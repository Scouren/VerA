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

test "§9.7.2 a posedge waiter resumes on 0 -> 1 only, after the writer's step" {
    // Process 0 waits on @(posedge c) and prints $time; process 1 writes c
    // 0 at #1 (a negedge from x: no wake) and 1 at #2 (the posedge).
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = try start(a);
    const bit = Ty.int(1, false);
    const c = try b.slot(bit, &.{1}, &.{1});
    const place = try b.extraOf(Program.Place{ .kind = .slot, .a = c });
    const terms = try b.listOf(&.{ c, @backingInt(Program.Edge.posedge), 0, 0 });
    _ = try b.inst(.wait_event, try b.extraOf(.{ .l = terms }), 0, 0); // pc 0
    const now = try b.expr(.time, Ty.int(64, false), 0, 0);
    _ = try b.inst(.task, try show(&b, "t=", now, 'd'), 0, 0); // pc 1
    _ = try b.inst(.stop, 0, 0, 0); // pc 2
    const one = try b.int(Ty.int(32, true), 1);
    _ = try b.inst(.delay, one, 0, 0); // pc 3
    _ = try b.inst(.assign, place, try b.int(bit, 0), 0);
    _ = try b.inst(.delay, one, 0, 0);
    _ = try b.inst(.assign, place, try b.int(bit, 1), 0);
    _ = try b.inst(.stop, 0, 0, 0);
    try b.starts.appendSlice(a, &.{ .{ .pc = 0 }, .{ .pc = 3 } });
    const p = b.finish();
    try std.testing.expectEqualStrings("t=2\n", try runOf(a, &p));
}

test "§7.9 a wand resolves its drivers by wired AND; an undriven wire reads z" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = try start(a);
    const bit = Ty.int(1, false);
    const w = try b.slot(bit, &.{0}, &.{1});
    const z = try b.slot(bit, &.{0}, &.{1});
    const zero = try b.int(bit, 0);
    const one = try b.int(bit, 1);
    const none = @backingInt(Program.Ref.none);
    // Two strong drivers of `w`, 1 and 0: wired AND gives 0 where a wire
    // would give x.
    const drivers = [_]Program.Driver{
        .{ .net = 0, .scope = 0, .s0 = .strong, .s1 = .strong, .delay = .{}, .delay_rows = @splat(none), .width = 1, .init = 0, .init_or_z = false, .source = .{ .expr = .{ .value = one, .slice = false, .lo = 0, .total = 0 } } },
        .{ .net = 0, .scope = 0, .s0 = .strong, .s1 = .strong, .delay = .{}, .delay_rows = @splat(none), .width = 1, .init = 2, .init_or_z = false, .source = .{ .expr = .{ .value = zero, .slice = false, .lo = 0, .total = 0 } } },
    };
    const nets = [_]Program.Net{
        .{ .kind = .wand, .charge = .medium, .slot = w, .drivers = try b.listOf(&.{ 0, 1 }), .delay = .{}, .decay = Program.Net.no_decay },
        .{ .kind = .wire, .charge = .medium, .slot = z, .drivers = .empty, .delay = .{}, .decay = Program.Net.no_decay },
    };
    _ = try b.inst(.continuous, 0, 0, 0); // pc 0
    _ = try b.inst(.continuous, 1, 0, 0); // pc 1
    _ = try b.inst(.delay, try b.int(Ty.int(32, true), 1), 0, 0); // pc 2
    const first: u32 = @intCast(b.pieces.items.len);
    try b.pieces.append(a, .{ .kind = .spec, .conv = 'b', .a = try b.expr(.slot, bit, w, 0) });
    try b.pieces.append(a, .{ .kind = .spec, .conv = 'b', .a = try b.expr(.slot, bit, z, 0) });
    try b.shows.append(a, .{ .pieces = try b.listOf(&.{ first, first + 1 }), .radix = .decimal, .newline = true, .scope = 0 });
    _ = try b.inst(.task, try b.extraOf(Program.Task{ .kind = .show, .a = 0 }), 0, 0);
    _ = try b.inst(.stop, 0, 0, 0);
    try b.starts.appendSlice(a, &.{ .{ .pc = 0 }, .{ .pc = 1 }, .{ .pc = 2 } });
    var p = b.finish();
    p.nets = &nets;
    p.drivers = &drivers;
    p.driver_init = &.{ 0, 1, 0, 1 };
    try std.testing.expectEqualStrings("0z\n", try runOf(a, &p));
}

test "§10.4 a function call copies its input in and returns its result slot" {
    // function [7:0] f(input [7:0] n); f = n + 1; called with 41.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = try start(a);
    const byte = Ty.int(8, false);
    const n = try b.slot(byte, &.{0xff}, &.{0xff});
    const f = try b.slot(byte, &.{0xff}, &.{0xff});
    const sum = try b.expr(.add, byte, try b.expr(.slot, byte, n, 0), try b.int(byte, 1));
    _ = try b.inst(.assign, try b.extraOf(Program.Place{ .kind = .slot, .a = f }), sum, 0); // pc 0
    _ = try b.inst(.stop, 0, 0, 0); // pc 1
    const subs = [_]Program.Sub{.{ .entry = 0, .function = true, .automatic = false, .first = n, .count = 2, .result = f, .ports = try b.listOf(&.{n}), .ranges = .empty }};
    const none = @backingInt(Program.Ref.none);
    const args = try b.listOf(&.{ try b.int(byte, 41), none, @bitCast(byte), 0 });
    const call = try b.expr(.call, byte, try b.extraOf(Program.Call{ .sub = 0, .args = args }), 0);
    _ = try b.inst(.task, try show(&b, "f=", call, 'd'), 0, 0); // pc 2
    _ = try b.inst(.stop, 0, 0, 0);
    try b.starts.append(a, .{ .pc = 2 });
    var p = b.finish();
    p.subs = &subs;
    try std.testing.expectEqualStrings("f=42\n", try runOf(a, &p));
}
