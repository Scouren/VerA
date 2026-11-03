//! A concrete interpreter over structured Air: the arguments and probe
//! values in, the main body's `ret` value out. Each tag is implemented here
//! with `std.math`, the Zig builtins and plain arithmetic, as the device
//! computes it at run time, sharing no code with Sema's folds or the old
//! `kernels.fold`: `zig build diff-air` holds the two against each other.
//! A §3.2 `integer` is carried in an `i64`, as the device carries it; `+ -
//! * /`, unary `-`, `abs`, `**` and `<<` keep §3.2's 32 bits.
//! Cites: VAMS-2023 §3.2, §3.2.2, §4.2.1.1, §4.2.1.2, §4.2.4, §4.2.5,
//! §4.2.7-§4.2.12, §4.3.1 (Table 4-14), §4.3.2 (Table 4-15), §4.4, §5.7;
//! IEEE 1364-2005 §5.1.5 (Table 5-6).
//!
//! Contents:
//! - `pub const Value = union(enum) { int: i64, real: f64, array: []Value }`
//! - `pub const Inputs = struct`
//! - `pub const Error = error{ NoValue, LoopCap, Unsupported, OutOfMemory }`
//! - `pub fn run(scratch: Allocator, air: Air, ip: *const InternPool, inputs: Inputs) Error!Value`

const std = @import("std");
const math = std.math;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const InternPool = @import("intern_pool");
const Air = @import("../Air.zig");
const Inst = Air.Inst;

/// A value of a §3.2 `integer` or `real`, or a §3.2.2 array version.
pub const Value = union(enum) { int: i64, real: f64, array: []Value };

/// What one run reads.
pub const Inputs = struct {
    /// One per `arg` index, of the `arg`'s type.
    args: []const Value = &.{},
    /// One per §4.4 solver unknown a `probe` reads.
    probes: []const f64 = &.{},
    /// Most `repeat`s the whole run may take before `error.LoopCap`.
    loop_cap: u32,
};

/// Why a run has no value.
pub const Error = error{
    /// An operation with no value at its operands: an integer `/` or `%`, or
    /// a real `%`, by zero (§4.2.4); `0 ** n` for n < 0 (IEEE 1364-2005
    /// Table 5-6's 'bx); a shift count outside 0..63 (the old fold declines
    /// it); a read of an undefined constant.
    NoValue,
    /// The run took more than `Inputs.loop_cap` `repeat`s.
    LoopCap,
    /// A `call`, `path_prev` or `path_acc`: its value is the simulator's.
    Unsupported,
    OutOfMemory,
};

/// How a body was left.
const Exit = union(enum) { br: Inst.Index, repeat: Inst.Index, ret };

const Run = struct {
    air: Air,
    ip: *const InternPool,
    inputs: Inputs,
    scratch: Allocator,
    /// One per instruction: its result, or an `alloc`'s current slot value.
    vals: []Value,
    repeats: u32 = 0,
    result: Value = undefined,

    fn body(r: *Run, insts: []const Inst.Index, depth: u32) Error!Exit {
        assert(depth <= Air.nesting_max);
        assert(insts.len != 0);
        for (insts) |inst| {
            const i = @backingInt(inst);
            const data = r.air.instructions.items(.data)[i];
            switch (r.air.instructions.items(.tag)[i]) {
                .block => {
                    const x = r.air.extraData(Air.Block, data.ty_pl.payload);
                    const exit = try r.body(r.air.body(x.end, x.data.body_len), depth + 1);
                    if (exit != .br or exit.br != inst) return exit;
                },
                .loop => {
                    const x = r.air.extraData(Air.Block, data.ty_pl.payload);
                    while (true) {
                        const exit = try r.body(r.air.body(x.end, x.data.body_len), depth + 1);
                        if (exit != .repeat or exit.repeat != inst) return exit;
                        r.repeats += 1;
                        if (r.repeats > r.inputs.loop_cap) return error.LoopCap;
                    }
                },
                .cond_br => {
                    const x = r.air.extraData(Air.CondBr, data.pl_op.payload);
                    const taken = if ((try r.get(data.pl_op.operand)).int != 0)
                        r.air.body(x.end, x.data.then_body_len)
                    else
                        r.air.body(x.end + x.data.then_body_len, x.data.else_body_len);
                    return r.body(taken, depth + 1);
                },
                .br => {
                    if (data.br.operand != .none) r.vals[@backingInt(data.br.block_inst)] = try r.get(data.br.operand);
                    return .{ .br = data.br.block_inst };
                },
                .repeat => return .{ .repeat = data.repeat.loop_inst },
                .ret => {
                    r.result = try r.get(data.un_op);
                    return .ret;
                },
                .assign => r.vals[@backingInt(data.bin_op.lhs.toIndex().?)] = try r.get(data.bin_op.rhs),
                else => |tag| r.vals[i] = try r.value(tag, data),
            }
        }
        unreachable; // a well-formed body ends in a noreturn tag
    }

    /// Returns the result of a tag that does not change control flow.
    fn value(r: *Run, tag: Inst.Tag, data: Inst.Data) Error!Value {
        return switch (tag) {
            .arg => blk: {
                const v = r.inputs.args[data.ty_index.index];
                assert((v == .int) == (data.ty_index.ty == InternPool.Index.integer_type));
                break :blk v;
            },
            .probe => .{ .real = r.inputs.probes[data.ty_index.index] },
            .alloc => zeroOf(r, data.ty),
            .load => r.vals[@backingInt(data.un_op.toIndex().?)],
            .select => blk: {
                const bin = r.air.extraData(Air.Bin, data.pl_op.payload).data;
                break :blk r.get(if ((try r.get(data.pl_op.operand)).int != 0) bin.lhs else bin.rhs);
            },
            .anew => zeroOf(r, data.ty_pl.ty),
            .fload, .iload => blk: {
                const arr = (try r.get(data.bin_op.lhs)).array;
                const k = (try r.get(data.bin_op.rhs)).int;
                if (k >= 0 and k < arr.len) break :blk arr[@intCast(k)];
                break :blk if (tag == .iload) Value{ .int = 0 } else Value{ .real = 0 };
            },
            .store => blk: {
                const bin = r.air.extraData(Air.Bin, data.pl_op.payload).data;
                const arr = try r.scratch.dupe(Value, (try r.get(data.pl_op.operand)).array);
                const k = (try r.get(bin.lhs)).int;
                if (k >= 0 and k < arr.len) arr[@intCast(k)] = try r.get(bin.rhs);
                break :blk .{ .array = arr };
            },
            .call, .path_prev, .path_acc => error.Unsupported,
            else => switch (Air.tag_info.getPtrConst(tag).class) {
                .un_op => unary(tag, try r.get(data.un_op)),
                .bin_op => binary(tag, try r.get(data.bin_op.lhs), try r.get(data.bin_op.rhs)),
                .pl_op, .ty_pl, .ty, .ty_index, .br, .repeat => unreachable, // each has its prong above or in `body`
            },
        };
    }

    /// Returns the value `ref` reads.
    fn get(r: *const Run, ref: Inst.Ref) Error!Value {
        if (ref.toIndex()) |i| return r.vals[@backingInt(i)];
        return switch (r.ip.indexToKey(ref.toInterned().?)) {
            .float => |f| .{ .real = f },
            .int => |int| switch (int.storage) {
                .small => |v| .{ .int = v },
                .big => error.Unsupported,
            },
            .undef => error.NoValue,
            .str => error.Unsupported,
            .simple_type, .int_type, .array_type, .nature, .discipline => unreachable, // Verify: an operand is a value
        };
    }
};

/// Builds the bodies the tests below run.
const Test = struct {
    gpa: Allocator,
    ip: InternPool,
    b: Air.Builder,

    fn init(gpa: Allocator) !Test {
        return .{ .gpa = gpa, .ip = try .init(gpa), .b = try .init(gpa) };
    }
    fn deinit(t: *Test) void {
        t.b.deinit(t.gpa);
        t.ip.deinit(t.gpa);
    }
    fn arg(t: *Test, ty: InternPool.Index, index: u32) !Inst.Index {
        return t.b.addInst(t.gpa, .{ .tag = .arg, .data = .{ .ty_index = .{ .ty = ty, .index = index } } });
    }
    fn alloc(t: *Test, ty: InternPool.Index) !Inst.Index {
        return t.b.addInst(t.gpa, .{ .tag = .alloc, .data = .{ .ty = ty } });
    }
    fn control(t: *Test, tag: Inst.Tag) !Inst.Index {
        return t.b.addInst(t.gpa, .{ .tag = tag, .data = undefined });
    }
    fn br(t: *Test, block: Inst.Index, operand: Inst.Ref) !Inst.Index {
        return t.b.addInst(t.gpa, .{ .tag = .br, .data = .{ .br = .{ .block_inst = block, .operand = operand } } });
    }
    fn repeat(t: *Test, loop: Inst.Index) !Inst.Index {
        return t.b.addInst(t.gpa, .{ .tag = .repeat, .data = .{ .repeat = .{ .loop_inst = loop } } });
    }
    fn real(t: *Test, x: f64) !Inst.Ref {
        return .fromIntern(try t.ip.get(t.gpa, .{ .float = x }));
    }
    /// Finishes, verifies and runs the body for each input set.
    fn runAll(t: *Test, main: []const Inst.Index, inputs: []const Inputs, out: []Value) !void {
        var air = try t.b.finish(t.gpa, main);
        defer air.deinit(t.gpa);
        try std.testing.expectEqual(@as(?Air.Verify.Violation, null), try Air.Verify.verify(t.gpa, air, &t.ip));
        var arena: std.heap.ArenaAllocator = .init(t.gpa);
        defer arena.deinit();
        for (inputs, out) |in, *o| o.* = try run(arena.allocator(), air, &t.ip, in);
    }
};

/// Returns the value the main body's `ret` yields over `inputs`. Allocates
/// from `scratch` and leaves the allocations to its owner (an arena).
/// Asserts that `air` is well formed (`Air.Verify`) and `inputs` gives
/// every `arg` and `probe` it reads a value of its type.
pub fn run(scratch: Allocator, air: Air, ip: *const InternPool, inputs: Inputs) Error!Value {
    var r: Run = .{ .air = air, .ip = ip, .inputs = inputs, .scratch = scratch, .vals = try scratch.alloc(Value, air.instructions.len) };
    const exit = try r.body(air.mainBody(), 0);
    assert(exit == .ret);
    assert(r.repeats <= inputs.loop_cap);
    return r.result;
}

// ---- private ----

/// A slot or array of type `ty` before any write: §3.2's zero.
fn zeroOf(r: *Run, ty: InternPool.Index) Error!Value {
    return switch (r.ip.indexToKey(ty)) {
        .array_type => |a| blk: {
            const arr = try r.scratch.alloc(Value, a.len);
            for (arr) |*e| e.* = try zeroOf(r, a.elem);
            break :blk .{ .array = arr };
        },
        .simple_type => |s| switch (s) {
            .real => .{ .real = 0 },
            .integer => .{ .int = 0 },
            .string => error.Unsupported,
        },
        .int_type => .{ .int = 0 },
        .nature, .discipline, .undef, .float, .int, .str => unreachable, // Verify: a slot's type is a type
    };
}

fn unary(tag: Inst.Tag, a: Value) Error!Value {
    if (tag == .opt_barrier or tag == .dstop) return a;
    if (Air.tag_info.getPtrConst(tag).operand.? == .int) {
        const x = a.int;
        return .{
            .int = switch (tag) {
                .ineg => w32(0 -% x),
                .lognot => @intFromBool(x == 0),
                .bitnot => ~x,
                .iabs => w32(if (x < 0) 0 -% x else x),
                .if_cast => return .{ .real = @floatFromInt(x) },
                else => unreachable, // the int unary tags are listed
            },
        };
    }
    const x = a.real;
    return .{
        .real = switch (tag) {
            .fneg => -x,
            .sqrt => @sqrt(x),
            .exp => @exp(x),
            .expm1 => math.expm1(x),
            .ln => @log(x),
            .ln1p => math.log1p(x),
            .log10 => log10(x),
            .floor => @floor(x),
            .ceil => @ceil(x),
            .fabs => @abs(x),
            .sin => @sin(x),
            .cos => @cos(x),
            .tan => @tan(x),
            .asin => math.asin(x),
            .acos => math.acos(x),
            .atan => math.atan(x),
            .sinh => math.sinh(x),
            .cosh => math.cosh(x),
            .tanh => math.tanh(x),
            .asinh => math.asinh(x),
            // `std.math.acosh` answers a finite number for x <= -2 (it reads
            // |x|'s exponent); Table 4-15 gives x < 1 no value, IEEE NaN.
            .acosh => if (x < 1) math.nan(f64) else math.acosh(x),
            .atanh => math.atanh(x),
            .fi_cast => return .{ .int = roundToInt(x) },
            else => unreachable, // the real unary tags are listed
        },
    };
}

fn binary(tag: Inst.Tag, a: Value, b: Value) Error!Value {
    if (Air.tag_info.getPtrConst(tag).operand.? == .int) return .{ .int = try intBinary(tag, a.int, b.int) };
    const x = a.real;
    const y = b.real;
    return switch (tag) {
        .flt => .{ .int = @intFromBool(x < y) },
        .fgt => .{ .int = @intFromBool(x > y) },
        .fle => .{ .int = @intFromBool(x <= y) },
        .fge => .{ .int = @intFromBool(x >= y) },
        .feq => .{ .int = @intFromBool(x == y) },
        .fne => .{ .int = @intFromBool(x != y) },
        else => .{
            .real = switch (tag) {
                .fadd => x + y,
                .fsub => x - y,
                .fmul => x * y,
                .fdiv => x / y,
                .fmod => if (y == 0) return error.NoValue else @rem(x, y),
                .pow => pow(x, y),
                .hypot => math.hypot(x, y),
                // §4.3.1: "min(x,y) is equivalent to (x < y) ? x : y".
                .fmin => if (x < y) x else y,
                .fmax => if (x > y) x else y,
                .atan2 => math.atan2(x, y),
                else => unreachable, // the real binary tags are listed
            },
        },
    };
}

fn intBinary(tag: Inst.Tag, x: i64, y: i64) Error!i64 {
    return switch (tag) {
        .iadd => w32(x +% y),
        .isub => w32(x -% y),
        .imul => w32(x *% y),
        // In i65: minInt(i64) / -1 does not trap before the 32-bit wrap.
        .idiv => if (y == 0) error.NoValue else w32(@truncate(@divTrunc(@as(i65, x), y))),
        .imod => if (y == 0) error.NoValue else @intCast(@rem(@as(i65, x), y)),
        .ilt => @intFromBool(x < y),
        .igt => @intFromBool(x > y),
        .ile => @intFromBool(x <= y),
        .ige => @intFromBool(x >= y),
        .ieq => @intFromBool(x == y),
        .ine => @intFromBool(x != y),
        .logand => @intFromBool(x != 0 and y != 0),
        .logor => @intFromBool(x != 0 or y != 0),
        .bitand => x & y,
        .bitor => x | y,
        .bitxor => x ^ y,
        .bitxnor => ~(x ^ y),
        .imin => @min(x, y),
        .imax => @max(x, y),
        .ipow => ipow(x, y),
        .shl, .shr => if (y < 0 or y > 63) error.NoValue else shift(tag, x, @intCast(y)),
        else => unreachable, // the int binary tags are listed
    };
}

/// x^y: `std.math.pow`'s special cases (C99 F.10.4.4), and for a finite
/// nonzero x and a finite y the magnitude in f128: `std.math.pow` is off by
/// hundreds of ulps on a huge or tiny result (diff-air found it against
/// `contract.gm.pow`, and a 60-digit model agreed with the fold).
fn pow(x: f64, y: f64) f64 {
    const r = math.pow(f64, x, y);
    if (!math.isFinite(x) or x == 0 or !math.isFinite(y)) return r;
    const int_y = @floor(y) == y;
    if (x < 0 and !int_y) return r; // NaN: a negative base under a fraction
    const mag: f64 = @floatCast(@exp(@as(f128, y) * @log(@as(f128, @abs(x)))));
    const odd = int_y and @abs(y) < 0x1p53 and @mod(y, 2) != 0;
    return if (x < 0 and odd) -mag else mag;
}

/// log10(x). `@log10` is off by up to 1e-10 relative on a subnormal
/// (diff-air found it against `contract.gm.log10` and Python's
/// `math.log10`), so a subnormal is scaled into the normal range first.
fn log10(x: f64) f64 {
    if (x > 0 and x < math.floatMin(f64)) return @log10(x * 0x1p54) - 16.25561976585498454154190031512262316; // 54·log10(2)
    return @log10(x);
}

/// §3.2: the low 32 bits, sign-extended.
fn w32(x: i64) i64 {
    return @as(i32, @truncate(x));
}

/// §4.2.11 at §3.2's 32 bits; a count of 0 keeps `x` whole, as the device's
/// `zShr` does.
fn shift(tag: Inst.Tag, x: i64, n: u6) i64 {
    if (n >= 32) return 0;
    const lo: u32 = @truncate(@as(u64, @bitCast(x)));
    if (tag == .shl) return @as(i32, @bitCast(lo << @as(u5, @intCast(n))));
    if (n == 0) return x;
    return lo >> @as(u5, @intCast(n));
}

/// IEEE 1364-2005 Table 5-6 at 32 bits.
fn ipow(base: i64, n: i64) Error!i64 {
    if (n < 0) return switch (base) {
        0 => error.NoValue,
        1 => 1,
        -1 => if (@mod(n, 2) == 0) 1 else -1,
        else => 0, // else: |base| > 1 truncates to 0
    };
    var b: u32 = @truncate(@as(u64, @bitCast(base)));
    var e: u64 = @intCast(n);
    var p: u32 = 1;
    var bits: u32 = 0;
    while (e != 0) : (e >>= 1) {
        bits += 1;
        assert(bits <= 64);
        if (e & 1 != 0) p *%= b;
        b *%= b;
    }
    return @as(i32, @bitCast(p));
}

/// §4.2.1.1: nearest, ties away from zero; saturating; NaN is 0.
fn roundToInt(x: f64) i64 {
    if (math.isNan(x)) return 0;
    const r = @round(x);
    if (r >= 0x1p63) return math.maxInt(i64);
    if (r < -0x1p63) return math.minInt(i64);
    return @intFromFloat(r);
}

test "run: a loop carries two slots and an if/else merges two slots" {
    // The case slots exist for. Oracle: a closed form per input, computed
    // apart from the body. For n >= 0:
    //   s = 0; k = 0;  while (k < n) { k = k + 1; s = s + k; }   -> s = n(n+1)/2, k = n
    //   if (n % 2 == 0) { a = s; b = k; } else { a = k; b = -s; }
    //   ret a * 1000 + b
    const gpa = std.testing.allocator;
    var t = try Test.init(gpa);
    defer t.deinit();
    const b = &t.b;
    const n = try t.arg(.integer_type, 0);
    const s = try t.alloc(.integer_type);
    const k = try t.alloc(.integer_type);
    // while (k < n) { k = k + 1; s = s + k; }
    const out = try t.control(.block);
    const lp = try t.control(.loop);
    const k0 = try b.addUnOp(gpa, .load, .fromIndex(k));
    const go = try b.addBinOp(gpa, .ilt, .fromIndex(k0), .fromIndex(n));
    const k1 = try b.addBinOp(gpa, .iadd, .fromIndex(k0), .fromIntern(.one));
    const set_k = try b.addBinOp(gpa, .assign, .fromIndex(k), .fromIndex(k1));
    const s0 = try b.addUnOp(gpa, .load, .fromIndex(s));
    const s1 = try b.addBinOp(gpa, .iadd, .fromIndex(s0), .fromIndex(k1));
    const set_s = try b.addBinOp(gpa, .assign, .fromIndex(s), .fromIndex(s1));
    const again = try t.repeat(lp);
    const done = try t.br(out, .none);
    const step = try b.addCondBr(gpa, .fromIndex(go), &.{ k1, set_k, s0, s1, set_s, again }, &.{done});
    try b.setBody(gpa, lp, .none, &.{ k0, go, step });
    try b.setBody(gpa, out, .none, &.{lp});
    // if (n % 2 == 0) { a = s; b = k; } else { a = k; b = -s; }
    const sa = try t.alloc(.integer_type);
    const sb = try t.alloc(.integer_type);
    const merge = try t.control(.block);
    const two = Inst.Ref.fromIntern(try t.ip.get(gpa, .{ .int = .{ .ty = .integer_type, .storage = .{ .small = 2 } } }));
    const rem = try b.addBinOp(gpa, .imod, .fromIndex(n), two);
    const even = try b.addBinOp(gpa, .ieq, .fromIndex(rem), .fromIntern(.zero));
    const ts = try b.addUnOp(gpa, .load, .fromIndex(s));
    const tk = try b.addUnOp(gpa, .load, .fromIndex(k));
    const ta = try b.addBinOp(gpa, .assign, .fromIndex(sa), .fromIndex(ts));
    const tb = try b.addBinOp(gpa, .assign, .fromIndex(sb), .fromIndex(tk));
    const tbr = try t.br(merge, .none);
    const es = try b.addUnOp(gpa, .load, .fromIndex(s));
    const ek = try b.addUnOp(gpa, .load, .fromIndex(k));
    const neg = try b.addUnOp(gpa, .ineg, .fromIndex(es));
    const ea = try b.addBinOp(gpa, .assign, .fromIndex(sa), .fromIndex(ek));
    const eb = try b.addBinOp(gpa, .assign, .fromIndex(sb), .fromIndex(neg));
    const ebr = try t.br(merge, .none);
    const cb = try b.addCondBr(gpa, .fromIndex(even), &.{ ts, tk, ta, tb, tbr }, &.{ es, ek, neg, ea, eb, ebr });
    try b.setBody(gpa, merge, .none, &.{ rem, even, cb });
    const ra = try b.addUnOp(gpa, .load, .fromIndex(sa));
    const rb = try b.addUnOp(gpa, .load, .fromIndex(sb));
    const thousand = Inst.Ref.fromIntern(try t.ip.get(gpa, .{ .int = .{ .ty = .integer_type, .storage = .{ .small = 1000 } } }));
    const hi = try b.addBinOp(gpa, .imul, .fromIndex(ra), thousand);
    const sum = try b.addBinOp(gpa, .iadd, .fromIndex(hi), .fromIndex(rb));
    const ret = try b.addUnOp(gpa, .ret, .fromIndex(sum));

    var inputs: [12]Inputs = undefined;
    var args: [12]Value = undefined;
    for (&inputs, &args, 0..) |*in, *a, i| {
        a.* = .{ .int = @intCast(i) };
        in.* = .{ .args = a[0..1], .loop_cap = 100 };
    }
    var got: [12]Value = undefined;
    try t.runAll(&.{ n, s, k, out, sa, sb, merge, ra, rb, hi, sum, ret }, &inputs, &got);
    for (got, 0..) |g, i| {
        const nn: i64 = @intCast(i);
        const tri = @divExact(nn * (nn + 1), 2);
        const want = if (@mod(nn, 2) == 0) tri * 1000 + nn else nn * 1000 - tri;
        try std.testing.expectEqual(want, g.int);
    }
}

test "run: the loop cap stops a loop that never leaves" {
    const gpa = std.testing.allocator;
    var t = try Test.init(gpa);
    defer t.deinit();
    const lp = try t.control(.loop);
    try t.b.setBody(gpa, lp, .none, &.{try t.repeat(lp)});
    var air = try t.b.finish(gpa, &.{lp});
    defer air.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try std.testing.expectError(error.LoopCap, run(arena.allocator(), air, &t.ip, .{ .loop_cap = 50 }));
}

test "run: an array version, a store and loads in and out of range" {
    // §3.2.2: a fresh version is zero; a store makes a new version and
    // leaves the old one as it was; an index outside 0..len reads zero.
    const gpa = std.testing.allocator;
    var t = try Test.init(gpa);
    defer t.deinit();
    const b = &t.b;
    const arr_ty = try t.ip.get(gpa, .{ .array_type = .{ .len = 3, .elem = .real_type } });
    const v0 = try b.addInst(gpa, .{ .tag = .anew, .data = .{ .ty_pl = .{ .ty = arr_ty, .payload = 0 } } });
    const v1 = try b.addInst(gpa, .{ .tag = .store, .data = .{ .pl_op = .{
        .operand = .fromIndex(v0),
        .payload = try b.addExtra(gpa, Air.Bin{ .lhs = .fromIntern(.one), .rhs = try t.real(2.5) }),
    } } });
    const at1 = try b.addBinOp(gpa, .fload, .fromIndex(v1), .fromIntern(.one));
    const out = try b.addBinOp(gpa, .fload, .fromIndex(v1), .fromIntern(.neg_one));
    const sum = try b.addBinOp(gpa, .fadd, .fromIndex(at1), .fromIndex(out));
    const ret = try b.addUnOp(gpa, .ret, .fromIndex(sum));
    var got: [1]Value = undefined;
    try t.runAll(&.{ v0, v1, at1, out, sum, ret }, &.{.{ .loop_cap = 0 }}, &got);
    try std.testing.expectEqual(@as(f64, 2.5), got[0].real);
}
