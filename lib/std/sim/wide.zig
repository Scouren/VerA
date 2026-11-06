//! IEEE 1364-2005 §5.1.5 `*`, `/`, `%` and `**` of two 4-state values wider
//! than one word in, the result written into the caller's planes out, with
//! no allocation (lib/TODO.md §9 bug 2): the bits come from
//! `kernels.wide_kernels`' limb algorithms, instantiated over a ladder of
//! widths each operand is extended to. An x or z bit, a division by zero
//! and zero to a negative power give all x, as `kernels.Integer`'s do.
//! Cites: IEEE 1364-2005 §5.1.5 (Table 5-6), §5.4, §5.5.
//!
//! Contents:
//! - `pub const Op = enum { mul, div, rem, pow }`
//! - `pub const max_width: u32`
//! - `pub fn arith(op: Op, a: Literal, b: Literal, out: Literal) bool`

const std = @import("std");
const assert = std.debug.assert;
const kernels = @import("kernels");
const zw = kernels.wide_kernels;
const Literal = kernels.Integer.Literal;

/// The four operators `kernels.Integer` would allocate for past one word.
pub const Op = enum { mul, div, rem, pow };

/// The widest operation `arith` takes; a wider one is the caller's
/// (`kernels.Integer`, which allocates).
/// ponytail: past 4096 bits the allocating operator stays; widen the
/// ladder if a design measures it.
pub const max_width: u32 = 4096;

/// The limb counts instantiated: each operation runs at the first that holds
/// both operands.
const ladder = [_]u32{ 128, 256, 512, 1024, 2048, max_width };

/// `a op b` into `out`, whose width and signedness the caller set as
/// `kernels.Integer` would: max(a, b) and both signed for `* / %`, the base's
/// for `**` (the exponent keeps its own). False, `out` untouched, when the
/// widest operand is one word or less, or past `max_width`.
pub fn arith(op: Op, a: Literal, b: Literal, out: Literal) bool {
    const w = @max(a.width, b.width);
    if (w <= 64 or w > max_width) return false;
    assert(out.width == if (op == .pow) a.width else w);
    if (a.reduce(.xor_bits) == .x or b.reduce(.xor_bits) == .x) {
        unknown(out);
        return true;
    }
    inline for (ladder) |n| if (w <= n) {
        at(n, op, a, b, out);
        return true;
    };
    unreachable; // the ladder ends at `max_width`
}

// ---- private ----

fn at(comptime n: u32, op: Op, a: Literal, b: Literal, out: Literal) void {
    const L = zw.zwL;
    const signed = if (op == .pow) a.signed else a.signed and b.signed;
    const la = limbs(n, a, signed);
    const lb = limbs(n, b, if (op == .pow) b.signed else signed);
    const zero = std.mem.zeroes([zw.zwLimbs(n)]u32);
    const r = switch (op) {
        .mul => L.mul(n, la, lb),
        .div, .rem => r: {
            if (std.mem.eql(u32, &lb, &zero)) return unknown(out);
            break :r L.divRem(n, signed, op == .rem, la, lb);
        },
        .pow => r: {
            // Table 5-6: zero to a negative power is x; the kernel's is 0.
            const negative = b.signed and b.bit(b.width - 1) == .one;
            if (negative and std.mem.eql(u32, &la, &zero)) return unknown(out);
            break :r zw.zwToLimbs(n, if (signed) pow(n, true, la, lb, b.signed) else pow(n, false, la, lb, b.signed));
        },
    };
    store(n, r, out);
}

fn pow(comptime n: u32, comptime signed: bool, a: [zw.zwLimbs(n)]u32, e: [zw.zwLimbs(n)]u32, esigned: bool) zw.ZW(n) {
    const base = zw.zwFromLimbs(n, a);
    const exp = zw.zwFromLimbs(n, e);
    return if (esigned) zw.zwPow(n, signed, base, n, true, exp) else zw.zwPow(n, signed, base, n, false, exp);
}

/// `v`'s known bits as `n`-bit limbs, extended by `signed`.
fn limbs(comptime n: u32, v: Literal, signed: bool) [zw.zwLimbs(n)]u32 {
    assert(v.width <= n);
    var r = std.mem.zeroes([zw.zwLimbs(n)]u32);
    const vals = v.values();
    for (0..v.width) |i| {
        if ((vals[i / 64] >> @intCast(i % 64)) & 1 != 0) r[i / 32] |= @as(u32, 1) << @intCast(i % 32);
    }
    if (signed and v.bit(v.width - 1) == .one) for (v.width..n) |i| {
        r[i / 32] |= @as(u32, 1) << @intCast(i % 32);
    };
    return zw.zwL.norm(n, r);
}

/// The low `out.width` bits of `r` into `out`, all known.
fn store(comptime n: u32, r: [zw.zwLimbs(n)]u32, out: Literal) void {
    assert(out.width <= n);
    const v = out.values();
    @memset(out.planes, 0);
    for (v, 0..) |*word, k| {
        const lo: u64 = if (2 * k < r.len) r[2 * k] else 0;
        const hi: u64 = if (2 * k + 1 < r.len) r[2 * k + 1] else 0;
        word.* = lo | hi << 32;
    }
    v[v.len - 1] &= mask(out.width);
}

fn mask(width: u32) u64 {
    const t: u6 = @truncate(width);
    return if (t == 0) std.math.maxInt(u64) else (@as(u64, 1) << t) - 1;
}

fn unknown(out: Literal) void {
    @memset(out.planes, std.math.maxInt(u64));
    const m = mask(out.width);
    out.values()[out.values().len - 1] &= m;
    out.unknowns()[out.unknowns().len - 1] &= m;
}

/// A random operand: a uniform value, or 0, 1, all ones, the most negative
/// or the most positive; a tenth of them with an x or z bit.
fn operand(a: std.mem.Allocator, rand: std.Random, width: u32, signed: bool) !Literal {
    const n = (width + 63) / 64;
    const planes = try a.alloc(u64, 2 * n);
    @memset(planes, 0);
    const v: Literal = .{ .width = width, .signed = signed, .sized = true, .planes = planes };
    const vals = planes[0..n];
    switch (rand.uintLessThan(u8, 8)) {
        0 => {},
        1 => vals[0] = 1,
        2 => @memset(vals, std.math.maxInt(u64)),
        3 => vals[(width - 1) / 64] = @as(u64, 1) << @intCast((width - 1) % 64),
        4 => {
            @memset(vals, std.math.maxInt(u64));
            vals[(width - 1) / 64] &= ~(@as(u64, 1) << @intCast((width - 1) % 64));
        },
        // A short value: the divisor and exponent cases a full-width one
        // rarely reaches.
        5 => vals[0] = rand.uintLessThan(u64, 1000),
        else => rand.bytes(std.mem.sliceAsBytes(vals)),
    }
    if (rand.uintLessThan(u8, 10) == 0) {
        const k = rand.uintLessThan(u32, width);
        planes[n + k / 64] |= @as(u64, 1) << @intCast(k % 64);
    }
    vals[n - 1] &= mask(width);
    return v;
}

test "§5.1.5 wide * / % ** agree with kernels.Integer over random widths and x/z operands" {
    // Oracle: `kernels.Integer`'s operators (`std.math.big` exact integers),
    // which compute the same answer a different way.
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(0x5eed_1364);
    const rand = prng.random();
    var checked: u32 = 0;
    for (0..3000) |round| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const op = rand.enumValue(Op);
        const big = round % 50 == 0;
        const wa = rand.intRangeAtMost(u32, 1, if (big) max_width else 300);
        // `* / %` take operands of one width (the caller's context); `**`
        // an exponent of its own.
        const wb = if (op == .pow) rand.intRangeAtMost(u32, 1, if (big) max_width else 300) else wa;
        const sa = rand.boolean();
        const sb = if (op == .pow) rand.boolean() else sa;
        const x = try operand(a, rand, wa, sa);
        const y = try operand(a, rand, wb, sb);
        const want = if (op == .pow) try x.power(a, y) else try x.arithmetic(a, switch (op) {
            .mul => .multiply,
            .div => .divide,
            .rem => .remainder,
            .pow => unreachable,
        }, y);
        var got = want;
        got.planes = try a.alloc(u64, want.planes.len);
        @memset(got.planes, 0xaaaa_aaaa_aaaa_aaaa);
        if (!arith(op, x, y, got)) {
            try std.testing.expect(@max(wa, wb) <= 64);
            continue;
        }
        checked += 1;
        std.testing.expectEqualSlices(u64, want.planes, got.planes) catch |e| {
            std.debug.print("{t}: {d}-bit {} by {d}-bit {}\n", .{ op, wa, sa, wb, sb });
            return e;
        };
    }
    try std.testing.expect(checked > 1500);
}
