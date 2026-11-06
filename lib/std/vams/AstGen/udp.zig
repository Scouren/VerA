//! The UDP rules a file can judge alone: a `udp_decl` in, its diagnostics
//! out. IEEE 1364-2005 §8.1.1 "exactly one output, and it is the first
//! port" (E1100, as the old compiler's analysis spine reported it) and
//! §8.1.4 "the same combination of inputs, including edges, specified for
//! different outputs" (E0248), ported from the old parser's table check.
//! Cites: IEEE 1364-2005 §8.1.1, §8.1.4, §8.8, Table 8-1, A.5.3.
//!
//! Contents:
//! - `pub fn rowText(arena: Allocator, tree: *const Ast, entry: Node.Index) Allocator.Error![]const u8`
//! - `pub fn check(ag: *AstGen, node: Node.Index) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Ast = @import("../Ast.zig");
const AstGen = @import("../AstGen.zig");
const Node = Ast.Node;
const Error = AstGen.Error;
const full = Ast.full;

/// One input column of an entry: a level set (bits 0, 1, x) or an edge set
/// (bit `3 * from + to`).
const Field = union(enum) { level: u3, edge: u9 };

/// One parsed entry: input columns, current state (0 when combinational),
/// output.
const Row = struct { inputs: []const u8, state: u8, output: u8 };

/// A table entry's symbols without white space: `inputs : [state :] out`.
pub fn rowText(arena: Allocator, tree: *const Ast, entry: Node.Index) Allocator.Error![]const u8 {
    assert(tree.nodeTag(entry) == .udp_entry);
    const semi = tree.nodeData(entry).token;
    var buf: std.ArrayList(u8) = .empty;
    var i = tree.nodeMainToken(entry);
    while (i < semi) : (i += 1) try buf.appendSlice(arena, tree.tokenSlice(i));
    return buf.items;
}

/// Reports §8.1.1 and §8.1.4 on UDP `node`.
pub fn check(ag: *AstGen, node: Node.Index) Error!void {
    const tree = ag.tree;
    const u = tree.extraData(tree.nodeData(node).extra, Node.Udp);
    const ports = tree.extraDataSlice(.{ .start = u.ports_start, .end = u.ports_end }, Node.Index);
    const items = tree.extraDataSlice(.{ .start = u.items_start, .end = u.items_end }, Node.Index);
    assert(ports.len >= 2); // the parser refuses fewer
    const kw = tree.nodeMainToken(node);
    // §8.1.1: the outputs, from the header's and the body's declarations.
    var outputs: u32 = 0;
    var output: ?[]const u8 = null;
    for (ports) |p| {
        const t = tree.nodeMainToken(p);
        if (headerOutput(tree, t)) {
            outputs += 1;
            output = AstGen.identText(tree, t);
        }
    }
    for (items) |it| if (tree.nodeTag(it) == .port_decl and tree.tokenTag(tree.nodeMainToken(it)) == .keyword_output) for (full.decl(tree, it).items) |d| {
        outputs += 1;
        output = AstGen.identText(tree, tree.nodeMainToken(d));
    };
    const first = AstGen.identText(tree, tree.nodeMainToken(ports[0]));
    const is_first = std.mem.eql(u8, output orelse "", first);
    if (outputs != 1 or !is_first) {
        // Both old routes pointed at the keyword's first byte; the digital
        // one said which half failed.
        const at = tree.tokenStart(kw);
        var b = ag.wip.build(.parse, .E1100, .{ .file = .root, .start = at, .end = at });
        if (!ag.options.ieee1364) {
            b.msg("§8.1.1: a UDP has exactly one output port, and it is the first port", .{});
        } else if (outputs != 1) {
            b.msg("§8.1.1: a UDP has exactly one output port", .{});
        } else b.msg("§8.1.1: the output port shall be the first port of a UDP", .{});
        try b.emit();
    }

    for (items) |it| if (tree.nodeTag(it) == .udp_table) try conflicts(ag, kw, full.list(tree, it), ports.len - 1);
}

// ---- private ----

/// Whether the header port named at `t` is declared `output` in the header.
fn headerOutput(tree: *const Ast, t: Ast.TokenIndex) bool {
    var i = t;
    while (i > 0) {
        i -= 1;
        switch (tree.tokenTag(i)) {
            .keyword_output => return true,
            .keyword_reg, .identifier, .escaped_identifier => {},
            else => return false, // else: the `(` or `,` before the port
        }
    }
    return false;
}

/// §8.1.4: two entries that overlap on every input (and the current state)
/// and give different next states, `-` reading as the current state. A
/// level entry and an edge entry never conflict (§8.8), nor do edge
/// entries on different inputs. O(rows²), as the old check. Reported at
/// `kw`, the `primitive` keyword, naming the UDP after it.
fn conflicts(ag: *AstGen, kw: Ast.TokenIndex, entries: []const Node.Index, inputs: usize) Error!void {
    const rows = try ag.arena.alloc(Row, entries.len);
    var sequential = false;
    for (entries, rows, 0..) |e, *r, k| {
        const text = try rowText(ag.arena, ag.tree, e);
        var cols = std.mem.splitScalar(u8, text, ':');
        const in = cols.first();
        const second = cols.next() orelse "";
        const third = cols.next();
        if (k == 0) sequential = third != null;
        r.* = .{ .inputs = in, .state = if (third != null and second.len != 0) second[0] else 0, .output = if (third) |o| (if (o.len != 0) o[0] else '0') else (if (second.len != 0) second[0] else '0') };
    }
    const a_buf = try ag.arena.alloc(Field, inputs);
    const b_buf = try ag.arena.alloc(Field, inputs);
    for (rows, 0..) |a, i| {
        if (fields(a.inputs, a_buf) != inputs) continue;
        for (rows[i + 1 ..], i + 1..) |b, j| {
            if (fields(b.inputs, b_buf) != inputs) continue;
            const overlap = for (a_buf, b_buf) |fa, fb| {
                const meet = switch (fa) {
                    .level => |la| switch (fb) {
                        .level => |lb| la & lb != 0,
                        .edge => false,
                    },
                    .edge => |ea| switch (fb) {
                        .level => false,
                        .edge => |eb| ea & eb != 0,
                    },
                };
                if (!meet) break false;
            } else true;
            if (!overlap) continue;
            const states: u3 = if (sequential) levelSet(a.state) & levelSet(b.state) else 0b001;
            for (0..3) |s| {
                if (states & (@as(u3, 1) << @intCast(s)) == 0) continue;
                const cur = "01x"[s];
                const out_a = if (a.output == '-') cur else std.ascii.toLower(a.output);
                const out_b = if (b.output == '-') cur else std.ascii.toLower(b.output);
                if (out_a == out_b) continue;
                try ag.report(.E0248, kw, "`{s}`: entries {d} and {d} share an input combination and give it {c} and {c}", .{ AstGen.identText(ag.tree, kw + 1), i + 1, j + 1, out_a, out_b });
                break;
            }
        }
    }
}

fn levelSet(c: u8) u3 {
    return switch (std.ascii.toLower(c)) {
        '0' => 0b001,
        '1' => 0b010,
        'x' => 0b100,
        'b' => 0b011,
        else => 0b111, // else: `?`, the only other level symbol A.5.3 admits
    };
}

/// Table 8-1's transitions between two level sets, a change only.
fn edgeSet(from: u3, to: u3) u9 {
    var set: u9 = 0;
    for (0..3) |f| for (0..3) |t| {
        if (f != t and from & (@as(u3, 1) << @intCast(f)) != 0 and to & (@as(u3, 1) << @intCast(t)) != 0)
            set |= @as(u9, 1) << @intCast(3 * f + t);
    };
    return set;
}

/// Splits an entry's input symbols into `out`, one field per input;
/// returns the field count, past `out.len` when there are more.
fn fields(inputs: []const u8, out: []Field) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < inputs.len) : (i += 1) {
        const f: Field = switch (std.ascii.toLower(inputs[i])) {
            '(' => blk: {
                if (i + 3 >= inputs.len) return out.len + 1;
                defer i += 3;
                break :blk .{ .edge = edgeSet(levelSet(inputs[i + 1]), levelSet(inputs[i + 2])) };
            },
            'r' => .{ .edge = edgeSet(0b001, 0b010) },
            'f' => .{ .edge = edgeSet(0b010, 0b001) },
            // (01) (0x) (x1), and (10) (1x) (x0).
            'p' => .{ .edge = edgeSet(0b001, 0b110) | edgeSet(0b100, 0b010) },
            'n' => .{ .edge = edgeSet(0b010, 0b101) | edgeSet(0b100, 0b001) },
            '*' => .{ .edge = edgeSet(0b111, 0b111) },
            else => .{ .level = levelSet(inputs[i]) }, // else: a level symbol
        };
        if (n == out.len) return n + 1;
        out[n] = f;
        n += 1;
    }
    return n;
}
