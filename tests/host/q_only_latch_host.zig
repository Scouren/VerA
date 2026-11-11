//! #134's oracle 2, a charge-only shape: a `$prev` path latch that feeds
//! ONLY a §5.6.1.2 charge (`ddt`) contribution, never a resistive (`I`) one
//! directly — the other half of `field_use.zig`'s own "a $prev path latch is
//! res/jac, w_commit only" unit test, which feeds the same `$prev(g)` latch
//! straight into `I()` instead. There is no `Q()` access function in
//! VerilogAMS; a charge contribution is spelled `I(...) <+ ddt(charge_expr)`
//! (`tests/conformance/tests/verilog-a/ch05_analog_behavior/batch_per_instance_state.va`'s
//! own `c * ddt(V(a, b))` term is the same idiom).
//!
//! The emitted field is still named `pb__0` ("path_prev latch") — VerA does
//! not rename it `pq__0` depending on where `$prev`'s result is consumed,
//! confirmed by generating this device and reading its `Instance`. `field_use`
//! (`field_taint.zig`'s per-output dataflow, #134's correction) reports it
//! `q = true, jac = true, res = false`: the latch is added beside `g` then
//! multiplied by `V(p, n)`, an unknown-dependent factor — the "mos2 shape"
//! (`field_use.zig`'s own "a latch multiplied by an x-dependent factor gets
//! jac" unit test is the same expression fed into `I()` directly instead of
//! `ddt()`) — so `jac` is earned on its own cross term, never inherited from
//! `res` (there IS no resistive term here at all: `res` is correctly clear).
//! What this fixture actually proves: before it, no `tests/host/` fixture
//! had a `q()` at all, so `checkClearBits`'s `has_q` branch was dead code in
//! every build. This gives it a real charge to call `D.q` against, and three
//! other `Instance` fields (`mfactor`, `bound_step`, `discontinuity_order`)
//! whose `q`-clear bit the oracle now actually checks against `D.q`, not
//! only `D.eval`.
//! device tests/host/q_only_latch.va

const std = @import("std");
const contract = @import("contract");
const D = @import("device");
const field_use_check = @import("field_use_check.zig");

const n_u = @typeInfo(D.U).@"enum".field_names.len;
const S = contract.RefFamily(f64, &@as([n_u]u8, @splat(contract.no_lane)), .{});

fn bias(vp: f64) [n_u]f64 {
    var x: [n_u]f64 = @splat(0.0);
    x[@backingInt(D.U.p)] = vp;
    return x;
}

/// `Instance`'s field index named `name`, or a compile error — this scan
/// mirrors `field_use.zig`'s own ("Instance's field order IS field_use's
/// index order"), so a renamed/reordered field fails loud, not silently
/// against the wrong index.
fn fieldIndex(comptime name: []const u8) usize {
    const names = @typeInfo(D.Instance).@"struct".field_names;
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    @compileError("Instance has no field '" ++ name ++ "'");
}

test "field_use (#134): a charge-only $prev latch (oracle 2, q bit)" {
    const model: D.Model = .{};
    var inst0: D.Instance = .{};
    _ = D.initState(&model, &inst0);
    const sim: contract.SimState = .{ .t = 1.0e-9, .dt = 1.0e-9, .kind = .tran };
    const x = bias(0.3);
    try field_use_check.checkClearBits(S, D, &x, &model, inst0, sim);
}

test "field_use (#134): the $prev latch is jac/q and w_commit — never res, the mos2 shape" {
    try std.testing.expect(@hasDecl(D, "q"));
    const uses = contract.fieldUse(D);
    try std.testing.expectEqual(4, uses.len);
    const pb0 = uses[comptime fieldIndex("pb__0")];
    try std.testing.expect(!pb0.res); // no resistive term reads it at all
    try std.testing.expect(pb0.jac); // earned on its own: `* V(p, n)`, an x-dependent factor
    try std.testing.expect(pb0.q);
    try std.testing.expect(!pb0.w_update);
    try std.testing.expect(pb0.w_commit);
}
