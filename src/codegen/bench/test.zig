//! `bench`'s public API: the runners it writes.
//! Cites: docs/rewrite/exe.md (a runner's imports).
//!
//! Contents: tests only.

const std = @import("std");
const bench = @import("../bench.zig");

/// Every module a runner may import: Zig's own, itself, and what
/// docs/rewrite/exe.md allows; no `frontend`, `base`, `diag`, old
/// `kernels` or old `sim`.
const allowed = [_][]const u8{ "std", "root", "contract", "std_kernels", "std_sim", "device" };

test "a runner imports only contract, std_kernels, std_sim and the device" {
    // Oracle: the rule of docs/rewrite/exe.md, read off the rendered text.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sources = [_][]const u8{
        "//! bias V(p) = 1\n",
        "//! param r = 2\n//! sweep V(p) = 1, 2\n//! time 0, 1n, 2n\n//! noise none\n//! acstim none\n//! limit V(p) = 0 -> V(p) = 0.1\n",
        "//! psweep r = 1, 2\n//! seed none\n//! meta none\n//! qsite none\n//! abstol V(p) = 1e-6\n",
    };
    for (sources) |src| {
        const s = try bench.Spec.parse(arena, src, null);
        var aw: std.Io.Writer.Allocating = .init(arena);
        try bench.writeRunner(&aw.writer, arena, "t", &s.bench, .{});
        var it = std.mem.splitSequence(u8, aw.written(), "@import(\"");
        _ = it.next();
        var n: u32 = 0;
        while (it.next()) |rest| : (n += 1) {
            const name = rest[0 .. std.mem.findScalar(u8, rest, '"') orelse rest.len];
            const ok = for (allowed) |a| {
                if (std.mem.eql(u8, a, name)) break true;
            } else false;
            if (!ok) std.debug.print("a runner imports `{s}`\n", .{name});
            try std.testing.expect(ok);
        }
        // `std`, `device` and `contract` at least.
        try std.testing.expect(n >= 3);
    }
}
