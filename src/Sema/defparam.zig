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
//! - `pub const Dp`, `pub const Source`, `pub const Waiting`, `pub const Row`, `pub const Origin`, `pub const Late`
//! - `pub fn reportUnused(s: *Sema, waiting: Waiting) Allocator.Error!void`
//! - `pub fn waitingFor(s: *Sema, waiting: Waiting, parent: Instance.Index, name: []const u8) Allocator.Error![]const Dp`
//! - `pub fn applyDefparams(s: *Sema, env: *Env, dps: []const Dp, module: Vir.String) Allocator.Error!void`
//! - `pub fn reaching(w: *Walk, p: Pending, index: Instance.Index) Allocator.Error![]const Dp`
//! - `pub fn keepLatest(s: *Sema, out: *std.ArrayList(Dp), dp: Dp) Allocator.Error!void`
//! - `pub fn collect(w: *Walk, env: *Env, index: Instance.Index, file: Zcu.File.Index, i: Inst.Index, prefix: []const u8) Allocator.Error!void`
//! - `pub fn ownTargets(w: *Walk, env: *Env, index: Instance.Index, insts: []const Inst.Index) Allocator.Error!void`

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
/// it names, its value and where it is written (`writer_instance`: the
/// instance whose scope the right-hand side resolves in, for re-deriving
/// it, `derive.zig`'s W12).
pub const Dp = struct { name: []const u8, value: InternPool.Index, file: Zcu.File.Index, src: Inst.Ref, writer: []const u8, writer_instance: Instance.Index };

/// The defparams the walk left waiting below an instance (one that names a
/// connect module §7.8 inserts after the walk, or nothing), and every
/// defparam as written.
pub const Waiting = struct { rows: []const Row, origins: []Origin };

/// A defparam waiting for its target below `anchor`, `rel` the path to it.
pub const Row = struct { anchor: Instance.Index, rel: []const u8, param: []const u8, value: InternPool.Index, origin: u32 };

/// A defparam's place in the source, which names it across passes.
pub const Source = struct { file: Zcu.File.Index, src: Inst.Ref };

/// A defparam as written, for E0907 when it never reaches a parameter.
pub const Origin = struct { file: Zcu.File.Index, src: Inst.Ref, text: []const u8, writer: []const u8, writer_instance: Instance.Index, used: bool = false };

/// A late defparam: its parameter, value and source, under its target's path.
pub const Late = struct { param: []const u8, value: InternPool.Index, file: Zcu.File.Index, src: Inst.Ref, writer: []const u8, writer_instance: Instance.Index };

/// E0907 for every defparam that reached no instance.
pub fn reportUnused(s: *Sema, waiting: Waiting) Allocator.Error!void {
    for (waiting.rows) |r| assert(r.origin < waiting.origins.len);
    for (waiting.origins) |o| if (!o.used) {
        // Named from the root's scope: the writer's path below the root.
        const below = if (std.mem.findScalar(u8, o.writer, '.')) |d| o.writer[d + 1 ..] else "";
        try s.failRule(.{ .part = .target }, .E0907, o.file, o.src, "`{s}{s}{s}` names no parameter of the elaborated design", .{ below, if (below.len == 0) "" else ".", o.text });
    };
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
        try keepLatest(s, &out, .{ .name = r.param, .value = r.value, .file = o.file, .src = o.src, .writer = o.writer, .writer_instance = o.writer_instance });
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
            try s.failRule(.{ .rule = .defparam_unknown, .name = dp.name, .part = .target }, .E0907, dp.file, dp.src, "`{s}` is not a parameter of `{s}`", .{ dp.name, env.vir.string(module) });
            continue;
        };
        // §3.4.7: a parameter and its alias are not both given a value.
        if (env.spelling.get(q)) |before| if (!std.mem.eql(u8, before, dp.name))
            try s.failRule(.{ .part = .target }, .E0908, dp.file, dp.src, "`{s}` and its alias are both given a value", .{env.vir.string(payloadOf(env.vir, Inst.Param, q).name)});
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
            // A `$` name no §9.18 system parameter spells reaches nothing:
            // it is reported unused, as the old elaborator named it.
            const unknown_system = r.param[0] == '$' and Zcu.SystemParam.fromName(r.param) == null;
            if (std.mem.eql(u8, r.rel, name) and !unknown_system) {
                const o = w.origins.items[r.origin];
                try w.matched.append(s.arena, r.origin);
                try keepLatest(s, &out, .{ .name = r.param, .value = r.value, .file = o.file, .src = o.src, .writer = o.writer, .writer_instance = o.writer_instance });
            } else if (r.rel.len > name.len and std.mem.startsWith(u8, r.rel, name) and r.rel[name.len] == '.') {
                try w.rows.append(s.arena, .{ .anchor = index, .rel = r.rel[name.len + 1 ..], .param = r.param, .value = r.value, .origin = r.origin });
            }
        }
    }
    if (w.late.count() == 0) return out.items;
    const path = if (p.parent == .none) name else try std.fmt.allocPrint(s.arena, "{f}.{s}", .{ w.zcu.fmtPath(p.parent), name });
    if (w.late.get(path)) |list| for (list.items) |l|
        try keepLatest(s, &out, .{ .name = l.param, .value = l.value, .file = l.file, .src = l.src, .writer = l.writer, .writer_instance = l.writer_instance });
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
/// `prefix`: the generate-block scopes the statement itself is written
/// under, `items`'s own (IEEE 1364-2005 §12.2.1: the scopes a generate
/// block or array element restricts a defparam written inside it to).
pub fn collect(w: *Walk, env: *Env, index: Instance.Index, file: Zcu.File.Index, i: Inst.Index, prefix: []const u8) Allocator.Error!void {
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
    try w.origins.append(s.arena, .{ .file = file, .src = i.toRef(), .text = text.items, .writer = try std.fmt.allocPrint(s.arena, "{f}", .{w.zcu.fmtPath(index)}), .writer_instance = index });
    const value = try env.bodyValue(a.rhs);
    const dot = std.mem.findScalarLast(u8, text.items, '.');
    const param = if (dot) |d| text.items[d + 1 ..] else text.items;
    var rel = if (dot) |d| text.items[0..d] else "";
    var anchor = index;
    const key: Source = .{ .file = file, .src = i.toRef() };
    var up = upward;
    if (s.config.ieee1364 and !up and rel.len != 0) if (headBlock(vir, lhs[lhs.len - 1].toRef())) |b| {
        const head = rel[0 .. std.mem.findAny(u8, rel, ".[") orelse rel.len];
        // IEEE 1364-2005 §12.8.2: a head that names a generate block not
        // instantiated now resolves as an upward name; once the block is,
        // the name resolves differently, which is an error.
        if (!w.prefixes.contains(b)) {
            if (upwardAnchor(w, index, head) != null) {
                up = true;
                try w.went_up.put(s.arena, key, {});
            }
        } else if (w.went_up.contains(key)) {
            w.origins.items[origin].used = true;
            return s.failRule(.{ .rule = .defparam_early, .part = .target }, .E1100, file, i.toRef(), "this defparam's hierarchical name was resolved before the hierarchy was complete and would resolve differently once it is (IEEE 1364-2005 12.8.2)", .{});
        }
    };
    if (s.config.ieee1364 and up and rel.len == 0 and env.named(param) == null and env.systemNamed(param) == null) {
        // §12.2.1 a one-name defparam that no declaration here names.
        w.origins.items[origin].used = true;
        return s.failRule(.{ .rule = .defparam_nothing, .name = text.items, .part = .target }, .E0901, file, i.toRef(), "§12.2.1: this defparam's hierarchical name `{s}` names nothing in the design", .{text.items});
    }
    if (up and std.mem.startsWith(u8, rel, "$root.")) rel = rel["$root.".len..];
    // A head that names no ancestor names a child this module does not
    // declare: a §7.8.5 connect module insertion makes (`a__cm__d.p`).
    if (up) if (upwardAnchor(w, index, rel[0 .. std.mem.findAny(u8, rel, ".[") orelse rel.len])) |at| {
        const head_end = std.mem.findAny(u8, rel, ".[") orelse rel.len;
        anchor = at;
        rel = if (head_end < rel.len and rel[head_end] == '.') rel[head_end + 1 ..] else rel[head_end..];
    };
    if (s.config.ieee1364) if (try outsideScope(w, index, prefix, anchor, rel)) |element| {
        // §12.2.1 "a defparam statement in a hierarchy in or under ... a
        // generate block instance or an array of instances ... shall not
        // change a parameter value outside that hierarchy".
        w.origins.items[origin].used = true;
        return s.failRule(.{ .rule = .defparam_outside, .name = element, .part = .target }, .E1100, file, i.toRef(), "a defparam inside `{s}` cannot change a parameter outside the generate block instance or array element it is in (IEEE 1364-2005 12.2.1)", .{element});
    };
    // IEEE 1364-2005 §12.8.1: a defparam's value, with every self-targeting
    // defparam of the writing instance standing for its parameter's default
    // instead of its own (`w.own`, gathered by `ownTargets`), reaches a
    // cycle through the undeclared (not yet in force) parameters it reads,
    // directly or through their own replacements: no replacement ends it,
    // so this defparam's value is never in force. Every defparam whose
    // value folds into the same cycle reports it (not only a self-target):
    // `w.own`'s own entries are read the same way `a.rhs` is.
    if (w.own.items.len != 0) if (try env.cycleOf(a.rhs, w.own.items)) |cyc| {
        w.origins.items[origin].used = true;
        const below = try std.fmt.allocPrint(s.arena, "{f}", .{w.zcu.fmtPathBelowRoot(anchor)});
        const flat = flat: {
            if (rel.len == 0) break :flat if (below.len == 0) param else try std.fmt.allocPrint(s.arena, "{s}.{s}", .{ below, param });
            const path = if (below.len == 0) rel else try std.fmt.allocPrint(s.arena, "{s}.{s}", .{ below, rel });
            break :flat try std.fmt.allocPrint(s.arena, "{s}.{s}", .{ path, param });
        };
        var names: std.ArrayList(u8) = .empty;
        for (cyc, 0..) |c, k| {
            if (k != 0) try names.appendSlice(s.arena, " → ");
            const nm = vir.string(payloadOf(vir, Inst.Param, c).name);
            if (below.len == 0) try names.print(s.arena, "`{s}`", .{nm}) else try names.print(s.arena, "`{s}.{s}`", .{ below, nm });
        }
        return s.failRule(.{ .part = .target }, .E0907, file, i.toRef(), "`{s}` is applied before its declaring instance is elaborated, and its value reads the cycle {s}, which no replacement ends (IEEE 1364-2005 12.8.1)", .{ flat, names.items });
    };
    try place(w, anchor, rel, param, value, origin);
}

/// The defparams of `insts` that target a parameter of `index` itself
/// (rendered text with no path, or one upward segment that resolves to
/// `index`), appended to `w.own` as `index`'s own-targeting defparams for
/// `cycleOf` (IEEE 1364-2005 §12.8.1). Called before `insts`' defparams are
/// collected, for every body of the instance being made (`items`); cleared
/// with `w.prefixes` per instance.
/// ponytail: a defparam in a sibling generate block is not `index`'s own
/// (a different body's `insts`); each call sees only its own.
pub fn ownTargets(w: *Walk, env: *Env, index: Instance.Index, insts: []const Inst.Index) Allocator.Error!void {
    assert(@backingInt(index) < w.zcu.instances.len);
    const s = w.s;
    const vir = env.vir;
    const tags = vir.instructions.items(.tag);
    for (insts) |i| {
        if (tags[@backingInt(i)] != .defparam) continue;
        const a = payloadOf(vir, Inst.Assign, i);
        const lhs = vir.body(a.lhs);
        if (lhs.len == 0) continue;
        var text: std.ArrayList(u8) = .empty;
        const upward = (try render(w, env, lhs[lhs.len - 1].toRef(), &text)) orelse continue;
        const dot = std.mem.findScalarLast(u8, text.items, '.');
        const param_name = if (dot) |d| text.items[d + 1 ..] else text.items;
        const rel = if (dot) |d| text.items[0..d] else "";
        const self = if (rel.len == 0)
            !upward
        else
            std.mem.findAny(u8, rel, ".[") == null and upwardAnchor(w, index, rel) == index;
        if (!self) continue;
        const target = env.named(param_name) orelse continue;
        try w.own.append(s.arena, .{ .param = target, .value = a.rhs });
    }
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
    try gop.value_ptr.append(s.arena, .{ .param = param, .value = value, .file = o.file, .src = o.src, .writer = o.writer, .writer_instance = o.writer_instance });
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

/// The generate block a defparam target's head names (`blk` of
/// `blk.u.p`), or null when it names something else.
fn headBlock(vir: *const Vir, r: Inst.Ref) ?Inst.Index {
    var at = r;
    // Bounded by the target's depth: each turn moves to an operand.
    for (0..1 << 12) |_| {
        const i = at.toIndex() orelse return null;
        switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            .field => at = payloadOf(vir, Inst.Field, i).operand,
            .elem => at = payloadOf(vir, Inst.Bin, i).lhs,
            .decl_ref => {
                const d = vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl;
                return if (vir.instructions.items(.tag)[@backingInt(d)] == .gen_block) d else null;
            },
            else => return null, // else: no other expression is a hierarchical name
        }
    }
    return null;
}

/// The generate-block or array-of-instances scope (IEEE 1364-2005 §12.2.1)
/// the defparam's resolved target (`anchor`, `rel`) falls outside of; null
/// when every such scope contains it. The scopes checked, innermost first:
/// each segment of `prefix` (the statement's own generate nesting inside
/// `index`), then each array-element or generate-block segment of
/// `index`'s own ancestors' names (`Zcu.Instance.name`'s doc comment: a
/// root's path below the parent, generate scopes and index included),
/// outermost last.
///
/// A scope `anchor` could not have left (no `Zcu.instances` row is a
/// generate scope, so an upward name across one is never found by
/// `upwardAnchor`, and a same-named sibling array element is not either:
/// `anchor` stays `index` or one of its own descendants) is judged by name
/// alone, the written head of `rel` against the scope's own base name,
/// ignoring which element or iteration it names: real path containment
/// would otherwise always trivially hold, since the target is built as
/// `anchor`'s own path plus `rel`. ponytail: this misses a same-named
/// sibling whose defparam targets *itself* by writing its own index back
/// (`u[1]`'s own defparam naming `u[1]`): accepted for every array element
/// too, so not a regression here; the generate-block form resolves
/// locally (`up` is false) and is judged by containment, precisely.
/// Every other scope is judged by containment: `rel`'s head is split only
/// on a literal `.`, so an escaped name holding one (§3.7.1) is kept as
/// its own `\name ` segment by `segment` upstream, and this does not
/// split inside it either.
/// Asserts the walk stays bounded by `Zcu.instances_max`.
fn outsideScope(w: *Walk, index: Instance.Index, prefix: []const u8, anchor: Instance.Index, rel: []const u8) Allocator.Error!?[]const u8 {
    assert(@backingInt(index) < w.zcu.instances.len);
    assert(@backingInt(anchor) < w.zcu.instances.len);
    const zcu = w.zcu;
    const arena = w.s.arena;
    const target = if (rel.len == 0)
        try std.fmt.allocPrint(arena, "{f}", .{zcu.fmtPath(anchor)})
    else
        try std.fmt.allocPrint(arena, "{f}.{s}", .{ zcu.fmtPath(anchor), rel });
    const head = rel[0 .. std.mem.findAny(u8, rel, ".[") orelse rel.len];
    var depth: u32 = 0;

    // The generate blocks the statement is nested in, innermost (last)
    // first: `index`'s own path plus a prefix segment never equals
    // `anchor`'s, so containment here is never the trivial-pass case below.
    var end = prefix.len;
    while (end > 0) {
        depth += 1;
        assert(depth < Zcu.instances_max);
        assert(prefix[end - 1] == '.');
        end -= 1;
        const start = if (std.mem.lastIndexOfScalar(u8, prefix[0..end], '.')) |d| d + 1 else 0;
        const scope = try std.fmt.allocPrint(arena, "{f}.{s}", .{ zcu.fmtPath(index), prefix[0..end] });
        if (!contains(target, scope)) return try arena.dupe(u8, prefix[start..end]);
        end = start;
    }

    // The ancestors' own generate-block and array-element scopes,
    // innermost first.
    var it = index;
    while (true) {
        const parent = zcu.instances.items(.parent)[@backingInt(it)];
        if (parent == .none) break;
        const stuck = isDescendantOrSelf(zcu, anchor, it);
        const name = zcu.intern_pool.stringToSlice(zcu.instances.items(.name)[@backingInt(it)]);
        var seg_end = name.len;
        var is_last = true;
        while (seg_end > 0) {
            depth += 1;
            assert(depth < Zcu.instances_max);
            const seg_start = if (std.mem.lastIndexOfScalar(u8, name[0..seg_end], '.')) |d| d + 1 else 0;
            const seg = name[seg_start..seg_end];
            const last = is_last;
            is_last = false;
            const this_end = seg_end;
            seg_end = seg_start;
            if (last and seg[seg.len - 1] != ']') continue; // else: an ordinary submodule name, no scope boundary here
            if (stuck) {
                if (rel.len != 0 and std.mem.eql(u8, seg[0 .. std.mem.indexOfScalar(u8, seg, '[') orelse seg.len], head))
                    return try arena.dupe(u8, seg);
            } else {
                const scope = try std.fmt.allocPrint(arena, "{f}.{s}", .{ zcu.fmtPath(parent), name[0..this_end] });
                if (!contains(target, scope)) return try arena.dupe(u8, seg);
            }
        }
        it = parent;
    }
    return null;
}

/// Whether `target` is `scope` itself or a name below it (`scope` followed
/// by `.`).
fn contains(target: []const u8, scope: []const u8) bool {
    if (std.mem.eql(u8, target, scope)) return true;
    return target.len > scope.len and std.mem.startsWith(u8, target, scope) and target[scope.len] == '.';
}

/// Whether `candidate` is `ancestor` or one of its descendants.
fn isDescendantOrSelf(zcu: *const Zcu, candidate: Instance.Index, ancestor: Instance.Index) bool {
    assert(@backingInt(candidate) < zcu.instances.len);
    assert(@backingInt(ancestor) < zcu.instances.len);
    var it = candidate;
    var depth: u32 = 0;
    while (true) {
        if (it == ancestor) return true;
        depth += 1;
        assert(depth < Zcu.instances_max);
        const p = zcu.instances.items(.parent)[@backingInt(it)];
        if (p == .none) return false;
        it = p;
    }
}

fn moduleName(zcu: *const Zcu, i: Instance.Index) []const u8 {
    assert(@backingInt(i) < zcu.instances.len);
    const d = zcu.instances.items(.module)[@backingInt(i)];
    return zcu.fileVir(d.file).string(zcu.declRow(d).name);
}
