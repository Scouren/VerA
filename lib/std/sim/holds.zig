//! IEEE 1364-2005 §9.3 procedural continuous assignments: `assign`/`force`
//! install a process that keeps a slot (or, §9.3.2, a constant select of a
//! net) equal to an expression, `deassign`/`release` remove it. While one
//! holds a slot, ordinary writes to it do not land (`State.store` asks
//! `blocks`); a force outranks an assign.
//! Cites: IEEE 1364-2005 §9.3, §9.3.1, §9.3.2.
//!
//! Contents:
//! - `pub const Range = struct`, `pub const Part = struct`, `pub const Layers = struct`
//! - `pub fn on(s: *State, at: u32) Error!void`
//! - `pub fn apply(s: *State, a: Allocator, at: u32) Error!void`
//! - `pub fn off(s: *State, a: Allocator, at: u32) Error!void`
//! - `pub fn blocks(s: *const State, slot: u32) ?Layers`
//! - `pub fn keepForced(dest_v: []u64, dest_x: []u64, value: Literal, parts: []const Part) bool`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Program = @import("Program.zig");
const State = @import("State.zig");
const eval = @import("eval.zig");
const logic = @import("logic.zig");
const resolve = @import("resolve.zig");
const Error = State.Error;
const Literal = logic.Literal;

/// A process range [start, end).
pub const Range = struct { start: u32, end: u32 };

/// One forced select of a net: its bits and its process.
pub const Part = struct { lo: u32, width: u32, range: Range };

/// What holds one slot: an assign's process, a force's, and §9.3.2's
/// forced selects.
pub const Layers = struct {
    assign: ?Range = null,
    force: ?Range = null,
    parts: std.ArrayList(Part) = .empty,
};

/// `.override_on` (`Program.Override` at `at`): the assign or force whose
/// process is [start, end) now holds its target, replacing the one before.
pub fn on(s: *State, at: u32) Error!void {
    const o = s.p.extraData(Program.Override, at);
    assert(o.start < o.end);
    const entry = try s.holds_by_slot.getOrPut(s.arena, o.slot);
    if (!entry.found_existing) entry.value_ptr.* = .{};
    const range: Range = .{ .start = o.start, .end = o.end };
    if (o.width != 0) {
        const parts = &entry.value_ptr.parts;
        for (parts.items) |*p| {
            if (p.lo != o.lo or p.width != o.width) continue;
            _ = try s.stopRange(p.range.start, p.range.end);
            p.range = range;
            break;
        } else try parts.append(s.arena, .{ .lo = o.lo, .width = o.width, .range = range });
        _ = try s.enqueue(.{ .run = o.start }, null, false);
        return;
    }
    const layer = if (o.force) &entry.value_ptr.force else &entry.value_ptr.assign;
    if (layer.*) |old| _ = try s.stopRange(old.start, old.end);
    layer.* = range;
    _ = try s.enqueue(.{ .run = o.start }, null, false);
}

/// `.override_eval` (`Program.OverrideEval` at `at`): the holding process
/// writes its value past the hold it owns; an assign under a force keeps
/// tracking but does not write.
pub fn apply(s: *State, a: Allocator, at: u32) Error!void {
    const p = s.p;
    const o = p.extraData(Program.OverrideEval, at);
    const layers = s.holds_by_slot.get(o.slot) orelse Layers{};
    if (o.force or layers.force == null) {
        const w = if (o.width != 0) o.width else p.slots.items(.ty)[o.slot].width;
        const v = try eval.eval(s, a, o.value);
        const value = if (o.of != 0) blk: {
            const part = try logic.filled(a, w, false, .zero);
            logic.copyBits(part, 0, v, o.slice_lo, w);
            break :blk part;
        } else v;
        s.holding = true;
        defer s.holding = false;
        if (o.width != 0)
            try eval.write(s, a, o.slot, .{ .first = o.lo, .count = o.width }, value)
        else
            try s.store(o.slot, value);
    }
    // A forced net drives the switch-joined nets, which follow it.
    if (o.force and o.width == 0) if (s.netOf(o.slot)) |n| if (p.nets[n].trans.len != 0) try resolve.resolve(s, a, n);
}

/// `.override_off` (`Program.Override` at `at`, no range): `deassign` or
/// `release` of the target, or of one forced select.
pub fn off(s: *State, a: Allocator, at: u32) Error!void {
    const o = s.p.extraData(Program.Override, at);
    // Releasing what is not held is a no-op.
    const layers = s.holds_by_slot.getPtr(o.slot) orelse return;
    if (o.width != 0) {
        for (layers.parts.items, 0..) |p, i| if (p.lo == o.lo and p.width == o.width) {
            _ = try s.stopRange(p.range.start, p.range.end);
            _ = layers.parts.orderedRemove(i);
            break;
        };
        if (layers.force == null and layers.assign == null and layers.parts.items.len == 0) _ = s.holds_by_slot.remove(o.slot);
        if (s.netOf(o.slot)) |n| try resolve.resolve(s, a, n);
        return;
    }
    const layer = if (o.force) &layers.force else &layers.assign;
    if (layer.*) |old| _ = try s.stopRange(old.start, old.end);
    layer.* = null;
    const held = layers.assign;
    if (layers.force == null and layers.assign == null and layers.parts.items.len == 0) _ = s.holds_by_slot.remove(o.slot);
    // §9.3.2: a released net is its drivers' again; a released variable
    // keeps its value, unless an assign holds it.
    if (o.force) {
        if (s.netOf(o.slot)) |n| try resolve.resolve(s, a, n) else if (held) |h| _ = try s.enqueue(.{ .run = h.start }, null, false);
    }
}

/// What holds `slot` against an ordinary write, or null.
pub fn blocks(s: *const State, slot: u32) ?Layers {
    if (s.holding or s.holds_by_slot.count() == 0) return null;
    return s.holds_by_slot.get(slot);
}

/// Writes `value` into (`dest_v`, `dest_x`) but for the bits of each forced
/// select in `parts`, which keep theirs; whether anything changed.
pub fn keepForced(dest_v: []u64, dest_x: []u64, value: Literal, parts: []const Part) bool {
    assert(dest_v.len == value.values().len);
    var differ = false;
    for (0..dest_v.len) |w| {
        var keep: u64 = 0;
        for (parts) |p| keep |= selectWord(p.lo, p.width, w);
        for ([2][]u64{ dest_v, dest_x }, [2][]u64{ value.values(), value.unknowns() }) |dst, src| {
            const new = (src[w] & ~keep) | (dst[w] & keep);
            differ = differ or new != dst[w];
            dst[w] = new;
        }
    }
    return differ;
}

// ---- private ----

/// The bits of plane word `w` that [lo, lo + width) covers.
fn selectWord(lo_bit: u32, width: u32, w: usize) u64 {
    const base: u64 = w * 64;
    const lo = @max(lo_bit, base);
    const hi = @min(@as(u64, lo_bit) + width, base + 64);
    if (lo >= hi) return 0;
    const n = hi - lo;
    const ones = std.math.shl(u64, 1, n) -% 1;
    return ones << @intCast(lo - base);
}
