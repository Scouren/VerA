//! The differential oracle of the new digital runtime (`zig build diff-sim`,
//! docs/rewrite/sim.md): every `.v` fixture `vera --run` judges against a
//! golden (the `suite -- devices` and `ieee1364` sets) in, a verdict per
//! fixture out. The oracle is lib/sim/digital, the product until the rewrite
//! replaces it: the fixture is elaborated twice by it, once to run in the old
//! interpreter and once for the bridge (`sim/bridge.zig`) to write as a
//! `Program`, which the new `Interp` runs. A fixture agrees when both
//! transcripts are byte-equal and both runs end the same way (completed, or
//! a runtime error). A known difference is a line of `sim.xfail`
//! (`<path under the fixture root> <reason>`); a listed fixture that agrees,
//! or that is not in the corpus, fails the run until its line goes.
//! Cites: IEEE 1364-2005 §9, §11, §17 (through both implementations).
//!
//! Contents: tests only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sim = @import("sim");
const std_sim = @import("std_sim");
const diag = @import("diag");
const frontend = @import("frontend");
const rewrite_options = @import("rewrite_options");
const bridge = @import("sim/bridge.zig");
const digital = sim.digital;

/// The fixture directories `suite -- devices` runs (`tests/suite/Devices.zig`).
const dirs = [_][]const u8{ "verilog", "verilog-ams/digital" };

/// One side's run: what the oracle compares.
const Side = struct { out: []const u8, failed: bool, why: []const u8 = "" };

// ---- private ----

/// Every `.v` with a `.expected.txt` golden and no `//! reject` line under
/// `dirs`, relative to `root` and sorted. `pli/` is the VPI suite's.
fn collect(arena: Allocator, io: std.Io, root: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (dirs) |sub| {
        const path = try std.fs.path.join(arena, &.{ root, sub });
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!std.mem.eql(u8, std.fs.path.extension(entry.path), ".v")) continue;
            if (std.mem.startsWith(u8, entry.path, "pli" ++ std.fs.path.sep_str)) continue;
            const stem = entry.path[0 .. entry.path.len - ".v".len];
            const golden = try std.fmt.allocPrint(arena, "{s}.expected.txt", .{stem});
            if (dir.access(io, golden, .{})) |_| {} else |_| continue;
            const source = try dir.readFileAlloc(io, entry.path, arena, .limited(1 << 22));
            if (negative(source)) continue;
            try list.append(arena, try std.fs.path.join(arena, &.{ sub, entry.path }));
        }
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return list.items;
}

/// `tests/suite/Digital.zig`'s `negative`: a `//! reject` or `//! reject-only` line.
fn negative(source: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "//!")) continue;
        var words = std.mem.tokenizeAny(u8, line["//!".len..], " \t");
        const word = words.next() orelse continue;
        if (std.mem.eql(u8, word, "reject") or std.mem.eql(u8, word, "reject-only")) return true;
    }
    return false;
}

/// `sim.xfail`: one `<path> <reason>` per line; `#` and blank lines are
/// comments. A line without a reason is refused.
fn readXfail(arena: Allocator, io: std.Io, path: []const u8) !std.StringHashMapUnmanaged([]const u8) {
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 24));
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.findAny(u8, line, " \t") orelse {
            std.debug.print("diff-sim: sim.xfail line `{s}` has no reason\n", .{line});
            return error.XfailWithoutReason;
        };
        try map.put(arena, line[0..sp], std.mem.trim(u8, line[sp..], " \t"));
    }
    return map;
}

/// The settings `vera --run` gives a fixture: its path, `//! event-budget`.
/// Null for a fixture with `//@` runner lines (more files, a library map),
/// which the bridge does not take yet.
fn options(source: []const u8, path: []const u8, io: std.Io) ?digital.Options {
    var opts: digital.Options = .{ .file_name = path, .io = io };
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "//@")) return null;
        if (std.mem.cutPrefix(u8, line, "//! event-budget")) |rest|
            opts.event_budget = std.fmt.parseInt(u64, std.mem.trim(u8, rest, " \t"), 10) catch return null;
    }
    return opts;
}

/// Runs fixture `rel` both ways: null when they agree, else what differs.
fn compare(a: Allocator, io: std.Io, root: []const u8, rel: []const u8) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ root, rel });
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 22));
    const opts = options(source, path, io) orelse return "bridge: `//@` runner lines (more files, a library map)";

    // The new side first: a fixture the bridge cannot express is not run by
    // the old engine either, so no fixture's file tasks touch the disk here.
    var new_out: std.Io.Writer.Allocating = .init(a);
    const new: Side = new: {
        var bag: diag.Bag = .init(a);
        var r = digital.elaborate(a, source, opts, &bag, &new_out.writer) catch return "the old engine refuses the design";
        var why: []const u8 = "";
        const p = bridge.program(a, &r, &why) catch |e| switch (e) {
            error.Unsupported => return std.fmt.allocPrint(a, "bridge: {s}", .{why}),
            error.OutOfMemory => return e,
        };
        var s: std_sim.State = try .init(a, &p, &new_out.writer);
        s.budget = opts.event_budget;
        std_sim.Interp.run(&s) catch |e| switch (e) {
            error.SimFailed => break :new .{ .out = new_out.written(), .failed = true, .why = s.failure.? },
            error.OutOfMemory, error.WriteFailed => return e,
        };
        break :new .{ .out = new_out.written(), .failed = false };
    };

    var old_out: std.Io.Writer.Allocating = .init(a);
    const old: Side = old: {
        var bag: diag.Bag = .init(a);
        digital.run(a, source, opts, &bag, &old_out.writer) catch |e| switch (e) {
            error.DigitalFailed => break :old .{ .out = old_out.written(), .failed = true },
            else => return e,
        };
        break :old .{ .out = old_out.written(), .failed = bag.failed() };
    };

    if (old.failed != new.failed)
        return std.fmt.allocPrint(a, "old run {s}, new run {s} ({s})", .{ if (old.failed) "failed" else "completed", if (new.failed) "failed" else "completed", new.why });
    if (!std.mem.eql(u8, old.out, new.out)) return textDiff(a, old.out, new.out);
    return "";
}

/// The first differing byte and the text around it on each side.
fn textDiff(a: Allocator, old: []const u8, new: []const u8) ![]const u8 {
    const at = std.mem.indexOfDiff(u8, old, new).?;
    const from = at -| 30;
    return std.fmt.allocPrint(a, "transcript differs at byte {d} (old {d} bytes, new {d}): old \"{s}\" new \"{s}\"", .{
        at,                                                old.len,                                           new.len,
        try escaped(a, old[from..@min(at + 30, old.len)]), try escaped(a, new[from..@min(at + 30, new.len)]),
    });
}

fn escaped(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '\n' => try out.appendSlice(a, "\\n"),
        '\t' => try out.appendSlice(a, "\\t"),
        else => try out.append(a, c),
    };
    return out.items;
}

test "diff-sim: the new runtime's transcripts equal lib/sim/digital's on every .v fixture" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var run_arena: std.heap.ArenaAllocator = .init(gpa);
    defer run_arena.deinit();
    const ra = run_arena.allocator();
    const root = rewrite_options.fixture_root;

    const fixtures = try collect(ra, io, root);
    const xfail_path = try std.fs.path.join(ra, &.{ rewrite_options.repo_root, "tests/differential/sim.xfail" });
    const xfail = try readXfail(ra, io, xfail_path);

    var fixture_arena: std.heap.ArenaAllocator = .init(gpa);
    defer fixture_arena.deinit();
    var agreed: usize = 0;
    var listed: usize = 0;
    var bad: usize = 0;
    var bridged: usize = 0;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (fixtures) |rel| {
        _ = fixture_arena.reset(.retain_capacity);
        const a = fixture_arena.allocator();
        try seen.put(ra, rel, {});
        const why = try compare(a, io, root, rel);
        if (!std.mem.startsWith(u8, why, "bridge:") and !std.mem.startsWith(u8, why, "the old engine")) bridged += 1;
        const reason = xfail.get(rel);
        if (why.len != 0) {
            if (reason != null) {
                listed += 1;
                continue;
            }
            bad += 1;
            std.debug.print("diff-sim: MISMATCH {s}: {s}\n", .{ rel, why });
        } else if (reason) |r| {
            bad += 1;
            std.debug.print("diff-sim: XPASS {s} agrees; remove its sim.xfail line ({s})\n", .{ rel, r });
        } else agreed += 1;
    }
    var it = xfail.keyIterator();
    while (it.next()) |k| if (!seen.contains(k.*)) {
        bad += 1;
        std.debug.print("diff-sim: STALE {s} is in sim.xfail but not in the corpus\n", .{k.*});
    };
    std.debug.print("diff-sim: {d} fixtures, {d} bridged and run both ways, {d} agreed, {d} listed in sim.xfail, {d} failed\n", .{ fixtures.len, bridged, agreed, listed, bad });
    try std.testing.expect(fixtures.len > 700);
    try std.testing.expectEqual(@as(usize, 0), bad);
}
