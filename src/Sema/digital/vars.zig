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
//! - `pub fn compileParams(l: *Lower) Error!void`
//! - `pub fn finishParams(l: *Lower, p: *Program) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const std_sim = @import("std_sim");
const walk = @import("../walk.zig");
const eval = @import("../eval.zig");
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
        // VAMS §3.6.2 a discipline declaration of a reg (`ddiscrete o; reg
        // o;`) names its discipline only: no storage, no type.
        .net => assert(Lower.payload(vir, Inst.Net, d).flags.net == .none),
        else => unreachable, // else: `signal` passes only these three
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
        // A bound that is no constant is reported at the declaration.
        const r = rangeOf(l, f, range) catch |e| {
            if (e == error.Rejected) l.why_at = l.srcOffset(f, first);
            return e;
        };
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
    // VAMS §7.2.2 a mixed design's string and array parameters are the
    // analog block's (lib/sim/digital's mixed elaboration skips them).
    if (l.options.mixed and (p.dims.len != 0 or p.flags.storage == .string)) return none;
    if (p.dims.len != 0) return l.refuse("a parameter array");
    try paramValueRules(l, f, i, p);
    const env = try l.envAt(f);
    const value = (try env.param(i)) orelse return lateParam(l, f, i);
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
    // §4.3.1 "msb_constant_expression … integer".
    for ([2]Inst.Ref{ bin.lhs, bin.rhs }) |b| if (try l.constOf(f, b)) |c| if (c == .real)
        return l.reject(f, b, "§4.3.1: a bound is a constant integer expression, not a real");
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

/// Compiles every late parameter's value row, in its frame, once every
/// subroutine a constant function call names is declared.
pub fn compileParams(l: *Lower) Error!void {
    const saved = l.frame;
    defer l.frame = saved;
    for (l.late_params.items) |*lp| {
        l.frame = lp.frame;
        lp.row = try expr.evalFor(l, lp.value, lp.ty);
    }
}

/// Evaluates every late parameter's value (`lateParam`), in declaration
/// order so a later one reads an earlier, with the run's own evaluator, and
/// makes it its slot's time-0 value.
pub fn finishParams(l: *Lower, p: *Program) Error!void {
    if (l.late_params.items.len == 0) return;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var s = std_sim.State.init(l.a, p, &discard.writer) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SimFailed, error.WriteFailed => return l.refuse("a design the runtime cannot start"),
    };
    for (l.late_params.items) |lp| {
        const v = std_sim.eval.eval(&s, l.a, lp.row) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SimFailed, error.WriteFailed => return l.refuse("a parameter value the runtime cannot evaluate"),
        };
        const word = p.slots.items(.word)[lp.slot];
        const words = Program.words(p.slots.items(.ty)[lp.slot].width);
        @memcpy(s.v[word..][0..words], v.values()[0..words]);
        @memcpy(s.x[word..][0..words], v.unknowns()[0..words]);
    }
    p.init_v = s.v;
    p.init_x = s.x;
}

// ---- private ----

/// lib/sim/digital's rules on the value parameter `i` takes: a defparam's
/// is constant and reaches no local parameter (§12.2); its own default
/// names only parameters declared before it (§4.10.1), and is constant.
/// ponytail: a `#()` override's value is elaboration's to judge.
fn paramValueRules(l: *Lower, f: u32, i: Inst.Index, p: Inst.Param) Error!void {
    const zcu = l.zcu;
    const vir = l.virOf(f);
    const k = l.frames.items[f].instance;
    const name = vir.string(p.name);
    const constness = @import("constness.zig");
    for (zcu.defparam_sources.keys(), zcu.defparam_sources.values()) |dp, src| {
        if (dp.instance != k or !std.mem.eql(u8, zcu.intern_pool.stringToSlice(dp.name), name)) continue;
        const dvir = zcu.fileVir(src.file);
        const di = src.src.toIndex() orelse return;
        if (p.flags.kind == .localparam or p.flags.local) {
            // At the defparam, as lib/sim/digital reports it.
            l.why = try std.fmt.allocPrint(l.a, "§12.2: `{s}` is a local parameter, which a defparam cannot override", .{name});
            const tree = l.options.sources[@backingInt(src.file)].tree;
            // Its target's first token: back from the `=` past the path.
            var t = tree.nodeMainToken(dvir.instructions.items(.data)[@backingInt(di)].pl_node.src_node);
            while (t > 0 and tree.tokenTag(t - 1) != .keyword_defparam and tree.tokenTag(t - 1) != .comma) t -= 1;
            l.why_at = tree.tokenStart(t);
            return error.Rejected;
        }
        const rhs = dvir.body(Lower.payload(dvir, Inst.Assign, di).rhs);
        if (rhs.len != 0 and try constness.offender(l, dvir, rhs[rhs.len - 1].toRef(), true) != null) return l.reject(f, i.toRef(), "a constant expression is required here");
        return;
    }
    const parent = zcu.instances.items(.parent)[@backingInt(k)];
    if (parent != .none) if (zcu.instances.items(.src)[@backingInt(k)].toIndex()) |src| {
        const pvir = zcu.fileVir(zcu.instances.items(.module)[@backingInt(parent)].file);
        if (Lower.tag(pvir, src) == .instance and Lower.payload(pvir, Inst.Instance, src).params.len != 0) return;
    };
    const b = vir.body(p.value);
    if (b.len == 0) return;
    const value = b[b.len - 1].toRef();
    if (try constness.offender(l, vir, value, true)) |o| {
        if (o.kind == .name) return l.reject(f, o.inst.toRef(), "§4.10.1: a parameter's value is a constant expression of numbers and previously defined parameters, and this name is neither");
        return l.reject(f, i.toRef(), "a constant expression is required here");
    }
    // §4.10.3 "module parameters shall not be assigned a constant expression
    // that includes any specify parameters".
    if (p.flags.kind != .specparam and try constness.readsSpecparam(l, vir, value))
        return l.reject(f, value, "§4.10.3: a module parameter cannot be assigned an expression that includes a specify parameter");
}

/// §12.2 the self-determined type of the expression that gave untyped
/// parameter `i` of frame `f` its final value (`finalValue`).
fn untypedType(l: *Lower, f: u32, i: Inst.Index) Error!Type {
    const saved = l.frame;
    defer l.frame = saved;
    const fv = try finalValue(l, f, i);
    l.frame = fv.frame;
    return expr.typeOf(l, fv.value);
}

/// The expression that gives parameter `i` of frame `f` its final value,
/// and the frame it is written in: a defparam's (§12.2.1, which takes
/// precedence), its instance's `#( )` override (by name, or in order among
/// the overridable parameters), else its declaration's own.
fn finalValue(l: *Lower, f: u32, i: Inst.Index) Error!struct { frame: u32, value: Inst.Ref } {
    const vir = l.virOf(f);
    const p = Lower.payload(vir, Inst.Param, i);
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
    if (b.len == 0) return l.refuse("a parameter with no value");
    return .{ .frame = from, .value = b[b.len - 1].toRef() };
}

/// A parameter whose value `Sema/eval.zig` does not fold (an x or z bit,
/// past 64 bits, a constant function's call): a slot of its §12.2 type,
/// x until `finishParams` evaluates its final value expression at the end
/// of lowering with the run's own evaluator.
fn lateParam(l: *Lower, f: u32, i: Inst.Index) Error!u32 {
    const vir = l.virOf(f);
    const p = Lower.payload(vir, Inst.Param, i);
    if (p.dims.len != 0) return l.refuse("a parameter array");
    var n: Name = .{ .kind = .param };
    if (p.range.len != 0) {
        const r = try rangeOf(l, f, p.range);
        n.ty = .{ .width = r.width, .signed = p.flags.signed };
        n.msb = r.msb;
        n.lsb = r.lsb;
    } else {
        n.ty = switch (p.flags.storage) {
            .integer => .{ .width = 32, .signed = true },
            .time => .{ .width = 64, .signed = false },
            .real, .realtime => Type.real_type,
            .string => return l.refuse("a string parameter"),
            .none, .reg => try untypedType(l, f, i),
        };
        if (p.flags.signed and !n.ty.real) n.ty.signed = true;
        n.msb = @as(i64, n.ty.width) - 1;
    }
    n.slot = try slots(l, n.ty, 1, if (n.ty.real) .zero else .x);
    const fv = try finalValue(l, f, i);
    try @import("constness.zig").constantCalls(l, fv.frame, fv.value);
    // The IEEE 1364 mode folds x/z bits, wide values and constant
    // functions; only what it cannot is evaluated by the run at the end.
    if (!n.ty.real) if (try eval.v1364.value(try l.envAt(fv.frame), fv.value)) |v| if (v == .int) {
        const fitted = v.int.resize(l.a, n.ty.width, if (v.int.signed) .sign else .zero) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ZeroSize => unreachable,
        };
        const word = l.b.p.slots.items(.word)[n.slot];
        const words = Program.words(n.ty.width);
        @memcpy(l.b.init_v.items[word..][0..words], fitted.values()[0..words]);
        @memcpy(l.b.init_x.items[word..][0..words], fitted.unknowns()[0..words]);
        return l.bind(f, i, n);
    };
    try l.late_params.append(l.a, .{ .slot = n.slot, .ty = n.ty, .frame = fv.frame, .value = fv.value });
    return l.bind(f, i, n);
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
