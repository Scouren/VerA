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
    const order = try processOrder(l);
    for (order) |s| {
        const procs = l.scopes.items[s].procs.items;
        for ([_]bool{ true, false }) |inits| for (procs) |p| {
            if ((p.kind == .init_var) != inits) continue;
            const start = try process(l, p);
            if (p.kind == .always and try levelControlled(l, p)) try early.append(l.a, start) else try queued.append(l.a, start);
        };
    }
    for (early.items) |at| try l.b.starts.append(l.a, .{ .pc = at });
    for (l.driver_pcs.items) |at| try l.b.starts.append(l.a, .{ .pc = at });
    var switches: usize = 0;
    for (l.trans.items) |t| if (t.pc != none) {
        try l.b.starts.append(l.a, .{ .pc = t.pc });
        switches += 1;
    };
    for (queued.items) |at| try l.b.starts.append(l.a, .{ .pc = at });
    try fanout(l);
    try sub.finish(l);
    l.b.p.counters = l.repeats + l.joins;
    assert(l.b.starts.items.len == early.items.len + l.driver_pcs.items.len + switches + queued.items.len);
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
            const n = (try expr.nameOf(l, r)) orelse return l.refuse("a trigger of an event array element or a hierarchical event");
            if (n.kind != .event) return l.refuse("§5.10.4 `->` of a variable or net");
            _ = try l.b.inst(.trigger, n.slot, 0, scope);
        },
        .call_sys => try task.task(l, i),
        .call => try sub.enable(l, i, depth),
        .store_timed, .store_nb_timed => return l.refuse("an intra-assignment timing control"),
        .case => return l.refuse("a case statement"),
        .proc_assign, .force, .deassign, .release => return l.refuse("a procedural continuous assignment"),
        .disable => return l.refuse("a disable statement"),
        .ret, .brk, .cont => return l.refuse("return, break or continue"),
        .variable, .param, .event => {},
        else => {}, // else: an expression instruction, reached from the statement that reads it
    }
}

/// Appends the statements of body `b` (its expression instructions are
/// reached from the statements that read them; a `call_sys` no later
/// instruction reads is a task enable).
pub fn body(l: *Lower, b: Vir.Body, depth: u32) Error!void {
    const vir = l.virOf(l.frame);
    const insts = vir.body(b);
    var used: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
    for (insts) |i| try operands(l, vir, i, &used);
    for (insts) |i| {
        const tg = Lower.tag(vir, i);
        if ((tg == .call_sys or tg == .call) and used.contains(i)) continue;
        if (isStatement(tg)) try compileStmt(l, i, depth);
    }
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

/// §9.9 the order processes are queued in: the scope tree depth first from
/// each root, each scope's children (by source position) before itself.
fn processOrder(l: *Lower) Error![]const u32 {
    const n = l.scopes.items.len;
    const children = try l.a.alloc(std.ArrayList(u32), n);
    @memset(children, .empty);
    for (l.b.scopes.items, 0..) |s, k| if (s.parent != k and l.scopes.items[k].queued) try children[s.parent].append(l.a, @intCast(k));
    for (children) |c| std.sort.block(u32, c.items, l, struct {
        fn less(ll: *Lower, x: u32, y: u32) bool {
            return ll.scopes.items[x].at < ll.scopes.items[y].at;
        }
    }.less);
    var out: std.ArrayList(u32) = .empty;
    var stack: std.ArrayList([2]u32) = .empty;
    for (l.roots.items) |root| {
        try stack.append(l.a, .{ root, 0 });
        var steps: usize = 0;
        while (stack.items.len != 0) : (steps += 1) {
            assert(steps <= 2 * n);
            const top = &stack.items[stack.items.len - 1];
            const kids = children[top[0]].items;
            if (top[1] < kids.len) {
                const c = kids[top[1]];
                top[1] += 1;
                try stack.append(l.a, .{ c, 0 });
                continue;
            }
            try out.append(l.a, top[0]);
            _ = stack.pop();
        }
    }
    return out.items;
}

/// Whether `always` process `p` starts with an event control on levels
/// only (`@(a or b)`, `@*`): VerA starts these first at time 0, so they see
/// the time-0 changes the others make (iverilog's order).
fn levelControlled(l: *Lower, p: Proc) Error!bool {
    const vir = l.virOf(p.frame);
    const b = vir.body(Lower.payload(vir, Inst.Process, p.inst).body);
    var first: ?Inst.Index = null;
    for (b) |i| if (isStatement(Lower.tag(vir, i))) {
        first = i;
        break;
    };
    const s = first orelse return false;
    if (Lower.tag(vir, s) != .event_wait) return false;
    const e = Lower.payload(vir, Inst.EventWait, s).event;
    return e == .none or levelOnly(vir, e);
}

fn levelOnly(vir: *const Vir, r: Inst.Ref) bool {
    const i = r.toIndex() orelse return true;
    return switch (Lower.tag(vir, i)) {
        .event_or => levelOnly(vir, Lower.payload(vir, Inst.Bin, i).lhs) and levelOnly(vir, Lower.payload(vir, Inst.Bin, i).rhs),
        .posedge, .negedge, .driver_update => false,
        .decl_ref => Lower.tag(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl) != .event,
        else => true, // else: an expression term
    };
}

/// A.6.3 a block: a named one is a scope of its own (§12.5) whose pc range
/// `%m` and `disable` read; its declarations bind in a frame of its own.
fn block(l: *Lower, i: Inst.Index, depth: u32) Error!void {
    const vir = l.virOf(l.frame);
    const blk = Lower.payload(vir, Inst.Block, i);
    if (blk.flags.fork) return l.refuse("a fork-join block");
    const outer = l.frame;
    defer l.frame = outer;
    const outer_scope = l.frames.items[outer].scope;
    const name = vir.string(blk.name);
    if (name.len != 0) {
        const s = try decl.newScope(l, outer_scope, name, null, l.b.times.items[outer_scope], l.srcOffset(outer, i), false);
        l.frame = try decl.newFrame(l, outer, l.frames.items[outer].instance, s, l.frames.items[outer].genvars);
        // §10.2.1 an automatic subroutine's block items are per activation,
        // which its storage (laid out at its declaration) does not hold.
        l.frames.items[l.frame].automatic = l.frames.items[outer].automatic;
        const slots_before = l.b.p.slots.len;
        try vars.locals(l, l.frame, blk.body);
        if (l.frames.items[outer].automatic and l.b.p.slots.len != slots_before) return l.refuse("a named block declaring storage in an automatic subroutine");
    } else for (vir.body(blk.body)) |x| switch (Lower.tag(vir, x)) {
        .variable, .param, .event => return l.refuse("a declaration in an unnamed block"),
        else => {}, // else: a statement
    };
    const start = pc(l);
    try body(l, blk.body, depth + 1);
    if (name.len != 0) try l.b.blocks.append(l.a, .{ .scope = outer_scope, .name = try l.b.string(name), .start = start, .end = pc(l), .depth = depth });
}

/// Every slot the statements of body `b` read (§9.7.5's `@*`).
fn bodyReads(l: *Lower, b: Vir.Body, out: *std.ArrayList(u32)) Error!void {
    const vir = l.virOf(l.frame);
    for (vir.body(b)) |i| switch (Lower.tag(vir, i)) {
        .store, .store_nb => try expr.reads(l, Lower.payload(vir, Inst.Bin, i).rhs, out),
        .condbr => {
            const c = Lower.payload(vir, Inst.CondBr, i);
            try expr.reads(l, c.cond, out);
            try bodyReads(l, c.then, out);
            try bodyReads(l, c.@"else", out);
        },
        .block => try bodyReads(l, Lower.payload(vir, Inst.Block, i).body, out),
        .call_sys => for (vir.list(Inst.Ref, Lower.payload(vir, Inst.SysCall, i).args)) |a| try expr.reads(l, a, out),
        else => if (isStatement(Lower.tag(vir, i))) return l.refuseFmt("the slots `@*` reads in `{t}`", .{Lower.tag(vir, i)}),
    };
}

fn isStatement(tg: Inst.Tag) bool {
    return switch (tg) {
        .block, .condbr, .case, .loop, .repeat, .wait, .delay, .event_wait, .store, .store_nb, .proc_assign, .force, .store_timed, .store_nb_timed, .deassign, .release, .trigger, .disable, .ret, .brk, .cont, .call_sys, .call, .contrib, .contrib_indirect => true,
        else => false, // else: a declaration or an expression
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

/// §6.1/§7.6 per slot, the pcs of the continuous drivers and controlled
/// pass switches that read it, drivers first.
fn fanout(l: *Lower) Error!void {
    const n = l.b.p.slots.len;
    var readers: std.ArrayList(struct { pc: u32, sensitivity: Program.List }) = .empty;
    for (l.b.p.drivers, l.driver_pcs.items) |d, at| try readers.append(l.a, .{ .pc = at, .sensitivity = d.sensitivity });
    for (l.trans.items) |t| if (t.pc != none) try readers.append(l.a, .{ .pc = t.pc, .sensitivity = t.sensitivity });
    const start = try l.a.alloc(u32, n + 1);
    @memset(start, 0);
    for (readers.items) |r| for (l.b.extra.items[r.sensitivity.start..][0..r.sensitivity.len]) |slot| {
        start[slot + 1] += 1;
    };
    for (1..n + 1) |k| start[k] += start[k - 1];
    const fill = try l.a.dupe(u32, start[0..n]);
    const fan = try l.a.alloc(u32, start[n]);
    for (readers.items) |r| for (l.b.extra.items[r.sensitivity.start..][0..r.sensitivity.len]) |slot| {
        fan[fill[slot]] = r.pc;
        fill[slot] += 1;
    };
    assert(std.mem.eql(u32, fill, start[1..]));
    l.b.p.fan_start = start;
    l.b.p.fan = fan;
}
