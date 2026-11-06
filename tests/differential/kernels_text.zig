//! The old kernel text, compiled: `device.kernel_text`'s string literals in,
//! one Zig file out (the path in argv[1]) laid out as a device's `h.zig` is
//! (`prelude.buildPrelude`): the helpers head, then each text with its
//! top-level `fn`/`const` made public, so `diff-kernels` can call the bytes
//! the old codegen splices into every device and hold `std_kernels` to them.
//! The texts a device reads its own decls through get test stand-ins: `zdr`
//! (every lane read) and `n_u` (`ac_fam_txt`'s unknown count).
//! Cites: none (test tooling over `src/codegen/device/codegen/kernel_text`).
//!
//! Contents: none public; `main` only.

const std = @import("std");
const kt = @import("device").kernel_text;

/// The unknown count `ac_fam_txt`'s `zAc` is compiled at; `diff-kernels`
/// instantiates `std_kernels.ac.Ac` at the same.
const n_u = 3;

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);
    std.debug.assert(args.len == 2);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, kt.helpers_head_txt);
    try out.print(arena, "pub const zdr: u64 = ~@as(u64, 0);\npub const n_u = {d};\n\n", .{n_u});
    const texts = [_][]const u8{
        kt.math_txt,      kt.domain_quiet_txt, kt.ops_txt,    kt.family_txt, kt.ac_txt,
        kt.ac_fam_txt,    kt.tp_txt,           kt.tp_arr_txt, kt.arr_txt,    kt.hist_txt,
        kt.hist_quad_txt,
    };
    for (texts) |t| try publish(arena, &out, t);
    std.debug.assert(out.items.len > kt.helpers_head_txt.len);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = out.items });
}

// ---- private ----

/// `prelude.publish`: each top-level `fn`/`const` of `src` made public.
fn publish(arena: std.mem.Allocator, out: *std.ArrayList(u8), src: []const u8) !void {
    const before = out.items.len;
    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(arena, '\n');
        first = false;
        if (kt.declKeyword(line) != null) try out.appendSlice(arena, "pub ");
        try out.appendSlice(arena, line);
    }
    std.debug.assert(out.items.len - before >= src.len);
}
