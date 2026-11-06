//! Subroutines: §4.7.1 analog functions (A.2.6 `analog_function_declaration`)
//! and IEEE 1364-2005 A.2.6/A.2.7 functions and tasks: tokens from
//! `[analog] function` or `task` to its end keyword in, a `function_decl`
//! or `task_decl` out. Formals, local declarations and body statements are
//! one item list in source order; which formal is typed by which variable
//! (§4.7.1) is Sema's.
//! Cites: VAMS-2023 §4.7, §4.7.1, §4.7.2, A.2.6; IEEE 1364-2005 §10.2,
//! §10.4, A.2.6, A.2.7.
//!
//! Contents:
//! - `pub fn parseFunction(p: *Parse) Error!Node.Index`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("../Ast.zig");
const Parse = @import("../Parse.zig");
const decl = @import("decl.zig");
const stmt = @import("stmt.zig");
const Node = Ast.Node;
const Token = @import("../tokenizer.zig").Token;
const Error = Parse.Error;

/// `analog function [type] name [( formals )] ; items endfunction`,
/// `function [automatic] [type|[signed] [range]] name [( formals )] ;
/// items endfunction`, or `task [automatic] name [( formals )] ; items
/// endtask`. A digital function's formals are inputs only (§10.4.1); an
/// analog one's carry no data type (A.2.6). Under a Verilog-AMS set an
/// analog function's statements are `analog_statement`s, no null one.
pub fn parseFunction(p: *Parse) Error!Node.Index {
    const first = p.tok_i;
    const analog = p.eat(.keyword_analog) != null;
    const task = p.tokenTag(p.tok_i) == .keyword_task;
    p.tok_i += 1;
    var range: Node.OptionalIndex = .none;
    if (!analog) _ = p.eat(.keyword_automatic);
    switch (p.tokenTag(p.tok_i)) {
        .keyword_integer, .keyword_real, .keyword_string => p.tok_i += 1,
        .keyword_time, .keyword_realtime => if (!analog) {
            p.tok_i += 1;
        },
        .keyword_reg, .keyword_signed, .l_bracket => if (!analog and !task) {
            _ = p.eat(.keyword_reg);
            _ = p.eat(.keyword_signed);
            if (p.tokenTag(p.tok_i) == .l_bracket) range = (try decl.parseRange(p)).toOptional();
        },
        else => {},
    }
    // Annex G.7 item 7780: models older than VAMS-2023 name functions
    // `expm1`/`ln1p`, now built-ins.
    const own = p.tokenTag(p.tok_i) == .keyword_builtin and
        (std.mem.eql(u8, p.tokenText(p.tok_i), "expm1") or std.mem.eql(u8, p.tokenText(p.tok_i), "ln1p"));
    if (own) p.tok_i += 1 else _ = try p.expectIdent();
    const header: decl.PortWhere = if (analog) .analog_header else .tf_header;
    // A Verilog-AMS digital function takes inputs only (IEEE 1364-2005
    // §10.4.1); a 1364 parse leaves that to the engine.
    const input_only = !analog and !task and !p.discrete;
    // A task body is A.6's discrete grammar.
    const outer = p.discrete;
    if (task) p.discrete = true;
    defer p.discrete = outer;
    const body: decl.PortWhere = if (analog) .analog_body else .tf_body;
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    if (p.eat(.l_paren) != null) {
        var entry: u32 = 0;
        while (p.tokenTag(p.tok_i) != .r_paren and p.tokenTag(p.tok_i) != .eof) : (entry += 1) {
            _ = try p.skipAttributes();
            switch (p.tokenTag(p.tok_i)) {
                .keyword_input, .keyword_output, .keyword_inout => |d| {
                    if (input_only and d != .keyword_input) try p.warnSite(.invalid_port_declaration, .function_input_only, p.tok_i, 0);
                    try p.push(try decl.parsePortDecl(p, header));
                },
                else => {
                    // A.2.6/A.2.7: a 1364 list opens with a direction.
                    if (p.discrete and !analog and entry == 0) try p.warnSite(.invalid_port_declaration, .tf_port_list_direction, p.tok_i, 0);
                    const name = try p.expectIdent();
                    try p.push(try p.addNode(.declarator, name, .{ .extra_and_opt_node = .{ try p.addExtra(try p.listToSpan(&.{})), .none } }));
                },
            }
            if (p.eat(.comma) == null) break;
        }
        _ = try p.expect(.r_paren);
    }
    _ = try p.expect(.semicolon);
    const ports = try p.spanFrom(top);
    const end_tag: Token.Tag = if (task) .keyword_endtask else .keyword_endfunction;
    while (true) {
        const item_at = p.tok_i;
        const attributed = try p.skipAttributes();
        const t = p.tokenTag(p.tok_i);
        if (t == .eof or t == end_tag or t == .keyword_endfunction) {
            if (attributed) try p.warnAt(.attribute_prefixes_nothing, item_at);
            break;
        }
        const before = p.tok_i;
        const item = switch (t) {
            .keyword_input, .keyword_output, .keyword_inout => port: {
                if (input_only and t != .keyword_input) try p.warnSite(.invalid_port_declaration, .function_input_only, p.tok_i, 0);
                break :port decl.parsePortDecl(p, body);
            },
            .keyword_parameter, .keyword_localparam, .keyword_integer, .keyword_real, .keyword_string, .keyword_realtime, .keyword_time => decl.parseBlockDecl(p),
            // A.2.6's analog_function_item_declaration has no `reg` or event.
            .keyword_reg, .keyword_event => if (analog) stmt.parseStmtIn(p, .analog) else decl.parseBlockDecl(p),
            else => stmt.parseStmtIn(p, if (analog) .analog else .null_ok),
        } catch |e| switch (e) {
            error.OutOfMemory => return e,
            error.ParseError => {
                p.recoverItem(before);
                continue;
            },
        };
        try p.push(item);
        assert(p.tok_i > before);
    }
    // A task may close with `endfunction` too, as the old parser read it.
    if (p.eat(end_tag) == null) _ = try p.expect(.keyword_endfunction);
    if (!task and !p.discrete) try checkFunction(p, first, analog, p.extra_data.items[@backingInt(ports.start)..@backingInt(ports.end)], p.scratch.items[top..]);
    const items = try p.spanFrom(top);
    return p.addNode(if (task) .task_decl else .function_decl, first, .{ .extra = try p.addExtra(Node.Function{
        .range = range,
        .ports_start = ports.start,
        .ports_end = ports.end,
        .items_start = items.start,
        .items_end = items.end,
    }) });
}

// ---- private ----

/// §4.7.1's bullets a parse can check: at least one formal argument (a
/// Verilog-AMS digital function too), and in an analog function no named
/// block and no `return` without a value (`invalid_function`).
fn checkFunction(p: *Parse, first: Ast.TokenIndex, analog: bool, ports: []const u32, items: []const u32) Error!void {
    var formals: usize = 0;
    for ([_][]const u32{ ports, items }) |list| for (list) |i| switch (p.nodes.items(.tag)[i]) {
        // A `Node.Decl` payload is `range, items_start, items_end`.
        .port_decl => {
            const d = @backingInt(p.nodes.items(.data)[i].extra);
            formals += p.extra_data.items[d + 2] - p.extra_data.items[d + 1];
        },
        .declarator => formals += 1,
        else => {},
    };
    if (formals == 0) try p.warnAt(.invalid_function, first);
    if (!analog) return;
    for (first..p.tok_i) |t| {
        const tok: Ast.TokenIndex = @intCast(t);
        const named_block = p.tokenTag(tok) == .keyword_begin and p.tokenTag(tok + 1) == .colon;
        const bare_return = p.tokenTag(tok) == .keyword_return and p.tokenTag(tok + 1) == .semicolon;
        if (named_block or bare_return) try p.warnAt(.invalid_function, tok);
    }
}
