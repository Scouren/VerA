//! Testbench builds: device text and runner text in, one `zig build-exe`
//! (or a runner `build-lib`) through the `Queue` out, as the binary's path
//! or the compiler's report. The runner text is the caller's
//! (`tb.renderRunner`); this file owns the module files on disk and the
//! batch root. Cites no LRM clause: every clause the binary implements is in
//! the text it builds.
//!
//! Contents:
//! - `pub const runtime_modules: [5]Module`
//! - `pub const StageError`
//! - `pub const Staged = struct { root: []const u8, device: []const u8 }`
//! - `pub const batch_argv0 = "vera-batch-"`
//! - `pub fn treeOf(contract: []const u8) []const u8`
//! - `pub fn buildExe(f: File, gpa: Allocator, io: Io, q: *Queue, device: ?[]const u8, runner: []const u8) File.Error!File.Artifact`
//! - `pub fn stage(f: File, arena: Allocator, io: Io, device: []const u8, runner: []const u8) StageError!Staged`
//! - `pub fn buildBatch(f: File, gpa: Allocator, io: Io, q: *Queue, members: []const Staged) File.Error!File.Artifact`

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const File = @import("File.zig");
const Zig = @import("Zig.zig");
const tree = @import("tree.zig");
const Queue = @import("Queue.zig");
const Server = @import("Server.zig");
const Module = Zig.Module;

/// The modules an emitted executable or a `.v` device links beside
/// `contract`: build.zig's `module_specs` rows for `sim` and what it imports.
/// Each root is relative to the VerA tree the contract sits in (`treeOf`),
/// which is what `vera` writes under its work directory (`src/main.zig`'s
/// `simTree`).
pub const runtime_modules = [_]Module{
    .{ .name = "sim", .root = "lib/sim/root.zig", .deps = &.{ "contract", "base", "diag", "frontend", "kernels" } },
    .{ .name = "base", .root = "lib/base/root.zig" },
    .{ .name = "diag", .root = "lib/diag/root.zig" },
    .{ .name = "frontend", .root = "lib/frontend/root.zig", .deps = &.{ "base", "diag", "kernels" } },
    .{ .name = "kernels", .root = "lib/kernels/root.zig", .deps = &.{"contract"} },
};

/// Every way `stage` fails: a module file could not be written. Files
/// written before the failure stay.
pub const StageError = Allocator.Error || Io.Dir.CreateDirPathError || Io.Dir.OpenError ||
    Io.Dir.WriteFileError;

/// A testbench's module files on disk, as `stage` wrote them. The paths live
/// in the `arena` given to `stage`.
pub const Staged = struct { root: []const u8, device: []const u8 };

/// A `buildBatch` binary runs member `i` when its `argv[0]` ends in
/// `batch_argv0 ++ "<i>"`: a symlink of that name stands in for each member's
/// own binary. No runner reads `argv[0]` (its plusargs start at `argv[1]`),
/// so a member's transcript is the one its own binary would print.
pub const batch_argv0 = "vera-batch-";

/// The compiler cache every testbench build shares, relative to the cwd.
const cache_dir = ".zig-cache";

/// Returns the VerA tree a `contract` root sits in, `<tree>` of
/// `<tree>/lib/contract.zig`, as a slice of `contract`.
pub fn treeOf(contract: []const u8) []const u8 {
    const root = std.fs.path.dirname(std.fs.path.dirname(contract) orelse ".") orelse ".";
    assert(root.len > 0);
    return root;
}

/// Builds the device and the runner into one native binary at `f.out_path`
/// or `<f.work_dir>/<name>`, through `q`: a `.exe` file is an executable, a
/// `.so` one `renderVpiLib`'s runner as a library a Clause 12 analog host
/// loads. A null `device` builds `runner` alone (an IEEE 1364 design). Every
/// module in `f.modules` is a dependency of the runner and of the device.
/// Calls `build-exe` directly: `flush`'s generation path serves hot reload,
/// which a build-once testbench does not need. Caller owns the result and
/// frees it with `Artifact.deinit` and `gpa`. Fails as `File.Error` says.
/// Asserts that `f` is `.exe` or `.so`, and that a `.so` has a device.
pub fn buildExe(f: File, gpa: Allocator, io: Io, q: *Queue, device: ?[]const u8, runner: []const u8) File.Error!File.Artifact {
    assert(f.kind == .exe or f.kind == .so);
    // `renderVpiLib`'s runner calls the device; there is no 1364 library form.
    if (f.kind == .so) assert(device != null);
    var dir = try openWorkDir(io, f);
    defer dir.close(io);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const names = try moduleNames(arena, f.modules, device != null);
    var modules: std.ArrayList(Module) = .empty;
    try modules.append(arena, .{ .name = "root", .root = try writeModule(arena, io, dir, f, "tb", runner), .deps = names });
    if (device) |text| try modules.append(arena, .{
        .name = "device",
        .root = try writeModule(arena, io, dir, f, "device", text),
        .deps = names[@intFromBool(device != null)..],
    });
    try modules.appendSlice(arena, f.modules);
    return runExe(f, gpa, io, q, arena, modules.items);
}

/// Writes the two module files `buildExe` would build for this device and
/// runner, under `f.work_dir`, without building, and returns their paths in
/// `arena`. Fails as `StageError` says.
pub fn stage(f: File, arena: Allocator, io: Io, device: []const u8, runner: []const u8) StageError!Staged {
    var dir = try openWorkDir(io, f);
    defer dir.close(io);
    const staged: Staged = .{
        .root = try writeModule(arena, io, dir, f, "tb", runner),
        .device = try writeModule(arena, io, dir, f, "device", device),
    };
    assert(!std.mem.eql(u8, staged.root, staged.device));
    return staged;
}

/// Builds several staged testbenches into one binary at
/// `<f.work_dir>/<f.name>`, dispatching on `argv[0]` (`batch_argv0`). A
/// fixture testbench's build is mostly the compiler's fixed cost per
/// invocation (std, start code, the panic handler), which a batch pays once.
/// Measured with a shared warm cache, 8 Debug testbenches: 17.57 Gi built one
/// by one, 3.53 Gi as one batch, transcripts identical. `.failed` names no
/// member: the caller rebuilds them one by one to learn which broke. Caller
/// owns the result and frees it with `Artifact.deinit` and `gpa`. Fails as
/// `File.Error` says. Asserts that `members` is not empty, `f` is `.exe` and
/// `f.modules` is the contract alone.
pub fn buildBatch(f: File, gpa: Allocator, io: Io, q: *Queue, members: []const Staged) File.Error!File.Artifact {
    assert(f.kind == .exe);
    assert(members.len != 0);
    assert(f.modules.len == 1);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try openWorkDir(io, f);
    defer dir.close(io);

    const n = members.len;
    const modules = try arena.alloc(Module, 1 + 2 * n + 1);
    const tbs = try arena.alloc([]const u8, n);
    for (tbs, 0..) |*t, i| t.* = try arena.print("tb{d}", .{i});
    modules[0] = .{ .name = "root", .root = try writeModule(arena, io, dir, f, "batch", try batchRoot(arena, n)), .deps = tbs };
    for (members, 0..) |m, i| {
        const dev = try arena.print("dev{d}", .{i});
        modules[1 + 2 * i] = .{ .name = tbs[i], .root = m.root, .deps = try arena.dupe([]const u8, &.{ try arena.print("device={s}", .{dev}), "contract" }) };
        modules[2 + 2 * i] = .{ .name = dev, .root = m.device, .deps = &.{"contract"} };
    }
    modules[1 + 2 * n] = f.modules[0];
    return runExe(f, gpa, io, q, arena, modules);
}

// ---- private ----

/// Creates `f.work_dir` if absent and opens it. The caller closes it.
fn openWorkDir(io: Io, f: File) (Io.Dir.CreateDirPathError || Io.Dir.OpenError)!Io.Dir {
    assert(f.work_dir.len > 0);
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, f.work_dir);
    return cwd.openDir(io, f.work_dir, .{});
}

/// `device` (when there is one) then every module's name, for the root's
/// `--dep`s; the device takes the slice past `device`.
fn moduleNames(arena: Allocator, modules: []const Module, device: bool) Allocator.Error![]const []const u8 {
    const names = try arena.alloc([]const u8, modules.len + @intFromBool(device));
    if (device) names[0] = "device";
    for (names[@intFromBool(device)..], modules) |*n, m| n.* = m.name;
    return names;
}

/// Writes one module's source to `<stem>.<suffix>.zig` in `dir` and returns
/// its path, allocated in `arena`. The name-qualified file keeps two
/// artifacts sharing a work root from overwriting each other.
fn writeModule(arena: Allocator, io: Io, dir: Io.Dir, f: File, suffix: []const u8, text: []const u8) (Allocator.Error || Io.Dir.WriteFileError)![]const u8 {
    assert(suffix.len != 0);
    assert(std.mem.findAny(u8, suffix, "/\\") == null);
    const file = try arena.print("{s}.{s}.zig", .{ try tree.fileStem(arena, f.name), suffix });
    try dir.writeFile(io, .{ .sub_path = file, .data = text });
    return std.fs.path.join(arena, &.{ f.work_dir, file });
}

/// Runs the one `zig build-exe` (or runner `build-lib`) over `modules`
/// through `q`, then copies the binary out of the compiler's cache to
/// `f.out_path` or `<work_dir>/<stem>`: `--listen` refuses `-femit-bin`.
fn runExe(f: File, gpa: Allocator, io: Io, q: *Queue, arena: Allocator, modules: []const Module) File.Error!File.Artifact {
    assert(modules.len > 1);
    const stem = try tree.fileStem(arena, f.name);
    const t = &builtin.target;
    const bin = try gpa.dupe(u8, f.out_path orelse try std.mem.concat(arena, u8, &.{
        try std.fs.path.join(arena, &.{ f.work_dir, stem }), t.exeFileExt(),
    }));
    errdefer gpa.free(bin);
    var flags: std.ArrayList([]const u8) = .empty;
    // The binary is loaded at run time (`dynlib.zig`), never linked
    // against, and Zig 0.17's COFF linker writes the import library to the
    // output's directory joined to itself (FileNotFound, or BadPathName on
    // an absolute path).
    try flags.append(arena, "-fno-emit-implib");
    try flags.appendSlice(arena, f.backendOf().flags());
    // No debug info where there are no safety checks to trace: emitting it
    // is most of an unsafe build's LLVM time.
    if (f.stripOf()) try flags.append(arena, "-fstrip");
    const shared = f.kind == .so;
    const a = try Zig.argv(arena, .{
        .zig_exe = f.zig_exe,
        .verb = if (shared) "build-lib" else "build-exe",
        .kind = if (shared) &.{"-dynamic"} else &.{},
        .optimize = f.optimize,
        .name = stem,
        .cache_dir = cache_dir,
        // A host `dlopen`s a runner library: libc's dynamic TLS model.
        .libc = shared,
        .target = f.target,
        .flags = flags.items,
        .modules = modules,
    });
    var done: [1]Server.Done = undefined;
    if (try q.run(gpa, io, arena, &.{a}, &done)) |b| {
        gpa.free(bin);
        return .{ .failed = b };
    }
    const file = if (shared)
        try arena.print("{s}{s}{s}", .{ t.libPrefix(), stem, t.dynamicLibSuffix() })
    else
        try arena.print("{s}{s}", .{ stem, t.exeFileExt() });
    const built = try std.fs.path.join(arena, &.{ cache_dir, "o", &std.Build.Cache.binToHex(done[0].digest orelse return error.NoArtifact), file });
    Io.Dir.cwd().copyFile(built, .cwd(), bin, io, .{}) catch return error.NoArtifact;
    return .{ .ok = bin };
}

/// Returns the root module of a `buildBatch` binary over `n` members,
/// allocated in `arena`: its `main` runs `@import("tb<i>").main` for the `i`
/// that `argv[0]` ends in after `batch_argv0`, and panics on any other. It
/// also holds `vera_domain_muted`, the root decl a device's `zDomain` reads.
fn batchRoot(arena: Allocator, n: usize) Allocator.Error![]const u8 {
    assert(n != 0); // `buildBatch`'s precondition: a switch with only `else`.
    var root: std.ArrayList(u8) = .empty;
    try root.print(arena,
        \\const std = @import("std");
        \\/// The §4.3.2 domain-report mute each member's runner sets while its
        \\/// self-checks run (`runner_text` `muteDomain`): a device's `zDomain`
        \\/// reads it from the root, which here is this file.
        \\pub var vera_domain_muted: bool = false;
        \\pub fn main(init: std.process.Init.Minimal) void {{
        \\    const argv = init.args.toSlice(std.heap.page_allocator) catch @panic("argv");
        \\    const at = std.mem.findLast(u8, argv[0], "{s}") orelse @panic("argv[0] names no batch member");
        \\    const i = std.fmt.parseInt(usize, argv[0][at + {d} ..], 10) catch @panic("argv[0] names no batch member");
        \\    switch (i) {{
        \\
    , .{ batch_argv0, batch_argv0.len });
    for (0..n) |i| try root.print(arena, "        {d} => @import(\"tb{d}\").main(init),\n", .{ i, i });
    try root.appendSlice(arena, "        else => @panic(\"argv[0] names no batch member\"),\n    }\n}\n");
    assert(std.mem.endsWith(u8, root.items, "}\n"));
    return root.items;
}

/// Fails the test unless `src` passes Zig's AstGen with no error.
fn expectAstGen(src: []const u8) !void {
    const gpa = std.testing.allocator;
    const z = try gpa.dupeSentinel(u8, src, 0);
    defer gpa.free(z);
    var ast = try std.zig.Ast.parse(gpa, z, .{ .mode = .zig });
    defer ast.deinit(gpa);
    var zir = try std.zig.AstGen.generate(gpa, ast);
    defer zir.deinit(gpa);
    if (ast.errors.len == 0 and !zir.hasCompileErrors()) return;
    std.debug.print("{s}\n", .{src});
    return error.TestUnexpectedResult;
}

// The oracle: Zig's own AstGen for the batch root, and the module lists
// written out by hand. `buildExe` and `stage` against a real `zig` are
// test.zig's.

test batchRoot {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const src = try batchRoot(arena_state.allocator(), 3);
    try expectAstGen(src);
    // One arm per member and no more.
    try std.testing.expect(std.mem.find(u8, src, "        2 => @import(\"tb2\").main(init),\n") != null);
    try std.testing.expect(std.mem.find(u8, src, "3 =>") == null);
    // A member's device reads the §4.3.2 mute from the root, which is this file.
    try std.testing.expect(std.mem.find(u8, src, "pub var vera_domain_muted: bool = false;\n") != null);
    // The member index is read after the whole of `batch_argv0`.
    try std.testing.expect(std.mem.find(u8, src, "\"vera-batch-\"") != null);
    try std.testing.expect(std.mem.find(u8, src, "argv[0][at + 11 ..]") != null);
}

test moduleNames {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const mods = [_]Module{ .{ .name = "contract", .root = "c.zig" }, .{ .name = "sim", .root = "s.zig" } };
    const with = try moduleNames(arena_state.allocator(), &mods, true);
    try std.testing.expectEqual(@as(usize, 3), with.len);
    try std.testing.expectEqualStrings("device", with[0]);
    try std.testing.expectEqualStrings("sim", with[2]);
    const without = try moduleNames(arena_state.allocator(), &mods, false);
    try std.testing.expectEqualStrings("contract", without[0]);
}

test treeOf {
    try std.testing.expectEqualStrings("a/b", treeOf("a/b/lib/contract.zig"));
    try std.testing.expectEqualStrings(".", treeOf("lib/contract.zig"));
}
