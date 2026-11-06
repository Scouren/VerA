//! §3.2.2 arrays (the old `analog/shape.zig`, `expr_select.zig`,
//! `assign.zig`): an array variable is one slot per element, row-major in
//! declaration order (each dimension's msb first). An element at constant
//! subscripts is its slot (E0309, E0310); at a run-time subscript a read is
//! a chain of `select`s over the slots and a write assigns each slot its
//! old value or the new one, so an index outside the array reads zero and
//! writes nothing, as the old memory array does.
//! Cites: VAMS-2023 §3.2.2, §4.2.12.
//!
//! Contents:
//! - `pub const Element = struct`
//! - `pub fn element(s: *Sema, b: *Block, r: Inst.Ref, src: Inst.Ref) Allocator.Error!?Element`
//! - `pub fn load(s: *Sema, b: *Block, e: Element) Allocator.Error!Value`
//! - `pub fn store(s: *Sema, b: *Block, e: Element, v: Air.Inst.Ref) Allocator.Error!void`

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
const Value = Sema.Value;
const Ref = Air.Inst.Ref;

/// An element of an array: its slots and the flat index (constant, or a
/// run-time integer over the slots).
pub const Element = struct {
    slots: []const Air.Inst.Index,
    ty: Sema.Ty,
    at: union(enum) { constant: u32, runtime: Ref },
};
/// §3.2.2 the element `r` (an `elem` chain over an array) names; null
/// after a diagnostic. A constant index outside the array is E0310.
pub fn element(s: *Sema, b: *Block, r: Inst.Ref, src: Inst.Ref) Allocator.Error!?Element {
    const vir = b.unit.vir;
    var subs: [8]Inst.Ref = undefined;
    var n: usize = 0;
    var at = r;
    const base = while (true) {
        const i = at.toIndex() orelse return null;
        switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            .elem => {
                if (n == subs.len) {
                    try s.fail(.E0512, b.unit.file, src, "an array of more than {d} dimensions", .{subs.len});
                    return null;
                }
                const x = decl.payloadOf(vir, Inst.Bin, i);
                subs[n] = x.rhs;
                n += 1;
                at = x.lhs;
            },
            .decl_ref => break decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl),
            else => {
                try s.fail(.E0512, b.unit.file, src, "a select of this is not lowered by Sema yet", .{});
                return null;
            },
        }
    };
    std.mem.reverse(Inst.Ref, subs[0..n]);
    const bind = b.unit.binds.get(base) orelse {
        try s.fail(.E0512, b.unit.file, src, "a select of a name with no slot", .{});
        return null;
    };
    if (bind != .array) {
        try s.fail(.E0512, b.unit.file, src, "a bit or part select of a scalar is not lowered by Sema yet", .{});
        return null;
    }
    const arr = bind.array;
    if (n != arr.dims.len) {
        try s.fail(.E0309, b.unit.file, src, "{d} subscripts for {d} dimensions", .{ n, arr.dims.len });
        return null;
    }
    var flat: u32 = 0;
    var runtime: ?Ref = null;
    for (subs[0..n], arr.dims) |sub, d| {
        const len: u32 = @intCast(@abs(d[0] - d[1]) + 1);
        const lo = @min(d[0], d[1]);
        if (expr.constOf(s, (try expr.lower(s, b, sub)).ref)) |c| {
            const k = c.asIntExact() orelse return null;
            if (k < lo or k > @max(d[0], d[1])) {
                try s.fail(.E0310, b.unit.file, src, "index {d} is outside [{d}:{d}]", .{ k, d[0], d[1] });
                return null;
            }
            // Declaration order: the msb is element 0.
            const off: u32 = @intCast(if (d[0] >= d[1]) d[0] - k else k - d[0]);
            flat = flat * len + off;
            if (runtime) |rt| runtime = try expr.binOp(s, b, .iadd, try expr.binOp(s, b, .imul, rt, .fromIntern(try decl.intern(s, .{ .int = len }))), .fromIntern(try decl.intern(s, .{ .int = off })));
            continue;
        }
        const k = try expr.coerce(s, b, try expr.lower(s, b, sub), .integer);
        const off = if (d[0] >= d[1]) try expr.binOp(s, b, .isub, .fromIntern(try decl.intern(s, .{ .int = d[0] })), k) else try expr.binOp(s, b, .isub, k, .fromIntern(try decl.intern(s, .{ .int = d[0] })));
        const base_ref: Ref = if (runtime) |rt| rt else .fromIntern(try decl.intern(s, .{ .int = flat }));
        runtime = try expr.binOp(s, b, .iadd, try expr.binOp(s, b, .imul, base_ref, .fromIntern(try decl.intern(s, .{ .int = len }))), off);
    }
    return .{ .slots = arr.slots, .ty = arr.ty, .at = if (runtime) |rt| .{ .runtime = rt } else .{ .constant = flat } };
}
/// The element's value; a run-time index outside the array reads zero
/// (§3.2.2, as the old `fload` does).
pub fn load(s: *Sema, b: *Block, e: Element) Allocator.Error!Value {
    switch (e.at) {
        .constant => |k| return .{ .ref = try s.addInst(b, .{ .tag = .load, .data = .{ .un_op = .fromIndex(e.slots[k]) } }), .ty = e.ty },
        .runtime => |k| {
            var acc: Ref = .fromIntern(if (e.ty == .real) .zero_real else .zero);
            var i = e.slots.len;
            while (i > 0) {
                i -= 1;
                const v = try s.addInst(b, .{ .tag = .load, .data = .{ .un_op = .fromIndex(e.slots[i]) } });
                const hit = try expr.binOp(s, b, .ieq, k, .fromIntern(try decl.intern(s, .{ .int = @intCast(i) })));
                const at = try s.air.addExtra(s.gpa, Air.Bin{ .lhs = v, .rhs = acc });
                acc = try s.addInst(b, .{ .tag = .select, .data = .{ .pl_op = .{ .operand = hit, .payload = at } } });
            }
            return .{ .ref = acc, .ty = e.ty };
        },
    }
}
/// Assigns `v` (of the element's type) to the element; a run-time index
/// outside the array writes nothing.
pub fn store(s: *Sema, b: *Block, e: Element, v: Ref) Allocator.Error!void {
    switch (e.at) {
        .constant => |k| _ = try s.addInst(b, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(e.slots[k]), .rhs = v } } }),
        .runtime => |k| for (e.slots, 0..) |slot, i| {
            const hit = try expr.binOp(s, b, .ieq, k, .fromIntern(try decl.intern(s, .{ .int = @intCast(i) })));
            const old = try s.addInst(b, .{ .tag = .load, .data = .{ .un_op = .fromIndex(slot) } });
            const at = try s.air.addExtra(s.gpa, Air.Bin{ .lhs = v, .rhs = old });
            const nv = try s.addInst(b, .{ .tag = .select, .data = .{ .pl_op = .{ .operand = hit, .payload = at } } });
            _ = try s.addInst(b, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slot), .rhs = nv } } });
        },
    }
}
