//! The comptime evaluator (Zig's `Sema.resolveConstValue`): one Vir
//! expression of one instance in, its folded value out, or null when it has
//! none at elaboration (a net, a variable, an x/z digit, a value wider than
//! 64 bits, a call no table folds). Every operator is `kernels.fold`'s, the
//! fold the old compiler's five folders share, so a parameter folds here as
//! a device computes it. A parameter reads its given value (an override, a
//! defparam, a paramset statement) or its default, converted to its
//! declared type and range; a genvar reads its current value.
//! Cites: VAMS-2023 §2.6.1, §2.6.2, §2.7, §3.2, §3.4, §3.4.6, §4.2, §4.3
//! (Tables 4-14, 4-15), §6.6.1; IEEE 1364-2005 §4.10.1, §12.2, §17.11.1.
//!
//! Contents:
//! - `pub const Const`
//! - `pub const Env = struct` (`init`, `deinit`, `body`, `ref`, `param`, `named`, `systemNamed`, `toConst`, `intern`)
//! - `pub const eval_depth_max: u32`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const fold = @import("kernels").fold;
const Zcu = @import("../Zcu.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// A folded value: an integer, a real or a string (`kernels.fold.Const`).
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
    /// §9.18 this instance's hierarchical system parameters, once known.
    hier: Zcu.Hier = .initFill(.undef),
    depth: u32 = 0,

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
        env.positions.deinit(env.gpa);
        env.aliases.deinit(env.gpa);
        env.values.deinit(env.gpa);
        env.given.deinit(env.gpa);
        env.spelling.deinit(env.gpa);
        env.genvars.deinit(env.gpa);
        env.busy.deinit(env.gpa);
        env.* = undefined;
    }

    /// The value of a body: its last instruction's. Null for an empty body.
    pub fn body(env: *Env, b: Vir.Body) Allocator.Error!?Const {
        assert(b.start + b.len <= env.vir.extra.len);
        const insts = env.vir.body(b);
        if (insts.len == 0) return null;
        return env.ref(insts[insts.len - 1].toRef());
    }

    /// The value of `r`, or null when it has none at elaboration.
    pub fn ref(env: *Env, r: Inst.Ref) Allocator.Error!?Const {
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
        const pos = env.positions.get(p);
        if (pos) |k| if (env.values.items[k] != .none) return env.toConst(env.values.items[k]);
        if (env.busy.contains(p)) return null;
        try env.busy.put(env.gpa, p, {});
        defer _ = env.busy.remove(p);
        const decl = env.payload(Inst.Param, p);
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
            .add, .sub, .mul, .div, .mod, .pow, .shl, .shr, .ashl, .ashr, .lt, .gt, .lte, .gte, .eq, .neq, .case_eq, .case_neq, .bit_and, .bit_or, .bit_xor, .bit_xnor, .bool_and, .bool_or => {
                const b = env.payload(Inst.Bin, i);
                const x = (try env.ref(b.lhs)) orelse return null;
                const y = (try env.ref(b.rhs)) orelse return null;
                return fold.binary(binaryOp(tag), x, y, null);
            },
            .ternary => {
                const t = env.payload(Inst.Triple, i);
                const c = (try env.ref(t.a)) orelse return null;
                return env.ref(if (c.isTrue()) t.b else t.c);
            },
            .mintypmax => env.ref(env.payload(Inst.Triple, i).b),
            .call_sys => env.sysCall(env.payload(Inst.SysCall, i)),
            // ponytail: §4.2.10 reductions, selects, concatenations, field
            // reads and constant functions do not fold yet; each is an
            // unfoldable value, which no fixture's instance tree reads.
            .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor, .str_ref, .field, .elem, .slice, .slice_up, .slice_down, .call, .concat, .pattern, .replicate, .pattern_repl, .port_branch => null,
            .module, .nature, .discipline, .paramset, .primitive, .connectrules, .config, .port, .io, .net, .variable, .param, .aliasparam, .genvar, .event, .branch, .instance, .assign, .defparam, .analog, .analog_initial, .initial, .always, .function, .gen_for, .gen_if, .gen_case, .gen_block, .specify, .path, .timing_check, .pulse_style, .timing_event, .ps_override, .connect_resolve, .connect_insert, .block, .condbr, .case, .loop, .repeat, .wait, .delay, .event_wait, .store, .store_nb, .contrib, .proc_assign, .force, .store_timed, .store_nb_timed, .contrib_indirect, .deassign, .release, .trigger, .disable, .ret, .brk, .cont, .delay_ctl, .event_ctl, .repeat_ctl, .event_or, .posedge, .negedge, .driver_update, .step_event, .paramset_output, .range, .pulse_limits => null,
        };
    }

    /// A name's value: a parameter's, a genvar's, or an alias's original's.
    fn declValue(env: *Env, d: Inst.Index) Allocator.Error!?Const {
        assert(@backingInt(d) < env.vir.instructions.len);
        return switch (env.vir.instructions.items(.tag)[@backingInt(d)]) {
            .param => env.param(d),
            .genvar => if (env.genvars.get(d)) |v| .{ .int = v } else null,
            .aliasparam => if (originalOf(env.vir, d)) |p| env.param(p) else null,
            else => null, // else: a net, variable, port, function or scope has no elaboration value
        };
    }

    /// §4.3's functions and IEEE 1364-2005 §17.11's `$clog2` and math
    /// functions; any other call has no constant value.
    fn sysCall(env: *Env, call: Inst.SysCall) Allocator.Error!?Const {
        assert(call.name != .empty);
        const raw = env.vir.string(call.name);
        const name = if (raw.len != 0 and raw[0] == '$') raw[1..] else raw;
        const args = env.vir.list(Inst.Ref, call.args);
        if (args.len == 0) if (Zcu.SystemParam.fromName(raw)) |k| return env.toConst(env.hier.get(k));
        var vals: [fold.MathFn.arity_max]Const = undefined;
        if (args.len == 0 or args.len > vals.len) return null;
        for (args, vals[0..args.len]) |a, *v| v.* = (try env.ref(a)) orelse return null;
        if (std.mem.eql(u8, name, "clog2")) {
            if (args.len != 1) return null;
            return .{ .int = fold.clog2(vals[0].asIntExact() orelse return null, 32) };
        }
        const f = fold.MathFn.fromName(if (std.mem.eql(u8, name, "log10")) "log" else name) orelse return null;
        return fold.math(f, vals[0..args.len]);
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
            .integer => .{ .int = fold.wrap32(c.asIntExact() orelse return null) },
            .time => .{ .int = c.asIntExact() orelse return null },
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

// ---- private ----

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
    return switch (tag) {
        .pos => .plus,
        .neg => .minus,
        .not => .logical_not,
        .bit_not => .bit_not,
        else => unreachable, // else: `inst` passes only the four tags above
    };
}

fn binaryOp(tag: Inst.Tag) fold.BinaryOp {
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
/// `?` digit or a value wider than 64 bits.
fn bigInt(vir: *const Vir, b: Inst.BigInt) ?Const {
    assert(b.digits != .empty);
    const digits = vir.string(b.digits);
    const radix: u8 = b.flags.radix;
    if (radix != 2 and radix != 8 and radix != 10 and radix != 16) return null;
    var acc: u64 = 0;
    for (digits) |ch| {
        const d = std.fmt.charToDigit(ch, radix) catch return null;
        acc = std.math.mul(u64, acc, radix) catch return null;
        acc = std.math.add(u64, acc, d) catch return null;
    }
    const size: u32 = if (b.size == 0) 32 else b.size;
    if (size < 64) {
        acc &= (@as(u64, 1) << @intCast(size)) - 1;
        if (b.flags.signed and acc >> @intCast(size - 1) != 0) return .{ .int = @bitCast(acc | ~((@as(u64, 1) << @intCast(size)) - 1)) };
    }
    if (size == 64 and b.flags.signed) return .{ .int = @bitCast(acc) };
    return if (acc <= std.math.maxInt(i64)) .{ .int = @intCast(acc) } else null;
}
