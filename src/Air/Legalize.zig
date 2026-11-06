//! If-conversion (Zig's `Air/Legalize.zig` shape: Air rewritten for a
//! backend): an `Air` in, the same program with every convertible
//! `block { ...; cond_br(c, {...; br}, {...; br}) }` straight-line out. Both
//! arms' instructions move into the block, the block's result becomes a
//! §4.2.12 `select` on `c`, and each slot an arm writes takes one
//! `assign(s, select(c, then, else))` after them, an arm that does not
//! write it reading the slot as it was. One post-order recursion: an inner
//! conversion leaves a straight-line block an outer arm may move whole; no
//! fixpoint, no worklist. The moved branch, `br`s and `assign`s stay behind
//! as rows no body holds.
//!
//! An arm converts when every instruction is a value with no side effect,
//! so §4.2.3's "side effects shall not occur" holds by construction: no
//! `call`, `opt_barrier`, `store`, `anew`, `alloc` or nested control, no
//! operation that has no value at some operands (an integer or real `%` or
//! `/` by zero, `**`, a shift), each slot written once, none read after its
//! write. `.pure` (before the proof) also refuses a §4.3.2 domain-restricted
//! operation: as an arm it is guarded by the branch, which `Float` reads.
//! `.speculate` (after a proof that rated every root `.strict`, where a
//! discarded arm's NaN is IEEE-defined) moves it and returns a `Guard` row,
//! so codegen reports it only where the source ran it; it keeps a branch on
//! a condition the card alone decides (every evaluation takes one arm).
//! Either keeps a branch on the first-evaluation flag (codegen's setup split
//! reads it) and one whose block or slot `Options.keep` names.
//! Cites: VAMS-2023 §2.9, §3.2.2, §4.2.3, §4.2.4, §4.2.8, §4.2.12, §4.3.2,
//! §5.2.1, §5.10.2.
//!
//! Contents:
//! - `pub const Mode = enum { pure, speculate }`
//! - `pub const Options = struct`
//! - `pub const Guard = struct { inst: Air.Inst.Index, cond: Air.Inst.Ref, taken: bool }`
//! - `pub const Result = struct { air: Air, guards: []Guard, converted: u32 }`, `Result.deinit(r: *Result, gpa: Allocator) void`
//! - `pub fn run(gpa: Allocator, air: Air, ip: *const InternPool, opts: Options) Allocator.Error!Result`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const InternPool = @import("intern_pool");
const Air = @import("../Air.zig");
const Inst = Air.Inst;

/// Which arms convert.
pub const Mode = enum {
    /// Before the proof: arms with no domain-restricted operation.
    pure,
    /// After a proof that rated every root `.strict`: domain-restricted
    /// operations too, each guarded, on a condition that varies with the solve.
    speculate,
};

/// What `run` reads beside the `Air`.
pub const Options = struct {
    mode: Mode = .pure,
    /// Indexed by `Air.Call.callee`: the first-evaluation flag.
    calls: []const Air.CallFacts = &.{},
    /// Per instruction: a `block` or `alloc` whose merge must stay a branch
    /// (an `.optimized` root's slice, where a speculated NaN is poison).
    keep: ?*const std.DynamicBitSetUnmanaged = null,
};

/// A domain-restricted instruction `.speculate` moved out of an arm: it may
/// report and run out of its domain only where `cond` is nonzero (`taken`)
/// or zero. An instruction's rows hold together.
pub const Guard = struct { inst: Inst.Index, cond: Inst.Ref, taken: bool };

/// The converted program; the caller frees it with `deinit`.
pub const Result = struct {
    air: Air,
    guards: []Guard,
    converted: u32,

    /// Frees the `Air` and the guard rows.
    pub fn deinit(r: *Result, gpa: Allocator) void {
        r.air.deinit(gpa);
        gpa.free(r.guards);
        r.* = undefined;
    }
};

/// Most values `cardOnly` visits before it answers "not card-only".
const card_visits_max: u32 = 256;

/// One slot an arm writes, and the value.
const Write = struct { slot: Inst.Ref, value: Inst.Ref };

/// The rewrite in progress: a copy of the instruction table and `extra`,
/// with payloads appended and re-pointed.
const L = struct {
    gpa: Allocator,
    ip: *const InternPool,
    opts: Options,
    insts: std.MultiArrayList(Inst),
    extra: std.ArrayList(u32),
    guards: std.ArrayList(Guard) = .empty,
    converted: u32 = 0,

    fn tag(l: *const L, i: Inst.Index) Inst.Tag {
        return l.insts.items(.tag)[@backingInt(i)];
    }
    fn data(l: *const L, i: Inst.Index) Inst.Data {
        return l.insts.items(.data)[@backingInt(i)];
    }
    fn add(l: *L, inst: Inst) Allocator.Error!Inst.Index {
        const i: Inst.Index = @fromBackingInt(@intCast(l.insts.len));
        try l.insts.append(l.gpa, inst);
        return i;
    }
    /// A copy of the body at `extra[at..][0..len]`: `extra` may grow under it.
    fn copy(l: *L, scratch: Allocator, at: u32, len: u32) Allocator.Error![]Inst.Index {
        return scratch.dupe(Inst.Index, @ptrCast(l.extra.items[at..][0..len]));
    }

    /// Converts post-order: every body inside `insts` first, then each block here.
    fn walk(l: *L, scratch: Allocator, insts: []const Inst.Index, depth: u32) Allocator.Error!void {
        assert(depth <= Air.nesting_max);
        for (insts) |inst| switch (l.tag(inst)) {
            .block, .loop => {
                const x = extraData(l, Air.Block, l.data(inst).ty_pl.payload);
                try l.walk(scratch, try l.copy(scratch, x.end, x.data.body_len), depth + 1);
                if (l.tag(inst) == .block) try l.convert(scratch, inst);
            },
            .cond_br => {
                const x = extraData(l, Air.CondBr, l.data(inst).pl_op.payload);
                try l.walk(scratch, try l.copy(scratch, x.end, x.data.then_body_len), depth + 1);
                try l.walk(scratch, try l.copy(scratch, x.end + x.data.then_body_len, x.data.else_body_len), depth + 1);
            },
            else => {}, // else: no other tag has a body
        };
    }

    /// Converts block `b` if its body ends in a `cond_br` whose arms both
    /// leave `b` and qualify.
    fn convert(l: *L, scratch: Allocator, b: Inst.Index) Allocator.Error!void {
        const x = extraData(l, Air.Block, l.data(b).ty_pl.payload);
        const body = try l.copy(scratch, x.end, x.data.body_len);
        const cb = body[body.len - 1];
        if (l.tag(cb) != .cond_br) return;
        if (l.opts.keep) |k| if (k.isSet(@backingInt(b))) return;
        const cond = l.data(cb).pl_op.operand;
        if (l.firstPoint(cond)) return;
        if (l.opts.mode == .speculate) {
            var budget = card_visits_max;
            if (l.cardOnly(cond, &budget)) return;
        }
        const cx = extraData(l, Air.CondBr, l.data(cb).pl_op.payload);
        const arms = [2][]Inst.Index{
            try l.copy(scratch, cx.end, cx.data.then_body_len),
            try l.copy(scratch, cx.end + cx.data.then_body_len, cx.data.else_body_len),
        };
        var writes: [2]std.ArrayList(Write) = .{ .empty, .empty };
        var restricted: [2]std.ArrayList(Inst.Index) = .{ .empty, .empty };
        var results: [2]Inst.Ref = undefined;
        for (arms, &writes, &restricted, &results) |arm, *w, *r, *out| {
            const last = arm[arm.len - 1];
            if (l.tag(last) != .br or l.data(last).br.block_inst != b) return;
            out.* = l.data(last).br.operand;
            if (!try l.movable(scratch, arm[0 .. arm.len - 1], w, r, false, 0)) return;
            if (l.opts.keep) |k| for (w.items) |wr| if (k.isSet(@backingInt(wr.slot.toIndex().?))) return;
        }

        // ---- the rewrite: nothing below refuses ----
        const c = l.peel(cond);
        var out: std.ArrayList(Inst.Index) = .empty;
        try out.appendSlice(scratch, body[0 .. body.len - 1]);
        // Each arm's values; its writes are the merged ones below.
        for (arms) |arm| for (arm[0 .. arm.len - 1]) |i| if (l.tag(i) != .assign) try out.append(scratch, i);
        // Every slot either arm writes, first-written first: its value as it
        // was, read before any merged write.
        var slots: std.ArrayList(Inst.Ref) = .empty;
        for (writes) |w| for (w.items) |wr| if (std.mem.findScalar(Inst.Ref, slots.items, wr.slot) == null) try slots.append(scratch, wr.slot);
        const before = try scratch.alloc(Inst.Ref, slots.items.len);
        @memset(before, .none);
        for (slots.items, before) |s, *v| {
            const in_both = find(writes[0].items, s) != null and find(writes[1].items, s) != null;
            if (in_both) continue;
            const ld = try l.add(.{ .tag = .load, .data = .{ .un_op = s } });
            try out.append(scratch, ld);
            v.* = .fromIndex(ld);
        }
        for (slots.items, before) |s, v| {
            const t = find(writes[0].items, s) orelse v;
            const e = find(writes[1].items, s) orelse v;
            const sel = try l.select(c, t, e);
            try out.append(scratch, sel);
            try out.append(scratch, try l.add(.{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = s, .rhs = .fromIndex(sel) } } }));
        }
        var result: Inst.Ref = .none;
        if (results[0] != .none) {
            const sel = try l.select(c, results[0], results[1]);
            try out.append(scratch, sel);
            result = .fromIndex(sel);
        }
        try out.append(scratch, try l.add(.{ .tag = .br, .data = .{ .br = .{ .block_inst = b, .operand = result } } }));
        const at: u32 = @intCast(l.extra.items.len);
        try l.extra.append(l.gpa, @intCast(out.items.len));
        try l.extra.appendSlice(l.gpa, @ptrCast(out.items));
        l.insts.items(.data)[@backingInt(b)].ty_pl.payload = at;
        for (restricted, [_]bool{ true, false }) |r, taken| for (r.items) |i| try l.guards.append(l.gpa, .{ .inst = i, .cond = c, .taken = taken });
        l.converted += 1;
        assert(l.tag(out.items[out.items.len - 1]) == .br);
        assert(out.items.len >= body.len); // the prefix, then at least the br
    }

    /// Whether `insts` (an arm without its `br`) may run unconditionally,
    /// collecting its writes and its domain-restricted instructions. A
    /// straight-line block (an inner conversion) moves whole if it writes
    /// no slot.
    fn movable(l: *L, scratch: Allocator, insts: []const Inst.Index, w: *std.ArrayList(Write), r: *std.ArrayList(Inst.Index), in_block: bool, depth: u32) Allocator.Error!bool {
        assert(depth <= Air.nesting_max);
        for (insts) |inst| {
            const t = l.tag(inst);
            const d = l.data(inst);
            switch (t) {
                .assign => {
                    if (in_block or find(w.items, d.bin_op.lhs) != null) return false;
                    try w.append(scratch, .{ .slot = d.bin_op.lhs, .value = d.bin_op.rhs });
                },
                // §5.7: a read after this arm's write would see the merged value.
                .load => if (find(w.items, d.un_op) != null) return false,
                .block => {
                    const x = extraData(l, Air.Block, d.ty_pl.payload);
                    const inner = try l.copy(scratch, x.end, x.data.body_len);
                    const end = inner[inner.len - 1];
                    if (l.tag(end) != .br or l.data(end).br.block_inst != inst) return false;
                    if (!try l.movable(scratch, inner[0 .. inner.len - 1], w, r, true, depth + 1)) return false;
                },
                // Side effects, state, nested control (§4.2.3).
                .alloc, .loop, .cond_br, .br, .repeat, .ret, .call, .opt_barrier, .anew, .store, .path_prev, .path_acc => return false,
                // No value at some operands: the arm's guard is what avoids them.
                .fmod, .idiv, .imod, .ipow, .shl, .shr => return false,
                else => if (Air.tag_info.getPtrConst(t).domain != .all) { // else: the pure value tags
                    if (l.opts.mode == .pure) return false;
                    try r.append(scratch, inst);
                },
            }
        }
        return true;
    }

    fn select(l: *L, c: Inst.Ref, a: Inst.Ref, b: Inst.Ref) Allocator.Error!Inst.Index {
        const at: u32 = @intCast(l.extra.items.len);
        try l.extra.appendSlice(l.gpa, &.{ @backingInt(a), @backingInt(b) });
        return l.add(.{ .tag = .select, .data = .{ .pl_op = .{ .operand = c, .payload = at } } });
    }

    /// §5.2.1/§5.10.2: the first-evaluation flag keeps its branch.
    fn firstPoint(l: *const L, cond: Inst.Ref) bool {
        const i = cond.toIndex() orelse return false;
        if (l.tag(i) != .call) return false;
        const callee = extraData(l, Air.Call, l.data(i).ty_pl.payload).data.callee;
        return callee < l.opts.calls.len and l.opts.calls[callee].first_point;
    }

    /// Whether `ref` is computed from constants and parameters alone, so
    /// every evaluation of one card takes the same arm. Past `budget`
    /// visits it answers false, which only costs a conversion.
    fn cardOnly(l: *const L, ref: Inst.Ref, budget: *u32) bool {
        const i = ref.toIndex() orelse return true;
        if (budget.* == 0) return false;
        budget.* -= 1;
        const t = l.tag(i);
        const d = l.data(i);
        return switch (t) {
            .arg => true,
            .probe, .load, .call, .block, .anew, .store, .fload, .iload, .path_prev, .path_acc => false,
            .select => blk: {
                const bin = extraData(l, Air.Bin, d.pl_op.payload).data;
                break :blk l.cardOnly(d.pl_op.operand, budget) and l.cardOnly(bin.lhs, budget) and l.cardOnly(bin.rhs, budget);
            },
            else => switch (Air.tag_info.getPtrConst(t).class) { // else: the rest by class
                .un_op => l.cardOnly(d.un_op, budget),
                .bin_op => l.cardOnly(d.bin_op.lhs, budget) and l.cardOnly(d.bin_op.rhs, budget),
                .pl_op, .ty_pl, .ty, .ty_index, .br, .repeat => false,
            },
        };
    }

    /// Strips `p != 0` around a predicate `p`: a select's condition already
    /// means "nonzero", and `Float` mines a bare `x != 0` for the §4.2.4
    /// hole only when `x` is no predicate, so only those peel.
    fn peel(l: *const L, cond: Inst.Ref) Inst.Ref {
        var c = cond;
        for (0..l.insts.len) |_| {
            const i = c.toIndex() orelse return c;
            if (l.tag(i) != .ine or l.data(i).bin_op.rhs != Inst.Ref.fromIntern(.zero)) return c;
            const p = l.data(i).bin_op.lhs.toIndex() orelse return c;
            if (!Air.tag_info.getPtrConst(l.tag(p)).predicate) return c;
            c = l.data(i).bin_op.lhs;
        }
        unreachable; // each peel moves to an operand defined earlier
    }
};

/// Converts every qualifying block of `air` under `opts.mode` and returns
/// the new program, its guard rows and how many converted; `air` is left
/// as it was. Asserts that `air` is well formed; the result is too
/// (`Air.Verify.check` in a safety build).
pub fn run(gpa: Allocator, air: Air, ip: *const InternPool, opts: Options) Allocator.Error!Result {
    var scratch_state: std.heap.ArenaAllocator = .init(gpa);
    defer scratch_state.deinit();
    var l: L = .{
        .gpa = gpa,
        .ip = ip,
        .opts = opts,
        .insts = try air.instructions.toMultiArrayList().clone(gpa),
        .extra = .fromOwnedSlice(try gpa.dupe(u32, air.extra)),
    };
    errdefer l.insts.deinit(gpa);
    errdefer l.extra.deinit(gpa);
    errdefer l.guards.deinit(gpa);
    try l.walk(scratch_state.allocator(), air.mainBody(), 0);
    const guards = try l.guards.toOwnedSlice(gpa);
    errdefer gpa.free(guards);
    const extra = try l.extra.toOwnedSlice(gpa);
    const out: Air = .{ .instructions = l.insts.toOwnedSlice(), .extra = extra };
    try Air.Verify.check(gpa, out, ip);
    assert(out.instructions.len >= air.instructions.len);
    assert(out.mainBody().len == air.mainBody().len); // only nested payloads move
    return .{ .air = out, .guards = guards, .converted = l.converted };
}

// ---- private ----

fn extraData(l: *const L, comptime T: type, at: u32) struct { data: T, end: u32 } {
    const air: Air = .{ .instructions = undefined, .extra = l.extra.items };
    const x = air.extraData(T, at);
    return .{ .data = x.data, .end = x.end };
}

fn find(writes: []const Write, slot: Inst.Ref) ?Inst.Ref {
    for (writes) |w| if (w.slot == slot) return w.value;
    return null;
}
