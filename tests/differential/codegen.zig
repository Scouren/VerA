//! The differential oracle of codegen's Zig backend (docs/rewrite/codegen.md):
//! every `.va`/`.vams` fixture under the fixture root in, one line per
//! fixture whose old and new devices disagree out, and a failure unless
//! each disagreeing fixture is named in `codegen.xfail` (and each named one
//! still disagrees). Per fixture:
//! - a fixture `lower.xfail` names is diff-lower's business: skipped, counted;
//! - the OLD device: `vera.analyze` + `Result.generate`, every unit strict;
//!   the NEW device: Sema's `Air` + `Air.Device`, `Air.Float` over
//!   `codegen.floatRoots`, `codegen.generate` (strict, or versioned with
//!   `-Dcodegen-versioned`); a side that refuses the source is skipped and
//!   counted; codegen failing on the new side is a disagreement;
//! - both devices are built by `link` (ReleaseFast, LLVM), many fixtures to
//!   one library, under `codegen/dyn.zig`, loaded, and evaluated at `points`
//!   seeded points (every unknown in [-2, 2], every real parameter near its
//!   default inside its ranges, a time in [0, 1 ms]): the residual rows,
//!   their Jacobian, the reactive rows and theirs, bit for bit (NaN as NaN).
//! `-Dcodegen-filter=<substring>` runs only the fixtures whose path holds it;
//! `-Dcodegen-keep` keeps the devices (`zig-out/codegen-work/b<k>/{o,n}<j>.zig`).
//! No LRM clause: this checks VerA's rewrite against VerA.
//!
//! Contents: tests only.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const link = @import("link");
const DynLib = @import("dynlib").DynLib;
const options = @import("rewrite_options");
const sides = @import("codegen/sides.zig");

/// Seeded points per fixture.
const points = 1000;
/// Fixtures per library: each `zig` child analyses them all.
const batch_max = 24;
/// Parallel `zig` children (the machine is shared).
const jobs = 2;

/// `compareIsolated`'s end-of-run record.
const done: u32 = std.math.maxInt(u32);

/// The std_kernels transcendentals whose value is Gompute's where the old
/// text ran gm's (diff-kernels: log10 1 ulp apart; the inverse hyperbolics
/// and atan2 compose them). A family method (`.exp()`, `.cosh()`) is the
/// host's on both sides.
const libm_kernels = [_][]const u8{ "M.zLog10", "M.zAsinh", "M.zAcosh", "M.zAtanh", "M.zAtan2" };

/// How far apart a value reached through one of `libm_kernels` may be:
/// diff-lower's bound (a few ulps per operation, grown by the arithmetic
/// after them); a codegen bug is far past it.
const libm_ulps: u64 = 1 << 10;

const Tally = struct {
    fixtures: u32 = 0,
    lower_listed: u32 = 0,
    old_refused: u32 = 0,
    new_refused: u32 = 0,
    compared: u32 = 0,
    points: u64 = 0,
    values_libm: u64 = 0,
    agreed: u32 = 0,
    xfailed: u32 = 0,
    failed: u32 = 0,
    old_bytes: u64 = 0,
    new_bytes: u64 = 0,
    build_ns: u64 = 0,
    optimized: u32 = 0,
    roots: u32 = 0,
};

/// A fixture both sides wrote a device for.
const Ready = struct { rel: []const u8, old: []const u8, new: []const u8, card: sides.Card };

/// The C entry `dyn.zig` exports per device.
const RunFn = *const fn ([*]const [*:0]const u8, [*]const f64, u32, [*]const f64, u32, f64, [*]f64, u32) callconv(.c) i32;

// ---- private ----

fn run(result: *anyerror!void) void {
    result.* = runAll();
}

fn runAll() !void {
    const gpa = std.heap.smp_allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const xfail = try readList(arena, io, "tests/differential/codegen.xfail");
    const lower_listed = try readList(arena, io, "tests/differential/lower.xfail");
    const filter = options.codegen_filter;

    var tally: Tally = .{};
    var whys: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var ready: std.ArrayList(Ready) = .empty;
    const include = options.fixture_root ++ "/include";
    for (try collect(arena, io)) |rel| {
        if (filter.len != 0 and std.mem.find(u8, rel, filter) == null) continue;
        tally.fixtures += 1;
        if (lower_listed.contains(rel)) {
            tally.lower_listed += 1;
            continue;
        }
        const path = try std.fs.path.join(arena, &.{ options.fixture_root, rel });
        const dirs = [_][]const u8{ std.fs.path.dirname(path).?, include };
        const source = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 26));
        const old = (try sides.old(gpa, arena, path, source, &dirs)) orelse {
            tally.old_refused += 1;
            continue;
        };
        switch (try sides.new(gpa, arena, io, path, source, &dirs, !options.codegen_versioned)) {
            .refused => tally.new_refused += 1,
            .fail => |why| try whys.put(arena, rel, try arena.print("codegen: {s}", .{why})),
            .ok => |n| {
                tally.optimized += n.optimized;
                tally.roots += n.roots;
                try ready.append(arena, .{ .rel = rel, .old = old, .new = n.text, .card = n.card });
            },
        }
    }

    const work = try std.fs.path.join(arena, &.{ options.repo_root, "zig-out", "codegen-work" });
    var slots: [jobs]link.Server = undefined;
    var q: link.Queue = .init(&slots);
    var at: usize = 0;
    var batch: u32 = 0;
    while (at < ready.items.len) : (batch += 1) {
        const group = ready.items[at..@min(at + batch_max, ready.items.len)];
        at += group.len;
        try runBatch(gpa, arena, io, &q, work, batch, group, &tally, &whys);
    }
    if (!options.codegen_keep) Io.Dir.cwd().deleteTree(io, work) catch {};

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (whys.keys(), whys.values()) |rel, why| {
        if (xfail.contains(rel)) {
            tally.xfailed += 1;
        } else {
            tally.failed += 1;
            try out.writer.print("FAIL {s} {s}\n", .{ rel, why });
        }
    }
    var it = xfail.iterator();
    while (it.next()) |e| {
        const rel = e.key_ptr.*;
        if (filter.len != 0 and std.mem.find(u8, rel, filter) == null) continue;
        if (whys.contains(rel)) continue;
        tally.failed += 1;
        const agreed = for (ready.items) |r| {
            if (std.mem.eql(u8, r.rel, rel)) break true;
        } else false;
        try out.writer.print("{s} {s}: {s}\n", .{ if (agreed) "XPASS" else "STALE", rel, if (agreed) "agrees now; delete its codegen.xfail line" else "codegen.xfail names a fixture that was not compared" });
    }
    tally.agreed = tally.compared - countCompared(&whys, ready.items);
    std.debug.print("{s}diff-codegen: {d} fixtures ({d} named in lower.xfail, {d} the old side refused, {d} the new side refused), {d} built and compared at {d} points ({d} evaluations bit for bit, {d} values within the libm ulp bound), {d} agree, {d} in codegen.xfail, {d} failures; device text old {d} B, new {d} B; build {d} ms; roots .optimized {d}/{d}\n", .{
        out.written(),   tally.fixtures,  tally.lower_listed,                  tally.old_refused, tally.new_refused, tally.compared, points, tally.points, tally.values_libm, tally.agreed, tally.xfailed, tally.failed,
        tally.old_bytes, tally.new_bytes, tally.build_ns / std.time.ns_per_ms, tally.optimized,   tally.roots,
    });
    if (tally.failed != 0) return error.DiffCodegenFailed;
}

/// How many of `whys` are fixtures that were built and compared.
fn countCompared(whys: *const std.StringArrayHashMapUnmanaged([]const u8), ready: []const Ready) u32 {
    var n: u32 = 0;
    for (ready) |r| n += @intFromBool(whys.contains(r.rel));
    return n;
}

/// Builds one library of `group`'s old and new devices, loads it, and
/// compares each fixture's two at `points` points; a disagreement goes to
/// `whys`.
fn runBatch(gpa: Allocator, arena: Allocator, io: Io, q: *link.Queue, work: []const u8, batch: u32, group: []const Ready, tally: *Tally, whys: *std.StringArrayHashMapUnmanaged([]const u8)) !void {
    tally.compared += @intCast(group.len);
    const dir = try arena.print("{s}/b{d}", .{ work, batch });
    try Io.Dir.cwd().createDirPath(io, dir);
    defer if (!options.codegen_keep) Io.Dir.cwd().deleteTree(io, dir) catch {};
    const contract = try std.fs.path.join(arena, &.{ options.repo_root, "lib", "contract.zig" });
    const kernels = try std.fs.path.join(arena, &.{ options.repo_root, "lib", "std", "kernels.zig" });
    const dyn = try std.fs.path.join(arena, &.{ options.repo_root, "tests", "differential", "codegen", "dyn.zig" });
    var index: Io.Writer.Allocating = .init(arena);
    for (group, 0..) |r, k| {
        for ([2][]const u8{ "o", "n" }, [2][]const u8{ r.old, r.new }) |side, text|
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = try arena.print("{s}/{s}{d}.zig", .{ dir, side, k }), .data = text });
        try index.writer.print("{d} {s}\n", .{ k, r.rel });
        tally.old_bytes += r.old.len;
        tally.new_bytes += r.new.len;
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try arena.print("{s}/index.txt", .{dir}), .data = index.written() });
    // A device that does not build is named by its file in the compiler's
    // report, recorded, and left out of the next try: each try drops one at
    // least, so there is at most one per fixture.
    const left = try arena.alloc(bool, group.len);
    @memset(left, true);
    for (0..group.len + 1) |attempt| {
        var mods: std.ArrayList(link.Module) = .empty;
        try mods.appendSlice(arena, &.{
            .{ .name = "contract", .root = contract },
            .{ .name = "gompute_math", .root = options.gompute_math },
            .{ .name = "std_kernels", .root = kernels, .deps = &.{ "contract", "gompute_math" } },
            .{ .name = "dyn", .root = dyn, .deps = &.{"contract"} },
        });
        var devices: Io.Writer.Allocating = .init(arena);
        var names: Io.Writer.Allocating = .init(arena);
        for (left, 0..) |l, k| if (l) for ([2][]const u8{ "o", "n" }) |side| {
            const name = try arena.print("{s}{d}", .{ side, k });
            try mods.append(arena, .{ .name = name, .root = try arena.print("{s}/{s}.zig", .{ dir, name }), .deps = if (side[0] == 'o') &.{"contract"} else &.{ "contract", "std_kernels" } });
            try devices.writer.print(" @import(\"{s}\"),", .{name});
            try names.writer.print(" \"{s}\",", .{name});
        };
        if (names.written().len == 0) return;
        const bundle = try arena.print("pub const devices = .{{{s} }};\npub const names = .{{{s} }};\n", .{ devices.written(), names.written() });
        const f: link.File = .{ .kind = .so, .work_dir = dir, .name = try arena.print("cg{d}", .{attempt}), .optimize = .fast, .backend = .llvm, .modules = mods.items, .split = .whole };
        const t0 = Io.Clock.awake.now(io);
        var built = try f.flush(gpa, io, q, .{ .text = bundle }, 1);
        defer built.deinit(gpa);
        tally.build_ns += @intCast(t0.durationTo(Io.Clock.awake.now(io)).toNanoseconds());
        const lib_path = switch (built) {
            .ok => |p| p,
            .failed => |b| {
                if (!try blame(arena, b, group, left, whys)) {
                    var text: Io.Writer.Allocating = .init(arena);
                    try b.renderToWriter(.{}, &text.writer);
                    for (group, left) |r, l| if (l) try whys.put(arena, r.rel, try arena.print("the batch does not build: {s}", .{text.written()}));
                    return;
                }
                continue;
            },
        };
        var lib = try DynLib.open(lib_path);
        defer lib.close();
        for (group, left, 0..) |r, l, k| if (l) {
            const old_fn = lib.lookup(RunFn, try arena.printSentinel("cg_o{d}", .{k}, 0)).?;
            const new_fn = lib.lookup(RunFn, try arena.printSentinel("cg_n{d}", .{k}, 0)).?;
            if (try compareIsolated(arena, r, old_fn, new_fn, tally)) |why| try whys.put(arena, r.rel, why);
        };
        return;
    }
}

/// Records each device the compiler's report names (`o<k>.zig`/`n<k>.zig`)
/// as its fixture's disagreement and drops it from `left`; returns whether
/// the report named any.
fn blame(arena: Allocator, b: std.zig.ErrorBundle, group: []const Ready, left: []bool, whys: *std.StringArrayHashMapUnmanaged([]const u8)) !bool {
    var named = false;
    for (b.getMessages()) |m| {
        const msg = b.getErrorMessage(m);
        if (msg.src_loc == .none) continue;
        const loc = b.getSourceLocation(msg.src_loc);
        const base = std.fs.path.basename(b.nullTerminatedString(loc.src_path));
        if (base.len < 2 or (base[0] != 'o' and base[0] != 'n')) continue;
        const k = std.fmt.parseInt(usize, std.fs.path.stem(base)[1..], 10) catch continue;
        if (k >= group.len or !left[k]) continue;
        left[k] = false;
        named = true;
        try whys.put(arena, group[k].rel, try arena.print("the {s} device does not build: {s}:{d}: {s}", .{ if (base[0] == 'o') "old" else "new", base, loc.line + 1, b.nullTerminatedString(msg.msg) }));
    }
    return named;
}

/// `compare` in a child process, so a device that traps (an `@trap` on a
/// zero integer divisor, a safety check) is that fixture's disagreement,
/// not the oracle's end. The child writes a `u32` record before each call
/// (point << 1 | side), then `done`, the points it compared and the why.
fn compareIsolated(arena: Allocator, r: Ready, old_fn: RunFn, new_fn: RunFn, tally: *Tally) !?[]const u8 {
    const linux = std.os.linux;
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{})) != .SUCCESS) return error.PipeFailed;
    const pid: i32 = @bitCast(@as(u32, @truncate(linux.fork())));
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = linux.close(fds[0]);
        var counts: [2]u32 = .{ 0, 0 };
        const why = compare(arena, r, old_fn, new_fn, fds[1], &counts) catch "the oracle ran out of memory";
        const tail = [_]u32{ done, counts[0], counts[1] };
        _ = linux.write(fds[1], @ptrCast(&tail), @sizeOf(@TypeOf(tail)));
        if (why) |w| _ = linux.write(fds[1], w.ptr, w.len);
        linux.exit_group(0);
    }
    _ = linux.close(fds[1]);
    var got: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    // Bounded by what the child writes: two records per point and a why.
    while (true) {
        const k = linux.read(fds[0], &buf, buf.len);
        if (linux.errno(k) != .SUCCESS or k == 0) break;
        try got.appendSlice(arena, buf[0..k]);
    }
    _ = linux.close(fds[0]);
    var status: i32 = 0;
    _ = linux.waitpid(pid, &status, 0);
    const words = got.items.len / 4;
    var last: u32 = 0;
    for (0..words) |w| {
        const rec = std.mem.readInt(u32, got.items[4 * w ..][0..4], .little);
        if (rec == done and w + 2 < words) {
            tally.points += std.mem.readInt(u32, got.items[4 * w + 4 ..][0..4], .little);
            tally.values_libm += std.mem.readInt(u32, got.items[4 * w + 8 ..][0..4], .little);
            const why = got.items[4 * w + 12 ..];
            return if (why.len == 0) null else why;
        }
        last = rec;
    }
    return try arena.print("the {s} device stopped the process at point {d} (wait status 0x{x})", .{ if (last & 1 == 0) "old" else "new", last >> 1, status });
}

/// Evaluates both devices at `points` seeded points, writing a progress
/// record to `fd` before each call; returns the first difference, or null.
fn compare(arena: Allocator, r: Ready, old_fn: RunFn, new_fn: RunFn, fd: i32, counts: *[2]u32) !?[]const u8 {
    const libm = for (libm_kernels) |k| {
        if (std.mem.find(u8, r.new, k) != null) break true;
    } else false;
    const n = r.card.n_u;
    const len = 2 * n + 2 * n * n;
    const outs = [2][]f64{ try arena.alloc(f64, len), try arena.alloc(f64, len) };
    const x = try arena.alloc(f64, n);
    const vals = try arena.alloc(f64, r.card.names.len);
    const names = try arena.alloc([*:0]const u8, r.card.names.len);
    for (names, r.card.names) |*p, s| p.* = s.ptr;
    var prng: std.Random.DefaultPrng = .init(std.hash.Wyhash.hash(0, r.rel));
    const rand = prng.random();
    for (0..points) |p| {
        for (x) |*v| v.* = rand.float(f64) * 4 - 2;
        for (vals, r.card.defaults, r.card.ranges) |*v, def, ranges| v.* = drawIn(rand, def, ranges);
        const t = rand.float(f64) * 1e-3;
        for ([2]RunFn{ old_fn, new_fn }, outs, [2][]const u8{ "old", "new" }, 0..) |f, out, side, s| {
            const rec: u32 = @intCast(p << 1 | s);
            _ = std.os.linux.write(fd, @ptrCast(&rec), 4);
            const rc = f(names.ptr, vals.ptr, @intCast(vals.len), x.ptr, n, t, out.ptr, @intCast(len));
            if (rc != 0) return try arena.print("the {s} device's entry returned {d}", .{ side, rc });
        }
        for (outs[0], outs[1], 0..) |a, b, i| {
            if (sameBits(a, b)) continue;
            if (libm and ulpsApart(a, b) <= libm_ulps) {
                counts[1] += 1;
                continue;
            }
            const part, const at = if (i < n) .{ "row", i } else if (i < n + n * n) .{ "d row", i - n } else if (i < 2 * n + n * n) .{ "q row", i - n - n * n } else .{ "d q row", i - 2 * n - n * n };
            return try arena.print("point {d}: {s} {d}: old {e}, new {e}", .{ p, part, at, a, b });
        }
        counts[0] += 1;
    }
    return null;
}

/// How many representable doubles lie between `a` and `b`; max for a NaN
/// against a number or a sign change.
fn ulpsApart(a: f64, b: f64) u64 {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.maxInt(u64);
    if ((a < 0) != (b < 0)) return if (a == 0 and b == 0) 0 else std.math.maxInt(u64);
    const x: i64 = @bitCast(@abs(a));
    const y: i64 = @bitCast(@abs(b));
    return @abs(x - y);
}

fn sameBits(a: f64, b: f64) bool {
    if (std.math.isNan(a) and std.math.isNan(b)) return true;
    return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
}

/// A value near `def` inside every `from` range, outside every `exclude`
/// (diff-lower's draw); `def` when none is found.
fn drawIn(rand: std.Random, def: f64, ranges: []const @import("air").Device.Range) f64 {
    for (0..16) |_| {
        const x = def * (0.5 + rand.float(f64)) + (rand.float(f64) - 0.5) * 1e-3;
        if (admits(x, ranges)) return x;
    }
    return def;
}

fn admits(x: f64, ranges: []const @import("air").Device.Range) bool {
    for (ranges) |r| {
        if (r.strings) continue;
        const lo = r.lo orelse -std.math.inf(f64);
        const hi = r.hi orelse std.math.inf(f64);
        const in = (if (r.lo_closed) x >= lo else x > lo) and (if (r.hi_closed) x <= hi else x < hi);
        if (in == r.exclude) return false;
    }
    return true;
}

/// The fixture paths a list file names (`<path> <reason>` lines, `#`
/// comments).
fn readList(arena: Allocator, io: Io, rel: []const u8) !std.StringHashMapUnmanaged(void) {
    const path = try std.fs.path.join(arena, &.{ options.repo_root, rel });
    const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 22));
    var set: std.StringHashMapUnmanaged(void) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.findScalar(u8, line, ' ') orelse return error.ListLineHasNoReason;
        try set.put(arena, line[0..sp], {});
    }
    return set;
}

/// Every `.va`/`.vams` fixture path relative to the fixture root, sorted.
fn collect(arena: Allocator, io: Io) ![]const []const u8 {
    var dir = try Io.Dir.cwd().openDir(io, options.fixture_root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var list: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.path);
        if (!std.mem.eql(u8, ext, ".va") and !std.mem.eql(u8, ext, ".vams")) continue;
        try list.append(arena, try arena.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return list.items;
}

test "diff-codegen: the new device computes the old device's rows, Jacobians and charges" {
    var result: anyerror!void = {};
    // The old lowering recurses with the tree.
    const t = try std.Thread.spawn(.{ .stack_size = 256 << 20 }, run, .{&result});
    t.join();
    try result;
}
