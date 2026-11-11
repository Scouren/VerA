//! §4.2.9 integer comparisons with an unsigned operand (the old
//! `analog/constfold.zig`'s `integerSourceSigned` and
//! `constfold_size.unsignedCompare`): a comparison's two integer operands
//! in; each extended so the signed compare on the 64-bit carrier orders
//! them as §4.2.9's unsigned comparison out. An operand's signedness
//! follows IEEE 1364-2005 §5.5.1; its bit length is a literal's size, a
//! name's declared width, or §3.2's 32 bits past any operator.
//!
//! The same width walk, run with no 32-bit floor on an operator's own
//! result, is IEEE 1364-2005 §5.4.1's self-determined width: `$clog2`'s one
//! argument (`clog2Width`), the old `constfold_size.clog2Width`/
//! `expressionWidth(..., self_determined = true)`.
//! Cites: VAMS-2023 §2.6.1, §3.2, §4.2.9, §4.2.10, §4.2.11; IEEE 1364-2005
//! §5.1.11, §5.4.1, §5.5.1, §17.11.1.
//!
//! Contents:
//! - `pub fn compareOperands(s: *Sema, b: *Block, vir: *const Vir, l: Inst.Ref, r: Inst.Ref, x: Air.Inst.Ref, y: Air.Inst.Ref) Allocator.Error![2]Air.Inst.Ref`
//! - `pub fn compareConsts(vir: *const Vir, l: Inst.Ref, r: Inst.Ref, x: i64, y: i64) [2]i64`
//! - `pub fn signed(vir: *const Vir, r: Inst.Ref) ?bool`
//! - `pub fn clog2Width(vir: *const Vir, r: Inst.Ref) ?u32`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const expr = @import("expr.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Block = Sema.Block;
const Ref = Air.Inst.Ref;

/// The deepest chain of operators and parameter defaults followed; past it
/// there is no evidence (null), as the old walk's `name_depth_max`.
const depth_max: u32 = 32;

/// The mask-and-flip plan `compareOperands` and `compareConsts` share: a
/// width to mask each operand to (null: no mask, the carrier stands), and
/// whether to flip bit 63 so the signed compare orders them as unsigned.
/// Null when both operands are signed (or unknown): no change needed.
const Plan = struct { widths: [2]?u32, flip: bool };

/// `x` and `y`, the integer values of operands `l` and `r` of a
/// comparison, as the signed compare must see them: unchanged when both
/// operands are signed (or unknown), else each zero-extended from its own
/// width, and both with bit 63 flipped when either is 64 bits or wider.
pub fn compareOperands(s: *Sema, b: *Block, vir: *const Vir, l: Inst.Ref, r: Inst.Ref, x: Ref, y: Ref) Allocator.Error![2]Ref {
    assert(l != .none);
    assert(r != .none);
    const p = plan(vir, l, r) orelse return .{ x, y };
    var out = [2]Ref{ x, y };
    for (&out, p.widths) |*v, w| {
        if (w) |n| if (n < 64) {
            v.* = try expr.binOp(s, b, .bitand, v.*, .fromIntern(try decl.intern(s, .{ .int = (@as(i64, 1) << @intCast(n)) - 1 })));
        };
        if (p.flip) v.* = try expr.binOp(s, b, .bitxor, v.*, .fromIntern(try decl.intern(s, .{ .int = std.math.minInt(i64) })));
    }
    return out;
}

/// `compareOperands`, folded over plain values instead of building Air: the
/// comptime evaluator's §4.2.9 fix (I1), the same mask-and-flip plan.
pub fn compareConsts(vir: *const Vir, l: Inst.Ref, r: Inst.Ref, x: i64, y: i64) [2]i64 {
    const p = plan(vir, l, r) orelse return .{ x, y };
    var out = [2]i64{ x, y };
    for (&out, p.widths) |*v, w| {
        if (w) |n| {
            if (n < 64) v.* = @bitCast(@as(u64, @bitCast(v.*)) & ((@as(u64, 1) << @intCast(n)) - 1));
        }
        if (p.flip) v.* ^= std.math.minInt(i64);
    }
    return out;
}

/// §5.5.1 whether integer expression `r` is signed; null with no evidence
/// (a real, a host-overridable untyped parameter, a call). Shared by
/// `compareOperands`/`compareConsts` (unsigned when either operand is not)
/// and IEEE 1364-2005 §5.1.12's `>>>` (I5: the carrier's sign bit fills only
/// when the left operand is signed).
pub fn signed(vir: *const Vir, r: Inst.Ref) ?bool {
    return signedOf(vir, r, 0);
}

/// IEEE 1364-2005 §5.4.1 / §17.11.1: `$clog2`'s one argument is
/// self-determined, so an arithmetic or bitwise operator's own width is the
/// widest operand's (never floored to §3.2's 32 bits, unlike
/// `compareOperands`'s operands) (D1-G).
pub fn clog2Width(vir: *const Vir, r: Inst.Ref) ?u32 {
    return widthOf(vir, r, 0, true);
}

// ---- private ----

fn plan(vir: *const Vir, l: Inst.Ref, r: Inst.Ref) ?Plan {
    if ((signedOf(vir, l, 0) orelse true) and (signedOf(vir, r, 0) orelse true)) return null;
    const widths = [2]?u32{ widthOf(vir, l, 0, false), widthOf(vir, r, 0, false) };
    var flip = false;
    for (widths) |w| flip = flip or (w orelse 0) >= 64;
    return .{ .widths = widths, .flip = flip };
}

fn signedOf(vir: *const Vir, r: Inst.Ref, depth: u32) ?bool {
    if (depth > depth_max) return null;
    const i = r.toIndex() orelse return null;
    const data = vir.instructions.items(.data)[@backingInt(i)];
    return switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .int => true,
        .big_int => decl.payloadOf(vir, Inst.BigInt, i).flags.signed,
        .decl_ref => nameSigned(vir, decl.canonical(vir, data.decl_tok.decl), depth),
        .pos, .neg, .bit_not => signedOf(vir, data.un_node.operand, depth + 1),
        // §4.2.11: the right operand "has no effect on the signedness".
        .shl, .shr, .ashl, .ashr, .pow => signedOf(vir, decl.payloadOf(vir, Inst.Bin, i).lhs, depth + 1),
        // §5.5.1 "If any operand is unsigned, the result is unsigned".
        .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => both(vir, decl.payloadOf(vir, Inst.Bin, i), depth),
        // §5.5.1 "Comparison results (1, 0) are unsigned".
        .lt, .gt, .lte, .gte, .eq, .neq, .case_eq, .case_neq => false,
        .ternary => blk: {
            const t = decl.payloadOf(vir, Inst.Triple, i);
            break :blk both(vir, .{ .lhs = t.b, .rhs = t.c }, depth);
        },
        .elem => signedOf(vir, decl.payloadOf(vir, Inst.Bin, i).lhs, depth + 1),
        else => null, // else: no declared integer provenance
    };
}

fn both(vir: *const Vir, x: Inst.Bin, depth: u32) ?bool {
    const a = signedOf(vir, x.lhs, depth + 1) orelse return null;
    const c = signedOf(vir, x.rhs, depth + 1) orelse return null;
    return a and c;
}

/// A name's signedness: an `integer` is signed; an untyped local
/// parameter has its default's; anything else gives no evidence.
fn nameSigned(vir: *const Vir, d: Inst.Index, depth: u32) ?bool {
    switch (vir.instructions.items(.tag)[@backingInt(d)]) {
        .variable => return if (decl.payloadOf(vir, Inst.Variable, d).flags.storage == .integer) true else null,
        .io => return if (decl.payloadOf(vir, Inst.Io, d).flags.storage == .integer) true else null,
        .param => {
            const p = decl.payloadOf(vir, Inst.Param, d);
            if (p.flags.storage == .integer) return true;
            const value = untypedLocalDefault(vir, p) orelse return null;
            return signedOf(vir, value, depth + 1);
        },
        else => return null, // else: no declared integer
    }
}

/// The default of an untyped, unranged local parameter, whose type and
/// width are its value's (IEEE 1364-2005 §12.2); null for any other.
fn untypedLocalDefault(vir: *const Vir, p: Inst.Param) ?Inst.Ref {
    if (!p.flags.local and p.flags.kind != .localparam) return null;
    return untypedDefault(vir, p);
}

/// `untypedLocalDefault` without the local-only restriction, for
/// `clog2Width`'s self-determined walk (IEEE 1364-2005 §12.2: an untyped
/// parameter's type and size are its default's, whether or not it is
/// overridable).
fn untypedDefault(vir: *const Vir, p: Inst.Param) ?Inst.Ref {
    if (p.flags.storage != .none or p.range.len != 0) return null;
    const body = vir.body(p.value);
    if (body.len == 0) return null;
    return body[body.len - 1].toRef();
}

/// The old `operandWidth`/`clog2Width`'s `expressionWidth`: the widest
/// operand the size passes through, at least §3.2's 32 bits once an
/// operator passed it on (`self_determined = false`, `compareOperands`'s
/// use), or exactly as written (`self_determined = true`, `clog2Width`'s:
/// IEEE 1364-2005 §5.4.1). Null when a name's width is unknown.
fn widthOf(vir: *const Vir, root: Inst.Ref, depth0: u32, comptime self_determined: bool) ?u32 {
    var stack: [64]struct { r: Inst.Ref, depth: u32 } = undefined;
    var n: usize = 1;
    stack[0] = .{ .r = root, .depth = depth0 };
    var widest: u32 = 0;
    while (n != 0) {
        n -= 1;
        const at = stack[n];
        if (at.depth > depth_max) return null;
        const i = at.r.toIndex() orelse return null;
        const data = vir.instructions.items(.data)[@backingInt(i)];
        var push: [2]Inst.Ref = .{ .none, .none };
        const w: u32 = switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            .int => if (std.math.cast(i32, data.int) != null or std.math.cast(u32, data.int) != null) 32 else 64,
            .big_int => size: {
                const x = decl.payloadOf(vir, Inst.BigInt, i);
                break :size if (x.size != 0) x.size else 32;
            },
            .decl_ref => nameWidth(vir, decl.canonical(vir, data.decl_tok.decl), at.depth, self_determined) orelse return null,
            .pos, .neg, .bit_not => blk: {
                push[0] = data.un_node.operand;
                break :blk 0;
            },
            // §4.2.10 a reduction, and §4.2.8 `!`, are self-determined
            // one-bit results; outside that context every integer form not
            // named below is §3.2's 32-bit integer.
            .not, .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor => if (self_determined) 1 else 32,
            .bit_and, .bit_or, .bit_xor, .bit_xnor => blk: {
                const x = decl.payloadOf(vir, Inst.Bin, i);
                push = .{ x.lhs, x.rhs };
                break :blk 0;
            },
            // §5.4.1: non-self-determined, these widen to §3.2's 32 bits;
            // self-determined, they are the widest of their operands'.
            .add, .sub, .mul, .div, .mod => if (self_determined) blk: {
                const x = decl.payloadOf(vir, Inst.Bin, i);
                push = .{ x.lhs, x.rhs };
                break :blk 0;
            } else 32,
            // §4.2.11: the right operand has no effect on the width either.
            .pow, .shl, .shr, .ashl, .ashr => if (self_determined) blk: {
                push[0] = decl.payloadOf(vir, Inst.Bin, i).lhs;
                break :blk 0;
            } else 32,
            .lt, .gt, .lte, .gte, .eq, .neq, .case_eq, .case_neq, .bool_and, .bool_or => if (self_determined) 1 else 32,
            .ternary => blk: {
                const t = decl.payloadOf(vir, Inst.Triple, i);
                push = .{ t.b, t.c };
                break :blk 0;
            },
            // §9.11 `$realtobits` returns the double's 64-bit pattern.
            .call_sys => if (std.mem.eql(u8, vir.string(decl.payloadOf(vir, Inst.SysCall, i).name), "$realtobits")) 64 else 32,
            else => 32, // else: every other integer form is §3.2's 32-bit integer
        };
        widest = @max(widest, if (i == root.toIndex().?) w else widthFloor(w, self_determined));
        for (push) |p| if (p != .none) {
            if (n == stack.len) return null;
            stack[n] = .{ .r = p, .depth = at.depth + 1 };
            n += 1;
        };
    }
    return widest;
}

fn widthFloor(w: u32, comptime self_determined: bool) u32 {
    const out = if (self_determined) w else @max(w, 32);
    assert(out >= w);
    return out;
}

/// A name's bit length: 32 for an `integer`, an untyped local parameter's
/// default's (any untyped parameter's, self-determined: IEEE 1364-2005
/// §12.2); null when nothing states it.
fn nameWidth(vir: *const Vir, d: Inst.Index, depth: u32, comptime self_determined: bool) ?u32 {
    switch (vir.instructions.items(.tag)[@backingInt(d)]) {
        .variable => return if (decl.payloadOf(vir, Inst.Variable, d).flags.storage == .integer) 32 else null,
        .io => return if (decl.payloadOf(vir, Inst.Io, d).flags.storage == .integer) 32 else null,
        .param => {
            const p = decl.payloadOf(vir, Inst.Param, d);
            if (p.flags.storage == .integer) return 32;
            if (depth > depth_max) return null;
            const default = if (self_determined) untypedDefault(vir, p) else untypedLocalDefault(vir, p);
            return widthOf(vir, default orelse return null, depth + 1, self_determined);
        },
        else => return null, // else: no declared integer
    }
}
