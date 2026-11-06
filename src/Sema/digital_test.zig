//! The digital lowering of a VAMS §7 mixed module: its digital half in,
//! one `std_sim.Program` out. Oracle (a metamorphic relation): the analog
//! half adds nothing to the Program, so blanking it out of the source (each
//! `/*<*/ ... /*>*/` span replaced by as many spaces, every other byte where
//! it was) and lowering the digital module left standing gives the same
//! Program, row for row.
//! Cites: VAMS-2023 §7.1, §7.2.1 (a continuous port is no digital port),
//! §7.2.2.
//!
//! Contents: tests only.

const std = @import("std");
const vams = @import("vams");
const std_sim = @import("std_sim");
const Zcu = @import("../Zcu.zig");
const Sema = @import("../Sema.zig");
const digital = @import("digital.zig");
const Program = std_sim.Program;

/// The disciplines the mixed examples' nets take: a continuous one and a
/// discrete one (VAMS §3.6.2.2).
const prelude =
    \\`timescale 1ns/1ns
    \\nature Voltage; access = V; units = "V"; abstol = 1e-6; endnature
    \\nature Current; access = I; units = "A"; abstol = 1e-12; endnature
    \\discipline electrical; potential Voltage; flow Current; enddiscipline
    \\discipline ddiscrete; domain discrete; enddiscipline
    \\
;

/// A connect module on `n` that drives its own discrete port (§9.22.6's
/// `assign d = out`), two ordinary drivers and two ordinary receivers.
const driver_bench =
    \\connectmodule c2e(d, a);
    \\  input d; output a; ddiscrete d; electrical a;
    \\  reg out; assign d = out;
    \\  wire w; assign w = out;
    \\  initial begin out = 1'b0; #1 $display("%0d %0d %0d", $driver_count(d), $receiver_count(d), $driver_count(w)); end
    \\  analog V(a) <+ 0.0;
    \\endmodule
    \\module drv(o); output o; ddiscrete o; reg o; initial o = 1'b0; endmodule
    \\module ear(i); input i; ddiscrete i; endmodule
    \\module top; electrical n; drv hi(.o(n)); drv lo(.o(n)); ear e1(.i(n)); ear e2(.i(n)); endmodule
    \\connectrules r; connect c2e merged inout ddiscrete, inout electrical; endconnectrules
    \\
;

// ---- private ----

/// Lowers `mixed` and its twin with the analog half blanked; both must
/// lower, to equal Programs.
fn expectSameProgram(comptime mixed: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const twin = try blank(a, mixed);
    try std.testing.expectEqual(mixed.len, twin.len);
    const m = try lowerSource(a, mixed, true);
    const t = try lowerSource(a, twin, false);
    try expectEqualPrograms(&t.program, &m.program);
}

/// `src` with every `/*<*/ ... /*>*/` span, markers included, spaces.
fn blank(a: std.mem.Allocator, src: []const u8) ![]u8 {
    const out = try a.dupe(u8, src);
    var at: usize = 0;
    while (std.mem.findPos(u8, out, at, "/*<*/")) |open| {
        const close = std.mem.findPos(u8, out, open, "/*>*/").? + "/*>*/".len;
        @memset(out[open..close], ' ');
        at = close;
    }
    return out;
}

/// `src` through the vams front end, elaboration (one root, as a device
/// compile has) and the digital lowering (of a `mixed` design's digital
/// half, or of a digital design); a refusal fails the test with its reason.
fn lowerSource(a: std.mem.Allocator, src: []const u8, mixed: bool) !digital.Lowered {
    var pp: vams.Preprocessor = .init(a, .{ .std_defs = false });
    try pp.addUnit("mixed.vams", src);
    while (try pp.run()) |_| return error.UnexpectedInclude;
    const out = try a.create(vams.Preprocessor.Output);
    out.* = pp.output();
    try std.testing.expect(!out.failed);
    const text = try a.dupeSentinel(u8, out.text, 0);
    const tree = try a.create(vams.Ast);
    tree.* = try vams.Ast.parse(a, text, .{});
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    const vir = try vams.AstGen.generate(a, tree, .{ .directives = out.directives });
    var zcu: Zcu = try .init(a);
    _ = try zcu.addFile("mixed.vams", vir, 0);
    try Sema.elaborate(&zcu, .{ .roots = .first });
    for (zcu.failed.items(.code)) |code| if (@tagName(code)[0] == 'E') {
        std.debug.print("elaboration refuses it: {t}\n", .{code});
        return error.TestUnexpectedResult;
    };
    var why: digital.Why = .{};
    const lowered = digital.lower(a, &zcu, .{ .sources = &.{.{ .tree = tree, .pp = out }}, .mixed = mixed }, &why) catch |e| {
        std.debug.print("lowering ({s}) {t}: {s} (at {d})\n", .{ if (mixed) "mixed" else "twin", e, why.text, why.at });
        return error.TestUnexpectedResult;
    };
    return lowered;
}

/// Every table of `got` equals `want`'s: each `MultiArrayList` column and
/// each other field compared deep.
fn expectEqualPrograms(want: *const Program, got: *const Program) !void {
    inline for (comptime std.meta.fieldNames(Program)) |name| {
        const w = @field(want, name);
        const g = @field(got, name);
        if (comptime isMultiArrayList(@FieldType(Program, name))) {
            try std.testing.expectEqual(w.len, g.len);
            inline for (comptime std.meta.fieldNames(@TypeOf(w.get(0)))) |col| {
                std.testing.expectEqualDeep(w.items(@field(@TypeOf(w).Field, col)), g.items(@field(@TypeOf(g).Field, col))) catch |e| {
                    std.debug.print("Program.{s}.{s} differs\n", .{ name, col });
                    return e;
                };
            }
        } else std.testing.expectEqualDeep(w, g) catch |e| {
            std.debug.print("Program.{s} differs\n", .{name});
            return e;
        };
    }
}

/// Whether slot `src` drives the net whose slot is `net_slot` through a
/// port (a `.bridge` driver, §12.3.9.2).
fn drives(p: *const Program, src: u32, net_slot: u32) bool {
    for (p.drivers) |d| {
        if (p.nets[d.net].slot != net_slot) continue;
        if (d.source == .bridge and d.source.bridge.src == src) return true;
    }
    return false;
}

/// The §17 transcript of running `p` in std_sim to its end.
fn transcript(a: std.mem.Allocator, p: *const Program) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var st: std_sim.State = try .init(a, p, &out.writer);
    try std_sim.Interp.run(&st);
    return out.written();
}

/// The rejection lowering `src` (mixed) raises; any other outcome fails.
fn rejection(a: std.mem.Allocator, src: []const u8) !digital.Why {
    var pp: vams.Preprocessor = .init(a, .{ .std_defs = false });
    try pp.addUnit("mixed.vams", src);
    while (try pp.run()) |_| return error.UnexpectedInclude;
    const out = try a.create(vams.Preprocessor.Output);
    out.* = pp.output();
    const text = try a.dupeSentinel(u8, out.text, 0);
    const tree = try a.create(vams.Ast);
    tree.* = try vams.Ast.parse(a, text, .{});
    const vir = try vams.AstGen.generate(a, tree, .{ .directives = out.directives });
    var zcu: Zcu = try .init(a);
    _ = try zcu.addFile("mixed.vams", vir, 0);
    try Sema.elaborate(&zcu, .{ .roots = .first });
    var why: digital.Why = .{};
    _ = digital.lower(a, &zcu, .{ .sources = &.{.{ .tree = tree, .pp = out }}, .mixed = true }, &why) catch |e| switch (e) {
        error.Rejected => return why,
        else => return e,
    };
    return error.TestExpectedError;
}

fn isMultiArrayList(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Field") and @hasDecl(T, "Slice");
}

test "§7.2.2 a continuous assignment and an initial beside an analog block: the digital half's Program" {
    try expectSameProgram(prelude ++
        \\module mx(/*<*/vo/*>*/);
        \\  /*<*/inout vo; electrical vo;/*>*/
        \\  reg a; wire b;
        \\  initial a = 1'b1;
        \\  assign b = ~a;
        \\  /*<*/analog V(vo) <+ b ? 1.0 : 0.0;/*>*/
        \\endmodule
        \\
    );
}

test "§7.2.2 an initialized variable and a real no discrete process writes are the analog block's" {
    try expectSameProgram(prelude ++
        \\module mx(/*<*/vo/*>*/);
        \\  /*<*/inout vo; electrical vo;/*>*/
        \\  /*<*/real gain = 2.0; real x;/*>*/
        \\  integer count;
        \\  reg clk;
        \\  initial begin clk = 0; count = 0; end
        \\  always #5 clk = ~clk;
        \\  always @(posedge clk) count = count + 1;
        \\  /*<*/analog begin x = V(vo); V(vo) <+ gain * count; end/*>*/
        \\endmodule
        \\
    );
}

test "§7.3.6.4 a real the analog block writes and a discrete process reads is declared without its initializer" {
    try expectSameProgram(prelude ++
        \\module mx(/*<*/vo/*>*/);
        \\  /*<*/inout vo; electrical vo;/*>*/
        \\  real level/*<*/ = 0.25/*>*/;
        \\  reg hi;
        \\  always #1 hi = level > 0.5;
        \\  /*<*/analog level = V(vo);/*>*/
        \\endmodule
        \\
    );
}

test "§7.3.5 an analog event in a digital event control: one monitor row, its event slot the term the process waits on" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const lowered = try lowerSource(arena_state.allocator(), prelude ++
        \\module mx(p); inout p; electrical p;
        \\  integer n;
        \\  initial n = 0;
        \\  always @(cross(V(p) - 0.5, 1)) n = n + 1;
        \\  analog I(p) <+ 0.0;
        \\endmodule
        \\
    , true);
    const p = &lowered.program;
    // §7.3.5 `cross(expr, dir)`: one monitor, its two arguments as real
    // rows: `V(p) - 0.5` (a probe of `p` alone) and the direction 1.
    try std.testing.expectEqual(@as(usize, 1), p.monitors.len);
    const m = p.monitors[0];
    try std.testing.expectEqual(Program.A2d.Kind.cross, m.kind);
    const args = p.list(m.args);
    try std.testing.expectEqual(@as(usize, 2), args.len);
    const tags = p.exprs.items(.tag);
    const data = p.exprs.items(.data);
    try std.testing.expectEqual(Program.Expr.Tag.real_sub, tags[args[0]]);
    try std.testing.expectEqual(Program.Expr.Tag.probe, tags[data[args[0]].a]);
    const probe = p.extraData(Program.Probe, data[data[args[0]].a].a);
    try std.testing.expectEqualStrings("p", p.str(probe.a));
    try std.testing.expectEqual(@as(u32, 0), probe.b.len);
    try std.testing.expectEqual(Program.Expr.Tag.real_of_int, tags[args[1]]);
    try std.testing.expect(p.has_probes);
    // The `always` waits on exactly the monitor's event slot.
    const insts = p.insts.items(.tag);
    const waits = for (insts, 0..) |t, k| {
        if (t == .wait_event) break p.insts.items(.data)[k].a;
    } else return error.TestUnexpectedResult;
    // `wait_event`'s `a` is the `List` of its terms; a term's first word is
    // the slot it watches.
    try std.testing.expectEqual(m.event, p.list(p.extraData(Program.List, waits))[0]);
}

test "§7.3 the mixed host's names: each variable and net by its path below the root, as Sema's card rows spell it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const lowered = try lowerSource(arena_state.allocator(), prelude ++
        \\module child(clk); output clk; reg clk; initial clk = 0; always #5 clk = ~clk; endmodule
        \\module mx(vo); inout vo; electrical vo; wire c; real r; child u(c); analog begin r = V(vo); V(vo) <+ c; end endmodule
        \\
    , true);
    // `vo` is continuous and `r` the analog block's (§7.2.1, §7.2.2):
    // neither is the digital half's. `c` is the root's, `clk` the child `u`'s.
    const n = lowered.names;
    try std.testing.expectEqual(@as(usize, 2), n.len);
    try std.testing.expectEqualStrings("c", n[0].path);
    try std.testing.expectEqualStrings("u.clk", n[1].path);
    for (n) |x| try std.testing.expectEqual(Program.Ty.int(1, false), x.ty);
    try std.testing.expect(n[0].slot != n[1].slot);
}

test "§7.2.1 a net of a discrete discipline and a reg's discipline declaration are the digital half's (regression: driver_state_histogram.va crashed)" {
    try expectSameProgram(prelude ++
        \\module mx(/*<*/vo/*>*/);
        \\  /*<*/inout vo; electrical vo;/*>*/
        \\  /*<*/ddiscrete d;/*>*/ wire d;
        \\  /*<*/ddiscrete o;/*>*/ reg o;
        \\  assign d = o;
        \\  initial o = 1'b1;
        \\  /*<*/analog V(vo) <+ d;/*>*/
        \\endmodule
        \\
    );
}

test "§7.3.6.4 an analog variable a continuous assignment reads is the digital half's to receive (analog_event_variable_drives_continuous_assign.va)" {
    try expectSameProgram(prelude ++
        \\module mx(/*<*/vo/*>*/);
        \\  /*<*/inout vo; electrical vo;/*>*/
        \\  real level;
        \\  wire hi;
        \\  assign hi = level > 0.5;
        \\  /*<*/analog begin @(initial_step) level = 0.75; V(vo) <+ hi; end/*>*/
        \\endmodule
        \\
    );
}

test "§19.8 a mixed design's modules ahead of its first `timescale take it (lib/sim/digital's mixedTimescales)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    // `ana` and the disciplines come before any directive, as the shipped
    // prelude's modules do; the source's `timescale is 1ns/1ps.
    const lowered = try lowerSource(arena_state.allocator(),
        \\nature Voltage; access = V; units = "V"; abstol = 1e-6; endnature
        \\nature Current; access = I; units = "A"; abstol = 1e-12; endnature
        \\discipline electrical; potential Voltage; flow Current; enddiscipline
        \\module ana(p); inout p; electrical p; analog V(p) <+ 0.0; endmodule
        \\`timescale 1ns/1ps
        \\module mx(vo); inout vo; electrical vo; reg r; initial #1 r = 1; ana u(vo); endmodule
        \\
    , true);
    // The design's tick is the finest precision: 1 ps, 10^-12 s.
    try std.testing.expectEqual(@as(i32, -12), lowered.program.finest);
}

test "§7.8 an inserted connect module's discrete port joins the digital net it bridges (net_read_by_digital_code_resolves_digital.va)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const lowered = try lowerSource(arena_state.allocator(), prelude ++
        \\connectmodule a2d(el, cm);
        \\  input el; output cm; electrical el; ddiscrete cm; reg cm;
        \\  analog I(el) <+ V(el) / 1000.0;
        \\  initial cm = 1'b0;
        \\endmodule
        \\module src(p); output p; electrical p; analog I(p) <+ -1.0e-3; endmodule
        \\module top;
        \\  ddiscrete n; wire n;
        \\  reg seen;
        \\  src u1(n);
        \\  always @(n) seen = n;
        \\endmodule
        \\connectrules rules; connect a2d; endconnectrules
        \\
    , true);
    // §7.8.3 one bridge under `top` on `n`. Its `cm` is an output `reg`
    // port: its own slot, driving `n` through the port (§12.3.9.2). `el`
    // and `u1.p` are continuous, not the digital half's.
    var n_slot: ?u32 = null;
    var cm_slot: ?u32 = null;
    for (lowered.names) |x| {
        if (std.mem.eql(u8, x.path, "n")) n_slot = x.slot;
        if (std.mem.endsWith(u8, x.path, ".cm")) cm_slot = x.slot;
        try std.testing.expect(!std.mem.endsWith(u8, x.path, ".el") and !std.mem.eql(u8, x.path, "u1.p"));
    }
    try std.testing.expect(drives(&lowered.program, cm_slot.?, n_slot.?));
}

test "§7.2.2 a process naming fewer instructions than the names read before it (regression: specify_paths_design_runs.va crashed)" {
    try expectSameProgram(prelude ++
        \\module mx(/*<*/vo/*>*/);
        \\  /*<*/inout vo; electrical vo;/*>*/
        \\  reg a, b, c, d, e, f, g, h, i, j;
        \\  initial begin a = 0; b = 0; c = 0; d = 0; e = 0; f = 0; g = 0; h = 0; i = 0; j = 0; end
        \\  always #1 ;
        \\  /*<*/analog V(vo) <+ a;/*>*/
        \\endmodule
        \\
    );
}

test "§7.8 a digital port meeting a continuous net: the bridge's segment joins them, the net stays analog (both_halves_of_the_bridge_execute.va)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const lowered = try lowerSource(arena_state.allocator(), prelude ++
        \\connectmodule d2a(cm, el);
        \\  input cm; output el; ddiscrete cm; electrical el;
        \\  reg lvl; always @(cm) lvl = cm;
        \\  analog I(el) <+ 0.0;
        \\endmodule
        \\module inv(d, q); input d; output q; ddiscrete d, q; reg q; initial q = 1'b0; always @(d) q = ~d; endmodule
        \\module top;
        \\  electrical y1; ddiscrete s; reg r;
        \\  assign s = r;
        \\  inv u1(s, y1);
        \\  analog I(y1) <+ V(y1) / 1000.0;
        \\endmodule
        \\connectrules rules; connect d2a; endconnectrules
        \\
    , true);
    // `y1` is continuous: not the digital half's. The bridge's input net
    // `cm` is its segment, which `u1.q` (an output reg) drives (§12.3.9.2).
    var q: ?u32 = null;
    var cm: ?u32 = null;
    for (lowered.names) |x| {
        try std.testing.expect(!std.mem.eql(u8, x.path, "y1"));
        if (std.mem.eql(u8, x.path, "u1.q")) q = x.slot;
        if (std.mem.endsWith(u8, x.path, ".cm")) cm = x.slot;
    }
    try std.testing.expect(drives(&lowered.program, q.?, cm.?));
}

test "§7.8.3.2 split: each port's own bridge and segment, so one port's driver reaches only its bridge (split_one_instance_per_port.va)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const lowered = try lowerSource(arena_state.allocator(), prelude ++
        \\connectmodule d2a(cm, el);
        \\  input cm; output el; ddiscrete cm; electrical el;
        \\  reg lvl; always @(cm) lvl = cm;
        \\  analog I(el) <+ 0.0;
        \\endmodule
        \\module src(q); output q; ddiscrete q; reg q; initial q = 1'b0; endmodule
        \\module top;
        \\  electrical a;
        \\  src u1(a);
        \\  src u2(a);
        \\  analog I(a) <+ V(a) / 1000.0;
        \\endmodule
        \\connectrules rules; connect d2a split; endconnectrules
        \\
    , true);
    // §7.8.3.2 "one connect module per port": `a__u1__q` and `a__u2__q`
    // (§7.8.5's split names), each `cm` the segment its own port drives.
    var q1: ?u32 = null;
    var q2: ?u32 = null;
    var cm1: ?u32 = null;
    var cm2: ?u32 = null;
    for (lowered.names) |x| {
        if (std.mem.eql(u8, x.path, "u1.q")) q1 = x.slot;
        if (std.mem.eql(u8, x.path, "u2.q")) q2 = x.slot;
        if (std.mem.eql(u8, x.path, "a__u1__q.cm")) cm1 = x.slot;
        if (std.mem.eql(u8, x.path, "a__u2__q.cm")) cm2 = x.slot;
    }
    try std.testing.expect(cm1.? != cm2.?);
    const p = &lowered.program;
    try std.testing.expect(drives(p, q1.?, cm1.?) and drives(p, q2.?, cm2.?));
    try std.testing.expect(!drives(p, q1.?, cm2.?) and !drives(p, q2.?, cm1.?));
}

test "§7.8.5.1 a primitive's terminal on a continuous net: the gate drives its bridge's segment (prim_connect_* fixtures)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const lowered = try lowerSource(arena_state.allocator(), prelude ++
        \\connectmodule d2a(cm, el);
        \\  input cm; output el; ddiscrete cm; electrical el;
        \\  reg lvl; always @(cm) lvl = cm;
        \\  analog I(el) <+ 0.0;
        \\endmodule
        \\`default_discipline ddiscrete
        \\module top;
        \\  electrical y; reg r;
        \\  initial r = 1'b1;
        \\  buf b1(y, r);
        \\  analog I(y) <+ V(y) / 1000.0;
        \\endmodule
        \\`default_discipline
        \\connectrules rules; connect d2a; endconnectrules
        \\
    , true);
    // `y` stays analog; the buffer's output terminal is the bridge's `cm`.
    var cm: ?u32 = null;
    for (lowered.names) |x| {
        try std.testing.expect(!std.mem.eql(u8, x.path, "y"));
        if (std.mem.endsWith(u8, x.path, ".cm")) cm = x.slot;
    }
    const p = &lowered.program;
    const gate_drives = for (p.drivers) |d| {
        if (d.source == .gate and p.nets[d.net].slot == cm.?) break true;
    } else false;
    try std.testing.expect(gate_drives);
}

test "§7.8.5.1 split on a gate array: each lane reads its own bridge's segment (prim_connect_gate_array.va)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const lowered = try lowerSource(arena_state.allocator(), prelude ++
        \\connectmodule a2d(el, cm);
        \\  input el; output cm; electrical el; ddiscrete cm; reg cm;
        \\  analog I(el) <+ V(el) / 1000.0;
        \\  initial cm = 1'b1;
        \\endmodule
        \\`default_discipline ddiscrete
        \\module top;
        \\  electrical a;
        \\  wire [1:0] y; reg [1:0] b;
        \\  and g[1:0] (y, a, b);
        \\  initial b = 2'b10;
        \\  analog I(a) <+ V(a) / 1000.0;
        \\endmodule
        \\`default_discipline
        \\connectrules rules; connect a2d split; endconnectrules
        \\
    , true);
    // §7.8.5 split names `a__g[1]__in1` and `a__g[0]__in1`; §12.1.2 `g[1]`
    // is the array's most significant lane, bit 1. Each bridge's `cm` is an
    // output reg: it drives its segment, which its lane's gate reads.
    var cm = [2]?u32{ null, null };
    for (lowered.names) |x| {
        if (std.mem.eql(u8, x.path, "a__g[0]__in1.cm")) cm[0] = x.slot;
        if (std.mem.eql(u8, x.path, "a__g[1]__in1.cm")) cm[1] = x.slot;
    }
    try std.testing.expect(cm[0].? != cm[1].?);
    const p = &lowered.program;
    const tags = p.exprs.items(.tag);
    const data = p.exprs.items(.data);
    var seen = [2]bool{ false, false };
    for (p.drivers) |d| {
        if (d.source != .gate) continue;
        const lane = d.source.gate.lane.?;
        const first_in = p.list(d.source.gate.ins)[0]; // `and`'s first input, `a`
        try std.testing.expectEqual(Program.Expr.Tag.slot, tags[first_in]);
        try std.testing.expect(drives(p, cm[lane].?, data[first_in].a));
        try std.testing.expect(!drives(p, cm[1 - lane].?, data[first_in].a));
        seen[lane] = true;
    }
    try std.testing.expect(seen[0] and seen[1]);
}

test "§7.8.5.1 split on a gate array's output: each lane drives its own bridge's segment (lib/sim/digital's lane rows)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const lowered = try lowerSource(arena_state.allocator(), prelude ++
        \\connectmodule d2a(cm, el);
        \\  input cm; output el; ddiscrete cm; electrical el;
        \\  reg lvl; always @(cm) lvl = cm;
        \\  analog I(el) <+ 0.0;
        \\endmodule
        \\`default_discipline ddiscrete
        \\module top;
        \\  electrical a;
        \\  reg [1:0] b, c;
        \\  and g[1:0] (a, b, c);
        \\  initial begin b = 2'b11; c = 2'b10; end
        \\  analog I(a) <+ V(a) / 1000.0;
        \\endmodule
        \\`default_discipline
        \\connectrules rules; connect d2a split; endconnectrules
        \\
    , true);
    // §7.8.5 split names `a__g[L]__out`; §12.1.2 `g[1]` is bit 1. Each
    // lane's gate drives the bridge input `cm` of its own name, one bit.
    var cm = [2]?u32{ null, null };
    for (lowered.names) |x| {
        if (std.mem.eql(u8, x.path, "a__g[0]__out.cm")) cm[0] = x.slot;
        if (std.mem.eql(u8, x.path, "a__g[1]__out.cm")) cm[1] = x.slot;
    }
    try std.testing.expect(cm[0].? != cm[1].?);
    const p = &lowered.program;
    var seen = [2]bool{ false, false };
    for (p.drivers) |d| {
        if (d.source != .gate) continue;
        const lane = d.source.gate.lane.?;
        try std.testing.expectEqual(cm[lane].?, p.nets[d.net].slot);
        try std.testing.expectEqual(@as(?u32, null), d.source.gate.out_bit);
        seen[lane] = true;
    }
    try std.testing.expect(seen[0] and seen[1]);
}

test "§7.2.2 a mixed design's string parameter is the analog block's (supply_sensitive_bridge_via_connect_rule.va)" {
    try expectSameProgram(prelude ++
        \\module mx(/*<*/vo/*>*/);
        \\  /*<*/inout vo; electrical vo;/*>*/
        \\  /*<*/parameter string name = "(not_given)";/*>*/
        \\  reg r; initial r = 1'b1;
        \\  /*<*/analog V(vo) <+ r;/*>*/
        \\endmodule
        \\
    );
}

test "A.8.5 a one-operand concatenation as a switch, pull or MOS terminal is its operand (concatenation_as_switch_terminal.va)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The same text with each `{x}` written ` x `: every offset equal.
    const braced = try lowerSource(a, prelude ++
        \\module mx(p); inout p; electrical p;
        \\  reg d, en; wire a, b, u, q;
        \\  assign a = 1'b1;
        \\  tran ({a}, b); pullup ({u}); nmos ({q}, d, en);
        \\  initial begin d = 1'b0; en = 1'b1; end
        \\  analog I(p) <+ V(p);
        \\endmodule
        \\
    , true);
    const plain = try lowerSource(a, prelude ++
        \\module mx(p); inout p; electrical p;
        \\  reg d, en; wire a, b, u, q;
        \\  assign a = 1'b1;
        \\  tran ( a , b); pullup ( u ); nmos ( q , d, en);
        \\  initial begin d = 1'b0; en = 1'b1; end
        \\  analog I(p) <+ V(p);
        \\endmodule
        \\
    , true);
    try expectEqualPrograms(&plain.program, &braced.program);
    try std.testing.expectEqual(@as(usize, 1), braced.program.trans.len);
}

test "§9.22.1/§9.22.2 the counts: ordinary drivers and receivers only, the connect module's own driver not one (driver_count_excludes_connectmodule.va)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const lowered = try lowerSource(a, prelude ++ driver_bench, true);
    // `hi.o` and `lo.o` drive; `e1.i` and `e2.i` receive. §9.22 ¶3 leaves
    // out `assign d = out` (§7.9 puts it on the receivers' net) and the
    // connect module's own `assign w = out`: `w` has no ordinary driver.
    try std.testing.expectEqualStrings("2 2 0\n", try transcript(a, &lowered.program));
}

test "§9.22 a driver access function outside a connect module is E0818" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const why = try rejection(arena_state.allocator(), prelude ++
        \\module top; wire w; assign w = 1'b1; initial $display("%0d", $driver_count(w)); endmodule
        \\
    );
    try std.testing.expectEqual(vams.Diag.Code.E0818, why.code);
}

test "§7.9/§9.22.6 segregation: the connect module reads the ordinary drivers, an ordinary input reads the connect module's driver (receiver_value_set_by_connectmodule.va)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const lowered = try lowerSource(a, prelude ++
        \\connectmodule c2e(d, a);
        \\  input d; output a; ddiscrete d; electrical a;
        \\  reg out; assign d = out;
        \\  initial begin out = 1'b1; #1 $display("d=%b", d); end
        \\  analog V(a) <+ 0.0;
        \\endmodule
        \\module drv(o); output o; ddiscrete o; reg o; initial o = 1'b0; endmodule
        \\module ear(i); input i; ddiscrete i; initial #2 $display("i=%b", i); endmodule
        \\module top; electrical n; drv hi(.o(n)); ear e1(.i(n)); endmodule
        \\connectrules r; connect c2e merged inout ddiscrete, inout electrical; endconnectrules
        \\
    , true);
    // §9.22.6: `d` "will be used to read the driver values" (hi's 0) and the
    // connect module's `assign d = out` "will drive the receivers" (1).
    // One shared net would resolve 0 against 1 to x for both.
    try std.testing.expectEqualStrings("d=0\ni=1\n", try transcript(a, &lowered.program));
}

test "§9.22.3/§9.22.4/§9.23 a driver's state, strength, type, pending state and delay (driver_delay_and_next_state.va)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const lowered = try lowerSource(a, prelude ++
        \\connectmodule c2e(d, a);
        \\  input d; output a; ddiscrete d; electrical a;
        \\  reg out; assign d = out;
        \\  initial begin
        \\    out = 1'b0;
        \\    #25 $display("%b %0.1f %b %0d %0d", $driver_state(d, 0), $driver_delay(d, 0), $driver_next_state(d, 0), $driver_strength(d, 0), $driver_type(d, 0));
        \\    #10 $display("%b %0.1f %b", $driver_state(d, 0), $driver_delay(d, 0), $driver_next_state(d, 0));
        \\    #10 $display("%b %0.1f %b", $driver_state(d, 0), $driver_delay(d, 0), $driver_next_state(d, 0));
        \\    #11 $display("%b %0.1f %b %b", $driver_state(d, 0), $driver_delay(d, 0), $driver_next_state(d, 0), $driver_state(d, 1));
        \\  end
        \\  analog V(a) <+ 0.0;
        \\endmodule
        \\module drv(o); output o; ddiscrete o; reg o; initial begin o = 1'b0; #30 o <= #20 1'b1; end endmodule
        \\module top; electrical n; drv dr(.o(n)); endmodule
        \\connectrules r; connect c2e merged input ddiscrete, output electrical; endconnectrules
        \\
    , true);
    // `dr.o <= #20 1'b1` at 30 lands at 50: pending from 30, 15 then 5 ns
    // away at 35 and 45, active at 56. §9.22.4 a strong 0: 6 << 3 | 6; Annex
    // D.3 a port window: DRIVER_ASSIGN's 16. Index 1 names no driver: x.
    try std.testing.expectEqualStrings(
        \\0 -1.0 0 54 16
        \\0 15.0 1
        \\0 5.0 1
        \\1 -1.0 1 x
        \\
    , try transcript(a, &lowered.program));
}

test "§9.22.5 driver_update fires on every assignment of a port's reg, a change or not, and not for the connect module's own driver (driver_update_without_resolved_change.va)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const lowered = try lowerSource(a, prelude ++
        \\connectmodule c2e(d, a);
        \\  input d; output a; ddiscrete d; electrical a;
        \\  reg out; integer updates;
        \\  assign d = out;
        \\  always @(driver_update d) updates = updates + 1;
        \\  initial begin
        \\    updates = 0; out = 1'b0;
        \\    #15 $display("%0d", updates);
        \\    #20 $display("%0d", updates);
        \\    #20 out = 1'b1;
        \\    #1 $display("%0d", updates);
        \\    #10 $display("%0d", updates);
        \\  end
        \\  analog V(a) <+ 0.0;
        \\endmodule
        \\module drv(o); output o; ddiscrete o; reg o;
        \\  initial begin #10 o = 1'b1; #20 o = 1'b1; #30 o <= #5 1'b0; end
        \\endmodule
        \\module top; electrical n; drv dr(.o(n)); endmodule
        \\connectrules r; connect c2e merged input ddiscrete, output electrical; endconnectrules
        \\
    , true);
    // t=10 `o = 1`: 1. t=30 `o = 1` again, no change: 2 (§9.22.5 "whether
    // or not there is a change"). t=55 the connect module's own `out = 1`:
    // still 2 (§9.22 ¶3, its driver is no ordinary one). t=60 `o <= #5 0`
    // is queued: 3, and landing at 65 is no second update: still 3.
    try std.testing.expectEqualStrings("1\n2\n2\n3\n", try transcript(a, &lowered.program));
}

test "§12.3.2/§12.3.3 the root's ports for a device host: list-of-ports order, direction, slot, type, range and kind; top_at at `module`" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    // No directive: the preprocessed text is the source, offset for offset.
    const src =
        \\module top(a, b, c, n);
        \\  input [3:0] a; output b; reg b; inout c; output n; integer n;
        \\endmodule
        \\
    ;
    const lowered = try lowerSource(arena_state.allocator(), src, false);
    const p = lowered.ports;
    try std.testing.expectEqual(@as(usize, 4), p.len);
    // `a`: an input vector [3:0]; `b`: a scalar output reg; `c`: a scalar
    // inout net; `n`: an `integer` output, 32 bits signed, [31:0].
    try std.testing.expectEqualStrings("a", p[0].name);
    try std.testing.expect(p[0].dir == .input and p[0].msb == 3 and p[0].lsb == 0 and !p[0].scalar and !p[0].integer);
    try std.testing.expectEqual(Program.Ty.int(4, false), p[0].ty);
    try std.testing.expectEqualStrings("b", p[1].name);
    try std.testing.expect(p[1].dir == .output and p[1].scalar and !p[1].integer);
    try std.testing.expectEqualStrings("c", p[2].name);
    try std.testing.expect(p[2].dir == .inout and p[2].scalar);
    try std.testing.expectEqualStrings("n", p[3].name);
    try std.testing.expect(p[3].dir == .output and p[3].integer and !p[3].scalar and p[3].msb == 31 and p[3].lsb == 0);
    try std.testing.expectEqual(Program.Ty.int(32, true), p[3].ty);
    for (p, 0..) |x, k| for (p[0..k]) |y| try std.testing.expect(x.slot != y.slot);
    try std.testing.expectEqualStrings("module top", src[lowered.top_at..][0.."module top".len]);
}

test "§12.2 the backends' tables: one spec per (module, parameters), each scope's spec, each slot's declared name and offset, each process's offset" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const src =
        \\module top; wire w; reg r;
        \\  sub #(.P(1)) a(.x(w)); sub #(.P(1)) b(.x(w)); sub #(.P(2)) c(.x(w));
        \\  initial r = 0; assign w = r;
        \\endmodule
        \\module sub(x); parameter P = 0; input x; reg [P:0] q; always @(x) q = x; endmodule
        \\
    ;
    const lowered = try lowerSource(arena_state.allocator(), src, false);
    const p = &lowered.program;
    // Three specs, by hand: top; sub with P = 1 (a and b share it); sub with P = 2.
    const s = lowered.specs;
    try std.testing.expectEqual(@as(usize, 3), s.len);
    try std.testing.expectEqualStrings("top", s[0].module);
    try std.testing.expectEqual(@as(usize, 0), s[0].ports.len);
    for (s[1..]) |x| {
        try std.testing.expectEqualStrings("sub", x.module);
        try std.testing.expectEqual(@as(usize, 1), x.ports.len);
        try std.testing.expectEqualStrings("x", x.ports[0].name);
        try std.testing.expect(x.ports[0].dir == .input);
    }
    try std.testing.expect(s[1].key.params != s[2].key.params);
    try std.testing.expectEqual(p.scopes.len, lowered.scope_spec.len);
    const want = [_]struct { []const u8, u32 }{ .{ "top", 0 }, .{ "a", 1 }, .{ "b", 1 }, .{ "c", 2 } };
    for (want) |w| {
        var found = false;
        for (p.scopes, lowered.scope_spec) |sc, spec| if (std.mem.eql(u8, p.str(sc.name), w[0])) {
            try std.testing.expectEqual(w[1], spec);
            found = true;
        };
        try std.testing.expect(found);
    }
    // Every declared slot carries its name and its declaration's offset:
    // `r` once, `q` once per instance.
    try std.testing.expectEqual(p.slots.len, lowered.slot_names.len);
    var qs: u32 = 0;
    var rs: u32 = 0;
    for (lowered.slot_names, lowered.slot_at) |nm, at| {
        if (std.mem.eql(u8, nm, "q")) qs += 1;
        if (std.mem.eql(u8, nm, "r")) rs += 1;
        if (nm.len != 0 and at != digital.none) try std.testing.expectEqualStrings(nm, src[at..][0..nm.len]);
    }
    try std.testing.expectEqual(@as(u32, 3), qs);
    try std.testing.expectEqual(@as(u32, 1), rs);
    // Processes: one `initial`, three `always` (one per instance), one
    // continuous driver, at its value `r`.
    var initials: u32 = 0;
    var always: u32 = 0;
    var drivers: u32 = 0;
    for (lowered.proc_sites) |ps| {
        try std.testing.expect(ps.pc < p.insts.len);
        if (std.mem.startsWith(u8, src[ps.at..], "initial")) initials += 1;
        if (std.mem.startsWith(u8, src[ps.at..], "always")) always += 1;
        if (std.mem.startsWith(u8, src[ps.at..], "r;")) drivers += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), initials);
    try std.testing.expectEqual(@as(u32, 3), always);
    try std.testing.expectEqual(@as(u32, 1), drivers);
}
