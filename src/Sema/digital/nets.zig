//! Nets and their drivers in the digital lowering: net declarations, §6.1
//! continuous assignments, §12.3 port connections (a port joined to the one
//! whole net outside it is that net; any other connection is a driver into
//! the port net or out of it) in; `Program.nets`, `Program.drivers` (each
//! with its `.continuous` instruction, queued at time 0), the time-0 driver
//! values (unknown, save the bits no operand can make other than z) and the
//! nets' §7.9/§7.10 time-0 resolution out.
//! Cites: IEEE 1364-2005 §4.2.1, §4.5, §6.1, §6.1.3, §7.9, §7.10, §12.3.3,
//! §12.3.9.2, §12.3.10, §19.9.
//!
//! Contents:
//! - `pub const NetRow = struct`, `pub const Wire = struct`, `Wire.Source`, `pub const Delay3 = struct`,
//!   `pub const Sink = struct`
//! - `pub fn netKind(k: Inst.NetKind) ?std_sim.net.NetKind`
//! - `pub fn mintNet(l: *Lower, kind: std_sim.net.NetKind, width: u32, signed: bool) Error!u32`
//! - `pub fn strengths(text: []const u8) [2]std_sim.net.Strength`
//! - `pub fn delay3(l: *Lower, f: u32, d: Inst.Exprs) Error!Delay3`
//! - `pub fn assign(l: *Lower, f: u32, i: Inst.Index) Error!void`
//! - `pub fn drivenNet(l: *Lower, f: u32, target: Inst.Ref, s: [2]std_sim.net.Strength) Error!u32`
//! - `pub fn compileDrivers(l: *Lower) Error!void`
//! - `pub fn finish(l: *Lower, p: *Program) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const std_sim = @import("std_sim");
const digital = @import("../digital.zig");
const expr = @import("expr.zig");
const place = @import("place.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const Name = digital.Name;
const none = digital.none;
const Program = std_sim.Program;
const net = std_sim.net;
const Bit = std_sim.logic.Bit;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// One net: its type, its slot and width, A.2.1.3's constant `delay3`
/// (a trireg's third value its charge decay) and a trireg's charge.
pub const NetRow = struct {
    kind: net.NetKind,
    charge: net.Strength = .medium,
    slot: u32,
    width: u32,
    delay: net.Delay = .{},
    decay: u64 = Program.Net.no_decay,
    /// Its drivers (`drivers` rows, in driver order), set once all exist.
    drivers: Program.List = .empty,
};

/// One driver of a net, compiled after the walk: what it asserts, in
/// frame `frame` (its expression's names), at A.2.2.2's strengths, after
/// its A.6.1 delay.
pub const Wire = struct {
    net: u32,
    frame: u32,
    source: Source,
    s0: net.Strength = .strong,
    s1: net.Strength = .strong,
    delay: Delay3 = .{},

    pub const Source = union(enum) {
        /// A.6.1 an expression; with `slice`, read `total` bits wide and
        /// bits [lo, lo + net width) asserted.
        expr: struct { value: Inst.Ref, slice: bool = false, lo: u32 = 0, total: u32 = 0 },
        /// §6.5.7.1 a port window (`Program.Driver.Source.bridge`).
        bridge: struct { src: u32, src_lo: u32, dst_lo: u32, width: u32, ext: u32 = 0, sign_at: ?u32 = null },
        /// §19.9 a pull of an unconnected input.
        pull: Bit,
    };
};

/// A.2.2.3 `delay3`: up to three values of frame `frame` (`none` absent).
pub const Delay3 = struct {
    frame: u32 = none,
    values: [3]Inst.Ref = .{ .none, .none, .none },
};

/// `width` bits of net `net` from bit `lo` up: one operand of a structural
/// net expression.
pub const Sink = struct { net: u32, lo: u32, width: u32 };

/// The net type a Vir net kind is, or null for one the digital engine has
/// no table for (`ground`, a discipline's own).
pub fn netKind(k: Inst.NetKind) ?net.NetKind {
    return switch (k) {
        .none, .ground => null,
        inline else => |t| @field(net.NetKind, @tagName(t)),
    };
}

/// A new net of `kind`, `width` bits, on a slot of its own holding §4.2.1's
/// undriven value. Returns its `nets` row.
pub fn mintNet(l: *Lower, kind: net.NetKind, width: u32, signed: bool) Error!u32 {
    const fill: Bit = switch (kind) {
        .supply0, .tri0 => .zero,
        .supply1, .tri1 => .one,
        .trireg => .x,
        .wire, .tri, .triand, .trior, .wand, .wor, .uwire, .wreal => .z,
    };
    if (kind == .wreal) return l.refuse("a wreal net");
    const t = try l.tyOf(.{ .width = width, .signed = signed });
    const words = Program.words(width);
    const v = try l.a.alloc(u64, words);
    const x = try l.a.alloc(u64, words);
    const value = try std_sim.logic.filled(l.a, width, signed, fill);
    @memcpy(v, value.values());
    @memcpy(x, value.unknowns());
    const slot = try l.b.slot(t, v, x);
    const at: u32 = @intCast(l.nets.items.len);
    try l.nets.append(l.a, .{ .kind = kind, .slot = slot, .width = width });
    try l.slot_net.put(l.a, slot, at);
    return at;
}

/// A.2.2.2 a strength group's words (`strong0,pull1`; empty: strong).
pub fn strengths(text: []const u8) [2]net.Strength {
    var out: [2]net.Strength = .{ .strong, .strong };
    var it = std.mem.tokenizeScalar(u8, text, ',');
    while (it.next()) |w| {
        if (w.len < 2) continue;
        const side: usize = if (w[w.len - 1] == '1') 1 else if (w[w.len - 1] == '0') 0 else continue;
        out[side] = std.meta.stringToEnum(net.Strength, w[0 .. w.len - 1]) orelse continue;
    }
    return out;
}

/// The `delay3` of an `Exprs` written in frame `f`.
pub fn delay3(l: *Lower, f: u32, d: Inst.Exprs) Error!Delay3 {
    const vir = l.virOf(f);
    const values = vir.list(Inst.Ref, d.values);
    if (values.len > 3) return l.refuse("a delay of more than three values");
    var out: Delay3 = .{ .frame = f };
    for (values, 0..) |r, k| out.values[k] = r;
    return out;
}

/// §6.1 a continuous assignment of frame `f`: one driver of the net its
/// target names (of a net of its own bridged onto a select's bits).
pub fn assign(l: *Lower, f: u32, i: Inst.Index) Error!void {
    const vir = l.virOf(f);
    const a = Lower.payload(vir, Inst.Assign, i);
    const s = strengths(vir.string(a.strength));
    const lhs = vir.body(a.lhs);
    const rhs = vir.body(a.rhs);
    const target = try drivenNet(l, f, lhs[lhs.len - 1].toRef(), s);
    try l.wires.append(l.a, .{ .net = target, .frame = f, .source = .{ .expr = .{ .value = rhs[rhs.len - 1].toRef() } }, .s0 = s[0], .s1 = s[1], .delay = try delay3(l, f, a.delay) });
}

/// The net a continuous assignment or an output terminal of frame `f`
/// drives: one whole net, or a new net bridged onto the bits of each
/// operand of a select or concatenation (§12.3.9.2), its bridges at the
/// assignment's strengths.
pub fn drivenNet(l: *Lower, f: u32, target: Inst.Ref, s: [2]net.Strength) Error!u32 {
    const saved = l.frame;
    defer l.frame = saved;
    l.frame = f;
    var leaves: std.ArrayList(Inst.Ref) = .empty;
    try concatLeaves(l, target, &leaves);
    var operands: std.ArrayList(Sink) = .empty;
    var width: u32 = 0;
    for (leaves.items) |x| {
        const k = try sink(l, x);
        width += k.width;
        try operands.append(l.a, k);
    }
    if (operands.items.len == 1 and operands.items[0].lo == 0 and operands.items[0].width == l.nets.items[operands.items[0].net].width) return operands.items[0].net;
    const n = try mintNet(l, .wire, width, false);
    const first = l.wires.items.len;
    try sendPort(l, f, operands.items, l.nets.items[n].slot, width, false);
    for (l.wires.items[first..]) |*w| {
        w.s0 = s[0];
        w.s1 = s[1];
    }
    return n;
}

/// Compiles every driver's expression and delay (in its frame) and appends
/// its `.continuous` instruction; the drivers' pcs come first, each queued
/// at time 0 in driver order.
pub fn compileDrivers(l: *Lower) Error!void {
    const out = try l.a.alloc(Program.Driver, l.wires.items.len);
    for (l.wires.items, out, 0..) |w, *d, k| {
        l.frame = w.frame;
        const scope = l.frames.items[w.frame].scope;
        const n = l.nets.items[w.net];
        var sensitivity: std.ArrayList(u32) = .empty;
        const source: Program.Driver.Source = switch (w.source) {
            .expr => |x| blk: {
                try expr.reads(l, x.value, &sensitivity);
                const nt = l.b.p.slots.items(.ty)[n.slot];
                const value = if (x.slice) try expr.self_(l, x.value, x.total) else try expr.evalFor(l, x.value, .{ .width = nt.width, .signed = nt.signed, .real = nt.real });
                break :blk .{ .expr = .{ .value = value, .slice = x.slice, .lo = x.lo, .total = x.total } };
            },
            .bridge => |b| blk: {
                try sensitivity.append(l.a, b.src);
                break :blk .{ .bridge = .{ .src = b.src, .src_lo = b.src_lo, .dst_lo = b.dst_lo, .width = b.width, .ext = b.ext, .sign_at = b.sign_at } };
            },
            .pull => |bit| .{ .pull = bit },
        };
        var rows: [3]u32 = .{ none, none, none };
        const dl = try delayOf(l, w.delay, &rows);
        d.* = .{
            .net = w.net,
            .scope = scope,
            .s0 = w.s0,
            .s1 = w.s1,
            .delay = dl,
            .delay_rows = rows,
            .width = n.width,
            .init = 0,
            .init_or_z = false,
            .source = source,
            .sensitivity = try l.b.listOf(sensitivity.items),
        };
        const pc = try l.b.inst(.continuous, @intCast(k), 0, scope);
        try l.driver_pcs.append(l.a, pc);
    }
    l.b.p.drivers = out;
    // Per net its drivers, in driver order.
    const runs = try l.a.alloc(std.ArrayList(u32), l.nets.items.len);
    @memset(runs, .empty);
    for (l.wires.items, 0..) |w, k| try runs[w.net].append(l.a, @intCast(k));
    for (l.nets.items, runs) |*n, run| n.drivers = try l.b.listOf(run.items);
}

/// Writes the nets' and drivers' tables into finished program `p`: each
/// driver's time-0 value (x, save the bits a constant z holds, read with
/// every net x), each net's §7.9 time-0 resolution (its signals, its
/// resolved value, its slot's value), and per slot its net.
pub fn finish(l: *Lower, p: *Program) Error!void {
    const nets = l.nets.items;
    const drivers = @constCast(p.drivers);
    // Each driver's time-0 value, unknown.
    var init: std.ArrayList(u64) = .empty;
    for (drivers) |*d| {
        d.init = @intCast(init.items.len);
        const v = try std_sim.logic.filled(l.a, d.width, false, .x);
        try init.appendSlice(l.a, v.values());
        try init.appendSlice(l.a, v.unknowns());
    }
    p.driver_init = init.items;
    try knownZ(l, p, init.items);
    const rows = try l.a.alloc(Program.Net, nets.len);
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
        // §7.9 the first resolution (lib/sim/digital's `resolution.initial`).
        if (n.kind != .trireg) {
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
            .resolved = at,
            .cold = n.delay.present or n.decay != Program.Net.no_decay,
        };
    }
    p.nets = rows;
    p.resolved_init = resolved.items;
    p.signal_init = signals.items;
    p.init_v = init_v;
    p.init_x = init_x;
    const slot_net = try l.a.alloc(u32, p.slots.len);
    @memset(slot_net, none);
    for (nets, 0..) |n, k| slot_net[n.slot] = @intCast(k);
    p.slot_net = slot_net;
}

// ---- private ----

/// A delay's constant ticks (`present`), or its rows read when it
/// schedules (`rows`, with `present` and zero ticks).
fn delayOf(l: *Lower, d: Delay3, rows: *[3]u32) Error!net.Delay {
    if (d.values[0] == .none) return .{};
    const f = d.frame;
    var constant = true;
    var ticks: [3]u64 = .{ 0, 0, 0 };
    const scale = l.b.times.items[l.frames.items[f].scope].scale;
    for (d.values, 0..) |r, k| {
        if (r == .none) continue;
        const c = (try l.constOf(f, r)) orelse {
            constant = false;
            continue;
        };
        ticks[k] = switch (c) {
            .int => |v| scale.signedDelay(v) catch return l.refuse("a delay past 2^64 ticks"),
            .real => |v| scale.realDelay(v) catch return l.refuse("a delay past 2^64 ticks"),
            .str => return l.refuse("a string delay"),
        };
    }
    if (!constant) {
        const saved = l.frame;
        defer l.frame = saved;
        l.frame = f;
        for (d.values, 0..) |r, k| if (r != .none) {
            rows[k] = try expr.selfOrReal(l, r);
        };
        return .{ .present = true };
    }
    var out: net.Delay = .{ .present = true, .rise = ticks[0], .fall = ticks[0] };
    if (d.values[1] != .none) out.fall = ticks[1];
    out.off = if (d.values[2] != .none) ticks[2] else @min(out.rise, out.fall);
    return out;
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

fn concatLeaves(l: *Lower, r: Inst.Ref, out: *std.ArrayList(Inst.Ref)) Error!void {
    const vir = l.virOf(l.frame);
    const i = r.toIndex() orelse return l.refuse("an omitted net lvalue");
    if (Lower.tag(vir, i) != .concat) return out.append(l.a, r);
    for (vir.list(Inst.Ref, Lower.payload(vir, Inst.Refs, i))) |x| try concatLeaves(l, x, out);
}

/// The net bits lvalue operand `r` names: a whole net (or net array
/// element), or a constant bit- or part-select of a vector net.
fn sink(l: *Lower, r: Inst.Ref) Error!Sink {
    const vir = l.virOf(l.frame);
    const i = r.toIndex() orelse return l.refuse("an omitted net lvalue");
    switch (Lower.tag(vir, i)) {
        .decl_ref, .str_ref => {
            const n = (try expr.nameOf(l, r)) orelse return l.refuse("a continuous assignment to a hierarchical net");
            if (n.kind != .net) return l.refuse("a continuous assignment to a variable");
            if (n.dims.len != 0) return l.refuse("a continuous assignment to a whole net array");
            return .{ .net = n.net, .lo = 0, .width = l.nets.items[n.net].width };
        },
        .elem, .slice, .slice_up, .slice_down => {
            const s = try place.selectOf(l, i);
            if (s.name.kind != .net) return l.refuse("a continuous assignment to a variable");
            if (s.name.dims.len != 0) return l.refuse("a continuous assignment to a net array element");
            const first: i64 = switch (s.mode) {
                .const_part => s.first,
                .bit, .up, .down => blk: {
                    const idx = try l.intOf(l.frame, s.index);
                    const n = s.name;
                    const ascending = n.msb >= n.lsb;
                    const p = if (ascending) idx -| n.lsb else n.lsb -| idx;
                    break :blk if (s.mode == .bit) p else if (ascending == (s.mode == .up)) p else p -| (s.count - 1);
                },
            };
            const w = l.nets.items[s.name.net].width;
            if (first < 0 or first + s.count > w) return l.refuse("§12.3.9.2 a select outside its net");
            return .{ .net = s.name.net, .lo = @intCast(first), .width = s.count };
        },
        else => return l.refuse("a continuous assignment to an expression"),
    }
}

/// §12.3.9.2 a port (or anonymous net) `src` of `width` bits driving the
/// operands it is connected to, the rightmost operand its low bits: a
/// bridge per operand, widened (zero, or `signed`'s sign) past the port.
fn sendPort(l: *Lower, f: u32, operands: []const Sink, src: u32, width: u32, signed: bool) Error!void {
    var lo: u32 = 0;
    var k = operands.len;
    while (k != 0) {
        k -= 1;
        const op = operands[k];
        const copy = @min(op.width, width - lo);
        try l.wires.append(l.a, .{ .net = op.net, .frame = f, .source = .{ .bridge = .{
            .src = src,
            .src_lo = lo,
            .dst_lo = op.lo,
            .width = copy,
            .ext = op.width - copy,
            .sign_at = if (signed and width != 0) width - 1 else null,
        } } });
        lo += copy;
    }
}
