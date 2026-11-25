//! Times the device's evalQ on the sparse reference family in process and prints a checksum of
//! every residual, charge and Jacobian entry: evalQ where the device has charges, eval otherwise.
//! It reaches the wrapper's tables directly, so it runs from a copy placed beside them:
//!   cp tools/bench/eval_check.zig lib/osdi_dyn/ && zig build-exe -OReleaseFast -fllvm --dep contract --dep device \
//!     -Mroot=lib/osdi_dyn/eval_check.zig --dep contract -Mdevice=$W/device.zig -Mcontract=lib/contract.zig
//! Remove the copy afterwards.
const std = @import("std");
const contract = @import("contract");
const D = @import("device");
const tables = @import("tables.zig");

fn now() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

const has_q = @hasDecl(D, "evalQ");

pub fn main() void {
    const T = tables.Tables(D);
    var model: D.Model = .{};
    D.setup(T.Val, &model);
    var inst: D.Instance = .{};
    var x: [T.n]f64 = undefined;
    for (&x, 0..) |*v, i| v.* = 0.3 + 0.17 * @as(f64, @floatFromInt(i % 5));
    var sim: contract.SimState = undefined;
    @memset(std.mem.asBytes(&sim), 0);
    var h: u64 = 0xcbf29ce484222325;
    const reps: usize = 20_000;
    var best: u64 = std.math.maxInt(u64);
    for (0..7) |_| {
        const t0 = now();
        for (0..reps) |r| {
            x[0] = 0.3 + 1.0e-6 * @as(f64, @floatFromInt(r & 15));
            if (comptime has_q) {
                const out = D.evalQ(T.Dual, &x, &model, &inst, sim);
                std.mem.doNotOptimizeAway(&out);
            } else {
                const out = D.eval(T.Dual, &x, &model, &inst, sim);
                std.mem.doNotOptimizeAway(&out);
            }
        }
        best = @min(best, now() - t0);
    }
    x[0] = 0.3;
    @setEvalBranchQuota(100_000_000);
    if (comptime has_q) {
        const out = D.evalQ(T.Dual, &x, &model, &inst, sim);
        const qr = contract.qRows(D, T.Dual, out.q);
        inline for (0..T.n) |i| {
            h = (h ^ @as(u64, @bitCast(out.res[i].val()))) *% 0x100000001b3;
            h = (h ^ @as(u64, @bitCast(qr[i].val()))) *% 0x100000001b3;
        }
        inline for (T.entries) |e| {
            h = (h ^ @as(u64, @bitCast(out.res[e.r].ddxAt(e.c)))) *% 0x100000001b3;
            h = (h ^ @as(u64, @bitCast(qr[e.r].ddxAt(e.c)))) *% 0x100000001b3;
        }
    } else {
        const rows = D.eval(T.Dual, &x, &model, &inst, sim);
        inline for (0..T.n) |i| h = (h ^ @as(u64, @bitCast(rows[i].val()))) *% 0x100000001b3;
        inline for (T.entries) |e| h = (h ^ @as(u64, @bitCast(rows[e.r].ddxAt(e.c)))) *% 0x100000001b3;
    }
    std.debug.print("unknowns {d}  ns_per_eval {d:.1}  checksum {x}\n", .{ T.n, @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(reps)), h });
}
