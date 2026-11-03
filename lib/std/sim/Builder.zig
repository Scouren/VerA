//! Rows appended one at a time in, a frozen `Program` out (`finish`): the
//! writer side of the table, for the compiler stage that lowers a design
//! and for tests that build a program by hand. Every row lives in `arena`.
//! Cites: none (table assembly).
//!
//! Contents:
//! - `pub fn init(arena: Allocator) Builder`
//! - `pub fn slot(b: *Builder, ty: Program.Ty, v: []const u64, x: []const u64) Error!u32`
//! - `pub fn inst(b: *Builder, tag: Program.Inst.Tag, a: u32, c: u32, scope: u32) Error!u32`
//! - `pub fn setInst(b: *Builder, pc: u32, tag: Program.Inst.Tag, a: u32, c: u32) void`
//! - `pub fn expr(b: *Builder, tag: Program.Expr.Tag, ty: Program.Ty, a: u32, c: u32) Error!u32`
//! - `pub fn constant(b: *Builder, ty: Program.Ty, v: []const u64, x: []const u64) Error!u32`
//! - `pub fn int(b: *Builder, ty: Program.Ty, value: u64) Error!u32`
//! - `pub fn extraOf(b: *Builder, value: anytype) Error!u32`
//! - `pub fn listOf(b: *Builder, words: []const u32) Error!Program.List`
//! - `pub fn string(b: *Builder, bytes: []const u8) Error!Program.List`
//! - `pub fn finish(b: *Builder) Program`
//! - `pub const Error = Allocator.Error`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Program = @import("Program.zig");

/// Only memory can run out.
pub const Error = Allocator.Error;

arena: Allocator,
p: Program = .{},
init_v: std.ArrayList(u64) = .empty,
init_x: std.ArrayList(u64) = .empty,
inst_scope: std.ArrayList(u32) = .empty,
extra: std.ArrayList(u32) = .empty,
consts: std.ArrayList(u64) = .empty,
string_bytes: std.ArrayList(u8) = .empty,
scopes: std.ArrayList(Program.Scope) = .empty,
times: std.ArrayList(Program.Time) = .empty,
blocks: std.ArrayList(Program.Block) = .empty,
pieces: std.ArrayList(Program.Piece) = .empty,
shows: std.ArrayList(Program.Show) = .empty,
starts: std.ArrayList(Program.Start) = .empty,
evcd_ports: std.ArrayList(Program.EvcdPort) = .empty,

const Builder = @This();

/// An empty program whose rows live in `arena`.
pub fn init(arena: Allocator) Builder {
    return .{ .arena = arena };
}

/// A new slot of type `ty` starting at value (`v`, `x`), each
/// `Program.words(ty.width)` words. Returns its index.
pub fn slot(b: *Builder, ty: Program.Ty, v: []const u64, x: []const u64) Error!u32 {
    const n = Program.words(ty.width);
    assert(v.len == n);
    assert(x.len == n);
    const at: u32 = @intCast(b.p.slots.len);
    try b.p.slots.append(b.arena, .{ .word = @intCast(b.init_v.items.len), .ty = ty });
    try b.init_v.appendSlice(b.arena, v);
    try b.init_x.appendSlice(b.arena, x);
    assert(b.init_v.items.len == b.init_x.items.len);
    return at;
}

/// Appends an instruction run in `scope`; returns its pc.
pub fn inst(b: *Builder, tag: Program.Inst.Tag, a: u32, c: u32, scope: u32) Error!u32 {
    const pc: u32 = @intCast(b.p.insts.len);
    try b.p.insts.append(b.arena, .{ .tag = tag, .data = .{ .a = a, .b = c } });
    try b.inst_scope.append(b.arena, scope);
    assert(b.inst_scope.items.len == b.p.insts.len);
    return pc;
}

/// Rewrites instruction `pc` (a forward target patched in).
pub fn setInst(b: *Builder, pc: u32, tag: Program.Inst.Tag, a: u32, c: u32) void {
    assert(pc < b.p.insts.len);
    b.p.insts.set(pc, .{ .tag = tag, .data = .{ .a = a, .b = c } });
}

/// Appends an expression row; returns its index.
pub fn expr(b: *Builder, tag: Program.Expr.Tag, ty: Program.Ty, a: u32, c: u32) Error!u32 {
    const at: u32 = @intCast(b.p.exprs.len);
    try b.p.exprs.append(b.arena, .{ .tag = tag, .ty = ty, .data = .{ .a = a, .b = c } });
    return at;
}

/// A constant row of type `ty` with planes (`v`, `x`).
pub fn constant(b: *Builder, ty: Program.Ty, v: []const u64, x: []const u64) Error!u32 {
    const n = Program.words(ty.width);
    assert(v.len == n);
    assert(x.len == n);
    const at: u32 = @intCast(b.consts.items.len);
    try b.consts.appendSlice(b.arena, v);
    try b.consts.appendSlice(b.arena, x);
    return b.expr(.constant, ty, at, 0);
}

/// A known constant of at most 64 bits.
pub fn int(b: *Builder, ty: Program.Ty, value: u64) Error!u32 {
    assert(ty.width <= 64);
    return b.constant(ty, &.{value}, &.{0});
}

/// Stores `value`, a struct of u32-backed fields (`Program.extraData`'s
/// layout), in `extra`; returns where.
pub fn extraOf(b: *Builder, value: anytype) Error!u32 {
    const at: u32 = @intCast(b.extra.items.len);
    const info = @typeInfo(@TypeOf(value)).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        const x = @field(value, name);
        switch (F) {
            u32 => try b.extra.append(b.arena, x),
            i32 => try b.extra.append(b.arena, @bitCast(x)),
            i64 => try b.extra.appendSlice(b.arena, &.{ @truncate(@as(u64, @bitCast(x))), @truncate(@as(u64, @bitCast(x)) >> 32) }),
            Program.Ty => try b.extra.append(b.arena, @bitCast(x)),
            bool => try b.extra.append(b.arena, @intFromBool(x)),
            Program.List => try b.extra.appendSlice(b.arena, &.{ x.start, x.len }),
            else => try b.extra.append(b.arena, @backingInt(x)), // else: a u32-backed enum
        }
    }
    return at;
}

/// Stores `words` in `extra` and returns the list naming them.
pub fn listOf(b: *Builder, words: []const u32) Error!Program.List {
    const start: u32 = @intCast(b.extra.items.len);
    try b.extra.appendSlice(b.arena, words);
    return .{ .start = start, .len = @intCast(words.len) };
}

/// Stores `bytes` in `string_bytes`.
pub fn string(b: *Builder, bytes: []const u8) Error!Program.List {
    const start: u32 = @intCast(b.string_bytes.items.len);
    try b.string_bytes.appendSlice(b.arena, bytes);
    return .{ .start = start, .len = @intCast(bytes.len) };
}

/// The program as built. The builder is spent.
pub fn finish(b: *Builder) Program {
    var p = b.p;
    p.init_v = b.init_v.items;
    p.init_x = b.init_x.items;
    p.inst_scope = b.inst_scope.items;
    p.extra = b.extra.items;
    p.consts = b.consts.items;
    p.string_bytes = b.string_bytes.items;
    p.scopes = b.scopes.items;
    p.times = b.times.items;
    p.blocks = b.blocks.items;
    p.pieces = b.pieces.items;
    p.shows = b.shows.items;
    p.starts = b.starts.items;
    p.evcd_ports = b.evcd_ports.items;
    assert(p.inst_scope.len == p.insts.len);
    assert(p.init_v.len == p.init_x.len);
    return p;
}
