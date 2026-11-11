//! The differential oracle of the vams `Diag` (`zig build diff-diag`,
//! docs/rewrite/diag.md). The oracle is lib/diag, the product until the
//! rewrite replaces it. The corpora:
//!
//! - The catalogue: every old `Code` exists in the new one under the same
//!   name and tag number, with the same title, LRM clause and explain text;
//!   `--explain` writes the same bytes for every code in both palettes.
//! - Scripts: seeded reports (every stage, code, label, note, help and
//!   fix-it shape, locations none, zero-width, inverted, past the end, in
//!   two files and an unknown one, duplicates, past the cap, under seeded
//!   lint levels) built both ways from the same script, the old `Bag` +
//!   `Builder` and the new `Wip`.
//! - Levels: every code at every level with a message, a label, a note and
//!   a fix-it; every `level=code` directive (and malformed ones) through
//!   `parseFlag` in a seeded order; `editDistance` and `didYouMean` over
//!   every pair of the catalogue's title words.
//! - Fixtures: every conformance `.va`/`.vams` fixture with a `//! reject`
//!   or `//! warn` line, through the old `vera.analyze`; each kept row is
//!   copied into a `Wip`, its spans resolved through the old file table and
//!   strip marks into the file locations the new `Loc` holds.
//!
//! Rendered text agrees byte for byte in both palettes. A JSON line agrees
//! byte for byte, or, where the old `byte_start`/`byte_end` count in the
//! preprocessed text the new bundle no longer has, field for field with the
//! offsets held to a relation: in a script, old = new + the file's base in
//! the old preprocessed text; in a fixture, the new `byte_start` is the
//! offset of the old line and column in the original file. A fixture that
//! may differ is a line of `diag.xfail` (`<path> <reason>`); a listed
//! fixture that agrees, or is not in the corpus, fails the run. A fixture
//! where the LRM sides with the new bundle is a line of `diag.rulings`
//! (`settle.zig`), whose expected result is the new bundle's rows in order,
//! each `CODE@line:col` in the original file.
//!
//! Cites no LRM clause: the catalogue rows cite their own.
//!
//! Contents: tests only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Random = std.Random;
const vams = @import("vams");
const diag = @import("diag");
const vera = @import("vera");
const frontend = @import("frontend");
const repo_env = @import("repo_env");
const settle = @import("settle.zig");
const Diag = vams.Diag;

/// The scripts' files: name, original text, and where the old preprocessed
/// text puts them. The third has no `Source`: an unknown file.
const files = [_]struct { name: []const u8, text: []const u8, base: u32, id: u16 }{
    .{ .name = "a.va", .text = text_a, .base = 0, .id = 0 },
    .{ .name = "b.vams", .text = text_b, .base = text_a.len, .id = 1 },
    .{ .name = "<source>", .text = "", .base = 1 << 30, .id = 7 },
};

const text_a =
    "module m(a, b);\n" ++
    "\tinout a, b;\n" ++
    "  electrical a, b; // µ ✓ comment\n" ++
    "  parameter real k = 1.0;\r\n" ++
    "  analog begin\n" ++
    "    I(a, b) <+ V(a, b) / k;\n" ++
    "  end\n" ++
    "\n" ++
    "\n" ++
    "  // line ten\n" ++
    "  // line eleven, a longer one than the others, to clamp against\n" ++
    "\t\treal x;\n" ++
    "endmodule\n";
const text_b = "`define W 3\nmodule n;\nendmodule";

/// Texts the scripts format into every part: empty, quotes, escapes,
/// control bytes, tabs, multi-byte UTF-8, a newline.
const pool = [_][]const u8{ "", "x", "`k` is \"quoted\"", "back\\slash", "tab\there", "µ ✓ unicode", "ctl\x01\x1f", "two\nlines", " from (0:inf)" };

/// Where a script puts a location: `file` indexes `files`, or is `none_file`.
const Where = struct { file: u8, start: u32, end: u32 };
const none_file: u8 = files.len;

const Part = struct { kind: enum { label, note, help, fix, here }, where: Where, text: []const u8 };

/// One diagnostic, as both sides are told to build it.
const Report = struct {
    stage: u3,
    code: u16,
    where: Where,
    msg: ?[]const u8,
    point: ?[]const u8,
    parts: []const Part,
};

/// What a corpus agreed on, printed with the verdict.
const Tally = struct { bundles: usize = 0, rows: usize = 0, text_bytes: usize = 0, json_exact: usize = 0, json_relation: usize = 0, level_sets: usize = 0 };

/// One `Levels.set` a script makes on both sides before it reports.
const LevelSet = struct { code: u16, level: Diag.Level };

/// How a JSON comparison holds the byte offsets of one span.
const Offsets = union(enum) {
    /// A script: old = new + the base of the span's file.
    script,
    /// A fixture: the new `byte_start` is the old line and column's offset
    /// in the original text of the named source.
    fixture: []const Diag.Source,
};

/// What `compareFixture` found: what differs first, or null; the new
/// bundle's rows as a ruling reads them; and the fixture's `//! lrm` clauses.
const FixtureVerdict = struct { why: ?[]const u8, rows: []const u8 = "", cited: []const []const u8 = &.{} };

// ---- private ----

fn oldSpan(w: Where) diag.Span {
    if (w.file == none_file) return .none;
    const base = files[w.file].base;
    return .{ .start = base +| w.start, .end = base +| w.end };
}

fn newLoc(w: Where) Diag.Loc {
    if (w.file == none_file) return .none;
    return .{ .file = @fromBackingInt(files[w.file].id), .start = w.start, .end = w.end };
}

fn genWhere(r: Random, allow_none: bool) Where {
    if (allow_none and r.uintLessThan(u8, 20) == 0) return .{ .file = none_file, .start = 0, .end = 0 };
    const f = r.uintLessThan(u8, 10);
    const file: u8 = if (f < 6) 0 else if (f < 9) 1 else 2;
    // File 0 starts at 1: old offset 0 with a zero end is `Span.none`. Its
    // starts stay inside it, or the old segment search lands in file 1.
    const start = switch (file) {
        0 => r.intRangeAtMost(u32, 1, text_a.len - 1),
        1 => r.uintLessThan(u32, text_b.len + 6),
        else => r.uintLessThan(u32, 1000),
    };
    const d = r.uintLessThan(u32, 40);
    const end = switch (r.uintLessThan(u8, 10)) {
        0 => start,
        1 => start -| d,
        2 => if (file == 0) std.math.maxInt(u32) else start + d,
        else => start + d,
    };
    return .{ .file = file, .start = start, .end = end };
}

fn genReport(a: Allocator, r: Random, prev: ?Report) !Report {
    // A duplicate of the last report now and then: the dedupe key.
    if (prev) |p| if (r.uintLessThan(u8, 8) == 0) return p;
    const n_codes = @typeInfo(Diag.Code).@"enum".field_names.len;
    const where = genWhere(r, true);
    const parts = try a.alloc(Part, r.uintLessThan(usize, 8));
    for (parts) |*p| {
        const kind = r.enumValueWithIndex(@FieldType(Part, "kind"), u8);
        p.* = .{
            .kind = if (kind == .here and where.file == none_file) .help else kind,
            // A fix always has a location: the old renderer draws one with
            // none at the root's first line, the new one draws nothing.
            .where = genWhere(r, kind == .label),
            .text = pool[r.uintLessThan(usize, pool.len)],
        };
    }
    return .{
        .stage = r.uintLessThan(u3, 6),
        .code = r.uintLessThan(u16, n_codes),
        .where = where,
        .msg = if (r.boolean()) pool[r.uintLessThan(usize, pool.len)] else null,
        .point = if (r.uintLessThan(u8, 4) == 0) pool[r.uintLessThan(usize, pool.len)] else null,
        .parts = parts,
    };
}

fn buildOld(bag: *diag.Bag, rep: Report) !void {
    const stage: diag.Stage = @fromBackingInt(@as(u8, rep.stage));
    var b = bag.build(stage, @fromBackingInt(rep.code), oldSpan(rep.where));
    if (rep.msg) |m| b.msg("{s}", .{m});
    if (rep.point) |p| b.point("{s}", .{p});
    for (rep.parts) |p| switch (p.kind) {
        .label => b.label(oldSpan(p.where), "{s}", .{p.text}),
        .note => b.note("{s}", .{p.text}),
        .help => b.help("{s}", .{p.text}),
        .fix => b.suggest(.{ .span = oldSpan(p.where), .replacement = p.text }, "{s}", .{p.text}),
        .here => b.suggestHere(p.text),
    };
    try b.emit();
}

fn buildNew(wip: *Diag.Wip, rep: Report) !void {
    const stage: Diag.Stage = @fromBackingInt(rep.stage);
    var b = wip.build(stage, @fromBackingInt(rep.code), newLoc(rep.where));
    if (rep.msg) |m| b.msg("{s}", .{m});
    if (rep.point) |p| b.point("{s}", .{p});
    for (rep.parts) |p| switch (p.kind) {
        .label => b.label(newLoc(p.where), "{s}", .{p.text}),
        .note => b.note("{s}", .{p.text}),
        .help => b.help("{s}", .{p.text}),
        .fix => b.suggest(.{ .loc = newLoc(p.where), .replacement = p.text }, "{s}", .{p.text}),
        .here => b.suggestHere(p.text),
    };
    try b.emit();
}

/// Renders both sides every way and returns null when they agree, else
/// what differs first.
fn compareRendered(a: Allocator, bag: *diag.Bag, d: Diag, sources: []const Diag.Source, offsets: Offsets, opts: diag.RenderOptions, tally: *Tally) !?[]const u8 {
    for ([_]bool{ false, true }) |colour| {
        var o: std.Io.Writer.Allocating = .init(a);
        var n: std.Io.Writer.Allocating = .init(a);
        try diag.render(bag, &o.writer, .{ .palette = if (colour) .on else .off, .explain_hint = opts.explain_hint, .summary = opts.summary });
        try d.render(sources, &n.writer, .{ .palette = if (colour) .on else .off, .explain_hint = opts.explain_hint, .summary = opts.summary });
        if (!std.mem.eql(u8, o.written(), n.written())) return try textDiff(a, if (colour) "text (colour)" else "text", o.written(), n.written());
        tally.text_bytes += o.written().len;
    }
    var o: std.Io.Writer.Allocating = .init(a);
    var n: std.Io.Writer.Allocating = .init(a);
    try diag.renderJson(bag, &o.writer);
    try d.renderJson(sources, &n.writer);
    var ol = std.mem.splitScalar(u8, o.written(), '\n');
    var nl = std.mem.splitScalar(u8, n.written(), '\n');
    while (ol.next()) |x| {
        const y = nl.next() orelse return "json: the new side has fewer lines";
        if (std.mem.eql(u8, x, y)) {
            tally.json_exact += @intFromBool(x.len != 0);
            continue;
        }
        const xv = try std.json.parseFromSliceLeaky(std.json.Value, a, x, .{});
        const yv = try std.json.parseFromSliceLeaky(std.json.Value, a, y, .{});
        if (try jsonDiff(a, xv, yv, offsets)) |why| return try a.print("json: {s}\n  old {s}\n  new {s}", .{ why, x, y });
        tally.json_relation += 1;
    }
    if (nl.next() != null) return "json: the new side has more lines";
    tally.bundles += 1;
    tally.rows += bag.count();
    return null;
}

/// Field-for-field equality of two JSON values; a span object's byte
/// offsets are held to `offsets` instead.
fn jsonDiff(a: Allocator, x: std.json.Value, y: std.json.Value, offsets: Offsets) !?[]const u8 {
    if (std.meta.activeTag(x) != std.meta.activeTag(y)) return "a value changed type";
    switch (x) {
        .object => |xo| {
            const yo = y.object;
            if (xo.count() != yo.count()) return "an object changed shape";
            if (xo.get("byte_start") != null) return spanDiff(xo, yo, offsets);
            for (xo.keys(), xo.values(), yo.keys(), yo.values()) |xk, xval, yk, yval| {
                if (!std.mem.eql(u8, xk, yk)) return "an object changed keys";
                if (try jsonDiff(a, xval, yval, offsets)) |why| return why;
            }
        },
        .array => |xa| {
            if (xa.items.len != y.array.items.len) return "an array changed length";
            for (xa.items, y.array.items) |xi, yi| if (try jsonDiff(a, xi, yi, offsets)) |why| return why;
        },
        .string => |s| if (!std.mem.eql(u8, s, y.string)) return "a string differs",
        .integer => |i| if (i != y.integer) return "a number differs",
        .null => {},
        else => return "an unexpected JSON value", // else: lib/diag writes no bool or float
    }
    return null;
}

fn spanDiff(xo: std.json.ObjectMap, yo: std.json.ObjectMap, offsets: Offsets) !?[]const u8 {
    const name = xo.get("file").?.string;
    if (!std.mem.eql(u8, name, yo.get("file").?.string)) return "a span's file differs";
    const line = xo.get("line").?.integer;
    const col = xo.get("col").?.integer;
    if (line != yo.get("line").?.integer or col != yo.get("col").?.integer) return "a span's line or column differs";
    const os = xo.get("byte_start").?.integer;
    const oe = xo.get("byte_end").?.integer;
    const ns = yo.get("byte_start").?.integer;
    const ne = yo.get("byte_end").?.integer;
    switch (offsets) {
        .script => {
            const base: i64 = for (files) |f| {
                if (std.mem.eql(u8, f.name, name)) break f.base;
            } else return "a span in no script file";
            if (os != base + ns) return "byte_start is not the old one less the file's base";
            if (oe != @min(base + ne, std.math.maxInt(u32))) return "byte_end is not the old one less the file's base";
        },
        .fixture => |sources| {
            const text = for (sources) |s| {
                if (std.mem.eql(u8, s.name, name)) break s.text;
            } else "";
            // The offset of `line` by a newline count, not the renderer's.
            var start: usize = 0;
            for (1..@intCast(line)) |_| start = (std.mem.findScalarPos(u8, text, start, '\n') orelse return "line past the text") + 1;
            if (ns != @as(i64, @intCast(start)) + col - 1) return "byte_start is not the old line and column";
            if (ne < ns) return "byte_end before byte_start";
        },
    }
    return null;
}

/// One script bundle: `n` reports from `r`, under a few random lint
/// levels half the time, built both ways and compared.
fn scriptBundle(a: Allocator, r: Random, n: usize, tally: *Tally) !?[]const u8 {
    const n_codes = @typeInfo(Diag.Code).@"enum".field_names.len;
    const sets = try a.alloc(LevelSet, if (r.boolean()) r.uintLessThan(usize, 12) else 0);
    for (sets) |*l| l.* = .{ .code = r.uintLessThan(u16, n_codes), .level = r.enumValueWithIndex(Diag.Level, u8) };
    const reports = try a.alloc(Report, n);
    var prev: ?Report = null;
    for (reports) |*rep| {
        rep.* = try genReport(a, r, prev);
        prev = rep.*;
    }
    return compareScript(a, reports, sets, .{ .explain_hint = r.boolean(), .summary = r.boolean() }, tally);
}

/// Sets `sets` in order on both sides (each refusal must agree), builds
/// `reports` both ways, and compares every rendering.
fn compareScript(a: Allocator, reports: []const Report, sets: []const LevelSet, opts: diag.RenderOptions, tally: *Tally) !?[]const u8 {
    var bag: diag.Bag = .init(a);
    _ = try bag.addFile(files[0].name, files[0].text);
    _ = try bag.addFile(files[1].name, files[1].text);
    const segs = [_]diag.Segment{
        .{ .out_start = files[0].base, .in_start = 0, .file = @fromBackingInt(files[0].id), .kind = .verbatim },
        .{ .out_start = files[1].base, .in_start = 0, .file = @fromBackingInt(files[1].id), .kind = .verbatim },
        .{ .out_start = files[2].base, .in_start = 0, .file = @fromBackingInt(files[2].id), .kind = .verbatim },
    };
    bag.map = .{ .segs = &segs };
    var wip: Diag.Wip = .init(a);
    for (sets) |l| {
        const old = bag.levels.set(@fromBackingInt(l.code), std.meta.stringToEnum(diag.Level, @tagName(l.level)).?);
        const new = wip.levels.set(@fromBackingInt(l.code), l.level);
        if (!std.mem.eql(u8, outcome(old), outcome(new))) return try a.print("levels: set({d}, {t}) is {s} old, {s} new", .{ l.code, l.level, outcome(old), outcome(new) });
        tally.level_sets += 1;
    }
    for (reports) |rep| {
        try buildOld(&bag, rep);
        try buildNew(&wip, rep);
        if (bag.enabled(@fromBackingInt(rep.code)) != wip.enabled(@fromBackingInt(rep.code))) return "enabled differs";
    }
    if (bag.failed() != wip.failed()) return "failed differs";
    const d = try wip.toOwnedBundle();
    var sources: [2]Diag.Source = undefined;
    for (&sources, files[0..2]) |*s, f| s.* = .{ .name = f.name, .text = f.text, .line_starts = try Diag.lineStarts(a, f.text) };
    return compareRendered(a, &bag, d, &sources, .script, opts, tally);
}

/// A `Levels.set` result as text, so the old and new error sets compare.
fn outcome(r: anytype) []const u8 {
    return if (r) |_| "ok" else |e| @errorName(e);
}

/// Every `.va` and `.vams` path under `root` whose text has a `//! reject`
/// or `//! warn` line, relative and sorted.
fn collect(arena: Allocator, io: std.Io, root: []const u8) ![]const []const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var list: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.path);
        if (!std.mem.eql(u8, ext, ".va") and !std.mem.eql(u8, ext, ".vams")) continue;
        const path = try std.fs.path.join(arena, &.{ root, entry.path });
        const text = try frontend.preprocessor.readText(io, .cwd(), path, arena);
        if (std.mem.find(u8, text, "\n//! reject") == null and std.mem.find(u8, text, "\n//! warn") == null) continue;
        try list.append(arena, try arena.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return list.items;
}

/// `diag.xfail`: one `<path> <reason>` per line; `#` lines and blank lines
/// are comments. A line without a reason is refused.
fn readXfail(arena: Allocator, io: std.Io, path: []const u8) !std.StringHashMapUnmanaged([]const u8) {
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    const text = try frontend.preprocessor.readText(io, .cwd(), path, arena);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.findAny(u8, line, " \t") orelse {
            std.debug.print("diff-diag: diag.xfail line `{s}` has no reason\n", .{line});
            return error.XfailWithoutReason;
        };
        try map.put(arena, line[0..sp], std.mem.trim(u8, line[sp..], " \t"));
    }
    return map;
}

/// An old span, resolved as the old renderer resolves it, as a file
/// location: the start through the segment map and the strip marks, the
/// end at the start plus the length, mapped the same way.
fn copyLoc(bag: *const diag.Bag, span: diag.Span, file: diag.FileId) Diag.Loc {
    const r = bag.locate(span, file);
    const start = bag.toSourceOffset(r.file, r.offset);
    const end = @max(start, bag.toSourceOffset(r.file, r.offset +| span.len()));
    return .{ .file = @fromBackingInt(@backingInt(r.file)), .start = start, .end = end };
}

/// Runs the old `analyze` on fixture `rel`, copies its rows into a `Wip`,
/// and returns null when every rendering agrees, else what differs first.
fn compareFixture(a: Allocator, io: std.Io, root: []const u8, rel: []const u8, tally: *Tally) !FixtureVerdict {
    const gpa = std.heap.smp_allocator;
    const path = try std.fs.path.join(a, &.{ root, rel });
    const text = try frontend.preprocessor.readText(io, .cwd(), path, a);
    const dir = std.fs.path.dirname(path).?;
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    if (vera.analyze(gpa, text, .{
        .file_name = rel,
        .include_dirs = &.{ dir, try std.fs.path.join(a, &.{ root, "include" }) },
        .require_std_includes = true,
    }, &bag)) |res| {
        var r = res;
        r.deinit(gpa);
    } else |e| switch (e) {
        error.OutOfMemory => return e,
        error.CompileFailed, error.NoModule, error.NothingToElaborate => {},
    }
    if (bag.isEmpty()) return .{ .why = null };
    bag.sort();

    var wip: Diag.Wip = .init(a);
    for (0..bag.count()) |k| {
        const e = bag.at(k);
        const loc: Diag.Loc = if (e.span.isNone()) .none else copyLoc(&bag, e.span, e.file);
        var b = wip.build(std.meta.stringToEnum(Diag.Stage, @tagName(e.stage)).?, @fromBackingInt(@backingInt(e.code)), loc);
        b.msg("{s}", .{e.message});
        if (e.point.len != 0) b.point("{s}", .{e.point});
        var label_buf: [diag.max_children]diag.Label = undefined;
        for (bag.labels(e, &label_buf)) |l| b.label(if (l.span.isNone()) .none else copyLoc(&bag, l.span, e.file), "{s}", .{l.text});
        var note_buf: [diag.max_children]diag.Note = undefined;
        for (bag.notes(e, &note_buf)) |n| switch (n.kind) {
            .note => b.note("{s}", .{n.text}),
            .help => if (n.fix) |f|
                b.suggest(.{ .loc = copyLoc(&bag, f.span, e.file), .replacement = f.replacement }, "{s}", .{n.text})
            else
                b.help("{s}", .{n.text}),
        };
        try b.emit();
    }
    const d = try wip.toOwnedBundle();
    const sources = try a.alloc(Diag.Source, bag.files.items.len);
    for (sources, 0..) |*s, k| {
        const id: diag.FileId = @fromBackingInt(@intCast(k));
        const t = bag.sourceText(id);
        s.* = .{ .name = bag.fileName(id), .text = t, .line_starts = try Diag.lineStarts(a, t) };
    }
    const why = try compareRendered(a, &bag, d, sources, .{ .fixture = sources }, .{}, tally) orelse return .{ .why = null };
    return .{ .why = why, .rows = try rowsText(a, d, sources), .cited = try settle.clauses(a, text) };
}

/// The bundle's rows in order, `CODE@line:col` (1-based, in the original
/// text of the row's file), space-separated: what a ruling expects.
fn rowsText(a: Allocator, d: Diag, sources: []const Diag.Source) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    for (d.messages(), 0..) |i, k| {
        const m = d.message(i);
        if (k != 0) try out.writer.writeByte(' ');
        try out.writer.print("{t}", .{m.tag.code});
        if (m.loc.isNone()) continue;
        const starts = sources[@backingInt(m.loc.file)].line_starts;
        var line: usize = 0;
        while (line + 1 < starts.len and starts[line + 1] <= m.loc.start) line += 1;
        try out.writer.print("@{d}:{d}", .{ line + 1, m.loc.start - starts[line] + 1 });
    }
    return out.written();
}

/// The first differing byte and the text around it on each side.
fn textDiff(a: Allocator, what: []const u8, old: []const u8, new: []const u8) ![]const u8 {
    const at = std.mem.indexOfDiff(u8, old, new).?;
    const from = at -| 60;
    return a.print("{s} differs at byte {d} (old {d} bytes, new {d}):\n  old \"{f}\"\n  new \"{f}\"", .{
        what,                                                 at,                                                   old.len, new.len,
        std.zig.fmtString(old[from..@min(at + 40, old.len)]), std.zig.fmtString(new[from..@min(at + 40, new.len)]),
    });
}

test "diff-diag: the catalogue is lib/diag's, row for row, and --explain writes the same bytes" {
    const old_names = @typeInfo(diag.Code).@"enum".field_names;
    const new_names = @typeInfo(Diag.Code).@"enum".field_names;
    var bad: usize = 0;
    var explained: usize = 0;
    for (std.enums.values(diag.Code)) |c| {
        const name = @tagName(c);
        const n = std.meta.stringToEnum(Diag.Code, name) orelse {
            std.debug.print("diff-diag: {s} is missing from codes.zon\n", .{name});
            bad += 1;
            continue;
        };
        const o = diag.info(c);
        const i = Diag.info(n);
        if (@backingInt(n) != @backingInt(c)) {
            std.debug.print("diff-diag: {s} is tag {d}, was {d}\n", .{ name, @backingInt(n), @backingInt(c) });
            bad += 1;
        }
        inline for (.{ "title", "lrm", "explain" }) |f| if (!std.mem.eql(u8, @field(o, f), @field(i, f))) {
            std.debug.print("diff-diag: {s}.{s} differs\n", .{ name, f });
            bad += 1;
        };
        for ([_]bool{ false, true }) |colour| {
            var ob: [16384]u8 = undefined;
            var nb: [16384]u8 = undefined;
            var ow: std.Io.Writer = .fixed(&ob);
            var nw: std.Io.Writer = .fixed(&nb);
            try diag.explain(c, &ow, if (colour) .on else .off);
            try Diag.explain(n, &nw, if (colour) .on else .off);
            if (!std.mem.eql(u8, ow.buffered(), nw.buffered())) {
                std.debug.print("diff-diag: --explain {s} differs{s}\n", .{ name, if (colour) " (colour)" else "" });
                bad += 1;
            } else explained += 1;
        }
    }
    std.debug.print("diff-diag: catalogue: {d} codes compared ({d} new), {d} --explain texts agree, {d} differ\n", .{ old_names.len, new_names.len, explained, bad });
    try std.testing.expectEqual(old_names.len, new_names.len);
    try std.testing.expectEqual(@as(usize, 0), bad);
}

test "diff-diag: seeded scripts render the same both ways" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var prng: Random.DefaultPrng = .init(0x7e5a_d1a9);
    const r = prng.random();
    var tally: Tally = .{};
    var bad: usize = 0;
    for (0..2000) |k| {
        _ = arena_state.reset(.retain_capacity);
        // Mostly short bundles; every tenth runs past the cap.
        const n = if (k % 10 == 0) r.intRangeAtMost(usize, 60, 90) else r.uintLessThan(usize, 12);
        if (try scriptBundle(arena_state.allocator(), r, n, &tally)) |why| {
            bad += 1;
            if (bad <= 5) std.debug.print("diff-diag: MISMATCH script bundle {d}: {s}\n", .{ k, why });
        }
    }
    std.debug.print("diff-diag: scripts: {d} bundles agree ({d} rows, {d} level sets, {d} text bytes, {d} JSON lines byte-equal, {d} by relation), {d} differ\n", .{
        tally.bundles, tally.rows, tally.level_sets, tally.text_bytes, tally.json_exact, tally.json_relation, bad,
    });
    try std.testing.expectEqual(@as(usize, 0), bad);
}

test "diff-diag: the old compiler's diagnostics on the reject and warn fixtures render the same" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var run_arena: std.heap.ArenaAllocator = .init(gpa);
    defer run_arena.deinit();
    const ra = run_arena.allocator();
    const root = repo_env.fixtureRoot();
    const fixtures = try collect(ra, io, root);
    const xfail = try readXfail(ra, io, try std.fs.path.join(ra, &.{ repo_env.repoRoot(), "tests/differential/diag.xfail" }));
    var rulings = try settle.Rulings.read(ra, io, repo_env.repoRoot(), "diag");

    var fixture_arena: std.heap.ArenaAllocator = .init(gpa);
    defer fixture_arena.deinit();
    var tally: Tally = .{};
    var agreed: usize = 0;
    var ruled: usize = 0;
    var listed: usize = 0;
    var bad: usize = 0;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (fixtures) |rel| {
        _ = fixture_arena.reset(.retain_capacity);
        try seen.put(ra, rel, {});
        const v = try compareFixture(fixture_arena.allocator(), io, root, rel, &tally);
        const reason = xfail.get(rel);
        if (v.why) |w| {
            if (reason != null) {
                listed += 1;
                continue;
            }
            if (rulings.get(rel) != null) {
                const no = try rulings.settle(fixture_arena.allocator(), rel, v.cited, v.rows) orelse {
                    ruled += 1;
                    continue;
                };
                bad += 1;
                std.debug.print("diff-diag: MISMATCH {s}: {s}; {s}\n", .{ rel, w, no });
                continue;
            }
            bad += 1;
            std.debug.print("diff-diag: MISMATCH {s}: {s}\n  new rows: {s}\n", .{ rel, w, v.rows });
        } else if (reason) |rsn| {
            bad += 1;
            std.debug.print("diff-diag: XPASS {s} agrees; remove its diag.xfail line ({s})\n", .{ rel, rsn });
        } else agreed += 1;
    }
    var it = xfail.keyIterator();
    while (it.next()) |k| if (!seen.contains(k.*)) {
        bad += 1;
        std.debug.print("diff-diag: STALE {s} is in diag.xfail but not in the corpus\n", .{k.*});
    };
    var ruling_text: std.Io.Writer.Allocating = .init(ra);
    bad += try rulings.finish(&ruling_text.writer);
    std.debug.print("{s}", .{ruling_text.written()});
    std.debug.print("diff-diag: fixtures: {d} compared, {d} agreed ({d} by a ruling; {d} with diagnostics: {d} rows, {d} text bytes, {d} JSON lines byte-equal, {d} by relation), {d} listed in diag.xfail, {d} failed\n", .{
        fixtures.len, agreed + ruled, ruled, tally.bundles, tally.rows, tally.text_bytes, tally.json_exact, tally.json_relation, listed, bad,
    });
    try std.testing.expect(fixtures.len > 900);
    try std.testing.expect(tally.rows > 1000);
    try std.testing.expectEqual(@as(usize, 0), bad);
}

test "diff-diag: every code at every level, with a message, a label, a note and a fix-it, renders the same" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const codes = std.enums.values(Diag.Code);
    var tally: Tally = .{};
    var bad: usize = 0;
    for (std.enums.values(Diag.Level)) |level| {
        // Bundles of 48 codes, under the cap, each code at `level`.
        var first: usize = 0;
        while (first < codes.len) : (first += 48) {
            _ = arena_state.reset(.retain_capacity);
            const a = arena_state.allocator();
            const chunk = codes[first..@min(first + 48, codes.len)];
            const sets = try a.alloc(LevelSet, chunk.len);
            const reports = try a.alloc(Report, chunk.len);
            for (chunk, sets, reports, 0..) |c, *l, *rep, k| {
                l.* = .{ .code = @backingInt(c), .level = level };
                const start: u32 = @intCast(1 + (k * 7) % (text_a.len - 8));
                const b_at: u32 = @intCast(k % text_b.len);
                const parts = try a.dupe(Part, &.{
                    .{ .kind = .label, .where = .{ .file = 1, .start = b_at, .end = b_at + 3 }, .text = "the label" },
                    .{ .kind = .note, .where = .{ .file = 0, .start = 1, .end = 1 }, .text = "the note" },
                    .{ .kind = .fix, .where = .{ .file = 0, .start = start, .end = start + 2 }, .text = "fixed" },
                });
                rep.* = .{
                    .stage = @intCast(k % 6),
                    .code = @backingInt(c),
                    .where = .{ .file = 0, .start = start, .end = start + 3 },
                    .msg = "the message",
                    .point = "here",
                    .parts = parts,
                };
            }
            if (try compareScript(a, reports, sets, .{}, &tally)) |why| {
                bad += 1;
                std.debug.print("diff-diag: MISMATCH {t} bundle at {t}: {s}\n", .{ level, chunk[0], why });
            }
        }
    }
    std.debug.print("diff-diag: levels: {d} bundles agree ({d} rows, {d} level sets), {d} differ\n", .{ tally.bundles, tally.rows, tally.level_sets, bad });
    try std.testing.expect(tally.rows > 1000);
    try std.testing.expectEqual(@as(usize, 0), bad);
}

test "diff-diag: parseFlag reads the same directives, refuses the same ones, and leaves the same levels" {
    @setEvalBranchQuota(10_000);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var words: std.ArrayList([]const u8) = .empty;
    for (std.enums.values(Diag.Code)) |c| for ([_][]const u8{ "allow", "warn", "deny", "forbid" }) |w| {
        try words.append(a, try a.print("{s}={t}", .{ w, c }));
    };
    try words.appendSlice(a, &.{ "", "allow", "allow=", "=W0650", "Allow=W0650", "allow=w0650", "allow=W9999", "allow=W0650=x", "allow= W0650", "deny=W0650 " });
    // Every directive once, in a seeded order, so a `forbid` meets later
    // directives for the same code.
    var prng: Random.DefaultPrng = .init(0x1e7e15);
    prng.random().shuffle([]const u8, words.items);
    var old: diag.Levels = .empty;
    var new: Diag.Levels = .empty;
    var bad: usize = 0;
    for (words.items) |w| {
        const os = if (old.parseFlag(w)) |v| (if (v) "true" else "false") else |e| @errorName(e);
        const ns = if (new.parseFlag(w)) |v| (if (v) "true" else "false") else |e| @errorName(e);
        if (!std.mem.eql(u8, os, ns)) {
            bad += 1;
            if (bad <= 5) std.debug.print("diff-diag: parseFlag(\"{s}\") is {s} old, {s} new\n", .{ w, os, ns });
        }
    }
    for (std.enums.values(diag.Code)) |c| {
        if (!std.mem.eql(u8, @tagName(old.get(c)), @tagName(new.get(@fromBackingInt(@backingInt(c)))))) bad += 1;
    }
    std.debug.print("diff-diag: parseFlag: {d} directives compared, result and final levels; {d} differ\n", .{ words.items.len, bad });
    try std.testing.expectEqual(@as(usize, 0), bad);
}

test "diff-diag: editDistance and didYouMean agree over the catalogue's title words" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (std.enums.values(Diag.Code)) |c| {
        var it = std.mem.tokenizeAny(u8, Diag.info(c).title, " `'(),:;$");
        while (it.next()) |w| try seen.put(a, w, {});
    }
    const words = seen.keys();
    var pairs: usize = 0;
    var bad: usize = 0;
    for (words) |x| {
        for (words) |y| for ([_]usize{ 1, 2, 4, 64 }) |limit| {
            pairs += 1;
            if (diag.editDistance(x, y, limit) != Diag.editDistance(x, y, limit)) bad += 1;
        };
        const o = diag.didYouMean(x, words);
        const n = Diag.didYouMean(x, words);
        if ((o == null) != (n == null) or (o != null and !std.mem.eql(u8, o.?, n.?))) bad += 1;
    }
    std.debug.print("diff-diag: suggestions: {d} words, {d} distance pairs, {d} differ\n", .{ words.len, pairs, bad });
    try std.testing.expectEqual(@as(usize, 0), bad);
}
