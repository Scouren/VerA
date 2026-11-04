//! §3.3 strings (the old `analog/expr_concat.zig`, the string half of
//! `expr_op.zig` and `string_io.zig`'s writers): two string operands of a
//! comparison, a concatenation or replication, or a `$sformat`/`$swrite`
//! in; a string or integer `Value` out. Constant operands fold here; a
//! string known only while the device runs goes through the synthetic
//! calls `str$cmp` (-1, 0, 1), `str$cat` and `str$repeat`, which the host
//! computes, as the old `$str$cat`/`$str$repeat`.
//! Cites: VAMS-2023 §3.3 (Table 3-3), §4.2.13, §9.5.3.
//!
//! Contents:
//! - `pub fn compare(s: *Sema, b: *Block, tag: Inst.Tag, x: Value, y: Value) Allocator.Error!Value`
//! - `pub fn concat(s: *Sema, b: *Block, i: Inst.Index, src: Inst.Ref) Allocator.Error!Value`
//! - `pub fn write(s: *Sema, b: *Block, tag: SysFn.Tag, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!void`
//! - `pub fn read(s: *Sema, b: *Block, tag: SysFn.Tag, first: usize, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const expr = @import("expr.zig");
const Inst = vams.Vir.Inst;
const SysFn = vams.SysFn;
const Block = Sema.Block;
const Value = Sema.Value;
const Ref = Air.Inst.Ref;

/// The longest string a constant replication folds to.
const concat_bytes_max: u64 = 1 << 20;

/// §3.3 Table 3-3's equality and relational operators over two strings: an
/// integer 0 or 1, lexicographic.
pub fn compare(s: *Sema, b: *Block, tag: Inst.Tag, x: Value, y: Value) Allocator.Error!Value {
    assert(x.ty == .string and y.ty == .string);
    const order: Ref = blk: {
        if (expr.constOf(s, x.ref)) |cx| if (expr.constOf(s, y.ref)) |cy| {
            const o: i64 = switch (std.mem.order(u8, cx.str, cy.str)) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            };
            break :blk .fromIntern(try decl.intern(s, .{ .int = o }));
        };
        break :blk try expr.call(s, b, @backingInt(SysFn.Tag.@"str$cmp"), .integer, &.{ x.ref, y.ref });
    };
    const t: Air.Inst.Tag = switch (tag) {
        .lt => .ilt,
        .gt => .igt,
        .lte => .ile,
        .gte => .ige,
        .eq, .case_eq => .ieq,
        else => .ine, // else: `!=` and `!==`, the rest of the comparisons
    };
    return .{ .ref = try expr.binOp(s, b, t, order, .fromIntern(.zero)), .ty = .integer };
}

/// §3.3 Table 3-3 `{s1, s2}` and `{n{s}}`: the joined string, folded when
/// every operand and the count are constants (E0326 an empty list, E0327 a
/// count that is negative, no integer, or a run-time real), else `str$cat`
/// and `str$repeat`. A sized-integer operand is not lowered yet.
pub fn concat(s: *Sema, b: *Block, i: Inst.Index, src: Inst.Ref) Allocator.Error!Value {
    const vir = b.unit.vir;
    const repl = vir.instructions.items(.tag)[@backingInt(i)] == .replicate;
    var copies: i64 = 1;
    var count: ?Ref = null;
    var list = i;
    if (repl) {
        const x = decl.payloadOf(vir, Inst.Bin, i);
        if (try decl.foldRef(s, b.unit, x.lhs)) |n| {
            copies = n.asIntExact() orelse return fail(s, b, src, "a replication constant shall be a finite integer after conversion");
            if (copies < 0) return fail(s, b, src, "a replication constant shall be non-negative");
        } else {
            const n = try expr.lower(s, b, x.lhs);
            if (n.ty != .integer) return fail(s, b, src, "a nonconstant replication multiplier shall be of integral type");
            count = n.ref;
        }
        list = x.rhs.toIndex() orelse return expr.poison;
        if (vir.instructions.items(.tag)[@backingInt(list)] != .concat) return refuse(s, b, src);
    }
    const elems = vir.list(Inst.Ref, decl.payloadOf(vir, Inst.Refs, list));
    if (elems.len == 0) {
        try s.fail(.E0326, b.unit.file, src, "", .{});
        return expr.poison;
    }
    // The current run of constant operands, and the parts in order.
    var run: std.ArrayList(u8) = .empty;
    var parts: std.ArrayList(Ref) = .empty;
    for (elems) |el| {
        const v = try expr.lower(s, b, el);
        if (v.ty != .string) return refuse(s, b, src);
        if (expr.constOf(s, v.ref)) |c| {
            try run.appendSlice(s.arena, c.str);
            continue;
        }
        if (run.items.len != 0) try parts.append(s.arena, .fromIntern(try decl.intern(s, .{ .str = try run.toOwnedSlice(s.arena) })));
        try parts.append(s.arena, v.ref);
    }
    if (parts.items.len == 0 and count == null) {
        const one = run.items;
        // N copies of "" are "", never counted out.
        if (one.len == 0 or copies == 1) return str(s, one);
        if (std.math.mul(u64, one.len, @intCast(copies)) catch std.math.maxInt(u64) <= concat_bytes_max) {
            var all: std.ArrayList(u8) = .empty;
            for (0..@intCast(copies)) |_| try all.appendSlice(s.arena, one);
            return str(s, all.items);
        }
    }
    if (run.items.len != 0 or parts.items.len == 0) try parts.append(s.arena, .fromIntern(try decl.intern(s, .{ .str = run.items })));
    const joined = if (parts.items.len == 1) parts.items[0] else try expr.call(s, b, @backingInt(SysFn.Tag.@"str$cat"), .string, parts.items);
    if (count == null and copies == 1) return .{ .ref = joined, .ty = .string };
    const n = count orelse Ref.fromIntern(try decl.intern(s, .{ .int = copies }));
    return .{ .ref = try expr.call(s, b, @backingInt(SysFn.Tag.@"str$repeat"), .string, &.{ n, joined }), .ty = .string };
}

/// §9.5.3 `$sformat(s, fmt, args...)` and `$swrite(s, args...)`: `s`
/// assigned the call's string, which the host formats.
pub fn write(s: *Sema, b: *Block, tag: SysFn.Tag, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!void {
    if (args.len == 0 or args[0] == .none) return s.fail(.E0506, b.unit.file, src, "`{t}` writes its first argument", .{tag});
    const refs = try s.arena.alloc(Ref, args.len - 1);
    for (args[1..], refs) |a, *r| r.* = if (a == .none) .fromIntern(.zero_real) else (try expr.lower(s, b, a)).ref;
    const v = try expr.call(s, b, @backingInt(tag), .string, refs);
    try @import("control.zig").assignTo(s, b, args[0], .{ .ref = v, .ty = .string }, src);
}

/// §9.5.4 `$sscanf`/`$fscanf`/`$fgets` and §9.12 `$value$plusargs`: an
/// integer `call` of the operands it reads (its count or status), then
/// each destination (argument `first`, and every one after it for a scan)
/// assigned `scan$item(call, k)` (a number, coerced) or `scan$str(call, k)`.
pub fn read(s: *Sema, b: *Block, tag: SysFn.Tag, first: usize, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value {
    const many = first >= 2;
    var ops: std.ArrayList(Ref) = .empty;
    for (args, 0..) |a, k| {
        if (k == first or (many and k > first)) continue;
        try ops.append(s.arena, if (a == .none) .fromIntern(.zero_real) else (try expr.lower(s, b, a)).ref);
    }
    const r = try expr.call(s, b, @backingInt(tag), .integer, ops.items);
    for (args, 0..) |a, k| {
        if (!(k == first or (many and k > first)) or a == .none) continue;
        const ty = try destType(s, b, a);
        const at: Ref = .fromIntern(try decl.intern(s, .{ .int = @intCast(k - first) }));
        const v: Value = if (ty == .string)
            .{ .ref = try expr.call(s, b, @backingInt(SysFn.Tag.@"scan$str"), .string, &.{ r, at }), .ty = .string }
        else
            .{ .ref = try expr.call(s, b, @backingInt(SysFn.Tag.@"scan$item"), .real, &.{ r, at }), .ty = .real };
        try @import("control.zig").assignTo(s, b, a, v, src);
    }
    return .{ .ref = r, .ty = .integer };
}

// ---- private ----

/// The type of the variable (or array element) `r` names; real when it
/// names none (the assignment reports it).
fn destType(s: *Sema, b: *Block, r: Inst.Ref) Allocator.Error!Sema.Ty {
    _ = s;
    const vir = b.unit.vir;
    var at = r;
    for (0..64) |_| {
        const i = at.toIndex() orelse return .real;
        switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            .elem => at = decl.payloadOf(vir, Inst.Bin, i).lhs,
            .decl_ref => {
                const bind = b.unit.binds.get(decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl)) orelse return .real;
                return switch (bind) {
                    .slot => |x| x.ty,
                    .array => |x| x.ty,
                    else => .real, // else: no variable
                };
            },
            else => return .real, // else: no variable
        }
    }
    return .real;
}

fn str(s: *Sema, bytes: []const u8) Allocator.Error!Value {
    return .{ .ref = .fromIntern(try decl.intern(s, .{ .str = bytes })), .ty = .string };
}

fn fail(s: *Sema, b: *Block, src: Inst.Ref, msg: []const u8) Allocator.Error!Value {
    try s.fail(.E0327, b.unit.file, src, "{s}", .{msg});
    return expr.poison;
}

fn refuse(s: *Sema, b: *Block, src: Inst.Ref) Allocator.Error!Value {
    try s.fail(.E0512, b.unit.file, src, "a concatenation of sized integers is not lowered by Sema yet", .{});
    return expr.poison;
}
