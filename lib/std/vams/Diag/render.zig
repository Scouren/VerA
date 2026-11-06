//! Rendering: a bundle and the caller's `Source` table in, terminal text
//! with source snippets (rustc's layout) or JSON Lines out; a code in, its
//! `--explain` entry out. Allocates nothing: the line starts come with the
//! sources.
//!
//! Cites no LRM clause: the output format is VerA's own. Goldens and the
//! fixture suites compare this text byte for byte.
//!
//! Contents:
//! - `pub const Source = struct { name, text, line_starts }`
//! - `pub fn lineStarts(gpa: Allocator, text: []const u8) Allocator.Error![]u32`
//! - `pub const Palette = struct`, `off`, `on`
//! - `pub const RenderOptions = struct { palette, explain_hint, summary }`
//! - `pub fn render(d: Diag, sources: []const Source, w: *Writer, opts: RenderOptions) Writer.Error!void`
//! - `pub fn renderJson(d: Diag, sources: []const Source, w: *Writer) Writer.Error!void`
//! - `pub fn explain(c: Code, w: *Writer, palette: Palette) Writer.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Diag = @import("../Diag.zig");
const Code = Diag.Code;
const File = Diag.File;
const Loc = Diag.Loc;
const Severity = Diag.Severity;

/// One file as the renderer reads it, indexed by `Diag.File`. Borrowed for
/// the call. A `File` past the table, or a source whose text is empty,
/// renders as `<source>` with no snippet.
pub const Source = struct {
    /// What `-->` and the JSON `file` print.
    name: []const u8,
    /// The original text: what `Loc`s index and snippets are cut from.
    text: []const u8,
    /// Offset of each line's first byte (`lineStarts(text)`): starts with
    /// 0, strictly increasing.
    line_starts: []const u32,
};

/// SGR escapes, or all empty when colour is off, so coloured and plain
/// output share one code path and cannot drift apart.
pub const Palette = struct {
    reset: []const u8 = "",
    bold: []const u8 = "",
    err: []const u8 = "",
    warn: []const u8 = "",
    gutter: []const u8 = "",
    note: []const u8 = "",
    help: []const u8 = "",
    good: []const u8 = "",

    /// Plain text, the default: what goldens and the test suites compare.
    pub const off: Palette = .{};

    /// ANSI SGR colours, rustc's scheme.
    pub const on: Palette = .{
        .reset = "\x1b[0m",
        .bold = "\x1b[1m",
        .err = "\x1b[1;31m", // Bold red.
        .warn = "\x1b[1;33m", // Bold yellow.
        .gutter = "\x1b[1;34m", // Bold blue.
        .note = "\x1b[1;36m", // Bold cyan.
        .help = "\x1b[1;36m",
        .good = "\x1b[1;32m", // Bold green: suggested insertions.
    };

    fn forSeverity(self: Palette, s: Severity) []const u8 {
        return switch (s) {
            .err => self.err,
            .warning => self.warn,
        };
    }
};

/// What `render` draws besides each diagnostic's headline and location.
pub const RenderOptions = struct {
    palette: Palette = .off,
    /// Print `= help: run vera --explain EXXXX` after the first diagnostic
    /// carrying each code.
    explain_hint: bool = true,
    /// Print the `N error(s), M warning(s)` trailer.
    summary: bool = true,
};

/// Tabs are expanded to this many spaces before a snippet is drawn, so a
/// caret lands under the character it means (as rustc does).
const tab_width = 4;

/// The widest gutter: the digits of the largest `u32` line number.
const spaces_pad: [10]u8 = @splat(' ');

/// A source with no text: what an unknown `File` resolves to.
const unknown: Source = .{ .name = "<source>", .text = "", .line_starts = &.{0} };

/// One location, resolved all the way to something printable.
const Placed = struct {
    file: File,
    /// 1-based line.
    line: u32,
    /// 0-based display column.
    col: u32,
    /// Display width of the underline, at least 1.
    width: u32,
    text: []const u8,
    primary: bool,
};

/// The state one `render` call shares between its steps.
const Pass = struct {
    d: Diag,
    sources: []const Source,
    w: *Writer,
    p: Palette,

    fn source(pass: Pass, file: File) Source {
        const i = @backingInt(file);
        return if (i < pass.sources.len) pass.sources[i] else unknown;
    }
};

/// Returns the offset of each line's first byte of `text`, one exact
/// allocation the caller frees with `gpa`. O(text.len).
/// Asserts that `text` is shorter than 4 GiB.
pub fn lineStarts(gpa: Allocator, text: []const u8) Allocator.Error![]u32 {
    assert(text.len < std.math.maxInt(u32));
    const starts = try gpa.alloc(u32, std.mem.countScalar(u8, text, '\n') + 1);
    starts[0] = 0;
    var n: usize = 1;
    for (text, 0..) |c, i| if (c == '\n') {
        starts[n] = @intCast(i + 1);
        n += 1;
    };
    assert(n == starts.len);
    return starts;
}

/// Renders `d` to `w`: one block per kept diagnostic, in the bundle's
/// order, then the cap trailer and the summary. A location is drawn on its
/// first line only, clamped to that line; a label in another file than the
/// primary's gets its own `::: file:line:col` header.
pub fn render(d: Diag, sources: []const Source, w: *Writer, opts: RenderOptions) Writer.Error!void {
    const h = d.header();
    if (h.len == 0 and h.suppressed == 0) return;
    assert(h.run_err_count <= h.err_count);
    const pass: Pass = .{ .d = d, .sources = sources, .w = w, .p = opts.palette };

    var explained: std.EnumSet(Code) = .empty;
    for (d.messages()) |i| {
        const m = d.message(i);
        const gutter = try renderOne(pass, i);
        if (opts.explain_hint and !explained.contains(m.tag.code)) {
            explained.insert(m.tag.code);
            try w.print("{s}{s} ={s} {s}help{s}: run `vera --explain {s}` for a detailed explanation\n", .{
                spaces(gutter), pass.p.gutter, pass.p.reset, pass.p.help, pass.p.reset, @tagName(m.tag.code),
            });
        }
        try w.writeByte('\n');
    }
    try renderTrailer(pass, opts.summary);
}

/// Writes one JSON object per kept diagnostic, one per line, shaped like
/// rustc's `--message-format json`. A location is `null` when absent, else
/// its file name, 1-based `line` and byte `col`, and its `byte_start` and
/// `byte_end` in the file. The suppressed and deduped counts are not
/// reported.
pub fn renderJson(d: Diag, sources: []const Source, w: *Writer) Writer.Error!void {
    const pass: Pass = .{ .d = d, .sources = sources, .w = w, .p = .off };
    for (d.messages()) |i| {
        const m = d.message(i);
        const meta = Diag.info(m.tag.code);
        try w.writeAll("{\"code\":\"");
        try w.writeAll(@tagName(m.tag.code));
        try w.print("\",\"level\":\"{s}\",\"stage\":\"{s}\",\"lrm\":", .{ m.tag.severity.word(), @tagName(m.tag.stage) });
        try writeString(w, meta.lrm);
        try w.writeAll(",\"title\":");
        try writeString(w, meta.title);
        try w.writeAll(",\"message\":");
        try writeString(w, d.string(m.msg));
        try w.writeAll(",\"span\":");
        try jsonLoc(pass, m.loc);

        try w.writeAll(",\"labels\":[");
        for (d.labels(i), 0..) |l, k| {
            if (k != 0) try w.writeByte(',');
            try w.writeAll("{\"text\":");
            try writeString(w, d.string(l.text));
            try w.writeAll(",\"span\":");
            try jsonLoc(pass, l.loc);
            try w.writeByte('}');
        }

        try w.writeAll("],\"notes\":[");
        for (d.notes(i), 0..) |n, k| {
            if (k != 0) try w.writeByte(',');
            try w.print("{{\"kind\":\"{s}\",\"text\":", .{@tagName(n.kind)});
            try writeString(w, d.string(n.text));
            if (n.replacement != .none) {
                try w.writeAll(",\"fix\":{\"replacement\":");
                try writeString(w, d.string(n.replacement));
                try w.writeAll(",\"span\":");
                try jsonLoc(pass, n.fix);
                try w.writeByte('}');
            }
            try w.writeByte('}');
        }
        try w.writeAll("]}\n");
    }
}

/// Writes the `--explain` entry of `c`: code, title, LRM citation, and
/// `Info.explain` verbatim.
pub fn explain(c: Code, w: *Writer, palette: Palette) Writer.Error!void {
    const meta = Diag.info(c);
    assert(meta.title.len > 0);
    assert(meta.explain.len > 0);
    try w.print("{s}{s}{s}: {s}{s}{s}\n", .{
        palette.bold, @tagName(c), palette.reset, palette.bold, meta.title, palette.reset,
    });
    if (meta.lrm.len != 0) {
        try w.print("{s}LRM {s}{s}{s}\n", .{ palette.note, meta.annexPrefix(), meta.lrm, palette.reset });
    }
    try w.print("\n{s}\n", .{meta.explain});
}

// ---- private ----

/// Writes the headline, location, snippet, citation and notes of one
/// diagnostic, and returns the gutter width it drew them with; the
/// `--explain` hint and the blank line after it are the caller's.
fn renderOne(pass: Pass, i: Diag.MessageIndex) Writer.Error!u32 {
    const p = pass.p;
    const w = pass.w;
    const d = pass.d;
    const m = d.message(i);
    const meta = Diag.info(m.tag.code);
    const severity = m.tag.severity;

    // `error[E0313]: unknown variable: <message>`
    try w.print("{s}{s}[{s}]{s}{s}: {s}{s}", .{
        p.forSeverity(severity), severity.word(), @tagName(m.tag.code), p.reset,
        p.bold,                  meta.title,      p.reset,
    });
    const headline = d.string(m.msg);
    if (headline.len != 0) try w.print(": {s}", .{headline});
    try w.writeByte('\n');

    // `  --> file.va:12:5`, then the snippet, gutter as wide as its widest line.
    var gutter: u32 = 1;
    if (place(pass, m.loc, d.string(m.point), true)) |primary| {
        gutter = digits(primary.line);
        try w.print("{s}{s}-->{s} {s}:{d}:{d}\n", .{
            spaces(gutter), p.gutter, p.reset, pass.source(primary.file).name, primary.line, primary.col + 1,
        });
        // SAFETY: the first `n` are written before `placed` is sliced.
        var placed_buf: [@as(u32, Diag.max_children) + 1]Placed = undefined;
        placed_buf[0] = primary;
        var n: usize = 1;
        for (d.labels(i)) |l| {
            placed_buf[n] = place(pass, l.loc, d.string(l.text), false) orelse continue;
            n += 1;
        }
        const placed = placed_buf[0..n];
        for (placed) |q| gutter = @max(gutter, digits(q.line));
        try renderSnippet(pass, placed, severity, gutter);
    }

    // The rule this diagnostic enforces.
    if (meta.lrm.len != 0) {
        try w.print("{s}{s} ={s} {s}note{s}: LRM {s}{s}\n", .{
            spaces(gutter),     p.gutter, p.reset, p.note, p.reset,
            meta.annexPrefix(), meta.lrm,
        });
    }

    for (d.notes(i)) |n| {
        const colour = switch (n.kind) {
            .note => p.note,
            .help => p.help,
        };
        try w.print("{s}{s} ={s} {s}{s}{s}: {s}\n", .{
            spaces(gutter), p.gutter, p.reset, colour, @tagName(n.kind), p.reset, d.string(n.text),
        });
        if (n.replacement != .none) try renderFix(pass, n.fix, d.string(n.replacement), gutter);
    }
    assert(gutter >= 1);
    return gutter;
}

/// Resolves `loc` to a line and display columns, or null when there is no
/// location or no text to show it in.
fn place(pass: Pass, loc: Loc, text: []const u8, primary: bool) ?Placed {
    if (loc.isNone()) return null;
    const src = pass.source(loc.file);
    if (src.text.len == 0) return null;
    const start = loc.start;
    const end = @max(start, loc.end);
    const lc = lineCol(src.line_starts, start);
    const line_text = lineText(src, lc.line);
    const start_col = displayCol(line_text, lc.col - 1);

    // A range past its line's end is clamped: an underline may not wrap,
    // and the first line is the informative one. One that STARTS past its
    // line's text (the '\n' of a "\r\n", or past the end of the file) holds
    // its end at the start, so the caret sits just after the line.
    const line_end = (start - (lc.col - 1)) + @as(u32, @intCast(line_text.len));
    const clamped = @max(start, @min(end, line_end));
    const end_col = displayCol(line_text, clamped - start + (lc.col - 1));
    return .{
        .file = loc.file,
        .line = lc.line,
        .col = start_col,
        .width = @max(1, end_col -| start_col),
        .text = text,
        .primary = primary,
    };
}

/// The ` 12 | source text` / `    | ^^^ label` block. Placed locations are
/// grouped by line; a gap between printed lines becomes `...`, like rustc.
fn renderSnippet(pass: Pass, placed: []Placed, severity: Severity, gutter: u32) Writer.Error!void {
    assert(placed.len > 0);
    assert(placed[0].primary);
    const p = pass.p;
    const w = pass.w;
    // The primary's file first, under the `-->` line; any other after, in
    // id order. Within a file: line, then column. Stable, so locations at
    // one position keep the primary-then-labels order.
    const home = placed[0].file;
    std.mem.sort(Placed, placed, home, snippetOrder);

    try w.print("{s}{s} |{s}\n", .{ spaces(gutter), p.gutter, p.reset });
    var i: usize = 0;
    var prev_line: u32 = 0;
    var prev_file = home;
    while (i < placed.len) {
        const line = placed[i].line;
        const file = placed[i].file;
        var j = i + 1;
        while (j < placed.len and placed[j].line == line and placed[j].file == file) j += 1;

        if (file != prev_file) {
            // A label in another file: rustc's `:::` header, aligned with the
            // `-->` line, so its line is never read as the primary file's.
            try w.print("{s}{s} |{s}\n", .{ spaces(gutter), p.gutter, p.reset });
            try w.print("{s}{s}:::{s} {s}:{d}:{d}\n", .{
                spaces(gutter), p.gutter, p.reset, pass.source(file).name, line, placed[i].col + 1,
            });
            try w.print("{s}{s} |{s}\n", .{ spaces(gutter), p.gutter, p.reset });
            prev_file = file;
            prev_line = 0;
        }
        if (prev_line != 0 and line > prev_line + 1) try w.print("{s}...{s}\n", .{ p.gutter, p.reset });
        prev_line = line;

        try w.print("{s}{d}{s} |{s} ", .{ p.gutter, line, spaces(gutter -| digits(line)), p.reset });
        try writeExpanded(w, lineText(pass.source(file), line));
        try w.writeByte('\n');

        // One underline row per location on this line, deepest column
        // last, so the labels stack instead of overlapping.
        for (placed[i..j]) |q| {
            try w.print("{s}{s} |{s} ", .{ spaces(gutter), p.gutter, p.reset });
            try w.splatByteAll(' ', q.col);
            try w.print("{s}", .{if (q.primary) p.forSeverity(severity) else p.gutter});
            try w.splatByteAll(if (q.primary) '^' else '-', q.width);
            if (q.text.len != 0) try w.print(" {s}", .{q.text});
            try w.print("{s}\n", .{p.reset});
        }
        assert(j > i);
        i = j;
    }
    try w.print("{s}{s} |{s}\n", .{ spaces(gutter), p.gutter, p.reset });
}

fn snippetOrder(home: File, a: Placed, b: Placed) bool {
    if (a.file != b.file) {
        if ((a.file == home) != (b.file == home)) return a.file == home;
        return @backingInt(a.file) < @backingInt(b.file);
    }
    if (a.line != b.line) return a.line < b.line;
    return a.col < b.col;
}

/// Shows a machine-applicable rewrite as the patched line, with `+` under
/// an insertion and `~` under a replacement. A fix with no location, or in
/// a file with no text, draws nothing.
fn renderFix(pass: Pass, fix: Loc, replacement: []const u8, gutter: u32) Writer.Error!void {
    const p = pass.p;
    const w = pass.w;
    if (fix.isNone()) return;
    const src = pass.source(fix.file);
    if (src.text.len == 0) return;
    const start = fix.start;
    const end = @max(start, fix.end);
    const lc = lineCol(src.line_starts, start);
    assert(lc.col >= 1);
    const line = lineText(src, lc.line);
    const cut = @min(lc.col - 1, line.len);
    const cut_end = @min(cut + (end - start), line.len);
    assert(cut <= cut_end);

    try w.print("{s}{s} |{s}\n", .{ spaces(gutter), p.gutter, p.reset });
    try w.print("{s}{d}{s} |{s} ", .{ p.gutter, lc.line, spaces(gutter -| digits(lc.line)), p.reset });
    try writeExpanded(w, line[0..cut]);
    // Expanded like the line around it, so the ruler below counts it in
    // the display columns a caret uses.
    try w.print("{s}", .{p.good});
    try writeExpanded(w, replacement);
    try w.print("{s}", .{p.reset});
    try writeExpanded(w, line[cut_end..]);
    try w.writeByte('\n');

    try w.print("{s}{s} |{s} ", .{ spaces(gutter), p.gutter, p.reset });
    try w.splatByteAll(' ', displayCol(line, @intCast(cut)));
    try w.print("{s}", .{p.good});
    try w.splatByteAll(
        if (fix.end -| fix.start == 0) '+' else '~',
        @max(1, displayCol(replacement, @intCast(replacement.len))),
    );
    try w.print("{s}\n", .{p.reset});
}

/// The cap trailer, then the summary; a `.run` error was raised after the
/// design compiled, so it is its own report and no compile failure (#72).
fn renderTrailer(pass: Pass, summary: bool) Writer.Error!void {
    const h = pass.d.header();
    const p = pass.p;
    const w = pass.w;
    if (h.suppressed != 0) {
        try w.print("{s}{s}:{s} {d} further diagnostic(s) not shown (limit {d})\n", .{
            p.warn, "warning", p.reset, h.suppressed, Diag.max_entries,
        });
    }
    assert(h.run_err_count <= h.err_count);
    const compile_errs = h.err_count - h.run_err_count;
    if (!summary or (compile_errs == 0 and h.warn_count == 0)) return;
    if (compile_errs != 0) {
        try w.print("{s}error{s}: could not compile due to {d} previous error(s)", .{ p.err, p.reset, compile_errs });
        if (h.warn_count != 0) try w.print("; {d} warning(s) emitted", .{h.warn_count});
        try w.writeByte('\n');
    } else {
        try w.print("{s}warning{s}: {d} warning(s) emitted\n", .{ p.warn, p.reset, h.warn_count });
    }
}

fn jsonLoc(pass: Pass, loc: Loc) Writer.Error!void {
    const w = pass.w;
    if (loc.isNone()) return w.writeAll("null");
    const src = pass.source(loc.file);
    const lc = lineCol(src.line_starts, loc.start);
    assert(lc.line >= 1);
    try w.writeAll("{\"file\":");
    try writeString(w, src.name);
    try w.print(",\"line\":{d},\"col\":{d},\"byte_start\":{d},\"byte_end\":{d}}}", .{
        lc.line, lc.col, loc.start, loc.end,
    });
}

/// The 1-based line and byte column of `off`. An `off` past the text lands
/// on the last line, with a column past its end. O(log lines).
fn lineCol(starts: []const u32, off: u32) struct { line: u32, col: u32 } {
    assert(starts.len > 0);
    assert(starts[0] == 0);
    const lo = std.sort.partitionPoint(u32, starts, off, lineAtOrBefore) - 1;
    return .{ .line = @intCast(lo + 1), .col = off - starts[lo] + 1 };
}

fn lineAtOrBefore(off: u32, start: u32) bool {
    return start <= off;
}

/// The text of `line` (1-based) without its `\n` or `\r\n`; empty for a
/// line past the end.
fn lineText(src: Source, line: u32) []const u8 {
    const starts = src.line_starts;
    if (line == 0 or line > starts.len) return "";
    const start = starts[line - 1];
    const end: u32 = if (line < starts.len) starts[line] else @intCast(src.text.len);
    assert(start <= end);
    var slice = src.text[@min(start, src.text.len)..@min(end, src.text.len)];
    if (std.mem.endsWith(u8, slice, "\n")) slice = slice[0 .. slice.len - 1];
    if (std.mem.endsWith(u8, slice, "\r")) slice = slice[0 .. slice.len - 1];
    assert(std.mem.findScalar(u8, slice, '\n') == null);
    return slice;
}

/// The display column of byte `byte_col` of `line`: a tab is `tab_width`
/// columns and a UTF-8 continuation byte none. Codepoints, not grapheme
/// clusters or wcwidth: the approximation rustc makes.
fn displayCol(line: []const u8, byte_col: u32) u32 {
    const bytes = line[0..@min(byte_col, line.len)];
    var col: u32 = 0;
    for (bytes) |c| {
        if (c & 0xc0 == 0x80) continue;
        col += if (c == '\t') tab_width else 1;
    }
    assert(col <= bytes.len * tab_width);
    return col;
}

fn writeExpanded(w: *Writer, line: []const u8) Writer.Error!void {
    for (line) |c| {
        if (c == '\t') try w.splatByteAll(' ', tab_width) else try w.writeByte(c);
    }
}

fn writeString(w: *Writer, s: []const u8) Writer.Error!void {
    try std.json.Stringify.encodeJsonString(s, .{}, w);
}

fn digits(n: u32) u32 {
    var v = n;
    var d: u32 = 1;
    while (v >= 10) : (v /= 10) d += 1;
    assert(d <= 10);
    return d;
}

fn spaces(n: u32) []const u8 {
    assert(n <= spaces_pad.len);
    return spaces_pad[0..n];
}
