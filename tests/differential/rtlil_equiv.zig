//! `zig build rtlil-equiv`: diff-rtlil's tiebreaker held to its own
//! canary, and VerA's own `--emit-rtlil` inputs (`tests/rtlil/*.v`)
//! through it. Oracle: Yosys (`comp/yosys.zig`) proves `vera-next`'s RTLIL
//! of each input equivalent to `vera`'s; and the same check refuses a
//! planted fault (the old text of `counter.v` with its `&q` turned into
//! `|q`), so a check that passes everything fails here. Yosys is required:
//! without it the step fails.
//! Clauses: none (an equivalence of two netlists).
//!
//! Contents: tests only.

const std = @import("std");
const Io = std.Io;
const options = @import("comp_options");
const yosys = @import("comp/yosys.zig");

// ---- private ----

/// One driver's `--emit-rtlil` of `src`; fails unless it exits 0.
fn emit(arena: std.mem.Allocator, io: Io, exe: []const u8, src: []const u8) ![]const u8 {
    const r = try std.process.run(arena, io, .{ .argv = &.{ exe, "--emit-rtlil", src } });
    switch (r.term) {
        .exited => |c| if (c == 0) return r.stdout,
        else => {}, // else: a signal is a failure too
    }
    std.debug.print("{s} --emit-rtlil {s} failed:\n{s}\n", .{ exe, src, r.stderr });
    return error.EmitFailed;
}

test "rtlil-equiv: vera-next's RTLIL of tests/rtlil is Yosys-equivalent to vera's, and a planted fault is not" {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    const work = try std.fs.path.join(a, &.{ options.repo_root, "zig-out", "rtlil-equiv" });
    const old_exe = try Io.Dir.cwd().realPathFileAlloc(io, options.vera, a);
    const new_exe = try Io.Dir.cwd().realPathFileAlloc(io, options.vera_next, a);
    var failed: u32 = 0;
    for ([_][]const u8{ "counter", "fold_1364", "null_ports" }) |stem| {
        const src = try std.fmt.allocPrint(a, "{s}/tests/rtlil/{s}.v", .{ options.repo_root, stem });
        const old = try emit(a, io, old_exe, src);
        const new = try emit(a, io, new_exe, src);
        if (try yosys.equivalent(a, io, options.yosys, work, old, new)) |why| {
            std.debug.print("tests/rtlil/{s}.v: not equivalent:\n{s}\n", .{ stem, why });
            failed += 1;
        }
        if (std.mem.eql(u8, stem, "counter")) {
            // The canary: `tc = &q` as `|q` is another circuit.
            const fault = try std.mem.replaceOwned(u8, a, old, "cell $reduce_and $vera$c2", "cell $reduce_or $vera$c2");
            try std.testing.expect(!std.mem.eql(u8, fault, old));
            try std.testing.expect(try yosys.equivalent(a, io, options.yosys, work, old, fault) != null);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), failed);
}
