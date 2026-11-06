//! diff-lower's table check (tests/differential/lower.zig): the old
//! `Lowered` and the new `Air.Device` in, each as the same text lines out
//! (unknowns, parameters with their ranges, contributions, the counts of
//! charge sites and limit slots, held variables and prints), compared row
//! for row by the caller.
//! No LRM clause: this checks VerA's rewrite against VerA.
//!
//! Contents:
//! - `pub fn oldTables(arena: std.mem.Allocator, lw: *const Lowered) ![]const []const u8`
//! - `pub fn newTables(arena: std.mem.Allocator, zcu: *const Zcu, d: *const Device) ![]const []const u8`

const std = @import("std");
const sema = @import("sema");
const Air = @import("air");
const InternPool = @import("intern_pool");
const ir = @import("ir");
const Zcu = sema.Zcu;
const Lowered = ir.Lowered;
const Device = Air.Device;

/// The old tables as text lines, in the format `newTables` writes.
pub fn oldTables(arena: std.mem.Allocator, lw: *const Lowered) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const nodes = lw.nodes.slice();
    for (0..nodes.len) |k| {
        const kind: Device.Node.Kind = switch (nodes.items(.kind)[k]) {
            .net => .net,
            .branch_flow => .branch_flow,
            .port_flow => .port_flow,
            .op_state => .op_state,
        };
        try out.append(arena, try arena.print("node {d} {s} {t}{s}", .{ k, nodes.items(.name)[k], kind, if (k < lw.num_ports) " port" else "" }));
    }
    for (lw.params.items) |p| {
        const ty: Device.Param.Type = switch (p.ty) {
            .real => .real,
            .integer => .integer,
            .string => .string,
            .unspecified => .unspecified,
        };
        var line: std.ArrayList(u8) = .empty;
        try line.print(arena, "param {s} {t}{s} = ", .{ p.name, ty, if (p.is_local) " local" else "" });
        try constText(arena, &line, p.folded);
        for (p.ranges) |r| try rangeText(arena, &line, .{ .exclude = r.kind == .exclude, .lo = r.lo, .hi = r.hi, .lo_closed = r.lo_inclusive, .hi_closed = r.hi_inclusive, .strings = r.strings });
        try out.append(arena, line.items);
    }
    for (lw.contributions.items) |c| {
        const access: Device.Access = switch (c.access) {
            .potential => .potential,
            .flow => .flow,
        };
        const kind: Device.Contribution.Kind = switch (c.kind) {
            .direct => .direct,
            .indirect => .indirect,
        };
        try out.append(arena, try arena.print("contrib {t} {t} br{d} {s} {s}", .{ access, kind, @backingInt(c.br), oldNode(lw, c.hi), oldNode(lw, c.lo) }));
    }
    try out.append(arena, try arena.print("charge_sites {d}", .{lw.charge_sites.items.len}));
    for (lw.held_vars.items) |h| try out.append(arena, try arena.print("held {s}", .{h.name}));
    try out.append(arena, try arena.print("limit_slots {d}", .{lw.limit_slots.items.len}));
    for (lw.displays.items) |d| try out.append(arena, try arena.print("display {s}", .{d.name}));
    return out.items;
}

/// The new tables as text lines.
pub fn newTables(arena: std.mem.Allocator, zcu: *const Zcu, d: *const Device) ![]const []const u8 {
    const ip = &zcu.intern_pool;
    var out: std.ArrayList([]const u8) = .empty;
    const nodes = d.nodes.slice();
    for (0..nodes.len) |k| try out.append(arena, try arena.print("node {d} {s} {t}{s}", .{ k, ip.stringToSlice(nodes.items(.name)[k]), nodes.items(.kind)[k], if (k < d.num_ports) " port" else "" }));
    for (0..d.params.len) |k| {
        const p = d.params.get(k);
        var line: std.ArrayList(u8) = .empty;
        try line.print(arena, "param {s} {t}{s} = ", .{ ip.stringToSlice(p.name), p.ty, if (p.local) " local" else "" });
        try constText(arena, &line, constOf(arena, ip, p.default));
        for (d.paramRanges(@fromBackingInt(@intCast(k)))) |r| try rangeText(arena, &line, r);
        try out.append(arena, line.items);
    }
    for (0..d.contributions.len) |k| {
        const c = d.contributions.get(k);
        try out.append(arena, try arena.print("contrib {t} {t} br{d} {s} {s}", .{ c.access, c.kind, @backingInt(c.branch), newNode(ip, d, c.hi), newNode(ip, d, c.lo) }));
    }
    try out.append(arena, try arena.print("charge_sites {d}", .{d.charge_sites.len}));
    for (d.held.items(.name)) |n| try out.append(arena, try arena.print("held {s}", .{ip.stringToSlice(n)}));
    try out.append(arena, try arena.print("limit_slots {d}", .{d.limit_slots.len}));
    for (d.displays.items(.name)) |n| try out.append(arena, try arena.print("display {s}", .{ip.stringToSlice(n)}));
    return out.items;
}

// ---- private ----

fn oldNode(lw: *const Lowered, n: Lowered.NodeId) []const u8 {
    return if (n == .ground) "gnd" else lw.nodes.items(.name)[@backingInt(n)];
}

fn newNode(ip: *const InternPool, d: *const Device, n: Device.Node.Index) []const u8 {
    return if (n == .ground) "gnd" else ip.stringToSlice(d.nodes.items(.name)[@backingInt(n)]);
}

/// An interned constant as the old `Const`, null for `undef`.
fn constOf(arena: std.mem.Allocator, ip: *const InternPool, index: InternPool.Index) ?Lowered.Const {
    return switch (ip.indexToKey(index)) {
        .float => |f| .{ .real = f },
        .int => |i| switch (i.storage) {
            .small => |v| .{ .int = v },
            .big => null,
        },
        .str => |s| .{ .str = arena.dupe(u8, ip.stringToSlice(s)) catch return null },
        else => null, // else: an unfoldable default
    };
}

/// Appends a folded value as both sides print it; `?` for none.
fn constText(arena: std.mem.Allocator, line: *std.ArrayList(u8), c: ?Lowered.Const) !void {
    switch (c orelse return line.appendSlice(arena, "?")) {
        .int => |v| try line.print(arena, "{d}", .{v}),
        .real => |v| try line.print(arena, "{e}", .{v}),
        .str => |t| try line.print(arena, "\"{s}\"", .{t}),
    }
}

/// Appends a §3.4.2 range as both sides print it.
fn rangeText(arena: std.mem.Allocator, line: *std.ArrayList(u8), r: Device.Range) !void {
    try line.appendSlice(arena, if (r.exclude) " exclude" else " from");
    if (r.strings) return line.appendSlice(arena, "{strings}");
    try line.print(arena, "{s}{?e}:{?e}{s}", .{ if (r.lo_closed) "[" else "(", r.lo, r.hi, if (r.hi_closed) "]" else ")" });
}
