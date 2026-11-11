//! lib/sim/digital's constant expression (its `constness.zig`), judged on
//! Vir: an expression in, the first operand that keeps it from being a
//! constant out (a name that is no parameter or genvar, a user function
//! call, a system function that reads the clock, a file, a queue, a
//! distribution's state or a driver), or null when it is one.
//! A function a parameter's value calls is judged a §10.4.5 constant
//! function on its body (`constantCalls`).
//! Cites: IEEE 1364-2005 §5.2, §10.4.5, §12.2, §17.7.
//!
//! Contents:
//! - `pub const Offender = struct` (`Kind`)
//! - `pub fn offender(l: *Lower, vir: *const Vir, r: Inst.Ref, calls: bool) Error!?Offender`
//! - `pub fn readsSpecparam(l: *Lower, vir: *const Vir, r: Inst.Ref) Error!bool`
//! - `pub fn constantCalls(l: *Lower, f: u32, r: Inst.Ref) Error!void`

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

/// The most nested bodies a function's walk enters.
const depth_max = 4096;

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

/// IEEE 1364-2005 §10.4.5: every function call in `r` (of frame `f`), made
/// during elaboration, is a constant function's; else rejected at the call,
/// as lib/sim/digital's `earlyFrame` did.
pub fn constantCalls(l: *Lower, f: u32, r: Inst.Ref) Error!void {
    const vir = l.virOf(f);
    const root = r.toIndex() orelse return;
    var stack: std.ArrayList(Inst.Index) = .empty;
    var ops: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
    try stack.append(l.a, root);
    var steps: usize = 0;
    while (stack.pop()) |i| : (steps += 1) {
        assert(steps <= vir.instructions.len * 4);
        if (Lower.tag(vir, i) == .call) if (functionOf(vir, i)) |callee| {
            var seen: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
            if (try notConstant(l, vir, callee, &seen)) |why|
                return l.rejectFmt(f, i.toRef(), "§10.4.5: a function called during elaboration is a constant function, and {s}", .{why});
        };
        ops.clearRetainingCapacity();
        try operands(l.a, vir, i, &ops);
        var it = ops.keyIterator();
        while (it.next()) |o| try stack.append(l.a, o.*);
    }
}

// ---- private ----

/// The function (or task) declaration call `i` names directly, or null.
fn functionOf(vir: *const Vir, i: Inst.Index) ?Inst.Index {
    const ci = Lower.payload(vir, Inst.Call, i).callee.toIndex() orelse return null;
    if (Lower.tag(vir, ci) != .decl_ref) return null;
    const d = vir.instructions.items(.data)[@backingInt(ci)].decl_tok.decl;
    return if (Lower.tag(vir, d) == .function) d else null;
}

/// Why function `fd` is no §10.4.5 constant function, in lib/sim/digital's
/// words, or null when it is one: every name it reads is its own (a
/// formal, a local, its result) or a parameter, it holds no hierarchical
/// reference, every function it calls is a constant function, and no
/// system function it calls reads state. A function in `seen` (a
/// recursive call) counts as constant.
fn notConstant(l: *Lower, vir: *const Vir, fd: Inst.Index, seen: *std.AutoHashMapUnmanaged(Inst.Index, void)) Error!?[]const u8 {
    if ((try seen.getOrPut(l.a, fd)).found_existing) return null;
    const fp = Lower.payload(vir, Inst.Function, fd);
    if (fp.flags.task) return "it is a task";
    var own: std.ArrayList(Inst.Index) = .empty;
    try gather(l, vir, fp.formals, &own, 0);
    try gather(l, vir, fp.body, &own, 0);
    var mine: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
    var heads: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
    for (own.items) |i| {
        try mine.put(l.a, i, {});
        if (Lower.tag(vir, i) == .field) if (Lower.payload(vir, Inst.Field, i).operand.toIndex()) |o| try heads.put(l.a, o, {});
    }
    for (own.items) |i| switch (Lower.tag(vir, i)) {
        .field => return "it contains a hierarchical reference",
        .decl_ref => if (!heads.contains(i)) {
            const d = vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl;
            const c = canonical(vir, d);
            switch (Lower.tag(vir, c)) {
                .param, .genvar, .function => {},
                else => if (!mine.contains(d) and !mine.contains(c)) return "it reads a name that is neither its own nor a parameter", // else: a variable, net or event
            }
        },
        .str_ref => if (!heads.contains(i)) return "it reads a name that is neither its own nor a parameter",
        .call => {
            const callee = functionOf(vir, i) orelse return "it calls a function that is not a constant function";
            if (Lower.payload(vir, Inst.Function, callee).flags.task) return "it enables a task";
            if (try notConstant(l, vir, callee, seen) != null) return "it calls a function that is not a constant function";
        },
        .call_sys => {
            const name = vir.string(Lower.payload(vir, Inst.SysCall, i).name);
            for (not_constant) |n| if (std.mem.eql(u8, n, name)) return "it calls a system function no constant expression may";
        },
        else => {}, // else: an operator, literal or statement, judged by its operands
    };
    return null;
}

/// Appends every instruction of body `b` and of the bodies nested in it.
fn gather(l: *Lower, vir: *const Vir, b: Vir.Body, out: *std.ArrayList(Inst.Index), depth: u32) Error!void {
    if (depth >= depth_max) return l.refuse("statements nested past 4096 levels");
    for (vir.body(b)) |i| {
        try out.append(l.a, i);
        const data = vir.instructions.items(.data)[@backingInt(i)];
        switch (Lower.tag(vir, i)) {
            inline else => |t| if (comptime Inst.dataKind(t) == .pl_node) {
                const P = Inst.Payload(t);
                if (P != void) {
                    const p = vir.extraData(P, data.pl_node.payload_index);
                    inline for (@typeInfo(P).@"struct".field_names) |name| {
                        const F = @FieldType(P, name);
                        if (F == Vir.Body) {
                            try gather(l, vir, @field(p, name), out, depth + 1);
                        } else if (F == Vir.List(Inst.Arm)) for (vir.list(Inst.Arm, @field(p, name))) |arm| {
                            try gather(l, vir, arm.labels, out, depth + 1);
                            try gather(l, vir, arm.body, out, depth + 1);
                        };
                    }
                }
            },
        }
    }
}
