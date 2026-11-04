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
//! - `pub fn operands(a: Allocator, vir: *const Vir, i: Inst.Index, out: *std.AutoHashMapUnmanaged(Inst.Index, void)) Allocator.Error!void`

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
    for (insts) |i| try operands(s.arena, vir, i, &used);
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
pub fn operands(a: Allocator, vir: *const Vir, i: Inst.Index, out: *std.AutoHashMapUnmanaged(Inst.Index, void)) Allocator.Error!void {
    const data = vir.instructions.items(.data)[@backingInt(i)];
    switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        inline else => |t| switch (comptime Inst.dataKind(t)) {
            .un_node => if (data.un_node.operand.toIndex()) |o| try out.put(a, o, {}),
            .pl_node => {
                const P = Inst.Payload(t);
                if (P == void) return;
                const p = vir.extraData(P, data.pl_node.payload_index);
                inline for (@typeInfo(P).@"struct".field_names) |name| {
                    const F = @FieldType(P, name);
                    if (F == Inst.Ref) {
                        if (@field(p, name).toIndex()) |o| try out.put(a, o, {});
                    } else if (F == Vir.List(Inst.Ref)) {
                        for (vir.list(Inst.Ref, @field(p, name))) |r| if (r.toIndex()) |o| try out.put(a, o, {});
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
    if (vir.instructions.items(.tag)[@backingInt(lhs)] == .elem) {
        const array = @import("array.zig");
        const e = (try array.element(s, b, lhs_ref, src)) orelse return;
        var r = try expr.coerce(s, b, v, e.ty);
        if (b.nodiff and e.ty == .real) r = try expr.unOp(s, b, .dstop, r);
        return array.store(s, b, e, r);
    }
    if (vir.instructions.items(.tag)[@backingInt(lhs)] != .decl_ref)
        return s.fail(.E0512, b.unit.file, src, "an assignment to a select is not lowered by Sema yet", .{});
    const first = decl.canonical(vir, vir.instructions.items(.data)[@backingInt(lhs)].decl_tok.decl);
    const bind = b.unit.binds.get(first) orelse return s.fail(.E0512, b.unit.file, src, "an assignment to a name with no slot", .{});
    if (bind != .slot) return s.fail(.E0313, b.unit.file, src, "an assignment to a name that is not a variable", .{});
    var r = try expr.coerce(s, b, v, bind.slot.ty);
    if (b.nodiff and bind.slot.ty == .real) r = try expr.unOp(s, b, .dstop, r);
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
        .contrib_indirect => try contrib.indirect(s, b, decl.payloadOf(vir, Inst.Triple, i), src),
        .trigger => try trigger(s, b, vir.instructions.items(.data)[@backingInt(i)].un_node.operand, src),
        .disable => try disable(s, b, vir.instructions.items(.data)[@backingInt(i)].un_node.operand, src),
        .store_nb, .proc_assign, .force, .store_timed, .store_nb_timed, .deassign, .release, .wait, .delay => try s.fail(.E0512, unit.file, src, "`{t}` is not lowered by Sema yet", .{tag}),
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

/// A.6.3 `begin ... end`: its locals, then its statements. A named block
/// (§5.3.2) that a `disable` leaves is an Air `block`; any other is its
/// statements, in place (a value lowered there stays readable after it).
fn block(s: *Sema, b: *Block, x: Inst.Block) Allocator.Error!void {
    if (x.flags.fork) return s.fail(.E0512, b.unit.file, .none, "a `fork` block in an analog body", .{});
    // VerA's `vera_nodiff` (§2.9): every assignment inside, unless a nearer
    // spec says otherwise; a value that does not fold is E0525.
    const outer_nodiff = b.nodiff;
    defer b.nodiff = outer_nodiff;
    for (b.unit.vir.list(Inst.Attr, x.attrs)) |a| if (std.mem.eql(u8, b.unit.vir.string(a.name), "vera_nodiff")) {
        if (a.value.len == 0) {
            b.nodiff = true;
        } else if (try decl.foldBody(s, b.unit, a.value)) |c| {
            b.nodiff = c.isTrue();
        } else try s.fail(.E0525, b.unit.file, .none, "", .{});
    };
    if (x.name == .empty) return body(s, b, x.body);
    const name = b.unit.vir.string(x.name);
    const exit = try s.air.addInst(s.gpa, .{ .tag = .block, .data = undefined });
    var disabled = false;
    const label: Block.Label = .{ .name = name, .exit = exit, .up = b.label, .disabled = &disabled };
    var inner = b.child();
    inner.label = &label;
    inner.path = try std.fmt.allocPrint(s.arena, "{s}{s}.", .{ b.path, name });
    try body(s, &inner, x.body);
    if (!disabled) {
        try s.air.setBody(s.gpa, exit, .none, &.{});
        try b.insts.appendSlice(s.arena, inner.insts.items);
        b.dead = inner.dead;
        return;
    }
    try br(s, &inner, exit, .none);
    try s.air.setBody(s.gpa, exit, .none, inner.insts.items);
    try b.insts.append(s.arena, exit);
}

/// §5.10.4 `-> ev`: the event's flag set for this evaluation. A.6.4 lists
/// it under `analog_event_statement` only (E0434); a hierarchical event is
/// E0235.
fn trigger(s: *Sema, b: *Block, target: Inst.Ref, src: Inst.Ref) Allocator.Error!void {
    const vir = b.unit.vir;
    const i = target.toIndex() orelse return;
    const tag = vir.instructions.items(.tag)[@backingInt(i)];
    if (tag != .decl_ref and tag != .elem) return s.fail(.E0235, b.unit.file, src, "§5.10.4: a hierarchical named event trigger in an analog block", .{});
    if (!b.in_event) return s.fail(.E0434, b.unit.file, src, "", .{});
    try assignTo(s, b, target, .{ .ref = .fromIntern(.one), .ty = .integer }, src);
}

/// A.6.5 `disable blk`: leaves the enclosing named block `blk`; legal only
/// as an event statement (E0401), naming an enclosing block (E0402).
fn disable(s: *Sema, b: *Block, target: Inst.Ref, src: Inst.Ref) Allocator.Error!void {
    const vir = b.unit.vir;
    if (!b.in_event) return s.fail(.E0401, b.unit.file, src, "", .{});
    const i = target.toIndex() orelse return;
    const data = vir.instructions.items(.data)[@backingInt(i)];
    const name = switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .str_ref => vir.string(data.str_tok.start),
        .decl_ref => vir.string(decl.nameOf(vir, decl.canonical(vir, data.decl_tok.decl))),
        else => return s.fail(.E0402, b.unit.file, src, "a hierarchical block name", .{}),
    };
    var l = b.label;
    while (l) |label| : (l = label.up) if (std.mem.eql(u8, label.name, name)) {
        label.disabled.* = true;
        try br(s, b, label.exit, .none);
        b.dead = true;
        return;
    };
    return s.fail(.E0402, b.unit.file, src, "`{s}` names no named block in scope", .{name});
}

/// §5.10.3.1-§5.10.3.3 the shape of a monitored event's arguments (the old
/// `event_args.zig`): the required slots, the enable last and integral, the
/// tolerances and a timer's time_tol non-negative, cross's direction
/// integral (E0517). False when a required slot is missing.
fn eventArgs(s: *Sema, b: *Block, tag: vams.SysFn.Tag, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!bool {
    const file = b.unit.file;
    const required: usize = switch (tag) {
        .cross, .above, .timer => 1,
        else => 0, // else: initial_step/final_step take names, not slots
    };
    const enable: ?usize = switch (tag) {
        .cross => 4,
        .above, .timer => 3,
        else => null, // else: no enable slot
    };
    var complete = true;
    for (0..required) |k| if (k >= args.len or args[k] == .none) {
        try s.fail(.E0517, file, src, "`{t}()` requires its {s} argument", .{ tag, if (tag == .timer) "start_time" else "expr" });
        complete = false;
    };
    if (enable) |k| {
        if (k < args.len and args[k] == .none) {
            try s.fail(.E0517, file, src, "`{t}()` has a comma before its enable and no enable", .{tag});
            complete = false;
        }
        if (args.len > k + 1) {
            try s.fail(.E0517, file, src, "`{t}()` takes at most {d} arguments, got {d} (A.6.5)", .{ tag, k + 1, args.len });
            complete = false;
        }
    }
    if (!complete) return false;
    if (enable) |k| if (k < args.len) if (try decl.foldRef(s, b.unit, args[k])) |c| {
        if (c != .str and c.asReal() != @round(c.asReal())) try s.fail(.E0517, file, src, "`{t}()` enable shall evaluate to an integer, got {d}", .{ tag, c.asReal() });
    };
    switch (tag) {
        .timer => if (args.len >= 3 and args[2] != .none) if (try decl.foldRef(s, b.unit, args[2])) |c| {
            if (c != .str and c.asReal() < 0) try s.fail(.E0517, file, src, "`timer()` time_tol shall be non-negative, got {d}", .{c.asReal()});
        },
        .cross, .above => {
            if (tag == .cross and args.len > 1 and args[1] != .none) if (try decl.foldRef(s, b.unit, args[1])) |c| {
                if (c != .str and c.asReal() != @round(c.asReal())) try s.fail(.E0517, file, src, "`cross()` direction shall evaluate to an integer, got {d}", .{c.asReal()});
            };
            const first: usize = if (tag == .cross) 2 else 1;
            var tol_given = false;
            for (first..@max(first, @min(first + 2, args.len))) |k| {
                if (args[k] == .none) continue;
                tol_given = true;
                const c = (try decl.foldRef(s, b.unit, args[k])) orelse continue;
                if (c != .str and c.asReal() < 0) try s.fail(.E0517, file, src, "`{t}()` tolerance shall be non-negative, got {d}", .{ tag, c.asReal() });
            }
            // "If either or both tolerances are defined, then the direction
            // shall also be defined"; "If expr_tol is specified, time_tol shall
            // also be specified" (§5.10.3.1).
            if (tag == .cross and tol_given and (args.len < 2 or args[1] == .none)) try s.fail(.E0517, file, src, "a tolerance is given but the direction slot is empty", .{});
            if (tag == .cross and args.len > 3 and args[3] != .none and args[2] == .none) try s.fail(.E0517, file, src, "`cross()` expr_tol is given but the time_tol slot is empty", .{});
        },
        else => {}, // else: no bound to check
    }
    return true;
}

/// §5.10 `@(event) s`: the event's flag guards `s`.
fn eventWait(s: *Sema, b: *Block, x: Inst.EventWait, src: Inst.Ref) Allocator.Error!void {
    const file = b.unit.file;
    if (b.in_event) return s.fail(.E0703, file, src, "", .{});
    if (b.conditional != 0) try s.fail(.E0707, file, src, "", .{});
    // A later stage's diagnostic about the event (the testbench's W0750)
    // points at the statement, as the old driver's did.
    const outer = s.expr_src;
    s.expr_src = src;
    const event = eventExpr(s, b, x.event, src);
    s.expr_src = outer;
    const c = (try event) orelse return;
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
            if (!try eventArgs(s, b, tag, vargs, src)) return null;
            const args = try s.arena.alloc(Air.Inst.Ref, vargs.len);
            for (vargs, args, 1..) |a, *o, k| {
                if (a == .none) {
                    o.* = .fromIntern(.zero_real);
                    continue;
                }
                const v = try expr.lower(s, b, a);
                if (v.ty == .string and expr.constOf(s, v.ref) == null) {
                    try s.fail(.E0517, b.unit.file, src, "`{t}()` argument {d} is a string", .{ tag, k });
                    return null;
                }
                o.* = try expr.coerce(s, b, v, .real);
            }
            return try expr.call(s, b, @backingInt(tag), .integer, args);
        },
        .posedge, .negedge => {
            try s.fail(.E0704, b.unit.file, src, "", .{});
            return null;
        },
        // §5.10.4 a named event: its flag this evaluation.
        .decl_ref, .elem => {
            var base = i;
            while (vir.instructions.items(.tag)[@backingInt(base)] == .elem) base = decl.payloadOf(vir, Inst.Bin, base).lhs.toIndex() orelse break;
            const named = vir.instructions.items(.tag)[@backingInt(base)] == .decl_ref and
                vir.instructions.items(.tag)[@backingInt(decl.canonical(vir, vir.instructions.items(.data)[@backingInt(base)].decl_tok.decl))] == .event;
            if (!named) {
                try s.fail(.E0706, b.unit.file, src, "", .{});
                return null;
            }
            return try expr.toBool(s, b, try expr.lower(s, b, r));
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
    try @import("variable.zig").checkRedeclared(s, b.unit, i);
    if (b.unit.binds.contains(first)) return;
    if (v.dims.len != 0) return decl.declareArray(s, b.unit, first, v.dims, decl.tyOf(v.flags.storage));
    const ty = decl.tyOf(v.flags.storage);
    const slot = try decl.addAlloc(s, ty);
    try b.unit.binds.put(s.arena, first, .{ .slot = .{ .alloc = slot, .ty = ty } });
    if (b.path.len != 0) try s.block_locals.put(s.arena, try std.fmt.allocPrint(s.arena, "{s}{s}{s}", .{ b.unit.prefix, b.path, vir.string(v.name) }), .{ .alloc = slot, .ty = ty });
    // §5.3.2 a held local of a named block is named by the block path.
    if (b.path.len != 0 and b.unit.held.contains(first)) try @import("variable.zig").addHeld(s, try std.fmt.allocPrint(s.arena, "{s}{s}{s}", .{ b.unit.prefix, b.path, vir.string(v.name) }), b.unit.binds.get(first).?, .undef);
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
