//! The design units other than modules to instructions: one `nature`,
//! `discipline`, `paramset`, `primitive` (UDP), `connectrules` or `config`
//! node in, its instruction and declaration-table row out. A UDP is also
//! checked here (`udp.check`).
//! Cites: VAMS-2023 §3.6.1, §3.6.2, §6.4, §7.7, A.1.5-A.1.9; IEEE
//! 1364-2005 §8.1, §13.3, A.5.
//!
//! Contents:
//! - `pub fn lowerNature(ag: *AstGen, node: Node.Index) Error!void`
//! - `pub fn lowerDiscipline(ag: *AstGen, node: Node.Index) Error!void`
//! - `pub fn lowerParamset(ag: *AstGen, node: Node.Index) Error!void`
//! - `pub fn lowerPrimitive(ag: *AstGen, node: Node.Index) Error!void`
//! - `pub fn lowerConnectRules(ag: *AstGen, node: Node.Index) Error!void`
//! - `pub fn lowerConfig(ag: *AstGen, node: Node.Index) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("../Ast.zig");
const Vir = @import("../Vir.zig");
const AstGen = @import("../AstGen.zig");
const decl = @import("decl.zig");
const expr = @import("expr.zig");
const stmt = @import("stmt.zig");
const prim = @import("prim.zig");
const udp = @import("udp.zig");
const Inst = Vir.Inst;
const Node = Ast.Node;
const Scope = AstGen.Scope;
const Error = AstGen.Error;
const full = Ast.full;

/// §3.6.1 `nature name [: parent[.potential|.flow]] attrs endnature`. An
/// attribute's value names nothing the file declares, so each is lowered
/// in an empty scope.
pub fn lowerNature(ag: *AstGen, node: Node.Index) Error!void {
    const tree = ag.tree;
    const kw = tree.nodeMainToken(node);
    const name = try ag.identString(kw + 1);
    const inst = try ag.unit(.nature, .nature, node, name);
    const parented = tree.tokenTag(kw + 2) == .colon;
    var empty: Scope = .{ .parent = null };
    const attrs = try ag.arena.alloc(Inst.Attr, full.list(tree, node).len);
    for (full.list(tree, node), attrs) |a, *out| out.* = try attr(ag, &empty, a);
    try ag.setPayload(inst, node, Inst.Nature{
        .name = name,
        .parent = if (parented) try ag.identString(kw + 3) else .empty,
        .flags = .{ .parent_kind = if (parented and tree.tokenTag(kw + 4) == .period) (if (tree.tokenTag(kw + 5) == .keyword_potential) .potential else .flow) else .none },
        .attrs = try ag.addList(Inst.Attr, attrs),
    });
}

/// §3.6.2 `discipline name items enddiscipline`.
pub fn lowerDiscipline(ag: *AstGen, node: Node.Index) Error!void {
    const tree = ag.tree;
    const name = try ag.identString(tree.nodeMainToken(node) + 1);
    const inst = try ag.unit(.discipline, .discipline, node, name);
    var empty: Scope = .{ .parent = null };
    const items = full.list(tree, node);
    const out = try ag.arena.alloc(Inst.DisciplineItem, items.len);
    for (items, out) |it, *o| {
        const main = tree.nodeMainToken(it);
        const potential = tree.tokenTag(main) == .keyword_potential;
        o.* = switch (tree.nodeTag(it)) {
            .discipline_binding => .{ .kind = if (potential) .potential else .flow, .name = try ag.identString(tree.nodeData(it).token), .value = .empty },
            .discipline_domain => .{ .kind = .domain, .name = try ag.string(tree.tokenSlice(tree.nodeData(it).token)), .value = .empty },
            .discipline_override => over: {
                const a = try attr(ag, &empty, tree.nodeData(it).node);
                break :over .{ .kind = if (potential) .potential_attr else .flow_attr, .name = a.name, .value = a.value };
            },
            else => own: { // else: a `nature_attr` of the discipline itself
                const a = try attr(ag, &empty, it);
                break :own .{ .kind = .attr, .name = a.name, .value = a.value };
            },
        };
    }
    try ag.setPayload(inst, node, Inst.Discipline{ .name = name, .items = try ag.addList(Inst.DisciplineItem, out) });
}

/// §6.4 `paramset name module ; items endparamset`: its declarations in
/// its own scope, `.name = value` overrides, and statements.
pub fn lowerParamset(ag: *AstGen, node: Node.Index) Error!void {
    const tree = ag.tree;
    const kw = tree.nodeMainToken(node);
    const name = try ag.identString(kw + 1);
    const inst = try ag.unit(.paramset, .paramset, node, name);
    const items = full.list(tree, node);
    var scope: Scope = .{ .parent = null };
    for (items) |it| switch (tree.nodeTag(it)) {
        .param_decl, .var_decl, .aliasparam_decl, .event_decl => try decl.scan(ag, &scope, it),
        else => {}, // else: overrides and statements declare nothing
    };
    const top = ag.scratch.items.len;
    for (items) |it| switch (tree.nodeTag(it)) {
        .param_decl, .var_decl, .aliasparam_decl, .event_decl => try decl.lower(ag, &scope, it),
        .paramset_override => {
            const o = tree.nodeMainToken(it);
            _ = try ag.addPl(.ps_override, it, Inst.Override{ .name = try ag.identString(o + 1), .value = try decl.exprBody(ag, &scope, tree.nodeData(it).node.toOptional()) });
        },
        else => try stmt.lower(ag, &scope, it), // else: a §6.4.3 paramset statement
    };
    const b = try ag.bodyFrom(top);
    try ag.setPayload(inst, node, Inst.Paramset{ .name = name, .module = try ag.identString(kw + 2), .body = b });
}

/// A.5.1 UDP: header names, port declarations (`io`), the `initial`
/// statement, the table rows; then IEEE 1364-2005 §8.1.1 and §8.1.4.
pub fn lowerPrimitive(ag: *AstGen, node: Node.Index) Error!void {
    const tree = ag.tree;
    const u = tree.extraData(tree.nodeData(node).extra, Node.Udp);
    const ports = tree.extraDataSlice(.{ .start = u.ports_start, .end = u.ports_end }, Node.Index);
    const items = tree.extraDataSlice(.{ .start = u.items_start, .end = u.items_end }, Node.Index);
    const name = try ag.identString(tree.nodeMainToken(node) + 1);
    const inst = try ag.unit(.primitive, .primitive, node, name);
    var scope: Scope = .{ .parent = null };
    const names = try ag.arena.alloc(Vir.String, ports.len);
    for (ports, names) |p, *n| {
        n.* = try ag.identString(tree.nodeMainToken(p));
        try decl.declareNode(ag, &scope, .io, p, tree.nodeMainToken(p));
    }
    for (items) |it| if (tree.nodeTag(it) == .port_decl) try decl.scan(ag, &scope, it);
    const top = ag.scratch.items.len;
    for (ports) |p| try headerIo(ag, &scope, p);
    for (items) |it| if (tree.nodeTag(it) == .port_decl) try decl.lower(ag, &scope, it);
    const b = try ag.bodyFrom(top);
    var init: Vir.Body = .empty;
    var rows: Vir.List(Vir.String) = .empty;
    var sequential = false;
    for (items) |it| switch (tree.nodeTag(it)) {
        .udp_initial => {
            const init_top = ag.scratch.items.len;
            const target = try expr.lowerName(ag, &scope, tree.nodeMainToken(it) + 1);
            const value = try expr.lower(ag, &scope, tree.nodeData(it).node);
            _ = try ag.addPl(.store, it, Inst.Bin{ .lhs = target, .rhs = value });
            init = try ag.bodyFrom(init_top);
        },
        .udp_table => {
            const entries = full.list(tree, it);
            const out = try ag.arena.alloc(Vir.String, entries.len);
            for (entries, out, 0..) |e, *o, k| {
                const text = try udp.rowText(ag.arena, tree, e);
                // A.5.3: a sequential entry has a current-state column.
                if (k == 0) sequential = std.mem.count(u8, text, ":") == 2;
                o.* = try ag.string(text);
            }
            rows = try ag.addList(Vir.String, out);
        },
        else => {}, // else: port declarations, lowered above
    };
    try ag.setPayload(inst, node, Inst.Primitive{ .name = name, .flags = .{ .sequential = sequential }, .ports = try ag.addList(Vir.String, names), .body = b, .init = init, .rows = rows });
    try udp.check(ag, node);
}

/// §7.7 `connectrules name ; items endconnectrules`.
pub fn lowerConnectRules(ag: *AstGen, node: Node.Index) Error!void {
    const tree = ag.tree;
    const name = try ag.identString(tree.nodeMainToken(node) + 1);
    const inst = try ag.unit(.connectrules, .connectrules, node, name);
    var empty: Scope = .{ .parent = null };
    const top = ag.scratch.items.len;
    for (full.list(tree, node)) |it| switch (tree.nodeTag(it)) {
        .connect_resolution => {
            const to = tree.nodeData(it).token;
            var names: std.ArrayList(Vir.String) = .empty;
            var i = tree.nodeMainToken(it) + 1;
            while (i < to) : (i += 1) if (AstGen.isName(tree.tokenTag(i))) try names.append(ag.arena, try ag.identString(i));
            const exclude = tree.tokenTag(to + 1) == .keyword_exclude;
            _ = try ag.addPl(.connect_resolve, it, Inst.ConnectResolve{ .flags = .{ .exclude = exclude }, .disciplines = try ag.addList(Vir.String, names.items), .result = if (exclude) .empty else try ag.identString(to + 1) });
        },
        else => try insertion(ag, &empty, it), // else: `connect_insertion`, the other connect statement
    };
    const b = try ag.bodyFrom(top);
    try ag.setPayload(inst, node, Inst.ConnectRules{ .name = name, .body = b });
}

/// IEEE 1364-2005 §13.3 `config`: the design cells and each rule's text.
pub fn lowerConfig(ag: *AstGen, node: Node.Index) Error!void {
    const tree = ag.tree;
    const name = try ag.identString(tree.nodeMainToken(node) + 1);
    const inst = try ag.unit(.config, .config, node, name);
    var cells: std.ArrayList(Vir.String) = .empty;
    var rules: std.ArrayList(Vir.String) = .empty;
    for (full.list(tree, node)) |it| {
        const semi = tree.nodeData(it).token;
        if (tree.nodeTag(it) == .config_design) {
            var i = tree.nodeMainToken(it) + 1;
            while (i < semi) : (i += 1) {
                const dotted = tree.tokenTag(i + 1) == .period;
                const text = if (dotted) try ag.arena.print("{s}.{s}", .{ AstGen.identText(tree, i), AstGen.identText(tree, i + 2) }) else AstGen.identText(tree, i);
                try cells.append(ag.arena, try ag.string(text));
                if (dotted) i += 2;
            }
        } else try rules.append(ag.arena, try ag.string(try tokenText(ag, tree.nodeMainToken(it), semi)));
    }
    try ag.setPayload(inst, node, Inst.Config{ .name = name, .design = try ag.addList(Vir.String, cells.items), .rules = try ag.addList(Vir.String, rules.items) });
}

// ---- private ----

fn attr(ag: *AstGen, scope: *Scope, node: Node.Index) Error!Inst.Attr {
    const tree = ag.tree;
    assert(tree.nodeTag(node) == .nature_attr);
    return .{ .name = try ag.string(tree.tokenSlice(tree.nodeMainToken(node))), .value = try decl.exprBody(ag, scope, tree.nodeData(node).node.toOptional()) };
}

/// A UDP header port: the direction and `reg` written before its name.
fn headerIo(ag: *AstGen, scope: *Scope, p: Node.Index) Error!void {
    const tree = ag.tree;
    const name_tok = tree.nodeMainToken(p);
    var i = name_tok;
    var dir: Inst.Direction = .none;
    var storage: Inst.Storage = .none;
    while (i > 0) {
        i -= 1;
        switch (tree.tokenTag(i)) {
            .keyword_reg => storage = .reg,
            .keyword_output => dir = .output,
            .keyword_input => dir = .input,
            .identifier, .escaped_identifier => {}, // a discipline
            else => break, // else: the `(` or `,` before the port
        }
        if (dir != .none) break;
    }
    const inst = ag.reserved(p);
    const name = try ag.identString(name_tok);
    try ag.fill(inst, p, Inst.Io{
        .name = name,
        .prev = decl.prevOf(scope, name, inst),
        .flags = .{ .dir = dir, .net = .none, .storage = storage, .signed = false, .header = true },
        .discipline = .empty,
        .range = .empty,
        .dims = .empty,
        .init = try decl.exprBody(ag, scope, tree.nodeData(p).extra_and_opt_node[1]),
        .defaults = .empty,
    });
}

/// `connect module [merged|split] [#(params)] [[dir] a, [dir] b] ;`.
fn insertion(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void {
    const tree = ag.tree;
    const x = tree.extraData(tree.nodeData(node).extra, Node.Insertion);
    const kw = tree.nodeMainToken(node);
    const mode = tree.tokenTag(kw + 2);
    var a: Vir.String = .empty;
    var b: Vir.String = .empty;
    var a_dir: Inst.Direction = .none;
    var b_dir: Inst.Direction = .none;
    if (x.overrides.unwrap()) |o| {
        var i = o;
        a_dir = direction(tree.tokenTag(i));
        if (a_dir != .none) i += 1;
        a = try ag.identString(i);
        i += 2;
        b_dir = direction(tree.tokenTag(i));
        if (b_dir != .none) i += 1;
        b = try ag.identString(i);
    }
    const params = tree.extraDataSlice(.{ .start = x.params_start, .end = x.params_end }, Node.OptionalIndex);
    const out = try ag.arena.alloc(Inst.Arg, params.len);
    for (params, out) |s, *arg| {
        const n = s.unwrap().?;
        arg.* = if (tree.nodeTag(n) == .named_param)
            .{ .name = try ag.identString(tree.nodeMainToken(n) + 1), .value = try decl.exprBody(ag, scope, tree.nodeData(n).opt_node) }
        else
            .{ .name = .empty, .value = try decl.exprBody(ag, scope, s) };
    }
    _ = try ag.addPl(.connect_insert, node, Inst.ConnectInsert{
        .module = try ag.identString(kw + 1),
        .flags = .{ .merged = mode == .keyword_merged, .split = mode == .keyword_split, .a_dir = a_dir, .b_dir = b_dir },
        .params = try ag.addList(Inst.Arg, out),
        .a = a,
        .b = b,
    });
}

fn direction(tag: @import("../tokenizer.zig").Token.Tag) Inst.Direction {
    return switch (tag) {
        .keyword_input => .input,
        .keyword_output => .output,
        .keyword_inout => .inout,
        else => .none, // else: a discipline name, no direction written
    };
}

/// Tokens `from..to` as written, joined by single spaces.
fn tokenText(ag: *AstGen, from: Ast.TokenIndex, to: Ast.TokenIndex) Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var i = from;
    while (i < to) : (i += 1) {
        if (i != from) try buf.append(ag.arena, ' ');
        try buf.appendSlice(ag.arena, ag.tree.tokenSlice(i));
    }
    return buf.items;
}
