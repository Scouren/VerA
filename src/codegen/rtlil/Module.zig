//! One RTLIL `module` being written: the elaborated instance it is the
//! text of (its spec's first), its wire lines and its cells, connects and
//! processes, and the writers every transformation shares: a slot's
//! sigspec, a fresh wire, a `$`-cell, a width change. The expressions are
//! `expr.zig`, the processes `proc.zig`, the spine `emit.zig`.
//! Cites: IEEE 1364-2005 §5.5 (an operand's extension), §12.1.2 (a port's
//! header position).
//!
//! Contents:
//! - `pub const Error`, `pub const In`, `pub const Sig`
//! - `pub fn instanceOf(m: *const Module, slot: u32) u32`
//! - `pub fn slot(m: *Module, s: u32) Error!Sig`
//! - `pub fn wireLine(m: *Module, name: []const u8, ty: Program.Ty, msb: i64, lsb: i64, dir: ?Port, init: ?[]const u8) Error!void`
//! - `pub fn fresh(m: *Module, comptime kind: u8) Error![]const u8`
//! - `pub fn temp(m: *Module, w: u32) Error!Sig`
//! - `pub fn cell1(m: *Module, kind: []const u8, a: Sig, yw: u32) Error!Sig`
//! - `pub fn cell2(m: *Module, kind: []const u8, a: Sig, b: Sig, yw: u32) Error!Sig`
//! - `pub fn mux(m: *Module, s: Sig, a: Sig, b: Sig) Error!Sig`
//! - `pub fn bit1(m: *Module, s: Sig) Error!Sig`
//! - `pub fn fit(m: *Module, s: Sig, w: u32, signed: bool) Error!Sig`
//! - `pub fn part(m: *Module, s: Sig, lo: u32, w: u32) Error!Sig`
//! - `pub fn constant(m: *Module, v: []const u64, x: []const u64, w: u32, signed: bool) Error!Sig`
//! - `pub fn publicId(arena: Allocator, name: []const u8) Error![]const u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const sema = @import("sema");
const std_sim = @import("std_sim");
const Program = std_sim.Program;
const Lowered = sema.digital.Lowered;
const Port = sema.digital.Port;

/// `Unsupported`: the Program holds a shape the RTLIL subset has no text
/// for (the refusals let none through; this is a backstop, reported as not
/// built).
pub const Error = error{ OutOfMemory, WriteFailed, Unsupported };

/// What the backend reads: the lowered design, and per `Zcu.instances` row
/// its parent's row (`none` for a root) and its name below the parent.
pub const In = struct {
    lowered: *const Lowered,
    parent: []const u32,
    name: []const []const u8,
};

/// One sigspec: its RTLIL spelling, width and §5.5 signedness.
pub const Sig = struct { s: []const u8, w: u32, signed: bool = false };

arena: Allocator,
in: In,
p: *const Program,
/// The `Zcu.instances` row this module is the text of, and its spec.
k: u32,
spec: u32,
/// The module's `wire` lines, then its cells, connects and processes.
wires: Writer.Allocating,
cells: Writer.Allocating,
/// Per slot already named in this module, its sigspec.
names: std.AutoHashMapUnmanaged(u32, Sig) = .empty,
/// `$vera$wN`, `$vera$cN`: unique in the file (shared by every module).
next_id: *u32,
/// The process being written: a read of a slot it wrote by a blocking
/// assignment takes its temp (§9.2.1).
redirect: ?*const std.AutoHashMapUnmanaged(u32, Sig) = null,

const Module = @This();
const none = std.math.maxInt(u32);

/// The `Zcu.instances` row of the frame that declared `s`, or `none`.
pub fn instanceOf(m: *const Module, s: u32) u32 {
    const l = m.in.lowered;
    const scope = l.slot_scope[s];
    return if (scope == none) none else l.scope_instance[scope];
}

/// Slot `s` as this module sees it: one of its ports, a wire it declares,
/// a port of one of its child instances (a wire of its own the cell's
/// connection names), else a wire named for the slot. Declares the wire
/// the first time.
pub fn slot(m: *Module, s: u32) Error!Sig {
    if (m.redirect) |r| if (r.get(s)) |t| return t;
    if (m.names.get(s)) |sig| return sig;
    const l = m.in.lowered;
    const ty = m.p.slots.items(.ty)[s];
    if (ty.real) return error.Unsupported;
    const owner = m.instanceOf(s);
    const name = if (owner != none and owner != m.k and m.in.parent[owner] == m.k)
        try m.arena.print("$vera$i{d}${s}", .{ owner, portName(l.instance_ports[owner], s) orelse "" })
    else if (owner == m.k and l.slot_names[s].len != 0)
        try publicId(m.arena, l.slot_names[s])
    else
        try m.arena.print("$vera$s{d}", .{s});
    try m.wireLine(name, ty, l.slot_msb[s], l.slot_lsb[s], null, null);
    const sig: Sig = .{ .s = name, .w = ty.width, .signed = ty.signed };
    try m.names.put(m.arena, s, sig);
    return sig;
}

/// `wire width W [signed] [offset O] [upto] [input|output|inout N] name`,
/// after its `init` attribute when it has one.
pub fn wireLine(m: *Module, name: []const u8, ty: Program.Ty, msb: i64, lsb: i64, dir: ?Port, init: ?[]const u8) Error!void {
    assert(ty.width >= 1);
    const w = &m.wires.writer;
    if (init) |v| try w.print("  attribute \\init {s}\n", .{v});
    try w.print("  wire width {d}", .{ty.width});
    if (ty.signed) try w.writeAll(" signed");
    // Yosys's `offset` is the lower bound either way: [3:10] is `upto offset 3`.
    const offset = @min(msb, lsb);
    if (offset != 0) try w.print(" offset {d}", .{offset});
    if (msb < lsb and ty.width > 1) try w.writeAll(" upto");
    if (dir) |p| try w.print(" {t} {d}", .{ p.dir, p.position });
    try w.print(" {s}\n", .{name});
}

/// A name no source identifier takes (`$vera$` and a counter).
pub fn fresh(m: *Module, comptime kind: u8) Error![]const u8 {
    m.next_id.* += 1;
    return m.arena.print("$vera${c}{d}", .{ kind, m.next_id.* });
}

/// A new private wire of `w` bits.
pub fn temp(m: *Module, w: u32) Error!Sig {
    assert(w >= 1);
    const name = try m.fresh('w');
    try m.wires.writer.print("  wire width {d} {s}\n", .{ w, name });
    return .{ .s = name, .w = w };
}

/// A unary `$`-cell over `a`, its `Y` a fresh `yw`-bit wire.
pub fn cell1(m: *Module, kind: []const u8, a: Sig, yw: u32) Error!Sig {
    assert(kind[0] == '$' and a.w >= 1 and yw >= 1);
    const y = try m.temp(yw);
    try m.cells.writer.print(
        "  cell {s} {s}\n    parameter \\A_SIGNED {d}\n    parameter \\A_WIDTH {d}\n    parameter \\Y_WIDTH {d}\n    connect \\A {s}\n    connect \\Y {s}\n  end\n",
        .{ kind, try m.fresh('c'), @intFromBool(a.signed), a.w, yw, a.s, y.s },
    );
    return y;
}

/// A binary `$`-cell over `a` and `b`, each read by its own signedness.
pub fn cell2(m: *Module, kind: []const u8, a: Sig, b: Sig, yw: u32) Error!Sig {
    assert(kind[0] == '$' and a.w >= 1 and b.w >= 1 and yw >= 1);
    const y = try m.temp(yw);
    try m.cells.writer.print(
        "  cell {s} {s}\n    parameter \\A_SIGNED {d}\n    parameter \\A_WIDTH {d}\n    parameter \\B_SIGNED {d}\n    parameter \\B_WIDTH {d}\n    parameter \\Y_WIDTH {d}\n    connect \\A {s}\n    connect \\B {s}\n    connect \\Y {s}\n  end\n",
        .{ kind, try m.fresh('c'), @intFromBool(a.signed), a.w, @intFromBool(b.signed), b.w, yw, a.s, b.s, y.s },
    );
    return y;
}

/// `$mux`: one-bit `s` selects `b` over `a`, both one width.
pub fn mux(m: *Module, s: Sig, a: Sig, b: Sig) Error!Sig {
    assert(s.w == 1 and a.w == b.w);
    const y = try m.temp(a.w);
    try m.cells.writer.print(
        "  cell $mux {s}\n    parameter \\WIDTH {d}\n    connect \\A {s}\n    connect \\B {s}\n    connect \\S {s}\n    connect \\Y {s}\n  end\n",
        .{ try m.fresh('c'), a.w, a.s, b.s, s.s, y.s },
    );
    return y;
}

/// `s` as one bit of §5.1.9 truth: a wider value through `$reduce_bool`.
pub fn bit1(m: *Module, s: Sig) Error!Sig {
    if (s.w == 1) return s;
    return m.cell1("$reduce_bool", s, 1);
}

/// `s` as exactly `w` bits typed `signed`: truncated, or extended by the
/// target's sign as `std_sim`'s `normalize` does (§5.5.4: an operand is
/// sign-extended only when its propagated type is signed).
pub fn fit(m: *Module, s: Sig, w: u32, signed: bool) Error!Sig {
    assert(w >= 1 and s.w >= 1);
    if (s.w == w) return .{ .s = s.s, .w = w, .signed = signed };
    if (s.w > w) return .{ .s = (try m.part(s, 0, w)).s, .w = w, .signed = signed };
    var out: Writer.Allocating = .init(m.arena);
    try out.writer.writeAll("{");
    const top = if (signed) (try m.part(s, s.w - 1, 1)).s else "1'0";
    for (0..w - s.w) |_| try out.writer.print(" {s}", .{top});
    try out.writer.print(" {s} }}", .{s.s});
    return .{ .s = out.written(), .w = w, .signed = signed };
}

/// Bits `[lo + w - 1 : lo]` of `s`.
pub fn part(m: *Module, s: Sig, lo: u32, w: u32) Error!Sig {
    assert(w >= 1 and lo + w <= s.w);
    if (lo == 0 and w == s.w) return s;
    // A select of a select or a concatenation goes through a wire of its own.
    const base = if (std.mem.findAny(u8, s.s, " {") == null) s else blk: {
        const t = try m.temp(s.w);
        try m.cells.writer.print("  connect {s} {s}\n", .{ t.s, s.s });
        break :blk t;
    };
    const text = if (w == 1) try m.arena.print("{s} [{d}]", .{ base.s, lo }) else try m.arena.print("{s} [{d}:{d}]", .{ base.s, lo + w - 1, lo });
    return .{ .s = text, .w = w };
}

/// A four-state constant of `w` bits, most significant first (`x` and
/// `z` are RTLIL constants too).
pub fn constant(m: *Module, v: []const u64, x: []const u64, w: u32, signed: bool) Error!Sig {
    assert(w >= 1);
    var out: Writer.Allocating = .init(m.arena);
    try out.writer.print("{d}'", .{w});
    var i: u32 = w;
    while (i > 0) : (i -= 1) {
        const k = i - 1;
        const vb = (v[k / 64] >> @intCast(k % 64)) & 1;
        const xb = (x[k / 64] >> @intCast(k % 64)) & 1;
        try out.writer.writeByte(if (xb == 0) '0' + @as(u8, @intCast(vb)) else if (vb == 0) 'z' else 'x');
    }
    return .{ .s = out.written(), .w = w, .signed = signed };
}

/// `\name`: RTLIL's public id, white space (an escaped identifier's) as `.`.
pub fn publicId(arena: Allocator, name: []const u8) Error![]const u8 {
    assert(name.len != 0);
    const out = try arena.alloc(u8, name.len + 1);
    out[0] = '\\';
    @memcpy(out[1..], name);
    for (out[1..]) |*c| if (std.ascii.isWhitespace(c.*)) {
        c.* = '.';
    };
    return out;
}

// ---- private ----

/// The name of the port of `ports` whose slot is `s`.
fn portName(ports: []const Port, s: u32) ?[]const u8 {
    for (ports) |p| if (p.slot == s) return p.name;
    return null;
}
