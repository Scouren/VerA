//! The byte scans: one file's raw bytes in, its comments stripped (`strip`,
//! newlines kept, strip marks out); the stripped text in, its bytes appended
//! to `Pass.out` with every §10 directive and macro use handled in place
//! (Preprocessor/directive.zig) and a dead conditional arm reduced to its
//! newlines (`scan`). Also the byte classes and cursors every preprocessor
//! file shares.
//! Cites: LRM §2.2, §2.4, §2.7, §2.8, §2.8.1, §10; IEEE 1364-2005 §19.3.1,
//! §19.4, §28.4.3.
//!
//! Contents:
//! - `pub const Stripped = struct`
//! - `pub const Rest = struct`, `Rest.peek`, `Rest.skipSpace`, `Rest.escapedIdent`, `Rest.ident`
//! - `pub fn scan(pp: *Pass, text: []const u8) Error!void`
//! - `pub fn stripComments(pp: *Pass, src: []const u8) Error!Stripped`
//! - `pub fn findStop(text: []const u8, from: usize, comptime stops: []const u8) usize`
//! - `pub fn stringStop(text: []const u8, start: usize) usize`
//! - `pub fn isIdentStart(c: u8) bool`
//! - `pub fn isIdentChar(c: u8) bool`
//! - `pub fn isSpace(c: u8) bool`
//! - `pub fn identEnd(s: []const u8, i: usize) usize`
//! - `pub fn escapedEnd(s: []const u8, i: usize) usize`

const std = @import("std");
const assert = std.debug.assert;
const Pass = @import("Pass.zig");
const Error = Pass.Error;
const StripMark = @import("../Preprocessor.zig").StripMark;
const directive = @import("directive.zig");
const protect = @import("protect.zig");

/// `stripComments`' result, both slices on the pass's arena.
pub const Stripped = struct { text: []const u8, marks: []const StripMark };

/// Cursor over the tail of a directive line.
pub const Rest = struct {
    s: []const u8,
    i: usize = 0,

    /// Returns the byte under the cursor, or null at the end of the line.
    pub fn peek(r: *const Rest) ?u8 {
        assert(r.i <= r.s.len);
        return if (r.i < r.s.len) r.s[r.i] else null;
    }
    /// Advances past white space as the lexer classes it (`isSpace`).
    pub fn skipSpace(r: *Rest) void {
        assert(r.i <= r.s.len);
        while (r.i < r.s.len and isSpace(r.s[r.i])) r.i += 1;
        assert(r.i == r.s.len or !isSpace(r.s[r.i]));
    }
    /// Returns the next §2.8.1 escaped identifier without its backslash and
    /// terminator, skipping leading white space, or null having consumed
    /// only that space: a macro is keyed on the bytes a `` `\name `` use reads.
    pub fn escapedIdent(r: *Rest) ?[]const u8 {
        r.skipSpace();
        if (r.i >= r.s.len or r.s[r.i] != '\\') return null;
        const start = r.i + 1;
        const k = escapedEnd(r.s, start);
        if (k == start) return null;
        r.i = k;
        return r.s[start..k];
    }
    /// Returns the next identifier (§2.8, `$` admitted first for system
    /// names), skipping leading white space, or null.
    pub fn ident(r: *Rest) ?[]const u8 {
        r.skipSpace();
        if (r.i >= r.s.len or !isIdentStart(r.s[r.i])) return null;
        const start = r.i;
        r.i = identEnd(r.s, start);
        assert(r.i > start);
        return r.s[start..r.i];
    }
};

/// Copies comment-stripped `text` to `pp.out`, handling directives (§10) and
/// macro uses (§10.4). An inactive conditional arm emits only its newlines.
pub fn scan(pp: *Pass, text: []const u8) Error!void {
    const out_before = pp.out.items.len;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        // §2.7 strings are opaque to macro expansion and to directives.
        if (c == '"') {
            const start = i;
            i = stringStop(text, i);
            const closed = i < text.len and text[i] == '"';
            if (closed) i += 1;
            if (pp.emitting()) {
                try pp.out.appendSlice(pp.arena, text[start..i]);
            } else {
                // IEEE 1364 §19.4: an ignored group "shall still follow the
                // Verilog HDL lexical conventions".
                // ponytail: only §3.6's one-line string is checked here.
                if (!closed) return pp.fail(pp.spanAt(start, i), "E0138", "", .{});
                try pp.putNewlines(text[start..i]);
            }
            continue;
        }
        // §2.8.1 escaped identifiers are opaque too (they may hold '`').
        if (c == '\\') {
            const start = i;
            i = escapedEnd(text, i + 1);
            if (pp.emitting()) try pp.out.appendSlice(pp.arena, text[start..i]);
            continue;
        }
        if (c == '`') {
            const at = i;
            i = try directive.directive(pp, text, i);
            assert(i > at);
            try pp.resync(i);
            continue;
        }
        // '\n' is no stop: `putNewlines` counts it in a dead arm.
        const end = findStop(text, i, "\"\\`");
        if (pp.emitting()) try pp.out.appendSlice(pp.arena, text[i..end]) else try pp.putNewlines(text[i..end]);
        i = end;
    }
    assert(i == text.len);
    assert(pp.out.items.len >= out_before);
}

/// Removes `//` and `/* */` comments, keeping their newlines; a one-line
/// block comment leaves one space, since §2.2 makes a comment a token
/// separator. Strings (§2.7), escaped identifiers (§2.8.1) and §28.4.3
/// encoded protect blocks are opaque; block comments do not nest (§2.4).
/// Returns one strip mark per comment, the stripped-to-source offset map.
/// An unterminated block comment is E0102 in `pp.cur_file`, which must
/// already name `src`. O(src.len).
pub fn stripComments(pp: *Pass, src: []const u8) Error!Stripped {
    assert(src.len <= std.math.maxInt(u32));
    // The output never grows past the input, so every append fits.
    var out: std.ArrayList(u8) = try .initCapacity(pp.arena, src.len);
    var marks: std.ArrayList(StripMark) = .empty;
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '"') {
            // An unterminated literal is the lexer's to report.
            const start = i;
            i = stringStop(src, i);
            if (i < src.len and src[i] == '"') i += 1;
            out.appendSliceAssumeCapacity(src[start..i]);
            continue;
        }
        if (c == '\\') {
            const start = i;
            i = escapedEnd(src, i + 1);
            out.appendSliceAssumeCapacity(src[start..i]);
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            const start = i;
            i = std.mem.findScalarPos(u8, src, i, '\n') orelse src.len;
            // IEEE 1364 §19.3.1: in `define text a `\` ending the comment
            // still continues the macro (iverilog br_gh435).
            var keep = i;
            while (keep > start + 2 and (src[keep - 1] == ' ' or src[keep - 1] == '\t' or src[keep - 1] == '\r')) keep -= 1;
            if (keep > start + 2 and src[keep - 1] == '\\' and inDefine(out.items)) keep -= 1 else keep = i;
            try marks.append(pp.arena, .{ .out = @intCast(out.items.len), .src = @intCast(keep) });
            out.appendSliceAssumeCapacity(src[keep..i]);
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            const start = i;
            // The `*` of the first `*/` past the opener.
            var k = start + 2;
            i = while (std.mem.findScalarPos(u8, src, k + 1, '/')) |slash| {
                if (src[slash - 1] == '*') break slash - 1;
                k = slash;
            } else return pp.fail(pp.spanAt(start, start + 2), "E0102", "", .{});
            const lines = std.mem.countScalar(u8, src[start..i], '\n');
            if (lines == 0) {
                out.appendAssumeCapacity(' ');
            } else if (inDefine(out.items)) {
                // A `\` ending a line of the comment continues the macro
                // (iverilog macro_comment_multiline).
                var prev: u8 = 0;
                for (src[start..i]) |b| {
                    if (b == '\n') {
                        if (prev == '\\') out.appendAssumeCapacity('\\');
                        out.appendAssumeCapacity('\n');
                    }
                    if (b != ' ' and b != '\t' and b != '\r') prev = b;
                }
            } else {
                out.appendNTimesAssumeCapacity('\n', lines);
            }
            i += 2;
            try marks.append(pp.arena, .{ .out = @intCast(out.items.len), .src = @intCast(i) });
            continue;
        }
        if (c == '`') {
            // §28.4.3: a protect block's encoded lines are data up to the
            // next directive line; base64 and uuencode spell `//` and `/*`.
            const nl = std.mem.findScalarPos(u8, src, i, '\n') orelse src.len;
            const start = i;
            i += 1;
            if (protect.opensBlock(src[start..nl])) {
                i = nl;
                while (i < src.len) {
                    const next = std.mem.findScalarPos(u8, src, i + 1, '\n') orelse src.len;
                    if (std.mem.startsWith(u8, std.mem.trimStart(u8, src[i + 1 .. next], " \t"), "`")) break;
                    i = next;
                }
            }
            out.appendSliceAssumeCapacity(src[start..i]);
            continue;
        }
        // `end == i` is a '/' that starts no comment.
        const end = findStop(src, i, "\"\\/`");
        if (end == i) {
            out.appendAssumeCapacity(c);
            i += 1;
        } else {
            out.appendSliceAssumeCapacity(src[i..end]);
            i = end;
        }
    }
    assert(i == src.len);
    assert(out.items.len <= src.len);
    return .{ .text = out.items, .marks = marks.items };
}

/// Returns the first index at or after `from` whose byte is in `stops`, else
/// `text.len`. O(result - from). Asserts that `from` is at most `text.len`.
pub fn findStop(text: []const u8, from: usize, comptime stops: []const u8) usize {
    assert(from <= text.len);
    // std's multi-needle search is scalar per needle: splat each stop and OR
    // the compare masks. The scalar loop is the tail and the oracle.
    var i = from;
    if (std.simd.suggestVectorLength(u8)) |lanes| {
        const V = @Vector(lanes, u8);
        const Mask = @Int(.unsigned, lanes);
        while (i + lanes <= text.len) : (i += lanes) {
            const block: V = text[i..][0..lanes].*;
            var hit: Mask = 0;
            inline for (stops) |stop| {
                const splat: V = @splat(stop);
                hit |= @as(Mask, @bitCast(block == splat));
            }
            if (hit != 0) return i + @ctz(hit);
        }
    }
    while (i < text.len) : (i += 1) {
        inline for (stops) |stop| {
            if (text[i] == stop) return i;
        }
    }
    assert(i == text.len);
    return i;
}

/// Returns the index of the closing quote, an unescaped newline, or EOF. A
/// `\` escapes the byte after it, a newline included. Asserts that
/// `text[start]` is the opening quote.
pub fn stringStop(text: []const u8, start: usize) usize {
    assert(text[start] == '"');
    var i = start + 1;
    // Each pass advances past one escape pair, so `text.len` passes bound it.
    for (0..text.len) |_| {
        i = findStop(text, i, "\"\n\\");
        if (i == text.len or text[i] != '\\') return i;
        i = @min(i + 2, text.len);
    }
    unreachable;
}

/// Reports whether `c` may start a §2.8 identifier. Admits `$`, which §2.8
/// forbids first, because `Rest.ident` also reads system names.
pub fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}

/// §2.8: letters, digits, `$` and `_`.
pub fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

/// §2.3 white space as the lexer classes it, form feed included.
pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

/// Returns the first index at or after `i` whose byte is not `isIdentChar`.
/// Asserts that `i <= s.len`.
pub fn identEnd(s: []const u8, i: usize) usize {
    assert(i <= s.len);
    var k = i;
    while (k < s.len and isIdentChar(s[k])) k += 1;
    assert(k == s.len or !isIdentChar(s[k]));
    return k;
}

/// Returns the end of the §2.8.1 escaped identifier whose body starts at
/// `i`: the first byte that is not printable ASCII. Asserts `i <= s.len`.
pub fn escapedEnd(s: []const u8, i: usize) usize {
    assert(i <= s.len);
    var k = i;
    while (k < s.len and s[k] >= 33 and s[k] <= 126) k += 1;
    assert(k == s.len or s[k] < 33 or s[k] > 126);
    return k;
}

// ---- private ----

/// Whether the end of `out` sits on a `define's logical line: walk back over
/// `\`-continued physical lines to the first, and look for the word there.
fn inDefine(out: []const u8) bool {
    var line_end = out.len;
    // Each pass moves `line_end` back past one newline.
    for (0..out.len + 1) |_| {
        const line_start = if (std.mem.findScalarLast(u8, out[0..line_end], '\n')) |n| n + 1 else 0;
        const line = std.mem.trimStart(u8, out[line_start..line_end], " \t");
        if (std.mem.startsWith(u8, line, "`define")) return true;
        if (line_start == 0) return false;
        const prev = std.mem.trimEnd(u8, out[0 .. line_start - 1], " \t\r");
        if (prev.len == 0 or prev[prev.len - 1] != '\\') return false;
        assert(line_start - 1 < line_end);
        line_end = line_start - 1;
    }
    unreachable;
}

test "findStop agrees with the scalar loop at every tail boundary" {
    // Oracle: a plain byte loop over the same stops.
    var buf: [200]u8 = @splat('a');
    for (0..buf.len) |hit| {
        buf[hit] = '`';
        defer buf[hit] = 'a';
        for (0..buf.len + 1) |from| {
            const want = if (from <= hit) hit else buf.len;
            try std.testing.expectEqual(want, findStop(&buf, from, "\"\\`"));
        }
    }
}

test "isIdentStart admits exactly §2.8's letters, `_`, and `$`" {
    for (0..256) |c| {
        const b: u8 = @intCast(c);
        const want = (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or b == '_' or b == '$';
        try std.testing.expectEqual(want, isIdentStart(b));
    }
}

test "Rest reads identifiers and escaped identifiers where the lexer splits them" {
    var r: Rest = .{ .s = "  a$1_ \\b-c d" };
    try std.testing.expectEqualStrings("a$1_", r.ident().?);
    try std.testing.expect(r.ident() == null);
    try std.testing.expectEqualStrings("b-c", r.escapedIdent().?);
    try std.testing.expect(r.escapedIdent() == null);
    try std.testing.expectEqualStrings("d", r.ident().?);
    try std.testing.expect(r.peek() == null);
}

test "stripComments: every kept byte maps back to itself, and stripping twice changes nothing" {
    // Oracle: the raw text itself, through the marks (`toSourceOffset`), and
    // idempotence: a stripped text holds no comment.
    const Preprocessor = @import("../Preprocessor.zig");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const opts: Preprocessor.Options = .{};
    const answers: std.StringHashMapUnmanaged(?[]const u8) = .empty;
    var pp: Pass = .{ .arena = arena_state.allocator(), .opts = &opts, .answers = &answers };
    _ = try pp.addFile("<source>", "");
    // By hand: `ab/*c*/d` runs in lockstep with the raw text from 7 at 3.
    const s = try stripComments(&pp, "ab/*c*/d");
    try std.testing.expectEqualStrings("ab d", s.text);
    try std.testing.expectEqualSlices(StripMark, &.{.{ .out = 3, .src = 7 }}, s.marks);
    // Then every short text over the bytes the stripper branches on.
    var prng: std.Random.DefaultPrng = .init(0xc0ffee);
    const rand = prng.random();
    const alphabet = "a /*\n\"\\";
    var buf: [48]u8 = undefined;
    for (0..4000) |_| {
        const raw = buf[0..rand.uintAtMost(usize, buf.len)];
        for (raw) |*b| b.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        const got = stripComments(&pp, raw) catch |e| switch (e) {
            error.PreprocessFailed => continue, // E0102, an unclosed `/*`
            else => return e,
        };
        try std.testing.expectEqual(std.mem.countScalar(u8, raw, '\n'), std.mem.countScalar(u8, got.text, '\n'));
        for (got.text, 0..) |c, k| {
            if (c == ' ' or c == '\n') continue;
            try std.testing.expectEqual(c, raw[Preprocessor.toSourceOffset(got.marks, @intCast(k))]);
        }
        const again = try stripComments(&pp, got.text);
        try std.testing.expectEqualStrings(got.text, again.text);
        try std.testing.expectEqual(@as(usize, 0), again.marks.len);
    }
}

test "stringStop ends at the closing quote, an unescaped newline, or the end" {
    // Oracle: §2.7, a literal closes at its quote and cannot span a line.
    try std.testing.expectEqual(@as(usize, 3), stringStop("\"ab\"x", 0));
    try std.testing.expectEqual(@as(usize, 3), stringStop("\"ab\nc\"", 0));
    try std.testing.expectEqual(@as(usize, 5), stringStop("\"a\\\"b\"", 0));
    try std.testing.expectEqual(@as(usize, 5), stringStop("\"a\\\nb", 0));
    try std.testing.expectEqual(@as(usize, 3), stringStop("\"ab", 0));
}
