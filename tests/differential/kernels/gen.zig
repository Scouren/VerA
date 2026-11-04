//! The `diff-kernels` harness: argument generators (specials, then seeded
//! random draws), the bit-level distance between two answers, and the
//! `Report` that holds every named difference to `kernels.xfail`. One
//! comparison is a function name, an old and a new function, and the specs
//! of its run-time arguments; `cmp` calls both on the same arguments and
//! records the distance.
//! Cites: none (test tooling).
//!
//! Contents:
//! - `pub const random_per_fn: usize`
//! - `pub const specials: [26]f64`
//! - `pub const Rng = std.Random`
//! - `pub const Judgement = struct { old_err, new_err, bound }`, `pub fn both`
//! - `pub const Report = struct` (`Row`, `record`, `judge`, `random`)
//! - argument specs: each a struct with `pub const T` (the argument's type) and `pub fn gen`
//! - `pub fn Real(comptime lo: f64, comptime hi: f64) type`, `pub fn RealIn(...)`, `pub const AnyReal`
//! - `pub fn Int(comptime T: type, comptime lo: T, comptime hi: T) type`
//! - `pub fn Of(comptime T: type) type`: a spec's default for a plain type
//! - `pub fn cmp(rep: *Report, comptime name: []const u8, comptime old_f: anytype, comptime new_f: anytype, comptime pre: anytype, comptime Specs: anytype) void`
//! - `pub fn cmpJudged(...)`: `cmp`, each difference judged by a reference
//! - `pub fn dist(a: anytype, b: anytype) u64`
//! - `pub fn ulps(a: f64, b: f64) u64`

const std = @import("std");
const assert = std.debug.assert;

/// Seeded random argument sets per function, after its specials.
pub const random_per_fn: usize = 100_000;

/// The f64 specials every real argument draws from first: the signed zeros
/// and infinities, NaN, the subnormal and normal limits, and the values a
/// kernel branches on.
pub const specials = [_]f64{
    0.0,                     -0.0,   1.0,   -1.0,        0.5,          -0.5,      2.0,        -2.0,
    inf,                     -inf,   nan,   0x1p-1074,   -0x1p-1074,   0x1p-1022, -0x1p-1022, std.math.floatMax(f64),
    -std.math.floatMax(f64), 1e-300, 1e300, std.math.pi, -std.math.pi, 0.1,       3.0,        709.78,
    -745.2,                  1e-9,
};

pub const Rng = std.Random;

/// A real anywhere: the specials and random bits, else |x| < 1e3.
pub const AnyReal = Real(-1e3, 1e3);

/// One differing input judged by the f128 reference: each side's error in
/// ulps and the new side's documented bound, which the new side must keep
/// on every input. Two faithful libraries each round some inputs the other
/// way, so "at least as close as the old side" is judged per name on the
/// worst case (`Row.new_err <= Row.old_err`), with each side's count of
/// strictly closer inputs printed.
pub const Judgement = struct {
    old_err: f64,
    new_err: f64,
    bound: f64,

    fn settles(j: Judgement) bool {
        return j.new_err <= j.bound;
    }
};

/// Every comparison's outcome by name: a name that differs passes when the
/// reference settles each difference for the new side (an old-side bug,
/// counted), else only when `kernels.xfail` has a line whose bound covers
/// its largest distance; a line whose name never differs fails the run.
pub const Report = struct {
    gpa: std.mem.Allocator,
    rows: std.StringArrayHashMapUnmanaged(Row) = .empty,
    rng: std.Random.DefaultPrng = .init(0x6b65726e656c73),

    pub const Row = struct {
        compared: u64 = 0,
        differ: u64 = 0,
        max: u64 = 0,
        /// The first differing input, as text, for the run's log.
        example: [160]u8 = undefined,
        example_len: u8 = 0,
        /// Over the differing inputs a reference could judge: each side's
        /// largest error against it (ulps) and how often each was closer.
        judged: u64 = 0,
        old_err: f64 = 0,
        new_err: f64 = 0,
        old_closer: u64 = 0,
        new_closer: u64 = 0,
        /// Differences the reference could not judge, or where the new side
        /// is past its bound; a name passes on the reference alone at 0
        /// and with its worst case no farther than the old one's.
        unsettled: u64 = 0,
    };

    /// Records the reference's verdict on one differing input of `name`;
    /// null is an input it cannot judge.
    pub fn judge(rep: *Report, name: []const u8, j: ?Judgement) void {
        const row = rep.rows.getPtr(name).?;
        assert(row.differ >= 1);
        const v = j orelse {
            row.unsettled += 1;
            return;
        };
        row.judged += 1;
        row.old_err = @max(row.old_err, v.old_err);
        row.new_err = @max(row.new_err, v.new_err);
        if (v.old_err < v.new_err) row.old_closer += 1;
        if (v.new_err < v.old_err) row.new_closer += 1;
        if (!v.settles()) row.unsettled += 1;
        assert(row.judged <= row.differ);
    }

    /// Records one comparison of `name`; `d` is `dist`'s answer.
    pub fn record(rep: *Report, name: []const u8, d: u64, args: anytype) void {
        const gop = rep.rows.getOrPut(rep.gpa, name) catch @panic("OOM");
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const row = gop.value_ptr;
        row.compared += 1;
        if (d == 0) return;
        row.differ += 1;
        row.max = @max(row.max, d);
        if (row.example_len == 0) {
            const s = std.fmt.bufPrint(&row.example, "{any}", .{args}) catch row.example[0..row.example.len];
            row.example_len = @intCast(@max(1, s.len));
        }
    }

    pub fn random(rep: *Report) Rng {
        return rep.rng.random();
    }
};

const inf = std.math.inf(f64);
const nan = std.math.nan(f64);

/// Two parts of one answer judged apart (a value and the factor of its
/// lanes): settled only when both are; the larger errors either way.
pub fn both(a: ?Judgement, b: ?Judgement) ?Judgement {
    const x = a orelse return null;
    const y = b orelse return null;
    if (!x.settles()) return x;
    if (!y.settles()) return y;
    return .{ .old_err = @max(x.old_err, y.old_err), .new_err = @max(x.new_err, y.new_err), .bound = @max(x.bound, y.bound) };
}

/// The default spec for a plain argument type.
pub fn Of(comptime A: type) type {
    return switch (@typeInfo(A)) {
        .float => AnyReal,
        .int => Int(A, std.math.minInt(A), std.math.maxInt(A)),
        .bool => struct {
            pub const T = bool;
            pub fn gen(r: Rng, i: usize) bool {
                return if (i < 2) i == 1 else r.boolean();
            }
        },
        .@"enum" => struct {
            pub const T = A;
            pub fn gen(r: Rng, i: usize) A {
                const tags = comptime std.enums.values(A);
                return tags[if (i < tags.len) i else r.uintLessThan(usize, tags.len)];
            }
        },
        else => @compileError("no default spec for " ++ @typeName(A)),
    };
}

/// A real argument: draw `i` below `specials.len` is that special; after
/// it, one in eight is a special, one in eight a random bit pattern, and the
/// rest uniform in [lo, hi], half of them log-uniform in magnitude when the
/// range spans more than six decades.
pub fn Real(comptime lo: f64, comptime hi: f64) type {
    return Reals(lo, hi, false);
}

/// `Real`, but every draw in [lo, hi]: a special or a bit pattern outside
/// it is replaced by a uniform draw (a kernel's precondition).
pub fn RealIn(comptime lo: f64, comptime hi: f64) type {
    return Reals(lo, hi, true);
}

/// An integer argument in [lo, hi]: its ends, 0, ±1 and small values first,
/// then half uniform in a small window around 0 and half uniform in range.
pub fn Int(comptime U: type, comptime lo: U, comptime hi: U) type {
    comptime assert(lo <= hi);
    return struct {
        pub const T = U;
        pub fn gen(r: Rng, i: usize) U {
            const firsts = [_]i128{ lo, hi, 0, 1, -1, 2, 31, 32, 33, 63, 64, 65, -64 };
            if (i < firsts.len) return clampTo(firsts[i]);
            if (r.boolean()) return clampTo(@as(i128, r.intRangeAtMost(i32, -100, 100)));
            return r.intRangeAtMost(U, lo, hi);
        }
        fn clampTo(v: i128) U {
            return @intCast(std.math.clamp(v, lo, hi));
        }
    };
}

/// Calls `old_f` and `new_f` on `pre ++ args` for the specials (the first
/// `specials.len` draws of each spec) and `random_per_fn` seeded draws, and
/// records each answer's distance under `name`.
pub fn cmp(rep: *Report, comptime name: []const u8, comptime old_f: anytype, comptime new_f: anytype, comptime pre: anytype, comptime Specs: anytype) void {
    comptime var types: [Specs.len]type = undefined;
    inline for (Specs, 0..) |Sp, k| types[k] = Sp.T;
    const Args = @Tuple(&types);
    const r = rep.random();
    const n = specials.len + random_per_fn;
    for (0..n) |i| {
        var args: Args = undefined;
        // Specials pair up across arguments in the first draws: argument k
        // takes special (i / len^k) % len, so arity <= 2 sees every pair.
        inline for (Specs, 0..) |Sp, k| {
            const idx = if (i < specials.len * specials.len) (i / std.math.pow(usize, specials.len, k)) % specials.len else n;
            args[k] = Sp.gen(r, idx);
        }
        const a = @call(.auto, old_f, pre ++ args);
        const b = @call(.auto, new_f, pre ++ args);
        rep.record(name, dist(a, b), args);
    }
}

/// `cmp`, each difference judged by `judge(args, old, new) ?Judgement`.
pub fn cmpJudged(rep: *Report, comptime name: []const u8, comptime old_f: anytype, comptime new_f: anytype, comptime pre: anytype, comptime Specs: anytype, comptime judge: anytype) void {
    comptime var types: [Specs.len]type = undefined;
    inline for (Specs, 0..) |Sp, k| types[k] = Sp.T;
    const Args = @Tuple(&types);
    const r = rep.random();
    const n = specials.len + random_per_fn;
    for (0..n) |i| {
        var args: Args = undefined;
        inline for (Specs, 0..) |Sp, k| {
            const idx = if (i < specials.len * specials.len) (i / std.math.pow(usize, specials.len, k)) % specials.len else n;
            args[k] = Sp.gen(r, idx);
        }
        const a = @call(.auto, old_f, pre ++ args);
        const b = @call(.auto, new_f, pre ++ args);
        const d = dist(a, b);
        rep.record(name, d, args);
        if (d != 0) rep.judge(name, judge(args, a, b));
    }
}

/// The distance between two answers: 0 when they are the same bits (any
/// NaN equals any NaN), the ulps between two reals, and `maxInt(u64)` for
/// any other difference, a zero of the other sign included. Structs, arrays,
/// vectors, optionals and unions compare field by field (the two may be
/// different types of one shape) and answer the largest.
pub fn dist(a: anytype, b: anytype) u64 {
    const A = @TypeOf(a);
    const B = @TypeOf(b);
    const never = std.math.maxInt(u64);
    switch (@typeInfo(A)) {
        .float => return ulps(@floatCast(a), @floatCast(b)),
        .int, .bool, .comptime_int => return if (a == b) 0 else never,
        .@"enum" => return if (std.mem.eql(u8, @tagName(a), @tagName(b))) 0 else never,
        .void => return 0,
        .optional => {
            if (a == null and b == null) return 0;
            if (a == null or b == null) return never;
            return dist(a.?, b.?);
        },
        .array, .vector => {
            const len = switch (@typeInfo(A)) {
                .array => |x| x.len,
                .vector => |x| x.len,
                else => unreachable, // else: the prong is these two
            };
            var m: u64 = 0;
            inline for (0..len) |k| m = @max(m, dist(a[k], b[k]));
            return m;
        },
        .@"struct" => |s| {
            var m: u64 = 0;
            inline for (s.field_names) |f| m = @max(m, dist(@field(a, f), @field(b, f)));
            return m;
        },
        .@"union" => {
            if (!std.mem.eql(u8, @tagName(a), @tagName(b))) return never;
            switch (a) {
                inline else => |pa, tag| return dist(pa, @field(b, @tagName(tag))),
            }
        },
        .pointer => |p| {
            if (p.size == .slice) {
                if (a.len != b.len) return never;
                var m: u64 = 0;
                for (a, b) |x, y| m = @max(m, dist(x, y));
                return m;
            }
            return dist(a.*, b.*);
        },
        else => @compileError("dist: " ++ @typeName(A) ++ " vs " ++ @typeName(B)),
    }
}

/// The ulps between two f64s: 0 for the same bits or two NaNs,
/// `maxInt(u64)` for a NaN and a number or a zero and the other zero (a
/// sign is not a rounding: atan(-0) = +0 is a bug no ulp bound may hide).
pub fn ulps(a: f64, b: f64) u64 {
    const ba: u64 = @bitCast(a);
    const bb: u64 = @bitCast(b);
    if (ba == bb) return 0;
    const na = std.math.isNan(a);
    const nb = std.math.isNan(b);
    if (na and nb) return 0;
    if (na or nb) return std.math.maxInt(u64);
    const d = @abs(@as(i128, ord(ba)) - ord(bb));
    if (d == 0) return std.math.maxInt(u64); // +0 and -0
    return @intCast(@min(d, std.math.maxInt(u64) - 1));
}

// ---- private ----

fn Reals(comptime lo: f64, comptime hi: f64, comptime strict: bool) type {
    comptime assert(lo < hi);
    return struct {
        pub const T = f64;
        pub fn gen(r: Rng, i: usize) f64 {
            const x = draw(r, i);
            if (strict and !(x >= lo and x <= hi)) return lo + (hi - lo) * r.float(f64);
            return x;
        }
        fn draw(r: Rng, i: usize) f64 {
            if (i < specials.len) return specials[i];
            switch (r.uintLessThan(u8, 8)) {
                0 => return specials[r.uintLessThan(usize, specials.len)],
                1 => return @bitCast(r.int(u64)),
                else => {},
            }
            const span = @max(@abs(lo), @abs(hi));
            const floor = @max(@min(@abs(lo), @abs(hi)), 1e-300);
            if (span / floor > 1e6 and r.boolean()) {
                const l0 = @log10(floor);
                const l1 = @log10(span);
                const m = std.math.pow(f64, 10.0, l0 + (l1 - l0) * r.float(f64));
                const neg = lo < 0 and (hi <= 0 or r.boolean());
                return if (neg) -m else m;
            }
            return lo + (hi - lo) * r.float(f64);
        }
    };
}

/// `bits` as a signed position on the number line: adjacent doubles differ by 1.
fn ord(bits: u64) i64 {
    const s: i64 = @bitCast(bits);
    return if (s < 0) std.math.minInt(i64) - s else s;
}
