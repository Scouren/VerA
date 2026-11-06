//! The RTLIL text of a lowered design (stub).
//!
//! Contents:
//! - `pub fn emit(w: *std.Io.Writer, arena: std.mem.Allocator, l: *const sema.digital.Lowered) !void`

const std = @import("std");
const sema = @import("sema");

/// Writes `l`'s RTLIL to `w`.
pub fn emit(w: *std.Io.Writer, arena: std.mem.Allocator, l: *const sema.digital.Lowered) !void {
    _ = arena;
    _ = l;
    try w.writeAll("autoidx 1\n");
}
