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

/// The old lexer's dedicated keyword tags: `found` quotes these and prints
/// any other keyword's text bare (it lexed them all as one reserved tag).
const quoted_keywords = std.StaticStringMap(void).initComptime(kv: {
    const words = [_][]const u8{
        "module",      "macromodule", "connectmodule", "endmodule",       "paramset",        "endparamset",   "function",      "endfunction",
        "analog",      "initial",     "always",        "assign",          "begin",           "end",           "wait",          "generate",
        "endgenerate", "defparam",    "connectrules",  "endconnectrules", "connect",         "resolveto",     "merged",        "split",
        "parameter",   "localparam",  "aliasparam",    "integer",         "real",            "string",        "realtime",      "time",
        "reg",         "event",       "genvar",        "branch",          "input",           "output",        "inout",         "wire",
        "tri",         "tri0",        "tri1",          "triand",          "trior",           "trireg",        "wand",          "wor",
        "uwire",       "supply0",     "supply1",       "signed",          "unsigned",        "scalared",      "vectored",      "tran",
        "rtran",       "and",         "nand",          "nor",             "xor",             "xnor",          "buf",           "not",
        "bufif0",      "bufif1",      "notif0",        "notif1",          "discipline",      "enddiscipline", "nature",        "endnature",
        "domain",      "continuous",  "discrete",      "potential",       "flow",            "abstol",        "access",        "units",
        "ddt_nature",  "idt_nature",  "ground",        "from",            "exclude",         "inf",           "if",            "else",
        "case",        "casex",       "casez",         "endcase",         "default",         "for",           "while",         "repeat",
        "forever",     "return",      "break",         "continue",        "disable",         "or",            "initial_step",  "final_step",
        "cross",       "above",       "timer",         "absdelta",        "driver_update",   "posedge",       "negedge",       "ddt",
        "ddx",         "idt",         "idtmod",        "absdelay",        "transition",      "slew",          "last_crossing", "laplace_zd",
        "laplace_zp",  "laplace_nd",  "laplace_np",    "zi_zd",           "zi_zp",           "zi_nd",         "zi_np",         "analysis",
        "ac_stim",     "white_noise", "flicker_noise", "noise_table",     "noise_table_log", "abs",           "max",           "min",
        "pow",         "sqrt",        "exp",           "limexp",          "ln",              "log",           "expm1",         "ln1p",
        "hypot",       "floor",       "ceil",          "sin",             "cos",             "tan",           "asin",          "acos",
        "atan",        "atan2",       "sinh",          "cosh",            "tanh",            "asinh",         "acosh",         "atanh",
    };
    var kvs: [words.len]struct { []const u8 } = undefined;
    for (&kvs, words) |*kv, word| kv.* = .{word};
    break :kv kvs;
});

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
        .unmatched_end_keywords, .null_statement, .not_a_generate_item => {},
        // else: a refusal whose old text names the site; diff-parse's debt.
        else => b.msg("{s}", .{@tagName(e.tag)}),
    }
    try b.emit();
}

/// The refusals whose old code or text the error's token and its
/// neighbours decide; true when it emitted one.
fn refined(tree: *const Ast, e: Ast.Error, loc: Diag.Loc, w: *Diag.Wip) Allocator.Error!bool {
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
        .expected_module_item => if (Token.Tag.isKeyword(tag) and !quoted_keywords.has(tree.tokenSlice(tok))) blk: {
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
        else => return false, // else: the generic rendering below
    };
    try b.emit();
    return true;
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

/// The old parser's name for token `i`: a name or literal as written, a
/// symbol or dedicated keyword quoted, any other keyword bare.
fn found(tree: *const Ast, i: Ast.TokenIndex) []const u8 {
    const tag = tree.tokenTag(i);
    const text = tree.tokenSlice(i);
    return switch (tag) {
        .eof => "end of file",
        .invalid => "invalid token",
        .identifier, .system_identifier, .number_literal, .string_literal => text,
        .escaped_identifier => std.mem.trimEnd(u8, text[@min(1, text.len)..], " \t\r\n"),
        else => if (!Token.Tag.isKeyword(tag) and tag != .keyword_builtin)
            desc(tag)
        else if (quoted_keywords.has(text))
            quote(text)
        else
            text,
    };
}

/// What the grammar wanted, as the old parser's caret named it.
fn desc(tag: Token.Tag) []const u8 {
    return switch (tag) {
        .eof => "end of file",
        .invalid => "invalid token",
        .identifier, .escaped_identifier => "an identifier",
        .system_identifier => "a system task or function name",
        .number_literal => "an integer literal",
        .string_literal => "a string literal",
        else => quotedLexeme(tag),
    };
}

fn quotedLexeme(tag: Token.Tag) []const u8 {
    return switch (tag) {
        inline else => |t| comptime if (Token.Tag.lexeme(t)) |l| "`" ++ l ++ "`" else @tagName(t),
    };
}

/// `text` in backticks, from a fixed table: `found`'s keywords are short.
fn quote(text: []const u8) []const u8 {
    inline for (comptime quoted_keywords.keys()) |k| {
        if (std.mem.eql(u8, k, text)) return "`" ++ k ++ "`";
    }
    unreachable; // `found` quotes only `quoted_keywords`.
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
