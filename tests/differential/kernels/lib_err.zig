//! `diff-kernels` part 4, the Air passes' error table: each library
//! function's device value (`Air.interp.deviceLib`) against the f128
//! reference over the specials and `g.random_per_fn` draws, its largest
//! error held to `Air.Interval.libErr`, the bound Interval's margins are
//! derived from. A table entry the device breaks fails the run.
//! Cites: VAMS-2023 §4.3.1 (Table 4-14), §4.3.2 (Table 4-15).
//!
//! Contents:
//! - `pub fn run() u32`: the functions over their bound, each printed

const std = @import("std");
const g = @import("gen.zig");
const reference = @import("reference.zig");
const Air = @import("air");
const Tag = Air.Inst.Tag;

/// Each tag, its reference's name, and the draws' range (y's for binary).
const fns = .{
    .{ .exp, "exp", g.Real(-750, 750), null },
    .{ .expm1, "expm1", g.Real(-40, 710), null },
    .{ .ln, "log", g.Real(1e-300, 1e300), null },
    .{ .ln1p, "log1p", g.Real(-1, 1e10), null },
    .{ .log10, "log10", g.Real(1e-300, 1e300), null },
    .{ .sinh, "sinh", g.Real(-720, 720), null },
    .{ .cosh, "cosh", g.Real(-720, 720), null },
    .{ .tanh, "tanh", g.Real(-40, 40), null },
    .{ .asinh, "asinh", g.Real(-1e300, 1e300), null },
    .{ .acosh, "acosh", g.Real(1, 1e300), null },
    .{ .atanh, "atanh", g.Real(-1, 1), null },
    .{ .atan, "atan", g.Real(-1e10, 1e10), null },
    .{ .asin, "asin", g.Real(-1, 1), null },
    .{ .acos, "acos", g.Real(-1, 1), null },
    .{ .pow, "pow", g.Real(0, 1e3), g.Real(-40, 40) },
    .{ .hypot, "hypot", g.Real(-1e3, 1e3), g.Real(-1e3, 1e3) },
    .{ .atan2, "atan2", g.Real(-1e3, 1e3), g.Real(-1e3, 1e3) },
};

/// Checks every function; returns how many exceed `libErr`.
pub fn run() u32 {
    var prng = std.Random.DefaultPrng.init(0x11b_e44);
    const r = prng.random();
    var over: u32 = 0;
    inline for (fns) |f| {
        const worst = sweep(f[0], f[1], f[2], f[3], r);
        const bound = Air.Interval.libErr(f[0]);
        std.debug.print("lib-err: {s}: device max {d:.3} ulp against f128, Interval.libErr {d}\n", .{ @tagName(f[0]), worst, bound });
        if (worst > bound) over += 1;
    }
    return over;
}

// ---- private ----

fn sweep(comptime t: Tag, comptime name: []const u8, comptime X: type, comptime Y: ?type, r: std.Random) f64 {
    var worst: f64 = 0;
    const n = g.specials.len * g.specials.len + g.random_per_fn;
    for (0..n) |i| {
        const pair = i < g.specials.len * g.specials.len;
        const x = X.gen(r, if (pair) i % g.specials.len else n);
        const y: f64 = if (Y) |YS| YS.gen(r, if (pair) i / g.specials.len else n) else 0;
        const v = Air.interp.deviceLib(t, x, y).?;
        const q = reference.of(name, x, y) orelse continue;
        // An overflow both round to the same infinity is no error.
        const e = if (std.math.isInf(v) and v == @as(f64, @floatCast(q))) 0 else reference.ulpErr(v, q);
        worst = @max(worst, e);
    }
    return worst;
}
