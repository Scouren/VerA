//! Verilog-AMS Intermediate Representation (Zig's `lib/std/zig/Zir.zig`):
//! the untyped output of `AstGen` for one file, its only input that file's
//! `Ast`. Names the file resolves alone (ports, nets, variables,
//! parameters, genvars, functions, block and generate scopes) are
//! `decl_ref`s to the declaring instruction; every other name (a module, a
//! nature, a discipline, a hierarchical path's head) is a `str_ref` Sema
//! resolves. Nothing is folded and no generate scheme is unrolled.
//!
//! Layout: `instructions` (tag + 8-byte `Data`), `extra` (payloads and
//! bodies, `u32` words), `string_bytes` (NUL-terminated names, byte 0 the
//! empty string). `extra[0..2]` is the declaration table (`decls`), the
//! only thing Sema reads to build `Zcu.modules`. Every payload is an
//! `extern struct` of 4-byte words, read by a pointer cast (`extraData`);
//! a `Body` or `List` field names a run of `extra` written before it.
//! A body's value, where it has one, is its last instruction.
//! Cites: VAMS-2023 annex A (the constructs each tag lowers); IEEE
//! 1364-2005 §12.4.3 (generate scope names).
//!
//! Contents:
//! - fields `instructions`, `extra`, `string_bytes`, `diag`
//! - `pub const String`, `pub const Body`, `pub fn List(comptime T: type) type` (`Elem`, `empty`), `pub const F64` (`init`, `get`)
//! - `pub const reserved_extra`, `pub const ExtraIndex`, `pub const TransitionDefault`, `pub fn transitionDefault(vir: *const Vir, i: Inst.Index) ?f64`
//! - `pub const Decl` (`Decl.Kind`, `Decl.Index`)
//! - `pub const Inst` (`Inst.Index`, `Inst.Ref`, `Inst.Tag`, `Inst.Data`, `Inst.DataKind`, `Inst.dataKind`, `Inst.Payload`) and the payloads in `Vir/Inst.zig`
//! - `pub const print`
//! - `pub fn deinit(vir: *Vir, gpa: Allocator) void`
//! - `pub fn decls(vir: *const Vir) []const Decl`
//! - `pub fn extraData(vir: *const Vir, comptime T: type, index: u32) T`
//! - `pub fn body(vir: *const Vir, b: Body) []const Inst.Index`
//! - `pub fn list(vir: *const Vir, comptime T: type, l: List(T)) []const T`
//! - `pub fn string(vir: *const Vir, s: String) [:0]const u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Diag = @import("Diag.zig");
/// The instruction table's row type, its tags and every payload.
pub const Inst = @import("Vir/Inst.zig");
/// The text dump (Zig's `print_zir.zig`).
pub const print = @import("Vir/print.zig");

instructions: std.MultiArrayList(Inst).Slice,

/// Payloads and bodies; `extra[0..reserved_extra]` is the declaration table
/// and the `default_transition` table.
extra: []u32,

/// NUL-terminated strings; byte 0 is NUL so `String.empty` is "".
string_bytes: []u8,

/// The per-file checks' diagnostics, located in the tree's source text.
diag: Diag,

/// An offset into `string_bytes`, NUL-terminated (Zig's
/// `NullTerminatedString`). A string literal with a NUL inside is a
/// `str` instruction carrying its length instead.
pub const String = enum(u32) { empty = 0, _ };

/// `len` instruction indices at `extra[start..]`, in evaluation order.
pub const Body = List(Inst.Index);

/// An `f64` split across two `extra` words (an `extern struct` field may
/// not need 8-byte alignment in a `[]u32`).
pub const F64 = extern struct {
    lo: u32,
    hi: u32,

    pub fn init(v: f64) F64 {
        const bits: u64 = @bitCast(v);
        return .{ .lo = @truncate(bits), .hi = @truncate(bits >> 32) };
    }

    pub fn get(f: F64) f64 {
        return @bitCast(@as(u64, f.hi) << 32 | f.lo);
    }
};

/// Words `extra` reserves before any payload: the declaration table's
/// `List(Decl)` and the `List(TransitionDefault)`, written last.
pub const reserved_extra = 4;

/// The fixed places in `extra` (Zig's `Zir.ExtraIndex`).
pub const ExtraIndex = enum(u32) {
    /// `extra[0..2]`: a `List(Decl)`.
    decls = 0,
    /// `extra[2..4]`: a `List(TransitionDefault)`, by instruction.
    transitions = 2,
    _,
};

/// One row of the declaration table: a design unit of the file, in source
/// order. Sema reads only this table to build `Zcu.modules`.
pub const Decl = extern struct {
    kind: Kind,
    name: String,
    /// The `module`, `nature`, ... instruction whose payload is the unit.
    inst: Inst.Index,

    /// A.1.2's descriptions.
    pub const Kind = enum(u32) { module, macromodule, connectmodule, paramset, primitive, nature, discipline, connectrules, config };

    /// A row of the table, as `Zcu.modules` names a unit.
    pub const Index = enum(u32) { _ };
};

comptime {
    assert(@sizeOf(Decl) == 12);
    assert(@sizeOf(Body) == 8);
    assert(@sizeOf(F64) == 8);
}

/// §10.3 the `default_transition` in force at one `transition` call.
pub const TransitionDefault = extern struct { inst: Inst.Index, value: F64 };

const Vir = @This();

/// `len` records of `T` at `extra[start..]`, each `@sizeOf(T) / 4` words.
pub fn List(comptime T: type) type {
    return extern struct {
        start: u32,
        len: u32,

        /// The record type, for a reader that walks payloads generically.
        pub const Elem = T;
        pub const empty: @This() = .{ .start = 0, .len = 0 };
    };
}

/// Frees every table `AstGen.generate` allocated with `gpa`.
pub fn deinit(vir: *Vir, gpa: Allocator) void {
    vir.instructions.deinit(gpa);
    gpa.free(vir.extra);
    gpa.free(vir.string_bytes);
    vir.diag.deinit(gpa);
    vir.* = undefined;
}

/// §10.3 the `default_transition` in force at `transition` call `i`
/// ("the directive which immediately precedes the transition filter"),
/// or null when none is.
pub fn transitionDefault(vir: *const Vir, i: Inst.Index) ?f64 {
    assert(vir.extra.len >= reserved_extra);
    const rows = vir.list(TransitionDefault, vir.extraData(List(TransitionDefault), @backingInt(ExtraIndex.transitions)));
    // Appended in instruction order.
    const k = std.sort.binarySearch(TransitionDefault, rows, i, struct {
        fn order(key: Inst.Index, r: TransitionDefault) std.math.Order {
            return std.math.order(@backingInt(key), @backingInt(r.inst));
        }
    }.order) orelse return null;
    return rows[k].value.get();
}

/// The declaration table, in source order, borrowed from `extra`.
pub fn decls(vir: *const Vir) []const Decl {
    assert(vir.extra.len >= reserved_extra);
    return vir.list(Decl, vir.extraData(List(Decl), @backingInt(ExtraIndex.decls)));
}

/// Reads the payload `T` (an `extern struct` of 4-byte words) at `index`.
/// Asserts it lies inside `extra`.
pub fn extraData(vir: *const Vir, comptime T: type, index: u32) T {
    comptime assert(@sizeOf(T) % 4 == 0);
    assert(index + @sizeOf(T) / 4 <= vir.extra.len);
    return @as(*align(4) const T, @ptrCast(vir.extra[index..][0 .. @sizeOf(T) / 4])).*;
}

/// The instructions of `b`, borrowed from `extra`.
pub fn body(vir: *const Vir, b: Body) []const Inst.Index {
    return vir.list(Inst.Index, b);
}

/// The records of `l`, borrowed from `extra`. Asserts the run is inside it.
pub fn list(vir: *const Vir, comptime T: type, l: List(T)) []const T {
    comptime assert(@sizeOf(T) % 4 == 0);
    const words = l.len * (@sizeOf(T) / 4);
    assert(l.start + words <= vir.extra.len);
    return @ptrCast(vir.extra[l.start..][0..words]);
}

/// The bytes of `s`, borrowed from `string_bytes`; `.empty` is "".
pub fn string(vir: *const Vir, s: String) [:0]const u8 {
    const start: usize = @backingInt(s);
    assert(start < vir.string_bytes.len);
    const end = std.mem.findScalarPos(u8, vir.string_bytes, start, 0).?;
    return vir.string_bytes[start..end :0];
}

test {
    _ = Inst;
    _ = print;
}
