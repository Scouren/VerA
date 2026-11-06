//! A device card naming a `.MODEL` in, the instance of its Verilog-A module or
//! paramset out, the card's and the model's parameters as overrides; a binned
//! model resolves to the bin that holds the card's L and W, and a Table E.1
//! semiconductor with no behaviour is E0953. Also the values every card
//! reader shares (`Value`, `paramValue`, `cardValue`) and a `.MODEL` card's
//! own module parameters (`modelParams`).
//! Cites: LRM annex E.2, E.2.2.1, E.4.1, E.4.2, Table E.1; §3.4.2, §6.3.
//!
//! Contents:
//! - `pub const model_cards = [_]struct`
//! - `pub const Value = union(enum)`: `format`
//! - `pub const Override = struct`
//! - `pub const ModelParams = struct`
//! - `pub fn emitModelCard(`
//! - `pub fn emitInstance(arena: Allocator, out: *std.ArrayList(u8), module: []const u8, params: []const Override, inst: []const u8, nodes: []const []const u8) Allocator.Error!void`
//! - `pub fn setOverride(arena: Allocator, list: *std.ArrayList(Override), name: []const u8, value: Value) Allocator.Error!void`
//! - `pub fn paramValue(arena: Allocator, t: []const u8, eq: usize, inst: []const u8, at: Card, refusals: *Refusals, scope: []const []const u8) Allocator.Error!?Value`
//! - `pub fn cardValue(`
//! - `pub fn modelParams(`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const card_ = @import("card.zig");
const expr = @import("expr.zig");
const Card = card_.Card;
const Refusals = card_.Refusals;
const ModelCard = card_.ModelCard;
const Tokens = card_.Tokens;
const model_types = card_.model_types;
const spiceNumber = card_.spiceNumber;
const spell = card_.spell;

/// SPICE3's semiconductor device cards: the letter, its node count before
/// the model name, and the Table E.1 primitive a `.MODEL` of a Table E.1
/// type would make it (`emitModelCard`):
///
///     M d g s b model [k=v ...]
///     Q c b e [s] model [area] [k=v ...]
///     J d g s model [area] [k=v ...]
///     D a c model [area] [k=v ...]
///
/// Q's substrate is read as SPICE3 reads it: the fourth field is the model
/// when a `.MODEL` card names it; otherwise the fifth is, when a `.MODEL`
/// card names it or it is not a number (`2N2222` is both a model name and
/// SPICE's 2n with unit noise, so the card decides).
pub const model_cards = [_]struct { letter: u8, nodes: u8, prim: []const u8 }{
    .{ .letter = 'm', .nodes = 4, .prim = "mosfet" },
    .{ .letter = 'q', .nodes = 3, .prim = "bjt" },
    .{ .letter = 'j', .nodes = 3, .prim = "jfet" },
    .{ .letter = 'd', .nodes = 2, .prim = "diode" },
};

/// A card value: a number, or a `{expr}` as Verilog-AMS text
/// (`expr.expression`), which elaboration evaluates against the
/// subcircuit's parameters.
pub const Value = union(enum) {
    num: f64,
    expr: []const u8,

    /// Writes the value as Verilog-AMS: `{d}`'s plain decimal, except an
    /// integral value of 2^31 or more, which `{d}` would spell as an integer
    /// literal too wide for §3.2's 32-bit integer; `{e}` keeps it real.
    pub fn format(v: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (v) {
            .num => |n| if (@abs(n) >= 0x1p31 and @trunc(n) == n) try w.print("{e}", .{n}) else try w.print("{d}", .{n}),
            .expr => |e| try w.writeAll(e),
        }
    }
};

/// One `.name(value)` an instance carries.
pub const Override = struct { name: []const u8, value: Value };

/// The `parameter` declarations a model-derived module carries, and the
/// argument list that forwards them to the primitive it wraps.
pub const ModelParams = struct {
    /// One `   parameter ...;\n` line per parameter of the primitive.
    decls: []const u8,
    /// `.r(r), .tc1(tc1), ...`: §6.3.3 by name, so Table E.1's order does
    /// not matter here.
    args: []const u8,
};

/// A bin card's four bounds, in the order `pickBin` keeps them.
const BinBound = enum { lmin, lmax, wmin, wmax };

/// Emits the instance an M/Q/J/D card is (`model_cards`). E.2: "models
/// contained within the SPICE netlist are treated as module definitions".
/// The card's model name resolves, in order, to
///
///   - a `.MODEL name type ...` card whose type is no Table E.1 row: an
///     instance of `type`, a Verilog-A module or paramset of the design,
///     the card's parameters as overrides;
///   - a `.MODEL` of a Table E.1 type (nmos, npn, d, ...): refused (E0953),
///     since Table E.1 leaves those rows without a Behavior and an instance
///     with none would be an open where the netlist has a transistor;
///   - binned model cards `.MODEL name.N type ... LMIN= LMAX= WMIN= WMAX=`
///     (E.4.2): the first bin, in card order, with lmin <= L < lmax and
///     wmin <= W < wmax for the card's numeric L and W (a bound the bin
///     card does not give is open), read as above without its bounds; no
///     such bin, or an L or W that is missing or an expression, is refused;
///   - no `.MODEL` of that name: the name itself, as a module or paramset
///     of the design.
///
/// The card's own parameters override the model card's of the same name,
/// and `M=` is E.4.1's multiplicity, the §6.3.6 `$mfactor`. A refusal is
/// recorded and nothing is emitted. Asserts that `at` is not empty.
pub fn emitModelCard(
    arena: Allocator,
    out: *std.ArrayList(u8),
    at: Card,
    inst: []const u8,
    it: *Tokens,
    row: @TypeOf(model_cards[0]),
    models: []const ModelCard,
    scope: []const []const u8,
    refusals: *Refusals,
) Allocator.Error!void {
    const out_before = out.items.len;
    defer assert(out.items.len >= out_before);
    assert(at.text.len > 0);
    var plain: std.ArrayList([]const u8) = .empty;
    var over: std.ArrayList(Override) = .empty;
    while (it.next()) |t| {
        const eq = std.mem.findScalar(u8, t, '=') orelse {
            if (over.items.len != 0)
                return refusals.add(at, "`{s}`: the field `{s}` after its parameters is not read", .{ inst, t });
            try plain.append(arena, t);
            continue;
        };
        try setOverride(arena, &over, t[0..eq], try paramValue(arena, t, eq, inst, at, refusals, scope) orelse return);
    }
    const substrate = row.letter == 'q' and plain.items.len >= 5 and !namesModel(models, plain.items[3]) and
        (namesModel(models, plain.items[4]) or spiceNumber(plain.items[4]) == null);
    const nodes: usize = if (substrate) 4 else row.nodes;
    if (plain.items.len <= nodes) return refusals.add(at, "`{s}` has too few fields", .{inst});
    const model = plain.items[nodes];
    var extra = plain.items[nodes + 1 ..];
    // A positional area (Q, J, D) is Table E.1's `area`; `area=` wins.
    if (row.letter != 'm' and extra.len == 1) if (spiceNumber(extra[0])) |a| {
        for (over.items) |o| {
            if (std.mem.eql(u8, o.name, "area")) break;
        } else try over.append(arena, .{ .name = "area", .value = .{ .num = a } });
        extra = extra[1..];
    };
    if (extra.len != 0) return refusals.add(at, "`{s}`: the field `{s}` after the model is not read", .{ inst, extra[0] });

    var module = model;
    var params: std.ArrayList(Override) = .empty;
    const found = for (models) |m| {
        if (std.mem.eql(u8, m.name, model)) break m;
    } else try pickBin(at, inst, model, models, over.items, refusals) orelse return;
    if (found) |m| {
        if (for (model_types) |t| {
            if (std.mem.eql(u8, t.type_, m.type_)) break t;
        } else null) |t| return refusals.addCode(.E0953, at, "`{s}`: its model `{s}` is `.model {s} {s}`, Table E.1's `{s}`, which has no behaviour in VerA; name a Verilog-A module as the model's type (`.model {s} <module> ...`)", .{ inst, model, m.name, m.type_, t.prim, m.name });
        module = m.type_;
        // A bin (`name.N`, picked or named) keeps its bounds to itself.
        const binned = std.mem.findScalar(u8, m.name, '.') != null;
        var mit: Tokens = .{ .text = m.card.text };
        for (0..3) |_| _ = mit.next(); // `.model name type`
        while (mit.next()) |t| {
            const eq = std.mem.findScalar(u8, t, '=') orelse
                return refusals.add(at, "`{s}`: the field `{s}` of `.model {s}` is not read", .{ inst, t, m.name });
            if (binned and std.meta.stringToEnum(BinBound, t[0..eq]) != null) continue;
            try setOverride(arena, &params, t[0..eq], try paramValue(arena, t, eq, inst, at, refusals, &.{}) orelse return);
        }
    }
    for (over.items) |o| try setOverride(arena, &params, o.name, o.value);
    try emitInstance(arena, out, module, params.items, inst, plain.items[0..nodes]);
}

/// Appends `   module #(.k(v), ...) inst(n1, ...);`, `m` written as
/// `$mfactor`. Asserts that `module` and `inst` are not empty.
pub fn emitInstance(arena: Allocator, out: *std.ArrayList(u8), module: []const u8, params: []const Override, inst: []const u8, nodes: []const []const u8) Allocator.Error!void {
    assert(module.len != 0);
    assert(inst.len != 0);
    const out_before = out.items.len;
    defer assert(out.items.len > out_before);
    try out.print(arena, "   {s} ", .{try spell(arena, module)});
    if (params.len != 0) {
        try out.appendSlice(arena, "#(");
        for (params, 0..) |p, i| {
            if (i != 0) try out.appendSlice(arena, ", ");
            const name = if (std.mem.eql(u8, p.name, "m")) "$mfactor" else try spell(arena, p.name);
            try out.print(arena, ".{s}({f})", .{ name, p.value });
        }
        try out.appendSlice(arena, ") ");
    }
    try out.print(arena, "{s}(", .{try spell(arena, inst)});
    for (nodes, 0..) |n, i| try out.print(arena, "{s}{s}", .{ if (i == 0) "" else ", ", try spell(arena, n) });
    try out.appendSlice(arena, ");\n");
}

/// Sets `name` in `list`, replacing an earlier value: a later assignment of
/// one parameter wins, as an instance's does over its model card's.
pub fn setOverride(arena: Allocator, list: *std.ArrayList(Override), name: []const u8, value: Value) Allocator.Error!void {
    const n = list.items.len;
    defer assert(list.items.len == n or list.items.len == n + 1);
    for (list.items) |*o| if (std.mem.eql(u8, o.name, name)) {
        o.value = value;
        return;
    };
    try list.append(arena, .{ .name = name, .value = value });
}

/// Returns the value `t[eq + 1 ..]` of the parameter assignment `t`: a
/// number, or a `{expr}` over `scope`; null after recording why it is
/// neither. Asserts that `eq` is the index of an `=` in `t`.
pub fn paramValue(arena: Allocator, t: []const u8, eq: usize, inst: []const u8, at: Card, refusals: *Refusals, scope: []const []const u8) Allocator.Error!?Value {
    assert(at.text.len > 0);
    assert(eq < t.len);
    assert(t[eq] == '=');
    const v = t[eq + 1 ..];
    if (eq == 0 or v.len == 0) {
        try refusals.add(at, "`{s}`: `{s}` is not a parameter assignment", .{ inst, t });
        return null;
    }
    if (spiceNumber(v)) |n| return .{ .num = n };
    if (v[0] == '{' or v[0] == '\'') return exprValue(arena, v, inst, at, refusals, scope);
    try refusals.add(at, "`{s}`: the value `{s}` of `{s}` is not a number", .{ inst, v, t[0..eq] });
    return null;
}

/// Returns a device card's one positional value, with nothing after it, or
/// null after recording why not: a model name (`R1 A B RMOD`), an
/// expression `expr.expression` does not read, a missing value, or a
/// trailing field (`TC=...`, `AC 1`) whose meaning would be dropped.
pub fn cardValue(
    arena: Allocator,
    t: ?[]const u8,
    it: *Tokens,
    inst: []const u8,
    at: Card,
    refusals: *Refusals,
    scope: []const []const u8,
) Allocator.Error!?Value {
    assert(at.text.len > 0);
    const v = t orelse {
        try refusals.add(at, "`{s}` has too few fields", .{inst});
        return null;
    };
    assert(v.len != 0);
    const value: Value = if (spiceNumber(v)) |n| .{ .num = n } else if (v[0] == '{' or v[0] == '\'')
        try exprValue(arena, v, inst, at, refusals, scope) orelse return null
    else {
        try refusals.add(at, "`{s}`: the value `{s}` is not a number (a model-referenced card is not read)", .{ inst, v });
        return null;
    };
    if (it.next()) |extra| {
        try refusals.add(at, "`{s}`: the field `{s}` after the value is not read", .{ inst, extra });
        return null;
    }
    return value;
}

/// Returns a model-derived module's parameter declarations and forwarding
/// list (E.2.2.1: "the ports and parameters of the bjt are determined by
/// the bjt primitive itself"), or null after a refusal. The primitive's
/// declarations are copied from `spice_primitives.vams` so the `from`
/// ranges and defaults cannot drift, each default replaced by the card's
/// value where the card names that parameter, the `from` range kept
/// (§3.4.2). A card parameter Table E.1 does not declare (`BF=80`) is
/// dropped in silence (E.2, E.4.2: "implementation specific"); a value for
/// one it does declare is a number or an expression over numbers, or is
/// refused, since dropping it would keep the default.
pub fn modelParams(
    arena: Allocator,
    prim: []const u8,
    it: *Tokens,
    model: []const u8,
    at: Card,
    refusals: *Refusals,
) Allocator.Error!?ModelParams {
    assert(at.text.len > 0);
    assert(primitiveBody(prim).len != 0);
    // The card's `k=v` tail; `tightEquals` has joined HSPICE's `k = v`.
    var keys: std.ArrayList([]const u8) = .empty;
    var vals: std.ArrayList([]const u8) = .empty;
    while (it.next()) |t| {
        const eq = std.mem.findScalar(u8, t, '=') orelse continue;
        if (eq == 0 or eq + 1 == t.len) continue;
        try keys.append(arena, t[0..eq]);
        try vals.append(arena, t[eq + 1 ..]);
    }

    var decls: std.ArrayList(u8) = .empty;
    var args: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, primitiveBody(prim), '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (!std.mem.startsWith(u8, line, "parameter ")) continue;
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        const head = std.mem.trimEnd(u8, line[0..eq], " \t");
        // The declared name is the last token before the `=`, minus any
        // §3.4.4 array range: `parameter real wave[0:nwave-1] = ...`.
        var name = head[(std.mem.findLastAny(u8, head, " \t") orelse 0) + 1 ..];
        if (std.mem.findScalar(u8, name, '[')) |b| name = name[0..b];
        if (name.len == 0) continue;

        if (args.items.len != 0) try args.appendSlice(arena, ", ");
        try args.print(arena, ".{s}({s})", .{ name, name });

        const bound = for (keys.items, vals.items) |k, v| {
            if (std.mem.eql(u8, k, name)) break v;
        } else null;
        if (bound) |given| {
            // An expression may read no name: no `.param` is in scope.
            const v: Value = if (spiceNumber(given)) |n| .{ .num = n } else if (given[0] == '{' or given[0] == '\'')
                try exprValue(arena, given, model, at, refusals, &.{}) orelse return null
            else {
                try refusals.add(at, "`.model {s}`: the value `{s}` of `{s}` is not a number", .{ model, given, name });
                return null;
            };
            const rest = line[eq + 1 ..];
            const tail = if (std.mem.find(u8, rest, " from ")) |f| rest[f..] else ";";
            try decls.print(arena, "   {s} = {f}{s}\n", .{ head, v, tail });
        } else {
            try decls.print(arena, "   {s}\n", .{line});
        }
    }
    return .{ .decls = decls.items, .args = args.items };
}

// ---- private ----

/// Returns the bin of the binned model `model` that holds the card's L and
/// W (`emitModelCard`), wrapped in an optional: `.{null}` when `model` is
/// not binned at all, null after a refusal.
fn pickBin(at: Card, inst: []const u8, model: []const u8, models: []const ModelCard, over: []const Override, refusals: *Refusals) Allocator.Error!??ModelCard {
    assert(at.text.len > 0);
    const any = for (models) |m| {
        if (isBinOf(m.name, model)) break true;
    } else false;
    if (!any) return @as(?ModelCard, null);
    // The card's L and W, numbers: the bin is chosen here, before elaboration.
    var lw: [2]f64 = undefined;
    for ([_][]const u8{ "l", "w" }, &lw) |key, *dst| {
        const o = for (over) |o| {
            if (std.mem.eql(u8, o.name, key)) break o;
        } else {
            try refusals.add(at, "`{s}`: `{s}` is a binned model (`.model {s}.N`), chosen by the card's L and W, and the card gives no {s}", .{ inst, model, model, key });
            return null;
        };
        dst.* = switch (o.value) {
            .num => |v| v,
            .expr => {
                try refusals.add(at, "`{s}`: `{s}` is a binned model (`.model {s}.N`), chosen by the card's L and W, and its {s} is an expression", .{ inst, model, model, key });
                return null;
            },
        };
    }
    for (models) |m| {
        if (!isBinOf(m.name, model)) continue;
        var b = [4]f64{ 0, std.math.inf(f64), 0, std.math.inf(f64) };
        var mit: Tokens = .{ .text = m.card.text };
        for (0..3) |_| _ = mit.next(); // `.model name type`
        while (mit.next()) |t| {
            const eq = std.mem.findScalar(u8, t, '=') orelse continue;
            const k = std.meta.stringToEnum(BinBound, t[0..eq]) orelse continue;
            b[@backingInt(k)] = spiceNumber(t[eq + 1 ..]) orelse {
                try refusals.add(at, "`{s}`: the bound `{s}` of the bin `.model {s}` is not a number", .{ inst, t, m.name });
                return null;
            };
        }
        if (b[0] <= lw[0] and lw[0] < b[1] and b[2] <= lw[1] and lw[1] < b[3]) return @as(?ModelCard, m);
    }
    try refusals.add(at, "`{s}`: no bin of the binned model `{s}` (`.model {s}.N`) holds L={d}, W={d}", .{ inst, model, model, lw[0], lw[1] });
    return null;
}

/// Reports whether `name` is a bin of the binned model `model`: `model.N`.
fn isBinOf(name: []const u8, model: []const u8) bool {
    return name.len > model.len + 1 and std.mem.startsWith(u8, name, model) and name[model.len] == '.';
}

/// Reports whether a `.MODEL` card names `name`, itself or as a binned model.
fn namesModel(models: []const ModelCard, name: []const u8) bool {
    for (models) |m| if (std.mem.eql(u8, m.name, name) or isBinOf(m.name, name)) return true;
    return false;
}

/// Returns the `{expr}` or `'expr'` field `v` as a `Value`, or null after
/// recording why `expr.expression` does not read it. Asserts that `v` opens
/// with `{` or `'`, which is how every caller tells an expression from a
/// number.
fn exprValue(arena: Allocator, v: []const u8, inst: []const u8, at: Card, refusals: *Refusals, scope: []const []const u8) Allocator.Error!?Value {
    assert(at.text.len > 0);
    assert(v[0] == '{' or v[0] == '\'');
    const close: u8 = if (v[0] == '{') '}' else '\'';
    if (v.len < 2 or v[v.len - 1] != close) {
        try refusals.add(at, "`{s}`: the expression value `{s}` does not end in `{c}`", .{ inst, v, close });
        return null;
    }
    switch (try expr.expression(arena, v[1 .. v.len - 1], scope)) {
        .text => |text| return .{ .expr = text },
        .refused => |why| {
            try refusals.add(at, "`{s}`: the expression value `{s}` {s}", .{ inst, v, why });
            return null;
        },
    }
}

/// The body of `spice_primitives.vams`'s module for `prim`, between its
/// header and its `endmodule`; empty if there is no such module.
fn primitiveBody(prim: []const u8) []const u8 {
    const prelude = @embedFile("../spice_primitives.vams");
    var buf: [64]u8 = undefined;
    const header = std.mem.print(&buf, "\nmodule {s}(", .{prim}) catch return "";
    const at = std.mem.find(u8, prelude, header) orelse return "";
    const rest = prelude[at + header.len ..];
    const end = std.mem.find(u8, rest, "\nendmodule") orelse return "";
    return rest[0..end];
}

test "a card value at or past 2^31 that is integral is spelled real" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("10000", try std.mem.print(&buf, "{f}", .{Value{ .num = 1e4 }}));
    try std.testing.expectEqualStrings("2147483647", try std.mem.print(&buf, "{f}", .{Value{ .num = 2147483647 }}));
    try std.testing.expectEqualStrings("2.147483648e9", try std.mem.print(&buf, "{f}", .{Value{ .num = 2147483648 }}));
    try std.testing.expectEqualStrings("0.5", try std.mem.print(&buf, "{f}", .{Value{ .num = 0.5 }}));
    try std.testing.expectEqualStrings("-2.147483648e9", try std.mem.print(&buf, "{f}", .{Value{ .num = -2147483648 }}));
    try std.testing.expectEqualStrings("-0.5", try std.mem.print(&buf, "{f}", .{Value{ .num = -0.5 }}));
}

test "every model_types primitive has a body to copy parameters from" {
    for (model_types) |r| try std.testing.expect(primitiveBody(r.prim).len != 0);
    try std.testing.expectEqual(@as(usize, 0), primitiveBody("nosuch").len);
}
