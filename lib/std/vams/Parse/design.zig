//! The other design elements (A.1.2's descriptions besides modules and
//! primitives): natures and disciplines (A.1.6, A.1.7), paramsets (A.1.9),
//! connectrules (A.1.8), configurations (A.1.5), and A.1.1's library text,
//! which source_text does not derive: tokens in, one description node out.
//! Cites: VAMS-2023 §3.6.1, §3.6.2, §6.4, §6.4.1, §6.4.3, §7.7, §10.6,
//! A.1.1, A.1.5-A.1.9; IEEE 1364-2005 §13.3.1.
//!
//! Contents:
//! - `pub fn parseNature(p: *Parse) Error!Node.Index`
//! - `pub fn parseDiscipline(p: *Parse) Error!Node.Index`
//! - `pub fn parseParamset(p: *Parse) Error!Node.Index`
//! - `pub fn parseConnectRules(p: *Parse) Error!Node.Index`
//! - `pub fn parseConfig(p: *Parse) Error!Node.Index`
//! - `pub fn parseLibraryDecl(p: *Parse) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("../Ast.zig");
const Parse = @import("../Parse.zig");
const expr = @import("expr.zig");
const stmt = @import("stmt.zig");
const decl = @import("decl.zig");
const module = @import("module.zig");
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const Error = Parse.Error;

/// A.1.6 `nature name [: parent [. potential|flow]] [;] { attr } endnature`.
pub fn parseNature(p: *Parse) Error!Node.Index {
    assert(p.tokenTag(p.tok_i) == .keyword_nature);
    const kw = p.tok_i;
    p.tok_i += 1;
    _ = try p.expectIdent();
    if (p.eat(.colon) != null) {
        _ = try p.expectIdent();
        if (p.eat(.period) != null) {
            if (p.eat(.keyword_potential) == null and p.eat(.keyword_flow) == null) return p.fail(.expected_identifier);
        }
    }
    _ = p.eat(.semicolon);
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    while (p.tokenTag(p.tok_i) != .keyword_endnature and p.tokenTag(p.tok_i) != .eof) try p.push(try natureAttr(p));
    _ = try p.expect(.keyword_endnature);
    return p.addNode(.nature_decl, kw, .{ .extra_range = try p.spanFrom(top) });
}

/// A.1.7 `discipline name [;] { item } enddiscipline`: nature bindings,
/// attribute overrides, `domain`, and (§3.6.2.7) user attributes.
pub fn parseDiscipline(p: *Parse) Error!Node.Index {
    assert(p.tokenTag(p.tok_i) == .keyword_discipline);
    const kw = p.tok_i;
    p.tok_i += 1;
    _ = try p.expectIdent();
    _ = p.eat(.semicolon);
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    while (p.tokenTag(p.tok_i) != .keyword_enddiscipline and p.tokenTag(p.tok_i) != .eof) {
        const tok = p.tok_i;
        const item = switch (p.tokenTag(tok)) {
            .keyword_potential, .keyword_flow => item: {
                p.tok_i += 1;
                if (p.eat(.period) != null) break :item try p.addNode(.discipline_override, tok, .{ .node = try natureAttr(p) });
                const nature = try p.expectIdent();
                _ = try p.expect(.semicolon);
                break :item try p.addNode(.discipline_binding, tok, .{ .token = nature });
            },
            .keyword_domain => item: {
                p.tok_i += 1;
                const domain = p.eat(.keyword_continuous) orelse p.eat(.keyword_discrete) orelse return p.fail(.expected_identifier);
                _ = try p.expect(.semicolon);
                break :item try p.addNode(.discipline_domain, tok, .{ .token = domain });
            },
            .identifier, .escaped_identifier => if (p.peek(1) == .equal) try natureAttr(p) else return p.fail(.expected_module_item),
            else => return p.fail(.expected_module_item),
        };
        try p.push(item);
    }
    _ = try p.expect(.keyword_enddiscipline);
    return p.addNode(.discipline_decl, kw, .{ .extra_range = try p.spanFrom(top) });
}

/// A.1.9 `paramset name module ; items endparamset`: declarations (at
/// least one), `.name = expr ;` overrides and statements. §6.4.1: a
/// statement is an assignment or a control statement around them, with no
/// contribution, event control, named block or `potential`/`flow` access
/// (an access function by any other name is Sema's to find).
pub fn parseParamset(p: *Parse) Error!Node.Index {
    assert(p.tokenTag(p.tok_i) == .keyword_paramset);
    const kw = p.tok_i;
    p.tok_i += 1;
    _ = try p.expectIdent();
    _ = try p.expectIdent();
    _ = try p.expect(.semicolon);
    const errors_before = p.errors.items.len;
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    var decls: u32 = 0;
    while (true) {
        const item_at = p.tok_i;
        const attributed = try p.skipAttributes();
        const tok = p.tok_i;
        switch (p.tokenTag(tok)) {
            .eof, .keyword_endparamset => {
                if (attributed) try p.warnAt(.attribute_prefixes_nothing, item_at);
                break;
            },
            .directive_begin_keywords, .directive_end_keywords => return p.fail(.directive_inside_design_element),
            .keyword_parameter, .keyword_localparam, .keyword_integer, .keyword_real, .keyword_string, .keyword_realtime, .keyword_time => {
                decls += 1;
                try p.push(try decl.parseBlockDecl(p));
            },
            .keyword_aliasparam => {
                decls += 1;
                try p.push(try decl.parseAliasparam(p));
            },
            .period => {
                p.tok_i += 1;
                if (p.eat(.system_identifier) == null) _ = try p.expectIdent();
                _ = try p.expect(.equal);
                const value = try expr.parseExpr(p);
                _ = try p.expect(.semicolon);
                try p.push(try p.addNode(.paramset_override, tok, .{ .node = value }));
            },
            else => try paramsetStatement(p),
        }
    }
    if (decls == 0 and p.errors.items.len == errors_before) try p.warnAt(.invalid_paramset, kw);
    _ = try p.expect(.keyword_endparamset);
    return p.addNode(.paramset_decl, kw, .{ .extra_range = try p.spanFrom(top) });
}

/// A.1.8 `connectrules name ; { connect_insertion | connect_resolution }
/// endconnectrules`.
pub fn parseConnectRules(p: *Parse) Error!Node.Index {
    assert(p.tokenTag(p.tok_i) == .keyword_connectrules);
    const kw = p.tok_i;
    p.tok_i += 1;
    _ = try p.expectIdent();
    _ = try p.expect(.semicolon);
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    while (p.eat(.keyword_endconnectrules) == null) {
        if (p.tokenTag(p.tok_i) == .directive_begin_keywords or p.tokenTag(p.tok_i) == .directive_end_keywords) return p.fail(.directive_inside_design_element);
        const item = try p.expect(.keyword_connect);
        _ = try p.expectIdent();
        if (p.tokenTag(p.tok_i) == .comma or p.tokenTag(p.tok_i) == .keyword_resolveto) {
            while (p.eat(.comma) != null) _ = try p.expectIdent();
            const to = try p.expect(.keyword_resolveto);
            if (p.eat(.keyword_exclude) == null) _ = try p.expectIdent();
            _ = try p.expect(.semicolon);
            try p.push(try p.addNode(.connect_resolution, item, .{ .token = to }));
            continue;
        }
        _ = p.eat(.keyword_merged) orelse p.eat(.keyword_split);
        const params = if (p.eat(.hash) != null) try module.parseParamValues(p) else try p.listToSpan(&.{});
        var overrides: Ast.OptionalTokenIndex = .none;
        if (p.tokenTag(p.tok_i) != .semicolon) {
            overrides = .fromOptional(p.tok_i);
            // A.1.8 connect_port_overrides: none/none, input/output,
            // output/input, inout/inout.
            const a_dir = p.tokenTag(p.tok_i);
            const directed = a_dir == .keyword_input or a_dir == .keyword_output or a_dir == .keyword_inout;
            if (directed) p.tok_i += 1;
            _ = try p.expectIdent();
            if (!directed and p.tokenTag(p.tok_i) == .semicolon) return p.failAt(.expected_identifier, p.tok_i - 1);
            _ = try p.expect(.comma);
            if (directed) _ = try p.expect(switch (a_dir) {
                .keyword_input => .keyword_output,
                .keyword_output => .keyword_input,
                else => .keyword_inout,
            });
            _ = try p.expectIdent();
        }
        _ = try p.expect(.semicolon);
        try p.push(try p.addNode(.connect_insertion, item, .{ .extra = try p.addExtra(Node.Insertion{ .params_start = params.start, .params_end = params.end, .overrides = overrides }) }));
    }
    return p.addNode(.connectrules_decl, kw, .{ .extra_range = try p.spanFrom(top) });
}

/// A.1.5 `config name ; design { [lib.]cell } ; { rule } endconfig`, a
/// rule `default liblist ... ;`, `instance path liblist|use ... ;` or
/// `cell [lib.]cell liblist|use ... ;`. A library-qualified cell takes no
/// liblist (§13.3.1.4); at most one default (§13.3.1.2).
pub fn parseConfig(p: *Parse) Error!Node.Index {
    assert(p.tokenTag(p.tok_i) == .keyword_config);
    const kw = p.tok_i;
    p.tok_i += 1;
    _ = try p.expectIdent();
    _ = try p.expect(.semicolon);
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    const design = p.eat(.keyword_design) orelse return p.fail(.invalid_config_rule);
    while (p.tokenTag(p.tok_i) != .semicolon) _ = try libCell(p);
    try p.push(try p.addNode(.config_design, design, .{ .token = p.tok_i }));
    p.tok_i += 1;
    var defaults: u32 = 0;
    while (p.eat(.keyword_endconfig) == null) {
        const rule = p.tok_i;
        var qualified = false;
        switch (p.tokenTag(rule)) {
            .keyword_default => {
                p.tok_i += 1;
                defaults += 1;
                if (defaults > 1) try p.warnAt(.invalid_config_rule, rule);
            },
            .keyword_instance => {
                p.tok_i += 1;
                _ = try stmt.parseHierName(p);
            },
            .keyword_cell => {
                p.tok_i += 1;
                qualified = try libCell(p);
            },
            else => return p.fail(.invalid_config_rule),
        }
        if (p.eat(.keyword_liblist) != null) {
            if (qualified) try p.warnAt(.invalid_config_rule, rule);
            while (p.tokenTag(p.tok_i) != .semicolon) _ = try p.expectIdent();
        } else if (p.tokenTag(rule) != .keyword_default and p.eat(.keyword_use) != null) {
            _ = try libCell(p);
            if (p.eat(.colon) != null) _ = try p.expect(.keyword_config);
        } else return p.fail(.invalid_config_rule);
        _ = try p.expect(.semicolon);
        try p.push(try p.addNode(.config_rule, rule, .{ .token = p.tok_i - 1 }));
    }
    return p.addNode(.config_decl, kw, .{ .extra_range = try p.spanFrom(top) });
}

/// A.1.1 `library name paths [-incdir paths] ;` or `include path ;`:
/// library_text, which no source_text derives, so always
/// `library_text_in_source` once parsed.
pub fn parseLibraryDecl(p: *Parse) Error!void {
    assert(p.tokenTag(p.tok_i) == .keyword_library or p.tokenTag(p.tok_i) == .keyword_include);
    const kw = p.tok_i;
    const library = p.tokenTag(kw) == .keyword_library;
    p.tok_i += 1;
    if (library) _ = try p.expectIdent();
    while (true) {
        _ = try p.expect(.string_literal);
        if (p.eat(.comma) == null) break;
    }
    if (library and p.eat(.minus) != null) {
        _ = try p.expect(.keyword_incdir);
        while (true) {
            _ = try p.expect(.string_literal);
            if (p.eat(.comma) == null) break;
        }
    }
    _ = try p.expect(.semicolon);
    return p.failAt(.library_text_in_source, kw);
}

// ---- private ----

/// A.1.6 `name = expr ;`, the name an identifier or one of §3.6.1.2's
/// attribute keywords.
fn natureAttr(p: *Parse) Error!Node.Index {
    const name = p.tok_i;
    switch (p.tokenTag(name)) {
        .identifier, .escaped_identifier, .keyword_abstol, .keyword_access, .keyword_units, .keyword_ddt_nature, .keyword_idt_nature => p.tok_i += 1,
        else => return p.fail(.expected_identifier),
    }
    _ = try p.expect(.equal);
    const value = try expr.parseExpr(p);
    _ = try p.expect(.semicolon);
    return p.addNode(.nature_attr, name, .{ .node = value });
}

/// `[lib .] cell`; returns whether a library was named.
fn libCell(p: *Parse) Error!bool {
    _ = try p.expectIdent();
    if (p.eat(.period) == null) return false;
    _ = try p.expectIdent();
    return true;
}

/// One A.1.9 paramset statement: a variable assignment or a control
/// statement over them, parsed with §6.4.3's `.name` primary. Any other
/// opener is `invalid_paramset`, skipped to its end.
fn paramsetStatement(p: *Parse) Error!void {
    const start = p.tok_i;
    const legal = (p.identLike(start) and (p.peek(1) == .equal or p.peek(1) == .l_bracket)) or switch (p.tokenTag(start)) {
        .keyword_if, .keyword_case, .keyword_for, .keyword_while, .keyword_repeat, .keyword_begin => true,
        else => false,
    };
    if (!legal) {
        try p.warn(.invalid_paramset);
        p.recoverItem(start);
        return;
    }
    p.in_paramset = true;
    defer p.in_paramset = false;
    const s = stmt.parseStmt(p) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.ParseError => {
            p.recoverItem(start);
            return;
        },
    };
    try p.push(s);
    for (start..p.tok_i) |i| {
        const tok: TokenIndex = @intCast(i);
        const forbidden = switch (p.tokenTag(tok)) {
            .angle_bracket_left_plus, .at_sign => true,
            .keyword_begin => p.tokenTag(tok + 1) == .colon,
            .keyword_potential, .keyword_flow => p.tokenTag(tok + 1) == .l_paren,
            else => false,
        };
        if (forbidden) try p.warnAt(.invalid_paramset, tok);
    }
}
