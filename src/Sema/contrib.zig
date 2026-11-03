//! Signal access and contributions (the old `analog/expr_access.zig`,
//! `branch.zig`, `accum.zig`, `contrib.zig`, `reactive.zig`): an access
//! function call (`V(a, b)`, `I(br)`) in, its probe out; a `<+` in, its
//! value added to its target's slots out. A target is (access, branch,
//! node pair), the pair ordered by row with a sign (§1.3.1.2: `I(n, p)` is
//! `-I(p, n)`); one row per target (§5.6.1.3 accumulation), its resistive
//! and reactive (§5.6.1.2, a linear `ddt` term's argument) sums in slots,
//! and a flag slot set to 1 when a `<+` runs.
//! Cites: VAMS-2023 §1.3.1.2, §3.6.2, §4.4, §4.4.1, §5.4.1, §5.4.2,
//! §5.5.1, §5.6, §5.6.1.2, §5.6.1.3.
//!
//! Contents:
//! - `pub const Target = struct`
//! - `pub fn accessOf(s: *Sema, b: *Block, name: []const u8) Allocator.Error!?Device.Access`
//! - `pub fn access(s: *Sema, b: *Block, name: []const u8, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value`
//! - `pub fn contribute(s: *Sema, b: *Block, x: Inst.Bin, src: Inst.Ref) Allocator.Error!void`
//! - `pub fn probe(s: *Sema, n: Node.Index) Allocator.Error!Air.Inst.Ref`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const expr = @import("expr.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Device = Air.Device;
const Node = Device.Node;
const Block = Sema.Block;
const Value = Sema.Value;
const Ref = Air.Inst.Ref;

/// What an access names: the quantity, the branch and its ordered pair,
/// and whether the source spelled the pair reversed.
pub const Target = struct {
    access: Device.Access,
    branch: Device.Branch.Index,
    hi: Node.Index,
    lo: Node.Index,
    neg: bool,
};

/// A `<+` right-hand side split into its resistive and reactive sums and
/// the charge sites of its `ddt` terms.
const Split = struct {
    resist: ?Ref = null,
    react: ?Ref = null,
    sites: std.ArrayList(Site) = .empty,
};
const Site = struct { charge: Ref, negate: bool };

/// One linear `ddt` term: its argument `b` and the factor on it.
const Reactive = struct { b: Ref, coeff: ?Ref = null, coeff_nonconst: bool = false };

/// The access `name` is under any discipline (§3.6.2: a nature's `access`
/// attribute), or null when no nature names it.
pub fn accessOf(s: *Sema, b: *Block, name: []const u8) Allocator.Error!?Device.Access {
    _ = b;
    try loadDisciplines(s);
    return s.access_kind.get(name);
}

/// §4.4 `name(args)` read as a value.
pub fn access(s: *Sema, b: *Block, name: []const u8, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value {
    const t = (try target(s, b, name, args, src)) orelse return expr.poison;
    switch (t.access) {
        .potential => {
            const hi = try probe(s, t.hi);
            if (t.lo == .ground) return .{ .ref = if (t.neg) try expr.unOp(s, b, .fneg, hi) else hi, .ty = .real };
            const lo = try probe(s, t.lo);
            return .{ .ref = if (t.neg) try expr.binOp(s, b, .fsub, lo, hi) else try expr.binOp(s, b, .fsub, hi, lo), .ty = .real };
        },
        .flow => {
            // §5.6.6 inside a `<+` to the same branch, a flow read is the
            // implicit form: the unknown. Else, once a flow source is on the
            // branch (and no potential source of this instance), it is the
            // value retained there (§5.4.2.2, §5.6.1.2).
            const implicit = if (s.contrib_target) |ct| ct.access == .flow and ct.hi == t.hi and ct.lo == t.lo and ct.branch == t.branch else false;
            if (!implicit and !potentialSourceHere(s, b, t)) if (s.contrib_rows.get(.{ .access = .flow, .branch = t.branch, .hi = t.hi, .lo = t.lo })) |row| {
                if (s.react_written.contains(row)) {
                    try s.fail(.E0512, b.unit.file, src, "a read of a reactive flow source is not lowered by Sema yet", .{});
                    return expr.poison;
                }
                const slot = s.device.contributions.items(.resist)[@backingInt(row)];
                const v = try s.addInst(b, .{ .tag = .load, .data = .{ .un_op = .fromIndex(slot) } });
                return .{ .ref = if (t.neg) try expr.unOp(s, b, .fneg, v) else v, .ty = .real };
            };
            const u = try flowUnknown(s, t.hi, t.lo);
            const v = try probe(s, u);
            return .{ .ref = if (t.neg) try expr.unOp(s, b, .fneg, v) else v, .ty = .real };
        },
    }
}

/// §5.6 `lhs <+ rhs`.
pub fn contribute(s: *Sema, b: *Block, x: Inst.Bin, src: Inst.Ref) Allocator.Error!void {
    const vir = b.unit.vir;
    const file = b.unit.file;
    const lhs = x.lhs.toIndex() orelse return;
    if (vir.instructions.items(.tag)[@backingInt(lhs)] != .call) return s.fail(.E0408, file, src, "", .{});
    const c = decl.payloadOf(vir, Inst.Call, lhs);
    const callee = c.callee.toIndex() orelse return;
    if (vir.instructions.items(.tag)[@backingInt(callee)] != .str_ref) return s.fail(.E0408, file, src, "", .{});
    const name = vir.string(vir.instructions.items(.data)[@backingInt(callee)].str_tok.start);
    if (b.loop != null) return s.fail(.E0426, file, src, "", .{});
    const t = (try target(s, b, name, vir.list(Inst.Ref, c.args), src)) orelse return;
    const row = try rowOf(s, b, t);
    var split: Split = .{};
    s.contrib_target = t;
    defer s.contrib_target = null;
    try splitTerm(s, b, x.rhs, false, &split);
    if (split.react != null) try s.react_written.put(s.arena, row, {});
    const slots = s.device.contributions.get(@backingInt(row));
    inline for (.{ "resist", "react" }) |half| if (@field(split, half)) |v0| {
        const v = if (t.neg) try expr.unOp(s, b, .fneg, v0) else v0;
        const slot = @field(slots, half);
        const old = try s.addInst(b, .{ .tag = .load, .data = .{ .un_op = .fromIndex(slot) } });
        const sum = try expr.binOp(s, b, .fadd, old, v);
        _ = try s.addInst(b, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slot), .rhs = sum } } });
    };
    for (split.sites.items) |site| {
        const slot = try decl.addAlloc(s, .real);
        _ = try s.addInst(b, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slot), .rhs = site.charge } } });
        try s.device.charge_sites.append(s.gpa, .{ .contrib = row, .sign = if (site.negate != t.neg) -1.0 else 1.0, .slot = slot });
    }
    _ = try s.addInst(b, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slots.wrote), .rhs = .fromIntern(.one_real) } } });
}

/// §4.4 the potential of node `n`: one `probe` per row, in the prologue;
/// ground is 0 (§1.3.1.1).
pub fn probe(s: *Sema, n: Node.Index) Allocator.Error!Ref {
    if (n == .ground) return .fromIntern(.zero_real);
    assert(@backingInt(n) < s.device.nodes.len);
    const gop = try s.probes.getOrPut(s.arena, n);
    if (gop.found_existing) return gop.value_ptr.*;
    const i = try s.air.addInst(s.gpa, .{ .tag = .probe, .data = .{ .ty_index = .{ .ty = .real_type, .index = @backingInt(n) } } });
    try s.prologue.append(s.arena, i);
    gop.value_ptr.* = .fromIndex(i);
    return gop.value_ptr.*;
}

// ---- private ----

/// Fills `s.access_kind` and `s.disc_access` from every discipline once.
pub fn loadDisciplines(s: *Sema) Allocator.Error!void {
    if (s.disciplines_loaded) return;
    s.disciplines_loaded = true;
    const zcu = s.zcu;
    var it = zcu.disciplines.iterator();
    while (it.next()) |e| {
        const vir = zcu.fileVir(e.value_ptr.file);
        const d = decl.payloadOf(vir, Inst.Discipline, zcu.declRow(e.value_ptr.*).inst);
        var pair: [2][]const u8 = .{ "", "" };
        for (vir.list(Inst.DisciplineItem, d.items)) |item| {
            const half: usize = switch (item.kind) {
                .potential => 0,
                .flow => 1,
                else => continue, // else: a domain or an attribute binds no nature
            };
            pair[half] = (try natureAccess(s, vir.string(item.name), 0)) orelse "";
        }
        // A copy: the pool's bytes move as it grows.
        try s.disc_access.put(s.arena, try s.arena.dupe(u8, zcu.intern_pool.stringToSlice(e.key_ptr.*)), pair);
        for (pair, [_]Device.Access{ .potential, .flow }) |a, k| if (a.len != 0) {
            const gop = try s.access_kind.getOrPut(s.arena, a);
            if (!gop.found_existing) gop.value_ptr.* = k else if (gop.value_ptr.* != k) try s.access_both.put(s.arena, a, {});
        };
    }
}

/// A nature's `access` attribute, its parent's when it has none.
fn natureAccess(s: *Sema, name: []const u8, depth: u32) Allocator.Error!?[]const u8 {
    if (depth > 64) return null;
    const zcu = s.zcu;
    const d = zcu.natures.get(try zcu.intern_pool.getString(s.gpa, name)) orelse return null;
    const vir = zcu.fileVir(d.file);
    const n = decl.payloadOf(vir, Inst.Nature, zcu.declRow(d).inst);
    for (vir.list(Inst.Attr, n.attrs)) |a| {
        if (!std.mem.eql(u8, vir.string(a.name), "access")) continue;
        const insts = vir.body(a.value);
        if (insts.len == 0) continue;
        const last = insts[insts.len - 1];
        return switch (vir.instructions.items(.tag)[@backingInt(last)]) {
            .str_ref => vir.string(vir.instructions.items(.data)[@backingInt(last)].str_tok.start),
            else => null, // else: an access is an identifier
        };
    }
    if (n.parent == .empty) return null;
    return natureAccess(s, vir.string(n.parent), depth + 1);
}

/// What `name(args)` names, ordered (`canonical`); null after a diagnostic.
fn target(s: *Sema, b: *Block, name: []const u8, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!?Target {
    const unit = b.unit;
    const vir = unit.vir;
    const global = (try accessOf(s, b, name)) orelse {
        try s.fail(.E0501, unit.file, src, "`{s}`", .{name});
        return null;
    };
    if (args.len == 0 or args.len > 2) {
        try s.fail(.E0512, unit.file, src, "`{s}` with {d} arguments", .{ name, args.len });
        return null;
    }
    const first = args[0].toIndex() orelse return null;
    if (vir.instructions.items(.tag)[@backingInt(first)] != .decl_ref) {
        try s.fail(.E0512, unit.file, src, "an access of a select or a hierarchical name is not lowered by Sema yet", .{});
        return null;
    }
    const bind = unit.binds.get(decl.canonical(vir, vir.instructions.items(.data)[@backingInt(first)].decl_tok.decl)) orelse {
        try s.fail(.E0512, unit.file, src, "an access of a name with no node", .{});
        return null;
    };
    if (bind == .branch and args.len == 1) {
        const row = s.device.branches.get(@backingInt(bind.branch) - 1);
        return canonical(accessOn(s, name, global, row.hi, row.lo), row.hi, row.lo, bind.branch);
    }
    if (bind != .node) {
        try s.fail(.E0512, unit.file, src, "an access of a vector or a non-net", .{});
        return null;
    }
    const hi = bind.node;
    const lo: Node.Index = if (args.len == 1) .ground else blk: {
        const second = args[1].toIndex() orelse return null;
        if (vir.instructions.items(.tag)[@backingInt(second)] != .decl_ref) {
            try s.fail(.E0512, unit.file, src, "an access of a select is not lowered by Sema yet", .{});
            return null;
        }
        const lb = unit.binds.get(decl.canonical(vir, vir.instructions.items(.data)[@backingInt(second)].decl_tok.decl)) orelse return null;
        if (lb != .node) return null;
        break :blk lb.node;
    };
    if (args.len == 2 and hi == lo and hi != .ground) {
        try s.fail(.E0315, unit.file, src, "`{s}` names one signal twice", .{name});
        return null;
    }
    return canonical(accessOn(s, name, global, hi, lo), hi, lo, .unnamed);
}

/// §3.6.2 the access `name` is on the discipline of the pair's non-ground node.
fn accessOn(s: *Sema, name: []const u8, global: Device.Access, hi: Node.Index, lo: Node.Index) Device.Access {
    const node = if (hi == .ground) lo else hi;
    if (node == .ground) return global;
    const dname = s.zcu.intern_pool.stringToSlice(s.device.nodes.items(.discipline)[@backingInt(node)]);
    const pair = s.disc_access.get(dname) orelse return global;
    if (std.mem.eql(u8, pair[0], name)) return .potential;
    if (std.mem.eql(u8, pair[1], name)) return .flow;
    return global;
}

/// §1.3.1.2 the pair with the lower row first, `neg` when that swapped it.
fn canonical(a: Device.Access, hi: Node.Index, lo: Node.Index, br: Device.Branch.Index) Target {
    const t: Target = if (@backingInt(hi) <= @backingInt(lo))
        .{ .access = a, .branch = br, .hi = hi, .lo = lo, .neg = false }
    else
        .{ .access = a, .branch = br, .hi = lo, .lo = hi, .neg = true };
    assert(@backingInt(t.hi) <= @backingInt(t.lo));
    return t;
}

/// §5.4.2 the unknown carrying branch (hi, lo)'s current, spelled
/// `flow(hi,lo)`; one per pair.
fn flowUnknown(s: *Sema, hi: Node.Index, lo: Node.Index) Allocator.Error!Node.Index {
    const gop = try s.flow_rows.getOrPut(s.arena, .{ hi, lo });
    if (gop.found_existing) return gop.value_ptr.*;
    const ip = &s.zcu.intern_pool;
    const name = try std.fmt.allocPrint(s.arena, "flow({s},{s})", .{ nodeName(s, hi), nodeName(s, lo) });
    const row: Node.Index = @fromBackingInt(@intCast(s.device.nodes.len));
    try s.device.nodes.append(s.gpa, .{ .name = try ip.getString(s.gpa, name), .kind = .branch_flow, .of = hi, .discipline = .empty });
    gop.value_ptr.* = row;
    return row;
}

/// Whether this instance has a potential source on `t`'s branch.
fn potentialSourceHere(s: *const Sema, b: *const Block, t: Target) bool {
    const row = s.contrib_rows.get(.{ .access = .potential, .branch = t.branch, .hi = t.hi, .lo = t.lo }) orelse return false;
    return s.contrib_units.items[@backingInt(row)] == b.unit.instance;
}

fn nodeName(s: *const Sema, n: Node.Index) []const u8 {
    if (n == .ground) return "gnd";
    return s.zcu.intern_pool.stringToSlice(s.device.nodes.items(.name)[@backingInt(n)]);
}

/// The contribution row of `t`, made on its first `<+` with its slots.
fn rowOf(s: *Sema, b: *const Block, t: Target) Allocator.Error!Device.Contribution.Index {
    const key: Sema.ContribKey = .{ .access = t.access, .branch = t.branch, .hi = t.hi, .lo = t.lo };
    const gop = try s.contrib_rows.getOrPut(s.arena, key);
    if (gop.found_existing) return gop.value_ptr.*;
    const row: Device.Contribution.Index = @fromBackingInt(@intCast(s.device.contributions.len));
    try s.device.contributions.append(s.gpa, .{
        .access = t.access,
        .kind = .direct,
        .branch = t.branch,
        .hi = t.hi,
        .lo = t.lo,
        .resist = try decl.addAlloc(s, .real),
        .react = try decl.addAlloc(s, .real),
        .wrote = try decl.addAlloc(s, .real),
    });
    try s.contrib_units.append(s.arena, b.unit.instance);
    gop.value_ptr.* = row;
    return row;
}

/// The old `reactive.splitTerm`: a sum's terms, each a linear `ddt` term
/// (into `react`, with a charge site) or a resistive one.
fn splitTerm(s: *Sema, b: *Block, r: Inst.Ref, negate: bool, out: *Split) Allocator.Error!void {
    const i = r.toIndex() orelse return;
    const vir = b.unit.vir;
    switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .add, .sub => |tag| {
            const bin = decl.payloadOf(vir, Inst.Bin, i);
            try splitTerm(s, b, bin.lhs, negate, out);
            return splitTerm(s, b, bin.rhs, if (tag == .sub) !negate else negate, out);
        },
        .pos => return splitTerm(s, b, vir.instructions.items(.data)[@backingInt(i)].un_node.operand, negate, out),
        .neg => return splitTerm(s, b, vir.instructions.items(.data)[@backingInt(i)].un_node.operand, !negate, out),
        else => {}, // else: one term
    }
    if (linearDdt(b.unit, r, 0)) {
        const t = (try reactive(s, b, r)) orelse return;
        const q = try finishReactive(s, b, t);
        try accumulate(s, b, &out.react, q, negate);
        try out.sites.append(s.arena, .{ .charge = q, .negate = negate });
        return;
    }
    const v = try expr.coerce(s, b, try expr.lower(s, b, r), .real);
    try accumulate(s, b, &out.resist, v, negate);
}

fn accumulate(s: *Sema, b: *Block, slot: *?Ref, v: Ref, negate: bool) Allocator.Error!void {
    slot.* = if (slot.*) |old|
        try expr.binOp(s, b, if (negate) .fsub else .fadd, old, v)
    else if (negate) try expr.unOp(s, b, .fneg, v) else v;
}

fn isDdt(unit: *const Sema.Unit, i: Inst.Index) bool {
    const vir = unit.vir;
    if (vir.instructions.items(.tag)[@backingInt(i)] != .call_sys) return false;
    return std.mem.eql(u8, vir.string(decl.payloadOf(vir, Inst.SysCall, i).name), "ddt");
}

fn containsDdt(unit: *const Sema.Unit, r: Inst.Ref, depth: u32) bool {
    const i = r.toIndex() orelse return false;
    if (depth > expr.depth_max) return false;
    if (isDdt(unit, i)) return true;
    const vir = unit.vir;
    return switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .pos, .neg, .not, .bit_not => containsDdt(unit, vir.instructions.items(.data)[@backingInt(i)].un_node.operand, depth + 1),
        .add, .sub, .mul, .div, .mod, .pow, .lt, .gt, .lte, .gte, .eq, .neq, .bool_and, .bool_or => blk: {
            const bin = decl.payloadOf(vir, Inst.Bin, i);
            break :blk containsDdt(unit, bin.lhs, depth + 1) or containsDdt(unit, bin.rhs, depth + 1);
        },
        .ternary => blk: {
            const t = decl.payloadOf(vir, Inst.Triple, i);
            break :blk containsDdt(unit, t.a, depth + 1) or containsDdt(unit, t.b, depth + 1) or containsDdt(unit, t.c, depth + 1);
        },
        .call_sys => for (vir.list(Inst.Ref, decl.payloadOf(vir, Inst.SysCall, i).args)) |a| {
            if (containsDdt(unit, a, depth + 1)) break true;
        } else false,
        else => false, // else: a leaf, or a construct whose ddt `reactive` never reaches
    };
}

/// The old `reactive.linearDdt`: a `ddt` on a linear spine (signs, a
/// factor, a divisor, sums of such).
fn linearDdt(unit: *const Sema.Unit, r: Inst.Ref, depth: u32) bool {
    const i = r.toIndex() orelse return false;
    if (depth > expr.depth_max) return false;
    if (isDdt(unit, i)) return true;
    const vir = unit.vir;
    return switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .pos, .neg => linearDdt(unit, vir.instructions.items(.data)[@backingInt(i)].un_node.operand, depth + 1),
        .mul => blk: {
            const bin = decl.payloadOf(vir, Inst.Bin, i);
            break :blk if (containsDdt(unit, bin.lhs, depth + 1)) !containsDdt(unit, bin.rhs, depth + 1) and linearDdt(unit, bin.lhs, depth + 1) else linearDdt(unit, bin.rhs, depth + 1);
        },
        .div => blk: {
            const bin = decl.payloadOf(vir, Inst.Bin, i);
            break :blk !containsDdt(unit, bin.rhs, depth + 1) and linearDdt(unit, bin.lhs, depth + 1);
        },
        .add, .sub => blk: {
            const bin = decl.payloadOf(vir, Inst.Bin, i);
            break :blk linearDdt(unit, bin.lhs, depth + 1) and linearDdt(unit, bin.rhs, depth + 1);
        },
        else => false, // else: no other node keeps a ddt on a linear spine
    };
}

/// The old `reactive.lowerReactive`.
fn reactive(s: *Sema, b: *Block, r: Inst.Ref) Allocator.Error!?Reactive {
    const i = r.toIndex() orelse return null;
    const vir = b.unit.vir;
    if (isDdt(b.unit, i)) {
        const args = vir.list(Inst.Ref, decl.payloadOf(vir, Inst.SysCall, i).args);
        if (args.len == 0 or args[0] == .none) {
            try s.fail(.E0502, b.unit.file, r, "", .{});
            return null;
        }
        return .{ .b = try expr.coerce(s, b, try expr.lower(s, b, args[0]), .real) };
    }
    switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .pos => return reactive(s, b, vir.instructions.items(.data)[@backingInt(i)].un_node.operand),
        .neg => {
            var t = (try reactive(s, b, vir.instructions.items(.data)[@backingInt(i)].un_node.operand)) orelse return null;
            t.coeff = if (t.coeff) |old| try expr.unOp(s, b, .fneg, old) else .fromIntern(.neg_one_real);
            return t;
        },
        .mul => {
            const bin = decl.payloadOf(vir, Inst.Bin, i);
            if (containsDdt(b.unit, bin.lhs, 0)) {
                var t = (try reactive(s, b, bin.lhs)) orelse return null;
                try mulCoeff(s, b, &t, try expr.coerce(s, b, try expr.lower(s, b, bin.rhs), .real), .fmul);
                return t;
            }
            const c = try expr.coerce(s, b, try expr.lower(s, b, bin.lhs), .real);
            var t = (try reactive(s, b, bin.rhs)) orelse return null;
            try mulCoeff(s, b, &t, c, .fmul);
            return t;
        },
        .div => {
            const bin = decl.payloadOf(vir, Inst.Bin, i);
            var t = (try reactive(s, b, bin.lhs)) orelse return null;
            try mulCoeff(s, b, &t, try expr.coerce(s, b, try expr.lower(s, b, bin.rhs), .real), .fdiv);
            return t;
        },
        else => {
            try s.fail(.E0512, b.unit.file, r, "a reactive term of this shape is not lowered by Sema yet", .{});
            return null;
        },
    }
}

fn mulCoeff(s: *Sema, b: *Block, t: *Reactive, c: Ref, tag: Air.Inst.Tag) Allocator.Error!void {
    t.coeff = if (t.coeff) |old|
        try expr.binOp(s, b, tag, old, c)
    else if (tag == .fdiv)
        try expr.binOp(s, b, .fdiv, .fromIntern(.one_real), c)
    else
        c;
    t.coeff_nonconst = t.coeff_nonconst or !coeffIsConst(s, c);
}

/// A factor a solve cannot change: a constant or a parameter.
fn coeffIsConst(s: *const Sema, c: Ref) bool {
    if (c.toInterned() != null) return true;
    const i = c.toIndex().?;
    return s.air.instructions.items(.tag)[@backingInt(i)] == .arg;
}

/// The charge `q` of a linear `ddt` term: `B` alone, `c·B` for a constant
/// factor, and the §5.6.1.2 path form `acc(c·ΔB) + c·ΔB` otherwise.
fn finishReactive(s: *Sema, b: *Block, t: Reactive) Allocator.Error!Ref {
    const c = t.coeff orelse return t.b;
    if (!t.coeff_nonconst) return expr.binOp(s, b, .fmul, c, t.b);
    const pb = try expr.unOp(s, b, .path_prev, t.b);
    const d = try expr.binOp(s, b, .fmul, c, try expr.binOp(s, b, .fsub, t.b, pb));
    return expr.binOp(s, b, .fadd, try expr.unOp(s, b, .path_acc, d), d);
}
