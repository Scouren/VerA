//! §4.5 the stateful analog operators as the device's state: each call
//! site of `transition`, `slew`, `idtmod`, `last_crossing` or `absdelay`
//! (`ops/delay.zig`: its ring) owns
//! `Instance` fields (`op<k>__<slot>`, the old `op_zig.zig` rows), `core`
//! evaluates it from them and returns its
//! input and control values (`o<k>`, `o<k>c<j>`), and `updateState` advances
//! the fields from those at an accepted point, `dt` after the last one
//! (`t_prev__`). `state.zig` keeps the fields across `stateCtl`. The
//! operator kernels are `std_kernels.ops`'s, called as the old device
//! called them (`call_operator.zig`, `accept.zig`), so both compute the
//! same bits.
//! Cites: VAMS-2023 §4.5 (an operator's output is a function of its input
//! and its internal state), §4.5.5 (idtmod), §4.5.8 (transition), §4.5.9
//! (slew), §4.5.10 (last_crossing), §5.10.3.1 (its direction), §10.3
//! (`default_transition`, which Air does not carry yet: 0).
//!
//! Contents:
//! - `pub const Kind = enum { transition, slew, idtmod, last_crossing, absdelay }`, `pub const Site = struct { call, kind, delay }`
//! - `pub const Field = struct { name, ty, default }`
//! - `pub fn plan(dg: *DeclGen) DeclGen.Error!void`
//! - `pub fn fields(dg: *const DeclGen) DeclGen.Error![]const Field`
//! - `pub fn genCoreFields`, `pub fn genDecls`, `pub fn genReturn`: `core`'s side
//! - `pub fn gen(f: *Function, inst: Air.Inst.Index, kind: Kind, args: []const Air.Inst.Ref) DeclGen.Error!void`
//! - `pub fn genAccept(dg: *DeclGen, w: *std.Io.Writer) DeclGen.Error!void`
//! - `pub fn genInstance`, `pub fn genState`, `pub fn genCommit`, `pub fn genRevertPre`, `pub fn genRevertPost`: what `state.zig` adds past the fields
//! - `pub fn value(f: *Function, args: []const Air.Inst.Ref, i: usize, dflt: []const u8) DeclGen.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Air = @import("air");
const SysFn = @import("vams").SysFn;
const DeclGen = @import("DeclGen.zig");
const Function = @import("Function.zig");
const delay = @import("ops/delay.zig");
const Ref = Air.Inst.Ref;
const Error = DeclGen.Error;

/// The operators this file spells.
pub const Kind = enum { transition, slew, idtmod, last_crossing, absdelay };

/// One operator call site, in `Air` order: its index is `k` in its names.
pub const Site = struct { call: Air.Inst.Index, kind: Kind, delay: delay.Delay = .{} };

/// One `f64` `Instance` field the operators own, and its default.
pub const Field = struct { name: []const u8, ty: []const u8 = "f64", default: []const u8 = "0.0" };

/// One field an operator owns: `op<k>__<name>`, at `default`.
const Slot = struct { name: []const u8, default: []const u8 = "0.0" };

/// Fills `dg.op_sites`: every call of an operator `Kind` names.
pub fn plan(dg: *DeclGen) Error!void {
    var sites: std.ArrayList(Site) = .empty;
    const air = dg.air;
    for (air.instructions.items(.tag), air.instructions.items(.data), 0..) |tag, data, i| {
        if (tag != .call) continue;
        const callee = air.extraData(Air.Call, data.ty_pl.payload).data.callee;
        if (callee > std.math.maxInt(@typeInfo(SysFn.Tag).@"enum".tag_type)) continue;
        const kind: Kind = switch (@as(SysFn.Tag, @fromBackingInt(@intCast(callee)))) {
            .transition => .transition,
            .slew => .slew,
            .idtmod => .idtmod,
            .last_crossing => .last_crossing,
            .absdelay => .absdelay,
            else => continue, // else: not an operator this file spells
        };
        const x = air.extraData(Air.Call, data.ty_pl.payload);
        const args: []const Ref = @ptrCast(air.extra[x.end..][0..x.data.args_len]);
        try sites.append(dg.arena, .{ .call = @fromBackingInt(@intCast(i)), .kind = kind, .delay = if (kind == .absdelay) delay.plan(dg, args) else .{} });
    }
    dg.op_sites = sites.items;
    assert(dg.op_sites.len <= air.instructions.len);
}

/// Every operator field, then `t_prev__` (the last accepted time) when
/// there is one: what `Instance` declares and `stateCtl` keeps.
pub fn fields(dg: *const DeclGen) Error![]const Field {
    var out: std.ArrayList(Field) = .empty;
    for (dg.op_sites, 0..) |s, k| {
        if (s.kind == .absdelay) try delay.fields(@constCast(dg), k, s.delay, &out);
        for (slots(s.kind)) |slot| try out.append(dg.arena, .{ .name = try std.fmt.allocPrint(dg.arena, "op{d}__{s}", .{ k, slot.name }), .default = slot.default });
    }
    if (out.items.len != 0) try out.append(dg.arena, .{ .name = "t_prev__", .default = "0.0" });
    assert(out.items.len == 0 or dg.op_sites.len != 0);
    return out.items;
}

/// `Core(S)`'s operator fields: each site's input and control values; then
/// §9.17.2 `$bound_step`'s own running minimum (`genAccept` reads it as
/// `m.bound_step`, independent of any operator).
pub fn genCoreFields(dg: *DeclGen, w: *std.Io.Writer) Error!void {
    for (dg.op_sites, 0..) |s, k| {
        try dg.print(w, " o{d}: F.zOf(S, 0x{x}),", .{ k, dg.live.masks[@backingInt(s.call)] });
        for (0..controls(s.kind)) |j| try dg.print(w, " o{d}c{d}: f64,", .{ k, j });
    }
    if (dg.device.kernel.bound_step) |a| try dg.print(w, " bound_step: F.zOf(S, 0x{x}),", .{dg.live.masks[@backingInt(a)]});
}

/// `core`'s locals the sites write, before the body.
pub fn genDecls(dg: *DeclGen, w: *std.Io.Writer) Error!void {
    for (dg.op_sites, 0..) |s, k| {
        const m = dg.live.masks[@backingInt(s.call)];
        try dg.print(w, "\n    var o{0d}: F.zOf(S, 0x{1x}) = F.zTo(S, 0x{1x}, S.con(0.0)); _ = &o{0d};", .{ k, m });
        for (0..controls(s.kind)) |j| try dg.print(w, "\n    var o{0d}c{1d}: f64 = 0.0; _ = &o{0d}c{1d};", .{ k, j });
    }
}

/// `core`'s `return` entries of the sites, then `$bound_step`'s slot.
pub fn genReturn(dg: *DeclGen, w: *std.Io.Writer) Error!void {
    for (dg.op_sites, 0..) |s, k| {
        try dg.print(w, " .o{0d} = o{0d},", .{k});
        for (0..controls(s.kind)) |j| try dg.print(w, " .o{0d}c{1d} = o{0d}c{1d},", .{ k, j });
    }
    if (dg.device.kernel.bound_step) |a| try dg.print(w, " .bound_step = s{d},", .{@backingInt(a)});
}

/// Writes operator call `inst`'s value: in `core` a block that records the
/// input and controls for `updateState`, then the kernel; in `say` the
/// kernel alone.
pub fn gen(f: *Function, inst: Air.Inst.Index, kind: Kind, args: []const Ref) Error!void {
    const dg = f.dg;
    const k = for (dg.op_sites, 0..) |s, k| {
        if (s.call == inst) break k;
    } else unreachable; // `plan` named every operator call
    const m = dg.live.masks[@backingInt(inst)];
    f.uses.inst = true;
    f.uses.sim = true;
    const core = f.phase == .core;
    try f.print("op{d}: {{", .{k});
    if (core) {
        try f.print(" o{d} = F.zTo(S, 0x{x}, ", .{ k, m });
        try f.real(args[0]);
        try f.print(");", .{});
        for (0..controls(kind)) |j| {
            try f.print(" o{d}c{d} = ", .{ k, j });
            try control(f, kind, args, j);
            try f.print(";", .{});
        }
    }
    if (kind == .absdelay) return delay.genEval(f, k, dg.op_sites[k].delay, args, m);
    try f.print(" break :op{d} F.zLu(S, 0x{x}, K.ops.{s}(F.zL(S, 0x{x}), F.zLw(S, 0x{x}, ", .{
        k, m,
        switch (kind) {
            .transition => "zTransition",
            .slew => "zSlew",
            .idtmod => "zIdtmod",
            .last_crossing => "zLastCross",
            .absdelay => unreachable, // `delay.genEval`
        },
        m, m,
    });
    try f.real(args[0]);
    switch (kind) {
        .transition => try f.print("), inst.op{0d}__from, inst.op{0d}__to, inst.op{0d}__t0, sim.t, sim.dt, ", .{k}),
        .slew => try f.print("), inst.op{d}__prev, sim.dt, ", .{k}),
        .idtmod => try f.print("), inst.op{d}__acc, sim.dt, ", .{k}),
        .absdelay => unreachable, // `delay.genEval`
        // §4.5.10 a crossing since the last accepted point is the last one;
        // `sim.dt > 0` is the seeding rule `updateState` keeps too.
        .last_crossing => {
            try f.print("), inst.op{0d}__prev, sim.t, sim.dt, inst.op{0d}__t_last, sim.dt > 0.0 and K.ops.zCrossDir(", .{k});
            try control(f, kind, args, 0);
            try f.print(", inst.op{d}__prev, (", .{k});
            try f.real(args[0]);
            return f.print(").val()))); }}", .{});
        },
    }
    // The rates and times the kernel reads; `transition`'s td is the accept's.
    const first: usize = if (kind == .transition) 1 else 0;
    for (first..controls(kind), 0..) |j, n| {
        if (n != 0) try f.print(", ", .{});
        if (kind == .slew and j == 1) try f.print("@abs(", .{});
        try control(f, kind, args, j);
        if (kind == .slew and j == 1) try f.print(")", .{});
    }
    try f.print(")); }}", .{});
}

/// `updateState`'s operator steps, reading `core`'s `m` and `dt`; then
/// §9.17.2 `$bound_step`'s own running minimum (T36), composed with any
/// ring's by `@min`, independent of whether the device has an operator.
pub fn genAccept(dg: *DeclGen, w: *std.Io.Writer) Error!void {
    const bound_step = dg.device.kernel.bound_step != null;
    if (dg.op_sites.len == 0 and !bound_step) return;
    // §9.17.2 reset first: a bound last step set must not bind this one.
    if (delays(dg) or bound_step) try dg.print(w, "    inst.bound_step = std.math.inf(f64);\n", .{});
    if (dg.op_sites.len != 0) {
        try dg.print(w, "    const dt = sim.t - inst.t_prev__;\n    _ = &dt;\n", .{});
        for (dg.op_sites, 0..) |s, k| switch (s.kind) {
            // §4.5.8 the accepted input arms or readjusts the excursion.
            .transition => try dg.print(w, "    K.ops.zTransStep(m.o{0d}.val(), &inst.op{0d}__from, &inst.op{0d}__to, &inst.op{0d}__t0, sim.t, dt, m.o{0d}c0, m.o{0d}c1, m.o{0d}c2);\n", .{k}),
            // §4.5.9 the output the rates allowed is the next step's origin.
            .slew => try dg.print(w, "    inst.op{0d}__prev = K.ops.zSlew(F.zL(S, 0), F.zL(S, 0).con(m.o{0d}.val()), inst.op{0d}__prev, dt, m.o{0d}c0, @abs(m.o{0d}c1)).val();\n", .{k}),
            // §4.5.5 the accepted integral, wrapped.
            .idtmod => try dg.print(w, "    inst.op{0d}__acc = K.ops.zWrap(K.ops.zIdtAcc(m.o{0d}.val(), inst.op{0d}__acc, dt, m.o{0d}c0), m.o{0d}c1, m.o{0d}c2);\n", .{k}),
            // §4.5.10 latch the crossing `eval` answered with (the same
            // operations, so the same bits), then move the history.
            .last_crossing => try dg.print(w,
                \\    if (dt > 0.0 and K.ops.zCrossDir(m.o{0d}c0, inst.op{0d}__prev, m.o{0d}.val())) inst.op{0d}__t_last = (sim.t - sim.dt) + inst.op{0d}__prev / (inst.op{0d}__prev - m.o{0d}.val()) * sim.dt;
                \\    inst.op{0d}__prev = m.o{0d}.val();
                \\
            , .{k}),
            .absdelay => try delay.genAccept(dg, w, k, s.delay),
        };
    }
    // T36: the device never wrote the `$bound_step()` calls' own running
    // minimum back to `Instance` (only an absdelay ring's `zad_td` did);
    // `m.bound_step` is `core`'s copy of the alloc `kernel.zig`'s
    // `runningMin` already accumulated correctly along the executed CFG.
    if (bound_step) try dg.print(w, "    inst.bound_step = @min(inst.bound_step, m.bound_step.val());\n", .{});
    if (dg.op_sites.len != 0) try dg.print(w, "    inst.t_prev__ = sim.t;\n", .{});
}

/// `Instance`'s fields past `fields`: the rings, and `bound_step` (§9.17.2,
/// the host reads it after an accepted step) when a ring bounds it or the
/// device calls `$bound_step` itself (T36).
pub fn genInstance(dg: *DeclGen, w: *std.Io.Writer) Error!void {
    for (dg.op_sites, 0..) |s, k| if (s.kind == .absdelay) try delay.genRing(dg, w, k, s.delay);
    if (delays(dg) or dg.device.kernel.bound_step != null) try dg.print(w, "    bound_step: f64 = std.math.inf(f64),\n", .{});
}

/// `State`'s fields past `fields`.
pub fn genState(dg: *DeclGen, w: *std.Io.Writer) Error!void {
    for (dg.op_sites, 0..) |s, k| if (s.kind == .absdelay) try delay.genState(dg, w, k);
}

/// `stateCtl(.commit)`'s lines past the field copies.
pub fn genCommit(dg: *DeclGen, w: *std.Io.Writer) Error!void {
    for (dg.op_sites, 0..) |s, k| if (s.kind == .absdelay) try delay.genCommit(dg, w, k, s.delay);
}

/// `stateCtl(.revert)`'s lines before the field copies.
pub fn genRevertPre(dg: *DeclGen, w: *std.Io.Writer) Error!void {
    for (dg.op_sites, 0..) |s, k| if (s.kind == .absdelay) try delay.genRevertPre(dg, w, k);
}

/// `stateCtl(.revert)`'s lines after the field copies.
pub fn genRevertPost(dg: *DeclGen, w: *std.Io.Writer) Error!void {
    for (dg.op_sites, 0..) |s, k| if (s.kind == .absdelay) try delay.genRevertPost(dg, w, k);
}

/// Writes argument `i` as an `f64`, or `dflt` when the call has none.
pub fn value(f: *Function, args: []const Ref, i: usize, dflt: []const u8) Error!void {
    if (i >= args.len or args[i] == .none) return f.print("{s}", .{dflt});
    if (f.isIntRef(args[i])) {
        try f.print("@as(f64, @floatFromInt(", .{});
        try f.int(args[i]);
        return f.print("))", .{});
    }
    try f.print("(", .{});
    try f.real(args[i]);
    try f.print(").val()", .{});
}

// ---- private ----

/// Whether some site is an `absdelay`.
fn delays(dg: *const DeclGen) bool {
    for (dg.op_sites) |s| if (s.kind == .absdelay) return true;
    return false;
}

fn slots(kind: Kind) []const Slot {
    return switch (kind) {
        // §4.5.8 the ramp's origin, destination and start time.
        .transition => &.{ .{ .name = "from" }, .{ .name = "to" }, .{ .name = "t0" } },
        // §4.5.9 the last accepted output.
        .slew => &.{.{ .name = "prev" }},
        // §4.5.5 the accepted integral.
        .idtmod => &.{.{ .name = "acc" }},
        // §4.5.10 the last accepted input, and the crossing time (-1: none yet).
        .last_crossing => &.{ .{ .name = "prev" }, .{ .name = "t_last", .default = "-1.0" } },
        // `delay.fields`: its shape is the call's.
        .absdelay => &.{},
    };
}

/// The f64 controls a site records: `transition`'s td, rise and fall,
/// `slew`'s positive and negative rates, `idtmod`'s ic, modulus and offset,
/// `last_crossing`'s direction.
fn controls(kind: Kind) usize {
    return switch (kind) {
        .transition, .idtmod => 3,
        .slew, .absdelay => 2,
        .last_crossing => 1,
    };
}

/// Writes control `j` of a site as an `f64`, with §4.5.8's and §4.5.9's
/// defaults: td 0; a rise time absent or 0 is the `default_transition`
/// (0 here), a fall time absent or 0 the rise time; a positive slew rate
/// absent is 1e300, a negative one the positive one.
fn control(f: *Function, kind: Kind, args: []const Ref, j: usize) Error!void {
    switch (kind) {
        .transition => switch (j) {
            0 => try value(f, args, 1, "0.0"),
            1 => try value(f, args, 2, "0.0"),
            else => {
                if (args.len <= 3) return value(f, args, 2, "0.0");
                // ponytail: re-evaluates the operands; the old device did too.
                try f.print("(if ((", .{});
                try value(f, args, 3, "0.0");
                try f.print(") != 0.0) (", .{});
                try value(f, args, 3, "0.0");
                try f.print(") else (", .{});
                try value(f, args, 2, "0.0");
                try f.print("))", .{});
            },
        },
        .slew => if (j == 0) try value(f, args, 1, "1e300") else if (args.len > 2) try value(f, args, 2, "0.0") else try value(f, args, 1, "1e300"),
        .idtmod => try value(f, args, j + 1, "0.0"),
        .last_crossing => try value(f, args, 1, "0.0"),
        // §4.5.7 td and maxdelay, as written.
        .absdelay => try value(f, args, j + 1, "0.0"),
    }
}
