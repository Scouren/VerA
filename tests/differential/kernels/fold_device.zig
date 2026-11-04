//! `diff-kernels` part 3, fold equals device: for every real Air tag Sema
//! folds, the constant `sema.fold.tag` gives against the value the device
//! computes at run time for the same operands, through the expression
//! codegen's Zig backend writes for that tag (`src/codegen/zig/Function.zig`:
//! a family method, a checked `M.z*D`, or `F.zLu(S, m, M.z*(F.zL(S, m),
//! F.zLw(S, m, a)))`), over the specials (every pair, for a binary tag) and
//! `g.random_per_fn` seeded draws. Equal bit for bit (any NaN equals any
//! NaN, and a zero's sign counts): a folded constant is the device's value
//! (lib/TODO.md §7).
//! Cites: VAMS-2023 §4.2, §4.3 (Tables 4-14, 4-15).
//!
//! Contents:
//! - `pub fn run() u32`: the tags that differ, each printed with an example
//! - `pub fn value(comptime t: Tag, x: f64, y: f64) f64`: the device's value

const std = @import("std");
const g = @import("gen.zig");
const sk = @import("std_kernels");
const sema = @import("sema");
const Tag = @import("air").Inst.Tag;
const scalar = @import("scalar.zig");
const M = sk.math;
const Const = sk.fold.Const;
const S = scalar.Ref;

const Fam = sk.family.Family(2, ~@as(u64, 0));
const m = 3;
const V = S.Of(m);
const unary = [_]Tag{ .fneg, .exp, .sin, .cos, .tanh, .sinh, .cosh, .atan, .expm1, .sqrt, .ln, .ln1p, .fabs, .log10, .tan, .asin, .acos, .asinh, .acosh, .atanh, .floor, .ceil };
const binary = [_]Tag{ .fadd, .fsub, .fmul, .fdiv, .fmod, .hypot, .atan2, .fmin, .fmax, .pow };

/// Runs every tag; returns how many differ.
pub fn run() u32 {
    var differ: u32 = 0;
    var prng = std.Random.DefaultPrng.init(0xf01d_de71ce);
    const r = prng.random();
    inline for (unary) |t| differ += sweep(t, 1, r);
    inline for (binary) |t| differ += sweep(t, 2, r);
    return differ;
}

/// The value lane of what the device computes for `t` (the expression
/// `Function.zig` writes), over operands that move with the solve.
pub fn value(comptime t: Tag, x: f64, y: f64) f64 {
    const a: V = .{ .v = x, .d = .{ 1, -1 } };
    const b: V = .{ .v = y, .d = .{ -0.5, 2 } };
    const out: V = switch (t) {
        .fadd => a.add(b),
        .fsub => a.sub(b),
        .fmul => a.mul(b),
        .fdiv => a.div(b),
        .fneg => a.neg(),
        .exp, .sin, .cos, .tanh, .sinh, .cosh, .atan, .expm1 => @field(V, @tagName(t))(a),
        .sqrt => M.zSqrtD(S, a),
        .ln => M.zLnD(S, a),
        .ln1p => M.zLn1pD(S, a),
        .fabs => Fam.zAbs(S, a),
        .log10 => kernel1("zLog10D", a),
        .tan => kernel1("zTan", a),
        .asin => kernel1("zAsin", a),
        .acos => kernel1("zAcos", a),
        .asinh => kernel1("zAsinh", a),
        .acosh => kernel1("zAcosh", a),
        .atanh => kernel1("zAtanh", a),
        .floor => kernel1("zFloor", a),
        .ceil => kernel1("zCeil", a),
        .fmod => kernel2("zFmod", a, b),
        .hypot => kernel2("zHypot", a, b),
        .atan2 => kernel2("zAtan2", a, b),
        .fmin => kernel2("zMin", a, b),
        .fmax => kernel2("zMax", a, b),
        // An exponent that moves with the solve; `powConst` below checks
        // the fixed-exponent form against it.
        .pow => Fam.zPowL(S, m, Fam.zTo(S, m, a), Fam.zTo(S, m, b), true),
        else => @compileError("no device form for " ++ @tagName(t)),
    };
    if (t == .pow) {
        const k = M.zPowK(S, a, y);
        if (!same(k.val(), out.val())) return k.val();
    }
    return out.val();
}

// ---- private ----

fn sweep(comptime t: Tag, comptime arity: u8, r: std.Random) u32 {
    const n_special = g.specials.len;
    const pairs = if (arity == 1) n_special else n_special * n_special;
    var differ: u64 = 0;
    var example: [2]f64 = undefined;
    var ex_fold: f64 = 0;
    var ex_dev: f64 = 0;
    for (0..pairs + g.random_per_fn) |k| {
        var x: [2]f64 = undefined;
        for (x[0..arity], 0..) |*a, j| a.* = if (k < pairs) g.specials[if (j == 0) k % n_special else k / n_special] else g.AnyReal.gen(r, n_special + k);
        var args: [2]Const = undefined;
        for (x[0..arity], args[0..arity]) |a, *c| c.* = .{ .real = a };
        const folded = sema.fold.tag(t, args[0..arity]) orelse continue;
        const f = folded.asReal();
        const d = value(t, x[0], x[1]);
        if (same(f, d)) continue;
        if (differ == 0) {
            example = x;
            ex_fold = f;
            ex_dev = d;
        }
        differ += 1;
    }
    if (differ == 0) return 0;
    std.debug.print("fold-device: {s}: {d} of {d} operand sets differ; e.g. at {e} {e}: folded {e}, device {e}\n", .{ @tagName(t), differ, pairs + g.random_per_fn, example[0], if (arity == 2) example[1] else @as(f64, 0), ex_fold, ex_dev });
    return 1;
}

fn same(a: f64, b: f64) bool {
    return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b)) or (std.math.isNan(a) and std.math.isNan(b));
}

fn kernel1(comptime name: []const u8, a: V) V {
    return Fam.zLu(S, m, @field(M, name)(Fam.zL(S, m), Fam.zLw(S, m, a)));
}

fn kernel2(comptime name: []const u8, a: V, b: V) V {
    return Fam.zLu(S, m, @field(M, name)(Fam.zL(S, m), Fam.zLw(S, m, a), Fam.zLw(S, m, b)));
}
