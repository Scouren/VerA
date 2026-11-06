//! IEEE 1364 primitives and timing (inherited through VAMS §1.1): A.2.2.2
//! strengths, A.2.2.3 delays, A.3 gate, switch and pull instantiations, A.7
//! specify blocks with their paths, pulse declarations and A.7.5 timing
//! checks: tokens in, nodes out. The shape rules A.3 and A.7 state over one
//! item (terminal counts, a parallel path's single terminals, a timing
//! check's arity) are checked here; rules over the module's ports are Sema's.
//! Cites: IEEE 1364-2005 §2.6.2 (via VAMS), §4.4, §6.1.4, §7, §14, §15,
//! A.2.2, A.3, A.7.
//!
//! Contents:
//! - `pub const timing_checks`
//! - `pub fn strengthSide(tag: Token.Tag) ?u2`
//! - `pub fn parseDriveStrength(p: *Parse) Error!void`
//! - `pub fn parseChargeStrength(p: *Parse, trireg: bool) Error!void`
//! - `pub fn parseDelay(p: *Parse, max: u8) Error!Node.Index`
//! - `pub fn parseDelayControl(p: *Parse) Error!Node.Index`
//! - `pub fn parseGates(p: *Parse) Error!Node.Index`
//! - `pub fn parseSpecify(p: *Parse) Error!Node.Index`
//! - `pub fn isNetLvalue(p: *const Parse, n: Node.Index) bool`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("../Ast.zig");
const Parse = @import("../Parse.zig");
const expr = @import("expr.zig");
const decl = @import("decl.zig");
const number_literal = @import("../number_literal.zig");
const Token = @import("../tokenizer.zig").Token;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const Error = Parse.Error;

/// A.7.5.1's twelve timing checks and their argument counts `{ mandatory,
/// mandatory + optional }`.
pub const timing_checks = std.StaticStringMap(struct { u8, u8 }).initComptime(.{
    .{ "$setup", .{ 3, 4 } },    .{ "$hold", .{ 3, 4 } },   .{ "$setuphold", .{ 4, 9 } }, .{ "$recovery", .{ 3, 4 } },
    .{ "$removal", .{ 3, 4 } },  .{ "$recrem", .{ 4, 9 } }, .{ "$skew", .{ 3, 4 } },      .{ "$timeskew", .{ 3, 6 } },
    .{ "$fullskew", .{ 4, 7 } }, .{ "$period", .{ 2, 3 } }, .{ "$width", .{ 2, 4 } },     .{ "$nochange", .{ 4, 5 } },
});

/// What distinguishes the A.3.1 arms: terminal counts, how many lead as
/// `net_lvalue`s (`all_but_last` for buf/not), and the most delay values
/// (0: none).
const Shape = struct { min: u8, max: u8, lvalues: u8, delay: u8, strength: bool = true };

const all_but_last: u8 = 255;

/// The side of an A.2.2.2 strength keyword: 0 for `strength0`/`highz0`, 1
/// for their `1`s, 2 for a charge strength; null for any other token.
pub fn strengthSide(tag: Token.Tag) ?u2 {
    return switch (tag) {
        .keyword_supply0, .keyword_strong0, .keyword_pull0, .keyword_weak0, .keyword_highz0 => 0,
        .keyword_supply1, .keyword_strong1, .keyword_pull1, .keyword_weak1, .keyword_highz1 => 1,
        .keyword_small, .keyword_medium, .keyword_large => 2,
        else => null,
    };
}

/// A.2.2.2 `( strength0 , strength1 )` in either order, not both `highz`
/// (IEEE 1364-2005 §6.1.4); cursor on the `(`.
pub fn parseDriveStrength(p: *Parse) Error!void {
    _ = try p.expect(.l_paren);
    const a = p.tok_i;
    const sa = strengthSide(p.tokenTag(a)) orelse return p.fail(.expected_strength);
    p.tok_i += 1;
    _ = try p.expect(.comma);
    const sb = strengthSide(p.tokenTag(p.tok_i)) orelse return p.fail(.expected_strength);
    const b = p.tok_i;
    p.tok_i += 1;
    _ = try p.expect(.r_paren);
    if (sa == sb or sa == 2 or sb == 2) return p.failAt(.expected_strength, a);
    if (p.tokenTag(a) == .keyword_highz0 or p.tokenTag(a) == .keyword_highz1) {
        if (p.tokenTag(b) == .keyword_highz0 or p.tokenTag(b) == .keyword_highz1) return p.failAt(.expected_strength, a);
    }
}

/// A.2.1.3 `charge_strength ::= ( small | medium | large )`, a `trireg`'s
/// only (E0257 before).
pub fn parseChargeStrength(p: *Parse, trireg: bool) Error!void {
    _ = try p.expect(.l_paren);
    const tok = p.tok_i;
    const side = strengthSide(p.tokenTag(tok)) orelse return p.fail(.expected_strength);
    p.tok_i += 1;
    _ = try p.expect(.r_paren);
    if (!trireg or side != 2) return p.failAt(.invalid_net_declaration, tok);
}

/// A.2.2.3 `# delay_value` or `# ( mintypmax {, mintypmax} )` with at
/// most `max` values (`delay2`, `delay3`), as a `delay` node; cursor on the
/// `#`. §2.6.2: no scale factor in a digital delay.
pub fn parseDelay(p: *Parse, max: u8) Error!Node.Index {
    const hash = try p.expect(.hash);
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    if (p.eat(.l_paren) != null) {
        var n: u8 = 0;
        while (true) : (n += 1) {
            try p.push(try expr.parseMinTypMax(p));
            if (n + 1 == max or p.eat(.comma) == null) break;
        }
        _ = try p.expect(.r_paren);
    } else try p.push(try delayValue(p));
    try checkScaleFactors(p, hash, p.tok_i);
    return p.addNode(.delay, hash, .{ .extra_range = try p.spanFrom(top) });
}

/// A.6.5 `delay_control ::= # delay_value | # ( mintypmax )`, cursor on the
/// `#`; returns the value.
pub fn parseDelayControl(p: *Parse) Error!Node.Index {
    const hash = try p.expect(.hash);
    const value = if (p.tokenTag(p.tok_i) == .l_paren) try expr.parsePrimary(p) else try delayValue(p);
    try checkScaleFactors(p, hash, p.tok_i);
    return value;
}

/// A.3.1 gate, switch and pull instantiations: `gate [strength] [delay]
/// instance {, instance} ;`, an instance `[name [range]] ( terminals )`.
/// The terminal count and output lvalues are A.3.1/A.3.3's.
pub fn parseGates(p: *Parse) Error!Node.Index {
    const kw = p.tok_i;
    const tag = p.tokenTag(kw);
    p.tok_i += 1;
    const pull = tag == .keyword_pullup or tag == .keyword_pulldown;
    const shape = gateShape(tag);
    // A.3.1: switches take no strength.
    if (shape.strength and p.tokenTag(p.tok_i) == .l_paren and strengthSide(p.peek(1)) != null) {
        if (pull and p.peek(2) != .comma) {
            // A.3.2's single-strength bracket names the gate's own side.
            p.tok_i += 1;
            const side = strengthSide(p.tokenTag(p.tok_i)).?;
            p.tok_i += 1;
            _ = try p.expect(.r_paren);
            if (side != @intFromBool(tag == .keyword_pullup)) return p.failAt(.expected_strength, p.tok_i - 2);
        } else try parseDriveStrength(p);
    }
    const delay: Node.OptionalIndex = if (shape.delay != 0 and p.tokenTag(p.tok_i) == .hash) (try parseDelay(p, shape.delay)).toOptional() else .none;
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    while (true) {
        const inst = p.tok_i;
        var range: Node.OptionalIndex = .none;
        if (p.identLike(p.tok_i)) {
            p.tok_i += 1;
            if (p.tokenTag(p.tok_i) == .l_bracket) range = (try decl.parseRange(p)).toOptional();
        }
        _ = try p.expect(.l_paren);
        const terms_top = p.scratch.items.len;
        while (true) {
            try p.push(try expr.parseExpr(p));
            if (p.eat(.comma) == null) break;
        }
        _ = try p.expect(.r_paren);
        const terms: []const u32 = p.scratch.items[terms_top..];
        if (terms.len < shape.min or terms.len > shape.max) return p.failAt(.invalid_gate_terminals, inst);
        const outs = if (shape.lvalues == all_but_last) terms.len - 1 else shape.lvalues;
        for (terms[0..outs]) |t| if (!isNetLvalue(p, @fromBackingInt(t))) return p.failAt(.invalid_gate_terminals, inst);
        const span = try p.spanFrom(terms_top);
        const extra = try p.addExtra(Node.GateInstance{ .range = range, .terms_start = span.start, .terms_end = span.end });
        try p.push(try p.addNode(.gate_instance, inst, .{ .extra = extra }));
        if (p.eat(.comma) == null) break;
    }
    _ = try p.expect(.semicolon);
    const items = try p.spanFrom(top);
    return p.addNode(.gate_instantiation, kw, .{ .extra = try p.addExtra(Node.Decl{ .range = delay, .items_start = items.start, .items_end = items.end }) });
}

/// A.7.1 `specify { specify_item } endspecify`.
pub fn parseSpecify(p: *Parse) Error!Node.Index {
    assert(p.tokenTag(p.tok_i) == .keyword_specify);
    const kw = p.tok_i;
    p.tok_i += 1;
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    while (p.eat(.keyword_endspecify) == null) {
        if (p.tokenTag(p.tok_i) == .eof or p.tokenTag(p.tok_i) == .keyword_endmodule) return p.fail(.invalid_specify_item);
        try p.push(try parseSpecifyItem(p));
    }
    return p.addNode(.specify_block, kw, .{ .extra_range = try p.spanFrom(top) });
}

/// A.8.5 `net_lvalue`: a (dotted) name with selects, or a concatenation of
/// them.
pub fn isNetLvalue(p: *const Parse, n: Node.Index) bool {
    const i = @backingInt(n);
    return switch (p.nodes.items(.tag)[i]) {
        .identifier => true,
        .field_access, .index, .range_select, .indexed_select_up, .indexed_select_down => isNetLvalue(p, switch (p.nodes.items(.tag)[i]) {
            .field_access => p.nodes.items(.data)[i].node_and_token[0],
            .index => p.nodes.items(.data)[i].node_and_node[0],
            else => p.nodes.items(.data)[i].node_and_extra[0],
        }),
        .concat => for (@as([]const Node.Index, @ptrCast(p.extra_data.items[@backingInt(p.nodes.items(.data)[i].extra_range.start)..@backingInt(p.nodes.items(.data)[i].extra_range.end)]))) |c| {
            if (!isNetLvalue(p, c)) break false;
        } else true,
        else => false,
    };
}

// ---- private ----

fn gateShape(tag: Token.Tag) Shape {
    return switch (tag) {
        .keyword_and, .keyword_nand, .keyword_or, .keyword_nor, .keyword_xor, .keyword_xnor => .{ .min = 2, .max = 255, .lvalues = 1, .delay = 2 },
        .keyword_buf, .keyword_not => .{ .min = 2, .max = 255, .lvalues = all_but_last, .delay = 2 },
        .keyword_bufif0, .keyword_bufif1, .keyword_notif0, .keyword_notif1 => .{ .min = 3, .max = 3, .lvalues = 1, .delay = 3 },
        .keyword_cmos, .keyword_rcmos => .{ .min = 4, .max = 4, .lvalues = 1, .delay = 3, .strength = false },
        .keyword_nmos, .keyword_pmos, .keyword_rnmos, .keyword_rpmos => .{ .min = 3, .max = 3, .lvalues = 1, .delay = 3, .strength = false },
        .keyword_tran, .keyword_rtran => .{ .min = 2, .max = 2, .lvalues = 2, .delay = 0, .strength = false },
        .keyword_tranif0, .keyword_tranif1, .keyword_rtranif0, .keyword_rtranif1 => .{ .min = 3, .max = 3, .lvalues = 2, .delay = 3, .strength = false },
        .keyword_pullup, .keyword_pulldown => .{ .min = 1, .max = 1, .lvalues = 1, .delay = 0 },
        else => unreachable,
    };
}

/// A.2.2.3 `delay_value ::= unsigned_number | real_number | identifier`:
/// one token, never an expression; a sized or based number needs the
/// parenthesized form.
fn delayValue(p: *Parse) Error!Node.Index {
    const tok = p.tok_i;
    if (p.identLike(tok) and p.peek(1) != .period) {
        p.tok_i += 1;
        return p.addNode(.identifier, tok, .{ .none = {} });
    }
    if (p.tokenTag(tok) == .number_literal and std.mem.findScalar(u8, p.tokenText(tok), '\'') != null) return p.fail(.invalid_delay_value);
    return expr.parsePrimary(p);
}

/// §2.6.2: a real with a scale factor among tokens `from..to` outside an
/// attribute instance is `scale_factor_in_delay`.
fn checkScaleFactors(p: *Parse, from: TokenIndex, to: TokenIndex) Error!void {
    var in_attr = false;
    for (from..to) |i| switch (p.tokenTag(@intCast(i))) {
        .l_paren_asterisk => in_attr = true,
        .asterisk_r_paren => in_attr = false,
        .number_literal => if (!in_attr) {
            const text = p.tokenText(@intCast(i));
            if (std.mem.findScalar(u8, text, '\'') == null and number_literal.scaleExponent(text[text.len - 1]) != null) try p.warnAt(.scale_factor_in_delay, @intCast(i));
        },
        else => {},
    };
}

/// One A.7.1 specify item: a specparam, a pulse declaration, a path or a
/// timing check.
fn parseSpecifyItem(p: *Parse) Error!Node.Index {
    const tok = p.tok_i;
    switch (p.tokenTag(tok)) {
        .keyword_specparam => {
            const node = try decl.parseParamDecl(p);
            _ = try p.expect(.semicolon);
            return node;
        },
        .keyword_pulsestyle_onevent, .keyword_pulsestyle_ondetect, .keyword_showcancelled, .keyword_noshowcancelled => {
            p.tok_i += 1;
            // §14.6.4.2 writes the list without parentheses.
            if (p.tokenTag(p.tok_i) == .l_paren) try p.warn(.invalid_specify_item);
            const paren = p.eat(.l_paren) != null;
            const terms = try terminalList(p);
            if (paren) _ = try p.expect(.r_paren);
            _ = try p.expect(.semicolon);
            return p.addNode(.specify_terminals, tok, .{ .extra_range = terms });
        },
        .keyword_ifnone => {
            p.tok_i += 1;
            return parsePath(p, tok, .none);
        },
        .keyword_if => {
            p.tok_i += 1;
            _ = try p.expect(.l_paren);
            const cond = try expr.parseExpr(p);
            _ = try p.expect(.r_paren);
            // §14.2.4.1 Table 14-1: a condition's operators.
            if (badOperator(p, cond)) |at| try p.warnAt(.invalid_specify_item, at);
            return parsePath(p, tok, cond.toOptional());
        },
        .l_paren => return parsePath(p, tok, .none),
        .system_identifier => return parseTimingCheck(p),
        else => return p.fail(.invalid_specify_item),
    }
}

/// A.7.3 descriptors `name [ [range] ] {, ...}`.
fn terminalList(p: *Parse) Error!Node.SubRange {
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    while (true) {
        const name = try p.expectIdent();
        const id = try p.addNode(.identifier, name, .{ .none = {} });
        try p.push(if (p.tokenTag(p.tok_i) == .l_bracket) try expr.parseSelect(p, id) else id);
        if (p.eat(.comma) == null) break;
    }
    return p.spanFrom(top);
}

/// A.7.2 path declarations: `( [edge] inputs [polarity] =>|*> outputs ) =
/// delays ;` or the edge-sensitive `=> ( outputs [polarity] : data )`.
/// `=>` joins one input to one output; the delays are 1, 2, 3, 6 or 12.
fn parsePath(p: *Parse, first: TokenIndex, cond: Node.OptionalIndex) Error!Node.Index {
    _ = try p.expect(.l_paren);
    _ = p.eat(.keyword_posedge) orelse p.eat(.keyword_negedge);
    const inputs = try terminalList(p);
    const polarity = p.eat(.plus) orelse p.eat(.minus);
    const arrow = p.tok_i;
    if (p.eat(.equal_angle_bracket_right) == null and p.eat(.asterisk_angle_bracket_right) == null) return p.fail(.invalid_specify_item);
    var data: Node.OptionalIndex = .none;
    // Syntax 14-4 puts an edge-sensitive path's polarity after the
    // destination; Syntax 14-5's `ifnone` takes a simple path.
    if (p.tokenTag(p.tok_i) == .l_paren and (polarity != null or p.tokenTag(first) == .keyword_ifnone)) try p.warnAt(.invalid_specify_item, first);
    const outputs = if (p.eat(.l_paren) != null) edge: {
        const outs = try terminalList(p);
        _ = p.eat(.plus) orelse p.eat(.minus);
        _ = try p.expect(.colon);
        data = (try expr.parseExpr(p)).toOptional();
        _ = try p.expect(.r_paren);
        break :edge outs;
    } else try terminalList(p);
    const parallel = p.tokenTag(arrow) == .equal_angle_bracket_right;
    if (parallel and (@backingInt(inputs.end) - @backingInt(inputs.start) != 1 or @backingInt(outputs.end) - @backingInt(outputs.start) != 1)) return p.fail(.invalid_specify_item);
    _ = try p.expect(.r_paren);
    _ = try p.expect(.equal);
    const bracketed = p.eat(.l_paren) != null;
    const delay_at = p.tok_i;
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    while (true) {
        try p.push(try expr.parseMinTypMax(p));
        if (p.eat(.comma) == null) break;
    }
    switch (p.scratch.items.len - top) {
        1, 2, 3, 6, 12 => {},
        else => return p.failAt(.invalid_specify_item, delay_at),
    }
    try checkScaleFactors(p, delay_at, p.tok_i);
    if (bracketed) _ = try p.expect(.r_paren);
    _ = try p.expect(.semicolon);
    const delays = try p.spanFrom(top);
    return p.addNode(.path_decl, first, .{ .extra = try p.addExtra(Node.Path{
        .cond = cond,
        .inputs_start = inputs.start,
        .inputs_end = inputs.end,
        .outputs_start = outputs.start,
        .outputs_end = outputs.end,
        .data_source = data,
        .delays_start = delays.start,
        .delays_end = delays.end,
        .arrow = arrow,
    }) });
}

/// A.7.5.1 `$check ( args ) ;`: the arity, the event arguments' controls
/// (`posedge`, `negedge`, `edge [ descriptors ]`) and `&&&` conditions,
/// required arguments, and the notifier's single name.
fn parseTimingCheck(p: *Parse) Error!Node.Index {
    const tok = p.tok_i;
    const name = p.tokenText(tok);
    const arity = timing_checks.get(name) orelse return p.fail(.invalid_specify_item);
    const controlled_first = std.mem.eql(u8, name, "$period") or std.mem.eql(u8, name, "$width");
    const events: u8 = if (controlled_first) 1 else 2;
    const notifier: u8 = if (std.mem.eql(u8, name, "$width")) 4 else arity[0] + 1;
    p.tok_i += 1;
    _ = try p.expect(.l_paren);
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    var n: u8 = 0;
    if (p.tokenTag(p.tok_i) != .r_paren) while (true) {
        n +|= 1;
        const arg = p.tok_i;
        if (p.tokenTag(arg) == .comma or p.tokenTag(arg) == .r_paren) {
            if (n <= arity[0] or std.mem.eql(u8, name, "$width")) return p.failAt(.invalid_specify_item, arg);
            try p.pushOpt(.none);
        } else {
            const edge = p.tokenTag(arg) == .keyword_posedge or p.tokenTag(arg) == .keyword_negedge or p.tokenTag(arg) == .keyword_edge;
            if (edge) try edgeControl(p);
            const term = switch (mintypmaxArg(name, n)) {
                .no => try expr.parseExpr(p),
                .yes => try expr.parseMinTypMax(p),
                // `terminal [ constant_mintypmax_expression ]`.
                .select => if (p.identLike(p.tok_i) and p.peek(1) == .l_bracket) sel: {
                    const base = try p.addNode(.identifier, p.tok_i, .{ .none = {} });
                    p.tok_i += 1;
                    const lb = try p.expect(.l_bracket);
                    const i = try expr.parseMinTypMax(p);
                    _ = try p.expect(.r_bracket);
                    break :sel try p.addNode(.index, lb, .{ .node_and_node = .{ base, i } });
                } else try expr.parseExpr(p),
            };
            const cond: Node.OptionalIndex = if (p.eat(.ampersand_ampersand_ampersand) != null) (try expr.parseExpr(p)).toOptional() else .none;
            if (n > events and (edge or cond != .none)) return p.failAt(.invalid_specify_item, arg);
            if (n == 1 and controlled_first and !edge) return p.failAt(.invalid_specify_item, arg);
            if (n == notifier and !(p.tok_i == arg + 1 and (p.tokenTag(arg) == .identifier or p.tokenTag(arg) == .escaped_identifier))) return p.failAt(.invalid_specify_item, arg);
            try p.push(if (edge or cond != .none) try p.addNode(.timing_event, arg, .{ .node_and_opt_node = .{ term, cond } }) else term);
        }
        if (p.eat(.comma) == null) break;
    };
    _ = try p.expect(.r_paren);
    _ = try p.expect(.semicolon);
    if (n < arity[0] or n > arity[1]) return p.failAt(.invalid_specify_item, tok);
    return p.addNode(.timing_check, tok, .{ .extra_range = try p.spanFrom(top) });
}

/// `posedge`, `negedge`, or A.7.5.3 `edge [ descriptor {, descriptor} ]`,
/// each descriptor two characters from `01`, `10`, or 0/1 with x/z, which
/// lex as numbers or names, so the characters are read across tokens.
fn edgeControl(p: *Parse) Error!void {
    if (p.eat(.keyword_edge) == null) {
        p.tok_i += 1;
        return;
    }
    _ = try p.expect(.l_bracket);
    while (true) {
        const at = p.tok_i;
        var d: [2]u8 = undefined;
        var len: usize = 0;
        while (p.tokenTag(p.tok_i) != .comma and p.tokenTag(p.tok_i) != .r_bracket) : (p.tok_i += 1) {
            if (p.tokenTag(p.tok_i) == .eof) return p.fail(.invalid_specify_item);
            for (p.tokenText(p.tok_i)) |c| {
                if (len < 2) d[len] = std.ascii.toLower(c);
                len += 1;
            }
        }
        if (len != 2 or !edgeDescriptor(d[0], d[1])) return p.failAt(.invalid_specify_item, at);
        if (p.eat(.r_bracket) != null) return;
        p.tok_i += 1;
    }
}

/// The first operation in `n` IEEE 1364-2005 Table 14-1 does not list
/// (unary `+`/`-`, arithmetic, relational, shifts, case equality), as its
/// operator token, or null. Bounded by the parse's own depth.
fn badOperator(p: *const Parse, n: Node.Index) ?TokenIndex {
    const i = @backingInt(n);
    const data = p.nodes.items(.data)[i];
    const main = p.nodes.items(.main_token)[i];
    switch (p.nodes.items(.tag)[i]) {
        .unary => return switch (p.tokenTag(main)) {
            .plus, .minus => main,
            else => badOperator(p, data.node), // else: only unary `+`/`-` are refused here; look inside the rest
        },
        .binary => return switch (p.tokenTag(main)) {
            .equal_equal, .bang_equal, .ampersand_ampersand, .pipe_pipe, .ampersand, .pipe, .caret, .tilde_caret, .caret_tilde => badOperator(p, data.node_and_node[0]) orelse badOperator(p, data.node_and_node[1]),
            else => main,
        },
        .grouped => return badOperator(p, data.node_and_token[0]),
        .ternary => {
            // `Node.Ternary` is `then, else`.
            const x = @backingInt(data.node_and_extra[1]);
            return badOperator(p, data.node_and_extra[0]) orelse
                badOperator(p, @fromBackingInt(p.extra_data.items[x])) orelse
                badOperator(p, @fromBackingInt(p.extra_data.items[x + 1]));
        },
        .index => return badOperator(p, data.node_and_node[0]) orelse badOperator(p, data.node_and_node[1]),
        else => return null,
    }
}

/// Which A.7.5.2 arguments are `mintypmax_expression`s: `$setuphold`'s
/// and `$recrem`'s 6th and 7th (and the 8th and 9th's selects), and
/// `$nochange`'s 3rd and 4th; the rest are `expression`s.
fn mintypmaxArg(name: []const u8, n: u8) enum { no, yes, select } {
    if (std.mem.eql(u8, name, "$nochange")) return if (n == 3 or n == 4) .yes else .no;
    if (!std.mem.eql(u8, name, "$setuphold") and !std.mem.eql(u8, name, "$recrem")) return .no;
    return switch (n) {
        6, 7 => .yes,
        8, 9 => .select,
        else => .no,
    };
}

fn edgeDescriptor(a: u8, b: u8) bool {
    const a01 = a == '0' or a == '1';
    const b01 = b == '0' or b == '1';
    const axz = a == 'x' or a == 'z';
    const bxz = b == 'x' or b == 'z';
    return (a01 and b01 and a != b) or (axz and b01) or (a01 and bxz);
}
