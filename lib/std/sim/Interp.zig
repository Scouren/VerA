//! The engine: a `State`'s scheduler drained in IEEE 1364-2005 §11.4 order
//! (`run`), each event dispatched, and a process's instructions executed
//! from a pc until it suspends, stops or finishes (`step`). `step` is also
//! the per-process fallback a native executable calls.
//! Cites: IEEE 1364-2005 §6.1, §8.5.3.3, §8.5.3.4, §9.2, §9.4-§9.9, §10.3,
//! §11.4, §17.1.2, §17.1.3, §17.4.1.
//!
//! Contents:
//! - `pub const Stop = enum { idle, analog, explicit_d2a }`
//! - `pub fn run(s: *State) Error!void`
//! - `pub fn runUntil(s: *State, limit: u64) Error!Stop`
//! - `pub fn delayIn(s: *State, a: Allocator, e: u32, scope: u32) Error!u64`
//! - `pub fn step(s: *State, start: u32) Error!void`
//! - `pub fn runFrom(s: *State, scratch: *std.heap.ArenaAllocator, start: u32) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Program = @import("Program.zig");
const State = @import("State.zig");
const eval = @import("eval.zig");
const logic = @import("logic.zig");
const display = @import("display.zig");
const resolve = @import("resolve.zig");
const calls = @import("calls.zig");
const readmem = @import("readmem.zig");
const holds = @import("holds.zig");
const files = @import("files.zig");
const tchk = @import("tchk.zig");
const vcd = @import("vcd.zig");
const evcd = @import("evcd.zig");
const sdf = @import("sdf.zig");
const queues = @import("queues.zig");
const pla = @import("pla.zig");
const activations = @import("activations.zig");
const analog = @import("analog.zig");
const Error = State.Error;
const Literal = logic.Literal;

/// Why `runUntil` returned: nothing is left at or before the limit; or,
/// in a mixed run, a value the analog block reads changed (VAMS §8.5.1
/// region 3b) or an explicit D2A term occurred (§8.5.3.6 region 1b).
pub const Stop = enum { idle, analog, explicit_d2a };

/// Whether a process goes on after an instruction.
const Flow = enum { next, ended };

/// Runs the design to completion.
pub fn run(s: *State) Error!void {
    const stop = try runUntil(s, std.math.maxInt(u64));
    assert(stop == .idle);
    // §18.3.6.1 the run is over: each port dump ends.
    try evcd.close(s);
}

/// Dispatches every event at a time <= `limit`, then returns with only later
/// work queued; a later call resumes.
pub fn runUntil(s: *State, limit: u64) Error!Stop {
    while (s.scheduler.nextUntil(limit)) |event| {
        _ = s.scratch.reset(.retain_capacity);
        if (event.time != s.budget_time) {
            s.budget_time = event.time;
            s.budget_used = 0;
        }
        s.budget_used += 1;
        if (s.budget_used > s.budget)
            return s.fail("more than {d} events at time {d}: a zero-delay loop keeps simulation time from advancing", .{ s.budget, event.time });
        const row = s.rows.items[event.payload];
        const a = s.scratch.allocator();
        switch (row.item) {
            .run => |pc| {
                s.ctx = 0;
                try step(s, pc);
            },
            .run_in => |x| {
                s.ctx = x.ctx;
                try activations.makeResident(s, x.ctx);
                try step(s, x.pc);
            },
            .write => |w| {
                const n = Program.words(w.width);
                const planes = try a.dupe(u64, row.buf[0 .. 2 * n]);
                try eval.write(s, a, w.slot, w.sel, .{ .width = w.width, .signed = w.signed, .sized = true, .planes = planes });
            },
            .strobe => |show| try display.show(s, a, show, 0),
            .fstrobe => |at| try files.fshow(s, a, at),
            .vcd_tick => {
                try vcd.tick(s, a);
                try evcd.tick(s, a);
            },
            .monitor_tick => {
                s.monitor_pending = false;
                if (s.monitor_hit) try display.monitorPrint(s, a);
                try display.fmonitorPrint(s, a);
            },
            .drive => |at| try resolve.drive(s, a, at),
            .net_update => |net| try resolve.netUpdate(s, net),
            .decay => |net| try resolve.decay(s, a, net),
            .tran_switch => |t| try resolve.tranSwitch(s, a, t),
            .tchk_expiry => |t| try tchk.expired(s, t.check, t.gen),
            .tchk_event => |t| try tchk.delivered(s, t.code, t.bit),
            .put => |w| {
                const n = Program.words(w.width);
                try s.store(w.slot, .{ .width = w.width, .signed = false, .sized = true, .planes = try a.dupe(u64, row.buf[0 .. 2 * n]) });
            },
            .a2d => |slot| try s.trigger(slot),
            .analog_mark => {
                try s.free_rows.append(s.arena, event.payload);
                s.analog.pending = false;
                return .analog;
            },
            // §8.4.7 "Digital to analog events shall cause an analog
            // solution of the time where they occur": 1b is followed by 3b.
            .d2a_mark => {
                try s.free_rows.append(s.arena, event.payload);
                s.analog.d2a_pending = false;
                try analog.requestAnalog(s);
                return .explicit_d2a;
            },
        }
        try s.free_rows.append(s.arena, event.payload);
    }
    return .idle;
}

/// §9.7.1 delay row `e` in ticks of the design's precision, in the time
/// scale of `scope`'s module: a real rounds to the module's precision; an
/// x/z delay is 0.
pub fn delayIn(s: *State, a: Allocator, e: u32, scope: u32) Error!u64 {
    const p = s.p;
    const scale = p.times[p.scopes[scope].time].scale;
    if (p.exprs.items(.ty)[e].real)
        return scale.realDelay(try eval.real(s, a, e)) catch |err| s.fail("digital delay cannot be represented: {t}", .{err});
    const value = try eval.eval(s, a, e);
    if (value.hasUnknown()) return 0;
    if (value.width > 64) return s.fail("delay values wider than 64 bits are not implemented", .{});
    return (if (value.signed) scale.signedDelay(value.asInt().?) else scale.unsignedDelay(value.values()[0])) catch |err|
        s.fail("digital delay cannot be represented: {t}", .{err});
}

/// Runs the process at `start` until it suspends, stops or finishes.
pub fn step(s: *State, start: u32) Error!void {
    return runFrom(s, &s.scratch, start);
}

/// `step` over `scratch`, reset before each instruction: a nested §10
/// activation runs its body on a scratch of its own.
pub fn runFrom(s: *State, scratch: *std.heap.ArenaAllocator, start: u32) Error!void {
    const p = s.p;
    const tags = p.insts.items(.tag);
    const datas = p.insts.items(.data);
    var pc = start;
    var restarted = false;
    while (true) {
        assert(pc < p.insts.len);
        // §10.3 a disabled subroutine's activations return at once.
        if (s.unwind != null) return;
        _ = scratch.reset(.retain_capacity);
        const a = scratch.allocator();
        const d = datas[pc];
        switch (tags[pc]) {
            .stop => return,
            .init_var => {
                try s.store(d.a, try eval.eval(s, a, d.b));
                pc += 1;
            },
            .assign, .assign_nb => {
                try eval.put(s, a, d.a, try eval.eval(s, a, d.b), tags[pc] == .assign_nb, null);
                pc += 1;
            },
            .delay => {
                _ = try s.enqueue(State.resumption(pc + 1, s.ctx), try delayOf(s, a, d.a, pc), false);
                return;
            },
            .task => {
                if (try task(s, a, d.a, pc) == .ended) return;
                pc += 1;
            },
            .jump => {
                if (d.a <= pc) try loopIteration(s);
                pc = d.a;
            },
            .branch => pc = if (try eval.truth(s, a, d.a) == .one) pc + 1 else d.b,
            .restart => {
                // A whole body run twice in one dispatch had no timing
                // control: each further pass counts against the budget.
                if (restarted) {
                    if (s.scheduler.finishing) return;
                    try loopIteration(s);
                }
                restarted = true;
                pc = d.a;
            },
            .case_select => pc = try caseSelect(s, a, p.extraData(Program.Case, d.a)),
            .repeat_start => {
                const r = p.extraData(Program.Repeat, d.b);
                const value = try eval.eval(s, a, d.a);
                const w = value.values();
                // §9.6: x, z or negative is zero times; past 64 bits saturates.
                const count: u64 = if (value.hasUnknown() or (value.signed and value.bit(value.width - 1) == .one))
                    0
                else if (std.mem.allEqual(u64, w[1..], 0)) w[0] else std.math.maxInt(u64);
                s.counters[r.counter] = count;
                pc = if (count == 0) r.end else pc + 1;
            },
            .repeat_next => {
                s.counters[d.a] -= 1;
                if (s.counters[d.a] != 0) try loopIteration(s);
                pc = if (s.counters[d.a] != 0) d.b else pc + 1;
            },
            .wait_event => {
                const id = try s.park(pc + 1);
                try watchAll(s, id, p.extraData(struct { l: Program.List }, d.a).l);
                return;
            },
            .wait_level => {
                if (try eval.truth(s, a, d.a) == .one) {
                    pc += 1;
                    continue;
                }
                const id = try s.park(pc);
                const slots = p.list(p.extraData(struct { l: Program.List }, d.b).l);
                for (slots) |slot| try s.watch(id, .{ .slot = slot, .edge = .any });
                return;
            },
            .trigger => {
                try s.trigger(d.a);
                pc += 1;
            },
            .trigger_elem => {
                if (try eval.address(s, a, p.extraData(Program.Elem, d.a))) |slot| try s.trigger(slot);
                pc += 1;
            },
            .continuous => return resolve.continuous(s, a, d.a, pc),
            .fork => {
                const f = p.extraData(Program.Fork, d.a);
                const arms = p.list(f.arms);
                if (arms.len == 0) {
                    pc = f.end;
                    continue;
                }
                // §10.2.3 a fork inside an activation counts its own arms.
                if (s.ctx == 0)
                    s.counters[f.join] = arms.len
                else
                    try s.joins.put(s.arena, .{ .join = f.join, .ctx = s.ctx }, arms.len);
                for (arms) |arm| _ = try s.enqueue(State.resumption(arm, s.ctx), null, false);
                return;
            },
            .join_arm => {
                const left = if (s.ctx == 0) &s.counters[d.a] else s.joins.getPtr(.{ .join = d.a, .ctx = s.ctx }).?;
                left.* -= 1;
                if (left.* == 0) _ = try s.enqueue(State.resumption(d.b, s.ctx), null, false);
                return;
            },
            .sample => {
                const sm = p.extraData(Program.Sample, d.a);
                const v = try eval.eval(s, a, sm.value);
                const h = &s.holds[sm.hold];
                if (h.planes.len != v.planes.len) h.planes = try s.arena.alloc(u64, v.planes.len);
                @memcpy(h.planes, v.planes);
                h.width = v.width;
                h.signed = v.signed;
                switch (sm.mode) {
                    .park => pc += 1,
                    // §8.5.3.4 a nonblocking one does not suspend.
                    .nba, .nba_delay => {
                        const value: Literal = .{ .width = h.width, .signed = h.signed, .sized = true, .planes = try a.dupe(u64, h.planes) };
                        try eval.put(s, a, sm.place, value, true, if (sm.mode == .nba_delay) try delayOf(s, a, sm.timing, pc) else null);
                        pc += 1;
                    },
                    .delay => {
                        _ = try s.enqueue(State.resumption(pc + 1, s.ctx), try delayOf(s, a, sm.timing, pc), false);
                        return;
                    },
                    .event => {
                        const id = try s.park(pc + 1);
                        try watchAll(s, id, sm.terms);
                        return;
                    },
                }
            },
            .deposit, .deposit_nb => {
                const h = s.holds[d.a];
                const value: Literal = .{ .width = h.width, .signed = h.signed, .sized = true, .planes = try a.dupe(u64, h.planes) };
                try eval.put(s, a, d.b, value, tags[pc] == .deposit_nb, null);
                pc += 1;
            },
            .switch_ctrl => return resolve.switchCtrl(s, a, d.a, pc),
            .spawn => {
                if (d.b == 1) {
                    // Nested, as a call's body runs: the child parks at its
                    // wait and this process carries on.
                    // A process of its own, outside any activation.
                    var nested: std.heap.ArenaAllocator = .init(s.arena);
                    defer nested.deinit();
                    const ctx = s.ctx;
                    s.ctx = 0;
                    defer s.ctx = ctx;
                    try runFrom(s, &nested, d.a);
                } else _ = try s.enqueue(.{ .run = d.a }, null, false);
                pc += 1;
            },
            .override_on => {
                try holds.on(s, d.a);
                pc += 1;
            },
            .override_eval => {
                try holds.apply(s, a, d.a);
                pc += 1;
            },
            .override_off => {
                try holds.off(s, a, d.a);
                pc += 1;
            },
            .call => {
                _ = try calls.call(s, a, d.a);
                pc += 1;
            },
            .copy_out => {
                try calls.copyOut(s, a, d.a);
                pc += 1;
            },
            .call_timed => pc = try activations.callTimed(s, a, d.a, pc),
            .task_return => pc = try activations.returnTimed(s, a, d.a),
            .disable_task => {
                // Every inlined copy (the running one resumes after itself)
                // and every synchronous activation, which unwind.
                const ranges = p.list(p.subs[d.a].ranges);
                var next = pc + 1;
                var resumed = false;
                var k: usize = 0;
                while (k < ranges.len) : (k += 2) {
                    const inside = pc >= ranges[k] and pc < ranges[k + 1];
                    if (inside) next = ranges[k + 1];
                    if (try disable(s, ranges[k], ranges[k + 1]) and inside) resumed = true;
                }
                if (s.sub_active[d.a] != 0) {
                    s.unwind = d.a;
                    return;
                }
                if (resumed) return;
                pc = next;
            },
            .disable_block => {
                const inside = pc >= d.a and pc < d.b;
                if (try disable(s, d.a, d.b) and inside) return;
                pc = if (inside) d.b else pc + 1;
            },
        }
    }
}

// ---- private ----

/// One pass back to the top of an untimed loop counts against the step's
/// budget, so `initial forever x = 1;` is refused by name.
fn loopIteration(s: *State) Error!void {
    s.budget_used += 1;
    if (s.budget_used > s.budget)
        return s.fail("more than {d} loop iterations and events at time {d}: a loop with no delay keeps simulation time from advancing", .{ s.budget, s.scheduler.now });
}

/// §10.3 `disable` of the block [start, end): every resumption into it is
/// dropped and, only if one was, execution resumes at `end` once.
fn disable(s: *State, start: u32, end: u32) Error!bool {
    if (!try s.stopRange(start, end)) return false;
    _ = try s.enqueue(.{ .run = end }, null, false);
    return true;
}

fn delayOf(s: *State, a: Allocator, e: u32, pc: u32) Error!u64 {
    return delayIn(s, a, e, s.p.inst_scope[pc]);
}

fn watchAll(s: *State, id: u32, terms: Program.List) Error!void {
    const words = s.p.list(terms);
    assert(words.len % Program.Term.words == 0);
    var k: usize = 0;
    while (k < words.len) : (k += Program.Term.words) try s.watch(id, s.p.extraData(Program.Term, terms.start + @as(u32, @intCast(k))));
}

/// §9.5: the first arm with a label matching the scrutinee; else the fallback.
fn caseSelect(s: *State, a: Allocator, c: Program.Case) Error!u32 {
    const p = s.p;
    const value = try eval.eval(s, a, c.scrutinee);
    for (p.list(c.arms)) |arm_at| {
        const arm = p.extraData(Program.Arm, arm_at);
        for (p.list(arm.labels)) |label| {
            if (caseMatches(c.kind, value, try eval.eval(s, a, label))) return arm.target;
        }
    }
    return c.fallback;
}

fn caseMatches(kind: Program.Case.Kind, value: Literal, label: Literal) bool {
    assert(value.width == label.width);
    if (kind == .normal) return value.equality(.case_equal, label) == .one;
    // §9.5.1: wildcards on either side; z is (0, 1), x is (1, 1).
    for (0..(value.width + 63) / 64) |w| {
        const av = value.values()[w];
        const au = value.unknowns()[w];
        const bv = label.values()[w];
        const bu = label.unknowns()[w];
        const wild = if (kind == .casex) au | bu else (au & ~av) | (bu & ~bv);
        if (((av ^ bv) | (au ^ bu)) & ~wild & logic.wordMask(value.width, w) != 0) return false;
    }
    return true;
}

/// A system task call (`Program.Task`): its effect, and whether the process
/// goes on.
fn task(s: *State, a: Allocator, at: u32, pc: u32) Error!Flow {
    const p = s.p;
    const t = p.extraData(Program.Task, at);
    switch (t.kind) {
        .show => try display.show(s, a, t.a, pc),
        .strobe => try s.enqueueMonitor(.{ .strobe = t.a }),
        .monitor => try display.install(s, a, t.a),
        .monitor_on => {
            s.monitor_on = true;
            try display.monitorPrint(s, a);
        },
        .monitor_off => s.monitor_on = false,
        .timeformat => try display.timeformat(s, a, t.a),
        .readmem => try readmem.readMemory(s, a, t.a),
        .swrite => try display.swrite(s, a, t.a),
        .fshow => try files.fshow(s, a, t.a),
        .fstrobe => try s.enqueueMonitor(.{ .fstrobe = t.a }),
        .fclose => try files.fclose(s, a, t.a),
        // Every write is already in its file.
        .fflush => {},
        .dump => try vcd.task(s, a, t.a),
        .ports => try evcd.task(s, a, t.a),
        .sdf => try sdf.annotate(s, a, t.a),
        .queue => try queues.task(s, a, t.a),
        .pla => try pla.task(s, a, t.a),
        .finish, .stop => {
            const verbose = t.a == @backingInt(Program.Ref.none) or ((try eval.eval(s, a, t.a)).asInt() orelse 1) != 0;
            if (verbose) {
                const where = p.str(t.b);
                if (t.kind == .stop)
                    std.debug.print("$stop at tick {d}, {s}\n", .{ s.scheduler.now, where })
                else
                    try s.out.print("$finish at tick {d}, {s}\n", .{ s.scheduler.now, where });
            }
            // The rest of this step runs, no later one does.
            s.scheduler.finishStep();
            return .ended;
        },
    }
    return .next;
}
