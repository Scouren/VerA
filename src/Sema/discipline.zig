//! §3.6 disciplines and natures as Sema reads them: a discipline name in,
//! its domain, the natures it binds and §3.11.1 compatibility out, over
//! `Zcu.disciplines` and `Zcu.natures` (each name's last declaration).
//! Cites: VAMS-2023 §3.6.1.1, §3.6.1.2, §3.6.2.2, §3.6.2.6, §3.11.1.
//!
//! Contents:
//! - `pub const Domain`, `pub const behavioral`
//! - `pub fn domainOf(s: *Sema, name: []const u8) Allocator.Error!?Domain`
//! - `pub fn compatible(s: *Sema, a: []const u8, b: []const u8) Allocator.Error!bool`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Sema = @import("../Sema.zig");
const Zcu = @import("../Zcu.zig");
const walk = @import("walk.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const payloadOf = walk.payloadOf;

/// §3.6.2.2 a discipline's domain.
pub const Domain = enum { continuous, discrete };

/// §3.6.2.4 the discipline of an undeclared net digital behavioral code
/// uses: discrete and natureless, so compatible with every discrete one
/// (§3.11.1). A `$` name, so no declaration can take it.
pub const behavioral = "$behavioral";

const ItemKind = @FieldType(Inst.DisciplineItem, "kind");

/// The derived-nature chain `baseNature` follows at most.
const nature_hops_max = 16;

/// A discipline's declaration and the Vir it is in.
const Found = struct { vir: *const Vir, decl: Inst.Discipline };

/// §3.6.2.2 the domain of the discipline `name`: as declared, else
/// continuous when it binds a nature ("the default domain ... is
/// continuous"). Null for no discipline of the name, and for a domainless
/// one (no domain, no nature).
pub fn domainOf(s: *Sema, name: []const u8) Allocator.Error!?Domain {
    if (std.mem.eql(u8, name, behavioral)) return .discrete;
    const d = try lookup(s, name) orelse return null;
    var natures = false;
    for (d.vir.list(Inst.DisciplineItem, d.decl.items)) |it| switch (it.kind) {
        .domain => return if (std.mem.eql(u8, d.vir.string(it.name), "discrete")) .discrete else .continuous,
        .potential, .flow => natures = true,
        .potential_attr, .flow_attr, .attr => {},
    };
    return if (natures) .continuous else null;
}

/// §3.11.1: two disciplines are compatible when their domains agree and
/// each half's natures are compatible (one absent, the same, derived from
/// one base nature, or of equal `units`). A name no discipline declares
/// conflicts with nothing.
pub fn compatible(s: *Sema, a: []const u8, b: []const u8) Allocator.Error!bool {
    if (std.mem.eql(u8, a, b)) return true;
    const da = try lookup(s, a) orelse return true;
    const db = try lookup(s, b) orelse return true;
    if (try domainOf(s, a) != try domainOf(s, b)) return false;
    for ([_]ItemKind{ .potential, .flow }) |half| {
        const na = natureOf(da, half) orelse continue;
        const nb = natureOf(db, half) orelse continue;
        if (std.mem.eql(u8, try baseNature(s, na), try baseNature(s, nb))) continue;
        const ua = try unitsOf(s, na) orelse return false;
        const ub = try unitsOf(s, nb) orelse return false;
        if (!std.mem.eql(u8, ua, ub)) return false;
    }
    return true;
}

// ---- private ----

fn lookup(s: *Sema, name: []const u8) Allocator.Error!?Found {
    assert(name.len < std.math.maxInt(u32));
    if (name.len == 0) return null;
    const zcu = s.zcu;
    const d = zcu.disciplines.get(try zcu.intern_pool.getString(s.gpa, name)) orelse return null;
    const vir = zcu.fileVir(d.file);
    return .{ .vir = vir, .decl = payloadOf(vir, Inst.Discipline, zcu.declRow(d).inst) };
}

/// The nature `d` binds to `half`, or null.
fn natureOf(d: Found, half: ItemKind) ?[]const u8 {
    assert(half == .potential or half == .flow);
    for (d.vir.list(Inst.DisciplineItem, d.decl.items)) |it| if (it.kind == half) return d.vir.string(it.name);
    return null;
}

/// §3.6.1.1 the `units` string nature `name` gives (or its parent chain
/// does), or null.
fn unitsOf(s: *Sema, name: []const u8) Allocator.Error!?[]const u8 {
    assert(name.len != 0);
    const zcu = s.zcu;
    var at = name;
    for (0..nature_hops_max) |_| {
        const n = zcu.natures.get(try zcu.intern_pool.getString(s.gpa, at)) orelse return null;
        const vir = zcu.fileVir(n.file);
        const nat = payloadOf(vir, Inst.Nature, zcu.declRow(n).inst);
        for (vir.list(Inst.Attr, nat.attrs)) |a| {
            if (!std.mem.eql(u8, vir.string(a.name), "units")) continue;
            const value = vir.body(a.value);
            if (value.len == 0) return null;
            const last = value[value.len - 1];
            if (vir.instructions.items(.tag)[@backingInt(last)] != .str) return null;
            const str = vir.instructions.items(.data)[@backingInt(last)].str;
            return vir.string_bytes[@backingInt(str.start)..][0..str.len];
        }
        if (nat.parent == .empty or nat.flags.parent_kind != .none) return null;
        at = vir.string(nat.parent);
    }
    return null;
}

/// §3.11.1 Derived Nature Rule: the base nature `name` derives from (a
/// `parent` that is a nature, or a discipline's half); itself when it has
/// none or names no nature.
fn baseNature(s: *Sema, name: []const u8) Allocator.Error![]const u8 {
    assert(name.len != 0);
    defer assert(name.len != 0);
    const zcu = s.zcu;
    var at = name;
    for (0..nature_hops_max) |_| {
        const n = zcu.natures.get(try zcu.intern_pool.getString(s.gpa, at)) orelse return at;
        const vir = zcu.fileVir(n.file);
        const nat = payloadOf(vir, Inst.Nature, zcu.declRow(n).inst);
        if (nat.parent == .empty) return at;
        const parent = vir.string(nat.parent);
        at = switch (nat.flags.parent_kind) {
            .none => parent,
            .potential, .flow => |h| natureOf(try lookup(s, parent) orelse return at, if (h == .potential) .potential else .flow) orelse return at,
        };
    }
    return at;
}
