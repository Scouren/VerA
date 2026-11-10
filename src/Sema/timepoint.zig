//! VerA's `vera_timepoint` (§2.9, the old `analog/timepoint.zig`'s
//! refusals): a statement's attribute in, `Block.timepoint` set for its
//! body out; inside, what a cached statement may not hold (a contribution,
//! an event, a probe, `$limit`, an operator with history, a noise source,
//! a system task other than `$fatal`/`$error`) is E0530. The statement
//! itself is lowered uncached: its value each evaluation is the one a
//! cache would have held.
//! Cites: VAMS-2023 §2.9, §5.6, §5.10, §9.7.3.
//!
//! Contents:
//! - `pub fn enter(s: *Sema, b: *Block, attrs: Vir.List(Inst.Attr)) Allocator.Error!void`
//! - `pub fn refuse(s: *Sema, b: *const Block, src: Inst.Ref, what: []const u8) Allocator.Error!bool`

const std = @import("std");
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Block = Sema.Block;

/// VerA's `vera_timepoint` (§2.9) on a statement: §2.9's default 1 when
/// it has no value, else a value that folds (E0529); not in a loop, an
/// analog function or an `analog initial` block (E0532). A nested one is
/// the outer one's.
pub fn enter(s: *Sema, b: *Block, attrs: Vir.List(Inst.Attr)) Allocator.Error!void {
    if (b.timepoint) return;
    const vir = b.unit.vir;
    for (vir.list(Inst.Attr, attrs)) |a| if (std.mem.eql(u8, vir.string(a.name), "vera_timepoint")) {
        if (a.value.len != 0) {
            // It picks the code the device is built with: no card value.
            if (@import("attr.zig").readsParam(vir, a.value)) return s.fail(.E0529, b.unit.file, .none, "the value reads a parameter", .{});
            const c = (try decl.foldBody(s, b.unit, a.value)) orelse return s.fail(.E0529, b.unit.file, .none, "", .{});
            if (!c.isTrue()) return;
        }
        if (b.restricted()) |ctx| return s.fail(.E0532, b.unit.file, .none, "in {s}", .{ctx});
        if (b.loop != null) return s.fail(.E0532, b.unit.file, .none, "inside a loop", .{});
        b.timepoint = true;
    };
}

/// E0530 for what a `vera_timepoint` statement may not hold; true when
/// raised.
pub fn refuse(s: *Sema, b: *const Block, src: Inst.Ref, what: []const u8) Allocator.Error!bool {
    if (!b.timepoint) return false;
    try s.fail(.E0530, b.unit.file, src, "{s}", .{what});
    return true;
}
