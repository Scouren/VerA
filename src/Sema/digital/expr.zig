//! Expressions of the digital lowering: a Vir expression, in the frame
//! `Lower.frame` binds its names in, -> typed `Program.exprs` rows bound to
//! slots. One sizer (`typeOf`, IEEE 1364-2005 §5.4's self-determined
//! widths and §5.5.1's types) and one lowering (`ctx`, §5.5.2's context
//! propagated down once, at compile time, instead of at every
//! evaluation), and the slots an expression reads. Selects, lvalues and
//! event terms are `place.zig`'s; system functions `sysfn.zig`'s.
//! Cites: IEEE 1364-2005 §3.5.1, §3.6, §4.8.2, §5.1, §5.2.1, §5.2.2,
//! §5.4, §5.5.1, §5.5.2, §5.5.3, §9.2, §9.7.2, §17.7, §17.8, §17.9, §17.11.
//!
//! Contents:
//! - `pub fn typeOf(l: *Lower, r: Inst.Ref) Error!Type`
//! - `pub fn ctx(l: *Lower, r: Inst.Ref, ty: Type) Error!u32`
//! - `pub fn self_(l: *Lower, r: Inst.Ref, width: u32) Error!u32`
//! - `pub fn selfOrReal(l: *Lower, r: Inst.Ref) Error!u32`
//! - `pub fn real(l: *Lower, r: Inst.Ref) Error!u32`
//! - `pub fn evalFor(l: *Lower, r: Inst.Ref, target: Type) Error!u32`
//! - `pub fn reads(l: *Lower, r: Inst.Ref, out: *std.ArrayList(u32)) Error!void`
//! - `pub fn nameOf(l: *Lower, r: Inst.Ref) Error!?Name`
//! - `pub fn common(a: Type, b: Type) Type`
//! - `pub fn constant(l: *Lower, v: Literal, ty: Type) Error!u32`
//! - `pub fn typeValue(l: *Lower, r: Inst.Ref) Error!Type`
//! - `pub fn declName(l: *Lower, d: Inst.Index) Error!Name`
//! - `pub fn leafName(l: *Lower, i: Inst.Index) Error!Name`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const std_sim = @import("std_sim");
const kernels = @import("kernels");
const digital = @import("../digital.zig");
const place = @import("place.zig");
const sysfn = @import("sysfn.zig");
const sub = @import("sub.zig");
const hier = @import("hier.zig");
const domain = @import("domain.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const Type = digital.Type;
const Name = digital.Name;
const none = digital.none;
const Program = std_sim.Program;
const Ty = Program.Ty;
const Literal = kernels.Integer.Literal;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// The deepest expression nest lowered; deeper is refused by name.
const depth_max: u32 = 1 << 10;

/// A sized or based literal: its value as the old frontend held it, and
/// its §5.4 type (`kernels.Integer.parse` of its text).
const Big = struct { v: Literal, ty: Type, unsized_logic: bool };

/// §5.5.1 the common type of two operands: real if either is, else the
/// wider width, signed only when both are.
pub fn common(a: Type, b: Type) Type {
    if (a.real or b.real) return Type.real_type;
    return .{ .width = @max(a.width, b.width), .signed = a.signed and b.signed };
}

/// §5.4/§5.5.1 the self-determined type of `r` in `Lower.frame` (a
/// width of 0 is §5.1.14's zero replication).
pub fn typeOf(l: *Lower, r: Inst.Ref) Error!Type {
    const i = r.toIndex() orelse return l.refuse("an omitted expression");
    const vir = l.virOf(l.frame);
    const data = vir.instructions.items(.data)[@backingInt(i)];
    return switch (Lower.tag(vir, i)) {
        .int => .{ .width = if (std.math.cast(i32, @as(i64, @bitCast(data.int))) != null) 32 else 64, .signed = true },
        .big_int => (try bigLiteral(l, vir, i)).ty,
        .str => .{ .width = @intCast(@max(1, data.str.len) * 8), .signed = false },
        .real => Type.real_type,
        .decl_ref, .str_ref, .field => blk: {
            const n = try leafName(l, i);
            if (n.kind == .event) return l.refuse("a named event read as a value");
            if (n.kind == .sub or n.kind == .scope) return l.refuse("a task, function or scope read as a value");
            break :blk n.ty;
        },
        .pos, .neg, .bit_not => blk: {
            const t = try typeValue(l, data.un_node.operand);
            if (t.real and Lower.tag(vir, i) == .bit_not) return l.refuse("~ of a real");
            break :blk t;
        },
        .not, .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor => blk: {
            const t = try typeValue(l, data.un_node.operand);
            if (t.real and Lower.tag(vir, i) != .not) return l.refuse("a reduction of a real");
            break :blk .{ .width = 1, .signed = false };
        },
        .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => blk: {
            const b = Lower.payload(vir, Inst.Bin, i);
            const x = try typeValue(l, b.lhs);
            const y = try typeValue(l, b.rhs);
            if ((x.real or y.real) and Lower.tag(vir, i) != .add and Lower.tag(vir, i) != .sub and Lower.tag(vir, i) != .mul and Lower.tag(vir, i) != .div) return l.refuse("a real operand of %, a bitwise or a shift operator");
            break :blk common(x, y);
        },
        .pow => blk: {
            const b = Lower.payload(vir, Inst.Bin, i);
            const x = try typeValue(l, b.lhs);
            const y = try typeValue(l, b.rhs);
            break :blk if (y.real) Type.real_type else x;
        },
        .shl, .shr, .ashl, .ashr => blk: {
            const b = Lower.payload(vir, Inst.Bin, i);
            const x = try typeValue(l, b.lhs);
            const y = try typeValue(l, b.rhs);
            if (x.real or y.real) return l.refuse("a real operand of a shift");
            break :blk x;
        },
        .lt, .gt, .lte, .gte, .eq, .neq, .case_eq, .case_neq, .bool_and, .bool_or => blk: {
            const b = Lower.payload(vir, Inst.Bin, i);
            const x = try typeValue(l, b.lhs);
            const y = try typeValue(l, b.rhs);
            if ((x.real or y.real) and (Lower.tag(vir, i) == .case_eq or Lower.tag(vir, i) == .case_neq)) return l.refuse("=== of a real");
            break :blk .{ .width = 1, .signed = false };
        },
        .ternary => blk: {
            const t = Lower.payload(vir, Inst.Triple, i);
            _ = try typeValue(l, t.a);
            break :blk common(try typeValue(l, t.b), try typeValue(l, t.c));
        },
        .mintypmax => typeValue(l, Lower.payload(vir, Inst.Triple, i).b),
        .elem, .slice, .slice_up, .slice_down => blk: {
            const s = try place.selectOf(l, i);
            if (s.name.kind == .event) return l.refuse("a named event element read as a value");
            break :blk s.ty;
        },
        .concat => blk: {
            var width: u32 = 0;
            for (vir.list(Inst.Ref, Lower.payload(vir, Inst.Refs, i))) |arg| {
                const t = try typeOf(l, arg);
                if (t.real) return l.refuse("a real concatenation operand");
                if (try unsized(l, arg)) return l.refuse("an unsized concatenation operand");
                width = std.math.add(u32, width, t.width) catch return l.refuse("a concatenation past 2^32 bits");
            }
            if (width == 0) return l.refuse("a concatenation of zero width");
            break :blk .{ .width = width, .signed = false };
        },
        .replicate => blk: {
            const b = Lower.payload(vir, Inst.Bin, i);
            const operand = try typeValue(l, b.rhs);
            const count = try replication(l, b.lhs);
            break :blk .{ .width = std.math.mul(u32, count, operand.width) catch return l.refuse("a replication past 2^32 bits"), .signed = false };
        },
        .call_sys => sysfn.sysType(l, i),
        .call => if (domain.isProbe(l, i)) Type.real_type else sub.resultType(l, i),
        else => l.refuseFmt("the expression form `{t}`", .{Lower.tag(vir, i)}),
    };
}

/// `r` evaluated in context type `ty` (§5.5.2), as a row.
pub fn ctx(l: *Lower, r: Inst.Ref, ty: Type) Error!u32 {
    const i = r.toIndex() orelse return l.refuse("an omitted expression");
    if (ty.real) return real(l, r);
    const vir = l.virOf(l.frame);
    const t = try l.tyOf(ty);
    const tg = Lower.tag(vir, i);
    switch (tg) {
        .int, .big_int, .str => return constant(l, try literalValue(l, vir, i, ty), ty),
        else => {},
    }
    const nat = try typeOf(l, r);
    if (nat.real) return l.b.expr(.int_of_real, t, try real(l, r), 0);
    const data = vir.instructions.items(.data)[@backingInt(i)];
    switch (tg) {
        .decl_ref, .str_ref, .field => {
            const n = try leafName(l, i);
            if (n.dims.len != 0) return l.refuse("a whole unpacked array read");
            return l.b.expr(.slot, t, n.slot, 0);
        },
        .elem, .slice, .slice_up, .slice_down => {
            const s = try place.selectOf(l, i);
            if (s.whole_elem) return l.b.expr(.elem, t, try place.elemRow(l, s), 0);
            return l.b.expr(.select, t, try place.selectRow(l, s), 0);
        },
        .pos => return ctx(l, data.un_node.operand, ty),
        .neg => return l.b.expr(.neg, t, try ctx(l, data.un_node.operand, ty), 0),
        .bit_not => return l.b.expr(.not, t, try ctx(l, data.un_node.operand, ty), 0),
        .not => return l.b.expr(.lnot, t, try selfOrReal(l, data.un_node.operand), 0),
        .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor => return l.b.expr(switch (tg) {
            .red_and => .red_and,
            .red_nand => .red_nand,
            .red_or => .red_or,
            .red_nor => .red_nor,
            .red_xor => .red_xor,
            else => .red_xnor, // else: the sixth reduction
        }, t, try self_(l, data.un_node.operand, 0), 0),
        .eq, .neq, .case_eq, .case_neq, .lt, .lte, .gt, .gte => {
            const b = Lower.payload(vir, Inst.Bin, i);
            const ot = common(try typeOf(l, b.lhs), try typeOf(l, b.rhs));
            if (ot.real) return l.b.expr(switch (tg) {
                .eq => .real_eq,
                .neq => .real_neq,
                .lt => .real_lt,
                .lte => .real_le,
                .gt => .real_gt,
                .gte => .real_ge,
                else => return l.refuse("=== of a real"), // else: `typeOf` refuses these
            }, t, try real(l, b.lhs), try real(l, b.rhs));
            return l.b.expr(switch (tg) {
                .eq => .eq,
                .neq => .neq,
                .case_eq => .case_eq,
                .case_neq => .case_neq,
                .lt => .lt,
                .lte => .le,
                .gt => .gt,
                else => .ge, // else: `>=`
            }, t, try ctx(l, b.lhs, ot), try ctx(l, b.rhs, ot));
        },
        .bool_and, .bool_or => {
            const b = Lower.payload(vir, Inst.Bin, i);
            return l.b.expr(if (tg == .bool_and) .land else .lor, t, try selfOrReal(l, b.lhs), try selfOrReal(l, b.rhs));
        },
        .shl, .shr, .ashl, .ashr, .pow => {
            const b = Lower.payload(vir, Inst.Bin, i);
            return l.b.expr(switch (tg) {
                .shl => .shl,
                .shr => .shr,
                .ashl => .ashl,
                .ashr => .ashr,
                else => .pow, // else: `**`
            }, t, try ctx(l, b.lhs, ty), try self_(l, b.rhs, 0));
        },
        .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => {
            const b = Lower.payload(vir, Inst.Bin, i);
            return l.b.expr(switch (tg) {
                .add => .add,
                .sub => .sub,
                .mul => .mul,
                .div => .div,
                .mod => .mod,
                .bit_and => .bit_and,
                .bit_or => .bit_or,
                .bit_xor => .bit_xor,
                else => .bit_xnor, // else: `~^`
            }, t, try ctx(l, b.lhs, ty), try ctx(l, b.rhs, ty));
        },
        .ternary => {
            const tr = Lower.payload(vir, Inst.Triple, i);
            const c = if ((try typeOf(l, tr.a)).real)
                try l.b.expr(.truth, Ty.bit, try real(l, tr.a), 0)
            else
                try self_(l, tr.a, 0);
            const arms = try l.b.listOf(&.{ try ctx(l, tr.b, ty), try ctx(l, tr.c, ty) });
            return l.b.expr(.cond, t, c, arms.start);
        },
        .mintypmax => return ctx(l, Lower.payload(vir, Inst.Triple, i).b, ty),
        .concat => {
            var parts: std.ArrayList(u32) = .empty;
            for (vir.list(Inst.Ref, Lower.payload(vir, Inst.Refs, i))) |arg| {
                if ((try typeOf(l, arg)).width == 0) {
                    // §5.1.14 a zero replication's operand runs, adding no bits.
                    const rep = Lower.payload(vir, Inst.Bin, arg.toIndex().?);
                    try parts.append(l.a, try l.b.expr(.discard, Ty.bit, try self_(l, rep.rhs, 0), 0));
                } else try parts.append(l.a, try self_(l, arg, 0));
            }
            const list = try l.b.listOf(parts.items);
            return l.b.expr(.concat, t, list.start, list.len);
        },
        .replicate => {
            const b = Lower.payload(vir, Inst.Bin, i);
            const count = try replication(l, b.lhs);
            if (count == 0) return l.refuse("a zero replication outside a concatenation");
            return l.b.expr(.replicate, t, try self_(l, b.rhs, 0), count);
        },
        .call_sys => return sysfn.sysCall(l, i, t, nat),
        .call => return l.b.expr(.call, t, try sub.callRow(l, i), 0),
        else => return l.refuseFmt("the expression form `{t}`", .{tg}),
    }
}

/// `r` in its own type, at least `width` wide (a real as its 64 bits).
pub fn self_(l: *Lower, r: Inst.Ref, width: u32) Error!u32 {
    var ty = try typeOf(l, r);
    if (ty.real) ty = .{ .width = 64, .signed = true };
    ty.width = @max(ty.width, width);
    return ctx(l, r, ty);
}

/// A real row when `r` is real, else `r` self-determined: a truth operand.
pub fn selfOrReal(l: *Lower, r: Inst.Ref) Error!u32 {
    if ((try typeOf(l, r)).real) return real(l, r);
    return self_(l, r, 0);
}

/// An assignment's value (§5.5.3): `r` at least as wide as the target, in
/// its own signedness, then converted to the target's width.
pub fn evalFor(l: *Lower, r: Inst.Ref, target: Type) Error!u32 {
    if (target.real) return real(l, r);
    const rhs = try self_(l, r, target.width);
    const rt = l.b.p.exprs.items(.ty)[rhs];
    return l.b.expr(.convert, try l.tyOf(.{ .width = target.width, .signed = rt.signed }), rhs, 0);
}

/// `r` as a real row (§4.8.2: an integral value converted).
pub fn real(l: *Lower, r: Inst.Ref) Error!u32 {
    const i = r.toIndex() orelse return l.refuse("an omitted expression");
    const vir = l.virOf(l.frame);
    const rt = Ty.real_ty;
    if (!(try typeOf(l, r)).real) return l.b.expr(.real_of_int, rt, try self_(l, r, 0), 0);
    const tg = Lower.tag(vir, i);
    const data = vir.instructions.items(.data)[@backingInt(i)];
    switch (tg) {
        .real => {
            const bits: u64 = @bitCast(data.float);
            return l.b.expr(.real_constant, rt, @truncate(bits), @truncate(bits >> 32));
        },
        .decl_ref, .str_ref, .field => {
            const n = try leafName(l, i);
            if (n.dims.len != 0) return l.refuse("a whole unpacked array read");
            return l.b.expr(.slot, rt, n.slot, 0);
        },
        .elem => {
            const s = try place.selectOf(l, i);
            if (!s.whole_elem) return l.refuse("a select of a real");
            return l.b.expr(.elem, rt, try place.elemRow(l, s), 0);
        },
        .pos => return real(l, data.un_node.operand),
        .neg => return l.b.expr(.real_neg, rt, try real(l, data.un_node.operand), 0),
        .add, .sub, .mul, .div, .pow => {
            const b = Lower.payload(vir, Inst.Bin, i);
            return l.b.expr(switch (tg) {
                .add => .real_add,
                .sub => .real_sub,
                .mul => .real_mul,
                .div => .real_div,
                else => .real_pow, // else: `**`
            }, rt, try real(l, b.lhs), try real(l, b.rhs));
        },
        .ternary => {
            const tr = Lower.payload(vir, Inst.Triple, i);
            const arms = try l.b.listOf(&.{ try real(l, tr.b), try real(l, tr.c) });
            return l.b.expr(.real_cond, rt, try selfOrReal(l, tr.a), arms.start);
        },
        .mintypmax => return real(l, Lower.payload(vir, Inst.Triple, i).b),
        .call_sys => return sysfn.sysReal(l, i),
        .call => return if (domain.isProbe(l, i)) domain.probe(l, i) else l.b.expr(.call, rt, try sub.callRow(l, i), 0),
        else => return l.refuseFmt("the real expression form `{t}`", .{tg}),
    }
}

/// Appends every slot expression `r` reads (§9.7.5's implicit list, a
/// driver's sensitivity), an array's every element.
pub fn reads(l: *Lower, r: Inst.Ref, out: *std.ArrayList(u32)) Error!void {
    const i = r.toIndex() orelse return;
    const vir = l.virOf(l.frame);
    const data = vir.instructions.items(.data)[@backingInt(i)];
    switch (Lower.tag(vir, i)) {
        .decl_ref, .str_ref, .field => {
            const n = try leafName(l, i);
            switch (n.kind) {
                .variable, .net, .param, .genvar, .event => for (0..n.count) |k| try addSlot(l, out, n.slot + @as(u32, @intCast(k))),
                .sub, .scope => {},
            }
        },
        .int, .big_int, .str, .real => {},
        .pos, .neg, .not, .bit_not, .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor, .posedge, .negedge => try reads(l, data.un_node.operand, out),
        .add, .sub, .mul, .div, .mod, .pow, .shl, .shr, .ashl, .ashr, .lt, .gt, .lte, .gte, .eq, .neq, .case_eq, .case_neq, .bit_and, .bit_or, .bit_xor, .bit_xnor, .bool_and, .bool_or, .elem, .replicate, .event_or => {
            const b = Lower.payload(vir, Inst.Bin, i);
            try reads(l, b.lhs, out);
            try reads(l, b.rhs, out);
        },
        .ternary, .mintypmax, .slice, .slice_up, .slice_down => {
            const t = Lower.payload(vir, Inst.Triple, i);
            try reads(l, t.a, out);
            try reads(l, t.b, out);
            try reads(l, t.c, out);
        },
        .concat => for (vir.list(Inst.Ref, Lower.payload(vir, Inst.Refs, i))) |x| try reads(l, x, out),
        .call_sys => for (vir.list(Inst.Ref, Lower.payload(vir, Inst.SysCall, i).args)) |x| try reads(l, x, out),
        // A probe reads the analog solution, no slot (the host's to watch).
        .call => if (!domain.isProbe(l, i)) for (vir.list(Inst.Ref, Lower.payload(vir, Inst.Call, i).args)) |x| try reads(l, x, out),
        else => return l.refuseFmt("the slots read by `{t}`", .{Lower.tag(vir, i)}),
    }
}

/// The name `r` is, when it is a `decl_ref` or an implicit net's
/// `str_ref`; else null.
pub fn nameOf(l: *Lower, r: Inst.Ref) Error!?Name {
    const i = r.toIndex() orelse return null;
    const vir = l.virOf(l.frame);
    if (Lower.tag(vir, i) != .decl_ref and Lower.tag(vir, i) != .str_ref and Lower.tag(vir, i) != .field) return null;
    return try leafName(l, i);
}

/// A constant row of type `ty` holding `v` (already as wide as `ty`).
pub fn constant(l: *Lower, v: Literal, ty: Type) Error!u32 {
    const n = Program.words(ty.width);
    assert(v.values().len >= n);
    return l.b.constant(try l.tyOf(ty), v.values()[0..n], v.unknowns()[0..n]);
}

/// `typeOf`, refused for a zero replication outside a concatenation.
pub fn typeValue(l: *Lower, r: Inst.Ref) Error!Type {
    const t = try typeOf(l, r);
    if (t.width == 0) return l.refuse("a zero replication outside a concatenation");
    return t;
}

/// The name declaration `d` is bound to from `Lower.frame`, refused
/// when none is.
pub fn declName(l: *Lower, d: Inst.Index) Error!Name {
    const n = l.lookup(l.frame, d) orelse {
        const vir = l.virOf(l.frame);
        return l.refuseFmt("a name declared by `{t}` that has no slot", .{Lower.tag(vir, d)});
    };
    return l.names.items[n];
}

/// The name leaf `i` (a `decl_ref`, a `str_ref` naming a §4.5 implicit
/// net of its instance, or a §12.5 hierarchical `field`) is bound to from
/// `Lower.frame`.
pub fn leafName(l: *Lower, i: Inst.Index) Error!Name {
    const vir = l.virOf(l.frame);
    const data = vir.instructions.items(.data)[@backingInt(i)];
    if (Lower.tag(vir, i) == .decl_ref) return declName(l, data.decl_tok.decl);
    if (Lower.tag(vir, i) == .field) return hier.field(l, i);
    assert(Lower.tag(vir, i) == .str_ref);
    const n = l.implicit.get(.{ .frame = l.rootFrame(l.frame), .name = data.str_tok.start }) orelse return l.refuse("a hierarchical name");
    return l.names.items[n];
}

// ---- private ----

/// `addSlot`: each slot once, in first-seen order.
fn addSlot(l: *Lower, out: *std.ArrayList(u32), slot: u32) Error!void {
    if (std.mem.findScalar(u32, out.items, slot) != null) return;
    try out.append(l.a, slot);
}

/// Whether `r` is an unsized constant (§4.2.13 forbids one in a
/// concatenation): an unsized literal, or a parameter of no range.
fn unsized(l: *Lower, r: Inst.Ref) Error!bool {
    const i = r.toIndex() orelse return false;
    const vir = l.virOf(l.frame);
    return switch (Lower.tag(vir, i)) {
        .int => true,
        .big_int => Lower.payload(vir, Inst.BigInt, i).size == 0,
        else => false, // else: every other operand is sized
    };
}

/// §5.1.14 a replication count: a non-negative constant.
fn replication(l: *Lower, r: Inst.Ref) Error!u32 {
    const v = try l.intOf(l.frame, r);
    return std.math.cast(u32, v) orelse l.refuse("a negative or huge replication count");
}

fn bigLiteral(l: *Lower, vir: *const Vir, i: Inst.Index) Error!Big {
    const b = Lower.payload(vir, Inst.BigInt, i);
    const digits = vir.string(b.digits);
    const radix: u8 = switch (b.flags.radix) {
        2 => 'b',
        8 => 'o',
        16 => 'h',
        else => 'd',
    };
    const text = if (b.size != 0)
        try std.fmt.allocPrint(l.a, "{d}'{s}{c}{s}", .{ b.size, if (b.flags.signed) "s" else "", radix, digits })
    else
        try std.fmt.allocPrint(l.a, "'{s}{c}{s}", .{ if (b.flags.signed) "s" else "", radix, digits });
    const lit = kernels.Integer.parse(l.a, text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return l.refuse("a literal kernels.Integer.parse refuses"),
    };
    // VD-131: an unsized based constant's digits times their bits.
    const per: u32 = switch (b.flags.radix) {
        2 => 1,
        8 => 3,
        16 => 4,
        else => 0,
    };
    const digit_bits: u32 = if (b.size == 0) per * @as(u32, @intCast(digits.len)) else 0;
    if (lit.asInt()) |value| {
        // §3.5.1: an unsized constant is 32 bits, so a signed based one
        // whose digits fill bit 31 is negative.
        const wraps = b.size == 0 and lit.signed and value > std.math.maxInt(i32) and value <= std.math.maxInt(u32);
        const v: i64 = if (wraps) value - (1 << 32) else value;
        const width: u32 = if (b.size != 0) b.size else if (digit_bits != 0) @max(32, digit_bits) else fits: {
            const ok = if (lit.signed) std.math.cast(i32, v) != null else v >= 0 and v <= std.math.maxInt(u32);
            break :fits if (ok) 32 else 64;
        };
        const planes = try l.a.alloc(u64, 2);
        planes[0] = @bitCast(v);
        planes[1] = 0;
        if (width < 64) planes[0] &= (@as(u64, 1) << @intCast(width)) - 1;
        return .{ .v = .{ .width = width, .signed = lit.signed, .sized = b.size != 0, .planes = planes }, .ty = .{ .width = width, .signed = lit.signed }, .unsized_logic = false };
    }
    var wide = lit;
    if (!lit.hasUnknown()) wide.width = @max(lit.width, digit_bits);
    const width: u32 = if (b.size != 0) b.size else if (!wide.hasUnknown() or wide.width > 64) @max(32, wide.width) else 32;
    return .{ .v = wide, .ty = .{ .width = width, .signed = lit.signed }, .unsized_logic = b.size == 0 };
}

/// A literal's value in context `ty` (`evaluate.evalContext` on a leaf):
/// extended by the context's signedness, an unsized x/z constant filled.
fn literalValue(l: *Lower, vir: *const Vir, i: Inst.Index, ty: Type) Error!Literal {
    const data = vir.instructions.items(.data)[@backingInt(i)];
    const leaf: Literal = switch (Lower.tag(vir, i)) {
        .int => blk: {
            const v: i64 = @bitCast(data.int);
            const width: u32 = if (std.math.cast(i32, v) != null) 32 else 64;
            const planes = try l.a.alloc(u64, 2);
            planes[0] = @bitCast(v);
            planes[1] = 0;
            if (width < 64) planes[0] &= (@as(u64, 1) << @intCast(width)) - 1;
            break :blk .{ .width = width, .signed = true, .sized = false, .planes = planes };
        },
        .big_int => blk: {
            const big = try bigLiteral(l, vir, i);
            if (big.unsized_logic) {
                const top = big.v.bit(big.v.width - 1);
                return resize(l, big.v, ty.width, if (top == .x or top == .z or ty.signed) .sign else .zero);
            }
            break :blk big.v;
        },
        .str => try std_sim.logic.stringLiteral(l.a, vir.string_bytes[@backingInt(data.str.start)..][0..data.str.len]),
        else => unreachable, // else: `ctx` sends only the literal tags
    };
    return resize(l, leaf, ty.width, if (ty.signed) .sign else .zero);
}

fn resize(l: *Lower, v: Literal, width: u32, ext: kernels.Integer.Extension) Error!Literal {
    return v.resize(l.a, width, ext) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ZeroSize => unreachable,
    };
}
