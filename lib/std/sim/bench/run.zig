//! The fixed-grid runner's spine: the card, the instance and the host
//! bindings, the device-table checks made once, then each operating point
//! (`Bench` expanded by `Row`) solved at each `//! time`, sweep outer and
//! time inner. With `//! time` each point is its own transient analysis
//! with a fresh `State`; a dc sweep's points are the steps of one.
//! Cites: §2.8.3, §3.4.1, §4.5.2, §4.6.1, §4.6.2, §5.2.1, §5.6, §5.10.2
//! (Table 5-1), §5.10.3.1, §6.3.4, §8.2, §9.5.1.1, §9.15, §12.32.
//!
//! Contents:
//! - `pub fn main(init: std.process.Init.Minimal) void`, `pub fn run(init: std.process.Init.Minimal) void`
//! - `pub fn setCard(card: *D.Model, comptime name: []const u8, value: f64) void`, `pub fn deriveCard(card: *D.Model, temperature_k: ?f64) void`
//! - `pub fn pointUnknowns(x: *[n_u]f64, forced: *[n_u]?f64, row: Row) void`, `pub fn sweepPoint(n: u32) []const u8`

const std = @import("std");
const contract = @import("contract");
const hub = @import("../bench.zig");
const Dual = @import("batch.zig").Dual;
const State = @import("step.zig").State;
const Val = @import("batch.zig").Val;
const crossRetry = @import("step.zig").crossRetry;
const locate = @import("step.zig").locate;
const newState = @import("step.zig").newState;
const point = @import("report.zig").point;
const retry = @import("step.zig").retry;
const set = @import("solve.zig").set;
const solve = @import("solve.zig").solve;
const stepPost = @import("step.zig").stepPost;
const step_part = @import("step.zig");
const checks = @import("checks.zig");
const D = hub.D;
const n_u = hub.n_u;
const bench = hub.cfg.bench;
const Row = @import("spec.zig").Row;

/// Points the sweeps expand to (the compiler refused more than
/// `points_max`).
const count = @import("spec.zig").pointCount(&bench) catch unreachable;
/// Each point re-initializes its §4.6.2 variables when it is an analysis
/// of its own (`//! time`); a dc sweep's points share them.
const per_block = bench.times_s.len > 1;

/// The runner's `main`: `run`, on a big-stack thread when the device needs one.
pub fn main(init: std.process.Init.Minimal) void {
    if (comptime hub.big_stack) return hub.bigStack(init);
    @call(.never_inline, run, .{init});
}

/// The whole testbench.
pub fn run(init: std.process.Init.Minimal) void {
    var model: D.Model = .{};
    inline for (bench.params) |p| setCard(&model, p.name, p.value);
    // §6.3.4: the card is complete only now. Unconditional, so a §3.4.5
    // localparam is derived even with no `//! param` line.
    deriveCard(&model, bench.temperature_k);
    var inst: D.Instance = .{};
    hub.run_kind = @field(contract.AnalysisKind, @tagName(bench.analysis));
    hub.sim_state = .{ .kind = hub.run_kind };
    // §2.8.3/§12.32: this testbench is a host, so it binds `no_vpi_app` for
    // the device's unresolved `$name`s and passes `validateHost` like any other.
    if (comptime @hasDecl(D, "systf_calls")) inst.systf = &hub.no_vpi_app;
    if (comptime @hasField(D.Instance, "plusargs")) inst.plusargs = hub.plusargs(init);
    // §9.15 Table 9-28 through the GPU-safe channel a GPU host uses: the
    // bytes in `contract.host_strings`, the row only their indices.
    var tb_strings = [_][]const u8{ "", "", hub.analysis_name };
    if (comptime @hasField(D.Model, "cwd_idx__")) {
        tb_strings[1] = hub.cwdPath();
        contract.host_strings = &tb_strings;
        model.cwd_idx__ = 1;
        model.analysis_name_idx__ = 2;
    }
    // The solve-invariant slice: after the card and the temperature write,
    // before the first evaluation, with `Dual` itself as the value scalar.
    if (comptime @hasDecl(D, "setup")) D.setup(Dual, &model);
    if (comptime @hasDecl(D, "setupInstance")) D.setupInstance(&model, &inst);
    var state: State = undefined;
    _ = &state;
    if (hub.print_residual) std.debug.print("=== {s} ===\n", .{hub.title});
    // Once, before the points: comptime tables, or the cold start.
    if (bench.noise) |rows| checks.noiseTopology(rows, &model);
    if (bench.acstim) |rows| checks.acTopology(rows);
    if (bench.qsites) |rows| checks.qSites(rows);
    if (bench.seeds) |rows| checks.seedCheck(rows, &model, &inst);
    if (bench.meta) |rows| checks.meta(rows);
    checks.abstols(bench.abstols);

    var solves: usize = 0;
    for (0..count) |pi| {
        const n: u32 = @intCast(pi);
        hub.diag_sweep = sweepPoint(n);
        // §9.5.1.1 a block after the first is a following analysis of the
        // same process, so a file it reopens "w" keeps earlier output.
        if (per_block and n != 0) if (contract.fileIo(D, &inst)) |f| if (f.new_analysis) |g| g(f.ctx);
        // `//! psweep` gives each point its own card (§8.2), re-derived
        // per §6.3.4; without it the shared `model` is used.
        var pm = model;
        const card = if (bench.psweeps.len == 0) &model else &pm;
        if (bench.psweeps.len != 0) {
            var row: Row = .init(&bench, count, n);
            inline for (0..bench.sweeps.len + bench.psweeps.len) |k| {
                const v = row.next().?;
                if (k >= bench.sweeps.len) setCard(&pm, bench.psweeps[k - bench.sweeps.len].name, v);
            }
            deriveCard(&pm, null);
            if (comptime @hasDecl(D, "setup")) D.setup(Dual, &pm);
            if (comptime @hasDecl(D, "setupInstance")) D.setupInstance(&pm, &inst);
        }
        var x: [n_u]f64 = @splat(0.0);
        var forced: [n_u]?f64 = @splat(if (bench.solve_free) null else 0.0);
        if (comptime @hasDecl(D, "u_nodeset")) for (D.u_nodeset, 0..) |nodeset_i, i| {
            if (nodeset_i) |v| x[i] = v;
        };
        // §4.6.2 a new analysis re-initializes its variables (`initState`).
        if (per_block or n == 0) state = newState(card, &inst);
        pointUnknowns(&x, &forced, .init(&bench, count, n));
        for (bench.times_s, 0..) |t, k| {
            timePoint(t, k, n, solves, &x, &forced, card, &inst, &state);
            solves += 1;
        }
    }
}

/// One card line, `card.name = value`, and the §9.19 `$param_given` bit.
/// §3.4.1/§4.2.1.1 via `cardValue`: a card is written in reals and an
/// integer parameter rounds, away from zero on a tie.
pub fn setCard(card: *D.Model, comptime name: []const u8, value: f64) void {
    @field(card, name) = hub.cardValue(@TypeOf(@field(card, name)), name, value);
    if (comptime @hasDecl(D.Model, "setGiven")) card.setGiven(name);
}

/// The §9.10 temperature into the card when one is given, then the §6.3.4
/// `derive` and the shape check that complete it.
pub fn deriveCard(card: *D.Model, temperature_k: ?f64) void {
    if (temperature_k) |t| card.temperature__ = t;
    if (comptime @hasDecl(D, "derive")) D.derive(Val, card);
    hub.shapeCheck(card);
}

/// One point's unknowns: §4.5.2 operator unknowns are never forced, then
/// what the directives pin, `//! bias` before the swept columns.
pub fn pointUnknowns(x: *[n_u]f64, forced: *[n_u]?f64, row: Row) void {
    for (hub.cfg.op_states) |u| forced[u] = null;
    inline for (bench.bias) |bi| set(x, forced, bi.name, bi.value);
    var r = row;
    inline for (bench.sweeps) |s| set(x, forced, s.name, r.next().?);
}

/// The host's §9.7.1/§9.7.3 sweep point `n`: `name=value` per swept
/// column, which `veraDiag` reports in place of the time during a dc
/// sweep; "" when nothing is swept.
pub fn sweepPoint(n: u32) []const u8 {
    if (comptime bench.sweeps.len + bench.psweeps.len == 0) return "";
    const S = struct {
        var buf: [4096]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&S.buf);
    var row: Row = .init(&bench, count, n);
    while (row.next()) |v| {
        const k = row.k - 1;
        w.print("{s}{s}={d}", .{ if (k == 0) "" else " ", @import("spec.zig").column(&bench, k).name, v }) catch break;
    }
    return w.buffered();
}

// ---- private ----

/// One solve of the grid: the waves at this time, the step, the §5.10.2
/// global events, the solve and its retries, the point's output and (at the
/// run's first solve) the point checks, then the accepted step.
fn timePoint(t: f64, k: usize, n: u32, solve_n: usize, x: *[n_u]f64, forced: *[n_u]?f64, card: *D.Model, inst: *D.Instance, state: *State) void {
    const last = bench.times_s.len - 1;
    // `locate` draws a wave between the last accepted point and this; a
    // short `wave` holds its last value.
    if (bench.waves.len != 0) step_part.forced_prev = forced.*;
    inline for (bench.waves) |wv| set(x, forced, wv.name, wv.values[@min(k, wv.values.len - 1)]);
    // The first time is the DC point, dt = 0 (Table 4-22's "ic").
    const dt: f64 = if (k == 0) 0.0 else bench.times_s[k] - bench.times_s[k - 1];
    hub.atPoint(t, dt);
    // §5.10.2 / Table 5-1, and §5.2.1 `analog initial` per sub-task.
    hub.sim_state.initial_step = k == 0 and (per_block or n == 0);
    hub.sim_state.final_step = k == last and (per_block or n + 1 == count);
    hub.sim_state.analog_initial = k == 0;
    var solved = solve(x, forced, card, inst);
    // §5.10.3.1 a crossing found outside its tolerance box gets its own
    // point first (`locate`), and this one is solved again.
    if (crossRetry(card, inst, x, state)) |r| solved = locate(r, solve_n, x, forced, card, inst, state, 0);
    point(solve_n, x, card, inst);
    if (solve_n == 0) {
        if (bench.noise) |rows| checks.noisePsd(rows, x, card, inst);
        if (bench.acstim) |rows| checks.acStim(rows, x, card, inst);
        checks.acDyn(bench.acdyn, x, card, inst);
        checks.limits(bench.limits, x, card, inst);
    }
    // §4.5.2 accepted-step bookkeeping: only `updateState` writes the
    // history `eval` reads. VerA's `$vera_reject_step`: a rejected step is retried.
    if (stepPost(card, inst, x, state, solved)) |r| retry(r, solve_n, x, forced, card, inst, state, 0);
}
