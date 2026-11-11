//! Conditional and loop statements (Zig's `zirCondbr`, `zirLoop`): an
//! `if`, `while`/`for` or `repeat` of the instance a `Block` reads in, its
//! structured `Air` appended to the block out. An `if` is a `block` holding
//! a `cond_br` whose arms `br` out of it; a loop is a `block` holding a
//! `loop` whose body tests the condition, runs the statements inside an
//! inner `block` a `continue` leaves, then the step, and `repeat`s.
//! Cites: VAMS-2023 §5.8.1, §5.9.1, §5.9.3, §5.9.4.
//!
//! Contents:
//! - `pub fn lower(s: *Sema, b: *Block, x: Inst.CondBr) Allocator.Error!void`
//! - `pub fn loop(s: *Sema, b: *Block, x: Inst.Loop) Allocator.Error!void`
//! - `pub fn repeat(s: *Sema, b: *Block, x: Inst.Repeat) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const expr = @import("expr.zig");
const op = @import("op.zig");
const control = @import("control.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Block = Sema.Block;

/// §5.8.1 `if (c) a else b`.
pub fn lower(s: *Sema, b: *Block, x: Inst.CondBr) Allocator.Error!void {
    const c = try expr.toBool(s, b, try expr.lower(s, b, x.cond));
    const rt: u32 = @intFromBool(!op.isStatic(s, c, 0));
    var then_b = b.child();
    then_b.conditional += 1;
    then_b.runtime += rt;
    try control.body(s, &then_b, x.then);
    var else_b = b.child();
    else_b.conditional += 1;
    else_b.runtime += rt;
    try control.body(s, &else_b, x.@"else");
    try control.ifElse(s, b, c, &then_b, &else_b);
}

/// §5.9.3/§5.9.4 `while (c) s` and `for (i; c; step) s` (the init is the
/// statement before): `block { loop { c; cond_br(c, { block { s }; step;
/// repeat }, { br out }) } }`.
pub fn loop(s: *Sema, b: *Block, x: Inst.Loop) Allocator.Error!void {
    const vir = b.unit.vir;
    const exit = try s.air.addInst(s.gpa, .{ .tag = .block, .data = undefined });
    const lp = try s.air.addInst(s.gpa, .{ .tag = .loop, .data = undefined });
    const cont = try s.air.addInst(s.gpa, .{ .tag = .block, .data = undefined });
    var head = b.child();
    head.conditional += 1;
    head.runtime += 1;
    const cond_insts = vir.body(x.cond);
    const c: Air.Inst.Ref = if (cond_insts.len == 0) .fromIntern(.one) else try expr.toBool(s, &head, try expr.lower(s, &head, cond_insts[cond_insts.len - 1].toRef()));
    var inner = head.child();
    inner.loop = .{ .exit = exit, .cont = cont };
    try control.body(s, &inner, x.body);
    try control.br(s, &inner, cont, .none);
    try s.air.setBody(s.gpa, cont, .none, inner.insts.items);
    var go = head.child();
    try go.insts.append(s.arena, cont);
    try control.body(s, &go, x.step);
    const again = try s.air.addInst(s.gpa, .{ .tag = .repeat, .data = .{ .repeat = .{ .loop_inst = lp } } });
    try go.insts.append(s.arena, again);
    var stop = head.child();
    try control.br(s, &stop, exit, .none);
    const cb = try s.air.addCondBr(s.gpa, c, go.insts.items, stop.insts.items);
    try head.insts.append(s.arena, cb);
    try s.air.setBody(s.gpa, lp, .none, head.insts.items);
    try s.air.setBody(s.gpa, exit, .none, &.{lp});
    try b.insts.append(s.arena, exit);
}

/// §5.9.1 `repeat (n) s`: `n` once, then a loop over a counter slot.
pub fn repeat(s: *Sema, b: *Block, x: Inst.Repeat) Allocator.Error!void {
    const n = try expr.coerce(s, b, try expr.lower(s, b, x.count), .integer);
    const counter = try decl.addAlloc(s, .integer);
    _ = try s.addInst(b, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(counter), .rhs = n } } });
    const exit = try s.air.addInst(s.gpa, .{ .tag = .block, .data = undefined });
    const lp = try s.air.addInst(s.gpa, .{ .tag = .loop, .data = undefined });
    const cont = try s.air.addInst(s.gpa, .{ .tag = .block, .data = undefined });
    var head = b.child();
    head.conditional += 1;
    const k = try s.addInst(&head, .{ .tag = .load, .data = .{ .un_op = .fromIndex(counter) } });
    const c = try s.addInst(&head, .{ .tag = .igt, .data = .{ .bin_op = .{ .lhs = k, .rhs = .fromIntern(.zero) } } });
    var inner = head.child();
    inner.loop = .{ .exit = exit, .cont = cont };
    try control.body(s, &inner, x.body);
    try control.br(s, &inner, cont, .none);
    try s.air.setBody(s.gpa, cont, .none, inner.insts.items);
    var go = head.child();
    try go.insts.append(s.arena, cont);
    const k1 = try s.addInst(&go, .{ .tag = .load, .data = .{ .un_op = .fromIndex(counter) } });
    const dec = try s.addInst(&go, .{ .tag = .isub, .data = .{ .bin_op = .{ .lhs = k1, .rhs = .fromIntern(.one) } } });
    _ = try s.addInst(&go, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(counter), .rhs = dec } } });
    const again = try s.air.addInst(s.gpa, .{ .tag = .repeat, .data = .{ .repeat = .{ .loop_inst = lp } } });
    try go.insts.append(s.arena, again);
    var stop = head.child();
    try control.br(s, &stop, exit, .none);
    const cb = try s.air.addCondBr(s.gpa, c, go.insts.items, stop.insts.items);
    try head.insts.append(s.arena, cb);
    try s.air.setBody(s.gpa, lp, .none, head.insts.items);
    try s.air.setBody(s.gpa, exit, .none, &.{lp});
    try b.insts.append(s.arena, exit);
}
