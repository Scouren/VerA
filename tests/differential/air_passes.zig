//! The `diff-air-passes` oracles: the Air passes held against
//! `Air.interp` over generated programs (`air_passes/gen.zig`), since no
//! differential against the old `src/prove` exists until Sema does.
//!
//! - Float, by falsification (the old `src/prove/falsify.zig` is the
//!   model): over `programs` programs and `points` samples each, every value
//!   a run defines lies in the interval `Float` gave its instruction; an
//!   instruction `Float` calls finite never defines inf or NaN; a root rated
//!   `.optimized` sees no inf or NaN on its slice, which the oracle finds on
//!   its own (operands, a loaded slot's writes, a block's `br`s, the
//!   conditions around each); an instruction `Float` reports outside its
//!   domain never runs inside it. Rule 3 (`+ - * /`, `%`, `hypot` on finite
//!   operands do not overflow) is the host contract: a run where one does is
//!   dropped whole, as falsify.zig drops it.
//! - Each oracle goes red on a planted bug first: a Float that calls every
//!   value finite and every root `.optimized`, one whose intervals are a
//!   point, one that calls every domain violated.
//! A failure passes only when a line of `air_passes.xfail` names its oracle
//! and kind; a line that never fires fails the run.
//! Cites: VAMS-2023 §4.2.12, §4.3.1, §4.3.2, §5.8.
//!
//! Contents: none public; tests only.

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const Allocator = std.mem.Allocator;
const Air = @import("air");
const InternPool = @import("intern_pool");
const Diag = @import("vams").Diag;
const gen = @import("air_passes/gen.zig");
const interp = Air.interp;
const Inst = Air.Inst;
const Value = interp.Value;
const Float = Air.Float;
const Interval = Air.Interval;

const programs = 10_000;
const points = 1_000;
/// The planted bugs run on fewer: they only have to go red.
const planted_programs = 200;
const planted_points = 50;
const seed: u64 = 0xA1F0_5EED;
const loop_cap = 1_000;
/// Failures printed per oracle kind, one per tag.
const examples_max = 6;

/// What a falsification run holds a run against.
const Claims = struct {
    iv: []const Interval,
    finite: []const bool,
    domain: []const Float.Domain,
    optimized: bool,
};

/// Which claim a run broke.
const Kind = enum { interval, finite, slice, violation };

/// Totals of one falsification sweep.
const Stats = struct {
    programs: u64 = 0,
    runs: u64 = 0,
    dropped: u64 = 0,
    optimized: u64 = 0,
    failed: std.EnumArray(Kind, u64) = .initFill(0),
    /// The tags an example was printed for, per kind: one example each.
    printed: std.EnumArray(Kind, std.EnumSet(Inst.Tag)) = .initFill(.empty),
};

/// What a planted bug claims instead of `Float`'s answer.
const Plant = enum { none, all_finite, all_optimized, point_iv, all_violated };

/// One run's observer: holds every value against the claims.
const Watch = struct {
    air: Air,
    ip: *const InternPool,
    claims: Claims,
    slice: []const bool,
    /// Per instruction: its value in this run so far, for operand reads.
    last: []Value,
    overflow: bool = false,
    failure: ?struct { kind: Kind, inst: u32, value: f64 } = null,

    fn seen(ctx: *anyopaque, inst: Inst.Index, v: Value) void {
        const w: *Watch = @ptrCast(@alignCast(ctx));
        const i = @backingInt(inst);
        w.last[i] = v;
        const x: f64 = switch (v) {
            .real => |x| x,
            .int => |n| @floatFromInt(n),
            .array => return,
        };
        const tag = w.air.instructions.items(.tag)[i];
        if (v == .real and !math.isFinite(x) and rule3(tag) and w.operandsFinite(i)) w.overflow = true;
        if (w.failure != null) return;
        const kind: ?Kind = if (!math.isNan(x) and !w.claims.iv[i].contains(x))
            .interval
        else if (w.claims.finite[i] and !math.isFinite(x))
            .finite
        else if (w.claims.optimized and w.slice[i] and !math.isFinite(x))
            .slice
        else if (w.claims.domain[i] == .violated and w.inDomain(i))
            .violation
        else
            null;
        if (kind) |k| w.failure = .{ .kind = k, .inst = i, .value = x };
    }

    fn get(w: *const Watch, ref: Inst.Ref) f64 {
        if (ref.toIndex()) |i| return switch (w.last[@backingInt(i)]) {
            .real => |x| x,
            .int => |n| @floatFromInt(n),
            .array => math.nan(f64),
        };
        return switch (w.ip.indexToKey(ref.toInterned().?)) {
            .float => |x| x,
            .int => |int| @floatFromInt(int.storage.small),
            .undef, .str, .simple_type, .int_type, .array_type, .nature, .discipline => math.nan(f64),
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

// ---- private ----

/// The tags rule 3 covers.
fn rule3(tag: Inst.Tag) bool {
    return switch (tag) {
        .fadd, .fsub, .fmul, .fdiv, .fmod, .hypot => true,
        else => false, // else: every other tag's finiteness is proven, not assumed
    };
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

/// Runs `n_points` samples of `p` against `claims`, adding to `stats`.
fn falsify(gpa: Allocator, ip: *const InternPool, p: *const gen.Program, claims: Claims, slice: []const bool, r: std.Random, n_points: u32, stats: *Stats) !void {
    var run_arena: std.heap.ArenaAllocator = .init(gpa);
    defer run_arena.deinit();
    const last = try gpa.alloc(Value, p.air.instructions.len);
    defer gpa.free(last);
    var args: [gen.params_n]Value = undefined;
    var probes: [gen.probes_n]f64 = undefined;
    for (0..n_points) |_| {
        _ = run_arena.reset(.retain_capacity);
        gen.sample(p, r, &args, &probes);
        var w: Watch = .{ .air = p.air, .ip = ip, .claims = claims, .slice = slice, .last = last };
        _ = interp.run(run_arena.allocator(), p.air, ip, .{ .args = &args, .probes = &probes, .loop_cap = loop_cap, .observe = .{ .ctx = &w, .seen = Watch.seen } }) catch |e| switch (e) {
            error.NoValue, error.LoopCap => {},
            error.Unsupported, error.OutOfMemory => return e,
        };
        stats.runs += 1;
        if (w.overflow) {
            stats.dropped += 1;
            continue;
        }
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

/// Generates `n_programs` programs, analyses each, plants `plant` into the
/// claims and falsifies them.
fn sweep(gpa: Allocator, plant: Plant, n_programs: u32, n_points: u32) !Stats {
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
        var claims: Claims = .{ .iv = f.iv, .finite = f.finite, .domain = f.domain, .optimized = f.modes[0] == .optimized };
        switch (plant) {
            .none => {},
            .all_finite => {
                claims.finite = try a.alloc(bool, f.finite.len);
                @memset(@constCast(claims.finite), true);
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
        }
        stats.programs += 1;
        stats.optimized += @intFromBool(claims.optimized);
        try falsify(gpa, &ip, &p, claims, try oracleSlice(a, p.air, p.root), r, n_points, &stats);
    }
    return stats;
}

/// Fails when `failures` and `air_passes.xfail` disagree: a failure no
/// line names, or a line naming `oracle kind` that never failed.
fn gate(oracle: []const u8, kind: []const u8, failures: u64) !void {
    var lines = std.mem.splitScalar(u8, @embedFile("air_passes.xfail"), '\n');
    const listed = while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        if (std.mem.eql(u8, words.next() orelse "", oracle) and std.mem.eql(u8, words.next() orelse "", kind)) break true;
    } else false;
    if (listed and failures == 0) std.debug.print("air_passes.xfail: `{s} {s}` never fails: delete the line\n", .{ oracle, kind });
    if (!listed and failures != 0) std.debug.print("air_passes: {s} {s}: {d} failures no xfail line names\n", .{ oracle, kind, failures });
    try std.testing.expect(listed == (failures != 0));
}

fn report(name: []const u8, s: Stats) void {
    std.debug.print("air_passes {s}: {d} programs ({d} rated .optimized), {d} runs, {d} dropped (rule 3), failures: interval {d}, finite {d}, slice {d}, violation {d}\n", .{ name, s.programs, s.optimized, s.runs, s.dropped, s.failed.get(.interval), s.failed.get(.finite), s.failed.get(.slice), s.failed.get(.violation) });
}

test "Float: each planted bug goes red" {
    // The oracle is trusted only after it catches a wrong verdict of each kind.
    const gpa = std.testing.allocator;
    const finite = try sweep(gpa, .all_finite, planted_programs, planted_points);
    report("planted all_finite", finite);
    try std.testing.expect(finite.failed.get(.finite) != 0);
    const optimized = try sweep(gpa, .all_optimized, planted_programs, planted_points);
    report("planted all_optimized", optimized);
    try std.testing.expect(optimized.failed.get(.slice) != 0);
    const point = try sweep(gpa, .point_iv, planted_programs, planted_points);
    report("planted point_iv", point);
    try std.testing.expect(point.failed.get(.interval) != 0);
    const violated = try sweep(gpa, .all_violated, planted_programs, planted_points);
    report("planted all_violated", violated);
    try std.testing.expect(violated.failed.get(.violation) != 0);
}

test "Float: sound on generated programs (falsification)" {
    const gpa = std.testing.allocator;
    const s = try sweep(gpa, .none, programs, points);
    report("Float", s);
    for (std.enums.values(Kind)) |k| try gate("float", @tagName(k), s.failed.get(k));
}
