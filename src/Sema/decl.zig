//! The lowering spine and the declarations (Zig's `Sema/type_resolution`
//! role): the elaborated instance tree in `Zcu` in; out, the device's
//! unknowns, model card, branches and slots, then every instance's analog
//! blocks lowered into one `Air` body, the old flattener's order (the root's
//! ports, every instance's nets, parameters and branches, then each
//! instance's analog blocks, depth first). A child's port is the parent's
//! net it connects to; a child's own net, parameter and branch take the
//! child's path as a prefix (`u1.r`), as the old flat names do.
//! Cites: VAMS-2023 §1.3.1, §3.2, §3.4, §3.4.2, §3.6.3, §3.6.4, §3.12,
//! §6.2.2, §6.5.
//!
//! Contents:
//! - `pub fn run(s: *Sema) Allocator.Error![]const Air.Inst.Index`
//! - `pub fn canonical(vir: *const Vir, i: Inst.Index) Inst.Index`
//! - `pub fn payloadOf(vir: *const Vir, comptime T: type, i: Inst.Index) T`
//! - `pub fn addAlloc(s: *Sema, ty: Sema.Ty) Allocator.Error!Air.Inst.Index`
//! - `pub fn tyOf(storage: Inst.Storage) Sema.Ty`
//! - `pub fn foldBody(s: *Sema, unit: *Sema.Unit, b: Vir.Body) Allocator.Error!?eval.Const`
//! - `pub fn intern(s: *Sema, c: eval.Const) Allocator.Error!InternPool.Index`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const Zcu = @import("../Zcu.zig");
const eval = @import("eval.zig");
const control = @import("control.zig");
const syscall = @import("syscall.zig");
const contrib = @import("contrib.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Device = Air.Device;
const Node = Device.Node;
const Unit = Sema.Unit;
const Block = Sema.Block;

/// Lowers the design under `zcu.instances[0]` and returns the main body,
/// its `ret` included. Asserts that nothing was lowered before.
pub fn run(s: *Sema) Allocator.Error![]const Air.Inst.Index {
    const zcu = s.zcu;
    assert(s.units.items.len == 0);
    assert(s.device.nodes.len == 0);
    try units(s);
    if (s.units.items.len == 0) return finish(s, &.{});
    try contrib.loadDisciplines(s);
    try ports(s, &s.units.items[0]);
    s.device.num_ports = @intCast(s.device.nodes.len);
    for (s.units.items) |*u| try nets(s, u);
    for (s.units.items[1..]) |*u| try bindChildPorts(s, u);
    for (s.units.items) |*u| try params(s, u);
    for (s.units.items) |*u| try branches(s, u);
    for (s.units.items) |*u| try variables(s, u);
    var main: Block = .{ .parent = null, .unit = &s.units.items[0] };
    for (s.units.items) |*u| {
        main.unit = u;
        for (u.vir.body(u.module.body)) |i| {
            const tag = u.vir.instructions.items(.tag)[@backingInt(i)];
            if (tag != .analog and tag != .analog_initial) continue;
            var b = main.child();
            b.analog_initial = tag == .analog_initial;
            try control.body(s, &b, payloadOf(u.vir, Inst.Process, i).body);
            try main.insts.appendSlice(s.arena, b.insts.items);
        }
    }
    try syscall.finishDisplays(s, &main);
    assert(zcu.instances.len >= s.units.items.len);
    return finish(s, main.insts.items);
}

/// A declaration's first instruction: the root of its `prev` chain, the
/// key every `decl_ref` to the name reaches.
pub fn canonical(vir: *const Vir, i: Inst.Index) Inst.Index {
    assert(@backingInt(i) < vir.instructions.len);
    const tag = vir.instructions.items(.tag)[@backingInt(i)];
    switch (tag) {
        .io, .net, .variable, .param, .aliasparam, .genvar, .event, .branch, .instance, .function, .gen_block => {},
        else => return i, // else: no other tag declares a name
    }
    const at = vir.instructions.items(.data)[@backingInt(i)].pl_node.payload_index;
    const prev: Inst.Ref = @fromBackingInt(vir.extra[at + 1]);
    const first = prev.toIndex() orelse return i;
    assert(@backingInt(first) < @backingInt(i));
    return first;
}

/// The `T` payload of `pl_node` instruction `i`.
pub fn payloadOf(vir: *const Vir, comptime T: type, i: Inst.Index) T {
    assert(@backingInt(i) < vir.instructions.len);
    return vir.extraData(T, vir.instructions.items(.data)[@backingInt(i)].pl_node.payload_index);
}

/// A slot of type `ty` in the main body's prologue, readable from every body.
pub fn addAlloc(s: *Sema, ty: Sema.Ty) Allocator.Error!Air.Inst.Index {
    const i = try s.air.addInst(s.gpa, .{ .tag = .alloc, .data = .{ .ty = typeIndex(ty) } });
    try s.prologue.append(s.arena, i);
    assert(s.prologue.items[s.prologue.items.len - 1] == i);
    return i;
}

/// §3.2 the value type a declared storage keyword gives.
pub fn tyOf(storage: Inst.Storage) Sema.Ty {
    return switch (storage) {
        .real, .realtime => .real,
        .integer, .time, .reg, .none => .integer,
        .string => .string,
    };
}

/// The constant value of body `b` in `unit`'s instance, or null.
pub fn foldBody(s: *Sema, unit: *Unit, b: Vir.Body) Allocator.Error!?eval.Const {
    var env = try envOf(s, unit);
    defer env.deinit();
    return env.body(b);
}

/// Interns a folded constant.
pub fn intern(s: *Sema, c: eval.Const) Allocator.Error!InternPool.Index {
    const index = try s.zcu.intern_pool.get(s.gpa, switch (c) {
        .int => |v| .{ .int = .{ .ty = .integer_type, .storage = .{ .small = v } } },
        .real => |v| .{ .float = v },
        .str => |t| .{ .str = try s.zcu.intern_pool.getString(s.gpa, t) },
    });
    assert(index != .none);
    return index;
}

// ---- private ----

fn typeIndex(ty: Sema.Ty) InternPool.Index {
    return switch (ty) {
        .real => .real_type,
        .integer => .integer_type,
        .string => .string_type,
    };
}

/// The main body: the prologue's slots, `body`, and the `ret`.
fn finish(s: *Sema, body: []const Air.Inst.Index) Allocator.Error![]const Air.Inst.Index {
    const ret = try s.air.addUnOp(s.gpa, .ret, .fromIntern(.zero_real));
    const main = try s.arena.alloc(Air.Inst.Index, s.prologue.items.len + body.len + 1);
    @memcpy(main[0..s.prologue.items.len], s.prologue.items);
    @memcpy(main[s.prologue.items.len..][0..body.len], body);
    main[main.len - 1] = ret;
    assert(main.len >= 1);
    return main;
}

/// One unit per module instance under the first root, in preorder; a UDP
/// instance has no analog half.
fn units(s: *Sema) Allocator.Error!void {
    const zcu = s.zcu;
    const ip = &zcu.intern_pool;
    for (0..zcu.instances.len) |k| {
        const index: Zcu.Instance.Index = @fromBackingInt(@intCast(k));
        const d = zcu.instances.items(.module)[k];
        if (k != 0 and zcu.instances.items(.parent)[k] == .none) break;
        const row = zcu.declRow(d);
        if (row.kind == .primitive) continue;
        const vir = zcu.fileVir(d.file);
        const parent = zcu.instances.items(.parent)[k];
        const prefix: []const u8 = if (parent == .none) "" else blk: {
            const pu = for (s.units.items) |*u| {
                if (u.instance == parent) break u;
            } else unreachable; // preorder: the parent's unit came first
            break :blk try std.fmt.allocPrint(s.arena, "{s}{s}.", .{ pu.prefix, ip.stringToSlice(zcu.instances.items(.name)[k]) });
        };
        try s.units.append(s.arena, .{
            .instance = index,
            .file = d.file,
            .vir = vir,
            .module = payloadOf(vir, Inst.Module, row.inst),
            .prefix = prefix,
        });
    }
}

/// An evaluator over `unit`'s module with the instance's folded parameters.
fn envOf(s: *Sema, unit: *Unit) Allocator.Error!eval.Env {
    const zcu = s.zcu;
    var env: eval.Env = try .init(s.gpa, s.arena, &zcu.intern_pool, unit.vir, &.{ unit.module.params, unit.module.body });
    errdefer env.deinit();
    const elems = zcu.intern_pool.indexToKey(zcu.instances.items(.params)[@backingInt(unit.instance)]).aggregate.elems;
    assert(elems.len == env.values.items.len);
    @memcpy(env.values.items, elems);
    env.hier = zcu.instances.items(.hier)[@backingInt(unit.instance)];
    return env;
}

/// Appends a node row named `name` (or returns the row already named so).
fn internNode(s: *Sema, name: []const u8, discipline: Vir.String, vir: *const Vir) Allocator.Error!Node.Index {
    const ip = &s.zcu.intern_pool;
    const key = try ip.getString(s.gpa, name);
    const gop = try s.node_rows.getOrPut(s.arena, key);
    if (gop.found_existing) return gop.value_ptr.*;
    const row: Node.Index = @fromBackingInt(@intCast(s.device.nodes.len));
    try s.device.nodes.append(s.gpa, .{ .name = key, .kind = .net, .of = .none, .discipline = try ip.getString(s.gpa, vir.string(discipline)) });
    gop.value_ptr.* = row;
    assert(@backingInt(row) + 1 == s.device.nodes.len);
    return row;
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

/// §6.5 the root's ports, in header order: the first rows.
fn ports(s: *Sema, unit: *Unit) Allocator.Error!void {
    const vir = unit.vir;
    const tags = vir.instructions.items(.tag);
    for (vir.body(unit.module.ports)) |p| {
        const first = portDecl(vir, p) orelse continue;
        const name = vir.string(nameOf(vir, first));
        const row = try internNode(s, try std.fmt.allocPrint(s.arena, "{s}{s}", .{ unit.prefix, name }), disciplineOf(unit, first), vir);
        try unit.binds.put(s.arena, first, .{ .node = row });
        _ = tags;
    }
}

/// The declaration a header port names: an ANSI `io` itself, or the net a
/// non-ANSI port expression names. Null for a null or concatenated port.
fn portDecl(vir: *const Vir, p: Inst.Index) ?Inst.Index {
    const tags = vir.instructions.items(.tag);
    switch (tags[@backingInt(p)]) {
        .io => return canonical(vir, p),
        .port => {
            const port = payloadOf(vir, Inst.Port, p);
            const b = vir.body(port.value);
            if (b.len == 0) return null;
            const last = b[b.len - 1];
            if (tags[@backingInt(last)] != .decl_ref) return null;
            return canonical(vir, vir.instructions.items(.data)[@backingInt(last)].decl_tok.decl);
        },
        else => return null, // else: a header holds only ports and directions
    }
}

/// The name a declaring instruction declares (its payload's first word).
fn nameOf(vir: *const Vir, i: Inst.Index) Vir.String {
    const at = vir.instructions.items(.data)[@backingInt(i)].pl_node.payload_index;
    return @fromBackingInt(vir.extra[at]);
}

/// §3.6.3 the instance's nets: every `net` and `io` not bound yet. §3.6.4
/// a `ground` net is the reference node. A child's port waits for
/// `bindChildPorts`.
fn nets(s: *Sema, unit: *Unit) Allocator.Error!void {
    const vir = unit.vir;
    const tags = vir.instructions.items(.tag);
    var child_ports: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
    if (unit.prefix.len != 0) for (vir.body(unit.module.ports)) |p| if (portDecl(vir, p)) |d| try child_ports.put(s.arena, d, {});
    for (vir.body(unit.module.body)) |i| {
        const tag = tags[@backingInt(i)];
        if (tag != .net and tag != .io) continue;
        const first = canonical(vir, i);
        if (unit.binds.contains(first) or child_ports.contains(first)) continue;
        if (tag == .io and tags[@backingInt(first)] == .io and !hasNet(unit, first)) continue;
        if (isGround(unit, first)) {
            try unit.binds.put(s.arena, first, .{ .node = .ground });
            continue;
        }
        const name = vir.string(nameOf(vir, first));
        const row = try internNode(s, try std.fmt.allocPrint(s.arena, "{s}{s}", .{ unit.prefix, name }), disciplineOf(unit, first), vir);
        try unit.binds.put(s.arena, first, .{ .node = row });
    }
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

/// Whether a `net` declares the name `first` (an `io`) names too.
fn hasNet(unit: *const Unit, first: Inst.Index) bool {
    const vir = unit.vir;
    for (vir.body(unit.module.body)) |i| {
        if (vir.instructions.items(.tag)[@backingInt(i)] == .net and canonical(vir, i) == first) return true;
    }
    return false;
}

/// §6.5 a child's ports: each the node its connection names in the
/// parent; an unconnected port is a net of the child's own.
fn bindChildPorts(s: *Sema, unit: *Unit) Allocator.Error!void {
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
            if (actual.toIndex()) |a| if (pu.vir.instructions.items(.tag)[@backingInt(a)] == .decl_ref) {
                const d = canonical(pu.vir, pu.vir.instructions.items(.data)[@backingInt(a)].decl_tok.decl);
                if (pu.binds.get(d)) |b| if (b == .node) break :blk b.node;
            };
            const name = unit.vir.string(nameOf(unit.vir, first));
            break :blk try internNode(s, try std.fmt.allocPrint(s.arena, "{s}{s}", .{ unit.prefix, name }), disciplineOf(unit, first), unit.vir);
        };
        try unit.binds.put(s.arena, first, .{ .node = node });
    }
}

/// §3.4 the instance's parameters, in declaration order: the root's on
/// the card, a child's as local rows of the folded value. Each is read by
/// an `arg` in the prologue.
fn params(s: *Sema, unit: *Unit) Allocator.Error!void {
    const zcu = s.zcu;
    const ip = &zcu.intern_pool;
    const vir = unit.vir;
    const elems = ip.indexToKey(zcu.instances.items(.params)[@backingInt(unit.instance)]).aggregate.elems;
    var at: usize = 0;
    for ([_]Vir.Body{ unit.module.params, unit.module.body }) |b| for (vir.body(b)) |i| {
        if (vir.instructions.items(.tag)[@backingInt(i)] != .param) continue;
        defer at += 1;
        const p = payloadOf(vir, Inst.Param, i);
        if (p.flags.kind == .specparam) continue;
        const ty: Device.Param.Type = switch (p.flags.storage) {
            .real, .realtime => .real,
            .integer, .time => .integer,
            .string => .string,
            .none, .reg => if (p.range.len != 0) .integer else .unspecified,
        };
        const row: Device.Param.Index = @fromBackingInt(@intCast(s.device.params.len));
        const ranges_start: u32 = @intCast(s.device.ranges.items.len);
        for (vir.list(Inst.ValueRange, p.ranges)) |r| try s.device.ranges.append(s.gpa, try rangeOf(s, unit, r));
        try s.device.params.append(s.gpa, .{
            .name = try ip.getString(s.gpa, try std.fmt.allocPrint(s.arena, "{s}{s}", .{ unit.prefix, vir.string(p.name) })),
            .ty = ty,
            .local = p.flags.local or unit.prefix.len != 0,
            .default = elems[at],
            .ranges_start = ranges_start,
            .ranges_len = @intCast(s.device.ranges.items.len - ranges_start),
        });
        try unit.binds.put(s.arena, canonical(vir, i), .{ .param = row });
        const vty: Sema.Ty = switch (ty) {
            .real => .real,
            .integer => .integer,
            .string => .string,
            .unspecified => switch (ip.indexToKey(elems[at])) {
                .float => .real,
                .str => .string,
                else => .integer, // else: an integer, or an unfoldable default read as one
            },
        };
        const arg = try s.air.addInst(s.gpa, .{ .tag = .arg, .data = .{ .ty_index = .{ .ty = typeIndex(vty), .index = @backingInt(row) } } });
        try s.prologue.append(s.arena, arg);
        try s.param_args.append(s.arena, .{ .ref = .fromIndex(arg), .ty = vty });
    };
    assert(s.param_args.items.len == s.device.params.len);
}

/// §3.4.2 one range, each bound folded over literals alone.
fn rangeOf(s: *Sema, unit: *Unit, r: Inst.ValueRange) Allocator.Error!Device.Range {
    const lo = try literalBound(s, unit, r.lo);
    const hi = if (r.flags.interval) try literalBound(s, unit, r.hi) else lo;
    return .{
        .exclude = r.flags.exclude,
        .lo = if (r.flags.set) null else lo,
        .hi = if (r.flags.set) null else hi,
        .lo_closed = if (r.flags.interval) r.flags.lo_closed else true,
        .hi_closed = if (r.flags.interval) r.flags.hi_closed else true,
        .strings = r.flags.set,
    };
}

/// A bound's value when it reads no name; a NaN or string is none.
fn literalBound(s: *Sema, unit: *Unit, b: Vir.Body) Allocator.Error!?f64 {
    const vir = unit.vir;
    for (vir.body(b)) |i| switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .decl_ref, .str_ref, .call_sys, .call => return null,
        else => {}, // else: a literal or an operator over literals
    };
    const c = (try foldBody(s, unit, b)) orelse return null;
    if (c == .str) return null;
    const x = c.asReal();
    return if (std.math.isNan(x)) null else x;
}

/// §3.12 the instance's named branches, in declaration order.
fn branches(s: *Sema, unit: *Unit) Allocator.Error!void {
    const vir = unit.vir;
    for (vir.body(unit.module.body)) |i| {
        if (vir.instructions.items(.tag)[@backingInt(i)] != .branch) continue;
        const br = payloadOf(vir, Inst.Branch, i);
        const hi = nodeOfBody(unit, br.hi) orelse continue;
        const lo = if (br.lo.len == 0) Node.Index.ground else nodeOfBody(unit, br.lo) orelse continue;
        try s.device.branches.append(s.gpa, .{
            .name = try s.zcu.intern_pool.getString(s.gpa, try std.fmt.allocPrint(s.arena, "{s}{s}", .{ unit.prefix, vir.string(br.name) })),
            .hi = hi,
            .lo = lo,
        });
        try unit.binds.put(s.arena, canonical(vir, i), .{ .branch = @fromBackingInt(@intCast(s.device.branches.len)) });
    }
}

/// The node a terminal body names (a scalar net), or null.
fn nodeOfBody(unit: *const Unit, b: Vir.Body) ?Node.Index {
    const vir = unit.vir;
    const insts = vir.body(b);
    if (insts.len == 0) return null;
    const last = insts[insts.len - 1];
    if (vir.instructions.items(.tag)[@backingInt(last)] != .decl_ref) return null;
    const bind = unit.binds.get(canonical(vir, vir.instructions.items(.data)[@backingInt(last)].decl_tok.decl)) orelse return null;
    return if (bind == .node) bind.node else null;
}

/// §3.2 the instance's module-level variables: one slot each.
fn variables(s: *Sema, unit: *Unit) Allocator.Error!void {
    const vir = unit.vir;
    for (vir.body(unit.module.body)) |i| {
        if (vir.instructions.items(.tag)[@backingInt(i)] != .variable) continue;
        const v = payloadOf(vir, Inst.Variable, i);
        if (v.dims.len != 0) continue;
        const first = canonical(vir, i);
        if (unit.binds.contains(first)) continue;
        const ty = tyOf(v.flags.storage);
        try unit.binds.put(s.arena, first, .{ .slot = .{ .alloc = try addAlloc(s, ty), .ty = ty } });
    }
}
