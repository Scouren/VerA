//! §6.3.6 `$mfactor` scaling: an instance's multiplicity over the top's
//! in, the factor a flow contribution is multiplied by and a flow probe
//! divided by out. Also §9.18 Table 9-29's general hierarchical-system-
//! parameter composition (D2-J), which `syscall.zig`'s `hierRead` shares:
//! the already-folded ratio when elaboration composed it, else a run-time
//! instruction composed from `Zcu.hier_srcs`.
//! Cites: VAMS-2023 §6.3.6, §9.18.
//!
//! Contents:
//! - `pub fn mfactorRef(s: *Sema, b: *Block, unit: *const Sema.Unit) Allocator.Error!Ref`
//! - `pub fn hierRef(s: *Sema, b: *Block, instance: Zcu.Instance.Index, k: Zcu.SystemParam) Allocator.Error!Ref`
//! - `pub fn scaled(s: *Sema, b: *Block, v: Ref, m: Ref, div: bool) Allocator.Error!Ref`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const InternPool = @import("intern_pool");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const Zcu = @import("../Zcu.zig");
const decl = @import("decl.zig");
const expr = @import("expr.zig");
const Block = Sema.Block;
const Unit = Sema.Unit;
const Ref = Air.Inst.Ref;

/// The deepest instance nesting `hierRef` follows: the elaborated tree is
/// acyclic and far shallower than this (`cycle.zig`'s own bound), so going
/// past it is a bug, not a design this deep.
const tree_depth_max: u32 = 1 << 16;

/// §6.3.6 the `$mfactor` `unit`'s instance has over the top's (whose own
/// stays with the host): 1 for the top.
pub fn mfactorRef(s: *Sema, b: *Block, unit: *const Unit) Allocator.Error!Ref {
    const top = s.units.items[0].instance;
    if (unit.instance == top) return .fromIntern(.one_real);
    assert(@backingInt(unit.instance) < s.zcu.instances.len);
    const here = try hierRef(s, b, unit.instance, .mfactor);
    const at_top = try hierRef(s, b, top, .mfactor);
    return expr.binOp(s, b, .fdiv, here, at_top);
}

/// §9.18 Table 9-29 `instance`'s own hierarchical system parameter `k`,
/// fully composed from the root: the elaboration-folded constant when it
/// folded, else (D2-J) `instance`'s own `hier_srcs` expression (or, absent
/// one, Table 9-29's identity) composed with the parent's (recursive) ref
/// by `k`'s operator.
pub fn hierRef(s: *Sema, b: *Block, instance: Zcu.Instance.Index, k: Zcu.SystemParam) Allocator.Error!Ref {
    return hierRefDepth(s, b, instance, k, 0);
}

/// `v` scaled by `m` (`fmul`, or `fdiv` when `div`); `v` itself when `m` is
/// the identity 1 (no residue: `expr.binOp` would fold it right back, this
/// just skips minting the instruction).
pub fn scaled(s: *Sema, b: *Block, v: Ref, m: Ref, div: bool) Allocator.Error!Ref {
    if (expr.constOf(s, m)) |c| if (c.asReal() == 1) return v;
    return expr.binOp(s, b, if (div) .fdiv else .fmul, v, m);
}

// ---- private ----

fn hierRefDepth(s: *Sema, b: *Block, instance: Zcu.Instance.Index, k: Zcu.SystemParam, depth: u32) Allocator.Error!Ref {
    assert(depth <= tree_depth_max);
    assert(@backingInt(instance) < s.zcu.instances.len);
    const folded = s.zcu.instances.items(.hier)[@backingInt(instance)].get(k);
    if (folded != InternPool.Index.undef) return .fromIntern(folded);
    const parent = s.zcu.instances.items(.parent)[@backingInt(instance)];
    // The top's own hier failing to fold is out of this task's scope (its
    // `hier_srcs` case is unplanned, §3 L0a's note on `--param` CLI
    // overrides); fall back to the identity, the same answer the old
    // `hierRead`/`mfactorOf` gave for any unfoldable hier read.
    if (parent == .none) return .fromIntern(try decl.intern(s, .{ .real = k.initial() }));
    const up = try hierRefDepth(s, b, parent, k, depth + 1);
    const own = try ownRef(s, b, instance, k);
    return compose(s, b, k, up, own);
}

/// `instance`'s own (not composed with its parent's) value of `k`: its
/// `hier_srcs` row lowered in the parent's scope when it did not fold at
/// elaboration, else Table 9-29's identity (nothing new specified here, or
/// a value that folded and is already inside the parent's `up`... no: a
/// folding own value is read back from `hierRefDepth`'s fast path at the
/// level it was specified, never from here).
fn ownRef(s: *Sema, b: *Block, instance: Zcu.Instance.Index, k: Zcu.SystemParam) Allocator.Error!Ref {
    for (s.zcu.hier_srcs.items) |row| if (row.instance == instance and row.kind == k) {
        const parent = s.zcu.instances.items(.parent)[@backingInt(instance)];
        const saved = b.unit;
        defer b.unit = saved;
        b.unit = unitOf(s, parent);
        const v = try expr.lower(s, b, row.value);
        return expr.coerce(s, b, v, .real);
    };
    return .fromIntern(try decl.intern(s, .{ .real = k.initial() }));
}

/// The already-made `Unit` of instance `i`: every non-primitive ancestor
/// has one (`decl.zig`'s `units`).
fn unitOf(s: *Sema, i: Zcu.Instance.Index) *Unit {
    for (s.units.items) |*u| if (u.instance == i) return u;
    unreachable; // a parent of a unit is always a unit itself
}

/// §9.18 Table 9-29's operator composing a parent's `up` with its child's
/// own `own`: a sum for the positions, a sum modulo 360 for `$angle`
/// (mirroring `walk.hierValues`' per-level `@rem`), a product for the
/// flips and `$mfactor`.
/// ponytail: `.fmod` truncates (C `fmod`/`@rem`), so this only matches
/// `walk.hierValues`' own per-level wrap while the running angle sum stays
/// non-negative; a floored-mod kernel is the upgrade for a design whose
/// intermediate angle goes negative while also reading the card.
fn compose(s: *Sema, b: *Block, k: Zcu.SystemParam, up: Ref, own: Ref) Allocator.Error!Ref {
    return switch (k) {
        .xposition, .yposition => expr.binOp(s, b, .fadd, up, own),
        .angle => expr.binOp(s, b, .fmod, try expr.binOp(s, b, .fadd, up, own), .fromIntern(try decl.intern(s, .{ .real = 360 }))),
        .hflip, .vflip, .mfactor => expr.binOp(s, b, .fmul, up, own),
    };
}
