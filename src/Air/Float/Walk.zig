//! One walk of the float pass (`Float.analyze`'s): an `Air` and the leaves'
//! abstract values in, every instruction's interval, NaN bit and domain
//! outcome written into a `Float`'s tables. A recursive descent of the
//! nesting: a guard fact is pushed entering a `cond_br` body and popped
//! leaving it; a block's result is the join of its `br` operands; a slot's
//! state at a block's exit is the join of its states on every `br` to it; a
//! `loop` iterates to a fixpoint, widening after `widen_after` rounds. A fact
//! about one value holds for every value structurally equal to it (a
//! congruence class: the same tag over the same classes, a `load` keyed by
//! its slot's version).
//! Cites: VAMS-2023 §3.4.2, §4.2.3, §4.2.4, §4.2.5, §4.2.7, §4.2.12, §4.3.2,
//! §4.4, §5.8, §5.9.
//!
//! Contents:
//! - `pub const Walk = @This()`
//! - `pub const empty: Interval`
//! - `pub fn init(arena: Allocator, air: Air, ip: *const InternPool, in: Float.Input, f: *Float) Allocator.Error!Walk`
//! - `pub fn body(w: *Walk, insts: []const Inst.Index, depth: u32) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const Allocator = std.mem.Allocator;
const InternPool = @import("intern_pool");
const Air = @import("../../Air.zig");
const Interval = @import("../Interval.zig");
const Float = @import("../Float.zig");
const domains = @import("domain.zig");
const Inst = Air.Inst;
const Abstract = Interval.Abstract;
const Input = Float.Input;
const Domain = Float.Domain;

/// File-as-struct: one walk's state. Scratch on the caller's arena.
pub const Walk = @This();

arena: Allocator,
air: Air,
ip: *const InternPool,
in: Input,
tags: []const Inst.Tag,
datas: []const Inst.Data,
f: *Float,
/// Per instruction: why its last domain check was not proven, and the
/// interval of the operand its message describes.
why: []domains.Why,
dom_iv: []Interval,
/// Per instruction: an `alloc`'s slot; per slot its state here and its
/// version (bumped by every write); per `load` the version it read.
slot_of: []u32,
state: []Abstract,
ver: []u32,
load_ver: []u32,
next_ver: u32 = 0,
/// The walk's point can run (false past a `br` or in a provably untaken arm).
reached: bool = true,
/// Domain violations are reported here (false in a provably untaken arm, §4.2.3).
active: bool = true,
/// Per instruction: its class representative; per representative the
/// meet of the active facts on the class; the undo log.
rep: []u32,
civ: []Interval,
classes: std.AutoHashMapUnmanaged(Key, u32) = .empty,
saved: std.ArrayList(Saved) = .empty,
frames: std.ArrayList(Frame) = .empty,
probe: Abstract,

/// The empty interval: a block nothing leaves, a slot no path reaches.
pub const empty: Interval = .{ .lo = math.inf(f64), .hi = -math.inf(f64) };

/// Rounds a `loop` joins exactly before it widens.
const widen_after: u32 = 3;
const bottom: Abstract = .{ .iv = empty, .nan = false };
const none: u32 = std.math.maxInt(u32);

/// A guard fact: "instruction `inst` lies in `iv` here".
const Fact = struct { inst: u32, iv: Interval };
/// What one fact push overwrote: class `rep`'s fact interval.
const Saved = struct { rep: u32, prev: Interval };
/// A `block` or `loop` around the walk: the join of what reaches its exit
/// (a block's `br`s) or its head again (a loop's `repeat`s).
const Frame = struct { inst: Inst.Index, reached: bool = false, slots: []Abstract, result: Abstract = bottom };
/// A congruence class key: a tag over its operands' classes.
const Key = struct { tag: Inst.Tag, a: u32, b: u32 = 0, c: u32 = 0 };

pub fn init(arena: Allocator, air: Air, ip: *const InternPool, in: Input, f: *Float) Allocator.Error!Walk {
    const n = air.instructions.len;
    const tags = air.instructions.items(.tag);
    const slot_of = try arena.alloc(u32, n);
    var slots: u32 = 0;
    for (tags, slot_of) |tag, *s| {
        s.* = if (tag == .alloc) slots else none;
        slots += @intFromBool(tag == .alloc);
    }
    const bound: ?f64 = if (in.unknown_bound) |b| (if (math.isNan(b)) null else @abs(b)) else null;
    const w: Walk = .{
        .arena = arena,
        .air = air,
        .ip = ip,
        .in = in,
        .tags = tags,
        .datas = air.instructions.items(.data),
        .f = f,
        .why = try arena.alloc(domains.Why, n),
        .dom_iv = try arena.alloc(Interval, n),
        .slot_of = slot_of,
        .state = try arena.alloc(Abstract, slots),
        .ver = try arena.alloc(u32, slots),
        .load_ver = try arena.alloc(u32, n),
        .rep = try arena.alloc(u32, n),
        .civ = try arena.alloc(Interval, n),
        .probe = .{ .iv = if (bound) |b| .{ .lo = -b, .hi = b } else .{ .lo = -math.inf(f64), .hi = math.inf(f64), .lo_open = true, .hi_open = true }, .nan = false },
    };
    @memset(w.why, .none);
    @memset(w.state, bottom);
    @memset(w.ver, 0);
    @memset(w.civ, .top);
    for (w.rep, 0..) |*r, i| r.* = @intCast(i);
    assert(w.state.len == slots);
    return w;
}

/// Walks `insts`, a body ending in its noreturn instruction.
pub fn body(w: *Walk, insts: []const Inst.Index, depth: u32) Allocator.Error!void {
    assert(depth <= Air.nesting_max);
    assert(insts.len != 0);
    for (insts) |inst| {
        const i = @backingInt(inst);
        const data = w.datas[i];
        switch (w.tags[i]) {
            .block => {
                const x = w.air.extraData(Air.Block, data.ty_pl.payload);
                try w.frames.append(w.arena, .{ .inst = inst, .slots = try w.arena.alloc(Abstract, w.state.len) });
                try w.body(w.air.body(x.end, x.data.body_len), depth + 1);
                const fr = w.frames.pop().?;
                w.reached = fr.reached;
                if (fr.reached) @memcpy(w.state, fr.slots);
                w.define(i, fr.result);
            },
            .loop => return w.loop(inst, data, depth),
            .cond_br => return w.condBr(data, depth),
            .br => return w.exit(data.br.block_inst, data.br.operand),
            .repeat => return w.exit(data.repeat.loop_inst, .none),
            .ret => {
                w.reached = false;
                return;
            },
            .alloc => w.write(i, .{ .iv = .point(0), .nan = false }),
            .assign => {
                const v = w.abs(data.bin_op.rhs);
                w.write(@backingInt(data.bin_op.lhs.toIndex().?), v);
                w.define(i, v);
            },
            else => |tag| { // else: the value tags
                var a = w.transfer(i, tag, data);
                // An unprovable domain is not an error (§4.3.2); it costs
                // the result its finiteness.
                if (Air.tag_info.getPtrConst(tag).domain != .all and !w.check(i, tag, data)) a.nan = true;
                w.define(i, a);
                w.classify(i, tag, data);
            },
        }
    }
    unreachable; // a well-formed body ends in a noreturn tag
}

// ---- private ----

/// Joins the walk's state into the frame `br` or `repeat` names.
fn exit(w: *Walk, target: Inst.Index, operand: Inst.Ref) void {
    defer w.reached = false;
    if (!w.reached) return;
    var k = w.frames.items.len;
    const fr = while (k > 0) {
        k -= 1;
        if (w.frames.items[k].inst == target) break &w.frames.items[k];
    } else unreachable; // Verify: a `br` leaves an enclosing block
    if (operand != .none) fr.result = joinAbs(fr.result, w.abs(operand));
    if (fr.reached) {
        for (fr.slots, w.state) |*s, x| s.* = joinAbs(s.*, x);
    } else @memcpy(fr.slots, w.state);
    fr.reached = true;
}

/// Walks both bodies, each under its edge's facts and from the state
/// before the branch. A provably untaken body is walked unreached, with
/// its domains off (§4.2.3).
fn condBr(w: *Walk, data: Inst.Data, depth: u32) Allocator.Error!void {
    const x = w.air.extraData(Air.CondBr, data.pl_op.payload);
    const cond = data.pl_op.operand;
    const c = w.abs(cond).iv;
    const before = try w.arena.dupe(Abstract, w.state);
    const reached = w.reached;
    const active = w.active;
    defer w.active = active;
    try w.arm(w.air.body(x.end, x.data.then_body_len), cond, true, c.lo == 0 and c.hi == 0, depth);
    @memcpy(w.state, before);
    w.reached = reached;
    w.active = active;
    try w.arm(w.air.body(x.end + x.data.then_body_len, x.data.else_body_len), cond, false, c.excludesZero(), depth);
    assert(!w.reached);
}

fn arm(w: *Walk, insts: []const Inst.Index, cond: Inst.Ref, taken: bool, dead: bool, depth: u32) Allocator.Error!void {
    const mark = w.saved.items.len;
    if (dead) {
        w.reached = false;
        w.active = false;
    }
    var buf: [2]Fact = undefined;
    try w.pushFacts(w.condFacts(cond, taken, &buf));
    try w.body(insts, depth + 1);
    w.popFacts(mark);
    assert(w.saved.items.len == mark);
}

/// Iterates the body from the join of the entry state and every
/// `repeat`'s, widening after `widen_after` rounds, until the head stops
/// growing. The last round's tables are the fixpoint's.
fn loop(w: *Walk, inst: Inst.Index, data: Inst.Data, depth: u32) Allocator.Error!void {
    const x = w.air.extraData(Air.Block, data.ty_pl.payload);
    const insts = w.air.body(x.end, x.data.body_len);
    const entry = w.reached;
    const head = try w.arena.dupe(Abstract, w.state);
    try w.frames.append(w.arena, .{ .inst = inst, .slots = try w.arena.alloc(Abstract, w.state.len) });
    const k = w.frames.items.len - 1;
    // Bound: past `widen_after`, a changing round moves one of six
    // one-way features of one slot (each end to infinity, the two
    // openness flags, `nonzero`, `nan`).
    const rounds_max = widen_after + 6 * @as(u32, @intCast(head.len)) + 1;
    var rounds: u32 = 0;
    while (true) : (rounds += 1) {
        assert(rounds <= rounds_max);
        @memcpy(w.state, head);
        w.reached = entry;
        w.frames.items[k].reached = false;
        try w.body(insts, depth + 1);
        const fr = w.frames.items[k];
        if (!fr.reached) break;
        var changed = false;
        for (head, fr.slots) |*h, back| {
            const j = joinAbs(h.*, back);
            if (j.nan == h.nan and std.meta.eql(j.iv, h.iv)) continue;
            changed = true;
            h.* = if (rounds < widen_after) j else .{ .iv = h.iv.widen(j.iv), .nan = j.nan };
        }
        if (!changed) break;
    }
    _ = w.frames.pop();
    w.reached = false;
}

/// Returns the abstract result of value tag `tag` before its domain.
fn transfer(w: *Walk, i: u32, tag: Inst.Tag, data: Inst.Data) Abstract {
    const info = Air.tag_info.getPtrConst(tag);
    return switch (tag) {
        .arg => blk: {
            const int = data.ty_index.ty == InternPool.Index.integer_type;
            const p: []const Interval.Range = if (data.ty_index.index < w.in.params.len) w.in.params[data.ty_index.index].ranges else &.{};
            const iv = Interval.fromRanges(p, int);
            break :blk .{ .iv = iv, .nan = !int and iv.whole() };
        },
        .probe => w.probe,
        .load => blk: {
            const s = w.slot_of[@backingInt(data.un_op.toIndex().?)];
            w.load_ver[i] = w.ver[s];
            break :blk w.state[s];
        },
        // §4.2.12: the arm the condition picks, or both.
        .select => blk: {
            const bin = w.air.extraData(Air.Bin, data.pl_op.payload).data;
            const c = w.abs(data.pl_op.operand).iv;
            if (c.excludesZero()) break :blk w.abs(bin.lhs);
            if (c.lo == 0 and c.hi == 0) break :blk w.abs(bin.rhs);
            break :blk joinAbs(w.abs(bin.lhs), w.abs(bin.rhs));
        },
        // §3.2.2: an array version's interval covers every element; a
        // fresh one is zero, an index outside it reads zero.
        .anew => .{ .iv = .point(0), .nan = false },
        .fload, .iload => blk: {
            const arr = w.abs(data.bin_op.lhs);
            break :blk .{ .iv = arr.iv.join(.point(0)), .nan = arr.nan and tag == .fload };
        },
        .store => blk: {
            const bin = w.air.extraData(Air.Bin, data.pl_op.payload).data;
            break :blk joinAbs(w.abs(data.pl_op.operand), w.abs(bin.rhs));
        },
        .call => blk: {
            const x = w.air.extraData(Air.Call, data.ty_pl.payload);
            const facts: Air.CallFacts = if (x.data.callee < w.in.calls.len) w.in.calls[x.data.callee] else .{};
            const arg: Abstract = if (x.data.args_len == 1) w.abs(@fromBackingInt(w.air.extra[x.end])) else .{ .iv = .top, .nan = true };
            break :blk Interval.call(facts.range, arg);
        },
        .opt_barrier, .dstop => w.abs(data.un_op),
        .if_cast => .{ .iv = w.abs(data.un_op).iv, .nan = false },
        // §4.2.1.1: NaN converts to 0.
        .fi_cast => blk: {
            const a = w.abs(data.un_op);
            const iv = Interval.integer(.fi_cast, a.iv, .top);
            break :blk .{ .iv = if (a.nan) iv.join(.point(0)) else iv, .nan = false };
        },
        // §4.2.5/§4.2.7: decided where the operands' intervals decide it.
        .flt, .fgt, .fle, .fge, .feq, .fne, .ilt, .igt, .ile, .ige, .ieq, .ine => .{ .iv = Interval.compare(
            info.rel.?,
            w.abs(data.bin_op.lhs).iv,
            w.abs(data.bin_op.rhs).iv,
            w.nanFree(data.bin_op.lhs) and w.nanFree(data.bin_op.rhs),
            info.operand == .int,
        ), .nan = false },
        .lognot => blk: {
            const x = w.abs(data.un_op).iv;
            break :blk .{ .iv = if (x.excludesZero()) .point(0) else if (x.lo == 0 and x.hi == 0) .point(1) else .{ .lo = 0, .hi = 1 }, .nan = false };
        },
        else => switch (info.class) { // else: the rest by class
            .un_op => if (info.int)
                .{ .iv = Interval.integer(tag, w.abs(data.un_op).iv, .top), .nan = false }
            else
                Interval.unary(tag, w.abs(data.un_op)),
            .bin_op => if (info.int)
                .{ .iv = Interval.integer(tag, w.abs(data.bin_op.lhs).iv, w.abs(data.bin_op.rhs).iv), .nan = false }
            else
                Interval.binary(tag, w.abs(data.bin_op.lhs), w.abs(data.bin_op.rhs)),
            .pl_op, .ty_pl, .ty, .ty_index, .br, .repeat => unreachable, // each has its prong above or in `body`
        },
    };
}

/// Checks `i`'s domain; returns whether it is proven, recording the
/// outcome for `report`.
fn check(w: *Walk, i: u32, tag: Inst.Tag, data: Inst.Data) bool {
    const unary_tag = Air.tag_info.getPtrConst(tag).class == .un_op;
    const x = w.abs(if (unary_tag) data.un_op else data.bin_op.lhs).iv;
    const y = if (unary_tag) Interval.top else w.abs(data.bin_op.rhs).iv;
    const int_y = !unary_tag and w.integral(data.bin_op.rhs);
    const c = domains.check(tag, x, y, int_y);
    w.f.domain[i] = if (w.active) c.state else .open;
    w.why[i] = if (w.active) c.why else .none;
    if (c.why != .none) w.dom_iv[i] = if (domains.text(c.why).operand == 0) x else y;
    return w.active and c.state == .proven;
}

/// Whether `ref` is provably an integer value (Table 4-14's "integer y").
fn integral(w: *const Walk, ref: Inst.Ref) bool {
    if (ref.toIndex()) |i| {
        const tag = w.tags[@backingInt(i)];
        return tag == .if_cast or w.air.typeOfIndex(w.ip, i) == InternPool.Index.integer_type;
    }
    return switch (w.ip.indexToKey(ref.toInterned().?)) {
        .float => |c| math.isFinite(c) and c == @trunc(c),
        .int => true,
        .undef, .str, .simple_type, .int_type, .array_type, .nature, .discipline => false,
    };
}

/// Returns `ref`'s abstract value here: its own, met with its class's facts.
fn abs(w: *const Walk, ref: Inst.Ref) Abstract {
    if (ref.toIndex()) |inst| {
        const i = @backingInt(inst);
        return .{ .iv = w.f.iv[i].meet(w.civ[w.rep[i]]), .nan = w.f.nan[i] };
    }
    return switch (w.ip.indexToKey(ref.toInterned().?)) {
        .float => |c| .{ .iv = .point(c), .nan = math.isNan(c) },
        .int => |int| switch (int.storage) {
            .small => |v| .{ .iv = .point(@floatFromInt(v)), .nan = false },
            .big => .{ .iv = .top, .nan = false },
        },
        .str => .{ .iv = .top, .nan = false },
        .undef => .{ .iv = .top, .nan = true },
        .simple_type, .int_type, .array_type, .nature, .discipline => unreachable, // Verify: an operand is a value
    };
}

fn define(w: *Walk, i: u32, a: Abstract) void {
    w.f.iv[i] = a.iv;
    w.f.nan[i] = a.nan;
}

/// Writes slot `alloc`'s state; a new version, so no older `load` speaks for it.
fn write(w: *Walk, alloc: u32, a: Abstract) void {
    const s = w.slot_of[alloc];
    assert(s != none);
    w.state[s] = a;
    w.next_ver += 1;
    w.ver[s] = w.next_ver;
}

/// Puts `i` in the class of the first instruction with its key; a tag
/// whose value is not a function of its operands stays alone.
fn classify(w: *Walk, i: u32, tag: Inst.Tag, data: Inst.Data) void {
    const key: Key = switch (tag) {
        .call, .opt_barrier, .anew, .store, .path_prev, .path_acc => return,
        .arg, .probe => .{ .tag = tag, .a = data.ty_index.index, .b = @backingInt(data.ty_index.ty) },
        .load => .{ .tag = tag, .a = w.slot_of[@backingInt(data.un_op.toIndex().?)], .b = w.load_ver[i] },
        .select => blk: {
            const bin = w.air.extraData(Air.Bin, data.pl_op.payload).data;
            break :blk .{ .tag = tag, .a = w.canon(data.pl_op.operand), .b = w.canon(bin.lhs), .c = w.canon(bin.rhs) };
        },
        else => switch (Air.tag_info.getPtrConst(tag).class) { // else: the rest are keyed by class
            .un_op => .{ .tag = tag, .a = w.canon(data.un_op) },
            .bin_op => .{ .tag = tag, .a = w.canon(data.bin_op.lhs), .b = w.canon(data.bin_op.rhs) },
            .pl_op, .ty_pl, .ty, .ty_index, .br, .repeat => unreachable, // `body` keeps the rest
        },
    };
    // ponytail: a failed insert leaves `i` alone, which is sound.
    const gop = w.classes.getOrPut(w.arena, key) catch return;
    if (!gop.found_existing) gop.value_ptr.* = i;
    w.rep[i] = gop.value_ptr.*;
    assert(w.rep[w.rep[i]] == w.rep[i]);
}

fn canon(w: *const Walk, ref: Inst.Ref) u32 {
    const i = ref.toIndex() orelse return @backingInt(ref);
    return @backingInt(Inst.Ref.fromIndex(@fromBackingInt(w.rep[@backingInt(i)])));
}

/// Returns the facts taking (or not) a branch on `cond` gives, in `buf`:
/// `!` and `p != 0` over a predicate peel, a bare `x != 0` gives the
/// §4.2.4 hole, a comparison bounds both sides (§4.2.5, §4.2.7).
fn condFacts(w: *const Walk, cond: Inst.Ref, taken: bool, buf: *[2]Fact) []const Fact {
    var c = cond;
    var t = taken;
    // Bound: each hop moves to an operand defined before its user.
    for (0..w.tags.len + 1) |_| {
        const i = @backingInt(c.toIndex() orelse return buf[0..0]);
        const tag = w.tags[i];
        const data = w.datas[i];
        if (tag == .lognot) {
            c = data.un_op;
            t = !t;
            continue;
        }
        const rel = Air.tag_info.getPtrConst(tag).rel orelse return buf[0..0];
        if (rel == .eq or rel == .ne) {
            const zl = w.isZero(data.bin_op.lhs);
            const other = if (w.isZero(data.bin_op.rhs)) data.bin_op.lhs else if (zl) data.bin_op.rhs else null;
            if (other) |o| {
                const flip = rel == .eq;
                if (o.toIndex()) |oi| if (Air.tag_info.getPtrConst(w.tags[@backingInt(oi)]).predicate) {
                    c = o;
                    t = t != flip;
                    continue;
                };
                if (t == flip) return buf[0..0];
                buf[0] = .{ .inst = @backingInt(o.toIndex() orelse return buf[0..0]), .iv = .{ .nonzero = true } };
                return buf[0..1];
            }
        }
        return w.relation(tag, rel, data, t, buf);
    }
    unreachable; // the hop bound
}

/// The facts of comparison `lhs REL rhs` that went `taken`, as `lo < hi`
/// or `lo <= hi` or `a == b`. A false ordering says the reverse only
/// between numbers (every ordering against NaN is false); an integer's
/// facts close their ends (`@floatFromInt` is monotone, not injective).
fn relation(w: *const Walk, tag: Inst.Tag, rel: Air.Relation, data: Inst.Data, taken: bool, buf: *[2]Fact) []const Fact {
    const ordering = rel != .eq and rel != .ne;
    if (!taken and ordering and !(w.nanFree(data.bin_op.lhs) and w.nanFree(data.bin_op.rhs))) return buf[0..0];
    const Norm = enum { lt, le, eq };
    const norm: Norm, const swap: bool = switch (rel) {
        .lt => if (taken) .{ .lt, false } else .{ .le, true },
        .le => if (taken) .{ .le, false } else .{ .lt, true },
        .gt => if (taken) .{ .lt, true } else .{ .le, false },
        .ge => if (taken) .{ .le, true } else .{ .lt, false },
        .eq => if (taken) .{ .eq, false } else return buf[0..0],
        .ne => if (taken) return buf[0..0] else .{ .eq, false },
    };
    const lo_ref = if (swap) data.bin_op.rhs else data.bin_op.lhs;
    const hi_ref = if (swap) data.bin_op.lhs else data.bin_op.rhs;
    const a = w.abs(lo_ref).iv;
    const b = w.abs(hi_ref).iv;
    const strict = norm == .lt and Air.tag_info.getPtrConst(tag).operand == .real;
    const real = Air.tag_info.getPtrConst(tag).operand == .real;
    const lo_fact: Interval = if (norm == .eq) b else .{ .hi = b.hi, .hi_open = strict or (real and b.hi_open) };
    const hi_fact: Interval = if (norm == .eq) a else .{ .lo = a.lo, .lo_open = strict or (real and a.lo_open) };
    var n: usize = 0;
    for ([_]Inst.Ref{ lo_ref, hi_ref }, [_]Interval{ lo_fact, hi_fact }) |ref, iv| {
        const i = ref.toIndex() orelse continue;
        buf[n] = .{ .inst = @backingInt(i), .iv = iv };
        n += 1;
    }
    assert(n <= buf.len);
    return buf[0..n];
}

fn isZero(w: *const Walk, ref: Inst.Ref) bool {
    const index = ref.toInterned() orelse return false;
    return switch (w.ip.indexToKey(index)) {
        .float => |c| c == 0,
        .int => |int| int.storage == .small and int.storage.small == 0,
        .undef, .str, .simple_type, .int_type, .array_type, .nature, .discipline => false,
    };
}

/// Whether `ref` is never NaN: a number constant, an integer, or a value
/// whose NaN bit is clear (a probe, a parameter with a range).
fn nanFree(w: *const Walk, ref: Inst.Ref) bool {
    const inst = ref.toIndex() orelse return switch (w.ip.indexToKey(ref.toInterned().?)) {
        .float => |c| !math.isNan(c),
        .int, .str => true,
        .undef, .simple_type, .int_type, .array_type, .nature, .discipline => false,
    };
    const i = @backingInt(inst);
    const tag = w.tags[i];
    return Air.tag_info.getPtrConst(tag).int or !w.f.nan[i];
}

/// Applies facts to their classes, and a fact on a `load` that still
/// reads its slot's current version to the slot.
fn pushFacts(w: *Walk, facts: []const Fact) Allocator.Error!void {
    const before = w.saved.items.len;
    for (facts) |fa| {
        const r = w.rep[fa.inst];
        try w.saved.append(w.arena, .{ .rep = r, .prev = w.civ[r] });
        w.civ[r] = w.civ[r].meet(fa.iv);
        if (w.tags[fa.inst] != .load) continue;
        const s = w.slot_of[@backingInt(w.datas[fa.inst].un_op.toIndex().?)];
        if (w.ver[s] == w.load_ver[fa.inst]) w.state[s].iv = w.state[s].iv.meet(fa.iv);
    }
    assert(w.saved.items.len == before + facts.len);
}

/// Undoes every push after `mark`, newest first.
fn popFacts(w: *Walk, mark: usize) void {
    assert(mark <= w.saved.items.len);
    while (w.saved.items.len > mark) {
        const s = w.saved.pop().?;
        w.civ[s.rep] = s.prev;
    }
}

fn joinAbs(a: Abstract, b: Abstract) Abstract {
    return .{ .iv = a.iv.join(b.iv), .nan = a.nan or b.nan };
}
