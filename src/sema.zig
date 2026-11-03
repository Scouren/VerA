//! The `sema` module: the files' Vir in, the elaborated design out as
//! `Zcu` tables (docs/rewrite/elab.md). Re-exports only.
//! Cites no LRM clause: each file cites its own.
//!
//! Contents:
//! - `pub const Zcu`
//! - `pub const Sema`

/// The compilation unit's tables.
pub const Zcu = @import("Zcu.zig");
/// Elaboration over a `Zcu`.
pub const Sema = @import("Sema.zig");

test {
    _ = Zcu;
    _ = Sema;
    _ = @import("Sema/eval.zig");
    _ = @import("Sema/walk.zig");
    _ = @import("Sema/defparam.zig");
    _ = @import("Sema/paramset.zig");
    _ = @import("Sema/checks.zig");
    _ = @import("Sema/discipline.zig");
    _ = @import("Sema/connect.zig");
    _ = @import("Sema/test.zig");
    _ = @import("Sema/decl.zig");
    _ = @import("Sema/expr.zig");
    _ = @import("Sema/control.zig");
    _ = @import("Sema/contrib.zig");
    _ = @import("Sema/syscall.zig");
}
