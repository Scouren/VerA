//! Declarations bound to slots in the digital lowering: one variable,
//! parameter or named event (an array of them included) of a frame in; its
//! `names` row and fresh slots at their time-0 values out (a variable x, a
//! real 0.0, a parameter its folded value in its §12.2 type, an event x).
//! Cites: IEEE 1364-2005 §3.6, §4.2.1, §4.8, §4.9, §4.10, §5.10.4, §6.2.1,
//! §12.2.
//!
//! Contents:
//! - `pub fn locals(l: *Lower, f: u32, body: Vir.Body) Error!void`
//! - `pub fn variable(l: *Lower, f: u32, first: Inst.Index, decls: []const Inst.Index) Error!u32`
//! - `pub fn param(l: *Lower, f: u32, i: Inst.Index) Error!u32`
//! - `pub fn event(l: *Lower, f: u32, i: Inst.Index) Error!u32`
//! - `pub fn rangeOf(l: *Lower, f: u32, range: Vir.Body) Error!struct { msb: i64, lsb: i64, width: u32 }`
//! - `pub fn slots(l: *Lower, ty: Type, count: u32, fill: enum { x, zero }) Error!u32`

const std = @import("std");
const vams = @import("vams");
const std_sim = @import("std_sim");
const walk = @import("../walk.zig");
const Zcu = @import("../../Zcu.zig");
const digital = @import("../digital.zig");
const expr = @import("expr.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const Name = digital.Name;
const Type = digital.Type;
const Span = digital.Span;
const none = digital.none;
const Program = std_sim.Program;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// The most slots one array declares.
const array_max: u32 = 1 << 24;

/// Binds the block- or subroutine-local declarations of `body` (variables,
/// parameters, events) in frame `f`, each a slot of its own.
pub fn locals(l: *Lower, f: u32, body: Vir.Body) Error!void {
    const vir = l.virOf(f);
    for (vir.body(body)) |i| switch (Lower.tag(vir, i)) {
        .variable => {
            const v = Lower.payload(vir, Inst.Variable, i);
            if (v.init.len != 0) return l.refuse("an initialized block-local variable");
            _ = try variable(l, f, i, &.{i});
        },
        .param => _ = try param(l, f, i),
        .event => _ = try event(l, f, i),
        else => {}, // else: a statement or an expression declares nothing
    };
}

/// A §4.2 variable (a `reg`, `integer`, `time`, `real` or `realtime`, an
/// array of them included) bound to fresh slots, x (a real 0.0) at time 0.
pub fn variable(l: *Lower, f: u32, first: Inst.Index, decls: []const Inst.Index) Error!u32 {
    const vir = l.virOf(f);
    var storage: Inst.Storage = .reg;
    var signed = false;
    var range: Vir.Body = .empty;
    var dims: Vir.Body = .empty;
    for (decls) |d| switch (Lower.tag(vir, d)) {
        .io => {
            const io = Lower.payload(vir, Inst.Io, d);
            if (io.flags.storage != .none) storage = io.flags.storage;
            signed = signed or io.flags.signed;
            if (range.len == 0) range = io.range;
            if (dims.len == 0) dims = io.dims;
        },
        .variable => {
            const v = Lower.payload(vir, Inst.Variable, d);
            if (v.flags.storage != .none) storage = v.flags.storage;
            signed = signed or v.flags.signed;
            if (range.len == 0) range = v.range;
            if (dims.len == 0) dims = v.dims;
        },
        else => unreachable, // else: `signal` passes only these two
    };
    var n: Name = .{ .kind = .variable };
    switch (storage) {
        .real, .realtime => n.ty = Type.real_type,
        .integer => n.ty = .{ .width = 32, .signed = true },
        .time => n.ty = .{ .width = 64, .signed = false },
        .string => return l.refuse("a string variable"),
        .reg, .none => n.ty = .{ .width = 1, .signed = signed },
    }
    if (range.len != 0) {
        if (n.ty.real) return l.refuse("a real with a range");
        const r = try rangeOf(l, f, range);
        n.msb = r.msb;
        n.lsb = r.lsb;
        n.ty.width = r.width;
    } else {
        n.msb = @as(i64, n.ty.width) - 1;
        n.scalar = storage == .reg or storage == .none;
    }
    if (storage == .integer or storage == .time) n.scalar = false;
    try arrayOf(l, f, dims, &n);
    n.slot = try slots(l, n.ty, n.count, if (n.ty.real) .zero else .x);
    return l.bind(f, first, n);
}

/// A §4.10 parameter (or specparam, or localparam) of frame `f`: one slot
/// holding its folded value, in its §12.2 type.
pub fn param(l: *Lower, f: u32, i: Inst.Index) Error!u32 {
    const vir = l.virOf(f);
    const p = Lower.payload(vir, Inst.Param, i);
    if (p.dims.len != 0) return l.refuse("a parameter array");
    const env = try l.envAt(f);
    const value = (try env.param(i)) orelse return l.refuse("a parameter value Sema/eval.zig does not fold (an x/z bit or past 64 bits)");
    var n: Name = .{ .kind = .param };
    if (p.range.len != 0) {
        const r = try rangeOf(l, f, p.range);
        n.ty = .{ .width = r.width, .signed = p.flags.signed };
        n.msb = r.msb;
        n.lsb = r.lsb;
    } else switch (p.flags.storage) {
        .integer => n.ty = .{ .width = 32, .signed = true },
        .time => n.ty = .{ .width = 64, .signed = false },
        .real, .realtime => n.ty = Type.real_type,
        .string => return l.refuse("a string parameter"),
        .none, .reg => n.ty = switch (value) {
            .real => Type.real_type,
            .int => |v| .{ .width = if (std.math.cast(i32, v) != null) 32 else 64, .signed = true },
            .str => |s| .{ .width = @intCast(@max(1, s.len) * 8), .signed = false },
        },
    }
    if (p.flags.signed and !n.ty.real) n.ty.signed = true;
    if (p.range.len == 0 and p.flags.storage == .none and value == .int) {
        // §12.2 the type of the final value assigned to it.
        const t = try untypedType(l, f, i);
        n.ty = .{ .width = t.width, .signed = p.flags.signed or t.signed };
    }
    if (p.range.len == 0) n.msb = @as(i64, n.ty.width) - 1;
    const words = Program.words(n.ty.width);
    const v = try l.a.alloc(u64, words);
    const x = try l.a.alloc(u64, words);
    @memset(v, 0);
    @memset(x, 0);
    switch (value) {
        .int => |iv| {
            if (n.ty.real) {
                v[0] = @bitCast(@as(f64, @floatFromInt(iv)));
            } else {
                const bits: u64 = @bitCast(iv);
                v[0] = bits;
                if (n.ty.width < 64) v[0] &= (@as(u64, 1) << @intCast(n.ty.width)) - 1;
                if (words > 1 and iv < 0 and n.ty.signed) for (v[1..]) |*word| {
                    word.* = std.math.maxInt(u64);
                };
                if (words > 1 and n.ty.width % 64 != 0) v[words - 1] &= (@as(u64, 1) << @intCast(n.ty.width % 64)) - 1;
            }
        },
        .real => |rv| {
            if (!n.ty.real) return l.refuse("a real value of an integral parameter");
            v[0] = @bitCast(rv);
        },
        .str => |s| {
            if (n.ty.real) return l.refuse("a string value of a real parameter");
            // §3.6: packed ASCII, the last character in the low byte.
            for (0..@min(s.len, words * 8)) |k| {
                const byte = s[s.len - 1 - k];
                v[k / 8] |= @as(u64, byte) << @intCast((k % 8) * 8);
            }
        },
    }
    n.slot = try l.b.slot(try l.tyOf(n.ty), v, x);
    return l.bind(f, i, n);
}

/// §5.10.4 a named event (an array of them included): one 1-bit slot per
/// element, x.
pub fn event(l: *Lower, f: u32, i: Inst.Index) Error!u32 {
    const vir = l.virOf(f);
    const e = Lower.payload(vir, Inst.Name, i);
    var n: Name = .{ .kind = .event };
    try arrayOf(l, f, e.dims, &n);
    n.slot = try slots(l, n.ty, n.count, .x);
    return l.bind(f, i, n);
}

/// The declared `[msb:lsb]` of a range body, folded.
pub fn rangeOf(l: *Lower, f: u32, range: Vir.Body) Error!struct { msb: i64, lsb: i64, width: u32 } {
    const vir = l.virOf(f);
    const r = vir.body(range);
    const bin = Lower.payload(vir, Inst.Bin, r[r.len - 1]);
    const msb = try l.intOf(f, bin.lhs);
    const lsb = try l.intOf(f, bin.rhs);
    const width = std.math.cast(u32, @abs(@as(i128, msb) - lsb) + 1) orelse return l.refuse("a range past 2^32 bits");
    return .{ .msb = msb, .lsb = lsb, .width = width };
}

/// `count` fresh slots of type `ty`, every bit `fill` (x, or 0).
pub fn slots(l: *Lower, ty: Type, count: u32, fill: enum { x, zero }) Error!u32 {
    const t = try l.tyOf(ty);
    const words = Program.words(t.width);
    const v = try l.a.alloc(u64, words);
    const x = try l.a.alloc(u64, words);
    @memset(v, 0);
    @memset(x, 0);
    if (fill == .x) {
        @memset(v, std.math.maxInt(u64));
        @memset(x, std.math.maxInt(u64));
        if (t.width % 64 != 0) {
            const mask = (@as(u64, 1) << @intCast(t.width % 64)) - 1;
            v[words - 1] &= mask;
            x[words - 1] &= mask;
        }
    }
    const first: u32 = @intCast(l.b.p.slots.len);
    for (0..count) |_| _ = try l.b.slot(t, v, x);
    return first;
}

// ---- private ----

/// §12.2 the self-determined type of the expression that gave untyped
/// parameter `i` of frame `f` its final value: its instance's `#( )`
/// override (by name, or in order among the overridable parameters), else
/// its declaration's own. The `Zcu` keeps no defparam's source, so a
/// parameter a defparam sets is refused.
fn untypedType(l: *Lower, f: u32, i: Inst.Index) Error!Type {
    const vir = l.virOf(f);
    const p = Lower.payload(vir, Inst.Param, i);
    const saved = l.frame;
    defer l.frame = saved;
    var from = f;
    var value = p.value;
    if (l.frames.items[f].parent == none and walk.isOverridable(vir, i)) {
        const k = l.frames.items[f].instance;
        const name = try l.zcu.intern_pool.getString(l.a, vir.string(p.name));
        if (l.zcu.defparam_sources.get(.{ .instance = k, .name = name })) |src| {
            // §12.2.1 a defparam takes precedence: its value as written, in
            // the instance writing it.
            from = try writerFrame(l, src, k);
            const wvir = l.virOf(from);
            const di = src.src.toIndex() orelse return l.refuse("a defparam of no instruction");
            value = Lower.payload(wvir, Inst.Assign, di).rhs;
        } else {
            const site = l.sites[@backingInt(k)];
            if (site.frame != none) if (overrideOf(l, site, vir, @backingInt(k), i)) |b| {
                value = b;
                from = site.frame;
            };
        }
    }
    const b = l.virOf(from).body(value);
    if (b.len == 0) return l.refuse("an untyped parameter with no value");
    l.frame = from;
    return expr.typeOf(l, b[b.len - 1].toRef());
}

/// The frame of the instance writing defparam `src`, which the walk of
/// instance `target` (its target) must have passed already.
fn writerFrame(l: *Lower, src: Zcu.DefparamSource, target: Zcu.Instance.Index) Error!u32 {
    const want = l.zcu.intern_pool.stringToSlice(src.writer);
    for (0..@backingInt(target) + 1) |k| {
        const path = try std.fmt.allocPrint(l.a, "{f}", .{l.zcu.fmtPath(@fromBackingInt(@intCast(k)))});
        if (!std.mem.eql(u8, path, want)) continue;
        const di = src.src.toIndex() orelse return l.refuse("a defparam of no instruction");
        const f = l.defparam_frames.get(.{ .instance = @intCast(k), .inst = di }) orelse l.instance_frame[k];
        if (l.fileOf(f) != src.file) return l.refuse("a defparam its writer's file does not hold");
        return f;
    }
    // A writer walked after its target (a later root): its value's own
    // type needs no names of it, so any frame of its file reads it; one
    // that names something is refused there.
    const f = l.instance_frame[@backingInt(target)];
    if (l.fileOf(f) != src.file) return l.refuse("a defparam written in another file's instance walked after its target");
    return f;
}

/// The value body instance `site` gives parameter `i` of instance `k`'s
/// module `vir`, or null when it gives none.
fn overrideOf(l: *Lower, site: Lower.Site, vir: *const Vir, k: u32, i: Inst.Index) ?Vir.Body {
    const pvir = l.virOf(site.frame);
    if (Lower.tag(pvir, site.inst) != .instance) return null;
    const in = Lower.payload(pvir, Inst.Instance, site.inst);
    const name = vir.string(Lower.payload(vir, Inst.Param, i).name);
    var position: u32 = 0;
    for (l.envs[k].positions.keys()) |q| {
        if (q == i) break;
        position += @intFromBool(walk.isOverridable(vir, q));
    }
    var ordered: u32 = 0;
    for (pvir.list(Inst.Arg, in.params)) |a| {
        const given = pvir.string(a.name);
        const hit = if (given.len == 0) blk: {
            defer ordered += 1;
            break :blk ordered == position;
        } else std.mem.eql(u8, given, name);
        if (hit) return if (a.value.len == 0) null else a.value;
    }
    return null;
}

/// §4.9 the unpacked dimensions of a dims body, outermost first, into `n`.
fn arrayOf(l: *Lower, f: u32, dims: Vir.Body, n: *Name) Error!void {
    if (dims.len == 0) return;
    const vir = l.virOf(f);
    var spans: std.ArrayList(Span) = .empty;
    var count: u64 = 1;
    for (vir.body(dims)) |d| {
        if (Lower.tag(vir, d) != .range) continue;
        const bin = Lower.payload(vir, Inst.Bin, d);
        const hi = try l.intOf(f, bin.lhs);
        const lo = try l.intOf(f, bin.rhs);
        const span: Span = .{ .low = @min(lo, hi), .high = @max(lo, hi) };
        count *= std.math.cast(u64, @as(i128, span.high) - span.low + 1) orelse return l.refuse("an array past 2^24 elements");
        if (count > array_max) return l.refuse("an array past 2^24 elements");
        try spans.append(l.a, span);
    }
    n.dims = spans.items;
    n.count = @intCast(count);
}
