//! The diagnostics of one compilation: coded rows in (from every stage,
//! through `Wip`), terminal text, JSON Lines and `--explain` entries out.
//! Zig's `std.zig.ErrorBundle` layout, with the columns VerA adds.
//!
//! Cites no LRM clause: each code's catalogue row cites its own.
//!
//! Contents:
//! - catalogue: `Code`, `Info`, `info`

const code = @import("Diag/code.zig");

/// Every diagnosable condition; see `Diag/code.zig`.
pub const Code = code.Code;
/// A code's title, LRM clause and `--explain` text.
pub const Info = code.Info;
/// Returns a code's catalogue row.
pub const info = code.info;

test {
    _ = code;
}
