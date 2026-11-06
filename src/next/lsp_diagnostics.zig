//! A compilation's diagnostic bundle (`Compilation.getAllErrors` and its
//! `sources`) -> LSP 3.17 `publishDiagnostics` rows, grouped by the URI
//! each lands on, with each fix-it in the row's `data` for `codeAction`;
//! and the `file://` URI <-> path conversions. The old
//! `src/cli/lsp_diagnostics.zig`'s rows over a `Diag` bundle instead of a
//! `diag.Bag`: every `Loc` is already a byte range of an original file.
//!
//! Cites: none of the LRM's; LSP 3.17 (positions, `publishDiagnostics`),
//! RFC 3986 (URI percent-encoding).
//!
//! Contents:
//! - `pub const Position`, `pub const Range`, `pub const Fix`,
//!   `pub const Related`, `pub const Diagnostic`, `pub const ByUri`,
//!   `pub const Error = Allocator.Error || Io.Writer.Error`
//! - `pub fn diagnostics(arena: Allocator, d: Diag, sources: []const Diag.Source, doc: Diag.File, uri: []const u8, utf16: bool) Error!ByUri`
//! - `pub fn uriToPath(arena: Allocator, uri: []const u8) Allocator.Error!?[]const u8`
//! - `pub fn pathToUri(arena: Allocator, path: []const u8) Error![]const u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Diag = @import("vams").Diag;

/// A 0-based line and character, the character in the negotiated encoding.
pub const Position = struct { line: u32, character: u32 };
/// A half-open span of two positions.
pub const Range = struct { start: Position, end: Position };

/// A fix-it, carried in the diagnostic's `data` so `codeAction` needs no
/// state: the client sends the diagnostic back as it got it.
pub const Fix = struct { title: []const u8, uri: []const u8, range: Range, newText: []const u8 };

/// A label of the diagnostic, placed where it points.
pub const Related = struct {
    location: struct { uri: []const u8, range: Range },
    message: []const u8,
};

/// One `publishDiagnostics` row.
pub const Diagnostic = struct {
    range: Range,
    /// 1 error, 2 warning, 3 information.
    severity: u8,
    code: ?[]const u8 = null,
    source: []const u8 = "vera",
    message: []const u8,
    relatedInformation: []const Related = &.{},
    data: struct { fixes: []const Fix = &.{} } = .{},
};

/// Each URI a lint published on, with its rows; the document's own first.
pub const ByUri = std.StringArrayHashMapUnmanaged(std.ArrayList(Diagnostic));

/// Every way `diagnostics` fails: its arena, or a message it formats.
pub const Error = Allocator.Error || Io.Writer.Error;

const zero: Range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };

/// Where one `Loc` lands: a URI and range, or the document's start with
/// `file:line:col` named when its file is not on disk (the annex D prelude).
const Place = struct { uri: []const u8, range: Range, elsewhere: ?[]const u8 = null };

/// The bundle as LSP diagnostics, grouped by the URI each lands on; `uri`,
/// the document's (file `doc` of `sources`), is always the first key.
pub fn diagnostics(arena: Allocator, d: Diag, sources: []const Diag.Source, doc: Diag.File, uri: []const u8, utf16: bool) Error!ByUri {
    var by_uri: ByUri = .empty;
    try by_uri.put(arena, uri, .empty);
    for (d.messages()) |i| {
        const m = d.message(i);
        const meta = Diag.info(m.tag.code);
        const at = try place(arena, sources, m.loc, doc, uri, utf16);
        var msg: Io.Writer.Allocating = .init(arena);
        const w = &msg.writer;
        if (at.elsewhere) |where| try w.print("{s}: ", .{where});
        try w.writeAll(meta.title);
        if (m.msg != .none) try w.print(": {s}", .{d.string(m.msg)});
        if (meta.lrm.len != 0) try w.print(" (LRM {s}{s})", .{ meta.annexPrefix(), meta.lrm });
        if (m.point != .none) try w.print("\n{s}", .{d.string(m.point)});
        var fixes: std.ArrayList(Fix) = .empty;
        for (d.notes(i)) |n| {
            try w.print("\n{t}: {s}", .{ n.kind, d.string(n.text) });
            if (n.replacement == .none) continue;
            const fp = try place(arena, sources, n.fix, doc, uri, utf16);
            if (fp.elsewhere != null) continue; // nothing on disk to edit
            try fixes.append(arena, .{ .title = d.string(n.text), .uri = fp.uri, .range = fp.range, .newText = d.string(n.replacement) });
        }
        const labels = d.labels(i);
        const related = try arena.alloc(Related, labels.len);
        for (labels, related) |l, *r| {
            const lp = try place(arena, sources, l.loc, doc, uri, utf16);
            r.* = .{ .location = .{ .uri = lp.uri, .range = lp.range }, .message = d.string(l.text) };
        }
        const gop = try by_uri.getOrPut(arena, at.uri);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, .{
            .range = at.range,
            .severity = switch (m.tag.severity) {
                .err => 1,
                .warning => 2,
            },
            .code = @tagName(m.tag.code),
            .message = msg.written(),
            .relatedInformation = related,
            .data = .{ .fixes = fixes.items },
        });
    }
    assert(std.mem.eql(u8, by_uri.keys()[0], uri));
    const suppressed = d.header().suppressed;
    if (suppressed != 0) try by_uri.getPtr(uri).?.append(arena, .{
        .range = zero,
        .severity = 3,
        .message = try arena.print("{d} more diagnostics not shown: a run stops at its cap", .{suppressed}),
    });
    return by_uri;
}

/// `file://` URI -> path, percent-decoded (`file:///C:/x` -> `C:/x`); null
/// for any other scheme (`untitled:`).
pub fn uriToPath(arena: Allocator, uri: []const u8) Allocator.Error!?[]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    const buf = try arena.dupe(u8, uri[prefix.len..]);
    const p = std.Uri.percentDecodeInPlace(buf);
    if (p.len >= 3 and p[0] == '/' and p[2] == ':') return p[1..]; // a Windows drive
    return p;
}

/// Absolute path -> `file://` URI, percent-encoding all but RFC 3986's
/// unreserved bytes and `/`. A Windows path's `\` becomes `/`.
pub fn pathToUri(arena: Allocator, path: []const u8) Error![]const u8 {
    assert(path.len != 0);
    var w: Io.Writer.Allocating = .init(arena);
    try w.writer.writeAll(if (path.len >= 2 and path[1] == ':') "file:///" else "file://");
    for (path) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '/' => try w.writer.writeByte(c),
        '\\' => try w.writer.writeByte('/'),
        else => try w.writer.print("%{X:0>2}", .{c}),
    };
    return w.written();
}

// ---- private ----

fn place(arena: Allocator, sources: []const Diag.Source, loc: Diag.Loc, doc: Diag.File, uri: []const u8, utf16: bool) Error!Place {
    if (loc.isNone() or @backingInt(loc.file) >= sources.len) return .{ .uri = uri, .range = zero };
    const s = sources[@backingInt(loc.file)];
    const start = @min(loc.start, @as(u32, @intCast(s.text.len)));
    const end = @max(start, @min(loc.end, @as(u32, @intCast(s.text.len))));
    const range: Range = .{ .start = position(s, start, utf16), .end = position(s, end, utf16) };
    if (loc.file == doc) return .{ .uri = uri, .range = range };
    if (!std.fs.path.isAbsolute(s.name)) return .{
        .uri = uri,
        .range = zero,
        .elsewhere = try arena.print("{s}:{d}:{d}", .{ s.name, range.start.line + 1, range.start.character + 1 }),
    };
    return .{ .uri = try pathToUri(arena, s.name), .range = range };
}

/// Byte offset `off` of `s` -> 0-based line and character, the character
/// counted in UTF-16 code units when `utf16`, else in bytes. Invalid UTF-8
/// counts a unit per non-continuation byte.
fn position(s: Diag.Source, off: u32, utf16: bool) Position {
    assert(off <= s.text.len);
    assert(s.line_starts.len != 0);
    const line = std.sort.partitionPoint(u32, s.line_starts, off, struct {
        fn atOrBefore(o: u32, x: u32) bool {
            return x <= o;
        }
    }.atOrBefore) - 1;
    const line_start = s.line_starts[line];
    assert(line_start <= off);
    if (!utf16) return .{ .line = @intCast(line), .character = off - line_start };
    var units: u32 = 0;
    for (s.text[line_start..off]) |c| {
        units += @intFromBool(c & 0xc0 != 0x80); // a lead byte starts a code point
        units += @intFromBool(c >= 0xf0); // a 4-byte sequence is a surrogate pair
    }
    return .{ .line = @intCast(line), .character = units };
}

test position {
    // Oracle: the old server's own case. "aé😀b": `b` is byte 7 of its line,
    // UTF-16 unit 4 (é is 1 unit, 😀 a surrogate pair).
    const text = "x\naé😀b\n";
    const starts = try Diag.lineStarts(std.testing.allocator, text);
    defer std.testing.allocator.free(starts);
    const s: Diag.Source = .{ .name = "t", .text = text, .line_starts = starts };
    try std.testing.expectEqual(Position{ .line = 1, .character = 7 }, position(s, 9, false));
    try std.testing.expectEqual(Position{ .line = 1, .character = 4 }, position(s, 9, true));
    try std.testing.expectEqual(Position{ .line = 0, .character = 0 }, position(s, 0, true));
}

test "file URIs round-trip, a drive letter and a space included" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try std.testing.expectEqualStrings("file:///home/x%20y/m.va", try pathToUri(arena, "/home/x y/m.va"));
    try std.testing.expectEqualStrings("/home/x y/m.va", (try uriToPath(arena, "file:///home/x%20y/m.va")).?);
    try std.testing.expectEqualStrings("file:///C%3A/d/m.va", try pathToUri(arena, "C:\\d\\m.va"));
    try std.testing.expectEqualStrings("C:/d/m.va", (try uriToPath(arena, "file:///C%3A/d/m.va")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try uriToPath(arena, "untitled:Untitled-1"));
}
