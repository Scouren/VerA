//! The float verdict: an `Air` and what the caller knows of its leaves
//! (`Input`: §3.4.2 parameter ranges, the host's unknown bound, the roots,
//! the callees) in; per instruction an interval and a NaN bit, per root a
//! float mode, and the §4.3.2 diagnostics (E0601-E0607, E0609, W0650,
//! W0651, W0653) into a `Diag.Wip` out. A root is `.optimized` when no value
//! on its backward slice can be inf or NaN, so `@setFloatMode(.optimized)`
//! is safe for it; else `.strict`, which is never an error.
//!
//! One recursive walk of the nesting (Zig's `Air/Liveness.zig` shape): a
//! guard fact is pushed entering a `cond_br` body and popped leaving it, so
//! the facts on a value are its enclosing conditions; a block's result is
//! the join of its `br` operands; a slot's state at a block's exit is the
//! join of its states on every `br` to it; a `loop` iterates to a fixpoint,
//! widening after `widen_after` rounds. A fact about one value holds for
//! every value structurally equal to it (a congruence class: the same tag
//! over the same classes, a `load` keyed by its slot's version), which is
//! what proves `if (V(p,n) > 0) ln(V(p,n))` when each `V(p,n)` is computed
//! anew. Finiteness is proven, never assumed (`Interval`: sound IEEE 754
//! transfers, no overflow contract): a value is finite when its interval
//! excludes ±inf and it cannot be NaN. A parameter's interval is its range,
//! and it may be NaN only when that range is the whole line; an unproven
//! domain costs the result its finiteness.
//! Cites: VAMS-2023 §3.2, §3.4.2, §4.2.3, §4.2.4, §4.2.5, §4.2.7, §4.2.8,
//! §4.2.12, §4.3, §4.3.2, §4.4, §4.5.13, §5.8, §5.9, §9.15, §9.19.
//!
//! Contents:
//! - `pub const Float = @This()` (fields `iv`, `nan`, `domain`, `modes`, `error_count`), `pub fn finite(f: Float, i: u32) bool`
//! - `pub const Mode = enum(u8) { optimized, strict }`, `Mode.strictest(a: Mode, b: Mode) Mode`
//! - `pub const Domain = enum(u8) { none, proven, open, violated }`
//! - `pub const Param = struct`, `pub const Root = struct`, `pub const Input = struct`
//! - `pub const errors_max: u8`
//! - `pub fn analyze(gpa: Allocator, air: Air, ip: *const InternPool, in: Input, wip: *Diag.Wip) Allocator.Error!Float`
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
const verdict = @import("Float/verdict.zig");
const Walk = @import("Float/Walk.zig");
const Inst = Air.Inst;
const Abstract = Interval.Abstract;

/// File-as-struct: the verdict. Every slice is allocated with the `gpa`
/// passed to `analyze`; free with `deinit`.
pub const Float = @This();

/// Per instruction: an interval holding every value it defines (a `block`
/// its result, an `assign` the value it writes), over every execution.
iv: []Interval,
/// Per instruction: some value it defines may be NaN (an integer never is,
/// unless its domain is unproven).
nan: []bool,
/// Per instruction: how its §4.3.2 obligation came out (`none`: it has none).
domain: []Domain,
/// Per `Input.roots` row. Invariant: a nonzero `error_count` rates every
/// root `.strict`.
modes: []Mode,
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
    /// A bound B with |unknown| <= B for every §4.4 probe: the hardware knob
    /// that makes probe-dependent transcendentals provable. Null or NaN:
    /// unbounded, still finite.
    unknown_bound: ?f64 = null,
};

/// Most §4.3.2 errors counted and reported: one bad expression otherwise
/// reports a cascade.
pub const errors_max: u8 = 64;

/// Walks `air` once, checks every domain, reports into `wip` and rates
/// every root. Scratch lives in an arena on `gpa` that dies before return.
/// Asserts that `air` is well formed (`Air.Verify`).
pub fn analyze(gpa: Allocator, air: Air, ip: *const InternPool, in: Input, wip: *Diag.Wip) Allocator.Error!Float {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const n = air.instructions.len;
    var f: Float = .{ .iv = &.{}, .nan = &.{}, .domain = &.{}, .modes = &.{}, .error_count = 0 };
    errdefer f.deinit(gpa);
    f.iv = try gpa.alloc(Interval, n);
    f.nan = try gpa.alloc(bool, n);
    f.domain = try gpa.alloc(Domain, n);
    f.modes = try gpa.alloc(Mode, in.roots.len);
    @memset(f.iv, Walk.empty);
    @memset(f.nan, true);
    @memset(f.domain, .none);

    var w = try Walk.init(arena, air, ip, in, &f);
    try w.body(air.mainBody(), 0);
    assert(w.saved.items.len == 0); // every fact popped
    assert(w.frames.items.len == 0);
    try verdict.report(wip, air, ip, in, &f, w.why, w.dom_iv);
    try verdict.rate(arena, air, ip, in, &f, wip);
    if (f.error_count != 0) for (f.modes) |m| assert(m == .strict);
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
    gpa.free(f.modes);
    f.* = undefined;
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
    _ = verdict;
    _ = Walk;
}
