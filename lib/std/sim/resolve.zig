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
//! - `pub fn switchCtrl(s: *State, a: Allocator, at: u32, pc: u32) Error!void`
//! - `pub fn tranSwitch(s: *State, a: Allocator, at: u32) Error!void`
//! - `pub fn wakeSwitches(s: *State, slot: u32) Error!void`
//! - `pub fn current(s: *const State, at: u32) Literal`
//! - `pub fn contribution(s: *const State, d: u32, at: u32) Signal`
//! - `Switches.switches`, `Switches.tran`, `Switches.conduction`, `Switches.fixed` (private type, `net.reach`'s view)

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Program = @import("Program.zig");
const State = @import("State.zig");
const eval = @import("eval.zig");
const logic = @import("logic.zig");
const net_ = @import("net.zig");
const Handle = @import("scheduler.zig").Handle;
const vcd = @import("vcd.zig");
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
    /// When the transition in flight lands (a path destination's, §14.6).
    due: u64 = 0,
};

/// The run's switches as `net.reach` and `net.switchPaths` see them.
const Switches = struct {
    s: *const State,
    pub fn switches(g: Switches, n: u32) []const u32 {
        return g.s.p.list(g.s.p.nets[n].trans);
    }
    pub fn tran(g: Switches, ti: u32) Program.Tran {
        return g.s.p.trans[ti];
    }
    pub fn conduction(g: Switches, ti: u32) net_.TranState {
        return g.s.tran_state[ti];
    }
    pub fn fixed(g: Switches, n: u32) bool {
        return switch (g.s.p.nets[n].kind) {
            .supply0, .supply1 => true,
            else => false, // else: every other net kind is a conductor
        };
    }
};

/// A transition's delay and §14.6.1 reject and error limits.
const Timed = struct { ticks: u64, reject: u64, err: u64 };

/// Per bit of one word, which values `foldUniform`'s drivers assert.
const Seen = struct {
    zero: u64 = 0,
    one: u64 = 0,
    x: u64 = 0,

    fn add(seen: *Seen, v: u64, x: u64) void {
        seen.zero |= ~v & ~x;
        seen.one |= v & ~x;
        seen.x |= v & x;
    }

    /// The resolved (value, unknown) planes of the `live` bits.
    fn word(seen: Seen, live: u64) [2]u64 {
        const unknown = seen.x | (seen.zero & seen.one);
        const none = ~(seen.zero | seen.one | seen.x);
        return .{ (seen.one | unknown) & live, (unknown | none) & live };
    }
};

/// Driver `at`'s turn at pc `pc` (`.continuous`): its value now, published
/// at once or after its delay, and the driver armed again.
pub fn continuous(s: *State, a: Allocator, at: u32, pc: u32) Error!void {
    const p = s.p;
    const d = p.drivers[at];
    const timing = try timingOf(s, a, at);
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
        .mos => |m| try mosValue(s, a, at, m, &or_z),
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
                .mos => |m| timing.to(target.bit(m.out_bit orelse 0)),
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
    // A §18.4 port's state can change with its drivers' strengths alone.
    if (s.port_slots[n.slot]) try vcd.request(s);
    if (n.trans.len != 0) return resolveJoined(s, a, net);
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
    // §7.10/§7.11: a MOS switch passes its data's strength, so a change of
    // strength alone on a net one reads re-evaluates that switch.
    var moved = false;
    const plain = !n.strength_read and switch (n.kind) {
        .wire, .tri, .uwire => true,
        // A pull, a wired table, a trireg's charge or a wreal's own rule.
        .tri0, .tri1, .supply0, .supply1, .wand, .wor, .triand, .trior, .trireg, .wreal => false,
    } and uniform(s, drivers, width);
    if (plain) foldUniform(s, drivers, resolved);
    for (0..if (plain) 0 else width) |i| {
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
        // A net's signal is kept only where something reads it (a MOS
        // switch's data, `%v`): `Net.strength_read`.
        if (n.strength_read) {
            moved = moved or !std.meta.eql(s.signals[n.signal + at], acc);
            s.signals[n.signal + at] = acc;
        }
        logic.setBit(resolved, at, acc.collapse());
    }
    if (n.kind == .trireg) try chargeState(s, net, floating == width);
    // A.2.1.3's delay3 and §14's module paths delay the net's own transition.
    if (n.delay.present or n.paths.len != 0) {
        const st = &s.net_trans[net];
        // Timed from what is in flight to land, when something is: the
        // edge §14.6's pulse ends with.
        const base: Literal = if (st.in_flight != null) .{ .width = width, .signed = false, .sized = true, .planes = st.target } else now;
        if (try transitionDelay(s, a, n, base, resolved)) |td| {
            if (st.in_flight != null and n.paths.len != 0 and !std.mem.eql(u64, st.target, resolved.planes))
                if (try pulse(s, net, td, resolved)) return;
            if (try schedule(s, now, false, resolved, false, st)) {
                st.in_flight = try s.enqueue(.{ .net_update = net }, td.ticks, false);
                st.due = s.scheduler.now + td.ticks;
            }
            return;
        }
        // No path is active: the transition is not delayed, and one in
        // flight is superseded.
        if (st.in_flight) |h| try s.cancel(h);
        st.in_flight = null;
    }
    try s.store(n.slot, resolved);
    if (moved) try wakeSwitches(s, n.slot);
}

/// §7.6 a controlled switch's turn (`.switch_ctrl` at `pc`): its control
/// read now, its conduction changed at once or after its delay, both sides
/// re-resolved, and it is armed again.
pub fn switchCtrl(s: *State, a: Allocator, at: u32, pc: u32) Error!void {
    const t = s.p.trans[at];
    const c = (try eval.eval(s, a, t.ctrl)).bit(0);
    const next: net_.TranState = if (c == t.on) .on else if (c == .zero or c == .one) .off else .unknown;
    const none = @backingInt(Program.Ref.none);
    if (t.delay_rows[0] != none) {
        var d: net_.Delay = .{ .present = true };
        d.rise = try delayIn(s, a, t.delay_rows[0], s.p.inst_scope[pc]);
        d.fall = if (t.delay_rows[1] != none) try delayIn(s, a, t.delay_rows[1], s.p.inst_scope[pc]) else d.rise;
        d.off = if (t.delay_rows[2] != none) try delayIn(s, a, t.delay_rows[2], s.p.inst_scope[pc]) else @min(d.rise, d.fall);
        s.tran_delay[at] = d;
    }
    if (s.tran_delay[at].present) try switchAfter(s, at, next) else {
        s.tran_state[at] = next;
        try resolve(s, a, t.a);
        try resolve(s, a, t.b);
    }
    s.armed[pc] = true;
}

/// A delayed switch reaches its target conduction (`.tran_switch`).
pub fn tranSwitch(s: *State, a: Allocator, at: u32) Error!void {
    s.tran_pending[at] = null;
    s.tran_state[at] = s.tran_target[at];
    try resolve(s, a, s.p.trans[at].a);
    try resolve(s, a, s.p.trans[at].b);
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

/// Re-runs the MOS switches reading slot `slot` (§7.11): its strength
/// changed, which no event control sees.
pub fn wakeSwitches(s: *State, slot: u32) Error!void {
    const p = s.p;
    if (slot + 1 >= p.fan_start.len) return;
    for (p.fan[p.fan_start[slot]..p.fan_start[slot + 1]]) |pc| if (s.armed[pc]) {
        if (p.insts.items(.tag)[pc] != .continuous) continue;
        if (p.drivers[p.insts.items(.data)[pc].a].source != .mos) continue;
        s.armed[pc] = false;
        _ = try s.enqueue(.{ .run = pc }, null, false);
    };
}

/// Driver `at`'s value now, in the run's own planes.
pub fn current(s: *const State, at: u32) Literal {
    const d = s.p.drivers[at];
    const n = Program.words(d.width);
    return .{ .width = d.width, .signed = false, .sized = true, .planes = s.drv[d.init..][0 .. 2 * n] };
}

/// What driver `d` asserts on bit `at`: its value at its strengths, or
/// §7.10.2's H/L.
pub fn contribution(s: *const State, d: u32, at: u32) Signal {
    const b = current(s, d).bit(at);
    return if (s.drv_or_z[d] and b != .z) .orZ(b, s.drv_s0[d], s.drv_s1[d]) else .of(b, s.drv_s0[d], s.drv_s1[d]);
}

// ---- private ----

/// §7.6 what a MOS switch drives: its data at the data's strength reduced
/// by §7.12 (a net's resolved signal, strong for anything else) while its
/// gate conducts; z when it does not; §7.10.2's H/L when the gate is x/z.
/// A z on the data is z whatever the gate.
fn mosValue(s: *State, a: Allocator, at: u32, m: @FieldType(Program.Driver.Source, "mos"), or_z: *bool) Error!Literal {
    const d = s.p.drivers[at];
    const gv = try eval.eval(s, a, m.gate);
    const g = gv.bit(if (gv.width > 1) m.lane.? else 0);
    const dv = try eval.eval(s, a, m.data);
    const bit = if (dv.width > 1) m.lane.? else 0;
    var sig: Signal = .of(dv.bit(bit), .strong, .strong);
    if (m.data_net != @backingInt(Program.Ref.none)) sig = s.signals[s.p.nets[m.data_net].signal + bit];
    s.drv_s0[at] = net_.reduce(if (sig.lo < 0) @fromBackingInt(@intCast(@as(u8, @intCast(-sig.lo)))) else .highz, m.resistive);
    s.drv_s1[at] = net_.reduce(if (sig.hi > 0) @fromBackingInt(@intCast(@as(u8, @intCast(sig.hi)))) else .highz, m.resistive);
    const value = sig.collapse();
    const on: Bit = if (m.n_type) .one else .zero;
    const out: Bit = if (value == .z or (g != on and (g == .zero or g == .one))) .z else value;
    or_z.* = out != .z and g != on;
    const result = try logic.filled(a, d.width, false, .z);
    logic.setBit(result, m.out_bit orelse 0, out);
    return result;
}

/// §7.6 a controlled switch with a delay: on after the first, off after the
/// second, unknown after the smaller; a control that returns first cancels.
fn switchAfter(s: *State, at: u32, next: net_.TranState) Error!void {
    const settled = if (s.tran_pending[at] != null) s.tran_target[at] else s.tran_state[at];
    if (settled == next) return;
    if (s.tran_pending[at]) |h| try s.cancel(h);
    s.tran_pending[at] = null;
    if (next == s.tran_state[at]) return;
    s.tran_target[at] = next;
    s.tran_pending[at] = try s.enqueue(.{ .tran_switch = at }, s.tran_delay[at].to(switch (next) {
        .on => .one,
        .off => .zero,
        .unknown => .x,
    }), false);
}

/// IEEE 1364-2005 §7.6/§8.5.3.5: the net bits joined through switches that
/// may conduct resolve as one, from every driver of every one of them,
/// each crossing reduced (§7.11, §7.12) and widened across an unknown
/// switch (§7.10.2); with no driver, the group's triregs share their charge.
/// ponytail: no charge decay, wired logic or net delay inside a group, and
/// the group is found afresh each time, as the old engine does.
fn resolveJoined(s: *State, a: Allocator, start: u32) Error!void {
    const p = s.p;
    const g: Switches = .{ .s = s };
    var touched: std.ArrayList(u32) = .empty;
    try touched.append(a, start);
    const width = p.slots.items(.ty)[p.nets[start].slot].width;
    for (0..width) |i| {
        const group = try net_.reach(g, a, .{ .net = start, .bit = @intCast(i) });
        for (group) |y| {
            const paths = try net_.switchPaths(g, a, y, group);
            var acc: Signal = .{};
            for (group, paths) |z, pz| {
                const zn = p.nets[z.net];
                var own = net_.netPull(zn.kind);
                for (p.list(zn.drivers)) |d| own = own.combine(contribution(s, d, z.bit));
                // §9.3.2 a forced net drives the others across a switch as
                // a strong driver of its forced value, and keeps it itself.
                // ponytail: a whole-net force only, not a forced select.
                if (s.holds_by_slot.get(zn.slot)) |o| if (o.force != null) {
                    own = .of((try eval.read(s, a, zn.slot)).bit(z.bit), .strong, .strong);
                };
                acc = acc.combine(net_.crossed(own, z, y, pz));
            }
            if (acc.none()) for (group, paths) |z, pz| {
                const zn = p.nets[z.net];
                if (zn.kind != .trireg) continue;
                const v = try eval.read(s, a, zn.slot);
                acc = acc.combine(net_.crossed(.of(v.bit(z.bit), zn.charge, zn.charge), z, y, pz));
            };
            const yn = p.nets[y.net];
            s.signals[yn.signal + y.bit] = acc;
            logic.setBit(joined(s, y.net), y.bit, acc.collapse());
            if (std.mem.findScalar(u32, touched.items, y.net) == null) try touched.append(a, y.net);
        }
    }
    for (touched.items) |t| try s.store(p.nets[t].slot, joined(s, t));
}

/// Net `n`'s value as the joined resolutions left it, bit by bit.
fn joined(s: *const State, n: u32) Literal {
    const nt = s.p.nets[n];
    const width = s.p.slots.items(.ty)[nt.slot].width;
    return .{ .width = width, .signed = false, .sized = true, .planes = s.net_resolved[nt.resolved..][0 .. 2 * Program.words(width)] };
}

/// The delay a driver schedules with: its constant one, or its rows read now.
fn timingOf(s: *State, a: Allocator, at: u32) Error!net_.Delay {
    const d = s.p.drivers[at];
    const none = @backingInt(Program.Ref.none);
    if (d.delay_rows[0] == none) return s.drv_delay[at];
    var out: net_.Delay = .{ .present = true };
    out.rise = try delayIn(s, a, d.delay_rows[0], d.scope);
    out.fall = if (d.delay_rows[1] != none) try delayIn(s, a, d.delay_rows[1], d.scope) else out.rise;
    out.off = if (d.delay_rows[2] != none) try delayIn(s, a, d.delay_rows[2], d.scope) else @min(out.rise, out.fall);
    return out;
}

fn delayIn(s: *State, a: Allocator, e: u32, scope: u32) Error!u64 {
    return @import("Interp.zig").delayIn(s, a, e, scope);
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

/// The delay of net `n`'s transition from `from` to `to`: its own delay3
/// (§6.1.3), its module paths' (`pathDelay`), or "the larger" (§14.4);
/// null when neither applies.
fn transitionDelay(s: *State, a: Allocator, n: Program.Net, from: Literal, to: Literal) Error!?Timed {
    const own: ?u64 = if (n.delay.present) n.delay.continuous(from.truth(), to) else null;
    var path = try pathDelay(s, a, s.paths[n.paths.start..][0..n.paths.len], from, to);
    if (own) |o| {
        if (path) |*p| p.ticks = @max(o, p.ticks) else return .{ .ticks = o, .reject = o, .err = o };
    }
    return path;
}

/// IEEE 1364-2005 §14.6 a path destination's transition `td` while another
/// is in flight: the pulse between the two landings is filtered (narrower
/// than the reject limit), both land (not narrower than the error limit),
/// or it is x between them (on-event) or from now (on-detect); a negative
/// pulse is filtered, or x under showcancelled. Whether it scheduled.
fn pulse(s: *State, net: u32, td: Timed, resolved: Literal) Error!bool {
    const n = s.p.nets[net];
    const st = &s.net_trans[net];
    const now = s.scheduler.now;
    const leading = st.due;
    const trailing = now + td.ticks;
    const xs = try logic.filled(s.arena, resolved.width, false, .x);
    if (trailing <= leading) {
        if (!n.showcancelled) return false;
        try s.cancel(st.in_flight.?);
        st.in_flight = null;
        if (n.ondetect) try s.store(n.slot, xs) else try s.schedulePut(n.slot, xs, trailing - now);
        try land(s, net, resolved, leading);
        return true;
    }
    const width = trailing - leading;
    if (width < td.reject) return false;
    try s.cancel(st.in_flight.?);
    st.in_flight = null;
    if (width >= td.err) {
        const target: Literal = .{ .width = resolved.width, .signed = false, .sized = true, .planes = st.target };
        try s.schedulePut(n.slot, target, leading - now);
    } else if (n.ondetect) {
        try s.store(n.slot, xs);
    } else {
        try s.schedulePut(n.slot, xs, leading - now);
    }
    try land(s, net, resolved, trailing);
    return true;
}

/// Puts `to` in flight on net `net`'s transition, landing at time `at`.
fn land(s: *State, net: u32, to: Literal, at: u64) Error!void {
    const st = &s.net_trans[net];
    if (st.target.len != to.planes.len) st.target = try s.arena.alloc(u64, to.planes.len);
    @memcpy(st.target, to.planes);
    st.or_z = false;
    st.in_flight = try s.enqueue(.{ .net_update = net }, at - s.scheduler.now, false);
    st.due = at;
}

/// IEEE 1364-2005 §14.3.3: of the paths whose source transitioned most
/// recently and whose condition holds, the smallest delay for this
/// transition, run from the source's transition; null when none is active.
/// ponytail: a vector destination takes the smallest delay its changed bits
/// select, as one transition (the old engine's reading).
fn pathDelay(s: *State, a: Allocator, paths: []const Program.Path, from: Literal, to: Literal) Error!?Timed {
    var latest: ?u64 = null;
    for (paths) |p| if (s.path_changed[p.src]) {
        const t = s.path_edge[p.src].time;
        latest = @max(latest orelse t, t);
    };
    const t = latest orelse return null;
    var best: ?u64 = null;
    var limits: [2]?u64 = .{ null, null };
    for (paths) |p| {
        if (!try pathActive(s, a, paths, p, t)) continue;
        for (0..to.width) |i| {
            const x = from.bit(@intCast(i));
            const y = to.bit(@intCast(i));
            if (x == y) continue;
            const d = p.table[@backingInt(x)][@backingInt(y)];
            if (best == null or d < best.?) limits = .{ p.reject, p.err };
            best = @min(best orelse d, d);
        }
    }
    const d = best orelse return null;
    return .{ .ticks = (t + d) -| s.scheduler.now, .reject = limits[0] orelse d, .err = limits[1] orelse d };
}

/// Whether path `p` is active for a source transition at time `t`: an
/// `ifnone` path only while no state-dependent path from its source is.
fn pathActive(s: *State, a: Allocator, paths: []const Program.Path, p: Program.Path, t: u64) Error!bool {
    if (!pathFired(s, p, t)) return false;
    const none = @backingInt(Program.Ref.none);
    if (p.ifnone) {
        for (paths) |q| if (q.src == p.src and !q.ifnone and (q.cond != none or q.edge != .any) and pathFired(s, q, t) and (q.cond == none or try pathCond(s, a, q))) return false;
        return true;
    }
    return p.cond == none or try pathCond(s, a, p);
}

/// Whether `p`'s source transitioned at `t`, on its edge when it has one
/// (§14.2.3, on its least significant or selected bit).
fn pathFired(s: *const State, p: Program.Path, t: u64) bool {
    if (!s.path_changed[p.src]) return false;
    const c = s.path_edge[p.src];
    if (c.time != t) return false;
    if (p.edge == .any or p.src_bit >= 64) return true;
    const sh: u6 = @intCast(p.src_bit);
    const before = logic.planeBit(c.before[0] >> sh, c.before[1] >> sh);
    const after = logic.planeBit(c.after[0] >> sh, c.after[1] >> sh);
    if (before == after) return false;
    return if (p.edge == .posedge) before == .zero or after == .one else before == .one or after == .zero;
}

/// §14.2.4.1: a state-dependent path's condition now; x or z is true, and
/// a vector's least significant bit decides.
fn pathCond(s: *State, a: Allocator, p: Program.Path) Error!bool {
    return (try eval.eval(s, a, p.cond)).bit(0) != .zero;
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

/// Whether `drivers` (of a net `width` bits wide) resolve word by word:
/// each full width, none an H/L, none at highz, and one driver or all at
/// one strength on both sides. Then Table 7-14's `combine` of a bit is the
/// value they agree on, x where two disagree or one is x, z where all are.
fn uniform(s: *const State, drivers: []const u32, width: u32) bool {
    assert(drivers.len < std.math.maxInt(u32));
    if (drivers.len == 0) return false;
    const first = drivers[0];
    for (drivers) |d| {
        if (s.drv_or_z[d] or s.p.drivers[d].width != width) return false;
        if (s.drv_s0[d] == .highz or s.drv_s1[d] == .highz) return false;
        if (drivers.len == 1) break;
        if (s.drv_s0[d] != s.drv_s1[d] or s.drv_s0[d] != s.drv_s0[first]) return false;
    }
    return true;
}

/// `resolve`'s per-bit fold over `uniform` drivers, a word at a time.
fn foldUniform(s: *const State, drivers: []const u32, resolved: Literal) void {
    const n = Program.words(resolved.width);
    for (resolved.values(), resolved.unknowns(), 0..) |*v, *x, w| {
        var acc: Seen = .{};
        for (drivers) |d| {
            const c = current(s, d);
            acc.add(c.values()[w], c.unknowns()[w]);
        }
        const live = logic.wordMask(resolved.width, w);
        v.*, x.* = acc.word(live);
    }
    assert(resolved.values().len == n);
}

test Seen {
    // Oracle: `Signal.combine` folded bit by bit and collapsed, as
    // `resolve` does, over 1 to 4 strong drivers of random four-state words.
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    for (0..500) |_| {
        const k = r.intRangeAtMost(usize, 1, 4);
        var vs: [4]u64 = undefined;
        var xs: [4]u64 = undefined;
        var seen: Seen = .{};
        for (vs[0..k], xs[0..k]) |*v, *x| {
            v.* = r.int(u64);
            x.* = r.int(u64);
            seen.add(v.*, x.*);
        }
        const got = seen.word(std.math.maxInt(u64));
        for (0..64) |i| {
            var acc: Signal = .{};
            for (vs[0..k], xs[0..k]) |v, x| acc = acc.combine(.of(logic.planeBit(v >> @intCast(i), x >> @intCast(i)), .strong, .strong));
            try std.testing.expectEqual(acc.collapse(), logic.planeBit(got[0] >> @intCast(i), got[1] >> @intCast(i)));
        }
    }
}
