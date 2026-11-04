//! The analog testbench runtime (`std_sim.bench`), its part: the point solve: the directive-pinned unknowns, the tolerances and the Newton loop.
//! Cites: each item cites its own clause.
//!
//! Contents:
//! - `u_abstol`, `solve_reltol`, `solve_max_iter`, `set`, `solve`, `luSolve`

const std = @import("std");
const contract = @import("contract");
const D = @import("../bench.zig").D;
const Dual = @import("batch.zig").Dual;
const Row = @import("batch.zig").Row;
const Val = @import("batch.zig").Val;
const commitCharge = @import("step.zig").commitCharge;
const hub = @import("../bench.zig");
const ix = @import("../bench.zig").ix;
const n_u = @import("../bench.zig").n_u;
const point = @import("report.zig").point;
const qRowsOf = @import("gates.zig").qRowsOf;
const sayIteration = @import("step.zig").sayIteration;
const step = @import("step.zig").step;
const step_part = @import("step.zig");
const title = @import("../bench.zig").title;
const u_names = @import("report.zig").u_names;
const withConst = @import("gates.zig").withConst;

/// §3.6.1.2 `abstol` — "the largest signal value that can be safely
/// ignored" — per unknown, which is the absolute half of Newton's stopping
/// test. The device declares it (codegen reads it off the net's discipline,
/// §3.6.2.3 override included); the fallback is annex D's own defaults for
/// `Voltage` and `Current`, for a hand-written device that declares neither
/// table.
pub const u_abstol: [n_u]f64 = if (@hasDecl(D, "u_abstol")) D.u_abstol else blk: {
    var a: [n_u]f64 = @splat(1e-6);
    if (@hasDecl(D, "u_kinds")) for (D.u_kinds, 0..) |k, i| {
        if (k != .voltage) a[i] = 1e-12;
    };
    break :blk a;
};

/// The relative half. Tighter than a circuit simulator's default reltol
/// because a fixture asserts a digit derived from the LRM, not a waveform:
/// the systems here are small enough that the extra decades cost nothing.
pub const solve_reltol = 1e-12;

/// A cap, not a budget. Every fixture system converges in one step (linear)
/// or a handful; reaching this means the iteration is not converging, and
/// that has to be LOUD — see the exit below.
pub const solve_max_iter = 100;

/// Pin an unknown at the value a `//! bias`, `//! sweep` or `//! wave` line
/// gave it: the INITIAL GUESS Newton starts from, and the CONSTRAINT row it
/// keeps. Both, from one directive, because a directive that names a value
/// for an unknown is saying the host drives it.
pub fn set(x: *[n_u]f64, forced: *[n_u]?f64, comptime name: []const u8, v: f64) void {
    x[ix(name)] = v;
    forced[ix(name)] = v;
}

/// §5.6 THE SOLVE, and it is a solve.
///
/// Verilog-A semantics are defined AT A SOLUTION of the nodal equations,
/// never at an arbitrary point. §5.6.7's indirect contribution is a
/// CONSTRAINT the simulator satisfies rather than an assignment — there is
/// no way to express it by evaluating anything — and §5.4.2.2's "the
/// potential of a source branch may be read" is a question about what the
/// solver settled on. A harness that wrote `//! bias` into x[] and stopped
/// could only ever hand a fixture back the number the harness itself just
/// wrote.
///
/// So: Newton-Raphson on the residual the device stamps, with the Jacobian
/// the forward-mode `Dual` above already carries. Dense LU with partial
/// pivoting — a fixture's system is under ~10 unknowns, so a sparse
/// factorisation or an ordering heuristic would be code with nothing to do.
///
/// ONE RULE BEYOND TEXTBOOK NEWTON, and it is what makes an isolated device
/// solvable at all. A .va compiled alone is NOT a circuit. `I(p,n) <+ 0.0`
/// stamps two identically-zero rows; a two-terminal module that never
/// references ground leaves its common mode undetermined however nonlinear
/// it is. Those are free directions of the device's own equations, not
/// solver failures — a host pins them by CONNECTING the device to
/// something. So a column with no usable pivot takes dx = 0 and its unknown
/// HOLDS the operating point the `//!` lines declared, which is exactly the
/// behaviour this harness had before it could solve at all. Convergence is
/// then judged on the unknowns the system does determine, and only those.
///
/// ponytail: no gmin stepping, no source stepping, no continuation. Every
/// system in the suite converges from the declared guess. Add the minimum
/// and name it here if one ever does not.
///
/// §5.6.1.2's reactive half is folded in by BACKWARD EULER, because a
/// fixture finally needed a transient solve: §5.4.3's port current is the
/// whole of what the module stamps at the port, charge included, and
/// `res[flow(<p>)] = x − res[p]` alone can only ever hand back the
/// conduction half (ch05_analog_behavior/a02_06). So the row Newton sees is
///
///     eval(x) + (q(x) − step_part.q_prev) / dt
///
/// with `step_part.q_prev` the charge of the last accepted point (`commitCharge`).
///
/// ponytail: first order, fixed step, no LTE control and no step rejection
/// — `//! time` states the steps and the suite asserts values a clause
/// derives, not a waveform's accuracy. Trapezoidal or gear-2 is the upgrade
/// if a fixture ever asserts a number the Euler truncation error moves.
///
/// dt = 0 is the DC point that opens a transient (`renderRunner` gives the
/// first time step dt = 0 for exactly this reason, §4.5.3), and there the
/// difference is undefined and the charge contributes nothing — so that
/// point is still the resistive solve it always was.
pub fn solve(x: *[n_u]f64, forced: *const [n_u]?f64, model: *const D.Model, inst: *D.Instance) bool {
    // Nothing to determine: every unknown is one a `//!` line named, or the
    // reference the harness ties the rest to without `//! solve`. x already
    // holds the answer. Returning here is not only the cheap path — it is
    // what keeps a `//! print none` fixture evaluated exactly as often as it
    // was before there was a solver, so no §9.4 transcript moves.
    for (forced) |f| {
        if (f == null) break;
    } else return false;
    hub.sim_state.iteration = 1;
    var previous = x.*;
    var worst: usize = 0;
    var worst_dx: f64 = 0.0;
    var iter: usize = 0;
    while (iter < solve_max_iter) : (iter += 1) {
        if (iter != 0) {
            if (@hasDecl(D, "advanceIteration")) D.advanceIteration(Val, model, inst, previous, hub.sim_state);
            hub.sim_state.iteration +|= 1;
        }
        previous = x.*;
        var r = withConst(Dual, D.eval(Dual, x, model, inst, hub.sim_state), model, false);
        sayIteration(x, model, inst);
        // §5.6.1.2 backward Euler — see the header. Value and derivative
        // both, so the capacitance matrix reaches the Jacobian too.
        if (comptime @hasDecl(D, "q")) if (hub.sim_state.dt > 0.0) {
            const qq = withConst(Dual, qRowsOf(Dual, x, model, inst), model, true);
            for (0..n_u) |i| {
                r[i].v += (qq[i].v - step_part.q_prev[i]) / hub.sim_state.dt;
                for (0..n_u) |j| r[i].d[j] += qq[i].d[j] / hub.sim_state.dt;
            }
        };
        var a: [n_u][n_u]f64 = undefined;
        var b: [n_u]f64 = undefined;
        var scale: f64 = 0.0;
        for (0..n_u) |i| {
            if (forced[i]) |v| {
                // The host drives this one, so its row is the constraint and
                // not the device's KCL. Written as a Newton row (1·dx =
                // v - x) rather than by assignment, so the value survives
                // elimination against every other row exactly.
                a[i] = @splat(0.0);
                a[i][i] = 1.0;
                b[i] = v - x[i];
            } else {
                a[i] = r[i].d;
                b[i] = -r[i].v;
                // A forced column's dx is known, so it moves to the right-
                // hand side. Left in, a large coupling (a charge over dt)
                // wins that column's pivot from the constraint row, and the
                // free column it displaces can fall under `eps`.
                for (0..n_u) |j| if (forced[j]) |v| {
                    b[i] -= a[i][j] * (v - x[j]);
                    a[i][j] = 0.0;
                };
            }
            // Row equilibration: each row is divided by its largest entry,
            // which leaves dx unchanged. Without it one row's 1/dt (a §4.5.3
            // `ddt` unknown's row, -2e8 at dt = 5 ns) sets `scale`, and a
            // pivot of 1 in a row of order 1 falls under `eps`, so that
            // unknown silently holds its guess.
            var m: f64 = 0.0;
            for (a[i]) |e| m = @max(m, @abs(e));
            if (m > 0.0) {
                for (&a[i]) |*e| e.* /= m;
                b[i] /= m;
                scale = 1.0;
            }
        }
        var dx: [n_u]f64 = undefined;
        var solved: [n_u]bool = undefined;
        luSolve(&a, &b, &dx, &solved, scale);
        var settled = true;
        worst_dx = 0.0;
        for (0..n_u) |i| {
            if (!solved[i]) continue;
            const tol = u_abstol[i] + solve_reltol * @abs(x[i]);
            // Written so a NaN step (a NaN residual or Jacobian entry)
            // never settles: it runs out the cap and fails by name.
            const step_i = @abs(dx[i]);
            if (step_i <= tol) continue;
            settled = false;
            if (!(step_i <= worst_dx)) {
                worst_dx = step_i;
                worst = i;
            }
        }
        for (0..n_u) |i| x[i] += dx[i];
        // §9.17.1 `limit`'s verdict is on the iterate at `old`. This harness
        // accepts the updated x, not the linearization point, so it asks
        // at x with `cur = old`, where every clamp is the identity.
        const can_converge = if (@hasDecl(D, "limit")) D.limit(Val, model, inst, x.*, x.*, hub.sim_state).converged else true;
        if (settled and can_converge) return true;
    }
    // A testbench that does not converge must FAIL, loudly and by exit
    // status, naming the unknown that would not settle. Falling through and
    // letting the model assert against a half-iterated x would report a
    // conformance verdict on arithmetic nobody solved.
    std.debug.print(
        "{s}: did not converge after {d} Newton iterations: x[{s}] still moving {e:.6} per step, tolerance {e:.6}\n",
        .{ title, solve_max_iter, u_names[worst], worst_dx, u_abstol[worst] + solve_reltol * @abs(x[worst]) },
    );
    std.process.exit(1);
}

/// Dense LU with partial pivoting, rank-revealing exactly as far as `solve`
/// needs: `solved[k]` is false for a column with no usable pivot, and
/// `dx[k]` is then 0. Row `k` of the echelon form lives at `perm[…]`, so
/// nothing is physically moved.
pub fn luSolve(
    a: *[n_u][n_u]f64,
    b: *[n_u]f64,
    dx: *[n_u]f64,
    solved: *[n_u]bool,
    scale: f64,
) void {
    // "Usable" is relative to the largest entry in the whole system: a
    // structurally absent coupling and one that cancelled to rounding are
    // both absence of information, and treating the second as a pivot is
    // how a solver invents a 1e17 node voltage.
    const eps = 1e-14 * scale;
    var pivot: [n_u]usize = @splat(0);
    var perm: [n_u]usize = undefined;
    for (0..n_u) |i| perm[i] = i;
    var rows: usize = 0; // rows consumed by a pivot so far
    for (0..n_u) |k| {
        var best = rows;
        var best_v: f64 = -1.0;
        for (rows..n_u) |i| {
            const v = @abs(a[perm[i]][k]);
            if (v > best_v) {
                best_v = v;
                best = i;
            }
        }
        if (best_v <= eps) {
            solved[k] = false;
            continue;
        }
        std.mem.swap(usize, &perm[rows], &perm[best]);
        const p = perm[rows];
        pivot[k] = p;
        solved[k] = true;
        for (rows + 1..n_u) |i| {
            const qr = perm[i];
            if (a[qr][k] == 0.0) continue;
            const f = a[qr][k] / a[p][k];
            for (k..n_u) |j| a[qr][j] -= f * a[p][j];
            b[qr] -= f * b[p];
        }
        rows += 1;
    }
    // Back-substitution over the pivoted columns, highest first. A free
    // column contributes nothing to any row above it, because its dx is 0.
    var k = n_u;
    while (k > 0) {
        k -= 1;
        if (!solved[k]) {
            dx[k] = 0.0;
            continue;
        }
        const p = pivot[k];
        var s = b[p];
        for (k + 1..n_u) |j| s -= a[p][j] * dx[j];
        dx[k] = s / a[p][k];
    }
}
