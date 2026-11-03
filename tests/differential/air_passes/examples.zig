//! The old `src/prove` tests as hand-built structured Air: the verdict's
//! cases (`proof.zig`, `domain.zig`, `verdict.zig`, `seed.zig`), if-
//! conversion's shapes (`ifconv.zig`) and the setup tier's (`invariance.zig`,
//! `timepoint.zig`, `held.zig`). Each expectation is the LRM's answer
//! derived by hand, named beside it; the Legalize ones also run `interp`
//! before and after.
//! Cites: VAMS-2023 §3.2, §3.4.2, §4.2.3, §4.2.4, §4.2.12, §4.3.1, §4.3.2,
//! §4.4, §5.2.1, §5.10.2.
//!
//! Contents: none public; tests only.

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const Allocator = std.mem.Allocator;
const Air = @import("air");
const InternPool = @import("intern_pool");
const Diag = @import("vams").Diag;
const Interval = Air.Interval;
const Float = Air.Float;
const Legalize = Air.Legalize;
const Setup = Air.Setup;
const interp = Air.interp;
const Inst = Air.Inst;

const testing = std.testing;
const inf = math.inf(f64);

/// A body under construction: the builder, the pool, and the main body.
const T = struct {
    gpa: Allocator,
    ip: InternPool,
    b: Air.Builder,
    main: std.ArrayList(Inst.Index) = .empty,

    fn init(gpa: Allocator) !T {
        return .{ .gpa = gpa, .ip = try .init(gpa), .b = try .init(gpa) };
    }
    fn deinit(t: *T) void {
        t.main.deinit(t.gpa);
        t.b.deinit(t.gpa);
        t.ip.deinit(t.gpa);
    }
    fn add(t: *T, body: *std.ArrayList(Inst.Index), inst: Inst) !Inst.Ref {
        const i = try t.b.addInst(t.gpa, inst);
        try body.append(t.gpa, i);
        return .fromIndex(i);
    }
    fn arg(t: *T, ty: InternPool.Index, index: u32) !Inst.Ref {
        return t.add(&t.main, .{ .tag = .arg, .data = .{ .ty_index = .{ .ty = ty, .index = index } } });
    }
    fn probe(t: *T, body: *std.ArrayList(Inst.Index), index: u32) !Inst.Ref {
        return t.add(body, .{ .tag = .probe, .data = .{ .ty_index = .{ .ty = .real_type, .index = index } } });
    }
    fn un(t: *T, body: *std.ArrayList(Inst.Index), tag: Inst.Tag, a: Inst.Ref) !Inst.Ref {
        return t.add(body, .{ .tag = tag, .data = .{ .un_op = a } });
    }
    fn bin(t: *T, body: *std.ArrayList(Inst.Index), tag: Inst.Tag, a: Inst.Ref, b: Inst.Ref) !Inst.Ref {
        return t.add(body, .{ .tag = tag, .data = .{ .bin_op = .{ .lhs = a, .rhs = b } } });
    }
    fn real(t: *T, x: f64) !Inst.Ref {
        return .fromIntern(try t.ip.get(t.gpa, .{ .float = x }));
    }
    fn call(t: *T, body: *std.ArrayList(Inst.Index), callee: u32, ty: InternPool.Index) !Inst.Ref {
        const payload = try t.b.addExtra(t.gpa, Air.Call{ .callee = callee, .args_len = 0 });
        return t.add(body, .{ .tag = .call, .data = .{ .ty_pl = .{ .ty = ty, .payload = payload } } });
    }
    /// `block(ty) { cond_br(c, then ++ [br a], else ++ [br b]) }` appended
    /// to `body`; `a`/`b` are `.none` for a block with no result.
    fn ifElse(t: *T, body: *std.ArrayList(Inst.Index), ty: InternPool.Index, c: Inst.Ref, then: *std.ArrayList(Inst.Index), a: Inst.Ref, els: *std.ArrayList(Inst.Index), b: Inst.Ref) !Inst.Ref {
        const blk = try t.b.addInst(t.gpa, .{ .tag = .block, .data = undefined });
        _ = try t.add(then, .{ .tag = .br, .data = .{ .br = .{ .block_inst = blk, .operand = a } } });
        _ = try t.add(els, .{ .tag = .br, .data = .{ .br = .{ .block_inst = blk, .operand = b } } });
        const cb = try t.b.addCondBr(t.gpa, c, then.items, els.items);
        try t.b.setBody(t.gpa, blk, ty, &.{cb});
        try body.append(t.gpa, blk);
        return .fromIndex(blk);
    }
    /// Ends the main body with `ret r`; the `Air` is the caller's.
    fn finish(t: *T, r: Inst.Ref) !Air {
        _ = try t.un(&t.main, .ret, r);
        const air = try t.b.finish(t.gpa, t.main.items);
        try testing.expectEqual(@as(?Air.Verify.Violation, null), try Air.Verify.verify(t.gpa, air, &t.ip));
        return air;
    }
};

/// What one `Float.analyze` reported: its codes, and the verdict.
const Outcome = struct {
    f: Float,
    codes: [8]?Diag.Code = @splat(null),

    fn has(o: Outcome, c: Diag.Code) bool {
        return std.mem.findScalar(?Diag.Code, &o.codes, c) != null;
    }
};

// ---- private ----

fn analyze(t: *T, air: Air, in: Float.Input) !Outcome {
    var wip: Diag.Wip = .init(t.gpa);
    defer wip.deinit();
    var o: Outcome = .{ .f = try Float.analyze(t.gpa, air, &t.ip, in, &wip) };
    var d = try wip.toOwnedBundle();
    defer d.deinit(t.gpa);
    for (d.messages(), 0..) |m, k| {
        if (k < o.codes.len) o.codes[k] = d.message(m).tag.code;
    }
    return o;
}

/// `y = ln(x)`, `x` the first parameter with `ranges`; the root reads `y`.
fn lnOf(gpa: Allocator, ranges: []const Interval.Range) !struct { t: T, air: Air, y: Inst.Ref, o: Outcome } {
    var t = try T.init(gpa);
    const x = try t.arg(.real_type, 0);
    const y = try t.un(&t.main, .ln, x);
    const air = try t.finish(y);
    const o = try analyze(&t, air, .{ .params = &.{.{ .ranges = ranges, .name = "x" }}, .roots = &.{.{ .refs = &.{y} }} });
    return .{ .t = t, .air = air, .y = y, .o = o };
}

/// Whether `blk`'s body (after a conversion) holds no `cond_br`.
fn straight(air: Air, blk: Inst.Ref) bool {
    const x = air.extraData(Air.Block, air.instructions.items(.data)[@backingInt(blk.toIndex().?)].ty_pl.payload);
    for (air.body(x.end, x.data.body_len)) |i| if (air.instructions.items(.tag)[@backingInt(i)] == .cond_br) return false;
    return true;
}

/// Runs `before` and `after` with the first parameter and probe at each of
/// `xs` and expects the same bits.
fn sameRuns(t: *T, before: Air, after: Air, xs: []const f64) !void {
    var arena: std.heap.ArenaAllocator = .init(t.gpa);
    defer arena.deinit();
    for (xs) |x| {
        const in: interp.Inputs = .{ .args = &.{.{ .real = x }}, .probes = &.{x}, .loop_cap = 10 };
        const want = (try interp.run(arena.allocator(), before, &t.ip, in)).real;
        const got = (try interp.run(arena.allocator(), after, &t.ip, in)).real;
        try testing.expect(want == got or (math.isNan(want) and math.isNan(got)));
    }
}

fn at(ref: Inst.Ref) usize {
    return @backingInt(ref.toIndex().?);
}

test "Float: ln(x) proves for x from (0:inf), errs for x from [-10:-1], stays open unranged" {
    // Table 4-15 ln: x > 0. Proven keeps `.optimized`; provably outside is
    // E0602 and rates every root `.strict`; straddling is accepted, `.strict`, W0650.
    const gpa = testing.allocator;
    const cases = [_]struct { ranges: []const Interval.Range, mode: Float.Mode, dom: Float.Domain, code: ?Diag.Code }{
        .{ .ranges = &.{.{ .kind = .from, .lo = 0, .hi = inf, .lo_inclusive = false, .hi_inclusive = false }}, .mode = .optimized, .dom = .proven, .code = null },
        .{ .ranges = &.{.{ .kind = .from, .lo = -10, .hi = -1 }}, .mode = .strict, .dom = .violated, .code = .E0602 },
        .{ .ranges = &.{}, .mode = .strict, .dom = .open, .code = .W0650 },
    };
    for (cases) |c| {
        var r = try lnOf(gpa, c.ranges);
        defer r.t.deinit();
        defer r.air.deinit(gpa);
        defer r.o.f.deinit(gpa);
        try testing.expectEqual(c.mode, r.o.f.verdict.modes[0]);
        try testing.expectEqual(c.dom, r.o.f.domain[@backingInt(r.y.toIndex().?)]);
        if (c.code) |code| try testing.expect(r.o.has(code)) else try testing.expectEqual(@as(?Diag.Code, null), r.o.codes[0]);
    }
}

test "Float: a guard on V(p,n) proves ln of a recomputed V(p,n)" {
    // if (V(p,n) > 0) ln(V(p,n)): lowering computes a fresh `fsub` per
    // V(p,n), so only the congruence class carries the fact. Probes lie in
    // the host's bound, so `-` keeps them finite.
    const gpa = testing.allocator;
    var t = try T.init(gpa);
    defer t.deinit();
    const p0 = try t.probe(&t.main, 0);
    const p1 = try t.probe(&t.main, 1);
    const v = try t.bin(&t.main, .fsub, p0, p1);
    const c = try t.bin(&t.main, .fgt, v, try t.real(0));
    var then: std.ArrayList(Inst.Index) = .empty;
    defer then.deinit(gpa);
    var els: std.ArrayList(Inst.Index) = .empty;
    defer els.deinit(gpa);
    const v2 = try t.bin(&then, .fsub, p0, p1);
    const l = try t.un(&then, .ln, v2);
    const blk = try t.ifElse(&t.main, .real_type, c, &then, l, &els, try t.real(0));
    var air = try t.finish(blk);
    defer air.deinit(gpa);
    var o = try analyze(&t, air, .{ .roots = &.{.{ .refs = &.{blk} }}, .unknown_bound = 10 });
    defer o.f.deinit(gpa);
    try testing.expectEqual(Float.Domain.proven, o.f.domain[@backingInt(l.toIndex().?)]);
    try testing.expectEqual(Float.Mode.optimized, o.f.verdict.modes[0]);
}

test "Float: a guard on a variable reaches its next read; a write in between cuts it" {
    // s = V; if (s > 0) ln(s): two loads of one slot version share the fact.
    // s = V; c = s > 0; s = -1; if (c) ln(s): the read after the write does not.
    const gpa = testing.allocator;
    for ([_]bool{ false, true }) |cut| {
        var t = try T.init(gpa);
        defer t.deinit();
        const s = try t.add(&t.main, .{ .tag = .alloc, .data = .{ .ty = .real_type } });
        _ = try t.bin(&t.main, .assign, s, try t.probe(&t.main, 0));
        const c = try t.bin(&t.main, .fgt, try t.un(&t.main, .load, s), try t.real(0));
        if (cut) _ = try t.bin(&t.main, .assign, s, try t.real(-1));
        var then: std.ArrayList(Inst.Index) = .empty;
        defer then.deinit(gpa);
        var els: std.ArrayList(Inst.Index) = .empty;
        defer els.deinit(gpa);
        const l = try t.un(&then, .ln, try t.un(&then, .load, s));
        const blk = try t.ifElse(&t.main, .real_type, c, &then, l, &els, try t.real(0));
        var air = try t.finish(blk);
        defer air.deinit(gpa);
        var o = try analyze(&t, air, .{ .roots = &.{.{ .refs = &.{blk} }} });
        defer o.f.deinit(gpa);
        // Cut: ln(-1) is provably outside the domain on the taken arm (E0602).
        try testing.expectEqual(if (cut) Float.Domain.violated else .proven, o.f.domain[@backingInt(l.toIndex().?)]);
    }
}

test "Float: 1/R is finite for R from [1m:1M], not for R with only exclude 0, nor for an unranged R" {
    // §4.2.4 `/` by a possible zero is ±inf, not an error; the hole proves
    // the zero away, but not the overflow: 1 / 5e-324 is inf in IEEE 754
    // (the merged prover called it finite). A range bounded away from 0
    // proves both.
    const gpa = testing.allocator;
    const open_line: Interval.Range = .{ .kind = .from, .lo = -inf, .hi = inf, .lo_inclusive = false, .hi_inclusive = false };
    const cases = [_]struct { ranges: []const Interval.Range, mode: Float.Mode }{
        .{ .ranges = &.{.{ .kind = .from, .lo = 1e-3, .hi = 1e6 }}, .mode = .optimized },
        .{ .ranges = &.{ open_line, .{ .kind = .exclude, .lo = 0, .hi = 0 } }, .mode = .strict },
        .{ .ranges = &.{open_line}, .mode = .strict },
    };
    for (cases) |c| {
        var t = try T.init(gpa);
        defer t.deinit();
        const q = try t.bin(&t.main, .fdiv, try t.real(1), try t.arg(.real_type, 0));
        var air = try t.finish(q);
        defer air.deinit(gpa);
        var o = try analyze(&t, air, .{ .params = &.{.{ .ranges = c.ranges }}, .roots = &.{.{ .refs = &.{q} }} });
        defer o.f.deinit(gpa);
        try testing.expectEqual(c.mode, o.f.verdict.modes[0]);
        try testing.expectEqual(c.mode == .strict, o.has(.W0650));
    }
}

test "Float: E0601, W0653, W0651" {
    // §4.2.4: real `%` by a provably zero divisor is an error; integer `/` by
    // a maybe-zero one warns. §3.4.2: a `from` bound closed on inf warns.
    const gpa = testing.allocator;
    var t = try T.init(gpa);
    defer t.deinit();
    const x = try t.arg(.real_type, 0);
    const n = try t.arg(.integer_type, 1);
    const m = try t.bin(&t.main, .fmod, x, try t.real(0));
    const d = try t.bin(&t.main, .idiv, .fromIntern(.one), n);
    const sum = try t.bin(&t.main, .fadd, m, try t.un(&t.main, .if_cast, d));
    var air = try t.finish(sum);
    defer air.deinit(gpa);
    var o = try analyze(&t, air, .{ .params = &.{ .{ .ranges = &.{.{ .kind = .from, .lo = 0, .hi = inf }} }, .{} }, .roots = &.{.{ .refs = &.{sum} }} });
    defer o.f.deinit(gpa);
    try testing.expect(o.has(.E0601));
    try testing.expect(o.has(.W0653));
    try testing.expect(o.has(.W0651));
    try testing.expectEqual(@as(u8, 1), o.f.error_count);
    try testing.expectEqual(Float.Mode.strict, o.f.verdict.modes[0]);
}

test "Float: exp(V) is proven inside the unknown bound, and the box says which" {
    // exp overflows past 709.78: finite only over a bounded argument. The
    // proof's box is the probe's [-B, B] (the default when the host gives
    // none); past 709.78 no box proves it, and a `.strict` root has none.
    const gpa = testing.allocator;
    const cases = [_]struct { bound: ?f64, mode: Float.Mode, half: f64 }{
        .{ .bound = null, .mode = .optimized, .half = Float.default_unknown_bound },
        .{ .bound = 5, .mode = .optimized, .half = 5 },
        .{ .bound = 1e3, .mode = .strict, .half = 0 },
    };
    for (cases) |c| {
        var t = try T.init(gpa);
        defer t.deinit();
        const e = try t.un(&t.main, .exp, try t.probe(&t.main, 0));
        var air = try t.finish(e);
        defer air.deinit(gpa);
        var o = try analyze(&t, air, .{ .roots = &.{.{ .refs = &.{e} }}, .unknown_bound = c.bound });
        defer o.f.deinit(gpa);
        try testing.expectEqual(c.mode, o.f.verdict.modes[0]);
        const box = o.f.verdict.box(0);
        if (c.mode == .strict) {
            try testing.expectEqual(@as(usize, 0), box.len);
            continue;
        }
        try testing.expectEqual(@as(usize, 1), box.len);
        try testing.expectEqual(Float.Guard{ .iv = .{ .lo = -c.half, .hi = c.half }, .index = 0, .leaf = .probe }, box[0]);
        try testing.expect(box[0].admits(c.half));
        try testing.expect(!box[0].admits(math.nextAfter(f64, c.half, inf)));
        try testing.expect(!box[0].admits(math.nan(f64)));
    }
}

test "Float: an error never rests on the default bound, only on the host's" {
    // ln(V - 20): with no bound from the host, V may be 25 (§4.3.2 reports
    // only what is provably outside), so it is accepted, `.strict` (inside
    // the default box it is outside the domain) with W0650. With the host's
    // `--unknown-bound=10`, V - 20 <= -10 on every legal input: E0602.
    const gpa = testing.allocator;
    for ([_]?f64{ null, 10 }) |bound| {
        var t = try T.init(gpa);
        defer t.deinit();
        const l = try t.un(&t.main, .ln, try t.bin(&t.main, .fsub, try t.probe(&t.main, 0), try t.real(20)));
        var air = try t.finish(l);
        defer air.deinit(gpa);
        var o = try analyze(&t, air, .{ .roots = &.{.{ .refs = &.{l} }}, .unknown_bound = bound });
        defer o.f.deinit(gpa);
        try testing.expectEqual(Float.Mode.strict, o.f.verdict.modes[0]);
        try testing.expectEqual(bound != null, o.has(.E0602));
        try testing.expectEqual(bound == null, o.has(.W0650));
    }
}

test "Float: a loop widens its counter and keeps its sign; a constant-false arm reports nothing" {
    // s = 0; k = 0; while (k < 3) { s = s + 1; k = k + 1 }; ln(s + 1): s >= 0
    // after widening, so s + 1 >= 1 > 0. Widening pushes s's upper end to
    // inf (nothing ties s to the trip count), so s + 1 is not provably
    // finite and the root is `.strict`. Then `if (0 > 1) ln(-1)`: §4.2.3, the
    // untaken arm's violation is not reported.
    const gpa = testing.allocator;
    var t = try T.init(gpa);
    defer t.deinit();
    const s = try t.add(&t.main, .{ .tag = .alloc, .data = .{ .ty = .real_type } });
    const k = try t.add(&t.main, .{ .tag = .alloc, .data = .{ .ty = .integer_type } });
    const out = try t.b.addInst(gpa, .{ .tag = .block, .data = undefined });
    const lp = try t.b.addInst(gpa, .{ .tag = .loop, .data = undefined });
    var head: std.ArrayList(Inst.Index) = .empty;
    defer head.deinit(gpa);
    var body: std.ArrayList(Inst.Index) = .empty;
    defer body.deinit(gpa);
    const k0 = try t.un(&head, .load, k);
    const go = try t.bin(&head, .ilt, k0, .fromIntern(try t.ip.get(gpa, .{ .int = .{ .ty = .integer_type, .storage = .{ .small = 3 } } })));
    _ = try t.bin(&body, .assign, s, try t.bin(&body, .fadd, try t.un(&body, .load, s), try t.real(1)));
    _ = try t.bin(&body, .assign, k, try t.bin(&body, .iadd, k0, .fromIntern(.one)));
    _ = try t.add(&body, .{ .tag = .repeat, .data = .{ .repeat = .{ .loop_inst = lp } } });
    const leave = try t.b.addInst(gpa, .{ .tag = .br, .data = .{ .br = .{ .block_inst = out, .operand = .none } } });
    try head.append(gpa, try t.b.addCondBr(gpa, go, body.items, &.{leave}));
    try t.b.setBody(gpa, lp, .none, head.items);
    try t.b.setBody(gpa, out, .none, &.{lp});
    try t.main.append(gpa, out);
    const l = try t.un(&t.main, .ln, try t.bin(&t.main, .fadd, try t.un(&t.main, .load, s), try t.real(1)));
    var then: std.ArrayList(Inst.Index) = .empty;
    defer then.deinit(gpa);
    var els: std.ArrayList(Inst.Index) = .empty;
    defer els.deinit(gpa);
    const bad = try t.un(&then, .ln, try t.real(-1));
    const never = try t.ifElse(&t.main, .real_type, try t.bin(&t.main, .fgt, try t.real(0), try t.real(1)), &then, bad, &els, l);
    var air = try t.finish(never);
    defer air.deinit(gpa);
    var o = try analyze(&t, air, .{ .roots = &.{.{ .refs = &.{l} }} });
    defer o.f.deinit(gpa);
    try testing.expectEqual(Float.Domain.proven, o.f.domain[@backingInt(l.toIndex().?)]);
    try testing.expect(o.f.iv[@backingInt(l.toIndex().?)].ge(0));
    try testing.expectEqual(@as(u8, 0), o.f.error_count);
    try testing.expectEqual(Float.Mode.strict, o.f.verdict.modes[0]);
}

test "Legalize: a diamond's result becomes a select, a one-armed write an assign of one" {
    // if (x > 0) r = x + 1; else r = x;   if (x > 0) s = 2;   ret r + s
    const gpa = testing.allocator;
    var t = try T.init(gpa);
    defer t.deinit();
    const x = try t.arg(.real_type, 0);
    const c = try t.bin(&t.main, .fgt, x, try t.real(0));
    var then: std.ArrayList(Inst.Index) = .empty;
    defer then.deinit(gpa);
    var els: std.ArrayList(Inst.Index) = .empty;
    defer els.deinit(gpa);
    const a = try t.bin(&then, .fadd, x, try t.real(1));
    const r = try t.ifElse(&t.main, .real_type, c, &then, a, &els, x);
    const s = try t.add(&t.main, .{ .tag = .alloc, .data = .{ .ty = .real_type } });
    var then2: std.ArrayList(Inst.Index) = .empty;
    defer then2.deinit(gpa);
    var els2: std.ArrayList(Inst.Index) = .empty;
    defer els2.deinit(gpa);
    _ = try t.bin(&then2, .assign, s, try t.real(2));
    const w = try t.ifElse(&t.main, .none, c, &then2, .none, &els2, .none);
    var air = try t.finish(try t.bin(&t.main, .fadd, r, try t.un(&t.main, .load, s)));
    defer air.deinit(gpa);
    var out = try Legalize.run(gpa, air, &t.ip, .{});
    defer out.deinit(gpa);
    try testing.expectEqual(@as(u32, 2), out.converted);
    try testing.expect(straight(out.air, r));
    try testing.expect(straight(out.air, w));
    try sameRuns(&t, air, out.air, &.{ -1, 0, 1, 2 });
}

test "Legalize: .pure keeps ln in an arm, .speculate moves it under a guard" {
    // if (V > 0) ln(V) else 0, V a probe: §4.2.12 before the proof the arm is
    // the guard; after it the guard row carries (cond, then).
    const gpa = testing.allocator;
    var t = try T.init(gpa);
    defer t.deinit();
    const v = try t.probe(&t.main, 0);
    const c = try t.bin(&t.main, .fgt, v, try t.real(0));
    var then: std.ArrayList(Inst.Index) = .empty;
    defer then.deinit(gpa);
    var els: std.ArrayList(Inst.Index) = .empty;
    defer els.deinit(gpa);
    const l = try t.un(&then, .ln, v);
    const r = try t.ifElse(&t.main, .real_type, c, &then, l, &els, try t.real(0));
    var air = try t.finish(r);
    defer air.deinit(gpa);
    var pure = try Legalize.run(gpa, air, &t.ip, .{ .mode = .pure });
    defer pure.deinit(gpa);
    try testing.expectEqual(@as(u32, 0), pure.converted);
    var spec = try Legalize.run(gpa, air, &t.ip, .{ .mode = .speculate });
    defer spec.deinit(gpa);
    try testing.expectEqual(@as(u32, 1), spec.converted);
    try testing.expectEqualSlices(Legalize.Guard, &.{.{ .inst = l.toIndex().?, .cond = c, .taken = true }}, spec.guards);
    try sameRuns(&t, air, spec.air, &.{ -1, 0, 2 });
}

test "Legalize: a card-only condition and the first-evaluation flag keep their branches" {
    // .speculate keeps `if (p > 0)` over a parameter (every evaluation takes
    // one arm); both modes keep a branch on §5.2.1's first-evaluation flag.
    const gpa = testing.allocator;
    for ([_]bool{ false, true }) |flag| {
        var t = try T.init(gpa);
        defer t.deinit();
        const p = try t.arg(.real_type, 0);
        const c = if (flag) try t.call(&t.main, 0, .integer_type) else try t.bin(&t.main, .fgt, p, try t.real(0));
        var then: std.ArrayList(Inst.Index) = .empty;
        defer then.deinit(gpa);
        var els: std.ArrayList(Inst.Index) = .empty;
        defer els.deinit(gpa);
        const a = try t.bin(&then, .fadd, p, try t.real(1));
        const r = try t.ifElse(&t.main, .real_type, c, &then, a, &els, p);
        var air = try t.finish(r);
        defer air.deinit(gpa);
        const calls = [_]Air.CallFacts{.{ .range = .unit, .first_point = true }};
        var pure = try Legalize.run(gpa, air, &t.ip, .{ .mode = .pure, .calls = &calls });
        defer pure.deinit(gpa);
        var spec = try Legalize.run(gpa, air, &t.ip, .{ .mode = .speculate, .calls = &calls });
        defer spec.deinit(gpa);
        try testing.expectEqual(@as(u32, if (flag) 0 else 1), pure.converted);
        try testing.expectEqual(@as(u32, 0), spec.converted);
    }
}

test "Legalize: an inner conversion moves whole; `p != 0` over a predicate selects on p" {
    // if ((V > 0) != 0) r = (V > 1) ? V : 1; else r = 0: both convert, and
    // the outer select reads the bare `>`.
    const gpa = testing.allocator;
    var t = try T.init(gpa);
    defer t.deinit();
    const v = try t.probe(&t.main, 0);
    const gt = try t.bin(&t.main, .fgt, v, try t.real(0));
    const c = try t.bin(&t.main, .ine, gt, .fromIntern(.zero));
    var then: std.ArrayList(Inst.Index) = .empty;
    defer then.deinit(gpa);
    var els: std.ArrayList(Inst.Index) = .empty;
    defer els.deinit(gpa);
    var in_then: std.ArrayList(Inst.Index) = .empty;
    defer in_then.deinit(gpa);
    var in_els: std.ArrayList(Inst.Index) = .empty;
    defer in_els.deinit(gpa);
    const inner = try t.ifElse(&then, .real_type, try t.bin(&then, .fgt, v, try t.real(1)), &in_then, v, &in_els, try t.real(1));
    const r = try t.ifElse(&t.main, .real_type, c, &then, inner, &els, try t.real(0));
    var air = try t.finish(r);
    defer air.deinit(gpa);
    var out = try Legalize.run(gpa, air, &t.ip, .{});
    defer out.deinit(gpa);
    try testing.expectEqual(@as(u32, 2), out.converted);
    try testing.expect(straight(out.air, r));
    const x = out.air.extraData(Air.Block, out.air.instructions.items(.data)[at(r)].ty_pl.payload);
    const body = out.air.body(x.end, x.data.body_len);
    const sel = body[body.len - 2];
    try testing.expectEqual(Inst.Tag.select, out.air.instructions.items(.tag)[@backingInt(sel)]);
    try testing.expectEqual(gt, out.air.instructions.items(.data)[@backingInt(sel)].pl_op.operand);
    try sameRuns(&t, air, out.air, &.{ -1, 0.5, 2 });
}

test "Setup: a parameter's function is fixed, a probe's moves, a varying branch keeps only what cannot fault" {
    // a = 2p; b = V + a; if (V > 0) { u = p + 1; w = asin(p) }: a and u are
    // the same every solve (u computed unconditionally, outside every loop);
    // w is not (asin reports a domain error where its source would not run).
    const gpa = testing.allocator;
    var t = try T.init(gpa);
    defer t.deinit();
    const p = try t.arg(.real_type, 0);
    const v = try t.probe(&t.main, 0);
    const a = try t.bin(&t.main, .fmul, p, try t.real(2));
    const b = try t.bin(&t.main, .fadd, v, a);
    var then: std.ArrayList(Inst.Index) = .empty;
    defer then.deinit(gpa);
    var els: std.ArrayList(Inst.Index) = .empty;
    defer els.deinit(gpa);
    const u = try t.bin(&then, .fadd, p, try t.real(1));
    const w = try t.un(&then, .asin, p);
    const r = try t.ifElse(&t.main, .real_type, try t.bin(&t.main, .fgt, v, try t.real(0)), &then, try t.bin(&then, .fadd, u, w), &els, b);
    var air = try t.finish(r);
    defer air.deinit(gpa);
    var s = try Setup.invariance(gpa, air, &t.ip, &.{});
    defer s.deinit(gpa);
    try testing.expect(s.invariant.isSet(at(a)));
    try testing.expect(s.placeable.isSet(at(a)));
    try testing.expect(!s.invariant.isSet(at(b)));
    try testing.expect(s.invariant.isSet(at(u)));
    try testing.expect(!s.placeable.isSet(at(u)));
    try testing.expect(!s.invariant.isSet(at(w)));
    try testing.expect(!s.invariant.isSet(at(r)));
}

test "Setup: E0531 names a probe inside a vera_timepoint statement, not the time" {
    // §2.9: inside the cached statement, `V * 2` moves between the Newton
    // iterations of one timepoint; a call the caller says is fixed per
    // timepoint (`$abstime`) does not; an unknown call does.
    const gpa = testing.allocator;
    for ([_]?Air.CallFacts{ null, .{ .timepoint = true }, .{} }) |facts| {
        var t = try T.init(gpa);
        defer t.deinit();
        const region = try t.b.addInst(gpa, .{ .tag = .block, .data = undefined });
        var body: std.ArrayList(Inst.Index) = .empty;
        defer body.deinit(gpa);
        const x = if (facts == null) try t.probe(&body, 0) else try t.call(&body, 0, .real_type);
        const v = try t.bin(&body, .fmul, x, try t.real(2));
        _ = try t.add(&body, .{ .tag = .br, .data = .{ .br = .{ .block_inst = region, .operand = v } } });
        try t.b.setBody(gpa, region, .real_type, body.items);
        try t.main.append(gpa, region);
        var air = try t.finish(.fromIndex(region));
        defer air.deinit(gpa);
        const calls: []const Air.CallFacts = if (facts) |f| &.{f} else &.{};
        const got = try Setup.timepoint(gpa, air, &t.ip, calls, region);
        // The first varying value inside: the probe or unknown call itself.
        const want: ?Inst.Index = if (facts != null and facts.?.timepoint) null else x.toIndex().?;
        try testing.expectEqual(want, got);
    }
}

test "Setup: a held slot written first, or never, is pruned; one read first or written under a probe is kept" {
    // §3.2: s1 = p before every read; s4 never written; s2 written only when
    // V > 0; s3 read, then written.
    const gpa = testing.allocator;
    var t = try T.init(gpa);
    defer t.deinit();
    const p = try t.arg(.real_type, 0);
    const v = try t.probe(&t.main, 0);
    var slots: [4]Inst.Ref = undefined;
    for (&slots) |*s| s.* = try t.add(&t.main, .{ .tag = .alloc, .data = .{ .ty = .real_type } });
    _ = try t.bin(&t.main, .assign, slots[0], p);
    var then: std.ArrayList(Inst.Index) = .empty;
    defer then.deinit(gpa);
    var els: std.ArrayList(Inst.Index) = .empty;
    defer els.deinit(gpa);
    _ = try t.bin(&then, .assign, slots[1], try t.real(1));
    _ = try t.ifElse(&t.main, .none, try t.bin(&t.main, .fgt, v, try t.real(0)), &then, .none, &els, .none);
    const early = try t.un(&t.main, .load, slots[2]);
    _ = try t.bin(&t.main, .assign, slots[2], try t.real(1));
    var sum = early;
    for (slots) |s| sum = try t.bin(&t.main, .fadd, sum, try t.un(&t.main, .load, s));
    var air = try t.finish(sum);
    defer air.deinit(gpa);
    var held: [4]Inst.Index = undefined;
    for (&held, slots) |*h, s| h.* = s.toIndex().?;
    const keep = try Setup.pruneHeld(gpa, air, &t.ip, &.{}, &held);
    defer gpa.free(keep);
    try testing.expectEqualSlices(bool, &.{ false, true, true, false }, keep);
}
