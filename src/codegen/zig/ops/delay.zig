//! §4.5.7 `absdelay` as `ops.zig` keeps it: a history ring in `Instance`
//! (`op<k>__t`, `__v`, `__head`), the window a full ring keeps (`__w`),
//! td frozen at the first evaluation when it is a signal (`__td`), a
//! signal-valued maxdelay latched at the start of the analysis (`__maxd`),
//! and `Instance.bound_step` held at td. The old device's `instance.zig`,
//! `call_operator.zig`, `accept.zig` and `state_ctl.zig` rows for it, so
//! both compute the same bits with `std_kernels.ops`'s ring.
//! Cites: VAMS-2023 §4.5.7 (absdelay, td, maxdelay), §4.5.14 (a dynamic
//! constant argument), §9.17.2 (`$bound_step`).
//!
//! Contents:
//! - `pub const Delay = struct { len, freezes, sampled, maxd }`
//! - `pub fn plan(dg: *const DeclGen, args: []const Air.Inst.Ref) Delay`
//! - `pub fn fields(dg: *DeclGen, k: usize, d: Delay, out: *std.ArrayList(ops.Field)) DeclGen.Error!void`
//! - `pub fn genRing`, `pub fn genEval`, `pub fn genAccept`, `pub fn genState`, `pub fn genCommit`, `pub fn genRevertPre`, `pub fn genRevertPost`

const std = @import("std");
const assert = std.debug.assert;
const Air = @import("air");
const DeclGen = @import("../DeclGen.zig");
const Function = @import("../Function.zig");
const Liveness = @import("../Liveness.zig");
const ops = @import("../ops.zig");
const Ref = Air.Inst.Ref;
const Error = DeclGen.Error;

/// One site's shape: its ring length, whether td is a frozen signal
/// (two arguments, td not a constant), whether maxdelay is a latched
/// signal, and whether the call has a maxdelay at all.
pub const Delay = struct { len: u32 = hist_len, freezes: bool = false, sampled: bool = false, maxd: bool = false };

/// The ring of a site with no constant `maxdelay`, in samples (the old
/// `instance.zig`'s `hist_len`).
const hist_len: u32 = 1024;
/// The step a `maxdelay` site's ring is sized for, and the largest ring.
const hist_min_step: f64 = 1e-12;
const hist_max: u32 = 16384;

/// The shape of `absdelay(args)`.
pub fn plan(dg: *const DeclGen, args: []const Ref) Delay {
    assert(args.len >= 2 and args.len <= 3);
    var d: Delay = .{ .maxd = args.len == 3 };
    if (args.len == 2) d.freezes = dynamic(dg, args[1]);
    if (args.len == 3) {
        d.sampled = dynamic(dg, args[2]);
        // `ceil(maxdelay / hist_min_step) + 2` samples, the parameter's
        // default for a parameter, within [hist_len, hist_max].
        if (fold(dg, args[2])) |md| {
            const want = md / hist_min_step + 2.0;
            if (want >= @as(f64, hist_max)) d.len = hist_max else if (want > @as(f64, hist_len)) d.len = @intFromFloat(@ceil(want));
        }
    }
    assert(d.len >= hist_len and d.len <= hist_max);
    return d;
}

/// Site `k`'s scalar fields the state keeps.
pub fn fields(dg: *DeclGen, k: usize, d: Delay, out: *std.ArrayList(ops.Field)) Error!void {
    const a = dg.arena;
    try out.append(a, .{ .name = try std.fmt.allocPrint(a, "op{d}__head", .{k}), .ty = "u64", .default = "0" });
    try out.append(a, .{ .name = try std.fmt.allocPrint(a, "op{d}__w", .{k}) });
    if (d.freezes) try out.append(a, .{ .name = try std.fmt.allocPrint(a, "op{d}__td", .{k}) });
    if (d.sampled) try out.append(a, .{ .name = try std.fmt.allocPrint(a, "op{d}__maxd", .{k}) });
}

/// Site `k`'s ring, an `Instance` field pair the state does not copy.
pub fn genRing(dg: *DeclGen, w: *std.Io.Writer, k: usize, d: Delay) Error!void {
    try dg.print(w, "    op{0d}__t: [{1d}]f64 = @splat(0.0),\n    op{0d}__v: [{1d}]f64 = @splat(0.0),\n", .{ k, d.len });
}

/// The rest of site `k`'s value after `ops.gen` recorded its input `o<k>`
/// and controls (td, maxdelay): the small-signal delay for a family with
/// `acMul`, else the ring read at the effective td.
pub fn genEval(f: *Function, k: usize, d: Delay, args: []const Ref, m: Liveness.Mask) Error!void {
    try f.print(" break :op{d} F.zLu(S, 0x{x}, if (comptime @hasDecl(S.Of(0), \"acMul\")) K.ac.zAcDelay(F.zL(S, 0x{x}), F.zLw(S, 0x{x}, ", .{ k, m, m, m });
    try f.real(args[0]);
    // §4.5.7 "td is evaluated as a constant at a particular time for any
    // small signal analysis": read live, clamped by maxdelay.
    try f.print("), ", .{});
    try clamp(f, args, null, d);
    try f.print(") else K.ac.zSs(F.zL(S, 0x{x}), sim.kind, K.ops.zAbsdelay(F.zL(S, 0x{x}), F.zLw(S, 0x{x}, ", .{ m, m, m });
    try f.real(args[0]);
    try f.print("), &inst.op{0d}__t, &inst.op{0d}__v, inst.op{0d}__head, sim.t, sim.dt, ", .{k});
    try clamp(f, args, k, d);
    try f.print("))); }}", .{});
}

/// Site `k`'s accepted step: thin a full ring, push the accepted input,
/// keep the window, latch td and maxdelay at the first point, and bound
/// the next step at td.
pub fn genAccept(dg: *DeclGen, w: *std.Io.Writer, k: usize, d: Delay) Error!void {
    try dg.print(w, "    K.ops.zHistThin(\"op{0d}\", &inst.op{0d}__t, &inst.op{0d}__v, &inst.op{0d}__head, sim.t, inst.op{0d}__w);\n", .{k});
    try dg.print(w, "    K.ops.zHistPush(&inst.op{0d}__t, &inst.op{0d}__v, &inst.op{0d}__head, sim.t, m.o{0d}.val());\n", .{k});
    // §4.5.7 maxdelay bounds every lookback; without one, td is the lookback.
    try dg.print(w, "    inst.op{d}__w = ", .{k});
    if (d.maxd) try dg.print(w, "{s};\n", .{if (d.sampled) try std.fmt.allocPrint(dg.arena, "inst.op{d}__maxd", .{k}) else try std.fmt.allocPrint(dg.arena, "m.o{d}c1", .{k})}) else {
        try stepTd(dg, w, k, d);
        try dg.print(w, ";\n", .{});
    }
    // §4.5.7 "the value of td when the absdelay() is first evaluated shall
    // be used"; §4.5.14 a dynamic maxdelay's value at the start.
    if (d.freezes) try dg.print(w, "    if (sim.t <= inst.t_prev__) inst.op{0d}__td = m.o{0d}c0;\n", .{k});
    if (d.sampled) try dg.print(w, "    if (sim.t <= inst.t_prev__) inst.op{0d}__maxd = m.o{0d}c1;\n", .{k});
    // §9.17.2 a wider step would flatten the delay; only a positive td binds.
    try dg.print(w, "    {{\n        const zad_td = ", .{});
    try stepTd(dg, w, k, d);
    try dg.print(w, ";\n        if (zad_td > 0.0) inst.bound_step = @min(inst.bound_step, zad_td);\n    }}\n", .{});
}

/// Site `k`'s `State` fields: the two samples a rejected push may have
/// overwritten (`zHistRevert`).
pub fn genState(dg: *DeclGen, w: *std.Io.Writer, k: usize) Error!void {
    try dg.print(w, "    op{0d}__t__acc: f64 = 0.0,\n    op{0d}__v__acc: f64 = 0.0,\n    op{0d}__t__acc2: f64 = 0.0,\n    op{0d}__v__acc2: f64 = 0.0,\n", .{k});
}

/// `commit`: the slot the next push writes, and the one after it.
pub fn genCommit(dg: *DeclGen, w: *std.Io.Writer, k: usize, d: Delay) Error!void {
    try dg.print(w,
        \\            state.op{0d}__t__acc = inst.op{0d}__t[@intCast(inst.op{0d}__head % {1d})];
        \\            state.op{0d}__v__acc = inst.op{0d}__v[@intCast(inst.op{0d}__head % {1d})];
        \\            state.op{0d}__t__acc2 = inst.op{0d}__t[@intCast((inst.op{0d}__head + 1) % {1d})];
        \\            state.op{0d}__v__acc2 = inst.op{0d}__v[@intCast((inst.op{0d}__head + 1) % {1d})];
        \\
    , .{ k, d.len });
}

/// `revert`, before `__head` is restored: the count the rejected push left.
pub fn genRevertPre(dg: *DeclGen, w: *std.Io.Writer, k: usize) Error!void {
    try dg.print(w, "            const zh{0d} = inst.op{0d}__head;\n", .{k});
}

/// `revert`, after: the overwritten slots and an undone thinning back.
pub fn genRevertPost(dg: *DeclGen, w: *std.Io.Writer, k: usize) Error!void {
    try dg.print(w, "            K.ops.zHistRevert(&inst.op{0d}__t, &inst.op{0d}__v, inst.op{0d}__head, zh{0d}, state.op{0d}__t__acc, state.op{0d}__v__acc, state.op{0d}__t__acc2, state.op{0d}__v__acc2);\n", .{k});
}

// ---- private ----

/// The effective td in `core`: the frozen field (`k` given) or the live
/// value, clamped to maxdelay (§4.5.7 "If td becomes greater than maxdelay,
/// maxdelay will be used").
fn clamp(f: *Function, args: []const Ref, k: ?usize, d: Delay) Error!void {
    if (d.maxd) try f.print("@min(", .{});
    if (k != null and d.freezes) try f.print("inst.op{d}__td", .{k.?}) else try ops.value(f, args, 1, "0.0");
    if (!d.maxd) return;
    try f.print(", ", .{});
    if (k != null and d.sampled) try f.print("inst.op{d}__maxd", .{k.?}) else try ops.value(f, args, 2, "0.0");
    try f.print(")", .{});
}

/// The effective td in `updateState`, from `core`'s recorded controls.
fn stepTd(dg: *DeclGen, w: *std.Io.Writer, k: usize, d: Delay) Error!void {
    if (d.maxd) try dg.print(w, "@min(", .{});
    if (d.freezes) try dg.print(w, "inst.op{d}__td", .{k}) else try dg.print(w, "m.o{d}c0", .{k});
    if (d.maxd) try dg.print(w, ", {s})", .{if (d.sampled) try std.fmt.allocPrint(dg.arena, "inst.op{d}__maxd", .{k}) else try std.fmt.allocPrint(dg.arena, "m.o{d}c1", .{k})});
}

/// Whether `ref` moves with the solve: it reads something beyond constants
/// and parameters (a probe, a variable, a call).
fn dynamic(dg: *const DeclGen, ref: Ref) bool {
    const root = ref.toIndex() orelse return false;
    const air = dg.air;
    var stack: [64]Air.Inst.Index = undefined;
    stack[0] = root;
    var len: usize = 1;
    // Bounded: a tree past the stack is called dynamic, which only latches.
    var steps: usize = 0;
    while (len != 0) : (steps += 1) {
        if (steps > air.instructions.len) return true;
        len -= 1;
        const i = stack[len];
        const tag = air.instructions.items(.tag)[@backingInt(i)];
        switch (tag) {
            .arg => continue,
            .alloc, .load, .assign, .call, .probe, .block, .loop, .cond_br, .br, .repeat, .ret, .anew, .store, .fload, .iload, .path_prev, .path_acc => return true,
            else => {}, // else: a pure operation over its operands
        }
        var o: Liveness.Operands = .{};
        o.collect(air.*, tag, air.instructions.items(.data)[@backingInt(i)], false);
        for (o.slice()) |r| if (r.toIndex()) |oi| {
            if (len == stack.len) return true;
            stack[len] = oi;
            len += 1;
        };
    }
    return false;
}

/// `ref`'s value when it is a real literal or a parameter with one as its
/// default, else null.
fn fold(dg: *const DeclGen, ref: Ref) ?f64 {
    const key_index = if (ref.toInterned()) |c| c else blk: {
        const i = ref.toIndex().?;
        if (dg.air.instructions.items(.tag)[@backingInt(i)] != .arg) return null;
        const p = dg.air.instructions.items(.data)[@backingInt(i)].ty_index.index;
        break :blk dg.device.params.items(.default)[p];
    };
    if (key_index == .none) return null;
    return switch (dg.ip.indexToKey(key_index)) {
        .float => |x| x,
        else => null, // else: no number to size the ring by
    };
}
