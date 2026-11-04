//! The differential oracle of codegen's Zig backend (docs/rewrite/codegen.md):
//! every `.va`/`.vams` fixture under the fixture root in, one line per
//! fixture whose old and new devices disagree out, and a failure unless
//! each disagreeing fixture is named in `codegen.xfail` (and each named one
//! still disagrees). Per fixture:
//! - a fixture `lower.xfail` names is diff-lower's business: skipped, counted;
//! - the OLD device: `vera.analyze` + `Result.generate`, every unit strict;
//!   the NEW device: Sema's `Air` + `Air.Device`, `Air.Float` over
//!   `codegen.floatRoots`, `codegen.generate` strict, and again versioned
//!   (§11.9) when a root is `.optimized`: the VERSIONED device, held to the
//!   old one bit for bit outside its box, within `fast_ulps` inside it, and
//!   red when no point lands inside; a side that refuses the source is
//!   skipped and counted; codegen failing on the new side is a disagreement;
//! - both devices are built by `link` (ReleaseFast, LLVM), each side's
//!   devices of a batch to one library, under `codegen/dyn.zig` (which holds
//!   every device to `contract.validate`), loaded, and evaluated in a forked
//!   child at `points` seeded points (every unknown in [-2, 2], every fourth
//!   point in [-40, 40], past the versioned units' default box; every real
//!   parameter near its default inside its ranges; a time in [0, 1 ms]):
//!   the residual rows, their Jacobian (with `jac_const`), the reactive rows
//!   and theirs, bit for bit (NaN as NaN), save the named libm and fast-math
//!   ulp bounds below; where a side stops the process (§4.2.4's zero
//!   divisor), every side must stop there by the same signal, and the run
//!   goes on past the point;
//! - the bsource stack (`codegen.examples.stack`) against `Air.interp`, and
//!   the contract's hosts (`tests/host`) on the new devices of their
//!   fixtures (build/rewrite.zig's `codegenHosts`).
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

/// What a child counted: points compared, values within the libm bound,
/// points inside a versioned unit's box, points outside it, and the most
/// ulps a value inside moved.
const Counts = [counts_len]u32;
const counts_len = 5;

/// How far a value the fast-math body computed may move from the strict
/// one: reassociation and contraction under `@setFloatMode(.optimized)`.
/// The measured maximum is reported; a lowering bug is far past it.
const fast_ulps: u64 = 1 << 20;

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
    inside: u64 = 0,
    outside: u64 = 0,
    fast_ulps: u32 = 0,
    /// Points where every side stopped alike (`compareIsolated`).
    stops: u32 = 0,
    agreed: u32 = 0,
    xfailed: u32 = 0,
    failed: u32 = 0,
    old_bytes: u64 = 0,
    new_bytes: u64 = 0,
    old_ns: u64 = 0,
    new_ns: u64 = 0,
    optimized: u32 = 0,
    roots: u32 = 0,
};

/// A fixture both sides wrote a device for.
const Ready = struct { rel: []const u8, old: []const u8, new: []const u8, ver: ?[]const u8, card: sides.Card };

/// The C entry `dyn.zig` exports per device.
const RunFn = *const fn ([*]const [*:0]const u8, [*]const f64, u32, [*]const f64, u32, f64, u32, [*]f64, u32) callconv(.c) i32;

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
        switch (try sides.new(gpa, arena, io, path, source, &dirs)) {
            .refused => tally.new_refused += 1,
            .fail => |why| try whys.put(arena, rel, try arena.print("codegen: {s}", .{why})),
            .ok => |n| {
                tally.optimized += n.optimized;
                tally.roots += n.roots;
                try ready.append(arena, .{ .rel = rel, .old = old, .new = n.text, .ver = n.versioned, .card = n.card });
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
            if (options.codegen_why) try out.writer.print("LISTED {s} {s}\n", .{ rel, why });
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
    std.debug.print("{s}diff-codegen: {d} fixtures ({d} named in lower.xfail, {d} the old side refused, {d} the new side refused), {d} built and compared at {d} points ({d} evaluations bit for bit, {d} values within the libm ulp bound), {d} agree, {d} in codegen.xfail, {d} failures; device text old {d} B, new {d} B (median per device old {d} B, new {d} B); build old {d} ms, new {d} ms; roots .optimized {d}/{d}; versioned units: {d} points inside the box (at most {d} ulps apart), {d} outside (bit for bit); {d} points where every side stopped alike\n", .{
        out.written(),   tally.fixtures,  tally.lower_listed,                   tally.old_refused,                    tally.new_refused,                 tally.compared,                    points,          tally.points, tally.values_libm, tally.agreed,    tally.xfailed, tally.failed,
        tally.old_bytes, tally.new_bytes, try median(arena, ready.items, .old), try median(arena, ready.items, .new), tally.old_ns / std.time.ns_per_ms, tally.new_ns / std.time.ns_per_ms, tally.optimized, tally.roots,  tally.inside,      tally.fast_ulps, tally.outside, tally.stops,
    });
    if (tally.failed != 0) return error.DiffCodegenFailed;
}

/// The median text size of one side's devices.
fn median(arena: Allocator, ready: []const Ready, comptime side: enum { old, new }) !usize {
    if (ready.len == 0) return 0;
    const sizes = try arena.alloc(usize, ready.len);
    for (sizes, ready) |*s, r| s.* = @field(r, @tagName(side)).len;
    std.mem.sort(usize, sizes, {}, std.sort.asc(usize));
    return sizes[sizes.len / 2];
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
        for ([3][]const u8{ "o", "n", "v" }, [3]?[]const u8{ r.old, r.new, r.ver }) |side, text| if (text) |t|
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = try arena.print("{s}/{s}{d}.zig", .{ dir, side, k }), .data = t });
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
        // One library per side, so each side's build time is its own.
        var paths: [2][]const u8 = undefined;
        var failed = false;
        for ([2][]const u8{ "o", "n" }, &paths, [2]*u64{ &tally.old_ns, &tally.new_ns }) |side, *path, ns| {
            var mods: std.ArrayList(link.Module) = .empty;
            try mods.appendSlice(arena, &.{
                .{ .name = "contract", .root = contract },
                .{ .name = "gompute_math", .root = options.gompute_math },
                .{ .name = "std_kernels", .root = kernels, .deps = &.{ "contract", "gompute_math" } },
                .{ .name = "dyn", .root = dyn, .deps = &.{"contract"} },
            });
            var devices: Io.Writer.Allocating = .init(arena);
            var names: Io.Writer.Allocating = .init(arena);
            for (left, group, 0..) |l, r, k| if (l) for ([2]u8{ side[0], 'v' }) |c| {
                // The versioned device rides in the new side's library.
                if (c == 'v' and (side[0] == 'o' or r.ver == null)) continue;
                const name = try arena.print("{c}{d}", .{ c, k });
                try mods.append(arena, .{ .name = name, .root = try arena.print("{s}/{s}.zig", .{ dir, name }), .deps = if (c == 'o') &.{"contract"} else &.{ "contract", "std_kernels" } });
                try devices.writer.print(" @import(\"{s}\"),", .{name});
                try names.writer.print(" \"{s}\",", .{name});
            };
            if (names.written().len == 0) return;
            const bundle = try arena.print("pub const devices = .{{{s} }};\npub const names = .{{{s} }};\n", .{ devices.written(), names.written() });
            const f: link.File = .{ .kind = .so, .work_dir = dir, .name = try arena.print("cg{d}{s}", .{ attempt, side }), .optimize = .fast, .backend = .llvm, .modules = mods.items, .split = .whole };
            const t0 = Io.Clock.awake.now(io);
            var built = try f.flush(gpa, io, q, .{ .text = bundle }, 1);
            defer built.deinit(gpa);
            ns.* += @intCast(t0.durationTo(Io.Clock.awake.now(io)).toNanoseconds());
            switch (built) {
                .ok => |lp| path.* = try arena.dupe(u8, lp),
                .failed => |rep| {
                    if (!try blame(arena, rep, group, left, whys)) {
                        var text: Io.Writer.Allocating = .init(arena);
                        try rep.renderToWriter(.{}, &text.writer);
                        for (group, left) |r, l| if (l) try whys.put(arena, r.rel, try arena.print("the batch does not build: {s}", .{text.written()}));
                        return;
                    }
                    failed = true;
                    break;
                },
            }
        }
        if (failed) continue;
        var libs = [2]DynLib{ try DynLib.open(paths[0]), try DynLib.open(paths[1]) };
        defer for (&libs) |*lib| lib.close();
        for (group, left, 0..) |r, l, k| if (l) {
            const old_fn = libs[0].lookup(RunFn, try arena.printSentinel("cg_o{d}", .{k}, 0)).?;
            const new_fn = libs[1].lookup(RunFn, try arena.printSentinel("cg_n{d}", .{k}, 0)).?;
            const ver_fn = if (r.ver != null) libs[1].lookup(RunFn, try arena.printSentinel("cg_v{d}", .{k}, 0)).? else null;
            const NuFn = *const fn () callconv(.c) u32;
            const nu = [2]u32{ libs[0].lookup(NuFn, try arena.printSentinel("cg_o{d}_nu", .{k}, 0)).?(), libs[1].lookup(NuFn, try arena.printSentinel("cg_n{d}_nu", .{k}, 0)).?() };
            if (nu[0] != nu[1]) {
                try whys.put(arena, r.rel, try arena.print("the unknowns differ: old {d}, new {d}", .{ nu[0], nu[1] }));
                continue;
            }
            var rn = r;
            rn.card.n_u = nu[0];
            if (try compareIsolated(arena, rn, old_fn, new_fn, ver_fn, tally)) |why| try whys.put(arena, r.rel, why);
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
        if (base.len < 2 or (base[0] != 'o' and base[0] != 'n' and base[0] != 'v')) continue;
        const k = std.fmt.parseInt(usize, std.fs.path.stem(base)[1..], 10) catch continue;
        if (k >= group.len or !left[k]) continue;
        left[k] = false;
        named = true;
        try whys.put(arena, group[k].rel, try arena.print("the {s} device does not build: {s}:{d}: {s}", .{ switch (base[0]) {
            'o' => "old",
            'n' => "new",
            else => "versioned",
        }, base, loc.line + 1, b.nullTerminatedString(msg.msg) }));
    }
    return named;
}

/// `compare` in a child process, so a device that stops (§4.2.4's zero
/// integer divisor reaches a safety check) is compared like a value: where
/// one side stops, every side must stop, by the same signal; the run then
/// resumes past the point in a new child, every side from a fresh instance
/// (`dyn.zig`), so each point is evaluated a bounded number of times. A
/// side that stops alone is the fixture's disagreement. Bounded: each
/// resume starts past a new point of `stops`.
fn compareIsolated(arena: Allocator, r: Ready, old_fn: RunFn, new_fn: RunFn, ver_fn: ?RunFn, tally: *Tally) !?[]const u8 {
    const sides_n: u2 = if (ver_fn != null) 3 else 2;
    const side_names = [3][]const u8{ "old", "new", "versioned" };
    var stops: std.ArrayList(u32) = .empty;
    for (0..points + 1) |_| {
        const start: u32 = if (stops.items.len == 0) 0 else stops.items[stops.items.len - 1] + 1;
        const first = try child(arena, r, old_fn, new_fn, ver_fn, stops.items, start, null);
        const stop = switch (first) {
            .done => |d| {
                tally.points += d.counts[0];
                tally.values_libm += d.counts[1];
                tally.inside += d.counts[2];
                tally.outside += d.counts[3];
                tally.fast_ulps = @max(tally.fast_ulps, d.counts[4]);
                tally.stops += @intCast(stops.items.len);
                return d.why;
            },
            .stopped => |st| st,
        };
        const p = stop.rec >> 2;
        const side: u2 = @intCast(stop.rec & 3);
        for (0..sides_n) |o| {
            if (o == side) continue;
            const other = try child(arena, r, old_fn, new_fn, ver_fn, stops.items, start, .{ .point = p, .side = @intCast(o) });
            switch (other) {
                .done => return try arena.print("the {s} device stopped the process at point {d} (wait status 0x{x}), the {s} device did not", .{ side_names[side], p, stop.status, side_names[o] }),
                .stopped => |os| if (os.rec != (stop.rec & ~@as(u32, 3)) | @as(u32, @intCast(o)) or os.status != stop.status)
                    return try arena.print("at point {d} the {s} device stopped (wait status 0x{x}), the {s} device stopped at record 0x{x} (wait status 0x{x})", .{ p, side_names[side], stop.status, side_names[o], os.rec, os.status }),
            }
        }
        try stops.append(arena, p);
    }
    unreachable; // every rerun adds a distinct point below `points`
}

/// A probe: evaluate the points from `start` to `point`, then only `side`.
const Probe = struct { point: u32, side: u2 };

const ChildRun = union(enum) {
    done: struct { counts: Counts, why: ?[]const u8 },
    stopped: struct { rec: u32, status: u32 },
};

/// Runs `compare` in a forked child. The child writes a `u32` record
/// before each call (point << 2 | side), then `done`, its counts and the
/// why; a child that dies leaves its last record.
fn child(arena: Allocator, r: Ready, old_fn: RunFn, new_fn: RunFn, ver_fn: ?RunFn, stops: []const u32, start: u32, probe: ?Probe) !ChildRun {
    const linux = std.os.linux;
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{})) != .SUCCESS) return error.PipeFailed;
    const pid: i32 = @bitCast(@as(u32, @truncate(linux.fork())));
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = linux.close(fds[0]);
        // A stopping device is expected here: no core dump (each one took
        // seconds and a share of the machine's coredump store).
        _ = linux.prctl(@backingInt(linux.PR.SET_DUMPABLE), 0, 0, 0, 0);
        var counts: Counts = .{ 0, 0, 0, 0, 0 };
        const why = compare(arena, r, old_fn, new_fn, ver_fn, fds[1], &counts, stops, start, probe) catch "the oracle ran out of memory";
        const tail = [_]u32{done} ++ counts;
        _ = linux.write(fds[1], @ptrCast(&tail), @sizeOf(@TypeOf(tail)));
        if (why) |w| _ = linux.write(fds[1], w.ptr, w.len);
        linux.exit_group(0);
    }
    _ = linux.close(fds[1]);
    var got: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    // Bounded by what the child writes: three records per point and a why.
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
        if (rec == done and w + counts_len < words) {
            var counts: Counts = undefined;
            for (&counts, 0..) |*c, i| c.* = std.mem.readInt(u32, got.items[4 * (w + 1 + i) ..][0..4], .little);
            const why = got.items[4 * (w + 1 + counts_len) ..];
            return .{ .done = .{ .counts = counts, .why = if (why.len == 0) null else why } };
        }
        last = rec;
    }
    return .{ .stopped = .{ .rec = last, .status = @bitCast(status) } };
}

/// Evaluates both devices at `points` seeded points, writing a progress
/// record to `fd` before each call; returns the first difference, or null.
fn compare(arena: Allocator, r: Ready, old_fn: RunFn, new_fn: RunFn, ver_fn: ?RunFn, fd: i32, counts: *Counts, stops: []const u32, start: u32, probe: ?Probe) !?[]const u8 {
    const libm = for (libm_kernels) |k| {
        if (std.mem.find(u8, r.new, k) != null) break true;
    } else false;
    const n = r.card.n_u;
    const len = 2 * n + 2 * n * n;
    const outs = [3][]f64{ try arena.alloc(f64, len), try arena.alloc(f64, len), try arena.alloc(f64, len) };
    const x = try arena.alloc(f64, n);
    const vals = try arena.alloc(f64, r.card.names.len);
    const names = try arena.alloc([*:0]const u8, r.card.names.len);
    for (names, r.card.names) |*p, s| p.* = s.ptr;
    var prng: std.Random.DefaultPrng = .init(std.hash.Wyhash.hash(0, r.rel));
    const rand = prng.random();
    const args = try arena.dupe(f64, r.card.args);
    const sides_n: usize = if (ver_fn != null) 3 else 2;
    for (0..points) |p| {
        // Every fourth point reaches past `default_unknown_bound` (10), so
        // a versioned unit's strict body runs there.
        const span: f64 = if (p % 4 == 3) 80 else 4;
        for (x) |*v| v.* = (rand.float(f64) - 0.5) * span;
        for (vals, r.card.defaults, r.card.ranges) |*v, def, ranges| v.* = drawIn(rand, def, ranges);
        for (r.card.arg_of, vals) |k, v| args[k] = v;
        // A transient: the points in time order, each accepted.
        const t = @as(f64, @floatFromInt(p)) * 1e-6;
        _ = rand.float(f64);
        // The versioned device's fast body runs inside the box: its values
        // may move by fast-math's reassociation, bounded by `fast_ulps`;
        // outside, its strict body runs and every bit must match.
        const inside = if (r.card.box) |box| admitted(box, x, args) else false;
        if (ver_fn != null) counts[if (inside) 2 else 3] += 1;
        // A point where every side stops is drawn but not evaluated.
        if (std.mem.findScalar(u32, stops, @intCast(p)) != null) continue;
        // An earlier child compared it (only the libm and ulp tallies are lost).
        if (p < start) {
            counts[0] += 1;
            continue;
        }
        const fns = [3]?RunFn{ old_fn, new_fn, ver_fn };
        if (probe) |pr| if (pr.point == p) {
            const rec: u32 = @intCast(p << 2 | pr.side);
            _ = std.os.linux.write(fd, @ptrCast(&rec), 4);
            _ = fns[pr.side].?(names.ptr, vals.ptr, @intCast(vals.len), x.ptr, n, t, @intCast(p), outs[pr.side].ptr, @intCast(len));
            return null;
        };
        for (fns[0..sides_n], outs[0..sides_n], ([3][]const u8{ "old", "new", "versioned" })[0..sides_n], 0..) |f, out, side, s| {
            const rec: u32 = @intCast(p << 2 | s);
            _ = std.os.linux.write(fd, @ptrCast(&rec), 4);
            const rc = f.?(names.ptr, vals.ptr, @intCast(vals.len), x.ptr, n, t, @intCast(p), out.ptr, @intCast(len));
            if (rc != 0) return try arena.print("the {s} device's entry returned {d} (card: {s})", .{ side, rc, try std.mem.join(arena, ",", @ptrCast(r.card.names)) });
        }
        for (1..sides_n) |s| for (outs[0], outs[s], 0..) |a, b, i| {
            if (sameBits(a, b)) continue;
            const apart = ulpsApart(a, b);
            if (libm and apart <= libm_ulps) {
                counts[1] += 1;
                continue;
            }
            if (s == 2 and inside and apart <= fast_ulps) {
                counts[4] = @max(counts[4], @as(u32, @intCast(apart)));
                continue;
            }
            const part, const at = if (i < n) .{ "row", i } else if (i < n + n * n) .{ "d row", i - n } else if (i < 2 * n + n * n) .{ "q row", i - n - n * n } else .{ "d q row", i - 2 * n - n * n };
            return try arena.print("point {d}: {s} {d}: old {e}, {s} {e}{s}", .{ p, part, at, a, if (s == 1) "new" else "versioned", b, if (s == 2 and !inside) " (outside the box: the strict body ran)" else "" });
        };
        counts[0] += 1;
    }
    // A device versioned on a box no point reached proved nothing.
    if (ver_fn != null and counts[2] == 0) return "the versioned device's box admitted none of the points";
    return null;
}

/// Whether every guard of `box` admits the point (`Float.Guard.admits`, the
/// check the device's entry makes): a probe reads `x`, an `arg` `args`.
fn admitted(box: []const @import("air").Float.Guard, x: []const f64, args: []const f64) bool {
    for (box) |g| if (!g.admits(switch (g.leaf) {
        .probe => x[g.index],
        .arg => args[g.index],
    })) return false;
    return true;
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

test "§11.10 the bsource stack device (a written-element mask, no memset) computes Air.interp's values" {
    // Oracle: Air.interp over the same body, bit for bit, and the Jacobian
    // by hand: I(p, n) = V(p)V(n) + V(n), so dI/dV(p) = V(n), dI/dV(n) =
    // V(p) + 1. Row m holds only st[5] (read before any write), st[20] and
    // st[-1] (outside the array): exactly +0, so a read of an unwritten
    // element's storage shows whole there (red-checked: reading storage
    // without its mask bit fails here, not in the p row, where a garbage
    // 1e-103 rounds away).
    const Air = @import("air");
    const contract = @import("contract");
    const D = @import("scratch_device");
    const gpa = std.testing.allocator;
    var ip: @import("intern_pool") = try .init(gpa);
    defer ip.deinit(gpa);
    var e = try @import("codegen").examples.stack(gpa, &ip);
    defer e.deinit(gpa);
    const S = contract.RefFamily(f64, &std.simd.iota(u8, 3), .{});
    const Watch = struct {
        slots: [2]Air.Inst.Index,
        air: *const Air,
        last: [2]f64 = .{ std.math.nan(f64), std.math.nan(f64) },
        fn seen(ctx: *anyopaque, inst: Air.Inst.Index, v: Air.interp.Value) void {
            const w: *@This() = @ptrCast(@alignCast(ctx));
            const i = @backingInt(inst);
            if (w.air.instructions.items(.tag)[i] != .assign) return;
            const lhs = w.air.instructions.items(.data)[i].bin_op.lhs.toIndex();
            for (w.slots, &w.last) |slot, *l| if (lhs == slot) {
                l.* = v.real;
            };
        }
    };
    var prng: std.Random.DefaultPrng = .init(0x5c7a7c4);
    const rand = prng.random();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const resist = e.device.contributions.items(.resist);
    for (0..points) |_| {
        _ = arena.reset(.retain_capacity);
        const x = [3]f64{ (rand.float(f64) - 0.5) * 8, (rand.float(f64) - 0.5) * 8, rand.float(f64) };
        var w: Watch = .{ .slots = .{ resist[0], resist[1] }, .air = &e.air };
        _ = try Air.interp.run(arena.allocator(), e.air, &ip, .{ .probes = &x, .loop_cap = 16, .observe = .{ .ctx = &w, .seen = Watch.seen } });
        const m: D.Model = .{};
        const inst: D.Instance = .{};
        const r = D.eval(S, &x, &m, &inst, .{});
        try std.testing.expectEqual(@as(u64, @bitCast(0.0 + w.last[0])), @as(u64, @bitCast(r[0].val())));
        try std.testing.expectEqual(@as(u64, @bitCast(0.0 - w.last[0])), @as(u64, @bitCast(r[1].val())));
        try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 0.0))), @as(u64, @bitCast(w.last[1])));
        try std.testing.expectEqual(@as(u64, @bitCast(0.0 + w.last[1])), @as(u64, @bitCast(r[2].val())));
        const jp = contract.denseRow(3, r[0]);
        try std.testing.expectEqual(x[1], jp[0]);
        try std.testing.expectEqual(x[0] + 1, jp[1]);
    }
}
