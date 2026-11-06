//! The one reader of the files a compilation's stages name: an `include, a
//! netlist's `.INCLUDE`/`.LIB`/`.HDL`, a §9.21.1 `$table_model` data file.
//! The compilation owns it (made from its `io`) and hands it to each stage;
//! a stage resolves a name by its own clause's search order and reads
//! through `read`, so no stage holds an `io`. `paths` lists every file read,
//! in order: the inputs a cache of the compilation keys on (Zig's
//! `Cache.Manifest.addFilePath`).
//!
//! Contents:
//! - fields `io: std.Io`, `arena: Allocator`, `paths: std.ArrayList([]const u8)`
//! - `pub fn init(io: std.Io, arena: Allocator) Files`
//! - `pub fn read(f: *Files, path: []const u8, max: usize) preprocessor.ReadError![]u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const preprocessor = @import("preprocessor.zig");

io: std.Io,
/// Owns every file's bytes and every recorded path.
arena: Allocator,
/// Every path `read` returned bytes for, in order.
paths: std.ArrayList([]const u8) = .empty,

const Files = @This();

pub fn init(io: std.Io, arena: Allocator) Files {
    return .{ .io = io, .arena = arena };
}

/// Reads the whole file at `path`, relative to the working directory, into
/// `f.arena`, and records `path`. At most `max` bytes: past them
/// `error.StreamTooLong` (`preprocessor.max_text_bytes` for text a lexer
/// addresses, `maxInt(usize)` for a data file). Fails as
/// `preprocessor.readText` does; a failed read records nothing.
pub fn read(f: *Files, path: []const u8, max: usize) preprocessor.ReadError![]u8 {
    const n = f.paths.items.len;
    const text = try preprocessor.readTextLimited(f.io, .cwd(), path, f.arena, max);
    try f.paths.append(f.arena, try f.arena.dupe(u8, path));
    assert(f.paths.items.len == n + 1);
    assert(text.len <= max);
    return text;
}

test "read: records each file read, in order, and nothing for a failed one" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}/a.vams", .{tmp.sub_path});
    try tmp.dir.writeFile(io, .{ .sub_path = "a.vams", .data = "`define A 1\n" });
    var f: Files = .init(io, arena.allocator());
    try std.testing.expectEqualStrings("`define A 1\n", try f.read(a, preprocessor.max_text_bytes));
    try std.testing.expectError(error.FileNotFound, f.read("", preprocessor.max_text_bytes));
    try std.testing.expectError(error.StreamTooLong, f.read(a, 4));
    try std.testing.expectEqual(@as(usize, 1), f.paths.items.len);
    try std.testing.expectEqualStrings(a, f.paths.items[0]);
}
