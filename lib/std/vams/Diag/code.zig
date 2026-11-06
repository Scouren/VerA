//! The diagnostic catalogue: `codes.zon` in, the `Code` enum and one `Info`
//! row per code out, both built at comptime. `Code` is reified from the
//! ZON keys in file order, so the catalogue is the only list of codes; a
//! duplicate key fails the ZON parse and a malformed row (a missing field, a
//! bad spelling, a titled-retired row with a clause) fails the build here.
//!
//! Cites no LRM clause: each row cites its own in `Info.lrm`.
//!
//! Contents:
//! - `pub const Code = enum(u16)`, reified from `codes.zon`'s keys
//! - `pub const Info = struct { title, lrm, explain: []const u8 }`, `annexPrefix`
//! - `pub fn info(c: Code) Info`

const std = @import("std");
const assert = std.debug.assert;
const catalogue = @import("codes.zon");

/// Every diagnosable condition, in `codes.zon` order (`E0101` is 0). The
/// tag name is the rendered spelling: one letter, then four digits. The
/// letter is the severity (`E` error, `W` warning) and the first two digits
/// the owning stage class. A code is never renumbered or reused; a retired
/// one keeps its row (`Info.title` is "(retired)"). The tag order is the
/// last key of the source sort, so a new code goes at the end of its run.
pub const Code = @Enum(u16, .exhaustive, &names, &std.simd.iota(u16, names.len));

/// Static documentation for one code; every field is a comptime string.
pub const Info = struct {
    /// Headline after `error[E0313]: `: a lowercase noun phrase with no
    /// trailing period; "(retired)" for a retired code.
    title: []const u8,
    /// LRM clause (`"5.6.1"`, `"A.6.4"`), printed under every diagnostic;
    /// empty for an engine limit or a retired code.
    lrm: []const u8,
    /// The `--explain` long form, pre-wrapped at 76 columns, printed verbatim.
    explain: []const u8,

    /// Returns `"annex "` when `lrm` names an annex (a letter A to H) and
    /// `""` otherwise, so `LRM annex C` never reads as a typo.
    pub fn annexPrefix(self: Info) []const u8 {
        if (self.lrm.len == 0) return "";
        return if (self.lrm[0] >= 'A' and self.lrm[0] <= 'H') "annex " else "";
    }

    comptime {
        assert(@sizeOf(Info) <= 48); // Three slices, one row per code.
    }
};

/// The ZON keys, in file order: `Code`'s fields.
const names: [field_names.len][]const u8 = blk: {
    var out: [field_names.len][]const u8 = undefined;
    for (&out, field_names) |*o, n| o.* = n;
    break :blk out;
};
const field_names = @typeInfo(@TypeOf(catalogue)).@"struct".field_names;

const table: std.enums.EnumArray(Code, Info) = blk: {
    @setEvalBranchQuota(200 * names.len);
    var t: std.enums.EnumArray(Code, Info) = undefined;
    for (names) |n| {
        const r = @field(catalogue, n);
        const row: Info = .{ .title = r.title, .lrm = r.lrm, .explain = r.explain };
        checkRow(n, row);
        t.set(@field(Code, n), row);
    }
    break :blk t;
};

/// Returns the documentation for `c` with one indexed load.
pub fn info(c: Code) Info {
    return table.get(c);
}

// ---- private ----

/// Fails the build on a row the renderer would print wrong.
fn checkRow(comptime n: []const u8, comptime row: Info) void {
    if (n.len != 5 or (n[0] != 'E' and n[0] != 'W')) @compileError(n ++ ": a code is E or W and four digits");
    for (n[1..]) |ch| if (!std.ascii.isDigit(ch)) @compileError(n ++ ": a code is E or W and four digits");
    if (row.title.len == 0 or row.title[row.title.len - 1] == '.') @compileError(n ++ ": a title is non-empty with no trailing period");
    if (row.explain.len == 0) @compileError(n ++ ": no explain text");
    if (std.mem.eql(u8, row.title, "(retired)") and row.lrm.len != 0) @compileError(n ++ ": a retired code cites no clause");
}

test "a code's spelling is a letter and four digits, in catalogue order" {
    try std.testing.expectEqual(@as(u16, 0), @backingInt(Code.E0101));
    try std.testing.expectEqualStrings("E0101", @tagName(@as(Code, @fromBackingInt(0))));
    try std.testing.expect(names.len > 500);
}
