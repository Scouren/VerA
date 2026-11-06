//! The walk's processes and drivers: each `initial` (flattened, then its
//! statements), the continuous assigns, net initializers, gates and
//! instances, and each `always` (header, event terms, targets, statements),
//! as the old emitter checked them (src/codegen/digital/rtlil_proc.zig,
//! rtlil_module.zig).
//! Cites: IEEE 1364-2005 §6.1, §7, §9, §12.1.
//!
//! Contents:
//! - `pub fn processRows`
//! - `pub fn stmtsOf`
//! - `pub fn operands`
//! - `pub fn flat`
//! - `pub fn blockRow`
//! - `pub fn leaves`
//! - `pub fn driverRows`
//! - `pub fn always`
//! - `pub fn terms`
//! - `pub fn targets`
//! - `pub fn stmts`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const decl = @import("../../../decl.zig");
const Walk = @import("../Walk.zig");
const sites = @import("../../sites.zig");
const Phase = sites.Phase;
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Ast = vams.Ast;
const max_depth = Walk.max_depth;
const last = Walk.last;
const forInit = Walk.forInit;
const literal = Walk.literal;
const isPull = Walk.isPull;
const isSwitch = Walk.isSwitch;

/// Each `initial` or `always` of the module, its ordinal the group.
pub fn processRows(w: *Walk, comptime which: Inst.Tag) Allocator.Error!void {
    w.group = 0;
    for (w.items.items) |i| if (w.tag(i) == which) {
        const body = try w.stmtsOf(w.payload(Inst.Process, i).body);
        if (which == .initial) {
            w.phase = .initial_flat;
            try w.flat(body, 0);
            w.phase = .initial_stmt;
            try w.leaves(body, 0);
        } else try w.always(i, body);
        w.group += 1;
    };
}

/// The statements of body `b`: Vir writes a statement's expressions
/// before it in the same body, so an instruction no other one in `b`
/// reads is a statement (a task enable among them).
pub fn stmtsOf(w: *Walk, b: Vir.Body) Allocator.Error![]const Inst.Index {
    const all = w.vir.body(b);
    var used: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
    for (all) |i| try w.operands(i, &used);
    var out: std.ArrayList(Inst.Index) = .empty;
    for (all) |i| if (!used.contains(i)) try out.append(w.a, i);
    return out.items;
}

/// Adds every instruction `i` reads to `used`.
pub fn operands(w: *Walk, i: Inst.Index, used: *std.AutoHashMapUnmanaged(Inst.Index, void)) Allocator.Error!void {
    var refs: [3]Inst.Ref = .{ .none, .none, .none };
    var list: []const Inst.Ref = &.{};
    const t = w.tag(i);
    switch (Inst.dataKind(t)) {
        .un_node => refs[0] = w.data(i).un_node.operand,
        .pl_node => switch (t) {
            .store, .store_nb, .contrib, .proc_assign, .force, .repeat_ctl, .add, .sub, .mul, .div, .mod, .pow, .shl, .shr, .ashl, .ashr, .lt, .gt, .lte, .gte, .eq, .neq, .case_eq, .case_neq, .bit_and, .bit_or, .bit_xor, .bit_xnor, .bool_and, .bool_or, .elem, .replicate, .pattern_repl, .event_or, .range, .pulse_limits => {
                const b = w.payload(Inst.Bin, i);
                refs = .{ b.lhs, b.rhs, .none };
            },
            .store_timed, .store_nb_timed => {
                const b = w.payload(Inst.Timed, i);
                refs = .{ b.lhs, b.rhs, b.timing };
            },
            .contrib_indirect, .ternary, .mintypmax, .slice, .slice_up, .slice_down => {
                const b = w.payload(Inst.Triple, i);
                refs = .{ b.a, b.b, b.c };
            },
            .field => refs[0] = w.payload(Inst.Field, i).operand,
            .call => {
                const c = w.payload(Inst.Call, i);
                refs[0] = c.callee;
                list = w.vir.list(Inst.Ref, c.args);
            },
            .call_sys => list = w.vir.list(Inst.Ref, w.payload(Inst.SysCall, i).args),
            .concat, .pattern => list = w.vir.list(Inst.Ref, w.payload(Inst.Refs, i)),
            .condbr => refs[0] = w.payload(Inst.CondBr, i).cond,
            .case => {
                const c = w.payload(Inst.Case, i);
                refs[0] = c.operand;
                for (w.vir.list(Inst.Arm, c.arms)) |arm| for (w.vir.list(Inst.Ref, arm.values)) |v| if (v.toIndex()) |x| try used.put(w.a, x, {});
            },
            .repeat => refs[0] = w.payload(Inst.Repeat, i).count,
            .delay => refs[0] = w.payload(Inst.Delay, i).value,
            .event_wait => refs[0] = w.payload(Inst.EventWait, i).event,
            else => {}, // else: reads no instruction of its body by reference
        },
        .str_tok, .decl_tok, .int, .float, .str => {},
    }
    for (refs) |r| if (r.toIndex()) |x| try used.put(w.a, x, {});
    for (list) |r| if (r.toIndex()) |x| try used.put(w.a, x, {});
}

/// An `initial`'s blocks, as the old `flatten` refuses them: one with
/// local declarations (E1255), then a fork (E1256), outermost first.
pub fn flat(w: *Walk, body: []const Inst.Index, depth: u32) Allocator.Error!void {
    if (depth > max_depth) return;
    for (body) |s| if (w.tag(s) == .block) {
        try w.blockRow(s);
        try w.flat(try w.stmtsOf(w.payload(Inst.Block, s).body), depth + 1);
    };
}

pub fn blockRow(w: *Walk, s: Inst.Index) Allocator.Error!void {
    const b = w.payload(Inst.Block, s);
    for (w.vir.body(b.body)) |x| switch (w.tag(x)) {
        .variable, .param => {
            try w.row(w.phase, .block_decls, w.at(s), "");
            break;
        },
        else => {}, // else: a statement or another declaration
    };
    if (b.flags.fork) try w.row(w.phase, .fork, w.at(s), "");
}

/// An `initial`'s leaf statements through its blocks: each must be a
/// constant assignment to a declared name (E1251 to E1254, E1224).
pub fn leaves(w: *Walk, body: []const Inst.Index, depth: u32) Allocator.Error!void {
    if (depth > max_depth) return;
    for (body, 0..) |s, k| switch (w.tag(s)) {
        .block => try w.leaves(try w.stmtsOf(w.payload(Inst.Block, s).body), depth + 1),
        .variable, .param, .event, .net, .genvar => {},
        .store, .store_nb => {
            if (forInit(w, body, k)) continue;
            const b = w.payload(Inst.Bin, s);
            const t = b.lhs.toIndex().?;
            if (w.tag(t) != .decl_ref and w.tag(t) != .str_ref) {
                try w.row(w.phase, .init_target, w.at(s), "");
            } else if (!w.known(t)) {
                try w.row(w.phase, .unknown_name, w.at(s), w.refName(t));
            } else if (!w.constant(b.rhs, true, 0)) {
                try w.row(w.phase, .init_value, w.at(s), "");
            }
        },
        .store_timed, .store_nb_timed, .proc_assign, .force, .deassign, .release => try w.row(w.phase, .init_timed, w.at(s), ""),
        else => try w.row(w.phase, .init_other, w.at(s), ""), // else: every other statement
    };
}

/// The continuous assigns, net initializers, gates and instances.
pub fn driverRows(w: *Walk) Allocator.Error!void {
    w.phase = .assign;
    for (w.items.items) |i| if (w.tag(i) == .assign) {
        const a = w.payload(Inst.Assign, i);
        try w.lvalue(last(w, a.lhs), false, 0);
        try w.expr(last(w, a.rhs), 0);
    };
    w.phase = .net_init;
    for (w.items.items) |i| if (w.tag(i) == .net) {
        const n = w.payload(Inst.Net, i);
        if (n.init.len != 0) try w.expr(last(w, n.init), 0);
    };
    w.phase = .gate;
    for (w.items.items) |i| if (w.tag(i) == .instance) {
        const inst = w.payload(Inst.Instance, i);
        const kw = w.string(inst.target);
        if (inst.flags.kind != .gate or isPull(kw) or isSwitch(kw)) continue;
        if (inst.range.len != 0) {
            try w.row(.gate, .gate_array, w.mainAt(i), "");
            continue;
        }
        const conns = w.vir.list(Inst.Arg, inst.conns);
        const outs: usize = if (std.mem.eql(u8, kw, "buf") or std.mem.eql(u8, kw, "not")) conns.len -| 1 else @min(conns.len, 1);
        for (conns, 0..) |c, k| {
            if (c.value.len == 0) continue;
            if (k < outs) try w.lvalue(last(w, c.value), false, 0) else try w.expr(last(w, c.value), 0);
        }
    };
    w.phase = .instance;
    for (w.items.items) |i| if (w.tag(i) == .instance) {
        const inst = w.payload(Inst.Instance, i);
        if (inst.flags.kind == .gate) continue;
        if (inst.range.len != 0) {
            try w.row(.instance, .instance_array, w.mainAt(i), "");
            continue;
        }
        const target = w.string(inst.target);
        for (w.vir.list(Inst.Arg, inst.params), 0..) |p, k| {
            const v = last(w, p.value).toIndex() orelse continue;
            if (p.name == .empty) if (w.counts.get(target)) |n| if (k >= n) {
                try w.row(.instance, .ordered_params, w.paramAt(i, k), target);
                break;
            };
            if (!w.constant(v.toRef(), false, 0)) {
                try w.row(.instance, .override_value, w.paramAt(i, k), "");
                break;
            }
        }
        for (w.vir.list(Inst.Arg, inst.conns)) |c| if (c.value.len != 0) try w.expr(last(w, c.value), 0);
    };
}

/// One `always`: its event control, the regs it writes, its body.
pub fn always(w: *Walk, i: Inst.Index, body: []const Inst.Index) Allocator.Error!void {
    w.phase = .always_head;
    const kw_at = w.mainAt(i);
    if (body.len != 1 or w.tag(body[0]) != .event_wait) {
        const delay = body.len != 0 and (w.tag(body[0]) == .delay or w.tag(body[0]) == .wait);
        return w.row(.always_head, if (delay) .not_event else .no_event, kw_at, "");
    }
    const ew = w.payload(Inst.EventWait, body[0]);
    w.phase = .always_event;
    var edges = false;
    var level = ew.event == .none;
    if (ew.event.toIndex()) |e| try w.terms(e, &edges, &level, 0);
    if (edges and level) try w.row(.always_mix, .mixed_edges, kw_at, "");
    w.phase = .always_target;
    try w.targets(try w.stmtsOf(ew.body), 0);
    w.phase = .always_stmt;
    try w.stmts(try w.stmtsOf(ew.body), 0);
}

pub fn terms(w: *Walk, e: Inst.Index, edges: *bool, level: *bool, depth: u32) Allocator.Error!void {
    if (depth > max_depth) return;
    switch (w.tag(e)) {
        .event_or => {
            const b = w.payload(Inst.Bin, e);
            if (b.lhs.toIndex()) |l| try w.terms(l, edges, level, depth + 1);
            if (b.rhs.toIndex()) |r| try w.terms(r, edges, level, depth + 1);
        },
        .posedge, .negedge => {
            edges.* = true;
            try w.expr(w.data(e).un_node.operand, 0);
        },
        else => level.* = true, // else: a level-sensitive term
    }
}

/// The old `assigned`: every target's name must be declared.
pub fn targets(w: *Walk, body: []const Inst.Index, depth: u32) Allocator.Error!void {
    if (depth > max_depth) return;
    for (body) |s| switch (w.tag(s)) {
        .store, .store_nb => {
            const base = w.lvalueBase(w.payload(Inst.Bin, s).lhs);
            if (base) |b| {
                if (!w.known(b)) try w.row(w.phase, .unknown_name, w.at(s), w.refName(b));
            } else if (w.tag(w.payload(Inst.Bin, s).lhs.toIndex().?) != .concat) try w.row(w.phase, .lvalue_no_base, w.at(s), "");
        },
        .block => try w.targets(try w.stmtsOf(w.payload(Inst.Block, s).body), depth + 1),
        .condbr => {
            const c = w.payload(Inst.CondBr, s);
            try w.targets(try w.stmtsOf(c.then), depth + 1);
            try w.targets(try w.stmtsOf(c.@"else"), depth + 1);
        },
        .case => for (w.vir.list(Inst.Arm, w.payload(Inst.Case, s).arms)) |arm| try w.targets(try w.stmtsOf(arm.body), depth + 1),
        else => {}, // else: refused or ignored by `stmts`
    };
}

/// An `always` body, as the old `stmt` walks it.
pub fn stmts(w: *Walk, body: []const Inst.Index, depth: u32) Allocator.Error!void {
    if (depth > max_depth) return;
    for (body, 0..) |s, k| switch (w.tag(s)) {
        .block => {
            try w.blockRow(s);
            try w.stmts(try w.stmtsOf(w.payload(Inst.Block, s).body), depth + 1);
        },
        .variable, .param, .event, .net, .genvar => {},
        .store, .store_nb => {
            if (forInit(w, body, k)) continue;
            const b = w.payload(Inst.Bin, s);
            try w.lvalue(b.lhs, true, 0);
            try w.expr(b.rhs, 0);
        },
        .store_timed, .store_nb_timed => try w.row(w.phase, .timed_assign, w.at(s), ""),
        .proc_assign, .force, .deassign, .release => try w.row(w.phase, .proc_continuous, w.at(s), ""),
        .condbr => {
            const c = w.payload(Inst.CondBr, s);
            try w.expr(c.cond, 0);
            try w.stmts(try w.stmtsOf(c.then), depth + 1);
            try w.stmts(try w.stmtsOf(c.@"else"), depth + 1);
        },
        .case => {
            const c = w.payload(Inst.Case, s);
            if (c.flags.kind != .case) {
                try w.row(w.phase, .case_xz, w.at(s), "");
                continue;
            }
            try w.expr(c.operand, 0);
            for (w.vir.list(Inst.Arm, c.arms)) |arm| {
                for (w.vir.list(Inst.Ref, arm.values)) |v| try w.expr(v, 0);
                try w.stmts(try w.stmtsOf(arm.body), depth + 1);
            }
        },
        .loop, .repeat => try w.row(w.phase, .loop, w.at(s), ""),
        .delay, .event_wait, .wait => try w.row(w.phase, .wait, w.at(s), ""),
        .trigger => try w.row(w.phase, .trigger, w.at(s), ""),
        .disable => try w.row(w.phase, .disable, w.at(s), ""),
        .ret, .brk, .cont => try w.row(w.phase, .jump, w.at(s), ""),
        .contrib, .contrib_indirect => try w.row(w.phase, .contribution, w.at(s), ""),
        else => {}, // else: a system or task enable, which synthesis drops
    };
}
