//! §4.7 analog user functions (Zig's inline `analyzeCall`; the old
//! `analog/func.zig`): a call of a user function in, its body inlined at
//! the call out. Each formal is a fresh slot (an input or inout one holds
//! the actual's value, an output one starts at 0), the function's name a
//! slot for its value; the body runs inside a `block` a `return` leaves;
//! after it, each output and inout formal's value is assigned back to its
//! actual. A function that reaches itself is E0510; a call with the wrong
//! number of arguments E0511; a call of a function not declared `analog`
//! E0436; a contribution inside one E0405.
//! Cites: VAMS-2023 §4.7, §4.7.1, §4.7.2, §4.7.2.3.
//!
//! Contents:
//! - `pub fn call(s: *Sema, b: *Block, f: Inst.Index, pre: []const Value, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const expr = @import("expr.zig");
const control = @import("control.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Block = Sema.Block;
const Value = Sema.Value;

/// Inlines function `f` (a `function` instruction): its leading formals
/// bound to `pre` (values the caller has, §9.17.3's `vnew` and `vold`), the
/// rest to `args`.
pub fn call(s: *Sema, b: *Block, f: Inst.Index, pre: []const Value, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value {
    const unit = b.unit;
    const vir = unit.vir;
    const file = unit.file;
    const fd = decl.payloadOf(vir, Inst.Function, f);
    const name = vir.string(fd.name);
    for (s.inlining.items) |g| if (g == f) {
        try s.fail(.E0510, file, src, "`{s}`", .{name});
        return expr.poison;
    };
    if (!fd.flags.analog) try s.fail(.E0436, file, src, "`{s}`", .{name});
    const formals = vir.body(fd.formals);
    if (formals.len != pre.len + args.len) {
        try s.fail(.E0511, file, src, "`{s}()` takes {d}, got {d}", .{ name, formals.len, pre.len + args.len });
        return expr.poison;
    }
    // The actuals, in the caller's scope, before any formal is bound.
    const slots = try s.arena.alloc(Sema.Slot, formals.len);
    const dirs = try s.arena.alloc(Inst.Direction, formals.len);
    for (formals, slots, dirs, 0..) |formal, *slot, *dir, k| {
        const io = decl.payloadOf(vir, Inst.Io, formal);
        dir.* = io.flags.dir;
        const ty = formalTy(vir, fd, formal, io);
        slot.* = .{ .alloc = try decl.addAlloc(s, ty), .ty = ty };
        const v: Air.Inst.Ref = if (dir.* == .output)
            zeroOf(ty)
        else
            try expr.coerce(s, b, if (k < pre.len) pre[k] else try expr.lower(s, b, args[k - pre.len]), ty);
        _ = try s.addInst(b, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slot.alloc), .rhs = v } } });
    }
    // §4.7.1 "if unspecified, the default is real".
    const ret_ty: Sema.Ty = if (fd.flags.storage == .none) .real else decl.tyOf(fd.flags.storage);
    const ret: Sema.Slot = .{ .alloc = try decl.addAlloc(s, ret_ty), .ty = ret_ty };
    _ = try s.addInst(b, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(ret.alloc), .rhs = zeroOf(ret_ty) } } });
    for (formals, slots) |formal, slot| try unit.binds.put(s.arena, decl.canonical(vir, formal), .{ .slot = slot });
    try unit.binds.put(s.arena, decl.canonical(vir, f), .{ .slot = ret });

    try s.inlining.append(s.arena, f);
    defer _ = s.inlining.pop();
    const exit = try s.air.addInst(s.gpa, .{ .tag = .block, .data = undefined });
    var fb = b.child();
    fb.loop = null;
    fb.function = exit;
    try control.body(s, &fb, fd.body);
    try control.br(s, &fb, exit, .none);
    try s.air.setBody(s.gpa, exit, .none, fb.insts.items);
    try b.insts.append(s.arena, exit);

    const result = try s.addInst(b, .{ .tag = .load, .data = .{ .un_op = .fromIndex(ret.alloc) } });
    for (args, slots[pre.len..], dirs[pre.len..]) |a, slot, dir| {
        if (dir != .output and dir != .inout) continue;
        const v = try s.addInst(b, .{ .tag = .load, .data = .{ .un_op = .fromIndex(slot.alloc) } });
        try control.assignTo(s, b, a, .{ .ref = v, .ty = slot.ty }, src);
    }
    return .{ .ref = result, .ty = ret_ty };
}

// ---- private ----

/// A formal's type: its own declaration's, or a variable of its name in the
/// body (`input x; real x;`); real when none says.
fn formalTy(vir: *const Vir, fd: Inst.Function, formal: Inst.Index, io: Inst.Io) Sema.Ty {
    if (io.flags.storage != .none) return decl.tyOf(io.flags.storage);
    const first = decl.canonical(vir, formal);
    for (vir.body(fd.body)) |i| {
        if (vir.instructions.items(.tag)[@backingInt(i)] != .variable or decl.canonical(vir, i) != first) continue;
        return decl.tyOf(decl.payloadOf(vir, Inst.Variable, i).flags.storage);
    }
    for (vir.body(fd.formals)) |i| {
        if (vir.instructions.items(.tag)[@backingInt(i)] != .variable or decl.canonical(vir, i) != first) continue;
        return decl.tyOf(decl.payloadOf(vir, Inst.Variable, i).flags.storage);
    }
    return .real;
}

fn zeroOf(ty: Sema.Ty) Air.Inst.Ref {
    return .fromIntern(switch (ty) {
        .real => .zero_real,
        .integer => .zero,
        .string => .zero,
    });
}
