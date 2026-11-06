//! §9.4.3 format strings (the old `analog/format.zig`): a formatting
//! task's operands in, E0810/E0819/E0825/E0826/E0828 out for a conversion
//! its operands cannot pair with, and each integer operand's IEEE 1364
//! width and sign recorded for the formatter: the operand becomes
//! `display$width(value, bits)` (a radix or `%s` conversion) or
//! `display$width(value, bits, signed)` (`%d` and a bare operand's default
//! decimal, IEEE 1364 §17.1.1.3's automatic field).
//! Cites: VAMS-2023 §3.2, §9.4.1, §9.4.2, §9.4.3, §9.4.5, §9.5.2, §9.7.3;
//! IEEE 1364-2005 §5.4.1, §5.5.1, §5.5.2, §17.1.1.2, §17.1.1.3.
//!
//! Contents:
//! - `pub fn operands(s: *Sema, b: *Block, skip: usize, args: []const Inst.Ref, vals: []Value, src: Inst.Ref) Allocator.Error!void`
//! - `pub fn skipOf(tag: SysFn.Tag, vals: []const Value) usize`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const str_real = @import("kernels").str_real;
const Air = @import("air");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const expr = @import("expr.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const SysFn = vams.SysFn;
const Block = Sema.Block;
const Unit = Sema.Unit;
const Value = Sema.Value;

/// One conversion `nextConv` found: its letter, lowercased, whether its
/// flags carried '#', whether anything stood between the `%` and the
/// letter, and the larger of its width and precision (saturating).
const Conv = struct { letter: u8, alt: bool, prefixed: bool = false, field: u64 = 0 };

/// The largest field width or precision a format may write (the old
/// `max_format_field`, VD §7): past it is E0828.
const field_max: u64 = 1 << 30;

/// An integer expression's width in bits (1..64) and sign.
const IntSize = struct { bits: u7, signed: bool };

const one_bit: IntSize = .{ .bits = 1, .signed = false };

/// §3.2's `integer`, and IEEE 1364 Table 5-22's unsized constant.
const integer: IntSize = .{ .bits = 32, .signed = true };

/// The deepest operator nesting `intSize` follows (null past it).
const depth_max: u32 = 1 << 10;

/// §9.4.3 over a formatting task's operands `vals` (the source operands
/// `args`, `.none` a null argument), past its first `skip` (`skipOf`):
/// a format shortfall (E0810), each conversion against its operand's type
/// (E0819) and its own spelling (E0825, E0826, E0828), and the width
/// markers, written into `vals`.
pub fn operands(s: *Sema, b: *Block, skip: usize, args: []const Inst.Ref, vals: []Value, src: Inst.Ref) Allocator.Error!void {
    assert(args.len == vals.len);
    assert(skip <= vals.len);
    const file = b.unit.file;
    try pairing(s, b, vals, src);
    var at: usize = skip;
    while (at < vals.len) {
        const fmt = formatOf(s, vals[at]) orelse {
            // §9.4.3 a bare operand takes "the default decimal format", `%d`'s field.
            if (vals[at].ty == .integer and args[at] != .none) try decimalWidth(s, b, args[at], &vals[at]);
            at += 1;
            continue;
        };
        var next = at + 1;
        var i: usize = 0;
        while (nextConv(fmt, &i)) |cv| {
            // §9.4.2 Table 9-21's `%%` is two characters (#42).
            if (cv.letter == '%' and cv.prefixed) {
                try s.fail(.E0826, file, src, "a flag, width or precision before the second `%` of `%%`", .{});
                continue;
            }
            if (cv.field > field_max) try s.fail(.E0828, file, src, "`%{c}` has a field width or precision past {d}", .{ cv.letter, field_max });
            if (cv.alt and !str_real.zcAltOk(cv.letter)) try s.fail(.E0825, file, src, "`%#{c}`: '#' is C's alternative form, which §9.4.3 grants only to %e, %f and %g", .{cv.letter});
            if (!consumes(cv.letter)) continue;
            if (next >= vals.len) return; // E0810's shortfall
            const conv = cv.letter;
            const k = next;
            next += 1;
            // §9.4.1 a null argument's one rendering is the space `%s` prints.
            if (args[k] == .none) {
                if (conv != 's') try s.fail(.E0819, file, src, "`%{c}` consumes a null argument, which §9.4.1 gives only a space; write `%s`", .{conv});
                continue;
            }
            const ty = vals[k].ty;
            const bad = switch (conv) {
                's' => ty != .string and ty != .integer,
                'c' => ty == .string,
                'e', 'f', 'g', 'r', 't', 'u', 'z', 'v' => ty == .string,
                else => false,
            };
            if (bad) {
                try s.fail(.E0819, file, src, "`%{c}` on a {t} operand", .{ conv, ty });
                continue;
            }
            if (conv == 's') {
                if (ty == .integer) {
                    const size = (try intSize(s, b.unit, args[k], 0)) orelse {
                        try s.fail(.E0819, file, src, "numeric `%s` needs a preserved integral width; this expression's sizing is not implemented", .{});
                        continue;
                    };
                    vals[k].ref = try mark(s, b, vals[k], size, false);
                } else if (expr.constOf(s, vals[k].ref)) |c| if (c == .str) {
                    // §9.4.5 a literal's leading zero bytes are suppressed.
                    vals[k].ref = .fromIntern(try decl.intern(s, .{ .str = std.mem.trimStart(u8, c.str, &.{0}) }));
                };
            } else if ((conv == 'h' or conv == 'x' or conv == 'o' or conv == 'b') and ty == .integer) {
                // IEEE 1364 §17.1.1.2: the operand's bit pattern at its own width.
                if (try intSize(s, b.unit, args[k], 0)) |size| vals[k].ref = try mark(s, b, vals[k], size, false);
            } else if (conv == 'd' and ty == .integer and !cv.prefixed) {
                // A flag or width replaces §17.1.1.3's automatic size.
                try decimalWidth(s, b, args[k], &vals[k]);
            }
        }
        at = next;
    }
}

/// How many leading operands of task `tag` are not message text: §9.5.2's
/// descriptor and §9.7.3's non-string `$fatal` finish_number.
pub fn skipOf(tag: SysFn.Tag, vals: []const Value) usize {
    if (SysFn.get(tag).family == .file_out) return @min(vals.len, 1);
    if (tag == .@"$fatal" and vals.len > 0 and vals[0].ty != .string) return 1;
    return 0;
}

// ---- private ----

/// §9.4.3 "for each % character (except %m, %% and %l) ... a corresponding
/// expression argument shall be supplied": a shortfall after the first
/// operand that is a constant string (E0810). A null argument is one.
fn pairing(s: *Sema, b: *Block, vals: []const Value, src: Inst.Ref) Allocator.Error!void {
    const at, const fmt = for (vals, 0..) |v, k| {
        if (formatOf(s, v)) |f| break .{ k, f };
    } else return;
    var need: usize = 0;
    var i: usize = 0;
    while (nextConv(fmt, &i)) |c| need += @intFromBool(consumes(c.letter));
    const have = vals.len - (at + 1);
    if (have < need) try s.fail(.E0810, b.unit.file, src, "the format string has {d} consuming format specifiers but {d} arguments follow it", .{ need, have });
}

/// The constant string `v` is, or null.
fn formatOf(s: *const Sema, v: Value) ?[]const u8 {
    if (v.ty != .string) return null;
    const c = expr.constOf(s, v.ref) orelse return null;
    return if (c == .str) c.str else null;
}

/// IEEE 1364 §17.1.1.3: a decimal field as wide as the operand's largest
/// value; a 1-bit unsigned result needs no record, and an operand
/// `intSize` cannot size takes an `integer`'s field.
fn decimalWidth(s: *Sema, b: *Block, arg: Inst.Ref, v: *Value) Allocator.Error!void {
    const size = (try intSize(s, b.unit, arg, 0)) orelse integer;
    if (size.bits == 1 and !size.signed) return;
    v.ref = try mark(s, b, v.*, size, true);
}

/// `display$width(v, bits)`, or with `signed` its sign too.
fn mark(s: *Sema, b: *Block, v: Value, size: IntSize, signed: bool) Allocator.Error!Air.Inst.Ref {
    const bits: Air.Inst.Ref = .fromIntern(try decl.intern(s, .{ .int = size.bits }));
    const tag = @backingInt(SysFn.Tag.@"display$width");
    if (!signed) return expr.call(s, b, tag, .integer, &.{ v.ref, bits });
    const sign: Air.Inst.Ref = .fromIntern(try decl.intern(s, .{ .int = @intFromBool(size.signed) }));
    return expr.call(s, b, tag, .integer, &.{ v.ref, bits, sign });
}

/// The width and sign of integer operand `r` (the old `intSize`): IEEE 1364
/// Table 5-22 and §5.5.1 read in the analog context. Null when the
/// carrier does not hold the expression's IEEE 1364 bits.
fn intSize(s: *Sema, unit: *Unit, r: Inst.Ref, depth: u32) Allocator.Error!?IntSize {
    if (depth > depth_max) return null;
    const i = r.toIndex() orelse return integer;
    const vir = unit.vir;
    const data = vir.instructions.items(.data)[@backingInt(i)];
    return switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .int => if (std.math.cast(i32, data.int) != null or std.math.cast(u32, data.int) != null) integer else .{ .bits = 64, .signed = true },
        .big_int => blk: {
            const lit = decl.payloadOf(vir, Inst.BigInt, i);
            if (lit.size > 64) break :blk null;
            if (lit.size != 0) break :blk .{ .bits = @intCast(lit.size), .signed = lit.flags.signed };
            const c = (try decl.foldRef(s, unit, r)) orelse break :blk null; // four-state (E0130)
            const n = c.asIntExact() orelse break :blk null;
            const fits = std.math.cast(i32, n) != null or std.math.cast(u32, n) != null;
            break :blk .{ .bits = if (fits) 32 else 64, .signed = lit.flags.signed };
        },
        .pos => intSize(s, unit, data.un_node.operand, depth + 1),
        .not, .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor => one_bit,
        .neg, .bit_not => narrow(s, unit, data.un_node.operand, .none, depth),
        .eq, .neq, .case_eq, .case_neq, .lt, .lte, .gt, .gte, .bool_and, .bool_or => one_bit,
        // Table 5-22: a shift's or `**`'s right operand is self-determined.
        .shl, .shr, .ashl, .ashr, .pow => narrow(s, unit, decl.payloadOf(vir, Inst.Bin, i).lhs, .none, depth),
        .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => blk: {
            const x = decl.payloadOf(vir, Inst.Bin, i);
            break :blk narrow(s, unit, x.lhs, x.rhs, depth);
        },
        .ternary => blk: {
            const t = decl.payloadOf(vir, Inst.Triple, i);
            const then = (try intSize(s, unit, t.b, depth + 1)) orelse break :blk null;
            const els = (try intSize(s, unit, t.c, depth + 1)) orelse break :blk null;
            // Table 5-22: max(L(j), L(k)); §5.5.1: signed only if both are.
            const signed = then.signed and els.signed;
            const nar = if (then.bits < els.bits) then else els;
            if (then.bits != els.bits and nar.signed and !signed) break :blk null;
            break :blk .{ .bits = @max(then.bits, els.bits), .signed = signed };
        },
        .decl_ref => declSize(s, unit, decl.canonical(vir, data.decl_tok.decl)),
        .call_sys => if (std.mem.eql(u8, vir.string(decl.payloadOf(vir, Inst.SysCall, i).name), "$realtobits")) .{ .bits = 64, .signed = false } else integer,
        else => integer, // else: a call, a select: §7.3.1's or §3.2's `integer`
    };
}

/// `integer` when each operand is sized and at most 32 bits wide; else null.
fn narrow(s: *Sema, unit: *Unit, a: Inst.Ref, b: Inst.Ref, depth: u32) Allocator.Error!?IntSize {
    if (((try intSize(s, unit, a, depth + 1)) orelse return null).bits > 32) return null;
    if (b != .none) if (((try intSize(s, unit, b, depth + 1)) orelse return null).bits > 32) return null;
    return integer;
}

/// A name's width and sign (the old `identSize`): a `reg`'s range (1 bit
/// with none), a net's or parameter's range; a parameter with no type or
/// range a model card can set has the card value's width, known only at
/// run time (null, VD-089). Anything else, and a width past 64, is `integer`.
fn declSize(s: *Sema, unit: *Unit, d: Inst.Index) Allocator.Error!?IntSize {
    const vir = unit.vir;
    var w: u64 = 32;
    var signed = true;
    switch (vir.instructions.items(.tag)[@backingInt(d)]) {
        .variable => {
            const v = decl.payloadOf(vir, Inst.Variable, d);
            if (v.flags.storage == .reg) {
                w = if (v.range.len == 0) 1 else (try rangeWidth(s, unit, v.range)) orelse return integer;
                signed = v.flags.signed;
            }
        },
        .net => {
            const n = decl.payloadOf(vir, Inst.Net, d);
            if (n.range.len != 0) {
                w = (try rangeWidth(s, unit, n.range)) orelse return integer;
                signed = n.flags.signed;
            }
        },
        .param => {
            const p = decl.payloadOf(vir, Inst.Param, d);
            if (p.range.len != 0) {
                w = (try rangeWidth(s, unit, p.range)) orelse return integer;
                signed = p.flags.signed;
            } else if (p.flags.storage == .none and p.flags.kind == .parameter and !p.flags.local) {
                const b = vir.body(p.value);
                if (b.len != 0) if (try decl.foldRef(s, unit, b[b.len - 1].toRef())) |c| if (c == .int) return null;
            }
        },
        else => {}, // else: an `integer`, a formal, a genvar
    }
    if (w == 0 or w > 64) return integer;
    return .{ .bits = @intCast(w), .signed = signed };
}

/// `[msb:lsb]`'s width, or null when a bound does not fold.
fn rangeWidth(s: *Sema, unit: *Unit, range: Vir.Body) Allocator.Error!?u64 {
    const r = unit.vir.body(range);
    const bin = decl.payloadOf(unit.vir, Inst.Bin, r[r.len - 1]);
    const msb = ((try decl.foldRef(s, unit, bin.lhs)) orelse return null).asIntExact() orelse return null;
    const lsb = ((try decl.foldRef(s, unit, bin.rhs)) orelse return null).asIntExact() orelse return null;
    return std.math.cast(u64, @abs(@as(i128, msb) - lsb) + 1);
}

/// §9.4.3 `%[flags][width][.precision]conv`: the next conversion at or
/// after `i.*`, `%%` included (letter '%'), with `i.*` moved past it; null
/// when the format ends first (the old `nextConv`).
fn nextConv(fmt: []const u8, i: *usize) ?Conv {
    assert(i.* <= fmt.len);
    const p = std.mem.findScalarPos(u8, fmt, i.*, '%') orelse return null;
    i.* = p + 1;
    var alt = false;
    var run: u64 = 0; // the number being read: the width, then the precision
    var field: u64 = 0;
    while (i.* < fmt.len) : (i.* += 1) {
        const c = fmt[i.*];
        if (std.ascii.isDigit(c)) {
            run = run *| 10 +| (c - '0');
            field = @max(field, run);
        } else if (c == '.') {
            run = 0;
        } else if (str_real.zcFlag(c)) |f| {
            alt = alt or f == str_real.zc_alt;
            run = 0;
        } else break;
    }
    if (i.* >= fmt.len) return null;
    const letter = std.ascii.toLower(fmt[i.*]);
    const prefixed = i.* > p + 1;
    i.* += 1;
    return .{ .letter = letter, .alt = alt, .prefixed = prefixed, .field = field };
}

/// Whether conversion `letter` consumes an argument (all but %m, %%, %l).
fn consumes(letter: u8) bool {
    return letter != '%' and letter != 'm' and letter != 'l';
}

test "§9.4.3 nextConv: flags, width and the letter" {
    var i: usize = 0;
    try std.testing.expectEqual(Conv{ .letter = 'g', .alt = true, .prefixed = true, .field = 12 }, nextConv("%#12g", &i).?);
    i = 0;
    try std.testing.expectEqual(Conv{ .letter = '%', .alt = false, .prefixed = true, .field = 5 }, nextConv("%5%", &i).?);
    i = 0;
    try std.testing.expectEqual(@as(?Conv, null), nextConv("%#", &i));
}
