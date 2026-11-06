//! §5.10 held variables (the old `analog/held.zig`): one instance's analog
//! blocks in, the variables whose value one evaluation leaves for the next
//! out, decided before any statement lowers. A variable written inside an
//! `@(...)` body is held (`event`); otherwise one a path reads before any
//! write of the same evaluation (an upward-exposed read) and that the
//! blocks write somewhere is held too: `retained` when the exposed read
//! reaches a later write or an `analog initial` body writes it, else
//! `unless_invariant` (the old `prove.held.prune` may drop it after).
//! The walk is the old definite-assignment walk, conservative alike: a
//! loop or event body may not run, and after a `disable` nothing defines.
//! §3.2.2 an array is its elements: a write at constant subscripts defines
//! that element, and a read needs its element (or, at a run-time subscript
//! or of the whole array, every element) defined.
//! Cites: VAMS-2023 §3.2, §5.2.1, §5.3.2, §5.6.1.3, §5.9, §5.10, §7.3.2.
//!
//! Contents:
//! - `pub const Why = enum`
//! - `pub fn mark(s: *Sema, unit: *Unit) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Unit = Sema.Unit;

/// Why a variable is held.
pub const Why = enum(u8) { event, retained, unless_invariant };

/// The per-variable facts of the walk.
const Marks = packed struct(u8) {
    /// Assigned on every path to the current point.
    def: bool = false,
    read: bool = false,
    write: bool = false,
    /// An exposed read is pending: a later write makes it `reach`.
    pend: bool = false,
    reach: bool = false,
    initial: bool = false,
    _: u2 = 0,
};

/// The deepest statement nesting the walks follow.
const depth_max: u32 = 1 << 12;

/// The most elements an array's definite assignment is tracked for, one
/// each (the lowering's own cap, `decl.array_cells_max`).
const cells_max: u64 = 1 << 16;

/// A variable, or one element of an array variable (row-major ordinal).
const Key = struct {
    var_: Inst.Index,
    elem: u32 = whole,

    const whole = std.math.maxInt(u32);
};

/// The definite-assignment walk (the old `Exposed`).
const Walk = struct {
    s: *Sema,
    unit: *Unit,
    marks: std.AutoHashMapUnmanaged(Key, Marks) = .empty,
    /// The keys `def` set, in order, for `undo`.
    list: std.ArrayList(Key) = .empty,
    /// Each array variable's element count, 0 when it does not fold.
    cells: std.AutoHashMapUnmanaged(Inst.Index, u32) = .empty,
    pend_list: std.ArrayList(Key) = .empty,
    disabled: bool = false,
    in_initial: bool = false,

    fn marksOf(w: *Walk, k: Key) Allocator.Error!*Marks {
        const gop = try w.marks.getOrPut(w.s.arena, k);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }
    fn has(w: *const Walk, k: Key, comptime field: []const u8) bool {
        const m = w.marks.get(k) orelse return false;
        return @field(m, field);
    }
    fn def(w: *Walk, k: Key) Allocator.Error!void {
        if (w.disabled or w.has(k, "def")) return;
        (try w.marksOf(k)).def = true;
        try w.list.append(w.s.arena, k);
    }
    fn undo(w: *Walk, at: usize) void {
        assert(at <= w.list.items.len);
        for (w.list.items[at..]) |k| w.marks.getPtr(k).?.def = false;
        w.list.shrinkRetainingCapacity(at);
    }
    fn exposed(w: *Walk, v: Inst.Index) Allocator.Error!void {
        const k: Key = .{ .var_ = v };
        const m = try w.marksOf(k);
        m.read = true;
        if (m.pend) return;
        m.pend = true;
        try w.pend_list.append(w.s.arena, k);
    }
    fn write(w: *Walk, v: Inst.Index) Allocator.Error!void {
        const m = try w.marksOf(.{ .var_ = v });
        m.write = true;
        if (m.pend) m.reach = true;
        if (w.in_initial) m.initial = true;
    }

    fn body(w: *Walk, b: Vir.Body, depth: u32) Allocator.Error!void {
        if (depth > depth_max) return;
        const vir = w.unit.vir;
        var used: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
        const insts = vir.body(b);
        for (insts) |i| try operandsOf(w.s, vir, i, &used);
        for (insts) |i| {
            const tag = vir.instructions.items(.tag)[@backingInt(i)];
            if ((tag == .call or tag == .call_sys) and !used.contains(i)) {
                try w.read(i.toRef(), 0);
                continue;
            }
            try w.stmt(i, tag, depth);
        }
    }

    fn stmt(w: *Walk, i: Inst.Index, tag: Inst.Tag, depth: u32) Allocator.Error!void {
        const vir = w.unit.vir;
        switch (tag) {
            .store, .store_nb => {
                const x = decl.payloadOf(vir, Inst.Bin, i);
                try w.read(x.rhs, 0);
                try w.subscripts(x.lhs);
                if (target(vir, x.lhs)) |t| {
                    try w.write(t.var_);
                    if (t.whole) try w.def(.{ .var_ = t.var_ }) else if (try w.elemOf(x.lhs)) |k| try w.def(.{ .var_ = t.var_, .elem = k });
                }
            },
            .contrib => {
                const x = decl.payloadOf(vir, Inst.Bin, i);
                try w.read(x.lhs, 0);
                try w.read(x.rhs, 0);
            },
            .contrib_indirect => {
                const x = decl.payloadOf(vir, Inst.Triple, i);
                try w.read(x.a, 0);
                try w.read(x.b, 0);
                try w.read(x.c, 0);
            },
            .block => try w.body(decl.payloadOf(vir, Inst.Block, i).body, depth + 1),
            .condbr => {
                const x = decl.payloadOf(vir, Inst.CondBr, i);
                try w.read(x.cond, 0);
                try w.alts(&.{ x.then, x.@"else" }, depth);
            },
            .case => {
                const x = decl.payloadOf(vir, Inst.Case, i);
                try w.read(x.operand, 0);
                var arms: std.ArrayList(Vir.Body) = .empty;
                var dflt = false;
                for (vir.list(Inst.Arm, x.arms)) |arm| {
                    for (vir.list(Inst.Ref, arm.values)) |v| try w.read(v, 0);
                    try arms.append(w.s.arena, arm.body);
                    dflt = dflt or arm.flags.default;
                }
                if (!dflt) try arms.append(w.s.arena, .empty);
                try w.alts(arms.items, depth);
            },
            .loop => {
                const x = decl.payloadOf(vir, Inst.Loop, i);
                const c = vir.body(x.cond);
                if (c.len != 0) try w.read(c[c.len - 1].toRef(), 0);
                const at = w.list.items.len;
                for (0..2) |_| {
                    try w.body(x.body, depth + 1);
                    try w.body(x.step, depth + 1);
                }
                w.undo(at);
            },
            .repeat => {
                const x = decl.payloadOf(vir, Inst.Repeat, i);
                try w.read(x.count, 0);
                const at = w.list.items.len;
                for (0..2) |_| try w.body(x.body, depth + 1);
                w.undo(at);
            },
            .event_wait => {
                const x = decl.payloadOf(vir, Inst.EventWait, i);
                try w.read(x.event, 0);
                const at = w.list.items.len;
                try w.body(x.body, depth + 1);
                w.undo(at);
            },
            .disable => w.disabled = true,
            else => {}, // else: a declaration, a jump or an expression reads nothing here
        }
    }

    /// The arms of an `if` or `case`: what every arm defines is defined after.
    fn alts(w: *Walk, arms: []const Vir.Body, depth: u32) Allocator.Error!void {
        const at = w.list.items.len;
        const pat = w.pend_list.items.len;
        var pended: std.ArrayList(Key) = .empty;
        var common: ?[]const Key = null;
        for (arms) |arm| {
            try w.body(arm, depth + 1);
            try pended.appendSlice(w.s.arena, w.pend_list.items[pat..]);
            for (w.pend_list.items[pat..]) |k| w.marks.getPtr(k).?.pend = false;
            w.pend_list.shrinkRetainingCapacity(pat);
            const got = w.list.items[at..];
            if (common) |c| {
                var keep: std.ArrayList(Key) = .empty;
                for (c) |k| for (got) |g| {
                    if (std.meta.eql(g, k)) break try keep.append(w.s.arena, k);
                };
                common = keep.items;
            } else common = try w.s.arena.dupe(Key, got);
            w.undo(at);
        }
        for (common orelse &.{}) |k| try w.def(k);
        for (pended.items) |k| if (!w.has(k, "pend")) {
            (try w.marksOf(k)).pend = true;
            try w.pend_list.append(w.s.arena, k);
        };
    }

    /// An expression's variable reads.
    fn read(w: *Walk, r: Inst.Ref, depth: u32) Allocator.Error!void {
        const i = r.toIndex() orelse return;
        if (depth > depth_max) return;
        const vir = w.unit.vir;
        const tag = vir.instructions.items(.tag)[@backingInt(i)];
        // §9.5 a writer's destinations are written, not read.
        if (tag == .call_sys) if (writtenFrom(vir, i)) |first| {
            const args = vir.list(Inst.Ref, decl.payloadOf(vir, Inst.SysCall, i).args);
            for (args, 0..) |a, k| {
                const dest = k == first or (first >= 2 and k >= first);
                if (!dest) {
                    try w.read(a, depth + 1);
                    continue;
                }
                try w.subscripts(a);
                // Written but not defined, as in the old walk (whose
                // `stmtEdges` sees a task's arguments only as reads): a
                // later read is exposed, so the destination is held.
                if (target(vir, a)) |t| try w.write(t.var_);
            }
            return;
        };
        if (tag == .decl_ref) {
            const k = decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl);
            if (vir.instructions.items(.tag)[@backingInt(k)] != .variable) return;
            if (!try w.defined(k, null)) try w.exposed(k);
            return;
        }
        // An element at constant subscripts reads that element alone.
        if (tag == .elem) if (target(vir, r)) |t| {
            try w.subscripts(r);
            if (!try w.defined(t.var_, try w.elemOf(r))) try w.exposed(t.var_);
            return;
        };
        var ops: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
        try operandsOf(w.s, vir, i, &ops);
        var it = ops.keyIterator();
        while (it.next()) |o| try w.read(o.toRef(), depth + 1);
    }

    /// Whether variable `v` is defined here: all of it, or element `elem`,
    /// or (`null`, for an array) every element.
    fn defined(w: *Walk, v: Inst.Index, elem: ?u32) Allocator.Error!bool {
        if (w.has(.{ .var_ = v }, "def")) return true;
        if (elem) |k| return w.has(.{ .var_ = v, .elem = k }, "def");
        const n = try w.cellsOf(v);
        if (n == 0) return false;
        for (0..n) |k| if (!w.has(.{ .var_ = v, .elem = @intCast(k) }, "def")) return false;
        return true;
    }

    /// The row-major ordinal of the element `r` (an `elem` chain over an
    /// array variable) names, or null at a subscript that does not fold.
    fn elemOf(w: *Walk, r: Inst.Ref) Allocator.Error!?u32 {
        const vir = w.unit.vir;
        var subs: [8]Inst.Ref = undefined;
        var n: usize = 0;
        var at = r;
        const v = while (true) {
            const i = at.toIndex() orelse return null;
            switch (vir.instructions.items(.tag)[@backingInt(i)]) {
                .elem => {
                    if (n == subs.len) return null;
                    const x = decl.payloadOf(vir, Inst.Bin, i);
                    subs[n] = x.rhs;
                    n += 1;
                    at = x.lhs;
                },
                .decl_ref => break decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl),
                else => return null,
            }
        };
        std.mem.reverse(Inst.Ref, subs[0..n]);
        const p = decl.payloadOf(vir, Inst.Variable, v);
        var flat: u64 = 0;
        var d: usize = 0;
        for (vir.body(p.dims)) |di| {
            if (vir.instructions.items(.tag)[@backingInt(di)] != .range) continue;
            if (d >= n) return null;
            const bin = decl.payloadOf(vir, Inst.Bin, di);
            const msb = ((try decl.foldRef(w.s, w.unit, bin.lhs)) orelse return null).asIntExact() orelse return null;
            const lsb = ((try decl.foldRef(w.s, w.unit, bin.rhs)) orelse return null).asIntExact() orelse return null;
            const k = ((try decl.foldRef(w.s, w.unit, subs[d])) orelse return null).asIntExact() orelse return null;
            if (k < @min(msb, lsb) or k > @max(msb, lsb)) return null;
            const len: u64 = @abs(msb - lsb) + 1;
            flat = flat * len + @abs(k - msb);
            d += 1;
        }
        if (d != n or flat >= std.math.maxInt(u32)) return null;
        return @intCast(flat);
    }

    /// Array variable `v`'s element count (0 when not an array, or past
    /// the walk's bound).
    fn cellsOf(w: *Walk, v: Inst.Index) Allocator.Error!u32 {
        if (w.cells.get(v)) |n| return n;
        const vir = w.unit.vir;
        var n: u64 = 1;
        var dims: u32 = 0;
        for (vir.body(decl.payloadOf(vir, Inst.Variable, v).dims)) |di| {
            if (vir.instructions.items(.tag)[@backingInt(di)] != .range) continue;
            const bin = decl.payloadOf(vir, Inst.Bin, di);
            const msb = ((try decl.foldRef(w.s, w.unit, bin.lhs)) orelse break).asIntExact() orelse break;
            const lsb = ((try decl.foldRef(w.s, w.unit, bin.rhs)) orelse break).asIntExact() orelse break;
            n = std.math.mul(u64, n, @abs(msb - lsb) + 1) catch break;
            dims += 1;
        }
        const cells: u32 = if (dims == 0 or n > cells_max) 0 else @intCast(n);
        try w.cells.put(w.s.arena, v, cells);
        return cells;
    }

    /// The subscripts of an assignment target are reads.
    fn subscripts(w: *Walk, r: Inst.Ref) Allocator.Error!void {
        var at = r;
        const vir = w.unit.vir;
        for (0..depth_max) |_| {
            const i = at.toIndex() orelse return;
            if (vir.instructions.items(.tag)[@backingInt(i)] != .elem) return;
            const x = decl.payloadOf(vir, Inst.Bin, i);
            try w.read(x.rhs, 0);
            at = x.lhs;
        }
    }
};

/// The variable an assignment writes, and whether it writes all of it.
const Target = struct { var_: Inst.Index, whole: bool };

/// Fills `unit.held` with every held variable of the instance's analog
/// blocks, keyed by its declaration's first instruction.
pub fn mark(s: *Sema, unit: *Unit) Allocator.Error!void {
    assert(unit.held.count() == 0);
    const vir = unit.vir;
    for (vir.body(unit.module.body)) |i| {
        const tag = vir.instructions.items(.tag)[@backingInt(i)];
        if (tag != .analog and tag != .analog_initial) continue;
        try eventWrites(s, unit, decl.payloadOf(vir, Inst.Process, i).body, false, 0);
    }
    var w: Walk = .{ .s = s, .unit = unit };
    for (vir.body(unit.module.body)) |i| {
        const tag = vir.instructions.items(.tag)[@backingInt(i)];
        if (tag != .analog and tag != .analog_initial) continue;
        w.in_initial = tag == .analog_initial;
        const b = decl.payloadOf(vir, Inst.Process, i).body;
        if (w.in_initial) {
            const at = w.list.items.len;
            try w.body(b, 0);
            w.undo(at);
        } else try w.body(b, 0);
    }
    var it = w.marks.iterator();
    while (it.next()) |e| if (e.key_ptr.elem == Key.whole and e.value_ptr.read and e.value_ptr.write) {
        const gop = try unit.held.getOrPut(s.arena, e.key_ptr.var_);
        if (gop.found_existing) continue;
        gop.value_ptr.* = if (e.value_ptr.reach or e.value_ptr.initial) .retained else .unless_invariant;
    };
    it = w.marks.iterator();
    while (it.next()) |e| if (e.key_ptr.elem == Key.whole and e.value_ptr.read and (e.value_ptr.initial or unit.held.get(e.key_ptr.var_) == .event))
        try unit.carried.put(s.arena, e.key_ptr.var_, {});
}

// ---- private ----

/// The first argument system call `i` writes (§9.5.3 `$sformat`/`$swrite`
/// its destination, §9.5.4 `$fgets` its string, §9.5.4.2 `$sscanf`/`$fscanf`
/// every argument from the third, §9.5.7 `$ferror` and §9.12
/// `$value$plusargs` their second), or
/// null for a call that writes none.
fn writtenFrom(vir: *const Vir, i: Inst.Index) ?usize {
    const name = vir.string(decl.payloadOf(vir, Inst.SysCall, i).name);
    const table = std.StaticStringMap(usize).initComptime(.{
        .{ "$sformat", 0 }, .{ "$swrite", 0 }, .{ "$fgets", 0 },
        .{ "$sscanf", 2 },  .{ "$fscanf", 2 }, .{ "$value$plusargs", 1 },
        .{ "$ferror", 1 },
    });
    return table.get(name);
}

fn target(vir: *const Vir, r: Inst.Ref) ?Target {
    var at = r;
    var whole = true;
    for (0..depth_max) |_| {
        const i = at.toIndex() orelse return null;
        switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            .decl_ref => {
                const k = decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl);
                if (vir.instructions.items(.tag)[@backingInt(k)] != .variable) return null;
                return .{ .var_ = k, .whole = whole };
            },
            .elem, .slice, .slice_up, .slice_down => {
                whole = false;
                at = if (vir.instructions.items(.tag)[@backingInt(i)] == .elem) decl.payloadOf(vir, Inst.Bin, i).lhs else decl.payloadOf(vir, Inst.Triple, i).a;
            },
            else => return null, // else: no variable is written
        }
    }
    return null;
}

/// Every write inside an `@(...)` body is held (`event`).
fn eventWrites(s: *Sema, unit: *Unit, b: Vir.Body, in_event: bool, depth: u32) Allocator.Error!void {
    if (depth > depth_max) return;
    const vir = unit.vir;
    for (vir.body(b)) |i| {
        const tag = vir.instructions.items(.tag)[@backingInt(i)];
        switch (tag) {
            .store, .store_nb => if (in_event) if (target(vir, decl.payloadOf(vir, Inst.Bin, i).lhs)) |t| try unit.held.put(s.arena, t.var_, .event),
            .block => try eventWrites(s, unit, decl.payloadOf(vir, Inst.Block, i).body, in_event, depth + 1),
            .condbr => {
                const x = decl.payloadOf(vir, Inst.CondBr, i);
                try eventWrites(s, unit, x.then, in_event, depth + 1);
                try eventWrites(s, unit, x.@"else", in_event, depth + 1);
            },
            .case => for (vir.list(Inst.Arm, decl.payloadOf(vir, Inst.Case, i).arms)) |arm| try eventWrites(s, unit, arm.body, in_event, depth + 1),
            .loop => {
                const x = decl.payloadOf(vir, Inst.Loop, i);
                try eventWrites(s, unit, x.body, in_event, depth + 1);
                try eventWrites(s, unit, x.step, in_event, depth + 1);
            },
            .repeat => try eventWrites(s, unit, decl.payloadOf(vir, Inst.Repeat, i).body, in_event, depth + 1),
            .event_wait => try eventWrites(s, unit, decl.payloadOf(vir, Inst.EventWait, i).body, true, depth + 1),
            else => {}, // else: no other statement holds a body
        }
    }
}

/// Every instruction `i` reads as an operand (control.zig's walk).
fn operandsOf(s: *Sema, vir: *const Vir, i: Inst.Index, out: *std.AutoHashMapUnmanaged(Inst.Index, void)) Allocator.Error!void {
    return @import("control.zig").operands(s, vir, i, out);
}
