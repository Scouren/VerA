//! §6.4.1 a paramset instance's own parameters (the old flattener's
//! paramset rows): the selected paramset's declarations, folded at its
//! level, in; local rows `u.<paramset>.<name>` with their ranges out,
//! ahead of the module's, each read by an `arg` in the prologue, and the
//! paramset's scope bound to them.
//! Cites: VAMS-2023 §3.4.2, §6.4.1.
//!
//! Contents:
//! - `pub fn rows(s: *Sema, unit: *Unit) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const Zcu = @import("../Zcu.zig");
const decl = @import("decl.zig");
const eval = @import("eval.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Device = Air.Device;
const Unit = Sema.Unit;

/// §6.4.1 a paramset instance's own parameters (the selected paramset's,
/// folded at its level): local rows `u.<paramset>.<name>` with their
/// ranges, ahead of the module's, as the old flattener names them. No
/// statement of the module reads one.
pub fn rows(s: *Sema, unit: *Unit) Allocator.Error!void {
    const zcu = s.zcu;
    const ip = &zcu.intern_pool;
    const k = @backingInt(unit.instance);
    const ps = zcu.instances.items(.paramset)[k];
    const own = zcu.instances.items(.paramset_params)[k];
    if (std.meta.eql(ps, Zcu.Decl.none) or own == .none) return;
    const vir = zcu.fileVir(ps.file);
    const row = zcu.declRow(ps);
    const decl_ps = decl.payloadOf(vir, Inst.Paramset, row.inst);
    const values = ip.indexToKey(own).aggregate.elems;
    // The paramset's scope: its own declarations bound to their rows.
    const scope = try s.arena.create(Unit);
    scope.* = .{ .instance = unit.instance, .file = ps.file, .vir = vir, .module = unit.module, .prefix = unit.prefix, .owner = unit };
    unit.paramset = scope;
    var env: eval.Env = try .init(s.gpa, s.arena, ip, vir, &.{});
    defer env.deinit();
    var at: usize = 0;
    for (vir.body(decl_ps.body)) |i| {
        if (vir.instructions.items(.tag)[@backingInt(i)] != .param) continue;
        defer at += 1;
        const p = decl.payloadOf(vir, Inst.Param, i);
        const ty: Device.Param.Type = switch (p.flags.storage) {
            .real, .realtime => .real,
            .integer, .time => .integer,
            .string => .string,
            .none, .reg => if (p.range.len != 0) .integer else .unspecified,
        };
        const ranges_start: u32 = @intCast(s.device.ranges.items.len);
        for (vir.list(Inst.ValueRange, p.ranges)) |r| {
            const lo = try boundIn(&env, vir, r.lo);
            const hi = if (r.flags.interval) try boundIn(&env, vir, r.hi) else lo;
            try s.device.ranges.append(s.gpa, .{
                .exclude = r.flags.exclude,
                .lo = if (r.flags.set) null else lo,
                .hi = if (r.flags.set) null else hi,
                .lo_closed = if (r.flags.interval) r.flags.lo_closed else true,
                .hi_closed = if (r.flags.interval) r.flags.hi_closed else true,
                .strings = r.flags.set,
            });
        }
        const value: InternPool.Index = if (at < values.len) values[at] else .undef;
        const r: Device.Param.Index = @fromBackingInt(@intCast(s.device.params.len));
        try s.device.params.append(s.gpa, .{
            .name = try ip.getString(s.gpa, try std.fmt.allocPrint(s.arena, "{s}{s}.{s}", .{ unit.prefix, vir.string(row.name), vir.string(p.name) })),
            .ty = if (ty != .unspecified) ty else switch (ip.indexToKey(value)) {
                .int => .integer,
                .str => .string,
                else => .real, // else: a real, or a value that did not fold
            },
            .local = true,
            .default = value,
            .ranges_start = ranges_start,
            .ranges_len = @intCast(s.device.ranges.items.len - ranges_start),
            .instance = decl.rowInstance(unit.instance),
            .derive = .none,
        });
        const vty: Sema.Ty = switch (ip.indexToKey(value)) {
            .float => .real,
            .str => .string,
            else => if (ty == .real) .real else .integer, // else: an integer, or an unfoldable value read as the declared type
        };
        const arg = try s.air.addInst(s.gpa, .{ .tag = .arg, .data = .{ .ty_index = .{ .ty = decl.typeIndex(vty), .index = @backingInt(r) } } });
        try s.prologue.append(s.arena, arg);
        try s.param_args.append(s.arena, .{ .ref = .fromIndex(arg), .ty = vty });
        try scope.binds.put(s.arena, decl.canonical(vir, i), .{ .param = r });
    }
}

// ---- private ----

/// A range bound of the paramset's file when it reads no name.
fn boundIn(env: *eval.Env, vir: *const Vir, b: Vir.Body) Allocator.Error!?f64 {
    for (vir.body(b)) |i| switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .decl_ref, .str_ref, .call_sys, .call => return null,
        else => {}, // else: a literal or an operator over literals
    };
    const c = (try env.body(b)) orelse return null;
    if (c == .str) return null;
    const x = c.asReal();
    return if (std.math.isNan(x)) null else x;
}
