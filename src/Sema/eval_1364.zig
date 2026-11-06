//! The comptime evaluator's IEEE 1364 mode (`eval.zig`'s Env, beside its
//! 32-bit VAMS mode): one Vir expression of one instance in, its four-state
//! value of any width out (a `kernels.Integer.Literal`, x and z bits and
//! values past 64 bits included), or null when it has none at elaboration.
//! Expressions are sized as §5.4/§5.5 size them (a self-determined type,
//! then the context propagated down), every operator is
//! `kernels.Integer`'s, and a §10.4.5 constant function's call runs its
//! body (assignments, blocks, `if`, `case`, loops, `repeat`; a system task
//! is ignored) over values of its declared types. A real operand defers to
//! the VAMS mode's `Env.ref`.
//! Cites: IEEE 1364-2005 §3.5.1, §4.10, §5.1, §5.4, §5.5, §9.5, §10.4.5,
//! §12.2.
//!
//! Contents:
//! - `pub const Value = union(enum)`, `pub const Type = struct`, `pub const steps_max: u32`, `pub const Frame = struct`
//! - `pub const Eval = struct` (`vir`, `tag`, `payload`, `typeOf`, `ctx`, `intOf`, `self`, `count`, `fit`, `alloc`, `fromInt`, `bit`, `string`, `bigInt`, `declType`, `declValue`, `rangeType`, `select`, `declRange`, `callee`, `varType`, `resultType`: the sizing and the operators; `eval_1364_fn.zig` the constant functions)
//! - `pub fn common(a: Type, b: Type) Type`, `pub fn setBit(l: Lit, k: u32, b: Bit) void`
//! - `pub fn value(env: *Env, r: Inst.Ref) Allocator.Error!?Value`
//! - `pub fn int(env: *Env, r: Inst.Ref) Allocator.Error!?i64`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const kernels = @import("kernels");
const eval = @import("eval.zig");
const Env = eval.Env;
const Lit = kernels.Integer.Literal;
const Bit = kernels.Integer.Bit;
const Vir = vams.Vir;
const Inst = Vir.Inst;
const fun = @import("eval_1364_fn.zig");

/// A 1364 constant: an integral value, or a real (§4.8).
pub const Value = union(enum) { int: Lit, real: f64 };

/// A §5.5 type: a width and signedness, or real.
pub const Type = struct { width: u32, signed: bool, real: bool = false };

/// The most statements one constant function call runs.
pub const steps_max: u32 = 1 << 20;

/// One constant function activation: its variables' values and types.
pub const Frame = struct {
    vars: std.AutoHashMapUnmanaged(Inst.Index, Lit) = .empty,
    types: std.AutoHashMapUnmanaged(Inst.Index, Type) = .empty,
};

pub const Eval = struct {
    env: *Env,
    a: Allocator,
    frame: ?*Frame = null,
    steps: u32 = 0,

    pub fn vir(e: *const Eval) *const Vir {
        return e.env.vir;
    }

    pub fn tag(e: *const Eval, i: Inst.Index) Inst.Tag {
        return e.vir().instructions.items(.tag)[@backingInt(i)];
    }

    pub fn payload(e: *const Eval, comptime T: type, i: Inst.Index) T {
        return e.vir().extraData(T, e.vir().instructions.items(.data)[@backingInt(i)].pl_node.payload_index);
    }

    /// §5.4/§5.5.1 the self-determined type of `r`, or null.
    pub fn typeOf(e: *Eval, r: Inst.Ref) Allocator.Error!?Type {
        const i = r.toIndex() orelse return null;
        const data = e.vir().instructions.items(.data)[@backingInt(i)];
        return switch (e.tag(i)) {
            .int => .{ .width = if (std.math.cast(i32, @as(i64, @bitCast(data.int))) != null) 32 else 64, .signed = true },
            .big_int => if (try e.bigInt(i)) |l| .{ .width = l.width, .signed = l.signed } else null,
            .str => .{ .width = @intCast(@max(1, data.str.len) * 8), .signed = false },
            .real => .{ .width = 64, .signed = true, .real = true },
            .decl_ref => e.declType(data.decl_tok.decl),
            .pos, .neg, .bit_not => e.typeOf(data.un_node.operand),
            .not, .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor => .{ .width = 1, .signed = false },
            .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => blk: {
                const b = e.payload(Inst.Bin, i);
                break :blk common((try e.typeOf(b.lhs)) orelse return null, (try e.typeOf(b.rhs)) orelse return null);
            },
            .shl, .shr, .ashl, .ashr, .pow => e.typeOf(e.payload(Inst.Bin, i).lhs),
            .lt, .gt, .lte, .gte, .eq, .neq, .case_eq, .case_neq, .bool_and, .bool_or => .{ .width = 1, .signed = false },
            .ternary => blk: {
                const t = e.payload(Inst.Triple, i);
                break :blk common((try e.typeOf(t.b)) orelse return null, (try e.typeOf(t.c)) orelse return null);
            },
            .mintypmax => e.typeOf(e.payload(Inst.Triple, i).b),
            .concat => blk: {
                var w: u32 = 0;
                for (e.vir().list(Inst.Ref, e.payload(Inst.Refs, i))) |x| w += ((try e.typeOf(x)) orelse return null).width;
                break :blk if (w == 0) null else .{ .width = w, .signed = false };
            },
            .replicate => blk: {
                const b = e.payload(Inst.Bin, i);
                const n = (try e.count(b.lhs)) orelse return null;
                const t = (try e.typeOf(b.rhs)) orelse return null;
                // §5.1.14 a zero count: no bits, only inside a concatenation.
                break :blk .{ .width = n * t.width, .signed = false };
            },
            .elem, .slice, .slice_up, .slice_down => blk: {
                const s = (try e.select(i)) orelse return null;
                break :blk .{ .width = s.width, .signed = false };
            },
            .call => blk: {
                const f = e.callee(i) orelse return null;
                break :blk try e.resultType(f);
            },
            .call_sys => blk: {
                const c = e.payload(Inst.SysCall, i);
                const name = e.vir().string(c.name);
                const args = e.vir().list(Inst.Ref, c.args);
                if ((std.mem.eql(u8, name, "$signed") or std.mem.eql(u8, name, "$unsigned")) and args.len == 1) {
                    const t = (try e.typeOf(args[0])) orelse return null;
                    break :blk .{ .width = t.width, .signed = name[1] == 's' };
                }
                if (std.mem.eql(u8, name, "$clog2")) break :blk .{ .width = 32, .signed = true };
                break :blk if (try e.env.ref(r)) |c2| switch (c2) {
                    .real => .{ .width = 64, .signed = true, .real = true },
                    else => .{ .width = 32, .signed = true }, // else: an integer or a string reads as an integer
                } else null;
            },
            else => null, // else: no other expression has a value at elaboration
        };
    }

    /// `r` evaluated in context type `t` (§5.5.2), as a value `t.width`
    /// bits wide.
    pub fn ctx(e: *Eval, r: Inst.Ref, t: Type) Allocator.Error!?Lit {
        if (e.env.depth >= eval.eval_depth_max) return null;
        e.env.depth += 1;
        defer e.env.depth -= 1;
        const i = r.toIndex() orelse return null;
        const data = e.vir().instructions.items(.data)[@backingInt(i)];
        const own = (try e.typeOf(r)) orelse return null;
        if (own.real) {
            const c = (try e.env.ref(r)) orelse return null;
            return e.fit(try e.fromInt(c.asIntExact() orelse @intFromFloat(@round(c.asReal())), 64, true), t);
        }
        const tg = e.tag(i);
        switch (tg) {
            .int => return e.fit(try e.fromInt(@bitCast(data.int), own.width, true), t),
            .big_int => return e.fit((try e.bigInt(i)) orelse return null, t),
            .str => return e.fit(try e.string(e.vir().string_bytes[@backingInt(data.str.start)..][0..data.str.len]), t),
            .decl_ref => return e.fit((try e.declValue(data.decl_tok.decl)) orelse return null, t),
            .pos => return e.ctx(data.un_node.operand, t),
            .neg => return try ((try e.ctx(data.un_node.operand, t)) orelse return null).negate(e.a),
            .bit_not => return try ((try e.ctx(data.un_node.operand, t)) orelse return null).bitwiseNot(e.a),
            .not => {
                const x = (try e.self(data.un_node.operand)) orelse return null;
                return e.fit(try e.bit(switch (x.truth()) {
                    .zero => .one,
                    .one => .zero,
                    else => .x, // else: an unknown truth stays unknown
                }), t);
            },
            .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor => {
                const x = (try e.self(data.un_node.operand)) orelse return null;
                const op: kernels.Integer.Reduction = switch (tg) {
                    .red_and => .and_bits,
                    .red_nand => .nand_bits,
                    .red_or => .or_bits,
                    .red_nor => .nor_bits,
                    .red_xor => .xor_bits,
                    else => .xnor_bits, // else: the sixth reduction
                };
                return e.fit(try e.bit(x.reduce(op)), t);
            },
            .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => {
                const b = e.payload(Inst.Bin, i);
                const x = (try e.ctx(b.lhs, t)) orelse return null;
                const y = (try e.ctx(b.rhs, t)) orelse return null;
                return switch (tg) {
                    .add => try x.arithmetic(e.a, .add, y),
                    .sub => try x.arithmetic(e.a, .subtract, y),
                    .mul => try x.arithmetic(e.a, .multiply, y),
                    .div => try x.arithmetic(e.a, .divide, y),
                    .mod => try x.arithmetic(e.a, .remainder, y),
                    .bit_and => try x.bitwise(e.a, .and_bits, y),
                    .bit_or => try x.bitwise(e.a, .or_bits, y),
                    .bit_xor => try x.bitwise(e.a, .xor_bits, y),
                    else => try x.bitwise(e.a, .xnor_bits, y), // else: `~^`
                };
            },
            .shl, .shr, .ashl, .ashr, .pow => {
                const b = e.payload(Inst.Bin, i);
                const x = (try e.ctx(b.lhs, t)) orelse return null;
                const y = (try e.self(b.rhs)) orelse return null;
                return switch (tg) {
                    .shl => try x.shift(e.a, .left, y),
                    .shr => try x.shift(e.a, .right, y),
                    .ashl => try x.shift(e.a, .arithmetic_left, y),
                    .ashr => try x.shift(e.a, .arithmetic_right, y),
                    else => try x.power(e.a, y), // else: `**`
                };
            },
            .lt, .gt, .lte, .gte, .eq, .neq, .case_eq, .case_neq => {
                const b = e.payload(Inst.Bin, i);
                const ot = common((try e.typeOf(b.lhs)) orelse return null, (try e.typeOf(b.rhs)) orelse return null);
                const x = (try e.ctx(b.lhs, ot)) orelse return null;
                const y = (try e.ctx(b.rhs, ot)) orelse return null;
                const out: Bit = switch (tg) {
                    .lt => x.relational(.less, y),
                    .lte => x.relational(.less_equal, y),
                    .gt => x.relational(.greater, y),
                    .gte => x.relational(.greater_equal, y),
                    .eq => x.equality(.equal, y),
                    .neq => x.equality(.not_equal, y),
                    .case_eq => x.equality(.case_equal, y),
                    else => x.equality(.case_not_equal, y), // else: `!==`
                };
                return e.fit(try e.bit(out), t);
            },
            .bool_and, .bool_or => {
                const b = e.payload(Inst.Bin, i);
                const x = (try e.self(b.lhs)) orelse return null;
                const y = (try e.self(b.rhs)) orelse return null;
                return e.fit(try e.bit(x.logical(if (tg == .bool_and) .and_bits else .or_bits, y)), t);
            },
            .ternary => {
                const tr = e.payload(Inst.Triple, i);
                const c = (try e.self(tr.a)) orelse return null;
                return switch (c.truth()) {
                    .one => e.ctx(tr.b, t),
                    .zero => e.ctx(tr.c, t),
                    else => try c.conditional(e.a, (try e.ctx(tr.b, t)) orelse return null, (try e.ctx(tr.c, t)) orelse return null),
                };
            },
            .mintypmax => return e.ctx(e.payload(Inst.Triple, i).b, t),
            .concat => {
                var parts: std.ArrayList(Lit) = .empty;
                for (e.vir().list(Inst.Ref, e.payload(Inst.Refs, i))) |x| {
                    const xt = (try e.typeOf(x)) orelse return null;
                    if (xt.width == 0) continue;
                    try parts.append(e.a, (try e.self(x)) orelse return null);
                }
                const out = Lit.concatenate(e.a, parts.items) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else null;
                return e.fit(out, t);
            },
            .replicate => {
                const b = e.payload(Inst.Bin, i);
                const n = (try e.count(b.lhs)) orelse return null;
                const x = (try e.self(b.rhs)) orelse return null;
                const out = x.replicate(e.a, n) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else null;
                return e.fit(out, t);
            },
            .elem, .slice, .slice_up, .slice_down => {
                const s = (try e.select(i)) orelse return null;
                const out = try e.alloc(s.width, false);
                for (0..s.width) |k| {
                    const at = s.first + @as(i64, @intCast(k));
                    setBit(out, @intCast(k), if (at < 0 or at >= s.base.width) .x else s.base.bit(@intCast(at)));
                }
                return e.fit(out, t);
            },
            .call => return e.fit((try fun.call(e, i)) orelse return null, t),
            .call_sys => {
                const c = e.payload(Inst.SysCall, i);
                const name = e.vir().string(c.name);
                const args = e.vir().list(Inst.Ref, c.args);
                if ((std.mem.eql(u8, name, "$signed") or std.mem.eql(u8, name, "$unsigned")) and args.len == 1) {
                    var x = (try e.self(args[0])) orelse return null;
                    x.signed = own.signed;
                    return e.fit(x, t);
                }
                const c2 = (try e.env.ref(r)) orelse return null;
                return e.fit(try e.fromInt(c2.asIntExact() orelse return null, 32, true), t);
            },
            else => return null, // else: `typeOf` gave the rest no type
        }
    }

    /// `r`'s value as an exact integer (an index, a bound, a count).
    pub fn intOf(e: *Eval, r: Inst.Ref) Allocator.Error!?i64 {
        const t = (try e.typeOf(r)) orelse return null;
        if (t.real) return if (try e.env.ref(r)) |c| c.asIntExact() else null;
        return ((try e.ctx(r, t)) orelse return null).asExactInt();
    }

    pub fn self(e: *Eval, r: Inst.Ref) Allocator.Error!?Lit {
        const t = (try e.typeOf(r)) orelse return null;
        return e.ctx(r, t);
    }

    /// A non-negative replication count.
    pub fn count(e: *Eval, r: Inst.Ref) Allocator.Error!?u32 {
        const v = (try e.self(r)) orelse return null;
        const n = v.asIndex() orelse return null;
        return std.math.cast(u32, n);
    }

    /// `v` extended (by `t`'s signedness) or truncated to `t`'s width.
    pub fn fit(e: *Eval, v: Lit, t: Type) Allocator.Error!?Lit {
        var out = v.resize(e.a, t.width, if (t.signed and v.signed) .sign else .zero) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else null;
        out.signed = t.signed;
        return out;
    }

    pub fn alloc(e: *Eval, width: u32, signed: bool) Allocator.Error!Lit {
        const n = (width + 63) / 64;
        const planes = try e.a.alloc(u64, 2 * n);
        @memset(planes, 0);
        return .{ .width = width, .sized = true, .signed = signed, .planes = planes };
    }

    pub fn fromInt(e: *Eval, v: i64, width: u32, signed: bool) Allocator.Error!Lit {
        const out = try e.alloc(width, signed);
        for (0..width) |k| setBit(out, @intCast(k), if (k < 64) (if ((@as(u64, @bitCast(v)) >> @intCast(k)) & 1 == 1) .one else .zero) else if (v < 0) .one else .zero);
        return out;
    }

    pub fn bit(e: *Eval, b: Bit) Allocator.Error!Lit {
        const out = try e.alloc(1, false);
        setBit(out, 0, b);
        return out;
    }

    /// §3.6 a string's characters, eight bits each, the last in the low byte.
    pub fn string(e: *Eval, s: []const u8) Allocator.Error!Lit {
        const out = try e.alloc(@intCast(@max(1, s.len) * 8), false);
        for (s, 0..) |ch, k| {
            const at = (s.len - 1 - k) * 8;
            for (0..8) |b| setBit(out, @intCast(at + b), if ((ch >> @intCast(b)) & 1 == 1) .one else .zero);
        }
        return out;
    }

    /// §3.5.1 a sized or based literal: its text read by `kernels.Integer`,
    /// an unsized one at least 32 bits (its digits' bits when wider).
    pub fn bigInt(e: *Eval, i: Inst.Index) Allocator.Error!?Lit {
        const b = e.payload(Inst.BigInt, i);
        const digits = e.vir().string(b.digits);
        const radix: u8 = switch (b.flags.radix) {
            2 => 'b',
            8 => 'o',
            16 => 'h',
            else => 'd',
        };
        const s: []const u8 = if (b.flags.signed) "s" else "";
        const text = if (b.size != 0) try std.fmt.allocPrint(e.a, "{d}'{s}{c}{s}", .{ b.size, s, radix, digits }) else try std.fmt.allocPrint(e.a, "'{s}{c}{s}", .{ s, radix, digits });
        const lit = kernels.Integer.parse(e.a, text) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else null;
        if (b.size != 0) return lit;
        const per: u32 = switch (b.flags.radix) {
            2 => 1,
            8 => 3,
            16 => 4,
            else => 0,
        };
        const width = @max(32, per * @as(u32, @intCast(digits.len)));
        // §3.5.1 an unsized x or z digit fills the width.
        const top = lit.bit(lit.width - 1);
        var out = lit.resize(e.a, width, if (top == .x or top == .z or lit.signed) .sign else .zero) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else null;
        out.signed = lit.signed;
        return out;
    }

    /// The type of the name declaration `d` reads.
    pub fn declType(e: *Eval, d: Inst.Index) Allocator.Error!?Type {
        if (e.frame) |fr| if (fr.types.get(d)) |t| return t;
        return switch (e.tag(d)) {
            .genvar => .{ .width = 32, .signed = true },
            .param => blk: {
                const p = e.payload(Inst.Param, d);
                if (p.dims.len != 0) return null;
                if (p.range.len != 0) break :blk try e.rangeType(p.range, p.flags.signed);
                break :blk switch (p.flags.storage) {
                    .integer => .{ .width = 32, .signed = true },
                    .time => .{ .width = 64, .signed = false },
                    .real, .realtime => .{ .width = 64, .signed = true, .real = true },
                    .string => null,
                    // §12.2 "the type of the final value assigned": the
                    // default's own, while the value is still the default's.
                    .none, .reg => if (try e.defaultType(d, p)) |t| t else if (try e.env.param(d)) |c| switch (c) {
                        .real => .{ .width = 64, .signed = true, .real = true },
                        .int => |v| .{ .width = if (std.math.cast(i32, v) != null) 32 else 64, .signed = true },
                        .str => |s| .{ .width = @intCast(@max(1, s.len) * 8), .signed = false },
                    } else blk2: {
                        const b = e.vir().body(p.value);
                        if (b.len == 0) return null;
                        const t = (try e.typeOf(b[b.len - 1].toRef())) orelse return null;
                        break :blk2 .{ .width = t.width, .signed = t.signed or p.flags.signed, .real = t.real };
                    },
                };
            },
            else => null, // else: a net, variable or scope has no elaboration value
        };
    }

    /// Untyped parameter `d`'s default's integral type when its folded
    /// value is the default's value (no override changed it), else null.
    fn defaultType(e: *Eval, d: Inst.Index, p: Inst.Param) Allocator.Error!?Type {
        const b = e.vir().body(p.value);
        if (b.len == 0) return null;
        const t = (try e.typeOf(b[b.len - 1].toRef())) orelse return null;
        if (t.real) return null;
        const c = (try e.env.param(d)) orelse return null;
        if (c != .int) return null;
        const own = (try e.self(b[b.len - 1].toRef())) orelse return null;
        const v = own.asExactInt() orelse return null;
        if (v != c.int) return null;
        return .{ .width = t.width, .signed = t.signed or p.flags.signed };
    }

    /// The value the name declaration `d` reads, in its type.
    pub fn declValue(e: *Eval, d: Inst.Index) Allocator.Error!?Lit {
        if (e.frame) |fr| if (fr.vars.get(d)) |v| return v;
        const t = (try e.declType(d)) orelse return null;
        if (t.real) return null;
        switch (e.tag(d)) {
            .genvar => return if (e.env.genvars.get(d)) |v| try e.fromInt(v, 32, true) else null,
            .param => {
                if (try e.env.param(d)) |c| return switch (c) {
                    .int => |v| try e.fromInt(v, t.width, t.signed),
                    .str => |s| e.fit(try e.string(s), t),
                    .real => null,
                };
                // §12.2 a value the VAMS mode does not hold: its default.
                const p = e.payload(Inst.Param, d);
                const b = e.vir().body(p.value);
                if (b.len == 0) return null;
                const raw = (try e.self(b[b.len - 1].toRef())) orelse return null;
                return e.fit(raw, t);
            },
            else => return null, // else: `declType` typed nothing else
        }
    }

    pub fn rangeType(e: *Eval, range: Vir.Body, signed: bool) Allocator.Error!?Type {
        const r = e.vir().body(range);
        const bin = e.payload(Inst.Bin, r[r.len - 1]);
        const msb = (try e.intOf(bin.lhs)) orelse return null;
        const lsb = (try e.intOf(bin.rhs)) orelse return null;
        const w = std.math.cast(u32, @abs(@as(i128, msb) - lsb) + 1) orelse return null;
        return .{ .width = w, .signed = signed };
    }

    /// A constant select of a parameter or a constant function's variable:
    /// its value, the first bit position it reads, and its width.
    pub fn select(e: *Eval, i: Inst.Index) Allocator.Error!?struct { base: Lit, first: i64, width: u32 } {
        const tg = e.tag(i);
        const base_ref = if (tg == .elem) e.payload(Inst.Bin, i).lhs else e.payload(Inst.Triple, i).a;
        const bi = base_ref.toIndex() orelse return null;
        if (e.tag(bi) != .decl_ref) return null;
        const d = e.vir().instructions.items(.data)[@backingInt(bi)].decl_tok.decl;
        const base = (try e.declValue(d)) orelse return null;
        // The declared range: a parameter's or a variable's, else [w-1:0].
        var msb: i64 = @as(i64, base.width) - 1;
        var lsb: i64 = 0;
        if (try e.declRange(d)) |rg| {
            msb = rg[0];
            lsb = rg[1];
        }
        const asc = msb >= lsb;
        const pos = struct {
            fn of(index: i64, m: i64, l_: i64, ascending: bool) i64 {
                _ = m;
                return if (ascending) index - l_ else l_ - index;
            }
        }.of;
        switch (tg) {
            .elem => {
                const idx = (try e.intOf(e.payload(Inst.Bin, i).rhs)) orelse return null;
                return .{ .base = base, .first = pos(idx, msb, lsb, asc), .width = 1 };
            },
            .slice => {
                const t = e.payload(Inst.Triple, i);
                const m = (try e.intOf(t.b)) orelse return null;
                const l_ = (try e.intOf(t.c)) orelse return null;
                const w = std.math.cast(u32, @abs(@as(i128, m) - l_) + 1) orelse return null;
                return .{ .base = base, .first = @min(pos(m, msb, lsb, asc), pos(l_, msb, lsb, asc)), .width = w };
            },
            else => {
                const t = e.payload(Inst.Triple, i);
                const start = (try e.intOf(t.b)) orelse return null;
                const w = std.math.cast(u32, (try e.intOf(t.c)) orelse return null) orelse return null;
                if (w == 0) return null;
                const end = if (tg == .slice_up) start + w - 1 else start - @as(i64, w) + 1;
                return .{ .base = base, .first = @min(pos(start, msb, lsb, asc), pos(end, msb, lsb, asc)), .width = w };
            },
        }
    }

    pub fn declRange(e: *Eval, d: Inst.Index) Allocator.Error!?[2]i64 {
        const range: Vir.Body = switch (e.tag(d)) {
            .param => e.payload(Inst.Param, d).range,
            .variable => e.payload(Inst.Variable, d).range,
            .io => e.payload(Inst.Io, d).range,
            .function => e.payload(Inst.Function, d).range,
            else => return null, // else: a genvar has no declared range
        };
        if (range.len == 0) return null;
        const r = e.vir().body(range);
        const bin = e.payload(Inst.Bin, r[r.len - 1]);
        return .{ (try e.intOf(bin.lhs)) orelse return null, (try e.intOf(bin.rhs)) orelse return null };
    }

    /// The function call `i` names, or null for none of this module's.
    pub fn callee(e: *Eval, i: Inst.Index) ?Inst.Index {
        const c = e.payload(Inst.Call, i);
        const ci = c.callee.toIndex() orelse return null;
        if (e.tag(ci) != .decl_ref) return null;
        const f = e.vir().instructions.items(.data)[@backingInt(ci)].decl_tok.decl;
        if (e.tag(f) != .function) return null;
        const fp = e.payload(Inst.Function, f);
        return if (fp.flags.task or fp.flags.analog) null else f;
    }

    /// The type of a variable, formal or function result declared by
    /// `range`, `storage` and `signed`.
    pub fn varType(e: *Eval, range: Vir.Body, storage: Inst.Storage, signed: bool) Allocator.Error!?Type {
        if (range.len != 0) return e.rangeType(range, signed);
        return switch (storage) {
            .integer => .{ .width = 32, .signed = true },
            .time => .{ .width = 64, .signed = false },
            .real, .realtime => .{ .width = 64, .signed = true, .real = true },
            .string => null,
            .none, .reg => .{ .width = 1, .signed = signed },
        };
    }

    pub fn resultType(e: *Eval, f: Inst.Index) Allocator.Error!?Type {
        const fp = e.payload(Inst.Function, f);
        return e.varType(fp.range, fp.flags.storage, fp.flags.signed);
    }
};

pub fn common(a: Type, b: Type) Type {
    if (a.real or b.real) return .{ .width = 64, .signed = true, .real = true };
    return .{ .width = @max(a.width, b.width), .signed = a.signed and b.signed };
}

pub fn setBit(l: Lit, k: u32, b: Bit) void {
    assert(k < l.width);
    const n = l.planes.len / 2;
    const mask = @as(u64, 1) << @intCast(k % 64);
    const v = &l.planes[k / 64];
    const u = &l.planes[n + k / 64];
    const code = @backingInt(b);
    if (code & 1 == 1) v.* |= mask else v.* &= ~mask;
    if (code & 2 == 2) u.* |= mask else u.* &= ~mask;
}

/// The `Value` of `r`, self-determined, or null when it has none.
pub fn value(env: *Env, r: Inst.Ref) Allocator.Error!?Value {
    var e: Eval = .{ .env = env, .a = env.arena };
    const t = (try e.typeOf(r)) orelse return null;
    if (t.real) return if (try env.ref(r)) |c| .{ .real = c.asReal() } else null;
    return if (try e.ctx(r, t)) |v| .{ .int = v } else null;
}

/// `r`'s value as an integer: a real rounded, an integral value exactly
/// (no x or z bit, within i64). Null otherwise.
pub fn int(env: *Env, r: Inst.Ref) Allocator.Error!?i64 {
    const v = (try value(env, r)) orelse return null;
    return switch (v) {
        .int => |l| l.asExactInt(),
        .real => |x| if (std.math.isFinite(x) and @abs(x) < 9.2e18) @intFromFloat(@round(x)) else null,
    };
}
