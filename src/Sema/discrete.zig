//! A mixed module's digital half as the analog block sees it (the old
//! `analog/discrete_input.zig` and `context.isMixed`): an instance's
//! continuous assignments, `initial`/`always` processes and nets in; the
//! digital-owned values its analog blocks read out, each a host-written
//! card row of its own name (`n`, `u.clk`), zero by default, typed per
//! Table 7-1. Such a net never becomes an unknown. A module whose digital
//! part is only `initial` blocks of plain assignments is not mixed.
//! Cites: VAMS-2023 §3.7, §7.2, §7.2.2, §7.3.1, §7.3.6.5, Table 7-1.
//!
//! Contents:
//! - `pub fn mark(s: *Sema, unit: *Unit) Allocator.Error!void`
//! - `pub fn declare(s: *Sema, unit: *Unit) Allocator.Error!void`
//! - `pub fn base(vir: *const Vir, r: Inst.Ref) ?Inst.Index`
//! - `pub fn writes(vir: *const Vir, b: Vir.Body, out: *std.ArrayList(Inst.Index), arena: Allocator, depth: u32) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const contrib = @import("contrib.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Unit = Sema.Unit;

/// The deepest statement or expression nesting the walks follow.
const depth_max: u32 = 1 << 12;

/// Fills `unit.discrete` with the digital-owned values the instance's
/// analog blocks read, in the old order (continuous assignment targets,
/// then the processes' writes, then discrete nets read by name).
pub fn mark(s: *Sema, unit: *Unit) Allocator.Error!void {
    assert(unit.discrete.items.len == 0);
    const vir = unit.vir;
    if (!try isMixed(s, unit)) return;
    s.mixed = true;
    var owned: std.ArrayList(Inst.Index) = .empty;
    for (vir.body(unit.module.body)) |i| if (vir.instructions.items(.tag)[@backingInt(i)] == .assign) {
        const a = decl.payloadOf(vir, Inst.Assign, i);
        const lhs = vir.body(a.lhs);
        if (lhs.len == 0) continue;
        const t = base(vir, lhs[lhs.len - 1].toRef()) orelse continue;
        switch (vir.instructions.items(.tag)[@backingInt(t)]) {
            // A.6.1 a continuous assignment drives a net, never a variable.
            .variable => try s.fail(.E0438, unit.file, i.toRef(), "", .{}),
            .net => if (try continuous(s, unit, t)) try s.fail(.E0435, unit.file, i.toRef(), "`{s}` is driven by a continuous assignment", .{vir.string(decl.nameOf(vir, t))}) else try owned.append(s.arena, t),
            else => try owned.append(s.arena, t),
        }
    };
    for (vir.body(unit.module.body)) |i| switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .initial, .always => try writes(vir, decl.payloadOf(vir, Inst.Process, i).body, &owned, s.arena, 0),
        else => {}, // else: no digital process
    };
    var reads: std.AutoArrayHashMapUnmanaged(Inst.Index, void) = .empty;
    for (vir.body(unit.module.body)) |i| switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .analog, .analog_initial => try analogReads(s, unit, decl.payloadOf(vir, Inst.Process, i).body, &reads),
        else => {}, // else: not an analog block
    };
    // §7.3.1 a discrete net the analog block reads holds the kernel's value.
    for (reads.keys()) |d| if (vir.instructions.items(.tag)[@backingInt(d)] == .net and !try continuous(s, unit, d)) try owned.append(s.arena, d);
    for (owned.items) |d| {
        if (!reads.contains(d)) continue;
        if (std.mem.findScalar(Inst.Index, unit.discrete.items, d) != null) continue;
        try unit.discrete.append(s.arena, d);
    }
}

/// One card row per value `mark` found, after every parameter (the old
/// flattened module's order), bound so an analog read is its `arg`.
pub fn declare(s: *Sema, unit: *Unit) Allocator.Error!void {
    const vir = unit.vir;
    const ip = &s.zcu.intern_pool;
    for (unit.discrete.items) |d| {
        const ty: Air.Device.Param.Type = switch (vir.instructions.items(.tag)[@backingInt(d)]) {
            .variable => switch (decl.payloadOf(vir, Inst.Variable, d).flags.storage) {
                .real, .realtime => .real,
                .integer, .time, .reg, .none => .integer,
                .string => {
                    try s.fail(.E0437, unit.file, d.toRef(), "`{s}` is a digital `string`, and Table 7-1 converts only integer, bit and real values", .{vir.string(decl.nameOf(vir, d))});
                    continue;
                },
            },
            .net => if (decl.payloadOf(vir, Inst.Net, d).flags.net == .wreal) .real else .integer,
            else => .integer, // else: a port read as its implicit net
        };
        if (vir.instructions.items(.tag)[@backingInt(d)] == .variable and decl.payloadOf(vir, Inst.Variable, d).dims.len != 0) {
            try s.fail(.E0512, unit.file, d.toRef(), "a digital array the analog block reads is not lowered by Sema yet", .{});
            continue;
        }
        const zero: InternPool.Index = if (ty == .real) .zero_real else .zero;
        const row: Air.Device.Param.Index = @fromBackingInt(@intCast(s.device.params.len));
        try s.device.params.append(s.gpa, .{
            .name = try ip.getString(s.gpa, try std.fmt.allocPrint(s.arena, "{s}{s}", .{ unit.prefix, vir.string(decl.nameOf(vir, d)) })),
            .ty = ty,
            .local = false,
            .default = zero,
            .ranges_start = @intCast(s.device.ranges.items.len),
            .ranges_len = 0,
            .instance = decl.rowInstance(unit.instance),
            .derive = .none,
        });
        const vty: Sema.Ty = if (ty == .real) .real else .integer;
        const arg = try s.air.addInst(s.gpa, .{ .tag = .arg, .data = .{ .ty_index = .{ .ty = decl.typeIndex(vty), .index = @backingInt(row) } } });
        try s.prologue.append(s.arena, arg);
        try s.param_args.append(s.arena, .{ .ref = .fromIndex(arg), .ty = vty });
        try unit.binds.put(s.arena, d, .{ .param = row });
    }
    assert(s.param_args.items.len == s.device.params.len);
}

/// The declaration an assignment target names (through its selects).
pub fn base(vir: *const Vir, r: Inst.Ref) ?Inst.Index {
    var at = r;
    for (0..depth_max) |_| {
        const i = at.toIndex() orelse return null;
        switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            .decl_ref => return decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl),
            .elem => at = decl.payloadOf(vir, Inst.Bin, i).lhs,
            .slice, .slice_up, .slice_down => at = decl.payloadOf(vir, Inst.Triple, i).a,
            else => return null, // else: a concatenation target or no name
        }
    }
    return null;
}

/// Appends every declaration a digital body writes, in order.
pub fn writes(vir: *const Vir, b: Vir.Body, out: *std.ArrayList(Inst.Index), arena: Allocator, depth: u32) Allocator.Error!void {
    if (depth > depth_max) return;
    for (vir.body(b)) |i| switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .store, .store_nb, .proc_assign, .force => if (base(vir, decl.payloadOf(vir, Inst.Bin, i).lhs)) |d| try out.append(arena, d),
        .store_timed, .store_nb_timed => if (base(vir, decl.payloadOf(vir, Inst.Timed, i).lhs)) |d| try out.append(arena, d),
        .block => try writes(vir, decl.payloadOf(vir, Inst.Block, i).body, out, arena, depth + 1),
        .condbr => {
            const x = decl.payloadOf(vir, Inst.CondBr, i);
            try writes(vir, x.then, out, arena, depth + 1);
            try writes(vir, x.@"else", out, arena, depth + 1);
        },
        .case => for (vir.list(Inst.Arm, decl.payloadOf(vir, Inst.Case, i).arms)) |arm| try writes(vir, arm.body, out, arena, depth + 1),
        .loop => {
            const x = decl.payloadOf(vir, Inst.Loop, i);
            try writes(vir, x.body, out, arena, depth + 1);
            try writes(vir, x.step, out, arena, depth + 1);
        },
        .repeat => try writes(vir, decl.payloadOf(vir, Inst.Repeat, i).body, out, arena, depth + 1),
        .wait => try writes(vir, decl.payloadOf(vir, Inst.Wait, i).body, out, arena, depth + 1),
        .delay => try writes(vir, decl.payloadOf(vir, Inst.Delay, i).body, out, arena, depth + 1),
        .event_wait => try writes(vir, decl.payloadOf(vir, Inst.EventWait, i).body, out, arena, depth + 1),
        else => {}, // else: writes nothing
    };
}

// ---- private ----

/// §7.2.2 whether the digital half runs on the mixed kernel: a continuous
/// assignment, a `wreal` net, an `always`, an `initial` that does more than
/// assign, or a discrete net the analog block reads by name.
fn isMixed(s: *Sema, unit: *Unit) Allocator.Error!bool {
    const vir = unit.vir;
    for (vir.body(unit.module.body)) |i| switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .assign, .always => return true,
        .net => if (decl.payloadOf(vir, Inst.Net, i).flags.net == .wreal) return true,
        .initial => if (!plain(vir, decl.payloadOf(vir, Inst.Process, i).body, 0)) return true,
        else => {}, // else: no digital half
    };
    // Only a net of no continuous discipline can be a discrete read.
    const any = for (vir.body(unit.module.body)) |i| {
        if (vir.instructions.items(.tag)[@backingInt(i)] == .net and !try continuous(s, unit, i)) break true;
    } else false;
    if (!any) return false;
    var reads: std.AutoArrayHashMapUnmanaged(Inst.Index, void) = .empty;
    for (vir.body(unit.module.body)) |i| switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .analog, .analog_initial => try analogReads(s, unit, decl.payloadOf(vir, Inst.Process, i).body, &reads),
        else => {}, // else: not an analog block
    };
    for (reads.keys()) |d| if (vir.instructions.items(.tag)[@backingInt(d)] == .net and !try continuous(s, unit, d)) return true;
    return false;
}

/// Whether an `initial` body only assigns (no timing, no task, no call):
/// the old side folds such a block into the initial state.
fn plain(vir: *const Vir, b: Vir.Body, depth: u32) bool {
    if (depth > depth_max) return false;
    for (vir.body(b)) |i| switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .store, .store_nb => {},
        .block => if (!plain(vir, decl.payloadOf(vir, Inst.Block, i).body, depth + 1)) return false,
        .condbr => {
            const x = decl.payloadOf(vir, Inst.CondBr, i);
            if (!plain(vir, x.then, depth + 1) or !plain(vir, x.@"else", depth + 1)) return false;
        },
        .variable, .param => {},
        // A statement the kernel runs: timing, a task or function call, a loop.
        .case, .loop, .repeat, .wait, .delay, .event_wait, .store_timed, .store_nb_timed, .proc_assign, .force, .deassign, .release, .trigger, .disable, .delay_ctl, .event_ctl, .repeat_ctl, .call, .call_sys => return false,
        else => {}, // else: an operand of the statement that reads it
    };
    return true;
}

/// Whether net `d`'s discipline is of the continuous domain (§3.6.2.2: a
/// `domain`, else a nature bound); no discipline is discrete.
fn continuous(s: *Sema, unit: *const Unit, d: Inst.Index) Allocator.Error!bool {
    const name = decl.payloadOf(unit.vir, Inst.Net, d).discipline;
    return s.zcu.continuousDiscipline(if (name == .empty) "" else unit.vir.string(name));
}

/// Every variable or net the analog body `b` reads by name: an access
/// function's operands are nodes, and an assignment's target is written.
/// One worklist, so a deep expression costs no stack and no per-level map.
fn analogReads(s: *Sema, unit: *Unit, b: Vir.Body, out: *std.AutoArrayHashMapUnmanaged(Inst.Index, void)) Allocator.Error!void {
    const vir = unit.vir;
    var stack: std.ArrayList(Inst.Index) = .empty;
    var seen: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
    var ops: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
    try stack.appendSlice(s.arena, vir.body(b));
    while (stack.pop()) |i| {
        if ((try seen.getOrPut(s.arena, i)).found_existing) continue;
        const tag = vir.instructions.items(.tag)[@backingInt(i)];
        switch (tag) {
            .decl_ref => {
                const d = decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl);
                switch (vir.instructions.items(.tag)[@backingInt(d)]) {
                    .variable, .net => try out.put(s.arena, d, {}),
                    else => {}, // else: a parameter, a function, a branch...
                }
                continue;
            },
            .call => if (try contrib.accessCall(s, unit, i.toRef()) != null) continue,
            .store, .store_nb => {
                if (decl.payloadOf(vir, Inst.Bin, i).rhs.toIndex()) |r| try stack.append(s.arena, r);
                continue;
            },
            else => {}, // else: its operands and bodies, below
        }
        ops.clearRetainingCapacity();
        try @import("control.zig").operands(s.arena, vir, i, &ops);
        var it = ops.keyIterator();
        while (it.next()) |o| try stack.append(s.arena, o.*);
        const bodies: []const Vir.Body = switch (tag) {
            .block => &.{decl.payloadOf(vir, Inst.Block, i).body},
            .condbr => &.{ decl.payloadOf(vir, Inst.CondBr, i).then, decl.payloadOf(vir, Inst.CondBr, i).@"else" },
            .loop => &.{ decl.payloadOf(vir, Inst.Loop, i).cond, decl.payloadOf(vir, Inst.Loop, i).body, decl.payloadOf(vir, Inst.Loop, i).step },
            .repeat => &.{decl.payloadOf(vir, Inst.Repeat, i).body},
            .event_wait => &.{decl.payloadOf(vir, Inst.EventWait, i).body},
            else => &.{}, // else: no body (a case's arms below)
        };
        for (bodies) |x| try stack.appendSlice(s.arena, vir.body(x));
        if (tag == .case) for (vir.list(Inst.Arm, decl.payloadOf(vir, Inst.Case, i).arms)) |arm| try stack.appendSlice(s.arena, vir.body(arm.body));
    }
}
