//! An `Air` body in, readable text out (Zig's `Air/print.zig`): one line
//! per instruction, `%i = tag(operands)`, nested bodies indented two spaces
//! inside `{ }`. A constant prints as `<type, value>`, a type by its §3.2
//! name. For people debugging; nothing parses it back.
//! No LRM clause: this prints VerA's own IR.
//!
//! Contents:
//! - `pub fn write(air: Air, ip: *const InternPool, w: *std.Io.Writer) std.Io.Writer.Error!void`
//! - `pub fn writeBody(air: Air, ip: *const InternPool, w: *std.Io.Writer, body: []const Air.Inst.Index, indent: u32) std.Io.Writer.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const InternPool = @import("intern_pool");
const Air = @import("../Air.zig");
const Inst = Air.Inst;

/// Writes the main body.
pub fn write(air: Air, ip: *const InternPool, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try writeBody(air, ip, w, air.mainBody(), 0);
}

/// Writes `body`, each line indented `indent` spaces. Asserts that the
/// nesting stays within `Air.nesting_max`.
pub fn writeBody(air: Air, ip: *const InternPool, w: *std.Io.Writer, body: []const Inst.Index, indent: u32) std.Io.Writer.Error!void {
    assert(indent / 2 <= Air.nesting_max);
    for (body) |inst| {
        try w.splatByteAll(' ', indent);
        try writeInst(air, ip, w, inst, indent);
        try w.writeByte('\n');
    }
}

// ---- private ----

fn writeInst(air: Air, ip: *const InternPool, w: *std.Io.Writer, inst: Inst.Index, indent: u32) std.Io.Writer.Error!void {
    const tag = air.instructions.items(.tag)[@backingInt(inst)];
    const data = air.instructions.items(.data)[@backingInt(inst)];
    try w.print("%{d} = {s}(", .{ @backingInt(inst), @tagName(tag) });
    switch (tag) {
        .select, .store => {
            const bin = air.extraData(Air.Bin, data.pl_op.payload).data;
            try refs(ip, w, &.{ data.pl_op.operand, bin.lhs, bin.rhs });
        },
        .cond_br => {
            const x = air.extraData(Air.CondBr, data.pl_op.payload);
            try writeRef(ip, w, data.pl_op.operand);
            try nested(air, ip, w, air.body(x.end, x.data.then_body_len), indent);
            try nested(air, ip, w, air.body(x.end + x.data.then_body_len, x.data.else_body_len), indent);
        },
        .block, .loop => {
            const x = air.extraData(Air.Block, data.ty_pl.payload);
            try writeType(ip, w, data.ty_pl.ty);
            try nested(air, ip, w, air.body(x.end, x.data.body_len), indent);
        },
        .call => {
            const x = air.extraData(Air.Call, data.ty_pl.payload);
            try writeType(ip, w, data.ty_pl.ty);
            try w.print(", callee {d}", .{x.data.callee});
            for (air.extra[x.end..][0..x.data.args_len]) |a| {
                try w.writeAll(", ");
                try writeRef(ip, w, @fromBackingInt(a));
            }
        },
        .anew => {
            try writeType(ip, w, data.ty_pl.ty);
            try w.print(", array {d}", .{data.ty_pl.payload});
        },
        .br => {
            try w.print("%{d}, ", .{@backingInt(data.br.block_inst)});
            try writeRef(ip, w, data.br.operand);
        },
        .repeat => try w.print("%{d}", .{@backingInt(data.repeat.loop_inst)}),
        .alloc => try writeType(ip, w, data.ty),
        .arg, .probe => {
            try writeType(ip, w, data.ty_index.ty);
            try w.print(", {d}", .{data.ty_index.index});
        },
        else => switch (Air.tag_info.getPtrConst(tag).class) {
            .un_op => try writeRef(ip, w, data.un_op),
            .bin_op => try refs(ip, w, &.{ data.bin_op.lhs, data.bin_op.rhs }),
            .pl_op, .ty_pl, .ty, .ty_index, .br, .repeat => unreachable, // each such tag has its prong above
        },
    }
    try w.writeByte(')');
}

fn refs(ip: *const InternPool, w: *std.Io.Writer, rs: []const Inst.Ref) std.Io.Writer.Error!void {
    for (rs, 0..) |r, i| {
        if (i != 0) try w.writeAll(", ");
        try writeRef(ip, w, r);
    }
}

fn nested(air: Air, ip: *const InternPool, w: *std.Io.Writer, body: []const Inst.Index, indent: u32) std.Io.Writer.Error!void {
    try w.writeAll(", {\n");
    try writeBody(air, ip, w, body, indent + 2);
    try w.splatByteAll(' ', indent);
    try w.writeByte('}');
}

fn writeRef(ip: *const InternPool, w: *std.Io.Writer, r: Inst.Ref) std.Io.Writer.Error!void {
    if (r == .none) return w.writeAll("none");
    if (r.toIndex()) |i| return w.print("%{d}", .{@backingInt(i)});
    const index = r.toInterned().?;
    try w.writeByte('<');
    try writeType(ip, w, ip.typeOf(index));
    try w.writeAll(", ");
    switch (ip.indexToKey(index)) {
        .float => |f| try w.print("{e}", .{f}),
        .int => |int| switch (int.storage) {
            .small => |v| try w.print("{d}", .{v}),
            .big => |limbs| try w.print("({d} limbs)", .{limbs.len}),
        },
        .str => |s| try w.print("\"{f}\"", .{std.zig.fmtString(ip.stringToSlice(s))}),
        .undef => try w.writeAll("undef"),
        .aggregate => |agg| try w.print("({d} elements)", .{agg.elems.len}),
        .simple_type, .int_type, .array_type, .nature, .discipline => unreachable, // `typeOf` asserted a value
    }
    try w.writeByte('>');
}

fn writeType(ip: *const InternPool, w: *std.Io.Writer, ty: InternPool.Index) std.Io.Writer.Error!void {
    if (ty == .none) return w.writeAll("none");
    switch (ip.indexToKey(ty)) {
        .simple_type => |s| try w.writeAll(@tagName(s)),
        .int_type => |t| try w.print("{c}{d}", .{ @as(u8, if (t.signed) 'i' else 'u'), t.bits }),
        .array_type => |a| {
            try w.print("[{d}]", .{a.len});
            try writeType(ip, w, a.elem);
        },
        .nature, .discipline, .undef, .float, .int, .str, .aggregate => unreachable, // a value is not a type
    }
}

test "print: a slot, a block and a cond_br, by hand" {
    // Oracle: the text written by hand from the format the header states.
    const gpa = std.testing.allocator;
    var ip = try InternPool.init(gpa);
    defer ip.deinit(gpa);
    var b = try Air.Builder.init(gpa);
    defer b.deinit(gpa);
    const n = try b.addInst(gpa, .{ .tag = .arg, .data = .{ .ty_index = .{ .ty = .integer_type, .index = 0 } } });
    const slot = try b.addInst(gpa, .{ .tag = .alloc, .data = .{ .ty = .real_type } });
    const blk = try b.addInst(gpa, .{ .tag = .block, .data = undefined });
    const c = try b.addBinOp(gpa, .ilt, .fromIndex(n), .fromIntern(.one));
    const br_a = try b.addInst(gpa, .{ .tag = .br, .data = .{ .br = .{ .block_inst = blk, .operand = .fromIntern(.ten_real) } } });
    const br_b = try b.addInst(gpa, .{ .tag = .br, .data = .{ .br = .{ .block_inst = blk, .operand = .fromIntern(.neg_one_real) } } });
    const cb = try b.addCondBr(gpa, .fromIndex(c), &.{br_a}, &.{br_b});
    try b.setBody(gpa, blk, .real_type, &.{ c, cb });
    const set = try b.addBinOp(gpa, .assign, .fromIndex(slot), .fromIndex(blk));
    const v = try b.addUnOp(gpa, .load, .fromIndex(slot));
    const r = try b.addUnOp(gpa, .ret, .fromIndex(v));
    var air = try b.finish(gpa, &.{ n, slot, blk, set, v, r });
    defer air.deinit(gpa);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(air, &ip, &out.writer);
    try std.testing.expectEqualStrings(
        \\%0 = arg(integer, 0)
        \\%1 = alloc(real)
        \\%2 = block(real, {
        \\  %3 = ilt(%0, <integer, 1>)
        \\  %6 = cond_br(%3, {
        \\    %4 = br(%2, <real, 1e1>)
        \\  }, {
        \\    %5 = br(%2, <real, -1e0>)
        \\  })
        \\})
        \\%7 = assign(%1, %2)
        \\%8 = load(%1)
        \\%9 = ret(%8)
        \\
    , out.written());
}
