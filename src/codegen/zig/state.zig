//! §5.10 the held variables as the device's state: each held slot an
//! `Instance` field the body starts from (`Function` reads it into the
//! slot), `core` returns it, `updateState` writes it back at an accepted
//! point, and `State` keeps the last committed copy for `stateCtl`'s
//! revert (the old device's `held` protocol, `src/codegen/device/codegen/
//! state.zig`). Fields are named `<name>__held` (`__<k>` per element of a
//! held array); no host reads them by name.
//! Cites: VAMS-2023 §5.10 (variables keep their value between
//! evaluations), §3.2 (a declaration initializer), §8.2 (it runs once).
//!
//! Contents:
//! - `pub fn plan(dg: *DeclGen) DeclGen.Error!void`
//! - `pub fn genInstanceFields(dg: *DeclGen, w: *std.Io.Writer) DeclGen.Error!void`
//! - `pub fn genEntries(dg: *DeclGen, w: *std.Io.Writer) DeclGen.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Air = @import("air");
const InternPool = @import("intern_pool");
const DeclGen = @import("DeclGen.zig");
const Function = @import("Function.zig");
const Ident = @import("Ident.zig");
const Real = Function.Real;

/// Fills `dg.held_field`: per `alloc`, its `Instance` field when held.
pub fn plan(dg: *DeclGen) DeclGen.Error!void {
    const d = dg.device;
    dg.held_field = try dg.arena.alloc(?[]const u8, dg.air.instructions.len);
    @memset(dg.held_field, null);
    for (d.held.items(.name), d.held.items(.slot), d.held.items(.count)) |n, slot, count| {
        const name = dg.ip.stringToSlice(n);
        for (0..count) |k| {
            const i = @backingInt(slot) + k;
            if (i >= dg.air.instructions.len or dg.air.instructions.items(.tag)[i] != .alloc) return dg.fail("held variable `{s}`'s slots are not consecutive allocs", .{name});
            dg.held_field[i] = if (count == 1)
                try std.fmt.allocPrint(dg.arena, "{f}__held", .{Ident{ .name = name }})
            else
                try std.fmt.allocPrint(dg.arena, "{f}__held__{d}", .{ Ident{ .name = name }, k });
        }
    }
}

/// The held fields of `Instance`, each at its §3.2 initializer (0 without).
pub fn genInstanceFields(dg: *DeclGen, w: *std.Io.Writer) DeclGen.Error!void {
    for (dg.held_field, 0..) |field, i| if (field) |f| {
        w.print("    {s}: {s} = ", .{ f, typeName(dg, i) }) catch return error.OutOfMemory;
        try writeInit(dg, w, i);
        w.writeAll(",\n") catch return error.OutOfMemory;
    };
}

/// `State`, `initState`, `updateState`, `stateCtl` and `state_class` when
/// the device holds a variable.
pub fn genEntries(dg: *DeclGen, w: *std.Io.Writer) DeclGen.Error!void {
    var any = false;
    for (dg.held_field) |f| any = any or f != null;
    if (!any) return;
    const p = struct {
        fn f(out: *std.Io.Writer, comptime fmt: []const u8, args: anytype) DeclGen.Error!void {
            out.print(fmt, args) catch return error.OutOfMemory;
        }
    }.f;
    try p(w, "\n/// §5.10 the held values as last committed (`stateCtl`).\npub const State = struct {{\n", .{});
    for (dg.held_field, 0..) |field, i| if (field) |f| {
        try p(w, "    {s}: {s} = ", .{ f, typeName(dg, i) });
        try writeInit(dg, w, i);
        try p(w, ",\n", .{});
    };
    try p(w, "}};\n\n/// Every held value back to its initializer: the start of an analysis.\npub fn initState(_: *const Model, inst: *Instance) State {{\n", .{});
    for (dg.held_field, 0..) |field, i| if (field) |f| {
        try p(w, "    inst.{s} = ", .{f});
        try writeInit(dg, w, i);
        try p(w, ";\n", .{});
    };
    try p(w, "    return .{{}};\n}}\n\n/// §5.10 an accepted point: the body's held values become the instance's.\npub fn updateState(comptime S: type, model: *const Model, inst: *Instance, x: [n_u]f64, _: *State, sim: contract.SimState) contract.UpdateResult {{\n    const m = run(S, &x, D.zProbe(S, &x), model, inst, sim);\n", .{});
    for (dg.held_field, 0..) |field, i| if (field) |f| {
        try p(w, "    inst.{s} = m.h{d}{s};\n", .{ f, i, if (isInt(dg, i)) "" else ".val()" });
    };
    try p(w, "    return .ok;\n}}\n\n/// `commit` keeps the instance's held values; `revert` restores them.\npub fn stateCtl(_: *const Model, inst: *Instance, state: *State, op: contract.StateCtlOp) bool {{\n    switch (op) {{\n        .query => {{}},\n        .commit => {{\n", .{});
    for (dg.held_field) |field| if (field) |f| try p(w, "            state.{s} = inst.{s};\n", .{ f, f });
    try p(w, "        }},\n        .revert => {{\n", .{});
    for (dg.held_field) |field| if (field) |f| try p(w, "            inst.{s} = state.{s};\n", .{ f, f });
    try p(w, "        }},\n    }}\n    return false;\n}}\n\npub const state_class: contract.StateClass = .history;\n", .{});
}

// ---- private ----

fn isInt(dg: *const DeclGen, i: usize) bool {
    const ty = dg.air.instructions.items(.data)[i].ty;
    return ty != InternPool.Index.real_type;
}

fn typeName(dg: *const DeclGen, i: usize) []const u8 {
    return if (isInt(dg, i)) "i64" else "f64";
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
    const r = switch (key) {
        .float => |x| if (isInt(dg, i)) w.print("{d}", .{@as(i64, @intFromFloat(@round(x)))}) else w.print("{f}", .{Real{ .x = x }}),
        .int => |n| if (n.storage == .small) (if (isInt(dg, i)) w.print("{d}", .{n.storage.small}) else w.print("{d}.0", .{n.storage.small})) else return dg.fail("a held initializer wider than 64 bits", .{}),
        else => w.writeAll(if (isInt(dg, i)) "0" else "0.0"), // else: no initializer, or one that does not fold
    };
    r catch return error.OutOfMemory;
    assert(i < dg.air.instructions.len);
}
