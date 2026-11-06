//! Gates, switches, pull sources and UDPs of the digital lowering: a
//! gate-level or UDP `instance` (A.3.1, A.5.4) in; per output, and per
//! instance of an array, a driver of the net its output terminal names (a
//! gate, a MOS switch, a pull, a UDP), or a `Program.trans` row joining two
//! nets' bits (a pass switch, controlled by a `switch_ctrl` process), out.
//! As lib/sim/digital builds them: an array's lane `j` (0 the leftmost
//! index) is bit `lanes - 1 - j` of a terminal as wide as the array, a
//! scalar terminal shared by all.
//! Cites: IEEE 1364-2005 §7.1, §7.1.5, §7.1.6, §7.6, §7.8, §7.11, §7.14, §8.
//!
//! Contents:
//! - `pub const TranRow = struct`
//! - `pub fn instance(l: *Lower, f: u32, i: Inst.Index) Error!void`
//! - `pub fn udp(l: *Lower, f: u32, i: Inst.Index, d: Zcu.Decl) Error!void`
//! - `pub fn compileTrans(l: *Lower) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const std_sim = @import("std_sim");
const Zcu = @import("../../Zcu.zig");
const digital = @import("../digital.zig");
const vars = @import("vars.zig");
const expr = @import("expr.zig");
const nets = @import("nets.zig");
const ports = @import("ports.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const none = digital.none;
const Program = std_sim.Program;
const net = std_sim.net;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// A pass switch (`tran`, or one controlled by `ctrl`, written in frame
/// `frame`), its delay, and once compiled its `switch_ctrl` pc and the
/// slots whose change wakes it.
pub const TranRow = struct {
    tran: Program.Tran,
    ctrl: Inst.Ref,
    frame: u32,
    delay: nets.Delay3,
    pc: u32 = none,
    sensitivity: Program.List = .empty,
};

/// Gate-level instance `i` of frame `f`, by its keyword.
pub fn instance(l: *Lower, f: u32, i: Inst.Index) Error!void {
    l.sink_use = .gate;
    defer l.sink_use = .assign;
    const vir = l.virOf(f);
    const in = Lower.payload(vir, Inst.Instance, i);
    const saved = l.frame;
    defer l.frame = saved;
    l.frame = f;
    const t = try terminals(l, vir, in);
    if (t.len == 0) return l.refuse("a gate with no terminal");
    const lanes: u32 = if (in.range.len == 0) 1 else (try vars.rangeOf(l, f, in.range)).width;
    const arrayed = in.range.len != 0;
    const text = vir.string(in.strength);
    const d = try nets.delay3(l, f, in.delay);
    const kw = vir.string(in.target);
    if (gateKind(kw)) |kind| return gate(l, f, kind, t, lanes, arrayed, nets.strengths(text), d);
    if (std.mem.eql(u8, kw, "pullup") or std.mem.eql(u8, kw, "pulldown")) {
        // §7.8 at pull strength unless one is written.
        const one = kw[4] == 'u';
        const st: net.Strength = if (text.len == 0) .pull else nets.strengths(text)[@intFromBool(one)];
        for (t) |o| {
            const n = try nets.drivenNet(l, f, o, .{ st, st });
            try l.wires.append(l.a, .{ .net = n, .frame = f, .source = .{ .pull = if (one) .one else .zero }, .s0 = st, .s1 = st });
        }
        return;
    }
    const resistive = kw[0] == 'r';
    const base = if (resistive) kw[1..] else kw;
    if (std.mem.eql(u8, base, "nmos") or std.mem.eql(u8, base, "pmos") or std.mem.eql(u8, base, "cmos")) return mos(l, f, base, resistive, t, lanes, arrayed, d);
    if (std.mem.startsWith(u8, base, "tran")) {
        if (d.values[2] != .none) return l.reject(f, i.toRef(), "§7.6: a pass switch takes at most two delays");
        return tran(l, f, base, resistive, t, lanes, d);
    }
    return l.refuseFmt("the primitive `{s}`", .{kw});
}

/// §8 instance `i` of frame `f` of UDP `d` (an array of them included):
/// one driver of its output net per instance, valued by the UDP's table.
/// A.5.4: its `#( )` is a `delay2`.
pub fn udp(l: *Lower, f: u32, i: Inst.Index, d: Zcu.Decl) Error!void {
    l.sink_use = .gate;
    defer l.sink_use = .assign;
    const vir = l.virOf(f);
    const in = Lower.payload(vir, Inst.Instance, i);
    const pvir = l.zcu.fileVir(d.file);
    const prim = Lower.payload(pvir, Inst.Primitive, l.zcu.declRow(d).inst);
    const saved = l.frame;
    defer l.frame = saved;
    l.frame = f;
    const t = try terminals(l, vir, in);
    if (t.len != prim.ports.len) return l.refuse("§8 a UDP instance not connecting its output and every input, in order");
    const params = vir.list(Inst.Arg, in.params);
    var delay = try nets.delay3(l, f, in.delay);
    if (params.len != 0) {
        if (params.len > 2) return l.refuse("§8.6 a UDP instance with more than two delays");
        for (params, 0..) |p, k| {
            const b = vir.body(p.value);
            if (b.len == 0) return l.refuse("an empty UDP delay");
            delay.values[k] = b[b.len - 1].toRef();
        }
        delay.frame = f;
    }
    const table = try tableOf(l, d, pvir, prim);
    const state = try initial(l, pvir, prim);
    const out = try nets.sink(l, t[0]);
    const lanes: u32 = if (in.range.len == 0) 1 else (try vars.rangeOf(l, f, in.range)).width;
    if (out.width != 1 and out.width != lanes) return l.refuse("§8.6 a UDP output terminal neither one bit nor one per instance of an array");
    const wide = l.nets.items[out.net].width != 1;
    const s = nets.strengths(vir.string(in.strength));
    for (0..lanes) |j| {
        const lane: u32 = @intCast(lanes - 1 - j);
        try l.wires.append(l.a, .{ .net = out.net, .frame = f, .s0 = s[0], .s1 = s[1], .delay = delay, .source = .{ .udp = .{
            .udp = table,
            .ins = t[1..],
            .sequential = prim.flags.sequential,
            .lane = if (in.range.len == 0) null else lane,
            .out_bit = if (!wide) null else out.lo + if (out.width == 1) 0 else lane,
            .state = state,
        } } });
    }
}

/// Every pass switch as a `Program.trans` row, each controlled one with
/// its `switch_ctrl` pc, each net's list of the switches on it, and the
/// UDP tables.
pub fn compileTrans(l: *Lower) Error!void {
    l.b.p.udps = l.udps.items;
    const out = try l.a.alloc(Program.Tran, l.trans.items.len);
    const runs = try l.a.alloc(std.ArrayList(u32), l.nets.items.len);
    @memset(runs, .empty);
    for (l.trans.items, out, 0..) |*t, *o, k| {
        o.* = t.tran;
        try runs[o.a].append(l.a, @intCast(k));
        if (o.b != o.a) try runs[o.b].append(l.a, @intCast(k));
        if (t.ctrl == .none) continue;
        l.frame = t.frame;
        const scope = l.frames.items[t.frame].scope;
        o.ctrl = try expr.self_(l, t.ctrl, 1);
        o.delay = try nets.delayOf(l, t.delay, &o.delay_rows);
        var sensitivity: std.ArrayList(u32) = .empty;
        try expr.reads(l, t.ctrl, &sensitivity);
        t.sensitivity = try l.b.listOf(sensitivity.items);
        t.pc = try l.b.inst(.switch_ctrl, @intCast(k), 0, scope);
    }
    for (l.nets.items, runs) |*n, run| n.trans = try l.b.listOf(run.items);
    l.b.p.trans = out;
    assert(out.len == l.trans.items.len);
}

// ---- private ----

/// A primitive's terminals, by position, none left open.
fn terminals(l: *Lower, vir: *const Vir, in: Inst.Instance) Error![]const Inst.Ref {
    var terms: std.ArrayList(Inst.Ref) = .empty;
    for (vir.list(Inst.Arg, in.conns)) |c| {
        if (vir.string(c.name).len != 0) return l.refuse("a primitive terminal connected by name");
        const b = vir.body(c.value);
        if (b.len == 0) return l.refuse("an unconnected primitive terminal");
        try terms.append(l.a, b[b.len - 1].toRef());
    }
    return terms.items;
}

/// UDP `d`'s `Program.udps` row, built once: per A.5.3 entry (`inputs:out`,
/// or `inputs:state:out` for a sequential UDP) one symbol per input, an
/// edge's input marked, every letter lowercase.
fn tableOf(l: *Lower, d: Zcu.Decl, pvir: *const Vir, prim: Inst.Primitive) Error!u32 {
    const gop = try l.udp_tables.getOrPut(l.a, d);
    if (gop.found_existing) return gop.value_ptr.*;
    const inputs = prim.ports.len - 1;
    const strings = pvir.list(Vir.String, prim.rows);
    const rows = try l.a.alloc(net.UdpRow, strings.len);
    for (strings, rows) |str, *row| {
        var fields = std.mem.splitScalar(u8, pvir.string(str), ':');
        const ins = fields.first();
        const second = fields.next() orelse return l.refuse("a UDP table entry with no output");
        const third = fields.next();
        if (fields.next() != null or second.len != 1 or (third != null and third.?.len != 1)) return l.refuse("a malformed UDP table entry");
        var syms: std.ArrayList(net.UdpSym) = .empty;
        var edge_at: ?u32 = null;
        var k: usize = 0;
        while (k < ins.len) : (k += 1) {
            const c = std.ascii.toLower(ins[k]);
            const sym: net.UdpSym = switch (c) {
                '(' => blk: {
                    if (k + 3 >= ins.len or ins[k + 3] != ')') return l.refuse("a malformed UDP edge");
                    const pair: [2]u8 = .{ std.ascii.toLower(ins[k + 1]), std.ascii.toLower(ins[k + 2]) };
                    k += 3;
                    break :blk .{ .pair = pair };
                },
                'r', 'f', 'p', 'n', '*' => .{ .letter = c },
                else => .{ .level = c },
            };
            if (sym != .level) edge_at = @intCast(syms.items.len);
            try syms.append(l.a, sym);
        }
        if (syms.items.len != inputs) return l.refuse("a UDP table entry without one field per input");
        const state: u8 = if (third != null) std.ascii.toLower(second[0]) else 0;
        const out = std.ascii.toLower((third orelse second)[0]);
        row.* = .{ .ins = syms.items, .state = state, .out = out, .edge_at = edge_at };
    }
    gop.value_ptr.* = @intCast(l.udps.items.len);
    try l.udps.append(l.a, rows);
    return gop.value_ptr.*;
}

/// §8.5 a sequential UDP's state at time 0: its `initial` statement's value
/// (0, 1 or x), or its `output reg q = v` header's, else x.
fn initial(l: *Lower, pvir: *const Vir, prim: Inst.Primitive) Error!std_sim.logic.Bit {
    var b = pvir.body(prim.init);
    if (b.len == 0) for (pvir.body(prim.body)) |d| {
        if (Lower.tag(pvir, d) != .io) continue;
        const io = Lower.payload(pvir, Inst.Io, d);
        if (io.init.len != 0) b = pvir.body(io.init);
    };
    if (b.len == 0) return .x;
    var i = b[b.len - 1];
    if (Lower.tag(pvir, i) == .store) i = Lower.payload(pvir, Inst.Bin, i).rhs.toIndex() orelse return l.refuse("a UDP initial value other than a literal");
    const data = pvir.instructions.items(.data)[@backingInt(i)];
    return switch (Lower.tag(pvir, i)) {
        .int => if (data.int == 0) .zero else .one,
        .big_int => switch (pvir.string(Lower.payload(pvir, Inst.BigInt, i).digits)[0]) {
            '0' => .zero,
            '1' => .one,
            else => .x,
        },
        else => l.refuse("a UDP initial value other than a literal"),
    };
}

fn gateKind(kw: []const u8) ?net.GateKind {
    const names = [_][]const u8{ "and", "nand", "or", "nor", "xor", "xnor", "buf", "not", "bufif0", "bufif1", "notif0", "notif1" };
    for (names, 0..) |n, k| if (std.mem.eql(u8, n, kw)) return @fromBackingInt(@intCast(k));
    return null;
}

/// A.3.1 an n-input gate (`out, in...`), or a `buf`/`not` of several
/// outputs (`out..., in`): one driver per output and lane.
fn gate(l: *Lower, f: u32, kind: net.GateKind, t: []const Inst.Ref, lanes: u32, arrayed: bool, s: [2]net.Strength, d: nets.Delay3) Error!void {
    if (t.len < 2) return l.refuse("a gate with no input terminal");
    const many = kind == .g_buf or kind == .g_not;
    const outs = if (many) t[0 .. t.len - 1] else t[0..1];
    const ins = if (many) t[t.len - 1 ..] else t[1..];
    // §7.1.6 "Too many or too few bits to connect to all the instances
    // shall be considered an error."
    if (arrayed) for (ins) |x| {
        const w = (try expr.typeOf(l, x)).width;
        if (w != 1 and w != lanes) return l.reject(f, x, "a gate's input terminal is one bit, or one per instance of an array");
    };
    for (outs) |o| {
        // VAMS §7.8.5.1 an output whose lanes take bridges of their own: each
        // lane drives its own one-bit segment (lib/sim/digital's lane rows).
        const owner = @backingInt(l.frames.items[f].instance);
        if (o.toIndex()) |oi| if (l.lane_split.contains(.{ .instance = owner, .inst = oi })) {
            for (0..lanes) |j| {
                const lane: u32 = @intCast(lanes - 1 - j);
                const b = l.segment_refs.get(.{ .instance = owner, .inst = oi, .lane = lane }).?;
                const seg = try ports.segment(l, b, 1);
                try l.wires.append(l.a, .{ .net = seg.net, .frame = f, .source = .{ .gate = .{ .kind = kind, .ins = ins, .lane = lane, .out_bit = null } }, .s0 = s[0], .s1 = s[1], .delay = d });
            }
            continue;
        };
        const n = try nets.drivenNet(l, f, o, s);
        const width = l.nets.items[n].width;
        if (width != 1 and width != lanes) return l.refuse("a gate output terminal neither one bit nor one per instance of an array");
        for (0..lanes) |j| {
            const lane: ?u32 = if (arrayed) @intCast(lanes - 1 - j) else null;
            try l.wires.append(l.a, .{ .net = n, .frame = f, .source = .{ .gate = .{ .kind = kind, .ins = ins, .lane = lane, .out_bit = if (width == 1) null else lane } }, .s0 = s[0], .s1 = s[1], .delay = d });
        }
    }
}

/// §7.6 a MOS switch (`out, data, gate`), or a CMOS one (`out, data,
/// ncontrol, pcontrol`: an n-type and a p-type sharing data and output).
fn mos(l: *Lower, f: u32, base: []const u8, resistive: bool, t: []const Inst.Ref, lanes: u32, arrayed: bool, d: nets.Delay3) Error!void {
    const cmos = base[0] == 'c';
    if (t.len != @as(usize, if (cmos) 4 else 3)) return l.refuse("a MOS switch with the wrong number of terminals");
    const at = try nets.sink(l, t[0]);
    if (at.width != 1 and (at.width != lanes or at.lo != 0)) return l.refuse("a MOS switch output neither one bit nor one per instance of an array");
    const whole = l.nets.items[at.net].width;
    var data_net: u32 = none;
    if (try expr.nameOf(l, t[1])) |n| if (n.kind == .net and n.dims.len == 0) {
        data_net = n.net;
        l.nets.items[n.net].strength_read = true;
    };
    for (0..lanes) |j| {
        const lane: ?u32 = if (arrayed) @intCast(lanes - 1 - j) else null;
        const out_bit: ?u32 = if (whole == 1) null else if (at.width == 1) at.lo else lane;
        for (0..@as(usize, if (cmos) 2 else 1)) |half| try l.wires.append(l.a, .{ .net = at.net, .frame = f, .delay = d, .source = .{ .mos = .{
            .data = t[1],
            .gate = t[2 + half],
            .data_net = data_net,
            .n_type = if (cmos) half == 0 else base[0] == 'n',
            .resistive = resistive,
            .lane = lane,
            .out_bit = out_bit,
        } } });
    }
}

/// §7.6 a pass switch (`a, b`, or `a, b, control`), one per lane, lane `k`
/// joining bit `k` of terminals as wide as the array.
fn tran(l: *Lower, f: u32, base: []const u8, resistive: bool, t: []const Inst.Ref, lanes: u32, d: nets.Delay3) Error!void {
    const gated = base.len != 4;
    if (t.len != @as(usize, if (gated) 3 else 2)) return l.refuse("a pass switch with the wrong number of terminals");
    for (0..lanes) |k| {
        const a = try terminal(l, t[0], lanes, @intCast(k));
        const b = try terminal(l, t[1], lanes, @intCast(k));
        try l.trans.append(l.a, .{
            .tran = .{
                .a = a.net,
                .b = b.net,
                .a_bit = a.lo,
                .b_bit = b.lo,
                .ctrl = none,
                .on = if (std.mem.endsWith(u8, base, "0")) .zero else .one,
                .resistive = resistive,
                .delay = .{},
                .delay_rows = .{ none, none, none },
                .state = if (gated) .unknown else .on,
            },
            .ctrl = if (gated) t[2] else .none,
            .frame = f,
            .delay = d,
        });
    }
}

/// The bit of lane `lane` a pass switch terminal names: a scalar net, a bit
/// of a vector one, or bit `lane` of one (or of a part-select) as wide as
/// the array.
fn terminal(l: *Lower, r: Inst.Ref, lanes: u32, lane: u32) Error!nets.Sink {
    const s = try nets.sink(l, r);
    if (s.width == 1) return s;
    if (lanes > 1 and s.width == lanes) return .{ .net = s.net, .lo = s.lo + lane, .width = 1 };
    return l.refuse("§7.6 a pass switch terminal neither a scalar net nor a bit-select of a vector one");
}
