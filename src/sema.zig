//! The `sema` module: the files' Vir in, the elaborated design out as
//! `Zcu` tables (docs/rewrite/elab.md). Re-exports only.
//! Cites no LRM clause: each file cites its own.
//!
//! Contents:
//! - `pub const Zcu`
//! - `pub const Sema`
//! - `pub const digital`
//! - `pub const fold`
//! - `pub const locate`

/// The compilation unit's tables.
pub const Zcu = @import("Zcu.zig");
/// Elaboration over a `Zcu`.
pub const Sema = @import("Sema.zig");
/// The digital lowering: the elaborated design as one `std_sim.Program`.
pub const digital = @import("Sema/digital.zig");
/// Emit-time constant folding of Air value tags (diff-kernels holds it to
/// the device's kernels).
pub const fold = @import("Sema/fold.zig");
/// Where an instruction or a part of one was written, as a token.
pub const locate = @import("Sema/locate.zig");

test {
    _ = Zcu;
    _ = Sema;
    _ = digital;
    _ = @import("Sema/eval.zig");
    _ = @import("Sema/eval_fn.zig");
    _ = @import("Sema/sign.zig");
    _ = @import("Sema/walk.zig");
    _ = @import("Sema/defparam.zig");
    _ = @import("Sema/paramset.zig");
    _ = @import("Sema/dist.zig");
    _ = @import("Sema/checks.zig");
    _ = @import("Sema/discipline.zig");
    _ = @import("Sema/connect.zig");
    _ = @import("Sema/resolve.zig");
    _ = @import("Sema/test.zig");
    _ = @import("Sema/decl.zig");
    _ = @import("Sema/expr.zig");
    _ = @import("Sema/control.zig");
    _ = @import("Sema/contrib.zig");
    _ = @import("Sema/access.zig");
    _ = @import("Sema/indirect.zig");
    _ = @import("Sema/mfactor.zig");
    _ = @import("Sema/condbr.zig");
    _ = @import("Sema/branch.zig");
    _ = @import("Sema/portbind.zig");
    _ = @import("Sema/param_paramset.zig");
    _ = @import("Sema/param_check.zig");
    _ = @import("Sema/held_writes.zig");
    _ = @import("Sema/syscall.zig");
    _ = @import("Sema/held.zig");
    _ = @import("Sema/func.zig");
    _ = @import("Sema/op.zig");
    _ = @import("Sema/param.zig");
    _ = @import("Sema/array.zig");
    _ = @import("Sema/param_test.zig");
    _ = @import("Sema/derive_test.zig");
    _ = @import("Sema/lower_test.zig");
    _ = @import("Sema/digital_test.zig");
    _ = @import("Sema/digital/sites_test.zig");
}
