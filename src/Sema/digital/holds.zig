//! Procedural continuous assignments of the digital lowering (§9.3): an
//! `assign`, `force`, `deassign` or `release` statement in; as
//! lib/sim/digital compiles them, per target (each operand of a
//! concatenation, which takes its own bits of the value) a holding process
//! jumped over where it is written (its `override_eval` step, a wait on the
//! value's operands, the loop back), the value written now and the
//! override switched on; `deassign`/`release` switch it off.
//! Cites: IEEE 1364-2005 §9.3, §9.3.1, §9.3.2.
//!
//! Contents:
//! - `pub fn statement(l: *Lower, i: Inst.Index) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const std_sim = @import("std_sim");
const digital = @import("../digital.zig");
const expr = @import("expr.zig");
const place = @import("place.zig");
const nets = @import("nets.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const none = digital.none;
const Program = std_sim.Program;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// A target's slot and, for a select of a vector net, its bits.
const Target = struct { slot: u32, lo: u32 = 0, width: u32 = 0, net: bool, slot_width: u32 };

/// §9.3 procedural continuous assignment statement `i`.
pub fn statement(l: *Lower, i: Inst.Index) Error!void {
    if (l.in_function) return l.refuse("§10.4.4 a procedural continuous assignment in a function");
    const vir = l.virOf(l.frame);
    const tg = Lower.tag(vir, i);
    const force = tg == .force or tg == .release;
    const lhs, const value = switch (tg) {
        .proc_assign, .force => blk: {
            const b = Lower.payload(vir, Inst.Bin, i);
            break :blk .{ b.lhs, b.rhs };
        },
        else => .{ vir.instructions.items(.data)[@backingInt(i)].un_node.operand, Inst.Ref.none }, // else: deassign, release
    };
    const li = lhs.toIndex() orelse return l.refuse("a procedural continuous assignment of nothing");
    try place.notAutomatic(l, lhs, "a procedural continuous assignment");
    try place.readsNoAutomatic(l, value, "a procedural continuous assignment");
    if (Lower.tag(vir, li) == .concat) {
        const ops = vir.list(Inst.Ref, Lower.payload(vir, Inst.Refs, li));
        var of: u32 = 0;
        for (ops) |x| of += widthOf(try target(l, x));
        var lo = of;
        for (ops) |x| {
            const t = try target(l, x);
            lo -= widthOf(t);
            try override(l, t, value, force, lo, of);
        }
        return;
    }
    try override(l, try target(l, lhs), value, force, 0, 0);
}

// ---- private ----

fn widthOf(t: Target) u32 {
    return if (t.width != 0) t.width else t.slot_width;
}

/// §9.3 a target: one whole variable or net, or (§9.3.2) a net array
/// element or a constant bit- or part-select of a vector net.
fn target(l: *Lower, r: Inst.Ref) Error!Target {
    const vir = l.virOf(l.frame);
    const i = r.toIndex() orelse return l.refuse("a procedural continuous assignment of nothing");
    switch (Lower.tag(vir, i)) {
        .decl_ref, .str_ref, .field => {
            const n = try expr.leafName(l, i);
            if (n.dims.len != 0) return l.refuse("§9.3 a procedural continuous assignment of a whole array");
            if (n.kind != .variable and n.kind != .net) return l.refuse("§9.3 a procedural continuous assignment of no variable or net");
            return .{ .slot = n.slot, .net = n.kind == .net, .slot_width = n.ty.width };
        },
        .elem, .slice, .slice_up, .slice_down => {
            const s = try place.selectOf(l, i);
            if (s.name.kind != .net) return l.refuse("§9.3.2 a procedural continuous assignment of a select that is no select of a net");
            // The bits `nets.sink` names, as a continuous assignment's.
            const k = try nets.sink(l, r);
            const row = l.nets.items[k.net];
            return .{ .slot = row.slot, .lo = k.lo, .width = if (s.whole_elem) 0 else k.width, .net = true, .slot_width = row.width };
        },
        else => return l.refuse("§9.3 a procedural continuous assignment of an expression"),
    }
}

/// One override of target `t` by `value` (`none`: switched off), its bits
/// [lo, lo + width) of a value `of` bits wide when `of` is not 0.
fn override(l: *Lower, t: Target, value: Inst.Ref, force: bool, lo: u32, of: u32) Error!void {
    const scope = l.frames.items[l.frame].scope;
    if (!force and t.net) return l.refuse("§9.3.1 assign/deassign of a net");
    if (value == .none) {
        _ = try l.b.inst(.override_off, try l.b.extraOf(Program.Override{ .slot = t.slot, .force = force, .lo = t.lo, .width = t.width, .start = 0, .end = 0 }), 0, scope);
        return;
    }
    const row = if (of != 0)
        try expr.evalFor(l, value, .{ .width = of, .signed = false })
    else if (t.width != 0)
        try expr.evalFor(l, value, .{ .width = t.width, .signed = false })
    else
        try expr.evalFor(l, value, typeOfSlot(l, t.slot));
    const step = try l.b.extraOf(Program.OverrideEval{ .slot = t.slot, .value = row, .force = force, .lo = t.lo, .width = t.width, .slice_lo = lo, .of = of });
    var slots: std.ArrayList(u32) = .empty;
    try expr.reads(l, value, &slots);
    var terms: std.ArrayList(u32) = .empty;
    for (slots.items) |s| try terms.appendSlice(l.a, &.{ s, @backingInt(Program.Edge.any), 0, 0, none });
    // The holding process, jumped over here.
    const skip = try l.b.inst(.jump, 0, 0, scope);
    const start: u32 = @intCast(l.b.p.insts.len);
    _ = try l.b.inst(.override_eval, step, 0, scope);
    _ = try l.b.inst(.wait_event, try l.b.extraOf(.{ .l = try l.b.listOf(terms.items) }), 0, scope);
    _ = try l.b.inst(.jump, start, 0, scope);
    const end: u32 = @intCast(l.b.p.insts.len);
    l.b.setInst(skip, .jump, end, 0);
    // §9.3.1/§9.3.2 the value holds from the statement on.
    _ = try l.b.inst(.override_eval, step, 0, scope);
    _ = try l.b.inst(.override_on, try l.b.extraOf(Program.Override{ .slot = t.slot, .force = force, .lo = t.lo, .width = t.width, .start = start, .end = end }), 0, scope);
    assert(start < end);
}

fn typeOfSlot(l: *Lower, slot: u32) digital.Type {
    const t = l.b.p.slots.items(.ty)[slot];
    return .{ .width = t.width, .signed = t.signed, .real = t.real };
}
