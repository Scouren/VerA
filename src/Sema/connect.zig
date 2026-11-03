//! Annex F discipline resolution and §7.8 connect-module insertion, over
//! the finished instance table: `Zcu.instances` and `Zcu.ports` in; the
//! resolved discipline of every port-connected net (`Zcu.net_discipline`),
//! one connect-module instance per bridge and its `Zcu.inserts` rows out,
//! the table put back in depth-first preorder. Running after the walk is
//! §7.8.4's "complete hierarchical examination of each signal": every
//! segment below a port is known before the port is judged, with no dry
//! walk.
//! Resolution is F.2's basic mode, bottom up: a net declared with a
//! discipline has it; an undeclared one takes its child segments'
//! disciplines, one if they agree, else the `resolveto` statement naming
//! them all, else the continuous one (§7.4.4.1). A port is mixed when its
//! upper and lower connections resolve to different domains; it matches
//! exactly one connect statement (§7.8.4; E0922 for several, E0927 for
//! none), whose module is instantiated in the upper connection's module,
//! one per signal, statement and bottom discipline when merged (§7.8.3, the
//! default, and always for an analog lower connection), else one per port,
//! named by §7.8.5.
//! Cites: VAMS-2023 §3.6.2.2, §3.11.1, §7.4.4.1, §7.6 (Table 7-2), §7.7.1,
//! §7.7.2, §7.7.3, §7.8.2-§7.8.5, Annex F.2.
//!
//! Contents:
//! - `pub fn run(s: *Sema, waiting: defparam.Waiting) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Sema = @import("../Sema.zig");
const Zcu = @import("../Zcu.zig");
const eval = @import("eval.zig");
const walk = @import("walk.zig");
const discipline = @import("discipline.zig");
const defparam = @import("defparam.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Instance = Zcu.Instance;
const String = InternPool.String;
const payloadOf = walk.payloadOf;

/// One side of a connect statement read as Table 7-2's pair.
const Side = struct { port: String, discipline: []const u8, dir: Inst.Direction };

/// One usable connect statement.
const Rule = struct { module: Zcu.Decl, file: Zcu.File.Index, src: Inst.Index, cont: Side, disc: Side, split: bool, params: Vir.List(Inst.Arg) };

/// A net's declaration in a module: its discipline (empty when none) and,
/// for a port, its direction.
const Net = struct { discipline: []const u8, dir: Inst.Direction };

/// A mixed port one statement matched.
const Hit = struct { parent: Instance.Index, child: Instance.Index, port: Inst.Index, port_name: String, sig: String, bottom: []const u8, rule: u32 };

/// A §7.7.2 statement's answer: its `resolveto` discipline, or `exclude`.
const Resolution = struct { result: []const u8, exclude: bool };

/// Resolves, inserts, and restores preorder; a defparam `waiting` for an
/// inserted connect module sets its parameter (§7.8.5 names are
/// hierarchical names). A design with no connect statement still resolves
/// its disciplines and judges its mixed ports (E0927).
pub fn run(s: *Sema, waiting: defparam.Waiting) Allocator.Error!void {
    const zcu = s.zcu;
    const rules = try collectRules(s);
    const count = zcu.instances.len;
    // Each instance's children, in table order.
    const kids = try s.arena.alloc(std.ArrayList(Instance.Index), count);
    for (kids) |*k| k.* = .empty;
    for (zcu.instances.items(.parent), 0..) |p, k| if (p != .none) try kids[@backingInt(p)].append(s.arena, @fromBackingInt(@intCast(k)));
    // Bottom up: a child follows its parent in preorder.
    var k = count;
    while (k > 0) {
        k -= 1;
        try resolveInstance(s, kids, @fromBackingInt(@intCast(k)));
    }
    var hits: std.ArrayList(Hit) = .empty;
    for (0..count) |p| for (kids[p].items) |c| try mixedPorts(s, rules, @fromBackingInt(@intCast(p)), c, &hits);
    if (hits.items.len == 0) return;
    try insert(s, rules, hits.items, waiting);
    try preorder(s);
}

// ---- private ----

/// §7.7.1 every statement whose connect module has one continuous and one
/// discrete port, read with its overrides. An override discipline
/// incompatible with the side it replaces is E0915 (§3.11.1).
fn collectRules(s: *Sema) Allocator.Error![]const Rule {
    const zcu = s.zcu;
    var rules: std.ArrayList(Rule) = .empty;
    for (0..zcu.files.len) |f| {
        const file: Zcu.File.Index = @fromBackingInt(@intCast(f));
        const vir = zcu.fileVir(file);
        for (vir.decls()) |d| if (d.kind == .connectrules) for (vir.body(payloadOf(vir, Inst.ConnectRules, d.inst).body)) |i| {
            if (vir.instructions.items(.tag)[@backingInt(i)] != .connect_insert) continue;
            const ins = payloadOf(vir, Inst.ConnectInsert, i);
            const m = zcu.modules.get(try zcu.intern_pool.getString(s.gpa, vir.string(ins.module))) orelse continue;
            if (zcu.declRow(m).kind != .connectmodule) continue;
            const mvir = zcu.fileVir(m.file);
            const header = mvir.body(payloadOf(mvir, Inst.Module, zcu.declRow(m).inst).ports);
            if (header.len != 2) continue;
            var sides: [2]Side = undefined;
            var domains: [2]?discipline.Domain = undefined;
            const decls = try netsOf(s, m);
            for (header, &sides, &domains) |h, *side, *dom| {
                const name = try zcu.intern_pool.getString(s.gpa, portName(mvir, h));
                const n = decls.get(name) orelse Net{ .discipline = "", .dir = .none };
                side.* = .{ .port = name, .discipline = n.discipline, .dir = n.dir };
                dom.* = try discipline.domainOf(s, n.discipline);
            }
            const c: usize = if (domains[0] == .continuous and domains[1] == .discrete) 0 else if (domains[1] == .continuous and domains[0] == .discrete) 1 else continue;
            var r: Rule = .{ .module = m, .file = file, .src = i, .cont = sides[c], .disc = sides[1 - c], .split = ins.flags.split, .params = ins.params };
            const ok = for ([_]struct { Inst.Direction, Vir.String }{ .{ ins.flags.a_dir, ins.a }, .{ ins.flags.b_dir, ins.b } }) |ov| {
                if (ov[1] == .empty) continue;
                const name = vir.string(ov[1]);
                const side = if (try discipline.domainOf(s, name) == .continuous) &r.cont else &r.disc;
                if (!try discipline.compatible(s, side.discipline, name)) {
                    try s.fail(.E0915, file, i.toRef(), "`{s}` cannot stand for `{s}`'s `{s}` (§3.11.1)", .{ name, mvir.string(zcu.declRow(m).name), zcu.intern_pool.stringToSlice(side.port) });
                    break false;
                }
                side.discipline = name;
                if (ov[0] != .none) side.dir = ov[0];
            } else true;
            if (ok) try rules.append(s.arena, r);
        };
    }
    return rules.items;
}

/// Records the resolved discipline of every net of instance `i` that has
/// one: declared, or from its children's port segments (F.2 basic).
fn resolveInstance(s: *Sema, kids: []const std.ArrayList(Instance.Index), i: Instance.Index) Allocator.Error!void {
    const zcu = s.zcu;
    const module = zcu.instances.items(.module)[@backingInt(i)];
    const decls = try netsOf(s, module);
    var it = decls.iterator();
    while (it.next()) |e| if (e.value_ptr.discipline.len != 0)
        try zcu.net_discipline.put(s.gpa, .{ .instance = i, .net = e.key_ptr.* }, try zcu.intern_pool.getString(s.gpa, e.value_ptr.discipline));
    var cands: std.AutoArrayHashMapUnmanaged(String, std.ArrayList([]const u8)) = .empty;
    const vir = zcu.fileVir(module.file);
    for (kids[@backingInt(i)].items) |c| {
        const run_ = zcu.instances.items(.ports)[@backingInt(c)];
        const cmod = zcu.instances.items(.module)[@backingInt(c)];
        const cvir = zcu.fileVir(cmod.file);
        for (zcu.ports.items(.formal)[run_.start..][0..run_.len], zcu.ports.items(.actual)[run_.start..][0..run_.len]) |formal, actual| {
            const sig = try netName(s, vir, actual) orelse continue;
            if (decls.get(sig)) |n| if (n.discipline.len != 0) continue;
            const inner = try zcu.intern_pool.getString(s.gpa, internalName(cvir, formal));
            const lower = zcu.net_discipline.get(.{ .instance = c, .net = inner }) orelse continue;
            const gop = try cands.getOrPut(s.arena, sig);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(s.arena, zcu.intern_pool.stringToSlice(lower));
        }
    }
    for (cands.keys(), cands.values()) |sig, list| {
        const d = try merge(s, i, list.items) orelse continue;
        try zcu.net_discipline.put(s.gpa, .{ .instance = i, .net = sig }, try zcu.intern_pool.getString(s.gpa, d));
    }
}

/// Annex F.2.1 step 4 for one undeclared net of instance `i` from its child
/// segments' disciplines. 4.a: the net is continuous when any child is,
/// else discrete. 4.b: the distinct candidates of that domain: one is the
/// answer; several are resolved by the §7.7.2 statement that lists them
/// (exactly, else as a subset; W0950 when several do, the first wins), and
/// one that `exclude`s them is E0917; with no statement the discipline is
/// unknown, an error (E0903) when the net also joins the other domain, and
/// insertion then reads the first candidate.
fn merge(s: *Sema, i: Instance.Index, list: []const []const u8) Allocator.Error!?[]const u8 {
    assert(list.len != 0);
    var continuous = false;
    for (list) |d| continuous = continuous or try discipline.domainOf(s, d) == .continuous;
    const want: discipline.Domain = if (continuous) .continuous else .discrete;
    var cands: std.ArrayList([]const u8) = .empty;
    var mixed = false;
    for (list) |d| {
        if (try discipline.domainOf(s, d) != want) {
            mixed = true;
            continue;
        }
        const seen = for (cands.items) |c| {
            if (std.mem.eql(u8, c, d)) break true;
        } else false;
        if (!seen) try cands.append(s.arena, d);
    }
    if (cands.items.len == 0) return list[0];
    if (cands.items.len == 1) return cands.items[0];
    const zcu = s.zcu;
    const file = zcu.instances.items(.module)[@backingInt(i)].file;
    for ([_]bool{ true, false }) |exact| if (try resolution(s, cands.items, exact, file)) |r| {
        if (r.exclude) {
            try s.fail(.E0917, file, .none, "the disciplines of a net of `{f}` match `connect ... resolveto exclude`", .{zcu.fmtPath(i)});
            return null;
        }
        return r.result;
    };
    if (mixed) try s.fail(.E0903, file, .none, "a net of `{f}` joins {d} {t} disciplines no resolution statement resolves, and a mixed port", .{ zcu.fmtPath(i), cands.items.len, want });
    return cands.items[0];
}

/// The first §7.7.2 statement whose list holds every candidate (`exact`:
/// and nothing else); W0950 when several do.
fn resolution(s: *Sema, cands: []const []const u8, exact: bool, at: Zcu.File.Index) Allocator.Error!?Resolution {
    const zcu = s.zcu;
    var first: ?Resolution = null;
    for (0..zcu.files.len) |f| {
        const vir = zcu.fileVir(@fromBackingInt(@intCast(f)));
        for (vir.decls()) |d| if (d.kind == .connectrules) for (vir.body(payloadOf(vir, Inst.ConnectRules, d.inst).body)) |i| {
            if (vir.instructions.items(.tag)[@backingInt(i)] != .connect_resolve) continue;
            const r = payloadOf(vir, Inst.ConnectResolve, i);
            const names = vir.list(Vir.String, r.disciplines);
            const covers = for (cands) |want| {
                const in = for (names) |n| {
                    if (std.mem.eql(u8, vir.string(n), want)) break true;
                } else false;
                if (!in) break false;
            } else true;
            if (!covers or (exact and names.len != cands.len)) continue;
            if (first != null) {
                try s.fail(.W0950, at, i.toRef(), "multiple {s} resolution rules apply; using the first", .{if (exact) "exact" else "subset"});
                continue;
            }
            first = .{ .result = vir.string(r.result), .exclude = r.flags.exclude };
        };
    }
    return first;
}

/// §7.8.4 judges each port of child `c` of `p`: mixed when its upper and
/// lower connections resolve to different domains, then matched against
/// the statements (E0922 for more than one, E0927 for none).
fn mixedPorts(s: *Sema, rules: []const Rule, p: Instance.Index, c: Instance.Index, hits: *std.ArrayList(Hit)) Allocator.Error!void {
    const zcu = s.zcu;
    const pmod = zcu.instances.items(.module)[@backingInt(p)];
    const cmod = zcu.instances.items(.module)[@backingInt(c)];
    if (zcu.declRow(cmod).kind == .connectmodule) return;
    const vir = zcu.fileVir(pmod.file);
    const cvir = zcu.fileVir(cmod.file);
    const cdecls = try netsOf(s, cmod);
    const pdecls = try netsOf(s, pmod);
    const run_ = zcu.instances.items(.ports)[@backingInt(c)];
    for (zcu.ports.items(.formal)[run_.start..][0..run_.len], zcu.ports.items(.actual)[run_.start..][0..run_.len]) |formal, actual| {
        const inner = try zcu.intern_pool.getString(s.gpa, internalName(cvir, formal));
        const sig = try netName(s, vir, actual) orelse {
            try analogActual(s, pmod.file, vir, c, inner, actual, formal, cvir);
            continue;
        };
        const upper = zcu.net_discipline.get(.{ .instance = p, .net = sig }) orelse continue;
        const lower = zcu.net_discipline.get(.{ .instance = c, .net = inner }) orelse continue;
        const up = zcu.intern_pool.stringToSlice(upper);
        const low = zcu.intern_pool.stringToSlice(lower);
        const du = try discipline.domainOf(s, up) orelse continue;
        const dl = try discipline.domainOf(s, low) orelse continue;
        if (du == dl) {
            // §3.11.1 one domain, so no bridge: a net and a port both
            // declared must agree. An undeclared net took a child's
            // discipline (F.2), and a shipped primitive's ports take the
            // net's (E.3.2.2).
            const declared = if (pdecls.get(sig)) |n| n.discipline.len != 0 else false;
            if (declared and !zcu.isBuiltin(cmod) and !try discipline.compatible(s, up, low))
                try s.fail(.E0355, pmod.file, zcu.instances.items(.src)[@backingInt(c)], "port `{s}` is `{s}` and its net `{s}` is `{s}`: incompatible disciplines (§3.11.1)", .{ portName(cvir, formal), low, zcu.intern_pool.stringToSlice(sig), up });
            continue;
        }
        const dir = if (cdecls.get(inner)) |n| n.dir else Inst.Direction.none;
        var found: ?u32 = null;
        var n: u32 = 0;
        for (rules, 0..) |r, ri| if (try matches(s, r, dir, up, low)) {
            n += 1;
            if (found == null) found = @intCast(ri);
        };
        const port_name = try zcu.intern_pool.getString(s.gpa, portName(cvir, formal));
        const child_name = zcu.intern_pool.stringToSlice(zcu.instances.items(.name)[@backingInt(c)]);
        if (n > 1) {
            try s.fail(.E0922, pmod.file, zcu.instances.items(.src)[@backingInt(c)], "port `{s}` of `{s}` matches more than one connect statement ({d})", .{ zcu.intern_pool.stringToSlice(port_name), child_name, n });
            continue;
        }
        const rule = found orelse {
            try s.fail(.E0927, pmod.file, zcu.instances.items(.src)[@backingInt(c)], "port `{s}` of `{s}` is `{s}` and its net `{s}` is `{s}`, and no connect statement bridges them", .{ zcu.intern_pool.stringToSlice(port_name), child_name, low, zcu.intern_pool.stringToSlice(sig), up });
            continue;
        };
        try hits.append(s.arena, .{ .parent = p, .child = c, .port = formal, .port_name = port_name, .sig = sig, .bottom = low, .rule = rule });
    }
}

/// §6.5 a continuous port joins a net: a variable (§6.5.1 lists no
/// variable port expression) or another expression (§6.2.2 allows one for a
/// digital input only) as its actual is E0906. A select or concatenation
/// names net parts and is judged where it is bound.
fn analogActual(s: *Sema, file: Zcu.File.Index, vir: *const Vir, c: Instance.Index, inner: String, actual: Inst.Ref, formal: Inst.Index, cvir: *const Vir) Allocator.Error!void {
    const zcu = s.zcu;
    const i = actual.toIndex() orelse return;
    const low = zcu.net_discipline.get(.{ .instance = c, .net = inner }) orelse return;
    if (try discipline.domainOf(s, zcu.intern_pool.stringToSlice(low)) != .continuous) return;
    switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .elem, .slice, .slice_up, .slice_down, .concat, .decl_ref => {},
        else => return s.fail(.E0906, file, zcu.instances.items(.src)[@backingInt(c)], "port `{s}` is continuous and its connection is an expression, not a net", .{portName(cvir, formal)}), // else: every other instruction is an expression
    }
    if (vir.instructions.items(.tag)[@backingInt(i)] != .decl_ref) return;
    const d = vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl;
    if (vir.instructions.items(.tag)[@backingInt(d)] == .variable)
        try s.fail(.E0906, file, zcu.instances.items(.src)[@backingInt(c)], "port `{s}` is continuous and its connection is a variable: it joins only a net", .{portName(cvir, formal)});
}

/// Table 7-2 and §7.7.1: statement `r` bridges a port of direction `dir`
/// whose upper connection is `upper` and lower `lower` when its sides'
/// disciplines are compatible with the two and its directions carry the
/// signal the port's way (an inout pair any way).
fn matches(s: *Sema, r: Rule, dir: Inst.Direction, upper: []const u8, lower: []const u8) Allocator.Error!bool {
    if (r.cont.dir == .inout and r.disc.dir == .inout) {
        const up_cont = try discipline.domainOf(s, upper) == .continuous;
        const c = if (up_cont) upper else lower;
        const d = if (up_cont) lower else upper;
        return try compat(s, r.cont.discipline, c) and try compat(s, r.disc.discipline, d);
    }
    const in_side, const out_side = if (r.cont.dir == .input and r.disc.dir == .output)
        .{ r.cont, r.disc }
    else if (r.cont.dir == .output and r.disc.dir == .input)
        .{ r.disc, r.cont }
    else
        return false;
    const source, const sink = switch (dir) {
        .input => .{ upper, lower },
        .output => .{ lower, upper },
        .inout, .none => return false,
    };
    return try compat(s, in_side.discipline, source) and try compat(s, out_side.discipline, sink);
}

fn compat(s: *Sema, a: []const u8, b: []const u8) Allocator.Error!bool {
    return try discipline.domainOf(s, a) == try discipline.domainOf(s, b) and try discipline.compatible(s, a, b);
}

/// Appends one bridge instance per merged group or split port, as a child
/// of the upper connection's instance, and one `Zcu.inserts` row per port.
fn insert(s: *Sema, rules: []const Rule, hits: []const Hit, waiting: defparam.Waiting) Allocator.Error!void {
    const zcu = s.zcu;
    for (hits, 0..) |h, k| {
        const r = rules[h.rule];
        const low_analog = try discipline.domainOf(s, h.bottom) == .continuous;
        // §7.8.2: an analog lower connection is never split.
        const merged = !r.split or low_analog;
        const owner = if (merged) for (hits[0..k]) |g| {
            if (g.parent == h.parent and g.sig == h.sig and g.rule == h.rule and std.mem.eql(u8, g.bottom, h.bottom)) break g;
        } else null else null;
        const bridge: Instance.Index = if (owner) |o| bridgeOf(zcu, o) else made: {
            const mvir = zcu.fileVir(r.module.file);
            const name = if (merged)
                try std.fmt.allocPrint(s.arena, "{s}__{s}__{s}", .{ zcu.intern_pool.stringToSlice(h.sig), mvir.string(zcu.declRow(r.module).name), h.bottom })
            else
                try std.fmt.allocPrint(s.arena, "{s}__{s}__{s}", .{ zcu.intern_pool.stringToSlice(h.sig), zcu.intern_pool.stringToSlice(zcu.instances.items(.name)[@backingInt(h.child)]), zcu.intern_pool.stringToSlice(h.port_name) });
            break :made try bridgeInstance(s, r, h.parent, try zcu.intern_pool.getString(s.gpa, name), try defparam.waitingFor(s, waiting, h.parent, name));
        };
        try zcu.inserts.append(s.gpa, .{ .instance = h.child, .port = h.port, .bridge = bridge });
    }
}

/// The bridge an earlier hit of a merged group made: its `inserts` row.
fn bridgeOf(zcu: *const Zcu, h: Hit) Instance.Index {
    for (zcu.inserts.items(.instance), zcu.inserts.items(.port), zcu.inserts.items(.bridge)) |i, p, b| if (i == h.child and p == h.port) return b;
    unreachable; // the owner was inserted before every later member of its group
}

/// One connect-module instance under `parent`, its parameters folded with
/// the statement's values (§7.7.3).
fn bridgeInstance(s: *Sema, r: Rule, parent: Instance.Index, name: String, dps: []const defparam.Dp) Allocator.Error!Instance.Index {
    const zcu = s.zcu;
    const mvir = zcu.fileVir(r.module.file);
    const row = zcu.declRow(r.module);
    const m = payloadOf(mvir, Inst.Module, row.inst);
    var env: eval.Env = try .init(s.gpa, s.arena, &zcu.intern_pool, mvir, &.{ m.params, m.body });
    defer env.deinit();
    // The statement's values are constants of the connectrules' file.
    var at: eval.Env = try .init(s.gpa, s.arena, &zcu.intern_pool, zcu.fileVir(r.file), &.{});
    defer at.deinit();
    var givens: std.ArrayList(walk.Given) = .empty;
    const rvir = zcu.fileVir(r.file);
    for (rvir.list(Inst.Arg, r.params)) |a| {
        const v = if (try at.body(a.value)) |c| try at.intern(c) else InternPool.Index.undef;
        try givens.append(s.arena, .{ .name = try zcu.intern_pool.getString(s.gpa, rvir.string(a.name)), .value = v });
    }
    try walk.applyGivens(s, &env, r.file, r.src.toRef(), givens.items, true, row.name);
    try defparam.applyDefparams(s, &env, dps, row.name);
    for (env.positions.keys()) |p| _ = try env.param(p);
    const params = try zcu.intern_pool.get(s.gpa, .{ .aggregate = .{ .ty = .none, .elems = env.values.items } });
    const index: Instance.Index = @fromBackingInt(@intCast(zcu.instances.len));
    try zcu.instances.append(s.gpa, .{
        .module = r.module,
        .parent = parent,
        .name = name,
        .params = params,
        .paramset = .none,
        .src = .none,
        .hier = zcu.instances.items(.hier)[@backingInt(parent)],
        .ports = .{ .start = @intCast(zcu.ports.len), .len = 0 },
    });
    const gop = try zcu.instance_map.getOrPut(s.gpa, .{ .module = r.module, .params = params });
    if (!gop.found_existing) gop.value_ptr.* = index;
    return index;
}

/// Puts the instance table back in depth-first preorder (each parent's
/// children in table order, so a bridge follows its siblings' subtrees),
/// remapping every index that names a row.
fn preorder(s: *Sema) Allocator.Error!void {
    const zcu = s.zcu;
    const n = zcu.instances.len;
    const parents = zcu.instances.items(.parent);
    const kids = try s.arena.alloc(std.ArrayList(u32), n);
    for (kids) |*k| k.* = .empty;
    var stack: std.ArrayList(u32) = .empty;
    var k = n;
    while (k > 0) {
        k -= 1;
        if (parents[k] == .none) try stack.append(s.arena, @intCast(k)) else try kids[@backingInt(parents[k])].insert(s.arena, 0, @intCast(k));
    }
    // `kids` lists are in table order; push them reversed so the first pops first.
    const order = try s.arena.alloc(u32, n);
    const new_of = try s.arena.alloc(u32, n);
    var at: u32 = 0;
    while (stack.pop()) |i| {
        order[at] = i;
        new_of[i] = at;
        at += 1;
        var j = kids[i].items.len;
        while (j > 0) {
            j -= 1;
            try stack.append(s.arena, kids[i].items[j]);
        }
    }
    assert(at == n);
    var next: std.MultiArrayList(Instance) = .empty;
    try next.ensureTotalCapacity(s.gpa, n);
    for (order) |old| {
        var row = zcu.instances.get(old);
        if (row.parent != .none) row.parent = @fromBackingInt(new_of[@backingInt(row.parent)]);
        next.appendAssumeCapacity(row);
    }
    zcu.instances.deinit(s.gpa);
    zcu.instances = next;
    var it = zcu.instance_map.valueIterator();
    while (it.next()) |v| v.* = @fromBackingInt(new_of[@backingInt(v.*)]);
    for (zcu.defparams.keys()) |*key| key.instance = @fromBackingInt(new_of[@backingInt(key.instance)]);
    try zcu.defparams.reIndex(s.gpa);
    for (zcu.inserts.items(.instance), zcu.inserts.items(.bridge)) |*i, *b| {
        i.* = @fromBackingInt(new_of[@backingInt(i.*)]);
        b.* = @fromBackingInt(new_of[@backingInt(b.*)]);
    }
    var segs: std.AutoHashMapUnmanaged(Zcu.NetKey, String) = .empty;
    var nit = zcu.net_discipline.iterator();
    while (nit.next()) |e| try segs.put(s.gpa, .{ .instance = @fromBackingInt(new_of[@backingInt(e.key_ptr.instance)]), .net = e.key_ptr.net }, e.value_ptr.*);
    zcu.net_discipline.deinit(s.gpa);
    zcu.net_discipline = segs;
}

/// A module's net, port and port-direction declarations by name (header
/// and top-level body; a later one adds to an earlier one of the name).
/// ponytail: read again per instance, linear in the module's items; a cache
/// by module if a design's size makes it show.
fn netsOf(s: *Sema, module: Zcu.Decl) Allocator.Error!std.AutoHashMapUnmanaged(String, Net) {
    const zcu = s.zcu;
    const vir = zcu.fileVir(module.file);
    const m = payloadOf(vir, Inst.Module, zcu.declRow(module).inst);
    var out: std.AutoHashMapUnmanaged(String, Net) = .empty;
    for ([_]Vir.Body{ m.ports, m.body }) |b| for (vir.body(b)) |i| {
        const name, const disc, const dir = switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            .io => blk: {
                const io = payloadOf(vir, Inst.Io, i);
                break :blk .{ io.name, io.discipline, io.flags.dir };
            },
            .net => blk: {
                const net = payloadOf(vir, Inst.Net, i);
                break :blk .{ net.name, net.discipline, Inst.Direction.none };
            },
            else => continue, // else: only port and net declarations declare a net's discipline
        };
        const gop = try out.getOrPut(s.arena, try zcu.intern_pool.getString(s.gpa, vir.string(name)));
        if (!gop.found_existing) gop.value_ptr.* = .{ .discipline = "", .dir = .none };
        if (disc != .empty) gop.value_ptr.discipline = vir.string(disc);
        if (dir != .none) gop.value_ptr.dir = dir;
    };
    return out;
}

/// The net a port connection names in `vir`: a declared net or port, or an
/// undeclared name (§3.6.5's implicit net); null for anything else.
fn netName(s: *Sema, vir: *const Vir, actual: Inst.Ref) Allocator.Error!?String {
    const i = actual.toIndex() orelse return null;
    const data = vir.instructions.items(.data)[@backingInt(i)];
    const text = switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .str_ref => vir.string(data.str_tok.start),
        .decl_ref => switch (vir.instructions.items(.tag)[@backingInt(data.decl_tok.decl)]) {
            .net => vir.string(payloadOf(vir, Inst.Net, data.decl_tok.decl).name),
            .io => vir.string(payloadOf(vir, Inst.Io, data.decl_tok.decl).name),
            else => return null, // else: a variable, parameter or scope is no net
        },
        else => return null, // else: an expression, select or concatenation names no whole net
    };
    return try s.zcu.intern_pool.getString(s.gpa, text);
}

/// A header port's external name: an ANSI `io`'s, or a `port`'s.
fn portName(vir: *const Vir, f: Inst.Index) []const u8 {
    return vir.string(switch (vir.instructions.items(.tag)[@backingInt(f)]) {
        .io => payloadOf(vir, Inst.Io, f).name,
        .port => payloadOf(vir, Inst.Port, f).name,
        else => unreachable, // else: a module header holds only ports and port declarations
    });
}

/// The net inside the child a header port connects: an ANSI `io`'s own
/// name, a `port` expression's net, else its external name.
fn internalName(vir: *const Vir, f: Inst.Index) []const u8 {
    if (vir.instructions.items(.tag)[@backingInt(f)] == .port) {
        const value = vir.body(payloadOf(vir, Inst.Port, f).value);
        if (value.len != 0) {
            const last = value[value.len - 1];
            if (vir.instructions.items(.tag)[@backingInt(last)] == .decl_ref) {
                const d = vir.instructions.items(.data)[@backingInt(last)].decl_tok.decl;
                switch (vir.instructions.items(.tag)[@backingInt(d)]) {
                    .io => return vir.string(payloadOf(vir, Inst.Io, d).name),
                    .net => return vir.string(payloadOf(vir, Inst.Net, d).name),
                    else => {}, // else: a port expression naming no net keeps the external name
                }
            }
        }
    }
    return portName(vir, f);
}
