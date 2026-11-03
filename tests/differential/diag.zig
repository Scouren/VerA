//! The differential oracle of the vams `Diag` (`zig build diff-diag`,
//! docs/rewrite/diag.md). The oracle is lib/diag, the product until the
//! rewrite replaces it.
//!
//! - The catalogue: every old `Code` exists in the new one under the same
//!   name and tag number, with the same title, LRM clause and explain text,
//!   and the two have the same codes.
//!
//! Cites no LRM clause: the catalogue rows cite their own.
//!
//! Contents: tests only.

const std = @import("std");
const vams = @import("vams");
const diag = @import("diag");
const Diag = vams.Diag;

test "diff-diag: the catalogue is lib/diag's, row for row" {
    const old_names = @typeInfo(diag.Code).@"enum".field_names;
    const new_names = @typeInfo(Diag.Code).@"enum".field_names;
    var bad: usize = 0;
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
    }
    std.debug.print("diff-diag: catalogue: {d} codes compared ({d} new), {d} differ\n", .{ old_names.len, new_names.len, bad });
    try std.testing.expectEqual(old_names.len, new_names.len);
    try std.testing.expectEqual(@as(usize, 0), bad);
}
