//! `std_kernels` on every target a device compiles for: this root exports
//! the kernels a device body calls, so `zig build kernels-targets` builds
//! them (ReleaseFast, as a device is) for x86_64, aarch64, NVPTX and
//! AMDGCN. With `math_only` it exports the `f64` math alone, whose LLVM IR
//! the step holds to "no optional contraction" on each target: no
//! `llvm.fmuladd` and no `contract`/`fast` flag, which each target may fuse
//! or not. An explicit `@mulAdd` (`llvm.fma`) rounds once everywhere, at
//! comptime too, so it is allowed: the bits a fold computes are the bits
//! every target computes (lib/TODO.md §11.8). The family's derivative lanes
//! may fuse (the contract's numerics table makes FMA optional there), so the
//! full set is built, not grepped. `fma_control` is the probe's own canary:
//! an optimized-mode `a * b + c`, which the step requires the grep to find.
//! Cites: VAMS §4.3 (Tables 4-14, 4-15), §4.5, §4.5.15.
//!
//! Contents: none public; exported symbols only.

const std = @import("std");
const k = @import("std_kernels");
const contract = @import("contract");
const options = @import("kernels_targets_options");

const m = k.math;
const Ref = contract.RefFamily(f64, &[2]u8{ 0, 1 }, .{ .math = k.math });
const K = k.family.Family(2, ~@as(u64, 0)).zL(Ref, 3);

comptime {
    if (options.control) {
        @export(&fmaControl, .{ .name = "fma_control" });
    } else {
        for (.{ "exp", "log", "sin", "cos", "tan", "tanh", "sinh", "cosh", "expm1", "log1p", "atan", "log10", "asinh", "acosh", "atanh" }) |name|
            @export(&Unary(name).f, .{ .name = "k_" ++ name });
        @export(&kPow, .{ .name = "k_pow" });
        @export(&kAtan2, .{ .name = "k_atan2" });
        if (!options.math_only) {
            @export(&kPnjlim, .{ .name = "k_pnjlim" });
            @export(&kFetlim, .{ .name = "k_fetlim" });
            @export(&kTimerDue, .{ .name = "k_timer_due" });
            @export(&kTransFrac, .{ .name = "k_trans_frac" });
            @export(&kZiRamp, .{ .name = "k_zi_ramp" });
            @export(&kFamily, .{ .name = "k_family" });
        }
    }
}

// ---- private ----

fn Unary(comptime name: []const u8) type {
    return struct {
        fn f(x: f64) callconv(.c) f64 {
            return @field(m, name)(x);
        }
    };
}

fn kPow(x: f64, y: f64) callconv(.c) f64 {
    return m.pow(x, y);
}

fn kAtan2(y: f64, x: f64) callconv(.c) f64 {
    return m.atan2(y, x);
}

fn kPnjlim(vnew: f64, vold: f64, vt: f64, vcrit: f64) callconv(.c) f64 {
    return k.limit.zPnjlim(vnew, vold, vt, vcrit);
}

fn kFetlim(vnew: f64, vold: f64, vto: f64) callconv(.c) f64 {
    return k.limit.zFetlim(vnew, vold, vto);
}

fn kTimerDue(start: f64, period: f64, t: f64, os: f64, op: f64, pend: f64) callconv(.c) bool {
    return k.ops.zTimerDue(start, period, t, os, op, pend);
}

fn kTransFrac(target: f64, from: f64, t0: f64, t: f64, rise: f64, fall: f64) callconv(.c) f64 {
    return k.ops.zTransFrac(target, from, t0, t, rise, fall);
}

fn kZiRamp(from: f64, to: f64, ts: f64, tau: f64, t: f64) callconv(.c) f64 {
    return k.filter.zZiRamp(from, to, ts, tau, t);
}

/// The generic kernels at one family: the value and one lane of a chain
/// through pow, log10, atan2, hypot, asinh, slew and transition.
fn kFamily(x: f64, y: f64, d: f64) callconv(.c) f64 {
    const a: K = .{ .v = .{ .v = x, .d = .{ d, 0 } } };
    const b: K = .{ .v = .{ .v = y, .d = .{ 0, d } } };
    var r = m.zPow(K, a, b, true);
    r = r.add(m.zLog10(K, a)).add(m.zAtan2(K, a, b)).add(m.zHypot(K, a, b)).add(m.zAsinh(K, b));
    r = k.ops.zSlew(K, r, x, 1e-3, 1e3, 1e3);
    r = k.ops.zTransition(K, r, x, y, 0, d, 1e-3, 1e-6, 1e-6);
    return r.val() + r.ddxAt(0);
}

fn fmaControl(a: f64, b: f64, c: f64) callconv(.c) f64 {
    @setFloatMode(.optimized);
    return a * b + c;
}
