//! Elaboration's spec examples: small sources in, their instance tree (one
//! `path module` line per instance, depth first) or their codes out. Each
//! expected tree is written by hand from the clause it cites; the oracle
//! for the corpus is `tests/differential/elab.zig`.
//!
//! Contents: tests only.

const std = @import("std");
const vams = @import("vams");
const Zcu = @import("../Zcu.zig");
const Sema = @import("../Sema.zig");
const Diag = vams.Diag;

/// What one elaboration gave: the tree as text and the codes, in order.
const Out = struct {
    arena: std.heap.ArenaAllocator,
    tree: []const u8,
    codes: []const Diag.Code,
    /// Distinct instance keys: the analyses the design needs.
    keys: usize,

    fn deinit(o: *Out) void {
        o.arena.deinit();
    }
};

// ---- private ----

fn elab(src: [:0]const u8, config: Sema.Config) !Out {
    return elabUnder(src, config, &.{}, 0);
}

fn elabUnder(src: [:0]const u8, config: Sema.Config, defaults: []const vams.Preprocessor.events.DefaultDiscipline, builtins: u32) !Out {
    const gpa = std.testing.allocator;
    var out: Out = .{ .arena = .init(gpa), .tree = "", .codes = &.{}, .keys = 0 };
    errdefer out.arena.deinit();
    const arena = out.arena.allocator();
    var ast = try vams.Ast.parse(gpa, src, .{});
    defer ast.deinit(gpa);
    if (ast.errors.len != 0) std.debug.print("parse error {t} at token {d}\n", .{ ast.errors[0].tag, ast.errors[0].token });
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    var vir = try vams.AstGen.generate(gpa, &ast, .{ .directives = .{ .disciplines = defaults } });
    defer vir.deinit(gpa);
    var zcu: Zcu = try .init(gpa);
    defer zcu.deinit();
    _ = try zcu.addFile("test.va", vir, builtins);
    try Sema.elaborate(&zcu, config);
    var text: std.Io.Writer.Allocating = .init(arena);
    for (0..zcu.instances.len) |k| {
        const i: Zcu.Instance.Index = @fromBackingInt(@intCast(k));
        const d = zcu.instances.items(.module)[k];
        try text.writer.print("{f} {s}", .{ zcu.fmtPath(i), zcu.fileVir(d.file).string(zcu.declRow(d).name) });
        const ps = zcu.instances.items(.paramset)[k];
        if (!std.meta.eql(ps, Zcu.Decl.none)) try text.writer.print(" (paramset row {d})", .{@backingInt(ps.index)});
        try text.writer.writeByte('\n');
    }
    out.tree = text.written();
    out.codes = try arena.dupe(Diag.Code, zcu.failed.items(.code));
    out.keys = zcu.instance_map.count();
    return out;
}

/// `expectCodes` with `default_discipline <discipline>` in force from the
/// first byte (§10.2).
fn expectCodesUnder(src: [:0]const u8, default: []const u8, want: []const Diag.Code) !void {
    var o = try elabUnder(src, .{}, &.{.{ .at = 0, .qualifier = null, .discipline = default }}, 0);
    defer o.deinit();
    try std.testing.expectEqualSlices(Diag.Code, want, o.codes);
}

/// `elab` with the file's first module shipped (Annex E), as the prelude's
/// Table E.1 primitives are.
fn elabBuiltins(src: [:0]const u8) !Out {
    return elabUnder(src, .{}, &.{}, 1);
}

fn expectTree(src: [:0]const u8, config: Sema.Config, want: []const u8) !void {
    var o = try elab(src, config);
    defer o.deinit();
    try std.testing.expectEqualStrings(want, o.tree);
    try std.testing.expectEqualSlices(Diag.Code, &.{}, o.codes);
}

fn expectCodes(src: [:0]const u8, config: Sema.Config, want: []const Diag.Code) !void {
    var o = try elab(src, config);
    defer o.deinit();
    try std.testing.expectEqualSlices(Diag.Code, want, o.codes);
}

/// The tree of `src` elaborated under a library map: `libs[k]` the library
/// of declaration row `k` (null: `work`), `order` the search order.
fn treeUnderMap(src: [:0]const u8, libs: []const ?[]const u8, order: []const []const u8) ![]u8 {
    const gpa = std.testing.allocator;
    var ast = try vams.Ast.parse(gpa, src, .{});
    defer ast.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    var vir = try vams.AstGen.generate(gpa, &ast, .{});
    defer vir.deinit(gpa);
    var zcu: Zcu = try .init(gpa);
    defer zcu.deinit();
    const file = try zcu.addFile("test.v", vir, 0);
    for (libs, 0..) |lib, k| if (lib) |l| {
        try zcu.decl_lib.put(gpa, .{ .file = file, .index = @fromBackingInt(@intCast(k)) }, try zcu.intern_pool.getString(gpa, l));
    };
    var interned: [4]@import("intern_pool").String = undefined;
    for (order, 0..) |l, k| interned[k] = try zcu.intern_pool.getString(gpa, l);
    zcu.lib_order = interned[0..order.len];
    try Sema.elaborate(&zcu, .{});
    try std.testing.expectEqualSlices(Diag.Code, &.{}, zcu.failed.items(.code));
    var text: std.Io.Writer.Allocating = .init(gpa);
    errdefer text.deinit();
    for (0..zcu.instances.len) |k| {
        const d = zcu.instances.items(.module)[k];
        try text.writer.print("{f} {s}.{s}\n", .{ zcu.fmtPath(@fromBackingInt(@intCast(k))), zcu.libraryOf(d), zcu.fileVir(d.file).string(zcu.declRow(d).name) });
    }
    return text.toOwnedSlice();
}

test "§6.2.2 the root is the module nothing instantiates, whatever the source order; children depth first" {
    try expectTree(
        \\module kid(a); inout a; endmodule
        \\module mid(a); inout a; kid k1(a); kid k2(a); endmodule
        \\module top(p); inout p; mid m1(p); kid k(p); endmodule
    , .{},
        \\top top
        \\top.m1 mid
        \\top.m1.k1 kid
        \\top.m1.k2 kid
        \\top.k kid
        \\
    );
}

test "IEEE 1364-2005 §12.1.1 every uninstantiated module is a root; a device takes the first" {
    const src =
        \\module a; endmodule
        \\module b; a u(); endmodule
        \\module c; endmodule
    ;
    try expectTree(src, .{}, "b b\nb.u a\nc c\n");
    try expectTree(src, .{ .roots = .first }, "b b\nb.u a\n");
}

test "§6.2.2 an instance array is one instance per element, lowest index first" {
    try expectTree(
        \\module kid; endmodule
        \\module top; parameter n = 2; kid u[n:1](); kid v[0:0](); endmodule
    , .{}, "top top\ntop.u[1] kid\ntop.u[2] kid\ntop.v[0] kid\n");
}

test "§6.6 generate schemes unroll with genvars as constants; IEEE 1364-2005 §12.4.3 names the scopes" {
    try expectTree(
        \\module kid; parameter k = 0; endmodule
        \\module top;
        \\  parameter n = 3;
        \\  genvar i;
        \\  for (i = 0; i < n; i = i + 1) begin : blk
        \\    kid u();
        \\  end
        \\  if (n > 2) kid hi(); else kid lo();
        \\  case (n) 1: kid one(); 3: begin : three kid t(); end default: kid other(); endcase
        \\endmodule
    , .{},
        \\top top
        \\top.blk[0].u kid
        \\top.blk[1].u kid
        \\top.blk[2].u kid
        \\top.genblk2.hi kid
        \\top.three.t kid
        \\
    );
}

test "§6.3 overrides fold into the instance key: equal tuples are one analysis" {
    var o = try elab(
        \\module kid; parameter real g = 1.0; parameter integer n = 2; endmodule
        \\module top; kid #(.g(2.0)) a(); kid #(2.0, 2) b(); kid c(); kid #(.n(2.5)) d(); endmodule
    , .{});
    defer o.deinit();
    try std.testing.expectEqual(@as(usize, 0), o.codes.len);
    try std.testing.expectEqualStrings("top top\ntop.a kid\ntop.b kid\ntop.c kid\ntop.d kid\n", o.tree);
    // `top`; `a` and `b` (g 2.0, n 2); `c` (the defaults); `d` (2.5 rounds
    // to the integer 3, §4.2.1.1).
    try std.testing.expectEqual(@as(usize, 4), o.keys);
}

test "§6.3.1 a defparam reaches down the tree and from the root; the last in the source wins (IEEE 1364-2005 §12.2.1)" {
    try expectTree(
        \\module leaf; parameter w = 1; genvar i; for (i = 0; i < w; i = i + 1) begin : g kid k(); end endmodule
        \\module kid; endmodule
        \\module mid; leaf l(); defparam l.w = 2; endmodule
        \\module top; mid m(); defparam top.m.l.w = 3; endmodule
    , .{},
        \\top top
        \\top.m mid
        \\top.m.l leaf
        \\top.m.l.g[0].k kid
        \\top.m.l.g[1].k kid
        \\top.m.l.g[2].k kid
        \\
    );
}

test "§6.3 an override naming no parameter is E0907; one given twice is E0908; an unknown module is E0904" {
    try expectCodes(
        \\module kid; parameter a = 1; localparam b = 2; endmodule
        \\module top; kid #(.zz(1)) u1(); kid #(.b(1)) u2(); kid #(1, 2) u3(); kid #(.a(1), .a(2)) u4(); nosuch u5(); endmodule
    , .{}, &.{ .E0907, .E0907, .E0907, .E0908, .E0904 });
}

test "§6.2.2 a recursion that repeats a key is E0905; one a generate scheme ends elaborates" {
    try expectCodes(
        \\module a; b u(); endmodule
        \\module b; a v(); endmodule
        \\module top; a x(); endmodule
    , .{}, &.{.E0905});
    try expectTree(
        \\module r; parameter n = 2; if (n > 0) r #(n - 1) u(); endmodule
        \\module top; r t(); endmodule
    , .{}, "top top\ntop.t r\ntop.t.genblk1.u r\ntop.t.genblk1.u.genblk1.u r\n");
}

test "§6.4.2 a paramset is selected by its ranges and tie-breaks to the fewest un-overridden parameters" {
    var o = try elab(
        \\module dev; parameter real l = 1; parameter real w = 1; endmodule
        \\paramset nch dev; parameter real l = 1 from [0:10); parameter real w = 1; .l = l; .w = w; endparamset
        \\paramset nch dev; parameter real l = 10 from [10:inf); .l = l; endparamset
        \\paramset nch dev; parameter real l = 1 from [0:inf); parameter real w = 1 from [0:inf); parameter real ad = 0; .l = l; .w = w; endparamset
        \\module top; nch #(.l(20)) long(); nch #(.l(2), .w(3)) short(); endmodule
    , .{});
    defer o.deinit();
    // `long`: rows 2 and 3 admit l = 20; row 2 leaves none un-overridden,
    // row 3 two. `short`: rows 1 and 3 admit; row 1 leaves none.
    try std.testing.expectEqualStrings("top top\ntop.long dev (paramset row 2)\ntop.short dev (paramset row 1)\n", o.tree);
    try std.testing.expectEqual(@as(usize, 0), o.codes.len);
}

test "§6.4.2 no admitting paramset is E0911" {
    try expectCodes(
        \\module dev; parameter real l = 1; endmodule
        \\paramset nch dev; parameter real l = 1 from [0:10); .l = l; endparamset
        \\module top; nch #(.l(20)) u(); endmodule
    , .{}, &.{.E0911});
}

test "§6.5.5 a connection list is all ordered or all named, no longer than the ports, each port once (E0906)" {
    try expectCodes(
        \\module kid(a, b); inout a, b; endmodule
        \\module top(p, n); inout p, n;
        \\  kid u1(p, n, n); kid u2(p, .b(n)); kid u3(.a(p), n); kid u4(.zz(p)); kid u5(.a(p), .a(n));
        \\  kid ok1(p, n); kid ok2(.b(n), .a(p)); kid ok3(p);
        \\endmodule
    , .{}, &.{ .E0906, .E0906, .E0906, .E0906, .E0906 });
}

test "§9.18 Table 9-29 composes the hierarchical system parameters; one outside its domain is E0890" {
    try expectTree(
        \\module leaf; endmodule
        \\module kid; if ($mfactor > 5 && $angle == 30) leaf big(); endmodule
        \\module mid; kid #(.$mfactor(3), .$angle(10)) k(); endmodule
        \\module top; mid #(.$mfactor(2), .$angle(380 - 360)) m(); endmodule
    , .{}, "top top\ntop.m mid\ntop.m.k kid\ntop.m.k.genblk1.big leaf\n");
    try expectCodes(
        \\module kid; endmodule
        \\module top; kid #(.$angle(360)) a(); kid #(.$mfactor(0)) b(); kid #(.$hflip(2)) c(); kid #(.$vflip(-1)) d(); endmodule
    , .{}, &.{ .E0890, .E0890, .E0890 });
}

test "A.2.1.3 a net names a declared discipline (E0371); a module defined again is W1152" {
    try expectCodes(
        \\discipline ca; domain continuous; enddiscipline
        \\module top(p); inout p; ca p; kid c1; nowhere n; endmodule
        \\module kid(a); inout a; ca a; endmodule
        \\module kid(a); inout a; ca a; endmodule
    , .{}, &.{ .W1152, .E0371, .E0371 });
}

test "§3.4.2 a paramset range's first bound is below its second (E0347)" {
    try expectCodes(
        \\module dev; parameter real l = 1; endmodule
        \\paramset p dev; parameter real l = 1 from [10:2); .l = l; endparamset
        \\paramset p dev; parameter real l = 1 from [2:10); .l = l; endparamset
        \\module top; endmodule
    , .{}, &.{.E0347});
}

test "§7.7 a connect statement names a connect module (E0915) and one discrete, one continuous discipline (E0923); Table 7-2 (E0982)" {
    try expectCodes(
        \\discipline el; potential V; enddiscipline
        \\nature V; access = V; endnature
        \\discipline dg; domain discrete; enddiscipline
        \\connectmodule cm(a, d); input a; output d; el a; dg d; endmodule
        \\connectmodule bad(a, d); input a; input d; el a; dg d; endmodule
        \\module plain(a); input a; endmodule
        \\connectrules r; connect cm; connect plain; connect nowhere; connect cm el, el; connect bad; connect el, dg resolveto nothing; endconnectrules
        \\module top; endmodule
    , .{}, &.{ .E0915, .E0915, .E0923, .E0982, .E0916 });
}

test "§7.8.4 a mixed port gets a connect module in its upper connection's module: merged by default, one per port when split (§7.8.5 names)" {
    const src =
        \\nature V; access = V; endnature
        \\discipline ca; potential V; enddiscipline
        \\discipline dd; domain discrete; enddiscipline
        \\module top; ca a; din u1(a); din u2(a); endmodule
        \\connectmodule a2d(el, cm); input el; output cm; ca el; dd cm; endmodule
        \\module din(d); input d; dd d; endmodule
        \\connectrules r; connect a2d{s}; endconnectrules
    ;
    var buf: [1024]u8 = undefined;
    try expectTree(try std.mem.printSentinel(&buf, src, .{""}, 0), .{}, "top top\ntop.u1 din\ntop.u2 din\ntop.a__a2d__dd a2d\n");
    try expectTree(try std.mem.printSentinel(&buf, src, .{" split"}, 0), .{}, "top top\ntop.u1 din\ntop.u2 din\ntop.a__u1__d a2d\ntop.a__u2__d a2d\n");
}

test "§7.8.4 a mixed port no statement bridges is E0927; one two statements match is E0922" {
    try expectCodes(
        \\nature V; access = V; endnature
        \\discipline ca; potential V; enddiscipline
        \\discipline dd; domain discrete; enddiscipline
        \\module top; ca a; din u1(a); endmodule
        \\module din(d); output d; dd d; endmodule
        \\connectmodule a2d(el, cm); input el; output cm; ca el; dd cm; endmodule
        \\connectrules r; connect a2d; endconnectrules
    , .{}, &.{.E0927});
    try expectCodes(
        \\nature V; access = V; endnature
        \\discipline ca; potential V; enddiscipline
        \\discipline dd; domain discrete; enddiscipline
        \\module top; ca a; din u1(a); endmodule
        \\module din(d); input d; dd d; endmodule
        \\connectmodule a2d(el, cm); input el; output cm; ca el; dd cm; endmodule
        \\connectmodule b2d(el, cm); input el; output cm; ca el; dd cm; endmodule
        \\connectrules r; connect a2d; connect b2d; endconnectrules
    , .{}, &.{.E0922});
}

test "§2.7 a string given to a ranged parameter is its characters' integer" {
    try expectTree(
        \\module kid; endmodule
        \\module top; parameter [15:0] s = "hi"; if (s == 16'h6869) kid k(); endmodule
    , .{}, "top top\ntop.genblk1.k kid\n");
}

test "IEEE 1364-2005 §12.8.1 a defparam of the module's own parameter is in force before the generate scheme reads it" {
    try expectTree(
        \\module kid; endmodule
        \\module top; parameter n = 1; if (n == 2) kid k(); defparam n = 2; endmodule
    , .{}, "top top\ntop.genblk1.k kid\n");
}

test "§7.8.5.1 a gate terminal on a continuous vector net gets no bridge (E0929)" {
    try expectCodesUnder(
        \\nature V; access = V; endnature
        \\discipline el; potential V; enddiscipline
        \\discipline dd; domain discrete; enddiscipline
        \\connectmodule a2d(e, c); input e; output c; el e; dd c; endmodule
        \\module top; el [1:0] a; wire [1:0] y; reg [1:0] b; and g[1:0] (y, a, b); endmodule
        \\connectrules r; connect a2d split; endconnectrules
    , "dd", &.{.E0929});
}

test "§7.4.4 a net's second discipline declaration in one scope is E0902; §3.11 a branch or access joining incompatible disciplines is E0355" {
    const prelude =
        \\nature V; units = "V"; access = V; endnature
        \\nature R; units = "rad"; access = R; endnature
        \\discipline ea; potential V; enddiscipline
        \\discipline eb; potential V; enddiscipline
        \\discipline rot; potential R; enddiscipline
        \\
    ;
    try expectCodes(prelude ++ "module top(p); inout p; ea p; eb p; endmodule", .{}, &.{.E0902});
    try expectCodes(prelude ++ "module top(p); inout p; ea p; endmodule", .{}, &.{});
    try expectCodes(prelude ++ "module top; ea a; rot b; branch (a, b) br; endmodule", .{}, &.{.E0355});
    try expectCodes(prelude ++ "module top; ea a; eb b; branch (a, b) br; endmodule", .{}, &.{});
}

test "Annex F.2.1 step 3 an out-of-context declaration overrides a net's discipline: twice for one segment is E0902, an incompatible override E0375" {
    const prelude =
        \\nature V; units = "V"; access = V; endnature
        \\nature R; units = "rad"; access = R; endnature
        \\discipline ea; potential V; enddiscipline
        \\discipline eb; potential V; enddiscipline
        \\discipline rot; potential R; enddiscipline
        \\module leaf(p); inout p; ea p; endmodule
        \\
    ;
    try expectCodes(prelude ++ "module top; leaf u(n); eb u.p; endmodule", .{}, &.{});
    try expectCodes(prelude ++ "module top; leaf u(n); eb u.p; ea u.p; endmodule", .{}, &.{.E0902});
    try expectCodes(prelude ++ "module top; leaf u(n); rot u.p; endmodule", .{}, &.{.E0375});
    try expectCodes(prelude ++ "module top; leaf u(n); rot $root.top.u.p; endmodule", .{}, &.{.E0375});
}

test "§3.6.2.4 an undeclared net digital behavioral code drives is discrete, so its analog port gets a bridge" {
    try expectTree(
        \\nature V; access = V; endnature
        \\discipline el; potential V; enddiscipline
        \\discipline dd; domain discrete; enddiscipline
        \\connectmodule d2a(c, e); input c; output e; dd c; el e; endmodule
        \\module load(p); input p; el p; endmodule
        \\module top; reg s; assign w = s; load l(w); endmodule
        \\connectrules r; connect d2a; endconnectrules
    , .{}, "top top\ntop.l load\ntop.w__d2a__el d2a\n");
}

test "§3.4.4 an array parameter's override is of its exact size, and a resize brings an array of the new size (E0921)" {
    const target =
        \\module t; parameter integer n = 2; parameter real c[0:n-1] = '{1.0, 2.0}; endmodule
        \\
    ;
    try expectCodes(target ++ "module top; t #(.c('{4.0, 5.0})) a(); t #(.n(3), .c('{1.0, 2.0, 3.0})) b(); endmodule", .{}, &.{});
    try expectCodes(target ++ "module top; t #(.c('{4.0, 5.0, 6.0})) a(); t #(.c('{4.0})) b(); t #(.n(3)) c(); endmodule", .{}, &.{ .E0921, .E0921, .E0921 });
}

test "Annex E.3.2.1 port_discipline on a shipped primitive names a continuous discipline (E0358); two incompatible segments of one domain are E0355" {
    const prelude =
        \\nature V; units = "V"; access = V; endnature
        \\nature R; units = "rad"; access = R; endnature
        \\discipline electrical; potential V; enddiscipline
        \\discipline rot; potential R; enddiscipline
        \\discipline dd; domain discrete; enddiscipline
        \\module resistor(p, n); inout p, n; electrical p, n; endmodule
        \\
    ;
    var o = try elabBuiltins(prelude ++
        \\module top; (* port_discipline = "rot" *) resistor a(x, y); (* port_discipline = "dd" *) resistor b(x, y);
        \\  (* port_discipline = 3 *) resistor c(x, y); (* port_discipline = "nowhere" *) resistor d(x, y); endmodule
    );
    defer o.deinit();
    try std.testing.expectEqualSlices(Diag.Code, &.{ .E0358, .E0358, .E0358 }, o.codes);
    try expectCodes(
        \\nature V; units = "V"; access = V; endnature
        \\nature R; units = "rad"; access = R; endnature
        \\discipline el; potential V; enddiscipline
        \\discipline rot; potential R; enddiscipline
        \\module a(x); inout x; el x; endmodule
        \\module b(x); inout x; rot x; endmodule
        \\module top; a u(q); b v(q); endmodule
    , .{}, &.{.E0355});
}

test "§2.6.2 a scale factor in a UDP's delay is E0247 (each UDP instance's W0252 beside it); IEEE 1364-2005 §12.8.1 a defparam of its own parameter that reads it is E0907" {
    try expectCodes(
        \\primitive buf1(q, a); output q; input a; table 0 : 0; 1 : 1; endtable endprimitive
        \\module top; wire q; buf1 #(0 ? 2u : 0.25) g(q, 1'b0); buf1 #(1) h(q, 1'b0); endmodule
    , .{}, &.{ .E0247, .W0252, .W0252 });
    try expectCodes(
        \\module w; parameter real x = 1.0; parameter real y = x; defparam w.x = y; endmodule
        \\module top; w w(); endmodule
    , .{}, &.{.E0907});
}

test "§2.7.1 an escaped instance name is one path segment" {
    try expectTree(
        \\module kid; endmodule
        \\module top; kid \a.b (); kid plain(); endmodule
    , .{}, "top top\ntop.\\a.b  kid\ntop.plain kid\n");
}

test "IEEE 1364-2005 §13.5.1 under a library map a cell binds from the search order's first library; §13.3.1.5 a config's default liblist first, inherited" {
    const gpa = std.testing.allocator;
    const cells =
        \\module a_kid; endmodule
        \\module b_kid; endmodule
        \\module leaf; a_kid k(); endmodule
        \\module leaf; b_kid k(); endmodule
        \\module top; leaf u(); endmodule
        \\
    ;
    const libs: []const ?[]const u8 = &.{ null, null, "libA", "libB", null, null };
    // The search order's libA, not the last `leaf` written (libB's).
    const by_order = try treeUnderMap(cells, libs, &.{ "libA", "libB", "work" });
    defer gpa.free(by_order);
    try std.testing.expectEqualStrings("top work.top\ntop.u libA.leaf\ntop.u.k work.a_kid\n", by_order);
    const by_config = try treeUnderMap(cells ++ "config cfg; design work.top; default liblist libB work; endconfig\n", libs, &.{ "libA", "libB", "work" });
    defer gpa.free(by_config);
    try std.testing.expectEqualStrings("top work.top\ntop.u libB.leaf\ntop.u.k work.b_kid\n", by_config);
}
