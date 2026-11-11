//! The writes the held walk reads (held.zig): an assignment's left side
//! in, the variable it writes (and whether all of it) out; an analog
//! block in, every variable an `@(...)` body writes marked held (`event`,
//! §5.10) out.
//! Cites: VAMS-2023 §3.2.2, §5.10.
//!
//! Contents:
//! - `pub const Target = struct`
//! - `pub fn target(vir: *const Vir, r: Inst.Ref) ?Target`
//! - `pub fn eventWrites(s: *Sema, unit: *Unit, b: Vir.Body, in_event: bool, depth: u32) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const held = @import("held.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Unit = Sema.Unit;

/// The variable an assignment writes, and whether it writes all of it.
pub const Target = struct { var_: Inst.Index, whole: bool };

pub fn target(vir: *const Vir, r: Inst.Ref) ?Target {
    var at = r;
    var whole = true;
    for (0..held.depth_max) |_| {
        const i = at.toIndex() orelse return null;
        switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            .decl_ref => {
                const k = decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl);
                if (vir.instructions.items(.tag)[@backingInt(k)] != .variable) return null;
                return .{ .var_ = k, .whole = whole };
            },
            .elem, .slice, .slice_up, .slice_down => {
                whole = false;
                at = if (vir.instructions.items(.tag)[@backingInt(i)] == .elem) decl.payloadOf(vir, Inst.Bin, i).lhs else decl.payloadOf(vir, Inst.Triple, i).a;
            },
            else => return null, // else: no variable is written
        }
    }
    return null;
}

/// Every write inside an `@(...)` body is held (`event`).
pub fn eventWrites(s: *Sema, unit: *Unit, b: Vir.Body, in_event: bool, depth: u32) Allocator.Error!void {
    if (depth > held.depth_max) return;
    const vir = unit.vir;
    for (vir.body(b)) |i| {
        const tag = vir.instructions.items(.tag)[@backingInt(i)];
        switch (tag) {
            .store, .store_nb => if (in_event) if (target(vir, decl.payloadOf(vir, Inst.Bin, i).lhs)) |t| try unit.held.put(s.arena, t.var_, .event),
            .block => try eventWrites(s, unit, decl.payloadOf(vir, Inst.Block, i).body, in_event, depth + 1),
            .condbr => {
                const x = decl.payloadOf(vir, Inst.CondBr, i);
                try eventWrites(s, unit, x.then, in_event, depth + 1);
                try eventWrites(s, unit, x.@"else", in_event, depth + 1);
            },
            .case => for (vir.list(Inst.Arm, decl.payloadOf(vir, Inst.Case, i).arms)) |arm| try eventWrites(s, unit, arm.body, in_event, depth + 1),
            .loop => {
                const x = decl.payloadOf(vir, Inst.Loop, i);
                try eventWrites(s, unit, x.body, in_event, depth + 1);
                try eventWrites(s, unit, x.step, in_event, depth + 1);
            },
            .repeat => try eventWrites(s, unit, decl.payloadOf(vir, Inst.Repeat, i).body, in_event, depth + 1),
            .event_wait => try eventWrites(s, unit, decl.payloadOf(vir, Inst.EventWait, i).body, true, depth + 1),
            else => {}, // else: no other statement holds a body
        }
    }
}
