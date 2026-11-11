//! The codegen module's spec examples: a small module lowered by Sema, its
//! device written by the Zig backend, and the text checked: it passes
//! `std.zig.AstGen` (no unused local or parameter: what a build would
//! refuse first), and it has the shape the spec names (no kernel
//! text, the versioned unit's entry check). The behaviour oracle is
//! `tests/differential/codegen.zig`, which builds and runs the devices.
//!
//! Contents: tests only.

const std = @import("std");
const vams = @import("vams");
const Air = @import("air");
const sema = @import("sema");
const codegen = @import("../codegen.zig");

const prelude =
    \\nature Voltage; access = V; units = "V"; abstol = 1e-6; endnature
    \\nature Current; access = I; units = "A"; abstol = 1e-12; endnature
    \\discipline electrical; potential Voltage; flow Current; enddiscipline
    \\
;

// ---- private ----

/// The device text of `body`'s first module (strict), or the failure.
fn emit(gpa: std.mem.Allocator, comptime body: []const u8) !codegen.Result {
    return emitWith(gpa, body, true);
}

/// `emit`, with the units versioned by `Air.Float`'s verdict over
/// `codegen.floatRoots` when `strict` is false.
fn emitWith(gpa: std.mem.Allocator, comptime body: []const u8, strict: bool) !codegen.Result {
    const src: [:0]const u8 = prelude ++ body;
    var ast = try vams.Ast.parse(gpa, src, .{});
    defer ast.deinit(gpa);
    var vir = try vams.AstGen.generate(gpa, &ast, .{});
    defer vir.deinit(gpa);
    var zcu: sema.Zcu = try .init(gpa);
    defer zcu.deinit();
    _ = try zcu.addFile("t.va", vir, 0);
    try sema.Sema.elaborate(&zcu, .{ .roots = .first });
    var a = (try sema.Sema.analyze(&zcu)).?;
    defer a.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const roots = try codegen.floatRoots(arena.allocator(), &a.air, &a.device);
    const params = try arena.allocator().alloc(Air.Float.Param, a.device.params.len);
    for (params, 0..) |*p, k| {
        var rs: std.ArrayList(Air.Interval.Range) = .empty;
        for (a.device.paramRanges(@fromBackingInt(@intCast(k)))) |r| try rs.append(arena.allocator(), .{ .kind = if (r.exclude) .exclude else .from, .lo = r.lo, .hi = r.hi, .lo_inclusive = r.lo_closed, .hi_inclusive = r.hi_closed });
        p.* = .{ .ranges = rs.items };
    }
    var wip: vams.Diag.Wip = .init(gpa);
    defer wip.deinit();
    var f = try Air.Float.analyze(gpa, a.air, &zcu.intern_pool, .{ .params = params, .roots = roots }, &wip);
    defer f.deinit(gpa);
    return codegen.generate(gpa, .zig, .{ .air = &a.air, .ip = &zcu.intern_pool, .device = &a.device, .verdict = &f.verdict }, .{ .strict = strict });
}

/// Fails unless `text` parses as a Zig file and passes `std.zig.AstGen`:
/// the per-file checks a build makes first (an unused local or parameter,
/// a discarded value, a shadowed name), without building the device.
fn expectAstGen(gpa: std.mem.Allocator, text: []const u8) !void {
    const z = try gpa.dupeSentinel(u8, text, 0);
    defer gpa.free(z);
    var tree = try std.zig.Ast.parse(gpa, z, .{});
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) {
        std.debug.print("{s}\n", .{text});
        return error.DeviceDoesNotParse;
    }
    var zir = try std.zig.AstGen.generate(gpa, tree);
    defer zir.deinit(gpa);
    if (!zir.hasCompileErrors()) return;
    var wip: std.zig.ErrorBundle.Wip = try .init(gpa);
    defer wip.deinit();
    try wip.addZirErrorMessages(zir, tree, z, "device.zig");
    var eb = try wip.toOwnedBundle("");
    defer eb.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try eb.renderToWriter(.{}, &out.writer);
    std.debug.print("{s}\n{s}", .{ text, out.written() });
    return error.DeviceFailsAstGen;
}

test "a diode and its junction charge: the device parses and imports its kernels" {
    const gpa = std.testing.allocator;
    var r = try emit(gpa,
        \\module d(a, c);
        \\  inout a, c;
        \\  electrical a, c;
        \\  parameter real is = 1e-15 from (0:inf);
        \\  parameter real cj = 1e-12 from [0:inf);
        \\  real vt;
        \\  analog begin
        \\    vt = $vt;
        \\    I(a, c) <+ is * (limexp(V(a, c) / vt) - 1.0);
        \\    I(a, c) <+ ddt(cj * V(a, c));
        \\    if (V(a,c) > 0) I(a,c) <+ V(a,c)*V(a,c); else I(a,c) <+ $temperature;
        \\  end
        \\endmodule
    );
    defer r.deinit(gpa);
    const text = r.ok.text;
    try expectAstGen(gpa, text);
    try std.testing.expect(std.mem.find(u8, text, "@import(\"std_kernels\")") != null);
    // No kernel text: no device-local transcendental.
    try std.testing.expect(std.mem.find(u8, text, "fn zLog10") == null);
}

test "a construct the backend does not spell yet fails with its name, never writes a device" {
    // §9.13 a draw moves the seed a later evaluation reads, so it is an
    // effect `core` must run; this backend has no rng state yet.
    const gpa = std.testing.allocator;
    var r = try emit(gpa,
        \\module d(a, c);
        \\  inout a, c;
        \\  electrical a, c;
        \\  integer seed;
        \\  analog begin
        \\    I(a, c) <+ V(a, c) * $random(seed);
        \\  end
        \\endmodule
    );
    defer r.deinit(gpa);
    try std.testing.expect(r == .fail);
    try std.testing.expect(std.mem.find(u8, r.fail, "$random") != null);
}

test "a print's operands are dead in the residual and live in `say`" {
    // §9.4 a `$strobe` runs in the display phase, so the value only it
    // reads is not emitted in `core` (Zig refuses an unused local), and
    // `say` records it (`say.zig`).
    const gpa = std.testing.allocator;
    var r = try emit(gpa,
        \\module d(a, c);
        \\  inout a, c;
        \\  electrical a, c;
        \\  analog begin
        \\    $strobe("%g", exp(V(a, c)));
        \\    I(a, c) <+ V(a, c);
        \\  end
        \\endmodule
    );
    defer r.deinit(gpa);
    try expectAstGen(gpa, r.ok.text);
    const at = std.mem.find(u8, r.ok.text, "pub fn say(").?;
    try std.testing.expect(std.mem.find(u8, r.ok.text[0..at], ".exp()") == null);
    try std.testing.expect(std.mem.find(u8, r.ok.text[at..], ".exp()") != null);
    try std.testing.expect(std.mem.find(u8, r.ok.text[at..], "out.put(0, &.{") != null);
    try std.testing.expect(std.mem.find(u8, r.ok.text, ".fmt = \"%g\\n\"") != null);
}

test "§4.5.8 an operator only a print reads still runs in the residual, its value discarded" {
    // `transition` keeps state between points, so `core` evaluates it even
    // though only `say` reads the value: AstGen refuses the local unless
    // it is discarded (red-checked: dropping `calls.zig`'s `_ = v` fails
    // here, as a device without it fails to build).
    const gpa = std.testing.allocator;
    var r = try emit(gpa,
        \\module d(a, c);
        \\  inout a, c;
        \\  electrical a, c;
        \\  analog begin
        \\    $strobe("%g", transition(V(a, c), 0, 1n));
        \\    I(a, c) <+ V(a, c);
        \\  end
        \\endmodule
    );
    defer r.deinit(gpa);
    try expectAstGen(gpa, r.ok.text);
}

test "§11.10 the bsource stack: no memset, a one-word reset, every read behind its written bit" {
    // The text half of the oracle; diff-codegen builds this device and holds
    // it to `Air.interp` (st[5] read before a write, st[20] and st[-1]
    // outside the array, all 0).
    const gpa = std.testing.allocator;
    var ip: @import("intern_pool") = try .init(gpa);
    defer ip.deinit(gpa);
    var e = try codegen.examples.stack(gpa, &ip);
    defer e.deinit(gpa);
    try std.testing.expectEqual(@as(?Air.Verify.Violation, null), try Air.Verify.verify(gpa, e.air, &ip));
    var r = try codegen.generate(gpa, .zig, .{ .air = &e.air, .ip = &ip, .device = &e.device }, .{ .strict = true });
    defer r.deinit(gpa);
    const text = r.ok.text;
    try expectAstGen(gpa, text);
    for ([_][]const u8{ "@memset", "@splat(" }) |zeroing| try std.testing.expect(std.mem.find(u8, text, zeroing) == null);
    try std.testing.expect(std.mem.find(u8, text, "[16]F.zOf(S, 0x3) = undefined") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "_m = 0;"));
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, text, "_m >> @intCast(k)) & 1 != 0"));
}

test "§11.9 a versioned unit: the box checked at entry, the fast body inside it, the strict one outside" {
    // exp(V(p,n)/r) with r from [1:1e6] is finite for |V| <= 10 (Float's
    // default unknown bound): Float rates the root `.optimized` under that
    // box and the body holds a transcendental, so the entry checks each probe and the parameter, one compare pair each,
    // `&`ed into one branch; the fast body runs on the family's `Fast` twin
    // and the strict one is out of line.
    const gpa = std.testing.allocator;
    const src =
        \\module r(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real r = 1k from [1:1e6];
        \\  analog I(p, n) <+ exp(V(p, n) / r);
        \\endmodule
    ;
    var r = try emitWith(gpa, src, false);
    defer r.deinit(gpa);
    const text = r.ok.text;
    try expectAstGen(gpa, text);
    for ([_][]const u8{
        "zIn(x[0], -1e1, false, 1e1, false, false)",
        "zIn(x[1], -1e1, false, 1e1, false, false)",
        "zIn(model.r, 1e0, false, 1e6, false, false)",
        ") != 0) return fast(S, x, xs, model, inst, sim);",
        "const f = @call(.always_inline, core, .{ S.Fast, .optimized, D.zProbe(S.Fast, x), model, inst, sim });",
        "return @call(.never_inline, core, .{ S, .strict, xs, model, inst, sim });",
    }) |want| {
        if (std.mem.find(u8, text, want) == null) {
            std.debug.print("missing `{s}` in\n{s}\n", .{ want, text });
            return error.TestExpectedText;
        }
    }
    // Forced strict: one body, no check.
    var s = try emitWith(gpa, src, true);
    defer s.deinit(gpa);
    try expectAstGen(gpa, s.ok.text);
    try std.testing.expect(std.mem.find(u8, s.ok.text, "zIn(") == null);
    try std.testing.expect(std.mem.find(u8, s.ok.text, ".optimized") == null);
}

test "§11.9 a polynomial body is not versioned: its entry check costs more than fast-math saves" {
    // The same box proves V(p,n)/r, but the body holds no transcendental
    // (`bench-fast`: a square law and abs ran slower versioned).
    const gpa = std.testing.allocator;
    const src =
        \\module r(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real r = 1k from [1:1e6];
        \\  analog I(p, n) <+ V(p, n) / r;
        \\endmodule
    ;
    var r = try emitWith(gpa, src, false);
    defer r.deinit(gpa);
    try expectAstGen(gpa, r.ok.text);
    try std.testing.expect(std.mem.find(u8, r.ok.text, "zIn(") == null);
    try std.testing.expect(std.mem.find(u8, r.ok.text, ".optimized") == null);
}

test "T5 regression (dependent_control_rg.va): a derived default's shared parameter read is visible to every branch that reads it" {
    // `ok`'s `||` chain reads `r` from two different alternatives. Sema's
    // lowering hands back the same `arg` Air instruction (one per row,
    // `s.param_args`) every time a parameter is read, so `Function.zig`'s
    // `genTree` meets it twice, from two different `cond_br` branches. A
    // naive "render where first met" walk declares its `const` inside one
    // branch's `{}`, leaving the other an undeclared identifier (`v0` in
    // the real fixture); `expectAstGen` is the same check a real build
    // makes first, and catches it here too.
    const gpa = std.testing.allocator;
    var r = try emit(gpa,
        \\module d(a, c);
        \\  inout a, c;
        \\  electrical a, c;
        \\  parameter real r = 0;
        \\  parameter real g = 0;
        \\  localparam integer ok = ((r > 0) && (g == 0)) || ((r > 0) && (g > 0));
        \\  analog I(a, c) <+ ok * V(a, c);
        \\endmodule
    );
    defer r.deinit(gpa);
    try expectAstGen(gpa, r.ok.text);
}
