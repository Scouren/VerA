//! §3.6.3 the device's nets (the old `analog/node.zig`'s declarations):
//! one instance's ports, nets and implicit nets in, their `device.nodes`
//! rows out, a vector's msb first, each with its §3.6.2 discipline (Annex F's
//! resolution, a `port_discipline` attribute, the declaration's, or the
//! §10.2 `default_discipline` in force). A child's port is the parent's net
//! it connects to (`portbind.zig`); a `ground` net reads the reference
//! node.
//! Cites: VAMS-2023 §3.6.2, §3.6.3, §3.6.4, §6.5, §10.2, Annex E.3.2.1,
//! Annex F; IEEE 1364-2005 §4.5.
//!
//! Contents:
//! - `pub fn ports(s: *Sema, unit: *Unit) Allocator.Error!void`
//! - `pub fn nets(s: *Sema, unit: *Unit) Allocator.Error!void`
//! - `pub fn pullDrives(s: *Sema) Allocator.Error!void`
//! - `pub fn signalFlowPorts(s: *Sema) Allocator.Error!void`
//! - `pub fn isSignalFlow(s: *Sema, disc: InternPool.String) Allocator.Error!bool`
//! - `pub fn inputPortOf(s: *Sema, n: Node.Index) ?[]const u8`
//! - `pub fn netDiscipline(s: *Sema, unit: *const Unit, first: Inst.Index) Allocator.Error!InternPool.String`
//! - `pub fn internNode(s: *Sema, unit: *const Unit, name: []const u8, discipline: InternPool.String) Allocator.Error!Node.Index`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const Zcu = @import("../Zcu.zig");
const decl = @import("decl.zig");
const eval = @import("eval.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Node = Air.Device.Node;
const Unit = Sema.Unit;
const canonical = decl.canonical;
const payloadOf = decl.payloadOf;
const portDecl = decl.portDecl;
const nameOf = decl.nameOf;
const rowInstance = decl.rowInstance;

/// §6.5 the root's ports, in header order: the first rows.
pub fn ports(s: *Sema, unit: *Unit) Allocator.Error!void {
    const vir = unit.vir;
    for (vir.body(unit.module.ports)) |p| {
        const first = portDecl(vir, p) orelse continue;
        try declareNet(s, unit, first);
    }
}

/// §3.6.3 the instance's nets: every `net` and `io` not bound yet. §3.6.4
/// a `ground` net is the reference node. A child's port waits for
/// `bindChildPorts`.
pub fn nets(s: *Sema, unit: *Unit) Allocator.Error!void {
    const vir = unit.vir;
    const tags = vir.instructions.items(.tag);
    var child_ports: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
    if (unit.prefix.len != 0) for (vir.body(unit.module.ports)) |p| if (portDecl(vir, p)) |d| try child_ports.put(s.arena, d, {});
    for (vir.body(unit.module.body)) |i| {
        const tag = tags[@backingInt(i)];
        if (tag != .net and tag != .io) continue;
        const first = canonical(vir, i);
        if (unit.binds.contains(first) or child_ports.contains(first)) continue;
        if (std.mem.findScalar(Inst.Index, unit.discrete.items, first) != null) continue;
        if (tag == .io and tags[@backingInt(first)] == .io and !hasNet(unit, first)) continue;
        try declareNet(s, unit, first);
    }
    try @import("portbind.zig").bridgeNets(s, unit.instance);
    // §6.5.4 (IEEE 1364-2005 §4.5) a name an instance connects that no
    // declaration names is an implicit net of this instance.
    const zcu = s.zcu;
    for (0..zcu.instances.len) |k| {
        if (zcu.instances.items(.parent)[k] != unit.instance) continue;
        const list = zcu.instances.items(.ports)[k];
        for (zcu.ports.items(.actual)[list.start..][0..list.len]) |actual| {
            const a = actual.toIndex() orelse continue;
            if (tags[@backingInt(a)] != .str_ref) continue;
            const name = vir.string(vir.instructions.items(.data)[@backingInt(a)].str_tok.start);
            const net = try zcu.intern_pool.getString(s.gpa, name);
            const disc = zcu.net_discipline.get(.{ .instance = unit.instance, .net = net }) orelse .empty;
            _ = try internNode(s, unit, try std.fmt.allocPrint(s.arena, "{s}{s}", .{ unit.prefix, name }), disc);
        }
    }
}

/// §3.6.2 the discipline of net `first`: the one Annex F resolution gave
/// it (`zcu.net_discipline`: its declaration's, a `port_discipline`
/// attribute's, or its segments'), else its declaration's, else the §10.2
/// `default_discipline` in force at it (one qualified by its net type, else
/// the unqualified one), else none.
pub fn netDiscipline(s: *Sema, unit: *const Unit, first: Inst.Index) Allocator.Error!InternPool.String {
    const vir = unit.vir;
    const ip = &s.zcu.intern_pool;
    if (try portDisciplineAttr(s, unit, first)) |d| return d;
    const net = try ip.getString(s.gpa, vir.string(nameOf(vir, first)));
    if (s.zcu.net_discipline.get(.{ .instance = unit.instance, .net = net })) |d| return d;
    const declared = disciplineOf(unit, first);
    if (declared != .empty) return ip.getString(s.gpa, vir.string(declared));
    if (defaultOf(unit, first)) |dflt| return ip.getString(s.gpa, vir.string(dflt));
    return .empty;
}

/// §1.3.4 a signal-flow port (its discipline binds one nature) has the
/// direction of its one quantity, so the root's `inout` one is E0360.
pub fn signalFlowPorts(s: *Sema) Allocator.Error!void {
    const unit = &s.units.items[0];
    const vir = unit.vir;
    for (vir.body(unit.module.ports)) |p| {
        const first = portDecl(vir, p) orelse continue;
        if (dirOf(unit, first) != .inout) continue;
        const bind = unit.binds.get(first) orelse continue;
        const n: Node.Index = switch (bind) {
            .node => |x| x,
            .vector => |v| unit.vec_rows.items[v.first],
            else => continue,
        };
        if (n == .ground) continue;
        const disc = s.device.nodes.items(.discipline)[@backingInt(n)];
        if (!try isSignalFlow(s, disc)) continue;
        try s.fail(.E0360, unit.file, first.toRef(), "`{s}` is an `inout` port of discipline `{s}`, which binds one nature only", .{ vir.string(nameOf(vir, first)), s.zcu.intern_pool.stringToSlice(disc) });
    }
}

/// §1.3.4 whether discipline `disc` binds exactly one of potential and flow.
pub fn isSignalFlow(s: *Sema, disc: InternPool.String) Allocator.Error!bool {
    if (disc == .empty) return false;
    const zcu = s.zcu;
    const d = zcu.disciplines.get(disc) orelse return false;
    const dvir = zcu.fileVir(d.file);
    var potential = false;
    var flow = false;
    for (dvir.list(Inst.DisciplineItem, payloadOf(dvir, Inst.Discipline, zcu.declRow(d).inst).items)) |it| switch (it.kind) {
        .potential => potential = true,
        .flow => flow = true,
        .domain, .potential_attr, .flow_attr, .attr => {},
    };
    return potential != flow;
}

/// The name of the root's `input` port whose node is `n`, or null.
pub fn inputPortOf(s: *Sema, n: Node.Index) ?[]const u8 {
    if (n == .ground or @backingInt(n) >= s.device.num_ports) return null;
    const unit = &s.units.items[0];
    const vir = unit.vir;
    for (vir.body(unit.module.ports)) |p| {
        const first = portDecl(vir, p) orelse continue;
        const bind = unit.binds.get(first) orelse continue;
        if (bind != .node or bind.node != n) continue;
        if (dirOf(unit, first) == .input) return vir.string(nameOf(vir, first));
    }
    return null;
}

/// IEEE 1364-2005 §19.9 `unconnected_drive`: each child's `input` port its
/// instance leaves unconnected is held at potential 0 (`pull0`) or 1
/// (`pull1`) by a potential source, when its discipline binds a potential
/// (the old `applyUnconnectedDrive`). Runs before any analog block lowers.
/// ponytail: 1.0 stands in for §19.9's Pu1 strength (the old's choice).
pub fn pullDrives(s: *Sema) Allocator.Error!void {
    const zcu = s.zcu;
    for (s.units.items[1..]) |*unit| {
        const drive = unit.module.stamp.flags.drive;
        if (drive == .float) continue;
        const list = zcu.instances.items(.ports)[@backingInt(unit.instance)];
        for (zcu.ports.items(.formal)[list.start..][0..list.len], zcu.ports.items(.actual)[list.start..][0..list.len]) |formal, actual| {
            if (actual != .none) continue;
            const first = portDecl(unit.vir, formal) orelse continue;
            if (!isInput(unit, first)) continue;
            const bind = unit.binds.get(first) orelse continue;
            if (bind != .node or bind.node == .ground) continue;
            const disc = s.device.nodes.items(.discipline)[@backingInt(bind.node)];
            const d = zcu.disciplines.get(disc) orelse continue;
            const dvir = zcu.fileVir(d.file);
            const binds_potential = for (dvir.list(Inst.DisciplineItem, payloadOf(dvir, Inst.Discipline, zcu.declRow(d).inst).items)) |it| {
                if (it.kind == .potential) break true;
            } else false;
            if (!binds_potential) continue;
            const b: Sema.Block = .{ .parent = null, .unit = unit };
            const row = try @import("contrib.zig").rowOf(s, &b, .{ .access = .potential, .branch = .unnamed, .hi = bind.node, .lo = .ground, .neg = false });
            const c = s.device.contributions.get(@backingInt(row));
            const level: InternPool.Index = if (drive == .pull1) .one_real else .zero_real;
            try s.entry.append(s.arena, try s.air.addInst(s.gpa, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(c.resist), .rhs = .fromIntern(level) } } }));
            try s.entry.append(s.arena, try s.air.addInst(s.gpa, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(c.wrote), .rhs = .fromIntern(.one_real) } } }));
        }
    }
}

/// Appends a node row named `name` (or returns the row already named so).
pub fn internNode(s: *Sema, unit: *const Unit, name: []const u8, discipline: InternPool.String) Allocator.Error!Node.Index {
    const ip = &s.zcu.intern_pool;
    const key = try ip.getString(s.gpa, name);
    const gop = try s.node_rows.getOrPut(s.arena, key);
    if (gop.found_existing) {
        // A later declaration of the name may be the one that gives it a
        // discipline (a port whose net declaration AstGen did not chain).
        const disc = &s.device.nodes.items(.discipline)[@backingInt(gop.value_ptr.*)];
        if (disc.* == .empty) disc.* = discipline;
        return gop.value_ptr.*;
    }
    const row: Node.Index = @fromBackingInt(@intCast(s.device.nodes.len));
    try s.device.nodes.append(s.gpa, .{ .name = key, .kind = .net, .of = .none, .discipline = discipline, .instance = rowInstance(unit.instance) });
    gop.value_ptr.* = row;
    assert(@backingInt(row) + 1 == s.device.nodes.len);
    return row;
}

// ---- private ----

/// Whether any declaration of `first`'s name is an `input`.
fn isInput(unit: *const Unit, first: Inst.Index) bool {
    return dirOf(unit, first) == .input;
}

/// The direction a declaration of `first`'s name gives, or `.none`.
fn dirOf(unit: *const Unit, first: Inst.Index) Inst.Direction {
    const vir = unit.vir;
    for ([_]Vir.Body{ unit.module.ports, unit.module.body }) |body| for (vir.body(body)) |i| {
        if (vir.instructions.items(.tag)[@backingInt(i)] != .io or canonical(vir, i) != first) continue;
        const d = payloadOf(vir, Inst.Io, i).flags.dir;
        if (d != .none) return d;
    };
    return .none;
}

/// Annex E.3.2.1 a shipped primitive's port under its instance's
/// `port_discipline` attribute (a string naming a discipline; elaboration
/// judged it, E0358): that discipline. Null for any other net.
fn portDisciplineAttr(s: *Sema, unit: *const Unit, first: Inst.Index) Allocator.Error!?InternPool.String {
    const zcu = s.zcu;
    const k = @backingInt(unit.instance);
    if (!zcu.isBuiltin(zcu.instances.items(.module)[k])) return null;
    if (unit.vir.instructions.items(.tag)[@backingInt(first)] != .io) return null;
    const parent = zcu.instances.items(.parent)[k];
    if (parent == .none) return null;
    const src = zcu.instances.items(.src)[k].toIndex() orelse return null;
    const pfile = for (s.units.items) |*u| {
        if (u.instance == parent) break u.file;
    } else return null;
    const pvir = zcu.fileVir(pfile);
    if (pvir.instructions.items(.tag)[@backingInt(src)] != .instance) return null;
    for (pvir.list(Inst.Attr, payloadOf(pvir, Inst.Instance, src).attrs)) |a| {
        if (!std.mem.eql(u8, pvir.string(a.name), "port_discipline") or a.value.len == 0) continue;
        var env: eval.Env = try .init(s.gpa, s.arena, &zcu.intern_pool, pvir, &.{});
        defer env.deinit();
        const c = (try env.body(a.value)) orelse continue;
        if (c == .str and zcu.disciplines.contains(try zcu.intern_pool.getString(s.gpa, c.str))) return try zcu.intern_pool.getString(s.gpa, c.str);
    }
    return null;
}

/// §10.2 the `default_discipline` in force at any declaration of `first`'s
/// name: one qualified by the declaration's net type (`wire` when none is
/// written by any declaration of the name), else the unqualified one.
fn defaultOf(unit: *const Unit, first: Inst.Index) ?Vir.String {
    const vir = unit.vir;
    const tags = vir.instructions.items(.tag);
    // `inout q; tri q;`: the net type is the declaration that writes one.
    var net: Inst.NetKind = .none;
    var defaults: ?Vir.List(Inst.Default) = null;
    for ([_]Vir.Body{ unit.module.ports, unit.module.body }) |body| for (vir.body(body)) |i| {
        if (canonical(vir, i) != first) continue;
        const kind: Inst.NetKind, const stamps = switch (tags[@backingInt(i)]) {
            .net => .{ payloadOf(vir, Inst.Net, i).flags.net, payloadOf(vir, Inst.Net, i).defaults },
            .io => .{ payloadOf(vir, Inst.Io, i).flags.net, payloadOf(vir, Inst.Io, i).defaults },
            else => continue, // else: only a net or a direction carries the stamps
        };
        if (defaults == null) defaults = stamps;
        if (net == .none and kind != .none) net = kind;
    };
    const want = std.meta.stringToEnum(@FieldType(@FieldType(Inst.Default, "flags"), "qualifier"), if (net == .none) "wire" else @tagName(net));
    var fallback: ?Vir.String = null;
    for (vir.list(Inst.Default, defaults orelse return null)) |x| {
        if (x.flags.qualified and want != null and x.flags.qualifier == want.?) return x.discipline;
        if (!x.flags.qualified) fallback = x.discipline;
    }
    return fallback;
}

/// The discipline any declaration of `first`'s name in the module gives it.
fn disciplineOf(unit: *const Unit, first: Inst.Index) Vir.String {
    const vir = unit.vir;
    const tags = vir.instructions.items(.tag);
    if (tags[@backingInt(first)] == .net) {
        const n = payloadOf(vir, Inst.Net, first);
        if (n.discipline != .empty) return n.discipline;
    }
    for (vir.body(unit.module.body)) |i| {
        if (canonical(vir, i) != first) continue;
        switch (tags[@backingInt(i)]) {
            .net => {
                const n = payloadOf(vir, Inst.Net, i);
                if (n.discipline != .empty) return n.discipline;
            },
            .io => {
                const io = payloadOf(vir, Inst.Io, i);
                if (io.discipline != .empty) return io.discipline;
            },
            else => {}, // else: only a net or a direction carries a discipline
        }
    }
    return .empty;
}

/// §3.6.4 whether any declaration of `first`'s name is `ground`.
fn isGround(unit: *const Unit, first: Inst.Index) bool {
    const vir = unit.vir;
    for (vir.body(unit.module.body)) |i| {
        if (vir.instructions.items(.tag)[@backingInt(i)] != .net or canonical(vir, i) != first) continue;
        if (payloadOf(vir, Inst.Net, i).flags.net == .ground) return true;
    }
    return false;
}

/// One net or port: a row, or a §3.6.3 vector's rows msb first (`name[k]`).
/// §3.6.4 a `ground` net keeps its row, and its name reads the reference node.
fn declareNet(s: *Sema, unit: *Unit, first: Inst.Index) Allocator.Error!void {
    const vir = unit.vir;
    const name = vir.string(nameOf(vir, first));
    const disc = try netDiscipline(s, unit, first);
    if (try vectorRange(s, unit, first)) |r| {
        const at: u32 = @intCast(unit.vec_rows.items.len);
        const n: u32 = @intCast(@abs(r[0] - r[1]) + 1);
        for (0..n) |k| {
            const i: i64 = if (r[0] >= r[1]) r[0] - @as(i64, @intCast(k)) else r[0] + @as(i64, @intCast(k));
            try unit.vec_rows.append(s.arena, try internNode(s, unit, try std.fmt.allocPrint(s.arena, "{s}{s}[{d}]", .{ unit.prefix, name, i }), disc));
        }
        try unit.binds.put(s.arena, first, .{ .vector = .{ .first = at, .len = n, .msb = r[0], .lsb = r[1] } });
        return;
    }
    const row = try internNode(s, unit, try std.fmt.allocPrint(s.arena, "{s}{s}", .{ unit.prefix, name }), disc);
    try unit.binds.put(s.arena, first, .{ .node = if (isGround(unit, first)) .ground else row });
}

/// The folded `[msb:lsb]` any declaration of `first`'s name carries, or null.
fn vectorRange(s: *Sema, unit: *Unit, first: Inst.Index) Allocator.Error!?[2]i64 {
    const vir = unit.vir;
    for ([_]Vir.Body{ unit.module.ports, unit.module.body }) |body| for (vir.body(body)) |i| {
        const tag = vir.instructions.items(.tag)[@backingInt(i)];
        if (tag != .net and tag != .io) continue;
        if (canonical(vir, i) != first) continue;
        const range = if (tag == .net) payloadOf(vir, Inst.Net, i).range else payloadOf(vir, Inst.Io, i).range;
        const insts = vir.body(range);
        if (insts.len == 0) continue;
        const bin = payloadOf(vir, Inst.Bin, insts[insts.len - 1]);
        var env = try decl.envOf(s, unit);
        defer env.deinit();
        const msb = ((try env.ref(bin.lhs)) orelse return null).asIntExact() orelse return null;
        const lsb = ((try env.ref(bin.rhs)) orelse return null).asIntExact() orelse return null;
        return .{ msb, lsb };
    };
    return null;
}

/// Whether a `net` declares the name `first` (an `io`) names too.
fn hasNet(unit: *const Unit, first: Inst.Index) bool {
    const vir = unit.vir;
    for (vir.body(unit.module.body)) |i| {
        if (vir.instructions.items(.tag)[@backingInt(i)] == .net and canonical(vir, i) == first) return true;
    }
    return false;
}
