//! A contribution's right-hand side split for §5.6.1.2 (the old
//! `analog/reactive.zig`): each term of a sum is resistive, or a linear
//! `ddt` term whose argument is a charge (one charge site each, its factor a
//! constant or, when the solve moves it, the path form `acc(c·ΔB) + c·ΔB`).
//! Cites: VAMS-2023 §4.5.3, §5.6.1.2.
//!
//! Contents:
//! - `pub const Split = struct`, `pub const Site = struct`
//! - `pub fn split(s: *Sema, b: *Block, r: Inst.Ref, negate: bool, out: *Split) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const expr = @import("expr.zig");
const Inst = vams.Vir.Inst;
const Block = Sema.Block;
const Ref = Air.Inst.Ref;

/// A `<+` right-hand side split into its resistive and reactive sums and
/// the charge sites of its `ddt` terms.
pub const Split = struct {
    resist: ?Ref = null,
    react: ?Ref = null,
    sites: std.ArrayList(Site) = .empty,
};
/// One charge site of a split: its charge and its sign in the sum.
pub const Site = struct { charge: Ref, negate: bool };

/// One linear `ddt` term: its argument `b` and the factor on it.
const Reactive = struct { b: Ref, coeff: ?Ref = null, coeff_nonconst: bool = false };

/// The old `reactive.splitTerm`: a sum's terms, each a linear `ddt` term
/// (into `react`, with a charge site) or a resistive one.
pub fn split(s: *Sema, b: *Block, r: Inst.Ref, negate: bool, out: *Split) Allocator.Error!void {
    const i = r.toIndex() orelse return;
    const vir = b.unit.vir;
    switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .add, .sub => |tag| {
            const bin = decl.payloadOf(vir, Inst.Bin, i);
            try split(s, b, bin.lhs, negate, out);
            return split(s, b, bin.rhs, if (tag == .sub) !negate else negate, out);
        },
        .pos => return split(s, b, vir.instructions.items(.data)[@backingInt(i)].un_node.operand, negate, out),
        .neg => return split(s, b, vir.instructions.items(.data)[@backingInt(i)].un_node.operand, !negate, out),
        else => {}, // else: one term
    }
    if (linearDdt(b.unit, r, 0)) {
        const t = (try term(s, b, r)) orelse return;
        const q = try finishReactive(s, b, t);
        try accumulate(s, b, &out.react, q, negate);
        try out.sites.append(s.arena, .{ .charge = q, .negate = negate });
        return;
    }
    const v = try expr.coerce(s, b, try expr.lower(s, b, r), .real);
    try accumulate(s, b, &out.resist, v, negate);
}

// ---- private ----

fn accumulate(s: *Sema, b: *Block, slot: *?Ref, v: Ref, negate: bool) Allocator.Error!void {
    slot.* = if (slot.*) |old|
        try expr.binOp(s, b, if (negate) .fsub else .fadd, old, v)
    else if (negate) try expr.unOp(s, b, .fneg, v) else v;
}

fn isDdt(unit: *const Sema.Unit, i: Inst.Index) bool {
    const vir = unit.vir;
    if (vir.instructions.items(.tag)[@backingInt(i)] != .call_sys) return false;
    return std.mem.eql(u8, vir.string(decl.payloadOf(vir, Inst.SysCall, i).name), "ddt");
}

fn containsDdt(unit: *const Sema.Unit, r: Inst.Ref, depth: u32) bool {
    const i = r.toIndex() orelse return false;
    if (depth > expr.depth_max) return false;
    if (isDdt(unit, i)) return true;
    const vir = unit.vir;
    return switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .pos, .neg, .not, .bit_not => containsDdt(unit, vir.instructions.items(.data)[@backingInt(i)].un_node.operand, depth + 1),
        .add, .sub, .mul, .div, .mod, .pow, .lt, .gt, .lte, .gte, .eq, .neq, .bool_and, .bool_or => blk: {
            const bin = decl.payloadOf(vir, Inst.Bin, i);
            break :blk containsDdt(unit, bin.lhs, depth + 1) or containsDdt(unit, bin.rhs, depth + 1);
        },
        .ternary => blk: {
            const t = decl.payloadOf(vir, Inst.Triple, i);
            break :blk containsDdt(unit, t.a, depth + 1) or containsDdt(unit, t.b, depth + 1) or containsDdt(unit, t.c, depth + 1);
        },
        .call_sys => for (vir.list(Inst.Ref, decl.payloadOf(vir, Inst.SysCall, i).args)) |a| {
            if (containsDdt(unit, a, depth + 1)) break true;
        } else false,
        else => false, // else: a leaf, or a construct whose ddt `reactive` never reaches
    };
}

/// The old `reactive.linearDdt`: a `ddt` on a linear spine (signs, a
/// factor, a divisor, sums of such).
fn linearDdt(unit: *const Sema.Unit, r: Inst.Ref, depth: u32) bool {
    const i = r.toIndex() orelse return false;
    if (depth > expr.depth_max) return false;
    if (isDdt(unit, i)) return true;
    const vir = unit.vir;
    return switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .pos, .neg => linearDdt(unit, vir.instructions.items(.data)[@backingInt(i)].un_node.operand, depth + 1),
        .mul => blk: {
            const bin = decl.payloadOf(vir, Inst.Bin, i);
            break :blk if (containsDdt(unit, bin.lhs, depth + 1)) !containsDdt(unit, bin.rhs, depth + 1) and linearDdt(unit, bin.lhs, depth + 1) else linearDdt(unit, bin.rhs, depth + 1);
        },
        .div => blk: {
            const bin = decl.payloadOf(vir, Inst.Bin, i);
            break :blk !containsDdt(unit, bin.rhs, depth + 1) and linearDdt(unit, bin.lhs, depth + 1);
        },
        .add, .sub => blk: {
            const bin = decl.payloadOf(vir, Inst.Bin, i);
            break :blk linearDdt(unit, bin.lhs, depth + 1) and linearDdt(unit, bin.rhs, depth + 1);
        },
        else => false, // else: no other node keeps a ddt on a linear spine
    };
}

/// The old `reactive.lowerReactive`.
fn term(s: *Sema, b: *Block, r: Inst.Ref) Allocator.Error!?Reactive {
    const i = r.toIndex() orelse return null;
    const vir = b.unit.vir;
    if (isDdt(b.unit, i)) {
        if (!try @import("op.zig").checkPlace(s, b, .ddt, r)) return null;
        const args = vir.list(Inst.Ref, decl.payloadOf(vir, Inst.SysCall, i).args);
        if (args.len == 0 or args[0] == .none) {
            try s.fail(.E0502, b.unit.file, r, "", .{});
            return null;
        }
        return .{ .b = try expr.coerce(s, b, try expr.lower(s, b, args[0]), .real) };
    }
    switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .pos => return term(s, b, vir.instructions.items(.data)[@backingInt(i)].un_node.operand),
        .neg => {
            var t = (try term(s, b, vir.instructions.items(.data)[@backingInt(i)].un_node.operand)) orelse return null;
            t.coeff = if (t.coeff) |old| try expr.unOp(s, b, .fneg, old) else .fromIntern(.neg_one_real);
            return t;
        },
        .mul => {
            const bin = decl.payloadOf(vir, Inst.Bin, i);
            if (containsDdt(b.unit, bin.lhs, 0)) {
                var t = (try term(s, b, bin.lhs)) orelse return null;
                try mulCoeff(s, b, &t, try expr.coerce(s, b, try expr.lower(s, b, bin.rhs), .real), .fmul);
                return t;
            }
            const c = try expr.coerce(s, b, try expr.lower(s, b, bin.lhs), .real);
            var t = (try term(s, b, bin.rhs)) orelse return null;
            try mulCoeff(s, b, &t, c, .fmul);
            return t;
        },
        .div => {
            const bin = decl.payloadOf(vir, Inst.Bin, i);
            var t = (try term(s, b, bin.lhs)) orelse return null;
            try mulCoeff(s, b, &t, try expr.coerce(s, b, try expr.lower(s, b, bin.rhs), .real), .fdiv);
            return t;
        },
        else => {
            try s.fail(.E0512, b.unit.file, r, "a reactive term of this shape is not lowered by Sema yet", .{});
            return null;
        },
    }
}

fn mulCoeff(s: *Sema, b: *Block, t: *Reactive, c: Ref, tag: Air.Inst.Tag) Allocator.Error!void {
    t.coeff = if (t.coeff) |old|
        try expr.binOp(s, b, tag, old, c)
    else if (tag == .fdiv)
        try expr.binOp(s, b, .fdiv, .fromIntern(.one_real), c)
    else
        c;
    t.coeff_nonconst = t.coeff_nonconst or !coeffIsConst(s, c);
}

/// A factor a solve cannot change: a constant or a parameter.
fn coeffIsConst(s: *const Sema, c: Ref) bool {
    if (c.toInterned() != null) return true;
    const i = c.toIndex().?;
    return s.air.instructions.items(.tag)[@backingInt(i)] == .arg;
}

/// The charge `q` of a linear `ddt` term: `B` alone, `c·B` for a constant
/// factor, and the §5.6.1.2 path form `acc(c·ΔB) + c·ΔB` otherwise.
fn finishReactive(s: *Sema, b: *Block, t: Reactive) Allocator.Error!Ref {
    const c = t.coeff orelse return t.b;
    if (!t.coeff_nonconst) return expr.binOp(s, b, .fmul, c, t.b);
    const pb = try expr.unOp(s, b, .path_prev, t.b);
    const d = try expr.binOp(s, b, .fmul, c, try expr.binOp(s, b, .fsub, t.b, pb));
    return expr.binOp(s, b, .fadd, try expr.unOp(s, b, .path_acc, d), d);
}
