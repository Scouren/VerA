//! Prints, as Zig source, the descriptor's parameter records in compact form: one blob of C names,
//! where each record's name starts, and each record's flags. What VerA would emit itself.
//!
//! It reaches the wrapper's tables directly, so it runs from a copy placed in lib/osdi_dyn/ of a tree
//! at proto/host-tables or later, and prints to stderr:
//!   zig build-exe --dep contract --dep device -Mroot=lib/osdi_dyn/emit_params.zig --dep contract \
//!     -Mdevice=$W/device.zig -Mcontract=lib/contract.zig && ./emit_params 2>> $W/device.zig
//! A wrapper at proto/host-literals then reads the appended tables.
const std = @import("std");
const D = @import("device");
const abi = @import("abi.zig");
const tables = @import("tables.zig");

fn cName(comptime s: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var buf: [s.len]u8 = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            if (s[i] == 'Z' and i + 3 <= s.len) {
                buf[n] = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch unreachable;
                n += 1;
                i += 2;
            } else if (s[i] != 'Z') {
                buf[n] = s[i];
                n += 1;
            }
        }
        const done = buf[0..n].*;
        return &done;
    }
}

pub fn main() void {
    const T = tables.Tables(D);
    @setEvalBranchQuota(100_000_000);
    std.debug.print("\n/// The descriptor's parameter records as data: C names end to end, each record's start, its flags.\npub const osdi_param_names = \"", .{});
    var at: usize = 0;
    var starts: [T.num_params]u32 = undefined;
    var flags: [T.num_params]u32 = undefined;
    inline for (0..T.num_params) |i| {
        const nm: []const u8 = comptime if (i < T.ni) cName(T.params[T.inst_idx[i]].field) else if (T.has_mf and i == T.ni) "$mfactor" else cName(T.params[i - T.num_inst_params].field);
        const kind: T.Kind = comptime if (i < T.ni) T.params[T.inst_idx[i]].kind else if (T.has_mf and i == T.ni) .real else T.params[i - T.num_inst_params].kind;
        std.debug.print("{s}\\x00", .{nm});
        starts[i] = @intCast(at);
        at += nm.len + 1;
        flags[i] = @as(u32, @intFromEnum(kind)) | (if (i < T.num_inst_params) abi.para_kind_inst else 0);
    }
    std.debug.print("\";\npub const osdi_param_name_at = [_]u32{{", .{});
    for (starts, 0..) |s, i| std.debug.print("{s}{d},", .{ if (i % 24 == 0) "\n    " else " ", s });
    std.debug.print("\n}};\npub const osdi_param_flags = [_]u32{{", .{});
    for (flags, 0..) |f, i| std.debug.print("{s}{d},", .{ if (i % 24 == 0) "\n    " else " ", f });
    std.debug.print("\n}};\n", .{});
}
