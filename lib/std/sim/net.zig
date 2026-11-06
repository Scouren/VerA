//! Driver bits, their A.2.2.2 strengths and the net's type in, one resolved
//! four-state bit out; a gate's or UDP's inputs in, its output bit out. Pure
//! tables and functions, no run state: §7.10's strength signals, §7.9 wired
//! logic, §3.7 undriven values, §7.8.5 gate tables, §8 UDP tables, §7.14 and
//! §6.1.3 delay selection.
//! Cites: IEEE 1364-2005 §3.7, §3.8, §6.1.3, §7.8.5, §7.9 Tables 7-4/7-6/7-7,
//! §7.10 Figures 7-9 to 7-25, §7.14, §8.1.6, §8.6 Table 8-1.
//!
//! Contents:
//! - `pub const Strength = enum(u8)`, `pub const NetKind = enum(u8)`, `pub const GateKind = enum(u8)`
//! - `pub const Wired = enum`, `pub const GateOut = struct`
//! - `pub const Signal = struct` (`of`, `orZ`, `none`, `combine`, `combineWired`, `collapse`)
//! - `pub const Delay = struct` (`to`, `continuous`)
//! - `pub const UdpSym = union(enum)`, `pub const UdpRow = struct`
//! - `pub const Node = struct`, `pub const SwitchPath = struct`, `pub const TranState = enum(u8)`
//! - `pub fn reduce(s: Strength, resistive: bool) Strength`, `pub fn reduceSignal(sig: Signal, hops: u32, resistive: u32) Signal`
//! - `pub fn crossed(own: Signal, z: Node, y: Node, p: SwitchPath) Signal`
//! - `pub fn reach(g: anytype, a: std.mem.Allocator, from: Node) std.mem.Allocator.Error![]const Node`
//! - `pub fn switchPaths(g: anytype, a: std.mem.Allocator, y: Node, group: []const Node) std.mem.Allocator.Error![]const SwitchPath`
//! - `pub fn pathTable(d: []const u64) [4][4]u64`
//! - `pub fn netPull(kind: NetKind) Signal`
//! - `pub fn wiredLogic(kind: NetKind) ?Wired`
//! - `pub fn gateBit(kind: GateKind, ins: []const Bit) GateOut`
//! - `pub fn udpEval(rows: []const UdpRow, sequential: bool, ins: []const Bit, state: Bit, changed: ?u32, from: Bit) Bit`

const std = @import("std");
const assert = std.debug.assert;
const logic = @import("logic.zig");
const Bit = logic.Bit;
const Literal = logic.Literal;

/// A.2.2.2's strengths as one scale, weakest first, so the backing integer
/// orders them.
pub const Strength = enum(u8) { highz = 0, small = 1, medium = 2, weak = 3, large = 4, pull = 5, strong = 6, supply = 7 };

/// §3.7 / VAMS §3.7 net types.
pub const NetKind = enum(u8) { wire, tri, tri0, tri1, triand, trior, trireg, wand, wor, uwire, supply0, supply1, wreal };

/// A.3.1 the gates of §7.8.
pub const GateKind = enum(u8) { g_and, g_nand, g_or, g_nor, g_xor, g_xnor, g_buf, g_not, g_bufif0, g_bufif1, g_notif0, g_notif1 };

/// The two §7.9 wired-logic tables: wired AND and wired OR.
pub const Wired = enum { @"and", @"or" };

/// One gate evaluation: its output bit, and whether it is §7.10.2's H/L.
pub const GateOut = struct { bit: Bit, or_z: bool = false };

/// §7.10's signal: a range of strength levels on Figure 7-2's scale folded
/// at HiZ: `-s` is strength0 level `s`, `+s` strength1 level `s`, 0 HiZ.
pub const Signal = struct {
    lo: i8 = 0,
    hi: i8 = 0,

    comptime {
        assert(@sizeOf(Signal) == 2);
    }

    /// What a driver holding `b` at `(s0, s1)` asserts.
    pub fn of(b: Bit, s0: Strength, s1: Strength) Signal {
        const p0 = -@as(i8, @intCast(@backingInt(s0)));
        const p1: i8 = @intCast(@backingInt(s1));
        const sig: Signal = switch (b) {
            .one => .{ .lo = p1, .hi = p1 },
            .zero => .{ .lo = p0, .hi = p0 },
            .x => .{ .lo = p0, .hi = p1 },
            .z => .{},
        };
        assert(sig.lo <= sig.hi);
        return sig;
    }

    /// §7.10.2 H or L: `b` or high impedance, at `b`'s side's strength.
    pub fn orZ(b: Bit, s0: Strength, s1: Strength) Signal {
        return of(.x, if (b == .one) .highz else s0, if (b == .zero) .highz else s1);
    }

    /// No driver at all.
    pub fn none(self: Signal) bool {
        assert(self.lo <= self.hi);
        return self.lo == 0 and self.hi == 0;
    }

    /// §7.10.1-§7.10.3, one more contributor folded in.
    pub fn combine(a: Signal, b: Signal) Signal {
        if (a.none()) return b;
        if (b.none()) return a;
        const hull: Signal = .{ .lo = @min(a.lo, b.lo), .hi = @max(a.hi, b.hi) };
        const ua = a.lo == a.hi;
        const ub = b.lo == b.hi;
        if (ua and ub) {
            if (@abs(a.lo) != @abs(b.lo)) return if (@abs(a.lo) > @abs(b.lo)) a else b;
            return hull;
        }
        if (!ua and !ub) return hull;
        const u = if (ua) a.lo else b.lo;
        const amb = if (ua) b else a;
        const s: i8 = @intCast(@abs(u));
        const out: Signal = .{
            .lo = if (amb.lo < -s or (amb.lo == -s and u > 0)) @min(u, amb.lo) else u,
            .hi = if (amb.hi > s or (amb.hi == s and u < 0)) @max(u, amb.hi) else u,
        };
        assert(out.lo <= out.hi);
        return out;
    }

    /// §7.10.4, one more contributor folded into a wired-logic net.
    pub fn combineWired(a: Signal, b: Signal, table: Wired) Signal {
        if (a.none()) return b;
        if (b.none()) return a;
        var out: Signal = .{ .lo = std.math.maxInt(i8), .hi = std.math.minInt(i8) };
        var p = a.lo;
        while (p <= a.hi) : (p += 1) {
            var q = b.lo;
            while (q <= b.hi) : (q += 1) {
                const r = if (@abs(p) != @abs(q))
                    (if (@abs(p) > @abs(q)) p else q)
                else if (table == .@"and") @min(p, q) else @max(p, q);
                out.lo = @min(out.lo, r);
                out.hi = @max(out.hi, r);
            }
        }
        assert(out.lo <= out.hi);
        return out;
    }

    /// The four-state value of the range: one side's value, z for HiZ alone,
    /// x for anything that straddles HiZ.
    pub fn collapse(self: Signal) Bit {
        assert(self.lo <= self.hi);
        const u = @intFromBool(self.lo <= 0) & @intFromBool(self.hi >= 0);
        const v = @intFromBool(self.hi > 0) | (@intFromBool(self.lo < 0) & @intFromBool(self.hi == 0));
        return @fromBackingInt(@intCast(@as(u2, v) | @as(u2, u) << 1));
    }
};

/// A.2.2.3's three values in ticks; `present` false is no delay at all.
pub const Delay = struct {
    rise: u64 = 0,
    fall: u64 = 0,
    off: u64 = 0,
    present: bool = false,

    /// §7.14 a scalar transition to `b`; x takes the smallest.
    pub fn to(self: Delay, b: Bit) u64 {
        return switch (b) {
            .one => self.rise,
            .zero => self.fall,
            .z => self.off,
            .x => @min(self.rise, @min(self.fall, self.off)),
        };
    }

    /// §6.1.3 a continuous assignment's (or a net's) delay to `value`:
    /// fall for nonzero to zero, turn-off for all z, rise otherwise; `from`
    /// is the truth of the published value.
    pub fn continuous(self: Delay, from: Bit, value: Literal) u64 {
        assert(value.width != 0);
        if (value.width == 1) return self.to(value.bit(0));
        const all_z = for (0..(value.width + 63) / 64) |w| {
            const m = logic.wordMask(value.width, w);
            if (value.unknowns()[w] & ~value.values()[w] & m != m) break false;
        } else true;
        if (all_z) return self.off;
        if (from == .one and value.truth() == .zero) return self.fall;
        return self.rise;
    }
};

/// One A.5.3 input field: a level symbol, a `(vw)` edge, or an edge letter.
pub const UdpSym = union(enum) { level: u8, pair: [2]u8, letter: u8 };

/// One table entry: `edge_at` is the input its edge is on, null for a level
/// entry; `state` is 0 in a combinational table.
pub const UdpRow = struct { ins: []const UdpSym, state: u8, out: u8, edge_at: ?u32 };

/// One bit of one net, as a pass switch terminal sees it.
pub const Node = struct { net: u32, bit: u32 };

/// From a group member to a node: the fewest resistive switches on a path
/// that may conduct, and whether some path surely does.
pub const SwitchPath = struct { res: u32, sure: bool };

/// §7.6 a pass switch's conduction: by its control, unknown while x or z.
pub const TranState = enum(u8) { on, off, unknown };

/// IEEE 1364-2005 §7.12 Table 7-8: what a resistive switch makes of the
/// strength it passes; a non-resistive one only turns supply into strong.
pub fn reduce(s: Strength, resistive: bool) Strength {
    const out: Strength = if (!resistive) (if (s == .supply) .strong else s) else switch (s) {
        .supply, .strong => .pull,
        .pull => .weak,
        .large, .weak => .medium,
        .medium, .small => .small,
        .highz => .highz,
    };
    assert(@backingInt(out) <= @backingInt(s));
    return out;
}

/// §7.11/§7.12 a signal that crossed `hops` pass switches, `resistive` of
/// them resistive.
pub fn reduceSignal(sig: Signal, hops: u32, resistive: u32) Signal {
    if (hops == 0) return sig;
    const one = struct {
        fn side(v: i8, k: u32) i8 {
            var s = reduce(@fromBackingInt(@intCast(@as(u8, @intCast(@abs(v))))), false);
            for (0..k) |_| s = reduce(s, true);
            const m: i8 = @intCast(@backingInt(s));
            return if (v < 0) -m else m;
        }
    };
    return .{ .lo = one.side(sig.lo, resistive), .hi = one.side(sig.hi, resistive) };
}

/// What `own`, asserted at `z`, is at `y` across path `p`: reduced, and
/// widened to high impedance where no path surely conducts (§7.10.2).
pub fn crossed(own: Signal, z: Node, y: Node, p: SwitchPath) Signal {
    assert(p.res != std.math.maxInt(u32));
    const sig = reduceSignal(own, @intFromBool(!std.meta.eql(z, y)), p.res);
    return if (p.sure or sig.none()) sig else .{ .lo = @min(sig.lo, 0), .hi = @max(sig.hi, 0) };
}

/// The net bits joined to `from` through switches that may conduct; `g`
/// has `switches(net)`, `tran(ti)`, `conduction(ti)` and `fixed(net)`
/// (a supply net, which no path runs through).
pub fn reach(g: anytype, a: std.mem.Allocator, from: Node) std.mem.Allocator.Error![]const Node {
    var seen: std.ArrayList(Node) = .empty;
    try seen.append(a, from);
    var i: usize = 0;
    while (i < seen.items.len) : (i += 1) {
        const u = seen.items[i];
        if (g.fixed(u.net)) continue;
        for (g.switches(u.net)) |ti| {
            if (g.conduction(ti) == .off) continue;
            const v = across(g.tran(ti), u) orelse continue;
            for (seen.items) |w| {
                if (std.meta.eql(w, v)) break;
            } else try seen.append(a, v);
        }
    }
    return seen.items;
}

/// For each member of `group`, its `SwitchPath` to `y`.
pub fn switchPaths(g: anytype, a: std.mem.Allocator, y: Node, group: []const Node) std.mem.Allocator.Error![]const SwitchPath {
    const p = try a.alloc(SwitchPath, group.len);
    @memset(p, .{ .res = std.math.maxInt(u32), .sure = false });
    for (group, p) |u, *q| if (std.meta.eql(u, y)) {
        q.* = .{ .res = 0, .sure = true };
    };
    const passes_max = group.len * (group.len + 2) + 1;
    var passes: usize = 0;
    var changed = true;
    while (changed) : (passes += 1) {
        assert(passes <= passes_max);
        changed = false;
        for (group, 0..) |u, iu| {
            if (p[iu].res == std.math.maxInt(u32)) continue;
            if (!std.meta.eql(u, y) and g.fixed(u.net)) continue;
            for (g.switches(u.net)) |ti| {
                const st = g.conduction(ti);
                if (st == .off) continue;
                const tr = g.tran(ti);
                const v = across(tr, u) orelse continue;
                const iv = for (group, 0..) |w, k| {
                    if (std.meta.eql(w, v)) break k;
                } else continue;
                const res = p[iu].res + @intFromBool(tr.resistive);
                if (res < p[iv].res) {
                    p[iv].res = res;
                    changed = true;
                }
                if (p[iu].sure and st == .on and !p[iv].sure) {
                    p[iv].sure = true;
                    changed = true;
                }
            }
        }
    }
    return p;
}

/// IEEE 1364-2005 §14.3.1 Table 14-2: a path's delay for each transition
/// (`[from][to]` by `Bit`'s backing integer) from its 1, 2, 3, 6 or 12
/// values; §14.3.2 Table 14-3's x transitions where fewer than 12 are
/// given: to x as quickly as possible, from x as long as possible.
pub fn pathTable(d: []const u64) [4][4]u64 {
    assert(d.len == 1 or d.len == 2 or d.len == 3 or d.len == 6 or d.len == 12);
    const t01, const t10, const t0z, const tz1, const t1z, const tz0 = switch (d.len) {
        1 => .{ d[0], d[0], d[0], d[0], d[0], d[0] },
        2 => .{ d[0], d[1], d[0], d[0], d[1], d[1] },
        3 => .{ d[0], d[1], d[2], d[0], d[2], d[1] },
        else => .{ d[0], d[1], d[2], d[3], d[4], d[5] }, // else: the 6 and 12 forms name these six first
    };
    const zero = @backingInt(Bit.zero);
    const one = @backingInt(Bit.one);
    const z = @backingInt(Bit.z);
    const x = @backingInt(Bit.x);
    var t: [4][4]u64 = @splat(@splat(0));
    t[zero][one] = t01;
    t[one][zero] = t10;
    t[zero][z] = t0z;
    t[z][one] = tz1;
    t[one][z] = t1z;
    t[z][zero] = tz0;
    if (d.len == 12) {
        t[zero][x] = d[6];
        t[x][one] = d[7];
        t[one][x] = d[8];
        t[x][zero] = d[9];
        t[x][z] = d[10];
        t[z][x] = d[11];
    } else {
        t[zero][x] = @min(t0z, t01);
        t[one][x] = @min(t1z, t10);
        t[z][x] = @min(tz1, tz0);
        t[x][zero] = @max(tz0, t10);
        t[x][one] = @max(tz1, t01);
        t[x][z] = @max(t1z, t0z);
    }
    return t;
}

/// §3.7/§7.9 what the net type itself contributes, at its own strength.
pub fn netPull(kind: NetKind) Signal {
    return switch (kind) {
        .supply0 => .of(.zero, .supply, .highz),
        .supply1 => .of(.one, .highz, .supply),
        .tri0 => .of(.zero, .pull, .highz),
        .tri1 => .of(.one, .highz, .pull),
        .wire, .tri, .triand, .trior, .trireg, .wand, .wor, .uwire, .wreal => .{},
    };
}

/// Which §7.9 table a net folds its drivers through; null for `combine`.
pub fn wiredLogic(kind: NetKind) ?Wired {
    return switch (kind) {
        .wand, .triand => .@"and",
        .wor, .trior => .@"or",
        .wire, .tri, .tri0, .tri1, .trireg, .uwire, .supply0, .supply1, .wreal => null,
    };
}

/// §7.8.5 a gate's output for input bits `ins` (z reads as x).
pub fn gateBit(kind: GateKind, ins: []const Bit) GateOut {
    assert(ins.len != 0);
    switch (kind) {
        .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => {
            assert(ins.len == 2);
            const on: Bit = if (kind == .g_bufif1 or kind == .g_notif1) .one else .zero;
            const enable = ins[1];
            const data = if (kind == .g_bufif0 or kind == .g_bufif1) gateIn(ins[0]) else invert(ins[0]);
            if (enable == .x or enable == .z) return .{ .bit = data, .or_z = data != .x };
            if (enable != on) return .{ .bit = .z };
            return .{ .bit = data };
        },
        .g_and, .g_nand, .g_or, .g_nor, .g_xor, .g_xnor, .g_buf, .g_not => return .{ .bit = logicBit(kind, ins) },
    }
}

/// §8 a UDP's output for inputs `ins` (no z): a level entry first, then an
/// edge entry on input `changed` from `from`; x when no entry matches.
pub fn udpEval(rows: []const UdpRow, sequential: bool, ins: []const Bit, state: Bit, changed: ?u32, from: Bit) Bit {
    for (rows) |row| {
        if (row.edge_at != null) continue;
        if (sequential and !udpLevel(row.state, state)) continue;
        for (row.ins, ins) |sym, b| {
            if (!udpLevel(sym.level, b)) break;
        } else return udpOut(row.out, state);
    }
    const k = changed orelse return .x;
    assert(k < ins.len);
    for (rows) |row| {
        if (row.edge_at != k or !udpLevel(row.state, state)) continue;
        for (row.ins, ins, 0..) |sym, b, i| {
            if (i == k) {
                if (!udpEdge(sym, from, b)) break;
            } else if (sym != .level or !udpLevel(sym.level, b)) break;
        } else return udpOut(row.out, state);
    }
    return .x;
}

// ---- private ----

fn across(tr: anytype, u: Node) ?Node {
    const at_a = tr.a == u.net and tr.a_bit == u.bit;
    const at_b = tr.b == u.net and tr.b_bit == u.bit;
    if (!at_a and !at_b) return null;
    return if (at_a) .{ .net = tr.b, .bit = tr.b_bit } else .{ .net = tr.a, .bit = tr.a_bit };
}

fn gateIn(b: Bit) Bit {
    return if (b == .z) .x else b;
}

fn invert(b: Bit) Bit {
    return switch (b) {
        .zero => .one,
        .one => .zero,
        .x, .z => .x,
    };
}

fn logicBit(kind: GateKind, ins: []const Bit) Bit {
    switch (kind) {
        .g_and, .g_nand, .g_or, .g_nor => {
            const control: Bit = if (kind == .g_and or kind == .g_nand) .zero else .one;
            var unknown = false;
            for (ins) |raw| {
                const b = gateIn(raw);
                if (b == control) return if (kind == .g_and or kind == .g_or) control else invert(control);
                if (b == .x) unknown = true;
            }
            if (unknown) return .x;
            const quiet = invert(control);
            return if (kind == .g_and or kind == .g_or) quiet else control;
        },
        .g_xor, .g_xnor => {
            var ones: u32 = 0;
            for (ins) |raw| {
                const b = gateIn(raw);
                if (b == .x) return .x;
                if (b == .one) ones += 1;
            }
            const parity: Bit = if (ones % 2 == 1) .one else .zero;
            return if (kind == .g_xor) parity else invert(parity);
        },
        .g_buf, .g_not => {
            assert(ins.len == 1);
            return if (kind == .g_buf) gateIn(ins[0]) else invert(ins[0]);
        },
        .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => unreachable, // gateBit's own arm
    }
}

fn udpLevel(sym: u8, b: Bit) bool {
    assert(b != .z);
    return switch (sym) {
        '0' => b == .zero,
        '1' => b == .one,
        'x' => b == .x,
        '?' => true,
        'b' => b == .zero or b == .one,
        else => false,
    };
}

fn udpEdge(sym: UdpSym, from: Bit, to: Bit) bool {
    if (from == to) return false;
    return switch (sym) {
        .level => false,
        .pair => |p| udpLevel(p[0], from) and udpLevel(p[1], to),
        .letter => |l| switch (l) {
            'r' => from == .zero and to == .one,
            'f' => from == .one and to == .zero,
            'p' => (from == .zero and to != .zero) or (from == .x and to == .one),
            'n' => (from == .one and to != .one) or (from == .x and to == .zero),
            else => true, // else: `*`, any change
        },
    };
}

fn udpOut(sym: u8, state: Bit) Bit {
    assert(state != .z);
    return switch (sym) {
        '0' => .zero,
        '1' => .one,
        '-' => state,
        else => .x,
    };
}

test "Signal.collapse agrees with the clause's reading on every range" {
    var lo: i8 = -7;
    while (lo <= 7) : (lo += 1) {
        var hi = lo;
        while (hi <= 7) : (hi += 1) {
            const s: Signal = .{ .lo = lo, .hi = hi };
            const want: Bit = if (lo == 0 and hi == 0) .z else if (lo > 0) .one else if (hi < 0) .zero else if (lo < 0 and hi == 0) .zero else .x;
            // An L (lo < 0, hi == 0) is 0-or-z, which reads as x on a
            // straddle of HiZ except Figure 7-17's L, the old engine's 0.
            if (lo < 0 and hi == 0) continue;
            try std.testing.expectEqual(want, s.collapse());
        }
    }
}
