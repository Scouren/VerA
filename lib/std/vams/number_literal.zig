//! Literal decoding on demand (Zig's `lib/std/zig/number_literal.zig`): one
//! `number_literal` token's text in, its §2.6.1 integer shape, §2.6.2 real
//! value or the reason it is malformed out (`parseNumberLiteral`,
//! `parseReal`); one `string_literal` token's text in, its §2.7 bytes out
//! (`stringContents`, `badEscape`). Nothing here allocates except
//! `stringContents`; the parser calls only the validators, AstGen decodes.
//! Cites: VAMS-2023 §2.6.1, §2.6.2 Table 2-1, §2.7 Table 2-2; IEEE 1364-2005
//! §3.5.1.
//!
//! Contents:
//! - `pub const Error = enum(u8)`
//! - `pub const Int = struct`
//! - `pub const Result = union(enum)`
//! - `pub fn parseNumberLiteral(text: []const u8) Result`
//! - `pub fn intValue(int: Int) ?u64`
//! - `pub fn scaleExponent(c: u8) ?[]const u8`
//! - `pub fn parseReal(buf: []u8, text: []const u8) error{NoSpaceLeft}!f64`
//! - `pub fn badEscape(text: []const u8) ?usize`
//! - `pub fn stringContents(gpa: Allocator, text: []const u8) Allocator.Error![]u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// Why a §2.6.1 integer is malformed; the old parser's E0131, E0132, E0133
/// (`zero_size`, `invalid_digit`) and E1019.
pub const Error = enum(u8) {
    /// A `'` with no `b`, `o`, `d` or `h` after it.
    missing_base,
    /// A base format with no digit after it.
    missing_digits,
    /// A size of zero.
    zero_size,
    /// A digit the base does not have, a leading `_`, a size with a
    /// leading 0, or x/z in a simple decimal.
    invalid_digit,
    /// A size or digit count past `u32`.
    overflow,
};

/// A well-formed §2.6.1 integer: `size` 0 when unsized.
pub const Int = struct {
    size: u32,
    signed: bool,
    radix: u8,
    /// The text after the base letter (or the whole decimal number),
    /// `_`, white space and x/z/? digits included.
    digits: []const u8,
};

pub const Result = union(enum) {
    int: Int,
    /// A §2.6.2 real; `parseReal` decodes it.
    real,
    failure: Error,
};

/// Classifies one `number_literal` token's text, validating an integer as
/// `kernels.Integer.parse` does. Asserts the text starts with a digit or `'`.
pub fn parseNumberLiteral(text: []const u8) Result {
    assert(text.len != 0);
    assert(std.ascii.isDigit(text[0]) or text[0] == '\'');
    const quote = std.mem.findScalar(u8, text, '\'') orelse {
        for (text) |c| if (!std.ascii.isDigit(c) and c != '_') return .real;
        return .{ .int = .{ .size = 0, .signed = true, .radix = 10, .digits = text } };
    };
    var i = quote + 1;
    const signed = i < text.len and (text[i] == 's' or text[i] == 'S');
    if (signed) i += 1;
    if (i >= text.len) return .{ .failure = .missing_base };
    const radix: u8 = switch (std.ascii.toLower(text[i])) {
        'b' => 2,
        'o' => 8,
        'd' => 10,
        'h' => 16,
        else => return .{ .failure = .missing_base },
    };
    const size_text = std.mem.trim(u8, text[0..quote], " \t\r\n\x0c");
    var size: u32 = 0;
    for (size_text, 0..) |c, n| {
        if (c == '_' and n != 0) continue;
        if (!std.ascii.isDigit(c)) return .{ .failure = .invalid_digit };
        size = std.math.mul(u32, size, 10) catch return .{ .failure = .overflow };
        size = std.math.add(u32, size, c - '0') catch return .{ .failure = .overflow };
    }
    if (size_text.len != 0 and size == 0) return .{ .failure = .zero_size };
    if (size_text.len != 0 and size_text[0] == '0') return .{ .failure = .invalid_digit };
    const digits = std.mem.trimStart(u8, text[i + 1 ..], " \t\r\n\x0c");
    if (digits.len == 0) return .{ .failure = .missing_digits };
    if (digits[0] == '_') return .{ .failure = .invalid_digit };
    var count: u32 = 0;
    var unknown = false;
    for (digits) |c| {
        if (c == '_') continue;
        count += 1;
        if (c == 'x' or c == 'X' or c == 'z' or c == 'Z' or c == '?') {
            unknown = true;
        } else _ = std.fmt.charToDigit(c, radix) catch return .{ .failure = .invalid_digit };
    }
    if (count == 0) return .{ .failure = .missing_digits };
    if (radix == 10 and unknown and count != 1) return .{ .failure = .invalid_digit };
    return .{ .int = .{ .size = size, .signed = signed, .radix = radix, .digits = digits } };
}

/// The value of a known integer that fits 64 bits before any truncation to
/// its size, else null (x/z digits, or wider: AstGen's wide decode).
pub fn intValue(int: Int) ?u64 {
    var v: u64 = 0;
    for (int.digits) |c| {
        if (c == '_') continue;
        const d = std.fmt.charToDigit(c, int.radix) catch return null;
        v = std.math.mul(u64, v, int.radix) catch return null;
        v = std.math.add(u64, v, d) catch return null;
    }
    return v;
}

/// The exponent a Table 2-1 scale factor stands for, or null.
pub fn scaleExponent(c: u8) ?[]const u8 {
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

/// Decodes a §2.6.2 real into `buf`'s scratch: `_` dropped and a scale
/// factor rewritten as an exponent, so it rounds once. Fails when `buf` is
/// shorter than the text plus four bytes.
pub fn parseReal(buf: []u8, text: []const u8) error{NoSpaceLeft}!f64 {
    const scale = scaleExponent(text[text.len - 1]);
    const body = if (scale != null) text[0 .. text.len - 1] else text;
    if (buf.len < body.len + 4) return error.NoSpaceLeft;
    var n: usize = 0;
    for (body) |c| if (c != '_') {
        buf[n] = c;
        n += 1;
    };
    if (scale) |s| {
        @memcpy(buf[n..][0..s.len], s);
        n += s.len;
    }
    assert(n <= buf.len);
    // The tokenizer only makes well-formed reals.
    return std.fmt.parseFloat(f64, buf[0..n]) catch unreachable;
}

/// The offset of the first octal escape above `\377` in a string literal's
/// text (quotes included), or null (§2.7 Table 2-2's `\ddd`).
pub fn badEscape(text: []const u8) ?usize {
    var i: usize = 1;
    while (i + 1 < text.len) : (i += 1) {
        if (text[i] != '\\') continue;
        const start = i;
        i += 1;
        var v: u16 = 0;
        var k: usize = 0;
        while (k < 3 and i + 1 < text.len and text[i] >= '0' and text[i] <= '7') : (k += 1) {
            v = v * 8 + (text[i] - '0');
            i += 1;
        }
        if (v > 0o377) return start;
        if (k != 0) i -= 1;
    }
    return null;
}

/// Decodes a string literal's text (quotes included) per Table 2-2; an
/// escape the table does not list is the escaped character. The caller owns
/// the result, freed with `gpa`.
pub fn stringContents(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    assert(text.len >= 2);
    const body = text[1 .. text.len - 1];
    var out = try gpa.alloc(u8, body.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        var c = body[i];
        if (c == '\\' and i + 1 < body.len) {
            i += 1;
            c = switch (body[i]) {
                'n' => '\n',
                't' => '\t',
                '0'...'7' => oct: {
                    var v: u16 = 0;
                    var k: usize = 0;
                    while (k < 3 and i < body.len and body[i] >= '0' and body[i] <= '7') : (k += 1) {
                        v = v * 8 + (body[i] - '0');
                        i += 1;
                    }
                    i -= 1;
                    break :oct @truncate(v);
                },
                else => body[i],
            };
        }
        out[n] = c;
        n += 1;
    }
    assert(n <= body.len);
    return gpa.realloc(out, n);
}

// ---- private ----

test "parseNumberLiteral: §2.6.1 shapes and every failure" {
    try std.testing.expectEqual(@as(u8, 16), parseNumberLiteral("8'hA5").int.radix);
    try std.testing.expectEqual(@as(u32, 8), parseNumberLiteral("8 'h A5").int.size);
    try std.testing.expect(parseNumberLiteral("4'sb1001").int.signed);
    try std.testing.expect(!parseNumberLiteral("4'b1001").int.signed);
    try std.testing.expect(parseNumberLiteral("1.5k") == .real);
    try std.testing.expect(parseNumberLiteral("2e3") == .real);
    try std.testing.expectEqual(Error.zero_size, parseNumberLiteral("0'h1").failure);
    try std.testing.expectEqual(Error.invalid_digit, parseNumberLiteral("08'h1").failure);
    try std.testing.expectEqual(Error.invalid_digit, parseNumberLiteral("'dxx").failure);
    try std.testing.expectEqual(Error.invalid_digit, parseNumberLiteral("8'h_1").failure);
    try std.testing.expectEqual(@as(?u64, 0xA5), intValue(parseNumberLiteral("8'hA5").int));
    try std.testing.expectEqual(@as(?u64, null), intValue(parseNumberLiteral("4'b1x01").int));
}

test "parseReal applies a scale factor once; strings decode Table 2-2" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(f64, 200e-6), try parseReal(&buf, "200u"));
    try std.testing.expectEqual(@as(f64, 236.123763e-12), try parseReal(&buf, "236.123_763_e-12"));
    try std.testing.expectEqual(@as(?usize, 2), badEscape("\"a\\400\""));
    try std.testing.expectEqual(@as(?usize, null), badEscape("\"a\\377\\n\""));
    const s = try stringContents(std.testing.allocator, "\"a\\tb\\101\\q\"");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("a\tbAq", s);
}
