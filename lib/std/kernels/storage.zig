//! The run-time storage kernels: VerA's `vera_timepoint` cache key and its
//! in-place arrays (§2.9), §3.2.2 memory-backed arrays (an index in, an
//! element or a store out, never a branch out of bounds), and the §4.5.7
//! `absdelay` history read quadratically under `(* vera_interp = 2 *)`, as
//! SPICE's lossless transmission line does. The storage is the caller's
//! (`Instance` fields); these read and write what they are handed.
//! Cites: VAMS §2.9, §3.2.2, §4.5.7, §5.10, §5.10.2.
//!
//! Contents:
//! - `pub fn zTpKey(sim: contract.SimState) u8`
//! - `pub fn zTpHit(t: f64, k: u8, sim: contract.SimState) bool`
//! - `pub fn zArrWT(comptime T: type, comptime n: usize, slot: anytype, a: *[n]T, p: **const [n]T) *[n]T`
//! - `pub fn zTpFill(comptime T: type, comptime n: usize, slot: anytype, p: **const [n]T) void`
//! - `pub fn zTpHeld(comptime T: type, comptime n: usize, held: *[n]T, p: **[n]T, d: anytype) void`
//! - `pub fn zArrLd(comptime T: type, a: []const T, i: i64, z: T) T`
//! - `pub fn zArrSt(comptime T: type, a: []T, i: i64, v: T) void`
//! - `pub fn zArrStD(comptime T: type, a: []T, d: *[2]i64, i: i64, v: T) void`
//! - `pub fn zArrSync(comptime T: type, dst: anytype, src: anytype, d: *[2]i64) void`
//! - `pub fn zArrW(comptime T: type, comptime n: usize, a: *[n]T, p: **const [n]T) *[n]T`
//! - `pub fn zArrVal(comptime S: type, comptime n: usize, a: *const [n]S) [n]f64`
//! - `pub fn zAbsdelayQ(comptime S: type, vin: S, ts: []const f64, vs: []const f64, head: u64, now: f64, dt: f64, td: f64) S`
//! - `pub fn zHistAtQ(ts: []const f64, vs: []const f64, head: u64, t: f64) f64`

const std = @import("std");
const contract = @import("contract");
const ops = @import("ops.zig");

/// What a per-timepoint cache is keyed on beside `sim.t`: the analysis
/// (§4.6.1) and the two §5.10.2 step flags, which a statement may read
/// through a variable assigned under them.
pub fn zTpKey(sim: contract.SimState) u8 {
    return @backingInt(sim.kind) | @as(u8, @intFromBool(sim.initial_step)) << 4 | @as(u8, @intFromBool(sim.final_step)) << 5;
}

/// Whether a cache filled at `t` under key `k` is current for `sim`. A
/// dropped cache holds NaN, which equals nothing.
pub fn zTpHit(t: f64, k: u8, sim: contract.SimState) bool {
    return t == sim.t and k == zTpKey(sim);
}

/// The storage a store inside a `vera_timepoint` statement writes: the
/// cache slot itself, holding what `p` read until now, when `slot` is
/// writable (`*[n]T`, a core handed a mutable `Instance`); else `zArrW`'s
/// local `a`.
pub fn zArrWT(comptime T: type, comptime n: usize, slot: anytype, a: *[n]T, p: **const [n]T) *[n]T {
    if (comptime @typeInfo(@TypeOf(slot)).pointer.attrs.@"const") return zArrW(T, n, a, p);
    return zArrW(T, n, slot, p);
}

/// At the statement's join: point `p` at a writable `slot`, copying the
/// version in when the statement stored none, so the slot holds what the
/// statement left whichever arm ran.
pub fn zTpFill(comptime T: type, comptime n: usize, slot: anytype, p: **const [n]T) void {
    if (comptime @typeInfo(@TypeOf(slot)).pointer.attrs.@"const") return;
    if (p.* != slot) {
        slot.* = p.*.*;
        p.* = slot;
    }
}

/// `updateState`'s join, for an array it stores in place: point `p` at the
/// held field, copying a cached version in and widening its dirty range `d`
/// (or `null`) to the whole array.
pub fn zTpHeld(comptime T: type, comptime n: usize, held: *[n]T, p: **[n]T, d: anytype) void {
    if (p.* != held) {
        held.* = p.*.*;
        p.* = held;
        if (@TypeOf(d) != @TypeOf(null)) d.* = .{ 0, n - 1 };
    }
}

/// Element `i` of `a`, or `z` for an index outside it: §3.2.2 names no
/// element there, and the read gives the element type's zero. The load is
/// clamped into bounds and the pick is a select, so it never branches.
/// Asserts that `a` is not empty.
pub fn zArrLd(comptime T: type, a: []const T, i: i64, z: T) T {
    const k: u64 = @bitCast(i);
    const v = a[@intCast(@min(k, a.len - 1))];
    return if (k < a.len) v else z;
}

/// Stores `v` at `i`; an index outside the array writes nothing.
pub fn zArrSt(comptime T: type, a: []T, i: i64, v: T) void {
    const k: u64 = @bitCast(i);
    if (k < a.len) a[@intCast(k)] = v;
}

/// Stores `v` at `i` in an in-place held array and widens `d`, the index
/// range written since the last `stateCtl` (`zArrSync`).
pub fn zArrStD(comptime T: type, a: []T, d: *[2]i64, i: i64, v: T) void {
    const k: u64 = @bitCast(i);
    if (k < a.len) {
        a[@intCast(k)] = v;
        d.* = .{ @min(d[0], i), @max(d[1], i) };
    }
}

/// §5.10 `stateCtl` for an in-place held array: copies the elements written
/// since the last commit or revert (`d`, inclusive; empty when d[0] > d[1])
/// from `src` to `dst`; then the two agree everywhere and `d` is empty. A
/// step appending one sample to a 2048-deep history copies one.
pub fn zArrSync(comptime T: type, dst: anytype, src: anytype, d: *[2]i64) void {
    if (d[0] <= d[1]) {
        const lo: usize = @intCast(d[0]);
        const hi: usize = @intCast(d[1] + 1);
        @memcpy(@as([]T, dst[lo..hi]), @as([]const T, src[lo..hi]));
    }
    d.* = .{ std.math.maxInt(i64), -1 };
}

/// §5.10 the storage a held array's store writes: `a`, holding what `p`
/// read until now (the `Instance` field, copied in by the first store).
pub fn zArrW(comptime T: type, comptime n: usize, a: *[n]T, p: **const [n]T) *[n]T {
    if (p.* != a) {
        a.* = p.*.*;
        p.* = a;
    }
    return a;
}

/// The values of an `S` array: what a held array's `f64` `Instance` field
/// keeps.
pub fn zArrVal(comptime S: type, comptime n: usize, a: *const [n]S) [n]f64 {
    var o: [n]f64 = undefined;
    for (&o, a) |*d, s| d.* = s.val();
    return o;
}

/// `ops.zAbsdelay` read quadratically. Every edge `zAbsdelay` decides for
/// itself (a static analysis, an empty ring, a query past `now`) is its
/// answer here too, and so is a single accepted sample. Past the newest
/// sample the parabola runs through the last two samples and the in-flight
/// (now, vin), so the output carries ∂/∂vin, the Lagrange weight of `now`.
pub fn zAbsdelayQ(comptime S: type, vin: S, ts: []const f64, vs: []const f64, head: u64, now: f64, dt: f64, td: f64) S {
    const t = now - td;
    if (dt <= 0.0 or head < 2 or !(t < now)) return ops.zAbsdelay(S, vin, ts, vs, head, now, dt, td);
    const b: usize = @intCast((head + ts.len - 1) % ts.len);
    const a: usize = @intCast((head + ts.len - 2) % ts.len);
    if (t <= ts[b]) return S.con(zHistAtQ(ts, vs, head, t));
    const dab = ts[b] - ts[a];
    const dan = now - ts[a];
    const dbn = now - ts[b];
    if (!(dab > 0.0 and dbn > 0.0)) return ops.zAbsdelay(S, vin, ts, vs, head, now, dt, td);
    const wa = (t - ts[b]) * (t - now) / (dab * dan);
    const wb = -(t - ts[a]) * (t - now) / (dab * dbn);
    const wn = (t - ts[a]) * (t - ts[b]) / (dan * dbn);
    return vin.scale(wn).addC(vs[a] * wa + vs[b] * wb);
}

/// `ops.zHistAt` read quadratically: the parabola through the two samples
/// bracketing `t` and the one before them (the first three, in the first
/// interval). Fewer than three samples, a query at or before the oldest, or
/// two samples at one time is `zHistAt`'s linear answer. O(log n).
pub fn zHistAtQ(ts: []const f64, vs: []const f64, head: u64, t: f64) f64 {
    const n = ts.len;
    const count: usize = @intCast(@min(head, n));
    const oldest: usize = if (head > n) @intCast(head % n) else 0;
    if (count < 3 or t <= ts[oldest]) return ops.zHistAt(ts, vs, head, t);
    // The ring is monotone in time, so the samples at or before `t` count
    // out the older end of its interval; a binary search in age order finds
    // that count.
    var lo: usize = 0;
    var hi: usize = count;
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (ts[(oldest + mid) % n] <= t) lo = mid else hi = mid;
    }
    const m = lo + 1;
    const w = oldest + @min(m - 1 -| 1, count - 3);
    const i_0 = w % n;
    const i_1 = (w + 1) % n;
    const i_2 = (w + 2) % n;
    const d01 = ts[i_1] - ts[i_0];
    const d12 = ts[i_2] - ts[i_1];
    if (!(d01 > 0.0 and d12 > 0.0)) return ops.zHistAt(ts, vs, head, t);
    const d02 = ts[i_2] - ts[i_0];
    return vs[i_0] * (t - ts[i_1]) * (t - ts[i_2]) / (d01 * d02) -
        vs[i_1] * (t - ts[i_0]) * (t - ts[i_2]) / (d01 * d12) +
        vs[i_2] * (t - ts[i_0]) * (t - ts[i_1]) / (d02 * d12);
}
