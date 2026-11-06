//! What the Zig backend knows of an `Air` body before it writes a line
//! (Zig's `Air/Liveness.zig` for this backend): per instruction the solver
//! unknowns its value may depend on (`masks`: the derivative lanes the
//! emitted family value carries, `zOf(S, mask)`), whether anything reads it
//! (`used`: a pure value nothing reads is not emitted, since Zig refuses an
//! unused local), and per `alloc` whether anything writes it (`assigned`: a
//! slot nothing writes is a `const`). Slots and `block` results join every
//! value written to them, flow-insensitively, to a fixed point.
//! Cites: VAMS-2023 §4.4 (probes), §5.7 (assignments), §4.5.14 (`ddx`).
//!
//! The data, by `data-oriented-design`'s six questions:
//! 1. In: one `Air`. Out: three columns over its instructions.
//! 2. One per device; tens to tens of thousands of rows.
//! 3. Row `i` is `Air.Inst.Index` `i`; a mask is one bit per unknown, at
//!    most `unknowns_max` of them.
//! 4. Read by row while `Function` renders an instruction.
//! 5. Lives for one `generate`.
//! 6. Written once by `init`, read only after.
//!
//! Contents:
//! - fields `masks`, `used`, `assigned`, `targeted`
//! - `pub const Mask = u64`, `pub const unknowns_max: u32`
//! - `pub fn init(arena: Allocator, air: Air, n_u: u32, roots: ?[]const bool) error{ OutOfMemory, TooManyUnknowns }!Liveness`
//! - `pub fn maskOf(l: Liveness, ref: Air.Inst.Ref) Mask`
//! - `pub fn effect(air: Air, tag: Air.Inst.Tag, data: Air.Inst.Data) bool`
//! - `pub const Operands = struct` (`collect`, `slice`)

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Air = @import("air");
const Inst = Air.Inst;
const SysFn = @import("vams").SysFn;

/// The unknowns a value may depend on: bit `u` is unknown `u`.
pub const Mask = u64;
/// Most unknowns a device may have: one `Mask` bit each.
// ponytail: one word per mask; `contract.MaskOf` past 64 unknowns needs a
// wide mask (a `[]u64` column of `mw` words), add it with the first such fixture.
pub const unknowns_max: u32 = @bitSizeOf(Mask);

/// Per instruction: the unknowns its value (an `alloc`'s: every value
/// assigned to it; a `block`'s: every `br` operand) may depend on.
masks: []Mask,
/// Per instruction: some instruction reads it as an operand.
used: []bool,
/// Per instruction: an `alloc` some `assign` writes.
assigned: []bool,
/// Per instruction: a `block` some `br` leaves (an unbroken one needs no label).
targeted: []bool,

/// The value operands of one instruction (a `call`'s arguments, a
/// `select`'s three, ...), at most `max` of them; the rest of a long call
/// are read through `rest`.
pub const Operands = struct {
    buf: [3]Inst.Ref = undefined,
    len: u8 = 0,
    rest: []const u32 = &.{},

    /// Fills the operands of instruction (`tag`, `data`).
    pub fn collect(o: *Operands, air: Air, tag: Inst.Tag, data: Inst.Data) void {
        assert(o.len == 0);
        switch (tag) {
            .select, .store => {
                const bin = air.extraData(Air.Bin, data.pl_op.payload).data;
                o.push(data.pl_op.operand);
                o.push(bin.lhs);
                o.push(bin.rhs);
            },
            .cond_br => o.push(data.pl_op.operand),
            .call => {
                const x = air.extraData(Air.Call, data.ty_pl.payload);
                o.rest = air.extra[x.end..][0..x.data.args_len];
            },
            .br => o.push(data.br.operand),
            .anew, .arg, .probe, .alloc, .block, .loop, .repeat => {},
            else => switch (Air.tag_info.getPtrConst(tag).class) { // else: the rest read their operands by class
                .un_op => o.push(data.un_op),
                .bin_op => {
                    o.push(data.bin_op.lhs);
                    o.push(data.bin_op.rhs);
                },
                .pl_op, .ty_pl, .ty, .ty_index, .br, .repeat => unreachable, // each has its prong above
            },
        }
    }

    fn push(o: *Operands, r: Inst.Ref) void {
        if (r == .none) return;
        o.buf[o.len] = r;
        o.len += 1;
    }

    /// The operands, the fixed ones then a call's.
    pub fn slice(o: *const Operands) []const Inst.Ref {
        if (o.rest.len != 0) {
            assert(o.len == 0);
            return @ptrCast(o.rest);
        }
        return o.buf[0..o.len];
    }
};

const Liveness = @This();

/// Computes the three columns of `air`, whose probes read `n_u` unknowns,
/// into `arena`; `roots`, per instruction, adds effects (the display tasks
/// `say` records). Fails with `error.TooManyUnknowns` past `unknowns_max`.
pub fn init(arena: Allocator, air: Air, n_u: u32, roots: ?[]const bool) error{ OutOfMemory, TooManyUnknowns }!Liveness {
    if (n_u > unknowns_max) return error.TooManyUnknowns;
    const n = air.instructions.len;
    const l: Liveness = .{
        .masks = try arena.alloc(Mask, n),
        .used = try arena.alloc(bool, n),
        .assigned = try arena.alloc(bool, n),
        .targeted = try arena.alloc(bool, n),
    };
    @memset(l.masks, 0);
    @memset(l.used, false);
    @memset(l.assigned, false);
    @memset(l.targeted, false);
    const tags = air.instructions.items(.tag);
    const datas = air.instructions.items(.data);
    for (tags, datas) |tag, data| {
        if (tag == .assign) l.assigned[@backingInt(data.bin_op.lhs.toIndex().?)] = true;
        if (tag == .br) l.targeted[@backingInt(data.br.block_inst)] = true;
    }
    // Only the main body's instructions run in `core`: a derived
    // parameter's tree (`Param.derive`) sits outside it and reads args the
    // body may not.
    const reach = try arena.alloc(bool, n);
    @memset(reach, false);
    markReach(air, air.mainBody(), reach);
    // Backward from the effects: a value only a print reads is dead in the
    // residual. Operands mostly precede their readers, so a reverse sweep
    // settles in a pass or two; each pass that changes marks a new value.
    var sweep: usize = 0;
    while (l.markUsed(air, reach, roots)) : (sweep += 1) assert(sweep <= n);
    // Each pass only ORs bits in, so it stops: at most one pass per bit of
    // every slot and block, plus the pass that sees nothing change.
    const passes_max = n * unknowns_max + 2;
    var pass: usize = 0;
    while (l.propagate(air)) : (pass += 1) assert(pass < passes_max);
    assert(l.masks.len == n);
    return l;
}

/// The unknowns operand `ref` may depend on; 0 for a constant.
pub fn maskOf(l: Liveness, ref: Inst.Ref) Mask {
    assert(ref != .none);
    const i = ref.toIndex() orelse return 0;
    return l.masks[@backingInt(i)];
}

/// Whether an instruction runs for what it does, not for its value: control,
/// an assignment, a call that changes what a later evaluation sees (a §9.13
/// draw, a §9.5 file task). A §9.4 print or §9.7 control task runs in the
/// device's display phase, and an operator's history moves in
/// `updateState`, so neither runs in `core` for its own sake.
pub fn effect(air: Air, tag: Inst.Tag, data: Inst.Data) bool {
    return switch (tag) {
        .block, .loop, .cond_br, .br, .repeat, .ret, .assign => true,
        .call => {
            const callee = air.extraData(Air.Call, data.ty_pl.payload).data.callee;
            // A user system task (§12, no `SysFn` row) runs in the display phase too.
            if (callee > std.math.maxInt(@typeInfo(SysFn.Tag).@"enum".tag_type)) return false;
            return switch (SysFn.get(@fromBackingInt(@intCast(callee))).family) {
                .random, .file_out, .file_func => true,
                else => false, // else: a value, or a task of another phase
            };
        },
        else => false, // else: a value
    };
}

// ---- private ----

/// One reverse pass: every operand of a live instruction (an effect, or a
/// value some live instruction reads) is used. Returns whether any mark
/// was new.
fn markUsed(l: Liveness, air: Air, reach: []const bool, roots: ?[]const bool) bool {
    const tags = air.instructions.items(.tag);
    const datas = air.instructions.items(.data);
    var grew = false;
    var i = tags.len;
    while (i > 0) {
        i -= 1;
        if (!reach[i]) continue;
        const root = if (roots) |r| r[i] else false;
        if (!l.used[i] and !root and !effect(air, tags[i], datas[i])) continue;
        var ops: Operands = .{};
        ops.collect(air, tags[i], datas[i]);
        for (ops.slice()) |r| if (r.toIndex()) |o| {
            if (!l.used[@backingInt(o)]) grew = true;
            l.used[@backingInt(o)] = true;
        };
    }
    return grew;
}

/// Marks every instruction of `body` and of the bodies nested in it. Each
/// instruction sits in one body, so the walk is bounded by `air`.
fn markReach(air: Air, body: []const Inst.Index, reach: []bool) void {
    const tags = air.instructions.items(.tag);
    const datas = air.instructions.items(.data);
    for (body) |inst| {
        const i = @backingInt(inst);
        assert(!reach[i]);
        reach[i] = true;
        switch (tags[i]) {
            .block, .loop => {
                const x = air.extraData(Air.Block, datas[i].ty_pl.payload);
                markReach(air, air.body(x.end, x.data.body_len), reach);
            },
            .cond_br => {
                const x = air.extraData(Air.CondBr, datas[i].pl_op.payload);
                markReach(air, air.body(x.end, x.data.then_body_len), reach);
                markReach(air, air.body(x.end + x.data.then_body_len, x.data.else_body_len), reach);
            },
            else => {}, // else: no nested body
        }
    }
}

/// One pass over every instruction in index order; returns whether any
/// mask grew.
fn propagate(l: Liveness, air: Air) bool {
    const tags = air.instructions.items(.tag);
    const datas = air.instructions.items(.data);
    var grew = false;
    for (tags, datas, 0..) |tag, data, i| {
        const m: Mask = switch (tag) {
            .probe => if (data.ty_index.index < unknowns_max) @as(Mask, 1) << @intCast(data.ty_index.index) else 0,
            .load => l.maskOf(data.un_op),
            .assign => {
                grew = l.orInto(@backingInt(data.bin_op.lhs.toIndex().?), l.maskOf(data.bin_op.rhs)) or grew;
                continue;
            },
            .br => {
                if (data.br.operand != .none) grew = l.orInto(@backingInt(data.br.block_inst), l.maskOf(data.br.operand)) or grew;
                continue;
            },
            .store => blk: {
                const bin = air.extraData(Air.Bin, data.pl_op.payload).data;
                break :blk l.maskOf(data.pl_op.operand) | l.maskOf(bin.rhs);
            },
            .select => blk: {
                const bin = air.extraData(Air.Bin, data.pl_op.payload).data;
                break :blk l.maskOf(bin.lhs) | l.maskOf(bin.rhs);
            },
            .fload => l.maskOf(data.bin_op.lhs),
            // A real's lanes are its operands'; an integer, a derivative stop
            // and a latch carry none.
            .fadd, .fsub, .fmul, .fdiv, .fmod, .pow, .hypot, .fmin, .fmax, .atan2 => l.maskOf(data.bin_op.lhs) | l.maskOf(data.bin_op.rhs),
            .fneg, .sqrt, .exp, .expm1, .ln, .ln1p, .log10, .floor, .ceil, .fabs, .sin, .cos, .tan, .asin, .acos, .atan, .sinh, .cosh, .tanh, .asinh, .acosh, .atanh, .opt_barrier => l.maskOf(data.un_op),
            .call => blk: {
                const x = air.extraData(Air.Call, data.ty_pl.payload);
                var acc: Mask = 0;
                for (air.extra[x.end..][0..x.data.args_len]) |w| {
                    const r: Inst.Ref = @fromBackingInt(w);
                    if (r != .none) acc |= l.maskOf(r);
                }
                break :blk acc;
            },
            // Blocks and slots gather from their `br`s and `assign`s above.
            .block, .alloc => continue,
            // Integers, comparisons, casts to integer, `dstop`, the §5.6.1.2
            // latches, `arg`, `anew` and the control tags carry no lanes.
            else => 0, // else: every tag above the lanes come from
        };
        grew = l.orInto(@intCast(i), m) or grew;
    }
    return grew;
}

fn orInto(l: Liveness, i: u32, m: Mask) bool {
    const before = l.masks[i];
    l.masks[i] = before | m;
    return l.masks[i] != before;
}

test "Liveness: a slot joins every value assigned to it; a constant has no lanes" {
    // %0 = probe 0, %1 = probe 1, %2 = alloc, assign(%2, %0), assign(%2, %1),
    // %5 = load(%2), %6 = fmul(%5, 2.0), ret: the load carries both lanes.
    const gpa = std.testing.allocator;
    var b = try Air.Builder.init(gpa);
    defer b.deinit(gpa);
    const InternPool = @import("intern_pool");
    const p0 = try b.addInst(gpa, .{ .tag = .probe, .data = .{ .ty_index = .{ .ty = .real_type, .index = 0 } } });
    const p1 = try b.addInst(gpa, .{ .tag = .probe, .data = .{ .ty_index = .{ .ty = .real_type, .index = 1 } } });
    const s = try b.addInst(gpa, .{ .tag = .alloc, .data = .{ .ty = .real_type } });
    const a0 = try b.addBinOp(gpa, .assign, .fromIndex(s), .fromIndex(p0));
    const a1 = try b.addBinOp(gpa, .assign, .fromIndex(s), .fromIndex(p1));
    const ld = try b.addUnOp(gpa, .load, .fromIndex(s));
    const mul = try b.addBinOp(gpa, .fmul, .fromIndex(ld), .fromIntern(InternPool.Index.two_real));
    const ret = try b.addUnOp(gpa, .ret, .fromIndex(mul));
    var air = try b.finish(gpa, &.{ p0, p1, s, a0, a1, ld, mul, ret });
    defer air.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const l = try init(arena.allocator(), air, 2, null);
    try std.testing.expectEqual(@as(Mask, 0b11), l.masks[@backingInt(ld)]);
    try std.testing.expectEqual(@as(Mask, 0b11), l.masks[@backingInt(mul)]);
    try std.testing.expect(l.assigned[@backingInt(s)]);
    try std.testing.expect(l.used[@backingInt(mul)]);
    try std.testing.expect(!l.used[@backingInt(ret)]);
    try std.testing.expectEqual(@as(Mask, 0), l.maskOf(.fromIntern(InternPool.Index.two_real)));
    try std.testing.expectError(error.TooManyUnknowns, init(arena.allocator(), air, 65, null));
}
