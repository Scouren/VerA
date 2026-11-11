//! A §10 subroutine call in, its effect out: the arguments copied in, the
//! body run to completion as one nested activation (its own scratch, an
//! automatic frame saved and reset around it), the outputs copied back, and
//! a function's result. Also the copy-out of an inlined task enable and
//! §10.3's `disable` of a task.
//! Cites: IEEE 1364-2005 §4.8.2, §10.2.2, §10.2.3, §10.3, §10.4.1, §10.4.2.
//!
//! Contents:
//! - `pub fn call(s: *State, a: Allocator, at: u32) Error!Literal`
//! - `pub fn copyOut(s: *State, a: Allocator, at: u32) Error!void`
//! - `pub fn convertValue(a: Allocator, v: Literal, from_real: bool, target: Program.Ty) Error!Literal`
//! - `pub fn frameWords(s: *const State, first: u32, count: u32) usize`
//! - `pub fn saveFrame(s: *const State, first: u32, count: u32, out: []u64) void`
//! - `pub fn loadFrame(s: *State, first: u32, count: u32, from: []const u64) void`
//! - `pub fn resetFrame(s: *State, first: u32, count: u32) void`
//! - `pub fn copyIn(s: *State, inputs: []const ?Literal, ports: []const u32) void`
//! - `pub fn copy(a: Allocator, v: Literal) Error!Literal`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Program = @import("Program.zig");
const State = @import("State.zig");
const Interp = @import("Interp.zig");
const eval = @import("eval.zig");
const logic = @import("logic.zig");
const Error = State.Error;
const Literal = logic.Literal;

const none = @backingInt(Program.Ref.none);

/// Runs the call at `at` in `extra` (a `Program.Call`) and returns a
/// function's result (x for a task), in `a`. The inputs are evaluated in the
/// caller before anything of the callee's changes; after a §10.3 disable of
/// the subroutine the outputs are not copied back.
pub fn call(s: *State, a: Allocator, at: u32) Error!Literal {
    const p = s.p;
    const c = p.extraData(Program.Call, at);
    const sub = p.subs[c.sub];
    // §10.4.2 bounds no depth; this engine does (lib/TODO.md §11.2), on a
    // stack sized for `State.stack_size`: the words the fixture's `//!
    // reject` pins, the MiB the new side's own.
    if (s.depth == s.depth_max) return s.fail(.E1100, "nesting here exhausts the {d} MiB stack VerA reserved for it", .{State.stack_size >> 20});
    s.depth += 1;
    defer s.depth -= 1;
    const args = p.list(c.args);
    const ports = p.list(sub.ports);
    assert(args.len == 4 * ports.len);
    const inputs = try a.alloc(?Literal, ports.len);
    for (inputs, 0..) |*in, k| {
        const arg = p.extraData(Program.Arg, c.args.start + @as(u32, @intCast(4 * k)));
        in.* = if (arg.in == none) null else try copy(a, try eval.eval(s, a, arg.in));
    }
    // §10.2.3/§10.4.2 an automatic activation's storage is its own: the
    // frame is set aside, reset, and restored after.
    var saved: []u64 = &.{};
    if (sub.automatic) {
        saved = try a.alloc(u64, frameWords(s, sub.first, sub.count));
        saveFrame(s, sub.first, sub.count, saved);
        resetFrame(s, sub.first, sub.count);
    }
    copyIn(s, inputs, ports);
    s.sub_active[c.sub] += 1;
    {
        var body: std.heap.ArenaAllocator = .init(s.arena);
        defer body.deinit();
        try Interp.runFrom(s, &body, sub.entry);
    }
    s.sub_active[c.sub] -= 1;
    const result = if (sub.function) try copy(a, try eval.read(s, a, sub.result)) else try logic.filled(a, 1, false, .x);
    const outs = try a.alloc(?Literal, ports.len);
    for (outs, ports, 0..) |*o, slot, k| {
        const arg = p.extraData(Program.Arg, c.args.start + @as(u32, @intCast(4 * k)));
        o.* = if (arg.place != none and s.unwind == null) try copy(a, try eval.read(s, a, slot)) else null;
    }
    if (sub.automatic) loadFrame(s, sub.first, sub.count, saved);
    for (outs, ports, 0..) |o, slot, k| if (o) |v| {
        const arg = p.extraData(Program.Arg, c.args.start + @as(u32, @intCast(4 * k)));
        try eval.put(s, a, arg.place, try convertValue(a, v, p.slots.items(.ty)[slot].real, arg.ty), false, null);
    };
    if (s.unwind == c.sub and s.sub_active[c.sub] == 0) s.unwind = null;
    return result;
}

/// §10.2.2 an inlined enable's copy-out (`Program.CopyOut` at `at`): the
/// formal converted and written to the caller's lvalue.
pub fn copyOut(s: *State, a: Allocator, at: u32) Error!void {
    const c = s.p.extraData(Program.CopyOut, at);
    const v = try eval.read(s, a, c.slot);
    try eval.put(s, a, c.place, try convertValue(a, v, s.p.slots.items(.ty)[c.slot].real, c.ty), false, null);
}

/// `v`, a real's bits when `from_real`, converted for an assignment to
/// `target` (§4.8.2): a real rounds to an integer, an integer becomes a
/// real, an integer extends by its own signedness or truncates.
pub fn convertValue(a: Allocator, v: Literal, from_real: bool, target: Program.Ty) Error!Literal {
    if (target.real) return if (from_real) v else logic.realLiteral(a, logic.realOfInt(v));
    const i = if (from_real) try logic.intOfReal(a, logic.realOf(v)) else v;
    return logic.normalize(a, i, target.width, i.signed);
}

/// The words slots [first, first + count) take, both planes.
pub fn frameWords(s: *const State, first: u32, count: u32) usize {
    var n: usize = 0;
    for (first..first + count) |slot| n += 2 * Program.words(s.p.slots.items(.ty)[slot].width);
    return n;
}

/// Slots [first, first + count) into `out`, each slot's planes in turn.
pub fn saveFrame(s: *const State, first: u32, count: u32, out: []u64) void {
    assert(out.len == frameWords(s, first, count));
    var w: usize = 0;
    for (first..first + count) |slot| {
        const sl = s.p.slots.get(slot);
        const n = Program.words(sl.ty.width);
        @memcpy(out[w..][0..n], s.v[sl.word..][0..n]);
        @memcpy(out[w + n ..][0..n], s.x[sl.word..][0..n]);
        w += 2 * n;
    }
}

/// `saveFrame`'s inverse.
pub fn loadFrame(s: *State, first: u32, count: u32, from: []const u64) void {
    assert(from.len == frameWords(s, first, count));
    var w: usize = 0;
    for (first..first + count) |slot| {
        const sl = s.p.slots.get(slot);
        const n = Program.words(sl.ty.width);
        @memcpy(s.v[sl.word..][0..n], from[w..][0..n]);
        @memcpy(s.x[sl.word..][0..n], from[w + n ..][0..n]);
        w += 2 * n;
    }
}

/// §10.2.3 slots [first, first + count) as entering their scope leaves
/// them: x, or 0.0 for a real.
pub fn resetFrame(s: *State, first: u32, count: u32) void {
    for (first..first + count) |slot| {
        const sl = s.p.slots.get(slot);
        const n = Program.words(sl.ty.width);
        @memset(s.v[sl.word..][0..n], 0);
        @memset(s.x[sl.word..][0..n], 0);
        if (sl.ty.real) continue;
        for (0..n) |i| {
            const m = logic.wordMask(sl.ty.width, i);
            s.v[sl.word + i] = m;
            s.x[sl.word + i] = m;
        }
    }
}

/// The evaluated inputs into their ports' slots (no change is published:
/// an activation's formals are its own).
pub fn copyIn(s: *State, inputs: []const ?Literal, ports: []const u32) void {
    assert(inputs.len == ports.len);
    for (inputs, ports) |in, slot| if (in) |v| {
        const sl = s.p.slots.get(slot);
        const n = Program.words(sl.ty.width);
        @memcpy(s.v[sl.word..][0..n], v.values());
        @memcpy(s.x[sl.word..][0..n], v.unknowns());
    };
}

/// `v` with planes of its own.
pub fn copy(a: Allocator, v: Literal) Error!Literal {
    var out = v;
    out.planes = try a.dupe(u64, v.planes);
    return out;
}
