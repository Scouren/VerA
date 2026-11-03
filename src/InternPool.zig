//! Every interned string, type and constant of a compilation behind one
//! `Index` (Zig's `src/InternPool.zig`). Placeholder of the rewrite
//! scaffold: docs/rewrite/core-ir.md specifies it. The two handle types are
//! fixed here so `Air` builds against them from the start.
//!
//! Contents:
//! - `pub const Index = enum(u32)`
//! - `pub const String = enum(u32)`

const std = @import("std");

/// An interned type or value. `none` is the absent one.
pub const Index = enum(u32) { none = std.math.maxInt(u32), _ };

/// An interned byte string: an offset into the pool's string bytes; 0 is "".
pub const String = enum(u32) { empty = 0, _ };
