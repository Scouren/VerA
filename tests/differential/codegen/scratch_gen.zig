//! diff-codegen's scratch-array device: `codegen.examples.stack` (ESPice's
//! bsource.va stack, lib/TODO.md §11.10) written by the Zig backend to the
//! path in argv[1], so the build compiles it into the oracle, which holds it
//! to `Air.interp` over the same body (`tests/differential/codegen.zig`).
//! Cites: VAMS-2023 §3.2.2.
//!
//! Contents: `main` only.

const std = @import("std");
const InternPool = @import("intern_pool");
const codegen = @import("codegen");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const args = try init.minimal.args.toSlice(arena_state.allocator());
    if (args.len != 2) return error.NoOutputPath;
    const out = args[1];
    var ip: InternPool = try .init(gpa);
    defer ip.deinit(gpa);
    var e = try codegen.examples.stack(gpa, &ip);
    defer e.deinit(gpa);
    var r = try codegen.generate(gpa, .zig, .{ .air = &e.air, .ip = &ip, .device = &e.device }, .{ .strict = true });
    defer r.deinit(gpa);
    switch (r) {
        .ok => |o| try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = o.text }),
        .fail => |why| {
            std.debug.print("codegen-scratch: {s}\n", .{why});
            return error.CodegenFailed;
        },
    }
}
