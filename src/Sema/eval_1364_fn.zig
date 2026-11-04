//! The constant functions of the comptime evaluator's IEEE 1364 mode
//! (`eval_1364.zig`): a §10.4.5 constant function's call in, its result
//! out, its body run over values of its declared types: assignments (to a
//! variable or a constant select of one), blocks, `if`, `case`/`casez`/
//! `casex`, loops and `repeat`; a system task is ignored, any other
//! statement (a timing control, a task enable, a nonblocking assignment)
//! leaves the call without a value.
//! Cites: IEEE 1364-2005 §9.5, §10.4.5.
//!
//! Contents:
//! - `pub fn call(e: *Eval, i: Inst.Index) Allocator.Error!?Lit`
//! - `pub fn declaredType(e: *Eval, body: Vir.Body, d: Inst.Index) Allocator.Error!?Type`
//! - `pub fn locals(e: *Eval, body: Vir.Body, fr: *Frame) Allocator.Error!void`
//! - `pub fn unknown(e: *Eval, t: Type) Allocator.Error!Lit`
//! - `pub fn run(e: *Eval, body: Vir.Body, depth: u32) Allocator.Error!bool`
//! - `pub fn statement(e: *Eval, i: Inst.Index, depth: u32) Allocator.Error!bool`
//! - `pub fn caseStmt(e: *Eval, i: Inst.Index, depth: u32) Allocator.Error!bool`
//! - `pub fn store(e: *Eval, lhs: Inst.Ref, rhs: Inst.Ref) Allocator.Error!bool`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const kernels = @import("kernels");
const e4 = @import("eval_1364.zig");
const Eval = e4.Eval;
const Frame = e4.Frame;
const Type = e4.Type;
const Lit = kernels.Integer.Literal;
const Vir = vams.Vir;
const Inst = Vir.Inst;
const setBit = e4.setBit;
const common = e4.common;
const steps_max = e4.steps_max;

/// §10.4.5 a constant function's call: its inputs bound, its body run,
/// its result.
pub fn call(e: *Eval, i: Inst.Index) Allocator.Error!?Lit {
    const f = e.callee(i) orelse return null;
    const fp = e.payload(Inst.Function, f);
    const args = e.vir().list(Inst.Ref, e.payload(Inst.Call, i).args);
    const formals = e.vir().body(fp.formals);
    if (args.len != formals.len) return null;
    var fr: Frame = .{};
    const rt = (try e.resultType(f)) orelse return null;
    if (rt.real) return null;
    try fr.types.put(e.a, f, rt);
    try fr.vars.put(e.a, f, try unknown(e, rt));
    // The inputs, evaluated in the caller.
    for (args, formals) |a, d| {
        const io = e.payload(Inst.Io, d);
        if (io.flags.dir != .input) return null;
        const t = try declaredType(e, fp.body, d) orelse return null;
        const v = (try e.self(a)) orelse return null;
        try fr.types.put(e.a, d, t);
        try fr.vars.put(e.a, d, (try e.fit(v, t)) orelse return null);
    }
    try locals(e, fp.body, &fr);
    const saved = e.frame;
    e.frame = &fr;
    defer e.frame = saved;
    if (!try run(e, fp.body, 0)) return null;
    return fr.vars.get(f);
}

/// A formal's type: its `io`'s, completed by a later `reg`/`integer`
/// declaration of it in `body`.
pub fn declaredType(e: *Eval, body: Vir.Body, d: Inst.Index) Allocator.Error!?Type {
    const io = e.payload(Inst.Io, d);
    var range = io.range;
    var storage = io.flags.storage;
    var signed = io.flags.signed;
    for (e.vir().body(body)) |x| if (e.tag(x) == .variable) {
        const v = e.payload(Inst.Variable, x);
        if (v.prev.toIndex() != d) continue;
        if (range.len == 0) range = v.range;
        if (v.flags.storage != .none) storage = v.flags.storage;
        signed = signed or v.flags.signed;
    };
    const t = (try e.varType(range, storage, signed)) orelse return null;
    return if (t.real) null else t;
}

/// The variables a body declares (a named block's too), each x.
pub fn locals(e: *Eval, body: Vir.Body, fr: *Frame) Allocator.Error!void {
    for (e.vir().body(body)) |x| switch (e.tag(x)) {
        .variable => {
            const v = e.payload(Inst.Variable, x);
            if (v.prev.toIndex() != null) continue;
            const t = (try e.varType(v.range, v.flags.storage, v.flags.signed)) orelse continue;
            if (t.real) continue;
            try fr.types.put(e.a, x, t);
            try fr.vars.put(e.a, x, try unknown(e, t));
        },
        .block => try locals(e, e.payload(Inst.Block, x).body, fr),
        else => {}, // else: a statement or an expression declares nothing
    };
}

pub fn unknown(e: *Eval, t: Type) Allocator.Error!Lit {
    const out = try e.alloc(t.width, t.signed);
    for (0..t.width) |k| setBit(out, @intCast(k), .x);
    return out;
}

/// Runs the statements of `body`; false when one has no constant
/// meaning (or the budget runs out).
pub fn run(e: *Eval, body: Vir.Body, depth: u32) Allocator.Error!bool {
    if (depth > 1 << 10) return false;
    for (e.vir().body(body)) |i| {
        e.steps += 1;
        if (e.steps > steps_max) return false;
        if (!try statement(e, i, depth)) return false;
    }
    return true;
}

pub fn statement(e: *Eval, i: Inst.Index, depth: u32) Allocator.Error!bool {
    switch (e.tag(i)) {
        .block => return run(e, e.payload(Inst.Block, i).body, depth + 1),
        .store => {
            const b = e.payload(Inst.Bin, i);
            return store(e, b.lhs, b.rhs);
        },
        .condbr => {
            const c = e.payload(Inst.CondBr, i);
            const v = (try e.self(c.cond)) orelse return false;
            return run(e, if (v.truth() == .one) c.then else c.@"else", depth + 1);
        },
        .loop => {
            const lp = e.payload(Inst.Loop, i);
            while (true) {
                e.steps += 1;
                if (e.steps > steps_max) return false;
                if (lp.cond.len != 0) {
                    const cb = e.vir().body(lp.cond);
                    const v = (try e.self(cb[cb.len - 1].toRef())) orelse return false;
                    if (v.truth() != .one) return true;
                }
                if (!try run(e, lp.body, depth + 1)) return false;
                if (!try run(e, lp.step, depth + 1)) return false;
            }
        },
        .repeat => {
            const rp = e.payload(Inst.Repeat, i);
            const n = (try e.self(rp.count)) orelse return false;
            const times = n.asIndex() orelse 0;
            var k: i128 = 0;
            while (k < times) : (k += 1) if (!try run(e, rp.body, depth + 1)) return false;
            return true;
        },
        .case => return caseStmt(e, i, depth),
        // §10.4.5 a system task in a constant function is ignored.
        .call_sys => return true,
        .delay, .event_wait, .wait, .store_nb, .store_timed, .store_nb_timed, .call, .trigger, .disable, .proc_assign, .force, .deassign, .release, .ret, .brk, .cont => return false,
        else => return true, // else: a declaration, or an expression a statement reads
    }
}

/// §9.5 a case statement: the first arm whose label matches (`casez`
/// and `casex` reading their wildcard bits as matching any), else the
/// default.
pub fn caseStmt(e: *Eval, i: Inst.Index, depth: u32) Allocator.Error!bool {
    const c = e.payload(Inst.Case, i);
    const arms = e.vir().list(Inst.Arm, c.arms);
    var t = (try e.typeOf(c.operand)) orelse return false;
    for (arms) |arm| for (e.vir().list(Inst.Ref, arm.values)) |v| {
        t = common(t, (try e.typeOf(v)) orelse return false);
    };
    const x = (try e.ctx(c.operand, t)) orelse return false;
    var default: ?Vir.Body = null;
    for (arms) |arm| {
        if (arm.flags.default or arm.values.len == 0) default = arm.body;
        for (e.vir().list(Inst.Ref, arm.values)) |v| {
            const y = (try e.ctx(v, t)) orelse return false;
            if (matches(x, y, c.flags.kind)) return run(e, arm.body, depth + 1);
        }
    }
    return if (default) |b| run(e, b, depth + 1) else true;
}

/// An assignment in a constant function: to a variable, or a constant
/// bit- or part-select of one.
pub fn store(e: *Eval, lhs: Inst.Ref, rhs: Inst.Ref) Allocator.Error!bool {
    const fr = e.frame orelse return false;
    const li = lhs.toIndex() orelse return false;
    switch (e.tag(li)) {
        .decl_ref => {
            const d = e.vir().instructions.items(.data)[@backingInt(li)].decl_tok.decl;
            const t = fr.types.get(d) orelse return false;
            const rt = (try e.typeOf(rhs)) orelse return false;
            const v = (try e.ctx(rhs, .{ .width = @max(t.width, rt.width), .signed = rt.signed })) orelse return false;
            try fr.vars.put(e.a, d, (try e.fit(v, t)) orelse return false);
            return true;
        },
        .elem, .slice, .slice_up, .slice_down => {
            const s = (try e.select(li)) orelse return false;
            const base_ref = if (e.tag(li) == .elem) e.payload(Inst.Bin, li).lhs else e.payload(Inst.Triple, li).a;
            const d = e.vir().instructions.items(.data)[@backingInt(base_ref.toIndex().?)].decl_tok.decl;
            if (!fr.vars.contains(d)) return false;
            const v = (try e.fit((try e.self(rhs)) orelse return false, .{ .width = s.width, .signed = false })) orelse return false;
            const out = try e.alloc(s.base.width, s.base.signed);
            for (0..s.base.width) |k| setBit(out, @intCast(k), s.base.bit(@intCast(k)));
            for (0..s.width) |k| {
                const at = s.first + @as(i64, @intCast(k));
                if (at >= 0 and at < s.base.width) setBit(out, @intCast(at), v.bit(@intCast(k)));
            }
            try fr.vars.put(e.a, d, out);
            return true;
        },
        else => return false, // else: no other lvalue in a constant function
    }
}

// ---- private ----

/// §9.5 whether case label `y` matches `x`: bit for bit, x and z included
/// (`case`); a z (and `?`) in either matching any bit (`casez`); an x or z
/// in either matching any bit (`casex`).
fn matches(x: Lit, y: Lit, kind: anytype) bool {
    assert(x.width == y.width);
    for (0..x.width) |k| {
        const a = x.bit(@intCast(k));
        const b = y.bit(@intCast(k));
        const wild = switch (kind) {
            .case => false,
            .casez => a == .z or b == .z,
            .casex => a == .z or b == .z or a == .x or b == .x,
        };
        if (!wild and a != b) return false;
    }
    return true;
}
