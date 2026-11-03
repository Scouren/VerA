//! `--check`: generated device text in, a `zig build-obj -fno-emit-bin` of
//! it beside the `contract` module through the `Queue` out, as a verdict,
//! with the compiler's report on the caller's writer when it fails. The
//! messages are user-visible and frozen. Cites no LRM clause: this checks
//! VerA's own output against its own contract.
//!
//! Contents:
//! - `pub const Verdict = enum { compiles, fails }`
//! - `pub const CheckError`
//! - `pub fn typeCheck(f: File, gpa: Allocator, io: Io, q: *Queue, device: []const u8, source_path: []const u8, err: *Io.Writer) CheckError!Verdict`

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const File = @import("File.zig");
const Zig = @import("Zig.zig");
const Queue = @import("Queue.zig");
const Server = @import("Server.zig");

/// Whether the device type-checks against the contract.
pub const Verdict = enum { compiles, fails };

/// Every way `typeCheck` fails short of a verdict: the scratch files could
/// not be written, `zig` could not be run (`Server.Error`), or `err` could
/// not take the message (std's names). The scratch files stay.
pub const CheckError = Server.Error || Io.Dir.CreateDirPathError || Io.Dir.OpenError ||
    Io.Dir.WriteFileError || Io.Writer.Error;

/// How long one device's check gets before it is killed. A check takes well
/// under a second per device, so a child past this is wedged, and an
/// unbounded one is a hang the parent build cannot report.
const check_budget_s = 120;

/// The check's root: the contract's checks on, over the device.
const check_root =
    \\pub const vera_validate_contract = true;
    \\comptime {
    \\    @import("contract").validate(@import("device"));
    \\}
    \\
;

/// Runs `zig build-obj -fno-emit-bin` over `device` with `f.modules` (the
/// `contract`), rooted at a file that turns the contract's checks on
/// (`contract.validating`), its files under `f.work_dir` named by
/// `source_path`'s stem. Returns `.compiles`, or `.fails` with the reason
/// (naming `source_path`) written on `err`: the compiler's report, or a note
/// that it ran past `check_budget_s` and was killed. Runs in `q`'s first
/// slot, so a check needs no free job beyond the one it takes.
///
/// Proves only that the file parses and its `comptime` blocks hold: analysis
/// is lazy and `contract.validate` is reflection, so a type error inside an
/// `eval`/`q` body passes here. Fails as `CheckError` says. Asserts that `f`
/// is `.check` with one module and `source_path` is not empty.
pub fn typeCheck(f: File, gpa: Allocator, io: Io, q: *Queue, device: []const u8, source_path: []const u8, err: *Io.Writer) CheckError!Verdict {
    assert(f.kind == .check);
    assert(f.modules.len == 1);
    assert(source_path.len > 0);
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, f.work_dir);
    var tmp = try cwd.openDir(io, f.work_dir, .{});
    defer tmp.close(io);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const stem = std.fs.path.stem(source_path);
    const dev_name = try arena.print("{s}.device.zig", .{stem});
    try tmp.writeFile(io, .{ .sub_path = dev_name, .data = device });
    const root_name = try arena.print("{s}.check.zig", .{stem});
    try tmp.writeFile(io, .{ .sub_path = root_name, .data = check_root });
    const contract = f.modules[0];
    const a = try Zig.argv(arena, .{
        .zig_exe = f.zig_exe,
        .verb = "build-obj",
        .kind = &.{"-fno-emit-bin"},
        .cache_dir = ".zig-cache",
        .modules = &.{
            .{ .name = "root", .root = try std.fs.path.join(arena, &.{ f.work_dir, root_name }), .deps = &.{ "device", contract.name } },
            .{ .name = "device", .root = try std.fs.path.join(arena, &.{ f.work_dir, dev_name }), .deps = &.{contract.name} },
            contract,
        },
    });

    const s = &q.slots[0];
    try s.spawn(io, arena, a);
    // `concurrent`, not `async`: `async` may run the watchdog inline on this
    // thread, which would sleep out the whole budget before the child was
    // ever read from. An Io that cannot spare a second thread gets an
    // unbounded wait rather than a wrong one.
    var watchdog = io.concurrent(killAfter, .{ io, &s.child, check_budget_s }) catch null;
    const reply = reply: {
        s.update(io) catch |e| break :reply e;
        break :reply s.wait(gpa, arena);
    };
    // Retired BEFORE `close` reaps, because after the reap this pid belongs
    // to whoever the OS hands it to next and a watchdog still holding it
    // would signal a stranger. `killAfter` reaps what it kills; `close`
    // leaves such a child alone.
    const timed_out = if (watchdog) |*w| w.cancel(io) else false;
    s.close(io);
    if (timed_out) {
        try err.print(
            "error: {s}: type check did not finish in {d}s and was killed. " ++
                "The generated Zig is at {s}/{s}; run its `zig build-obj` by hand to see where it sticks.\n",
            .{ source_path, check_budget_s, f.work_dir, dev_name },
        );
        return .fails;
    }
    var got = try reply;
    switch (got) {
        .ok => return .compiles,
        .failed => |*bundle| {
            defer bundle.deinit(gpa);
            try err.print(
                "error: {s}: codegen produced Zig that does not compile — this is an engine bug, " ++
                    "not a problem with the model:\n",
                .{source_path},
            );
            try bundle.renderToWriter(.{}, err);
            return .fails;
        },
    }
}

// ---- private ----

/// Kills `child` once the budget is up and returns whether it had to; a
/// cancel (the check finished first) ends the sleep and answers false.
fn killAfter(io: Io, child: *std.process.Child, seconds: i64) bool {
    assert(seconds > 0);
    io.sleep(.fromSeconds(seconds), .awake) catch |e| {
        assert(e == error.Canceled);
        return false;
    };
    child.kill(io);
    return true;
}
