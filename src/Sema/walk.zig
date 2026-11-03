//! The instance walk: the roots in, `Zcu.instances` out, depth first in
//! source order (each scope's instances, then its generate constructs),
//! on a heap stack so any finite depth is walked. Each instance folds its
//! module's parameters (`eval.Env`) with what it is given, in rising
//! precedence: the defaults, `#()` overrides (§6.3.2), paramset statements
//! (§6.4), defparams (§6.3.1); the folded tuple is its key. Its body is then
//! read under that key: generate schemes are evaluated and unrolled with
//! genvars as constants (§6.6, IEEE 1364-2005 §12.4), instance arrays
//! expanded lowest index first (§6.2.2), and its defparams placed.
//! A defparam whose target already exists when it is read (an upward or
//! absolute path, or the module's own parameter) is a late one: the walk
//! records it by path and runs again (IEEE 1364-2005 §12.8.1: every
//! defparam is in force before the parameters it names take their values).
//! Cites: VAMS-2023 §6.2.2, §6.3.1, §6.3.2, §6.4, §6.6, §6.6.1-§6.6.3;
//! IEEE 1364-2005 §12.1.2, §12.1.3, §12.2, §12.4, §12.8.1.
//!
//! Contents:
//! - `pub fn run(s: *Sema, roots: []const Zcu.Decl) Allocator.Error!void`
//! - `pub const Given = struct`, `pub const Run = struct`, `pub const Dp = struct`
//! - `pub fn applyDefparams(s: *Sema, env: *Env, dps: []const Dp, module: Vir.String) Allocator.Error!void`
//! - `pub fn applyGivens(s: *Sema, env: *Env, file: Zcu.File.Index, src: Inst.Ref, givens: []const Given, quiet: bool, module: Vir.String) Allocator.Error!void`
//! - `pub fn isOverridable(vir: *const Vir, p: Inst.Index) bool`
//! - `pub fn payloadOf(vir: *const Vir, comptime T: type, i: Inst.Index) T`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Sema = @import("../Sema.zig");
const Zcu = @import("../Zcu.zig");
const eval = @import("eval.zig");
const paramset = @import("paramset.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Env = eval.Env;
const Instance = Zcu.Instance;

/// A value an instance gives one of its target's parameters: named, or the
/// next in order (`name` empty); `value` is none for an empty `.name()`,
/// which keeps the default.
pub const Given = struct { name: InternPool.String, value: InternPool.Index };

/// A §6.3.1 defparam that reached the instance being made: the parameter
/// it names, its value and where it is written.
pub const Dp = struct { name: []const u8, value: InternPool.Index, file: Zcu.File.Index, src: Inst.Ref };

/// A run of `Walk.givens`.
pub const Run = struct { start: u32, len: u32 };

/// The most iterations one loop generate scheme unrolls.
const loop_max: u32 = 1 << 16;

/// The deepest instance tree; deeper is a runaway recursion (E0905).
const depth_max: u32 = 1 << 16;

/// A child waiting to be instantiated.
const Pending = struct {
    parent: Instance.Index,
    /// The file `src` is in.
    file: Zcu.File.Index,
    src: Inst.Ref,
    name: InternPool.String,
    target: InternPool.String,
    givens: Run,
    /// A root's givens are `--param`s: one naming nothing is no error.
    quiet: bool,
};

/// A defparam waiting for its target below `anchor`, `rel` the path to it.
const Row = struct { anchor: Instance.Index, rel: []const u8, param: []const u8, value: InternPool.Index, origin: u32 };

/// A defparam as written, for E0907 when it never reaches a parameter.
const Origin = struct { file: Zcu.File.Index, src: Inst.Ref, text: []const u8, used: bool = false };

/// A late defparam: its parameter, value and source, under its target's path.
const Late = struct { param: []const u8, value: InternPool.Index, file: Zcu.File.Index, src: Inst.Ref };

const Walk = struct {
    s: *Sema,
    zcu: *Zcu,
    late: *std.StringArrayHashMapUnmanaged(std.ArrayList(Late)),
    pending: std.ArrayList(Pending) = .empty,
    givens: std.ArrayList(Given) = .empty,
    rows: std.ArrayList(Row) = .empty,
    origins: std.ArrayList(Origin) = .empty,
    /// The children of the instance being walked, in source order.
    kids: std.ArrayList(Pending) = .empty,
    /// The scope prefix each instance and generate block of the instance
    /// being walked was declared under (a defparam's path names them).
    prefixes: std.AutoHashMapUnmanaged(Inst.Index, []const u8) = .empty,
    /// The defparams (`origins` rows) that reached the instance being made,
    /// a later one's loser included: each is used once the instance exists.
    matched: std.ArrayList(u32) = .empty,
    rerun: bool = false,
};

/// Walks the instance trees under `roots` into `zcu.instances`, until no
/// late defparam changes a value. Asserts the table is empty.
pub fn run(s: *Sema, roots: []const Zcu.Decl) Allocator.Error!void {
    const zcu = s.zcu;
    assert(zcu.instances.len == 0);
    const failed_before = zcu.failed.len;
    var late: std.StringArrayHashMapUnmanaged(std.ArrayList(Late)) = .empty;
    var pass: u32 = 0;
    while (true) : (pass += 1) {
        zcu.instances.shrinkRetainingCapacity(0);
        zcu.instance_map.clearRetainingCapacity();
        zcu.defparams.clearRetainingCapacity();
        zcu.failed.shrinkRetainingCapacity(failed_before);
        var w: Walk = .{ .s = s, .zcu = zcu, .late = &late };
        var k = roots.len;
        while (k > 0) {
            k -= 1;
            const name = try zcu.intern_pool.getString(s.gpa, zcu.fileVir(roots[k].file).string(zcu.declRow(roots[k]).name));
            const start: u32 = @intCast(w.givens.items.len);
            for (s.config.overrides) |o| try w.givens.append(s.arena, .{ .name = try zcu.intern_pool.getString(s.gpa, o.name), .value = o.value });
            try w.pending.append(s.arena, .{ .parent = .none, .file = roots[k].file, .src = .none, .name = name, .target = name, .givens = .{ .start = start, .len = @intCast(s.config.overrides.len) }, .quiet = true });
        }
        while (w.pending.pop()) |p| try instantiate(&w, p);
        // Each pass adds a late value or changes one; the values a cycle of
        // defparams feeds itself stop changing or the passes run out.
        if (!w.rerun or pass > late.count() + 1) {
            for (w.origins.items) |o| if (!o.used)
                try s.fail(.E0907, o.file, o.src, "`{s}` names no parameter of the elaborated design", .{o.text});
            break;
        }
    }
}

/// Gives each value of `givens` to its parameter in `env`: by name, or in
/// order to the overridable parameters (§6.3.2). Reports E0907 for a name
/// that is no overridable parameter and for too many ordered values, and
/// E0908 for a parameter given twice.
pub fn applyGivens(s: *Sema, env: *Env, file: Zcu.File.Index, src: Inst.Ref, givens: []const Given, quiet: bool, module: Vir.String) Allocator.Error!void {
    const vir = env.vir;
    const ip = &s.zcu.intern_pool;
    var ordered: u32 = 0;
    var overridable: u32 = 0;
    for (env.positions.keys()) |p| overridable += @intFromBool(isOverridable(vir, p));
    for (givens) |g| {
        const p = if (g.name == .empty) ordered: {
            defer ordered += 1;
            var n: u32 = 0;
            for (env.positions.keys()) |q| if (isOverridable(vir, q)) {
                if (n == ordered) break :ordered q;
                n += 1;
            };
            if (ordered == overridable) try s.fail(.E0907, file, src, "`{s}` declares {d} overridable parameters, and this instance overrides more", .{ vir.string(module), overridable });
            continue;
        } else named: {
            const name = ip.stringToSlice(g.name);
            // §9.18's hierarchical system parameters bind on any instance.
            if (env.systemNamed(name) != null) continue;
            if (env.named(name)) |q| if (isOverridable(vir, q)) break :named q;
            if (!quiet) try s.fail(.E0907, file, src, "`{s}` is not a parameter of `{s}`", .{ name, vir.string(module) });
            continue;
        };
        if (g.value == .none) continue;
        const gop = try env.given.getOrPut(s.gpa, p);
        if (gop.found_existing) try s.fail(.E0908, file, src, "`{s}` is given more than one value", .{vir.string(payloadOf(vir, Inst.Param, p).name)});
        gop.value_ptr.* = g.value;
    }
}

/// Gives each defparam's value to the parameter it names, over any `#()`
/// override; E0907 for a name that is no parameter of the module.
pub fn applyDefparams(s: *Sema, env: *Env, dps: []const Dp, module: Vir.String) Allocator.Error!void {
    for (dps) |dp| {
        if (env.systemNamed(dp.name) != null) continue;
        const q = env.named(dp.name) orelse {
            try s.fail(.E0907, dp.file, dp.src, "`{s}` is not a parameter of `{s}`", .{ dp.name, env.vir.string(module) });
            continue;
        };
        try env.given.put(s.gpa, q, dp.value);
    }
}

/// §6.3.2: a `parameter`, not a `localparam` or `specparam`, and not local
/// by IEEE 1364-2005 §4.10.1.
pub fn isOverridable(vir: *const Vir, p: Inst.Index) bool {
    const f = payloadOf(vir, Inst.Param, p).flags;
    return f.kind == .parameter and !f.local;
}

/// The payload of `pl_node` instruction `i`.
pub fn payloadOf(vir: *const Vir, comptime T: type, i: Inst.Index) T {
    return vir.extraData(T, vir.instructions.items(.data)[@backingInt(i)].pl_node.payload_index);
}

// ---- private ----

/// Creates the instance `p` names, then walks its body for its children.
fn instantiate(w: *Walk, p: Pending) Allocator.Error!void {
    const s = w.s;
    const zcu = w.zcu;
    const index: Instance.Index = @fromBackingInt(@intCast(zcu.instances.len));
    const dps = try reaching(w, p, index);
    const picked = (try paramset.resolve(s, p.file, p.src, p.target, p.givens, &w.givens, dps)) orelse return;
    const vir = zcu.fileVir(picked.module.file);
    const row = zcu.declRow(picked.module);
    const m = vir.extraData(Inst.Module, vir.instructions.items(.data)[@backingInt(row.inst)].pl_node.payload_index);
    var env: Env = try .init(s.gpa, s.arena, &zcu.intern_pool, vir, &.{ m.params, m.body });
    defer env.deinit();
    try applyGivens(s, &env, p.file, p.src, w.givens.items[picked.givens.start..][0..picked.givens.len], p.quiet, row.name);
    // A paramset instance's defparams name the paramset's parameters.
    if (std.meta.eql(picked.paramset, Zcu.Decl.none)) try applyDefparams(s, &env, dps, row.name);
    for (dps) |dp| try zcu.defparams.put(s.gpa, .{ .instance = index, .name = try zcu.intern_pool.getString(s.gpa, dp.name) }, dp.value);
    env.hier = try hierValues(s, &env, p, w.givens.items[p.givens.start..][0..p.givens.len], dps);
    for (env.positions.keys()) |param_inst| _ = try env.param(param_inst);
    const params = try zcu.intern_pool.get(s.gpa, .{ .aggregate = .{ .ty = .none, .elems = env.values.items } });
    const key: Instance.Key = .{ .module = picked.module, .params = params };
    if (try recursion(w, p, key)) |depth| {
        try s.fail(.E0905, p.file, p.src, "`{s}` instantiates itself with the same parameters ({d} levels deep)", .{ vir.string(row.name), depth });
        return;
    }
    try zcu.instances.append(s.gpa, .{ .module = picked.module, .parent = p.parent, .name = p.name, .params = params, .paramset = picked.paramset, .src = p.src, .hier = env.hier });
    assert(zcu.instances.len == @backingInt(index) + 1);
    const gop = try zcu.instance_map.getOrPut(s.gpa, key);
    if (!gop.found_existing) gop.value_ptr.* = index;
    // A defparam is used when its instance exists (E0907 otherwise).
    for (w.matched.items) |o| w.origins.items[o].used = true;

    w.kids.clearRetainingCapacity();
    w.prefixes.clearRetainingCapacity();
    try items(w, &env, index, picked.module.file, m.body, "");
    var k = w.kids.items.len;
    while (k > 0) {
        k -= 1;
        try w.pending.append(s.arena, w.kids.items[k]);
    }
}

/// §9.18 Table 9-29 the instance's hierarchical system parameters: each
/// value specified by a `#()` override or a defparam (by its spelling or an
/// aliasparam of it, a defparam last) composed with the parent's: a sum for
/// the positions, a product for the flips and `$mfactor`, a sum modulo 360
/// for `$angle`. E0890 for a specified value outside the kind's domain,
/// E0908 for one kind given under two spellings.
fn hierValues(s: *Sema, env: *Env, p: Pending, givens: []const Given, dps: []const Dp) Allocator.Error!Zcu.Hier {
    const zcu = s.zcu;
    var specified: std.EnumArray(Zcu.SystemParam, ?struct { value: InternPool.Index, spelling: []const u8 }) = .initFill(null);
    for (givens) |g| {
        if (g.name == .empty or g.value == .none) continue;
        const name = zcu.intern_pool.stringToSlice(g.name);
        const k = env.systemNamed(name) orelse continue;
        if (specified.get(k)) |before| if (!std.mem.eql(u8, before.spelling, name))
            try s.fail(.E0908, p.file, p.src, "`{s}` and its alias are both given a value", .{@tagName(k)});
        specified.set(k, .{ .value = g.value, .spelling = try s.arena.dupe(u8, name) });
    }
    for (dps) |dp| {
        const k = env.systemNamed(dp.name) orelse continue;
        if (specified.get(k)) |before| if (!std.mem.eql(u8, before.spelling, dp.name))
            try s.fail(.E0908, dp.file, dp.src, "`{s}` and its alias are both given a value", .{@tagName(k)});
        specified.set(k, .{ .value = dp.value, .spelling = dp.name });
    }
    var out: Zcu.Hier = undefined;
    for (std.enums.values(Zcu.SystemParam)) |k| {
        const parent: ?f64 = if (p.parent == .none) null else if (env.toConst(zcu.instances.items(.hier)[@backingInt(p.parent)].get(k))) |c| c.asReal() else null;
        const own: ?f64 = if (specified.get(k)) |sp| if (env.toConst(sp.value)) |c| c.asReal() else null else k.initial();
        if (specified.get(k) != null) if (own) |v| if (!k.allows(v))
            try s.fail(.E0890, p.file, p.src, "`${s}` is {d}, and Table 9-29 allows only {s}", .{ @tagName(k), v, k.domain() });
        const up = parent orelse k.initial();
        const v: ?f64 = if (own) |o| switch (k) {
            .xposition, .yposition => up + o,
            .angle => @rem(up + o, 360.0),
            .hflip, .vflip, .mfactor => up * o,
        } else null;
        const unfolded = (p.parent != .none and parent == null) or v == null;
        out.set(k, if (unfolded) .undef else try env.intern(.{ .real = v.? }));
    }
    return out;
}

/// E0905's depth when `key` is already on the path from the root to `p`,
/// or when the tree is past `depth_max`; else null.
fn recursion(w: *Walk, p: Pending, key: Instance.Key) Allocator.Error!?u32 {
    const parents = w.zcu.instances.items(.parent);
    const modules = w.zcu.instances.items(.module);
    const params = w.zcu.instances.items(.params);
    var depth: u32 = 1;
    var it = p.parent;
    while (it != .none) : (it = parents[@backingInt(it)]) {
        depth += 1;
        if (depth > depth_max) return depth;
        if (params[@backingInt(it)] == key.params and std.meta.eql(modules[@backingInt(it)], key.module)) return depth;
    }
    if (w.zcu.instances.len >= Zcu.instances_max) return depth;
    return null;
}

/// The defparams that reach the new instance `index` (`p`): those anchored
/// at its parent that name it, and the late ones recorded under its path;
/// of two for one parameter (alias spellings apart), the later in the source (IEEE 1364-2005
/// §12.2.1: files in order, then instructions, which AstGen numbers in
/// source order). Re-anchors at it those that name its descendants.
fn reaching(w: *Walk, p: Pending, index: Instance.Index) Allocator.Error![]const Dp {
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

fn keepLatest(s: *Sema, out: *std.ArrayList(Dp), dp: Dp) Allocator.Error!void {
    for (out.items) |*o| if (std.mem.eql(u8, o.name, dp.name)) {
        if (later(dp, o.*)) o.* = dp;
        return;
    };
    try out.append(s.arena, dp);
}

fn later(a: Dp, b: Dp) bool {
    if (a.file != b.file) return @backingInt(a.file) > @backingInt(b.file);
    return @backingInt(a.src) > @backingInt(b.src);
}

/// One scope's items: its instances (each array element in rising index
/// order), then its generate constructs, then its defparams.
fn items(w: *Walk, env: *Env, index: Instance.Index, file: Zcu.File.Index, body: Vir.Body, prefix: []const u8) Allocator.Error!void {
    const s = w.s;
    const vir = env.vir;
    const tags = vir.instructions.items(.tag);
    const insts = vir.body(body);
    for (insts) |i| if (tags[@backingInt(i)] == .instance) try instance(w, env, index, file, i, prefix);
    for (insts) |i| switch (tags[@backingInt(i)]) {
        .gen_if => {
            const g = payloadOf(vir, Inst.GenIf, i);
            // ponytail: a scheme that does not fold selects no arm; the
            // per-instance analysis reports the unfoldable condition.
            const c = (try env.body(g.cond)) orelse continue;
            try items(w, env, index, file, if (c.isTrue()) g.then else g.@"else", prefix);
        },
        .gen_case => try genCase(w, env, index, file, payloadOf(vir, Inst.GenCase, i), prefix),
        .gen_for => try genFor(w, env, index, file, payloadOf(vir, Inst.GenFor, i), prefix),
        .gen_block => {
            const b = payloadOf(vir, Inst.GenBlock, i);
            try w.prefixes.put(s.arena, i, prefix);
            try items(w, env, index, file, b.body, try std.fmt.allocPrint(s.arena, "{s}{s}.", .{ prefix, vir.string(b.name) }));
        },
        else => {}, // else: only a generate construct opens a scope
    };
    for (insts) |i| if (tags[@backingInt(i)] == .defparam) try defparam(w, env, index, file, i);
}

/// One module instance (or each element of an array of them) as a child.
fn instance(w: *Walk, env: *Env, index: Instance.Index, file: Zcu.File.Index, i: Inst.Index, prefix: []const u8) Allocator.Error!void {
    const s = w.s;
    const ip = &w.zcu.intern_pool;
    const vir = env.vir;
    const in = payloadOf(vir, Inst.Instance, i);
    if (in.flags.kind != .module) return;
    const target = try ip.getString(s.gpa, vir.string(in.target));
    if (w.zcu.modules.get(target)) |d| if (w.zcu.declRow(d).kind == .primitive) return;
    try w.prefixes.put(s.arena, i, prefix);
    const start: u32 = @intCast(w.givens.items.len);
    for (vir.list(Inst.Arg, in.params)) |a| {
        // An empty `.name()` keeps the default but still names a parameter.
        const v = if (a.value.len == 0) InternPool.Index.none else if (try env.body(a.value)) |c| try env.intern(c) else InternPool.Index.undef;
        try w.givens.append(s.arena, .{ .name = try ip.getString(s.gpa, vir.string(a.name)), .value = v });
    }
    const givens: Run = .{ .start = start, .len = @intCast(w.givens.items.len - start) };
    const name = vir.string(in.name);
    if (in.range.len == 0) {
        const n = try ip.getString(s.gpa, try std.fmt.allocPrint(s.arena, "{s}{s}", .{ prefix, name }));
        return w.kids.append(s.arena, .{ .parent = index, .file = file, .src = i.toRef(), .name = n, .target = target, .givens = givens, .quiet = false });
    }
    // §6.2.2 an array: one instance per element, lowest index first.
    const r = vir.body(in.range);
    const bin = payloadOf(vir, Inst.Bin, r[r.len - 1]);
    const msb = if (try env.ref(bin.lhs)) |c| c.asIntExact() else null;
    const lsb = if (try env.ref(bin.rhs)) |c| c.asIntExact() else null;
    if (msb == null or lsb == null) return s.fail(.E0909, file, i.toRef(), "`{s}`", .{name});
    var k: i128 = @min(msb.?, lsb.?);
    while (k <= @max(msb.?, lsb.?)) : (k += 1) {
        const n = try ip.getString(s.gpa, try std.fmt.allocPrint(s.arena, "{s}{s}[{d}]", .{ prefix, name, k }));
        try w.kids.append(s.arena, .{ .parent = index, .file = file, .src = i.toRef(), .name = n, .target = target, .givens = givens, .quiet = false });
    }
}

/// §6.6.1 a loop generate scheme: the genvar from its first value while the
/// condition holds, one `name[value]` scope per iteration.
fn genFor(w: *Walk, env: *Env, index: Instance.Index, file: Zcu.File.Index, g: Inst.GenFor, prefix: []const u8) Allocator.Error!void {
    const vir = env.vir;
    const init = storeOf(vir, g.init) orelse return;
    const gv = declOf(vir, init.lhs) orelse return;
    var v = ((try env.ref(init.rhs)) orelse return).asIntExact() orelse return;
    const step = storeOf(vir, g.step) orelse return;
    defer _ = env.genvars.remove(gv);
    var n: u32 = 0;
    while (n < loop_max) : (n += 1) {
        try env.genvars.put(w.s.gpa, gv, v);
        const c = (try env.body(g.cond)) orelse return;
        if (!c.isTrue()) return;
        for (vir.body(g.body)) |b| {
            if (vir.instructions.items(.tag)[@backingInt(b)] != .gen_block) continue;
            const blk = payloadOf(vir, Inst.GenBlock, b);
            try w.prefixes.put(w.s.arena, b, prefix);
            try items(w, env, index, file, blk.body, try std.fmt.allocPrint(w.s.arena, "{s}{s}[{d}].", .{ prefix, vir.string(blk.name), v }));
        }
        v = ((try env.ref(step.rhs)) orelse return).asIntExact() orelse return;
    }
    // ponytail: past `loop_max` iterations the scheme is cut short; the
    // per-instance analysis judges termination (§6.6.1).
}

/// §6.6 a case generate scheme: the first arm a label of which equals the
/// operand, else the default arm.
fn genCase(w: *Walk, env: *Env, index: Instance.Index, file: Zcu.File.Index, g: Inst.GenCase, prefix: []const u8) Allocator.Error!void {
    const vir = env.vir;
    const operand = (try env.body(g.operand)) orelse return;
    var default: ?Vir.Body = null;
    for (vir.list(Inst.Arm, g.arms)) |arm| {
        if (arm.flags.default) default = arm.body;
        for (vir.list(Inst.Ref, arm.values)) |l| {
            const label = (try env.ref(l)) orelse continue;
            const eq = eval.Const.isTrue(@import("kernels").fold.binary(.eq, operand, label, null) orelse continue);
            if (eq) return items(w, env, index, file, arm.body, prefix);
        }
    }
    if (default) |b| try items(w, env, index, file, b, prefix);
}

/// §6.3.1 one defparam: its value folded here, its target placed below the
/// instance (a path through this module's scopes) or, for a path whose head
/// names no declaration here, below the ancestor or root it names.
fn defparam(w: *Walk, env: *Env, index: Instance.Index, file: Zcu.File.Index, i: Inst.Index) Allocator.Error!void {
    const s = w.s;
    const vir = env.vir;
    const a = payloadOf(vir, Inst.Assign, i);
    const lhs = vir.body(a.lhs);
    if (lhs.len == 0) return;
    var text: std.ArrayList(u8) = .empty;
    const upward = (try render(w, env, lhs[lhs.len - 1].toRef(), &text)) orelse return;
    const origin: u32 = @intCast(w.origins.items.len);
    try w.origins.append(s.arena, .{ .file = file, .src = i.toRef(), .text = text.items });
    const value = if (try env.body(a.rhs)) |c| try env.intern(c) else InternPool.Index.undef;
    const dot = std.mem.findScalarLast(u8, text.items, '.');
    const param = if (dot) |d| text.items[d + 1 ..] else text.items;
    var rel = if (dot) |d| text.items[0..d] else "";
    var anchor = index;
    if (upward and std.mem.startsWith(u8, rel, "$root.")) rel = rel["$root.".len..];
    if (upward) {
        const head_end = std.mem.findAny(u8, rel, ".[") orelse rel.len;
        anchor = upwardAnchor(w, index, rel[0..head_end]) orelse return;
        rel = if (head_end < rel.len and rel[head_end] == '.') rel[head_end + 1 ..] else rel[head_end..];
    }
    try place(w, anchor, rel, param, value, origin);
}

/// The instance an upward or absolute path's head names (IEEE 1364-2005
/// §12.5): the nearest ancestor, `from` included, whose module or instance
/// name it is, else a root of that module name.
fn upwardAnchor(w: *Walk, from: Instance.Index, head: []const u8) ?Instance.Index {
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
            try out.appendSlice(arena, vir.string(name));
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
    const d = zcu.instances.items(.module)[@backingInt(i)];
    return zcu.fileVir(d.file).string(zcu.declRow(d).name);
}

/// A body's last instruction as a `store`, or null.
fn storeOf(vir: *const Vir, b: Vir.Body) ?Inst.Bin {
    const insts = vir.body(b);
    if (insts.len == 0) return null;
    const last = insts[insts.len - 1];
    if (vir.instructions.items(.tag)[@backingInt(last)] != .store) return null;
    return payloadOf(vir, Inst.Bin, last);
}

/// The declaration a `decl_ref` names, or null.
fn declOf(vir: *const Vir, r: Inst.Ref) ?Inst.Index {
    const i = r.toIndex() orelse return null;
    if (vir.instructions.items(.tag)[@backingInt(i)] != .decl_ref) return null;
    return vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl;
}
