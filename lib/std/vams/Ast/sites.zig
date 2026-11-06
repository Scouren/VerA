//! The reports of the parse errors whose `Ast.Error.Site` names the rule
//! that refused (`errors.zig` renders the rest): each site's code, headline
//! and caret text as the old parser wrote them, and the old parser's names
//! for tokens (`found`, `desc`), which both files use.
//!
//! Cites: VAMS-2023 annex A, §3.6, §7.8.3, §9.22, §10.6; IEEE 1364-2005
//! §8, §13.3.1, §15.1, A.5.
//!
//! Contents:
//! - `pub fn report(tree: *const Ast, e: Ast.Error, loc: Diag.Loc, w: *Diag.Wip) Allocator.Error!void`
//! - `pub fn found(tree: *const Ast, i: Ast.TokenIndex) []const u8`
//! - `pub fn desc(tag: Token.Tag) []const u8`

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

/// The report of a refusal whose `site` names its rule (`e.site` is not
/// `.generic`).
pub fn report(tree: *const Ast, e: Ast.Error, loc: Diag.Loc, w: *Diag.Wip) Allocator.Error!void {
    const tok = e.token;
    const f = found(tree, tok);
    var b = w.build(.parse, switch (e.site) {
        .specify_condition_operator, .specify_polarity_placement, .specify_ifnone_edge => .E0245,
        .port_analog_typed => .E0291,
        .net_mixed_init => .E0292,
        .charge_strength_net => .E0257,
        .gate_count => .E0209,
        .instance_unnamed => .E0293,
        .param_list_mixed => .E0246,
        .delay_close => .E0210,
        .attr_keyword_name => .E0208,
        .nature_parent_access => .E0211,
        .discipline_domain => .E0212,
        .discipline_item => .E0213,
        .vams_under_language => .E0242,
        .config_two_defaults, .config_lib_liblist => .E0243,
        .udp_colons, .udp_body_mixed, .udp_comb_edge, .udp_two_edges => .E0234,
        .udp_input_symbol, .udp_edge_shape, .udp_state_symbol, .udp_state_count, .udp_output_count, .udp_output_symbol => .E0233,
        else => .E0207,
    }, loc);
    switch (e.site) {
        .generic => unreachable, // `refined` renders the generic rows.
        .specify_list_parenthesized => b.msg("found {s}: A.7.1's `{s}` takes list_of_path_outputs, written without parentheses", .{ f, tree.tokenSlice(tok - 1) }),
        .specify_condition_operator => b.msg("a state-dependent path's condition uses only Table 14-1's operators (§14.2.4.1)", .{}),
        .specify_item => b.msg("found {s}, which begins no A.7.1 specify_item", .{f}),
        .specify_path_arrow => b.msg("found {s}: a path description connects its terminals with `=>` or `*>`", .{f}),
        .specify_polarity_placement => b.msg("an edge-sensitive path writes its polarity after the destination (Syntax 14-4), not before the arrow", .{}),
        .specify_ifnone_edge => b.msg("ifnone takes a simple path (Syntax 14-5), not an edge-sensitive one", .{}),
        .specify_parallel_list => b.msg("a parallel path (`=>`) connects one source to one destination, and this one lists {d} source(s) and {d} destination(s); lists need the full path `*>` (A.7.2)", .{ e.arg >> 16, e.arg & 0xffff }),
        .specify_delay_count => b.msg("a path delay lists 1, 2, 3, 6 or 12 values (A.7.4 list_of_path_delay_expressions), not {d}", .{e.arg}),
        .specify_timing_check_name => b.msg("found {s}: A.7.1 admits only A.7.5.1's twelve timing checks inside a specify block", .{f}),
        .specify_width_null => b.msg("found {s}: `$width`'s threshold and notifier are not null arguments (A.7.5.1, §15.3.4)", .{f}),
        .specify_event_control => b.msg("`{s}` timing check requires an event control (posedge, negedge or edge) on its reference event (A.7.5.3 controlled_timing_check_event)", .{tree.tokenSlice(e.arg)}),
        .specify_notifier => b.msg("found {s}: the notifier argument of `{s}` names a variable (A.7.5.2 notifier ::= variable_identifier)", .{ f, tree.tokenSlice(e.arg) }),
        .specify_arity => b.msg("`{s}` takes {d} to {d} arguments, not {d}", .{ tree.tokenSlice(tok), (e.arg >> 8) & 0xff, e.arg >> 16, e.arg & 0xff }),
        .port_variable_type => b.msg("found {s}: A.2.1.2 gives a variable type to `output` only", .{f}),
        .port_analog_typed => {
            b.msg("`{s} {s}`", .{ tree.tokenSlice(e.arg), tree.tokenSlice(tok) });
        },
        .function_input_only => b.msg("found {s}: A.2.6 gives a function `input` formals only; an `analog function` or a task takes `output`", .{f}),
        .tf_port_list_direction => b.msg("found {s}: a task or function port list opens with input, output or inout", .{f}),
        .port_after_list => b.msg("found {s}: a port_declaration cannot follow a list_of_ports port (A.1.3)", .{f}),
        .net_two_types => b.msg("found {s}: A.2.1.3's net_declaration names one net_type", .{f}),
        .net_advised_no_range => b.msg("§4.3.2: scalared and vectored are only legal on a vector net, which declares a range", .{}),
        .net_range_after_delay => b.msg("A.2.1.3: a net's range comes before its delay (`wire [7:0] #3 w;`), found `[` after the delay", .{}),
        .net_mixed_init => {
            b.msg("`{s}` has {s}, and the first name has {s}", .{ tree.tokenSlice(tok), if (e.arg == 0) "no initializer" else "an initializer", if (e.arg == 0) "one" else "none" });
        },
        .net_drive_no_init => b.msg("§4.4: a drive strength is only legal on a net declaration assignment", .{}),
        .charge_strength_net => {
            b.msg("a charge strength is only legal on a trireg", .{});
        },
        .charge_strength_word => b.msg("found {s}, which is not a charge strength", .{f}),
        .strength_sides => b.msg("a drive strength pairs one 0-side with one 1-side strength", .{}),
        .strength_highz => b.msg("§6.1.4: both drive strengths cannot be high impedance", .{}),
        .strength_single => b.msg("a single-strength bracket on this gate is A.3.2's `( strength{d} )`", .{e.arg}),
        .gate_count => {
            b.msg("{s}", .{switch (tree.tokenTag(e.arg)) {
                .keyword_buf, .keyword_not => "a buf/not gate needs at least one output and one input",
                .keyword_bufif0, .keyword_bufif1, .keyword_notif0, .keyword_notif1 => "an enable gate takes an output, a data input and an enable",
                .keyword_nmos, .keyword_pmos, .keyword_rnmos, .keyword_rpmos => "a mos switch (A.3.4 mos_switchtype) takes an output, an input and an enable terminal",
                .keyword_cmos, .keyword_rcmos => "a cmos switch (A.3.4 cmos_switchtype) takes an output, an input, an ncontrol and a pcontrol terminal",
                .keyword_tran, .keyword_rtran => "a pass switch (A.3.4 pass_switchtype) takes two inout terminals",
                .keyword_tranif0, .keyword_tranif1, .keyword_rtranif0, .keyword_rtranif1 => "a pass-enable switch (A.3.4 pass_en_switchtype) takes two inout terminals and an enable",
                else => "an n-input gate takes an output and at least one input", // else: and, nand, or, nor, xor, xnor
            }});
        },
        .gate_output => b.msg("found {s}: a gate's output terminal is a net_lvalue (A.3.3), a net the gate can drive", .{f}),
        .instance_unnamed => {
            if (e.arg == 1) b.msg("`{s}`, with one terminal", .{tree.tokenSlice(tok)}) else b.msg("`{s}`, with {d} terminals", .{ tree.tokenSlice(tok), e.arg });
        },
        .param_list_mixed => b.msg("instance mixes ordered and named parameter assignments", .{}),
        .delay_close, .nature_parent_access, .discipline_domain, .discipline_item => b.msg("found {s}", .{f}),
        .value_range_bare_from => {
            b.msg("found {s}", .{f});
            b.point("expected `(` or `[` — only `exclude` takes a bare value", .{});
        },
        .attr_keyword_name => {
            b.msg("found keyword `{s}`: an attribute name is an identifier", .{tree.tokenSlice(tok)});
            b.note("§2.9 / A.9.1: `attr_name ::= identifier`; only §2.9.2's `units` is exempt", .{});
            b.help("escape it: `\\{s} `", .{tree.tokenSlice(tok)});
        },
        .connect_mode => b.msg("found {s}: a connect_mode is `merged` or `split`", .{f}),
        .vams_under_language => b.msg("`{s}` under \"{s}\"", .{ tree.tokenSlice(tok), @as(Ast.KeywordSet, @fromBackingInt(@intCast(e.arg))).specifier() }),
        .timing_check_in_procedure => b.msg("`{s}` is a timing check, which only a specify block holds (§15.1)", .{tree.tokenSlice(tok)}),
        .config_design_first => b.msg("found {s}: a config_declaration begins with its `design` statement", .{f}),
        .config_no_endconfig => b.msg("found {s}: no `endconfig` closes the configuration", .{f}),
        .config_rule_start => b.msg("found {s}, which begins no A.1.5 config_rule_statement", .{f}),
        .config_two_defaults => b.msg("more than one default clause specifies a liblist (IEEE 1364-2005 §13.3.1.2)", .{}),
        .config_lib_liblist => b.msg("a cell clause with a library name takes `use`, not `liblist` (IEEE 1364-2005 §13.3.1.4)", .{}),
        .config_expansion => b.msg("found {s}: a {s} pairs with `liblist`{s}", .{ f, tree.tokenSlice(e.arg), if (tree.tokenTag(e.arg) == .keyword_default) "" else " or `use`" }),
        .config_use_suffix => b.msg("found {s}: a use_clause's `:` is followed by the word `config`", .{f}),
        .udp_body => b.msg("found {s}: a udp_body is a `table … endtable`", .{f}),
        .udp_no_endtable => b.msg("found {s}: no `endtable` closes the table", .{f}),
        .udp_entry_semicolon => b.msg("found {s}: a UDP table entry ends with `;`", .{f}),
        .udp_colons => b.msg("a UDP table entry has one colon (combinational) or two (sequential), not {d}", .{e.arg}),
        .udp_body_mixed => b.msg("this entry is {s} and the table's first entry is {s}; A.5.3 gives a table ONE udp_body", .{ udpBody(e.arg == 1), udpBody(e.arg == 0) }),
        .udp_comb_edge => b.msg("an edge indicator `{c}` in a combinational UDP table entry: A.5.3 reaches `edge_input_list` only from a sequential_entry", .{@as(u8, @intCast(e.arg))}),
        .udp_two_edges => b.msg("a sequential UDP table entry permits at most one input transition descriptor", .{}),
        .udp_input_symbol => b.msg("`{c}` is not a UDP input symbol", .{@as(u8, @intCast(e.arg))}),
        .udp_edge_shape => b.msg("an edge_indicator is `(` and two level symbols and `)` (A.5.3)", .{}),
        .udp_state_symbol => b.msg("`{c}` is not a UDP current_state symbol", .{@as(u8, @intCast(e.arg))}),
        .udp_state_count => b.msg("a UDP current_state is one level symbol, not {d}", .{e.arg}),
        .udp_output_count => b.msg("a UDP output symbol is one character, not {d}", .{e.arg}),
        .udp_output_symbol => b.msg("`{c}` is not a UDP output symbol", .{@as(u8, @intCast(e.arg))}),
        .specify_edge_descriptor => {
            // The descriptor's characters span tokens `tok..arg`.
            const end = tree.tokenStart(@intCast(e.arg));
            b.msg("found {s}, not an A.7.5.3 edge descriptor (01, 10, or 0 or 1 paired with x or z)", .{std.mem.trimEnd(u8, tree.source[tree.tokenStart(tok)..end], " \t\r\n")});
        },
    }
    try b.emit();
}

/// The old parser's name for token `i`: a name or literal as written, a
/// symbol or dedicated keyword quoted, any other keyword bare.
pub fn found(tree: *const Ast, i: Ast.TokenIndex) []const u8 {
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
pub fn desc(tag: Token.Tag) []const u8 {
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

// ---- private ----

fn udpBody(sequential: bool) []const u8 {
    return if (sequential) "sequential" else "combinational";
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
