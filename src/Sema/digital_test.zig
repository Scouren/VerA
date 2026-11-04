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

/// The discipline the mixed examples' continuous nets take.
const prelude =
    \\`timescale 1ns/1ns
    \\nature Voltage; access = V; units = "V"; abstol = 1e-6; endnature
    \\nature Current; access = I; units = "A"; abstol = 1e-12; endnature
    \\discipline electrical; potential Voltage; flow Current; enddiscipline
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
