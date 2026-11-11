//! #134's perturbation oracle (oracle 2), factored out so every
//! `*_host.zig` fixture with a runnable `eval`/`q` can call it instead of
//! repeating the loop: `field_use`'s contract is a superset
//! (`lib/contract/sim_state.zig`'s doc on `FieldUse`) — a CLEAR `res`/`q`
//! bit is the one a device's own arithmetic must never contradict. Named
//! before `field_use.zig`'s emitter: perturb every `Instance` field whose
//! `res` (`q`) bit this device reports clear, one at a time, off a baseline
//! `eval` (`q`), and the residual (charge) must come back byte-identical.
//! Nothing here recomputes `field_use`'s own scan — this calls `eval`/`q`
//! themselves, the independent oracle the emitter's doc names.
//!
//! Contents:
//! - `pub fn perturbable(comptime T: type) bool`
//! - `pub fn perturb(ptr: anytype) void`
//! - `pub fn checkClearBits(comptime S: type, comptime D: type, x: anytype, model: *const D.Model, inst0: D.Instance, sim: contract.SimState) !void`

const std = @import("std");
const contract = @import("contract");

/// Skipped: not a float/int/bool (or a fixed array of one) `eval`/`q` could
/// read as model data — `[]const u8`/`?*const contract.SystfHost`-style
/// host-owned handles carry no number a residual could depend on through
/// this device's own arithmetic.
pub fn perturbable(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float, .int, .bool => true,
        .array => |a| perturbable(a.child),
        else => false,
    };
}

/// Changes `ptr.*` to some other value of its own type — a fixed sentinel,
/// or its toggle when already at the sentinel (also covers `bool`, where
/// "toggle" is the only well-defined perturbation). The int branch toggles
/// 0/`maxInt(T)` instead of a fixed literal: a magic number like `12345`
/// does not fit every width a narrow Instance field is stated in (caught by
/// `tphist_host.zig` exercising a `u8` field — `12345` overflowed it).
pub fn perturb(ptr: anytype) void {
    const T = @TypeOf(ptr.*);
    switch (@typeInfo(T)) {
        .float => ptr.* = if (ptr.* == 12345.6789) 0.0 else 12345.6789,
        .int => ptr.* = if (ptr.* == 0) std.math.maxInt(T) else 0,
        .bool => ptr.* = !ptr.*,
        .array => for (ptr) |*e| perturb(e),
        else => unreachable,
    }
}

/// For every perturbable `Instance` field, off baseline `inst0`: if
/// `field_use[i].res` is clear, perturbing it must not move `D.eval`'s
/// result at `x`/`sim`; if `D` has a `q` and `field_use[i].q` is clear,
/// perturbing it must not move `D.q`'s result there either. `x` is whatever
/// `eval`/`q` take for their unknowns argument (a fixture's own `bias()`
/// result) — this does no biasing of its own, only the perturb-and-compare.
pub fn checkClearBits(comptime S: type, comptime D: type, x: anytype, model: *const D.Model, inst0: D.Instance, sim: contract.SimState) !void {
    const uses = contract.fieldUse(D);
    try std.testing.expectEqual(contract.nFields(D), uses.len);
    // A local `var`, not `&@as(D.Instance, inst0)`: a parameter is immutable,
    // so taking its address directly yields `*const Instance`, which a
    // `mutable_eval` device's `eval`/`q` (`InstancePtr = *Instance`) refuses.
    var base_inst = inst0;
    const base_eval = D.eval(S, x, model, &base_inst, sim);
    const has_q = @hasDecl(D, "q");
    base_inst = inst0;
    const base_q = if (comptime has_q) D.q(S, x, model, &base_inst, sim) else {};

    const info = @typeInfo(D.Instance).@"struct";
    inline for (info.field_names, info.field_types, 0..) |name, Ty, i| {
        if (comptime perturbable(Ty)) {
            var inst = inst0;
            perturb(&@field(inst, name));
            if (!uses[i].res) {
                const got = D.eval(S, x, model, &inst, sim);
                if (!std.mem.eql(u8, std.mem.asBytes(&base_eval), std.mem.asBytes(&got))) {
                    std.debug.print("field_use says Instance.{s}'s res bit is clear, but perturbing it moved eval's result\n", .{name});
                    return error.FieldUseUnderReportsRes;
                }
            }
            if (comptime has_q) {
                if (!uses[i].q) {
                    const got = D.q(S, x, model, &inst, sim);
                    if (!std.mem.eql(u8, std.mem.asBytes(&base_q), std.mem.asBytes(&got))) {
                        std.debug.print("field_use says Instance.{s}'s q bit is clear, but perturbing it moved q's result\n", .{name});
                        return error.FieldUseUnderReportsQ;
                    }
                }
            }
        }
    }
}
