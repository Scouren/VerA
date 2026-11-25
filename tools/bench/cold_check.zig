//! Runs the device's checkRange and setup on its default card and on cards with one parameter
//! pushed out of range, and prints a checksum of every setup slot and of the names returned.
//! Build it against the emitted device before and after tools/bench/tabulate_cold.py: equal output means
//! the tables give the same slots and refuse the same parameters.
//!   zig build-exe -OReleaseFast --dep contract --dep device -Mroot=tools/bench/cold_check.zig \
//!     --dep contract -Mdevice=$W/device.zig -Mcontract=lib/contract.zig
const std = @import("std");
const D = @import("device");

pub fn main() void {
    var h: u64 = 0xcbf29ce484222325;
    var model: D.Model = .{};
    D.setup(f64Val, &model);
    for (model.su.r) |v| h = (h ^ @as(u64, @bitCast(v))) *% 0x100000001b3;
    var bad: usize = 0;
    @setEvalBranchQuota(1_000_000);
    const info = @typeInfo(D.Model).@"struct";
    inline for (info.field_names, info.field_types, 0..) |name_of, T, k| {
        if (T == f64 and k % 37 == 5) {
            var m: D.Model = .{};
            @field(m, name_of) = -1.0;
            if (D.checkRange(&m)) |name| {
                for (name) |c| h = (h ^ c) *% 0x100000001b3;
                bad += 1;
            }
            @field(m, name_of) = std.math.nan(f64);
            if (D.checkRange(&m)) |name| {
                for (name) |c| h = (h ^ c) *% 0x100000001b3;
                bad += 1;
            }
        }
    }
    const ok = D.checkRange(&model) == null;
    std.debug.print("slots {d}  default_in_range {}  refusals {d}  checksum {x}\n", .{ model.su.r.len, ok, bad, h });
}

/// The scalar value family setup runs on: a bare f64.
const f64Val = struct {
    v: f64,
    pub fn con(c: f64) @This() {
        return .{ .v = c };
    }
    pub fn val(a: @This()) f64 {
        return a.v;
    }
};
