//! The runtime's public API on hand-built `Program`s: each test writes a
//! table as a compiler stage would and holds the transcript to the IEEE
//! 1364-2005 text the clause names. The fixture corpus is `diff-sim`'s.
//!
//! Contents: tests only.

const std = @import("std");
const sim = @import("../sim.zig");
const Builder = sim.Builder;
const Program = sim.Program;
const State = sim.State;
const Interp = sim.Interp;
const Ty = Program.Ty;

// ---- private ----

/// A builder with one root scope at 1s/1s.
fn start(arena: std.mem.Allocator) !Builder {
    var b: Builder = .init(arena);
    try b.times.append(arena, .{ .scale = try sim.time.Scale.init(.s, .s, .s), .unit_exp = 0 });
    try b.scopes.append(arena, .{ .parent = 0, .name = try b.string("top"), .index = null, .time = 0 });
    return b;
}

fn show(b: *Builder, text: []const u8, arg: ?u32, conv: u8) !u32 {
    const first: u32 = @intCast(b.pieces.items.len);
    const t = try b.string(text);
    try b.pieces.append(b.arena, .{ .kind = .text, .a = t.start, .width = t.len });
    if (arg) |e| try b.pieces.append(b.arena, .{ .kind = .spec, .conv = conv, .a = e, .width = 0 });
    const ids = try b.arena.alloc(u32, b.pieces.items.len - first);
    for (ids, first..) |*id, k| id.* = @intCast(k);
    try b.shows.append(b.arena, .{ .pieces = try b.listOf(ids), .radix = .decimal, .newline = true, .scope = 0 });
    return b.extraOf(Program.Task{ .kind = .show, .a = @intCast(b.shows.items.len - 1) });
}

fn runOf(arena: std.mem.Allocator, p: *const Program) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var s: State = try .init(arena, p, &out.writer);
    try Interp.run(&s);
    return out.written();
}

test "§9.2 a blocking assignment lands before the next statement reads it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = try start(a);
    const u8_ty = Ty.int(8, false);
    const r = try b.slot(u8_ty, &.{0xff}, &.{0xff});
    const place = try b.extraOf(Program.Place{ .kind = .slot, .a = r });
    _ = try b.inst(.assign, place, try b.int(u8_ty, 5), 0);
    _ = try b.inst(.task, try show(&b, "r=", try b.expr(.slot, u8_ty, r, 0), 'd'), 0, 0);
    _ = try b.inst(.stop, 0, 0, 0);
    try b.starts.append(a, .{ .pc = 0 });
    const p = b.finish();
    try std.testing.expectEqualStrings("r=5\n", try runOf(a, &p));
}

test "§9.2.2 a nonblocking update lands after the active region; §9.7.1 #1 resumes later" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = try start(a);
    const ty = Ty.int(4, false);
    const r = try b.slot(ty, &.{1}, &.{0});
    const place = try b.extraOf(Program.Place{ .kind = .slot, .a = r });
    const read = try b.expr(.slot, ty, r, 0);
    _ = try b.inst(.assign_nb, place, try b.int(ty, 9), 0);
    _ = try b.inst(.task, try show(&b, "now ", read, 'd'), 0, 0);
    _ = try b.inst(.delay, try b.int(Ty.int(32, true), 1), 0, 0);
    _ = try b.inst(.task, try show(&b, "later ", read, 'd'), 0, 0);
    _ = try b.inst(.stop, 0, 0, 0);
    try b.starts.append(a, .{ .pc = 0 });
    const p = b.finish();
    try std.testing.expectEqualStrings("now 1\nlater 9\n", try runOf(a, &p));
}
