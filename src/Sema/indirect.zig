//! Indirect branch assignments: `V(out) : probe == eqn` in, a contribution
//! row of its own whose resistive value is `probe - eqn` out (§5.6.7:
//! "drive V(out) so that probe == eqn").
//! Cites: VAMS-2023 §5.6.7, §5.6.7.1, §5.6.7.2, A.8.3.
//!
//! Contents:
//! - `pub fn lower(s: *Sema, b: *Block, x: Inst.Triple, src: Inst.Ref) Allocator.Error!void`
//! - `pub fn on(s: *const Sema, hi: Node.Index, lo: Node.Index) bool`

const std = @import("std");
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const expr = @import("expr.zig");
const access = @import("access.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Device = Air.Device;
const Node = Device.Node;
const Block = Sema.Block;
const Ref = Air.Inst.Ref;

/// §5.6.7 `V(out) : probe == eqn`: "drive V(out) so that probe == eqn", a
/// row of its own (never accumulated, §5.6.7.1) whose resistive value is
/// `probe - eqn`. Not in a restricted context (E0410), an event (E0411), a
/// run-time conditional or loop (E0412); the target an access (E0413), the
/// probe an access or `ddt`/`idt`/`idtmod` of one (E0414); no `<+` on the
/// pair before it (E0415).
pub fn lower(s: *Sema, b: *Block, x: Inst.Triple, src: Inst.Ref) Allocator.Error!void {
    const unit = b.unit;
    const file = unit.file;
    if (b.restricted()) |ctx| return s.fail(.E0410, file, src, "not allowed in {s}", .{ctx});
    if (b.in_event) return s.fail(.E0411, file, src, "", .{});
    if (b.conditional != 0 or b.loop != null) return s.fail(.E0412, file, src, "the condition is not a constant expression", .{});
    if (b.nodiff) return s.fail(.E0526, file, src, "", .{});
    const lhs = (try access.accessCall(s, unit, x.a)) orelse return s.fail(.E0413, file, src, "", .{});
    if (!try probeOk(s, unit, x.b)) return s.fail(.E0414, file, src, "", .{});
    const t = (try access.target(s, b, lhs.name, lhs.args, src)) orelse return;
    for (0..s.device.contributions.len) |k| {
        const row = s.device.contributions.get(k);
        if (row.kind != .direct) continue;
        if (!((row.hi == t.hi and row.lo == t.lo) or (row.hi == t.lo and row.lo == t.hi))) continue;
        return s.fail(.E0415, file, src, "`({s},{s})`", .{ access.nodeName(s, t.hi), access.nodeName(s, t.lo) });
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

/// Whether an indirect contribution (§5.6.7) defines the unordered pair.
pub fn on(s: *const Sema, hi: Node.Index, lo: Node.Index) bool {
    const d = &s.device.contributions;
    for (d.items(.kind), d.items(.hi), d.items(.lo)) |k, h, l| {
        if (k == .indirect and ((h == hi and l == lo) or (h == lo and l == hi))) return true;
    }
    return false;
}

// ---- private ----

/// A.8.3 `indirect_expression`: an access, or `ddt`/`idt`/`idtmod` of one.
fn probeOk(s: *Sema, unit: *const Sema.Unit, r: Inst.Ref) Allocator.Error!bool {
    if (try access.accessCall(s, unit, r) != null) return true;
    const vir = unit.vir;
    const i = r.toIndex() orelse return false;
    if (vir.instructions.items(.tag)[@backingInt(i)] != .call_sys) return false;
    const c = decl.payloadOf(vir, Inst.SysCall, i);
    const name = vir.string(c.name);
    if (!std.mem.eql(u8, name, "ddt") and !std.mem.eql(u8, name, "idt") and !std.mem.eql(u8, name, "idtmod")) return false;
    const args = vir.list(Inst.Ref, c.args);
    return args.len != 0 and try access.accessCall(s, unit, args[0]) != null;
}
