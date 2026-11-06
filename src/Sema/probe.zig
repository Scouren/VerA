//! §1.3.1 the probe-branch rule (the old `analog/source_check.zig`'s
//! `checkProbeBranches`): every access read lowering recorded
//! (`Sema.branch_reads`) and the contribution rows in; E0423 out for a
//! node pair nothing is contributed to whose potential and flow are both
//! read, once per design.
//! Cites: VAMS-2023 §1.3.1, §5.4.2.1, §5.4.2.2.
//!
//! Contents:
//! - `pub fn checkProbes(s: *Sema) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const Air = @import("air");
const Sema = @import("../Sema.zig");
const Node = Air.Device.Node;
const nodeName = @import("contrib.zig").nodeName;

/// §1.3.1 "The potential and flow of a probe branch may not both appear in
/// expressions in a given module" (E0423, the old `checkProbeBranches`): a
/// node pair nothing is contributed to whose two quantities are both read,
/// reported once at the later quantity's first read.
pub fn checkProbes(s: *Sema) Allocator.Error!void {
    const none = std.math.maxInt(u32);
    var first: std.AutoArrayHashMapUnmanaged(u64, [2]u32) = .empty;
    for (s.branch_reads.items, 0..) |r, k| {
        const g = try first.getOrPut(s.arena, pairKey(r.hi, r.lo));
        if (!g.found_existing) g.value_ptr.* = .{ none, none };
        const slot = &g.value_ptr[@backingInt(r.access)];
        if (slot.* == none) slot.* = @intCast(k);
    }
    var contributed: std.AutoHashMapUnmanaged(u64, void) = .empty;
    const c = s.device.contributions.slice();
    for (c.items(.hi), c.items(.lo)) |hi, lo| try contributed.put(s.arena, pairKey(hi, lo), {});
    for (s.branch_reads.items, 0..) |r, k| {
        const f = first.get(pairKey(r.hi, r.lo)).?;
        if (f[0] == none or f[1] == none or @min(f[0], f[1]) != k) continue;
        if (contributed.contains(pairKey(r.hi, r.lo))) continue;
        const at = s.branch_reads.items[@max(f[0], f[1])];
        return s.fail(.E0423, at.file, at.src, "both quantities of the probe branch (`{s}`, `{s}`) are read", .{ nodeName(s, r.hi), nodeName(s, r.lo) });
    }
}

// ---- private ----

/// An unordered node pair as one key.
fn pairKey(hi: Node.Index, lo: Node.Index) u64 {
    const h = @backingInt(hi);
    const l = @backingInt(lo);
    return @as(u64, @min(h, l)) << 32 | @max(h, l);
}
