//! The analog lowering's spec examples (the old `src/analog` tests and
//! `Lower.Harness` cases, ported): a small module in; its `Air.Device`
//! tables, its codes, or its contribution values at chosen unknowns out.
//! Each expected table, code and value is derived by hand from the clause
//! it cites; the oracle over the corpus is `tests/differential/lower.zig`.
//!
//! Contents: tests only.

const std = @import("std");
const vams = @import("vams");
const Air = @import("air");
const Zcu = @import("../Zcu.zig");
const Sema = @import("../Sema.zig");
const Diag = vams.Diag;

/// The natures and discipline every example declares (annex D's electrical).
const prelude =
    \\nature Voltage; access = V; units = "V"; abstol = 1e-6; endnature
    \\nature Current; access = I; units = "A"; abstol = 1e-12; endnature
    \\discipline electrical; potential Voltage; flow Current; enddiscipline
    \\
;

/// One lowering: its tables as text, its codes, and its body to run.
const Out = struct {
    arena: std.heap.ArenaAllocator,
    tables: []const u8,
    codes: []const Diag.Code,
    analysis: ?Sema.Analysis,
    zcu: *Zcu,
    vir: *vams.Vir,

    fn deinit(o: *Out) void {
        const gpa = std.testing.allocator;
        if (o.analysis) |*a| a.deinit(gpa);
        o.zcu.deinit();
        gpa.destroy(o.zcu);
        o.vir.deinit(gpa);
        gpa.destroy(o.vir);
        o.arena.deinit();
    }

    /// Contribution `k`'s resistive (`half` 0) or reactive (1) sum with the
    /// unknowns at `probes` and the parameters at their defaults.
    fn value(o: *Out, k: usize, half: u1, probes: []const f64) !f64 {
        const a = &o.analysis.?;
        const gpa = std.testing.allocator;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const args = try arena.allocator().alloc(Air.interp.Value, a.device.params.len);
        for (args, a.device.params.items(.default)) |*x, d| x.* = switch (o.zcu.intern_pool.indexToKey(d)) {
            .float => |f| .{ .real = f },
            .int => |i| .{ .int = i.storage.small },
            else => unreachable, // the examples' defaults fold
        };
        const finals = try arena.allocator().alloc(?Air.interp.Value, a.air.instructions.len);
        @memset(finals, null);
        var obs: Watch = .{ .finals = finals, .air = &a.air };
        _ = try Air.interp.run(arena.allocator(), a.air, &o.zcu.intern_pool, .{
            .args = args,
            .probes = probes,
            .loop_cap = 1000,
            .observe = .{ .ctx = &obs, .seen = Watch.seen },
            .calls = .{ .ctx = &obs, .value = Watch.call },
        });
        const slot = if (half == 0) a.device.contributions.items(.resist)[k] else a.device.contributions.items(.react)[k];
        const v = finals[@backingInt(slot)] orelse return 0;
        return v.real;
    }
};

/// The last value each slot was assigned; every call is a 0 of its
/// `SysFn` type (a user call's is real).
const Watch = struct {
    finals: []?Air.interp.Value,
    air: *const Air,
    fn seen(ctx: *anyopaque, inst: Air.Inst.Index, v: Air.interp.Value) void {
        const w: *Watch = @ptrCast(@alignCast(ctx));
        const i = @backingInt(inst);
        if (w.air.instructions.items(.tag)[i] != .assign) return;
        w.finals[@backingInt(w.air.instructions.items(.data)[i].bin_op.lhs.toIndex().?)] = v;
    }
    fn call(_: *anyopaque, callee: u32, _: []const Air.interp.Value) Air.interp.Error!Air.interp.Value {
        if (callee > std.math.maxInt(@typeInfo(vams.SysFn.Tag).@"enum".tag_type)) return .{ .real = 0 };
        return switch (vams.SysFn.get(@fromBackingInt(@intCast(callee))).ty) {
            .int => .{ .int = 0 },
            .str => .{ .str = "" },
            .real, .none => .{ .real = 0 },
        };
    }
};

// ---- private ----

fn lower(comptime body: []const u8) !Out {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = prelude ++ body;
    var out: Out = .{ .arena = .init(gpa), .tables = "", .codes = &.{}, .analysis = null, .zcu = undefined, .vir = undefined };
    errdefer out.arena.deinit();
    const arena = out.arena.allocator();
    var ast = try vams.Ast.parse(gpa, src, .{});
    defer ast.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    out.vir = try gpa.create(vams.Vir);
    out.vir.* = try vams.AstGen.generate(gpa, &ast, .{});
    out.zcu = try gpa.create(Zcu);
    out.zcu.* = try .init(gpa);
    _ = try out.zcu.addFile("test.va", out.vir.*, 0);
    try Sema.elaborate(out.zcu, .{ .roots = .first });
    out.analysis = try Sema.analyze(out.zcu);
    out.codes = try arena.dupe(Diag.Code, out.zcu.failed.items(.code));
    const a = &(out.analysis orelse return out);
    const ip = &out.zcu.intern_pool;
    var text: std.Io.Writer.Allocating = .init(arena);
    const d = &a.device;
    for (d.nodes.items(.name), d.nodes.items(.kind)) |n, k| try text.writer.print("node {s} {t}\n", .{ ip.stringToSlice(n), k });
    for (d.params.items(.name)) |n| try text.writer.print("param {s}\n", .{ip.stringToSlice(n)});
    for (0..d.contributions.len) |k| {
        const c = d.contributions.get(k);
        try text.writer.print("contrib {t} {s} {s}\n", .{ c.access, nodeName(ip, d, c.hi), nodeName(ip, d, c.lo) });
    }
    for (d.charge_sites.items(.sign)) |sign| try text.writer.print("charge {d}\n", .{sign});
    for (d.held.items(.name)) |n| try text.writer.print("held {s}\n", .{ip.stringToSlice(n)});
    for (d.displays.items(.name)) |n| try text.writer.print("display {s}\n", .{ip.stringToSlice(n)});
    out.tables = text.written();
    return out;
}

fn nodeName(ip: *const @import("intern_pool"), d: *const Air.Device, n: Air.Device.Node.Index) []const u8 {
    return if (n == .ground) "gnd" else ip.stringToSlice(d.nodes.items(.name)[@backingInt(n)]);
}

fn expectTables(comptime body: []const u8, want: []const u8) !void {
    var o = try lower(body);
    defer o.deinit();
    try std.testing.expectEqualSlices(Diag.Code, &.{}, o.codes);
    try std.testing.expectEqualStrings(want, o.tables);
}

fn expectCode(comptime body: []const u8, want: Diag.Code) !void {
    var o = try lower(body);
    defer o.deinit();
    if (std.mem.findScalar(Diag.Code, o.codes, want) == null) {
        std.debug.print("want {t}, got {any}\n", .{ want, o.codes });
        return error.TestUnexpectedResult;
    }
}

/// How many instructions of `tag` the body holds.
fn countTag(o: *const Out, tag: Air.Inst.Tag) usize {
    var n: usize = 0;
    for (o.analysis.?.air.instructions.items(.tag)) |t| n += @intFromBool(t == tag);
    return n;
}

test "§6.5 the ports are the first rows, in header order, a vector msb first; then the nets" {
    try expectTables(
        \\module m(a, b);
        \\  inout a; inout [1:0] b;
        \\  electrical a; electrical [1:0] b;
        \\  electrical n;
        \\  analog I(a) <+ V(a);
        \\endmodule
    ,
        \\node a net
        \\node b[1] net
        \\node b[0] net
        \\node n net
        \\contrib flow a gnd
        \\
    );
}

test "§5.6.1.3 two `<+` to one branch are one row, their values summed" {
    var o = try lower(
        \\module m(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin I(p, n) <+ V(p, n); I(p, n) <+ 2 * V(p, n); end
        \\endmodule
    );
    defer o.deinit();
    try std.testing.expectEqualStrings("node p net\nnode n net\ncontrib flow p n\n", o.tables);
    // V(p, n) = 1 - 0.25 = 0.75; 0.75 + 2 * 0.75 = 2.25, exact in binary.
    try std.testing.expectEqual(@as(f64, 2.25), try o.value(0, 0, &.{ 1.0, 0.25 }));
}

test "§1.3.1.2 the reversed spelling of a branch is the same row, negated" {
    var o = try lower(
        \\module m(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog I(n, p) <+ 0.5 * V(p, n);
        \\endmodule
    );
    defer o.deinit();
    try std.testing.expectEqualStrings("node p net\nnode n net\ncontrib flow p n\n", o.tables);
    // I(n, p) = -I(p, n): the row (p, n) carries -(0.5 * (2 - 1)) = -0.5.
    try std.testing.expectEqual(@as(f64, -0.5), try o.value(0, 0, &.{ 2.0, 1.0 }));
}

test "§5.6.1.2 a linear ddt term is the reactive half, with its charge site" {
    var o = try lower(
        \\module m(p, n);
        \\  inout p, n; electrical p, n;
        \\  parameter real c = 2.0;
        \\  analog I(p, n) <+ V(p, n) / 4.0 + ddt(c * V(p, n));
        \\endmodule
    );
    defer o.deinit();
    try std.testing.expectEqualStrings("node p net\nnode n net\nparam c\ncontrib flow p n\ncharge 1\n", o.tables);
    // V(p, n) = 3: resistive 3 / 4 = 0.75, the charge c * V = 6.
    try std.testing.expectEqual(@as(f64, 0.75), try o.value(0, 0, &.{ 3.0, 0.0 }));
    try std.testing.expectEqual(@as(f64, 6.0), try o.value(0, 1, &.{ 3.0, 0.0 }));
}

test "§4.5.2 a ddt off the contribution spine is an unknown of its own, with its row" {
    try expectTables(
        \\module m(p);
        \\  inout p; electrical p;
        \\  real q;
        \\  analog begin q = ddt(V(p)); I(p) <+ q * q; end
        \\endmodule
    ,
        \\node p net
        \\node ddt$0 op_state
        \\contrib flow ddt$0 gnd
        \\contrib flow p gnd
        \\charge -1
        \\
    );
}

test "§5.10 a variable an event body writes is held; one written before read is not" {
    try expectTables(
        \\module m(p);
        \\  inout p; electrical p;
        \\  real x, y;
        \\  analog begin
        \\    @(initial_step) x = 1.0;
        \\    y = 2.0;
        \\    I(p) <+ x + y;
        \\  end
        \\endmodule
    ,
        \\node p net
        \\contrib flow p gnd
        \\held x
        \\
    );
}

test "§4.7 an analog function is inlined; its output argument is written back" {
    var o = try lower(
        \\module m(p);
        \\  inout p; electrical p;
        \\  real r;
        \\  analog function real sq;
        \\    input x; output y; real x, y;
        \\    begin y = x + 1.0; sq = x * x; end
        \\  endfunction
        \\  analog begin I(p) <+ sq(V(p), r) + r; end
        \\endmodule
    );
    defer o.deinit();
    try std.testing.expectEqualSlices(Diag.Code, &.{}, o.codes);
    // V(p) = 3: sq = 9 and r = 4, so 13.
    try std.testing.expectEqual(@as(f64, 13.0), try o.value(0, 0, &.{3.0}));
}

test "A.6.2 a constant `initial` assignment is the variable's start value" {
    var o = try lower(
        \\module m(p);
        \\  inout p; electrical p;
        \\  integer level;
        \\  initial level = 10;
        \\  analog I(p) <+ level * V(p);
        \\endmodule
    );
    defer o.deinit();
    try std.testing.expectEqualSlices(Diag.Code, &.{}, o.codes);
    // The block runs once before the analysis: level is 10 throughout.
    try std.testing.expectEqual(@as(f64, 20.0), try o.value(0, 0, &.{2.0}));
}

test "§4.7.1 an analog function with no type returns real" {
    var o = try lower(
        \\module m(p);
        \\  inout p; electrical p;
        \\  analog function halve;
        \\    input x; real x;
        \\    halve = 0.5 * x;
        \\  endfunction
        \\  analog I(p) <+ halve(V(p));
        \\endmodule
    );
    defer o.deinit();
    try std.testing.expectEqualSlices(Diag.Code, &.{}, o.codes);
    // "if unspecified, the default is real": 0.5 * 3 = 1.5, not rounded to 2.
    try std.testing.expectEqual(@as(f64, 1.5), try o.value(0, 0, &.{3.0}));
}

test "§6.6 a loop generate scheme unrolls its analog block once per genvar value" {
    var o = try lower(
        \\module m(p);
        \\  inout p; electrical p;
        \\  genvar k;
        \\  generate for (k = 0; k < 3; k = k + 1) analog I(p) <+ k * V(p); endgenerate
        \\endmodule
    );
    defer o.deinit();
    // 0 * V + 1 * V + 2 * V at V(p) = 0.5 is 1.5.
    try std.testing.expectEqual(@as(f64, 1.5), try o.value(0, 0, &.{0.5}));
}

test "§3.2.2 an array element at a run-time index reads and writes its slot" {
    var o = try lower(
        \\module m(p);
        \\  inout p; electrical p;
        \\  real a[0:2];
        \\  integer i;
        \\  analog begin
        \\    a[0] = 1.0; a[1] = 10.0; a[2] = 100.0;
        \\    i = V(p);
        \\    a[i] = a[i] + 0.5;
        \\    I(p) <+ a[0] + a[1] + a[2];
        \\  end
        \\endmodule
    );
    defer o.deinit();
    // V(p) = 1 rounds to i = 1: a = {1, 10.5, 100}, sum 111.5.
    try std.testing.expectEqual(@as(f64, 111.5), try o.value(0, 0, &.{1.0}));
}

test "§5.8.1/§5.10/§5.9/§4.7 a contribution may not stand in an event, a loop or a function" {
    try expectCode(
        \\module m(p); inout p; electrical p;
        \\  analog @(initial_step) I(p) <+ V(p);
        \\endmodule
    , .E0406);
    try expectCode(
        \\module m(p); inout p; electrical p; integer k;
        \\  analog for (k = 0; k < 2; k = k + 1) I(p) <+ V(p);
        \\endmodule
    , .E0426);
}

test "§5.8.1 an analog operator under a condition that moves is E0514; a static one is not" {
    try expectCode(
        \\module m(p); inout p; electrical p;
        \\  analog if (V(p) > 0) I(p) <+ ddt(V(p));
        \\endmodule
    , .E0514);
    var o = try lower(
        \\module m(p); inout p; electrical p; parameter real g = 1.0;
        \\  analog if (g > 0) I(p) <+ ddt(V(p));
        \\endmodule
    );
    defer o.deinit();
    try std.testing.expectEqualSlices(Diag.Code, &.{}, o.codes);
}

test "§7.2.2/§6.6 a digital process a generate scheme brings in is judged; one it leaves out is not" {
    // §4.5.15 an analog operator "can not be used inside an initial or
    // always block": the old checker saw the flattened design, every
    // active generate scope's process included (E0422).
    try expectCode(
        \\module m(p); inout p; electrical p; real x;
        \\  generate if (1) begin : g
        \\    always x = ddt(V(p));
        \\  end endgenerate
        \\  analog I(p) <+ V(p);
        \\endmodule
    , .E0422);
    var o = try lower(
        \\module m(p); inout p; electrical p; real x;
        \\  generate if (0) begin : g
        \\    always x = ddt(V(p));
        \\  end endgenerate
        \\  analog I(p) <+ V(p);
        \\endmodule
    );
    defer o.deinit();
    try std.testing.expectEqualSlices(Diag.Code, &.{}, o.codes);
}

test "§4.4 a net is no value (E0315); §9.2 a digital-only task is refused in analog (E0806)" {
    try expectCode(
        \\module m(p); inout p; electrical p; real x;
        \\  analog begin x = p; I(p) <+ x; end
        \\endmodule
    , .E0315);
    try expectCode(
        \\module m(p); inout p; electrical p;
        \\  analog begin $monitoron; I(p) <+ V(p); end
        \\endmodule
    , .E0806);
}

test "§3.4.2 a parameter outside its declared range is E0361" {
    try expectCode(
        \\module m(p); inout p; electrical p;
        \\  parameter real r = -1.0 from (0:inf);
        \\  analog I(p) <+ V(p) / r;
        \\endmodule
    , .E0361);
}

test "§9.4.1 an unconditional print is a row in source order, minted after the blocks" {
    try expectTables(
        \\module m(p); inout p; electrical p;
        \\  analog begin $strobe("a"); I(p) <+ V(p); $display("b"); end
        \\endmodule
    ,
        \\node p net
        \\contrib flow p gnd
        \\display $strobe
        \\display $display
        \\
    );
}

test "§3.2 a variable no evaluation writes reads its declaration initializer" {
    var o = try lower(
        \\module m(p); inout p; electrical p;
        \\  integer count = 3; real gain = 2.5;
        \\  analog I(p) <+ count * gain * V(p);
        \\endmodule
    );
    defer o.deinit();
    try std.testing.expectEqualSlices(Diag.Code, &.{}, o.codes);
    // 3 * 2.5 * 1.0, exact in binary.
    try std.testing.expectEqual(@as(f64, 7.5), try o.value(0, 0, &.{1.0}));
}

test "§3.4 a default over another parameter keeps its expression for the host (Param.derive)" {
    var o = try lower(
        \\module m(p); inout p; electrical p;
        \\  parameter real a = 2.0; parameter real b = a * 3.0;
        \\  analog I(p) <+ b * V(p);
        \\endmodule
    );
    defer o.deinit();
    const d = o.analysis.?.device.params.items(.derive);
    try std.testing.expectEqual(Air.Inst.Ref.none, d[0]);
    // b's derive is a * 3.0 over a's arg: an fmul, not the folded 6.0.
    const i = d[1].toIndex().?;
    try std.testing.expectEqual(Air.Inst.Tag.fmul, o.analysis.?.air.instructions.items(.tag)[@backingInt(i)]);
}

test "§2.9 vera_nodiff stops an assigned real's derivative; a nearer spec turns it back on" {
    var o = try lower(
        \\module m(p); inout p; electrical p; real a, b;
        \\  analog begin
        \\    (* vera_nodiff *) a = V(p) * V(p);
        \\    (* vera_nodiff *) begin (* vera_nodiff = 0 *) b = V(p); end
        \\    I(p) <+ a + b;
        \\  end
        \\endmodule
    );
    defer o.deinit();
    try std.testing.expectEqualSlices(Diag.Code, &.{}, o.codes);
    // `a` only: `b`'s nearer spec is off.
    try std.testing.expectEqual(@as(usize, 1), countTag(&o, .dstop));
}

test "§5.2.1 an analog initial body runs under the host's first-evaluation flag" {
    var o = try lower(
        \\module m(p); inout p; electrical p; real r;
        \\  analog initial r = 1.0;
        \\  analog I(p) <+ r * V(p);
        \\endmodule
    );
    defer o.deinit();
    try std.testing.expectEqualSlices(Diag.Code, &.{}, o.codes);
    // The body sits in a `cond_br` on `analog$initial`, so with the host
    // answering 0 (not the first evaluation) r keeps its zero start.
    try std.testing.expectEqual(@as(usize, 1), countTag(&o, .cond_br));
    try std.testing.expectEqual(@as(f64, 0), try o.value(0, 0, &.{1.0}));
}
