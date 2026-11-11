//! §3.12 branch declarations: one instance's `branch (a, b) br;` items in,
//! a `device.branches` row each (named by the instance path) and the
//! branch's bind out; a §3.12.1 port branch (`branch (<p>) br;`) binds
//! the port instead.
//! Cites: VAMS-2023 §3.12, §3.12.1.
//!
//! Contents:
//! - `pub fn declare(s: *Sema, unit: *Unit) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Device = Air.Device;
const Node = Device.Node;
const Unit = Sema.Unit;

/// §3.12 the instance's named branches, in declaration order.
pub fn declare(s: *Sema, unit: *Unit) Allocator.Error!void {
    const vir = unit.vir;
    for (vir.body(unit.module.body)) |i| {
        if (vir.instructions.items(.tag)[@backingInt(i)] != .branch) continue;
        const br = decl.payloadOf(vir, Inst.Branch, i);
        if (portOfBody(unit, br.hi)) |p| {
            try unit.binds.put(s.arena, decl.canonical(vir, i), .{ .port = p });
            continue;
        }
        const hi = nodeOfBody(unit, br.hi) orelse continue;
        const lo = if (br.lo.len == 0) Node.Index.ground else nodeOfBody(unit, br.lo) orelse continue;
        try s.device.branches.append(s.gpa, .{
            .name = try s.zcu.intern_pool.getString(s.gpa, try std.fmt.allocPrint(s.arena, "{s}{s}", .{ unit.prefix, vir.string(br.name) })),
            .hi = hi,
            .lo = lo,
            .instance = decl.rowInstance(unit.instance),
        });
        try unit.binds.put(s.arena, decl.canonical(vir, i), .{ .branch = @fromBackingInt(@intCast(s.device.branches.len)) });
    }
}

// ---- private ----

/// The port node a §3.12.1 terminal body names (`<p>`), or null.
fn portOfBody(unit: *const Unit, b: Vir.Body) ?Node.Index {
    const vir = unit.vir;
    const insts = vir.body(b);
    if (insts.len == 0) return null;
    const last = insts[insts.len - 1];
    if (vir.instructions.items(.tag)[@backingInt(last)] != .port_branch) return null;
    const o = vir.instructions.items(.data)[@backingInt(last)].un_node.operand.toIndex() orelse return null;
    if (vir.instructions.items(.tag)[@backingInt(o)] != .decl_ref) return null;
    const bind = unit.binds.get(decl.canonical(vir, vir.instructions.items(.data)[@backingInt(o)].decl_tok.decl)) orelse return null;
    return if (bind == .node) bind.node else null;
}

/// The node a terminal body names (a scalar net), or null.
fn nodeOfBody(unit: *const Unit, b: Vir.Body) ?Node.Index {
    const vir = unit.vir;
    const insts = vir.body(b);
    if (insts.len == 0) return null;
    const last = insts[insts.len - 1];
    if (vir.instructions.items(.tag)[@backingInt(last)] != .decl_ref) return null;
    const bind = unit.binds.get(decl.canonical(vir, vir.instructions.items(.data)[@backingInt(last)].decl_tok.decl)) orelse return null;
    return if (bind == .node) bind.node else null;
}
