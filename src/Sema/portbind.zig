//! §6.5 port binding (the old `analog/node.zig`'s child ports): a child
//! instance's ports in, each bound to the parent's node(s) its connection
//! names out (an unconnected port is a net of the child's own; an
//! undeclared parent net takes the port's discipline, Annex F). §6.5.7.1 a
//! §3.6.3 vector port binds its elements positionally to the connection's
//! bits, IEEE 1364-2005 §12.3.9.2: msb to msb, one net, a vector net, or a
//! concatenation of either (`connNodes`/`memberNodes`), each member a
//! §6.5.5 scalar member or sub-range of a declared vector (E0351 on a net
//! with no range, E0352 outside it, E0925 on a width that disagrees).
//! §7.8.4 a connect module inserted on a port splits it: the child port
//! names the bridge's lower net, and the bridge's other port joins the
//! parent's.
//! Cites: VAMS-2023 §6.5, §6.5.5, §6.5.7.1, §7.8.4, Annex F; IEEE
//! 1364-2005 §5.2.1, §12.3.9.2.
//!
//! Contents:
//! - `pub fn bindChildren(s: *Sema, unit: *Unit) Allocator.Error!void`
//! - `pub fn bindBridges(s: *Sema) Allocator.Error!void`
//! - `pub fn bridgeNets(s: *Sema, parent: Zcu.Instance.Index) Allocator.Error!void`
//! - `Finder.item` (`decl.eachItem`'s visitor; `pub` for `foldConn`'s cross-file call)

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("intern_pool");
const vams = @import("vams");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const Zcu = @import("../Zcu.zig");
const decl = @import("decl.zig");
const net = @import("net.zig");
const eval = @import("eval.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Node = Air.Device.Node;
const Unit = Sema.Unit;
const canonical = decl.canonical;
const payloadOf = decl.payloadOf;
const portDecl = decl.portDecl;
const nameOf = decl.nameOf;

/// `vectorBase`'s result: the bind and the name it was declared with, so a
/// caller's diagnostic can name it as the old `analog/node.zig` messages do.
const VecRef = struct { v: @FieldType(Sema.Bind, "vector"), name: []const u8 };

/// `foldConn`'s fallback visitor: a loop generate scheme unrolls one `src`
/// VIR node into every one of its instances (§6.6.1), so `target` alone
/// does not pick one; `ordinal` (`target`'s `at`-th visit, 0 based) does.
/// `decl.eachItem`'s genvars are bound in `unit.binds` only while it visits
/// that item, so the fold runs from inside the matching callback instead of
/// after the walk has moved on.
const Finder = struct {
    target: Inst.Index,
    ordinal: u32,
    ref: Inst.Ref,
    at: *u32,
    out: *?eval.Const,

    pub fn item(f: Finder, s: *Sema, unit: *Unit, i: Inst.Index) Allocator.Error!void {
        if (i != f.target) return;
        defer f.at.* += 1;
        if (f.at.* != f.ordinal) return;
        f.out.* = try decl.foldRef(s, unit, f.ref);
    }
};

/// §6.5 a child's ports: each the node(s) its connection names in the
/// parent; an unconnected port is a net of the child's own.
pub fn bindChildren(s: *Sema, unit: *Unit) Allocator.Error!void {
    const zcu = s.zcu;
    const k = @backingInt(unit.instance);
    const parent = zcu.instances.items(.parent)[k];
    const pu = for (s.units.items) |*u| {
        if (u.instance == parent) break u;
    } else unreachable; // a child's parent is a unit before it
    const list = zcu.instances.items(.ports)[k];
    for (zcu.ports.items(.formal)[list.start..][0..list.len], zcu.ports.items(.actual)[list.start..][0..list.len]) |formal, actual|
        try bindChild(s, unit, pu, formal, actual);
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

/// One child port, scalar or §3.6.3 vector.
fn bindChild(s: *Sema, unit: *Unit, pu: *Unit, formal: Inst.Index, actual: Inst.Ref) Allocator.Error!void {
    const first = portDecl(unit.vir, formal) orelse return; // a null or concatenated header port binds nothing
    if (try net.vectorRange(s, unit, first)) |r| return bindVector(s, unit, pu, first, r, actual);
    const zcu = s.zcu;
    const node: Node.Index = blk: {
        if (actual.toIndex()) |a| switch (pu.vir.instructions.items(.tag)[@backingInt(a)]) {
            .decl_ref => {
                const d = canonical(pu.vir, pu.vir.instructions.items(.data)[@backingInt(a)].decl_tok.decl);
                if (pu.binds.get(d)) |b| switch (b) {
                    .node => |n| break :blk n,
                    // §6.5.7.1 a vector net or port onto a scalar port.
                    .vector => |v| {
                        try s.fail(.E0925, pu.file, actual, "`{s}` is {d} wide and the port it connects is 1", .{ pu.vir.string(nameOf(pu.vir, d)), v.len });
                        break :blk .ground;
                    },
                    else => {},
                };
            },
            // The parent's implicit net (`nets`).
            .str_ref => {
                const flat = try std.fmt.allocPrint(s.arena, "{s}{s}", .{ pu.prefix, pu.vir.string(pu.vir.instructions.items(.data)[@backingInt(a)].str_tok.start) });
                if (s.node_rows.get(try zcu.intern_pool.getString(s.gpa, flat))) |n| break :blk n;
            },
            // §6.5.5/§6.5.7.1 a select or concatenation onto a scalar port:
            // legal only at width 1.
            .elem, .slice, .slice_up, .slice_down, .concat => {
                var bits: std.ArrayList(Node.Index) = .empty;
                defer bits.deinit(s.arena);
                const ok = try connNodes(s, pu, unit.instance, actual, &bits);
                if (ok and bits.items.len == 1) break :blk bits.items[0];
                if (ok) try s.fail(.E0925, pu.file, actual, "the connection is {d} nets wide and the port it connects is scalar", .{bits.items.len});
                break :blk .ground; // a refused connection binds the port to ground
            },
            else => {}, // else: not a net reference, falls through as unconnected
        };
        const name = unit.vir.string(nameOf(unit.vir, first));
        break :blk try net.internNode(s, unit, try std.fmt.allocPrint(s.arena, "{s}{s}", .{ unit.prefix, name }), try net.netDiscipline(s, unit, first));
    };
    // §7.8.4 a bridged port names the bridge's lower net; its
    // connection is the bridge's upper side.
    if (s.bridged.getPtr(.{ unit.instance, first })) |br| {
        br.upper = node;
        try unit.binds.put(s.arena, first, .{ .node = br.lower });
        return;
    }
    // Annex F: a parent net no declaration gives a discipline takes the
    // one of the port it connects to.
    if (node != .ground) {
        const disc = &s.device.nodes.items(.discipline)[@backingInt(node)];
        if (disc.* == .empty) disc.* = try net.netDiscipline(s, unit, first);
    }
    try unit.binds.put(s.arena, first, .{ .node = node });
}

/// A §3.6.3 vector child port `first`, declared `[r[0]:r[1]]`: its elements
/// bound positionally to the connection's bits (IEEE 1364-2005 §12.3.9.2,
/// msb to msb), or, unconnected, nets of the child's own, one per element.
/// A refused connection (E0925: a width that disagrees) binds every element
/// to ground, as a scalar port's refused connection does.
fn bindVector(s: *Sema, unit: *Unit, pu: *Unit, first: Inst.Index, r: [2]i64, actual: Inst.Ref) Allocator.Error!void {
    const vir = unit.vir;
    const name = vir.string(nameOf(vir, first));
    const disc = try net.netDiscipline(s, unit, first);
    const width: u32 = @intCast(@abs(r[0] - r[1]) + 1);
    var bits: std.ArrayList(Node.Index) = .empty;
    defer bits.deinit(s.arena);
    var connected = false;
    var failed = false;
    if (actual != .none) {
        const ok = try connNodes(s, pu, unit.instance, actual, &bits);
        if (ok and bits.items.len == width) {
            connected = true;
        } else {
            failed = true;
            if (ok) try failWidth(s, pu, actual, bits.items.len, width);
        }
    }
    const at: u32 = @intCast(unit.vec_rows.items.len);
    for (0..width) |kk| {
        const idx: i64 = if (r[0] >= r[1]) r[0] - @as(i64, @intCast(kk)) else r[0] + @as(i64, @intCast(kk));
        const row: Node.Index = if (connected)
            bits.items[kk]
        else if (failed)
            .ground
        else
            try net.internNode(s, unit, try std.fmt.allocPrint(s.arena, "{s}{s}[{d}]", .{ unit.prefix, name, idx }), disc);
        try unit.vec_rows.append(s.arena, row);
    }
    try unit.binds.put(s.arena, first, .{ .vector = .{ .first = at, .len = width, .msb = r[0], .lsb = r[1] } });
}

/// §6.5.7.1 E0925: `actual`'s width disagrees with the vector port's. A
/// plain net or port reference names itself, as the old `analog/node.zig`'s
/// `port_widths` row does; anything else (a concatenation or a select) has
/// no one name, so it reads as `port_concats`'s row does.
fn failWidth(s: *Sema, pu: *Unit, actual: Inst.Ref, got: usize, want: u32) Allocator.Error!void {
    const vir = pu.vir;
    if (actual.toIndex()) |i| switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .decl_ref => {
            const d = canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl);
            return s.fail(.E0925, pu.file, actual, "`{s}` is {d} wide and the port it connects is {d}", .{ vir.string(nameOf(vir, d)), got, want });
        },
        .str_ref => {
            return s.fail(.E0925, pu.file, actual, "`{s}` is {d} wide and the port it connects is {d}", .{ vir.string(vir.instructions.items(.data)[@backingInt(i)].str_tok.start), got, want });
        },
        else => {},
    };
    try s.fail(.E0925, pu.file, actual, "the connection is {d} nets wide and the port it connects is {d}", .{ got, want });
}

/// §6.5.7.1 the nodes `r` (a port connection in `pu`, bound for `child`)
/// names, msb first: one per concatenation member (`memberNodes`), or the
/// one member itself. False after a diagnostic.
fn connNodes(s: *Sema, pu: *Unit, child: Zcu.Instance.Index, r: Inst.Ref, out: *std.ArrayList(Node.Index)) Allocator.Error!bool {
    const vir = pu.vir;
    const i = r.toIndex() orelse return false;
    if (vir.instructions.items(.tag)[@backingInt(i)] == .concat) {
        for (vir.list(Inst.Ref, payloadOf(vir, Inst.Refs, i))) |m|
            if (!try memberNodes(s, pu, child, m, m, out)) return false; // stop at the first failing member
        return true;
    }
    return memberNodes(s, pu, child, r, r, out);
}

/// One member of a port connection (or the whole connection, not a
/// concatenation): every element of a whole vector net, one scalar net, or
/// the elements a constant §6.5.5 select names, appended msb first.
fn memberNodes(s: *Sema, pu: *Unit, child: Zcu.Instance.Index, r: Inst.Ref, src: Inst.Ref, out: *std.ArrayList(Node.Index)) Allocator.Error!bool {
    const vir = pu.vir;
    const i = r.toIndex() orelse return false;
    switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .decl_ref => {
            const d = canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl);
            switch (pu.binds.get(d) orelse return false) {
                .node => |n| try out.append(s.arena, n),
                .vector => |v| for (0..v.len) |k| try out.append(s.arena, pu.vec_rows.items[v.first + k]),
                else => return false,
            }
            return true;
        },
        .str_ref => {
            const flat = try std.fmt.allocPrint(s.arena, "{s}{s}", .{ pu.prefix, vir.string(vir.instructions.items(.data)[@backingInt(i)].str_tok.start) });
            const n = s.node_rows.get(try s.zcu.intern_pool.getString(s.gpa, flat)) orelse try net.internNode(s, pu, flat, .empty);
            try out.append(s.arena, n);
            return true;
        },
        .elem => {
            const x = payloadOf(vir, Inst.Bin, i);
            const vb = (try vectorBase(s, pu, x.lhs, src)) orelse return false;
            const v = vb.v;
            const k = ((try foldConn(s, pu, child, x.rhs)) orelse return false).asIntExact() orelse return false;
            if (k < @min(v.msb, v.lsb) or k > @max(v.msb, v.lsb)) {
                try s.fail(.E0352, pu.file, src, "`{s}` is [{d}:{d}], so {d} is not one of its elements", .{ vb.name, v.msb, v.lsb, k });
                return false;
            }
            const off: u32 = @intCast(if (v.msb >= v.lsb) v.msb - k else k - v.msb);
            try out.append(s.arena, pu.vec_rows.items[v.first + off]);
            return true;
        },
        .slice, .slice_up, .slice_down => |tag| {
            const t = payloadOf(vir, Inst.Triple, i);
            const vb = (try vectorBase(s, pu, t.a, src)) orelse return false;
            const v = vb.v;
            const decl_r: [2]i64 = .{ v.msb, v.lsb };
            const r2: [2]i64 = if (tag == .slice) blk: {
                const m = ((try foldConn(s, pu, child, t.b)) orelse return false).asIntExact() orelse return false;
                const l = ((try foldConn(s, pu, child, t.c)) orelse return false).asIntExact() orelse return false;
                break :blk .{ m, l };
            } else blk: {
                const base = ((try foldConn(s, pu, child, t.b)) orelse return false).asIntExact() orelse return false;
                const w = ((try foldConn(s, pu, child, t.c)) orelse return false).asIntExact() orelse return false;
                if (w < 1) {
                    try s.fail(.E0352, pu.file, src, "the indexed part-select of `{s}` is {d} wide", .{ vb.name, w });
                    return false;
                }
                break :blk net.indexedRange(decl_r, base, w, tag == .slice_down);
            };
            if (!net.partOf(decl_r, r2)) {
                try s.fail(.E0352, pu.file, src, "`{s}` is [{d}:{d}], so [{d}:{d}] is not a part of it", .{ vb.name, decl_r[0], decl_r[1], r2[0], r2[1] });
                return false;
            }
            const n: u32 = @intCast(@abs(r2[0] - r2[1]) + 1);
            for (0..n) |kk| {
                const idx: i64 = if (r2[0] >= r2[1]) r2[0] - @as(i64, @intCast(kk)) else r2[0] + @as(i64, @intCast(kk));
                const off: u32 = @intCast(if (v.msb >= v.lsb) v.msb - idx else idx - v.msb);
                try out.append(s.arena, pu.vec_rows.items[v.first + off]);
            }
            return true;
        },
        else => return false, // else: not a net reference (A.1.3/§6.5.5)
    }
}

/// The §3.6.3 vector bind of `r` (a plain name) in `pu`, or null after an
/// E0351 (no range: §5.5.2's shape shared with an access function's).
fn vectorBase(s: *Sema, pu: *const Unit, r: Inst.Ref, src: Inst.Ref) Allocator.Error!?VecRef {
    const vir = pu.vir;
    const i = r.toIndex() orelse return null;
    if (vir.instructions.items(.tag)[@backingInt(i)] != .decl_ref) return null;
    const d = canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl);
    const name = vir.string(nameOf(vir, d));
    const bind = pu.binds.get(d) orelse return null;
    if (bind != .vector) {
        try s.fail(.E0351, pu.file, src, "`{s}` was not declared with a range", .{name});
        return null;
    }
    return .{ .v = bind.vector, .name = name };
}

/// `r`'s constant value in `pu`, a select's index or bound (§5.5.2 "may
/// include genvar variables"): the direct fold first, which covers every
/// case but a genvar, since `decl.eachItem`'s `.gen_for` binds one in
/// `unit.binds` only while its own walk visits the scheme's items and lets
/// it go once that walk returns (`bindChildren` runs later, over every
/// instance that walk already placed). On a genvar, a fresh walk of `pu`'s
/// schemes places the same instances in the same order, so `child`'s own
/// visit (`ordinalOf`'s count, since a loop scheme's one `src` node is
/// every one of its instances) sees its genvars bound exactly as
/// `decl.eachItem` first had them there.
fn foldConn(s: *Sema, pu: *Unit, child: Zcu.Instance.Index, r: Inst.Ref) Allocator.Error!?eval.Const {
    if (try decl.foldRef(s, pu, r)) |c| return c;
    const zcu = s.zcu;
    const target = zcu.instances.items(.src)[@backingInt(child)].toIndex() orelse return null;
    var at: u32 = 0;
    var found: ?eval.Const = null;
    var env = try decl.envOf(s, pu);
    defer env.deinit();
    try decl.eachItem(s, pu, &env, pu.module.body, Finder{
        .target = target,
        .ordinal = ordinalOf(zcu, child),
        .ref = r,
        .at = &at,
        .out = &found,
    }, 0);
    return found;
}

/// How many instances before `child` share its parent and its `src` node:
/// a loop generate scheme's `at`-th placement of the one VIR node it
/// unrolls (§6.6.1), 0 based.
fn ordinalOf(zcu: *const Zcu, child: Zcu.Instance.Index) u32 {
    const k = @backingInt(child);
    const parent = zcu.instances.items(.parent)[k];
    const src = zcu.instances.items(.src)[k];
    var n: u32 = 0;
    for (0..k) |j| n += @intFromBool(zcu.instances.items(.parent)[j] == parent and zcu.instances.items(.src)[j] == src);
    return n;
}

fn unitOf(s: *Sema, i: Zcu.Instance.Index) ?*Unit {
    for (s.units.items) |*u| if (u.instance == i) return u;
    return null;
}

/// Whether discipline `name` is of the continuous domain.
fn continuous(s: *Sema, name: InternPool.String) Allocator.Error!bool {
    if (name == .empty) return false;
    return try @import("discipline.zig").domainOf(s, s.zcu.intern_pool.stringToSlice(name)) == .continuous;
}
