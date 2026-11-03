//! A display call's parsed pieces (`Program.Show`) and the run's values in,
//! IEEE 1364-2005 §17.1 text on `State.out` out; the standing `$monitor`
//! (§17.1.3) and `$timeformat` (§17.3.2) state. Every value's digits come
//! from `kernels.fmt`, the radix and time text both engines share.
//! Cites: IEEE 1364-2005 §9.4.1, §17.1.1.2-§17.1.1.7, §17.1.3, §17.3.2;
//! VAMS §9.4.3 Table 9-23, §9.4.7.
//!
//! Contents:
//! - `pub fn show(s: *State, a: Allocator, at: u32, pc: u32) Error!void`
//! - `pub fn install(s: *State, a: Allocator, at: u32) Error!void`
//! - `pub fn monitorPrint(s: *State, a: Allocator) Error!void`
//! - `pub fn timeformat(s: *State, a: Allocator, at: u32) Error!void`
//! - `pub fn real(out: *std.Io.Writer, gpa: Allocator, r: f64, conv: u8, flags: u8, precision: i64, width: ?u64) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const kernels = @import("kernels");
const fmt = kernels.fmt;
const str_real = kernels.str_real;
const Program = @import("Program.zig");
const State = @import("State.zig");
const eval = @import("eval.zig");
const logic = @import("logic.zig");
const Error = State.Error;
const Literal = logic.Literal;
const Piece = Program.Piece;

/// How a non-real field's C flag reshapes its padded text (iverilog's).
const Fill = enum { zero, left };

/// Prints show row `at` onto `s.out`, every conversion width-exact (§17.1.1.3).
pub fn show(s: *State, a: Allocator, at: u32, pc: u32) Error!void {
    _ = pc;
    const p = s.p;
    const sh = p.shows[at];
    for (p.list(sh.pieces)) |k| try piece(s, a, sh, p.pieces[k]);
    if (sh.newline) try s.out.writeByte('\n');
}

/// §17.1.3 `$monitor`: the `Program.Monitor` at `at` becomes the standing
/// monitor, replacing any other, watch list and all; its first report is at
/// the end of this time step.
pub fn install(s: *State, a: Allocator, at: u32) Error!void {
    const p = s.p;
    const m = p.extraData(Program.Monitor, at);
    if (s.monitor) |old| for (p.list(old.m.slots)) |slot| {
        s.monitored[slot] = false;
    };
    s.monitor = null;
    const values = try s.arena.alloc([]u64, m.compared.len);
    for (p.list(m.compared), values) |e, *v| v.* = try s.arena.dupe(u64, try s.monitorValue(a, e));
    s.monitor = .{ .m = m, .values = values };
    for (p.list(m.slots)) |slot| s.monitored[slot] = true;
    s.monitor_hit = true;
    try s.requestMonitor();
}

/// Prints the standing monitor, if one is due: on, or a change seen while
/// it was on.
pub fn monitorPrint(s: *State, a: Allocator) Error!void {
    const m = s.monitor orelse return;
    if (!s.monitor_on and !s.monitor_hit) return;
    try show(s, a, m.m.show, 0);
    s.monitor_hit = false;
}

/// §17.3.2 `$timeformat` with the arguments at `at` in `extra` (a
/// `Program.TimeFormat`), or the reset when `at` is `none`.
pub fn timeformat(s: *State, a: Allocator, at: u32) Error!void {
    if (at == @backingInt(Program.Ref.none)) {
        s.time_format = .{ .units = s.p.finest };
        return;
    }
    const t = s.p.extraData(Program.TimeFormat, at);
    s.time_format = .{
        .units = std.math.lossyCast(i32, (try eval.eval(s, a, t.units)).asInt() orelse 0),
        .precision = std.math.lossyCast(u32, (try eval.eval(s, a, t.precision)).asInt() orelse 0),
        .suffix = s.p.str(t.suffix),
        .width = std.math.lossyCast(u32, (try eval.eval(s, a, t.width)).asInt() orelse 0),
    };
}

/// §17.1.1.2 one real conversion, C's text under `flags`, in a field
/// `width` wide.
pub fn real(out: *std.Io.Writer, gpa: Allocator, r: f64, conv: u8, flags: u8, precision: i64, width: ?u64) Error!void {
    var stack: [1024]u8 = undefined;
    const need = 512 + @as(usize, @intCast(@max(precision, 0)));
    const buf = if (need <= stack.len) &stack else try gpa.alloc(u8, need);
    defer if (buf.ptr != &stack) gpa.free(buf);
    const text = str_real.zCReal(buf, r, conv, flags & ~(str_real.zc_left | str_real.zc_zero), 0, precision);
    const pad = (width orelse 0) -| text.len;
    if (flags & str_real.zc_left != 0) {
        try out.writeAll(text);
        return out.splatByteAll(' ', @intCast(pad));
    }
    const zero = flags & str_real.zc_zero != 0 and std.math.isFinite(r);
    const sign: usize = if (zero and text.len != 0 and (text[0] == '-' or text[0] == '+' or text[0] == ' ')) 1 else 0;
    try out.writeAll(text[0..sign]);
    try out.splatByteAll(if (zero) '0' else ' ', @intCast(pad));
    try out.writeAll(text[sign..]);
}

// ---- private ----

fn piece(s: *State, a: Allocator, sh: Program.Show, pc_: Piece) Error!void {
    const p = s.p;
    const out = s.out;
    const width: ?u64 = if (pc_.width == Piece.none_width) null else pc_.width;
    switch (pc_.kind) {
        .text, .lib => try out.writeAll(p.str(.{ .start = pc_.a, .len = pc_.width })),
        .space => try out.writeByte(' '),
        .scope => try scopeName(s, sh.scope, pc_.a),
        .bare => try fmt.value(out, a, try eval.eval(s, a, pc_.a), @fromBackingInt(@intCast(@backingInt(sh.radix))), null),
        .bare_real => {
            const r = try eval.real(s, a, pc_.a);
            if (pc_.precision >= 0) return real(out, a, r, 'f', 0, pc_.precision, null);
            try real(out, a, r, 'g', str_real.zc_alt, -1, null);
        },
        .spec => {
            const sp: fmt.Spec = .{ .flags = pc_.flags, .width = width, .precision = pc_.precision };
            const conv = pc_.conv;
            const arg = pc_.a;
            const is_real = p.exprs.items(.ty)[arg].real;
            switch (conv | 0x20) {
                'e', 'f', 'g', 'r' => return real(out, a, try eval.real(s, a, arg), conv, pc_.flags, pc_.precision, width),
                'u', 'z' => return unformatted(out, try eval.eval(s, a, arg), conv | 0x20 == 'z'),
                else => {},
            }
            // A field the C flags reshape is written aside first.
            const fill = fieldFill(sp, conv);
            var field: std.Io.Writer.Allocating = .init(a);
            const w = if (fill != null) &field.writer else out;
            switch (conv | 0x20) {
                't' => {
                    const tf = s.time_format.field(width, pc_.precision);
                    const unit_exp = p.times[p.scopes[sh.scope].time].unit_exp;
                    if (is_real)
                        try fmt.time(w, try eval.real(s, a, arg), tf, unit_exp)
                    else {
                        const v = try eval.eval(s, a, arg);
                        if (v.hasUnknown()) try fmt.timeUnknown(w, v, tf) else try fmt.timeInt(w, a, v, tf, unit_exp);
                    }
                },
                's', 'c' => try fmt.text(w, try eval.eval(s, a, arg), conv | 0x20 == 'c', width),
                else => {
                    const radix: fmt.Radix = switch (conv | 0x20) {
                        'b' => .binary,
                        'o' => .octal,
                        'h', 'x' => .hex,
                        else => .decimal, // else: `%d`, the fourth radix
                    };
                    if (is_real) try realRadix(w, a, try eval.real(s, a, arg), radix, width) else try fmt.value(w, a, try eval.eval(s, a, arg), radix, width);
                },
            }
            if (fill) |f| try fillField(out, field.written(), f);
        },
    }
}

/// §17.1.1.6 `%m`: the scope's path from the root, then every named block
/// around pc `pc` in it, outermost first.
fn scopeName(s: *State, scope: u32, pc: u32) Error!void {
    try path(s, scope);
    var last: i64 = -1;
    while (true) {
        var next: ?Program.Block = null;
        for (s.p.blocks) |b| {
            if (b.scope != scope or pc < b.start or pc >= b.end) continue;
            if (b.depth > last and (next == null or b.depth < next.?.depth)) next = b;
        }
        const b = next orelse break;
        try s.out.print(".{s}", .{s.p.str(b.name)});
        last = b.depth;
    }
}

fn path(s: *State, scope: u32) Error!void {
    const sc = s.p.scopes[scope];
    if (sc.parent != scope and scope != 0) {
        try path(s, sc.parent);
        try s.out.writeByte('.');
    }
    try s.out.writeAll(s.p.str(sc.name));
    if (sc.index) |i| try s.out.print("[{d}]", .{i});
}

fn fieldFill(sp: fmt.Spec, conv: u8) ?Fill {
    if (sp.flags & str_real.zc_left != 0) return .left;
    if (sp.flags & str_real.zc_zero != 0 and (sp.width orelse 0) != 0 and conv | 0x20 != 's') return .zero;
    return null;
}

fn fillField(out: *std.Io.Writer, text: []const u8, f: Fill) Error!void {
    const pad = std.mem.indexOfNone(u8, text, " ") orelse text.len;
    if (f == .zero) {
        const sign: usize = @intFromBool(pad < text.len and text[pad] == '-');
        try out.writeAll(text[pad..][0..sign]);
        try out.splatByteAll('0', pad);
        return out.writeAll(text[pad + sign ..]);
    }
    try out.writeAll(text[pad..]);
    try out.splatByteAll(' ', pad);
}

/// A radix conversion of a real (VD-120): the §4.8.2 integer at minimal
/// width unless given; inf and nan as C spells them.
fn realRadix(out: *std.Io.Writer, a: Allocator, r: f64, radix: fmt.Radix, width: ?u64) Error!void {
    const neg_zero = radix == .decimal and @round(r) == 0 and std.math.signbit(r);
    if (!std.math.isFinite(r) or neg_zero) {
        const text = if (neg_zero) "-0" else if (std.math.isNan(r)) "nan" else if (r < 0) "-inf" else "inf";
        try out.splatByteAll(' ', @intCast((width orelse 0) -| text.len));
        return out.writeAll(text);
    }
    try fmt.value(out, a, try logic.intOfReal(a, r), radix, width orelse 0);
}

/// §17.1.1.2 `%u`/`%z`: 32-bit words, least significant first, little-endian.
fn unformatted(out: *std.Io.Writer, v: Literal, four: bool) Error!void {
    for (0..@max(1, (v.width + 31) / 32)) |k| {
        const lo = k * 32;
        const val: u32 = @truncate(v.values()[lo / 64] >> @intCast(lo % 64));
        const unk: u32 = @truncate(v.unknowns()[lo / 64] >> @intCast(lo % 64));
        if (four) {
            try out.writeInt(u32, val, .little);
            try out.writeInt(u32, unk, .little);
        } else try out.writeInt(u32, val & ~unk, .little);
    }
}
