//! IEEE 1364-2005 §14.2-§14.3's module path rules that need the module's
//! ports and drivers (E0245): the module's `path_decl`s and `check.Facts`
//! in, diagnostics out. Ported from the old parser's `checkPaths`, which
//! ran them once the module was parsed.
//! - §14.2.1: a source is an input or inout port, a destination an output
//!   or inout port with one driver per bit inside the module.
//! - §14.2.3/§14.2.5: a parallel path joins terminals of one width; an
//!   edge-sensitive one's destination is scalar or a bit-select.
//! - §14.3: a path delay is constant (reads no variable, net or port).
//! - §14.2.4.3/§14.2.4.4: one edge-sensitive path references each port the
//!   same way; no `ifnone` beside an unconditional path.
//! Cites: IEEE 1364-2005 §14.2.1, §14.2.3, §14.2.4.3, §14.2.4.4, §14.2.5,
//! §14.3.
//!
//! Contents:
//! - `pub fn check(ag: *AstGen, f: *const check.Facts) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("../Ast.zig");
const AstGen = @import("../AstGen.zig");
const check_file = @import("check.zig");
const number_literal = @import("../number_literal.zig");
const Node = Ast.Node;
const Error = AstGen.Error;
const Facts = check_file.Facts;

/// How a terminal names its port (§14.2.4.3).
const Reference = enum { whole, bit, part };

/// One path as the rules read it.
const PathView = struct {
    node: Node.Index,
    tok: Ast.TokenIndex,
    full: bool,
    ifnone: bool,
    cond: Node.OptionalIndex,
    data: Node.OptionalIndex,
    ins: []const Node.Index,
    outs: []const Node.Index,
    delays: []const Node.Index,
};

/// The bound on an expression walk, past the parser's own depth cap.
const max_walk = 1 << 20;

/// Reports every E0245 over the module's paths.
pub fn check(ag: *AstGen, f: *const Facts) Error!void {
    const tree = ag.tree;
    const views = try ag.arena.alloc(PathView, f.path_decls.items.len);
    for (f.path_decls.items, views) |n, *v| {
        const p = tree.extraData(tree.nodeData(n).extra, Node.Path);
        v.* = .{
            .node = n,
            .tok = tree.nodeMainToken(n),
            .full = tree.tokenTag(p.arrow) == .asterisk_angle_bracket_right,
            .ifnone = tree.tokenTag(tree.nodeMainToken(n)) == .keyword_ifnone,
            .cond = p.cond,
            .data = p.data_source,
            .ins = tree.extraDataSlice(.{ .start = p.inputs_start, .end = p.inputs_end }, Node.Index),
            .outs = tree.extraDataSlice(.{ .start = p.outputs_start, .end = p.outputs_end }, Node.Index),
            .delays = tree.extraDataSlice(.{ .start = p.delays_start, .end = p.delays_end }, Node.Index),
        };
    }
    for (views, 0..) |p, i| {
        for (p.ins) |t| {
            const port = portNamed(f, terminalName(tree, t));
            if (port == null or (port.?.dir != .input and port.?.dir != .inout))
                try ag.report(.E0245, tree.nodeMainToken(t), "module path source `{s}` is not an input or inout port (§14.2.1)", .{terminalName(tree, t)});
        }
        for (p.outs) |t| {
            const n = terminalName(tree, t);
            const port = portNamed(f, n);
            if (port == null or (port.?.dir != .output and port.?.dir != .inout))
                try ag.report(.E0245, tree.nodeMainToken(t), "module path destination `{s}` is not an output or inout port (§14.2.1)", .{n});
            if (try sharedDriver(ag, f, n)) try ag.report(.E0245, tree.nodeMainToken(t), "module path destination `{s}` has more than one driver on a bit; §14.2.1 allows only one driver inside the module", .{n});
        }
        if (!p.full) {
            const src = p.ins[0];
            const dst = p.outs[0];
            if (p.data != .none) {
                if (reference(tree, dst) != .bit and (terminalWidth(tree, f, dst) orelse 1) != 1)
                    try ag.report(.E0245, tree.nodeMainToken(dst), "the destination of a parallel edge-sensitive path is a scalar port or a bit-select (§14.2.3)", .{});
            } else if (terminalWidth(tree, f, src)) |ws| if (terminalWidth(tree, f, dst)) |wd| if (ws != wd)
                try ag.report(.E0245, p.tok, "a parallel path joins terminals of the same number of bits (§14.2.5), not {d} and {d}", .{ ws, wd });
        }
        for (p.delays) |d| if (try readsSignal(ag, f, d)) |at|
            try ag.report(.E0245, tree.nodeMainToken(at), "a module path delay is a constant expression (§14.3); `{s}` is a signal", .{AstGen.identText(tree, tree.nodeMainToken(at))});
        for (views[0..i]) |q| {
            if (p.data != .none and q.data != .none and p.ins.len == 1 and q.ins.len == 1 and p.outs.len == 1 and q.outs.len == 1 and
                std.mem.eql(u8, terminalName(tree, p.ins[0]), terminalName(tree, q.ins[0])) and std.mem.eql(u8, terminalName(tree, p.outs[0]), terminalName(tree, q.outs[0])) and
                (reference(tree, p.ins[0]) != reference(tree, q.ins[0]) or reference(tree, p.outs[0]) != reference(tree, q.outs[0])))
                try ag.report(.E0245, p.tok, "a port is referenced in the same way in all declarations of one edge-sensitive path (§14.2.4.3)", .{});
            if (p.ifnone != q.ifnone and p.data == .none and q.data == .none and samePath(tree, p, q) and
                (if (p.ifnone) q.cond == .none else p.cond == .none))
                try ag.report(.E0245, p.tok, "an ifnone path and an unconditional path for the same module path (§14.2.4.4)", .{});
        }
    }
}

// ---- private ----

fn portNamed(f: *const Facts, n: []const u8) ?check_file.Port {
    return f.ports.items[f.port_index.get(n) orelse return null];
}

/// The name a terminal or driver target references, a select's base; ""
/// for any other shape.
fn terminalName(tree: *const Ast, t: Node.Index) []const u8 {
    const base = switch (tree.nodeTag(t)) {
        .index => tree.nodeData(t).node_and_node[0],
        .range_select, .indexed_select_up, .indexed_select_down => tree.nodeData(t).node_and_extra[0],
        else => t, // else: the terminal itself
    };
    return if (tree.nodeTag(base) == .identifier) AstGen.identText(tree, tree.nodeMainToken(base)) else "";
}

fn reference(tree: *const Ast, t: Node.Index) Reference {
    return switch (tree.nodeTag(t)) {
        .index => .bit,
        .range_select, .indexed_select_up, .indexed_select_down => .part,
        else => .whole, // else: an unselected name
    };
}

/// A literal integer node's value, or null.
fn literal(tree: *const Ast, n: Node.Index) ?i128 {
    if (tree.nodeTag(n) != .number_literal) return null;
    return switch (number_literal.parseNumberLiteral(tree.tokenSlice(tree.nodeMainToken(n)))) {
        .int => |int| if (number_literal.intValue(int)) |v| v else null,
        else => null, // else: a real or malformed literal has no integer value
    };
}

fn rangeWidth(tree: *const Ast, msb: Node.Index, lsb: Node.Index) ?u64 {
    const a = literal(tree, msb) orelse return null;
    const b = literal(tree, lsb) orelse return null;
    return std.math.cast(u64, @abs(a - b) + 1);
}

/// A terminal's width when its port's range and its select are literal.
fn terminalWidth(tree: *const Ast, f: *const Facts, t: Node.Index) ?u64 {
    switch (tree.nodeTag(t)) {
        .index => return 1,
        .range_select => {
            const pair = tree.extraData(tree.nodeData(t).node_and_extra[1], Node.Pair);
            return rangeWidth(tree, pair.a, pair.b);
        },
        .indexed_select_up, .indexed_select_down => {
            const pair = tree.extraData(tree.nodeData(t).node_and_extra[1], Node.Pair);
            return std.math.cast(u64, literal(tree, pair.b) orelse return null);
        },
        else => {}, // else: an unselected port, its declared range below
    }
    const n = terminalName(tree, t);
    const p = portNamed(f, n) orelse return null;
    const r = p.range.unwrap() orelse f.type_ranges.get(n) orelse return 1;
    return rangeWidth(tree, tree.nodeData(r).node_and_node[0], tree.nodeData(r).node_and_node[1]);
}

/// The bits a driver target selects when literal; null for the whole.
fn driverBits(tree: *const Ast, t: Node.Index) ?[2]i128 {
    switch (tree.nodeTag(t)) {
        .index => {
            const v = literal(tree, tree.nodeData(t).node_and_node[1]) orelse return null;
            return .{ v, v };
        },
        .range_select => {
            const pair = tree.extraData(tree.nodeData(t).node_and_extra[1], Node.Pair);
            const a = literal(tree, pair.a) orelse return null;
            const b = literal(tree, pair.b) orelse return null;
            return .{ @min(a, b), @max(a, b) };
        },
        else => return null, // else: the whole signal, or a select that does not fold
    }
}

fn bitsOverlap(a: ?[2]i128, b: ?[2]i128) bool {
    const x = a orelse return true;
    const y = b orelse return true;
    return x[0] <= y[1] and y[0] <= x[1];
}

/// Two drivers of `n` (continuous assignments, then gate outputs) that
/// overlap on a bit.
fn sharedDriver(ag: *AstGen, f: *const Facts, n: []const u8) Error!bool {
    const tree = ag.tree;
    const all = try std.mem.concat(ag.arena, Node.Index, &.{ f.assigns.items, f.gate_outs.items });
    for (all, 0..) |dj, j| {
        if (!std.mem.eql(u8, terminalName(tree, dj), n)) continue;
        for (all[0..j]) |dk| if (std.mem.eql(u8, terminalName(tree, dk), n) and bitsOverlap(driverBits(tree, dj), driverBits(tree, dk))) return true;
    }
    return false;
}

fn samePath(tree: *const Ast, p: PathView, q: PathView) bool {
    if (p.full != q.full or p.ins.len != q.ins.len or p.outs.len != q.outs.len) return false;
    for (p.ins, q.ins) |a, b| if (!std.mem.eql(u8, terminalName(tree, a), terminalName(tree, b))) return false;
    for (p.outs, q.outs) |a, b| if (!std.mem.eql(u8, terminalName(tree, a), terminalName(tree, b))) return false;
    return true;
}

/// The first identifier in delay `e` that names a variable, net or port,
/// walked with an explicit stack, leftmost operand first.
fn readsSignal(ag: *AstGen, f: *const Facts, e: Node.Index) Error!?Node.Index {
    const tree = ag.tree;
    var stack: std.ArrayList(Node.Index) = .empty;
    try stack.append(ag.arena, e);
    var steps: u32 = 0;
    while (stack.pop()) |n| {
        steps += 1;
        assert(steps <= max_walk);
        const d = tree.nodeData(n);
        var kids: [3]Node.Index = undefined;
        const len: usize = switch (tree.nodeTag(n)) {
            .identifier => {
                const name = AstGen.identText(tree, tree.nodeMainToken(n));
                if (f.vars.contains(name) or f.nets.contains(name) or f.port_index.contains(name)) return n;
                continue;
            },
            .grouped => one: {
                kids[0] = d.node_and_token[0];
                break :one 1;
            },
            .unary => one: {
                kids[0] = d.node;
                break :one 1;
            },
            .binary, .index => two: {
                kids[0..2].* = d.node_and_node;
                break :two 2;
            },
            .mintypmax => three: {
                const m = tree.extraData(d.node_and_extra[1], Node.MinTypMax);
                kids = .{ d.node_and_extra[0], m.typ, m.max };
                break :three 3;
            },
            .ternary => three: {
                const t = tree.extraData(d.node_and_extra[1], Node.Ternary);
                kids = .{ d.node_and_extra[0], t.then, t.@"else" };
                break :three 3;
            },
            else => continue, // else: literals, calls and the rest read no plain name of their own
        };
        var k = len;
        while (k > 0) {
            k -= 1;
            try stack.append(ag.arena, kids[k]);
        }
    }
    return null;
}
