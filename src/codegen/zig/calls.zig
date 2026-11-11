//! One system-function call's value (`Function`'s `call`): the §9.10
//! environment, §9.15 simulation parameters, §9.19 queries, §4.6 analysis
//! tests, §9.11 conversions and the §9.21 table lookup, each spelled as
//! the old device spelled it (`src/codegen/device/codegen/call.zig`,
//! `call_analysis.zig`, `render_sysfunc.zig`), so the two
//! compute the same bits. A §4.6.4 noise source is 0 in the residual.
//! Cites: VAMS-2023 §4.5.4, §4.5.13, §4.6.1, §4.6.3, §4.6.4, §5.10.2, §9.10,
//! §9.11, §9.14, §9.15, §9.18, §9.19, §9.21; IEEE 1364-2005 §17.8, §17.11.1.
//!
//! Contents:
//! - `pub fn genCall(f: *Function, inst: Air.Inst.Index, data: Air.Inst.Data) DeclGen.Error!void`
//! - `pub fn gen(f: *Function, inst: Air.Inst.Index, tag: SysFn.Tag, args: []const Air.Inst.Ref) DeclGen.Error!void`
//! - `pub const host_params`: the §9.15 parameters a host writes into `Model`

const std = @import("std");
const assert = std.debug.assert;
const Air = @import("air");
const InternPool = @import("intern_pool");
const SysFn = @import("vams").SysFn;
const DeclGen = @import("DeclGen.zig");
const Function = @import("Function.zig");
const state = @import("state.zig");
const ops = @import("ops.zig");
const Liveness = @import("Liveness.zig");
const say = @import("say.zig");
const Real = Function.Real;
const Ref = Air.Inst.Ref;
const Error = DeclGen.Error;

/// §9.15 a simulation parameter the host writes: its name, its `Model`
/// field and the field's default (the old `src/ir/simparam.zig` table).
pub const host_params = [_]struct { name: []const u8, field: []const u8, default: f64 }{
    .{ .name = "tnom", .field = "nom_temp__", .default = 27.0 },
    .{ .name = "reltol", .field = "reltol__", .default = 1e-3 },
    .{ .name = "abstol", .field = "abstol__", .default = 1e-12 },
    .{ .name = "vntol", .field = "vntol__", .default = 1e-6 },
    .{ .name = "gmin", .field = "gmin__", .default = 1e-12 },
    .{ .name = "sourceScaleFactor", .field = "source_scale__", .default = 1.0 },
};

/// The analysis names `analysis()` recognises (§4.6.1).
const analysis_names = [_][]const u8{ "static", "ic", "nodeset", "dc", "tran", "ac", "noise" };

/// A `call`: a system function's value, or a task (a statement).
pub fn genCall(f: *Function, inst: Air.Inst.Index, data: Air.Inst.Data) Error!void {
    const air = f.dg.air;
    const x = air.extraData(Air.Call, data.ty_pl.payload);
    const args: []const Ref = @ptrCast(air.extra[x.end..][0..x.data.args_len]);
    const used = f.dg.live.used[@backingInt(inst)];
    const max_tag = std.math.maxInt(@typeInfo(SysFn.Tag).@"enum".tag_type);
    if (x.data.callee > max_tag) return if (used) f.dg.fail("a call of a user function (callee {d})", .{x.data.callee});
    const tag: SysFn.Tag = @fromBackingInt(@intCast(x.data.callee));
    const info = SysFn.get(tag);
    switch (info.family) {
        // §9.4/§9.7 a print or a simulation control task is not part of a
        // residual: the device's display phase runs it.
        .display, .simctl => {
            if (used) return f.dg.fail("the value of `{s}`", .{@tagName(tag)});
            if (f.phase == .say) try say.record(f, inst);
            return;
        },
        else => {}, // else: a value, by tag below
    }
    if (!used and !Liveness.effect(air.*, .call, data)) return;
    // A task with no value (a §9.5 file task) has no spelling here yet.
    if (air.typeOfIndex(f.dg.ip, inst) == .none) return f.dg.fail("the task `{s}`", .{@tagName(tag)});
    try f.line();
    try f.print("const v{d} = ", .{@backingInt(inst)});
    try gen(f, inst, tag, args);
    try f.print(";", .{});
    // An effect whose value nothing reads (an operator only a print reads).
    if (!used) try f.print(" _ = v{d};", .{@backingInt(inst)});
}

/// Writes call `inst`'s value: a family value for a real result, an `i64`
/// for an integer. Fails on a callee this backend does not spell yet.
pub fn gen(f: *Function, inst: Air.Inst.Index, tag: SysFn.Tag, args: []const Ref) Error!void {
    const int = Function.isInt(f.dg.ip, f.dg.air.typeOfIndex(f.dg.ip, inst));
    switch (tag) {
        .@"$temperature" => {
            f.uses.model = true;
            try f.print("S.con(model.temperature__)", .{});
        },
        // §9.10 $vt = kT/q, k/q = 8.617333262e-5 V/K.
        .@"$vt" => if (args.len == 0) {
            f.uses.model = true;
            try f.print("S.con(model.temperature__ * 8.617333262145179e-5)", .{});
        } else {
            try f.print("(", .{});
            try f.real(args[0]);
            try f.print(").scale(8.617333262145179e-5)", .{});
        },
        .@"$abstime", .@"$realtime" => {
            f.uses.sim = true;
            try f.print("S.con(sim.t)", .{});
        },
        .@"$mfactor" => {
            f.uses.inst = true;
            try f.print("M.zInst(S, inst, \"mfactor\")", .{});
        },
        // §9.18 Table 9-29: a top-level device's hierarchical parameters.
        .@"$xposition", .@"$yposition", .@"$angle" => try f.print("S.con(0.0)", .{}),
        .@"$hflip", .@"$vflip" => try f.print("S.con(1.0)", .{}),
        // §9.19 `$param_given`: the card named the parameter (`setGiven`).
        .@"$param_given" => {
            const bit = bit: {
                const i = (if (args.len == 1) args[0].toIndex() else null) orelse break :bit DeclGen.no_bit;
                if (f.dg.air.instructions.items(.tag)[@backingInt(i)] != .arg) break :bit DeclGen.no_bit;
                break :bit f.dg.given_bit[f.dg.air.instructions.items(.data)[@backingInt(i)].ty_index.index];
            };
            if (bit == DeclGen.no_bit) return f.print("@as(i64, 0)", .{});
            f.uses.model = true;
            try f.print("@as(i64, @intFromBool(model.given__.isSet({d})))", .{bit});
        },
        // §4.5.13: limexp is `exp`'s own text (VD-121, as the old device).
        .limexp => {
            try f.print("(", .{});
            try f.real(args[0]);
            try f.print(").exp()", .{});
        },
        // §4.5.4/§4.5.5 the solve an operator's DC form keys on.
        .@"op$static" => {
            f.uses.sim = true;
            try open(f, int);
            try f.print("sim.dt == 0.0 and sim.kind != .ac and sim.kind != .noise", .{});
            try close(f, int);
        },
        // §5.10.2 the global events, an analysis list narrowing them.
        .initial_step, .final_step => {
            f.uses.sim = true;
            try open(f, int);
            try f.print("sim.{t}", .{tag});
            if (args.len != 0) {
                try f.print(" and (", .{});
                try analysisMatch(f, args);
                try f.print(")", .{});
            }
            try close(f, int);
        },
        // §4.6.1 analysis("dc"|"tran"|...).
        .analysis => {
            try open(f, int);
            try analysisMatch(f, args);
            try close(f, int);
        },
        // §4.6.4 a noise source is 0 in the residual; `noisePsd` reads it.
        .white_noise, .flicker_noise, .noise_table, .noise_table_log => try f.print("S.con(0.0)", .{}),
        // §9.15 a known name's value; the fallback where it is not known.
        .@"$simparam" => try simparam(f, args),
        // §9.11 conversions.
        .@"$rtoi" => {
            // Truncation toward zero, saturating (`std.math.lossyCast`).
            try f.print("std.math.lossyCast(i64, @trunc((", .{});
            try f.real(args[0]);
            try f.print(").val()))", .{});
        },
        .@"$itor" => {
            try f.print("S.con(@as(f64, @floatFromInt(", .{});
            try f.int(args[0]);
            try f.print(")))", .{});
        },
        .@"$realtobits" => {
            try f.print("@as(i64, @bitCast((", .{});
            try f.real(args[0]);
            try f.print(").val()))", .{});
        },
        .@"$bitstoreal" => {
            try f.print("S.con(@as(f64, @bitCast(", .{});
            try f.int(args[0]);
            try f.print(")))", .{});
        },
        // §9.14 / IEEE 1364-2005 §17.11.1 at §3.2's 32 bits.
        .@"$clog2" => {
            try f.print("M.zClog2(", .{});
            try f.int(args[0]);
            if (args.len > 1) {
                try f.print(", ", .{});
                try f.int(args[1]);
                try f.print(")", .{});
            } else try f.print(", 32)", .{});
        },
        // §4.5.14 the partial derivative along unknown `u`'s lane, which
        // `ddx_reads` (and so `deriv_reads`) then carries.
        .ddx => {
            const u = state.intConst(f.dg, args[1]) orelse return f.dg.fail("a `ddx` along no constant unknown", .{});
            if (u >= Liveness.unknowns_max) return f.dg.fail("a `ddx` past unknown {d}", .{Liveness.unknowns_max});
            f.dg.ddx_reads |= @as(Liveness.Mask, 1) << @intCast(u);
            try f.print("S.con((", .{});
            try f.real(args[0]);
            try f.print(").ddxAt({d}))", .{u});
        },
        // §9.17.3 a user-function `$limit`: Sema inlined the function and
        // kept its value in the row's slot; the result carries the access
        // function's derivative (`M.zLimitUf`).
        .@"limit$uf" => {
            if (args.len != 2) return f.dg.fail("a malformed `limit$uf` call", .{});
            try f.kernel(f.dg.live.masks[@backingInt(inst)], "zLimitUf", args);
        },
        // The slot's value at the end of the previous iterate
        // (`advanceIteration`, `state.zig`).
        .@"limit$old" => {
            const k = state.intConst(f.dg, args[0]) orelse return f.dg.fail("a malformed `limit$old` call", .{});
            f.uses.inst = true;
            try f.print("M.zInst(S, inst, \"limiter_previous__{d}\")", .{k});
        },
        // A port access keys no state, so §4.5.15 lets the request be
        // declined: the access function's value.
        .@"$limit" => {
            if (args.len != 1) return f.dg.fail("a §9.17.3 `$limit` string form (the host's `limit` hook)", .{});
            try f.real(args[0]);
        },
        // §9.21 a table lookup (`K.table.zTable`), the old `emitTable`.
        .@"$table_model" => try table(f, inst, args),
        // §4.5.5/§4.5.8-§4.5.10 an operator over its `Instance` state (`ops.zig`).
        .transition => try ops.gen(f, inst, .transition, args),
        .slew => try ops.gen(f, inst, .slew, args),
        .idtmod => try ops.gen(f, inst, .idtmod, args),
        .last_crossing => try ops.gen(f, inst, .last_crossing, args),
        .absdelay => try ops.gen(f, inst, .absdelay, args),
        else => {
            // rw-lower's `display$phase` guards a print's operands: `core`
            // drops prints, so it answers 0, and `say` 1. By name, so this
            // spells it before and after the tag lands.
            if (std.mem.eql(u8, @tagName(tag), "display$phase")) return f.print("@as(i64, {d})", .{@intFromBool(f.phase == .say)});
            // §9.4 a print operand's width marker (`say.zig`): its value.
            if (std.mem.eql(u8, @tagName(tag), "display$width") and args.len >= 2) return if (int) f.int(args[0]) else f.real(args[0]);
            return f.dg.fail("a call of `{s}`", .{@tagName(tag)}); // not yet spelled by this backend
        },
    }
}

// ---- private ----

/// Opens a 0/1 value: an `i64` or a real `S.con`.
fn open(f: *Function, int: bool) Error!void {
    try f.print("{s}", .{if (int) "@as(i64, @intFromBool(" else "S.con(if ("});
}

fn close(f: *Function, int: bool) Error!void {
    try f.print("{s}", .{if (int) "))" else ") 1.0 else 0.0)"});
}

/// §4.6.1 whether the running analysis is one of `args`' names.
fn analysisMatch(f: *Function, args: []const Ref) Error!void {
    f.uses.sim = true;
    var first = true;
    for (args) |a| {
        const s = str(f, a) orelse continue;
        if (!first) try f.print(" or ", .{});
        first = false;
        if (std.mem.eql(u8, s, "static")) {
            // Any analysis that computes a DC operating point.
            try f.print("(sim.kind == .static or sim.kind == .ic or sim.kind == .nodeset or sim.kind == .dc)", .{});
        } else if (std.mem.eql(u8, s, "tran")) {
            // "the initial DC and time-sweep phases of a transient".
            try f.print("(sim.kind == .tran or sim.kind == .ic)", .{});
        } else if (for (analysis_names) |n| {
            if (std.mem.eql(u8, n, s)) break true;
        } else false) {
            try f.print("sim.kind == .{s}", .{s});
        } else try f.print("false", .{});
    }
    if (first) try f.print("false", .{});
    assert(f.uses.sim);
}

/// §9.15 `$simparam(name [, fallback])`.
fn simparam(f: *Function, args: []const Ref) Error!void {
    const name = (if (args.len > 0) str(f, args[0]) else null) orelse return f.dg.fail("`$simparam` of a name that is not a literal", .{});
    if (std.mem.eql(u8, name, "iteration")) {
        f.uses.sim = true;
        return f.print("S.con(@floatFromInt(sim.iteration))", .{});
    }
    if (std.mem.eql(u8, name, "dt")) {
        f.uses.sim = true;
        return f.print("S.con(sim.dt)", .{});
    }
    if (std.mem.eql(u8, name, "scale") or std.mem.eql(u8, name, "shrink")) return f.print("S.con(1e0)", .{});
    for (host_params, 0..) |h, k| if (std.mem.eql(u8, h.name, name)) {
        f.uses.model = true;
        f.dg.host_params |= @as(u8, 1) << @intCast(k);
        return f.print("S.con(model.{s})", .{h.field});
    };
    // Not known here (`timeUnit` with no `timescale`, an unknown name).
    if (args.len > 1) return f.real(args[1]);
    try f.print("S.con(0.0)", .{});
}

/// §9.21 `$table_model(ND, NP, NCOL, dep, "<ctl>", site, previous, in...,
/// row...)` (`Sema/table.zig`'s shape): the samples go in as `f64` (§9.21.1
/// fixes them at the first call, so they carry no derivative), the lookup
/// point as `F.zL(S, m)` at the call's mask.
fn table(f: *Function, inst: Air.Inst.Index, args: []const Ref) Error!void {
    const head_fixed = 7;
    if (args.len < head_fixed) return f.dg.fail("a malformed `$table_model` call", .{});
    const nd = state.intConst(f.dg, args[0]) orelse 0;
    const np = state.intConst(f.dg, args[1]) orelse 0;
    const ncol = state.intConst(f.dg, args[2]) orelse 0;
    const dep = state.intConst(f.dg, args[3]) orelse 0;
    const ext = str(f, args[4]) orelse "";
    const site = state.intConst(f.dg, args[5]) orelse 0;
    const head = head_fixed + nd;
    if (nd == 0 or ncol == 0 or args.len != head + np * ncol) return f.dg.fail("a malformed `$table_model` call", .{});
    const m = f.dg.live.masks[@backingInt(inst)];
    const i = @backingInt(inst);
    // `previous` orders the sites; its value is unused.
    try f.print("tbl{d}: {{ _ = ", .{i});
    try f.real(args[6]);
    try f.print("; ", .{});
    // §9.21.1 an array source's samples are captured at the site's first
    // call (`state.zig`); a file's are constants.
    if (site != 0) {
        f.uses.inst = true;
        try f.print("if (!inst.table_ready[{d}]) {{ inst.table_{d} = [_]f64{{", .{ site - 1, site - 1 });
    } else try f.print("const rows = [_]f64{{", .{});
    for (args[head..], 0..) |v, k| {
        if (k != 0) try f.print(", ", .{});
        try f.print("(", .{});
        try f.real(v);
        try f.print(").val()", .{});
    }
    if (site != 0) try f.print("}}; inst.table_ready[{d}] = true; }} const rows = inst.table_{d};", .{ site - 1, site - 1 }) else try f.print("}};", .{});
    try f.print(" break :tbl{d} F.zLu(S, 0x{x}, K.table.zTable(F.zL(S, 0x{x}), {d}, {d}, {d}, {d}, \"{f}\", rows, [_]F.zL(S, 0x{x}){{", .{ i, m, m, np, ncol, nd, dep, std.zig.fmtString(ext), m });
    for (args[head_fixed..head], 0..) |v, k| {
        if (k != 0) try f.print(", ", .{});
        try f.print("F.zLw(S, 0x{x}, ", .{m});
        try f.real(v);
        try f.print(")", .{});
    }
    try f.print("}})); }}", .{});
}

/// The string constant `ref` reads, or null.
fn str(f: *Function, ref: Ref) ?[]const u8 {
    const i = ref.toInterned() orelse return null;
    return switch (f.dg.ip.indexToKey(i)) {
        .str => |s| f.dg.ip.stringToSlice(s),
        else => null, // else: not a string literal
    };
}

test "host_params: every field is a reserved `__` name" {
    for (host_params) |h| try std.testing.expect(std.mem.endsWith(u8, h.field, "__"));
    try std.testing.expect(host_params.len <= 8);
    _ = Real;
}
