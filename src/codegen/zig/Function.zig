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
//! - `pub fn genTree`, `pub fn valueOf`: a derived parameter's default
//! - `pub fn real`, `pub fn int`, `pub fn isIntRef`, `pub fn isInt`, `pub fn line`, `pub fn print`, `pub fn kernel`: what `calls.zig` writes with
//! - `pub const Phase`: which body is written

const std = @import("std");
const assert = std.debug.assert;
const Air = @import("air");
const InternPool = @import("intern_pool");
const vams = @import("vams");
const DeclGen = @import("DeclGen.zig");
const Liveness = @import("Liveness.zig");
const Ident = @import("Ident.zig");
const calls = @import("calls.zig");
const Inst = Air.Inst;
const Ref = Inst.Ref;
const Error = DeclGen.Error;

dg: *DeclGen,
w: *std.Io.Writer,
uses: Uses = .{},
/// Statement nesting, for indentation.
indent: u32 = 1,
/// Which body: `core`'s, or `say`'s (prints recorded, `say.zig`).
phase: Phase = .core,

pub const Phase = enum { core, say };

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

/// The most elements a scratch array's written-element mask covers: one word.
const mask_elements_max = 64;

const Label = struct {
    i: u32,
    pub fn format(l: Label, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("ld{d}", .{l.i});
    }
};

const Function = @This();

/// Writes `body`'s statements, nested bodies included. Asserts that the
/// body ends in one `noreturn` instruction (`Air.Verify`).
pub fn genBody(f: *Function, body: []const Inst.Index) Error!void {
    assert(body.len != 0);
    assert(f.indent <= Air.nesting_max + 1);
    for (body) |inst| try f.genInst(inst);
}

/// Writes `const v<i> = ...;` for every instruction `ref` reads, itself
/// included, in index order (an operand precedes its reader): a derived
/// parameter's default, which reads only `arg`s, constants and pure
/// operations. Returns how many it wrote.
pub fn genTree(f: *Function, ref: Ref) Error!u32 {
    const root = ref.toIndex() orelse return 0;
    const air = f.dg.air;
    const seen = try f.dg.arena.alloc(bool, air.instructions.len);
    @memset(seen, false);
    var stack: std.ArrayList(Inst.Index) = .empty;
    try stack.append(f.dg.arena, root);
    // Each instruction is pushed once, so the walk is bounded by the body.
    while (stack.pop()) |i| {
        if (seen[@backingInt(i)]) continue;
        seen[@backingInt(i)] = true;
        const tag = air.instructions.items(.tag)[@backingInt(i)];
        switch (tag) {
            .alloc, .load, .assign, .call, .probe, .block, .loop, .cond_br, .br, .repeat, .ret, .anew, .store, .fload, .iload, .path_prev, .path_acc => return f.dg.fail("a derived parameter default that reads `{t}`", .{tag}),
            else => {}, // else: a value of args, constants and its operands
        }
        var ops: Liveness.Operands = .{};
        ops.collect(air.*, tag, air.instructions.items(.data)[@backingInt(i)]);
        for (ops.slice()) |o| if (o.toIndex()) |oi| try stack.append(f.dg.arena, oi);
    }
    var n: u32 = 0;
    for (seen, 0..) |s, i| if (s) {
        const inst: Inst.Index = @fromBackingInt(@intCast(i));
        try f.line();
        try f.print("const v{d} = ", .{i});
        try f.genValue(inst, air.instructions.items(.tag)[i], air.instructions.items(.data)[i]);
        try f.print(";", .{});
        n += 1;
    };
    return n;
}

/// Writes operand `ref` as a plain number: a real's `.val()`, an integer.
pub fn valueOf(f: *Function, ref: Ref) Error!void {
    if (isIntRef(f, ref)) return f.int(ref);
    if (ref.toIndex()) |i| return f.print("v{d}.val()", .{@backingInt(i)});
    switch (f.dg.ip.indexToKey(ref.toInterned().?)) {
        .float => |x| return f.print("{f}", .{Real{ .x = x }}),
        else => return f.dg.fail("a derived parameter default that is not a number", .{}), // else: Verify types every real operand
    }
}

/// Writes a real operand: a value, or a constant as an `Of(0)` value.
pub fn real(f: *Function, ref: Ref) Error!void {
    if (ref.toIndex()) |i| return f.print("v{d}", .{@backingInt(i)});
    switch (f.dg.ip.indexToKey(ref.toInterned().?)) {
        .float => |x| return f.print("S.con({f})", .{Real{ .x = x }}),
        .int => |n| return f.print("S.con({d}.0)", .{n.storage.small}),
        else => return f.dg.fail("a real operand that is not a number", .{}), // else: Verify types every real operand
    }
}

/// Writes an integer operand.
pub fn int(f: *Function, ref: Ref) Error!void {
    if (ref.toIndex()) |i| return f.print("v{d}", .{@backingInt(i)});
    switch (f.dg.ip.indexToKey(ref.toInterned().?)) {
        .int => |n| switch (n.storage) {
            .small => |s| return f.print("@as(i64, {d})", .{s}),
            .big => return f.dg.fail("an integer constant wider than 64 bits", .{}),
        },
        else => return f.dg.fail("an integer operand that is not an integer", .{}), // else: Verify types every integer operand
    }
}

/// Whether operand `ref` is an integer.
pub fn isIntRef(f: *Function, ref: Ref) bool {
    return isInt(f.dg.ip, f.dg.air.typeOf(f.dg.ip, ref));
}

/// Whether type `ty` is an integer.
pub fn isInt(ip: *const InternPool, ty: InternPool.Index) bool {
    if (ty == InternPool.Index.integer_type) return true;
    return switch (ip.indexToKey(ty)) {
        .int_type => true,
        else => false, // else: a real, a string or an array
    };
}

/// Starts a statement line at the current nesting.
pub fn line(f: *Function) Error!void {
    try f.print("\n", .{});
    for (0..f.indent) |_| try f.print("    ", .{});
}

/// Writes to the body.
pub fn print(f: *Function, comptime fmt: []const u8, args: anytype) Error!void {
    f.w.print(fmt, args) catch return error.OutOfMemory;
}

/// Writes `M.<name>` over one scalar type at mask `m` (`F.zL(S, m)`), each
/// operand widened to it.
pub fn kernel(f: *Function, m: Liveness.Mask, name: []const u8, ops: []const Ref) Error!void {
    assert(ops.len == 1 or ops.len == 2);
    try f.print("F.zLu(S, 0x{x}, M.{s}(F.zL(S, 0x{x})", .{ m, name, m });
    for (ops) |o| {
        try f.print(", F.zLw(S, 0x{x}, ", .{m});
        try f.real(o);
        try f.print(")", .{});
    }
    try f.print("))", .{});
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
            if (f.dg.held_field[i]) |field| {
                // §5.10 the value the last accepted point left.
                f.uses.inst = true;
                if (isInt(f.dg.ip, data.ty))
                    try f.print("{s} s{d}: i64 = M.zInstI(S, inst, \"{s}\");", .{ kw, i, field })
                else
                    try f.print("{s} s{d}: F.zOf(S, 0x{x}) = F.zTo(S, 0x{x}, M.zInst(S, inst, \"{s}\"));", .{ kw, i, live.masks[i], live.masks[i], field });
            } else if (isInt(f.dg.ip, data.ty)) {
                try f.print("{s} s{d}: i64 = 0;", .{ kw, i });
            } else if (data.ty == InternPool.Index.real_type) {
                try f.print("{s} s{d}: F.zOf(S, 0x{x}) = F.zTo(S, 0x{x}, S.con(0.0));", .{ kw, i, live.masks[i], live.masks[i] });
            } else if (f.arrayOf(data.ty)) |a| {
                // §11.10 a scratch array: its storage is never zeroed; the
                // written-element mask `_m` says which elements hold a value.
                if (a.len > mask_elements_max) return f.dg.fail("a §3.2.2 array of {d} elements, past the {d} a written-element mask covers", .{ a.len, mask_elements_max });
                try f.print("var s{d}: [{d}]{f} = undefined; var s{d}_m: u64 = 0; _ = .{{ &s{d}, &s{d}_m }};", .{ i, a.len, f.elemText(a.elem, i), i, i, i });
                return;
            } else return f.dg.fail("a slot of type {d} (a string)", .{@backingInt(data.ty)});
            try f.print(" _ = &s{d};", .{i});
        },
        .assign => {
            const slot = data.bin_op.lhs.toIndex().?;
            if (f.arrayOf(f.dg.air.typeOfIndex(f.dg.ip, slot)) != null) return f.assignArray(slot, data.bin_op.rhs);
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
        .call => try calls.genCall(f, inst, data),
        // An array version is its slot's storage, written in place: a fresh
        // one is the mask's reset (`assignArray`), a load names the storage.
        .anew => {},
        .load => if (f.arrayOf(air.typeOfIndex(f.dg.ip, inst)) == null) try f.genValueStmt(inst, tag, data),
        .store => try f.genStore(data),
        else => try f.genValueStmt(inst, tag, data), // else: every other tag is a value: written when something reads it
    }
}

/// `const v<i> = <value>;` when something reads instruction `inst`.
fn genValueStmt(f: *Function, inst: Inst.Index, tag: Inst.Tag, data: Inst.Data) Error!void {
    if (!f.dg.live.used[@backingInt(inst)]) return;
    try f.line();
    try f.print("const v{d} = ", .{@backingInt(inst)});
    try f.genValue(inst, tag, data);
    try f.print(";", .{});
}

/// §3.2.2 the array slot a version reads: a `load` of it, or a `store` made
/// from one. Null for any other shape (a fresh `anew` read before it is
/// stored to a slot), which this backend does not spell.
fn rootSlot(f: *Function, ref: Ref) ?Inst.Index {
    var r = ref;
    // A chain of stores is as long as the body.
    for (0..f.dg.air.instructions.len + 1) |_| {
        const i = r.toIndex() orelse return null;
        const data = f.dg.air.instructions.items(.data)[@backingInt(i)];
        switch (f.dg.air.instructions.items(.tag)[@backingInt(i)]) {
            .load => return data.un_op.toIndex(),
            .store => r = data.pl_op.operand,
            else => return null, // else: an `anew`, a `select` or `block` of versions
        }
    }
    unreachable; // the chain walked every instruction
}

/// `slot = rhs` for an array slot: a fresh version is the per-evaluation
/// reset, one word (§11.10: no memset); a version stored from the slot's
/// own is already in place.
fn assignArray(f: *Function, slot: Inst.Index, rhs: Ref) Error!void {
    const i = rhs.toIndex() orelse return f.dg.fail("an array slot assigned a constant", .{});
    if (f.dg.air.instructions.items(.tag)[@backingInt(i)] == .anew) {
        try f.line();
        return f.print("s{d}_m = 0;", .{@backingInt(slot)});
    }
    if (f.rootSlot(rhs) != slot) return f.dg.fail("an array version assigned to a slot it was not read from", .{});
}

/// `store`: element `index` of the version's storage set to `value`, its
/// mask bit with it; an index outside the array writes nothing (§3.2.2).
fn genStore(f: *Function, data: Inst.Data) Error!void {
    const bin = f.dg.air.extraData(Air.Bin, data.pl_op.payload).data;
    const slot = f.rootSlot(data.pl_op.operand) orelse return f.dg.fail("a store into an array version that no slot holds", .{});
    const s = @backingInt(slot);
    const a = f.arrayOf(f.dg.air.typeOfIndex(f.dg.ip, slot)).?;
    try f.line();
    try f.print("{{ const k: i64 = ", .{});
    try f.int(bin.lhs);
    try f.print("; if (k >= 0 and k < {d}) {{ s{d}[@intCast(k)] = ", .{ a.len, s });
    if (isInt(f.dg.ip, a.elem)) try f.int(bin.rhs) else try f.widened(slot, bin.rhs);
    try f.print("; s{d}_m |= @as(u64, 1) << @intCast(k); }} }}", .{s});
}

/// `fload`/`iload`: element `index` when its mask bit says it was written,
/// else the element type's zero (§3.2.2: an unwritten element, or one
/// outside the array, reads 0).
fn genLoad(f: *Function, inst: Inst.Index, data: Inst.Data) Error!void {
    const slot = f.rootSlot(data.bin_op.lhs) orelse return f.dg.fail("a load from an array version that no slot holds", .{});
    const s = @backingInt(slot);
    const a = f.arrayOf(f.dg.air.typeOfIndex(f.dg.ip, slot)).?;
    try f.print("{f}: {{ const k: i64 = ", .{Label{ .i = @backingInt(inst) }});
    try f.int(data.bin_op.rhs);
    try f.print("; break :{f} if (k >= 0 and k < {d} and (s{d}_m >> @intCast(k)) & 1 != 0) s{d}[@intCast(k)] else ", .{ Label{ .i = @backingInt(inst) }, a.len, s, s });
    if (isInt(f.dg.ip, a.elem)) try f.print("0; }}", .{}) else try f.print("F.zTo(S, 0x{x}, S.con(0.0)); }}", .{f.dg.live.masks[s]});
}

/// The length and element type of array type `ty`, or null.
fn arrayOf(f: *Function, ty: InternPool.Index) ?InternPool.Key.ArrayType {
    if (ty == .none) return null;
    return switch (f.dg.ip.indexToKey(ty)) {
        .array_type => |a| a,
        else => null, // else: a scalar or a string
    };
}

/// An array slot's element type: an `i64`, or the family value at the
/// slot's mask.
fn elemText(f: *Function, elem: InternPool.Index, slot: u32) TypeText {
    return .{ .int = isInt(f.dg.ip, elem), .mask = f.dg.live.masks[slot] };
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
            if (isInt(f.dg.ip, data.ty_index.ty)) return f.print("model.{f}", .{Ident{ .name = name }});
            return f.print("S.con(model.{f})", .{Ident{ .name = name }});
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
        .fload, .iload => return f.genLoad(inst, data),
        .anew, .store => unreachable, // `genInst` writes them as statements
        else => unreachable, // else: the control tags, `alloc`, `assign` and `call` are statements (`genInst`)
    }
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

/// The Zig type of instruction `inst`'s value.
fn typeText(f: *Function, inst: Inst.Index) TypeText {
    const ty = f.dg.air.typeOfIndex(f.dg.ip, inst);
    return .{ .int = isInt(f.dg.ip, ty), .mask = f.dg.live.masks[@backingInt(inst)] };
}

fn nested(f: *Function, body: []const Inst.Index) Error!void {
    f.indent += 1;
    defer f.indent -= 1;
    try f.genBody(body);
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
