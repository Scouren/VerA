//! A driver's turn and a net's resolution: a `Program.Driver`'s source read
//! now -> its contribution, held back by its §6.1.3 inertial delay or
//! published at once; a net's drivers -> the §7.9/§7.10 value its slot
//! shows, held back by the net's own `delay3`; §3.8 `trireg` charge and
//! decay. The run state they keep is `State`'s (`drv`, `drv_trans`,
//! `net_trans`, ...).
//! Cites: IEEE 1364-2005 §3.8, §6.1.3, §6.5.7.1, §7.8.5, §7.9, §7.10,
//! §7.14, §8, §19.9; VAMS §3.7 (wreal).
//!
//! Contents:
//! - `pub const Inertial = struct`
//! - `pub fn continuous(s: *State, a: Allocator, at: u32, pc: u32) Error!void`
//! - `pub fn resolve(s: *State, a: Allocator, net: u32) Error!void`
//! - `pub fn drive(s: *State, a: Allocator, at: u32) Error!void`
//! - `pub fn netUpdate(s: *State, net: u32) Error!void`
//! - `pub fn decay(s: *State, a: Allocator, net: u32) Error!void`
//! - `pub fn current(s: *const State, at: u32) Literal`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Program = @import("Program.zig");
const State = @import("State.zig");
const eval = @import("eval.zig");
const logic = @import("logic.zig");
const net_ = @import("net.zig");
const Handle = @import("scheduler.zig").Handle;
const Error = State.Error;
const Literal = logic.Literal;
const Bit = logic.Bit;
const Signal = net_.Signal;

/// A driver's or a net's one transition in flight (§6.1.3): cancelling it is
/// the scheduler's `cancel` on `in_flight`; `target` is what it publishes.
pub const Inertial = struct {
    in_flight: ?Handle = null,
    target: []u64 = &.{},
    or_z: bool = false,
};

/// Driver `at`'s turn at pc `pc` (`.continuous`): its value now, published
/// at once or after its delay, and the driver armed again.
pub fn continuous(s: *State, a: Allocator, at: u32, pc: u32) Error!void {
    const p = s.p;
    const d = p.drivers[at];
    const timing = try timingOf(s, a, d);
    var or_z = false;
    const value: Literal = switch (d.source) {
        .expr => |x| if (x.slice) blk: {
            const whole = try eval.eval(s, a, x.value);
            const part = try logic.filled(a, d.width, false, .z);
            logic.copyBits(part, 0, whole, x.lo, d.width);
            break :blk part;
        } else try eval.eval(s, a, x.value),
        .bridge => |b| blk: {
            const out = try logic.filled(a, d.width, false, .z);
            const src = try eval.read(s, a, b.src);
            logic.copyBits(out, b.dst_lo, src, b.src_lo, b.width);
            const fill: Bit = if (b.sign_at) |k| src.bit(k) else .zero;
            for (0..b.ext) |j| logic.setBit(out, b.dst_lo + b.width + @as(u32, @intCast(j)), fill);
            break :blk out;
        },
        .gate => |g| blk: {
            const ins = p.list(g.ins);
            const bits = try a.alloc(Bit, ins.len);
            for (ins, bits) |in, *b| {
                const v = try eval.eval(s, a, in);
                b.* = v.bit(if (v.width > 1) g.lane orelse 0 else 0);
            }
            const out = try logic.filled(a, d.width, false, .z);
            const o = net_.gateBit(g.kind, bits);
            logic.setBit(out, g.out_bit orelse 0, o.bit);
            or_z = o.or_z;
            break :blk out;
        },
        .udp => |u| blk: {
            const ins = p.list(u.ins);
            const bits = try a.alloc(Bit, ins.len);
            for (ins, bits) |in, *b| {
                const w = try eval.eval(s, a, in);
                const v = w.bit(if (w.width > 1) u.lane orelse 0 else 0);
                b.* = if (v == .z) .x else v;
            }
            const rows = p.udps[u.udp];
            const out_bit = if (!u.sequential) net_.udpEval(rows, false, bits, .x, null, .x) else seq: {
                const prev = s.udp_bits[u.prev.start..][0..u.prev.len];
                for (bits, 0..) |b, k| {
                    if (b == prev[k]) continue;
                    const from = prev[k];
                    prev[k] = b;
                    s.udp_state[at] = net_.udpEval(rows, true, prev, s.udp_state[at], @intCast(k), from);
                }
                break :seq s.udp_state[at];
            };
            const out = try logic.filled(a, d.width, false, .z);
            logic.setBit(out, u.out_bit orelse 0, out_bit);
            break :blk out;
        },
        .pull => |b| try logic.filled(a, d.width, false, b),
    };
    // §8.5: a sequential UDP's initial output is published at time 0; a
    // combinational one's is x until its first delayed value.
    const is_udp = d.source == .udp;
    const first_udp = is_udp and d.source.udp.sequential and !s.udp_started[at];
    if (is_udp and !s.udp_started[at] and !first_udp and timing.present) try resolve(s, a, d.net);
    if (is_udp) s.udp_started[at] = true;
    if (timing.present and !first_udp) {
        const st = &s.drv_trans[at];
        const cur = current(s, at);
        if (try schedule(s, cur, s.drv_or_z[at], value, or_z, st)) {
            const target: Literal = .{ .width = d.width, .signed = false, .sized = true, .planes = st.target };
            const delay = switch (d.source) {
                .expr => timing.continuous(cur.truth(), target),
                .gate => |g| timing.to(target.bit(g.out_bit orelse 0)),
                .udp => |u| timing.to(target.bit(u.out_bit orelse 0)),
                .bridge, .pull => timing.to(target.bit(0)),
            };
            st.in_flight = try s.enqueue(.{ .drive = at }, delay, false);
        }
    } else {
        @memcpy(current(s, at).planes, value.planes);
        s.drv_or_z[at] = or_z;
        try resolve(s, a, d.net);
    }
    s.armed[pc] = true;
}

/// Net `net` resolved from every driver and published to its slot, at once
/// or after the net's own delay (§6.1.3).
pub fn resolve(s: *State, a: Allocator, net: u32) Error!void {
    const p = s.p;
    const n = p.nets[net];
    const drivers = p.list(n.drivers);
    const width = p.slots.items(.ty)[n.slot].width;
    const resolved = try logic.filled(a, width, false, .z);
    if (n.kind == .wreal) {
        // VAMS §3.7: one driver's value, 0.0 with none, no four-state fold.
        resolved.unknowns()[0] = 0;
        resolved.values()[0] = 0;
        for (drivers) |d| {
            const cur = current(s, d);
            if (!cur.hasUnknown()) resolved.values()[0] = cur.values()[0];
        }
        return s.store(n.slot, resolved);
    }
    const now = try eval.read(s, a, n.slot);
    const tables = net_.wiredLogic(n.kind);
    var floating: u32 = 0;
    for (0..width) |i| {
        const at: u32 = @intCast(i);
        var acc: Signal = .{};
        for (drivers) |d| {
            const c = contribution(s, d, at);
            acc = if (tables) |table| acc.combineWired(c, table) else acc.combine(c);
        }
        // §7.9/§7.10 a trireg no driver asserts holds its charge.
        if (n.kind == .trireg and acc.none()) {
            acc = .of(now.bit(at), n.charge, n.charge);
            floating += 1;
        }
        acc = acc.combine(net_.netPull(n.kind));
        logic.setBit(resolved, at, acc.collapse());
    }
    if (n.kind == .trireg) try chargeState(s, net, floating == width);
    if (n.delay.present) {
        const st = &s.net_trans[net];
        // Timed from what is in flight to land, when something is.
        const base: Literal = if (st.in_flight != null) .{ .width = width, .signed = false, .sized = true, .planes = st.target } else now;
        const ticks = n.delay.continuous(base.truth(), resolved);
        if (try schedule(s, now, false, resolved, false, st)) st.in_flight = try s.enqueue(.{ .net_update = net }, ticks, false);
        return;
    }
    return s.store(n.slot, resolved);
}

/// A delayed driver's transition lands (`.drive`).
pub fn drive(s: *State, a: Allocator, at: u32) Error!void {
    const st = &s.drv_trans[at];
    st.in_flight = null;
    @memcpy(current(s, at).planes, st.target);
    s.drv_or_z[at] = st.or_z;
    try resolve(s, a, s.p.drivers[at].net);
}

/// A delayed net's transition lands (`.net_update`).
pub fn netUpdate(s: *State, net: u32) Error!void {
    const st = &s.net_trans[net];
    st.in_flight = null;
    const slot = s.p.nets[net].slot;
    const width = s.p.slots.items(.ty)[slot].width;
    try s.store(slot, .{ .width = width, .signed = false, .sized = true, .planes = st.target });
}

/// §3.8 a trireg's charge held for its decay time is worth nothing: x.
pub fn decay(s: *State, a: Allocator, net: u32) Error!void {
    s.decay_event[net] = null;
    const slot = s.p.nets[net].slot;
    try s.store(slot, try logic.filled(a, s.p.slots.items(.ty)[slot].width, false, .x));
}

/// Driver `at`'s value now, in the run's own planes.
pub fn current(s: *const State, at: u32) Literal {
    const d = s.p.drivers[at];
    const n = Program.words(d.width);
    return .{ .width = d.width, .signed = false, .sized = true, .planes = s.drv[d.init..][0 .. 2 * n] };
}

// ---- private ----

/// The delay a driver schedules with: its constant one, or its rows read now.
fn timingOf(s: *State, a: Allocator, d: Program.Driver) Error!net_.Delay {
    const none = @backingInt(Program.Ref.none);
    if (d.delay_rows[0] == none) return d.delay;
    var out: net_.Delay = .{ .present = true };
    out.rise = try delayIn(s, a, d.delay_rows[0], d.scope);
    out.fall = if (d.delay_rows[1] != none) try delayIn(s, a, d.delay_rows[1], d.scope) else out.rise;
    out.off = if (d.delay_rows[2] != none) try delayIn(s, a, d.delay_rows[2], d.scope) else @min(out.rise, out.fall);
    return out;
}

fn delayIn(s: *State, a: Allocator, e: u32, scope: u32) Error!u64 {
    return @import("Interp.zig").delayIn(s, a, e, scope);
}

/// What driver `d` asserts on bit `at`: its value at its strengths, or
/// §7.10.2's H/L.
fn contribution(s: *const State, d: u32, at: u32) Signal {
    const dr = s.p.drivers[d];
    const b = current(s, d).bit(at);
    return if (s.drv_or_z[d] and b != .z) .orZ(b, dr.s0, dr.s1) else .of(b, dr.s0, dr.s1);
}

/// §6.1.3's inertial rule: whether a transition to `to` is needed, having
/// cancelled what it displaced and recorded `to` as the target.
fn schedule(s: *State, from: Literal, from_or_z: bool, to: Literal, to_or_z: bool, st: *Inertial) Error!bool {
    const settled = if (st.in_flight != null) st.target else from.planes;
    const settled_or_z = if (st.in_flight != null) st.or_z else from_or_z;
    if (std.mem.eql(u64, settled, to.planes) and settled_or_z == to_or_z) return false;
    if (st.in_flight) |h| try s.cancel(h);
    st.in_flight = null;
    if (st.target.len != to.planes.len) st.target = try s.arena.alloc(u64, to.planes.len);
    @memcpy(st.target, to.planes);
    st.or_z = to_or_z;
    return true;
}

/// §3.8: the decay countdown restarts on each entry into the capacitive
/// state and is cancelled on leaving it.
fn chargeState(s: *State, net: u32, floating: bool) Error!void {
    const was = s.capacitive[net];
    s.capacitive[net] = floating;
    if (was == floating) return;
    if (s.decay_event[net]) |h| try s.cancel(h);
    s.decay_event[net] = null;
    if (!floating) return;
    const after = s.p.nets[net].decay;
    if (after == Program.Net.no_decay) return;
    s.decay_event[net] = try s.enqueue(.{ .decay = net }, after, false);
}
