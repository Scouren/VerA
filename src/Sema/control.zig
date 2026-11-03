//! Statements and control flow (Zig's `zirBlock`, `zirCondbr`, `zirLoop`):
//! one Vir body of the instance a `Block` reads in, its statements appended
//! to the block as structured `Air` out. An `if` is a `block` holding a
//! `cond_br` whose arms `br` out of it; a loop is a `block` holding a
//! `loop` whose body tests the condition, runs the statements inside an
//! inner `block` a `continue` leaves, then the step, and `repeat`s; a
//! `case` is a chain of `if`s. A variable is a slot: an assignment is an
//! `assign` of the value coerced to the slot's type (§5.7).
//! Cites: VAMS-2023 §5.2, §5.3, §5.7, §5.8.1, §5.8.2, §5.8.3, §5.9.1-§5.9.4,
//! A.6.
//!
//! Contents:
//! - `pub fn body(s: *Sema, b: *Block, vb: Vir.Body) Allocator.Error!void`
//! - `pub fn br(s: *Sema, b: *Block, target: Air.Inst.Index, operand: Air.Inst.Ref) Allocator.Error!void`
//! - `pub fn ifElse(s: *Sema, b: *Block, cond: Air.Inst.Ref, then_b: *Block, else_b: *Block) Allocator.Error!void`
//! - `pub fn assignTo(s: *Sema, b: *Block, lhs_ref: Inst.Ref, v: Sema.Value, src: Inst.Ref) Allocator.Error!void`
//! - `pub fn operands(s: *Sema, vir: *const Vir, i: Inst.Index, out: *std.AutoHashMapUnmanaged(Inst.Index, void)) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const expr = @import("expr.zig");
const contrib = @import("contrib.zig");
const syscall = @import("syscall.zig");
const op = @import("op.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Block = Sema.Block;

/// Lowers the statements of `vb` into `b`, in order. An expression is
/// lowered where a statement reads it, so only statements are walked: a
/// statement tag, or a call nothing in the body reads (a task enable).
pub fn body(s: *Sema, b: *Block, vb: Vir.Body) Allocator.Error!void {
    const vir = b.unit.vir;
    const insts = vir.body(vb);
    var used: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
    for (insts) |i| try operands(s, vir, i, &used);
    for (insts) |i| {
        if (b.dead) return;
        const tag = vir.instructions.items(.tag)[@backingInt(i)];
        if ((tag == .call or tag == .call_sys) and !used.contains(i)) {
            try task(s, b, i);
            continue;
        }
        try stmt(s, b, i, tag);
    }
}

/// Appends `br` out of `target` with `operand` (`.none` for none).
pub fn br(s: *Sema, b: *Block, target: Air.Inst.Index, operand: Air.Inst.Ref) Allocator.Error!void {
    if (b.dead) return;
    const i = try s.air.addInst(s.gpa, .{ .tag = .br, .data = .{ .br = .{ .block_inst = target, .operand = operand } } });
    try b.insts.append(s.arena, i);
    assert(b.insts.items.len != 0);
}

/// Appends `if (cond) then_b else else_b` to `b`: both children are open
/// (no `br` yet) and are closed here.
pub fn ifElse(s: *Sema, b: *Block, cond: Air.Inst.Ref, then_b: *Block, else_b: *Block) Allocator.Error!void {
    assert(then_b.parent == b);
    assert(else_b.parent == b);
    const blk = try s.air.addInst(s.gpa, .{ .tag = .block, .data = undefined });
    try br(s, then_b, blk, .none);
    try br(s, else_b, blk, .none);
    const cb = try s.air.addCondBr(s.gpa, cond, then_b.insts.items, else_b.insts.items);
    try s.air.setBody(s.gpa, blk, .none, &.{cb});
    try b.insts.append(s.arena, blk);
}

/// Adds every instruction `i` reads as an operand to `out` (its payload's
/// `Ref` and `List(Ref)` fields; a body is not an operand).
pub fn operands(s: *Sema, vir: *const Vir, i: Inst.Index, out: *std.AutoHashMapUnmanaged(Inst.Index, void)) Allocator.Error!void {
    const data = vir.instructions.items(.data)[@backingInt(i)];
    switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        inline else => |t| switch (comptime Inst.dataKind(t)) {
            .un_node => if (data.un_node.operand.toIndex()) |o| try out.put(s.arena, o, {}),
            .pl_node => {
                const P = Inst.Payload(t);
                if (P == void) return;
                const p = vir.extraData(P, data.pl_node.payload_index);
                inline for (@typeInfo(P).@"struct".field_names) |name| {
                    const F = @FieldType(P, name);
                    if (F == Inst.Ref) {
                        if (@field(p, name).toIndex()) |o| try out.put(s.arena, o, {});
                    } else if (F == Vir.List(Inst.Ref)) {
                        for (vir.list(Inst.Ref, @field(p, name))) |r| if (r.toIndex()) |o| try out.put(s.arena, o, {});
                    }
                }
            },
            .str_tok, .decl_tok, .int, .float, .str => {},
        },
    }
}

/// §5.7 `lhs = v` to a variable's slot.
pub fn assignTo(s: *Sema, b: *Block, lhs_ref: Inst.Ref, v: Sema.Value, src: Inst.Ref) Allocator.Error!void {
    const vir = b.unit.vir;
    const lhs = lhs_ref.toIndex() orelse return;
    if (vir.instructions.items(.tag)[@backingInt(lhs)] != .decl_ref)
        return s.fail(.E0512, b.unit.file, src, "an assignment to a select is not lowered by Sema yet", .{});
    const first = decl.canonical(vir, vir.instructions.items(.data)[@backingInt(lhs)].decl_tok.decl);
    const bind = b.unit.binds.get(first) orelse return s.fail(.E0512, b.unit.file, src, "an assignment to a name with no slot", .{});
    if (bind != .slot) return s.fail(.E0313, b.unit.file, src, "an assignment to a name that is not a variable", .{});
    const r = try expr.coerce(s, b, v, bind.slot.ty);
    if (op.isStatic(s, r, 0)) try s.static_slots.put(s.arena, bind.slot.alloc, {}) else _ = s.static_slots.remove(bind.slot.alloc);
    _ = try s.addInst(b, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(bind.slot.alloc), .rhs = r } } });
}
// ---- private ----

fn stmt(s: *Sema, b: *Block, i: Inst.Index, tag: Inst.Tag) Allocator.Error!void {
    const unit = b.unit;
    const vir = unit.vir;
    const src = i.toRef();
    switch (tag) {
        .block => try block(s, b, decl.payloadOf(vir, Inst.Block, i)),
        .condbr => try condbr(s, b, decl.payloadOf(vir, Inst.CondBr, i)),
        .case => try case(s, b, decl.payloadOf(vir, Inst.Case, i)),
        .loop => try loop(s, b, decl.payloadOf(vir, Inst.Loop, i)),
        .repeat => try repeat(s, b, decl.payloadOf(vir, Inst.Repeat, i)),
        .store => {
            const x = decl.payloadOf(vir, Inst.Bin, i);
            try assignTo(s, b, x.lhs, try expr.lower(s, b, x.rhs), src);
        },
        .ret => {
            const target = b.function orelse return s.fail(.E0512, unit.file, src, "`return` outside a function", .{});
            const r = vir.instructions.items(.data)[@backingInt(i)].un_node.operand;
            if (r != .none) try s.fail(.E0512, unit.file, src, "`return` with a value is not lowered by Sema yet", .{});
            try br(s, b, target, .none);
            b.dead = true;
        },
        .contrib => try contrib.contribute(s, b, decl.payloadOf(vir, Inst.Bin, i), src),
        .brk, .cont => {
            const l = b.loop orelse return s.fail(.E0512, unit.file, src, "`{s}` outside a loop", .{if (tag == .brk) "break" else "continue"});
            try br(s, b, if (tag == .brk) l.exit else l.cont, .none);
            // What follows a jump in the same body never runs.
            b.dead = true;
        },
        .variable => try local(s, b, i),
        .param, .event => {},
        .event_wait => try eventWait(s, b, decl.payloadOf(vir, Inst.EventWait, i), src),
        .store_nb, .proc_assign, .force, .store_timed, .store_nb_timed, .contrib_indirect, .deassign, .release, .trigger, .disable, .wait, .delay => try s.fail(.E0512, unit.file, src, "`{t}` is not lowered by Sema yet", .{tag}),
        // An expression: lowered where its statement reads it.
        .decl_ref, .str_ref, .int, .big_int, .real, .str, .pos, .neg, .not, .bit_not, .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor, .add, .sub, .mul, .div, .mod, .pow, .shl, .shr, .ashl, .ashr, .lt, .gt, .lte, .gte, .eq, .neq, .case_eq, .case_neq, .bit_and, .bit_or, .bit_xor, .bit_xnor, .bool_and, .bool_or, .ternary, .mintypmax, .field, .elem, .slice, .slice_up, .slice_down, .call, .call_sys, .port_branch, .concat, .pattern, .replicate, .pattern_repl, .event_or, .posedge, .negedge, .driver_update, .step_event, .paramset_output, .range, .pulse_limits, .delay_ctl, .event_ctl, .repeat_ctl => {},
        .module, .nature, .discipline, .paramset, .primitive, .connectrules, .config, .port, .io, .net, .aliasparam, .genvar, .branch, .instance, .assign, .defparam, .analog, .analog_initial, .initial, .always, .function, .gen_for, .gen_if, .gen_case, .gen_block, .specify, .path, .timing_check, .pulse_style, .timing_event, .ps_override, .connect_resolve, .connect_insert => try s.fail(.E0512, unit.file, src, "`{t}` in an analog body", .{tag}),
    }
}

/// A task enable: a system task, or a user task.
fn task(s: *Sema, b: *Block, i: Inst.Index) Allocator.Error!void {
    const vir = b.unit.vir;
    if (vir.instructions.items(.tag)[@backingInt(i)] == .call_sys) return syscall.task(s, b, decl.payloadOf(vir, Inst.SysCall, i), i.toRef());
    try s.fail(.E0512, b.unit.file, i.toRef(), "a user task enable is not lowered by Sema yet", .{});
}

/// A.6.3 `begin ... end`: its locals, then its statements.
fn block(s: *Sema, b: *Block, x: Inst.Block) Allocator.Error!void {
    if (x.flags.fork) return s.fail(.E0512, b.unit.file, .none, "a `fork` block in an analog body", .{});
    const outer = b.path;
    defer b.path = outer;
    if (x.name != .empty) b.path = try std.fmt.allocPrint(s.arena, "{s}{s}.", .{ outer, b.unit.vir.string(x.name) });
    try body(s, b, x.body);
}

/// §5.10 `@(event) s`: the event's flag guards `s`.
fn eventWait(s: *Sema, b: *Block, x: Inst.EventWait, src: Inst.Ref) Allocator.Error!void {
    const file = b.unit.file;
    if (b.in_event) return s.fail(.E0703, file, src, "", .{});
    if (b.conditional != 0) try s.fail(.E0707, file, src, "", .{});
    const c = (try eventExpr(s, b, x.event, src)) orelse return;
    var then_b = b.child();
    then_b.conditional += 1;
    then_b.runtime += 1;
    then_b.in_event = true;
    try body(s, &then_b, x.body);
    var else_b = b.child();
    try ifElse(s, b, c, &then_b, &else_b);
}

/// An event expression's flag: §5.10.2 `initial_step`/`final_step`, a
/// §5.10.3 monitored event, `or` of two.
fn eventExpr(s: *Sema, b: *Block, r: vams.Vir.Inst.Ref, src: Inst.Ref) Allocator.Error!?Air.Inst.Ref {
    const vir = b.unit.vir;
    const i = r.toIndex() orelse {
        try s.fail(.E0706, b.unit.file, src, "", .{});
        return null;
    };
    switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .event_or => {
            const x = decl.payloadOf(vir, Inst.Bin, i);
            const l = (try eventExpr(s, b, x.lhs, src)) orelse return null;
            const r2 = (try eventExpr(s, b, x.rhs, src)) orelse return null;
            return try expr.binOp(s, b, .logor, l, r2);
        },
        .step_event => {
            const x = decl.payloadOf(vir, Inst.StepEvent, i);
            const names = vir.list(Vir.String, x.analyses);
            const args = try s.arena.alloc(Air.Inst.Ref, names.len);
            for (names, args) |n, *a| a.* = .fromIntern(try decl.intern(s, .{ .str = vir.string(n) }));
            const tag: vams.SysFn.Tag = if (x.flags.final) .final_step else .initial_step;
            return try expr.call(s, b, @backingInt(tag), .integer, args);
        },
        .call_sys => {
            const c = decl.payloadOf(vir, Inst.SysCall, i);
            const name = vir.string(c.name);
            const tag = vams.SysFn.Tag.fromName(name) orelse {
                try s.fail(.E0706, b.unit.file, src, "", .{});
                return null;
            };
            if (vams.SysFn.get(tag).family != .event) {
                try s.fail(.E0706, b.unit.file, src, "", .{});
                return null;
            }
            const vargs = vir.list(Inst.Ref, c.args);
            const args = try s.arena.alloc(Air.Inst.Ref, vargs.len);
            for (vargs, args) |a, *o| o.* = if (a == .none) .fromIntern(.zero_real) else try expr.coerce(s, b, try expr.lower(s, b, a), .real);
            return try expr.call(s, b, @backingInt(tag), .integer, args);
        },
        .posedge, .negedge => {
            try s.fail(.E0704, b.unit.file, src, "", .{});
            return null;
        },
        else => {
            try s.fail(.E0512, b.unit.file, src, "this event expression is not lowered by Sema yet", .{});
            return null;
        },
    }
}

/// A §3.2 variable declared in a block: a slot of its own.
fn local(s: *Sema, b: *Block, i: Inst.Index) Allocator.Error!void {
    const vir = b.unit.vir;
    const v = decl.payloadOf(vir, Inst.Variable, i);
    const first = decl.canonical(vir, i);
    if (b.unit.binds.contains(first)) return;
    if (v.dims.len != 0) return s.fail(.E0512, b.unit.file, i.toRef(), "a local array is not lowered by Sema yet", .{});
    const ty = decl.tyOf(v.flags.storage);
    const slot = try decl.addAlloc(s, ty);
    try b.unit.binds.put(s.arena, first, .{ .slot = .{ .alloc = slot, .ty = ty } });
    // §5.3.2 a held local of a named block is named by the block path.
    if (b.path.len != 0 and b.unit.held.contains(first)) try s.device.held.append(s.gpa, .{
        .name = try s.zcu.intern_pool.getString(s.gpa, try std.fmt.allocPrint(s.arena, "{s}{s}{s}", .{ b.unit.prefix, b.path, vir.string(v.name) })),
        .slot = slot,
    });
}

/// §5.8.1 `if (c) a else b`.
fn condbr(s: *Sema, b: *Block, x: Inst.CondBr) Allocator.Error!void {
    const c = try expr.toBool(s, b, try expr.lower(s, b, x.cond));
    const rt: u32 = @intFromBool(!op.isStatic(s, c, 0));
    var then_b = b.child();
    then_b.conditional += 1;
    then_b.runtime += rt;
    try body(s, &then_b, x.then);
    var else_b = b.child();
    else_b.conditional += 1;
    else_b.runtime += rt;
    try body(s, &else_b, x.@"else");
    try ifElse(s, b, c, &then_b, &else_b);
}

/// §5.8.3 `case`: the subject once, then each arm's labels in order, the
/// first equal one's statements run; `default` when none is.
fn case(s: *Sema, b: *Block, x: Inst.Case) Allocator.Error!void {
    const vir = b.unit.vir;
    if (x.flags.kind != .case) return s.fail(.E0512, b.unit.file, .none, "`casex`/`casez` in an analog body", .{});
    const subject = try expr.lower(s, b, x.operand);
    const arms = vir.list(Inst.Arm, x.arms);
    var default: ?Inst.Arm = null;
    for (arms) |a| if (a.flags.default) {
        default = a;
    };
    try caseFrom(s, b, subject, arms, default, 0);
}

/// The arms from `k` on, as nested `if`s.
fn caseFrom(s: *Sema, b: *Block, subject: Sema.Value, arms: []const Inst.Arm, default: ?Inst.Arm, k: usize) Allocator.Error!void {
    var at = k;
    while (at < arms.len and arms[at].flags.default) at += 1;
    if (at == arms.len) {
        if (default) |d| try body(s, b, d.body);
        return;
    }
    const arm = arms[at];
    var hit: ?Air.Inst.Ref = null;
    for (b.unit.vir.list(Inst.Ref, arm.values)) |label| {
        const l = try expr.lower(s, b, label);
        const real = subject.ty == .real or l.ty == .real;
        const ty: Sema.Ty = if (real) .real else .integer;
        const eq = try expr.binOp(s, b, if (real) .feq else .ieq, try expr.coerce(s, b, subject, ty), try expr.coerce(s, b, l, ty));
        hit = if (hit) |h| try expr.binOp(s, b, .logor, h, eq) else eq;
    }
    const rt: u32 = @intFromBool(!op.isStatic(s, hit orelse .fromIntern(.zero), 0));
    var then_b = b.child();
    then_b.conditional += 1;
    then_b.runtime += rt;
    try body(s, &then_b, arm.body);
    var else_b = b.child();
    else_b.conditional += 1;
    else_b.runtime += rt;
    try caseFrom(s, &else_b, subject, arms, default, at + 1);
    try ifElse(s, b, hit orelse .fromIntern(.zero), &then_b, &else_b);
}

/// §5.9.3/§5.9.4 `while (c) s` and `for (i; c; step) s` (the init is the
/// statement before): `block { loop { c; cond_br(c, { block { s }; step;
/// repeat }, { br out }) } }`.
fn loop(s: *Sema, b: *Block, x: Inst.Loop) Allocator.Error!void {
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
    try body(s, &inner, x.body);
    try br(s, &inner, cont, .none);
    try s.air.setBody(s.gpa, cont, .none, inner.insts.items);
    var go = head.child();
    try go.insts.append(s.arena, cont);
    try body(s, &go, x.step);
    const again = try s.air.addInst(s.gpa, .{ .tag = .repeat, .data = .{ .repeat = .{ .loop_inst = lp } } });
    try go.insts.append(s.arena, again);
    var stop = head.child();
    try br(s, &stop, exit, .none);
    const cb = try s.air.addCondBr(s.gpa, c, go.insts.items, stop.insts.items);
    try head.insts.append(s.arena, cb);
    try s.air.setBody(s.gpa, lp, .none, head.insts.items);
    try s.air.setBody(s.gpa, exit, .none, &.{lp});
    try b.insts.append(s.arena, exit);
}

/// §5.9.1 `repeat (n) s`: `n` once, then a loop over a counter slot.
fn repeat(s: *Sema, b: *Block, x: Inst.Repeat) Allocator.Error!void {
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
    try body(s, &inner, x.body);
    try br(s, &inner, cont, .none);
    try s.air.setBody(s.gpa, cont, .none, inner.insts.items);
    var go = head.child();
    try go.insts.append(s.arena, cont);
    const k1 = try s.addInst(&go, .{ .tag = .load, .data = .{ .un_op = .fromIndex(counter) } });
    const dec = try s.addInst(&go, .{ .tag = .isub, .data = .{ .bin_op = .{ .lhs = k1, .rhs = .fromIntern(.one) } } });
    _ = try s.addInst(&go, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(counter), .rhs = dec } } });
    const again = try s.air.addInst(s.gpa, .{ .tag = .repeat, .data = .{ .repeat = .{ .loop_inst = lp } } });
    try go.insts.append(s.arena, again);
    var stop = head.child();
    try br(s, &stop, exit, .none);
    const cb = try s.air.addCondBr(s.gpa, c, go.insts.items, stop.insts.items);
    try head.insts.append(s.arena, cb);
    try s.air.setBody(s.gpa, lp, .none, head.insts.items);
    try s.air.setBody(s.gpa, exit, .none, &.{lp});
    try b.insts.append(s.arena, exit);
}
