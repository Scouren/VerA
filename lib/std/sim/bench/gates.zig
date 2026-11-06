//! The analog testbench runtime (`std_sim.bench`), its part: the differential gates run at every point: the fused, pattern, narrow and constant-Jacobian checks.
//! Cites: each item cites its own clause.
//!
//! Contents:
//! - `n_q`, `fusedCheck`, `patternCheck`, `narrowCheck`, `narrowCheckAs`, `constCheck`, `constAssert`, `hasLane`, `narrowAssert`, `patAssert`, `rowAssert`, `fusedAssert`, `fusedAssertSite`, `qRowsOf`, `withConst`

const std = @import("std");
const contract = @import("contract");
const Batch = @import("batch.zig").Batch;
const D = @import("../bench.zig").D;
const Dual = @import("batch.zig").Dual;
const DualC = @import("batch.zig").DualC;
const Row = @import("batch.zig").Row;
const Val = @import("batch.zig").Val;
const dense = @import("batch.zig").dense;
const hub = @import("../bench.zig");
const n_u = @import("../bench.zig").n_u;
const set = @import("solve.zig").set;
const step = @import("step.zig").step;
const u_names = @import("report.zig").u_names;

/// §5.6.1.2 how many charges `q` returns, and the rows they stamp: `q`
/// returns one per `ddt` site and `contract.qRows` sums them into the
/// reactive residual's rows through `q_stamps`.
pub const n_q = contract.nQ(D);

/// The fused differential gate: `evalQ` shares ONE core call between the
/// two halves, so it must return exactly what the separate `eval` and `q`
/// return. Same ops, same order, same core — bit equality, no epsilon.
/// A mismatch means the shared-core hoist changed the physics, which is
/// the only way this refactor can be wrong.
pub fn fusedCheck(x: *const [n_u]f64, model: *const D.Model, inst: contract.InstancePtr(D)) void {
    if (comptime !@hasDecl(D, "evalQ")) return;
    const both = D.evalQ(Dual, x, model, inst, hub.sim_state);
    const both_res = dense(both.res);
    const both_q = dense(both.q);
    const res = dense(D.eval(Dual, x, model, inst, hub.sim_state));
    const qq = dense(D.q(Dual, x, model, inst, hub.sim_state));
    for (0..n_u) |i| {
        fusedAssert("res", i, both_res[i].v, res[i].v);
        for (0..n_u) |j| fusedAssert("dres", i, both_res[i].d[j], res[i].d[j]);
    }
    // §5.6.1.2 one charge per site (`contract.nQ`), compared as sites.
    for (0..n_q) |k| {
        fusedAssertSite("q", k, both_q[k].v, qq[k].v);
        for (0..n_u) |j| fusedAssertSite("dq", k, both_q[k].d[j], qq[k].d[j]);
    }
}

/// The structural-Jacobian gate. `jac_pattern`/`q_pattern` tell a host
/// which local matrix entries this device can fill, and the host DELETES
/// the stamps for the rest — it does not even reserve the matrix entry.
/// So a cleared bit with a nonzero partial behind it is a silently missing
/// Jacobian entry, and that is the one way the declaration can be wrong.
/// The converse is legal: the pattern over-approximates on purpose, and a
/// set bit that happens to be zero at this bias costs one stamp.
pub fn patternCheck(x: *const [n_u]f64, model: *const D.Model, inst: contract.InstancePtr(D)) void {
    const r = withConst(Dual, D.eval(Dual, x, model, inst, hub.sim_state), model, false);
    if (comptime @hasDecl(D, "jac_pattern")) patAssert("res", D.jac_pattern, &r);
    if (comptime @hasDecl(D, "jac_rows")) rowAssert("res", D.jac_rows, &r);
    if (comptime @hasDecl(D, "q")) {
        const qr = withConst(Dual, qRowsOf(Dual, x, model, inst), model, true);
        if (comptime @hasDecl(D, "q_pattern")) patAssert("q", D.q_pattern, &qr);
        if (comptime @hasDecl(D, "q_rows")) rowAssert("q", D.q_rows, &qr);
    }
}

/// The constant-column gate, the one a host relies on when it stamps
/// `contract.jacConst(D)` for every column outside `contract.derivReads(D)`
/// (the device reads no lane there). The promise is that such a column
/// enters every row linearly with the exact coefficient the table states,
/// so a unit step on it moves each row by that coefficient: checked on
/// `eval` and on the reactive rows, to the rounding of the rows' own
/// magnitude. A zero step answer matches an absent entry.
///
/// Run under BOTH collapse settings (`collapse_applied` false, then true),
/// stamping a guarded entry exactly when `contract.jacConstApplies` says a
/// host would: its `Model` flag set and the collapse state it names.
///
/// Always on, not behind a flag: a gate that has to be asked for is one
/// somebody forgets.
pub fn narrowCheck(x: *const [n_u]f64, model: *const D.Model, inst: contract.InstancePtr(D)) void {
    inline for (.{ false, true }) |collapsed| narrowCheckAs(collapsed, x, model, inst);
}

pub fn narrowCheckAs(comptime collapsed: bool, x: *const [n_u]f64, model: *const D.Model, inst: contract.InstancePtr(D)) void {
    const Dl = DualC(collapsed);
    const r0 = dense(D.eval(Dl, x, model, inst, hub.sim_state));
    const q0: [n_u]Row = if (comptime @hasDecl(D, "q")) dense(qRowsOf(Dl, x, model, inst)) else undefined;
    for (0..n_u) |c| {
        if (hasLane(c)) continue;
        var xs = x.*;
        xs[c] += 1.0;
        const r1 = dense(D.eval(Dl, &xs, model, inst, hub.sim_state));
        narrowAssert(Dl, "res", false, model, c, &r0, &r1);
        if (comptime @hasDecl(D, "q")) {
            const q1 = dense(qRowsOf(Dl, &xs, model, inst));
            narrowAssert(Dl, "q", true, model, c, &q0, &q1);
        }
    }
}

/// The constant-stamp gate. A device that declares `constant` promises its
/// Jacobian (`g`) or capacitance matrix (`c`) is the same at every x, so a
/// host builds the stamp once: the whole local matrix, `jac_const`
/// included, must come out the same at a second, unrelated bias, to the
/// rounding of its own entries.
pub fn constCheck(x: *const [n_u]f64, model: *const D.Model, inst: contract.InstancePtr(D)) void {
    if (comptime !@hasDecl(D, "constant")) return;
    var xs: [n_u]f64 = undefined;
    for (&xs, x, 0..) |*o, v, i| o.* = v * 1.5 - 0.25 - 0.125 * @as(f64, @floatFromInt(i));
    if (comptime D.constant.g) constAssert("res", withConst(Dual, D.eval(Dual, x, model, inst, hub.sim_state), model, false), withConst(Dual, D.eval(Dual, &xs, model, inst, hub.sim_state), model, false));
    if (comptime D.constant.c and @hasDecl(D, "q")) constAssert("q", withConst(Dual, qRowsOf(Dual, x, model, inst), model, true), withConst(Dual, qRowsOf(Dual, &xs, model, inst), model, true));
}

pub fn constAssert(what: []const u8, a: [n_u]Row, b: [n_u]Row) void {
    for (0..n_u) |i| for (0..n_u) |j| {
        const p = a[i].d[j];
        const q = b[i].d[j];
        if (p == q or @abs(p - q) <= 1e-12 * @max(@abs(p), @abs(q))) continue;
        std.debug.print("const_check FAIL: d{s}[{s}]/dx[{s}] is {e} at one bias and {e} at another, but the device declares it constant\n", .{ what, u_names[i], u_names[j], p, q });
        std.process.exit(1);
    };
}

pub fn hasLane(u: usize) bool {
    return (contract.derivReads(D) >> @intCast(u)) & 1 != 0;
}

/// Column `c`'s unit step moved every row by `r1 - r0`; each must be the
/// `jac_const` entry a host would stamp (0 when there is none), to the
/// rounding of the rows' magnitude.
pub fn narrowAssert(comptime Dl: type, what: []const u8, react: bool, model: *const D.Model, c: usize, r0: *const [n_u]Row, r1: *const [n_u]Row) void {
    for (0..n_u) |i| {
        var k: f64 = 0.0;
        inline for (comptime contract.jacConst(D)) |e| {
            if (@backingInt(e.row) == i and @backingInt(e.col) == c and
                contract.jacConstApplies(D, e, model, Dl.collapse_applied)) k = if (react) e.c else e.g;
        }
        const moved = r1[i].v - r0[i].v;
        const tol = 1e-9 * @max(@abs(r0[i].v), @abs(r1[i].v)) + 1e-300;
        if (@abs(moved - k) <= tol) continue;
        std.debug.print("narrow_check FAIL: d{s}[{s}]/dx[{s}]: a unit step moves the row by {e}, jac_const says {e}{s}\n", .{
            what, u_names[i], u_names[c], moved, k, if (Dl.collapse_applied) " [collapse applied]" else "",
        });
        std.process.exit(1);
    }
}

pub fn patAssert(what: []const u8, pat: [n_u]contract.Mask(D), r: *const [n_u]Row) void {
    for (0..n_u) |i| for (0..n_u) |j| {
        if (r[i].d[j] == 0.0) continue;
        if ((pat[i] >> @intCast(j)) & 1 != 0) continue;
        std.debug.print("pattern_check FAIL: d{s}[{s}]/dx[{s}] = {e} is outside the declared pattern\n", .{ what, u_names[i], u_names[j], r[i].d[j] });
        std.process.exit(1);
    };
}

/// The WRITTEN-ROW gate. A host drops a row outside `jac_rows`/`q_rows`
/// entirely — no residual stamp, no charge-tape entry — so a clear bit
/// with anything but a hard zero behind it is a term that vanishes from
/// the netlist with no diagnostic. This is the check that fails if
/// codegen ever writes `res[ru]` without going through `patRow`, and the
/// value, not the derivative, is what it looks at: `isource` writes rows
/// whose every partial is zero.
pub fn rowAssert(what: []const u8, rows: contract.Mask(D), r: *const [n_u]Row) void {
    for (0..n_u) |i| {
        if ((rows >> @intCast(i)) & 1 != 0) continue;
        if (r[i].v == 0.0) continue;
        std.debug.print("row_check FAIL: {s}[{s}] = {e} but the row is declared never written\n", .{ what, u_names[i], r[i].v });
        std.process.exit(1);
    }
}

pub fn fusedAssert(what: []const u8, i: usize, a: f64, b: f64) void {
    if (@as(u64, @bitCast(a)) == @as(u64, @bitCast(b))) return;
    std.debug.print("fused_check FAIL: {s}[{s}]: evalQ {e} vs split {e}\n", .{ what, u_names[i], a, b });
    std.process.exit(1);
}

pub fn fusedAssertSite(what: []const u8, k: usize, a: f64, b: f64) void {
    if (@as(u64, @bitCast(a)) == @as(u64, @bitCast(b))) return;
    std.debug.print("fused_check FAIL: {s} site {d}: evalQ {e} vs split {e}\n", .{ what, k, a, b });
    std.process.exit(1);
}

/// A lane-free family's (`Val`, `Batch`) coerces to `[n_u]Sc.Of(0)`; a
/// `Dual`'s is read through `dense`.
pub fn qRowsOf(comptime Sc: type, x: *const [n_u]Sc.V, model: *const D.Model, inst: contract.InstancePtr(D)) contract.QRows(D, Sc) {
    return contract.qRows(D, Sc, D.q(Sc, x, model, inst, hub.sim_state));
}

/// The whole local Jacobian a host assembles: the device's lanes on the
/// columns in `deriv_reads`, `jac_const` on the rest (`g` of `eval`, `c`
/// of the reactive rows).
pub fn withConst(comptime Dl: type, rows: anytype, model: *const D.Model, react: bool) [n_u]Row {
    var out = dense(rows);
    inline for (comptime contract.jacConst(D)) |e| {
        if (contract.jacConstApplies(D, e, model, Dl.collapse_applied))
            out[@backingInt(e.row)].d[@backingInt(e.col)] = if (react) e.c else e.g;
    }
    return out;
}
