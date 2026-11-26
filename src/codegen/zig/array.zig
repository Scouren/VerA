//! §3.2.2 a declared array as one slot (DV1, research/codegen.md T40):
//! Sema lowers an array to one scalar `alloc` per element
//! (`Sema/array.zig`), a run-time-index read to a chain of `select`s over
//! every element and a write to one `select`-and-`assign` per element, so
//! a device text grew with the element count (`vera_timepoint_held_history`:
//! 4,096 cells, a 9.7 MB device). `plan` finds each `Device.arrays` row's
//! slots and each such chain; `Function` then types the slots as one
//! `[n]T` and writes a chain as one indexed read or write. A chain of any
//! other shape is written element by element, as before.
//! Cites: VAMS-2023 §3.2.2 (an index outside the array reads zero and
//! writes nothing), §5.10.
//!
//! The data, by `data-oriented-design`'s six questions:
//! 1. In: one `Air` and its `Device.arrays`. Out: two columns over its
//!    instructions (`group`, `fuse`) and the `fused` rows.
//! 2. One per device; up to `Sema`'s `array_cells_max` slots an array.
//! 3. A group is a `Device.arrays` row (`u32`), a fuse a `fused` row
//!    (`u32`), each with sentinels at the top.
//! 4. Read by instruction while `Function` writes it.
//! 5. Lives for one `generate`.
//! 6. Written once by `plan`, read only after.
//!
//! Contents:
//! - `pub const Group = enum(u32)`, `pub const Fuse = enum(u32)`, `pub const Fused = struct`
//! - `pub fn plan(dg: *DeclGen) DeclGen.Error!void`
//! - `pub fn base(dg: *const DeclGen, slot: u32) ?u32`: the slot's array's first slot

const std = @import("std");
const assert = std.debug.assert;
const Air = @import("air");
const DeclGen = @import("DeclGen.zig");
const Liveness = @import("Liveness.zig");
const state = @import("state.zig");
const Inst = Air.Inst;
const Ref = Inst.Ref;

/// Per instruction: the `Device.arrays` row an `alloc` is an element of.
pub const Group = enum(u32) { none = std.math.maxInt(u32), _ };

/// Per instruction: written as itself (`none`), not at all (`skip`, a part
/// of a chain), or as the `fused` row it starts.
pub const Fuse = enum(u32) { none = std.math.maxInt(u32), skip = std.math.maxInt(u32) - 1, _ };

/// One chain written as one statement: `read` at its last `select` (the
/// value), `write` at its first `ieq`. `k` is the flat index, `v` the value
/// written or the constant an index outside the array reads.
pub const Fused = struct {
    group: u32,
    k: Ref,
    v: Ref,
    kind: enum(u8) { read, write },
};

comptime {
    assert(@sizeOf(Fused) <= 16);
}

/// A chain `matchRead`/`matchWrite` found: its row and its instruction count.
const Match = struct { row: Fused, n: usize };

/// Fills `dg.group`, `dg.fuse` and `dg.fused`.
pub fn plan(dg: *DeclGen) DeclGen.Error!void {
    const n = dg.air.instructions.len;
    const arrays = dg.device.arrays.items;
    dg.group = try dg.arena.alloc(Group, n);
    @memset(dg.group, .none);
    dg.fuse = try dg.arena.alloc(Fuse, n);
    @memset(dg.fuse, .none);
    for (arrays, 0..) |a, g| {
        const s = @backingInt(a.slot);
        if (a.count < 2 or s + a.count > n) return dg.fail("array row {d} is not two or more slots of the body", .{g});
        for (dg.group[s..][0..a.count], s..) |*x, i| {
            if (dg.air.instructions.items(.tag)[i] != .alloc) return dg.fail("array row {d}'s slots are not consecutive allocs", .{g});
            x.* = @fromBackingInt(@intCast(g));
        }
    }
    if (arrays.len == 0) return;
    const uses = try dg.arena.alloc(u8, n);
    @memset(uses, 0);
    for (dg.air.instructions.items(.tag), dg.air.instructions.items(.data)) |tag, data| {
        var ops: Liveness.Operands = .{};
        ops.collect(dg.air.*, tag, data, false);
        for (ops.slice()) |r| if (r.toIndex()) |o| {
            uses[@backingInt(o)] +|= 1;
        };
    }
    var fused: std.ArrayList(Fused) = .empty;
    try walk(dg, dg.air.mainBody(), uses, &fused, 0);
    dg.fused = fused.items;
    assert(dg.fused.len < @backingInt(Fuse.skip));
}

/// The first slot of the array slot `slot` is an element of, or null.
pub fn base(dg: *const DeclGen, slot: u32) ?u32 {
    const g = dg.group[slot];
    if (g == .none) return null;
    const b = @backingInt(dg.device.arrays.items[@backingInt(g)].slot);
    assert(b <= slot);
    return b;
}

// ---- private ----

/// Marks the chains of `body` and of every body nested in it.
fn walk(dg: *DeclGen, body: []const Inst.Index, uses: []const u8, fused: *std.ArrayList(Fused), depth: u32) DeclGen.Error!void {
    assert(depth <= Air.nesting_max + 1);
    const tags = dg.air.instructions.items(.tag);
    const datas = dg.air.instructions.items(.data);
    var p: usize = 0;
    // Each pass moves `p` past one instruction or one whole chain.
    while (p < body.len) {
        const i = @backingInt(body[p]);
        switch (tags[i]) {
            .block, .loop => {
                const x = dg.air.extraData(Air.Block, datas[i].ty_pl.payload);
                try walk(dg, dg.air.body(x.end, x.data.body_len), uses, fused, depth + 1);
            },
            .cond_br => {
                const x = dg.air.extraData(Air.CondBr, datas[i].pl_op.payload);
                try walk(dg, dg.air.body(x.end, x.data.then_body_len), uses, fused, depth + 1);
                try walk(dg, dg.air.body(x.end + x.data.then_body_len, x.data.else_body_len), uses, fused, depth + 1);
            },
            else => {}, // else: no nested body
        }
        const len = matchRead(dg, body[p..], uses) orelse matchWrite(dg, body[p..], uses) orelse {
            p += 1;
            continue;
        };
        const first: Fuse = @fromBackingInt(@intCast(fused.items.len));
        try fused.append(dg.arena, len.row);
        const chain = body[p..][0..len.n];
        for (chain) |c| dg.fuse[@backingInt(c)] = .skip;
        dg.fuse[@backingInt(chain[if (len.row.kind == .read) chain.len - 1 else 0])] = first;
        p += len.n;
    }
}

/// `Sema/array.zig`'s run-time read at `at[0]`: for `e` from the last
/// element down, `load(slot e)`, `ieq(k, e)`, `select(that, the load, the
/// select before, or the out-of-range constant)`, each part read once.
fn matchRead(dg: *const DeclGen, at: []const Inst.Index, uses: []const u8) ?Match {
    const tags = dg.air.instructions.items(.tag);
    const datas = dg.air.instructions.items(.data);
    const first = @backingInt(at[0]);
    if (tags[first] != .load) return null;
    const slot = @backingInt(datas[first].un_op.toIndex() orelse return null);
    const g = dg.group[slot];
    if (g == .none) return null;
    const a = dg.device.arrays.items[@backingInt(g)];
    const s = @backingInt(a.slot);
    if (slot != s + a.count - 1 or at.len < 3 * @as(usize, a.count)) return null;
    var k: Ref = .none;
    var out: Ref = .none;
    for (0..a.count) |j| {
        const ld, const eq, const sel = .{ at[3 * j], at[3 * j + 1], at[3 * j + 2] };
        const e = a.count - 1 - j;
        if (tags[@backingInt(ld)] != .load or datas[@backingInt(ld)].un_op != Ref.fromIndex(@fromBackingInt(@intCast(s + e)))) return null;
        if (!isIeq(dg, eq, e, &k)) return null;
        if (tags[@backingInt(sel)] != .select or datas[@backingInt(sel)].pl_op.operand != Ref.fromIndex(eq)) return null;
        const bin = dg.air.extraData(Air.Bin, datas[@backingInt(sel)].pl_op.payload).data;
        if (bin.lhs != Ref.fromIndex(ld)) return null;
        if (j == 0) {
            if (bin.rhs.toIndex() != null) return null;
            out = bin.rhs;
        } else if (bin.rhs != Ref.fromIndex(at[3 * j - 1])) return null;
        if (uses[@backingInt(ld)] != 1 or uses[@backingInt(eq)] != 1) return null;
        if (j + 1 < a.count and uses[@backingInt(sel)] != 1) return null;
    }
    assert(k != .none and out != .none);
    return .{ .row = .{ .group = @backingInt(g), .k = k, .v = out, .kind = .read }, .n = 3 * @as(usize, a.count) };
}

/// `Sema/array.zig`'s run-time write at `at[0]`: for each element `e`,
/// `ieq(k, e)`, `load(slot e)`, `select(that, v, the load)`, `assign(slot
/// e, the select)`, each value part read once.
fn matchWrite(dg: *const DeclGen, at: []const Inst.Index, uses: []const u8) ?Match {
    const tags = dg.air.instructions.items(.tag);
    const datas = dg.air.instructions.items(.data);
    if (at.len < 4 or tags[@backingInt(at[1])] != .load) return null;
    const slot = @backingInt(datas[@backingInt(at[1])].un_op.toIndex() orelse return null);
    const g = dg.group[slot];
    if (g == .none) return null;
    const a = dg.device.arrays.items[@backingInt(g)];
    const s = @backingInt(a.slot);
    if (slot != s or at.len < 4 * @as(usize, a.count)) return null;
    var k: Ref = .none;
    var v: Ref = .none;
    for (0..a.count) |e| {
        const eq, const ld, const sel, const as = .{ at[4 * e], at[4 * e + 1], at[4 * e + 2], at[4 * e + 3] };
        const el = Ref.fromIndex(@fromBackingInt(@intCast(s + e)));
        if (!isIeq(dg, eq, e, &k)) return null;
        if (tags[@backingInt(ld)] != .load or datas[@backingInt(ld)].un_op != el) return null;
        if (tags[@backingInt(sel)] != .select or datas[@backingInt(sel)].pl_op.operand != Ref.fromIndex(eq)) return null;
        const bin = dg.air.extraData(Air.Bin, datas[@backingInt(sel)].pl_op.payload).data;
        if (bin.rhs != Ref.fromIndex(ld)) return null;
        if (e == 0) v = bin.lhs else if (bin.lhs != v) return null;
        if (tags[@backingInt(as)] != .assign or datas[@backingInt(as)].bin_op.lhs != el or datas[@backingInt(as)].bin_op.rhs != Ref.fromIndex(sel)) return null;
        if (uses[@backingInt(eq)] != 1 or uses[@backingInt(ld)] != 1 or uses[@backingInt(sel)] != 1) return null;
    }
    assert(k != .none and v != .none);
    return .{ .row = .{ .group = @backingInt(g), .k = k, .v = v, .kind = .write }, .n = 4 * @as(usize, a.count) };
}

/// Whether `eq` is `ieq(k, e)` over the chain's one `k` (the first one
/// seen sets it).
fn isIeq(dg: *const DeclGen, eq: Inst.Index, e: usize, k: *Ref) bool {
    if (dg.air.instructions.items(.tag)[@backingInt(eq)] != .ieq) return false;
    const bin = dg.air.instructions.items(.data)[@backingInt(eq)].bin_op;
    if (state.intConst(dg, bin.rhs) != e) return false;
    if (k.* == .none) k.* = bin.lhs;
    return bin.lhs == k.*;
}
