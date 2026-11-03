//! The analog IR Sema writes and every later stage reads (Zig's
//! `src/Air.zig`): one instruction table and one `extra` pool per analysed
//! body, structured. An instruction's index is its value (`Inst.Ref`);
//! constants and types are `InternPool` indexes. Control flow nests, so
//! dominance is nesting: `block` (a body left by `br` with the block's
//! result), `cond_br` (two bodies), `loop` (a body re-entered by `repeat`),
//! `select` (a value-level if). No CFG and no phis: a variable is a slot,
//! `alloc`ed, `load`ed and `assign`ed, as Zig's locals are.
//!
//! The invariants a pass may rely on (`Air/Verify.zig` checks each, in
//! Debug, after every producer):
//! - every body ends with exactly one `noreturn` instruction (`br`,
//!   `repeat`, `cond_br`, `ret`), and holds no other;
//! - every instruction sits in exactly one body;
//! - an operand is an interned value, or an instruction defined earlier in
//!   the same body or in an enclosing one; a value never leaves its body
//!   except as a `br` operand;
//! - `br` leaves an enclosing `block`, with an operand of the block's type
//!   (`.none` for a block with no result); `repeat` names an enclosing `loop`;
//! - `load` and `assign` name an `alloc` defined earlier in the same or an
//!   enclosing body, and nothing else names an `alloc`; `assign` writes a
//!   value of the slot's type and has no result;
//! - every value operand has the type `tag_info` gives it; bodies nest at
//!   most `nesting_max` deep.
//!
//! Cites: VAMS-2023 §3.2, §3.2.2, §4.2 (Tables 4-1..4-3), §4.3 (Tables 4-14,
//! 4-15), §4.2.1.1, §4.2.1.2, §4.4, §5.6.1.2, §5.7, §5.8, §5.9; IEEE
//! 1364-2005 §5.1.5.
//!
//! Contents:
//! - `pub const print`, `pub const Verify`, `pub const interp`: the files under `Air/`
//! - `pub const Inst = struct` (`Index`, `Ref` (`fromIndex`, `fromIntern`, `toIndex`, `toInterned`), `Tag`, `Data`)
//! - `pub const ExtraIndex = enum(u32)`
//! - `pub const Block`, `pub const CondBr`, `pub const Bin`, `pub const Call`: the `extra` payloads
//! - `pub const Class`, `pub const Scalar`, `pub const Domain`, `pub const Relation`, `pub const Info`
//! - `pub const tag_info: std.EnumArray(Inst.Tag, Info)`
//! - `pub const nesting_max: u32`
//! - `pub const Builder = struct` (`init`, `deinit`, `addInst`, `addUnOp`, `addBinOp`,
//!   `addCondBr`, `setBody`, `addExtra`, `addPayloadBody`, `finish`)
//! - `pub fn deinit(air: *Air, gpa: Allocator) void`
//! - `pub fn extraData(air: Air, comptime T: type, at: u32) struct { data: T, end: u32 }`
//! - `pub fn body(air: Air, at: u32, len: u32) []const Inst.Index`
//! - `pub fn mainBody(air: Air) []const Inst.Index`
//! - `pub fn typeOf(air: Air, ip: *const InternPool, ref: Inst.Ref) InternPool.Index`
//! - `pub fn typeOfIndex(air: Air, ip: *const InternPool, inst: Inst.Index) InternPool.Index`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const InternPool = @import("intern_pool");
/// A readable text dump of a body.
pub const print = @import("Air/print.zig");
/// The well-formedness checker.
pub const Verify = @import("Air/Verify.zig");
/// The concrete interpreter.
pub const interp = @import("Air/interp.zig");

/// One row per instruction; `Inst.Index` `i` is row `i`.
instructions: std.MultiArrayList(Inst).Slice,
/// The payloads `Inst.Data` points at; word 0 is `ExtraIndex.main_block`.
extra: []const u32,

/// One instruction: a tag and its 8-byte payload.
pub const Inst = struct {
    tag: Tag,
    data: Data,

    /// A row of `instructions`.
    pub const Index = enum(u32) { _ };

    /// An operand: an interned value (high bit clear) or an instruction's
    /// result (high bit set). `none` is the absent operand.
    pub const Ref = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        /// Returns the operand that reads instruction `i`'s result.
        pub fn fromIndex(i: Index) Ref {
            assert(@backingInt(i) < ref_bit - 1);
            return @fromBackingInt(@backingInt(i) | ref_bit);
        }
        /// Returns the operand that reads the interned `index`; `.none`
        /// gives `.none`. Asserts that `index` is below `InternPool.items_max`.
        pub fn fromIntern(index: InternPool.Index) Ref {
            if (index == .none) return .none;
            assert(@backingInt(index) < ref_bit);
            return @fromBackingInt(@backingInt(index));
        }
        /// Returns the instruction `r` reads, or null for a constant or `.none`.
        pub fn toIndex(r: Ref) ?Index {
            if (r == .none or @backingInt(r) & ref_bit == 0) return null;
            return @fromBackingInt(@backingInt(r) & ~ref_bit);
        }
        /// Returns the interned index `r` reads, or null for an instruction
        /// or `.none`.
        pub fn toInterned(r: Ref) ?InternPool.Index {
            if (r == .none or @backingInt(r) & ref_bit != 0) return null;
            return @fromBackingInt(@backingInt(r));
        }

        const ref_bit: u32 = 1 << 31;
    };

    /// What an instruction does; `tag_info` holds its facts and names the
    /// `Data` field it reads (`Info.class`). A leading `f` is the real form,
    /// a leading `i` the integer form; math carries the LRM name.
    pub const Tag = enum(u8) {
        // §4.2.4 arithmetic: `bin_op` / `un_op`.
        fadd,
        fsub,
        fmul,
        fdiv,
        fmod,
        fneg,
        iadd,
        isub,
        imul,
        idiv,
        imod,
        ineg,
        // §4.2.5/§4.2.7 comparisons, integer 0/1: `bin_op`.
        flt,
        fgt,
        fle,
        fge,
        feq,
        fne,
        ilt,
        igt,
        ile,
        ige,
        ieq,
        ine,
        // §4.2.8 logical, over integer 0/1 operands.
        logand,
        logor,
        lognot,
        // §4.2.9 bitwise and §4.2.11 shifts, integer.
        bitand,
        bitor,
        bitxor,
        bitxnor,
        bitnot,
        shl,
        shr,
        // §4.3.1 Table 4-14.
        sqrt,
        exp,
        expm1,
        ln,
        ln1p,
        log10,
        pow,
        hypot,
        floor,
        ceil,
        fabs,
        fmin,
        fmax,
        iabs,
        imin,
        imax,
        /// §4.2.1.3 `**` over two integers (IEEE 1364-2005 Table 5-6, 32 bits).
        ipow,
        // §4.3.2 Table 4-15.
        sin,
        cos,
        tan,
        asin,
        acos,
        atan,
        atan2,
        sinh,
        cosh,
        tanh,
        asinh,
        acosh,
        atanh,
        /// §4.2.1.1 real → integer, rounding ties away from zero, saturating, NaN → 0.
        fi_cast,
        /// §4.2.1.2 integer → real.
        if_cast,
        /// Optimization fence: the operand, unchanged; codegen does not
        /// fold or reassociate across it.
        opt_barrier,
        /// Derivative stop (`vera_nodiff`, §2.9): the operand's value with
        /// every derivative lane zero.
        dstop,
        /// §5.6.1.2: the operand's value at the last accepted solve.
        path_prev,
        /// §5.6.1.2: the sum of the operand's values over accepted solves.
        path_acc,
        /// §4.2.12 `?:` as a value: `pl_op`, operand the integer condition,
        /// payload a `Bin` (then, else).
        select,
        /// §3.2.2 a fresh array version, every element zero: `ty_pl`, `ty`
        /// the array type, payload the memory array's id.
        anew,
        /// Element `rhs` of array version `lhs` (`bin_op`); an index outside
        /// the array reads the element type's zero.
        fload,
        iload,
        /// Array version `operand` with one element set: `pl_op`, payload a
        /// `Bin` (index, value); an index outside the array writes nothing.
        /// A version is dead once a store was made from it.
        store,
        /// A system or user call: `ty_pl`, `ty` the result type (`.none`
        /// for a task), payload a `Call` and its argument `Ref`s.
        call,
        /// The `index`th parameter (`ty_index`).
        arg,
        /// §4.4 a read of solver unknown `index` (`ty_index`, `ty` real).
        probe,
        /// A variable's slot (`ty`: the value type). Its `Ref` is read only
        /// by `load` and `assign`.
        alloc,
        /// The slot's current value (`un_op`, the `alloc`).
        load,
        /// §5.7 writes `rhs` to slot `lhs` (`bin_op`); no result.
        assign,
        /// A body with a result (`ty_pl`: `ty` or `.none`, payload a `Block`).
        block,
        /// Leaves `block_inst` with `operand` (`br`). noreturn.
        br,
        /// Runs one of two bodies: `pl_op`, operand the integer condition,
        /// payload a `CondBr`. noreturn.
        cond_br,
        /// A body re-entered by `repeat`, left by `br` (`ty_pl`, `ty`
        /// `.none`, payload a `Block`). noreturn.
        loop,
        /// Re-enters `loop_inst` (`repeat`). noreturn.
        repeat,
        /// Leaves the analysed body with `operand` (`un_op`). noreturn.
        ret,
    };

    /// Every instruction has an 8-byte payload; `tag_info`'s `class` names
    /// the active field.
    pub const Data = union {
        un_op: Ref,
        bin_op: struct { lhs: Ref, rhs: Ref },
        pl_op: struct { operand: Ref, payload: u32 },
        ty_pl: struct { ty: InternPool.Index, payload: u32 },
        ty: InternPool.Index,
        ty_index: struct { ty: InternPool.Index, index: u32 },
        br: struct { block_inst: Index, operand: Ref },
        repeat: struct { loop_inst: Index },

        comptime {
            // Safety builds add a hidden tag (Zig's Air.zig does the same).
            if (!std.debug.runtime_safety) assert(@sizeOf(Data) == 8);
        }
    };
};

/// The reserved leading words of `extra`.
pub const ExtraIndex = enum(u32) {
    /// The offset of the main body's `Block`.
    main_block,
};

/// `body_len` instruction indexes follow.
pub const Block = struct { body_len: u32 };
/// The then body's indexes follow, then the else body's.
pub const CondBr = struct { then_body_len: u32, else_body_len: u32 };
/// Two operands.
pub const Bin = struct { lhs: Inst.Ref, rhs: Inst.Ref };
/// `args_len` operand `Ref`s follow. `callee` is the old `src/ir/callee.zig`
/// `Callee`'s integer until `SysFn` exists.
pub const Call = struct { callee: u32, args_len: u32 };

/// The `Inst.Data` field a tag reads.
pub const Class = enum(u8) { un_op, bin_op, pl_op, ty_pl, ty, ty_index, br, repeat };
/// A §3.2 scalar type, the type of a value operand.
pub const Scalar = enum(u8) { real, int };
/// LRM Tables 4-14 / 4-15 domains. For a binary tag the obligation is on
/// the second operand (`nonzero_divisor`) or on both (`pow_sign`).
pub const Domain = enum(u8) {
    all,
    positive,
    gt_neg_one,
    non_negative,
    unit_closed,
    unit_open,
    ge_one,
    nonzero_divisor,
    tan_poles,
    pow_sign,
};
/// `lhs REL rhs` for the twelve comparisons.
pub const Relation = enum(u8) { lt, le, gt, ge, eq, ne };

/// One row of `tag_info` (`src/ir/opcode.zig`'s `Info` without `fold`:
/// folding is Sema's, and the interpreter must not share it).
pub const Info = struct {
    class: Class,
    /// The value operands' type; null where the tag has its own rule
    /// (`Verify` states each).
    operand: ?Scalar = null,
    /// The result is a §3.2 integer (a value tag; else real or own rule).
    int: bool = false,
    /// The result is 0 or 1.
    bool01: bool = false,
    /// A predicate the prover mines: the comparisons and `!`.
    predicate: bool = false,
    /// The relation a comparison tests.
    rel: ?Relation = null,
    /// The LRM domain obligation.
    domain: Domain = .all,
    /// The Table 4-14/4-15 spelling for diagnostics; null is the tag name.
    label: ?[]const u8 = null,
    /// The tag ends a body (`br`, `repeat`, `cond_br`, `loop`, `ret`).
    noreturn: bool = false,
};

/// Per-tag facts, total over `Inst.Tag`.
pub const tag_info = std.EnumArray(Inst.Tag, Info).init(.{
    .fadd = real2(.{}),
    .fsub = real2(.{}),
    .fmul = real2(.{}),
    .fdiv = real2(.{}),
    .fmod = real2(.{ .domain = .nonzero_divisor }),
    .fneg = real1(.{}),
    .iadd = int2(.{}),
    .isub = int2(.{}),
    .imul = int2(.{}),
    .idiv = int2(.{ .domain = .nonzero_divisor }),
    .imod = int2(.{ .domain = .nonzero_divisor }),
    .ineg = int1(.{}),
    .flt = cmp(.real, .lt),
    .fgt = cmp(.real, .gt),
    .fle = cmp(.real, .le),
    .fge = cmp(.real, .ge),
    .feq = cmp(.real, .eq),
    .fne = cmp(.real, .ne),
    .ilt = cmp(.int, .lt),
    .igt = cmp(.int, .gt),
    .ile = cmp(.int, .le),
    .ige = cmp(.int, .ge),
    .ieq = cmp(.int, .eq),
    .ine = cmp(.int, .ne),
    .logand = int2(.{ .bool01 = true }),
    .logor = int2(.{ .bool01 = true }),
    .lognot = int1(.{ .bool01 = true, .predicate = true }),
    .bitand = int2(.{}),
    .bitor = int2(.{}),
    .bitxor = int2(.{}),
    .bitxnor = int2(.{}),
    .bitnot = int1(.{}),
    .shl = int2(.{}),
    .shr = int2(.{}),
    .sqrt = real1(.{ .domain = .non_negative, .label = "sqrt()" }),
    .exp = real1(.{}),
    .expm1 = real1(.{}),
    .ln = real1(.{ .domain = .positive, .label = "ln()" }),
    .ln1p = real1(.{ .domain = .gt_neg_one, .label = "ln1p()" }),
    .log10 = real1(.{ .domain = .positive, .label = "log()" }),
    .pow = real2(.{ .domain = .pow_sign, .label = "pow()" }),
    .hypot = real2(.{}),
    .floor = real1(.{}),
    .ceil = real1(.{}),
    .fabs = real1(.{}),
    .fmin = real2(.{}),
    .fmax = real2(.{}),
    .iabs = int1(.{}),
    .imin = int2(.{}),
    .imax = int2(.{}),
    .ipow = int2(.{ .domain = .pow_sign }),
    .sin = real1(.{}),
    .cos = real1(.{}),
    .tan = real1(.{ .domain = .tan_poles, .label = "tan()" }),
    .asin = real1(.{ .domain = .unit_closed, .label = "asin()" }),
    .acos = real1(.{ .domain = .unit_closed, .label = "acos()" }),
    .atan = real1(.{}),
    .atan2 = real2(.{}),
    .sinh = real1(.{}),
    .cosh = real1(.{}),
    .tanh = real1(.{}),
    .asinh = real1(.{}),
    .acosh = real1(.{ .domain = .ge_one, .label = "acosh()" }),
    .atanh = real1(.{ .domain = .unit_open, .label = "atanh()" }),
    .fi_cast = .{ .class = .un_op, .operand = .real, .int = true },
    .if_cast = .{ .class = .un_op, .operand = .int },
    .opt_barrier = .{ .class = .un_op },
    .dstop = .{ .class = .un_op },
    .path_prev = real1(.{}),
    .path_acc = real1(.{}),
    .select = .{ .class = .pl_op },
    .anew = .{ .class = .ty_pl },
    .fload = .{ .class = .bin_op },
    .iload = .{ .class = .bin_op, .int = true },
    .store = .{ .class = .pl_op },
    .call = .{ .class = .ty_pl },
    .arg = .{ .class = .ty_index },
    .probe = .{ .class = .ty_index },
    .alloc = .{ .class = .ty },
    .load = .{ .class = .un_op },
    .assign = .{ .class = .bin_op },
    .block = .{ .class = .ty_pl },
    .br = .{ .class = .br, .noreturn = true },
    .cond_br = .{ .class = .pl_op, .noreturn = true },
    .loop = .{ .class = .ty_pl, .noreturn = true },
    .repeat = .{ .class = .repeat, .noreturn = true },
    .ret = .{ .class = .un_op, .noreturn = true },
});

/// Most bodies nested inside one another: `Verify` checks it, and the
/// interpreter's recursion is bounded by it.
pub const nesting_max: u32 = 1024;

/// Appends instructions and payloads, then hands out the `Air`. Sema's
/// writer and the tests'. A `block`, `loop` or `cond_br` is added before
/// its body (a `br` names it), so its `data` is set once the body exists
/// (`setBody`).
pub const Builder = struct {
    instructions: std.MultiArrayList(Inst) = .empty,
    extra: std.ArrayList(u32) = .empty,

    /// Returns a builder with `extra`'s reserved words in place.
    pub fn init(gpa: Allocator) Allocator.Error!Builder {
        var b: Builder = .{};
        try b.extra.appendNTimes(gpa, 0, @typeInfo(ExtraIndex).@"enum".field_names.len);
        assert(b.extra.items.len == 1);
        return b;
    }
    /// Frees what `finish` has not handed out.
    pub fn deinit(b: *Builder, gpa: Allocator) void {
        b.instructions.deinit(gpa);
        b.extra.deinit(gpa);
        b.* = undefined;
    }
    /// Appends `inst` and returns its index.
    pub fn addInst(b: *Builder, gpa: Allocator, inst: Inst) Allocator.Error!Inst.Index {
        const i: u32 = @intCast(b.instructions.len);
        assert(i < Inst.Ref.ref_bit - 1);
        try b.instructions.append(gpa, inst);
        return @fromBackingInt(i);
    }
    /// Appends a `un_op` instruction.
    pub fn addUnOp(b: *Builder, gpa: Allocator, tag: Inst.Tag, operand: Inst.Ref) Allocator.Error!Inst.Index {
        assert(tag_info.getPtrConst(tag).class == .un_op);
        return b.addInst(gpa, .{ .tag = tag, .data = .{ .un_op = operand } });
    }
    /// Appends a `bin_op` instruction.
    pub fn addBinOp(b: *Builder, gpa: Allocator, tag: Inst.Tag, lhs: Inst.Ref, rhs: Inst.Ref) Allocator.Error!Inst.Index {
        assert(tag_info.getPtrConst(tag).class == .bin_op);
        return b.addInst(gpa, .{ .tag = tag, .data = .{ .bin_op = .{ .lhs = lhs, .rhs = rhs } } });
    }
    /// Appends a `cond_br` over two bodies already added.
    pub fn addCondBr(b: *Builder, gpa: Allocator, cond: Inst.Ref, then_body: []const Inst.Index, else_body: []const Inst.Index) Allocator.Error!Inst.Index {
        const header: CondBr = .{ .then_body_len = @intCast(then_body.len), .else_body_len = @intCast(else_body.len) };
        const at = try b.addPayloadBody(gpa, header, &.{ then_body, else_body });
        return b.addInst(gpa, .{ .tag = .cond_br, .data = .{ .pl_op = .{ .operand = cond, .payload = at } } });
    }
    /// Gives `block` or `loop` instruction `inst`, added earlier with
    /// undefined data, its result type and its body.
    pub fn setBody(b: *Builder, gpa: Allocator, inst: Inst.Index, ty: InternPool.Index, bd: []const Inst.Index) Allocator.Error!void {
        const tag = b.instructions.items(.tag)[@backingInt(inst)];
        assert(tag == .block or tag == .loop);
        if (tag == .loop) assert(ty == .none);
        const at = try b.addPayloadBody(gpa, Block{ .body_len = @intCast(bd.len) }, &.{bd});
        b.instructions.items(.data)[@backingInt(inst)] = .{ .ty_pl = .{ .ty = ty, .payload = at } };
    }
    /// Appends the `u32`/enum fields of `v` and returns their offset.
    pub fn addExtra(b: *Builder, gpa: Allocator, v: anytype) Allocator.Error!u32 {
        const names = @typeInfo(@TypeOf(v)).@"struct".field_names;
        const at: u32 = @intCast(b.extra.items.len);
        try b.extra.ensureUnusedCapacity(gpa, names.len);
        inline for (names) |name| {
            const x = @field(v, name);
            b.extra.appendAssumeCapacity(if (@typeInfo(@TypeOf(x)) == .@"enum") @backingInt(x) else x);
        }
        assert(b.extra.items.len == at + names.len);
        return at;
    }
    /// Appends `header` then each body's indexes, and returns the header's
    /// offset: the payload of a `block`, `loop` or `cond_br`.
    pub fn addPayloadBody(b: *Builder, gpa: Allocator, header: anytype, bodies: []const []const Inst.Index) Allocator.Error!u32 {
        const at = try b.addExtra(gpa, header);
        for (bodies) |bd| try b.extra.appendSlice(gpa, @ptrCast(bd));
        assert(b.extra.items.len >= at + bodies.len);
        return at;
    }
    /// Returns the `Air` whose main body is `main_body`; the builder is
    /// empty after, and the caller frees the `Air` with `deinit`.
    pub fn finish(b: *Builder, gpa: Allocator, main_body: []const Inst.Index) Allocator.Error!Air {
        assert(main_body.len != 0);
        const at = try b.addPayloadBody(gpa, Block{ .body_len = @intCast(main_body.len) }, &.{main_body});
        b.extra.items[@backingInt(ExtraIndex.main_block)] = at;
        const extra = try b.extra.toOwnedSlice(gpa);
        const air: Air = .{ .instructions = b.instructions.toOwnedSlice(), .extra = extra };
        b.instructions = .empty;
        assert(air.mainBody().len == main_body.len);
        return air;
    }
};

/// The facts a value tag's helper row takes beside its class and types.
const Facts = struct { bool01: bool = false, predicate: bool = false, domain: Domain = .all, label: ?[]const u8 = null };

const Air = @This();

/// Frees both tables.
pub fn deinit(air: *Air, gpa: Allocator) void {
    air.instructions.deinit(gpa);
    gpa.free(air.extra);
    air.* = undefined;
}

/// Returns the payload `T` at `extra[at..]` and the offset after it.
pub fn extraData(air: Air, comptime T: type, at: u32) struct { data: T, end: u32 } {
    const info = @typeInfo(T).@"struct";
    assert(at + info.field_names.len <= air.extra.len);
    var r: T = undefined;
    inline for (info.field_names, info.field_types, 0..) |name, F, i| {
        const w = air.extra[at + i];
        @field(r, name) = if (@typeInfo(F) == .@"enum") @fromBackingInt(w) else w;
    }
    return .{ .data = r, .end = at + @as(u32, @intCast(info.field_names.len)) };
}

/// Returns the `len` instruction indexes at `extra[at..]`.
pub fn body(air: Air, at: u32, len: u32) []const Inst.Index {
    assert(at + len <= air.extra.len);
    return @ptrCast(air.extra[at..][0..len]);
}

/// Returns the analysed body: what `interp.run` runs.
pub fn mainBody(air: Air) []const Inst.Index {
    const b = air.extraData(Block, air.extra[@backingInt(ExtraIndex.main_block)]);
    return air.body(b.end, b.data.body_len);
}

/// Returns the type of the value `ref` reads; `.none` for an instruction
/// with no result (`assign`, the noreturn tags, a task `call`).
pub fn typeOf(air: Air, ip: *const InternPool, ref: Inst.Ref) InternPool.Index {
    assert(ref != .none);
    if (ref.toInterned()) |index| return ip.typeOf(index);
    return air.typeOfIndex(ip, ref.toIndex().?);
}

/// Returns the type of instruction `inst`'s result (see `typeOf`); an
/// `alloc`'s is the type of the value its slot holds.
pub fn typeOfIndex(air: Air, ip: *const InternPool, inst: Inst.Index) InternPool.Index {
    const tag = air.instructions.items(.tag)[@backingInt(inst)];
    const data = air.instructions.items(.data)[@backingInt(inst)];
    const info = tag_info.getPtrConst(tag);
    if (info.noreturn) return .none;
    return switch (tag) {
        .opt_barrier, .dstop => air.typeOf(ip, data.un_op),
        .select => air.typeOf(ip, air.extraData(Bin, data.pl_op.payload).data.lhs),
        .store => air.typeOf(ip, data.pl_op.operand),
        .anew, .call, .block => data.ty_pl.ty,
        .arg, .probe => data.ty_index.ty,
        .alloc => data.ty,
        .load => air.typeOfIndex(ip, data.un_op.toIndex().?),
        .assign => .none,
        else => if (info.int) .integer_type else .real_type, // else: the value tags, typed by `int`
    };
}

// ---- private ----

fn real1(f: Facts) Info {
    return with(f, .un_op, .real, false);
}
fn real2(f: Facts) Info {
    return with(f, .bin_op, .real, false);
}
fn int1(f: Facts) Info {
    return with(f, .un_op, .int, true);
}
fn int2(f: Facts) Info {
    return with(f, .bin_op, .int, true);
}
fn cmp(operand: Scalar, rel: Relation) Info {
    return .{ .class = .bin_op, .operand = operand, .int = true, .bool01 = true, .predicate = true, .rel = rel };
}
fn with(f: Facts, class: Class, operand: Scalar, int: bool) Info {
    return .{ .class = class, .operand = operand, .int = int, .bool01 = f.bool01, .predicate = f.predicate, .domain = f.domain, .label = f.label };
}

// The facts every row must agree on, checked at build time: a 0/1 result
// is an integer, only a 0/1 result is a predicate, a relation is exactly a
// comparison, a label names a domain error, and the noreturn tags are the
// control tags.
comptime {
    @setEvalBranchQuota(20_000);
    assert(@sizeOf(Inst.Tag) == 1);
    for (std.enums.values(Inst.Tag)) |tag| {
        const info = tag_info.get(tag);
        if (info.bool01) assert(info.int);
        if (info.predicate) assert(info.bool01);
        assert((info.predicate and tag != .lognot) == (info.rel != null));
        if (info.label != null) assert(info.domain != .all);
        if (info.operand != null) assert(info.class == .un_op or info.class == .bin_op);
        const control = switch (tag) {
            .br, .cond_br, .loop, .repeat, .ret => true,
            else => false, // else: every value tag
        };
        assert(info.noreturn == control);
    }
}

test "Ref: an interned index and an instruction index round trip and never meet" {
    const i: Inst.Index = @fromBackingInt(7);
    const r = Inst.Ref.fromIndex(i);
    try std.testing.expectEqual(i, r.toIndex().?);
    try std.testing.expectEqual(@as(?InternPool.Index, null), r.toInterned());
    const c = Inst.Ref.fromIntern(InternPool.Index.one_real);
    try std.testing.expectEqual(InternPool.Index.one_real, c.toInterned().?);
    try std.testing.expectEqual(@as(?Inst.Index, null), c.toIndex());
    try std.testing.expectEqual(Inst.Ref.none, Inst.Ref.fromIntern(.none));
    try std.testing.expectEqual(@as(?Inst.Index, null), Inst.Ref.none.toIndex());
}

test {
    _ = print;
    _ = Verify;
    _ = interp;
}
