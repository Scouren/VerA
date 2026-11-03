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
//! - `pub fn checkSites(arena: Allocator, r: *const Run) E![]const u32`
//! - `pub fn sdfScopes(l: *Lower) E!void`

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
const net = std_sim.net;
const logic = std_sim.logic;
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

/// Per timing check (`Program.checks` order), the source byte its W1199
/// report is filed at: the oracle's key for "which checks violated".
pub fn checkSites(arena: Allocator, r: *const Run) E![]const u32 {
    const out = try arena.alloc(u32, r.checks.rows.items.len);
    for (r.checks.rows.items, out) |c, *o| o.* = r.starts[@min(c.tok, r.starts.len - 1)];
    return out;
}

/// §16 per scope what an annotation matches by name (`Program.SdfScope`).
pub fn sdfScopes(l: *Lower) E!void {
    const r = l.r;
    const b = l.b;
    if (b.p.sdf_scopes.len != 0) return;
    const out = try b.arena.alloc(Program.SdfScope, r.hier.scopes.items.len);
    for (r.hier.scopes.items, out, 0..) |info, *o, sc| {
        const m = &r.file.modules[info.def];
        var ports: std.ArrayList(u32) = .empty;
        for (m.ports) |port| {
            const name = try b.string(r.file.str(port.name));
            try ports.appendSlice(l.a, &.{ name.start, name.len, r.hier.names.get(.{ .scope = @intCast(sc), .str = port.name }) orelse std.math.maxInt(u32) });
        }
        var specs: std.ArrayList(u32) = .empty;
        for (m.params) |param| if (param.is_spec) if (r.hier.names.get(.{ .scope = @intCast(sc), .str = param.name })) |at| {
            const name = try b.string(r.file.str(param.name));
            try specs.appendSlice(l.a, &.{ name.start, name.len, at });
        };
        o.* = .{ .module = try b.string(r.file.str(m.name)), .lexical = info.lexical, .ports = try b.listOf(ports.items), .specparams = try b.listOf(specs.items) };
    }
    b.p.sdf_scopes = out;
}

// ---- private ----

fn build(l: *Lower) E!void {
    const r = l.r;
    const b = l.b;
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
    b.p.random_seed = r.tasks.random_seed;
    b.p.file_name = try b.string(r.file_name);
    var blocks = r.program.blocks.iterator();
    while (blocks.next()) |kv| try b.blocks.append(b.arena, .{
        .scope = kv.key_ptr.scope,
        .name = try b.string(r.file.str(kv.key_ptr.str)),
        .start = kv.value_ptr.start,
        .end = kv.value_ptr.end,
        .depth = kv.value_ptr.depth,
    });
    try netlist(l);
    try subs(l);
    try checks(l);
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
        .continuous => |at| _ = try b.inst(.continuous, at, 0, scope),
        .fork => |f| {
            const c = try b.extraOf(Program.Fork{ .arms = try b.listOf(r.program.wordsOf(f.arms)), .join = repeats + f.join, .end = f.end });
            _ = try b.inst(.fork, c, 0, scope);
        },
        .join_arm => |j| _ = try b.inst(.join_arm, repeats + j.join, j.end, scope),
        .disable_block => |d| _ = try b.inst(.disable_block, d.start, d.end, scope),
        .call => |c| _ = try b.inst(.call, try l.call(c.sub, r.program.exprs(c.args)), 0, scope),
        .copy_out => |c| _ = try b.inst(.copy_out, try b.extraOf(Program.CopyOut{ .place = try l.place(c.target), .slot = c.slot, .ty = try l.tyOf(try l.targetType(c.target)) }), 0, scope),
        .disable_task => |idx| _ = try b.inst(.disable_task, idx, 0, scope),
        .call_timed => return l.refuse("a timed task activation"),
        .task_return => return l.refuse("a timed task return"),
        .pla_start => return l.refuse("a process of its own (PLA or event-controlled NBA)"),
        .override_on => |o| _ = try b.inst(.override_on, try b.extraOf(Program.Override{ .slot = o.slot, .force = o.force, .lo = o.bits.lo, .width = o.bits.width, .start = o.start, .end = o.end }), 0, scope),
        .override_off => |o| _ = try b.inst(.override_off, try b.extraOf(Program.Override{ .slot = o.slot, .force = o.force, .lo = o.bits.lo, .width = o.bits.width, .start = 0, .end = 0 }), 0, scope),
        .override_eval => |o| {
            const value = if (o.slice.of != 0)
                try l.evalFor(o.value, .{ .width = o.slice.of, .signed = false })
            else if (o.bits.width != 0)
                try l.evalFor(o.value, .{ .width = o.bits.width, .signed = false })
            else
                try l.evalFor(o.value, r.slotType(o.slot));
            _ = try b.inst(.override_eval, try b.extraOf(Program.OverrideEval{ .slot = o.slot, .value = value, .force = o.force, .lo = o.bits.lo, .width = o.bits.width, .slice_lo = o.slice.lo, .of = o.slice.of }), 0, scope);
        },
        .switch_ctrl => |sc| {
            const t = r.netlist.switches[sc.tran];
            const tr = @constCast(&b.p.trans[sc.tran]);
            tr.ctrl = try l.self_(t.ctrl, 1);
            if (r.netlist.switch_delays.get(sc.tran)) |d3| {
                tr.delay_rows[0] = try l.selfOrReal(d3.rise);
                if (d3.fall != .none) tr.delay_rows[1] = try l.selfOrReal(d3.fall);
                if (d3.off != .none) tr.delay_rows[2] = try l.selfOrReal(d3.off);
            }
            _ = try b.inst(.switch_ctrl, sc.tran, 0, scope);
        },
    }
}

/// §15 every timing check as `Program.checks`, and per slot the checks its
/// change reaches, in `tchk.arm`'s order.
fn checks(l: *Lower) E!void {
    const r = l.r;
    const b = l.b;
    const rows = r.checks.rows.items;
    if (rows.len == 0) return;
    const out = try b.arena.alloc(Program.Check, rows.len);
    for (rows, out, 0..) |c, *o, i| {
        r.scope = c.scope;
        var ev: [2]Program.CheckEvent = undefined;
        for (&ev, c.ev) |*e, old| e.* = .{ .slot = old.slot, .lo = old.lo, .width = old.width, .mask = old.mask, .cond = try checkCond(l, old.cond) };
        o.* = .{
            .kind = std.meta.stringToEnum(Program.Check.Kind, @tagName(c.kind)).?,
            .scope = c.scope,
            .ev = ev,
            .lim = c.lim,
            .notifier = c.notifier orelse std.math.maxInt(u32),
            .stamp_cond = try checkCond(l, c.stamp_cond),
            .check_cond = try checkCond(l, c.check_cond),
            .event_based = c.flags.event_based,
            .remain_active = c.flags.remain_active,
            .delay = if (r.checks.delay.items.len != 0) r.checks.delay.items[i] else .{ 0, 0 },
            .v = .{ c.ev[0].v, c.ev[1].v },
            .x = .{ c.ev[0].x, c.ev[1].x },
        };
    }
    b.p.checks = out;
    // The CSR of `tchk.arm`: per slot, its codes in check order.
    const n = r.values.len;
    const start = try b.arena.alloc(u32, n + 1);
    @memset(start, 0);
    for (rows) |c| for (c.ev[0..watched(c.kind)]) |e| {
        start[e.slot + 1] += 1;
    };
    for (1..n + 1) |k| start[k] += start[k - 1];
    const fill = try l.a.dupe(u32, start[0..n]);
    const codes = try b.arena.alloc(u32, start[n]);
    for (rows, 0..) |c, i| for (c.ev[0..watched(c.kind)], 0..) |e, k| {
        codes[fill[e.slot]] = @intCast(i * 2 + k);
        fill[e.slot] += 1;
    };
    b.p.check_start = start;
    b.p.check_codes = codes;
}

/// The events `tchk.arm` files: $width and $period watch the reference only.
fn watched(kind: anytype) usize {
    return if (kind == .width or kind == .period) 1 else 2;
}

/// §15.6 condition `e` analysed as `tchk.enabled` reads it.
fn checkCond(l: *Lower, e: @import("frontend").Ast.ExprId) E!Program.Cond {
    if (e == .none) return .{};
    const r = l.r;
    const ex = &r.file.exprs;
    var out: Program.Cond = .{ .op = .plain };
    var signal = e;
    switch (ex.tag(e)) {
        .unary => if (ex.unOp(e) == .bit_not) {
            out.op = .invert;
            signal = ex.lhs(e);
        },
        .binary => if (ex.tag(ex.rhs(e)) == .int_literal or ex.tag(ex.rhs(e)) == .logic_literal) {
            out.op = switch (ex.binOp(e)) {
                .eq => .eq,
                .neq => .neq,
                .case_eq => .case_eq,
                .case_neq => .case_neq,
                else => .plain, // else: any other operator is a bare expression
            };
            if (out.op != .plain) {
                signal = ex.lhs(e);
                const v = digital.for_emitter.evaluate.eval(r, l.a, ex.rhs(e), 0) catch return l.refuse("a check condition the old engine refuses");
                out.want = @fromBackingInt(@intCast(@backingInt(v.bit(0))));
            }
        },
        else => {}, // else: any other expression is a bare one
    }
    out.signal = try l.self_(signal, 0);
    return out;
}

/// §10 every task and function, as `Program.subs`.
fn subs(l: *Lower) E!void {
    const r = l.r;
    const b = l.b;
    const out = try b.arena.alloc(Program.Sub, r.routines.rows.items.len);
    for (r.routines.rows.items, out) |sub, *o| {
        var ranges: std.ArrayList(u32) = .empty;
        for (sub.ranges.items) |rg| try ranges.appendSlice(l.a, &.{ rg.start, rg.end });
        o.* = .{
            .entry = if (sub.compiled) sub.entry else std.math.maxInt(u32),
            .function = sub.decl.is_function,
            .automatic = sub.decl.automatic,
            .first = sub.frame.first,
            .count = sub.frame.count,
            .result = sub.frame.result,
            .ports = try b.listOf(sub.frame.ports),
            .ranges = try b.listOf(ranges.items),
        };
    }
    b.p.subs = out;
}

/// §7.9 every net and §6.1/§7 every driver, as `Program.nets` and
/// `Program.drivers`, each driver's time-0 value and state as elaboration
/// left it.
fn netlist(l: *Lower) E!void {
    const r = l.r;
    const b = l.b;
    const nets = try b.arena.alloc(Program.Net, r.netlist.nets.len);
    var paths: std.ArrayList(Program.Path) = .empty;
    var resolved: std.ArrayList(u64) = .empty;
    const path_source = try b.arena.alloc(bool, r.values.len);
    @memset(path_source, false);
    for (r.netlist.nets, nets, 0..) |n, *out, k| {
        const cold = r.netCold(n);
        const width = n.resolved.width;
        const resolved_at: u32 = @intCast(resolved.items.len);
        try resolved.appendSlice(b.arena, n.resolved.values()[0..Program.words(width)]);
        try resolved.appendSlice(b.arena, n.resolved.unknowns()[0..Program.words(width)]);
        const first: u32 = @intCast(paths.items.len);
        for (cold.paths) |path| {
            path_source[path.src] = true;
            var edge: Program.Edge = .any;
            switch (path.edge) {
                .none => {},
                .posedge => edge = .posedge,
                .negedge => edge = .negedge,
                else => return l.refuse("a module path edge other than posedge/negedge"), // else: no other edge reaches a path
            }
            r.scope = path.scope;
            const cond: u32 = if (path.cond == .none) @backingInt(Program.Ref.none) else try l.self_(path.cond, 0);
            var delays: std.ArrayList(u32) = .empty;
            for (path.delays) |d| try delays.append(l.a, try l.selfOrReal(d));
            try paths.append(b.arena, .{ .src = path.src, .src_bit = path.src_bit, .edge = edge, .cond = cond, .ifnone = path.ifnone, .scope = path.scope, .table = path.table, .reject = path.reject, .err = path.err, .delays = try b.listOf(delays.items) });
        }
        out.* = .{
            .kind = std.meta.stringToEnum(net.NetKind, @tagName(n.kind)).?,
            .charge = @fromBackingInt(@intCast(@backingInt(n.charge))),
            .slot = n.slot,
            .drivers = try b.listOf(r.netDrivers(@intCast(k))),
            .delay = delay(cold.delay),
            .decay = cold.decay orelse Program.Net.no_decay,
            .paths = .{ .start = first, .len = @intCast(cold.paths.len) },
            .ondetect = cold.ondetect,
            .showcancelled = cold.showcancelled,
            .trans = try b.listOf(cold.trans),
            .signal = n.signal,
            .strength_read = n.strength_read,
            .resolved = resolved_at,
            .cold = n.cold != digital.for_emitter.net.no_cold,
        };
    }
    b.p.resolved_init = resolved.items;
    const signals = try b.arena.alloc(net.Signal, r.netlist.signals.len);
    for (r.netlist.signals, signals) |sig, *o| o.* = .{ .lo = sig.lo, .hi = sig.hi };
    b.p.signal_init = signals;
    const none = @backingInt(Program.Ref.none);
    const trans = try b.arena.alloc(Program.Tran, r.netlist.switches.len);
    for (r.netlist.switches, trans) |t, *o| o.* = .{
        .a = t.a,
        .b = t.b,
        .a_bit = t.a_bit,
        .b_bit = t.b_bit,
        .ctrl = none,
        .on = @fromBackingInt(@intCast(@backingInt(t.on))),
        .resistive = t.resistive,
        .delay = delay(t.delay),
        .delay_rows = .{ none, none, none },
        .state = std.meta.stringToEnum(net.TranState, @tagName(t.state)).?,
    };
    b.p.trans = trans;
    b.p.paths = paths.items;
    if (paths.items.len != 0) b.p.path_source = path_source;
    var init: std.ArrayList(u64) = .empty;
    var udp_bits: std.ArrayList(logic.Bit) = .empty;
    var udps: std.ArrayList([]const net.UdpRow) = .empty;
    var tables: std.AutoHashMapUnmanaged(usize, u32) = .empty;
    const drivers = try b.arena.alloc(Program.Driver, r.netlist.drivers.len);
    for (r.netlist.drivers, drivers, 0..) |d, *out, k| {
        r.scope = d.scope;
        const n = r.netlist.nets[d.net];
        const width = d.current.width;
        const words = Program.words(width);
        const at: u32 = @intCast(init.items.len);
        try init.appendSlice(b.arena, d.current.values()[0..words]);
        try init.appendSlice(b.arena, d.current.unknowns()[0..words]);
        var rows: [3]u32 = .{ none, none, none };
        if (r.netlist.driver_delays.get(@intCast(k))) |d3| {
            rows[0] = try l.selfOrReal(d3.rise);
            if (d3.fall != .none) rows[1] = try l.selfOrReal(d3.fall);
            if (d3.off != .none) rows[2] = try l.selfOrReal(d3.off);
        }
        const source: Program.Driver.Source = switch (d.source) {
            .expr => |x| if (x.slice) |sl|
                .{ .expr = .{ .value = try l.self_(x.e, sl.total), .slice = true, .lo = sl.lo, .total = sl.total } }
            else
                .{ .expr = .{ .value = try l.evalFor(x.e, r.slotType(n.slot)), .slice = false, .lo = 0, .total = 0 } },
            .bridge => |br| .{ .bridge = .{ .src = br.src, .src_lo = br.src_lo, .dst_lo = br.dst_lo, .width = br.width, .ext = br.ext, .sign_at = br.sign_at } },
            .gate => |g| .{ .gate = .{ .kind = std.meta.stringToEnum(net.GateKind, @tagName(g.kind)).?, .ins = try inputRows(l, g.ins), .lane = g.lane, .out_bit = g.out_bit } },
            .udp => |u| blk: {
                const key = @intFromPtr(u.rows.ptr);
                const table = tables.get(key) orelse t: {
                    const copy = try b.arena.alloc(net.UdpRow, u.rows.len);
                    for (u.rows, copy) |row, *c| {
                        const syms = try b.arena.alloc(net.UdpSym, row.ins.len);
                        for (row.ins, syms) |sym, *y| y.* = switch (sym) {
                            .level => |v| .{ .level = v },
                            .pair => |v| .{ .pair = v },
                            .letter => |v| .{ .letter = v },
                        };
                        c.* = .{ .ins = syms, .state = row.state, .out = row.out, .edge_at = row.edge_at };
                    }
                    try udps.append(b.arena, copy);
                    const id: u32 = @intCast(udps.items.len - 1);
                    try tables.put(b.arena, key, id);
                    break :t id;
                };
                const prev_start: u32 = @intCast(udp_bits.items.len);
                for (u.prev) |bit| try udp_bits.append(b.arena, @fromBackingInt(@intCast(@backingInt(bit))));
                break :blk .{ .udp = .{
                    .udp = table,
                    .ins = try inputRows(l, u.ins),
                    .sequential = u.sequential,
                    .lane = u.lane,
                    .out_bit = u.out_bit,
                    .state = @fromBackingInt(@intCast(@backingInt(u.state))),
                    .started = u.started,
                    .prev = .{ .start = prev_start, .len = @intCast(u.prev.len) },
                } };
            },
            .mos => |m| blk: {
                const ex = &r.file.exprs;
                var data_net: u32 = none;
                if (ex.tag(m.data) == .ident) if (r.netlist.slot_nets.get(r.slot(m.data) catch return l.refuse("a MOS data name the old engine refuses"))) |dn| {
                    data_net = dn;
                };
                break :blk .{ .mos = .{ .data = try l.self_(m.data, 1), .gate = try l.self_(m.gate, 1), .data_net = data_net, .n_type = m.n_type, .resistive = m.resistive, .lane = m.lane, .out_bit = m.out_bit } };
            },
            .pull => |bit| .{ .pull = @fromBackingInt(@intCast(@backingInt(bit))) },
        };
        out.* = .{
            .net = d.net,
            .scope = d.scope,
            .s0 = @fromBackingInt(@intCast(@backingInt(d.s0))),
            .s1 = @fromBackingInt(@intCast(@backingInt(d.s1))),
            .delay = delay(d.delay),
            .delay_rows = rows,
            .width = width,
            .init = at,
            .init_or_z = d.or_z,
            .source = source,
            .sensitivity = try b.listOf(d.sensitivity),
        };
    }
    b.p.nets = nets;
    const slot_net = try b.arena.alloc(u32, r.values.len);
    for (slot_net, 0..) |*sn, k| sn.* = r.netlist.slot_nets.get(@intCast(k)) orelse std.math.maxInt(u32);
    b.p.slot_net = slot_net;
    b.p.drivers = drivers;
    b.p.driver_init = init.items;
    b.p.udps = udps.items;
    b.p.udp_bits = udp_bits.items;
}

fn delay(d: anytype) net.Delay {
    return .{ .rise = d.rise, .fall = d.fall, .off = d.off, .present = d.present };
}

/// A gate's or UDP's input rows: each read one bit wide (`eval(in, 1)`).
fn inputRows(l: *Lower, exprs: anytype) E!Program.List {
    var rows: std.ArrayList(u32) = .empty;
    for (exprs) |e| try rows.append(l.a, try l.self_(e, 1));
    return l.b.listOf(rows.items);
}
