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

/// One row of the old parser's `expectFirstErrors` tables
/// (tests/unit/parser_tests.zig): the source, whether it was a digital
/// (`.v`, 1364) parse, and the old first error code ("" for none). The old
/// parser is the oracle of record (golden with provenance: commit 76efa07c).
/// `sema`: a row whose old refusal needs ports, drivers, a nature's
/// `access` or the compile's analog/digital choice, which Sema judges.
const Case = struct { src: [:0]const u8, digital: bool, old: []const u8, sema: bool = false };

/// The old parser's refusals that need names, folding or a module-wide
/// table, which the context-free parser leaves to AstGen and Sema (the
/// codes parse.xfail names).
const semantic = [_][]const u8{ "E0206", "E0218", "E0230", "E0231", "E0235", "E0238", "E0248", "E0216", "E0217", "E0225" };

const old_cases = [_]Case{
    .{ .src = "(* module = 1 *) module m; endmodule", .digital = false, .old = "E0208" },
    .{ .src = "(* units = \"V\" *) module m; endmodule", .digital = false, .old = "" },
    .{ .src = "(* \\module = 1 *) module m; endmodule", .digital = false, .old = "" },
    .{ .src = "module m; endmodule (* a *)", .digital = false, .old = "E0207" },
    .{ .src = "(* *) module m; endmodule", .digital = false, .old = "E0208" },
    .{ .src = "module m; integer x; analog x = ; endmodule", .digital = false, .old = "E0209" },
    .{ .src = "module m; integer x; analog x = 1; endmodule", .digital = false, .old = "" },
    .{ .src = "module m; integer x; reg c; event e; analog begin wait (x) x = 1; end endmodule", .digital = false, .old = "E0255" },
    .{ .src = "module m; integer x; reg c; event e; analog begin force x = 1; end endmodule", .digital = false, .old = "E0258" },
    .{ .src = "module m; integer x; reg c; event e; analog begin release x; end endmodule", .digital = false, .old = "E0258" },
    .{ .src = "module m; integer x; reg c; event e; analog begin fork join end endmodule", .digital = false, .old = "E0249" },
    .{ .src = "module m; integer x; reg c; event e; initial begin wait (x) x = 1; force x = 1; release x; fork join end endmodule", .digital = false, .old = "" },
    .{ .src = "module m; integer x; reg c; event e; analog x; endmodule", .digital = false, .old = "E0214" },
    .{ .src = "module m; integer x; reg c; event e; initial begin disable a.b; -> e; end endmodule", .digital = false, .old = "" },
    .{ .src = "module m; integer x; reg c; event e; analog case (x) default x = 1; endcase endmodule", .digital = false, .old = "" },
    .{ .src = "module m; integer x; reg c; event e; initial $setup(x, c, 1); endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m; wire w; always @(driver_update w) ; endmodule", .digital = false, .old = "E0818" },
    .{ .src = "connectmodule c(w); input w; always @(driver_update w) ; endmodule", .digital = false, .old = "" },
    .{ .src = "module m; integer x; reg c; event e; initial ; endmodule", .digital = false, .old = "E0219" },
    .{ .src = "module m; initial ; endmodule", .digital = true, .old = "E0209" },
    .{ .src = "module m #(localparam a = 1) (); endmodule", .digital = false, .old = "E0246" },
    .{ .src = "module m #() (); endmodule", .digital = false, .old = "E0246" },
    .{ .src = "module m #(parameter a = 1, parameter b = 2) (); endmodule", .digital = false, .old = "" },
    .{ .src = "module m(input a); input a; endmodule", .digital = false, .old = "E0218" },
    .{ .src = "module m(a); input z; endmodule", .digital = false, .old = "E0206" },
    .{ .src = "module m(a, input b); endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m; begin end endmodule", .digital = false, .old = "E0221" },
    .{ .src = "module m; foo; endmodule", .digital = false, .old = "E0240" },
    .{ .src = "module m; endgenerate endmodule", .digital = false, .old = "E0240" },
    .{ .src = "module m(x); input integer x; endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m; wire scalared w; endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m; wire scalared [3:0] w; endmodule", .digital = false, .old = "" },
    .{ .src = "module m; wire a; wire (highz0, highz1) w = a; endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m; wire a; wire (strong0, pull0) w = a; endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m; wire a; wire (small, strong1) w = a; endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m; wire (strong0, strong1) w; endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m; wire (small) w; endmodule", .digital = false, .old = "E0257" },
    .{ .src = "module m; trireg (strong0) t; endmodule", .digital = false, .old = "E0257" },
    .{ .src = "module m; trireg (foo) t; endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m; wire #(1, 2, 3, 4) w; endmodule", .digital = false, .old = "E0210" },
    .{ .src = "module m; wire n[0:3]; endmodule", .digital = false, .old = "E0205", .sema = true },
    .{ .src = "module m; electrical a, n[0:3]; endmodule", .digital = false, .old = "E0205", .sema = true },
    .{ .src = "module m; defparam u[k].x = 1; endmodule", .digital = false, .old = "E0231" },
    .{ .src = "module m; wire n[0:3]; endmodule", .digital = true, .old = "" },
    .{ .src = "module m; defparam u[k].x = 1; endmodule", .digital = true, .old = "" },
    .{ .src = "module m; parameter real a = 1 from [0:1; endmodule", .digital = false, .old = "E0210" },
    .{ .src = "module m; parameter [3:0] p = 3; endmodule", .digital = false, .old = "" },
    .{ .src = "module m; parameter real r = 1; aliasparam m2 = $mfactor; endmodule", .digital = false, .old = "" },
    .{ .src = "module m; for (i = 0; i < 2; i = i + 1) begin end endmodule", .digital = false, .old = "E0238" },
    .{ .src = "module m; genvar i; for (i = 0; i < 2; i = i + 1) begin end endmodule", .digital = false, .old = "" },
    .{ .src = "module m; generate if (1) begin task t; begin end endtask end endgenerate endmodule", .digital = false, .old = "E0235" },
    .{ .src = "module m; generate if (1) begin task t; begin end endtask end endgenerate endmodule", .digital = true, .old = "" },
    .{ .src = "library lib \"a.v\", \"b.v\" -incdir \"inc\";", .digital = false, .old = "E0232" },
    .{ .src = "include \"x.v\";", .digital = false, .old = "E0232" },
    .{ .src = "library lib \"a.v\" -foo;", .digital = false, .old = "E0207" },
    .{ .src = "specify endspecify", .digital = false, .old = "E0245" },
    .{ .src = "table", .digital = false, .old = "E0201" },
    .{ .src = "endmodule", .digital = false, .old = "E0201" },
    .{ .src = "config c; design top; default liblist a; default liblist b; endconfig", .digital = false, .old = "E0243" },
    .{ .src = "config c; design top; cell lib.x liblist a; endconfig", .digital = false, .old = "E0243" },
    .{ .src = "config c; default liblist a; endconfig", .digital = false, .old = "E0207" },
    .{ .src = "config c; design top;", .digital = false, .old = "E0207" },
    .{ .src = "config c; design top; instance top.u use lib.x : foo; endconfig", .digital = false, .old = "E0207" },
    .{ .src = "module m; analog $strobe(\"\\777\"); endmodule", .digital = false, .old = "E0148" },
    .{ .src = "module m; analog $strobe(\"\\q\"); endmodule", .digital = false, .old = "" },
    .{ .src = "primitive u(q, a); output q; input a; table 0; endtable endprimitive", .digital = false, .old = "E0234" },
    .{ .src = "primitive u(q, a); output q; reg q; input a; table 0 : 1 : 1 : 1; endtable endprimitive", .digital = false, .old = "E0234" },
    .{ .src = "primitive u(q, a); output q; input a; table q : 1; endtable endprimitive", .digital = false, .old = "E0233" },
    .{ .src = "primitive u(q, a); output q; input a; table 0 : 2; endtable endprimitive", .digital = false, .old = "E0233" },
    .{ .src = "primitive u(q, a); output q; input a; table 0 : 01; endtable endprimitive", .digital = false, .old = "E0233" },
    .{ .src = "primitive u(q, a); output q; input a; table 0 : -; endtable endprimitive", .digital = false, .old = "E0233" },
    .{ .src = "primitive u(q, a); output q; reg q; input a; table 0 : 0 : -; endtable endprimitive", .digital = false, .old = "" },
    .{ .src = "primitive u(q, a); output q; input a; table r : 1; endtable endprimitive", .digital = false, .old = "E0234" },
    .{ .src = "primitive u(q, a); output q; reg q; input a; table 0 : r : 1; endtable endprimitive", .digital = false, .old = "E0233" },
    .{ .src = "primitive u(q, a); output q; input a; table 0 : 0; endtable", .digital = false, .old = "E0207" },
    .{ .src = "primitive u(q, a); output q; input a; endprimitive", .digital = false, .old = "E0207" },
    .{ .src = "primitive u(q, a); output q; input a; table 0 : 0; 0 : 1; endtable endprimitive", .digital = false, .old = "E0248" },
    .{ .src = "primitive u(q, a); output q; input a; table ? : 0; 1 : 1; endtable endprimitive", .digital = false, .old = "E0248" },
    .{ .src = "primitive u(q, a); output q; input a; table ? : 0; 1 : 0; endtable endprimitive", .digital = false, .old = "" },
    .{ .src = "primitive u(q, a); output q; input a; table 0 : 0; 1 : 1; endtable endprimitive", .digital = false, .old = "" },
    .{ .src = "primitive u(q, a); output q; reg q; input a; table 0 : 0 : -; 0 : 0 : 0; endtable endprimitive", .digital = false, .old = "" },
    .{ .src = "primitive u(q, a); output q; reg q; input a; table 0 : 1 : -; 0 : 1 : 0; endtable endprimitive", .digital = false, .old = "E0248" },
    .{ .src = "primitive u(q, a); output q; reg q; input a; table r : ? : 1; 1 : ? : 0; endtable endprimitive", .digital = false, .old = "" },
    .{ .src = "primitive u(q, a, b); output q; input a, b; table 0 0 : 0; endtable endprimitive module m; wire q, a, b; u (strong0, weak1) #(1, 2, 3) g(q, a, b); endmodule", .digital = false, .old = "E0239" },
    .{ .src = "primitive u(q, a, b); output q; input a, b; table 0 0 : 0; endtable endprimitive module m; wire q, a, b; u (strong0, weak1) #(1, 2) g(q, a, b); endmodule", .digital = false, .old = "" },
    .{ .src = "module m(input a, input b, input clk, output y); specify (a => y) = (1, 2, 3, 4); endspecify endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m(input a, input b, input clk, output y); specify (a, b => y) = 1; endspecify endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m(input a, input b, input clk, output y); specify (a y) = 1; endspecify endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m(output a, output y); specify (a => y) = 1; endspecify endmodule", .digital = false, .old = "E0245", .sema = true },
    .{ .src = "module m(input a, input y); specify (a => y) = 1; endspecify endmodule", .digital = false, .old = "E0245", .sema = true },
    .{ .src = "module m(input a, input b, input clk, output y); assign y = a; assign y = b; specify (a => y) = 1; endspecify endmodule", .digital = false, .old = "E0245", .sema = true },
    .{ .src = "module m(input [3:0] a, output y); specify (a => y) = 1; endspecify endmodule", .digital = false, .old = "E0245", .sema = true },
    .{ .src = "module m(input [3:0] a, output [0:3] y); specify (a => y) = 1; endspecify endmodule", .digital = false, .old = "" },
    .{ .src = "module m(input a, input b, input clk, output y); specify (a => y) = a; endspecify endmodule", .digital = false, .old = "E0245", .sema = true },
    .{ .src = "module m(input a, input b, input clk, output y); specify (a => y) = 1; ifnone (a => y) = 2; endspecify endmodule", .digital = false, .old = "E0245", .sema = true },
    .{ .src = "module m(input a, input b, input clk, output y); specify if (b) (a => y) = 1; ifnone (a => y) = 2; endspecify endmodule", .digital = false, .old = "" },
    .{ .src = "module m(input a, input b, input clk, output y); specify if (a + b) (a => y) = 1; endspecify endmodule", .digital = false, .old = "E0245" },
    .{ .src = "module m(input a, input b, input clk, output y); specify ifnone (posedge clk => (y : a)) = 1; endspecify endmodule", .digital = false, .old = "E0245" },
    .{ .src = "module m(input a, input b, input clk, output y); specify (posedge clk + => (y : a)) = 1; endspecify endmodule", .digital = false, .old = "E0245" },
    .{ .src = "module m(input a, input b, input clk, output y); specify y = 1; endspecify endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m(input a, input b, input clk, output y); specify (a => y) = 1;", .digital = false, .old = "E0207" },
    .{ .src = "module m(input d, input clk, input en); reg notif; specify $setup(d, posedge clk &&& en, 1); $hold(posedge clk, d, 1, notif); endspecify endmodule", .digital = false, .old = "" },
    .{ .src = "module m(input d, input clk, input en); reg notif; specify $setup(d, clk); endspecify endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m(input d, input clk, input en); reg notif; specify $setup(d, clk, 1, notif, 2); endspecify endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m(input d, input clk, input en); reg notif; specify $width(clk, 1); endspecify endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m(input d, input clk, input en); reg notif; specify $width(negedge clk, 1, , notif); endspecify endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m(input d, input clk, input en); reg notif; specify $width(negedge clk, 1, 0, notif); endspecify endmodule", .digital = false, .old = "" },
    .{ .src = "module m(input d, input clk, input en); reg notif; specify $hold(posedge clk, d, 1, 5); endspecify endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m(input d, input clk, input en); reg notif; specify $setup(d, posedge clk, posedge en); endspecify endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m(input d, input clk, input en); reg notif; specify $foo(d); endspecify endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m(input d, input clk, input en); reg notif; specify $period(edge [01, 1x] clk, 5); endspecify endmodule", .digital = false, .old = "" },
    .{ .src = "module m(input d, input clk, input en); reg notif; specify $period(edge [2x] clk, 5); endspecify endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m(input d, input clk, input en); reg notif; specify $period(edge clk, 5); endspecify endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m; child #(.a(1), 2) c(); endmodule", .digital = false, .old = "E0246" },
    .{ .src = "module m; child #() c(); endmodule", .digital = false, .old = "E0246" },
    .{ .src = "module m; wire o; and (o); endmodule", .digital = false, .old = "E0209" },
    .{ .src = "module m; wire o, i; bufif0 (o, i); endmodule", .digital = false, .old = "E0209" },
    .{ .src = "module m; wire a, b; and (1, a, b); endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m; wire o, a; buf (o); endmodule", .digital = false, .old = "E0209" },
    .{ .src = "module m; wire w; pulldown (strong1) (w); endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m; wire a, b; tran #1 (a, b); endmodule", .digital = false, .old = "E0207" },
    .{ .src = "module m; wire o, i; nmos (o, i); endmodule", .digital = false, .old = "E0209" },
    .{ .src = "module m; task t; begin end", .digital = true, .old = "E0207" },
    .{ .src = "nature N : el.potential; endnature", .digital = false, .old = "" },
    .{ .src = "nature N : el.foo; endnature", .digital = false, .old = "E0211" },
    .{ .src = "nature N; 5 = 1; endnature", .digital = false, .old = "E0208" },
    .{ .src = "discipline d; domain foo; enddiscipline", .digital = false, .old = "E0212" },
    .{ .src = "discipline d; x; enddiscipline", .digital = false, .old = "E0213" },
    .{ .src = "discipline d; 5; enddiscipline", .digital = false, .old = "E0213" },
    .{ .src = "discipline d; flow.abstol = 1e-9; domain discrete; enddiscipline", .digital = false, .old = "" },
    .{ .src = "paramset ps mo; endparamset", .digital = false, .old = "E0297" },
    .{ .src = "paramset ps mo; real o; o = V(p); endparamset", .digital = false, .old = "E0237", .sema = true },
    .{ .src = "paramset ps mo; real o; begin : b o = 1; end endparamset", .digital = false, .old = "E0237" },
    .{ .src = "paramset ps mo; real o; garbage; endparamset", .digital = false, .old = "E0205" },
    .{ .src = "paramset ps mo; real o;\n`begin_keywords \"1364-2005\"\nendparamset", .digital = false, .old = "E0202" },
    .{ .src = "connectrules c;\n`begin_keywords \"1364-2005\"\nendconnectrules", .digital = false, .old = "E0202" },
    .{ .src = "connectrules c; connect a2d foo; endconnectrules", .digital = false, .old = "E0207" },
    .{ .src = "connectrules c; connect a2d output elec, output dig; endconnectrules", .digital = false, .old = "E0207" },
    .{ .src = "module m(input a, output y); generate if (1) begin specify (a => y) = 1; endspecify end endgenerate endmodule", .digital = false, .old = "E0229" },
    .{ .src = "module m; generate specparam s = 1; endgenerate endmodule", .digital = false, .old = "E0229" },
    .{ .src = "module m(a); generate input a; endgenerate endmodule", .digital = false, .old = "E0229" },
    .{ .src = "module m(a); input a; if (1) begin output a; end endmodule", .digital = false, .old = "E0229" },
    .{ .src = "module m(input a, output y); specify (a => y) = 1; endspecify endmodule", .digital = false, .old = "" },
    .{ .src = "module m; specparam s = 1; endmodule", .digital = false, .old = "" },
    .{ .src = "module m(a); input a; endmodule", .digital = false, .old = "" },
    .{ .src = "primitive u(q, a); output q; reg q; input a; table (01x) : ? : 1; endtable endprimitive", .digital = false, .old = "E0233" },
    .{ .src = "primitive u(q, a); output q; reg q; input a; table (0) : ? : 1; endtable endprimitive", .digital = false, .old = "E0233" },
    .{ .src = "primitive u(q, a); output q; reg q; input a; table 0) : ? : 1; endtable endprimitive", .digital = false, .old = "E0233" },
    .{ .src = "primitive u(q, a); output q; reg q; input a; table (01) : ? : 1; endtable endprimitive", .digital = false, .old = "" },
    .{ .src = "primitive u(q, a); output q; reg q; input a; table (?b) : ? : 1; endtable endprimitive", .digital = false, .old = "" },
    .{ .src = "primitive u(q, a); output q; reg q; input a; table 0 : 01 : 1; endtable endprimitive", .digital = false, .old = "E0233" },
    .{ .src = "primitive u(q, a); output q; reg q; input a; table 0 : : 1; endtable endprimitive", .digital = false, .old = "E0233" },
    .{ .src = "module m(input [3:0] a, output y); specify (a[0 +: 4'shf] => y) = 1; endspecify endmodule", .digital = false, .old = "" },
    .{ .src = "module m; wire [7:0] n; pullup u [7:0] (n); endmodule", .digital = true, .old = "" },
    .{ .src = "module m; event ev [0:1]; initial @(ev[0]) ; endmodule", .digital = true, .old = "" },
    .{ .src = "module m; event ev [0:1]; initial @ev[0] ; endmodule", .digital = true, .old = "E0209" },
    .{ .src = "module m(a, p); input a; output [1:0] p; buf b0(p[0], a); buf b1(p[1], a); specify (a *> p) = 1; endspecify endmodule", .digital = true, .old = "" },
    .{ .src = "module m(a, p); input a; output [1:0] p; buf b0(p[0], a); buf b1(p[0], a); specify (a *> p) = 1; endspecify endmodule", .digital = true, .old = "E0245", .sema = true },
    .{ .src = "module m(a, p); input a; output [1:0] p; buf b0(p[0], a); assign p = 0; specify (a *> p) = 1; endspecify endmodule", .digital = true, .old = "E0245", .sema = true },
    .{ .src = "module m; if (1) begin : b end initial begin : b end endmodule", .digital = true, .old = "E0230" },
    .{ .src = "module m; task t(a); begin end endtask endmodule", .digital = true, .old = "E0207" },
    .{ .src = "module m; task t(input a, b); begin end endtask endmodule", .digital = true, .old = "" },
    .{ .src = "module m; reg [3:0] i; reg r; initial r = ~ &i; endmodule", .digital = true, .old = "E0209" },
    .{ .src = "module m; reg r; initial r = !!r; endmodule", .digital = true, .old = "E0209" },
    .{ .src = "module m; reg r; initial r = !(!r) + - r - -r; endmodule", .digital = true, .old = "" },
    .{ .src = "module m; initial #4'd2 ; endmodule", .digital = true, .old = "E0207" },
    .{ .src = "module m; initial #(4'd2) ; endmodule", .digital = true, .old = "" },
};

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

/// The binary node at `n` as (operator text, lhs, rhs).
fn binary(tree: *const Ast, n: Ast.Node.Index) struct { []const u8, Ast.Node.Index, Ast.Node.Index } {
    std.debug.assert(tree.nodeTag(n) == .binary);
    const d = tree.nodeData(n).node_and_node;
    return .{ tree.tokenSlice(tree.nodeMainToken(n)), d[0], d[1] };
}

/// The right-hand side of the module's first analog contribution or
/// assignment.
fn analogRhs(tree: *const Ast) Ast.Node.Index {
    const m = full.moduleDecl(tree, tree.rootDecls()[0]);
    for (m.items) |item| if (tree.nodeTag(item) == .analog) {
        return tree.nodeData(tree.nodeData(item).node).node_and_node[1];
    };
    unreachable;
}

fn deep(result: *anyerror!void) void {
    result.* = deepCases();
}

fn deepCases() !void {
    const gpa = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    // 5,000 nested parentheses parse; 20,000 are `nesting_too_deep`, not a
    // stack overflow. A 100,000-operand chain costs no depth at all.
    for ([_]struct { usize, bool }{ .{ 5_000, true }, .{ 20_000, false } }) |c| {
        src.clearRetainingCapacity();
        try src.appendSlice(gpa, "module m; real x; analog x = ");
        try src.appendNTimes(gpa, '(', c[0]);
        try src.append(gpa, '1');
        try src.appendNTimes(gpa, ')', c[0]);
        try src.appendSlice(gpa, "; endmodule");
        try src.append(gpa, 0);
        var tree = try Ast.parse(gpa, src.items[0 .. src.items.len - 1 :0], .{});
        defer tree.deinit(gpa);
        if (c[1]) try testing.expectEqual(0, tree.errors.len) else try testing.expectEqual(.nesting_too_deep, tree.errors[0].tag);
    }
    src.clearRetainingCapacity();
    try src.appendSlice(gpa, "module m; real x; analog x = 1");
    for (0..100_000) |_| try src.appendSlice(gpa, "+1");
    try src.appendSlice(gpa, "; endmodule");
    try src.append(gpa, 0);
    var tree = try Ast.parse(gpa, src.items[0 .. src.items.len - 1 :0], .{});
    defer tree.deinit(gpa);
    try testing.expectEqual(0, tree.errors.len);
}

fn parseSmall(gpa: std.mem.Allocator) !void {
    var tree = try Ast.parse(gpa, "module m(p); inout p; electrical p; parameter real r = 1 from (0:inf); analog I(p) <+ V(p) / r; endmodule", .{});
    tree.deinit(gpa);
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

test "every row of the old parser's tables: refused iff the old parser refused it, but for rules over names (Sema's)" {
    var bad: usize = 0;
    for (old_cases) |c| {
        const leaves = for (semantic) |code| {
            if (std.mem.eql(u8, code, c.old)) break true;
        } else false;
        const want = c.old.len != 0 and !leaves and !c.sema;
        var tree = try Ast.parse(testing.allocator, c.src, .{ .keywords = if (c.digital) .v1364_2005 else .vams_2023 });
        defer tree.deinit(testing.allocator);
        if ((tree.errors.len != 0) == want) continue;
        bad += 1;
        std.debug.print("old {s}, new {s}: {s}\n", .{ if (c.old.len == 0) "accepts" else c.old, if (tree.errors.len == 0) "accepts" else @tagName(tree.errors[0].tag), c.src });
    }
    try testing.expectEqual(0, bad);
}

test "Table 4-3: left associativity, `**` included, and `?:` the one right-associative operator (§4.2.2)" {
    var tree = try parseOk("module m; real x; analog x = 1 - 2 - 3 + 2 ** 3 ** 2 * 4; endmodule", .vams_2023);
    defer tree.deinit(testing.allocator);
    // ((1 - 2) - 3) + ((2 ** 3) ** 2) * 4
    const plus = binary(&tree, analogRhs(&tree));
    try testing.expectEqualStrings("+", plus[0]);
    try testing.expectEqualStrings("-", binary(&tree, plus[1])[0]);
    try testing.expectEqualStrings("-", binary(&tree, binary(&tree, plus[1])[1])[0]);
    const times = binary(&tree, plus[2]);
    try testing.expectEqualStrings("*", times[0]);
    const pow = binary(&tree, times[1]);
    try testing.expectEqualStrings("**", pow[0]);
    try testing.expectEqualStrings("**", binary(&tree, pow[1])[0]);

    var t2 = try parseOk("module m; real x, a, b, c, d, e; analog x = a ? b : c ? d : e; endmodule", .vams_2023);
    defer t2.deinit(testing.allocator);
    const outer = analogRhs(&t2);
    try testing.expectEqual(.ternary, t2.nodeTag(outer));
    const arms = t2.extraData(t2.nodeData(outer).node_and_extra[1], Ast.Node.Ternary);
    try testing.expectEqual(.ternary, t2.nodeTag(arms.@"else"));
}

test "A.8.3: a unary operand is a primary, so `- -x` is no expression and `a - -b` is" {
    try testing.expectEqual(.expected_expr, try firstError("module m; real x; analog x = - -x; endmodule", .vams_2023));
    var tree = try parseOk("module m; real x, a, b; analog x = a - -b; endmodule", .vams_2023);
    defer tree.deinit(testing.allocator);
    try testing.expectEqual(.unary, tree.nodeTag(binary(&tree, analogRhs(&tree))[2]));
}

test "A.6.5 `@*` in each of its four spellings is an event statement with no expression" {
    for ([_][:0]const u8{
        "module m; reg x; initial @* x = 1; endmodule",
        "module m; reg x; initial @(*) x = 1; endmodule",
        "module m; reg x; initial @( *) x = 1; endmodule",
        "module m; reg x; initial @( * ) x = 1; endmodule",
    }) |src| {
        var tree = try parseOk(src, .vams_2023);
        defer tree.deinit(testing.allocator);
        const m = full.moduleDecl(&tree, tree.rootDecls()[0]);
        const ev = tree.nodeData(m.items[1]).node;
        try testing.expectEqual(.event_stmt, tree.nodeTag(ev));
        try testing.expectEqual(Ast.Node.OptionalIndex.none, tree.nodeData(ev).opt_node_and_node[0]);
    }
}

test "§10.6: `begin_keywords frees a newer word as a name, the construct keeps its keyword" {
    var tree = try parseOk(
        \\`begin_keywords "1364-2005"
        \\module m(sin, n); input sin, n; electrical sin, n;
        \\  analog I(sin, n) <+ V(sin, n);
        \\endmodule
        \\`end_keywords
    , .vams_2023);
    defer tree.deinit(testing.allocator);
    try testing.expectEqual(.unknown_keyword_set, try firstError("`begin_keywords \"VAMS-2.4\" module m; endmodule", .vams_2023));
    try testing.expectEqual(.unmatched_end_keywords, try firstError("`end_keywords module m; endmodule", .vams_2023));
    // A 1364 language names no newer set, and frees every Verilog-AMS word:
    // `connect u(a);` instantiates `connect`; `analog begin` is refused.
    try testing.expectEqual(.unknown_keyword_set, try firstError("`begin_keywords \"VAMS-2.3\" module m; endmodule", .v1364_2005));
    var v = try parseOk("module connect(a); input a; endmodule module m; wire a, sin; connect u(a); endmodule", .v1364_2005);
    defer v.deinit(testing.allocator);
    try testing.expectEqual(.vams_construct_under_1364, try firstError("module m; analog begin end endmodule", .v1364_2005));
}

test "A.6.4 refuses the digital statement forms in an analog block; an initial body takes them" {
    try testing.expectEqual(.digital_statement_in_analog, try firstError("module m; real x; analog #1 x = 1; endmodule", .vams_2023));
    try testing.expectEqual(.expected_statement, try firstError("module m; real x; analog x <= 1; endmodule", .vams_2023));
    try testing.expectEqual(.null_statement, try firstError("module m; analog begin ; end endmodule", .vams_2023));
    var tree = try parseOk("module m; reg c; integer x; initial begin #1 x <= repeat (2) @(posedge c) 1; wait (c) t(x); end endmodule", .vams_2023);
    defer tree.deinit(testing.allocator);
    // An analog event's block keeps the null statement (A.6.4).
    var ev = try parseOk("module m; analog @(initial_step) begin ; end endmodule", .vams_2023);
    defer ev.deinit(testing.allocator);
}

test "literals are validated where they stand, decoded on demand (§2.6.1, §2.7)" {
    try testing.expectEqual(.invalid_number, try firstError("module m; parameter p = 0'h1; endmodule", .vams_2023));
    try testing.expectEqual(.invalid_string_escape, try firstError("module m; analog $strobe(\"\\400\"); endmodule", .vams_2023));
}

test "a parse keeps every error and goes on: one per bad item" {
    var tree = try Ast.parse(testing.allocator, "module m; real; real; endmodule module n; = ; endmodule", .{});
    defer tree.deinit(testing.allocator);
    try testing.expectEqual(3, tree.errors.len);
    try testing.expectEqual(2, tree.rootDecls().len);
}

test "nesting is capped at `Parse.max_depth` with its own error, on a 256 MiB worker stack" {
    var result: anyerror!void = {};
    const t = try std.Thread.spawn(.{ .stack_size = 256 << 20 }, deep, .{&result});
    t.join();
    try result;
}

test "an allocation failure anywhere in a parse is OutOfMemory, and leaks nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, parseSmall, .{});
}

test "§10.6 / IEEE 1364-2005 §19.11 keyword sets, as the old parser's tests read them" {
    const Row = struct { src: [:0]const u8, set: Ast.KeywordSet, ok: bool };
    const own = "module m; analog function real expm1; input x; real x; expm1 = exp(x) - 1.0; endfunction\nendmodule\n";
    for ([_]Row{
        // VAMS-2023's `sin` is reserved, 1364-2005's is not.
        .{ .src = "`begin_keywords \"VAMS-2023\"\nmodule m2(sin, n); inout sin, n; endmodule\n`end_keywords\n", .set = .vams_2023, .ok = false },
        // `end_keywords restores the set.
        .{ .src = "`begin_keywords \"1364-1995\"\n`end_keywords\nmodule m(sin); endmodule\n", .set = .vams_2023, .ok = false },
        .{ .src = "`begin_keywords \"1800-2017\"\n`end_keywords\n", .set = .vams_2023, .ok = false },
        // An open `begin_keywords at the end of the file is no error.
        .{ .src = "`begin_keywords \"VAMS-2.3\"\nmodule m; endmodule\n", .set = .vams_2023, .ok = true },
        .{ .src = "module m;\n`begin_keywords \"1364-2005\"\nendmodule\n`end_keywords\n", .set = .vams_2023, .ok = false },
        .{ .src = "module m; reg analog; wire sin; endmodule\n", .set = .v1364_2005, .ok = true },
        .{ .src = "module m; reg analog; wire sin; endmodule\n", .set = .vams_2023, .ok = false },
        .{ .src = "module connect; endmodule\nmodule m; reg string; connect u(); initial begin string = 1; end endmodule\n", .set = .v1364_2005, .ok = true },
        .{ .src = "`begin_keywords \"1364-2001-noconfig\"\nmodule m; reg config; endmodule\n`end_keywords\n", .set = .v1364_2001, .ok = true },
        // Annex G.7 item 7780: a model's own `expm1`.
        .{ .src = own, .set = .vams_2023, .ok = true },
        .{ .src = "`begin_keywords \"VAMS-2.3\"\n" ++ own ++ "`end_keywords\n", .set = .vams_2023, .ok = true },
        .{ .src = "nature N; endnature\nmodule m; analog begin end\nreg r; endmodule\n", .set = .v1364_2005, .ok = false },
    }) |row| {
        var tree = try Ast.parse(testing.allocator, row.src, .{ .keywords = row.set });
        defer tree.deinit(testing.allocator);
        testing.expectEqual(row.ok, tree.errors.len == 0) catch |e| {
            std.debug.print("{s}\n", .{row.src});
            return e;
        };
    }
}
