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
const expr = @import("expr.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const SysFn = vams.SysFn;
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
    const v = try expr.lower(s, &pb, insts[insts.len - 1].toRef());
    const want = s.param_args.items[@backingInt(row)].ty;
    const r = try expr.coerce(s, &pb, v, want);
    // Codegen renders the expression alone: arguments, constants, pure
    // operations, a `block`/`cond_br`/`br` (§4.2.12's ternary, `&&`/`||`)
    // whose own bodies are pure, and a `$simparam` of a `host_params` name.
    const pure = isPure(s, pb.insts.items, 0);
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

/// W11: whether every instruction in `insts` is one `genTree` (the
/// standalone-expression renderer) can render: an `arg`, a `select`, a
/// pure operator, a `block`/`cond_br`/`br` whose nested bodies are
/// (recursively) pure, or a pure `$simparam` call. Reads `s.air`'s
/// extra array directly (the builder stage: `op.zig`'s `isStatic`,
/// `readsUnknown` read it the same way). Bounded like every expr.zig walk.
fn isPure(s: *Sema, insts: []const Air.Inst.Index, depth: u32) bool {
    if (depth > expr.depth_max) return false;
    for (insts) |i| {
        const idx = @backingInt(i);
        const tag = s.air.instructions.items(.tag)[idx];
        const data = s.air.instructions.items(.data)[idx];
        switch (tag) {
            .arg, .select, .br => {},
            .call => if (!isPureSimparam(s, data)) return false,
            .block => {
                const body_len = s.air.extra.items[data.ty_pl.payload];
                if (!isPure(s, bodyOf(s, data.ty_pl.payload + 1, body_len), depth + 1)) return false;
            },
            .cond_br => {
                const lens = s.air.extra.items[data.pl_op.payload..][0..2];
                const then_at = data.pl_op.payload + 2;
                if (!isPure(s, bodyOf(s, then_at, lens[0]), depth + 1)) return false;
                if (!isPure(s, bodyOf(s, then_at + lens[0], lens[1]), depth + 1)) return false;
            },
            .load, .assign, .path_prev, .path_acc, .opt_barrier, .dstop, .store, .fload, .iload, .anew => return false,
            else => switch (Air.tag_info.getPtrConst(tag).class) {
                .un_op, .bin_op => {},
                else => return false,
            },
        }
    }
    return true;
}

/// `s.air.extra.items[at..][0..len]`'s `u32`s read back as `Inst.Index`.
fn bodyOf(s: *Sema, at: u32, len: u32) []const Air.Inst.Index {
    return @ptrCast(s.air.extra.items[at..][0..len]);
}

/// Whether `data` (a `call`) is a `$simparam` of any name but `"iteration"`
/// or `"dt"` (Table 9-27's two run-time ones): `calls.zig`'s `simparam`
/// renders every other name from `model` alone (a `host_params` field), a
/// constant (`"scale"`/`"shrink"`), or its own fallback argument (an
/// unknown name) — never `sim`. A literal fallback's purity needs no
/// extra check: it is its own entry in the same `insts` this walks.
fn isPureSimparam(s: *Sema, data: Air.Inst.Data) bool {
    const head = s.air.extra.items[data.ty_pl.payload..][0..2];
    if (head[0] > std.math.maxInt(@typeInfo(SysFn.Tag).@"enum".tag_type)) return false;
    if (@as(SysFn.Tag, @fromBackingInt(@intCast(head[0]))) != .@"$simparam") return false;
    if (head[1] == 0) return false;
    const arg0: Air.Inst.Ref = @fromBackingInt(@intCast(s.air.extra.items[data.ty_pl.payload + 2]));
    const idx = arg0.toInterned() orelse return false;
    const name = switch (s.zcu.intern_pool.indexToKey(idx)) {
        .str => |t| s.zcu.intern_pool.stringToSlice(t),
        else => return false,
    };
    return !std.mem.eql(u8, name, "iteration") and !std.mem.eql(u8, name, "dt");
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
