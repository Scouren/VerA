//! Net declarations and port connections of the digital lowering: a net's
//! declarations (and, for a port, the connection its instance gives it in
//! the parent) in; the net bound in the instance's frame out: the parent's
//! own net when the port is joined to one whole net of its width (IEEE
//! 1364-2005 clause 12: a port is a connection), else a net of its own fed
//! from the parent's expression (an input) or bridged onto the parent's
//! nets (an output). Also §4.5's implicit nets.
//! Cites: IEEE 1364-2005 §4.5, §6.1.3, §12.3.3, §12.3.9.2, §19.2, §19.9.
//!
//! Contents:
//! - `pub const Conn = struct`
//! - `pub fn declareNet(l: *Lower, f: u32, first: Inst.Index, decls: []const Inst.Index, conn: ?Conn, deferred: *std.ArrayList(nets.Wire)) Error!void`
//! - `pub fn outputVariable(l: *Lower, f: u32, n: Name, conn: Conn, deferred: *std.ArrayList(nets.Wire)) Error!void`
//! - `pub fn implicitNets(l: *Lower, f: u32, insts: []const Inst.Index) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const std_sim = @import("std_sim");
const digital = @import("../digital.zig");
const expr = @import("expr.zig");
const nets = @import("nets.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const Name = digital.Name;
const Span = digital.Span;
const none = digital.none;
const Program = std_sim.Program;
const net = std_sim.net;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// The connection an instance gives one of its module's ports: the
/// parent's expression and the frame it is written in (`none` when the
/// port is left open).
pub const Conn = struct { actual: Inst.Ref, frame: u32 };

/// A net from its first declaration `first` and the later ones `decls`
/// (`first` included) of frame `f`, joined to `conn` when it is a port.
/// Its declaration assignment is a driver now; a port's drivers go to
/// `deferred` (the old engine's order: net declaration assignments, then
/// the ports' drivers).
pub fn declareNet(l: *Lower, f: u32, first: Inst.Index, decls: []const Inst.Index, conn: ?Conn, deferred: *std.ArrayList(nets.Wire)) Error!void {
    const vir = l.virOf(f);
    var kind: Inst.NetKind = .none;
    var signed = false;
    var range: Vir.Body = .empty;
    var dir: Inst.Direction = .none;
    var decl_net: ?Inst.Net = null;
    for (decls) |d| switch (Lower.tag(vir, d)) {
        .io => {
            const io = Lower.payload(vir, Inst.Io, d);
            if (io.flags.net != .none) kind = io.flags.net;
            signed = signed or io.flags.signed;
            if (range.len == 0) range = io.range;
            dir = io.flags.dir;
            if (io.dims.len != 0) return l.refuse("a port array");
        },
        .net => {
            const n = Lower.payload(vir, Inst.Net, d);
            if (n.flags.net != .none) kind = n.flags.net;
            signed = signed or n.flags.signed;
            if (range.len == 0) range = n.range;
            if (n.discipline != .empty) return l.refuse("a disciplined net");
            decl_net = n;
        },
        else => unreachable, // else: `declare.items` groups only nets and ports here
    };
    if (kind == .none) kind = defaultNet(l, f);
    const nk = nets.netKind(kind) orelse return l.refuse("a ground or discipline-only net");
    var n: Name = .{ .kind = .net };
    var width: u32 = 1;
    if (range.len != 0) {
        const r = try rangeOf(l, f, range);
        n.msb = r.msb;
        n.lsb = r.lsb;
        width = r.width;
    } else n.scalar = true;
    n.ty = .{ .width = width, .signed = signed };
    if (decl_net) |dn| if (dn.dims.len != 0) return netArray(l, f, first, n, nk, dn);
    // §12.3 a port joined to one whole net of its width is that net.
    if (conn) |c| if (c.actual != .none) if (try wholeNet(l, c)) |outer| if (outer.ty.width == width) {
        if (decl_net) |dn| if (dn.init.len != 0) return l.refuse("a port with a net declaration assignment");
        var joined = outer;
        joined.ty.signed = signed;
        _ = try l.bind(f, first, joined);
        return;
    };
    n.net = try nets.mintNet(l, nk, width, signed);
    n.slot = l.nets.items[n.net].slot;
    _ = try l.bind(f, first, n);
    if (decl_net) |dn| try netOf(l, f, n.net, nk, dn);
    const c = conn orelse return;
    if (c.actual == .none) {
        // §19.9 an unconnected input under `unconnected_drive is pulled.
        const drive = Lower.payload(vir, Inst.Module, l.zcu.declRow(l.zcu.instances.items(.module)[@backingInt(l.frames.items[f].instance)]).inst).stamp.flags.drive;
        if (dir == .input and drive != .float) try deferred.append(l.a, .{ .net = n.net, .frame = f, .source = .{ .pull = if (drive == .pull1) .one else .zero }, .s0 = .pull, .s1 = .pull });
        return;
    }
    switch (dir) {
        .input => try deferred.append(l.a, .{ .net = n.net, .frame = c.frame, .source = .{ .expr = .{ .value = c.actual } } }),
        .output => try send(l, f, c, n.slot, width, signed, deferred),
        .inout => return l.refuse("an inout port joined to a select, a concatenation or a net of another width"),
        .none => return l.refuse("a port with no direction"),
    }
}

/// §12.3.3 an output port declared as a variable: it drives the net(s) it
/// is connected to, as a continuous assignment of it would.
pub fn outputVariable(l: *Lower, f: u32, n: Name, conn: Conn, deferred: *std.ArrayList(nets.Wire)) Error!void {
    if (conn.actual == .none) return;
    if (n.ty.real) return l.refuse("a real output port");
    if (try wholeNet(l, conn)) |outer| {
        const w = l.nets.items[outer.net].width;
        try deferred.append(l.a, .{ .net = outer.net, .frame = f, .source = .{ .bridge = .{
            .src = n.slot,
            .src_lo = 0,
            .dst_lo = 0,
            .width = @min(n.ty.width, w),
            .ext = w -| n.ty.width,
            .sign_at = if (n.ty.signed) n.ty.width - 1 else null,
        } } });
        return;
    }
    try send(l, f, conn, n.slot, n.ty.width, n.ty.signed, deferred);
}

/// §4.5 every identifier no declaration names on the left of a continuous
/// assignment (the whole target) or in an instance's connections (any
/// identifier of one): a scalar net of the `default_nettype, in frame `f`.
pub fn implicitNets(l: *Lower, f: u32, insts: []const Inst.Index) Error!void {
    const vir = l.virOf(f);
    for (insts) |i| switch (Lower.tag(vir, i)) {
        .assign => {
            const a = Lower.payload(vir, Inst.Assign, i);
            const lhs = vir.body(a.lhs);
            try implicit(l, f, lhs[lhs.len - 1].toRef(), false);
        },
        .instance => {
            const in = Lower.payload(vir, Inst.Instance, i);
            for (vir.list(Inst.Arg, in.conns)) |c| {
                const b = vir.body(c.value);
                if (b.len != 0) try implicit(l, f, b[b.len - 1].toRef(), true);
            }
        },
        else => {}, // else: no other item declares a net by naming it
    };
}

// ---- private ----

/// The `default_nettype in force at frame `f`'s module.
fn defaultNet(l: *Lower, f: u32) Inst.NetKind {
    const d = l.zcu.instances.items(.module)[@backingInt(l.frames.items[f].instance)];
    const vir = l.zcu.fileVir(d.file);
    const m = Lower.payload(vir, Inst.Module, l.zcu.declRow(d).inst);
    return std.meta.stringToEnum(Inst.NetKind, @tagName(m.stamp.flags.nettype)) orelse .none;
}

/// A net declaration's own facts: its constant `delay3` (a trireg's third
/// value its charge decay), its charge, and its declaration assignment as
/// a driver (timed by the declaration's delay, which is then not the net's).
fn netOf(l: *Lower, f: u32, at: u32, kind: net.NetKind, dn: Inst.Net) Error!void {
    const vir = l.virOf(f);
    const words = vir.string(dn.strength);
    const s = nets.strengths(words);
    if (kind == .trireg) {
        if (std.mem.eql(u8, words, "small")) l.nets.items[at].charge = .small;
        if (std.mem.eql(u8, words, "large")) l.nets.items[at].charge = .large;
    }
    const d = try nets.delay3(l, f, dn.delay);
    if (dn.init.len != 0) {
        const init = vir.body(dn.init);
        try l.wires.append(l.a, .{ .net = at, .frame = f, .source = .{ .expr = .{ .value = init[init.len - 1].toRef() } }, .s0 = s[0], .s1 = s[1], .delay = d });
        return;
    }
    if (d.values[0] == .none) return;
    var ticks: [3]u64 = .{ 0, 0, 0 };
    const scale = l.b.times.items[l.frames.items[f].scope].scale;
    for (d.values, 0..) |r, k| if (r != .none) {
        const c = (try l.constOf(f, r)) orelse return l.refuse("a net delay Sema/eval.zig does not fold");
        ticks[k] = switch (c) {
            .int => |v| scale.signedDelay(v) catch return l.refuse("a delay past 2^64 ticks"),
            .real => |v| scale.realDelay(v) catch return l.refuse("a delay past 2^64 ticks"),
            .str => return l.refuse("a string delay"),
        };
    };
    var dl: net.Delay = .{ .present = true, .rise = ticks[0], .fall = if (d.values[1] != .none) ticks[1] else ticks[0] };
    dl.off = if (d.values[2] != .none) ticks[2] else @min(dl.rise, dl.fall);
    if (kind == .trireg and d.values[2] != .none) {
        l.nets.items[at].decay = dl.off;
        dl.off = @min(dl.rise, dl.fall);
    }
    l.nets.items[at].delay = dl;
}

/// §4.9.1 a net array: one net per element on consecutive slots.
fn netArray(l: *Lower, f: u32, first: Inst.Index, proto: Name, kind: net.NetKind, dn: Inst.Net) Error!void {
    if (dn.init.len != 0) return l.refuse("a net array with an assignment");
    const vir = l.virOf(f);
    var n = proto;
    var spans: std.ArrayList(Span) = .empty;
    var count: u64 = 1;
    for (vir.body(dn.dims)) |d| {
        if (Lower.tag(vir, d) != .range) continue;
        const bin = Lower.payload(vir, Inst.Bin, d);
        const hi = try l.intOf(f, bin.lhs);
        const lo = try l.intOf(f, bin.rhs);
        try spans.append(l.a, .{ .low = @min(lo, hi), .high = @max(lo, hi) });
        count *= std.math.cast(u64, @as(i128, @max(lo, hi)) - @min(lo, hi) + 1) orelse return l.refuse("a net array past 2^24 elements");
        if (count > 1 << 24) return l.refuse("a net array past 2^24 elements");
    }
    n.dims = spans.items;
    n.count = @intCast(count);
    for (0..n.count) |k| {
        const at = try nets.mintNet(l, kind, n.ty.width, n.ty.signed);
        if (k == 0) {
            n.net = at;
            n.slot = l.nets.items[at].slot;
        }
        try netOf(l, f, at, kind, dn);
    }
    _ = try l.bind(f, first, n);
}

/// The whole net (not an array, not a select) `c.actual` names in its
/// frame, or null.
fn wholeNet(l: *Lower, c: Conn) Error!?Name {
    const saved = l.frame;
    defer l.frame = saved;
    l.frame = c.frame;
    const n = (try expr.nameOf(l, c.actual)) orelse return null;
    if (n.kind != .net or n.dims.len != 0) return null;
    return n;
}

/// §12.3.9.2 a port (`src`, `width` bits) driving the nets its connection
/// names: a bridge per operand, the rightmost operand the port's low bits.
fn send(l: *Lower, f: u32, c: Conn, src: u32, width: u32, signed: bool, deferred: *std.ArrayList(nets.Wire)) Error!void {
    const saved = l.frame;
    defer l.frame = saved;
    l.frame = c.frame;
    var leaves: std.ArrayList(Inst.Ref) = .empty;
    try leavesOf(l, c.actual, &leaves);
    var operands: std.ArrayList(nets.Sink) = .empty;
    for (leaves.items) |x| {
        const n = (try expr.nameOf(l, x)) orelse return l.refuse("an output port connected to a select or an expression");
        if (n.kind != .net or n.dims.len != 0) return l.refuse("an output port connected to a variable");
        try operands.append(l.a, .{ .net = n.net, .lo = 0, .width = l.nets.items[n.net].width });
    }
    var lo: u32 = 0;
    var k = operands.items.len;
    while (k != 0) {
        k -= 1;
        const op = operands.items[k];
        const copy = @min(op.width, width - lo);
        try deferred.append(l.a, .{ .net = op.net, .frame = f, .source = .{ .bridge = .{
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

fn leavesOf(l: *Lower, r: Inst.Ref, out: *std.ArrayList(Inst.Ref)) Error!void {
    const vir = l.virOf(l.frame);
    const i = r.toIndex() orelse return;
    if (Lower.tag(vir, i) != .concat) return out.append(l.a, r);
    for (vir.list(Inst.Ref, Lower.payload(vir, Inst.Refs, i))) |x| try leavesOf(l, x, out);
}

/// An implicit net for `r` when it is a `str_ref` no net is bound to yet;
/// with `deep`, for each `str_ref` anywhere in it.
fn implicit(l: *Lower, f: u32, r: Inst.Ref, deep: bool) Error!void {
    const vir = l.virOf(f);
    const i = r.toIndex() orelse return;
    const data = vir.instructions.items(.data)[@backingInt(i)];
    switch (Lower.tag(vir, i)) {
        .str_ref => {
            const text = vir.string(data.str_tok.start);
            if (text.len != 0 and text[0] == '$') return;
            const key: Lower.Implicit = .{ .frame = l.rootFrame(f), .name = data.str_tok.start };
            if (l.implicit.contains(key)) return;
            const kind = nets.netKind(defaultNet(l, f)) orelse return;
            const at = try nets.mintNet(l, kind, 1, false);
            try l.names.append(l.a, .{ .kind = .net, .slot = l.nets.items[at].slot, .net = at, .scalar = true });
            try l.implicit.put(l.a, key, @intCast(l.names.items.len - 1));
        },
        .concat => if (deep) for (vir.list(Inst.Ref, Lower.payload(vir, Inst.Refs, i))) |x| try implicit(l, f, x, deep),
        .pos, .neg, .not, .bit_not, .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor => if (deep) try implicit(l, f, data.un_node.operand, deep),
        .add, .sub, .mul, .div, .mod, .pow, .shl, .shr, .ashl, .ashr, .lt, .gt, .lte, .gte, .eq, .neq, .case_eq, .case_neq, .bit_and, .bit_or, .bit_xor, .bit_xnor, .bool_and, .bool_or => if (deep) {
            const b = Lower.payload(vir, Inst.Bin, i);
            try implicit(l, f, b.lhs, deep);
            try implicit(l, f, b.rhs, deep);
        },
        else => {}, // else: a declared name, a literal, a select (whose base is declared)
    }
}

fn rangeOf(l: *Lower, f: u32, range: Vir.Body) Error!struct { msb: i64, lsb: i64, width: u32 } {
    const vir = l.virOf(f);
    const r = vir.body(range);
    const bin = Lower.payload(vir, Inst.Bin, r[r.len - 1]);
    const msb = try l.intOf(f, bin.lhs);
    const lsb = try l.intOf(f, bin.rhs);
    const width = std.math.cast(u32, @abs(@as(i128, msb) - lsb) + 1) orelse return l.refuse("a range past 2^32 bits");
    return .{ .msb = msb, .lsb = lsb, .width = width };
}
