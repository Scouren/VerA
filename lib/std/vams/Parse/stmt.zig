//! Statements (A.6.2-A.6.10, IEEE 1364-2005 A.6): tokens in, statement
//! nodes out. One grammar serves analog blocks, `initial`/`always` bodies,
//! functions and tasks: the digital-only forms (`#`, `wait`, `<=`,
//! intra-assignment timing, `fork`, `forever`, procedural continuous
//! assignments, task enables) parse everywhere, and which context may hold
//! which is Sema's question. The one positional rule kept is A.6.4's: under
//! a Verilog-AMS set a block item or construct body is an
//! `analog_statement`, which has no null alternative, except inside an
//! `analog_event_seq_block`.
//! Cites: VAMS-2023 §5.3-§5.11, A.6.3, A.6.4, A.6.5; IEEE 1364-2005 §9.2,
//! §9.3, §9.6, §9.7, §9.8, §15.1.
//!
//! Contents:
//! - `pub const Mode = enum`
//! - `pub fn parseStmt(p: *Parse) Error!Node.Index`
//! - `pub fn parseStmtIn(p: *Parse, mode: Mode) Error!Node.Index`
//! - `pub fn parseIf(p: *Parse, comptime generate: bool) Error!Node.Index`
//! - `pub fn parseFor(p: *Parse, comptime generate: bool) Error!Node.Index`
//! - `pub fn parseCase(p: *Parse, comptime generate: bool) Error!Node.Index`
//! - `pub fn parseHierName(p: *Parse) Error!Node.Index`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("../Ast.zig");
const Parse = @import("../Parse.zig");
const expr = @import("expr.zig");
const decl = @import("decl.zig");
const module = @import("module.zig");
const prim = @import("prim.zig");
const Node = Ast.Node;
const Token = @import("../tokenizer.zig").Token;
const Error = Parse.Error;

/// Where a statement stands: `statement_or_null` (`null_ok`), an A.6.4
/// `analog_statement` (`analog`), or an `analog_event_statement`, whose
/// blocks keep the event's null alternative (`event`).
pub const Mode = enum { null_ok, analog, event };

/// A `statement_or_null`.
pub fn parseStmt(p: *Parse) Error!Node.Index {
    return parseStmtIn(p, .null_ok);
}

/// One statement where `mode` says what may stand.
pub fn parseStmtIn(p: *Parse, mode: Mode) Error!Node.Index {
    try p.enter();
    defer p.leave();
    _ = try p.skipAttributes();
    const tok = p.tok_i;
    switch (p.tokenTag(tok)) {
        .hash, .keyword_wait, .keyword_forever, .keyword_fork, .keyword_assign, .keyword_force, .keyword_deassign, .keyword_release => if (!p.discrete) try p.warn(.digital_statement_in_analog),
        else => {},
    }
    switch (p.tokenTag(tok)) {
        .semicolon => {
            if (mode == .analog and analogGrammar(p)) try p.warn(.null_statement);
            p.tok_i += 1;
            return p.addNode(.null_stmt, tok, .{ .none = {} });
        },
        .hash => {
            const delay = try prim.parseDelayControl(p);
            return p.addNode(.delay_stmt, tok, .{ .node_and_node = .{ delay, try parseStmt(p) } });
        },
        .keyword_wait => return condLoop(p, .wait_stmt),
        .keyword_while => return condLoop(p, .while_stmt),
        .keyword_repeat => return condLoop(p, .repeat_stmt),
        .keyword_assign, .keyword_force, .keyword_deassign, .keyword_release => |t| {
            p.tok_i += 1;
            const lhs = try expr.parsePostfix(p);
            var rhs: Node.OptionalIndex = .none;
            if (t == .keyword_assign or t == .keyword_force) {
                _ = try p.expect(.equal);
                rhs = (try expr.parseExpr(p)).toOptional();
            }
            _ = try p.expect(.semicolon);
            return p.addNode(.procedural_continuous, tok, .{ .node_and_opt_node = .{ lhs, rhs } });
        },
        .keyword_forever => {
            p.tok_i += 1;
            if (p.tokenTag(p.tok_i) == .semicolon) return p.fail(.forever_needs_statement);
            return p.addNode(.forever_stmt, tok, .{ .node = try parseStmt(p) });
        },
        .keyword_begin, .keyword_fork => return parseBlock(p, mode == .event),
        .keyword_if => return parseIf(p, false),
        .keyword_case, .keyword_casex, .keyword_casez => return parseCase(p, false),
        .keyword_for => return parseFor(p, false),
        .at_sign => {
            p.tok_i += 1;
            const event = try parseEventControl(p);
            return p.addNode(.event_stmt, tok, .{ .opt_node_and_node = .{ event, try parseStmtIn(p, .event) } });
        },
        .minus_angle_bracket_right => return semiStmt(p, .event_trigger, tok, try advance(p, expr.parseExpr)),
        .keyword_disable => return semiStmt(p, .disable, tok, try advance(p, parseHierName)),
        .keyword_return => {
            p.tok_i += 1;
            const value: Node.OptionalIndex = if (p.tokenTag(p.tok_i) == .semicolon) .none else (try expr.parseExpr(p)).toOptional();
            _ = try p.expect(.semicolon);
            return p.addNode(.return_stmt, tok, .{ .opt_node = value });
        },
        .keyword_break, .keyword_continue => |t| {
            p.tok_i += 1;
            _ = try p.expect(.semicolon);
            return p.addNode(if (t == .keyword_break) .break_stmt else .continue_stmt, tok, .{ .none = {} });
        },
        // IEEE 1364-2005 §15.1: "no timing check can appear in procedural code".
        .system_identifier => if (prim.timing_checks.has(p.tokenText(tok))) return p.fail(.expected_statement) else return exprStmt(p),
        else => return exprStmt(p),
    }
}

/// `if ( c ) s [else s]`; with `generate`, Syntax 6-8's
/// `if_generate_construct`, whose arms are generate blocks.
pub fn parseIf(p: *Parse, comptime generate: bool) Error!Node.Index {
    const kw = try p.expect(.keyword_if);
    _ = try p.expect(.l_paren);
    const cond = try expr.parseExpr(p);
    _ = try p.expect(.r_paren);
    const then = try body(p, generate);
    const els: Node.OptionalIndex = if (p.eat(.keyword_else) != null) (try body(p, generate)).toOptional() else .none;
    const extra = try p.addExtra(Node.If{ .then = then, .@"else" = els });
    return p.addNode(if (generate) .generate_if else .if_stmt, kw, .{ .node_and_extra = .{ cond, extra } });
}

/// `for ( init ; cond ; step ) s`, or Syntax 6-8's `loop_generate_construct`.
pub fn parseFor(p: *Parse, comptime generate: bool) Error!Node.Index {
    const kw = try p.expect(.keyword_for);
    _ = try p.expect(.l_paren);
    const init = try assignNoSemi(p);
    _ = try p.expect(.semicolon);
    const cond = try expr.parseExpr(p);
    _ = try p.expect(.semicolon);
    const step = try assignNoSemi(p);
    _ = try p.expect(.r_paren);
    const b = try body(p, generate);
    const extra = try p.addExtra(Node.For{ .init = init, .cond = cond, .step = step, .body = b });
    return p.addNode(if (generate) .generate_for else .for_stmt, kw, .{ .extra = extra });
}

/// A.6.7 `case|casex|casez ( e ) items endcase`, or Syntax 6-8's
/// `case_generate_construct`. An item is `default [:] body` or
/// `e {, e} : body`.
pub fn parseCase(p: *Parse, comptime generate: bool) Error!Node.Index {
    assert(p.tokenTag(p.tok_i) == .keyword_case or p.tokenTag(p.tok_i) == .keyword_casex or p.tokenTag(p.tok_i) == .keyword_casez);
    const kw = p.tok_i;
    p.tok_i += 1;
    _ = try p.expect(.l_paren);
    const scrutinee = try expr.parseExpr(p);
    _ = try p.expect(.r_paren);
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    while (p.tokenTag(p.tok_i) != .keyword_endcase and p.tokenTag(p.tok_i) != .eof) {
        const item_at = p.tok_i;
        const past = p.pastAttributes();
        if (past != item_at and (p.tokenTag(past) == .keyword_endcase or p.tokenTag(past) == .eof)) {
            _ = try p.skipAttributes();
            try p.warnAt(.attribute_prefixes_nothing, item_at);
            break;
        }
        _ = try p.skipAttributes();
        const first = p.tok_i;
        const labels_top = p.scratch.items.len;
        if (p.eat(.keyword_default) != null) {
            _ = p.eat(.colon);
        } else {
            while (true) {
                try p.push(try expr.parseExpr(p));
                if (p.eat(.comma) == null) break;
            }
            _ = try p.expect(.colon);
        }
        const labels = try p.spanFrom(labels_top);
        const b = try body(p, generate);
        try p.push(try p.addNode(.case_item, first, .{ .extra_and_node = .{ try p.addExtra(labels), b } }));
    }
    _ = try p.expect(.keyword_endcase);
    const items = try p.spanFrom(top);
    return p.addNode(if (generate) .generate_case else .case_stmt, kw, .{ .node_and_extra = .{ scrutinee, try p.addExtra(items) } });
}

/// A.9.3 `hierarchical_identifier ::= [ $root . ] identifier { . identifier }`
/// with A.9.3's `[ constant_expression ]` per segment.
pub fn parseHierName(p: *Parse) Error!Node.Index {
    const head = p.tok_i;
    if (p.tokenTag(head) == .system_identifier) p.tok_i += 1 else _ = try p.expectIdent();
    var e = try p.addNode(.identifier, head, .{ .none = {} });
    while (true) switch (p.tokenTag(p.tok_i)) {
        .l_bracket => e = try expr.parseSelect(p, e),
        .period => {
            const dot = p.tok_i;
            p.tok_i += 1;
            if (p.tokenTag(p.tok_i) == .system_identifier) p.tok_i += 1 else _ = try p.expectIdent();
            e = try p.addNode(.field_access, dot, .{ .node_and_token = .{ e, dot + 1 } });
        },
        else => return e,
    };
}

// ---- private ----

/// Whether the parse's language is Verilog-AMS, whose A.6.4 analog
/// statements have no null alternative.
fn analogGrammar(p: *const Parse) bool {
    return @backingInt(p.language) >= @backingInt(Parse.KeywordSet.vams_2_3);
}

fn body(p: *Parse, comptime generate: bool) Error!Node.Index {
    return if (generate) module.parseGenerateBlock(p) else parseStmt(p);
}

/// Skips the keyword at the cursor, then parses with `f`.
fn advance(p: *Parse, comptime f: fn (*Parse) Error!Node.Index) Error!Node.Index {
    p.tok_i += 1;
    return f(p);
}

/// `tag` at `kw` over `node`, then the `;`.
fn semiStmt(p: *Parse, tag: Node.Tag, kw: Ast.TokenIndex, node: Node.Index) Error!Node.Index {
    _ = try p.expect(.semicolon);
    return p.addNode(tag, kw, .{ .node = node });
}

/// `kw ( e ) s` for `while`, `repeat` and `wait`.
fn condLoop(p: *Parse, tag: Node.Tag) Error!Node.Index {
    const kw = p.tok_i;
    p.tok_i += 1;
    _ = try p.expect(.l_paren);
    const cond = try expr.parseExpr(p);
    _ = try p.expect(.r_paren);
    return p.addNode(tag, kw, .{ .node_and_node = .{ cond, try parseStmt(p) } });
}

/// A.6.3 `begin|fork [: name] { block_item_declaration } { statement }
/// end|join`. Declarations need the name (`decl_in_unnamed_block`).
fn parseBlock(p: *Parse, event: bool) Error!Node.Index {
    const kw = p.tok_i;
    const fork = p.tokenTag(kw) == .keyword_fork;
    p.tok_i += 1;
    const named = p.eat(.colon) != null;
    if (named) _ = try p.expectIdent();
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    while (true) {
        const past = p.pastAttributes();
        // A keyword the §10.6 set frees, with no name after it, starts a
        // statement (`string = 1;` under "1364-2005").
        if (p.identLike(past) and !p.identLike(past + 1)) break;
        switch (p.tokenTag(past)) {
            .keyword_parameter, .keyword_localparam, .keyword_integer, .keyword_real, .keyword_string, .keyword_realtime, .keyword_time, .keyword_reg, .keyword_event => {},
            else => break,
        }
        if (!named) try p.warnAt(.decl_in_unnamed_block, past);
        _ = try p.skipAttributes();
        try p.push(try decl.parseBlockDecl(p));
    }
    const closer: Token.Tag = if (fork) .keyword_join else .keyword_end;
    while (p.tokenTag(p.tok_i) != closer and p.tokenTag(p.tok_i) != .eof) {
        const before = p.tok_i;
        const past = p.pastAttributes();
        if (past != before and (p.tokenTag(past) == closer or p.tokenTag(past) == .eof)) {
            _ = try p.skipAttributes();
            try p.warnAt(.attribute_prefixes_nothing, before);
            break;
        }
        const s = parseStmtIn(p, if (event) .event else .analog) catch |e| switch (e) {
            error.OutOfMemory => return e,
            error.ParseError => {
                p.recoverItem(before);
                continue;
            },
        };
        try p.push(s);
    }
    _ = try p.expect(closer);
    return p.addNode(.block, kw, .{ .extra_range = try p.spanFrom(top) });
}

/// An A.6.5 `event_control` after the `@`: `*`, `(*)` (lexed three ways),
/// `( event_expression )` or a hierarchical event name. Null for `@*`.
fn parseEventControl(p: *Parse) Error!Node.OptionalIndex {
    const star: u32 = switch (p.tokenTag(p.tok_i)) {
        .asterisk => 1,
        .l_paren_asterisk => if (p.peek(1) == .r_paren) 2 else 0,
        .l_paren => if (p.peek(1) == .asterisk_r_paren) 2 else if (p.peek(1) == .asterisk and p.peek(2) == .r_paren) 3 else 0,
        else => 0,
    };
    p.tok_i += star;
    if (star != 0) return .none;
    if (p.eat(.l_paren) != null) {
        const e = try expr.parseEventExpr(p);
        _ = try p.expect(.r_paren);
        return e.toOptional();
    }
    // A.9.3 `hierarchical_event_identifier`, its last segment unselected:
    // an event-array element is `@(ev[0])`.
    const head = p.tok_i;
    if (p.tokenTag(head) == .system_identifier) p.tok_i += 1 else _ = try p.expectIdent();
    var e = try p.addNode(.identifier, head, .{ .none = {} });
    while (p.tokenTag(p.tok_i) == .period) {
        const dot = p.tok_i;
        p.tok_i += 1;
        _ = try p.expectIdent();
        e = try p.addNode(.field_access, dot, .{ .node_and_token = .{ e, dot + 1 } });
    }
    return e.toOptional();
}

/// A.6.2's optional `delay_or_event_control` after `=` or `<=`, or null.
fn parseIntraTiming(p: *Parse) Error!?Node.Index {
    const tok = p.tok_i;
    if (!p.discrete) return null;
    switch (p.tokenTag(tok)) {
        .hash => return try p.addNode(.delay_control, tok, .{ .node = try prim.parseDelayControl(p) }),
        .at_sign => {
            p.tok_i += 1;
            return try p.addNode(.event_control, tok, .{ .opt_node = try parseEventControl(p) });
        },
        .keyword_repeat => {
            p.tok_i += 1;
            _ = try p.expect(.l_paren);
            const count = try expr.parseExpr(p);
            _ = try p.expect(.r_paren);
            _ = try p.expect(.at_sign);
            return try p.addNode(.repeat_control, tok, .{ .node_and_opt_node = .{ count, try parseEventControl(p) } });
        },
        else => return null,
    }
}

/// `lhs = rhs` with no `;`: a `for` header's assignments.
fn assignNoSemi(p: *Parse) Error!Node.Index {
    const lhs = try expr.parseExpr(p);
    const eq = try p.expect(.equal);
    return p.addNode(.assign, eq, .{ .node_and_node = .{ lhs, try expr.parseExpr(p) } });
}

/// An assignment (`=`, `<=`), a contribution (`<+`, §5.6), an indirect
/// contribution (`: probe == eqn`, §5.6.7) or a task enable (`name;`,
/// `name(args);`). The target is read as an operand first, so `<=` is the
/// nonblocking assignment there; any other operator continues it as an
/// expression (§5.6's `V(a) + ... <+` is no lvalue, which Sema judges).
fn exprStmt(p: *Parse) Error!Node.Index {
    // A.6.4 reads the target as an expression; A.6.2 as an lvalue (a
    // postfix operand), which leaves `<=` and `;` to the statement.
    if (!p.discrete) {
        const lhs = try expr.parseExpr(p);
        // A.6.9 `analog_system_task_enable`, the one enable A.6.4 has.
        if (p.tokenTag(p.tok_i) == .semicolon and systemName(p, lhs)) {
            p.tok_i += 1;
            return p.addNode(.task_enable, p.tok_i - 1, .{ .node = lhs });
        }
        return analogStmt(p, lhs);
    }
    const lhs = try expr.parsePostfix(p);
    if (p.tokenTag(p.tok_i) == .semicolon) {
        switch (p.nodes.items(.tag)[@backingInt(lhs)]) {
            .identifier, .field_access, .call => {},
            else => return p.fail(.expected_statement),
        }
        p.tok_i += 1;
        return p.addNode(.task_enable, p.tok_i - 1, .{ .node = lhs });
    }
    return analogStmt(p, lhs);
}

/// The rest of an expression statement after its target `lhs`.
fn analogStmt(p: *Parse, lhs: Node.Index) Error!Node.Index {
    const op = p.tok_i;
    switch (p.tokenTag(op)) {
        .equal, .angle_bracket_left_equal => |t| {
            if (t == .angle_bracket_left_equal and !p.discrete) return p.fail(.expected_statement);
            switch (p.nodes.items(.tag)[@backingInt(lhs)]) {
                .number_literal, .string_literal => return p.fail(.literal_assignment_target),
                else => {},
            }
            p.tok_i += 1;
            const timing = try parseIntraTiming(p);
            const rhs = try expr.parseExpr(p);
            _ = try p.expect(.semicolon);
            const plain: Node.Tag, const timed: Node.Tag = if (t == .equal) .{ .assign, .assign_timed } else .{ .nonblocking_assign, .nonblocking_assign_timed };
            if (timing) |tm| return p.addNode(timed, op, .{ .node_and_extra = .{ lhs, try p.addExtra(Node.Timed{ .timing = tm, .rhs = rhs }) } });
            return p.addNode(plain, op, .{ .node_and_node = .{ lhs, rhs } });
        },
        .angle_bracket_left_plus => {
            p.tok_i += 1;
            const rhs = try expr.parseExpr(p);
            _ = try p.expect(.semicolon);
            return p.addNode(.contribution, op, .{ .node_and_node = .{ lhs, rhs } });
        },
        .colon => {
            p.tok_i += 1;
            const probe = try expr.parsePostfix(p);
            _ = try p.expect(.equal_equal);
            const eqn = try expr.parseExpr(p);
            _ = try p.expect(.semicolon);
            return p.addNode(.indirect_contribution, op, .{ .node_and_extra = .{ lhs, try p.addExtra(Node.Indirect{ .probe = probe, .eqn = eqn }) } });
        },
        else => return p.fail(.expected_statement),
    }
}

/// Whether `n` is `$name` or `$name(args)`.
fn systemName(p: *const Parse, n: Node.Index) bool {
    const i = @backingInt(n);
    const callee = switch (p.nodes.items(.tag)[i]) {
        .identifier => n,
        .call => p.nodes.items(.data)[i].node_and_extra[0],
        else => return false,
    };
    const c = @backingInt(callee);
    return p.nodes.items(.tag)[c] == .identifier and p.tokenTag(p.nodes.items(.main_token)[c]) == .system_identifier;
}
