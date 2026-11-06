//! Where a Vir instruction, or a part of one (`Zcu.Part`), was written:
//! a token of the unit's tree, as the old compilers placed a report. One
//! answer for the driver (`src/next/Compilation/errors.zig`) and for the
//! oracles that compare a report's byte (diff-sim).
//! Cites no LRM clause: the reports cite theirs.
//!
//! Contents:
//! - `pub const Span = struct` (`bytes`)
//! - `pub fn inst(tree: *const Ast, vir: *const Vir, src: Inst.Ref) ?Span`
//! - `pub fn part(tree: *const Ast, vir: *const Vir, src: Inst.Ref, p: Zcu.Part) ?Span`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const Zcu = @import("../Zcu.zig");
const Ast = vams.Ast;
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Token = Ast.TokenIndex;

/// A report's place: a token, its whole text or (`point`) its first byte.
pub const Span = struct {
    token: Token,
    point: bool = false,

    /// The span's byte range in the tree's source.
    pub fn bytes(s: Span, tree: *const Ast) struct { start: u32, end: u32 } {
        const at = tree.tokenStart(s.token);
        return .{ .start = at, .end = if (s.point) at else at + @as(u32, @intCast(tree.tokenSlice(s.token).len)) };
    }
};

/// Where instruction `src` was written, as the old compiler located it: a
/// statement `<+` at its target's first byte, a call at its callee's name,
/// anything else at its main token; null for none or a literal.
pub fn inst(tree: *const Ast, vir: *const Vir, src: Inst.Ref) ?Span {
    const i = src.toIndex() orelse return null;
    const tag = vir.instructions.items(.tag)[@backingInt(i)];
    if (tag == .contrib or tag == .contrib_indirect) {
        const at_payload = vir.instructions.items(.data)[@backingInt(i)].pl_node.payload_index;
        const lhs = if (tag == .contrib) vir.extraData(Inst.Bin, at_payload).lhs else vir.extraData(Inst.Triple, at_payload).a;
        return .{ .token = instToken(tree, vir, lhs) orelse return null, .point = true };
    }
    return .{ .token = instToken(tree, vir, src) orelse return null };
}

/// Where part `p` of instance `src` was written, as the old elaborators
/// located it: the first token of its k-th connection or parameter value
/// (a named one's `.`; `value` its expression), a defparam's target name
/// or value,
/// an attribute spec's name; the instruction itself for `.whole`, or when
/// the part cannot be found.
pub fn part(tree: *const Ast, vir: *const Vir, src: Inst.Ref, p: Zcu.Part) ?Span {
    const k: u32, const list_open: ?Token = switch (p) {
        .whole => return inst(tree, vir, src),
        .target => return .{ .token = target(tree, vir, src) orelse return inst(tree, vir, src) },
        .scaled => return .{ .token = scaled(tree, vir, src) orelse return inst(tree, vir, src) },
        .rule => |k| return .{ .token = rule(tree, vir, src, k) orelse return inst(tree, vir, src), .point = true },
        .rhs => {
            const eq = instToken(tree, vir, src) orelse return null;
            return if (tree.tokenTag(eq) == .equal) .{ .token = eq + 1 } else inst(tree, vir, src);
        },
        .attr => |k| return .{ .token = attr(tree, vir, src, k) orelse return inst(tree, vir, src) },
        .conn => |k| .{ k, connOpen(tree, vir, src) },
        .param, .value => |k| .{ k, paramOpen(tree, vir, src) },
    };
    var t = itemStart(tree, list_open orelse return inst(tree, vir, src), k) orelse return inst(tree, vir, src);
    if (p == .value and tree.tokenTag(t) == .period) t += 3;
    return .{ .token = t };
}

// ---- private ----

/// The token instruction `ref` names: its main token, or for a call (whose
/// main token is its `(`) the callee's name; null for a literal.
fn instToken(tree: *const Ast, vir: *const Vir, ref: Inst.Ref) ?Token {
    const i = ref.toIndex() orelse return null;
    const data = vir.instructions.items(.data)[@backingInt(i)];
    const tok: Token = switch (Inst.dataKind(vir.instructions.items(.tag)[@backingInt(i)])) {
        .pl_node => tree.nodeMainToken(data.pl_node.src_node),
        .un_node => tree.nodeMainToken(data.un_node.src_node),
        .decl_tok => data.decl_tok.src_tok,
        .str_tok => data.str_tok.src_tok,
        .int, .float, .str => return null,
    };
    return if (tok > 0 and tree.tokenTag(tok) == .l_paren) tok - 1 else tok;
}

/// A defparam's target name (the lhs before its `=`), from its first
/// token; null when `src` is not one.
fn target(tree: *const Ast, vir: *const Vir, src: Inst.Ref) ?Token {
    const eq = instToken(tree, vir, src) orelse return null;
    if (tree.tokenTag(eq) != .equal) return null;
    var t = eq;
    var depth: u32 = 0;
    // Bounded by `eq`: each turn moves one token back.
    while (t > 0) : (t -= 1) switch (tree.tokenTag(t - 1)) {
        .r_bracket => depth += 1,
        .l_bracket => depth -|= 1,
        .comma, .keyword_defparam => if (depth == 0) break,
        else => {},
    };
    return t;
}

/// The name of the k-th attribute spec in the `(* ... *)` instances just
/// before the declaration or instance `src` (no `;` between); null when
/// there is none.
fn attr(tree: *const Ast, vir: *const Vir, src: Inst.Ref, k: u32) ?Token {
    var t = instToken(tree, vir, src) orelse return null;
    // Bounded by `t`: back to the last `*)` before the item.
    while (t > 0 and tree.tokenTag(t) != .asterisk_r_paren) : (t -= 1) {
        if (tree.tokenTag(t) == .semicolon) return null;
    }
    if (t == 0) return null;
    // Back over the run of instances, to the first `(*`.
    var first = t;
    // Bounded by `t`: each turn moves one token back.
    while (first > 0) : (first -= 1) {
        if (tree.tokenTag(first) == .l_paren_asterisk and (first == 0 or tree.tokenTag(first - 1) != .asterisk_r_paren)) break;
    }
    var n: u32 = 0;
    var depth: u32 = 0;
    var i = first;
    // Bounded by `t`: each turn moves one token on.
    while (i < t) : (i += 1) switch (tree.tokenTag(i)) {
        .l_paren_asterisk => if (n == k) return i + 1,
        .asterisk_r_paren => n += 1,
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) {
            n += 1;
            if (n == k) return i + 1;
        },
        else => {},
    };
    return null;
}

/// The first token of configuration `src`'s k-th rule: the statement after
/// its `config name;` and its `design` statement; null past `endconfig`.
fn rule(tree: *const Ast, vir: *const Vir, src: Inst.Ref, k: u32) ?Token {
    var t = instToken(tree, vir, src) orelse return null;
    var semis: u32 = 0;
    // Bounded by the token count: each turn moves one token on.
    while (tree.tokenTag(t) != .eof and tree.tokenTag(t) != .keyword_endconfig) : (t += 1) {
        if (tree.tokenTag(t) != .semicolon) continue;
        semis += 1;
        if (semis == k + 2) return t + 1;
    }
    return null;
}

/// The first number literal with a §2.6.2 scale factor (`2u`) in instance
/// `src`'s `#(...)`, or null.
fn scaled(tree: *const Ast, vir: *const Vir, src: Inst.Ref) ?Token {
    const open = paramOpen(tree, vir, src) orelse return null;
    var t = open + 1;
    var depth: u32 = 0;
    // Bounded by the token count: each turn moves one token on.
    while (tree.tokenTag(t) != .eof) : (t += 1) switch (tree.tokenTag(t)) {
        .l_paren => depth += 1,
        .r_paren => if (depth == 0) return null else {
            depth -= 1;
        },
        .number_literal => {
            const text = tree.tokenSlice(t);
            if (std.mem.findScalar(u8, "TGMKkmunpfa", text[text.len - 1]) != null and std.mem.findScalar(u8, text, '\'') == null) return t;
        },
        else => {},
    };
    return null;
}

/// The `instance` node of Vir instance `src`, or null.
fn instanceNode(tree: *const Ast, vir: *const Vir, src: Inst.Ref) ?Ast.Node.Index {
    const i = src.toIndex() orelse return null;
    if (vir.instructions.items(.tag)[@backingInt(i)] != .instance) return null;
    const n = vir.instructions.items(.data)[@backingInt(i)].pl_node.src_node;
    return if (tree.nodeTag(n) == .instance) n else null;
}

/// The `(` of instance `src`'s connection list: past its name and range.
fn connOpen(tree: *const Ast, vir: *const Vir, src: Inst.Ref) ?Token {
    const n = instanceNode(tree, vir, src) orelse return null;
    var t = tree.nodeMainToken(n) + 1;
    var depth: u32 = 0;
    // Bounded by the token count: each turn moves one token on.
    while (tree.tokenTag(t) != .eof) : (t += 1) switch (tree.tokenTag(t)) {
        .l_bracket => depth += 1,
        .r_bracket => depth -|= 1,
        .l_paren => if (depth == 0) return t,
        else => {},
    };
    return null;
}

/// The `(` after `#` of the instantiation that lists instance `src`, or
/// of connect statement `src` (§7.7.3).
fn paramOpen(tree: *const Ast, vir: *const Vir, src: Inst.Ref) ?Token {
    const n = instanceNode(tree, vir, src) orelse {
        const i = src.toIndex() orelse return null;
        if (vir.instructions.items(.tag)[@backingInt(i)] != .connect_insert) return null;
        var t = instToken(tree, vir, src) orelse return null;
        // Bounded by the token count: each turn moves one token on.
        while (tree.tokenTag(t) != .semicolon and tree.tokenTag(t) != .eof) : (t += 1) {
            if (tree.tokenTag(t) == .hash and tree.tokenTag(t + 1) == .l_paren) return t + 1;
        }
        return null;
    };
    const tags = tree.nodes.items(.tag);
    // Bounded by the node count; a refusal's location only.
    for (tags, 0..) |tag, j| if (tag == .module_instantiation) {
        const m: Ast.Node.Index = @fromBackingInt(@intCast(j));
        const x = tree.extraData(tree.nodeData(m).extra, Ast.Node.Instantiation);
        for (tree.extraDataSlice(.{ .start = x.items_start, .end = x.items_end }, Ast.Node.Index)) |it| if (it == n) {
            const hash = tree.nodeMainToken(m) + 1;
            return if (tree.tokenTag(hash) == .hash and tree.tokenTag(hash + 1) == .l_paren) hash + 1 else null;
        };
    };
    return null;
}

/// The first token of item `k` of the comma list that `open` opens, past
/// its attribute instances; null past the list's end.
fn itemStart(tree: *const Ast, open: Token, k: u32) ?Token {
    assert(tree.tokenTag(open) == .l_paren);
    var t = open + 1;
    var n: u32 = 0;
    var depth: u32 = 0;
    // Bounded by the token count: each turn moves one token on.
    while (tree.tokenTag(t) != .eof) : (t += 1) {
        if (n == k and depth == 0) {
            // Bounded by the token count, past `(* ... *)` runs.
            while (tree.tokenTag(t) == .l_paren_asterisk) {
                while (tree.tokenTag(t) != .asterisk_r_paren and tree.tokenTag(t) != .eof) t += 1;
                if (tree.tokenTag(t) == .eof) return null;
                t += 1;
            }
            return t;
        }
        switch (tree.tokenTag(t)) {
            .l_paren, .l_bracket, .l_brace, .l_paren_asterisk => depth += 1,
            .r_paren, .r_bracket, .r_brace, .asterisk_r_paren => if (depth == 0) return null else {
                depth -= 1;
            },
            .comma => n += @intFromBool(depth == 0),
            else => {},
        }
    }
    return null;
}
