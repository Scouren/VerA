//! The writes the held walk reads (held.zig): an assignment's left side
//! in, the variable it writes (and whether all of it) out; an analog
//! block in, every variable an `@(...)` body writes marked held (`event`,
//! §5.10) out, including one written only through a sys-call destination
//! or a user function's `output`/`inout` actual (`callWrites`); the
//! module's digital processes in, the analog variables they read and
//! never write out (`a2dReads`, §7.3.6.4).
//! Cites: VAMS-2023 §3.2.2, §4.7.2.3, §5.10, §7.3.6.4, §9.5, §9.12, §9.13;
//! IEEE 1364-2005 §17.6.
//!
//! Contents:
//! - `pub const Target = struct`
//! - `pub fn target(vir: *const Vir, r: Inst.Ref) ?Target`
//! - `pub fn eventWrites(s: *Sema, unit: *Unit, b: Vir.Body, in_event: bool, depth: u32) Allocator.Error!void`
//! - `pub fn a2dReads(s: *Sema, unit: *Unit) Allocator.Error![]const Inst.Index`

const std = @import("std");
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const held = @import("held.zig");
const func = @import("func.zig");
const control = @import("control.zig");
const discrete = @import("discrete.zig");
const domain = @import("digital/domain.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const SysFn = vams.SysFn;
const Unit = Sema.Unit;

/// The variable an assignment writes, and whether it writes all of it.
pub const Target = struct { var_: Inst.Index, whole: bool };

/// IEEE 1364-2005 §17.6 the queue tasks' output argument, by name: none of
/// these has a `SysFn.Tag` (they are `SysFn.foreign`, digital-only), so
/// `callWrites` cannot read their `Writes` row from the table.
const q_outputs = std.StaticStringMap(usize).initComptime(.{
    .{ "$q_initialize", 3 }, .{ "$q_remove", 1 }, .{ "$q_full", 1 }, .{ "$q_exam", 3 },
});

pub fn target(vir: *const Vir, r: Inst.Ref) ?Target {
    var at = r;
    var whole = true;
    for (0..held.depth_max) |_| {
        const i = at.toIndex() orelse return null;
        switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            .decl_ref => {
                const k = decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl);
                if (vir.instructions.items(.tag)[@backingInt(k)] != .variable) return null;
                return .{ .var_ = k, .whole = whole };
            },
            .elem, .slice, .slice_up, .slice_down => {
                whole = false;
                at = if (vir.instructions.items(.tag)[@backingInt(i)] == .elem) decl.payloadOf(vir, Inst.Bin, i).lhs else decl.payloadOf(vir, Inst.Triple, i).a;
            },
            else => return null, // else: no variable is written
        }
    }
    return null;
}

/// Every write inside an `@(...)` body is held (`event`): a plain
/// assignment's target, and (§9.5/§9.12/§9.13/§4.7.2.3) every write a call
/// anywhere in the statement makes (`callWrites`), direct or nested.
pub fn eventWrites(s: *Sema, unit: *Unit, b: Vir.Body, in_event: bool, depth: u32) Allocator.Error!void {
    if (depth > held.depth_max) return;
    const vir = unit.vir;
    for (vir.body(b)) |i| {
        const tag = vir.instructions.items(.tag)[@backingInt(i)];
        if (in_event) try markCallWrites(s, unit, i, tag);
        switch (tag) {
            .block => try eventWrites(s, unit, decl.payloadOf(vir, Inst.Block, i).body, in_event, depth + 1),
            .condbr => {
                const x = decl.payloadOf(vir, Inst.CondBr, i);
                try eventWrites(s, unit, x.then, in_event, depth + 1);
                try eventWrites(s, unit, x.@"else", in_event, depth + 1);
            },
            .case => for (vir.list(Inst.Arm, decl.payloadOf(vir, Inst.Case, i).arms)) |arm| try eventWrites(s, unit, arm.body, in_event, depth + 1),
            .loop => {
                const x = decl.payloadOf(vir, Inst.Loop, i);
                try eventWrites(s, unit, x.body, in_event, depth + 1);
                try eventWrites(s, unit, x.step, in_event, depth + 1);
            },
            .repeat => try eventWrites(s, unit, decl.payloadOf(vir, Inst.Repeat, i).body, in_event, depth + 1),
            .event_wait => try eventWrites(s, unit, decl.payloadOf(vir, Inst.EventWait, i).body, true, depth + 1),
            else => {}, // else: no other statement holds a body
        }
    }
}

/// §7.3.6.4 A2D: the module's variables a digital process (`initial`,
/// `always`, a continuous assignment's value) reads, minus every one any
/// of them also writes (`discrete.writes`, a nested call's destination,
/// an IEEE 1364 §17.6 `$q_*` output). The caller's arena.
pub fn a2dReads(s: *Sema, unit: *Unit) Allocator.Error![]const Inst.Index {
    const vir = unit.vir;
    var written: std.ArrayList(Inst.Index) = .empty;
    var read: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
    for (vir.body(unit.module.body)) |i| switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .initial, .always => {
            const b = decl.payloadOf(vir, Inst.Process, i).body;
            try discrete.writes(vir, b, &written, s.arena, 0);
            try callWriteDecls(s, unit, b, &written, 0);
            try domain.reads(s.arena, vir, b, &read);
        },
        .function => {
            const f = decl.payloadOf(vir, Inst.Function, i);
            if (f.flags.task) {
                try discrete.writes(vir, f.body, &written, s.arena, 0);
                try callWriteDecls(s, unit, f.body, &written, 0);
            }
        },
        .assign => try domain.reads(s.arena, vir, decl.payloadOf(vir, Inst.Assign, i).rhs, &read),
        else => {}, // else: not a digital process
    };
    var out: std.ArrayList(Inst.Index) = .empty;
    var it = read.keyIterator();
    while (it.next()) |d| {
        if (vir.instructions.items(.tag)[@backingInt(d.*)] != .variable) continue;
        if (std.mem.findScalar(Inst.Index, written.items, d.*) != null) continue;
        try out.append(s.arena, d.*);
    }
    return out.items;
}

// ---- private ----

/// Every write statement `i` makes directly or through a nested call,
/// marked `.event`.
fn markCallWrites(s: *Sema, unit: *Unit, i: Inst.Index, tag: Inst.Tag) Allocator.Error!void {
    const vir = unit.vir;
    var refs: std.ArrayList(Inst.Ref) = .empty;
    switch (tag) {
        .store, .store_nb => {
            const x = decl.payloadOf(vir, Inst.Bin, i);
            try refs.append(s.arena, x.lhs);
            try callWrites(s, vir, x.rhs, &refs, 0);
        },
        .contrib => {
            const x = decl.payloadOf(vir, Inst.Bin, i);
            try callWrites(s, vir, x.lhs, &refs, 0);
            try callWrites(s, vir, x.rhs, &refs, 0);
        },
        .contrib_indirect => {
            const x = decl.payloadOf(vir, Inst.Triple, i);
            try callWrites(s, vir, x.a, &refs, 0);
            try callWrites(s, vir, x.b, &refs, 0);
            try callWrites(s, vir, x.c, &refs, 0);
        },
        .call, .call_sys => try callWrites(s, vir, i.toRef(), &refs, 0),
        else => {}, // else: a declaration, a jump or a condition writes nothing
    }
    for (refs.items) |r| if (target(vir, r)) |t| try unit.held.put(s.arena, t.var_, .event);
}

/// Every write a call inside expression `r` makes (a §9.5/§9.12/§9.13
/// sys-call destination, or a §4.7.2.3 user function's `output`/`inout`
/// actual), appended to `out` as the actual's own ref (`target` resolves
/// it to the variable it names).
fn callWrites(s: *Sema, vir: *const Vir, r: Inst.Ref, out: *std.ArrayList(Inst.Ref), depth: u32) Allocator.Error!void {
    if (depth > held.depth_max) return;
    const i = r.toIndex() orelse return;
    switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .call_sys => {
            const c = decl.payloadOf(vir, Inst.SysCall, i);
            const name = vir.string(c.name);
            const args = vir.list(Inst.Ref, c.args);
            const writes: SysFn.Writes = if (SysFn.Tag.fromName(name)) |t| SysFn.get(t).writes else .{};
            const q_out = q_outputs.get(name);
            for (args, 0..) |a, k| {
                if (writes.has(k) or (q_out != null and q_out.? == k)) try out.append(s.arena, a);
                try callWrites(s, vir, a, out, depth + 1);
            }
        },
        .call => if (func.calleeOf(vir, i)) |f| {
            const formals = vir.body(decl.payloadOf(vir, Inst.Function, f).formals);
            const args = vir.list(Inst.Ref, decl.payloadOf(vir, Inst.Call, i).args);
            const n = @min(formals.len, args.len);
            for (formals[0..n], args[0..n]) |formal, a| {
                const dir = decl.payloadOf(vir, Inst.Io, formal).flags.dir;
                if (dir == .output or dir == .inout) try out.append(s.arena, a);
                try callWrites(s, vir, a, out, depth + 1);
            }
        },
        else => {
            var ops: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
            try control.operands(s.arena, vir, i, &ops);
            var it = ops.keyIterator();
            while (it.next()) |o| try callWrites(s, vir, o.toRef(), out, depth + 1);
        },
    }
}

/// Every declaration a call writes anywhere in body `b`, recursively
/// through its control structures (`discrete.writes`' shape): a plain
/// assignment's own target is `discrete.writes`' job, not this one's.
fn callWriteDecls(s: *Sema, unit: *Unit, b: Vir.Body, out: *std.ArrayList(Inst.Index), depth: u32) Allocator.Error!void {
    if (depth > held.depth_max) return;
    const vir = unit.vir;
    for (vir.body(b)) |i| {
        const tag = vir.instructions.items(.tag)[@backingInt(i)];
        var refs: std.ArrayList(Inst.Ref) = .empty;
        switch (tag) {
            .store, .store_nb => try callWrites(s, vir, decl.payloadOf(vir, Inst.Bin, i).rhs, &refs, 0),
            .contrib => {
                const x = decl.payloadOf(vir, Inst.Bin, i);
                try callWrites(s, vir, x.lhs, &refs, 0);
                try callWrites(s, vir, x.rhs, &refs, 0);
            },
            .contrib_indirect => {
                const x = decl.payloadOf(vir, Inst.Triple, i);
                try callWrites(s, vir, x.a, &refs, 0);
                try callWrites(s, vir, x.b, &refs, 0);
                try callWrites(s, vir, x.c, &refs, 0);
            },
            .call, .call_sys => try callWrites(s, vir, i.toRef(), &refs, 0),
            else => {}, // else: no calls of its own (its bodies, below)
        }
        for (refs.items) |r| if (target(vir, r)) |t| try out.append(s.arena, t.var_);
        switch (tag) {
            .block => try callWriteDecls(s, unit, decl.payloadOf(vir, Inst.Block, i).body, out, depth + 1),
            .condbr => {
                const x = decl.payloadOf(vir, Inst.CondBr, i);
                try callWriteDecls(s, unit, x.then, out, depth + 1);
                try callWriteDecls(s, unit, x.@"else", out, depth + 1);
            },
            .case => for (vir.list(Inst.Arm, decl.payloadOf(vir, Inst.Case, i).arms)) |arm| try callWriteDecls(s, unit, arm.body, out, depth + 1),
            .loop => {
                const x = decl.payloadOf(vir, Inst.Loop, i);
                try callWriteDecls(s, unit, x.body, out, depth + 1);
                try callWriteDecls(s, unit, x.step, out, depth + 1);
            },
            .repeat => try callWriteDecls(s, unit, decl.payloadOf(vir, Inst.Repeat, i).body, out, depth + 1),
            .event_wait => try callWriteDecls(s, unit, decl.payloadOf(vir, Inst.EventWait, i).body, out, depth + 1),
            else => {}, // else: no nested body
        }
    }
}
