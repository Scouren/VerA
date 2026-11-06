//! Annex F discipline resolution over the finished instance table:
//! `Zcu.instances`, `Zcu.ports` and each instance's children in; the
//! discipline of every port-connected net of every instance out
//! (`Zcu.net_discipline`). F.2's basic mode, bottom up (a child follows its
//! parent in preorder, so the table is walked backwards): a net declared
//! with a discipline has it; an undeclared one takes its child segments'
//! disciplines (step 4: the level's domain, then one candidate, a §7.7.2
//! resolution, or unknown). Also the net and port readers `connect.zig`
//! shares.
//! Cites: VAMS-2023 §3.6.2.2, §7.4.4.1, §7.7.2, Annex F.2.1.
//!
//! Contents:
//! - `pub const Net`
//! - `pub fn run(s: *Sema, kids: []const std.ArrayList(Instance.Index)) Allocator.Error!void`
//! - `pub fn netsOf(s: *Sema, module: Zcu.Decl) Allocator.Error!std.AutoHashMapUnmanaged(String, Net)`
//! - `pub fn netName(s: *Sema, vir: *const Vir, actual: Inst.Ref) Allocator.Error!?String`
//! - `pub fn portName(vir: *const Vir, f: Inst.Index) []const u8`
//! - `pub fn internalName(vir: *const Vir, f: Inst.Index) []const u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Sema = @import("../Sema.zig");
const Zcu = @import("../Zcu.zig");
const walk = @import("walk.zig");
const discipline = @import("discipline.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Instance = Zcu.Instance;
const String = InternPool.String;
const payloadOf = walk.payloadOf;

/// A net's declaration in a module: its discipline (empty when none), for
/// a port its direction, and whether it declares a range.
pub const Net = struct { discipline: []const u8, dir: Inst.Direction, vector: bool = false };

/// An out-of-context declaration's discipline and where it is written.
const Ooc = struct { discipline: []const u8, file: Zcu.File.Index, src: Inst.Ref };
const Oocs = std.AutoHashMapUnmanaged(Zcu.NetKey, Ooc);

/// The deepest instruction nesting `netsNamed` follows (the parser caps
/// source nesting far below it).
const named_depth_max = 1 << 12;

/// A §7.7.2 statement's answer: its `resolveto` discipline, or `exclude`.
const Resolution = struct { result: []const u8, exclude: bool };

/// A child segment reaching a net: the child, its port and the
/// connection, and the discipline it brings. The reports point at it.
const Arrival = struct { child: Instance.Index, formal: Inst.Index, actual: Inst.Ref, discipline: []const u8 };

/// Resolves every instance's nets, children before parents, after Annex
/// F.2.1 step 3's out-of-context declarations. Asserts that `kids` lists
/// each instance's children.
pub fn run(s: *Sema, kids: []const std.ArrayList(Instance.Index)) Allocator.Error!void {
    assert(kids.len == s.zcu.instances.len);
    const ooc = try collectOoc(s);
    var k = kids.len;
    while (k > 0) {
        k -= 1;
        try resolveInstance(s, kids, &ooc, @fromBackingInt(@intCast(k)));
    }
    assert(k == 0);
}

/// A module's net, port and port-direction declarations by name (header
/// and top-level body; a later one adds to an earlier one of the name).
/// ponytail: read again per instance, linear in the module's items; a cache
/// by module if a design's size makes it show.
pub fn netsOf(s: *Sema, module: Zcu.Decl) Allocator.Error!std.AutoHashMapUnmanaged(String, Net) {
    assert(@backingInt(module.file) < s.zcu.files.len);
    assert(s.zcu.declRow(module).kind != .primitive);
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
                if (net.range.len != 0) {
                    const gop = try out.getOrPut(s.arena, try zcu.intern_pool.getString(s.gpa, vir.string(net.name)));
                    if (!gop.found_existing) gop.value_ptr.* = .{ .discipline = "", .dir = .none };
                    gop.value_ptr.vector = true;
                }
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
pub fn netName(s: *Sema, vir: *const Vir, actual: Inst.Ref) Allocator.Error!?String {
    if (actual.toIndex()) |i| assert(@backingInt(i) < vir.instructions.len);
    assert(vir.instructions.len != 0);
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
pub fn portName(vir: *const Vir, f: Inst.Index) []const u8 {
    assert(@backingInt(f) < vir.instructions.len);
    return vir.string(switch (vir.instructions.items(.tag)[@backingInt(f)]) {
        .io => payloadOf(vir, Inst.Io, f).name,
        .port => payloadOf(vir, Inst.Port, f).name,
        else => unreachable, // else: a module header holds only ports and port declarations
    });
}

/// The net inside the child a header port connects: an ANSI `io`'s own
/// name, a `port` expression's net, else its external name.
pub fn internalName(vir: *const Vir, f: Inst.Index) []const u8 {
    assert(@backingInt(f) < vir.instructions.len);
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

// ---- private ----

/// §3.6.2.4 the nets module `module`'s digital behavioral code names: every
/// net or undeclared name a continuous assignment or an `initial` or
/// `always` process reads or writes.
fn behavioralNets(s: *Sema, module: Zcu.Decl) Allocator.Error!std.AutoHashMapUnmanaged(String, void) {
    assert(s.zcu.declRow(module).kind != .paramset);
    assert(@backingInt(module.file) < s.zcu.files.len);
    const zcu = s.zcu;
    const vir = zcu.fileVir(module.file);
    var out: std.AutoHashMapUnmanaged(String, void) = .empty;
    if (zcu.declRow(module).kind == .primitive) return out;
    const m = payloadOf(vir, Inst.Module, zcu.declRow(module).inst);
    for (vir.body(m.body)) |i| switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .assign, .initial, .always => try netsNamed(s, vir, i, &out, 0),
        else => {}, // else: analog and structural items are not digital behavior
    };
    return out;
}

/// Adds to `out` every net and undeclared name instruction `i` reaches
/// through its operands and bodies.
fn netsNamed(s: *Sema, vir: *const Vir, i: Inst.Index, out: *std.AutoHashMapUnmanaged(String, void), depth: u32) Allocator.Error!void {
    assert(depth < named_depth_max);
    const tag = vir.instructions.items(.tag)[@backingInt(i)];
    const data = vir.instructions.items(.data)[@backingInt(i)];
    switch (Inst.dataKind(tag)) {
        .decl_tok => switch (vir.instructions.items(.tag)[@backingInt(data.decl_tok.decl)]) {
            .net => try out.put(s.arena, try s.zcu.intern_pool.getString(s.gpa, vir.string(payloadOf(vir, Inst.Net, data.decl_tok.decl).name)), {}),
            .io => try out.put(s.arena, try s.zcu.intern_pool.getString(s.gpa, vir.string(payloadOf(vir, Inst.Io, data.decl_tok.decl).name)), {}),
            else => {}, // else: a variable, parameter or scope is no net
        },
        .str_tok => if (tag == .str_ref) try out.put(s.arena, try s.zcu.intern_pool.getString(s.gpa, vir.string(data.str_tok.start)), {}),
        .un_node => if (data.un_node.operand.toIndex()) |o| try netsNamed(s, vir, o, out, depth + 1),
        .pl_node => switch (tag) {
            inline else => |t| if (Inst.Payload(t) != void) try namesIn(s, vir, Inst.Payload(t), vir.extraData(Inst.Payload(t), data.pl_node.payload_index), out, depth + 1),
        },
        .int, .float, .str => {},
    }
}

/// `netsNamed` over a payload's operands and bodies, field by field.
fn namesIn(s: *Sema, vir: *const Vir, comptime T: type, v: T, out: *std.AutoHashMapUnmanaged(String, void), depth: u32) Allocator.Error!void {
    assert(depth < named_depth_max);
    if (T == Inst.Ref) {
        if (v.toIndex()) |o| try netsNamed(s, vir, o, out, depth);
    } else if (T == Vir.Body) {
        for (vir.body(v)) |o| try netsNamed(s, vir, o, out, depth);
    } else if (@typeInfo(T) == .@"struct" and @hasDecl(T, "Elem")) {
        if (T.Elem == Inst.Ref or @typeInfo(T.Elem) == .@"struct") for (vir.list(T.Elem, v)) |e| try namesIn(s, vir, T.Elem, e, out, depth);
    } else if (@typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".layout == .@"extern") {
        inline for (@typeInfo(T).@"struct".field_names) |f| try namesIn(s, vir, @FieldType(T, f), @field(v, f), out, depth);
    }
}

/// Annex F.2.1 step 3 every out-of-context discipline declaration
/// (`electrical u.w;`, `magnetic $root.top.u.q;`) by the instance and net
/// it names: §3.10's precedence order 1, over the net's own declaration.
/// E0902 for a second declaration of one segment ("More than one
/// conflicting out-of-context discipline declaration for the same
/// hierarchical segment of a signal is an error"; §3.10 makes two at one
/// level illegal even when compatible). A path that names no instance
/// declares nothing.
fn collectOoc(s: *Sema) Allocator.Error!Oocs {
    assert(s.zcu.net_discipline.count() == 0);
    const zcu = s.zcu;
    var out: Oocs = .empty;
    var paths: std.StringHashMapUnmanaged(Instance.Index) = .empty;
    for (0..zcu.instances.len) |k| {
        const i: Instance.Index = @fromBackingInt(@intCast(k));
        const module = zcu.instances.items(.module)[k];
        if (zcu.declRow(module).kind == .primitive) continue;
        const vir = zcu.fileVir(module.file);
        const m = payloadOf(vir, Inst.Module, zcu.declRow(module).inst);
        for (vir.body(m.body)) |n| {
            if (vir.instructions.items(.tag)[@backingInt(n)] != .net) continue;
            const net = payloadOf(vir, Inst.Net, n);
            const text = vir.string(net.name);
            if (std.mem.findAny(u8, text, ".$") == null or net.discipline == .empty) continue;
            if (paths.count() == 0) for (0..zcu.instances.len) |j|
                try paths.put(s.arena, try std.fmt.allocPrint(s.arena, "{f}", .{zcu.fmtPath(@fromBackingInt(@intCast(j)))}), @fromBackingInt(@intCast(j)));
            const abs = if (std.mem.startsWith(u8, text, "$root.")) text["$root.".len..] else try std.fmt.allocPrint(s.arena, "{f}.{s}", .{ zcu.fmtPath(i), text });
            const dot = std.mem.findScalarLast(u8, abs, '.') orelse continue;
            const owner = paths.get(abs[0..dot]) orelse continue;
            const dot_root = std.mem.findScalar(u8, abs, '.').?;
            const key: Zcu.NetKey = .{ .instance = owner, .net = try zcu.intern_pool.getString(s.gpa, abs[dot + 1 ..]) };
            const gop = try out.getOrPut(s.arena, key);
            if (gop.found_existing) {
                // The old elaborator's path: below the root.
                try s.fail(.E0902, module.file, n.toRef(), "`{s}` already has the out-of-context discipline `{s}`", .{ abs[dot_root + 1 ..], gop.value_ptr.discipline });
                continue;
            }
            gop.value_ptr.* = .{ .discipline = vir.string(net.discipline), .file = module.file, .src = n.toRef() };
        }
    }
    return out;
}

/// Records the resolved discipline of every net of instance `i` that has
/// one: declared, or from its children's port segments (F.2 basic).
fn resolveInstance(s: *Sema, kids: []const std.ArrayList(Instance.Index), ooc: *const Oocs, i: Instance.Index) Allocator.Error!void {
    assert(@backingInt(i) < kids.len);
    assert(kids.len == s.zcu.instances.len);
    const zcu = s.zcu;
    const module = zcu.instances.items(.module)[@backingInt(i)];
    const decls = try netsOf(s, module);
    var it = decls.iterator();
    while (it.next()) |e| {
        const name = zcu.intern_pool.stringToSlice(e.key_ptr.*);
        // An out-of-context declaration names another scope's net.
        if (std.mem.findAny(u8, name, ".$") != null) continue;
        if (ooc.get(.{ .instance = i, .net = e.key_ptr.* })) |o| {
            // §3.6.2: overriding an explicit declaration needs a compatible
            // discipline (§3.11.1); a shipped primitive's is a placeholder.
            if (e.value_ptr.discipline.len != 0 and !zcu.isBuiltin(module)) if (try discipline.conflict(s, e.value_ptr.discipline, o.discipline)) |why|
                try s.fail(.E0375, o.file, o.src, "`{f}{s}{s}` is declared `{s}` and cannot be overridden with `{s}` ({s})", .{ zcu.fmtPathBelowRoot(i), if (zcu.instances.items(.parent)[@backingInt(i)] == .none) "" else ".", name, e.value_ptr.discipline, o.discipline, why });
            try zcu.net_discipline.put(s.gpa, .{ .instance = i, .net = e.key_ptr.* }, try zcu.intern_pool.getString(s.gpa, o.discipline));
            continue;
        }
        if (e.value_ptr.discipline.len != 0)
            try zcu.net_discipline.put(s.gpa, .{ .instance = i, .net = e.key_ptr.* }, try zcu.intern_pool.getString(s.gpa, e.value_ptr.discipline));
    }
    var cands: std.AutoArrayHashMapUnmanaged(String, std.ArrayList([]const u8)) = .empty;
    // Each net's child segments, in arrival order, for the reports.
    var arrivals: std.AutoHashMapUnmanaged(String, std.ArrayList(Arrival)) = .empty;
    const vir = zcu.fileVir(module.file);
    // §3.6.2.4: a net with no discipline that digital behavioral code uses
    // is discrete: its discrete child segments resolve it, and with none it
    // is natureless (`discipline.behavioral`).
    const digital = try behavioralNets(s, module);
    for (kids[@backingInt(i)].items) |c| {
        const run_ = zcu.instances.items(.ports)[@backingInt(c)];
        const cmod = zcu.instances.items(.module)[@backingInt(c)];
        const cvir = zcu.fileVir(cmod.file);
        // E.3.2.2: a shipped primitive's `electrical` is a placeholder the
        // net resolves, no candidate of its own.
        if (zcu.isBuiltin(cmod)) continue;
        for (zcu.ports.items(.formal)[run_.start..][0..run_.len], zcu.ports.items(.actual)[run_.start..][0..run_.len]) |formal, actual| {
            const sig = try netName(s, vir, actual) orelse continue;
            if (decls.get(sig)) |n| if (n.discipline.len != 0) continue;
            if (ooc.contains(.{ .instance = i, .net = sig })) continue;
            const inner = try zcu.intern_pool.getString(s.gpa, internalName(cvir, formal));
            const lower = zcu.net_discipline.get(.{ .instance = c, .net = inner }) orelse continue;
            const gop = try cands.getOrPut(s.arena, sig);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(s.arena, zcu.intern_pool.stringToSlice(lower));
            const seg = try arrivals.getOrPut(s.arena, sig);
            if (!seg.found_existing) seg.value_ptr.* = .empty;
            try seg.value_ptr.append(s.arena, .{ .child = c, .formal = formal, .actual = actual, .discipline = zcu.intern_pool.stringToSlice(lower) });
        }
    }
    var dit = digital.keyIterator();
    while (dit.next()) |n| {
        if (decls.get(n.*)) |d| if (d.discipline.len != 0) continue;
        if (ooc.contains(.{ .instance = i, .net = n.* })) continue;
        const gop = try cands.getOrPut(s.arena, n.*);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        var kept: usize = 0;
        for (gop.value_ptr.items) |d| if (try discipline.domainOf(s, d) == .discrete) {
            gop.value_ptr.items[kept] = d;
            kept += 1;
        };
        gop.value_ptr.shrinkRetainingCapacity(kept);
        if (kept == 0) try gop.value_ptr.append(s.arena, discipline.behavioral);
    }
    for (cands.keys(), cands.values()) |sig, list| {
        const segs = if (arrivals.get(sig)) |a| a.items else &.{};
        const d = try merge(s, i, zcu.intern_pool.stringToSlice(sig), segs, list.items) orelse continue;
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
/// insertion then reads the first candidate. `net` is the net's name, as
/// the reports spell it, and `segs` its child segments: E0917 and E0903
/// point at the first one's port, E0355 at the incompatible one's
/// connection.
fn merge(s: *Sema, i: Instance.Index, net: []const u8, segs: []const Arrival, list: []const []const u8) Allocator.Error!?[]const u8 {
    assert(list.len != 0);
    assert(@backingInt(i) < s.zcu.instances.len);
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
    const at_file = if (segs.len == 0) file else zcu.instances.items(.module)[@backingInt(segs[0].child)].file;
    const at: Inst.Ref = if (segs.len == 0) .none else segs[0].formal.toRef();
    for ([_]bool{ true, false }) |exact| if (try resolution(s, cands.items, exact, file)) |r| {
        if (r.exclude) {
            try s.fail(.E0917, at_file, at, "the disciplines of `{s}` match `connect ... resolveto exclude`", .{net});
            return null;
        }
        return r.result;
    };
    // §3.11 "It shall be an error to connect two ports or nets of the same
    // domain with incompatible disciplines".
    for (cands.items[1..]) |c| if (try discipline.conflict(s, cands.items[0], c)) |why| {
        const seg = for (segs) |g| {
            if (std.mem.eql(u8, g.discipline, c)) break g;
        } else {
            try s.fail(.E0355, file, .none, "`{s}` joins `{s}` and `{s}` ({s})", .{ net, cands.items[0], c, why });
            return cands.items[0];
        };
        const cvir = zcu.fileVir(zcu.instances.items(.module)[@backingInt(seg.child)].file);
        try s.fail(.E0355, file, seg.actual, "port `{f}.{s}` is of discipline `{s}` and is connected to `{s}`, of discipline `{s}` ({s})", .{ zcu.fmtPathBelowRoot(seg.child), portName(cvir, seg.formal), c, net, cands.items[0], why });
        return cands.items[0];
    };
    if (mixed) try s.fail(.E0903, at_file, at, "`{s}` has candidate disciplines {{`{s}`, `{s}`{s}}} and no matching `resolveto`", .{ net, cands.items[0], cands.items[1], if (cands.items.len > 2) ", ..." else "" });
    return cands.items[0];
}

/// The first §7.7.2 statement whose list holds every candidate (`exact`:
/// and nothing else); W0950 once, at the second, when several do.
fn resolution(s: *Sema, cands: []const []const u8, exact: bool, at: Zcu.File.Index) Allocator.Error!?Resolution {
    assert(cands.len > 1);
    assert(@backingInt(at) < s.zcu.files.len);
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
                // Once, at the second match, as the old elaborator stopped there.
                try s.fail(.W0950, at, i.toRef(), "multiple {s} resolution rules apply; using the first", .{if (exact) "exact" else "subset"});
                return first;
            }
            first = .{ .result = vir.string(r.result), .exclude = r.flags.exclude };
        };
    }
    return first;
}
