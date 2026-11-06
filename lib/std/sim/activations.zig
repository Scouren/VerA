//! A timed enable of a task that reaches itself in, its §10.2.3 activation
//! out: the process goes on in the task's out-of-line body (`Sub.body`) and
//! comes back after the enable when the body ends. An automatic task's
//! frame holds one activation at a time (`State.resident`); another one's
//! storage waits in its `State.Act` until a process resumes inside it.
//! Cites: IEEE 1364-2005 §10.2.1, §10.2.2, §10.2.3.
//!
//! Contents:
//! - `pub fn callTimed(s: *State, a: Allocator, at: u32, pc: u32) Error!u32`
//! - `pub fn returnTimed(s: *State, a: Allocator, sub: u32) Error!u32`
//! - `pub fn makeResident(s: *State, ctx: u32) Error!void`
//! - `pub fn context(s: *const State, sub: u32, from: u32) u32`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Program = @import("Program.zig");
const State = @import("State.zig");
const eval = @import("eval.zig");
const calls = @import("calls.zig");
const logic = @import("logic.zig");
const Error = State.Error;
const Literal = logic.Literal;

const none = @backingInt(Program.Ref.none);

/// §10.2.2 the enable at `pc` of the `Program.Call` at `at` as a new
/// activation: the inputs evaluated in the caller, an automatic task's
/// frame set aside for a fresh one, the ports filled. Returns the pc the
/// process goes on at (the body's entry), now inside the activation.
pub fn callTimed(s: *State, a: Allocator, at: u32, pc: u32) Error!u32 {
    const p = s.p;
    const c = p.extraData(Program.Call, at);
    const sub = p.subs[c.sub];
    assert(sub.body != none);
    const ports = p.list(sub.body_ports);
    assert(p.list(c.args).len == 4 * ports.len);
    const inputs = try a.alloc(?Literal, ports.len);
    for (inputs, 0..) |*in, k| {
        const arg = p.extraData(Program.Arg, c.args.start + @as(u32, @intCast(4 * k)));
        in.* = if (arg.in == none) null else try calls.copy(a, try eval.eval(s, a, arg.in));
    }
    if (s.acts.items.len == 0) try s.acts.append(s.arena, undefined); // 0 is "no activation"
    const act: State.Act = .{ .sub = c.sub, .ret_pc = pc + 1, .ret_ctx = s.ctx, .call = at };
    const id: u32 = if (s.free_acts.pop()) |k| blk: {
        s.acts.items[k] = act;
        break :blk k;
    } else blk: {
        try s.acts.append(s.arena, act);
        break :blk @intCast(s.acts.items.len - 1);
    };
    if (sub.automatic) {
        try evict(s, c.sub);
        calls.resetFrame(s, sub.body_first, sub.body_count);
        s.resident[c.sub] = id;
    }
    calls.copyIn(s, inputs, ports);
    s.ctx = id;
    return sub.body;
}

/// The end of the running activation's body (task `sub`): its outputs read
/// while its storage is resident, the caller's activation made resident,
/// and the outputs written to the caller's actuals. Returns the pc after
/// the enable.
pub fn returnTimed(s: *State, a: Allocator, sub: u32) Error!u32 {
    const p = s.p;
    const done = s.ctx;
    assert(done != 0);
    const act = s.acts.items[done];
    assert(act.sub == sub);
    const ports = p.list(p.subs[sub].body_ports);
    const outs = try a.alloc(Literal, ports.len);
    for (ports, outs) |slot, *o| o.* = try calls.copy(a, try eval.read(s, a, slot));
    if (s.resident[sub] == done) s.resident[sub] = 0; // ended: nothing to save
    try s.free_acts.append(s.arena, done);
    s.ctx = act.ret_ctx;
    try makeResident(s, s.ctx);
    const c = p.extraData(Program.Call, act.call);
    for (ports, outs, 0..) |slot, v, k| {
        const arg = p.extraData(Program.Arg, c.args.start + @as(u32, @intCast(4 * k)));
        if (arg.place == none) continue;
        try eval.put(s, a, arg.place, try calls.convertValue(a, v, p.slots.items(.ty)[slot].real, arg.ty), false, null);
    }
    return act.ret_pc;
}

/// Puts activation `ctx`'s storage in its task's frame, if it is not there.
pub fn makeResident(s: *State, ctx: u32) Error!void {
    if (ctx == 0) return;
    const act = s.acts.items[ctx];
    const sub = s.p.subs[act.sub];
    if (!sub.automatic or s.resident[act.sub] == ctx) return;
    try evict(s, act.sub);
    calls.loadFrame(s, sub.body_first, sub.body_count, act.storage);
    s.resident[act.sub] = ctx;
}

/// The activation of automatic task `sub` that activation `from` is in,
/// itself or through its callers; 0 for none.
pub fn context(s: *const State, sub: u32, from: u32) u32 {
    var ctx = from;
    var hops: usize = 0;
    while (ctx != 0) : (hops += 1) {
        assert(hops < s.acts.items.len); // Each hop is a distinct caller.
        const act = s.acts.items[ctx];
        if (act.sub == sub) return ctx;
        ctx = act.ret_ctx;
    }
    return 0;
}

// ---- private ----

/// Saves the resident activation of automatic task `sub`, freeing its frame.
fn evict(s: *State, sub: u32) Error!void {
    const r = s.resident[sub];
    if (r == 0) return;
    const b = s.p.subs[sub];
    const act = &s.acts.items[r];
    const n = calls.frameWords(s, b.body_first, b.body_count);
    if (act.storage.len != n) act.storage = try s.arena.alloc(u64, n);
    calls.saveFrame(s, b.body_first, b.body_count, act.storage);
    s.resident[sub] = 0;
}
