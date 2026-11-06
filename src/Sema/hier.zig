//! Hierarchical names (the old `analog/expr_name.zig` `lowerHierIdent` and
//! `analog_op.natureAttrRef`): a `field` chain in, what it names out. A
//! §5.5.3 `net.potential.attr` (or `.flow.`) is its nature's attribute, a
//! constant; any other path is §6.7's, spelled out (`x1.p`, `blk[2].u.r`)
//! and looked up from the reading instance up through each instance above
//! it, the root's last (§6.2.1 "priority to the local scope", §6.7.1's
//! upward reference): an instance's declaration or a §5.3.2 named block's
//! local. `$root` and the root module's own name open an absolute path.
//! Cites: VAMS-2023 §3.6.1, §3.6.2, §5.3.2, §5.5.3, §6.2.1, §6.7, §6.7.1.
//!
//! Contents:
//! - `pub const Hit = union(enum)`
//! - `pub fn resolve(s: *Sema, b: *Block, r: Inst.Ref, src: Inst.Ref) Allocator.Error!?Hit`
//! - `pub fn isBranch(s: *Sema, b: *Block, r: Inst.Ref) Allocator.Error!bool`
//! - `pub fn natureAttrOf(s: *Sema, name: []const u8, attr: []const u8, depth: u32) Allocator.Error!?eval.Const`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const eval = @import("eval.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Block = Sema.Block;
const Unit = Sema.Unit;

/// What a hierarchical name names.
pub const Hit = union(enum) {
    /// A declaration of `unit`'s module.
    bind: struct { unit: *Unit, bind: Sema.Bind },
    /// A §5.3.2 named block's local.
    local: Sema.Slot,
    /// A §5.5.3 nature attribute's value.
    attr: eval.Const,
    /// A §3.4.7 aliasparam (no value: E0373 at the read).
    alias,
};

/// The deepest `field` chain followed (a path's length).
const parts_max: u32 = 256;

/// What the `field` chain `r` names; null after a diagnostic (E0901 for a
/// path that names nothing, E0359 for an attribute §5.5.3 bars).
pub fn resolve(s: *Sema, b: *Block, r: Inst.Ref, src: Inst.Ref) Allocator.Error!?Hit {
    const unit = b.unit;
    var parts: std.ArrayList([]const u8) = .empty;
    if (!try pathOf(s, unit, r, &parts, 0)) {
        try s.fail(.E0512, unit.file, src, "a hierarchical name of this shape is not lowered by Sema yet", .{});
        return null;
    }
    const failed = s.zcu.failed.len;
    if (try natureAttr(s, b, parts.items, src)) |hit| return hit;
    if (s.zcu.failed.len != failed) return null;
    if (try find(s, unit, parts.items)) |hit| {
        // §3.4.7 "an aliasparam ... shall not be used in an expression".
        if (hit == .alias) {
            try s.fail(.E0373, unit.file, src, "`{s}` is an alias; reference the original parameter", .{try std.mem.join(s.arena, ".", parts.items)});
            return null;
        }
        return hit;
    }
    try s.fail(.E0901, unit.file, src, "`{s}` names nothing in the elaborated design", .{try std.mem.join(s.arena, ".", parts.items)});
    return null;
}

/// Whether the path `r` names a §3.12 branch (without a diagnostic when
/// it names nothing).
pub fn isBranch(s: *Sema, b: *Block, r: Inst.Ref) Allocator.Error!bool {
    var parts: std.ArrayList([]const u8) = .empty;
    if (!try pathOf(s, b.unit, r, &parts, 0)) return false;
    const hit = (try find(s, b.unit, parts.items)) orelse return false;
    return hit == .bind and hit.bind.bind == .branch;
}

/// Nature `name`'s attribute `attr`, or its parent's (§3.6.1.2).
pub fn natureAttrOf(s: *Sema, name: []const u8, attr: []const u8, depth: u32) Allocator.Error!?eval.Const {
    if (depth > parts_max or name.len == 0) return null;
    const zcu = s.zcu;
    const d = zcu.natures.get(try zcu.intern_pool.getString(s.gpa, name)) orelse return null;
    const vir = zcu.fileVir(d.file);
    const n = decl.payloadOf(vir, Inst.Nature, zcu.declRow(d).inst);
    for (vir.list(Inst.Attr, n.attrs)) |a| if (std.mem.eql(u8, vir.string(a.name), attr)) return foldIn(s, vir, a.value);
    if (n.parent == .empty) return null;
    const parent = vir.string(n.parent);
    if (n.flags.parent_kind == .none) return natureAttrOf(s, parent, attr, depth + 1);
    // `nature n : disc.potential`: the discipline's nature of that half.
    const dd = zcu.disciplines.get(try zcu.intern_pool.getString(s.gpa, parent)) orelse return null;
    const dvir = zcu.fileVir(dd.file);
    const want: @FieldType(Inst.DisciplineItem, "kind") = if (n.flags.parent_kind == .potential) .potential else .flow;
    const over: @FieldType(Inst.DisciplineItem, "kind") = if (n.flags.parent_kind == .potential) .potential_attr else .flow_attr;
    const items = dvir.list(Inst.DisciplineItem, decl.payloadOf(dvir, Inst.Discipline, zcu.declRow(dd).inst).items);
    // §3.6.1.1 the parent is the discipline's half as declared, its
    // §3.6.2.3 override of the attribute included.
    for (items) |item| if (item.kind == over and std.mem.eql(u8, dvir.string(item.name), attr)) return foldIn(s, dvir, item.value);
    for (items) |item| if (item.kind == want) return natureAttrOf(s, dvir.string(item.name), attr, depth + 1);
    return null;
}

// ---- private ----

/// The §6.7 path `parts` looked up from `unit` up to the root, or null.
fn find(s: *Sema, unit: *Unit, parts: []const []const u8) Allocator.Error!?Hit {
    var p = parts;
    // `$root.` and the root module's own name (unless a local of the root
    // is so named) open a path from the root.
    const root = &s.units.items[0];
    const root_name = root.vir.string(root.vir.decls()[@backingInt(s.zcu.instances.items(.module)[0].index)].name);
    var absolute = false;
    if (p.len > 1 and std.mem.eql(u8, p[0], "$root")) {
        p = p[1..];
        absolute = true;
    }
    if (p.len > 1 and std.mem.eql(u8, p[0], root_name) and (absolute or findDecl(unit, p[0]) == null)) {
        p = p[1..];
        absolute = true;
    }
    const tail = try std.mem.join(s.arena, ".", p);
    var scope: ?*Unit = if (absolute) root else unit;
    while (scope) |u| : (scope = parentOf(s, u)) {
        const flat = try std.fmt.allocPrint(s.arena, "{s}{s}", .{ u.prefix, tail });
        if (try lookup(s, flat)) |hit| return hit;
    }
    return null;
}

/// Appends `r`'s path, root first: each `field` a part, a constant `[k]`
/// on the part it selects. False for any other shape.
fn pathOf(s: *Sema, unit: *Unit, r: Inst.Ref, out: *std.ArrayList([]const u8), depth: u32) Allocator.Error!bool {
    if (depth > parts_max) return false;
    const vir = unit.vir;
    const i = r.toIndex() orelse return false;
    const data = vir.instructions.items(.data)[@backingInt(i)];
    switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .field => {
            const f = decl.payloadOf(vir, Inst.Field, i);
            if (!try pathOf(s, unit, f.operand, out, depth + 1)) return false;
            try out.append(s.arena, vir.string(f.name));
        },
        .elem => {
            const x = decl.payloadOf(vir, Inst.Bin, i);
            if (!try pathOf(s, unit, x.lhs, out, depth + 1)) return false;
            const k = ((try decl.foldRef(s, unit, x.rhs)) orelse return false).asIntExact() orelse return false;
            const last = &out.items[out.items.len - 1];
            last.* = try std.fmt.allocPrint(s.arena, "{s}[{d}]", .{ last.*, k });
        },
        .decl_ref => try out.append(s.arena, vir.string(decl.nameOf(vir, decl.canonical(vir, data.decl_tok.decl)))),
        .str_ref => try out.append(s.arena, vir.string(data.str_tok.start)),
        else => return false, // else: a path is names and constant selects
    }
    return true;
}

/// The unit of `u`'s parent instance; null for the root.
fn parentOf(s: *Sema, u: *const Unit) ?*Unit {
    const parent = s.zcu.instances.items(.parent)[@backingInt(u.instance)];
    if (parent == .none) return null;
    for (s.units.items) |*p| if (p.instance == parent) return p;
    return null;
}

/// The declaration or named-block local the flat name `flat` (`x1.p`)
/// spells, or null.
fn lookup(s: *Sema, flat: []const u8) Allocator.Error!?Hit {
    if (s.block_locals.get(flat)) |slot| return .{ .local = slot };
    const dot = std.mem.findScalarLast(u8, flat, '.');
    const prefix = if (dot) |d| flat[0 .. d + 1] else "";
    const name = if (dot) |d| flat[d + 1 ..] else flat;
    for (s.units.items) |*u| {
        if (!std.mem.eql(u8, u.prefix, prefix)) continue;
        const d = findDecl(u, name) orelse return null;
        if (u.vir.instructions.items(.tag)[@backingInt(d)] == .aliasparam) return .alias;
        const bind = u.binds.get(d) orelse return null;
        return .{ .bind = .{ .unit = u, .bind = bind } };
    }
    return null;
}

/// The canonical declaration of `name` among `unit`'s module items.
fn findDecl(unit: *const Unit, name: []const u8) ?Inst.Index {
    const vir = unit.vir;
    for ([_]Vir.Body{ unit.module.ports, unit.module.body }) |body| for (vir.body(body)) |i| {
        switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            .io, .net, .variable, .param, .aliasparam, .branch, .instance, .gen_block => {},
            else => continue, // else: declares no name a path reaches
        }
        if (std.mem.eql(u8, vir.string(decl.nameOf(vir, i)), name)) return decl.canonical(vir, i);
    };
    return null;
}

/// §5.5.3 `net.potential.attr`, `net.flow.attr` (a branch's: its
/// terminals' discipline): the attribute's value through the net's
/// discipline (its override first) and nature (its parents next). Null when
/// `parts` is no such reference.
fn natureAttr(s: *Sema, b: *Block, parts: []const []const u8, src: Inst.Ref) Allocator.Error!?Hit {
    if (parts.len != 3) return null;
    const half: u1 = if (std.mem.eql(u8, parts[1], "potential")) 0 else if (std.mem.eql(u8, parts[1], "flow")) 1 else return null;
    const d = findDecl(b.unit, parts[0]) orelse return null;
    const node: Sema.Bind = b.unit.binds.get(d) orelse return null;
    const row = switch (node) {
        .node => |n| n,
        .vector => |v| b.unit.vec_rows.items[v.first],
        .branch => |br| blk: {
            const x = s.device.branches.get(@backingInt(br) - 1);
            break :blk if (x.hi == .ground) x.lo else x.hi;
        },
        else => return null,
    };
    if (row == .ground) return null;
    const attr = parts[2];
    // "shall not be used for the access, ddt_nature, or idt_nature attributes".
    for ([_][]const u8{ "access", "ddt_nature", "idt_nature" }) |banned| if (std.mem.eql(u8, attr, banned)) {
        try s.fail(.E0359, b.unit.file, src, "`{s}`", .{attr});
        return null;
    };
    const zcu = s.zcu;
    // §7.2.4 a net reads its own module's discipline (declared or resolved),
    // not that of the node it shares with its parent.
    const local: InternPool.String = if (node == .branch) .empty else try @import("net.zig").netDiscipline(s, b.unit, d);
    const disc = zcu.disciplines.get(if (local != .empty) local else s.device.nodes.items(.discipline)[@backingInt(row)]) orelse return null;
    const vir = zcu.fileVir(disc.file);
    const dp = decl.payloadOf(vir, Inst.Discipline, zcu.declRow(disc).inst);
    var nature: []const u8 = "";
    for (vir.list(Inst.DisciplineItem, dp.items)) |item| {
        const kind_half: ?u1 = switch (item.kind) {
            .potential, .potential_attr => 0,
            .flow, .flow_attr => 1,
            .domain, .attr => null,
        };
        if (kind_half != half) continue;
        if (item.kind == .potential or item.kind == .flow) nature = vir.string(item.name);
        // §3.6.2.3 a discipline's override of its nature's attribute.
        if ((item.kind == .potential_attr or item.kind == .flow_attr) and std.mem.eql(u8, vir.string(item.name), attr))
            if (try foldIn(s, vir, item.value)) |c| return .{ .attr = c };
    }
    if (try natureAttrOf(s, nature, attr, 0)) |c| return .{ .attr = c };
    return null;
}

/// The constant value of body `b` of file `vir` (no parameters in scope).
fn foldIn(s: *Sema, vir: *const Vir, b: Vir.Body) Allocator.Error!?eval.Const {
    var env: eval.Env = try .init(s.gpa, s.arena, &s.zcu.intern_pool, vir, &.{});
    defer env.deinit();
    return env.body(b);
}
