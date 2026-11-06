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
//! - `pub fn unknowns(dg: *DeclGen) DeclGen.Error!void`
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

/// Fills `dg.u_names` and `dg.branch_u`: lowering mints a branch's flow
/// unknown only where the model probes its current (§5.4.2), so a
/// potential or §5.6.7 indirect source without one gets an unknown here,
/// appended after `nodes` in contribution order, spelled `flow(hi,lo)`
/// (`#k` added while the spelling is taken). A source whose unknown an
/// earlier source already drives gets its own: two sources in one branch
/// carry two currents (§5.6.7.1). The old codegen's `plan/names.zig`, so
/// `U` numbers the unknowns alike.
pub fn unknowns(dg: *DeclGen) DeclGen.Error!void {
    const d = dg.device;
    const a = dg.arena;
    var names: std.ArrayList([]const u8) = .empty;
    for (d.nodes.items(.name)) |n| try names.append(a, dg.ip.stringToSlice(n));
    dg.branch_u = try a.alloc(u32, d.contributions.len);
    @memset(dg.branch_u, none);
    for (d.contributions.items(.access), d.contributions.items(.kind), d.contributions.items(.flow), d.contributions.items(.hi), d.contributions.items(.lo), 0..) |access, kind, flow, hi, lo, k| {
        if (access != .potential and kind != .indirect) continue;
        var found: u32 = if (flow == .none) none else @backingInt(flow);
        if (found != none and std.mem.findScalar(u32, dg.branch_u[0..k], found) != null) found = none;
        if (found == none) {
            const base = try std.fmt.allocPrint(a, "flow({s},{s})", .{ name(dg, hi), name(dg, lo) });
            var spelled = base;
            // Each try is a distinct taken spelling, of finitely many.
            for (1..names.items.len + 2) |t| {
                const taken = for (names.items) |nm| {
                    if (std.mem.eql(u8, nm, spelled)) break true;
                } else false;
                if (!taken) break;
                spelled = try std.fmt.allocPrint(a, "{s}#{d}", .{ base, t });
            }
            found = @intCast(names.items.len);
            try names.append(a, spelled);
        }
        dg.branch_u[k] = found;
    }
    dg.u_names = names.items;
    if (dg.u_names.len > Liveness.unknowns_max) return dg.fail("more than {d} unknowns", .{Liveness.unknowns_max});
    assert(dg.u_names.len >= d.nodes.len);
}

fn name(dg: *DeclGen, n: Device.Node.Index) []const u8 {
    if (n == .ground) return "gnd";
    return dg.ip.stringToSlice(dg.device.nodes.items(.name)[@backingInt(n)]);
}

/// The stamp plan of `dg.device`. Fails (`dg.fail`) on a shape this
/// backend does not stamp yet.
pub fn plan(dg: *DeclGen) DeclGen.Error!Plan {
    const d = dg.device;
    const a = dg.arena;
    const n_u: u32 = @intCast(dg.u_names.len);
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
        fl.* = dg.branch_u[k];
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
    for (d.flows.items(.unknown), d.flows.items(.hi), d.flows.items(.lo), d.flows.items(.kind)) |un, hi, lo, kind| {
        const u: u32 = @backingInt(un);
        if (kind != .branch or std.mem.findScalar(u32, flows, u) != null) continue;
        const ends = [2]u32{ @backingInt(hi), @backingInt(lo) };
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
    for (d.flows.items(.unknown), d.flows.items(.hi), d.flows.items(.kind)) |un, port, kind| {
        if (kind != .port) continue;
        const u: u32 = @backingInt(un);
        const p: u32 = @backingInt(port);
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
    for (d.flows.items(.unknown), d.flows.items(.hi), d.flows.items(.kind)) |un, port, kind| {
        if (kind != .port) continue;
        const port_rows = try dg.arena.dupe(QStamp, out.items);
        for (port_rows) |s| if (s.row == @backingInt(port)) try qAdd(dg, &out, @backingInt(un), s.site, -s.sign);
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

/// The `branch` flow unknown of pair (hi, lo) (`Device.flows`), or null.
fn flowUnknown(dg: *DeclGen, hi: u32, lo: u32) ?u32 {
    const d = dg.device;
    for (d.flows.items(.unknown), d.flows.items(.hi), d.flows.items(.lo), d.flows.items(.kind)) |u, h, l, kind| {
        if (kind == .branch and @backingInt(h) == hi and @backingInt(l) == lo) return @backingInt(u);
    }
    return null;
}
