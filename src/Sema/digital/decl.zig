//! The instance walk of the digital lowering: `Zcu.instances` (preorder,
//! each module's Vir re-read under its folded parameters) in; per instance
//! a frame binding its declarations to slots and a `Program.scopes` row,
//! per generate block (each iteration of a loop scheme) a frame and a
//! scope of its own, and per scope the processes it holds, out. Slots
//! start at their §4.2.1 / §6.2.1 time-0 values: a variable x (a real
//! 0.0), a parameter its folded value, a named event x.
//! Cites: IEEE 1364-2005 §3.2, §3.9, §4.2.1, §4.5, §4.8, §4.10, §5.10.4,
//! §6.2.1, §12.1.2, §12.2, §12.4, §12.5.
//!
//! Contents:
//! - `pub fn declare(l: *Lower) Error!void`
//! - `pub fn newScope(l: *Lower, parent: u32, name: []const u8, index: ?i64, time: Program.Time, at: u32, queued: bool) Error!u32`
//! - `pub fn newFrame(l: *Lower, parent: u32, instance: Zcu.Instance.Index, scope: u32, genvars: []const Frame.Genvar) Error!u32`
//! - `pub fn locals(l: *Lower, f: u32, body: Vir.Body) Error!void`
//! - `pub fn variable(l: *Lower, f: u32, first: Inst.Index, decls: []const Inst.Index) Error!u32`
//! - `pub fn param(l: *Lower, f: u32, i: Inst.Index) Error!u32`
//! - `pub fn event(l: *Lower, f: u32, i: Inst.Index) Error!u32`
//! - `pub fn rangeOf(l: *Lower, f: u32, range: Vir.Body) Error!struct { msb: i64, lsb: i64, width: u32 }`
//! - `pub fn slots(l: *Lower, ty: Type, count: u32, fill: enum { x, zero }) Error!u32`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const std_sim = @import("std_sim");
const InternPool = @import("intern_pool");
const kernels = @import("kernels");
const Zcu = @import("../../Zcu.zig");
const eval = @import("../eval.zig");
const digital = @import("../digital.zig");
const nets = @import("nets.zig");
const ports = @import("ports.zig");
const sub = @import("sub.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const Name = digital.Name;
const Type = digital.Type;
const Span = digital.Span;
const Frame = digital.Frame;
const Proc = digital.Proc;
const none = digital.none;
const Program = std_sim.Program;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// The most iterations one loop generate scheme unrolls (`walk.zig`'s).
const loop_max: u32 = 1 << 16;

/// The most slots one array declares.
const array_max: u32 = 1 << 24;

const Placement = struct { scope: u32 = none, frame: u32 = none, index: ?i64 = null, at: u32 = 0, name: []const u8 = "" };
const Child = struct { parent: u32, name: InternPool.String };

const Walk = struct {
    l: *Lower,
    placed: []Placement,
    children: *const std.AutoHashMapUnmanaged(Child, u32),
    /// The instance being walked.
    index: u32 = 0,
    /// Its ports' connections, by each port's first declaration.
    conns: std.AutoHashMapUnmanaged(Inst.Index, ports.Conn) = .empty,
    /// Its ports' drivers, appended after its net declarations' own.
    deferred: std.ArrayList(nets.Wire) = .empty,
};

/// Walks every instance in `Zcu.instances` order: its scope, its frame, its
/// declarations' slots and its processes, then its generate blocks'.
/// Asserts the walk starts empty.
pub fn declare(l: *Lower) Error!void {
    assert(l.scopes.items.len == 0);
    const zcu = l.zcu;
    const n = zcu.instances.len;
    l.instance_frame = try l.a.alloc(u32, n);
    l.envs = try l.a.alloc(eval.Env, n);
    // Where each child instance is declared: its parent scope, set as the
    // parent's walk reaches its `instance` instruction.
    const placed = try l.a.alloc(Placement, n);
    @memset(placed, .{});
    var children: std.AutoHashMapUnmanaged(Child, u32) = .empty;
    for (0..n) |k| {
        const p = zcu.instances.items(.parent)[k];
        if (p == .none) continue;
        try children.put(l.a, .{ .parent = @backingInt(p), .name = zcu.instances.items(.name)[k] }, @intCast(k));
    }
    var w: Walk = .{ .l = l, .placed = placed, .children = &children };
    for (0..n) |k| try instance(&w, @intCast(k));
    assert(l.roots.items.len >= 1);
}

/// Appends a `Program.scopes` row (and its lowering facts) and returns it.
pub fn newScope(l: *Lower, parent: u32, name: []const u8, index: ?i64, time: Program.Time, at: u32, queued: bool) Error!u32 {
    const s: u32 = @intCast(l.b.scopes.items.len);
    assert(parent == none or parent < s);
    const idx: ?i32 = if (index) |i| std.math.cast(i32, i) orelse return l.refuse("a generate or array index past i32") else null;
    try l.b.scopes.append(l.a, .{ .parent = if (parent == none) s else parent, .name = try l.b.string(name), .index = idx, .time = s });
    try l.b.times.append(l.a, time);
    try l.scopes.append(l.a, .{ .at = at, .queued = queued });
    assert(l.scopes.items.len == l.b.scopes.items.len);
    return s;
}

/// Appends a binding frame above `parent` (`none` for an instance's).
pub fn newFrame(l: *Lower, parent: u32, instance_index: Zcu.Instance.Index, scope: u32, genvars: []const Frame.Genvar) Error!u32 {
    assert(scope < l.b.scopes.items.len);
    const f: u32 = @intCast(l.frames.items.len);
    try l.frames.append(l.a, .{ .parent = parent, .instance = instance_index, .scope = scope, .genvars = genvars });
    return f;
}

/// Binds the block- or subroutine-local declarations of `body` (variables,
/// parameters, events) in frame `f`, each a slot of its own.
pub fn locals(l: *Lower, f: u32, body: Vir.Body) Error!void {
    const vir = l.virOf(f);
    for (vir.body(body)) |i| switch (Lower.tag(vir, i)) {
        .variable => {
            const v = Lower.payload(vir, Inst.Variable, i);
            if (v.init.len != 0) return l.refuse("an initialized block-local variable");
            _ = try variable(l, f, i, &.{i});
        },
        .param => _ = try param(l, f, i),
        .event => _ = try event(l, f, i),
        else => {}, // else: a statement or an expression declares nothing
    };
}

/// A §4.2 variable (a `reg`, `integer`, `time`, `real` or `realtime`, an
/// array of them included) bound to fresh slots, x (a real 0.0) at time 0.
pub fn variable(l: *Lower, f: u32, first: Inst.Index, decls: []const Inst.Index) Error!u32 {
    const vir = l.virOf(f);
    var storage: Inst.Storage = .reg;
    var signed = false;
    var range: Vir.Body = .empty;
    var dims: Vir.Body = .empty;
    for (decls) |d| switch (Lower.tag(vir, d)) {
        .io => {
            const io = Lower.payload(vir, Inst.Io, d);
            if (io.flags.storage != .none) storage = io.flags.storage;
            signed = signed or io.flags.signed;
            if (range.len == 0) range = io.range;
            if (dims.len == 0) dims = io.dims;
        },
        .variable => {
            const v = Lower.payload(vir, Inst.Variable, d);
            if (v.flags.storage != .none) storage = v.flags.storage;
            signed = signed or v.flags.signed;
            if (range.len == 0) range = v.range;
            if (dims.len == 0) dims = v.dims;
        },
        else => unreachable, // else: `signal` passes only these two
    };
    var n: Name = .{ .kind = .variable };
    switch (storage) {
        .real, .realtime => n.ty = Type.real_type,
        .integer => n.ty = .{ .width = 32, .signed = true },
        .time => n.ty = .{ .width = 64, .signed = false },
        .string => return l.refuse("a string variable"),
        .reg, .none => n.ty = .{ .width = 1, .signed = signed },
    }
    if (range.len != 0) {
        if (n.ty.real) return l.refuse("a real with a range");
        const r = try rangeOf(l, f, range);
        n.msb = r.msb;
        n.lsb = r.lsb;
        n.ty.width = r.width;
    } else {
        n.msb = @as(i64, n.ty.width) - 1;
        n.scalar = storage == .reg or storage == .none;
    }
    if (storage == .integer or storage == .time) n.scalar = false;
    try arrayOf(l, f, dims, &n);
    n.slot = try slots(l, n.ty, n.count, if (n.ty.real) .zero else .x);
    return l.bind(f, first, n);
}

/// A §4.10 parameter (or specparam, or localparam) of frame `f`: one slot
/// holding its folded value, in its §12.2 type.
pub fn param(l: *Lower, f: u32, i: Inst.Index) Error!u32 {
    const vir = l.virOf(f);
    const p = Lower.payload(vir, Inst.Param, i);
    if (p.dims.len != 0) return l.refuse("a parameter array");
    const env = try l.envAt(f);
    const value = (try env.param(i)) orelse return l.refuse("a parameter value Sema/eval.zig does not fold (an x/z bit or past 64 bits)");
    var n: Name = .{ .kind = .param };
    if (p.range.len != 0) {
        const r = try rangeOf(l, f, p.range);
        n.ty = .{ .width = r.width, .signed = p.flags.signed };
        n.msb = r.msb;
        n.lsb = r.lsb;
    } else switch (p.flags.storage) {
        .integer => n.ty = .{ .width = 32, .signed = true },
        .time => n.ty = .{ .width = 64, .signed = false },
        .real, .realtime => n.ty = Type.real_type,
        .string => return l.refuse("a string parameter"),
        .none, .reg => n.ty = switch (value) {
            .real => Type.real_type,
            .int => |v| .{ .width = if (std.math.cast(i32, v) != null) 32 else 64, .signed = true },
            .str => |s| .{ .width = @intCast(@max(1, s.len) * 8), .signed = false },
        },
    }
    if (p.flags.signed and !n.ty.real) n.ty.signed = true;
    if (p.range.len == 0) n.msb = @as(i64, n.ty.width) - 1;
    if (p.range.len == 0 and p.flags.storage == .none and value == .int) return l.refuse("an untyped integral parameter (its §12.2 type is its value expression's)");
    const words = Program.words(n.ty.width);
    const v = try l.a.alloc(u64, words);
    const x = try l.a.alloc(u64, words);
    @memset(v, 0);
    @memset(x, 0);
    switch (value) {
        .int => |iv| {
            if (n.ty.real) {
                v[0] = @bitCast(@as(f64, @floatFromInt(iv)));
            } else {
                const bits: u64 = @bitCast(iv);
                v[0] = bits;
                if (n.ty.width < 64) v[0] &= (@as(u64, 1) << @intCast(n.ty.width)) - 1;
                if (words > 1 and iv < 0 and n.ty.signed) for (v[1..]) |*word| {
                    word.* = std.math.maxInt(u64);
                };
                if (words > 1 and n.ty.width % 64 != 0) v[words - 1] &= (@as(u64, 1) << @intCast(n.ty.width % 64)) - 1;
            }
        },
        .real => |rv| {
            if (!n.ty.real) return l.refuse("a real value of an integral parameter");
            v[0] = @bitCast(rv);
        },
        .str => |s| {
            if (n.ty.real) return l.refuse("a string value of a real parameter");
            // §3.6: packed ASCII, the last character in the low byte.
            for (0..@min(s.len, words * 8)) |k| {
                const byte = s[s.len - 1 - k];
                v[k / 8] |= @as(u64, byte) << @intCast((k % 8) * 8);
            }
        },
    }
    n.slot = try l.b.slot(try l.tyOf(n.ty), v, x);
    return l.bind(f, i, n);
}

/// §5.10.4 a named event (an array of them included): one 1-bit slot per
/// element, x.
pub fn event(l: *Lower, f: u32, i: Inst.Index) Error!u32 {
    const vir = l.virOf(f);
    const e = Lower.payload(vir, Inst.Name, i);
    var n: Name = .{ .kind = .event };
    try arrayOf(l, f, e.dims, &n);
    n.slot = try slots(l, n.ty, n.count, .x);
    return l.bind(f, i, n);
}

/// The declared `[msb:lsb]` of a range body, folded.
pub fn rangeOf(l: *Lower, f: u32, range: Vir.Body) Error!struct { msb: i64, lsb: i64, width: u32 } {
    const vir = l.virOf(f);
    const r = vir.body(range);
    const bin = Lower.payload(vir, Inst.Bin, r[r.len - 1]);
    const msb = try l.intOf(f, bin.lhs);
    const lsb = try l.intOf(f, bin.rhs);
    const width = std.math.cast(u32, @abs(@as(i128, msb) - lsb) + 1) orelse return l.refuse("a range past 2^32 bits");
    return .{ .msb = msb, .lsb = lsb, .width = width };
}

/// `count` fresh slots of type `ty`, every bit `fill` (x, or 0).
pub fn slots(l: *Lower, ty: Type, count: u32, fill: enum { x, zero }) Error!u32 {
    const t = try l.tyOf(ty);
    const words = Program.words(t.width);
    const v = try l.a.alloc(u64, words);
    const x = try l.a.alloc(u64, words);
    @memset(v, 0);
    @memset(x, 0);
    if (fill == .x) {
        @memset(v, std.math.maxInt(u64));
        @memset(x, std.math.maxInt(u64));
        if (t.width % 64 != 0) {
            const mask = (@as(u64, 1) << @intCast(t.width % 64)) - 1;
            v[words - 1] &= mask;
            x[words - 1] &= mask;
        }
    }
    const first: u32 = @intCast(l.b.p.slots.len);
    for (0..count) |_| _ = try l.b.slot(t, v, x);
    return first;
}

// ---- private ----

/// One instance: its env (its module's parameters as `Zcu` folded them),
/// its scope and frame, then its module's items.
fn instance(w: *Walk, k: u32) Error!void {
    const l = w.l;
    const zcu = l.zcu;
    const d = zcu.instances.items(.module)[k];
    const vir = zcu.fileVir(d.file);
    const row = zcu.declRow(d);
    if (row.kind == .primitive) return l.refuse("a UDP instance");
    const m = Lower.payload(vir, Inst.Module, row.inst);
    l.envs[k] = try eval.Env.init(l.a, l.a, &zcu.intern_pool, vir, &.{ m.params, m.body });
    const env = &l.envs[k];
    const elems = zcu.intern_pool.indexToKey(zcu.instances.items(.params)[k]).aggregate.elems;
    assert(elems.len == env.values.items.len);
    @memcpy(env.values.items, elems);
    env.hier = zcu.instances.items(.hier)[k];
    const time = l.module_times.get(d).?;
    const parent = zcu.instances.items(.parent)[k];
    const scope = if (parent == .none) root: {
        const s = try newScope(l, none, vir.string(row.name), null, time, 0, true);
        try l.roots.append(l.a, s);
        break :root s;
    } else child: {
        const p = w.placed[k];
        if (p.scope == none) return l.refuse("an instance its parent's walk did not reach");
        break :child try newScope(l, p.scope, p.name, p.index, time, p.at, true);
    };
    const f = try newFrame(l, none, @fromBackingInt(k), scope, &.{});
    l.instance_frame[k] = f;
    w.index = k;
    w.conns.clearRetainingCapacity();
    // §12.3 each port's connection, by the declaration it names inside; a
    // root's ports are open.
    const rows = zcu.instances.items(.ports)[k];
    const formals = vir.body(m.ports);
    for (formals, 0..) |formal, at| {
        const actual: Inst.Ref = if (rows.len == 0) .none else zcu.ports.items(.actual)[rows.start + at];
        const inner: Inst.Index = switch (Lower.tag(vir, formal)) {
            .io => formal,
            .port => blk: {
                const port = Lower.payload(vir, Inst.Port, formal);
                const value = vir.body(port.value);
                if (value.len == 0) continue;
                if (value.len > 1 or Lower.tag(vir, value[0]) != .decl_ref) return l.refuse("a port expression (§12.3.6)");
                break :blk vir.instructions.items(.data)[@backingInt(value[0])].decl_tok.decl;
            },
            else => continue, // else: a header holds only ports and port declarations
        };
        try w.conns.put(l.a, inner, .{ .actual = actual, .frame = if (actual == .none) none else w.placed[k].frame });
    }
    try items(w, f, scope, if (m.flags.ansi) m.ports else .empty, m.body, "");
}

/// One scope's items: header ports (ANSI) and declarations first, so a
/// later item can name any of them, then processes, generate blocks and
/// child instances in source order.
fn items(w: *Walk, f: u32, scope: u32, header: Vir.Body, body: Vir.Body, prefix: []const u8) Error!void {
    const l = w.l;
    const vir = l.virOf(f);
    // Each first declaration of a name, with the later ones of that name
    // in this scope (`prev`) that complete it (`input a; reg a;`).
    var later: std.AutoArrayHashMapUnmanaged(Inst.Index, std.ArrayList(Inst.Index)) = .empty;
    const all = try std.mem.concat(l.a, Inst.Index, &.{ vir.body(header), vir.body(body) });
    for (all) |i| {
        const prev: Inst.Ref = switch (Lower.tag(vir, i)) {
            .io => Lower.payload(vir, Inst.Io, i).prev,
            .net => Lower.payload(vir, Inst.Net, i).prev,
            .variable => Lower.payload(vir, Inst.Variable, i).prev,
            else => continue, // else: only these three complete one another
        };
        const first = prev.toIndex() orelse i;
        const gop = try later.getOrPut(l.a, first);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(l.a, i);
    }
    const top = l.frames.items[f].parent == none;
    w.deferred.clearRetainingCapacity();
    for (later.keys(), later.values()) |first, decls| try signal(w, f, first, decls.items, if (top) w.conns.get(first) else null);
    try l.wires.appendSlice(l.a, w.deferred.items);
    try ports.implicitNets(l, f, all);
    for (all) |i| switch (Lower.tag(vir, i)) {
        .param => _ = try param(l, f, i),
        .event => _ = try event(l, f, i),
        else => {}, // else: declared above or below
    };
    for (all) |i| switch (Lower.tag(vir, i)) {
        .initial, .always => try l.scopes.items[scope].procs.append(l.a, .{ .kind = if (Lower.tag(vir, i) == .initial) .initial else .always, .inst = i, .frame = f }),
        .variable => if (Lower.payload(vir, Inst.Variable, i).init.len != 0) {
            try l.scopes.items[scope].procs.append(l.a, .{ .kind = .init_var, .inst = i, .frame = f });
        },
        .io => if (Lower.payload(vir, Inst.Io, i).init.len != 0) {
            try l.scopes.items[scope].procs.append(l.a, .{ .kind = .init_var, .inst = i, .frame = f });
        },
        .instance => try childInstance(w, f, scope, i, prefix),
        .gen_if => {
            const g = Lower.payload(vir, Inst.GenIf, i);
            const c = (try (try l.envAt(f)).body(g.cond)) orelse return l.refuse("a generate condition Sema/eval.zig does not fold");
            try armBlock(w, f, scope, if (c.isTrue()) g.then else g.@"else", prefix);
        },
        .gen_case => try genCase(w, f, scope, Lower.payload(vir, Inst.GenCase, i), prefix),
        .gen_for => try genFor(w, f, scope, Lower.payload(vir, Inst.GenFor, i), prefix),
        .gen_block => try genBlock(w, f, scope, i, null, &.{}, prefix),
        .assign => try nets.assign(l, f, i),
        .function => try sub.declare(l, f, scope, i),
        .specify => return l.refuse("a specify block"),
        .defparam, .genvar, .param, .event, .port, .net => {},
        .analog, .analog_initial => return l.refuse("an analog block"),
        else => {}, // else: an expression of a range or a delay, read where it is used
    };
}

/// A generate arm: its `gen_block`, or nothing.
fn armBlock(w: *Walk, f: u32, scope: u32, arm: Vir.Body, prefix: []const u8) Error!void {
    const vir = w.l.virOf(f);
    for (vir.body(arm)) |b| if (Lower.tag(vir, b) == .gen_block) try genBlock(w, f, scope, b, null, &.{}, prefix);
}

/// A generate block (`index`: a loop scheme's iteration): a scope and a
/// frame of its own, its items walked in them.
fn genBlock(w: *Walk, f: u32, scope: u32, b: Inst.Index, index: ?i64, genvars: []const Frame.Genvar, prefix: []const u8) Error!void {
    const l = w.l;
    const vir = l.virOf(f);
    const blk = Lower.payload(vir, Inst.GenBlock, b);
    const name = vir.string(blk.name);
    const inner_scope = try newScope(l, scope, name, index, l.b.times.items[scope], l.srcOffset(f, b), true);
    const inner = try newFrame(l, f, l.frames.items[f].instance, inner_scope, genvars);
    _ = try l.bind(f, b, .{ .kind = .scope, .slot = inner_scope });
    // §12.4.1 the iteration's genvar reads as a localparam integer.
    if (index) |v| {
        const gv = genvars[genvars.len - 1];
        const n: Name = .{ .kind = .genvar, .ty = .{ .width = 32, .signed = true }, .msb = 31 };
        var value = n;
        value.slot = try l.b.slot(Program.Ty.int(32, true), &.{@as(u32, @truncate(@as(u64, @bitCast(v))))}, &.{0});
        _ = try l.bind(inner, gv.decl, value);
    }
    const path = if (index) |k| try std.fmt.allocPrint(l.a, "{s}{s}[{d}].", .{ prefix, name, k }) else try std.fmt.allocPrint(l.a, "{s}{s}.", .{ prefix, name });
    try items(w, inner, inner_scope, .empty, blk.body, path);
}

/// §12.4.2 a case generate scheme: the first arm a label of which equals
/// the operand, else the default arm.
fn genCase(w: *Walk, f: u32, scope: u32, g: Inst.GenCase, prefix: []const u8) Error!void {
    const l = w.l;
    const vir = l.virOf(f);
    const env = try l.envAt(f);
    const operand = (try env.body(g.operand)) orelse return l.refuse("a generate case operand Sema/eval.zig does not fold");
    var default: ?Vir.Body = null;
    for (vir.list(Inst.Arm, g.arms)) |arm| {
        if (arm.flags.default) default = arm.body;
        for (vir.list(Inst.Ref, arm.values)) |r| {
            const label = (try env.ref(r)) orelse continue;
            const eq = kernels.fold.binary(.eq, operand, label, null) orelse continue;
            if (eq.isTrue()) return armBlock(w, f, scope, arm.body, prefix);
        }
    }
    if (default) |b| try armBlock(w, f, scope, b, prefix);
}

/// §12.4.1 a loop generate scheme: one `name[value]` block per iteration,
/// its genvar bound to the iteration's value.
fn genFor(w: *Walk, f: u32, scope: u32, g: Inst.GenFor, prefix: []const u8) Error!void {
    const l = w.l;
    const vir = l.virOf(f);
    const init = storeOf(vir, g.init) orelse return l.refuse("a loop generate scheme without a genvar assignment");
    const gv = declOf(vir, init.lhs) orelse return l.refuse("a loop generate scheme without a genvar assignment");
    var v = try l.intOf(f, init.rhs);
    const step = storeOf(vir, g.step) orelse return l.refuse("a loop generate scheme without a step assignment");
    var n: u32 = 0;
    while (n < loop_max) : (n += 1) {
        const outer = l.frames.items[f].genvars;
        const genvars = try l.a.alloc(Frame.Genvar, outer.len + 1);
        @memcpy(genvars[0..outer.len], outer);
        genvars[outer.len] = .{ .decl = gv, .value = v };
        const env = try l.envAt(f);
        try env.genvars.put(env.gpa, gv, v);
        const c = (try env.body(g.cond)) orelse return l.refuse("a loop generate condition Sema/eval.zig does not fold");
        if (!c.isTrue()) return;
        for (vir.body(g.body)) |b| if (Lower.tag(vir, b) == .gen_block) {
            // The genvar reads as a localparam of the iteration (§12.4.1).
            try genBlock(w, f, scope, b, v, genvars, prefix);
        };
        const next_env = try l.envAt(f);
        try next_env.genvars.put(next_env.gpa, gv, v);
        v = ((try next_env.ref(step.rhs)) orelse return l.refuse("a loop generate step Sema/eval.zig does not fold")).asIntExact() orelse return l.refuse("a non-integral genvar");
    }
    return l.refuse("a loop generate scheme past 65536 iterations");
}

/// A body's last instruction as a `store`, or null.
fn storeOf(vir: *const Vir, b: Vir.Body) ?Inst.Bin {
    const insts = vir.body(b);
    if (insts.len == 0) return null;
    const last = insts[insts.len - 1];
    if (Lower.tag(vir, last) != .store) return null;
    return Lower.payload(vir, Inst.Bin, last);
}

/// The declaration a `decl_ref` names, or null.
fn declOf(vir: *const Vir, r: Inst.Ref) ?Inst.Index {
    const i = r.toIndex() orelse return null;
    if (Lower.tag(vir, i) != .decl_ref) return null;
    return vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl;
}

/// A module instance (each element of an array of them): where the child
/// `Zcu` made is placed in the scope tree. Gates and UDP instances are
/// refused for now.
fn childInstance(w: *Walk, f: u32, scope: u32, i: Inst.Index, prefix: []const u8) Error!void {
    const l = w.l;
    const vir = l.virOf(f);
    const in = Lower.payload(vir, Inst.Instance, i);
    switch (in.flags.kind) {
        .gate => return l.refuse("a gate instance"),
        .udp => return l.refuse("a UDP instance"),
        .module => {},
    }
    const target = try l.zcu.intern_pool.getString(l.a, vir.string(in.target));
    if (l.zcu.modules.get(target)) |d| if (l.zcu.declRow(d).kind == .primitive) return l.refuse("a UDP instance");
    const name = vir.string(in.name);
    const at = l.srcOffset(f, i);
    if (in.range.len == 0) return place(w, f, scope, prefix, name, null, at);
    const r = vir.body(in.range);
    const bin = Lower.payload(vir, Inst.Bin, r[r.len - 1]);
    const msb = try l.intOf(f, bin.lhs);
    const lsb = try l.intOf(f, bin.rhs);
    var k: i64 = @min(msb, lsb);
    while (k <= @max(msb, lsb)) : (k += 1) try place(w, f, scope, prefix, name, k, at);
}

fn place(w: *Walk, f: u32, scope: u32, prefix: []const u8, name: []const u8, index: ?i64, at: u32) Error!void {
    const l = w.l;
    const full = if (index) |k| try std.fmt.allocPrint(l.a, "{s}{s}[{d}]", .{ prefix, name, k }) else try std.fmt.allocPrint(l.a, "{s}{s}", .{ prefix, name });
    const key: Child = .{ .parent = w.index, .name = try l.zcu.intern_pool.getString(l.a, full) };
    const child = w.children.get(key) orelse return l.refuse("an instance the elaboration did not make");
    w.placed[child] = .{ .scope = scope, .frame = f, .index = index, .at = at, .name = name };
}

/// A variable, net or port, from its first declaration `first` and the
/// later ones `decls` that complete it (`first` included); `conn` is a
/// port's connection.
fn signal(w: *Walk, f: u32, first: Inst.Index, decls: []const Inst.Index, conn: ?ports.Conn) Error!void {
    const l = w.l;
    const vir = l.virOf(f);
    var storage: Inst.Storage = .none;
    var dir: Inst.Direction = .none;
    for (decls) |d| switch (Lower.tag(vir, d)) {
        .io => {
            const io = Lower.payload(vir, Inst.Io, d);
            if (io.flags.storage != .none) storage = io.flags.storage;
            dir = io.flags.dir;
        },
        .net => {},
        .variable => storage = Lower.payload(vir, Inst.Variable, d).flags.storage,
        else => unreachable, // else: `items` groups only these three
    };
    if (storage == .none) {
        var only: std.ArrayList(Inst.Index) = .empty;
        for (decls) |d| if (Lower.tag(vir, d) != .variable) try only.append(l.a, d);
        return ports.declareNet(l, f, first, only.items, conn, &w.deferred);
    }
    const at = try variable(l, f, first, decls);
    const c = conn orelse return;
    if (dir != .output) {
        if (c.actual == .none) return;
        return l.refuse("§12.3.3 an input or inout port declared as a variable");
    }
    try ports.outputVariable(l, f, l.names.items[at], c, &w.deferred);
}

/// §4.9 the unpacked dimensions of a dims body, outermost first, into `n`.
fn arrayOf(l: *Lower, f: u32, dims: Vir.Body, n: *Name) Error!void {
    if (dims.len == 0) return;
    const vir = l.virOf(f);
    var spans: std.ArrayList(Span) = .empty;
    var count: u64 = 1;
    for (vir.body(dims)) |d| {
        if (Lower.tag(vir, d) != .range) continue;
        const bin = Lower.payload(vir, Inst.Bin, d);
        const hi = try l.intOf(f, bin.lhs);
        const lo = try l.intOf(f, bin.rhs);
        const span: Span = .{ .low = @min(lo, hi), .high = @max(lo, hi) };
        count *= std.math.cast(u64, @as(i128, span.high) - span.low + 1) orelse return l.refuse("an array past 2^24 elements");
        if (count > array_max) return l.refuse("an array past 2^24 elements");
        try spans.append(l.a, span);
    }
    n.dims = spans.items;
    n.count = @intCast(count);
}
