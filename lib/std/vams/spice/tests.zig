//! The SPICE reader's spec examples, through its public request API: a
//! netlist in, module text, refusals, `.HDL` names and requests checked out.
//! Each expected value is derived by hand from the annex clause it cites.
//! Ported from lib/frontend/spice_cards.zig's tests; files are answered
//! from memory, so no test touches a disk.
//! Cites: LRM annex E.1.2, E.2, E.2.1, E.2.2.1-E.2.2.3, E.3.1, E.4.1, E.4.2,
//! Table E.1; §2.8.1, §3.4.2, §3.6.4, A.1.2.
//!
//! Contents: tests only.

const std = @import("std");
const testing = std.testing;
const spice = @import("../spice.zig");
const Diag = @import("../Diag.zig");
const Netlist = spice.Netlist;

/// A file the tests answer a request with: (path, bytes).
const DiskFile = struct { []const u8, []const u8 };

const test_lib =
    \\* corners
    \\.LIB FF
    \\.SUBCKT FAST A B
    \\R1 A B 1
    \\.ENDS
    \\.ENDL
    \\.LIB TT
    \\.SUBCKT TYP A B
    \\R1 A B 2
    \\.ENDS
    \\.ENDL
    \\.LIB EMPTY
    \\.ENDL
    \\
;

const test_top =
    \\.INCLUDE "inc.sp"
    \\.INC 'inc.sp'
    \\.LIB 'lib.sp' tt
    \\.LIB lib.sp empty
    \\.LIB lib.sp ss
    \\.INCLUDE
    \\.INCLUDE nothere.sp
    \\.LIB open.sp tt
    \\.HDL "a.va"
    \\.HDL a.va
    \\.HDL
    \\
;

/// The words `readOne` builds netlists from (the old fuzz test's). No
/// `.include`, `.lib` or `.hdl` call, so a run makes no request.
const fuzz_words = [_][]const u8{ ".subckt", ".ends", ".model", ".param", ".endl", "+", "r1", "c1", "v1", "i1", "e1", "f1", "g1", "h1", "m1", "q1", "j1", "d1", "x1", "k1", "a", "b", "0", "1", "1k", "2n2222", "nch", "nch.1", "npn", "nmos", "bsim4", "params:", "w=1", "l={2*w}", "m=2", "lmin=0", "lmax=1", "{w*2}", "'w+1'", "{", "}", "'", "(", ")", ",", "=", "**", "-", "poly", "value={1}", "*", ";", "$", "\n", "1e999k", "wire" };

// ---- private ----

/// Runs `n` to the end, answering from `disk` (any other path is "cannot
/// read"), and returns the requests it made.
fn finish(n: *Netlist, disk: []const DiskFile) !usize {
    var requests: usize = 0;
    while (try n.run()) |req| switch (req) {
        .file => |want| {
            requests += 1;
            try n.answer(for (disk) |f| {
                if (std.mem.eql(u8, f[0], want.path)) break f[1];
            } else null);
        },
    };
    return requests;
}

/// A finished read of `netlist` with no path and no files; the caller deinits.
fn read(netlist: []const u8) !Netlist {
    var n: Netlist = .init(testing.allocator, "", netlist);
    errdefer n.deinit();
    try testing.expectEqual(@as(usize, 0), try finish(&n, &.{}));
    return n;
}

/// Requires every `want` in `text`, printing the text when one is missing.
fn expectHas(text: []const u8, wants: []const []const u8) !void {
    for (wants) |want| if (std.mem.find(u8, text, want) == null) {
        std.debug.print("missing: {s}\n in:\n{s}\n", .{ want, text });
        return error.TestUnexpectedResult;
    };
}

/// Requires `text` to hold none of `unwanted`.
fn expectLacks(text: []const u8, unwanted: []const []const u8) !void {
    for (unwanted) |u| if (std.mem.find(u8, text, u) != null) {
        std.debug.print("unexpected: {s}\n in:\n{s}\n", .{ u, text });
        return error.TestUnexpectedResult;
    };
}

/// Requires the refusals' messages to hold `wants`, one each, in order.
fn expectRefusals(refused: []const spice.Refusal, wants: []const []const u8) !void {
    errdefer for (refused, 0..) |r, i| std.debug.print("refusal {d}: {s}\n", .{ i, r.message });
    try testing.expectEqual(wants.len, refused.len);
    for (refused, wants) |r, want| try expectHas(r.message, &.{want});
}

/// Reads `netlist` with every allocation on `gpa`, answering `/d/inc.sp`.
fn readAll(gpa: std.mem.Allocator, netlist: []const u8) !void {
    var n: Netlist = .init(gpa, "/d/top.sp", netlist);
    defer n.deinit();
    _ = try finish(&n, &.{.{ "/d/inc.sp", ".SUBCKT I A B\nR1 A B 1\n.ENDS\n.LIB OPEN\n" }});
}

fn readOne(_: void, s: *testing.Smith) anyerror!void {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    while (!s.eos()) {
        w.writeAll(fuzz_words[s.index(fuzz_words.len)]) catch break;
        w.writeByte(' ') catch break;
    }
    var n = try read(w.buffered());
    defer n.deinit();
    const out = n.output();
    // Every refusal points inside the file it names, and a module count
    // comes with module text.
    for (out.refusals) |r| {
        try testing.expect(r.file < out.files.len);
        try testing.expect(@as(usize, r.at) + r.len <= out.files[r.file].text.len);
    }
    try testing.expect((out.modules == 0) == (out.text.len == 0));
}

test "a .MODEL card becomes a module with the primitive's ports, a .SUBCKT with its own" {
    var n = try read(
        \\* a comment line
        \\.MODEL VERTNPN NPN BF=80 IS=1E-18 RB=100 VAF=50
        \\+ CJE=3PF CJC=2PF ; trailing comment
        \\.SUBCKT ECPOSC (OUT GND)
        \\VA VCC GND 5
        \\R1 B1 GND 10K
        \\.ENDS ECPOSC
        \\.TRAN 1N 100N $ skipped, not diagnosed
    );
    defer n.deinit();
    const s = n.output();
    try testing.expectEqual(@as(u32, 2), s.modules);
    try expectRefusals(s.refusals, &.{});
    // E.2.2.1: ports AND parameters from the bjt primitive, in Table E.1's
    // order; Table E.1's bjt declares `area` and nothing else, so `BF`,
    // `IS`, `CJE` are dropped in silence (E.4.2).
    try expectHas(s.text, &.{
        "module vertnpn(c, b, e, s);",
        "parameter real area = 1.0;",
        "bjt #(.area(area)) prim(c, b, e, s);",
        // E.2.2.2: ports from the card, lowered, parentheses dropped.
        "module ecposc(out, gnd);",
        "vsine #(.dc(5)) va(vcc, gnd);",
        "resistor #(.r(10000)) r1(b1, gnd);",
    });
    try expectLacks(s.text, &.{ "bf", "100n" });
}

test "a .SUBCKT's device cards are its body, and an unreadable one is refused" {
    var n = try read(
        \\.SUBCKT RDIV IN OUT GND
        \\R1 IN OUT 1K
        \\R2 OUT GND 3K
        \\S1 OUT IN GND 0 SWMOD
        \\R3 A B RMOD
        \\.ENDS RDIV
        \\R9 X Y 1K
    );
    defer n.deinit();
    const s = n.output();
    try testing.expectEqual(@as(u32, 1), s.modules);
    try expectHas(s.text, &.{ "resistor #(.r(1000)) r1(in, out);", "resistor #(.r(3000)) r2(out, gnd);" });
    // `S` has no row and `RMOD` is no number: each is refused at its line;
    // `R9` is after `.ENDS`, top-level, not part of any definition.
    try expectLacks(s.text, &.{ "s1", "r3", "r9" });
    try expectRefusals(s.refusals, &.{ "a `s` device card", "`rmod` is not a number" });
    try testing.expectEqual(@as(u32, 51), s.refusals[0].at);

    // A repeated `.SUBCKT` is dropped with its body.
    var dup = try read(".SUBCKT PAD A B\nR1 A B 1K\n.ENDS\n.SUBCKT PAD A B\nR1 A B 9K\n.ENDS\n");
    defer dup.deinit();
    try testing.expectEqual(@as(u32, 1), dup.output().modules);
    try expectLacks(dup.output().text, &.{"9000"});
}

test "a .MODEL card's value reaches the Table E.1 parameter of the same name" {
    var n = try read(".MODEL RMOD R R=10K TC1=1E-3\n.MODEL CM C C=1P IC=2.5\n");
    defer n.deinit();
    const s = n.output();
    try testing.expectEqual(@as(u32, 2), s.modules);
    try expectHas(s.text, &.{
        // §3.4.2's `from` range belongs to the declaration, not the default.
        "parameter real r = 10000 from (0:inf);",
        "parameter real tc1 = 0.001;",
        // A parameter the card does not name keeps the primitive's default.
        "parameter real tc2 = 0.0;",
        "resistor #(.r(r), .tc1(tc1), .tc2(tc2)) prim(p, n);",
        "parameter real c = 0.000000000001 from (0:inf);",
        "parameter real ic = 2.5;",
    });
}

test "a card naming a keyword is declared as a §2.8.1 escaped identifier" {
    var n = try read(".SUBCKT AMP (INPUT OUTPUT)\n.ENDS AMP\n.MODEL WIRE NPN BF=80\n");
    defer n.deinit();
    try testing.expectEqual(@as(u32, 2), n.output().modules);
    // The terminator is the point: `\input,` would scan the comma in.
    try expectHas(n.output().text, &.{ "module amp(\\input , \\output );", "electrical \\input , \\output ;", "module \\wire (c, b, e, s);" });
    var plain = try read(".SUBCKT PAD IN OUT\n.ENDS\n");
    defer plain.deinit();
    try expectHas(plain.output().text, &.{"module pad(in, out);"});
}

test "a digit-leading name and a numeric node are spelled §2.8.1, not dropped" {
    var n = try read(".MODEL 2N2222 NPN BF=200\n.SUBCKT FLT A 1 B\n.ENDS FLT\n");
    defer n.deinit();
    try testing.expectEqual(@as(u32, 2), n.output().modules);
    // The numeric node is a port, not the end of the list (§6.5.4 order).
    try expectHas(n.output().text, &.{ "module \\2n2222 (c, b, e, s);", "module flt(a, \\1 , b);", "electrical a, \\1 , b;" });
    // A parameter assignment ends the port list (HSPICE's PARAMS:).
    var p = try read(".SUBCKT X N1 N2 PARAMS: W=2\n.ENDS\n");
    defer p.deinit();
    try testing.expectEqual(@as(u32, 1), p.output().modules);
    try expectRefusals(p.output().refusals, &.{});
    try expectHas(p.output().text, &.{ "module x(n1, n2);", "   parameter real w = 2;" });
}

test "an unrecognised model type, a repeat and an empty netlist all contribute nothing" {
    var empty = try read("");
    defer empty.deinit();
    try testing.expectEqual(@as(u32, 0), empty.output().modules);
    try testing.expectEqual(@as(usize, 0), empty.output().files.len);
    var sw = try read(".MODEL SW1 SW RON=1\n");
    defer sw.deinit();
    try testing.expectEqual(@as(u32, 0), sw.output().modules);
    // E.1.2: kept by name and type, so its instance is refused as such.
    try testing.expectEqual(@as(usize, 1), sw.output().unsupported.len);
    try testing.expectEqualStrings("sw1 sw", sw.output().unsupported[0]);
    var top = try read("R1 a b 1k\n.TRAN 1n 1u\n");
    defer top.deinit();
    try testing.expectEqual(@as(u32, 0), top.output().modules);
    try testing.expectEqualStrings("", top.output().text);
    var dup = try read(".MODEL M1 NPN\n.MODEL M1 PNP\n");
    defer dup.deinit();
    try testing.expectEqual(@as(u32, 1), dup.output().modules);
    // A portless .SUBCKT is A.1.2's `module identifier ;`.
    var bare = try read(".SUBCKT PAD\n.ENDS\n");
    defer bare.deinit();
    try testing.expectEqual(@as(u32, 1), bare.output().modules);
    try expectLacks(bare.output().text, &.{"electrical"});
}

test "E.3.1 the four controlled sources inside a .SUBCKT, and the V card an F or H reads" {
    var n = try read(
        \\.SUBCKT CTL A B C D
        \\VS A X 0
        \\E1 B 0 A X 2
        \\G1 C 0 A X 3
        \\F1 D 0 VS 4
        \\H1 B C VS 5
        \\F2 D 0 VNONE 6
        \\.ENDS
    );
    defer n.deinit();
    const s = n.output();
    try expectHas(s.text, &.{
        "branch (a, x) vs;",
        "V(vs) <+ $simparam(\"sourceScaleFactor\") * 0;",
        "V(b, \\0 ) <+ 2 * V(a, x);",
        "I(c, \\0 ) <+ 3 * V(a, x);",
        "I(d, \\0 ) <+ 4 * I(vs);",
        "V(b, c) <+ 5 * I(vs);",
    });
    // A controlling V card the subcircuit does not declare is refused, and
    // a controlling V card is a branch of this module, not a `vsine` child.
    try expectLacks(s.text, &.{ "6 *", "vsine" });
    try expectRefusals(s.refusals, &.{"`vnone`, which is not a V card"});
}

test "E.1.2 nested .SUBCKT, {expr} values and trailing fields in a body are refused, top-level cards are not" {
    var n = try read(
        \\.SUBCKT OUTER A B
        \\.SUBCKT INNER C D
        \\R1 A B {RVAL}
        \\R2 A B 1K TC=0.01
        \\.ENDS
        \\R9 X Y RMOD
        \\.TRAN 1N 1U
    );
    defer n.deinit();
    try expectRefusals(n.output().refusals, &.{ "nested", "{rval}", "tc=0.01" });
}

test "E.2 an M/Q/J/D card instantiates its model's module, card parameters under the instance's" {
    var n = try read(
        \\.SUBCKT AMP D G S B
        \\M1 D G S B NCH W=2U L = 50N M=3
        \\Q1 D G S QMOD 2
        \\Q2 D G S B QMOD
        \\D1 G S DIO 4 AREA=5
        \\J1 D G S MYJFET
        \\.ENDS
        \\.MODEL NCH BSIMCMG TYPE=1 L=20N NSD=2E+26
        \\.MODEL QMOD MYBJT BF=80
        \\.MODEL DIO DIODE_VA IS=1E-14
    );
    defer n.deinit();
    try expectRefusals(n.output().refusals, &.{});
    try expectHas(n.output().text, &.{
        // The model card first (its `l` replaced in place), then what only
        // the instance sets; `M` is E.4.1's `$mfactor`; 2e26 is real.
        "   bsimcmg #(.type(1), .l(0.00000005), .nsd(2e26), .w(0.000002), .$mfactor(3)) m1(d, g, s, b);",
        // Q: a fifth field that is a number is the area, not a substrate...
        "   mybjt #(.bf(80), .area(2)) q1(d, g, s);",
        // ...and a fifth that is not is the model after a substrate.
        "   mybjt #(.bf(80)) q2(d, g, s, b);",
        // An explicit `area=` wins over the positional one.
        "   diode_va #(.is(0.00000000000001), .area(5)) d1(g, s);",
        // No `.MODEL`: the name is a module or paramset of the design.
        "   myjfet j1(d, g, s);",
    });
}

test "E.2 a card whose model is a Table E.1 semiconductor is E0953; a binned model and a bad value are E0928" {
    var n = try read(
        \\.MODEL NMOS_LVT NMOS LEVEL = 72
        \\.MODEL PCH.1 BSIM4 LMIN=1U
        \\.SUBCKT INV A Y VDD VSS
        \\MN Y A VSS VSS NMOS_LVT L=21N
        \\MP Y A VDD VDD PCH L=21N
        \\MX Y A VDD VDD BSIM4 L={LEN}
        \\MY Y A VDD VDD BSIM4 OFF
        \\.ENDS
    );
    defer n.deinit();
    const r = n.output().refusals;
    try expectRefusals(r, &.{ "Table E.1's `mosfet`", "binned", "{len}", "`off`" });
    try testing.expectEqual(Diag.Code.E0953, r[0].code);
    for (r[1..]) |x| try testing.expectEqual(Diag.Code.E0928, x.code);
}

test "PARAMS: on a .SUBCKT, {expr} values over them, and X cards instantiating a subcircuit" {
    var n = try read(
        \\.SUBCKT RDIV IN OUT GND PARAMS: RTOP=1K RBOT={3*RTOP}
        \\R1 IN OUT { RTOP }
        \\R2 OUT GND 'RBOT'
        \\R3 OUT GND {max(RTOP, 2k)}
        \\.ENDS
        \\.SUBCKT TWO A B
        \\X1 A MID 0 RDIV PARAMS: RTOP=2K
        \\X2 MID B 0 RDIV M=2
        \\.ENDS
    );
    defer n.deinit();
    try expectRefusals(n.output().refusals, &.{});
    try testing.expectEqual(@as(u32, 2), n.output().modules);
    try expectHas(n.output().text, &.{
        "   parameter real rtop = 1000;",
        // A default may read the parameters before it; numbers are real.
        "   parameter real rbot = (3e0 * rtop);",
        // A brace or quote holds its blanks, parentheses and commas.
        "   resistor #(.r(rtop)) r1(in, out);",
        "   resistor #(.r(rbot)) r2(out, gnd);",
        "   resistor #(.r(max(rtop, 2e3))) r3(out, gnd);",
        "   rdiv #(.rtop(2000)) x1(a, mid, \\0 );",
        "   rdiv #(.$mfactor(2)) x2(mid, b, \\0 );",
        // SPICE's node 0 is the global ground, not a local net (§3.6.4).
        "   electrical \\0 ;\n   ground \\0 ;\n",
    });
    var bad = try read(".SUBCKT R A B PARAMS: X={Y}\n.ENDS\n");
    defer bad.deinit();
    try expectRefusals(bad.output().refusals, &.{"reads `y`"});
}

test "E.4.2 a card naming a binned model instantiates the bin that holds its L and W" {
    var n = try read(
        \\.MODEL NCH.1 MYFET KP=1E-3 LMIN=0 LMAX=0.5
        \\.MODEL NCH.2 MYFET KP=3E-3 LMIN=0.5 LMAX=2 WMIN=1
        \\.SUBCKT CELL2 D G S B
        \\M1 D G S B NCH W=2 L=0.5
        \\M2 D G S B NCH W=2 L=0.25
        \\M3 D G S B NCH W=2 L=3
        \\M4 D G S B NCH L=1
        \\.ENDS
    );
    defer n.deinit();
    // lmin <= L < lmax: 0.5 is the second bin's, 0.25 the first's; the
    // bounds select and are not forwarded.
    try expectHas(n.output().text, &.{
        "   myfet #(.kp(0.003), .w(2), .l(0.5)) m1(d, g, s, b);",
        "   myfet #(.kp(0.001), .w(2), .l(0.25)) m2(d, g, s, b);",
    });
    try expectRefusals(n.output().refusals, &.{ "no bin of the binned model `nch`", "gives no w" });
}

test "cards: `+` continues the card above, a leading `+` is dropped, and an unterminated .SUBCKT keeps its body" {
    var n = try read(
        \\+ R0 A B 1
        \\.SUBCKT CONT A
        \\+ B PARAMS: W = 2 ; comment
        \\R1 A B
        \\+ {W}
        \\.ENDS
        \\.MODEL
        \\.MODEL NOTYPE
        \\.SUBCKT OPEN A B
        \\R1 A B 1K
    );
    defer n.deinit();
    try expectRefusals(n.output().refusals, &.{});
    try testing.expectEqual(@as(u32, 2), n.output().modules);
    try expectHas(n.output().text, &.{
        "module cont(a, b);",
        "   parameter real w = 2;",
        "   resistor #(.r(w)) r1(a, b);",
        "module open(a, b);",
        "   resistor #(.r(1000)) r1(a, b);",
    });
    try expectLacks(n.output().text, &.{"r0"});
}

test "E.2 a .SUBCKT header and body refuse what they cannot read, and name it" {
    var n = try read(
        \\.SUBCKT
        \\.ENDS
        \\.SUBCKT A=1
        \\.ENDS
        \\.SUBCKT S1 A PARAMS: W=1 B
        \\.ENDS
        \\.SUBCKT S2 A 1X=2
        \\.ENDS
        \\.SUBCKT S3 A B
        \\.PARAM W=1
        \\K1 L1 L2 0.9
        \\X1
        \\X2 A B SUB W=1 C
        \\R1 A
        \\M1 A B NCH
        \\D1 A B DIO 2 3
        \\R2 A B W=
        \\R3 A B {W
        \\.ENDS
    );
    defer n.deinit();
    try expectRefusals(n.output().refusals, &.{
        "`.subckt` names no definition",
        "`a=1` is not a name for a definition",
        "`b` on `.subckt s1`: neither a node before the parameters nor a `k=v` parameter",
        "`1x` is not a parameter name",
        "`.param` inside a `.subckt` body is not read",
        "a `k` device card is not one VerA reads",
        "`x1` names no subcircuit",
        "the field `c` after its parameters is not read",
        "`r1` has too few fields",
        "`m1` has too few fields",
        "the field `2` after the model is not read",
        "the value `w=` is not a number",
        "the expression value `{w` does not end in `}`",
    });
    try testing.expectEqual(@as(u32, 1), n.output().modules);
    try expectHas(n.output().text, &.{"module s3(a, b);"});
}

test "E.2 Q's substrate is read as SPICE3 reads it, by which field a .MODEL card names" {
    // `2N2222` is also SPICE's 2n with unit noise; the `.MODEL` card says
    // it is the model, so `S` before it is the substrate.
    var n = try read(
        \\.MODEL 2N2222 MYBJT BF=100
        \\.MODEL QM MYBJT
        \\.SUBCKT AMP C B E S
        \\Q1 C B E S 2N2222
        \\Q2 C B E 2N2222 3
        \\Q3 C B E QM SUB
        \\.ENDS
    );
    defer n.deinit();
    try expectHas(n.output().text, &.{ "   mybjt #(.bf(100)) q1(c, b, e, s);", "   mybjt #(.bf(100), .area(3)) q2(c, b, e);" });
    // The fourth field names a model, so the fifth is no substrate.
    try expectRefusals(n.output().refusals, &.{"`q3`: the field `sub` after the model is not read"});
}

test "E.3.1 a controlled source in its POLY, VALUE, TABLE or LAPLACE form is refused, not misread" {
    var n = try read(
        \\.SUBCKT P A B C D
        \\VS C D 0
        \\E1 A B POLY(1) 5
        \\G1 A B VALUE={V(C)*2}
        \\E2 A B TABLE {V(C)} = (0,0) (1,1)
        \\G2 A B LAPLACE {V(C)} {1/(1+S)}
        \\F1 A B POLY(1) VS 0 2
        \\E3 A B C D 2
        \\.ENDS
    );
    defer n.deinit();
    try expectRefusals(n.output().refusals, &.{ "`poly`", "`value`", "`table`", "`laplace`", "`poly`" });
    try expectHas(n.output().text, &.{"V(a, b) <+ 2 * V(c, d);"});
    try expectLacks(n.output().text, &.{"poly"});
}

test "a top-level .LIB block is a library entry, read only when called" {
    var n = try read(
        \\.LIB TT
        \\.SUBCKT HIDDEN A B
        \\.ENDS
        \\.ENDL
        \\.SUBCKT SEEN A B
        \\.ENDS
        \\.LIB OPEN
        \\.SUBCKT LOST A B
        \\.ENDS
    );
    defer n.deinit();
    try testing.expectEqual(@as(u32, 1), n.output().modules);
    try expectHas(n.output().text, &.{"module seen(a, b);"});
    try expectLacks(n.output().text, &.{ "hidden", "lost" });
    try expectRefusals(n.output().refusals, &.{"`.lib` entry has no `.endl`"});
}

test "requests: .INCLUDE, .LIB entries and .HDL beside the netlist, and the refusal for each failure" {
    var n: Netlist = .init(testing.allocator, "/d/top.sp", test_top);
    defer n.deinit();
    const requests = try finish(&n, &.{
        .{ "/d/inc.sp", ".SUBCKT FROMINC A B\nR1 A B 1K\n.ENDS\n" },
        .{ "/d/lib.sp", test_lib },
        .{ "/d/open.sp", ".LIB TT\n.SUBCKT T2 A B\n.ENDS\n" },
    });
    // Each path is asked once, the unreadable one too: inc, lib, nothere, open.
    try testing.expectEqual(@as(usize, 4), requests);
    const s = n.output();
    // inc.sp twice (the second module is a repeat), lib.sp's `tt` entry and
    // open.sp's unterminated one.
    try testing.expectEqual(@as(u32, 3), s.modules);
    try expectHas(s.text, &.{ "module frominc(a, b);", "module typ(a, b);", "module t2(a, b);" });
    try expectLacks(s.text, &.{"fast"});
    try expectRefusals(s.refusals, &.{
        "has no `.lib ss` entry",
        "`.include` names no file",
        "cannot read \"/d/nothere.sp\"",
        "`.lib` entry has no `.endl`",
        "`.hdl` names no file",
    });
    // The unterminated entry is reported in open.sp, the file it is in.
    try testing.expectEqualStrings("/d/open.sp", s.files[s.refusals[3].file].name);
    // top, inc.sp twice, lib.sp three times, open.sp; nothere.sp is no file.
    try testing.expectEqual(@as(usize, 7), s.files.len);
    try testing.expectEqual(@as(usize, 1), s.hdl.len);
    try testing.expectEqualStrings("/d/a.va", s.hdl[0]);
}

test "requests: an .INCLUDE cycle is one refusal naming it; finite nesting has no bound" {
    var self: Netlist = .init(testing.allocator, "/d/self.sp", ".include self.sp\n");
    defer self.deinit();
    _ = try finish(&self, &.{.{ "/d/self.sp", ".include self.sp\n" }});
    try expectRefusals(self.output().refusals, &.{"`.include` cycle: /d/self.sp -> /d/self.sp"});
    // The netlist, and self.sp opened once more before the cycle is seen.
    try testing.expectEqual(@as(usize, 2), self.output().files.len);

    // 2,000 files deep (the old reader was bounded at 16, then by its
    // stack); and one file whose `.LIB` entry calls another entry of the
    // same file, which is no cycle.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const depth = 2000;
    var disk: std.ArrayList(DiskFile) = .empty;
    for (0..depth) |k| {
        const data = if (k + 1 == depth) ".SUBCKT DEEP A B\nR1 A B 1K\n.ENDS\n" else try arena.print(".include c{d}.sp\n", .{k + 1});
        try disk.append(arena, .{ try arena.print("/d/c{d}.sp", .{k}), data });
    }
    try disk.append(arena, .{ "/d/two.sp", ".LIB a\n.LIB two.sp b\n.ENDL\n.LIB b\n.SUBCKT FROMB A B\nR1 A B 1K\n.ENDS\n.ENDL\n" });
    var deep: Netlist = .init(testing.allocator, "/d/top.sp", ".include c0.sp\n.lib two.sp a\n");
    defer deep.deinit();
    try testing.expectEqual(@as(usize, depth + 1), try finish(&deep, disk.items));
    try expectRefusals(deep.output().refusals, &.{});
    try expectHas(deep.output().text, &.{ "module deep(a, b);", "module fromb(a, b);" });
}

test "report: each refusal is its code at the card, in the caller's file numbering" {
    var n = try read(".MODEL N1 NMOS\n.SUBCKT S A B\nS1 A B\nM1 A B A B N1\n.ENDS\n");
    defer n.deinit();
    var wip: Diag.Wip = .init(testing.allocator);
    defer wip.deinit();
    try n.output().report(&wip, @fromBackingInt(3));
    var d = try wip.toOwnedBundle();
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), d.count());
    const first = d.message(d.messages()[0]);
    const second = d.message(d.messages()[1]);
    try testing.expectEqual(Diag.Code.E0928, first.tag.code);
    try testing.expectEqual(Diag.Code.E0953, second.tag.code);
    // `S1 A B` is line 3: 15 + 14 bytes in; the location is the caller's
    // file 3 + the netlist's own index 0.
    try testing.expectEqual(@as(u32, 3), @backingInt(first.loc.file));
    try testing.expectEqual(@as(u32, 29), first.loc.start);
    try testing.expectEqual(@as(u32, 35), first.loc.end);
    try expectHas(d.string(first.msg), &.{"a `s` device card"});
}

test "a read reports every allocation failure as OutOfMemory" {
    // A model, a subcircuit with a body, an unsupported type, a refused
    // card, an include and an entry with no `.endl`: every path that
    // allocates.
    try testing.checkAllAllocationFailures(testing.allocator, readAll, .{
        \\.MODEL RM R R=1K
        \\.MODEL SW1 SW
        \\.SUBCKT S A B
        \\R1 A B 1K
        \\S1 A B
        \\.ENDS
        \\.include inc.sp
        \\.LIB OPEN
    });
}

test "fuzz: a read never panics on card-shaped text, and every refusal points into its file" {
    try testing.fuzz({}, readOne, .{});
}
