//! The codegen module's spec examples: a small module lowered by Sema, its
//! device written by the Zig backend, and the text checked: it parses as
//! Zig (`std.zig.Ast`), and it has the shape the spec names (no kernel
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
    return codegen.generate(gpa, .zig, .{ .air = &a.air, .ip = &zcu.intern_pool, .device = &a.device }, .{ .strict = true });
}

/// Fails unless `text` parses as a Zig file.
fn expectParses(gpa: std.mem.Allocator, text: []const u8) !void {
    const z = try gpa.dupeSentinel(u8, text, 0);
    defer gpa.free(z);
    var tree = try std.zig.Ast.parse(gpa, z, .{});
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) {
        std.debug.print("{s}\n", .{text});
        return error.DeviceDoesNotParse;
    }
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
    try expectParses(gpa, text);
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

test "a print's operands are dead in the residual: no unused local, no call" {
    // §9.4 a `$strobe` runs in the display phase, so the value only it
    // reads is not emitted (Zig refuses an unused local).
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
    try expectParses(gpa, r.ok.text);
    try std.testing.expect(std.mem.find(u8, r.ok.text, ".exp()") == null);
}
