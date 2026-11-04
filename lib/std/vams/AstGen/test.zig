//! AstGen's spec examples: small sources in, their Vir dump (goldens whose
//! expected text was written by hand from the source) or their per-file
//! codes out. The oracle for the corpus is `tests/differential/astgen.zig`.
//! Cites the clause each test names.
//!
//! Contents: tests only.

const std = @import("std");
const Ast = @import("../Ast.zig");
const Vir = @import("../Vir.zig");
const AstGen = @import("../AstGen.zig");
const Diag = @import("../Diag.zig");

// ---- private ----

fn gen(src: [:0]const u8) !Vir {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, src, .{});
    defer tree.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    return AstGen.generate(gpa, &tree, .{});
}

fn dump(src: [:0]const u8) ![]u8 {
    const gpa = std.testing.allocator;
    var vir = try gen(src);
    defer vir.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try Vir.print.render(&vir, &out.writer);
    return out.toOwnedSlice();
}

/// The codes `src`'s Vir reports, in source order.
fn codes(src: [:0]const u8) ![]Diag.Code {
    const gpa = std.testing.allocator;
    var vir = try gen(src);
    defer vir.deinit(gpa);
    const out = try gpa.alloc(Diag.Code, vir.diag.count());
    for (vir.diag.messages(), out) |m, *c| c.* = vir.diag.message(m).tag.code;
    return out;
}

fn expectCodes(src: [:0]const u8, want: []const Diag.Code) !void {
    const got = try codes(src);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualSlices(Diag.Code, want, got);
}

test "§6.2 the declaration table lists every design unit in source order" {
    const gpa = std.testing.allocator;
    var vir = try gen(
        \\nature N; abstol = 1; endnature
        \\discipline D; potential N; enddiscipline
        \\module m; endmodule
        \\paramset p m; parameter real x = 1; endparamset
        \\connectmodule c(a); input a; endmodule
    );
    defer vir.deinit(gpa);
    const d = vir.decls();
    try std.testing.expectEqual(@as(usize, 5), d.len);
    const kinds = [_]Vir.Decl.Kind{ .nature, .discipline, .module, .paramset, .connectmodule };
    const names = [_][]const u8{ "N", "D", "m", "p", "c" };
    for (d, kinds, names) |row, k, n| {
        try std.testing.expectEqual(k, row.kind);
        try std.testing.expectEqualStrings(n, vir.string(row.name));
    }
}

test "a local name resolves to its declaration; another file's name stays a string" {
    const out = try dump(
        \\module m(p);
        \\  inout p; electrical p;
        \\  analog V(p) <+ x;
        \\  real x;
        \\endmodule
    );
    defer std.testing.allocator.free(out);
    // Declarations are reserved by the scope's scan (%1-%3), so `x`, used
    // before its declaration, still resolves (%9 -> %3); `V` is an access
    // function another file's nature defines, a string.
    try std.testing.expectEqualStrings(
        \\module "m" %0
        \\%0 = module(name="m", flags=.{kind=.module, ansi=false}, stamp=.{flags=.{nettype=.wire, drive=.float, celldefine=false, has_timescale=false, has_transition=false}, unit=0e0, precision=0e0, transition=0e0}, params={}, ports={
        \\  %5 = port(name="p", value={
        \\    %4 = decl_ref(%1)
        \\  })
        \\}, body={
        \\  %1 = io(name="p", prev=none, flags=.{dir=.inout, net=.none, storage=.none, signed=false, header=false}, discipline="", range={}, dims={}, init={}, defaults=[], attrs=[])
        \\  %2 = net(name="p", prev=%1, flags=.{net=.none, signed=false, vectored=false, scalared=false}, discipline="electrical", strength="", range={}, dims={}, delay=.{body={}, values=[]}, init={}, defaults=[], attrs=[])
        \\  %11 = analog(body={
        \\    %6 = str_ref("V")
        \\    %7 = decl_ref(%1)
        \\    %8 = call(callee=%6, args=[%7])
        \\    %9 = decl_ref(%3)
        \\    %10 = contrib(lhs=%8, rhs=%9)
        \\  })
        \\  %3 = variable(name="x", prev=none, flags=.{storage=.real, signed=false}, discipline="", range={}, dims={}, init={}, attrs=[])
        \\})
        \\
    , out);
}

test "IEEE 1364-2005 Annex B `string` is a variable's name under 1364-2005, not its type" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "module m; reg string; endmodule\n", .{ .keywords = .v1364_2005 });
    defer tree.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    var vir = try AstGen.generate(gpa, &tree, .{});
    defer vir.deinit(gpa);
    var seen: u32 = 0;
    for (vir.instructions.items(.tag), vir.instructions.items(.data)) |t, d| if (t == .variable) {
        const v = vir.extraData(Vir.Inst.Variable, d.pl_node.payload_index);
        try std.testing.expectEqualStrings("string", vir.string(v.name));
        try std.testing.expectEqual(Vir.Inst.Storage.reg, v.flags.storage);
        seen += 1;
    };
    try std.testing.expectEqual(@as(u32, 1), seen);
}

test "IEEE 1364-2005 §12.4.3 an unnamed generate block is genblk<n>, zero-padded past a clash" {
    const gpa = std.testing.allocator;
    var vir = try gen(
        \\module m;
        \\  parameter p = 1;
        \\  wire genblk2;
        \\  if (p) begin wire a; end
        \\  if (p) begin wire b; end
        \\endmodule
    );
    defer vir.deinit(gpa);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    for (vir.instructions.items(.tag), vir.instructions.items(.data)) |t, d| if (t == .gen_block) {
        try names.append(gpa, vir.string(vir.extraData(Vir.Inst.GenBlock, d.pl_node.payload_index).name));
    };
    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("genblk1", names.items[0]);
    try std.testing.expectEqualStrings("genblk02", names.items[1]);
}

test "IEEE 1364-2005 §12.4.3 every arm of one generate construct shares its genblk<n>" {
    // Oracle: the LRM's example (and iverilog): `genblk02` names the `if`
    // and the `else` arm alike, the zeros added past the explicit
    // `genblk2` only, never past a sibling arm's own name.
    const gpa = std.testing.allocator;
    var vir = try gen(
        \\module m;
        \\  parameter genblk2 = 0;
        \\  if (1) begin wire a; end
        \\  if (genblk2) begin wire b; end else begin wire c; end
        \\endmodule
    );
    defer vir.deinit(gpa);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    for (vir.instructions.items(.tag), vir.instructions.items(.data)) |t, d| if (t == .gen_block) {
        try names.append(gpa, vir.string(vir.extraData(Vir.Inst.GenBlock, d.pl_node.payload_index).name));
    };
    try std.testing.expectEqual(@as(usize, 3), names.items.len);
    try std.testing.expectEqualStrings("genblk1", names.items[0]);
    try std.testing.expectEqualStrings("genblk02", names.items[1]);
    try std.testing.expectEqualStrings("genblk02", names.items[2]);
}

test "§6.5.2 E0218 a port declared twice, E0206 a declaration of no header port, E0376 a port with no direction" {
    try expectCodes("module m(a, b); input a; output a; input c; endmodule", &.{ .E0376, .E0218, .E0206 });
    try expectCodes("module m(input a); wire a; endmodule", &.{.E0218});
    try expectCodes("module m(input a); electrical a; endmodule", &.{});
}

test "A.4.2 E0238 a loop generate index that is no genvar; §6.6.2 E0230 a block name clash" {
    try expectCodes("module m; integer i; for (i = 0; i < 2; i = i + 1) begin end endmodule", &.{.E0238});
    try expectCodes("module m; genvar i; for (i = 0; i < 2; i = i + 1) begin : g end endmodule", &.{});
    try expectCodes("module m; genvar i; wire g; for (i = 0; i < 2; i = i + 1) begin : g end endmodule", &.{.E0230});
    try expectCodes("module m; parameter p = 1; if (p) begin : g end else begin : g end endmodule", &.{});
    try expectCodes("module m; parameter p = 1; if (p) begin : g end if (p) begin : g end endmodule", &.{.E0230});
}

test "A.8.4 E0295 a min:typ:max in an analog expression, not in a parameter" {
    try expectCodes("module m; real x; analog x = (1:2:3); endmodule", &.{.E0295});
    try expectCodes("module m; parameter real a = (1:2:3); endmodule", &.{});
}

test "§4.7.1 E0225 an analog function formal with no data type" {
    try expectCodes("module m; analog function real f; input x; f = x; endfunction endmodule", &.{.E0225});
    try expectCodes("module m; analog function real f; input x; real x; f = x; endfunction endmodule", &.{});
}

test "§3.4.7 E0373 an expression reads an aliasparam" {
    try expectCodes("module m; parameter real p = 1; aliasparam q = p; real x; analog x = q; endmodule", &.{.E0373});
    try expectCodes("module m; parameter real p = 1; aliasparam q = p; real x; analog x = p; endmodule", &.{});
}

test "§3.7 E0918 a wreal driven twice" {
    try expectCodes("module m; wreal w; assign w = 1.0; assign w = 2.0; endmodule", &.{.E0918});
    try expectCodes("module m; wreal w; assign w = 1.0; endmodule", &.{});
}

test "IEEE 1364-2005 §8.1.1 E1100 and §8.1.4 E0248 on a UDP" {
    try expectCodes(
        \\primitive u(q, a); output q; input a;
        \\table 0 : 1; 0 : 0; endtable endprimitive
    , &.{.E0248});
    try expectCodes(
        \\primitive u(a, q); input a; output q;
        \\table 0 : 1; endtable endprimitive
    , &.{.E1100});
}

test "IEEE 1364-2005 §14.2.1 E0245 a path source that is not an input" {
    try expectCodes("module m(a, q); input a; output q; specify (q => a) = 1; endspecify endmodule", &.{ .E0245, .E0245 });
    try expectCodes("module m(a, q); input a; output q; specify (a => q) = 1; endspecify endmodule", &.{});
}

test "generating twice gives the same bytes" {
    const gpa = std.testing.allocator;
    const src =
        \\module m(a, b); input a; output b; electrical a, b;
        \\  parameter real r = 1 from (0:inf);
        \\  genvar i;
        \\  for (i = 0; i < 2; i = i + 1) begin : g wire w; end
        \\  analog begin : blk real t; t = r * V(a); I(b) <+ t; end
        \\endmodule
    ;
    const a = try dump(src);
    defer gpa.free(a);
    const b = try dump(src);
    defer gpa.free(b);
    try std.testing.expectEqualStrings(a, b);
}

test "IEEE 1364-2005 §12.3.3 one direction declaration covers every port reference to its name" {
    // A port named twice took its direction only at its first reference,
    // so E0376 fired on the second (the corpus's select_and_concatenation_ports.v).
    try expectCodes("module m(a[7:4], a[3:0]); input [7:0] a; endmodule", &.{});
    try expectCodes("module m(.a(i), .b(i)); inout i; endmodule", &.{});
    try expectCodes("module m(a, a); input a; endmodule", &.{});
    try expectCodes("module m({c, d}, .e(f)); input [1:0] c, d; output [3:0] f; endmodule", &.{});
    try expectCodes("module m(a, a); endmodule", &.{ .E0376, .E0376 });
}
