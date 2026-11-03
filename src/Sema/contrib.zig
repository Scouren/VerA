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
//! - `pub fn indirect(s: *Sema, b: *Block, x: Inst.Triple, src: Inst.Ref) Allocator.Error!void`
//! - `pub fn probe(s: *Sema, n: Node.Index) Allocator.Error!Air.Inst.Ref`
//! - `pub fn loadDisciplines(s: *Sema) Allocator.Error!void`
//! - `pub fn rowOf(s: *Sema, b: *const Block, t: Target) Allocator.Error!Device.Contribution.Index`
//! - `pub fn target(s: *Sema, b: *Block, name: []const u8, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!?Target`
//! - `pub const AccessCall`, `pub fn accessCall(s: *Sema, unit: *const Sema.Unit, r: Inst.Ref) Allocator.Error!?AccessCall`
//! - `pub fn nodeName(s: *const Sema, n: Node.Index) []const u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const expr = @import("expr.zig");
const hier = @import("hier.zig");
const reactive = @import("reactive.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Device = Air.Device;
const Node = Device.Node;
const Block = Sema.Block;
const Value = Sema.Value;
const Ref = Air.Inst.Ref;

/// An access function call's name and arguments (`accessCall`).
pub const AccessCall = struct { name: []const u8, args: []const Inst.Ref };

/// What an access names: the quantity, the branch and its ordered pair,
/// and whether the source spelled the pair reversed.
pub const Target = struct {
    access: Device.Access,
    branch: Device.Branch.Index,
    hi: Node.Index,
    lo: Node.Index,
    neg: bool,
};

/// The access `name` is under any discipline (§3.6.2: a nature's `access`
/// attribute), or null when no nature names it.
pub fn accessOf(s: *Sema, b: *Block, name: []const u8) Allocator.Error!?Device.Access {
    _ = b;
    try loadDisciplines(s);
    return s.access_kind.get(name);
}

/// §4.4 `name(args)` read as a value.
pub fn access(s: *Sema, b: *Block, name: []const u8, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value {
    if (b.restricted()) |ctx| {
        try s.fail(.E0421, b.unit.file, src, "not allowed in {s}", .{ctx});
        return expr.poison;
    }
    if (args.len == 1) if (try portOf(s, b, args[0], src)) |p| return portFlow(s, b, name, p, src);
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
            const u = try flowUnknown(s, b.unit, t.hi, t.lo);
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
    if (b.restricted()) |ctx| return s.fail(.E0405, file, src, "not allowed in {s}", .{ctx});
    if (b.in_event) return s.fail(.E0406, file, src, "", .{});
    if (b.loop != null) return s.fail(.E0426, file, src, "", .{});
    // §5.4.3 a port access is read-only: it measures what the world outside
    // the module drives in.
    for (vir.list(Inst.Ref, c.args)) |a| if (isPortBranch(b.unit, a)) return s.fail(.E0407, file, src, "a contribution to a port access", .{});
    const t = (try target(s, b, name, vir.list(Inst.Ref, c.args), src)) orelse return;
    // §5.6.7.2 "Once a value is indirectly assigned to a branch, it cannot
    // be contributed to using the branch contribution operator <+."
    if (indirectOn(s, t.hi, t.lo)) return s.fail(.E0409, file, src, "`({s},{s})`", .{ nodeName(s, t.hi), nodeName(s, t.lo) });
    const row = try rowOf(s, b, t);
    var split: reactive.Split = .{};
    s.contrib_target = t;
    defer s.contrib_target = null;
    try reactive.split(s, b, x.rhs, false, &split);
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

/// §5.6.7 `V(out) : probe == eqn`: "drive V(out) so that probe == eqn", a
/// row of its own (never accumulated, §5.6.7.1) whose resistive value is
/// `probe - eqn`. Not in a restricted context (E0410), an event (E0411), a
/// run-time conditional or loop (E0412); the target an access (E0413), the
/// probe an access or `ddt`/`idt`/`idtmod` of one (E0414); no `<+` on the
/// pair before it (E0415).
pub fn indirect(s: *Sema, b: *Block, x: Inst.Triple, src: Inst.Ref) Allocator.Error!void {
    const unit = b.unit;
    const file = unit.file;
    if (b.restricted()) |ctx| return s.fail(.E0410, file, src, "not allowed in {s}", .{ctx});
    if (b.in_event) return s.fail(.E0411, file, src, "", .{});
    if (b.conditional != 0 or b.loop != null) return s.fail(.E0412, file, src, "the condition is not a constant expression", .{});
    const lhs = (try accessCall(s, unit, x.a)) orelse return s.fail(.E0413, file, src, "", .{});
    if (!try indirectProbe(s, unit, x.b)) return s.fail(.E0414, file, src, "", .{});
    const t = (try target(s, b, lhs.name, lhs.args, src)) orelse return;
    for (0..s.device.contributions.len) |k| {
        const row = s.device.contributions.get(k);
        if (row.kind != .direct) continue;
        if (!((row.hi == t.hi and row.lo == t.lo) or (row.hi == t.lo and row.lo == t.hi))) continue;
        return s.fail(.E0415, file, src, "`({s},{s})`", .{ nodeName(s, t.hi), nodeName(s, t.lo) });
    }
    const p = try expr.coerce(s, b, try expr.lower(s, b, x.b), .real);
    const e = try expr.coerce(s, b, try expr.lower(s, b, x.c), .real);
    const v = try expr.binOp(s, b, .fsub, p, e);
    const row: Device.Contribution.Index = @fromBackingInt(@intCast(s.device.contributions.len));
    try s.device.contributions.append(s.gpa, .{
        .access = t.access,
        .kind = .indirect,
        .branch = t.branch,
        .hi = t.hi,
        .lo = t.lo,
        .resist = try decl.addAlloc(s, .real),
        .react = try decl.addAlloc(s, .real),
        .wrote = try decl.addAlloc(s, .real),
        .instance = decl.rowInstance(unit.instance),
        .flow = .none,
    });
    const slots = s.device.contributions.get(@backingInt(row));
    _ = try s.addInst(b, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slots.resist), .rhs = v } } });
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

/// The contribution row of `t`, made on its first `<+` with its slots.
pub fn rowOf(s: *Sema, b: *const Block, t: Target) Allocator.Error!Device.Contribution.Index {
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
        .instance = decl.rowInstance(b.unit.instance),
        .flow = .none,
    });
    gop.value_ptr.* = row;
    return row;
}

/// What `name(args)` names, ordered (`canonical`); null after a diagnostic.
pub fn target(s: *Sema, b: *Block, name: []const u8, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!?Target {
    const unit = b.unit;
    const global = (try accessOf(s, b, name)) orelse {
        try s.fail(.E0501, unit.file, src, "`{s}`", .{name});
        return null;
    };
    if (args.len == 0 or args.len > 2) {
        try s.fail(.E0512, unit.file, src, "`{s}` with {d} arguments", .{ name, args.len });
        return null;
    }
    if (args.len == 1) if (try branchOf(s, b, args[0], src)) |br| {
        const row = s.device.branches.get(@backingInt(br) - 1);
        const a = accessOn(s, name, global, row.hi, row.lo);
        if (!try accessMatches(s, b, name, a, row.hi, src)) return null;
        return canonical(a, row.hi, row.lo, br);
    };
    const hi = (try nodeOf(s, b, args[0], src)) orelse return null;
    const lo: Node.Index = if (args.len == 1) .ground else (try nodeOf(s, b, args[1], src)) orelse return null;
    const a = accessOn(s, name, global, hi, lo);
    if (!try accessMatches(s, b, name, a, hi, src)) return null;
    if (args.len == 2 and hi == lo and hi != .ground) {
        try s.fail(.E0315, unit.file, src, "`{s}` names one signal twice", .{name});
        return null;
    }
    return canonical(a, hi, lo, .unnamed);
}

/// The access function call `r` is (`V(a, b)`, `I(<p>)`): its name and its
/// arguments, or null for any other expression.
pub fn accessCall(s: *Sema, unit: *const Sema.Unit, r: Inst.Ref) Allocator.Error!?AccessCall {
    const vir = unit.vir;
    const i = r.toIndex() orelse return null;
    if (vir.instructions.items(.tag)[@backingInt(i)] != .call) return null;
    const c = decl.payloadOf(vir, Inst.Call, i);
    const callee = c.callee.toIndex() orelse return null;
    if (vir.instructions.items(.tag)[@backingInt(callee)] != .str_ref) return null;
    const name = vir.string(vir.instructions.items(.data)[@backingInt(callee)].str_tok.start);
    try loadDisciplines(s);
    if (s.access_kind.get(name) == null) return null;
    return .{ .name = name, .args = vir.list(Inst.Ref, c.args) };
}

/// A node row's name; `gnd` for the reference node.
pub fn nodeName(s: *const Sema, n: Node.Index) []const u8 {
    if (n == .ground) return "gnd";
    return s.zcu.intern_pool.stringToSlice(s.device.nodes.items(.name)[@backingInt(n)]);
}

// ---- private ----

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
    if (n.flags.parent_kind == .none) return natureAccess(s, vir.string(n.parent), depth + 1);
    // `nature n : disc.potential`: the discipline's nature of that half.
    const dd = zcu.disciplines.get(try zcu.intern_pool.getString(s.gpa, vir.string(n.parent))) orelse return null;
    const dvir = zcu.fileVir(dd.file);
    const want: @FieldType(Inst.DisciplineItem, "kind") = if (n.flags.parent_kind == .potential) .potential else .flow;
    for (dvir.list(Inst.DisciplineItem, decl.payloadOf(dvir, Inst.Discipline, zcu.declRow(dd).inst).items)) |item|
        if (item.kind == want) return natureAccess(s, dvir.string(item.name), depth + 1);
    return null;
}

/// The named branch `r` names (`br`, or §6.7's `x1.br`), or null.
fn branchOf(s: *Sema, b: *Block, r: Inst.Ref, src: Inst.Ref) Allocator.Error!?Device.Branch.Index {
    const vir = b.unit.vir;
    const i = r.toIndex() orelse return null;
    return switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .decl_ref => if (b.unit.binds.get(decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl))) |x| (if (x == .branch) x.branch else null) else null,
        .field => blk: {
            if (!try hier.isBranch(s, b, r)) break :blk null;
            const hit = (try hier.resolve(s, b, r, src)) orelse break :blk null;
            break :blk hit.bind.bind.branch;
        },
        else => null, // else: a terminal, not a branch
    };
}

/// The bind a terminal's name has (`p`, or §6.7's `x1.p`) and the unit it
/// is in; null after a diagnostic.
fn terminalBind(s: *Sema, b: *Block, r: Inst.Ref, src: Inst.Ref) Allocator.Error!?struct { Sema.Bind, *Sema.Unit } {
    const unit = b.unit;
    const vir = unit.vir;
    const i = r.toIndex() orelse return null;
    switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .decl_ref => {
            const bind = unit.binds.get(decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl)) orelse {
                try s.fail(.E0512, unit.file, src, "an access of a name with no node", .{});
                return null;
            };
            return .{ bind, unit };
        },
        .field => {
            const hit = (try hier.resolve(s, b, r, src)) orelse return null;
            if (hit != .bind) {
                try s.fail(.E0512, unit.file, src, "an access of a name with no node", .{});
                return null;
            }
            return .{ hit.bind.bind, hit.bind.unit };
        },
        else => {
            try s.fail(.E0512, unit.file, src, "an access of a select or a hierarchical name is not lowered by Sema yet", .{});
            return null;
        },
    }
}

/// The node a terminal names: a scalar net, or an element of a vector by
/// a constant index (§3.6.3); null after a diagnostic.
fn nodeOf(s: *Sema, b: *Block, r: Inst.Ref, src: Inst.Ref) Allocator.Error!?Node.Index {
    const unit = b.unit;
    const vir = unit.vir;
    const i = r.toIndex() orelse return null;
    if (vir.instructions.items(.tag)[@backingInt(i)] != .elem) {
        const bind, _ = (try terminalBind(s, b, r, src)) orelse return null;
        switch (bind) {
            .node => |n| return n,
            .vector => {
                try s.fail(.E0512, unit.file, src, "an access of a whole vector", .{});
                return null;
            },
            else => {
                try s.fail(.E0512, unit.file, src, "an access of a name with no node", .{});
                return null;
            },
        }
    }
    const x = decl.payloadOf(vir, Inst.Bin, i);
    const base_tag = if (x.lhs.toIndex()) |base| vir.instructions.items(.tag)[@backingInt(base)] else .str_ref;
    if (base_tag != .decl_ref and base_tag != .field) {
        try s.fail(.E0512, unit.file, src, "an access of a select of a select", .{});
        return null;
    }
    const bind, const owner = (try terminalBind(s, b, x.lhs, src)) orelse return null;
    if (bind != .vector) {
        try s.fail(.E0351, unit.file, src, "the net was not declared with a range", .{});
        return null;
    }
    const v = bind.vector;
    const k = ((try decl.foldRef(s, unit, x.rhs)) orelse {
        try s.fail(.E0512, unit.file, src, "an access of a vector element at a run-time index", .{});
        return null;
    }).asIntExact() orelse return null;
    if (k < @min(v.msb, v.lsb) or k > @max(v.msb, v.lsb)) {
        try s.fail(.E0352, unit.file, src, "{d} is not an element of [{d}:{d}]", .{ k, v.msb, v.lsb });
        return null;
    }
    const off: u32 = @intCast(if (v.msb >= v.lsb) v.msb - k else k - v.msb);
    return owner.vec_rows.items[v.first + off];
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
fn flowUnknown(s: *Sema, unit: *const Sema.Unit, hi: Node.Index, lo: Node.Index) Allocator.Error!Node.Index {
    const gop = try s.flow_rows.getOrPut(s.arena, .{ hi, lo });
    if (gop.found_existing) return gop.value_ptr.*;
    const ip = &s.zcu.intern_pool;
    const name = try std.fmt.allocPrint(s.arena, "flow({s},{s})", .{ nodeName(s, hi), nodeName(s, lo) });
    const row: Node.Index = @fromBackingInt(@intCast(s.device.nodes.len));
    try s.device.nodes.append(s.gpa, .{ .name = try ip.getString(s.gpa, name), .kind = .branch_flow, .of = hi, .discipline = .empty, .instance = decl.rowInstance(unit.instance) });
    try s.device.flows.append(s.gpa, .{ .unknown = row, .hi = hi, .lo = lo, .kind = .branch });
    gop.value_ptr.* = row;
    return row;
}

/// Whether `r` is a §4.4.2 port reference (`<p>`) or names a §3.12.1 port
/// branch.
fn isPortBranch(unit: *const Sema.Unit, r: Inst.Ref) bool {
    const vir = unit.vir;
    const i = r.toIndex() orelse return false;
    return switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .port_branch => true,
        .decl_ref => if (unit.binds.get(decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl))) |x| x == .port else false,
        else => false, // else: a net or a branch
    };
}

/// The port node `r` reaches: `<p>` (§4.4.2) or a §3.12.1 port branch;
/// null for any other argument, or after a diagnostic.
fn portOf(s: *Sema, b: *Block, r: Inst.Ref, src: Inst.Ref) Allocator.Error!?Node.Index {
    const unit = b.unit;
    const vir = unit.vir;
    if (!isPortBranch(unit, r)) return null;
    const i = r.toIndex().?;
    if (vir.instructions.items(.tag)[@backingInt(i)] == .decl_ref)
        return unit.binds.get(decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl)).?.port;
    const operand = vir.instructions.items(.data)[@backingInt(i)].un_node.operand;
    if (operand.toIndex()) |o| if (vir.instructions.items(.tag)[@backingInt(o)] != .decl_ref) {
        try s.fail(.E0512, unit.file, src, "a port access of an instance's port (`<u.p>`) is not lowered by Sema yet", .{});
        return null;
    };
    return nodeOf(s, b, operand, src);
}

/// §5.4.3 `I(<p>)`: the flow into the module's port `p`, its own unknown
/// `flow(<p>)`. "The expression V(<a>) is invalid for ports and nets"
/// (E0507); `p` must be a port of the module (E0508).
fn portFlow(s: *Sema, b: *Block, name: []const u8, p: Node.Index, src: Inst.Ref) Allocator.Error!Value {
    const file = b.unit.file;
    const global = (try accessOf(s, b, name)) orelse {
        try s.fail(.E0501, file, src, "`{s}`", .{name});
        return expr.poison;
    };
    if (accessOn(s, name, global, p, .ground) == .potential) {
        try s.fail(.E0507, file, src, "`{s}` is a potential access function", .{name});
        return expr.poison;
    }
    if (p == .ground or @backingInt(p) >= s.device.num_ports) {
        try s.fail(.E0508, file, src, "`{s}(<{s}>)`", .{ name, nodeName(s, p) });
        return expr.poison;
    }
    // ponytail: a child's port is the parent's net it binds; its flow is
    // the old flattener's ammeter split, which Sema does not make yet.
    if (b.unit.prefix.len != 0) {
        try s.fail(.E0512, file, src, "a port access in an instance below the root is not lowered by Sema yet", .{});
        return expr.poison;
    }
    const gop = try s.port_rows.getOrPut(s.arena, p);
    if (!gop.found_existing) {
        gop.value_ptr.* = @fromBackingInt(@intCast(s.device.nodes.len));
        const ip = &s.zcu.intern_pool;
        try s.device.nodes.append(s.gpa, .{ .name = try ip.getString(s.gpa, try std.fmt.allocPrint(s.arena, "flow(<{s}>)", .{nodeName(s, p)})), .kind = .port_flow, .of = p, .discipline = .empty, .instance = decl.rowInstance(b.unit.instance) });
        try s.device.flows.append(s.gpa, .{ .unknown = gop.value_ptr.*, .hi = p, .lo = .ground, .kind = .port });
    }
    return .{ .ref = try probe(s, gop.value_ptr.*), .ty = .real };
}

/// Whether an indirect contribution (§5.6.7) defines the unordered pair.
fn indirectOn(s: *const Sema, hi: Node.Index, lo: Node.Index) bool {
    const d = &s.device.contributions;
    for (d.items(.kind), d.items(.hi), d.items(.lo)) |k, h, l| {
        if (k == .indirect and ((h == hi and l == lo) or (h == lo and l == hi))) return true;
    }
    return false;
}

/// A.8.3 `indirect_expression`: an access, or `ddt`/`idt`/`idtmod` of one.
fn indirectProbe(s: *Sema, unit: *const Sema.Unit, r: Inst.Ref) Allocator.Error!bool {
    if (try accessCall(s, unit, r) != null) return true;
    const vir = unit.vir;
    const i = r.toIndex() orelse return false;
    if (vir.instructions.items(.tag)[@backingInt(i)] != .call_sys) return false;
    const c = decl.payloadOf(vir, Inst.SysCall, i);
    const name = vir.string(c.name);
    if (!std.mem.eql(u8, name, "ddt") and !std.mem.eql(u8, name, "idt") and !std.mem.eql(u8, name, "idtmod")) return false;
    const args = vir.list(Inst.Ref, c.args);
    return args.len != 0 and try accessCall(s, unit, args[0]) != null;
}

/// §4.4 `name` is the access its node's discipline binds for `a` (or the
/// generic `potential`/`flow`): E0501 when the discipline binds no such
/// nature or another name.
/// ponytail: a node with no discipline is not judged (the old E0337): a
/// `default_discipline` directive gives one Sema does not see yet.
fn accessMatches(s: *Sema, b: *Block, name: []const u8, a: Device.Access, node: Node.Index, src: Inst.Ref) Allocator.Error!bool {
    if (node == .ground) return true;
    // A Table E.1 primitive reads its ports with Annex D's names, whatever
    // the source binds `electrical` to.
    if (s.zcu.isBuiltin(s.zcu.instances.items(.module)[@backingInt(b.unit.instance)])) return true;
    const dname = s.zcu.intern_pool.stringToSlice(s.device.nodes.items(.discipline)[@backingInt(node)]);
    if (dname.len == 0) return true;
    const pair = s.disc_access.get(dname) orelse return true;
    // A discipline that binds no nature is judged nowhere (the old side
    // keeps no access table for it).
    if (pair[0].len == 0 and pair[1].len == 0) return true;
    const want = pair[@backingInt(a)];
    if (std.mem.eql(u8, want, name) or std.mem.eql(u8, name, "potential") or std.mem.eql(u8, name, "flow")) return true;
    try s.fail(.E0501, b.unit.file, src, "`{s}` is not an access function of `{s}`", .{ name, nodeName(s, node) });
    return false;
}

/// Whether this instance has a potential source on `t`'s branch.
fn potentialSourceHere(s: *const Sema, b: *const Block, t: Target) bool {
    const row = s.contrib_rows.get(.{ .access = .potential, .branch = t.branch, .hi = t.hi, .lo = t.lo }) orelse return false;
    return s.device.contributions.items(.instance)[@backingInt(row)] == decl.rowInstance(b.unit.instance);
}
