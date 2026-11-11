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
//! - `pub fn rowOf(s: *Sema, b: *const Block, t: Target) Allocator.Error!Device.Contribution.Index`

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
    const row = try rowOf(s, b, t);
    var split: reactive.Split = .{};
    s.contrib_target = t;
    defer s.contrib_target = null;
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
