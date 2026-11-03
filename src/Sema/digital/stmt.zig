//! Statements of the digital lowering: every recorded process (and each
//! §6.2.1 variable declaration assignment), in its frame, -> `Program.insts`
//! rows, then the §11.4 time-0 queue (`Program.starts`) and the
//! continuous fan-out. Control flow is branches and jumps patched once
//! their targets exist; a named block records its pc range for `%m` and
//! `disable` (`Program.blocks`).
//! Cites: IEEE 1364-2005 §6.2.1, §9.2-§9.9, §11.4, §12.5.
//!
//! Contents:
//! - `pub fn compileAll(l: *Lower) Error!void`
//! - `pub fn compileStmt(l: *Lower, i: Inst.Index, depth: u32) Error!void`
//! - `pub fn body(l: *Lower, b: Vir.Body, depth: u32) Error!void`
//! - `pub fn isStatement(tg: Inst.Tag) bool`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const std_sim = @import("std_sim");
const digital = @import("../digital.zig");
const expr = @import("expr.zig");
const place = @import("place.zig");
const task = @import("task.zig");
const decl = @import("decl.zig");
const vars = @import("vars.zig");
const nets = @import("nets.zig");
const sub = @import("sub.zig");
const gates = @import("gates.zig");
const link = @import("link.zig");
const tchk = @import("tchk.zig");
const vcd = @import("vcd.zig");
const sdf = @import("sdf.zig");
const holds = @import("holds.zig");
const order_ = @import("order.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const Type = digital.Type;
const Proc = digital.Proc;
const none = digital.none;
const Program = std_sim.Program;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// The deepest statement nest lowered; deeper is refused by name.
const depth_max: u32 = 1 << 12;

/// Compiles every process in §9.9's order (the scope tree depth first, each
/// scope's children before its own processes, each scope's variable
/// initializers before its processes), queues each at time 0 (the
/// level-sensitive `always` ones first, as iverilog does), and builds the
/// fan-out.
pub fn compileAll(l: *Lower) Error!void {
    var early: std.ArrayList(u32) = .empty;
    var queued: std.ArrayList(u32) = .empty;
    try nets.compileDrivers(l);
    try gates.compileTrans(l);
    try sub.compileBodies(l);
    const order = try order_.processOrder(l);
    for (order) |s| {
        const procs = l.scopes.items[s].procs.items;
        for ([_]bool{ true, false }) |inits| for (procs) |p| {
            if ((p.kind == .init_var) != inits) continue;
            const start = try process(l, p);
            if (p.kind == .always and try order_.levelControlled(l, p)) try early.append(l.a, start) else try queued.append(l.a, start);
        };
    }
    for (l.term_starts.items) |at| try l.b.starts.append(l.a, .{ .pc = at });
    for (early.items) |at| try l.b.starts.append(l.a, .{ .pc = at });
    for (l.driver_pcs.items) |at| try l.b.starts.append(l.a, .{ .pc = at });
    var switches: usize = 0;
    for (l.trans.items) |t| if (t.pc != none) {
        try l.b.starts.append(l.a, .{ .pc = t.pc });
        switches += 1;
    };
    for (queued.items) |at| try l.b.starts.append(l.a, .{ .pc = at });
    try link.fanout(l);
    try link.resolveDisables(l);
    try tchk.finish(l);
    try vcd.catalog(l);
    try sdf.scopes(l);
    try sub.finish(l);
    l.b.p.counters = l.repeats + l.joins;
    l.b.p.holds = l.holds;
    assert(l.b.starts.items.len == l.term_starts.items.len + early.items.len + l.driver_pcs.items.len + switches + queued.items.len);
}

/// Appends statement `i`'s instructions, compiled in `Lower.frame`.
pub fn compileStmt(l: *Lower, i: Inst.Index, depth: u32) Error!void {
    if (depth >= depth_max) return l.refuse("statements nested past 4096 levels");
    const vir = l.virOf(l.frame);
    const scope = l.frames.items[l.frame].scope;
    const tg = Lower.tag(vir, i);
    switch (tg) {
        .block => try block(l, i, depth),
        .condbr => {
            const c = Lower.payload(vir, Inst.CondBr, i);
            const test_pc = try l.b.inst(.branch, try expr.selfOrReal(l, c.cond), 0, scope);
            try body(l, c.then, depth + 1);
            if (c.@"else".len == 0) {
                patch(l, test_pc, pc(l));
            } else {
                const end_pc = try l.b.inst(.jump, 0, 0, scope);
                patch(l, test_pc, pc(l));
                try body(l, c.@"else", depth + 1);
                patch(l, end_pc, pc(l));
            }
        },
        .loop => {
            const lp = Lower.payload(vir, Inst.Loop, i);
            if (lp.cond.len == 0) {
                // `forever`.
                const start = pc(l);
                try body(l, lp.body, depth + 1);
                _ = try l.b.inst(.jump, start, 0, scope);
                return;
            }
            const cond = vir.body(lp.cond);
            const test_pc = try l.b.inst(.branch, try expr.selfOrReal(l, cond[cond.len - 1].toRef()), 0, scope);
            try body(l, lp.body, depth + 1);
            try body(l, lp.step, depth + 1);
            _ = try l.b.inst(.jump, test_pc, 0, scope);
            patch(l, test_pc, pc(l));
        },
        .repeat => {
            const rp = Lower.payload(vir, Inst.Repeat, i);
            const counter = counterCell(l, .repeat);
            const start = try l.b.inst(.repeat_start, try expr.self_(l, rp.count, 0), 0, scope);
            const body_pc = pc(l);
            try body(l, rp.body, depth + 1);
            _ = try l.b.inst(.repeat_next, counter, body_pc, scope);
            l.b.setInst(start, .repeat_start, l.b.p.insts.items(.data)[start].a, try l.b.extraOf(Program.Repeat{ .counter = counter, .end = pc(l) }));
        },
        .delay => {
            const d = Lower.payload(vir, Inst.Delay, i);
            _ = try l.b.inst(.delay, try expr.selfOrReal(l, d.value), 0, scope);
            try body(l, d.body, depth + 1);
        },
        .event_wait => {
            const e = Lower.payload(vir, Inst.EventWait, i);
            var terms: std.ArrayList(u32) = .empty;
            if (e.event == .none) {
                // §9.7.5 `@*`: every slot the statement reads.
                var slots: std.ArrayList(u32) = .empty;
                try bodyReads(l, e.body, &slots);
                for (slots.items) |s| try terms.appendSlice(l.a, &.{ s, @backingInt(Program.Edge.any), 0, 0, none });
            } else try place.terms(l, e.event, &terms);
            _ = try l.b.inst(.wait_event, try l.b.extraOf(.{ .l = try l.b.listOf(terms.items) }), 0, scope);
            try body(l, e.body, depth + 1);
        },
        .wait => {
            const wt = Lower.payload(vir, Inst.Wait, i);
            const cond = vir.body(wt.cond);
            const c = cond[cond.len - 1].toRef();
            var slots: std.ArrayList(u32) = .empty;
            try expr.reads(l, c, &slots);
            _ = try l.b.inst(.wait_level, try expr.selfOrReal(l, c), try l.b.extraOf(.{ .l = try l.b.listOf(slots.items) }), scope);
            try body(l, wt.body, depth + 1);
        },
        .store, .store_nb => {
            const s = Lower.payload(vir, Inst.Bin, i);
            const target = try place.targetType(l, s.lhs);
            _ = try l.b.inst(if (tg == .store) .assign else .assign_nb, try place.place(l, s.lhs), try expr.evalFor(l, s.rhs, target), scope);
        },
        .trigger => {
            const r = vir.instructions.items(.data)[@backingInt(i)].un_node.operand;
            // §9.7.3 an element of an event array, chosen when it runs.
            if (r.toIndex()) |ri| if (Lower.tag(vir, ri) == .elem) {
                const s = try place.selectOf(l, ri);
                if (s.name.kind != .event or !s.whole_elem) return l.refuse("§5.10.4 `->` of a variable or net");
                _ = try l.b.inst(.trigger_elem, try place.elemRow(l, s), 0, scope);
                return;
            };
            const n = (try expr.nameOf(l, r)) orelse return l.refuse("a trigger of no named event");
            if (n.kind != .event) return l.refuse("§5.10.4 `->` of a variable or net");
            _ = try l.b.inst(.trigger, n.slot, 0, scope);
        },
        .call_sys => try task.task(l, i),
        .call => try sub.enable(l, i, depth),
        .store_timed, .store_nb_timed => try timedStore(l, i, depth),
        .case => try caseStmt(l, i, depth),
        .proc_assign, .force, .deassign, .release => try holds.statement(l, i),
        .disable => {
            // A.6.5 resolved once every block is compiled (`link.resolveDisables`).
            const r = vir.instructions.items(.data)[@backingInt(i)].un_node.operand;
            const ri = r.toIndex() orelse return l.refuse("a disable of nothing");
            const name = switch (Lower.tag(vir, ri)) {
                .str_ref => vir.string(vir.instructions.items(.data)[@backingInt(ri)].str_tok.start),
                .decl_ref => blk: {
                    const d = vir.instructions.items(.data)[@backingInt(ri)].decl_tok.decl;
                    break :blk switch (Lower.tag(vir, d)) {
                        .block => vir.string(Lower.payload(vir, Inst.Block, d).name),
                        .function => vir.string(Lower.payload(vir, Inst.Function, d).name),
                        else => return l.refuse("a disable of no block or task"),
                    };
                },
                else => return l.refuse("a disable of a hierarchical name"),
            };
            const at = try l.b.inst(.disable_block, 0, 0, scope);
            try l.disables.append(l.a, .{ .pc = at, .frame = l.frame, .name = name });
        },
        .ret, .brk, .cont => return l.refuse("return, break or continue"),
        .variable, .param, .event => {},
        else => {}, // else: an expression instruction, reached from the statement that reads it
    }
}

/// Appends the statements of body `b` (its expression instructions are
/// reached from the statements that read them; a `call_sys` no later
/// instruction reads is a task enable).
pub fn body(l: *Lower, b: Vir.Body, depth: u32) Error!void {
    for (try statements(l, b)) |i| try compileStmt(l, i, depth);
}

pub fn isStatement(tg: Inst.Tag) bool {
    return switch (tg) {
        .block, .condbr, .case, .loop, .repeat, .wait, .delay, .event_wait, .store, .store_nb, .proc_assign, .force, .store_timed, .store_nb_timed, .deassign, .release, .trigger, .disable, .ret, .brk, .cont, .call_sys, .call, .contrib, .contrib_indirect => true,
        else => false, // else: a declaration or an expression
    };
}

// ---- private ----

fn pc(l: *Lower) u32 {
    return @intCast(l.b.p.insts.len);
}

/// Points branch or jump `at` at `target`.
fn patch(l: *Lower, at: u32, target: u32) void {
    const row = l.b.p.insts.get(at);
    switch (row.tag) {
        .branch => l.b.setInst(at, .branch, row.data.a, target),
        .jump => l.b.setInst(at, .jump, target, 0),
        else => unreachable, // else: only a branch or jump is patched
    }
}

/// §8.5.3.3/§8.5.3.4 an assignment with an intra-assignment timing control,
/// as lib/sim/digital compiles it: its value sampled into a hold cell now,
/// then by its control: a blocking `#d` or plain `@e` suspends in the
/// `sample` itself, a nonblocking `#d` schedules the update and falls
/// through, and an `@*`, a `repeat (n) @e` or any nonblocking event control
/// waits after the sample (a nonblocking one in a process of its own) and
/// then deposits the held value.
fn timedStore(l: *Lower, i: Inst.Index, depth: u32) Error!void {
    const vir = l.virOf(l.frame);
    const scope = l.frames.items[l.frame].scope;
    const t = Lower.payload(vir, Inst.Timed, i);
    const nb = Lower.tag(vir, i) == .store_nb_timed;
    const ti = t.timing.toIndex() orelse return l.refuse("an intra-assignment timing control of nothing");
    var delay: Inst.Ref = .none;
    var event: Inst.Ref = .none;
    var count: Inst.Ref = .none;
    switch (Lower.tag(vir, ti)) {
        .delay_ctl => delay = vir.instructions.items(.data)[@backingInt(ti)].un_node.operand,
        .event_ctl => event = vir.instructions.items(.data)[@backingInt(ti)].un_node.operand,
        .repeat_ctl => {
            const b = Lower.payload(vir, Inst.Bin, ti);
            count = b.lhs;
            event = b.rhs;
            if (event.toIndex()) |e| if (Lower.tag(vir, e) == .event_ctl) {
                event = vir.instructions.items(.data)[@backingInt(e)].un_node.operand;
            };
        },
        else => return l.refuse("an intra-assignment timing control of another form"),
    }
    const is_delay = delay != .none;
    const parks_only = !is_delay and (nb or count != .none or event == .none);
    const hold = l.holds;
    l.holds += 1;
    var sm: Program.Sample = .{ .hold = hold, .value = try expr.evalFor(l, t.rhs, try place.targetType(l, t.lhs)), .mode = .park, .place = 0, .timing = 0, .terms = .empty };
    if (!parks_only) {
        if (nb) {
            sm.place = try place.place(l, t.lhs);
            sm.mode = .nba_delay;
            sm.timing = try expr.selfOrReal(l, delay);
        } else if (is_delay) {
            sm.mode = .delay;
            sm.timing = try expr.selfOrReal(l, delay);
        } else {
            sm.mode = .event;
            var terms: std.ArrayList(u32) = .empty;
            try place.terms(l, event, &terms);
            sm.terms = try l.b.listOf(terms.items);
        }
    }
    _ = try l.b.inst(.sample, try l.b.extraOf(sm), 0, scope);
    if (nb and is_delay) return;
    if (!parks_only) {
        _ = try l.b.inst(.deposit, hold, try place.place(l, t.lhs), scope);
        return;
    }
    // A nonblocking one waits in a process of its own, run nested now.
    var skip: u32 = none;
    if (nb) {
        _ = try l.b.inst(.spawn, pc(l) + 2, 1, scope);
        skip = try l.b.inst(.jump, 0, 0, scope);
    }
    if (count != .none) {
        const counter = counterCell(l, .repeat);
        const start = try l.b.inst(.repeat_start, try expr.self_(l, count, 0), 0, scope);
        const body_pc = pc(l);
        try waitIntra(l, event, t.rhs, t.lhs);
        _ = try l.b.inst(.repeat_next, counter, body_pc, scope);
        l.b.setInst(start, .repeat_start, l.b.p.insts.items(.data)[start].a, try l.b.extraOf(Program.Repeat{ .counter = counter, .end = pc(l) }));
    } else try waitIntra(l, event, t.rhs, t.lhs);
    _ = try l.b.inst(if (nb) .deposit_nb else .deposit, hold, try place.place(l, t.lhs), scope);
    if (nb) {
        _ = try l.b.inst(.stop, 0, 0, scope);
        patch(l, skip, pc(l));
    }
    assert(depth < depth_max);
}

/// An intra-assignment event control's wait: on `event`, or for `@*` on
/// every slot the assigned value and the target's indices read.
fn waitIntra(l: *Lower, event: Inst.Ref, value: Inst.Ref, target: Inst.Ref) Error!void {
    const scope = l.frames.items[l.frame].scope;
    var terms: std.ArrayList(u32) = .empty;
    if (event == .none) {
        var slots: std.ArrayList(u32) = .empty;
        try expr.reads(l, value, &slots);
        try indexReads(l, target, &slots);
        for (slots.items) |s| try terms.appendSlice(l.a, &.{ s, @backingInt(Program.Edge.any), 0, 0, none });
    } else try place.terms(l, event, &terms);
    _ = try l.b.inst(.wait_event, try l.b.extraOf(.{ .l = try l.b.listOf(terms.items) }), 0, scope);
}

/// §9.5 a case statement, as lib/sim/digital compiles it: one
/// `case_select` over the scrutinee and labels in their common type, each
/// arm at a pc of its own ending in a jump past the last, the default arm
/// (else the end) the fallback.
fn caseStmt(l: *Lower, i: Inst.Index, depth: u32) Error!void {
    const vir = l.virOf(l.frame);
    const scope = l.frames.items[l.frame].scope;
    const c = Lower.payload(vir, Inst.Case, i);
    const arms = vir.list(Inst.Arm, c.arms);
    if (arms.len == 0) return l.refuse("§9.5 a case statement with no item");
    var ty = try expr.typeValue(l, c.operand);
    for (arms) |arm| for (vir.list(Inst.Ref, arm.values)) |v| {
        ty = expr.common(ty, try expr.typeValue(l, v));
    };
    const scrutinee = try expr.ctx(l, c.operand, ty);
    var rows: std.ArrayList(u32) = .empty;
    for (arms) |arm| {
        var labels: std.ArrayList(u32) = .empty;
        for (vir.list(Inst.Ref, arm.values)) |v| try labels.append(l.a, try expr.ctx(l, v, ty));
        try rows.append(l.a, (try l.b.listOf(labels.items)).start);
        try rows.append(l.a, @intCast(labels.items.len));
    }
    const dispatch = try l.b.inst(.case_select, 0, 0, scope);
    const targets = try l.a.alloc(u32, arms.len);
    const exits = try l.a.alloc(u32, arms.len);
    var fallback: u32 = none;
    for (arms, targets, exits) |arm, *t, *e| {
        t.* = pc(l);
        if (arm.flags.default or arm.values.len == 0) fallback = pc(l);
        try body(l, arm.body, depth + 1);
        e.* = try l.b.inst(.jump, 0, 0, scope);
    }
    const end = pc(l);
    for (exits) |e| patch(l, e, end);
    var arm_rows: std.ArrayList(u32) = .empty;
    for (targets, 0..) |t, k| try arm_rows.append(l.a, try l.b.extraOf(Program.Arm{ .labels = .{ .start = rows.items[2 * k], .len = rows.items[2 * k + 1] }, .target = t }));
    const kind: Program.Case.Kind = switch (c.flags.kind) {
        .case => .normal,
        .casez => .casez,
        .casex => .casex,
    };
    const row = try l.b.extraOf(Program.Case{ .kind = kind, .scrutinee = scrutinee, .arms = try l.b.listOf(arm_rows.items), .fallback = if (fallback == none) end else fallback });
    l.b.setInst(dispatch, .case_select, row, 0);
}

/// A repeat or fork-join counter cell.
fn counterCell(l: *Lower, kind: enum { repeat, join }) u32 {
    const at = l.repeats + l.joins;
    switch (kind) {
        .repeat => l.repeats += 1,
        .join => l.joins += 1,
    }
    return at;
}

/// One process: its body, then `restart` (always) or `stop`; returns its
/// first pc.
fn process(l: *Lower, p: Proc) Error!u32 {
    l.frame = p.frame;
    const vir = l.virOf(p.frame);
    const scope = l.frames.items[p.frame].scope;
    const start = pc(l);
    switch (p.kind) {
        .init_var => {
            // The name is bound to its first declaration (`output q; reg q = 1;`).
            const prev, const init_body = switch (Lower.tag(vir, p.inst)) {
                .variable => .{ Lower.payload(vir, Inst.Variable, p.inst).prev, Lower.payload(vir, Inst.Variable, p.inst).init },
                .io => .{ Lower.payload(vir, Inst.Io, p.inst).prev, Lower.payload(vir, Inst.Io, p.inst).init },
                else => unreachable, // else: `declare.items` records these two
            };
            const n = l.names.items[l.lookup(p.frame, prev.toIndex() orelse p.inst) orelse return l.refuse("an initialized declaration with no slot")];
            if (n.dims.len != 0) return l.refuse("an initialized array");
            if (n.kind != .variable) return l.refuse("an initialized net port");
            const init = vir.body(init_body);
            _ = try l.b.inst(.init_var, n.slot, try expr.evalFor(l, init[init.len - 1].toRef(), n.ty), scope);
            _ = try l.b.inst(.stop, 0, 0, scope);
        },
        .initial, .always => {
            const b = Lower.payload(vir, Inst.Process, p.inst).body;
            try body(l, b, 0);
            if (p.kind == .always) _ = try l.b.inst(.restart, start, 0, scope) else _ = try l.b.inst(.stop, 0, 0, scope);
        },
    }
    return start;
}

/// A.6.3 a block: a named one is a scope of its own (§12.5) whose pc range
/// `%m` and `disable` read; its declarations bind in a frame of its own.
fn block(l: *Lower, i: Inst.Index, depth: u32) Error!void {
    const vir = l.virOf(l.frame);
    const blk = Lower.payload(vir, Inst.Block, i);
    const outer = l.frame;
    defer l.frame = outer;
    const outer_scope = l.frames.items[outer].scope;
    const name = vir.string(blk.name);
    if (name.len != 0) {
        l.frame = try decl.blockFrame(l, outer, i);
    } else for (vir.body(blk.body)) |x| switch (Lower.tag(vir, x)) {
        .variable, .param, .event => return l.refuse("a declaration in an unnamed block"),
        else => {}, // else: a statement
    };
    const start = pc(l);
    if (blk.flags.fork and !l.in_function) try fork(l, blk.body, depth + 1) else try body(l, blk.body, depth + 1);
    if (name.len == 0) return;
    try l.b.blocks.append(l.a, .{ .scope = outer_scope, .name = try l.b.string(name), .start = start, .end = pc(l), .depth = depth });
    try l.block_ranges.put(l.a, try link.blockKey(l, outer, name), .{ start, pc(l) });
}

/// §9.8.2 a parallel block, as lib/sim/digital compiles it: each statement
/// an arm ending in `join_arm`; `fork` starts them all and suspends the
/// parent until the last is back, which resumes it after the block.
fn fork(l: *Lower, b: Vir.Body, depth: u32) Error!void {
    const scope = l.frames.items[l.frame].scope;
    const join = counterCell(l, .join);
    const at = try l.b.inst(.fork, 0, 0, scope);
    const stmts = try statements(l, b);
    const arms = try l.a.alloc(u32, stmts.len);
    const ends = try l.a.alloc(u32, stmts.len);
    for (stmts, arms, ends) |s, *arm, *end| {
        arm.* = pc(l);
        try compileStmt(l, s, depth);
        end.* = try l.b.inst(.join_arm, join, 0, scope);
    }
    const after = pc(l);
    l.b.setInst(at, .fork, try l.b.extraOf(Program.Fork{ .arms = try l.b.listOf(arms), .join = join, .end = after }), 0);
    for (ends) |e| l.b.setInst(e, .join_arm, join, after);
}

/// The statements of body `b`, in order (its expression instructions are
/// reached from the statements that read them; a `call_sys` or `call` no
/// later instruction reads is a task enable).
fn statements(l: *Lower, b: Vir.Body) Error![]const Inst.Index {
    const vir = l.virOf(l.frame);
    const insts = vir.body(b);
    var used: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
    for (insts) |i| try operands(l, vir, i, &used);
    var out: std.ArrayList(Inst.Index) = .empty;
    for (insts) |i| {
        const tg = Lower.tag(vir, i);
        if ((tg == .call_sys or tg == .call) and used.contains(i)) continue;
        if (isStatement(tg)) try out.append(l.a, i);
    }
    return out.items;
}

/// Every slot the statements of body `b` read (§9.7.5's `@*`).
/// The slots the index expressions of lvalue `r` read (not its targets).
fn indexReads(l: *Lower, r: Inst.Ref, out: *std.ArrayList(u32)) Error!void {
    const vir = l.virOf(l.frame);
    const i = r.toIndex() orelse return;
    switch (Lower.tag(vir, i)) {
        .elem => {
            const b = Lower.payload(vir, Inst.Bin, i);
            try indexReads(l, b.lhs, out);
            try expr.reads(l, b.rhs, out);
        },
        .slice, .slice_up, .slice_down => {
            const t = Lower.payload(vir, Inst.Triple, i);
            try indexReads(l, t.a, out);
            try expr.reads(l, t.b, out);
            try expr.reads(l, t.c, out);
        },
        .concat => for (vir.list(Inst.Ref, Lower.payload(vir, Inst.Refs, i))) |x| try indexReads(l, x, out),
        else => {}, // else: a name, whose slot is written, not read
    }
}

fn bodyReads(l: *Lower, b: Vir.Body, out: *std.ArrayList(u32)) Error!void {
    const vir = l.virOf(l.frame);
    for (vir.body(b)) |i| switch (Lower.tag(vir, i)) {
        .store, .store_nb => {
            const s = Lower.payload(vir, Inst.Bin, i);
            try expr.reads(l, s.rhs, out);
            // §9.7.5 the target's index expressions are read too.
            try indexReads(l, s.lhs, out);
        },
        .condbr => {
            const c = Lower.payload(vir, Inst.CondBr, i);
            try expr.reads(l, c.cond, out);
            try bodyReads(l, c.then, out);
            try bodyReads(l, c.@"else", out);
        },
        .block => try bodyReads(l, Lower.payload(vir, Inst.Block, i).body, out),
        .case => {
            const c = Lower.payload(vir, Inst.Case, i);
            try expr.reads(l, c.operand, out);
            for (vir.list(Inst.Arm, c.arms)) |arm| {
                for (vir.list(Inst.Ref, arm.values)) |v| try expr.reads(l, v, out);
                try bodyReads(l, arm.body, out);
            }
        },
        .call_sys => for (vir.list(Inst.Ref, Lower.payload(vir, Inst.SysCall, i).args)) |a| try expr.reads(l, a, out),
        else => if (isStatement(Lower.tag(vir, i))) return l.refuseFmt("the slots `@*` reads in `{t}`", .{Lower.tag(vir, i)}),
    };
}

/// Adds every operand `i` reads to `used`.
fn operands(l: *Lower, vir: *const Vir, i: Inst.Index, used: *std.AutoHashMapUnmanaged(Inst.Index, void)) Error!void {
    const tg = Lower.tag(vir, i);
    const data = vir.instructions.items(.data)[@backingInt(i)];
    switch (Inst.dataKind(tg)) {
        .un_node => if (data.un_node.operand.toIndex()) |o| try used.put(l.a, o, {}),
        .pl_node => switch (tg) {
            .call => {
                const c = Lower.payload(vir, Inst.Call, i);
                for (vir.list(Inst.Ref, c.args)) |r| if (r.toIndex()) |o| try used.put(l.a, o, {});
            },
            .call_sys => for (vir.list(Inst.Ref, Lower.payload(vir, Inst.SysCall, i).args)) |r| {
                if (r.toIndex()) |o| try used.put(l.a, o, {});
            },
            .concat => for (vir.list(Inst.Ref, Lower.payload(vir, Inst.Refs, i))) |r| {
                if (r.toIndex()) |o| try used.put(l.a, o, {});
            },
            .add, .sub, .mul, .div, .mod, .pow, .shl, .shr, .ashl, .ashr, .lt, .gt, .lte, .gte, .eq, .neq, .case_eq, .case_neq, .bit_and, .bit_or, .bit_xor, .bit_xnor, .bool_and, .bool_or, .elem, .replicate, .event_or, .store, .store_nb, .proc_assign, .force, .contrib, .repeat_ctl, .pattern_repl, .range, .pulse_limits => {
                const b = Lower.payload(vir, Inst.Bin, i);
                for ([_]Inst.Ref{ b.lhs, b.rhs }) |r| if (r.toIndex()) |o| try used.put(l.a, o, {});
            },
            .ternary, .mintypmax, .slice, .slice_up, .slice_down, .contrib_indirect => {
                const t = Lower.payload(vir, Inst.Triple, i);
                for ([_]Inst.Ref{ t.a, t.b, t.c }) |r| if (r.toIndex()) |o| try used.put(l.a, o, {});
            },
            .store_timed, .store_nb_timed => {
                const t = Lower.payload(vir, Inst.Timed, i);
                for ([_]Inst.Ref{ t.lhs, t.rhs, t.timing }) |r| if (r.toIndex()) |o| try used.put(l.a, o, {});
            },
            .condbr => if (Lower.payload(vir, Inst.CondBr, i).cond.toIndex()) |o| try used.put(l.a, o, {}),
            .case => if (Lower.payload(vir, Inst.Case, i).operand.toIndex()) |o| try used.put(l.a, o, {}),
            .repeat => if (Lower.payload(vir, Inst.Repeat, i).count.toIndex()) |o| try used.put(l.a, o, {}),
            .delay => if (Lower.payload(vir, Inst.Delay, i).value.toIndex()) |o| try used.put(l.a, o, {}),
            .event_wait => if (Lower.payload(vir, Inst.EventWait, i).event.toIndex()) |o| try used.put(l.a, o, {}),
            .field => if (Lower.payload(vir, Inst.Field, i).operand.toIndex()) |o| try used.put(l.a, o, {}),
            .pattern => for (vir.list(Inst.Ref, Lower.payload(vir, Inst.Refs, i))) |r| {
                if (r.toIndex()) |o| try used.put(l.a, o, {});
            },
            else => {}, // else: a statement or declaration, whose operands are not calls in this body's sense
        },
        .str_tok, .decl_tok, .int, .float, .str => {},
    }
}
