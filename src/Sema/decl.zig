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
//! - `pub fn envOf(s: *Sema, unit: *Unit) Allocator.Error!eval.Env`
//! - `pub fn eachItem(s: *Sema, unit: *Unit, env: *eval.Env, body: Vir.Body, visitor: anytype, depth: u32) Allocator.Error!void`

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
const discrete = @import("discrete.zig");
const variable = @import("variable.zig");
const net = @import("net.zig");
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

/// The analog blocks of a body, in source order, generate schemes unrolled
/// with their genvars bound (§6.6): each block lowered into `main`.
const Lowering = struct {
    main: *Block,

    fn item(l: Lowering, s: *Sema, unit: *Unit, i: Inst.Index) Allocator.Error!void {
        const vir = unit.vir;
        const main = l.main;
        switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            .analog => {
                var b = main.child();
                try control.body(s, &b, payloadOf(vir, Inst.Process, i).body);
                try main.insts.appendSlice(s.arena, b.insts.items);
            },
            // §5.2.1 an `analog initial` body runs on the analysis's first
            // evaluation only: guarded by `analog$initial`, which the host answers.
            .analog_initial => {
                var b = main.child();
                const flag = try @import("expr.zig").call(s, &b, @backingInt(@import("vams").SysFn.Tag.@"analog$initial"), .integer, &.{});
                var then_b = b.child();
                then_b.analog_initial = true;
                then_b.conditional += 1;
                try control.body(s, &then_b, payloadOf(vir, Inst.Process, i).body);
                var else_b = b.child();
                try control.ifElse(s, &b, flag, &then_b, &else_b);
                try main.insts.appendSlice(s.arena, b.insts.items);
            },
            else => {}, // else: not an analog block
        }
    }
};

/// Lowers the design under `zcu.instances[0]` and returns the main body,
/// its `ret` included. Asserts that nothing was lowered before.
pub fn run(s: *Sema) Allocator.Error![]const Air.Inst.Index {
    const zcu = s.zcu;
    assert(s.units.items.len == 0);
    assert(s.device.nodes.len == 0);
    try @import("nature.zig").check(s);
    try units(s);
    if (s.units.items.len == 0) return finish(s, &.{});
    try contrib.loadDisciplines(s);
    for (s.units.items) |*u| try discrete.mark(s, u);
    for (s.units.items) |*u| try @import("discrete_check.zig").check(s, u);
    try net.ports(s, &s.units.items[0]);
    s.device.num_ports = @intCast(s.device.nodes.len);
    for (s.units.items) |*u| try net.nets(s, u);
    for (s.units.items[1..]) |*u| try net.bindChildPorts(s, u);
    try net.signalFlowPorts(s);
    try net.bindBridges(s);
    for (s.units.items) |*u| try param.declare(s, u);
    for (s.units.items) |*u| try discrete.declare(s, u);
    for (s.units.items[1..]) |*u| try @import("derive.zig").child(s, u);
    for (s.units.items) |*u| try branches(s, u);
    for (s.units.items) |*u| try held.mark(s, u);
    for (s.units.items) |*u| try @import("attr.zig").check(s, u);
    for (s.units.items) |*u| try variable.declare(s, u);
    for (s.units.items) |*u| try @import("func.zig").checkRecursion(s, u);
    try net.pullDrives(s);
    var main: Block = .{ .parent = null, .unit = &s.units.items[0] };
    // The old flattener's order (`elab/instance.zig` inlineInstance,
    // `Flatten.run`): each placed instance's blocks as the walk reaches it,
    // in preorder; the top's after every child's (§5.4.2.2: a parent reads
    // a child's flow after its contribution); then any unit no statement
    // places (an inserted connect module), in preorder.
    for (s.units.items[1..]) |*u| if (zcu.instances.items(.src)[@backingInt(u.instance)] != .none) try lowerUnit(s, &main, u, 0);
    try lowerUnit(s, &main, &s.units.items[0], 0);
    for (s.units.items) |*u| if (!u.lowered) try lowerUnit(s, &main, u, 0);
    try syscall.finishDisplays(s, &main);
    try @import("probe.zig").checkProbes(s);
    // §5.4.2 a potential or indirect row's branch current, wherever
    // lowering minted it; a flow row's is its own value.
    const c = s.device.contributions.slice();
    for (c.items(.hi), c.items(.lo), c.items(.access), c.items(.kind), c.items(.flow)) |hi, lo, access, kind, *flow| {
        flow.* = if (access == .potential or kind == .indirect) s.flow_rows.get(.{ hi, lo }) orelse .none else .none;
    }
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
    env.shaping += 1;
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
    if (s.zcu.instances.items(.parent)[@backingInt(unit.instance)] == .none) try @import("walk.zig").rootShapes(s, &env);
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

/// An evaluator over `unit`'s module with the instance's folded parameters.
pub fn envOf(s: *Sema, unit: *Unit) Allocator.Error!eval.Env {
    const zcu = s.zcu;
    var env: eval.Env = try .init(s.gpa, s.arena, &zcu.intern_pool, unit.vir, &.{ unit.module.params, unit.module.body });
    errdefer env.deinit();
    const elems = zcu.intern_pool.indexToKey(zcu.instances.items(.params)[@backingInt(unit.instance)]).aggregate.elems;
    assert(elems.len == env.values.items.len);
    @memcpy(env.values.items, elems);
    env.hier = zcu.instances.items(.hier)[@backingInt(unit.instance)];
    return env;
}

/// Calls `visitor.item(s, unit, i)` on each item of `body` in source order, with
/// generate schemes (§6.6) evaluated under `env` and unrolled, their
/// genvars bound in `env` and `unit.binds` while their bodies are visited.
pub fn eachItem(s: *Sema, unit: *Unit, env: *eval.Env, body: Vir.Body, visitor: anytype, depth: u32) Allocator.Error!void {
    const vir = unit.vir;
    if (depth > gen_depth_max) return;
    for (vir.body(body)) |i| switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .gen_block => try eachItem(s, unit, env, payloadOf(vir, Inst.GenBlock, i).body, visitor, depth + 1),
        .gen_if => {
            const g = payloadOf(vir, Inst.GenIf, i);
            const c = (try env.body(g.cond)) orelse continue;
            try eachItem(s, unit, env, if (c.isTrue()) g.then else g.@"else", visitor, depth + 1);
        },
        .gen_case => {
            const g = payloadOf(vir, Inst.GenCase, i);
            const operand = (try env.body(g.operand)) orelse continue;
            var arm_body: ?Vir.Body = null;
            for (vir.list(Inst.Arm, g.arms)) |arm| {
                if (arm.flags.default and arm_body == null) arm_body = arm.body;
                for (vir.list(Inst.Ref, arm.values)) |l| {
                    const label = (try env.ref(l)) orelse continue;
                    const eq = @import("std_kernels").fold.binary(.eq, operand, label, null) orelse continue;
                    if (eq.isTrue()) {
                        arm_body = arm.body;
                        break;
                    }
                } else continue;
                break;
            }
            if (arm_body) |ab| try eachItem(s, unit, env, ab, visitor, depth + 1);
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
                try eachItem(s, unit, env, g.body, visitor, depth + 1);
                v = ((try env.ref(step.rhs)) orelse break).asIntExact() orelse break;
            }
        },
        else => try visitor.item(s, unit, i),
    };
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

/// Lowers `u`'s own analog blocks into `main` (its children's are lowered
/// in `run`'s order).
fn lowerUnit(s: *Sema, main: *Block, u: *Unit, depth: u32) Allocator.Error!void {
    assert(!u.lowered);
    u.lowered = true;
    const saved = main.unit;
    defer main.unit = saved;
    main.unit = u;
    var env = try envOf(s, u);
    defer env.deinit();
    try eachItem(s, u, &env, u.module.body, Lowering{ .main = main }, depth);
    try @import("simprobe.zig").statements(s, main, u);
}

/// A body's last instruction as a `store`, or null.
fn lastStore(vir: *const Vir, b: Vir.Body) ?Inst.Bin {
    const insts = vir.body(b);
    if (insts.len == 0) return null;
    const last = insts[insts.len - 1];
    if (vir.instructions.items(.tag)[@backingInt(last)] != .store) return null;
    return payloadOf(vir, Inst.Bin, last);
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
