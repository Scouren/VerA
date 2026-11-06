//! An IEEE 1364 design in, Yosys RTLIL text out (`--emit-rtlil`): the
//! refusal of a design outside the synthesizable subset (`refusal`, over
//! `sema.digital.sites`), and the text of one inside it (`emit`, over the
//! lowered `std_sim.Program` and `sema.digital.Lowered`).
//!
//! Contents:
//! - `pub const Refusal = struct`
//! - `pub fn refusal(arena: Allocator, s: *const Sites) Allocator.Error!?Refusal`
//! - `pub const emit = @import("rtlil/emit.zig").emit`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const sema = @import("sema");
const sites = sema.digital.sites;
const Sites = sites.Sites;
const Code = vams.Diag.Code;
const Allocator = std.mem.Allocator;

/// The text of a design inside the subset (`rtlil/emit.zig`).
pub const emit = @import("rtlil/emit.zig").emit;

/// The construct the old emitter refuses first: its code, the offset of
/// its token in the preprocessed text, and the message's detail ("" for
/// the code's title alone).
pub const Refusal = struct { code: Code, at: u32, detail: []const u8 };

/// A row's place in the walk; the row index breaks a tie.
const Key = struct { major: u8, group: u32, phase: u8, rank: u8 };

/// The first refusal of the old emitter's walk: a UDP anywhere in the
/// file, else the first module's first refusal by phase, then by
/// `initial`/`always` (each walked whole before the next), then by the
/// item lists' order of checks, then by source order. Null: every module
/// is inside the subset.
pub fn refusal(arena: Allocator, s: *const Sites) Allocator.Error!?Refusal {
    const rows = s.rows.slice();
    const kinds = rows.items(.kind);
    const ats = rows.items(.at);
    const names = rows.items(.name);
    for (kinds, ats) |k, at| if (k == .udp) return .{ .code = .E1201, .at = at, .detail = "" };
    var best: ?usize = null;
    var best_key: Key = undefined;
    var module: u32 = sites.none;
    for (rows.items(.module), rows.items(.phase), rows.items(.group), kinds, 0..) |m, p, g, k, i| {
        if (m == sites.none) continue;
        const key = keyOf(p, g, k);
        if (best == null or m < module or (m == module and lessKey(key, best_key))) {
            best = i;
            best_key = key;
            module = m;
        }
    }
    const i = best orelse return null;
    assert(module < s.modules.len);
    const name = names[i];
    const detail = if (kinds[i] == .duplicate)
        "duplicate digital variable"
    else if (kinds[i] == .var_array)
        try std.fmt.allocPrint(arena, "`{s}` has unpacked dimensions", .{name})
    else if (name.len != 0) try std.fmt.allocPrint(arena, "`{s}`", .{name}) else "";
    return .{ .code = codeOf(kinds[i]), .at = ats[i], .detail = detail };
}

// ---- private ----

fn keyOf(p: sites.Phase, g: u32, k: sites.Kind) Key {
    const major: u8 = switch (p) {
        .initial_flat, .initial_stmt => @backingInt(sites.Phase.initial_flat),
        .always_head, .always_event, .always_mix, .always_target, .always_stmt => @backingInt(sites.Phase.always_head),
        else => @backingInt(p), // else: a phase of its own
    };
    const grouped = p == .initial_flat or p == .initial_stmt or @backingInt(p) >= @backingInt(sites.Phase.always_head);
    return .{ .major = major, .group = if (grouped) g else 0, .phase = @backingInt(p), .rank = if (p == .item) @backingInt(k) else 0 };
}

fn lessKey(a: Key, b: Key) bool {
    if (a.major != b.major) return a.major < b.major;
    if (a.group != b.group) return a.group < b.group;
    if (a.phase != b.phase) return a.phase < b.phase;
    return a.rank < b.rank;
}

/// The old emitter's code for each refusal (src/codegen/digital/rtlil*.zig).
fn codeOf(k: sites.Kind) Code {
    return switch (k) {
        .udp => .E1201,
        .analog => .E1202,
        .connect => .E1203,
        .genvar => .E1204,
        .defparam => .E1205,
        .task => .E1206,
        .analog_function => .E1207,
        .event => .E1208,
        .pull => .E1209,
        .switch_prim => .E1210,
        .branch => .E1211,
        .port_expr => .E1212,
        .port_select => .E1213,
        .port_wreal => .E1214,
        .net_wreal => .E1215,
        .net_array => .E1216,
        .var_array => .E1217,
        .var_real => .E1218,
        .var_string => .E1219,
        .range_value => .E1220,
        .range_offset => .E1221,
        .range_width => .E1222,
        .param_value => .E1223,
        .unknown_name => .E1224,
        .real_literal => .E1225,
        .string_literal => .E1226,
        .hierarchical => .E1227,
        .call => .E1228,
        .other_expr => .E1229,
        .sys_call => .E1230,
        .clog2_value => .E1231,
        .replicate_count => .E1233,
        .select_range => .E1236,
        .select_width => .E1237,
        .select_base => .E1239,
        .select_of_expr => .E1240,
        .select_of_param => .E1241,
        .lvalue_no_base => .E1244,
        .lvalue_other => .E1245,
        .lvalue_param => .E1246,
        .lvalue_net => .E1247,
        .lvalue_nested => .E1248,
        .lvalue_indexed => .E1249,
        .lvalue_bit => .E1250,
        .init_other => .E1251,
        .init_timed => .E1252,
        .init_target => .E1253,
        .init_value => .E1254,
        .block_decls => .E1255,
        .fork => .E1256,
        .no_event => .E1257,
        .not_event => .E1258,
        .mixed_edges => .E1259,
        .timed_assign => .E1260,
        .proc_continuous => .E1261,
        .case_xz => .E1262,
        .loop => .E1263,
        .wait => .E1264,
        .trigger => .E1265,
        .disable => .E1266,
        .jump => .E1267,
        .contribution => .E1268,
        .gate_array => .E1269,
        .instance_array => .E1270,
        .duplicate => .E1100,
        .ordered_params => .E1272,
        .override_value => .E1273,
    };
}
