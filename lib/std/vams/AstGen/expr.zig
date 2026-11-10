//! Expressions (A.8) to instructions: one expression node in, its
//! instructions appended to the current body and the result's `Ref` out.
//! A name resolves through the scope chain to a `decl_ref`, or stays a
//! `str_ref`; literals are decoded (§2.6, §2.7). Two per-file rules live
//! here, because only the lowering knows the context and the binding:
//! E0295 (A.8.4: no `( mintypmax )` in an analog expression) and E0373
//! (§3.4.7: a value reads an aliasparam's original, not the alias).
//! Cites: VAMS-2023 §2.6.1, §2.6.2, §2.7, §3.4.6, §3.4.7, §4.2, §9.18,
//! A.8.1-A.8.5; IEEE 1364-2005 §5.
//!
//! Contents:
//! - `pub fn lower(ag: *AstGen, scope: *Scope, node: Node.Index) Error!Inst.Ref`
//! - `pub fn lowerName(ag: *AstGen, scope: *Scope, tok: Ast.TokenIndex) Error!Inst.Ref`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("../Ast.zig");
const Vir = @import("../Vir.zig");
const AstGen = @import("../AstGen.zig");
const number_literal = @import("../number_literal.zig");
const Token = @import("../tokenizer.zig").Token;
const Inst = Vir.Inst;
const Node = Ast.Node;
const Scope = AstGen.Scope;
const Error = AstGen.Error;
const full = Ast.full;

/// §9.18 Table 9-29's hierarchical system parameters, originals in their
/// own right for §3.4.7.
const system_params = std.StaticStringMap(void).initComptime(.{ .{"$mfactor"}, .{"$xposition"}, .{"$yposition"}, .{"$angle"}, .{"$hflip"}, .{"$vflip"} });

/// The longest chain of aliasparams `checkAlias` follows.
const max_alias_chain = 64;

/// Lowers expression `node` into the current body and returns its value.
/// Recursion follows the tree's nesting except along a left-leaning
/// binary chain (`a + b + ...`), which is lowered by a loop.
pub fn lower(ag: *AstGen, scope: *Scope, node: Node.Index) Error!Inst.Ref {
    const tree = ag.tree;
    const data = tree.nodeData(node);
    return switch (tree.nodeTag(node)) {
        .identifier => lowerIdent(ag, scope, node),
        .number_literal => number(ag, node),
        .string_literal => stringLit(ag, tree.nodeMainToken(node)),
        .grouped => lower(ag, scope, data.node_and_token[0]),
        .mintypmax => {
            if (ag.analog) try ag.report(.E0295, tree.nodeMainToken(node), "", .{});
            const m = tree.extraData(data.node_and_extra[1], Node.MinTypMax);
            return triple(ag, .mintypmax, node, try lower(ag, scope, data.node_and_extra[0]), try lower(ag, scope, m.typ), try lower(ag, scope, m.max));
        },
        .unary => {
            const operand = try lower(ag, scope, data.node);
            return ag.addInst(unaryTag(tree.tokenTag(tree.nodeMainToken(node))), .{ .un_node = .{ .src_node = node, .operand = operand } });
        },
        .binary => binaryChain(ag, scope, node),
        .ternary => {
            const t = tree.extraData(data.node_and_extra[1], Node.Ternary);
            return triple(ag, .ternary, node, try lower(ag, scope, data.node_and_extra[0]), try lower(ag, scope, t.then), try lower(ag, scope, t.@"else"));
        },
        .field_access => {
            const base = data.node_and_token[0];
            // `$root.top.x`: the head names no declaration.
            const operand = if (tree.nodeTag(base) == .identifier and tree.tokenTag(tree.nodeMainToken(base)) == .system_identifier)
                try strRef(ag, tree.nodeMainToken(base))
            else
                try lower(ag, scope, base);
            return ag.addPl(.field, node, Inst.Field{ .operand = operand, .name = try ag.identString(data.node_and_token[1]) });
        },
        .index => bin(ag, .elem, node, try lower(ag, scope, data.node_and_node[0]), try lower(ag, scope, data.node_and_node[1])),
        .range => bin(ag, .range, node, try lower(ag, scope, data.node_and_node[0]), try lower(ag, scope, data.node_and_node[1])),
        .range_select, .indexed_select_up, .indexed_select_down => {
            const pair = tree.extraData(data.node_and_extra[1], Node.Pair);
            const tag: Inst.Tag = switch (tree.nodeTag(node)) {
                .range_select => .slice,
                .indexed_select_up => .slice_up,
                else => .slice_down, // else: the arm names three tags
            };
            return triple(ag, tag, node, try lower(ag, scope, data.node_and_extra[0]), try lower(ag, scope, pair.a), try lower(ag, scope, pair.b));
        },
        .call => call(ag, scope, node),
        .port_branch => un(ag, .port_branch, node, try lower(ag, scope, data.node)),
        .concat => list(ag, scope, .concat, node, @ptrCast(full.list(tree, node))),
        .assign_pattern => list(ag, scope, .pattern, node, tree.extraDataSlice(data.extra_range, Node.OptionalIndex)),
        .multi_concat => bin(ag, .replicate, node, try lower(ag, scope, data.node_and_node[0]), try lower(ag, scope, data.node_and_node[1])),
        .pattern_repl => bin(ag, .pattern_repl, node, try lower(ag, scope, data.node_and_node[0]), try lower(ag, scope, data.node_and_node[1])),
        .event_or => bin(ag, .event_or, node, try lower(ag, scope, data.node_and_node[0]), try lower(ag, scope, data.node_and_node[1])),
        .edge_event => un(ag, switch (tree.tokenTag(tree.nodeMainToken(node))) {
            .keyword_posedge => .posedge,
            .keyword_negedge => .negedge,
            else => .driver_update, // else: the parser makes an edge event of these three keywords
        }, node, try lower(ag, scope, data.node)),
        .step_event => stepEvent(ag, node),
        .paramset_output => ag.addInst(.paramset_output, .{ .str_tok = .{ .start = try ag.identString(data.token), .src_tok = data.token } }),
        .pulse_limits => bin(ag, .pulse_limits, node, try lower(ag, scope, data.node_and_opt_node[0]), if (data.node_and_opt_node[1].unwrap()) |e| try lower(ag, scope, e) else .none),
        else => unreachable, // else: every other tag is a declaration, item or statement, never an operand
    };
}

/// Resolves the name token `tok` through `scope`: a `decl_ref`, or a
/// `str_ref` Sema resolves. Reports E0373 for a read of an aliasparam.
pub fn lowerName(ag: *AstGen, scope: *Scope, tok: Ast.TokenIndex) Error!Inst.Ref {
    const name = try ag.identString(tok);
    const decl = scope.lookup(name) orelse return strRef(ag, tok);
    if (ag.instructions.items(.tag)[@backingInt(decl)] == .aliasparam) try checkAlias(ag, scope, decl, tok);
    return ag.addInst(.decl_ref, .{ .decl_tok = .{ .decl = decl, .src_tok = tok } });
}

// ---- private ----

fn lowerIdent(ag: *AstGen, scope: *Scope, node: Node.Index) Error!Inst.Ref {
    const tree = ag.tree;
    const tok = tree.nodeMainToken(node);
    return switch (tree.tokenTag(tok)) {
        // A.8.2 `system_function_call` with no argument list.
        .system_identifier => ag.addPl(.call_sys, node, Inst.SysCall{ .name = try ag.string(tree.tokenSlice(tok)), .args = .empty }),
        .keyword_inf => ag.addInst(.real, .{ .float = std.math.inf(f64) }),
        else => lowerName(ag, scope, tok), // else: a name, or a keyword the set frees or a file may declare (`expm1`)
    };
}

/// §3.4.7: "an aliasparam ... shall not be used in an expression": E0373
/// when the alias reaches an original (a parameter or a §9.18 system
/// parameter), following a chain of aliases.
fn checkAlias(ag: *AstGen, scope: *const Scope, alias: Inst.Index, tok: Ast.TokenIndex) Error!void {
    const tree = ag.tree;
    var decl = alias;
    // A chain of aliases visits each once; a cycle has no original.
    for (0..max_alias_chain) |_| {
        const node = ag.instructions.items(.data)[@backingInt(decl)].pl_node.src_node;
        assert(tree.nodeTag(node) == .aliasparam_decl);
        const target_tok = tree.nodeMainToken(node) + 3;
        const target = AstGen.identText(tree, target_tok);
        if (system_params.has(target)) return reportAlias(ag, tok, target);
        const next = scope.lookup(try ag.string(target)) orelse return;
        switch (ag.instructions.items(.tag)[@backingInt(next)]) {
            .param => return reportAlias(ag, tok, target),
            .aliasparam => decl = next,
            else => return, // else: an alias of a non-parameter is lowering's E0303/E0331
        }
    }
}

fn reportAlias(ag: *AstGen, tok: Ast.TokenIndex, original: []const u8) Error!void {
    try ag.report(.E0373, tok, "`{s}` is an alias; reference the original parameter `{s}`", .{ AstGen.identText(ag.tree, tok), original });
}

fn strRef(ag: *AstGen, tok: Ast.TokenIndex) Error!Inst.Ref {
    const text = if (ag.tree.tokenTag(tok) == .system_identifier) ag.tree.tokenSlice(tok) else AstGen.identText(ag.tree, tok);
    return ag.addInst(.str_ref, .{ .str_tok = .{ .start = try ag.string(text), .src_tok = tok } });
}

/// §2.6.1 integers (`int` when unsized decimal and under 2^64, else
/// `big_int`) and §2.6.2 reals.
fn number(ag: *AstGen, node: Node.Index) Error!Inst.Ref {
    const text = ag.tree.tokenSlice(ag.tree.nodeMainToken(node));
    switch (number_literal.parseNumberLiteral(text)) {
        .int => |int| {
            if (int.size == 0 and int.radix == 10 and std.mem.findScalar(u8, text, '\'') == null) {
                if (number_literal.intValue(int)) |v| return ag.addInst(.int, .{ .int = v });
            }
            var digits: std.ArrayList(u8) = .empty;
            for (int.digits) |c| switch (c) {
                '_', ' ', '\t', '\r', '\n', 0x0c => {},
                else => try digits.append(ag.arena, std.ascii.toLower(c)),
            };
            return ag.addPl(.big_int, node, Inst.BigInt{ .size = int.size, .flags = .{ .signed = int.signed, .radix = int.radix }, .digits = try ag.string(digits.items) });
        },
        .real => {
            const buf = try ag.arena.alloc(u8, text.len + 4);
            return ag.addInst(.real, .{ .float = number_literal.parseReal(buf, text) catch unreachable });
        },
        // The parser refused it, and a tree with errors is never generated.
        .failure => unreachable,
    }
}

/// §2.7 string literal, escapes decoded; one with a NUL is not interned.
fn stringLit(ag: *AstGen, tok: Ast.TokenIndex) Error!Inst.Ref {
    const bytes = try number_literal.stringContents(ag.arena, ag.tree.tokenSlice(tok));
    if (std.mem.findScalar(u8, bytes, 0) == null) {
        return ag.addInst(.str, .{ .str = .{ .start = try ag.string(bytes), .len = @intCast(bytes.len) } });
    }
    const at: u32 = @intCast(ag.string_bytes.items.len);
    try ag.string_bytes.appendSlice(ag.gpa, bytes);
    try ag.string_bytes.append(ag.gpa, 0);
    return ag.addInst(.str, .{ .str = .{ .start = @fromBackingInt(at), .len = @intCast(bytes.len) } });
}

/// A left-leaning chain of `binary` nodes, lowered leftmost operand first
/// without recursing down the chain.
fn binaryChain(ag: *AstGen, scope: *Scope, node: Node.Index) Error!Inst.Ref {
    const tree = ag.tree;
    var spine: std.ArrayList(Node.Index) = .empty;
    var n = node;
    while (tree.nodeTag(n) == .binary) : (n = tree.nodeData(n).node_and_node[0]) try spine.append(ag.arena, n);
    var acc = try lower(ag, scope, n);
    var k = spine.items.len;
    while (k > 0) {
        k -= 1;
        const b = spine.items[k];
        const rhs = try lower(ag, scope, tree.nodeData(b).node_and_node[1]);
        acc = try bin(ag, binaryTag(tree.tokenTag(tree.nodeMainToken(b))), b, acc, rhs);
    }
    return acc;
}

/// A call: a `$` name or A.8.2 built-in is `call_sys`; any other callee
/// is resolved and `call`ed.
fn call(ag: *AstGen, scope: *Scope, node: Node.Index) Error!Inst.Ref {
    const tree = ag.tree;
    const callee = tree.nodeData(node).node_and_extra[0];
    const slots = tree.extraDataSlice(tree.extraData(tree.nodeData(node).node_and_extra[1], Node.SubRange), Node.OptionalIndex);
    const sys_name: ?[]const u8 = if (tree.nodeTag(callee) == .identifier) name: {
        const tok = tree.nodeMainToken(callee);
        break :name switch (tree.tokenTag(tok)) {
            .system_identifier => tree.tokenSlice(tok),
            // A built-in, unless the file declares a function of its name (`expm1`, annex G.7).
            .keyword_builtin, .keyword_potential, .keyword_flow, .keyword_analysis => if (scope.lookup(try ag.identString(tok)) == null) tree.tokenSlice(tok) else null,
            else => null, // else: a user function or an access function, resolved below
        };
    } else null;
    if (sys_name) |name| {
        const args = try argRefs(ag, scope, slots);
        const r = try ag.addPl(.call_sys, node, Inst.SysCall{ .name = try ag.string(name), .args = args });
        // §10.3 the `default_transition` in force at this call.
        if (std.mem.eql(u8, name, "transition")) if (ag.transitionAt(tree.tokenStart(tree.nodeMainToken(node)))) |v|
            try ag.transitions.append(ag.arena, .{ .inst = r.toIndex().?, .value = .init(v) });
        return r;
    }
    const f = try lower(ag, scope, callee);
    const args = try argRefs(ag, scope, slots);
    return ag.addPl(.call, node, Inst.Call{ .callee = f, .args = args });
}

fn argRefs(ag: *AstGen, scope: *Scope, slots: []const Node.OptionalIndex) Error!Vir.List(Inst.Ref) {
    const refs = try ag.arena.alloc(Inst.Ref, slots.len);
    for (slots, refs) |s, *r| r.* = if (s.unwrap()) |a| try lower(ag, scope, a) else .none;
    return ag.addList(Inst.Ref, refs);
}

fn list(ag: *AstGen, scope: *Scope, tag: Inst.Tag, node: Node.Index, slots: []const Node.OptionalIndex) Error!Inst.Ref {
    return ag.addPl(tag, node, @as(Inst.Refs, try argRefs(ag, scope, slots)));
}

/// `initial_step|final_step [( "a", ... )]`.
fn stepEvent(ag: *AstGen, node: Node.Index) Error!Inst.Ref {
    const tree = ag.tree;
    const kw = tree.nodeMainToken(node);
    var names: std.ArrayList(Vir.String) = .empty;
    if (tree.tokenTag(kw + 1) == .l_paren) {
        var i = kw + 2;
        while (tree.tokenTag(i) == .string_literal) : (i += 2) {
            try names.append(ag.arena, try ag.string(try number_literal.stringContents(ag.arena, tree.tokenSlice(i))));
            if (tree.tokenTag(i + 1) != .comma) break;
        }
    }
    return ag.addPl(.step_event, node, Inst.StepEvent{ .flags = .{ .final = tree.tokenTag(kw) == .keyword_final_step }, .analyses = try ag.addList(Vir.String, names.items) });
}

fn un(ag: *AstGen, tag: Inst.Tag, node: Node.Index, operand: Inst.Ref) Error!Inst.Ref {
    return ag.addInst(tag, .{ .un_node = .{ .src_node = node, .operand = operand } });
}

fn bin(ag: *AstGen, tag: Inst.Tag, node: Node.Index, lhs: Inst.Ref, rhs: Inst.Ref) Error!Inst.Ref {
    return ag.addPl(tag, node, Inst.Bin{ .lhs = lhs, .rhs = rhs });
}

fn triple(ag: *AstGen, tag: Inst.Tag, node: Node.Index, a: Inst.Ref, b: Inst.Ref, c: Inst.Ref) Error!Inst.Ref {
    return ag.addPl(tag, node, Inst.Triple{ .a = a, .b = b, .c = c });
}

fn unaryTag(op: Token.Tag) Inst.Tag {
    return switch (op) {
        .plus => .pos,
        .minus => .neg,
        .bang => .not,
        .tilde => .bit_not,
        .ampersand => .red_and,
        .tilde_ampersand => .red_nand,
        .pipe => .red_or,
        .tilde_pipe => .red_nor,
        .caret => .red_xor,
        .tilde_caret, .caret_tilde => .red_xnor,
        else => unreachable, // else: `Parse.parseUnary` makes these eleven only
    };
}

fn binaryTag(op: Token.Tag) Inst.Tag {
    return switch (op) {
        .plus => .add,
        .minus => .sub,
        .asterisk => .mul,
        .slash => .div,
        .percent => .mod,
        .asterisk_asterisk => .pow,
        .angle_bracket_angle_bracket_left => .shl,
        .angle_bracket_angle_bracket_right => .shr,
        .angle_bracket_angle_bracket_angle_bracket_left => .ashl,
        .angle_bracket_angle_bracket_angle_bracket_right => .ashr,
        .angle_bracket_left => .lt,
        .angle_bracket_right => .gt,
        .angle_bracket_left_equal => .lte,
        .angle_bracket_right_equal => .gte,
        .equal_equal => .eq,
        .bang_equal => .neq,
        .equal_equal_equal => .case_eq,
        .bang_equal_equal => .case_neq,
        .ampersand => .bit_and,
        .pipe => .bit_or,
        .caret => .bit_xor,
        .tilde_caret, .caret_tilde => .bit_xnor,
        .ampersand_ampersand => .bool_and,
        .pipe_pipe => .bool_or,
        else => unreachable, // else: `Parse.binaryPrec` admits these only
    };
}
