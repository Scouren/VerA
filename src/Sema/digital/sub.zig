//! Tasks and functions of the digital lowering: a `function` declaration (a
//! task is one with `flags.task`) in; a `Program.subs` row, a scope, and a
//! frame binding its result, formals and locals to slots of its own, out.
//! A function call, and the enable of a task that cannot suspend, is one
//! `call` of a body compiled once; a task that can (a timing control, a
//! fork, or an enable of such a task) is inlined where it is enabled (copy
//! in, its body in its frame, copy out) as lib/sim/digital does, so its
//! suspensions are the enabling process's own.
//! Cites: IEEE 1364-2005 §10.2.1, §10.2.2, §10.2.3, §10.3, §10.4.1, §10.4.2.
//!
//! Contents:
//! - `pub const Storage = struct`, `pub const Row = struct`
//! - `pub fn declare(l: *Lower, f: u32, scope: u32, i: Inst.Index) Error!void`
//! - `pub fn resultType(l: *Lower, i: Inst.Index) Error!Type`
//! - `pub fn callRow(l: *Lower, i: Inst.Index) Error!u32`
//! - `pub fn enable(l: *Lower, i: Inst.Index, depth: u32) Error!void`
//! - `pub fn compileBodies(l: *Lower) Error!void`
//! - `pub fn finish(l: *Lower) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const std_sim = @import("std_sim");
const digital = @import("../digital.zig");
const decl = @import("decl.zig");
const vars = @import("vars.zig");
const expr = @import("expr.zig");
const place = @import("place.zig");
const stmt = @import("stmt.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const Type = digital.Type;
const Name = digital.Name;
const none = digital.none;
const Program = std_sim.Program;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// One activation record of a subroutine: its frame and its slots
/// [first, first + count) (the result, the formals, the variables and
/// events; not its parameters), its result slot (`none` for a task) and
/// its formals' slots in formal order.
pub const Storage = struct {
    frame: u32,
    first: u32,
    count: u32,
    result: u32,
    ports: []const u32,
};

/// One `Program.subs` row and its lowering facts: the declaration, the
/// frame declaring it, its scope, its own storage, a function's result
/// type, whether it can suspend (unset until asked), whether its inlined
/// body is being compiled now, and the pc ranges of its inlined copies.
pub const Row = struct {
    decl: Inst.Index,
    outer: u32,
    scope: u32,
    own: Storage,
    result_ty: Type,
    function: bool,
    automatic: bool,
    entry: u32 = none,
    timed: ?bool = null,
    inlining: bool = false,
    ranges: std.ArrayList(u32) = .empty,
};

/// The deepest statement nest searched for a timing control.
const depth_max: u32 = 1 << 12;

/// §10.2.1/§10.4.1 subroutine `i` of frame `f`: a scope under `scope`, its
/// storage, and its name bound in `f` to its row.
pub fn declare(l: *Lower, f: u32, scope: u32, i: Inst.Index) Error!void {
    const vir = l.virOf(f);
    const s = Lower.payload(vir, Inst.Function, i);
    if (s.flags.analog) return l.refuse("an analog function");
    const sc = try decl.newScope(l, scope, vir.string(s.name), null, l.b.times.items[scope], l.srcOffset(f, i), false);
    const own = try storage(l, f, sc, i);
    const row: u32 = @intCast(l.subs.items.len);
    const result_ty = if (own.result == none) Type{ .width = 1, .signed = false } else typeOfTy(l.b.p.slots.items(.ty)[own.result]);
    try l.subs.append(l.a, .{ .decl = i, .outer = f, .scope = sc, .own = own, .result_ty = result_ty, .function = !s.flags.task, .automatic = s.flags.automatic });
    _ = try l.bind(f, i, .{ .kind = .sub, .slot = row });
    assert(l.subs.items.len == row + 1);
}

/// §10.4.1 the type of function call `i`: its result's.
pub fn resultType(l: *Lower, i: Inst.Index) Error!Type {
    const row = try callee(l, i);
    if (!l.subs.items[row].function) return l.refuse("§10.4 a task called as a function");
    return l.subs.items[row].result_ty;
}

/// A `Program.Call` (in `extra`) of call `i` in `Lower.frame`: per formal,
/// its input value in the formal's type and its output's place.
pub fn callRow(l: *Lower, i: Inst.Index) Error!u32 {
    const row = try callee(l, i);
    const r = l.subs.items[row];
    const args = try argsOf(l, i, r);
    const out = try l.a.alloc(Program.Arg, args.len);
    for (args, r.own.ports, out, 0..) |a, slot, *o, k| {
        const ty = l.b.p.slots.items(.ty)[slot];
        const dir = dirOf(l, r, k);
        o.* = .{ .in = none, .place = none, .ty = ty };
        if (dir != .output) o.in = try expr.evalFor(l, a, typeOfTy(ty));
        if (dir != .input) {
            o.place = try place.place(l, a);
            o.ty = try l.tyOf(try place.targetType(l, a));
        }
    }
    const start: u32 = @intCast(l.b.extra.items.len);
    for (out) |o| _ = try l.b.extraOf(o);
    assert(l.b.extra.items.len == start + 4 * out.len);
    return l.b.extraOf(Program.Call{ .sub = row, .args = .{ .start = start, .len = @intCast(4 * out.len) } });
}

/// §10.2.2 task enable `i` in `Lower.frame`: a `call`, or for a task that
/// can suspend its body inlined here. A static task's copies share its one
/// storage (§10.2.3); an automatic one's each get storage of their own,
/// one per activation since a site cannot be re-entered while suspended.
pub fn enable(l: *Lower, i: Inst.Index, depth: u32) Error!void {
    const row = try callee(l, i);
    const scope = l.frames.items[l.frame].scope;
    if (l.subs.items[row].function) return l.refuse("§10.4 a function enabled as a task");
    if (!try timed(l, row)) {
        _ = try l.b.inst(.call, try callRow(l, i), 0, scope);
        return;
    }
    if (l.subs.items[row].inlining) return l.refuse("a timed task that enables itself");
    l.subs.items[row].inlining = true;
    defer l.subs.items[row].inlining = false;
    const r = l.subs.items[row];
    const st = if (r.automatic) try storage(l, r.outer, r.scope, r.decl) else r.own;
    const args = try argsOf(l, i, r);
    const start: u32 = @intCast(l.b.p.insts.len);
    for (args, st.ports, 0..) |a, slot, k| if (dirOf(l, r, k) != .output) {
        _ = try l.b.inst(.init_var, slot, try expr.evalFor(l, a, typeOfTy(l.b.p.slots.items(.ty)[slot])), scope);
    };
    const caller = l.frame;
    l.frame = st.frame;
    const fvir = l.virOf(r.outer);
    try stmt.body(l, Lower.payload(fvir, Inst.Function, r.decl).body, depth + 1);
    l.frame = caller;
    for (args, st.ports, 0..) |a, slot, k| if (dirOf(l, r, k) != .input) {
        const c: Program.CopyOut = .{ .place = try place.place(l, a), .slot = slot, .ty = try l.tyOf(try place.targetType(l, a)) };
        _ = try l.b.inst(.copy_out, try l.b.extraOf(c), 0, scope);
    };
    try l.subs.items[row].ranges.appendSlice(l.a, &.{ start, @intCast(l.b.p.insts.len) });
    assert(l.b.p.insts.len >= start);
}

/// Every subroutine that cannot suspend, its body at an entry of its own
/// ended by `stop`; a task that can is inlined where it is enabled.
pub fn compileBodies(l: *Lower) Error!void {
    for (0..l.subs.items.len) |k| {
        if (try timed(l, @intCast(k))) continue;
        const r = l.subs.items[k];
        assert(r.entry == none);
        l.frame = r.own.frame;
        l.subs.items[k].entry = @intCast(l.b.p.insts.len);
        const vir = l.virOf(r.outer);
        try stmt.body(l, Lower.payload(vir, Inst.Function, r.decl).body, 0);
        _ = try l.b.inst(.stop, 0, 0, r.scope);
    }
}

/// Writes `Program.subs`, one row per subroutine in declaration order.
pub fn finish(l: *Lower) Error!void {
    const out = try l.a.alloc(Program.Sub, l.subs.items.len);
    for (l.subs.items, out) |r, *s| {
        assert(r.ranges.items.len % 2 == 0);
        s.* = .{
            .entry = r.entry,
            .function = r.function,
            .automatic = r.automatic,
            .first = r.own.first,
            .count = r.own.count,
            .result = r.own.result,
            .ports = try l.b.listOf(r.own.ports),
            .ranges = try l.b.listOf(r.ranges.items),
        };
    }
    l.b.p.subs = out;
}

// ---- private ----

fn typeOfTy(t: Program.Ty) Type {
    return .{ .width = t.width, .signed = t.signed, .real = t.real };
}

/// A frame for subroutine `i` of frame `outer` in scope `scope`, its slots
/// laid out: the result, the formals (with the declarations completing
/// them), the variables and events, then the parameters, which no
/// activation resets.
fn storage(l: *Lower, outer: u32, scope: u32, i: Inst.Index) Error!Storage {
    const vir = l.virOf(outer);
    const s = Lower.payload(vir, Inst.Function, i);
    const f = try decl.newFrame(l, outer, l.frames.items[outer].instance, scope, l.frames.items[outer].genvars);
    l.frames.items[f].automatic = s.flags.automatic;
    const first: u32 = @intCast(l.b.p.slots.len);
    var result: u32 = none;
    if (!s.flags.task) {
        const n = try resultName(l, outer, s);
        result = n.slot;
        _ = try l.bind(f, i, n);
    }
    // Each formal or variable by its first declaration, with the later ones
    // completing it (`input x; reg x;`).
    var later: std.AutoArrayHashMapUnmanaged(Inst.Index, std.ArrayList(Inst.Index)) = .empty;
    const all = try std.mem.concat(l.a, Inst.Index, &.{ vir.body(s.formals), vir.body(s.body) });
    for (all) |d| {
        const prev: Inst.Ref = switch (Lower.tag(vir, d)) {
            .io => Lower.payload(vir, Inst.Io, d).prev,
            .variable => blk: {
                const v = Lower.payload(vir, Inst.Variable, d);
                if (v.init.len != 0) return l.refuse("an initialized subroutine variable");
                break :blk v.prev;
            },
            else => continue, // else: declared below, or a statement
        };
        const gop = try later.getOrPut(l.a, prev.toIndex() orelse d);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(l.a, d);
    }
    for (later.keys(), later.values()) |d, decls| _ = try vars.variable(l, f, d, decls.items);
    for (all) |d| if (Lower.tag(vir, d) == .event) {
        _ = try vars.event(l, f, d);
    };
    const count: u32 = @as(u32, @intCast(l.b.p.slots.len)) - first;
    for (all) |d| if (Lower.tag(vir, d) == .param) {
        _ = try vars.param(l, f, d);
    };
    const formals = vir.body(s.formals);
    const ports = try l.a.alloc(u32, formals.len);
    for (formals, ports) |d, *p| {
        const n = l.names.items[l.lookup(f, d).?];
        if (n.dims.len != 0) return l.refuse("an array formal");
        p.* = n.slot;
    }
    return .{ .frame = f, .first = first, .count = count, .result = result, .ports = ports };
}

/// §10.4.1 a function's result variable, named by the function: a slot of
/// its declared type (one bit by default), x (a real 0.0).
fn resultName(l: *Lower, outer: u32, s: Inst.Function) Error!Name {
    var n: Name = .{ .kind = .variable };
    switch (s.flags.storage) {
        .integer => n.ty = .{ .width = 32, .signed = true },
        .time => n.ty = .{ .width = 64, .signed = false },
        .real, .realtime => n.ty = Type.real_type,
        .string => return l.refuse("a string function"),
        .reg, .none => n.ty = .{ .width = 1, .signed = s.flags.signed },
    }
    if (s.range.len != 0) {
        if (n.ty.real) return l.refuse("a real with a range");
        const r = try vars.rangeOf(l, outer, s.range);
        n.msb = r.msb;
        n.lsb = r.lsb;
        n.ty.width = r.width;
    } else {
        n.msb = @as(i64, n.ty.width) - 1;
        n.scalar = s.flags.storage == .reg or s.flags.storage == .none;
    }
    n.slot = try vars.slots(l, n.ty, 1, if (n.ty.real) .zero else .x);
    return n;
}

/// The `subs` row call or enable `i` names from `Lower.frame` (inside a
/// function its name is its result variable, so the row is found further
/// out).
fn callee(l: *Lower, i: Inst.Index) Error!u32 {
    const vir = l.virOf(l.frame);
    const c = Lower.payload(vir, Inst.Call, i);
    const ci = c.callee.toIndex() orelse return l.refuse("a call of no subroutine");
    if (Lower.tag(vir, ci) != .decl_ref) return l.refuse("a hierarchical task or function name");
    const d = vir.instructions.items(.data)[@backingInt(ci)].decl_tok.decl;
    var f = l.frame;
    var steps: u32 = 0;
    while (f != none) : (f = l.frames.items[f].parent) {
        steps += 1;
        assert(steps <= l.frames.items.len);
        const at = l.frames.items[f].names.get(d) orelse continue;
        if (l.names.items[at].kind == .sub) return l.names.items[at].slot;
    }
    return l.refuse("a task or function its walk did not declare");
}

/// The arguments of call `i`, one per formal of row `r`.
fn argsOf(l: *Lower, i: Inst.Index, r: Row) Error![]const Inst.Ref {
    const vir = l.virOf(l.frame);
    const args = vir.list(Inst.Ref, Lower.payload(vir, Inst.Call, i).args);
    if (args.len != r.own.ports.len) return l.refuse("§10.2.2 a call with one argument per formal not given");
    for (args) |a| if (a == .none) return l.refuse("§10.2.2 an omitted argument");
    return args;
}

/// The direction of formal `k` of row `r`.
fn dirOf(l: *Lower, r: Row, k: usize) Inst.Direction {
    const vir = l.virOf(r.outer);
    const formals = vir.body(Lower.payload(vir, Inst.Function, r.decl).formals);
    return Lower.payload(vir, Inst.Io, formals[k]).flags.dir;
}

/// Whether task `row` can suspend: it holds a timing control or a fork, or
/// enables a task that can. A recursive enable counts as untimed while it
/// is being asked about; a function never can (§10.4.4).
fn timed(l: *Lower, row: u32) Error!bool {
    if (l.subs.items[row].timed) |t| return t;
    l.subs.items[row].timed = false;
    if (l.subs.items[row].function) return false;
    const r = l.subs.items[row];
    const saved = l.frame;
    defer l.frame = saved;
    l.frame = r.own.frame;
    const vir = l.virOf(r.outer);
    const t = try bodyTimed(l, vir, Lower.payload(vir, Inst.Function, r.decl).body, 0);
    l.subs.items[row].timed = t;
    return t;
}

fn bodyTimed(l: *Lower, vir: *const Vir, b: Vir.Body, depth: u32) Error!bool {
    if (depth >= depth_max) return l.refuse("statements nested past 4096 levels");
    for (vir.body(b)) |i| {
        const t = switch (Lower.tag(vir, i)) {
            .delay, .event_wait, .wait, .store_timed, .store_nb_timed => true,
            .block => blk: {
                const k = Lower.payload(vir, Inst.Block, i);
                break :blk k.flags.fork or try bodyTimed(l, vir, k.body, depth + 1);
            },
            .condbr => blk: {
                const c = Lower.payload(vir, Inst.CondBr, i);
                break :blk try bodyTimed(l, vir, c.then, depth + 1) or try bodyTimed(l, vir, c.@"else", depth + 1);
            },
            .loop => blk: {
                const lp = Lower.payload(vir, Inst.Loop, i);
                break :blk try bodyTimed(l, vir, lp.body, depth + 1) or try bodyTimed(l, vir, lp.step, depth + 1);
            },
            .repeat => try bodyTimed(l, vir, Lower.payload(vir, Inst.Repeat, i).body, depth + 1),
            .case => for (vir.list(Inst.Arm, Lower.payload(vir, Inst.Case, i).arms)) |arm| {
                if (try bodyTimed(l, vir, arm.body, depth + 1)) break true;
            } else false,
            .call => try timed(l, try callee(l, i)),
            else => false, // else: no other instruction suspends or nests a statement
        };
        if (t) return true;
    }
    return false;
}
