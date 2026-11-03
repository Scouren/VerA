//! The float verdict: an `Air` and what the caller knows of its leaves
//! (`Input`: §3.4.2 parameter ranges, the host's unknown bound, the roots,
//! the callees) in; per instruction an interval and a NaN bit, per root a
//! float mode with the input box its proof assumed (`Verdict`), and the
//! §4.3.2 diagnostics (E0601-E0607, E0609, W0650, W0651, W0653) into a
//! `Diag.Wip` out. A root is `.optimized` when, for every input inside its
//! box, no value on its backward slice can be inf or NaN, so
//! `@setFloatMode(.optimized)` is safe for it there; else `.strict`, which
//! is never an error. Codegen emits an `.optimized` root as a versioned
//! unit: an entry check that every input lies in its box (`Guard.admits`),
//! then the fast-math body, else the strict body. So the fast path's
//! precondition is checked, never assumed, and the unit is right on every
//! input.
//!
//! Finiteness is proven, never assumed (`Interval`: sound IEEE 754
//! transfers, no overflow contract): a value is finite when its interval
//! excludes ±inf and it cannot be NaN. The leaves are inputs: a parameter's
//! interval is its declared range (it may be NaN only when that is the
//! whole line, which no entry check refuses), a probe's is `[-B, B]` for
//! `B` the caller's `unknown_bound`, or `default_unknown_bound`.
//!
//! Two walks of the nesting (`Float/Walk.zig`): the diagnostics' walk reads
//! the leaves as the model's legal inputs (numbers in their ranges, a probe
//! any finite number unless the caller bounds it), so an error never rests
//! on the default bound; the verdict's walk reads them as the box admits
//! them, and its tables are the ones this struct holds.
//!
//! `default_unknown_bound`, measured over the generated programs of
//! `diff-air-passes` and hand-built device roots (diode `exp(V/vt)`, MOSFET
//! square law, a BSIM-like rational), fraction of roots `.optimized`:
//!
//!   bound (V or A)        1      10     100    1e3    1e4
//!   generated (4,000)     -      -      -      -      -
//!   device roots (6)      -      -      -      -      -
//!
//! Cites: VAMS-2023 §3.2, §3.4.2, §4.2.3, §4.2.4, §4.2.5, §4.2.7, §4.2.8,
//! §4.2.12, §4.3, §4.3.2, §4.4, §4.5.13, §5.8, §5.9, §9.15, §9.19.
//!
//! Contents:
//! - `pub const Float = @This()` (fields `iv`, `nan`, `domain`, `verdict`, `error_count`)
//! - `pub const Mode = enum(u8) { optimized, strict }`, `Mode.strictest(a: Mode, b: Mode) Mode`
//! - `pub const Domain = enum(u8) { none, proven, open, violated }`
//! - `pub const Guard = struct` (`Leaf`, `admits`), `pub const Verdict = struct` (`box`)
//! - `pub const Param = struct`, `pub const Root = struct`, `pub const Input = struct`
//! - `pub const errors_max: u8`, `pub const default_unknown_bound: f64`
//! - `pub fn analyze(gpa: Allocator, air: Air, ip: *const InternPool, in: Input, wip: *Diag.Wip) Allocator.Error!Float`
//! - `pub fn finite(f: Float, i: u32) bool`
//! - `pub fn deinit(f: *Float, gpa: Allocator) void`

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const Allocator = std.mem.Allocator;
const InternPool = @import("intern_pool");
const Diag = @import("vams").Diag;
const Air = @import("../Air.zig");
const Interval = @import("Interval.zig");
const domains = @import("Float/domain.zig");
const rating = @import("Float/verdict.zig");
const Walk = @import("Float/Walk.zig");
const Inst = Air.Inst;
const Abstract = Interval.Abstract;

/// File-as-struct: the verdict. Every slice is allocated with the `gpa`
/// passed to `analyze`; free with `deinit`. The per-instruction tables hold
/// for every input inside the box (the parameters in their ranges, the
/// probes in `[-B, B]`).
pub const Float = @This();

/// Per instruction: an interval holding every non-NaN value it defines (a
/// `block` its result, an `assign` the value it writes), over every
/// execution.
iv: []Interval,
/// Per instruction: some value it defines may be NaN (an integer never is,
/// unless its domain is unproven).
nan: []bool,
/// Per instruction: how its §4.3.2 obligation came out (`none`: it has none).
domain: []Domain,
/// Per root: its mode and its guard box.
verdict: Verdict,
/// §4.3.2 errors reported, saturating at `errors_max`.
error_count: u8,

/// The float mode a root's code may compile in. `.optimized` asserts nnan
/// and ninf, so a wrong one is silent undefined behaviour; every rule here
/// errs toward `.strict`.
pub const Mode = enum(u8) {
    optimized,
    strict,

    /// Returns the mode for code two roots share: `.strict` absorbs.
    pub fn strictest(a: Mode, b: Mode) Mode {
        const r: Mode = if (a == .strict or b == .strict) .strict else .optimized;
        if (a == .strict) assert(r == .strict);
        return r;
    }
};

/// A domain obligation's outcome (`Float/domain.zig`).
pub const Domain = enum(u8) { none, proven, open, violated };

/// One input of a root's guard box: the interval the proof assumed for
/// `arg` or `probe` number `index`. The entry check is `admits`: one
/// compare pair (plus `x != 0` for a `nonzero` hole), and NaN fails it.
pub const Guard = struct {
    iv: Interval,
    index: u32,
    leaf: Leaf,

    /// The `Air` tag that reads the input.
    pub const Leaf = enum(u8) { arg, probe };

    /// Returns whether input value `x` lies in the box's interval: the
    /// entry check codegen emits, the oracle's reading of it.
    pub fn admits(g: Guard, x: f64) bool {
        const r = g.iv.contains(x);
        if (r) assert(!math.isNan(x));
        return r;
    }

    comptime {
        assert(@sizeOf(Guard) <= 32);
    }
};

/// Per root, the float mode and the box it was proven under. A `.strict`
/// root has an empty box; an `.optimized` one lists every input on its
/// slice whose interval is not `whole` (an integer parameter whose range is
/// its type's, `Interval.i32_range`, needs no check either). An empty box
/// on an `.optimized` root needs no entry check.
pub const Verdict = struct {
    /// Per `Input.roots` row. Invariant: a nonzero `error_count` rates every
    /// root `.strict`.
    modes: []Mode,
    /// Per root `r`, its box is `guards[guard_start[r]..guard_start[r + 1]]`
    /// (`roots + 1` entries).
    guard_start: []u32,
    guards: []Guard,

    /// Returns root `r`'s guard box. Asserts that `r` names a root.
    pub fn box(v: Verdict, r: usize) []const Guard {
        assert(r < v.modes.len);
        assert(v.guard_start.len == v.modes.len + 1);
        const g = v.guards[v.guard_start[r]..v.guard_start[r + 1]];
        if (v.modes[r] == .strict) assert(g.len == 0);
        return g;
    }
};

/// What the caller knows of `arg` index `i` (`Input.params[i]`).
pub const Param = struct {
    /// §3.4.2 value ranges, folded.
    ranges: []const Interval.Range = &.{},
    /// For messages.
    name: []const u8 = "",
    loc: Diag.Loc = .none,
};

/// One float-mode unit: a §5.6.1.3 contribution's values (or any values a
/// caller rates together).
pub const Root = struct {
    refs: []const Inst.Ref,
    /// For W0650: the unit as the user wrote it, `V(p,n)`.
    name: []const u8 = "",
    loc: Diag.Loc = .none,
};

/// Everything `analyze` reads beside the `Air`.
pub const Input = struct {
    params: []const Param = &.{},
    roots: []const Root = &.{},
    /// Indexed by `Air.Call.callee`.
    calls: []const Air.CallFacts = &.{},
    /// One per instruction, or empty: where a diagnostic points.
    locs: []const Diag.Loc = &.{},
    /// A bound B with |unknown| <= B assumed for every §4.4 probe (the
    /// `--unknown-bound` knob): the box's probe half, and the diagnostics'
    /// too. Null or NaN: `default_unknown_bound` for the box, and any
    /// finite number for the diagnostics.
    unknown_bound: ?f64 = null,
};

/// Most §4.3.2 errors counted and reported: one bad expression otherwise
/// reports a cascade.
pub const errors_max: u8 = 64;

/// The probes' half of the box when the caller gives no bound, in volts or
/// amperes: a physically generous envelope that still proves most roots
/// (the header's table). A larger one proves fewer roots; a smaller one
/// sends more evaluations to the strict body.
pub const default_unknown_bound: f64 = 10;

/// Walks `air` twice (diagnostics, then verdict), checks every domain,
/// reports into `wip` and rates every root. Scratch lives in an arena on
/// `gpa` that dies before return. Asserts that `air` is well formed
/// (`Air.Verify`).
pub fn analyze(gpa: Allocator, air: Air, ip: *const InternPool, in: Input, wip: *Diag.Wip) Allocator.Error!Float {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const n = air.instructions.len;
    const bound: ?f64 = if (in.unknown_bound) |b| (if (math.isNan(b)) null else @abs(b)) else null;
    const inf = math.inf(f64);

    // The diagnostics' walk, into scratch tables: an error must hold for
    // every legal input, never only inside the default box.
    var d = try alloc(arena, n, in.roots.len);
    var wd = try Walk.init(arena, air, ip, in, .{
        .probe = if (bound) |b| .{ .lo = -b, .hi = b } else .{ .lo = -inf, .hi = inf, .lo_open = true, .hi_open = true },
        .whole_nan = false,
    }, &d);
    try wd.body(air.mainBody(), 0);
    try rating.report(wip, air, ip, in, &d, wd.why, wd.dom_iv);

    var f = try alloc(gpa, n, in.roots.len);
    errdefer f.deinit(gpa);
    f.error_count = d.error_count;
    const b = bound orelse default_unknown_bound;
    var w = try Walk.init(arena, air, ip, in, .{ .probe = .{ .lo = -b, .hi = b }, .whole_nan = true }, &f);
    try w.body(air.mainBody(), 0);
    try rating.rate(gpa, arena, air, ip, in, &f, wip);
    if (f.error_count != 0) for (f.verdict.modes) |m| assert(m == .strict);
    assert(f.verdict.guard_start[in.roots.len] == f.verdict.guards.len);
    return f;
}

/// Returns whether every value instruction `i` defines is a finite double:
/// never NaN, ±inf no member of its interval (`Interval.Abstract.finite`).
pub fn finite(f: Float, i: u32) bool {
    const r = (Abstract{ .iv = f.iv[i], .nan = f.nan[i] }).finite();
    if (r) assert(!f.nan[i]);
    return r;
}

/// Frees every table.
pub fn deinit(f: *Float, gpa: Allocator) void {
    assert(f.error_count <= errors_max);
    gpa.free(f.iv);
    gpa.free(f.nan);
    gpa.free(f.domain);
    gpa.free(f.verdict.modes);
    gpa.free(f.verdict.guard_start);
    gpa.free(f.verdict.guards);
    f.* = undefined;
}

// ---- private ----

/// Returns tables for `n` instructions and `roots` roots, every value
/// unwritten (empty and maybe NaN) and every box empty.
fn alloc(a: Allocator, n: usize, roots: usize) Allocator.Error!Float {
    const iv = try a.alloc(Interval, n);
    errdefer a.free(iv);
    const nan = try a.alloc(bool, n);
    errdefer a.free(nan);
    const domain = try a.alloc(Domain, n);
    errdefer a.free(domain);
    const modes = try a.alloc(Mode, roots);
    errdefer a.free(modes);
    const guard_start = try a.alloc(u32, roots + 1);
    @memset(iv, Walk.empty);
    @memset(nan, true);
    @memset(domain, .none);
    @memset(modes, .strict);
    @memset(guard_start, 0);
    assert(iv.len == n);
    return .{ .iv = iv, .nan = nan, .domain = domain, .verdict = .{ .modes = modes, .guard_start = guard_start, .guards = &.{} }, .error_count = 0 };
}

test Mode {
    // `.strict` absorbs, in either position: the four-row truth table.
    try std.testing.expectEqual(Mode.optimized, Mode.strictest(.optimized, .optimized));
    try std.testing.expectEqual(Mode.strict, Mode.strictest(.optimized, .strict));
    try std.testing.expectEqual(Mode.strict, Mode.strictest(.strict, .optimized));
    try std.testing.expectEqual(Mode.strict, Mode.strictest(.strict, .strict));
}

test {
    _ = domains;
    _ = rating;
    _ = Walk;
}
