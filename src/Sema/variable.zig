//! §3.2 the instance's module-level variables and §5.10.4 named events
//! (the old `analog/var.zig`'s declarations): each a slot (an array a run
//! of them), a held one a `device.held` row with its initializer's folded
//! value, any other assigned its initializer at entry (each evaluation
//! starts from it); an event is an integer flag, 0 at entry. A variable
//! whose name a variable, parameter or net declared first is E0362.
//! Cites: VAMS-2023 §3.2, §3.2.2, §5.10, §5.10.4, §6.8.
//!
//! Contents:
//! - `pub fn declare(s: *Sema, unit: *Unit) Allocator.Error!void`
//! - `pub fn checkRedeclared(s: *Sema, unit: *const Unit, i: Inst.Index) Allocator.Error!void`
//! - `pub fn addHeld(s: *Sema, name: []const u8, bind: Sema.Bind, init: InternPool.Index) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const attr = @import("attr.zig");
const Inst = vams.Vir.Inst;
const Unit = Sema.Unit;
const Block = Sema.Block;

/// §3.2 the instance's module-level variables: one slot each. §5.10.4 a
/// named event is an integer flag (one per element of an event array), 0 at
/// entry to every evaluation.
pub fn declare(s: *Sema, unit: *Unit) Allocator.Error!void {
    const vir = unit.vir;
    for (vir.body(unit.module.body)) |i| {
        if (vir.instructions.items(.tag)[@backingInt(i)] == .event) {
            const first = decl.canonical(vir, i);
            if (unit.binds.contains(first)) continue;
            const dims = decl.payloadOf(vir, Inst.Name, i).dims;
            if (dims.len != 0) try decl.declareArray(s, unit, first, dims, .integer) else try unit.binds.put(s.arena, first, .{ .slot = .{ .alloc = try decl.addAlloc(s, .integer), .ty = .integer } });
            const bind = unit.binds.get(first) orelse continue;
            const slots: []const Air.Inst.Index = if (bind == .array) bind.array.slots else &.{bind.slot.alloc};
            for (slots) |slot| try s.entry.append(s.arena, try s.air.addInst(s.gpa, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slot), .rhs = .fromIntern(.zero) } } }));
            continue;
        }
        if (vir.instructions.items(.tag)[@backingInt(i)] != .variable) continue;
        const v = decl.payloadOf(vir, Inst.Variable, i);
        const first = decl.canonical(vir, i);
        try checkRedeclared(s, unit, i);
        if (unit.binds.contains(first)) continue;
        const ty = decl.tyOf(v.flags.storage);
        if (v.dims.len != 0) try decl.declareArray(s, unit, first, v.dims, ty) else try unit.binds.put(s.arena, first, .{ .slot = .{ .alloc = try decl.addAlloc(s, ty), .ty = ty } });
        const bind = unit.binds.get(first) orelse continue;
        // VerA's `vera_scratch` (§2.9): no held slot, every evaluation starts
        // over; not for a value an `analog initial` or event body leaves
        // for a later read (E0536), nor a digital process's (E0537).
        var mode = try attr.scratch(s, unit, v.attrs, i.toRef());
        if (mode != .off and unit.carried.contains(first)) {
            try s.fail(.E0536, unit.file, i.toRef(), "`{s}`", .{vir.string(v.name)});
            mode = .off;
        }
        if (mode == .uninit and v.init.len != 0) {
            try s.fail(.E0539, unit.file, i.toRef(), "`{s}`", .{vir.string(v.name)});
            mode = .zero;
        }
        if (mode != .off and std.mem.findScalar(Inst.Index, unit.discrete.items, first) != null) try s.fail(.E0537, unit.file, i.toRef(), "`{s}`", .{vir.string(v.name)});
        if (mode != .off) {
            _ = unit.held.remove(first);
            if (mode == .zero and v.init.len == 0 and bind == .slot) try s.entry.append(s.arena, try s.air.addInst(s.gpa, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(bind.slot.alloc), .rhs = .fromIntern(if (ty == .real) .zero_real else .zero) } } }));
        }
        if (unit.held.contains(first)) {
            const init: InternPool.Index = if (v.init.len == 0) .undef else if (try decl.foldBody(s, unit, v.init)) |k| try decl.intern(s, k) else .undef;
            try addHeld(s, try std.fmt.allocPrint(s.arena, "{s}{s}", .{ unit.prefix, vir.string(v.name) }), bind, init);
        } else if (v.init.len != 0 and bind == .slot) {
            // §3.2 a variable no evaluation leaves for the next starts each
            // one from its initializer (its folded value when it folds).
            var eb: Block = .{ .parent = null, .unit = unit };
            const init = vir.body(v.init);
            const expr = @import("expr.zig");
            const val: Sema.Value = if (try decl.foldBody(s, unit, v.init)) |k| switch (k) {
                .int => .{ .ref = .fromIntern(try decl.intern(s, k)), .ty = .integer },
                .real => .{ .ref = .fromIntern(try decl.intern(s, k)), .ty = .real },
                .str => if (ty == .string)
                    .{ .ref = .fromIntern(try decl.intern(s, k)), .ty = .string }
                else
                    .{ .ref = .fromIntern(try decl.intern(s, .{ .int = @import("kernels").fold.strToInt(k.str, 64) })), .ty = .integer },
            } else try expr.lower(s, &eb, init[init.len - 1].toRef());
            const r = try expr.coerce(s, &eb, val, bind.slot.ty);
            _ = try s.addInst(&eb, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(bind.slot.alloc), .rhs = r } } });
            try s.entry.appendSlice(s.arena, eb.insts.items);
        }
    }
}

/// §6.8 "one identifier declares one item in a scope": a variable whose
/// name a variable, parameter or net declared first is E0362 (a port's
/// direction then its type is one item).
pub fn checkRedeclared(s: *Sema, unit: *const Unit, i: Inst.Index) Allocator.Error!void {
    const vir = unit.vir;
    const first = decl.canonical(vir, i);
    if (first == i) return;
    switch (vir.instructions.items(.tag)[@backingInt(first)]) {
        .variable, .param, .net => try s.fail(.E0362, unit.file, i.toRef(), "`{s}`", .{vir.string(decl.nameOf(vir, i))}),
        else => {}, // else: a port's direction, or a formal
    }
}

/// A §5.10 held row named `name` for a variable's (or array's) slots.
pub fn addHeld(s: *Sema, name: []const u8, bind: Sema.Bind, init: InternPool.Index) Allocator.Error!void {
    const slots: []const Air.Inst.Index = switch (bind) {
        .slot => |x| &.{x.alloc},
        .array => |a| a.slots,
        else => return,
    };
    if (slots.len == 0) return;
    // `declareArray` mints the slots back to back.
    assert(@backingInt(slots[slots.len - 1]) - @backingInt(slots[0]) == slots.len - 1);
    try s.device.held.append(s.gpa, .{ .name = try s.zcu.intern_pool.getString(s.gpa, name), .slot = slots[0], .count = @intCast(slots.len), .init = init });
}
