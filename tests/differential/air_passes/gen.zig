//! The Air program generator of `diff-air-passes`: a seeded `std.Random`
//! in, a well-formed structured `Air` (`Air.Verify` accepts every one) and
//! the host contract its samples honour out. A program reads three real
//! parameters with §3.4.2 range shapes and two §4.4 probes; computes over
//! the Table 4-14/4-15 math, `+ - * /`, integer casts and arithmetic, `?:`
//! as a `select`; guards a domain-restricted call by a comparison on its
//! operand (`if (x > c) ln(x)`, the shape a guard fact exists to prove) in
//! a `block` + `cond_br` with a result; writes and reads real slots in
//! nested bodies; runs counted `while` loops (a counter slot, 1-3 trips);
//! and returns a sum over its values and slots. A sample draws each
//! parameter inside its range and each probe inside the host's bound, or
//! from a wide spread of finite doubles when there is none.
//! Cites: VAMS-2023 §3.4.2, §4.2.12, §4.3.1, §4.3.2, §4.4, §5.7, §5.8, §5.9.
//!
//! Contents:
//! - `pub const params_n`, `pub const probes_n`, `pub const Shape = enum`
//! - `pub const Program = struct` (`deinit`)
//! - `pub fn generate(gpa: Allocator, ip: *InternPool, r: std.Random) !Program`
//! - `pub fn sample(p: *const Program, r: std.Random, args: *[params_n]interp.Value, probes: *[probes_n]f64) void`
//! - `pub fn ranges(s: Shape) []const Interval.Range`

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const Allocator = std.mem.Allocator;
const Air = @import("air");
const InternPool = @import("intern_pool");
const Interval = Air.Interval;
const interp = Air.interp;
const Inst = Air.Inst;

/// Real parameters (`arg` 0..2) and probes (`probe` 0..1) a program reads.
pub const params_n = 3;
pub const probes_n = 2;

/// The §3.4.2 range shapes a parameter may carry.
pub const Shape = enum { none, positive_open, one_to_ten, unit_closed, negative, nonzero, unit_open, non_negative };

/// One program and its contract.
pub const Program = struct {
    air: Air,
    shapes: [params_n]Shape,
    bound: ?f64,
    /// The `ret` operand: the one root.
    root: Inst.Ref,
    /// The real slots allocated first in the main body: held-slot candidates.
    held: [slots_n]Inst.Index,

    pub fn deinit(p: *Program, gpa: Allocator) void {
        p.air.deinit(gpa);
        p.* = undefined;
    }
};

/// Real slots per program, statements per program, nesting below the main body.
const slots_n = 3;
const statements_max = 24;
const depth_max = 3;
const unary_ops = [_]Inst.Tag{ .exp, .ln, .sqrt, .sin, .cos, .tanh, .atan, .asin, .acos, .atanh, .acosh, .fneg, .fabs, .ln1p, .floor, .log10, .sinh, .cosh, .expm1, .asinh, .ceil, .tan };
const binary_ops = [_]Inst.Tag{ .fadd, .fsub, .fmul, .fdiv, .pow, .fmin, .fmax, .hypot, .atan2, .fmod };
const guarded_ops = [_]Inst.Tag{ .ln, .log10, .sqrt, .acosh, .ln1p, .asin, .atanh };
const cmp_ops = [_]Inst.Tag{ .flt, .fgt, .fle, .fge, .feq, .fne };
const int_ops = [_]Inst.Tag{ .iadd, .isub, .imul, .idiv, .imod, .imin, .imax, .iabs, .ineg };
const real_consts = [_]f64{ 0.0, 1.0, -1.0, 0.5, 2.0, -0.0, 1e300, 3.0 };

const Gen = struct {
    gpa: Allocator,
    ip: *InternPool,
    r: std.Random,
    b: Air.Builder,
    /// The values the current point may read, real and integer.
    reals: std.ArrayList(Inst.Ref) = .empty,
    ints: std.ArrayList(Inst.Ref) = .empty,
    slots: std.ArrayList(Inst.Index) = .empty,
    made: u32 = 0,

    fn deinit(g: *Gen) void {
        g.b.deinit(g.gpa);
        g.reals.deinit(g.gpa);
        g.ints.deinit(g.gpa);
        g.slots.deinit(g.gpa);
    }

    fn add(g: *Gen, body: *std.ArrayList(Inst.Index), inst: Inst) !Inst.Ref {
        const i = try g.b.addInst(g.gpa, inst);
        try body.append(g.gpa, i);
        return .fromIndex(i);
    }
    fn bin(g: *Gen, body: *std.ArrayList(Inst.Index), tag: Inst.Tag, a: Inst.Ref, b: Inst.Ref) !Inst.Ref {
        return g.add(body, .{ .tag = tag, .data = .{ .bin_op = .{ .lhs = a, .rhs = b } } });
    }
    fn un(g: *Gen, body: *std.ArrayList(Inst.Index), tag: Inst.Tag, a: Inst.Ref) !Inst.Ref {
        return g.add(body, .{ .tag = tag, .data = .{ .un_op = a } });
    }
    fn real(g: *Gen) !Inst.Ref {
        if (g.r.uintLessThan(u8, 5) == 0) return .fromIntern(try g.ip.get(g.gpa, .{ .float = real_consts[g.r.uintLessThan(usize, real_consts.len)] }));
        // Recent values more often: deeper expressions.
        const n = g.reals.items.len;
        const k = if (g.r.boolean()) n - 1 - g.r.uintLessThan(usize, @min(n, 4)) else g.r.uintLessThan(usize, n);
        return g.reals.items[k];
    }
    fn int(g: *Gen) !Inst.Ref {
        if (g.ints.items.len == 0 or g.r.uintLessThan(u8, 3) == 0) return .fromIntern(try g.ip.get(g.gpa, .{ .int = .{ .ty = .integer_type, .storage = .{ .small = g.r.intRangeAtMost(i64, -2, 3) } } }));
        return g.ints.items[g.r.uintLessThan(usize, g.ints.items.len)];
    }

    /// Appends statements to `body` (no terminator): its values stay visible
    /// to the caller only where `body` is the caller's own.
    fn statements(g: *Gen, body: *std.ArrayList(Inst.Index), depth: u32) anyerror!void {
        const n = 1 + g.r.uintLessThan(u32, if (depth == 0) 8 else 4);
        for (0..n) |_| {
            if (g.made >= statements_max) return;
            g.made += 1;
            const pick = g.r.uintLessThan(u8, 12);
            switch (pick) {
                0, 1, 2 => try g.reals.append(g.gpa, try g.un(body, unary_ops[g.r.uintLessThan(usize, unary_ops.len)], try g.real())),
                3, 4 => try g.reals.append(g.gpa, try g.bin(body, binary_ops[g.r.uintLessThan(usize, binary_ops.len)], try g.real(), try g.real())),
                5 => try g.integer(body),
                6 => {
                    const c = try g.cond(body);
                    const sel = try g.b.addExtra(g.gpa, Air.Bin{ .lhs = try g.real(), .rhs = try g.real() });
                    try g.reals.append(g.gpa, try g.add(body, .{ .tag = .select, .data = .{ .pl_op = .{ .operand = c, .payload = sel } } }));
                },
                7 => _ = try g.bin(body, .assign, .fromIndex(g.slots.items[g.r.uintLessThan(usize, g.slots.items.len)]), try g.real()),
                8 => try g.reals.append(g.gpa, try g.un(body, .load, .fromIndex(g.slots.items[g.r.uintLessThan(usize, g.slots.items.len)]))),
                9, 10 => if (depth < depth_max) try g.guarded(body, depth),
                11 => if (depth < depth_max) try g.loop(body, depth),
                else => unreachable,
            }
        }
    }

    /// An integer from a real, integer arithmetic, back to a real.
    fn integer(g: *Gen, body: *std.ArrayList(Inst.Index)) !void {
        try g.ints.append(g.gpa, try g.un(body, .fi_cast, try g.real()));
        const op = int_ops[g.r.uintLessThan(usize, int_ops.len)];
        const v = if (Air.tag_info.get(op).class == .un_op) try g.un(body, op, try g.int()) else try g.bin(body, op, try g.int(), try g.int());
        try g.ints.append(g.gpa, v);
        try g.reals.append(g.gpa, try g.un(body, .if_cast, v));
    }

    fn cond(g: *Gen, body: *std.ArrayList(Inst.Index)) !Inst.Ref {
        const c = try g.bin(body, cmp_ops[g.r.uintLessThan(usize, cmp_ops.len)], try g.real(), try g.real());
        return switch (g.r.uintLessThan(u8, 6)) {
            0 => g.un(body, .lognot, c),
            1 => g.bin(body, .ine, c, .fromIntern(.zero)),
            else => c,
        };
    }

    /// `block(real) { cond_br(x OP c, { y = f(x); ...; br y }, { ...; br z }) }`.
    fn guarded(g: *Gen, body: *std.ArrayList(Inst.Index), depth: u32) !void {
        const x = try g.real();
        const k: Inst.Ref = .fromIntern(try g.ip.get(g.gpa, .{ .float = ([_]f64{ 0, -1, 1, 0.5 })[g.r.uintLessThan(usize, 4)] }));
        const c = if (g.r.uintLessThan(u8, 4) == 0) try g.cond(body) else try g.bin(body, if (g.r.boolean()) .fgt else .fge, x, k);
        const blk = try g.b.addInst(g.gpa, .{ .tag = .block, .data = undefined });
        var arms: [2]std.ArrayList(Inst.Index) = .{ .empty, .empty };
        defer for (&arms) |*a| a.deinit(g.gpa);
        for (&arms, 0..) |*arm, side| {
            const mark = .{ g.reals.items.len, g.ints.items.len };
            if (side == 0 and g.r.boolean()) try g.reals.append(g.gpa, try g.un(arm, guarded_ops[g.r.uintLessThan(usize, guarded_ops.len)], x));
            try g.statements(arm, depth + 1);
            const out = try g.real();
            g.reals.shrinkRetainingCapacity(mark[0]);
            g.ints.shrinkRetainingCapacity(mark[1]);
            _ = try g.add(arm, .{ .tag = .br, .data = .{ .br = .{ .block_inst = blk, .operand = out } } });
        }
        const cb = try g.b.addCondBr(g.gpa, c, arms[0].items, arms[1].items);
        try g.b.setBody(g.gpa, blk, .real_type, &.{cb});
        try body.append(g.gpa, blk);
        try g.reals.append(g.gpa, .fromIndex(blk));
    }

    /// `k = 0; while (k < n) { ...; k = k + 1; }` with n in 1..3.
    fn loop(g: *Gen, body: *std.ArrayList(Inst.Index), depth: u32) !void {
        const k = (try g.add(body, .{ .tag = .alloc, .data = .{ .ty = .integer_type } })).toIndex().?;
        const out = try g.b.addInst(g.gpa, .{ .tag = .block, .data = undefined });
        const lp = try g.b.addInst(g.gpa, .{ .tag = .loop, .data = undefined });
        var head: std.ArrayList(Inst.Index) = .empty;
        defer head.deinit(g.gpa);
        var then: std.ArrayList(Inst.Index) = .empty;
        defer then.deinit(g.gpa);
        const k0 = try g.un(&head, .load, .fromIndex(k));
        const n: Inst.Ref = .fromIntern(try g.ip.get(g.gpa, .{ .int = .{ .ty = .integer_type, .storage = .{ .small = g.r.intRangeAtMost(i64, 1, 3) } } }));
        const go = try g.bin(&head, .ilt, k0, n);
        const mark = .{ g.reals.items.len, g.ints.items.len };
        try g.ints.append(g.gpa, k0);
        try g.statements(&then, depth + 1);
        g.reals.shrinkRetainingCapacity(mark[0]);
        g.ints.shrinkRetainingCapacity(mark[1]);
        const k1 = try g.bin(&then, .iadd, k0, .fromIntern(.one));
        _ = try g.bin(&then, .assign, .fromIndex(k), k1);
        _ = try g.add(&then, .{ .tag = .repeat, .data = .{ .repeat = .{ .loop_inst = lp } } });
        const leave = try g.b.addInst(g.gpa, .{ .tag = .br, .data = .{ .br = .{ .block_inst = out, .operand = .none } } });
        try head.append(g.gpa, try g.b.addCondBr(g.gpa, go, then.items, &.{leave}));
        try g.b.setBody(g.gpa, lp, .none, head.items);
        try g.b.setBody(g.gpa, out, .none, &.{lp});
        try body.append(g.gpa, out);
    }
};

/// Returns a random well-formed program. Its `Air` is the caller's to free.
pub fn generate(gpa: Allocator, ip: *InternPool, r: std.Random) !Program {
    var g: Gen = .{ .gpa = gpa, .ip = ip, .r = r, .b = try .init(gpa) };
    defer g.deinit();
    var p: Program = .{ .air = undefined, .shapes = undefined, .bound = if (r.boolean()) 10.0 else null, .root = undefined, .held = undefined };
    var main: std.ArrayList(Inst.Index) = .empty;
    defer main.deinit(gpa);
    for (&p.shapes, 0..) |*s, i| {
        s.* = r.enumValue(Shape);
        try g.reals.append(gpa, try g.add(&main, .{ .tag = .arg, .data = .{ .ty_index = .{ .ty = .real_type, .index = @intCast(i) } } }));
    }
    for (0..probes_n) |i| try g.reals.append(gpa, try g.add(&main, .{ .tag = .probe, .data = .{ .ty_index = .{ .ty = .real_type, .index = @intCast(i) } } }));
    for (&p.held) |*h| {
        h.* = (try g.add(&main, .{ .tag = .alloc, .data = .{ .ty = .real_type } })).toIndex().?;
        try g.slots.append(gpa, h.*);
    }
    try g.statements(&main, 0);
    // The root reads the last values and every slot, so all are on its slice.
    var sum = g.reals.items[g.reals.items.len - 1];
    for (g.slots.items) |s| sum = try g.bin(&main, .fadd, sum, try g.add(&main, .{ .tag = .load, .data = .{ .un_op = .fromIndex(s) } }));
    sum = try g.bin(&main, .fadd, sum, g.reals.items[r.uintLessThan(usize, g.reals.items.len)]);
    _ = try g.add(&main, .{ .tag = .ret, .data = .{ .un_op = sum } });
    p.root = sum;
    p.air = try g.b.finish(gpa, main.items);
    return p;
}

/// Writes one sample inside the contract: each parameter in its range, each
/// probe inside the bound (or anywhere finite).
pub fn sample(p: *const Program, r: std.Random, args: *[params_n]interp.Value, probes: *[probes_n]f64) void {
    for (args, p.shapes) |*a, s| a.* = .{ .real = inShape(r, s) };
    for (probes) |*x| x.* = if (p.bound) |b| (if (r.uintLessThan(u8, 8) == 0) (if (r.boolean()) b else -b) else (r.float(f64) * 2 - 1) * b) else wide(r);
    for (args) |a| assert(math.isFinite(a.real));
}

/// Returns shape `s` as §3.4.2 ranges.
pub fn ranges(s: Shape) []const Interval.Range {
    const inf = math.inf(f64);
    return switch (s) {
        .none => &.{},
        .positive_open => &.{.{ .kind = .from, .lo = 0, .hi = inf, .lo_inclusive = false, .hi_inclusive = false }},
        .one_to_ten => &.{.{ .kind = .from, .lo = 1, .hi = 10 }},
        .unit_closed => &.{.{ .kind = .from, .lo = -1, .hi = 1 }},
        .negative => &.{.{ .kind = .from, .lo = -10, .hi = -1 }},
        .nonzero => &.{.{ .kind = .exclude, .lo = 0, .hi = 0 }},
        .unit_open => &.{.{ .kind = .from, .lo = -1, .hi = 1, .lo_inclusive = false, .hi_inclusive = false }},
        .non_negative => &.{.{ .kind = .from, .lo = 0, .hi = 10 }},
    };
}

// ---- private ----

/// A finite double from a wide spread: small, log-uniform, and the edges.
fn wide(r: std.Random) f64 {
    return switch (r.uintLessThan(u8, 10)) {
        0...3 => (r.float(f64) * 2 - 1) * 10,
        4...6 => (if (r.boolean()) @as(f64, 1) else -1) * @exp((r.float(f64) * 2 - 1) * 100),
        7 => ([_]f64{ 0, 1, -1, 1e-300, -1e-300, 1e300, -1e300, math.floatMax(f64), -math.floatMax(f64), math.floatTrueMin(f64) })[r.uintLessThan(usize, 10)],
        else => r.floatNorm(f64),
    };
}

fn inShape(r: std.Random, s: Shape) f64 {
    const u = r.float(f64);
    const edge = r.uintLessThan(u8, 8) == 0;
    return switch (s) {
        .none => wide(r),
        .positive_open => blk: {
            const x = @abs(wide(r));
            break :blk if (x == 0) math.floatTrueMin(f64) else x;
        },
        .one_to_ten => if (edge) (if (r.boolean()) @as(f64, 1) else 10) else 1 + 9 * u,
        .unit_closed => if (edge) (if (r.boolean()) @as(f64, 1) else -1) else u * 2 - 1,
        .negative => if (edge) (if (r.boolean()) @as(f64, -1) else -10) else -1 - 9 * u,
        .nonzero => blk: {
            const x = wide(r);
            break :blk if (x == 0) 1 else x;
        },
        .unit_open => blk: {
            const x = u * 2 - 1;
            break :blk if (x == -1) 0 else x;
        },
        .non_negative => if (edge) (if (r.boolean()) @as(f64, 0) else 10) else 10 * u,
    };
}
