//! §9.17 analog kernel control and limiting (the old `analog/limit.zig`
//! and `analog/kernel_ctl.zig`): a `$limit`, `$bound_step`,
//! `$discontinuity` or `$vera_reject_step` call in. `$limit`'s function
//! form inlines the user function over the access function's value and its
//! slot's previous-iterate value, keeps the result in the slot (one
//! `device.limit_slots` row per access function) and returns `limit$uf` of
//! the two; its string forms are a `$limit` call. The three requests are
//! running minimums (a flag for `$discontinuity(-1)`) in the slots of
//! `device.kernel`, seeded at entry.
//! Cites: VAMS-2023 §4.7, §9.17.1, §9.17.2, §9.17.3.
//!
//! Contents:
//! - `pub fn lower(s: *Sema, b: *Block, tag: SysFn.Tag, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Air = @import("air");
const fold = @import("kernels").fold;
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const expr = @import("expr.zig");
const contrib = @import("contrib.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const SysFn = vams.SysFn;
const Block = Sema.Block;
const Value = Sema.Value;
const Ref = Air.Inst.Ref;

/// A kernel-family call: its value (`$limit`'s), or 0 for a request.
pub fn lower(s: *Sema, b: *Block, tag: SysFn.Tag, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value {
    const zero: Value = .{ .ref = .fromIntern(.zero_real), .ty = .real };
    switch (tag) {
        .@"$limit" => return limit(s, b, args, src),
        .@"$bound_step" => try boundStep(s, b, args, src),
        .@"$discontinuity" => try discontinuity(s, b, args, src),
        .@"$vera_reject_step" => try rejectStep(s, b, args, src),
        .@"$table_model" => return @import("table.zig").lower(s, b, args, src),
        .@"limit$old", .@"limit$uf" => {
            try s.fail(.E0512, b.unit.file, src, "`{t}` is not lowered by Sema yet", .{tag});
            return expr.poison;
        },
        else => unreachable, // else: the caller routes the kernel family here
    }
    return zero;
}

// ---- private ----

/// §9.17.3 `$limit(access, fn_or_string, args...)`.
fn limit(s: *Sema, b: *Block, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value {
    const unit = b.unit;
    const file = unit.file;
    if (args.len == 0) {
        try s.fail(.E0506, file, src, "`$limit` takes an access function", .{});
        return expr.poison;
    }
    // Syntax 9-12 spells the first argument access_function_reference.
    const access = (try contrib.accessCall(s, unit, args[0])) orelse {
        try s.fail(.E0891, file, src, "its first argument is not an access function reference", .{});
        return expr.poison;
    };
    if (args.len >= 2) if (try decl.foldRef(s, unit, args[1])) |c| if (c == .str) {
        const need: usize = if (std.mem.eql(u8, c.str, "pnjlim")) 4 else if (std.mem.eql(u8, c.str, "fetlim")) 3 else 0;
        if (need != 0 and args.len < need) {
            try s.fail(.E0809, file, src, "`\"{s}\"` needs {d} arguments to `$limit`, got {d}", .{ c.str, need, args.len });
            return expr.poison;
        }
    };
    if (args.len >= 2) if (userFunction(unit, args[1])) |f| return limitUser(s, b, f, access, args, src);
    const vals = try s.arena.alloc(Ref, args.len);
    for (args, vals, 0..) |a, *v, k| {
        if (a == .none) {
            v.* = .fromIntern(.zero_real);
            continue;
        }
        const x = try expr.lower(s, b, a);
        // §9.17.3: a second argument is a string or an analog function.
        if (k == 1 and x.ty != .string) {
            try s.fail(.E0891, file, src, "its second argument is neither a string nor an analog function", .{});
            return expr.poison;
        }
        v.* = if (x.ty == .string) x.ref else try expr.coerce(s, b, x, .real);
    }
    return .{ .ref = try expr.call(s, b, @backingInt(SysFn.Tag.@"$limit"), .real, vals), .ty = .real };
}

/// The §4.7 function `r` names (a variable or parameter of the name wins,
/// as the name's binding says), or null.
fn userFunction(unit: *const Sema.Unit, r: Inst.Ref) ?Inst.Index {
    const vir = unit.vir;
    const i = r.toIndex() orelse return null;
    if (vir.instructions.items(.tag)[@backingInt(i)] != .decl_ref) return null;
    const d = decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl);
    return if (vir.instructions.items(.tag)[@backingInt(d)] == .function) d else null;
}

/// Syntax 9-12's third form: `f(vnew, vold, args[2..]...)` inlined, its
/// value kept in the access function's slot; the result carries the access
/// function's derivative (`limit$uf(vnew, vlim)`), so the host stamps
/// `I(vlim) + g·(v - vlim)`.
fn limitUser(s: *Sema, b: *Block, f: Inst.Index, access: contrib.AccessCall, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value {
    const vnew: Value = .{ .ref = try expr.coerce(s, b, try expr.lower(s, b, args[0]), .real), .ty = .real };
    // A port access (`I(<p>)`) keys no state: §4.5.15 lets the simulator
    // decline the request, the one answer that invents nothing.
    const by_port = for (access.args) |a| {
        const i = a.toIndex() orelse continue;
        if (b.unit.vir.instructions.items(.tag)[@backingInt(i)] == .port_branch) break true;
    } else false;
    if (by_port) return .{ .ref = try expr.call(s, b, @backingInt(SysFn.Tag.@"$limit"), .real, &.{vnew.ref}), .ty = .real };
    const t = (try contrib.target(s, b, access.name, access.args, src)) orelse return expr.poison;
    const row = try slotOf(s, t);
    const slot = s.device.limit_slots.items(.slot)[row];
    // The seed, not the running value: every site on one access function
    // reads the previous iterate's value (§9.17.3's second argument).
    const old: Value = .{ .ref = s.limit_seeds.items[row], .ty = .real };
    const res = try expr.coerce(s, b, try @import("func.zig").call(s, b, f, &.{ vnew, old }, args[2..], src), .real);
    _ = try s.addInst(b, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slot), .rhs = res } } });
    return .{ .ref = try expr.call(s, b, @backingInt(SysFn.Tag.@"limit$uf"), .real, &.{ vnew.ref, res }), .ty = .real };
}

/// The `limit_slots` row of `t`, minted on its first site: its slot seeded
/// at entry with `limit$old` of the row's ordinal.
fn slotOf(s: *Sema, t: contrib.Target) Allocator.Error!usize {
    const d = &s.device;
    for (0..d.limit_slots.len) |k| {
        const row = d.limit_slots.get(k);
        if (row.access == t.access and row.branch == t.branch and row.hi == t.hi and row.lo == t.lo and row.neg == t.neg) return k;
    }
    const k = d.limit_slots.len;
    const slot = try decl.addAlloc(s, .real);
    const ordinal: Ref = .fromIntern(try decl.intern(s, .{ .int = @intCast(k) }));
    var entry: Block = .{ .parent = null, .unit = &s.units.items[0] };
    const seed = try expr.call(s, &entry, @backingInt(SysFn.Tag.@"limit$old"), .real, &.{ordinal});
    try s.entry.appendSlice(s.arena, entry.insts.items);
    try s.entry.append(s.arena, try s.air.addInst(s.gpa, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slot), .rhs = seed } } }));
    try s.limit_seeds.append(s.arena, seed);
    try d.limit_slots.append(s.gpa, .{
        .label = try s.zcu.intern_pool.getString(s.gpa, try std.fmt.allocPrint(s.arena, "{s}({s},{s})", .{ if (t.access == .potential) "V" else "I", contrib.nodeName(s, t.hi), contrib.nodeName(s, t.lo) })),
        .access = t.access,
        .branch = t.branch,
        .hi = t.hi,
        .lo = t.lo,
        .neg = t.neg,
        .slot = slot,
    });
    assert(s.limit_seeds.items.len == d.limit_slots.len);
    return k;
}

/// §9.17.2 `$bound_step(expr)`: the smallest step asked for.
fn boundStep(s: *Sema, b: *Block, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!void {
    if (args.len != 1 or args[0] == .none) return s.fail(.E0802, b.unit.file, src, "got {d}", .{args.len});
    // "The expression argument shall be non-negative".
    if (try decl.foldRef(s, b.unit, args[0])) |c| if (c.asReal() < 0) return s.fail(.E0803, b.unit.file, src, "got {d}", .{c.asReal()});
    const v = try expr.coerce(s, b, try expr.lower(s, b, args[0]), .real);
    try runningMin(s, b, &s.device.kernel.bound_step, v);
}

/// VerA's `$vera_reject_step(t_retry)`: the earliest retry asked for.
fn rejectStep(s: *Sema, b: *Block, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!void {
    // An analog initial block and a function call are no accepted step.
    if (b.function != null or b.analog_initial) return s.fail(.E0533, b.unit.file, src, "in {s}", .{if (b.function != null) "an analog function" else "an analog initial block"});
    if (args.len != 1 or args[0] == .none) return s.fail(.E0506, b.unit.file, src, "`$vera_reject_step` takes 1", .{});
    const v = try expr.coerce(s, b, try expr.lower(s, b, args[0]), .real);
    try runningMin(s, b, &s.device.kernel.reject_step, v);
}

/// §9.17.1 `$discontinuity[(degree)]`: the smallest degree announced, or
/// at -1 the request to reject the iteration.
fn discontinuity(s: *Sema, b: *Block, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!void {
    const file = b.unit.file;
    const given = for (args) |a| {
        if (a != .none) break args;
    } else args[0..0];
    if (given.len > 1) return s.fail(.E0804, file, src, "got {d}", .{given.len});
    var degree: i64 = 0;
    if (given.len == 1) {
        const c = (try decl.foldRef(s, b.unit, given[0])) orelse return s.fail(.E0805, file, src, "", .{});
        if (c == .str) {
            // §3.3: a string literal is its packed bytes; a string
            // parameter has no integer to be.
            const i = given[0].toIndex().?;
            if (b.unit.vir.instructions.items(.tag)[@backingInt(i)] != .str) return s.fail(.E0820, file, src, "got a `string` value, \"{s}\", which is not an integer", .{c.str});
            degree = fold.strToInt(c.str, 32);
        } else degree = c.asIntExact() orelse return s.fail(.E0820, file, src, "got {e}", .{c.asReal()});
    }
    if (degree < -1) return s.fail(.E0820, file, src, "got {d}", .{degree});
    if (degree == -1) {
        const slot = s.device.kernel.reject_iteration orelse blk: {
            const a = try decl.addAlloc(s, .integer);
            try s.entry.append(s.arena, try s.air.addInst(s.gpa, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(a), .rhs = .fromIntern(.zero) } } }));
            s.device.kernel.reject_iteration = a;
            break :blk a;
        };
        _ = try s.addInst(b, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slot), .rhs = .fromIntern(.one) } } });
        return;
    }
    try runningMin(s, b, &s.device.kernel.discontinuity, .fromIntern(try decl.intern(s, .{ .real = @floatFromInt(degree) })));
}

/// `slot = min(slot, v)`, the slot minted on first use and seeded +inf at
/// entry (`fmin`'s identity: "nothing was asked").
fn runningMin(s: *Sema, b: *Block, field: *?Air.Inst.Index, v: Ref) Allocator.Error!void {
    const slot = field.* orelse blk: {
        const a = try decl.addAlloc(s, .real);
        const inf: Ref = .fromIntern(try decl.intern(s, .{ .real = std.math.inf(f64) }));
        try s.entry.append(s.arena, try s.air.addInst(s.gpa, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(a), .rhs = inf } } }));
        field.* = a;
        break :blk a;
    };
    const cur = try s.addInst(b, .{ .tag = .load, .data = .{ .un_op = .fromIndex(slot) } });
    const m = try expr.binOp(s, b, .fmin, cur, v);
    _ = try s.addInst(b, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slot), .rhs = m } } });
}
