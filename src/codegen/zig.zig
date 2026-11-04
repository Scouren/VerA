//! The Zig backend (Zig's `codegen/c.zig`, named for the language it
//! emits): one analysed device in, its Zig source out. `Liveness` first
//! (the lanes and uses of every value), then `DeclGen` writes the file and
//! `Function` the one body. Cites the clauses its files cite.
//!
//! Contents:
//! - `pub const DeclGen`, `pub const Function`, `pub const Liveness`, `pub const Ident`
//! - `pub fn generate(gpa: Allocator, in: codegen.Input, options: codegen.Options) Allocator.Error!codegen.Result`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const codegen = @import("../codegen.zig");
/// The device-lifetime state and the file's declarations.
pub const DeclGen = @import("zig/DeclGen.zig");
/// One body's statements.
pub const Function = @import("zig/Function.zig");
/// The lanes and uses of every value.
pub const Liveness = @import("zig/Liveness.zig");
/// A Verilog-A name as the ABI's Zig identifier.
pub const Ident = @import("zig/Ident.zig");

/// Writes `in`'s device. The text in `.ok` is `gpa`'s; a `.fail` names
/// what this backend does not spell yet, also in `gpa`.
pub fn generate(gpa: Allocator, in: codegen.Input, options: codegen.Options) Allocator.Error!codegen.Result {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const live = Liveness.init(arena, in.air.*, @intCast(in.device.nodes.len)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooManyUnknowns => return .{ .fail = try std.fmt.allocPrint(gpa, "more than {d} unknowns", .{Liveness.unknowns_max}) },
    };
    var dg: DeclGen = .{
        .gpa = gpa,
        .arena = arena,
        .air = in.air,
        .ip = in.ip,
        .device = in.device,
        .verdict = in.verdict,
        .live = live,
        .options = .{ .strict = options.strict },
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    dg.genFile(&out.writer) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CodegenFail => return .{ .fail = try gpa.dupe(u8, dg.failure.?) },
    };
    const text = try out.toOwnedSlice();
    assert(text.len != 0);
    return .{ .ok = .{ .text = text } };
}

test {
    _ = DeclGen;
    _ = Function;
    _ = Liveness;
    _ = Ident;
    _ = @import("zig/stamps.zig");
    _ = @import("zig/state.zig");
    _ = @import("zig/calls.zig");
}
