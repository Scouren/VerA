//! The `diff-air` oracle: `Air.interp` against the old pipeline's constant
//! kernel (`src/ir/opcode.zig`'s `fold`, which calls `kernels.fold`). For
//! every opcode the old fold folds, a one-instruction Air body runs over
//! the specials (±0, ±inf, NaN, the smallest subnormal, the largest double,
//! the integer limits, 0, ±1, and every pair of them for a binary tag) and
//! over `random_per_opcode` seeded random operand sets, and each answer is
//! compared with the fold's, bit for bit (any NaN equals any NaN; a fold
//! that declines must meet `error.NoValue`). A difference passes only when
//! a line of `air.xfail` names its opcode and kind, and a line whose kind
//! never occurs fails the run (an unexpected pass). Then structured control
//! against independent models: a loop summing 1..n against n(n+1)/2,
//! nested `cond_br`s against a Zig `if` chain, and the metamorphic pair
//! `select` / `block` + `cond_br`, which must agree bit for bit.
//! Cites: VAMS-2023 §4.2, §4.3 (Tables 4-14, 4-15), §4.2.12, §5.8.
//!
//! Contents: none public; tests only.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Air = @import("air");
const InternPool = @import("intern_pool");
const opcode = @import("ir").Mir.opcode;
const Const = @import("kernels").fold.Const;
const interp = Air.interp;
const Inst = Air.Inst;
const Value = interp.Value;

/// Seeded random operand sets per opcode (and per operand type for the
/// type-generic `opt_barrier` and `dstop`).
const random_per_opcode = 100_000;
/// Examples printed per opcode and kind of difference.
const examples_max = 3;

/// How the interpreter's answer differs from the fold's.
const Kind = enum {
    /// The fold has no value (null); the interpreter has one.
    declines,
    /// Both real and finite-signed, apart by at most the line's ulps.
    ulp,
    /// Both integer and different, with an operand outside §3.2's 32 bits.
    wide,
};

/// One line of `air.xfail`: `<opcode> <kind> [<ulps>] <reason>`.
const Allowed = struct {
    tag: Inst.Tag,
    kind: Kind,
    ulps: u64 = 0,
    line: u32,
    seen: u64 = 0,
    max_ulps: u64 = 0,
};

const Outcome = union(enum) { agree, differ: struct { kind: Kind, ulps: u64 = 0 }, mismatch };

/// One opcode's Air body and what it was compared over.
const Probe = struct {
    tag: Inst.Tag,
    old: opcode.Opcode,
    scalar: Air.Scalar,
    arity: u8,
    air: Air,
};

const Report = struct {
    allowed: []Allowed,
    compared: u64 = 0,
    failures: u64 = 0,

    /// Records one comparison; prints the first examples of a failure.
    fn record(rep: *Report, p: *const Probe, args: []const Value, want: ?Const, got: interp.Error!Value, printed: *u32) void {
        rep.compared += 1;
        const out = classify(want, got, args);
        const kind = switch (out) {
            .agree => return,
            .mismatch => null,
            .differ => |d| d.kind,
        };
        if (kind) |k| for (rep.allowed) |*a| {
            if (a.tag != p.tag or a.kind != k) continue;
            if (k == .ulp and out.differ.ulps > a.ulps) break;
            a.seen += 1;
            a.max_ulps = @max(a.max_ulps, out.differ.ulps);
            return;
        };
        rep.failures += 1;
        if (printed.* >= examples_max) return;
        printed.* += 1;
        std.debug.print("diff-air: {s} {s}: fold {any} interp {any} at", .{ @tagName(p.tag), if (kind) |k| @tagName(k) else "mismatch", want, got });
        for (args) |a| switch (a) {
            .real => |x| std.debug.print(" {e}", .{x}),
            .int => |x| std.debug.print(" {d}", .{x}),
            .array => unreachable, // the sweep makes scalars only
        };
        if (want) |w| if (w == .real) std.debug.print(" (fold {e})", .{w.real});
        if (got) |g| if (g == .real) std.debug.print(" (interp {e})", .{g.real}) else {} else |_| {}
        std.debug.print("\n", .{});
    }
};

/// The real specials: ±0, ±inf, NaN, the smallest subnormal, the largest
/// double, ±1, the integer limits as reals, and §4.2.1.1's rounding ties.
const real_specials = [_]f64{
    0.0,                     -0.0,                       std.math.inf(f64),           -std.math.inf(f64),
    std.math.nan(f64),       std.math.floatTrueMin(f64), -std.math.floatTrueMin(f64), std.math.floatMax(f64),
    -std.math.floatMax(f64), 1.0,                        -1.0,                        2147483647.0,
    -2147483648.0,           9223372036854775807.0,      -9223372036854775808.0,      2.5,
    -2.5,                    0.5,
};

/// The integer specials: 0, ±1, the 32- and 64-bit limits, and the shift
/// counts at §3.2's and the carrier's edges.
const int_specials = [_]i64{ 0, 1, -1, std.math.minInt(i32), std.math.maxInt(i32), std.math.minInt(i64), std.math.maxInt(i64), 2, 31, 32, 63, 64 };

// ---- private ----

/// Returns the Air body `arg0 [, arg1]; op; ret`.
fn build(gpa: Allocator, tag: Inst.Tag, scalar: Air.Scalar, arity: u8) !Air {
    var b = try Air.Builder.init(gpa);
    defer b.deinit(gpa);
    const ty: InternPool.Index = if (scalar == .real) .real_type else .integer_type;
    var body: [4]Inst.Index = undefined;
    for (0..arity) |k| body[k] = try b.addInst(gpa, .{ .tag = .arg, .data = .{ .ty_index = .{ .ty = ty, .index = @intCast(k) } } });
    const a0: Inst.Ref = .fromIndex(body[0]);
    body[arity] = if (arity == 1) try b.addUnOp(gpa, tag, a0) else try b.addBinOp(gpa, tag, a0, .fromIndex(body[1]));
    body[arity + 1] = try b.addUnOp(gpa, .ret, .fromIndex(body[arity]));
    return b.finish(gpa, body[0 .. arity + 2]);
}

/// Runs `p` over the specials (every pair, for a binary tag) and the
/// random operand sets.
fn sweep(rep: *Report, p: *const Probe, ip: *const InternPool, rnd: std.Random) !void {
    var buf: [4096]u8 = undefined;
    var printed: u32 = 0;
    const n_special: usize = if (p.scalar == .real) real_specials.len else int_specials.len;
    const pairs = if (p.arity == 1) n_special else n_special * n_special;
    for (0..pairs + random_per_opcode) |k| {
        var args: [2]Value = undefined;
        for (args[0..p.arity], 0..) |*a, j| {
            const special = if (j == 0) k % n_special else k / n_special;
            a.* = if (k < pairs)
                (if (p.scalar == .real) Value{ .real = real_specials[special] } else Value{ .int = int_specials[special] })
            else if (p.scalar == .real) Value{ .real = randomReal(rnd) } else Value{ .int = randomInt(rnd) };
        }
        var consts: [2]Const = undefined;
        for (args[0..p.arity], consts[0..p.arity]) |a, *c| c.* = switch (a) {
            .int => |v| .{ .int = v },
            .real => |v| .{ .real = v },
            .array => unreachable, // the sweep makes scalars only
        };
        const want = opcode.fold(p.old, consts[0..p.arity]);
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const got = interp.run(fba.allocator(), p.air, ip, .{ .args = args[0..p.arity], .loop_cap = 0 });
        rep.record(p, args[0..p.arity], want, got, &printed);
    }
}

/// A real from one of four regions: any bit pattern, [-10, 10], [-1.5,
/// 1.5] (the Table 4-15 domains' edges), or a small integer.
fn randomReal(rnd: std.Random) f64 {
    return switch (rnd.uintLessThan(u8, 4)) {
        0 => @bitCast(rnd.int(u64)),
        1 => (rnd.float(f64) - 0.5) * 20,
        2 => (rnd.float(f64) - 0.5) * 3,
        else => @floatFromInt(rnd.intRangeAtMost(i8, -5, 5)),
    };
}

/// An integer from one of three regions: a small one (shift counts
/// included), any 32-bit one, any 64-bit one.
fn randomInt(rnd: std.Random) i64 {
    return switch (rnd.uintLessThan(u8, 3)) {
        0 => rnd.intRangeAtMost(i64, -70, 70),
        1 => rnd.int(i32),
        else => rnd.int(i64),
    };
}

fn classify(want: ?Const, got: interp.Error!Value, args: []const Value) Outcome {
    const g = got catch |e| return if (e == error.NoValue and want == null) .agree else .mismatch;
    const w = want orelse return .{ .differ = .{ .kind = .declines } };
    switch (w) {
        .int => |wi| {
            if (g != .int) return .mismatch;
            if (g.int == wi) return .agree;
            for (args) |a| if (a == .int and std.math.cast(i32, a.int) == null) return .{ .differ = .{ .kind = .wide } };
            return .mismatch;
        },
        .real => |wr| {
            if (g != .real) return .mismatch;
            const gr = g.real;
            if (std.math.isNan(wr) and std.math.isNan(gr)) return .agree;
            if (@as(u64, @bitCast(wr)) == @as(u64, @bitCast(gr))) return .agree;
            if (std.math.isNan(wr) or std.math.isNan(gr)) return .mismatch;
            if (std.math.signbit(wr) != std.math.signbit(gr)) return .mismatch;
            const d = @abs(@as(i128, @as(i64, @bitCast(wr))) - @as(i64, @bitCast(gr)));
            return .{ .differ = .{ .kind = .ulp, .ulps = @intCast(d) } };
        },
        .str => return .mismatch,
    }
}

/// Parses `air.xfail`: `#` comments, blank lines, and
/// `<opcode> <kind> [<ulps>] <reason>` lines with a non-empty reason.
fn parseXfail(gpa: Allocator, text: []const u8) ![]Allowed {
    var list: std.ArrayList(Allowed) = .empty;
    errdefer list.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: u32 = 0;
    while (lines.next()) |line| {
        line_no += 1;
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        var words = std.mem.tokenizeAny(u8, t, " \t");
        const tag = std.meta.stringToEnum(Inst.Tag, words.next().?) orelse return error.XfailOpcode;
        const kind = std.meta.stringToEnum(Kind, words.next() orelse return error.XfailKind) orelse return error.XfailKind;
        const ulps: u64 = if (kind == .ulp) try std.fmt.parseInt(u64, words.next() orelse return error.XfailUlps, 10) else 0;
        if (words.rest().len == 0) return error.XfailReason;
        try list.append(gpa, .{ .tag = tag, .kind = kind, .ulps = ulps, .line = line_no });
    }
    return list.toOwnedSlice(gpa);
}

/// Returns `ret select(c, x, y)` or `ret block { cond_br(c, br x, br y) }`
/// over args c (integer), x and y (real).
fn selectOrBranch(gpa: Allocator, form: Inst.Tag) !Air {
    var b = try Air.Builder.init(gpa);
    defer b.deinit(gpa);
    const c = try b.addInst(gpa, .{ .tag = .arg, .data = .{ .ty_index = .{ .ty = .integer_type, .index = 0 } } });
    const x = try b.addInst(gpa, .{ .tag = .arg, .data = .{ .ty_index = .{ .ty = .real_type, .index = 1 } } });
    const y = try b.addInst(gpa, .{ .tag = .arg, .data = .{ .ty_index = .{ .ty = .real_type, .index = 2 } } });
    const v = if (form == .select) try b.addInst(gpa, .{ .tag = .select, .data = .{ .pl_op = .{
        .operand = .fromIndex(c),
        .payload = try b.addExtra(gpa, Air.Bin{ .lhs = .fromIndex(x), .rhs = .fromIndex(y) }),
    } } }) else blk: {
        const v = try b.addInst(gpa, .{ .tag = .block, .data = undefined });
        const cb = try b.addCondBr(gpa, .fromIndex(c), &.{try brTo(&b, gpa, v, .fromIndex(x))}, &.{try brTo(&b, gpa, v, .fromIndex(y))});
        try b.setBody(gpa, v, .real_type, &.{cb});
        break :blk v;
    };
    const ret = try b.addUnOp(gpa, .ret, .fromIndex(v));
    return b.finish(gpa, &.{ c, x, y, v, ret });
}

fn brTo(b: *Air.Builder, gpa: Allocator, block: Inst.Index, operand: Inst.Ref) !Inst.Index {
    return b.addInst(gpa, .{ .tag = .br, .data = .{ .br = .{ .block_inst = block, .operand = operand } } });
}

test "diff-air: every folding opcode, the interpreter against opcode.fold" {
    const gpa = std.testing.allocator;
    var ip = try InternPool.init(gpa);
    defer ip.deinit(gpa);
    const allowed = try parseXfail(gpa, @embedFile("air.xfail"));
    defer gpa.free(allowed);
    var rep: Report = .{ .allowed = allowed };
    var opcodes: u32 = 0;
    var prng = std.Random.DefaultPrng.init(0xA1_2_F01D);
    const rnd = prng.random();
    for (std.enums.values(opcode.Opcode)) |old| {
        if (opcode.table.get(old).fold == .none) continue;
        const tag = std.meta.stringToEnum(Inst.Tag, @tagName(old)) orelse {
            std.debug.print("diff-air: old opcode {s} has no Air tag\n", .{@tagName(old)});
            rep.failures += 1;
            continue;
        };
        const info = Air.tag_info.getPtrConst(tag);
        const arity: u8 = if (info.class == .un_op) 1 else 2;
        // `opt_barrier` and `dstop` take either type: sweep both.
        const scalars: []const Air.Scalar = if (info.operand) |s| &.{s} else &.{ .real, .int };
        for (scalars) |scalar| {
            var p: Probe = .{ .tag = tag, .old = old, .scalar = scalar, .arity = arity, .air = try build(gpa, tag, scalar, arity) };
            defer p.air.deinit(gpa);
            try Air.Verify.check(gpa, p.air, &ip);
            try sweep(&rep, &p, &ip, rnd);
            opcodes += 1;
        }
    }
    std.debug.print("diff-air: {d} opcode sweeps, {d} operand sets compared, {d} failures\n", .{ opcodes, rep.compared, rep.failures });
    for (rep.allowed) |a| {
        std.debug.print("diff-air: xfail line {d} ({s} {s}): {d} operand sets, max {d} ulps\n", .{ a.line, @tagName(a.tag), @tagName(a.kind), a.seen, a.max_ulps });
        if (a.seen == 0) {
            std.debug.print("diff-air: air.xfail line {d} ({s} {s}) never differed: an unexpected pass, remove the line\n", .{ a.line, @tagName(a.tag), @tagName(a.kind) });
            rep.failures += 1;
        }
    }
    try std.testing.expectEqual(@as(u64, 0), rep.failures);
}

test "control: a loop over two slots sums 1..n" {
    // Oracle: n(n+1)/2, exact in f64 for these n.
    //   s = 0.0; i = 0; block { loop { i = i + 1; if (i <= n) { s = s + if_cast(i); repeat } else br } }; ret s
    const gpa = std.testing.allocator;
    var ip = try InternPool.init(gpa);
    defer ip.deinit(gpa);
    var b = try Air.Builder.init(gpa);
    defer b.deinit(gpa);
    const n = try b.addInst(gpa, .{ .tag = .arg, .data = .{ .ty_index = .{ .ty = .integer_type, .index = 0 } } });
    const s = try b.addInst(gpa, .{ .tag = .alloc, .data = .{ .ty = .real_type } });
    const i = try b.addInst(gpa, .{ .tag = .alloc, .data = .{ .ty = .integer_type } });
    const out = try b.addInst(gpa, .{ .tag = .block, .data = undefined });
    const lp = try b.addInst(gpa, .{ .tag = .loop, .data = undefined });
    const i_old = try b.addUnOp(gpa, .load, .fromIndex(i));
    const i_new = try b.addBinOp(gpa, .iadd, .fromIndex(i_old), .fromIntern(.one));
    const set_i = try b.addBinOp(gpa, .assign, .fromIndex(i), .fromIndex(i_new));
    const go = try b.addBinOp(gpa, .ile, .fromIndex(i_new), .fromIndex(n));
    const s0 = try b.addUnOp(gpa, .load, .fromIndex(s));
    const ir = try b.addUnOp(gpa, .if_cast, .fromIndex(i_new));
    const s1 = try b.addBinOp(gpa, .fadd, .fromIndex(s0), .fromIndex(ir));
    const set_s = try b.addBinOp(gpa, .assign, .fromIndex(s), .fromIndex(s1));
    const again = try b.addInst(gpa, .{ .tag = .repeat, .data = .{ .repeat = .{ .loop_inst = lp } } });
    const done = try b.addInst(gpa, .{ .tag = .br, .data = .{ .br = .{ .block_inst = out, .operand = .none } } });
    const cb = try b.addCondBr(gpa, .fromIndex(go), &.{ s0, ir, s1, set_s, again }, &.{done});
    try b.setBody(gpa, lp, .none, &.{ i_old, i_new, set_i, go, cb });
    try b.setBody(gpa, out, .none, &.{lp});
    const r = try b.addUnOp(gpa, .load, .fromIndex(s));
    const ret = try b.addUnOp(gpa, .ret, .fromIndex(r));
    var air = try b.finish(gpa, &.{ n, s, i, out, r, ret });
    defer air.deinit(gpa);
    try Air.Verify.check(gpa, air, &ip);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for ([_]i64{ 0, 1, 2, 3, 10, 99, 1000, -5 }) |k| {
        const got = try interp.run(arena.allocator(), air, &ip, .{ .args = &.{.{ .int = k }}, .loop_cap = 1001 });
        const want: f64 = if (k < 0) 0 else @floatFromInt(@divExact(k * (k + 1), 2));
        try std.testing.expectEqual(want, got.real);
    }
}

test "control: nested cond_br with block results against an if chain" {
    // Oracle: the same piecewise function as a Zig `if` chain, over seeded
    // random x and the specials:
    //   x < 0 ? (x < -1 ? -2 : -1) : (x > 1 ? 2 : (x == 0 ? 0 : 1)), NaN -> 1
    const gpa = std.testing.allocator;
    var ip = try InternPool.init(gpa);
    defer ip.deinit(gpa);
    var b = try Air.Builder.init(gpa);
    defer b.deinit(gpa);
    const two: Inst.Ref = .fromIntern(.two_real);
    const neg_two: Inst.Ref = .fromIntern(try ip.get(gpa, .{ .float = -2.0 }));
    const x = try b.addInst(gpa, .{ .tag = .arg, .data = .{ .ty_index = .{ .ty = .real_type, .index = 0 } } });
    const outer = try b.addInst(gpa, .{ .tag = .block, .data = undefined });
    const neg = try b.addBinOp(gpa, .flt, .fromIndex(x), .fromIntern(.zero_real));
    // then: x < -1 ? -2 : -1
    const lt1 = try b.addBinOp(gpa, .flt, .fromIndex(x), .fromIntern(.neg_one_real));
    const t_cb = try b.addCondBr(gpa, .fromIndex(lt1), &.{try brTo(&b, gpa, outer, neg_two)}, &.{try brTo(&b, gpa, outer, .fromIntern(.neg_one_real))});
    // else: x > 1 ? 2 : (x == 0 ? 0 : 1), the inner choice its own block
    const gt1 = try b.addBinOp(gpa, .fgt, .fromIndex(x), .fromIntern(.one_real));
    const inner = try b.addInst(gpa, .{ .tag = .block, .data = undefined });
    const is0 = try b.addBinOp(gpa, .feq, .fromIndex(x), .fromIntern(.zero_real));
    const i_cb = try b.addCondBr(gpa, .fromIndex(is0), &.{try brTo(&b, gpa, inner, .fromIntern(.zero_real))}, &.{try brTo(&b, gpa, inner, .fromIntern(.one_real))});
    try b.setBody(gpa, inner, .real_type, &.{ is0, i_cb });
    const e_cb = try b.addCondBr(gpa, .fromIndex(gt1), &.{try brTo(&b, gpa, outer, two)}, &.{ inner, try brTo(&b, gpa, outer, .fromIndex(inner)) });
    const o_cb = try b.addCondBr(gpa, .fromIndex(neg), &.{ lt1, t_cb }, &.{ gt1, e_cb });
    try b.setBody(gpa, outer, .real_type, &.{ neg, o_cb });
    const ret = try b.addUnOp(gpa, .ret, .fromIndex(outer));
    var air = try b.finish(gpa, &.{ x, outer, ret });
    defer air.deinit(gpa);
    try Air.Verify.check(gpa, air, &ip);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(0xC0_4D);
    for (0..20_000) |k| {
        const xv: f64 = if (k < real_specials.len) real_specials[k] else (prng.random().float(f64) - 0.5) * 6;
        const want: f64 = if (xv < 0) (if (xv < -1) -2 else -1) else if (xv > 1) 2 else if (xv == 0) 0 else 1;
        const got = try interp.run(arena.allocator(), air, &ip, .{ .args = &.{.{ .real = xv }}, .loop_cap = 0 });
        try std.testing.expectEqual(want, got.real);
    }
}

test "control: select and block + cond_br agree bit for bit (metamorphic)" {
    // `select(c, a, b)` and `block { cond_br(c, br a, br b) }` are the same
    // value (§4.2.12 / Legalize's if-conversion): same bits, NaN payloads
    // and -0.0 included.
    const gpa = std.testing.allocator;
    var ip = try InternPool.init(gpa);
    defer ip.deinit(gpa);
    var air_sel = try selectOrBranch(gpa, .select);
    defer air_sel.deinit(gpa);
    var air_br = try selectOrBranch(gpa, .cond_br);
    defer air_br.deinit(gpa);
    try Air.Verify.check(gpa, air_sel, &ip);
    try Air.Verify.check(gpa, air_br, &ip);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(0x5E1EC7);
    const rnd = prng.random();
    for (0..20_000) |_| {
        const args = [_]Value{ .{ .int = randomInt(rnd) }, .{ .real = randomReal(rnd) }, .{ .real = randomReal(rnd) } };
        const in: interp.Inputs = .{ .args = &args, .loop_cap = 0 };
        const p = try interp.run(arena.allocator(), air_sel, &ip, in);
        const q = try interp.run(arena.allocator(), air_br, &ip, in);
        try std.testing.expectEqual(@as(u64, @bitCast(p.real)), @as(u64, @bitCast(q.real)));
        const want = if (args[0].int != 0) args[1].real else args[2].real;
        try std.testing.expectEqual(@as(u64, @bitCast(want)), @as(u64, @bitCast(p.real)));
    }
}
