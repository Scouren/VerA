//! The setup tier: an `Air` and its callees' facts in; which values are the
//! same at every Newton iterate and time point of one card (solve
//! invariance), where setup may compute them, the first value of a
//! `vera_timepoint` statement that moves between the iterations of one
//! timepoint (E0531), and which held slots no evaluation can observe, out.
//!
//! One optimistic fixpoint over the nesting: every value starts fixed and
//! only falls. A §4.4 probe varies; a parameter or constant does not; a call
//! varies unless the caller's facts allow it over fixed arguments; a pure
//! value varies with an operand; a `load` with any `assign` to its slot that
//! writes a varying value or runs under varying control; a `block` with a
//! varying `br` operand or a `br` taken under varying control. Control
//! varies inside an arm of a varying condition, after a block some varying
//! decision may leave early, and inside a `loop` some varying decision
//! repeats or leaves (its iteration count moves). Per solve, a value under
//! varying control is fixed only outside every loop and when it cannot fault
//! (setup computes it unconditionally); per timepoint the data alone decides,
//! since every branch inside the statement is checked itself.
//!
//! A held slot (§3.2: it starts each evaluation with the last one's value)
//! is unobservable when no read can run before a write in one evaluation
//! and every write runs under card-fixed control: a card then writes it
//! before every read, or never, so it always holds its initializer.
//! Cites: VAMS-2023 §2.9, §3.2, §4.4, §5.6.1.2, §5.10.2, §9.15.
//!
//! Contents:
//! - `pub const Mode = enum { solve, timepoint }`
//! - `pub const Result = struct` (`invariant`, `placeable`, `deinit`)
//! - `pub fn invariance(gpa: Allocator, air: Air, ip: *const InternPool, calls: []const Air.CallFacts) Allocator.Error!Result`
//! - `pub fn timepoint(gpa: Allocator, air: Air, ip: *const InternPool, calls: []const Air.CallFacts, region: Air.Inst.Index) Allocator.Error!?Air.Inst.Index`
//! - `pub fn pruneHeld(gpa: Allocator, air: Air, ip: *const InternPool, calls: []const Air.CallFacts, held: []const Air.Inst.Index) Allocator.Error![]bool`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const InternPool = @import("intern_pool");
const Air = @import("../Air.zig");
const Inst = Air.Inst;

/// What "fixed" means: across the solves of one card, or across the Newton
/// iterations of one timepoint.
pub const Mode = enum { solve, timepoint };

/// Per instruction, one bit each; the caller frees with `deinit`.
pub const Result = struct {
    /// A value that is the same at every solve of one card.
    invariant: std.DynamicBitSetUnmanaged,
    /// Its control is the card's alone and no varying loop ran before it:
    /// setup may compute it where it stands.
    placeable: std.DynamicBitSetUnmanaged,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        r.invariant.deinit(gpa);
        r.placeable.deinit(gpa);
        r.* = undefined;
    }
};

/// A `block` or `loop` around the walk: whether a decision the entry did not
/// already have varying reached its exit (`varied`), left it early
/// (`escaped`), or carried a varying value out (`data`).
const Frame = struct { inst: Inst.Index, entry: bool, varied: bool = false, escaped: bool = false, data: bool = false };

/// One fixpoint's tables; every slice per instruction, in `arena`.
const Scan = struct {
    arena: Allocator,
    air: Air,
    ip: *const InternPool,
    calls: []const Air.CallFacts,
    mode: Mode,
    tags: []const Inst.Tag,
    datas: []const Inst.Data,
    /// The value varies; for an `alloc`, some write to its slot does; for a
    /// `loop`, its iteration count does.
    vary: []bool,
    /// Control varied at the instruction, in the last round.
    ctl: []bool,
    placeable: []bool,
    frames: std.ArrayList(Frame) = .empty,
    loops: u32 = 0,
    /// A varying loop ran before the walk's point.
    past: bool = false,
    changed: bool = false,

    fn init(arena: Allocator, air: Air, ip: *const InternPool, calls: []const Air.CallFacts, mode: Mode) Allocator.Error!Scan {
        const n = air.instructions.len;
        const s: Scan = .{
            .arena = arena,
            .air = air,
            .ip = ip,
            .calls = calls,
            .mode = mode,
            .tags = air.instructions.items(.tag),
            .datas = air.instructions.items(.data),
            .vary = try arena.alloc(bool, n),
            .ctl = try arena.alloc(bool, n),
            .placeable = try arena.alloc(bool, n),
        };
        @memset(s.vary, false);
        @memset(s.ctl, false);
        @memset(s.placeable, false);
        return s;
    }

    /// Rounds until no flag rises: each round but the last raises one.
    fn solve(s: *Scan) Allocator.Error!void {
        var rounds: usize = 0;
        while (true) : (rounds += 1) {
            assert(rounds <= s.vary.len + 1);
            s.changed = false;
            s.past = false;
            try s.walk(s.air.mainBody(), false, 0);
            assert(s.frames.items.len == 0);
            if (!s.changed) break;
        }
    }

    fn walk(s: *Scan, insts: []const Inst.Index, ctl_in: bool, depth: u32) Allocator.Error!void {
        assert(depth <= Air.nesting_max);
        var ctl = ctl_in;
        for (insts) |inst| {
            const i = @backingInt(inst);
            const data = s.datas[i];
            s.ctl[i] = ctl;
            s.placeable[i] = !ctl and !s.past;
            switch (s.tags[i]) {
                .block => {
                    const x = s.air.extraData(Air.Block, data.ty_pl.payload);
                    try s.frames.append(s.arena, .{ .inst = inst, .entry = ctl });
                    try s.walk(s.air.body(x.end, x.data.body_len), ctl, depth + 1);
                    const f = s.frames.pop().?;
                    if (f.varied or f.data or s.underControl(.block, ctl)) s.raise(i);
                    ctl = ctl or f.escaped;
                },
                .loop => {
                    const x = s.air.extraData(Air.Block, data.ty_pl.payload);
                    try s.frames.append(s.arena, .{ .inst = inst, .entry = ctl });
                    s.loops += 1;
                    try s.walk(s.air.body(x.end, x.data.body_len), ctl or s.vary[i], depth + 1);
                    s.loops -= 1;
                    const f = s.frames.pop().?;
                    if (f.varied or f.escaped) s.raise(i);
                    if (s.vary[i]) s.past = true;
                    return;
                },
                .cond_br => {
                    const x = s.air.extraData(Air.CondBr, data.pl_op.payload);
                    const c = ctl or s.varies(data.pl_op.operand);
                    try s.walk(s.air.body(x.end, x.data.then_body_len), c, depth + 1);
                    try s.walk(s.air.body(x.end + x.data.then_body_len, x.data.else_body_len), c, depth + 1);
                    return;
                },
                .br => return s.exit(data.br.block_inst, ctl, data.br.operand),
                .repeat => return s.exit(data.repeat.loop_inst, ctl, .none),
                .ret => {
                    for (s.frames.items) |*f| f.escaped = f.escaped or (ctl and !f.entry);
                    return;
                },
                .alloc => {},
                .assign => if (ctl or s.varies(data.bin_op.rhs)) s.raise(@backingInt(data.bin_op.lhs.toIndex().?)),
                else => |tag| if (s.rule(tag, data) or s.underControl(tag, ctl)) s.raise(i), // else: the value tags
            }
        }
        unreachable; // a well-formed body ends in a noreturn tag
    }

    /// Records an exit to `target` under `ctl`: the frames it leaves early,
    /// and the target's own decision and carried value.
    fn exit(s: *Scan, target: Inst.Index, ctl: bool, operand: Inst.Ref) void {
        var k = s.frames.items.len;
        while (k > 0) {
            k -= 1;
            const f = &s.frames.items[k];
            const new = ctl and !f.entry;
            if (f.inst != target) {
                f.escaped = f.escaped or new;
                continue;
            }
            f.varied = f.varied or new;
            if (operand != .none and s.varies(operand)) f.data = true;
            return;
        }
        unreachable; // Verify: a `br` or `repeat` names an enclosing frame
    }

    /// Whether a value computed under varying control `ctl` varies per
    /// solve: inside a loop its sequence does; outside, a value setup cannot
    /// compute unconditionally (it may fault, or reads state) does.
    fn underControl(s: *const Scan, tag: Inst.Tag, ctl: bool) bool {
        if (!ctl or s.mode == .timepoint) return false;
        return s.loops > 0 or !speculable(tag);
    }

    /// The data rule: whether value `tag` varies with its inputs.
    fn rule(s: *const Scan, tag: Inst.Tag, data: Inst.Data) bool {
        return switch (tag) {
            .arg, .anew => false,
            .probe => true,
            .load => s.vary[@backingInt(data.un_op.toIndex().?)],
            // §5.6.1.2: the latches move with every accepted solve.
            .path_prev, .path_acc => s.mode == .solve or s.varies(data.un_op),
            .call => blk: {
                const x = s.air.extraData(Air.Call, data.ty_pl.payload);
                const facts: Air.CallFacts = if (x.data.callee < s.calls.len) s.calls[x.data.callee] else .{};
                const fixed = facts.invariant or (s.mode == .timepoint and facts.timepoint);
                if (!fixed) break :blk true;
                for (s.air.extra[x.end..][0..x.data.args_len]) |a| if (s.varies(@fromBackingInt(a))) break :blk true;
                break :blk false;
            },
            .select, .store => blk: {
                const bin = s.air.extraData(Air.Bin, data.pl_op.payload).data;
                break :blk s.varies(data.pl_op.operand) or s.varies(bin.lhs) or s.varies(bin.rhs);
            },
            else => switch (Air.tag_info.getPtrConst(tag).class) { // else: the rest by class
                .un_op => s.varies(data.un_op),
                .bin_op => s.varies(data.bin_op.lhs) or s.varies(data.bin_op.rhs),
                .pl_op, .ty_pl, .ty, .ty_index, .br, .repeat => true,
            },
        };
    }

    fn varies(s: *const Scan, ref: Inst.Ref) bool {
        const i = ref.toIndex() orelse return false;
        return s.vary[@backingInt(i)];
    }

    fn raise(s: *Scan, i: u32) void {
        if (s.vary[i]) return;
        s.vary[i] = true;
        s.changed = true;
    }
};

/// Returns the solve-invariant values and the placeable instructions.
/// Scratch lives in an arena on `gpa`; the bit sets are the caller's.
/// Asserts that `air` is well formed.
pub fn invariance(gpa: Allocator, air: Air, ip: *const InternPool, calls: []const Air.CallFacts) Allocator.Error!Result {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var s = try Scan.init(arena.allocator(), air, ip, calls, .solve);
    try s.solve();
    const n = air.instructions.len;
    var r: Result = .{ .invariant = try .initEmpty(gpa, n), .placeable = undefined };
    errdefer r.invariant.deinit(gpa);
    r.placeable = try .initEmpty(gpa, n);
    for (0..n) |i| {
        const tag = s.tags[i];
        const value = tag != .alloc and tag != .assign and air.typeOfIndex(ip, @fromBackingInt(@intCast(i))) != .none;
        if (value and !s.vary[i]) r.invariant.set(i);
        if (s.placeable[i]) r.placeable.set(i);
    }
    if (n != 0) assert(r.invariant.count() <= n);
    return r;
}

/// E0531: returns the first condition inside `region` (a `block`, the
/// `vera_timepoint` statement) that moves between the Newton iterations of
/// one timepoint, else the first such value defined inside it, else null.
/// Asserts that `region` is a `block`.
pub fn timepoint(gpa: Allocator, air: Air, ip: *const InternPool, calls: []const Air.CallFacts, region: Inst.Index) Allocator.Error!?Inst.Index {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var s = try Scan.init(arena.allocator(), air, ip, calls, .timepoint);
    try s.solve();
    assert(s.tags[@backingInt(region)] == .block);
    const x = air.extraData(Air.Block, s.datas[@backingInt(region)].ty_pl.payload);
    const insts = air.body(x.end, x.data.body_len);
    if (firstIn(&s, insts, true, 0)) |c| return c;
    return firstIn(&s, insts, false, 0);
}

/// Returns, per `held` slot (an `alloc` whose slot starts each evaluation
/// with the previous one's final value), whether an evaluation can observe
/// that value: a read that may run before a write in one evaluation, or a
/// write under control the card does not fix. The mask is the caller's
/// (`gpa`). Asserts that each `held` row is an `alloc`.
pub fn pruneHeld(gpa: Allocator, air: Air, ip: *const InternPool, calls: []const Air.CallFacts, held: []const Inst.Index) Allocator.Error![]bool {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = try Scan.init(arena, air, ip, calls, .solve);
    try s.solve();
    const n = air.instructions.len;
    // Walk order and the enclosing loop of each instruction.
    const pos = try arena.alloc(u32, n);
    const loop_of = try arena.alloc(u32, n);
    @memset(pos, std.math.maxInt(u32));
    var next: u32 = 0;
    try number(air, air.mainBody(), std.math.maxInt(u32), pos, loop_of, &next, 0);
    const keep = try gpa.alloc(bool, held.len);
    for (held, keep) |h, *k| {
        assert(s.tags[@backingInt(h)] == .alloc);
        const slot = Inst.Ref.fromIndex(h);
        k.* = false;
        for (0..n) |a| {
            if (s.tags[a] != .assign or s.datas[a].bin_op.lhs != slot or pos[a] == std.math.maxInt(u32)) continue;
            if (s.ctl[a]) k.* = true;
            for (0..n) |l| {
                if (s.tags[l] != .load or s.datas[l].un_op != slot or pos[l] == std.math.maxInt(u32)) continue;
                if (pos[l] < pos[a] or sharesLoop(loop_of, @intCast(l), @intCast(a))) k.* = true;
            }
        }
    }
    return keep;
}

// ---- private ----

/// The first varying condition (`conds`) or value inside `insts`, in walk order.
fn firstIn(s: *const Scan, insts: []const Inst.Index, conds: bool, depth: u32) ?Inst.Index {
    assert(depth <= Air.nesting_max);
    for (insts) |inst| {
        const i = @backingInt(inst);
        const data = s.datas[i];
        switch (s.tags[i]) {
            .block, .loop => {
                const x = s.air.extraData(Air.Block, data.ty_pl.payload);
                if (firstIn(s, s.air.body(x.end, x.data.body_len), conds, depth + 1)) |f| return f;
            },
            .cond_br => {
                if (conds and s.varies(data.pl_op.operand)) return data.pl_op.operand.toIndex().?;
                const x = s.air.extraData(Air.CondBr, data.pl_op.payload);
                if (firstIn(s, s.air.body(x.end, x.data.then_body_len + x.data.else_body_len), conds, depth + 1)) |f| return f;
            },
            .alloc, .assign, .br, .repeat, .ret => {},
            else => if (!conds and s.vary[i]) return inst, // else: the value tags
        }
    }
    return null;
}

fn number(air: Air, insts: []const Inst.Index, loop: u32, pos: []u32, loop_of: []u32, next: *u32, depth: u32) Allocator.Error!void {
    assert(depth <= Air.nesting_max);
    for (insts) |inst| {
        const i = @backingInt(inst);
        pos[i] = next.*;
        next.* += 1;
        loop_of[i] = loop;
        const data = air.instructions.items(.data)[i];
        switch (air.instructions.items(.tag)[i]) {
            .block, .loop => |t| {
                const x = air.extraData(Air.Block, data.ty_pl.payload);
                try number(air, air.body(x.end, x.data.body_len), if (t == .loop) i else loop, pos, loop_of, next, depth + 1);
            },
            .cond_br => {
                const x = air.extraData(Air.CondBr, data.pl_op.payload);
                try number(air, air.body(x.end, x.data.then_body_len + x.data.else_body_len), loop, pos, loop_of, next, depth + 1);
            },
            else => {}, // else: no other tag has a body
        }
    }
}

/// Whether some loop encloses both `a` and `b`: a read in one iteration
/// then reaches a write in the next.
fn sharesLoop(loop_of: []const u32, a: u32, b: u32) bool {
    var la = loop_of[a];
    while (la != std.math.maxInt(u32)) : (la = loop_of[la]) {
        var lb = loop_of[b];
        while (lb != std.math.maxInt(u32)) : (lb = loop_of[lb]) if (la == lb) return true;
    }
    return false;
}

/// A value setup may compute where its source would not run: a real
/// operation that cannot fault (a real outside its domain is NaN or inf,
/// and these have unchecked spellings) or a comparison. No integer
/// arithmetic (a zero divisor traps), no `%`, none of the four functions
/// every spelling of which reports a domain error, no state.
fn speculable(tag: Inst.Tag) bool {
    const info = Air.tag_info.getPtrConst(tag);
    if (info.class != .un_op and info.class != .bin_op) return false;
    if (info.operand == null) return false;
    if (info.int and !info.bool01) return false;
    return switch (info.domain) {
        .all, .positive, .gt_neg_one, .non_negative, .pow_sign, .tan_poles => tag != .path_prev and tag != .path_acc,
        .unit_closed, .unit_open, .ge_one, .nonzero_divisor => false,
    };
}
