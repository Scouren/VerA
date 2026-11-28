//! §5.10.3 the monitored events `cross`, `above` and `timer` as `ops.zig`
//! keeps them: each site's `Instance` fields (`op<k>__prev`; a timer's
//! `__next`, `__start`, `__per`), its value in `core` (the event decided at
//! the point being evaluated), its accepted step in `updateState` (only the
//! history moves there), `Instance.vera_cross_retry__` for a `cross` that
//! gives its own tolerance box, and the host's timer hooks
//! (`pendingBreakpoint`, `nextBreakpoint`). The old device's
//! `call_operator.zig`, `op_zig.zig`, `accept.zig` and `breakpoints.zig`
//! rows for them, so both compute the same bits with `std_kernels.ops`.
//! Cites: VAMS-2023 §5.10.3.1 (cross: transient only, after time advanced
//! from zero; its direction and tolerances), §5.10.3.2 (above: also during
//! initialization), §5.10.3.3 (timer: the latest start and period), §5.10.5
//! (a host places a timepoint on each timer fire).
//!
//! Contents:
//! - `pub const Kind = enum(u8) { cross, above, timer }`
//! - `pub fn of(k: ops.Kind) ?Kind`
//! - `pub fn fields(k: Kind) []const ops.Field`, `pub fn controls(k: Kind) usize`
//! - `pub fn control(f: *Function, k: Kind, args: []const Air.Inst.Ref, j: usize) DeclGen.Error!void`
//! - `pub fn located(dg: *const DeclGen, args: []const Air.Inst.Ref) bool`, `pub fn anyLocated(dg: *const DeclGen) bool`
//! - `pub fn genValue(f: *Function, k: usize, kind: Kind, args: []const Air.Inst.Ref) DeclGen.Error!void`
//! - `pub fn genAccept(dg: *DeclGen, w: *std.Io.Writer, k: usize, kind: Kind, located: bool) DeclGen.Error!void`
//! - `pub fn genBreakpoints(dg: *DeclGen, w: *std.Io.Writer) DeclGen.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Air = @import("air");
const InternPool = @import("intern_pool");
const DeclGen = @import("../DeclGen.zig");
const Function = @import("../Function.zig");
const Ident = @import("../Ident.zig");
const ops = @import("../ops.zig");
const delay = @import("delay.zig");
const Ref = Air.Inst.Ref;
const Error = DeclGen.Error;

/// The §5.10.3 events this file spells.
pub const Kind = enum(u8) { cross, above, timer };

/// A quiet NaN as a literal (`std.math.nan` is comptime work per field,
/// past the branch quota in a device of many timers).
const nan = "@as(f64, @bitCast(@as(u64, 0x7ff8000000000000)))";

/// The deepest expression `overModel` spells before it gives up.
const model_depth_max = 32;

/// The event `k` is, or null for another operator.
pub fn of(k: ops.Kind) ?Kind {
    return switch (k) {
        .cross => .cross,
        .above => .above,
        .timer => .timer,
        .transition, .slew, .idtmod, .last_crossing, .absdelay => null,
    };
}

/// A site's own fields, by suffix (`op<k>__<name>`), at their defaults.
pub fn fields(k: Kind) []const ops.Field {
    return switch (k) {
        // §5.10.3.1/§5.10.3.2 the last accepted input; 0 gives above()'s
        // initial event ("was <= 0, is now > 0" at the first point).
        .cross, .above => &.{.{ .name = "prev" }},
        // §5.10.3.3 the pending deadline and the start and period it was
        // scheduled from; NaN differs from every control, so the first
        // evaluation schedules both.
        .timer => &.{ .{ .name = "next" }, .{ .name = "start", .default = nan }, .{ .name = "per", .default = nan } },
    };
}

/// The f64 controls `core` records for `updateState`: cross's direction,
/// time_tol and expr_tol; timer's period. The input is `o<k>` (a timer's
/// start_time).
pub fn controls(k: Kind) usize {
    return switch (k) {
        .cross => 3,
        .above => 0,
        .timer => 1,
    };
}

/// Writes control `j` of an event site as an `f64` (an absent one is 0).
pub fn control(f: *Function, k: Kind, args: []const Ref, j: usize) Error!void {
    assert(j < controls(k));
    try ops.value(f, args, j + 1, "0.0");
}

/// §5.10.3.1 whether a `cross` gives its own tolerance box, so
/// `updateState` publishes where a late event should have fired: time_tol
/// written, both tolerances constant over the analysis, the enable absent
/// or a nonzero literal (the old `operator_ctrl.crossLocated`).
pub fn located(dg: *const DeclGen, args: []const Ref) bool {
    assert(args.len <= 5);
    if (args.len < 3) return false;
    for (args[2..@min(args.len, 4)]) |a| if (a != .none and delay.dynamic(dg, a)) return false;
    if (args.len < 5) return true;
    const c = args[4].toInterned() orelse return false;
    return switch (dg.ip.indexToKey(c)) {
        .float => |x| x != 0.0,
        .int => |n| n.storage != .small or n.storage.small != 0,
        else => false, // else: no literal to read
    };
}

/// Whether some `cross` site is `located`: then `Instance` has
/// `vera_cross_retry__`.
pub fn anyLocated(dg: *const DeclGen) bool {
    for (dg.op_sites) |s| if (s.kind == .cross and located(dg, siteArgs(dg, s.call))) return true;
    return false;
}

/// The rest of site `k`'s value after `ops.gen` recorded its input and
/// controls: 1 when the event fires at this point, else 0.
pub fn genValue(f: *Function, k: usize, kind: Kind, args: []const Ref) Error!void {
    const int = Function.isInt(f.dg.ip, f.dg.air.typeOfIndex(f.dg.ip, f.dg.op_sites[k].call));
    try f.print(" break :op{d} {s}", .{ k, if (int) "@as(i64, @intFromBool(" else "S.con(if (" });
    switch (kind) {
        // §5.10.3.1 "will not generate events for non-transient analyses
        // ... it can only generate an event after the simulation time has
        // advanced from zero": a transient and a positive `dt`.
        .cross => {
            try f.print("sim.kind == .tran and sim.dt > 0.0 and K.ops.zCrossDir(", .{});
            try ops.value(f, args, 1, "0.0");
            try f.print(", inst.op{d}__prev, ", .{k});
            try ops.value(f, args, 0, "0.0");
            try f.print(")", .{});
        },
        // §5.10.3.2 no transient or `dt` guard: above() "can generate an
        // event during initialization".
        .above => {
            try f.print("inst.op{d}__prev <= 0.0 and ", .{k});
            try ops.value(f, args, 0, "0.0");
            try f.print(" > 0.0", .{});
        },
        // §5.10.3.3 a control changed before the test replaces the pending
        // deadline (`zTimerPending`).
        .timer => {
            try f.print("K.ops.zTimerDue(", .{});
            try ops.value(f, args, 0, "0.0");
            try f.print(", ", .{});
            try ops.value(f, args, 1, "0.0");
            try f.print(", sim.t, inst.op{0d}__start, inst.op{0d}__per, inst.op{0d}__next)", .{k});
        },
    }
    // §5.10.3 "If enable argument is specified and it is zero, then
    // <op>() is inactive".
    const e: usize = if (kind == .cross) 4 else 3;
    if (e < args.len and args[e] != .none) {
        try f.print(" and (", .{});
        if (f.isIntRef(args[e])) try f.int(args[e]) else try ops.value(f, args, e, "0.0");
        try f.print(") != 0", .{});
    }
    try f.print("{s}; }}", .{if (int) "))" else ") 1.0 else 0.0)"});
}

/// Site `k`'s accepted step: only the history moves (`core` raised the
/// event already); `enable` gates the event, not the record.
pub fn genAccept(dg: *DeclGen, w: *std.Io.Writer, k: usize, kind: Kind, loc: bool) Error!void {
    switch (kind) {
        .cross, .above => {
            // §5.10.3.1 a crossing this step found outside its own box: the
            // earliest time inside it, read against `__prev` before it moves.
            if (loc) try dg.print(w,
                \\    if (sim.kind == .tran and sim.dt > 0.0 and K.ops.zCrossDir(m.o{0d}c0, inst.op{0d}__prev, m.o{0d}.val())) if (K.ops.zCrossRetry(inst.op{0d}__prev, m.o{0d}.val(), sim.t, sim.dt, m.o{0d}c1, m.o{0d}c2)) |r| {{
                \\        inst.vera_cross_retry__ = @min(inst.vera_cross_retry__, r);
                \\    }};
                \\
            , .{k});
            try dg.print(w, "    inst.op{0d}__prev = m.o{0d}.val();\n", .{k});
        },
        // §5.10.3.3 the latest start and period define the absolute grid,
        // counted from start, advancing even while enable suppresses delivery.
        .timer => try dg.print(w,
            \\    inst.op{0d}__start = m.o{0d}.val();
            \\    inst.op{0d}__per = m.o{0d}c0;
            \\    inst.op{0d}__next = K.ops.zNextTimer(m.o{0d}.val(), m.o{0d}c0, sim.t) orelse std.math.inf(f64);
            \\
        , .{k}),
    }
}

/// `pendingBreakpoint` (every timer's live deadline) and, when every
/// timer's start and period are expressions over `Model`, `nextBreakpoint`
/// (the §5.10.5 fires recomputed from the card), so a host places a
/// timepoint on each fire. Nothing without a timer.
pub fn genBreakpoints(dg: *DeclGen, w: *std.Io.Writer) Error!void {
    var timers: usize = 0;
    for (dg.op_sites) |s| timers += @intFromBool(s.kind == .timer);
    if (timers == 0) return;
    try dg.print(w, "\n/// §5.10.3.3 the earliest timer event this instance has scheduled\n/// strictly after `t`, re-armed start times included.\npub fn pendingBreakpoint(inst: *const Instance, t: f64) ?f64 {{\n    var best = std.math.inf(f64);\n", .{});
    for (dg.op_sites, 0..) |s, k| if (s.kind == .timer) try dg.print(w, "    if (inst.op{0d}__next > t) best = @min(best, inst.op{0d}__next);\n", .{k});
    try dg.print(w, "    return if (best == std.math.inf(f64)) null else best;\n}}\n", .{});

    // All or nothing: a subset would tell the host this device wants no
    // other timepoints; a missing hook costs accuracy only.
    var body: std.Io.Writer.Allocating = .init(dg.arena);
    var model = false;
    var listed: usize = 0;
    for (dg.op_sites) |s| {
        if (s.kind != .timer) continue;
        const args = siteArgs(dg, s.call);
        // §5.10.3.3 a timer whose enable folds to zero is inactive: no
        // breakpoint, no veto. One over `Model` guards its own; a solved
        // one keeps its breakpoints (a timepoint costs a step, never an answer).
        var guard: ?[]const u8 = null;
        if (3 < args.len and args[3] != .none) {
            var g: std.Io.Writer.Allocating = .init(dg.arena);
            if (try overModel(dg, &g.writer, args[3], &model)) {
                if (constZero(dg, args[3])) continue;
                guard = g.written();
            }
        }
        var start: std.Io.Writer.Allocating = .init(dg.arena);
        if (!try overModel(dg, &start.writer, args[0], &model)) return;
        var period: std.Io.Writer.Allocating = .init(dg.arena);
        if (args.len < 2 or args[1] == .none) period.writer.writeAll("0.0") catch return error.OutOfMemory else if (!try overModel(dg, &period.writer, args[1], &model)) return;
        if (guard) |g| try dg.print(&body.writer, "    if (({s}) != 0.0) {{\n    ", .{g});
        try dg.print(&body.writer, "    if (K.ops.zNextTimer({s}, {s}, t)) |b| best = @min(best, b);\n", .{ start.written(), period.written() });
        if (guard != null) try dg.print(&body.writer, "    }}\n", .{});
        listed += 1;
    }
    assert(listed <= timers);
    if (listed == 0) return;
    try dg.print(w, "\n/// §5.10.5 the earliest `timer` fire strictly after `t`, so the host\n/// puts a timepoint ON the discontinuity instead of across it.\npub fn nextBreakpoint({s}: *const Model, t: f64) ?f64 {{\n    var best = std.math.inf(f64);\n{s}    return if (best == std.math.inf(f64)) null else best;\n}}\n", .{ if (model) "model" else "_", body.written() });
}

// ---- private ----

/// The arguments of call `inst`.
fn siteArgs(dg: *const DeclGen, inst: Air.Inst.Index) []const Ref {
    const air = dg.air;
    const data = air.instructions.items(.data)[@backingInt(inst)];
    const x = air.extraData(Air.Call, data.ty_pl.payload);
    return @ptrCast(air.extra[x.end..][0..x.data.args_len]);
}

/// Whether `ref` is a literal zero, or reads a variable nothing assigns
/// (§3.2: it keeps its zero initial value; the old `foldConst` folds it).
fn constZero(dg: *const DeclGen, ref: Ref) bool {
    if (unassigned(dg, ref)) return true;
    const c = ref.toInterned() orelse return false;
    return switch (dg.ip.indexToKey(c)) {
        .float => |x| x == 0.0,
        .int => |n| n.storage == .small and n.storage.small == 0,
        else => false, // else: not a number
    };
}

/// Whether `ref` loads a scalar slot no `assign` writes and no held field
/// starts: its value is the type's zero at every evaluation.
fn unassigned(dg: *const DeclGen, ref: Ref) bool {
    const i = ref.toIndex() orelse return false;
    const air = dg.air;
    if (air.instructions.items(.tag)[@backingInt(i)] != .load) return false;
    const slot = air.instructions.items(.data)[@backingInt(i)].un_op.toIndex() orelse return false;
    const si = @backingInt(slot);
    if (air.instructions.items(.tag)[si] != .alloc) return false;
    const ty = air.instructions.items(.data)[si].ty;
    if (!Function.isInt(dg.ip, ty) and ty != InternPool.Index.real_type) return false;
    return !dg.live.assigned[si] and dg.held_field[si] == null;
}

/// Writes `ref` as an `f64` over `model` alone (a constant, a parameter,
/// and arithmetic over them), setting `model.*` when it reads one; false
/// (nothing usable written) when it reads anything else.
fn overModel(dg: *const DeclGen, w: *std.Io.Writer, ref: Ref, model: *bool) Error!bool {
    return overModelDepth(dg, w, ref, model, 0);
}

fn overModelDepth(dg: *const DeclGen, w: *std.Io.Writer, ref: Ref, model: *bool, depth: u32) Error!bool {
    if (depth > model_depth_max) return false;
    const p = struct {
        fn f(out: *std.Io.Writer, comptime fmt: []const u8, args: anytype) Error!void {
            out.print(fmt, args) catch return error.OutOfMemory;
        }
    }.f;
    const i = ref.toIndex() orelse {
        const c = ref.toInterned() orelse return false;
        switch (dg.ip.indexToKey(c)) {
            .float => |x| try p(w, "{f}", .{Function.Real{ .x = x }}),
            .int => |n| switch (n.storage) {
                .small => |s| try p(w, "{d}.0", .{s}),
                .big => return false,
            },
            else => return false, // else: a string
        }
        return true;
    };
    if (unassigned(dg, ref)) {
        try p(w, "0.0", .{});
        return true;
    }
    const air = dg.air;
    const tag = air.instructions.items(.tag)[@backingInt(i)];
    const data = air.instructions.items(.data)[@backingInt(i)];
    switch (tag) {
        .arg => {
            model.* = true;
            const name = Ident{ .name = dg.paramName(data.ty_index.index) };
            if (Function.isInt(dg.ip, data.ty_index.ty)) try p(w, "@as(f64, @floatFromInt(model.{f}))", .{name}) else try p(w, "model.{f}", .{name});
            return true;
        },
        .if_cast, .opt_barrier => return overModelDepth(dg, w, data.un_op, model, depth + 1),
        .fneg => {
            try p(w, "(-", .{});
            if (!try overModelDepth(dg, w, data.un_op, model, depth + 1)) return false;
            try p(w, ")", .{});
            return true;
        },
        .fadd, .fsub, .fmul, .fdiv => {
            try p(w, "(", .{});
            if (!try overModelDepth(dg, w, data.bin_op.lhs, model, depth + 1)) return false;
            try p(w, " {s} ", .{switch (tag) {
                .fadd => "+",
                .fsub => "-",
                .fmul => "*",
                else => "/", // else: the prong's four tags
            }});
            if (!try overModelDepth(dg, w, data.bin_op.rhs, model, depth + 1)) return false;
            try p(w, ")", .{});
            return true;
        },
        else => return false, // else: a value that moves with the solve, or one not spelled here
    }
}
