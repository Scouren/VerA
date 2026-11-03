//! A `Program.exprs` row and the run's planes in, its value out: an integral
//! row as a four-state `Literal` in exactly its `ty`, a real row as the 64
//! bits of a double. The §5.5.2 context was applied when the row was
//! written, so a row reads its operands' values and never sizes anything.
//! Also the write half: a `Place` and a value -> the slot or bits it lands
//! in now.
//! Cites: IEEE 1364-2005 §3.9, §4.8.2, §5.1, §5.2.1, §5.5, §9.2, §17.7,
//! §17.8, §17.11.
//!
//! Contents:
//! - `pub fn eval(s: *State, a: Allocator, e: u32) Error!Literal`
//! - `pub fn real(s: *State, a: Allocator, e: u32) Error!f64`
//! - `pub fn truth(s: *State, a: Allocator, e: u32) Error!Bit`
//! - `pub fn read(s: *const State, a: Allocator, slot: u32) Error!Literal`
//! - `pub fn address(s: *State, a: Allocator, el: Program.Elem) Error!?u32`
//! - `pub fn put(s: *State, a: Allocator, place: u32, value: Literal, nba: bool, delay: ?u64) Error!void`
//! - `pub fn write(s: *State, a: Allocator, slot: u32, sel: ?Sel, value: Literal) Error!void`
//! - `pub const Sel = struct { first: i64, count: u32 }`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Program = @import("Program.zig");
const State = @import("State.zig");
const logic = @import("logic.zig");
const calls = @import("calls.zig");
const files = @import("files.zig");
const scan = @import("scan.zig");
const Literal = logic.Literal;
const Bit = logic.Bit;
const Error = State.Error;
const filled = logic.filled;
const normalize = logic.normalize;

/// §5.2.1 the bit positions a select names: bit i of the selected value is
/// bit `first + i` of the slot, and no bit where the slot has none.
pub const Sel = struct { first: i64, count: u32 };

/// Row `e`'s value, in its `ty`. The result may alias a constant's or a
/// slot's scratch copy; it lives in `a`.
pub fn eval(s: *State, a: Allocator, e: u32) Error!Literal {
    const p = s.p;
    assert(e < p.exprs.len);
    const row = p.exprs.get(e);
    const ty = row.ty;
    const d = row.data;
    const w: u32 = ty.width;
    return switch (row.tag) {
        .constant => blk: {
            const n = Program.words(w);
            const planes = try a.alloc(u64, 2 * n);
            @memcpy(planes[0..n], p.consts[d.a..][0..n]);
            @memcpy(planes[n..], p.consts[d.a + n ..][0..n]);
            break :blk .{ .width = w, .signed = ty.signed, .sized = true, .planes = planes };
        },
        .real_constant => logic.realLiteral(a, @bitCast(@as(u64, d.a) | @as(u64, d.b) << 32)),
        .slot => normalize(a, try read(s, a, d.a), w, ty.signed),
        .elem => blk: {
            const el = p.extraData(Program.Elem, d.a);
            const base = p.slots.items(.ty)[el.base];
            // §5.2.2 an invalid reference is x, which a real reads as 0 (§4.8.2).
            const at = (try address(s, a, el)) orelse break :blk if (ty.real)
                logic.realLiteral(a, 0)
            else
                normalize(a, try filled(a, base.width, base.signed, .x), w, ty.signed);
            const v = try read(s, a, at);
            if (ty.real) {
                // An actual NaN in a valid element survives; x bits read as 0.
                v.values()[0] &= ~v.unknowns()[0];
                v.unknowns()[0] = 0;
                break :blk v;
            }
            break :blk normalize(a, v, w, ty.signed);
        },
        .select => normalize(a, try readSelect(s, a, p.extraData(Program.Select, d.a)), w, ty.signed),
        .neg => (try eval(s, a, d.a)).negate(a),
        .not => (try eval(s, a, d.a)).bitwiseNot(a),
        .lnot => scalarIn(a, switch (try truth(s, a, d.a)) {
            .one => .zero,
            .zero => .one,
            .x, .z => .x,
        }, ty),
        .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor => scalarIn(a, (try eval(s, a, d.a)).reduce(switch (row.tag) {
            .red_and => .and_bits,
            .red_nand => .nand_bits,
            .red_or => .or_bits,
            .red_nor => .nor_bits,
            .red_xor => .xor_bits,
            else => .xnor_bits, // else: the sixth reduction
        }), ty),
        .truth => scalarIn(a, try truth(s, a, d.a), ty),
        .add, .sub, .mul, .div, .mod => (try eval(s, a, d.a)).arithmetic(a, switch (row.tag) {
            .add => .add,
            .sub => .subtract,
            .mul => .multiply,
            .div => .divide,
            else => .remainder, // else: `%`
        }, try eval(s, a, d.b)),
        .bit_and, .bit_or, .bit_xor, .bit_xnor => (try eval(s, a, d.a)).bitwise(a, switch (row.tag) {
            .bit_and => .and_bits,
            .bit_or => .or_bits,
            .bit_xor => .xor_bits,
            else => .xnor_bits, // else: `~^`
        }, try eval(s, a, d.b)),
        .shl, .shr, .ashl, .ashr => (try eval(s, a, d.a)).shift(a, switch (row.tag) {
            .shl => .left,
            .shr => .right,
            .ashl => .arithmetic_left,
            else => .arithmetic_right, // else: `>>>`
        }, try eval(s, a, d.b)),
        .pow => (try eval(s, a, d.a)).power(a, try eval(s, a, d.b)),
        .eq, .neq, .case_eq, .case_neq => scalarIn(a, (try eval(s, a, d.a)).equality(switch (row.tag) {
            .eq => .equal,
            .neq => .not_equal,
            .case_eq => .case_equal,
            else => .case_not_equal, // else: `!==`
        }, try eval(s, a, d.b)), ty),
        .lt, .le, .gt, .ge => scalarIn(a, (try eval(s, a, d.a)).relational(switch (row.tag) {
            .lt => .less,
            .le => .less_equal,
            .gt => .greater,
            else => .greater_equal, // else: `>=`
        }, try eval(s, a, d.b)), ty),
        .land, .lor => blk: {
            const l = try truth(s, a, d.a);
            if ((row.tag == .land and l == .zero) or (row.tag == .lor and l == .one)) break :blk scalarIn(a, l, ty);
            const r = try truth(s, a, d.b);
            const lb = try logic.scalar(a, l);
            break :blk scalarIn(a, lb.logical(if (row.tag == .land) .and_bits else .or_bits, try logic.scalar(a, r)), ty);
        },
        .cond => blk: {
            const arms = p.extra[d.b..][0..2];
            const c = try eval(s, a, d.a);
            break :blk switch (c.truth()) {
                .one => eval(s, a, arms[0]),
                .zero => eval(s, a, arms[1]),
                .x, .z => c.conditional(a, try eval(s, a, arms[0]), try eval(s, a, arms[1])),
            };
        },
        .concat => blk: {
            const parts_rows = p.list(.{ .start = d.a, .len = d.b });
            var parts: std.ArrayList(Literal) = try .initCapacity(a, parts_rows.len);
            for (parts_rows) |r| {
                if (p.exprs.items(.tag)[r] == .discard) {
                    _ = try eval(s, a, p.exprs.items(.data)[r].a);
                    continue;
                }
                parts.appendAssumeCapacity(try eval(s, a, r));
            }
            const v = Literal.concatenate(a, parts.items) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ZeroSize, error.Overflow => unreachable, // the writer sized every part
            };
            break :blk normalize(a, v, w, ty.signed);
        },
        .replicate => blk: {
            const v = (try eval(s, a, d.a)).replicate(a, d.b) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ZeroSize, error.Overflow => unreachable, // a zero count is a `discard`
            };
            break :blk normalize(a, v, w, ty.signed);
        },
        .discard => unreachable, // only a `concat` part, which skips it
        .convert => blk: {
            var v = try eval(s, a, d.a);
            if (d.b == 1) v.signed = false;
            if (d.b == 2) v.signed = true;
            break :blk normalize(a, v, w, ty.signed);
        },
        .int_of_real => normalize(a, try logic.intOfReal(a, try real(s, a, d.a)), w, ty.signed),
        .real_of_int, .real_neg, .real_add, .real_sub, .real_mul, .real_div, .real_pow, .real_cond, .realtime, .bitstoreal, .math1, .math2 => logic.realLiteral(a, try real(s, a, e)),
        .real_eq, .real_neq, .real_lt, .real_le, .real_gt, .real_ge => blk: {
            const l = try real(s, a, d.a);
            const r = try real(s, a, d.b);
            const holds = switch (row.tag) {
                .real_eq => l == r,
                .real_neq => l != r,
                .real_lt => l < r,
                .real_le => l <= r,
                .real_gt => l > r,
                else => l >= r, // else: `>=`
            };
            break :blk scalarIn(a, if (holds) .one else .zero, ty);
        },
        .time, .stime => blk: {
            const units = p.times[d.a].scale.unitsAt(s.scheduler.now);
            const v = try filled(a, w, ty.signed, .zero);
            v.values()[0] = if (row.tag == .stime) units & 0xffff_ffff else if (w >= 64) units else units & ((@as(u64, 1) << @intCast(w)) - 1);
            break :blk v;
        },
        .rtoi => blk: {
            const t = @trunc(try real(s, a, d.a));
            const v = try filled(a, 32, true, .x);
            if (std.math.isFinite(t)) {
                v.values()[0] = (try logic.intOfReal(a, t)).values()[0] & 0xffff_ffff;
                v.unknowns()[0] = 0;
            }
            break :blk normalize(a, v, w, ty.signed);
        },
        .realtobits => blk: {
            const v = try filled(a, 64, false, .zero);
            v.values()[0] = @bitCast(try real(s, a, d.a));
            break :blk normalize(a, v, w, ty.signed);
        },
        .call => normalize(a, try calls.call(s, a, d.a), w, ty.signed),
        .file => blk: {
            const raw: u64 = @bitCast(try files.call(s, a, d.a));
            const v = try filled(a, w, ty.signed, .zero);
            v.values()[0] = if (w >= 64) raw else raw & ((@as(u64, 1) << @intCast(w)) - 1);
            break :blk v;
        },
        .scan, .fread => blk: {
            const r = if (row.tag == .fread) try scan.fread(s, a, d.a) else if (d.b == 0) try scan.sscanf(s, a, d.a) else try scan.fscanf(s, a, d.a);
            const raw: u64 = @bitCast(r);
            const v = try filled(a, w, ty.signed, .zero);
            v.values()[0] = if (w >= 64) raw else raw & ((@as(u64, 1) << @intCast(w)) - 1);
            break :blk v;
        },
        .random => blk: {
            const raw: u32 = @bitCast(try random(s, a, p.extraData(Program.Random, d.a)));
            const v = try filled(a, w, ty.signed, .zero);
            v.values()[0] = if (w >= 64) raw else raw & ((@as(u64, 1) << @intCast(w)) - 1);
            break :blk v;
        },
        .clog2 => blk: {
            const v = try filled(a, 32, true, .zero);
            v.values()[0] = ceilLog2(try eval(s, a, d.a));
            break :blk normalize(a, v, w, ty.signed);
        },
    };
}

/// Row `e` as a double: a real row's value, an integral row by §4.8.2.
pub fn real(s: *State, a: Allocator, e: u32) Error!f64 {
    const p = s.p;
    assert(e < p.exprs.len);
    const row = p.exprs.get(e);
    const d = row.data;
    if (!row.ty.real) return logic.realOfInt(try eval(s, a, e));
    return switch (row.tag) {
        .real_constant => @bitCast(@as(u64, d.a) | @as(u64, d.b) << 32),
        .slot, .elem => logic.realOf(try eval(s, a, e)),
        .call => logic.realOf(try calls.call(s, a, d.a)),
        .real_of_int => logic.realOfInt(try eval(s, a, d.a)),
        .real_neg => -(try real(s, a, d.a)),
        .real_add => try real(s, a, d.a) + try real(s, a, d.b),
        .real_sub => try real(s, a, d.a) - try real(s, a, d.b),
        .real_mul => try real(s, a, d.a) * try real(s, a, d.b),
        .real_div => try real(s, a, d.a) / try real(s, a, d.b),
        .real_pow => std.math.pow(f64, try real(s, a, d.a), try real(s, a, d.b)),
        .real_cond => blk: {
            const arms = p.extra[d.b..][0..2];
            break :blk switch (try truth(s, a, d.a)) {
                .one => try real(s, a, arms[0]),
                .zero => try real(s, a, arms[1]),
                .x, .z => x: {
                    // §5.1.13: both arms run; an ambiguous real result is 0.
                    _ = try real(s, a, arms[0]);
                    _ = try real(s, a, arms[1]);
                    break :x 0;
                },
            };
        },
        .realtime => p.times[d.a].scale.realAt(s.scheduler.now),
        .bitstoreal => @bitCast((try eval(s, a, d.a)).values()[0]),
        .math1 => math1(@fromBackingInt(@intCast(d.b)), try real(s, a, d.a)),
        .math2 => blk: {
            const args = p.extra[d.a..][0..2];
            const x = try real(s, a, args[0]);
            const y = try real(s, a, args[1]);
            break :blk switch (@as(Program.Math, @fromBackingInt(@intCast(d.b)))) {
                .pow => std.math.pow(f64, x, y),
                .atan2 => std.math.atan2(x, y),
                .hypot => std.math.hypot(x, y),
                else => unreachable, // else: the one-argument functions are `math1`
            };
        },
        else => unreachable, // else: no other row is real-typed
    };
}

/// §5.1.9 the truth of row `e`: a real is true when it is not zero; an
/// integral row is its `Literal.truth` (0, 1 or x).
pub fn truth(s: *State, a: Allocator, e: u32) Error!Bit {
    assert(e < s.p.exprs.len);
    if (s.p.exprs.items(.ty)[e].real) return if (try real(s, a, e) != 0) .one else .zero;
    const b = (try eval(s, a, e)).truth();
    assert(b != .z);
    return b;
}

/// Slot `slot`'s value now, copied into `a` (both planes), in the slot's type.
pub fn read(s: *const State, a: Allocator, slot: u32) Error!Literal {
    const p = s.p;
    assert(slot < p.slots.len);
    const sl = p.slots.get(slot);
    const n = Program.words(sl.ty.width);
    const planes = try a.alloc(u64, 2 * n);
    @memcpy(planes[0..n], s.v[sl.word..][0..n]);
    @memcpy(planes[n..], s.x[sl.word..][0..n]);
    return .{ .width = sl.ty.width, .signed = sl.ty.signed, .sized = true, .planes = planes };
}

/// §3.9 the element slot `el` names now; null for an x/z or out-of-range
/// index. Every index is evaluated before an out-of-range one decides.
pub fn address(s: *State, a: Allocator, el: Program.Elem) Error!?u32 {
    const dims = s.p.list(el.dims);
    assert(dims.len % 3 == 0);
    var at: u64 = 0;
    var stride: u64 = 1;
    var inside = true;
    // Row-major: the last dimension is the innermost.
    var k = dims.len / 3;
    while (k != 0) {
        k -= 1;
        const idx = indexOf(try eval(s, a, dims[3 * k])) orelse return null;
        const low: i64 = @as(i32, @bitCast(dims[3 * k + 1]));
        const high: i64 = @as(i32, @bitCast(dims[3 * k + 2]));
        if (idx < low or idx > high) inside = false;
        if (inside) at += stride * @as(u64, @intCast(idx - low));
        stride *= @as(u64, @intCast(high - low + 1));
    }
    if (!inside) return null;
    assert(at < el.count);
    return el.base + @as(u32, @intCast(at));
}

/// §9.2 writes `value` (already in the place's type) where place `place`
/// lands now, or queues it as a nonblocking update after `delay`. A
/// concatenation splits the value, its last operand taking the low bits.
pub fn put(s: *State, a: Allocator, place: u32, value: Literal, nba: bool, delay: ?u64) Error!void {
    const p = s.p;
    const pl = p.extraData(Program.Place, place);
    switch (pl.kind) {
        .concat => {
            const parts = p.list(p.extraData(struct { l: Program.List }, pl.a).l);
            assert(parts.len % 2 == 0);
            var lo: u32 = 0;
            var k = parts.len / 2;
            while (k != 0) {
                k -= 1;
                const width = parts[2 * k + 1];
                const part = try filled(a, width, false, .zero);
                logic.copyBits(part, 0, value, lo, width);
                try put(s, a, parts[2 * k], part, nba, delay);
                lo += width;
            }
            assert(lo <= value.width);
        },
        .slot => try land(s, a, pl.a, null, value, nba, delay),
        .elem => if (try address(s, a, p.extraData(Program.Elem, pl.a))) |at| try land(s, a, at, null, value, nba, delay),
        .select => {
            const sl = p.extraData(Program.Select, pl.a);
            const at = (try selectSlot(s, a, sl)) orelse return;
            const sel = (try selection(s, a, sl)) orelse return;
            try land(s, a, at, sel, value, nba, delay);
        },
    }
}

/// Writes `value` into `slot`, or into its `sel` bits merged with what the
/// slot holds now; bits outside the slot are dropped.
pub fn write(s: *State, a: Allocator, slot: u32, sel: ?Sel, value: Literal) Error!void {
    assert(slot < s.p.slots.len);
    const b = sel orelse return s.store(slot, value);
    const merged = try read(s, a, slot);
    const lo = @max(b.first, 0);
    const hi = @min(b.first + @as(i64, b.count), @as(i64, merged.width));
    if (lo < hi) logic.copyBits(merged, @intCast(lo), value, @intCast(lo - b.first), @intCast(hi - lo));
    return s.store(slot, merged);
}

// ---- private ----

/// §17.9 one draw: the seed read and written back (an inout argument), or
/// the seedless `$random`'s own; a non-positive mean or degree draws 0 and
/// keeps the seed (a warning).
fn random(s: *State, a: Allocator, r: Program.Random) Error!i32 {
    const none = @backingInt(Program.Ref.none);
    if (r.seed == none) {
        const d = dist(.random, s.random_seed, 0, 0).?;
        s.random_seed = d.seed;
        return d.value;
    }
    const seed = try long(s, a, r.seed);
    const x = if (r.x != none) try long(s, a, r.x) else 0;
    const y = if (r.y != none) try long(s, a, r.y) else 0;
    const d = dist(r.dist, seed, x, y) orelse {
        try s.warn("a $dist_ mean, degree of freedom or k_stage is not positive: the result is 0 and the seed is unchanged", .{});
        return 0;
    };
    const lit = try filled(a, 64, true, .zero);
    lit.values()[0] = @bitCast(@as(i64, d.seed));
    try put(s, a, r.place, try calls.convertValue(a, lit, false, r.ty), false, null);
    return d.value;
}

fn long(s: *State, a: Allocator, e: u32) Error!i32 {
    return @truncate((try eval(s, a, e)).asInt() orelse 0);
}

/// The §17.9.3 listing's draw and its next seed; null for a bad parameter.
fn dist(f: Program.Dist, seed: i32, x_: i32, y_: i32) ?struct { value: i32, seed: i32 } {
    const rng = @import("kernels").rng_kernels;
    const bad = switch (f) {
        .random, .uniform, .normal => false,
        .exponential, .poisson, .chi_square, .t => x_ <= 0,
        .erlang => x_ <= 0 or y_ <= 0,
    };
    if (bad) return null;
    const sd: i64 = seed;
    const x: f64 = @floatFromInt(x_);
    const y: f64 = @floatFromInt(y_);
    const r: f64, const next: f64 = switch (f) {
        .random => .{ rng.zRngRand(sd), rng.zRngRandNext(sd) },
        .uniform => .{ rng.zRngIUniform(sd, x, y), rng.zRngIUniformNext(sd, x, y) },
        .normal => .{ rng.zRngNormal(sd, x, y), rng.zRngNormalNext(sd, x, y) },
        .exponential => .{ rng.zRngExponential(sd, x), rng.zRngExponentialNext(sd, x) },
        .poisson => .{ rng.zRngPoisson(sd, x), rng.zRngPoissonNext(sd, x) },
        .chi_square => .{ rng.zRngChiSquare(sd, x), rng.zRngChiSquareNext(sd, x) },
        .t => .{ rng.zRngT(sd, x), rng.zRngTNext(sd, x) },
        .erlang => .{ rng.zRngErlang(sd, x, y), rng.zRngErlangNext(sd, x, y) },
    };
    // The listing's `(long)(r + 0.5)`, mirrored for a negative r.
    const m = @trunc(@abs(r) + 0.5);
    return .{ .value = std.math.lossyCast(i32, if (r >= 0) m else -m), .seed = @intFromFloat(next) };
}

fn land(s: *State, a: Allocator, slot: u32, sel: ?Sel, value: Literal, nba: bool, delay: ?u64) Error!void {
    if (nba) return s.scheduleWrite(slot, sel, value, delay);
    return write(s, a, slot, sel, value);
}

fn scalarIn(a: Allocator, b: Bit, ty: Program.Ty) Error!Literal {
    return normalize(a, try logic.scalar(a, b), ty.width, ty.signed);
}

/// An index value by its own signedness; null for x/z or outside i64.
fn indexOf(v: Literal) ?i64 {
    return std.math.cast(i64, v.asIndex() orelse return null);
}

fn selectSlot(s: *State, a: Allocator, sl: Program.Select) Error!?u32 {
    if (sl.elem == std.math.maxInt(u32)) return sl.slot;
    return address(s, a, s.p.extraData(Program.Elem, sl.elem));
}

/// The bits select `sl` names now; null for an x/z index.
fn selection(s: *State, a: Allocator, sl: Program.Select) Error!?Sel {
    const first: i64 = switch (sl.mode) {
        .const_part => sl.first,
        .bit => position(sl, indexOf(try eval(s, a, sl.index)) orelse return null),
        .up, .down => blk: {
            const base = (try eval(s, a, sl.index)).asIndex() orelse return null;
            const ascending = sl.msb >= sl.lsb;
            const p = if (ascending) base -| sl.lsb else @as(i128, sl.lsb) -| base;
            break :blk std.math.lossyCast(i64, if (ascending == (sl.mode == .up)) p else p -| (sl.count - 1));
        },
    };
    const width = s.p.slots.items(.ty)[sl.slot].width;
    if (first >= width or first <= -@as(i64, sl.count)) return null;
    return .{ .first = first, .count = sl.count };
}

/// Storage position of declared index `i` of a `[msb:lsb]` vector.
fn position(sl: Program.Select, i: i64) i64 {
    return if (sl.msb >= sl.lsb) i -| sl.lsb else @as(i64, sl.lsb) -| i;
}

fn readSelect(s: *State, a: Allocator, sl: Program.Select) Error!Literal {
    const out = try filled(a, sl.count, false, .x);
    const at = (try selectSlot(s, a, sl)) orelse return out;
    const sel = (try selection(s, a, sl)) orelse return out;
    const v = try read(s, a, at);
    const lo = @max(sel.first, 0);
    const hi = @min(sel.first + @as(i64, sel.count), @as(i64, v.width));
    if (lo < hi) logic.copyBits(out, @intCast(lo - sel.first), v, @intCast(lo), @intCast(hi - lo));
    return out;
}

/// §17.11.1 `$clog2`: the operand's bits as unsigned; x/z gives 0.
fn ceilLog2(value: Literal) u64 {
    if (value.hasUnknown()) return 0;
    var length: u64 = 0;
    var power_of_two = true;
    for (value.values(), 0..) |word, index| {
        if (word == 0) continue;
        if (length != 0 or word & (word - 1) != 0) power_of_two = false;
        length = @as(u64, @intCast(index)) * 64 + 64 - @clz(word);
    }
    assert(length <= @as(u64, value.width));
    return if (length != 0 and power_of_two) length - 1 else length;
}

fn math1(f: Program.Math, x: f64) f64 {
    return switch (f) {
        .ln => @log(x),
        .log10 => @log10(x),
        .exp => @exp(x),
        .sqrt => @sqrt(x),
        .floor => @floor(x),
        .ceil => @ceil(x),
        .sin => @sin(x),
        .cos => @cos(x),
        .tan => @tan(x),
        .asin => std.math.asin(x),
        .acos => std.math.acos(x),
        .atan => std.math.atan(x),
        .sinh => std.math.sinh(x),
        .cosh => std.math.cosh(x),
        .tanh => std.math.tanh(x),
        .asinh => std.math.asinh(x),
        .acosh => std.math.acosh(x),
        .atanh => std.math.atanh(x),
        .ln1p => std.math.log1p(x),
        .expm1 => std.math.expm1(x),
        .pow, .atan2, .hypot => unreachable, // two arguments: `math2`
    };
}
