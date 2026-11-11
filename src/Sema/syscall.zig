//! System functions and tasks (Zig's builtin-call handling over
//! `BuiltinFn`): a `call_sys` in, switched on its `SysFn.Tag`: a §4.3
//! math function is its `Air` tag over real (or, for `abs`, `min`, `max`,
//! integer) operands; a query, conversion or random number is a `call` of
//! the table's type; a §9.4 display or §9.5 file task is a `call` with no
//! result, recorded in `device.displays`. A spelling the table does not
//! name is a §2.8.3 user system function.
//! Cites: VAMS-2023 §2.8.3, §4.3 (Tables 4-14, 4-15), §9.4, §9.5, §9.7,
//! §9.10, §9.15.
//!
//! Contents:
//! - `pub fn lower(s: *Sema, b: *Block, c: Inst.SysCall, src: Inst.Ref) Allocator.Error!Value`
//! - `pub const Deferred = struct`
//! - `pub fn task(s: *Sema, b: *Block, c: Inst.SysCall, src: Inst.Ref) Allocator.Error!void`
//! - `pub fn fileRow(s: *Sema, tag: SysFn.Tag, call: Air.Inst.Ref) Allocator.Error!void`
//! - `pub fn finishDisplays(s: *Sema, b: *Block) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const expr = @import("expr.zig");
const decl = @import("decl.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const SysFn = vams.SysFn;
const Block = Sema.Block;
const Value = Sema.Value;
const Ref = Air.Inst.Ref;

/// A print `task` left for `finishDisplays`.
pub const Deferred = struct {
    unit: *Sema.Unit,
    tag: SysFn.Tag,
    args: []const Inst.Ref,
    /// Each operand's value at the statement; null for one lowered at the end.
    pre: []const ?Value,
    /// Its `device.displays` row.
    row: u32,
    /// The statement, for §9.4.3's findings.
    src: Inst.Ref,
};

/// A system function call read as a value.
pub fn lower(s: *Sema, b: *Block, c: Inst.SysCall, src: Inst.Ref) Allocator.Error!Value {
    const vir = b.unit.vir;
    const name = vir.string(c.name);
    const args = vir.list(Inst.Ref, c.args);
    if (std.mem.eql(u8, name, "$simprobe")) return @import("simprobe.zig").lower(s, b, args, src);
    const tag = SysFn.Tag.fromName(name) orelse {
        if (try refuseForeign(s, b, name, src)) return expr.poison;
        return userCall(s, b, name, args, .real);
    };
    const info = SysFn.get(tag);
    if (try refuseContext(s, b, tag, src)) return expr.poison;
    // Each of these judges its own argument list, with its clause's codes.
    switch (tag) {
        .white_noise, .flicker_noise, .noise_table, .noise_table_log, .ac_stim => return @import("op.zig").noise(s, b, tag, args, src),
        else => if (info.family == .kernel) return @import("kernel.zig").lower(s, b, tag, args, src), // else: the kernel family by its table row; the rest below
    }
    // §9.13 a distribution judges its own arity, as E0816.
    if (info.family == .random) return @import("dist.zig").lower(s, b, tag, args, src);
    if (!info.args.admits(args.len)) {
        try arity(s, b, tag, args.len, src);
        return expr.poison;
    }
    // §9.5.4/§9.12 a reader assigns its destinations.
    if (readFrom(tag)) |first| return @import("string.zig").read(s, b, tag, first, args, src);
    switch (info.family) {
        .math => return math(s, b, info.math.?, args, src),
        .display, .file_out, .simctl, .string => {
            try task(s, b, c, src);
            return .{ .ref = .fromIntern(.zero_real), .ty = .real };
        },
        .analog_op => return @import("op.zig").lower(s, b, tag, args, src),
        .kernel => unreachable, // routed above
        .event => {
            try s.fail(.E0512, b.unit.file, src, "`{s}` is not lowered by Sema yet", .{name});
            return expr.poison;
        },
        .query, .convert, .random, .file_func => {
            if (tag == .potential or tag == .flow) {
                try s.fail(.E0512, b.unit.file, src, "`{s}` is not lowered by Sema yet", .{name});
                return expr.poison;
            }
            if (tag == .@"$port_connected") return portConnected(s, b, args, src);
            // §3.4.7 the root reads an aliased system parameter's card row.
            if (@import("../Zcu.zig").SystemParam.fromName(name)) |k| if (s.sys_alias.get(k)) |row|
                if (b.unit.instance == s.units.items[0].instance) return s.param_args.items[@backingInt(row)];
            if (tag == .@"$param_given") if (try paramGiven(s, b, args)) |v| return v;
            if ((tag == .@"$simparam" or tag == .@"$simparam$str") and try unknownSimparam(s, b, tag, args, src)) return expr.poison;
            const ty: Sema.Ty = switch (info.ty) {
                .real => .real,
                .int => .integer,
                .str => .string,
                .none => .real,
            };
            const refs = try lowerArgs(s, b, args);
            const host = try expr.call(s, b, @backingInt(tag), ty, refs);
            try fileRow(s, tag, host);
            if (@import("../Zcu.zig").SystemParam.fromName(name)) |k| return .{ .ref = try hierRead(s, b, k, host), .ty = .real };
            return .{ .ref = host, .ty = ty };
        },
    }
}

/// §9.5.9 a descriptor call (`$fopen`, `$fgets`, ...) is a `device.displays`
/// row as well: its effect belongs to the accepted point's I/O phase, in
/// order with the prints (the old `sequenceFileCall`).
pub fn fileRow(s: *Sema, tag: SysFn.Tag, call: Ref) Allocator.Error!void {
    if (SysFn.get(tag).family != .file_func) return;
    const i = call.toIndex() orelse return;
    try s.device.displays.append(s.gpa, .{ .name = try s.zcu.intern_pool.getString(s.gpa, @tagName(tag)), .call = i, .file = .empty, .line = 0 });
}

/// A system task enable (`$strobe(...)`): a `call` with no result; a
/// display or file task is recorded in `device.displays`.
pub fn task(s: *Sema, b: *Block, c: Inst.SysCall, src: Inst.Ref) Allocator.Error!void {
    const vir = b.unit.vir;
    const name = vir.string(c.name);
    const args = vir.list(Inst.Ref, c.args);
    const tag = SysFn.Tag.fromName(name) orelse {
        if (try refuseForeign(s, b, name, src)) return;
        _ = try userCall(s, b, name, args, null);
        return;
    };
    const info = SysFn.get(tag);
    if (try refuseContext(s, b, tag, src)) return;
    switch (info.family) {
        // Judged in `lower`, each with its clause's code.
        .math, .analog_op, .kernel, .random => {},
        else => if (!info.args.admits(args.len)) return arity(s, b, tag, args.len, src),
    }
    if (tag == .@"$sformat" or tag == .@"$swrite") return @import("string.zig").write(s, b, tag, args, src);
    if (readFrom(tag)) |first| {
        _ = try @import("string.zig").read(s, b, tag, first, args, src);
        return;
    }
    switch (info.family) {
        .display, .file_out, .simctl, .string => {},
        else => {
            // A function enabled as a task: its value is dropped.
            _ = try lower(s, b, c, src);
            return;
        },
    }
    // The old `systask`: a task that takes a format, and §9.7's simulation
    // controls, are rows of `displays`.
    const row_kind = switch (tag) {
        .@"$monitoron", .@"$monitoroff" => false,
        else => info.family == .display or info.family == .file_out or info.family == .simctl,
    };
    if (!row_kind) {
        _ = try expr.call(s, b, @backingInt(tag), null, try lowerArgs(s, b, args));
        return;
    }
    // §9.5.1/§9.5.2 `$fclose`/`$fflush`: a row (the old `systask` gives
    // every file_out task one) over the plain call, no format.
    if (info.family == .simctl or tag == .@"$fclose" or tag == .@"$fflush") {
        const r = try expr.call(s, b, @backingInt(tag), null, try lowerArgs(s, b, args));
        try s.device.displays.append(s.gpa, .{ .name = try s.zcu.intern_pool.getString(s.gpa, name), .call = r.toIndex().?, .file = .empty, .line = 0 });
        return;
    }
    const row: u32 = @intCast(s.device.displays.len);
    try s.device.displays.append(s.gpa, .{ .name = try s.zcu.intern_pool.getString(s.gpa, name), .call = undefined, .file = .empty, .line = 0 });
    if (b.conditional != 0) {
        // A guarded print is minted where it stands.
        const vals = try s.arena.alloc(Value, args.len);
        for (args, vals) |a, *v| v.* = try printArg(s, b, a);
        const r = try expr.call(s, b, @backingInt(tag), null, try formatted(s, b, tag, args, vals, src));
        s.device.displays.items(.call)[row] = r.toIndex().?;
        return;
    }
    // §9.4.1 an unconditional print is minted at the end of the analog
    // blocks: an operand that reads a branch flow is lowered there, against
    // the converged sums; every other operand is its value here.
    const pre = try s.arena.alloc(?Value, args.len);
    for (args, pre) |a, *p| p.* = if (a == .none or readsFlow(s, b.unit, a, 0)) null else try expr.lower(s, b, a);
    try s.deferred.append(s.arena, .{ .unit = b.unit, .tag = tag, .args = args, .pre = pre, .row = row, .src = src });
}

/// Mints every print `task` deferred, in source order, at the end of `b`
/// (the main body).
pub fn finishDisplays(s: *Sema, b: *Block) Allocator.Error!void {
    assert(b.parent == null);
    for (s.deferred.items) |d| {
        b.unit = d.unit;
        const vals = try s.arena.alloc(Value, d.args.len);
        for (d.args, d.pre, vals) |a, p, *v| v.* = p orelse try printArg(s, b, a);
        const call = try expr.call(s, b, @backingInt(d.tag), null, try formatted(s, b, d.tag, d.args, vals, d.src));
        s.device.displays.items(.call)[d.row] = call.toIndex().?;
    }
    assert(s.deferred.items.len <= s.device.displays.len);
}

// ---- private ----

/// §6.3.6/§9.18 Table 9-29 a hierarchical system parameter read in an
/// instance under the top: the host's value (`host`, the top's) composed
/// with what the instances between them specify (a product for the flips
/// and `$mfactor`, a sum for the rest, `$angle` modulo 360). The top
/// reads the host's alone.
fn hierRead(s: *Sema, b: *Block, k: @import("../Zcu.zig").SystemParam, host: Ref) Allocator.Error!Ref {
    const zcu = s.zcu;
    const hiers = zcu.instances.items(.hier);
    assert(hiers.len != 0);
    const top = s.units.items[0].instance;
    if (b.unit.instance == top) return host;
    const ip = &zcu.intern_pool;
    const here = switch (ip.indexToKey(hiers[@backingInt(b.unit.instance)].get(k))) {
        .float => |f| f,
        else => return host, // else: a value that did not fold (E0890 was raised)
    };
    const at_top = switch (ip.indexToKey(hiers[@backingInt(top)].get(k))) {
        .float => |f| f,
        else => return host, // else: as above
    };
    return switch (k) {
        .mfactor, .hflip, .vflip => expr.binOp(s, b, .fmul, host, .fromIntern(try decl.intern(s, .{ .real = here / at_top }))),
        .xposition, .yposition => expr.binOp(s, b, .fadd, host, .fromIntern(try decl.intern(s, .{ .real = here - at_top }))),
        .angle => expr.binOp(s, b, .fmod, try expr.binOp(s, b, .fadd, host, .fromIntern(try decl.intern(s, .{ .real = @mod(here - at_top, 360) }))), .fromIntern(try decl.intern(s, .{ .real = 360 }))),
    };
}

/// §9.15 "If param_name is not known, and the optional expression is not
/// supplied, then an error is generated" (E0811): a name that folds and
/// that Table 9-27 (`$simparam`) or 9-28 (`$simparam$str`, which takes no
/// fallback) does not hold. True when raised.
fn unknownSimparam(s: *Sema, b: *Block, tag: SysFn.Tag, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!bool {
    if (args.len == 0 or args[0] == .none or (tag == .@"$simparam" and args.len > 1)) return false;
    const c = (try decl.foldRef(s, b.unit, args[0])) orelse return false;
    if (c != .str) return false;
    const known = if (tag == .@"$simparam") SysFn.simparam_names else SysFn.simparam_str_names;
    // `timeUnit`/`timePrecision` are known only under a `timescale.
    const timescale = std.mem.eql(u8, c.str, "timeUnit") or std.mem.eql(u8, c.str, "timePrecision");
    if (known.has(c.str) and (!timescale or b.unit.module.stamp.flags.has_timescale)) return false;
    try s.fail(.E0811, b.unit.file, src, "`\"{s}\"` is not a §9.15 simulation parameter VerA knows", .{c.str});
    return true;
}

/// §9.19 `$param_given(p)` in an instance under the top: whether its
/// instance statement, a defparam or its paramset gave `p` a value, a
/// constant elaboration knows. Null at the top, whose card the host reads,
/// and for an argument that is no parameter of the module.
fn paramGiven(s: *Sema, b: *Block, args: []const Inst.Ref) Allocator.Error!?Value {
    const unit = b.unit;
    if (unit.instance == s.units.items[0].instance or args.len != 1) return null;
    const vir = unit.vir;
    const i = args[0].toIndex() orelse return null;
    if (vir.instructions.items(.tag)[@backingInt(i)] != .decl_ref) return null;
    const d = decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl);
    var env = try decl.envOf(s, unit);
    defer env.deinit();
    const at = env.positions.getIndex(d) orelse return null;
    const given = s.zcu.instances.items(.given)[@backingInt(unit.instance)];
    const yes = given != .none and s.zcu.intern_pool.indexToKey(given).aggregate.elems[at] == InternPool.Index.one;
    return .{ .ref = .fromIntern(if (yes) InternPool.Index.one else InternPool.Index.zero), .ty = .integer };
}

/// A call of `tag` with `n` arguments, which its row does not admit: a
/// §4.3 function or §4.5 operator is E0506, any other system call E0887
/// (the old `checkArity`).
fn arity(s: *Sema, b: *Block, tag: SysFn.Tag, n: usize, src: Inst.Ref) Allocator.Error!void {
    const a = SysFn.get(tag).args;
    assert(!a.admits(n));
    switch (SysFn.get(tag).family) {
        .math, .analog_op => try s.fail(.E0506, b.unit.file, src, "`{t}` takes {d} to {d}, given {d}", .{ tag, a.min, a.max, n }),
        else => try s.fail(.E0887, b.unit.file, src, "`{t}` takes {d} to {d} arguments, got {d}", .{ tag, a.min, a.max, n }),
    }
}

/// A print operand's value; a null argument is §9.4.1's space.
fn printArg(s: *Sema, b: *Block, a: Inst.Ref) Allocator.Error!Value {
    if (a == .none) return .{ .ref = .fromIntern(try decl.intern(s, .{ .str = " " })), .ty = .string };
    return expr.lower(s, b, a);
}

/// A print's operand refs, after §9.4.3 judged and marked `vals` (format.zig).
fn formatted(s: *Sema, b: *Block, tag: SysFn.Tag, args: []const Inst.Ref, vals: []Value, src: Inst.Ref) Allocator.Error![]const Ref {
    const format = @import("format.zig");
    try format.operands(s, b, format.skipOf(tag, vals), args, vals, src);
    const refs = try s.arena.alloc(Ref, vals.len);
    for (vals, refs) |v, *r| r.* = v.ref;
    return refs;
}

/// Whether `r` reads a branch flow (an access whose name is a flow's
/// anywhere): such an operand is lowered at the end of the blocks.
fn readsFlow(s: *Sema, unit: *const Sema.Unit, r: Inst.Ref, depth: u32) bool {
    const i = r.toIndex() orelse return false;
    if (depth > expr.depth_max) return false;
    const vir = unit.vir;
    const data = vir.instructions.items(.data)[@backingInt(i)];
    switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .call => {
            const c = decl.payloadOf(vir, Inst.Call, i);
            if (c.callee.toIndex()) |callee| if (vir.instructions.items(.tag)[@backingInt(callee)] == .str_ref) {
                const name = vir.string(vir.instructions.items(.data)[@backingInt(callee)].str_tok.start);
                if (s.access_kind.get(name)) |k| return k == .flow or s.access_both.contains(name);
            };
            for (vir.list(Inst.Ref, c.args)) |a| if (readsFlow(s, unit, a, depth + 1)) return true;
            return false;
        },
        .call_sys => {
            const c = decl.payloadOf(vir, Inst.SysCall, i);
            for (vir.list(Inst.Ref, c.args)) |a| if (readsFlow(s, unit, a, depth + 1)) return true;
            return false;
        },
        .pos, .neg, .not, .bit_not, .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor => return readsFlow(s, unit, data.un_node.operand, depth + 1),
        .add, .sub, .mul, .div, .mod, .pow, .shl, .shr, .ashl, .ashr, .lt, .gt, .lte, .gte, .eq, .neq, .case_eq, .case_neq, .bit_and, .bit_or, .bit_xor, .bit_xnor, .bool_and, .bool_or => {
            const bin = decl.payloadOf(vir, Inst.Bin, i);
            return readsFlow(s, unit, bin.lhs, depth + 1) or readsFlow(s, unit, bin.rhs, depth + 1);
        },
        .ternary => {
            const t = decl.payloadOf(vir, Inst.Triple, i);
            return readsFlow(s, unit, t.a, depth + 1) or readsFlow(s, unit, t.b, depth + 1) or readsFlow(s, unit, t.c, depth + 1);
        },
        else => return false, // else: a leaf reads no flow
    }
}

/// The first destination argument of a §9.5.4/§9.12 reader, or null.
fn readFrom(tag: SysFn.Tag) ?usize {
    return switch (tag) {
        .@"$sscanf", .@"$fscanf" => 2,
        .@"$fgets" => 0,
        .@"$ferror" => 1,
        .@"$value$plusargs" => 1,
        else => null, // else: no destination argument
    };
}

/// §9.19 `$port_connected(p)`: the root's port is the host's bit (a call
/// on its ordinal); a child's is known here, from its connection.
fn portConnected(s: *Sema, b: *Block, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value {
    const unit = b.unit;
    const vir = unit.vir;
    const a = if (args.len == 1) args[0].toIndex() else null;
    const port: ?Inst.Index = if (a) |i| if (vir.instructions.items(.tag)[@backingInt(i)] == .decl_ref) decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl) else null else null;
    const ordinal: ?u32 = if (port) |p| for (vir.body(unit.module.ports), 0..) |f, k| {
        if (decl.portDecl(vir, f) == p) break @intCast(k);
    } else null else null;
    const k = ordinal orelse {
        try s.fail(.E0822, unit.file, src, "$port_connected requires a port identifier", .{});
        return expr.poison;
    };
    if (unit.prefix.len == 0) return .{ .ref = try expr.call(s, b, @backingInt(SysFn.Tag.@"$port_connected"), .integer, &.{.fromIntern(try decl.intern(s, .{ .int = k }))}), .ty = .integer };
    const zcu = s.zcu;
    const list = zcu.instances.items(.ports)[@backingInt(unit.instance)];
    const formals = zcu.ports.items(.formal)[list.start..][0..list.len];
    const actuals = zcu.ports.items(.actual)[list.start..][0..list.len];
    const connected = for (formals, actuals) |f, act| {
        if (decl.portDecl(vir, f) == port.?) break act != .none;
    } else false;
    return .{ .ref = .fromIntern(if (connected) .one else .zero), .ty = .integer };
}

/// §9.2 a digital-context name in an analog block is E0806; §9.22 a driver
/// access function outside a connect module E0818 (and in one's analog
/// block E0806).
fn refuseContext(s: *Sema, b: *Block, tag: SysFn.Tag, src: Inst.Ref) Allocator.Error!bool {
    return refuseIn(s, b, SysFn.get(tag).context, @tagName(tag), src);
}

/// `refuseContext` for a spelling of `SysFn.foreign`.
fn refuseForeign(s: *Sema, b: *Block, name: []const u8, src: Inst.Ref) Allocator.Error!bool {
    return refuseIn(s, b, SysFn.foreign.get(name) orelse return false, name, src);
}

fn refuseIn(s: *Sema, b: *Block, context: SysFn.Context, name: []const u8, src: Inst.Ref) Allocator.Error!bool {
    switch (context) {
        .both, .analog => return false,
        .digital => try s.fail(.E0806, b.unit.file, src, "`{s}`", .{name}),
        .connect => {
            const in_cm = b.unit.module.flags.kind == .connectmodule;
            if (in_cm and !std.mem.eql(u8, name, "$receiver_count"))
                try s.fail(.E0806, b.unit.file, src, "`{s}` in the analog block of a connect module", .{name})
            else
                try s.fail(.E0818, b.unit.file, src, "`{s}` can only be called from a connect module", .{name});
        },
    }
    return true;
}

/// Each argument lowered, in order; an omitted one is a real 0.
fn lowerArgs(s: *Sema, b: *Block, args: []const Inst.Ref) Allocator.Error![]const Ref {
    const out = try s.arena.alloc(Ref, args.len);
    for (args, out) |a, *o| o.* = if (a == .none) .fromIntern(.zero_real) else (try expr.lower(s, b, a)).ref;
    return out;
}

/// §12 a user system function or task: a `call` of `user_callee`, its name
/// in `device.systf` for the host's table.
fn userCall(s: *Sema, b: *Block, name: []const u8, args: []const Inst.Ref, ty: ?Sema.Ty) Allocator.Error!Value {
    const refs = try lowerArgs(s, b, args);
    const r = try expr.call(s, b, expr.user_callee, ty, refs);
    try s.device.systf.append(s.gpa, .{ .name = try s.zcu.intern_pool.getString(s.gpa, name), .call = r.toIndex().?, .file = .empty, .line = 0 });
    return .{ .ref = r, .ty = ty orelse .real };
}

/// §4.3 a Table 4-14/4-15 function over its operands (the old `analog/math.zig`).
fn math(s: *Sema, b: *Block, m: SysFn.Math, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value {
    var vals: [2]Value = undefined;
    for (args, vals[0..args.len]) |a, *v| {
        v.* = try expr.lower(s, b, a);
        if (v.ty == .string) {
            try s.fail(.E0321, b.unit.file, src, "a §4.3 math function operand shall be numeric (integer or real); this one is a string", .{});
            return expr.poison;
        }
    }
    switch (m) {
        .abs => {
            const a = vals[0];
            return .{ .ref = try expr.unOp(s, b, if (a.ty == .integer) .iabs else .fabs, a.ref), .ty = a.ty };
        },
        .min, .max => {
            const real = vals[0].ty == .real or vals[1].ty == .real;
            const ty: Sema.Ty = if (real) .real else .integer;
            const tag: Air.Inst.Tag = if (m == .min) (if (real) .fmin else .imin) else (if (real) .fmax else .imax);
            return .{ .ref = try expr.binOp(s, b, tag, try expr.coerce(s, b, vals[0], ty), try expr.coerce(s, b, vals[1], ty)), .ty = ty };
        },
        else => {}, // else: a real function, below
    }
    const tag: Air.Inst.Tag = switch (m) {
        .sqrt => .sqrt,
        .exp => .exp,
        .expm1 => .expm1,
        .ln => .ln,
        .ln1p => .ln1p,
        .log10 => .log10,
        .pow => .pow,
        .hypot => .hypot,
        .floor => .floor,
        .ceil => .ceil,
        .sin => .sin,
        .cos => .cos,
        .tan => .tan,
        .asin => .asin,
        .acos => .acos,
        .atan => .atan,
        .atan2 => .atan2,
        .sinh => .sinh,
        .cosh => .cosh,
        .tanh => .tanh,
        .asinh => .asinh,
        .acosh => .acosh,
        .atanh => .atanh,
        .abs, .min, .max => unreachable, // returned above
    };
    if (Air.tag_info.getPtrConst(tag).class == .un_op) return .{ .ref = try expr.unOp(s, b, tag, try expr.coerce(s, b, vals[0], .real)), .ty = .real };
    assert(args.len == 2);
    return .{ .ref = try expr.binOp(s, b, tag, try expr.coerce(s, b, vals[0], .real), try expr.coerce(s, b, vals[1], .real)), .ty = .real };
}
