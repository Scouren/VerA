//! §5.10 the held variables as the device's state: each held slot an
//! `Instance` field the body starts from (`Function` reads it into the
//! slot), `core` returns it, `updateState` writes it back at an accepted
//! point, and `State` keeps the last committed copy for `stateCtl`'s
//! revert (the old device's `held` protocol, `src/codegen/device/codegen/
//! state.zig`). Fields are named `<name>__held`, a held array's one
//! `[n]` field (DV1: indexed in a loop, never one field per element); no
//! host reads them by name. The §9.21.1 `$table_model`
//! snapshots ride the same protocol (`table_<k>`, `table_ready`,
//! `table_kept`, the old `instance.zig`/`state_ctl.zig` names).
//! Cites: VAMS-2023 §5.10 (variables keep their value between
//! evaluations), §3.2 (a declaration initializer), §8.2 (it runs once),
//! §9.21.1 (an array source is read at the first call).
//!
//! Contents:
//! - `pub fn plan(dg: *DeclGen) DeclGen.Error!void`
//! - `pub fn genInstanceFields(dg: *DeclGen, w: *std.Io.Writer) DeclGen.Error!void`
//! - `pub fn genEntries(dg: *DeclGen, w: *std.Io.Writer) DeclGen.Error!void`
//! - `pub fn intConst(dg: *const DeclGen, ref: Air.Inst.Ref) ?usize`
//! - `pub fn arrayLen(dg: *const DeclGen, i: usize) ?u32`

const std = @import("std");
const assert = std.debug.assert;
const Air = @import("air");
const InternPool = @import("intern_pool");
const SysFn = @import("vams").SysFn;
const DeclGen = @import("DeclGen.zig");
const Function = @import("Function.zig");
const Ident = @import("Ident.zig");
const ops = @import("ops.zig");
const status = @import("status.zig");
const array = @import("array.zig");
const strings = @import("strings.zig");
const Real = Function.Real;

/// Fills `dg.held_field` (per `alloc`, its `Instance` field when held) and
/// `dg.table_len` (per §9.21.1 snapshot site, its sample count).
pub fn plan(dg: *DeclGen) DeclGen.Error!void {
    const d = dg.device;
    try planTables(dg);
    dg.held_field = try dg.arena.alloc(?[]const u8, dg.air.instructions.len);
    @memset(dg.held_field, null);
    for (d.held.items(.name), d.held.items(.slot), d.held.items(.count)) |n, slot, count| {
        const name = dg.ip.stringToSlice(n);
        const i = @backingInt(slot);
        if (i >= dg.air.instructions.len or dg.air.instructions.items(.tag)[i] != .alloc) return dg.fail("held variable `{s}`'s slot is not an alloc", .{name});
        // A held array is one of `Device.arrays`: its first slot names the field.
        if (count != 1 and (array.base(dg, i) != i or arrayLen(dg, i) != count)) return dg.fail("held array `{s}` is not one declared array", .{name});
        dg.held_field[i] = try std.fmt.allocPrint(dg.arena, "{f}__held", .{Ident{ .name = name }});
    }
}

/// The element count when slot `i` starts a §3.2.2 array, else null (a
/// scalar).
pub fn arrayLen(dg: *const DeclGen, i: usize) ?u32 {
    const g = dg.group[i];
    if (g == .none) return null;
    const a = dg.device.arrays.items[@backingInt(g)];
    if (@backingInt(a.slot) != i) return null;
    assert(a.count > 1);
    return a.count;
}

/// The held fields of `Instance`, each at its §3.2 initializer (0 without),
/// then the §9.21.1 snapshots: each site's samples, `table_ready` (captured
/// this evaluation) and `table_kept` (captured at an accepted point).
pub fn genInstanceFields(dg: *DeclGen, w: *std.Io.Writer) DeclGen.Error!void {
    for (0..dg.device.limit_slots.len) |k| w.print("    limiter_previous__{d}: f64 = 0.0,\n", .{k}) catch return error.OutOfMemory;
    for (dg.table_len, 0..) |n, k| w.print("    table_{d}: [{d}]f64 = @splat(0.0),\n", .{ k, n }) catch return error.OutOfMemory;
    if (dg.table_len.len != 0) w.print("    table_ready: [{0d}]bool = @splat(false),\n    table_kept: [{0d}]bool = @splat(false),\n", .{dg.table_len.len}) catch return error.OutOfMemory;
    for (try ops.fields(dg)) |o| w.print("    {s}: {s} = {s},\n", .{ o.name, o.ty, o.default }) catch return error.OutOfMemory;
    try ops.genInstance(dg, w);
    for (dg.held_field, 0..) |field, i| if (field) |f| {
        w.print("    {s}: ", .{f}) catch return error.OutOfMemory;
        try writeType(dg, w, i);
        w.writeAll(" = ") catch return error.OutOfMemory;
        try writeHeldInit(dg, w, i);
        w.writeAll(",\n") catch return error.OutOfMemory;
    };
}

/// `State`, `initState`, `updateState`, `stateCtl` and `state_class` when
/// the device holds a variable, snapshots a table or reports §9.7.3 status
/// (either then `mutable_eval`), or keeps a §9.17.3 `$limit` slot (then
/// `advanceIteration`).
pub fn genEntries(dg: *DeclGen, w: *std.Io.Writer) DeclGen.Error!void {
    var held = false;
    for (dg.held_field) |f| held = held or f != null;
    const tables = dg.table_len.len != 0;
    const limits = dg.device.limit_slots.len;
    // §4.5 the operators' fields, kept like the held values.
    const opf = try ops.fields(dg);
    const st = status.hasStatus(dg);
    // T36: `$bound_step` needs `run`'s `m` even with no held variable,
    // table, limiter, operator or status (`ops.genAccept` writes it).
    const bound_step = dg.device.kernel.bound_step != null;
    if (!held and !tables and limits == 0 and opf.len == 0 and !st and !bound_step) return;
    const p = struct {
        fn f(out: *std.Io.Writer, comptime fmt: []const u8, args: anytype) DeclGen.Error!void {
            out.print(fmt, args) catch return error.OutOfMemory;
        }
    }.f;
    // §9.21.1 the first call of a site captures its samples into `inst`
    // (and, the same way, a status call: `eval`/`q` latch `inst` directly).
    if (tables or st) try p(w, "\npub const mutable_eval = true;\n", .{});
    try p(w, "\n/// §5.10 the held values as last committed (`stateCtl`).\npub const State = struct {{\n", .{});
    if (tables) try p(w, "    table_kept: [{d}]bool = @splat(false),\n", .{dg.table_len.len});
    for (0..limits) |k| try p(w, "    limiter_previous__{d}: f64 = 0.0,\n", .{k});
    for (opf) |o| try p(w, "    {s}: {s} = {s},\n", .{ o.name, o.ty, o.default });
    try ops.genState(dg, w);
    for (dg.held_field, 0..) |field, i| if (field) |f| {
        try p(w, "    {s}: ", .{f});
        try writeType(dg, w, i);
        try p(w, " = ", .{});
        try writeHeldInit(dg, w, i);
        try p(w, ",\n", .{});
    };
    try p(w, "}};\n\n/// Every held value back to its initializer: the start of an analysis.\npub fn initState(_: *const Model, {s}: *Instance) State {{\n", .{if (held or opf.len != 0 or st) "inst" else "_"});
    for (opf) |o| try p(w, "    inst.{s} = {s};\n", .{ o.name, o.default });
    for (dg.held_field, 0..) |field, i| if (field) |f| {
        try p(w, "    inst.{s} = ", .{f});
        try writeHeldInit(dg, w, i);
        try p(w, ";\n", .{});
    };
    // §9.7.3 a latched status is re-initialized like any other variable
    // (§4.6.2: "re-initialized to zero ... at the start of each new analysis").
    if (st) try p(w, "    inst.vera_status__ = 0;\n    inst.vera_status_args__ = @splat(0.0);\n", .{});
    try p(w, "    return .{{}};\n}}\n\n/// §5.10 an accepted point: the body's held values become the instance's.\npub fn updateState(comptime S: type, model: *const Model, inst: *Instance, x: [n_u]f64, _: *State, sim: contract.SimState) contract.UpdateResult {{\n", .{});
    // A status-only device reads none of these in its own right; `run`
    // (held values, table captures, operators, `$bound_step`) is what
    // would otherwise.
    if (!tables and !(held or opf.len != 0 or bound_step)) try p(w, "    _ = .{{ S, model, x, sim }};\n", .{});
    // §9.7.3 a latched status: the device stopped, so its state stays put.
    if (st) try p(w, "    if (inst.vera_status__ != 0) return .ok;\n", .{});
    // §9.21.1 a capture an iterate made is kept only at an accepted point:
    // the body runs once more at `x` while a site is uncaptured.
    if (tables) try p(w, "    if (std.mem.findScalar(bool, &inst.table_kept, false) != null) {{\n        _ = run(S, &x, D.zProbe(S, &x), model, inst, sim);\n        inst.table_kept = inst.table_ready;\n    }}\n", .{});
    if (held or opf.len != 0 or bound_step) try p(w, "    const m = run(S, &x, D.zProbe(S, &x), model, inst, sim);\n", .{});
    try ops.genAccept(dg, w);
    for (dg.held_field, 0..) |field, i| if (field) |f| {
        if (isStr(dg, i))
            try p(w, "    inst.{s} = K.str.zStrHeldN({d}, m.h{d});\n", .{ f, try strings.capOf(dg, i), i })
        else if (arrayLen(dg, i) != null and !isInt(dg, i))
            try p(w, "    for (&inst.{s}, m.h{d}) |*e, v| e.* = v.val();\n", .{ f, i })
        else
            try p(w, "    inst.{s} = m.h{d}{s};\n", .{ f, i, if (isInt(dg, i)) "" else ".val()" });
    };
    // A status-only device's `commit`/`revert` copy nothing: `inst` and
    // `state` would otherwise go unused.
    const copies = tables or held or limits != 0 or opf.len != 0;
    try p(w, "    return .ok;\n}}\n\n/// `commit` keeps the instance's held values; `revert` restores them.\npub fn stateCtl(_: *const Model, {s}: *Instance, {s}: *State, op: contract.StateCtlOp) bool {{\n    switch (op) {{\n        .query => {{}},\n        .commit => {{\n", .{ if (copies) "inst" else "_", if (copies) "state" else "_" });
    if (tables) try p(w, "            state.table_kept = inst.table_kept;\n            inst.table_ready = inst.table_kept;\n", .{});
    for (dg.held_field) |field| if (field) |f| try p(w, "            state.{s} = inst.{s};\n", .{ f, f });
    for (0..limits) |k| try p(w, "            state.limiter_previous__{0d} = inst.limiter_previous__{0d};\n", .{k});
    for (opf) |o| try p(w, "            state.{0s} = inst.{0s};\n", .{o.name});
    try ops.genCommit(dg, w);
    try p(w, "        }},\n        .revert => {{\n", .{});
    try ops.genRevertPre(dg, w);
    if (tables) try p(w, "            inst.table_kept = state.table_kept;\n            inst.table_ready = inst.table_kept;\n", .{});
    for (dg.held_field) |field| if (field) |f| try p(w, "            inst.{s} = state.{s};\n", .{ f, f });
    for (0..limits) |k| try p(w, "            inst.limiter_previous__{0d} = state.limiter_previous__{0d};\n", .{k});
    for (opf) |o| try p(w, "            inst.{0s} = state.{0s};\n", .{o.name});
    try ops.genRevertPost(dg, w);
    try p(w, "        }},\n    }}\n    return false;\n}}\n\npub const state_class: contract.StateClass = .history;\n", .{});
    if (limits == 0) return;
    // §9.17.3 after each Newton iterate, each `$limit` slot's value is the
    // next iterate's previous one (`limit$old`).
    try p(w, "\n/// §9.17.3 an iterate's limited values become the next one's previous ones.\npub fn advanceIteration(comptime S: type, model: *const Model, inst: *Instance, x: [n_u]f64, sim: contract.SimState) void {{\n    const m = run(S, &x, D.zProbe(S, &x), model, inst, sim);\n", .{});
    for (0..limits) |k| try p(w, "    inst.limiter_previous__{0d} = m.l{0d}.val();\n", .{k});
    try p(w, "}}\n", .{});
}

// ---- private ----

/// `dg.table_len`: each `$table_model` call's snapshot site (`args[5]`,
/// 1-based; 0 for a file source) and its `NP * NCOL` samples.
fn planTables(dg: *DeclGen) DeclGen.Error!void {
    var len: std.ArrayList(u32) = .empty;
    const air = dg.air;
    for (air.instructions.items(.tag), air.instructions.items(.data)) |tag, data| {
        if (tag != .call) continue;
        const x = air.extraData(Air.Call, data.ty_pl.payload);
        if (x.data.callee != @backingInt(SysFn.Tag.@"$table_model") or x.data.args_len < 7) continue;
        const args: []const Air.Inst.Ref = @ptrCast(air.extra[x.end..][0..x.data.args_len]);
        const site = intConst(dg, args[5]) orelse continue;
        if (site == 0) continue;
        const n = (intConst(dg, args[1]) orelse 0) * (intConst(dg, args[2]) orelse 0);
        while (len.items.len < site) try len.append(dg.arena, 0);
        len.items[site - 1] = @intCast(n);
    }
    dg.table_len = len.items;
}

/// The non-negative integer constant `ref` reads, or null.
pub fn intConst(dg: *const DeclGen, ref: Air.Inst.Ref) ?usize {
    const i = ref.toInterned() orelse return null;
    return switch (dg.ip.indexToKey(i)) {
        .int => |n| switch (n.storage) {
            .small => |v| if (v >= 0) @intCast(v) else null,
            .big => null, // past any table's size
        },
        else => null, // else: not an integer literal
    };
}

fn isInt(dg: *const DeclGen, i: usize) bool {
    const ty = dg.air.instructions.items(.data)[i].ty;
    return ty != InternPool.Index.real_type and !strings.isStrType(ty);
}

/// Whether held slot `i` is §3.3's string (an `Instance` field of its bytes).
fn isStr(dg: *const DeclGen, i: usize) bool {
    return strings.isStrType(dg.air.instructions.items(.data)[i].ty);
}

/// Writes held slot `i`'s field type: a scalar, or an array's `[n]` of them.
fn writeType(dg: *DeclGen, w: *std.Io.Writer, i: usize) DeclGen.Error!void {
    if (isStr(dg, i)) {
        if (arrayLen(dg, i) != null) return dg.fail("a held string array", .{});
        return w.print("K.str.ZStrHeldN({d})", .{try strings.capOf(dg, i)}) catch error.OutOfMemory;
    }
    if (arrayLen(dg, i)) |n| w.print("[{d}]", .{n}) catch return error.OutOfMemory;
    w.writeAll(if (isInt(dg, i)) "i64" else "f64") catch return error.OutOfMemory;
}

/// Writes held slot `i`'s initial value: `writeInit`'s, or an array's
/// elements (`@splat` when they agree, as they do without an initializer).
fn writeHeldInit(dg: *DeclGen, w: *std.Io.Writer, i: usize) DeclGen.Error!void {
    const n = arrayLen(dg, i) orelse return writeInit(dg, w, i);
    var first: std.Io.Writer.Allocating = .init(dg.arena);
    try writeInit(dg, &first.writer, i);
    var all: std.Io.Writer.Allocating = .init(dg.arena);
    var same = true;
    for (0..n) |e| {
        var one: std.Io.Writer.Allocating = .init(dg.arena);
        try writeInit(dg, &one.writer, i + e);
        same = same and std.mem.eql(u8, one.written(), first.written());
        all.writer.print("{s}{s}", .{ if (e == 0) "" else ", ", one.written() }) catch return error.OutOfMemory;
    }
    assert(n > 1);
    const r = if (same) w.print("@splat({s})", .{first.written()}) else w.print(".{{ {s} }}", .{all.written()});
    r catch return error.OutOfMemory;
}

/// Writes held slot `i`'s initial value: its row's initializer (an array's
/// element `k`), else the type's zero.
fn writeInit(dg: *DeclGen, w: *std.Io.Writer, i: usize) DeclGen.Error!void {
    const d = dg.device;
    const row, const k = for (d.held.items(.slot), d.held.items(.count), 0..) |slot, count, r| {
        const s = @backingInt(slot);
        if (i >= s and i < s + count) break .{ r, i - s };
    } else unreachable; // `plan` named only held slots
    var init = d.held.items(.init)[row];
    if (init != InternPool.Index.undef and init != .none) switch (dg.ip.indexToKey(init)) {
        .aggregate => |agg| init = if (k < agg.elems.len) agg.elems[k] else InternPool.Index.undef,
        else => {}, // else: one value for the scalar
    };
    const key = if (init == InternPool.Index.undef or init == .none) InternPool.Key{ .undef = .none } else dg.ip.indexToKey(init);
    if (isStr(dg, i)) {
        // §3.3 the initializer's bytes, "" without one.
        const text = switch (key) {
            .str => |t| dg.ip.stringToSlice(t),
            else => "", // else: no initializer
        };
        w.print("K.str.zStrHeldN({d}, \"", .{try strings.capOf(dg, i)}) catch return error.OutOfMemory;
        for (text) |c| if (c != 0) w.print("{f}", .{std.zig.fmtString(&.{c})}) catch return error.OutOfMemory;
        return w.writeAll("\")") catch error.OutOfMemory;
    }
    const r = switch (key) {
        .float => |x| if (isInt(dg, i)) w.print("{d}", .{@as(i64, @intFromFloat(@round(x)))}) else w.print("{f}", .{Real{ .x = x }}),
        .int => |n| if (n.storage == .small) (if (isInt(dg, i)) w.print("{d}", .{n.storage.small}) else w.print("{d}.0", .{n.storage.small})) else return dg.fail("a held initializer wider than 64 bits", .{}),
        else => w.writeAll(if (isInt(dg, i)) "0" else "0.0"), // else: no initializer, or one that does not fold
    };
    r catch return error.OutOfMemory;
    assert(i < dg.air.instructions.len);
}
