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
//! - `pub fn typeIndex(ty: Sema.Ty) InternPool.Index`
//! - `pub fn foldBody(s: *Sema, unit: *Sema.Unit, b: Vir.Body) Allocator.Error!?eval.Const`
//! - `pub fn foldRef(s: *Sema, unit: *Sema.Unit, r: Inst.Ref) Allocator.Error!?eval.Const`
//! - `pub fn intern(s: *Sema, c: eval.Const) Allocator.Error!InternPool.Index`
//! - `pub fn declareArray(s: *Sema, unit: *Sema.Unit, first: Inst.Index, dims_body: Vir.Body, ty: Sema.Ty) Allocator.Error!void`
//! - `pub fn portDecl(vir: *const Vir, p: Inst.Index) ?Inst.Index`
//! - `pub fn rowInstance(i: Zcu.Instance.Index) Device.Instance`
//! - `pub fn nameOf(vir: *const Vir, i: Inst.Index) Vir.String`

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
const held = @import("held.zig");
const param = @import("param.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Device = Air.Device;
const Node = Device.Node;
const Unit = Sema.Unit;
const Block = Sema.Block;

/// The most passes one loop generate scheme unrolls (the walk's bound).
const gen_loop_max: u32 = 1 << 16;
/// The deepest generate nesting followed.
const gen_depth_max: u32 = 1 << 10;

/// The most elements one array is lowered to (a slot each).
const array_cells_max: u64 = 1 << 16;

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
    for (s.units.items) |*u| try param.declare(s, u);
    for (s.units.items) |*u| try branches(s, u);
    for (s.units.items) |*u| try held.mark(s, u);
    for (s.units.items) |*u| try variables(s, u);
    var main: Block = .{ .parent = null, .unit = &s.units.items[0] };
    for (s.units.items) |*u| {
        main.unit = u;
        var env = try envOf(s, u);
        defer env.deinit();
        try items(s, &main, &env, u.module.body, 0);
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

/// The constant value of `r` in `unit`'s instance (genvars bound as the
/// lowering has them), or null.
pub fn foldRef(s: *Sema, unit: *Unit, r: Inst.Ref) Allocator.Error!?eval.Const {
    var env = try envOf(s, unit);
    defer env.deinit();
    var it = unit.binds.iterator();
    while (it.next()) |e| if (e.value_ptr.* == .constant and unit.vir.instructions.items(.tag)[@backingInt(e.key_ptr.*)] == .genvar) {
        const c = s.zcu.intern_pool.indexToKey(e.value_ptr.constant);
        if (c == .int and c.int.storage == .small) try env.genvars.put(s.gpa, e.key_ptr.*, c.int.storage.small);
    };
    return env.ref(r);
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

/// The declaration a header port names: an ANSI `io` itself, or the net a
/// non-ANSI port expression names. Null for a null or concatenated port.
pub fn portDecl(vir: *const Vir, p: Inst.Index) ?Inst.Index {
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

/// §3.2.2 an array variable (or §3.4.4 parameter) of type `ty` whose
/// dimensions are `dims_body`: a slot per element.
pub fn declareArray(s: *Sema, unit: *Unit, first: Inst.Index, dims_body: Vir.Body, ty: Sema.Ty) Allocator.Error!void {
    const vir = unit.vir;
    var env = try envOf(s, unit);
    defer env.deinit();
    var dims: std.ArrayList([2]i64) = .empty;
    var cells: u64 = 1;
    for (vir.body(dims_body)) |d| {
        if (vir.instructions.items(.tag)[@backingInt(d)] != .range) continue;
        const bin = payloadOf(vir, Inst.Bin, d);
        const msb = ((try env.ref(bin.lhs)) orelse return s.fail(.E0352, unit.file, first.toRef(), "an array bound is not constant", .{})).asIntExact() orelse return;
        const lsb = ((try env.ref(bin.rhs)) orelse return s.fail(.E0352, unit.file, first.toRef(), "an array bound is not constant", .{})).asIntExact() orelse return;
        try dims.append(s.arena, .{ msb, lsb });
        cells = std.math.mul(u64, cells, @abs(msb - lsb) + 1) catch return s.fail(.E1015, unit.file, first.toRef(), "the array is too large", .{});
    }
    if (cells > array_cells_max) return s.fail(.E1015, unit.file, first.toRef(), "the array has {d} elements, past {d}", .{ cells, array_cells_max });
    const slots = try s.arena.alloc(Air.Inst.Index, @intCast(cells));
    for (slots) |*slot| slot.* = try addAlloc(s, ty);
    try unit.binds.put(s.arena, first, .{ .array = .{ .slots = slots, .dims = dims.items, .ty = ty } });
}

/// A `Zcu` instance as a device row's `instance` column.
pub fn rowInstance(i: Zcu.Instance.Index) Device.Instance {
    return @fromBackingInt(@backingInt(i));
}

/// The `InternPool` type of a value type.
pub fn typeIndex(ty: Sema.Ty) InternPool.Index {
    return switch (ty) {
        .real => .real_type,
        .integer => .integer_type,
        .string => .string_type,
    };
}

/// The name a declaring instruction declares (its payload's first word).
pub fn nameOf(vir: *const Vir, i: Inst.Index) Vir.String {
    const at = vir.instructions.items(.data)[@backingInt(i)].pl_node.payload_index;
    return @fromBackingInt(vir.extra[at]);
}

// ---- private ----

/// The main body: the prologue's slots, the entry assignments, `body`, and the `ret`.
fn finish(s: *Sema, body: []const Air.Inst.Index) Allocator.Error![]const Air.Inst.Index {
    const ret = try s.air.addUnOp(s.gpa, .ret, .fromIntern(.zero_real));
    const head = s.prologue.items.len + s.entry.items.len;
    const main = try s.arena.alloc(Air.Inst.Index, head + body.len + 1);
    @memcpy(main[0..s.prologue.items.len], s.prologue.items);
    @memcpy(main[s.prologue.items.len..head], s.entry.items);
    @memcpy(main[head..][0..body.len], body);
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

/// The analog blocks of a body, in source order, generate schemes unrolled
/// with their genvars bound (§6.6): each block lowered into `main`.
fn items(s: *Sema, main: *Block, env: *eval.Env, body: Vir.Body, depth: u32) Allocator.Error!void {
    const unit = main.unit;
    const vir = unit.vir;
    if (depth > gen_depth_max) return;
    for (vir.body(body)) |i| switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .analog, .analog_initial => |tag| {
            var b = main.child();
            b.analog_initial = tag == .analog_initial;
            try control.body(s, &b, payloadOf(vir, Inst.Process, i).body);
            try main.insts.appendSlice(s.arena, b.insts.items);
        },
        .gen_block => try items(s, main, env, payloadOf(vir, Inst.GenBlock, i).body, depth + 1),
        .gen_if => {
            const g = payloadOf(vir, Inst.GenIf, i);
            const c = (try env.body(g.cond)) orelse continue;
            try items(s, main, env, if (c.isTrue()) g.then else g.@"else", depth + 1);
        },
        .gen_case => {
            const g = payloadOf(vir, Inst.GenCase, i);
            const operand = (try env.body(g.operand)) orelse continue;
            var arm_body: ?Vir.Body = null;
            for (vir.list(Inst.Arm, g.arms)) |arm| {
                if (arm.flags.default and arm_body == null) arm_body = arm.body;
                for (vir.list(Inst.Ref, arm.values)) |l| {
                    const label = (try env.ref(l)) orelse continue;
                    const eq = @import("kernels").fold.binary(.eq, operand, label, null) orelse continue;
                    if (eq.isTrue()) {
                        arm_body = arm.body;
                        break;
                    }
                } else continue;
                break;
            }
            if (arm_body) |ab| try items(s, main, env, ab, depth + 1);
        },
        .gen_for => {
            const g = payloadOf(vir, Inst.GenFor, i);
            const init = lastStore(vir, g.init) orelse continue;
            const step = lastStore(vir, g.step) orelse continue;
            const gvi = init.lhs.toIndex() orelse continue;
            if (vir.instructions.items(.tag)[@backingInt(gvi)] != .decl_ref) continue;
            const gv = canonical(vir, vir.instructions.items(.data)[@backingInt(gvi)].decl_tok.decl);
            var v = ((try env.ref(init.rhs)) orelse continue).asIntExact() orelse continue;
            defer _ = env.genvars.remove(gv);
            defer _ = unit.binds.remove(gv);
            for (0..gen_loop_max) |_| {
                try env.genvars.put(s.gpa, gv, v);
                try unit.binds.put(s.arena, gv, .{ .constant = try intern(s, .{ .int = v }) });
                const c = (try env.body(g.cond)) orelse break;
                if (!c.isTrue()) break;
                try items(s, main, env, g.body, depth + 1);
                v = ((try env.ref(step.rhs)) orelse break).asIntExact() orelse break;
            }
        },
        else => {}, // else: not an analog block or a generate scheme
    };
}

/// A body's last instruction as a `store`, or null.
fn lastStore(vir: *const Vir, b: Vir.Body) ?Inst.Bin {
    const insts = vir.body(b);
    if (insts.len == 0) return null;
    const last = insts[insts.len - 1];
    if (vir.instructions.items(.tag)[@backingInt(last)] != .store) return null;
    return payloadOf(vir, Inst.Bin, last);
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
fn internNode(s: *Sema, unit: *const Unit, name: []const u8, discipline: Vir.String) Allocator.Error!Node.Index {
    const vir = unit.vir;
    const ip = &s.zcu.intern_pool;
    const key = try ip.getString(s.gpa, name);
    const gop = try s.node_rows.getOrPut(s.arena, key);
    if (gop.found_existing) return gop.value_ptr.*;
    const row: Node.Index = @fromBackingInt(@intCast(s.device.nodes.len));
    try s.device.nodes.append(s.gpa, .{ .name = key, .kind = .net, .of = .none, .discipline = try ip.getString(s.gpa, vir.string(discipline)), .instance = rowInstance(unit.instance) });
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
    _ = tags;
    for (vir.body(unit.module.ports)) |p| {
        const first = portDecl(vir, p) orelse continue;
        try declareNet(s, unit, first);
    }
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
        try declareNet(s, unit, first);
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

/// One net or port: a row, or a §3.6.3 vector's rows msb first (`name[k]`).
/// §3.6.4 a `ground` net keeps its row, and its name reads the reference node.
fn declareNet(s: *Sema, unit: *Unit, first: Inst.Index) Allocator.Error!void {
    const vir = unit.vir;
    const name = vir.string(nameOf(vir, first));
    const disc = disciplineOf(unit, first);
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
        var env = try envOf(s, unit);
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
            break :blk try internNode(s, unit, try std.fmt.allocPrint(s.arena, "{s}{s}", .{ unit.prefix, name }), disciplineOf(unit, first));
        };
        try unit.binds.put(s.arena, first, .{ .node = node });
    }
}

/// §3.12 the instance's named branches, in declaration order.
fn branches(s: *Sema, unit: *Unit) Allocator.Error!void {
    const vir = unit.vir;
    for (vir.body(unit.module.body)) |i| {
        if (vir.instructions.items(.tag)[@backingInt(i)] != .branch) continue;
        const br = payloadOf(vir, Inst.Branch, i);
        if (portOfBody(unit, br.hi)) |p| {
            try unit.binds.put(s.arena, canonical(vir, i), .{ .port = p });
            continue;
        }
        const hi = nodeOfBody(unit, br.hi) orelse continue;
        const lo = if (br.lo.len == 0) Node.Index.ground else nodeOfBody(unit, br.lo) orelse continue;
        try s.device.branches.append(s.gpa, .{
            .name = try s.zcu.intern_pool.getString(s.gpa, try std.fmt.allocPrint(s.arena, "{s}{s}", .{ unit.prefix, vir.string(br.name) })),
            .hi = hi,
            .lo = lo,
            .instance = rowInstance(unit.instance),
        });
        try unit.binds.put(s.arena, canonical(vir, i), .{ .branch = @fromBackingInt(@intCast(s.device.branches.len)) });
    }
}

/// The port node a §3.12.1 terminal body names (`<p>`), or null.
fn portOfBody(unit: *const Unit, b: Vir.Body) ?Node.Index {
    const vir = unit.vir;
    const insts = vir.body(b);
    if (insts.len == 0) return null;
    const last = insts[insts.len - 1];
    if (vir.instructions.items(.tag)[@backingInt(last)] != .port_branch) return null;
    const o = vir.instructions.items(.data)[@backingInt(last)].un_node.operand.toIndex() orelse return null;
    if (vir.instructions.items(.tag)[@backingInt(o)] != .decl_ref) return null;
    const bind = unit.binds.get(canonical(vir, vir.instructions.items(.data)[@backingInt(o)].decl_tok.decl)) orelse return null;
    return if (bind == .node) bind.node else null;
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

/// §3.2 the instance's module-level variables: one slot each. §5.10.4 a
/// named event is an integer flag (one per element of an event array), 0 at
/// entry to every evaluation.
fn variables(s: *Sema, unit: *Unit) Allocator.Error!void {
    const vir = unit.vir;
    for (vir.body(unit.module.body)) |i| {
        if (vir.instructions.items(.tag)[@backingInt(i)] == .event) {
            const first = canonical(vir, i);
            if (unit.binds.contains(first)) continue;
            const dims = payloadOf(vir, Inst.Name, i).dims;
            if (dims.len != 0) try declareArray(s, unit, first, dims, .integer) else try unit.binds.put(s.arena, first, .{ .slot = .{ .alloc = try addAlloc(s, .integer), .ty = .integer } });
            const bind = unit.binds.get(first) orelse continue;
            const slots: []const Air.Inst.Index = if (bind == .array) bind.array.slots else &.{bind.slot.alloc};
            for (slots) |slot| try s.entry.append(s.arena, try s.air.addInst(s.gpa, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slot), .rhs = .fromIntern(.zero) } } }));
            continue;
        }
        if (vir.instructions.items(.tag)[@backingInt(i)] != .variable) continue;
        const v = payloadOf(vir, Inst.Variable, i);
        const first = canonical(vir, i);
        if (unit.binds.contains(first)) continue;
        if (v.dims.len != 0) {
            try declareArray(s, unit, first, v.dims, tyOf(v.flags.storage));
            continue;
        }
        const ty = tyOf(v.flags.storage);
        const slot = try addAlloc(s, ty);
        try unit.binds.put(s.arena, first, .{ .slot = .{ .alloc = slot, .ty = ty } });
        if (unit.held.contains(first)) try s.device.held.append(s.gpa, .{
            .name = try s.zcu.intern_pool.getString(s.gpa, try std.fmt.allocPrint(s.arena, "{s}{s}", .{ unit.prefix, vir.string(v.name) })),
            .slot = slot,
        });
    }
}
