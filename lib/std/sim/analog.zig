//! A run beside an analog solver (the old `lib/sim/digital/analog_link.zig`):
//! the slots an analog block reads (an implicit D2A), the event terms an
//! analog event control waits on (an explicit D2A), the analog values
//! written back (A2D) and the analog events delivered to digital waiters.
//! `Interp.runUntil` stops at the marks this file queues, so the mixed
//! kernel solves at exactly those points.
//! Cites: VAMS-2023 §7.3.4, §7.3.5, §7.3.6.1, §7.3.6.4, §8.4.3, §8.4.7,
//! §8.5.1, §8.5.3.6.
//!
//! Contents:
//! - `pub const Link = struct`, `pub const D2aSite = struct`
//! - `pub fn watchAnalog(s: *State, slot: u32) Error!void`
//! - `pub fn watchEvent(s: *State, slot: u32, edge: Program.Edge, site: u6) Error!void`
//! - `pub fn changed(s: *State, slot: u32, before: Bit, after: Bit) Error!void`
//! - `pub fn requestAnalog(s: *State) Error!void`
//! - `pub fn a2dWrite(s: *State, slot: u32, v: f64, assigned: bool) Error!void`
//! - `pub fn deliverA2d(s: *State, event: u32, tick: u64) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Program = @import("Program.zig");
const State = @import("State.zig");
const logic = @import("logic.zig");
const Error = State.Error;
const Bit = logic.Bit;

/// The run's side of the analog link; empty for a plain digital run.
pub const Link = struct {
    /// Per slot: the analog block reads it outside any event guard
    /// (`watchAnalog`); empty until the first watch.
    watch: []bool = &.{},
    /// §8.5 the explicit D2A terms, and the ones that occurred this tick
    /// (bit = `D2aSite.site`).
    sites: std.ArrayList(D2aSite) = .empty,
    fired: u64 = 0,
    /// One region-3b mark per tick however many watched values moved, and
    /// one region-1b mark for the explicit terms.
    pending: bool = false,
    d2a_pending: bool = false,
    /// §7.3.3/§7.3.6.3 `V(a)` or `V(a, b)` of the analog solution at the
    /// current digital time, set by the mixed kernel; a probe without it
    /// fails the run.
    probe: ?*const fn (ctx: *anyopaque, a: []const u8, b: ?[]const u8) Error!f64 = null,
    probe_ctx: *anyopaque = undefined,
};

/// One explicit D2A term: `edge` of `slot`, reported as bit `site`.
pub const D2aSite = struct { slot: u32, edge: Program.Edge, site: u6 };

/// §8.5 / §8.4.3.2: the analog block reads `slot` outside any event guard,
/// so every change of it is an implicit D2A: from now on `runUntil` stops
/// with `.analog` in region 3b of the tick it changed in.
pub fn watchAnalog(s: *State, slot: u32) Error!void {
    assert(slot < s.p.slots.len);
    if (s.analog.watch.len == 0) {
        s.analog.watch = try s.arena.alloc(bool, s.p.slots.len);
        @memset(s.analog.watch, false);
    }
    s.analog.watch[slot] = true;
    assert(s.analog.watch.len == s.p.slots.len);
}

/// §7.3.4 / §8.5: an analog event control waits on `edge` of `slot` (a
/// variable, net or named event) as term `site`: from now on the event
/// makes `runUntil` stop with `.explicit_d2a` in region 1b of its tick,
/// bit `site` set in `Link.fired`.
pub fn watchEvent(s: *State, slot: u32, edge: Program.Edge, site: u6) Error!void {
    assert(slot < s.p.slots.len);
    const n = s.analog.sites.items.len;
    try s.analog.sites.append(s.arena, .{ .slot = slot, .edge = edge, .site = site });
    assert(s.analog.sites.items.len == n + 1);
}

/// `State.wake`'s hook: `slot` changed from `before` to `after` (bit 0), or
/// fired as a named event (`.x` to `.x`). Queues the marks the link asks for.
pub fn changed(s: *State, slot: u32, before: Bit, after: Bit) Error!void {
    assert(slot < s.p.slots.len);
    if (s.analog.watch.len != 0 and s.analog.watch[slot]) try requestAnalog(s);
    for (s.analog.sites.items) |site| {
        if (site.slot != slot or !State.matches(site.edge, before, after)) continue;
        s.analog.fired |= @as(u64, 1) << site.site;
        if (s.analog.d2a_pending) continue;
        s.analog.d2a_pending = true;
        _ = try s.mark(.explicit_d2a, .d2a_mark);
    }
    assert(!s.analog.d2a_pending or s.analog.fired != 0);
}

/// Queues this tick's region-3b analog mark, once.
pub fn requestAnalog(s: *State) Error!void {
    if (s.analog.pending) return;
    s.analog.pending = true;
    _ = try s.mark(.analog, .analog_mark);
    assert(s.analog.pending);
}

/// §7.3.6.4: an analog variable a digital expression reads takes the value
/// the analog block left it, as a write at the current tick (Table 7-1 in
/// reverse: a real as itself, an integer truncated). `assigned`: an analog
/// event statement assigned it, which §7.3.6.1 makes an event "regardless
/// of whether the variable changes value or not".
pub fn a2dWrite(s: *State, slot: u32, v: f64, assigned: bool) Error!void {
    assert(slot < s.p.slots.len);
    const ty = s.p.slots[slot].ty;
    const a = s.scratch.allocator();
    const lit = if (ty.real) try logic.realLiteral(a, v) else blk: {
        const w = try logic.filled(a, 64, true, .zero);
        w.values()[0] = @bitCast(std.math.lossyCast(i64, v));
        break :blk try logic.normalize(a, w, ty.width, ty.signed);
    };
    const word = s.p.slots[slot].word;
    const n = lit.values().len;
    const same = std.mem.eql(u64, s.v[word..][0..n], lit.values()) and std.mem.eql(u64, s.x[word..][0..n], lit.unknowns());
    try s.store(slot, lit);
    if (assigned and same) try s.trigger(slot);
}

/// §7.3.5 / §7.3.6.1: analog event `event` (the named-event slot a digital
/// `@(cross(...))` waits on) occurred: its waiters wake at `tick`, or now
/// when `tick` is not after the current time (§8.4.3.3: never before it).
pub fn deliverA2d(s: *State, event: u32, tick: u64) Error!void {
    assert(event < s.p.slots.len);
    const now = s.scheduler.now;
    _ = try s.enqueue(.{ .a2d = event }, if (tick > now) tick - now else null, false);
}

test "an implicit D2A queues one region-3b mark per tick" {
    // Oracle: VAMS §8.5.1, "one region-3b event per tick however many
    // analog-read values moved" (the old link's `pending`).
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: @import("Builder.zig") = .init(a);
    const x = try b.slot(.int(4, false), &.{0}, &.{0});
    const y = try b.slot(.int(4, false), &.{0}, &.{0});
    const p = b.finish();
    var out: std.Io.Writer.Allocating = .init(a);
    var s: State = try .init(a, &p, &out.writer);
    try watchAnalog(&s, x);
    try s.store(y, try logic.filled(a, 4, false, .one));
    try std.testing.expect(!s.analog.pending);
    try s.store(x, try logic.filled(a, 4, false, .one));
    try s.store(x, try logic.filled(a, 4, false, .zero));
    try std.testing.expect(s.analog.pending);
    try std.testing.expectEqual(.analog, try @import("Interp.zig").runUntil(&s, 0));
    try std.testing.expect(!s.analog.pending);
    try std.testing.expectEqual(.idle, try @import("Interp.zig").runUntil(&s, 0));
}

test "an explicit D2A on a posedge stops in region 1b, then 3b" {
    // Oracle: VAMS §8.5.3.6 (region 1b reports the term) and §8.4.7 (a D2A
    // event causes an analog solution at its time: 3b follows 1b); a
    // negedge is no posedge (IEEE 1364-2005 Table 9-1).
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: @import("Builder.zig") = .init(a);
    const clk = try b.slot(.bit, &.{0}, &.{0});
    const p = b.finish();
    var out: std.Io.Writer.Allocating = .init(a);
    var s: State = try .init(a, &p, &out.writer);
    try watchEvent(&s, clk, .posedge, 5);
    try s.store(clk, try logic.filled(a, 1, false, .one));
    try std.testing.expectEqual(@as(u64, 1 << 5), s.analog.fired);
    const Interp = @import("Interp.zig");
    try std.testing.expectEqual(.explicit_d2a, try Interp.runUntil(&s, 0));
    try std.testing.expectEqual(.analog, try Interp.runUntil(&s, 0));
    try std.testing.expectEqual(.idle, try Interp.runUntil(&s, 0));
    s.analog.fired = 0;
    try s.store(clk, try logic.filled(a, 1, false, .zero));
    try std.testing.expectEqual(@as(u64, 0), s.analog.fired);
    try std.testing.expectEqual(.idle, try Interp.runUntil(&s, 0));
}
