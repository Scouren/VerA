//! Declarations (A.2) to their declaring instructions: one Ast declaration
//! node in, one reserved instruction filled per declared name out (`io`,
//! `net`, `variable`, `param`, `aliasparam`, `genvar`, `event`, `branch`).
//! The type words the tree leaves in tokens (discipline, net type,
//! `signed`, variable type, strengths) are read back here. A scope's scan
//! (`scan`) reserves and declares; the lowering (`lower`) fills, in order.
//! Cites: VAMS-2023 §3.2-§3.4.7, §3.6.3, §3.7, §3.12, §6.5.2, §10.2,
//! A.2.1-A.2.5; IEEE 1364-2005 §4.10.1, A.2.2.2.
//!
//! Contents:
//! - `pub const TypeWords = struct`, `pub fn typeWords(tree: *const Ast, first: Ast.TokenIndex) TypeWords`
//! - `pub fn scan(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void`
//! - `pub fn lower(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void`
//! - `pub fn declaratorDims(tree: *const Ast, d: Node.Index) []const Node.Index`
//! - `pub fn exprBody(ag: *AstGen, scope: *Scope, node: Node.OptionalIndex) Error!Vir.Body`
//! - `pub fn rangeBody(ag: *AstGen, scope: *Scope, ranges: []const Node.Index) Error!Vir.Body`
//! - `pub fn exprsOf(ag: *AstGen, scope: *Scope, nodes: []const Node.OptionalIndex) Error!Inst.Exprs`
//! - `pub fn declareNode(ag: *AstGen, scope: *Scope, tag: Inst.Tag, node: Node.Index, name_tok: ?Ast.TokenIndex) Error!void`
//! - `pub fn prevOf(scope: *const Scope, name: Vir.String, inst: Inst.Index) Inst.Ref`
//! - `pub fn delayExprs(ag: *AstGen, scope: *Scope, node: Node.Index) Error!Inst.Exprs`
//! - `pub fn strengthString(ag: *AstGen, lp: ?Ast.TokenIndex) Error!Vir.String`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("../Ast.zig");
const Vir = @import("../Vir.zig");
const AstGen = @import("../AstGen.zig");
const expr = @import("expr.zig");
const Token = @import("../tokenizer.zig").Token;
const Inst = Vir.Inst;
const Node = Ast.Node;
const Scope = AstGen.Scope;
const Error = AstGen.Error;
const full = Ast.full;

/// The type words before a declaration's names, as the tree leaves them in
/// tokens: `[discipline] [net_type|wreal|ground] [signed]
/// [reg|integer|...] [signed]`, a strength group, `vectored`/`scalared`.
pub const TypeWords = struct {
    discipline: ?Ast.TokenIndex = null,
    net: Inst.NetKind = .none,
    storage: Inst.Storage = .none,
    signed: bool = false,
    vectored: bool = false,
    scalared: bool = false,
    /// The `(` of a strength group.
    strength: ?Ast.TokenIndex = null,
};

/// Reads the type words starting at `first`, up to a range, a delay or the
/// first name.
pub fn typeWords(tree: *const Ast, first: Ast.TokenIndex) TypeWords {
    var t: TypeWords = .{};
    var i = first;
    while (i < tree.tokens.len) : (i += 1) switch (tree.tokenTag(i)) {
        .identifier, .escaped_identifier => {
            // A discipline is a name another name follows, or a range and
            // then a name (A.2.1.3 `discipline_identifier [range]
            // list_of_net_identifiers`).
            if (t.discipline != null or !AstGen.isName(tree.tokenTag(rangeEnd(tree, i + 1)))) return t;
            t.discipline = i;
        },
        .keyword_wire => t.net = .wire,
        .keyword_tri => t.net = .tri,
        .keyword_tri0 => t.net = .tri0,
        .keyword_tri1 => t.net = .tri1,
        .keyword_wand => t.net = .wand,
        .keyword_triand => t.net = .triand,
        .keyword_wor => t.net = .wor,
        .keyword_trior => t.net = .trior,
        .keyword_trireg => t.net = .trireg,
        .keyword_uwire => t.net = .uwire,
        .keyword_supply0 => t.net = .supply0,
        .keyword_supply1 => t.net = .supply1,
        .keyword_wreal => t.net = .wreal,
        .keyword_ground => t.net = .ground,
        .keyword_signed => t.signed = true,
        .keyword_vectored => t.vectored = true,
        .keyword_scalared => t.scalared = true,
        .keyword_reg => t.storage = .reg,
        .keyword_integer => t.storage = .integer,
        .keyword_real => t.storage = .real,
        .keyword_realtime => t.storage = .realtime,
        .keyword_time => t.storage = .time,
        .keyword_string => t.storage = .string,
        .keyword_input, .keyword_output, .keyword_inout, .keyword_parameter, .keyword_localparam, .keyword_specparam, .keyword_automatic => {},
        .l_paren => {
            // A.2.2.2 strengths: skip to the `)`.
            t.strength = i;
            while (tree.tokenTag(i) != .r_paren and tree.tokenTag(i) != .eof) i += 1;
        },
        else => return t,
    };
    return t;
}

/// Reserves and declares in `scope` every name declaration `node` makes.
pub fn scan(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void {
    const tree = ag.tree;
    switch (tree.nodeTag(node)) {
        .param_decl => for (full.decl(tree, node).items) |a| try declare(ag, scope, .param, a, tree.nodeMainToken(a)),
        .port_decl => for (full.decl(tree, node).items) |d| try declare(ag, scope, .io, d, tree.nodeMainToken(d)),
        .var_decl => for (full.decl(tree, node).items) |d| try declare(ag, scope, .variable, d, tree.nodeMainToken(d)),
        .genvar_decl, .event_decl => for (full.list(tree, node)) |d| try declare(ag, scope, if (tree.nodeTag(node) == .genvar_decl) .genvar else .event, d, tree.nodeMainToken(d)),
        .aliasparam_decl => try declare(ag, scope, .aliasparam, node, tree.nodeMainToken(node) + 1),
        .net_decl => {
            const x = tree.extraData(tree.nodeData(node).extra, Node.NetDecl);
            for (tree.extraDataSlice(.{ .start = x.items_start, .end = x.items_end }, Node.Index)) |d| {
                const name = tree.nodeMainToken(d);
                // Annex F.2.1: an out-of-context `top.mid.sig` names another scope's net.
                const dotted = tree.tokenTag(name) == .system_identifier or tree.tokenTag(name + 1) == .period;
                try declareNode(ag, scope, .net, d, if (dotted) null else name);
            }
        },
        .branch_decl => {
            const x = tree.extraData(tree.nodeData(node).extra, Node.Branch);
            for (tree.extraDataSlice(.{ .start = x.items_start, .end = x.items_end }, Node.Index)) |d| try declare(ag, scope, .branch, d, tree.nodeMainToken(d));
        },
        else => unreachable, // else: the callers pass declaration nodes only
    }
}

/// Fills the instructions `scan` reserved for `node`, in the current body.
pub fn lower(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void {
    const tree = ag.tree;
    switch (tree.nodeTag(node)) {
        .param_decl => try lowerParams(ag, scope, node),
        .port_decl => try lowerIos(ag, scope, node),
        .var_decl => {
            const d = full.decl(tree, node);
            const t = typeWords(tree, d.main_token);
            for (d.items) |x| {
                const inst = ag.reserved(x);
                const name = try ag.identString(tree.nodeMainToken(x));
                try ag.fill(inst, x, Inst.Variable{
                    .name = name,
                    .prev = prevOf(scope, name, inst),
                    .flags = .{ .storage = t.storage, .signed = t.signed },
                    .discipline = try nameOr(ag, t.discipline),
                    .range = try exprBody(ag, scope, d.range),
                    .dims = try rangeBody(ag, scope, declaratorDims(tree, x)),
                    .init = try exprBody(ag, scope, tree.nodeData(x).extra_and_opt_node[1]),
                });
            }
        },
        .genvar_decl, .event_decl => for (full.list(tree, node)) |x| {
            const inst = ag.reserved(x);
            const name = try ag.identString(tree.nodeMainToken(x));
            try ag.fill(inst, x, Inst.Name{ .name = name, .prev = prevOf(scope, name, inst), .dims = try rangeBody(ag, scope, declaratorDims(tree, x)) });
        },
        .aliasparam_decl => {
            const inst = ag.reserved(node);
            const target_tok = tree.nodeMainToken(node) + 3;
            const target = try ag.identString(target_tok);
            const original: Inst.Ref = if (scope.lookup(target)) |i| i.toRef() else .none;
            const name = try ag.identString(tree.nodeMainToken(node) + 1);
            try ag.fill(inst, node, Inst.Aliasparam{ .name = name, .prev = prevOf(scope, name, inst), .target = target, .original = original });
        },
        .net_decl => try lowerNets(ag, scope, node),
        .branch_decl => {
            const x = tree.extraData(tree.nodeData(node).extra, Node.Branch);
            for (tree.extraDataSlice(.{ .start = x.items_start, .end = x.items_end }, Node.Index)) |d| {
                const inst = ag.reserved(d);
                const name = try ag.identString(tree.nodeMainToken(d));
                try ag.fill(inst, d, Inst.Branch{
                    .name = name,
                    .prev = prevOf(scope, name, inst),
                    .range = try rangeBody(ag, scope, declaratorDims(tree, d)),
                    .hi = try exprBody(ag, scope, x.hi.toOptional()),
                    .lo = try exprBody(ag, scope, x.lo),
                });
            }
        },
        else => unreachable, // else: the callers pass declaration nodes only
    }
}

/// A declarator's dimensions (`declarator`: `extra_and_opt_node`, the
/// extra a `SubRange`).
pub fn declaratorDims(tree: *const Ast, d: Node.Index) []const Node.Index {
    assert(tree.nodeTag(d) == .declarator);
    const range = tree.extraData(tree.nodeData(d).extra_and_opt_node[0], Node.SubRange);
    return tree.extraDataSlice(range, Node.Index);
}

/// A body computing `node`, empty for none; its value is its last instruction.
pub fn exprBody(ag: *AstGen, scope: *Scope, node: Node.OptionalIndex) Error!Vir.Body {
    const n = node.unwrap() orelse return .empty;
    const top = ag.scratch.items.len;
    _ = try expr.lower(ag, scope, n);
    return ag.bodyFrom(top);
}

/// A body of one `range` instruction per `range` node, in order.
pub fn rangeBody(ag: *AstGen, scope: *Scope, ranges: []const Node.Index) Error!Vir.Body {
    const top = ag.scratch.items.len;
    for (ranges) |r| _ = try expr.lower(ag, scope, r);
    return ag.bodyFrom(top);
}

/// One body computing every slot of `nodes`; a none slot is a none value.
pub fn exprsOf(ag: *AstGen, scope: *Scope, nodes: []const Node.OptionalIndex) Error!Inst.Exprs {
    const top = ag.scratch.items.len;
    const values = try ag.arena.alloc(Inst.Ref, nodes.len);
    for (nodes, values) |n, *v| v.* = if (n.unwrap()) |x| try expr.lower(ag, scope, x) else .none;
    const b = try ag.bodyFrom(top);
    return .{ .body = b, .values = try ag.addList(Inst.Ref, values) };
}

/// Reserves `tag` for declaring node `node` and declares the name token
/// `name_tok` in `scope` (none: a declaration that enters no scope).
pub fn declareNode(ag: *AstGen, scope: *Scope, tag: Inst.Tag, node: Node.Index, name_tok: ?Ast.TokenIndex) Error!void {
    const inst = try ag.reserve(tag, node);
    try ag.decl_insts.putNoClobber(ag.gpa, node, inst);
    if (name_tok) |t| _ = try scope.declare(ag.arena, try ag.identString(t), inst);
}

/// The first declaration of `name` in `scope` when that is not `inst`.
pub fn prevOf(scope: *const Scope, name: Vir.String, inst: Inst.Index) Inst.Ref {
    const first = scope.names.get(name) orelse return .none;
    return if (first == inst) .none else first.toRef();
}

/// A `delay` node's values.
pub fn delayExprs(ag: *AstGen, scope: *Scope, node: Node.Index) Error!Inst.Exprs {
    const tree = ag.tree;
    assert(tree.nodeTag(node) == .delay);
    return exprsOf(ag, scope, @ptrCast(full.list(tree, node)));
}

/// The words of a strength group at `lp` joined by commas, or empty.
pub fn strengthString(ag: *AstGen, lp: ?Ast.TokenIndex) Error!Vir.String {
    const open = lp orelse return .empty;
    const tree = ag.tree;
    var buf: std.ArrayList(u8) = .empty;
    var i = open + 1;
    while (tree.tokenTag(i) != .r_paren and tree.tokenTag(i) != .eof) : (i += 1) try buf.appendSlice(ag.arena, tree.tokenSlice(i));
    return ag.string(buf.items);
}

// ---- private ----

/// The token after a bracketed range that opens at `i`, or `i` itself when
/// none does. Brackets nest; the scan stops at the end of the text.
fn rangeEnd(tree: *const Ast, i: Ast.TokenIndex) Ast.TokenIndex {
    if (tree.tokenTag(i) != .l_bracket) return i;
    var depth: u32 = 0;
    var k = i;
    while (k < tree.tokens.len) : (k += 1) switch (tree.tokenTag(k)) {
        .l_bracket => depth += 1,
        .r_bracket => {
            depth -= 1;
            if (depth == 0) return k + 1;
        },
        .eof => return k,
        else => {}, // else: a range's contents
    };
    return i;
}

fn declare(ag: *AstGen, scope: *Scope, tag: Inst.Tag, node: Node.Index, name_tok: Ast.TokenIndex) Error!void {
    try declareNode(ag, scope, tag, node, name_tok);
}

fn nameOr(ag: *AstGen, tok: ?Ast.TokenIndex) Error!Vir.String {
    return if (tok) |t| ag.identString(t) else .empty;
}

fn lowerParams(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void {
    const tree = ag.tree;
    const d = full.decl(tree, node);
    const t = typeWords(tree, d.main_token);
    const kw = tree.tokenTag(d.main_token);
    // A parameter is a constant expression: A.8.4's `( constant_mintypmax_expression )` holds even in an analog block.
    const analog = ag.analog;
    ag.analog = false;
    defer ag.analog = analog;
    for (d.items) |a| {
        const pa = tree.extraData(tree.nodeData(a).extra, Node.ParamAssign);
        const inst = ag.reserved(a);
        const top = ag.scratch.items.len;
        for (tree.extraDataSlice(.{ .start = pa.ranges_start, .end = pa.ranges_end }, Node.Index)) |r| try ag.scratch.append(ag.gpa, @backingInt(r));
        const range_nodes = try ag.arena.dupe(u32, ag.scratch.items[top..]);
        ag.scratch.shrinkRetainingCapacity(top);
        const ranges = try ag.arena.alloc(Inst.ValueRange, range_nodes.len);
        for (range_nodes, ranges) |r, *out| out.* = try valueRange(ag, scope, @fromBackingInt(r));
        const name = try ag.identString(tree.nodeMainToken(a));
        try ag.fill(inst, a, Inst.Param{
            .name = name,
            .prev = prevOf(scope, name, inst),
            .flags = .{
                .kind = switch (kw) {
                    .keyword_localparam => .localparam,
                    .keyword_specparam => .specparam,
                    else => .parameter, // else: `param_decl` opens with one of the three keywords
                },
                .storage = t.storage,
                .signed = t.signed,
                .local = kw == .keyword_localparam or (kw == .keyword_parameter and ag.header_params),
            },
            .range = try exprBody(ag, scope, d.range),
            .dims = try rangeBody(ag, scope, tree.extraDataSlice(.{ .start = pa.dims_start, .end = pa.dims_end }, Node.Index)),
            .value = try exprBody(ag, scope, pa.value.toOptional()),
            .ranges = try ag.addList(Inst.ValueRange, ranges),
        });
    }
}

fn valueRange(ag: *AstGen, scope: *Scope, node: Node.Index) Error!Inst.ValueRange {
    const tree = ag.tree;
    const v = tree.extraData(tree.nodeData(node).extra, Node.ValueRange);
    const main = tree.nodeMainToken(node);
    const close = v.close.unwrap();
    return .{
        .flags = .{
            .exclude = tree.tokenTag(main) == .keyword_exclude,
            .lo_closed = tree.tokenTag(main + 1) == .l_bracket,
            .hi_closed = if (close) |c| tree.tokenTag(c) == .r_bracket else false,
            .interval = close != null,
            .set = tree.nodeTag(v.lo) == .assign_pattern and close == null,
        },
        .lo = try exprBody(ag, scope, v.lo.toOptional()),
        .hi = try exprBody(ag, scope, v.hi),
    };
}

fn lowerIos(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void {
    const tree = ag.tree;
    const d = full.decl(tree, node);
    const t = typeWords(tree, d.main_token);
    const dir: Inst.Direction = switch (tree.tokenTag(d.main_token)) {
        .keyword_input => .input,
        .keyword_output => .output,
        .keyword_inout => .inout,
        else => .none, // else: a UDP's `reg q;` declares no direction
    };
    const defaults = try ag.defaultsAt(d.main_token);
    for (d.items) |x| {
        const inst = ag.reserved(x);
        const name = try ag.identString(tree.nodeMainToken(x));
        try ag.fill(inst, x, Inst.Io{
            .name = name,
            .prev = prevOf(scope, name, inst),
            .flags = .{ .dir = dir, .net = t.net, .storage = t.storage, .signed = t.signed, .header = false },
            .discipline = try nameOr(ag, t.discipline),
            .range = try exprBody(ag, scope, d.range),
            .dims = try rangeBody(ag, scope, declaratorDims(tree, x)),
            .init = try exprBody(ag, scope, tree.nodeData(x).extra_and_opt_node[1]),
            .defaults = defaults,
        });
    }
}

fn lowerNets(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void {
    const tree = ag.tree;
    const main = tree.nodeMainToken(node);
    const x = tree.extraData(tree.nodeData(node).extra, Node.NetDecl);
    const t = typeWords(tree, main);
    const defaults = try ag.defaultsAt(main);
    const strength = try strengthString(ag, t.strength);
    for (tree.extraDataSlice(.{ .start = x.items_start, .end = x.items_end }, Node.Index)) |d| {
        const inst = ag.reserved(d);
        const name_tok = tree.nodeMainToken(d);
        const dotted = tree.tokenTag(name_tok) == .system_identifier or tree.tokenTag(name_tok + 1) == .period;
        const delay: Inst.Exprs = if (x.delay.unwrap()) |dl| try delayExprs(ag, scope, dl) else .{ .body = .empty, .values = .empty };
        const name = if (dotted) try dottedName(ag, name_tok) else try ag.identString(name_tok);
        try ag.fill(inst, d, Inst.Net{
            .name = name,
            .prev = if (dotted) .none else prevOf(scope, name, inst),
            .flags = .{ .net = t.net, .signed = t.signed, .vectored = t.vectored, .scalared = t.scalared },
            .discipline = try nameOr(ag, t.discipline),
            .strength = strength,
            .range = try exprBody(ag, scope, x.range),
            .dims = try rangeBody(ag, scope, declaratorDims(tree, d)),
            .delay = delay,
            .init = try exprBody(ag, scope, tree.nodeData(d).extra_and_opt_node[1]),
            .defaults = defaults,
        });
    }
}

/// The text of a dotted out-of-context name, its segments joined by `.`.
fn dottedName(ag: *AstGen, first: Ast.TokenIndex) Error!Vir.String {
    const tree = ag.tree;
    var buf: std.ArrayList(u8) = .empty;
    var i = first;
    while (true) {
        try buf.appendSlice(ag.arena, AstGen.identText(tree, i));
        if (tree.tokenTag(i + 1) != .period) break;
        try buf.append(ag.arena, '.');
        i += 2;
    }
    return ag.string(buf.items);
}
