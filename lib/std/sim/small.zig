//! The evaluator's fast half: an integral row of at most 64 bits whose
//! operands are as narrow, as two u64 planes (`V`) and no allocation. An
//! operand with an x or z bit takes `Literal`'s own operator (the kernel
//! `eval` calls), so the result is the kernel's by construction; with none,
//! the operator is the machine's. Any other row is `eval.evalRow`'s.
//! Cites: IEEE 1364-2005 §5.1, §5.2.1, §5.5.
//!
//! Contents:
//! - `pub const V = struct { v: u64, x: u64 }`
//! - `pub fn fits(ty: Program.Ty) bool`
//! - `pub fn value(s: *State, a: Allocator, e: u32) Error!V`
//! - `pub fn evalInto(s: *State, a: Allocator, planes: *[2]u64, e: u32) Error!Literal`
//! - `pub fn literal(planes: *[2]u64, v: V, ty: Program.Ty) Literal`
//! - `pub fn truthOf(v: V, width: u32) Bit`
//! - `pub fn indexOf(v: V, ty: Ty) ?i128`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Program = @import("Program.zig");
const State = @import("State.zig");
const eval = @import("eval.zig");
const logic = @import("logic.zig");
const Literal = logic.Literal;
const Bit = logic.Bit;
const Error = State.Error;
const Ty = Program.Ty;
const Builder = @import("Builder.zig");

/// A value of at most 64 bits: the value plane and the unknown plane, both
/// zero above the width (an x bit is v 1, x 1; a z bit v 0, x 1).
pub const V = struct { v: u64, x: u64 };

const all_x: V = .{ .v = std.math.maxInt(u64), .x = std.math.maxInt(u64) };

/// Whether a row of type `ty` is `value`'s: integral and at most 64 bits.
pub fn fits(ty: Ty) bool {
    return !ty.real and ty.width <= 64;
}

/// Row `e`'s value in its `ty`, as `eval.eval` computes it. Asserts `fits`.
pub fn value(s: *State, a: Allocator, e: u32) Error!V {
    const p = s.p;
    const tys = p.exprs.items(.ty);
    const ty = tys[e];
    assert(fits(ty));
    const d = p.exprs.items(.data)[e];
    const w: u32 = ty.width;
    const out: V = switch (p.exprs.items(.tag)[e]) {
        .constant => .{ .v = p.consts[d.a], .x = p.consts[d.a + 1] },
        .slot => blk: {
            const sl = p.slots.get(d.a);
            break :blk resize(.{ .v = s.v[sl.word], .x = s.x[sl.word] }, @min(sl.ty.width, 64), w, ty.signed);
        },
        .select => blk: {
            const sl = p.extraData(Program.Select, d.a);
            if (sl.elem != @backingInt(Program.Ref.none) or sl.count > 64) return slow(s, a, e);
            break :blk resize(try readSelect(s, a, sl), sl.count, w, ty.signed);
        },
        .elem => blk: {
            const el = p.extraData(Program.Elem, d.a);
            const base = p.slots.items(.ty)[el.base];
            if (base.width > 64 or base.real) return slow(s, a, e);
            const at = (try eval.address(s, a, el)) orelse break :blk resize(all_x, base.width, w, ty.signed);
            const word = p.slots.items(.word)[at];
            break :blk resize(.{ .v = s.v[word], .x = s.x[word] }, base.width, w, ty.signed);
        },
        .neg, .not => blk: {
            if (tys[d.a] != ty) return slow(s, a, e);
            const x = try value(s, a, d.a);
            if (x.x != 0) break :blk try kernel(s, a, e, x, x);
            break :blk .{ .v = (if (p.exprs.items(.tag)[e] == .neg) 0 -% x.v else ~x.v) & mask(w), .x = 0 };
        },
        .lnot, .truth => blk: {
            if (!fits(tys[d.a])) return slow(s, a, e);
            const t = truthOf(try value(s, a, d.a), tys[d.a].width);
            break :blk scalarIn(if (p.exprs.items(.tag)[e] == .truth) t else switch (t) {
                .one => .zero,
                .zero => .one,
                .x, .z => .x,
            }, ty);
        },
        .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor => |tag| blk: {
            if (!fits(tys[d.a])) return slow(s, a, e);
            const x = try value(s, a, d.a);
            if (x.x != 0) break :blk try kernel(s, a, e, x, x);
            const m = mask(tys[d.a].width);
            const r = switch (tag) {
                .red_and, .red_nand => x.v == m,
                .red_or, .red_nor => x.v != 0,
                else => @popCount(x.v) & 1 == 1, // else: the xor pair
            };
            const flip = tag == .red_nand or tag == .red_nor or tag == .red_xnor;
            break :blk scalarIn(if (r != flip) .one else .zero, ty);
        },
        .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .bit_xnor => |tag| blk: {
            if (tys[d.a] != ty or tys[d.b] != ty) return slow(s, a, e);
            const x = try value(s, a, d.a);
            const y = try value(s, a, d.b);
            if ((x.x | y.x) != 0) break :blk try kernel(s, a, e, x, y);
            const r = switch (tag) {
                .add => x.v +% y.v,
                .sub => x.v -% y.v,
                .mul => x.v *% y.v,
                .bit_and => x.v & y.v,
                .bit_or => x.v | y.v,
                .bit_xor => x.v ^ y.v,
                else => ~(x.v ^ y.v), // else: `~^`
            };
            break :blk .{ .v = r & mask(w), .x = 0 };
        },
        .shl, .shr, .ashl, .ashr => |tag| blk: {
            if (tys[d.a] != ty or !fits(tys[d.b])) return slow(s, a, e);
            const x = try value(s, a, d.a);
            const y = try value(s, a, d.b);
            if ((x.x | y.x) != 0) break :blk try kernel(s, a, e, x, y);
            const n: u32 = @intCast(@min(y.v, w));
            const ext = tag == .ashr and ty.signed;
            const r: u64 = if (tag == .shl or tag == .ashl)
                (if (n == w) 0 else x.v << @intCast(n))
            else if (ext)
                @bitCast(@as(i64, @bitCast(signExtend(x.v, w))) >> @intCast(@min(n, 63)))
            else if (n == w) 0 else x.v >> @intCast(n);
            break :blk .{ .v = r & mask(w), .x = 0 };
        },
        .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge => |tag| blk: {
            const at = tys[d.a];
            if (!fits(at) or tys[d.b] != at) return slow(s, a, e);
            const x = try value(s, a, d.a);
            const y = try value(s, a, d.b);
            if ((x.x | y.x) != 0) break :blk try kernel(s, a, e, x, y);
            const sx: i64 = @bitCast(if (at.signed) signExtend(x.v, at.width) else x.v);
            const sy: i64 = @bitCast(if (at.signed) signExtend(y.v, at.width) else y.v);
            const r = switch (tag) {
                .eq, .case_eq => x.v == y.v,
                .neq, .case_neq => x.v != y.v,
                .lt => if (at.signed) sx < sy else x.v < y.v,
                .le => if (at.signed) sx <= sy else x.v <= y.v,
                .gt => if (at.signed) sx > sy else x.v > y.v,
                else => if (at.signed) sx >= sy else x.v >= y.v, // else: `>=`
            };
            break :blk scalarIn(if (r) .one else .zero, ty);
        },
        .land, .lor => |tag| blk: {
            if (!fits(tys[d.a]) or !fits(tys[d.b])) return slow(s, a, e);
            const l = truthOf(try value(s, a, d.a), tys[d.a].width);
            if ((tag == .land and l == .zero) or (tag == .lor and l == .one)) break :blk scalarIn(l, ty);
            const r = truthOf(try value(s, a, d.b), tys[d.b].width);
            break :blk scalarIn(if (tag == .land)
                (if (l == .zero or r == .zero) .zero else if (l == .one and r == .one) .one else .x)
            else if (l == .one or r == .one) .one else if (l == .zero and r == .zero) .zero else .x, ty);
        },
        .cond => blk: {
            const arms = p.extra[d.b..][0..2];
            if (!fits(tys[d.a]) or tys[arms[0]] != ty or tys[arms[1]] != ty) return slow(s, a, e);
            const c = try value(s, a, d.a);
            break :blk switch (truthOf(c, tys[d.a].width)) {
                .one => try value(s, a, arms[0]),
                .zero => try value(s, a, arms[1]),
                .x, .z => try kernel(s, a, e, c, c),
            };
        },
        .concat => blk: {
            const parts = p.list(.{ .start = d.a, .len = d.b });
            const tags = p.exprs.items(.tag);
            var total: u32 = 0;
            for (parts) |r| {
                if (tags[r] != .discard and !fits(tys[r])) return slow(s, a, e);
                if (tags[r] != .discard) total += tys[r].width;
            }
            if (total > 64) return slow(s, a, e);
            var acc: V = .{ .v = 0, .x = 0 };
            for (parts) |r| {
                if (tags[r] == .discard) {
                    _ = try eval.eval(s, a, p.exprs.items(.data)[r].a);
                    continue;
                }
                const part = try value(s, a, r);
                const pw: u6 = @intCast(tys[r].width % 64);
                acc = if (pw == 0) part else .{ .v = acc.v << pw | part.v, .x = acc.x << pw | part.x };
            }
            break :blk resize(acc, total, w, ty.signed);
        },
        .replicate => blk: {
            const ow = tys[d.a].width;
            if (!fits(tys[d.a]) or @as(u64, ow) * d.b > 64) return slow(s, a, e);
            const x = try value(s, a, d.a);
            var acc: V = .{ .v = 0, .x = 0 };
            for (0..d.b) |_| acc = if (ow == 64) x else .{ .v = acc.v << @intCast(ow) | x.v, .x = acc.x << @intCast(ow) | x.x };
            break :blk resize(acc, ow * d.b, w, ty.signed);
        },
        .convert => blk: {
            if (!fits(tys[d.a])) return slow(s, a, e);
            break :blk resize(try value(s, a, d.a), tys[d.a].width, w, ty.signed);
        },
        // else: every other row is `eval.evalRow`'s.
        else => return slow(s, a, e),
    };
    assert((out.v | out.x) & ~mask(w) == 0);
    return out;
}

/// `eval.eval` of row `e`, over `planes` when the row `fits` (the result
/// lives as long as `planes`), else in `a`.
pub fn evalInto(s: *State, a: Allocator, planes: *[2]u64, e: u32) Error!Literal {
    const ty = s.p.exprs.items(.ty)[e];
    if (!fits(ty)) return eval.eval(s, a, e);
    return literal(planes, try value(s, a, e), ty);
}

/// `v` as a `Literal` of type `ty` over `planes`, which must outlive it.
pub fn literal(planes: *[2]u64, v: V, ty: Ty) Literal {
    assert(fits(ty));
    planes.* = .{ v.v, v.x };
    return .{ .width = ty.width, .signed = ty.signed, .sized = true, .planes = planes };
}

/// §5.1.9 `Literal.truth` of a `width`-bit `v`: a known 1 decides it, then
/// any x or z.
pub fn truthOf(v: V, width: u32) Bit {
    const m = mask(width);
    if (v.v & ~v.x & m != 0) return .one;
    return if (v.x & m != 0) .x else .zero;
}

/// `Literal.asIndex` of `v` in `ty`: by its own signedness, null for an x
/// or z bit.
pub fn indexOf(v: V, ty: Ty) ?i128 {
    assert(fits(ty));
    if (v.x != 0) return null;
    return if (ty.signed) @as(i64, @bitCast(signExtend(v.v, ty.width))) else v.v;
}

// ---- private ----

fn mask(w: u32) u64 {
    assert(w >= 1 and w <= 64);
    return if (w == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(w)) - 1;
}

fn signExtend(word: u64, from: u32) u64 {
    if (from == 64) return word;
    const sh: u6 = @intCast(64 - from);
    return @bitCast(@as(i64, @bitCast(word << sh)) >> sh);
}

/// `logic.normalize`: `x` (`from` bits) in `to` bits, extended by the
/// target's signedness, x and z included, or truncated.
fn resize(x: V, from: u32, to: u32, signed: bool) V {
    if (to <= from or !signed) return .{ .v = x.v & mask(to), .x = x.x & mask(to) };
    return .{ .v = signExtend(x.v & mask(from), from) & mask(to), .x = signExtend(x.x & mask(from), from) & mask(to) };
}

fn scalarIn(b: Bit, ty: Ty) V {
    const bits: u2 = @backingInt(b);
    return resize(.{ .v = bits & 1, .x = bits >> 1 }, 1, ty.width, ty.signed);
}

fn ofLiteral(l: Literal) V {
    assert(l.width <= 64);
    return .{ .v = l.values()[0], .x = l.unknowns()[0] };
}

fn slow(s: *State, a: Allocator, e: u32) Error!V {
    return ofLiteral(try eval.evalRow(s, a, e));
}

/// Row `e`'s operator over operand values `x` and `y` (the condition and
/// nothing for `cond`, whose arms it evaluates), by the kernel `evalRow`
/// calls: the case with an x or z bit.
fn kernel(s: *State, a: Allocator, e: u32, x: V, y: V) Error!V {
    const p = s.p;
    const tys = p.exprs.items(.ty);
    const ty = tys[e];
    const d = p.exprs.items(.data)[e];
    var bx: [2]u64 = undefined;
    var by: [2]u64 = undefined;
    const lx = literal(&bx, x, tys[d.a]);
    const tag = p.exprs.items(.tag)[e];
    if (tag == .cond) {
        const arms = p.extra[d.b..][0..2];
        var b0: [2]u64 = undefined;
        var b1: [2]u64 = undefined;
        const yes = literal(&b0, try value(s, a, arms[0]), ty);
        const no = literal(&b1, try value(s, a, arms[1]), ty);
        return ofLiteral(try lx.conditional(a, yes, no));
    }
    const unary = switch (tag) {
        .neg, .not, .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor => true,
        // else: a binary operator
        else => false,
    };
    const ly = if (unary) lx else literal(&by, y, tys[d.b]);
    const bit: ?Bit = switch (tag) {
        .red_and => lx.reduce(.and_bits),
        .red_nand => lx.reduce(.nand_bits),
        .red_or => lx.reduce(.or_bits),
        .red_nor => lx.reduce(.nor_bits),
        .red_xor => lx.reduce(.xor_bits),
        .red_xnor => lx.reduce(.xnor_bits),
        .eq => lx.equality(.equal, ly),
        .neq => lx.equality(.not_equal, ly),
        .case_eq => lx.equality(.case_equal, ly),
        .case_neq => lx.equality(.case_not_equal, ly),
        .lt => lx.relational(.less, ly),
        .le => lx.relational(.less_equal, ly),
        .gt => lx.relational(.greater, ly),
        .ge => lx.relational(.greater_equal, ly),
        // else: the operators with a value result, below.
        else => null,
    };
    if (bit) |b| return scalarIn(b, ty);
    return ofLiteral(try switch (tag) {
        .neg => lx.negate(a),
        .not => lx.bitwiseNot(a),
        .add => lx.arithmetic(a, .add, ly),
        .sub => lx.arithmetic(a, .subtract, ly),
        .mul => lx.arithmetic(a, .multiply, ly),
        .bit_and => lx.bitwise(a, .and_bits, ly),
        .bit_or => lx.bitwise(a, .or_bits, ly),
        .bit_xor => lx.bitwise(a, .xor_bits, ly),
        .bit_xnor => lx.bitwise(a, .xnor_bits, ly),
        .shl => lx.shift(a, .left, ly),
        .shr => lx.shift(a, .right, ly),
        .ashl => lx.shift(a, .arithmetic_left, ly),
        .ashr => lx.shift(a, .arithmetic_right, ly),
        else => unreachable, // else: `value` sends only these here
    });
}

/// `eval.readSelect` of a select of a slot (not an array element), at most
/// 64 bits: the bits outside the slot or past an x/z index are x.
fn readSelect(s: *State, a: Allocator, sl: Program.Select) Error!V {
    const sel = (try eval.selection(s, a, sl)) orelse return .{ .v = mask(sl.count), .x = mask(sl.count) };
    const st = s.p.slots.get(sl.slot);
    const lo = @max(sel.first, 0);
    const hi = @min(sel.first + @as(i64, sel.count), @as(i64, st.ty.width));
    if (lo >= hi) return .{ .v = mask(sl.count), .x = mask(sl.count) };
    const n: u32 = @intCast(hi - lo);
    const got = s.termBits(sl.slot, @intCast(lo), n);
    const at: u6 = @intCast(lo - sel.first);
    const keep = mask(n) << at;
    const outside = mask(sl.count) & ~keep;
    return .{ .v = got[0] << at | outside, .x = got[1] << at | outside };
}

/// A random constant row of type `t`: a quarter with x or z bits, half
/// small, so shifts and compares reach their edges.
fn operand(b: *Builder, r: std.Random, t: Ty) !u32 {
    const m = mask(t.width);
    const x = if (r.uintLessThan(u8, 4) == 0) r.int(u64) & m else 0;
    const v = (if (r.boolean()) r.uintLessThan(u64, 70) else r.int(u64)) & m;
    return b.constant(t, &.{v}, &.{x});
}

test resize {
    // Oracle: `Literal.resize` (the kernel `normalize` calls) over every
    // 3-bit four-state value, to 2 and 6 bits, both extensions.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..64) |code| {
        const x: V = .{ .v = code & 7, .x = code >> 3 };
        var buf: [2]u64 = undefined;
        const lit = literal(&buf, x, Ty.int(3, true));
        for ([_]u32{ 2, 6 }) |to| for ([_]bool{ false, true }) |signed| {
            const want = try logic.normalize(a, lit, to, signed);
            try std.testing.expectEqual(ofLiteral(want), resize(x, 3, to, signed));
        };
    }
}

test value {
    // Oracle: `eval.evalRow`, the `Literal` evaluator, on every operator
    // `value` computes itself, over random operands at widths that cross
    // the word's edges, a quarter of them with x or z bits.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const rand = prng.random();
    const tags = [_]Program.Expr.Tag{ .neg, .not, .lnot, .truth, .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor, .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .bit_xnor, .shl, .shr, .ashl, .ashr, .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .land, .lor, .convert, .replicate };
    var checked: u32 = 0;
    for (0..4000) |_| {
        var b: Builder = .init(a);
        const w = rand.intRangeAtMost(u32, 1, 64);
        const ty = Ty.int(w, rand.boolean());
        const tag = tags[rand.uintLessThan(usize, tags.len)];
        const x = try operand(&b, rand, ty);
        const y = try operand(&b, rand, switch (tag) {
            .shl, .shr, .ashl, .ashr => Ty.int(rand.intRangeAtMost(u32, 1, 64), rand.boolean()),
            // else: the other operand is in the row's type
            else => ty,
        });
        const out_ty = switch (tag) {
            .lnot, .truth, .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor, .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .land, .lor => Ty.int(rand.intRangeAtMost(u32, 1, 3), rand.boolean()),
            .convert => Ty.int(rand.intRangeAtMost(u32, 1, 64), rand.boolean()),
            .replicate => Ty.int(w * 2, false),
            // else: in the operands' type
            else => ty,
        };
        if (tag == .replicate and w > 32) continue;
        const e = try b.expr(tag, out_ty, x, if (tag == .replicate) 2 else y);
        var p = b.finish();
        var out: std.Io.Writer.Allocating = .init(a);
        var s: State = try .init(a, &p, &out.writer);
        const want = ofLiteral(try eval.evalRow(&s, a, e));
        try std.testing.expectEqual(want, try value(&s, a, e));
        checked += 1;
    }
    try std.testing.expect(checked > 3000);
}
