//! §3.6 the rules nature and discipline declarations satisfy on their own
//! (the old `analog/discipline.zig`'s `collectDisciplines` and
//! `checkNatureTable`): each file's declaration table in, the declaration
//! diagnostics out. Name lookups answer the first nature and the last
//! discipline of a name, as the old `natureAttrExpr` and `declOf` do. The
//! per-file rules (E0335, E0336, E0342) read `Zcu.File.decl_files` and are
//! skipped when it is empty.
//! Cites: VAMS-2023 §3.6.1, §3.6.1.1, §3.6.1.2, §3.6.1.3, §3.6.2.1,
//! §3.6.2.2, §3.6.2.3, §3.6.2.5, §3.6.2.7, §3.13.1, §3.13.2.
//!
//! Contents:
//! - `pub fn check(s: *Sema) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Sema = @import("../Sema.zig");
const Zcu = @import("../Zcu.zig");
const decl = @import("decl.zig");
const eval = @import("eval.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// The derived-nature chain followed at most (the old 16 hops).
const hops_max = 16;

/// One file's natures and disciplines, in source order, with each row's
/// source file (`Zcu.File.decl_files`; null when unknown).
const Table = struct {
    file: Zcu.File.Index,
    vir: *const Vir,
    natures: []const Row(Inst.Nature),
    discs: []const Row(Inst.Discipline),
    annex_d_included: bool,

    fn init(s: *Sema, file: Zcu.File.Index) Allocator.Error!Table {
        const zcu = s.zcu;
        const vir = zcu.fileVir(file);
        const files = zcu.files.items(.decl_files)[@backingInt(file)];
        assert(files.len == 0 or files.len == vir.decls().len);
        var ns: std.ArrayList(Row(Inst.Nature)) = .empty;
        var ds: std.ArrayList(Row(Inst.Discipline)) = .empty;
        for (vir.decls(), 0..) |d, k| {
            const src: ?u32 = if (files.len == 0) null else files[k];
            switch (d.kind) {
                .nature => try ns.append(s.arena, .{ .inst = d.inst, .p = decl.payloadOf(vir, Inst.Nature, d.inst), .src = src }),
                .discipline => try ds.append(s.arena, .{ .inst = d.inst, .p = decl.payloadOf(vir, Inst.Discipline, d.inst), .src = src }),
                else => {}, // else: no nature rule reads another unit
            }
        }
        return .{ .file = file, .vir = vir, .natures = ns.items, .discs = ds.items, .annex_d_included = zcu.files.items(.annex_d_included)[@backingInt(file)] };
    }

    /// The first nature named `name`, or null.
    fn nature(t: *const Table, name: Vir.String) ?Inst.Nature {
        for (t.natures) |n| if (n.p.name == name) return n.p;
        return null;
    }

    /// The last discipline named `name`, or null.
    fn discipline(t: *const Table, name: Vir.String) ?Inst.Discipline {
        var k = t.discs.len;
        while (k > 0) {
            k -= 1;
            if (t.discs[k].p.name == name) return t.discs[k].p;
        }
        return null;
    }

    /// The nature discipline `d` binds to `half`, or `.empty`.
    fn bound(t: *const Table, d: Inst.Discipline, half: Half) Vir.String {
        for (t.vir.list(Inst.DisciplineItem, d.items)) |it| if (it.kind == half.binding()) return it.name;
        return .empty;
    }

    /// A nature's parent nature: its `parent`, or the nature the parent
    /// discipline binds to the named half; `.empty` for a base nature.
    fn parentNature(t: *const Table, n: Inst.Nature) Vir.String {
        if (n.parent == .empty) return .empty;
        const half = Half.of(n) orelse return n.parent;
        const d = t.discipline(n.parent) orelse return .empty;
        return t.bound(d, half);
    }

    /// §3.11.1 the base nature `name` derives from; `.empty` when no
    /// nature has the name.
    fn base(t: *const Table, name: Vir.String) Vir.String {
        var want = name;
        for (0..hops_max) |hop| {
            const n = t.nature(want) orelse return if (hop == 0) .empty else want;
            const p = t.parentNature(n);
            if (p == .empty) return want;
            want = p;
        }
        return want;
    }

    /// §3.6.1.1 attribute `attr` of nature `name` or of its parents (a
    /// discipline-half parent's §3.6.2.3 override first), or null.
    fn attr(t: *const Table, name: Vir.String, attr_name: []const u8) ?Vir.Body {
        const vir = t.vir;
        var want = name;
        for (0..hops_max) |_| {
            if (want == .empty) return null;
            const n = t.nature(want) orelse return null;
            for (vir.list(Inst.Attr, n.attrs)) |a| if (std.mem.eql(u8, vir.string(a.name), attr_name)) return a.value;
            if (n.parent == .empty) return null;
            const half = Half.of(n) orelse {
                want = n.parent;
                continue;
            };
            const d = for (t.discs) |x| {
                if (x.p.name == n.parent) break x.p;
            } else return null;
            want = t.bound(d, half);
            if (want == .empty) return null;
            var over: ?Vir.Body = null;
            for (vir.list(Inst.DisciplineItem, d.items)) |it| {
                if (it.kind == half.override() and std.mem.eql(u8, vir.string(it.name), attr_name)) over = it.value;
            }
            if (over) |v| return v;
        }
        return null;
    }
};

const Half = enum {
    potential,
    flow,

    fn of(n: Inst.Nature) ?Half {
        return switch (n.flags.parent_kind) {
            .none => null,
            .potential => .potential,
            .flow => .flow,
        };
    }
    fn binding(h: Half) @FieldType(Inst.DisciplineItem, "kind") {
        return if (h == .potential) .potential else .flow;
    }
    fn override(h: Half) @FieldType(Inst.DisciplineItem, "kind") {
        return if (h == .potential) .potential_attr else .flow_attr;
    }
};

/// What an attribute's value body holds: a name, a string literal, or
/// another expression.
const Value = union(enum) { name: Vir.String, string, other };

/// Judges every file's natures and disciplines.
pub fn check(s: *Sema) Allocator.Error!void {
    for (0..s.zcu.files.len) |f| {
        const file: Zcu.File.Index = @fromBackingInt(@intCast(f));
        var t: Table = try .init(s, file);
        try disciplines(s, &t);
        try natures(s, &t);
        try unique(s, &t);
    }
}

// ---- private ----

fn Row(comptime T: type) type {
    return struct { inst: Inst.Index, p: T, src: ?u32 };
}

fn valueOf(vir: *const Vir, b: Vir.Body) Value {
    const body = vir.body(b);
    if (body.len == 0) return .other;
    const last = body[body.len - 1];
    return switch (vir.instructions.items(.tag)[@backingInt(last)]) {
        .str_ref => .{ .name = vir.instructions.items(.data)[@backingInt(last)].str_tok.start },
        .str => .string,
        else => .other, // else: an expression, folded by `constant`
    };
}

/// Whether body `b` folds with no parameter in scope (§3.6.1.3 "shall be
/// constant").
fn constant(s: *Sema, vir: *const Vir, b: Vir.Body) Allocator.Error!bool {
    var env: eval.Env = try .init(s.gpa, s.arena, &s.zcu.intern_pool, vir, &.{});
    defer env.deinit();
    return (try env.body(b)) != null;
}

/// §3.6.2 each discipline's bindings and overrides.
fn disciplines(s: *Sema, t: *const Table) Allocator.Error!void {
    const vir = t.vir;
    for (t.discs) |row| {
        const d = row.p;
        const name = vir.string(d.name);
        const src = row.inst.toRef();
        const potential = t.bound(d, .potential);
        const flow = t.bound(d, .flow);
        // §3.6.2.1 "Conservative disciplines shall not have the same nature
        // specified for both the potential and the flow."
        if (potential != .empty and potential == flow) try s.fail(.E0338, t.file, src, "`{s}` binds `{s}` to both its potential and its flow", .{ name, vir.string(potential) });
        // §3.6.2.2 "an error for a discipline to have a domain binding of
        // discrete if it has nature bindings".
        const discrete = for (vir.list(Inst.DisciplineItem, d.items)) |it| {
            if (it.kind == .domain) break std.mem.eql(u8, vir.string(it.name), "discrete");
        } else false;
        if (discrete and (potential != .empty or flow != .empty)) try s.fail(.E0339, t.file, src, "`{s}` declares `domain discrete` and binds a nature", .{name});
        // §3.6.2.1 / A.1.7 a binding names a declared nature.
        for ([_]Vir.String{ potential, flow }, [_][]const u8{ "potential", "flow" }) |b, half| {
            if (b != .empty and t.base(b) == .empty) try s.fail(.E0378, t.file, src, "`{s}` binds `{s}` as its {s}, and no nature `{s}` is declared", .{ name, vir.string(b), half, vir.string(b) });
        }
        // §3.6.2.5 an override needs its bound nature to define the attribute.
        for (vir.list(Inst.DisciplineItem, d.items)) |it| {
            const half: Half = switch (it.kind) {
                .potential_attr => .potential,
                .flow_attr => .flow,
                .potential, .flow, .domain, .attr => continue,
            };
            const b = if (half == .potential) potential else flow;
            if (b == .empty) {
                try s.fail(.E0370, t.file, src, "`{t}.{s}` in `{s}`, which binds no {t} nature", .{ half, vir.string(it.name), name, half });
            } else if (t.attr(b, vir.string(it.name)) == null) {
                try s.fail(.E0370, t.file, src, "`{t}.{s}` in `{s}`: the bound nature `{s}` does not define `{s}`", .{ half, vir.string(it.name), name, vir.string(b), vir.string(it.name) });
            }
        }
        // §3.6.2.7 a discipline's own attributes: unique and constant.
        const items = vir.list(Inst.DisciplineItem, d.items);
        for (items, 0..) |it, k| {
            if (it.kind != .attr) continue;
            for (items[0..k]) |prev| if (prev.kind == .attr and prev.name == it.name) {
                try s.fail(.E0343, t.file, src, "`{s}` is already an attribute of discipline `{s}`", .{ vir.string(it.name), name });
                break;
            };
            if (!try constant(s, vir, it.value)) try s.fail(.E0340, t.file, src, "`{s}` of discipline `{s}` is not a constant expression", .{ vir.string(it.name), name });
        }
    }
}

/// §3.6.1 each nature's attributes, and §3.6.1.2's idt_nature/ddt_nature.
fn natures(s: *Sema, t: *const Table) Allocator.Error!void {
    const vir = t.vir;
    for (t.natures) |row| {
        const n = row.p;
        const name = vir.string(n.name);
        const src = row.inst.toRef();
        const attrs = vir.list(Inst.Attr, n.attrs);
        var has: struct { abstol: bool = false, access: bool = false, units: bool = false } = .{};
        for (attrs, 0..) |a, k| {
            const an = vir.string(a.name);
            // §3.6.1.3 "The name of the attribute shall be unique".
            for (attrs[0..k]) |prev| if (prev.name == a.name) {
                try s.fail(.E0343, t.file, src, "`{s}` is already an attribute of `{s}`", .{ an, name });
                break;
            };
            const v = valueOf(vir, a.value);
            if (std.mem.eql(u8, an, "access") or std.mem.eql(u8, an, "idt_nature") or std.mem.eql(u8, an, "ddt_nature")) {
                // §3.6.1.2 "an identifier (by name, not as a string)".
                if (v != .name) try s.fail(.E0340, t.file, src, "`{s}` of `{s}` must be an identifier, not a value", .{ an, name });
            } else if (std.mem.eql(u8, an, "units")) {
                if (v != .string) try s.fail(.E0340, t.file, src, "`units` of `{s}` must be a string", .{name});
            } else if (!try constant(s, vir, a.value)) {
                try s.fail(.E0340, t.file, src, "`{s}` of `{s}` is not a constant expression", .{ an, name });
            }
            if (std.mem.eql(u8, an, "abstol")) has.abstol = true;
            if (std.mem.eql(u8, an, "access")) has.access = true;
            if (std.mem.eql(u8, an, "units")) has.units = true;
        }
        if (n.parent == .empty) {
            // §3.6.1.2: abstol, access and units are each "required for all
            // base natures".
            const missing: ?[]const u8 = if (!has.abstol) "abstol" else if (!has.access) "access" else if (!has.units) "units" else null;
            if (missing) |m| try s.fail(.E0332, t.file, src, "`{s}` has no `{s}`; or derive it from a base nature: `nature {s} : <parent>;`", .{ name, m, name });
        } else {
            // §3.6.1.2 a derived nature may not change units or access.
            if (has.units) try s.fail(.E0333, t.file, src, "`{s}`", .{name});
            if (has.access) try s.fail(.E0334, t.file, src, "`{s}`", .{name});
        }
        for ([_][]const u8{ "idt_nature", "ddt_nature" }) |which| try derivNature(s, t, n, src, which);
    }
}

/// §3.6.1.2 `idt_nature`/`ddt_nature` "shall be the name ... of a nature
/// which is defined elsewhere", and a derived nature's override "shall be
/// related (share the same base nature) to the nature the parent uses"
/// (E0341 and E0374).
fn derivNature(s: *Sema, t: *const Table, n: Inst.Nature, src: Inst.Ref, which: []const u8) Allocator.Error!void {
    const vir = t.vir;
    const code: vams.Diag.Code = if (which[0] == 'i') .E0341 else .E0374;
    const own = for (vir.list(Inst.Attr, n.attrs)) |a| {
        if (std.mem.eql(u8, vir.string(a.name), which)) break a;
    } else return;
    // A value that is no name is E0340's report.
    const target = switch (valueOf(vir, own.value)) {
        .name => |x| x,
        .string, .other => return,
    };
    const target_base = t.base(target);
    if (target_base == .empty) return s.fail(code, t.file, src, "`{s}` is not a declared nature", .{vir.string(target)});
    // The nature the parent uses: its own or inherited value, else itself.
    const parent = t.parentNature(n);
    if (parent == .empty) return;
    const inherited = if (t.attr(parent, which)) |v| switch (valueOf(vir, v)) {
        .name => |x| x,
        .string, .other => return,
    } else parent;
    const inherited_base = t.base(inherited);
    if (inherited_base == .empty or inherited_base == target_base) return;
    try s.fail(code, t.file, src, "`{s}` is not related to `{s}`", .{ vir.string(target), vir.string(inherited) });
}

/// §3.13.1/§3.13.2 the uniqueness rules, within one source file (and the
/// access rule over the prelude only when the source includes annex D.1,
/// VD-096). Not judged when the files are unknown.
fn unique(s: *Sema, t: *const Table) Allocator.Error!void {
    const vir = t.vir;
    for (t.natures, 0..) |a, k| {
        const fa = a.src orelse return;
        // §3.13.2 "the access function of each base nature shall be unique".
        if (a.p.parent == .empty and (fa != 0 or t.annex_d_included)) if (accessOf(t, a.p)) |acc| {
            for (t.natures[k + 1 ..]) |b| {
                if (b.p.parent != .empty or b.p.name == a.p.name) continue;
                if (accessOf(t, b.p) != acc) continue;
                try s.fail(.E0335, t.file, b.inst.toRef(), "`{s}` and `{s}` both access `{s}`", .{ vir.string(a.p.name), vir.string(b.p.name), vir.string(acc) });
            }
        };
        // §3.6.1 a nature declared twice in one file.
        for (t.natures[k + 1 ..]) |b| if (b.p.name == a.p.name and b.src == fa)
            try s.fail(.E0342, t.file, b.inst.toRef(), "nature `{s}` is already declared", .{vir.string(b.p.name)});
        // §3.13.1 natures and disciplines share one scope.
        for (t.discs) |d| if (d.p.name == a.p.name and d.src == fa)
            try s.fail(.E0336, t.file, d.inst.toRef(), "`{s}` is already a nature", .{vir.string(d.p.name)});
    }
    for (t.discs, 0..) |a, k| for (t.discs[k + 1 ..]) |b| {
        if (b.p.name == a.p.name and b.src != null and b.src == a.src)
            try s.fail(.E0342, t.file, b.inst.toRef(), "discipline `{s}` is already declared", .{vir.string(b.p.name)});
    };
}

/// A nature's own `access` name, or null.
fn accessOf(t: *const Table, n: Inst.Nature) ?Vir.String {
    for (t.vir.list(Inst.Attr, n.attrs)) |a| if (std.mem.eql(u8, t.vir.string(a.name), "access")) return switch (valueOf(t.vir, a.value)) {
        .name => |x| x,
        .string, .other => null,
    };
    return null;
}
