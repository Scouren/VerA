//! Statements (A.6), processes and subroutines to instructions: one
//! statement node in, its instructions appended to the current body; a
//! process or function node in, its `analog`/`initial`/`always`/`function`
//! instruction out. Control flow keeps its structure (`condbr`, `case`,
//! `loop` with its condition and step as bodies re-evaluated per pass).
//! A named block and a function open a scope, scanned before lowering.
//! Cites: VAMS-2023 §4.7, §5.2-§5.10, A.2.6, A.6.1-A.6.8; IEEE 1364-2005
//! §9, §10.
//!
//! Contents:
//! - `pub fn lower(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void`
//! - `pub fn body(ag: *AstGen, scope: *Scope, node: Node.Index) Error!Vir.Body`
//! - `pub fn process(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void`
//! - `pub fn function(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void`
//! - `pub fn functionName(tree: *const Ast, node: Node.Index) Ast.TokenIndex`
//! - `pub fn caseArms(ag: *AstGen, scope: *Scope, items: []const Node.Index, comptime arm: fn (*AstGen, *Scope, Node.Index) Error!Vir.Body) Error!Vir.List(Inst.Arm)`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("../Ast.zig");
const Vir = @import("../Vir.zig");
const AstGen = @import("../AstGen.zig");
const expr = @import("expr.zig");
const decl = @import("decl.zig");
const Inst = Vir.Inst;
const Node = Ast.Node;
const Scope = AstGen.Scope;
const Error = AstGen.Error;
const full = Ast.full;

/// Lowers statement `node` into the current body.
pub fn lower(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void {
    const tree = ag.tree;
    const data = tree.nodeData(node);
    switch (tree.nodeTag(node)) {
        .block => try block(ag, scope, node),
        .if_stmt => {
            const cond = try expr.lower(ag, scope, data.node_and_extra[0]);
            const x = tree.extraData(data.node_and_extra[1], Node.If);
            _ = try ag.addPl(.condbr, node, Inst.CondBr{ .cond = cond, .then = try body(ag, scope, x.then), .@"else" = try optBody(ag, scope, x.@"else") });
        },
        .case_stmt => {
            const operand = try expr.lower(ag, scope, data.node_and_extra[0]);
            const items = tree.extraDataSlice(tree.extraData(data.node_and_extra[1], Node.SubRange), Node.Index);
            const kind: @FieldType(@FieldType(Inst.Case, "flags"), "kind") = switch (tree.tokenTag(tree.nodeMainToken(node))) {
                .keyword_casex => .casex,
                .keyword_casez => .casez,
                else => .case, // else: `case_stmt` opens with one of the three keywords
            };
            _ = try ag.addPl(.case, node, Inst.Case{ .flags = .{ .kind = kind }, .operand = operand, .arms = try caseArms(ag, scope, items, body) });
        },
        .for_stmt => {
            const f = tree.extraData(data.extra, Node.For);
            try lower(ag, scope, f.init);
            _ = try ag.addPl(.loop, node, Inst.Loop{ .cond = try decl.exprBody(ag, scope, f.cond.toOptional()), .step = try body(ag, scope, f.step), .body = try body(ag, scope, f.body) });
        },
        .while_stmt => _ = try ag.addPl(.loop, node, Inst.Loop{ .cond = try decl.exprBody(ag, scope, data.node_and_node[0].toOptional()), .step = .empty, .body = try body(ag, scope, data.node_and_node[1]) }),
        .forever_stmt => _ = try ag.addPl(.loop, node, Inst.Loop{ .cond = .empty, .step = .empty, .body = try body(ag, scope, data.node) }),
        .repeat_stmt => {
            const count = try expr.lower(ag, scope, data.node_and_node[0]);
            _ = try ag.addPl(.repeat, node, Inst.Repeat{ .count = count, .body = try body(ag, scope, data.node_and_node[1]) });
        },
        .wait_stmt => _ = try ag.addPl(.wait, node, Inst.Wait{ .cond = try decl.exprBody(ag, scope, data.node_and_node[0].toOptional()), .body = try body(ag, scope, data.node_and_node[1]) }),
        .delay_stmt => {
            const value = try expr.lower(ag, scope, data.node_and_node[0]);
            _ = try ag.addPl(.delay, node, Inst.Delay{ .value = value, .body = try body(ag, scope, data.node_and_node[1]) });
        },
        .event_stmt => {
            const event: Inst.Ref = if (data.opt_node_and_node[0].unwrap()) |e| try expr.lower(ag, scope, e) else .none;
            _ = try ag.addPl(.event_wait, node, Inst.EventWait{ .event = event, .body = try body(ag, scope, data.opt_node_and_node[1]) });
        },
        .assign, .nonblocking_assign, .contribution => {
            const lhs = try expr.lower(ag, scope, data.node_and_node[0]);
            const rhs = try expr.lower(ag, scope, data.node_and_node[1]);
            const tag: Inst.Tag = switch (tree.nodeTag(node)) {
                .assign => .store,
                .nonblocking_assign => .store_nb,
                else => .contrib, // else: the arm names three tags
            };
            _ = try ag.addPl(tag, node, Inst.Bin{ .lhs = lhs, .rhs = rhs });
        },
        .assign_timed, .nonblocking_assign_timed => {
            const t = tree.extraData(data.node_and_extra[1], Node.Timed);
            const lhs = try expr.lower(ag, scope, data.node_and_extra[0]);
            const timing = try timingControl(ag, scope, t.timing);
            const rhs = try expr.lower(ag, scope, t.rhs);
            _ = try ag.addPl(if (tree.nodeTag(node) == .assign_timed) .store_timed else .store_nb_timed, node, Inst.Timed{ .lhs = lhs, .rhs = rhs, .timing = timing });
        },
        .indirect_contribution => {
            const x = tree.extraData(data.node_and_extra[1], Node.Indirect);
            const lhs = try expr.lower(ag, scope, data.node_and_extra[0]);
            const probe = try expr.lower(ag, scope, x.probe);
            const eqn = try expr.lower(ag, scope, x.eqn);
            _ = try ag.addPl(.contrib_indirect, node, Inst.Triple{ .a = lhs, .b = probe, .c = eqn });
        },
        .procedural_continuous => {
            const lhs = try expr.lower(ag, scope, data.node_and_opt_node[0]);
            switch (tree.tokenTag(tree.nodeMainToken(node))) {
                .keyword_assign, .keyword_force => |kw| {
                    const rhs = try expr.lower(ag, scope, data.node_and_opt_node[1].unwrap().?);
                    _ = try ag.addPl(if (kw == .keyword_assign) .proc_assign else .force, node, Inst.Bin{ .lhs = lhs, .rhs = rhs });
                },
                .keyword_deassign => _ = try un(ag, .deassign, node, lhs),
                else => _ = try un(ag, .release, node, lhs), // else: the fourth keyword, `release`
            }
        },
        .task_enable => try taskEnable(ag, scope, data.node),
        .event_trigger => _ = try un(ag, .trigger, node, try expr.lower(ag, scope, data.node)),
        .disable => _ = try un(ag, .disable, node, try expr.lower(ag, scope, data.node)),
        .return_stmt => _ = try un(ag, .ret, node, if (data.opt_node.unwrap()) |v| try expr.lower(ag, scope, v) else .none),
        .break_stmt => _ = try un(ag, .brk, node, .none),
        .continue_stmt => _ = try un(ag, .cont, node, .none),
        .null_stmt => {},
        // A.6.3 block declarations, scanned by the enclosing `block`.
        .param_decl, .var_decl, .event_decl => try decl.lower(ag, scope, node),
        else => unreachable, // else: every other tag is an item or an expression, never a statement
    }
}

/// A body holding statement `node`.
pub fn body(ag: *AstGen, scope: *Scope, node: Node.Index) Error!Vir.Body {
    const top = ag.scratch.items.len;
    try lower(ag, scope, node);
    return ag.bodyFrom(top);
}

/// `analog`, `analog initial`, `initial` or `always`.
pub fn process(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void {
    const tree = ag.tree;
    const tag: Inst.Tag = switch (tree.nodeTag(node)) {
        .analog => .analog,
        .analog_initial => .analog_initial,
        .initial => .initial,
        else => .always, // else: the caller passes these four tags
    };
    const analog = ag.analog;
    ag.analog = tag == .analog or tag == .analog_initial;
    defer ag.analog = analog;
    const b = try body(ag, scope, tree.nodeData(node).node);
    _ = try ag.addPl(tag, node, Inst.Process{ .body = b });
}

/// A function or task, its formals and locals in their own scope; fills
/// the instruction the enclosing scope's scan reserved.
pub fn function(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void {
    const tree = ag.tree;
    const f = full.function(tree, node);
    const inst = ag.reserved(node);
    const name_tok = functionName(tree, node);
    var inner: Scope = .{ .parent = scope };
    for (f.ports) |p| try scanFormal(ag, &inner, p);
    for (f.items) |it| switch (tree.nodeTag(it)) {
        .port_decl, .param_decl, .var_decl, .event_decl => try decl.scan(ag, &inner, it),
        else => {}, // else: a statement declares nothing
    };
    const analog_fn = tree.tokenTag(f.main_token) == .keyword_analog;
    const words = decl.typeWords(tree, f.main_token + @intFromBool(analog_fn) + 1);
    const formals_top = ag.scratch.items.len;
    for (f.ports) |p| try lowerFormal(ag, &inner, p);
    for (f.items) |it| if (tree.nodeTag(it) == .port_decl) try decl.lower(ag, &inner, it);
    const formals = try ag.bodyFrom(formals_top);
    const range = try decl.exprBody(ag, scope, f.range);
    const analog = ag.analog;
    ag.analog = analog_fn;
    defer ag.analog = analog;
    const top = ag.scratch.items.len;
    for (f.items) |it| if (tree.nodeTag(it) != .port_decl) try lower(ag, &inner, it);
    const b = try ag.bodyFrom(top);
    const name = try ag.identString(name_tok);
    try ag.fill(inst, node, Inst.Function{
        .name = name,
        .prev = decl.prevOf(scope, name, inst),
        .flags = .{ .analog = analog_fn, .task = tree.nodeTag(node) == .task_decl, .automatic = tree.tokenTag(f.main_token + 1) == .keyword_automatic, .storage = words.storage, .signed = words.signed },
        .range = range,
        .formals = formals,
        .body = b,
    });
}

/// The name token of a function or task: past `analog`, the keyword,
/// `automatic`, the type words and a range.
pub fn functionName(tree: *const Ast, node: Node.Index) Ast.TokenIndex {
    var i = tree.nodeMainToken(node);
    if (tree.tokenTag(i) == .keyword_analog) i += 1;
    i += 1;
    while (true) : (i += 1) switch (tree.tokenTag(i)) {
        .keyword_automatic, .keyword_integer, .keyword_real, .keyword_string, .keyword_time, .keyword_realtime, .keyword_reg, .keyword_signed => {},
        .l_bracket => while (tree.tokenTag(i) != .r_bracket) {
            i += 1;
        },
        else => return i, // else: the first token that is no type word is the name
    };
}

/// Case arms; each arm's body lowered by `arm`.
pub fn caseArms(ag: *AstGen, scope: *Scope, items: []const Node.Index, comptime arm: fn (*AstGen, *Scope, Node.Index) Error!Vir.Body) Error!Vir.List(Inst.Arm) {
    const tree = ag.tree;
    const arms = try ag.arena.alloc(Inst.Arm, items.len);
    for (items, arms) |item, *out| {
        const labels = tree.extraDataSlice(tree.extraData(tree.nodeData(item).extra_and_node[0], Node.SubRange), Node.OptionalIndex);
        const e = try decl.exprsOf(ag, scope, labels);
        out.* = .{ .flags = .{ .default = labels.len == 0 }, .labels = e.body, .values = e.values, .body = try arm(ag, scope, tree.nodeData(item).extra_and_node[1]) };
    }
    return ag.addList(Inst.Arm, arms);
}

// ---- private ----

fn optBody(ag: *AstGen, scope: *Scope, node: Node.OptionalIndex) Error!Vir.Body {
    return if (node.unwrap()) |n| body(ag, scope, n) else .empty;
}

fn un(ag: *AstGen, tag: Inst.Tag, node: Node.Index, operand: Inst.Ref) Error!Inst.Ref {
    return ag.addInst(tag, .{ .un_node = .{ .src_node = node, .operand = operand } });
}

/// A.6.3 `begin|fork [: name] decls stmts end|join`; a named block's
/// declarations live in its own scope.
fn block(ag: *AstGen, scope: *Scope, node: Node.Index) Error!void {
    const tree = ag.tree;
    const kw = tree.nodeMainToken(node);
    const named = tree.tokenTag(kw + 1) == .colon;
    const items = full.list(tree, node);
    var inner: Scope = .{ .parent = scope };
    for (items) |it| switch (tree.nodeTag(it)) {
        .param_decl, .var_decl, .event_decl => try decl.scan(ag, &inner, it),
        else => {}, // else: a statement declares nothing
    };
    const top = ag.scratch.items.len;
    for (items) |it| try lower(ag, &inner, it);
    const b = try ag.bodyFrom(top);
    _ = try ag.addPl(.block, node, Inst.Block{ .name = if (named) try ag.identString(kw + 2) else .empty, .flags = .{ .fork = tree.tokenTag(kw) == .keyword_fork }, .body = b });
}

/// A task or system task enable: the name or call, called.
fn taskEnable(ag: *AstGen, scope: *Scope, target: Node.Index) Error!void {
    const tree = ag.tree;
    switch (tree.nodeTag(target)) {
        .call => _ = try expr.lower(ag, scope, target),
        .identifier => if (tree.tokenTag(tree.nodeMainToken(target)) == .system_identifier) {
            _ = try expr.lower(ag, scope, target);
        } else {
            const callee = try expr.lower(ag, scope, target);
            _ = try ag.addPl(.call, target, Inst.Call{ .callee = callee, .args = .empty });
        },
        else => { // else: a hierarchical task name, `a.b.t;`
            const callee = try expr.lower(ag, scope, target);
            _ = try ag.addPl(.call, target, Inst.Call{ .callee = callee, .args = .empty });
        },
    }
}

/// Intra-assignment timing: `# value`, `@ event` (none: `@*`), `repeat (n) @ event`.
fn timingControl(ag: *AstGen, scope: *Scope, node: Node.Index) Error!Inst.Ref {
    const tree = ag.tree;
    const data = tree.nodeData(node);
    return switch (tree.nodeTag(node)) {
        .delay_control => un(ag, .delay_ctl, node, try expr.lower(ag, scope, data.node)),
        .event_control => un(ag, .event_ctl, node, if (data.opt_node.unwrap()) |e| try expr.lower(ag, scope, e) else .none),
        else => repeat: { // else: `repeat_control`, the third timing form
            const count = try expr.lower(ag, scope, data.node_and_opt_node[0]);
            const event: Inst.Ref = if (data.node_and_opt_node[1].unwrap()) |e| try expr.lower(ag, scope, e) else .none;
            break :repeat ag.addPl(.repeat_ctl, node, Inst.Bin{ .lhs = count, .rhs = event });
        },
    };
}

/// Declares a header formal: a `port_decl` group or a bare name.
fn scanFormal(ag: *AstGen, scope: *Scope, p: Node.Index) Error!void {
    if (ag.tree.nodeTag(p) == .port_decl) return decl.scan(ag, scope, p);
    try decl.declareNode(ag, scope, .io, p, ag.tree.nodeMainToken(p));
}

fn lowerFormal(ag: *AstGen, scope: *Scope, p: Node.Index) Error!void {
    const tree = ag.tree;
    if (tree.nodeTag(p) == .port_decl) return decl.lower(ag, scope, p);
    const inst = ag.reserved(p);
    const name = try ag.identString(tree.nodeMainToken(p));
    try ag.fill(inst, p, Inst.Io{
        .name = name,
        .prev = decl.prevOf(scope, name, inst),
        .flags = .{ .dir = .none, .net = .none, .storage = .none, .signed = false, .header = true },
        .discipline = .empty,
        .range = .empty,
        .dims = .empty,
        .init = .empty,
        .defaults = .empty,
    });
}
