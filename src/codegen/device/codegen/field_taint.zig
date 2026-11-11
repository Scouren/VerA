//! Per-`Instance`-field dataflow over the Mir SSA graph (#134's correction):
//! does perturbing one field change a value (`val`), and does it change that
//! value's DERIVATIVE wrt some real unknown (`deriv`)? A field read is a
//! constant wrt every unknown (`deriv = false` at its own leaf), so it
//! enters a derivative lane only through a product (or another nonlinear
//! combination) with an operand that already has one — `Analysis.dFree`
//! (`active` below) names that operand, exactly how a dual number's
//! derivative lane only ever grows through a multiply against a nonzero
//! one. `transferBinary`'s `fmul` rule is the one the correction is about:
//! `(a.val and active(rhs)) or (b.val and active(lhs))`, never the looser
//! `(a.val or b.val) and (active(lhs) or active(rhs))`, which would also
//! fire when a field is only ADDED beside an x-dependent term and multiplied
//! by a model constant — exactly the charge-only latch the correction says
//! must come out `jac`-clear.
//!
//! Scope: §5.6.1.2 path latches (`pb__k`/`pq__k`, `pathLeaves`), scalar
//! §5.10 held variables and `$limit$old` (`limiter_previous`, one Instance
//! field shared by every slot) — `field_use.zig` dispatches to this pass by
//! field name and keeps its own text scan for everything else (array-backed
//! held state, string-held state, every per-operator history field).
//!
//! Contents:
//! - `pub const Bits = struct`
//! - `pub fn pathLeaves(gen: *const Gen, arena: Allocator, acc: bool, k: u32) Error![]const Mir.Value`
//! - `pub fn compute(gen: *const Gen, arena: Allocator, leaves: []const Mir.Value) Error!Taint`
//! - `pub fn sinks(gen: *const Gen, t: *const Taint) Bits`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Analysis = @import("prove").Analysis;
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const Error = codegen.Error;

/// The five outputs §134's `FieldUse` doc describes as dataflow (`res`,
/// `jac`, `q`, `limit`, `state`); `w_update`/`w_commit` are mechanical
/// (which entry point's rendered text assigns the field) and stay
/// `field_use.zig`'s text scan.
pub const Bits = struct {
    res: bool = false,
    jac: bool = false,
    q: bool = false,
    limit: bool = false,
    state: bool = false,
};

/// Per-Value taint wrt one field, `an.nv` long.
pub const Taint = struct {
    val: []bool,
    deriv: []bool,
};

/// Every result Value of a `path_prev` (`acc = false`) or `path_acc`
/// (`acc = true`) instruction whose rv-resolved operand is `gen.core`'s
/// `k`-th latch (`plan/core.zig`'s `prev_vals`/`acc_vals`, the same `k` that
/// numbers `Instance.pb__k`/`pq__k`): every raw occurrence the CSE dedup
/// folded into that one latch is its own read site, and so its own leaf.
pub fn pathLeaves(gen: *const Gen, arena: Allocator, acc: bool, k: u32) Error![]const Mir.Value {
    const want = if (acc) gen.core.acc_vals[k] else gen.core.prev_vals[k];
    const op: Mir.Opcode = if (acc) .path_acc else .path_prev;
    const mir = gen.mir;
    var out: std.ArrayList(Mir.Value) = .empty;
    const n = mir.instCount();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const inst: Mir.Inst = @fromBackingInt(i);
        if (mir.instOp(inst) != op) continue;
        if (gen.an.rv(mir.instData(inst).unary.operand) != want) continue;
        try out.append(arena, mir.instResult(inst));
    }
    assert(out.items.len != 0); // `k` named a latch `plan/core.zig` actually found
    return out.items;
}

/// Computes `Taint` over the whole graph, seeded at `leaves` (every read
/// site of one field): `val = true`, `deriv = false` there. Monotone
/// OR-fixpoint (bits only grow), bounded by twice the value count: each
/// value flips at most two bits (`val` then `deriv`) over the whole run.
pub fn compute(gen: *const Gen, arena: Allocator, leaves: []const Mir.Value) Error!Taint {
    const an = gen.an;
    const nv = an.nv;
    const t: Taint = .{
        .val = try arena.alloc(bool, nv),
        .deriv = try arena.alloc(bool, nv),
    };
    @memset(t.val, false);
    @memset(t.deriv, false);
    const is_leaf = try arena.alloc(bool, nv);
    @memset(is_leaf, false);
    for (leaves) |l0| {
        const l: usize = @backingInt(an.rv(l0));
        assert(l < nv);
        is_leaf[l] = true;
        t.val[l] = true;
    }
    const sweeps_max = @as(usize, nv) * 2 + 1;
    var sweeps: usize = 0;
    var changed = true;
    while (changed) : (sweeps += 1) {
        assert(sweeps < sweeps_max);
        changed = false;
        for (0..nv) |vi| {
            if (is_leaf[vi]) continue; // fixed: a field read, never recomputed
            const v: Mir.Value = @fromBackingInt(@intCast(vi));
            if (@as(usize, @backingInt(an.rv(v))) != vi) continue; // an alias settles to its target's row
            const r = transfer(gen, &t, v);
            if (r.val and !t.val[vi]) {
                t.val[vi] = true;
                changed = true;
            }
            if (r.deriv and !t.deriv[vi]) {
                t.deriv[vi] = true;
                changed = true;
            }
        }
    }
    assert(!changed);
    return t;
}

/// Reads the `Bits` off `t`: `jac` is `eval`'s OR `q`'s OWN derivative lane,
/// never `res or q` — the per-core-union bug #134's correction named, where
/// a charge-only field's `q` forced `jac` regardless of whether the field
/// ever reached a derivative at all.
pub fn sinks(gen: *const Gen, t: *const Taint) Bits {
    const an = gen.an;
    var b: Bits = .{};
    for (gen.lowered.contributions.items) |c| {
        const r = readTaint(t, an, c.resist_val);
        const q = readTaint(t, an, c.react_val);
        b.res = b.res or r.val;
        b.jac = b.jac or r.deriv or q.deriv;
        b.q = b.q or q.val;
    }
    for (gen.lowered.limit_slots.items) |slot| {
        const f = readTaint(t, an, slot.final);
        b.limit = b.limit or f.val;
        b.state = b.state or f.val;
    }
    for (gen.lowered.held_vars.items) |h| {
        if (h.array != .none or h.ty == .string) continue; // not this pass's scope
        const f = readTaint(t, an, h.final);
        b.state = b.state or f.val;
    }
    return b;
}

// ---- private: the per-opcode transfer ----

const Pair = struct { val: bool, deriv: bool };

fn readTaint(t: *const Taint, an: *const Analysis, v: Mir.Value) Pair {
    const i: usize = @backingInt(an.rv(v));
    return .{ .val = t.val[i], .deriv = t.deriv[i] };
}

/// Whether `v` already has a possibly-nonzero ORDINARY derivative wrt some
/// real unknown: the operand a product/quotient/chain cross term must pair
/// a field's own cross term against. `Analysis.dFree`, except a `path_prev`/
/// `path_acc` latch is always inactive regardless of what `Analysis.deps`
/// says about its OPERAND — the opcode's own doc ("gradient zero") is the
/// authority a reader renders by (`S.con(inst.pb__k)`, every lane zero);
/// `Analysis.deps` carries the operand's bits through a latch anyway
/// because `jac_pattern` (its other reader) tolerates the extra 1, which
/// `field_taint` cannot: an `active` that is true there could wrongly pair
/// with a DIFFERENT latch's own field cross term one multiply up and give
/// it `jac` it never earned.
fn active(an: *const Analysis, v: Mir.Value) bool {
    const r = an.rv(v);
    if (an.mir.valueDef(r) == .inst_result) {
        const op = an.mir.instOp(an.mir.valueDef(r).inst_result);
        if (op == .path_prev or op == .path_acc) return false;
    }
    return !an.dFree(v);
}

fn transfer(gen: *const Gen, t: *const Taint, v: Mir.Value) Pair {
    const mir = gen.mir;
    return switch (mir.valueDef(v)) {
        .undef, .float_const, .int_const, .str_const, .param_ref, .block_param => .{ .val = false, .deriv = false },
        .inst_result => |inst| transferInst(gen, t, inst),
    };
}

fn transferInst(gen: *const Gen, t: *const Taint, inst: Mir.Inst) Pair {
    const an = gen.an;
    const mir = gen.mir;
    return switch (mir.instData(inst)) {
        .unary => |u| transferUnary(an, t, u.op, u.operand),
        .binary => |b| transferBinary(an, t, b.op, b.lhs, b.rhs),
        .ternary => |tr| blk: {
            const c = readTaint(t, an, tr.cond);
            const a = readTaint(t, an, tr.then_val);
            const b = readTaint(t, an, tr.else_val);
            // §4.2.12: the condition steers which arm is taken (so it can
            // move the VALUE) but never enters the derivative, the same
            // treatment `Analysis.deps` gives it.
            break :blk .{ .val = c.val or a.val or b.val, .deriv = a.deriv or b.deriv };
        },
        .phi => |p| blk: {
            var r: Pair = .{ .val = false, .deriv = false };
            for (0..p.count) |k| {
                const pr = readTaint(t, an, mir.phiPair(inst, @intCast(k)).value);
                r.val = r.val or pr.val;
                r.deriv = r.deriv or pr.deriv;
            }
            break :blk r;
        },
        .call => |c| transferCall(an, t, c),
        .load => |l| blk: {
            const a = readTaint(t, an, l.arr);
            const idx = readTaint(t, an, l.index);
            break :blk .{ .val = a.val or idx.val, .deriv = a.deriv };
        },
        .store => |s| blk: {
            const a = readTaint(t, an, s.arr);
            const idx = readTaint(t, an, s.index);
            const sv = readTaint(t, an, s.value);
            break :blk .{ .val = a.val or idx.val or sv.val, .deriv = a.deriv or sv.deriv };
        },
        .anew, .branch, .jump => .{ .val = false, .deriv = false },
    };
}

fn transferCall(an: *const Analysis, t: *const Taint, c: anytype) Pair {
    return switch (c.callee) {
        // A fresh read of SOME per-instance slot, never a function of its
        // own call argument (an index/id): when it is a DIFFERENT field's
        // read than the one this pass seeded (its own occurrences are the
        // leaves `compute` fixes and never reaches this switch), it carries
        // none of THIS field's taint.
        .@"$held_real", .@"$held_int", .@"$held_str", .@"$held_wide", .@"$mfactor", .@"$limit$old" => .{ .val = false, .deriv = false },
        else => blk: {
            var r: Pair = .{ .val = false, .deriv = false };
            for (c.args) |a| {
                const pr = readTaint(t, an, a);
                r.val = r.val or pr.val;
                r.deriv = r.deriv or pr.deriv;
            }
            break :blk r;
        },
    };
}

fn transferUnary(an: *const Analysis, t: *const Taint, op: Mir.Opcode, a: Mir.Value) Pair {
    const pa = readTaint(t, an, a);
    return switch (op) {
        // A DIFFERENT field's latch (this field's own occurrences are
        // seeded leaves `compute` never recomputes): an independent read,
        // not a function of what it latches.
        .path_prev, .path_acc => .{ .val = false, .deriv = false },
        // The operand's value, every derivative lane zeroed — the opcode's
        // own doc.
        .dstop => .{ .val = pa.val, .deriv = false },
        // Chain rule: `f(a)`'s derivative is `f'(a)*a'`, so its mixed
        // partial wrt the field needs `a`'s OWN cross term paired with `a`'s
        // ordinary derivative — the one-operand shape of `fmul`'s rule.
        .sqrt, .exp, .expm1, .ln, .ln1p, .log10, .sin, .cos, .tan, .asin, .acos, .atan, .sinh, .cosh, .tanh, .asinh, .acosh, .atanh => .{
            .val = pa.val,
            .deriv = pa.deriv or (pa.val and active(an, a)),
        },
        // Linear in the operand (sign flip, bit/logical negate, round,
        // cast, the optimisation fence): no cross term.
        .fneg, .ineg, .lognot, .bitnot, .floor, .ceil, .fabs, .iabs, .fi_cast, .if_cast, .opt_barrier => .{ .val = pa.val, .deriv = pa.deriv },
        else => unreachable, // else: `instData`'s `.unary` variant decodes only an opcode whose `opcode.class` is `.unary` (`Mir.InstData`'s doc)
    };
}

fn transferBinary(an: *const Analysis, t: *const Taint, op: Mir.Opcode, lhs: Mir.Value, rhs: Mir.Value) Pair {
    const a = readTaint(t, an, lhs);
    const b = readTaint(t, an, rhs);
    return switch (op) {
        // Linear combination, a comparison/logical/bitwise/shift result (no
        // continuous derivative to begin with) or a `select`-shaped pick
        // (`fmin`/`fmax`: whichever operand wins passes its OWN derivative
        // through unchanged, no cross term from the picking): the union of
        // the operands, same as `Analysis.deps`' own "plain" rule already
        // gives every one of these.
        .fadd, .fsub, .iadd, .isub, .flt, .fgt, .fle, .fge, .feq, .fne, .ilt, .igt, .ile, .ige, .ieq, .ine, .logand, .logor, .bitand, .bitor, .bitxor, .bitxnor, .shl, .shr, .fmin, .fmax, .imin, .imax => .{
            .val = a.val or b.val,
            .deriv = a.deriv or b.deriv,
        },
        // Product rule: `c = a*b`, `dc/dx = a'b + ab'`. `d(dc/dx)/dfield`
        // gains a term only by pairing ONE operand's field cross term with
        // the OTHER operand's already-nonzero ordinary derivative — never
        // an operand paired with itself. The correction this file exists
        // for: the looser `(a.val or b.val) and (active(lhs) or
        // active(rhs))` would also fire when a field is added beside an
        // x-dependent term and the SUM is then multiplied by a model
        // constant, which is exactly the charge-only latch that must come
        // out `jac`-clear.
        .fmul, .imul => .{
            .val = a.val or b.val,
            .deriv = a.deriv or b.deriv or (a.val and active(an, rhs)) or (b.val and active(an, lhs)),
        },
        // Quotient rule: `c = a/b`, `dc/dx = (a'b - ab')/b^2`. `b`'s field
        // cross term can pair with EITHER operand's derivative (`b`
        // appears squared), `a`'s only with `b`'s: a sound superset of the
        // exact fraction, never looser than `fmul`'s.
        .fdiv, .idiv, .fmod, .imod => .{
            .val = a.val or b.val,
            .deriv = a.deriv or b.deriv or (a.val and active(an, rhs)) or (b.val and (active(an, lhs) or active(an, rhs))),
        },
        // `pow`/`hypot`/`atan2`: nonlinear in both operands at once
        // (`pow(a,b) = exp(b*ln(a))` differentiates through both). A sound,
        // looser-than-exact superset rather than deriving each one's own
        // chain rule — rare enough in a stamped device that the extra
        // reported `jac` costs a stamp, never a missing one.
        .pow, .hypot, .ipow, .atan2 => .{
            .val = a.val or b.val,
            .deriv = a.deriv or b.deriv or ((a.val or b.val) and (active(an, lhs) or active(an, rhs))),
        },
        else => unreachable, // else: `instData`'s `.binary` variant decodes only an opcode whose `opcode.class` is `.binary`
    };
}
