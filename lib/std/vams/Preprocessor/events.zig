//! The positional directive events the preprocessor publishes: each
//! directive whose state outlives its own line, as one table per kind in
//! text-stream order (`Directives`), and the value types of those tables. A
//! later stage looks its own output offset up. Data only: the handlers that
//! record the events are Preprocessor/handlers.zig.
//! Cites: LRM §10.2 Syntax 10-1, §10.3; IEEE 1364-2005 §19.1, §19.2, §19.6,
//! §19.8, §19.9.
//!
//! Contents:
//! - `pub const Directives = struct`
//! - `pub const Events = struct`
//! - `pub const Qualifier = enum(u8)`
//! - `pub const DefaultDiscipline = struct`
//! - `pub const Timescale = struct`
//! - `pub const NetType = enum(u8)`, `NetType.default`
//! - `pub const Drive = enum(u8)`, `Drive.default`
//! - `pub fn Region(comptime T: type) type`

const std = @import("std");
const assert = std.debug.assert;

/// Every directive whose state outlives its own line, one table per kind in
/// text-stream order. Each table's `at` is an offset into the preprocessed
/// text, the unit every later stage reports in.
pub const Directives = struct {
    /// §10.2 `default_discipline, for §7.4 discipline resolution; the empty
    /// name is the bare form or §19.6's `resetall, which withdraws it.
    disciplines: []const DefaultDiscipline = &.{},
    /// §10.3 `default_transition in seconds; null after `resetall.
    transitions: []const Region(?f64) = &.{},
    /// IEEE 1364 §19.8 `timescale; null is §19.6's `resetall (none specified).
    timescales: []const Region(?Timescale) = &.{},
    /// IEEE 1364 §19.2 `default_nettype.
    nettypes: []const Region(NetType) = &.{},
    /// IEEE 1364 §19.1 `celldefine (true) / `endcelldefine (false).
    cells: []const Region(bool) = &.{},
    /// IEEE 1364 §19.9 `unconnected_drive / `nounconnected_drive.
    drives: []const Region(Drive) = &.{},
};

/// `Directives` while it fills: field for field the same names, as growable
/// lists on the pass's arena. The comptime block holds the two lists of names
/// together, so publishing (Preprocessor.zig's `publish`) copies by name.
pub const Events = struct {
    disciplines: std.ArrayList(DefaultDiscipline) = .empty,
    transitions: std.ArrayList(Region(?f64)) = .empty,
    timescales: std.ArrayList(Region(?Timescale)) = .empty,
    nettypes: std.ArrayList(Region(NetType)) = .empty,
    cells: std.ArrayList(Region(bool)) = .empty,
    drives: std.ArrayList(Region(Drive)) = .empty,

    comptime {
        const want = @typeInfo(Directives).@"struct".field_names;
        const have = @typeInfo(Events).@"struct".field_names;
        assert(want.len == have.len);
        for (want, have) |w, h| assert(std.mem.eql(u8, w, h));
    }
};

/// §10.2 Syntax 10-1's qualifier, a closed list of fifteen keywords.
pub const Qualifier = enum(u8) { integer, real, reg, wreal, wire, tri, wand, triand, wor, trior, trireg, tri0, tri1, supply0, supply1 };

/// One §10.2 `default_discipline. "More than one `default_discipline directive
/// can be in force simultaneously, provided each differs in qualifier", and a
/// qualified one outranks an unqualified one however old.
pub const DefaultDiscipline = struct {
    at: u32,
    /// Null when the directive named no qualifier.
    qualifier: ?Qualifier,
    /// "" withdraws every default in force from `at` on.
    discipline: []const u8,
};

/// A `timescale's two operands in seconds, each an exact decimal from IEEE
/// 1364 Table 19-1 (`100us` is 1e-4, not 100 * 1e-6).
pub const Timescale = struct { unit: f64, precision: f64 };

/// IEEE 1364 §19.2 `default_nettype_value`. `.none` withdraws implicit nets.
pub const NetType = enum(u8) {
    wire,
    tri,
    tri0,
    tri1,
    wand,
    triand,
    wor,
    trior,
    trireg,
    uwire,
    none,

    /// §19.2: "If no `default_nettype directive is present or if the
    /// `resetall directive is used, implicit nets are of type wire."
    pub const default: NetType = .wire;
};

/// IEEE 1364 §19.9: how an unconnected input port is driven.
pub const Drive = enum(u8) {
    /// `nounconnected_drive, and the state before either directive.
    float,
    pull0,
    pull1,

    pub const default: Drive = .float;
};

/// One positional event: the output offset where the directive's value
/// changed, and the new value.
pub fn Region(comptime T: type) type {
    return struct { at: u32, value: T };
}
