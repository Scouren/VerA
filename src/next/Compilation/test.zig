//! The spine's own tests: a source on disk through `Compilation.update`,
//! held to the stages chained by hand (the differential harnesses' way:
//! `vams` Preprocessor, Parse, AstGen, `Sema`, `Air.Float`, `codegen`),
//! and the scratch directory `--check` takes.
//! No LRM clause: each stage cites its own.
//!
//! Contents: tests only.

const std = @import("std");
const Io = std.Io;
const vams = @import("vams");
const sema = @import("sema");
const Air = @import("air");
const codegen = @import("codegen");
const Compilation = @import("../Compilation.zig");
const backend = @import("backend.zig");

const resistor =
    \\`include "disciplines.vams"
    \\module res(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  parameter real r = 1000.0 from (0.0:inf);
    \\  analog I(p, n) <+ V(p, n) / r;
    \\endmodule
    \\
;

// ---- private ----

/// Compiles `text` written to `name` under `tmp` with `config` (its
/// `paths` filled in, in `arena`); the caller destroys the result before
/// freeing `arena`.
fn compileText(arena: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8, text: []const u8, config: Compilation.Config) !*Compilation {
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = text });
    var c = config;
    c.paths = try arena.dupe([]const u8, &.{try tmp.dir.realPathFileAlloc(io, name, arena)});
    const comp = try Compilation.create(std.testing.allocator, io, c);
    errdefer comp.destroy();
    try comp.update();
    return comp;
}

fn backendRanges(a: std.mem.Allocator, ranges: []const Air.Device.Range) ![]const Air.Interval.Range {
    var out: std.ArrayList(Air.Interval.Range) = .empty;
    for (ranges) |r| {
        if (r.strings) continue;
        try out.append(a, .{ .kind = if (r.exclude) .exclude else .from, .lo = r.lo, .hi = r.hi, .lo_inclusive = r.lo_closed, .hi_inclusive = r.hi_closed });
    }
    return out.items;
}

test "--emit-zig through the spine is the stages chained by hand, byte for byte" {
    // Oracle: the same source through each merged stage called directly,
    // as tests/differential/codegen/sides.zig chains them.
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer paths.deinit();
    const comp = try compileText(paths.allocator(), &tmp, "res.va", resistor, .{ .target = .zig });
    defer comp.destroy();
    var errors = try comp.getAllErrors();
    defer errors.deinit(gpa);
    try std.testing.expect(!errors.failed());
    const got = comp.outputs.out.items;

    var pp: vams.Preprocessor = .init(gpa, .{ .spice_primitives = true, .require_std_includes = true });
    defer pp.deinit();
    try pp.addUnit("res.va", resistor);
    // Only annex D is included, and no file of that name is beside it.
    while (try pp.run()) |_| try pp.answer(null);
    const text = try gpa.dupeSentinel(u8, pp.output().text, 0);
    defer gpa.free(text);
    var tree = try vams.Ast.parse(gpa, text, .{});
    defer tree.deinit(gpa);
    var vir = try vams.AstGen.generate(gpa, &tree, .{ .directives = pp.output().directives });
    defer vir.deinit(gpa);
    var zcu: sema.Zcu = try .init(gpa);
    defer zcu.deinit();
    _ = try zcu.addFile("res.va", vir, comp.units.items[0].builtins);
    try sema.Sema.elaborate(&zcu, .{ .roots = .first });
    var a = (try sema.Sema.analyze(&zcu)).?;
    defer a.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const roots = try codegen.floatRoots(arena.allocator(), &a.air, &a.device);
    const params = try arena.allocator().alloc(Air.Float.Param, a.device.params.len);
    for (params, 0..) |*p, k| p.* = .{ .ranges = try backendRanges(arena.allocator(), a.device.paramRanges(@fromBackingInt(@intCast(k)))) };
    var wip: vams.Diag.Wip = .init(gpa);
    defer wip.deinit();
    var f = try Air.Float.analyze(gpa, a.air, &zcu.intern_pool, .{ .params = params, .roots = roots }, &wip);
    defer f.deinit(gpa);
    var r = try codegen.generate(gpa, .zig, .{ .air = &a.air, .ip = &zcu.intern_pool, .device = &a.device, .verdict = &f.verdict }, .{});
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings(r.ok.text, got);
    try std.testing.expect(std.mem.find(u8, got, "module res") == null);
}

test "an error stops the queue and is located in the file the user wrote" {
    // Oracle: the text itself: the undeclared name sits on line 3 of the
    // source, after a 1-line `include whose expansion moves every
    // preprocessed offset.
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer paths.deinit();
    const src = "`include \"disciplines.vams\"\nmodule m(p); inout p; electrical p;\n  analog V(p) <+ nope;\nendmodule\n";
    const comp = try compileText(paths.allocator(), &tmp, "bad.va", src, .{ .target = .zig });
    defer comp.destroy();
    var errors = try comp.getAllErrors();
    defer errors.deinit(gpa);
    try std.testing.expect(errors.failed());
    try std.testing.expect(comp.stopped);
    try std.testing.expectEqual(@as(usize, 0), comp.outputs.out.items.len);
    const m = errors.message(errors.messages()[0]);
    try std.testing.expectEqual(@as(u32, 0), @backingInt(m.loc.file));
    try std.testing.expectEqualStrings("nope", src[m.loc.start..m.loc.end]);
}

test "a §4.3.2 error from the air passes is located at the operator the user wrote" {
    // Oracle: the text itself (the old driver points E0601 at the `%`):
    // Sema records where each Air instruction came from and `Air.Float`
    // reports there.
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer paths.deinit();
    const src = "`include \"disciplines.vams\"\nmodule m(p, n); inout p, n; electrical p, n; real f;\n  analog begin f = 5.5 % 0.0; I(p, n) <+ f; end\nendmodule\n";
    const comp = try compileText(paths.allocator(), &tmp, "mod.va", src, .{ .target = .zig });
    defer comp.destroy();
    var errors = try comp.getAllErrors();
    defer errors.deinit(gpa);
    try std.testing.expect(errors.failed());
    const m = errors.message(errors.messages()[0]);
    try std.testing.expectEqual(vams.Diag.Code.E0601, m.tag.code);
    try std.testing.expect(!m.loc.isNone());
    try std.testing.expectEqualStrings("%", src[m.loc.start..m.loc.end]);
}

test "a backend that is not built is named, with not_built_status" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer paths.deinit();
    const comp = try compileText(paths.allocator(), &tmp, "res.va", resistor, .{ .target = .verilog });
    defer comp.destroy();
    try std.testing.expectEqual(Compilation.not_built_status, comp.outputs.status);
    try std.testing.expectEqual(Compilation.Backend.verilog, comp.outputs.not_built.?);
    try std.testing.expect(std.mem.find(u8, comp.outputs.err.items, "not built") != null);
}

test "every --check scratch directory is its own, under -o's directory" {
    // Oracle: lib/TODO.md §12 (ESPice's race): two invocations never share
    // a scratch path, and it is never a fixed name.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer paths.deinit();
    const comp = try compileText(paths.allocator(), &tmp, "res.va", resistor, .{ .target = .lint });
    defer comp.destroy();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", paths.allocator());
    const out = try std.fs.path.join(paths.allocator(), &.{ base, "out" });
    comp.config.out_path = try std.fs.path.join(paths.allocator(), &.{ out, "dev.zig" });
    const a = try backend.scratchDir(comp);
    const b = try backend.scratchDir(comp);
    try std.testing.expect(!std.mem.eql(u8, a, b));
    try std.testing.expectEqualStrings(out, std.fs.path.dirname(a).?);
    try std.testing.expectEqualStrings(out, std.fs.path.dirname(b).?);
    try Io.Dir.cwd().access(std.testing.io, a, .{});
}
