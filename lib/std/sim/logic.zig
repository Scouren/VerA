//! Four-state values (`kernels.Integer.Literal`, two planes) in, the shape
//! operations the runtime needs between operators out: fills, single-bit
//! writes, §5.5 resizing, bit copies, and §4.8.2's real/integer conversions.
//! The operators themselves are `Literal`'s.
//! Cites: IEEE 1364-2005 §3.6, §4.8.2, §5.5.1, §5.5.3, §9.4.1.
//!
//! Contents:
//! - `pub const Int`, `pub const Literal`, `pub const Bit`
//! - `pub const Error`
//! - `pub fn filled(a: Allocator, width: u32, signed: bool, fill: Bit) Error!Literal`
//! - `pub fn setBit(value: Literal, index: u32, b: Bit) void`
//! - `pub fn planeBit(v: u64, x: u64) Bit`
//! - `pub fn wordMask(width: u32, w: usize) u64`
//! - `pub fn normalize(a: Allocator, value: Literal, width: u32, signed: bool) Error!Literal`
//! - `pub fn copyBits(dst: Literal, dst_lo: u32, src: Literal, src_lo: u32, count: u32) void`
//! - `pub fn scalar(a: Allocator, b: Bit) Error!Literal`
//! - `pub fn realLiteral(a: Allocator, r: f64) Error!Literal`
//! - `pub fn realOf(v: Literal) f64`
//! - `pub fn realOfInt(v: Literal) f64`
//! - `pub fn intOfReal(a: Allocator, r: f64) Error!Literal`
//! - `pub fn stringLiteral(a: Allocator, text: []const u8) Error!Literal`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
pub const Int = @import("kernels").Integer;
pub const Literal = Int.Literal;
pub const Bit = Int.Bit;

/// Every value operation allocates its result from the caller's scratch.
pub const Error = Allocator.Error;

/// A `width`-bit value of every bit `fill`.
pub fn filled(a: Allocator, width: u32, signed: bool, fill: Bit) Error!Literal {
    assert(width >= 1);
    const n = (@as(usize, width) - 1) / 64 + 1;
    const planes = try a.alloc(u64, n * 2);
    @memset(planes[0..n], if (@backingInt(fill) & 1 != 0) std.math.maxInt(u64) else 0);
    @memset(planes[n..], if (@backingInt(fill) >> 1 != 0) std.math.maxInt(u64) else 0);
    const tail: u6 = @truncate(width);
    if (tail != 0) {
        const keep = (@as(u64, 1) << tail) - 1;
        planes[n - 1] &= keep;
        planes[2 * n - 1] &= keep;
    }
    assert(planes.len == 2 * n);
    return .{ .width = width, .signed = signed, .sized = true, .planes = planes };
}

/// Writes bit `index` of `value`. Asserts the bit is inside the planes.
pub fn setBit(value: Literal, index: u32, b: Bit) void {
    assert(index / 64 < value.planes.len / 2);
    const sh: u6 = @truncate(index);
    const word = index / 64;
    const bits: u64 = @backingInt(b);
    const v = &value.values()[word];
    const u = &value.unknowns()[word];
    v.* = (v.* & ~(@as(u64, 1) << sh)) | ((bits & 1) << sh);
    u.* = (u.* & ~(@as(u64, 1) << sh)) | ((bits >> 1) << sh);
    assert(planeBit(v.* >> sh, u.* >> sh) == b);
}

/// The bit whose value-plane bit is bit 0 of `v` and unknown bit bit 0 of `x`.
pub fn planeBit(v: u64, x: u64) Bit {
    return @fromBackingInt(@intCast(@as(u2, @truncate(v & 1)) | (@as(u2, @truncate(x & 1)) << 1)));
}

/// The declared bits of plane word `w` of a `width`-bit value.
pub fn wordMask(width: u32, w: usize) u64 {
    const lo = w * 64;
    if (lo >= width) return 0;
    const n = width - lo;
    return if (n >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(n)) - 1;
}

/// `value` in `width` bits typed `signed`: extended by the TARGET's
/// signedness (the §5.5.2 context reaches the operand) or truncated.
/// Returns `value` itself when nothing changes.
pub fn normalize(a: Allocator, value: Literal, width: u32, signed: bool) Error!Literal {
    assert(width != 0);
    assert(value.width != 0);
    if (value.width == width and value.signed == signed) return value;
    var out = value.resize(a, width, if (signed) .sign else .zero) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ZeroSize => unreachable,
    };
    out.signed = signed;
    assert(out.width == width);
    return out;
}

/// Copies bits [src_lo, src_lo + count) of `src` into [dst_lo, dst_lo +
/// count) of `dst`, both planes, leaving `dst`'s other bits alone.
pub fn copyBits(dst: Literal, dst_lo: u32, src: Literal, src_lo: u32, count: u32) void {
    assert(@as(u64, src_lo) + count <= src.width);
    assert(@as(u64, dst_lo) + count <= dst.width);
    const planes = [2][2][]u64{ .{ dst.values(), src.values() }, .{ dst.unknowns(), src.unknowns() } };
    var done: u32 = 0;
    while (done < count) {
        const s = src_lo + done;
        const d = dst_lo + done;
        const n = @min(count - done, 64 - d % 64, 64 - s % 64);
        const mask: u64 = if (n == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(n)) - 1;
        const ds: u6 = @intCast(d % 64);
        for (planes) |p| {
            const bits = (p[1][s / 64] >> @intCast(s % 64)) & mask;
            p[0][d / 64] = (p[0][d / 64] & ~(mask << ds)) | (bits << ds);
        }
        done += n;
    }
    assert(done == count);
}

/// One bit `b`, unsigned.
pub fn scalar(a: Allocator, b: Bit) Error!Literal {
    const out = try filled(a, 1, false, b);
    assert(out.bit(0) == b);
    return out;
}

/// A real as the 64-bit value that holds it.
pub fn realLiteral(a: Allocator, r: f64) Error!Literal {
    const out = try filled(a, 64, true, .zero);
    out.values()[0] = @bitCast(r);
    assert(!out.hasUnknown());
    return out;
}

/// The real a real-typed value holds.
pub fn realOf(v: Literal) f64 {
    assert(v.width == 64);
    return @bitCast(v.values()[0]);
}

/// §4.8.2 integer-to-real: the value by its own signedness, x and z bits as
/// 0, exactly rounded at any width.
pub fn realOfInt(v: Literal) f64 {
    assert(v.width != 0);
    if (v.width > 64) return wordsToReal(v.values(), v.unknowns(), v.width, v.signed);
    const lo = v.values()[0] & ~v.unknowns()[0];
    if (!v.signed) return @floatFromInt(lo);
    const shift: u6 = @intCast(64 - v.width);
    return @floatFromInt(@as(i64, @bitCast(lo << shift)) >> shift);
}

/// §4.8.2 real-to-integer: rounded half away from zero, signed, at least 64
/// bits and as wide as the integer needs; a non-finite real is x.
pub fn intOfReal(a: Allocator, r: f64) Error!Literal {
    const n = @round(r);
    if (!std.math.isFinite(n)) return filled(a, 64, true, .x);
    if (n >= -0x1p63 and n < 0x1p63) {
        const out = try filled(a, 64, true, .zero);
        out.values()[0] = @bitCast(@as(i64, @intFromFloat(n)));
        return out;
    }
    const fr = std.math.frexp(@abs(n));
    const mant: u64 = @intFromFloat(std.math.ldexp(fr.significand, 53));
    assert(fr.exponent >= 64);
    const shift: u32 = @intCast(fr.exponent - 53);
    const out = try filled(a, @intCast(fr.exponent + 1), true, .zero);
    const v = out.values();
    v[shift / 64] |= mant << @intCast(shift % 64);
    if (shift % 64 != 0 and shift / 64 + 1 < v.len) v[shift / 64 + 1] |= mant >> @intCast(64 - shift % 64);
    if (n < 0) {
        var carry: u1 = 1;
        for (v) |*w| {
            const sum = @addWithOverflow(~w.*, @as(u64, carry));
            w.* = sum[0];
            carry = sum[1];
        }
        const top = out.width % 64;
        if (top != 0) v[v.len - 1] &= (@as(u64, 1) << @intCast(top)) - 1;
    }
    return out;
}

/// §3.6 `text` as packed ASCII, the first character most significant; an
/// empty string is one zero byte.
pub fn stringLiteral(a: Allocator, text: []const u8) Error!Literal {
    assert(text.len <= std.math.maxInt(u32) / 8);
    const width: u32 = if (text.len == 0) 8 else @intCast(text.len * 8);
    const value = try filled(a, width, false, .zero);
    for (text, 0..) |c, i| {
        const shift: u32 = @intCast((text.len - 1 - i) * 8);
        value.values()[shift / 64] |= @as(u64, c) << @intCast(shift % 64);
    }
    assert(value.width == width);
    return value;
}

// ---- private ----

/// §4.8.2 of a value wider than 64 bits: the 64 bits from the most
/// significant one down and a sticky bit, so the one rounding is exact.
fn wordsToReal(v: []const u64, x: []const u64, width: u32, signed: bool) f64 {
    const n: usize = (width + 63) / 64;
    const Mag = struct {
        v: []const u64,
        x: []const u64,
        width: u32,
        n: usize,
        neg: bool = false,
        low: usize = 0,
        fn raw(m: @This(), i: usize) u64 {
            const b = m.v[i] & ~m.x[i];
            return if (i == m.n - 1 and m.width % 64 != 0) b & ((@as(u64, 1) << @intCast(m.width % 64)) - 1) else b;
        }
        fn get(m: @This(), i: usize) u64 {
            if (!m.neg) return m.raw(i);
            const r = if (i < m.low) 0 else if (i == m.low) 0 -% m.raw(i) else ~m.raw(i);
            return if (i == m.n - 1 and m.width % 64 != 0) r & ((@as(u64, 1) << @intCast(m.width % 64)) - 1) else r;
        }
    };
    var mag: Mag = .{ .v = v, .x = x, .width = width, .n = n };
    mag.neg = signed and (mag.raw(n - 1) >> @intCast((width - 1) % 64)) & 1 != 0;
    if (mag.neg) mag.low = for (0..n) |i| {
        if (mag.raw(i) != 0) break i;
    } else n;
    var t: usize = n;
    while (t > 0 and mag.get(t - 1) == 0) t -= 1;
    if (t == 0) return 0;
    const hi = mag.get(t - 1);
    const lead: u32 = 63 - @clz(hi);
    const msb: u32 = @as(u32, @intCast(t - 1)) * 64 + lead;
    const r: f64 = if (msb < 64) @floatFromInt(hi) else blk: {
        const sh: u32 = 63 - lead;
        const next = mag.get(t - 2);
        var top64 = if (sh == 0) hi else (hi << @intCast(sh)) | (next >> @intCast(64 - sh));
        var sticky = (if (sh == 0) next else next << @intCast(sh)) != 0;
        for (0..t - 2) |i| sticky = sticky or mag.get(i) != 0;
        if (sticky) top64 |= 1;
        break :blk std.math.ldexp(@as(f64, @floatFromInt(top64)), @intCast(msb - 63));
    };
    return if (mag.neg) -r else r;
}

test "realOfInt reads x as 0 and agrees with the signed reading" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try filled(a, 4, false, .zero);
    setBit(v, 0, .one);
    setBit(v, 2, .x);
    setBit(v, 3, .one);
    try std.testing.expectEqual(@as(f64, 9), realOfInt(v));
    const s = try filled(a, 4, true, .one);
    try std.testing.expectEqual(@as(f64, -1), realOfInt(s));
    const wide = try filled(a, 130, true, .one);
    try std.testing.expectEqual(@as(f64, -1), realOfInt(wide));
    try std.testing.expect((try intOfReal(a, std.math.inf(f64))).hasUnknown());
    try std.testing.expectEqual(@as(f64, 0x1p100), realOfInt(try intOfReal(a, 0x1p100)));
}
