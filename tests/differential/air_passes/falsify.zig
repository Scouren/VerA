//! The Float falsification oracle of `diff-air-passes`: generated programs
//! (`gen.zig`) analysed by `Float`, then run by `Air.interp` with the
//! device's math (`interp.Math.device`: `std_kernels`, not the
//! interpreter's own correctly rounded functions, which would share the
//! assumption under test) at points inside and outside their input box,
//! every claim held against every value a run defines (the root file's
//! header states the claims). Each planted bug rewrites `Float`'s answer
//! before the runs.
//! Cites: VAMS-2023 §3.4.2, §4.3.1, §4.3.2, §4.4.
//!
//! Contents:
//! - `pub const seed: u64`, `pub const loop_cap`, `pub const examples_max`
//! - `pub const Kind = enum`, `pub const Stats = struct`, `pub const Plant = enum`
//! - `pub fn sweep(gpa: Allocator, plant: Plant, n_programs: u32, n_points: u32) !Stats`
//! - `pub fn report(name: []const u8, s: Stats) void`

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const Allocator = std.mem.Allocator;
const Air = @import("air");
const InternPool = @import("intern_pool");
const Diag = @import("vams").Diag;
const gen = @import("gen.zig");
const interp = Air.interp;
const Inst = Air.Inst;
const Value = interp.Value;
const Float = Air.Float;
const Interval = Air.Interval;

/// The generator's seed: every sweep replays the same programs.
pub const seed: u64 = 0xA1F0_5EED;
/// Most `repeat`s one run may take.
pub const loop_cap = 1_000;
/// Failures printed per oracle kind, one per tag.
pub const examples_max = 6;

/// Which claim a run broke.
pub const Kind = enum { interval, finite, slice, violation };

/// Totals of one falsification sweep.
pub const Stats = struct {
    programs: u64 = 0,
    runs: u64 = 0,
    /// Runs inside the whole input box.
    inside: u64 = 0,
    /// Runs of an `.optimized` root inside its guard box (the fast body
    /// would run) and outside it (the strict body would).
    fast: u64 = 0,
    guarded_out: u64 = 0,
    /// Runs where `+ - * /`, `%` or `hypot` made ±inf or NaN from finite
    /// operands (the old oracle dropped them), and those of them where the
    /// fast body would run.
    overflowed: u64 = 0,
    overflowed_fast: u64 = 0,
    optimized: u64 = 0,
    failed: std.EnumArray(Kind, u64) = .initFill(0),
    /// The tags an example was printed for, per kind: one example each.
    printed: std.EnumArray(Kind, std.EnumSet(Inst.Tag)) = .initFill(.empty),
};

/// What a planted bug claims instead of `Float`'s answer.
pub const Plant = enum { none, all_finite, all_optimized, point_iv, all_violated, overflow_contract, inward, wide_box };

/// What a falsification run holds a run against.
const Claims = struct {
    iv: []const Interval,
    finite: []const bool,
    domain: []const Float.Domain,
    optimized: bool,
    /// The root's guard box: the slice claim holds where every guard admits.
    box: []const Float.Guard,
};

/// One run's observer: holds every value against the claims.
const Watch = struct {
    air: Air,
    ip: *const InternPool,
    claims: Claims,
    slice: []const bool,
    /// Per instruction: its value in this run so far, for operand reads.
    last: []Value,
    /// The point lies inside the whole input box: the per-instruction
    /// claims hold. Inside the root's guard box: the slice claim holds.
    inside: bool,
    inside_root: bool,
    overflow: bool = false,
    failure: ?struct { kind: Kind, inst: u32, value: f64 } = null,

    fn seen(ctx: *anyopaque, inst: Inst.Index, v: Value) void {
        const w: *Watch = @ptrCast(@alignCast(ctx));
        const i = @backingInt(inst);
        w.last[i] = v;
        const x: f64 = switch (v) {
            .real => |x| x,
            .int => |n| @floatFromInt(n),
            .array, .str => return,
        };
        const tag = w.air.instructions.items(.tag)[i];
        if (v == .real and !math.isFinite(x) and rule3(tag) and w.operandsFinite(i)) w.overflow = true;
        if (w.failure != null) return;
        const kind: ?Kind = if (w.inside and !math.isNan(x) and !w.claims.iv[i].contains(x))
            .interval
        else if (w.inside and w.claims.finite[i] and !math.isFinite(x))
            .finite
        else if (w.inside_root and w.claims.optimized and w.slice[i] and !math.isFinite(x))
            .slice
        else if (w.inside and w.claims.domain[i] == .violated and w.inDomain(i))
            .violation
        else
            null;
        if (kind) |k| w.failure = .{ .kind = k, .inst = i, .value = x };
    }

    fn get(w: *const Watch, ref: Inst.Ref) f64 {
        if (ref.toIndex()) |i| return switch (w.last[@backingInt(i)]) {
            .real => |x| x,
            .int => |n| @floatFromInt(n),
            .array, .str => math.nan(f64),
        };
        return switch (w.ip.indexToKey(ref.toInterned().?)) {
            .float => |x| x,
            .int => |int| @floatFromInt(int.storage.small),
            .undef, .str, .aggregate, .simple_type, .int_type, .array_type, .nature, .discipline => math.nan(f64),
        };
    }

    fn operandsFinite(w: *const Watch, i: u32) bool {
        const d = w.air.instructions.items(.data)[i].bin_op;
        return math.isFinite(w.get(d.lhs)) and math.isFinite(w.get(d.rhs));
    }

    /// Whether instruction `i`'s operands, as this run reads them, lie in
    /// its Table 4-14/4-15 domain: the oracle's own reading of the tables.
    fn inDomain(w: *const Watch, i: u32) bool {
        const tag = w.air.instructions.items(.tag)[i];
        if (Air.tag_info.get(tag).domain == .all) return true;
        const data = w.air.instructions.items(.data)[i];
        const unary = Air.tag_info.get(tag).class == .un_op;
        const x = w.get(if (unary) data.un_op else data.bin_op.lhs);
        const y = if (unary) 0 else w.get(data.bin_op.rhs);
        return switch (Air.tag_info.get(tag).domain) {
            .all, .tan_poles => true,
            .positive => x > 0,
            .gt_neg_one => x > -1,
            .non_negative => x >= 0,
            .unit_closed => -1 <= x and x <= 1,
            .unit_open => -1 < x and x < 1,
            .ge_one => x >= 1,
            .nonzero_divisor => y != 0,
            .pow_sign => x > 0 or (x == 0 and y > 0) or (x < 0 and y == @trunc(y)),
        };
    }
};

/// Generates `n_programs` programs, analyses each, plants `plant` into the
/// claims and falsifies them.
pub fn sweep(gpa: Allocator, plant: Plant, n_programs: u32, n_points: u32) !Stats {
    var prng: std.Random.DefaultPrng = .init(seed);
    const r = prng.random();
    var stats: Stats = .{};
    var ip = try InternPool.init(gpa);
    defer ip.deinit(gpa);
    for (0..n_programs) |_| {
        var p = try gen.generate(gpa, &ip, r);
        defer p.deinit(gpa);
        try std.testing.expectEqual(@as(?Air.Verify.Violation, null), try Air.Verify.verify(gpa, p.air, &ip));
        var params: [gen.params_n]Float.Param = undefined;
        for (&params, p.shapes) |*q, s| q.* = .{ .ranges = gen.ranges(s) };
        var wip: Diag.Wip = .init(gpa);
        defer wip.deinit();
        var f = try Float.analyze(gpa, p.air, &ip, .{ .params = &params, .roots = &.{.{ .refs = &.{p.root} }}, .unknown_bound = p.bound }, &wip);
        defer f.deinit(gpa);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const finite = try a.alloc(bool, f.nan.len);
        for (finite, 0..) |*x, i| x.* = f.finite(@intCast(i));
        var claims: Claims = .{ .iv = f.iv, .finite = finite, .domain = f.domain, .optimized = f.verdict.modes[0] == .optimized, .box = f.verdict.box(0) };
        switch (plant) {
            .none => {},
            .all_finite => {
                @memset(finite, true);
                claims.iv = try a.alloc(Interval, f.iv.len);
                @memset(@constCast(claims.iv), .top);
                claims.optimized = true;
            },
            .all_optimized => claims.optimized = true,
            .point_iv => {
                claims.iv = try a.alloc(Interval, f.iv.len);
                @memset(@constCast(claims.iv), .point(0));
            },
            .all_violated => {
                claims.domain = try a.alloc(Float.Domain, f.domain.len);
                @memset(@constCast(claims.domain), .violated);
            },
            .overflow_contract, .inward, .wide_box => {},
        }
        const slice = try oracleSlice(a, p.air, p.root);
        switch (plant) {
            .none, .all_finite, .all_optimized, .point_iv, .all_violated => {},
            .overflow_contract => claims.optimized = try plantOverflowContract(a, &ip, p.air, f.error_count, slice, &claims),
            .inward => claims.iv = try plantInward(a, p.air, f.iv),
            .wide_box => claims.box = try plantWideBox(a, claims.box),
        }
        stats.programs += 1;
        stats.optimized += @intFromBool(claims.optimized);
        try falsify(gpa, &ip, &p, claims, slice, p.bound orelse Float.default_unknown_bound, r, n_points, &stats);
    }
    return stats;
}

pub fn report(name: []const u8, s: Stats) void {
    std.debug.print("air_passes {s}: {d} programs ({d} rated .optimized), {d} runs ({d} inside the box; of .optimized roots {d} inside the guard box, {d} outside), {d} overflowed ({d} on the fast path), failures: interval {d}, finite {d}, slice {d}, violation {d}\n", .{ name, s.programs, s.optimized, s.runs, s.inside, s.fast, s.guarded_out, s.overflowed, s.overflowed_fast, s.failed.get(.interval), s.failed.get(.finite), s.failed.get(.slice), s.failed.get(.violation) });
}

// ---- private ----

/// Runs `n_points` samples of `p` against `claims`, adding to `stats`;
/// `bound` is the probes' half of the input box.
fn falsify(gpa: Allocator, ip: *const InternPool, p: *const gen.Program, claims: Claims, slice: []const bool, bound: f64, r: std.Random, n_points: u32, stats: *Stats) !void {
    var run_arena: std.heap.ArenaAllocator = .init(gpa);
    defer run_arena.deinit();
    const last = try gpa.alloc(Value, p.air.instructions.len);
    defer gpa.free(last);
    var args: [gen.params_n]Value = undefined;
    var probes: [gen.probes_n]f64 = undefined;
    for (0..n_points) |_| {
        _ = run_arena.reset(.retain_capacity);
        gen.sampleBox(p, r, bound, &args, &probes);
        const inside = for (args, p.shapes) |a, s| {
            if (!gen.admits(s, a.real)) break false;
        } else for (probes) |x| {
            if (!(@abs(x) <= bound)) break false;
        } else true;
        const inside_root = for (claims.box) |g| {
            const x = switch (g.leaf) {
                .arg => args[g.index].real,
                .probe => probes[g.index],
            };
            if (!g.admits(x)) break false;
        } else true;
        var w: Watch = .{ .air = p.air, .ip = ip, .claims = claims, .slice = slice, .last = last, .inside = inside, .inside_root = inside_root };
        _ = interp.run(run_arena.allocator(), p.air, ip, .{ .args = &args, .probes = &probes, .loop_cap = loop_cap, .observe = .{ .ctx = &w, .seen = Watch.seen }, .math = .device }) catch |e| switch (e) {
            error.NoValue, error.LoopCap => {},
            error.Unsupported, error.OutOfMemory => return e,
        };
        stats.runs += 1;
        stats.inside += @intFromBool(inside);
        stats.fast += @intFromBool(claims.optimized and inside_root);
        stats.guarded_out += @intFromBool(claims.optimized and !inside_root);
        stats.overflowed += @intFromBool(w.overflow);
        stats.overflowed_fast += @intFromBool(w.overflow and claims.optimized and inside_root);
        const f = w.failure orelse continue;
        stats.failed.getPtr(f.kind).* += 1;
        const printed = stats.printed.getPtr(f.kind);
        const tag = p.air.instructions.items(.tag)[f.inst];
        if (printed.count() >= examples_max or printed.contains(tag)) continue;
        printed.insert(tag);
        const iv = claims.iv[f.inst];
        std.debug.print("air_passes: {s} at %{d} = {d}, claimed [{d}:{d}] open {}/{} finite {} domain {s}; args {any} probes {any}\n", .{ @tagName(f.kind), f.inst, f.value, iv.lo, iv.hi, iv.lo_open, iv.hi_open, claims.finite[f.inst], @tagName(claims.domain[f.inst]), args, probes });
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        Air.print.write(p.air, ip, &aw.writer) catch {};
        std.debug.print("{s}\n", .{aw.written()});
    }
}

/// The merged prover's rule 3 reinstated over `claims`: `+ - * /`, `%` and
/// `hypot` on operands claimed finite are claimed finite too, their
/// interval cut to the finite doubles, and the root re-rated over the
/// oracle's slice. Returns the root's new rating.
fn plantOverflowContract(arena: Allocator, ip: *const InternPool, air: Air, errors: u8, slice: []const bool, claims: *Claims) !bool {
    const fin = try arena.dupe(bool, claims.finite);
    const iv = try arena.dupe(Interval, claims.iv);
    const finite_line: Interval = .{ .lo = -math.floatMax(f64), .hi = math.floatMax(f64) };
    // Operands precede their users in a generated program's table.
    for (air.instructions.items(.tag), air.instructions.items(.data), 0..) |tag, data, i| {
        if (!rule3(tag)) continue;
        const ops = [_]Inst.Ref{ data.bin_op.lhs, data.bin_op.rhs };
        const all = for (ops) |o| {
            const f = if (o.toIndex()) |oi| fin[@backingInt(oi)] else switch (ip.indexToKey(o.toInterned().?)) {
                .float => |c| math.isFinite(c),
                .int => true,
                .undef, .str, .aggregate, .simple_type, .int_type, .array_type, .nature, .discipline => false,
            };
            if (!f) break false;
        } else true;
        if (!all) continue;
        fin[i] = true;
        iv[i] = iv[i].meet(finite_line);
    }
    claims.finite = fin;
    claims.iv = iv;
    for (slice, 0..) |m, i| if (m and air.typeOfIndex(ip, @fromBackingInt(@intCast(i))) != .none and !fin[i]) return false;
    return errors == 0;
}

/// A box wider than the one the proof assumed: every probe guard a
/// thousand times wider, every parameter guard dropped.
fn plantWideBox(arena: Allocator, box: []const Float.Guard) ![]const Float.Guard {
    var out: std.ArrayList(Float.Guard) = .empty;
    for (box) |g| {
        if (g.leaf == .arg) continue;
        try out.append(arena, .{ .iv = .{ .lo = g.iv.lo * 1e3, .hi = g.iv.hi * 1e3 }, .index = g.index, .leaf = .probe });
    }
    return out.items;
}

/// Every finite end of a real transfer's interval (a `+ - * /` or math
/// result, not a leaf, a slot or a point) moved `Interval.libUlps(tag) + 1`
/// doubles inward: an interval rounded inward where it must round outward.
fn plantInward(arena: Allocator, air: Air, iv: []const Interval) ![]const Interval {
    const out = try arena.dupe(Interval, iv);
    for (out, air.instructions.items(.tag)) |*x, tag| {
        const info = Air.tag_info.get(tag);
        if (info.int or info.operand != .real or !(x.lo < x.hi)) continue;
        for (0..Interval.libUlps(tag) + 1) |_| {
            if (math.isFinite(x.lo)) x.lo = math.nextAfter(f64, x.lo, math.inf(f64));
            if (math.isFinite(x.hi)) x.hi = math.nextAfter(f64, x.hi, -math.inf(f64));
        }
    }
    return out;
}

/// The root's slice as the oracle reads it, a subset of what any sound
/// verdict must cover: operands, a loaded slot's writes, a block's `br`s,
/// and the condition of every `cond_br` around a member. A plain fixpoint
/// over the instruction table, sharing nothing with `Float/verdict.zig`.
fn oracleSlice(arena: Allocator, air: Air, root: Inst.Ref) ![]bool {
    const n = air.instructions.len;
    const tags = air.instructions.items(.tag);
    const datas = air.instructions.items(.data);
    const parent = try arena.alloc(u32, n);
    @memset(parent, std.math.maxInt(u32));
    try parents(air, air.mainBody(), std.math.maxInt(u32), parent);
    const member = try arena.alloc(bool, n);
    @memset(member, false);
    if (root.toIndex()) |r| member[@backingInt(r)] = true;
    var changed = true;
    while (changed) {
        changed = false;
        for (0..n) |i| {
            if (!member[i]) continue;
            var refs: [3]Inst.Ref = @splat(.none);
            switch (tags[i]) {
                .load => for (0..n) |j| {
                    if (tags[j] == .assign and datas[j].bin_op.lhs == datas[i].un_op) refs[0] = .fromIndex(@fromBackingInt(@intCast(j)));
                    if (refs[0] != .none) changed = mark(member, refs[0]) or changed;
                    refs[0] = .none;
                },
                .block => for (0..n) |j| {
                    if (tags[j] == .br and datas[j].br.block_inst == @as(Inst.Index, @fromBackingInt(@intCast(i)))) changed = mark(member, .fromIndex(@fromBackingInt(@intCast(j)))) or changed;
                },
                .assign => refs[0] = datas[i].bin_op.rhs,
                .br => refs[0] = datas[i].br.operand,
                .select => {
                    const bin = air.extraData(Air.Bin, datas[i].pl_op.payload).data;
                    refs = .{ datas[i].pl_op.operand, bin.lhs, bin.rhs };
                },
                .arg, .probe, .alloc => {},
                else => switch (Air.tag_info.get(tags[i]).class) { // else: the rest read their operands by class
                    .un_op => refs[0] = datas[i].un_op,
                    .bin_op => refs[0..2].* = .{ datas[i].bin_op.lhs, datas[i].bin_op.rhs },
                    .pl_op, .ty_pl, .ty, .ty_index, .br, .repeat => {},
                },
            }
            for (refs) |r| changed = mark(member, r) or changed;
            var p = parent[i];
            while (p != std.math.maxInt(u32)) : (p = parent[p]) {
                if (tags[p] == .cond_br) changed = mark(member, datas[p].pl_op.operand) or changed;
            }
        }
    }
    return member;
}

fn mark(member: []bool, ref: Inst.Ref) bool {
    const i = @backingInt(ref.toIndex() orelse return false);
    if (member[i]) return false;
    member[i] = true;
    return true;
}

fn parents(air: Air, insts: []const Inst.Index, parent: u32, out: []u32) !void {
    for (insts) |inst| {
        const i = @backingInt(inst);
        out[i] = parent;
        const data = air.instructions.items(.data)[i];
        switch (air.instructions.items(.tag)[i]) {
            .block, .loop => {
                const x = air.extraData(Air.Block, data.ty_pl.payload);
                try parents(air, air.body(x.end, x.data.body_len), i, out);
            },
            .cond_br => {
                const x = air.extraData(Air.CondBr, data.pl_op.payload);
                try parents(air, air.body(x.end, x.data.then_body_len + x.data.else_body_len), i, out);
            },
            else => {}, // else: no other tag has a body
        }
    }
}

/// The tags the old prover's overflow contract (its rule 3) covered.
fn rule3(tag: Inst.Tag) bool {
    return switch (tag) {
        .fadd, .fsub, .fmul, .fdiv, .fmod, .hypot => true,
        else => false, // else: every other tag's finiteness is proven, not assumed
    };
}
