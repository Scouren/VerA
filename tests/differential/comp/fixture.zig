//! diff-comp's fixtures: the conformance harness's tests under the fixture
//! root and the command line its `vera.conf` gives each one
//! (`tests/conformance/harness/conform.c` `collect`, `parse`, `run_one`;
//! `tests/conformance/tools/vera.conf`'s `run.<language>` rows), so both
//! drivers see exactly what `zig build conformance` hands `vera`.
//! No LRM clause: this mirrors the harness.
//!
//! Contents:
//! - `pub const Lang = enum`, `pub const Fixture = struct`
//! - `pub fn collect(arena: Allocator, io: Io, root: []const u8) ![]const Fixture`
//! - `pub fn argv(arena: Allocator, f: Fixture, root: []const u8) ![]const []const u8`

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The directory under the root a test sits in (conform's `locate`).
pub const Lang = enum { verilog_a, verilog_ams, spice, verilog, vpi };

/// One test: where it is, its language and what its `//!` and `//@`
/// lines tell the harness.
pub const Fixture = struct {
    /// Relative to the fixture root.
    rel: []const u8,
    lang: Lang,
    /// Neither `//! reject` nor a line or gold that needs a run: the
    /// harness only compiles it (`CONFORM_COMPILE_ONLY`).
    compile_only: bool,
    reject: bool,
    /// `//@ files`, `libmap`, `protect-keys` (absolute), `liblist`, `std`.
    files: []const []const u8 = &.{},
    libmap: []const []const u8 = &.{},
    liblist: []const []const u8 = &.{},
    protect_keys: []const []const u8 = &.{},
    std_: ?[]const u8 = null,
};

/// Most `//!`/`//@` lines one fixture is read for: a fixture is a few
/// hundred lines; past this the reader is looping.
const lines_max: u32 = 1 << 20;

/// conform's metadata keywords: every other `//!` keyword needs a run.
const meta = [_][]const u8{ "lrm", "inherited", "lrm-reject", "inherited-reject", "neighbour", "reject", "reject-only", "warn", "nowarn" };

/// Every test under `root` as conform collects it (a `.va`, `.vams`,
/// `.v` or `.c` with a `//!` line or a gold beside it, never under
/// `include/`), sorted by path; a `.sp` deck (`netlist`) has no `vera`
/// command and is left to the SPICE suites.
pub fn collect(arena: Allocator, io: Io, root: []const u8) ![]const Fixture {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var list: std.ArrayList(Fixture) = .empty;
    while (try walker.next(io)) |e| {
        if (e.kind != .file) continue;
        const rel = try arena.dupe(u8, e.path);
        const slash = std.mem.findScalar(u8, rel, '/') orelse continue;
        const top = rel[0..slash];
        if (std.mem.eql(u8, top, "include") or std.mem.find(u8, rel, "/include/") != null) continue;
        const ext = std.fs.path.extension(rel);
        const lang: Lang = if (std.mem.eql(u8, ext, ".c")) .vpi else if (std.mem.eql(u8, top, "verilog-a")) .verilog_a else if (std.mem.eql(u8, top, "verilog-ams")) .verilog_ams else if (std.mem.eql(u8, top, "spice")) .spice else if (std.mem.eql(u8, top, "verilog")) .verilog else continue;
        if (!(std.mem.eql(u8, ext, ".va") or std.mem.eql(u8, ext, ".vams") or std.mem.eql(u8, ext, ".v") or std.mem.eql(u8, ext, ".c"))) continue;
        const text = try dir.readFileAlloc(io, rel, arena, .limited(1 << 26));
        const stem = rel[0 .. rel.len - ext.len];
        const has_gold = exists(io, dir, try std.fmt.allocPrint(arena, "{s}.expected.txt", .{stem})) or exists(io, dir, try std.fmt.allocPrint(arena, "{s}.expected.json", .{stem}));
        // conform's `app_of`: a design its same-stem `.c` names with
        // `//! design` runs as that VPI application.
        const app = if (lang == .vpi) false else if (dir.readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}.c", .{stem}), arena, .limited(1 << 22))) |c|
            std.mem.find(u8, c, try std.fmt.allocPrint(arena, "//! design {s}", .{std.fs.path.basename(rel)})) != null
        else |_|
            false;
        var f = (try parse(arena, root, rel, text, if (app) .vpi else lang)) orelse continue;
        if (!has_gold and !f.directive) continue;
        if (has_gold) f.fixture.compile_only = false;
        if (std.mem.find(u8, text, "`CHECK") != null or std.mem.find(u8, text, "ok=") != null) f.fixture.compile_only = false;
        f.fixture.compile_only = f.fixture.compile_only and !f.fixture.reject;
        try list.append(arena, f.fixture);
    }
    std.mem.sort(Fixture, list.items, {}, struct {
        fn lt(_: void, a: Fixture, b: Fixture) bool {
            return std.mem.lessThan(u8, a.rel, b.rel);
        }
    }.lt);
    return list.items;
}

/// The arguments `vera.conf`'s `run.<lang>` row passes (after the
/// executable), every path absolute under `root`.
pub fn argv(arena: Allocator, f: Fixture, root: []const u8) ![]const []const u8 {
    assert(f.lang != .vpi);
    const src = try std.fs.path.join(arena, &.{ root, f.rel });
    const dir = std.fs.path.dirname(src).?;
    const include = try std.fs.path.join(arena, &.{ root, "include" });
    var a: std.ArrayList([]const u8) = .empty;
    switch (f.lang) {
        .verilog_a => try a.appendSlice(arena, &.{ if (f.compile_only) "--check" else "--run", "--sim=verilogA", "--no-std-defs", "-I", include, "-I", dir, src }),
        .verilog_ams => {
            try a.appendSlice(arena, &.{ if (f.compile_only) "--check" else "--run", "--no-std-defs" });
            if (f.std_) |s| try a.append(arena, try std.fmt.allocPrint(arena, "--std={s}", .{s}));
            try a.appendSlice(arena, &.{ "-I", include, "-I", dir, src });
        },
        .spice => try a.appendSlice(arena, &.{ "--run", "--no-std-defs", "-I", include, "-I", dir, src }),
        .verilog => {
            try a.appendSlice(arena, &.{ if (f.compile_only) "--elab" else "--run", src, "-I", dir, "-I", include });
            if (f.std_) |s| try a.append(arena, try std.fmt.allocPrint(arena, "--std={s}", .{s}));
            for (f.protect_keys) |k| try a.appendSlice(arena, &.{ "--protect-keys", k });
            for (f.libmap) |m| try a.appendSlice(arena, &.{ "--libmap", m });
            for (f.liblist) |l| try a.appendSlice(arena, &.{ "-L", l });
            try a.appendSlice(arena, f.files);
        },
        .vpi => unreachable,
    }
    return a.items;
}

// ---- private ----

fn exists(io: Io, dir: Io.Dir, sub: []const u8) bool {
    dir.access(io, sub, .{}) catch return false;
    return true;
}

/// conform's `parse`: the fixture's `//!` and `//@` lines; null for a
/// `//@` keyword conform refuses. `directive`: a `//!` line with a
/// keyword (`is_test`).
fn parse(arena: Allocator, root: []const u8, rel: []const u8, text: []const u8, lang: Lang) !?struct { fixture: Fixture, directive: bool } {
    const dir = std.fs.path.dirname(try std.fs.path.join(arena, &.{ root, rel })).?;
    var f: Fixture = .{ .rel = rel, .lang = lang, .compile_only = true, .reject = false };
    var directive = false;
    var files: std.ArrayList([]const u8) = .empty;
    var libmap: std.ArrayList([]const u8) = .empty;
    var liblist: std.ArrayList([]const u8) = .empty;
    var keys: std.ArrayList([]const u8) = .empty;
    var std_words: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: u32 = 0;
    while (lines.next()) |raw| : (n += 1) {
        if (n == lines_max) return error.TooManyLines;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.cutPrefix(u8, line, "//@")) |rest| {
            var words = std.mem.tokenizeAny(u8, rest, " \t");
            const kw = words.next() orelse continue;
            const list: ?*std.ArrayList([]const u8) = if (std.mem.eql(u8, kw, "files")) &files else if (std.mem.eql(u8, kw, "libmap")) &libmap else if (std.mem.eql(u8, kw, "protect-keys")) &keys else null;
            if (list) |l| {
                while (words.next()) |w| try l.append(arena, try std.fs.path.join(arena, &.{ dir, w }));
            } else if (std.mem.eql(u8, kw, "liblist")) {
                while (words.next()) |w| try liblist.append(arena, w);
            } else if (std.mem.eql(u8, kw, "std")) {
                while (words.next()) |w| {
                    if (std_words.items.len != 0) try std_words.append(arena, ' ');
                    try std_words.appendSlice(arena, w);
                }
            } else return null;
            continue;
        }
        const rest = std.mem.cutPrefix(u8, line, "//!") orelse continue;
        const d = std.mem.trimStart(u8, rest, " \t");
        if (d.len == 0) continue;
        if (lang == .vpi and !std.mem.startsWith(u8, d, "design ")) continue;
        directive = true;
        const kw = d[0 .. std.mem.findAny(u8, d, " \t\r") orelse d.len];
        if (std.mem.eql(u8, kw, "reject") or std.mem.eql(u8, kw, "reject-only")) f.reject = true;
        const is_meta = for (meta) |m| {
            if (std.mem.eql(u8, m, kw)) break true;
        } else false;
        if (!is_meta) f.compile_only = false;
    }
    f.files = files.items;
    f.libmap = libmap.items;
    f.liblist = liblist.items;
    f.protect_keys = keys.items;
    if (std_words.items.len != 0) f.std_ = std_words.items;
    return .{ .fixture = f, .directive = directive };
}
