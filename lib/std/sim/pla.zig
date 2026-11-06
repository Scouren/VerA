//! IEEE 1364-2005 §17.5 programmable logic arrays: a PLA task's
//! personality memory and input terms in, its output terms out. An
//! asynchronous one is its own process (`Inst.spawn`), re-run whenever an
//! input or the personality changes; this file is the one evaluation.
//! Cites: IEEE 1364-2005 §17.5.1-§17.5.4.
//!
//! Contents:
//! - `pub fn task(s: *State, a: Allocator, at: u32) Error!void`
//! - `pub fn evaluate(c: Program.PlaCall, rows: []const Literal, in: Literal, out: Literal) void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Program = @import("Program.zig");
const State = @import("State.zig");
const eval = @import("eval.zig");
const logic = @import("logic.zig");
const calls = @import("calls.zig");
const Error = State.Error;
const Literal = logic.Literal;
const Bit = logic.Bit;

/// One PLA task call (`Program.PlaCall` at `at`): the outputs, all x to
/// start, computed from the memory's rows and assigned.
pub fn task(s: *State, a: Allocator, at: u32) Error!void {
    const c = s.p.extraData(Program.PlaCall, at);
    const in = try eval.eval(s, a, c.in);
    const out = try logic.filled(a, c.ty.width, false, .x);
    const rows = try a.alloc(Literal, c.count);
    for (rows, 0..) |*r, k| r.* = try eval.read(s, a, c.base + @as(u32, @intCast(k)));
    evaluate(c, rows, in, out);
    try eval.put(s, a, c.out, try calls.convertValue(a, out, false, c.ty), false, null);
}

/// §17.5 into `out`: row k of the personality (lowest address first)
/// computes output bit k (from the left); bit j of a row governs input j.
/// An unknown input a row selects makes it unknown unless the row's
/// controlling value decides it.
pub fn evaluate(c: Program.PlaCall, rows: []const Literal, in: Literal, out: Literal) void {
    const and_like = c.logic == .@"and" or c.logic == .nand;
    for (0..@min(rows.len, out.width)) |k| {
        const row = rows[k];
        var unknown = false;
        var decided = false;
        for (0..@min(row.width, in.width)) |j| {
            const sel = row.bit(@intCast(row.width - 1 - j));
            var b = in.bit(@intCast(in.width - 1 - j));
            if (c.plane) {
                // §17.5.4: 0 the complement, 1 the input, x the worst
                // case, z (or ?) nothing.
                if (sel == .zero) b = switch (b) {
                    .zero => .one,
                    .one => .zero,
                    else => .x,
                } else if (sel == .x) b = .x else if (sel != .one) continue;
            } else if (sel == .zero) continue else if (sel != .one) b = .x;
            if (b == (if (and_like) Bit.zero else Bit.one)) decided = true;
            if (b == .x or b == .z) unknown = true;
        }
        const value: Bit = if (decided) (if (and_like) .zero else .one) else if (unknown) .x else (if (and_like) .one else .zero);
        const inverted = c.logic == .nand or c.logic == .nor;
        logic.setBit(out, @intCast(out.width - 1 - k), if (!inverted) value else switch (value) {
            .zero => .one,
            .one => .zero,
            else => .x,
        });
    }
}

test "§17.5 an and-array row is the and of its selected inputs" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two rows over inputs (i1, i0): row 0 selects both, row 1 only i1.
    const r0 = try logic.filled(a, 2, false, .one);
    const r1 = try logic.filled(a, 2, false, .zero);
    logic.setBit(r1, 1, .one);
    const in = try logic.filled(a, 2, false, .zero);
    logic.setBit(in, 1, .one); // i1 = 1, i0 = 0
    const out = try logic.filled(a, 2, false, .x);
    const c: Program.PlaCall = .{ .logic = .@"and", .plane = false, .base = 0, .count = 2, .in = 0, .out = 0, .ty = .int(2, false) };
    evaluate(c, &.{ r0, r1 }, in, out);
    // Row 0: 1 & 0 = 0 (bit 1); row 1: 1 (bit 0).
    try std.testing.expectEqual(Bit.zero, out.bit(1));
    try std.testing.expectEqual(Bit.one, out.bit(0));
}
