//! One run of a `Program`: the value planes, the §11 scheduler and the rows
//! its events carry, the processes suspended on event controls, and what
//! the system tasks keep across calls. `init` places the time-0 processes;
//! `Interp.run` drains the scheduler. The write path (`store`) is here, so
//! every value that lands wakes what watches it.
//! Cites: IEEE 1364-2005 §5.10.1 (edges), §6.1 (continuous fan-out), §9.2.2
//! (NBA), §9.7 (event controls), §11.4, §17.1.2, §17.1.3.
//!
//! Contents:
//! - `pub const Error = error{ SimFailed, OutOfMemory, WriteFailed }`
//! - `pub const Pending = union(enum)`, `pub const Row = struct`
//! - `pub const Susp = struct`, `pub const Term = struct`
//! - `pub const Hold = struct`, `pub const Monitor = struct`
//! - `pub const default_budget: u64`
//! - `pub fn init(arena: Allocator, p: *const Program, out: *std.Io.Writer) Error!State`
//! - `pub fn fail(s: *State, comptime f: []const u8, args: anytype) Error`
//! - `pub fn store(s: *State, slot: u32, value: Literal) Error!void`
//! - `pub fn trigger(s: *State, slot: u32) Error!void`
//! - `pub fn scheduleWrite(s: *State, slot: u32, sel: ?eval.Sel, value: Literal, delay: ?u64) Error!void`
//! - `pub fn enqueue(s: *State, item: Pending, delay: ?u64, nba: bool) Error!Handle`
//! - `pub fn enqueueMonitor(s: *State, item: Pending) Error!void`
//! - `pub fn cancel(s: *State, h: Handle) Error!void`
//! - `pub fn park(s: *State, pc: u32) Error!u32`
//! - `pub fn watch(s: *State, id: u32, t: Program.Term) Error!void`
//! - `pub fn retire(s: *State, id: u32) void`
//! - `pub fn stopRange(s: *State, start: u32, end: u32) Error!bool`
//! - `pub fn requestMonitor(s: *State) Error!void`
//! - `pub fn monitorValue(s: *State, a: Allocator, e: u32) Error![]u64`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Program = @import("Program.zig");
const logic = @import("logic.zig");
const eval = @import("eval.zig");
const sched = @import("scheduler.zig");
const fmt = @import("kernels").fmt;
const Literal = logic.Literal;
const Bit = logic.Bit;
const Scheduler = sched.Scheduler;
const Handle = sched.Handle;

/// `SimFailed`: the run stopped with a runtime error, its text in
/// `State.failure`. `WriteFailed`: the transcript writer failed.
pub const Error = error{ SimFailed, OutOfMemory, WriteFailed };

/// One scheduled event's payload, consumed whole by its dispatch.
pub const Pending = union(enum) {
    /// Run the process continuing at this pc.
    run: u32,
    /// §9.2.2 a nonblocking update landing in `slot` (its `sel` bits only);
    /// the value is the row's own `buf`.
    write: struct { slot: u32, sel: ?eval.Sel, width: u32, signed: bool },
    /// §17.1.2 one `$strobe`: show row `show`, evaluated in the monitor region.
    strobe: u32,
    /// §17.1.3 the standing monitor's end-of-step check, one per step.
    monitor_tick,
};

/// One payload row, recycled once its event dispatches or is cancelled.
pub const Row = struct {
    item: Pending,
    handle: Handle = undefined,
    buf: []u64 = &.{},
};

/// A process suspended on an event control: where it resumes. Its terms
/// name this row and go stale together when `gen` moves on.
pub const Susp = struct { pc: u32, gen: u32, alive: bool };

/// One term of a suspension, filed under the slot it watches. A select term
/// (`width != 0`) remembers its bits when last tested (`v`, `x`).
pub const Term = struct {
    susp: u32,
    gen: u32,
    edge: Program.Edge,
    lo: u32 = 0,
    width: u32 = 0,
    v: u64 = 0,
    x: u64 = 0,
};

/// §8.5.3.3 one parked right-hand side.
pub const Hold = struct { planes: []u64 = &.{}, width: u32 = 0, signed: bool = false };

/// §17.1.3 the standing monitor: its `Program.Monitor` and what each
/// compared argument read when last evaluated.
pub const Monitor = struct {
    m: Program.Monitor,
    values: [][]u64,
};

/// Events at one tick (and untimed loop passes) before a zero-delay loop
/// is refused by name.
pub const default_budget: u64 = 10_000_000;

p: *const Program,
arena: Allocator,
out: *std.Io.Writer,
v: []u64,
x: []u64,
scheduler: Scheduler = .empty,
rows: std.ArrayList(Row) = .empty,
free_rows: std.ArrayList(u32) = .empty,
susps: std.ArrayList(Susp) = .empty,
free_susps: std.ArrayList(u32) = .empty,
/// Per slot, the terms of the event controls waiting on it.
terms: []std.ArrayList(Term),
/// Per pc of a continuous driver: suspended on its operands now.
armed: []bool,
counters: []u64,
holds: []Hold,
/// Per slot: a standing monitor argument reads it.
monitored: []bool,
monitor: ?Monitor = null,
monitor_on: bool = true,
monitor_pending: bool = false,
monitor_hit: bool = false,
monitor_evaluating: bool = false,
time_format: fmt.TimeFormat = .{},
/// The events dispatched at `budget_time`, against `budget`.
budget: u64 = default_budget,
budget_time: u64 = 0,
budget_used: u64 = 0,
/// The runtime error that ended the run (`fail`).
failure: ?[]const u8 = null,
/// Per-instruction temporaries, reset before each.
scratch: std.heap.ArenaAllocator,

const State = @This();

/// A run of `p` at time 0: every slot at its initial value and every
/// time-0 process queued in order. `arena` owns everything and must outlive
/// the `State`; `out` takes the transcript.
pub fn init(arena: Allocator, p: *const Program, out: *std.Io.Writer) Error!State {
    assert(p.inst_scope.len == p.insts.len);
    assert(p.init_v.len == p.init_x.len);
    var s: State = .{
        .p = p,
        .arena = arena,
        .out = out,
        .v = try arena.dupe(u64, p.init_v),
        .x = try arena.dupe(u64, p.init_x),
        .terms = try arena.alloc(std.ArrayList(Term), p.slots.len),
        .armed = try arena.alloc(bool, p.insts.len),
        .counters = try arena.alloc(u64, p.counters),
        .holds = try arena.alloc(Hold, p.holds),
        .monitored = try arena.alloc(bool, p.slots.len),
        .scratch = .init(arena),
    };
    @memset(s.terms, .empty);
    @memset(s.armed, false);
    @memset(s.counters, 0);
    @memset(s.holds, .{});
    @memset(s.monitored, false);
    s.time_format = .{ .units = p.finest };
    for (p.starts) |st| _ = try s.enqueue(.{ .run = st.pc }, null, false);
    assert(s.scheduler.now == 0);
    return s;
}

/// Ends the run with a runtime error: its text kept in `failure`.
pub fn fail(s: *State, comptime f: []const u8, args: anytype) Error {
    assert(s.failure == null);
    s.failure = try std.fmt.allocPrint(s.arena, f, args);
    return error.SimFailed;
}

/// Stores `value` (as wide as the slot) into `slot` and wakes what watches
/// it: the one write path. A real changes when its value does (-0.0 over
/// +0.0 is no change, but the bits are stored).
pub fn store(s: *State, slot: u32, value: Literal) Error!void {
    const sl = s.p.slots.get(slot);
    const n = Program.words(sl.ty.width);
    assert(value.planes.len == 2 * n);
    const v = s.v[sl.word..][0..n];
    const x = s.x[sl.word..][0..n];
    const before = logic.planeBit(v[0], x[0]);
    const differ = !std.mem.eql(u64, v, value.values()) or !std.mem.eql(u64, x, value.unknowns());
    const changed = if (sl.ty.real) @as(f64, @bitCast(v[0])) != @as(f64, @bitCast(value.values()[0])) else differ;
    if (differ) {
        @memcpy(v, value.values());
        @memcpy(x, value.unknowns());
    }
    if (!changed) return;
    if (s.monitored[slot]) try monitorChanged(s, slot);
    try wake(s, slot, before, logic.planeBit(v[0], x[0]));
}

/// §5.10.4 `-> e`: resume what waits on named event `slot`.
pub fn trigger(s: *State, slot: u32) Error!void {
    assert(slot < s.p.slots.len);
    return wake(s, slot, .x, .x);
}

/// Queues a §9.2.2 nonblocking update of `slot` (its `sel` bits) with
/// `value`, now or `delay` ticks later. The value is copied into the row.
pub fn scheduleWrite(s: *State, slot: u32, sel: ?eval.Sel, value: Literal, delay: ?u64) Error!void {
    assert(slot < s.p.slots.len);
    _ = try s.enqueueBuf(.{ .write = .{ .slot = slot, .sel = sel, .width = value.width, .signed = value.signed } }, value.planes, delay, true);
}

/// Queues `item` now (active, or NBA when `nba`) or `delay` ticks later.
pub fn enqueue(s: *State, item: Pending, delay: ?u64, nba: bool) Error!Handle {
    assert(item != .write);
    return enqueueBuf(s, item, &.{}, delay, nba);
}

/// Queues `item` in the current step's monitor region.
pub fn enqueueMonitor(s: *State, item: Pending) Error!void {
    const at = try claim(s, item, &.{});
    s.rows.items[at].handle = s.scheduler.schedule(s.arena, .monitor, at) catch |e| return schedFail(s, e);
}

/// Cancels one queued event; a stale handle is a no-op.
pub fn cancel(s: *State, h: Handle) Error!void {
    const row = s.scheduler.payloadOf(h) orelse return;
    _ = s.scheduler.cancel(h) catch |e| return schedFail(s, e);
    try s.free_rows.append(s.arena, row);
}

/// Suspends the running process at `pc` (§9.7); file its terms with `watch`
/// under the id returned.
pub fn park(s: *State, pc: u32) Error!u32 {
    const id = s.free_susps.pop() orelse blk: {
        try s.susps.append(s.arena, .{ .pc = 0, .gen = 0, .alive = false });
        try s.free_susps.ensureTotalCapacity(s.arena, s.susps.items.len);
        break :blk @as(u32, @intCast(s.susps.items.len - 1));
    };
    const su = &s.susps.items[id];
    assert(!su.alive);
    su.pc = pc;
    su.alive = true;
    return id;
}

/// Files term `t` of suspension `id` under its slot; a select term
/// remembers its bits now.
pub fn watch(s: *State, id: u32, t: Program.Term) Error!void {
    assert(s.susps.items[id].alive);
    var term: Term = .{ .susp = id, .gen = s.susps.items[id].gen, .edge = t.edge, .lo = t.lo, .width = t.width };
    if (t.width != 0) {
        const now = termBits(s, t.slot, t.lo, t.width);
        term.v = now[0];
        term.x = now[1];
    }
    try s.terms[t.slot].append(s.arena, term);
}

/// Suspension `id` no longer waits: its terms go stale and its row is free.
pub fn retire(s: *State, id: u32) void {
    const su = &s.susps.items[id];
    assert(su.alive);
    su.alive = false;
    su.gen +%= 1;
    s.free_susps.appendAssumeCapacity(id);
}

/// Drops every resumption point in [start, end): parked waiters and queued
/// `.run` rows. Whether anything was.
pub fn stopRange(s: *State, start: u32, end: u32) Error!bool {
    var hit = false;
    for (s.susps.items, 0..) |su, id| if (su.alive and su.pc >= start and su.pc < end) {
        retire(s, @intCast(id));
        hit = true;
    };
    for (s.rows.items) |row| switch (row.item) {
        .run => |at| if (at >= start and at < end and s.scheduler.payloadOf(row.handle) != null) {
            try cancel(s, row.handle);
            hit = true;
        },
        .write, .strobe, .monitor_tick => {},
    };
    return hit;
}

/// §17.1.3 one end-of-step monitor check, however many values moved.
pub fn requestMonitor(s: *State) Error!void {
    if (s.monitor == null or !s.monitor_on or s.monitor_pending) return;
    s.monitor_pending = true;
    try enqueueMonitor(s, .monitor_tick);
}

/// A compared monitor argument's value as the planes compared: a real by
/// value (0.0 for either zero).
pub fn monitorValue(s: *State, a: Allocator, e: u32) Error![]u64 {
    if (s.p.exprs.items(.ty)[e].real) {
        const r = try eval.real(s, a, e);
        const out = try a.alloc(u64, 1);
        out[0] = @bitCast(if (r == 0) 0 else r);
        return out;
    }
    return (try eval.eval(s, a, e)).planes;
}

// ---- private ----

fn enqueueBuf(s: *State, item: Pending, planes: []const u64, delay: ?u64, nba: bool) Error!Handle {
    const at = try claim(s, item, planes);
    const h = (if (delay) |d|
        s.scheduler.scheduleAfter(s.arena, d, if (nba) .nba else .inactive, at)
    else
        s.scheduler.schedule(s.arena, if (nba) .nba else .active, at)) catch |e| return schedFail(s, e);
    s.rows.items[at].handle = h;
    return h;
}

fn claim(s: *State, item: Pending, planes: []const u64) Error!u32 {
    const at: u32 = s.free_rows.pop() orelse blk: {
        try s.rows.append(s.arena, .{ .item = item });
        break :blk @intCast(s.rows.items.len - 1);
    };
    const row = &s.rows.items[at];
    row.item = item;
    if (planes.len != 0) {
        if (row.buf.len < planes.len) row.buf = try s.arena.alloc(u64, planes.len);
        @memcpy(row.buf[0..planes.len], planes);
    }
    return at;
}

fn schedFail(s: *State, e: anyerror) Error {
    if (e == error.OutOfMemory) return error.OutOfMemory;
    return s.fail("digital scheduling failure: {t}", .{e});
}

/// Resumes the continuous drivers reading `slot`, then every suspension on
/// it whose edge matches, in the order they suspended.
fn wake(s: *State, slot: u32, before: Bit, after: Bit) Error!void {
    const p = s.p;
    if (slot + 1 < p.fan_start.len) for (p.fan[p.fan_start[slot]..p.fan_start[slot + 1]]) |pc| if (s.armed[pc]) {
        s.armed[pc] = false;
        _ = try enqueue(s, .{ .run = pc }, null, false);
    };
    const list = &s.terms[slot];
    var keep: usize = 0;
    for (list.items, 0..) |t, i| {
        assert(keep <= i);
        const su = &s.susps.items[t.susp];
        if (su.gen != t.gen) continue;
        const hit = if (t.width == 0) matches(t.edge, before, after) else selectChanged(s, &list.items[i], slot);
        if (!hit) {
            list.items[keep] = list.items[i];
            keep += 1;
            continue;
        }
        const pc = su.pc;
        retire(s, t.susp);
        _ = try enqueue(s, .{ .run = pc }, null, false);
    }
    list.shrinkRetainingCapacity(keep);
}

/// §9.7.2 Table 9-1: `any` is every change (the caller proved one).
fn matches(edge: Program.Edge, before: Bit, after: Bit) bool {
    if (edge == .any) return true;
    if (before == after) return false;
    return switch (edge) {
        .posedge => before == .zero or after == .one,
        .negedge => before == .one or after == .zero,
        .any => unreachable,
    };
}

fn selectChanged(s: *State, t: *Term, slot: u32) bool {
    const now = termBits(s, slot, t.lo, t.width);
    if (now[0] == t.v and now[1] == t.x) return false;
    const before = logic.planeBit(t.v, t.x);
    const after = logic.planeBit(now[0], now[1]);
    t.v = now[0];
    t.x = now[1];
    return matches(t.edge, before, after);
}

/// Bits [lo, lo + width) of `slot`, width at most 64, as (v, x) words.
fn termBits(s: *const State, slot: u32, lo: u32, width: u32) [2]u64 {
    const sl = s.p.slots.get(slot);
    const n = Program.words(sl.ty.width);
    assert(lo / 64 < n);
    var out: [2]u64 = undefined;
    for ([_][]const u64{ s.v[sl.word..][0..n], s.x[sl.word..][0..n] }, &out) |plane, *o| {
        const w = lo / 64;
        const sh: u6 = @intCast(lo % 64);
        var bits = plane[w] >> sh;
        if (sh != 0 and w + 1 < plane.len) bits |= plane[w + 1] << @intCast(64 - @as(u7, sh));
        o.* = bits & logic.wordMask(width, 0);
    }
    return out;
}

/// A slot the standing monitor reads changed: a loose slot, or a compared
/// argument whose value moved (each keeps its new value), makes the report
/// due. A store its own evaluation makes asks nothing again.
fn monitorChanged(s: *State, slot: u32) Error!void {
    if (s.monitor_evaluating) return;
    s.monitor_evaluating = true;
    defer s.monitor_evaluating = false;
    const m = s.monitor orelse return;
    var tmp: std.heap.ArenaAllocator = .init(s.arena);
    defer tmp.deinit();
    const moved = moved: {
        if (std.mem.findScalar(u32, s.p.list(m.m.loose), slot) != null) break :moved true;
        var any = false;
        for (s.p.list(m.m.compared), m.values) |e, old| {
            const now = try monitorValue(s, tmp.allocator(), e);
            if (std.mem.eql(u64, old, now)) continue;
            any = true;
            @memcpy(old, now);
        }
        break :moved any;
    };
    if (moved and s.monitor_on) {
        s.monitor_hit = true;
        try requestMonitor(s);
    }
}
