//! §6.2.2 a recursive instantiation (E0905): an instance whose module
//! and parameter values are already on its path from the root has no
//! finite instance tree. A generate scheme that ends the recursion gives
//! each level other values, so only a repeated key is refused.
//! Cites: VAMS-2023 §6.2.2; IEEE 1364-2005 §12.4.
//!
//! Contents:
//! - `pub fn refused(w: *const Walk, p: Pending, key: Instance.Key, module: []const u8) Allocator.Error!bool`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Zcu = @import("../Zcu.zig");
const walk = @import("walk.zig");
const Instance = Zcu.Instance;
const Walk = walk.Walk;
const Pending = walk.Pending;

/// The deepest instance tree; deeper is a runaway recursion (E0905).
const depth_max: u32 = 1 << 16;

/// Reports E0905 and returns true when instantiating `p` as `key` (of
/// module `module`) repeats an instance on its path or runs past the
/// table's bounds; else false.
pub fn refused(w: *const Walk, p: Pending, key: Instance.Key, module: []const u8) Allocator.Error!bool {
    assert(module.len != 0);
    const before = w.zcu.failed.len;
    defer assert(w.zcu.failed.len >= before);
    const depth = (try recursion(w, p, key)) orelse return false;
    if (depth > depth_max or w.zcu.instances.len >= Zcu.instances_max) {
        try w.s.fail(.E0905, p.file, p.src, "`{s}` instantiates itself with the same parameters ({d} levels deep)", .{ module, depth });
    } else try w.s.fail(.E0905, p.file, p.src, "{s}", .{try cycleText(w, p, depth)});
    return true;
}

// ---- private ----

/// E0905's depth when `key` is already on the path from the root to `p`,
/// or when the tree is past `depth_max`; else null.
fn recursion(w: *const Walk, p: Pending, key: Instance.Key) Allocator.Error!?u32 {
    assert(key.params != .none);
    if (p.parent != .none) assert(@backingInt(p.parent) < w.zcu.instances.len);
    const parents = w.zcu.instances.items(.parent);
    const modules = w.zcu.instances.items(.module);
    const params = w.zcu.instances.items(.params);
    var depth: u32 = 1;
    var it = p.parent;
    while (it != .none) : (it = parents[@backingInt(it)]) {
        depth += 1;
        if (depth > depth_max) return depth;
        if (params[@backingInt(it)] == key.params and std.meta.eql(modules[@backingInt(it)], key.module)) return depth;
    }
    if (w.zcu.instances.len >= Zcu.instances_max) return depth;
    return null;
}

/// E0905 in the old elaborator's words: the modules of the cycle that
/// closes `depth` levels above `p` (`` `a` → `b` → `a` ``), and the path
/// below the root at which it closes.
fn cycleText(w: *const Walk, p: Pending, depth: u32) Allocator.Error![]const u8 {
    assert(depth >= 2 and depth <= depth_max);
    const zcu = w.zcu;
    const ip = &zcu.intern_pool;
    const a = w.s.arena;
    var chain: std.ArrayList(Instance.Index) = .empty;
    var it = p.parent;
    // Bounded by `depth_max` (`recursion`'s walk of the same parents).
    while (it != .none) : (it = zcu.instances.items(.parent)[@backingInt(it)]) try chain.append(a, it);
    assert(chain.items.len >= depth - 1);
    var out: std.ArrayList(u8) = .empty;
    var k = depth - 1;
    while (k > 0) : (k -= 1) {
        const m = zcu.instances.items(.module)[@backingInt(chain.items[k - 1])];
        try out.print(a, "`{s}` → ", .{zcu.fileVir(m.file).string(zcu.declRow(m).name)});
    }
    const m = zcu.instances.items(.module)[@backingInt(chain.items[depth - 2])];
    try out.print(a, "`{s}` closes at `", .{zcu.fileVir(m.file).string(zcu.declRow(m).name)});
    // The root's own name is not on the path.
    var j = chain.items.len - 1;
    while (j > 0) : (j -= 1) try out.print(a, "{s}.", .{ip.stringToSlice(zcu.instances.items(.name)[@backingInt(chain.items[j - 1])])});
    try out.print(a, "{s}`", .{ip.stringToSlice(p.name)});
    return out.items;
}
