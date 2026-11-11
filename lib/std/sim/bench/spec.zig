//! The bench a runner runs, as data: the directives' card, points and
//! checks (`Bench`) and the compile's facts (`Config`), which the compiler
//! writes into the runner's root as one literal (`vera_bench`), and the
//! sweep expansion every point reads (`Row`, `pointCount`).
//! Cites: §2.9.2, §3.4, §3.6.1.2, §4.5.2, §4.6.1, §4.6.3, §4.6.4, §5.6.1.2,
//! §8.2, §9.10, §9.15, §9.17.3.
//!
//! Contents:
//! - `pub const points_max: u32`
//! - `pub const Config = struct`, `pub const Digital = struct` (`Digital.Name`, `Digital.Probe`)
//! - `pub const Bench = struct`, `pub const Binding = struct`, `pub const Sweep = struct`, `pub const LimitCase = struct`
//! - `pub const Analysis = enum`, `pub const Print = enum`
//! - `pub const NoiseWant = struct` (`Interp`, `Corr`, `needsPoint`), `pub const AcWant = struct` (`needsPoint`), `pub const AcDynWant = struct`
//! - `pub const Row = struct` (`init`, `next`), `pub fn pointCount(bench: *const Bench) error{TooManyPoints}!u32`, `pub fn columnCount(bench: *const Bench) usize`, `pub fn column(bench: *const Bench, k: usize) Sweep`

const std = @import("std");
const assert = std.debug.assert;

/// Most operating points one bench may expand to: the product of every
/// `sweep` and `psweep` length (`error.TooManyPoints` past it). Each point is
/// a straight-line block of the runner's source, so this bounds its size.
pub const points_max: u32 = 4096;

/// One runner: its title (the fixture's stem, keying the transcript), the
/// bench, and what the compile learnt (`bench.facts` fills the first three).
pub const Config = struct {
    title: []const u8,
    bench: Bench = .{},
    /// The design's digital half, for the §8 mixed-signal runner; null for
    /// the fixed-grid one.
    mixed: ?Digital = null,
    /// §4.5.2 operator unknowns' `U` indices, ascending; never forced.
    op_states: []const u32 = &.{},
    /// Bytes of §3.2.2 memory-backed arrays an `eval` frame holds.
    mem_bytes: u64 = 0,
    /// The runner declares `vera_validate_contract` (`--validate-contract`).
    validate_contract: bool = false,
    /// The suite's `--certify`: the runner's FD, finite and state gates run.
    certify: bool = false,
    /// Every contribution unit was proved finite, the claim `certify` tests.
    finite_proved: bool = false,
};

/// A mixed design's digital half as the runner embeds it: the
/// `std_sim.Program` as `std_sim.serial` bytes, and each named digital value
/// (`path`, spelled as the device's card row of it, `n` or `u.clk`), and
/// each VAMS §7.3.6.3 probe terminal the program names, resolved.
pub const Digital = struct {
    program: []const u8,
    names: []const Name,
    /// One row per distinct probe terminal name in `program`; every name
    /// its probes read has one (`codegen.bench.digital` checks).
    probes: []const Probe = &.{},

    /// One named digital value: its path, its slot, whether it is a `real`.
    pub const Name = struct { path: []const u8, slot: u32, real: bool };
    /// A probe terminal (`name` as the program spells it, `u.sense`) and
    /// the unknowns its potential is `x[hi] - x[lo]` of; null is ground.
    pub const Probe = struct { name: []const u8, hi: ?u32, lo: ?u32 };
};

/// What a runner renders: the card, the operating points, and the device
/// tables to check. Invariants `parse` establishes and the renderers assert:
/// `times_s` is non-empty, finite and strictly increasing; every `Sweep` has
/// at least one value.
pub const Bench = struct {
    /// §3.4 parameter overrides, in source order. A name is the parameter's
    /// source name and its `Model` field at once, so a host-written field
    /// (`gmin__`) is named as the device spells it.
    params: []const Binding = &.{},
    /// Unknowns held at a fixed value across the whole run. A name is a `U`
    /// member, resolved by the access-function rule (`V(a)`, `I(a,b)`, `x[a]`).
    bias: []const Binding = &.{},
    /// Swept unknowns: the operating points are the cartesian product of
    /// `sweeps` then `psweeps`, the last line varying fastest.
    sweeps: []const Sweep = &.{},
    /// §8.2 swept parameters: each point gets its own card and §6.3.4 `derive`.
    psweeps: []const Sweep = &.{},
    /// Per-timepoint values of an unknown, one per `times_s` entry; a short
    /// list holds its last value.
    waves: []const Sweep = &.{},
    /// §9.10 `$temperature`, in kelvin.
    temperature_k: f64 = 300.15,
    /// §9.10 `$abstime` values. Each operating point runs once per time, `dt`
    /// from the previous entry (§4.5.3), so §4.5 operators see a history.
    times_s: []const f64 = &.{0.0},
    /// §4.6.1. Unwritten: `.tran` under a grid of two or more times, else `.dc`.
    analysis: Analysis = .dc,
    /// §9.15 Table 9-28 `analysis_name`; empty means the kind's spelling.
    analysis_name: []const u8 = "",
    /// `//! solve`: unknowns no directive names are solved by Newton (§5.6);
    /// otherwise every unnamed unknown is tied to the reference.
    solve_free: bool = false,
    /// What the runner prints besides the model's own output and the gates.
    print: Print = .residual,
    /// §4.6.4 the expected `noise_gens` rows in table order; null when no
    /// `//! noise` line was written, empty for `//! noise none`.
    noise: ?[]const NoiseWant = null,
    /// §4.6.3 the expected `ac_gens` rows; null and empty as `noise`.
    acstim: ?[]const AcWant = null,
    /// `//! acdyn` lines, in source order.
    acdyn: []const AcDynWant = &.{},
    /// §5.6.1.2 the expected charge sites in slot order, each in the form the
    /// runner prints (`g+ s- lte`; another weight as `g*0.5`); null and empty
    /// as `noise`.
    qsites: ?[]const []const u8 = null,
    /// §9.17.3 exactly the lanes `seed` returns non-null, with their values;
    /// null and empty as `noise`.
    seeds: ?[]const Binding = null,
    /// §2.9.2 the expected `decl_meta` rows, each as the runner prints one
    /// (`kind name desc="..." units="..."`); null and empty as `noise`.
    meta: ?[]const []const u8 = null,
    /// §3.6.1.2 the tolerance the device publishes per named unknown.
    abstols: []const Binding = &.{},
    /// §9.17.3 `limit` cases, each run at the first point's solution.
    limits: []const LimitCase = &.{},
};

/// One `name = value` binding: a parameter card value or a pinned unknown.
pub const Binding = struct { name: []const u8, value: f64 };

/// One `sweep`/`psweep`/`wave` line: a name and its values, never empty.
pub const Sweep = struct { name: []const u8, values: []const f64 };

/// One `//! limit` line: the `old` lanes that differ from `cur`, and the
/// wanted outputs, where the name `converged` is the verdict pseudo-lane.
pub const LimitCase = struct { old: []const Binding, want: []const Binding };

/// §4.6.1 analysis kinds, spelled as the generated `AnalysisKind` enum does.
pub const Analysis = enum { static, ic, nodeset, dc, tran, ac, noise };

/// `//! print residual|none`: `none` leaves only the model's own output,
/// the gates' FAILs and `next_bp`.
pub const Print = enum { residual, none };

/// One `//! noise` row (§4.6.4). Fields after `topo` assert nothing when
/// absent. `topo` is checked against `noise_gens` at comptime; `white`,
/// `flicker`, `ef` and `corrs` are read from `noisePsd` at the first point.
pub const NoiseWant = struct {
    /// `kind(row,col)#source`, verbatim, compared byte-exact with the
    /// device's own spelling of the row.
    topo: []const u8,
    /// §4.6.4.1-.3 the source label, byte-exact; empty asserts no label.
    name: ?[]const u8 = null,
    /// §4.6.4.1/.2 the effective density including §4.6.4.6's `coeff²`.
    white: ?f64 = null,
    flicker: ?f64 = null,
    /// §4.6.4.2 the flicker exponent, unscaled.
    ef: ?f64 = null,
    /// Relative tolerance of every number on this row.
    rtol: f64 = 1e-12,
    /// §4.6.4.3/.4 the table's interpolation.
    interp: ?Interp = null,
    /// §4.6.4.3/.4 the table's exported knots, sorted by frequency.
    points: ?[]const [2]f64 = null,
    /// §4.6.4.3/.4 `<f>:<S>` pairs: the table's own density at f.
    psd: ?[]const [2]f64 = null,
    /// §4.6.4.6 the correlation coefficient with other rows.
    corrs: []const Corr = &.{},

    /// §4.6.4.3 `linear` or §4.6.4.4 `log`, spelled as `contract` tags it.
    pub const Interp = enum { linear, log };

    /// One `corr=<j>:<rho>` field.
    pub const Corr = struct {
        /// The other row, by its index in `noise_gens`.
        with: u16,
        rho: f64,
    };

    /// Returns whether this row asserts a bias-dependent number, which the
    /// runner reads at an operating point.
    pub fn needsPoint(w: NoiseWant) bool {
        return w.white != null or w.flicker != null or w.ef != null or w.corrs.len != 0;
    }
};

/// One `//! acstim` row (§4.6.3). `topo` and `name` are checked against
/// `ac_gens` at comptime; `mag` and `phase` are read at the first point.
pub const AcWant = struct {
    /// `(row,col)` without spaces, compared byte-exact.
    topo: []const u8,
    /// §4.6.3 `analysis_name`, byte-exact.
    name: ?[]const u8 = null,
    /// §4.6.3 magnitude and phase (radians).
    mag: ?f64 = null,
    phase: ?f64 = null,
    /// Relative tolerance of `mag` and `phase`.
    rtol: f64 = 1e-12,

    /// Returns whether this row reads the card, which needs a point.
    pub fn needsPoint(w: AcWant) bool {
        return w.mag != null or w.phase != null;
    }
};

/// One `//! acdyn` row: `acDyn`'s term at local Jacobian entry (row, col),
/// `U` tag names, at ω = 2πf and the first point. An unlisted slot reads 0.
pub const AcDynWant = struct {
    row: []const u8,
    col: []const u8,
    f_hz: f64,
    re: f64,
    im: f64,
    /// Absolute tolerance on each part.
    tol: f64 = 1e-12,
};

/// Point `n`'s column values, first column first: the mixed-radix digits of
/// `n`, each column's length its radix.
pub const Row = struct {
    bench: *const Bench,
    n: u32,
    /// The next column to yield.
    k: usize = 0,
    /// How many points one step of column `k` spans: the product of the
    /// lengths after it.
    stride: u32,

    /// Starts point `n` of the `count` that `pointCount(bench)` returned.
    /// Asserts that `n < count`.
    pub fn init(bench: *const Bench, count: u32, n: u32) Row {
        assert(n < count);
        assert(count <= points_max);
        const first = if (columnCount(bench) == 0) 1 else column(bench, 0).values.len;
        assert(count % first == 0);
        return .{ .bench = bench, .n = n, .stride = count / @as(u32, @intCast(first)) };
    }

    /// Returns the next column's value, or null after the last column.
    pub fn next(r: *Row) ?f64 {
        if (r.k == columnCount(r.bench)) return null;
        const vals = column(r.bench, r.k).values;
        assert(r.stride != 0);
        const v = vals[(r.n / r.stride) % vals.len];
        r.k += 1;
        if (r.k < columnCount(r.bench)) {
            const len: u32 = @intCast(column(r.bench, r.k).values.len);
            assert(r.stride % len == 0);
            r.stride /= len;
        } else assert(r.stride == 1);
        return v;
    }
};

/// Returns how many points the sweeps expand to: the product of every
/// column's length, 1 with no column. Fails past `points_max`. Asserts that
/// no column is empty.
pub fn pointCount(bench: *const Bench) error{TooManyPoints}!u32 {
    var total: u32 = 1;
    for (0..columnCount(bench)) |k| {
        const len = column(bench, k).values.len;
        assert(len != 0); // `numbers` refuses an empty list.
        if (len > points_max) return error.TooManyPoints;
        total *= @intCast(len);
        if (total > points_max) return error.TooManyPoints;
    }
    assert(total != 0);
    assert(total <= points_max);
    return total;
}

/// Returns the number of columns a point has: the unknown sweeps, then the
/// parameter sweeps.
pub fn columnCount(bench: *const Bench) usize {
    return bench.sweeps.len + bench.psweeps.len;
}

/// Column `k` of a point: `sweeps[k]`, then the `psweeps`. Asserts that
/// `k < columnCount(bench)`.
pub fn column(bench: *const Bench, k: usize) Sweep {
    assert(k < columnCount(bench));
    return if (k < bench.sweeps.len) bench.sweeps[k] else bench.psweeps[k - bench.sweeps.len];
}
