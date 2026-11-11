//! §7.2.2 the discrete context's rules (the old `analog/discrete_check.zig`,
//! in part): an instance's `initial`/`always` bodies in, a diagnostic out
//! for each analog construct written there: an analog operator (E0422,
//! §4.5.15 "can not be used inside an initial or always block"), an analog
//! function call (E0430, §4.7.3), a contribution (E0435, §7.3: "Write
//! operations ... are only allowed from the context of their domain"), a
//! system call whose §9.2 digital cell is No (E0821), `initial_step`/
//! `final_step` (E0708, §5.10), a procedural write to a net (E0482, A.6.2),
//! a probe outside an analog event function in an event control (E0484,
//! §8.5.1). A monitored event there is §5.10.3's function, whose
//! "arguments ... are in the continuous context" (§7.3.5): its argument
//! rules hold (E0517), and a digital function called in its arguments is
//! called from the analog context (E0436, §7.3.7). Then the analog blocks:
//! a variable the digital processes also assign (E0432, §7.2.2), and in an
//! `analog initial` block a read of one (E0431, §5.2.1).
//! Cites: VAMS-2023 §4.5.15, §4.7.3, §5.10, §5.10.3.1-§5.10.3.4, §7.2.2,
//! §7.3, §7.3.5, §7.3.7, §8.5.1, §9.2, A.6.2.
//!
//! Contents:
//! - `pub fn check(s: *Sema, unit: *Unit) Allocator.Error!void`
//! - private `Pass` (`item`, `decl.eachItem`'s visitor)

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const control = @import("control.zig");
const discrete = @import("discrete.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const SysFn = vams.SysFn;
const Unit = Sema.Unit;

/// The deepest statement or expression nesting the walks follow.
const depth_max: u32 = 1 << 12;

/// An instruction of a digital process, in context `where`.
const Digital = struct {
    where: []const u8,
    /// The variables an analog block assigns outside every event statement.
    free: *const Set,

    fn inst(d: Digital, s: *Sema, unit: *Unit, i: Inst.Index) Allocator.Error!void {
        const vir = unit.vir;
        const file = unit.file;
        const src = i.toRef();
        switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            .step_event => {
                const final = decl.payloadOf(vir, Inst.StepEvent, i).flags.final;
                try s.fail(.E0708, file, src, "`{s}` in {s}, the digital context", .{ if (final) "final_step" else "initial_step", d.where });
            },
            .call => if (function(vir, i)) |f| if (decl.payloadOf(vir, Inst.Function, f).flags.analog)
                try s.fail(.E0430, file, src, "`{s}`: an analog function shall only be called from an analog block or from another analog function", .{vir.string(decl.payloadOf(vir, Inst.Function, f).name)}),
            .contrib, .contrib_indirect => try s.fail(.E0435, file, src, "contributed from {s}", .{d.where}),
            // A.6.2: a blocking, nonblocking or procedural `assign`/`deassign`
            // writes a `variable_lvalue`; only `force`/`release` take a net.
            .store, .store_nb, .proc_assign => try netWrite(s, unit, decl.payloadOf(vir, Inst.Bin, i).lhs, src),
            .store_timed, .store_nb_timed => try netWrite(s, unit, decl.payloadOf(vir, Inst.Timed, i).lhs, src),
            .deassign => try netWrite(s, unit, vir.instructions.items(.data)[@backingInt(i)].un_node.operand, src),
            // §8.5.1 "A2D events must be analog event controlled statements".
            // §7.3.6.1 admits "analog variables that are only assigned values
            // in analog event statements"; any other changes as a probe does.
            .event_wait => if (try probeOutside(s, unit, decl.payloadOf(vir, Inst.EventWait, i).event, d.free, 0)) |p|
                try s.fail(.E0484, file, p, "a probe, or a variable the analog block assigns outside any event statement, in the event control of {s}", .{d.where}),
            .call_sys => {
                const c = decl.payloadOf(vir, Inst.SysCall, i);
                const name = vir.string(c.name);
                const args = vir.list(Inst.Ref, c.args);
                if (analogOnly(name)) try s.fail(.E0821, file, src, "`{s}` in {s}", .{ name, d.where });
                if (std.mem.eql(u8, name, "absdelta")) {
                    try absdelta(s, unit, args, src);
                    for (args) |a| try digitalCalls(s, unit, a, 0);
                    return;
                }
                const tag = SysFn.Tag.fromName(name) orelse return;
                switch (SysFn.get(tag).family) {
                    .analog_op => try s.fail(.E0422, file, src, "not allowed in {s}", .{d.where}),
                    .event => if (tag == .cross or tag == .above or tag == .timer) {
                        _ = try control.eventArgs(s, unit, tag, args, src);
                        for (args) |a| try digitalCalls(s, unit, a, 0);
                    },
                    else => {}, // else: no rule of the discrete context
                }
            },
            else => {}, // else: no analog construct
        }
    }
};

/// The variables an analog block assigns outside every event statement
/// (an event body is not entered).
const Free = struct {
    out: *Set,

    fn skips(_: Free, tag: Inst.Tag) bool {
        return tag == .event_wait;
    }

    fn inst(f: Free, s: *Sema, unit: *Unit, i: Inst.Index) Allocator.Error!void {
        const vir = unit.vir;
        const lhs = switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            .store, .store_nb => decl.payloadOf(vir, Inst.Bin, i).lhs,
            else => return, // else: assigns nothing
        };
        const d = discrete.base(vir, lhs) orelse return;
        if (vir.instructions.items(.tag)[@backingInt(d)] == .variable) try f.out.put(s.arena, d, {});
    }
};

const Set = std.AutoHashMapUnmanaged(Inst.Index, void);

/// One of `check`'s three passes over the module's items (generate
/// schemes unrolled by `decl.eachItem`): the analog blocks' free
/// variables, then the digital processes, then the analog blocks against
/// what those assign.
const Pass = struct {
    free: *Set,
    vars: *const Set,
    owned: *std.ArrayList(Inst.Index),
    phase: enum { free, digital, analog },

    pub fn item(p: Pass, s: *Sema, unit: *Unit, i: Inst.Index) Allocator.Error!void {
        const vir = unit.vir;
        const tag = vir.instructions.items(.tag)[@backingInt(i)];
        const b = switch (tag) {
            .analog, .analog_initial, .initial, .always => decl.payloadOf(vir, Inst.Process, i).body,
            else => return, // else: no process
        };
        const analog = tag == .analog or tag == .analog_initial;
        switch (p.phase) {
            .free => if (analog) try walk(s, unit, b, Free{ .out = p.free }, 0),
            .digital => if (!analog) {
                try walk(s, unit, b, Digital{ .where = if (tag == .always) "an always block" else "an initial block", .free = p.free }, 0);
                try discrete.writes(vir, b, p.owned, s.arena, 0);
            },
            .analog => if (analog) {
                try walk(s, unit, b, Analog{ .vars = p.vars }, 0);
                if (tag != .analog_initial) return;
                var targets: Set = .empty;
                try walk(s, unit, b, Targets{ .out = &targets }, 0);
                try walk(s, unit, b, Initial{ .vars = p.vars, .targets = &targets }, 0);
            },
        }
    }
};

/// The assignment targets of an analog block, by instruction.
const Targets = struct {
    out: *Set,

    fn inst(t: Targets, s: *Sema, unit: *Unit, i: Inst.Index) Allocator.Error!void {
        const vir = unit.vir;
        switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            .store, .store_nb => if (decl.payloadOf(vir, Inst.Bin, i).lhs.toIndex()) |l| try t.out.put(s.arena, l, {}),
            else => {}, // else: assigns nothing
        }
    }
};

/// §5.2.1 "digital values cannot be accessed from the analog initial block
/// as they have not yet been assigned": a read there of a variable in
/// `vars` the digital processes assign (E0431); `targets` are writes.
const Initial = struct {
    vars: *const Set,
    targets: *const Set,

    fn inst(n: Initial, s: *Sema, unit: *Unit, i: Inst.Index) Allocator.Error!void {
        const vir = unit.vir;
        if (vir.instructions.items(.tag)[@backingInt(i)] != .decl_ref or n.targets.contains(i)) return;
        const d = decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl);
        if (n.vars.contains(d)) try s.fail(.E0431, unit.file, i.toRef(), "`{s}` is assigned in the discrete context", .{vir.string(decl.nameOf(vir, d))});
    }
};

/// An instruction of an analog block, against the variables `vars` the
/// digital processes assign: §7.2.2 "It shall be an error to assign to a
/// given variable in both contexts" (E0432), through an assignment or an
/// analog function's `output`/`inout` actual.
const Analog = struct {
    vars: *const Set,

    fn inst(a: Analog, s: *Sema, unit: *Unit, i: Inst.Index) Allocator.Error!void {
        const vir = unit.vir;
        switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            .store, .store_nb => try a.write(s, unit, decl.payloadOf(vir, Inst.Bin, i).lhs),
            .call => if (function(vir, i)) |f| {
                const formals = vir.body(decl.payloadOf(vir, Inst.Function, f).formals);
                const args = vir.list(Inst.Ref, decl.payloadOf(vir, Inst.Call, i).args);
                for (formals[0..@min(formals.len, args.len)], args[0..@min(formals.len, args.len)]) |formal, arg| {
                    switch (decl.payloadOf(vir, Inst.Io, formal).flags.dir) {
                        .output, .inout => try a.write(s, unit, arg),
                        .none, .input => {},
                    }
                }
            },
            else => {}, // else: writes no variable
        }
    }

    fn write(a: Analog, s: *Sema, unit: *Unit, lhs: Inst.Ref) Allocator.Error!void {
        const d = discrete.base(unit.vir, lhs) orelse return;
        if (a.vars.contains(d)) try s.fail(.E0432, unit.file, lhs, "`{s}` is also assigned in the discrete context", .{unit.vir.string(decl.nameOf(unit.vir, d))});
    }
};

/// Judges each `initial` and `always` body of `unit`'s module, then each
/// analog block's writes against the variables those bodies assign.
pub fn check(s: *Sema, unit: *Unit) Allocator.Error!void {
    var env = try decl.envOf(s, unit);
    defer env.deinit();
    const top = unit.module.body;
    var free: Set = .empty;
    try decl.eachItem(s, unit, &env, top, Pass{ .free = &free, .vars = undefined, .owned = undefined, .phase = .free }, 0);
    var owned: std.ArrayList(Inst.Index) = .empty;
    try decl.eachItem(s, unit, &env, top, Pass{ .free = &free, .vars = undefined, .owned = &owned, .phase = .digital }, 0);
    var vars: Set = .empty;
    for (owned.items) |d| if (unit.vir.instructions.items(.tag)[@backingInt(d)] == .variable) try vars.put(s.arena, d, {});
    if (vars.count() == 0) return;
    try decl.eachItem(s, unit, &env, top, Pass{ .free = &free, .vars = &vars, .owned = &owned, .phase = .analog }, 0);
}

// ---- private ----

/// `body`'s instructions, and those of every body nested in one, each
/// handed to `v.inst` (a body under an instruction `v.skips` is not).
fn walk(s: *Sema, unit: *Unit, b: Vir.Body, v: anytype, depth: u32) Allocator.Error!void {
    if (depth > depth_max) return;
    const vir = unit.vir;
    for (vir.body(b)) |i| {
        try v.inst(s, unit, i);
        if (@hasDecl(@TypeOf(v), "skips") and v.skips(vir.instructions.items(.tag)[@backingInt(i)])) continue;
        const data = vir.instructions.items(.data)[@backingInt(i)];
        switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            inline else => |t| if (comptime Inst.dataKind(t) == .pl_node) {
                const P = Inst.Payload(t);
                if (P == void) continue;
                const p = vir.extraData(P, data.pl_node.payload_index);
                inline for (@typeInfo(P).@"struct".field_names) |name| {
                    const F = @FieldType(P, name);
                    if (F == Vir.Body) try walk(s, unit, @field(p, name), v, depth + 1);
                    if (F == Vir.List(Inst.Arm)) for (vir.list(Inst.Arm, @field(p, name))) |arm| try walk(s, unit, arm.body, v, depth + 1);
                }
            },
        }
    }
}

/// The function call `i` names, or null for none of the module's.
fn function(vir: *const Vir, i: Inst.Index) ?Inst.Index {
    const ci = decl.payloadOf(vir, Inst.Call, i).callee.toIndex() orelse return null;
    if (vir.instructions.items(.tag)[@backingInt(ci)] != .decl_ref) return null;
    const f = decl.canonical(vir, vir.instructions.items(.data)[@backingInt(ci)].decl_tok.decl);
    return if (vir.instructions.items(.tag)[@backingInt(f)] == .function) f else null;
}

/// E0482 when procedural assignment target `lhs` is a net.
fn netWrite(s: *Sema, unit: *Unit, lhs: Inst.Ref, src: Inst.Ref) Allocator.Error!void {
    const vir = unit.vir;
    const d = discrete.base(vir, lhs) orelse return;
    if (vir.instructions.items(.tag)[@backingInt(d)] != .net) return;
    try s.fail(.E0482, unit.file, src, "`{s}` is a net, and a procedural assignment writes a variable", .{vir.string(decl.nameOf(vir, d))});
}

/// The first branch or port probe, or read of a variable in `free`, in
/// event expression `r` that no analog event function (`cross`, `above`,
/// `timer`, `absdelta`) encloses, or null.
fn probeOutside(s: *Sema, unit: *Unit, r: Inst.Ref, free: *const Set, depth: u32) Allocator.Error!?Inst.Ref {
    if (depth > depth_max) return null;
    const i = r.toIndex() orelse return null;
    const vir = unit.vir;
    switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .call_sys => {
            const name = vir.string(decl.payloadOf(vir, Inst.SysCall, i).name);
            const event = for ([_][]const u8{ "cross", "above", "timer", "absdelta" }) |e| {
                if (std.mem.eql(u8, e, name)) break true;
            } else false;
            if (event) return null;
        },
        .call => if (try @import("access.zig").accessCall(s, unit, r) != null) return r,
        .port_branch => return r,
        .decl_ref => if (free.contains(decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl))) return r,
        else => {}, // else: searched through its operands
    }
    var ops: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
    try control.operands(s.arena, vir, i, &ops);
    var it = ops.keyIterator();
    while (it.next()) |o| if (try probeOutside(s, unit, o.toRef(), free, depth + 1)) |p| return p;
    return null;
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
    if (vir.instructions.items(.tag)[@backingInt(i)] == .call) if (function(vir, i)) |f| {
        if (!decl.payloadOf(vir, Inst.Function, f).flags.analog)
            try s.fail(.E0436, unit.file, r, "`{s}`", .{vir.string(decl.payloadOf(vir, Inst.Function, f).name)});
    };
    var ops: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
    try control.operands(s.arena, vir, i, &ops);
    var it = ops.keyIterator();
    while (it.next()) |o| try digitalCalls(s, unit, o.toRef(), depth + 1);
}
