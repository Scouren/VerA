//! The card rows a netlist is read into (`Card`), the refusal list
//! (`Refusals`), the `.MODEL` type table (`model_types`), the text helpers
//! every reader shares (a card's tokens, comment stripping, quote and `=`
//! normalisation, a `.SUBCKT`'s body) and the SPICE spellings (scaled
//! numbers, identifier shapes, the §2.8.1 escaped spelling).
//! Cites: LRM §2.6.2 Table 2-1, §2.7, §2.8, §2.8.1; annex E.1.2, E.2, E.2.1,
//! E.2.2.1, E.3, Table E.1.
//!
//! Contents:
//! - `pub const Card = struct`
//! - `pub const Refusals = struct`: `add`, `addCode`
//! - `pub const model_types = [_]struct`
//! - `pub const ModelCard = struct`
//! - `pub const Tokens = struct`: `next`
//! - `pub fn hasEntry(text: []const u8, entry: []const u8) bool`
//! - `pub fn unquote(t: []const u8) []const u8`
//! - `pub fn tightEquals(arena: Allocator, card: []const u8) Allocator.Error![]const u8`
//! - `pub fn strip(raw: []const u8) []const u8`
//! - `pub fn subcktBody(rest: []const Card) []const Card`
//! - `pub fn spiceNumber(t: []const u8) ?f64`
//! - `pub fn isIdent(t: []const u8) bool`
//! - `pub fn isSpiceName(t: []const u8) bool`
//! - `pub fn spell(arena: Allocator, t: []const u8) Allocator.Error![]const u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const spice = @import("../spice.zig");
const Token = @import("../tokenizer.zig").Token;
const Diag = @import("../Diag.zig");
const Refusal = spice.Refusal;

/// A logical card (continuations joined) and where its first line starts;
/// also one physical line of it (`Reader.lines`), comments stripped and
/// lower-cased. `at` and `len` index `Output.files[file].text`.
pub const Card = struct {
    text: []const u8,
    file: u32 = 0,
    at: u32,
    len: u32,

    comptime {
        assert(@sizeOf(Card) <= 32); // a slice and three words
    }
};

/// The refusals of one read, in the order they are met; the messages live
/// on `arena`.
pub const Refusals = struct {
    arena: Allocator,
    list: std.ArrayList(Refusal) = .empty,

    /// Appends an E0928 refusal at `card`. Asserts that `card` is not empty.
    pub fn add(r: *Refusals, card: Card, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        return r.addCode(.E0928, card, fmt, args);
    }

    /// Appends a refusal with `code` at `card`. Asserts that `card` is not
    /// empty and `code` is E0928 or E0953.
    pub fn addCode(r: *Refusals, code: Diag.Code, card: Card, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        assert(card.text.len > 0);
        assert(code == .E0928 or code == .E0953);
        const n = r.list.items.len;
        try r.list.append(r.arena, .{ .code = code, .file = card.file, .at = card.at, .len = card.len, .message = try r.arena.print(fmt, args) });
        assert(r.list.items.len == n + 1);
    }
};

/// E.2.2.1: ".MODEL statements can be accessed in Verilog-AMS HDL ... The ports
/// and parameters of the bjt are determined by the bjt primitive itself and not
/// by the model statement." So a model card contributes a name and a primitive
/// type, and the interface comes from Table E.1's row for that type.
///
/// The rows are the SPICE model-type letters, mapped to the Table E.1
/// primitive each names. Absent types (`sw`, `ltra`, `core`, ...) are
/// recorded, not refused: E.1.2's first bullet makes the recognised flavor
/// "solely determined by the authors of the simulator". `ports` is pre-joined
/// in Table E.1's order, which E.3 makes normative for connection by order;
/// a test pins each row against `spice_primitives.vams`.
pub const model_types = [_]struct { type_: []const u8, prim: []const u8, ports: []const u8 }{
    .{ .type_ = "npn", .prim = "bjt", .ports = "c, b, e, s" },
    .{ .type_ = "pnp", .prim = "bjt", .ports = "c, b, e, s" },
    .{ .type_ = "d", .prim = "diode", .ports = "a, c" },
    .{ .type_ = "nmos", .prim = "mosfet", .ports = "d, g, s, b" },
    .{ .type_ = "pmos", .prim = "mosfet", .ports = "d, g, s, b" },
    .{ .type_ = "njf", .prim = "jfet", .ports = "d, g, s" },
    .{ .type_ = "pjf", .prim = "jfet", .ports = "d, g, s" },
    .{ .type_ = "nmf", .prim = "mesfet", .ports = "d, g, s" },
    .{ .type_ = "pmf", .prim = "mesfet", .ports = "d, g, s" },
    .{ .type_ = "r", .prim = "resistor", .ports = "p, n" },
    .{ .type_ = "c", .prim = "capacitor", .ports = "p, n" },
    .{ .type_ = "l", .prim = "inductor", .ports = "p, n" },
};

/// One `.MODEL` card of the netlist, wherever it sits: what a body card's
/// model name resolves to (`model.emitModelCard`).
pub const ModelCard = struct {
    name: []const u8,
    type_: []const u8,
    card: Card,
};

/// A card's fields: split at blanks and at `(`, `)` and `,`, which are noise
/// in a SPICE card, except inside a `{...}` or `'...'` expression, which is
/// one field whatever it holds (HSPICE writes `{w * 2}`, `'max(a, b)'`).
pub const Tokens = struct {
    text: []const u8,
    i: usize = 0,

    const seps = " \t(),";

    /// Returns the next field, never empty, or null at the end.
    pub fn next(t: *Tokens) ?[]const u8 {
        assert(t.i <= t.text.len);
        while (t.i < t.text.len and std.mem.findScalar(u8, seps, t.text[t.i]) != null) t.i += 1;
        if (t.i == t.text.len) return null;
        const start = t.i;
        var depth: usize = 0;
        var quoted = false;
        while (t.i < t.text.len) : (t.i += 1) {
            const c = t.text[t.i];
            if (c == '\'') {
                quoted = !quoted;
            } else if (quoted) {
                continue;
            } else if (c == '{') {
                depth += 1;
            } else if (c == '}') {
                depth -|= 1;
            } else if (depth == 0 and std.mem.findScalar(u8, seps, c) != null) break;
        }
        // The first byte is no separator, so the field holds one at least.
        assert(t.i > start);
        assert(t.i <= t.text.len);
        return t.text[start..t.i];
    }
};

/// Reports whether `text` has a `.LIB entry` header, so an empty entry is
/// not reported as a missing one.
pub fn hasEntry(text: []const u8, entry: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var it = std.mem.tokenizeAny(u8, strip(raw), " \t");
        if (!std.ascii.eqlIgnoreCase(it.next() orelse continue, ".lib")) continue;
        if (std.ascii.eqlIgnoreCase(unquote(it.next() orelse continue), entry) and it.next() == null) return true;
    }
    return false;
}

/// Returns a file name or entry without the `"`/`'` SPICE dialects put
/// around it.
pub fn unquote(t: []const u8) []const u8 {
    if (t.len >= 2 and (t[0] == '"' or t[0] == '\'') and t[t.len - 1] == t[0]) return t[1 .. t.len - 1];
    return t;
}

/// Returns `card` with the white space around each `=` removed, on `arena`:
/// HSPICE writes `level = 72`, and every reader splits a parameter on its
/// `=` within one token.
pub fn tightEquals(arena: Allocator, card: []const u8) Allocator.Error![]const u8 {
    if (std.mem.findScalar(u8, card, '=') == null) return arena.dupe(u8, card);
    var out: std.ArrayList(u8) = try .initCapacity(arena, card.len);
    for (card, 0..) |c, i| {
        const blank = c == ' ' or c == '\t';
        if (blank) {
            const next = std.mem.trimStart(u8, card[i..], " \t");
            if (next.len != 0 and next[0] == '=') continue;
            if (out.items.len != 0 and out.items[out.items.len - 1] == '=') continue;
        }
        out.appendAssumeCapacity(c);
    }
    assert(out.items.len <= card.len);
    return out.items;
}

/// Returns one physical line without its comments: `*` is a full-line
/// comment, `;` and `$` start a trailing one.
pub fn strip(raw: []const u8) []const u8 {
    var line = std.mem.trim(u8, raw, " \t\r");
    if (line.len != 0 and line[0] == '*') return "";
    if (std.mem.findAny(u8, line, ";$")) |at| line = std.mem.trim(u8, line[0..at], " \t");
    return line;
}

/// Returns the cards `rest[0]` owns, excluding the terminating `.ENDS`; empty
/// unless `rest[0]` is a `.SUBCKT` header. E.2 makes a subcircuit a module
/// definition and E.2.2.2 shows its device cards as its body; the first
/// `.ENDS` ends it, and an unterminated one keeps the rest. Asserts that
/// `rest` is not empty.
pub fn subcktBody(rest: []const Card) []const Card {
    assert(rest.len != 0);
    if (!std.mem.startsWith(u8, rest[0].text, ".subckt")) return &.{};
    for (rest[1..], 1..) |card, i| {
        if (std.mem.startsWith(u8, card.text, ".ends")) return rest[1..i];
    }
    return rest[1..];
}

/// Parses SPICE's scaled notation, which annex E prints throughout its
/// netlists (`10K`, `1P`, `0.3NS`, `1MA`); E.2.2.3 translates `10K` as
/// `10k`, which §2.6.2 Table 2-1 makes ten thousand. Unit letters after the
/// scale (`PF`, `UH`, `NS`) carry no value and are ignored. Returns null
/// when `t` does not start with a number, when its exponent does not fit an
/// i32, or when a scaled number's joined text passes 128 bytes; a value
/// past f64's range is an infinity.
pub fn spiceNumber(t: []const u8) ?f64 {
    var i: usize = 0;
    if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
    const digits = i;
    while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
    if (i < t.len and t[i] == '.') {
        i += 1;
        while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
    }
    if (i == digits or (i == digits + 1 and t[digits] == '.')) return null;
    const mant_end = i;
    assert(mant_end <= t.len);
    // An exponent only if it is complete: `1E-18` is a number, the `E` of a
    // bare `1EXP` is the start of unit noise.
    var own: i32 = 0;
    if (i < t.len and t[i] == 'e') {
        var j = i + 1;
        if (j < t.len and (t[j] == '+' or t[j] == '-')) j += 1;
        if (j < t.len and std.ascii.isDigit(t[j])) {
            while (j < t.len and std.ascii.isDigit(t[j])) j += 1;
            own = std.fmt.parseInt(i32, t[i + 1 .. j], 10) catch return null;
            i = j;
        }
    }
    const scale = spiceScale(t[i..]);
    if (scale.exp == 0) return (std.fmt.parseFloat(f64, t[0..i]) catch return null) * scale.mul;
    // Rounds once, as the lexer's §2.6.2 factors do: `50n` is
    // parseFloat("50e-9"), while 50 * 1e-9 is a different double. i64: an
    // exponent at the end of i32 plus the scale's would overflow.
    var buf: [128]u8 = undefined;
    const joined = std.mem.print(&buf, "{s}e{d}", .{ t[0..mant_end], @as(i64, own) + scale.exp }) catch return null;
    return std.fmt.parseFloat(f64, joined) catch null;
}

/// Reports whether `t` has the §2.7 shape of a simple identifier. `$` is not
/// admitted even though §2.7 allows it: `strip` has already treated it as a
/// comment opener, so it cannot reach here.
pub fn isIdent(t: []const u8) bool {
    if (t.len == 0) return false;
    if (!std.ascii.isAlphabetic(t[0]) and t[0] != '_') return false;
    for (t) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    // An identifier is a SPICE name too, so `spell` may write it bare.
    assert(isSpiceName(t));
    return true;
}

/// Reports whether `t` is a SPICE model, subcircuit or node name. SPICE names
/// may lead with digits (`2N2222`) and bare numbers are the default node
/// spelling, so anything printable that is not a parameter (`k=v`,
/// `params:`) qualifies; `spell` decides how it is written.
pub fn isSpiceName(t: []const u8) bool {
    if (t.len == 0) return false;
    assert(t.len <= std.math.maxInt(u32));
    for (t) |c| if (c < 33 or c > 126 or c == '=' or c == ':') return false;
    return true;
}

/// Returns `t` as it must be written to declare it: bare when it is a simple
/// identifier and not a keyword, otherwise as a §2.8.1 escaped identifier
/// (`\wire `, `\2n2222 `) on `arena`, since SPICE has no reserved words and
/// no §2.7 shape rule. Neither the `\` nor the terminating blank is part of
/// the name (§2.8.1), so lookups still see `wire`; the blank is required,
/// or a following `,` or `)` would scan into the name. Asserts that `t` is
/// not empty.
pub fn spell(arena: Allocator, t: []const u8) Allocator.Error![]const u8 {
    assert(t.len > 0);
    if (isIdent(t) and Token.getKeyword(t) == null) return t;
    const out = try arena.print("\\{s} ", .{t});
    assert(out.len == t.len + 2);
    return out;
}

// ---- private ----

/// Berkeley SPICE's ten scale factors, as a power of ten (`exp`) or, for
/// `mil`, a factor. `meg` and `mil` are tested before `m` because they share
/// its first letter. SPICE and §2.6.2 Table 2-1 disagree on `M` (milli here,
/// mega there), which is why a card's number is converted to plain decimal
/// rather than handed on with its suffix. SPICE has no atto, so `1A` is one
/// ampere.
fn spiceScale(rest: []const u8) struct { exp: i32 = 0, mul: f64 = 1.0 } {
    assert(rest.len <= std.math.maxInt(u32));
    if (std.mem.startsWith(u8, rest, "meg")) return .{ .exp = 6 };
    if (std.mem.startsWith(u8, rest, "mil")) return .{ .mul = 25.4e-6 };
    const scales = [_]struct { suffix: u8, exp: i32 }{
        .{ .suffix = 't', .exp = 12 },
        .{ .suffix = 'g', .exp = 9 },
        .{ .suffix = 'k', .exp = 3 },
        .{ .suffix = 'm', .exp = -3 },
        .{ .suffix = 'u', .exp = -6 },
        .{ .suffix = 'n', .exp = -9 },
        .{ .suffix = 'p', .exp = -12 },
        .{ .suffix = 'f', .exp = -15 },
    };
    if (rest.len != 0) for (scales) |s| if (rest[0] == s.suffix) return .{ .exp = s.exp };
    return .{};
}

test "model_types names a real Table E.1 module with the ports it lists" {
    // A row whose primitive or port order does not match the prelude would
    // be wrong without any other test noticing.
    const prelude = @embedFile("../spice_primitives.vams");
    for (model_types) |r| {
        const header = try std.testing.allocator.print("module {s}({s});", .{ r.prim, r.ports });
        defer std.testing.allocator.free(header);
        try std.testing.expect(std.mem.find(u8, prelude, header) != null);
    }
}

test "SPICE's scaled notation, including the three suffixes §2.6.2 does not share" {
    // The annex prints `10K`, `3PF`, `1UH`, `0.3NS`, `1MA`, `1E-18` in its
    // own netlists. `MEG`/`MIL` are the SPICE-only ones, and `M` is milli
    // here where §2.6.2 Table 2-1 makes it mega.
    try std.testing.expectEqual(@as(?f64, 10000), spiceNumber("10k"));
    try std.testing.expectEqual(@as(?f64, 3e-12), spiceNumber("3pf"));
    try std.testing.expectEqual(@as(?f64, 1e-6), spiceNumber("1uh"));
    try std.testing.expectEqual(@as(?f64, 0.3e-9), spiceNumber("0.3ns"));
    try std.testing.expectEqual(@as(?f64, 1e-3), spiceNumber("1ma"));
    try std.testing.expectEqual(@as(?f64, 1e6), spiceNumber("1meg"));
    try std.testing.expectEqual(@as(?f64, 25.4e-6), spiceNumber("1mil"));
    try std.testing.expectEqual(@as(?f64, 1e-18), spiceNumber("1e-18"));
    try std.testing.expectEqual(@as(?f64, -2.5), spiceNumber("-2.5"));
    // The scale rounds once: 50 * 1e-9 is 5.0000000000000004e-8, one ulp off.
    try std.testing.expectEqual(@as(?f64, 5e-8), spiceNumber("50n"));
    try std.testing.expectEqual(@as(?f64, 2.2e-9), spiceNumber("2.2n"));
    try std.testing.expectEqual(@as(?f64, 1.5e-6), spiceNumber("1.5e-3m"));
    // SPICE has no atto, so a bare `1A` is one ampere and the letter is noise.
    try std.testing.expectEqual(@as(?f64, 1.0), spiceNumber("1a"));
    try std.testing.expectEqual(@as(?f64, null), spiceNumber("rmod"));
    try std.testing.expectEqual(@as(?f64, null), spiceNumber(""));
    try std.testing.expectEqual(@as(?f64, null), spiceNumber("."));
}

test "spiceNumber never panics: an exponent past i32 is not a number, a huge one is infinite" {
    try std.testing.expect(std.math.isInf(spiceNumber("1e2147483647k").?));
    const tiny = spiceNumber("-1e-2147483648f").?;
    try std.testing.expect(tiny == 0);
    try std.testing.expect(std.math.signbit(tiny));
    try std.testing.expectEqual(@as(?f64, null), spiceNumber("1e99999999999k"));
    // Past the 128-byte join a scaled number is refused; unscaled it is read.
    var long: [132]u8 = @splat('0');
    long[0] = '1';
    long[131] = 'k';
    try std.testing.expectEqual(@as(?f64, null), spiceNumber(&long));
    try std.testing.expectEqual(@as(?f64, 1e130), spiceNumber(long[0..131]));
    try std.testing.expectEqual(@as(?f64, 0.5), spiceNumber("+.5"));
    try std.testing.expectEqual(@as(?f64, 5e-7), spiceNumber(".5u"));
    // An incomplete exponent is unit noise, as are other letters.
    try std.testing.expectEqual(@as(?f64, 1), spiceNumber("1e"));
    try std.testing.expectEqual(@as(?f64, 1), spiceNumber("1x"));
    try std.testing.expectEqual(@as(?f64, null), spiceNumber("-"));
    try std.testing.expectEqual(@as(?f64, null), spiceNumber("+"));
    try std.testing.expectEqual(@as(?f64, null), spiceNumber("e5"));
}

test "the card text helpers: tightEquals, Tokens, strip, unquote, hasEntry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Pair = struct { []const u8, []const u8 };
    for ([_]Pair{
        .{ "level = 72", "level=72" },
        .{ "a  =  b c", "a=b c" },
        .{ "x= y", "x=y" },
        .{ "x =y", "x=y" },
        .{ "no equals here", "no equals here" },
    }) |p| try std.testing.expectEqualStrings(p[1], try tightEquals(arena, p[0]));
    const Split = struct { []const u8, []const []const u8 };
    for ([_]Split{
        .{ ".subckt ecposc (out gnd)", &.{ ".subckt", "ecposc", "out", "gnd" } },
        .{ "r1 a b {w * 2}", &.{ "r1", "a", "b", "{w * 2}" } },
        .{ "x1 a 'max(a, b)' c", &.{ "x1", "a", "'max(a, b)'", "c" } },
        .{ "{a {b} c} d", &.{ "{a {b} c}", "d" } },
        // A stray `}` does not open anything.
        .{ "a}b c", &.{ "a}b", "c" } },
        .{ " ,() ", &.{} },
    }) |c| {
        var it: Tokens = .{ .text = c[0] };
        for (c[1]) |want| try std.testing.expectEqualStrings(want, it.next().?);
        try std.testing.expect(it.next() == null);
    }
    try std.testing.expectEqualStrings("", strip("* a full-line comment"));
    try std.testing.expectEqualStrings("r1 a b 1k", strip("r1 a b 1k ; note"));
    try std.testing.expectEqualStrings("r1 a b 1k", strip("r1 a b 1k $ note"));
    try std.testing.expectEqualStrings("x", strip("  x \r"));
    try std.testing.expectEqualStrings("", strip("   ; only a comment"));
    try std.testing.expectEqualStrings("a", unquote("'a'"));
    try std.testing.expectEqualStrings("a", unquote("\"a\""));
    try std.testing.expectEqualStrings("'a\"", unquote("'a\""));
    try std.testing.expect(hasEntry(".lib tt\n.endl\n", "TT"));
    try std.testing.expect(hasEntry("* c\n.LIB 'tt'\n", "tt"));
    try std.testing.expect(!hasEntry(".lib file.sp tt\n", "tt"));
}

test "names: isIdent, isSpiceName and spell" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "_a1", "w" }) |t| try std.testing.expect(isIdent(t));
    for ([_][]const u8{ "", "a$", "1a", "a.b" }) |t| try std.testing.expect(!isIdent(t));
    for ([_][]const u8{ "2n2222", "a.b", "0", "{x}" }) |t| try std.testing.expect(isSpiceName(t));
    for ([_][]const u8{ "", "a=b", "x:", "a\x7f", "a b" }) |t| try std.testing.expect(!isSpiceName(t));
    try std.testing.expectEqualStrings("w", try spell(arena, "w"));
    try std.testing.expectEqualStrings("\\wire ", try spell(arena, "wire"));
    try std.testing.expectEqualStrings("\\2n ", try spell(arena, "2n"));
    try std.testing.expectEqualStrings("\\a.b ", try spell(arena, "a.b"));
}
