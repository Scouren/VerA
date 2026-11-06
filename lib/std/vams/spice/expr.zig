//! A SPICE `{expr}` / `'expr'` value in, its real value over the
//! subcircuit's `PARAMS:` out (as Verilog-AMS text), or the reason it is
//! refused. Recursive descent whose every recursive rule passes through
//! `unary`, so one depth counter bounds the native stack (lib/TODO.md §11.2:
//! a fixed cap with its own refusal).
//! Cites: LRM annex E.1.2 (VerA's claimed subset of HSPICE expressions).
//!
//! Contents:
//! - `pub const Expr = union(enum)`
//! - `pub const depth_max: u32`
//! - `pub fn expression(arena: Allocator, src: []const u8, scope: []const []const u8) Allocator.Error!Expr`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const card = @import("card.zig");
const spiceNumber = card.spiceNumber;
const spell = card.spell;

/// What `expression` makes of a SPICE expression.
pub const Expr = union(enum) {
    /// Verilog-AMS source with the same value.
    text: []const u8,
    /// Why it is not read, to follow "the expression value `{...}`".
    refused: []const u8,
};

/// `unary` levels (parentheses, calls, signs, power operands) an expression
/// may nest before it is refused. Each level is five native frames; 1024
/// keeps the deepest input far inside an 8 MiB stack in Debug.
pub const depth_max: u32 = 1024;

/// The functions a SPICE expression may call: each means the same in HSPICE
/// and ngspice as in §4.3.1-4.3.2 (`log`, natural in SPICE and base 10 here,
/// is not one).
const expr_fns = [_][]const u8{ "sqrt", "exp", "abs", "min", "max", "pow", "sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh", "floor", "ceil" };

/// `expression`'s recursive descent. Each rule returns its Verilog-AMS
/// text, or null with `why` set.
const Parser = struct {
    arena: Allocator,
    src: []const u8,
    scope: []const []const u8,
    i: usize = 0,
    why: ?[]const u8 = null,
    /// `unary` frames open; every recursive rule passes through `unary`.
    depth: u32 = 0,

    fn refuse(p: *Parser, comptime fmt: []const u8, args: anytype) Allocator.Error!?[]const u8 {
        assert(p.i <= p.src.len);
        if (p.why == null) p.why = try p.arena.print(fmt, args);
        assert(p.why != null);
        return null;
    }

    fn skip(p: *Parser) void {
        assert(p.i <= p.src.len);
        while (p.i < p.src.len and (p.src[p.i] == ' ' or p.src[p.i] == '\t')) p.i += 1;
        assert(p.i <= p.src.len);
    }

    /// Consumes `tok` after blanks when it is next. `*` is not taken from
    /// the front of a `**`.
    fn eat(p: *Parser, tok: []const u8) bool {
        assert(tok.len != 0);
        p.skip();
        if (!std.mem.startsWith(u8, p.src[p.i..], tok)) return false;
        if (std.mem.eql(u8, tok, "*") and std.mem.startsWith(u8, p.src[p.i..], "**")) return false;
        p.i += tok.len;
        assert(p.i <= p.src.len);
        return true;
    }

    /// sum := product (('+' | '-') product)*
    fn sum(p: *Parser) Allocator.Error!?[]const u8 {
        const i_in = p.i;
        defer assert(p.i >= i_in);
        var acc = try p.product() orelse return null;
        // Each round consumes an operator, so the loop ends by `src.len`.
        while (true) {
            const op: []const u8 = if (p.eat("+")) "+" else if (p.eat("-")) "-" else return acc;
            const rhs = try p.product() orelse return null;
            acc = try p.arena.print("({s} {s} {s})", .{ acc, op, rhs });
        }
    }

    /// product := unary (('*' | '/') unary)*
    fn product(p: *Parser) Allocator.Error!?[]const u8 {
        const i_in = p.i;
        defer assert(p.i >= i_in);
        var acc = try p.unary() orelse return null;
        while (true) {
            const op: []const u8 = if (p.eat("*")) "*" else if (p.eat("/")) "/" else return acc;
            const rhs = try p.unary() orelse return null;
            acc = try p.arena.print("({s} {s} {s})", .{ acc, op, rhs });
        }
    }

    /// unary := ('+' | '-') unary | power
    fn unary(p: *Parser) Allocator.Error!?[]const u8 {
        assert(p.depth <= depth_max);
        if (p.depth == depth_max) return p.refuse("nests more than {d} levels deep", .{depth_max});
        p.depth += 1;
        defer p.depth -= 1;
        if (p.eat("-")) return try p.arena.print("(-{s})", .{try p.unary() orelse return null});
        if (p.eat("+")) return p.unary();
        return p.power();
    }

    /// power := atom ('**' unary)?
    fn power(p: *Parser) Allocator.Error!?[]const u8 {
        assert(p.depth > 0);
        const base = try p.atom() orelse return null;
        if (!p.eat("**")) return base;
        return try p.arena.print("({s} ** {s})", .{ base, try p.unary() orelse return null });
    }

    /// atom := number | name | function '(' sum (',' sum)* ')' | '(' sum ')'
    fn atom(p: *Parser) Allocator.Error!?[]const u8 {
        assert(p.depth > 0);
        p.skip();
        if (p.i == p.src.len) return p.refuse("ends before an operand", .{});
        const c = p.src[p.i];
        if (c == '(') {
            p.i += 1;
            const e = try p.sum() orelse return null;
            if (!p.eat(")")) return p.refuse("has a `(` with no `)`", .{});
            return e;
        }
        if (std.ascii.isDigit(c) or c == '.') return p.number();
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = p.i;
            while (p.i < p.src.len and (std.ascii.isAlphanumeric(p.src[p.i]) or p.src[p.i] == '_')) p.i += 1;
            const name = p.src[start..p.i];
            if (p.eat("(")) return p.call(name);
            for (p.scope) |s| if (std.mem.eql(u8, s, name)) return try spell(p.arena, name);
            return p.refuse("reads `{s}`, which names no parameter in scope (the subcircuit's PARAMS: before it; a `.param` is not read)", .{name});
        }
        return p.refuse("has `{c}`, which is not read", .{c});
    }

    /// A number at `i`, its scale letter and unit letters with it, as a
    /// real literal.
    fn number(p: *Parser) Allocator.Error!?[]const u8 {
        const start = p.i;
        while (p.i < p.src.len and (std.ascii.isDigit(p.src[p.i]) or p.src[p.i] == '.')) p.i += 1;
        assert(p.i > start);
        // A complete exponent only, as `spiceNumber` reads one.
        if (p.i + 1 < p.src.len and p.src[p.i] == 'e') {
            var j = p.i + 1;
            if (p.src[j] == '+' or p.src[j] == '-') j += 1;
            if (j < p.src.len and std.ascii.isDigit(p.src[j])) {
                while (j < p.src.len and std.ascii.isDigit(p.src[j])) j += 1;
                p.i = j;
            }
        }
        while (p.i < p.src.len and std.ascii.isAlphabetic(p.src[p.i])) p.i += 1;
        const v = spiceNumber(p.src[start..p.i]) orelse return p.refuse("has `{s}`, which is not a number", .{p.src[start..p.i]});
        return try p.arena.print("{e}", .{v});
    }

    /// The call of `name`, its `(` consumed: `name(a, b, ...)`.
    fn call(p: *Parser, name: []const u8) Allocator.Error!?[]const u8 {
        assert(name.len != 0);
        for (expr_fns) |f| {
            if (std.mem.eql(u8, f, name)) break;
        } else return p.refuse("calls `{s}`, which is not one of sqrt, exp, abs, min, max, pow, sin, cos, tan, asin, acos, atan, sinh, cosh, tanh, floor, ceil", .{name});
        var args: std.ArrayList(u8) = .empty;
        // Each argument consumes text, so the loop ends by `src.len`.
        while (true) {
            const a = try p.sum() orelse return null;
            if (args.items.len != 0) try args.appendSlice(p.arena, ", ");
            try args.appendSlice(p.arena, a);
            if (p.eat(",")) continue;
            if (p.eat(")")) break;
            return p.refuse("has a `{s}(` with no `)`", .{name});
        }
        return try p.arena.print("{s}({s})", .{ name, args.items });
    }
};

/// Returns a SPICE expression (the inside of `{...}` or `'...'`) as
/// Verilog-AMS text on `arena`. Read: numbers in SPICE's scaled notation,
/// written as real literals (`1k` is `1e3`, and `1/3` is a third, not
/// §4.2.1's integer 0); the names in `scope`, a subcircuit's parameters;
/// `+ - * /`; `**`, HSPICE's power; unary `+` and `-`; parentheses; and the
/// `expr_fns` calls. Power binds tighter than a unary minus on its left
/// (`-2**2` is -4), and every operation is parenthesized, so the grammar's
/// precedence is the text's. Anything else (`.param` names, `^`,
/// comparisons, `?:`, other functions, nesting past `depth_max`) is refused.
pub fn expression(arena: Allocator, src: []const u8, scope: []const []const u8) Allocator.Error!Expr {
    var p: Parser = .{ .arena = arena, .src = src, .scope = scope };
    const text = try p.sum() orelse return .{ .refused = p.why.? };
    // Every `unary` frame closed on the way out.
    assert(p.depth == 0);
    p.skip();
    if (p.i != src.len) return .{ .refused = try arena.print("has `{s}` after a complete expression", .{src[p.i..]}) };
    return .{ .text = text };
}

// ---- private ----

/// Requires every `want` in `text`.
fn expectHas(text: []const u8, wants: []const []const u8) !void {
    for (wants) |want| if (std.mem.find(u8, text, want) == null) {
        std.debug.print("missing: {s}\n in:\n{s}\n", .{ want, text });
        return error.TestUnexpectedResult;
    };
}

fn expressionOne(_: void, s: *std.testing.Smith) anyerror!void {
    const words = [_][]const u8{ "w", "1", "1k", "2e3", ".5", "(", ")", "+", "-", "*", "/", "**", "max", "sqrt", "log", ",", " ", "_x", "#", "'" };
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    while (!s.eos()) w.writeAll(words[s.index(words.len)]) catch break;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    switch (try expression(arena_state.allocator(), w.buffered(), &.{"w"})) {
        // Every operation is parenthesized: the text's parentheses balance.
        .text => |t| try std.testing.expectEqual(std.mem.count(u8, t, "("), std.mem.count(u8, t, ")")),
        .refused => |why| try std.testing.expect(why.len != 0),
    }
}

test "SPICE expressions: real arithmetic, power over a unary minus, and what is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Case = struct { []const u8, []const u8 };
    for ([_]Case{
        // `1/3` is a third: §4.2.1 would make `1 / 3` an integer 0.
        .{ "1/3", "(1e0 / 3e0)" },
        .{ "-2**2", "(-(2e0 ** 2e0))" },
        .{ "2**-1", "(2e0 ** (-1e0))" },
        .{ "max(1k, w)*2", "(max(1e3, w) * 2e0)" },
        .{ " w - 1u - 2 ", "((w - 1e-6) - 2e0)" },
    }) |c| try std.testing.expectEqualStrings(c[1], (try expression(arena, c[0], &.{"w"})).text);
    for ([_][]const u8{ "log(2)", "w^2", "v", "1 +", "(w", "w ? 1 : 2" }) |bad|
        try std.testing.expect((try expression(arena, bad, &.{"w"})) == .refused);
}

test "SPICE expressions name what they refuse, and nesting stops at depth_max" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Case = struct { []const u8, []const u8 };
    for ([_]Case{
        .{ "1 2", "has `2` after a complete expression" },
        .{ "foo(1)", "calls `foo`" },
        .{ "max(1, 2", "has a `max(` with no `)`" },
        .{ "(1", "has a `(` with no `)`" },
        .{ "", "ends before an operand" },
        .{ "1 +", "ends before an operand" },
        .{ "#", "has `#`, which is not read" },
        .{ "q", "reads `q`, which names no parameter in scope" },
    }) |c| {
        const got = try expression(arena, c[0], &.{"w"});
        try std.testing.expect(got == .refused);
        try expectHas(got.refused, &.{c[1]});
    }
    try std.testing.expectEqualStrings("1e0", (try expression(arena, "+1", &.{})).text);
    try std.testing.expectEqualStrings("(2e0 ** (3e0 ** 2e0))", (try expression(arena, "2**3**2", &.{})).text);
    // 257 parentheses was one past the old code's first cap; depth_max - 1
    // is the deepest read (the outer `sum` holds one `unary` level too).
    for ([_]usize{ 257, depth_max - 1 }) |n| {
        const buf = try arena.alloc(u8, 2 * n + 1);
        @memset(buf[0..n], '(');
        buf[n] = '1';
        @memset(buf[n + 1 ..], ')');
        try std.testing.expectEqualStrings("1e0", (try expression(arena, buf, &.{})).text);
    }
    const deep = try arena.alloc(u8, 2 * depth_max + 1);
    @memset(deep[0..depth_max], '(');
    deep[depth_max] = '1';
    @memset(deep[depth_max + 1 ..], ')');
    try expectHas((try expression(arena, deep, &.{})).refused, &.{"nests more than 1024 levels deep"});
    // Signs build one `(-...)` per level.
    const signs = try arena.alloc(u8, 1001);
    @memset(signs[0..1000], '-');
    signs[1000] = '1';
    const got = (try expression(arena, signs, &.{})).text;
    try std.testing.expect(std.mem.startsWith(u8, got, "(-(-"));
    try std.testing.expectEqual(@as(usize, 1000), std.mem.count(u8, got, "(-"));
}

test "fuzz: a SPICE expression is read or refused with a reason, never a panic" {
    try std.testing.fuzz({}, expressionOne, .{});
}
