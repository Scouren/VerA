//! An `Air` in, its first broken invariant out (Zig's `Air/Verify.zig`):
//! the rules `Air.zig`'s header lists, checked in one walk of the nested
//! bodies, with a scope set of the instructions each point may read. The
//! postcondition of every Air producer; `check` panics with the instruction
//! in a safety build and costs nothing in a release one.
//! No LRM clause: this checks VerA's own IR.
//!
//! Contents:
//! - `pub const Rule = enum`
//! - `pub const Violation = struct { inst: Air.Inst.Index, rule: Rule }`
//! - `pub fn verify(gpa: Allocator, air: Air, ip: *const InternPool) Allocator.Error!?Violation`
//! - `pub fn check(gpa: Allocator, air: Air, ip: *const InternPool) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const InternPool = @import("intern_pool");
const Air = @import("../Air.zig");
const Inst = Air.Inst;

/// One invariant of `Air.zig`'s header.
pub const Rule = enum {
    /// An instruction sits in two bodies, or twice in one.
    placement,
    /// A body is empty, does not end in a noreturn tag, or holds one before its end.
    body_end,
    /// An operand is absent, out of range, not a value, or not in scope.
    operand,
    /// `load`/`assign` names something other than an `alloc` in scope, or
    /// another tag names an `alloc`.
    slot,
    /// `br` names no enclosing `block`.
    br_target,
    /// `repeat` names no enclosing `loop`.
    repeat_target,
    /// An operand or a payload type is not the one the tag requires.
    types,
    /// Bodies nest deeper than `Air.nesting_max`.
    nesting,
};

/// The first rule broken, at the instruction that broke it.
pub const Violation = struct { inst: Inst.Index, rule: Rule };

const Walk = struct {
    air: Air,
    ip: *const InternPool,
    /// The instructions the current point may read.
    in_scope: std.DynamicBitSetUnmanaged,
    /// The instructions some body already holds.
    placed: std.DynamicBitSetUnmanaged,
    /// The `block`s and `loop`s around the current point, outermost first.
    enclosing: std.ArrayList(Inst.Index) = .empty,

    /// Walks `insts`; `owner` names the violation of an empty body.
    /// Returns with every instruction of `insts` out of scope again.
    fn body(w: *Walk, gpa: Allocator, insts: []const Inst.Index, owner: Inst.Index, depth: u32) Allocator.Error!?Violation {
        if (depth > Air.nesting_max) return .{ .inst = owner, .rule = .nesting };
        if (insts.len == 0) return .{ .inst = owner, .rule = .body_end };
        defer for (insts) |i| if (@backingInt(i) < w.air.instructions.len) w.in_scope.unset(@backingInt(i));
        for (insts, 0..) |inst, k| {
            if (@backingInt(inst) >= w.air.instructions.len or w.placed.isSet(@backingInt(inst)))
                return .{ .inst = inst, .rule = .placement };
            w.placed.set(@backingInt(inst));
            const tag = w.air.instructions.items(.tag)[@backingInt(inst)];
            if (Air.tag_info.getPtrConst(tag).noreturn != (k == insts.len - 1)) return .{ .inst = inst, .rule = .body_end };
            if (w.instRule(tag, inst)) |rule| return .{ .inst = inst, .rule = rule };
            if (try w.nested(gpa, tag, inst, depth)) |v| return v;
            w.in_scope.set(@backingInt(inst));
        }
        return null;
    }

    /// Checks the bodies of a `block`, `loop` or `cond_br`.
    fn nested(w: *Walk, gpa: Allocator, tag: Inst.Tag, inst: Inst.Index, depth: u32) Allocator.Error!?Violation {
        const data = w.air.instructions.items(.data)[@backingInt(inst)];
        switch (tag) {
            .block, .loop => {
                const x = w.air.extraData(Air.Block, data.ty_pl.payload);
                try w.enclosing.append(gpa, inst);
                defer _ = w.enclosing.pop();
                return w.body(gpa, w.air.body(x.end, x.data.body_len), inst, depth + 1);
            },
            .cond_br => {
                const x = w.air.extraData(Air.CondBr, data.pl_op.payload);
                if (try w.body(gpa, w.air.body(x.end, x.data.then_body_len), inst, depth + 1)) |v| return v;
                return w.body(gpa, w.air.body(x.end + x.data.then_body_len, x.data.else_body_len), inst, depth + 1);
            },
            else => return null, // else: no other tag has a body
        }
    }

    /// Returns the rule `inst`'s own operands and types break, if any.
    fn instRule(w: *Walk, tag: Inst.Tag, i: Inst.Index) ?Rule {
        const data = w.air.instructions.items(.data)[@backingInt(i)];
        const info = Air.tag_info.getPtrConst(tag);
        if (info.operand) |scalar| {
            const want: InternPool.Index = if (scalar == .real) .real_type else .integer_type;
            return switch (info.class) {
                .un_op => w.typed(data.un_op, want),
                .bin_op => w.typed(data.bin_op.lhs, want) orelse w.typed(data.bin_op.rhs, want),
                else => unreachable, // tag_info's comptime check: an operand type means un_op or bin_op
            };
        }
        return switch (tag) {
            .opt_barrier, .dstop, .ret => w.value(data.un_op),
            .select => blk: {
                const bin = w.air.extraData(Air.Bin, data.pl_op.payload).data;
                if (w.typed(data.pl_op.operand, .integer_type) orelse w.value(bin.lhs) orelse w.value(bin.rhs)) |r| break :blk r;
                break :blk if (w.air.typeOf(w.ip, bin.lhs) == w.air.typeOf(w.ip, bin.rhs)) null else .types;
            },
            .anew => if (w.arrayOf(data.ty_pl.ty) != null) null else .types,
            .fload, .iload => blk: {
                if (w.value(data.bin_op.lhs) orelse w.typed(data.bin_op.rhs, .integer_type)) |r| break :blk r;
                const elem = w.arrayOf(w.air.typeOf(w.ip, data.bin_op.lhs)) orelse break :blk .types;
                break :blk if (elem == (if (tag == .iload) InternPool.Index.integer_type else InternPool.Index.real_type)) null else .types;
            },
            .store => blk: {
                const bin = w.air.extraData(Air.Bin, data.pl_op.payload).data;
                if (w.value(data.pl_op.operand) orelse w.typed(bin.lhs, .integer_type)) |r| break :blk r;
                const elem = w.arrayOf(w.air.typeOf(w.ip, data.pl_op.operand)) orelse break :blk .types;
                break :blk w.typed(bin.rhs, elem);
            },
            .call => blk: {
                const x = w.air.extraData(Air.Call, data.ty_pl.payload);
                for (w.air.extra[x.end..][0..x.data.args_len]) |a| if (w.value(@fromBackingInt(a))) |r| break :blk r;
                break :blk if (data.ty_pl.ty == .none or w.isType(data.ty_pl.ty)) null else .types;
            },
            .arg => if (w.isType(data.ty_index.ty)) null else .types,
            .probe => if (data.ty_index.ty == InternPool.Index.real_type) null else .types,
            .alloc => if (w.isType(data.ty)) null else .types,
            .load => w.slot(data.un_op),
            .assign => w.slot(data.bin_op.lhs) orelse w.typed(data.bin_op.rhs, w.air.typeOfIndex(w.ip, data.bin_op.lhs.toIndex().?)),
            .block => if (data.ty_pl.ty == .none or w.isType(data.ty_pl.ty)) null else .types,
            .loop => if (data.ty_pl.ty == .none) null else .types,
            .br => blk: {
                const target = data.br.block_inst;
                if (!w.encloses(target, .block)) break :blk .br_target;
                const ty = w.air.instructions.items(.data)[@backingInt(target)].ty_pl.ty;
                if (ty == .none) break :blk if (data.br.operand == .none) null else .types;
                break :blk w.typed(data.br.operand, ty);
            },
            .repeat => if (w.encloses(data.repeat.loop_inst, .loop)) null else .repeat_target,
            .cond_br => w.typed(data.pl_op.operand, .integer_type),
            else => unreachable, // else: every tag with an `operand` type returned above
        };
    }

    /// `.operand`/`.slot` unless `r` is a value the current point may read.
    fn value(w: *const Walk, r: Inst.Ref) ?Rule {
        if (r == .none) return .operand;
        if (r.toIndex()) |i| {
            if (@backingInt(i) >= w.air.instructions.len or !w.in_scope.isSet(@backingInt(i))) return .operand;
            const tag = w.air.instructions.items(.tag)[@backingInt(i)];
            if (tag == .alloc) return .slot;
            return if (w.air.typeOfIndex(w.ip, i) == .none) .operand else null;
        }
        const index = r.toInterned().?;
        if (@backingInt(index) >= w.ip.items.len) return .operand;
        return switch (w.ip.indexToKey(index)) {
            .float, .int, .str, .undef => null,
            .simple_type, .int_type, .array_type, .nature, .discipline => .operand,
        };
    }

    /// `value`, then `.types` unless `r` has type `ty`.
    fn typed(w: *const Walk, r: Inst.Ref, ty: InternPool.Index) ?Rule {
        if (w.value(r)) |rule| return rule;
        return if (w.air.typeOf(w.ip, r) == ty) null else .types;
    }

    fn slot(w: *const Walk, r: Inst.Ref) ?Rule {
        const i = r.toIndex() orelse return .slot;
        if (@backingInt(i) >= w.air.instructions.len or !w.in_scope.isSet(@backingInt(i))) return .slot;
        return if (w.air.instructions.items(.tag)[@backingInt(i)] == .alloc) null else .slot;
    }

    fn encloses(w: *const Walk, target: Inst.Index, tag: Inst.Tag) bool {
        if (@backingInt(target) >= w.air.instructions.len) return false;
        if (w.air.instructions.items(.tag)[@backingInt(target)] != tag) return false;
        return std.mem.findScalar(Inst.Index, w.enclosing.items, target) != null;
    }

    fn isType(w: *const Walk, ty: InternPool.Index) bool {
        if (ty == .none or @backingInt(ty) >= w.ip.items.len) return false;
        return switch (w.ip.indexToKey(ty)) {
            .simple_type, .int_type, .array_type => true,
            .nature, .discipline, .undef, .float, .int, .str => false,
        };
    }

    fn arrayOf(w: *const Walk, ty: InternPool.Index) ?InternPool.Index {
        if (!w.isType(ty)) return null;
        const k = w.ip.indexToKey(ty);
        return if (k == .array_type) k.array_type.elem else null;
    }
};

/// One small body per rule, and the well-formed body each one breaks.
const Case = struct {
    gpa: Allocator,
    ip: *InternPool,
    b: Air.Builder,

    fn init(gpa: Allocator, ip: *InternPool) !Case {
        return .{ .gpa = gpa, .ip = ip, .b = try .init(gpa) };
    }
    /// Verifies the Air whose main body is `main` and frees it.
    fn run(c: *Case, main: []const Inst.Index) !?Violation {
        var air = try c.b.finish(c.gpa, main);
        defer air.deinit(c.gpa);
        c.b.deinit(c.gpa);
        return verify(c.gpa, air, c.ip);
    }
    fn arg(c: *Case, ty: InternPool.Index) !Inst.Index {
        return c.b.addInst(c.gpa, .{ .tag = .arg, .data = .{ .ty_index = .{ .ty = ty, .index = 0 } } });
    }
};

/// Returns the first violation in body order, or null for a well-formed
/// `air`. Allocates scratch from `gpa` and frees it before returning.
pub fn verify(gpa: Allocator, air: Air, ip: *const InternPool) Allocator.Error!?Violation {
    const n = air.instructions.len;
    var w: Walk = .{ .air = air, .ip = ip, .in_scope = try .initEmpty(gpa, n), .placed = undefined };
    defer w.in_scope.deinit(gpa);
    w.placed = try .initEmpty(gpa, n);
    defer w.placed.deinit(gpa);
    defer w.enclosing.deinit(gpa);
    const main = air.mainBody();
    assert(main.len != 0);
    const found = try w.body(gpa, main, main[main.len - 1], 0);
    if (found == null) assert(w.in_scope.count() == 0);
    return found;
}

/// Panics with the violation `verify` finds, in a safety build only.
pub fn check(gpa: Allocator, air: Air, ip: *const InternPool) Allocator.Error!void {
    if (!std.debug.runtime_safety) return;
    const v = try verify(gpa, air, ip) orelse return;
    std.debug.panic("Air verify: %{d} ({s}) breaks `{s}`", .{ @backingInt(v.inst), @tagName(air.instructions.items(.tag)[@backingInt(v.inst)]), @tagName(v.rule) });
}

// ---- private ----

fn expectRule(want: ?Rule, got: ?Violation) !void {
    try std.testing.expectEqual(want, if (got) |v| v.rule else null);
}

test "verify: a well-formed body with a slot, a loop and a block passes" {
    // sum = 0; loop { if (sum < 3.0) { sum = sum + 1.0; repeat } else br out }
    const gpa = std.testing.allocator;
    var ip = try InternPool.init(gpa);
    defer ip.deinit(gpa);
    var c = try Case.init(gpa, &ip);
    const b = &c.b;
    const s = try b.addInst(gpa, .{ .tag = .alloc, .data = .{ .ty = .real_type } });
    const out = try b.addInst(gpa, .{ .tag = .block, .data = undefined });
    const lp = try b.addInst(gpa, .{ .tag = .loop, .data = undefined });
    const v = try b.addUnOp(gpa, .load, .fromIndex(s));
    const lt = try b.addBinOp(gpa, .flt, .fromIndex(v), .fromIntern(try ip.get(gpa, .{ .float = 3.0 })));
    const v1 = try b.addBinOp(gpa, .fadd, .fromIndex(v), .fromIntern(.one_real));
    const set = try b.addBinOp(gpa, .assign, .fromIndex(s), .fromIndex(v1));
    const again = try b.addInst(gpa, .{ .tag = .repeat, .data = .{ .repeat = .{ .loop_inst = lp } } });
    const leave = try b.addInst(gpa, .{ .tag = .br, .data = .{ .br = .{ .block_inst = out, .operand = .none } } });
    const cb = try b.addCondBr(gpa, .fromIndex(lt), &.{ v1, set, again }, &.{leave});
    try b.setBody(gpa, lp, .none, &.{ v, lt, cb });
    try b.setBody(gpa, out, .none, &.{lp});
    const r = try b.addUnOp(gpa, .load, .fromIndex(s));
    const ret = try b.addUnOp(gpa, .ret, .fromIndex(r));
    try expectRule(null, try c.run(&.{ s, out, r, ret }));
}

test "verify: each rule fires on the body that breaks it" {
    // Oracle: each body is built to break exactly one rule, named beside it.
    const gpa = std.testing.allocator;
    var ip = try InternPool.init(gpa);
    defer ip.deinit(gpa);
    { // body_end: the main body does not end in a noreturn tag.
        var c = try Case.init(gpa, &ip);
        const a = try c.arg(.real_type);
        try expectRule(.body_end, try c.run(&.{a}));
    }
    { // body_end: a ret before the end.
        var c = try Case.init(gpa, &ip);
        const r = try c.b.addUnOp(gpa, .ret, .fromIntern(.one_real));
        const r2 = try c.b.addUnOp(gpa, .ret, .fromIntern(.one_real));
        try expectRule(.body_end, try c.run(&.{ r, r2 }));
    }
    { // placement: one instruction twice.
        var c = try Case.init(gpa, &ip);
        const a = try c.arg(.real_type);
        const r = try c.b.addUnOp(gpa, .ret, .fromIndex(a));
        try expectRule(.placement, try c.run(&.{ a, a, r }));
    }
    { // operand: read before its definition.
        var c = try Case.init(gpa, &ip);
        const a = try c.arg(.real_type);
        const r = try c.b.addUnOp(gpa, .ret, .fromIndex(a));
        try expectRule(.operand, try c.run(&.{r}));
    }
    { // operand: a value read after the block it was defined in.
        var c = try Case.init(gpa, &ip);
        const blk = try c.b.addInst(gpa, .{ .tag = .block, .data = undefined });
        const x = try c.b.addUnOp(gpa, .fneg, .fromIntern(.one_real));
        const br = try c.b.addInst(gpa, .{ .tag = .br, .data = .{ .br = .{ .block_inst = blk, .operand = .none } } });
        try c.b.setBody(gpa, blk, .none, &.{ x, br });
        const r = try c.b.addUnOp(gpa, .ret, .fromIndex(x));
        try expectRule(.operand, try c.run(&.{ blk, r }));
    }
    { // types: fadd over an integer.
        var c = try Case.init(gpa, &ip);
        const x = try c.b.addBinOp(gpa, .fadd, .fromIntern(.one), .fromIntern(.one_real));
        const r = try c.b.addUnOp(gpa, .ret, .fromIndex(x));
        try expectRule(.types, try c.run(&.{ x, r }));
    }
    { // types: a br operand not of the block's type.
        var c = try Case.init(gpa, &ip);
        const blk = try c.b.addInst(gpa, .{ .tag = .block, .data = undefined });
        const br = try c.b.addInst(gpa, .{ .tag = .br, .data = .{ .br = .{ .block_inst = blk, .operand = .fromIntern(.one) } } });
        try c.b.setBody(gpa, blk, .real_type, &.{br});
        const r = try c.b.addUnOp(gpa, .ret, .fromIndex(blk));
        try expectRule(.types, try c.run(&.{ blk, r }));
    }
    { // slot: an alloc read as a value; a load of a non-alloc.
        var c = try Case.init(gpa, &ip);
        const s = try c.b.addInst(gpa, .{ .tag = .alloc, .data = .{ .ty = .real_type } });
        const r = try c.b.addUnOp(gpa, .ret, .fromIndex(s));
        try expectRule(.slot, try c.run(&.{ s, r }));
        var c2 = try Case.init(gpa, &ip);
        const a = try c2.arg(.real_type);
        const l = try c2.b.addUnOp(gpa, .load, .fromIndex(a));
        const r2 = try c2.b.addUnOp(gpa, .ret, .fromIndex(l));
        try expectRule(.slot, try c2.run(&.{ a, l, r2 }));
    }
    { // br_target: a br out of no enclosing block.
        var c = try Case.init(gpa, &ip);
        const blk = try c.b.addInst(gpa, .{ .tag = .block, .data = undefined });
        const in = try c.b.addInst(gpa, .{ .tag = .br, .data = .{ .br = .{ .block_inst = blk, .operand = .none } } });
        try c.b.setBody(gpa, blk, .none, &.{in});
        const stray = try c.b.addInst(gpa, .{ .tag = .br, .data = .{ .br = .{ .block_inst = blk, .operand = .none } } });
        try expectRule(.br_target, try c.run(&.{ blk, stray }));
    }
    { // repeat_target: a repeat of a block.
        var c = try Case.init(gpa, &ip);
        const blk = try c.b.addInst(gpa, .{ .tag = .block, .data = undefined });
        const rp = try c.b.addInst(gpa, .{ .tag = .repeat, .data = .{ .repeat = .{ .loop_inst = blk } } });
        try c.b.setBody(gpa, blk, .none, &.{rp});
        const r = try c.b.addUnOp(gpa, .ret, .fromIntern(.one_real));
        try expectRule(.repeat_target, try c.run(&.{ blk, r }));
    }
    { // nesting: loops nested past nesting_max (a loop is noreturn, so it ends a body).
        var c = try Case.init(gpa, &ip);
        var inner: Inst.Index = try c.b.addUnOp(gpa, .ret, .fromIntern(.one_real));
        for (0..Air.nesting_max + 1) |_| {
            const lp = try c.b.addInst(gpa, .{ .tag = .loop, .data = undefined });
            try c.b.setBody(gpa, lp, .none, &.{inner});
            inner = lp;
        }
        try expectRule(.nesting, try c.run(&.{inner}));
    }
}
