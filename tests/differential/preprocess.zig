//! The differential oracle of the vams `Preprocessor` (`zig build diff-pp`,
//! docs/rewrite/preprocess.md): every `.va`, `.vams` and `.v` fixture under
//! the conformance suite's `tests/` in, a verdict per fixture out. The oracle
//! is lib/frontend's preprocessor, the product until the rewrite replaces
//! it: both run on the same bytes under the settings `vera` uses, the old one
//! reading through `frontend.Files`, the new one answering its requests from
//! the same disk. A fixture agrees when the output text is byte-equal, the
//! diagnostic code lists are equal in order, and each directive event table
//! is equal. A known difference is a line of `preprocess.xfail`
//! (`<path under the fixture root> <reason>`); a listed fixture that agrees,
//! or that is not in the corpus, fails the run until its line goes.
//! Cites: IEEE 1364-2005 §19, LRM §10 (through both implementations).
//!
//! Contents: tests only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const frontend = @import("frontend");
const diag = @import("diag");
const repo_env = @import("repo_env");
const Preprocessor = vams.Preprocessor;
const old_pp = frontend.preprocessor;

/// The fixture header lines (`//@ std`, `//@ protect-keys`) the conformance
/// harness turns into `vera` options, and so into preprocessor options.
const Header = struct { std_1364: bool = false, keys: ?[]const u8 = null };

/// What the agreeing fixtures exercised, printed with the verdict so a
/// green run shows it compared something.
const Coverage = struct { failed: usize = 0, warned: usize = 0, requests: usize = 0, events: usize = 0, bytes: usize = 0 };

/// One side's verdict on a fixture: what the oracle compares.
const Side = struct {
    failed: bool,
    text: []const u8,
    codes: []const []const u8,
};

// ---- private ----

/// Every `.va`, `.vams` and `.v` path under `root`, relative and sorted
/// (`Dir.walk` order is undefined).
fn collect(arena: Allocator, io: std.Io, root: []const u8) ![]const []const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var list: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.path);
        if (!std.mem.eql(u8, ext, ".va") and !std.mem.eql(u8, ext, ".vams") and !std.mem.eql(u8, ext, ".v")) continue;
        try list.append(arena, try arena.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return list.items;
}

/// `preprocess.xfail`: one `<path> <reason>` per line; `#` lines and blank
/// lines are comments. A line without a reason is refused.
fn readXfail(arena: Allocator, io: std.Io, path: []const u8) !std.StringHashMapUnmanaged([]const u8) {
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    const text = try old_pp.readText(io, .cwd(), path, arena);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.findAny(u8, line, " \t") orelse {
            std.debug.print("diff-pp: preprocess.xfail line `{s}` has no reason\n", .{line});
            return error.XfailWithoutReason;
        };
        try map.put(arena, line[0..sp], std.mem.trim(u8, line[sp..], " \t"));
    }
    return map;
}

/// Runs both preprocessors on fixture `rel` and returns null when they
/// agree, else what differs first.
fn compare(a: Allocator, io: std.Io, root: []const u8, rel: []const u8, cov: *Coverage) !?[]const u8 {
    const path = try std.fs.path.join(a, &.{ root, rel });
    const text = try old_pp.readText(io, .cwd(), path, a);
    const dir = std.fs.path.dirname(path).?;
    const include_dirs: []const []const u8 = &.{ dir, try std.fs.path.join(a, &.{ root, "include" }) };
    const hdl_1364 = std.mem.eql(u8, std.fs.path.extension(rel), ".v");
    const header = try readHeader(a, io, dir, text);

    // The old side, as `vera` calls it.
    var bag: diag.Bag = .init(a);
    var files: frontend.Files = .init(io, a);
    const old_out = old_pp.process(a, text, .{
        .file_name = path,
        .include_dirs = include_dirs,
        .std_defs = !hdl_1364,
        .spice_primitives = !hdl_1364,
        .require_std_includes = true,
        .std_1364 = header.std_1364,
        .protect_keys = if (header.keys) |k| try frontend.protect.parseKeys(a, k) else .{},
        .bag = &bag,
        .files = &files,
    });
    var old_codes: std.ArrayList([]const u8) = .empty;
    for (0..bag.count()) |k| try old_codes.append(a, @tagName(bag.at(k).code));
    const old: Side = .{
        .failed = if (old_out) |_| false else |e| switch (e) {
            error.OutOfMemory => return e,
            error.PreprocessFailed => true,
        },
        .text = if (old_out) |o| o.text else |_| "",
        .codes = old_codes.items,
    };

    // The new side, answering its requests from the same disk.
    var pp: Preprocessor = .init(a, .{
        .include_dirs = include_dirs,
        .std_defs = !hdl_1364,
        .spice_primitives = !hdl_1364,
        .require_std_includes = true,
        .std_1364 = header.std_1364,
        .protect_keys = if (header.keys) |k| try Preprocessor.protect.parseKeys(a, k) else .{},
    });
    defer pp.deinit();
    try pp.addUnit(path, text);
    var requests: usize = 0;
    while (try pp.run()) |req| switch (req) {
        .file => |want| {
            requests += 1;
            cov.requests += 1;
            if (requests > 10_000) return "more than 10,000 requests";
            try pp.answer(old_pp.readText(io, .cwd(), want.path, a) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => null,
            });
        },
    };
    const out = pp.output();
    var new_codes: std.ArrayList([]const u8) = .empty;
    for (out.diagnostics) |d| try new_codes.append(a, d.code);
    const new: Side = .{ .failed = out.failed, .text = if (out.failed) "" else out.text, .codes = new_codes.items };

    if (!sameCodes(old.codes, new.codes) or old.failed != new.failed)
        return try a.print("diagnostics: old {s}{s}, new {s}{s}", .{
            try std.mem.join(a, ",", old.codes), if (old.failed) " (failed)" else "",
            try std.mem.join(a, ",", new.codes), if (new.failed) " (failed)" else "",
        });
    if (!std.mem.eql(u8, old.text, new.text)) return try textDiff(a, old.text, new.text);
    cov.bytes += old.text.len;
    if (old.failed) cov.failed += 1 else if (old.codes.len != 0) cov.warned += 1;
    const o = old_out catch return null;
    inline for (@typeInfo(@TypeOf(o.directives)).@"struct".field_names) |name| {
        const x = @field(o.directives, name);
        const y = @field(out.directives, name);
        if (x.len != y.len) return try a.print("directive table {s}: old {d} events, new {d}", .{ name, x.len, y.len });
        cov.events += x.len;
        for (x, y, 0..) |ex, ey, k| if (!same(ex, ey))
            return try a.print("directive table {s}: event {d} differs (old at {d}, new at {d})", .{ name, k, ex.at, ey.at });
    }
    return null;
}

/// The `//@ std` and `//@ protect-keys` lines of a fixture, as
/// tests/conformance/harness/conform.c reads them; the key file is read
/// beside the fixture.
fn readHeader(a: Allocator, io: std.Io, dir: []const u8, text: []const u8) !Header {
    var h: Header = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const rest = std.mem.cutPrefix(u8, line, "//@") orelse continue;
        var words = std.mem.tokenizeAny(u8, rest, " \t");
        const kw = words.next() orelse continue;
        if (std.mem.eql(u8, kw, "std")) h.std_1364 = std.mem.startsWith(u8, words.rest(), "1364");
        if (std.mem.eql(u8, kw, "protect-keys")) {
            const f = words.next() orelse continue;
            h.keys = try old_pp.readText(io, .cwd(), try std.fs.path.join(a, &.{ dir, f }), a);
        }
    }
    return h;
}

fn sameCodes(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    return true;
}

/// The first differing byte and the text around it on each side.
fn textDiff(a: Allocator, old: []const u8, new: []const u8) ![]const u8 {
    const at = std.mem.indexOfDiff(u8, old, new).?;
    const from = at -| 30;
    return a.print("text differs at byte {d} (old {d} bytes, new {d}): old \"{s}\" new \"{s}\"", .{
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

/// Field-for-field equality of an old and a new event row, whose types
/// differ but whose fields and enum tags have the same names.
fn same(x: anytype, y: anytype) bool {
    const X = @TypeOf(x);
    return switch (@typeInfo(X)) {
        .@"struct" => |s| inline for (s.field_names) |f| {
            if (!same(@field(x, f), @field(y, f))) break false;
        } else true,
        .optional => if (x) |xv| (if (y) |yv| same(xv, yv) else false) else y == null,
        .@"enum" => std.mem.eql(u8, @tagName(x), @tagName(y)),
        .float => @as(u64, @bitCast(x)) == @as(u64, @bitCast(y)),
        .pointer => std.mem.eql(u8, x, y),
        else => x == y, // else: bool and the integer offsets
    };
}

test "diff-pp: the vams Preprocessor agrees with lib/frontend's on every fixture" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var run_arena: std.heap.ArenaAllocator = .init(gpa);
    defer run_arena.deinit();
    const ra = run_arena.allocator();
    const root = repo_env.fixtureRoot();

    const fixtures = try collect(ra, io, root);
    const xfail_path = try std.fs.path.join(ra, &.{ repo_env.repoRoot(), "tests/differential/preprocess.xfail" });
    const xfail = try readXfail(ra, io, xfail_path);

    var fixture_arena: std.heap.ArenaAllocator = .init(gpa);
    defer fixture_arena.deinit();
    var agreed: usize = 0;
    var listed: usize = 0;
    var bad: usize = 0;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var cov: Coverage = .{};
    for (fixtures) |rel| {
        _ = fixture_arena.reset(.retain_capacity);
        const a = fixture_arena.allocator();
        try seen.put(ra, rel, {});
        const why = try compare(a, io, root, rel, &cov);
        const reason = xfail.get(rel);
        if (why) |w| {
            if (reason != null) {
                listed += 1;
                continue;
            }
            bad += 1;
            std.debug.print("diff-pp: MISMATCH {s}: {s}\n", .{ rel, w });
        } else if (reason) |r| {
            bad += 1;
            std.debug.print("diff-pp: XPASS {s} agrees; remove its preprocess.xfail line ({s})\n", .{ rel, r });
        } else agreed += 1;
    }
    var it = xfail.keyIterator();
    while (it.next()) |k| if (!seen.contains(k.*)) {
        bad += 1;
        std.debug.print("diff-pp: STALE {s} is in preprocess.xfail but not in the corpus\n", .{k.*});
    };
    std.debug.print("diff-pp: {d} fixtures compared, {d} agreed, {d} listed in preprocess.xfail, {d} failed\n", .{ fixtures.len, agreed, listed, bad });
    std.debug.print("diff-pp: compared {d} text bytes, {d} directive events, {d} diagnosed fixtures, {d} warned, {d} file requests\n", .{ cov.bytes, cov.events, cov.failed, cov.warned, cov.requests });
    try std.testing.expect(fixtures.len > 4000);
    try std.testing.expectEqual(@as(usize, 0), bad);
}
