//! A C-style format and its numeric arguments in, the text C prints out:
//! the renderer behind `formatSay` and `formatStatus`, the §9.4 display
//! tasks a device records and a host prints. A real conversion is
//! `str_real.zCReal`'s, the one the device prints through, so a host and a
//! device print one text (`tests/printf_reference.zig` holds both to C).
//! Cites: VAMS-2023 §9.4.3 Table 9-23 (the conversions, `%r`'s engineering
//! notation and the `%10.3g` example), §2.6.2 Table 2-1 (the scale letters),
//! §4.2.1.1 (a real rounds to an integer); C11 7.21.6.1 (flags, width,
//! precision, `%e %f %g`, `#`).
//!
//! Contents:
//! - `pub fn formatC(fmt: []const u8, args: []const f64, name: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void`

const std = @import("std");
const str_real = @import("str_real.zig");
const assert = std.debug.assert;
const Writer = std.Io.Writer;

/// The longest precision a conversion keeps; more is cut to it.
const precision_max = 64;
/// Bytes one real conversion renders into: the longest is a sign, 309
/// integer digits, the point and `precision_max` fraction digits of `%f`.
const buf_len = 512;

comptime {
    assert(1 + 309 + 1 + precision_max < buf_len);
}

/// A §9.4.3 conversion's flags, width and precision.
const Flags = struct {
    left: bool = false,
    plus: bool = false,
    space: bool = false,
    zero: bool = false,
    alt: bool = false,
    width: usize = 0,
    prec: ?usize = null,
};

/// One parsed conversion: its flags, its letter (null when `fmt` ends
/// before one), and the index of that letter.
const Spec = struct { flags: Flags, conv: ?u8, end: usize };

const Class = enum { percent, name, string, integer, real, unknown };

/// Whether a padded field may be zero-filled after its sign.
const Fill = enum { number, text };

/// Renders `fmt` C-style (C11 7.21.6.1, which §9.4.3 Table 9-23 grants the
/// real conversions) over `args`, each conversion taking the next value, 0
/// past the end. Integer conversions round the value (§4.2.1.1); `%h`, `%x`,
/// `%o` and `%b` print its 64-bit two's complement, `%c` its low byte, `%r`
/// is §2.6.2 engineering notation (a mantissa in [1, 1000) and one scale
/// letter, the mantissa's shortest digits, or a precision's fractional
/// digits, as the device's display kernels print it), a `%g` precision
/// counts fractional digits (§9.4.3's `%10.3g` example, as the device
/// prints it: `%.3g` is `%.3f`), `%t` is `%g`, `%s` writes `?`, and
/// `%m`/`%l` write `name`. Precision past 64 is cut to 64. A conversion VerA
/// does not know is written as is and still takes its value.
/// A `%` that ends `fmt` is written as is; one cut off after its flags,
/// width or precision writes nothing.
pub fn formatC(fmt: []const u8, args: []const f64, name: []const u8, w: *Writer) Writer.Error!void {
    var next: usize = 0;
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        if (fmt[i] != '%' or i + 1 == fmt.len) {
            try w.writeByte(fmt[i]);
            continue;
        }
        const spec = parseSpec(fmt, i + 1);
        i = spec.end;
        const conv = spec.conv orelse break;
        assert(i < fmt.len);
        switch (classOf(conv)) {
            .percent => try w.writeByte('%'),
            .name => try writePadded(w, "", name, spec.flags, .text),
            .string => try writePadded(w, "", "?", spec.flags, .text),
            .integer, .real, .unknown => |class| {
                const v: f64 = if (next < args.len) args[next] else 0.0;
                next += 1;
                switch (class) {
                    .integer => try writeInteger(w, conv, v, spec.flags),
                    .real => try writeReal(w, conv, v, spec.flags),
                    .unknown => {
                        try w.writeByte('%');
                        try w.writeByte(conv);
                    },
                    .percent, .name, .string => unreachable,
                }
            },
        }
    }
    assert(i >= fmt.len);
}

// ---- private ----

/// Parses the flags, width and precision starting at `start`, the byte
/// after a `%`. Asserts that `start` is inside `fmt`.
fn parseSpec(fmt: []const u8, start: usize) Spec {
    assert(start < fmt.len);
    var f: Flags = .{};
    var i = start;
    while (i < fmt.len) : (i += 1) switch (fmt[i]) {
        '-' => f.left = true,
        '+' => f.plus = true,
        ' ' => f.space = true,
        '0' => f.zero = true,
        '#' => f.alt = true,
        else => break,
    };
    while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) f.width = f.width *| 10 +| (fmt[i] - '0');
    if (i < fmt.len and fmt[i] == '.') {
        i += 1;
        var p: usize = 0;
        while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) p = p *| 10 +| (fmt[i] - '0');
        f.prec = @min(p, precision_max);
    }
    assert(i <= fmt.len);
    return .{ .flags = f, .conv = if (i < fmt.len) fmt[i] else null, .end = i };
}

fn classOf(conv: u8) Class {
    return switch (conv) {
        '%' => .percent,
        'm', 'M', 'l', 'L' => .name,
        's', 'S' => .string,
        'd', 'D', 'i', 'h', 'H', 'x', 'X', 'o', 'O', 'b', 'B', 'c', 'C' => .integer,
        'e', 'E', 'f', 'F', 'g', 'G', 'r', 'R', 't', 'T' => .real,
        else => .unknown,
    };
}

/// `v` rounded to an i64 (NaN as 0, clamped into range), in conversion
/// `conv`: signed decimal, or the 64-bit two's complement in hex, octal or
/// binary, or its low byte.
fn writeInteger(w: *Writer, conv: u8, v: f64, f: Flags) Writer.Error!void {
    assert(classOf(conv) == .integer);
    // 2^63 - 1024 is the largest double below 2^63.
    const n: i64 = if (std.math.isNan(v)) 0 else @intFromFloat(@round(std.math.clamp(v, -0x1p63, 0x1p63 - 1024)));
    const u: u64 = @bitCast(n);
    // SAFETY: `print` writes the digits it returns; nothing else is read.
    var buf: [64]u8 = undefined;
    // 64 bytes hold the longest of these: a u64 in binary.
    const digits = switch (conv) {
        'd', 'D', 'i' => std.mem.print(&buf, "{d}", .{@abs(n)}),
        'h', 'x' => std.mem.print(&buf, "{x}", .{u}),
        'H', 'X' => std.mem.print(&buf, "{X}", .{u}),
        'o', 'O' => std.mem.print(&buf, "{o}", .{u}),
        'b', 'B' => std.mem.print(&buf, "{b}", .{u}),
        else => std.mem.print(&buf, "{c}", .{@as(u8, @truncate(u))}),
    } catch unreachable;
    assert(digits.len > 0);
    const signed = conv == 'd' or conv == 'D' or conv == 'i';
    try writePadded(w, if (signed) signOf(n < 0, f) else "", digits, f, .number);
}

/// `v` in real conversion `conv` (`%t` is `%g`): `str_real.zCReal`'s
/// sign and body, in the field `writePadded` lays out, which zero-fills
/// only a finite value (C: the '0' flag is ignored for inf and nan).
fn writeReal(w: *Writer, conv: u8, v: f64, f: Flags) Writer.Error!void {
    assert(classOf(conv) == .real);
    const c: u8 = switch (conv) {
        't' => 'g',
        'T' => 'G',
        else => conv,
    };
    const flags: u8 = (if (f.plus) str_real.zc_plus else 0) |
        (if (f.space) str_real.zc_space else 0) |
        (if (f.alt) str_real.zc_alt else 0);
    const prec: i64 = if (f.prec) |p| @intCast(p) else -1;
    // SAFETY: `zCReal` returns only bytes it wrote.
    var buf: [buf_len]u8 = undefined;
    const text = str_real.zCReal(&buf, v, c, flags, 0, prec);
    assert(text.len < buf.len);
    const signed = text.len != 0 and (text[0] == '-' or text[0] == '+' or text[0] == ' ');
    const sign = if (signed) text[0..1] else "";
    try writePadded(w, sign, text[sign.len..], f, if (std.math.isFinite(v)) .number else .text);
}

fn signOf(neg: bool, f: Flags) []const u8 {
    return if (neg) "-" else if (f.plus) "+" else if (f.space) " " else "";
}

/// Writes `sign` and `body` in a field `f.width` wide: left-justified,
/// zero-filled after the sign (numbers only), or right-justified.
fn writePadded(w: *Writer, sign: []const u8, body: []const u8, f: Flags, fill_kind: Fill) Writer.Error!void {
    assert(sign.len <= 1);
    const n = sign.len + body.len;
    const fill = f.width -| n;
    if (f.left) {
        try w.writeAll(sign);
        try w.writeAll(body);
        try w.splatByteAll(' ', fill);
    } else if (f.zero and fill_kind == .number) {
        try w.writeAll(sign);
        try w.splatByteAll('0', fill);
        try w.writeAll(body);
    } else {
        try w.splatByteAll(' ', fill);
        try w.writeAll(sign);
        try w.writeAll(body);
    }
}

test "formatC: §9.4.3's conversions as C11 7.21.6.1 prints them" {
    const cases = [_]struct { fmt: []const u8, v: f64, want: []const u8 }{
        .{ .fmt = "%g", .v = 0.1, .want = "0.1" },
        .{ .fmt = "%g", .v = 1e-9, .want = "1e-09" },
        .{ .fmt = "%g", .v = 123456789, .want = "1.23457e+08" },
        .{ .fmt = "%g", .v = 100000, .want = "100000" },
        .{ .fmt = "%G", .v = 2.5e-5, .want = "2.5E-05" },
        .{ .fmt = "%.3e", .v = 1234.56, .want = "1.235e+03" },
        .{ .fmt = "%e", .v = 0, .want = "0.000000e+00" },
        .{ .fmt = "%8.2f|", .v = -3.14159, .want = "   -3.14|" },
        .{ .fmt = "%-6d|", .v = 42, .want = "42    |" },
        .{ .fmt = "%05d", .v = -42, .want = "-0042" },
        .{ .fmt = "%+d", .v = 7, .want = "+7" },
        .{ .fmt = "%d", .v = 2.5, .want = "3" },
        .{ .fmt = "%h", .v = -1, .want = "ffffffffffffffff" },
        .{ .fmt = "%o %%", .v = 8, .want = "10 %" },
        .{ .fmt = "%b", .v = 5, .want = "101" },
        .{ .fmt = "%c", .v = 65, .want = "A" },
        .{ .fmt = "%r", .v = 4.7e-9, .want = "4.7n" },
        .{ .fmt = "%r", .v = 2200, .want = "2.2K" }, // Table 2-1 has K and k; the device prints K
        .{ .fmt = "%g", .v = std.math.inf(f64), .want = "inf" },
        .{ .fmt = "%m: %g", .v = 1, .want = "top.x1: 1" },
    };
    for (cases) |c| {
        var buf: [128]u8 = undefined;
        var w: Writer = .fixed(&buf);
        try formatC(c.fmt, &.{c.v}, "top.x1", &w);
        std.testing.expectEqualStrings(c.want, w.buffered()) catch |e| {
            std.debug.print("format \"{s}\" of {d}\n", .{ c.fmt, c.v });
            return e;
        };
    }
}

test "formatC: the C11 7.21.6.1 corners a model's format can reach" {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    const zeros64: [64]u8 = @splat('0');
    const cases = [_]struct { fmt: []const u8, args: []const f64, want: []const u8 }{
        .{ .fmt = "%", .args = &.{}, .want = "%" }, // a `%` that ends the format
        .{ .fmt = "50%", .args = &.{}, .want = "50%" },
        .{ .fmt = "%5", .args = &.{}, .want = "" }, // cut off after its width
        .{ .fmt = "a%q", .args = &.{}, .want = "a%q" }, // no such conversion: as written
        .{ .fmt = "%q%d", .args = &.{ 1, 2 }, .want = "%q2" }, // ...and it took its value
        .{ .fmt = "%d %d", .args = &.{7}, .want = "7 0" }, // past the arguments: 0
        .{ .fmt = "%d", .args = &.{nan}, .want = "0" },
        // Clamped into i64: 2^63 - 1024 is the largest double below 2^63.
        .{ .fmt = "%d", .args = &.{1e300}, .want = "9223372036854774784" },
        .{ .fmt = "%d", .args = &.{-1e300}, .want = "-9223372036854775808" },
        .{ .fmt = "%x", .args = &.{-2}, .want = "fffffffffffffffe" },
        .{ .fmt = "%X", .args = &.{255}, .want = "FF" },
        .{ .fmt = "%c", .args = &.{321}, .want = "A" }, // 321 & 0xff = 65
        .{ .fmt = "%f", .args = &.{-0.0}, .want = "-0.000000" },
        .{ .fmt = "%g", .args = &.{0}, .want = "0" },
        .{ .fmt = "%g", .args = &.{0.0001}, .want = "0.0001" }, // X = -4: still %f
        .{ .fmt = "%g", .args = &.{0.00001}, .want = "1e-05" }, // X = -5: %e
        .{ .fmt = "%#g", .args = &.{1}, .want = "1.00000" }, // `#` keeps the zeros
        .{ .fmt = "%#g", .args = &.{100000}, .want = "100000." }, // ...and the point
        .{ .fmt = "%#.0f", .args = &.{3}, .want = "3." },
        .{ .fmt = "%#5.0f|", .args = &.{-7}, .want = "  -7.|" },
        .{ .fmt = "%#.0e", .args = &.{12345}, .want = "1.e+04" },
        .{ .fmt = "%#.2f", .args = &.{1.5}, .want = "1.50" }, // a point already: unchanged
        .{ .fmt = "%e", .args = &.{-1.5}, .want = "-1.500000e+00" },
        .{ .fmt = "%.0e", .args = &.{12345}, .want = "1e+04" },
        .{ .fmt = "%+g", .args = &.{inf}, .want = "+inf" },
        .{ .fmt = "%G", .args = &.{nan}, .want = "NAN" },
        .{ .fmt = "% g", .args = &.{-inf}, .want = "-inf" },
        .{ .fmt = "%5g|", .args = &.{nan}, .want = "  nan|" },
        .{ .fmt = "%-5s|", .args = &.{}, .want = "?    |" },
        .{ .fmt = "%3m|", .args = &.{}, .want = "  x|" },
        .{ .fmt = "%l", .args = &.{}, .want = "x" },
        // `%%` takes no width: VerA refuses `%5%` (E0826), so no device
        // records one; a host handed it anyway prints the one `%`.
        .{ .fmt = "%5%", .args = &.{}, .want = "%" },
        .{ .fmt = "%t", .args = &.{0.5}, .want = "0.5" },
        .{ .fmt = "%05.1f", .args = &.{-2.3}, .want = "-02.3" }, // zeros after the sign
        .{ .fmt = "%-+4d|", .args = &.{5}, .want = "+5  |" },
        .{ .fmt = "%.100f", .args = &.{1}, .want = "1." ++ &zeros64 }, // precision cut to 64
        // C11 prints every digit a `%e` precision asks for: at the cap, 64
        // fraction digits and the exponent (this printed `?` before the
        // exponent's scratch held the cap's mantissa).
        .{ .fmt = "%.64e", .args = &.{1}, .want = "1." ++ &zeros64 ++ "e+00" },
        .{ .fmt = "%.64E", .args = &.{0.5}, .want = "5." ++ &zeros64 ++ "E-01" },
    };
    for (cases) |c| {
        var buf: [256]u8 = undefined;
        var w: Writer = .fixed(&buf);
        try formatC(c.fmt, c.args, "x", &w);
        std.testing.expectEqualStrings(c.want, w.buffered()) catch |e| {
            std.debug.print("format \"{s}\"\n", .{c.fmt});
            return e;
        };
    }
}

test "formatC %r: §2.6.2 engineering notation, as the display kernels print it" {
    // The mantissa is in [1, 1000) and the scale letter picks the exponent,
    // a multiple of three (`str_real.zCReal`). Without a precision the
    // mantissa is the value's shortest digits; with one, that many fractional
    // digits, ties to even.
    const cases = [_]struct { fmt: []const u8, v: f64, want: []const u8 }{
        .{ .fmt = "%r", .v = 4.7e-9, .want = "4.7n" },
        .{ .fmt = "%r", .v = 2200, .want = "2.2K" }, // Table 2-1 has K and k; the device prints K
        .{ .fmt = "%r", .v = 1234567, .want = "1.234567M" }, // every digit, not %g's six
        .{ .fmt = "%r", .v = 999.9999999, .want = "999.9999999" }, // not rounded up to 1000
        .{ .fmt = "%r", .v = 0.999, .want = "999m" },
        .{ .fmt = "%r", .v = -0.5, .want = "-500m" },
        .{ .fmt = "%R", .v = 2.2e6, .want = "2.2M" }, // the letter keeps its case
        .{ .fmt = "%r", .v = 0, .want = "0" },
        .{ .fmt = "%.3r", .v = 0, .want = "0.000" },
        // Past the table the mantissa absorbs the rest: T is the largest
        // letter, a the smallest.
        .{ .fmt = "%r", .v = 1e15, .want = "1000T" },
        .{ .fmt = "%r", .v = 1.5e-20, .want = "0.015a" },
        // A precision is the mantissa's fractional digits, never %g's
        // significant ones (which printed `1.2e+02k` here).
        .{ .fmt = "%.2r", .v = 123456, .want = "123.46K" },
        .{ .fmt = "%.1r", .v = 4.75e-9, .want = "4.8n" }, // 4.75: a tie, to even
        .{ .fmt = "%.1r", .v = 4.25e-9, .want = "4.2n" },
        .{ .fmt = "%.2r", .v = 999.996, .want = "1.00K" }, // the carry takes the next letter, as the device prints it
        .{ .fmt = "%8.1r|", .v = 1500, .want = "    1.5K|" },
    };
    for (cases) |c| {
        var buf: [128]u8 = undefined;
        var w: Writer = .fixed(&buf);
        try formatC(c.fmt, &.{c.v}, "", &w);
        std.testing.expectEqualStrings(c.want, w.buffered()) catch |e| {
            std.debug.print("format \"{s}\" of {e}\n", .{ c.fmt, c.v });
            return e;
        };
    }
}
