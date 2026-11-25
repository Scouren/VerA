//! The per-iterate stamps of the OSDI wrapper on one device, timed in process: what a transient
//! iterate calls (load_spice_rhs_tran, load_jacobian_tran) and what a DC iterate calls
//! (load_spice_rhs_dc, load_jacobian_resist). Prints nanoseconds per call set and a checksum.
//!
//! It reaches the wrapper's files directly, so it runs from a copy placed beside them:
//!   cp tools/bench/host_stamps.zig lib/osdi_dyn/ && zig build-exe -OReleaseFast -fllvm --dep contract --dep device \
//!     -Mroot=lib/osdi_dyn/host_stamps.zig --dep contract -Mdevice=$W/device.zig -Mcontract=lib/contract.zig
//! where $W is the work directory of a `vera --emit-osdi --work-dir $W` build. Remove the copy afterwards.
const std = @import("std");
const D = @import("device");
const blobs = @import("blobs.zig");
const load = @import("load.zig");
const tables = @import("tables.zig");

fn now() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn main() void {
    const T = tables.Tables(D);
    const I = blobs.Instance(D);
    const L = load.Load(D);
    const S = struct {
        var inst: I = undefined;
        var matrix: [T.nj]f64 = @splat(0);
        var rhs: [T.n + 1]f64 = @splat(0);
        var prev: [T.n + 1]f64 = @splat(0);
    };
    const inst = &S.inst;
    @memset(std.mem.asBytes(inst), 0);
    for (&inst.node_mapping, 0..) |*m, i| m.* = @intCast(i);
    for (&inst.jac_ptr, &inst.react_ptr, 0..) |*p, *r, k| {
        p.* = &S.matrix[k];
        r.* = &S.matrix[k];
    }
    var seed: u64 = 0x9E3779B97F4A7C15;
    const fill = struct {
        fn f(xs: []f64, s: *u64) void {
            for (xs) |*x| {
                s.* = s.* *% 6364136223846793005 +% 1442695040888963407;
                x.* = @as(f64, @floatFromInt(s.* >> 40)) / 16777216.0 - 0.5;
            }
        }
    }.f;
    fill(&inst.res, &seed);
    fill(&inst.q, &seed);
    fill(&inst.jac, &seed);
    fill(&inst.jac_q, &seed);
    fill(&inst.x, &seed);
    const reps: usize = if (T.nj > 2000) 20_000 else 400_000;
    var best: u64 = std.math.maxInt(u64);
    for (0..7) |_| {
        const t0 = now();
        for (0..reps) |r| {
            const alpha: f64 = 1.0e-3 + @as(f64, @floatFromInt(r & 7)) * 1.0e-6;
            L.loadSpiceRhsTran(inst, inst, &S.rhs, &S.prev, alpha);
            L.loadJacobianTran(inst, inst, alpha);
            L.loadSpiceRhsDc(inst, inst, &S.rhs, &S.prev);
            L.loadJacobianResist(inst, inst);
            std.mem.doNotOptimizeAway(&S.rhs);
            std.mem.doNotOptimizeAway(&S.matrix);
        }
        best = @min(best, now() - t0);
    }
    var h: u64 = 0;
    for (S.rhs) |v| h = (h ^ @as(u64, @bitCast(v))) *% 0x100000001b3;
    for (S.matrix) |v| h = (h ^ @as(u64, @bitCast(v))) *% 0x100000001b3;
    std.debug.print("unknowns {d}  entries {d}  ns_per_set {d:.1}  checksum {x}\n", .{ T.n, T.nj, @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(reps)), h });
}
