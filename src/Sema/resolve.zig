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

/// A net's declaration in a module: its discipline (empty when none) and,
/// for a port, its direction.
pub const Net = struct { discipline: []const u8, dir: Inst.Direction, vector: bool = false };

/// A §7.7.2 statement's answer: its `resolveto` discipline, or `exclude`.
const Resolution = struct { result: []const u8, exclude: bool };

/// Resolves every instance's nets, children before parents. Asserts that
/// `kids` lists each instance's children.
pub fn run(s: *Sema, kids: []const std.ArrayList(Instance.Index)) Allocator.Error!void {
    assert(kids.len == s.zcu.instances.len);
    var k = kids.len;
    while (k > 0) {
        k -= 1;
        try resolveInstance(s, kids, @fromBackingInt(@intCast(k)));
    }
    assert(k == 0);
}

/// A module's net, port and port-direction declarations by name (header
/// and top-level body; a later one adds to an earlier one of the name).
/// ponytail: read again per instance, linear in the module's items; a cache
/// by module if a design's size makes it show.
pub fn netsOf(s: *Sema, module: Zcu.Decl) Allocator.Error!std.AutoHashMapUnmanaged(String, Net) {
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
    return vir.string(switch (vir.instructions.items(.tag)[@backingInt(f)]) {
        .io => payloadOf(vir, Inst.Io, f).name,
        .port => payloadOf(vir, Inst.Port, f).name,
        else => unreachable, // else: a module header holds only ports and port declarations
    });
}

/// The net inside the child a header port connects: an ANSI `io`'s own
/// name, a `port` expression's net, else its external name.
pub fn internalName(vir: *const Vir, f: Inst.Index) []const u8 {
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

/// Records the resolved discipline of every net of instance `i` that has
/// one: declared, or from its children's port segments (F.2 basic).
fn resolveInstance(s: *Sema, kids: []const std.ArrayList(Instance.Index), i: Instance.Index) Allocator.Error!void {
    assert(@backingInt(i) < kids.len);
    assert(kids.len == s.zcu.instances.len);
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
