//! Modules (§6.2) and their items to instructions: one `module_decl` in,
//! its `module` instruction and declaration-table row out, with the
//! per-file checks run over it (`check.module`). Owns the scope scan of a
//! module or generate block (`scanItems`), the item lowering (`lowerItems`)
//! and the generate constructs: schemes stay bodies, each arm is a
//! `gen_block` scope, and an unnamed block is named `genblk<n>`.
//! Cites: VAMS-2023 §6.2, §6.5, §6.6, §6.6.2, A.1.2-A.1.4, A.4.2; IEEE
//! 1364-2005 §4.10.1, §12.4.2, §12.4.3.
//!
//! Contents:
//! - `pub fn lowerModule(ag: *AstGen, node: Node.Index) Error!void`
//! - `pub fn scanItems(ag: *AstGen, scope: *Scope, items: []const Node.Index) Error!void`
//! - `pub fn lowerItems(ag: *AstGen, scope: *Scope, items: []const Node.Index) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("../Ast.zig");
const Vir = @import("../Vir.zig");
const AstGen = @import("../AstGen.zig");
const decl = @import("decl.zig");
const expr = @import("expr.zig");
const stmt = @import("stmt.zig");
const prim = @import("prim.zig");
const check = @import("check.zig");
const Inst = Vir.Inst;
const Node = Ast.Node;
const Scope = AstGen.Scope;
const Error = AstGen.Error;
const full = Ast.full;

/// §12.4.3: "leading zeroes are added until the name does not conflict",
/// given up after eight, as the old parser did.
const genblk_zeros_max = 8;

/// Lowers module `node`: its header parameters, ports and items in one
/// scope, then the per-file checks over it.
pub fn lowerModule(ag: *AstGen, node: Node.Index) Error!void {
    const tree = ag.tree;
    const m = full.moduleDecl(tree, node);
    const kind: Vir.Decl.Kind = switch (tree.tokenTag(m.main_token)) {
        .keyword_macromodule => .macromodule,
        .keyword_connectmodule => .connectmodule,
        else => .module, // else: `module_decl` opens with one of the three keywords
    };
    const name = try ag.identString(m.name);
    const inst = try ag.unit(kind, .module, node, name);
    const ansi = for (m.ports) |p| {
        if (tree.nodeTag(p) == .port_decl) break true;
    } else false;

    var scope: Scope = .{ .parent = null };
    for (m.params) |d| try decl.scan(ag, &scope, d);
    for (m.ports) |p| if (tree.nodeTag(p) == .port_decl) try decl.scan(ag, &scope, p);
    try scanItems(ag, &scope, m.items);

    const params_top = ag.scratch.items.len;
    for (m.params) |d| try decl.lower(ag, &scope, d);
    const params = try ag.bodyFrom(params_top);
    const ports_top = ag.scratch.items.len;
    for (m.ports) |p| switch (tree.nodeTag(p)) {
        .port_decl => try decl.lower(ag, &scope, p),
        else => try headerPort(ag, &scope, p), // else: `port` or `named_port`, A.1.3's other arms
    };
    const ports = try ag.bodyFrom(ports_top);
    // IEEE 1364-2005 §4.10.1: a body parameter of a module with a header is local.
    ag.header_params = m.params.len != 0;
    defer ag.header_params = false;
    const items_top = ag.scratch.items.len;
    try lowerItems(ag, &scope, m.items);
    const body = try ag.bodyFrom(items_top);
    const kind_flag: @FieldType(@FieldType(Inst.Module, "flags"), "kind") = switch (kind) {
        .macromodule => .macromodule,
        .connectmodule => .connectmodule,
        else => .module, // else: `kind` is one of the three module kinds above
    };
    try ag.setPayload(inst, node, Inst.Module{
        .name = name,
        .flags = .{ .kind = kind_flag, .ansi = ansi },
        .stamp = ag.stampAt(m.main_token),
        .params = params,
        .ports = ports,
        .body = body,
    });
    try check.module(ag, node);
}

/// Declares, in `scope`, every name `items` declare: declarations,
/// instances, functions, generate block names (§6.6.2: a generate block's
/// name belongs to the enclosing scope) and a specify block's specparams.
pub fn scanItems(ag: *AstGen, scope: *Scope, items: []const Node.Index) Error!void {
    const tree = ag.tree;
    for (items) |it| switch (tree.nodeTag(it)) {
        .param_decl, .port_decl, .net_decl, .var_decl, .genvar_decl, .event_decl, .aliasparam_decl, .branch_decl => try decl.scan(ag, scope, it),
        .module_instantiation => {
            const x = tree.extraData(tree.nodeData(it).extra, Node.Instantiation);
            for (tree.extraDataSlice(.{ .start = x.items_start, .end = x.items_end }, Node.Index)) |i| try decl.declareNode(ag, scope, .instance, i, tree.nodeMainToken(i));
        },
        .udp_instantiation, .gate_instantiation => for (full.decl(tree, it).items) |g| {
            const name = tree.nodeMainToken(g);
            try decl.declareNode(ag, scope, .instance, g, if (AstGen.isName(tree.tokenTag(name))) name else null);
        },
        .function_decl, .task_decl => try decl.declareNode(ag, scope, .function, it, stmt.functionName(tree, it)),
        .generate_region => try scanItems(ag, scope, full.list(tree, it)),
        .generate_for, .generate_if, .generate_case => try scanConstruct(ag, scope, it),
        // A specify block is no scope (IEEE 1364-2005 §4.10.3).
        .specify_block => for (full.list(tree, it)) |s| {
            if (tree.nodeTag(s) == .param_decl) try decl.scan(ag, scope, s);
        },
        else => {}, // else: assignments, processes and the rest declare nothing
    };
}

/// Lowers `items` into the current body, in order.
pub fn lowerItems(ag: *AstGen, scope: *Scope, items: []const Node.Index) Error!void {
    const tree = ag.tree;
    for (items) |it| switch (tree.nodeTag(it)) {
        .param_decl, .port_decl, .net_decl, .var_decl, .genvar_decl, .event_decl, .aliasparam_decl, .branch_decl => try decl.lower(ag, scope, it),
        .module_instantiation => try prim.moduleInstances(ag, scope, it),
        .udp_instantiation, .gate_instantiation => try prim.gateInstances(ag, scope, it),
        .continuous_assign, .defparam => try prim.assigns(ag, scope, it),
        .analog, .analog_initial, .initial, .always => try stmt.process(ag, scope, it),
        .function_decl, .task_decl => try stmt.function(ag, scope, it),
        .generate_region => try lowerItems(ag, scope, full.list(tree, it)),
        .generate_for, .generate_if, .generate_case => {
            scope.constructs += 1;
            try construct(ag, scope, it, scope.constructs);
        },
        .specify_block => try prim.specify(ag, scope, it),
        .null_stmt => {},
        else => unreachable, // else: the parser's module items are the tags above
    };
}

// ---- private ----

/// A.1.3 non-ANSI port: its external name (a simple reference's name or
/// `.name`) and its expression.
fn headerPort(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void {
    const tree = ag.tree;
    const value = tree.nodeData(node).opt_node;
    const name: Vir.String = if (tree.nodeTag(node) == .named_port) try ag.identString(tree.nodeMainToken(node) + 1) else if (value.unwrap()) |e| switch (tree.nodeTag(e)) {
        .identifier => try ag.identString(tree.nodeMainToken(e)),
        .index => try ag.identString(tree.nodeMainToken(tree.nodeData(e).node_and_node[0])),
        .range_select, .indexed_select_up, .indexed_select_down => try ag.identString(tree.nodeMainToken(tree.nodeData(e).node_and_extra[0])),
        else => .empty, // else: a concatenation has no name of its own
    } else .empty;
    _ = try ag.addPl(.port, node, Inst.Port{ .name = name, .value = try decl.exprBody(ag, scope, value) });
}

/// Declares the named generate blocks of a construct's arms in `scope`,
/// and reserves every arm's `gen_block`.
fn scanConstruct(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void {
    const tree = ag.tree;
    switch (tree.nodeTag(node)) {
        .generate_for => try scanArm(ag, scope, tree.extraData(tree.nodeData(node).extra, Node.For).body, true),
        .generate_if => {
            const x = tree.extraData(tree.nodeData(node).node_and_extra[1], Node.If);
            try scanArm(ag, scope, x.then, false);
            if (x.@"else".unwrap()) |e| try scanArm(ag, scope, e, false);
        },
        else => for (caseItems(tree, node)) |item| try scanArm(ag, scope, tree.nodeData(item).extra_and_node[1], false), // else: `generate_case`, the third construct
    }
}

fn scanArm(ag: *AstGen, scope: *Scope, arm: Node.Index, loop: bool) Error!void {
    const tree = ag.tree;
    switch (tree.nodeTag(arm)) {
        .null_stmt => {},
        // §6.6.2 direct nesting: an arm that is one conditional construct
        // is no scope; its blocks belong to this one.
        .generate_if, .generate_case => if (!loop) try scanConstruct(ag, scope, arm) else try reserveBlock(ag, scope, arm),
        else => try reserveBlock(ag, scope, arm), // else: a block or a single item, each a scope
    }
}

fn reserveBlock(ag: *AstGen, scope: *Scope, arm: Node.Index) Error!void {
    const tree = ag.tree;
    const inst = try ag.reserve(.gen_block, arm);
    try ag.block_insts.putNoClobber(ag.gpa, arm, inst);
    if (namedBlock(tree, arm)) |name| _ = try scope.declare(ag.arena, try ag.identString(name), inst);
}

/// The name token of a `begin : name` generate block, or null.
fn namedBlock(tree: *const Ast, arm: Node.Index) ?Ast.TokenIndex {
    if (tree.nodeTag(arm) != .generate_block) return null;
    const kw = tree.nodeMainToken(arm);
    return if (tree.tokenTag(kw + 1) == .colon) kw + 2 else null;
}

fn caseItems(tree: *const Ast, node: Node.Index) []const Node.Index {
    return tree.extraDataSlice(tree.extraData(tree.nodeData(node).node_and_extra[1], Node.SubRange), Node.Index);
}

/// A generate construct numbered `n` in its scope (§12.4.3), its scheme
/// kept as bodies.
fn construct(ag: *AstGen, scope: *Scope, node: Node.Index, n: u32) Error!void {
    const tree = ag.tree;
    switch (tree.nodeTag(node)) {
        .generate_for => {
            const f = tree.extraData(tree.nodeData(node).extra, Node.For);
            _ = try ag.addPl(.gen_for, node, Inst.GenFor{
                .init = try stmt.body(ag, scope, f.init),
                .cond = try decl.exprBody(ag, scope, f.cond.toOptional()),
                .step = try stmt.body(ag, scope, f.step),
                .body = try armBody(ag, scope, f.body, n, true),
            });
        },
        .generate_if => {
            const x = tree.extraData(tree.nodeData(node).node_and_extra[1], Node.If);
            const cond = try decl.exprBody(ag, scope, tree.nodeData(node).node_and_extra[0].toOptional());
            const then = try armBody(ag, scope, x.then, n, false);
            const els: Vir.Body = if (x.@"else".unwrap()) |e| try armBody(ag, scope, e, n, false) else .empty;
            _ = try ag.addPl(.gen_if, node, Inst.GenIf{ .cond = cond, .then = then, .@"else" = els });
        },
        else => { // else: `generate_case`, the third construct
            const operand = try decl.exprBody(ag, scope, tree.nodeData(node).node_and_extra[0].toOptional());
            const items = caseItems(tree, node);
            const arms = try ag.arena.alloc(Inst.Arm, items.len);
            for (items, arms) |item, *out| {
                const labels = tree.extraDataSlice(tree.extraData(tree.nodeData(item).extra_and_node[0], Node.SubRange), Node.OptionalIndex);
                const e = try decl.exprsOf(ag, scope, labels);
                out.* = .{ .flags = .{ .default = labels.len == 0 }, .labels = e.body, .values = e.values, .body = try armBody(ag, scope, tree.nodeData(item).extra_and_node[1], n, false) };
            }
            _ = try ag.addPl(.gen_case, node, Inst.GenCase{ .operand = operand, .arms = try ag.addList(Inst.Arm, arms) });
        },
    }
}

/// An arm's body: empty, a directly nested construct (same number, same
/// scope), or one `gen_block`.
fn armBody(ag: *AstGen, scope: *Scope, arm: Node.Index, n: u32, loop: bool) Error!Vir.Body {
    const tree = ag.tree;
    const top = ag.scratch.items.len;
    switch (tree.nodeTag(arm)) {
        .null_stmt => {},
        .generate_if, .generate_case => if (!loop) try construct(ag, scope, arm, n) else try genBlock(ag, scope, arm, n),
        else => try genBlock(ag, scope, arm, n), // else: a block or a single item
    }
    return ag.bodyFrom(top);
}

/// One generate scope: named as written, or `genblk<n>` with zeros added
/// until it names nothing else in `scope`, every arm of construct `n` the
/// same name (§12.4.3: "if such a name conflicts with an explicitly
/// declared name").
fn genBlock(ag: *AstGen, scope: *Scope, arm: Node.Index, n: u32) Error!void {
    const tree = ag.tree;
    const inst = ag.block_insts.get(arm).?;
    const named = namedBlock(tree, arm);
    const name = if (named) |t| try ag.identString(t) else auto: {
        if (scope.auto) |a| if (a.n == n) break :auto a.name;
        var zeros: usize = 0;
        while (true) : (zeros += 1) {
            const text = try ag.arena.print("genblk{s}{d}", .{ ("00000000")[0..zeros], n });
            const s = try ag.string(text);
            if (zeros == genblk_zeros_max or !scope.names.contains(s)) {
                _ = try scope.declare(ag.arena, s, inst);
                scope.auto = .{ .n = n, .name = s };
                break :auto s;
            }
        }
    };
    var inner: Scope = .{ .parent = scope };
    const items: []const Node.Index = if (tree.nodeTag(arm) == .generate_block) full.list(tree, arm) else (&arm)[0..1];
    try scanItems(ag, &inner, items);
    const top = ag.scratch.items.len;
    try lowerItems(ag, &inner, items);
    const body = try ag.bodyFrom(top);
    try ag.fill(inst, arm, Inst.GenBlock{ .name = name, .prev = decl.prevOf(scope, name, inst), .flags = .{ .named = named != null }, .body = body });
}
