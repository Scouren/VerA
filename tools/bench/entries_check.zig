//! Prints a checksum of the wrapper's Jacobian entry table for one device, to compare two lib/ trees.
//! Run from a copy placed in each tree's lib/osdi_dyn/, built as eval_check.zig's header shows.
const std = @import("std");
const D = @import("device");
const tables = @import("tables.zig");
pub fn main() void {
    const T = tables.Tables(D);
    @setEvalBranchQuota(100_000_000);
    const h = comptime blk: {
        var x: u64 = 0xcbf29ce484222325;
        for (T.entries) |e| {
            x = (x ^ e.r) *% 0x100000001b3;
            x = (x ^ e.c) *% 0x100000001b3;
            x = (x ^ @intFromBool(e.resist)) *% 0x100000001b3;
            x = (x ^ @intFromBool(e.react)) *% 0x100000001b3;
        }
        break :blk x;
    };
    std.debug.print("unknowns {d} entries {d} resist {d} react {d} checksum {x}\n", .{ T.n, T.nj, T.n_resist, T.n_react, h });
}
