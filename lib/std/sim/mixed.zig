//! A digital `State` and an analog solver in, one mixed-signal analysis on
//! a common global time out (VAMS §8.4.4, §7.3.6): `run`, the spine that
//! walks the declared timepoints and hands each step to
//! `coordinator.Coordinator(A)`. The old `lib/sim/mixed` retargeted to
//! `std_sim.State` (lib/TODO.md A.7, finding 9): the digital half is a
//! compiled `Program`, never elaborated at run time. The analog side is a
//! comptime interface (`run`'s `A`); `tests/differential/mixed.zig` drives
//! the old and this spine over the same designs against one fake solver.
//! Cites: VAMS §7.3.5, §7.3.6, §8.4, §8.5, §5.10.3; IEEE 1364-2005 §17.1.3.
//!
//! Contents:
//! - `pub const Options = struct`
//! - `pub const max_rejects`
//! - `pub const max_secant`
//! - `pub const max_cuts`
//! - `pub const default_time_tol`
//! - `pub const default_expr_tol`
//! - `pub const Error`
//! - `pub fn RunError(comptime A: type) type`
//! - `pub fn run(comptime A: type, a: *A, dig: *State, opts: Options) RunError(A)!void`
//! - `pub const Mon`

const std = @import("std");
const assert = std.debug.assert;
const State = @import("State.zig");
const analog = @import("analog.zig");
const Interp = @import("Interp.zig");
const time = @import("time.zig");
const tickAtOrBefore = time.tickAtOrBefore;
const coordinator = @import("mixed/coordinator.zig");
const monitors = @import("mixed/monitors.zig");
const Coordinator = coordinator.Coordinator;
/// One monitored analog event's state (`mixed/monitors.zig`).
pub const Mon = monitors.Mon;

/// One analysis's timeline, as `run` reads it.
pub const Options = struct {
    /// The declared analog timepoints, in seconds, ascending. `times[0]` is the
    /// DC point that opens the analysis (§8.4.2); the rest are transient
    /// points. Implicit D2A points are inserted between them.
    times: []const f64,
    /// One scheduler tick, in seconds: the design's finest time precision.
    tick: f64,
};

/// Rejections of one tentative solution `solve` backs up from before it
/// gives up, as the VPI walk does (`src/vpi/analog.zig`).
pub const max_rejects = 60;

/// Secant cuts `step` tries before it halves the step instead.
pub const max_secant = 64;

/// Cuts one step can take: `max_secant`, then bisections. Each bisection
/// halves acc - base or ends the loop, and an f64 interval shrinks to one ulp
/// in at most 2098 + 52 halvings (the exponent range plus the mantissa).
pub const max_cuts = max_secant + 2150;

/// §5.10.3.1 leaves an absent `time_tol` to the tool.
pub const default_time_tol = 1e-12;

/// §5.10.3.4 lets the tool choose an absent/zero expression tolerance.
pub const default_expr_tol = 1e-12;

/// What `run` refuses of its own, beside the digital engine's errors:
/// `BadTimeline`, `Options.times` empty, holding a negative or non-finite
/// time, running back, or ending past 2^64 ticks (a digital time is a u64
/// tick count); `BackupExhausted`, a step the host rejected `max_rejects`
/// times over.
pub const Error = State.Error || error{ BadTimeline, BackupExhausted };

/// `run`'s error set over analog side `A`: `Error` and every error `A`'s
/// methods return (`probe`'s are reported through the digital engine).
pub fn RunError(comptime A: type) type {
    var E: type = Error;
    for (.{ "setInputs", "snapshot", "latch", "solveAt", "finish", "rejected" }) |name| if (@hasDecl(A, name)) {
        const R = @typeInfo(@TypeOf(@field(A, name))).@"fn".return_type.?;
        if (@typeInfo(R) == .error_union) E = E || @typeInfo(R).error_union.error_set;
    };
    return E;
}

/// Runs one analysis over `opts.times`.
///
/// Digital to analog: the solve at `t` sees every tick <= `t` (§7.3.6.5); a
/// change of a value the analog block reads forces a solve at its own time,
/// on or off the declared grid (§8.5, §8.4.7), once per tick after the
/// tick's nonblocking updates (§8.5.1 region 3b); activity at or before the
/// first time is settled into the DC point (§8.4.2). A solution is final
/// only once every tick at or before it has run, so a later D2A at the same
/// time re-solves it instead of adding a point.
///
/// Analog to digital: a `cross`/`above` in a digital event control is
/// checked against every tentative solution, and a step that jumps a
/// crossing is cut back to within its `time_tol` and `expr_tol` (§7.3.5,
/// §5.10.3.1); the
/// event is delivered at the nearest tick, never before the current digital
/// time (§7.3.6.1, §8.4.3.3); a probe reads the solution interpolated at the
/// promoted digital time (§7.3.6.3).
///
/// `A` provides these methods, each fallible:
///   setInputs(a, dig, fired)      copy the discrete inputs the analog block reads
///                                 out of `dig` (§7.3.1 Table 7-1 conversion is A's),
///                                 and raise the explicit D2A terms in `fired`
///                                 (bit = `analog.D2aSite.site`) for this solve
///   snapshot(a, dig)              region 1b (§8.5.3.6): keep, for the next
///                                 setInputs, the values the statements guarded
///                                 by an explicit D2A event read
///   latch(a)                      commit what the tentative solution's explicit
///                                 D2A event statements assigned, and nothing
///                                 else: one region-1b evaluation (§8.5.3.6)
///   solveAt(a, t, dt, first, last) a TENTATIVE solution at `t`; `first` opens the
///                                 analysis (dt = 0), `last` is its final point
///   finish(a)                     the last tentative solution is final: report it
///                                 (§9.4 strobes) and commit its state (§4.5.2)
///   rejected(a)                   optional: whether the host rejected the
///                                 tentative solution `solveAt` just made (VPI
///                                 §12.36 vpiRejectTransientStep, §12.31.3
///                                 acbConvergenceTest); the step is halved and
///                                 solved again before any event reads it, so an
///                                 A2D event of a rejected solution is never
///                                 delivered (§8.4.7)
///   probe(a, t, n1, n2)           V(n1, n2) (n2 null: V(n1)) of the tentative
///                                 solution when `t` is null, else interpolated
///                                 at `t` between the last finished solution and
///                                 the tentative one (§7.3.6.3)
/// and installs its own `analog.watchAnalog` on every slot it reads,
/// which is what makes a change of one of them an implicit D2A.
///
/// `opts.times` is the caller's (a deck's analysis line, a testbench's
/// `//! time`s) and is checked here (`BadTimeline`). Asserts that
/// `opts.tick` is positive.
pub fn run(comptime A: type, a: *A, dig: *State, opts: Options) RunError(A)!void {
    try checkTimeline(opts);
    var s: Coordinator(A) = .{ .a = a, .dig = dig, .opts = opts, .final = opts.times[opts.times.len - 1] };
    // §7.3.5 / §7.3.6.3: a monitored analog event or a probe needs the analog
    // solution at every digital event time, so the analog steps to each one
    // before the digital engine runs it (Figure 8-7's conservative half).
    const mons = analog.monitors(dig);
    const sync = mons.len != 0 or dig.analog.has_probes or dig.p.has_probes;
    if (sync) {
        dig.analog.probe = Coordinator(A).probeHook;
        dig.analog.probe_ctx = &s;
        s.mons = try dig.arena.alloc(Mon, mons.len);
        for (s.mons, mons, 0..) |*m, mon, j| {
            if (mon.kind == .timer) {
                // Controls may read a probe. Initialize after the first solve,
                // when those arguments have an analog value (§5.10.3.3).
                m.* = .{ .kind = .{ .timer = .{} } };
                continue;
            }
            if (mon.kind == .absdelta) {
                // Its arguments can change at runtime. In particular, no
                // probe is meaningful until the initial analog solve exists.
                m.* = .{ .kind = .{ .absdelta = .{} } };
                continue;
            }
            const above = mon.kind == .above;
            // §5.10.3.1 cross(expr, dir, time_tol, expr_tol, ...);
            // §5.10.3.2 above(expr, time_tol, expr_tol, ...).
            const dir = if (above) 1.0 else (try analog.monitorArg(dig, j, 1)) orelse 0.0;
            const tol = (try analog.monitorArg(dig, j, if (above) 1 else 2)) orelse 0.0;
            const etol = (try analog.monitorArg(dig, j, if (above) 2 else 3)) orelse 0.0;
            m.* = .{ .kind = .{ .crossing = .{
                .dir = dir,
                .tol = if (tol > 0) tol else @min(default_time_tol, opts.tick / 2),
                .etol = if (etol > 0) etol else std.math.inf(f64),
                .enable = if (above) 3 else 4,
            } } };
        }
    }
    for (opts.times, 0..) |target, i| {
        const horizon = tickAtOrBefore(target, opts.tick);
        s.target = target;
        s.dc = i == 0;
        // §8.4.1 "a one time execution of nodeset statements (3.6.3.2), then
        // the procedural statements in analog initial block, and then the
        // procedural statements in the Verilog initial block for time zero":
        // a tentative solution runs the analog initial block before any
        // digital process, so a digital read of a continuous variable or a
        // probe at time zero sees it. No digital value exists yet (no
        // `setInputs`: the inputs keep their defaults, and §5.2.1 keeps them
        // out of the analog initial block). `acc` stays null: the DC point is
        // still solved below, with the time-zero digital values (§8.4.2).
        if (i == 0 and dig.analog.has_probes) try a.solveAt(target, 0.0, true, target == s.final);
        if (sync and i > 0) {
            while (s.acc.? < target) {
                var t_end = target;
                if (dig.scheduler.peekTime()) |k| if (k <= horizon) {
                    t_end = @min(t_end, s.timeOf(k, target, horizon));
                };
                // §5.10.3.3 a timer places a point at its firing time, whether
                // it is monitored here or only the device's (`nextBreakpoint`).
                for (s.mons) |m| if (m.kind == .timer and m.kind.timer.next > s.acc.?) {
                    t_end = @min(t_end, m.kind.timer.next);
                };
                if (@hasDecl(A, "breakpoint")) if (a.breakpoint(s.acc.?)) |b| if (b > s.acc.?) {
                    t_end = @min(t_end, b);
                };
                try s.step(t_end);
            }
            continue;
        }
        // Every tick up to the horizon, one at a time, so an implicit D2A at
        // tick k is solved at k's own time and not at the next declared point.
        while (dig.scheduler.peekTime()) |k| {
            if (k > horizon) break;
            while (true) {
                switch (try Interp.runUntil(dig, k)) {
                    .idle => break,
                    .explicit_d2a => {
                        try s.explicitD2a();
                        continue;
                    },
                    .analog => {},
                }
                const t = s.timeOf(k, target, horizon);
                // §8.4.2: activity before the first analog time is settled
                // into the DC point, not given solutions of its own.
                if (i == 0 and t < target) continue;
                try s.accept(t);
            }
        }
        // The declared point itself, unless a D2A at this very time already
        // solved it with the tick's final values (region 3b follows 1-3).
        if (s.acc == null or s.acc.? != target) try s.accept(target);
        // §5.10.3.4 absdelta "generates events ... During initialization".
        if (sync and i == 0) {
            for (s.mons, 0..) |*m, j| if (m.kind == .absdelta) {
                const ad = &m.kind.absdelta;
                ad.initialized = true;
                ad.last = try s.monValue(j);
                ad.extreme = ad.last;
                ad.last_time = target;
            };
            _ = try s.refreshAbsdelta(target);
            _ = try s.refreshTimers(target);
            try s.runDigital(horizon);
        }
    }
    try a.finish();
}

// ---- private ----

/// `BadTimeline` unless `run` can walk `opts.times`: at least one time, the
/// first at or after 0, none before the one ahead of it, and the last below
/// 2^64 ticks. Each comparison is false on a NaN, so a NaN fails too.
fn checkTimeline(opts: Options) error{BadTimeline}!void {
    assert(opts.tick > 0); // 10^`finest` s, a §19.8 precision.
    assert(std.math.isFinite(opts.tick));
    const times = opts.times;
    if (times.len == 0) return error.BadTimeline;
    if (!(times[0] >= 0)) return error.BadTimeline;
    for (times[1..], times[0 .. times.len - 1]) |t, before| if (!(t >= before)) return error.BadTimeline;
    if (!(times[times.len - 1] / opts.tick < 0x1p64)) return error.BadTimeline;
    assert(times[0] <= times[times.len - 1]);
}

test {
    _ = coordinator;
    _ = monitors;
    _ = @import("mixed/test.zig");
}
