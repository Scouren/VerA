//! `--check`'s scratch per invocation (lib/TODO.md §12, ESPice's race):
//! one model, one working directory, `runs` concurrent `vera-next
//! --emit-zig --check` processes, every one of which must succeed and
//! print the same device, leaving no scratch behind. The race itself is
//! timing: with a fixed path (`.zig-cache/vera-tb/check`) these runs did
//! not hit the window on this machine, so the red-first proof of the
//! property is `src/next/Compilation/test.zig`'s scratch test, which a
//! fixed path fails; this one holds the processes to it end to end.
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
