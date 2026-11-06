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
//! - `pub const Susp = struct`, `pub const Act = struct`, `pub const Term = struct`
//! - `pub const Hold = struct`, `pub const Monitor = struct`, `pub const PathEdge = struct`
//! - `pub const default_budget: u64`, `pub const default_depth: u32`
//! - `pub fn init(arena: Allocator, p: *const Program, out: *std.Io.Writer) Error!State`
//! - `pub fn fail(s: *State, comptime f: []const u8, args: anytype) Error`
//! - `pub fn netOf(s: *const State, slot: u32) ?u32`
//! - `pub fn warn(s: *State, comptime f: []const u8, args: anytype) Error!void`
//! - `pub fn store(s: *State, slot: u32, value: Literal) Error!void`
//! - `pub fn trigger(s: *State, slot: u32) Error!void`
//! - `pub fn scheduleWrite(s: *State, slot: u32, sel: ?eval.Sel, value: Literal, delay: ?u64) Error!void`
//! - `pub fn schedulePut(s: *State, slot: u32, value: Literal, delay: u64) Error!void`
//! - `pub fn enqueue(s: *State, item: Pending, delay: ?u64, nba: bool) Error!Handle`
//! - `pub fn enqueueMonitor(s: *State, item: Pending) Error!void`
//! - `pub fn mark(s: *State, region: sched.Region, item: Pending) Error!Handle`
//! - `pub fn cancel(s: *State, h: Handle) Error!void`
//! - `pub fn park(s: *State, pc: u32) Error!u32`
//! - `pub fn watch(s: *State, id: u32, t: Program.Term) Error!void`
//! - `pub fn retire(s: *State, id: u32) void`
//! - `pub fn stopRange(s: *State, start: u32, end: u32) Error!bool`
//! - `pub fn resumption(pc: u32, ctx: u32) Pending`
//! - `pub fn requestMonitor(s: *State, file: bool) Error!void`
//! - `pub fn termBits(s: *const State, slot: u32, lo: u32, width: u32) [2]u64`
//! - `pub fn monitorValue(s: *State, a: Allocator, e: u32) Error![]u64`
//! - `pub fn matches(edge: Program.Edge, before: Bit, after: Bit) bool`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Program = @import("Program.zig");
const logic = @import("logic.zig");
const eval = @import("eval.zig");
const driver_access = @import("driver_access.zig");
const resolve = @import("resolve.zig");
const hold = @import("holds.zig");
const tchk = @import("tchk.zig");
const activations = @import("activations.zig");
const queue = @import("queues.zig");
const vcd = @import("vcd.zig");
const evcd = @import("evcd.zig");
const net = @import("net.zig");
const sched = @import("scheduler.zig");
const analog_link = @import("analog.zig");
const kernels = @import("kernels");
const fmt = kernels.fmt;
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
    /// Run the process continuing at `pc` inside timed activation `ctx`.
    run_in: struct { pc: u32, ctx: u32 },
    /// §9.2.2 a nonblocking update landing in `slot` (its `sel` bits only);
    /// the value is the row's own `buf`.
    write: struct { slot: u32, sel: ?eval.Sel, width: u32, signed: bool },
    /// §17.1.2 one `$strobe`: show row `show`, evaluated in the monitor region.
    strobe: u32,
    /// §17.2.2 one `$fstrobe`: the `Program.FShow` at this `extra` index.
    fstrobe: u32,
    /// §17.1.3 the standing monitor's end-of-step check, one per step.
    monitor_tick,
    /// §18.1.4 the value change dump's end-of-step section, one per step.
    vcd_tick,
    /// §6.1.3 driver `drive`'s delayed transition lands.
    drive: u32,
    /// A.2.1.3 a net's own delayed transition lands.
    net_update: u32,
    /// §3.8 a trireg's charge decays to x.
    decay: u32,
    /// §7.6 a delayed switch reaching its target conduction.
    tran_switch: u32,
    /// §15.3.2 a skew check's timer (or §15.3.6's deferred data event),
    /// stale unless the check's generation is still `gen`.
    tchk_expiry: struct { check: u32, gen: u32 },
    /// §15.5.1 a change reaching its check through a delayed signal.
    tchk_event: struct { code: u32, bit: u8 },
    /// §14.6 a module path destination's value landing as a plain write
    /// (`slot`, its planes the row's `buf`).
    put: struct { slot: u32, width: u32 },
    /// VAMS §8.5.1 region 3b: `runUntil` stops with `.analog` (analog.zig).
    analog_mark,
    /// VAMS §8.5.3.6 region 1b: `runUntil` stops with `.explicit_d2a`.
    d2a_mark,
    /// VAMS §7.3.6.1 an analog event's A2D: wake what waits on named-event
    /// slot `a2d` (`analog.deliverA2d`).
    a2d: u32,
};

/// One payload row, recycled once its event dispatches or is cancelled.
pub const Row = struct {
    item: Pending,
    handle: Handle = undefined,
    buf: []u64 = &.{},
};

/// A process suspended on an event control: where it resumes. Its terms
/// name this row and go stale together when `gen` moves on.
pub const Susp = struct { pc: u32, gen: u32, alive: bool, ctx: u32 = 0 };

/// §10.2.3 one timed activation of a task that reaches itself: where its
/// caller resumes and in which activation, its `Program.Call`, and its own
/// storage while another activation of the same automatic task is resident.
pub const Act = struct { sub: u32, ret_pc: u32, ret_ctx: u32, call: u32, storage: []u64 = &.{} };

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
    /// `Program.Term.select`.
    select: u32 = std.math.maxInt(u32),
};

/// A module path source's last transition: when, and its low word before
/// and after (values, unknowns).
pub const PathEdge = struct { time: u64, before: [2]u64, after: [2]u64 };

/// §8.5.3.3 one parked right-hand side.
pub const Hold = struct { planes: []u64 = &.{}, width: u32 = 0, signed: bool = false };

/// §17.1.3 the standing monitor or a §17.2.2 `$fmonitor`: its
/// `Program.Monitor`, what each compared argument read when last
/// evaluated, and an `$fmonitor`'s descriptor and pending report.
pub const Monitor = struct {
    m: Program.Monitor,
    values: [][]u64,
    fd: i64 = 0,
    hit: bool = false,
};

/// The nested activations a run allows by default: 20,000 (the old engine's
/// 256 MiB stack held a few times more; `recursion_past_1024` needs 5,001).
pub const default_depth: u32 = 20_000;

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
/// §17.2.2 "any number of $fmonitor tasks", each until an `$fclose` of its
/// descriptor.
fmonitors: std.ArrayList(Monitor) = .empty,
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
/// The warnings the run raised (`warn`), in order; none ends the run.
warnings: std.ArrayList([]const u8) = .empty,
/// What §17.2.9 reads files through; without it a load warns and ends.
io: ?std.Io = null,
/// §17.6 the stochastic queues, by `q_id`.
queues: queue.Queues = .empty,
/// §17.9.1 the seedless `$random`'s seed.
random_seed: i32 = 0,
/// §17.2 the run's descriptor table (`files.zig`).
files: kernels.file_table.ZfTable = .{},
/// §6.1 every driver's value now (`resolve.current`), its §7.10.2 H/L
/// flag and its transition in flight; per net, its own transition, §3.8
/// capacitive state and decay countdown; §8 UDP inputs and states.
drv: []u64,
drv_or_z: []bool,
drv_trans: []resolve.Inertial,
net_trans: []resolve.Inertial,
capacitive: []bool,
decay_event: []?Handle,
udp_bits: []Bit,
udp_state: []Bit,
udp_started: []bool,
/// §10 per `subs` row, its synchronous activations in progress; §10.3 the
/// subroutine a `disable` is unwinding, whose activations return at once.
sub_active: []u32,
unwind: ?u32 = null,
/// §10.2.3 the timed activations: the one the running process is in (0:
/// none), every one (row 0 unused), the rows free for reuse, per `subs`
/// row the activation its frame holds now, and the `fork` counters of the
/// forks inside an activation.
ctx: u32 = 0,
acts: std.ArrayList(Act) = .empty,
free_acts: std.ArrayList(u32) = .empty,
resident: []u32,
joins: std.AutoHashMapUnmanaged(struct { join: u32, ctx: u32 }, u64) = .empty,
/// Nested synchronous activations now, and the most allowed: the caller
/// gives the run a stack for `depth_max` of them (`default_depth`).
depth: u32 = 0,
depth_max: u32 = default_depth,
/// §7.6 per switch, its conduction, the conduction in flight and its event;
/// per net bit, its §7.10 signal; per driver, the strengths it asserts (a
/// MOS switch's follow its data).
tran_state: []net.TranState,
tran_target: []net.TranState,
tran_pending: []?Handle,
signals: []net.Signal,
tran_delay: []net.Delay,
/// Per switch-joined net, its value as the group resolutions left it.
net_resolved: []u64,
drv_s0: []net.Strength,
drv_s1: []net.Strength,
/// §9.3 what holds each held slot, and whether the write in flight is a
/// holding process's own (which the hold lets through).
holds_by_slot: std.AutoHashMapUnmanaged(u32, hold.Layers) = .empty,
holding: bool = false,
/// §18 the value change dump, and per slot whether it is dumped.
dump: vcd.Dump = .{},
dumped: []bool,
/// §18.3 the port dump files, when they were asked for, and per slot
/// whether it is a dumped port.
port_files: std.ArrayList(evcd.File) = .empty,
ports_at: ?u64 = null,
port_slots: []bool,
/// The module paths and drivers' delays as §16 annotation leaves them
/// (elaboration's until a `$sdf_annotate` changes them).
paths: []Program.Path,
drv_delay: []net.Delay,
/// §15 every check's run state, and the violations found.
checks: []tchk.Run,
violations: u64 = 0,
/// §14.3.3 per path source slot, its last transition (`path_changed`
/// holds whether it has one).
path_edge: []PathEdge,
path_changed: []bool,
/// Per-instruction temporaries, reset before each.
scratch: std.heap.ArenaAllocator,
/// VAMS §7.3, §8.5 the link to an analog solver of a mixed run.
analog: analog_link.Link = .{},

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
        .drv = try arena.dupe(u64, p.driver_init),
        .drv_or_z = try arena.alloc(bool, p.drivers.len),
        .drv_trans = try arena.alloc(resolve.Inertial, p.drivers.len),
        .net_trans = try arena.alloc(resolve.Inertial, p.nets.len),
        .capacitive = try arena.alloc(bool, p.nets.len),
        .decay_event = try arena.alloc(?Handle, p.nets.len),
        .udp_bits = try arena.dupe(Bit, p.udp_bits),
        .udp_state = try arena.alloc(Bit, p.drivers.len),
        .udp_started = try arena.alloc(bool, p.drivers.len),
        .sub_active = try arena.alloc(u32, p.subs.len),
        .resident = try arena.alloc(u32, p.subs.len),
        .checks = try arena.alloc(tchk.Run, p.checks.len),
        .paths = try arena.dupe(Program.Path, p.paths),
        .drv_delay = try arena.alloc(net.Delay, p.drivers.len),
        .dumped = try arena.alloc(bool, p.slots.len),
        .port_slots = try arena.alloc(bool, p.slots.len),
        .tran_state = try arena.alloc(net.TranState, p.trans.len),
        .tran_target = try arena.alloc(net.TranState, p.trans.len),
        .tran_pending = try arena.alloc(?Handle, p.trans.len),
        .signals = try arena.dupe(net.Signal, p.signal_init),
        .tran_delay = try arena.alloc(net.Delay, p.trans.len),
        .net_resolved = try arena.dupe(u64, p.resolved_init),
        .drv_s0 = try arena.alloc(net.Strength, p.drivers.len),
        .drv_s1 = try arena.alloc(net.Strength, p.drivers.len),
        .path_edge = try arena.alloc(PathEdge, if (p.path_source.len != 0) p.slots.len else 0),
        .path_changed = try arena.alloc(bool, if (p.path_source.len != 0) p.slots.len else 0),
        .scratch = .init(arena),
    };
    @memset(s.sub_active, 0);
    @memset(s.resident, 0);
    for (p.checks, s.checks) |c, *r| r.* = .{ .v = c.v, .x = c.x, .lim = c.lim };
    for (p.drivers, s.drv_delay) |d, *dl| dl.* = d.delay;
    for (p.trans, s.tran_state, s.tran_target, s.tran_delay) |t, *st, *tg, *dl| {
        st.* = t.state;
        tg.* = t.state;
        dl.* = t.delay;
    }
    @memset(s.tran_pending, null);
    for (p.drivers, s.drv_s0, s.drv_s1) |d, *s0, *s1| {
        s0.* = d.s0;
        s1.* = d.s1;
    }
    @memset(s.path_changed, false);
    for (p.drivers, s.drv_or_z, s.udp_state, s.udp_started) |d, *oz, *st, *started| {
        oz.* = d.init_or_z;
        st.* = if (d.source == .udp) d.source.udp.state else .x;
        started.* = d.source == .udp and d.source.udp.started;
    }
    @memset(s.drv_trans, .{});
    @memset(s.net_trans, .{});
    @memset(s.capacitive, false);
    @memset(s.decay_event, null);
    @memset(s.terms, .empty);
    @memset(s.armed, false);
    @memset(s.counters, 0);
    @memset(s.holds, .{});
    @memset(s.monitored, false);
    @memset(s.dumped, false);
    @memset(s.port_slots, false);
    s.time_format = .{ .units = p.finest };
    s.random_seed = p.random_seed;
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

/// The net slot `slot` is, or null for a variable's.
pub fn netOf(s: *const State, slot: u32) ?u32 {
    if (s.p.slot_net.len == 0) return null;
    const n = s.p.slot_net[slot];
    return if (n == std.math.maxInt(u32)) null else n;
}

/// Records a warning; the run goes on.
pub fn warn(s: *State, comptime f: []const u8, args: anytype) Error!void {
    try s.warnings.append(s.arena, try std.fmt.allocPrint(s.arena, f, args));
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
    const before_words: [2]u64 = .{ v[0], x[0] };
    // §9.3: while a hold has the slot, its own process alone writes it: an
    // assign over a variable, a force over anything; a forced select of a
    // net keeps its bits and the rest resolve.
    var kept: ?bool = null;
    if (hold.blocks(s, slot)) |o| {
        if (o.force != null or (o.assign != null and s.netOf(slot) == null)) return;
        if (o.parts.items.len != 0) kept = hold.keepForced(v, x, value, o.parts.items);
    }
    const differ = kept orelse (!std.mem.eql(u64, v, value.values()) or !std.mem.eql(u64, x, value.unknowns()));
    const changed = if (kept != null) differ else if (sl.ty.real) @as(f64, @bitCast(v[0])) != @as(f64, @bitCast(value.values()[0])) else differ;
    if (differ and kept == null) {
        @memcpy(v, value.values());
        @memcpy(x, value.unknowns());
    }
    // VAMS §9.22.5 an update need not change the value.
    if (s.p.driver_updates.len != 0) try driver_access.stored(s, slot, changed);
    if (!changed) return;
    if (s.p.path_source.len != 0 and s.p.path_source[slot]) {
        s.path_edge[slot] = .{ .time = s.scheduler.now, .before = before_words, .after = .{ v[0], x[0] } };
        s.path_changed[slot] = true;
    }
    if (s.monitored[slot] or s.fmonitors.items.len != 0) try monitorChanged(s, slot);
    if (s.dumped[slot] or s.port_slots[slot]) try vcd.request(s);
    const after = logic.planeBit(v[0], x[0]);
    try wake(s, slot, before, after);
    // §15: a timing check whose event this slot is.
    if (s.p.checks.len != 0) try tchk.changed(s, slot, before, after);
}

/// §5.10.4 `-> e`: resume what waits on named event `slot`.
pub fn trigger(s: *State, slot: u32) Error!void {
    assert(slot < s.p.slots.len);
    if (s.dumped[slot]) try vcd.fired(s, slot);
    return wake(s, slot, .x, .x);
}

/// Queues a §9.2.2 nonblocking update of `slot` (its `sel` bits) with
/// `value`, now or `delay` ticks later. The value is copied into the row.
pub fn scheduleWrite(s: *State, slot: u32, sel: ?eval.Sel, value: Literal, delay: ?u64) Error!void {
    assert(slot < s.p.slots.len);
    _ = try s.enqueueBuf(.{ .write = .{ .slot = slot, .sel = sel, .width = value.width, .signed = value.signed } }, value.planes, delay, true);
    if (s.p.driver_updates.len != 0) try driver_access.scheduled(s, slot);
}

/// Queues a plain write of `value` into `slot`, `delay` ticks later, in
/// the inactive region (a §14.6 pulse's edge).
pub fn schedulePut(s: *State, slot: u32, value: Literal, delay: u64) Error!void {
    _ = try s.enqueueBuf(.{ .put = .{ .slot = slot, .width = value.width } }, value.planes, delay, false);
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

/// Queues `item`, which carries no buffer, in `region` of the current time
/// (the analog link's marks).
pub fn mark(s: *State, region: sched.Region, item: Pending) Error!Handle {
    assert(item == .analog_mark or item == .d2a_mark);
    const at = try claim(s, item, &.{});
    const h = s.scheduler.schedule(s.arena, region, at) catch |e| return schedFail(s, e);
    s.rows.items[at].handle = h;
    return h;
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
    su.ctx = s.ctx;
    su.alive = true;
    return id;
}

/// Files term `t` of suspension `id` under its slot; a select term
/// remembers its bits now.
pub fn watch(s: *State, id: u32, t: Program.Term) Error!void {
    assert(s.susps.items[id].alive);
    var term: Term = .{ .susp = id, .gen = s.susps.items[id].gen, .edge = t.edge, .lo = t.lo, .width = t.width, .select = t.select };
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
        .run_in => |x| if (x.pc >= start and x.pc < end and s.scheduler.payloadOf(row.handle) != null) {
            try cancel(s, row.handle);
            hit = true;
        },
        .write, .strobe, .fstrobe, .monitor_tick, .vcd_tick, .tchk_expiry, .tchk_event, .drive, .net_update, .decay, .put, .tran_switch, .analog_mark, .d2a_mark, .a2d => {},
    };
    return hit;
}

/// Where a process continues at `pc`: inside timed activation `ctx`, if any.
pub fn resumption(pc: u32, ctx: u32) Pending {
    return if (ctx == 0) .{ .run = pc } else .{ .run_in = .{ .pc = pc, .ctx = ctx } };
}

/// §17.1.3 one end-of-step monitor check, however many values moved; an
/// `$fmonitor` (`file`) needs it whether or not a `$monitor` stands.
pub fn requestMonitor(s: *State, file: bool) Error!void {
    if (!file and (s.monitor == null or !s.monitor_on)) return;
    if (s.monitor_pending) return;
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

/// Bits [lo, lo + width) of `slot`, width at most 64, as (v, x) words.
pub fn termBits(s: *const State, slot: u32, lo: u32, width: u32) [2]u64 {
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

/// §9.7.2 Table 9-1: whether bit 0 moving `before` to `after` is `edge`;
/// `any` is every change (the caller proved one).
pub fn matches(edge: Program.Edge, before: Bit, after: Bit) bool {
    if (edge == .any) return true;
    if (before == after) return false;
    return switch (edge) {
        .posedge => before == .zero or after == .one,
        .negedge => before == .one or after == .zero,
        .any => unreachable,
    };
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
    const none = @backingInt(Program.Ref.none);
    // §10.2.1 an automatic task's variables and events are each
    // activation's own: a change in one is none in another.
    const owner = if (p.slot_act.len != 0) p.slot_act[slot] else none;
    const here = if (owner != none) activations.context(s, owner, s.ctx) else 0;
    var keep: usize = 0;
    for (list.items, 0..) |t, i| {
        assert(keep <= i);
        const su = &s.susps.items[t.susp];
        if (su.gen != t.gen) continue;
        const mine = owner == none or here == activations.context(s, owner, su.ctx);
        const hit = mine and if (t.width != 0) selectChanged(s, &list.items[i], slot) else matches(t.edge, before, after) and try selected(s, t, su.ctx, slot);
        // The select's evaluation can satisfy another term of this
        // suspension (an index function's write).
        if (su.gen != t.gen) continue;
        if (!hit) {
            list.items[keep] = list.items[i];
            keep += 1;
            continue;
        }
        const pc = su.pc;
        const ctx = su.ctx;
        retire(s, t.susp);
        _ = try enqueue(s, resumption(pc, ctx), null, false);
    }
    list.shrinkRetainingCapacity(keep);
    if (s.analog.watch.len != 0 or s.analog.sites.items.len != 0) try analog_link.changed(s, slot, before, after);
}

/// §9.7.3 an event array term wakes only when its index names `slot` now,
/// read in the waiter's activation `ctx`.
fn selected(s: *State, t: Term, ctx: u32, slot: u32) Error!bool {
    if (t.select == std.math.maxInt(u32)) return true;
    var tmp: std.heap.ArenaAllocator = .init(s.arena);
    defer tmp.deinit();
    try activations.makeResident(s, ctx);
    const at = try eval.address(s, tmp.allocator(), s.p.extraData(Program.Elem, t.select));
    try activations.makeResident(s, s.ctx);
    return at != null and at.? == slot;
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

/// A slot a monitor reads changed: a loose slot, or a compared argument
/// whose value moved (each keeps its new value), makes its report due. A
/// store its own evaluation makes asks nothing again.
fn monitorChanged(s: *State, slot: u32) Error!void {
    if (s.monitor_evaluating) return;
    s.monitor_evaluating = true;
    defer s.monitor_evaluating = false;
    var tmp: std.heap.ArenaAllocator = .init(s.arena);
    defer tmp.deinit();
    if (s.monitored[slot]) if (s.monitor) |m| if (try moved(s, tmp.allocator(), m, slot) and s.monitor_on) {
        s.monitor_hit = true;
        try requestMonitor(s, false);
    };
    for (s.fmonitors.items) |*m| if (std.mem.findScalar(u32, s.p.list(m.m.slots), slot) != null and try moved(s, tmp.allocator(), m.*, slot)) {
        m.hit = true;
        try requestMonitor(s, true);
    };
}

/// Whether monitor `m`'s report is due after `slot` changed.
fn moved(s: *State, a: Allocator, m: Monitor, slot: u32) Error!bool {
    if (std.mem.findScalar(u32, s.p.list(m.m.loose), slot) != null) return true;
    var any = false;
    for (s.p.list(m.m.compared), m.values) |e, old| {
        const now = try monitorValue(s, a, e);
        if (std.mem.eql(u64, old, now)) continue;
        any = true;
        @memcpy(old, now);
    }
    return any;
}
