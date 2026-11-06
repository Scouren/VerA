//! A `Program` as bytes and back: what the compiler hands a built
//! executable (the §8 mixed runner embeds its digital half this way, so the
//! runner never elaborates). Every field is written by its type, field by
//! field and little-endian, never as raw struct bytes, so the same program
//! is the same bytes (no padding) on every host.
//! Cites: VAMS-2023 §8 (the digital half of a mixed run).
//!
//! Contents:
//! - `pub const LoadError`
//! - `pub fn save(p: *const Program, w: *std.Io.Writer) std.Io.Writer.Error!void`
//! - `pub fn load(arena: Allocator, bytes: []const u8) LoadError!Program`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Program = @import("Program.zig");

/// `load`'s failures: the bytes end early, a count or a tag is out of
/// range, or the arena runs out.
pub const LoadError = Allocator.Error || error{Corrupt};

/// Writes every field of `p`.
pub fn save(p: *const Program, w: *std.Io.Writer) std.Io.Writer.Error!void {
    inline for (@typeInfo(Program).@"struct".field_names) |name| try put(w, @field(p, name));
}

/// The `Program` `save` wrote into `bytes`, every slice in `arena`; free
/// the arena, never the program (no `Program.deinit`).
pub fn load(arena: Allocator, bytes: []const u8) LoadError!Program {
    var r: std.Io.Reader = .fixed(bytes);
    var p: Program = .{};
    const s = @typeInfo(Program).@"struct";
    inline for (s.field_names, s.field_types) |name, F| @field(p, name) = try get(F, arena, &r);
    if (r.seek != bytes.len) return error.Corrupt;
    return p;
}

// ---- private ----

fn isMulti(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Field") and @hasDecl(T, "Slice") and @hasField(T, "bytes");
}

fn put(w: *std.Io.Writer, v: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(v);
    if (comptime isMulti(T)) {
        try w.writeInt(u64, v.len, .little);
        for (0..v.len) |i| try put(w, v.get(i));
        return;
    }
    switch (@typeInfo(T)) {
        .void => {},
        .bool => try w.writeByte(@intFromBool(v)),
        .int => try w.writeInt(@Int(.unsigned, @max(8, std.mem.alignForward(u16, @bitSizeOf(T), 8))), @as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(v)), .little),
        .float => try put(w, @as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(v))),
        .@"enum" => try put(w, @backingInt(v)),
        .optional => if (v) |x| {
            try w.writeByte(1);
            try put(w, x);
        } else try w.writeByte(0),
        .array => for (v) |x| try put(w, x),
        .pointer => |ptr| {
            comptime assert(ptr.size == .slice);
            try w.writeInt(u64, v.len, .little);
            for (v) |x| try put(w, x);
        },
        .@"struct" => |s| if (s.layout == .@"packed") {
            try put(w, @as(s.backing_integer.?, @bitCast(v)));
        } else inline for (s.field_names) |name| try put(w, @field(v, name)),
        .@"union" => |u| {
            const Tag = u.tag_type.?;
            try put(w, @as(Tag, v));
            switch (v) {
                inline else => |x| try put(w, x),
            }
        },
        else => @compileError("serial: no form for " ++ @typeName(T)),
    }
}

fn get(comptime T: type, arena: Allocator, r: *std.Io.Reader) LoadError!T {
    if (comptime isMulti(T)) {
        const n = try count(r);
        var out: T = .empty;
        try out.ensureTotalCapacity(arena, n);
        for (0..n) |_| out.appendAssumeCapacity(try get(@typeInfo(@TypeOf(T.get)).@"fn".return_type.?, arena, r));
        return out;
    }
    switch (@typeInfo(T)) {
        .void => return {},
        .bool => return switch (r.takeByte() catch return error.Corrupt) {
            0 => false,
            1 => true,
            else => error.Corrupt,
        },
        .int => {
            const W = @Int(.unsigned, @max(8, std.mem.alignForward(u16, @bitSizeOf(T), 8)));
            const raw = r.takeInt(W, .little) catch return error.Corrupt;
            const bits = std.math.cast(@Int(.unsigned, @bitSizeOf(T)), raw) orelse return error.Corrupt;
            return @bitCast(bits);
        },
        .float => return @bitCast(try get(@Int(.unsigned, @bitSizeOf(T)), arena, r)),
        .@"enum" => |e| return std.enums.fromInt(T, try get(e.tag_type, arena, r)) orelse error.Corrupt,
        .optional => |o| return switch (try get(bool, arena, r)) {
            false => null,
            true => try get(o.child, arena, r),
        },
        .array => |a| {
            var out: T = undefined;
            for (&out) |*x| x.* = try get(a.child, arena, r);
            return out;
        },
        .pointer => |ptr| {
            comptime assert(ptr.size == .slice);
            const out = try arena.alloc(ptr.child, try count(r));
            for (out) |*x| x.* = try get(ptr.child, arena, r);
            return out;
        },
        .@"struct" => |s| {
            if (s.layout == .@"packed") return @bitCast(try get(s.backing_integer.?, arena, r));
            var out: T = undefined;
            inline for (s.field_names, s.field_types) |name, F| @field(out, name) = try get(F, arena, r);
            return out;
        },
        .@"union" => |u| {
            const tag = try get(u.tag_type.?, arena, r);
            switch (tag) {
                inline else => |t| return @unionInit(T, @tagName(t), try get(@FieldType(T, @tagName(t)), arena, r)),
            }
        },
        else => @compileError("serial: no form for " ++ @typeName(T)),
    }
}

/// A slice length, bounded by the bytes left (every element takes one or
/// more), so a corrupt count fails instead of allocating.
fn count(r: *std.Io.Reader) LoadError!usize {
    const n = r.takeInt(u64, .little) catch return error.Corrupt;
    if (n > r.buffer.len - r.seek) return error.Corrupt;
    return @intCast(n);
}

test "a program saved and loaded is saved to the same bytes" {
    // Oracle: the round trip (save, load, save again) and the loaded
    // program's own fields against the built one.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: @import("Builder.zig") = .init(a);
    const x = try b.slot(.int(70, true), &.{ 5, 1 }, &.{ 0, 2 });
    _ = try b.slot(.real_ty, &.{@bitCast(@as(f64, -0.5))}, &.{0});
    var p = b.finish();
    p.finest = -12;
    p.random_seed = -7;
    var first: std.Io.Writer.Allocating = .init(a);
    try save(&p, &first.writer);
    const q = try load(a, first.written());
    try std.testing.expectEqual(p.slots.len, q.slots.len);
    try std.testing.expectEqual(p.slots.get(x).ty, q.slots.get(x).ty);
    try std.testing.expectEqualSlices(u64, p.init_v, q.init_v);
    try std.testing.expectEqualSlices(u64, p.init_x, q.init_x);
    try std.testing.expectEqual(@as(i32, -12), q.finest);
    try std.testing.expectEqual(@as(i32, -7), q.random_seed);
    var second: std.Io.Writer.Allocating = .init(a);
    try save(&q, &second.writer);
    try std.testing.expectEqualSlices(u8, first.written(), second.written());
    // A truncated program is refused, not read past its end.
    try std.testing.expectError(error.Corrupt, load(a, first.written()[0 .. first.written().len - 1]));
}
