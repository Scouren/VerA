//! The bridge (docs/rewrite/sim.md): an old elaborated `Run` (lib/sim/digital,
//! after `elaborate`, before any event) in, the new `Program` out, pc for
//! pc: every instruction translated in the scope it was compiled in, its
//! expressions bound to slots and typed (`lower.zig`), its formats parsed
//! (`shows.zig`). It stands in for Sema until Sema exists. A construct it
//! does not express yet is `error.Unsupported` with `Lower.why` saying
//! which, so `diff-sim` lists the fixture by name.
//! Cites: IEEE 1364-2005 §6.1, §9, §11.4, §12.5, §19.8 (through
//! lib/sim/digital).
//!
//! Contents:
//! - `pub fn program(arena: Allocator, r: *Run, why: *[]const u8) E!Program`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const sim = @import("sim");
const std_sim = @import("std_sim");
const digital = sim.digital;
const Run = digital.Run;
const compile = digital.for_emitter.compile;
const Program = std_sim.Program;
const Builder = std_sim.Builder;
const lower = @import("lower.zig");
const shows = @import("shows.zig");
const Lower = lower.Lower;
const E = lower.E;

/// The `Program` of elaborated run `r`, in `arena`. On `Unsupported`, `why`
/// says what stopped it. `r` is spent: its time-0 queue is drained.
pub fn program(arena: Allocator, r: *Run, why: *[]const u8) E!Program {
    var b: Builder = .init(arena);
    var l: Lower = .{ .r = r, .b = &b, .a = arena };
    build(&l) catch |e| {
        why.* = l.why;
        return e;
    };
    return b.finish();
}

// ---- private ----

fn build(l: *Lower) E!void {
    const r = l.r;
    const b = l.b;
    if (r.checks.rows.items.len != 0) return l.refuse("§15 timing checks");
    if (r.opts.systf != null) return l.refuse("a PLI application");
    // Slots, by the old numbering, at their time-0 values.
    for (r.values, 0..) |v, k| {
        const ty = r.slotType(@intCast(k));
        if (ty.width > std.math.maxInt(u30)) return l.refuse("a slot wider than 2^30 bits");
        const t: Program.Ty = if (ty.real) .real_ty else .int(ty.width, ty.signed);
        const n = Program.words(ty.width);
        _ = try b.slot(t, v.values()[0..n], v.unknowns()[0..n]);
    }
    // Scopes, each with its own module's time scale.
    for (r.hier.scopes.items, 0..) |s, k| {
        const mt = r.timeOf(@intCast(k));
        try b.times.append(b.arena, .{ .scale = .{ .local_per_unit = mt.scale.local_per_unit, .global_per_local = mt.scale.global_per_local }, .unit_exp = mt.unit_exp });
        const index: ?i32 = if (s.index) |i| std.math.cast(i32, i) orelse return l.refuse("a generate index past i32") else null;
        try b.scopes.append(b.arena, .{ .parent = s.parent, .name = try b.string(r.file.str(s.name)), .index = index, .time = @intCast(k) });
    }
    b.p.finest = r.time.finest;
    var blocks = r.program.blocks.iterator();
    while (blocks.next()) |kv| try b.blocks.append(b.arena, .{
        .scope = kv.key_ptr.scope,
        .name = try b.string(r.file.str(kv.key_ptr.str)),
        .start = kv.value_ptr.start,
        .end = kv.value_ptr.end,
        .depth = kv.value_ptr.depth,
    });
    const repeats: u32 = @intCast(r.rows.repeats.items.len);
    b.p.counters = repeats + @as(u32, @intCast(r.rows.joins.items.len));
    b.p.holds = @intCast(r.rows.holds.items.len);
    for (r.program.code.items, r.program.scope_of.items, 0..) |ins, scope, pc| {
        r.scope = scope;
        try inst(l, ins, @intCast(pc), repeats);
    }
    b.p.fan_start = r.waits.fan_start;
    b.p.fan = r.waits.fan;
    // §11.4 the time-0 queue, in dispatch order.
    while (r.scheduler.nextUntil(0)) |event| {
        if (event.region != .active) return l.refuse("a time-0 event outside the active region");
        switch (r.rows.pending.items[event.payload].item) {
            .run_process => |pc| try b.starts.append(b.arena, .{ .pc = pc }),
            else => return l.refuse("a time-0 event other than a process start"),
        }
    }
    if (r.scheduler.peekTime() != null) return l.refuse("an event queued past time 0 at elaboration");
}

/// Instruction `pc`, translated in `r.scope`; `repeats` offsets the fork
/// join counters past the repeat counters.
fn inst(l: *Lower, ins: compile.Instruction, pc: u32, repeats: u32) E!void {
    const r = l.r;
    const b = l.b;
    const scope = r.scope;
    switch (ins) {
        .stop => _ = try b.inst(.stop, 0, 0, scope),
        .init_var => |s| _ = try b.inst(.init_var, s.slot, try l.evalFor(s.value, r.slotType(s.slot)), scope),
        .assign => |s| {
            const target = try l.targetType(s.target);
            _ = try b.inst(if (s.nonblocking) .assign_nb else .assign, try l.place(s.target), try l.evalFor(s.value, target), scope);
        },
        .delay => |s| _ = try b.inst(.delay, try l.selfOrReal(s.amount), 0, scope),
        .task => |s| {
            r.pc = pc;
            _ = try b.inst(.task, try shows.task(l, s.task, r.program.exprs(s.args), s.tok, pc), 0, scope);
        },
        .jump => |target| _ = try b.inst(.jump, target, 0, scope),
        .branch => |s| _ = try b.inst(.branch, try l.selfOrReal(s.condition), s.otherwise, scope),
        .restart => |s| _ = try b.inst(.restart, s.target, 0, scope),
        .case_select => |s| {
            const case = r.file.stmt(s.statement).case_stmt;
            const scrutinee = try l.ctx(case.scrutinee, s.ty);
            var arms: std.ArrayList(u32) = .empty;
            for (case.arms, 0..) |arm, i| {
                var labels: std.ArrayList(u32) = .empty;
                for (r.file.caseLabels(arm)) |label| try labels.append(l.a, try l.ctx(label, s.ty));
                try arms.append(l.a, try b.extraOf(Program.Arm{ .labels = try b.listOf(labels.items), .target = r.program.case_targets.items[s.targets + i] }));
            }
            const kind: Program.Case.Kind = switch (case.kind) {
                .normal => .normal,
                .casez => .casez,
                .casex => .casex,
            };
            const c = try b.extraOf(Program.Case{ .kind = kind, .scrutinee = scrutinee, .arms = try b.listOf(arms.items), .fallback = s.fallback });
            _ = try b.inst(.case_select, c, 0, scope);
        },
        .repeat_start => |s| _ = try b.inst(.repeat_start, try l.self_(s.count, 0), try b.extraOf(Program.Repeat{ .counter = s.counter, .end = s.end }), scope),
        .repeat_next => |s| _ = try b.inst(.repeat_next, s.counter, s.body, scope),
        .wait_event => |e| {
            var terms: std.ArrayList(u32) = .empty;
            try l.terms(e, &terms);
            _ = try b.inst(.wait_event, try b.extraOf(.{ .l = try b.listOf(terms.items) }), 0, scope);
        },
        .wait_slots => |slots| {
            var terms: std.ArrayList(u32) = .empty;
            for (r.program.wordsOf(slots)) |s| try terms.appendSlice(l.a, &.{ s, @backingInt(Program.Edge.any), 0, 0 });
            _ = try b.inst(.wait_event, try b.extraOf(.{ .l = try b.listOf(terms.items) }), 0, scope);
        },
        .wait_level => |s| _ = try b.inst(.wait_level, try l.selfOrReal(s.cond), try b.extraOf(.{ .l = try b.listOf(r.program.wordsOf(s.slots)) }), scope),
        .sample => |s| {
            const a = r.file.stmt(s.statement).assign;
            if (a.timing_repeat != .none) return l.refuse("§9.7.7 repeat event control");
            const value = try l.evalFor(a.value, try l.targetType(a.target));
            var sm: Program.Sample = .{ .hold = s.cell, .value = value, .mode = .park, .place = 0, .timing = 0, .terms = .empty };
            if (!compile.parksOnly(a)) {
                if (a.nonblocking) {
                    sm.place = try l.place(a.target);
                    if (a.timing_is_delay) {
                        sm.mode = .nba_delay;
                        sm.timing = try l.selfOrReal(a.timing);
                    } else sm.mode = .nba;
                } else if (a.timing_is_delay) {
                    sm.mode = .delay;
                    sm.timing = try l.selfOrReal(a.timing);
                } else {
                    sm.mode = .event;
                    var terms: std.ArrayList(u32) = .empty;
                    try l.terms(a.timing, &terms);
                    sm.terms = try b.listOf(terms.items);
                }
            }
            _ = try b.inst(.sample, try b.extraOf(sm), 0, scope);
        },
        .deposit => |s| {
            const a = r.file.stmt(s.statement).assign;
            _ = try b.inst(if (a.nonblocking) .deposit_nb else .deposit, s.cell, try l.place(a.target), scope);
        },
        .trigger => |t| switch (t) {
            .slot => |slot| _ = try b.inst(.trigger, slot, 0, scope),
            .indexed => return l.refuse("a trigger of an event array element"),
        },
        .continuous => |at| _ = try b.inst(.continuous, try driver(l, at), 0, scope),
        .fork => |f| {
            const c = try b.extraOf(Program.Fork{ .arms = try b.listOf(r.program.wordsOf(f.arms)), .join = repeats + f.join, .end = f.end });
            _ = try b.inst(.fork, c, 0, scope);
        },
        .join_arm => |j| _ = try b.inst(.join_arm, repeats + j.join, j.end, scope),
        .disable_block => |d| _ = try b.inst(.disable_block, d.start, d.end, scope),
        .call => return l.refuse("a task or function call"),
        .copy_out => return l.refuse("a task copy-out"),
        .disable_task => return l.refuse("a disable of a task"),
        .call_timed => return l.refuse("a timed task activation"),
        .task_return => return l.refuse("a timed task return"),
        .pla_start => return l.refuse("a process of its own (PLA or event-controlled NBA)"),
        .override_on, .override_eval, .override_off => return l.refuse("§9.3 assign/force"),
        .switch_ctrl => return l.refuse("§7.6 a controlled switch"),
    }
}

/// Continuous driver `at` as a `Program.Driver`: only an expression driving
/// a whole plain net alone, which resolves to its own value (§7.9).
fn driver(l: *Lower, at: u32) E!u32 {
    const r = l.r;
    const d = r.netlist.drivers[at];
    const x = switch (d.source) {
        .expr => |x| x,
        .bridge => return l.refuse("a port bridge driver"),
        .gate => return l.refuse("a §7 gate"),
        .udp => return l.refuse("a §8 UDP"),
        .mos => return l.refuse("a §7.6 MOS switch"),
        .pull => return l.refuse("a §7.7 pull"),
    };
    if (x.slice != null) return l.refuse("a driver of part of a net");
    if (d.delay.present or r.netlist.driver_delays.contains(at)) return l.refuse("a delayed continuous assignment");
    const n = r.netlist.nets[d.net];
    if (n.kind != .wire and n.kind != .tri) return l.refuse("a net type other than wire/tri");
    if (r.netDrivers(d.net).len != 1) return l.refuse("a net with more than one driver");
    const cold = r.netCold(n);
    if (cold.trans.len != 0 or cold.delay.present or cold.paths.len != 0) return l.refuse("a net with switches, a delay or module paths");
    r.scope = d.scope;
    return l.b.extraOf(Program.Driver{ .slot = n.slot, .value = try l.evalFor(x.e, r.slotType(n.slot)) });
}
