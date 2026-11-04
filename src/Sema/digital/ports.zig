//! Net declarations and port connections of the digital lowering: a net's
//! declarations (and, for a port, the connection its instance gives it in
//! the parent) in; the net bound in the instance's frame out: the parent's
//! own net when the port is joined to one whole net of its width (IEEE
//! 1364-2005 clause 12: a port is a connection), else a net of its own fed
//! from the parent's expression (an input) or bridged onto the parent's
//! nets (an output). Also §4.5's implicit nets.
//! An expression-ported module's ports (§12.3.6) connect one external port
//! at a time; an inout joined to anything but one whole net is a `tran`
//! per bit (§7.6).
//! Cites: IEEE 1364-2005 §4.5, §6.1.3, §7.6, §12.3.2, §12.3.3, §12.3.6,
//! §12.3.9.2, §12.3.10, §19.2, §19.9.
//!
//! Contents:
//! - `pub const Conn = struct`, `pub const Group = struct`
//! - `pub fn expressionPorts(vir: *const Vir, formals: []const Inst.Index) bool`
//! - `pub fn group(l: *Lower, f: u32, g: Group, deferred: *std.ArrayList(nets.Wire)) Error!void`
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
/// port is left open), and for an element of an instance array its lane
/// (`lane[0]`, the lowest bits 0) of `lane[1]` (§12.1.2).
pub const Conn = struct { actual: Inst.Ref, frame: u32, lane: ?[2]u32 = null };

/// §12.3.6 one external port of an expression-ported module: its port
/// expression (in the module's own frame) and its connection.
pub const Group = struct { expr: Inst.Ref, conn: Conn };

/// IEEE 1364-2005 §12.3.2: do `formals` use A.1.3's port expressions
/// beyond one whole net per port (a select, a concatenation, a name more
/// than one port references)? The module then connects one external port
/// at a time (`group`).
pub fn expressionPorts(vir: *const Vir, formals: []const Inst.Index) bool {
    var seen: [64]Inst.Index = undefined;
    var n: usize = 0;
    for (formals) |formal| {
        if (Lower.tag(vir, formal) != .port) continue;
        const value = vir.body(Lower.payload(vir, Inst.Port, formal).value);
        if (value.len == 0) continue; // A.1.3 a null port names no net
        if (value.len > 1 or Lower.tag(vir, value[0]) != .decl_ref) return true;
        const d = vir.instructions.items(.data)[@backingInt(value[0])].decl_tok.decl;
        if (std.mem.indexOfScalar(Inst.Index, seen[0..n], d) != null) return true;
        // ponytail: duplicates are sought among the first 64 ports only.
        if (n < seen.len) {
            seen[n] = d;
            n += 1;
        }
    }
    return false;
}

/// §12.3.2/§12.3.3 one external port `g` of frame `f`'s module, its
/// connection split among its port references (leftmost the most
/// significant): an input reference takes its bits of the connection
/// through a net the connection drives, an output one drives its bits of
/// the connected nets, and an inout one is joined to them bit by bit, as a
/// `tran` joins two nets (§7.6).
pub fn group(l: *Lower, f: u32, g: Group, deferred: *std.ArrayList(nets.Wire)) Error!void {
    const c = g.conn;
    if (c.actual == .none) return;
    if (c.lane != null) return l.refuse("an instance array of a module with port expressions");
    const saved = l.frame;
    defer l.frame = saved;
    l.frame = f;
    const Ref = struct { slot: u32, net: u32, lo: u32, width: u32, at: u32, dir: Inst.Direction };
    var leaves: std.ArrayList(Inst.Ref) = .empty;
    try leavesOf(l, g.expr, &leaves);
    const refs = try l.a.alloc(Ref, leaves.items.len);
    var total: u32 = 0;
    var k = leaves.items.len;
    while (k != 0) {
        k -= 1;
        const x = leaves.items[k];
        const dir = direction(l, f, x);
        if (dir == .none) return l.refuse("§12.3.3 a port reference with no direction declaration");
        const v = try expr.nameOf(l, x);
        if (v != null and v.?.kind == .variable) {
            refs[k] = .{ .slot = v.?.slot, .net = none, .lo = 0, .width = v.?.ty.width, .at = total, .dir = dir };
        } else {
            const s = try nets.sink(l, x);
            refs[k] = .{ .slot = l.nets.items[s.net].slot, .net = s.net, .lo = s.lo, .width = s.width, .at = total, .dir = dir };
        }
        if (refs[k].net == none and dir != .output) return l.refuse("§12.3.3 an input or inout port declared as a variable");
        total += refs[k].width;
    }
    // Inputs: the connection, as wide as the port, on a net of its own
    // whose bits each input reference takes.
    var fed: u32 = none;
    for (refs) |ref| if (ref.dir == .input) {
        if (fed == none) {
            fed = try nets.mintNet(l, .wire, total, false);
            try deferred.append(l.a, .{ .net = fed, .frame = c.frame, .source = .{ .expr = .{ .value = c.actual } } });
        }
        try deferred.append(l.a, .{ .net = ref.net, .frame = f, .source = .{ .bridge = .{ .src = l.nets.items[fed].slot, .src_lo = ref.at, .dst_lo = ref.lo, .width = ref.width } } });
    };
    for (refs) |ref| {
        if (ref.dir != .input) break;
    } else return;
    // Outputs and inouts: the connected nets, bit ranges from the least
    // significant (§12.3.9.2).
    l.frame = c.frame;
    leaves.clearRetainingCapacity();
    try leavesOf(l, c.actual, &leaves);
    var at: u32 = 0;
    k = leaves.items.len;
    while (k != 0) {
        k -= 1;
        const s = try nets.sink(l, leaves.items[k]);
        for (refs) |ref| {
            const from = @max(ref.at, at);
            const to = @min(ref.at + ref.width, at + s.width);
            if (from >= to) continue;
            switch (ref.dir) {
                .output => try deferred.append(l.a, .{ .net = s.net, .frame = f, .source = .{ .bridge = .{ .src = ref.slot, .src_lo = ref.lo + from - ref.at, .dst_lo = s.lo + from - at, .width = to - from } } }),
                .inout => for (from..to) |b| try join(l, f, ref.net, ref.lo + @as(u32, @intCast(b)) - ref.at, s.net, s.lo + @as(u32, @intCast(b)) - at),
                .input, .none => {},
            }
        }
        at += s.width;
    }
}

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
    // VAMS §3.7 a wreal holds a real.
    if (nk == .wreal) {
        n.ty = digital.Type.real_type;
        width = 64;
    }
    if (decl_net) |dn| if (dn.dims.len != 0) return netArray(l, f, first, n, nk, dn);
    // §12.3 a port joined to one whole net of its width is that net.
    // §12.1.2 an instance array's element takes its own slice of an
    // expression as wide as the port times the elements.
    const slice: ?u32 = if (conn) |c| try laneSlice(l, c, width) else null;
    if (slice == null) if (conn) |c| if (c.actual != .none) if (try wholeNet(l, c)) |outer| {
        // VAMS §3.7 a wreal joined to a wire or tri: one wreal net.
        const outer_wreal = l.nets.items[outer.net].kind == .wreal;
        const merging = (nk == .wreal) != outer_wreal;
        if (merging or outer.ty.width == width) {
            // A port's net declaration assignment drives the merged net.
            if (decl_net) |dn| if (dn.init.len != 0) try netOf(l, f, outer.net, nk, dn);
            // §12.3.10.1 the merged net takes the dominating type (a `tri0`
            // inside a `wire` stays a tri0 and reads 0 undriven).
            if (merging) {
                if (!outer_wreal) try nets.promoteWreal(l, outer.net);
            } else if (nets.internalDominates(nk, l.nets.items[outer.net].kind)) try nets.retype(l, outer.net, nk);
            var joined = outer;
            if (merging or outer_wreal) joined.ty = digital.Type.real_type else joined.ty.signed = signed;
            _ = try l.bind(f, first, joined);
            return;
        }
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
        .input => try deferred.append(l.a, .{ .net = n.net, .frame = c.frame, .source = .{ .expr = if (slice) |lo| .{ .value = c.actual, .slice = true, .lo = lo, .total = width * c.lane.?[1] } else .{ .value = c.actual } } }),
        .output => if (slice) |lo| {
            try sendLane(l, f, c, n.slot, width, lo, deferred);
        } else try send(l, f, c, n.slot, width, signed, deferred),
        .inout => if (slice != null) return l.refuse("an inout port of an instance array element") else try joinPort(l, n.net, width, c),
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
/// The self-determined width of `c.actual` in its frame.
/// §12.1.2 the lowest bit of `c`'s slice an instance array element of a
/// `width`-bit port takes: null when `c` is as wide as the port (connected
/// to every element whole), or when it is no array element.
fn laneSlice(l: *Lower, c: Conn, width: u32) Error!?u32 {
    const ln = c.lane orelse return null;
    if (c.actual == .none) return null;
    assert(ln[0] < ln[1]);
    const whole = try actualWidth(l, c);
    if (whole == width) return null;
    // §7.1.6 "Too many or too few bits to connect to all the instances
    // shall be considered an error"; the product is sized in u64, as a
    // mismatch past u32 is the same error.
    if (@as(u64, width) * ln[1] != whole) return l.reject(c.frame, c.actual, "§12.1.2: only an expression as wide as the port or as the port times the array size is connected across an instance array");
    return ln[0] * width;
}

fn actualWidth(l: *Lower, c: Conn) Error!u32 {
    const saved = l.frame;
    defer l.frame = saved;
    l.frame = c.frame;
    return (try expr.typeOf(l, c.actual)).width;
}

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
    // §12.3.9.2 each operand a whole net or a constant select of one.
    for (leaves.items) |x| try operands.append(l.a, try nets.sink(l, x));
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

/// §12.1.2 an instance array element's output port (`src`, `width` bits)
/// driving bits [lo, lo + width) of the connection's operands, the
/// rightmost operand its low bits: a bridge per operand it overlaps.
fn sendLane(l: *Lower, f: u32, c: Conn, src: u32, width: u32, lo: u32, deferred: *std.ArrayList(nets.Wire)) Error!void {
    const saved = l.frame;
    defer l.frame = saved;
    l.frame = c.frame;
    var leaves: std.ArrayList(Inst.Ref) = .empty;
    try leavesOf(l, c.actual, &leaves);
    var pos: u32 = 0;
    var k = leaves.items.len;
    while (k != 0) {
        k -= 1;
        const op = try nets.sink(l, leaves.items[k]);
        const start = @max(pos, lo);
        const end = @min(pos + op.width, lo + width);
        if (start < end) try deferred.append(l.a, .{ .net = op.net, .frame = f, .source = .{ .bridge = .{ .src = src, .src_lo = start - lo, .dst_lo = op.lo + (start - pos), .width = end - start } } });
        pos += op.width;
    }
}

/// §12.3.10 an inout port (net `at`, `width` bits) joined to the nets its
/// connection names, rightmost operand first: the bits both sides have,
/// one `tran` each; the rest of either side connects nothing.
fn joinPort(l: *Lower, at: u32, width: u32, c: Conn) Error!void {
    const saved = l.frame;
    defer l.frame = saved;
    l.frame = c.frame;
    var leaves: std.ArrayList(Inst.Ref) = .empty;
    try leavesOf(l, c.actual, &leaves);
    var lo: u32 = 0;
    var k = leaves.items.len;
    while (k != 0 and lo < width) {
        k -= 1;
        const op = try nets.sink(l, leaves.items[k]);
        const n = @min(op.width, width - lo);
        for (0..n) |j| try join(l, c.frame, at, lo + @as(u32, @intCast(j)), op.net, op.lo + @as(u32, @intCast(j)));
        lo += n;
    }
    assert(lo <= width);
}

/// §7.6 bit `a_bit` of net `a` joined to bit `b_bit` of net `b`: an
/// always-on `tran`.
fn join(l: *Lower, f: u32, a: u32, a_bit: u32, b: u32, b_bit: u32) Error!void {
    assert(a != none and b != none);
    assert(a_bit < l.nets.items[a].width and b_bit < l.nets.items[b].width);
    try l.trans.append(l.a, .{
        .tran = .{ .a = a, .b = b, .a_bit = a_bit, .b_bit = b_bit, .ctrl = none, .on = .one, .resistive = false, .delay = .{}, .delay_rows = .{ none, none, none }, .state = .on },
        .ctrl = .none,
        .frame = f,
        .delay = .{},
    });
}

/// The direction declared for the declaration port reference `r` (a name
/// or a select of one) names in frame `f`'s module, or `.none`.
fn direction(l: *Lower, f: u32, r: Inst.Ref) Inst.Direction {
    const vir = l.virOf(f);
    var x = r.toIndex() orelse return .none;
    var depth: u32 = 0;
    while (Lower.tag(vir, x) != .decl_ref) : (depth += 1) {
        assert(depth < vir.instructions.len);
        const base = switch (Lower.tag(vir, x)) {
            .elem => Lower.payload(vir, Inst.Bin, x).lhs,
            .slice, .slice_up, .slice_down => Lower.payload(vir, Inst.Triple, x).a,
            else => return .none, // else: no port reference
        };
        x = base.toIndex() orelse return .none;
    }
    const first = vir.instructions.items(.data)[@backingInt(x)].decl_tok.decl;
    const d = l.zcu.instances.items(.module)[@backingInt(l.frames.items[f].instance)];
    const m = Lower.payload(vir, Inst.Module, l.zcu.declRow(d).inst);
    for (vir.body(m.body)) |i| if (Lower.tag(vir, i) == .io) {
        const io = Lower.payload(vir, Inst.Io, i);
        if (i == first or io.prev.toIndex() == first) return io.flags.dir;
    };
    return .none;
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
