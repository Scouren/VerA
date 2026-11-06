//! The end-to-end oracle of the rewrite (`zig build diff-comp`,
//! docs/rewrite/comp.md): every conformance test under the fixture root,
//! run by `vera` and by `vera-next` with the command line the suite's own
//! harness gives it (`comp/fixture.zig`), each in a fresh directory, and
//! compared on exit status, stderr byte for byte, stdout and every file
//! written (`comp/judge.zig`). A disagreement is a line of `comp.xfail`
//! (`<path> <owner>: <reason>`, covering it only while that owner's
//! difference is the first; a -j1/-jN difference is never covered), or a ruling of `comp.rulings` (`<path>
//! <clause>`: the old side is wrong and the new one agrees with the
//! fixture's own verdict, its `//! reject` or its gold). A fixture whose
//! input needs a backend `vera-next` has not got (exit status 126) is
//! compared no further: its line names the backend. A listed fixture that
//! agrees, or that is not in the corpus, fails the run until its line goes.
//! Determinism: `-Dcomp-j1=N` fixtures' new side runs again at `--jobs=1`
//! and must write the same bytes as at the CPU count.
//! `-Dcomp-filter=` runs a subset; `-Dcomp-rebaseline` writes every
//! disagreement to `zig-out/<list>.xfail.new` instead of failing.
//! The `.v` backends' runs (`v_options`: diff-digital-exe, diff-rtlil,
//! diff-digital-device) take every `.v` fixture through `--emit-exe` (then
//! the binary it built), `--emit-rtlil` or `--check` in place of `--run`,
//! each against its own list (`tests/differential/<name>.xfail`) and
//! rulings (`<name>.rulings`); a `--check` ruling's tiebreaker runs the
//! device the new side builds (`comp/device.zig`).
//! No LRM clause: this checks VerA's rewrite against VerA.
//!
//! Contents: tests only.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const options = @import("comp_options");
/// Which run this is: `flag` replaces a `.v` fixture's `--run`/`--elab`
/// ("" for diff-comp itself) and `name` is its xfail list's.
const v_run = @import("v_options");
const fixture = @import("comp/fixture.zig");
const judge = @import("comp/judge.zig");
const device = @import("comp/device.zig");
const Fixture = fixture.Fixture;

/// One fixture's outcome.
const Outcome = union(enum) {
    pending,
    agree,
    /// The backend `vera-next` named.
    not_built: []const u8,
    differ: struct { owner: []const u8, why: []const u8 },
    /// `--jobs=1` wrote other bytes than the CPU count did.
    nondeterministic: []const u8,
    /// A `comp.rulings` line settled the difference: the old side is wrong
    /// and the new one meets the fixture's own verdict.
    ruled: []const u8,
};

/// The shared state of one run, read by every worker.
const Shared = struct {
    io: Io,
    fixtures: []const Fixture,
    outcomes: []Outcome,
    next: std.atomic.Value(u32) = .init(0),
    env: *const std.process.Environ.Map,
    work: []const u8,
    exe_old: []const u8,
    exe_new: []const u8,
    /// Every `j1_every`-th compared fixture runs again at `--jobs=1`.
    j1_every: u32,
    lock: std.Io.Mutex = .init,
    failed: ?anyerror = null,
    /// `comp.rulings`: fixture to the clause that settles it.
    rulings: std.StringHashMapUnmanaged([]const u8),
};

// ---- private ----

fn runAll() !void {
    const gpa = std.heap.smp_allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const all = try fixture.collect(arena, io, options.fixture_root);
    var picked: std.ArrayList(Fixture) = .empty;
    for (all) |f| if (options.filter.len == 0 or std.mem.find(u8, f.rel, options.filter) != null) {
        if (v_run.flag.len == 0 or f.lang == .verilog) try picked.append(arena, f);
    };
    const env = try arena.create(std.process.Environ.Map);
    env.* = try std.testing.environ.createMap(arena);
    const work = try std.fs.path.join(arena, &.{ options.repo_root, "zig-out", "comp-work" });
    try env.put("ZIG_LOCAL_CACHE_DIR", try std.fs.path.join(arena, &.{ options.repo_root, "zig-out", "comp-zig-cache" }));
    const outcomes = try arena.alloc(Outcome, picked.items.len);
    @memset(outcomes, .pending);
    var shared: Shared = .{
        .io = io,
        .fixtures = picked.items,
        .outcomes = outcomes,
        .env = env,
        .work = work,
        // Absolute: each child runs in a directory of its own.
        .exe_old = try Io.Dir.cwd().realPathFileAlloc(io, options.vera, arena),
        .exe_new = try Io.Dir.cwd().realPathFileAlloc(io, options.vera_next, arena),
        .rulings = try readRulings(arena, io),
        .j1_every = if (options.j1_sample == 0 or v_run.flag.len != 0) std.math.maxInt(u32) else @max(1, @as(u32, @intCast(picked.items.len)) / options.j1_sample),
    };
    const t0 = Io.Clock.awake.now(io);
    const threads = try arena.alloc(std.Thread, @max(1, options.jobs));
    for (threads) |*t| t.* = try std.Thread.spawn(.{}, worker, .{&shared});
    for (threads) |t| t.join();
    if (shared.failed) |e| return e;
    Io.Dir.cwd().deleteTree(io, work) catch {};
    const secs = @divTrunc(t0.durationTo(Io.Clock.awake.now(io)).toNanoseconds(), std.time.ns_per_s);
    try report(arena, io, picked.items, outcomes, @intCast(secs));
}

fn worker(s: *Shared) void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena_state.deinit();
    // Bounded by the fixture count: each turn takes one index.
    while (true) {
        const k = s.next.fetchAdd(1, .monotonic);
        if (k >= s.fixtures.len) return;
        _ = arena_state.reset(.retain_capacity);
        const out = one(arena_state.allocator(), s, k) catch |e| {
            s.lock.lockUncancelable(s.io);
            defer s.lock.unlock(s.io);
            s.failed = e;
            return;
        };
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        s.outcomes[k] = switch (out) {
            .pending, .agree => out,
            .not_built => |b| .{ .not_built = std.heap.smp_allocator.dupe(u8, b) catch "?" },
            .differ => |d| .{ .differ = .{ .owner = std.heap.smp_allocator.dupe(u8, d.owner) catch "?", .why = std.heap.smp_allocator.dupe(u8, d.why) catch "?" } },
            .nondeterministic => |w| .{ .nondeterministic = std.heap.smp_allocator.dupe(u8, w) catch "?" },
            .ruled => |w| .{ .ruled = std.heap.smp_allocator.dupe(u8, w) catch "?" },
        };
    }
}

/// Runs fixture `k` through both drivers (the new one first: a fixture
/// it cannot build costs the old side nothing).
fn one(arena: Allocator, s: *Shared, k: u32) !Outcome {
    const f = s.fixtures[k];
    if (f.lang == .vpi) return .{ .not_built = "vpi" };
    const args = try arena.dupe([]const u8, try fixture.argv(arena, f, options.fixture_root));
    if (v_run.flag.len != 0) args[0] = v_run.flag;
    const exec = std.mem.eql(u8, v_run.flag, "--emit-exe");
    const w_new = try std.fmt.allocPrint(arena, "{s}/{d}-n", .{ s.work, k });
    var new = try judge.run(arena, s.io, s.exe_new, args, w_new, s.env, exec);
    if (judge.notBuilt(new)) |b| return .{ .not_built = b };
    if (k % s.j1_every == 0) {
        const one_job = try std.mem.concat(arena, []const u8, &.{ &.{"--jobs=1"}, args });
        const again = try judge.run(arena, s.io, s.exe_new, one_job, w_new, s.env, exec);
        if (try judge.compare(arena, new, again, f.lang == .verilog)) |why| return .{ .nondeterministic = why };
    }
    const w_old = try std.fmt.allocPrint(arena, "{s}/{d}-o", .{ s.work, k });
    var old = try judge.run(arena, s.io, s.exe_old, args, w_old, s.env, exec);
    // Paths under the fixture root read the same on both sides; the
    // reasons `comp.xfail` keeps name them relative, whatever checkout ran.
    const root = options.fixture_root ++ "/";
    old.stderr = try std.mem.replaceOwned(u8, arena, old.stderr, root, "");
    new.stderr = try std.mem.replaceOwned(u8, arena, new.stderr, root, "");
    const why = (try judge.compare(arena, old, new, f.lang == .verilog)) orelse return .agree;
    if (s.rulings.get(f.rel)) |clause| {
        const miss: ?[]const u8 = if (std.mem.eql(u8, v_run.flag, "--check"))
            try deviceTiebreak(arena, s, f, new, args, try std.fmt.allocPrint(arena, "{s}/{d}-d", .{ s.work, k }))
        else if (try tiebreak(arena, s.io, f, new)) null else "the new side misses the fixture's own verdict";
        if (miss == null) return .{ .ruled = clause };
        return .{ .differ = .{ .owner = v_run.name ++ ".rulings", .why = try std.fmt.allocPrint(arena, "the ruling ({s}) does not hold: {s}; {s}", .{ clause, miss.?, why }) } };
    }
    return .{ .differ = .{ .owner = try judge.owner(arena, old, new, f.lang == .verilog), .why = why } };
}

/// Holds the outcomes to `comp.xfail` and `comp.rulings`, prints the
/// tally, and fails on an unlisted difference or a stale line.
fn report(arena: Allocator, io: Io, fixtures: []const Fixture, outcomes: []const Outcome, secs: u32) !void {
    const xfail = try readList(arena, io, "tests/differential/" ++ v_run.name ++ ".xfail");
    var out: Io.Writer.Allocating = .init(arena);
    var new_list: Io.Writer.Allocating = .init(arena);
    var t: struct { ruled: u32 = 0, agree: u32 = 0, not_built: u32 = 0, differ: u32 = 0, listed: u32 = 0, failed: u32 = 0 } = .{};
    var by_owner: std.StringArrayHashMapUnmanaged(u32) = .empty;
    for (fixtures, outcomes) |f, o| {
        if (o == .ruled) {
            t.ruled += 1;
            try out.writer.print("RULED {s}: an old-side bug the tiebreaker settles ({s})\n", .{ f.rel, o.ruled });
            continue;
        }
        const line: ?[]const u8 = switch (o) {
            .pending => unreachable, // Every worker finished its fixtures.
            .agree => null,
            .not_built => |b| try std.fmt.allocPrint(arena, "not built: backend {s}", .{b}),
            .differ => |d| try std.fmt.allocPrint(arena, "{s}: {s}", .{ d.owner, d.why }),
            .nondeterministic => |w| try std.fmt.allocPrint(arena, "rw-comp (determinism): -j1 and -jN differ: {s}", .{w}),
            .ruled => unreachable, // Counted above.
        };
        switch (o) {
            .agree => t.agree += 1,
            .not_built => t.not_built += 1,
            else => t.differ += 1,
        }
        const l = line orelse {
            if (xfail.contains(f.rel)) {
                t.failed += 1;
                try out.writer.print("XPASS {s}: agrees now; delete its " ++ v_run.name ++ ".xfail line\n", .{f.rel});
            }
            continue;
        };
        const flat = try oneLine(arena, l);
        try new_list.writer.print("{s} {s}\n", .{ f.rel, flat });
        const key = flat[0 .. std.mem.find(u8, flat, ":") orelse flat.len];
        const gop = try by_owner.getOrPut(arena, key);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        // A line covers its fixture only while its owner is the one that
        // differs now, and never a -j1/-jN difference.
        const listed = if (xfail.get(f.rel)) |r| o != .nondeterministic and std.mem.eql(u8, key, r[0 .. std.mem.find(u8, r, ":") orelse r.len]) else false;
        if (listed) {
            t.listed += 1;
        } else if (!options.rebaseline or o == .nondeterministic) {
            t.failed += 1;
            try out.writer.print("FAIL {s} {s}{s}\n", .{ f.rel, flat, if (xfail.contains(f.rel)) " (its " ++ v_run.name ++ ".xfail line names another owner)" else "" });
        }
    }
    if (options.filter.len == 0) {
        var it = xfail.keyIterator();
        while (it.next()) |rel| {
            const known = for (fixtures) |f| {
                if (std.mem.eql(u8, f.rel, rel.*)) break true;
            } else false;
            if (known) continue;
            t.failed += 1;
            try out.writer.print("STALE {s}: " ++ v_run.name ++ ".xfail names a fixture that is not in the corpus\n", .{rel.*});
        }
    }
    if (options.rebaseline) try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ options.repo_root, "zig-out", v_run.name ++ ".xfail.new" }), .data = new_list.written() });
    var owners: Io.Writer.Allocating = .init(arena);
    for (by_owner.keys(), by_owner.values()) |k, v| try owners.writer.print("  {d} {s}\n", .{ v, k });
    std.debug.print("{s}" ++ v_run.name ++ ": {d} fixtures in {d} s: {d} agree, {d} ruled (old-side bugs), {d} need a backend vera-next has not got, {d} differ; {d} in " ++ v_run.name ++ ".xfail, {d} failures. By owner:\n{s}", .{ out.written(), fixtures.len, secs, t.agree, t.ruled, t.not_built, t.differ, t.listed, t.failed, owners.written() });
    if (t.failed != 0 and !options.rebaseline) return error.DiffCompFailed;
}

/// The tiebreaker of a ruling: the fixture's own verdict, as conform
/// judges it. A `//! reject` fixture must be refused (a status other than
/// 0, and never "not built"); an accept-only fixture must compile; a
/// fixture with an `.expected.txt` gold must print it.
fn tiebreak(arena: Allocator, io: Io, f: Fixture, new: judge.Run) !bool {
    if (f.reject) return new.status >= 1 and new.status <= 125;
    if (new.status != 0) return false;
    if (f.compile_only) return true;
    const stem = f.rel[0 .. f.rel.len - std.fs.path.extension(f.rel).len];
    const gold_path = try std.fmt.allocPrint(arena, "{s}/{s}.expected.txt", .{ options.fixture_root, stem });
    const gold = Io.Dir.cwd().readFileAlloc(io, gold_path, arena, .limited(1 << 24)) catch return false;
    return std.mem.eql(u8, gold, new.stdout);
}

/// diff-digital-device's tiebreaker: the old side failed the design, and
/// the new side's device builds and runs it as `--run` does
/// (`comp/device.zig`); a `//! reject` fixture's `--run` must fail too.
/// Null when it holds, else why not.
fn deviceTiebreak(arena: Allocator, s: *Shared, f: Fixture, new: judge.Run, args: []const []const u8, work: []const u8) !?[]const u8 {
    if (new.status != 0) return "the new side builds no device";
    return device.agrees(arena, s.io, s.env, s.exe_new, options.repo_root, args, work, f.reject);
}

/// The run's rulings (`<name>.rulings`): `<path> <clause and reason>`
/// lines, `#` comments.
fn readRulings(arena: Allocator, io: Io) !std.StringHashMapUnmanaged([]const u8) {
    const path = try std.fs.path.join(arena, &.{ options.repo_root, "tests/differential/" ++ v_run.name ++ ".rulings" });
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 22)) catch |e| switch (e) {
        error.FileNotFound => return .empty,
        else => return e,
    };
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.findScalar(u8, line, ' ') orelse return error.RulingHasNoClause;
        try map.put(arena, line[0..sp], line[sp + 1 ..]);
    }
    return map;
}

/// `l` on one line: newlines and tabs as spaces, at most 300 bytes.
fn oneLine(arena: Allocator, l: []const u8) ![]const u8 {
    const s = try arena.dupe(u8, l[0..@min(l.len, 300)]);
    for (s) |*c| if (c.* == '\n' or c.* == '\t' or c.* == '\r') {
        c.* = ' ';
    };
    return s;
}

/// The fixture paths a list file names (`<path> <reason>` lines, `#`
/// comments).
fn readList(arena: Allocator, io: Io, rel: []const u8) !std.StringHashMapUnmanaged([]const u8) {
    const path = try std.fs.path.join(arena, &.{ options.repo_root, rel });
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 24)) catch |e| switch (e) {
        error.FileNotFound => return .empty,
        else => return e,
    };
    var set: std.StringHashMapUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.findScalar(u8, line, ' ') orelse return error.ListLineHasNoReason;
        try set.put(arena, line[0..sp], line[sp + 1 ..]);
    }
    return set;
}

test "diff-comp: vera-next does what vera does on every conformance test" {
    try runAll();
}

test "the harness's command lines are vera.conf's" {
    // Oracle: tests/conformance/tools/vera.conf's run.verilog-a row, by hand.
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const f: Fixture = .{ .rel = "verilog-a/ch04/x.va", .lang = .verilog_a, .compile_only = true, .reject = false };
    const got = try fixture.argv(arena.allocator(), f, "/r");
    const want = [_][]const u8{ "--check", "--sim=verilogA", "--no-std-defs", "-I", "/r/include", "-I", "/r/verilog-a/ch04", "/r/verilog-a/ch04/x.va" };
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}
