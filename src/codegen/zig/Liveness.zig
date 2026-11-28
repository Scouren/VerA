//! What the Zig backend knows of an `Air` body before it writes a line
//! (Zig's `Air/Liveness.zig` for this backend): per instruction the solver
//! unknowns its value may depend on (`masks`: the derivative lanes the
//! emitted family value carries, `zOf(S, mask)`), whether anything reads it
//! (`used`: a pure value nothing reads is not emitted, since Zig refuses an
//! unused local), and per `alloc` whether anything writes it (`assigned`: a
//! slot nothing writes is a `const`). Slots and `block` results join every
//! value written to them, flow-insensitively, to a fixed point; the slots
//! of one §3.2.2 array share one mask (`Function` types them as one array).
//! Cites: VAMS-2023 §4.4 (probes), §5.7 (assignments), §4.5.14 (`ddx`).
//!
//! The data, by `data-oriented-design`'s six questions:
//! 1. In: one `Air`. Out: three columns over its instructions.
//! 2. One per device; tens to tens of thousands of rows.
//! 3. Row `i` is `Air.Inst.Index` `i`; a mask is one bit per unknown, at
//!    most `unknowns_max` of them, in `mw = max(1, ceil(n_u / 64))` u64
//!    words: one flat column, row `i` at `words[i * mw ..][0..mw]`.
//! 4. Read by row while `Function` renders an instruction.
//! 5. Lives for one `generate`.
//! 6. Written once by `init`, read only after.
//!
//! Contents:
//! - fields `mw`, `words`, `used`, `assigned`, `targeted`
//! - `pub const Mask = struct` (`eql`, `isZero`, `format`), `pub const unknowns_max: u32`
//! - `pub fn wordsOf(n_u: u32) u32`
//! - `pub fn init(arena: Allocator, air: Air, n_u: u32, roots: ?[]const bool, arrays: []const Air.Device.Array) Allocator.Error!Liveness`
//! - `pub fn mask(l: Liveness, i: u32) Mask`
//! - `pub fn maskOf(l: Liveness, ref: Air.Inst.Ref) Mask`
//! - `pub fn effect(air: Air, tag: Air.Inst.Tag, data: Air.Inst.Data) bool`
//! - `pub const Operands = struct` (`collect`, `slice`)

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Air = @import("air");
const Inst = Air.Inst;
const SysFn = @import("vams").SysFn;

/// The unknowns a value may depend on, a view of `mw` words: bit `u` is
/// unknown `u`, in word `u / 64`. Its `{f}` text is the Zig literal of
/// `contract.MaskOf(n_u)` without the `0x`.
pub const Mask = struct {
    words: []const u64,

    /// Whether `a` and `b` name the same unknowns. Asserts equal widths.
    pub fn eql(a: Mask, b: Mask) bool {
        assert(a.words.len == b.words.len);
        return std.mem.eql(u64, a.words, b.words);
    }

    /// Whether no unknown is named.
    pub fn isZero(m: Mask) bool {
        assert(m.words.len != 0);
        return std.mem.allEqual(u64, m.words, 0);
    }

    /// The hex digits of one literal: the highest nonzero word unpadded,
    /// each word below it 16 digits, so a one-word mask writes as its
    /// `u64` did and a zero mask as `0`.
    pub fn format(m: Mask, w: *std.Io.Writer) std.Io.Writer.Error!void {
        assert(m.words.len != 0);
        var top = m.words.len - 1;
        while (top > 0 and m.words[top] == 0) top -= 1;
        try w.print("{x}", .{m.words[top]});
        for (0..top) |k| try w.print("{x:0>16}", .{m.words[top - 1 - k]});
    }
};

/// Most unknowns a device may have: `contract.MaskOf(n_u)` is one
/// `u<n_u>`, and Zig's widest integer is `u65535` (`std_kernels.Family`
/// takes `n_u` as a `u16`).
pub const unknowns_max: u32 = std.math.maxInt(u16);

/// The words of a mask over `n_u` unknowns: `max(1, ceil(n_u / 64))`.
pub fn wordsOf(n_u: u32) u32 {
    assert(n_u <= unknowns_max);
    const mw = @max(1, std.math.divCeil(u32, n_u, 64) catch unreachable);
    assert(mw * 64 >= n_u);
    return mw;
}

/// Words per mask (`wordsOf(n_u)`); 1 up to 64 unknowns.
mw: u32,
/// Per instruction `mw` words, row `i` at `words[i * mw ..][0..mw]`: the
/// unknowns its value (an `alloc`'s: every value assigned to it; a
/// `block`'s: every `br` operand) may depend on.
words: []u64,
/// `mw` zero words: a constant's mask.
zero: []const u64,
/// `mw` words of scratch for `propagate` and `joinArrays`.
acc: []u64,
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

    /// Fills the operands of instruction (`tag`, `data`). `skip_noise_args`
    /// drops a §4.6 noise call's args (B1): every body but `noise.zig`'s
    /// renders that call as a constant, so its args would be unread locals.
    /// `markUsed` skips them unless the call is a root (only `noise.plan`
    /// roots the calls); `Function.hoistArgs`/`genTree` pass `false`, since
    /// a derived parameter default never calls one.
    pub fn collect(o: *Operands, air: Air, tag: Inst.Tag, data: Inst.Data, skip_noise_args: bool) void {
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
                // B1: outside `noise.zig`'s own body a §4.6 noise call's
                // args never render (`calls.zig` renders a constant);
                // marking them used would leave their local unread.
                if (skip_noise_args and x.data.callee <= max_sysfn_tag and !readsArgs(@fromBackingInt(@as(@typeInfo(SysFn.Tag).@"enum".tag_type, @intCast(x.data.callee))))) return;
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

const max_sysfn_tag = std.math.maxInt(@typeInfo(SysFn.Tag).@"enum".tag_type);

/// B1: whether a call of `tag` reads its own arguments in a body that does
/// not root it (`core`, `say`).
/// False for the §4.6.4 noise family: `calls.zig` renders their value as a
/// constant there, never their arguments, so marking them used would leave
/// the rendered local unread (an "unused local constant" build failure).
/// `ac_stim` does read its own `mag`/`phase` (§4.6.3's eval arm), and
/// `noise.zig`'s own second body roots every call and reads every one of
/// them, to price `noisePsd`/`acStim`.
pub fn readsArgs(tag: SysFn.Tag) bool {
    return switch (tag) {
        .white_noise, .flicker_noise, .noise_table, .noise_table_log => false,
        // §9.5 a descriptor call renders its type's zero (`calls.zig`'s
        // `fileZero`), never its operands.
        else => switch (SysFn.get(tag).family) {
            .file_out, .file_func => false,
            else => true, // else: every other call, `ac_stim` included
        },
    };
}

const Liveness = @This();

/// Computes the three columns of `air`, whose probes read `n_u` unknowns,
/// into `arena`; `roots`, per instruction, adds effects (the display tasks
/// `say` records); each of `arrays` gets the join of its slots' masks.
/// Asserts `n_u <= unknowns_max` (the caller refuses past it) and that
/// every probe reads an unknown below `n_u`.
pub fn init(arena: Allocator, air: Air, n_u: u32, roots: ?[]const bool, arrays: []const Air.Device.Array) Allocator.Error!Liveness {
    assert(n_u <= unknowns_max);
    const n = air.instructions.len;
    const mw = wordsOf(n_u);
    const zero = try arena.alloc(u64, mw);
    @memset(zero, 0);
    const l: Liveness = .{
        .mw = mw,
        .words = try arena.alloc(u64, n * mw),
        .zero = zero,
        .acc = try arena.alloc(u64, mw),
        .used = try arena.alloc(bool, n),
        .assigned = try arena.alloc(bool, n),
        .targeted = try arena.alloc(bool, n),
    };
    @memset(l.words, 0);
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
    const passes_max = @as(u64, n) * n_u + 2;
    var pass: u64 = 0;
    while (l.propagate(air, n_u) or l.joinArrays(arrays)) : (pass += 1) assert(pass < passes_max);
    assert(l.words.len == n * mw);
    return l;
}

/// The unknowns instruction `i`'s value may depend on.
pub fn mask(l: Liveness, i: u32) Mask {
    assert(i < l.used.len);
    return .{ .words = l.words[i * l.mw ..][0..l.mw] };
}

/// The unknowns operand `ref` may depend on; none for a constant.
pub fn maskOf(l: Liveness, ref: Inst.Ref) Mask {
    assert(ref != .none);
    const i = ref.toIndex() orelse return .{ .words = l.zero };
    return l.mask(@backingInt(i));
}

/// Whether an instruction runs for what it does, not for its value: control,
/// an assignment, a call that changes what a later evaluation sees (a §9.13
/// draw, a §4.5 operator `ops.zig` keeps, a §9.7.3
/// `$fatal`/`$error` `status.zig` latches `core`-side, whose input
/// `updateState`/`eval`/`q` read from `core` even where only a print reads
/// its value). A §9.4 print or the rest of §9.7's tasks run in the
/// device's display phase, so they do not run in `core` for their own sake;
/// nor does a §9.5 file call, which a recording device never performs (its
/// value is its type's zero, `calls.zig`'s `fileZero`).
pub fn effect(air: Air, tag: Inst.Tag, data: Inst.Data) bool {
    return switch (tag) {
        .block, .loop, .cond_br, .br, .repeat, .ret, .assign => true,
        .call => {
            const callee = air.extraData(Air.Call, data.ty_pl.payload).data.callee;
            // A user system task (§12, no `SysFn` row) runs in the display phase too.
            if (callee > std.math.maxInt(@typeInfo(SysFn.Tag).@"enum".tag_type)) return false;
            const fn_tag: SysFn.Tag = @fromBackingInt(@intCast(callee));
            if (fn_tag == .transition or fn_tag == .slew or fn_tag == .idtmod or fn_tag == .last_crossing or fn_tag == .absdelay) return true;
            // §5.10.3 an event records its input for `updateState` (`ops/events.zig`).
            if (fn_tag == .cross or fn_tag == .above or fn_tag == .timer) return true;
            if (fn_tag == .@"$fatal" or fn_tag == .@"$error") return true;
            return switch (SysFn.get(fn_tag).family) {
                .random => true,
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
        ops.collect(air, tags[i], datas[i], !root);
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
/// mask grew. Probes read unknowns below `n_u`.
fn propagate(l: Liveness, air: Air, n_u: u32) bool {
    const tags = air.instructions.items(.tag);
    const datas = air.instructions.items(.data);
    var grew = false;
    for (tags, datas, 0..) |tag, data, i| {
        const acc = l.acc;
        @memset(acc, 0);
        switch (tag) {
            .probe => {
                const u = data.ty_index.index;
                assert(u < n_u);
                acc[u / 64] = @as(u64, 1) << @intCast(u % 64);
            },
            .load => l.orIn(acc, data.un_op),
            .assign => {
                grew = l.orInto(@backingInt(data.bin_op.lhs.toIndex().?), l.maskOf(data.bin_op.rhs)) or grew;
                continue;
            },
            .br => {
                if (data.br.operand != .none) grew = l.orInto(@backingInt(data.br.block_inst), l.maskOf(data.br.operand)) or grew;
                continue;
            },
            .store => {
                const bin = air.extraData(Air.Bin, data.pl_op.payload).data;
                l.orIn(acc, data.pl_op.operand);
                l.orIn(acc, bin.rhs);
            },
            .select => {
                const bin = air.extraData(Air.Bin, data.pl_op.payload).data;
                l.orIn(acc, bin.lhs);
                l.orIn(acc, bin.rhs);
            },
            .fload => l.orIn(acc, data.bin_op.lhs),
            // A real's lanes are its operands'; an integer, a derivative stop
            // and a latch carry none.
            .fadd, .fsub, .fmul, .fdiv, .fmod, .pow, .hypot, .fmin, .fmax, .atan2 => {
                l.orIn(acc, data.bin_op.lhs);
                l.orIn(acc, data.bin_op.rhs);
            },
            .fneg, .sqrt, .exp, .expm1, .ln, .ln1p, .log10, .floor, .ceil, .fabs, .sin, .cos, .tan, .asin, .acos, .atan, .sinh, .cosh, .tanh, .asinh, .acosh, .atanh, .opt_barrier => l.orIn(acc, data.un_op),
            .call => {
                const x = air.extraData(Air.Call, data.ty_pl.payload);
                for (air.extra[x.end..][0..x.data.args_len]) |w| {
                    const r: Inst.Ref = @fromBackingInt(w);
                    if (r != .none) l.orIn(acc, r);
                }
            },
            // Blocks and slots gather from their `br`s and `assign`s above.
            .block, .alloc => continue,
            // Integers, comparisons, casts to integer, `dstop`, the §5.6.1.2
            // latches, `arg`, `anew` and the control tags carry no lanes.
            else => {}, // else: every tag above the lanes come from
        }
        grew = l.orInto(@intCast(i), .{ .words = acc }) or grew;
    }
    return grew;
}

/// Every slot of each array to the join of the array's masks; returns
/// whether any mask grew.
fn joinArrays(l: Liveness, arrays: []const Air.Device.Array) bool {
    var grew = false;
    for (arrays) |a| {
        assert(a.count > 1);
        const slots = l.words[@backingInt(a.slot) * l.mw ..][0 .. a.count * l.mw];
        const m = l.acc;
        @memset(m, 0);
        for (0..a.count) |k| for (m, slots[k * l.mw ..][0..l.mw]) |*x, y| {
            x.* |= y;
        };
        for (0..a.count) |k| {
            const s = slots[k * l.mw ..][0..l.mw];
            grew = grew or !std.mem.eql(u64, s, m);
            @memcpy(s, m);
        }
        assert(std.mem.eql(u64, slots[0..l.mw], m));
        assert(std.mem.eql(u64, slots[(a.count - 1) * l.mw ..][0..l.mw], m));
    }
    return grew;
}

/// Ors operand `ref`'s mask into `acc`, `mw` words.
fn orIn(l: Liveness, acc: []u64, ref: Inst.Ref) void {
    assert(acc.len == l.mw);
    for (acc, l.maskOf(ref).words) |*x, y| x.* |= y;
}

/// Ors `m` into instruction `i`'s mask; returns whether it grew.
fn orInto(l: Liveness, i: u32, m: Mask) bool {
    assert(m.words.len == l.mw);
    const row = l.words[i * l.mw ..][0..l.mw];
    var grew = false;
    for (row, m.words) |*x, y| {
        grew = grew or y & ~x.* != 0;
        x.* |= y;
    }
    return grew;
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
    const l = try init(arena.allocator(), air, 2, null, &.{});
    try std.testing.expectEqualSlices(u64, &.{0b11}, l.mask(@backingInt(ld)).words);
    try std.testing.expectEqualSlices(u64, &.{0b11}, l.mask(@backingInt(mul)).words);
    try std.testing.expect(l.assigned[@backingInt(s)]);
    try std.testing.expect(l.used[@backingInt(mul)]);
    try std.testing.expect(!l.used[@backingInt(ret)]);
    try std.testing.expect(l.maskOf(.fromIntern(InternPool.Index.two_real)).isZero());
}

test "Liveness: past 64 unknowns a mask is one column of mw words, bits 64 and up kept" {
    // %0 = probe 1, %1 = probe 129, %2 = fadd(%0, %1), ret: three words,
    // and the literal is one hex number, the top word unpadded.
    const gpa = std.testing.allocator;
    var b = try Air.Builder.init(gpa);
    defer b.deinit(gpa);
    const p0 = try b.addInst(gpa, .{ .tag = .probe, .data = .{ .ty_index = .{ .ty = .real_type, .index = 1 } } });
    const p1 = try b.addInst(gpa, .{ .tag = .probe, .data = .{ .ty_index = .{ .ty = .real_type, .index = 129 } } });
    const add = try b.addBinOp(gpa, .fadd, .fromIndex(p0), .fromIndex(p1));
    const ret = try b.addUnOp(gpa, .ret, .fromIndex(add));
    var air = try b.finish(gpa, &.{ p0, p1, add, ret });
    defer air.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const l = try init(arena.allocator(), air, 130, null, &.{});
    try std.testing.expectEqual(@as(u32, 3), l.mw);
    try std.testing.expectEqualSlices(u64, &.{ 0b10, 0, 0b10 }, l.mask(@backingInt(add)).words);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("2" ++ "0000000000000000" ++ "0000000000000002", try std.fmt.bufPrint(&buf, "{f}", .{l.mask(@backingInt(add))}));
    try std.testing.expectEqualStrings("2", try std.fmt.bufPrint(&buf, "{f}", .{l.mask(@backingInt(p0))}));
    try std.testing.expectEqual(@as(u32, 1), wordsOf(0));
    try std.testing.expectEqual(@as(u32, 1), wordsOf(64));
    try std.testing.expectEqual(@as(u32, 2), wordsOf(65));
    try std.testing.expectEqual(@as(u32, 1024), wordsOf(unknowns_max));
}
