//! Declarations (A.2): parameters, aliasparams and value ranges (§3.4),
//! variables and `reg` (§3.2, §3.3), genvars and events, ports (§6.5.2),
//! nets with their strengths and delays (§3.6.3, §3.7), branches (§3.12),
//! continuous assignments (A.6.1) and A.2.5 ranges: tokens in, declaration
//! nodes out. A name that also names a header port is just a declarator
//! here; folding it into the port is Sema's.
//! Cites: VAMS-2023 §3.2-§3.4.6, §3.6.3, §3.6.3.2, §3.7, §3.12, §6.5.2,
//! A.2.1-A.2.5; IEEE 1364-2005 §4.4, §4.10.1, §12.3.3, §14.6.1.
//!
//! Contents:
//! - `pub const PortWhere = enum`
//! - `pub fn parseParamDecl(p: *Parse) Error!Node.Index`
//! - `pub fn parseAliasparam(p: *Parse) Error!Node.Index`
//! - `pub fn parseVarDecl(p: *Parse) Error!Node.Index`
//! - `pub fn parseNameList(p: *Parse) Error!Node.Index`
//! - `pub fn parseBlockDecl(p: *Parse) Error!Node.Index`
//! - `pub fn parseBranch(p: *Parse) Error!Node.Index`
//! - `pub fn parsePortDecl(p: *Parse, where: PortWhere) Error!Node.Index`
//! - `pub fn parseNetDecl(p: *Parse) Error!Node.Index`
//! - `pub fn parseContinuousAssign(p: *Parse) Error!Node.Index`
//! - `pub fn parseRange(p: *Parse) Error!Node.Index`
//! - `pub fn parseDims(p: *Parse) Error!Node.SubRange`
//! - `pub fn netType(tag: Token.Tag) bool`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("../Ast.zig");
const Parse = @import("../Parse.zig");
const expr = @import("expr.zig");
const prim = @import("prim.zig");
const Token = @import("../tokenizer.zig").Token;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const Error = Parse.Error;

/// Where a port declaration stands: a module header (A.1.3, its names end
/// at a comma that no name follows), a module body (ends in `;`), or a
/// task/function's (A.2.6/A.2.7, with their own type arms).
pub const PortWhere = enum { header, body, tf_header, tf_body, analog_header, analog_body };

/// What a declarator may carry after its name: dimensions and an
/// initializer, dimensions alone, a range, an initializer, or nothing.
const Shape = enum { dims_init, dims, range, init, name };

/// How a declarator list continues: at every comma, or (a header's) only
/// at a comma a name follows.
const Continue = enum { comma, comma_name };

/// A.2.1.1 `parameter|localparam|specparam [signed] [type|range]
/// param_assignment {, param_assignment}`, without the `;`. A comma before
/// another `parameter` ends the list (A.1.3 shares the comma).
pub fn parseParamDecl(p: *Parse) Error!Node.Index {
    assert(p.tokenTag(p.tok_i) == .keyword_parameter or p.tokenTag(p.tok_i) == .keyword_localparam or p.tokenTag(p.tok_i) == .keyword_specparam);
    const kw = p.tok_i;
    p.tok_i += 1;
    _ = p.eat(.keyword_signed);
    // A type keyword the §10.6 set frees, right before `=`, is the name.
    const named = p.peek(1) == .equal and p.identLike(p.tok_i);
    var range: Node.OptionalIndex = .none;
    if (!named) switch (p.tokenTag(p.tok_i)) {
        .keyword_integer, .keyword_real, .keyword_realtime, .keyword_time, .keyword_string => p.tok_i += 1,
        .l_bracket => range = (try parseRange(p)).toOptional(),
        else => {},
    };
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    while (true) {
        const name = try p.expectIdent();
        const dims = try parseDims(p);
        _ = try p.expect(.equal);
        // §14.6.1: `PATHPULSE$... = ( reject [, error] )`.
        const value = if (std.mem.startsWith(u8, p.tokenText(name), "PATHPULSE$") and p.tokenTag(p.tok_i) == .l_paren) limits: {
            const lp = p.tok_i;
            p.tok_i += 1;
            const reject = try expr.parseMinTypMax(p);
            const err: Node.OptionalIndex = if (p.eat(.comma) != null) (try expr.parseMinTypMax(p)).toOptional() else .none;
            _ = try p.expect(.r_paren);
            break :limits try p.addNode(.pulse_limits, lp, .{ .node_and_opt_node = .{ reject, err } });
        } else try expr.parseMinTypMax(p);
        const ranges_top = p.scratch.items.len;
        while (p.tokenTag(p.tok_i) == .keyword_from or p.tokenTag(p.tok_i) == .keyword_exclude) try p.push(try parseValueRange(p));
        const ranges = try p.spanFrom(ranges_top);
        try p.push(try p.addNode(.param_assign, name, .{ .extra = try p.addExtra(Node.ParamAssign{
            .dims_start = dims.start,
            .dims_end = dims.end,
            .value = value,
            .ranges_start = ranges.start,
            .ranges_end = ranges.end,
        }) }));
        if (p.tokenTag(p.tok_i) != .comma) break;
        if (p.peek(1) == .keyword_parameter or p.peek(1) == .keyword_localparam) break;
        p.tok_i += 1;
    }
    return decl(p, .param_decl, kw, range, try p.spanFrom(top));
}

/// §3.4.6 `aliasparam alias = target ;`; §3.4.7 prints a §9.18 system
/// parameter as the target.
pub fn parseAliasparam(p: *Parse) Error!Node.Index {
    assert(p.tokenTag(p.tok_i) == .keyword_aliasparam);
    const kw = p.tok_i;
    p.tok_i += 1;
    _ = try p.expectIdent();
    _ = try p.expect(.equal);
    if (p.eat(.system_identifier) == null) _ = try p.expectIdent();
    _ = try p.expect(.semicolon);
    return p.addNode(.aliasparam_decl, kw, .{ .none = {} });
}

/// A.2.1.3 `integer|real|string|realtime|time names` or `reg
/// [discipline] [signed] [range] names`, each name `name {dim} [= expr]`,
/// without the `;`.
pub fn parseVarDecl(p: *Parse) Error!Node.Index {
    assert(p.tokenTag(p.tok_i) == .keyword_integer or p.tokenTag(p.tok_i) == .keyword_real or p.tokenTag(p.tok_i) == .keyword_string or p.tokenTag(p.tok_i) == .keyword_realtime or p.tokenTag(p.tok_i) == .keyword_time or p.tokenTag(p.tok_i) == .keyword_reg);
    const kw = p.tok_i;
    p.tok_i += 1;
    var range: Node.OptionalIndex = .none;
    if (p.tokenTag(kw) == .keyword_reg) {
        if (regDisciplineAhead(p)) p.tok_i += 1;
        _ = p.eat(.keyword_signed);
        if (p.tokenTag(p.tok_i) == .l_bracket) range = (try parseRange(p)).toOptional();
    }
    return decl(p, .var_decl, kw, range, try declarators(p, .dims_init, .comma));
}

/// `genvar names ;` (§3.5) or `event names ;` (§5.10.4).
pub fn parseNameList(p: *Parse) Error!Node.Index {
    assert(p.tokenTag(p.tok_i) == .keyword_genvar or p.tokenTag(p.tok_i) == .keyword_event);
    const kw = p.tok_i;
    p.tok_i += 1;
    const items = try declarators(p, .dims, .comma);
    _ = try p.expect(.semicolon);
    return p.addNode(if (p.tokenTag(kw) == .keyword_genvar) .genvar_decl else .event_decl, kw, .{ .extra_range = items });
}

/// A.2.8 `block_item_declaration` with its `;`: parameters, variables,
/// `reg` and events.
pub fn parseBlockDecl(p: *Parse) Error!Node.Index {
    const node = switch (p.tokenTag(p.tok_i)) {
        .keyword_parameter, .keyword_localparam => try parseParamDecl(p),
        .keyword_event => return parseNameList(p),
        else => try parseVarDecl(p),
    };
    _ = try p.expect(.semicolon);
    return node;
}

/// §3.12 `branch ( a [, b] ) names ;` or `branch ( < p > ) names ;`, each
/// name `name [range]`.
pub fn parseBranch(p: *Parse) Error!Node.Index {
    assert(p.tokenTag(p.tok_i) == .keyword_branch);
    const kw = p.tok_i;
    p.tok_i += 1;
    _ = try p.expect(.l_paren);
    var hi: Node.Index = undefined;
    var lo: Node.OptionalIndex = .none;
    if (p.eat(.angle_bracket_left)) |lt| {
        hi = try p.addNode(.port_branch, lt, .{ .node = try expr.parsePostfix(p) });
        _ = try p.expect(.angle_bracket_right);
    } else {
        hi = try expr.parsePostfix(p);
        if (p.eat(.comma) != null) lo = (try expr.parsePostfix(p)).toOptional();
    }
    _ = try p.expect(.r_paren);
    const items = try declarators(p, .range, .comma);
    _ = try p.expect(.semicolon);
    return p.addNode(.branch_decl, kw, .{ .extra = try p.addExtra(Node.Branch{ .hi = hi, .lo = lo, .items_start = items.start, .items_end = items.end }) });
}

/// A.2.1.2 `input|output|inout [discipline] [net_type|wreal] [signed]
/// [reg|integer|time [signed]] [range] names`, the variable arms `output`'s
/// only; a task or function formal takes A.2.7's types instead, and an
/// analog function formal no type but `output integer|time` (A.2.6).
pub fn parsePortDecl(p: *Parse, where: PortWhere) Error!Node.Index {
    assert(p.tokenTag(p.tok_i) == .keyword_input or p.tokenTag(p.tok_i) == .keyword_output or p.tokenTag(p.tok_i) == .keyword_inout);
    const kw = p.tok_i;
    const dir = p.tokenTag(kw);
    p.tok_i += 1;
    var variable = false;
    var range: Node.OptionalIndex = .none;
    var leading: ?Node.SubRange = null;
    switch (where) {
        .header, .body => {
            portType(p);
            switch (p.tokenTag(p.tok_i)) {
                .keyword_integer, .keyword_time, .keyword_reg => {
                    if (dir != .keyword_output) try p.warnSite(.invalid_port_declaration, .port_variable_type, p.tok_i, 0);
                    p.tok_i += 1;
                    _ = p.eat(.keyword_signed);
                    variable = true;
                },
                else => {},
            }
            if (p.tokenTag(p.tok_i) == .l_bracket) range = (try parseRange(p)).toOptional();
        },
        .tf_header, .tf_body => switch (p.tokenTag(p.tok_i)) {
            .keyword_integer, .keyword_time, .keyword_real, .keyword_realtime => p.tok_i += 1,
            else => {
                _ = p.eat(.keyword_reg);
                _ = p.eat(.keyword_signed);
                if (p.tokenTag(p.tok_i) == .l_bracket) range = (try parseRange(p)).toOptional();
            },
        },
        .analog_header, .analog_body => {
            switch (p.tokenTag(p.tok_i)) {
                .keyword_integer, .keyword_time, .keyword_real, .keyword_string, .keyword_realtime => |t| {
                    if (!(dir == .keyword_output and (t == .keyword_integer or t == .keyword_time))) try p.warnSite(.invalid_port_declaration, .port_analog_typed, p.tok_i, kw);
                    p.tok_i += 1;
                },
                else => {
                    portType(p);
                    if (p.eat(.keyword_reg) != null) _ = p.eat(.keyword_signed);
                },
            }
            // §4.7.2.3 `output [0:1] out;`: the range is the formal's array
            // dimension, every name's.
            leading = try parseDims(p);
        },
    }
    const shape: Shape = switch (where) {
        .analog_header, .analog_body => .dims,
        else => if (variable) .init else .name,
    };
    const items = switch (where) {
        .header, .tf_header, .analog_header => try declaratorsWith(p, shape, .comma_name, leading),
        .body, .tf_body, .analog_body => body: {
            const items = try declaratorsWith(p, shape, .comma, leading);
            _ = try p.expect(.semicolon);
            break :body items;
        },
    };
    return decl(p, .port_decl, kw, range, items);
}

/// A.2.1.3 net declarations: `ground [discipline] names ;`, `wreal
/// [discipline] [range] names ;`, `net_type [strength] [vectored|scalared]
/// [discipline] [signed] [range] [delay3] names ;`, or `discipline [range]
/// names ;`. One list is all `name` or all `name = expr` (§3.6.3.2); a drive
/// strength needs the assignments (IEEE 1364-2005 §4.4).
pub fn parseNetDecl(p: *Parse) Error!Node.Index {
    const first = p.tok_i;
    const tag = p.tokenTag(first);
    p.tok_i += 1;
    var drive = false;
    switch (tag) {
        .keyword_ground, .keyword_wreal => portType(p),
        .identifier, .escaped_identifier => {},
        else => {
            if (p.tokenTag(p.tok_i) == .l_paren) {
                if (prim.strengthSide(p.peek(1)) != null and p.peek(2) == .comma) {
                    try prim.parseDriveStrength(p);
                    drive = true;
                } else try prim.parseChargeStrength(p, tag == .keyword_trireg);
            }
            const advice = p.tok_i;
            const advised = p.eat(.keyword_scalared) != null or p.eat(.keyword_vectored) != null;
            const after_disc = p.tok_i + @intFromBool(p.tokenTag(p.tok_i) == .identifier and p.identLike(p.tok_i + 1));
            if (netType(p.tokenTag(after_disc)) or p.tokenTag(after_disc) == .keyword_wreal) return p.failSite(.invalid_net_declaration, .net_two_types, after_disc, 0);
            portType(p);
            if (advised and p.tokenTag(p.tok_i) != .l_bracket) return p.failSite(.invalid_net_declaration, .net_advised_no_range, advice, 0);
        },
    }
    const range: Node.OptionalIndex = if (p.tokenTag(p.tok_i) == .l_bracket) (try parseRange(p)).toOptional() else .none;
    const delay: Node.OptionalIndex = if (p.tokenTag(p.tok_i) == .hash) (try prim.parseDelay(p, 3)).toOptional() else .none;
    if (delay != .none and p.tokenTag(p.tok_i) == .l_bracket) return p.failSite(.invalid_net_declaration, .net_range_after_delay, p.tok_i, 0);
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    var assigns: ?bool = null;
    while (true) {
        const name = p.tok_i;
        // Annex F.2.1: an out-of-context `top.mid.sig`, maybe `$root.`-led.
        if (p.eat(.system_identifier) == null) _ = try p.expectIdent();
        while (p.eat(.period) != null) _ = try p.expectIdent();
        const dims = try parseDims(p);
        const init: Node.OptionalIndex = if (tag != .keyword_ground and p.eat(.equal) != null) (try expr.parseExpr(p)).toOptional() else .none;
        if (assigns) |a| if (a != (init != .none)) try p.warnSite(.invalid_net_declaration, .net_mixed_init, name, @intFromBool(init != .none));
        assigns = init != .none;
        if (drive and init == .none) return p.failSite(.invalid_net_declaration, .net_drive_no_init, name, 0);
        try p.push(try p.addNode(.declarator, name, .{ .extra_and_opt_node = .{ try p.addExtra(dims), init } }));
        if (p.eat(.comma) == null) break;
    }
    _ = try p.expect(.semicolon);
    const items = try p.spanFrom(top);
    return p.addNode(.net_decl, first, .{ .extra = try p.addExtra(Node.NetDecl{ .range = range, .delay = delay, .items_start = items.start, .items_end = items.end }) });
}

/// A.6.1 `assign [drive_strength] [delay3] lhs = rhs {, lhs = rhs} ;`.
pub fn parseContinuousAssign(p: *Parse) Error!Node.Index {
    assert(p.tokenTag(p.tok_i) == .keyword_assign);
    const kw = p.tok_i;
    p.tok_i += 1;
    if (p.tokenTag(p.tok_i) == .l_paren) try prim.parseDriveStrength(p);
    const delay: Node.OptionalIndex = if (p.tokenTag(p.tok_i) == .hash) (try prim.parseDelay(p, 3)).toOptional() else .none;
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    while (true) {
        const lhs = try expr.parseExpr(p);
        const eq = try p.expect(.equal);
        try p.push(try p.addNode(.net_assign, eq, .{ .node_and_node = .{ lhs, try expr.parseExpr(p) } }));
        if (p.eat(.comma) == null) break;
    }
    _ = try p.expect(.semicolon);
    return decl(p, .continuous_assign, kw, delay, try p.spanFrom(top));
}

/// A.2.5 `[ msb : lsb ]`.
pub fn parseRange(p: *Parse) Error!Node.Index {
    const lb = try p.expect(.l_bracket);
    const msb = try expr.parseExpr(p);
    _ = try p.expect(.colon);
    const lsb = try expr.parseExpr(p);
    _ = try p.expect(.r_bracket);
    return p.addNode(.range, lb, .{ .node_and_node = .{ msb, lsb } });
}

/// Zero or more A.2.5 dimensions, as a list of `range` nodes.
pub fn parseDims(p: *Parse) Error!Node.SubRange {
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    while (p.tokenTag(p.tok_i) == .l_bracket) try p.push(try parseRange(p));
    return p.spanFrom(top);
}

/// Whether `tag` is an A.2.2.1 `net_type`.
pub fn netType(tag: Token.Tag) bool {
    return switch (tag) {
        .keyword_wire, .keyword_tri, .keyword_tri0, .keyword_tri1, .keyword_triand, .keyword_trior, .keyword_trireg, .keyword_wand, .keyword_wor, .keyword_uwire, .keyword_supply0, .keyword_supply1 => true,
        else => false,
    };
}

// ---- private ----

fn declarators(p: *Parse, shape: Shape, cont: Continue) Error!Node.SubRange {
    return declaratorsWith(p, shape, cont, null);
}

/// `declarators`, every name without dimensions of its own taking
/// `leading` (the dimensions written before the names).
fn declaratorsWith(p: *Parse, shape: Shape, cont: Continue, leading: ?Node.SubRange) Error!Node.SubRange {
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    while (true) {
        const name = try p.expectIdent();
        const own = switch (shape) {
            .dims_init, .dims => try parseDims(p),
            .range => if (p.tokenTag(p.tok_i) == .l_bracket) try p.listToSpan(&.{@backingInt(try parseRange(p))}) else try p.listToSpan(&.{}),
            .init, .name => try p.listToSpan(&.{}),
        };
        const dims = if (leading != null and own.start == own.end) leading.? else own;
        const has_init = shape == .dims_init or shape == .init;
        const init: Node.OptionalIndex = if (has_init and p.eat(.equal) != null) (try expr.parseExpr(p)).toOptional() else .none;
        try p.push(try p.addNode(.declarator, name, .{ .extra_and_opt_node = .{ try p.addExtra(dims), init } }));
        if (p.tokenTag(p.tok_i) != .comma) break;
        if (cont == .comma_name and !p.identLike(p.tok_i + 1)) break;
        p.tok_i += 1;
    }
    return p.spanFrom(top);
}

fn decl(p: *Parse, tag: Node.Tag, kw: TokenIndex, range: Node.OptionalIndex, items: Node.SubRange) Error!Node.Index {
    return p.addNode(tag, kw, .{ .extra = try p.addExtra(Node.Decl{ .range = range, .items_start = items.start, .items_end = items.end }) });
}

/// A.2.1.2's `[ discipline_identifier ] [ net_type | wreal ] [ signed ]`;
/// a discipline is a name another name follows.
fn portType(p: *Parse) void {
    if (p.tokenTag(p.tok_i) == .identifier and p.identLike(p.tok_i + 1)) p.tok_i += 1;
    if (netType(p.tokenTag(p.tok_i)) or p.tokenTag(p.tok_i) == .keyword_wreal) p.tok_i += 1;
    _ = p.eat(.keyword_signed);
}

/// §3.4.2 `from|exclude` with `[`/`(` brackets, a bare `exclude` value, or
/// a `'{ strings }` set. `from` takes a bracket.
fn parseValueRange(p: *Parse) Error!Node.Index {
    const kw = p.tok_i;
    p.tok_i += 1;
    const open = p.tokenTag(p.tok_i);
    if (open == .apostrophe_l_brace) {
        // A.2.5 `value_range_type '{ string {, string} }`: strings only.
        const lb = p.tok_i;
        p.tok_i += 1;
        const top = p.scratch.items.len;
        defer p.scratch.shrinkRetainingCapacity(top);
        while (p.tokenTag(p.tok_i) != .r_brace) {
            const s = try p.expect(.string_literal);
            try p.push(try p.addNode(.string_literal, s, .{ .none = {} }));
            if (p.eat(.comma) == null) break;
        }
        _ = try p.expect(.r_brace);
        const lo = try p.addNode(.assign_pattern, lb, .{ .extra_range = try p.spanFrom(top) });
        return p.addNode(.value_range, kw, .{ .extra = try p.addExtra(Node.ValueRange{ .lo = lo, .hi = .none, .close = .none }) });
    }
    if (open != .l_paren and open != .l_bracket) {
        if (p.tokenTag(kw) == .keyword_from) return p.failSite(.expected_expr, .value_range_bare_from, p.tok_i, 0);
        const lo = try expr.parseExpr(p);
        return p.addNode(.value_range, kw, .{ .extra = try p.addExtra(Node.ValueRange{ .lo = lo, .hi = .none, .close = .none }) });
    }
    p.tok_i += 1;
    const lo = try expr.parseExpr(p);
    var hi: Node.OptionalIndex = .none;
    if (p.eat(.colon) != null) {
        hi = (try expr.parseExpr(p)).toOptional();
        if (p.tokenTag(p.tok_i) != .r_bracket and p.tokenTag(p.tok_i) != .r_paren) return p.fail(.expected_expr);
    } else if (p.tokenTag(p.tok_i) != .r_paren) {
        _ = try p.expect(.r_paren);
    }
    const close = p.tok_i;
    p.tok_i += 1;
    return p.addNode(.value_range, kw, .{ .extra = try p.addExtra(Node.ValueRange{ .lo = lo, .hi = hi, .close = .fromOptional(close) }) });
}

/// A `reg`'s optional discipline: a name followed by a name, `signed`, or
/// a range that a name follows (`reg r[0:3];` declares an array).
fn regDisciplineAhead(p: *const Parse) bool {
    if (!p.identLike(p.tok_i)) return false;
    var i = p.tok_i + 1;
    if (p.tokenTag(i) == .keyword_signed) return true;
    if (p.tokenTag(i) == .l_bracket) {
        var depth: u32 = 0;
        while (p.tokenTag(i) != .eof) : (i += 1) switch (p.tokenTag(i)) {
            .l_bracket => depth += 1,
            .r_bracket => {
                depth -= 1;
                if (depth == 0) break;
            },
            else => {},
        };
        if (p.tokenTag(i) == .eof) return false;
        i += 1;
    }
    return p.identLike(i);
}
