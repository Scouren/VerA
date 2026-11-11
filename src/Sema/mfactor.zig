//! §6.3.6 `$mfactor` scaling: an instance's multiplicity over the top's
//! in, the factor a flow contribution is multiplied by and a flow probe
//! divided by out.
//! Cites: VAMS-2023 §6.3.6.
//!
//! Contents:
//! - `pub fn mfactorOf(s: *const Sema, unit: *const Sema.Unit) f64`
//! - `pub fn scaled(s: *Sema, b: *Block, v: Ref, m: f64, div: bool) Allocator.Error!Ref`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Air = @import("air");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const expr = @import("expr.zig");
const Block = Sema.Block;
const Ref = Air.Inst.Ref;

/// §6.3.6 the `$mfactor` `unit`'s instance has over the top's (whose own
/// stays with the host): 1 for the top and for a value that did not fold.
pub fn mfactorOf(s: *const Sema, unit: *const Sema.Unit) f64 {
    const hiers = s.zcu.instances.items(.hier);
    const top = s.units.items[0].instance;
    assert(@backingInt(unit.instance) < hiers.len);
    if (unit.instance == top) return 1;
    const ip = &s.zcu.intern_pool;
    const here = switch (ip.indexToKey(hiers[@backingInt(unit.instance)].get(.mfactor))) {
        .float => |f| f,
        else => return 1, // else: did not fold (E0890 was raised)
    };
    const at_top = switch (ip.indexToKey(hiers[@backingInt(top)].get(.mfactor))) {
        .float => |f| f,
        else => return 1, // else: as above
    };
    return here / at_top;
}

/// `v` scaled by `m` (`fmul`, or `fdiv` when `div`); `v` itself at 1.
pub fn scaled(s: *Sema, b: *Block, v: Ref, m: f64, div: bool) Allocator.Error!Ref {
    if (m == 1) return v;
    return expr.binOp(s, b, if (div) .fdiv else .fmul, v, .fromIntern(try decl.intern(s, .{ .real = m })));
}
