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
//! - `pub fn blockFrame(l: *Lower, outer: u32, i: Inst.Index) Error!u32`

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
const gates = @import("gates.zig");
const specify = @import("specify.zig");
const vars = @import("vars.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const Name = digital.Name;
const Frame = digital.Frame;
const none = digital.none;
const Program = std_sim.Program;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// The most iterations one loop generate scheme unrolls (`walk.zig`'s).
const loop_max: u32 = 1 << 16;

const Placement = struct { scope: u32 = none, frame: u32 = none, inst: Inst.Index = undefined, index: ?i64 = null, lane: ?[2]u32 = null, at: u32 = 0, name: []const u8 = "" };
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
    l.sites = try l.a.alloc(Lower.Site, n);
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

/// §12.5 named block `i` of frame `outer`: its scope and frame, its block
/// items bound, made the first time it is asked for.
pub fn blockFrame(l: *Lower, outer: u32, i: Inst.Index) Error!u32 {
    const gop = try l.block_frames.getOrPut(l.a, .{ .outer = outer, .inst = i });
    if (gop.found_existing) return gop.value_ptr.*;
    const vir = l.virOf(outer);
    const blk = Lower.payload(vir, Inst.Block, i);
    const outer_scope = l.frames.items[outer].scope;
    const s = try newScope(l, outer_scope, vir.string(blk.name), null, l.b.times.items[outer_scope], l.srcOffset(outer, i), false);
    const f = try newFrame(l, outer, l.frames.items[outer].instance, s, l.frames.items[outer].genvars);
    // §10.2.1 an automatic subroutine's block items are per activation,
    // which its storage (laid out at its declaration) does not hold.
    l.frames.items[f].automatic = l.frames.items[outer].automatic;
    gop.value_ptr.* = f;
    const slots_before = l.b.p.slots.len;
    try vars.locals(l, f, blk.body);
    if (l.frames.items[outer].automatic and l.b.p.slots.len != slots_before) return l.refuse("a named block declaring storage in an automatic subroutine");
    return f;
}

// ---- private ----

/// §12.5 the named blocks of a process body, made at the walk (as
/// lib/sim/digital's elaboration binds them), so a hierarchical name in any
/// process reaches them.
fn preBlocks(l: *Lower, f: u32, b: Vir.Body, depth: u32) Error!void {
    if (depth >= 1 << 12) return l.refuse("statements nested past 4096 levels");
    const vir = l.virOf(f);
    for (vir.body(b)) |i| switch (Lower.tag(vir, i)) {
        .block => {
            const blk = Lower.payload(vir, Inst.Block, i);
            const inner = if (blk.name == .empty) f else try blockFrame(l, f, i);
            try preBlocks(l, inner, blk.body, depth + 1);
        },
        .condbr => {
            const c = Lower.payload(vir, Inst.CondBr, i);
            try preBlocks(l, f, c.then, depth + 1);
            try preBlocks(l, f, c.@"else", depth + 1);
        },
        .loop => {
            const lp = Lower.payload(vir, Inst.Loop, i);
            try preBlocks(l, f, lp.body, depth + 1);
            try preBlocks(l, f, lp.step, depth + 1);
        },
        .repeat => try preBlocks(l, f, Lower.payload(vir, Inst.Repeat, i).body, depth + 1),
        .delay => try preBlocks(l, f, Lower.payload(vir, Inst.Delay, i).body, depth + 1),
        .event_wait => try preBlocks(l, f, Lower.payload(vir, Inst.EventWait, i).body, depth + 1),
        .wait => try preBlocks(l, f, Lower.payload(vir, Inst.Wait, i).body, depth + 1),
        .case => for (vir.list(Inst.Arm, Lower.payload(vir, Inst.Case, i).arms)) |arm| try preBlocks(l, f, arm.body, depth + 1),
        else => {}, // else: no other statement nests one
    };
}

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
    l.sites[k] = if (parent == .none) .{ .frame = none, .inst = row.inst } else .{ .frame = w.placed[k].frame, .inst = w.placed[k].inst };
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
        try w.conns.put(l.a, inner, .{ .actual = actual, .frame = if (actual == .none) none else w.placed[k].frame, .lane = w.placed[k].lane });
    }
    // A.1.3 the header's `#( parameter ... )` list, before the body's items.
    for (vir.body(m.params)) |p| if (Lower.tag(vir, p) == .param) {
        _ = try vars.param(l, f, p);
    };
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
    // A parameter's value may call a constant function (§10.4.5).
    for (all) |i| if (Lower.tag(vir, i) == .function) try sub.declare(l, f, scope, i);
    for (all) |i| switch (Lower.tag(vir, i)) {
        .param => _ = try vars.param(l, f, i),
        .event => _ = try vars.event(l, f, i),
        else => {}, // else: declared above or below
    };
    for (all) |i| switch (Lower.tag(vir, i)) {
        .initial, .always => {
            try l.scopes.items[scope].procs.append(l.a, .{ .kind = if (Lower.tag(vir, i) == .initial) .initial else .always, .inst = i, .frame = f });
            try preBlocks(l, f, Lower.payload(vir, Inst.Process, i).body, 0);
        },
        .variable => if (Lower.payload(vir, Inst.Variable, i).init.len != 0) {
            try l.scopes.items[scope].procs.append(l.a, .{ .kind = .init_var, .inst = i, .frame = f });
        },
        .io => if (Lower.payload(vir, Inst.Io, i).init.len != 0) {
            try l.scopes.items[scope].procs.append(l.a, .{ .kind = .init_var, .inst = i, .frame = f });
        },
        .instance => try childInstance(w, f, scope, i, prefix),
        .gen_if, .gen_case => try scheme(w, f, scope, i, prefix),
        .gen_for => try genFor(w, f, scope, Lower.payload(vir, Inst.GenFor, i), prefix),
        .gen_block => try genBlock(w, f, scope, i, null, &.{}, prefix),
        .assign => try nets.assign(l, f, i),
        .function => {}, // declared above
        .specify => try specify.block(l, f, i),
        .defparam => try l.defparam_frames.put(l.a, .{ .instance = @backingInt(l.frames.items[f].instance), .inst = i }, f),
        .genvar, .param, .event, .port, .net => {},
        .analog, .analog_initial => return l.refuse("an analog block"),
        else => {}, // else: an expression of a range or a delay, read where it is used
    };
}

/// §12.4.2 a conditional generate scheme: the arm its condition (or case
/// operand) picks.
fn scheme(w: *Walk, f: u32, scope: u32, i: Inst.Index, prefix: []const u8) Error!void {
    const l = w.l;
    const vir = l.virOf(f);
    if (Lower.tag(vir, i) == .gen_case) return genCase(w, f, scope, Lower.payload(vir, Inst.GenCase, i), prefix);
    const g = Lower.payload(vir, Inst.GenIf, i);
    const c = (try (try l.envAt(f)).body(g.cond)) orelse return l.refuse("a generate condition Sema/eval.zig does not fold");
    try armBlock(w, f, scope, if (c.isTrue()) g.then else g.@"else", prefix);
}

/// A generate arm: its `gen_block`, a conditional scheme nested directly
/// in it (§12.4.2, no scope of its own), or nothing.
fn armBlock(w: *Walk, f: u32, scope: u32, arm: Vir.Body, prefix: []const u8) Error!void {
    const vir = w.l.virOf(f);
    for (vir.body(arm)) |b| switch (Lower.tag(vir, b)) {
        .gen_block => try genBlock(w, f, scope, b, null, &.{}, prefix),
        .gen_if, .gen_case => try scheme(w, f, scope, b, prefix),
        else => {}, // else: the arm's condition expressions
    };
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
            const eq = @import("std_kernels").fold.binary(.eq, operand, label, null) orelse continue;
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
/// `Zcu` made is placed in the scope tree; a gate or UDP instance is
/// lowered in place (`gates.zig`).
fn childInstance(w: *Walk, f: u32, scope: u32, i: Inst.Index, prefix: []const u8) Error!void {
    const l = w.l;
    const vir = l.virOf(f);
    const in = Lower.payload(vir, Inst.Instance, i);
    switch (in.flags.kind) {
        .gate => return gates.instance(l, f, i),
        .udp, .module => {},
    }
    const target = try l.zcu.intern_pool.getString(l.a, vir.string(in.target));
    if (l.zcu.modules.get(target)) |d| if (l.zcu.declRow(d).kind == .primitive) return gates.udp(l, f, i, d);
    if (in.flags.kind == .udp) return l.refuse("a UDP instance of no primitive");
    const name = vir.string(in.name);
    const at = l.srcOffset(f, i);
    if (in.range.len == 0) return place(w, f, scope, i, prefix, name, null, null, at);
    const r = vir.body(in.range);
    const bin = Lower.payload(vir, Inst.Bin, r[r.len - 1]);
    const msb = try l.intOf(f, bin.lhs);
    const lsb = try l.intOf(f, bin.rhs);
    var k: i64 = @min(msb, lsb);
    // §12.1.2 the leftmost index takes the most significant lane.
    const lanes: u32 = @intCast(@abs(msb - lsb) + 1);
    while (k <= @max(msb, lsb)) : (k += 1) try place(w, f, scope, i, prefix, name, k, .{ lanes - 1 - @as(u32, @intCast(@abs(k - msb))), lanes }, at);
}

fn place(w: *Walk, f: u32, scope: u32, i: Inst.Index, prefix: []const u8, name: []const u8, index: ?i64, lane: ?[2]u32, at: u32) Error!void {
    const l = w.l;
    const full = if (index) |k| try std.fmt.allocPrint(l.a, "{s}{s}[{d}]", .{ prefix, name, k }) else try std.fmt.allocPrint(l.a, "{s}{s}", .{ prefix, name });
    const key: Child = .{ .parent = w.index, .name = try l.zcu.intern_pool.getString(l.a, full) };
    const child = w.children.get(key) orelse return l.refuse("an instance the elaboration did not make");
    w.placed[child] = .{ .scope = scope, .frame = f, .inst = i, .index = index, .lane = lane, .at = at, .name = name };
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
    const at = try vars.variable(l, f, first, decls);
    const c = conn orelse return;
    if (dir != .output) {
        if (c.actual == .none) return;
        return l.refuse("§12.3.3 an input or inout port declared as a variable");
    }
    try ports.outputVariable(l, f, l.names.items[at], c, &w.deferred);
}
