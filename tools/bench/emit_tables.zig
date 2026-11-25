//! Prints, as Zig source, the two tables the wrapper derives for a device at compile time: the
//! Jacobian entries and the parameter list. Appended to the emitted device, they let the wrapper
//! read literals instead of deriving them (what VerA would emit itself).
//!
//! It reaches the wrapper's tables directly, so it runs from a copy placed in lib/osdi_dyn/ of a tree
//! at proto/host-tables or later, and prints to stderr:
//!   zig build-exe --dep contract --dep device -Mroot=lib/osdi_dyn/emit_tables.zig --dep contract \
//!     -Mdevice=$W/device.zig -Mcontract=lib/contract.zig && ./emit_tables 2>> $W/device.zig
//! A wrapper at proto/host-literals then reads the appended tables.
const std = @import("std");
const D = @import("device");
const tables = @import("tables.zig");
pub fn main() void {
    const T = tables.Tables(D);
    @setEvalBranchQuota(100_000_000);
    std.debug.print("\n/// The wrapper's Jacobian entry table as data: row, column, flags (1 resistive, 2 reactive).\npub const osdi_entries = [_][3]u16{{\n", .{});
    for (T.entries) |e| std.debug.print("    .{{ {d}, {d}, {d} }},\n", .{ e.r, e.c, @as(u16, @intFromBool(e.resist)) | (@as(u16, @intFromBool(e.react)) << 1) });
    std.debug.print("}};\n/// The wrapper's parameter list as data: Model field and kind (0 real, 1 integer, 2 string).\npub const osdi_param_fields = [_][]const u8{{\n", .{});
    for (T.params) |p| std.debug.print("    \"{s}\",\n", .{p.field});
    std.debug.print("}};\npub const osdi_param_kinds = [_]u8{{", .{});
    for (T.params, 0..) |p, i| std.debug.print("{s}{d},", .{ if (i % 40 == 0) "\n    " else " ", @intFromEnum(p.kind) });
    std.debug.print("\n}};\n", .{});
}
