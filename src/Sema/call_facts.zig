//! The callee facts table (research/airpasses.md T2): what the Air passes
//! know of a `call`'s `SysFn.Tag` callee, one row per tag, read by
//! `Air.Call.callee`. `air_passes.run` passes `&table` to `Air.Float.analyze`
//! as `.calls`, so `rate`'s W0650 culprit-naming (`verdict.zig`) reads a
//! modelled range instead of `.unknown` for `analysis()`, `$vt`, `limexp`
//! and the rest.
//! Cites: old `src/prove/transfer.zig:75-115` `callAbstract` (`range`),
//! `src/prove/invariance.zig:355-384` `callInvariant` (`invariant`),
//! `src/prove/timepoint.zig:100-112` `callTimepoint` (`timepoint`),
//! `src/prove/invariance.zig:396-404` `initCond` (`first_point`).
//!
//! Two gaps, both resolved toward the conservative default (`false`), never
//! a guess, because nothing downstream of this table may read a stale value
//! as fresh:
//! - `$simparam`'s old `invariant`/`timepoint` answer depends on its string
//!   argument (`"dt"`, `"iteration"`, a published homotopy knob); a table
//!   keyed on the tag alone cannot see it, so `$simparam`/`$simparam$str`
//!   stay at today's default (never cached) rather than guess the name.
//! - Old's `$held_*`, `$tp_*`, `$idx*`, `$wide*`, `$str$cat`, `$str$repeat`
//!   timepoint-true synthetic callees have no `SysFn.Tag` counterpart here
//!   (lowering mints a dedicated `Air` tag for them, not a `call`), so this
//!   table has no row to set for them.
//! - Old's `initial_step`'s first-point answer is conditional on a
//!   zero-argument call (`initCond`); `Legalize.firstPoint` reads this
//!   table by tag alone with no argument check, so only `analog$initial`
//!   (always zero-argument, `.exactly(0)`) is marked here. A zero-argument
//!   `initial_step()` still falls back to `false`, a precision loss, not a
//!   wrong answer: `Legalize` only elides a branch when the flag is `true`.
//!
//! Contents:
//! - `pub const table: [SysFn.Tag field count]Air.CallFacts`

const std = @import("std");
const vams = @import("vams");
const Air = @import("air");
const SysFn = vams.SysFn;

const tag_count = @typeInfo(SysFn.Tag).@"enum".field_names.len;

/// `Air.CallFacts` per `SysFn.Tag`, built once at comptime. A callee past
/// this table's end (`Sema/expr.zig`'s `user_callee`) is unmodelled: every
/// reader treats an out-of-range index as `.{}` (unknown, never cached).
pub const table: [tag_count]Air.CallFacts = blk: {
    @setEvalBranchQuota(100 * tag_count + 1000);
    var t: [tag_count]Air.CallFacts = undefined;
    for (&t, 0..) |*row, i| row.* = facts(@fromBackingInt(@intCast(i)));
    break :blk t;
};

comptime {
    std.debug.assert(table.len == tag_count);
    for (table) |f| if (f.first_point) std.debug.assert(f.range == .unit or f.range == .int);
}

/// One tag's facts. `range` feeds `Air.Interval.call` (`Air.Float`'s
/// verdict and diagnostics walks); `invariant`/`timepoint` are `Air/Setup.zig`'s
/// per-mode caching; `first_point` is `Air/Legalize.zig`'s branch elision.
fn facts(t: SysFn.Tag) Air.CallFacts {
    const range: Air.CallFacts.Range = switch (t) {
        // §4.6.1 analysis(), §5.2.1 analog initial, §5.10.2 initial_step/
        // final_step, §5.10.3 cross/above/timer, §4.5.4's static-solve test:
        // all render 0.0 or 1.0.
        .analysis, .@"analog$initial", .initial_step, .final_step, .cross, .above, .timer, .@"op$static" => .unit,
        // §9.15 kT/q; `Float/Walk.zig` overrides to `.positive` when called
        // with no argument (old `callAbstract`'s argument-free `$vt`).
        .@"$vt" => .vt,
        .@"$temperature", .@"$mfactor" => .positive,
        .@"$abstime", .@"$realtime" => .non_negative,
        .limexp => .limexp,
        // §9.19: names its argument, never reads it (`verdict.zig:93`).
        .@"$param_given" => .param_given,
        else => switch (SysFn.get(t).ty) {
            .int => .int,
            .str => .finite,
            .real, .none => .unknown,
        },
    };
    // Old `callInvariant`'s own allowlist: `$temperature`/`$vt` (env
    // parameters), `$param_given`/`$port_connected` (instantiation facts),
    // IEEE 1364 §17.11 math (both the bare VAMS-operator and the
    // `$`-prefixed digital-task spelling old unifies into one callee).
    // `$abs`/`$min`/`$max` are deliberately absent: old excludes them too.
    const invariant = switch (t) {
        .@"$temperature", .@"$vt", .@"$param_given", .@"$port_connected" => true,
        .sqrt, .@"$sqrt", .exp, .@"$exp", .@"$expm1" => true,
        .ln, .@"$ln", .@"$ln1p", .log, .@"$log", .@"$log10" => true,
        .floor, .@"$floor", .ceil, .@"$ceil" => true,
        .sin, .@"$sin", .cos, .@"$cos", .tan, .@"$tan" => true,
        .asin, .@"$asin", .acos, .@"$acos", .atan, .@"$atan" => true,
        .sinh, .@"$sinh", .cosh, .@"$cosh", .tanh, .@"$tanh" => true,
        .asinh, .@"$asinh", .acosh, .@"$acosh", .atanh, .@"$atanh" => true,
        .pow, .@"$pow", .hypot, .@"$hypot", .@"$atan2" => true,
        .@"$rtoi", .@"$itor", .@"$clog2" => true,
        else => false, // else: callInvariant's allowlist, never a guess
    };
    // Old `callTimepoint`: invariant implies timepoint-stable, plus its own
    // allowlist (`$abstime`/`$realtime` move with the timepoint, never
    // within one; the §5.10.2 events; `limexp`, a pure synthetic read).
    const timepoint = invariant or switch (t) {
        .@"$abstime", .@"$realtime", .analysis, .@"analog$initial", .initial_step, .final_step, .limexp => true,
        else => false, // else: callTimepoint's allowlist, never a guess
    };
    return .{
        .range = range,
        .invariant = invariant,
        .timepoint = timepoint,
        .first_point = t == .@"analog$initial", // old `initCond`: unconditional for this tag alone
        .name = @tagName(t),
    };
}
