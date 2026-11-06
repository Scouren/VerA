//! diff-digital-device's tiebreaker (`digital_device.rulings`): where the
//! old `--check` of a `.v` is wrong, the new device must not only build but
//! run the design. `vera-next --emit-zig` writes the device, a generic host
//! (`tests/host/vdev_run.zig`) built over it steps it as a transient host
//! does, and the transcript the device commits must equal `vera-next
//! --run`'s stdout byte for byte: the interpreter's run, which diff-sim and
//! diff-comp hold to the old engine. With no pins to drive this is the
//! whole of what the device does; a design with pins must have its own
//! oracle (vdev_host), so it never agrees here.
//! No LRM clause: this checks VerA's rewrite against VerA.
//!
//! Contents:
//! - `pub fn agrees(arena: Allocator, io: Io, env: *const std.process.Environ.Map, exe_new: []const u8, repo: []const u8, args: []const []const u8, work: []const u8, reject: bool) !?[]const u8`

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// One child's exit status and output.
const Out = struct { status: u8, stdout: []const u8, stderr: []const u8 };

/// How long each child (the emit, the host's build, its run, `--run`) may take.
const timeout_s = 300;

/// Null when the device built from the fixture's `--check` command line
/// `args` (its first argument the flag) runs the design as `--run` does,
/// and, for a `reject` fixture, `--run` fails; else why not. `work` is created fresh and removed after.
pub fn agrees(arena: Allocator, io: Io, env: *const std.process.Environ.Map, exe_new: []const u8, repo: []const u8, args: []const []const u8, work: []const u8, reject: bool) !?[]const u8 {
    assert(args.len >= 2);
    assert(std.mem.eql(u8, args[0], "--check"));
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, work) catch {};
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};

    const emit = try std.mem.concat(arena, []const u8, &.{ &.{ exe_new, "--emit-zig" }, args[1..], &.{ "-o", "dev.zig" } });
    const e = try child(arena, io, env, work, emit);
    if (e.status != 0) return try std.fmt.allocPrint(arena, "--emit-zig exited {d}: {s}", .{ e.status, e.stderr });
    if (std.mem.find(u8, try cwd.readFileAlloc(io, try std.fs.path.join(arena, &.{ work, "dev.zig" }), arena, .limited(1 << 30)), "num_ports: usize = 0;") == null)
        return "the device has pins: the transcript is no oracle for it (vdev_host is)";

    const lib = try std.fs.path.join(arena, &.{ repo, "lib" });
    const build = [_][]const u8{
        "zig",                                                                        "build-exe",
        "--dep",                                                                      "device",
        try std.fmt.allocPrint(arena, "-Mroot={s}/tests/host/vdev_run.zig", .{repo}), "--dep",
        "std_sim",                                                                    "--dep",
        "contract",                                                                   "-Mdevice=dev.zig",
        "--dep",                                                                      "kernels",
        "--dep",                                                                      "contract",
        "--dep",                                                                      "vams",
        try std.fmt.allocPrint(arena, "-Mstd_sim={s}/std/sim.zig", .{lib}),           "--dep",
        "contract",                                                                   try std.fmt.allocPrint(arena, "-Mkernels={s}/kernels/root.zig", .{lib}),
        try std.fmt.allocPrint(arena, "-Mcontract={s}/contract.zig", .{lib}),         try std.fmt.allocPrint(arena, "-Mvams={s}/std/vams.zig", .{lib}),
        "-femit-bin=host",
    };
    const b = try child(arena, io, env, work, &build);
    if (b.status != 0) return try std.fmt.allocPrint(arena, "the host did not build: {s}", .{b.stderr});
    const h = try child(arena, io, env, work, &.{"./host"});
    if (h.status != 0) return try std.fmt.allocPrint(arena, "the host exited {d}", .{h.status});

    const run = try std.mem.concat(arena, []const u8, &.{ &.{ exe_new, "--run" }, args[1..] });
    const r = try child(arena, io, env, work, run);
    // A design the fixture rejects is rejected at run time, as the device
    // stops: one rejected before it runs has no device to judge.
    if (reject and r.status == 0) return "a `//! reject` fixture `--run` accepts";
    // Both print `$stop`'s line straight to stderr (`Interp.task`), never
    // into the transcript the device holds: it is no transcript line.
    var said: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, h.stderr, '\n');
    while (lines.next()) |line| if (!std.mem.startsWith(u8, line, "$stop at tick ")) {
        try said.appendSlice(arena, line);
        if (lines.index != null) try said.append(arena, '\n');
    };
    if (!std.mem.eql(u8, said.items, r.stdout)) return try std.fmt.allocPrint(arena, "the device's transcript is not --run's: device {d} bytes, run {d}", .{ said.items.len, r.stdout.len });
    return null;
}

// ---- private ----

fn child(arena: Allocator, io: Io, env: *const std.process.Environ.Map, work: []const u8, argv: []const []const u8) !Out {
    assert(argv.len != 0);
    const r = std.process.run(arena, io, .{
        .argv = argv,
        .cwd = .{ .path = work },
        .environ_map = env,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(timeout_s), .clock = .awake } },
    }) catch |e| switch (e) {
        error.Timeout => return .{ .status = 255, .stdout = "", .stderr = "timed out" },
        else => return e,
    };
    return .{ .status = switch (r.term) {
        .exited => |c| c,
        else => 255,
    }, .stdout = r.stdout, .stderr = r.stderr };
}
