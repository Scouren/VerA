//! The comptime evaluator (Zig's `Sema.resolveConstValue`): one Vir
//! expression of one instance in, its folded value out, or null when it has
//! none at elaboration (a net, a variable, an x/z digit, a value wider than
//! 64 bits, a call no table folds). Every operator is `std_kernels.fold`'s,
//! whose §4.3 functions are the device's (Gompute), so a parameter folds
//! here as a device computes it. A parameter reads its given value (an override, a
//! defparam, a paramset statement) or its default, converted to its
//! declared type and range; a genvar reads its current value.
//! Cites: VAMS-2023 §2.6.1, §2.6.2, §2.7, §3.2, §3.4, §3.4.6, §4.2, §4.3
//! (Tables 4-14, 4-15), §6.6.1; IEEE 1364-2005 §4.10.1, §12.2, §17.11.1.
//!
//! Contents:
//! - `pub const Const`
//! - `pub const Env = struct` (`init`, `deinit`, `body`, `bodyValue`, `ref`, `param`, `named`, `systemNamed`, `toConst`, `intern`, `arraySize`, `dependsOn`)
//! - `pub const eval_depth_max: u32`
//! - `pub const v1364` (the IEEE 1364 mode: four-state values of any width, constant functions)
//! - `pub fn toInteger(c: Const) ?i64`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const fold = @import("std_kernels").fold;
const Zcu = @import("../Zcu.zig");
const sign = @import("sign.zig");
const sysfn = @import("eval_fn.zig");
/// The IEEE 1364 mode of this evaluator (`eval_1364.zig`): four-state
/// values of any width, sized as §5.4/§5.5 size them, and §10.4.5 constant
/// functions. The VAMS mode (`Env.ref`) is unchanged by it.
pub const v1364 = @import("eval_1364.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// A folded value: an integer, a real or a string (`std_kernels.fold.Const`).
pub const Const = fold.Const;

/// The deepest chain of parameter reads and nested expressions one
/// evaluation follows; past it the value is unfoldable. Reads that close a
/// cycle stop at their first repeat, long before it.
pub const eval_depth_max: u32 = 1 << 12;

/// One instance's evaluation state: which file its names are in, the
/// values its parameters are given, the module-level values folded so far
/// and the genvars bound now. Lives while the instance's body is walked.
pub const Env = struct {
    gpa: Allocator,
    /// Strings a value needs beyond the evaluation (`toConst`'s copies).
    arena: Allocator,
    ip: *InternPool,
    vir: *const Vir,
    /// The module-level parameters (header, then body), each with its
    /// position in `values`.
    positions: std.AutoArrayHashMapUnmanaged(Inst.Index, u32) = .empty,
    /// The module-level aliasparams (§3.4.6), in order.
    aliases: std.ArrayList(Inst.Index) = .empty,
    /// The folded value of each module-level parameter, `.none` until
    /// folded and `.undef` when it has no value.
    values: std.ArrayList(InternPool.Index) = .empty,
    /// A value from outside the declaration: an override, a defparam or a
    /// paramset statement. Wins over the declared default.
    given: std.AutoHashMapUnmanaged(Inst.Index, InternPool.Index) = .empty,
    /// The name each `given` value was given under (an alias's, or the
    /// parameter's own), for §3.4.7's E0908.
    spelling: std.AutoHashMapUnmanaged(Inst.Index, []const u8) = .empty,
    /// §6.6.1 the genvars the generate walk has bound.
    genvars: std.AutoHashMapUnmanaged(Inst.Index, i64) = .empty,
    /// Parameters being folded: a read of one of these closes a cycle.
    busy: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty,
    /// A read of a `busy` parameter happened (`dependsOn`).
    cycled: bool = false,
    /// §9.18 this instance's hierarchical system parameters, once known.
    hier: Zcu.Hier = .initFill(.undef),
    depth: u32 = 0,
    /// While nonzero, a parameter read is a §3.4 shape read (`shapes`).
    shaping: u32 = 0,
    /// The parameters a shape read (`shaping`), by declaration.
    shapes: std.AutoArrayHashMapUnmanaged(Inst.Index, void) = .empty,
    /// §6.4.1 a paramset's out-of-module `module.localparam` reads
    /// (C-P6/D2-M), keyed by the `field` instruction: `paramset.zig`
    /// resolves them before the body is evaluated, since only it (not
    /// `Env`) knows the design's module table.
    oomrs: std.AutoHashMapUnmanaged(Inst.Index, InternPool.Index) = .empty,

    /// An environment over `vir` whose module-level parameters are those of
    /// `params` (bodies holding `param` instructions, in order).
    pub fn init(gpa: Allocator, arena: Allocator, ip: *InternPool, vir: *const Vir, params: []const Vir.Body) Allocator.Error!Env {
        var env: Env = .{ .gpa = gpa, .arena = arena, .ip = ip, .vir = vir };
        errdefer env.deinit();
        const tags = vir.instructions.items(.tag);
        for (params) |b| for (vir.body(b)) |i| switch (tags[@backingInt(i)]) {
            .param => {
                try env.positions.put(gpa, i, @intCast(env.values.items.len));
                try env.values.append(gpa, .none);
            },
            .aliasparam => try env.aliases.append(gpa, i),
            else => {}, // else: only parameters and their aliases are named by a value
        };
        assert(env.positions.count() == env.values.items.len);
        return env;
    }

    pub fn deinit(env: *Env) void {
        assert(env.busy.count() == 0);
        env.positions.deinit(env.gpa);
        env.aliases.deinit(env.gpa);
        env.values.deinit(env.gpa);
        env.given.deinit(env.gpa);
        env.spelling.deinit(env.gpa);
        env.genvars.deinit(env.gpa);
        env.busy.deinit(env.gpa);
        // `oomrs` is put through `env.arena` (`paramset.zig`'s caller owns
        // it, usually `s.arena`): the same allocator frees it.
        env.oomrs.deinit(env.arena);
        env.* = undefined;
    }

    /// The value of a body: its last instruction's. Null for an empty body.
    pub fn body(env: *Env, b: Vir.Body) Allocator.Error!?Const {
        const depth = env.depth;
        defer assert(env.depth == depth);
        assert(b.start + b.len <= env.vir.extra.len);
        const insts = env.vir.body(b);
        if (insts.len == 0) return null;
        return env.ref(insts[insts.len - 1].toRef());
    }

    /// The value of a body as an interned constant: a §3.4.4 assignment
    /// pattern `'{...}` is an untyped aggregate of its elements' values, any
    /// other value as `intern`s, `undef` when it does not fold.
    pub fn bodyValue(env: *Env, b: Vir.Body) Allocator.Error!InternPool.Index {
        const insts = env.vir.body(b);
        if (insts.len == 0) return .undef;
        const last = insts[insts.len - 1];
        if (env.vir.instructions.items(.tag)[@backingInt(last)] != .pattern) {
            return if (try env.body(b)) |c| env.intern(c) else .undef;
        }
        const refs = env.vir.list(Inst.Ref, env.payload(Inst.Refs, last));
        const elems = try env.arena.alloc(InternPool.Index, refs.len);
        for (refs, elems) |r, *e| e.* = if (try env.ref(r)) |c| try env.intern(c) else .undef;
        const out = try env.ip.get(env.gpa, .{ .aggregate = .{ .ty = .none, .elems = elems } });
        assert(out != .none);
        return out;
    }

    /// §3.4.4 the element count of parameter `p`'s first (outermost)
    /// declared dimension: an assignment pattern's own length (a nested
    /// pattern holds the inner dimensions). Null for a scalar or a range
    /// that does not fold.
    /// ponytail: the inner dimensions' sizes are not judged.
    pub fn arraySize(env: *Env, p: Inst.Index) Allocator.Error!?u64 {
        const decl = env.payload(Inst.Param, p);
        if (decl.dims.len == 0) return null;
        const first = for (env.vir.body(decl.dims)) |d| {
            if (env.vir.instructions.items(.tag)[@backingInt(d)] == .range) break d;
        } else return null;
        const bin = env.payload(Inst.Bin, first);
        const msb = ((try env.ref(bin.lhs)) orelse return null).asIntExact() orelse return null;
        const lsb = ((try env.ref(bin.rhs)) orelse return null).asIntExact() orelse return null;
        const n: u64 = @intCast(@min(@abs(@as(i128, msb) - lsb) + 1, std.math.maxInt(u64)));
        assert(n >= 1);
        return n;
    }

    /// Whether folding `b` reads parameter `target`, directly or through
    /// the defaults of the parameters it reads: every cached value is
    /// folded again with `target` busy, then restored.
    pub fn dependsOn(env: *Env, b: Vir.Body, target: Inst.Index) Allocator.Error!bool {
        assert(env.vir.instructions.items(.tag)[@backingInt(target)] == .param);
        assert(!env.busy.contains(target));
        const saved = try env.arena.dupe(InternPool.Index, env.values.items);
        defer @memcpy(env.values.items, saved);
        @memset(env.values.items, .none);
        try env.busy.put(env.gpa, target, {});
        defer _ = env.busy.remove(target);
        env.cycled = false;
        _ = try env.body(b);
        defer env.cycled = false;
        return env.cycled;
    }

    /// The value of `r`, or null when it has none at elaboration.
    pub fn ref(env: *Env, r: Inst.Ref) Allocator.Error!?Const {
        const depth = env.depth;
        defer assert(env.depth == depth);
        const i = r.toIndex() orelse return null;
        if (env.depth >= eval_depth_max) return null;
        env.depth += 1;
        defer env.depth -= 1;
        return env.inst(i);
    }

    /// The folded value of parameter `p` (a `param` instruction), from its
    /// given value or its default, in its declared type and range.
    pub fn param(env: *Env, p: Inst.Index) Allocator.Error!?Const {
        assert(env.vir.instructions.items(.tag)[@backingInt(p)] == .param);
        if (env.shaping != 0) try env.shapes.put(env.arena, p, {});
        const pos = env.positions.get(p);
        if (pos) |k| if (env.values.items[k] != .none) return env.toConst(env.values.items[k]);
        if (env.busy.contains(p)) {
            env.cycled = true;
            return null;
        }
        try env.busy.put(env.gpa, p, {});
        defer _ = env.busy.remove(p);
        const decl = env.payload(Inst.Param, p);
        // §3.4.4 an array parameter's value is an aggregate: no `Const`.
        if (decl.dims.len != 0) {
            const v = env.given.get(p) orelse try env.bodyValue(decl.value);
            if (pos) |k| env.values.items[k] = v;
            return null;
        }
        const raw = if (env.given.get(p)) |g| env.toConst(g) else try env.body(decl.value);
        const v = if (raw) |c| try env.coerce(decl, c) else null;
        if (pos) |k| env.values.items[k] = if (v) |c| try env.intern(c) else .undef;
        return v;
    }

    /// The module-level parameter `name` names: a parameter of that name,
    /// or the original an aliasparam of that name reaches (§3.4.6). Null
    /// for no parameter, and for an alias of a §9.18 system parameter.
    pub fn named(env: *const Env, name: []const u8) ?Inst.Index {
        assert(name.len != 0);
        const vir = env.vir;
        for (env.positions.keys()) |p| if (std.mem.eql(u8, vir.string(env.payload(Inst.Param, p).name), name)) return p;
        for (env.aliases.items) |a| {
            if (!std.mem.eql(u8, vir.string(env.payload(Inst.Aliasparam, a).name), name)) continue;
            return originalOf(vir, a);
        }
        return null;
    }

    /// The §9.18 system parameter `name` names: its own spelling, or an
    /// aliasparam (a chain of them) of it. Null for any other name.
    pub fn systemNamed(env: *const Env, name: []const u8) ?Zcu.SystemParam {
        assert(name.len != 0);
        if (Zcu.SystemParam.fromName(name)) |k| return k;
        const vir = env.vir;
        var at = name;
        for (0..max_alias_chain) |_| {
            const a = for (env.aliases.items) |a| {
                if (std.mem.eql(u8, vir.string(env.payload(Inst.Aliasparam, a).name), at)) break env.payload(Inst.Aliasparam, a);
            } else return null;
            at = vir.string(a.target);
            if (Zcu.SystemParam.fromName(at)) |k| return k;
        }
        return null;
    }

    /// The value `index` holds, or null for `undef`. A string is copied, so
    /// it outlives the pool's next string.
    pub fn toConst(env: *Env, index: InternPool.Index) ?Const {
        assert(@backingInt(index) < env.ip.items.len);
        assert(index != .none);
        return switch (env.ip.indexToKey(index)) {
            .float => |f| .{ .real = f },
            .int => |int| switch (int.storage) {
                .small => |v| .{ .int = v },
                .big => null,
            },
            .str => |s| .{ .str = env.arena.dupe(u8, env.ip.stringToSlice(s)) catch return null },
            .undef, .aggregate => null,
            .simple_type, .int_type, .array_type, .nature, .discipline => unreachable, // a parameter holds a value
        };
    }

    /// Interns `c` as an `integer`, a `real` or a `string` constant.
    pub fn intern(env: *Env, c: Const) Allocator.Error!InternPool.Index {
        const index = try env.ip.get(env.gpa, switch (c) {
            .int => |v| .{ .int = .{ .ty = .integer_type, .storage = .{ .small = v } } },
            .real => |v| .{ .float = v },
            .str => |s| .{ .str = try env.ip.getString(env.gpa, s) },
        });
        assert(index != .none);
        return index;
    }

    // ---- private ----

    fn payload(env: *const Env, comptime T: type, i: Inst.Index) T {
        assert(Inst.dataKind(env.vir.instructions.items(.tag)[@backingInt(i)]) == .pl_node);
        return env.vir.extraData(T, env.vir.instructions.items(.data)[@backingInt(i)].pl_node.payload_index);
    }

    fn inst(env: *Env, i: Inst.Index) Allocator.Error!?Const {
        assert(@backingInt(i) < env.vir.instructions.len);
        assert(env.depth <= eval_depth_max);
        const vir = env.vir;
        const tag = vir.instructions.items(.tag)[@backingInt(i)];
        const data = vir.instructions.items(.data)[@backingInt(i)];
        return switch (tag) {
            .int => if (data.int <= std.math.maxInt(i64)) .{ .int = @intCast(data.int) } else null,
            .real => .{ .real = data.float },
            .str => .{ .str = vir.string_bytes[@backingInt(data.str.start)..][0..data.str.len] },
            .big_int => bigInt(vir, env.payload(Inst.BigInt, i)),
            .decl_ref => env.declValue(data.decl_tok.decl),
            .pos, .neg, .not, .bit_not => {
                const a = (try env.ref(data.un_node.operand)) orelse return null;
                return fold.unary(unaryOp(tag), a);
            },
            // §4.2.10 a reduction: a bitwise fold over the operand's own
            // width, which only a literal carries (I5).
            .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor => {
                const a = (try env.ref(data.un_node.operand)) orelse return null;
                return reduction(vir, tag, data.un_node.operand, a);
            },
            .add, .sub, .mul, .div, .mod, .pow, .shl, .shr, .ashl, .ashr, .lt, .gt, .lte, .gte, .eq, .neq, .case_eq, .case_neq, .bit_and, .bit_or, .bit_xor, .bit_xnor, .bool_and, .bool_or => {
                const b = env.payload(Inst.Bin, i);
                var x = (try env.ref(b.lhs)) orelse return null;
                var y = (try env.ref(b.rhs)) orelse return null;
                // §4.2.9 an unsigned operand makes a comparison unsigned
                // (I1), the same mask-and-flip plan the Air lowering's
                // `sign.compareOperands` applies.
                if (x == .int and y == .int) switch (tag) {
                    .lt, .gt, .lte, .gte, .eq, .neq, .case_eq, .case_neq => {
                        const xy = sign.compareConsts(vir, b.lhs, b.rhs, x.int, y.int);
                        x = .{ .int = xy[0] };
                        y = .{ .int = xy[1] };
                    },
                    else => {},
                };
                // IEEE 1364-2005 §5.1.12 `>>>` fills from the sign bit only
                // when the left operand is signed (I5); every other
                // operator ignores this.
                const lhs_signed = if (tag == .ashr) sign.signed(vir, b.lhs) else null;
                return fold.binary(binaryOp(tag), x, y, lhs_signed);
            },
            .ternary => {
                const t = env.payload(Inst.Triple, i);
                const c = (try env.ref(t.a)) orelse return null;
                return env.ref(if (c.isTrue()) t.b else t.c);
            },
            .mintypmax => env.ref(env.payload(Inst.Triple, i).b),
            .call_sys => sysfn.sysCall(env, env.payload(Inst.SysCall, i)),
            // §6.4.1 a paramset's out-of-module read of a different
            // module's local parameter (C-P6/D2-M): `paramset.zig` resolves
            // it into `oomrs` before the body runs; any other `field` (an
            // ordinary hierarchical read) is `hier.zig`'s, not foldable here.
            .field => if (env.oomrs.get(i)) |v| env.toConst(v) else null,
            // ponytail: selects, concatenations and constant functions do
            // not fold yet; each is an unfoldable value, which no fixture's
            // instance tree reads.
            .str_ref, .elem, .slice, .slice_up, .slice_down, .call, .concat, .pattern, .replicate, .pattern_repl, .port_branch => null,
            .module, .nature, .discipline, .paramset, .primitive, .connectrules, .config, .port, .io, .net, .variable, .param, .aliasparam, .genvar, .event, .branch, .instance, .assign, .defparam, .analog, .analog_initial, .initial, .always, .function, .gen_for, .gen_if, .gen_case, .gen_block, .specify, .path, .timing_check, .pulse_style, .timing_event, .ps_override, .connect_resolve, .connect_insert, .block, .condbr, .case, .loop, .repeat, .wait, .delay, .event_wait, .store, .store_nb, .contrib, .proc_assign, .force, .store_timed, .store_nb_timed, .contrib_indirect, .deassign, .release, .trigger, .disable, .ret, .brk, .cont, .delay_ctl, .event_ctl, .repeat_ctl, .event_or, .posedge, .negedge, .driver_update, .step_event, .paramset_output, .range, .pulse_limits => null,
        };
    }

    /// A name's value: a parameter's, a genvar's, or an alias's original's.
    fn declValue(env: *Env, d: Inst.Index) Allocator.Error!?Const {
        assert(env.depth <= eval_depth_max);
        assert(@backingInt(d) < env.vir.instructions.len);
        return switch (env.vir.instructions.items(.tag)[@backingInt(d)]) {
            .param => env.param(d),
            .genvar => if (env.genvars.get(d)) |v| .{ .int = v } else null,
            .aliasparam => if (originalOf(env.vir, d)) |p| env.param(p) else null,
            else => null, // else: a net, variable, port, function or scope has no elaboration value
        };
    }

    /// `c` in parameter `decl`'s declared type (§3.4: `real`, `integer`,
    /// `string`) and range (IEEE 1364-2005 §12.2: truncated to its width,
    /// signed only when declared so); an untyped parameter keeps its value's
    /// type.
    fn coerce(env: *Env, decl: Inst.Param, value: Const) Allocator.Error!?Const {
        assert(decl.name != .empty);
        // §2.7 a string given to a numeric parameter is its characters'
        // integer, eight bits each.
        const numeric = decl.range.len != 0 or (decl.flags.storage != .none and decl.flags.storage != .string);
        const c: Const = if (value == .str and numeric) .{ .int = fold.strToInt(value.str, 64) } else value;
        const typed: Const = switch (decl.flags.storage) {
            .real, .realtime => .{ .real = c.asReal() },
            // §4.2.1.1/§3.4.1 (I3/I4): an already-integer value wraps to
            // §3.2's 32 bits exactly; a real rounds and saturates there
            // instead of declining past `i64` (the old side keeps the
            // unrounded real, which is the bug `integer_conversion_saturates.va`
            // names: VerA's defined answer, where the LRM is silent, is
            // saturation, never a crash).
            .integer => .{ .int = fold.wrap32(toInteger(c) orelse return null) },
            .time => .{ .int = toInteger(c) orelse return null },
            .none, .reg, .string => c,
        };
        if (decl.range.len == 0) return typed;
        const r = env.vir.body(decl.range);
        const bin = env.payload(Inst.Bin, r[r.len - 1]);
        const msb = ((try env.ref(bin.lhs)) orelse return null).asIntExact() orelse return null;
        const lsb = ((try env.ref(bin.rhs)) orelse return null).asIntExact() orelse return null;
        const width: u128 = @abs(@as(i128, msb) - lsb) + 1;
        const v = typed.asIntExact() orelse return null;
        if (width >= 64) return .{ .int = v };
        const bits: u64 = @as(u64, @bitCast(v)) & ((@as(u64, 1) << @intCast(width)) - 1);
        const negative = decl.flags.signed and bits >> @intCast(width - 1) != 0;
        const out: i64 = if (negative) @bitCast(bits | ~((@as(u64, 1) << @intCast(width)) - 1)) else @intCast(bits);
        assert(negative == (out < 0));
        return .{ .int = out };
    }
};

/// The longest chain of aliasparams `originalOf` follows.
const max_alias_chain = 64;

/// §4.2.1.1/§3.4.1 (I3/I4): `c` as an integer, exact for an already-integer
/// value, rounded to nearest (ties away from zero) and saturated at the
/// 32-bit ceiling/floor for a real too large or small to hold (VerA's
/// defined answer where the LRM states only the rounding and is silent past
/// it: never UB, never a crash). Null for a NaN or an infinity, which no
/// literal folds to, and for a string.
pub fn toInteger(c: Const) ?i64 {
    return switch (c) {
        .int => |v| v,
        .real => |r| blk: {
            if (!std.math.isFinite(r)) break :blk null;
            const v = @round(r);
            if (v >= 2147483648.0) break :blk std.math.maxInt(i32);
            if (v <= -2147483649.0) break :blk std.math.minInt(i32);
            break :blk @intFromFloat(v);
        },
        .str => null,
    };
}

// ---- private ----

/// §4.2.10's reduction operators (IEEE 1364-2005 §5.1.11): "a bitwise
/// operation on a single operand to produce a single-bit result", so the
/// answer depends on the operand's width, which a folded `Const` does not
/// carry. Only a literal carries one; any other operand declines (the old
/// `lib/frontend/constfold.zig` `reduction`, ported literal for literal: §4.2.10
/// bars these operators from the analog block, not from a parameter default).
fn reduction(vir: *const Vir, tag: Inst.Tag, operand: Inst.Ref, a: Const) ?Const {
    if (a != .int) return null;
    const oi = operand.toIndex() orelse return null;
    const data = vir.instructions.items(.data)[@backingInt(oi)];
    const w: u32 = switch (vir.instructions.items(.tag)[@backingInt(oi)]) {
        .int => if (std.math.cast(i32, data.int) != null or std.math.cast(u32, data.int) != null) 32 else 64,
        .big_int => size: {
            const b = vir.extraData(Inst.BigInt, data.pl_node.payload_index);
            break :size if (b.size != 0) b.size else 32;
        },
        else => return null, // else: only a literal carries a width
    };
    if (w > 64) return null;
    const mask: u64 = if (w == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(w)) - 1;
    const bits: u64 = @as(u64, @bitCast(a.int)) & mask;
    const r = switch (tag) {
        .red_and => bits == mask,
        .red_nand => bits != mask,
        .red_or => bits != 0,
        .red_nor => bits == 0,
        .red_xor => @popCount(bits) % 2 == 1,
        .red_xnor => @popCount(bits) % 2 == 0,
        else => unreachable, // else: `inst` passes only the six reduction tags
    };
    return .{ .int = @intFromBool(r) };
}

/// The parameter a chain of aliasparams from `alias` reaches, or null (a
/// §9.18 system parameter, a name declared nowhere, a cycle).
fn originalOf(vir: *const Vir, alias: Inst.Index) ?Inst.Index {
    assert(vir.instructions.items(.tag)[@backingInt(alias)] == .aliasparam);
    const tags = vir.instructions.items(.tag);
    const data = vir.instructions.items(.data);
    var at = alias;
    for (0..max_alias_chain) |_| {
        const a = vir.extraData(Inst.Aliasparam, data[@backingInt(at)].pl_node.payload_index);
        const next = a.original.toIndex() orelse return null;
        switch (tags[@backingInt(next)]) {
            .param => return next,
            .aliasparam => at = next,
            else => return null, // else: an alias of a non-parameter is lowering's E0303/E0331
        }
    }
    return null;
}

fn unaryOp(tag: Inst.Tag) fold.UnaryOp {
    assert(Inst.dataKind(tag) == .un_node);
    return switch (tag) {
        .pos => .plus,
        .neg => .minus,
        .not => .logical_not,
        .bit_not => .bit_not,
        else => unreachable, // else: `inst` passes only the four tags above
    };
}

fn binaryOp(tag: Inst.Tag) fold.BinaryOp {
    assert(Inst.dataKind(tag) == .pl_node);
    return switch (tag) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .pow => .pow,
        .shl => .shl,
        .shr => .shr,
        .ashl => .ashl,
        .ashr => .ashr,
        .lt => .lt,
        .gt => .gt,
        .lte => .le,
        .gte => .ge,
        .eq => .eq,
        .neq => .neq,
        .case_eq => .case_eq,
        .case_neq => .case_neq,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        .bit_xnor => .bit_xnor,
        .bool_and => .logical_and,
        .bool_or => .logical_or,
        else => unreachable, // else: `inst` passes only the binary operator tags
    };
}

/// §2.6.1 a sized or based literal's value: its digits in its radix,
/// truncated to its size and sign-extended when signed. Null for an x, z or
/// `?` digit; a declared 64-bit size keeps its carrier's bit pattern
/// outright (I2), and past 64 bits (D1-F) so does a signed literal (two's
/// complement sign-extends consistently past any width) or an unsigned one
/// whose low 64 bits alone already hold it (bit 63 clear) — an unsigned
/// literal past 64 bits with bit 63 set is the one case the i64 carrier
/// cannot tell from a negative value, so it still declines.
fn bigInt(vir: *const Vir, b: Inst.BigInt) ?Const {
    assert(b.flags.radix != 0);
    assert(b.digits != .empty);
    const digits = vir.string(b.digits);
    const radix: u8 = b.flags.radix;
    if (radix != 2 and radix != 8 and radix != 10 and radix != 16) return null;
    var acc: u64 = 0;
    for (digits) |ch| {
        const d = std.fmt.charToDigit(ch, radix) catch return null;
        // D1-F: a literal needing more than 64 bits (`128'h...`) wraps
        // mod 2^64 instead of declining; `size` below still cuts a
        // narrower declared width down from this carrier.
        acc = acc *% @as(u64, radix) +% @as(u64, d);
    }
    const size: u32 = if (b.size == 0) 32 else b.size;
    if (size < 64) {
        acc &= (@as(u64, 1) << @intCast(size)) - 1;
        if (b.flags.signed and acc >> @intCast(size - 1) != 0) return .{ .int = @bitCast(acc | ~((@as(u64, 1) << @intCast(size)) - 1)) };
        return .{ .int = @intCast(acc) };
    }
    // I2: at exactly 64 bits the carrier's bit pattern is the value,
    // unsigned or signed alike (`reject_clog2_wide_unsigned_carrier.va`'s
    // neighbour `clog2_unsigned_width.va` folds `64'h8000000000000000`,
    // not just a signed literal: there is no wider i64 to decline into).
    if (size == 64) return .{ .int = @bitCast(acc) };
    // D1-F: past 64 bits, a signed literal's low 64 bits are always the
    // right truncation (two's complement sign-extends consistently, as
    // `clog2_unsigned_width.va`'s `128'shffff...ffff` relies on). An
    // unsigned literal whose low 64 bits alone fit (bit 63 clear) is the
    // same value with no ambiguity. Bit 63 set past 64 declared bits is
    // ambiguous between that bit pattern and a wider positive magnitude
    // the carrier cannot hold: decline, as `reject_clog2_wide_unsigned_carrier.va` requires.
    if (!b.flags.signed and acc >> 63 != 0) return null;
    return .{ .int = @bitCast(acc) };
}
