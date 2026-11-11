//! §6.5 port binding (the old `analog/node.zig`'s child ports): a child
//! instance's ports in, each bound to the parent's node its connection
//! names out (an unconnected port is a net of the child's own; an
//! undeclared parent net takes the port's discipline, Annex F). §7.8.4 a
//! connect module inserted on a port splits it: the child port names the
//! bridge's lower net, and the bridge's other port joins the parent's.
//! Cites: VAMS-2023 §6.5, §7.8.4, Annex F.
//!
//! Contents:
//! - `pub fn bindChildPorts(s: *Sema, unit: *Unit) Allocator.Error!void`
//! - `pub fn bindBridges(s: *Sema) Allocator.Error!void`
//! - `pub fn bridgeNets(s: *Sema, parent: Zcu.Instance.Index) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("intern_pool");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const Zcu = @import("../Zcu.zig");
const decl = @import("decl.zig");
const net = @import("net.zig");
const Node = Air.Device.Node;
const Unit = Sema.Unit;
const canonical = decl.canonical;
const portDecl = decl.portDecl;
const nameOf = decl.nameOf;

/// §6.5 a child's ports: each the node its connection names in the
/// parent; an unconnected port is a net of the child's own.
pub fn bindChildPorts(s: *Sema, unit: *Unit) Allocator.Error!void {
    const zcu = s.zcu;
    const k = @backingInt(unit.instance);
    const parent = zcu.instances.items(.parent)[k];
    const pu = for (s.units.items) |*u| {
        if (u.instance == parent) break u;
    } else unreachable; // a child's parent is a unit before it
    const list = zcu.instances.items(.ports)[k];
    for (zcu.ports.items(.formal)[list.start..][0..list.len], zcu.ports.items(.actual)[list.start..][0..list.len]) |formal, actual| {
        const first = portDecl(unit.vir, formal) orelse continue;
        const node: Node.Index = blk: {
            if (actual.toIndex()) |a| switch (pu.vir.instructions.items(.tag)[@backingInt(a)]) {
                .decl_ref => {
                    const d = canonical(pu.vir, pu.vir.instructions.items(.data)[@backingInt(a)].decl_tok.decl);
                    if (pu.binds.get(d)) |b| if (b == .node) break :blk b.node;
                },
                // The parent's implicit net (`nets`).
                .str_ref => {
                    const flat = try std.fmt.allocPrint(s.arena, "{s}{s}", .{ pu.prefix, pu.vir.string(pu.vir.instructions.items(.data)[@backingInt(a)].str_tok.start) });
                    if (s.node_rows.get(try zcu.intern_pool.getString(s.gpa, flat))) |n| break :blk n;
                },
                else => {}, // else: a select or concatenation, not bound here
            };
            const name = unit.vir.string(nameOf(unit.vir, first));
            break :blk try net.internNode(s, unit, try std.fmt.allocPrint(s.arena, "{s}{s}", .{ unit.prefix, name }), try net.netDiscipline(s, unit, first));
        };
        // §7.8.4 a bridged port names the bridge's lower net; its
        // connection is the bridge's upper side.
        if (s.bridged.getPtr(.{ unit.instance, first })) |br| {
            br.upper = node;
            try unit.binds.put(s.arena, first, .{ .node = br.lower });
            continue;
        }
        // Annex F: a parent net no declaration gives a discipline takes the
        // one of the port it connects to.
        if (node != .ground) {
            const disc = &s.device.nodes.items(.discipline)[@backingInt(node)];
            if (disc.* == .empty) disc.* = try net.netDiscipline(s, unit, first);
        }
        try unit.binds.put(s.arena, first, .{ .node = node });
    }
}

/// The upper side of each bridge `bridgeNets` placed: its other port joins
/// the net the child port's connection names in the parent.
pub fn bindBridges(s: *Sema) Allocator.Error!void {
    var it = s.bridged.iterator();
    while (it.next()) |e| {
        const upper = e.value_ptr.upper;
        if (upper == .none) continue;
        const bu = unitOf(s, e.value_ptr.bridge) orelse continue;
        for (bu.vir.body(bu.module.ports)) |p| {
            const first = portDecl(bu.vir, p) orelse continue;
            if (!bu.binds.contains(first)) try bu.binds.put(s.arena, first, .{ .node = upper });
        }
    }
}

/// §7.8.4 the lower side of each connect module inserted in `parent`,
/// after its declared nets and before its implicit ones (the old
/// flattener's order): the bridge's port of the bridged child port's
/// domain is a net of its own (`<bridge>.<port>`), which that child port
/// names (`Sema.bridged`).
pub fn bridgeNets(s: *Sema, parent: Zcu.Instance.Index) Allocator.Error!void {
    const zcu = s.zcu;
    for (zcu.inserts.items(.instance), zcu.inserts.items(.port), zcu.inserts.items(.bridge)) |child, port, bridge| {
        if (zcu.instances.items(.parent)[@backingInt(bridge)] != parent) continue;
        const cu = unitOf(s, child) orelse continue;
        const bu = unitOf(s, bridge) orelse continue;
        // A primitive's terminal (its `instance` instruction) binds no port here.
        if (cu.vir.instructions.items(.tag)[@backingInt(port)] == .instance) continue;
        const formal = portDecl(cu.vir, port) orelse continue;
        const low_cont = try continuous(s, try net.netDiscipline(s, cu, formal));
        for (bu.vir.body(bu.module.ports)) |p| {
            const first = portDecl(bu.vir, p) orelse continue;
            const disc = try net.netDiscipline(s, bu, first);
            if (try continuous(s, disc) != low_cont) continue;
            const node = if (bu.binds.get(first)) |x| x.node else try net.internNode(s, bu, try std.fmt.allocPrint(s.arena, "{s}{s}", .{ bu.prefix, bu.vir.string(nameOf(bu.vir, first)) }), disc);
            try bu.binds.put(s.arena, first, .{ .node = node });
            try s.bridged.put(s.arena, .{ child, formal }, .{ .lower = node, .upper = .none, .bridge = bridge });
            break;
        }
    }
}

// ---- private ----

fn unitOf(s: *Sema, i: Zcu.Instance.Index) ?*Unit {
    for (s.units.items) |*u| if (u.instance == i) return u;
    return null;
}

/// Whether discipline `name` is of the continuous domain.
fn continuous(s: *Sema, name: InternPool.String) Allocator.Error!bool {
    if (name == .empty) return false;
    return try @import("discipline.zig").domainOf(s, s.zcu.intern_pool.stringToSlice(name)) == .continuous;
}
