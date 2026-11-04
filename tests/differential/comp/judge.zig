//! diff-comp's judgement of one fixture: each driver run in a fresh
//! working directory of its own (as conform runs a test in its work
//! directory), and the two runs compared: the exit status, stderr (the
//! whole diagnostic stream, byte for byte), stdout, and every file the run
//! wrote outside `.zig-cache`. A disagreement is named with the agent and
//! stage that owns it: of the diagnostic codes one stream has and the
//! other lacks, the one the earliest stage owns (`tests/differential/
//! stages.zig`'s table) decides, since a later stage's code is downstream
//! of an earlier stage's (an old W0650 the new side lacks because it
//! stopped in Sema is Sema's debt), so a `comp.xfail` line says whose debt
//! it is.
//! No LRM clause: this checks VerA's rewrite against VerA.
//!
//! Contents:
//! - `pub const Run = struct` (`File`), `pub const Verdict = union(enum)`
//! - `pub fn run(arena: Allocator, io: Io, exe: []const u8, args: []const []const u8, work: []const u8, env: *const std.process.Environ.Map) !Run`
//! - `pub fn compare(arena: Allocator, old: Run, new: Run, digital: bool) !?[]const u8`
//! - `pub fn notBuilt(new: Run) ?[]const u8`
//! - `pub fn owner(arena: Allocator, old: Run, new: Run, digital: bool) ![]const u8`

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const stages = @import("../stages.zig");
const Code = @import("vams").Diag.Code;

/// One driver's run of one fixture.
pub const Run = struct {
    /// The exit status; 255 for a signal or a timeout.
    status: u8,
    stdout: []const u8,
    stderr: []const u8,
    /// Every file the run wrote, sorted, with its bytes.
    files: []const File,

    pub const File = struct { path: []const u8, bytes: []const u8 };
};

/// The outcome the oracle records.
pub const Verdict = union(enum) { agree, differ: []const u8 };

/// `Compilation.not_built_status`.
const not_built_status = 126;

/// How long one driver may take on one fixture (conform's `-T 300`).
const timeout_s = 300;

/// Most files a run may write that are compared.
const files_max: u32 = 1 << 12;

/// Runs `exe args` in `work` (created fresh, removed after) and returns
/// what it printed and wrote, in `arena`.
pub fn run(arena: Allocator, io: Io, exe: []const u8, args: []const []const u8, work: []const u8, env: *const std.process.Environ.Map) !Run {
    assert(exe.len != 0);
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, work) catch {};
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};
    const argv = try std.mem.concat(arena, []const u8, &.{ &.{exe}, args });
    const r = std.process.run(arena, io, .{
        .argv = argv,
        .cwd = .{ .path = work },
        .environ_map = env,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(timeout_s), .clock = .awake } },
    }) catch |e| switch (e) {
        error.Timeout => return .{ .status = 255, .stdout = "", .stderr = "timed out", .files = &.{} },
        else => return e,
    };
    const status: u8 = switch (r.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .status = status, .stdout = r.stdout, .stderr = try unthreaded(arena, r.stderr), .files = try written(arena, io, work) };
}

/// The backend `vera-next` named as not built (exit status 126), or null.
pub fn notBuilt(new: Run) ?[]const u8 {
    if (new.status != not_built_status) return null;
    const at = std.mem.find(u8, new.stderr, "(backend `") orelse return "driver";
    const rest = new.stderr[at + "(backend `".len ..];
    return rest[0 .. std.mem.findScalar(u8, rest, '`') orelse rest.len];
}

/// Null when the runs agree on everything compared, else the first
/// difference. A dump's `$date` (the wall clock) is not compared.
pub fn compare(arena: Allocator, old: Run, new: Run, digital: bool) !?[]const u8 {
    _ = digital;
    if (old.status != new.status) return try std.fmt.allocPrint(arena, "exit status old {d}, new {d}", .{ old.status, new.status });
    if (!std.mem.eql(u8, old.stderr, new.stderr)) return try std.fmt.allocPrint(arena, "stderr: {s}", .{try firstDiff(arena, old.stderr, new.stderr)});
    if (!std.mem.eql(u8, old.stdout, new.stdout)) return try std.fmt.allocPrint(arena, "stdout: {s}", .{try firstDiff(arena, old.stdout, new.stdout)});
    if (old.files.len != new.files.len) return try std.fmt.allocPrint(arena, "the runs wrote {d} and {d} files", .{ old.files.len, new.files.len });
    for (old.files, new.files) |a, b| {
        if (!std.mem.eql(u8, a.path, b.path)) return try std.fmt.allocPrint(arena, "the runs wrote `{s}` and `{s}`", .{ a.path, b.path });
        if (!std.mem.eql(u8, undated(a.bytes), undated(b.bytes))) return try std.fmt.allocPrint(arena, "file `{s}`: {s}", .{ a.path, try firstDiff(arena, a.bytes, b.bytes) });
    }
    return null;
}

/// The agent and stage a disagreement belongs to: of the diagnostic codes
/// one stream has and the other lacks, the earliest stage's decides; with the same codes,
/// the driver's own text (a location, a plain line) is the spine's, and a
/// different transcript or status the lowering's.
pub fn owner(arena: Allocator, old: Run, new: Run, digital: bool) ![]const u8 {
    const a = try codes(arena, old.stderr);
    const b = try codes(arena, new.stderr);
    if (try earliestUnmatched(arena, a, b)) |c| return ownerOf(c, digital);
    if (std.mem.find(u8, new.stderr, "codegen refused") != null or std.mem.find(u8, new.stderr, "does not compile") != null) return "rw-codegen (codegen)";
    if (a.len != 0 and !std.mem.eql(u8, old.stderr, new.stderr)) return try std.fmt.allocPrint(arena, "{s} {s}", .{ ownerOf(a[0], digital), part(old.stderr, new.stderr) });
    return if (digital) "rw-dlower (digital lowering)" else "rw-lower (analog lowering)";
}

// ---- private ----

/// Of the codes in `a` and not `b` or in `b` and not `a` (as multisets),
/// the one the earliest stage owns; null when the two agree. A code the
/// catalogue lacks counts as the run stage's.
fn earliestUnmatched(arena: Allocator, a: []const []const u8, b: []const []const u8) !?[]const u8 {
    const used = try arena.alloc(bool, b.len);
    @memset(used, false);
    var best: ?[]const u8 = null;
    for (a) |x| {
        const hit = for (b, used) |y, *u| {
            if (!u.* and std.mem.eql(u8, x, y)) {
                u.* = true;
                break true;
            }
        } else false;
        if (!hit and earlier(x, best)) best = x;
    }
    for (b, used) |y, u| if (!u and earlier(y, best)) {
        best = y;
    };
    return best;
}

fn earlier(code: []const u8, than: ?[]const u8) bool {
    const t = than orelse return true;
    return @backingInt(stageOf(code)) < @backingInt(stageOf(t));
}

fn stageOf(code: []const u8) stages.Owner {
    const c = std.meta.stringToEnum(Code, code) orelse return .run;
    return stages.owner(c);
}

/// The stage that owns `code` (`E0405`) by `stages.owner`, and its agent:
/// the front end is rw-comp's, Sema's lowering rw-lower's or rw-dlower's.
fn ownerOf(code: []const u8, digital: bool) []const u8 {
    assert(code.len == 5);
    const c = std.meta.stringToEnum(Code, code) orelse return "rw-comp (driver)";
    return switch (stages.owner(c)) {
        .preprocess => "rw-comp (preprocess)",
        .parse => "rw-comp (parse)",
        .astgen => "rw-comp (astgen)",
        .elab => "rw-comp (elab)",
        .sema => if (digital) "rw-dlower (digital lowering)" else "rw-lower (analog lowering)",
        .proof => "rw-zero (air passes)",
        .codegen => "rw-codegen (codegen)",
        .run => if (digital) "rw-dlower (run)" else "rw-codegen (run)",
    };
}

/// Which part of a rendered diagnostic the first differing line is: its
/// headline (`message`), a `= note:`/`= help:` line (`notes`), or the
/// location and snippet (`location`).
fn part(a: []const u8, b: []const u8) []const u8 {
    var la = std.mem.splitScalar(u8, a, '\n');
    var lb = std.mem.splitScalar(u8, b, '\n');
    while (la.next()) |x| {
        const y = lb.next() orelse return "notes";
        if (std.mem.eql(u8, x, y)) continue;
        if (std.mem.startsWith(u8, x, "error") or std.mem.startsWith(u8, x, "warning")) return "message";
        if (std.mem.find(u8, x, "= note") != null or std.mem.find(u8, x, "= help") != null or std.mem.find(u8, y, "= help") != null) return "notes";
        return "location";
    }
    return "notes";
}

/// The codes of a rendered stream's headlines (`error[E0405]:`), in order.
fn codes(arena: Allocator, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const open = std.mem.findScalar(u8, line, '[') orelse continue;
        if (!(std.mem.startsWith(u8, line, "error[") or std.mem.startsWith(u8, line, "warning["))) continue;
        if (line.len < open + 7 or line[open + 6] != ']') continue;
        try list.append(arena, line[open + 1 .. open + 6]);
    }
    return list.items;
}

/// The first line the two texts differ on, both sides shown, short.
fn firstDiff(arena: Allocator, a: []const u8, b: []const u8) ![]const u8 {
    var la = std.mem.splitScalar(u8, a, '\n');
    var lb = std.mem.splitScalar(u8, b, '\n');
    var n: u32 = 1;
    while (true) : (n += 1) {
        const x = la.next();
        const y = lb.next();
        if (x == null and y == null) return "the same lines, different bytes";
        const xs = x orelse "<end>";
        const ys = y orelse "<end>";
        if (!std.mem.eql(u8, xs, ys)) return std.fmt.allocPrint(arena, "line {d}: old `{s}`, new `{s}`", .{ n, xs[0..@min(xs.len, 160)], ys[0..@min(ys.len, 160)] });
    }
}

/// `text` with a panic's `thread <id> panic` as `thread panic`: the id is
/// the OS's, not the compiler's output.
fn unthreaded(arena: Allocator, text: []const u8) ![]const u8 {
    const at = std.mem.find(u8, text, "thread ") orelse return text;
    var k = at + "thread ".len;
    while (k < text.len and std.ascii.isDigit(text[k])) k += 1;
    if (k == at + "thread ".len or !std.mem.startsWith(u8, text[k..], " panic")) return text;
    return std.mem.concat(arena, u8, &.{ text[0 .. at + "thread".len], text[k..] });
}

/// A dump past its `$date ... $end` section; any other file whole.
fn undated(bytes: []const u8) []const u8 {
    const at = std.mem.find(u8, bytes, "$date") orelse return bytes;
    const end = std.mem.findPos(u8, bytes, at, "$end") orelse return bytes;
    return bytes[end..];
}

/// Every file under `work` outside `.zig-cache`, sorted, with its bytes.
fn written(arena: Allocator, io: Io, work: []const u8) ![]const Run.File {
    var dir = try Io.Dir.cwd().openDir(io, work, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var list: std.ArrayList(Run.File) = .empty;
    while (try walker.next(io)) |e| {
        if (e.kind != .file) continue;
        if (std.mem.startsWith(u8, e.path, ".zig-cache")) continue;
        if (list.items.len == files_max) return error.TooManyFiles;
        try list.append(arena, .{ .path = try arena.dupe(u8, e.path), .bytes = try dir.readFileAlloc(io, e.path, arena, .limited(1 << 26)) });
    }
    std.mem.sort(Run.File, list.items, {}, struct {
        fn lt(_: void, x: Run.File, y: Run.File) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    return list.items;
}
