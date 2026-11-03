//! The bridge's netlist half (docs/rewrite/sim.md): the old `Run`'s nets,
//! drivers, module paths and switches in, `Program.nets`, `drivers`,
//! `paths` and `trans` out, each driver's time-0 value and state as
//! elaboration left it.
//! Cites: IEEE 1364-2005 §6.1, §7, §8, §14.3 (through lib/sim/digital).
//!
//! Contents:
//! - `pub fn netlist(l: *Lower) E!void`

const std = @import("std");
const sim = @import("sim");
const std_sim = @import("std_sim");
const digital = sim.digital;
const Program = std_sim.Program;
const net = std_sim.net;
const logic = std_sim.logic;
const lower = @import("lower.zig");
const Lower = lower.Lower;
const E = lower.E;

/// §7.9 every net and §6.1/§7 every driver, as `Program.nets` and
/// `Program.drivers`, each driver's time-0 value and state as elaboration
/// left it.
pub fn netlist(l: *Lower) E!void {
    const r = l.r;
    const b = l.b;
    const nets = try b.arena.alloc(Program.Net, r.netlist.nets.len);
    var paths: std.ArrayList(Program.Path) = .empty;
    var resolved: std.ArrayList(u64) = .empty;
    const path_source = try b.arena.alloc(bool, r.values.len);
    @memset(path_source, false);
    for (r.netlist.nets, nets, 0..) |n, *out, k| {
        const cold = r.netCold(n);
        const width = n.resolved.width;
        const resolved_at: u32 = @intCast(resolved.items.len);
        try resolved.appendSlice(b.arena, n.resolved.values()[0..Program.words(width)]);
        try resolved.appendSlice(b.arena, n.resolved.unknowns()[0..Program.words(width)]);
        const first: u32 = @intCast(paths.items.len);
        for (cold.paths) |path| {
            path_source[path.src] = true;
            var edge: Program.Edge = .any;
            switch (path.edge) {
                .none => {},
                .posedge => edge = .posedge,
                .negedge => edge = .negedge,
                else => return l.refuse("a module path edge other than posedge/negedge"), // else: no other edge reaches a path
            }
            r.scope = path.scope;
            const cond: u32 = if (path.cond == .none) @backingInt(Program.Ref.none) else try l.self_(path.cond, 0);
            var delays: std.ArrayList(u32) = .empty;
            for (path.delays) |d| try delays.append(l.a, try l.selfOrReal(d));
            try paths.append(b.arena, .{ .src = path.src, .src_bit = path.src_bit, .edge = edge, .cond = cond, .ifnone = path.ifnone, .scope = path.scope, .table = path.table, .reject = path.reject, .err = path.err, .delays = try b.listOf(delays.items) });
        }
        out.* = .{
            .kind = std.meta.stringToEnum(net.NetKind, @tagName(n.kind)).?,
            .charge = @fromBackingInt(@intCast(@backingInt(n.charge))),
            .slot = n.slot,
            .drivers = try b.listOf(r.netDrivers(@intCast(k))),
            .delay = delay(cold.delay),
            .decay = cold.decay orelse Program.Net.no_decay,
            .paths = .{ .start = first, .len = @intCast(cold.paths.len) },
            .ondetect = cold.ondetect,
            .showcancelled = cold.showcancelled,
            .trans = try b.listOf(cold.trans),
            .signal = n.signal,
            .strength_read = n.strength_read,
            .resolved = resolved_at,
            .cold = n.cold != digital.for_emitter.net.no_cold,
        };
    }
    b.p.resolved_init = resolved.items;
    const signals = try b.arena.alloc(net.Signal, r.netlist.signals.len);
    for (r.netlist.signals, signals) |sig, *o| o.* = .{ .lo = sig.lo, .hi = sig.hi };
    b.p.signal_init = signals;
    const none = @backingInt(Program.Ref.none);
    const trans = try b.arena.alloc(Program.Tran, r.netlist.switches.len);
    for (r.netlist.switches, trans) |t, *o| o.* = .{
        .a = t.a,
        .b = t.b,
        .a_bit = t.a_bit,
        .b_bit = t.b_bit,
        .ctrl = none,
        .on = @fromBackingInt(@intCast(@backingInt(t.on))),
        .resistive = t.resistive,
        .delay = delay(t.delay),
        .delay_rows = .{ none, none, none },
        .state = std.meta.stringToEnum(net.TranState, @tagName(t.state)).?,
    };
    b.p.trans = trans;
    b.p.paths = paths.items;
    if (paths.items.len != 0) b.p.path_source = path_source;
    var init: std.ArrayList(u64) = .empty;
    var udp_bits: std.ArrayList(logic.Bit) = .empty;
    var udps: std.ArrayList([]const net.UdpRow) = .empty;
    var tables: std.AutoHashMapUnmanaged(usize, u32) = .empty;
    const drivers = try b.arena.alloc(Program.Driver, r.netlist.drivers.len);
    for (r.netlist.drivers, drivers, 0..) |d, *out, k| {
        r.scope = d.scope;
        const n = r.netlist.nets[d.net];
        const width = d.current.width;
        const words = Program.words(width);
        const at: u32 = @intCast(init.items.len);
        try init.appendSlice(b.arena, d.current.values()[0..words]);
        try init.appendSlice(b.arena, d.current.unknowns()[0..words]);
        var rows: [3]u32 = .{ none, none, none };
        if (r.netlist.driver_delays.get(@intCast(k))) |d3| {
            rows[0] = try l.selfOrReal(d3.rise);
            if (d3.fall != .none) rows[1] = try l.selfOrReal(d3.fall);
            if (d3.off != .none) rows[2] = try l.selfOrReal(d3.off);
        }
        const source: Program.Driver.Source = switch (d.source) {
            .expr => |x| if (x.slice) |sl|
                .{ .expr = .{ .value = try l.self_(x.e, sl.total), .slice = true, .lo = sl.lo, .total = sl.total } }
            else
                .{ .expr = .{ .value = try l.evalFor(x.e, r.slotType(n.slot)), .slice = false, .lo = 0, .total = 0 } },
            .bridge => |br| .{ .bridge = .{ .src = br.src, .src_lo = br.src_lo, .dst_lo = br.dst_lo, .width = br.width, .ext = br.ext, .sign_at = br.sign_at } },
            .gate => |g| .{ .gate = .{ .kind = std.meta.stringToEnum(net.GateKind, @tagName(g.kind)).?, .ins = try inputRows(l, g.ins), .lane = g.lane, .out_bit = g.out_bit } },
            .udp => |u| blk: {
                const key = @intFromPtr(u.rows.ptr);
                const table = tables.get(key) orelse t: {
                    const copy = try b.arena.alloc(net.UdpRow, u.rows.len);
                    for (u.rows, copy) |row, *c| {
                        const syms = try b.arena.alloc(net.UdpSym, row.ins.len);
                        for (row.ins, syms) |sym, *y| y.* = switch (sym) {
                            .level => |v| .{ .level = v },
                            .pair => |v| .{ .pair = v },
                            .letter => |v| .{ .letter = v },
                        };
                        c.* = .{ .ins = syms, .state = row.state, .out = row.out, .edge_at = row.edge_at };
                    }
                    try udps.append(b.arena, copy);
                    const id: u32 = @intCast(udps.items.len - 1);
                    try tables.put(b.arena, key, id);
                    break :t id;
                };
                const prev_start: u32 = @intCast(udp_bits.items.len);
                for (u.prev) |bit| try udp_bits.append(b.arena, @fromBackingInt(@intCast(@backingInt(bit))));
                break :blk .{ .udp = .{
                    .udp = table,
                    .ins = try inputRows(l, u.ins),
                    .sequential = u.sequential,
                    .lane = u.lane,
                    .out_bit = u.out_bit,
                    .state = @fromBackingInt(@intCast(@backingInt(u.state))),
                    .started = u.started,
                    .prev = .{ .start = prev_start, .len = @intCast(u.prev.len) },
                } };
            },
            .mos => |m| blk: {
                const ex = &r.file.exprs;
                var data_net: u32 = none;
                if (ex.tag(m.data) == .ident) if (r.netlist.slot_nets.get(r.slot(m.data) catch return l.refuse("a MOS data name the old engine refuses"))) |dn| {
                    data_net = dn;
                };
                break :blk .{ .mos = .{ .data = try l.self_(m.data, 1), .gate = try l.self_(m.gate, 1), .data_net = data_net, .n_type = m.n_type, .resistive = m.resistive, .lane = m.lane, .out_bit = m.out_bit } };
            },
            .pull => |bit| .{ .pull = @fromBackingInt(@intCast(@backingInt(bit))) },
        };
        out.* = .{
            .net = d.net,
            .scope = d.scope,
            .s0 = @fromBackingInt(@intCast(@backingInt(d.s0))),
            .s1 = @fromBackingInt(@intCast(@backingInt(d.s1))),
            .delay = delay(d.delay),
            .delay_rows = rows,
            .width = width,
            .init = at,
            .init_or_z = d.or_z,
            .source = source,
            .sensitivity = try b.listOf(d.sensitivity),
        };
    }
    b.p.nets = nets;
    const slot_net = try b.arena.alloc(u32, r.values.len);
    for (slot_net, 0..) |*sn, k| sn.* = r.netlist.slot_nets.get(@intCast(k)) orelse std.math.maxInt(u32);
    b.p.slot_net = slot_net;
    b.p.drivers = drivers;
    b.p.driver_init = init.items;
    b.p.udps = udps.items;
    b.p.udp_bits = udp_bits.items;
}

// ---- private ----

fn delay(d: anytype) net.Delay {
    return .{ .rise = d.rise, .fall = d.fall, .off = d.off, .present = d.present };
}

/// A gate's or UDP's input rows: each read one bit wide (`eval(in, 1)`).
fn inputRows(l: *Lower, exprs: anytype) E!Program.List {
    var rows: std.ArrayList(u32) = .empty;
    for (exprs) |e| try rows.append(l.a, try l.self_(e, 1));
    return l.b.listOf(rows.items);
}
