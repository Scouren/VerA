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
//! defparam is in force before the parameters it names take their values;
//! `defparam.zig` places them). Also the §9.18 hierarchical system
//! parameters (`hierValues`) and port binding (§6.2.2).
//! Cites: VAMS-2023 §6.2.2, §6.3.1, §6.3.2, §6.4, §6.6, §6.6.1-§6.6.3;
//! IEEE 1364-2005 §12.1.2, §12.1.3, §12.2, §12.4, §12.8.1.
//!
//! Contents:
//! - `pub const Given = struct`, `pub const Run = struct`, `pub const Pending = struct`, `pub const Walk = struct`
//! - `pub fn run(s: *Sema, roots: []const Zcu.Decl) Allocator.Error!defparams.Waiting`
//! - `pub fn applyGivens(s: *Sema, env: *Env, file: Zcu.File.Index, src: Inst.Ref, givens: []const Given, quiet: bool, module: Vir.String) Allocator.Error!void`
//! - `pub fn hierValues(s: *Sema, env: *Env, base: ?*const Zcu.Hier, givens: []const Given, dps: []const Dp, file: Zcu.File.Index, src: Inst.Ref) Allocator.Error!Zcu.Hier`
//! - `pub fn isOverridable(vir: *const Vir, p: Inst.Index) bool`
//! - `pub fn payloadOf(vir: *const Vir, comptime T: type, i: Inst.Index) T`
//! - `pub fn segment(arena: Allocator, name: []const u8) Allocator.Error![]const u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Sema = @import("../Sema.zig");
const Zcu = @import("../Zcu.zig");
const eval = @import("eval.zig");
const paramset = @import("paramset.zig");
const discipline = @import("discipline.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Env = eval.Env;
const Instance = Zcu.Instance;
const defparams = @import("defparam.zig");
const Dp = defparams.Dp;

/// A value an instance gives one of its target's parameters: named, or the
/// next in order (`name` empty); `value` is none for an empty `.name()`,
/// which keeps the default.
pub const Given = struct { name: InternPool.String, value: InternPool.Index };

/// A run of `Walk.givens`.
pub const Run = struct { start: u32, len: u32 };

/// A child waiting to be instantiated.
pub const Pending = struct {
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

/// The walk's state: the children waiting depth first, the values they are
/// given, the defparams placed so far, and the instance being walked.
pub const Walk = struct {
    s: *Sema,
    zcu: *Zcu,
    late: *std.StringArrayHashMapUnmanaged(std.ArrayList(defparams.Late)),
    pending: std.ArrayList(Pending) = .empty,
    givens: std.ArrayList(Given) = .empty,
    rows: std.ArrayList(defparams.Row) = .empty,
    origins: std.ArrayList(defparams.Origin) = .empty,
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

/// The most iterations one loop generate scheme unrolls.
const loop_max: u32 = 1 << 16;

/// The deepest instance tree; deeper is a runaway recursion (E0905).
const depth_max: u32 = 1 << 16;

/// Walks the instance trees under `roots` into `zcu.instances`, until no
/// late defparam changes a value; returns the defparams left waiting.
/// Asserts the table is empty.
pub fn run(s: *Sema, roots: []const Zcu.Decl) Allocator.Error!defparams.Waiting {
    const zcu = s.zcu;
    assert(zcu.instances.len == 0);
    const failed_before = zcu.failed.len;
    var late: std.StringArrayHashMapUnmanaged(std.ArrayList(defparams.Late)) = .empty;
    var pass: u32 = 0;
    while (true) : (pass += 1) {
        zcu.instances.shrinkRetainingCapacity(0);
        zcu.instance_map.clearRetainingCapacity();
        zcu.ports.shrinkRetainingCapacity(0);
        zcu.defparams.clearRetainingCapacity();
        zcu.defparam_sources.clearRetainingCapacity();
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
        if (w.rerun and pass > late.count() + 1) for (w.origins.items) |o| if (o.used)
            try s.fail(.E0907, o.file, o.src, "`{s}` keeps changing the value it reads (IEEE 1364-2005 §12.8.1)", .{o.text});
        if (!w.rerun or pass > late.count() + 1) {
            // Every root is a module, so each made an instance.
            assert(zcu.instances.len >= roots.len);
            return .{ .rows = w.rows.items, .origins = w.origins.items };
        }
    }
}

/// Gives each value of `givens` to its parameter in `env`: by name, or in
/// order to the overridable parameters (§6.3.2). Reports E0907 for a name
/// that is no overridable parameter and for too many ordered values, and
/// E0908 for a parameter given twice.
pub fn applyGivens(s: *Sema, env: *Env, file: Zcu.File.Index, src: Inst.Ref, givens: []const Given, quiet: bool, module: Vir.String) Allocator.Error!void {
    assert(env.positions.count() == env.values.items.len);
    defer assert(env.given.count() <= env.positions.count());
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
        try env.spelling.put(s.gpa, p, if (g.name == .empty) vir.string(payloadOf(vir, Inst.Param, p).name) else ip.stringToSlice(g.name));
    }
}

/// §6.3.2: a `parameter`, not a `localparam` or `specparam`, and not local
/// by IEEE 1364-2005 §4.10.1.
pub fn isOverridable(vir: *const Vir, p: Inst.Index) bool {
    assert(vir.instructions.items(.tag)[@backingInt(p)] == .param);
    const f = payloadOf(vir, Inst.Param, p).flags;
    return f.kind == .parameter and !f.local;
}

/// A name as one segment of a hierarchical path: as written, or, when it
/// is no simple identifier (§2.7.1: an escaped one such as `\a.b `), with
/// its backslash and terminating space, so a `.` in it is no separator.
pub fn segment(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    assert(name.len != 0);
    const simple = for (name, 0..) |c, k| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or (c == '$' and k != 0))) break false;
    } else !std.ascii.isDigit(name[0]);
    return if (simple) name else std.fmt.allocPrint(arena, "\\{s} ", .{name});
}

/// The payload of `pl_node` instruction `i`.
pub fn payloadOf(vir: *const Vir, comptime T: type, i: Inst.Index) T {
    assert(Inst.dataKind(vir.instructions.items(.tag)[@backingInt(i)]) == .pl_node);
    return vir.extraData(T, vir.instructions.items(.data)[@backingInt(i)].pl_node.payload_index);
}

/// §9.18 Table 9-29 one level's hierarchical system parameters: each value
/// specified by `givens` or `dps` (by its spelling or an aliasparam of it in
/// `env`, a defparam last) composed with `base`'s (the parent's, or a
/// paramset level's; null at a root): a sum for the positions, a product
/// for the flips and `$mfactor`, a sum modulo 360 for `$angle`. E0890 for a
/// specified value outside the kind's domain, E0908 for one kind given
/// under two spellings.
pub fn hierValues(s: *Sema, env: *Env, base: ?*const Zcu.Hier, givens: []const Given, dps: []const Dp, file: Zcu.File.Index, src: Inst.Ref) Allocator.Error!Zcu.Hier {
    assert(env.positions.count() == env.values.items.len);
    if (base) |b| assert(b.get(.mfactor) != .none);
    const zcu = s.zcu;
    var specified: std.EnumArray(Zcu.SystemParam, ?struct { value: InternPool.Index, spelling: []const u8 }) = .initFill(null);
    for (givens) |g| {
        if (g.name == .empty or g.value == .none) continue;
        const name = zcu.intern_pool.stringToSlice(g.name);
        const k = env.systemNamed(name) orelse continue;
        if (specified.get(k)) |before| if (!std.mem.eql(u8, before.spelling, name))
            try s.fail(.E0908, file, src, "`{s}` and its alias are both given a value", .{@tagName(k)});
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
        const up: ?f64 = if (base) |b| if (env.toConst(b.get(k))) |c| c.asReal() else null else k.initial();
        const own: ?f64 = if (specified.get(k)) |sp| if (env.toConst(sp.value)) |c| c.asReal() else null else k.initial();
        if (specified.get(k) != null) if (own) |v| if (!k.allows(v))
            try s.fail(.E0890, file, src, "`${s}` is {d}, and Table 9-29 allows only {s}", .{ @tagName(k), v, k.domain() });
        const v: ?f64 = if (own == null or up == null) null else switch (k) {
            .xposition, .yposition => up.? + own.?,
            .angle => @rem(up.? + own.?, 360.0),
            .hflip, .vflip, .mfactor => up.? * own.?,
        };
        out.set(k, if (v) |x| try env.intern(.{ .real = x }) else .undef);
    }
    return out;
}

// ---- private ----

/// Creates the instance `p` names, then walks its body for its children.
fn instantiate(w: *Walk, p: Pending) Allocator.Error!void {
    assert(p.name != .empty);
    if (p.parent != .none) assert(@backingInt(p.parent) < w.zcu.instances.len);
    const s = w.s;
    const zcu = w.zcu;
    const index: Instance.Index = @fromBackingInt(@intCast(zcu.instances.len));
    const dps = try defparams.reaching(w, p, index);
    const parent_hier: ?*const Zcu.Hier = if (p.parent == .none) null else &zcu.instances.items(.hier)[@backingInt(p.parent)];
    const picked = (try paramset.resolve(s, p.file, p.src, p.target, p.givens, &w.givens, dps, parent_hier)) orelse return;
    const vir = zcu.fileVir(picked.module.file);
    const row = zcu.declRow(picked.module);
    const m = vir.extraData(Inst.Module, vir.instructions.items(.data)[@backingInt(row.inst)].pl_node.payload_index);
    var env: Env = try .init(s.gpa, s.arena, &zcu.intern_pool, vir, &.{ m.params, m.body });
    defer env.deinit();
    try applyGivens(s, &env, p.file, p.src, w.givens.items[picked.givens.start..][0..picked.givens.len], p.quiet, row.name);
    // A paramset instance's defparams name the paramset's parameters.
    if (std.meta.eql(picked.paramset, Zcu.Decl.none)) try defparams.applyDefparams(s, &env, dps, row.name);
    for (dps) |dp| {
        const key: Zcu.Defparam = .{ .instance = index, .name = try zcu.intern_pool.getString(s.gpa, dp.name) };
        try zcu.defparams.put(s.gpa, key, dp.value);
        try zcu.defparam_sources.put(s.gpa, key, .{ .file = dp.file, .src = dp.src, .writer = try zcu.intern_pool.getString(s.gpa, dp.writer) });
    }
    // A paramset is a level of Table 9-29's composition: its statements
    // specify the module's values over the paramset level's.
    const base: ?*const Zcu.Hier = if (picked.base) |*b| b else if (p.parent == .none) null else &zcu.instances.items(.hier)[@backingInt(p.parent)];
    env.hier = try hierValues(s, &env, base, w.givens.items[picked.givens.start..][0..picked.givens.len], if (picked.base == null) dps else &.{}, p.file, p.src);
    for (env.positions.keys()) |param_inst| _ = try env.param(param_inst);
    try arraySizes(s, &env, p);
    const params = try zcu.intern_pool.get(s.gpa, .{ .aggregate = .{ .ty = .none, .elems = env.values.items } });
    const key: Instance.Key = .{ .module = picked.module, .params = params };
    if (try recursion(w, p, key)) |depth| {
        try s.fail(.E0905, p.file, p.src, "`{s}` instantiates itself with the same parameters ({d} levels deep)", .{ vir.string(row.name), depth });
        return;
    }
    if (zcu.isBuiltin(picked.module)) try portDisciplineAttrs(s, p);
    const ports = try bindPorts(s, p, vir, m, row.name);
    try zcu.instances.append(s.gpa, .{ .module = picked.module, .parent = p.parent, .name = p.name, .params = params, .paramset = picked.paramset, .paramset_params = picked.own, .src = p.src, .hier = env.hier, .ports = ports });
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

/// §3.4.4 "An array assigned to an instance of a module to override the
/// default value of an array parameter shall be of the exact size of the
/// parameter array", and one whose size an override changed "shall be
/// assigned an array of the new size" (E0921 for either). A value or range
/// that does not fold is not judged.
fn arraySizes(s: *Sema, env: *Env, p: Pending) Allocator.Error!void {
    assert(env.positions.count() == env.values.items.len);
    for (env.positions.keys(), env.values.items) |q, v| {
        const want = try env.arraySize(q) orelse continue;
        if (v == InternPool.Index.undef or v == .none) continue;
        const k = s.zcu.intern_pool.indexToKey(v);
        if (k != .aggregate) continue;
        const got = k.aggregate.elems.len;
        if (got == want) continue;
        const name = env.vir.string(payloadOf(env.vir, Inst.Param, q).name);
        if (env.given.contains(q))
            try s.fail(.E0921, p.file, p.src, "the array assigned to `{s}` has {d} elements, and its declared range has {d}", .{ name, got, want })
        else
            try s.fail(.E0921, p.file, p.src, "an override resized `{s}` to {d} elements, and no array of the new size was assigned to it (its default has {d})", .{ name, want, got });
    }
}

/// Annex E.3.2.1: "The value [of `port_discipline`] shall be of type
/// string and the value must be a valid discipline of domain continuous"
/// (E0358), judged on an instance of a shipped analog primitive only ("for
/// other modules ... it shall be ignored"). A valueless spec is §2.9's 1;
/// a value that does not fold is lowering's E0357.
fn portDisciplineAttrs(s: *Sema, p: Pending) Allocator.Error!void {
    const i = p.src.toIndex() orelse return;
    const vir = s.zcu.fileVir(p.file);
    assert(vir.instructions.items(.tag)[@backingInt(i)] == .instance);
    var env: Env = try .init(s.gpa, s.arena, &s.zcu.intern_pool, vir, &.{});
    defer env.deinit();
    for (vir.list(Inst.Attr, payloadOf(vir, Inst.Instance, i).attrs)) |a| {
        if (!std.mem.eql(u8, vir.string(a.name), "port_discipline")) continue;
        const c: eval.Const = if (a.value.len == 0) .{ .int = 1 } else (try env.body(a.value)) orelse continue;
        if (c != .str) {
            try s.fail(.E0358, p.file, p.src, "E.3.2.1: port_discipline requires a string naming a continuous discipline", .{});
            continue;
        }
        if (!s.zcu.disciplines.contains(try s.zcu.intern_pool.getString(s.gpa, c.str))) {
            try s.fail(.E0358, p.file, p.src, "E.3.2.1: port_discipline names an undeclared discipline `{s}`", .{c.str});
            continue;
        }
        if (try discipline.domainOf(s, c.str) != .continuous)
            try s.fail(.E0358, p.file, p.src, "E.3.2.1: port_discipline requires a continuous discipline; `{s}` is not one", .{c.str});
    }
}

/// §6.2.2 binds each port of module `m` (in `vir`) to the connection the
/// instance `p` gives it: by position, or by name when the list's first
/// entry names one (§6.5.5). Reports E0906 for a list longer than the
/// ports, a mix of the two spellings, a name that is no port and a port
/// named twice (IEEE 1364-2005 §12.3.6). A root binds nothing.
fn bindPorts(s: *Sema, p: Pending, vir: *const Vir, m: Inst.Module, module: Vir.String) Allocator.Error!Vir.List(Zcu.Port) {
    if (p.parent != .none) assert(p.src != .none);
    assert(m.ports.start + m.ports.len <= vir.extra.len);
    const zcu = s.zcu;
    const start: u32 = @intCast(zcu.ports.len);
    const i = p.src.toIndex() orelse return .{ .start = start, .len = 0 };
    const pvir = zcu.fileVir(p.file);
    const conns = pvir.list(Inst.Arg, payloadOf(pvir, Inst.Instance, i).conns);
    const formals = vir.body(m.ports);
    const named = conns.len != 0 and conns[0].name != .empty;
    if (!named and conns.len > formals.len)
        try s.fail(.E0906, p.file, p.src, "`{s}` declares {d} ports, and this instance connects {d}", .{ vir.string(module), formals.len, conns.len });
    for (conns, 0..) |c, k| {
        if (named != (c.name != .empty)) {
            try s.fail(.E0906, p.file, p.src, "a{s} connection in a list of {s} connections", .{ if (named) "n ordered" else " named", if (named) "named" else "ordered" });
            continue;
        }
        if (!named) continue;
        const n = pvir.string(c.name);
        if (portNamed(vir, formals, n) == null) {
            try s.fail(.E0906, p.file, p.src, "`{s}` is not a port of `{s}`", .{ n, vir.string(module) });
            continue;
        }
        for (conns[0..k]) |prev| if (prev.name != .empty and std.mem.eql(u8, pvir.string(prev.name), n)) {
            try s.fail(.E0906, p.file, p.src, "`{s}` is connected twice", .{n});
            break;
        };
    }
    try zcu.ports.ensureUnusedCapacity(s.gpa, formals.len);
    for (formals, 0..) |f, k| {
        const c: ?Inst.Arg = if (named) for (conns) |c| {
            if (c.name != .empty and std.mem.eql(u8, pvir.string(c.name), portName(vir, f))) break c;
        } else null else if (k < conns.len) conns[k] else null;
        const value = if (c) |a| pvir.body(a.value) else &.{};
        zcu.ports.appendAssumeCapacity(.{ .formal = f, .actual = if (value.len == 0) .none else value[value.len - 1].toRef() });
    }
    assert(zcu.ports.len == start + formals.len);
    return .{ .start = start, .len = @intCast(formals.len) };
}

/// A header port's external name: an ANSI `io`'s, or a `port`'s.
fn portName(vir: *const Vir, f: Inst.Index) []const u8 {
    assert(@backingInt(f) < vir.instructions.len);
    return vir.string(switch (vir.instructions.items(.tag)[@backingInt(f)]) {
        .io => payloadOf(vir, Inst.Io, f).name,
        .port => payloadOf(vir, Inst.Port, f).name,
        else => unreachable, // else: a module header holds only ports and port declarations
    });
}

fn portNamed(vir: *const Vir, formals: []const Inst.Index, name: []const u8) ?Inst.Index {
    assert(name.len != 0);
    for (formals) |f| if (std.mem.eql(u8, portName(vir, f), name)) return f;
    return null;
}

/// E0905's depth when `key` is already on the path from the root to `p`,
/// or when the tree is past `depth_max`; else null.
fn recursion(w: *Walk, p: Pending, key: Instance.Key) Allocator.Error!?u32 {
    assert(key.params != .none);
    if (p.parent != .none) assert(@backingInt(p.parent) < w.zcu.instances.len);
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

/// One scope's items: its instances (each array element in rising index
/// order), then its generate constructs, then its defparams.
fn items(w: *Walk, env: *Env, index: Instance.Index, file: Zcu.File.Index, body: Vir.Body, prefix: []const u8) Allocator.Error!void {
    assert(@backingInt(index) < w.zcu.instances.len);
    const kids_before = w.kids.items.len;
    defer assert(w.kids.items.len >= kids_before);
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
    for (insts) |i| if (tags[@backingInt(i)] == .defparam) try defparams.collect(w, env, index, file, i);
}

/// One module instance (or each element of an array of them) as a child.
fn instance(w: *Walk, env: *Env, index: Instance.Index, file: Zcu.File.Index, i: Inst.Index, prefix: []const u8) Allocator.Error!void {
    assert(env.vir.instructions.items(.tag)[@backingInt(i)] == .instance);
    assert(@backingInt(index) < w.zcu.instances.len);
    const s = w.s;
    const ip = &w.zcu.intern_pool;
    const vir = env.vir;
    const in = payloadOf(vir, Inst.Instance, i);
    if (in.flags.kind != .module) return;
    const target = try ip.getString(s.gpa, vir.string(in.target));
    if (w.zcu.modules.get(target)) |d| if (w.zcu.declRow(d).kind == .primitive) {
        // A.5.4: a named UDP instance parses as a module instance, so its
        // `#( … )` is A.2.2.3's `delay2`: at most two values, in order.
        const params = vir.list(Inst.Arg, in.params);
        // §2.6.2: a scale factor is a real literal's, and a digital delay
        // is no real.
        if (in.flags.scaled) try s.fail(.E0247, file, i.toRef(), "a scaled literal in `{s}`'s UDP delay", .{vir.string(in.target)});
        if (params.len > 2 or (params.len != 0 and params[0].name != .empty))
            try s.fail(.E0239, file, i.toRef(), "`{s} #(…) {s}`: {d} value(s)", .{ vir.string(in.target), vir.string(in.name), params.len })
        else
            // The instance computes nothing in an analog device (a notice
            // stage 5 owns, tests/differential/stages.zig).
            try s.fail(.W0252, file, i.toRef(), "`{s}` primitive", .{vir.string(in.target)});
        return;
    };
    try w.prefixes.put(s.arena, i, prefix);
    const start: u32 = @intCast(w.givens.items.len);
    for (vir.list(Inst.Arg, in.params)) |a| {
        // An empty `.name()` keeps the default but still names a parameter.
        const v = if (a.value.len == 0) InternPool.Index.none else try env.bodyValue(a.value);
        try w.givens.append(s.arena, .{ .name = try ip.getString(s.gpa, vir.string(a.name)), .value = v });
    }
    const givens: Run = .{ .start = start, .len = @intCast(w.givens.items.len - start) };
    const name = try segment(s.arena, vir.string(in.name));
    if (in.range.len == 0) {
        const n = try ip.getString(s.gpa, try std.fmt.allocPrint(s.arena, "{s}{s}", .{ prefix, name }));
        return w.kids.append(s.arena, .{ .parent = index, .file = file, .src = i.toRef(), .name = n, .target = try boundTarget(w, index, n, target), .givens = givens, .quiet = false });
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
        try w.kids.append(s.arena, .{ .parent = index, .file = file, .src = i.toRef(), .name = n, .target = try boundTarget(w, index, n, target), .givens = givens, .quiet = false });
    }
}

/// The cell a child named `name` of `parent` binds (`Sema.bound`).
fn boundTarget(w: *Walk, parent: Instance.Index, name: InternPool.String, target: InternPool.String) Allocator.Error!InternPool.String {
    assert(@backingInt(parent) < w.zcu.instances.len);
    assert(name != .empty);
    if (w.s.uses.count() == 0) return target;
    const path = try std.fmt.allocPrint(w.s.arena, "{f}.{s}", .{ w.zcu.fmtPath(parent), w.zcu.intern_pool.stringToSlice(name) });
    return w.s.bound(target, path);
}

/// §6.6.1 a loop generate scheme: the genvar from its first value while the
/// condition holds, one `name[value]` scope per iteration.
fn genFor(w: *Walk, env: *Env, index: Instance.Index, file: Zcu.File.Index, g: Inst.GenFor, prefix: []const u8) Allocator.Error!void {
    assert(@backingInt(index) < w.zcu.instances.len);
    assert(env.depth == 0);
    const vir = env.vir;
    const init = storeOf(vir, g.init) orelse return;
    const gv = declOf(vir, init.lhs) orelse return;
    var v = ((try env.ref(init.rhs)) orelse return).asIntExact() orelse return;
    const step = storeOf(vir, g.step) orelse return;
    defer _ = env.genvars.remove(gv);
    var n: u32 = 0;
    while (n < loop_max) : (n += 1) {
        try env.genvars.put(w.s.gpa, gv, v);
        assert(env.genvars.get(gv).? == v);
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
    assert(@backingInt(index) < w.zcu.instances.len);
    assert(env.depth == 0);
    const vir = env.vir;
    const operand = (try env.body(g.operand)) orelse return;
    var default: ?Vir.Body = null;
    for (vir.list(Inst.Arm, g.arms)) |arm| {
        if (arm.flags.default) default = arm.body;
        for (vir.list(Inst.Ref, arm.values)) |l| {
            const label = (try env.ref(l)) orelse continue;
            const eq = eval.Const.isTrue(@import("std_kernels").fold.binary(.eq, operand, label, null) orelse continue);
            if (eq) return items(w, env, index, file, arm.body, prefix);
        }
    }
    if (default) |b| try items(w, env, index, file, b, prefix);
}

/// A body's last instruction as a `store`, or null.
fn storeOf(vir: *const Vir, b: Vir.Body) ?Inst.Bin {
    assert(b.start + b.len <= vir.extra.len);
    const insts = vir.body(b);
    if (insts.len == 0) return null;
    const last = insts[insts.len - 1];
    if (vir.instructions.items(.tag)[@backingInt(last)] != .store) return null;
    return payloadOf(vir, Inst.Bin, last);
}

/// The declaration a `decl_ref` names, or null.
fn declOf(vir: *const Vir, r: Inst.Ref) ?Inst.Index {
    if (r.toIndex()) |i| assert(@backingInt(i) < vir.instructions.len);
    const i = r.toIndex() orelse return null;
    if (vir.instructions.items(.tag)[@backingInt(i)] != .decl_ref) return null;
    return vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl;
}
