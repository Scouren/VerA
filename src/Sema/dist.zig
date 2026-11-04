//! §9.13 distributions in a §6.4.1 paramset statement, folded at
//! elaboration (the old `elab/paramset_dist.zig`): a paramset statement
//! gives a module parameter its value, a parameter is fixed before the
//! design runs, and §9.13.2 "The system functions shall always return the
//! same value given the same seed", so a call whose seed and parameters are
//! constants has one value, drawn here with the kernels every device embeds
//! (`rng_kernels`). The statement is the one scope a `type_string` is legal
//! in (§9.13.2 "shall only be used in calls to a distribution function from
//! within a paramset"): "global" and "instance" select the same draw in the
//! one trial VerA compiles, anything else is E0816, as are a parameter
//! §9.13.2 requires positive that is not, a stage count the reference
//! algorithm cannot take, a start not below its end, and an integer draw no
//! signed 32-bit integer holds. In the analog context (`lower`) the same
//! rules judge a call's operands where they fold.
//! Cites: VAMS-2023 §4.2.1.1, §6.4.1, §9.13.1, §9.13.2, Table 9-10.
//!
//! Contents:
//! - `pub fn fold(s: *Sema, env: *eval.Env, file: Zcu.File.Index, value: Vir.Body) Allocator.Error!?InternPool.Index`
//! - `pub fn lower(s: *Sema, b: *Block, tag: vams.SysFn.Tag, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Sema.Value`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const rng = @import("kernels").rng_kernels;
const Air = @import("air");
const Sema = @import("../Sema.zig");
const expr = @import("expr.zig");
const Zcu = @import("../Zcu.zig");
const eval = @import("eval.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Block = Sema.Block;

/// One row of Table 9-10 past `$random` (whose Syntax 9-8 production has
/// no `type_string`): the kernel, the parameters after the seed, and the
/// §9.13.2 argument rules.
const Dist = struct {
    name: []const u8,
    kernel: Kernel,
    nparam: u8,
    integer: bool,
    /// Bit i: parameter i "shall be greater than zero".
    positive: u8 = 0,
    /// The first parameter is a count (df, stages) of the reference algorithm.
    count: bool = false,
    /// "The start value shall be smaller than the end value."
    ordered: bool = false,
};

const Kernel = enum { rand, i_uniform, uniform, normal, exponential, poisson, chi_square, t, erlang };

const dists = [_]Dist{
    .{ .name = "$arandom", .kernel = .rand, .nparam = 0, .integer = true },
    .{ .name = "$dist_uniform", .kernel = .i_uniform, .nparam = 2, .integer = true, .ordered = true },
    .{ .name = "$dist_normal", .kernel = .normal, .nparam = 2, .integer = true },
    .{ .name = "$dist_exponential", .kernel = .exponential, .nparam = 1, .integer = true, .positive = 0b01 },
    .{ .name = "$dist_poisson", .kernel = .poisson, .nparam = 1, .integer = true, .positive = 0b01 },
    .{ .name = "$dist_chi_square", .kernel = .chi_square, .nparam = 1, .integer = true, .positive = 0b01, .count = true },
    .{ .name = "$dist_t", .kernel = .t, .nparam = 1, .integer = true, .positive = 0b01, .count = true },
    .{ .name = "$dist_erlang", .kernel = .erlang, .nparam = 2, .integer = true, .positive = 0b11, .count = true },
    .{ .name = "$rdist_uniform", .kernel = .uniform, .nparam = 2, .integer = false, .ordered = true },
    .{ .name = "$rdist_normal", .kernel = .normal, .nparam = 2, .integer = false },
    .{ .name = "$rdist_exponential", .kernel = .exponential, .nparam = 1, .integer = false, .positive = 0b01 },
    .{ .name = "$rdist_poisson", .kernel = .poisson, .nparam = 1, .integer = false, .positive = 0b01 },
    .{ .name = "$rdist_chi_square", .kernel = .chi_square, .nparam = 1, .integer = false, .positive = 0b01, .count = true },
    .{ .name = "$rdist_t", .kernel = .t, .nparam = 1, .integer = false, .positive = 0b01, .count = true },
    .{ .name = "$rdist_erlang", .kernel = .erlang, .nparam = 2, .integer = false, .positive = 0b11, .count = true },
};

/// The value of a paramset statement's right-hand side `value` when it is a
/// Table 9-10 distribution call: its draw, or `undef` when an argument does
/// not fold or breaks a rule (each break reported as E0816 in `file`). Null
/// when `value` is anything else, which the caller folds as usual.
pub fn fold(s: *Sema, env: *eval.Env, file: Zcu.File.Index, value: Vir.Body) Allocator.Error!?InternPool.Index {
    const vir = env.vir;
    const insts = vir.body(value);
    if (insts.len == 0) return null;
    const call_inst = insts[insts.len - 1];
    const tags = vir.instructions.items(.tag);
    if (tags[@backingInt(call_inst)] != .call_sys) return null;
    const call = vir.extraData(Inst.SysCall, vir.instructions.items(.data)[@backingInt(call_inst)].pl_node.payload_index);
    const name = vir.string(call.name);
    const d = for (&dists) |*d| {
        if (std.mem.eql(u8, d.name, name)) break d;
    } else return null;
    assert(d.nparam <= 2);
    var args = vir.list(Inst.Ref, call.args);
    var bad = false;
    if (args.len != 0) if (args[args.len - 1].toIndex()) |last| if (tags[@backingInt(last)] == .str) {
        const ts = (try env.ref(args[args.len - 1])).?.str;
        if (!std.mem.eql(u8, ts, "global") and !std.mem.eql(u8, ts, "instance")) {
            try s.fail(.E0816, file, last.toRef(), "`{s}`'s `type_string` shall be \"global\" or \"instance\", got \"{s}\"", .{ name, ts });
            bad = true;
        }
        args = args[0 .. args.len - 1];
    };
    if (bad or args.len != @as(usize, d.nparam) + 1) return .undef;
    // Syntax 9-8's seed, `[ sign ] decimal_number`: a real one is lowering's
    // E0816 ("the seed argument shall be an integer") and declines the fold.
    const seed = literalSeed(vir, args[0]) orelse return .undef;
    var p = [2]f64{ 0, 0 };
    for (args[1..], 0..) |arg, i| {
        p[i] = ((try env.ref(arg)) orelse return .undef).asReal();
        const src = arg.toIndex().?.toRef();
        if (d.positive & (@as(u8, 1) << @intCast(i)) != 0 and !(p[i] > 0)) {
            try s.fail(.E0816, file, src, "`{s}`'s parameter {d} shall be greater than zero, got {d}", .{ name, i + 1, p[i] });
            bad = true;
        }
        if (d.count and i == 0 and p[i] > 0 and (!(p[i] <= 2147483647.0) or p[i] != @trunc(p[i]))) {
            try s.fail(.E0816, file, src, "`{s}`'s fractional or out-of-range count is unsupported; the reference count domain is 1..2147483647", .{name});
            bad = true;
        }
    }
    if (d.ordered and !d.integer and !(p[0] < p[1])) {
        try s.fail(.E0816, file, args[1].toIndex().?.toRef(), "the start value shall be smaller than the end value, got {d} and {d}", .{ p[0], p[1] });
        bad = true;
    }
    if (bad) return .undef;
    const v: f64 = switch (d.kernel) {
        .rand => rng.zRngRand(seed),
        .i_uniform => rng.zRngIUniform(seed, p[0], p[1]),
        .uniform => rng.zRngUniform(seed, p[0], p[1]),
        .normal => rng.zRngNormal(seed, p[0], p[1]),
        .exponential => rng.zRngExponential(seed, p[0]),
        .poisson => rng.zRngPoisson(seed, p[0]),
        .chi_square => rng.zRngChiSquare(seed, p[0]),
        .t => rng.zRngT(seed, p[0]),
        .erlang => rng.zRngErlang(seed, p[0], p[1]),
    };
    if (!d.integer) return try env.intern(.{ .real = v });
    // §9.13.2 "$dist_ ... return integer values": §4.2.1.1's rounding.
    if (!std.math.isFinite(v) or @round(v) < -2147483648.0 or @round(v) > 2147483647.0) {
        try s.fail(.E0816, file, call_inst.toRef(), "`{s}`'s reference result cannot be represented as a signed 32-bit integer", .{name});
        return .undef;
    }
    return try env.intern(.{ .int = @intFromFloat(@round(v)) });
}

/// A Table 9-10 call `tag` in the analog context (the old
/// `analog/random.zig`'s rules): a `call` of the tag over `args`, after
/// §9.13.1/§9.13.2's static rules, each E0816: no `type_string` outside a
/// paramset, the arity the row allows, an integer seed; and, where the
/// call runs unconditionally (§4.2.3 suppresses errors in a skipped
/// operand), the parameter rules over operands that fold.
pub fn lower(s: *Sema, b: *Block, tag: vams.SysFn.Tag, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Sema.Value {
    const vir = b.unit.vir;
    const file = b.unit.file;
    const name = @tagName(tag);
    // §9.13.1's `$random` takes `$arandom`'s row: no parameters, an optional seed.
    const key = if (tag == .@"$random") "$arandom" else name;
    const d = for (&dists) |*d| {
        if (std.mem.eql(u8, d.name, key)) break d;
    } else unreachable; // every `.random` tag has a row
    var given: std.ArrayList(Inst.Ref) = .empty;
    for (args) |a| if (a != .none) try given.append(s.arena, a);
    if (given.getLastOrNull()) |last| if (last.toIndex()) |li| if (vir.instructions.items(.tag)[@backingInt(li)] == .str) {
        try s.fail(.E0816, file, last, "`{s}`'s `type_string` argument is only meaningful within a paramset (§6.4)", .{name});
        return expr.poison;
    };
    const want: usize = @as(usize, d.nparam) + 1;
    const min: usize = if (d.nparam == 0) 0 else want;
    if (given.items.len < min or given.items.len > want) {
        try s.fail(.E0816, file, src, "`{s}` takes {s}{d} argument{s}, got {d}", .{ name, if (min < want) "at most " else "", want, if (want == 1) "" else "s", given.items.len });
        return expr.poison;
    }
    return lowerCall(s, b, tag, d, args);
}

// ---- private ----

/// The `call` of `tag` over `args` (an empty slot a real zero), each
/// operand judged by `d`'s rules as it is lowered.
fn lowerCall(s: *Sema, b: *Block, tag: vams.SysFn.Tag, d: *const Dist, args: []const Inst.Ref) Allocator.Error!Sema.Value {
    const file = b.unit.file;
    const name = @tagName(tag);
    const eager = b.conditional == 0 and b.function == null;
    const refs = try s.arena.alloc(Air.Inst.Ref, args.len);
    var p: [2]?f64 = .{ null, null };
    var at: [2]Inst.Ref = .{ .none, .none };
    var k: usize = 0; // the written operands so far
    for (args, refs) |a, *r| {
        if (a == .none) {
            r.* = .fromIntern(.zero_real);
            continue;
        }
        defer k += 1;
        const v = try expr.lower(s, b, a);
        r.* = v.ref;
        if (k == 0) {
            // §9.13.2 "the seed argument shall be an integer".
            if (v.ty != .integer) {
                try s.fail(.E0816, file, a, "the seed argument shall be an integer, and this one is {s}", .{@tagName(v.ty)});
                return expr.poison;
            }
            continue;
        }
        const i = k - 1;
        const c = expr.constOf(s, v.ref) orelse continue;
        if (!eager or c == .str or i >= 2) continue;
        p[i] = c.asReal();
        at[i] = a;
        if (d.positive & (@as(u8, 1) << @intCast(i)) != 0 and !(p[i].? > 0))
            try s.fail(.E0816, file, a, "`{s}`'s parameter {d} shall be greater than zero, got {d}", .{ name, i + 1, p[i].? });
        if (d.count and i == 0 and p[i].? > 0 and (!(p[i].? <= 2147483647.0) or p[i].? != @trunc(p[i].?)))
            try s.fail(.E0816, file, a, "`{s}`'s fractional or out-of-range count is unsupported; the reference count domain is 1..2147483647", .{name});
    }
    if (d.ordered and !d.integer) if (p[0]) |lo| if (p[1]) |hi| if (!(lo < hi))
        try s.fail(.E0816, file, at[0], "the start value shall be smaller than the end value, got {d} and {d}", .{ lo, hi });
    const ty: Sema.Ty = if (d.integer) .integer else .real;
    return .{ .ref = try expr.call(s, b, @backingInt(tag), ty, refs), .ty = ty };
}

/// `[ sign ] decimal_number`: an integer literal under any `+`/`-` signs.
fn literalSeed(vir: *const Vir, r: Inst.Ref) ?i64 {
    var at = r.toIndex() orelse return null;
    var negative = false;
    // Bounded by the instruction count: each step moves to an operand.
    for (0..vir.instructions.len) |_| {
        const data = vir.instructions.items(.data)[@backingInt(at)];
        switch (vir.instructions.items(.tag)[@backingInt(at)]) {
            .int => {
                const v = std.math.cast(i64, data.int) orelse return null;
                return if (negative) -v else v;
            },
            .neg, .pos => |t| {
                negative = negative != (t == .neg);
                at = data.un_node.operand.toIndex() orelse return null;
            },
            else => return null, // else: not Syntax 9-8's literal seed
        }
    }
    return null;
}
