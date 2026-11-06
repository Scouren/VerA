//! The analog testbench runtime (`std_sim.bench`), its part: what a point prints: the unknowns, the residual and Jacobian, and the certify gates (finite differences, finite values, state).
//! Cites: each item cites its own clause.
//!
//! Contents:
//! - `u_names`, `finite_decades`, `finite_samples`, `fieldName`, `point`, `fdCheck`, `fdEval`, `fdRows`, `finiteCheck`, `stateCheck`, `stateFields`, `sameBits`, `allZero`

const std = @import("std");
const contract = @import("contract");
const D = @import("../bench.zig").D;
const Dual = @import("batch.zig").Dual;
const Row = @import("batch.zig").Row;
const State = @import("step.zig").State;
const Val = @import("batch.zig").Val;
const constCheck = @import("gates.zig").constCheck;
const fd_certify = @import("../bench.zig").fd_certify;
const finite_proved = @import("../bench.zig").finite_proved;
const fusedCheck = @import("gates.zig").fusedCheck;
const hub = @import("../bench.zig");
const laneCheck = @import("batch.zig").laneCheck;
const mutable_eval = @import("../bench.zig").mutable_eval;
const muteDomain = @import("../bench.zig").muteDomain;
const n_u = @import("../bench.zig").n_u;
const narrowCheck = @import("gates.zig").narrowCheck;
const patternCheck = @import("gates.zig").patternCheck;
const print_residual = @import("../bench.zig").print_residual;
const qRowsOf = @import("gates.zig").qRowsOf;
const run = @import("../bench.zig").run;
const sayPoint = @import("step.zig").sayPoint;
const withConst = @import("gates.zig").withConst;

/// Each unknown as the transcript and the directives spell it: the
/// device's `U` member, already `fieldName`'s spelling.
pub const u_names = blk: {
    const f = @typeInfo(D.U).@"enum".field_names;
    var names: [f.len][]const u8 = undefined;
    for (f, 0..) |e, i| names[i] = e;
    break :blk names;
};

/// The prover-soundness gate, on under `--certify`
/// for a device whose every contribution unit the prover rated
/// `.optimized` (`finite_proved`): its rows are finite doubles for any
/// finite unknowns and in-range card (`proof.FloatMode`'s rules). So `eval`
/// and `q` on this point's card and instance, at random unknowns, must
/// return finite rows; a NaN or an inf is a prover bug. The testbench's
/// card, not `D.Model{}`: without `//! param` it is the defaults, and with
/// one a default may be an error the card overrides (§6.3.4, a dependent
/// default `11 % zero_divisor`). Rule 3 there assumes `+ - * /` do not
/// overflow at device magnitudes, so each unknown is drawn log-uniform in
/// magnitude over 10^finite_decades, either sign; one time in eight
/// exactly 0 (the divisor a prover must not miss) and one in eight at the
/// bound, where overflow lives. Seeded by the point, so a failure reruns.
/// Silent on success but for one census line.
/// ponytail: one fixed bound (1 kV, 1 kA); thread `--unknown-bound=` here
/// once the suite compiles with one.
pub const finite_decades = [2]f64{ -6.0, 3.0 };
pub const finite_samples = 64;
/// The device's spelling of a Verilog-A name as a `Model` field or `U`
/// member (codegen's `Ident`): every byte outside `[a-zA-Y]`, a leading
/// digit and a leading, trailing or doubled `_` as `Z<hex><hex>`, and a
/// Zig keyword or primitive with a trailing `Z`. The bench's
/// `operands.sanitize` spells directive names so.
pub fn fieldName(comptime name: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (name, 0..) |c, i| {
            const bare = switch (c) {
                'a'...'z', 'A'...'Y' => true,
                '0'...'9' => i != 0,
                '_' => i != 0 and i + 1 < name.len and name[i + 1] != '_',
                else => false,
            };
            out = if (bare) out ++ [_]u8{c} else out ++ [_]u8{ 'Z', "0123456789abcdef"[c >> 4], "0123456789abcdef"[c & 0xf] };
        }
        if (std.zig.Token.keywords.has(out) or std.zig.primitives.isPrimitive(out)) out = out ++ "Z";
        return out;
    }
}

/// One operating point: the bias, then whatever the model prints, then the
/// residual it stamps and the Jacobian the solver would see. Under
/// `//! print none` only the model's own output and the gates' FAILs print.
pub fn point(n: usize, x: *const [n_u]f64, model: *const D.Model, inst: contract.InstancePtr(D)) void {
    if (print_residual) {
        std.debug.print("--- point {d} ---\n", .{n});
        for (0..n_u) |i| std.debug.print("  x[{s}] = {e:.6}\n", .{ u_names[i], x[i] });
        if (hub.sim_state.t != 0.0 or hub.sim_state.dt != 0.0)
            std.debug.print("  t = {e:.6}  dt = {e:.6}\n", .{ hub.sim_state.t, hub.sim_state.dt });
    }

    // §5.10.5 the host's breakpoint hook, when codegen emitted one (only a
    // module with a `timer` has one). Printed OUTSIDE `print_residual`
    // because it is not part of the residual and the fixtures that test it
    // are `print none`; `@hasDecl` keeps every other transcript unchanged.
    if (@hasDecl(D, "nextBreakpoint")) {
        if (D.nextBreakpoint(model, hub.sim_state.t)) |bp|
            std.debug.print("  next_bp = {e:.6}\n", .{bp})
        else
            std.debug.print("  next_bp = none\n", .{});
    }

    // Differential gates — silent on success, fail the run loudly. They
    // evaluate at points around `x` that no analysis asked for, so a
    // §4.3.2 domain error there is muted (`vera_domain_muted`, read by
    // the printing artifact's `zDomain`); `x` itself is evaluated first,
    // unmuted, so its own error still reports.
    _ = D.eval(Val, x, model, inst, hub.sim_state);
    muteDomain(true);
    laneCheck(x, model, inst);
    fusedCheck(x, model, inst);
    patternCheck(x, model, inst);
    narrowCheck(x, model, inst);
    constCheck(x, model, inst);
    fdCheck(x, model, inst);
    finiteCheck(n, model, inst);
    muteDomain(false);

    // §9.4 the model's own transcript. Runs BEFORE the residual print so a
    // fixture's `$strobe` lines sit next to the bias that produced them.
    sayPoint(x, model, inst);
    if (!print_residual) return;

    const res = withConst(Dual, D.eval(Dual, x, model, inst, hub.sim_state), model, false);
    for (0..n_u) |i| {
        std.debug.print("  res[{s}] = {e:.6}\n", .{ u_names[i], res[i].v });
        for (0..n_u) |j| {
            if (res[i].d[j] == 0.0) continue;
            std.debug.print("    d res[{s}]/d x[{s}] = {e:.6}\n", .{ u_names[i], u_names[j], res[i].d[j] });
        }
    }
    // §5.6.1.2 the reactive half, when the model has one. Its derivative is
    // the capacitance/inductance matrix the host multiplies by d/dt.
    if (@hasDecl(D, "q")) {
        const qq = withConst(Dual, qRowsOf(Dual, x, model, inst), model, true);
        for (0..n_u) |i| {
            if (qq[i].v == 0.0 and allZero(qq[i].d)) continue;
            std.debug.print("  q[{s}] = {e:.6}\n", .{ u_names[i], qq[i].v });
            for (0..n_u) |j| {
                if (qq[i].d[j] == 0.0) continue;
                std.debug.print("    d q[{s}]/d x[{s}] = {e:.6}\n", .{ u_names[i], u_names[j], qq[i].d[j] });
            }
        }
    }
}

/// The derivative gate, on under the suite's
/// `--certify` (`fd_certify`): every Jacobian entry, as a host stamps it
/// (`withConst`), against a central difference of the value-only `eval`
/// and `q`. h = cbrt(eps)*max(|x|,1) makes the difference's truncation
/// error about eps^(2/3), so 1e-5 relative has margin and still sees a
/// wrong term. Where the forward and backward slopes disagree by more than
/// curvature explains, a kink or a branch sits inside +-h and nothing there
/// is smooth enough to difference: that lane is counted as skipped, never
/// judged. Silent on success but for one census line.
pub fn fdCheck(x: *const [n_u]f64, model: *const D.Model, inst: contract.InstancePtr(D)) void {
    if (!fd_certify) return;
    // In a small-signal analysis the rows carry the §4.6.3/§4.6.4 excitations,
    // which are sources and not part of the residual being linearized.
    if (hub.sim_state.kind == .ac or hub.sim_state.kind == .noise) return;
    var tally: [3]usize = .{ 0, 0, 0 }; // compared, skipped, failed
    const ad = withConst(Dual, D.eval(Dual, x, model, inst, hub.sim_state), model, false);
    fdRows("res", false, x, model, inst, &ad, &tally);
    if (comptime @hasDecl(D, "q")) {
        const aq = withConst(Dual, qRowsOf(Dual, x, model, inst), model, true);
        fdRows("q", true, x, model, inst, &aq, &tally);
    }
    std.debug.print("  fd_check: {d} compared, {d} skipped, {d} failed\n", .{ tally[0], tally[1], tally[2] });
    if (tally[2] != 0) std.process.exit(1);
}
pub fn fdEval(react: bool, x: *const [n_u]f64, model: *const D.Model, inst: contract.InstancePtr(D)) [n_u]f64 {
    var copy = inst.*; // a `mutable_eval` device writes its instance
    var out: [n_u]f64 = @splat(0.0);
    if (react) {
        if (comptime @hasDecl(D, "q")) for (&out, @as([n_u]Val.Of(0), qRowsOf(Val, x, model, &copy))) |*o, e| {
            o.* = e.v;
        };
    } else {
        const r: [n_u]Val.Of(0) = D.eval(Val, x, model, &copy, hub.sim_state);
        for (&out, r) |*o, e| o.* = e.v;
    }
    return out;
}
pub fn fdRows(what: []const u8, react: bool, x: *const [n_u]f64, model: *const D.Model, inst: contract.InstancePtr(D), ad: *const [n_u]Row, tally: *[3]usize) void {
    const eps = std.math.floatEps(f64);
    const r0 = fdEval(react, x, model, inst);
    for (0..n_u) |j| {
        const h = std.math.cbrt(eps) * @max(@abs(x[j]), 1.0);
        var xp = x.*;
        xp[j] += h;
        var xm = x.*;
        xm[j] -= h;
        const rp = fdEval(react, &xp, model, inst);
        const rm = fdEval(react, &xm, model, inst);
        for (0..n_u) |i| {
            const a = ad[i].d[j];
            if (!std.math.isFinite(a) or !std.math.isFinite(rp[i]) or !std.math.isFinite(rm[i]) or !std.math.isFinite(r0[i])) {
                tally[1] += 1;
                continue;
            }
            const fwd = (rp[i] - r0[i]) / h;
            const bwd = (r0[i] - rm[i]) / h;
            const round = 64.0 * eps * (@abs(rp[i]) + @abs(rm[i]) + @abs(r0[i])) / h;
            if (@abs(fwd - bwd) > 1e-3 * (@abs(fwd) + @abs(bwd)) + round) {
                tally[1] += 1;
                continue;
            }
            tally[0] += 1;
            const fd = 0.5 * (fwd + bwd);
            if (@abs(fd - a) <= 1e-5 * @max(@abs(fd), @abs(a)) + round) continue;
            tally[2] += 1;
            std.debug.print("fd_check FAIL: d {s}[{s}]/d x[{s}]: jacobian {e} vs central difference {e} (h={e})\n", .{ what, u_names[i], u_names[j], a, fd, h });
        }
    }
}

pub fn finiteCheck(n: usize, model: *const D.Model, inst: contract.InstancePtr(D)) void {
    if (!fd_certify or !finite_proved) return;
    var prng = std.Random.DefaultPrng.init(0x4c34b +% n);
    const r = prng.random();
    for (0..finite_samples) |k| {
        var x: [n_u]f64 = undefined;
        for (&x) |*e| {
            const sign: f64 = if (r.boolean()) 1.0 else -1.0;
            e.* = switch (r.uintLessThan(u8, 8)) {
                0 => 0.0,
                1 => sign * std.math.pow(f64, 10.0, finite_decades[1]),
                else => sign * std.math.pow(f64, 10.0, finite_decades[0] + (finite_decades[1] - finite_decades[0]) * r.float(f64)),
            };
        }
        const res = fdEval(false, &x, model, inst);
        const qq = fdEval(true, &x, model, inst);
        for (0..n_u) |i| {
            if (std.math.isFinite(res[i]) and std.math.isFinite(qq[i])) continue;
            std.debug.print("finite_check FAIL: point {d} sample {d}: res[{s}] = {e}, q[{s}] = {e}, but every unit was proved finite; x =", .{ n, k, u_names[i], res[i], u_names[i], qq[i] });
            for (x, 0..) |v, j| std.debug.print(" {s}={e}", .{ u_names[j], v });
            std.debug.print("\n", .{});
            std.process.exit(1);
        }
    }
    std.debug.print("  finite_check: {d} samples finite\n", .{finite_samples});
}

/// The state-machine gate, on under `--certify` for
/// a device with `stateCtl`: a host's reject path at each accepted point,
/// on copies. Commit the working state (the last accepted point, as a host
/// does before it may revert), try `updateState` at this point, then
/// `stateCtl(.revert)`: every `Instance` and `State` field must be back to
/// the bit, and `eval` must answer as it did before the attempt. Exempt:
/// the §5.6.1.2 staging twins `wb__k`/`wq__k`, which `updateState` writes
/// and only `.commit` reads, so a host stages them again before the next
/// commit (`codegen/instance.zig` `emitStateTwins`). Silent on success but
/// for one census line.
pub fn stateCheck(model: *const D.Model, inst: *const D.Instance, x: *const [n_u]f64, state: *const State) void {
    if (comptime State == void or !@hasDecl(D, "stateCtl")) return;
    if (!fd_certify) return;
    var ic = inst.*;
    var sc = state.*;
    _ = D.stateCtl(model, &ic, &sc, .commit);
    const inst0 = ic;
    const state0 = sc;
    const before = fdEval(false, x, model, &ic);
    _ = D.updateState(Val, model, &ic, x.*, &sc, hub.sim_state);
    _ = D.stateCtl(model, &ic, &sc, .revert);
    const fields = stateFields("Instance", D.Instance, &inst0, &ic) + stateFields("State", State, &state0, &sc);
    const after = fdEval(false, x, model, &ic);
    for (0..n_u) |i| {
        if (@as(u64, @bitCast(before[i])) == @as(u64, @bitCast(after[i])) or (before[i] != before[i] and after[i] != after[i])) continue;
        std.debug.print("state_check FAIL: res[{s}] is {e} before updateState and {e} after its revert\n", .{ u_names[i], before[i], after[i] });
        std.process.exit(1);
    }
    std.debug.print("  state_check: {d} fields restored\n", .{fields});
}
pub fn stateFields(what: []const u8, comptime T: type, want: *const T, got: *const T) usize {
    const names = @typeInfo(T).@"struct".field_names;
    @setEvalBranchQuota(1000 + 100 * names.len);
    var bad = false;
    inline for (names) |name| {
        const staged = comptime std.mem.startsWith(u8, name, "wb__") or std.mem.startsWith(u8, name, "wq__");
        if (!staged and !sameBits(@field(want.*, name), @field(got.*, name))) {
            std.debug.print("state_check FAIL: {s}.{s} is {any} after updateState and stateCtl(.revert), {any} before\n", .{ what, name, @field(got.*, name), @field(want.*, name) });
            bad = true;
        }
    }
    if (bad) std.process.exit(1);
    return names.len;
}
/// `a` and `b` to the bit, NaN payloads included. An integer compares by
/// value: a held wide `reg` is a `uN` (`ZW`, N up to 128) whose storage
/// has padding bits LLVM leaves undefined, so the bytes of two equal
/// copies may differ outside Debug.
pub fn sameBits(a: anytype, b: @TypeOf(a)) bool {
    return switch (@typeInfo(@TypeOf(a))) {
        .int => a == b,
        .array => for (a, b) |x, y| {
            if (!sameBits(x, y)) break false;
        } else true,
        // else: floats, bools, pointers and the padding-free structs a device holds: bytes are bits
        else => std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b)),
    };
}

pub fn allZero(v: [n_u]f64) bool {
    for (v) |e| if (e != 0.0) return false;
    return true;
}
