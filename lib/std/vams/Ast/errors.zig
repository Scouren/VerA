//! A tree's parse errors as diagnostics (Zig's `Ast.renderError`): each
//! `Ast.Error` becomes one row of a `Diag.Wip`, its code, headline, caret
//! text and fix-it the ones the old parser reported for the same refusal
//! (`zig build diff-parse` holds them to it). Locations are byte ranges of
//! the parsed text in file `.root`; the caller moves them to the original
//! files, as it does AstGen's.
//!
//! Cites: VAMS-2023 annex A (the grammar each refusal names), §2.6 (number
//! literals), §2.7 (strings), §10.6 (keyword sets).
//!
//! Contents:
//! - `pub fn report(tree: *const Ast, w: *Diag.Wip) Allocator.Error!void`
//! - `pub fn code(tag: Ast.Error.Tag) Diag.Code`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Ast = @import("../Ast.zig");
const Diag = @import("../Diag.zig");
const Token = @import("../tokenizer.zig").Token;
const sites = @import("sites.zig");
const found = sites.found;
const desc = sites.desc;

const Runaway = enum { none, unterminated, line_continuation };

/// Every error of `tree`, in the order the parser raised them, into `w`.
pub fn report(tree: *const Ast, w: *Diag.Wip) Allocator.Error!void {
    for (tree.errors) |e| try one(tree, e, w);
}

/// The code a refusal is reported under.
pub fn code(tag: Ast.Error.Tag) Diag.Code {
    return switch (tag) {
        .expected_token => .E0207,
        .expected_identifier => .E0208,
        .expected_expr => .E0209,
        .expected_statement => .E0214,
        .expected_module_item, .nested_module => .E0240,
        .expected_description => .E0201,
        .invalid_number => .E0133,
        .invalid_string_escape => .E0148,
        .unknown_keyword_set => .E0135,
        .unmatched_end_keywords => .E0136,
        .directive_inside_design_element => .E0202,
        .null_statement => .E0219,
        .outside_verilog_a => .E0250,
        .scale_factor_in_delay => .E0247,
        .empty_step_event_list => .E0220,
        .begin_at_module_scope => .E0221,
        .invalid_function => .E0226,
        .not_a_generate_item => .E0228,
        .library_text_in_source => .E0232,
        .invalid_udp => .E0233,
        .invalid_specify_item, .specify_outside_module => .E0245,
        .invalid_config_rule => .E0243,
        .invalid_parameter_list => .E0246,
        .digital_statement_in_analog => .E0249,
        .driver_update_outside_connect_module => .E0818,
        .nesting_too_deep => .E0241,
        // else: the shapes the old parser reported as "unexpected token"
        // with a reason; finer codes are diff-parse's debt (parse.xfail).
        else => .E0207,
    };
}

// ---- private ----

fn one(tree: *const Ast, e: Ast.Error, w: *Diag.Wip) Allocator.Error!void {
    const tok = e.token;
    const at = tree.tokenStart(tok);
    const loc: Diag.Loc = .{ .file = .root, .start = at, .end = at + @as(u32, @intCast(tree.tokenSlice(tok).len)) };
    const open = if (tree.tokenTag(tok) == .invalid) runaway(tree.source, at, tree.tokenSlice(tok)) else .none;
    if (open != .none) {
        var b = w.build(.parse, .E0138, loc);
        b.point("this literal is still open at the end of the line", .{});
        if (open == .line_continuation) b.note("the trailing `\\` is an IEEE 1800 SystemVerilog continuation (§5.9); Verilog-AMS derives from IEEE 1364-2005, which has no such escape", .{});
        b.help("keep the literal on one line — `\\n` inside it is what breaks the output", .{});
        return b.emit();
    }
    const text = tree.tokenSlice(tok);
    // An attribute that prefixes nothing: at its `(*`, naming what follows.
    if (e.tag == .attribute_prefixes_nothing) {
        const next = afterAttribute(tree, tok);
        var b = w.build(.parse, .E0207, loc);
        b.msg("found {s}: an attribute instance prefixes nothing", .{found(tree, next)});
        return b.emit();
    }
    // IEEE 1364-2005 §19.6: `resetall is its own code inside a module.
    if (e.tag == .directive_inside_design_element and std.mem.eql(u8, text, "`resetall")) {
        var b = w.build(.parse, .E0236, loc);
        return b.emit();
    }
    if (try refined(tree, e, loc, w)) return;
    var b = w.build(.parse, code(e.tag), loc);
    switch (e.tag) {
        .expected_token => {
            const want = e.extra.expected_tag;
            b.msg("found {s}", .{found(tree, tok)});
            b.point("expected {s}", .{desc(want)});
            if (terminator(want)) {
                const end = endOfPrev(tree, tok);
                b.suggest(.{ .loc = .{ .file = .root, .start = end, .end = end }, .replacement = want.lexeme().? }, "insert `{s}` after the previous {s}", .{ want.lexeme().?, if (want == .semicolon) "statement" else "item" });
            }
        },
        .expected_identifier, .expected_expr, .expected_statement, .expected_module_item, .nested_module => b.msg("found {s}", .{found(tree, tok)}),
        .expected_description => b.msg("`{s}`", .{found(tree, tok)}),
        .invalid_number => b.msg("`{s}`", .{text}),
        .scale_factor_in_delay => b.msg("`{s}` in a digital delay; use decimal or scientific notation in the module's time units", .{text}),
        .directive_inside_design_element => b.msg("`{s} inside a {s}", .{ text[@min(1, text.len)..], enclosing(tree, tok) }),
        .unknown_keyword_set => b.msg("`{s}`", .{std.mem.trim(u8, text, "\"")}),
        .begin_at_module_scope => b.msg("found {s}", .{found(tree, tok)}),
        .library_text_in_source => b.msg("`{s}` is a library_description, and this file is source_text", .{std.mem.trimStart(u8, text, "`")}),
        .specify_outside_module => b.msg("a specify block outside a module (§14.1)", .{}),
        .outside_verilog_a => b.msg("`{s}` under --sim=verilogA", .{text}),
        .driver_update_outside_connect_module => {
            b.msg("`driver_update` in a module that is not a connect module", .{});
            b.note("§9.22: \"Driver access functions can only be called from connect modules\", and driver_update \"is used in combination with the driver access functions\"", .{});
        },
        .unmatched_end_keywords, .null_statement, .not_a_generate_item, .digital_statement_in_analog => {},
        // else: a refusal whose old text names the site; diff-parse's debt.
        else => b.msg("{s}", .{@tagName(e.tag)}),
    }
    try b.emit();
}

/// The refusals whose old code or text the error's token and its
/// neighbours decide; true when it emitted one.
fn refined(tree: *const Ast, e: Ast.Error, loc: Diag.Loc, w: *Diag.Wip) Allocator.Error!bool {
    if (e.site != .generic) {
        try sites.report(tree, e, loc, w);
        return true;
    }
    const tok = e.token;
    const tag = tree.tokenTag(tok);
    const prev: Token.Tag = if (tok == 0) .eof else tree.tokenTag(tok - 1);
    var b: Diag.Wip.Builder = switch (e.tag) {
        // A.6.4: each digital statement form has its own code.
        .digital_statement_in_analog => switch (tag) {
            .hash => w.build(.parse, .E0254, loc),
            .keyword_wait => w.build(.parse, .E0255, loc),
            .keyword_forever => w.build(.parse, .E0256, loc),
            .keyword_assign, .keyword_deassign, .keyword_force, .keyword_release => blk: {
                var x = w.build(.parse, .E0258, loc);
                x.msg("`{s}`", .{tree.tokenSlice(tok)});
                break :blk x;
            },
            else => return false, // else: the fork-join and the rest keep E0249
        },
        // Syntax 6-8: a parameter declaration has its own code.
        .not_a_generate_item => if (tag == .keyword_parameter or tag == .keyword_localparam) w.build(.parse, .E0229, loc) else return false,
        // An initial or always construct takes a statement: E0209.
        .null_statement => if (prev == .keyword_initial or prev == .keyword_always) blk: {
            var x = w.build(.parse, .E0209, loc);
            x.msg("found `;`: an {s} construct takes a statement, not a null one", .{if (prev == .keyword_always) "always" else "initial"});
            break :blk x;
        } else return false,
        // A.1.4: a keyword with no dedicated tag in module item position.
        .expected_module_item => if (Token.Tag.isKeyword(tag) and found(tree, tok)[0] != '`') blk: {
            var x = w.build(.parse, .E0205, loc);
            x.msg("found {s}", .{found(tree, tok)});
            break :blk x;
        } else return false,
        // A.6.5: `initial_step()`/`final_step()` names the event.
        .empty_step_event_list => blk: {
            var k = tok;
            // Bounded by three tokens: the keyword, `(`, `)`.
            while (k > 0 and tok - k < 3 and tree.tokenTag(k) != .keyword_initial_step and tree.tokenTag(k) != .keyword_final_step) k -= 1;
            var x = w.build(.parse, .E0220, loc);
            x.msg("after `{s}`", .{tree.tokenSlice(k)});
            break :blk x;
        },
        // §2.6: a number the new tokenizer ends early (`4af`, `4'b101f`,
        // `8'`) is one bad literal to the old lexer, reported at its start
        // and underlining the old lexer's first token: the number token.
        .expected_token => if (tok > 0 and prev == .number_literal and tree.tokenStart(tok) == endOfPrev(tree, tok) and
            ((tag == .identifier and hexLetter(tree.tokenSlice(tok)[0]) and std.mem.findScalar(u8, tree.tokenSlice(tok - 1), '.') == null) or (tag == .invalid and tree.source[tree.tokenStart(tok)] == '\'')))
        blk: {
            const at = tree.tokenStart(tok - 1);
            const end = tree.tokenStart(tok) + @as(u32, @intCast(tree.tokenSlice(tok).len));
            var x = w.build(.parse, if (tag == .invalid) .E0131 else .E0133, .{ .file = .root, .start = at, .end = tree.tokenStart(tok) });
            x.msg("`{s}`", .{tree.source[at..end]});
            break :blk x;
        } else return false,
        // §2.7: at the escape above `\377`.
        .invalid_string_escape => blk: {
            const text = tree.tokenSlice(tok);
            var k: usize = 0;
            // Bounded by the token's length.
            const esc = while (k + 3 < text.len) : (k += 1) {
                if (text[k] == '\\' and std.ascii.isDigit(text[k + 1]) and text[k + 1] >= '4' and std.ascii.isDigit(text[k + 2]) and std.ascii.isDigit(text[k + 3])) break k;
            } else 0;
            const at = tree.tokenStart(tok) + @as(u32, @intCast(esc));
            var x = w.build(.parse, .E0148, .{ .file = .root, .start = at, .end = at + 4 });
            x.msg("`{s}`", .{text[esc..@min(text.len, esc + 4)]});
            break :blk x;
        },
        // §6.4.1: an empty paramset, a forbidden statement form, or an item
        // that begins no statement.
        .invalid_paramset => blk: {
            if (tag == .keyword_paramset) {
                var x = w.build(.parse, .E0297, loc);
                x.msg("paramset `{s}` declares no parameter, aliasparam or variable", .{tree.tokenSlice(tok + 1)});
                break :blk x;
            }
            const what: ?[]const u8 = switch (tag) {
                .angle_bracket_left_plus => "a contribution statement",
                .at_sign => "an event control",
                .keyword_begin => "a named block",
                .keyword_potential, .keyword_flow => "an access function",
                else => null, // else: no forbidden form, an item no statement begins
            };
            var x = w.build(.parse, if (what != null) .E0237 else .E0205, loc);
            if (what) |wh| x.msg("{s}: found {s}", .{ wh, found(tree, tok) }) else x.msg("found {s} in a paramset body", .{found(tree, tok)});
            break :blk x;
        },
        // A.1.3 / A.4.1.1: the parameter list's rule, by the token.
        .invalid_parameter_list => blk: {
            var x = w.build(.parse, .E0246, loc);
            const header = tok >= 4 and tree.tokenTag(tok - 1) == .l_paren and tree.tokenTag(tok - 2) == .hash and switch (tree.tokenTag(tok - 4)) {
                .keyword_module, .keyword_macromodule, .keyword_connectmodule => true,
                else => false,
            };
            x.msg("{s}", .{switch (tag) {
                .keyword_localparam => "a module parameter header requires `parameter`, not `localparam`",
                else => if (header) "an empty module parameter header has no parameter declaration" else "an empty parameter value assignment has no expression or named assignment",
            }});
            break :blk x;
        },
        // A.6.3: the declaration in an unnamed block.
        .decl_in_unnamed_block => blk: {
            var x = w.build(.parse, .E0290, loc);
            x.msg("found {s}", .{found(tree, tok)});
            break :blk x;
        },
        .forever_needs_statement => w.build(.parse, .E0296, loc),
        .invalid_delay_value => blk: {
            var x = w.build(.parse, .E0207, loc);
            x.msg("found {s}", .{found(tree, tok)});
            break :blk x;
        },
        .nested_attribute => blk: {
            var x = w.build(.parse, .E0357, loc);
            x.msg("the value contains an attribute instance", .{});
            x.note("§2.9: \"Nesting of attribute instances is disallowed\"", .{});
            break :blk x;
        },
        // A.8.5: reported at the literal, the token before the operator.
        .literal_assignment_target => blk: {
            const lit = tok - 1;
            const at = tree.tokenStart(lit);
            var x = w.build(.parse, .E0207, .{ .file = .root, .start = at, .end = at + @as(u32, @intCast(tree.tokenSlice(lit).len)) });
            x.msg("found {s}: an A.8.5 assignment target is a variable, never a literal", .{found(tree, lit)});
            break :blk x;
        },
        // §4.7.1: the token says which rule.
        .invalid_function => switch (tag) {
            .keyword_return => blk: {
                var x = w.build(.parse, .E0227, loc);
                x.help("write `return <expr>;`", .{});
                break :blk x;
            },
            .keyword_begin => blk: {
                const label = tok + 2;
                const at = tree.tokenStart(label);
                var x = w.build(.parse, .E0226, .{ .file = .root, .start = at, .end = at + @as(u32, @intCast(tree.tokenSlice(label).len)) });
                x.msg("`{s}`", .{tree.tokenSlice(label)});
                x.help("remove the label", .{});
                break :blk x;
            },
            else => blk: {
                var x = w.build(.parse, .E0224, loc);
                x.msg("`{s}` has an empty formal list", .{tree.tokenSlice(functionName(tree, tok))});
                break :blk x;
            },
        },
        // A.8.2: which argument of which function is empty.
        .empty_argument => blk: {
            var depth: u32 = 0;
            var commas: u32 = 0;
            var k = tok;
            // Bounded by `tok`: back to the call's `(`.
            while (k > 0) : (k -= 1) switch (tree.tokenTag(k - 1)) {
                .r_paren, .r_bracket, .r_brace => depth += 1,
                .l_paren, .l_bracket, .l_brace => if (depth == 0) break else {
                    depth -= 1;
                },
                .comma => commas += @intFromBool(depth == 0),
                else => {},
            };
            var x = w.build(.parse, .E0289, loc);
            x.msg("argument {d} of `{s}` is empty", .{ commas + 1, if (k >= 2) tree.tokenSlice(k - 2) else "" });
            break :blk x;
        },
        else => return false, // else: the generic rendering below
    };
    try b.emit();
    return true;
}

fn hexLetter(c: u8) bool {
    return (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// The name a function declaration starting at `first` declares: the
/// token before its `;` or `(` after `function`.
fn functionName(tree: *const Ast, first: Ast.TokenIndex) Ast.TokenIndex {
    var k = first;
    // Bounded by the token count: each turn moves one token on.
    while (tree.tokenTag(k) != .eof and tree.tokenTag(k) != .keyword_function) k += 1;
    while (tree.tokenTag(k) != .eof and tree.tokenTag(k) != .semicolon and tree.tokenTag(k) != .l_paren) k += 1;
    return if (k > first) k - 1 else first;
}

/// The design element a directive sits inside, by the nearest opening
/// keyword before `i`.
fn enclosing(tree: *const Ast, i: Ast.TokenIndex) []const u8 {
    var k = i;
    // Bounded by `i`: each turn moves one token back.
    while (k > 0) {
        k -= 1;
        switch (tree.tokenTag(k)) {
            .keyword_paramset => return "paramset",
            .keyword_module, .keyword_macromodule, .keyword_connectmodule => return "module",
            else => {},
        }
    }
    return "module";
}

fn terminator(tag: Token.Tag) bool {
    return switch (tag) {
        .semicolon, .comma, .r_paren, .r_bracket, .r_brace => true,
        else => false, // else: not a list or statement terminator
    };
}

/// Where the token before `i` ends: a missing terminator is typed there.
fn endOfPrev(tree: *const Ast, i: Ast.TokenIndex) u32 {
    if (i == 0) return tree.tokenStart(0);
    const p = i - 1;
    if (tree.tokenTag(p) == .eof) return tree.tokenStart(p);
    return tree.tokenStart(p) + @as(u32, @intCast(tree.tokenSlice(p).len));
}

/// §2.7: whether the `.invalid` token `text` at `at` is a string that runs
/// off its line, and whether a trailing `\` (IEEE 1800's continuation)
/// stopped it (the old lexer's `stringRunaway`).
fn runaway(source: []const u8, at: u32, text: []const u8) Runaway {
    assert(at + text.len <= source.len);
    if (text.len == 0 or text[0] != '"') return .none;
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '"') return .none;
        if (text[i] != '\\') continue;
        if (i + 1 == text.len) return if (at + text.len < source.len) .line_continuation else .unterminated;
        i += 1;
    }
    return .unterminated;
}

/// The token after the attribute instance that opens at `i` (`(*`): past
/// its `*)`, or the end of file.
fn afterAttribute(tree: *const Ast, i: Ast.TokenIndex) Ast.TokenIndex {
    var k = i;
    // Bounded by the token count: each turn moves one token on.
    while (tree.tokenTag(k) != .eof) : (k += 1) {
        if (tree.tokenTag(k) == .asterisk_r_paren) return k + 1;
    }
    return k;
}
