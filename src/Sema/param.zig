//! §3.4 parameters (the old `analog/param.zig`): one instance's `param`
//! declarations in, its rows of the model card out (`device.params`, each
//! read by an `arg` in the prologue): the root's on the card, a child's as
//! local rows named by its path (`u1.r`), every one with its folded value
//! and its §3.4.2 ranges (a bound folded over literals alone, as the prover
//! reads it). A value outside its declared ranges is E0361.
//! Cites: VAMS-2023 §3.4, §3.4.1, §3.4.2, §3.4.5.
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
    var at: usize = 0;
    for ([_]Vir.Body{ unit.module.params, unit.module.body }) |b| for (vir.body(b)) |i| {
        if (vir.instructions.items(.tag)[@backingInt(i)] != .param) continue;
        defer at += 1;
        const p = decl.payloadOf(vir, Inst.Param, i);
        if (p.flags.kind == .specparam) continue;
        const ty: Device.Param.Type = switch (p.flags.storage) {
            .real, .realtime => .real,
            .integer, .time => .integer,
            .string => .string,
            .none, .reg => if (p.range.len != 0) .integer else .unspecified,
        };
        const row: Device.Param.Index = @fromBackingInt(@intCast(s.device.params.len));
        const ranges_start: u32 = @intCast(s.device.ranges.items.len);
        for (vir.list(Inst.ValueRange, p.ranges)) |r| try s.device.ranges.append(s.gpa, try rangeOf(s, unit, r));
        try s.device.params.append(s.gpa, .{
            .name = try ip.getString(s.gpa, try std.fmt.allocPrint(s.arena, "{s}{s}", .{ unit.prefix, vir.string(p.name) })),
            .ty = ty,
            .local = p.flags.local or unit.prefix.len != 0,
            .default = elems[at],
            .ranges_start = ranges_start,
            .ranges_len = @intCast(s.device.ranges.items.len - ranges_start),
        });
        try unit.binds.put(s.arena, decl.canonical(vir, i), .{ .param = row });
        try checkRange(s, unit, i, p, elems[at]);
        const vty: Sema.Ty = switch (ty) {
            .real => .real,
            .integer => .integer,
            .string => .string,
            .unspecified => switch (ip.indexToKey(elems[at])) {
                .float => .real,
                .str => .string,
                else => .integer, // else: an integer, or an unfoldable default read as one
            },
        };
        const arg = try s.air.addInst(s.gpa, .{ .tag = .arg, .data = .{ .ty_index = .{ .ty = decl.typeIndex(vty), .index = @backingInt(row) } } });
        try s.prologue.append(s.arena, arg);
        try s.param_args.append(s.arena, .{ .ref = .fromIndex(arg), .ty = vty });
    };
    assert(s.param_args.items.len == s.device.params.len);
}

// ---- private ----

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
