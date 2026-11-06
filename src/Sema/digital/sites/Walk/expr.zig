//! The walk's expressions and lvalues, as the old emitter's `shape`,
//! `expr` and `lvalue` refused them (src/codegen/digital/rtlil_expr.zig),
//! and whether the old 4-state fold takes a constant.
//! Cites: IEEE 1364-2005 §5.1, §5.2.1, §5.4.1, A.8.5.
//!
//! Contents:
//! - `pub fn lvalue`
//! - `pub fn expr`
//! - `pub fn select`
//! - `pub fn lvalueBase`
//! - `pub fn known`
//! - `pub fn refName`
//! - `pub fn constant`
//! - `pub fn unsized`
//! - `pub fn paramAt`
//! - `pub fn keywordAt`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const decl = @import("../../../decl.zig");
const Walk = @import("../Walk.zig");
const sites = @import("../../sites.zig");
const Phase = sites.Phase;
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Ast = vams.Ast;
const max_depth = Walk.max_depth;
const last = Walk.last;
const forInit = Walk.forInit;
const literal = Walk.literal;
const isPull = Walk.isPull;
const isSwitch = Walk.isSwitch;

/// An A.8.5 lvalue, as the old `lvalue` refuses it; `in_proc`: a
/// process's target must be a reg.
pub fn lvalue(w: *Walk, r: Inst.Ref, in_proc: bool, depth: u32) Allocator.Error!void {
    const i = r.toIndex() orelse return;
    if (depth > max_depth) return;
    switch (w.tag(i)) {
        .concat => for (w.vir.list(Inst.Ref, w.payload(Inst.Refs, i))) |p| try w.lvalue(p, in_proc, depth + 1),
        .decl_ref, .str_ref, .elem, .slice, .slice_up, .slice_down => {
            const base = w.lvalueBase(r) orelse return w.row(w.phase, .lvalue_no_base, w.at(i), "");
            if (!w.known(base)) return w.row(w.phase, .unknown_name, w.at(i), w.refName(base));
            const c = decl.canonical(w.vir, w.data(base).decl_tok.decl);
            if (w.params.contains(c)) return w.row(w.phase, .lvalue_param, w.at(i), w.refName(base));
            if (in_proc and !w.names.get(c).?) return w.row(w.phase, .lvalue_net, w.at(i), w.refName(base));
            switch (w.tag(i)) {
                .decl_ref, .str_ref => {},
                .elem => {
                    const b = w.payload(Inst.Bin, i);
                    if (w.tag(b.lhs.toIndex().?) != .decl_ref) return w.row(w.phase, .lvalue_nested, w.at(i), "");
                    if (!w.constant(b.rhs, false, 0)) try w.row(w.phase, .lvalue_bit, w.at(i), "");
                },
                .slice => {
                    const t = w.payload(Inst.Triple, i);
                    if (w.tag(t.a.toIndex().?) != .decl_ref) return w.row(w.phase, .lvalue_nested, w.at(i), "");
                    if (!w.constant(t.b, false, 0) or !w.constant(t.c, false, 0)) try w.row(w.phase, .select_range, w.at(i), "");
                },
                else => {
                    if (w.tag(w.payload(Inst.Triple, i).a.toIndex().?) != .decl_ref) return w.row(w.phase, .lvalue_nested, w.at(i), "");
                    try w.row(w.phase, .lvalue_indexed, w.at(i), "");
                },
            }
        },
        else => try w.row(w.phase, .lvalue_other, w.at(i), ""), // else: A.8.5 admits nothing else
    }
}

/// The old `shape`/`expr` refusals of an expression, left to right.
pub fn expr(w: *Walk, r: Inst.Ref, depth: u32) Allocator.Error!void {
    const i = r.toIndex() orelse return;
    if (depth > max_depth) return;
    switch (w.tag(i)) {
        .int, .big_int => {},
        .decl_ref, .str_ref => if (!w.known(i)) try w.row(w.phase, .unknown_name, w.at(i), w.refName(i)),
        .real => try w.row(w.phase, .real_literal, w.at(i), ""),
        .str => try w.row(w.phase, .string_literal, w.at(i), ""),
        .field => try w.row(w.phase, .hierarchical, w.at(i), ""),
        .call => try w.row(w.phase, .call, w.at(i), ""),
        .call_sys => {
            const c = w.payload(Inst.SysCall, i);
            const name = w.string(c.name);
            const args = w.vir.list(Inst.Ref, c.args);
            if ((std.mem.eql(u8, name, "$signed") or std.mem.eql(u8, name, "$unsigned")) and args.len == 1) return w.expr(args[0], depth + 1);
            if (std.mem.eql(u8, name, "$clog2")) {
                if (!w.constant(r, false, 0)) try w.row(w.phase, .clog2_value, w.at(i), "");
                return;
            }
            try w.row(w.phase, .sys_call, w.at(i), name);
        },
        .pos, .neg, .not, .bit_not, .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor => try w.expr(w.data(i).un_node.operand, depth + 1),
        .add, .sub, .mul, .div, .mod, .pow, .shl, .shr, .ashl, .ashr, .lt, .gt, .lte, .gte, .eq, .neq, .case_eq, .case_neq, .bit_and, .bit_or, .bit_xor, .bit_xnor, .bool_and, .bool_or => {
            const b = w.payload(Inst.Bin, i);
            try w.expr(b.lhs, depth + 1);
            try w.expr(b.rhs, depth + 1);
        },
        .ternary => {
            const t = w.payload(Inst.Triple, i);
            try w.expr(t.a, depth + 1);
            try w.expr(t.b, depth + 1);
            try w.expr(t.c, depth + 1);
        },
        .concat => for (w.vir.list(Inst.Ref, w.payload(Inst.Refs, i))) |p| try w.expr(p, depth + 1),
        .replicate => {
            const b = w.payload(Inst.Bin, i);
            if (!w.constant(b.lhs, false, 0)) return w.row(w.phase, .replicate_count, w.at(i), "");
            try w.expr(b.rhs, depth + 1);
        },
        .elem, .slice, .slice_up, .slice_down => try w.select(i, depth),
        else => try w.row(w.phase, .other_expr, w.at(i), ""), // else: no RTLIL expression
    }
}

/// A select of a declared name (the old `shape` then `select`).
pub fn select(w: *Walk, i: Inst.Index, depth: u32) Allocator.Error!void {
    const t = w.tag(i);
    const base: Inst.Ref, const x: Inst.Ref, const y: Inst.Ref = if (t == .elem) blk: {
        const b = w.payload(Inst.Bin, i);
        break :blk .{ b.lhs, b.rhs, .none };
    } else blk: {
        const p = w.payload(Inst.Triple, i);
        break :blk .{ p.a, p.b, p.c };
    };
    if (t == .slice and (!w.constant(x, false, 0) or !w.constant(y, false, 0))) return w.row(w.phase, .select_range, w.at(i), "");
    if ((t == .slice_up or t == .slice_down) and !w.constant(y, false, 0)) return w.row(w.phase, .select_width, w.at(i), "");
    const b = base.toIndex().?;
    if (w.tag(b) != .decl_ref and w.tag(b) != .str_ref) return w.row(w.phase, .select_of_expr, w.at(i), "");
    if (!w.known(b)) return w.row(w.phase, .unknown_name, w.at(i), w.refName(b));
    if (w.params.contains(decl.canonical(w.vir, w.data(b).decl_tok.decl))) return w.row(w.phase, .select_of_param, w.at(i), "");
    if ((t == .slice_up or t == .slice_down) and !w.constant(x, false, 0)) return w.row(w.phase, .select_base, w.at(i), "");
    if (t == .elem and !w.constant(x, false, 0)) try w.expr(x, depth + 1);
}

/// The name at the bottom of a select chain, or null (a concatenation).
pub fn lvalueBase(w: *const Walk, r: Inst.Ref) ?Inst.Index {
    var i = r.toIndex() orelse return null;
    var n: u32 = 0;
    while (n < max_depth) : (n += 1) switch (w.tag(i)) {
        .decl_ref, .str_ref => return i,
        .elem => i = w.payload(Inst.Bin, i).lhs.toIndex() orelse return null,
        .slice, .slice_up, .slice_down => i = w.payload(Inst.Triple, i).a.toIndex() orelse return null,
        else => return null, // else: no name at the bottom
    };
    return null;
}

/// Whether name reference `i` names a module-level declaration.
pub fn known(w: *const Walk, i: Inst.Index) bool {
    if (w.tag(i) != .decl_ref) return false;
    return w.names.contains(decl.canonical(w.vir, w.data(i).decl_tok.decl));
}

pub fn refName(w: *const Walk, i: Inst.Index) []const u8 {
    const d = w.data(i);
    return switch (w.tag(i)) {
        .decl_ref => w.string(decl.nameOf(w.vir, d.decl_tok.decl)),
        .str_ref => w.string(d.str_tok.start),
        else => "", // else: no name
    };
}

/// Whether the old 4-state fold (`rtlil_fold.zig`) takes `r`: literals,
/// integral parameters folded so far (all of them when `seen` is not
/// the bound), operators, `$signed`, `$unsigned`, `$clog2`; `real`: an
/// assignment's right side may also be a real literal or a negated one.
pub fn constant(w: *const Walk, r: Inst.Ref, real: bool, depth: u32) bool {
    const i = r.toIndex() orelse return false;
    if (depth > max_depth) return false;
    switch (w.tag(i)) {
        .int, .big_int, .str => return true,
        .real => return real and depth == 0,
        .decl_ref => {
            const c = decl.canonical(w.vir, w.data(i).decl_tok.decl);
            if (!w.params.contains(c)) return false;
            if (w.phase == .param and !w.seen.contains(c)) return false;
            const p = w.payload(Inst.Param, c);
            if (p.flags.storage == .real or p.flags.storage == .realtime) return false;
            const v = w.vir.body(p.value);
            return v.len != 0 and !(w.tag(v[v.len - 1]) == .real and p.flags.storage == .none and p.range.len == 0);
        },
        .neg => {
            const o = w.data(i).un_node.operand;
            if (real and depth == 0) if (o.toIndex()) |oi| if (w.tag(oi) == .real) return true;
            return w.constant(o, false, depth + 1);
        },
        .pos, .not, .bit_not, .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor => return w.constant(w.data(i).un_node.operand, false, depth + 1),
        .add, .sub, .mul, .div, .mod, .pow, .shl, .shr, .ashl, .ashr, .lt, .gt, .lte, .gte, .eq, .neq, .case_eq, .case_neq, .bit_and, .bit_or, .bit_xor, .bit_xnor, .bool_and, .bool_or => {
            const b = w.payload(Inst.Bin, i);
            return w.constant(b.lhs, false, depth + 1) and w.constant(b.rhs, false, depth + 1);
        },
        .ternary => {
            const t = w.payload(Inst.Triple, i);
            return w.constant(t.a, false, depth + 1) and w.constant(t.b, false, depth + 1) and w.constant(t.c, false, depth + 1);
        },
        .concat => {
            const parts = w.vir.list(Inst.Ref, w.payload(Inst.Refs, i));
            if (parts.len == 0) return false;
            for (parts) |p| if (w.unsized(p) or !w.constant(p, false, depth + 1)) return false;
            return true;
        },
        .replicate => {
            const b = w.payload(Inst.Bin, i);
            if (literal(w, b.lhs)) |n| if (n <= 0) return false;
            return !w.unsized(b.rhs) and w.constant(b.lhs, false, depth + 1) and w.constant(b.rhs, false, depth + 1);
        },
        // The old parser kept a constant `min:typ:max`'s typical value.
        .mintypmax => return w.constant(w.payload(Inst.Triple, i).b, real, depth),
        .call_sys => {
            const c = w.payload(Inst.SysCall, i);
            const name = w.string(c.name);
            const args = w.vir.list(Inst.Ref, c.args);
            if (args.len != 1) return false;
            if (!std.mem.eql(u8, name, "$signed") and !std.mem.eql(u8, name, "$unsigned") and !std.mem.eql(u8, name, "$clog2")) return false;
            return w.constant(args[0], false, depth + 1);
        },
        else => return false, // else: a select, a call, a name that is not a parameter
    }
}

/// §5.1.14: an unsized literal (no concatenation takes one).
pub fn unsized(w: *const Walk, r: Inst.Ref) bool {
    const i = r.toIndex() orelse return false;
    return switch (w.tag(i)) {
        .int => true,
        .big_int => w.payload(Inst.BigInt, i).size == 0,
        else => false, // else: only a literal can be unsized
    };
}

/// The first token of parameter value `k` of instance `i`'s `#( ... )`
/// (a literal has no position in Vir): its count of top-level commas.
pub fn paramAt(w: *const Walk, i: Inst.Index, k: usize) u32 {
    var t = w.tree.nodeMainToken(w.node(i));
    var n: u32 = 0;
    while (t > 0 and n < 4096 and w.tree.tokenTag(t) != .hash) : (n += 1) t -= 1;
    t += 2; // `#` `(`
    var depth: u32 = 0;
    var seen: usize = 0;
    const end: Ast.TokenIndex = @intCast(w.tree.tokens.len);
    while (t < end and seen < k) : (t += 1) switch (w.tree.tokenTag(t)) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => seen += @intFromBool(depth == 0),
        else => {}, // else: a token inside the value
    };
    return w.tree.tokenStart(@min(t, end - 1));
}

/// A pull gate's keyword, before its strengths and name.
pub fn keywordAt(w: *const Walk, i: Inst.Index, kw: []const u8) u32 {
    var t = w.tree.nodeMainToken(w.node(i));
    var n: u32 = 0;
    while (t > 0 and n < 64 and !std.mem.eql(u8, w.tree.tokenSlice(t), kw)) : (n += 1) t -= 1;
    return w.tree.tokenStart(t);
}
