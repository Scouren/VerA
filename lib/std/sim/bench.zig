//! The analog testbench runtime (`std_sim.bench`, like `std/start.zig`):
//! the host a `vera --run` runner is. The runner's root declares the device
//! (`D`) and the bench (`vera_bench`, a `Config` the compiler writes as a
//! literal) and takes `main` from here; everything else is shipped once,
//! never spliced: the spine (`bench/run.zig`, or `bench/mixed.zig` for a §8
//! design), the checks, the solve and the gates (`bench/*.zig`).
//! Cites: §2.8.3, §3.4.1, §4.2.1.1, §9.7.1, §12.32; each part cites its own.
//!
//! Contents:
//! - `Config`, `D`, `cfg`, `n_u`, `title`, `times`, `mem_bytes`, `print_residual`, `fd_certify`, `finite_proved`, `analysis_name`, `main`, `run`, `no_vpi_app`, `iteration_hooks`, `mutable_eval`, `noise_table_points`, `shape_check`, `calls_setup`, `calls_ac_dyn`, `sim_state`, `diag_sweep`, `run_kind`, `big_stack_bytes`, `big_stack`, `noVpiApp`, `plusargs`, `cwdPath`, `acDynAt`, `shapeCheck`, `systf`, `cardValue`, `ix`, `uIndex`, `near`, `veraDiag`, `muteDomain`, `atPoint`, `bigStack`, `pwl`

const std = @import("std");
const contract = @import("contract");
const Dual = @import("bench/batch.zig").Dual;
const Row = @import("bench/batch.zig").Row;
const point = @import("bench/report.zig").point;
const set = @import("bench/solve.zig").set;
const solve = @import("bench/solve.zig").solve;
const u_names = @import("bench/report.zig").u_names;

const spec = @import("bench/spec.zig");
/// The runner's root: the device and the bench.
const root = @import("root");

/// What the compiler writes into the runner (`bench/spec.zig`).
pub const Config = spec.Config;
pub const D = root.D;
pub const cfg: Config = root.vera_bench;
pub const n_u = @typeInfo(D.U).@"enum".field_names.len;
pub const title = cfg.title;
pub const times = cfg.bench.times_s;
pub const mem_bytes: usize = cfg.mem_bytes;
pub const print_residual = cfg.bench.print == .residual;
pub const fd_certify = cfg.certify;
pub const finite_proved = cfg.finite_proved;
/// §9.15 `$simparam$str("analysis_name")`: this testbench's one analysis.
pub const analysis_name = if (cfg.bench.analysis_name.len != 0) cfg.bench.analysis_name else @tagName(cfg.bench.analysis);
/// The spine: the §8 mixed runner for a design with a digital half.
pub const main = (if (cfg.mixed != null) @import("bench/mixed.zig") else @import("bench/run.zig")).main;
pub const run = (if (cfg.mixed != null) @import("bench/mixed.zig") else @import("bench/run.zig")).run;

pub var no_vpi_app: contract.SystfHost = .{ .ctx = undefined, .call = noVpiApp };

/// What `contract.validateHost` checks this host by, when the checks are on
/// (`vera_validate_contract`). The fixture suite always turns them on: this
/// is the host that runs against every device the torture suite compiles.
pub const iteration_hooks = true;
pub const mutable_eval = true;
/// 4.6.4.3 an array-parameter noise table: this host reads the card's own
/// knots through `contract.noiseTable` (the row's `noise_table_points__`),
/// not the declared defaults that reach `noise_tables`. See
/// `emitNoiseComptime`'s `points=` and `psd=` comparisons.
pub const noise_table_points = true;
/// §3.4 this host refuses a card that moves a shape parameter: `shapeCheck`
/// runs after every `derive`.
pub const shape_check = true;
/// The testbench calls `setup` after every card it writes (`tb/runner.zig`).
pub const calls_setup = true;
/// The testbench builds no small-signal matrix; it reads `acDyn` for
/// `//! acdyn` (`acDynAt`), its one view of those slots.
pub const calls_ac_dyn = true;
/// The analysis in force, as every entry point reads it.
pub var sim_state: contract.SimState = .{};
/// The `//! sweep`/`//! psweep` point in force, `name=value` per swept
/// variable (`sweepPoint`); "" when nothing is swept.
pub var diag_sweep: []const u8 = "";
/// The analysis this run is (§4.6.1 Table 4-21): the `//! analysis` kind,
/// or the one the VPI host opened. `sim_state.kind` is the part of it a
/// point evaluates as, which `atPoint` decides.
pub var run_kind: contract.AnalysisKind = .dc;

/// Past 256 unknowns a `Dual` is n_u lanes wide and a Debug `eval` frame
/// holds one per temporary; a large §3.2.2 array is a frame local, and
/// a large held one is in `Instance`, which the runner copies. Either
/// outgrows the main thread's 8 MiB, so `main` runs the testbench (`run`)
/// on a thread whose stack grows with them (#29). Virtual size only: a
/// stack is touched as deep as it is used.
/// ponytail: about 128 lane-wide temporaries per unknown and sixteen
/// copies of each array (a Debug frame copies by value; measured on
/// array_past_2_20_elements.va); a device far past that needs more.
pub const big_stack_bytes = @sizeOf(Row) * n_u * 128 + 16 * (@sizeOf(D.Instance) + mem_bytes);
pub const big_stack = n_u > 256 or big_stack_bytes > (1 << 20);
comptime {
    contract.validateHost(@This(), D);
}

/// §2.8.3/§12.32: this testbench is a HOST, and a host answers for every
/// `$name` the compiler left to a VPI application. There is no application
/// in a `vera --run` build, so this one answers zero — and that answer is
/// the testbench's, written here where a reader can see it, not a value the
/// compiler substituted behind everyone's back.
///
/// ZERO IS NOT A CLAIM ABOUT THE FUNCTION. §12.32.3's own sampnhold listing
/// never initializes `sampler->value` before its first update callback, so
/// the language fixes no value for an unregistered systf and there is
/// nothing here to be wrong about. What a fixture over one of these may
/// assert is what does NOT depend on the value: that the analog block runs
/// straight through the call (§5.3.1), that the residual is still built.
/// Asserting the 0.0 itself would pin this file's choice as if it were the
/// LRM's, and a host-linked conforming tool would then fail the fixture.
///
/// The partials are zero for the same reason and one more: a systf whose
/// derivative were left undefined would put a number nothing computed into
/// the Jacobian, and Newton would chase it.
pub fn noVpiApp(_: *anyopaque, _: usize, _: []const f64, partials: []f64) f64 {
    @memset(partials, 0);
    return 0;
}
/// §9.12 / IEEE 1364 §17.10: this binary's own command line is the
/// invocation `Instance.plusargs` carries; the harness passes a
/// fixture's `//! plusargs` there.
pub fn plusargs(init: std.process.Init.Minimal) []const [:0]const u8 {
    const argv = init.args.toSlice(std.heap.page_allocator) catch return &.{};
    return argv[@min(1, argv.len)..];
}

/// §9.15 Table 9-28 "cwd": the directory this testbench was started in,
/// "" if it cannot be read.
pub fn cwdPath() []const u8 {
    return std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), std.heap.page_allocator) catch "";
}

/// `acDyn`'s term at slot (r, c) and angular frequency `w`, at `x`; 0 at a
/// slot `ac_dyn_slots` does not list.
pub fn acDynAt(r: usize, c: usize, w: f64, x: *const [n_u]f64, m: *const D.Model, inst: *D.Instance) std.math.Complex(f64) {
    if (comptime !@hasDecl(D, "ac_dyn_slots")) return .init(0.0, 0.0);
    var out: [D.ac_dyn_slots.len]std.math.Complex(f64) = undefined;
    D.acDyn(f64, m, inst, x, sim_state, w, &out);
    for (D.ac_dyn_slots, out) |s, v| if (s == r * n_u + c) return v;
    return .init(0.0, 0.0);
}
pub fn shapeCheck(m: *const D.Model) void {
    if (comptime @hasDecl(D, "checkCard")) if (D.checkCard(m)) |name| {
        std.debug.print("error[E0890]: LRM 9.18: the model card puts `{s}` outside Table 9-29's allowed values\n", .{name});
        std.process.exit(1);
    };
    if (comptime @hasDecl(D, "checkRange")) if (D.checkRange(m)) |name| {
        std.debug.print("error[E0377]: LRM 3.4.2: the model card puts parameter `{s}` outside its declared range\n", .{name});
        std.process.exit(1);
    };
    if (comptime !@hasDecl(D, "checkShape")) return;
    const name = D.checkShape(m) orelse return;
    std.debug.print("error: LRM 3.4: the model card sets shape parameter `{s}` to a value this device was not compiled for\n", .{name});
    std.process.exit(1);
}
pub fn systf(_: *const D.Model) ?*const contract.SystfHost {
    return &no_vpi_app;
}
/// §3.4.1: "If the type of the parameter is specified as integer or real,
/// and the value assigned to the parameter conflicts with the type of the
/// parameter, the value is converted to the type of the parameter (see
/// 4.2.1.1)." A `//! param` card is written in reals, like any host's, so
/// an integer parameter is handed one here.
///
/// §4.2.1.1: "Real numbers are converted to integers by rounding the real
/// number to the nearest integer, rather than by truncating it ... If the
/// fractional part of the real number is exactly 0.5, it shall be rounded
/// away from zero." `@round` is exactly that tie rule. §3.4.1's explicit
/// integer keeps the low 32 bits of a wider value (VD-089), an inferred
/// integral one its 64-bit saturation; a field the §3.4.2 range sized
/// narrower refuses a value it cannot hold, as `checkRange` refuses one
/// inside the width.
pub fn cardValue(comptime T: type, name: []const u8, v: f64) T {
    return switch (@typeInfo(T)) {
        .int => |info| if (info.bits >= 64) std.math.lossyCast(T, @round(v)) else std.math.cast(T, @as(i32, @truncate(std.math.lossyCast(i64, @round(v))))) orelse {
            std.debug.print("error[E0377]: LRM 3.4.2: the model card puts parameter `{s}` outside its declared range\n", .{name});
            std.process.exit(1);
        },
        else => v,
    };
}

/// Index of the unknown a directive named. A miss is a compile error that
/// names the directive, not a runtime surprise.
pub fn ix(comptime name: []const u8) usize {
    return comptime uIndex(name) orelse
        @compileError(title ++ ": `//!` names unknown `" ++ name ++ "`, which this module does not have");
}

/// Index of the unknown spelled `name` in `u_names`, or null.
pub fn uIndex(comptime name: []const u8) ?usize {
    for (u_names, 0..) |u, i| if (std.mem.eql(u8, u, name)) return i;
    return null;
}

/// A `//! seed` or `//! limit` want: equal to the 12 significant digits a
/// hand derivation writes.
pub fn near(got: f64, want: f64) bool {
    return @abs(got - want) <= 1e-12 * @abs(want) + 1e-15;
}

/// §9.7.1 Table 9-25, §9.7.3: the testbench's part of a device diagnostic
/// (its `zWhen`), with no newline. In a dc sweep "the current value of
/// the swept variable in place of the simulation time" (`diag_sweep`),
/// else `t=` the time; `level` 2 adds the run's memory and CPU use.
pub fn veraDiag(t: f64, level: u8) void {
    const swept = diag_sweep.len != 0 and switch (sim_state.kind) {
        .static, .dc, .nodeset => true,
        .ic, .tran, .ac, .noise => false,
    };
    if (swept) std.debug.print("{s}", .{diag_sweep}) else std.debug.print("t={d}", .{t});
    if (level < 2) return;
    // ponytail: `maxrss` is kB on Linux and bytes on macOS; 0 on an OS without rusage.
    if (comptime std.posix.rusage != void) { // os: comptime-gated on `rusage`, else the zeros below
        const ru = std.posix.getrusage(std.posix.rusage.SELF); // os: inside the `rusage != void` branch
        const cpu = @as(f64, @floatFromInt(ru.utime.sec + ru.stime.sec)) + @as(f64, @floatFromInt(ru.utime.usec + ru.stime.usec)) / 1e6;
        std.debug.print(" memory={d} kB cpu={d:.3} s", .{ ru.maxrss, cpu });
    } else std.debug.print(" memory=0 kB cpu=0 s", .{});
}
/// The root's `vera_domain_muted`, set while `point`'s self-checks
/// evaluate the device around a point: the printing kernels' `zDomain`
/// (§4.3.2) stays quiet, since no analysis asked for those inputs.
pub fn muteDomain(on: bool) void {
    if (comptime @hasDecl(@import("root"), "vera_domain_muted")) @import("root").vera_domain_muted = on;
}
/// Points `sim_state` at time `t`, `dt` after the last accepted point, and
/// at the §4.6.1 analysis that point belongs to. Table 4-22's TRAN OP
/// column: the dt = 0 solve that opens a transient is its "ic" analysis
/// (Table 4-21: "the initial-condition analysis which precedes a
/// transient analysis"), where "static", "ic" and "tran" are 1 and "dc" 0;
/// every later point is the Tran column. Any other analysis is itself at
/// every point. Every host here sets t, dt and kind only through this.
pub fn atPoint(t: f64, dt: f64) void {
    sim_state.t = t;
    sim_state.dt = dt;
    sim_state.kind = if (run_kind == .tran and dt == 0.0) .ic else run_kind;
}

pub fn bigStack(init: std.process.Init.Minimal) void {
    const t = std.Thread.spawn(.{ .stack_size = (8 << 20) + big_stack_bytes }, run, .{init}) catch |e|
        std.debug.panic("testbench: no thread for {d} unknowns: {t}", .{ n_u, e });
    t.join();
}

pub fn pwl(values: []const f64, t: f64) f64 {
    var k: usize = 0;
    while (k + 1 < times.len and times[k + 1] <= t) k += 1;
    const v0 = values[@min(k, values.len - 1)];
    if (k + 1 >= times.len or k + 1 >= values.len) return v0;
    return v0 + (values[k + 1] - v0) * (t - times[k]) / (times[k + 1] - times[k]);
}
