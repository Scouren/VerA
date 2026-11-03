//! The new pipeline's device for one fixture (`sides.new`, strict), written
//! to a file the build compiles a `tests/host/*_host.zig` against: argv is
//! the fixture, its include directory and the output path. diff-codegen's
//! host phase runs the contract's behavioural hosts on the new devices.
//! No LRM clause: each host cites its own.
//!
//! Contents: `main` only.

const std = @import("std");
const sides = @import("sides.zig");

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) return error.Usage;
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], arena, .limited(1 << 26));
    const dirs = [_][]const u8{ std.fs.path.dirname(args[1]).?, args[2] };
    switch (try sides.new(init.gpa, arena, init.io, args[1], source, &dirs, true)) {
        .refused => return error.NewSideRefused,
        .fail => |why| {
            std.debug.print("codegen: {s}\n", .{why});
            return error.CodegenFailed;
        },
        .ok => |n| try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[3], .data = n.text }),
    }
}
