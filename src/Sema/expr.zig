//! Expressions (Zig's `Sema/arith.zig` and the `zir*` expression handlers):
//! one Vir expression of the instance a `Block` reads in, its `Air`
//! operand and §3.2 type out. Operators choose their real or integer form
//! by the operands' types (§4.2.1, the old `analog/expr_op.zig`); an
//! operation whose operands are all constants is folded at emit time by
//! `kernels.fold`, the kernel the old MIR's run-time ops share, so a folded
//! value is the value the old interpreter computes (fold.zig). `?:`, `&&` and `||`
//! evaluate their arms only when taken (a `block` and a `cond_br`).
//! Cites: VAMS-2023 §2.6, §2.7, §3.2, §4.2, §4.2.1.1, §4.2.1.2, §4.2.4,
//! §4.2.5, §4.2.7-§4.2.12, §4.3 (Tables 4-14, 4-15); IEEE 1364-2005 Table 5-6.
//!
//! Contents:
//! - `pub const depth_max: u32`
//! - `pub fn lower(s: *Sema, b: *Block, r: Inst.Ref) Allocator.Error!Value`
//! - `pub fn coerce(s: *Sema, b: *Block, v: Value, ty: Sema.Ty) Allocator.Error!Air.Inst.Ref`
//! - `pub fn toBool(s: *Sema, b: *Block, v: Value) Allocator.Error!Air.Inst.Ref`
//! - `pub fn unOp(s: *Sema, b: *Block, tag: Air.Inst.Tag, a: Air.Inst.Ref) Allocator.Error!Air.Inst.Ref`
//! - `pub fn binOp(s: *Sema, b: *Block, tag: Air.Inst.Tag, x: Air.Inst.Ref, y: Air.Inst.Ref) Allocator.Error!Air.Inst.Ref`
//! - `pub fn constOf(s: *const Sema, r: Air.Inst.Ref) ?fold.Const`
//! - `pub fn call(s: *Sema, b: *Block, callee: u32, ty: Sema.Ty, args: []const Air.Inst.Ref) Allocator.Error!Air.Inst.Ref`
//! - `pub const poison: Value`, `pub const user_callee: u32`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Air = @import("air");
const fold = @import("std_kernels").fold;
const sema_fold = @import("fold.zig");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const contrib = @import("contrib.zig");
const syscall = @import("syscall.zig");
const control = @import("control.zig");
const array = @import("array.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Block = Sema.Block;
const Value = Sema.Value;
const Ref = Air.Inst.Ref;

/// The deepest expression nesting lowered; past it, E0241 (lib/TODO.md
/// §11.2: a fixed cap with its own code).
pub const depth_max: u32 = 1 << 12;

/// `Air.Call.callee` of a §2.8.3 user system function.
pub const user_callee: u32 = std.math.maxInt(u32);

/// The value a refused operand stands for after its diagnostic.
pub const poison: Value = .{ .ref = .fromIntern(.zero_real), .ty = .real };

/// Lowers `r` and returns its value. A construct lowering refuses is
/// reported to `zcu.failed` and stands for `poison`.
pub fn lower(s: *Sema, b: *Block, r: Inst.Ref) Allocator.Error!Value {
    const i = r.toIndex() orelse return poison;
    if (s.expr_depth >= depth_max) {
        try s.fail(.E0241, b.unit.file, r, "{d} levels deep", .{s.expr_depth});
        return poison;
    }
    s.expr_depth += 1;
    defer s.expr_depth -= 1;
    const outer = s.expr_src;
    s.expr_src = r;
    defer s.expr_src = outer;
    const v = try inst(s, b, i);
    assert(v.ref != .none);
    return v;
}

/// `v` as a value of type `ty` (§4.2.1.1, §4.2.1.2; §2.7 a string literal
/// is its characters' integer).
pub fn coerce(s: *Sema, b: *Block, v: Value, ty: Sema.Ty) Allocator.Error!Ref {
    if (ty == .string) return v.ref;
    const w = try strNum(s, v);
    return switch (ty) {
        .real => if (w.ty == .integer) try unOp(s, b, .if_cast, w.ref) else w.ref,
        .integer => if (w.ty == .real) try unOp(s, b, .fi_cast, w.ref) else w.ref,
        .string => w.ref,
    };
}

/// `v != 0` as a §4.2.8 integer 0 or 1; a string is 0.
pub fn toBool(s: *Sema, b: *Block, v: Value) Allocator.Error!Ref {
    return switch (v.ty) {
        .integer => binOp(s, b, .ine, v.ref, .fromIntern(.zero)),
        .real => binOp(s, b, .fne, v.ref, .fromIntern(.zero_real)),
        .string => .fromIntern(.zero),
    };
}

/// Appends value tag `tag` over `a`, or its folded constant.
pub fn unOp(s: *Sema, b: *Block, tag: Air.Inst.Tag, a: Ref) Allocator.Error!Ref {
    assert(Air.tag_info.getPtrConst(tag).class == .un_op);
    if (constOf(s, a)) |c| if (sema_fold.tag(tag, &.{c})) |r| return .fromIntern(try decl.intern(s, r));
    return s.addInst(b, .{ .tag = tag, .data = .{ .un_op = a } });
}

/// Appends value tag `tag` over `x`, `y`, or its folded constant.
pub fn binOp(s: *Sema, b: *Block, tag: Air.Inst.Tag, x: Ref, y: Ref) Allocator.Error!Ref {
    assert(Air.tag_info.getPtrConst(tag).class == .bin_op);
    if (constOf(s, x)) |cx| if (constOf(s, y)) |cy| if (sema_fold.tag(tag, &.{ cx, cy })) |r| return .fromIntern(try decl.intern(s, r));
    return s.addInst(b, .{ .tag = tag, .data = .{ .bin_op = .{ .lhs = x, .rhs = y } } });
}

/// The constant `r` reads, or null for an instruction.
pub fn constOf(s: *const Sema, r: Ref) ?fold.Const {
    const index = r.toInterned() orelse return null;
    return switch (s.zcu.intern_pool.indexToKey(index)) {
        .float => |f| .{ .real = f },
        .int => |int| switch (int.storage) {
            .small => |v| .{ .int = v },
            .big => null,
        },
        .str => |t| .{ .str = s.zcu.intern_pool.stringToSlice(t) },
        else => null, // else: a type or an undefined value folds nothing
    };
}

/// Appends a system or user call (`callee` a `SysFn.Tag`'s integer, or
/// `user_callee`) of type `ty` over `args`.
pub fn call(s: *Sema, b: *Block, callee: u32, ty: ?Sema.Ty, args: []const Ref) Allocator.Error!Ref {
    const at = try s.air.addExtra(s.gpa, Air.Call{ .callee = callee, .args_len = @intCast(args.len) });
    try s.air.extra.appendSlice(s.gpa, @ptrCast(args));
    const t: InternPool.Index = if (ty) |x| switch (x) {
        .real => .real_type,
        .integer => .integer_type,
        .string => .string_type,
    } else .none;
    const r = try s.addInst(b, .{ .tag = .call, .data = .{ .ty_pl = .{ .ty = t, .payload = at } } });
    assert(r.toIndex() != null);
    return r;
}

// ---- private ----

fn inst(s: *Sema, b: *Block, i: Inst.Index) Allocator.Error!Value {
    const unit = b.unit;
    const vir = unit.vir;
    const tag = vir.instructions.items(.tag)[@backingInt(i)];
    const data = vir.instructions.items(.data)[@backingInt(i)];
    const src = i.toRef();
    return switch (tag) {
        .int => if (data.int <= std.math.maxInt(i64)) constant(s, .{ .int = @intCast(data.int) }) else refuse(s, b, src, "an integer literal past 64 bits"),
        .real => constant(s, .{ .real = data.float }),
        .str => constant(s, .{ .str = vir.string_bytes[@backingInt(data.str.start)..][0..data.str.len] }),
        .big_int => bigInt(s, b, i),
        .decl_ref => declRef(s, b, data.decl_tok.decl, src),
        .pos => lower(s, b, data.un_node.operand),
        .neg, .not, .bit_not => unary(s, b, tag, data.un_node.operand, src),
        .red_and, .red_nand, .red_or, .red_nor => {
            try s.fail(.E0348, unit.file, src, "", .{});
            return poison;
        },
        .red_xor, .red_xnor => {
            try s.fail(.E0320, unit.file, src, "", .{});
            return poison;
        },
        .add, .sub, .mul, .div, .mod, .pow, .shl, .shr, .ashl, .ashr, .lt, .gt, .lte, .gte, .eq, .neq, .case_eq, .case_neq, .bit_and, .bit_or, .bit_xor, .bit_xnor => binary(s, b, tag, decl.payloadOf(vir, Inst.Bin, i), src),
        .bool_and, .bool_or => shortCircuit(s, b, tag == .bool_and, decl.payloadOf(vir, Inst.Bin, i)),
        .ternary => ternary(s, b, decl.payloadOf(vir, Inst.Triple, i)),
        .call_sys => syscall.lower(s, b, decl.payloadOf(vir, Inst.SysCall, i), src),
        .call => callExpr(s, b, decl.payloadOf(vir, Inst.Call, i), src),
        .mintypmax => lower(s, b, decl.payloadOf(vir, Inst.Triple, i).b),
        .elem => blk: {
            const e = (try array.element(s, b, src, src)) orelse break :blk poison;
            break :blk array.load(s, b, e);
        },
        .field => hierRead(s, b, src),
        .concat, .replicate => @import("string.zig").concat(s, b, i, src),
        // §6.8 a name no declaration in scope gives.
        .str_ref => blk: {
            try s.fail(.E0314, b.unit.file, src, "`{s}` is not declared here", .{vir.string(data.str_tok.start)});
            break :blk poison;
        },
        .slice, .slice_up, .slice_down, .pattern, .pattern_repl, .port_branch, .event_or, .posedge, .negedge, .driver_update, .step_event, .range, .pulse_limits => refuse(s, b, src, @tagName(tag)),
        .paramset_output => @import("simprobe.zig").dotted(s, b, vir.string(data.str_tok.start), src),
        .module, .nature, .discipline, .paramset, .primitive, .connectrules, .config, .port, .io, .net, .variable, .param, .aliasparam, .genvar, .event, .branch, .instance, .assign, .defparam, .analog, .analog_initial, .initial, .always, .function, .gen_for, .gen_if, .gen_case, .gen_block, .specify, .path, .timing_check, .pulse_style, .timing_event, .ps_override, .connect_resolve, .connect_insert, .block, .condbr, .case, .loop, .repeat, .wait, .delay, .event_wait, .store, .store_nb, .contrib, .proc_assign, .force, .store_timed, .store_nb_timed, .contrib_indirect, .deassign, .release, .trigger, .disable, .ret, .brk, .cont, .delay_ctl, .event_ctl, .repeat_ctl => unreachable, // AstGen: an operand is an expression
    };
}

/// A construct this lowering does not execute yet: E0512 naming it, never a
/// silent zero.
fn refuse(s: *Sema, b: *Block, src: Inst.Ref, what: []const u8) Allocator.Error!Value {
    try s.fail(.E0512, b.unit.file, src, "`{s}` is not lowered by Sema yet", .{what});
    return poison;
}

fn constant(s: *Sema, c: fold.Const) Allocator.Error!Value {
    return .{ .ref = .fromIntern(try decl.intern(s, c)), .ty = switch (c) {
        .int => .integer,
        .real => .real,
        .str => .string,
    } };
}

fn bigInt(s: *Sema, b: *Block, i: Inst.Index) Allocator.Error!Value {
    var env: @import("eval.zig").Env = try .init(s.gpa, s.arena, &s.zcu.intern_pool, b.unit.vir, &.{});
    defer env.deinit();
    const c = (try env.ref(i.toRef())) orelse {
        try s.fail(.E0130, b.unit.file, i.toRef(), "the analog backend cannot execute this four-state or wide literal", .{});
        return poison;
    };
    return constant(s, c);
}

/// A name: a parameter's `arg`, a variable's slot, or a refusal.
fn declRef(s: *Sema, b: *Block, d: Inst.Index, src: Inst.Ref) Allocator.Error!Value {
    const first = decl.canonical(b.unit.vir, d);
    const bind = b.unit.binds.get(first) orelse return refuse(s, b, src, "a name with no analog binding");
    return bindValue(s, b, bind, src);
}

/// §6.7 a hierarchical name read as a value: a parameter, a named block's
/// local, a §5.5.3 nature attribute (a real, or a string). §6.7.1: "It
/// shall be an error to access analog variables hierarchically" (E0910).
fn hierRead(s: *Sema, b: *Block, src: Inst.Ref) Allocator.Error!Value {
    const hit = (try @import("hier.zig").resolve(s, b, src, src)) orelse return poison;
    switch (hit) {
        .attr => |c| return switch (c) {
            .real, .int => constant(s, .{ .real = c.asReal() }),
            .str => constant(s, c),
        },
        .local => |slot| return .{ .ref = try s.addInst(b, .{ .tag = .load, .data = .{ .un_op = .fromIndex(slot.alloc) } }), .ty = slot.ty },
        .alias => unreachable, // `resolve` reports an aliasparam (E0373)
        .bind => |x| {
            if (x.bind == .slot or x.bind == .array) {
                try s.fail(.E0910, b.unit.file, src, "a variable read through a hierarchical name", .{});
                return poison;
            }
            return bindValue(s, b, x.bind, src);
        },
    }
}

/// What a name's binding reads as a value.
fn bindValue(s: *Sema, b: *Block, bind: Sema.Bind, src: Inst.Ref) Allocator.Error!Value {
    return switch (bind) {
        .param => |p| s.param_args.items[@backingInt(p)],
        .slot => |slot| blk: {
            const r = try s.addInst(b, .{ .tag = .load, .data = .{ .un_op = .fromIndex(slot.alloc) } });
            if (s.static_slots.contains(slot.alloc)) try s.static_loads.put(s.arena, r.toIndex().?, {});
            break :blk .{ .ref = r, .ty = slot.ty };
        },
        .constant => |c| .{
            .ref = .fromIntern(c),
            .ty = switch (s.zcu.intern_pool.indexToKey(c)) {
                .float => .real,
                .str => .string,
                else => .integer, // else: a genvar's integer
            },
        },
        .array => refuse(s, b, src, "a whole array read as a value"),
        .node, .vector, .branch, .port => {
            try s.fail(.E0315, b.unit.file, src, "a net or branch is not a value; read it through an access function", .{});
            return poison;
        },
    };
}

/// §2.7: a string constant as its characters' integer; anything else as is.
fn strNum(s: *Sema, v: Value) Allocator.Error!Value {
    if (v.ty != .string) return v;
    const c = constOf(s, v.ref) orelse return v;
    return constant(s, .{ .int = fold.strToInt(c.str, 64) });
}

fn unary(s: *Sema, b: *Block, tag: Inst.Tag, operand: Inst.Ref, src: Inst.Ref) Allocator.Error!Value {
    const a = try strNum(s, try lower(s, b, operand));
    switch (tag) {
        .neg => {
            if (constOf(s, a.ref)) |c| switch (c) {
                .int => |x| return constant(s, fold.unary(.minus, .{ .int = x }).?),
                .real => |x| return constant(s, .{ .real = -x }),
                .str => {},
            };
            return .{ .ref = try unOp(s, b, if (a.ty == .real) .fneg else .ineg, a.ref), .ty = a.ty };
        },
        .not => return .{ .ref = try unOp(s, b, .lognot, try toBool(s, b, a)), .ty = .integer },
        .bit_not => {
            if (a.ty != .integer) {
                try s.fail(.E0318, b.unit.file, src, "`~` on a {t}", .{a.ty});
                return poison;
            }
            return .{ .ref = try unOp(s, b, .bitnot, a.ref), .ty = .integer };
        },
        else => unreachable, // else: `inst` routes these three
    }
}

fn unify(a: Sema.Ty, b: Sema.Ty) Sema.Ty {
    if (a == .string or b == .string) return .string;
    return if (a == .real or b == .real) .real else .integer;
}

fn binary(s: *Sema, b: *Block, tag: Inst.Tag, bin: Inst.Bin, src: Inst.Ref) Allocator.Error!Value {
    const file = b.unit.file;
    const lx = try lower(s, b, bin.lhs);
    const ly = try lower(s, b, bin.rhs);
    // §3.3 Table 3-3: two strings compare as strings.
    if (lx.ty == .string and ly.ty == .string) switch (tag) {
        .lt, .gt, .lte, .gte, .eq, .neq, .case_eq, .case_neq => return @import("string.zig").compare(s, b, tag, lx, ly),
        else => {}, // else: no other operator takes two strings (E0321 below)
    };
    const x = try strNum(s, lx);
    const y = try strNum(s, ly);
    if (x.ty == .string or y.ty == .string) {
        try s.fail(.E0321, file, src, "a string is not a number; §3.3 Table 3-3 gives it no arithmetic", .{});
        return poison;
    }
    const real = unify(x.ty, y.ty) == .real;
    switch (tag) {
        .add, .sub, .mul, .div, .mod => {
            const t: Air.Inst.Tag = switch (tag) {
                .add => if (real) .fadd else .iadd,
                .sub => if (real) .fsub else .isub,
                .mul => if (real) .fmul else .imul,
                .div => if (real) .fdiv else .idiv,
                else => if (real) .fmod else .imod, // else: `.mod`, the fifth of the prong
            };
            const ty: Sema.Ty = if (real) .real else .integer;
            return .{ .ref = try binOp(s, b, t, try coerce(s, b, x, ty), try coerce(s, b, y, ty)), .ty = ty };
        },
        .pow => {
            if (x.ty == .integer and y.ty == .integer) return .{ .ref = try binOp(s, b, .ipow, x.ref, y.ref), .ty = .integer };
            return .{ .ref = try binOp(s, b, .pow, try coerce(s, b, x, .real), try coerce(s, b, y, .real)), .ty = .real };
        },
        .lt, .gt, .lte, .gte, .eq, .neq, .case_eq, .case_neq => {
            if ((tag == .case_eq or tag == .case_neq) and real) {
                try s.fail(.E0369, file, src, "", .{});
                return poison;
            }
            const t: Air.Inst.Tag = switch (tag) {
                .lt => if (real) .flt else .ilt,
                .gt => if (real) .fgt else .igt,
                .lte => if (real) .fle else .ile,
                .gte => if (real) .fge else .ige,
                .eq, .case_eq => if (real) .feq else .ieq,
                else => if (real) .fne else .ine, // else: `!=` and `!==`
            };
            if (real) return .{ .ref = try binOp(s, b, t, try coerce(s, b, x, .real), try coerce(s, b, y, .real)), .ty = .integer };
            // §4.2.9 an unsigned operand makes the comparison unsigned.
            const xy = try @import("sign.zig").compareOperands(s, b, b.unit.vir, bin.lhs, bin.rhs, x.ref, y.ref);
            return .{ .ref = try binOp(s, b, t, xy[0], xy[1]), .ty = .integer };
        },
        .bit_and, .bit_or, .bit_xor, .bit_xnor, .shl, .shr => {
            if (x.ty != .integer or y.ty != .integer) {
                try s.fail(.E0322, file, src, "got {t} and {t}", .{ x.ty, y.ty });
                return poison;
            }
            const t: Air.Inst.Tag = switch (tag) {
                .bit_and => .bitand,
                .bit_or => .bitor,
                .bit_xor => .bitxor,
                .bit_xnor => .bitxnor,
                .shl => .shl,
                else => .shr, // else: `>>`, the sixth of the prong
            };
            return .{ .ref = try binOp(s, b, t, x.ref, y.ref), .ty = .integer };
        },
        .ashl, .ashr => {
            try s.fail(.E0324, file, src, "", .{});
            return poison;
        },
        else => unreachable, // else: `inst` routes the binary operators here
    }
}

/// §4.2.8 `a && b`, `a || b`: `b` runs only when `a` does not decide.
fn shortCircuit(s: *Sema, b: *Block, is_and: bool, bin: Inst.Bin) Allocator.Error!Value {
    const a = try toBool(s, b, try lower(s, b, bin.lhs));
    if (constOf(s, a)) |c| {
        if (c.isTrue() != is_and) return .{ .ref = a, .ty = .integer };
        return .{ .ref = try toBool(s, b, try lower(s, b, bin.rhs)), .ty = .integer };
    }
    const blk = try s.air.addInst(s.gpa, .{ .tag = .block, .data = undefined });
    var rhs_b = b.child();
    rhs_b.conditional += 1;
    rhs_b.runtime += @intFromBool(!@import("op.zig").isStatic(s, a, 0));
    const r = try toBool(s, &rhs_b, try lower(s, &rhs_b, bin.rhs));
    try control.br(s, &rhs_b, blk, r);
    var short_b = b.child();
    try control.br(s, &short_b, blk, .fromIntern(if (is_and) .zero else .one));
    const cb = if (is_and)
        try s.air.addCondBr(s.gpa, a, rhs_b.insts.items, short_b.insts.items)
    else
        try s.air.addCondBr(s.gpa, a, short_b.insts.items, rhs_b.insts.items);
    try s.air.setBody(s.gpa, blk, .integer_type, &.{cb});
    try b.insts.append(s.arena, blk);
    return .{ .ref = .fromIndex(blk), .ty = .integer };
}

/// §4.2.12 `c ? x : y`: only the arm taken runs; the result is of the two
/// arms' unified type.
fn ternary(s: *Sema, b: *Block, t: Inst.Triple) Allocator.Error!Value {
    const c = try toBool(s, b, try lower(s, b, t.a));
    if (constOf(s, c)) |k| return lower(s, b, if (k.isTrue()) t.b else t.c);
    const blk = try s.air.addInst(s.gpa, .{ .tag = .block, .data = undefined });
    const rt: u32 = @intFromBool(!@import("op.zig").isStatic(s, c, 0));
    var then_b = b.child();
    then_b.conditional += 1;
    then_b.runtime += rt;
    var else_b = b.child();
    else_b.conditional += 1;
    else_b.runtime += rt;
    const x = try lower(s, &then_b, t.b);
    const y = try lower(s, &else_b, t.c);
    const ty = unify(x.ty, y.ty);
    try control.br(s, &then_b, blk, try coerce(s, &then_b, x, ty));
    try control.br(s, &else_b, blk, try coerce(s, &else_b, y, ty));
    const cb = try s.air.addCondBr(s.gpa, c, then_b.insts.items, else_b.insts.items);
    try s.air.setBody(s.gpa, blk, switch (ty) {
        .real => .real_type,
        .integer => .integer_type,
        .string => .string_type,
    }, &.{cb});
    try b.insts.append(s.arena, blk);
    return .{ .ref = .fromIndex(blk), .ty = ty };
}

/// A `call` whose callee is a name: an access function (`V(p)`), or a
/// user function.
fn callExpr(s: *Sema, b: *Block, c: Inst.Call, src: Inst.Ref) Allocator.Error!Value {
    const vir = b.unit.vir;
    const callee = c.callee.toIndex() orelse return poison;
    switch (vir.instructions.items(.tag)[@backingInt(callee)]) {
        .str_ref => {
            const name = vir.string(vir.instructions.items(.data)[@backingInt(callee)].str_tok.start);
            if (try contrib.accessOf(s, b, name)) |_| return contrib.access(s, b, name, vir.list(Inst.Ref, c.args), src);
            return refuse(s, b, src, name);
        },
        .decl_ref => {
            const f = decl.canonical(vir, vir.instructions.items(.data)[@backingInt(callee)].decl_tok.decl);
            if (vir.instructions.items(.tag)[@backingInt(f)] != .function) return refuse(s, b, src, "a call of a name that is no function");
            return @import("func.zig").call(s, b, f, &.{}, vir.list(Inst.Ref, c.args), src);
        },
        else => return refuse(s, b, src, "a call"),
    }
}
