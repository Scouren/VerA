//! A `.v` design's `Program` -> a contract device (ABI 5) an analog host
//! loads like a `.va` one: one pin per port bit of the top module, an
//! `input` bit sensed by an A2D bridge, an `output` bit driven by a D2A
//! bridge, and the interpreter (`Interp`) behind `updateState`/`stateCtl`.
//! The old `lib/sim/rt/device.zig` over `State` instead of the native
//! engine. The bridges are the connect modules VAMS §7.8 inserts on a port
//! that meets an electrical net, with VerA's defaults (the LRM supplies
//! none):
//!
//!     D2A: I(a) <+ transition(g, 0, trise, tfall) * (V(a) - transition(lvl, 0, trise, tfall))
//!          0 -> vss, 1 -> vdd, x -> (vdd + vss)/2 at g = 1/rout; z -> g = gz
//!     A2D: rising through vth + vhys/2 -> 1, falling through vth - vhys/2 -> 0;
//!          a static solve reads 1 above the band, 0 below, x inside it
//!
//! The engine is two runs: the accepted one, at the last accepted tick
//! boundary, and the one a step works on, a deep copy of it (`fork`) made
//! whenever the step has work. Commit keeps the working run, revert drops
//! it. Clauses: VAMS §7.3.6 (synchronization), §7.8, §8.4.3.3 (an A2D event
//! at the nearest tick), §4.5.8 (the ramps), §5.10.3.1 (`cross`); IEEE
//! 1364-2005 §9.7.2 (which edges wake a process), §11.4 (a tick boundary).
//!
//! Contents:
//! - `pub const Pin = struct`, `pub const Spec = struct`
//! - `pub fn Device(comptime spec: Spec) type`
//! - `Device.U`, `Device.Model`, `Device.Instance`, `Device.State`
//! - `Device.state_class`, `Device.deriv_reads`, `Device.ddx_reads`, `Device.jac_pattern`
//! - `Device.eval(comptime S: type, x: *const [n_u]S.V, _: *const Model, inst: *const Instance, sim: contract.SimState) contract.Rows(Self, S)`
//! - `Device.initState(m: *const Model, inst: *Instance) State`
//! - `Device.initProgram(m: *const Model, inst: *Instance, p: *const Program) State`
//! - `Device.updateState(comptime S: type, m: *const Model, inst: *Instance, x: [n_u]f64, st: *State, sim: contract.SimState) contract.UpdateResult`
//! - `Device.stateCtl(_: *const Model, inst: *Instance, st: *State, op: contract.StateCtlOp) bool`
//! - `Device.pendingBreakpoint(inst: *const Instance, t: f64) ?f64`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const contract = @import("contract");
const Program = @import("Program.zig");
const SimState = @import("State.zig");
const Interp = @import("Interp.zig");
const serial = @import("serial.zig");
const logic = @import("logic.zig");
const time = @import("time.zig");
const Bit = logic.Bit;

/// One pin: bit `bit` (counted from the slot's least significant bit) of
/// the top module's port slot `slot`.
pub const Pin = struct { out: bool, slot: u32, bit: u32 };

/// What `codegen/digital_next`'s device root passes `Device`, all comptime.
pub const Spec = struct {
    /// The pins' enum, `U` of the device.
    U: type,
    /// The design, saved by `serial.save`.
    program: []const u8,
    /// In `U` order: the ports in declaration order, a vector's bits from
    /// its left index to its right.
    pins: []const Pin,
    /// The design's finest precision: a tick is 10^`units` s.
    units: i32,
};

/// The contract device (`contract.validate`'s decls) of the design in
/// `spec`. Each instance loads the program once and keeps two runs of it.
///
/// Its cost grows with the pins, never with their square: output row u
/// reads unknown u alone, so `jac_pattern` gives a sparse family one lane
/// per row; a step's A2D work is one compare per input, and the engine runs
/// only when an input crossed or an event is due.
pub fn Device(comptime spec: Spec) type {
    const n_u = spec.pins.len;
    @setEvalBranchQuota(100 * n_u + 1000);
    const M = contract.MaskOf(n_u);
    const ins, const outs = comptime blk: {
        var i: [n_u]u32 = undefined;
        var o: [n_u]u32 = undefined;
        var ni: usize = 0;
        var no: usize = 0;
        for (spec.pins, 0..) |p, u| if (p.out) {
            o[no] = u;
            no += 1;
        } else {
            i[ni] = u;
            ni += 1;
        };
        const ii = i[0..ni].*;
        const oo = o[0..no].*;
        break :blk .{ ii, oo };
    };
    const n_out = outs.len;
    const n_in = ins.len;
    comptime assert(n_in + n_out == n_u);
    const index = comptime blk: {
        var ix: [n_u]usize = undefined;
        for (ins, 0..) |u, i| ix[u] = i;
        for (outs, 0..) |u, k| ix[u] = k;
        break :blk ix;
    };
    const out_mask: M = comptime blk: {
        var m: M = 0;
        for (outs) |u| m |= @as(M, 1) << u;
        break :blk m;
    };
    const tick: f64 = comptime std.fmt.parseFloat(f64, std.fmt.comptimePrint("1e{d}", .{spec.units})) catch unreachable;
    // 10^|units|, exact for every precision 1364 allows, so a tick count
    // converts with one rounding: k * 1e-9 is not k / 1e9.
    const decade: f64 = comptime std.fmt.parseFloat(f64, std.fmt.comptimePrint("1e{d}", .{@abs(spec.units)})) catch unreachable;
    comptime assert(tick > 0);
    comptime assert(decade >= 1);
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);

    return struct {
        const Self = @This();
        /// The contract's unknowns: one per pin, in `spec.pins` order.
        pub const U = spec.U;

        /// The bridge parameters, one card for every instance. A NaN `vth`
        /// is (vdd + vss)/2. A ramp time <= 0 is 1 ps: an ideal step would
        /// need the solve at the event time repeated after the events.
        pub const Model = struct {
            vdd: f64 = 5,
            vss: f64 = 0,
            vth: f64 = nan,
            vhys: f64 = 0,
            trise: f64 = 1e-9,
            tfall: f64 = 1e-9,
            rout: f64 = 1,
            /// The conductance of a released (z) output: 0 would leave a net
            /// only it drives with no path, and the host's matrix singular.
            gz: f64 = 1e-12,
            /// How late after an A2D crossing the host may accept a point
            /// (the `time_tol` VAMS §5.10.3.1 leaves to the tool). NaN is
            /// min(trise, tfall)/50.
            ttol: f64 = nan,
        };

        /// What `eval` reads, and the A2D samples. `dc_lvl`/`dc_g` are the
        /// levels a static solve iterates on: `stateCtl(.revert)` leaves
        /// them, since each static `updateState` rebuilds from the accepted
        /// run and compares against them (VAMS §7.3.6's fixed point).
        pub const Instance = struct {
            /// Per output, its level and conductance ramps: from `from` at
            /// `t0` to `to` at `t1` (§4.5.8 `transition`, zero delay).
            lvl_from: [n_out]f64 = @splat(0),
            lvl_to: [n_out]f64 = @splat(0),
            lvl_t0: [n_out]f64 = @splat(0),
            lvl_t1: [n_out]f64 = @splat(0),
            g_from: [n_out]f64 = @splat(0),
            g_to: [n_out]f64 = @splat(0),
            g_t0: [n_out]f64 = @splat(0),
            g_t1: [n_out]f64 = @splat(0),
            dc_lvl: [n_out]f64 = @splat(0),
            dc_g: [n_out]f64 = @splat(0),
            /// Each input's voltage at the last sample, NaN before the first,
            /// which is then the reference and never a crossing.
            a2d_v: [n_in]f64 = @splat(nan),
            a2d_t: f64 = 0,
            /// Per input, which of its crossings would wake a process at the
            /// accepted boundary: bit 0 a rising one, bit 1 a falling one.
            wakes: [n_in]u2 = @splat(3),
            /// The next digital event, in seconds.
            next_ev: f64 = inf,
            /// A crossing this step took more than `ttol` before its end, in
            /// a step where some process woke.
            late_cross: bool = false,
            /// `$finish` ran or the run failed: the outputs hold from then on.
            stopped: bool = false,
        };

        /// The accepted run, the run this step works on (null while the
        /// step has done no work), and the accepted `Instance`. The working
        /// run's transcript goes to stderr when the host commits it, so a
        /// rejected step prints nothing and its retry prints once. The runs
        /// live on the heap: move a `State`, never copy it.
        pub const State = struct {
            accepted: ?*Run = null,
            work: ?*Run = null,
            inst: Instance = .{},
        };

        /// The digital engine keeps history across accepted steps.
        pub const state_class: contract.StateClass = .history;
        /// Only an output pin's own voltage enters `eval` (`g · (V - level)`).
        pub const deriv_reads: M = out_mask;
        /// No `ddx` reads any unknown.
        pub const ddx_reads: M = 0;
        /// Output row u depends on unknown u alone; an input row on nothing.
        pub const jac_pattern: [n_u]M = blk: {
            @setEvalBranchQuota(100 * n_u + 1000);
            var p: [n_u]M = @splat(0);
            for (outs) |u| p[u] = @as(M, 1) << u;
            break :blk p;
        };

        /// Output pin k: g · (V - level), with the static levels in any
        /// analysis but a transient. An input pin draws nothing.
        pub fn eval(comptime S: type, x: *const [n_u]S.V, _: *const Model, inst: *const Instance, sim: contract.SimState) contract.Rows(Self, S) {
            var r: contract.Rows(Self, S) = undefined;
            comptime assert(r.len == n_u);
            inline for (spec.pins, 0..) |p, u| {
                if (!p.out) {
                    r[u] = S.con(0).to(contract.rowMask(Self, u));
                } else {
                    const k = index[u];
                    comptime assert(k < n_out);
                    const g = if (sim.kind != .tran) inst.dc_g[k] else ramp(inst.g_from[k], inst.g_to[k], inst.g_t0[k], inst.g_t1[k], sim.t);
                    const v = if (sim.kind != .tran) inst.dc_lvl[k] else ramp(inst.lvl_from[k], inst.lvl_to[k], inst.lvl_t0[k], inst.lvl_t1[k], sim.t);
                    r[u] = S.probe(u, x[u]).addC(-v).scale(g).to(contract.rowMask(Self, u));
                }
            }
            return r;
        }

        /// Time 0 of `spec.program`: `initProgram` over it, loaded once
        /// per instance (never freed: the contract has no teardown).
        pub fn initState(m: *const Model, inst: *Instance) State {
            const p = std.heap.smp_allocator.create(Program) catch return dead(inst);
            p.* = serial.load(std.heap.smp_allocator, spec.program) catch return dead(inst);
            return initProgram(m, inst, p);
        }

        /// Time 0 of `p`, which must outlive the instance: every input x,
        /// then the tick-0 events (initial blocks, continuous assignments);
        /// the outputs as they stand are both the static and the ramp levels.
        pub fn initProgram(m: *const Model, inst: *Instance, p: *const Program) State {
            var st: State = .{};
            birth(m, inst, &st, p) catch {
                poison(inst);
                st.inst = inst.*;
                return st;
            };
            st.inst = inst.*;
            assert(st.work == null); // No step is in flight.
            assert(st.accepted != null);
            return st;
        }

        fn birth(m: *const Model, inst: *Instance, st: *State, p: *const Program) !void {
            const r = try Run.init(p);
            errdefer r.free();
            // A design with no pins of a direction never indexes them.
            if (n_in != 0) for (ins) |u| try drive(&r.s, spec.pins[u], .x);
            try run(&r.s, 0);
            outputs(m, inst, &r.s, 0, true);
            keep(inst, &r.s);
            st.accepted = r;
            // Time 0 is never rejected.
            r.flush();
        }

        /// At a static solve (any analysis but a transient) the inputs are
        /// read by threshold at the engine's tick, whose events run again,
        /// and an output that moved asks the host to iterate once more. In
        /// a transient every crossing since the last sample is delivered at
        /// its nearest tick and every tick up to `sim.t` runs; an output
        /// that moved starts its ramp at `sim.t`, where its value has not
        /// changed, so the step never needs repeating (`.ok` always).
        pub fn updateState(comptime S: type, m: *const Model, inst: *Instance, x: [n_u]f64, st: *State, sim: contract.SimState) contract.UpdateResult {
            _ = S;
            if (st.work) |w| w.free();
            st.work = null;
            if (inst.stopped) return .ok;
            if (sim.kind != .tran) {
                const moved = static(m, inst, x, st, sim.t) catch {
                    poison(inst);
                    return .ok;
                };
                return if (moved) .{ .request_reject_at = sim.t } else .ok;
            }
            transient(m, inst, x, st, sim.t) catch poison(inst);
            return .ok;
        }

        fn static(m: *const Model, inst: *Instance, x: [n_u]f64, st: *State, t: f64) !bool {
            assert(!inst.stopped);
            const s = try open(st);
            if (n_in != 0) for (ins, 0..) |u, i| {
                try drive(s, spec.pins[u], threshold(m, x[u]));
                inst.a2d_v[i] = x[u];
            };
            inst.a2d_t = t;
            try run(s, s.scheduler.now);
            const before = inst.dc_lvl ++ inst.dc_g;
            outputs(m, inst, s, t, true);
            keep(inst, s);
            return !std.mem.eql(f64, &before, &(inst.dc_lvl ++ inst.dc_g));
        }

        const Edge = struct { tick: u64, pin: u32, bit: Bit };

        fn transient(m: *const Model, inst: *Instance, x: [n_u]f64, st: *State, t: f64) !void {
            assert(!inst.stopped);
            const horizon = time.tickAtOrBefore(t, tick);
            const hi = vth(m) + m.vhys / 2;
            const lo = vth(m) - m.vhys / 2;
            var edges: [2 * n_in]Edge = undefined;
            var n: usize = 0;
            // A crossing's time matters only if the step wakes a process: one
            // that wakes nothing runs at its secant tick, unlocated.
            var late = false;
            var woke = false;
            if (n_in != 0) for (ins, 0..) |u, i| {
                const v0 = inst.a2d_v[i];
                const v1 = x[u];
                if (std.math.isNan(v0)) {
                    // The first sample is the reference: no crossing, delivered
                    // at the engine's own tick.
                    edges[n] = .{ .tick = 0, .pin = u, .bit = threshold(m, v1) };
                    n += 1;
                } else for ([2]f64{ hi, lo }, [2]f64{ 1, -1 }, [2]Bit{ .one, .zero }, [2]u2{ 1, 2 }) |th, dir, bit, wake| {
                    if (!time.crosses(dir, v0 - th, v1 - th)) continue;
                    // The secant between the two samples, as `cross` finds it.
                    const tc = inst.a2d_t + (t - inst.a2d_t) * (th - v0) / (v1 - v0);
                    late = late or t - tc > ttol(m);
                    woke = woke or inst.wakes[i] & wake != 0;
                    // ponytail: a crossing that rounds past `horizon` runs at it,
                    // a tick early, rather than holding an event past `t`.
                    edges[n] = .{ .tick = @min(@as(u64, @intFromFloat(@max(@round(ticks(tc)), 0))), horizon), .pin = u, .bit = bit };
                    n += 1;
                }
                inst.a2d_v[i] = v1;
            };
            inst.a2d_t = t;
            assert(n <= edges.len); // At most two edges per input.
            const due = inst.next_ev != inf and time.tickAtOrBefore(inst.next_ev, tick) <= horizon;
            if (late and (woke or due)) inst.late_cross = true;
            if (n == 0 and !due) return;
            // Stable, at most two edges per input.
            std.sort.insertion(Edge, edges[0..n], {}, struct {
                fn lt(_: void, l: Edge, r: Edge) bool {
                    return l.tick < r.tick;
                }
            }.lt);
            const s = try open(st);
            if (n_in != 0) for (edges[0..n]) |e| {
                if (e.tick > s.scheduler.now) {
                    try run(s, e.tick - 1);
                    // Nothing is left before `e.tick`, so the clock may move there.
                    if (s.scheduler.phase != .stopped) s.scheduler.now = e.tick;
                }
                try drive(s, spec.pins[e.pin], e.bit);
            };
            try run(s, @max(horizon, s.scheduler.now));
            outputs(m, inst, s, t, false);
            keep(inst, s);
        }

        /// This step's run: a copy of the accepted one.
        fn open(st: *State) !*SimState {
            assert(st.work == null); // `updateState` dropped the last one.
            const r = try st.accepted.?.fork();
            st.work = r;
            return &r.s;
        }

        /// Every event at a tick up to `limit`; a run-time error fails.
        fn run(s: *SimState, limit: u64) !void {
            assert(limit >= s.scheduler.now); // The clock never runs back.
            const stop = try Interp.runUntil(s, limit);
            assert(stop == .idle); // No analog link: only `idle` stops it.
            assert(s.scheduler.now <= limit);
        }

        /// The A2D store of `bit` into pin `p`, with every wake it causes.
        fn drive(s: *SimState, p: Pin, bit: Bit) !void {
            assert(!p.out); // An A2D bridge drives an input pin.
            const sl = s.p.slots.get(p.slot);
            const n = Program.words(sl.ty.width);
            assert(p.bit < sl.ty.width);
            const planes = try s.scratch.allocator().alloc(u64, 2 * n);
            @memcpy(planes[0..n], s.v[sl.word..][0..n]);
            @memcpy(planes[n..], s.x[sl.word..][0..n]);
            const value: logic.Literal = .{ .width = sl.ty.width, .signed = sl.ty.signed, .sized = true, .planes = planes };
            logic.setBit(value, p.bit, bit);
            try s.store(p.slot, value);
        }

        /// Each output's level and conductance from the engine: the static
        /// ones when `static_`, else a ramp from its value at `t`.
        fn outputs(m: *const Model, inst: *Instance, s: *const SimState, t: f64, static_: bool) void {
            assert(s.v.len == s.x.len);
            if (n_out != 0) for (outs, 0..) |u, k| {
                const p = spec.pins[u];
                assert(p.out);
                const word = s.p.slots.get(p.slot).word + p.bit / 64;
                const at: u6 = @intCast(p.bit % 64);
                const b: u2 = @intCast(((s.v[word] >> at) & 1) | (((s.x[word] >> at) & 1) << 1));
                const lvl = switch (b) {
                    0 => m.vss,
                    1 => m.vdd,
                    else => (m.vdd + m.vss) / 2,
                };
                const g = if (b == 2) m.gz else 1 / m.rout;
                if (static_) {
                    inst.dc_lvl[k] = lvl;
                    inst.dc_g[k] = g;
                    inst.lvl_from[k] = lvl;
                    inst.lvl_to[k] = lvl;
                    inst.g_from[k] = g;
                    inst.g_to[k] = g;
                } else {
                    arm(m, &inst.lvl_from[k], &inst.lvl_to[k], &inst.lvl_t0[k], &inst.lvl_t1[k], t, lvl);
                    arm(m, &inst.g_from[k], &inst.g_to[k], &inst.g_t0[k], &inst.g_t1[k], t, g);
                }
            };
        }

        /// The engine's next event, whether it stopped, and which input
        /// edges wake a process now.
        fn keep(inst: *Instance, s: *SimState) void {
            inst.stopped = s.scheduler.phase == .stopped;
            inst.next_ev = if (s.scheduler.peekTime()) |k| seconds(k) else inf;
            if (n_in != 0) for (ins, 0..) |u, i| {
                const p = spec.pins[u];
                var up = false;
                var down = false;
                for (s.terms[p.slot].items) |t| {
                    const su = s.susps.items[t.susp];
                    if (!su.alive or su.gen != t.gen) continue; // Stale.
                    if (t.width != 0 and (p.bit < t.lo or p.bit >= t.lo + t.width)) continue;
                    // An edge term sees only its least significant bit.
                    const lsb = p.bit == t.lo;
                    up = up or t.edge == .any or lsb and t.edge == .posedge;
                    down = down or t.edge == .any or lsb and t.edge == .negedge;
                }
                // A continuous driver reading the slot wakes on any change.
                const p_ = s.p;
                if (p.slot + 1 < p_.fan_start.len) for (p_.fan[p_.fan_start[p.slot]..p_.fan_start[p.slot + 1]]) |pc| if (s.armed[pc]) {
                    up = true;
                    down = true;
                };
                inst.wakes[i] = @as(u2, @intFromBool(up)) | @as(u2, @intFromBool(down)) << 1;
            };
        }

        /// `query`: a crossing ran late; `commit`: this step's run and
        /// `Instance` are the accepted ones; `revert`: the accepted ones are
        /// restored, the static levels excepted (see `Instance`).
        pub fn stateCtl(_: *const Model, inst: *Instance, st: *State, op: contract.StateCtlOp) bool {
            switch (op) {
                .query => return inst.late_cross,
                .commit => {
                    if (st.work) |w| {
                        w.flush();
                        st.accepted.?.free();
                        st.accepted = w;
                    }
                    st.work = null;
                    inst.late_cross = false;
                    st.inst = inst.*;
                },
                .revert => {
                    const lvl = inst.dc_lvl;
                    const g = inst.dc_g;
                    inst.* = st.inst;
                    inst.dc_lvl = lvl;
                    inst.dc_g = g;
                    if (st.work) |w| w.free();
                    st.work = null;
                },
            }
            assert(st.work == null);
            return false;
        }

        /// The next digital event or end of an output ramp after `t`.
        pub fn pendingBreakpoint(inst: *const Instance, t: f64) ?f64 {
            var best = if (inst.next_ev > t) inst.next_ev else inf;
            for (inst.lvl_t1 ++ inst.g_t1) |t1| {
                if (t1 > t) best = @min(best, t1);
            }
            if (best == inf) return null;
            assert(best > t); // Never a time at or before `t`, nor a NaN.
            return best;
        }

        fn ramp(from: f64, to: f64, t0: f64, t1: f64, t: f64) f64 {
            if (from == to) return to;
            return from + (to - from) * std.math.clamp((t - t0) / (t1 - t0), 0, 1);
        }

        /// A ramp toward `target` from its value at `t`, unless it is headed
        /// there already; `trise` long upward, `tfall` downward.
        fn arm(m: *const Model, from: *f64, to: *f64, t0: *f64, t1: *f64, t: f64, target: f64) void {
            if (to.* == target) return;
            from.* = ramp(from.*, to.*, t0.*, t1.*, t);
            to.* = target;
            t0.* = t;
            t1.* = t + if (target > from.*) rise(m) else fall(m);
        }

        fn seconds(k: u64) f64 {
            const f: f64 = @floatFromInt(k);
            const t = if (spec.units < 0) f / decade else f * decade;
            assert(t >= 0); // A tick count is never before time 0.
            return t;
        }

        fn ticks(t: f64) f64 {
            return if (spec.units < 0) t * decade else t / decade;
        }

        fn rise(m: *const Model) f64 {
            const r = if (m.trise > 0) m.trise else 1e-12;
            assert(r > 0); // A NaN or non-positive card value is 1 ps.
            return r;
        }

        fn fall(m: *const Model) f64 {
            const f = if (m.tfall > 0) m.tfall else 1e-12;
            assert(f > 0); // A NaN or non-positive card value is 1 ps.
            return f;
        }

        fn vth(m: *const Model) f64 {
            return if (std.math.isNan(m.vth)) (m.vdd + m.vss) / 2 else m.vth;
        }

        fn ttol(m: *const Model) f64 {
            return if (std.math.isNan(m.ttol)) @min(rise(m), fall(m)) / 50 else m.ttol;
        }

        /// A static read of `v`: 1 above the band, 0 below, x inside it.
        fn threshold(m: *const Model, v: f64) Bit {
            if (v > vth(m) + m.vhys / 2) return .one;
            if (v < vth(m) - m.vhys / 2) return .zero;
            return if (m.vhys > 0) .x else .zero;
        }

        /// A failed engine run: every output reads NaN, which the host
        /// reports as a failed step.
        fn poison(inst: *Instance) void {
            inst.dc_lvl = @splat(nan);
            inst.lvl_from = @splat(nan);
            inst.lvl_to = @splat(nan);
            inst.stopped = true;
            assert(inst.stopped); // `updateState` never runs the engine again.
        }

        fn dead(inst: *Instance) State {
            poison(inst);
            return .{ .inst = inst.* };
        }
    };
}

/// One run of the device's program on the heap, its memory its own arena,
/// its transcript held until `flush`.
const Run = struct {
    arena: std.heap.ArenaAllocator,
    say: std.Io.Writer.Allocating,
    s: SimState,

    const gpa = std.heap.smp_allocator;

    /// Time 0 of `p`.
    fn init(p: *const Program) !*Run {
        const r = try gpa.create(Run);
        r.arena = .init(gpa);
        errdefer r.free();
        r.say = .init(r.arena.allocator());
        r.s = try SimState.init(r.arena.allocator(), p, &r.say.writer);
        assert(r.s.out == &r.say.writer);
        return r;
    }

    /// A deep copy of `r` at its tick boundary, with an empty transcript.
    fn fork(r: *const Run) !*Run {
        const c = try gpa.create(Run);
        c.arena = .init(gpa);
        errdefer c.free();
        const a = c.arena.allocator();
        c.say = .init(a);
        c.s = try dupe(SimState, a, r.s);
        c.s.arena = a;
        c.s.out = &c.say.writer;
        c.s.scratch = .init(a);
        assert(c.s.p == r.s.p);
        return c;
    }

    /// The held transcript to stderr: a host's stdout may carry its own
    /// results.
    fn flush(r: *Run) void {
        const said = r.say.written();
        if (said.len != 0) std.debug.print("{s}", .{said});
        r.say.clearRetainingCapacity();
        assert(r.say.written().len == 0);
    }

    fn free(r: *Run) void {
        r.arena.deinit();
        gpa.destroy(r);
    }
};

/// A deep copy of `x` into `a`: every slice and list it reaches is new;
/// single pointers (the `Program`, the writer) are shared. The fields
/// `fork` resets (allocators, the scratch arena) are copied shallow here.
fn dupe(comptime T: type, a: Allocator, x: T) Allocator.Error!T {
    if (comptime !hasSlice(T)) return x;
    if (comptime isMulti(T)) return x.clone(a);
    if (comptime isList(T)) {
        var out = try @TypeOf(x).initCapacity(a, x.capacity);
        for (x.items) |e| out.appendAssumeCapacity(try dupe(@TypeOf(x.items[0]), a, e));
        return out;
    }
    if (comptime isQueue(T)) {
        const buf = try a.alloc(@TypeOf(x.items[0]), x.cap);
        for (buf[0..x.items.len], x.items) |*d, e| d.* = try dupe(@TypeOf(e), a, e);
        var out = x;
        out.items = buf[0..x.items.len];
        return out;
    }
    if (comptime isHashMap(T)) {
        var out = try x.clone(a);
        var it = out.valueIterator();
        while (it.next()) |v| v.* = try dupe(@TypeOf(v.*), a, v.*);
        return out;
    }
    switch (@typeInfo(T)) {
        .optional => |o| return if (x) |v| try dupe(o.child, a, v) else null,
        .array => |ar| {
            var out: T = undefined;
            for (&out, x) |*d, e| d.* = try dupe(ar.child, a, e);
            return out;
        },
        .pointer => |ptr| {
            comptime assert(ptr.size == .slice);
            const out = try a.alloc(ptr.child, x.len);
            for (out, x) |*d, e| d.* = try dupe(ptr.child, a, e);
            return out;
        },
        .@"struct" => |s| {
            var out: T = x;
            inline for (s.field_names, s.field_types) |name, F| @field(out, name) = try dupe(F, a, @field(x, name));
            return out;
        },
        .@"union" => switch (x) {
            inline else => |v, tag| return @unionInit(T, @tagName(tag), try dupe(@TypeOf(v), a, v)),
        },
        else => @compileError("Device.dupe: no copy for " ++ @typeName(T)),
    }
}

/// Whether a value of `T` reaches memory a copy must duplicate: a slice,
/// or a container of the standard library holding one.
fn hasSlice(comptime T: type) bool {
    @setEvalBranchQuota(100_000);
    if (T == Allocator or T == std.heap.ArenaAllocator or T == std.Io) return false;
    if (isMulti(T) or isList(T) or isQueue(T) or isHashMap(T)) return true;
    return switch (@typeInfo(T)) {
        .optional => |o| hasSlice(o.child),
        .array => |ar| hasSlice(ar.child),
        .pointer => |ptr| switch (ptr.size) {
            .slice => true,
            // The `Program` and the writer: shared.
            .one => false,
            .many, .c => @compileError("Device.dupe: a many-pointer in " ++ @typeName(T)),
        },
        .@"struct" => |s| inline for (s.field_types) |F| {
            if (hasSlice(F)) break true;
        } else false,
        .@"union" => |u| inline for (u.field_types) |F| {
            if (hasSlice(F)) break true;
        } else false,
        else => false,
    };
}

fn isMulti(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Field") and @hasDecl(T, "Slice") and @hasField(T, "bytes");
}

fn isList(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasField(T, "items") and @hasField(T, "capacity");
}

fn isQueue(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasField(T, "items") and @hasField(T, "cap");
}

fn isHashMap(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "KV") and @hasField(T, "metadata");
}

test "Device: a step over a one-slot design keeps a run its next step forks" {
    // Oracle: the asserts above, which pair `open`'s fork with `keep`.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var b: @import("Builder.zig") = .init(arena.allocator());
    _ = try b.slot(.int(2, false), &.{0}, &.{3});
    const p = b.finish();
    const Dev = Device(.{
        .U = enum { a, y },
        .program = "",
        .pins = &.{ .{ .out = false, .slot = 0, .bit = 0 }, .{ .out = true, .slot = 0, .bit = 1 } },
        .units = -9,
    });
    const m: Dev.Model = .{};
    var inst: Dev.Instance = .{};
    var st = Dev.initProgram(&m, &inst, &p);
    try std.testing.expect(!inst.stopped);
    // A static solve reads 5 V on the input as 1; the output, x, holds.
    try std.testing.expectEqual(contract.UpdateResult.ok, Dev.updateState(void, &m, &inst, .{ 5, 0 }, &st, .{}));
    _ = Dev.stateCtl(&m, &inst, &st, .commit);
    _ = Dev.updateState(void, &m, &inst, .{ 0, 0 }, &st, .{ .kind = .tran, .t = 1e-9 });
    _ = Dev.stateCtl(&m, &inst, &st, .revert);
    try std.testing.expectEqual(@as(?f64, null), Dev.pendingBreakpoint(&inst, 1));
    st.accepted.?.free();
    // No pins: every bridge loop is empty and never indexes a pin.
    const None = Device(.{ .U = enum(u8) { _ }, .program = "", .pins = &.{}, .units = 0 });
    const m0: None.Model = .{};
    var inst0: None.Instance = .{};
    var st0 = None.initProgram(&m0, &inst0, &p);
    _ = None.updateState(void, &m0, &inst0, .{}, &st0, .{ .kind = .tran, .t = 2 });
    _ = None.stateCtl(&m0, &inst0, &st0, .commit);
    try std.testing.expect(!inst0.stopped);
    st0.accepted.?.free();
}
