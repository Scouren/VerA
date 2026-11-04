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
    const file = b.unit.file;
    if (args.len == 0 or args[0] == .none) return s.fail(.E0813, file, src, "`{t}` needs a string variable to write into", .{tag});
    if (slotType(b, args[0])) |t| if (t != .string) return s.fail(.E0813, file, src, "`{t}` writes into a `string` variable, and this one is {t}", .{ tag, t });
    const ops = args[1..];
    const vals = try s.arena.alloc(Value, ops.len);
    for (ops, vals) |a, *v| v.* = if (a == .none) .{ .ref = .fromIntern(try decl.intern(s, .{ .str = " " })), .ty = .string } else try expr.lower(s, b, a);
    // §9.5.3 `$sformat`'s format may be a string variable, read at run time.
    const runtime = tag == .@"$sformat" and vals.len != 0 and ops[0] != .none and expr.constOf(s, vals[0].ref) == null;
    if (runtime and vals[0].ty != .string) return s.fail(.E0813, file, src, "`$sformat`'s format_string is a string, and this one is {t}", .{vals[0].ty});
    if (!runtime) try @import("format.zig").operands(s, b, 0, ops, vals, src);
    const refs = try s.arena.alloc(Ref, vals.len);
    for (vals, refs) |x, *r| r.* = x.ref;
    const v = try expr.call(s, b, @backingInt(tag), .string, refs);
    try @import("control.zig").assignTo(s, b, args[0], .{ .ref = v, .ty = .string }, src);
}

/// §9.5.4 `$sscanf`/`$fscanf`/`$fgets`, §9.5.7 `$ferror` and §9.12
/// `$value$plusargs`: an integer `call` of the operands it reads (its count
/// or status), then each destination (argument `first`, and every one after
/// it for a scan) assigned `scan$item(call, k)` (a number, coerced) or
/// `scan$str(call, k)`. E0813 (the old `string_io`'s): a scan with no source
/// or format, a `$sscanf` source that is no string, a literal format with a
/// code §9.5.4.2 does not list, a `$fgets`/`$ferror` destination that is no
/// `string`; the value is then 0.
pub fn read(s: *Sema, b: *Block, tag: SysFn.Tag, first: usize, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value {
    const file = b.unit.file;
    const zero: Value = .{ .ref = .fromIntern(.zero), .ty = .integer };
    const many = first >= 2;
    if (many and (args.len < 2 or args[0] == .none or args[1] == .none)) {
        try s.fail(.E0813, file, src, "`{t}` needs a source and a format string", .{tag});
        return zero;
    }
    if (many) if (try decl.foldRef(s, b.unit, args[1])) |c| if (c == .str) if (badScanCode(c.str)) |code| {
        try s.fail(.E0813, file, src, "`{t}` does not support the conversion `%{c}`; §9.5.4.2's codes are %d %o %h %x %b %c %f %e %g %s %r %m", .{ tag, code });
        return zero;
    };
    if (tag == .@"$fgets" or tag == .@"$ferror") if (args.len > first) if (slotType(b, args[first])) |t| if (t != .string) {
        try s.fail(.E0813, file, src, "`{t}` writes into a `string` variable, and this one is {t}", .{ tag, t });
        return zero;
    };
    var ops: std.ArrayList(Ref) = .empty;
    for (args, 0..) |a, k| {
        if (k == first or (many and k > first)) continue;
        const v: Value = if (a == .none) .{ .ref = .fromIntern(.zero_real), .ty = .real } else try expr.lower(s, b, a);
        // §9.5.4.2 "a string variable, string parameter, or string literal".
        if (tag == .@"$sscanf" and k == 0 and v.ty != .string) {
            try s.fail(.E0813, file, src, "`$sscanf` reads from a string variable, string parameter or string literal, and this one is {t}", .{v.ty});
            return zero;
        }
        try ops.append(s.arena, v.ref);
    }
    const r = try expr.call(s, b, @backingInt(tag), .integer, ops.items);
    for (args, 0..) |a, k| {
        if (!(k == first or (many and k > first)) or a == .none) continue;
        const ty = slotType(b, a) orelse .real;
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

/// The first conversion code of scan format `fmt` that §9.5.4.2's table
/// does not list (case-sensitive, as the scanner compares it), or null.
fn badScanCode(fmt: []const u8) ?u8 {
    var i: usize = 0;
    while (std.mem.findScalarPos(u8, fmt, i, '%')) |p| {
        i = p + 1;
        if (i >= fmt.len) return null;
        if (fmt[i] == '%') { // a literal percent, matched not converted
            i += 1;
            continue;
        }
        if (fmt[i] == '*') i += 1;
        while (i < fmt.len and std.ascii.isDigit(fmt[i])) i += 1;
        if (i >= fmt.len) return null;
        const conv = fmt[i];
        i += 1;
        if (std.mem.findScalar(u8, "dohxbcfegsrm", conv) == null) return conv;
    }
    return null;
}

/// The type of the variable (or array element) `r` names, or null.
fn slotType(b: *Block, r: Inst.Ref) ?Sema.Ty {
    const vir = b.unit.vir;
    var at = r;
    for (0..64) |_| {
        const i = at.toIndex() orelse return null;
        switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            .elem => at = decl.payloadOf(vir, Inst.Bin, i).lhs,
            .decl_ref => {
                const bind = b.unit.binds.get(decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl)) orelse return null;
                return switch (bind) {
                    .slot => |x| x.ty,
                    .array => |x| x.ty,
                    else => null, // else: no variable
                };
            },
            else => return null, // else: no variable
        }
    }
    return null;
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
