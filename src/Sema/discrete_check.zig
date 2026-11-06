//! §7.2.2 the discrete context's rules (the old `analog/discrete_check.zig`,
//! in part): an instance's `initial`/`always` bodies in, a diagnostic out
//! for each analog construct written there: an analog operator (E0422,
//! §4.5.15 "can not be used inside an initial or always block"), a system
//! call whose §9.2 digital cell is No (E0821), `initial_step`/`final_step`
//! (E0708, §5.10). A monitored event there is §5.10.3's function, whose
//! "arguments ... are in the continuous context" (§7.3.5): its argument
//! rules hold (E0517), and a digital function called in its arguments is
//! called from the analog context (E0436, §7.3.7).
//! Cites: VAMS-2023 §4.5.15, §5.10, §5.10.3.1-§5.10.3.4, §7.2.2, §7.3.5,
//! §7.3.7, §9.2.
//!
//! Contents:
//! - `pub fn check(s: *Sema, unit: *Unit) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const control = @import("control.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const SysFn = vams.SysFn;
const Unit = Sema.Unit;

/// The deepest statement or expression nesting the walks follow.
const depth_max: u32 = 1 << 12;

/// Judges each `initial` and `always` body of `unit`'s module.
pub fn check(s: *Sema, unit: *Unit) Allocator.Error!void {
    const vir = unit.vir;
    // ponytail: a process inside a generate scope is not walked; walk the
    // generate bodies when a fixture puts an analog construct there.
    for (vir.body(unit.module.body)) |i| {
        const tag = vir.instructions.items(.tag)[@backingInt(i)];
        if (tag != .initial and tag != .always) continue;
        const where = if (tag == .always) "an always block" else "an initial block";
        try body(s, unit, decl.payloadOf(vir, Inst.Process, i).body, where, 0);
    }
}

// ---- private ----

fn body(s: *Sema, unit: *Unit, b: Vir.Body, where: []const u8, depth: u32) Allocator.Error!void {
    if (depth > depth_max) return;
    const vir = unit.vir;
    for (vir.body(b)) |i| {
        try inst(s, unit, i, where);
        // The statement's nested bodies.
        const data = vir.instructions.items(.data)[@backingInt(i)];
        switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            inline else => |t| if (comptime Inst.dataKind(t) == .pl_node) {
                const P = Inst.Payload(t);
                if (P == void) continue;
                const p = vir.extraData(P, data.pl_node.payload_index);
                inline for (@typeInfo(P).@"struct".field_names) |name| {
                    const F = @FieldType(P, name);
                    if (F == Vir.Body) try body(s, unit, @field(p, name), where, depth + 1);
                    if (F == Vir.List(Inst.Arm)) for (vir.list(Inst.Arm, @field(p, name))) |arm| try body(s, unit, arm.body, where, depth + 1);
                }
            },
        }
    }
}

fn inst(s: *Sema, unit: *Unit, i: Inst.Index, where: []const u8) Allocator.Error!void {
    const vir = unit.vir;
    const file = unit.file;
    switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .step_event => {
            const final = decl.payloadOf(vir, Inst.StepEvent, i).flags.final;
            try s.fail(.E0708, file, i.toRef(), "`{s}` in {s}, the digital context", .{ if (final) "final_step" else "initial_step", where });
        },
        .call_sys => {
            const c = decl.payloadOf(vir, Inst.SysCall, i);
            const name = vir.string(c.name);
            const args = vir.list(Inst.Ref, c.args);
            if (analogOnly(name)) try s.fail(.E0821, file, i.toRef(), "`{s}` in {s}", .{ name, where });
            if (std.mem.eql(u8, name, "absdelta")) {
                try absdelta(s, unit, args, i.toRef());
                for (args) |a| try digitalCalls(s, unit, a, 0);
                return;
            }
            const tag = SysFn.Tag.fromName(name) orelse return;
            switch (SysFn.get(tag).family) {
                .analog_op => try s.fail(.E0422, file, i.toRef(), "not allowed in {s}", .{where}),
                .event => if (tag == .cross or tag == .above or tag == .timer) {
                    _ = try control.eventArgs(s, unit, tag, args, i.toRef());
                    for (args) |a| try digitalCalls(s, unit, a, 0);
                },
                else => {}, // else: no rule of the discrete context
            }
        },
        else => {}, // else: no analog construct
    }
}

/// §9.2's digital column: the names whose "Supported in digital context"
/// cell is No (the old `isAnalogOnlySysFunc`).
fn analogOnly(name: []const u8) bool {
    const names = std.StaticStringMap(void).initComptime(.{
        .{"$debug"},          .{"$fdebug"},            .{"$fatal"},             .{"$warning"},
        .{"$error"},          .{"$info"},              .{"$simprobe"},          .{"$discontinuity"},
        .{"$limit"},          .{"$bound_step"},        .{"$vera_reject_step"},  .{"$param_given"},
        .{"$port_connected"}, .{"$analog_node_alias"}, .{"$analog_port_alias"},
    });
    return names.has(name);
}

/// §5.10.3.4 `absdelta(expr, delta [, time_tol [, expr_tol [, enable]]])`:
/// the two required slots, nothing past the enable, delta and both
/// tolerances non-negative and the enable integral where they fold (E0517).
fn absdelta(s: *Sema, unit: *Unit, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!void {
    const file = unit.file;
    for ([_][]const u8{ "expr", "delta" }, 0..) |slot, k| if (k >= args.len or args[k] == .none)
        return s.fail(.E0517, file, src, "`absdelta()` requires its {s} argument", .{slot});
    if (args.len > 5) return s.fail(.E0517, file, src, "`absdelta()` takes at most 5 arguments, got {d} (A.6.5)", .{args.len});
    if (args.len == 5 and args[4] == .none) return s.fail(.E0517, file, src, "`absdelta()` has a comma before its enable and no enable", .{});
    for ([_][]const u8{ "delta", "time_tol", "expr_tol" }, 1..) |slot, k| {
        if (k >= args.len or args[k] == .none) continue;
        const c = (try decl.foldRef(s, unit, args[k])) orelse continue;
        if (c != .str and c.asReal() < 0) try s.fail(.E0517, file, src, "`absdelta()` {s} shall be non-negative, got {d}", .{ slot, c.asReal() });
    }
    if (args.len == 5) if (try decl.foldRef(s, unit, args[4])) |c| {
        if (c != .str and c.asReal() != @round(c.asReal())) try s.fail(.E0517, file, src, "`absdelta()` enable shall evaluate to an integer, got {d}", .{c.asReal()});
    };
}

/// §7.3.7 "Digital functions cannot be called from within the analog
/// context": each call of one in the expression `r` (E0436).
fn digitalCalls(s: *Sema, unit: *Unit, r: Inst.Ref, depth: u32) Allocator.Error!void {
    if (depth > depth_max) return;
    const i = r.toIndex() orelse return;
    const vir = unit.vir;
    if (vir.instructions.items(.tag)[@backingInt(i)] == .call) {
        const callee = decl.payloadOf(vir, Inst.Call, i).callee.toIndex();
        if (callee) |ci| if (vir.instructions.items(.tag)[@backingInt(ci)] == .decl_ref) {
            const f = decl.canonical(vir, vir.instructions.items(.data)[@backingInt(ci)].decl_tok.decl);
            if (vir.instructions.items(.tag)[@backingInt(f)] == .function and !decl.payloadOf(vir, Inst.Function, f).flags.analog)
                try s.fail(.E0436, unit.file, r, "`{s}`", .{vir.string(decl.payloadOf(vir, Inst.Function, f).name)});
        };
    }
    var ops: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
    try control.operands(s, vir, i, &ops);
    var it = ops.keyIterator();
    while (it.next()) |o| try digitalCalls(s, unit, o.toRef(), depth + 1);
}
