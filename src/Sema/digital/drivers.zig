//! VAMS §7.9 and §9.22 driver access in a mixed design's digital half:
//! the bridges' segments in; each segment a connect module drives split
//! into its drivers' net and its receivers' net (`segregate`), and the
//! static facts the access functions read (`count`, `receiverCount`) out.
//! Cites: VAMS-2023 §7.9, §9.22, §9.22.1, §9.22.2, §9.22.6.
//!
//! Contents:
//! - `pub const Fn = enum`
//! - `pub fn check(l: *Lower, i: Inst.Index, f: Fn, args: []const Inst.Ref) Error!digital.Name`
//! - `pub fn segregate(l: *Lower) Error!void`
//! - `pub fn isConnect(l: *const Lower, f: u32) bool`
//! - `pub fn count(l: *const Lower, net: u32) u32`
//! - `pub fn receiverCount(l: *const Lower, net: u32) u32`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const digital = @import("../digital.zig");
const nets = @import("nets.zig");
const expr = @import("expr.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const none = digital.none;
const Inst = vams.Vir.Inst;

/// The VAMS §9.22.1-§9.22.4 / §9.23.1-§9.23.4 access functions.
pub const Fn = enum { count, receiver_count, state, strength, delay, next_state, next_strength, type };

/// Syntax 9-17 … 9-24, as lib/sim/digital checks a call `i` of `f`:
/// `(signal_name)` for the two counts, `(signal_name, driver_index)` for
/// the rest, in a connect module (E0818), on a scalar net. Its net's name.
pub fn check(l: *Lower, i: Inst.Index, f: Fn, args: []const Inst.Ref) Error!digital.Name {
    const want: usize = if (f == .count or f == .receiver_count) 1 else 2;
    if (args.len != want or args[0] == .none or (want == 2 and args[1] == .none))
        return l.reject(l.frame, i.toRef(), "§9.22: a driver access function takes (signal_name) or (signal_name, driver_index)");
    if (!isConnect(l, l.frame)) {
        l.why_code = .E0818;
        return l.reject(l.frame, i.toRef(), "§9.22: \"Driver access functions can only be called from connect modules.\" This is a `module`");
    }
    const n = (try expr.nameOf(l, args[0])) orelse return l.reject(l.frame, args[0], "§9.22: signal_name names a net");
    if (n.kind != .net) return l.reject(l.frame, args[0], "§9.22: signal_name names a net");
    // §9.22.3 a driver's state is one of "0, 1, x, or z": one bit.
    if (n.ty.width != 1) return l.reject(l.frame, args[0], "§9.22.3: signal_name is a scalar net; a driver's state is one bit");
    if (want == 2 and (try expr.typeValue(l, args[1])).real) return l.reject(l.frame, args[1], "§9.22.3: driver_index is an integer");
    assert(n.net != none);
    return n;
}

/// §7.9 "the drivers and receivers of connect modules shall be oppositely
/// segregated": a segment a connect module drives becomes two nets. The
/// segment keeps the ordinary drivers and the connect module's reads; a
/// fresh net takes the connect module's drivers and every ordinary input
/// port bound to the segment (lib/sim/digital's `segregate`). Runs after
/// the walk, before any process or driver is compiled.
pub fn segregate(l: *Lower) Error!void {
    var it = l.segment_of.valueIterator();
    while (it.next()) |seg| {
        const d = seg.net;
        if (l.receivers.contains(d)) continue; // two names of one segment
        const driven = for (l.wires.items) |w| {
            if (w.net == d and isConnect(l, w.frame)) break true;
        } else false;
        if (!driven) continue;
        const rx = try nets.mintNet(l, l.nets.items[d].kind, l.nets.items[d].width, seg.ty.signed);
        for (l.wires.items) |*w| if (w.net == d and isConnect(l, w.frame)) {
            w.net = rx;
        };
        var rx_name = seg.*;
        rx_name.net = rx;
        rx_name.slot = l.nets.items[rx].slot;
        for (l.frames.items, 0..) |fr, f| {
            if (fr.parent != none or isConnect(l, @intCast(f))) continue;
            const vir = l.virOf(@intCast(f));
            var names = fr.names.iterator();
            while (names.next()) |e| {
                const n = &l.names.items[e.value_ptr.*];
                if (n.kind != .net or n.net != d or !inputPort(vir, e.key_ptr.*)) continue;
                n.net = rx;
                n.slot = rx_name.slot;
            }
        }
        try l.receivers.put(l.a, d, rx_name);
        assert(l.nets.items[rx].width == l.nets.items[d].width);
    }
}

/// §9.22 ¶3 whether frame `f` is inside a connect module, whose drivers
/// "the driver access functions … only access drivers found in ordinary
/// modules" skip.
pub fn isConnect(l: *const Lower, f: u32) bool {
    const zcu = l.zcu;
    const d = zcu.instances.items(.module)[@backingInt(l.frames.items[f].instance)];
    return zcu.declRow(d).kind == .connectmodule;
}

/// §9.22.1 `$driver_count`: the ordinary drivers of `net`.
pub fn count(l: *const Lower, net: u32) u32 {
    assert(net < l.nets.items.len);
    var n: u32 = 0;
    for (l.wires.items) |w| n += @intFromBool(w.net == net and !isConnect(l, w.frame));
    return n;
}

/// §9.22.2 `$receiver_count`: "the total number of ordinary receivers", the
/// ordinary input ports bound to `net`'s receivers' net (the segment itself
/// when no connect module drives it).
pub fn receiverCount(l: *const Lower, net: u32) u32 {
    const rx = if (l.receivers.get(net)) |n| n.net else net;
    var n: u32 = 0;
    for (l.frames.items, 0..) |fr, f| {
        if (fr.parent != none or isConnect(l, @intCast(f))) continue;
        const vir = l.virOf(@intCast(f));
        var names = fr.names.iterator();
        while (names.next()) |e| {
            const x = l.names.items[e.value_ptr.*];
            n += @intFromBool(x.kind == .net and x.net == rx and inputPort(vir, e.key_ptr.*));
        }
    }
    return n;
}

// ---- private ----

/// Whether declaration `d` is an input port's.
fn inputPort(vir: *const vams.Vir, d: Inst.Index) bool {
    if (Lower.tag(vir, d) != .io) return false;
    return Lower.payload(vir, Inst.Io, d).flags.dir == .input;
}
