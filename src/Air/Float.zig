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
//! `default_unknown_bound` is measured (`diff-air-passes`, its
//! `air_passes/bound.zig`): the roots rated `.optimized` with every probe
//! in `[-B, B]`, over generated programs and hand-built devices (resistor,
//! capacitor, diode and Ebers-Moll `exp(V/vt)`, diode with `$vt`, MOSFET
//! square law, BSIM-like softplus rational, `tanh` limiter):
//!
//!   B (V or A)              1        10       100      1e3      1e4
//!   generated (2,000)       38.4%    36.6%    36.6%    35.1%    35.1%
//!   devices (8)             7        5        4        4        4
//!
//! 1 proves the junctions, but a node voltage past 1 V is everyday; 10 is
//! the largest bound that keeps the softplus `exp` finite and covers the
//! supplies of most analog ICs; past it only the polynomial devices stay.
//! So B = 10: a probe past it runs the strict body, correct and slower. A
//! junction `exp(V(a,c)/vt)` reads two node voltages, so no generous box
//! proves it (2B/vt passes 709 at B = 9.2); `$vt` of `$temperature` is
//! unbounded, so that diode is proven at no bound.
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
const builtin = @import("builtin");
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
    /// One per `probe` index (`Device.nodes` order): the unknown's name,
    /// for a probe culprit's message; empty or a short slice falls back to
    /// "a probe of unknown {d}".
    probe_names: []const []const u8 = &.{},
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
    const wd = try walk(arena, air, ip, in, .{
        .probe = if (bound) |b| .{ .lo = -b, .hi = b } else .{ .lo = -inf, .hi = inf, .lo_open = true, .hi_open = true },
        .whole_nan = false,
    }, &d);
    try rating.report(wip, air, ip, in, &d, wd.why, wd.dom_iv);

    var f = try alloc(gpa, n, in.roots.len);
    errdefer f.deinit(gpa);
    f.error_count = d.error_count;
    const b = bound orelse default_unknown_bound;
    _ = try walk(arena, air, ip, in, .{ .probe = .{ .lo = -b, .hi = b }, .whole_nan = true }, &f);
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
/// One walk of `air` into `f`. In Debug (tests included) the `.dense` walk
/// runs too, into scratch tables, and every table it writes must match the
/// trail's bit for bit: the oracle for the trail's saves and joins (M9).
fn walk(arena: Allocator, air: Air, ip: *const InternPool, in: Input, leaves: Walk.Leaves, f: *Float) Allocator.Error!Walk {
    assert(leaves.states == .trail);
    var w = try Walk.init(arena, air, ip, in, leaves, f);
    try w.body(air.mainBody(), 0);
    if (builtin.mode != .debug) return w;
    var g = try alloc(arena, air.instructions.len, in.roots.len);
    var dense = leaves;
    dense.states = .dense;
    var o = try Walk.init(arena, air, ip, in, dense, &g);
    try o.body(air.mainBody(), 0);
    for (0..air.instructions.len) |i| {
        assert(sameIv(f.iv[i], g.iv[i]));
        assert(f.nan[i] == g.nan[i]);
        assert(f.domain[i] == g.domain[i]);
        assert(w.why[i] == o.why[i]);
        if (w.why[i] != .none) assert(sameIv(w.dom_iv[i], o.dom_iv[i]));
    }
    return w;
}

/// Bit equality: two walks that agree agree on the sign of a zero bound.
fn sameIv(a: Interval, b: Interval) bool {
    return @as(u64, @bitCast(a.lo)) == @as(u64, @bitCast(b.lo)) and @as(u64, @bitCast(a.hi)) == @as(u64, @bitCast(b.hi)) and
        a.lo_open == b.lo_open and a.hi_open == b.hi_open and a.nonzero == b.nonzero;
}

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

test "analyze: a merge joins a slot one arm leaves with its entry state; a loop carries one" {
    // Oracle: the `.dense` walk, which `walk` runs beside the trail in
    // Debug and holds to it bit for bit; and by hand, the join each slot
    // must reach. `alloc` starts a slot at 0.
    //   a = 0; b = 0;  if (p0 < 0) a = 1; else b = 2;      -> a in [0,1], b in [0,2]
    //   k = 0;  while (k < 3) k = k + 1;                    -> k in [0,inf) (widened)
    //   ret a + b + k
    const gpa = std.testing.allocator;
    var ip: InternPool = try .init(gpa);
    defer ip.deinit(gpa);
    var b: Air.Builder = try .init(gpa);
    defer b.deinit(gpa);
    const x = try b.addInst(gpa, .{ .tag = .probe, .data = .{ .ty_index = .{ .ty = .real_type, .index = 0 } } });
    const sa = try b.addInst(gpa, .{ .tag = .alloc, .data = .{ .ty = .real_type } });
    const sb = try b.addInst(gpa, .{ .tag = .alloc, .data = .{ .ty = .real_type } });
    const sk = try b.addInst(gpa, .{ .tag = .alloc, .data = .{ .ty = .integer_type } });
    const merge = try b.addInst(gpa, .{ .tag = .block, .data = undefined });
    const neg = try b.addBinOp(gpa, .flt, .fromIndex(x), .fromIntern(.zero_real));
    const ta = try b.addBinOp(gpa, .assign, .fromIndex(sa), .fromIntern(.one_real));
    const tbr = try b.addInst(gpa, .{ .tag = .br, .data = .{ .br = .{ .block_inst = merge, .operand = .none } } });
    const eb = try b.addBinOp(gpa, .assign, .fromIndex(sb), .fromIntern(.two_real));
    const ebr = try b.addInst(gpa, .{ .tag = .br, .data = .{ .br = .{ .block_inst = merge, .operand = .none } } });
    const cb = try b.addCondBr(gpa, .fromIndex(neg), &.{ ta, tbr }, &.{ eb, ebr });
    try b.setBody(gpa, merge, .none, &.{ neg, cb });
    const three = Inst.Ref.fromIntern(try ip.get(gpa, .{ .int = .{ .ty = .integer_type, .storage = .{ .small = 3 } } }));
    const out = try b.addInst(gpa, .{ .tag = .block, .data = undefined });
    const lp = try b.addInst(gpa, .{ .tag = .loop, .data = undefined });
    const k0 = try b.addUnOp(gpa, .load, .fromIndex(sk));
    const go = try b.addBinOp(gpa, .ilt, .fromIndex(k0), three);
    const k1 = try b.addBinOp(gpa, .iadd, .fromIndex(k0), .fromIntern(.one));
    const set_k = try b.addBinOp(gpa, .assign, .fromIndex(sk), .fromIndex(k1));
    const again = try b.addInst(gpa, .{ .tag = .repeat, .data = .{ .repeat = .{ .loop_inst = lp } } });
    const done = try b.addInst(gpa, .{ .tag = .br, .data = .{ .br = .{ .block_inst = out, .operand = .none } } });
    const step = try b.addCondBr(gpa, .fromIndex(go), &.{ k1, set_k, again }, &.{done});
    try b.setBody(gpa, lp, .none, &.{ k0, go, step });
    try b.setBody(gpa, out, .none, &.{lp});
    const la = try b.addUnOp(gpa, .load, .fromIndex(sa));
    const lb = try b.addUnOp(gpa, .load, .fromIndex(sb));
    const ab = try b.addBinOp(gpa, .fadd, .fromIndex(la), .fromIndex(lb));
    const ret = try b.addUnOp(gpa, .ret, .fromIndex(ab));
    var air = try b.finish(gpa, &.{ x, sa, sb, sk, merge, out, la, lb, ab, ret });
    defer air.deinit(gpa);
    try std.testing.expectEqual(@as(?Air.Verify.Violation, null), try Air.Verify.verify(gpa, air, &ip));
    var wip: Diag.Wip = .init(gpa);
    defer wip.deinit();
    var f = try analyze(gpa, air, &ip, .{}, &wip);
    defer f.deinit(gpa);
    const ia = f.iv[@backingInt(la)];
    const ib = f.iv[@backingInt(lb)];
    try std.testing.expect(ia.lo == 0 and ia.hi == 1);
    try std.testing.expect(ib.lo == 0 and ib.hi == 2);
    try std.testing.expect(f.iv[@backingInt(k0)].lo == 0);
}

test {
    _ = domains;
    _ = rating;
    _ = Walk;
}
