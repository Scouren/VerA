//! §6.6.1/§5.9.2 an analog `for` over a genvar (the old `analog/loop.zig`'s
//! `tryUnrollFor`): the initialization `store` to a genvar and the `loop`
//! after it in; the body lowered once per value the scheme folds to, the
//! genvar bound to that constant, out. The scheme is followed in full
//! first: a value that repeats is E0420. An initialization that does not
//! fold is E0417 (E0486 for an x or z literal), a condition E0418, an
//! iteration that assigns another name or does not fold E0419. A jump that
//! would leave the unrolled loop is E0440 (`Block.analog_for`). A genvar
//! assigned anywhere else is no variable (E0313).
//! Cites: VAMS-2023 §3.5, §5.9.2, §5.11, §6.6.1.
//!
//! Contents:
//! - `pub fn genvarStore(vir: *const Vir, i: Inst.Index) ?Inst.Index`
//! - `pub fn unroll(s: *Sema, b: *Block, init: Inst.Index, lp: ?Inst.Index) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Block = Sema.Block;

/// The most values one scheme is followed through before it is unrolled;
/// past it the scheme is taken to end (the unroll stops there too).
const values_max: u32 = 1 << 20;

/// The genvar `store` instruction `i` assigns, or null.
pub fn genvarStore(vir: *const Vir, i: Inst.Index) ?Inst.Index {
    if (vir.instructions.items(.tag)[@backingInt(i)] != .store) return null;
    const t = decl.payloadOf(vir, Inst.Bin, i).lhs.toIndex() orelse return null;
    if (vir.instructions.items(.tag)[@backingInt(t)] != .decl_ref) return null;
    const d = decl.canonical(vir, vir.instructions.items(.data)[@backingInt(t)].decl_tok.decl);
    return if (vir.instructions.items(.tag)[@backingInt(d)] == .genvar) d else null;
}

/// Unrolls `for (init; cond; step) body`, `init` a store to a genvar and
/// `lp` the `loop` after it; a store with no loop after it is E0313.
pub fn unroll(s: *Sema, b: *Block, init: Inst.Index, lp: ?Inst.Index) Allocator.Error!void {
    const unit = b.unit;
    const vir = unit.vir;
    const file = unit.file;
    const gv = genvarStore(vir, init).?;
    const name = vir.string(decl.nameOf(vir, gv));
    const loop = decl.payloadOf(vir, Inst.Loop, lp orelse return s.fail(.E0313, file, init.toRef(), "`{s}` is a genvar: only an analog `for` assigns it", .{name}));
    const first = decl.payloadOf(vir, Inst.Bin, init);
    // §6.6.1 "Both the initialization and iteration assignments shall
    // assign to the same genvar".
    const steps = vir.body(loop.step);
    const step: ?Inst.Bin = if (steps.len != 0 and genvarStore(vir, steps[steps.len - 1]) == gv) decl.payloadOf(vir, Inst.Bin, steps[steps.len - 1]) else null;
    if (step == null) return s.fail(.E0419, file, init.toRef(), "the iteration shall assign the genvar `{s}`", .{name});
    const conds = vir.body(loop.cond);
    if (conds.len == 0) return s.fail(.E0418, file, init.toRef(), "", .{});
    const cond = conds[conds.len - 1].toRef();
    defer _ = unit.binds.remove(gv);
    const start = (try decl.foldRef(s, unit, first.rhs)) orelse
        return s.fail(if (hasUnknown(vir, first.rhs, 0)) .E0486 else .E0417, file, init.toRef(), "the initialization of `{s}`", .{name});
    // §6.6.1 a scheme that never ends is refused before any body is lowered.
    var seen: std.AutoHashMapUnmanaged(i64, void) = .empty;
    var v = start.asIntExact() orelse return s.fail(.E0417, file, init.toRef(), "the initialization of `{s}`", .{name});
    for (0..values_max) |_| {
        try bind(s, b, gv, v);
        const c = (try decl.foldRef(s, unit, cond)) orelse break;
        if (!c.isTrue()) break;
        if ((try seen.getOrPut(s.arena, v)).found_existing) return s.fail(.E0420, file, init.toRef(), "`{s}` repeats the value {d}, so the loop never ends", .{ name, v });
        v = ((try decl.foldRef(s, unit, step.?.rhs)) orelse break).asIntExact() orelse break;
    }
    v = start.asIntExact().?;
    for (0..values_max) |_| {
        try bind(s, b, gv, v);
        const c = (try decl.foldRef(s, unit, cond)) orelse return s.fail(.E0418, file, init.toRef(), "", .{});
        if (!c.isTrue()) return;
        var inner = b.child();
        inner.loop = null;
        inner.analog_for = true;
        try @import("control.zig").body(s, &inner, loop.body);
        try b.insts.appendSlice(s.arena, inner.insts.items);
        const next = (try decl.foldRef(s, unit, step.?.rhs)) orelse
            return s.fail(if (hasUnknown(vir, step.?.rhs, 0)) .E0486 else .E0419, file, init.toRef(), "the iteration of `{s}`", .{name});
        v = next.asIntExact() orelse return s.fail(.E0419, file, init.toRef(), "the iteration of `{s}`", .{name});
    }
}

// ---- private ----

fn bind(s: *Sema, b: *Block, gv: Inst.Index, v: i64) Allocator.Error!void {
    try b.unit.binds.put(s.arena, gv, .{ .constant = try decl.intern(s, .{ .int = v }) });
}

/// §6.6.1 "It shall be an error if any bit of the genvar is set to x or z":
/// whether `r` holds a literal with an x, z or `?` digit.
fn hasUnknown(vir: *const Vir, r: Inst.Ref, depth: u32) bool {
    const i = r.toIndex() orelse return false;
    if (depth > 64) return false;
    if (vir.instructions.items(.tag)[@backingInt(i)] == .big_int)
        return std.mem.findAny(u8, vir.string(decl.payloadOf(vir, Inst.BigInt, i).digits), "xz?") != null;
    var ops: [3]Inst.Ref = .{ .none, .none, .none };
    switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .pos, .neg, .not, .bit_not => ops[0] = vir.instructions.items(.data)[@backingInt(i)].un_node.operand,
        .add, .sub, .mul, .div, .mod, .pow, .shl, .shr, .bit_and, .bit_or, .bit_xor => {
            const x = decl.payloadOf(vir, Inst.Bin, i);
            ops = .{ x.lhs, x.rhs, .none };
        },
        else => {}, // else: no operand to look under
    }
    for (ops) |o| if (hasUnknown(vir, o, depth + 1)) return true;
    return false;
}
