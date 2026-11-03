//! Instances, continuous assignments and specify blocks to instructions:
//! a module, UDP or gate instantiation node in, one `instance` per instance
//! out (filling what the scope scan reserved); an `assign` or `defparam`
//! node in, one instruction per assignment out; a specify block in, a
//! `specify` with its specparams, paths, pulse styles and timing checks.
//! Cites: VAMS-2023 §6.3.1, §6.3.2, §6.5.6, §6.5.7, A.4.1; IEEE 1364-2005
//! §6.1, §7, §14, §15, A.2.2.2, A.3, A.5.4, A.7.
//!
//! Contents:
//! - `pub fn moduleInstances(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void`
//! - `pub fn gateInstances(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void`
//! - `pub fn assigns(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void`
//! - `pub fn specify(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("../Ast.zig");
const Vir = @import("../Vir.zig");
const AstGen = @import("../AstGen.zig");
const decl = @import("decl.zig");
const expr = @import("expr.zig");
const Token = @import("../tokenizer.zig").Token;
const Inst = Vir.Inst;
const Node = Ast.Node;
const Scope = AstGen.Scope;
const Error = AstGen.Error;
const full = Ast.full;

const no_exprs: Inst.Exprs = .{ .body = .empty, .values = .empty };

/// A.4.1 `module [#(params)] instances ;`: the parameter values are lowered
/// once and shared by every instance of the statement.
pub fn moduleInstances(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void {
    const tree = ag.tree;
    const x = tree.extraData(tree.nodeData(node).extra, Node.Instantiation);
    const params = try args(ag, scope, tree.extraDataSlice(.{ .start = x.params_start, .end = x.params_end }, Node.OptionalIndex));
    const target = try ag.identString(tree.nodeMainToken(node));
    for (tree.extraDataSlice(.{ .start = x.items_start, .end = x.items_end }, Node.Index)) |i| {
        const inst = ag.reserved(i);
        const in = tree.extraData(tree.nodeData(i).extra, Node.Instance);
        const name = try ag.identString(tree.nodeMainToken(i));
        try ag.fill(inst, i, Inst.Instance{
            .name = name,
            .prev = decl.prevOf(scope, name, inst),
            .target = target,
            .flags = .{ .kind = .module },
            .strength = .empty,
            .delay = no_exprs,
            .range = try decl.exprBody(ag, scope, in.range),
            .params = params,
            .conns = try args(ag, scope, tree.extraDataSlice(.{ .start = in.conns_start, .end = in.conns_end }, Node.OptionalIndex)),
            .defaults = .empty,
        });
    }
}

/// A.3 gate and switch instances and A.5.4 UDP instances: `target` the
/// gate keyword or UDP name, the terminals ordered connections.
pub fn gateInstances(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void {
    const tree = ag.tree;
    const d = full.decl(tree, node);
    const gate = tree.nodeTag(node) == .gate_instantiation;
    const target = if (gate) try ag.string(tree.tokenSlice(d.main_token)) else try ag.identString(d.main_token);
    const lp = d.main_token + 1;
    const strength = if (tree.tokenTag(lp) == .l_paren and strengthWord(tree.tokenTag(lp + 1))) try decl.strengthString(ag, lp) else .empty;
    const delay = if (d.range.unwrap()) |dl| try decl.delayExprs(ag, scope, dl) else no_exprs;
    for (d.items) |g| {
        const inst = ag.reserved(g);
        const gi = tree.extraData(tree.nodeData(g).extra, Node.GateInstance);
        const first = tree.nodeMainToken(g);
        const name: Vir.String = if (AstGen.isName(tree.tokenTag(first))) try ag.identString(first) else .empty;
        const terms = tree.extraDataSlice(.{ .start = gi.terms_start, .end = gi.terms_end }, Node.OptionalIndex);
        try ag.fill(inst, g, Inst.Instance{
            .name = name,
            .prev = if (name == .empty) .none else decl.prevOf(scope, name, inst),
            .target = target,
            .flags = .{ .kind = if (gate) .gate else .udp },
            .strength = strength,
            .delay = delay,
            .range = try decl.exprBody(ag, scope, gi.range),
            .params = .empty,
            .conns = try args(ag, scope, terms),
            .defaults = try ag.defaultsAt(d.main_token),
        });
    }
}

/// A.6.1 continuous assignments and §6.3.1 defparams, one per `lhs = rhs`.
pub fn assigns(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void {
    const tree = ag.tree;
    const cont = tree.nodeTag(node) == .continuous_assign;
    const items = if (cont) full.decl(tree, node).items else full.list(tree, node);
    var strength: Vir.String = .empty;
    var delay = no_exprs;
    if (cont) {
        const kw = tree.nodeMainToken(node);
        if (tree.tokenTag(kw + 1) == .l_paren) strength = try decl.strengthString(ag, kw + 1);
        if (full.decl(tree, node).range.unwrap()) |dl| delay = try decl.delayExprs(ag, scope, dl);
    }
    for (items) |a| {
        const pair = tree.nodeData(a).node_and_node;
        _ = try ag.addPl(if (cont) .assign else .defparam, a, Inst.Assign{
            .strength = strength,
            .delay = delay,
            .lhs = try decl.exprBody(ag, scope, pair[0].toOptional()),
            .rhs = try decl.exprBody(ag, scope, pair[1].toOptional()),
        });
    }
}

/// A.7.1 `specify items endspecify`; its specparams were declared in the
/// module's scope.
pub fn specify(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void {
    const tree = ag.tree;
    const top = ag.scratch.items.len;
    for (full.list(tree, node)) |item| switch (tree.nodeTag(item)) {
        .param_decl => try decl.lower(ag, scope, item),
        .specify_terminals => _ = try ag.addPl(.pulse_style, item, Inst.PulseStyle{
            .keyword = try ag.string(tree.tokenSlice(tree.nodeMainToken(item))),
            .terms = try decl.exprsOf(ag, scope, @ptrCast(full.list(tree, item))),
        }),
        .path_decl => try path(ag, scope, item),
        .timing_check => try timingCheck(ag, scope, item),
        else => unreachable, // else: `Parse.parseSpecifyItem` makes these four only
    };
    const b = try ag.bodyFrom(top);
    _ = try ag.addPl(.specify, node, Inst.Process{ .body = b });
}

// ---- private ----

/// A.2.2.2: whether `tag` opens a strength group.
fn strengthWord(tag: Token.Tag) bool {
    return switch (tag) {
        .keyword_supply0, .keyword_strong0, .keyword_pull0, .keyword_weak0, .keyword_highz0, .keyword_supply1, .keyword_strong1, .keyword_pull1, .keyword_weak1, .keyword_highz1, .keyword_small, .keyword_medium, .keyword_large => true,
        else => false,
    };
}

/// Parameter values or connections: an expression, `.name(value)`
/// (`named_param`/`named_port`) or an omitted slot.
fn args(ag: *AstGen, scope: *Scope, slots: []const Node.OptionalIndex) Error!Vir.List(Inst.Arg) {
    const tree = ag.tree;
    const out = try ag.arena.alloc(Inst.Arg, slots.len);
    for (slots, out) |s, *a| {
        const n = s.unwrap() orelse {
            a.* = .{ .name = .empty, .value = .empty };
            continue;
        };
        a.* = switch (tree.nodeTag(n)) {
            .named_param, .named_port => .{ .name = try ag.identString(tree.nodeMainToken(n) + 1), .value = try decl.exprBody(ag, scope, tree.nodeData(n).opt_node) },
            else => .{ .name = .empty, .value = try decl.exprBody(ag, scope, s) }, // else: an ordered expression
        };
    }
    return ag.addList(Inst.Arg, out);
}

/// A.7.2 path: its shape read from the tokens around its nodes.
fn path(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void {
    const tree = ag.tree;
    const p = tree.extraData(tree.nodeData(node).extra, Node.Path);
    const inputs = tree.extraDataSlice(.{ .start = p.inputs_start, .end = p.inputs_end }, Node.OptionalIndex);
    const first_in = tree.nodeMainToken(inputs[0].unwrap().?);
    const polarity = tree.tokenTag(p.arrow - 1);
    _ = try ag.addPl(.path, node, Inst.Path{
        .flags = .{
            .full = tree.tokenTag(p.arrow) == .asterisk_angle_bracket_right,
            .ifnone = tree.tokenTag(tree.nodeMainToken(node)) == .keyword_ifnone,
            .edge = switch (tree.tokenTag(first_in - 1)) {
                .keyword_posedge => .posedge,
                .keyword_negedge => .negedge,
                else => .none, // else: no edge identifier before the first input
            },
            .polarity = polarityOf(polarity),
            .data_polarity = if (p.data_source != .none) dataPolarity(tree, p.arrow) else .none,
        },
        .cond = try decl.exprBody(ag, scope, p.cond),
        .inputs = try decl.exprsOf(ag, scope, inputs),
        .outputs = try decl.exprsOf(ag, scope, tree.extraDataSlice(.{ .start = p.outputs_start, .end = p.outputs_end }, Node.OptionalIndex)),
        .data = try decl.exprBody(ag, scope, p.data_source),
        .delays = try decl.exprsOf(ag, scope, tree.extraDataSlice(.{ .start = p.delays_start, .end = p.delays_end }, Node.OptionalIndex)),
    });
}

fn polarityOf(tag: Token.Tag) @FieldType(@FieldType(Inst.Path, "flags"), "polarity") {
    return switch (tag) {
        .plus => .positive,
        .minus => .negative,
        else => .none, // else: no polarity operator
    };
}

/// The polarity before an edge-sensitive path's `:` (Syntax 14-4).
fn dataPolarity(tree: *const Ast, arrow: Ast.TokenIndex) @FieldType(@FieldType(Inst.Path, "flags"), "data_polarity") {
    var i = arrow + 2;
    var depth: u32 = 0;
    while (tree.tokenTag(i) != .eof) : (i += 1) switch (tree.tokenTag(i)) {
        .l_bracket, .l_paren => depth += 1,
        .r_bracket, .r_paren => depth -|= 1,
        .colon => if (depth == 0) return switch (tree.tokenTag(i - 1)) {
            .plus => .positive,
            .minus => .negative,
            else => .none, // else: no polarity operator before the `:`
        },
        else => {},
    };
    return .none;
}

/// A.7.5 `$check ( args )`; a controlled event is a `timing_event`.
fn timingCheck(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void {
    const tree = ag.tree;
    const slots = tree.extraDataSlice(tree.nodeData(node).extra_range, Node.OptionalIndex);
    const top = ag.scratch.items.len;
    const values = try ag.arena.alloc(Inst.Ref, slots.len);
    for (slots, values) |s, *v| {
        const n = s.unwrap() orelse {
            v.* = .none;
            continue;
        };
        v.* = if (tree.nodeTag(n) == .timing_event) try timingEvent(ag, scope, n) else try expr.lower(ag, scope, n);
    }
    const b = try ag.bodyFrom(top);
    const name = try ag.string(tree.tokenSlice(tree.nodeMainToken(node)));
    _ = try ag.addPl(.timing_check, node, Inst.TimingCheck{ .name = name, .args = .{ .body = b, .values = try ag.addList(Inst.Ref, values) } });
}

fn timingEvent(ag: *AstGen, scope: *Scope, node: Node.Index) Error!Inst.Ref {
    const tree = ag.tree;
    const kw = tree.nodeMainToken(node);
    const data = tree.nodeData(node).node_and_opt_node;
    var edges: Vir.String = .empty;
    if (tree.tokenTag(kw) == .keyword_edge and tree.tokenTag(kw + 1) == .l_bracket) {
        var buf: std.ArrayList(u8) = .empty;
        var i = kw + 2;
        while (tree.tokenTag(i) != .r_bracket and tree.tokenTag(i) != .eof) : (i += 1) try buf.appendSlice(ag.arena, tree.tokenSlice(i));
        edges = try ag.string(buf.items);
    }
    const term = try expr.lower(ag, scope, data[0]);
    const cond: Inst.Ref = if (data[1].unwrap()) |c| try expr.lower(ag, scope, c) else .none;
    return ag.addPl(.timing_event, node, Inst.TimingEvent{
        .flags = .{
            .edge = switch (tree.tokenTag(kw)) {
                .keyword_posedge => .posedge,
                .keyword_negedge => .negedge,
                .keyword_edge => .edge,
                else => .none, // else: a `&&&` condition with no edge
            },
        },
        .edges = edges,
        .term = term,
        .cond = cond,
    });
}
