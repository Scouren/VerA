//! §4.5 analog operators in expression position (the old
//! `analog/analog_op.zig`): a `call_sys` of a Table 4-19 operator in, its
//! value out. `ddt` and `idt` each mint an operator unknown (`ddt$k`,
//! `idt$k`, §4.5.2 "new equations and new unknowns") whose row is a flow
//! contribution on it (the old `stampOpRow`: `ddt(x)` is the unknown `v`
//! with `q = -x`, `idt(x)` the unknown with `f = -x`, or `v - ic` at the
//! static point when an initial condition is given); the others are a
//! `call` of their real operands, a coefficient vector as its length and
//! its elements. An operator that keeps state (all but `ddx`, `limexp`)
//! under a condition that changes during the analysis is E0514.
//! Cites: VAMS-2023 §4.5, §4.5.1, §4.5.2, §4.5.3, §4.5.4, §4.5.13,
//! §4.5.14, Table 4-19, Table 4-20.
//!
//! Contents:
//! - `pub fn lower(s: *Sema, b: *Block, tag: SysFn.Tag, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value`
//! - `pub fn noise(s: *Sema, b: *Block, tag: SysFn.Tag, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value`
//! - `pub fn vectorArg(s: *Sema, b: *Block, r: Inst.Ref, out: *std.ArrayList(Ref)) Allocator.Error!bool`
//! - `pub fn checkPlace(s: *Sema, b: *Block, tag: SysFn.Tag, src: Inst.Ref) Allocator.Error!bool`
//! - `pub fn isStatic(s: *const Sema, r: Air.Inst.Ref, depth: u32) bool`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const expr = @import("expr.zig");
const contrib = @import("contrib.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const SysFn = vams.SysFn;
const Device = Air.Device;
const Node = Device.Node;
const Block = Sema.Block;
const Value = Sema.Value;
const Ref = Air.Inst.Ref;

/// An analog operator call read as a value.
pub fn lower(s: *Sema, b: *Block, tag: SysFn.Tag, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value {
    const file = b.unit.file;
    if (!try checkPlace(s, b, tag, src)) return expr.poison;
    if (tag == .ddx) return ddx(s, b, args, src);
    const min: usize = switch (tag) {
        .absdelay => 2,
        .laplace_zd, .laplace_zp, .laplace_nd, .laplace_np => 3,
        .zi_zd, .zi_zp, .zi_nd, .zi_np => 4,
        else => 1, // else: ddt, idt, idtmod, transition, slew, last_crossing, limexp
    };
    if (args.len < min) {
        try s.fail(.E0505, file, src, "`{t}()` needs {d} argument(s), got {d}", .{ tag, min, args.len });
        return expr.poison;
    }
    try checkBounds(s, b, tag, args, src);
    const coef = switch (tag) {
        .laplace_zd, .laplace_zp, .laplace_nd, .laplace_np, .zi_zd, .zi_zp, .zi_nd, .zi_np => true,
        else => false, // else: no coefficient vector
    };
    var vals: std.ArrayList(Ref) = .empty;
    for (args, 0..) |a, k| {
        if (a == .none) {
            if (k == 1 and (tag == .laplace_zp or tag == .laplace_np or tag == .zi_zp or tag == .zi_np)) {
                try vals.append(s.arena, .fromIntern(.zero));
                continue;
            }
            try s.fail(.E0505, file, src, "`{t}()`", .{tag});
            return expr.poison;
        }
        if (coef and (k == 1 or k == 2)) if (try vectorArg(s, b, a, &vals)) continue;
        const v = try expr.lower(s, b, a);
        try vals.append(s.arena, if (v.ty == .string) v.ref else try expr.coerce(s, b, v, .real));
    }
    switch (tag) {
        .ddt => return .{ .ref = try ddt(s, b, vals.items[0]), .ty = .real },
        .idt => return .{ .ref = try idt(s, b, vals.items), .ty = .real },
        else => return .{ .ref = try expr.call(s, b, @backingInt(tag), .real, vals.items), .ty = .real },
    }
}

/// §4.6.3 `ac_stim` and the §4.6.4 noise sources: a `call` of their
/// operands (a table flattened `count, f0, p0, ...`, a label as its string),
/// recorded in `device.noise`. Its value is 0 outside a small-signal
/// analysis; the host reads the call.
pub fn noise(s: *Sema, b: *Block, tag: SysFn.Tag, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value {
    const file = b.unit.file;
    const vir = b.unit.vir;
    // A.8.2 brackets only trailing optional arguments: no empty slot.
    for (args) |a| if (a == .none) {
        try s.fail(.E0505, file, src, "`{t}()` (A.8.2 gives the small-signal functions no empty slot)", .{tag});
        return expr.poison;
    };
    const most: usize = if (tag == .ac_stim or tag == .flicker_noise) 3 else 2;
    if (args.len > most) {
        try s.fail(.E0506, file, src, "`{t}()` takes at most {d}, and this call passes {d}", .{ tag, most, args.len });
        return expr.poison;
    }
    // A.8.2 quotes `ac_stim`'s analysis name: a string literal.
    if (tag == .ac_stim and args.len != 0 and vir.instructions.items(.tag)[@backingInt(args[0].toIndex().?)] != .str) {
        try s.fail(.E0521, file, src, "", .{});
        return expr.poison;
    }
    // §4.6.4.2 `1/f^exp` has no default exponent.
    if (tag == .flicker_noise and args.len < 2) {
        try s.fail(.E0522, file, src, "got {d} argument(s)", .{args.len});
        return expr.poison;
    }
    // Syntax 4-4: the optional last argument is the source's label.
    const label_at: ?usize = switch (tag) {
        .white_noise, .noise_table, .noise_table_log => 1,
        .flicker_noise => 2,
        else => null, // else: ac_stim's arguments are values
    };
    var label: InternPool.String = .empty;
    if (label_at) |k| if (k < args.len) {
        const c = try decl.foldRef(s, b.unit, args[k]);
        if (c == null or c.? != .str) {
            try s.fail(.E0573, file, src, "`{t}()` argument {d} is its label", .{ tag, k + 1 });
            return expr.poison;
        }
        label = try s.zcu.intern_pool.getString(s.gpa, c.?.str);
    };
    const table = tag == .noise_table or tag == .noise_table_log;
    var vals: std.ArrayList(Ref) = .empty;
    for (args, 0..) |a, k| {
        if (table and k == 0) {
            // §4.6.4.3 a file of frequency/power pairs, read at compile time.
            if (try decl.foldRef(s, b.unit, a)) |c| if (c == .str) {
                const pairs = (try @import("table.zig").noiseFile(s, b, c.str, src)) orelse return expr.poison;
                try vals.append(s.arena, .fromIntern(try decl.intern(s, .{ .int = @intCast(pairs.len) })));
                for (pairs) |x| try vals.append(s.arena, .fromIntern(try decl.intern(s, .{ .real = x })));
                continue;
            };
            if (try vectorArg(s, b, a, &vals)) continue;
        }
        const v = try expr.lower(s, b, a);
        try vals.append(s.arena, if (v.ty == .string) v.ref else try expr.coerce(s, b, v, .real));
    }
    const r = try expr.call(s, b, @backingInt(tag), .real, vals.items);
    try s.device.noise.append(s.gpa, .{
        .kind = switch (tag) {
            .white_noise => .thermal,
            .flicker_noise => .flicker,
            .noise_table => .table,
            .noise_table_log => .table_log,
            .ac_stim => .ac_stim,
            else => unreachable, // else: the caller routes the small-signal sources here
        },
        .call = r.toIndex().?,
        .name = label,
    });
    return .{ .ref = r, .ty = .real };
}

/// §5.8.1: an operator with state may not stand under a condition that
/// changes during the analysis (E0514); none in a function (E0422).
pub fn checkPlace(s: *Sema, b: *Block, tag: SysFn.Tag, src: Inst.Ref) Allocator.Error!bool {
    const historyless = tag == .ddx or tag == .limexp;
    if (b.restricted()) |ctx| {
        try s.fail(.E0422, b.unit.file, src, "not allowed in {s}", .{ctx});
        return false;
    }
    if (b.runtime != 0 and !historyless) try s.fail(.E0514, b.unit.file, src, "`{t}`", .{tag});
    return true;
}

/// Whether `r` keeps one value through the analysis: a constant, a
/// parameter, or an operation on such (the old `static.isStaticValue`).
pub fn isStatic(s: *const Sema, r: Ref, depth: u32) bool {
    if (r.toInterned() != null) return true;
    const i = r.toIndex() orelse return true;
    if (depth > expr.depth_max) return false;
    const data = s.air.instructions.items(.data)[@backingInt(i)];
    const tag = s.air.instructions.items(.tag)[@backingInt(i)];
    return switch (tag) {
        .arg => true,
        .load => s.static_loads.contains(i),
        .probe, .alloc, .path_prev, .path_acc, .block, .anew, .fload, .iload, .store => false,
        .call => blk: {
            const x = s.air.extra.items[data.ty_pl.payload];
            break :blk x == @backingInt(SysFn.Tag.analysis) or x == @backingInt(SysFn.Tag.@"$param_given") or x == @backingInt(SysFn.Tag.@"$port_connected");
        },
        .select => blk: {
            const bin = s.air.extra.items[data.pl_op.payload..][0..2];
            break :blk isStatic(s, data.pl_op.operand, depth + 1) and isStatic(s, @fromBackingInt(bin[0]), depth + 1) and isStatic(s, @fromBackingInt(bin[1]), depth + 1);
        },
        else => switch (Air.tag_info.getPtrConst(tag).class) {
            .un_op => isStatic(s, data.un_op, depth + 1),
            .bin_op => isStatic(s, data.bin_op.lhs, depth + 1) and isStatic(s, data.bin_op.rhs, depth + 1),
            .pl_op, .ty_pl, .ty, .ty_index, .br, .repeat => false,
        },
    };
}

/// A coefficient vector (`'{a, b}`, `{a, b}`, or a §3.2.2 array's name):
/// its length, then each element as a real. False for any other argument.
pub fn vectorArg(s: *Sema, b: *Block, r: Inst.Ref, out: *std.ArrayList(Ref)) Allocator.Error!bool {
    const i = r.toIndex() orelse return false;
    const vir = b.unit.vir;
    switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .pattern, .concat => {
            const elems = vir.list(Inst.Ref, decl.payloadOf(vir, Inst.Refs, i));
            try out.append(s.arena, .fromIntern(try decl.intern(s, .{ .int = @intCast(elems.len) })));
            for (elems) |e| try out.append(s.arena, try expr.coerce(s, b, try expr.lower(s, b, e), .real));
            return true;
        },
        .decl_ref => {
            const bind = b.unit.binds.get(decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl)) orelse return false;
            if (bind != .array) return false;
            const arr = bind.array;
            try out.append(s.arena, .fromIntern(try decl.intern(s, .{ .int = @intCast(arr.slots.len) })));
            for (arr.slots) |slot| {
                const v = try s.addInst(b, .{ .tag = .load, .data = .{ .un_op = .fromIndex(slot) } });
                try out.append(s.arena, try expr.coerce(s, b, .{ .ref = v, .ty = arr.ty }, .real));
            }
            return true;
        },
        else => return false, // else: a select of an array: not lowered yet
    }
}

// ---- private ----

/// §4.5.14 `ddx(f, V(n))` / `ddx(f, I(br))`: a `ddx` call of `f` and the
/// unknown's row, negated when the access spells the pair reversed; 0 when
/// the flow it names was never read (f cannot depend on it).
fn ddx(s: *Sema, b: *Block, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value {
    const f = try expr.coerce(s, b, try expr.lower(s, b, args[0]), .real);
    const access = (try contrib.accessCall(s, b.unit, args[1])) orelse {
        try s.fail(.E0504, b.unit.file, src, "", .{});
        return expr.poison;
    };
    const t = (try contrib.target(s, b, access.name, access.args, src)) orelse return expr.poison;
    // §4.5.14: the potential of a scalar net or the flow through a branch;
    // `V(p, n)` is two unknowns.
    if (t.access == .potential and t.lo != .ground) {
        try s.fail(.E0504, b.unit.file, src, "a potential across two nets is not one unknown", .{});
        return expr.poison;
    }
    const u: Node.Index = switch (t.access) {
        .potential => t.hi,
        .flow => s.flow_rows.get(.{ t.hi, t.lo }) orelse return .{ .ref = .fromIntern(.zero_real), .ty = .real },
    };
    const d = try expr.call(s, b, @backingInt(SysFn.Tag.ddx), .real, &.{ f, .fromIntern(try decl.intern(s, .{ .int = @backingInt(u) })) });
    return .{ .ref = if (t.neg) try expr.unOp(s, b, .fneg, d) else d, .ty = .real };
}

/// §4.5.3 `ddt(x)` outside a contribution's linear spine.
fn ddt(s: *Sema, b: *Block, x: Ref) Allocator.Error!Ref {
    const n = try opNode(s, b, "ddt");
    const v = try contrib.probe(s, n);
    try stampOpRow(s, b, n, v, x, true);
    return v;
}

/// §4.5.4 `idt(x[, ic[, assert[, abstol]]])`.
fn idt(s: *Sema, b: *Block, vals: []const Ref) Allocator.Error!Ref {
    const x = vals[0];
    const n = try opNode(s, b, "idt");
    const v = try contrib.probe(s, n);
    const ic: ?Ref = if (vals.len > 1) vals[1] else if (!readsUnknown(s, x, 0)) .fromIntern(.zero_real) else null;
    const hold: ?Ref = if (vals.len > 2) try expr.binOp(s, b, .fne, vals[2], .fromIntern(.zero_real)) else null;
    var f = try expr.unOp(s, b, .fneg, x);
    if (hold) |h| f = try select(s, b, h, .fromIntern(.zero_real), f);
    if (ic) |c| f = try select(s, b, try expr.call(s, b, @backingInt(SysFn.Tag.@"op$static"), .integer, &.{}), try expr.binOp(s, b, .fsub, v, c), f);
    try stampOpRow(s, b, n, f, v, false);
    if (hold != null) return expr.call(s, b, @backingInt(SysFn.Tag.@"idt$hold"), .real, &.{ v, ic.?, vals[2] });
    return v;
}

fn select(s: *Sema, b: *Block, c: Ref, x: Ref, y: Ref) Allocator.Error!Ref {
    const at = try s.air.addExtra(s.gpa, Air.Bin{ .lhs = x, .rhs = y });
    return s.addInst(b, .{ .tag = .select, .data = .{ .pl_op = .{ .operand = c, .payload = at } } });
}

/// A §4.5.2 operator unknown, `<op>$<k>`.
fn opNode(s: *Sema, b: *const Block, op: []const u8) Allocator.Error!Node.Index {
    const ip = &s.zcu.intern_pool;
    const row: Node.Index = @fromBackingInt(@intCast(s.device.nodes.len));
    const name = try std.fmt.allocPrint(s.arena, "{s}${d}", .{ op, s.op_states });
    s.op_states += 1;
    try s.device.nodes.append(s.gpa, .{ .name = try ip.getString(s.gpa, name), .kind = .op_state, .of = .none, .discipline = .empty, .instance = decl.rowInstance(b.unit.instance) });
    return row;
}

/// The old `reactive.stampOpRow`: the operator unknown's own row, a flow
/// contribution on (`n`, ground) whose resistive part is `f` (the unknown
/// itself before the operator runs) and whose charge is `q`.
fn stampOpRow(s: *Sema, b: *Block, n: Node.Index, f: Ref, q: Ref, q_neg: bool) Allocator.Error!void {
    const row = try contrib.rowOf(s, b, .{ .access = .flow, .branch = .unnamed, .hi = n, .lo = .ground, .neg = false });
    const slots = s.device.contributions.get(@backingInt(row));
    // At entry: the unknown and the flag, so a row whose operator does not
    // run still pins it.
    try s.entry.append(s.arena, try s.air.addInst(s.gpa, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slots.resist), .rhs = try contrib.probe(s, n) } } }));
    try s.entry.append(s.arena, try s.air.addInst(s.gpa, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slots.wrote), .rhs = .fromIntern(.one_real) } } }));
    _ = try s.addInst(b, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slots.resist), .rhs = f } } });
    const react = if (q_neg) try expr.unOp(s, b, .fneg, q) else q;
    _ = try s.addInst(b, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slots.react), .rhs = react } } });
    try s.react_written.put(s.arena, row, {});
    const site = try decl.addAlloc(s, .real);
    _ = try s.addInst(b, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(site), .rhs = q } } });
    try s.device.charge_sites.append(s.gpa, .{ .contrib = row, .sign = if (q_neg) -1.0 else 1.0, .slot = site });
}

/// §4.5.5-§4.5.10 the control arguments' bounds, judged when they fold
/// (E0516): A.8.2 types them `analog_expression`, so one over parameters
/// may fold and one over the solve may not.
fn checkBounds(s: *Sema, b: *Block, tag: SysFn.Tag, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!void {
    const Bound = enum { positive, non_negative, negative };
    const Rule = struct { i: usize, arg: []const u8, want: Bound };
    const rules: []const Rule = switch (tag) {
        .idtmod => &.{.{ .i = 2, .arg = "modulus", .want = .positive }},
        .absdelay => &.{.{ .i = 1, .arg = "td", .want = .positive }},
        .transition => &.{
            .{ .i = 1, .arg = "td", .want = .non_negative },
            .{ .i = 2, .arg = "rise_time", .want = .non_negative },
            .{ .i = 3, .arg = "fall_time", .want = .non_negative },
            .{ .i = 4, .arg = "time_tol", .want = .non_negative },
        },
        // On the written arguments, before §4.5.9's default negates the first.
        .slew => &.{
            .{ .i = 1, .arg = "max_pos_slew_rate", .want = .positive },
            .{ .i = 2, .arg = "max_neg_slew_rate", .want = .negative },
        },
        else => &.{}, // else: no bounded control argument
    };
    for (rules) |r| {
        if (r.i >= args.len or args[r.i] == .none) continue;
        const c = (try decl.foldRef(s, b.unit, args[r.i])) orelse continue;
        if (c == .str) continue;
        const v = c.asReal();
        const holds = switch (r.want) {
            .positive => v > 0,
            .non_negative => v >= 0,
            .negative => v < 0,
        };
        if (!holds) try s.fail(.E0516, b.unit.file, src, "`{t}()` argument `{s}` shall be {t}, got {d}", .{ tag, r.arg, r.want, v });
    }
    // §4.5.10 the direction indicator is +1, -1 or 0.
    if (tag == .last_crossing and args.len > 1 and args[1] != .none) if (try decl.foldRef(s, b.unit, args[1])) |c| {
        const v = c.asReal();
        if (c != .str and (v != @round(v) or @abs(v) > 1)) try s.fail(.E0516, b.unit.file, src, "`last_crossing()` direction indicator shall be +1, -1 or 0, got {d}", .{v});
    };
}

/// Whether `r` depends on a solver unknown or a path latch.
fn readsUnknown(s: *const Sema, r: Ref, depth: u32) bool {
    const i = r.toIndex() orelse return false;
    if (depth > expr.depth_max) return true;
    const data = s.air.instructions.items(.data)[@backingInt(i)];
    const tag = s.air.instructions.items(.tag)[@backingInt(i)];
    return switch (tag) {
        .probe, .path_prev, .path_acc, .load, .block, .anew, .fload, .iload, .store => true,
        .arg, .alloc => false,
        .call => blk: {
            const x = s.air.extra.items[data.ty_pl.payload..][0..2];
            for (s.air.extra.items[data.ty_pl.payload + 2 ..][0..x[1]]) |w| if (readsUnknown(s, @fromBackingInt(w), depth + 1)) break :blk true;
            break :blk false;
        },
        .select => blk: {
            const bin = s.air.extra.items[data.pl_op.payload..][0..2];
            break :blk readsUnknown(s, data.pl_op.operand, depth + 1) or readsUnknown(s, @fromBackingInt(bin[0]), depth + 1) or readsUnknown(s, @fromBackingInt(bin[1]), depth + 1);
        },
        else => switch (Air.tag_info.getPtrConst(tag).class) {
            .un_op => readsUnknown(s, data.un_op, depth + 1),
            .bin_op => readsUnknown(s, data.bin_op.lhs, depth + 1) or readsUnknown(s, data.bin_op.rhs, depth + 1),
            .pl_op, .ty_pl, .ty, .ty_index, .br, .repeat => true,
        },
    };
}
