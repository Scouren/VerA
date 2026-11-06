//! lib/sim/digital's constant expression (its `constness.zig`), judged on
//! Vir: an expression in, the first operand that keeps it from being a
//! constant out (a name that is no parameter or genvar, a user function
//! call, a system function that reads the clock, a file, a queue, a
//! distribution's state or a driver), or null when it is one.
//! Cites: IEEE 1364-2005 §5.2, §10.4.5, §12.2, §17.7.
//!
//! Contents:
//! - `pub const Offender = struct` (`Kind`)
//! - `pub fn offender(l: *Lower, vir: *const Vir, r: Inst.Ref, calls: bool) Error!?Offender`
//! - `pub fn readsSpecparam(l: *Lower, vir: *const Vir, r: Inst.Ref) Error!bool`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const digital = @import("../digital.zig");
const canonical = @import("../decl.zig").canonical;
const operands = @import("../control.zig").operands;
const Lower = digital.Lower;
const Error = digital.Error;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// What keeps an expression from being constant: `name`, a variable, net
/// or other non-parameter name (or an undeclared one); `call`, a function
/// call or a non-constant system function.
pub const Offender = struct {
    kind: Kind,
    inst: Inst.Index,

    pub const Kind = enum(u8) { name, call };
};

/// The system functions lib/sim/digital's `SysFn.constant` refuses: a clock
/// query, a plusarg, a file or queue operation, a distribution draw, a
/// driver query.
const not_constant = [_][]const u8{
    "$time",           "$stime",            "$realtime",        "$abstime",         "$test$plusargs",     "$value$plusargs",       "$q_full",
    "$fopen",          "$fgetc",            "$ungetc",          "$fgets",           "$fscanf",            "$fread",                "$ftell",
    "$fseek",          "$rewind",           "$feof",            "$ferror",          "$sscanf",            "$random",               "$dist_uniform",
    "$dist_normal",    "$dist_exponential", "$dist_poisson",    "$dist_chi_square", "$dist_t",            "$dist_erlang",          "$driver_count",
    "$receiver_count", "$driver_state",     "$driver_strength", "$driver_delay",    "$driver_next_state", "$driver_next_strength", "$driver_type",
};

/// The first operand of `r` (in `vir`) that is no constant, or null; a
/// user function call is one only with `calls` (elaboration's folding).
pub fn offender(l: *Lower, vir: *const Vir, r: Inst.Ref, calls: bool) Error!?Offender {
    const root = r.toIndex() orelse return null;
    var stack: std.ArrayList(Inst.Index) = .empty;
    var ops: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
    try stack.append(l.a, root);
    var steps: usize = 0;
    while (stack.pop()) |i| : (steps += 1) {
        assert(steps <= vir.instructions.len * 4);
        switch (Lower.tag(vir, i)) {
            .decl_ref => {
                const d = canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl);
                switch (Lower.tag(vir, d)) {
                    .param, .genvar, .function => continue,
                    else => return .{ .kind = .name, .inst = i }, // else: a variable, net, event or scope
                }
            },
            .str_ref => return .{ .kind = .name, .inst = i },
            // §10.4.5 a constant function call folds only at elaboration (`calls`).
            .call => if (!calls) return .{ .kind = .call, .inst = i },
            .call_sys => {
                const name = vir.string(Lower.payload(vir, Inst.SysCall, i).name);
                for (not_constant) |n| if (std.mem.eql(u8, n, name)) return .{ .kind = .call, .inst = i };
            },
            else => {}, // else: an operator or literal, judged by its operands
        }
        ops.clearRetainingCapacity();
        try operands(l.a, vir, i, &ops);
        var it = ops.keyIterator();
        while (it.next()) |o| try stack.append(l.a, o.*);
    }
    return null;
}

/// Whether `r` (in `vir`) reads a §4.10.3 specify parameter.
pub fn readsSpecparam(l: *Lower, vir: *const Vir, r: Inst.Ref) Error!bool {
    const root = r.toIndex() orelse return false;
    var stack: std.ArrayList(Inst.Index) = .empty;
    var ops: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
    try stack.append(l.a, root);
    var steps: usize = 0;
    while (stack.pop()) |i| : (steps += 1) {
        assert(steps <= vir.instructions.len * 4);
        if (Lower.tag(vir, i) == .decl_ref) {
            const d = canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl);
            if (Lower.tag(vir, d) == .param and Lower.payload(vir, Inst.Param, d).flags.kind == .specparam) return true;
            continue;
        }
        ops.clearRetainingCapacity();
        try operands(l.a, vir, i, &ops);
        var it = ops.keyIterator();
        while (it.next()) |o| try stack.append(l.a, o.*);
    }
    return false;
}
