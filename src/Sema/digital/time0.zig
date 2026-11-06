//! The time-0 tables of the digital lowering's nets: the finished
//! `Program`'s drivers and nets in; each driver's time-0 value (unknown,
//! save the bits no operand can make other than z), each net's §7.9/§7.10
//! time-0 resolution (its signals, resolved value and slot value) and per
//! slot its net out.
//! Cites: IEEE 1364-2005 §7.6, §7.9, §7.10, §8.5.
//!
//! Contents:
//! - `pub fn finish(l: *Lower, p: *Program) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const std_sim = @import("std_sim");
const digital = @import("../digital.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const none = digital.none;
const Program = std_sim.Program;
const net = std_sim.net;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// Writes the nets' and drivers' tables into finished program `p`: each
/// driver's time-0 value (x, save the bits a constant z holds, read with
/// every net x), each net's §7.9 time-0 resolution (its signals, its
/// resolved value, its slot's value), and per slot its net.
pub fn finish(l: *Lower, p: *Program) Error!void {
    const nets = l.nets.items;
    const drivers = @constCast(p.drivers);
    // One driver per wire, in wire order (`compileDrivers`).
    assert(drivers.len == l.wires.items.len);
    // Each driver's time-0 value, unknown.
    var init: std.ArrayList(u64) = .empty;
    for (drivers) |*d| {
        d.init = @intCast(init.items.len);
        const v = try std_sim.logic.filled(l.a, d.width, false, .x);
        // §8.5 a UDP's output starts at its state (x for a combinational one).
        if (d.source == .udp) std_sim.logic.setBit(v, d.source.udp.out_bit orelse 0, d.source.udp.state);
        try init.appendSlice(l.a, v.values());
        try init.appendSlice(l.a, v.unknowns());
    }
    p.driver_init = init.items;
    try knownZ(l, p, init.items);
    const rows = try l.a.alloc(Program.Net, nets.len);
    // §14.2 the module paths, a run per net, and the slots they start at.
    var paths: std.ArrayList(Program.Path) = .empty;
    const path_source = try l.a.alloc(bool, p.slots.len);
    @memset(path_source, false);
    var resolved: std.ArrayList(u64) = .empty;
    var signals: std.ArrayList(net.Signal) = .empty;
    const init_v = try l.a.dupe(u64, p.init_v);
    const init_x = try l.a.dupe(u64, p.init_x);
    for (nets, rows) |n, *row| {
        const ds = p.list(n.drivers);
        const word = p.slots.items(.word)[n.slot];
        const words = Program.words(n.width);
        const sig_at: u32 = @intCast(signals.items.len);
        try signals.appendNTimes(l.a, .{}, n.width);
        const at: u32 = @intCast(resolved.items.len);
        const value = try std_sim.logic.filled(l.a, n.width, false, .z);
        // §7.9 the first resolution (lib/sim/digital's `resolution.initial`);
        // a wreal keeps its 0.0 (VAMS §3.7).
        if (n.kind != .trireg and n.kind != .wreal) {
            const sigs = signals.items[sig_at..][0..n.width];
            if (ds.len == 0) {
                @memset(sigs, net.netPull(n.kind));
            } else {
                const table = net.wiredLogic(n.kind);
                for (0..n.width) |b| {
                    var acc: net.Signal = .{};
                    for (ds) |di| {
                        const d = drivers[di];
                        const dv = p.driver_init[d.init..][0..Program.words(d.width)];
                        const dx = p.driver_init[d.init + Program.words(d.width) ..][0..Program.words(d.width)];
                        const bit = std_sim.logic.planeBit(dv[b / 64] >> @intCast(b % 64), dx[b / 64] >> @intCast(b % 64));
                        const c: net.Signal = if (d.init_or_z and bit != .z) .orZ(bit, d.s0, d.s1) else .of(bit, d.s0, d.s1);
                        acc = if (table) |t| acc.combineWired(c, t) else acc.combine(c);
                    }
                    acc = acc.combine(net.netPull(n.kind));
                    sigs[b] = acc;
                    std_sim.logic.setBit(value, @intCast(b), acc.collapse());
                }
                @memcpy(init_v[word..][0..words], value.values());
                @memcpy(init_x[word..][0..words], value.unknowns());
            }
        }
        try resolved.appendSlice(l.a, value.values());
        try resolved.appendSlice(l.a, value.unknowns());
        row.* = .{
            .kind = n.kind,
            .charge = n.charge,
            .slot = n.slot,
            .drivers = n.drivers,
            .delay = n.delay,
            .decay = n.decay,
            .signal = sig_at,
            .strength_read = n.strength_read,
            .trans = n.trans,
            .paths = .{ .start = @intCast(paths.items.len), .len = @intCast(n.paths.items.len) },
            .ondetect = n.ondetect,
            .showcancelled = n.showcancelled,
            .resolved = at,
            .cold = n.delay.present or n.decay != Program.Net.no_decay or n.paths.items.len != 0,
        };
        for (n.paths.items) |pp| path_source[pp.src] = true;
        try paths.appendSlice(l.a, n.paths.items);
    }
    p.nets = rows;
    p.paths = paths.items;
    if (paths.items.len != 0) p.path_source = path_source;
    p.resolved_init = resolved.items;
    p.signal_init = signals.items;
    p.init_v = init_v;
    p.init_x = init_x;
    const slot_net = try l.a.alloc(u32, p.slots.len);
    @memset(slot_net, none);
    for (nets, 0..) |n, k| slot_net[n.slot] = @intCast(k);
    p.slot_net = slot_net;
    assert(p.slot_net.len == p.slots.len);
    try switchJoined(l, p);
}

// ---- private ----

/// §7.6 every switch-joined net resolved once at time 0, by the run's own
/// group resolution over the drivers' time-0 values (lib/sim/digital's
/// elaboration does the same): its slot, signals and resolution as the
/// group leaves them.
fn switchJoined(l: *Lower, p: *Program) Error!void {
    for (p.nets) |n| {
        if (n.trans.len != 0) break;
    } else return;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var s = std_sim.State.init(l.a, p, &discard.writer) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SimFailed, error.WriteFailed => return l.refuse("a design the runtime cannot start"),
    };
    for (p.nets, 0..) |n, k| if (n.trans.len != 0) std_sim.resolve.resolve(&s, l.a, @intCast(k)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SimFailed, error.WriteFailed => return l.refuse("a switch-joined net the runtime cannot resolve at time 0"),
    };
    p.init_v = s.v;
    p.init_x = s.x;
    p.signal_init = s.signals;
    p.resolved_init = s.net_resolved;
}

/// The bits of each driver no operand value can make other than z are z
/// from the start (iverilog's reading): each driver's value is computed
/// once with every net x, by the run's own evaluator.
fn knownZ(l: *Lower, p: *Program, init: []u64) Error!void {
    if (p.drivers.len == 0) return;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var s = std_sim.State.init(l.a, p, &discard.writer) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SimFailed, error.WriteFailed => return l.refuse("a design the runtime cannot start"),
    };
    for (l.nets.items) |n| {
        const word = p.slots.items(.word)[n.slot];
        const x = try std_sim.logic.filled(l.a, n.width, false, .x);
        @memcpy(s.v[word..][0..x.values().len], x.values());
        @memcpy(s.x[word..][0..x.unknowns().len], x.unknowns());
    }
    for (p.drivers, l.wires.items) |d, w| {
        const words = Program.words(d.width);
        const dv = init[d.init..][0..words];
        const dx = init[d.init + words ..][0..words];
        switch (d.source) {
            .bridge => |b| {
                const zv = try std_sim.logic.filled(l.a, d.width, false, .z);
                for (b.dst_lo..b.dst_lo + b.width + b.ext) |k| std_sim.logic.setBit(zv, @intCast(k), .x);
                @memcpy(dv, zv.values());
                @memcpy(dx, zv.unknowns());
            },
            .expr => |x| {
                l.frame = w.frame;
                if (try calls(l, w.source.expr.value)) continue;
                const v = std_sim.eval.eval(&s, l.a, x.value) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.SimFailed, error.WriteFailed => return l.refuse("a continuous assignment the runtime cannot evaluate at time 0"),
                };
                for (0..d.width) |k| {
                    const from: u32 = if (x.slice) x.lo + @as(u32, @intCast(k)) else @intCast(k);
                    if (v.bit(from) == .z) {
                        dv[k / 64] &= ~(@as(u64, 1) << @intCast(k % 64));
                        dx[k / 64] |= @as(u64, 1) << @intCast(k % 64);
                    }
                }
            },
            else => {}, // else: a gate, switch, UDP or pull starts at its own value
        }
    }
}

/// Whether expression `r` calls a function, user or system.
fn calls(l: *Lower, r: Inst.Ref) Error!bool {
    const i = r.toIndex() orelse return false;
    const vir = l.virOf(l.frame);
    const data = vir.instructions.items(.data)[@backingInt(i)];
    return switch (Lower.tag(vir, i)) {
        .call, .call_sys => true,
        .pos, .neg, .not, .bit_not, .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor => calls(l, data.un_node.operand),
        .add, .sub, .mul, .div, .mod, .pow, .shl, .shr, .ashl, .ashr, .lt, .gt, .lte, .gte, .eq, .neq, .case_eq, .case_neq, .bit_and, .bit_or, .bit_xor, .bit_xnor, .bool_and, .bool_or, .elem, .replicate => blk: {
            const b = Lower.payload(vir, Inst.Bin, i);
            break :blk try calls(l, b.lhs) or try calls(l, b.rhs);
        },
        .ternary, .mintypmax, .slice, .slice_up, .slice_down => blk: {
            const t = Lower.payload(vir, Inst.Triple, i);
            break :blk try calls(l, t.a) or try calls(l, t.b) or try calls(l, t.c);
        },
        .concat => for (vir.list(Inst.Ref, Lower.payload(vir, Inst.Refs, i))) |x| {
            if (try calls(l, x)) break true;
        } else false,
        else => false, // else: a leaf
    };
}
