//! One `Air` body in, the Zig statements of the device's `core` out (Zig's
//! `codegen/c.zig` `Function`): every value instruction a `const v<i>`,
//! every slot a `var s<i>` (§11.7), `block`/`br` a labelled block, `cond_br`
//! an `if`, `loop`/`repeat` a labelled `while`. Structured Air is
//! structured Zig, so there is no relooper. A real is a family value typed
//! by the unknowns it depends on (`F.zOf(S, mask)`, `Liveness.masks`), an
//! integer an `i64` wrapped to §3.2's 32 bits. What the body reads beyond
//! its own values (`x`, `model`, `inst`, `sim`) is recorded while it is
//! written (`uses`), never by scanning the text. Each operation is spelled
//! as the old device spelled it (`src/codegen/device/codegen/render_op.zig`),
//! so the two compute the same bits.
//! Cites: VAMS-2023 §3.2, §4.2.1, §4.2.4, §4.2.5, §4.2.7-§4.2.12, §4.3.1
//! (Table 4-14), §4.3.2 (Table 4-15), §4.5.13, §5.7, §5.8, §9.10.
//!
//! Contents:
//! - fields `dg`, `w`, `uses`, `indent`
//! - `pub const Uses = struct { x, model, inst, sim }`
//! - `pub const Real = struct { x }` (`format`): a real constant as Zig source
//! - `pub fn genBody(f: *Function, body: []const Air.Inst.Index) DeclGen.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Air = @import("air");
const InternPool = @import("intern_pool");
const vams = @import("vams");
const DeclGen = @import("DeclGen.zig");
const Liveness = @import("Liveness.zig");
const Inst = Air.Inst;
const Ref = Inst.Ref;
const Error = DeclGen.Error;

dg: *DeclGen,
w: *std.Io.Writer,
uses: Uses = .{},
/// Statement nesting, for indentation.
indent: u32 = 1,

/// Which of `core`'s parameters the body read.
pub const Uses = struct { x: bool = false, model: bool = false, inst: bool = false, sim: bool = false };

/// A real constant as Zig source: a literal that parses back to the same
/// bits, or its bits when no literal does (a NaN, ±inf, -0).
pub const Real = struct {
    x: f64,
    pub fn format(r: Real, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (!std.math.isFinite(r.x) or (r.x == 0 and std.math.signbit(r.x)))
            return w.print("@as(f64, @bitCast(@as(u64, 0x{x})))", .{@as(u64, @bitCast(r.x))});
        try w.print("{e}", .{r.x});
    }
};

const TypeText = struct {
    int: bool,
    mask: Liveness.Mask,
    pub fn format(t: TypeText, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (t.int) return w.writeAll("i64");
        return w.print("F.zOf(S, 0x{x})", .{t.mask});
    }
};

/// §4.2.4 integer `/` with a zero divisor 0 (the old device's `idiv_fn`).
const idiv_fn = "(struct { fn zd_f(zd_a: i64, zd_b: i64) i64 { " ++
    "return if (zd_b == 0) 0 else @truncate(@divTrunc(@as(i65, zd_a), zd_b)); } }.zd_f)";
/// §4.2.4 integer `%`: a zero divisor traps in a solver device.
const imod_fn = "(struct { fn zm_f(zm_a: i64, zm_b: i64) i64 { if (zm_b == 0) { @trap(); } " ++
    "return if (zm_b == -1) 0 else @rem(zm_a, zm_b); } }.zm_f)";
/// IEEE 1364-2005 Table 5-6 `**` at 32 bits (`kernels/fold.zig`'s `ipow32`).
const ipow_fn = "(struct { fn zp_f(zp_b: i64, zp_n: i64) i64 { " ++
    "if (zp_n < 0) return if (zp_b == 1) 1 else if (zp_b == -1) (if (@rem(zp_n, 2) == 0) 1 else -1) else 0; " ++
    "var zp_x: i32 = @truncate(zp_b); var zp_e = zp_n; var zp_r: i32 = 1; " ++
    "while (zp_e > 0) : (zp_e >>= 1) { if (zp_e & 1 != 0) zp_r *%= zp_x; zp_x *%= zp_x; } " ++
    "return zp_r; } }.zp_f)";

const Function = @This();

/// Writes `body`'s statements, nested bodies included. Asserts that the
/// body ends in one `noreturn` instruction (`Air.Verify`).
pub fn genBody(f: *Function, body: []const Inst.Index) Error!void {
    assert(body.len != 0);
    assert(f.indent <= Air.nesting_max + 1);
    for (body) |inst| try f.genInst(inst);
}

// ---- private ----

fn genInst(f: *Function, inst: Inst.Index) Error!void {
    const air = f.dg.air;
    const i = @backingInt(inst);
    const tag = air.instructions.items(.tag)[i];
    const data = air.instructions.items(.data)[i];
    const live = f.dg.live;
    switch (tag) {
        .alloc => {
            try f.line();
            const kw = if (live.assigned[i]) "var" else "const";
            if (isInt(f.dg.ip, data.ty)) {
                try f.print("{s} s{d}: i64 = 0;", .{ kw, i });
            } else if (data.ty == InternPool.Index.real_type) {
                try f.print("{s} s{d}: F.zOf(S, 0x{x}) = F.zTo(S, 0x{x}, S.con(0.0));", .{ kw, i, live.masks[i], live.masks[i] });
            } else return f.dg.fail("a slot of type {d} (an array or a string)", .{@backingInt(data.ty)});
            try f.print(" _ = &s{d};", .{i});
        },
        .assign => {
            const slot = data.bin_op.lhs.toIndex().?;
            try f.line();
            try f.print("s{d} = ", .{@backingInt(slot)});
            try f.widened(slot, data.bin_op.rhs);
            try f.print(";", .{});
        },
        .block => {
            const x = air.extraData(Air.Block, data.ty_pl.payload);
            try f.line();
            if (data.ty_pl.ty != .none and live.used[i]) {
                try f.print("const v{d}: {f} = ", .{ i, f.typeText(inst) });
            } else if (data.ty_pl.ty != .none) try f.print("_ = ", .{});
            if (live.targeted[i]) try f.print("b{d}: ", .{i});
            try f.print("{{", .{});
            try f.nested(air.body(x.end, x.data.body_len));
            try f.line();
            try f.print("}}{s}", .{if (data.ty_pl.ty != .none) ";" else ""});
        },
        .loop => {
            const x = air.extraData(Air.Block, data.ty_pl.payload);
            try f.line();
            try f.print("l{d}: while (true) {{", .{i});
            try f.nested(air.body(x.end, x.data.body_len));
            try f.line();
            try f.print("}}", .{});
        },
        .cond_br => {
            const x = air.extraData(Air.CondBr, data.pl_op.payload);
            try f.line();
            try f.print("if (", .{});
            try f.int(data.pl_op.operand);
            try f.print(" != 0) {{", .{});
            try f.nested(air.body(x.end, x.data.then_body_len));
            try f.line();
            try f.print("}} else {{", .{});
            try f.nested(air.body(x.end + x.data.then_body_len, x.data.else_body_len));
            try f.line();
            try f.print("}}", .{});
        },
        .br => {
            const blk = data.br.block_inst;
            try f.line();
            if (data.br.operand == .none) return f.print("break :b{d};", .{@backingInt(blk)});
            try f.print("break :b{d} ", .{@backingInt(blk)});
            try f.widened(blk, data.br.operand);
            try f.print(";", .{});
        },
        .repeat => {
            try f.line();
            try f.print("continue :l{d};", .{@backingInt(data.repeat.loop_inst)});
        },
        .ret => {
            try f.line();
            try f.dg.genReturn(f);
        },
        .call => try f.genCall(inst, data),
        // else: every other tag is a value: written when something reads it
        else => {
            if (!live.used[i]) return;
            try f.line();
            try f.print("const v{d} = ", .{i});
            try f.genValue(inst, tag, data);
            try f.print(";", .{});
        },
    }
}

/// Writes a value instruction's expression.
fn genValue(f: *Function, inst: Inst.Index, tag: Inst.Tag, data: Inst.Data) Error!void {
    const i = @backingInt(inst);
    const m = f.dg.live.masks[i];
    switch (tag) {
        .arg => {
            f.uses.model = true;
            const k = data.ty_index.index;
            const name = f.dg.paramName(k);
            if (isInt(f.dg.ip, data.ty_index.ty)) return f.print("model.{f}", .{std.zig.fmtId(name)});
            return f.print("S.con(model.{f})", .{std.zig.fmtId(name)});
        },
        .probe => {
            f.uses.x = true;
            return f.print("x[{d}]", .{data.ty_index.index});
        },
        .load => return f.print("s{d}", .{@backingInt(data.un_op.toIndex().?)}),
        // §4.2.4 real arithmetic over the family's methods.
        .fadd, .fsub, .fmul, .fdiv => {
            try f.print("(", .{});
            try f.real(data.bin_op.lhs);
            try f.print(").{s}(", .{switch (tag) {
                .fadd => "add",
                .fsub => "sub",
                .fmul => "mul",
                else => "div", // else: the prong's four tags
            }});
            try f.real(data.bin_op.rhs);
            return f.print(")", .{});
        },
        .fneg, .exp, .sin, .cos, .tanh, .sinh, .cosh, .atan, .expm1 => {
            try f.print("(", .{});
            try f.real(data.un_op);
            return f.print(").{s}()", .{switch (tag) {
                .fneg => "neg",
                .exp => "exp",
                .sin => "sin",
                .cos => "cos",
                .tanh => "tanh",
                .sinh => "sinh",
                .cosh => "cosh",
                .atan => "atan",
                else => "expm1", // else: the prong's tags
            }});
        },
        // §4.3.2 the one-bound domains, checked where they run.
        .sqrt, .ln, .ln1p => {
            try f.print("M.{s}(S, ", .{switch (tag) {
                .sqrt => "zSqrtD",
                .ln => "zLnD",
                else => "zLn1pD", // else: the prong's tags
            }});
            try f.real(data.un_op);
            return f.print(")", .{});
        },
        .fabs => {
            try f.print("F.zAbs(S, ", .{});
            try f.real(data.un_op);
            return f.print(")", .{});
        },
        .log10, .tan, .asin, .acos, .asinh, .acosh, .atanh, .floor, .ceil => return f.kernel(m, switch (tag) {
            .log10 => "zLog10D",
            .tan => "zTan",
            .asin => "zAsin",
            .acos => "zAcos",
            .asinh => "zAsinh",
            .acosh => "zAcosh",
            .atanh => "zAtanh",
            .floor => "zFloor",
            else => "zCeil", // else: the prong's tags
        }, &.{data.un_op}),
        .fmod, .hypot, .atan2, .fmin, .fmax => return f.kernel(m, switch (tag) {
            .fmod => "zFmod",
            .hypot => "zHypot",
            .atan2 => "zAtan2",
            .fmin => "zMin",
            else => "zMax", // else: the prong's tags
        }, &.{ data.bin_op.lhs, data.bin_op.rhs }),
        .pow => {
            const b = data.bin_op.rhs;
            if (f.dg.live.maskOf(b) == 0) {
                // An exponent that does not move with the solve.
                try f.print("M.zPowK(S, ", .{});
                try f.real(data.bin_op.lhs);
                try f.print(", (", .{});
                try f.real(b);
                return f.print(").val())", .{});
            }
            try f.print("F.zPowL(S, 0x{x}, F.zTo(S, 0x{x}, ", .{ m, m });
            try f.real(data.bin_op.lhs);
            try f.print("), F.zTo(S, 0x{x}, ", .{m});
            try f.real(b);
            return f.print("), true)", .{});
        },
        // §4.2.1 conversions.
        .if_cast => {
            try f.print("S.con(@as(f64, @floatFromInt(", .{});
            try f.int(data.un_op);
            return f.print(")))", .{});
        },
        .fi_cast => {
            try f.print("M.zRoundI(S, ", .{});
            try f.real(data.un_op);
            return f.print(")", .{});
        },
        .opt_barrier => return if (isIntRef(f, data.un_op)) f.int(data.un_op) else f.real(data.un_op),
        .dstop => {
            try f.print("M.zStrip(S, ", .{});
            try f.real(data.un_op);
            return f.print(")", .{});
        },
        // §4.2.12 a value-level `?:`.
        .select => {
            const bin = f.dg.air.extraData(Air.Bin, data.pl_op.payload).data;
            const int_result = isIntRef(f, bin.lhs);
            if (!int_result) try f.print("@as({f}, ", .{f.typeText(inst)});
            try f.print("if (", .{});
            try f.int(data.pl_op.operand);
            try f.print(" != 0) ", .{});
            try f.widened(inst, bin.lhs);
            try f.print(" else ", .{});
            try f.widened(inst, bin.rhs);
            if (!int_result) try f.print(")", .{});
        },
        // §4.2.5/§4.2.7 comparisons, integer 0/1.
        .flt, .fgt, .fle, .fge, .feq, .fne => {
            try f.print("@as(i64, @intFromBool(M.zCmp(S, .{s}, ", .{switch (tag) {
                .flt => "lt",
                .fgt => "gt",
                .fle => "lte",
                .fge => "gte",
                .feq => "eq",
                else => "neq", // else: the prong's tags
            }});
            try f.real(data.bin_op.lhs);
            try f.print(", ", .{});
            try f.real(data.bin_op.rhs);
            return f.print(")))", .{});
        },
        .ilt, .igt, .ile, .ige, .ieq, .ine => return f.intOp("@as(i64, @intFromBool((", data, switch (tag) {
            .ilt => ") < (",
            .igt => ") > (",
            .ile => ") <= (",
            .ige => ") >= (",
            .ieq => ") == (",
            else => ") != (", // else: the prong's tags
        }, ")))"),
        // §3.2 integer arithmetic at 32-bit two's complement width.
        .iadd => return f.intOp("@as(i64, @as(i32, @truncate((", data, ") +% (", "))))"),
        .isub => return f.intOp("@as(i64, @as(i32, @truncate((", data, ") -% (", "))))"),
        .imul => return f.intOp("@as(i64, @as(i32, @truncate((", data, ") *% (", "))))"),
        .idiv => return f.intOp("@as(i64, @as(i32, @truncate(" ++ idiv_fn ++ "(", data, ", ", "))))"),
        .imod => return f.intOp(imod_fn ++ "(", data, ", ", ")"),
        .imin => return f.intOp("@min(", data, ", ", ")"),
        .imax => return f.intOp("@max(", data, ", ", ")"),
        .ipow => return f.intOp(ipow_fn ++ "(", data, ", ", ")"),
        .logand => return f.intOp("@as(i64, @intFromBool((", data, ") != 0 and (", ") != 0))"),
        .logor => return f.intOp("@as(i64, @intFromBool((", data, ") != 0 or (", ") != 0))"),
        .bitand => return f.intOp("((", data, ") & (", "))"),
        .bitor => return f.intOp("((", data, ") | (", "))"),
        .bitxor => return f.intOp("((", data, ") ^ (", "))"),
        .bitxnor => return f.intOp("~((", data, ") ^ (", "))"),
        .shl => return f.intOp("@as(i64, @as(i32, @truncate(M.zShl(", data, ", ", "))))"),
        .shr => return f.intOp("M.zShr(", data, ", ", ")"),
        .ineg, .lognot, .bitnot, .iabs => {
            try f.print("{s}", .{switch (tag) {
                .ineg => "@as(i64, @as(i32, @truncate(-%(",
                .lognot => "@as(i64, @intFromBool((",
                .bitnot => "~(",
                else => "M.zIabs((", // else: the prong's tags
            }});
            try f.int(data.un_op);
            return f.print("{s}", .{switch (tag) {
                .ineg => "))))",
                .lognot => ") == 0))",
                .bitnot => ")",
                else => "))", // else: the prong's tags
            }});
        },
        .path_prev, .path_acc => return f.dg.fail("a §5.6.1.2 path latch (`{t}`)", .{tag}),
        .anew, .fload, .iload, .store => return f.dg.fail("a §3.2.2 array version (`{t}`)", .{tag}),
        // else: the control tags, `alloc`, `assign` and `call` are statements (`genInst`)
        else => unreachable,
    }
}

/// A `call`: a system function's value, or a task (a statement).
fn genCall(f: *Function, inst: Inst.Index, data: Inst.Data) Error!void {
    const air = f.dg.air;
    const x = air.extraData(Air.Call, data.ty_pl.payload);
    const args: []const Ref = @ptrCast(air.extra[x.end..][0..x.data.args_len]);
    const used = f.dg.live.used[@backingInt(inst)];
    const max_tag = std.math.maxInt(@typeInfo(vams.SysFn.Tag).@"enum".tag_type);
    if (x.data.callee > max_tag) return if (used) f.dg.fail("a call of a user function (callee {d})", .{x.data.callee});
    const tag: vams.SysFn.Tag = @fromBackingInt(@intCast(x.data.callee));
    const info = vams.SysFn.get(tag);
    switch (info.family) {
        // §9.4/§9.7 a print or a simulation control task is not part of a
        // residual: the device's display phase runs it.
        .display, .simctl => return if (used) f.dg.fail("the value of `{s}`", .{@tagName(tag)}),
        // else: a value, by tag below
        else => {},
    }
    if (!used and !Liveness.effect(air.*, .call, data)) return;
    try f.line();
    try f.print("const v{d} = ", .{@backingInt(inst)});
    switch (tag) {
        // §9.10 environment.
        .@"$temperature" => {
            f.uses.model = true;
            try f.print("S.con(model.temperature__)", .{});
        },
        .@"$vt" => if (args.len == 0) {
            f.uses.model = true;
            try f.print("S.con(model.temperature__ * 8.617333262145179e-5)", .{});
        } else {
            try f.print("(", .{});
            try f.real(args[0]);
            try f.print(").scale(8.617333262145179e-5)", .{});
        },
        .@"$abstime", .@"$realtime" => {
            f.uses.sim = true;
            try f.print("S.con(sim.t)", .{});
        },
        .@"$mfactor" => {
            f.uses.inst = true;
            try f.print("M.zInst(S, inst, \"mfactor\")", .{});
        },
        // §4.5.13: limexp is `exp`'s own text (VD-121, as the old device).
        .limexp => {
            try f.print("(", .{});
            try f.real(args[0]);
            try f.print(").exp()", .{});
        },
        // else: not yet spelled by this backend
        else => return f.dg.fail("a call of `{s}`", .{@tagName(tag)}),
    }
    try f.print(";", .{});
}

/// Writes `M.<name>` over one scalar type at mask `m` (`F.zL(S, m)`), each
/// operand widened to it.
fn kernel(f: *Function, m: Liveness.Mask, name: []const u8, ops: []const Ref) Error!void {
    assert(ops.len == 1 or ops.len == 2);
    try f.print("F.zLu(S, 0x{x}, M.{s}(F.zL(S, 0x{x})", .{ m, name, m });
    for (ops) |o| {
        try f.print(", F.zLw(S, 0x{x}, ", .{m});
        try f.real(o);
        try f.print(")", .{});
    }
    try f.print("))", .{});
}

/// Writes `head a mid b tail` over a `bin_op`'s integer operands.
fn intOp(f: *Function, head: []const u8, data: Inst.Data, mid: []const u8, tail: []const u8) Error!void {
    try f.print("{s}", .{head});
    try f.int(data.bin_op.lhs);
    try f.print("{s}", .{mid});
    try f.int(data.bin_op.rhs);
    try f.print("{s}", .{tail});
}

/// Writes `ref` converted to the type of `to` (a slot, a block, a
/// `select`): a real widened to its mask, an integer as it is.
fn widened(f: *Function, to: Inst.Index, ref: Ref) Error!void {
    if (isInt(f.dg.ip, f.dg.air.typeOfIndex(f.dg.ip, to))) return f.int(ref);
    const m = f.dg.live.masks[@backingInt(to)];
    try f.print("F.zTo(S, 0x{x}, ", .{m});
    try f.real(ref);
    try f.print(")", .{});
}

/// Writes a real operand: a value, or a constant as an `Of(0)` value.
fn real(f: *Function, ref: Ref) Error!void {
    if (ref.toIndex()) |i| return f.print("v{d}", .{@backingInt(i)});
    switch (f.dg.ip.indexToKey(ref.toInterned().?)) {
        .float => |x| return f.print("S.con({f})", .{Real{ .x = x }}),
        .int => |n| return f.print("S.con({d}.0)", .{n.storage.small}),
        // else: Verify types every real operand
        else => return f.dg.fail("a real operand that is not a number", .{}),
    }
}

/// Writes an integer operand.
fn int(f: *Function, ref: Ref) Error!void {
    if (ref.toIndex()) |i| return f.print("v{d}", .{@backingInt(i)});
    switch (f.dg.ip.indexToKey(ref.toInterned().?)) {
        .int => |n| switch (n.storage) {
            .small => |s| return f.print("@as(i64, {d})", .{s}),
            .big => return f.dg.fail("an integer constant wider than 64 bits", .{}),
        },
        // else: Verify types every integer operand
        else => return f.dg.fail("an integer operand that is not an integer", .{}),
    }
}

/// The Zig type of instruction `inst`'s value.
fn typeText(f: *Function, inst: Inst.Index) TypeText {
    const ty = f.dg.air.typeOfIndex(f.dg.ip, inst);
    return .{ .int = isInt(f.dg.ip, ty), .mask = f.dg.live.masks[@backingInt(inst)] };
}

fn isIntRef(f: *Function, ref: Ref) bool {
    return isInt(f.dg.ip, f.dg.air.typeOf(f.dg.ip, ref));
}

fn isInt(ip: *const InternPool, ty: InternPool.Index) bool {
    if (ty == InternPool.Index.integer_type) return true;
    return switch (ip.indexToKey(ty)) {
        .int_type => true,
        // else: a real, a string or an array
        else => false,
    };
}

fn nested(f: *Function, body: []const Inst.Index) Error!void {
    f.indent += 1;
    defer f.indent -= 1;
    try f.genBody(body);
}

fn line(f: *Function) Error!void {
    try f.print("\n", .{});
    for (0..f.indent) |_| try f.print("    ", .{});
}

fn print(f: *Function, comptime fmt: []const u8, args: anytype) Error!void {
    f.w.print(fmt, args) catch return error.OutOfMemory;
}

test "Real: every constant prints as a literal that parses back to its bits" {
    const xs = [_]f64{ 1e-15, 1.380649e-23, -1.0, 0.1, 3.0, std.math.floatMax(f64), std.math.floatTrueMin(f64), -0.0, std.math.inf(f64), std.math.nan(f64), 0.0, 8.617333262145179e-5 };
    var buf: [128]u8 = undefined;
    for (xs) |x| {
        const text = try std.fmt.bufPrint(&buf, "{f}", .{Real{ .x = x }});
        if (std.mem.startsWith(u8, text, "@as")) {
            try std.testing.expect(!std.math.isFinite(x) or std.math.signbit(x));
            continue;
        }
        const back = try std.fmt.parseFloat(f64, text);
        try std.testing.expectEqual(@as(u64, @bitCast(x)), @as(u64, @bitCast(back)));
    }
}
