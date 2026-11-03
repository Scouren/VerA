//! Spec examples of `Ast.parse`: VAMS text in, the tree's shape or its
//! first error out, each case citing the clause it reads. Ported from the
//! old parser's tests (tests/unit/parser_tests.zig and lib/frontend/parser
//! test blocks), adapted to a tree that folds and resolves nothing.
//! Cites: the clauses each test names.
//!
//! Contents: tests only.

const std = @import("std");
const Ast = @import("../Ast.zig");
const full = Ast.full;
const testing = std.testing;

// ---- private ----

/// Parses `src` and returns the tree; the caller deinits it.
fn parseOk(src: [:0]const u8, keywords: Ast.KeywordSet) !Ast {
    var tree = try Ast.parse(testing.allocator, src, .{ .keywords = keywords });
    errdefer tree.deinit(testing.allocator);
    if (tree.errors.len != 0) {
        std.debug.print("unexpected {t} at `{s}`\n", .{ tree.errors[0].tag, tree.tokenSlice(tree.errors[0].token) });
        return error.ParseFailed;
    }
    return tree;
}

/// The first error `src` parses with.
fn firstError(src: [:0]const u8, keywords: Ast.KeywordSet) !Ast.Error.Tag {
    var tree = try Ast.parse(testing.allocator, src, .{ .keywords = keywords });
    defer tree.deinit(testing.allocator);
    if (tree.errors.len == 0) return error.ParsedClean;
    return tree.errors[0].tag;
}

test "a resistor module: header ports, discipline, parameter with a range, contribution (§3.4.2, §5.6)" {
    var tree = try parseOk(
        \\module r(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real R = 1k from (0:inf);
        \\  analog I(p, n) <+ V(p, n) / R;
        \\endmodule
    , .vams_2023);
    defer tree.deinit(testing.allocator);
    const m = full.moduleDecl(&tree, tree.rootDecls()[0]);
    try testing.expectEqualStrings("r", tree.tokenSlice(m.name));
    try testing.expectEqual(2, m.ports.len);
    const tags = [_]Ast.Node.Tag{ .port_decl, .net_decl, .param_decl, .analog };
    try testing.expectEqual(tags.len, m.items.len);
    for (tags, m.items) |want, item| try testing.expectEqual(want, tree.nodeTag(item));
}
