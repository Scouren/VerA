//! How a differential oracle settles a difference without an `.xfail` line
//! (docs/rewrite/README.md rule 3), shared by diff-parse, diff-astgen,
//! diff-elab and diff-diag:
//! - stage ownership: `codesDiffer` compares two code sets inside an
//!   oracle's window of stages, by `stages.ownerUnder` and the fixture's
//!   `//! lrm` clauses: a code its stages own both ways, a later stage's one
//!   way (the new side raised it only where the old did), an earlier
//!   stage's not at all (its own oracle does);
//! - rulings: `Rulings` reads `<oracle>.rulings`, one line per fixture where
//!   the LRM sides with the new code: `<path> | <clause> | new | <expected>
//!   | <why>`. A ruling settles a disagreement only when the fixture cites
//!   the clause (`//! lrm`) and the new side gives the expected result,
//!   which each oracle states in its own terms.
//! Cites no LRM clause: each ruling cites its own.
//!
//! Contents:
//! - `pub const stages` (`stages.zig`), `pub const Owner`
//! - `pub const Window = struct { first, last }`
//! - `pub const Codes = struct { why, later }`
//! - `pub const Later = struct` (`add`, `print`)
//! - `pub const Ruling = struct { clause, expected, why }`
//! - `pub const Rulings = struct` (`read`, `get`, `settle`, `finish`)
//! - `pub fn clauses(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8`
//! - `pub fn codesDiffer(arena: Allocator, old: []const []const u8, new: []const []const u8, window: Window, cited: []const []const u8) !Codes`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Diag = @import("vams").Diag;
pub const stages = @import("stages.zig");

/// The stages of the new pipeline, in order.
pub const Owner = stages.Owner;

/// The stages whose output an oracle observes on both sides.
pub const Window = struct { first: Owner, last: Owner };

/// `codesDiffer`'s answer: the first disagreement, or null; and the old
/// side's codes a later stage owns that the new side did not raise.
pub const Codes = struct { why: ?[]const u8, later: []const []const u8 };

/// How many fixtures set aside each later stage's code (`Codes.later`),
/// printed with an oracle's summary so the codes a later oracle must still
/// demand are named.
pub const Later = struct {
    /// Holds the counts and their keys, `E0207 (sema)`.
    arena: Allocator,
    counts: std.StringArrayHashMapUnmanaged(u32) = .empty,

    /// Counts each of `codes` (set aside in a fixture citing `cited`) once more.
    pub fn add(l: *Later, codes: []const []const u8, cited: []const []const u8) Allocator.Error!void {
        for (codes) |c| {
            const key = try std.fmt.allocPrint(l.arena, "{s} ({t})", .{ c, ownerOf(c, cited) });
            const slot = try l.counts.getOrPut(l.arena, key);
            slot.value_ptr.* = if (slot.found_existing) slot.value_ptr.* + 1 else 1;
        }
    }

    /// Writes one line naming every code set aside, with its owner and count.
    pub fn print(l: *const Later, w: *Io.Writer, oracle: []const u8) !void {
        if (l.counts.count() == 0) return;
        const keys = try l.arena.dupe([]const u8, l.counts.keys());
        std.mem.sort([]const u8, keys, {}, lessThan);
        try w.print("{s}: a later stage's codes, raised by the old side and left to that stage's oracle:", .{oracle});
        for (keys) |c| try w.print(" {s} x{d}", .{ c, l.counts.get(c).? });
        try w.writeAll("\n");
    }
};

/// One ruling: the clause it rests on, the result the oracle expects of the
/// new side (in that oracle's terms), and why the LRM supports it.
pub const Ruling = struct { clause: []const u8, expected: []const u8, why: []const u8 };

/// An oracle's rulings by fixture path, and which ones settled a difference.
pub const Rulings = struct {
    /// Holds the table and `used` for the whole run.
    arena: Allocator,
    name: []const u8,
    map: std.StringArrayHashMapUnmanaged(Ruling) = .empty,
    used: std.StringHashMapUnmanaged(void) = .empty,

    /// Reads `tests/differential/<name>.rulings` under `repo_root`; `#` and
    /// blank lines are comments. A line that is not five `|` fields, or
    /// that sides with the old code, is refused: the LRM supporting the old
    /// side is a bug in the new code, not a ruling.
    pub fn read(arena: Allocator, io: Io, repo_root: []const u8, name: []const u8) !Rulings {
        const path = try std.fmt.allocPrint(arena, "{s}/tests/differential/{s}.rulings", .{ repo_root, name });
        const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
        var r: Rulings = .{ .arena = arena, .name = name };
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            var f: [5][]const u8 = undefined;
            var it = std.mem.splitSequence(u8, line, " | ");
            for (&f) |*x| x.* = std.mem.trim(u8, it.next() orelse return error.RulingNeedsFiveFields, " ");
            if (it.next() != null) return error.RulingNeedsFiveFields;
            if (!std.mem.eql(u8, f[2], "new")) return error.RulingForTheOldSide;
            if (f[1].len == 0 or f[3].len == 0 or f[4].len == 0) return error.RulingFieldEmpty;
            try r.map.put(arena, f[0], .{ .clause = f[1], .expected = f[3], .why = f[4] });
        }
        return r;
    }

    /// The ruling on fixture `path`, if any.
    pub fn get(r: *const Rulings, path: []const u8) ?Ruling {
        return r.map.get(path);
    }

    /// Settles a disagreement on `path` (a fixture citing `cited`) whose new
    /// side gave `got`, in the oracle's terms: null when a ruling names the
    /// fixture, the fixture cites its clause and `got` is its expected
    /// result; else why not, in `arena`. `path` must outlive the run.
    pub fn settle(r: *Rulings, arena: Allocator, path: []const u8, cited: []const []const u8, got: []const u8) !?[]const u8 {
        const ruling = r.get(path) orelse return "no ruling";
        if (!contains(cited, ruling.clause)) return try arena.print("its ruling cites §{s}, which the fixture's `//! lrm` lines do not", .{ruling.clause});
        if (!std.mem.eql(u8, got, ruling.expected)) return try arena.print("its ruling expects `{s}` of the new side, which gives `{s}`", .{ ruling.expected, got });
        try r.used.put(r.arena, path, {});
        return null;
    }

    /// Prints every ruling that settled a difference and returns how many
    /// rulings did not: each must, or its line goes.
    pub fn finish(r: *const Rulings, w: *Io.Writer) !u32 {
        var unused: u32 = 0;
        for (r.map.keys(), r.map.values()) |path, ruling| {
            if (r.used.contains(path)) {
                try w.print("RULING {s}: §{s}, the new side's `{s}`: {s}\n", .{ path, ruling.clause, ruling.expected, ruling.why });
            } else {
                unused += 1;
                try w.print("STALE {s}: {s}.rulings settles no difference here; delete its line\n", .{ path, r.name });
            }
        }
        return unused;
    }
};

/// A fixture's `//! lrm` clauses (`4.4`, `4.4:1`) and its `//! inherited`
/// IEEE 1364-2005 ones (`IEEE 1364-2005 12.3.3`), in file order.
pub fn clauses(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "//! lrm ")) {
            var it = std.mem.tokenizeAny(u8, line["//! lrm ".len..], " \t");
            while (it.next()) |c| try out.append(arena, c);
        } else if (std.mem.startsWith(u8, line, "//! inherited IEEE 1364-2005 ")) {
            var it = std.mem.tokenizeAny(u8, line["//! inherited IEEE 1364-2005 ".len..], " \t");
            while (it.next()) |c| try out.append(arena, try std.mem.concat(arena, u8, &.{ "IEEE 1364-2005 ", c }));
        }
    }
    return out.items;
}

/// Compares `old` and `new` (code spellings, sorted and deduplicated) in
/// `window` for a fixture citing `cited`: a code owned inside the window is
/// on both sides or neither; one owned after it may be on the new side only
/// when it is on the old; one owned before it is another oracle's.
pub fn codesDiffer(arena: Allocator, old: []const []const u8, new: []const []const u8, window: Window, cited: []const []const u8) !Codes {
    assert(@backingInt(window.first) <= @backingInt(window.last));
    var later: std.ArrayList([]const u8) = .empty;
    var wrong = false;
    for (old) |c| {
        const o = ownerOf(c, cited);
        if (@backingInt(o) < @backingInt(window.first)) continue;
        if (contains(new, c)) continue;
        if (@backingInt(o) > @backingInt(window.last)) {
            if (!contains(later.items, c)) try later.append(arena, c);
        } else wrong = true;
    }
    for (new) |c| {
        if (@backingInt(ownerOf(c, cited)) < @backingInt(window.first)) continue;
        if (!contains(old, c)) wrong = true;
    }
    assert(later.items.len <= old.len);
    if (!wrong) return .{ .why = null, .later = later.items };
    return .{ .why = try arena.print("codes: old {s}, new {s} (stages {t}..{t})", .{ try join(arena, old), try join(arena, new), window.first, window.last }), .later = later.items };
}

// ---- private ----

fn ownerOf(spelling: []const u8, cited: []const []const u8) Owner {
    const c = std.meta.stringToEnum(Diag.Code, spelling) orelse unreachable; // the old and new catalogues are one (diff-diag)
    return stages.ownerUnder(c, cited);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn contains(set: []const []const u8, x: []const u8) bool {
    for (set) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

fn join(arena: Allocator, set: []const []const u8) ![]const u8 {
    return if (set.len == 0) "{}" else std.mem.join(arena, ",", set);
}
