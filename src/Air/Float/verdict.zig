//! The verdict and the words: `Float`'s intervals and NaN bits in, one
//! float mode per root out, ANDed over the root's backward slice (a member
//! is finite when its interval excludes ±inf and it cannot be NaN), with
//! W0650 naming the
//! value that broke an accepted root's proof; and the text of every `Float`
//! diagnostic, naming a value as the user wrote it (a parameter, a probe, a
//! constant, or the unbounded leaf a computed value depends on).
//!
//! A root's slice: its values; every operand of a member; every `assign` to
//! a slot a member `load`s; every `br` to a `block` a member is; and, since
//! under `.optimized` a comparison on inf or NaN is poison and a branch on
//! poison is undefined, the condition of every `cond_br` around a member and
//! of every `cond_br` inside a `loop` around one (its iteration count). §9.19
//! `$param_given` names its argument, it never reads it.
//! Cites: VAMS-2023 §3.4.2, §4.3.2, §4.4, §5.6.1.3, §5.8, §9.19.
//!
//! Contents:
//! - `pub fn report(wip: *Diag.Wip, air: Air, ip: *const InternPool, in: Float.Input, f: *Float, why: []const domain.Why, iv: []const Interval) Allocator.Error!void`
//! - `pub fn rate(gpa: Allocator, arena: Allocator, air: Air, ip: *const InternPool, in: Float.Input, f: *Float, wip: *Diag.Wip) Allocator.Error!void`
//! - `format` on the private `Who` and `IvText`: the words of a value and an interval

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const Allocator = std.mem.Allocator;
const InternPool = @import("intern_pool");
const Diag = @import("vams").Diag;
const Air = @import("../../Air.zig");
const Interval = @import("../Interval.zig");
const Float = @import("../Float.zig");
const domain = @import("domain.zig");
const Inst = Air.Inst;

const none: u32 = std.math.maxInt(u32);

/// Most values `unboundedLeaf` visits, and its stack: the leaf only names
/// the culprit in a message, so a miss costs words, not a proof.
const leaf_visits_max: u32 = 256;
const leaf_stack_max: usize = 64;

/// The nesting, flattened: each instruction's enclosing `block`, `loop` or
/// `cond_br`, and per `alloc` its `assign`s, per `block` its `br`s
/// (`users[off[i]..off[i + 1]]`). Only instructions some body holds.
const Tree = struct {
    parent: []u32,
    off: []u32,
    users: []u32,
};

/// One root's slice walk; `seen` and `around` are shared generation stamps.
const Slice = struct {
    air: Air,
    ip: *const InternPool,
    in: Float.Input,
    f: *const Float,
    tree: Tree,
    seen: []u32,
    around: []u32,
    gen: u32,
    stack: *std.ArrayList(Inst.Ref),
    /// Every `arg` and `probe` the walk met: the inputs of the root's box.
    leaves: *std.ArrayList(u32),
    arena: Allocator,

    /// The first value with no finite bit on the slice, or null. Each
    /// instruction is visited once per root, so the walk is linear.
    fn firstNotFinite(s: Slice) Allocator.Error!?Inst.Ref {
        const tags = s.air.instructions.items(.tag);
        const datas = s.air.instructions.items(.data);
        while (s.stack.pop()) |ref| {
            const inst = ref.toIndex() orelse {
                if (!constFinite(s.ip, ref.toInterned().?)) return ref;
                continue;
            };
            const i = @backingInt(inst);
            if (s.seen[i] == s.gen) continue;
            s.seen[i] = s.gen;
            const tag = tags[i];
            const data = datas[i];
            if (tag != .alloc and s.air.typeOfIndex(s.ip, inst) != .none and !s.f.finite(i)) return ref;
            switch (tag) {
                .load => try s.pushUsers(@backingInt(data.un_op.toIndex().?)),
                .block => try s.pushUsers(i),
                .assign => try s.stack.append(s.arena, data.bin_op.rhs),
                .br => if (data.br.operand != .none) try s.stack.append(s.arena, data.br.operand),
                .select, .store => {
                    const bin = s.air.extraData(Air.Bin, data.pl_op.payload).data;
                    try s.stack.appendSlice(s.arena, &.{ data.pl_op.operand, bin.lhs, bin.rhs });
                },
                .call => {
                    const x = s.air.extraData(Air.Call, data.ty_pl.payload);
                    const facts: Air.CallFacts = if (x.data.callee < s.in.calls.len) s.in.calls[x.data.callee] else .{};
                    if (facts.range != .param_given) try s.stack.appendSlice(s.arena, @ptrCast(s.air.extra[x.end..][0..x.data.args_len]));
                },
                .arg, .probe => try s.leaves.append(s.arena, i),
                .alloc, .anew => {},
                else => switch (Air.tag_info.getPtrConst(tag).class) { // else: the rest read their operands by class
                    .un_op => try s.stack.append(s.arena, data.un_op),
                    .bin_op => try s.stack.appendSlice(s.arena, &.{ data.bin_op.lhs, data.bin_op.rhs }),
                    .pl_op, .ty_pl, .ty, .ty_index, .br, .repeat => unreachable, // each has its prong above; control is never a member
                },
            }
            // The control around `i`: each stamp stops the climb where an
            // earlier member's climb went on.
            var p = s.tree.parent[i];
            while (p != none and s.around[p] != s.gen) : (p = s.tree.parent[p]) {
                s.around[p] = s.gen;
                switch (tags[p]) {
                    .cond_br => try s.stack.append(s.arena, datas[p].pl_op.operand),
                    .loop => try s.pushConds(@fromBackingInt(p), 0),
                    .block => {},
                    else => unreachable, // else: `buildTree` makes a parent only of a block, loop or cond_br
                }
            }
        }
        return null;
    }

    fn pushUsers(s: Slice, i: u32) Allocator.Error!void {
        for (s.tree.users[s.tree.off[i]..s.tree.off[i + 1]]) |u| try s.stack.append(s.arena, .fromIndex(@fromBackingInt(u)));
    }

    /// Pushes the condition of every `cond_br` inside `inst`'s bodies.
    fn pushConds(s: Slice, inst: Inst.Index, depth: u32) Allocator.Error!void {
        assert(depth <= Air.nesting_max);
        const tag = s.air.instructions.items(.tag)[@backingInt(inst)];
        const data = s.air.instructions.items(.data)[@backingInt(inst)];
        const insts = switch (tag) {
            .block, .loop => blk: {
                const x = s.air.extraData(Air.Block, data.ty_pl.payload);
                break :blk s.air.body(x.end, x.data.body_len);
            },
            .cond_br => blk: {
                try s.stack.append(s.arena, data.pl_op.operand);
                const x = s.air.extraData(Air.CondBr, data.pl_op.payload);
                break :blk s.air.body(x.end, x.data.then_body_len + x.data.else_body_len);
            },
            else => return, // else: no other tag has a body
        };
        for (insts) |c| try s.pushConds(c, depth + 1);
    }
};

/// A value named as the user wrote it.
const Who = struct {
    air: Air,
    ip: *const InternPool,
    in: Float.Input,
    f: *const Float,
    ref: Inst.Ref,

    pub fn format(who: Who, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const inst = who.ref.toIndex() orelse return switch (who.ip.indexToKey(who.ref.toInterned().?)) {
            .float => |c| w.print("the constant {d}", .{c}),
            .int => |int| if (int.storage == .small) w.print("the constant {d}", .{int.storage.small}) else w.writeAll("a constant"),
            .undef, .str, .aggregate, .simple_type, .int_type, .array_type, .nature, .discipline => w.writeAll("an unknown value"),
        };
        const data = who.air.instructions.items(.data)[@backingInt(inst)];
        switch (who.air.instructions.items(.tag)[@backingInt(inst)]) {
            .arg => {
                const k = data.ty_index.index;
                if (k < who.in.params.len and who.in.params[k].name.len != 0) return w.print("parameter `{s}`", .{who.in.params[k].name});
                return w.print("parameter {d}", .{k});
            },
            .probe => {
                const k = data.ty_index.index;
                if (k < who.in.probe_names.len and who.in.probe_names[k].len != 0) return w.print("a probe of node `{s}`", .{who.in.probe_names[k]});
                return w.print("a probe of unknown {d}", .{k});
            },
            .call => {
                const facts = callFacts(who.air, who.in, inst);
                if (facts.name.len != 0) return w.print("the result of `{s}()`", .{facts.name});
                return w.writeAll("the result of a call");
            },
            else => { // else: a computed value, named by its leaf
                const leaf = unboundedLeaf(who.air, who.f, inst) orelse return w.writeAll("a computed expression");
                try w.writeAll("an expression of ");
                // A leaf is an `arg` or a `probe`, so this recursion is one deep.
                return (Who{ .air = who.air, .ip = who.ip, .in = who.in, .f = who.f, .ref = .fromIndex(leaf) }).format(w);
            },
        }
    }
};

/// ` with known range [lo:hi]`, or ` with no known bounds`.
const IvText = struct {
    iv: Interval,

    pub fn format(t: IvText, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (t.iv.lo == -math.inf(f64) and t.iv.hi == math.inf(f64)) return w.writeAll(" with no known bounds");
        try w.print(" with known range {c}{d}:{d}{c}", .{ @as(u8, if (t.iv.lo_open) '(' else '['), t.iv.lo, t.iv.hi, @as(u8, if (t.iv.hi_open) ')' else ']') });
    }
};

/// Reports every violation (E0601-E0607, E0609, counted up to
/// `Float.errors_max`), every open integer divisor (W0653) and every range
/// closed on infinity (W0651), in instruction order. `why[i]` is why
/// instruction `i`'s domain is not proven, `iv[i]` the interval of the
/// operand its message describes.
pub fn report(wip: *Diag.Wip, air: Air, ip: *const InternPool, in: Float.Input, f: *Float, why: []const domain.Why, iv: []const Interval) Allocator.Error!void {
    assert(why.len == air.instructions.len);
    for (in.params, 0..) |p, i| try warnInfiniteRange(wip, p, i);
    const tags = air.instructions.items(.tag);
    const datas = air.instructions.items(.data);
    for (why, 0..) |y, i| {
        if (y == .none) continue;
        const t = domain.text(y);
        if (t.code == .W0653) {
            if (!wip.enabled(.W0653)) continue;
        } else {
            assert(f.domain[i] == .violated);
            if (f.error_count == Float.errors_max) continue;
            f.error_count += 1;
        }
        const unary_tag = Air.tag_info.getPtrConst(tags[i]).class == .un_op;
        const operand = if (unary_tag) datas[i].un_op else if (t.operand == 0) datas[i].bin_op.lhs else datas[i].bin_op.rhs;
        try emitDomain(wip, air, ip, in, f, @intCast(i), operand, y, iv[i]);
    }
    assert(f.error_count <= Float.errors_max);
}

/// Writes `f.verdict`: a root is `.optimized` when every value on its
/// slice is finite and no §4.3.2 error was reported, and its box then
/// lists the interval of every input on the slice that needs a check; an
/// accepted `.strict` root gets W0650. The guards are allocated with `gpa`.
/// Asserts that `f` holds the verdict walk's tables.
pub fn rate(gpa: Allocator, arena: Allocator, air: Air, ip: *const InternPool, in: Float.Input, f: *Float, wip: *Diag.Wip) Allocator.Error!void {
    assert(f.verdict.modes.len == in.roots.len);
    assert(f.verdict.guard_start.len == in.roots.len + 1);
    assert(f.nan.len == air.instructions.len);
    const tree = try buildTree(arena, air);
    const n = air.instructions.len;
    // Generation stamps, not cleared per root: `seen[i] == gen` is "on this slice".
    const seen = try arena.alloc(u32, n);
    const around = try arena.alloc(u32, n);
    @memset(seen, none);
    @memset(around, none);
    var stack: std.ArrayList(Inst.Ref) = .empty;
    var leaves: std.ArrayList(u32) = .empty;
    var guards: std.ArrayList(Float.Guard) = .empty;
    for (in.roots, f.verdict.modes, 0..) |root, *mode, u| {
        const gen: u32 = @intCast(u);
        f.verdict.guard_start[u] = @intCast(guards.items.len);
        stack.clearRetainingCapacity();
        leaves.clearRetainingCapacity();
        try stack.appendSlice(arena, root.refs);
        const s: Slice = .{ .air = air, .ip = ip, .in = in, .f = f, .tree = tree, .seen = seen, .around = around, .gen = gen, .stack = &stack, .leaves = &leaves, .arena = arena };
        const culprit = try s.firstNotFinite();
        mode.* = if (culprit == null and f.error_count == 0) .optimized else .strict;
        if (mode.* == .optimized) try appendBox(arena, &guards, air, f, leaves.items);
        if (culprit) |c| if (f.error_count == 0) try warnNotFinite(wip, air, ip, in, f, u, root, c);
    }
    f.verdict.guard_start[in.roots.len] = @intCast(guards.items.len);
    f.verdict.guards = try gpa.dupe(Float.Guard, guards.items);
    for (f.verdict.modes, 0..) |m, r| {
        if (f.error_count != 0) assert(m == .strict);
        if (m == .strict) assert(f.verdict.box(r).len == 0);
    }
}

// ---- private ----

/// Appends one guard per input in `leaves` (the `arg`s and `probe`s an
/// `.optimized` root's slice read) whose interval needs a check: not
/// `whole`, and for an integer parameter not its type's range. One guard
/// per input, however many instructions read it.
fn appendBox(arena: Allocator, guards: *std.ArrayList(Float.Guard), air: Air, f: *const Float, leaves: []const u32) Allocator.Error!void {
    const start = guards.items.len;
    const tags = air.instructions.items(.tag);
    const datas = air.instructions.items(.data);
    for (leaves) |i| {
        const data = datas[i].ty_index;
        const g: Float.Guard = .{ .iv = f.iv[i], .index = data.index, .leaf = if (tags[i] == .arg) .arg else .probe };
        assert(tags[i] == .arg or tags[i] == .probe);
        if (g.iv.whole()) continue;
        if (data.ty == InternPool.Index.integer_type and std.meta.eql(g.iv, Interval.i32_range)) continue;
        const dup = for (guards.items[start..]) |h| {
            if (h.leaf == g.leaf and h.index == g.index) break true;
        } else false;
        if (dup) continue;
        try guards.append(arena, g);
    }
    assert(guards.items.len - start <= leaves.len);
}

/// W0651: a `from` range closed on infinity admits it as a value, which
/// costs every root downstream its proof; the open bound admits the same
/// finite values.
fn warnInfiniteRange(wip: *Diag.Wip, p: Float.Param, index: usize) Allocator.Error!void {
    if (!wip.enabled(.W0651)) return;
    const inf = math.inf(f64);
    const side: []const u8 = for (p.ranges) |r| {
        if (r.kind != .from) continue;
        if (r.lo_inclusive and (r.lo orelse 0) == -inf) break "lower";
        if (r.hi_inclusive and (r.hi orelse 0) == inf) break "upper";
    } else return;
    var b = wip.build(.proof, .W0651, p.loc);
    if (p.name.len != 0) b.msg("`{s}`", .{p.name}) else b.msg("parameter {d}", .{index});
    b.point("{s} bound is closed on infinity", .{side});
    b.help("close the bound instead: `[0:inf)` admits the same finite values", .{});
    try b.emit();
}

/// Reports instruction `inst`'s domain diagnostic `why` (an E06xx error or
/// W0653), describing `operand`, whose interval is `iv`.
fn emitDomain(wip: *Diag.Wip, air: Air, ip: *const InternPool, in: Float.Input, f: *const Float, inst: u32, operand: Inst.Ref, why: domain.Why, iv: Interval) Allocator.Error!void {
    const t = domain.text(why);
    const tag = air.instructions.items(.tag)[inst];
    const what: []const u8 = switch (why) {
        .zero_divisor => if (tag == .idiv) "`/` divisor" else "`%` divisor",
        .int_divisor => "integer `/` divisor",
        .pow_zero_base, .pow_neg_base => "pow() exponent",
        .none, .positive, .gt_neg_one, .non_negative, .unit_closed, .unit_open, .ge_one => Air.tag_info.getPtrConst(tag).label orelse @tagName(tag),
    };
    const at = locOf(in, inst);
    const who: Who = .{ .air = air, .ip = ip, .in = in, .f = f, .ref = operand };
    var b = wip.build(.proof, t.code, at);
    b.msg("{s} is {f}{f}", .{ what, who, IvText{ .iv = iv } });
    const def = refLoc(air, in, operand);
    if (!def.isNone() and def.start != at.start) b.label(def, "{f} originates here", .{who});
    b.point("{s}", .{t.requirement});
    b.help("{s}", .{t.fix});
    try b.emit();
}

fn buildTree(arena: Allocator, air: Air) Allocator.Error!Tree {
    const n = air.instructions.len;
    const t: Tree = .{ .parent = try arena.alloc(u32, n), .off = try arena.alloc(u32, n + 1), .users = undefined };
    @memset(t.parent, none);
    var pairs: std.ArrayList([2]u32) = .empty;
    try place(arena, air, air.mainBody(), none, 0, t.parent, &pairs);
    // Counting sort by key: `off` then `users`.
    @memset(t.off, 0);
    for (pairs.items) |p| t.off[p[0] + 1] += 1;
    for (0..n) |i| t.off[i + 1] += t.off[i];
    const users = try arena.alloc(u32, pairs.items.len);
    const fill = try arena.dupe(u32, t.off[0..n]);
    for (pairs.items) |p| {
        users[fill[p[0]]] = p[1];
        fill[p[0]] += 1;
    }
    assert(t.off[n] == pairs.items.len);
    return .{ .parent = t.parent, .off = t.off, .users = users };
}

fn place(arena: Allocator, air: Air, insts: []const Inst.Index, parent: u32, depth: u32, out: []u32, pairs: *std.ArrayList([2]u32)) Allocator.Error!void {
    assert(depth <= Air.nesting_max);
    for (insts) |inst| {
        const i = @backingInt(inst);
        out[i] = parent;
        const data = air.instructions.items(.data)[i];
        switch (air.instructions.items(.tag)[i]) {
            .block, .loop => {
                const x = air.extraData(Air.Block, data.ty_pl.payload);
                try place(arena, air, air.body(x.end, x.data.body_len), i, depth + 1, out, pairs);
            },
            .cond_br => {
                const x = air.extraData(Air.CondBr, data.pl_op.payload);
                try place(arena, air, air.body(x.end, x.data.then_body_len + x.data.else_body_len), i, depth + 1, out, pairs);
            },
            .assign => try pairs.append(arena, .{ @backingInt(data.bin_op.lhs.toIndex().?), i }),
            .br => try pairs.append(arena, .{ @backingInt(data.br.block_inst), i }),
            else => {}, // else: no other tag nests or names a slot's writer or a block's exit
        }
    }
}

fn constFinite(ip: *const InternPool, index: InternPool.Index) bool {
    return switch (ip.indexToKey(index)) {
        .float => |c| math.isFinite(c),
        .int, .str => true,
        .undef, .aggregate, .simple_type, .int_type, .array_type, .nature, .discipline => false,
    };
}

fn locOf(in: Float.Input, inst: u32) Diag.Loc {
    return if (inst < in.locs.len) in.locs[inst] else .none;
}

/// `call` instruction `i`'s facts (`.{}` past `in.calls`'s end, Walk.zig's
/// own reading of the same table).
fn callFacts(air: Air, in: Float.Input, i: Inst.Index) Air.CallFacts {
    const data = air.instructions.items(.data)[@backingInt(i)];
    assert(air.instructions.items(.tag)[@backingInt(i)] == .call);
    const x = air.extraData(Air.Call, data.ty_pl.payload);
    return if (x.data.callee < in.calls.len) in.calls[x.data.callee] else .{};
}

/// Where whatever defined `ref` was written: a parameter's declaration, an
/// instruction's expression, nothing for a constant.
fn refLoc(air: Air, in: Float.Input, ref: Inst.Ref) Diag.Loc {
    const i = @backingInt(ref.toIndex() orelse return .none);
    const data = air.instructions.items(.data)[i];
    if (air.instructions.items(.tag)[i] == .arg and data.ty_index.index < in.params.len) return in.params[data.ty_index.index].loc;
    return locOf(in, i);
}

/// W0650: a root that is not provably finite. Legal, but it compiles
/// `.strict`, which costs reassociation, fusion and vectorisation, so it
/// names the value that broke the proof and the way to constrain it.
fn warnNotFinite(wip: *Diag.Wip, air: Air, ip: *const InternPool, in: Float.Input, f: *const Float, unit: usize, root: Float.Root, culprit: Inst.Ref) Allocator.Error!void {
    if (!wip.enabled(.W0650)) return;
    assert(f.error_count == 0); // a rejected model warns nothing
    // A caller that locates instructions (research/airpasses.md §0's bug
    // class) must locate and name its roots too: `codegen.floatRoots`
    // builds a `Root` with no name or location, left for `air_passes.run`
    // to fill before this ever runs.
    if (in.locs.len != 0) assert(!root.loc.isNone());
    if (in.locs.len != 0) assert(root.name.len != 0);
    var b = wip.build(.proof, .W0650, root.loc);
    b.msg("unit {d} — {s} — compiles with @setFloatMode(.strict)", .{ unit, root.name });
    const who: Who = .{ .air = air, .ip = ip, .in = in, .f = f, .ref = culprit };
    const def = refLoc(air, in, culprit);
    if (!def.isNone()) b.label(def, "{f} is not provably finite", .{who}) else b.point("{f} is not provably finite", .{who});
    if (culprit.toIndex()) |i| switch (air.instructions.items(.tag)[@backingInt(i)]) {
        .arg => b.help("give the parameter a range that excludes infinity, e.g. `from (0:inf)`", .{}),
        .probe => b.help("a probe is bounded only by `Float.Input.unknown_bound`; give a finite one, the solver's compliance limit", .{}),
        .call => {
            const facts = callFacts(air, in, i);
            if (facts.range == .limexp or facts.range == .vt) {
                b.help("constrain the operands with a range or a guard the prover can see", .{});
            } else if (facts.name.len != 0) {
                b.help("the prover does not model `{s}()`, so its range is unknown", .{facts.name});
            } else {
                b.help("the prover does not model this call, so its range is unknown", .{});
            }
        },
        else => b.help("constrain the operands with a range or a guard the prover can see", .{}), // else: a computed value
    };
    b.note("`.strict` is correct and spec-legal — this warning is about speed, not correctness", .{});
    try b.emit();
}

/// The first `arg` or `probe` with no bound on `root`'s operand slice: the
/// thing the user has to constrain. Budgeted.
fn unboundedLeaf(air: Air, f: *const Float, root: Inst.Index) ?Inst.Index {
    var stack: [leaf_stack_max]Inst.Index = undefined;
    stack[0] = root;
    var n: usize = 1;
    var budget = leaf_visits_max;
    while (n > 0 and budget > 0) : (budget -= 1) {
        n -= 1;
        const i = @backingInt(stack[n]);
        const data = air.instructions.items(.data)[i];
        const tag = air.instructions.items(.tag)[i];
        if (tag == .arg or tag == .probe) {
            if (!f.iv[i].bounded()) return stack[n];
            continue;
        }
        const ops: [2]Inst.Ref = switch (Air.tag_info.getPtrConst(tag).class) {
            .un_op => if (tag == .load) .{ .none, .none } else .{ data.un_op, .none },
            .bin_op => .{ data.bin_op.lhs, data.bin_op.rhs },
            .pl_op, .ty_pl, .ty, .ty_index, .br, .repeat => .{ .none, .none },
        };
        for (ops) |o| if (o.toIndex()) |oi| if (n < stack.len) {
            stack[n] = oi;
            n += 1;
        };
    }
    assert(n == 0 or budget == 0); // the slice ran out, or the budget did
    return null;
}
