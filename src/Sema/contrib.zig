//! Contributions (the old `accum.zig`, `contrib.zig`): a `<+` in, its
//! value added to its target's slots out. One row per target (access,
//! branch, ordered node pair; §5.6.1.3 accumulation), its resistive and
//! reactive (§5.6.1.2, a linear `ddt` term's argument) sums in slots, and
//! a flag slot set to 1 when a `<+` runs. A flow contribution is scaled by
//! `$mfactor` (§6.3.6). Access lowering is `access.zig`'s.
//! Cites: VAMS-2023 §1.3.4.1, §1.3.4.2, §5.4.3, §5.6, §5.6.1.2, §5.6.1.3,
//! §5.6.7.2, §6.3.6.
//!
//! Contents:
//! - `pub const Target = struct`
//! - `pub fn contribute(s: *Sema, b: *Block, x: Inst.Bin, src: Inst.Ref) Allocator.Error!void`
//! - `pub fn rowOf(s: *Sema, b: *const Block, t: Target, src: Inst.Ref) Allocator.Error!Device.Contribution.Index`

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
const access = @import("access.zig");
const indirect = @import("indirect.zig");
const mfactor = @import("mfactor.zig");
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
    // `vera_nodiff` would leave the branch with no Jacobian.
    if (b.nodiff) return s.fail(.E0526, file, src, "", .{});
    // §5.4.3 a port access is read-only: it measures what the world outside
    // the module drives in.
    for (vir.list(Inst.Ref, c.args)) |a| if (access.isPortBranch(b.unit, a)) return s.fail(.E0407, file, src, "a contribution to a port access", .{});
    const t = (try access.target(s, b, name, vir.list(Inst.Ref, c.args), src)) orelse return;
    // §1.3.4.1/§1.3.4.2 no contribution to a signal-flow `input` port.
    for ([_]Node.Index{ t.hi, t.lo }) |n| if (@import("net.zig").inputPortOf(s, n)) |port|
        if (try @import("net.zig").isSignalFlow(s, s.device.nodes.items(.discipline)[@backingInt(n)]))
            return s.fail(.E0425, file, src, "`{s}` is an `input` port of a signal-flow discipline", .{port});
    // §5.6.7.2 "Once a value is indirectly assigned to a branch, it cannot
    // be contributed to using the branch contribution operator <+."
    if (indirect.on(s, t.hi, t.lo)) return s.fail(.E0409, file, src, "`({s},{s})`", .{ access.nodeName(s, t.hi), access.nodeName(s, t.lo) });
    // W0650's headline points at the access call that opened the row
    // (the old `mainTok(lhs)`): `x.lhs` is `I(p,n)`/`V(p,n)`'s own call.
    const row = try rowOf(s, b, t, x.lhs);
    try discardOpposite(s, b, t);
    var split: reactive.Split = .{};
    s.contrib_target = t;
    defer s.contrib_target = null;
    // `reactive.split` and the resist/react sum below mint instructions
    // with no `expr.lower` of their own (it is not a value expression: a
    // `<+` has no result), so without this they inherit whatever
    // `s.expr_src` an earlier statement left set -- usually `.none`, this
    // row's W0650 (research/airpasses.md T1) then finding no location for
    // its own resist/react sum. The statement's own ref is the old side's
    // answer too (`locate.inst`'s `.contrib` case: the access call's byte).
    const outer_src = s.expr_src;
    s.expr_src = src;
    defer s.expr_src = outer_src;
    try reactive.split(s, b, x.rhs, false, &split);
    if (split.react != null) try s.react_written.put(s.arena, row, {});
    const slots = s.device.contributions.get(@backingInt(row));
    // §6.3.6 "All contributions to a branch flow quantity in the analog
    // block shall be multiplied by $mfactor".
    const m = if (t.access == .flow) mfactor.mfactorOf(s, b.unit) else 1;
    inline for (.{ "resist", "react" }) |half| if (@field(split, half)) |v1| {
        const v0 = try mfactor.scaled(s, b, v1, m, false);
        const v = if (t.neg) try expr.unOp(s, b, .fneg, v0) else v0;
        const slot = @field(slots, half);
        const old = try s.addInst(b, .{ .tag = .load, .data = .{ .un_op = .fromIndex(slot) } });
        const sum = try expr.binOp(s, b, .fadd, old, v);
        _ = try s.addInst(b, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slot), .rhs = sum } } });
    };
    for (split.sites.items) |site| {
        const slot = try decl.addAlloc(s, .real);
        _ = try s.addInst(b, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slot), .rhs = try mfactor.scaled(s, b, site.charge, m, false) } } });
        try s.device.charge_sites.append(s.gpa, .{ .contrib = row, .sign = if (site.negate != t.neg) -1.0 else 1.0, .slot = slot });
    }
    _ = try s.addInst(b, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slots.wrote), .rhs = .fromIntern(.one_real) } } });
}

/// The contribution row of `t`, made on its first `<+` with its slots.
/// `src` is that first `<+`'s access call (or, for an operator row,
/// its operator call): on a new row only, W0650's headline points there.
pub fn rowOf(s: *Sema, b: *const Block, t: Target, src: Inst.Ref) Allocator.Error!Device.Contribution.Index {
    const key: Sema.ContribKey = .{ .access = t.access, .branch = t.branch, .hi = t.hi, .lo = t.lo };
    const gop = try s.contrib_rows.getOrPut(s.arena, key);
    if (gop.found_existing) return gop.value_ptr.*;
    const row: Device.Contribution.Index = @fromBackingInt(@intCast(s.device.contributions.len));
    const resist = try decl.addAlloc(s, .real);
    const react = try decl.addAlloc(s, .real);
    const wrote = try decl.addAlloc(s, .real);
    try s.device.contributions.append(s.gpa, .{
        .access = t.access,
        .kind = .direct,
        .branch = t.branch,
        .hi = t.hi,
        .lo = t.lo,
        .resist = resist,
        .react = react,
        .wrote = wrote,
        .instance = decl.rowInstance(b.unit.instance),
        .flow = .none,
    });
    gop.value_ptr.* = row;
    try s.setSrc(resist, b.unit.file, src);
    return row;
}

// ---- private ----

/// §5.6.1.3 "contributing [the other access] to a branch which already has
/// a value retained for [this one] results in [it] being discarded and the
/// branch being converted to a [this-access] source": when `t`'s branch
/// already holds a row for the opposite access, opened by this same
/// instance, every sum this `<+` would otherwise add to is stale, so its
/// resistive and reactive sums, its retention flag and every charge site it
/// fed are reset to 0 before this contribution accumulates into its own
/// row. A same-access `<+` (the common case) finds no opposite row and does
/// nothing.
fn discardOpposite(s: *Sema, b: *Block, t: Target) Allocator.Error!void {
    const opp: Device.Access = if (t.access == .potential) .flow else .potential;
    const key: Sema.ContribKey = .{ .access = opp, .branch = t.branch, .hi = t.hi, .lo = t.lo };
    const row = s.contrib_rows.get(key) orelse return;
    if (s.device.contributions.items(.instance)[@backingInt(row)] != decl.rowInstance(b.unit.instance)) return;
    const slots = s.device.contributions.get(@backingInt(row));
    for ([_]Air.Inst.Index{ slots.resist, slots.react, slots.wrote }) |slot|
        _ = try s.addInst(b, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slot), .rhs = .fromIntern(.zero_real) } } });
    for (s.device.charge_sites.items(.contrib), s.device.charge_sites.items(.slot)) |c, slot| {
        if (c != row) continue;
        _ = try s.addInst(b, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slot), .rhs = .fromIntern(.zero_real) } } });
    }
}
