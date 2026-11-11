//! `derive.zig`'s public API through the whole pipeline (`Ast.parse`,
//! `AstGen.generate`, `Zcu.elaborate`, `Sema.analyze`): a design's text in,
//! a named card row's `derive` Air ref out — `.none` for a row that keeps
//! its plain folded value, set once `expression`/`array` could render it
//! (W11/W12/T38). The oracle over the corpus is
//! `tests/differential/codegen.zig`; `research/codegen.md`'s T5-W12 and
//! T38 name these two planted faults. The third test is `diff-lower`'s own
//! find, past T38's narrow oracle: a §3.6.3.2 hole (E0894 for a parameter,
//! annex_a_syntax/pattern_empty_element_rejected.va) panicked `array`'s
//! `elementBody`, which assumed every pattern element is a real instruction.
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

/// Whether card row `name` of the elaborated+lowered `body` holds a
/// `derive` expression. Fails the test if `body` raises a code or declares
/// no row of that name.
fn hasDerive(comptime body: []const u8, name: []const u8) !bool {
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
    for (d.params.items(.name), d.params.items(.derive)) |n, der| {
        if (!std.mem.eql(u8, ip.stringToSlice(n), name)) continue;
        return der != .none;
    }
    return error.TestUnexpectedResult; // else: no card row of that name
}

test "T5-W12: a defparam's target re-derives through the writer's own scope" {
    // §6.3.1/§6.3: the instance overrides u's gain to 2.0 inline, but the
    // defparam from the parent (which also declares `scale`) overrides it
    // to scale*2.0, which takes precedence; `defparam_unsupported.va`'s own
    // shape. `Zcu.defparams` eagerly folds the defparam's value, so before
    // W12 the row keeps no `derive` and a later host override of `scale`
    // could never reach `gain` again.
    try std.testing.expect(try hasDerive(
        \\module p;
        \\  electrical a, b;
        \\  parameter real scale = 2.5;
        \\  c #(.gain(2.0)) u(a, b);
        \\  defparam u.gain = scale * 2.0;
        \\endmodule
        \\module c(a, b);
        \\  inout a, b; electrical a, b;
        \\  parameter real gain = 1.0;
        \\  analog I(a, b) <+ gain * V(a, b);
        \\endmodule
    , "u.gain"));
}

test "T38: an array parameter's dependent element re-derives, same as a scalar's" {
    // §3.4.4/§6.3.4: `values[1]` (the element written first, msb) reads
    // `both`; `values[0]` (a literal) does not and stays folded.
    // `dependent_control_host.va`'s own shape: before T38 `declareArray`
    // never registers either element for `derive` at all.
    try std.testing.expect(try hasDerive(
        \\module m(p);
        \\  inout p; electrical p;
        \\  parameter integer both = 0;
        \\  parameter integer values[1:0] = '{both ? 29 : 31, 0};
        \\  analog I(p) <+ values[1] * V(p);
        \\endmodule
    , "values[1]"));
    try std.testing.expect(!try hasDerive(
        \\module m(p);
        \\  inout p; electrical p;
        \\  parameter integer both = 0;
        \\  parameter integer values[1:0] = '{both ? 29 : 31, 0};
        \\  analog I(p) <+ values[1] * V(p);
        \\endmodule
    , "values[0]"));
}

test "T38 regression: a §3.6.3.2 pattern hole in a parameter array does not crash array()" {
    // `pattern_empty_element_rejected.va`'s own shape: a hole has no value
    // for a parameter (A.8.1 derives none; only a bus nodeset reads one).
    // The old `src/analog` pipeline's shape.zig raises E0894 for this; the
    // new Sema pipeline under test here does not yet (a separate, pre-
    // existing gap — not this fix's concern). What matters here: AstGen
    // lowers the hole `.none`, and `array()` must leave that row at its
    // folded default rather than index through a missing instruction.
    try std.testing.expect(!try hasDerive(
        \\module m(p, n);
        \\  inout p, n; electrical p, n;
        \\  parameter real a[0:2] = '{1.0, , 3.0};
        \\  analog I(p, n) <+ a[1] * V(p, n);
        \\endmodule
    , "a[1]"));
}
