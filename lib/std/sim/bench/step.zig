//! The analog testbench runtime (`std_sim.bench`), its part: the accepted-step bookkeeping: `State`, the charge history, the rejected-step retry, the crossing locator and the `$strobe` passes.
//! Cites: each item cites its own clause.
//!
//! Contents:
//! - `State`, `q_prev`, `forced_prev`, `say_iterations`, `newState`, `step`, `commitCharge`, `acceptCheck`, `stepPost`, `stepAdvance`, `retryUnsupported`, `retry`, `crossRetry`, `locate`, `sayPoint`, `sayIteration`, `sayPass`

const std = @import("std");
const contract = @import("contract");
const D = @import("../bench.zig").D;
const Dual = @import("batch.zig").Dual;
const Val = @import("batch.zig").Val;
const atPoint = @import("../bench.zig").atPoint;
const dense = @import("batch.zig").dense;
const hub = @import("../bench.zig");
const n_q = @import("gates.zig").n_q;
const n_u = @import("../bench.zig").n_u;
const point = @import("report.zig").point;
const print_residual = @import("../bench.zig").print_residual;
const pwl = @import("../bench.zig").pwl;
const qRowsOf = @import("gates.zig").qRowsOf;
const solve = @import("solve.zig").solve;
const stateCheck = @import("report.zig").stateCheck;
const title = @import("../bench.zig").title;

/// §4.5.2 accepted-step bookkeeping. `void` for a module with no stateful
/// operator, which is most of them — codegen emits the state machine only
/// when one is present.
pub const State = if (@hasDecl(D, "updateState") and @hasDecl(D, "initState")) D.State else void;

/// Iteration history advances independently of accepted-time operators.
/// §5.6.1.2 the accepted step's CHARGE, which is the other operand of the
/// backward-Euler difference `solve` forms at the next time point. Taken
/// before `step`, so it is the q of the state `eval` saw while this point
/// was being solved and not of the history `updateState` is about to write.
pub var q_prev: [n_u]f64 = @splat(0.0);

/// The forced unknowns at the last accepted point, which `locate` draws
/// a `//! wave` from linearly, as the mixed runner's `pwl` does.
pub var forced_prev: [n_u]?f64 = @splat(null);

/// §9.4.1 `$debug` "displays its arguments for each iteration of the analog
/// solver", and §9.5.9 `$fdebug` writes "even if the evaluation occurred
/// during an iteration that was rejected": the iteration pass at the
/// iterate `x` (`contract.SayPass`), after each Newton iteration of `solve`.
pub var say_iterations: usize = 0;
pub fn newState(model: *const D.Model, inst: *D.Instance) State {
    if (State == void) return {};
    return D.initState(model, inst);
}

/// Commit the accepted solution, exactly as a transient solver does after
/// a converged step. `eval` READS the history out of `Instance`; this is the
/// only thing that ever writes it, so without this call every §4.5 operator
/// would answer from zero history at every time point and the transcript
/// would claim more than it proves.
///
/// Returns `contract.UpdateResult.request_reject_at`'s time when the device
/// rejects the step (VerA's `$vera_reject_step`), with every write this call
/// made undone; null when it accepts.
pub fn step(model: *const D.Model, inst: *D.Instance, x: *const [n_u]f64, state: *State) ?f64 {
    if (State == void) return null;
    const inst0 = inst.*;
    const state0 = state.*;
    switch (D.updateState(Val, model, inst, x.*, state, hub.sim_state)) {
        .ok => return null,
        .request_reject_at => |r| {
            inst.* = inst0;
            state.* = state0;
            return r;
        },
    }
}

pub fn commitCharge(model: *const D.Model, inst: *D.Instance, x: *const [n_u]f64) void {
    if (comptime !@hasDecl(D, "q")) return;
    const qq = dense(qRowsOf(Dual, x, model, inst));
    for (0..n_u) |i| q_prev[i] = qq[i].v;
}

/// `acceptQ` is `q` then `updateState` from one core evaluation, so its
/// charge must be `q`'s to the bit, lanes included. Run on copies: the
/// transcript keeps advancing through `updateState` exactly as before.
pub fn acceptCheck(model: *const D.Model, inst: *const D.Instance, x: *const [n_u]f64, state: *const State) void {
    if (comptime !@hasDecl(D, "acceptQ") or State == void) return;
    var iw = inst.*;
    const want = dense(D.q(Dual, x, model, &iw, hub.sim_state));
    var ic = inst.*;
    var sc = state.*;
    const got = dense(D.acceptQ(Dual, x, model, &ic, &sc, hub.sim_state));
    for (0..n_q) |i| {
        if (@as(u64, @bitCast(got[i].v)) == @as(u64, @bitCast(want[i].v)) and
            std.mem.eql(u8, std.mem.asBytes(&got[i].d), std.mem.asBytes(&want[i].d))) continue;
        std.debug.print("acceptQ FAIL: q site {d} {e} vs q() {e}\n", .{ i, got[i].v, want[i].v });
        std.process.exit(1);
    }
}

pub fn stepPost(model: *const D.Model, inst: *D.Instance, x: *const [n_u]f64, state: *State, solved: bool) ?f64 {
    acceptCheck(model, inst, x, state);
    stateCheck(model, inst, x, state);
    const q0 = q_prev;
    commitCharge(model, inst, x);
    const r = stepAdvance(model, inst, x, state, solved);
    if (r != null) q_prev = q0;
    return r;
}

pub fn stepAdvance(model: *const D.Model, inst: *D.Instance, x: *const [n_u]f64, state: *State, solved: bool) ?f64 {
    if (!solved) {
        // Forced-point fixtures sample both lifetimes, and a forced point
        // is one Newton iteration of an unbroken solve. Both updates read
        // the same evaluated state, even when their inputs depend on one
        // another; `limiter_previous` is the iteration hook's.
        defer hub.sim_state.iteration +|= 1;
        if (@hasDecl(D, "advanceIteration")) {
            var next = inst.*;
            D.advanceIteration(Val, model, &next, x.*, hub.sim_state);
            const r = step(model, inst, x, state);
            if (r == null and @hasField(D.Instance, "limiter_previous")) inst.limiter_previous = next.limiter_previous;
            return r;
        }
    }
    return step(model, inst, x, state);
}

/// A host whose time walk cannot go back (the mixed and VPI runners)
/// refuses a `$vera_reject_step` request rather than accept the step anyway.
pub fn retryUnsupported(r: f64) void {
    std.debug.print("reject_step FAIL: this runner does not retry a rejected step (retry at {e})\n", .{r});
    std.process.exit(1);
}

/// The host half of `contract.UpdateResult.request_reject_at` (VerA's
/// `$vera_reject_step`): the step to `t` was rejected and undone, so a point
/// is solved and accepted at `r`, between the last accepted time and `t`,
/// and then `t` is solved again from there. The forced unknowns keep the
/// values they have at `t`. A request during the retry is honoured the same
/// way, 16 deep at most.
pub fn retry(r: f64, n: usize, x: *[n_u]f64, forced: *const [n_u]?f64, model: *const D.Model, inst: *D.Instance, state: *State, depth: u32) void {
    const t = hub.sim_state.t;
    const t_prev = t - hub.sim_state.dt;
    const last = hub.sim_state.final_step;
    if (!(r > t_prev and r < t) or depth == 16) {
        std.debug.print("reject_step FAIL: retry at {e} is not inside ({e}, {e})\n", .{ r, t_prev, t });
        std.process.exit(1);
    }
    if (print_residual) std.debug.print("--- point {d} rejected: retry at {e} ---\n", .{ n, r });
    atPoint(r, r - t_prev);
    hub.sim_state.initial_step = false;
    hub.sim_state.final_step = false;
    hub.sim_state.analog_initial = false;
    const solved_r = solve(x, forced, model, inst);
    point(n, x, model, inst);
    if (stepPost(model, inst, x, state, solved_r)) |r2| retry(r2, n, x, forced, model, inst, state, depth + 1);
    atPoint(t, t - r);
    hub.sim_state.final_step = last;
    const solved_t = solve(x, forced, model, inst);
    point(n, x, model, inst);
    if (stepPost(model, inst, x, state, solved_t)) |r3| retry(r3, n, x, forced, model, inst, state, depth + 1);
}

/// §5.10.3.1 where a `cross` with its own tolerances should have fired,
/// when the point just solved found it outside the box they draw
/// (`Instance.vera_cross_retry__`), else null. Read off `updateState` on
/// copies, before the point prints, so the late attempt leaves neither
/// transcript nor history: a host does not strobe a step it rejects.
pub fn crossRetry(model: *const D.Model, inst: *const D.Instance, x: *const [n_u]f64, state: *const State) ?f64 {
    if (comptime State == void or !@hasField(D.Instance, "vera_cross_retry__")) return null;
    var ic = inst.*;
    var sc = state.*;
    _ = D.updateState(Val, model, &ic, x.*, &sc, hub.sim_state);
    return if (std.math.isFinite(ic.vera_cross_retry__)) ic.vera_cross_retry__ else null;
}

/// The point `crossRetry` asked for: solved and accepted at `r`, with each
/// forced unknown on the line between the last accepted point and `t`,
/// then `t` solved again from it. Returns whether that solve iterated, as
/// `solve` does. 16 deep at most, as `retry`.
pub fn locate(r: f64, n: usize, x: *[n_u]f64, forced: *const [n_u]?f64, model: *const D.Model, inst: *D.Instance, state: *State, depth: u32) bool {
    const t = hub.sim_state.t;
    const t_prev = t - hub.sim_state.dt;
    const last = hub.sim_state.final_step;
    if (!(r > t_prev and r < t) or depth == 16) {
        std.debug.print("cross FAIL: located at {e}, not inside ({e}, {e})\n", .{ r, t_prev, t });
        std.process.exit(1);
    }
    if (print_residual) std.debug.print("--- point {d}: crossing located at {e} ---\n", .{ n, r });
    var fr = forced.*;
    for (&fr, forced_prev, x) |*f, p, *xi| if (f.*) |v| if (p) |v0| {
        f.* = v0 + (v - v0) * (r - t_prev) / (t - t_prev);
        xi.* = f.*.?;
    };
    atPoint(r, r - t_prev);
    hub.sim_state.initial_step = false;
    hub.sim_state.final_step = false;
    hub.sim_state.analog_initial = false;
    var solved_r = solve(x, &fr, model, inst);
    if (crossRetry(model, inst, x, state)) |r2| solved_r = locate(r2, n, x, &fr, model, inst, state, depth + 1);
    point(n, x, model, inst);
    if (stepPost(model, inst, x, state, solved_r)) |r2| retry(r2, n, x, &fr, model, inst, state, depth + 1);
    forced_prev = fr;
    for (forced, x) |f, *xi| if (f) |v| {
        xi.* = v;
    };
    atPoint(t, t - r);
    hub.sim_state.final_step = last;
    const solved_t = solve(x, forced, model, inst);
    if (crossRetry(model, inst, x, state)) |r3| return locate(r3, n, x, forced, model, inst, state, depth + 1);
    return solved_t;
}

/// §9.4 the model's display tasks at this accepted point: a printing
/// device's own `display`, or what a device built `--display=record`
/// records (`say`), rendered by `contract.formatSay`. Its `$debug` and
/// `$fdebug` ran per iteration (`sayIteration`) when the point took any,
/// so this is their `.accepted` pass; a point `solve` returned at once
/// runs them here (`.all`).
pub fn sayPoint(x: *const [n_u]f64, model: *const D.Model, inst: contract.InstancePtr(D)) void {
    defer say_iterations = 0;
    if (@hasDecl(D, "displayPass")) {
        if (say_iterations != 0) D.displayPass(Dual, x, model, inst, hub.sim_state, .accepted) else D.display(Dual, x, model, inst, hub.sim_state);
    } else if (@hasDecl(D, "display")) D.display(Dual, x, model, inst, hub.sim_state);
    if (comptime !@hasDecl(D, "say")) return;
    sayPass(x, model, inst, if (say_iterations != 0) .accepted else .all);
}

pub fn sayIteration(x: *const [n_u]f64, model: *const D.Model, inst: contract.InstancePtr(D)) void {
    say_iterations += 1;
    if (@hasDecl(D, "displayPass")) D.displayPass(Dual, x, model, inst, hub.sim_state, .iteration);
    if (comptime !@hasDecl(D, "say")) return;
    sayPass(x, model, inst, .iteration);
}

pub fn sayPass(x: *const [n_u]f64, model: *const D.Model, inst: contract.InstancePtr(D), pass: contract.SayPass) void {
    var store: [4096]f64 = undefined;
    var s: contract.Say = .{ .buf = &store, .pass = pass };
    D.say(Dual, x, model, inst, hub.sim_state, &s);
    var text: [65536]u8 = undefined;
    var w: std.Io.Writer = .fixed(&text);
    // A record past the buffer prints what fits, then fails by name: a
    // silently cut record reads as the device's whole output.
    contract.formatSay(D, &s, title, &w) catch {
        std.debug.print("{s}\nFAIL {s}: a say record passes {d} bytes\n", .{ w.buffered(), title, text.len });
        std.process.exit(1);
    };
    std.debug.print("{s}", .{w.buffered()});
}
