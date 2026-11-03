//! §6.3.1 defparams: each one the walk reads (its value folded where it is
//! written, its target a path) in; a value given to the parameter of the
//! instance the path names out, as that instance is made. A path is placed
//! down the existing tree from the instance (or, for an upward or absolute
//! one, the ancestor or root its head names) and waits at the deepest
//! instance reached; a target that exists already is a late one, recorded
//! by path for the walk's next pass (IEEE 1364-2005 §12.8.1). Of two for
//! one parameter the later in the source wins (§12.2.1).
//! Cites: VAMS-2023 §6.3.1, §7.8.5; IEEE 1364-2005 §12.2.1, §12.5, §12.8.1.
//!
//! Contents:
//! - `pub const Dp`, `pub const Waiting`, `pub const Row`, `pub const Origin`, `pub const Late`
//! - `pub fn reportUnused(s: *Sema, waiting: Waiting) Allocator.Error!void`
//! - `pub fn waitingFor(s: *Sema, waiting: Waiting, parent: Instance.Index, name: []const u8) Allocator.Error![]const Dp`
//! - `pub fn applyDefparams(s: *Sema, env: *Env, dps: []const Dp, module: Vir.String) Allocator.Error!void`
//! - `pub fn reaching(w: *Walk, p: Pending, index: Instance.Index) Allocator.Error![]const Dp`
//! - `pub fn keepLatest(s: *Sema, out: *std.ArrayList(Dp), dp: Dp) Allocator.Error!void`
//! - `pub fn collect(w: *Walk, env: *Env, index: Instance.Index, file: Zcu.File.Index, i: Inst.Index) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Sema = @import("../Sema.zig");
const Zcu = @import("../Zcu.zig");
const eval = @import("eval.zig");
const walk = @import("walk.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Env = eval.Env;
const Instance = Zcu.Instance;
const Walk = walk.Walk;
const Pending = walk.Pending;
const payloadOf = walk.payloadOf;

/// A §6.3.1 defparam that reached the instance being made: the parameter
/// it names, its value and where it is written.
pub const Dp = struct { name: []const u8, value: InternPool.Index, file: Zcu.File.Index, src: Inst.Ref };

/// The defparams the walk left waiting below an instance (one that names a
/// connect module §7.8 inserts after the walk, or nothing), and every
/// defparam as written.
pub const Waiting = struct { rows: []const Row, origins: []Origin };

/// A defparam waiting for its target below `anchor`, `rel` the path to it.
pub const Row = struct { anchor: Instance.Index, rel: []const u8, param: []const u8, value: InternPool.Index, origin: u32 };

/// A defparam as written, for E0907 when it never reaches a parameter.
pub const Origin = struct { file: Zcu.File.Index, src: Inst.Ref, text: []const u8, used: bool = false };

/// A late defparam: its parameter, value and source, under its target's path.
pub const Late = struct { param: []const u8, value: InternPool.Index, file: Zcu.File.Index, src: Inst.Ref };

/// E0907 for every defparam that reached no instance.
pub fn reportUnused(s: *Sema, waiting: Waiting) Allocator.Error!void {
    for (waiting.rows) |r| assert(r.origin < waiting.origins.len);
    for (waiting.origins) |o| if (!o.used)
        try s.fail(.E0907, o.file, o.src, "`{s}` names no parameter of the elaborated design", .{o.text});
}

/// The waiting defparams that name a new child `name` of `parent` (a
/// connect module §7.8 inserts), each marked used, the later of two for one
/// parameter kept (IEEE 1364-2005 §12.2.1).
pub fn waitingFor(s: *Sema, waiting: Waiting, parent: Instance.Index, name: []const u8) Allocator.Error![]const Dp {
    assert(name.len != 0);
    assert(@backingInt(parent) < s.zcu.instances.len);
    var out: std.ArrayList(Dp) = .empty;
    for (waiting.rows) |r| {
        if (r.anchor != parent or !std.mem.eql(u8, r.rel, name)) continue;
        waiting.origins[r.origin].used = true;
        const o = waiting.origins[r.origin];
        try keepLatest(s, &out, .{ .name = r.param, .value = r.value, .file = o.file, .src = o.src });
    }
    return out.items;
}

/// Gives each defparam's value to the parameter it names, over any `#()`
/// override; E0907 for a name that is no parameter of the module.
pub fn applyDefparams(s: *Sema, env: *Env, dps: []const Dp, module: Vir.String) Allocator.Error!void {
    assert(env.positions.count() == env.values.items.len);
    for (dps) |dp| assert(dp.name.len != 0);
    for (dps) |dp| {
        if (env.systemNamed(dp.name) != null) continue;
        const q = env.named(dp.name) orelse {
            try s.fail(.E0907, dp.file, dp.src, "`{s}` is not a parameter of `{s}`", .{ dp.name, env.vir.string(module) });
            continue;
        };
        // §3.4.7: a parameter and its alias are not both given a value.
        if (env.spelling.get(q)) |before| if (!std.mem.eql(u8, before, dp.name))
            try s.fail(.E0908, dp.file, dp.src, "`{s}` and its alias are both given a value", .{env.vir.string(payloadOf(env.vir, Inst.Param, q).name)});
        try env.given.put(s.gpa, q, dp.value);
    }
}

/// The defparams that reach the new instance `index` (`p`): those anchored
/// at its parent that name it, and the late ones recorded under its path;
/// of two for one parameter (alias spellings apart), the later in the source (IEEE 1364-2005
/// §12.2.1: files in order, then instructions, which AstGen numbers in
/// source order). Re-anchors at it those that name its descendants.
pub fn reaching(w: *Walk, p: Pending, index: Instance.Index) Allocator.Error![]const Dp {
    assert(@backingInt(index) == w.zcu.instances.len);
    if (p.parent != .none) assert(@backingInt(p.parent) < @backingInt(index));
    const s = w.s;
    const name = w.zcu.intern_pool.stringToSlice(p.name);
    var out: std.ArrayList(Dp) = .empty;
    w.matched.clearRetainingCapacity();
    if (p.parent != .none) {
        var i: usize = 0;
        while (i < w.rows.items.len) : (i += 1) {
            const r = w.rows.items[i];
            if (r.anchor != p.parent) continue;
            if (std.mem.eql(u8, r.rel, name)) {
                const o = w.origins.items[r.origin];
                try w.matched.append(s.arena, r.origin);
                try keepLatest(s, &out, .{ .name = r.param, .value = r.value, .file = o.file, .src = o.src });
            } else if (r.rel.len > name.len and std.mem.startsWith(u8, r.rel, name) and r.rel[name.len] == '.') {
                try w.rows.append(s.arena, .{ .anchor = index, .rel = r.rel[name.len + 1 ..], .param = r.param, .value = r.value, .origin = r.origin });
            }
        }
    }
    if (w.late.count() == 0) return out.items;
    const path = if (p.parent == .none) name else try std.fmt.allocPrint(s.arena, "{f}.{s}", .{ w.zcu.fmtPath(p.parent), name });
    if (w.late.get(path)) |list| for (list.items) |l|
        try keepLatest(s, &out, .{ .name = l.param, .value = l.value, .file = l.file, .src = l.src });
    return out.items;
}

pub fn keepLatest(s: *Sema, out: *std.ArrayList(Dp), dp: Dp) Allocator.Error!void {
    assert(dp.name.len != 0);
    const before = out.items.len;
    defer assert(out.items.len == before or out.items.len == before + 1);
    for (out.items) |*o| if (std.mem.eql(u8, o.name, dp.name)) {
        if (later(dp, o.*)) o.* = dp;
        return;
    };
    try out.append(s.arena, dp);
}

/// §6.3.1 one defparam: its value folded here, its target placed below the
/// instance (a path through this module's scopes) or, for a path whose head
/// names no declaration here, below the ancestor or root it names.
pub fn collect(w: *Walk, env: *Env, index: Instance.Index, file: Zcu.File.Index, i: Inst.Index) Allocator.Error!void {
    assert(env.vir.instructions.items(.tag)[@backingInt(i)] == .defparam);
    assert(@backingInt(index) < w.zcu.instances.len);
    const s = w.s;
    const vir = env.vir;
    const a = payloadOf(vir, Inst.Assign, i);
    const lhs = vir.body(a.lhs);
    if (lhs.len == 0) return;
    var text: std.ArrayList(u8) = .empty;
    const upward = (try render(w, env, lhs[lhs.len - 1].toRef(), &text)) orelse return;
    const origin: u32 = @intCast(w.origins.items.len);
    try w.origins.append(s.arena, .{ .file = file, .src = i.toRef(), .text = text.items });
    const value = try env.bodyValue(a.rhs);
    const dot = std.mem.findScalarLast(u8, text.items, '.');
    const param = if (dot) |d| text.items[d + 1 ..] else text.items;
    var rel = if (dot) |d| text.items[0..d] else "";
    var anchor = index;
    if (upward and std.mem.startsWith(u8, rel, "$root.")) rel = rel["$root.".len..];
    // A head that names no ancestor names a child this module does not
    // declare: a §7.8.5 connect module insertion makes (`a__cm__d.p`).
    if (upward) if (upwardAnchor(w, index, rel[0 .. std.mem.findAny(u8, rel, ".[") orelse rel.len])) |up| {
        const head_end = std.mem.findAny(u8, rel, ".[") orelse rel.len;
        anchor = up;
        rel = if (head_end < rel.len and rel[head_end] == '.') rel[head_end + 1 ..] else rel[head_end..];
    };
    // IEEE 1364-2005 §12.8.1: a defparam of its own instance's parameter
    // whose value reads that parameter has no value to be in force first.
    if (anchor == index and rel.len == 0) if (env.named(param)) |target| if (try env.dependsOn(a.rhs, target)) {
        w.origins.items[origin].used = true;
        return s.fail(.E0907, file, i.toRef(), "`{s}` is applied before its instance's parameters take their values, and its value reads `{s}` itself (IEEE 1364-2005 12.8.1)", .{ text.items, param });
    };
    try place(w, anchor, rel, param, value, origin);
}

// ---- private ----

fn later(a: Dp, b: Dp) bool {
    assert(a.name.len != 0);
    assert(b.name.len != 0);
    if (a.file != b.file) return @backingInt(a.file) > @backingInt(b.file);
    return @backingInt(a.src) > @backingInt(b.src);
}

/// The instance an upward or absolute path's head names (IEEE 1364-2005
/// §12.5): the nearest ancestor, `from` included, whose module or instance
/// name it is, else a root of that module name.
fn upwardAnchor(w: *Walk, from: Instance.Index, head: []const u8) ?Instance.Index {
    assert(@backingInt(from) < w.zcu.instances.len);
    const zcu = w.zcu;
    const parents = zcu.instances.items(.parent);
    var it = from;
    while (it != .none) : (it = parents[@backingInt(it)]) {
        if (std.mem.eql(u8, moduleName(zcu, it), head)) return it;
        const n = zcu.intern_pool.stringToSlice(zcu.instances.items(.name)[@backingInt(it)]);
        const last = if (std.mem.findScalarLast(u8, n, '.')) |d| n[d + 1 ..] else n;
        if (std.mem.eql(u8, last, head)) return it;
    }
    for (0..zcu.instances.len) |k| if (parents[k] == .none and std.mem.eql(u8, moduleName(zcu, @fromBackingInt(@intCast(k))), head)) return @fromBackingInt(@intCast(k));
    return null;
}

/// Places a defparam: down the existing tree from `anchor` as far as `rel`
/// goes. A target that exists already takes the value late; else the
/// defparam waits at the deepest instance reached for the rest of `rel`.
fn place(w: *Walk, anchor: Instance.Index, rel: []const u8, param: []const u8, value: InternPool.Index, origin: u32) Allocator.Error!void {
    assert(origin < w.origins.items.len);
    assert(@backingInt(anchor) < w.zcu.instances.len);
    const zcu = w.zcu;
    var cur = anchor;
    var rest = rel;
    descend: while (rest.len != 0) {
        const names = zcu.instances.items(.name);
        const parents = zcu.instances.items(.parent);
        for (@backingInt(cur) + 1..zcu.instances.len) |k| {
            if (parents[k] != cur) continue;
            const n = zcu.intern_pool.stringToSlice(names[k]);
            if (!std.mem.startsWith(u8, rest, n)) continue;
            if (rest.len == n.len or rest[n.len] == '.') {
                cur = @fromBackingInt(@intCast(k));
                rest = if (rest.len == n.len) "" else rest[n.len + 1 ..];
                continue :descend;
            }
        }
        return w.rows.append(w.s.arena, .{ .anchor = cur, .rel = rest, .param = param, .value = value, .origin = origin });
    }
    try lateDefparam(w, cur, param, value, origin);
}

/// A defparam whose target `target` exists: recorded under its path, and
/// the walk runs again when the value is not the one the target took.
fn lateDefparam(w: *Walk, target: Instance.Index, param: []const u8, value: InternPool.Index, origin: u32) Allocator.Error!void {
    assert(origin < w.origins.items.len);
    assert(@backingInt(target) < w.zcu.instances.len);
    const s = w.s;
    const zcu = w.zcu;
    w.origins.items[origin].used = true;
    const o = w.origins.items[origin];
    const path = try std.fmt.allocPrint(s.arena, "{f}", .{zcu.fmtPath(target)});
    const gop = try w.late.getOrPut(s.arena, path);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    for (gop.value_ptr.items) |*l| if (std.mem.eql(u8, l.param, param)) {
        if (l.value == value) return;
        l.value = value;
        w.rerun = true;
        return;
    };
    try gop.value_ptr.append(s.arena, .{ .param = param, .value = value, .file = o.file, .src = o.src });
    w.rerun = true;
}

/// Renders a defparam's target (`g[1].u.p`) into `out`, each name declared
/// in this module under the scope prefix it was declared in. Returns whether
/// the head names nothing here (an upward or absolute path), or null when
/// the target is no path or an index does not fold.
fn render(w: *Walk, env: *Env, r: Inst.Ref, out: *std.ArrayList(u8)) Allocator.Error!?bool {
    assert(r != .none);
    const before = out.items.len;
    defer assert(out.items.len >= before);
    const arena = w.s.arena;
    const vir = env.vir;
    const i = r.toIndex() orelse return null;
    const data = vir.instructions.items(.data)[@backingInt(i)];
    switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .decl_ref => {
            const d = data.decl_tok.decl;
            const name = switch (vir.instructions.items(.tag)[@backingInt(d)]) {
                .instance => payloadOf(vir, Inst.Instance, d).name,
                .gen_block => payloadOf(vir, Inst.GenBlock, d).name,
                .param => payloadOf(vir, Inst.Param, d).name,
                else => return null, // else: a defparam's path names instances and scopes, and ends at a parameter
            };
            try out.appendSlice(arena, w.prefixes.get(d) orelse "");
            try out.appendSlice(arena, try walk.segment(arena, vir.string(name)));
            return false;
        },
        .str_ref => {
            try out.appendSlice(arena, vir.string(data.str_tok.start));
            return true;
        },
        .field => {
            const f = payloadOf(vir, Inst.Field, i);
            const up = (try render(w, env, f.operand, out)) orelse return null;
            try out.print(arena, ".{s}", .{vir.string(f.name)});
            return up;
        },
        .elem => {
            const b = payloadOf(vir, Inst.Bin, i);
            const up = (try render(w, env, b.lhs, out)) orelse return null;
            const k = ((try env.ref(b.rhs)) orelse return null).asIntExact() orelse return null;
            try out.print(arena, "[{d}]", .{k});
            return up;
        },
        else => return null, // else: no other expression is a hierarchical name
    }
}

fn moduleName(zcu: *const Zcu, i: Instance.Index) []const u8 {
    assert(@backingInt(i) < zcu.instances.len);
    const d = zcu.instances.items(.module)[@backingInt(i)];
    return zcu.fileVir(d.file).string(zcu.declRow(d).name);
}
