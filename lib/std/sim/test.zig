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
const net = sim.net;

/// One continuous assignment of 1-bit slot `reg` to net `net` at strengths
/// (`s0`, `s1`).
const Drive = struct { net: u32, reg: u32, s0: net.Strength = .strong, s1: net.Strength = .strong };

/// What `netlist` sets on the finished program.
const Netlist = struct {
    nets: []const Program.Net,
    drivers: []const Program.Driver,
    driver_init: []const u64,
    fan_start: []const u32,
    fan: []const u32,

    fn wire(n: Netlist, p: *Program) void {
        p.nets = n.nets;
        p.drivers = n.drivers;
        p.driver_init = n.driver_init;
        p.fan_start = n.fan_start;
        p.fan = n.fan;
    }
};

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

/// A show row of `format` (text with `%b`, `%d` or `%0d`, each taking the
/// next of `args`), ending its line.
fn showRow(b: *Builder, format: []const u8, args: []const u32) !u32 {
    var ids: std.ArrayList(u32) = .empty;
    var next: usize = 0;
    var i: usize = 0;
    var text_start: usize = 0;
    while (i <= format.len) : (i += 1) {
        if (i < format.len and format[i] != '%') continue;
        if (i > text_start) {
            const t = try b.string(format[text_start..i]);
            try b.pieces.append(b.arena, .{ .kind = .text, .a = t.start, .width = t.len });
            try ids.append(b.arena, @intCast(b.pieces.items.len - 1));
        }
        if (i == format.len) break;
        const zero = format[i + 1] == '0';
        i += if (zero) 2 else 1;
        try b.pieces.append(b.arena, .{ .kind = .spec, .conv = format[i], .a = args[next], .width = if (zero) 0 else Program.Piece.none_width });
        try ids.append(b.arena, @intCast(b.pieces.items.len - 1));
        next += 1;
        text_start = i + 1;
    }
    std.debug.assert(next == args.len);
    try b.shows.append(b.arena, .{ .pieces = try b.listOf(ids.items), .radix = .decimal, .newline = true, .scope = 0 });
    return @intCast(b.shows.items.len - 1);
}

/// `showRow` as a `$display` task.
fn display(b: *Builder, format: []const u8, args: []const u32) !u32 {
    return b.extraOf(Program.Task{ .kind = .show, .a = try showRow(b, format, args) });
}

fn assign(b: *Builder, tag: Program.Inst.Tag, slot: u32, value: u32) !void {
    _ = try b.inst(tag, try b.extraOf(Program.Place{ .kind = .slot, .a = slot }), value, 0);
}

fn delay(b: *Builder, ticks: u64) !void {
    _ = try b.inst(.delay, try b.int(Ty.int(32, true), ticks), 0, 0);
}

/// `$finish(0)`: no message, the rest of the step runs.
fn finish(b: *Builder) !void {
    _ = try b.inst(.task, try b.extraOf(Program.Task{ .kind = .finish, .a = try b.int(Ty.int(32, true), 0), .b = try b.string("here") }), 0, 0);
    _ = try b.inst(.stop, 0, 0, 0);
}

/// A 1-bit slot starting at x.
fn reg(b: *Builder) !u32 {
    return b.slot(Ty.int(1, false), &.{1}, &.{1});
}

/// A 1-bit constant: '0', '1', 'x' or 'z'.
fn bitOf(b: *Builder, c: u8) !u32 {
    const v: u64 = @intFromBool(c == '1' or c == 'x');
    const x: u64 = @intFromBool(c == 'x' or c == 'z');
    return b.constant(Ty.int(1, false), &.{v}, &.{x});
}

/// A read row of each 1-bit slot.
fn reads(b: *Builder, slots: []const u32) ![]const u32 {
    const out = try b.arena.alloc(u32, slots.len);
    for (out, slots) |*e, s| e.* = try b.expr(.slot, Ty.int(1, false), s, 0);
    return out;
}

/// Nets of `kinds` over 1-bit `slots`, driven by `ds`: driver k is a
/// `.continuous` process at pc k, started at time 0 before every later one
/// and re-run on its reg's change. Call before any other instruction; the
/// next pc starts too.
fn netlist(b: *Builder, kinds: []const net.NetKind, slots: []const u32, ds: []const Drive) !Netlist {
    const none = @backingInt(Program.Ref.none);
    std.debug.assert(b.p.insts.len == 0);
    const nets = try b.arena.alloc(Program.Net, kinds.len);
    for (nets, kinds, slots, 0..) |*n, kind, slot, k| {
        var mine: std.ArrayList(u32) = .empty;
        for (ds, 0..) |d, j| if (d.net == k) try mine.append(b.arena, @intCast(j));
        n.* = .{ .kind = kind, .charge = .medium, .slot = slot, .drivers = try b.listOf(mine.items), .delay = .{}, .decay = Program.Net.no_decay };
    }
    const drivers = try b.arena.alloc(Program.Driver, ds.len);
    const init = try b.arena.alloc(u64, 2 * ds.len);
    for (drivers, ds, 0..) |*dr, d, k| {
        const value = try b.expr(.slot, Ty.int(1, false), d.reg, 0);
        dr.* = .{ .net = d.net, .scope = 0, .s0 = d.s0, .s1 = d.s1, .delay = .{}, .delay_rows = @splat(none), .width = 1, .init = @intCast(2 * k), .init_or_z = false, .source = .{ .expr = .{ .value = value, .slice = false, .lo = 0, .total = 0 } } };
        init[2 * k] = 0; // z until the driver first runs
        init[2 * k + 1] = 1;
        _ = try b.inst(.continuous, @intCast(k), 0, 0);
        try b.starts.append(b.arena, .{ .pc = @intCast(k) });
    }
    try b.starts.append(b.arena, .{ .pc = @intCast(ds.len) });
    // Per slot, the driver pcs that read it.
    const fan_start = try b.arena.alloc(u32, b.p.slots.len + 1);
    var fan: std.ArrayList(u32) = .empty;
    for (0..b.p.slots.len) |slot| {
        fan_start[slot] = @intCast(fan.items.len);
        for (ds, 0..) |d, k| if (d.reg == slot) try fan.append(b.arena, @intCast(k));
    }
    fan_start[b.p.slots.len] = @intCast(fan.items.len);
    return .{ .nets = nets, .drivers = drivers, .driver_init = init, .fan_start = fan_start, .fan = fan.items };
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
    const terms = try b.listOf(&.{ c, @backingInt(Program.Edge.posedge), 0, 0, std.math.maxInt(u32) });
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

// §11 scheduling regions and §7 net resolution, ported from the old
// engine's tests (lib/sim exec.zig, monitor.zig, signal.zig), each held to
// the transcript its Verilog source gave there.

test "§11.4 #0 resumes in the inactive region, before the nonblocking updates land" {
    // exec.zig "source processes suspend at zero delay and NBA captures RHS
    // in lexical order":
    //   initial begin
    //     $display("initial %b",a); a = 1; b <= a; b <= 3; a = 2;
    //     #0 $display("inactive %b %b",a,b);
    //     #1 $display("after %b %b",a,b); $finish(0);
    //   end
    //   initial begin #0 $display("peer %b",a); end
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = try start(a);
    const nib = Ty.int(4, false);
    const ra = try b.slot(nib, &.{0xf}, &.{0xf});
    const rb = try b.slot(nib, &.{0xf}, &.{0xf});
    const va = try b.expr(.slot, nib, ra, 0);
    const vb = try b.expr(.slot, nib, rb, 0);
    _ = try b.inst(.task, try display(&b, "initial %b", &.{va}), 0, 0);
    try assign(&b, .assign, ra, try b.int(nib, 1));
    try assign(&b, .assign_nb, rb, va);
    try assign(&b, .assign_nb, rb, try b.int(nib, 3));
    try assign(&b, .assign, ra, try b.int(nib, 2));
    try delay(&b, 0);
    _ = try b.inst(.task, try display(&b, "inactive %b %b", &.{ va, vb }), 0, 0);
    try delay(&b, 1);
    _ = try b.inst(.task, try display(&b, "after %b %b", &.{ va, vb }), 0, 0);
    try finish(&b);
    const peer: u32 = @intCast(b.p.insts.len);
    try delay(&b, 0);
    _ = try b.inst(.task, try display(&b, "peer %b", &.{va}), 0, 0);
    _ = try b.inst(.stop, 0, 0, 0);
    try b.starts.appendSlice(a, &.{ .{ .pc = 0 }, .{ .pc = peer } });
    const p = b.finish();
    try std.testing.expectEqualStrings("initial xxxx\ninactive 0010 xxxx\npeer 0010\nafter 0010 0011\n", try runOf(a, &p));
}

test "§9.7.1 an x delay is zero; §17.4.1 $finish ends the run before a later process" {
    // exec.zig "unknown delay is zero and finish discards pending later
    // processes": a = 0; a <= 1; #(1'bx) shows 0 (the NBA has not landed),
    // #1 shows 1, then $finish(0) at 1 before the other process's #2.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = try start(a);
    const bit = Ty.int(1, false);
    const r = try b.slot(bit, &.{1}, &.{1});
    const v = try b.expr(.slot, bit, r, 0);
    try assign(&b, .assign, r, try b.int(bit, 0));
    try assign(&b, .assign_nb, r, try b.int(bit, 1));
    _ = try b.inst(.delay, try bitOf(&b, 'x'), 0, 0);
    _ = try b.inst(.task, try display(&b, "unknown-delay %b", &.{v}), 0, 0);
    try delay(&b, 1);
    _ = try b.inst(.task, try display(&b, "later %b", &.{v}), 0, 0);
    try finish(&b);
    const other: u32 = @intCast(b.p.insts.len);
    try delay(&b, 2);
    _ = try b.inst(.task, try display(&b, "not run", &.{}), 0, 0);
    _ = try b.inst(.stop, 0, 0, 0);
    try b.starts.appendSlice(a, &.{ .{ .pc = 0 }, .{ .pc = other } });
    const p = b.finish();
    try std.testing.expectEqualStrings("unknown-delay 0\nlater 1\n", try runOf(a, &p));
}

test "§17.1.2 $strobe shows the end of its step, after the nonblocking updates" {
    // a = 1; $strobe("strobe %0d", a); $display("display %0d", a); a <= 2;
    // The clause: $strobe displays "at the end of the current time step",
    // past §11.4's NBA region; $display shows the value now.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = try start(a);
    const ty = Ty.int(4, false);
    const r = try b.slot(ty, &.{0xf}, &.{0xf});
    const v = try b.expr(.slot, ty, r, 0);
    try assign(&b, .assign, r, try b.int(ty, 1));
    _ = try b.inst(.task, try b.extraOf(Program.Task{ .kind = .strobe, .a = try showRow(&b, "strobe %0d", &.{v}) }), 0, 0);
    _ = try b.inst(.task, try display(&b, "display %0d", &.{v}), 0, 0);
    try assign(&b, .assign_nb, r, try b.int(ty, 2));
    _ = try b.inst(.stop, 0, 0, 0);
    try b.starts.append(a, .{ .pc = 0 });
    const p = b.finish();
    try std.testing.expectEqualStrings("display 1\nstrobe 2\n", try runOf(a, &p));
}

test "§17.1.3 the monitor reports once per step on a value change, never on time alone" {
    // monitor.zig "clock queries do not trigger, a change and change back
    // does": a = 0; u = 0; $monitor("a=%b t=%0d", a, $time); a <= 0;
    // #1 u = 1; #1 a = 1; #0 a = 0; #1 a = 1; #1 $monitoron; #1 $finish(0);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = try start(a);
    const bit = Ty.int(1, false);
    const ra = try reg(&b);
    const ru = try reg(&b);
    const va = try b.expr(.slot, bit, ra, 0);
    const now = try b.expr(.time, Ty.int(64, false), 0, 0);
    try assign(&b, .assign, ra, try b.int(bit, 0));
    try assign(&b, .assign, ru, try b.int(bit, 0));
    const m = try b.extraOf(Program.Monitor{
        .show = try showRow(&b, "a=%b t=%0d", &.{ va, now }),
        .compared = try b.listOf(&.{va}),
        .slots = try b.listOf(&.{ra}),
        .loose = .empty,
        .fd = @backingInt(Program.Ref.none),
    });
    _ = try b.inst(.task, try b.extraOf(Program.Task{ .kind = .monitor, .a = m }), 0, 0);
    try assign(&b, .assign_nb, ra, try b.int(bit, 0));
    try delay(&b, 1);
    try assign(&b, .assign, ru, try b.int(bit, 1));
    try delay(&b, 1);
    try assign(&b, .assign, ra, try b.int(bit, 1));
    try delay(&b, 0);
    try assign(&b, .assign, ra, try b.int(bit, 0));
    try delay(&b, 1);
    try assign(&b, .assign, ra, try b.int(bit, 1));
    try delay(&b, 1);
    _ = try b.inst(.task, try b.extraOf(Program.Task{ .kind = .monitor_on, .a = 0 }), 0, 0);
    try delay(&b, 1);
    try finish(&b);
    try b.starts.append(a, .{ .pc = 0 });
    const p = b.finish();
    try std.testing.expectEqualStrings("a=0 t=0\na=0 t=2\na=1 t=3\na=1 t=4\n", try runOf(a, &p));
}

test "§7.10 a drive strength decides between disagreeing drivers; a tri0 pulls what none drives" {
    // signal.zig "a drive strength decides which of two disagreeing drivers
    // the net shows": assign (strong1, strong0) w = a, t = a;
    // assign (weak1, weak0) w = b; `t` a tri0; then a, b = 1, 0; 0, 1;
    // x; z, each shown a tick later.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = try start(a);
    const ra = try reg(&b);
    const rb = try reg(&b);
    const nets = [_]u32{ try reg(&b), try reg(&b) };
    const n = try netlist(&b, &.{ .wire, .tri0 }, &nets, &.{
        .{ .net = 0, .reg = ra },
        .{ .net = 1, .reg = ra },
        .{ .net = 0, .reg = rb, .s0 = .weak, .s1 = .weak },
    });
    const shown = try reads(&b, &nets);
    const steps = [_]struct { u8, u8, []const u8 }{
        .{ '1', '0', "6v3 %b %b" },
        .{ '0', '1', "3v6 %b %b" },
        .{ 'x', '1', "ambiguous %b %b" },
        .{ 'z', '1', "removed %b %b" },
    };
    for (steps) |st| {
        try assign(&b, .assign, ra, try bitOf(&b, st[0]));
        try assign(&b, .assign, rb, try bitOf(&b, st[1]));
        try delay(&b, 1);
        _ = try b.inst(.task, try display(&b, st[2], shown), 0, 0);
    }
    try finish(&b);
    var p = b.finish();
    n.wire(&p);
    try std.testing.expectEqualStrings("6v3 1 1\n3v6 0 0\nambiguous x x\nremoved 1 0\n", try runOf(a, &p));
}

test "§7.9 a highz half asserts nothing: the plain wire and the wand both ignore it" {
    // signal.zig "a highz half suppresses that polarity outright, wired
    // logic included": assign (strong1, highz0) w = a, wa = a;
    // assign (weak1, weak0) w = b, wa = b; a = 0 and b = 1, 0, z.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = try start(a);
    const ra = try reg(&b);
    const rb = try reg(&b);
    const nets = [_]u32{ try reg(&b), try reg(&b) };
    const n = try netlist(&b, &.{ .wire, .wand }, &nets, &.{
        .{ .net = 0, .reg = ra, .s0 = .highz },
        .{ .net = 1, .reg = ra, .s0 = .highz },
        .{ .net = 0, .reg = rb, .s0 = .weak, .s1 = .weak },
        .{ .net = 1, .reg = rb, .s0 = .weak, .s1 = .weak },
    });
    const shown = try reads(&b, &nets);
    const steps = [_]struct { u8, []const u8 }{
        .{ '1', "open_drain %b %b" },
        .{ '0', "weak_zero %b %b" },
        .{ 'z', "nothing_left %b %b" },
    };
    for (steps) |st| {
        try assign(&b, .assign, ra, try bitOf(&b, '0'));
        try assign(&b, .assign, rb, try bitOf(&b, st[0]));
        try delay(&b, 1);
        _ = try b.inst(.task, try display(&b, st[1], shown), 0, 0);
    }
    try finish(&b);
    var p = b.finish();
    n.wire(&p);
    try std.testing.expectEqualStrings("open_drain 1 1\nweak_zero 0 0\nnothing_left z z\n", try runOf(a, &p));
}

test "§7.10 a supply net outranks a strong driver and ties a supply one" {
    // signal.zig "a supply net outranks every strength an assign can write
    // but its own": supply1 vdd, v2; assign (strong1, strong0) vdd = a;
    // assign (supply1, supply0) v2 = a; a = 0, then 1.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = try start(a);
    const ra = try reg(&b);
    const nets = [_]u32{ try reg(&b), try reg(&b) };
    const n = try netlist(&b, &.{ .supply1, .supply1 }, &nets, &.{
        .{ .net = 0, .reg = ra },
        .{ .net = 1, .reg = ra, .s0 = .supply, .s1 = .supply },
    });
    const shown = try reads(&b, &nets);
    const steps = [_]struct { u8, []const u8 }{ .{ '0', "zero %b %b" }, .{ '1', "one %b %b" } };
    for (steps) |st| {
        try assign(&b, .assign, ra, try bitOf(&b, st[0]));
        try delay(&b, 1);
        _ = try b.inst(.task, try display(&b, st[1], shown), 0, 0);
    }
    try finish(&b);
    var p = b.finish();
    n.wire(&p);
    try std.testing.expectEqualStrings("zero 1 x\none 1 1\n", try runOf(a, &p));
}

test "§3.7 pull, supply and trireg nets supply what no driver does" {
    // signal.zig "the pull supply and capacitive net types supply what no
    // driver did": tri0 t0, tri1 t1, supply0 s0, supply1 s1, trireg c, each
    // assigned d; d = x, then 0, then z.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = try start(a);
    const d = try reg(&b);
    var nets: [5]u32 = undefined;
    for (&nets) |*s| s.* = try reg(&b);
    var ds: [5]Drive = undefined;
    for (&ds, 0..) |*x, k| x.* = .{ .net = @intCast(k), .reg = d };
    const n = try netlist(&b, &.{ .tri0, .tri1, .supply0, .supply1, .trireg }, &nets, &ds);
    const shown = try reads(&b, &nets);
    _ = try b.inst(.task, try display(&b, "start %b %b %b %b %b", shown), 0, 0);
    try assign(&b, .assign, d, try bitOf(&b, '0'));
    try delay(&b, 1);
    _ = try b.inst(.task, try display(&b, "zero  %b %b %b %b %b", shown), 0, 0);
    try assign(&b, .assign, d, try bitOf(&b, 'z'));
    try delay(&b, 1);
    _ = try b.inst(.task, try display(&b, "float %b %b %b %b %b", shown), 0, 0);
    try finish(&b);
    var p = b.finish();
    n.wire(&p);
    try std.testing.expectEqualStrings("start x x 0 1 x\nzero  0 0 0 1 0\nfloat 0 1 0 1 0\n", try runOf(a, &p));
}
