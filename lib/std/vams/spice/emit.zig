//! One `.MODEL` or `.SUBCKT` card (and a `.SUBCKT`'s body cards) in, the
//! Verilog-AMS module text it stands for appended out: R/C/L/V/I and the four
//! controlled sources by their Table E.1 primitive, X cards as instances of a
//! subcircuit, M/Q/J/D cards through model.zig; anything else in a body is a
//! refusal (E0928).
//! Cites: LRM annex E.1.2, E.2, E.2.2.1-E.2.2.3, E.3, E.3.1, E.4.1, Table
//! E.1; §2.8.1, §3.6.4, §5.4.2, §9.15, A.1.2.
//!
//! Contents:
//! - `pub fn emitCard(`
//! - `pub const device_cards = [_]struct`
//! - `pub const controlled = [_]struct`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const card_ = @import("card.zig");
const model = @import("model.zig");
const Card = card_.Card;
const Refusals = card_.Refusals;
const ModelCard = card_.ModelCard;
const Tokens = card_.Tokens;
const model_types = card_.model_types;
const isIdent = card_.isIdent;
const isSpiceName = card_.isSpiceName;
const spell = card_.spell;
const model_cards = model.model_cards;
const Override = model.Override;

/// Device card letters and the Table E.1 primitive each becomes. E.2.2.3, the
/// only place the LRM says what a device card means, prints `R1 B1 GND 10K` as
/// `resistor #(.r(10k)) R1 (b1, gnd);`, `VA VCC GND 5` as
/// `vsine #(.dc(5)) Vcc (vcc, gnd);` and `IEE E GND 1MA` as
/// `isine #(.dc(1m)) Iee (e, gnd);`: the leading letter picks the primitive and
/// the one positional value lands on `param`. Two terminals and one value is
/// every row; a three-terminal or `k=v` card would need its own arity column.
pub const device_cards = [_]struct { letter: u8, prim: []const u8, param: []const u8 }{
    .{ .letter = 'r', .prim = "resistor", .param = "r" },
    .{ .letter = 'c', .prim = "capacitor", .param = "c" },
    .{ .letter = 'l', .prim = "inductor", .param = "l" },
    .{ .letter = 'v', .prim = "vsine", .param = "dc" },
    .{ .letter = 'i', .prim = "isine", .param = "dc" },
};

/// E.3.1: "the following primitives are not supported: ccvs, cccs, and mutual
/// inductors; however, these primitives can be instantiated inside a SPICE
/// subcircuit". The four SPICE controlled-source letters, as the one
/// contribution each is, in SPICE's own sign convention:
///
///     E n+ n- nc+ nc- gain    V(n+, n-) <+ gain * V(nc+, nc-);   vcvs
///     G n+ n- nc+ nc- gm      I(n+, n-) <+ gm * V(nc+, nc-);     vccs
///     F n+ n- vctl gain       I(n+, n-) <+ gain * I(vctl);       cccs
///     H n+ n- vctl r          V(n+, n-) <+ r * I(vctl);          ccvs
///
/// A V card that controls something is written as a named branch of this
/// module (`branch (p, n) vctl; V(vctl) <+ dc;`) rather than a `vsine`
/// child, so the controlled source reads the flow of a branch its own module
/// declares (§5.4.2) with no cross-instance access.
pub const controlled = [_]struct { letter: u8, lhs: []const u8, rhs: []const u8, by_current: bool }{
    .{ .letter = 'e', .lhs = "V", .rhs = "V", .by_current = false },
    .{ .letter = 'g', .lhs = "I", .rhs = "V", .by_current = false },
    .{ .letter = 'f', .lhs = "I", .rhs = "I", .by_current = true },
    .{ .letter = 'h', .lhs = "V", .rhs = "I", .by_current = true },
};

/// The keywords (HSPICE and ngspice) that open a controlled source's
/// polynomial, behavioural, table or frequency-domain form.
const source_forms = [_][]const u8{ "poly", "value", "table", "laplace", "freq" };

// `emitBody` tries `controlled`, then `model_cards`, then `x`, then
// `device_cards` on a card's first letter: a letter in two of them would
// make the later row unreachable.
comptime {
    for (controlled) |c| {
        assert(c.letter != 'x');
        for (model_cards) |m| assert(c.letter != m.letter);
        for (device_cards) |d| assert(c.letter != d.letter);
    }
    for (model_cards) |m| {
        assert(m.letter != 'x');
        for (device_cards) |d| assert(m.letter != d.letter);
    }
    for (device_cards) |d| assert(d.letter != 'x');
}

const short = "`{s}` has too few fields";

/// Appends the module one complete card stands for, reading `body` (from
/// `card.subcktBody`) when it is a `.SUBCKT`. Returns true when it produced
/// a module. A repeated name produces nothing (the first card wins: E.1.2
/// leaves the choice to "the authors of the simulator"); a `.MODEL` of a
/// type with no Table E.1 row is recorded in `unsupported` as `name type`.
/// Asserts that `at` is not empty.
pub fn emitCard(
    arena: Allocator,
    out: *std.ArrayList(u8),
    at: Card,
    body: []const Card,
    models: []const ModelCard,
    seen: *std.ArrayList([]const u8),
    refusals: *Refusals,
    unsupported: *std.ArrayList([]const u8),
) Allocator.Error!bool {
    const out_before = out.items.len;
    defer assert(out.items.len >= out_before);
    assert(at.text.len > 0);
    // `(` `)` and `,` are noise in a SPICE port list: E.2.2.2's own example
    // writes `.SUBCKT ECPOSC (OUT GND)` with parentheses that carry no meaning.
    var it: Tokens = .{ .text = at.text };
    const kw = it.next() orelse return false;
    const is_model = std.mem.eql(u8, kw, ".model");
    if (!is_model and !std.mem.eql(u8, kw, ".subckt")) return false; // a device card, .tran, .include, ...

    const name = it.next() orelse {
        if (!is_model) try refusals.add(at, "`{s}` names no definition", .{kw});
        return false;
    };
    if (!isSpiceName(name)) {
        if (!is_model) try refusals.add(at, "`{s}` is not a name for a definition", .{name});
        return false;
    }
    for (seen.items) |s| if (std.mem.eql(u8, s, name)) return false;
    // `seen` keeps the bare name: the escape is a spelling of it, so two
    // cards named `wire` are still a repeat.
    const decl = try spell(arena, name);

    if (is_model) {
        const type_ = it.next() orelse return false;
        const row = for (model_types) |r| {
            if (std.mem.eql(u8, r.type_, type_)) break r;
        } else {
            // E.1.2: "a particular SPICE netlist can reference a primitive
            // which is unsupported". Kept, so its use is named as that.
            try seen.append(arena, name);
            try unsupported.append(arena, try arena.print("{s} {s}", .{ name, type_ }));
            return false;
        };
        const params = try model.modelParams(arena, row.prim, &it, name, at, refusals) orelse return false;
        try out.print(arena,
            \\module {s}({s});
            \\   inout {s};
            \\   electrical {s};
            \\{s}   {s} #({s}) prim({s});
            \\endmodule
            \\
            \\
        , .{ decl, row.ports, row.ports, row.ports, params.decls, row.prim, params.args, row.ports });
    } else if (!try emitSubckt(arena, out, at, &it, name, decl, body, models, refusals)) return false;
    try seen.append(arena, name);
    return true;
}

// ---- private ----

/// `.SUBCKT name p1 p2 ... [PARAMS:] [k=v ...]` and its body as a module:
/// ports up to the first parameter (numeric nodes are the SPICE default, so
/// only a parameter ends the list), each `k=v` a real parameter with `v`
/// as its default, a number or a `{expr}` over the parameters before it.
/// Returns false after a refusal of the header.
fn emitSubckt(
    arena: Allocator,
    out: *std.ArrayList(u8),
    at: Card,
    it: *Tokens,
    name: []const u8,
    decl: []const u8,
    body: []const Card,
    models: []const ModelCard,
    refusals: *Refusals,
) Allocator.Error!bool {
    assert(name.len != 0);
    assert(decl.len >= name.len);
    var ports: std.ArrayList([]const u8) = .empty;
    var params: std.ArrayList([]const u8) = .empty;
    var decls: std.ArrayList(u8) = .empty;
    var in_params = false;
    while (it.next()) |t| {
        if (std.mem.eql(u8, t, "params:")) {
            in_params = true;
            continue;
        }
        const eq = std.mem.findScalar(u8, t, '=') orelse {
            if (in_params or !isSpiceName(t)) {
                try refusals.add(at, "`{s}` on `.subckt {s}`: neither a node before the parameters nor a `k=v` parameter", .{ t, name });
                return false;
            }
            try ports.append(arena, try spell(arena, t));
            continue;
        };
        in_params = true;
        if (!isIdent(t[0..eq])) {
            try refusals.add(at, "`{s}` on `.subckt {s}`: `{s}` is not a parameter name", .{ t, name, t[0..eq] });
            return false;
        }
        const v = try model.paramValue(arena, t, eq, name, at, refusals, params.items) orelse return false;
        try decls.print(arena, "   parameter real {s} = {f};\n", .{ try spell(arena, t[0..eq]), v });
        try params.append(arena, t[0..eq]);
    }
    // A.1.2 makes the port list optional, so a portless `.SUBCKT` is a legal
    // module, and an empty `electrical ;` would not be.
    if (ports.items.len == 0) {
        try out.print(arena, "module {s};\n", .{decl});
    } else {
        const list = try std.mem.join(arena, ", ", ports.items);
        try out.print(arena,
            \\module {s}({s});
            \\   inout {s};
            \\   electrical {s};
            \\
        , .{ decl, list, list, list });
    }
    try out.appendSlice(arena, decls.items);
    var inner: std.ArrayList(u8) = .empty;
    try emitBody(arena, &inner, body, models, params.items, refusals);
    // SPICE's node 0 is the global ground inside a subcircuit too. Spelled
    // `\0 ` it would be a local implicit net and every card on it an open;
    // declared `ground`, it is §3.6.4's "global reference node".
    const zero_port = for (ports.items) |pt| {
        if (std.mem.eql(u8, pt, "\\0 ")) break true;
    } else false;
    if (!zero_port and std.mem.find(u8, inner.items, "\\0 ") != null)
        try out.appendSlice(arena, "   electrical \\0 ;\n   ground \\0 ;\n");
    try out.appendSlice(arena, inner.items);
    try out.appendSlice(arena, "endmodule\n\n");
    return true;
}

/// Appends the instance lines and analog contributions a `.SUBCKT`'s device
/// cards become. `scope` is the subcircuit's parameters, the names a
/// `{expr}` value may read. A card this cannot read is refused: a letter
/// with no row and not `X` (`S`, `T`, `K`), a value that is a model name or
/// an expression `expr` does not read, a missing or extra field, a
/// controlled source in its `POLY`/`VALUE`/`TABLE`/`LAPLACE` form, a nested
/// `.SUBCKT` or any other dot card. A node the port list does not name is an
/// implicit net of the module (§7.5).
fn emitBody(
    arena: Allocator,
    out: *std.ArrayList(u8),
    body: []const Card,
    models: []const ModelCard,
    scope: []const []const u8,
    refusals: *Refusals,
) Allocator.Error!void {
    const out_before = out.items.len;
    defer assert(out.items.len >= out_before);
    // The V cards an F or H card reads the current of, by name.
    var controls: std.ArrayList([]const u8) = .empty;
    for (body) |c| {
        var it: Tokens = .{ .text = c.text };
        const inst = it.next() orelse continue;
        if (inst[0] != 'f' and inst[0] != 'h') continue;
        _ = it.next() orelse continue;
        _ = it.next() orelse continue;
        try controls.append(arena, it.next() orelse continue);
    }
    var analog: std.ArrayList(u8) = .empty;
    for (body) |at| {
        var it: Tokens = .{ .text = at.text };
        const inst = it.next() orelse continue;
        if (inst[0] == '.') {
            if (std.mem.eql(u8, inst, ".subckt"))
                try refusals.add(at, "a `.subckt` inside a `.subckt` body: nested subcircuits are not read", .{})
            else
                try refusals.add(at, "`{s}` inside a `.subckt` body is not read", .{inst});
            continue;
        }
        if (for (controlled) |c| {
            if (inst[0] == c.letter) break c;
        } else null) |c| {
            try emitControlled(arena, &analog, at, inst, &it, c, body, scope, refusals);
            continue;
        }
        if (for (model_cards) |m| {
            if (inst[0] == m.letter) break m;
        } else null) |m| {
            try model.emitModelCard(arena, out, at, inst, &it, m, models, scope, refusals);
            continue;
        }
        if (inst[0] == 'x') {
            try emitSubcktCard(arena, out, at, inst, &it, scope, refusals);
            continue;
        }
        const row = for (device_cards) |d| {
            if (inst[0] == d.letter) break d;
        } else {
            try refusals.add(at, "`{s}`: a `{c}` device card is not one VerA reads in a subcircuit (R, C, L, V, I, E, F, G, H, M, Q, J, D, X)", .{ inst, inst[0] });
            continue;
        };
        const p = it.next() orelse {
            try refusals.add(at, short, .{inst});
            continue;
        };
        const n = it.next() orelse {
            try refusals.add(at, short, .{inst});
            continue;
        };
        const value = try model.cardValue(arena, it.next(), &it, inst, at, refusals, scope) orelse continue;
        if (row.letter == 'v' and for (controls.items) |v| {
            if (std.mem.eql(u8, v, inst)) break true;
        } else false) {
            // An independent source, so §9.15's source-stepping factor scales
            // it, as it does the Annex E sources.
            const name = try spell(arena, inst);
            try out.print(arena, "   branch ({s}, {s}) {s};\n", .{ try spell(arena, p), try spell(arena, n), name });
            try analog.print(arena, "      V({s}) <+ $simparam(\"sourceScaleFactor\") * {f};\n", .{ name, value });
            continue;
        }
        try out.print(arena, "   {s} #(.{s}({f})) {s}({s}, {s});\n", .{
            row.prim, row.param, value, try spell(arena, inst), try spell(arena, p), try spell(arena, n),
        });
    }
    if (analog.items.len != 0) try out.print(arena, "   analog begin\n{s}   end\n", .{analog.items});
}

/// Appends the contribution an E/G/F/H card is (`controlled`), or refuses
/// it. Its `inst` field is already read from `it`.
fn emitControlled(
    arena: Allocator,
    analog: *std.ArrayList(u8),
    at: Card,
    inst: []const u8,
    it: *Tokens,
    c: @TypeOf(controlled[0]),
    body: []const Card,
    scope: []const []const u8,
    refusals: *Refusals,
) Allocator.Error!void {
    assert(inst[0] == c.letter);
    const analog_before = analog.items.len;
    defer assert(analog.items.len >= analog_before);
    const p = try spell(arena, it.next() orelse return refusals.add(at, short, .{inst}));
    const n = try spell(arena, it.next() orelse return refusals.add(at, short, .{inst}));
    // SPICE's other shapes of these letters put a keyword where the control
    // goes; read as nodes, `E1 A B POLY(1) 5` would be a gain on V(poly, 1).
    var look = it.*;
    const field = look.next() orelse "";
    const key = field[0 .. std.mem.findScalar(u8, field, '=') orelse field.len];
    for (source_forms) |k| if (std.mem.eql(u8, k, key))
        return refusals.add(at, "`{s}`: the `{s}` form of a controlled source is not read", .{ inst, key });
    // The controlling quantity: a V card's branch, or a node pair.
    const ctl = if (c.by_current) blk: {
        const v = it.next() orelse return refusals.add(at, short, .{inst});
        if (v[0] != 'v' or !declares(body, v))
            return refusals.add(at, "`{s}` reads the current of `{s}`, which is not a V card of this subcircuit", .{ inst, v });
        break :blk try spell(arena, v);
    } else try arena.print("{s}, {s}", .{
        try spell(arena, it.next() orelse return refusals.add(at, short, .{inst})),
        try spell(arena, it.next() orelse return refusals.add(at, short, .{inst})),
    });
    const gain = try model.cardValue(arena, it.next(), it, inst, at, refusals, scope) orelse return;
    try analog.print(arena, "      {s}({s}, {s}) <+ {f} * {s}({s});\n", .{ c.lhs, p, n, gain, c.rhs, ctl });
}

/// Appends the instance an X card is: `Xname n1 ... nk subckt [PARAMS:]
/// [k=v ...]`, an instance of the subcircuit (or any module or paramset of
/// the design) `subckt`, connected by position (E.2), each `k=v` an
/// override, a number or a `{expr}` over `scope`, and `M=` E.4.1's
/// `$mfactor`.
fn emitSubcktCard(
    arena: Allocator,
    out: *std.ArrayList(u8),
    at: Card,
    inst: []const u8,
    it: *Tokens,
    scope: []const []const u8,
    refusals: *Refusals,
) Allocator.Error!void {
    assert(at.text.len > 0);
    assert(inst[0] == 'x');
    var plain: std.ArrayList([]const u8) = .empty;
    var over: std.ArrayList(Override) = .empty;
    while (it.next()) |t| {
        if (std.mem.eql(u8, t, "params:")) continue;
        const eq = std.mem.findScalar(u8, t, '=') orelse {
            if (over.items.len != 0)
                return refusals.add(at, "`{s}`: the field `{s}` after its parameters is not read", .{ inst, t });
            try plain.append(arena, t);
            continue;
        };
        try model.setOverride(arena, &over, t[0..eq], try model.paramValue(arena, t, eq, inst, at, refusals, scope) orelse return);
    }
    const sub = plain.pop() orelse return refusals.add(at, "`{s}` names no subcircuit", .{inst});
    try model.emitInstance(arena, out, sub, over.items, inst, plain.items);
}

/// Reports whether `body` holds a card named `name`.
fn declares(body: []const Card, name: []const u8) bool {
    for (body) |c| {
        var it: Tokens = .{ .text = c.text };
        if (std.mem.eql(u8, it.next() orelse continue, name)) return true;
    }
    return false;
}
