//! `link` through its public API, against a real `zig`: the spec examples
//! of `tests/unit/zigbuild_tests.zig` and `src/zigbuild/library.zig`,
//! ported. The oracles: the built code run (each library is dlopened and
//! called), the bytes a cache hit must have copied, the compiler's own
//! report, the files read back, and 1 job against N for the same bytes
//! (AGENTS.md: determinism is a test). No LRM clause.
//!
//! Contents: none public; tests only.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const File = @import("File.zig");
const Queue = @import("Queue.zig");
const Server = @import("Server.zig");
const Zig = @import("Zig.zig");
const exe = @import("exe.zig");
const check = @import("check.zig");
const tree = @import("tree.zig");
const Module = Zig.Module;
const Artifact = File.Artifact;

/// Most children a test keeps alive: the machine is shared.
const jobs_max = 3;

/// A `dyn` stand-in whose only obligation is the `exportDevice` the shim calls.
const plain_dyn =
    \\pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
    \\    _ = name;
    \\    @export(&D.eval, .{ .name = "arp_eval" });
    \\}
    \\
;

/// A host with `exportDevicePart`: exports each symbol from one part, so the
/// library resolves both only if every part was compiled and linked.
const parts_dyn =
    \\pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
    \\    _ = .{ D, name };
    \\    @compileError("a split build calls exportDevicePart");
    \\}
    \\pub fn exportDevicePart(comptime D: type, comptime name: []const u8, comptime part: @TypeOf(.setup)) void {
    \\    _ = name;
    \\    if (part == .setup) @export(&D.k, .{ .name = "arp_k" });
    \\    if (part == .eval) @export(&D.eval, .{ .name = "arp_eval" });
    \\}
    \\
;

// ---- private ----

/// `name` as `flush` names this target's library: `testdev.1` is
/// `libtestdev.1.so` on Linux and `testdev.1.dll` on Windows.
fn testLib(comptime name: []const u8) []const u8 {
    const t = &builtin.target;
    return comptime t.libPrefix() ++ name ++ t.dynamicLibSuffix();
}

/// The path of a successful build, or the test fails with its report.
fn expectOk(io: Io, r: Artifact) ![]u8 {
    return switch (r) {
        .failed => |b| {
            b.renderToStderr(io, .{}, .off) catch |e| std.debug.print("rendering the report failed: {t}\n", .{e});
            return error.UnexpectedBuildFailure;
        },
        .ok => |path| path,
    };
}

/// Opens `path` and returns `arp_eval(x)`: the oracle is the built code run.
fn callEval(path: []const u8, x: f64) !f64 {
    var lib = try @import("dynlib").DynLib.open(path);
    defer lib.close();
    const eval = lib.lookup(*const fn (f64) callconv(.c) f64, "arp_eval") orelse return error.MissingSymbol;
    return eval(x);
}

/// Writes `contract.zig` (`contract_text`) and `dyn.zig` (`dyn_text`) under
/// `sub` of `tmp` and returns their modules, roots allocated in `arena`.
fn standIns(arena: Allocator, tmp: std.testing.TmpDir, sub: []const u8, contract_text: []const u8, dyn_text: []const u8) ![2]Module {
    const io = std.testing.io;
    const dir = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path, sub });
    try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ dir, "contract.zig" }), .data = contract_text });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ dir, "dyn.zig" }), .data = dyn_text });
    return .{
        .{ .name = "contract", .root = try std.fs.path.join(arena, &.{ dir, "contract.zig" }) },
        .{ .name = "dyn", .root = try std.fs.path.join(arena, &.{ dir, "dyn.zig" }) },
    };
}

test "Backend.auto is self-hosted only for Debug on x86_64" {
    const Backend = Zig.Backend;
    try std.testing.expectEqual(Backend.self_hosted, Backend.auto(.debug, .x86_64));
    try std.testing.expectEqual(Backend.llvm, Backend.auto(.fast, .x86_64));
    try std.testing.expectEqual(Backend.llvm, Backend.auto(.debug, .aarch64));
    try std.testing.expectEqual(Backend.llvm, Backend.auto(.debug, .nvptx64));
    for ([_]std.lang.Optimize{ .safe, .fast, .small }) |m|
        try std.testing.expectEqual(Backend.llvm, Backend.auto(m, .x86_64));
}

test "flush builds and versions a device" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var slots: [1]Server = undefined;
    var q: Queue = .init(&slots);
    const work = try arena.allocator().print(".zig-cache/tmp/{s}/w", .{tmp.sub_path});
    const mods = try standIns(arena.allocator(), tmp, "mods", "pub const k: f64 = 2.0;\n", plain_dyn);
    const f: File = .{ .kind = .so, .work_dir = work, .name = "testdev", .optimize = .debug, .backend = .self_hosted, .modules = &mods };

    const dev_v1 =
        \\const contract = @import("contract");
        \\pub fn eval(x: f64) callconv(.c) f64 { return x * contract.k; }
        \\
    ;
    var r1 = try f.flush(gpa, io, &q, .{ .text = dev_v1 }, 1);
    defer r1.deinit(gpa);
    const so1 = try expectOk(io, r1);
    try std.testing.expect(std.mem.endsWith(u8, so1, testLib("testdev.1")));
    try std.testing.expectEqual(@as(f64, 6.0), try callEval(so1, 3.0));

    // A changed unit rebuilds to a fresh inode under a new generation.
    const dev_v2 =
        \\const contract = @import("contract");
        \\pub fn eval(x: f64) callconv(.c) f64 { return x * contract.k + 1.0; }
        \\
    ;
    var r2 = try f.flush(gpa, io, &q, .{ .text = dev_v2 }, 2);
    defer r2.deinit(gpa);
    const so2 = try expectOk(io, r2);
    try std.testing.expect(std.mem.endsWith(u8, so2, testLib("testdev.2")));
    try std.testing.expectEqual(@as(f64, 7.0), try callEval(so2, 3.0));

    // A broken unit is reported as diagnostics.
    var r3 = try f.flush(gpa, io, &q, .{ .text = "pub fn eval() void { @compileError(\"boom\"); }\n" }, 3);
    defer r3.deinit(gpa);
    try std.testing.expect(r3 == .failed);

    // The split form compiles: `device.zig` and the unit files import each
    // other, which is legal Zig.
    var r5 = try f.flush(gpa, io, &q, tree.splitOutput(&.{ "unit_a", "unit_b" }), 5);
    defer r5.deinit(gpa);
    const so5 = try expectOk(io, r5);
    try std.testing.expect(std.mem.endsWith(u8, so5, testLib("testdev.5")));
    // unit_a(3) + unit_b(3) = 3*2 + (3+2).
    try std.testing.expectEqual(@as(f64, 11.0), try callEval(so5, 3.0));
}

test "a split flush links one object per part into a library that runs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var slots: [jobs_max]Server = undefined;
    var q: Queue = .init(&slots);
    const work = try arena.allocator().print(".zig-cache/tmp/{s}/w", .{tmp.sub_path});

    // One host without `exportDevicePart` is built whole in the setup object.
    const whole_dyn =
        \\pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
        \\    _ = name;
        \\    @export(&D.k, .{ .name = "arp_k" });
        \\    @export(&D.eval, .{ .name = "arp_eval" });
        \\}
        \\
    ;
    const dev =
        \\const contract = @import("contract");
        \\pub fn k() callconv(.c) f64 { return contract.k; }
        \\pub fn eval(x: f64) callconv(.c) f64 { return x * contract.k; }
        \\
    ;
    for ([_][]const u8{ parts_dyn, whole_dyn }, [_][]const u8{ "parts", "whole" }, 1..) |dyn, sub, gen| {
        const mods = try standIns(arena.allocator(), tmp, sub, "pub const k: f64 = 2.0;\n", dyn);
        const f: File = .{ .kind = .so, .work_dir = work, .name = "splitdev", .optimize = .fast, .backend = .llvm, .modules = &mods, .split = .parts };
        var r = try f.flush(gpa, io, &q, .{ .text = dev }, @intCast(gen));
        defer r.deinit(gpa);
        const so = try expectOk(io, r);
        var lib = try @import("dynlib").DynLib.open(so);
        defer lib.close();
        const k = lib.lookup(*const fn () callconv(.c) f64, "arp_k") orelse return error.MissingSymbol;
        try std.testing.expectEqual(@as(f64, 2.0), k());
        try std.testing.expectEqual(@as(f64, 6.0), try callEval(so, 3.0));
    }
}

test "a split flush that fails returns one report and leaks the others' none" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try arena.allocator().print(".zig-cache/tmp/{s}/w", .{tmp.sub_path});
    // Every part reaches `eval`, so every piece fails; the children after
    // the first report are killed (`std.testing.allocator` sees a leak if a
    // report is not freed).
    const mods = try standIns(arena.allocator(), tmp, "mods", "pub const k: f64 = 2.0;\n",
        \\pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
        \\    _ = name;
        \\    @export(&D.eval, .{ .name = "arp_eval" });
        \\}
        \\pub fn exportDevicePart(comptime D: type, comptime name: []const u8, comptime part: @TypeOf(.setup)) void {
        \\    _ = .{ name, part };
        \\    @export(&D.eval, .{ .name = "arp_eval" });
        \\}
        \\
    );
    const dev = "pub fn eval() callconv(.c) void { @compileError(\"boom\"); }\n";
    // One child at a time, then several at once.
    var slots: [jobs_max]Server = undefined;
    for ([_]usize{ 1, jobs_max }) |jobs| {
        var q: Queue = .init(slots[0..jobs]);
        const f: File = .{ .kind = .so, .work_dir = work, .name = "faildev", .optimize = .fast, .backend = .llvm, .modules = &mods, .split = .parts };
        var r = try f.flush(gpa, io, &q, .{ .text = dev }, 1);
        defer r.deinit(gpa);
        try std.testing.expect(r == .failed);
        try std.testing.expect(r.failed.errorMessageCount() > 0);
    }
}

test "a split flush gives the same library bytes from 1 job and from N" {
    // AGENTS.md: determinism is a test, 1 job and N jobs give the same bytes.
    // Oracle: the library built one child at a time.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const mods = try standIns(arena.allocator(), tmp, "mods", "pub const k: f64 = 2.0;\n", parts_dyn);
    const dev =
        \\pub fn k() callconv(.c) f64 { return @import("contract").k; }
        \\pub fn eval(x: f64) callconv(.c) f64 { return x * @import("contract").k; }
        \\
    ;
    var slots: [jobs_max]Server = undefined;
    var bytes: [2][]u8 = undefined;
    for ([_]usize{ 1, jobs_max }, &bytes, 0..) |jobs, *out, i| {
        var q: Queue = .init(slots[0..jobs]);
        const work = try arena.allocator().print(".zig-cache/tmp/{s}/w{d}", .{ tmp.sub_path, i });
        const f: File = .{ .kind = .so, .work_dir = work, .name = "jobsdev", .optimize = .fast, .backend = .llvm, .modules = &mods, .split = .parts };
        var r = try f.flush(gpa, io, &q, .{ .text = dev }, 1);
        defer r.deinit(gpa);
        out.* = try Io.Dir.cwd().readFileAlloc(io, try expectOk(io, r), arena.allocator(), .unlimited);
    }
    try std.testing.expect(bytes[0].len > 0);
    try std.testing.expectEqualSlices(u8, bytes[0], bytes[1]);
}

test "cache_dir: a second work directory reuses the first's library, and a changed device misses" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var slots: [1]Server = undefined;
    var q: Queue = .init(&slots);
    const base = try arena.allocator().print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    const mods = try standIns(arena.allocator(), tmp, "mods", "pub const k: f64 = 2.0;\n", plain_dyn);
    const cache = try std.fs.path.join(arena.allocator(), &.{ base, "cache" });
    const dev = "pub fn eval(x: f64) callconv(.c) f64 { return x * @import(\"contract\").k; }\n";

    // The first build fills the cache; its library is then replaced by a
    // marker, which a hit publishes and a miss cannot.
    const marker = "not a library";
    var got: [3]bool = undefined;
    for ([_][]const u8{ "w1", "w2", "w3" }, 0..) |w, i| {
        const wd = try std.fs.path.join(arena.allocator(), &.{ base, w });
        const f: File = .{ .kind = .so, .work_dir = wd, .name = "cachedev", .optimize = .debug, .backend = .self_hosted, .modules = &mods, .cache_dir = cache };
        var r = try f.flush(gpa, io, &q, .{ .text = if (i == 2) dev ++ "pub const z = 1;\n" else dev }, 1);
        defer r.deinit(gpa);
        const bytes = try Io.Dir.cwd().readFileAlloc(io, try expectOk(io, r), gpa, .unlimited);
        defer gpa.free(bytes);
        got[i] = std.mem.eql(u8, bytes, marker);
        if (i == 0) {
            // `<cache>/o/<digest>/<library>`: exactly one entry.
            const objects = try std.fs.path.join(arena.allocator(), &.{ cache, "o" });
            var odir = try Io.Dir.cwd().openDir(io, objects, .{ .iterate = true });
            defer odir.close(io);
            var it = odir.iterate();
            var n: usize = 0;
            while (try it.next(io)) |e| : (n += 1) {
                try odir.writeFile(io, .{ .sub_path = try std.fs.path.join(arena.allocator(), &.{ e.name, testLib("cachedev") }), .data = marker });
            }
            try std.testing.expectEqual(@as(usize, 1), n);
        }
    }
    try std.testing.expectEqualSlices(bool, &.{ false, true, false }, &got);
}

test "cache_dir: an edit to a file a module root imports misses the cache" {
    // Regression (zigbuild): the key once hashed only each module's root
    // file, so a build after an edit to a sibling it imports returned the
    // stale library.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var slots: [1]Server = undefined;
    var q: Queue = .init(&slots);
    const base = try arena.allocator().print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    const mods = try standIns(arena.allocator(), tmp, "mods", "pub const k = @import(\"k.zig\").k;\n", plain_dyn);
    const cache = try std.fs.path.join(arena.allocator(), &.{ base, "cache" });
    const dev = "pub fn eval(x: f64) callconv(.c) f64 { return x * @import(\"contract\").k; }\n";

    for ([_][]const u8{ "w1", "w2", "w3" }, [_]f64{ 2.0, 3.0, 2.0 }) |w, k| {
        try tmp.dir.writeFile(io, .{ .sub_path = "mods/k.zig", .data = try arena.allocator().print("pub const k: f64 = {d:.1};\n", .{k}) });
        const wd = try std.fs.path.join(arena.allocator(), &.{ base, w });
        const f: File = .{ .kind = .so, .work_dir = wd, .name = "sibdev", .optimize = .debug, .backend = .self_hosted, .modules = &mods, .cache_dir = cache };
        var r = try f.flush(gpa, io, &q, .{ .text = dev }, 1);
        defer r.deinit(gpa);
        try std.testing.expectEqual(k, try callEval(try expectOk(io, r), 1.0));
    }
}

test "buildEngine reuses its object only while every key component is unchanged" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var slots: [1]Server = undefined;
    var q: Queue = .init(&slots);
    const work = try gpa.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(work);
    const cache = try std.fs.path.join(gpa, &.{ work, "engine-cache" });
    defer gpa.free(cache);

    // A stand-in `sim` whose engine reads a constant from a second file.
    try tmp.dir.writeFile(io, .{ .sub_path = "sim.zig", .data =
        \\pub const rt = struct {
        \\    pub const engine = struct {
        \\        pub fn exportAll() void {
        \\            @export(&k, .{ .name = "vera_rt_test_k" });
        \\        }
        \\        fn k() callconv(.c) u32 {
        \\            return @import("k.zig").k;
        \\        }
        \\    };
        \\};
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "k.zig", .data = "pub const k: u32 = 1;\n" });
    const mods = [_]Module{
        .{ .name = "dyn", .root = "never-read.zig" },
        .{ .name = "sim", .root = try std.fs.path.join(gpa, &.{ work, "sim.zig" }) },
    };
    defer gpa.free(mods[1].root);
    var f: File = .{ .kind = .so, .work_dir = work, .name = "unused", .optimize = .debug, .backend = .self_hosted, .modules = &mods };

    const Build = struct {
        fn path(f_: File, q_: *Queue, cache_: []const u8) ![]u8 {
            var r = try f_.buildEngine(gpa, io, q_, cache_);
            errdefer r.deinit(gpa);
            return try expectOk(io, r);
        }
    };
    const first = try Build.path(f, &q, cache);
    defer gpa.free(first);

    // Unchanged: the same object.
    const again = try Build.path(f, &q, cache);
    defer gpa.free(again);
    try std.testing.expectEqualStrings(first, again);

    // A changed source file, a changed optimize mode, a changed backend:
    // each a different object.
    try tmp.dir.writeFile(io, .{ .sub_path = "k.zig", .data = "pub const k: u32 = 2;\n" });
    const edited = try Build.path(f, &q, cache);
    defer gpa.free(edited);
    try std.testing.expect(!std.mem.eql(u8, first, edited));

    f.optimize = .small;
    f.backend = .llvm;
    const small = try Build.path(f, &q, cache);
    defer gpa.free(small);
    try std.testing.expect(!std.mem.eql(u8, edited, small));

    // ... and the change undone finds the first object again.
    f.optimize = .debug;
    f.backend = .self_hosted;
    try tmp.dir.writeFile(io, .{ .sub_path = "k.zig", .data = "pub const k: u32 = 1;\n" });
    const back = try Build.path(f, &q, cache);
    defer gpa.free(back);
    try std.testing.expectEqualStrings(first, back);
}

test "buildExe hands back zig's report for a testbench that does not compile" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var slots: [1]Server = undefined;
    var q: Queue = .init(&slots);
    const work = try gpa.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(work);
    try tmp.dir.writeFile(io, .{ .sub_path = "c.zig", .data = "" });
    const contract = try std.fs.path.join(gpa, &.{ work, "c.zig" });
    defer gpa.free(contract);
    const f: File = .{ .kind = .exe, .work_dir = work, .name = "broken", .optimize = .debug, .modules = &.{.{ .name = "contract", .root = contract }} };

    // `std.testing.allocator` fails the test if `bin` or the report leaks.
    var r = try exe.buildExe(f, gpa, io, &q, "pub const x = 1;\n", "pub fn main() void { _ = @import(\"device\").y; }\n");
    defer r.deinit(gpa);
    try std.testing.expect(r == .failed);
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try r.failed.renderToWriter(.{}, &aw.writer);
    try std.testing.expect(std.mem.find(u8, aw.written(), "no member named 'y'") != null);

    // A compiler that cannot be spawned is an error, and `bin` is freed.
    var gone = f;
    gone.zig_exe = "/nonexistent/zig";
    try std.testing.expectError(error.CompilerGone, exe.buildExe(gone, gpa, io, &q, "", ""));
}

test "buildExe and buildBatch build binaries that run" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var slots: [1]Server = undefined;
    var q: Queue = .init(&slots);
    const work = try arena.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(io, .{ .sub_path = "c.zig", .data = "pub const k: u8 = 7;\n" });
    const contract: Module = .{ .name = "contract", .root = try std.fs.path.join(arena, &.{ work, "c.zig" }) };
    const device = "pub const k = @import(\"contract\").k;\n";
    // A runner's `main` takes the process (`batchRoot` passes it on).
    const runner = "pub fn main(_: @import(\"std\").process.Init.Minimal) void { @import(\"std\").process.exit(@import(\"device\").k); }\n";
    const f: File = .{ .kind = .exe, .work_dir = work, .name = "tb", .optimize = .debug, .modules = &.{contract} };

    // The oracle is the binary's exit status: the contract's constant.
    var r = try exe.buildExe(f, gpa, io, &q, device, runner);
    defer r.deinit(gpa);
    const one = try std.process.run(gpa, io, .{ .argv = &.{try expectOk(io, r)} });
    defer gpa.free(one.stdout);
    defer gpa.free(one.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, one.term);

    // Two members in one binary, each picked by `argv[0]`.
    var batch = f;
    batch.name = "batch";
    const members = [_]exe.Staged{
        try exe.stage(f, arena, io, device, runner),
        try exe.stage(.{ .kind = .exe, .work_dir = work, .name = "tb2", .optimize = .debug, .modules = &.{contract} }, arena, io, device, "pub fn main(_: @import(\"std\").process.Init.Minimal) void { @import(\"std\").process.exit(@import(\"device\").k + 1); }\n"),
    };
    var b = try exe.buildBatch(batch, gpa, io, &q, &members);
    defer b.deinit(gpa);
    const bin = try expectOk(io, b);
    for ([_]u8{ 7, 8 }, 0..) |want, i| {
        const link_path = try arena.print("{s}/{s}{d}", .{ work, exe.batch_argv0, i });
        try Io.Dir.cwd().symLink(io, std.fs.path.basename(bin), link_path, .{});
        const run = try std.process.run(gpa, io, .{ .argv = &.{link_path} });
        defer gpa.free(run.stdout);
        defer gpa.free(run.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = want }, run.term);
    }
}

test "stage writes a testbench's files, one name-qualified pair per artifact" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try arena.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    const f: File = .{ .kind = .exe, .work_dir = work, .name = "res", .optimize = .debug, .modules = &.{} };

    const s = try exe.stage(f, arena, io, "DEVICE", "RUNNER");
    try std.testing.expectEqualStrings(try std.fs.path.join(arena, &.{ work, "res.tb.zig" }), s.root);
    try std.testing.expectEqualStrings(try std.fs.path.join(arena, &.{ work, "res.device.zig" }), s.device);
    try std.testing.expectEqualStrings("RUNNER", try tmp.dir.readFileAlloc(io, "res.tb.zig", arena, .limited(64)));
    try std.testing.expectEqualStrings("DEVICE", try tmp.dir.readFileAlloc(io, "res.device.zig", arena, .limited(64)));

    // A second artifact in the same work root keeps its own files: an
    // escaped module name takes a hashed stem (`fileStem`).
    var g = f;
    g.name = "res+";
    const t = try exe.stage(g, arena, io, "D2", "R2");
    try std.testing.expect(!std.mem.eql(u8, s.root, t.root));
    try std.testing.expectEqualStrings("RUNNER", try tmp.dir.readFileAlloc(io, "res.tb.zig", arena, .limited(64)));
}

test "typeCheck: the contract's verdict, and its refusal reported with the compiler's message" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var slots: [1]Server = undefined;
    var q: Queue = .init(&slots);
    const work = try arena.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    // `validate` runs only when the root turns it on, which the check's root does.
    try tmp.dir.writeFile(io, .{ .sub_path = "contract.zig", .data =
        \\pub fn validate(comptime D: type) void {
        \\    if (!@import("root").vera_validate_contract) @compileError("off");
        \\    if (!@hasDecl(D, "eval")) @compileError("no eval");
        \\}
        \\
    });
    const f: File = .{
        .kind = .check,
        .work_dir = try std.fs.path.join(arena, &.{ work, "check" }),
        .name = "check",
        .optimize = .debug,
        .modules = &.{.{ .name = "contract", .root = try std.fs.path.join(arena, &.{ work, "contract.zig" }) }},
    };
    var err: Io.Writer.Allocating = .init(gpa);
    defer err.deinit();

    try std.testing.expectEqual(check.Verdict.compiles, try check.typeCheck(f, gpa, io, &q, "pub fn eval() void {}\n", "dir/good.va", &err.writer));
    try std.testing.expectEqual(@as(usize, 0), err.written().len);

    try std.testing.expectEqual(check.Verdict.fails, try check.typeCheck(f, gpa, io, &q, "pub const x = 1;\n", "dir/bad.va", &err.writer));
    try std.testing.expect(std.mem.startsWith(u8, err.written(), "error: dir/bad.va: codegen produced Zig that does not compile"));
    try std.testing.expect(std.mem.find(u8, err.written(), "no eval") != null);
}
