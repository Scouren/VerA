//! A Verilog-A name as a Zig identifier, injectively: the spelling the
//! device ABI fixes for `Model` fields and `U` members, so a host that sets
//! `model.word` or reads `D.U.p` reads the same name from every VerA
//! (the old `src/ir/names.zig` `sanitize`, kept byte for byte). Every byte
//! outside `[A-Za-z0-9_]`, a leading digit, a leading, trailing or doubled
//! `_`, and `Z` itself become `Z` + two hex digits; a Zig keyword or
//! primitive gains a trailing `Z`.
//! Cites: VAMS-2023 §2.8, §2.8.1 (escaped identifiers carry any printable byte).
//!
//! Contents:
//! - field `name`
//! - `pub fn format(id: Ident, w: *std.Io.Writer) std.Io.Writer.Error!void`

const std = @import("std");
const assert = std.debug.assert;

/// The source spelling.
name: []const u8,

const Ident = @This();

/// Writes the sanitized identifier.
pub fn format(id: Ident, w: *std.Io.Writer) std.Io.Writer.Error!void {
    assert(id.name.len != 0);
    var plain = true;
    for (id.name, 0..) |c, i| {
        const bare = switch (c) {
            'a'...'z', 'A'...'Y' => true,
            '0'...'9' => i != 0,
            '_' => i != 0 and i + 1 < id.name.len and id.name[i + 1] != '_',
            else => false, // else: `Z` is the escape marker, every other byte escapes
        };
        if (bare) {
            try w.writeByte(c);
        } else {
            plain = false;
            try w.writeAll(&.{ 'Z', "0123456789abcdef"[c >> 4], "0123456789abcdef"[c & 0xf] });
        }
    }
    if (plain and (std.zig.Token.keywords.has(id.name) or std.zig.primitives.isPrimitive(id.name))) try w.writeByte('Z');
}

test "Ident: the old ABI spelling, one name to one identifier" {
    // Oracle: the old `sanitize`'s documented cases and the old devices'
    // Model fields (pattern_every_element_written.va: `aZ5b0Z5d`).
    var buf: [64]u8 = undefined;
    const cases = [_][2][]const u8{
        .{ "v_ds", "v_ds" }, .{ "a[0]", "aZ5b0Z5d" }, .{ "Z", "Z5a" },   .{ "_x", "Z5fx" },
        .{ "x_", "xZ5f" },   .{ "a__b", "aZ5f_b" },   .{ "1n", "Z31n" }, .{ "pub", "pubZ" },
        .{ "u32", "u32Z" },  .{ "is", "is" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c[1], try std.fmt.bufPrint(&buf, "{f}", .{Ident{ .name = c[0] }}));
}
