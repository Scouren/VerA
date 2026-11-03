//! Modules (A.1.2 module_declaration, A.1.3 ports, A.1.4 module items) and
//! their generate constructs (A.4.2) and module instantiations (A.4.1):
//! tokens from `module` to `endmodule` in, a `module_decl` node out. Each
//! item is dispatched on its first token to the file owning its grammar.
//! An identifier opens an instance, a UDP instance or a net declaration,
//! told apart by at most three tokens (`parseIdentItem`).
//! Cites: VAMS-2023 §6.2, §6.2.2, §6.3, §6.3.1, §6.5, §6.6, §7.6, §10.6,
//! A.1.2-A.1.4, A.4.1, A.4.2; IEEE 1364-2005 §12.3.3, §19.2, §19.6, §19.9.
//!
//! Contents:
//! - `pub fn parseModule(p: *Parse) Error!Node.Index`
//! - `pub fn parseItems(p: *Parse, end: Token.Tag) Error!Node.SubRange`
//! - `pub fn parseGenerateBlock(p: *Parse) Error!Node.Index`
//! - `pub fn parseParamValues(p: *Parse) Error!Node.SubRange`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("../Ast.zig");
const Parse = @import("../Parse.zig");
const expr = @import("expr.zig");
const stmt = @import("stmt.zig");
const decl = @import("decl.zig");
const prim = @import("prim.zig");
const udp = @import("udp.zig");
const function = @import("function.zig");
const Token = @import("../tokenizer.zig").Token;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const Error = Parse.Error;

/// A.1.2 `module_keyword name [ #( parameter_declaration {, ...} ) ]
/// [ ( ports ) ] ; { module_item } endmodule`.
pub fn parseModule(p: *Parse) Error!Node.Index {
    assert(p.tokenTag(p.tok_i) == .keyword_module or p.tokenTag(p.tok_i) == .keyword_macromodule or p.tokenTag(p.tok_i) == .keyword_connectmodule);
    const kw = p.tok_i;
    p.tok_i += 1;
    _ = try p.expectIdent();
    p.connect_module = p.tokenTag(kw) == .keyword_connectmodule;
    defer p.connect_module = false;
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    // A.1.3 `module_parameter_port_list`: `parameter` declarations only,
    // at least one.
    if (p.eat(.hash) != null) {
        _ = try p.expect(.l_paren);
        const first = p.tok_i;
        while (p.tokenTag(p.tok_i) == .keyword_parameter or p.tokenTag(p.tok_i) == .keyword_localparam) {
            if (p.tokenTag(p.tok_i) == .keyword_localparam) try p.warn(.invalid_parameter_list);
            try p.push(try decl.parseParamDecl(p));
            if (p.eat(.comma) == null) break;
        }
        _ = try p.expect(.r_paren);
        if (p.scratch.items.len == top) try p.warnAt(.invalid_parameter_list, first);
    }
    const params = try p.spanFrom(top);
    const ports = if (p.tokenTag(p.tok_i) == .l_paren) try parsePorts(p) else try p.spanFrom(top);
    _ = try p.expect(.semicolon);
    const items = try parseItems(p, .keyword_endmodule);
    _ = try p.expect(.keyword_endmodule);
    return p.addNode(.module_decl, kw, .{ .extra = try p.addExtra(Node.Module{
        .params_start = params.start,
        .params_end = params.end,
        .ports_start = ports.start,
        .ports_end = ports.end,
        .items_start = items.start,
        .items_end = items.end,
    }) });
}

/// Module items until `end`, `endmodule` or end of file, recovering at the
/// next item after a bad one.
pub fn parseItems(p: *Parse, end: Token.Tag) Error!Node.SubRange {
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    while (true) {
        const item_at = p.tok_i;
        const attributed = try p.skipAttributes();
        const t = p.tokenTag(p.tok_i);
        if (t == end or t == .eof or t == .keyword_endmodule) {
            if (attributed) try p.warnAt(.attribute_prefixes_nothing, item_at);
            break;
        }
        const before = p.tok_i;
        const item = parseItem(p) catch |e| switch (e) {
            error.OutOfMemory => return e,
            error.ParseError => {
                p.recoverItem(before);
                continue;
            },
        };
        if (item) |n| try p.push(n);
        assert(p.tok_i > before);
    }
    return p.spanFrom(top);
}

/// Syntax 6-8 `generate_block ::= module_or_generate_item | begin
/// [ : name ] { module_or_generate_item } end`; a lone `;` is a `null_stmt`.
pub fn parseGenerateBlock(p: *Parse) Error!Node.Index {
    try p.enter();
    defer p.leave();
    const tok = p.tok_i;
    if (p.eat(.semicolon) != null) return p.addNode(.null_stmt, tok, .{ .none = {} });
    if (p.eat(.keyword_begin) != null) {
        if (p.eat(.colon) != null) _ = try p.expectIdent();
        const items = try parseItems(p, .keyword_end);
        _ = try p.expect(.keyword_end);
        return p.addNode(.generate_block, tok, .{ .extra_range = items });
    }
    _ = try p.skipAttributes();
    const at = p.tok_i;
    return try parseItem(p) orelse p.addNode(.null_stmt, at, .{ .none = {} });
}

/// A.4.1 `# ( list_of_parameter_assignments )` after the `#`: ordered
/// expressions or `named_param`s, one arm only, at least one.
pub fn parseParamValues(p: *Parse) Error!Node.SubRange {
    _ = try p.expect(.l_paren);
    const first = p.tok_i;
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    var named: ?bool = null;
    if (p.tokenTag(p.tok_i) != .r_paren) while (true) {
        const dot = p.tok_i;
        const is_named = p.eat(.period) != null;
        if (named) |n| if (n != is_named) try p.warnAt(.invalid_parameter_list, dot);
        named = is_named;
        if (is_named) {
            // §9.18 Example 1: `.$mfactor(2)`.
            if (p.eat(.system_identifier) == null) _ = try p.expectIdent();
            _ = try p.expect(.l_paren);
            const value: Node.OptionalIndex = if (p.tokenTag(p.tok_i) == .r_paren) .none else (try expr.parseMinTypMax(p)).toOptional();
            _ = try p.expect(.r_paren);
            try p.push(try p.addNode(.named_param, dot, .{ .opt_node = value }));
        } else try p.push(try expr.parseExpr(p));
        if (p.eat(.comma) == null) break;
    };
    _ = try p.expect(.r_paren);
    if (p.scratch.items.len == top) try p.warnAt(.invalid_parameter_list, first);
    return p.spanFrom(top);
}

// ---- private ----

/// A.1.3 `list_of_ports` or `list_of_port_declarations`: null ports,
/// `.name ( expr )`, port expressions, or `port_decl` groups. A port
/// declaration after a plain port is `invalid_port_declaration`.
fn parsePorts(p: *Parse) Error!Node.SubRange {
    _ = try p.expect(.l_paren);
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    if (p.eat(.r_paren) != null) return p.spanFrom(top);
    var plain = false;
    var ansi = false;
    while (true) {
        _ = try p.skipAttributes();
        const tok = p.tok_i;
        switch (p.tokenTag(tok)) {
            .keyword_input, .keyword_output, .keyword_inout => {
                if (plain) try p.warn(.invalid_port_declaration);
                ansi = true;
                try p.push(try decl.parsePortDecl(p, .header));
            },
            .comma, .r_paren => {
                plain = plain or !ansi;
                try p.push(try p.addNode(.port, tok, .{ .opt_node = .none }));
            },
            .period => {
                plain = plain or !ansi;
                p.tok_i += 1;
                _ = try p.expectIdent();
                _ = try p.expect(.l_paren);
                const e: Node.OptionalIndex = if (p.tokenTag(p.tok_i) == .r_paren) .none else (try portExpr(p)).toOptional();
                _ = try p.expect(.r_paren);
                try p.push(try p.addNode(.named_port, tok, .{ .opt_node = e }));
            },
            else => {
                plain = plain or !ansi;
                try p.push(try p.addNode(.port, tok, .{ .opt_node = (try portExpr(p)).toOptional() }));
            },
        }
        if (p.eat(.comma) == null) break;
    }
    _ = try p.expect(.r_paren);
    return p.spanFrom(top);
}

/// A.1.3 `port_expression ::= port_reference | { port_reference {, ...} }`,
/// `port_reference ::= name [ [ constant_range_expression ] ]`.
fn portExpr(p: *Parse) Error!Node.Index {
    const lb = p.tok_i;
    if (p.eat(.l_brace) == null) return portRef(p);
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    while (true) {
        try p.push(try portRef(p));
        if (p.eat(.comma) == null) break;
    }
    _ = try p.expect(.r_brace);
    return p.addNode(.concat, lb, .{ .extra_range = try p.spanFrom(top) });
}

fn portRef(p: *Parse) Error!Node.Index {
    const name = try p.expectIdent();
    const id = try p.addNode(.identifier, name, .{ .none = {} });
    return if (p.tokenTag(p.tok_i) == .l_bracket) expr.parseSelect(p, id) else id;
}

/// One A.1.4 module item, or null for a nested module definition skipped
/// whole (§6.2.2: modules do not nest).
fn parseItem(p: *Parse) Error!?Node.Index {
    const tok = p.tok_i;
    // Under a 1364 language, a Verilog-AMS word followed by a name or a `#`
    // is a name opening an instance or a declaration (annex B of 1364
    // reserves none of them); otherwise it is a Verilog-AMS item, refused.
    const vams = p.vamsWordUnder1364(tok);
    const freed = vams and (p.identLike(tok + 1) or p.peek(1) == .hash);
    if (vams and !freed) try p.warn(.vams_construct_under_1364);
    const tag: Token.Tag = if (freed) .identifier else p.tokenTag(tok);
    return switch (tag) {
        .directive_begin_keywords, .directive_end_keywords, .directive_resetall, .directive_default_nettype, .directive_unconnected_drive, .directive_nounconnected_drive, .directive_default_transition => p.fail(.directive_inside_design_element),
        .keyword_for, .keyword_if, .keyword_case => {
            p.gen_depth += 1;
            defer p.gen_depth -= 1;
            return switch (tag) {
                .keyword_for => try stmt.parseFor(p, true),
                .keyword_if => try stmt.parseIf(p, true),
                else => try stmt.parseCase(p, true),
            };
        },
        .keyword_begin => p.fail(.begin_at_module_scope),
        .keyword_parameter, .keyword_localparam => {
            if (p.gen_depth > 0 and tag == .keyword_parameter) return p.fail(.not_a_generate_item);
            return try semi(p, try decl.parseParamDecl(p));
        },
        .keyword_specparam => {
            if (p.gen_depth > 0) return p.fail(.not_a_generate_item);
            return try semi(p, try decl.parseParamDecl(p));
        },
        .keyword_defparam => try parseDefparam(p),
        .keyword_aliasparam => try decl.parseAliasparam(p),
        .keyword_integer, .keyword_real, .keyword_string, .keyword_realtime, .keyword_time, .keyword_reg => try semi(p, try decl.parseVarDecl(p)),
        .keyword_genvar, .keyword_event => try decl.parseNameList(p),
        .keyword_branch => try decl.parseBranch(p),
        .keyword_input, .keyword_output, .keyword_inout => {
            if (p.gen_depth > 0) return p.fail(.not_a_generate_item);
            return try decl.parsePortDecl(p, .body);
        },
        .keyword_ground, .keyword_wreal, .keyword_wire, .keyword_tri, .keyword_tri0, .keyword_tri1, .keyword_triand, .keyword_trior, .keyword_trireg, .keyword_wand, .keyword_wor, .keyword_uwire, .keyword_supply0, .keyword_supply1 => try decl.parseNetDecl(p),
        .keyword_assign => try decl.parseContinuousAssign(p),
        .keyword_and, .keyword_nand, .keyword_or, .keyword_nor, .keyword_xor, .keyword_xnor, .keyword_buf, .keyword_not, .keyword_bufif0, .keyword_bufif1, .keyword_notif0, .keyword_notif1, .keyword_tran, .keyword_rtran, .keyword_tranif0, .keyword_tranif1, .keyword_rtranif0, .keyword_rtranif1, .keyword_cmos, .keyword_rcmos, .keyword_nmos, .keyword_pmos, .keyword_rnmos, .keyword_rpmos, .keyword_pullup, .keyword_pulldown => try prim.parseGates(p),
        .keyword_initial, .keyword_always => {
            p.tok_i += 1;
            // A.6.2 `initial_construct ::= initial statement`, no null one.
            if (p.tokenTag(p.tok_i) == .semicolon) try p.warn(.null_statement);
            const outer = p.discrete;
            p.discrete = true;
            defer p.discrete = outer;
            const body = try stmt.parseStmtIn(p, .analog);
            return try p.addNode(if (tag == .keyword_initial) .initial else .always, tok, .{ .node = body });
        },
        .keyword_analog => {
            if (p.peek(1) == .keyword_function) return try function.parseFunction(p);
            p.tok_i += 1;
            const node_tag: Node.Tag = if (p.eat(.keyword_initial) != null) .analog_initial else .analog;
            return try p.addNode(node_tag, tok, .{ .node = try stmt.parseStmtIn(p, .analog) });
        },
        .keyword_function, .keyword_task => try function.parseFunction(p),
        .keyword_generate => {
            if (p.gen_depth > 0) try p.warn(.not_a_generate_item);
            p.tok_i += 1;
            p.gen_depth += 1;
            defer p.gen_depth -= 1;
            try p.enter();
            defer p.leave();
            const items = try parseItems(p, .keyword_endgenerate);
            _ = try p.expect(.keyword_endgenerate);
            return try p.addNode(.generate_region, tok, .{ .extra_range = items });
        },
        .keyword_specify => {
            if (p.gen_depth > 0) try p.warn(.not_a_generate_item);
            return try prim.parseSpecify(p);
        },
        .keyword_module, .keyword_macromodule, .keyword_connectmodule => {
            try p.warn(.nested_module);
            var depth: u32 = 0;
            while (true) : (p.tok_i += 1) switch (p.tokenTag(p.tok_i)) {
                .eof => return null,
                .keyword_module, .keyword_macromodule, .keyword_connectmodule => depth += 1,
                .keyword_endmodule => {
                    depth -= 1;
                    if (depth == 0) {
                        p.tok_i += 1;
                        return null;
                    }
                },
                else => {},
            };
        },
        .identifier, .escaped_identifier => try parseIdentItem(p),
        else => p.fail(.expected_module_item),
    };
}

/// An item opened by a name: a module instantiation (`m #(`, or `m name (`
/// / `m name [`), a UDP instantiation (`u #d`, `u (`), or a net
/// declaration with a discipline (`d name`, `d [`, `d $root.`).
fn parseIdentItem(p: *Parse) Error!Node.Index {
    if ((p.peek(1) == .hash and p.peek(2) == .l_paren) or
        (p.identLike(p.tok_i + 1) and (p.peek(2) == .l_paren or p.peek(2) == .l_bracket)))
        return parseInstantiation(p);
    if (p.peek(1) == .hash or p.peek(1) == .l_paren) return udp.parseUdpInst(p);
    const rooted = p.peek(1) == .system_identifier and p.peek(2) == .period and std.mem.eql(u8, p.tokenText(p.tok_i + 1), "$root");
    if (p.identLike(p.tok_i + 1) or p.peek(1) == .l_bracket or rooted) return decl.parseNetDecl(p);
    return p.fail(.expected_module_item);
}

/// A.4.1 `module [ #( params ) ] instance {, instance} ;`, an instance
/// `name [ range ] ( [ conns ] )`, a connection ordered (`[expr]`) or named
/// (`.port ( [expr] )`).
fn parseInstantiation(p: *Parse) Error!Node.Index {
    const mod = p.tok_i;
    p.tok_i += 1;
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    const params = if (p.eat(.hash) != null) try parseParamValues(p) else try p.spanFrom(top);
    while (true) {
        const name = try p.expectIdent();
        const range: Node.OptionalIndex = if (p.tokenTag(p.tok_i) == .l_bracket) (try decl.parseRange(p)).toOptional() else .none;
        _ = try p.expect(.l_paren);
        const conns_top = p.scratch.items.len;
        if (p.tokenTag(p.tok_i) != .r_paren) while (true) {
            _ = try p.skipAttributes();
            const dot = p.tok_i;
            if (p.eat(.period) != null) {
                _ = try p.expectIdent();
                _ = try p.expect(.l_paren);
                const e: Node.OptionalIndex = if (p.tokenTag(p.tok_i) == .r_paren) .none else (try expr.parseExpr(p)).toOptional();
                _ = try p.expect(.r_paren);
                try p.push(try p.addNode(.named_port, dot, .{ .opt_node = e }));
            } else if (p.tokenTag(p.tok_i) == .comma or p.tokenTag(p.tok_i) == .r_paren) {
                try p.pushOpt(.none);
            } else try p.push(try expr.parseExpr(p));
            if (p.eat(.comma) == null) break;
        };
        _ = try p.expect(.r_paren);
        const conns = try p.spanFrom(conns_top);
        const extra = try p.addExtra(Node.Instance{ .range = range, .conns_start = conns.start, .conns_end = conns.end });
        try p.push(try p.addNode(.instance, name, .{ .extra = extra }));
        if (p.eat(.comma) == null) break;
    }
    _ = try p.expect(.semicolon);
    const items = try p.spanFrom(top);
    return p.addNode(.module_instantiation, mod, .{ .extra = try p.addExtra(Node.Instantiation{
        .params_start = params.start,
        .params_end = params.end,
        .items_start = items.start,
        .items_end = items.end,
    }) });
}

/// §6.3.1 `defparam path = mintypmax {, ...} ;`.
fn parseDefparam(p: *Parse) Error!Node.Index {
    const kw = p.tok_i;
    p.tok_i += 1;
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    while (true) {
        const path = try stmt.parseHierName(p);
        const eq = try p.expect(.equal);
        try p.push(try p.addNode(.net_assign, eq, .{ .node_and_node = .{ path, try expr.parseMinTypMax(p) } }));
        if (p.eat(.comma) == null) break;
    }
    _ = try p.expect(.semicolon);
    return p.addNode(.defparam, kw, .{ .extra_range = try p.spanFrom(top) });
}

fn semi(p: *Parse, node: Node.Index) Error!Node.Index {
    _ = try p.expect(.semicolon);
    return node;
}
