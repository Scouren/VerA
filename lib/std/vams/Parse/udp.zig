//! User-defined primitives (IEEE 1364-2005 A.5, inherited through VAMS
//! §1.1): `primitive ... endprimitive` in, a `udp_decl` out, its table rows
//! checked against A.5.3's alphabets and shapes; and A.5.4 instantiations.
//! A table entry's symbols are characters, not tokens (`(01)` is three
//! tokens, `b` an identifier), so an entry is judged by the characters of
//! the tokens up to its `;`. Which entries conflict (§8.1.4) is Sema's.
//! Cites: IEEE 1364-2005 §8, §8.1.4, §8.4, A.5.1-A.5.4.
//!
//! Contents:
//! - `pub fn parseUdpDecl(p: *Parse) Error!Node.Index`
//! - `pub fn parseUdpInst(p: *Parse) Error!Node.Index`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("../Ast.zig");
const Parse = @import("../Parse.zig");
const expr = @import("expr.zig");
const decl = @import("decl.zig");
const prim = @import("prim.zig");
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const Error = Parse.Error;

/// The characters of tokens `tok..end`, in order.
const Chars = struct {
    p: *const Parse,
    tok: TokenIndex,
    end: TokenIndex,
    at: usize = 0,

    fn next(it: *Chars) ?u8 {
        while (it.tok < it.end) {
            const text = it.p.tokenText(it.tok);
            if (it.at < text.len) {
                it.at += 1;
                return text[it.at - 1];
            }
            it.tok += 1;
            it.at = 0;
        }
        return null;
    }
};

/// A.5.1 `primitive name ( ports ) ; { port declaration } [ initial ]
/// table entries endtable endprimitive`, the ports bare names or (A.5.2)
/// declarations; at least an output and an input.
pub fn parseUdpDecl(p: *Parse) Error!Node.Index {
    assert(p.tokenTag(p.tok_i) == .keyword_primitive);
    const kw = p.tok_i;
    p.tok_i += 1;
    _ = try p.expectIdent();
    _ = try p.expect(.l_paren);
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    while (true) {
        _ = try p.skipAttributes();
        try p.push(try udpPort(p));
        if (p.eat(.comma) == null) break;
    }
    if (p.scratch.items.len - top < 2) return p.fail(.invalid_udp);
    _ = try p.expect(.r_paren);
    _ = try p.expect(.semicolon);
    const ports = try p.spanFrom(top);
    while (true) {
        _ = try p.skipAttributes();
        switch (p.tokenTag(p.tok_i)) {
            .keyword_output, .keyword_input, .keyword_reg => {},
            else => break,
        }
        const list = p.tok_i;
        const items_top = p.scratch.items.len;
        while (true) {
            try p.push(try udpPort(p));
            if (p.eat(.comma) == null) break;
        }
        _ = try p.expect(.semicolon);
        const items = try p.spanFrom(items_top);
        try p.push(try p.addNode(.port_decl, list, .{ .extra = try p.addExtra(Node.Decl{ .range = .none, .items_start = items.start, .items_end = items.end }) }));
    }
    if (p.eat(.keyword_initial)) |init| {
        _ = try p.expectIdent();
        _ = try p.expect(.equal);
        const value = try expr.parseExpr(p);
        _ = try p.expect(.semicolon);
        try p.push(try p.addNode(.udp_initial, init, .{ .node = value }));
    }
    try p.push(try parseTable(p));
    if (p.eat(.keyword_endprimitive) == null) return p.fail(.invalid_udp);
    const items = try p.spanFrom(top);
    return p.addNode(.udp_decl, kw, .{ .extra = try p.addExtra(Node.Udp{ .ports_start = ports.start, .ports_end = ports.end, .items_start = items.start, .items_end = items.end }) });
}

/// A.5.4 `udp [drive_strength] [delay2] instance {, instance} ;`, an
/// instance `[name [range]] ( output , input {, input} )`; an unnamed one
/// with one terminal is a module instance missing its name (E0293 before).
pub fn parseUdpInst(p: *Parse) Error!Node.Index {
    const name_tok = p.tok_i;
    p.tok_i += 1;
    if (p.tokenTag(p.tok_i) == .l_paren and prim.strengthSide(p.peek(1)) != null) try prim.parseDriveStrength(p);
    const delay: Node.OptionalIndex = if (p.tokenTag(p.tok_i) == .hash) (try prim.parseDelay(p, 2)).toOptional() else .none;
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    while (true) {
        const inst = p.tok_i;
        var range: Node.OptionalIndex = .none;
        const named = p.identLike(inst);
        if (named) {
            p.tok_i += 1;
            if (p.tokenTag(p.tok_i) == .l_bracket) range = (try decl.parseRange(p)).toOptional();
        }
        _ = try p.expect(.l_paren);
        const terms_top = p.scratch.items.len;
        const out = try expr.parseExpr(p);
        if (!prim.isNetLvalue(p, out)) return p.failSite(.invalid_gate_terminals, .gate_output, p.nodes.items(.main_token)[@backingInt(out)], 0);
        try p.push(out);
        while (p.eat(.comma) != null) try p.push(try expr.parseExpr(p));
        if (!named and p.scratch.items.len - terms_top < 2) return p.failSite(.invalid_gate_terminals, .instance_unnamed, name_tok, @intCast(p.scratch.items.len - terms_top));
        _ = try p.expect(.r_paren);
        const terms = try p.spanFrom(terms_top);
        try p.push(try p.addNode(.gate_instance, inst, .{ .extra = try p.addExtra(Node.GateInstance{ .range = range, .terms_start = terms.start, .terms_end = terms.end }) }));
        if (p.eat(.comma) == null) break;
    }
    _ = try p.expect(.semicolon);
    const items = try p.spanFrom(top);
    return p.addNode(.udp_instantiation, name_tok, .{ .extra = try p.addExtra(Node.Decl{ .range = delay, .items_start = items.start, .items_end = items.end }) });
}

// ---- private ----

/// One UDP port: `[output|input|reg] [discipline] [reg] name [= expr]`.
fn udpPort(p: *Parse) Error!Node.Index {
    switch (p.tokenTag(p.tok_i)) {
        .keyword_output, .keyword_input, .keyword_reg => {
            p.tok_i += 1;
            if (p.tokenTag(p.tok_i) == .identifier and p.identLike(p.tok_i + 1)) p.tok_i += 1;
            _ = p.eat(.keyword_reg);
        },
        else => {},
    }
    const name = try p.expectIdent();
    const init: Node.OptionalIndex = if (p.eat(.equal) != null) (try expr.parseExpr(p)).toOptional() else .none;
    return p.addNode(.declarator, name, .{ .extra_and_opt_node = .{ try p.addExtra(try p.listToSpan(&.{})), init } });
}

/// A.5.3 `table entry { entry } endtable`; every entry has the first one's
/// body (one colon: combinational, two: sequential).
fn parseTable(p: *Parse) Error!Node.Index {
    const kw = p.eat(.keyword_table) orelse return p.failSite(.invalid_udp, .udp_body, p.tok_i, 0);
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    var sequential: ?bool = null;
    while (p.eat(.keyword_endtable) == null) {
        if (p.tokenTag(p.tok_i) == .eof) return p.failSite(.invalid_udp, .udp_no_endtable, p.tok_i, 0);
        try p.push(try parseEntry(p, &sequential));
    }
    return p.addNode(.udp_table, kw, .{ .extra_range = try p.spanFrom(top) });
}

/// One `level_input_list : output ;` or `seq_input_list : state : next ;`
/// against A.5.3's alphabets: inputs from `01xX?bB` (and in a sequential
/// entry at most one edge, `rRfFpPnN*` or `( level level )`), the state one
/// level symbol, the output one of `01xX` (or `-` for a next state). The
/// checks run in the old parser's order, so the first refusal is its.
fn parseEntry(p: *Parse, sequential: *?bool) Error!Node.Index {
    const first = p.tok_i;
    // The first token of each column; a colon opens columns 1 and 2.
    var cols: [3]TokenIndex = .{ first, first, first };
    var n: u32 = 0;
    while (p.tokenTag(p.tok_i) != .semicolon) : (p.tok_i += 1) {
        if (p.tokenTag(p.tok_i) == .eof or p.tokenTag(p.tok_i) == .keyword_endtable) return p.failSite(.invalid_udp, .udp_entry_semicolon, p.tok_i, 0);
        if (p.tokenTag(p.tok_i) != .colon) continue;
        n += 1;
        if (n > 2) return p.failSite(.invalid_udp, .udp_colons, first, n);
        cols[n] = p.tok_i + 1;
    }
    const semi = p.tok_i;
    p.tok_i += 1;
    if (n == 0) return p.failSite(.invalid_udp, .udp_colons, first, 0);
    const seq = n == 2;
    if (sequential.*) |was| {
        if (was != seq) return p.failSite(.invalid_udp, .udp_body_mixed, first, @intFromBool(seq));
    } else sequential.* = seq;
    // The inputs' alphabet, then (A.5.3 edge_indicator) the shape of each
    // `( level level )`.
    var edges: u32 = 0;
    var it: Chars = .{ .p = p, .tok = first, .end = cols[1] - 1 };
    while (it.next()) |c| {
        if (isLevel(c)) continue;
        if (std.mem.findScalar(u8, "rRfFpPnN*()", c) == null) return p.failSite(.invalid_udp, .udp_input_symbol, first, c);
        if (!seq) return p.failSite(.invalid_udp, .udp_comb_edge, first, c);
        edges += @intFromBool(c != ')');
        if (edges > 1) return p.failSite(.invalid_udp, .udp_two_edges, first, 0);
    }
    var pair: u8 = 0; // characters seen inside an open `(`
    it = .{ .p = p, .tok = first, .end = cols[1] - 1 };
    while (it.next()) |c| {
        const ok = switch (pair) {
            0 => c != ')',
            1, 2 => isLevel(c),
            else => c == ')',
        };
        if (!ok) return p.failSite(.invalid_udp, .udp_edge_shape, first, 0);
        pair = if (pair == 3 or (pair == 0 and c != '(')) 0 else pair + 1;
    }
    if (pair != 0) return p.failSite(.invalid_udp, .udp_edge_shape, first, 0);
    if (seq) {
        var count: u32 = 0;
        var state: Chars = .{ .p = p, .tok = cols[1], .end = cols[2] - 1 };
        while (state.next()) |c| : (count += 1) if (!isLevel(c)) return p.failSite(.invalid_udp, .udp_state_symbol, cols[1], c);
        if (count != 1) return p.failSite(.invalid_udp, .udp_state_count, cols[1], count);
    }
    var count: u32 = 0;
    var last: u8 = 0;
    var out: Chars = .{ .p = p, .tok = cols[n], .end = semi };
    while (out.next()) |c| : (count += 1) last = c;
    if (count != 1) return p.failSite(.invalid_udp, .udp_output_count, cols[n], count);
    if (std.mem.findScalar(u8, "01xX", last) == null and !(seq and last == '-')) return p.failSite(.invalid_udp, .udp_output_symbol, cols[n], last);
    return p.addNode(.udp_entry, first, .{ .token = semi });
}

/// A.5.3 `level_symbol ::= 0 | 1 | x | X | ? | b | B`.
fn isLevel(c: u8) bool {
    return std.mem.findScalar(u8, "01xX?bB", c) != null;
}
