//! Emit-time constant folding of `Air` value tags (the old
//! `src/ir/opcode.zig` fold rows): a tag over constant operands in, its
//! value out, computed by `kernels.fold`, the kernel the old MIR's run-time
//! ops share, so a folded value is the value the old interpreter computes.
//! Cites: VAMS-2023 §4.2, §4.2.1.1, §4.3 (Tables 4-14, 4-15).
//!
//! Contents:
//! - `pub fn tag(t: Air.Inst.Tag, args: []const fold.Const) ?fold.Const`

const std = @import("std");
const Air = @import("air");
const fold = @import("kernels").fold;

/// The old `src/ir/opcode.zig` fold rows, per Air tag: which kernel, over
/// which operand type, wrapped to §3.2's 32 bits or not.
const FoldRow = union(enum) {
    none,
    to_real,
    to_int,
    unary: struct { f: fold.UnaryOp, int: bool = false, wrap: bool = false },
    binary: struct { f: fold.BinaryOp, int: bool = false },
    math: struct { f: fold.MathFn, int: bool = false, wrap: bool = false },
};

const rows = std.EnumArray(Air.Inst.Tag, FoldRow).init(.{
    .fadd = .{ .binary = .{ .f = .add } },
    .fsub = .{ .binary = .{ .f = .sub } },
    .fmul = .{ .binary = .{ .f = .mul } },
    .fdiv = .{ .binary = .{ .f = .div } },
    .fmod = .{ .binary = .{ .f = .mod } },
    .fneg = .{ .unary = .{ .f = .minus } },
    .iadd = .{ .binary = .{ .f = .add, .int = true } },
    .isub = .{ .binary = .{ .f = .sub, .int = true } },
    .imul = .{ .binary = .{ .f = .mul, .int = true } },
    .idiv = .{ .binary = .{ .f = .div, .int = true } },
    .imod = .{ .binary = .{ .f = .mod, .int = true } },
    .ineg = .{ .unary = .{ .f = .minus, .int = true, .wrap = true } },
    .flt = .{ .binary = .{ .f = .lt } },
    .fgt = .{ .binary = .{ .f = .gt } },
    .fle = .{ .binary = .{ .f = .le } },
    .fge = .{ .binary = .{ .f = .ge } },
    .feq = .{ .binary = .{ .f = .eq } },
    .fne = .{ .binary = .{ .f = .neq } },
    .ilt = .{ .binary = .{ .f = .lt, .int = true } },
    .igt = .{ .binary = .{ .f = .gt, .int = true } },
    .ile = .{ .binary = .{ .f = .le, .int = true } },
    .ige = .{ .binary = .{ .f = .ge, .int = true } },
    .ieq = .{ .binary = .{ .f = .eq, .int = true } },
    .ine = .{ .binary = .{ .f = .neq, .int = true } },
    .logand = .{ .binary = .{ .f = .logical_and } },
    .logor = .{ .binary = .{ .f = .logical_or } },
    .lognot = .{ .unary = .{ .f = .logical_not } },
    .bitand = .{ .binary = .{ .f = .bit_and, .int = true } },
    .bitor = .{ .binary = .{ .f = .bit_or, .int = true } },
    .bitxor = .{ .binary = .{ .f = .bit_xor, .int = true } },
    .bitxnor = .{ .binary = .{ .f = .bit_xnor, .int = true } },
    .bitnot = .{ .unary = .{ .f = .bit_not, .int = true } },
    .shl = .{ .binary = .{ .f = .shl, .int = true } },
    .shr = .{ .binary = .{ .f = .shr, .int = true } },
    .sqrt = .{ .math = .{ .f = .sqrt } },
    .exp = .{ .math = .{ .f = .exp } },
    .expm1 = .{ .math = .{ .f = .expm1 } },
    .ln = .{ .math = .{ .f = .ln } },
    .ln1p = .{ .math = .{ .f = .ln1p } },
    .log10 = .{ .math = .{ .f = .log } },
    .pow = .{ .math = .{ .f = .pow } },
    .hypot = .{ .math = .{ .f = .hypot } },
    .floor = .{ .math = .{ .f = .floor } },
    .ceil = .{ .math = .{ .f = .ceil } },
    .fabs = .{ .math = .{ .f = .abs } },
    .fmin = .{ .math = .{ .f = .min } },
    .fmax = .{ .math = .{ .f = .max } },
    .iabs = .{ .math = .{ .f = .abs, .int = true, .wrap = true } },
    .imin = .{ .math = .{ .f = .min, .int = true } },
    .imax = .{ .math = .{ .f = .max, .int = true } },
    .ipow = .{ .binary = .{ .f = .pow, .int = true } },
    .sin = .{ .math = .{ .f = .sin } },
    .cos = .{ .math = .{ .f = .cos } },
    .tan = .{ .math = .{ .f = .tan } },
    .asin = .{ .math = .{ .f = .asin } },
    .acos = .{ .math = .{ .f = .acos } },
    .atan = .{ .math = .{ .f = .atan } },
    .atan2 = .{ .math = .{ .f = .atan2 } },
    .sinh = .{ .math = .{ .f = .sinh } },
    .cosh = .{ .math = .{ .f = .cosh } },
    .tanh = .{ .math = .{ .f = .tanh } },
    .asinh = .{ .math = .{ .f = .asinh } },
    .acosh = .{ .math = .{ .f = .acosh } },
    .atanh = .{ .math = .{ .f = .atanh } },
    .fi_cast = .to_int,
    .if_cast = .to_real,
    .opt_barrier = .none,
    .dstop = .none,
    .path_prev = .none,
    .path_acc = .none,
    .select = .none,
    .anew = .none,
    .fload = .none,
    .iload = .none,
    .store = .none,
    .call = .none,
    .arg = .none,
    .probe = .none,
    .alloc = .none,
    .load = .none,
    .assign = .none,
    .block = .none,
    .br = .none,
    .cond_br = .none,
    .loop = .none,
    .repeat = .none,
    .ret = .none,
});

/// `t` over constant operands, as the old MIR's `opcode.fold` computes
/// it; null when it has no value there (it is then left to run time).
pub fn tag(t: Air.Inst.Tag, args: []const fold.Const) ?fold.Const {
    for (args) |a| if (a == .str) return null;
    return switch (rows.get(t)) {
        .none => null,
        .to_real => .{ .real = args[0].asReal() },
        .to_int => .{ .int = std.math.lossyCast(i64, @round(args[0].asReal())) },
        .unary => |k| wrapped(k.wrap, fold.unary(k.f, as(k.int, args[0]))),
        .binary => |k| fold.binary(k.f, as(k.int, args[0]), as(k.int, args[1]), null),
        .math => |k| blk: {
            var buf: [fold.MathFn.arity_max]fold.Const = undefined;
            for (args, buf[0..args.len]) |a, *o| o.* = as(k.int, a);
            break :blk wrapped(k.wrap, fold.math(k.f, buf[0..args.len]));
        },
    };
}

// ---- private ----

fn as(int: bool, c: fold.Const) fold.Const {
    if (!int) return .{ .real = c.asReal() };
    return .{
        .int = switch (c) {
            .int => |i| i,
            .real => |r| std.math.lossyCast(i64, @round(r)),
            .str => unreachable, // `tag` returned for a string
        },
    };
}

fn wrapped(wrap: bool, r: ?fold.Const) ?fold.Const {
    const c = r orelse return null;
    return if (wrap and c == .int) .{ .int = fold.wrap32(c.int) } else c;
}
