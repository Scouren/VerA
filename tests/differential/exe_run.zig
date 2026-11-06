//! `.v --emit-exe`'s binary against vera-next's own `--run`, byte for
//! byte (docs/rewrite/digital.md step 1): the same design both ways, its
//! status, stdout and stderr equal. The design prints, dumps nothing,
//! violates a timing check (W1199 on stderr) and finishes, so the
//! transcript, the run's diagnostics and their source snippets are all
//! compared.
//! Cites: IEEE 1364-2005 §15.2, §15.5, §17.1.
//!
//! Contents: tests only.

const std = @import("std");
const Io = std.Io;
const options = @import("comp_options");

const design =
    \\`timescale 1ns/1ns
    \\module u(input d, input clk);
    \\  reg n;
    \\  specify
    \\    $setup(d, posedge clk, 5, n);
    \\  endspecify
    \\endmodule
    \\module top;
    \\  reg d, clk;
    \\  u x(d, clk);
    \\  initial begin
    \\    d = 0; clk = 0;
    \\    #10 d = 1;
    \\    #2 clk = 1;
    \\    $display("t=%0t d=%b clk=%b", $time, d, clk);
    \\    #1 $finish;
    \\  end
    \\endmodule
    \\
;

const Out = struct { status: u8, stdout: []const u8, stderr: []const u8 };

// ---- private ----

fn exec(arena: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !Out {
    const r = try std.process.run(arena, std.testing.io, .{ .argv = argv, .cwd = .{ .path = cwd } });
    return .{ .status = switch (r.term) {
        .exited => |c| c,
        else => 255,
    }, .stdout = r.stdout, .stderr = r.stderr };
}

test "the --emit-exe binary prints what --run prints, byte for byte" {
    // Oracle: vera-next --run of the same design (the interpreter the
    // binary embeds), whose transcript and W1199 the binary must repeat.
    const io = std.testing.io;
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "d.v", .data = design });
    const cwd = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const vn = try Io.Dir.cwd().realPathFileAlloc(io, options.vera_next, arena);
    const ran = try exec(arena, &.{ vn, "--run", "d.v" }, cwd);
    const built = try exec(arena, &.{ vn, "--emit-exe", "d.v" }, cwd);
    if (built.status != 0) std.debug.print("--emit-exe failed:\n{s}\n", .{built.stderr});
    try std.testing.expectEqual(@as(u8, 0), built.status);
    const bin = std.mem.trimEnd(u8, built.stdout, "\n");
    const got = try exec(arena, &.{try std.fs.path.join(arena, &.{ cwd, bin })}, cwd);
    // The design does what it says: one line, one violation.
    try std.testing.expect(std.mem.find(u8, ran.stdout, "t=12 d=1 clk=1") != null);
    try std.testing.expect(std.mem.find(u8, ran.stderr, "W1199") != null);
    try std.testing.expectEqual(ran.status, got.status);
    try std.testing.expectEqualStrings(ran.stdout, got.stdout);
    try std.testing.expectEqualStrings(ran.stderr, got.stderr);
}
