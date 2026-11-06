//! In-progress parsing of one token list into an `Ast` (Zig's
//! `lib/std/zig/Parse.zig`): tokens in, nodes, extra data and errors out.
//! Recursive descent, predictive with bounded lookahead, context-free: no
//! name is looked up and nothing is folded. The grammar state is what the
//! token stream itself carries: the §10.6 keyword set (`begin_keywords),
//! whether the cursor is below a generate region or construct (Syntax 6-8's
//! `module_or_generate_item`), inside an attribute value (§2.9 forbids a
//! nested instance) or a paramset statement (§6.4.3's `.name` primary).
//! This file is the spine (`parseRoot`), the cursor, the node writers, the
//! §10.6 directives and the §2.9 attribute instances; each grammar area is a
//! file of free functions in `Parse/`.
//! Cites: VAMS-2023 annex A (A.1.2 source_text), §2.9, §10.6; IEEE 1364-2005
//! §19.6.
//!
//! Contents:
//! - fields: the cursor, the tables being written, the grammar state
//! - `pub const Error`, `pub const KeywordSet`, `pub const max_depth`
//! - `pub fn run(gpa: Allocator, source: [:0]const u8, tokens: Ast.TokenList.Slice, options: Ast.ParseOptions) Allocator.Error!Ast`
//! - `pub fn tokenTag(p: *const Parse, i: TokenIndex) Token.Tag`, `pub fn peek(p: *const Parse, n: u32) Token.Tag`, `pub fn tokenText(p: *const Parse, i: TokenIndex) []const u8`
//! - `pub fn eat(p: *Parse, tag: Token.Tag) ?TokenIndex`, `pub fn expect(p: *Parse, tag: Token.Tag) Error!TokenIndex`, `pub fn identLike(p: *const Parse, i: TokenIndex) bool`, `pub fn expectIdent(p: *Parse) Error!TokenIndex`
//! - `pub fn addNode(p: *Parse, tag: Node.Tag, main_token: TokenIndex, data: Node.Data) Allocator.Error!Node.Index`, `pub fn addExtra(p: *Parse, extra: anytype) Allocator.Error!ExtraIndex`, `pub fn listToSpan(p: *Parse, list: []const u32) Allocator.Error!Node.SubRange`, `pub fn push(p: *Parse, n: Node.Index) Allocator.Error!void`, `pub fn pushOpt(p: *Parse, n: Node.OptionalIndex) Allocator.Error!void`, `pub fn spanFrom(p: *Parse, top: usize) Allocator.Error!Node.SubRange`
//! - `pub fn warn(p: *Parse, tag: Ast.Error.Tag) Allocator.Error!void`, `pub fn warnAt(p: *Parse, tag: Ast.Error.Tag, tok: TokenIndex) Allocator.Error!void`, `pub fn fail(p: *Parse, tag: Ast.Error.Tag) Error`, `pub fn failAt(p: *Parse, tag: Ast.Error.Tag, tok: TokenIndex) Error`
//! - `pub fn enter(p: *Parse) Error!void`, `pub fn leave(p: *Parse) void`
//! - `pub fn skipAttributes(p: *Parse) Allocator.Error!bool`, `pub fn pastAttributes(p: *const Parse) TokenIndex`
//! - `pub fn recoverItem(p: *Parse, before: TokenIndex) void`
//! - `pub fn vamsWordUnder1364(p: *const Parse, i: TokenIndex) bool`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const tokenizer = @import("tokenizer.zig");
const keywords = @import("Parse/keywords.zig");
const module = @import("Parse/module.zig");
const design = @import("Parse/design.zig");
const udp = @import("Parse/udp.zig");
const expr = @import("Parse/expr.zig");
const number_literal = @import("number_literal.zig");
const Token = tokenizer.Token;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const ExtraIndex = Ast.ExtraIndex;

gpa: Allocator,
source: [:0]const u8,
tokens: Ast.TokenList.Slice,
tok_i: TokenIndex,
errors: std.ArrayList(Ast.Error),
nodes: Ast.NodeList,
extra_data: std.ArrayList(u32),
/// The lists being collected, innermost on top: a user pushes above the
/// length it took and truncates back on every path (Zig's `scratch`).
scratch: std.ArrayList(u32),
/// Recursion levels open (`enter`), bounded by `max_depth`.
depth: u32,
/// The language (`ParseOptions.keywords`): the §10.6 default set and the
/// ceiling on `begin_keywords.
language: KeywordSet,
/// §10.6 set in effect, and the sets each open `begin_keywords saved.
kw_set: KeywordSet,
kw_stack: std.ArrayList(KeywordSet),
/// Generate regions and generate constructs open around the cursor.
gen_depth: u32,
/// Attribute instances open around the cursor (§2.9: no nesting).
attr_depth: u32,
/// Inside a paramset statement, where `.name` is a primary (§6.4.3).
in_paramset: bool,
/// Statements are IEEE 1364-2005 A.6's (a 1364 language, an `initial` or
/// `always` body, a task), not A.6.4's `analog_statement`s: `#`, `wait`,
/// `forever`, `fork`, `<=`, task enables and intra-assignment timing parse.
discrete: bool,
/// Inside a §7.6 `connectmodule`, where §9.22 admits `driver_update`.
connect_module: bool,

/// `ParseError`: the diagnostic is in `errors` and the caller recovers.
pub const Error = error{ParseError} || Allocator.Error;

pub const KeywordSet = keywords.KeywordSet;

/// Deepest nesting of statements, expressions and generate blocks; past it
/// is `nesting_too_deep` (lib/TODO.md §11.2: a fixed cap, with workers on a
/// 256 MiB stack). The fixtures nest 1,100.
pub const max_depth = 10_000;

const Parse = @This();

/// Parses `tokens` (ending in `.eof`) of `source` into a tree that takes
/// ownership of `tokens`. On `OutOfMemory` the caller still owns `tokens`.
pub fn run(gpa: Allocator, source: [:0]const u8, tokens: Ast.TokenList.Slice, options: Ast.ParseOptions) Allocator.Error!Ast {
    assert(tokens.len > 0);
    assert(tokens.items(.tag)[tokens.len - 1] == .eof);
    var p: Parse = .{
        .gpa = gpa,
        .source = source,
        .tokens = tokens,
        .tok_i = 0,
        .errors = .empty,
        .nodes = .empty,
        .extra_data = .empty,
        .scratch = .empty,
        .depth = 0,
        .language = options.keywords,
        .kw_set = options.keywords,
        .kw_stack = .empty,
        .gen_depth = 0,
        .attr_depth = 0,
        .in_paramset = false,
        .discrete = @backingInt(options.keywords) < @backingInt(KeywordSet.vams_2_3),
        .connect_module = false,
    };
    defer p.errors.deinit(gpa);
    defer p.nodes.deinit(gpa);
    defer p.extra_data.deinit(gpa);
    defer p.scratch.deinit(gpa);
    defer p.kw_stack.deinit(gpa);
    // About two tokens per node.
    try p.nodes.ensureTotalCapacity(gpa, tokens.len / 2 + 1);
    try p.parseRoot();
    assert(p.depth == 0);
    assert(p.scratch.items.len == 0);
    const extra = try p.extra_data.toOwnedSlice(gpa);
    errdefer gpa.free(extra);
    const errors = try p.errors.toOwnedSlice(gpa);
    return .{ .source = source, .tokens = tokens, .nodes = p.nodes.toOwnedSlice(), .extra_data = extra, .errors = errors };
}

pub fn tokenTag(p: *const Parse, i: TokenIndex) Token.Tag {
    return p.tokens.items(.tag)[i];
}

/// The tag `n` tokens past the cursor, clamped to the final `.eof`.
pub fn peek(p: *const Parse, n: u32) Token.Tag {
    return p.tokenTag(@min(p.tok_i + n, @as(TokenIndex, @intCast(p.tokens.len - 1))));
}

/// Token `i`'s source text (an escaped identifier keeps its `\`).
pub fn tokenText(p: *const Parse, i: TokenIndex) []const u8 {
    const tag = p.tokenTag(i);
    if (tag.lexeme()) |l| return l;
    var tz: tokenizer.Tokenizer = .{ .buffer = p.source, .index = p.tokens.items(.start)[i] };
    const tok = tz.next();
    assert(tok.tag == tag);
    return p.source[tok.loc.start..tok.loc.end];
}

/// Consumes the next token if it is `tag`.
pub fn eat(p: *Parse, tag: Token.Tag) ?TokenIndex {
    assert(p.tok_i < p.tokens.len);
    assert(tag != .eof);
    if (p.tokenTag(p.tok_i) != tag) return null;
    p.tok_i += 1;
    return p.tok_i - 1;
}

/// Consumes a `tag` token, or fails with `expected_token` at the cursor.
pub fn expect(p: *Parse, tag: Token.Tag) Error!TokenIndex {
    if (p.eat(tag)) |i| return i;
    try p.errors.append(p.gpa, .{ .tag = .expected_token, .token = p.tok_i, .extra = .{ .expected_tag = tag } });
    return error.ParseError;
}

/// Whether token `i` can stand where the grammar wants a name: §2.8 and
/// §2.8.1 identifiers, and a keyword the §10.6 set in effect does not
/// reserve (§10.6: `input sin;` "OK since sin is not a keyword in 1364-2005").
pub fn identLike(p: *const Parse, i: TokenIndex) bool {
    const tag = p.tokenTag(@min(i, @as(TokenIndex, @intCast(p.tokens.len - 1))));
    return switch (tag) {
        .identifier, .escaped_identifier => true,
        else => tag.isKeyword() and p.kw_set != .vams_2023 and !keywords.reservedUnder(p.tokenText(i), p.kw_set), // else: a keyword the set in effect leaves free
    };
}

/// Consumes a name (`identLike`), or fails with `expected_identifier`.
pub fn expectIdent(p: *Parse) Error!TokenIndex {
    if (!p.identLike(p.tok_i)) return p.fail(.expected_identifier);
    p.tok_i += 1;
    return p.tok_i - 1;
}

pub fn addNode(p: *Parse, tag: Node.Tag, main_token: TokenIndex, data: Node.Data) Allocator.Error!Node.Index {
    assert(main_token < p.tokens.len);
    assert(tag != .root);
    const result: Node.Index = @fromBackingInt(@as(u32, @intCast(p.nodes.len)));
    try p.nodes.append(p.gpa, .{ .tag = tag, .main_token = main_token, .data = data });
    assert(@backingInt(result) == p.nodes.len - 1);
    return result;
}

/// Appends the payload struct `extra` (every field a `u32`-backed index)
/// and returns where it starts.
pub fn addExtra(p: *Parse, extra: anytype) Allocator.Error!ExtraIndex {
    const info = @typeInfo(@TypeOf(extra)).@"struct";
    try p.extra_data.ensureUnusedCapacity(p.gpa, info.field_names.len);
    const result: ExtraIndex = @fromBackingInt(@as(u32, @intCast(p.extra_data.items.len)));
    inline for (info.field_names, info.field_types) |name, F| {
        p.extra_data.appendAssumeCapacity(if (F == TokenIndex) @field(extra, name) else @backingInt(@field(extra, name)));
    }
    return result;
}

pub fn listToSpan(p: *Parse, list: []const u32) Allocator.Error!Node.SubRange {
    for (list) |n| assert(n == @backingInt(Node.OptionalIndex.none) or n < p.nodes.len);
    try p.extra_data.appendSlice(p.gpa, list);
    const end: u32 = @intCast(p.extra_data.items.len);
    assert(end >= list.len);
    return .{ .start = @fromBackingInt(end - @as(u32, @intCast(list.len))), .end = @fromBackingInt(end) };
}

pub fn push(p: *Parse, n: Node.Index) Allocator.Error!void {
    try p.scratch.append(p.gpa, @backingInt(n));
}

pub fn pushOpt(p: *Parse, n: Node.OptionalIndex) Allocator.Error!void {
    try p.scratch.append(p.gpa, @backingInt(n));
}

/// Copies `scratch[top..]` to `extra_data` and truncates `scratch` to `top`.
pub fn spanFrom(p: *Parse, top: usize) Allocator.Error!Node.SubRange {
    assert(top <= p.scratch.items.len);
    const span = try p.listToSpan(p.scratch.items[top..]);
    p.scratch.shrinkRetainingCapacity(top);
    return span;
}

pub fn warn(p: *Parse, tag: Ast.Error.Tag) Allocator.Error!void {
    @branchHint(.cold);
    try p.warnAt(tag, p.tok_i);
}

pub fn warnAt(p: *Parse, tag: Ast.Error.Tag, tok: TokenIndex) Allocator.Error!void {
    @branchHint(.cold);
    try p.errors.append(p.gpa, .{ .tag = tag, .token = tok });
}

pub fn fail(p: *Parse, tag: Ast.Error.Tag) Error {
    @branchHint(.cold);
    return p.failAt(tag, p.tok_i);
}

pub fn failAt(p: *Parse, tag: Ast.Error.Tag, tok: TokenIndex) Error {
    @branchHint(.cold);
    try p.warnAt(tag, tok);
    return error.ParseError;
}

/// Opens one level of recursion, or fails with `nesting_too_deep` past
/// `max_depth`. Pair with `defer p.leave()`.
pub fn enter(p: *Parse) Error!void {
    if (p.depth >= max_depth) return p.fail(.nesting_too_deep);
    p.depth += 1;
}

pub fn leave(p: *Parse) void {
    assert(p.depth > 0);
    p.depth -= 1;
}

/// Parses the §2.9 attribute instances at the cursor into `attribute`
/// nodes (owned by no parent; see Ast.zig) and returns whether there were
/// any. A malformed one is reported and skipped past its `*)`.
pub fn skipAttributes(p: *Parse) Allocator.Error!bool {
    const start = p.tok_i;
    while (p.tokenTag(p.tok_i) == .l_paren_asterisk) {
        parseAttribute(p) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseError => while (true) : (p.tok_i += 1) switch (p.tokenTag(p.tok_i)) {
                .eof => break,
                .asterisk_r_paren => {
                    p.tok_i += 1;
                    break;
                },
                else => {},
            },
        };
    }
    assert(p.tok_i >= start);
    return p.tok_i != start;
}

/// The token past the attribute instances at the cursor, found by scanning
/// to each `*)`; nothing is read.
pub fn pastAttributes(p: *const Parse) TokenIndex {
    var i = p.tok_i;
    while (p.tokenTag(i) == .l_paren_asterisk) {
        while (p.tokenTag(i) != .asterisk_r_paren and p.tokenTag(i) != .eof) i += 1;
        if (p.tokenTag(i) == .eof) break;
        i += 1;
    }
    return i;
}

/// Resynchronizes after a bad module item or statement: past the next `;`,
/// or up to a keyword that closes the enclosing construct. Always moves
/// past `before` unless that is `.eof`.
pub fn recoverItem(p: *Parse, before: TokenIndex) void {
    assert(p.tok_i >= before);
    if (p.tok_i == before and p.tokenTag(p.tok_i) != .eof) p.tok_i += 1;
    defer assert(p.tok_i > before or p.tokenTag(p.tok_i) == .eof);
    while (true) : (p.tok_i += 1) switch (p.tokenTag(p.tok_i)) {
        .eof, .keyword_end, .keyword_endmodule, .keyword_endfunction, .keyword_endgenerate, .keyword_endcase, .keyword_endnature, .keyword_enddiscipline, .keyword_analog => return,
        .semicolon => {
            p.tok_i += 1;
            return;
        },
        else => {},
    };
}

/// Whether token `i` is a keyword the parse's 1364 language does not
/// reserve: a Verilog-AMS word, which no IEEE 1364-2005 production opens.
pub fn vamsWordUnder1364(p: *const Parse, i: TokenIndex) bool {
    if (@backingInt(p.language) >= @backingInt(KeywordSet.vams_2_3)) return false;
    return p.tokenTag(i).isKeyword() and !keywords.reservedUnder(p.tokenText(i), p.language);
}

// ---- private ----

/// A.1.2 `source_text ::= { description }`, with the §10.6 directives
/// between descriptions. Node 0 is the root.
fn parseRoot(p: *Parse) Allocator.Error!void {
    p.nodes.appendAssumeCapacity(.{ .tag = .root, .main_token = 0, .data = undefined });
    try checkStrings(p);
    const top = p.scratch.items.len;
    while (true) {
        const item_at = p.tok_i;
        const attributed = try p.skipAttributes();
        if (p.tokenTag(p.tok_i) == .eof) {
            if (attributed) try p.warnAt(.attribute_prefixes_nothing, item_at);
            break;
        }
        const before = p.tok_i;
        if (p.vamsWordUnder1364(before)) try p.warn(.vams_construct_under_1364);
        const node = parseDescription(p) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseError => {
                recoverTopLevel(p, before);
                continue;
            },
        };
        if (node) |n| try p.push(n);
        assert(p.tok_i > before);
    }
    const span = try p.spanFrom(top);
    p.nodes.items(.data)[0] = .{ .extra_range = span };
}

/// One description, or null for a directive between descriptions.
fn parseDescription(p: *Parse) Error!?Node.Index {
    return switch (p.tokenTag(p.tok_i)) {
        .directive_begin_keywords => {
            try beginKeywords(p);
            return null;
        },
        .directive_end_keywords => {
            const tok = p.tok_i;
            p.tok_i += 1;
            p.kw_set = p.kw_stack.pop() orelse return p.failAt(.unmatched_end_keywords, tok);
            return null;
        },
        .directive_resetall, .directive_default_nettype, .directive_unconnected_drive, .directive_nounconnected_drive, .directive_default_transition => {
            p.tok_i += 1;
            return null;
        },
        .keyword_module, .keyword_macromodule, .keyword_connectmodule => try module.parseModule(p),
        .keyword_discipline => try design.parseDiscipline(p),
        .keyword_nature => try design.parseNature(p),
        .keyword_paramset => try design.parseParamset(p),
        .keyword_connectrules => try design.parseConnectRules(p),
        .keyword_config => try design.parseConfig(p),
        .keyword_primitive => try udp.parseUdpDecl(p),
        .keyword_library, .keyword_include => {
            try design.parseLibraryDecl(p);
            return null;
        },
        .keyword_specify => p.fail(.specify_outside_module),
        else => p.fail(.expected_description),
    };
}

/// §10.6 `begin_keywords "specifier"`: an unknown specifier, or one newer
/// than the language, is `unknown_keyword_set`.
fn beginKeywords(p: *Parse) Error!void {
    p.tok_i += 1;
    const str = try p.expect(.string_literal);
    const raw = p.tokenText(str);
    const known = KeywordSet.fromSpecifier(raw[1 .. raw.len - 1]) orelse return p.failAt(.unknown_keyword_set, str);
    // "1364-2001-noconfig" reserves a subset of "1364-2001", so it is no newer.
    const age: KeywordSet = if (known == .v1364_2001_noconfig) .v1364_2001 else known;
    if (@backingInt(age) > @backingInt(p.language)) return p.failAt(.unknown_keyword_set, str);
    try p.kw_stack.append(p.gpa, p.kw_set);
    p.kw_set = known;
}

/// Skips to the next token that opens a description, past any end keyword
/// that closes the one abandoned. Always advances unless at `.eof`.
fn recoverTopLevel(p: *Parse, before: TokenIndex) void {
    if (p.tok_i == before and p.tokenTag(p.tok_i) != .eof) p.tok_i += 1;
    while (true) : (p.tok_i += 1) switch (p.tokenTag(p.tok_i)) {
        .eof, .keyword_module, .keyword_macromodule, .keyword_connectmodule, .keyword_discipline, .keyword_nature, .keyword_paramset, .keyword_connectrules => return,
        .keyword_endmodule, .keyword_enddiscipline, .keyword_endnature, .keyword_endparamset, .keyword_endconnectrules, .keyword_endprimitive, .keyword_endconfig => {
            p.tok_i += 1;
            return;
        },
        .keyword_primitive, .keyword_config => if (p.tok_i != before) return,
        else => {},
    };
}

/// §2.7 Table 2-2 over every string literal: an octal escape above `\377`.
fn checkStrings(p: *Parse) Allocator.Error!void {
    for (p.tokens.items(.tag), 0..) |tag, i| {
        if (tag != .string_literal) continue;
        if (number_literal.badEscape(p.tokenText(@intCast(i))) != null) try p.warnAt(.invalid_string_escape, @intCast(i));
    }
}

/// One `(* attr_spec {, attr_spec} *)`; `attr_spec ::= name [= expr]`.
/// §2.9.2's `units` is the one keyword admitted as a name.
fn parseAttribute(p: *Parse) Error!void {
    if (p.attr_depth != 0) return p.fail(.nested_attribute);
    const open = p.tok_i;
    p.tok_i += 1;
    p.attr_depth += 1;
    defer p.attr_depth -= 1;
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    while (true) {
        const name = p.tok_i;
        if (!p.identLike(name) and p.tokenTag(name) != .keyword_units) return p.fail(.expected_identifier);
        p.tok_i += 1;
        const value: Node.OptionalIndex = if (p.eat(.equal) != null) (try expr.parseExpr(p)).toOptional() else .none;
        try p.push(try p.addNode(.attr_spec, name, .{ .opt_node = value }));
        if (p.eat(.comma) == null) break;
    }
    _ = try p.expect(.asterisk_r_paren);
    _ = try p.addNode(.attribute, open, .{ .extra_range = try p.spanFrom(top) });
}

test {
    _ = keywords;
    _ = module;
    _ = design;
    _ = udp;
    _ = expr;
}
