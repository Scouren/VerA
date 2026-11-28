//! The OSDI host's tables as data: what `lib/osdi_dyn` otherwise derives
//! at compile time from the device (by scanning `jac_pattern` and
//! reflecting on `Model`), written once from this backend's own tables,
//! the stamp plan's per-row pattern and `Air.Device.params`. Six
//! declarations, each optional in the contract (a host that does not read
//! them is unaffected): `osdi_entries` (the Jacobian entry table: row,
//! column, 1 resistive | 2 reactive), `osdi_param_fields` and
//! `osdi_param_kinds` (the §3.4 parameter list: `Model` field, 0 real or
//! 1 integer), and the descriptor's parameter records in compact form,
//! `osdi_param_names` (every C name NUL-terminated, end to end),
//! `osdi_param_name_at` (where record `i`'s starts) and
//! `osdi_param_flags` (its OSDI type and kind bits). `lib/osdi_dyn`
//! compares them with the derived ones in a Debug build
//! (`Library(D).literal_error`).
//! Cites: VAMS-2023 §3.4 (parameters), §5.6 (the Jacobian), §6.3.6
//! (`$mfactor`); OpenVAF-Reloaded `osdi_0_4.h` (`PARA_TY_*`,
//! `PARA_KIND_INST`, `JACOBIAN_ENTRY_*`).
//!
//! Contents:
//! - `pub fn genTables(dg: *DeclGen, w: *std.Io.Writer, pattern: []const Liveness.Mask) DeclGen.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const InternPool = @import("intern_pool");
const DeclGen = @import("DeclGen.zig");
const Liveness = @import("Liveness.zig");
const Ident = @import("Ident.zig");

/// `osdi_0_4.h` `PARA_TY_REAL`, `PARA_TY_INT`, `PARA_KIND_INST`.
const para_ty_real: u32 = 0;
const para_ty_int: u32 = 1;
const para_kind_inst: u32 = 1 << 30;
/// An `osdi_entries` flag: the entry has a reactive half.
const entry_react: u16 = 2;
/// Values per line of the number tables.
const per_line: u32 = 24;

/// Writes the six declarations of the device `dg` writes, whose `eval` rows
/// depend on the unknowns `pattern` gives (`stamps.Plan.pattern`, the
/// emitted `jac_pattern`).
///
/// The entries follow from what this backend emits: `q` always and no
/// `q_pattern`, so every column of every row has a reactive half; no
/// `jac_const`, `ac_dyn_slots` or `collapse`, so no extra entry and no
/// dropped flow. The parameters: every one is an instance parameter (no
/// `instance_params`) and `Instance` has `mfactor`, so the records are the
/// instance side, `$mfactor`, then the model side.
pub fn genTables(dg: *DeclGen, w: *std.Io.Writer, pattern: []const Liveness.Mask) DeclGen.Error!void {
    const n: u32 = @intCast(dg.u_names.len);
    assert(pattern.len == n);
    assert(n <= std.math.maxInt(u16));
    try dg.print(w, "\n/// The host's Jacobian entry table as data, row-major: row, column, flags (1 resistive, 2 reactive).\npub const osdi_entries = [_][3]u16{{\n", .{});
    var entries: u32 = 0;
    for (pattern, 0..) |row, r| for (0..n) |c| {
        try dg.print(w, "    .{{ {d}, {d}, {d} }},\n", .{ r, c, @as(u16, @intFromBool(resist(row, c))) | entry_react });
        entries += 1;
    };
    try dg.print(w, "}};\n", .{});
    assert(entries == n * n);
    try genParams(dg, w);
}

// ---- private ----

/// Whether `eval`'s row `row` may depend on unknown `c`: a column past
/// the mask's width is taken as set, as the host reads an emitted row.
fn resist(row: Liveness.Mask, c: usize) bool {
    return c >= @bitSizeOf(Liveness.Mask) or (row >> @intCast(c)) & 1 != 0;
}

/// `osdi_param_fields`, `osdi_param_kinds` and the three record tables.
fn genParams(dg: *DeclGen, w: *std.Io.Writer) DeclGen.Error!void {
    const d = dg.device;
    const np: u32 = @intCast(d.params.len);
    const records = 2 * np + 1;
    try dg.print(w, "/// The host's §3.4 parameter list as data: `Model` field, and kind (0 real, 1 integer).\npub const osdi_param_fields = [_][]const u8{{\n", .{});
    for (d.params.items(.name)) |name| try dg.print(w, "    \"{f}\",\n", .{Ident{ .name = dg.ip.stringToSlice(name) }});
    try dg.print(w, "}};\npub const osdi_param_kinds = [_]u8{{", .{});
    for (0..np) |k| try dg.print(w, "{s}{d},", .{ sep(k), kindOf(dg, @intCast(k)) });
    try dg.print(w, "\n}};\n", .{});

    try dg.print(w, "/// The descriptor's parameter records as data: C names end to end, each record's start, its flags.\npub const osdi_param_names = \"", .{});
    var at: u32 = 0;
    for (0..records) |i| at += try cString(dg, w, recordName(dg, @intCast(i)));
    try dg.print(w, "\";\npub const osdi_param_name_at = [_]u32{{", .{});
    var start: u32 = 0;
    for (0..records) |i| {
        try dg.print(w, "{s}{d},", .{ sep(i), start });
        start += @intCast(recordName(dg, @intCast(i)).len + 1);
    }
    assert(start == at);
    try dg.print(w, "\n}};\npub const osdi_param_flags = [_]u32{{", .{});
    for (0..records) |i| try dg.print(w, "{s}{d},", .{ sep(i), recordFlags(dg, @intCast(i)) });
    try dg.print(w, "\n}};\n", .{});
}

/// Record `i`'s C name: parameter `i`, then `$mfactor`, then parameter
/// `i - np - 1`. The source spelling, which is what the host's `cName`
/// recovers from the sanitized field.
fn recordName(dg: *const DeclGen, i: u32) []const u8 {
    const np: u32 = @intCast(dg.device.params.len);
    assert(i < 2 * np + 1);
    if (i == np) return "$mfactor";
    return dg.ip.stringToSlice(dg.device.params.items(.name)[if (i < np) i else i - np - 1]);
}

/// Record `i`'s flags: its type, and `PARA_KIND_INST` on the instance side.
fn recordFlags(dg: *const DeclGen, i: u32) u32 {
    const np: u32 = @intCast(dg.device.params.len);
    assert(i < 2 * np + 1);
    if (i == np) return para_ty_real | para_kind_inst;
    if (i < np) return kindOf(dg, i) | para_kind_inst;
    return kindOf(dg, i - np - 1);
}

/// Parameter `k`'s OSDI type: integer when `genModel` writes its field as
/// an `i64` (a derived default of an `integer` parameter, or a folded
/// integer default), else real.
fn kindOf(dg: *const DeclGen, k: u32) u32 {
    const d = dg.device;
    assert(k < d.params.len);
    const def = d.params.items(.default)[k];
    const integer = if (def == InternPool.Index.undef or def == .none)
        d.params.items(.ty)[k] == .integer
    else
        dg.ip.indexToKey(def) == .int;
    return if (integer) para_ty_int else para_ty_real;
}

/// Writes `s` and its NUL as the inside of a Zig string literal; returns
/// the bytes the literal holds.
fn cString(dg: *DeclGen, w: *std.Io.Writer, s: []const u8) DeclGen.Error!u32 {
    for (s) |c| {
        assert(c != 0);
        if (c >= 0x20 and c < 0x7f and c != '"' and c != '\\') try dg.print(w, "{c}", .{c}) else try dg.print(w, "\\x{x:0>2}", .{c});
    }
    try dg.print(w, "\\x00", .{});
    return @intCast(s.len + 1);
}

/// The separator before value `i` of a number table: a new line every
/// `per_line` values.
fn sep(i: usize) []const u8 {
    return if (i % per_line == 0) "\n    " else " ";
}

test resist {
    try std.testing.expect(resist(0b101, 0));
    try std.testing.expect(!resist(0b101, 1));
    try std.testing.expect(resist(0b101, 2));
    // Past the mask's width, as the host reads `jac_pattern`.
    try std.testing.expect(resist(0, 64));
}
