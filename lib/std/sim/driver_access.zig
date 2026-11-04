//! VAMS §9.22.3-§9.22.4 and §9.23.1-§9.23.4 driver access at run time: a
//! `Program.DriverAccess` row and the run's drivers in; the indexed
//! ordinary driver's state, strength, type, or its pending value and the
//! delay until it lands, out (lib/sim/digital's `driver.zig`).
//! Cites: VAMS-2023 §9.22.1, §9.22.3, §9.22.4, §9.23.1-§9.23.4, Annex D.3;
//! IEEE 1364-2005 §7.10 (the strength scale §9.22.4 encodes).
//!
//! Contents:
//! - `pub fn value(s: *State, a: Allocator, e: u32) Error!Literal`
//! - `pub fn delay(s: *State, a: Allocator, e: u32) Error!f64`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Program = @import("Program.zig");
const State = @import("State.zig");
const logic = @import("logic.zig");
const net = @import("net.zig");
const resolve = @import("resolve.zig");
const eval = @import("eval.zig");
const Literal = logic.Literal;
const Bit = logic.Bit;
const Signal = net.Signal;
const Error = State.Error;

/// Row `e`'s value (a `.driver_access` row other than `$driver_delay`):
/// one bit for a state, an i32 otherwise; x for an index naming no
/// ordinary driver (§9.22.3 bounds it to 0..N-1 and says no more).
pub fn value(s: *State, a: Allocator, e: u32) Error!Literal {
    const p = s.p;
    const da = p.extraData(Program.DriverAccess, p.exprs.items(.data)[e].a);
    assert(da.op != .delay);
    const bit = da.op == .state or da.op == .next_state;
    const di = (try driverOf(s, a, da)) orelse return logic.filled(a, if (bit) 1 else 32, !bit, .x);
    const now = resolve.current(s, di).bit(0);
    const next = (try pending(s, a, di)) orelse Pend{ .bit = now, .time = 0 };
    const n: u32 = switch (da.op) {
        .state => return logic.scalar(a, now),
        .next_state => return logic.scalar(a, next.bit),
        .strength => strengthBits(.of(now, s.drv_s0[di], s.drv_s1[di])),
        .next_strength => level(.of(next.bit, s.drv_s0[di], s.drv_s1[di])),
        .type => typeBits(p, p.drivers[di]),
        .delay => unreachable, // asserted above: real-valued
    };
    const v = try logic.filled(a, 32, true, .zero);
    v.values()[0] = n;
    return v;
}

/// §9.23.1 `$driver_delay`: "the delay, from current simulation time,
/// after which the pending state or strength becomes active. If there is
/// no pending value on a signal, it returns the value minus one (-1.0)", in
/// the calling scope's `timescale units.
pub fn delay(s: *State, a: Allocator, e: u32) Error!f64 {
    const p = s.p;
    const da = p.extraData(Program.DriverAccess, p.exprs.items(.data)[e].a);
    assert(da.op == .delay);
    const di = (try driverOf(s, a, da)) orelse return -1.0;
    const next = (try pending(s, a, di)) orelse return -1.0;
    assert(next.time >= s.scheduler.now);
    const scale = p.times[da.time].scale;
    return scale.realAt(next.time) - scale.realAt(s.scheduler.now);
}

// ---- private ----

const Pend = struct { bit: Bit, time: u64 };

/// The ordinary driver `da.index` names, or null.
fn driverOf(s: *State, a: Allocator, da: Program.DriverAccess) Error!?u32 {
    const i = (try eval.eval(s, a, da.index)).asInt() orelse return null;
    const rows = s.p.list(da.drivers);
    if (i < 0 or i >= rows.len) return null;
    return rows[@intCast(i)];
}

/// The earliest value scheduled onto driver `di` and not yet active: its
/// own delayed transition, or, for a port window, a scheduled write of the
/// variable it carries (§9.23's "a non-blocking assign with delays").
fn pending(s: *State, a: Allocator, di: u32) Error!?Pend {
    const dr = s.p.drivers[di];
    var live: std.ArrayList(@import("scheduler.zig").Live) = .empty;
    try s.scheduler.pendingPayloads(a, &live);
    var best: ?Pend = null;
    for (live.items) |ev| {
        if (ev.payload >= s.rows.items.len) continue;
        const row = s.rows.items[ev.payload];
        const b: Bit = switch (row.item) {
            .drive => |at| if (at == di) blk: {
                const t = s.drv_trans[di].target;
                break :blk (Literal{ .width = dr.width, .signed = false, .sized = true, .planes = t }).bit(0);
            } else continue,
            .write => |w| switch (dr.source) {
                .bridge => |br| if (w.slot == br.src and w.sel == null)
                    (Literal{ .width = w.width, .signed = w.signed, .sized = true, .planes = row.buf }).bit(br.src_lo)
                else
                    continue,
                .expr, .gate, .udp, .mos, .pull => continue,
            },
            else => continue, // else: only a drive or a write carries a driver's next value
        };
        if (best == null or ev.time < best.?.time) best = .{ .bit = b, .time = ev.time };
    }
    return best;
}

/// §9.22.4 "bits 5-3 for strength0 and bits 2-0 for strength1", each a
/// level of Figure 9-3 (Su 7 … Sm 1, HiZ 0). A 0 or 1 spans one side of
/// the scale, its strongest and weakest level; an x gives each field its
/// own side.
fn strengthBits(sig: Signal) u32 {
    if (sig.lo < 0 and sig.hi > 0) return @as(u32, @abs(sig.lo)) << 3 | @abs(sig.hi);
    return @as(u32, @max(@abs(sig.lo), @abs(sig.hi))) << 3 | @min(@abs(sig.lo), @abs(sig.hi));
}

/// §9.23.3 "an integer between 0 and 7": the strength of the one state.
fn level(sig: Signal) u32 {
    return @max(@abs(sig.lo), @abs(sig.hi));
}

/// §9.23.4 and Annex D.3's masks.
fn typeBits(p: *const Program, dr: Program.Driver) u32 {
    var t: u32 = 0;
    if (dr.delay.present or dr.delay_rows[0] != std.math.maxInt(u32)) t |= 1; // DRIVER_DELAYED
    t |= switch (dr.source) {
        .gate, .mos => 2, // DRIVER_GATE
        .udp => 4, // DRIVER_UDP
        .expr => 8,
        .bridge => 16,
        .pull => 256,
    };
    t |= switch (p.nets[dr.net].kind) {
        .wor, .trior => 512,
        .wand, .triand => 1024,
        .wire, .tri, .tri0, .tri1, .trireg, .uwire, .supply0, .supply1, .wreal => 0, // no Table 7-4 wired-logic bit
    };
    return t;
}

test strengthBits {
    // §9.22.4: bits 5-3 strength0, bits 2-0 strength1 (the old engine's cases).
    try std.testing.expectEqual(@as(u32, 6 << 3 | 6), strengthBits(.of(.one, .strong, .strong)));
    try std.testing.expectEqual(@as(u32, 6 << 3 | 5), strengthBits(.{ .lo = 5, .hi = 6 }));
    try std.testing.expectEqual(@as(u32, 7 << 3 | 3), strengthBits(.{ .lo = -7, .hi = -3 }));
    try std.testing.expectEqual(@as(u32, 3 << 3 | 5), strengthBits(.{ .lo = -3, .hi = 5 }));
    try std.testing.expectEqual(@as(u32, 0), strengthBits(.{}));
}

test level {
    try std.testing.expectEqual(@as(u32, 7), level(.of(.one, .supply, .supply)));
    try std.testing.expectEqual(@as(u32, 5), level(.of(.zero, .pull, .pull)));
    try std.testing.expectEqual(@as(u32, 0), level(.{}));
}
