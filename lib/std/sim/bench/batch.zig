//! The analog testbench runtime (`std_sim.bench`), its part: the `@Vector(NL, f64)` batch family a `batch_ok` device runs and its lane checks.
//! Cites: each item cites its own clause.
//!
//! Contents:
//! - `Dual`, `Row`, `lane_of`, `Val`, `NL`, `VF`, `batch_lead`, `batch_insts`, `Batch`, `V`, `Of`, `con`, `lift`, `probe`, `sel`, `B`, `Inner`, `Lane`, `lane_count`, `fromLanes`, `instLane`, `leadBegin`, `leadNext`, `leadMerge`, `BatchCore`, `laneOf`, `decide`, `decideI`, `strip`, `to`, `val`, `leadKeep`, `ddxAt`, `add`, `sub`, `neg`, `mul`, `div`, `scale`, `addC`, `exp`, `log`, `expm1`, `log1p`, `sqrt`, `sin`, `cos`, `tanh`, `sinh`, `cosh`, `atan`, `pow`, `lt`, `le`, `eq`, `DualC`, `dense`, `laneCheck`, `laneCheckSpread`, `laneAssert`

const std = @import("std");
const contract = @import("contract");
const D = @import("../bench.zig").D;
const hub = @import("../bench.zig");
const n_u = @import("../bench.zig").n_u;
const narrowCheck = @import("gates.zig").narrowCheck;
const point = @import("report.zig").point;
const qRowsOf = @import("gates.zig").qRowsOf;
const run = @import("../bench.zig").run;
const u_names = @import("report.zig").u_names;

/// Forward-mode dual: the contract's reference family
/// (`contract.RefFamily`), each value carrying only the lanes of the
/// unknowns it may depend on. A row is read through `dense`. `collapsed`
/// is the contract's `collapse_applied` trait: the testbench evaluates
/// with `false`, and `narrowCheck` with both.
pub const Dual = DualC(false);
/// The local matrix row a host assembles: the value and every column's
/// partial, indexable at run time.
pub const Row = struct { v: f64, d: [n_u]f64 = @splat(0.0) };
/// Unknown `u` on lane `u`; `u32`, so past 255 unknowns too.
pub const lane_of = blk: {
    var l: [n_u]u32 = undefined;
    for (&l, 0..) |*e, u| e.* = u;
    break :blk l;
};
/// The value family of the value-only entry points (`updateState`,
/// `limit`, `seed`, `collapse`, `derive`, the iteration hooks):
/// the reference family with no lanes, so every path runs the arithmetic
/// `eval` does.
pub const Val = contract.RefFamily(f64, &@as([n_u]u8, @splat(contract.no_lane)), .{});

/// A batch family: `V` is NL operating points, one per vector element, and
/// every value is lane-free. Per element it computes what `Val` does:
/// `contract.RefFamily`'s IEEE division, `gm` transcendentals.
/// Instantiated only for a device that declares `batch_ok`; a
/// `batch_lead` device decides per point, and the family runs the lead
/// protocol (`contract.LeadState`), so `val` answers the leader.
pub const NL = 4;
pub const VF = @Vector(NL, f64);
pub var batch_lead: contract.LeadState(NL, true) = .{};
/// Each point's own `Instance` (contract.zig `batch_inst`).
pub var batch_insts: [NL]*const D.Instance = undefined;
pub const Batch = struct {
    pub const V = VF;
    pub const Of = BatchCore.Of;
    pub const con = BatchCore.con;
    pub const lift = BatchCore.lift;
    pub const probe = BatchCore.probe;
    pub const sel = BatchCore.sel;
    pub const B = BatchCore.B;
    pub const Inner = BatchCore;
    pub const Lane = Val;
    pub const lane_count = NL;
    pub const fromLanes = BatchCore.fromLanes;
    pub const instLane = BatchCore.instLane;
    pub fn leadBegin() void {
        batch_lead.begin();
    }
    pub fn leadNext() bool {
        return batch_lead.next();
    }
    pub fn leadMerge(out: anytype, new: @TypeOf(out.*)) void {
        contract.leadMergeInto(out, new, batch_lead.keep());
    }
};
pub const BatchCore = struct {
    pub const V = VF;
    pub const Lane = Val;
    pub const lane_count = NL;
    pub fn laneOf(a: B, comptime w: usize) Val.Of(0) {
        return Val.con(a.v[w]);
    }
    pub fn fromLanes(comptime _: contract.Mask(D), ls: [NL]Val.Of(0)) B {
        var r: VF = undefined;
        inline for (0..NL) |w| r[w] = ls[w].v;
        return .{ .v = r };
    }
    pub fn decide(comptime op: std.math.CompareOperator, a: B, b: B) bool {
        const c: @Vector(NL, bool) = switch (op) {
            .lt => a.v < b.v,
            .lte => a.v <= b.v,
            .gt => a.v > b.v,
            .gte => a.v >= b.v,
            .eq => a.v == b.v,
            .neq => a.v != b.v,
        };
        return batch_lead.mark(c);
    }
    pub fn decideI(a: B) i64 {
        var r: @Vector(NL, i64) = undefined;
        inline for (0..NL) |w| r[w] = std.math.lossyCast(i64, @round(a.v[w]));
        return batch_lead.markI(r);
    }
    pub fn strip(a: B) B {
        return a;
    }
    pub fn instLane(comptime T: type, comptime w: usize) *const T {
        comptime std.debug.assert(T == D.Instance);
        return batch_insts[w];
    }
    pub fn Of(comptime _: contract.Mask(D)) type {
        return B;
    }
    pub fn con(c: f64) B {
        return .{ .v = @splat(c) };
    }
    pub fn lift(v: VF) B {
        return .{ .v = v };
    }
    pub fn probe(comptime _: usize, v: VF) B {
        return .{ .v = v };
    }
    pub fn sel(c: B, a: B, b: B) B {
        return .{ .v = @select(f64, c.v != zeros, a.v, b.v) };
    }
    const zeros: VF = @splat(0.0);
    const ones: VF = @splat(1.0);
    pub const B = struct {
        v: VF,
        fn map1(a: B, comptime f: anytype) B {
            var r: VF = undefined;
            inline for (0..NL) |i| r[i] = f(a.v[i]);
            return .{ .v = r };
        }
        pub fn to(a: B, comptime _: contract.Mask(D)) B {
            return a;
        }
        pub fn val(a: B) f64 {
            const arr: [NL]f64 = a.v;
            return arr[batch_lead.leader];
        }
        pub fn leadKeep(a: *B, n: B, keep: @Vector(NL, bool)) void {
            a.v = @select(f64, keep, n.v, a.v);
        }
        pub fn ddxAt(_: B, comptime _: usize) f64 {
            return 0.0;
        }
        pub fn add(a: B, b: B) B {
            return .{ .v = a.v + b.v };
        }
        pub fn sub(a: B, b: B) B {
            return .{ .v = a.v - b.v };
        }
        pub fn neg(a: B) B {
            return .{ .v = -a.v };
        }
        pub fn mul(a: B, b: B) B {
            return .{ .v = a.v * b.v };
        }
        pub fn div(a: B, b: B) B {
            return .{ .v = a.v / b.v };
        }
        pub fn scale(a: B, c: f64) B {
            return .{ .v = a.v * @as(VF, @splat(c)) };
        }
        pub fn addC(a: B, c: f64) B {
            return .{ .v = a.v + @as(VF, @splat(c)) };
        }
        // exp/log take the whole vector (`contract.gm`: lane for lane the
        // scalar call's bits, which `batch_ok` promises).
        pub fn exp(a: B) B {
            return .{ .v = contract.gm.exp(a.v) };
        }
        pub fn log(a: B) B {
            return .{ .v = contract.gm.log(a.v) };
        }
        pub fn expm1(a: B) B {
            return map1(a, contract.gm.expm1);
        }
        pub fn log1p(a: B) B {
            return map1(a, std.math.log1p);
        }
        pub fn sqrt(a: B) B {
            return .{ .v = @sqrt(a.v) };
        }
        pub fn sin(a: B) B {
            return map1(a, contract.gm.sin);
        }
        pub fn cos(a: B) B {
            return map1(a, contract.gm.cos);
        }
        pub fn tanh(a: B) B {
            return map1(a, contract.gm.tanh);
        }
        pub fn sinh(a: B) B {
            return map1(a, contract.gm.sinh);
        }
        pub fn cosh(a: B) B {
            return map1(a, contract.gm.cosh);
        }
        pub fn atan(a: B) B {
            return map1(a, contract.gm.atan);
        }
        pub fn pow(a: B, c: f64) B {
            var r: VF = undefined;
            inline for (0..NL) |i| r[i] = contract.gm.pow(a.v[i], c);
            return .{ .v = r };
        }
        pub fn lt(a: B, b: B) B {
            return .{ .v = @select(f64, a.v < b.v, ones, zeros) };
        }
        pub fn le(a: B, b: B) B {
            return .{ .v = @select(f64, a.v <= b.v, ones, zeros) };
        }
        pub fn eq(a: B, b: B) B {
            return .{ .v = @select(f64, a.v == b.v, ones, zeros) };
        }
    };
};

comptime {
    // A batch value is its vector and nothing else: passed by value per op.
    std.debug.assert(@sizeOf(BatchCore.B) == @sizeOf(VF));
    contract.checkFamily(Dual);
    contract.checkFamily(Val);
    contract.checkFamily(Batch);
}

pub fn DualC(comptime collapsed: bool) type {
    return contract.RefFamily(f64, &lane_of, .{ .collapse_applied = collapsed });
}
/// `rows` (what `eval`, `q` or `qRows` returned) as `Row`s, each lane at
/// its unknown's column and every other column +0.
pub fn dense(rows: anytype) [rows.len]Row {
    var out: [rows.len]Row = undefined;
    inline for (0..rows.len) |r| out[r] = .{ .v = rows[r].v, .d = contract.denseRow(n_u, rows[r]) };
    return out;
}
/// The batch gate (ref/SIMD-Strategies T8): one `eval` over NL perturbed
/// copies of the operating point, one per element of `Batch.V`, must agree
/// with NL scalar evals, element by element. Bit equality is the
/// expectation — the same IEEE ops run in the same order per element —
/// with a 1e-12 relative escape for a vectorizer that contracts
/// differently than the scalar pipeline. Silent on success. Run twice:
/// nearby points, and points spread far enough that a `batch_lead`
/// device's points take different branches (the lead protocol's runs).
pub fn laneCheck(x: *const [n_u]f64, model: *const D.Model, inst: contract.InstancePtr(D)) void {
    laneCheckSpread(x, model, inst, 1.0e-3);
    if (comptime @hasDecl(D, "batch_lead") and D.batch_lead) laneCheckSpread(x, model, inst, 0.37);
}
pub fn laneCheckSpread(x: *const [n_u]f64, model: *const D.Model, inst: contract.InstancePtr(D), spread: f64) void {
    if (comptime !(@hasDecl(D, "batch_ok") and D.batch_ok)) return;
    // Every point its own instance: point k's real and integer fields
    // moved apart, so a point that read another's latch or held value
    // would differ from its scalar evaluation.
    var insts: [NL]D.Instance = @splat(inst.*);
    const inst_info = @typeInfo(D.Instance).@"struct";
    // A compact model's Instance has thousands of fields (BSIM4).
    @setEvalBranchQuota(1000 + 100 * inst_info.field_names.len);
    for (1..NL) |k| inline for (inst_info.field_names, inst_info.field_types) |name, FT| {
        const kf: f64 = @floatFromInt(k);
        if (FT == f64) {
            const v = @field(insts[k], name);
            if (std.math.isFinite(v)) @field(insts[k], name) = v * (1.0 + 0.25 * kf) + 0.125 * kf;
        } else if (FT == i64) {
            @field(insts[k], name) +%= @intCast(k);
        }
    };
    for (0..NL) |k| batch_insts[k] = &insts[k];
    var xs: [NL][n_u]f64 = undefined;
    var xv: [n_u]VF = undefined;
    for (0..NL) |k| {
        const s = 1.0 + spread * @as(f64, @floatFromInt(k));
        for (0..n_u) |i| xs[k][i] = x[i] * s + spread * @as(f64, @floatFromInt(k)) * @as(f64, if (i % 2 == 0) 1.0 else -1.0);
    }
    for (0..n_u) |i| {
        // Through an array: a vector index must be comptime-known.
        var lanes: [NL]f64 = undefined;
        for (0..NL) |k| lanes[k] = xs[k][i];
        xv[i] = lanes;
    }
    const rv: [n_u]Batch.B = D.eval(Batch, &xv, model, &insts[0], hub.sim_state);
    // The signatures the batched call produced are `contract.region`'s.
    const sigs = if (comptime @hasDecl(D, "batch_lead")) batch_lead.regions() else @as([NL]u16, @splat(0));
    for (0..NL) |k| {
        const want = contract.region(D, &xs[k], model, &insts[k], hub.sim_state);
        if (sigs[k] == want) continue;
        std.debug.print("lane_check FAIL: region lane {d}: batch {d} vs region {d}\n", .{ k, sigs[k], want });
        std.process.exit(1);
    }
    const qv: [n_u]Batch.B = if (comptime @hasDecl(D, "q")) qRowsOf(Batch, &xv, model, &insts[0]) else undefined;
    for (0..NL) |k| {
        const rs: [n_u]Val.Of(0) = D.eval(Val, &xs[k], model, &insts[k], hub.sim_state);
        for (0..n_u) |i| laneAssert("res", i, k, @as([NL]f64, rv[i].v)[k], rs[i].v);
        if (comptime @hasDecl(D, "q")) {
            const qs: [n_u]Val.Of(0) = qRowsOf(Val, &xs[k], model, &insts[k]);
            for (0..n_u) |i| laneAssert("q", i, k, @as([NL]f64, qv[i].v)[k], qs[i].v);
        }
    }
}

pub fn laneAssert(what: []const u8, i: usize, k: usize, a: f64, b: f64) void {
    if (@as(u64, @bitCast(a)) == @as(u64, @bitCast(b))) return;
    if (a != a and b != b) return; // NaN payloads may differ
    std.debug.print("lane_check FAIL: {s}[{s}] lane {d}: batch {e} vs scalar {e}\n", .{ what, u_names[i], k, a, b });
    std.process.exit(1);
}
