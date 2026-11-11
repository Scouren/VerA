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
//! - `pub fn checkRecursion(s: *Sema, unit: *const Sema.Unit) Allocator.Error!void`
//! - `pub fn calleeOf(vir: *const Vir, i: Inst.Index) ?Inst.Index`

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

/// §4.7.3 "recursive functions are not permitted" of an analog function
/// (E0510), judged on the declarations: an uncalled recursive function is
/// still illegal (the old `checkFuncRecursion`). One reachability walk per
/// function over the module's call graph.
pub fn checkRecursion(s: *Sema, unit: *const Sema.Unit) Allocator.Error!void {
    const vir = unit.vir;
    var fns: std.ArrayList(Inst.Index) = .empty;
    for (vir.body(unit.module.body)) |i| if (vir.instructions.items(.tag)[@backingInt(i)] == .function and decl.canonical(vir, i) == i) try fns.append(s.arena, i);
    if (fns.items.len == 0) return;
    const edges = try s.arena.alloc(std.ArrayList(Inst.Index), fns.items.len);
    for (fns.items, edges) |f, *out| {
        out.* = .empty;
        try callees(s, vir, decl.payloadOf(vir, Inst.Function, f).body, out, 0);
    }
    var seen: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
    var stack: std.ArrayList(Inst.Index) = .empty;
    for (fns.items) |f| {
        const fd = decl.payloadOf(vir, Inst.Function, f);
        if (!fd.flags.analog) continue;
        seen.clearRetainingCapacity();
        stack.clearRetainingCapacity();
        try stack.append(s.arena, f);
        walk: while (stack.pop()) |g| {
            const k = std.mem.findScalar(Inst.Index, fns.items, g) orelse continue;
            for (edges[k].items) |h| {
                if (h == f) {
                    try s.fail(.E0510, unit.file, f.toRef(), "`{s}` calls itself", .{vir.string(fd.name)});
                    break :walk;
                }
                if ((try seen.getOrPut(s.arena, h)).found_existing) continue;
                try stack.append(s.arena, h);
            }
        }
    }
}

/// The function `.call` instruction `i` names, or null when the callee is
/// not a `decl_ref` to one of the module's `function`s (the old
/// `discrete_check.zig`'s private `function`, shared now that the held
/// walk (T2) needs it too).
pub fn calleeOf(vir: *const Vir, i: Inst.Index) ?Inst.Index {
    const ci = decl.payloadOf(vir, Inst.Call, i).callee.toIndex() orelse return null;
    if (vir.instructions.items(.tag)[@backingInt(ci)] != .decl_ref) return null;
    const f = decl.canonical(vir, vir.instructions.items(.data)[@backingInt(ci)].decl_tok.decl);
    return if (vir.instructions.items(.tag)[@backingInt(f)] == .function) f else null;
}

// ---- private ----

/// Appends every function body `b` calls (through nested bodies too).
fn callees(s: *Sema, vir: *const Vir, b: Vir.Body, out: *std.ArrayList(Inst.Index), depth: u32) Allocator.Error!void {
    if (depth > 1 << 10) return;
    for (vir.body(b)) |i| {
        const data = vir.instructions.items(.data)[@backingInt(i)];
        switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            .call => if (decl.payloadOf(vir, Inst.Call, i).callee.toIndex()) |c| if (vir.instructions.items(.tag)[@backingInt(c)] == .decl_ref) {
                const g = decl.canonical(vir, vir.instructions.items(.data)[@backingInt(c)].decl_tok.decl);
                if (vir.instructions.items(.tag)[@backingInt(g)] == .function) try out.append(s.arena, g);
            },
            .case => for (vir.list(Inst.Arm, decl.payloadOf(vir, Inst.Case, i).arms)) |arm| try callees(s, vir, arm.body, out, depth + 1),
            inline else => |t| if (comptime Inst.dataKind(t) == .pl_node) {
                const P = Inst.Payload(t);
                if (P != void) {
                    const p = vir.extraData(P, data.pl_node.payload_index);
                    inline for (@typeInfo(P).@"struct".field_names) |name| {
                        if (@FieldType(P, name) == Vir.Body) try callees(s, vir, @field(p, name), out, depth + 1);
                    }
                }
            },
        }
    }
}

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
