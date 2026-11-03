//! The directives whose state outlives their line: one directive's operand
//! line in, its event appended to `Pass.events` (or the §10.7 line remap
//! set) out, every malformed operand refused with its clause's code.
//! Cites: LRM §2.6, §10.2 Syntax 10-1, §10.3 Syntax 10-2, §10.7; IEEE
//! 1364-2005 §19.2, §19.7, §19.8 Table 19-1, §19.9.
//!
//! Contents:
//! - `pub fn defaultDiscipline(pp: *Pass, rest: []const u8, off: usize) Error!void`
//! - `pub fn defaultTransition(pp: *Pass, rest: []const u8, off: usize) Error!void`
//! - `pub fn timescale(pp: *Pass, rest: []const u8, off: usize) Error!void`
//! - `pub fn defaultNettype(pp: *Pass, rest: []const u8, off: usize) Error!void`
//! - `pub fn unconnectedDrive(pp: *Pass, rest: []const u8, off: usize) Error!void`
//! - `pub fn line(pp: *Pass, rest: []const u8, at: usize, off: usize) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Pass = @import("Pass.zig");
const Error = Pass.Error;
const events = @import("events.zig");
const scan = @import("scan.zig");
const Rest = scan.Rest;
const toSourceOffset = @import("../Preprocessor.zig").toSourceOffset;

/// Parses a §10.2 Syntax 10-1 `default_discipline and records its event.
/// Both operands are optional; the bare form withdraws the default. Anything
/// but one of the fifteen qualifiers after the name is E0127.
pub fn defaultDiscipline(pp: *Pass, rest: []const u8, off: usize) Error!void {
    const before = pp.events.disciplines.items.len;
    defer assert(pp.events.disciplines.items.len <= before + 1);
    var r: Rest = .{ .s = rest };
    // The name is simple or escaped (annex D.1's `\logic`); a qualifier is a
    // keyword, which an escaped identifier never is (§2.8.2).
    const disc = r.escapedIdent() orelse r.ident() orelse "";
    const word = if (disc.len == 0) "" else r.ident() orelse "";
    const qual = std.meta.stringToEnum(events.Qualifier, word);
    if (word.len != 0 and qual == null)
        return pp.fail(pp.spanAt(off + r.i - word.len, off + r.i), "E0127", "`{s}` is not a qualifier", .{word});
    try expectEnd(pp, &r, off, "E0127", "qualifier");
    try pp.events.disciplines.append(pp.arena, .{ .at = @intCast(pp.out.items.len), .qualifier = qual, .discipline = disc });
}

/// Parses a §10.3 Syntax 10-2 `default_transition and records its event:
/// a mandatory, finite, non-negative time (E0129).
///
/// ponytail: reads one §2.6 number with scale factor (`4n`, `4e-9`), not a
/// full constant_expression; upgrade when a model writes `tr*2`.
pub fn defaultTransition(pp: *Pass, rest: []const u8, off: usize) Error!void {
    const before = pp.events.transitions.items.len;
    defer assert(pp.events.transitions.items.len <= before + 1);
    var r: Rest = .{ .s = rest };
    r.skipSpace();
    const start = r.i;
    while (r.i < r.s.len and !scan.isSpace(r.s[r.i])) r.i += 1;
    const text = r.s[start..r.i];
    if (text.len == 0)
        return pp.fail(pp.spanAt(off, off + r.s.len), "E0129", "`default_transition needs a transition time and this one has none", .{});
    // One signed §2.6 number token: `parseFloat` alone also reads C's
    // `0x10`, `1.` and `_1`.
    const num = if (text[0] == '+' or text[0] == '-') text[1..] else text;
    const t = if (isNumber(num)) parseReal(text) else null;
    // §4.5.8: a time; a negative one finishes before it starts.
    if (t == null or !(t.? >= 0.0) or !std.math.isFinite(t.?))
        return pp.fail(pp.spanAt(off + start, off + r.i), "E0129", "`{s}` is not a transition time", .{text});
    try expectEnd(pp, &r, off, "E0129", "transition time");
    try pp.mark(&pp.events.transitions, t);
}

/// Parses an IEEE 1364 §19.8 `` `timescale <unit> / <precision> `` and
/// records its event. Each operand is on Table 19-1's grid; every malformed
/// form, and a precision coarser than the unit, is E0142.
pub fn timescale(pp: *Pass, rest: []const u8, off: usize) Error!void {
    const before = pp.events.timescales.items.len;
    defer assert(pp.events.timescales.items.len <= before + 1);
    // Marked null first and filled in on success.
    try pp.mark(&pp.events.timescales, null);
    var r: Rest = .{ .s = rest };
    const unit = timeLiteral(&r) orelse return badTimescale(pp, off, &r);
    r.skipSpace();
    if (r.peek() != '/') return badTimescale(pp, off, &r);
    r.i += 1;
    const precision = timeLiteral(&r) orelse return badTimescale(pp, off, &r);
    // "The time precision shall be at least as precise as the time unit".
    if (precision > unit)
        return pp.fail(pp.spanAt(off, off + r.s.len), "E0142", "the time precision is coarser than the time unit", .{});
    r.skipSpace();
    if (r.i < r.s.len) return badTimescale(pp, off, &r);
    pp.events.timescales.items[before].value = .{ .unit = unit, .precision = precision };
}

/// Parses an IEEE 1364 §19.2 `default_nettype and records its region. The
/// operand is mandatory and anything off §19.2's list is E0140.
pub fn defaultNettype(pp: *Pass, rest: []const u8, off: usize) Error!void {
    const before = pp.events.nettypes.items.len;
    defer assert(pp.events.nettypes.items.len <= before + 1);
    var r: Rest = .{ .s = rest };
    const word = r.ident() orelse "";
    const value = std.meta.stringToEnum(events.NetType, word) orelse
        return pp.fail(pp.spanAt(off, off + r.s.len), "E0140", "`{s}` is not a net type", .{word});
    try expectEnd(pp, &r, off, "E0140", "net type");
    try pp.mark(&pp.events.nettypes, value);
}

/// Parses an IEEE 1364 §19.9 `` `unconnected_drive pull1 | pull0 `` and
/// records its region; any other operand, or none, is E0141.
pub fn unconnectedDrive(pp: *Pass, rest: []const u8, off: usize) Error!void {
    const before = pp.events.drives.items.len;
    defer assert(pp.events.drives.items.len <= before + 1);
    var r: Rest = .{ .s = rest };
    const word = r.ident() orelse "";
    // Not `stringToEnum`: `float` is `nounconnected_drive's value only.
    const value: events.Drive = if (std.mem.eql(u8, word, "pull0"))
        .pull0
    else if (std.mem.eql(u8, word, "pull1"))
        .pull1
    else
        return pp.fail(pp.spanAt(off, off + r.s.len), "E0141", "`{s}` is not a pull value", .{word});
    try expectEnd(pp, &r, off, "E0141", "pull value");
    try pp.mark(&pp.events.drives, value);
}

/// Parses an IEEE 1364 §19.7 `line <number> "<file>" <level> and remaps
/// §10.7 `__LINE__` and `__FILE__` from the next line on. Every operand is
/// required, nothing may follow, and only white space may share the line
/// (E0128); the level is checked and dropped.
pub fn line(pp: *Pass, rest: []const u8, at: usize, off: usize) Error!void {
    assert(off > at);
    if (pp.expand_site == null) {
        const f = pp.file(pp.cur_file);
        const end = off + rest.len;
        const line_start = if (std.mem.findScalarLast(u8, f.text[0..at], '\n')) |nl| nl + 1 else 0;
        for (f.text[line_start..at]) |c| if (!scan.isSpace(c))
            return pp.fail(pp.spanAt(line_start, at), "E0128", "text before the directive on its line", .{});
        // A comment ending on the line left a strip mark on it.
        // ponytail: linear in the file's comments; a `line is rare.
        for (f.marks) |m| if (m.out >= line_start and m.out <= end)
            return pp.fail(pp.spanAt(at, end), "E0128", "a comment on the directive's line", .{});
        // One opening on the line and ending later left its first newline
        // where the source has the comment's `/`.
        if (end < f.text.len and f.source[toSourceOffset(f.marks, @intCast(end))] != '\n')
            return pp.fail(pp.spanAt(at, end), "E0128", "a comment on the directive's line", .{});
    }
    var r: Rest = .{ .s = rest };
    r.skipSpace();
    const start = r.i;
    while (r.i < r.s.len and std.ascii.isDigit(r.s[r.i])) r.i += 1;
    if (r.i == start) return pp.fail(pp.spanAt(off, off + r.s.len), "E0128", "", .{});
    const n = std.fmt.parseInt(u32, r.s[start..r.i], 10) catch
        return pp.fail(pp.spanAt(off + start, off + r.i), "E0128", "`{s}` does not fit a line number", .{r.s[start..r.i]});
    if (n == 0) return pp.fail(pp.spanAt(off + start, off + r.i), "E0128", "the line number must be a positive integer", .{});
    r.skipSpace();
    if (r.peek() != '"') return pp.fail(pp.spanAt(off + r.i, off + r.s.len), "E0128", "the file name is missing", .{});
    const q = r.i + 1;
    r.i = std.mem.findScalarPos(u8, r.s, q, '"') orelse r.s.len;
    if (r.i >= r.s.len) return pp.fail(pp.spanAt(off + q - 1, off + r.i), "E0128", "unterminated file name", .{});
    const name = r.s[q..r.i];
    r.i += 1;
    r.skipSpace();
    const level = r.i;
    if (r.i >= r.s.len or r.s[r.i] < '0' or r.s[r.i] > '2')
        return pp.fail(pp.spanAt(off + level, off + r.s.len), "E0128", "the level must be 0, 1 or 2", .{});
    r.i += 1;
    if (std.mem.trim(u8, r.s[r.i..], " \t\r\n").len != 0)
        return pp.fail(pp.spanAt(off + level, off + r.s.len), "E0128", "`{s}` is not a level", .{std.mem.trim(u8, r.s[level..], " \t\r\n")});
    pp.file_override = name;
    pp.line_from = pp.physicalLine(at) + 1;
    pp.line_to = n;
    assert(pp.line_from > 1);
    assert(n > 0);
}

// ---- private ----

fn badTimescale(pp: *Pass, off: usize, r: *const Rest) Error {
    const wrote = std.mem.trim(u8, r.s, " \t\r");
    return pp.fail(pp.spanAt(off, off + r.s.len), "E0142", "`{s}` is not a `timescale <time_unit>/<time_precision>", .{wrote});
}

/// Fails with `code` if anything but white space is left on the line: the
/// operand, named by `what`, is the last thing its syntax allows.
fn expectEnd(pp: *Pass, r: *Rest, off: usize, comptime code: []const u8, what: []const u8) Error!void {
    r.skipSpace();
    if (r.i == r.s.len) return;
    return pp.fail(pp.spanAt(off + r.i, off + r.s.len), code, "`{s}` follows the {s}", .{ std.mem.trim(u8, r.s[r.i..], " \t\r"), what });
}

/// Reads one Table 19-1 time literal (`1`, `10` or `100` glued to one of
/// `s ms us ns ps fs`) as seconds, or null with the cursor undefined.
fn timeLiteral(r: *Rest) ?f64 {
    r.skipSpace();
    const start = r.i;
    while (r.i < r.s.len and std.ascii.isDigit(r.s[r.i])) r.i += 1;
    const mags = std.StaticStringMap(i8).initComptime(.{ .{ "1", 0 }, .{ "10", 1 }, .{ "100", 2 } });
    const mag = mags.get(r.s[start..r.i]) orelse return null;
    const unit = r.ident() orelse return null;
    const units = std.StaticStringMap(i8).initComptime(.{
        .{ "s", 0 },   .{ "ms", -3 },  .{ "us", -6 },
        .{ "ns", -9 }, .{ "ps", -12 }, .{ "fs", -15 },
    });
    // Exact decimal literals: 100 * 1e-6 is one ulp off the 1e-4 §9.15 reads.
    const decades = [_]f64{
        1e-15, 1e-14, 1e-13, 1e-12, 1e-11, 1e-10, 1e-9, 1e-8, 1e-7,
        1e-6,  1e-5,  1e-4,  1e-3,  1e-2,  1e-1,  1e0,  1e1,  1e2,
    };
    const k = mag + (units.get(unit) orelse return null) + 15;
    assert(k >= 0);
    assert(k < decades.len);
    return decades[@intCast(k)];
}

/// Whether `s` is exactly one §2.6 unsigned decimal number token, as the
/// lexer reads one: digits and `_`, then `.digits`, then an exponent or a
/// Table 2-1 scale factor. A based constant (`'`) is no time.
fn isNumber(s: []const u8) bool {
    var i = digitsEnd(s, 0);
    if (i == 0) return false;
    if (i + 1 < s.len and s[i] == '.' and std.ascii.isDigit(s[i + 1])) i = digitsEnd(s, i + 1);
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        var e = i + 1;
        if (e < s.len and (s[e] == '+' or s[e] == '-')) e += 1;
        if (e < s.len and std.ascii.isDigit(s[e])) i = digitsEnd(s, e);
    } else if (i < s.len and scale(s[i]) != null and (i + 1 == s.len or !scan.isIdentChar(s[i + 1]))) {
        i += 1;
    }
    return i == s.len;
}

fn digitsEnd(s: []const u8, from: usize) usize {
    var i = from;
    if (i < s.len and !std.ascii.isDigit(s[i])) return i;
    while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '_')) i += 1;
    return i;
}

/// The exponent a §2.6.2 Table 2-1 scale factor stands for.
fn scale(c: u8) ?[]const u8 {
    return switch (c) {
        'T' => "e12",
        'G' => "e9",
        'M' => "e6",
        'K', 'k' => "e3",
        'm' => "e-3",
        'u' => "e-6",
        'n' => "e-9",
        'p' => "e-12",
        'f' => "e-15",
        'a' => "e-18",
        else => null,
    };
}

/// A signed number `isNumber` accepted, as f64: `_` dropped and a scale
/// factor spelled as its exponent, so it rounds once. Null if too long.
fn parseReal(text: []const u8) ?f64 {
    var buf: [512]u8 = undefined;
    const exp = scale(text[text.len - 1]);
    const body = if (exp != null) text[0 .. text.len - 1] else text;
    var n: usize = 0;
    for (body) |c| {
        if (c == '_') continue;
        if (n == buf.len) return null;
        buf[n] = c;
        n += 1;
    }
    const tail = exp orelse "";
    if (n + tail.len > buf.len) return null;
    @memcpy(buf[n..][0..tail.len], tail);
    return std.fmt.parseFloat(f64, buf[0 .. n + tail.len]) catch null;
}

test "isNumber reads one §2.6 token, as the lexer does" {
    // Oracle: lib/frontend/lexer.zig's tests (`9.`, `4.E3`, `4af` are not one number).
    for ([_][]const u8{ "4", "4n", "1_0", "1.5", "1e-3", "2.5E+4", "7k", "1.5a" }) |s| try std.testing.expect(isNumber(s));
    for ([_][]const u8{ "", "9.", "4.E3", "4af", ".5", "_1", "0x10", "4'b1", "1e", "1nk" }) |s| try std.testing.expect(!isNumber(s));
}
