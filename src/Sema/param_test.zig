//! The comptime evaluator's §4.2/§4.3/§9.14 constant-fold spec examples
//! (T10: unsigned compares, 64-bit and wider literals, reductions, `>>>`,
//! `$clog2`): a module's text in, its `Air.Device.params` folded defaults
//! by name out. Each expected value is derived by hand from the clause it
//! cites; the oracle over the corpus is `tests/differential/lower.zig`.
//!
//! Contents: tests only.

const std = @import("std");
const vams = @import("vams");
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

// ---- private ----

/// Parameter `name`'s folded default in `body`, through the whole pipeline
/// (`Ast.parse`, `AstGen.generate`, `Zcu.elaborate`, `Sema.analyze`): an
/// integer or a real, read back as `f64`. Fails the test if `body` raises a
/// code or declares no parameter of that name.
fn paramDefault(comptime body: []const u8, name: []const u8) !f64 {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = prelude ++ body;
    var ast = try vams.Ast.parse(gpa, src, .{});
    defer ast.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    var vir = try vams.AstGen.generate(gpa, &ast, .{});
    defer vir.deinit(gpa);
    var zcu: Zcu = try .init(gpa);
    defer zcu.deinit();
    _ = try zcu.addFile("test.va", vir, 0);
    try Sema.elaborate(&zcu, .{ .roots = .first });
    var analysis = try Sema.analyze(&zcu);
    defer if (analysis) |*a| a.deinit(gpa);
    try std.testing.expectEqualSlices(Diag.Code, &.{}, zcu.failed.items(.code));
    const a = &(analysis orelse return error.TestUnexpectedResult);
    const ip = &zcu.intern_pool;
    const d = &a.device;
    for (d.params.items(.name), d.params.items(.default)) |n, v| {
        if (!std.mem.eql(u8, ip.stringToSlice(n), name)) continue;
        return switch (ip.indexToKey(v)) {
            .int => |x| switch (x.storage) {
                .small => |s| @floatFromInt(s),
                .big => error.TestUnexpectedResult, // else: no fixture here needs a wide row
            },
            .float => |f| f,
            else => error.TestUnexpectedResult, // else: `.undef`/`.aggregate`: declined to fold
        };
    }
    return error.TestUnexpectedResult; // else: no parameter row of that name
}

/// Every `(name, want)` row of one module checks against `paramDefault`.
fn expectDefaults(comptime body: []const u8, want: []const struct { []const u8, f64 }) !void {
    for (want) |w| try std.testing.expectEqual(w[1], try paramDefault(body, w[0]));
}

test "§4.2.9 (I1) a based literal without `s` makes the comparison unsigned, over the signed carrier" {
    // -1 >> 0 is the carrier -1; 32'h1 is unsigned, so §4.2.9 compares
    // 1 against the unsigned 4294967295: true.
    try expectDefaults(
        \\module m(p); inout p; electrical p;
        \\  localparam integer mixed = 32'h1 < (-1 >> 0);
        \\  analog I(p) <+ mixed * V(p);
        \\endmodule
    , &.{.{ "mixed", 1 }});
}

test "(I2) a 64-bit literal at or past 2^63 keeps its bit pattern instead of declining" {
    // Untyped (not `integer`): §3.2's 32-bit wrap must not fold these two
    // in, or it would hide the bug under test.
    try expectDefaults(
        \\module m(p); inout p; electrical p;
        \\  localparam allones = 64'hFFFFFFFFFFFFFFFF;
        \\  localparam high = 64'h8000000000000000;
        \\  analog I(p) <+ (allones + high) * V(p);
        \\endmodule
    , &.{ .{ "allones", -1 }, .{ "high", std.math.minInt(i64) } });
}

test "§4.2.1.1/§3.4.1 (I3/I4) a real parameter default saturates at the 32-bit ceiling instead of declining" {
    // `integer_conversion_saturates.va`'s own case: 1e300 saturates to
    // 2147483647, never UB and never left unfolded.
    try expectDefaults(
        \\module m(p); inout p; electrical p;
        \\  parameter integer big = 1e300;
        \\  parameter integer low = -1e300;
        \\  analog I(p) <+ (big + low) * V(p);
        \\endmodule
    , &.{ .{ "big", 2147483647 }, .{ "low", std.math.minInt(i32) } });
}

test "§4.2.10 (I5) a reduction over a literal folds at its own width" {
    try expectDefaults(
        \\module m(p); inout p; electrical p;
        \\  localparam integer r = &8'hFF;
        \\  localparam integer x = ^4'hF;
        \\  analog I(p) <+ (r + x) * V(p);
        \\endmodule
    , &.{ .{ "r", 1 }, .{ "x", 0 } });
}

test "IEEE 1364-2005 §5.1.12 (I5) `>>>` fills from the sign bit only when the left operand is signed" {
    try expectDefaults(
        \\module m(p); inout p; electrical p;
        \\  localparam integer s = (-8'sd1) >>> 2;
        \\  localparam integer u = (8'd255) >>> 2;
        \\  analog I(p) <+ (s + u) * V(p);
        \\endmodule
    , &.{ .{ "s", -1 }, .{ "u", 63 } });
}

test "§2.6.1 (D1-F) a literal wider than 64 bits folds its low 64 bits instead of declining" {
    try expectDefaults(
        \\module m(p); inout p; electrical p;
        \\  localparam integer w = 128'shffffffffffffffffffffffffffffffff;
        \\  analog I(p) <+ w * V(p);
        \\endmodule
    , &.{.{ "w", -1 }});
}

test "IEEE 1364-2005 §5.4.1/§17.11.1 (D1-G) `$clog2`'s argument keeps its own self-determined width" {
    try expectDefaults(
        \\module m(p); inout p; electrical p;
        \\  localparam integer discard = $clog2(4'hf + 4'h1);
        \\  localparam integer sized = $clog2(4'shf);
        \\  localparam integer wide = $clog2(128'shffffffffffffffffffffffffffffffff);
        \\  analog I(p) <+ (discard + sized + wide) * V(p);
        \\endmodule
    , &.{ .{ "discard", 0 }, .{ "sized", 4 }, .{ "wide", 128 } });
}
