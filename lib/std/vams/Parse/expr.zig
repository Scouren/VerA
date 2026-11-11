//! Expressions (A.8.3, A.8.4, A.8.1, A.6.5's event expressions): tokens in,
//! expression nodes out. Binary operators by precedence climbing over Table
//! 4-3 (§4.2.2) in one loop (Zig's `parseExprPrecedence`), so `a+b+...`
//! costs no depth; every operand passes `parseUnary`, which counts one level.
//! A call is any name followed by `(`: `V(p, n)`, `sin(x)` and `f(x)` are
//! all `call` nodes; which is a probe is AstGen's question.
//! Cites: VAMS-2023 §2.9, §4.1, §4.2.2, §4.2.13, §4.2.14, §4.4, §5.10,
//! §6.4.3, §6.7, A.8; IEEE 1364-2005 §5.2.1, §5.3.
//!
//! Contents:
//! - `pub fn parseExpr(p: *Parse) Error!Node.Index`
//! - `pub fn climb(p: *Parse, lhs: Node.Index, min_prec: u8) Error!Node.Index`
//! - `pub fn parseMinTypMax(p: *Parse) Error!Node.Index`
//! - `pub fn parseUnary(p: *Parse) Error!Node.Index`
//! - `pub fn parsePostfix(p: *Parse) Error!Node.Index`
//! - `pub fn parsePrimary(p: *Parse) Error!Node.Index`
//! - `pub fn parseSelect(p: *Parse, base: Node.Index) Error!Node.Index`
//! - `pub fn parseEventExpr(p: *Parse) Error!Node.Index`
//! - `pub fn parseCallArgs(p: *Parse, user: bool) Error!Node.SubRange`
//! - `pub fn parseStepEvent(p: *Parse) Error!Node.Index`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("../Ast.zig");
const Parse = @import("../Parse.zig");
const number_literal = @import("../number_literal.zig");
const Token = @import("../tokenizer.zig").Token;
const Node = Ast.Node;
const Error = Parse.Error;

/// §4.2.12 `?:` sits below every binary operator.
const prec_ternary: u8 = 1;

/// A full expression, `?:` included (§4.1).
pub fn parseExpr(p: *Parse) Error!Node.Index {
    return climb(p, try parseUnary(p), prec_ternary);
}

/// Continues precedence climbing from the operand `lhs` (§4.2.2 Table 4-3):
/// every operator binds left to right except `?:`.
pub fn climb(p: *Parse, lhs: Node.Index, min_prec: u8) Error!Node.Index {
    var result = lhs;
    while (true) {
        const tag = p.tokenTag(p.tok_i);
        if (tag == .question_mark and min_prec <= prec_ternary) {
            const q = p.tok_i;
            p.tok_i += 1;
            _ = try p.skipAttributes();
            try p.enter();
            defer p.leave();
            const then = try climb(p, try parseUnary(p), prec_ternary);
            _ = try p.expect(.colon);
            const els = try climb(p, try parseUnary(p), prec_ternary);
            result = try p.addNode(.ternary, q, .{ .node_and_extra = .{ result, try p.addExtra(Node.Ternary{ .then = then, .@"else" = els }) } });
            continue;
        }
        // IEEE 1364-2005 §5.2.1: `+:` / `-:` end an indexed part-select's base.
        if ((tag == .plus or tag == .minus) and p.peek(1) == .colon) return result;
        const prec = binaryPrec(tag) orelse return result;
        if (prec < min_prec) return result;
        const op = p.tok_i;
        // Annex C.5: Verilog-A has no case equality.
        if (p.verilog_a and (tag == .equal_equal_equal or tag == .bang_equal_equal)) try p.warn(.outside_verilog_a);
        p.tok_i += 1;
        _ = try p.skipAttributes(); // A.8.3: an operator's attribute suffix
        const rhs = try climb(p, try parseUnary(p), prec + 1);
        result = try p.addNode(.binary, op, .{ .node_and_node = .{ result, rhs } });
    }
}

/// IEEE 1364-2005 §5.3 `expression [: expression : expression]`.
pub fn parseMinTypMax(p: *Parse) Error!Node.Index {
    const min = try parseExpr(p);
    const colon = p.eat(.colon) orelse return min;
    const typ = try parseExpr(p);
    _ = try p.expect(.colon);
    const max = try parseExpr(p);
    return p.addNode(.mintypmax, colon, .{ .node_and_extra = .{ min, try p.addExtra(Node.MinTypMax{ .typ = typ, .max = max }) } });
}

/// A.8.3 `unary_operator { attribute_instance } primary`, or a postfix
/// expression. The operand is a primary, so `- -x` is no expression.
pub fn parseUnary(p: *Parse) Error!Node.Index {
    try p.enter();
    defer p.leave();
    switch (p.tokenTag(p.tok_i)) {
        .plus, .minus, .bang, .tilde, .ampersand, .tilde_ampersand, .pipe, .tilde_pipe, .caret, .tilde_caret, .caret_tilde => {
            const op = p.tok_i;
            p.tok_i += 1;
            _ = try p.skipAttributes();
            return p.addNode(.unary, op, .{ .node = try parsePostfix(p) });
        },
        else => return parsePostfix(p),
    }
}

/// A primary and its selects, member names and call: `a[i]`, `u.x`,
/// `$root.t.f(x)`, `g[0].l.x` (IEEE 1364-2005 §12.5).
pub fn parsePostfix(p: *Parse) Error!Node.Index {
    var e = try parsePrimary(p);
    while (true) {
        const tag = p.nodes.items(.tag)[@backingInt(e)];
        const callee = tag == .identifier or tag == .field_access;
        switch (p.tokenTag(p.tok_i)) {
            .l_bracket => e = try parseSelect(p, e),
            .period => {
                if (!callee and tag != .index) return e;
                if (!memberName(p, p.tok_i + 1)) return e;
                const dot = p.tok_i;
                p.tok_i += 2;
                e = try p.addNode(.field_access, dot, .{ .node_and_token = .{ e, dot + 1 } });
            },
            .l_paren => {
                if (!callee) return e;
                const lp = p.tok_i;
                // A.8.2 `function_call`: a user function (a name, or a
                // dotted one) takes no empty argument outside A.6's grammar.
                const head = p.tokenTag(p.nodes.items(.main_token)[@backingInt(e)]);
                const user = !p.discrete and (tag == .field_access or head == .identifier or head == .escaped_identifier or (head.isKeyword() and head != .keyword_builtin and head != .keyword_potential and head != .keyword_flow and head != .keyword_analysis));
                const args = try parseCallArgs(p, user);
                e = try p.addNode(.call, lp, .{ .node_and_extra = .{ e, try p.addExtra(args) } });
            },
            // §2.9 Example 7: `add (* mode = "cla" *) (b, c)`, a call's only.
            .l_paren_asterisk => {
                if (!callee) return e;
                const past = p.pastAttributes();
                if (p.tokenTag(past) != .l_paren) return e;
                _ = try p.skipAttributes();
            },
            else => return e,
        }
    }
}

/// An A.8.4 primary: a literal, `( mintypmax )`, a brace form, a name, a
/// keyword-named call head, a step event, or §6.4.3's `.name` in a paramset.
pub fn parsePrimary(p: *Parse) Error!Node.Index {
    const tok = p.tok_i;
    if (p.identLike(tok)) {
        p.tok_i += 1;
        return p.addNode(.identifier, tok, .{ .none = {} });
    }
    switch (p.tokenTag(tok)) {
        .number_literal => {
            if (number_literal.parseNumberLiteral(p.tokenText(tok)) == .failure) try p.warn(.invalid_number);
            p.tok_i += 1;
            return p.addNode(.number_literal, tok, .{ .none = {} });
        },
        .string_literal => {
            p.tok_i += 1;
            return p.addNode(.string_literal, tok, .{ .none = {} });
        },
        .l_paren => {
            p.tok_i += 1;
            const inner = try parseMinTypMax(p);
            const rp = try p.expect(.r_paren);
            return p.addNode(.grouped, tok, .{ .node_and_token = .{ inner, rp } });
        },
        .l_brace => return parseConcat(p),
        .apostrophe_l_brace => return parsePattern(p),
        .system_identifier, .keyword_inf => {
            p.tok_i += 1;
            return p.addNode(.identifier, tok, .{ .none = {} });
        },
        // Call heads: §4.4's generic `potential`/`flow`, §4.6.1 `analysis`,
        // the A.8.2 built-ins. `expm1`/`ln1p` may also name a function the
        // file declares (annex G.7 item 7780), so they may stand alone.
        .keyword_potential, .keyword_flow, .keyword_analysis, .keyword_builtin => {
            p.tok_i += 1;
            const alone_ok = p.tokenTag(tok) == .keyword_builtin and
                (std.mem.eql(u8, p.tokenText(tok), "expm1") or std.mem.eql(u8, p.tokenText(tok), "ln1p"));
            if (!alone_ok and p.tokenTag(p.pastAttributes()) != .l_paren) {
                _ = try p.expect(.l_paren);
                unreachable;
            }
            return p.addNode(.identifier, tok, .{ .none = {} });
        },
        .keyword_initial_step, .keyword_final_step => return parseStepEvent(p),
        .period => {
            if (!p.in_paramset) return p.fail(.expected_expr);
            p.tok_i += 1;
            return p.addNode(.paramset_output, tok, .{ .token = try p.expectIdent() });
        },
        else => return p.fail(.expected_expr),
    }
}

/// `[ i ]`, `[ msb : lsb ]`, `[ base +: width ]` or `[ base -: width ]` on
/// `base`, cursor on the `[`.
pub fn parseSelect(p: *Parse, base: Node.Index) Error!Node.Index {
    const lb = try p.expect(.l_bracket);
    const a = try parseExpr(p);
    const tag: Node.Tag = if (p.eat(.colon) != null) .range_select else switch (p.tokenTag(p.tok_i)) {
        .plus, .minus => |t| tag: {
            p.tok_i += 2; // `+:` / `-:`, where `climb` stopped
            break :tag if (t == .plus) .indexed_select_up else .indexed_select_down;
        },
        else => { // else: no `:`, `+:` or `-:` after the first index: a bit or element select
            _ = try p.expect(.r_bracket);
            return p.addNode(.index, lb, .{ .node_and_node = .{ base, a } });
        },
    };
    const b = try parseExpr(p);
    _ = try p.expect(.r_bracket);
    return p.addNode(tag, lb, .{ .node_and_extra = .{ base, try p.addExtra(Node.Pair{ .a = a, .b = b }) } });
}

/// A.6.5 `event_expression`: terms joined by `or` or `,`.
pub fn parseEventExpr(p: *Parse) Error!Node.Index {
    var lhs = try parseEventTerm(p);
    while (p.tokenTag(p.tok_i) == .keyword_or or p.tokenTag(p.tok_i) == .comma) {
        const op = p.tok_i;
        p.tok_i += 1;
        lhs = try p.addNode(.event_or, op, .{ .node_and_node = .{ lhs, try parseEventTerm(p) } });
    }
    return lhs;
}

/// An argument list `( [arg] {, [arg]} )`, cursor on the `(`; an omitted
/// argument is a none slot (`empty_argument` in a `user` call), and
/// `< net >` (§5.4.3) a `port_branch`.
pub fn parseCallArgs(p: *Parse, user: bool) Error!Node.SubRange {
    _ = try p.expect(.l_paren);
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    if (p.tokenTag(p.tok_i) == .r_paren) {
        if (user) try p.warn(.empty_argument);
        p.tok_i += 1;
        return p.spanFrom(top);
    }
    while (true) {
        switch (p.tokenTag(p.tok_i)) {
            .comma, .r_paren => {
                if (user) try p.warn(.empty_argument);
                try p.pushOpt(.none);
            },
            .angle_bracket_left => {
                const lt = p.tok_i;
                p.tok_i += 1;
                const net = try parsePostfix(p);
                _ = try p.expect(.angle_bracket_right);
                try p.push(try p.addNode(.port_branch, lt, .{ .node = net }));
            },
            else => try p.push(try parseExpr(p)),
        }
        if (p.eat(.comma) == null) break;
    }
    _ = try p.expect(.r_paren);
    return p.spanFrom(top);
}

/// A.6.5 `initial_step|final_step [ ( "analysis" { , "analysis" } ) ]`,
/// the list never empty.
pub fn parseStepEvent(p: *Parse) Error!Node.Index {
    const tok = p.tok_i;
    p.tok_i += 1;
    if (p.eat(.l_paren) != null) {
        if (p.tokenTag(p.tok_i) == .r_paren) try p.warn(.empty_step_event_list);
        while (p.tokenTag(p.tok_i) != .r_paren) {
            _ = try p.expect(.string_literal);
            if (p.eat(.comma) == null) break;
        }
        _ = try p.expect(.r_paren);
    }
    return p.addNode(.step_event, tok, .{ .none = {} });
}

// ---- private ----

/// `posedge`/`negedge`/`driver_update` expression, a step event (a term
/// alone, no operand of an operator), or an expression.
fn parseEventTerm(p: *Parse) Error!Node.Index {
    switch (p.tokenTag(p.tok_i)) {
        .keyword_initial_step, .keyword_final_step => return parseStepEvent(p),
        .keyword_posedge, .keyword_negedge, .keyword_driver_update => |t| {
            const kw = p.tok_i;
            // §9.22: outside a connect module, a discrete event reports the
            // rule and an analog one finds no expression (§2.8.2).
            if (t == .keyword_driver_update and !p.connect_module) {
                if (!p.discrete) return p.fail(.expected_expr);
                try p.warn(.driver_update_outside_connect_module);
            }
            p.tok_i += 1;
            return p.addNode(.edge_event, kw, .{ .node = try parseExpr(p) });
        },
        else => return parseExpr(p),
    }
}

/// §4.2.13 `{ e {, e} }` or `{ n { e {, e} } }`, cursor on the `{`.
fn parseConcat(p: *Parse) Error!Node.Index {
    try p.enter();
    defer p.leave();
    const lb = try p.expect(.l_brace);
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    if (p.eat(.r_brace) != null) return p.addNode(.concat, lb, .{ .extra_range = try p.spanFrom(top) });
    const first = try parseExpr(p);
    if (p.tokenTag(p.tok_i) == .l_brace) {
        const inner = try parseConcat(p);
        _ = try p.expect(.r_brace);
        return p.addNode(.multi_concat, lb, .{ .node_and_node = .{ first, inner } });
    }
    try p.push(first);
    while (p.eat(.comma) != null) try p.push(try parseExpr(p));
    _ = try p.expect(.r_brace);
    return p.addNode(.concat, lb, .{ .extra_range = try p.spanFrom(top) });
}

/// §4.2.14 `'{ [e] {, [e]} }` (a hole is §3.6.3.2's) or `'{ n { ... } }`.
fn parsePattern(p: *Parse) Error!Node.Index {
    try p.enter();
    defer p.leave();
    const lb = try p.expect(.apostrophe_l_brace);
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    if (p.eat(.r_brace) != null) return p.addNode(.assign_pattern, lb, .{ .extra_range = try p.spanFrom(top) });
    if (p.tokenTag(p.tok_i) != .comma) {
        const first = try parseExpr(p);
        if (p.tokenTag(p.tok_i) == .l_brace) {
            const inner = try parseConcat(p);
            _ = try p.expect(.r_brace);
            return p.addNode(.pattern_repl, lb, .{ .node_and_node = .{ first, inner } });
        }
        try p.push(first);
    } else try p.pushOpt(.none);
    while (p.eat(.comma) != null) switch (p.tokenTag(p.tok_i)) {
        .comma, .r_brace => try p.pushOpt(.none),
        else => try p.push(try parseExpr(p)),
    };
    _ = try p.expect(.r_brace);
    return p.addNode(.assign_pattern, lb, .{ .extra_range = try p.spanFrom(top) });
}

/// Whether token `i` can follow a `.` in a dotted name: a name, a §6.3.6
/// system parameter, a Syntax 5-4 nature attribute keyword, or §5.6.8.2's
/// `branch`.
fn memberName(p: *const Parse, i: Ast.TokenIndex) bool {
    if (p.identLike(i)) return true;
    return switch (p.tokenTag(i)) {
        .system_identifier, .keyword_potential, .keyword_flow, .keyword_abstol, .keyword_access, .keyword_units, .keyword_ddt_nature, .keyword_idt_nature, .keyword_branch => true,
        else => false,
    };
}

/// §4.2.2 Table 4-3's binary precedence of `tag`, highest binds tightest;
/// null for a token that is no binary operator.
fn binaryPrec(tag: Token.Tag) ?u8 {
    return switch (tag) {
        .asterisk_asterisk => 12,
        .asterisk, .slash, .percent => 11,
        .plus, .minus => 10,
        .angle_bracket_angle_bracket_left, .angle_bracket_angle_bracket_right, .angle_bracket_angle_bracket_angle_bracket_left, .angle_bracket_angle_bracket_angle_bracket_right => 9,
        .angle_bracket_left, .angle_bracket_left_equal, .angle_bracket_right, .angle_bracket_right_equal => 8,
        .equal_equal, .bang_equal, .equal_equal_equal, .bang_equal_equal => 7,
        .ampersand => 6,
        .caret, .tilde_caret, .caret_tilde => 5,
        .pipe => 4,
        .ampersand_ampersand => 3,
        .pipe_pipe => 2,
        else => null,
    };
}
