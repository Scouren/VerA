//! A `Program.exprs` row in, its RTLIL sigspec out: a constant, a slot
//! (or a select of one), or a `$`-cell per operator over its operands'
//! sigspecs. A row's value is in its `ty`, its operands already in theirs
//! (Sema typed and sized them once, §5.4/§5.5); a width change is
//! `Module.fit`, `std_sim`'s `normalize`.
//! Cites: IEEE 1364-2005 §5.1 (operators), §5.2.1 (selects), §5.5.
//!
//! Contents:
//! - `pub fn row(m: *Module, e: u32) Module.Error!Sig`
//! - `pub fn reads(p: *const Program, e: u32, out: *std.ArrayList(u32), a: std.mem.Allocator) error{OutOfMemory}!void`

const std = @import("std");
const assert = std.debug.assert;
const std_sim = @import("std_sim");
const Module = @import("Module.zig");
const Program = std_sim.Program;
const Sig = Module.Sig;
const Error = Module.Error;

/// Expression row `e` as a sigspec exactly `ty.width` bits wide.
pub fn row(m: *Module, e: u32) Error!Sig {
    const p = m.p;
    assert(e < p.exprs.len);
    const tag = p.exprs.items(.tag)[e];
    const ty = p.exprs.items(.ty)[e];
    const d = p.exprs.items(.data)[e];
    if (ty.real) return error.Unsupported;
    const w: u32 = ty.width;
    const out: Sig = switch (tag) {
        .constant => blk: {
            const c = p.constOf(@fromBackingInt(@intCast(e)));
            break :blk try m.constant(c.v, c.x, w, ty.signed);
        },
        .slot => try m.slot(d.a),
        .select => try select(m, p.extraData(Program.Select, d.a)),
        .neg => try m.cell1("$neg", try row(m, d.a), w),
        .not => try m.cell1("$not", try row(m, d.a), w),
        .lnot => try m.cell1("$logic_not", try row(m, d.a), 1),
        .truth => try m.bit1(try row(m, d.a)),
        .red_and, .red_or, .red_xor, .red_xnor => try m.cell1(switch (tag) {
            .red_and => "$reduce_and",
            .red_or => "$reduce_or",
            .red_xor => "$reduce_xor",
            else => "$reduce_xnor", // else: the fourth reduction
        }, try row(m, d.a), 1),
        .red_nand, .red_nor => try m.cell1("$not", try m.cell1(if (tag == .red_nand) "$reduce_and" else "$reduce_or", try row(m, d.a), 1), 1),
        .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => try m.cell2(switch (tag) {
            .add => "$add",
            .sub => "$sub",
            .mul => "$mul",
            .div => "$div",
            .mod => "$mod",
            .bit_and => "$and",
            .bit_or => "$or",
            .bit_xor => "$xor",
            else => "$xnor", // else: `~^`
        }, try row(m, d.a), try row(m, d.b), w),
        .shl, .shr, .ashl, .ashr, .pow => blk: {
            const b = try row(m, d.b);
            // §5.1.12: a shift count is read unsigned.
            const count: Sig = if (tag == .pow) b else .{ .s = b.s, .w = b.w };
            break :blk try m.cell2(switch (tag) {
                .shl => "$shl",
                .shr => "$shr",
                .ashl => "$sshl",
                .ashr => "$sshr",
                else => "$pow", // else: `**`
            }, try row(m, d.a), count, w);
        },
        .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge => try m.cell2(switch (tag) {
            .eq => "$eq",
            .neq => "$ne",
            .case_eq => "$eqx",
            .case_neq => "$nex",
            .lt => "$lt",
            .le => "$le",
            .gt => "$gt",
            else => "$ge", // else: `>=`
        }, try row(m, d.a), try row(m, d.b), 1),
        .land, .lor => try m.cell2(if (tag == .land) "$logic_and" else "$logic_or", try row(m, d.a), try row(m, d.b), 1),
        .cond => blk: {
            const arms = p.extra[d.b..][0..2];
            const s = try m.bit1(try row(m, d.a));
            const yes = try m.fit(try row(m, arms[0]), w, ty.signed);
            const no = try m.fit(try row(m, arms[1]), w, ty.signed);
            break :blk try m.mux(s, no, yes);
        },
        .concat => blk: {
            var text: std.Io.Writer.Allocating = .init(m.arena);
            try text.writer.writeAll("{");
            var width: u32 = 0;
            for (p.list(.{ .start = d.a, .len = d.b })) |r| {
                if (p.exprs.items(.tag)[r] == .discard) continue;
                const part = try row(m, r);
                width += part.w;
                try text.writer.print(" {s}", .{part.s});
            }
            try text.writer.writeAll(" }");
            if (width == 0) return error.Unsupported;
            break :blk .{ .s = text.written(), .w = width };
        },
        .replicate => blk: {
            const one = try row(m, d.a);
            var text: std.Io.Writer.Allocating = .init(m.arena);
            try text.writer.writeAll("{");
            for (0..d.b) |_| try text.writer.print(" {s}", .{one.s});
            try text.writer.writeAll(" }");
            break :blk .{ .s = text.written(), .w = one.w * d.b };
        },
        .convert => try row(m, d.a),
        else => return error.Unsupported, // else: no synthesizable RTLIL (a real, a call, a system function)
    };
    return m.fit(out, w, ty.signed);
}

/// Every slot expression row `e` reads, into `out` (repeats kept).
pub fn reads(p: *const Program, e: u32, out: *std.ArrayList(u32), a: std.mem.Allocator) error{OutOfMemory}!void {
    var stack: std.ArrayList(u32) = .empty;
    try stack.append(a, e);
    var n: u32 = 0;
    while (stack.pop()) |r| : (n += 1) {
        assert(n <= p.exprs.len * 4);
        const d = p.exprs.items(.data)[r];
        switch (p.exprs.items(.tag)[r]) {
            .slot => try out.append(a, d.a),
            .select => {
                const s = p.extraData(Program.Select, d.a);
                try out.append(a, s.slot);
                if (s.mode != .const_part) try stack.append(a, s.index);
            },
            .neg, .not, .lnot, .truth, .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor, .convert, .replicate, .discard => try stack.append(a, d.a),
            .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor, .shl, .shr, .ashl, .ashr, .pow, .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .land, .lor => try stack.appendSlice(a, &.{ d.a, d.b }),
            .cond => try stack.appendSlice(a, &.{ d.a, p.extra[d.b], p.extra[d.b + 1] }),
            .concat => try stack.appendSlice(a, p.list(.{ .start = d.a, .len = d.b })),
            else => {}, // else: a constant, or a row `row` refuses anyway
        }
    }
}

// ---- private ----

/// §5.2.1 a select of a vector slot: a constant part as a slice, a
/// variable bit of a descending vector as `$shiftx` by its offset.
fn select(m: *Module, s: Program.Select) Error!Sig {
    if (s.elem != std.math.maxInt(u32)) return error.Unsupported;
    const base = try m.slot(s.slot);
    switch (s.mode) {
        .const_part => {
            if (s.first < 0 or s.first + s.count > base.w) return error.Unsupported;
            return m.part(base, @intCast(s.first), s.count);
        },
        .bit => {
            if (s.msb < s.lsb) return error.Unsupported;
            var idx = try row(m, s.index);
            if (s.lsb != 0) {
                const lsb: u64 = @bitCast(s.lsb);
                idx = try m.cell2("$sub", idx, try m.constant(&.{lsb}, &.{0}, @min(idx.w, 64), false), idx.w);
            }
            return m.cell2("$shiftx", base, .{ .s = idx.s, .w = idx.w }, 1);
        },
        .up, .down => return error.Unsupported,
    }
}
