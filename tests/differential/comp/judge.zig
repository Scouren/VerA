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
//! - `pub fn run(arena: Allocator, io: Io, exe: []const u8, args: []const []const u8, work: []const u8, env: *const std.process.Environ.Map, exec: bool) !Run`
//! - `pub fn runTwice(arena: Allocator, io: Io, exe: []const u8, args: []const []const u8, work: []const u8, env: *const std.process.Environ.Map, again: *const std.process.Environ.Map) ![2]Run`
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

/// The diagnostics of a rendered stream: each from its headline to the
/// next headline or the end.
const Blocks = struct {
    text: []const u8,
    at: usize = 0,

    fn next(it: *Blocks) ?[]const u8 {
        const start = headline(it.text, it.at) orelse return null;
        const end = headline(it.text, start + 1) orelse it.text.len;
        it.at = end;
        // A rendered diagnostic ends at its blank line; a summary may follow.
        const blank = std.mem.find(u8, it.text[start..end], "\n\n") orelse end - start;
        return it.text[start..][0..blank];
    }

    /// The offset of the first `error[`/`warning[` line at or after `from`.
    fn headline(text: []const u8, from: usize) ?usize {
        var k = from;
        // Bounded by the text's length: each turn moves one line on.
        while (k < text.len) {
            const line_start = k == 0 or text[k - 1] == '\n';
            if (line_start and (std.mem.startsWith(u8, text[k..], "error[") or std.mem.startsWith(u8, text[k..], "warning["))) return k;
            k = (std.mem.findScalarPos(u8, text, k, '\n') orelse return null) + 1;
        }
        return null;
    }
};

/// One headline's code, and whether it came after the run banner
/// (`=== <name> ===`): a code the run printed is the run stage's,
/// whatever stage owns it at compile time.
const Seen = struct { code: []const u8, run: bool };

/// Runs `exe args` in `work` (created fresh, removed after) and returns
/// what it printed and wrote, in `arena`. With `exec` (an `--emit-exe`),
/// a successful run's binary (the first line of its stdout) runs too, in
/// `work`: its status and stdout are the run's, its stderr follows the
/// build's.
pub fn run(arena: Allocator, io: Io, exe: []const u8, args: []const []const u8, work: []const u8, env: *const std.process.Environ.Map, exec: bool) !Run {
    return (try runWith(arena, io, exe, args, work, env, exec, null))[0];
}

/// `run` of an `--emit-exe` whose binary runs twice: under `env`, then
/// under `again` (diff-native's interpreter-only run). Both runs, in that
/// order; a failed build is both.
pub fn runTwice(arena: Allocator, io: Io, exe: []const u8, args: []const []const u8, work: []const u8, env: *const std.process.Environ.Map, again: *const std.process.Environ.Map) ![2]Run {
    return runWith(arena, io, exe, args, work, env, true, again);
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
    if (try earliestUnmatched(arena, a, b)) |c| return if (c.run) runOwner(digital) else ownerOf(c.code, digital);
    // The old native codegen's build remarks (`note: ... 4-state: ...`),
    // which the interpreted executable has no counterpart of.
    if (old.status == new.status and std.mem.eql(u8, try withoutNotes(arena, old.stderr), new.stderr) and std.mem.eql(u8, old.stdout, new.stdout)) return "digital_exe (build remarks)";
    if (std.mem.find(u8, new.stderr, "codegen refused") != null or std.mem.find(u8, new.stderr, "does not compile") != null) return "rw-codegen (codegen)";
    // A testbench transcript with lines missing and nothing else changed:
    // the device's §9.4 display phase (`$strobe`), which the Zig device
    // backend has not got yet.
    if (!digital and old.status == new.status and dropped(old.stderr, new.stderr)) return "rw-codegen (display phase)";
    // Every diagnostic block matches (only their order or the run's text
    // differs): the run's.
    if (a.len != 0 and !std.mem.eql(u8, old.stderr, new.stderr)) {
        const c = firstChanged(old.stderr, new.stderr) orelse return runOwner(digital);
        return try std.fmt.allocPrint(arena, "{s} {s}", .{ ownerOf(c, digital), part(old.stderr, new.stderr) });
    }
    return if (digital) "rw-dlower (digital lowering)" else "rw-lower (analog lowering)";
}

// ---- private ----

/// Builds and runs `exe args` in `work` under `env`; when `again` is given
/// (an `--emit-exe` build, `exec`), the built binary runs a second time
/// under it and both runs come back, in that order. A failed build (or a
/// build with no exec) is both.
fn runWith(arena: Allocator, io: Io, exe: []const u8, args: []const []const u8, work: []const u8, env: *const std.process.Environ.Map, exec: bool, again: ?*const std.process.Environ.Map) ![2]Run {
    assert(exe.len != 0);
    assert(again == null or exec);
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
        error.Timeout => return @splat(.{ .status = 255, .stdout = "", .stderr = "timed out", .files = &.{} }),
        else => return e,
    };
    const status: u8 = switch (r.term) {
        .exited => |c| c,
        else => 255,
    };
    if (exec and status == 0) {
        const bin = std.mem.trimEnd(u8, r.stdout[0 .. std.mem.findScalar(u8, r.stdout, '\n') orelse r.stdout.len], " \r");
        if (bin.len != 0) {
            const first = try execBin(arena, io, bin, work, env, r.stderr);
            return .{ first, if (again) |e| try execBin(arena, io, bin, work, e, r.stderr) else first };
        }
    }
    return @splat(.{ .status = status, .stdout = r.stdout, .stderr = try unthreaded(arena, r.stderr), .files = try written(arena, io, work) });
}

/// The built binary `bin` run in `work` under `env`: its status and
/// stdout, its stderr after the build's `built`.
fn execBin(arena: Allocator, io: Io, bin: []const u8, work: []const u8, env: *const std.process.Environ.Map, built: []const u8) !Run {
    const x = std.process.run(arena, io, .{
        .argv = &.{bin},
        .cwd = .{ .path = work },
        .environ_map = env,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(timeout_s), .clock = .awake } },
    }) catch |e| switch (e) {
        error.Timeout => return .{ .status = 255, .stdout = "", .stderr = "timed out", .files = &.{} },
        else => return e,
    };
    const x_status: u8 = switch (x.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .status = x_status, .stdout = x.stdout, .stderr = try unthreaded(arena, try std.mem.concat(arena, u8, &.{ built, x.stderr })), .files = try written(arena, io, work) };
}

/// Of the codes in `a` and not `b` or in `b` and not `a` (as multisets),
/// the one the earliest stage owns; null when the two agree. A code the
/// catalogue lacks counts as the run stage's. W0650 is not counted: its
/// rule differs by design (lib/TODO.md §11.9), so its presence alone names
/// no stage.
fn earliestUnmatched(arena: Allocator, a: []const Seen, b: []const Seen) !?Seen {
    const used = try arena.alloc(bool, b.len);
    @memset(used, false);
    var best: ?Seen = null;
    for (a) |x| {
        if (std.mem.eql(u8, x.code, "W0650")) continue;
        const hit = for (b, used) |y, *u| {
            if (!u.* and x.run == y.run and std.mem.eql(u8, x.code, y.code)) {
                u.* = true;
                break true;
            }
        } else false;
        if (!hit and earlier(x, best)) best = x;
    }
    for (b, used) |y, u| if (!u and !std.mem.eql(u8, y.code, "W0650") and earlier(y, best)) {
        best = y;
    };
    return best;
}

/// `text` without its lines that open with `note: ` (the owner of a
/// difference that is only those).
fn withoutNotes(arena: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "note: ")) continue;
        if (!first) try out.append(arena, '\n');
        first = false;
        try out.appendSlice(arena, line);
    }
    return out.items;
}

/// Whether `b` differs from `a` only by transcript lines `a` has and `b`
/// lacks: `b`'s lines are a subsequence of `a`'s, and no line dropped is a
/// diagnostic's `= note:`/`= help:` (those are Sema's, not the display
/// phase's).
fn dropped(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return false;
    var la = std.mem.splitScalar(u8, a, '\n');
    var lb = std.mem.splitScalar(u8, b, '\n');
    while (lb.next()) |y| {
        while (la.next()) |x| {
            if (std.mem.eql(u8, x, y)) break;
            if (isNote(x)) return false;
        } else return false;
    }
    while (la.next()) |x| if (isNote(x)) return false;
    return true;
}

fn isNote(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "   = note:") or std.mem.startsWith(u8, line, "   = help:");
}

fn earlier(x: Seen, than: ?Seen) bool {
    const t = than orelse return true;
    return @backingInt(stageOf(x)) < @backingInt(stageOf(t));
}

fn stageOf(x: Seen) stages.Owner {
    if (x.run) return .run;
    const c = std.meta.stringToEnum(Code, x.code) orelse return .run;
    return stages.owner(c);
}

/// The run stage's agent.
fn runOwner(digital: bool) []const u8 {
    return if (digital) "rw-dlower (run)" else "rw-codegen (run)";
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
        .run => runOwner(digital),
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

/// The code of the first diagnostic of `a` whose rendering differs from
/// the same code's same occurrence in `b` (the stage that changed it),
/// or null when every one matches and only their order differs.
fn firstChanged(a: []const u8, b: []const u8) ?[]const u8 {
    var blocks = Blocks{ .text = a };
    // Bounded by `a`'s length: each turn takes one diagnostic.
    while (blocks.next()) |x| {
        if (codeOf(x).len == 0) continue;
        var seen: u32 = 0;
        var mine = Blocks{ .text = a };
        while (mine.next()) |m| {
            if (m.ptr == x.ptr) break;
            if (std.mem.eql(u8, codeOf(m), codeOf(x))) seen += 1;
        }
        var theirs = Blocks{ .text = b };
        const y = while (theirs.next()) |t| {
            if (!std.mem.eql(u8, codeOf(t), codeOf(x))) continue;
            if (seen == 0) break t;
            seen -= 1;
        } else return codeOf(x);
        if (!std.mem.eql(u8, x, y)) return codeOf(x);
    }
    return null;
}

/// A diagnostic block's code (`E0405`), or empty.
fn codeOf(block: []const u8) []const u8 {
    const open = std.mem.findScalar(u8, block, '[') orelse return "";
    return if (block.len >= open + 7 and block[open + 6] == ']') block[open + 1 .. open + 6] else "";
}

/// The codes of a rendered stream's headlines (`error[E0405]:`), in order,
/// each marked when it follows the run banner.
fn codes(arena: Allocator, text: []const u8) ![]const Seen {
    var list: std.ArrayList(Seen) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var after_banner = false;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "=== ") and std.mem.endsWith(u8, line, " ===")) after_banner = true;
        const open = std.mem.findScalar(u8, line, '[') orelse continue;
        if (!(std.mem.startsWith(u8, line, "error[") or std.mem.startsWith(u8, line, "warning["))) continue;
        if (line.len < open + 7 or line[open + 6] != ']') continue;
        try list.append(arena, .{ .code = line[open + 1 .. open + 6], .run = after_banner });
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

test "owner: matching blocks with a different transcript are the run's (J0)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const block = "warning[W0650]: x\n --> a.va:1:1\n\n";
    const old: Run = .{ .status = 0, .stdout = "", .stderr = block ++ "=== t ===\n1\n", .files = &.{} };
    const new: Run = .{ .status = 0, .stdout = "", .stderr = block ++ "=== t ===\n2\n", .files = &.{} };
    try std.testing.expectEqualStrings("rw-codegen (run)", try owner(arena.allocator(), old, new, false));
}

test "owner: W0650 presence alone names no stage (J1); a code after the banner is the run's (J3)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const old: Run = .{ .status = 1, .stdout = "", .stderr = "warning[W0650]: x\n\n=== t ===\nerror[E0601]: y\n\n", .files = &.{} };
    const new: Run = .{ .status = 0, .stdout = "", .stderr = "=== t ===\n", .files = &.{} };
    try std.testing.expectEqualStrings("rw-codegen (run)", try owner(arena.allocator(), old, new, false));
}

test "dropped: a missing note line is not the display phase's" {
    try std.testing.expect(dropped("a\nb\n", "a\n"));
    try std.testing.expect(!dropped("a\n   = note: n\n", "a\n"));
}
