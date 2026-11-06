//! Nets and their drivers in the digital lowering: net declarations, §6.1
//! continuous assignments, §12.3 port connections (a port joined to the one
//! whole net outside it is that net; any other connection is a driver into
//! the port net or out of it) in; `Program.nets`, `Program.drivers` (each
//! with its `.continuous` instruction, queued at time 0), the time-0 driver
//! values and the nets' §7.9/§7.10 time-0 resolution (`time0.zig`) out.
//! Cites: IEEE 1364-2005 §4.2.1, §4.5, §6.1, §6.1.3, §7.9, §7.10, §12.3.3,
//! §12.3.9.2, §12.3.10, §19.9.
//!
//! Contents:
//! - `pub const NetRow = struct`, `pub const Wire = struct`, `Wire.Source`, `pub const Delay3 = struct`,
//!   `pub const Sink = struct`
//! - `pub fn netKind(k: Inst.NetKind) ?std_sim.net.NetKind`
//! - `pub fn mintNet(l: *Lower, kind: std_sim.net.NetKind, width: u32, signed: bool) Error!u32`
//! - `pub fn retype(l: *Lower, n: u32, kind: net.NetKind) Error!void`
//! - `pub fn promoteWreal(l: *Lower, n: u32) Error!void`
//! - `pub fn internalDominates(internal: net.NetKind, external: net.NetKind) bool`
//! - `pub fn strengths(text: []const u8) [2]std_sim.net.Strength`
//! - `pub fn delay3(l: *Lower, f: u32, d: Inst.Exprs) Error!Delay3`
//! - `pub fn assign(l: *Lower, f: u32, i: Inst.Index) Error!void`
//! - `pub fn drivenNet(l: *Lower, f: u32, target: Inst.Ref, s: [2]std_sim.net.Strength) Error!u32`
//! - `pub fn compileDrivers(l: *Lower) Error!void`
//! - `pub fn sink(l: *Lower, r: Inst.Ref) Error!Sink`
//! - `pub fn delayOf(l: *Lower, d: Delay3, rows: *[3]u32) Error!net.Delay`

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
    /// §7.11 a MOS switch's data terminal: its signal is kept current.
    strength_read: bool = false,
    /// §7.6 the pass switches with it as a terminal (`trans` rows).
    trans: Program.List = .empty,
    /// §14.2 the module paths into it, and §14.6.4's pulse styles.
    paths: std.ArrayList(Program.Path) = .empty,
    ondetect: bool = false,
    showcancelled: bool = false,
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
        /// §19.9 a pull of an unconnected input, or a §7.8 pull source.
        pull: Bit,
        /// A.3.1 a gate: its input expressions, read one bit each (bit
        /// `lane` of an instance array's vector terminal), and its output bit.
        gate: struct { kind: net.GateKind, ins: []const Inst.Ref, lane: ?u32, out_bit: ?u32 },
        /// §7.6 a MOS switch: its data and gate expressions, the net the data
        /// names (`none` for any other expression), the lane and output bit.
        mos: struct { data: Inst.Ref, gate: Inst.Ref, data_net: u32, n_type: bool, resistive: bool, lane: ?u32, out_bit: ?u32 },
        /// §8 a UDP instance: table `udp` (a `Program.udps` row), its input
        /// expressions, the lane and output bit, its time-0 state.
        udp: struct { udp: u32, ins: []const Inst.Ref, sequential: bool, lane: ?u32, out_bit: ?u32, state: Bit },
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
/// undriven value (VAMS §3.7: a `wreal` holds a real, 0.0). Returns its
/// `nets` row.
pub fn mintNet(l: *Lower, kind: net.NetKind, width: u32, signed: bool) Error!u32 {
    const wreal = kind == .wreal;
    const bits: u32 = if (wreal) 64 else width;
    const t = if (wreal) Program.Ty.real_ty else try l.tyOf(.{ .width = width, .signed = signed });
    const words = Program.words(bits);
    const value = try std_sim.logic.filled(l.a, bits, signed, if (wreal) .zero else undriven(kind));
    const slot = try l.b.slot(t, try l.a.dupe(u64, value.values()[0..words]), try l.a.dupe(u64, value.unknowns()[0..words]));
    const at: u32 = @intCast(l.nets.items.len);
    try l.nets.append(l.a, .{ .kind = kind, .slot = slot, .width = bits });
    try l.slot_net.put(l.a, slot, at);
    return at;
}

/// §12.3.10.1 net `n` takes type `kind` (a port's that dominates it), and
/// that type's undriven value at time 0.
pub fn retype(l: *Lower, n: u32, kind: net.NetKind) Error!void {
    const row = &l.nets.items[n];
    row.kind = kind;
    const word = l.b.p.slots.items(.word)[row.slot];
    const words = Program.words(row.width);
    const value = try std_sim.logic.filled(l.a, row.width, false, undriven(kind));
    @memcpy(l.b.init_v.items[word..][0..words], value.values()[0..words]);
    @memcpy(l.b.init_x.items[word..][0..words], value.unknowns()[0..words]);
}

/// VAMS §3.7's port merge: a wire or tri joined to a wreal port becomes one
/// wreal net (a real, 0.0 undriven) for every connection to it, the names
/// already bound to it included.
pub fn promoteWreal(l: *Lower, n: u32) Error!void {
    const row = &l.nets.items[n];
    assert(row.kind != .wreal);
    if (Program.words(row.width) != 1) return l.refuse("VAMS §3.7 a vector net joined to a wreal port");
    row.kind = .wreal;
    row.width = 64;
    l.b.p.slots.items(.ty)[row.slot] = Program.Ty.real_ty;
    const word = l.b.p.slots.items(.word)[row.slot];
    l.b.init_v.items[word] = 0;
    l.b.init_x.items[word] = 0;
    for (l.names.items) |*name| if (name.kind == .net and name.net == n) {
        name.ty = digital.Type.real_type;
    };
    assert(l.b.p.slots.items(.ty)[row.slot].real);
}

/// §12.3.10 Table 12-1's "int" cells: whether a port net of type
/// `internal` joined to a net of type `external` gives the merged net its
/// own type.
pub fn internalDominates(internal: net.NetKind, external: net.NetKind) bool {
    const wire = external == .wire or external == .tri;
    return switch (internal) {
        .wire, .tri, .wreal => false,
        .wand, .triand, .wor, .trior, .trireg => wire,
        .tri0, .tri1 => wire or external == .trireg,
        .uwire => wire or switch (external) {
            .wand, .triand, .wor, .trior, .trireg, .tri0, .tri1 => true,
            else => false, // else: uwire, the supplies and wreal are "ext" in the uwire row
        },
        .supply0, .supply1 => switch (external) {
            .supply0, .supply1, .wreal => false,
            else => true, // else: every non-supply column of the supply rows is "int"
        },
    };
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
    var udp_bits: std.ArrayList(Bit) = .empty;
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
            .gate => |g| blk: {
                const rows = try l.a.alloc(u32, g.ins.len);
                // VAMS §7.8.5.1 an array lane reads its own bridge's segment.
                l.gate_lane = g.lane orelse 0;
                defer l.gate_lane = none;
                for (g.ins, rows) |x, *row| {
                    row.* = try expr.self_(l, x, 1);
                    try expr.reads(l, x, &sensitivity);
                }
                break :blk .{ .gate = .{ .kind = g.kind, .ins = try l.b.listOf(rows), .lane = g.lane, .out_bit = g.out_bit } };
            },
            .mos => |m| blk: {
                const data = try expr.self_(l, m.data, 1);
                const gate = try expr.self_(l, m.gate, 1);
                try expr.reads(l, m.data, &sensitivity);
                try expr.reads(l, m.gate, &sensitivity);
                break :blk .{ .mos = .{ .data = data, .gate = gate, .data_net = m.data_net, .n_type = m.n_type, .resistive = m.resistive, .lane = m.lane, .out_bit = m.out_bit } };
            },
            .udp => |u| blk: {
                const rows = try l.a.alloc(u32, u.ins.len);
                for (u.ins, rows) |x, *row| {
                    row.* = try expr.self_(l, x, 1);
                    try expr.reads(l, x, &sensitivity);
                }
                // §8.6 the inputs it last saw: none yet.
                const prev: Program.List = .{ .start = @intCast(udp_bits.items.len), .len = @intCast(u.ins.len) };
                try udp_bits.appendNTimes(l.a, .x, u.ins.len);
                break :blk .{ .udp = .{ .udp = u.udp, .ins = try l.b.listOf(rows), .sequential = u.sequential, .lane = u.lane, .out_bit = u.out_bit, .state = u.state, .started = false, .prev = prev } };
            },
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
    l.b.p.udp_bits = udp_bits.items;
    // Per net its drivers, in driver order.
    const runs = try l.a.alloc(std.ArrayList(u32), l.nets.items.len);
    @memset(runs, .empty);
    for (l.wires.items, 0..) |w, k| try runs[w.net].append(l.a, @intCast(k));
    for (l.nets.items, runs) |*n, run| n.drivers = try l.b.listOf(run.items);
}

/// The net bits lvalue operand `r` names: a whole net (or net array
/// element), or a constant bit- or part-select of a vector net.
pub fn sink(l: *Lower, r: Inst.Ref) Error!Sink {
    const vir = l.virOf(l.frame);
    const i = r.toIndex() orelse return l.refuse("an omitted net lvalue");
    switch (Lower.tag(vir, i)) {
        .decl_ref, .str_ref, .field => {
            const n = (try expr.nameOf(l, r)) orelse return l.refuse("a continuous assignment to a hierarchical net");
            if (n.kind != .net) return l.refuse("a continuous assignment to a variable");
            if (n.dims.len != 0) return l.refuse("a continuous assignment to a whole net array");
            return .{ .net = n.net, .lo = 0, .width = l.nets.items[n.net].width };
        },
        .elem, .slice, .slice_up, .slice_down => {
            const s = try place.selectOf(l, i);
            if (s.name.kind != .net) return l.refuse("a continuous assignment to a variable");
            // §4.9.1 a net array element is a net of its own.
            const at = if (s.name.dims.len == 0) s.name.net else try elementNet(l, s);
            if (s.whole_elem) return .{ .net = at, .lo = 0, .width = l.nets.items[at].width };
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
            const w = l.nets.items[at].width;
            if (first < 0 or first + s.count > w) return l.refuse("§12.3.9.2 a select outside its net");
            return .{ .net = at, .lo = @intCast(first), .width = s.count };
        },
        // A.8.5 a one-operand concatenation is its operand (`tran ({a}, b)`).
        .concat => {
            const ops = vir.list(Inst.Ref, Lower.payload(vir, Inst.Refs, i));
            if (ops.len != 1) return l.refuse("a continuous assignment to an expression");
            return sink(l, ops[0]);
        },
        else => return l.refuse("a continuous assignment to an expression"),
    }
}

/// A delay's constant ticks (`present`), or its rows read when it
/// schedules (`rows`, with `present` and zero ticks).
pub fn delayOf(l: *Lower, d: Delay3, rows: *[3]u32) Error!net.Delay {
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

// ---- private ----

/// §4.2.1 a net type's value with no driver.
fn undriven(kind: net.NetKind) Bit {
    return switch (kind) {
        .supply0, .tri0 => .zero,
        .supply1, .tri1 => .one,
        .trireg => .x,
        .wire, .tri, .triand, .trior, .wand, .wor, .uwire, .wreal => .z,
    };
}

fn concatLeaves(l: *Lower, r: Inst.Ref, out: *std.ArrayList(Inst.Ref)) Error!void {
    const vir = l.virOf(l.frame);
    const i = r.toIndex() orelse return l.refuse("an omitted net lvalue");
    if (Lower.tag(vir, i) != .concat) return out.append(l.a, r);
    for (vir.list(Inst.Ref, Lower.payload(vir, Inst.Refs, i))) |x| try concatLeaves(l, x, out);
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

/// The net row of net array element `s` (constant indices, row-major as
/// `std_sim.eval.address` reads them: the last dimension innermost).
fn elementNet(l: *Lower, s: place.Sel) Error!u32 {
    const dims = s.name.dims;
    assert(dims.len != 0 and s.indices.len >= dims.len);
    var at: u64 = 0;
    var stride: u64 = 1;
    var k = dims.len;
    while (k != 0) {
        k -= 1;
        const idx = try l.intOf(l.frame, s.indices[k]);
        if (idx < dims[k].low or idx > dims[k].high) return l.refuse("§12.3.9.2 a net array index outside its array");
        at += stride * @as(u64, @intCast(idx - dims[k].low));
        stride *= @as(u64, @intCast(dims[k].high - dims[k].low + 1));
    }
    assert(at < s.name.count);
    return s.name.net + @as(u32, @intCast(at));
}
