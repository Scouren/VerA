//! `Air.Device.Param.derive` (the old device's `derive`): each card row's
//! value as an expression over the rows before it, so a host that moves a
//! row its value reads recomputes it. A root row's is its default; a
//! child's, the expression that gives its value where it is written: the
//! parent's instance override (in the parent's scope), a paramset
//! statement (in the paramset's), else the module's own default. A row a
//! defparam sets, or whose expression reads no row, keeps its folded value.
//! Cites: VAMS-2023 §3.4, §6.3, §6.3.1, §6.3.2, §6.4.1.
//!
//! Contents:
//! - `pub fn expression(s: *Sema, unit: *Unit, row: Device.Param.Index, value: Vir.Body) Allocator.Error!void`
//! - `pub fn child(s: *Sema, unit: *Unit) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const walk = @import("walk.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Device = Air.Device;
const Unit = Sema.Unit;

/// Row `row`'s value as the expression `value` in `unit`'s scope (its rows
/// before it), `Param.derive`: its instructions at the end of the prologue; none for
/// a default over literals alone, or one the lowering cannot express (its
/// diagnostics are dropped: the folded default stands).
pub fn expression(s: *Sema, unit: *Unit, row: Device.Param.Index, value: Vir.Body) Allocator.Error!void {
    const vir = unit.vir;
    const insts = vir.body(value);
    if (insts.len == 0) return;
    const reads = for (insts) |i| switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .decl_ref, .str_ref, .call_sys, .call, .field => break true,
        else => {}, // else: a literal or an operator
    } else false;
    if (!reads) return;
    const failed = s.zcu.failed.len;
    var pb: Sema.Block = .{ .parent = null, .unit = unit };
    const v = try @import("expr.zig").lower(s, &pb, insts[insts.len - 1].toRef());
    const want = s.param_args.items[@backingInt(row)].ty;
    const r = try @import("expr.zig").coerce(s, &pb, v, want);
    // Codegen renders the expression alone: arguments, constants and pure
    // operations only.
    const pure = for (pb.insts.items) |i| switch (s.air.instructions.items(.tag)[@backingInt(i)]) {
        .arg, .select => {},
        .load, .assign, .path_prev, .path_acc, .opt_barrier, .dstop, .store, .fload, .iload, .anew => break false,
        else => |t| switch (Air.tag_info.getPtrConst(t).class) {
            .un_op, .bin_op => {},
            else => break false,
        },
    } else true;
    if (s.zcu.failed.len != failed or !pure or (v.ty == .string) != (want == .string)) {
        s.zcu.failed.shrinkRetainingCapacity(failed);
        return;
    }
    try s.prologue.appendSlice(s.arena, pb.insts.items);
    s.device.params.items(.derive)[@backingInt(row)] = r;
}

/// The derive of every row of child `unit` (and of its paramset's), after
/// every unit's rows exist.
pub fn child(s: *Sema, unit: *Unit) Allocator.Error!void {
    const zcu = s.zcu;
    const k = @backingInt(unit.instance);
    const parent = zcu.instances.items(.parent)[k];
    assert(parent != .none);
    const pu = for (s.units.items) |*u| {
        if (u.instance == parent) break u;
    } else return;
    const src = zcu.instances.items(.src)[k].toIndex() orelse return;
    if (pu.vir.instructions.items(.tag)[@backingInt(src)] != .instance) return;
    const args = pu.vir.list(Inst.Arg, decl.payloadOf(pu.vir, Inst.Instance, src).params);
    if (unit.paramset) |ps| {
        // The instance gives the paramset its values; its statements give
        // the module's.
        try scope(s, ps, psParams(s, ps), pu, args, unit);
        const body = psBody(ps);
        for (moduleParams(s, unit)) |p| {
            const row = rowOf(unit, p) orelse continue;
            const name = unit.vir.string(decl.payloadOf(unit.vir, Inst.Param, p).name);
            const over = for (ps.vir.body(body)) |o| {
                if (ps.vir.instructions.items(.tag)[@backingInt(o)] != .ps_override) continue;
                const x = decl.payloadOf(ps.vir, Inst.Override, o);
                if (std.mem.eql(u8, ps.vir.string(x.name), name)) break x.value;
            } else null;
            if (over) |v| try expression(s, ps, row, v) else try expression(s, unit, row, decl.payloadOf(unit.vir, Inst.Param, p).value);
        }
        return;
    }
    try scope(s, unit, moduleParams(s, unit), pu, args, unit);
}

// ---- private ----

/// The rows of the declarations `params` of `target` (a module or a
/// paramset scope): a given override in the parent `pu`'s scope, else the
/// default in `target`'s; none for a defparam's target.
fn scope(s: *Sema, target: *Unit, params: []const Inst.Index, pu: *Unit, args: []const Inst.Arg, owner: *Unit) Allocator.Error!void {
    const vir = target.vir;
    var ordered: usize = 0;
    const given = try s.arena.alloc(?Vir.Body, params.len);
    @memset(given, null);
    for (args) |a| {
        const at: ?usize = if (a.name == .empty) blk: {
            var n: usize = 0;
            for (params, 0..) |p, j| if (walk.isOverridable(vir, p)) {
                if (n == ordered) break :blk j;
                n += 1;
            };
            break :blk null;
        } else for (params, 0..) |p, j| {
            if (std.mem.eql(u8, vir.string(decl.payloadOf(vir, Inst.Param, p).name), pu.vir.string(a.name))) break j;
        } else null;
        if (a.name == .empty) ordered += 1;
        if (at) |j| if (a.value.len != 0) {
            given[j] = a.value;
        };
    }
    for (params, given) |p, g| {
        const row = rowOf(target, p) orelse continue;
        const name = try s.zcu.intern_pool.getString(s.gpa, vir.string(decl.payloadOf(vir, Inst.Param, p).name));
        if (s.zcu.defparams.contains(.{ .instance = owner.instance, .name = name })) continue;
        if (g) |v| try expression(s, pu, row, v) else try expression(s, target, row, decl.payloadOf(vir, Inst.Param, p).value);
    }
}

fn rowOf(unit: *const Unit, p: Inst.Index) ?Device.Param.Index {
    const bind = unit.binds.get(decl.canonical(unit.vir, p)) orelse return null;
    return if (bind == .param) bind.param else null;
}

/// A module's `param` declarations, header then body.
fn moduleParams(s: *Sema, unit: *const Unit) []const Inst.Index {
    var out: std.ArrayList(Inst.Index) = .empty;
    for ([_]Vir.Body{ unit.module.params, unit.module.body }) |b| for (unit.vir.body(b)) |i| {
        if (unit.vir.instructions.items(.tag)[@backingInt(i)] == .param) out.append(s.arena, i) catch return out.items;
    };
    return out.items;
}

/// The paramset body `ps` (a scope unit) reads.
fn psBody(ps: *const Unit) Vir.Body {
    var it = ps.binds.keyIterator();
    const any = it.next() orelse return .empty;
    // The paramset holding a bound declaration.
    for (ps.vir.decls()) |d| if (d.kind == .paramset) {
        const b = decl.payloadOf(ps.vir, Inst.Paramset, d.inst).body;
        for (ps.vir.body(b)) |i| if (i == any.*) return b;
    };
    return .empty;
}

/// The paramset's own `param` declarations, in order.
fn psParams(s: *Sema, ps: *const Unit) []const Inst.Index {
    var out: std.ArrayList(Inst.Index) = .empty;
    for (ps.vir.body(psBody(ps))) |i| {
        if (ps.vir.instructions.items(.tag)[@backingInt(i)] == .param) out.append(s.arena, i) catch return out.items;
    }
    return out.items;
}
