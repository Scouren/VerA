//! The scalar-family helpers: a host's family `S` and a device's unknown
//! count and `deriv_reads` in, the types and conversions every body and
//! kernel reaches the family through out. A real is typed `zOf(S, m)`, `m`
//! the unknowns it may depend on, narrowed by the device's `deriv_reads`
//! so no mask names a lane the host did not ask for. Masks are
//! `contract.MaskOf(n_u)`: `u64` up to 64 unknowns, one bit per unknown
//! past them (what the old text widening, `prelude.wideText`, spelled).
//! `Device(D)` is the half that reads a device's own decls (its rows, its
//! probes).
//! Cites: VAMS §4.3.1 (min, max and abs as conditionals); the contract's
//! family (`lib/contract/family.zig`, `family_fns`).
//!
//! Contents:
//! - `pub fn Family(comptime n_u: u16, comptime deriv_reads: contract.MaskOf(n_u)) type`
//!   (`Mask`, `zdr`, `zOf`, `zTo`, `zV`, `zAbs`, `zL`, `zPowL`, `zLw`, `zLu`); `zL(S, m)` carries
//!   `con`, `val`, `ddxAt`, `add`, `sub`, `mul`, `div`, `neg`, `scale`, `addC`, `exp`, `log`,
//!   `expm1`, `log1p`, `sqrt`, `sin`, `cos`, `tanh`, `sinh`, `cosh`, `atan`, `pow`, `lt`, `le`,
//!   `eq`, `sel`, `min`, `max`, `abs`, `minC`, `maxC`
//! - `pub fn Device(comptime D: type) type` (`F`, `zRow`, `zRowsZero`, `zX`, `zProbe`, `zVals`)

const std = @import("std");
const assert = std.debug.assert;
const contract = @import("contract");
const math = @import("math.zig");

/// The family helpers of a device with `n_u` unknowns that reads the
/// derivative lanes `deriv_reads` (`contract.derivReads`).
pub fn Family(comptime n_u: u16, comptime deriv_reads: contract.MaskOf(n_u)) type {
    // `n_u == 0` is §6.2's module with no ports or nets: every row empty.
    comptime assert(@bitSizeOf(contract.MaskOf(n_u)) >= n_u);
    return struct {
        /// One bit per unknown.
        pub const Mask = contract.MaskOf(n_u);
        /// The lanes the host carries: every mask is narrowed by it.
        pub const zdr: Mask = deriv_reads;

        /// The family value that may depend on the unknowns `m` reads.
        pub fn zOf(comptime S: type, comptime m: Mask) type {
            @setEvalBranchQuota(1_000_000);
            return S.Of(m & zdr);
        }
        /// `a` widened to `zOf(S, m)`: a compile error when `a` carries a
        /// lane `m` does not name.
        pub fn zTo(comptime S: type, comptime m: Mask, a: anytype) zOf(S, m) {
            return a.to(m & zdr);
        }
        /// The value of `a`, lanes dropped.
        pub fn zV(a: anytype) f64 {
            return a.val();
        }
        /// §4.3.1 "abs(x) is equivalent to (x > 0) x : -x": a family carries
        /// no `abs`, so the conditional is spelled here.
        pub fn zAbs(comptime S: type, a: anytype) @TypeOf(a) {
            return S.sel(S.con(0.0).lt(a), a, a.neg());
        }
        /// `zOf(S, m)` as one scalar type, for kernels written against one:
        /// every operation runs at mask `m`. min, max, abs and the slew
        /// clamps are §4.3.1's conditionals.
        pub fn zL(comptime S: type, comptime m: Mask) type {
            return struct {
                v: zOf(S, m),
                const T = @This();
                fn w(a: anytype) T {
                    return .{ .v = zTo(S, m, a) };
                }
                pub fn con(c: f64) T {
                    return w(S.con(c));
                }
                pub fn val(a: T) f64 {
                    return a.v.val();
                }
                pub fn ddxAt(a: T, comptime u: usize) f64 {
                    return a.v.ddxAt(u);
                }
                pub fn add(a: T, b: T) T {
                    return .{ .v = a.v.add(b.v) };
                }
                pub fn sub(a: T, b: T) T {
                    return .{ .v = a.v.sub(b.v) };
                }
                pub fn mul(a: T, b: T) T {
                    return .{ .v = a.v.mul(b.v) };
                }
                pub fn div(a: T, b: T) T {
                    return .{ .v = a.v.div(b.v) };
                }
                pub fn neg(a: T) T {
                    return .{ .v = a.v.neg() };
                }
                pub fn scale(a: T, c: f64) T {
                    return .{ .v = a.v.scale(c) };
                }
                pub fn addC(a: T, c: f64) T {
                    return .{ .v = a.v.addC(c) };
                }
                pub fn exp(a: T) T {
                    return .{ .v = a.v.exp() };
                }
                pub fn log(a: T) T {
                    return .{ .v = a.v.log() };
                }
                pub fn expm1(a: T) T {
                    return .{ .v = a.v.expm1() };
                }
                pub fn log1p(a: T) T {
                    return .{ .v = a.v.log1p() };
                }
                pub fn sqrt(a: T) T {
                    return .{ .v = a.v.sqrt() };
                }
                pub fn sin(a: T) T {
                    return .{ .v = a.v.sin() };
                }
                pub fn cos(a: T) T {
                    return .{ .v = a.v.cos() };
                }
                pub fn tanh(a: T) T {
                    return .{ .v = a.v.tanh() };
                }
                pub fn sinh(a: T) T {
                    return .{ .v = a.v.sinh() };
                }
                pub fn cosh(a: T) T {
                    return .{ .v = a.v.cosh() };
                }
                pub fn atan(a: T) T {
                    return .{ .v = a.v.atan() };
                }
                pub fn pow(a: T, c: f64) T {
                    return .{ .v = a.v.pow(c) };
                }
                pub fn lt(a: T, b: T) T {
                    return w(a.v.lt(b.v));
                }
                pub fn le(a: T, b: T) T {
                    return w(a.v.le(b.v));
                }
                pub fn eq(a: T, b: T) T {
                    return w(a.v.eq(b.v));
                }
                pub fn sel(c: T, a: T, b: T) T {
                    return .{ .v = S.sel(c.v, a.v, b.v) };
                }
                pub fn min(a: T, b: T) T {
                    return a.lt(b).sel(a, b);
                }
                pub fn max(a: T, b: T) T {
                    return b.lt(a).sel(a, b);
                }
                pub fn abs(a: T) T {
                    return con(0.0).lt(a).sel(a, a.neg());
                }
                pub fn minC(a: T, c: f64) T {
                    return con(c).lt(a).sel(con(c), a);
                }
                pub fn maxC(a: T, c: f64) T {
                    return a.lt(con(c)).sel(con(c), a);
                }
            };
        }
        /// `math.zPow` at mask `m`; a batch family (`batch_lead`) runs it
        /// once per point on its scalar `Lane` family, since it steers on
        /// both values.
        pub fn zPowL(comptime S: type, comptime m: Mask, a: zOf(S, m), b: zOf(S, m), comptime ve: bool) zOf(S, m) {
            if (comptime @hasDecl(S, "Lane")) {
                var ls: [S.lane_count]zOf(S.Lane, m) = undefined;
                inline for (0..S.lane_count) |w| ls[w] = zPowL(S.Lane, m, S.laneOf(a, w), S.laneOf(b, w), ve);
                return S.fromLanes(m & zdr, ls);
            }
            return zLu(S, m, math.zPow(zL(S, m), zLw(S, m, a), zLw(S, m, b), ve));
        }
        /// `a` wrapped as `zL(S, m)`.
        pub fn zLw(comptime S: type, comptime m: Mask, a: anytype) zL(S, m) {
            return .{ .v = zTo(S, m, a) };
        }
        /// `a` unwrapped from `zL(S, m)`.
        pub fn zLu(comptime S: type, comptime m: Mask, a: zL(S, m)) zOf(S, m) {
            return a.v;
        }
    };
}

/// The helpers that read device `D`'s decls: a row as the family returns
/// it, and the unknowns an entry point hands its core.
pub fn Device(comptime D: type) type {
    const n_u = contract.nU(D);
    return struct {
        /// `D`'s family helpers.
        pub const F = Family(n_u, contract.derivReads(D));

        /// `a` as row `r`'s type.
        pub fn zRow(comptime S: type, comptime r: D.U, a: anytype) F.zOf(S, contract.rowMask(D, @backingInt(r))) {
            return F.zTo(S, contract.rowMask(D, @backingInt(r)), a);
        }
        /// Every row, zero.
        pub fn zRowsZero(comptime S: type) contract.Rows(D, S) {
            var r: contract.Rows(D, S) = undefined;
            inline for (0..n_u) |u| r[u] = F.zTo(S, contract.rowMask(D, u), S.con(0.0));
            return r;
        }
        /// The unknowns as an entry point's core reads them: a probe for
        /// each lane the device reads, a constant for every other.
        pub fn zX(comptime S: type) type {
            @setEvalBranchQuota(1_000_000);
            var ts: [n_u]type = undefined;
            for (&ts, 0..) |*t, u| t.* = F.zOf(S, @as(F.Mask, 1) << u);
            return @Tuple(&ts);
        }
        /// `x` as `zX(S)`.
        pub fn zProbe(comptime S: type, x: *const [n_u]S.V) zX(S) {
            var p: zX(S) = undefined;
            inline for (0..n_u) |u| p[u] = if (comptime (F.zdr >> u) & 1 != 0) S.probe(u, x[u]) else if (S.V == f64) S.con(x[u]) else S.lift(x[u]);
            return p;
        }
        /// The unknowns as values only, for the entry points that read the
        /// core without lanes.
        pub fn zVals(comptime S: type, x: *const [n_u]f64) [n_u]F.zOf(S, 0) {
            var p: [n_u]F.zOf(S, 0) = undefined;
            for (&p, x) |*o, v| o.* = S.con(v);
            return p;
        }
    };
}
