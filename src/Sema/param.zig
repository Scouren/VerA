//! §3.4 parameters (the old `analog/param.zig`): one instance's `param`
//! declarations in, its rows of the model card out (`device.params`, each
//! read by an `arg` in the prologue): the root's on the card, a child's as
//! local rows named by its path (`u1.r`), every one with its folded value
//! and its §3.4.2 ranges (a bound folded over literals alone, as the prover
//! reads it). A value outside its declared ranges is E0361. A §3.4.4 array
//! parameter is a row per element (`c[0]`, `c[1]`, the old scalarization),
//! read through an array of slots each set from its `arg` at entry.
//! Cites: VAMS-2023 §3.4, §3.4.1, §3.4.2, §3.4.4, §3.4.5.
//!
//! Contents:
//! - `pub fn declare(s: *Sema, unit: *Sema.Unit) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const eval = @import("eval.zig");
const Zcu = @import("../Zcu.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Device = Air.Device;
const Unit = Sema.Unit;

/// §3.4 the instance's parameters, in declaration order: the root's on
/// the card, a child's as local rows of the folded value. Each is read by
/// an `arg` in the prologue.
pub fn declare(s: *Sema, unit: *Unit) Allocator.Error!void {
    const zcu = s.zcu;
    const ip = &zcu.intern_pool;
    const vir = unit.vir;
    const elems = ip.indexToKey(zcu.instances.items(.params)[@backingInt(unit.instance)]).aggregate.elems;
    try paramsetRows(s, unit);
    var at: usize = 0;
    // The root's rows whose default reads a parameter.
    var derived: std.ArrayList(struct { Device.Param.Index, Vir.Body }) = .empty;
    for ([_]Vir.Body{ unit.module.params, unit.module.body }) |b| for (vir.body(b)) |i| {
        // A.7.1 a specify block's specparams: local rows of their folded
        // values, in declaration order (the old flattener's).
        if (vir.instructions.items(.tag)[@backingInt(i)] == .specify) {
            for (vir.body(decl.payloadOf(vir, Inst.Process, i).body)) |sp| {
                if (vir.instructions.items(.tag)[@backingInt(sp)] != .param) continue;
                const p = decl.payloadOf(vir, Inst.Param, sp);
                const value: InternPool.Index = if (try decl.foldBody(s, unit, p.value)) |c| try decl.intern(s, c) else .undef;
                const row = try addRow(s, unit, vir.string(p.name), p, .unspecified, value);
                try unit.binds.put(s.arena, decl.canonical(vir, sp), .{ .param = row });
            }
            continue;
        }
        if (vir.instructions.items(.tag)[@backingInt(i)] == .aliasparam) {
            try systemAlias(s, unit, i);
            continue;
        }
        if (vir.instructions.items(.tag)[@backingInt(i)] != .param) continue;
        defer at += 1;
        const p = decl.payloadOf(vir, Inst.Param, i);
        const ty: Device.Param.Type = switch (p.flags.storage) {
            .real, .realtime => .real,
            .integer, .time => .integer,
            .string => .string,
            .none, .reg => if (p.range.len != 0) .integer else .unspecified,
        };
        if (p.dims.len != 0) {
            try declareArray(s, unit, i, p, ty, elems[at]);
            continue;
        }
        const row = try addRow(s, unit, vir.string(p.name), p, ty, elems[at]);
        try unit.binds.put(s.arena, decl.canonical(vir, i), .{ .param = row });
        try checkRange(s, unit, i, p, elems[at]);
        if (try stateRead(s, unit, p.value)) |what| try s.fail(.E0363, unit.file, i.toRef(), "`{s}` reads `{s}`", .{ vir.string(p.name), what });
        if (unit.prefix.len == 0) try derived.append(s.arena, .{ row, p.value });
    };
    assert(s.param_args.items.len == s.device.params.len);
    for (derived.items) |x| try @import("derive.zig").expression(s, unit, x[0], x[1]);
}

// ---- private ----

/// §3.4.7/§9.18 `aliasparam m = $mfactor;` on the root: the first alias of
/// a hierarchical system parameter is a card row of Table 9-29's top-level
/// value, and the root's reads of the parameter read it (the old
/// `aliasSystemParam`); a later alias names the same row.
fn systemAlias(s: *Sema, unit: *Unit, i: Inst.Index) Allocator.Error!void {
    if (unit.prefix.len != 0) return;
    const vir = unit.vir;
    const a = decl.payloadOf(vir, Inst.Aliasparam, i);
    const k = Zcu.SystemParam.fromName(vir.string(a.target)) orelse return;
    if (s.sys_alias.get(k) != null) return;
    const ip = &s.zcu.intern_pool;
    const row: Device.Param.Index = @fromBackingInt(@intCast(s.device.params.len));
    try s.device.params.append(s.gpa, .{
        .name = try ip.getString(s.gpa, vir.string(a.name)),
        .ty = .real,
        .local = false,
        .default = try decl.intern(s, .{ .real = k.initial() }),
        .ranges_start = @intCast(s.device.ranges.items.len),
        .ranges_len = 0,
        .instance = decl.rowInstance(unit.instance),
        .derive = .none,
    });
    const arg = try s.air.addInst(s.gpa, .{ .tag = .arg, .data = .{ .ty_index = .{ .ty = decl.typeIndex(.real), .index = @backingInt(row) } } });
    try s.prologue.append(s.arena, arg);
    try s.param_args.append(s.arena, .{ .ref = .fromIndex(arg), .ty = .real });
    s.sys_alias.set(k, row);
}

/// §6.4.1 a paramset instance's own parameters (the selected paramset's,
/// folded at its level): local rows `u.<paramset>.<name>` with their
/// ranges, ahead of the module's, as the old flattener names them. No
/// statement of the module reads one.
fn paramsetRows(s: *Sema, unit: *Unit) Allocator.Error!void {
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

/// §3.4 a default is a constant expression over "constant numbers and
/// previously defined parameters": the first read in `b` of the operating
/// point or the simulation state (an access, an analog operator, a noise
/// source, an event, `$abstime` and the like, a module variable), or null.
fn stateRead(s: *Sema, unit: *Unit, b: Vir.Body) Allocator.Error!?[]const u8 {
    const vir = unit.vir;
    for (vir.body(b)) |i| switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .call => if (try @import("contrib.zig").accessCall(s, unit, i.toRef())) |a| return a.name,
        .call_sys => {
            const name = vir.string(decl.payloadOf(vir, Inst.SysCall, i).name);
            const t = vams.SysFn.Tag.fromName(name) orelse continue;
            switch (vams.SysFn.get(t).family) {
                .analog_op, .event => return name,
                else => {}, // else: by name below
            }
            for ([_][]const u8{ "$abstime", "$realtime", "$temperature", "$vt", "$random", "$arandom", "analysis" }) |n| if (std.mem.eql(u8, n, name)) return name;
            if (std.mem.startsWith(u8, name, "$dist_") or std.mem.startsWith(u8, name, "$rdist_")) return name;
        },
        .decl_ref => {
            const d = decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl);
            if (vir.instructions.items(.tag)[@backingInt(d)] == .variable) return vir.string(decl.nameOf(vir, d));
        },
        else => {}, // else: an operator over its operands, walked in the body
    };
    return null;
}

/// Appends one card row named `name` (under the unit's prefix) of value
/// `value`, its ranges, and its `arg` in the prologue.
fn addRow(s: *Sema, unit: *Unit, name: []const u8, p: Inst.Param, declared: Device.Param.Type, value: InternPool.Index) Allocator.Error!Device.Param.Index {
    const ip = &s.zcu.intern_pool;
    // §3.4.1 an untyped parameter takes its value's type; one that does
    // not fold is real (the old `lowerParam`).
    const ty: Device.Param.Type = if (declared != .unspecified) declared else switch (ip.indexToKey(value)) {
        .int => .integer,
        .str => .string,
        else => .real, // else: a real, or a value that did not fold
    };
    const row: Device.Param.Index = @fromBackingInt(@intCast(s.device.params.len));
    const ranges_start: u32 = @intCast(s.device.ranges.items.len);
    for (unit.vir.list(Inst.ValueRange, p.ranges)) |r| try s.device.ranges.append(s.gpa, try rangeOf(s, unit, r));
    try s.device.params.append(s.gpa, .{
        .name = try ip.getString(s.gpa, try std.fmt.allocPrint(s.arena, "{s}{s}", .{ unit.prefix, name })),
        .ty = ty,
        // §3.4.5 a localparam and a specparam are no card value.
        .local = p.flags.local or p.flags.kind != .parameter or unit.prefix.len != 0,
        .default = value,
        .ranges_start = ranges_start,
        .ranges_len = @intCast(s.device.ranges.items.len - ranges_start),
        .instance = decl.rowInstance(unit.instance),
        .derive = .none,
    });
    const vty: Sema.Ty = switch (ty) {
        .real => .real,
        .integer => .integer,
        .string => .string,
        .unspecified => switch (ip.indexToKey(value)) {
            .float => .real,
            .str => .string,
            else => .integer, // else: an integer, or an unfoldable default read as one
        },
    };
    const arg = try s.air.addInst(s.gpa, .{ .tag = .arg, .data = .{ .ty_index = .{ .ty = decl.typeIndex(vty), .index = @backingInt(row) } } });
    try s.prologue.append(s.arena, arg);
    try s.param_args.append(s.arena, .{ .ref = .fromIndex(arg), .ty = vty });
    return row;
}

/// §3.4.4 `parameter real c[0:2] = '{1, 2, 3};`: rows `c[0]`, `c[1]`,
/// `c[2]`, each element's value as the declared type (an omitted one its
/// zero); the name an array of slots set from the rows at entry. "A type of
/// a parameter array shall be given" (E0346, read as real after); the value
/// is an assignment pattern (E0349).
fn declareArray(s: *Sema, unit: *Unit, i: Inst.Index, p: Inst.Param, ty0: Device.Param.Type, value: InternPool.Index) Allocator.Error!void {
    const vir = unit.vir;
    const ip = &s.zcu.intern_pool;
    const name = vir.string(p.name);
    if (ty0 == .unspecified) try s.fail(.E0346, unit.file, i.toRef(), "array parameter `{s}` has no declared type", .{name});
    const ty: Device.Param.Type = if (ty0 == .unspecified) .real else ty0;
    const vb = vir.body(p.value);
    if (vb.len != 0 and vir.instructions.items(.tag)[@backingInt(vb[vb.len - 1])] != .pattern)
        try s.fail(.E0349, unit.file, i.toRef(), "initialising array parameter `{s}`", .{name});
    const before = unit.binds.count();
    try decl.declareArray(s, unit, decl.canonical(vir, i), p.dims, if (ty == .integer) .integer else .real);
    if (unit.binds.count() == before) return;
    const arr = unit.binds.get(decl.canonical(vir, i)).?.array;
    const values: []const InternPool.Index = switch (ip.indexToKey(value)) {
        .aggregate => |a| a.elems,
        else => &.{}, // else: no pattern folded; every element is undef
    };
    for (arr.slots, 0..) |slot, k| {
        var label: std.ArrayList(u8) = .empty;
        try label.appendSlice(s.arena, name);
        var rest = k;
        var subs: [8]i64 = undefined;
        var d = arr.dims.len;
        while (d > 0) {
            d -= 1;
            const len: usize = @intCast(@abs(arr.dims[d][0] - arr.dims[d][1]) + 1);
            const off: i64 = @intCast(rest % len);
            rest /= len;
            subs[d] = if (arr.dims[d][0] >= arr.dims[d][1]) arr.dims[d][0] - off else arr.dims[d][0] + off;
        }
        for (subs[0..arr.dims.len]) |x| try label.print(s.arena, "[{d}]", .{x});
        const elem = try asType(s, ty, if (k < values.len) values[k] else .undef, k >= values.len and vb.len != 0);
        const row = try addRow(s, unit, label.items, p, ty, elem);
        try s.entry.append(s.arena, try s.air.addInst(s.gpa, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slot), .rhs = s.param_args.items[@backingInt(row)].ref } } }));
    }
}

/// An element's value as the declared type: §3.4.1 converts it; an
/// omitted element (`zero`) is the type's zero.
fn asType(s: *Sema, ty: Device.Param.Type, v: InternPool.Index, zero: bool) Allocator.Error!InternPool.Index {
    if (zero) return if (ty == .integer) .zero else .zero_real;
    const c = constOfIndex(s, v) orelse return v;
    return switch (ty) {
        .integer => decl.intern(s, .{ .int = std.math.lossyCast(i64, @round(c.asReal())) }),
        .real => decl.intern(s, .{ .real = c.asReal() }),
        .string, .unspecified => v,
    };
}

/// §3.4.2 a parameter's value inside its `from` ranges and outside its
/// `exclude` ones (E0361); a bound folds over every parameter.
fn checkRange(s: *Sema, unit: *Unit, i: Inst.Index, p: Inst.Param, value: InternPool.Index) Allocator.Error!void {
    const vir = unit.vir;
    const ip = &s.zcu.intern_pool;
    const name = vir.string(p.name);
    var has_from = false;
    var in_from = false;
    switch (ip.indexToKey(value)) {
        .str => |t| {
            const text = ip.stringToSlice(t);
            for (vir.list(Inst.ValueRange, p.ranges)) |r| {
                if (!r.flags.set) continue;
                var contains = false;
                for (vir.body(r.lo)) |e| if (vir.instructions.items(.tag)[@backingInt(e)] == .str) {
                    const d = vir.instructions.items(.data)[@backingInt(e)].str;
                    if (std.mem.eql(u8, vir.string_bytes[@backingInt(d.start)..][0..d.len], text)) contains = true;
                };
                if (r.flags.exclude) {
                    if (contains) return s.fail(.E0361, unit.file, i.toRef(), "`{s}` is \"{s}\", which the declared range excludes", .{ name, text });
                } else {
                    has_from = true;
                    in_from = in_from or contains;
                }
            }
            if (has_from and !in_from) try s.fail(.E0361, unit.file, i.toRef(), "`{s}` is \"{s}\", outside the declared range", .{ name, text });
            return;
        },
        .float, .int => {},
        else => return, // else: an unfoldable value is checked by the host
    }
    const v = (constOfIndex(s, value) orelse return).asReal();
    for (vir.list(Inst.ValueRange, p.ranges)) |r| {
        if (r.flags.set) continue;
        const lo = ((try decl.foldBody(s, unit, r.lo)) orelse continue);
        if (lo == .str) continue;
        const hi = if (!r.flags.interval) lo else ((try decl.foldBody(s, unit, r.hi)) orelse continue);
        if (hi == .str) continue;
        const lo_closed = !r.flags.interval or r.flags.lo_closed;
        const hi_closed = !r.flags.interval or r.flags.hi_closed;
        const above = if (lo_closed) v >= lo.asReal() else v > lo.asReal();
        const below = if (hi_closed) v <= hi.asReal() else v < hi.asReal();
        if (r.flags.exclude) {
            if (above and below) return s.fail(.E0361, unit.file, i.toRef(), "`{s}` is {d}, which the declared range excludes", .{ name, v });
        } else {
            has_from = true;
            if (above and below) in_from = true;
        }
    }
    if (has_from and !in_from) try s.fail(.E0361, unit.file, i.toRef(), "`{s}` is {d}, outside the declared range", .{ name, v });
}
fn constOfIndex(s: *const Sema, index: InternPool.Index) ?eval.Const {
    return switch (s.zcu.intern_pool.indexToKey(index)) {
        .float => |f| .{ .real = f },
        .int => |int| switch (int.storage) {
            .small => |x| .{ .int = x },
            .big => null,
        },
        else => null, // else: no number
    };
}
/// §3.4.2 one range, each bound folded over literals alone.
fn rangeOf(s: *Sema, unit: *Unit, r: Inst.ValueRange) Allocator.Error!Device.Range {
    const lo = try literalBound(s, unit, r.lo);
    const hi = if (r.flags.interval) try literalBound(s, unit, r.hi) else lo;
    return .{
        .exclude = r.flags.exclude,
        .lo = if (r.flags.set) null else lo,
        .hi = if (r.flags.set) null else hi,
        .lo_closed = if (r.flags.interval) r.flags.lo_closed else true,
        .hi_closed = if (r.flags.interval) r.flags.hi_closed else true,
        .strings = r.flags.set,
    };
}
/// A bound's value when it reads no name; a NaN or string is none.
fn literalBound(s: *Sema, unit: *Unit, b: Vir.Body) Allocator.Error!?f64 {
    const vir = unit.vir;
    for (vir.body(b)) |i| switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .decl_ref, .str_ref, .call_sys, .call => return null,
        else => {}, // else: a literal or an operator over literals
    };
    const c = (try decl.foldBody(s, unit, b)) orelse return null;
    if (c == .str) return null;
    const x = c.asReal();
    return if (std.math.isNan(x)) null else x;
}
