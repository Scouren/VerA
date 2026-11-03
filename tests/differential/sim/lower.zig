//! The bridge's expression half: an old elaborated `Run`'s AST expression,
//! in the scope `Run.scope` names, -> typed, bound `Program.exprs` rows,
//! each the value lib/sim/digital's `evaluate.evalContext` computes for it
//! (the context propagation is replayed here once, at bridge time, instead
//! of at every evaluation). Also assignment targets (`Program.Place`) and
//! event controls (`Program.Term` lists). Test code: Sema replaces it.
//! Cites: IEEE 1364-2005 §4.8.2, §5.1, §5.2.1, §5.5.1, §5.5.2, §9.2,
//! §9.7.2, §17.7, §17.8, §17.11 (through lib/sim/digital).
//!
//! Contents:
//! - `pub const Lower = struct`
//! - `Lower.refuse(l: *Lower, comptime why: []const u8) error{Unsupported}`
//! - `Lower.ctx(l: *Lower, e: ExprId, ty: Type) E!u32`
//! - `Lower.self_(l: *Lower, e: ExprId, width: u32) E!u32`
//! - `Lower.real(l: *Lower, e: ExprId) E!u32`
//! - `Lower.selfOrReal(l: *Lower, e: ExprId) E!u32`
//! - `Lower.evalFor(l: *Lower, e: ExprId, target: Type) E!u32`
//! - `Lower.targetType(l: *Lower, e: ExprId) E!Type`
//! - `Lower.place(l: *Lower, e: ExprId) E!u32`
//! - `Lower.terms(l: *Lower, e: ExprId, out: *std.ArrayList(u32)) E!void`
//! - `pub const E`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const sim = @import("sim");
const std_sim = @import("std_sim");
const frontend = @import("frontend");
const Ast = frontend.Ast;
const ExprId = Ast.ExprId;
const digital = sim.digital;
const Run = digital.Run;
const compile = digital.for_emitter.compile;
const evaluate = digital.for_emitter.evaluate;
const Type = compile.Type;
const Program = std_sim.Program;
const Builder = std_sim.Builder;
const Ty = Program.Ty;

/// A construct the bridge does not express yet, or the old engine's own
/// failure while the bridge asked it something.
pub const E = error{Unsupported} || Allocator.Error;

pub const Lower = struct {
    r: *Run,
    b: *Builder,
    a: Allocator,
    /// Why the last `Unsupported` was returned.
    why: []const u8 = "",

    /// Records `why` and fails.
    pub fn refuse(l: *Lower, comptime why: []const u8) error{Unsupported} {
        l.why = why;
        return error.Unsupported;
    }

    /// `evaluate.evalContext(e, ty)` as a row.
    pub fn ctx(l: *Lower, e: ExprId, ty: Type) E!u32 {
        assert(e != .none);
        const r = l.r;
        const ex = &r.file.exprs;
        if (ty.real) return l.real(e);
        const t = try tyOf(l, ty);
        const nat = compile.typeOf(r, e);
        switch (ex.tag(e)) {
            // A literal's value in its context is pure: the old evaluator
            // folds it here once.
            .int_literal, .logic_literal, .str_literal => if (!nat.real) return l.constant(e, ty),
            else => {},
        }
        if (nat.real) return l.b.expr(.int_of_real, t, try l.real(e), 0);
        switch (ex.tag(e)) {
            .ident, .hier_ident => {
                const at = try l.slotOf(e);
                if (r.decls.arrays.contains(at)) return l.refuse("a whole unpacked array read");
                return l.b.expr(.slot, t, at, 0);
            },
            .index => return l.index(e, t),
            .unary => {
                const op = ex.unOp(e);
                return switch (op) {
                    .plus => l.ctx(ex.lhs(e), ty),
                    .minus => l.b.expr(.neg, t, try l.ctx(ex.lhs(e), ty), 0),
                    .bit_not => l.b.expr(.not, t, try l.ctx(ex.lhs(e), ty), 0),
                    .logical_not => l.b.expr(.lnot, t, try l.selfOrReal(ex.lhs(e)), 0),
                    .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => l.b.expr(switch (op) {
                        .reduce_and => .red_and,
                        .reduce_nand => .red_nand,
                        .reduce_or => .red_or,
                        .reduce_nor => .red_nor,
                        .reduce_xor => .red_xor,
                        else => .red_xnor, // else: the sixth reduction
                    }, t, try l.self_(ex.lhs(e), 0), 0),
                };
            },
            .binary => {
                const op = ex.binOp(e);
                switch (op) {
                    .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge => {
                        const ot = compile.common(compile.typeOf(r, ex.lhs(e)), compile.typeOf(r, ex.rhs(e)));
                        if (ot.real) return l.b.expr(switch (op) {
                            .eq => .real_eq,
                            .neq => .real_neq,
                            .lt => .real_lt,
                            .le => .real_le,
                            .gt => .real_gt,
                            .ge => .real_ge,
                            else => return l.refuse("=== on a real"), // else: infer refuses these
                        }, t, try l.real(ex.lhs(e)), try l.real(ex.rhs(e)));
                        return l.b.expr(switch (op) {
                            .eq => .eq,
                            .neq => .neq,
                            .case_eq => .case_eq,
                            .case_neq => .case_neq,
                            .lt => .lt,
                            .le => .le,
                            .gt => .gt,
                            else => .ge, // else: `>=`
                        }, t, try l.ctx(ex.lhs(e), ot), try l.ctx(ex.rhs(e), ot));
                    },
                    .logical_and, .logical_or => return l.b.expr(if (op == .logical_and) .land else .lor, t, try l.selfOrReal(ex.lhs(e)), try l.selfOrReal(ex.rhs(e))),
                    .shl, .shr, .ashl, .ashr, .pow => return l.b.expr(switch (op) {
                        .shl => .shl,
                        .shr => .shr,
                        .ashl => .ashl,
                        .ashr => .ashr,
                        else => .pow, // else: `**`
                    }, t, try l.ctx(ex.lhs(e), ty), try l.self_(ex.rhs(e), 0)),
                    .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => return l.b.expr(switch (op) {
                        .add => .add,
                        .sub => .sub,
                        .mul => .mul,
                        .div => .div,
                        .mod => .mod,
                        .bit_and => .bit_and,
                        .bit_or => .bit_or,
                        .bit_xor => .bit_xor,
                        else => .bit_xnor, // else: `~^`
                    }, t, try l.ctx(ex.lhs(e), ty), try l.ctx(ex.rhs(e), ty)),
                }
            },
            .ternary => {
                const c = if (compile.typeOf(r, ex.lhs(e)).real)
                    try l.b.expr(.truth, Ty.bit, try l.real(ex.lhs(e)), 0)
                else
                    try l.self_(ex.lhs(e), 0);
                const arms = try l.b.listOf(&.{ try l.ctx(ex.rhs(e), ty), try l.ctx(ex.ternaryElse(e), ty) });
                return l.b.expr(.cond, t, c, arms.start);
            },
            .concat => {
                var parts: std.ArrayList(u32) = .empty;
                for (ex.args(e)) |arg| {
                    if (compile.typeOf(r, arg).width == 0) {
                        // §5.1.14 a zero replication's operand runs, adding no bits.
                        try parts.append(l.a, try l.b.expr(.discard, Ty.bit, try l.self_(ex.rhs(arg), 0), 0));
                    } else try parts.append(l.a, try l.self_(arg, 0));
                }
                const list = try l.b.listOf(parts.items);
                return l.b.expr(.concat, t, list.start, list.len);
            },
            .multi_concat => {
                const count = r.typing.replications.get(.{ .spec = r.specOf(r.scope), .e = e }) orelse return l.refuse("an unfolded replication");
                if (count == 0) return l.refuse("a zero replication outside a concatenation");
                return l.b.expr(.replicate, t, try l.self_(ex.rhs(e), 0), count);
            },
            .sys_call => return l.sysCall(e, t, nat),
            .call => return l.refuse("a function call"),
            else => return l.refuse("an expression form"),
        }
    }

    /// `evaluate.eval(e, width)`: `e` in its own type, at least `width` wide.
    pub fn self_(l: *Lower, e: ExprId, width: u32) E!u32 {
        var ty = compile.typeOf(l.r, e);
        if (ty.real) ty = .{ .width = 64, .signed = true };
        ty.width = @max(ty.width, width);
        return l.ctx(e, ty);
    }

    /// A row that is real when `e` is, else `e` self-determined: a truth
    /// operand (`evaluate.truthOf`).
    pub fn selfOrReal(l: *Lower, e: ExprId) E!u32 {
        if (compile.typeOf(l.r, e).real) return l.real(e);
        return l.self_(e, 0);
    }

    /// `evaluate.evalFor(e, target)`: an assignment's value, converted.
    pub fn evalFor(l: *Lower, e: ExprId, target: Type) E!u32 {
        if (target.real) return l.real(e);
        const rhs = try l.self_(e, target.width);
        const rt = l.b.p.exprs.items(.ty)[rhs];
        return l.b.expr(.convert, try tyOf(l, .{ .width = target.width, .signed = rt.signed }), rhs, 0);
    }

    /// `evaluate.targetType(e)`.
    pub fn targetType(l: *Lower, e: ExprId) E!Type {
        const r = l.r;
        const ex = &r.file.exprs;
        if (ex.tag(e) == .concat) {
            var width: u32 = 0;
            for (ex.args(e)) |x| width += (try l.targetType(x)).width;
            return .{ .width = width, .signed = false };
        }
        if (ex.tag(e) == .index and try l.indexedArray(e) == null) return .{ .width = compile.typeOf(r, e).width, .signed = false };
        const at = r.baseSlot(e) catch return l.refuse("an lvalue the old engine refuses");
        return r.slotType(at);
    }

    /// The `Program.Place` lvalue `e` names, at its index in `extra`.
    pub fn place(l: *Lower, e: ExprId) E!u32 {
        const r = l.r;
        const ex = &r.file.exprs;
        switch (ex.tag(e)) {
            .concat => {
                var parts: std.ArrayList(u32) = .empty;
                for (ex.args(e)) |x| try parts.appendSlice(l.a, &.{ try l.place(x), (try l.targetType(x)).width });
                const list = try l.b.listOf(parts.items);
                return l.b.extraOf(Program.Place{ .kind = .concat, .a = try l.b.extraOf(.{ .l = list }) });
            },
            .ident, .hier_ident => return l.b.extraOf(Program.Place{ .kind = .slot, .a = try l.slotOf(e) }),
            .index => {
                if (try l.indexedArray(e) != null) return l.b.extraOf(Program.Place{ .kind = .elem, .a = try l.elem(e) });
                return l.b.extraOf(Program.Place{ .kind = .select, .a = try l.select(e) });
            },
            else => return l.refuse("an lvalue form"),
        }
    }

    /// Appends the `Program.Term` rows (4 words each) of event expression
    /// `e` (`exec.suspendOn`).
    pub fn terms(l: *Lower, e: ExprId, out: *std.ArrayList(u32)) E!void {
        const r = l.r;
        const ex = &r.file.exprs;
        const edge: Program.Edge = switch (ex.tag(e)) {
            .event_or => {
                try l.terms(ex.lhs(e), out);
                return l.terms(ex.rhs(e), out);
            },
            .event_posedge => .posedge,
            .event_negedge => .negedge,
            .event_function => return l.refuse("an analog event function term"),
            .event_driver_update => return l.refuse("a driver_update event term"),
            else => .any, // else: a name, or an expression with a hidden slot
        };
        const watched = if (edge == .any) e else ex.lhs(e);
        if (ex.tag(watched) == .index) {
            const c = r.chainBase(watched);
            const base = try l.slotOf(c.base);
            if (r.decls.events.contains(base)) return l.refuse("an event array select term");
        }
        if (compile.selectTerm(r, watched) catch return l.refuse("a select term the old engine refuses")) |sel| {
            return out.appendSlice(l.a, &.{ sel.slot, @backingInt(edge), sel.first, sel.count });
        }
        if (r.routines.auto_terms.contains(.{ .scope = r.scope, .e = watched })) return l.refuse("an automatic expression term");
        const slot = r.termSlot(watched) catch return l.refuse("a term the old engine refuses");
        try out.appendSlice(l.a, &.{ slot, @backingInt(edge), 0, 0 });
    }

    /// `evaluate.evalReal(e)` as a real row.
    pub fn real(l: *Lower, e: ExprId) E!u32 {
        const r = l.r;
        const ex = &r.file.exprs;
        const rt = Ty.real_ty;
        if (!compile.typeOf(r, e).real) return l.b.expr(.real_of_int, rt, try l.self_(e, 0), 0);
        switch (ex.tag(e)) {
            .real_literal => {
                const bits: u64 = @bitCast(ex.realValue(e));
                return l.b.expr(.real_constant, rt, @truncate(bits), @truncate(bits >> 32));
            },
            .ident, .hier_ident => return l.b.expr(.slot, rt, try l.slotOf(e), 0),
            .index => {
                if (try l.indexedArray(e) == null) return l.refuse("a select of a real");
                return l.b.expr(.elem, rt, try l.elem(e), 0);
            },
            .unary => return switch (ex.unOp(e)) {
                .minus => l.b.expr(.real_neg, rt, try l.real(ex.lhs(e)), 0),
                else => l.real(ex.lhs(e)), // else: `+`, the only other real unary
            },
            .binary => return l.b.expr(switch (ex.binOp(e)) {
                .add => .real_add,
                .sub => .real_sub,
                .mul => .real_mul,
                .div => .real_div,
                .pow => .real_pow,
                else => return l.refuse("a real operator"), // else: infer admits only these
            }, rt, try l.real(ex.lhs(e)), try l.real(ex.rhs(e))),
            .ternary => {
                const arms = try l.b.listOf(&.{ try l.real(ex.rhs(e)), try l.real(ex.ternaryElse(e)) });
                return l.b.expr(.real_cond, rt, try l.selfOrReal(ex.lhs(e)), arms.start);
            },
            .sys_call => {
                const f = r.typing.sys_calls[@backingInt(e)] orelse return l.refuse("an untyped system call");
                const args = ex.args(e);
                return switch (f) {
                    .realtime => l.b.expr(.realtime, rt, try l.timeRow(), 0),
                    .itor => if (compile.typeOf(r, args[0]).real) l.refuse("$itor of a real") else l.b.expr(.real_of_int, rt, try l.self_(args[0], 0), 0),
                    .bitstoreal => l.b.expr(.bitstoreal, rt, try l.self_(args[0], 64), 0),
                    inline .ln, .log10, .exp, .sqrt, .floor, .ceil, .sin, .cos, .tan, .asin, .acos, .atan, .sinh, .cosh, .tanh, .asinh, .acosh, .atanh => |m| l.b.expr(.math1, rt, try l.real(args[0]), @backingInt(@field(Program.Math, @tagName(m)))),
                    inline .pow, .atan2, .hypot => |m| blk: {
                        const pair = try l.b.listOf(&.{ try l.real(args[0]), try l.real(args[1]) });
                        break :blk l.b.expr(.math2, rt, pair.start, @backingInt(@field(Program.Math, @tagName(m))));
                    },
                    else => l.refuse("a real system function"), // else: the rest are not lowered yet
                };
            },
            .call => return l.refuse("a real function call"),
            else => return l.refuse("a real expression form"),
        }
    }

    // ---- private ----

    fn slotOf(l: *Lower, e: ExprId) E!u32 {
        return l.r.slot(e) catch l.refuse("a name the old engine cannot resolve here");
    }

    fn indexedArray(l: *Lower, e: ExprId) E!?digital.Array {
        return l.r.indexedArray(e) catch l.refuse("an index the old engine refuses");
    }

    /// A literal's value in `ty`, folded by the old evaluator.
    fn constant(l: *Lower, e: ExprId, ty: Type) E!u32 {
        const v = evaluate.evalContext(l.r, l.a, e, ty) catch return l.refuse("a literal the old engine refuses");
        const n = std_sim.Program.words(ty.width);
        return l.b.constant(try tyOf(l, ty), v.values()[0..n], v.unknowns()[0..n]);
    }

    fn timeRow(l: *Lower) E!u32 {
        return l.r.scope;
    }

    fn index(l: *Lower, e: ExprId, t: Ty) E!u32 {
        if (try l.indexedArray(e) != null) return l.b.expr(.elem, t, try l.elem(e), 0);
        return l.b.expr(.select, t, try l.select(e), 0);
    }

    /// The `Program.Elem` of array element reference `e`, in `extra`.
    fn elem(l: *Lower, e: ExprId) E!u32 {
        const r = l.r;
        const ex = &r.file.exprs;
        const c = r.chainBase(e);
        const base = try l.slotOf(c.base);
        const arr = r.decls.arrays.get(base).?;
        const dims = try l.a.alloc(u32, 3 * c.depth);
        var x = e;
        var k = c.depth;
        while (k != 0) : (x = ex.lhs(x)) {
            k -= 1;
            const span: digital.Span = if (k == 0) .{ .low = arr.low, .high = arr.high } else arr.rest[k - 1];
            const low = std.math.cast(i32, span.low) orelse return l.refuse("an array bound past i32");
            const high = std.math.cast(i32, span.high) orelse return l.refuse("an array bound past i32");
            dims[3 * k] = try l.self_(ex.rhs(x), 0);
            dims[3 * k + 1] = @bitCast(low);
            dims[3 * k + 2] = @bitCast(high);
        }
        return l.b.extraOf(Program.Elem{ .base = base, .count = arr.count, .dims = try l.b.listOf(dims) });
    }

    /// The `Program.Select` of bit- or part-select `e`, in `extra`.
    fn select(l: *Lower, e: ExprId) E!u32 {
        const r = l.r;
        const ex = &r.file.exprs;
        const v = ex.lhs(e);
        const base = r.baseSlot(v) catch return l.refuse("a select base the old engine refuses");
        const range = r.vecRange(base);
        const msb = std.math.cast(i32, range.msb) orelse return l.refuse("a vector bound past i32");
        const lsb = std.math.cast(i32, range.lsb) orelse return l.refuse("a vector bound past i32");
        const el: u32 = if (ex.tag(v) == .index) try l.elem(v) else std.math.maxInt(u32);
        const rg = ex.rhs(e);
        var sel: Program.Select = .{ .slot = base, .elem = el, .msb = msb, .lsb = lsb, .mode = .bit, .index = 0, .count = 1, .first = 0 };
        switch (ex.tag(rg)) {
            .range => {
                const ps = r.typing.part_selects.get(.{ .spec = r.specOf(r.scope), .e = e }) orelse return l.refuse("an unfolded part-select");
                sel.mode = .const_part;
                sel.first = std.math.cast(i32, range.position(ps.lsb)) orelse return l.refuse("a part-select position past i32");
                sel.count = std.math.cast(u32, @abs(ps.msb - ps.lsb) + 1) orelse return l.refuse("a part-select past u32");
            },
            .indexed_range => {
                const ps = r.typing.part_selects.get(.{ .spec = r.specOf(r.scope), .e = e }) orelse return l.refuse("an unfolded part-select");
                sel.mode = if (ex.extraOf(rg) == 0) .up else .down;
                sel.count = std.math.cast(u32, ps.msb + 1) orelse return l.refuse("a part-select past u32");
                sel.index = try l.self_(ex.lhs(rg), 0);
            },
            else => sel.index = try l.self_(rg, 0), // else: a bit-select's index
        }
        return l.b.extraOf(sel);
    }

    fn sysCall(l: *Lower, e: ExprId, t: Ty, nat: Type) E!u32 {
        const r = l.r;
        const ex = &r.file.exprs;
        const f = r.typing.sys_calls[@backingInt(e)] orelse return l.refuse("an untyped system call");
        const args = ex.args(e);
        const natural = try tyOf(l, nat);
        const raw: u32 = switch (f) {
            .make_signed, .make_unsigned => return l.b.expr(.convert, t, try l.self_(args[0], 0), if (f == .make_signed) 2 else 1),
            .rtoi => try l.b.expr(.rtoi, Ty.int(32, true), try l.real(args[0]), 0),
            .realtobits => try l.b.expr(.realtobits, Ty.int(64, false), try l.real(args[0]), 0),
            .time => try l.b.expr(.time, natural, try l.timeRow(), 0),
            .stime => try l.b.expr(.stime, natural, try l.timeRow(), 0),
            .clog2 => try l.b.expr(.clog2, Ty.int(32, true), try l.self_(args[0], 0), 0),
            else => return l.refuse("a system function"), // else: not lowered yet
        };
        return l.b.expr(.convert, t, raw, 0);
    }
};

// ---- private ----

fn tyOf(l: *Lower, ty: Type) E!Ty {
    if (ty.real) return Ty.real_ty;
    if (ty.width == 0 or ty.width > std.math.maxInt(u30)) return l.refuse("a width past 2^30 bits");
    return Ty.int(ty.width, ty.signed);
}
