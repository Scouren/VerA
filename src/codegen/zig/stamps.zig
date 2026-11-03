//! The §5.6 stamp plan: `Air.Device`'s contributions, flow unknowns and
//! charge sites in, the residual's rows as an ordered list of stamps out
//! (each contribution added at hi and subtracted at lo, §1.3.1.2; a
//! potential source's branch relation `V(hi) - V(lo) - c`; a §5.4.2.1 flow
//! probe's short; a §5.6.6 implicit flow's `x[u] - Σ`; a §5.4.3 port
//! probe's mirror), the Jacobian pattern each row gains, and the reactive
//! rows as `q_stamps`. In the old device's order
//! (`src/codegen/device/codegen/stamps.zig`, `plan/qsite.zig`), so both sum
//! the same terms in the same order.
//! Cites: VAMS-2023 §1.3.1.2, §5.4.2.1, §5.4.3, §5.6, §5.6.1.2, §5.6.6.
//!
//! Contents:
//! - `pub const Term = union(enum)`, `pub const Stamp = struct` (`Op`), `pub const QStamp = struct`, `pub const Plan = struct`
//! - `pub fn plan(dg: *DeclGen) DeclGen.Error!Plan`

const std = @import("std");
const assert = std.debug.assert;
const Air = @import("air");
const DeclGen = @import("DeclGen.zig");
const Liveness = @import("Liveness.zig");
const Device = Air.Device;
const Mask = Liveness.Mask;
/// What a stamp writes into its row.
pub const Term = union(enum) {
    /// Contribution `k`'s resistive sum (`m.r<k>`), or 0 when it has none.
    resist: u32,
    /// Unknown `u`'s value and lane (`xs[u]`).
    x: u32,
    /// `V(hi) - V(lo)`, less contribution `k`'s resistive sum when set.
    branch: struct { hi: u32, lo: u32, k: u32 },
    /// `xs[u] - res[p]`: port `p`'s flow as KCL has summed it so far.
    port: struct { u: u32, p: u32 },
};

/// One residual stamp: `res[row] op term`, or `res[row] = term` (`set`).
pub const Stamp = struct {
    row: u32,
    op: Op,
    term: Term,

    /// `res[row] = res[row].add(term)`, `.sub(term)`, or `= term`.
    pub const Op = enum { add, sub, set };
};

/// Row `row` of the reactive residual gains `sign · q[site]`.
pub const QStamp = struct { row: u32, site: u32, sign: f64 };

/// The plan, in the arena.
pub const Plan = struct {
    stamps: []const Stamp,
    /// Per row, the unknowns `eval`'s row may depend on (`jac_pattern`).
    pattern: []const Mask,
    /// Sorted by (row, site), no repeated pair, no zero sign.
    q: []const QStamp,
};

const none: u32 = std.math.maxInt(u32);

/// The stamp plan of `dg.device`. Fails (`dg.fail`) on a shape this
/// backend does not stamp yet.
pub fn plan(dg: *DeclGen) DeclGen.Error!Plan {
    const d = dg.device;
    const a = dg.arena;
    const n_u: u32 = @intCast(d.nodes.len);
    var stamps: std.ArrayList(Stamp) = .empty;
    const pattern = try a.alloc(Mask, n_u);
    @memset(pattern, 0);
    // Each contribution's flow unknown, `none` for a flow contribution.
    const flows = try a.alloc(u32, d.contributions.len);
    for (flows, 0..) |*fl, k| {
        const c = d.contributions.get(k);
        if (c.kind == .indirect) return dg.fail("a §5.6.7 indirect contribution", .{});
        fl.* = none;
        if (c.access == .flow) continue;
        if (!dg.unconditional(c.wrote)) return dg.fail("a §5.6.1.3 potential contribution that runs under a condition (a switch branch)", .{});
        fl.* = flowUnknown(dg, @backingInt(c.hi), @backingInt(c.lo)) orelse return dg.fail("a potential contribution whose flow unknown is not `flow(hi,lo)`", .{});
    }
    for (flows, 0..) |fl, k| {
        const c = d.contributions.get(k);
        const hi = @backingInt(c.hi);
        const lo = @backingInt(c.lo);
        const m = dg.live.masks[@backingInt(c.resist)];
        if (fl == none) {
            if (potentialOn(d, hi, lo)) return dg.fail("a flow contribution to a potential source's branch", .{});
            if (!dg.live.assigned[@backingInt(c.resist)]) continue; // a zero half stamps nothing
            try add(a, &stamps, pattern, hi, .add, .{ .resist = @intCast(k) }, m);
            try add(a, &stamps, pattern, lo, .sub, .{ .resist = @intCast(k) }, m);
            if (freeOf(dg, flows, hi, lo)) |u| try add(a, &stamps, pattern, u, .sub, .{ .resist = @intCast(k) }, m);
            continue;
        }
        const bit = @as(Mask, 1) << @intCast(fl);
        try add(a, &stamps, pattern, hi, .add, .{ .x = fl }, bit);
        try add(a, &stamps, pattern, lo, .sub, .{ .x = fl }, bit);
        try add(a, &stamps, pattern, fl, .set, .{ .branch = .{ .hi = hi, .lo = lo, .k = @intCast(k) } }, bits(hi) | bits(lo) | m);
    }
    // §5.4.2.1/§5.6.6 the flow unknowns no branch relation defines, in
    // unknown order: a sourced one closes `x[u] - Σ`, a probe is a short.
    for (d.nodes.items(.kind), 0..) |kind, ui| {
        const u: u32 = @intCast(ui);
        if (kind != .branch_flow or std.mem.findScalar(u32, flows, u) != null) continue;
        const ends = flowEnds(dg, u) orelse return dg.fail("a flow unknown whose name is not `flow(hi,lo)`", .{});
        const bit = @as(Mask, 1) << @intCast(u);
        if (sourced(dg, ends[0], ends[1])) {
            try add(a, &stamps, pattern, u, .add, .{ .x = u }, bit);
        } else {
            try add(a, &stamps, pattern, ends[0], .add, .{ .x = u }, bit);
            try add(a, &stamps, pattern, ends[1], .sub, .{ .x = u }, bit);
            try add(a, &stamps, pattern, u, .set, .{ .branch = .{ .hi = ends[0], .lo = ends[1], .k = none } }, bits(ends[0]) | bits(ends[1]));
        }
    }
    // §5.4.3 a port probe reads the finished KCL row of its port.
    for (d.nodes.items(.kind), 0..) |kind, ui| {
        const u: u32 = @intCast(ui);
        if (kind != .port_flow) continue;
        const p = portOf(dg, u) orelse return dg.fail("a port flow unknown whose name is not `flow(<p>)`", .{});
        try add(a, &stamps, pattern, u, .set, .{ .port = .{ .u = u, .p = p } }, (@as(Mask, 1) << @intCast(u)) | pattern[p]);
    }
    return .{ .stamps = stamps.items, .pattern = pattern, .q = try qPlan(dg, flows) };
}

// ---- private ----

fn add(a: std.mem.Allocator, stamps: *std.ArrayList(Stamp), pattern: []Mask, row: u32, op: Stamp.Op, term: Term, m: Mask) !void {
    if (row == @backingInt(Device.Node.Index.ground)) return; // §1.3.1.1 ground has no equation
    assert(row < pattern.len);
    pattern[row] |= m;
    try stamps.append(a, .{ .row = row, .op = op, .term = term });
}

fn bits(u: u32) Mask {
    return if (u == @backingInt(Device.Node.Index.ground)) 0 else @as(Mask, 1) << @intCast(u);
}

/// The reactive rows: each charge site at its contribution's rows, a port
/// probe's row the negation of its port's.
fn qPlan(dg: *DeclGen, flows: []const u32) DeclGen.Error![]const QStamp {
    const d = dg.device;
    var out: std.ArrayList(QStamp) = .empty;
    for (d.charge_sites.items(.contrib), d.charge_sites.items(.sign), 0..) |ci, sign, k| {
        const c = d.contributions.get(@backingInt(ci));
        const site: u32 = @intCast(k);
        const fl = flows[@backingInt(ci)];
        if (fl != none) {
            try qAdd(dg, &out, fl, site, -sign);
            continue;
        }
        try qAdd(dg, &out, @backingInt(c.hi), site, sign);
        try qAdd(dg, &out, @backingInt(c.lo), site, -sign);
        if (freeOf(dg, flows, @backingInt(c.hi), @backingInt(c.lo))) |u| try qAdd(dg, &out, u, site, -sign);
    }
    for (d.nodes.items(.kind), 0..) |kind, ui| {
        if (kind != .port_flow) continue;
        const p = portOf(dg, @intCast(ui)).?;
        const port_rows = try dg.arena.dupe(QStamp, out.items);
        for (port_rows) |s| if (s.row == p) try qAdd(dg, &out, @intCast(ui), s.site, -s.sign);
    }
    std.mem.sort(QStamp, out.items, {}, struct {
        fn lt(_: void, x: QStamp, y: QStamp) bool {
            return x.row < y.row or (x.row == y.row and x.site < y.site);
        }
    }.lt);
    // Merge repeats; drop what cancels.
    var n: usize = 0;
    for (out.items) |s| {
        if (n != 0 and out.items[n - 1].row == s.row and out.items[n - 1].site == s.site) {
            out.items[n - 1].sign += s.sign;
            if (out.items[n - 1].sign == 0) n -= 1;
            continue;
        }
        out.items[n] = s;
        n += 1;
    }
    return out.items[0..n];
}

fn qAdd(dg: *DeclGen, out: *std.ArrayList(QStamp), row: u32, site: u32, sign: f64) !void {
    if (row == @backingInt(Device.Node.Index.ground)) return;
    try out.append(dg.arena, .{ .row = row, .site = site, .sign = sign });
}

/// The §5.6.6 free flow of a flow contribution's pair: its flow unknown
/// when no potential source defines it.
fn freeOf(dg: *DeclGen, flows: []const u32, hi: u32, lo: u32) ?u32 {
    const u = flowUnknown(dg, hi, lo) orelse return null;
    if (std.mem.findScalar(u32, flows, u) != null) return null;
    return u;
}

/// Whether a flow contribution writes pair (hi, lo).
fn sourced(dg: *DeclGen, hi: u32, lo: u32) bool {
    const d = dg.device;
    for (d.contributions.items(.access), d.contributions.items(.hi), d.contributions.items(.lo)) |acc, h, l| {
        if (acc == .flow and @backingInt(h) == hi and @backingInt(l) == lo) return true;
    }
    return false;
}

/// Whether a potential contribution writes pair (hi, lo).
fn potentialOn(d: *const Device, hi: u32, lo: u32) bool {
    for (d.contributions.items(.access), d.contributions.items(.hi), d.contributions.items(.lo)) |acc, h, l| {
        if (acc == .potential and @backingInt(h) == hi and @backingInt(l) == lo) return true;
    }
    return false;
}

// ponytail: the flow unknown of a pair and the port of a port flow are
// found by Sema's spelling (`flow(hi,lo)`, `flow(<p>)`), since `Air.Device`
// has no column for them yet; asked of rw-lower as `Contribution.flow` and
// a probes table. A misspelling fails codegen, never mis-stamps.

/// The `branch_flow` unknown spelled `flow(<hi>,<lo>)`, ground `gnd`.
fn flowUnknown(dg: *DeclGen, hi: u32, lo: u32) ?u32 {
    const d = dg.device;
    const name = std.fmt.allocPrint(dg.arena, "flow({s},{s})", .{ nodeName(dg, hi), nodeName(dg, lo) }) catch return null;
    for (d.nodes.items(.kind), d.nodes.items(.name), 0..) |kind, n, u| {
        if (kind == .branch_flow and std.mem.eql(u8, dg.ip.stringToSlice(n), name)) return @intCast(u);
    }
    return null;
}

/// The pair a `branch_flow` unknown's name spells.
fn flowEnds(dg: *DeclGen, u: u32) ?[2]u32 {
    const d = dg.device;
    const name = dg.ip.stringToSlice(d.nodes.items(.name)[u]);
    if (!std.mem.startsWith(u8, name, "flow(") or name[name.len - 1] != ')') return null;
    const inner = name[5 .. name.len - 1];
    // Every split at a comma; the one that names two nodes wins.
    for (inner, 0..) |ch, at| {
        if (ch != ',') continue;
        const hi = nodeByName(dg, inner[0..at]) orelse continue;
        const lo = nodeByName(dg, inner[at + 1 ..]) orelse continue;
        if (flowUnknown(dg, hi, lo) == u) return .{ hi, lo };
    }
    return null;
}

/// The port a `port_flow` unknown `flow(<p>)` reads.
fn portOf(dg: *DeclGen, u: u32) ?u32 {
    const name = dg.ip.stringToSlice(dg.device.nodes.items(.name)[u]);
    if (!std.mem.startsWith(u8, name, "flow(<") or !std.mem.endsWith(u8, name, ">)")) return null;
    return nodeByName(dg, name[6 .. name.len - 2]);
}

fn nodeByName(dg: *DeclGen, s: []const u8) ?u32 {
    if (std.mem.eql(u8, s, "gnd")) return @backingInt(Device.Node.Index.ground);
    for (dg.device.nodes.items(.name), 0..) |n, u| if (std.mem.eql(u8, dg.ip.stringToSlice(n), s)) return @intCast(u);
    return null;
}

fn nodeName(dg: *DeclGen, u: u32) []const u8 {
    if (u == @backingInt(Device.Node.Index.ground)) return "gnd";
    return dg.ip.stringToSlice(dg.device.nodes.items(.name)[u]);
}
