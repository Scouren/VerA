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
//! - `pub fn localParam(s: *Sema, unit: *Unit, i: Inst.Index) Allocator.Error!void`
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
        // §3.3 Table 3-3 a literal (or a concatenation of literals) given
        // to an integral variable is its bytes, `""` one zero byte.
        // ponytail: declaration initializers only; an assignment statement's
        // literal goes through `expr.coerce` and drops a `""`.
        const literal: ?[]const u8 = if (ty == .integer and v.init.len != 0) try literalBytes(s, vir, vir.body(v.init)[vir.body(v.init).len - 1].toRef(), 0) else null;
        // A.6.2 a constant `initial` assignment lands where a declaration
        // assignment does, after it (discrete.zig's `initial`).
        const start: ?@import("eval.zig").Const = if (unit.initial.get(first)) |k| k else if (literal) |l| .{ .str = l } else if (v.init.len != 0) try decl.foldBody(s, unit, v.init) else null;
        const has_init = v.init.len != 0 or unit.initial.contains(first);
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
            if (mode == .zero and !has_init and bind == .slot) try s.entry.append(s.arena, try s.air.addInst(s.gpa, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(bind.slot.alloc), .rhs = .fromIntern(if (ty == .real) .zero_real else .zero) } } }));
        }
        if (unit.held.contains(first)) {
            // §3.2.2 a held array's initializer is the flat per-slot
            // aggregate `state.zig`'s `writeInit` already reads by
            // `agg.elems[k]`; a scalar's is its own folded value.
            const init: InternPool.Index = switch (bind) {
                .array => |a| try arrayPatternInit(s, unit, v.init, a.slots.len),
                else => if (start) |k| try decl.intern(s, k) else .undef,
            };
            try addHeld(s, try std.fmt.allocPrint(s.arena, "{s}{s}", .{ unit.prefix, vir.string(v.name) }), bind, init);
        } else if (has_init and bind == .slot) {
            // §3.2 a variable no evaluation leaves for the next starts each
            // one from its initializer (its folded value when it folds).
            var eb: Block = .{ .parent = null, .unit = unit };
            const init = vir.body(v.init);
            const expr = @import("expr.zig");
            const val: Sema.Value = if (start) |k| switch (k) {
                .int => .{ .ref = .fromIntern(try decl.intern(s, k)), .ty = .integer },
                .real => .{ .ref = .fromIntern(try decl.intern(s, k)), .ty = .real },
                .str => if (ty == .string)
                    .{ .ref = .fromIntern(try decl.intern(s, k)), .ty = .string }
                else
                    .{ .ref = .fromIntern(try decl.intern(s, .{ .int = @import("std_kernels").fold.strToInt(k.str, if (v.flags.storage == .integer) 32 else 64) })), .ty = .integer },
            } else try expr.lower(s, &eb, init[init.len - 1].toRef());
            const r = try expr.coerce(s, &eb, val, bind.slot.ty);
            _ = try s.addInst(&eb, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(bind.slot.alloc), .rhs = r } } });
            try s.entry.appendSlice(s.arena, eb.insts.items);
        } else if (has_init and bind == .array) {
            // §3.2.2/§3.4.4 a non-held array's `'{...}` initializer (nested,
            // for a multi-dimensional array): one store per element, redone
            // every evaluation, exactly as a scalar's initializer above.
            var eb: Block = .{ .parent = null, .unit = unit };
            const expr = @import("expr.zig");
            var elems: std.ArrayList(Inst.Ref) = .empty;
            const init = vir.body(v.init);
            if (init.len != 0) try flattenPattern(vir, init[init.len - 1].toRef(), &elems, s.arena, 0);
            // ponytail: a shape mismatch (the parser/elaborator's to refuse,
            // not Sema's) drops the initializer rather than mis-assigning.
            if (elems.items.len == bind.array.slots.len) {
                for (elems.items, bind.array.slots) |el, slot| {
                    const val = try expr.lower(s, &eb, el);
                    const r = try expr.coerce(s, &eb, val, bind.array.ty);
                    _ = try s.addInst(&eb, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slot), .rhs = r } } });
                }
                try s.entry.appendSlice(s.arena, eb.insts.items);
            }
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

/// §3.4.1/§4.7.2 a parameter declared in a named block or an analog
/// function: its default folded in the instance, in its declared type, bound
/// as a constant (no model card reaches it). One that does not fold is no
/// binding (the read refuses it).
pub fn localParam(s: *Sema, unit: *Unit, i: Inst.Index) Allocator.Error!void {
    const vir = unit.vir;
    // A paramset's own parameter is already its card row (param.zig).
    if (unit.binds.contains(decl.canonical(vir, i))) return;
    const p = decl.payloadOf(vir, Inst.Param, i);
    const c = (try decl.foldBody(s, unit, p.value)) orelse return;
    const typed: @import("eval.zig").Const = switch (p.flags.storage) {
        .real, .realtime => .{ .real = c.asReal() },
        .integer, .time => .{ .int = c.asIntExact() orelse return },
        .none, .reg, .string => c,
    };
    try unit.binds.put(s.arena, decl.canonical(vir, i), .{ .constant = try decl.intern(s, typed) });
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

// ---- private ----

/// Flattens a §3.4.4 assignment pattern `'{...}` (nested, for a
/// multi-dimensional array) into its leaf element refs, in the same
/// declaration order `array.zig`'s own flat index uses (the first-declared
/// bound of each dimension is element 0), so `out[k]` is `arr.slots[k]`'s
/// initializer. A non-pattern `r` is one leaf. Bounded like every other
/// Vir walk here (`depth_max`-class recursion on input-controlled nesting).
fn flattenPattern(vir: *const vams.Vir, r: Inst.Ref, out: *std.ArrayList(Inst.Ref), arena: Allocator, depth: u32) Allocator.Error!void {
    if (depth > 64) return;
    const i = r.toIndex() orelse return out.append(arena, r);
    if (vir.instructions.items(.tag)[@backingInt(i)] != .pattern) return out.append(arena, r);
    for (vir.list(Inst.Ref, decl.payloadOf(vir, Inst.Refs, i))) |el| try flattenPattern(vir, el, out, arena, depth + 1);
}

/// A held array's `'{...}` initializer as the flat `.aggregate`
/// `state.zig`'s `writeInit` indexes by `agg.elems[k]`: `want` elements
/// (the array's own slot count), each folded (`.undef` when it does not).
/// `.undef` for an empty body or a shape `want` does not match, same as no
/// initializer at all.
fn arrayPatternInit(s: *Sema, unit: *Unit, init: vams.Vir.Body, want: usize) Allocator.Error!InternPool.Index {
    const vir = unit.vir;
    const body = vir.body(init);
    if (body.len == 0) return .undef;
    var refs: std.ArrayList(Inst.Ref) = .empty;
    try flattenPattern(vir, body[body.len - 1].toRef(), &refs, s.arena, 0);
    if (refs.items.len != want) return .undef;
    const elems = try s.arena.alloc(InternPool.Index, refs.items.len);
    for (refs.items, elems) |r, *e| e.* = if (try decl.foldRef(s, unit, r)) |c| try decl.intern(s, c) else .undef;
    const agg = try s.zcu.intern_pool.get(s.gpa, .{ .aggregate = .{ .ty = .none, .elems = elems } });
    assert(agg != .none);
    return agg;
}

/// The bytes of `r` when it is a string literal or a concatenation of
/// them (the old `strLitBytes`), `""` as one zero byte; else null.
fn literalBytes(s: *Sema, vir: *const vams.Vir, r: Inst.Ref, depth: u32) Allocator.Error!?[]const u8 {
    const i = r.toIndex() orelse return null;
    if (depth > 64) return null;
    switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .str => {
            const x = vir.instructions.items(.data)[@backingInt(i)].str;
            return if (x.len == 0) "\x00" else vir.string_bytes[@backingInt(x.start)..][0..x.len];
        },
        .concat => {
            var out: std.ArrayList(u8) = .empty;
            for (vir.list(Inst.Ref, decl.payloadOf(vir, Inst.Refs, i))) |el| try out.appendSlice(s.arena, (try literalBytes(s, vir, el, depth + 1)) orelse return null);
            return out.items;
        },
        else => return null, // else: not a literal, so no compile-time bytes
    }
}
