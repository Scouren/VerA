//! The §8 mixed-signal runner: the device beside its digital half, a
//! `std_sim.Program` the compiler embedded (`Config.mixed`, `std_sim.serial`
//! bytes), so nothing is elaborated at run time (A.4 finding F12). Each
//! point loads it afresh into a `State`, watches the values the analog
//! block reads, and `std_sim.mixed.run` steps both halves on one time line.
//! Cites: VAMS-2023 §7.3.1, §7.3.2, §7.3.6.3, §7.3.6.5, §8.2, §8.4, §8.5;
//! IEEE 1364-2005 §19.8.
//!
//! Contents:
//! - `pub fn main(init: std.process.Init.Minimal) void`, `pub fn run(init: std.process.Init.Minimal) void`
//! - `pub const Analog = struct` (`std_sim.mixed.run`'s analog side: `setInputs`, `breakpoint`, `snapshot`, `latch`, `solveAt`, `finish`, `probe`)

const std = @import("std");
const contract = @import("contract");
const hub = @import("../bench.zig");
const Dual = @import("batch.zig").Dual;
const State = @import("step.zig").State;
const fieldName = @import("report.zig").fieldName;
const newState = @import("step.zig").newState;
const point = @import("report.zig").point;
const retryUnsupported = @import("step.zig").retryUnsupported;
const set = @import("solve.zig").set;
const solve = @import("solve.zig").solve;
const stepPost = @import("step.zig").stepPost;
const spec = @import("spec.zig");
const sim = @import("../../sim.zig");
const run_part = @import("run.zig");
const D = hub.D;
const n_u = hub.n_u;
const bench = hub.cfg.bench;
const Name = spec.Digital.Name;

/// `std_sim.mixed.run`'s analog side over the device.
pub const Analog = struct {
    model: *D.Model,
    inst: *D.Instance,
    x: *[n_u]f64,
    forced: *[n_u]?f64,
    state: *State,
    dout: *std.Io.Writer.Allocating,
    n: *usize,
    dig: *sim.State,
    t: f64 = 0.0,
    solved: bool = false,
    /// The last finished solution, for §7.3.6.3's interpolation.
    x_prev: [n_u]f64 = @splat(0.0),
    t_prev: ?f64 = null,

    /// §7.3.6.5 / Table 7-1: every input as the digital engine holds it for
    /// the latest tick. The fields are parameters to the device, so its
    /// parameter-only prep is redone.
    pub fn setInputs(a: *Analog, dig: *sim.State, fired: u64) !void {
        _ = fired;
        a.flush();
        inline for (input_ports) |p| setField(a.model, comptime fieldName(p.path), mixedInput(dig, p));
        if (comptime @hasDecl(D, "setup")) D.setup(Dual, a.model);
        if (comptime @hasDecl(D, "setupInstance")) D.setupInstance(a.model, a.inst);
    }

    /// §5.10.3.3 the device's next timer instant after `t`, if it has one.
    pub fn breakpoint(a: *Analog, t: f64) ?f64 {
        const m: ?f64 = if (comptime @hasDecl(D, "nextBreakpoint")) D.nextBreakpoint(a.model, t) else null;
        const i: ?f64 = if (comptime @hasDecl(D, "pendingBreakpoint")) D.pendingBreakpoint(a.inst, t) else null;
        return if (m != null and i != null) @min(m.?, i.?) else m orelse i;
    }

    // ponytail: no §8.5.3.6 explicit D2A terms yet (the device has no
    // snapshot or event-flag rows), so region 1b keeps nothing.
    pub fn snapshot(_: *Analog, _: *sim.State) !void {}
    pub fn latch(_: *Analog) !void {}

    pub fn solveAt(a: *Analog, t: f64, dt: f64, first: bool, last: bool) !void {
        hub.atPoint(t, dt);
        hub.sim_state.initial_step = first;
        hub.sim_state.final_step = last;
        hub.sim_state.analog_initial = first;
        inline for (bench.waves) |wv| set(a.x, a.forced, wv.name, hub.pwl(wv.values, t));
        a.solved = solve(a.x, a.forced, a.model, a.inst);
        a.t = t;
    }

    pub fn finish(a: *Analog) !void {
        a.flush();
        point(a.n.*, a.x, a.model, a.inst);
        if (stepPost(a.model, a.inst, a.x, a.state, a.solved)) |r| retryUnsupported(r);
        a.n.* += 1;
        a.x_prev = a.x.*;
        a.t_prev = a.t;
    }

    /// VAMS §7.3.6.3 `V(n1)` / `V(n1, n2)` for a digital expression: the
    /// tentative solution (`t` null), or the value "calculated for the time
    /// corresponding to a real promotion of the digital time", linear
    /// between the last finished solution and the tentative one.
    pub fn probe(a: *Analog, t: ?f64, n1: []const u8, n2: ?[]const u8) !f64 {
        const now = potential(a.x, n1, n2);
        const tq = t orelse return now;
        const tp = a.t_prev orelse return now;
        if (tq >= a.t or a.t <= tp) return now;
        const before = potential(&a.x_prev, n1, n2);
        if (tq <= tp) return before;
        return before + (now - before) * (tq - tp) / (a.t - tp);
    }

    /// The digital half's own §17 output, in time order with the analog
    /// points: everything it printed up to the tick being solved.
    fn flush(a: *Analog) void {
        std.debug.print("{s}", .{a.dout.written()});
        a.dout.clearRetainingCapacity();
    }
};

const digital = hub.cfg.mixed.?;
const count = spec.pointCount(&bench) catch unreachable;

/// The digital values the device's card reads: Sema declares one card row
/// per digital-owned value its analog blocks read (§7.3.1), named by path
/// and spelled as the device spells a field (`fieldName`).
const input_ports = blk: {
    @setEvalBranchQuota(1000 + 100 * digital.names.len);
    var out: []const Name = &.{};
    for (digital.names) |d| {
        if (@hasField(D.Model, fieldName(d.path))) out = out ++ [_]Name{d};
    }
    break :blk out;
};

/// Each VAMS §7.3.6.3 probe terminal by the name the program spells it.
const probes = std.StaticStringMap(spec.Digital.Probe).initComptime(blk: {
    var kvs: [digital.probes.len]struct { []const u8, spec.Digital.Probe } = undefined;
    for (digital.probes, &kvs) |p, *kv| kv.* = .{ p.name, p };
    break :blk kvs;
});

/// The runner's `main`: `run`, on a big-stack thread when the device needs one.
pub fn main(init: std.process.Init.Minimal) void {
    if (comptime hub.big_stack) return hub.bigStack(init);
    @call(.never_inline, run, .{init});
}

/// The card, the instance and the host bindings, then one `runMixed`
/// analysis per point.
pub fn run(init: std.process.Init.Minimal) void {
    var model: D.Model = .{};
    inline for (bench.params) |p| run_part.setCard(&model, p.name, p.value);
    run_part.deriveCard(&model, bench.temperature_k);
    var inst: D.Instance = .{};
    hub.run_kind = @field(contract.AnalysisKind, @tagName(bench.analysis));
    hub.sim_state = .{ .kind = hub.run_kind };
    if (comptime @hasDecl(D, "systf_calls")) inst.systf = &hub.no_vpi_app;
    if (comptime @hasField(D.Instance, "plusargs")) inst.plusargs = hub.plusargs(init);
    if (comptime @hasField(D.Instance, "cwd")) inst.cwd = hub.cwdPath();
    if (comptime @hasField(D.Instance, "analysis_name")) inst.analysis_name = hub.analysis_name;
    if (comptime @hasDecl(D, "setup")) D.setup(Dual, &model);
    if (comptime @hasDecl(D, "setupInstance")) D.setupInstance(&model, &inst);
    if (hub.print_residual) std.debug.print("=== {s} ===\n", .{hub.title});
    var n: usize = 0;
    var state: State = undefined;
    for (0..count) |pi| {
        const p: u32 = @intCast(pi);
        hub.diag_sweep = run_part.sweepPoint(p);
        // §9.5.1.1, as in the fixed-grid runner: every point here is an analysis.
        if (p != 0) if (contract.fileIo(D, &inst)) |f| if (f.new_analysis) |g| g(f.ctx);
        var pm = model;
        const card = if (bench.psweeps.len == 0) &model else &pm;
        if (bench.psweeps.len != 0) {
            var row: spec.Row = .init(&bench, count, p);
            inline for (0..bench.sweeps.len + bench.psweeps.len) |k| {
                const v = row.next().?;
                if (k >= bench.sweeps.len) run_part.setCard(&pm, bench.psweeps[k - bench.sweeps.len].name, v);
            }
            run_part.deriveCard(&pm, null);
        }
        var x: [n_u]f64 = @splat(0.0);
        var forced: [n_u]?f64 = @splat(if (bench.solve_free) null else 0.0);
        if (comptime @hasDecl(D, "u_nodeset")) for (D.u_nodeset, 0..) |nodeset_i, i| {
            if (nodeset_i) |v| x[i] = v;
        };
        state = newState(card, &inst);
        run_part.pointUnknowns(&x, &forced, .init(&bench, count, p));
        runMixed(card, &inst, &x, &forced, &state, &n);
    }
}

// ---- private ----

/// VAMS §7.3.1 Table 7-1: a bit grouping, a net and an `integer` reach the
/// continuous context as an integer, a `real` with no conversion. §7.3.2:
/// "It is an error if these operands return x or z bit values when
/// solved", and a solve is where this is read, so an x or z bit fails the
/// run by name.
fn mixedInput(dig: *sim.State, p: Name) f64 {
    var tmp: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer tmp.deinit();
    const v = sim.eval.read(dig, tmp.allocator(), p.slot) catch |e| mixedFail(dig, e);
    if (p.real) return @bitCast(v.values()[0]);
    const i = v.asInt() orelse {
        std.debug.print("{s}: FAIL §7.3.2: the discrete input `{s}` holds an x or z bit when the analog block reads it\n", .{ hub.title, p.path });
        std.process.exit(1);
    };
    return @floatFromInt(i);
}

/// The potential of terminal `n1` (minus `n2`) in `x`.
fn potential(x: *const [n_u]f64, n1: []const u8, n2: ?[]const u8) f64 {
    return terminal(x, n1) - if (n2) |m| terminal(x, m) else 0.0;
}

/// Probe terminal `name`'s potential: its unknowns as codegen resolved
/// them (`Digital.probes`), which name every terminal the program probes.
fn terminal(x: *const [n_u]f64, name: []const u8) f64 {
    const p = probes.get(name) orelse unreachable; // codegen.bench.digital resolves every probe terminal
    const hi = if (p.hi) |i| x[i] else 0.0;
    return hi - if (p.lo) |i| x[i] else 0.0;
}

fn setField(model: *D.Model, comptime field: []const u8, v: anytype) void {
    @field(model, field) = std.math.lossyCast(@TypeOf(@field(model, field)), v);
}

/// The digital half stopped: its run-time error, then the run's own.
fn mixedFail(dig: *const sim.State, e: anyerror) noreturn {
    if (dig.failure) |f| std.debug.print("{s}\n", .{f});
    std.debug.print("FAIL {s}: the digital half did not run: {t}\n", .{ hub.title, e });
    std.process.exit(1);
}

/// One analysis: the digital half afresh from the embedded program, the
/// inputs watched, and `std_sim.mixed.run` owning the global time.
fn runMixed(model: *D.Model, inst: *D.Instance, x: *[n_u]f64, forced: *[n_u]?f64, state: *State, n: *usize) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = sim.serial.load(arena, digital.program) catch |e| {
        std.debug.print("FAIL {s}: the digital half does not load: {t}\n", .{ hub.title, e });
        std.process.exit(1);
    };
    var dout = std.Io.Writer.Allocating.init(arena);
    var dig = sim.State.init(arena, &p, &dout.writer) catch |e| {
        std.debug.print("FAIL {s}: the digital half did not start: {t}\n", .{ hub.title, e });
        std.process.exit(1);
    };
    var a: Analog = .{ .model = model, .inst = inst, .x = x, .forced = forced, .state = state, .dout = &dout, .n = n, .dig = &dig };
    // §8.4.3.2: an unguarded read makes the block implicitly sensitive.
    inline for (input_ports) |port| sim.analog.watchAnalog(&dig, port.slot) catch |e| mixedFail(&dig, e);
    // IEEE 1364 §19.8 the digital half's tick: the finest precision of all.
    sim.mixed.run(Analog, &a, &dig, .{ .times = hub.times, .tick = sim.time.secondsAt(1, p.finest) }) catch |e| {
        a.flush();
        mixedFail(&dig, e);
    };
    a.flush();
}
