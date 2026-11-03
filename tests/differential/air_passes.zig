//! The `diff-air-passes` oracles: the Air passes held against
//! `Air.interp` over generated programs (`air_passes/gen.zig`), since no
//! differential against the old `src/prove` exists until Sema does.
//!
//! - Float, by falsification (`air_passes/falsify.zig`; the old `src/prove/falsify.zig` is the
//!   model), dropping nothing: over `programs` programs and `points`
//!   samples each, drawn inside and outside the input box (each parameter's
//!   declared range, `[-bound, bound]` for each probe, `gen.admits`) and
//!   reaching the overflowing magnitudes, ±inf and NaN. At a point inside
//!   the box, every non-NaN value a run defines lies in the interval
//!   `Float` gave its instruction, an instruction `Float` calls finite
//!   never defines inf or NaN, and one it reports outside its domain never
//!   runs inside it. At a point inside a root's guard box (the box
//!   `Float.Verdict` hands codegen, which checks it at run time), a root
//!   rated `.optimized` sees no inf or NaN on its slice, which the oracle
//!   finds on its own (operands, a loaded slot's writes, a block's `br`s,
//!   the conditions around each). A point outside makes no claim (the strict
//!   body runs there) but is still run.
//! - Each oracle goes red on a planted bug first: a Float that calls every
//!   value finite and every root `.optimized`, one whose intervals are a
//!   point, one that calls every domain violated; the old prover's overflow
//!   contract (`+ - * /`, `%`, `hypot` on finite operands stay finite), an
//!   interval one ulp short of its computed ends (rounded inward, not
//!   outward), and a guard box wider than the one the proof assumed.
//! - Legalize, by a metamorphic pair: each program and its `.pure` and
//!   `.speculate` conversions give the same bits (any NaN equals any NaN)
//!   or the same error at every sample. Planted: a conversion whose
//!   selects swap their arms.
//! - Setup, invariance: with the parameters fixed and only the probes
//!   moving, every value `Setup` calls solve-invariant defines the same
//!   sequence of values (bit for bit) in every run that executes it.
//!   Planted: every value called invariant.
//! - Setup, held slots: a held slot `Setup` prunes is unobservable. A
//!   second evaluation started from the first's final slot values returns
//!   the same bits as one whose pruned slots start from the initializer.
//!   Planted: every slot pruned.
//! A failure passes only when a line of `air_passes.xfail` names its oracle
//! and kind; a line that never fires fails the run.
//! Cites: VAMS-2023 §4.2.12, §4.3.1, §4.3.2, §5.8.
//!
//! Contents: none public; tests only.

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;
const Air = @import("air");
const InternPool = @import("intern_pool");
const gen = @import("air_passes/gen.zig");
const examples = @import("air_passes/examples.zig");
const falsify = @import("air_passes/falsify.zig");
const seed = falsify.seed;
const loop_cap = falsify.loop_cap;
const examples_max = falsify.examples_max;
const interp = Air.interp;
const Inst = Air.Inst;
const Value = interp.Value;
const Float = Air.Float;
const Legalize = Air.Legalize;
const Setup = Air.Setup;

/// `-Dfull-oracles`: the nightly's sweep; else the merge tier's.
const full = @import("rewrite_options").full_oracles;
const programs: u32 = if (full) 10_000 else 2_000;
const points: u32 = if (full) 1_000 else 200;
/// The planted bugs run on fewer: they only have to go red.
const planted_programs = 200;
const planted_points = 50;
/// The Setup sweeps record a sequence per invariant value per run: the
/// costliest oracle, so fewer samples per program.
const setup_points: u32 = if (full) 200 else 50;

/// The metamorphic sweep's totals.
const Pair = struct { programs: u64 = 0, compared: u64 = 0, pure: u64 = 0, speculate: u64 = 0, differ: u64 = 0, printed: u32 = 0 };

/// The Setup sweeps' totals.
const SetupStats = struct { programs: u64 = 0, claimed: u64 = 0, pruned: u64 = 0, compared: u64 = 0, differ: u64 = 0, printed: u32 = 0 };

/// Records, per instruction it watches, every value a run defines; and
/// the last value written to each held slot.
const Record = struct {
    air: Air,
    watch: []const bool,
    seqs: []std.ArrayList(Value),
    held: []const Inst.Index = &.{},
    finals: []Value = &.{},
    arena: Allocator,

    fn seen(ctx: *anyopaque, inst: Inst.Index, v: Value) void {
        const rec: *Record = @ptrCast(@alignCast(ctx));
        const i = @backingInt(inst);
        if (rec.air.instructions.items(.tag)[i] == .assign) {
            const slot = rec.air.instructions.items(.data)[i].bin_op.lhs.toIndex().?;
            for (rec.held, rec.finals) |h, *f| if (h == slot) {
                f.* = v;
            };
            return;
        }
        if (rec.watch.len != 0 and rec.watch[i]) rec.seqs[i].append(rec.arena, v) catch @panic("OOM");
    }
};

// ---- private ----

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

/// Runs every program and its two conversions at `n_points` samples and
/// counts the samples where they differ. `plant` swaps the arms of every
/// select a conversion made.
fn legalizeSweep(gpa: Allocator, plant: bool, n_programs: u32, n_points: u32) !Pair {
    var prng: std.Random.DefaultPrng = .init(seed ^ 0x1E6A);
    const r = prng.random();
    var s: Pair = .{};
    var ip = try InternPool.init(gpa);
    defer ip.deinit(gpa);
    var run_arena: std.heap.ArenaAllocator = .init(gpa);
    defer run_arena.deinit();
    for (0..n_programs) |_| {
        var p = try gen.generate(gpa, &ip, r);
        defer p.deinit(gpa);
        var pure = try Legalize.run(gpa, p.air, &ip, .{ .mode = .pure });
        defer pure.deinit(gpa);
        var spec = try Legalize.run(gpa, pure.air, &ip, .{ .mode = .speculate });
        defer spec.deinit(gpa);
        if (plant) for ([_]Air{ pure.air, spec.air }) |out| {
            for (out.instructions.items(.tag)[p.air.instructions.len..], out.instructions.items(.data)[p.air.instructions.len..]) |tag, data| {
                if (tag != .select) continue;
                const words = @constCast(out.extra[data.pl_op.payload..][0..2]);
                std.mem.swap(u32, &words[0], &words[1]);
            }
        };
        s.programs += 1;
        s.pure += pure.converted;
        s.speculate += spec.converted;
        var args: [gen.params_n]Value = undefined;
        var probes: [gen.probes_n]f64 = undefined;
        for (0..n_points) |_| {
            gen.sample(&p, r, &args, &probes);
            const in: interp.Inputs = .{ .args = &args, .probes = &probes, .loop_cap = loop_cap };
            _ = run_arena.reset(.retain_capacity);
            const want = interp.run(run_arena.allocator(), p.air, &ip, in);
            for ([_]Air{ pure.air, spec.air }) |out| {
                s.compared += 1;
                const got = interp.run(run_arena.allocator(), out, &ip, in);
                if (sameBits(want, got)) continue;
                s.differ += 1;
                if (s.printed >= examples_max) continue;
                s.printed += 1;
                std.debug.print("air_passes legalize: {any} became {any}; args {any} probes {any}\n", .{ want, got, args, probes });
                var aw: std.Io.Writer.Allocating = .init(gpa);
                defer aw.deinit();
                Air.print.write(p.air, &ip, &aw.writer) catch {};
                aw.writer.writeAll("--- converted ---\n") catch {};
                Air.print.write(out, &ip, &aw.writer) catch {};
                std.debug.print("{s}\n", .{aw.written()});
            }
        }
    }
    return s;
}

fn sameBits(a: interp.Error!Value, b: interp.Error!Value) bool {
    const x = a catch |e| return if (b) |_| false else |f| e == f;
    const y = b catch return false;
    return sameValue(x, y);
}

fn sameValue(x: Value, y: Value) bool {
    return switch (x) {
        .real => |u| y == .real and (@as(u64, @bitCast(u)) == @as(u64, @bitCast(y.real)) or (math.isNan(u) and math.isNan(y.real))),
        .int => |n| y == .int and n == y.int,
        .array => false,
    };
}

/// Runs each program with its parameters fixed and its probes moving,
/// holding every value `Setup.invariance` calls invariant (or, planted,
/// every value) to one sequence.
fn invarianceSweep(gpa: Allocator, plant: bool, n_programs: u32, n_points: u32) !SetupStats {
    var prng: std.Random.DefaultPrng = .init(seed ^ 0x5E70);
    const r = prng.random();
    var s: SetupStats = .{};
    var ip = try InternPool.init(gpa);
    defer ip.deinit(gpa);
    var run_arena: std.heap.ArenaAllocator = .init(gpa);
    defer run_arena.deinit();
    for (0..n_programs) |_| {
        var p = try gen.generate(gpa, &ip, r);
        defer p.deinit(gpa);
        var inv = try Setup.invariance(gpa, p.air, &ip, &.{});
        defer inv.deinit(gpa);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const n = p.air.instructions.len;
        const watch = try a.alloc(bool, n);
        for (watch, 0..) |*w, i| w.* = if (plant) Air.tag_info.get(p.air.instructions.items(.tag)[i]).class != .br and p.air.typeOfIndex(&ip, @fromBackingInt(@intCast(i))) != .none else inv.invariant.isSet(i);
        const want = try a.alloc(?[]const Value, n);
        @memset(want, null);
        const seqs = try a.alloc(std.ArrayList(Value), n);
        @memset(seqs, .empty);
        s.programs += 1;
        s.claimed += inv.invariant.count();
        var args: [gen.params_n]Value = undefined;
        var other: [gen.params_n]Value = undefined;
        var probes: [gen.probes_n]f64 = undefined;
        gen.sample(&p, r, &args, &probes);
        for (0..n_points) |_| {
            gen.sample(&p, r, &other, &probes);
            _ = run_arena.reset(.retain_capacity);
            for (seqs) |*q| q.clearRetainingCapacity();
            var rec: Record = .{ .air = p.air, .watch = watch, .seqs = seqs, .arena = a };
            _ = interp.run(run_arena.allocator(), p.air, &ip, .{ .args = &args, .probes = &probes, .loop_cap = loop_cap, .observe = .{ .ctx = &rec, .seen = Record.seen } }) catch continue;
            for (seqs, want, 0..) |q, *w, i| {
                if (q.items.len == 0) continue;
                const ref = w.* orelse {
                    w.* = try a.dupe(Value, q.items);
                    continue;
                };
                s.compared += 1;
                if (sameSeq(ref, q.items)) continue;
                s.differ += 1;
                if (s.printed >= examples_max) continue;
                s.printed += 1;
                std.debug.print("air_passes setup: %{d} called invariant took {any} then {any}; args {any} probes {any}\n", .{ i, ref, q.items, args, probes });
            }
        }
    }
    return s;
}

fn sameSeq(a: []const Value, b: []const Value) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!sameValue(x, y)) return false;
    return true;
}

/// Evaluates each program twice per sample pair, the second from the
/// first's final held values, against a second whose pruned slots (or,
/// planted, every slot) start from the initializer.
fn heldSweep(gpa: Allocator, plant: bool, n_programs: u32, n_points: u32) !SetupStats {
    var prng: std.Random.DefaultPrng = .init(seed ^ 0x4E1D);
    const r = prng.random();
    var s: SetupStats = .{};
    var ip = try InternPool.init(gpa);
    defer ip.deinit(gpa);
    var run_arena: std.heap.ArenaAllocator = .init(gpa);
    defer run_arena.deinit();
    for (0..n_programs) |_| {
        var p = try gen.generate(gpa, &ip, r);
        defer p.deinit(gpa);
        const keep = try Setup.pruneHeld(gpa, p.air, &ip, &.{}, &p.held);
        defer gpa.free(keep);
        if (plant) @memset(keep, false);
        const pruned = std.mem.count(bool, keep, &.{false});
        s.programs += 1;
        s.pruned += pruned;
        if (pruned == 0) continue;
        var args: [gen.params_n]Value = undefined;
        var other: [gen.params_n]Value = undefined;
        var a_probes: [gen.probes_n]f64 = undefined;
        var b_probes: [gen.probes_n]f64 = undefined;
        gen.sample(&p, r, &args, &a_probes);
        for (0..n_points) |_| {
            gen.sample(&p, r, &other, &a_probes);
            gen.sample(&p, r, &other, &b_probes);
            _ = run_arena.reset(.retain_capacity);
            var finals: [p.held.len]Value = @splat(.{ .real = 0 });
            var rec: Record = .{ .air = p.air, .watch = &.{}, .seqs = &.{}, .held = &p.held, .finals = &finals, .arena = run_arena.allocator() };
            _ = interp.run(run_arena.allocator(), p.air, &ip, .{ .args = &args, .probes = &a_probes, .loop_cap = loop_cap, .observe = .{ .ctx = &rec, .seen = Record.seen } }) catch continue;
            var carried: [p.held.len]interp.Slot = undefined;
            var reset: [p.held.len]interp.Slot = undefined;
            for (&carried, &reset, p.held, finals, keep) |*c, *z, h, f, k| {
                c.* = .{ .alloc = h, .value = f };
                z.* = .{ .alloc = h, .value = if (k) f else .{ .real = 0 } };
            }
            const want = interp.run(run_arena.allocator(), p.air, &ip, .{ .args = &args, .probes = &b_probes, .loop_cap = loop_cap, .slots = &carried });
            const got = interp.run(run_arena.allocator(), p.air, &ip, .{ .args = &args, .probes = &b_probes, .loop_cap = loop_cap, .slots = &reset });
            s.compared += 1;
            if (sameBits(want, got)) continue;
            s.differ += 1;
            if (s.printed >= examples_max) continue;
            s.printed += 1;
            std.debug.print("air_passes held: carried {any} gave {any}, reset gave {any}; keep {any}\n", .{ finals, want, got, keep });
        }
    }
    return s;
}

test {
    _ = examples;
    _ = falsify;
}

test "Float: each planted bug goes red" {
    // The oracle is trusted only after it catches a wrong verdict of each kind.
    const gpa = std.testing.allocator;
    const finite = try falsify.sweep(gpa, .all_finite, planted_programs, planted_points);
    falsify.report("planted all_finite", finite);
    try std.testing.expect(finite.failed.get(.finite) != 0);
    const optimized = try falsify.sweep(gpa, .all_optimized, planted_programs, planted_points);
    falsify.report("planted all_optimized", optimized);
    try std.testing.expect(optimized.failed.get(.slice) != 0);
    const point = try falsify.sweep(gpa, .point_iv, planted_programs, planted_points);
    falsify.report("planted point_iv", point);
    try std.testing.expect(point.failed.get(.interval) != 0);
    const violated = try falsify.sweep(gpa, .all_violated, planted_programs, planted_points);
    falsify.report("planted all_violated", violated);
    try std.testing.expect(violated.failed.get(.violation) != 0);
    const contract = try falsify.sweep(gpa, .overflow_contract, planted_programs, planted_points);
    falsify.report("planted overflow_contract", contract);
    try std.testing.expect(contract.failed.get(.interval) + contract.failed.get(.finite) + contract.failed.get(.slice) != 0);
    const inward = try falsify.sweep(gpa, .inward, planted_programs, planted_points);
    falsify.report("planted inward", inward);
    try std.testing.expect(inward.failed.get(.interval) != 0);
}

test "Float: sound on generated programs (falsification)" {
    const gpa = std.testing.allocator;
    const s = try falsify.sweep(gpa, .none, programs, points);
    falsify.report("Float", s);
    for (std.enums.values(falsify.Kind)) |k| try gate("float", @tagName(k), s.failed.get(k));
}

test "Legalize: the planted arm swap goes red" {
    const s = try legalizeSweep(std.testing.allocator, true, planted_programs, planted_points);
    std.debug.print("air_passes planted legalize swap: {d} programs, {d} compared, {d} differ\n", .{ s.programs, s.compared, s.differ });
    try std.testing.expect(s.differ != 0);
}

test "Legalize: interp before and after agree bit for bit (metamorphic)" {
    const s = try legalizeSweep(std.testing.allocator, false, programs, points);
    std.debug.print("air_passes Legalize: {d} programs, {d} conversions pure, {d} speculate, {d} samples compared, {d} differ\n", .{ s.programs, s.pure, s.speculate, s.compared, s.differ });
    try gate("legalize", "bits", s.differ);
}

test "Setup: the planted claims go red" {
    const gpa = std.testing.allocator;
    const inv = try invarianceSweep(gpa, true, planted_programs, planted_points);
    std.debug.print("air_passes planted setup all-invariant: {d} programs, {d} sequences compared, {d} differ\n", .{ inv.programs, inv.compared, inv.differ });
    try std.testing.expect(inv.differ != 0);
    const held = try heldSweep(gpa, true, planted_programs, planted_points);
    std.debug.print("air_passes planted held all-pruned: {d} programs, {d} compared, {d} differ\n", .{ held.programs, held.compared, held.differ });
    try std.testing.expect(held.differ != 0);
}

test "Setup: invariant values take one value as the probes move" {
    const s = try invarianceSweep(std.testing.allocator, false, programs, setup_points);
    std.debug.print("air_passes Setup invariance: {d} programs, {d} values called invariant, {d} sequences compared, {d} differ\n", .{ s.programs, s.claimed, s.compared, s.differ });
    try gate("setup", "invariant", s.differ);
}

test "Setup: a pruned held slot is unobservable" {
    const s = try heldSweep(std.testing.allocator, false, programs, setup_points);
    std.debug.print("air_passes Setup held: {d} programs, {d} of {d} slots pruned, {d} evaluation pairs compared, {d} differ\n", .{ s.programs, s.pruned, s.programs * 3, s.compared, s.differ });
    try gate("held", "pruned", s.differ);
}
