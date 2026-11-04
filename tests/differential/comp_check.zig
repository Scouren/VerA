//! `--check`'s scratch per invocation (lib/TODO.md §12, ESPice's race):
//! one model, one working directory, `vera-next --emit-zig --check`
//! processes that overlap. The first test overlaps two deterministically:
//! one pauses between writing its scratch files and type-checking them
//! (`--test-check-pause-ms=`, `Config.check_pause`) while the other checks
//! and cleans up. With a fixed scratch path (`.zig-cache/vera-tb/check`) the
//! paused one fails with `unable to load "res.check.zig": FileNotFound`,
//! ESPice's symptom; with a path per invocation both succeed. The second
//! runs `runs` staggered at once, each printing the same device and leaving
//! no scratch behind.
//! No LRM clause: this checks the driver.
//!
//! Contents: tests only.

const std = @import("std");
const Io = std.Io;
const options = @import("comp_options");

/// Concurrent invocations (the spec asks for at least 8).
const runs = 16;
/// The gap between two runs' starts: well inside one type check (about a second).
const stagger_ms = 40;

const resistor =
    \\`include "disciplines.vams"
    \\module res(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  parameter real r = 1000.0 from (0.0:inf);
    \\  analog I(p, n) <+ V(p, n) / r;
    \\endmodule
    \\
;

const Result = struct { term: std.process.Child.Term = .{ .unknown = 0 }, stdout: []const u8 = "", stderr: []const u8 = "", err: ?anyerror = null };

// ---- private ----

/// Run `k` starts `k` staggers after the first, so one run's cleanup
/// lands inside another's type check, as builds sharing a cache do.
fn one(io: Io, exe: []const u8, cwd: []const u8, k: u32, out: *Result) void {
    io.sleep(.fromMilliseconds(stagger_ms * k), .awake) catch {};
    const r = std.process.run(std.heap.smp_allocator, io, .{
        .argv = &.{ exe, "--emit-zig", "--check", "res.va" },
        .cwd = .{ .path = cwd },
    }) catch |e| {
        out.err = e;
        return;
    };
    out.* = .{ .term = r.term, .stdout = r.stdout, .stderr = r.stderr };
}

/// One `vera-next --emit-zig --check res.va` in `cwd` with `extra` flags
/// before the input, after `delay_ms`.
fn checkRun(io: Io, exe: []const u8, cwd: []const u8, extra: []const []const u8, delay_ms: u32, out: *Result) void {
    io.sleep(.fromMilliseconds(delay_ms), .awake) catch {};
    var argv: [6][]const u8 = undefined;
    argv[0] = exe;
    argv[1] = "--emit-zig";
    argv[2] = "--check";
    @memcpy(argv[3..][0..extra.len], extra);
    argv[3 + extra.len] = "res.va";
    const r = std.process.run(std.heap.smp_allocator, io, .{ .argv = argv[0 .. 4 + extra.len], .cwd = .{ .path = cwd } }) catch |e| {
        out.err = e;
        return;
    };
    out.* = .{ .term = r.term, .stdout = r.stdout, .stderr = r.stderr };
}

test "§12 a check that pauses after writing its files outlives another check's cleanup" {
    // Deterministic overlap: A writes its scratch files, then waits
    // `pause_ms` (the `--test-check-pause-ms=` hook, Config.check_pause);
    // B starts `start_ms` later, checks and removes its scratch. With one
    // fixed scratch path B deletes A's files before A type-checks them, and
    // A fails (red, shown with `scratchDir` returning `<base>/check`).
    const pause_ms = 20_000;
    const start_ms = 1_000;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "res.va", .data = resistor });
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cwd = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, options.vera_next, arena.allocator());
    // Warm the shared caches, so B's whole check fits in A's pause.
    var warm: Result = .{};
    checkRun(io, exe, cwd, &.{}, 0, &warm);
    if (warm.err) |e| return e;
    try std.testing.expect(warm.term.success());
    var a: Result = .{};
    var b: Result = .{};
    const ta = try std.Thread.spawn(.{}, checkRun, .{ io, exe, cwd, @as([]const []const u8, &.{"--test-check-pause-ms=" ++ std.fmt.comptimePrint("{d}", .{pause_ms})}), 0, &a });
    const tb = try std.Thread.spawn(.{}, checkRun, .{ io, exe, cwd, @as([]const []const u8, &.{}), start_ms, &b });
    ta.join();
    tb.join();
    for ([_]*const Result{ &a, &b }, [_][]const u8{ "A (paused)", "B" }) |r, name| {
        if (r.err) |e| return e;
        if (!r.term.success()) {
            std.debug.print("{s} failed ({any}):\n{s}\n", .{ name, r.term, r.stderr });
            return error.OverlappingCheckFailed;
        }
    }
    try std.testing.expectEqualStrings(warm.stdout, a.stdout);
    try std.testing.expectEqualStrings(warm.stdout, b.stdout);
}

test "§12 sixteen concurrent --emit-zig --check runs of one model in one directory all succeed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "res.va", .data = resistor });
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cwd = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, options.vera_next, arena.allocator());
    var results: [runs]Result = @splat(.{});
    var threads: [runs]std.Thread = undefined;
    for (&threads, &results, 0..) |*t, *r, k| t.* = try std.Thread.spawn(.{}, one, .{ io, exe, cwd, @as(u32, @intCast(k)), r });
    for (threads) |t| t.join();
    for (results, 0..) |r, k| {
        if (r.err) |e| return e;
        if (!r.term.success()) {
            std.debug.print("run {d} of {d} failed ({any}):\n{s}\n", .{ k, runs, r.term, r.stderr });
            return error.ConcurrentCheckFailed;
        }
        try std.testing.expect(r.stdout.len != 0);
        try std.testing.expectEqualStrings(results[0].stdout, r.stdout);
    }
    // Nothing is left behind but the shared contract tree and caches.
    var tb = try tmp.dir.openDir(io, ".zig-cache/vera-tb", .{ .iterate = true });
    defer tb.close(io);
    var it = tb.iterate();
    while (try it.next(io)) |e| try std.testing.expectEqualStrings("vera-src", e.name);
}
