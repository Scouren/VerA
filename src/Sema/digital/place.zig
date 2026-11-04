//! Selects, lvalues and event terms of the digital lowering: an
//! `elem`/`slice*` chain, an assignment target or an event expression, in
//! `Lower.frame`, -> `Program.Elem`/`Program.Select`/`Program.Place` rows
//! and `Program.Term` lists.
//! Cites: IEEE 1364-2005 §4.9, §5.2.1, §5.2.2, §9.2, §9.7.2.
//!
//! Contents:
//! - `pub const Sel = struct`
//! - `pub fn targetType(l: *Lower, r: Inst.Ref) Error!Type`
//! - `pub fn place(l: *Lower, r: Inst.Ref) Error!u32`
//! - `pub fn notAutomatic(l: *Lower, r: Inst.Ref, comptime what: []const u8) Error!void`
//! - `pub fn readsNoAutomatic(l: *Lower, r: Inst.Ref, comptime what: []const u8) Error!void`
//! - `pub fn indexReads(l: *Lower, r: Inst.Ref, out: *std.ArrayList(u32)) Error!void`
//! - `pub fn bodyReads(l: *Lower, b: Vir.Body, out: *std.ArrayList(u32)) Error!void`
//! - `pub fn terms(l: *Lower, r: Inst.Ref, out: *std.ArrayList(u32)) Error!void`
//! - `pub fn selectOf(l: *Lower, i: Inst.Index) Error!Sel`
//! - `pub fn elemRow(l: *Lower, s: Sel) Error!u32`
//! - `pub fn selectRow(l: *Lower, s: Sel) Error!u32`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const std_sim = @import("std_sim");
const digital = @import("../digital.zig");
const expr = @import("expr.zig");
const stmt = @import("stmt.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const Type = digital.Type;
const Name = digital.Name;
const none = digital.none;
const Program = std_sim.Program;
const Ty = Program.Ty;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// A select or element reference, resolved: its base name, the indices
/// down the chain (outermost first), and what it is.
pub const Sel = struct {
    name: Name,
    /// The `elem` index refs, outermost first.
    indices: []const Inst.Ref,
    /// An element of the array `name` (all its dimensions indexed).
    whole_elem: bool,
    ty: Type,
    /// For a select: the element whose bits are selected (`whole_elem` of
    /// the prefix), the mode and its operands.
    mode: Program.Select.Mode = .bit,
    index: Inst.Ref = .none,
    count: u32 = 1,
    first: i64 = 0,
};

/// The type an assignment to lvalue `r` converts its value to: the
/// variable's (an element's), a select's (unsigned), a concatenation's sum.
pub fn targetType(l: *Lower, r: Inst.Ref) Error!Type {
    const i = r.toIndex() orelse return l.refuse("an omitted lvalue");
    const vir = l.virOf(l.frame);
    switch (Lower.tag(vir, i)) {
        .concat => {
            var width: u32 = 0;
            for (vir.list(Inst.Ref, Lower.payload(vir, Inst.Refs, i))) |x| width += (try targetType(l, x)).width;
            return .{ .width = width, .signed = false };
        },
        .decl_ref, .str_ref, .field => {
            const n = try expr.leafName(l, i);
            try writable(l, n, r);
            return n.ty;
        },
        .elem, .slice, .slice_up, .slice_down => {
            const s = try selectOf(l, i);
            try writable(l, s.name, r);
            if (s.whole_elem) return s.name.ty;
            return .{ .width = s.ty.width, .signed = false };
        },
        else => return l.refuse("an lvalue form"),
    }
}

/// The `Program.Place` lvalue `r` names, at its index in `extra`.
pub fn place(l: *Lower, r: Inst.Ref) Error!u32 {
    const i = r.toIndex() orelse return l.refuse("an omitted lvalue");
    const vir = l.virOf(l.frame);
    switch (Lower.tag(vir, i)) {
        .concat => {
            var parts: std.ArrayList(u32) = .empty;
            for (vir.list(Inst.Ref, Lower.payload(vir, Inst.Refs, i))) |x| try parts.appendSlice(l.a, &.{ try place(l, x), (try targetType(l, x)).width });
            const list = try l.b.listOf(parts.items);
            return l.b.extraOf(Program.Place{ .kind = .concat, .a = try l.b.extraOf(.{ .l = list }) });
        },
        .decl_ref, .str_ref, .field => {
            const n = try expr.leafName(l, i);
            try writable(l, n, r);
            if (n.dims.len != 0) return l.refuse("an assignment to a whole unpacked array");
            return l.b.extraOf(Program.Place{ .kind = .slot, .a = n.slot });
        },
        .elem, .slice, .slice_up, .slice_down => {
            const s = try selectOf(l, i);
            try writable(l, s.name, r);
            if (s.whole_elem) return l.b.extraOf(Program.Place{ .kind = .elem, .a = try elemRow(l, s) });
            return l.b.extraOf(Program.Place{ .kind = .select, .a = try selectRow(l, s) });
        },
        else => return l.refuse("an lvalue form"),
    }
}

/// §10.2.3 an automatic subroutine's variables "shall not be assigned
/// values using nonblocking assignments or procedural continuous
/// assignments" and "shall not be traced with system tasks such as
/// $monitor": `r` (a target, or a traced argument) names none.
pub fn notAutomatic(l: *Lower, r: Inst.Ref, comptime what: []const u8) Error!void {
    const i = r.toIndex() orelse return;
    const vir = l.virOf(l.frame);
    const slot = switch (Lower.tag(vir, i)) {
        .concat => {
            for (vir.list(Inst.Ref, Lower.payload(vir, Inst.Refs, i))) |x| try notAutomatic(l, x, what);
            return;
        },
        .decl_ref, .str_ref, .field => (try expr.leafName(l, i)).slot,
        .elem, .slice, .slice_up, .slice_down => (try selectOf(l, i)).name.slot,
        else => return, // else: an expression names no storage to outlive the activation
    };
    if (l.auto_slots.contains(slot)) return l.reject(l.frame, r, "§10.2.3: " ++ what ++ " cannot name a variable of an automatic task or function");
}

/// §10.2.3 `notAutomatic` for an expression read after the activation may
/// have ended: no plain name in `r` is an automatic variable (§10.2.1 keeps
/// a hierarchical name from reaching one).
pub fn readsNoAutomatic(l: *Lower, r: Inst.Ref, comptime what: []const u8) Error!void {
    const i = r.toIndex() orelse return;
    const vir = l.virOf(l.frame);
    const data = vir.instructions.items(.data)[@backingInt(i)];
    switch (Lower.tag(vir, i)) {
        .decl_ref => {
            const n = try expr.leafName(l, i);
            if (n.kind == .variable and l.auto_slots.contains(n.slot)) return l.reject(l.frame, r, "§10.2.3: " ++ what ++ " cannot name a variable of an automatic task or function");
        },
        .pos, .neg, .not, .bit_not, .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor, .posedge, .negedge, .event_ctl => try readsNoAutomatic(l, data.un_node.operand, what),
        .add, .sub, .mul, .div, .mod, .pow, .shl, .shr, .ashl, .ashr, .lt, .gt, .lte, .gte, .eq, .neq, .case_eq, .case_neq, .bit_and, .bit_or, .bit_xor, .bit_xnor, .bool_and, .bool_or, .elem, .replicate, .event_or, .repeat_ctl => {
            const b = Lower.payload(vir, Inst.Bin, i);
            try readsNoAutomatic(l, b.lhs, what);
            try readsNoAutomatic(l, b.rhs, what);
        },
        .ternary, .mintypmax, .slice, .slice_up, .slice_down => {
            const t = Lower.payload(vir, Inst.Triple, i);
            try readsNoAutomatic(l, t.a, what);
            try readsNoAutomatic(l, t.b, what);
            try readsNoAutomatic(l, t.c, what);
        },
        .concat => for (vir.list(Inst.Ref, Lower.payload(vir, Inst.Refs, i))) |x| try readsNoAutomatic(l, x, what),
        .call_sys => for (vir.list(Inst.Ref, Lower.payload(vir, Inst.SysCall, i).args)) |x| try readsNoAutomatic(l, x, what),
        .call => for (vir.list(Inst.Ref, Lower.payload(vir, Inst.Call, i).args)) |x| try readsNoAutomatic(l, x, what),
        else => {}, // else: a literal, a hierarchical name
    }
}

/// The slots the index expressions of lvalue `r` read (not its targets).
pub fn indexReads(l: *Lower, r: Inst.Ref, out: *std.ArrayList(u32)) Error!void {
    const vir = l.virOf(l.frame);
    const i = r.toIndex() orelse return;
    switch (Lower.tag(vir, i)) {
        .elem => {
            const b = Lower.payload(vir, Inst.Bin, i);
            try indexReads(l, b.lhs, out);
            try expr.reads(l, b.rhs, out);
        },
        .slice, .slice_up, .slice_down => {
            const t = Lower.payload(vir, Inst.Triple, i);
            try indexReads(l, t.a, out);
            try expr.reads(l, t.b, out);
            try expr.reads(l, t.c, out);
        },
        .concat => for (vir.list(Inst.Ref, Lower.payload(vir, Inst.Refs, i))) |x| try indexReads(l, x, out),
        else => {}, // else: a name, whose slot is written, not read
    }
}

/// Every slot the statements of body `b` read (§9.7.5's `@*`).
pub fn bodyReads(l: *Lower, b: Vir.Body, out: *std.ArrayList(u32)) Error!void {
    const vir = l.virOf(l.frame);
    for (vir.body(b)) |i| switch (Lower.tag(vir, i)) {
        .store, .store_nb => {
            const s = Lower.payload(vir, Inst.Bin, i);
            try expr.reads(l, s.rhs, out);
            // §9.7.5 the target's index expressions are read too.
            try indexReads(l, s.lhs, out);
        },
        .condbr => {
            const c = Lower.payload(vir, Inst.CondBr, i);
            try expr.reads(l, c.cond, out);
            try bodyReads(l, c.then, out);
            try bodyReads(l, c.@"else", out);
        },
        .block => try bodyReads(l, Lower.payload(vir, Inst.Block, i).body, out),
        .case => {
            const c = Lower.payload(vir, Inst.Case, i);
            try expr.reads(l, c.operand, out);
            for (vir.list(Inst.Arm, c.arms)) |arm| {
                for (vir.list(Inst.Ref, arm.values)) |v| try expr.reads(l, v, out);
                try bodyReads(l, arm.body, out);
            }
        },
        .call_sys => for (vir.list(Inst.Ref, Lower.payload(vir, Inst.SysCall, i).args)) |a| try expr.reads(l, a, out),
        // A nested `@` suspends on its own terms; its statement's reads join.
        .event_wait => try bodyReads(l, Lower.payload(vir, Inst.EventWait, i).body, out),
        .loop => {
            const lp = Lower.payload(vir, Inst.Loop, i);
            const cond = vir.body(lp.cond);
            if (cond.len != 0) try expr.reads(l, cond[cond.len - 1].toRef(), out);
            try bodyReads(l, lp.body, out);
            try bodyReads(l, lp.step, out);
        },
        .repeat => {
            const r = Lower.payload(vir, Inst.Repeat, i);
            try expr.reads(l, r.count, out);
            try bodyReads(l, r.body, out);
        },
        else => if (stmt.isStatement(Lower.tag(vir, i))) return l.refuseFmt("the slots `@*` reads in `{t}`", .{Lower.tag(vir, i)}),
    };
}

/// Appends the `Program.Term` rows (5 words each) of event expression `r`
/// (§9.7.2): its `or`/`,` operands, each edge, named events and the
/// slots of each operand.
pub fn terms(l: *Lower, r: Inst.Ref, out: *std.ArrayList(u32)) Error!void {
    const i = r.toIndex() orelse return l.refuse("an omitted event expression");
    const vir = l.virOf(l.frame);
    const tg = Lower.tag(vir, i);
    const edge: Program.Edge = switch (tg) {
        .event_or => {
            const b = Lower.payload(vir, Inst.Bin, i);
            try terms(l, b.lhs, out);
            return terms(l, b.rhs, out);
        },
        .posedge => .posedge,
        .negedge => .negedge,
        .driver_update => return l.refuse("a driver_update event term"),
        else => .any, // else: a name or an expression
    };
    const watched = if (edge == .any) r else vir.instructions.items(.data)[@backingInt(i)].un_node.operand;
    const w = watched.toIndex() orelse return l.refuse("an omitted event expression");
    if (try @import("domain.zig").monitor(l, w)) |event| {
        if (edge != .any) return l.refuse("an edge of an analog event");
        return out.appendSlice(l.a, &.{ event, @backingInt(Program.Edge.any), 0, 0, none });
    }
    switch (Lower.tag(vir, w)) {
        .decl_ref, .str_ref, .field => {
            const n = try expr.leafName(l, w);
            if (n.dims.len != 0) return l.refuse("an event control on a whole array");
            return out.appendSlice(l.a, &.{ n.slot, @backingInt(edge), 0, 0, none });
        },
        .elem, .slice, .slice_up, .slice_down => {
            const s = try selectOf(l, w);
            // §9.7.3 an event array element: every element, each waking
            // only when the index names it at the occurrence.
            if (s.name.kind == .event and s.whole_elem) {
                const el = try elemRow(l, s);
                for (0..s.name.count) |k| try out.appendSlice(l.a, &.{ s.name.slot + @as(u32, @intCast(k)), @backingInt(Program.Edge.any), 0, 0, el });
                return;
            }
            // A constant select of a vector watches its own bits.
            if (!s.whole_elem and s.name.dims.len == 0 and !s.name.ty.real) if (try constantFirst(l, s)) |first| if (s.count <= 64) {
                return out.appendSlice(l.a, &.{ s.name.slot, @backingInt(edge), first, s.count, none });
            };
        },
        else => {}, // else: an expression, watched below
    }
    try out.appendSlice(l.a, &.{ try exprTerm(l, watched), @backingInt(edge), 0, 0, none });
}

/// Resolves an `elem`/`slice*` chain `i`: an array element, or a bit- or
/// part-select of a vector or of an element.
pub fn selectOf(l: *Lower, i: Inst.Index) Error!Sel {
    const vir = l.virOf(l.frame);
    // The chain of `elem`s from the base, outermost first.
    var indices: std.ArrayList(Inst.Ref) = .empty;
    const top_tag = Lower.tag(vir, i);
    var x = if (top_tag == .elem) i.toRef() else Lower.payload(vir, Inst.Triple, i).a;
    while (true) {
        const xi = x.toIndex() orelse return l.refuse("an omitted select base");
        if (Lower.tag(vir, xi) != .elem) break;
        const b = Lower.payload(vir, Inst.Bin, xi);
        try indices.insert(l.a, 0, b.rhs);
        x = b.lhs;
    }
    const base = x.toIndex().?;
    if (Lower.tag(vir, base) != .decl_ref and Lower.tag(vir, base) != .str_ref and Lower.tag(vir, base) != .field) return l.refuse("a select of an expression");
    const n = try expr.leafName(l, base);
    if (n.kind == .sub or n.kind == .scope) return l.refuse("a select of a task, function or scope");
    const dims = n.dims.len;
    if (indices.items.len < dims) return l.refuse("a select of a whole array dimension");
    for (indices.items) |r| if ((try expr.typeOf(l, r)).real) return l.refuse("a real index");
    if (top_tag == .elem and indices.items.len == dims) return .{ .name = n, .indices = indices.items, .whole_elem = true, .ty = n.ty };
    if (n.kind == .event) return l.refuse("a select of a named event");
    if (n.ty.real) return l.refuse("a select of a real");
    if (n.scalar) return l.refuse("§5.2.1 a select of a scalar");
    if (n.kind == .event) return l.refuse("a select of a named event");
    var s: Sel = .{ .name = n, .indices = indices.items[0..dims], .whole_elem = false, .ty = .{ .width = 1, .signed = false } };
    switch (top_tag) {
        .elem => {
            if (indices.items.len != dims + 1) return l.refuse("a select of a bit");
            s.mode = .bit;
            s.index = indices.items[dims];
        },
        .slice => {
            if (indices.items.len != dims) return l.refuse("a part-select of a bit");
            const t = Lower.payload(vir, Inst.Triple, i);
            const msb = try l.intOf(l.frame, t.b);
            const lsb = try l.intOf(l.frame, t.c);
            if (msb != lsb and (msb > lsb) != (n.msb >= n.lsb)) return l.refuse("§5.2.1 a part-select reversed against its declaration");
            s.mode = .const_part;
            s.count = std.math.cast(u32, @abs(@as(i128, msb) - lsb) + 1) orelse return l.refuse("a part-select past 2^32 bits");
            s.first = if (n.msb >= n.lsb) lsb -| n.lsb else n.lsb -| lsb;
            s.ty = .{ .width = s.count, .signed = false };
        },
        .slice_up, .slice_down => {
            if (indices.items.len != dims) return l.refuse("a part-select of a bit");
            const t = Lower.payload(vir, Inst.Triple, i);
            const width = try l.intOf(l.frame, t.c);
            if (width < 1 or width >= std.math.maxInt(u32)) return l.refuse("§5.2.1 an indexed part-select width that is not a positive constant");
            if ((try expr.typeOf(l, t.b)).real) return l.refuse("a real part-select base");
            s.mode = if (top_tag == .slice_up) .up else .down;
            s.index = t.b;
            s.count = @intCast(width);
            s.ty = .{ .width = s.count, .signed = false };
        },
        else => unreachable, // else: `selectOf` is called for these four tags
    }
    return s;
}

/// The `Program.Elem` of element reference `s`, in `extra`.
pub fn elemRow(l: *Lower, s: Sel) Error!u32 {
    const n = Program.Elem.dim_words;
    const dims = try l.a.alloc(u32, n * s.name.dims.len);
    for (s.name.dims, s.indices[0..s.name.dims.len], 0..) |span, r, k| {
        const low: u64 = @bitCast(span.low);
        const high: u64 = @bitCast(span.high);
        dims[n * k ..][0..n].* = .{ try expr.self_(l, r, 0), @truncate(low), @truncate(low >> 32), @truncate(high), @truncate(high >> 32) };
    }
    return l.b.extraOf(Program.Elem{ .base = s.name.slot, .count = s.name.count, .dims = try l.b.listOf(dims) });
}

/// The `Program.Select` of select `s`, in `extra`.
pub fn selectRow(l: *Lower, s: Sel) Error!u32 {
    const el: u32 = if (s.name.dims.len != 0) try elemRow(l, .{ .name = s.name, .indices = s.indices, .whole_elem = true, .ty = s.name.ty }) else none;
    var sel: Program.Select = .{ .slot = s.name.slot, .elem = el, .msb = s.name.msb, .lsb = s.name.lsb, .mode = s.mode, .index = 0, .count = s.count, .first = s.first };
    if (s.mode != .const_part) sel.index = try expr.self_(l, s.index, 0);
    return l.b.extraOf(sel);
}

// ---- private ----

/// §6.2/§9.2 a procedural target is a variable (lib/sim/digital's
/// `checkTarget`): a net, or an element of a net array (§4.9.1), is driven
/// by a continuous assignment only.
fn writable(l: *Lower, n: Name, r: Inst.Ref) Error!void {
    switch (n.kind) {
        .variable => {},
        .net => return l.reject(l.frame, r, "a net is driven by a continuous assignment; there is no procedural assignment to a net"),
        .param, .genvar => return l.refuse("an assignment to a parameter"),
        .event, .sub, .scope => return l.refuse("an assignment to a named event, task, function or scope"),
    }
}

/// The bit position a constant select `s` starts at, or null when its
/// index is not constant or it leaves its vector.
fn constantFirst(l: *Lower, s: Sel) Error!?u32 {
    const first: i64 = switch (s.mode) {
        .const_part => s.first,
        .bit, .up, .down => blk: {
            const c = (try l.constOf(l.frame, s.index)) orelse return null;
            const idx = switch (c) {
                .int => |v| v,
                else => return null,
            };
            break :blk if (s.name.msb >= s.name.lsb) idx -| s.name.lsb else s.name.lsb -| idx;
        },
    };
    if (first < 0 or first + s.count > s.name.ty.width) return null;
    return @intCast(first);
}

/// §9.7.2 "an implicit event shall be detected on any change in the value
/// of the expression": a hidden slot kept equal to `r` by a process of its
/// own (jumped over here, started at time 0), which the term watches.
fn exprTerm(l: *Lower, r: Inst.Ref) Error!u32 {
    const scope = l.frames.items[l.frame].scope;
    const ty = try expr.typeValue(l, r);
    const slot = try @import("vars.zig").slots(l, ty, 1, if (ty.real) .zero else .x);
    var reads: std.ArrayList(u32) = .empty;
    try expr.reads(l, r, &reads);
    var terms_: std.ArrayList(u32) = .empty;
    for (reads.items) |s| try terms_.appendSlice(l.a, &.{ s, @backingInt(Program.Edge.any), 0, 0, none });
    const skip = try l.b.inst(.jump, 0, 0, scope);
    const start: u32 = @intCast(l.b.p.insts.len);
    _ = try l.b.inst(.init_var, slot, try expr.evalFor(l, r, ty), scope);
    _ = try l.b.inst(.wait_event, try l.b.extraOf(.{ .l = try l.b.listOf(terms_.items) }), 0, scope);
    _ = try l.b.inst(.jump, start, 0, scope);
    l.b.setInst(skip, .jump, @intCast(l.b.p.insts.len), 0);
    try l.term_starts.append(l.a, start);
    return slot;
}
