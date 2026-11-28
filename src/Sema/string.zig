//! §3.3 strings (the old `analog/expr_concat.zig`, the string half of
//! `expr_op.zig` and `string_io.zig`'s writers): two string operands of a
//! comparison, a concatenation or replication, or a `$sformat`/`$swrite`
//! in; a string or integer `Value` out. Constant operands fold here; a
//! string known only while the device runs goes through the synthetic
//! calls `str$cmp` (-1, 0, 1), `str$cat` and `str$repeat`, which the host
//! computes, as the old `$str$cat`/`$str$repeat`.
//! Cites: VAMS-2023 §3.3 (Table 3-3), §4.2.13, §9.5.3.
//!
//! Contents:
//! - `pub fn compare(s: *Sema, b: *Block, tag: Inst.Tag, x: Value, y: Value) Allocator.Error!Value`
//! - `pub fn concat(s: *Sema, b: *Block, i: Inst.Index, src: Inst.Ref) Allocator.Error!Value`
//! - `pub fn write(s: *Sema, b: *Block, tag: SysFn.Tag, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!void`
//! - `pub fn read(s: *Sema, b: *Block, tag: SysFn.Tag, first: usize, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value`
//! - `pub fn simparamStr(s: *Sema, b: *Block, args: []const Inst.Ref) Allocator.Error!?Value`
//! - `pub fn finish(s: *Sema, air: *const Air) Allocator.Error!void`: `Device.name` and `Device.str_caps`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const expr = @import("expr.zig");
const Inst = vams.Vir.Inst;
const SysFn = vams.SysFn;
const Block = Sema.Block;
const Value = Sema.Value;
const Ref = Air.Inst.Ref;
const InternPool = @import("intern_pool");
const Device = Air.Device;

/// The longest string a constant replication folds to.
const concat_bytes_max: u64 = 1 << 20;

const none = std.math.maxInt(u32);

/// `finish`'s walk: one memoized capacity per instruction.
const Caps = struct {
    air: *const Air,
    ip: *const InternPool,
    name_len: u64,
    caps: []u64,
    state: []State,
    /// Per slot or block, its first `assign` or `br`; `next` chains the rest.
    head: []u32,
    next: []u32,
    /// Per §5.10 held slot, its initializer's length.
    held_init: []?u64,

    const State = enum(u8) { new, open, done };
    /// The deepest chain of string operands followed; past it a piece counts the row.
    const depth_max = 1 << 10;

    fn cap(c: *Caps, ref: Ref, depth: u32) u64 {
        const i = ref.toIndex() orelse {
            const index = ref.toInterned() orelse return 0;
            return switch (c.ip.indexToKey(index)) {
                .str => |t| c.ip.stringToSlice(t).len,
                else => 0, // else: §2.7 a number read as a string
            };
        };
        const k = @backingInt(i);
        switch (c.state[k]) {
            .done => return c.caps[k],
            .open => return Device.str_row, // a cycle through a slot
            .new => {},
        }
        if (depth >= depth_max) return Device.str_row;
        c.state[k] = .open;
        const v = c.compute(i, depth + 1);
        c.caps[k] = v;
        c.state[k] = .done;
        return v;
    }

    fn compute(c: *Caps, i: Air.Inst.Index, depth: u32) u64 {
        const air = c.air;
        const k = @backingInt(i);
        const data = air.instructions.items(.data)[k];
        switch (air.instructions.items(.tag)[k]) {
            .alloc, .block => {
                var m: u64 = if (c.held_init[k]) |len| @max(len, Device.str_row) else 0;
                var at = c.head[k];
                // Each pass follows one link of the list `finish` chained.
                for (0..air.instructions.len) |_| {
                    if (at == none) break;
                    const d = air.instructions.items(.data)[at];
                    const v = if (air.instructions.items(.tag)[at] == .assign) d.bin_op.rhs else d.br.operand;
                    if (v != .none) m = @max(m, c.cap(v, depth));
                    at = c.next[at];
                }
                return m;
            },
            .load => return c.cap(data.un_op, depth),
            .opt_barrier, .dstop => return c.cap(data.un_op, depth),
            .select => {
                const bin = air.extraData(Air.Bin, data.pl_op.payload).data;
                return @max(c.cap(bin.lhs, depth), c.cap(bin.rhs, depth));
            },
            .call => {
                const x = air.extraData(Air.Call, data.ty_pl.payload);
                const args: []const Ref = @ptrCast(air.extra[x.end..][0..x.data.args_len]);
                if (x.data.callee > std.math.maxInt(@typeInfo(SysFn.Tag).@"enum".tag_type)) return Device.str_row;
                const tag: SysFn.Tag = @fromBackingInt(@intCast(x.data.callee));
                return switch (tag) {
                    .@"$sformat", .@"$swrite" => if (tag == .@"$sformat" and args.len != 0 and c.str(args[0]) == null)
                        c.rtFormat(args, depth)
                    else
                        @max(c.literalFormat(args, depth), Device.str_row),
                    .@"str$cat" => blk: {
                        var m: u64 = 0;
                        for (args) |a| m +|= c.cap(a, depth);
                        break :blk @max(m, Device.str_row);
                    },
                    .@"str$repeat" => blk: {
                        const copies = c.int(args[0]) orelse break :blk Device.str_row;
                        break :blk @max(@as(u64, @intCast(@max(copies, 0))) *| c.cap(args[1], depth), Device.str_row);
                    },
                    // §9.5.4.2 an item is a slice of the scanned string.
                    .@"scan$str" => blk: {
                        const r = args[0].toIndex() orelse break :blk Device.str_row;
                        const rd = air.instructions.items(.data)[@backingInt(r)];
                        if (air.instructions.items(.tag)[@backingInt(r)] != .call) break :blk Device.str_row;
                        const rx = air.extraData(Air.Call, rd.ty_pl.payload);
                        if (rx.data.callee != @backingInt(SysFn.Tag.@"$sscanf") or rx.data.args_len == 0) break :blk Device.str_row;
                        break :blk c.cap(@fromBackingInt(air.extra[rx.end]), depth);
                    },
                    else => Device.str_row, // else: a file line, a `$simparam$str` answer: run-time lengths
                };
            },
            else => return Device.str_row, // else: a parameter, an array element: run-time lengths
        }
    }

    /// `zSFormatRt`'s row: the format's own text plus each operand's widest
    /// rendering (the old `rtFormatCap`).
    fn rtFormat(c: *Caps, args: []const Ref, depth: u32) u64 {
        var m = c.cap(args[0], depth);
        for (args[1..]) |a| m +|= if (c.isStr(a)) c.cap(a, depth) else 512;
        return @max(m, Device.str_row);
    }

    /// The bytes a §9.4.1 argument list can render to: each constant
    /// string a format, its literal bytes and each conversion's widest
    /// field (the old `siteCap` over `PrintArg.textMax`); an operand no
    /// format took, its default conversion's.
    fn literalFormat(c: *Caps, args: []const Ref, depth: u32) u64 {
        var m: u64 = 0;
        var i: usize = 0;
        // Each pass consumes at least one argument.
        while (i < args.len) {
            const fmt = c.str(args[i]) orelse {
                m +|= c.field(0, 0, null, args[i], depth);
                i += 1;
                continue;
            };
            i += 1;
            var j: usize = 0;
            while (j < fmt.len) {
                if (fmt[j] != '%') {
                    m +|= 1;
                    j += 1;
                    continue;
                }
                j += 1;
                while (j < fmt.len and @import("kernels").str_real.zcFlag(fmt[j]) != null) j += 1;
                var width: u64 = 0;
                while (j < fmt.len and std.ascii.isDigit(fmt[j])) : (j += 1) width = width *| 10 +| (fmt[j] - '0');
                var prec: ?u64 = null;
                if (j < fmt.len and fmt[j] == '.') {
                    j += 1;
                    var p: u64 = 0;
                    while (j < fmt.len and std.ascii.isDigit(fmt[j])) : (j += 1) p = p *| 10 +| (fmt[j] - '0');
                    prec = p;
                }
                if (j >= fmt.len) break;
                const conv = std.ascii.toLower(fmt[j]);
                j += 1;
                switch (conv) {
                    '%' => m +|= 1,
                    'm', 'l' => m +|= c.name_len + 5,
                    else => {
                        const op: Ref = if (i < args.len) args[i] else .fromIntern(.zero_real);
                        i += 1;
                        m +|= c.field(conv, width, prec, op, depth);
                    },
                }
            }
        }
        return m;
    }

    /// The widest text conversion `conv` (0: an operand's default) of `op`
    /// writes in a field of `width`.
    fn field(c: *Caps, conv: u8, width: u64, prec: ?u64, op: Ref, depth: u32) u64 {
        const body: u64 = switch (conv) {
            'e', 'f', 'g', 'r' => @max(width, (prec orelse 6) +| 320) +| 8,
            'b', 'o', 'h', 'x' => 64,
            'c' => 1,
            'd' => width +| 24,
            's' => if (c.isStr(op)) c.cap(op, depth) else 8,
            0 => if (c.isStr(op)) c.cap(op, depth) else 512,
            else => 512,
        };
        return @max(body, width);
    }

    fn isStr(c: *const Caps, r: Ref) bool {
        return c.air.typeOf(c.ip, r) == InternPool.Index.string_type;
    }

    fn str(c: *const Caps, r: Ref) ?[]const u8 {
        const index = r.toInterned() orelse return null;
        return switch (c.ip.indexToKey(index)) {
            .str => |t| c.ip.stringToSlice(t),
            else => null, // else: not a string literal
        };
    }

    fn int(c: *const Caps, r: Ref) ?i64 {
        const index = r.toInterned() orelse return null;
        return switch (c.ip.indexToKey(index)) {
            .int => |v| switch (v.storage) {
                .small => |x| x,
                .big => null,
            },
            else => null, // else: not an integer literal
        };
    }
};

/// §3.3 Table 3-3's equality and relational operators over two strings: an
/// integer 0 or 1, lexicographic.
pub fn compare(s: *Sema, b: *Block, tag: Inst.Tag, x: Value, y: Value) Allocator.Error!Value {
    assert(x.ty == .string and y.ty == .string);
    const order: Ref = blk: {
        if (expr.constOf(s, x.ref)) |cx| if (expr.constOf(s, y.ref)) |cy| {
            const o: i64 = switch (std.mem.order(u8, cx.str, cy.str)) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            };
            break :blk .fromIntern(try decl.intern(s, .{ .int = o }));
        };
        break :blk try expr.call(s, b, @backingInt(SysFn.Tag.@"str$cmp"), .integer, &.{ x.ref, y.ref });
    };
    const t: Air.Inst.Tag = switch (tag) {
        .lt => .ilt,
        .gt => .igt,
        .lte => .ile,
        .gte => .ige,
        .eq, .case_eq => .ieq,
        else => .ine, // else: `!=` and `!==`, the rest of the comparisons
    };
    return .{ .ref = try expr.binOp(s, b, t, order, .fromIntern(.zero)), .ty = .integer };
}

/// §3.3 Table 3-3 `{s1, s2}` and `{n{s}}`: the joined string, folded when
/// every operand and the count are constants (E0326 an empty list, E0327 a
/// count that is negative, no integer, or a run-time real), else `str$cat`
/// and `str$repeat`. A sized-integer operand is not lowered yet.
pub fn concat(s: *Sema, b: *Block, i: Inst.Index, src: Inst.Ref) Allocator.Error!Value {
    const vir = b.unit.vir;
    // §4.2.13 the integer form: sized literals, folded.
    if (try @import("bits.zig").fold(s, b, i, src)) |v| return v;
    const repl = vir.instructions.items(.tag)[@backingInt(i)] == .replicate;
    var copies: i64 = 1;
    var count: ?Ref = null;
    var list = i;
    if (repl) {
        const x = decl.payloadOf(vir, Inst.Bin, i);
        if (try decl.foldRef(s, b.unit, x.lhs)) |n| {
            copies = n.asIntExact() orelse return fail(s, b, src, "a replication constant shall be a finite integer after conversion");
            if (copies < 0) return fail(s, b, src, "a replication constant shall be non-negative");
        } else {
            const n = try expr.lower(s, b, x.lhs);
            if (n.ty != .integer) return fail(s, b, src, "a nonconstant replication multiplier shall be of integral type");
            count = n.ref;
        }
        list = x.rhs.toIndex() orelse return expr.poison;
        if (vir.instructions.items(.tag)[@backingInt(list)] != .concat) return refuse(s, b, src);
    }
    const elems = vir.list(Inst.Ref, decl.payloadOf(vir, Inst.Refs, list));
    if (elems.len == 0) {
        try s.fail(.E0326, b.unit.file, src, "", .{});
        return expr.poison;
    }
    // The current run of constant operands, and the parts in order.
    var run: std.ArrayList(u8) = .empty;
    var parts: std.ArrayList(Ref) = .empty;
    for (elems) |el| {
        const v = try expr.lower(s, b, el);
        if (v.ty != .string) return refuse(s, b, src);
        if (expr.constOf(s, v.ref)) |c| {
            try run.appendSlice(s.arena, c.str);
            continue;
        }
        if (run.items.len != 0) try parts.append(s.arena, .fromIntern(try decl.intern(s, .{ .str = try run.toOwnedSlice(s.arena) })));
        try parts.append(s.arena, v.ref);
    }
    if (parts.items.len == 0 and count == null) {
        const one = run.items;
        // N copies of "" are "", never counted out.
        if (one.len == 0 or copies == 1) return str(s, one);
        if (std.math.mul(u64, one.len, @intCast(copies)) catch std.math.maxInt(u64) <= concat_bytes_max) {
            var all: std.ArrayList(u8) = .empty;
            for (0..@intCast(copies)) |_| try all.appendSlice(s.arena, one);
            return str(s, all.items);
        }
    }
    if (run.items.len != 0 or parts.items.len == 0) try parts.append(s.arena, .fromIntern(try decl.intern(s, .{ .str = run.items })));
    const joined = if (parts.items.len == 1) parts.items[0] else try expr.call(s, b, @backingInt(SysFn.Tag.@"str$cat"), .string, parts.items);
    if (count == null and copies == 1) return .{ .ref = joined, .ty = .string };
    const n = count orelse Ref.fromIntern(try decl.intern(s, .{ .int = copies }));
    return .{ .ref = try expr.call(s, b, @backingInt(SysFn.Tag.@"str$repeat"), .string, &.{ n, joined }), .ty = .string };
}

/// §9.5.3 `$sformat(s, fmt, args...)` and `$swrite(s, args...)`: `s`
/// assigned the call's string, which the host formats.
pub fn write(s: *Sema, b: *Block, tag: SysFn.Tag, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!void {
    const file = b.unit.file;
    if (args.len == 0 or args[0] == .none) return s.fail(.E0813, file, src, "`{t}` needs a string variable to write into", .{tag});
    if (slotType(b, args[0])) |t| if (t != .string) return s.fail(.E0813, file, src, "`{t}` writes into a `string` variable, and this one is {t}", .{ tag, t });
    const ops = args[1..];
    const vals = try s.arena.alloc(Value, ops.len);
    for (ops, vals) |a, *v| v.* = if (a == .none) .{ .ref = .fromIntern(try decl.intern(s, .{ .str = " " })), .ty = .string } else try expr.lower(s, b, a);
    // §9.5.3 `$sformat`'s format may be a string variable, read at run time.
    const runtime = tag == .@"$sformat" and vals.len != 0 and ops[0] != .none and expr.constOf(s, vals[0].ref) == null;
    if (runtime and vals[0].ty != .string) return s.fail(.E0813, file, src, "`$sformat`'s format_string is a string, and this one is {t}", .{vals[0].ty});
    if (!runtime) try @import("format.zig").operands(s, b, 0, ops, vals, src);
    const refs = try s.arena.alloc(Ref, vals.len);
    for (vals, refs) |x, *r| r.* = x.ref;
    const v = try expr.call(s, b, @backingInt(tag), .string, refs);
    try @import("control.zig").assignTo(s, b, args[0], .{ .ref = v, .ty = .string }, src);
}

/// §9.5.4 `$sscanf`/`$fscanf`/`$fgets`, §9.5.7 `$ferror` and §9.12
/// `$value$plusargs`: an integer `call` of the operands it reads (its count
/// or status), then each destination (argument `first`, and every one after
/// it for a scan) assigned `scan$item(call, k)` (a number, coerced) or
/// `scan$str(call, k)`. E0813 (the old `string_io`'s): a scan with no source
/// or format, a `$sscanf` source that is no string, a literal format with a
/// code §9.5.4.2 does not list, a `$fgets`/`$ferror` destination that is no
/// `string`; the value is then 0.
pub fn read(s: *Sema, b: *Block, tag: SysFn.Tag, first: usize, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value {
    const file = b.unit.file;
    const zero: Value = .{ .ref = .fromIntern(.zero), .ty = .integer };
    const many = first >= 2;
    if (many and (args.len < 2 or args[0] == .none or args[1] == .none)) {
        try s.fail(.E0813, file, src, "`{t}` needs a source and a format string", .{tag});
        return zero;
    }
    if (many) if (try decl.foldRef(s, b.unit, args[1])) |c| if (c == .str) if (badScanCode(c.str)) |code| {
        try s.fail(.E0813, file, src, "`{t}` does not support the conversion `%{c}`; §9.5.4.2's codes are %d %o %h %x %b %c %f %e %g %s %r %m", .{ tag, code });
        return zero;
    };
    if (tag == .@"$fgets" or tag == .@"$ferror") if (args.len > first) if (slotType(b, args[first])) |t| if (t != .string) {
        try s.fail(.E0813, file, src, "`{t}` writes into a `string` variable, and this one is {t}", .{ tag, t });
        return zero;
    };
    var ops: std.ArrayList(Ref) = .empty;
    for (args, 0..) |a, k| {
        if (k == first or (many and k > first)) continue;
        const v: Value = if (a == .none) .{ .ref = .fromIntern(.zero_real), .ty = .real } else try expr.lower(s, b, a);
        // §9.5.4.2 "a string variable, string parameter, or string literal".
        if (tag == .@"$sscanf" and k == 0 and v.ty != .string) {
            try s.fail(.E0813, file, src, "`$sscanf` reads from a string variable, string parameter or string literal, and this one is {t}", .{v.ty});
            return zero;
        }
        try ops.append(s.arena, v.ref);
    }
    const r = try expr.call(s, b, @backingInt(tag), .integer, ops.items);
    try @import("syscall.zig").fileRow(s, tag, r);
    for (args, 0..) |a, k| {
        if (!(k == first or (many and k > first)) or a == .none) continue;
        const ty = slotType(b, a) orelse .real;
        const at: Ref = .fromIntern(try decl.intern(s, .{ .int = @intCast(k - first) }));
        // §9.5.4.2 a scan assigns only the items it converted: destination k
        // keeps its value unless the count passed k (the old `lowerScan`).
        var then_b = b.child();
        var else_b = b.child();
        if (many) {
            then_b.conditional += 1;
            then_b.runtime += 1;
            else_b.conditional += 1;
            else_b.runtime += 1;
        }
        const into = if (many) &then_b else b;
        const v: Value = if (ty == .string)
            .{ .ref = try expr.call(s, into, @backingInt(SysFn.Tag.@"scan$str"), .string, &.{ r, at }), .ty = .string }
        else
            .{ .ref = try expr.call(s, into, @backingInt(SysFn.Tag.@"scan$item"), .real, &.{ r, at }), .ty = .real };
        try @import("control.zig").assignTo(s, into, a, v, src);
        if (many) try @import("control.zig").ifElse(s, b, try expr.binOp(s, b, .igt, r, at), &then_b, &else_b);
    }
    return .{ .ref = r, .ty = .integer };
}

/// §9.15 Table 9-28's hierarchy rows, elaboration facts of the calling
/// instance (the old `Lower.simparamStr`): "module" is "the name of the
/// module from which $simparam$str is called", "instance" "the hierarchical
/// name of the instance" (its root's module first, §6.7). Null for any other
/// name, or one known only at run time: the host answers it.
pub fn simparamStr(s: *Sema, b: *Block, args: []const Inst.Ref) Allocator.Error!?Value {
    if (args.len == 0 or args[0] == .none) return null;
    const c = (try decl.foldRef(s, b.unit, args[0])) orelse return null;
    if (c != .str) return null;
    const zcu = s.zcu;
    const inst = b.unit.instance;
    if (std.mem.eql(u8, c.str, "module")) {
        const d = zcu.instances.items(.module)[@backingInt(inst)];
        return try str(s, zcu.fileVir(d.file).string(zcu.declRow(d).name));
    }
    if (std.mem.eql(u8, c.str, "instance")) return try str(s, try std.fmt.allocPrint(s.arena, "{f}", .{zcu.fmtPath(inst)}));
    return null;
}

/// Sets the device's `name` (the top module's, §9.4.3 `%m`) and
/// `str_caps` (the old `cg_strcap.cap`): per instruction that yields a
/// string, the most bytes it can hold. A piece whose length is run-time
/// data no fold bounds (a string parameter a card may set, a `$simparam$str`
/// answer, a file line) counts `Device.str_row`; a run-time string's row is
/// never below it, and a slot holds the most of every value assigned to it
/// (a §5.10 held one also its initializer, and never below the row). A slot
/// met again while its own capacity is computed (a loop's `s = {s, "x"}`)
/// counts the row, as the old phi did. Called once, after `Air.finish`.
pub fn finish(s: *Sema, air: *const Air) Allocator.Error!void {
    const zcu = s.zcu;
    const d = zcu.instances.items(.module)[0];
    s.device.name = try zcu.intern_pool.getString(s.gpa, zcu.fileVir(d.file).string(zcu.declRow(d).name));
    const ip = &zcu.intern_pool;
    const n = air.instructions.len;
    const tags = air.instructions.items(.tag);
    const datas = air.instructions.items(.data);
    var any = false;
    for (0..n) |i| any = any or air.typeOfIndex(ip, @fromBackingInt(@intCast(i))) == InternPool.Index.string_type;
    if (!any) return;
    var c: Caps = .{
        .air = air,
        .ip = ip,
        .name_len = ip.stringToSlice(s.device.name).len,
        .caps = try s.arena.alloc(u64, n),
        .state = try s.arena.alloc(Caps.State, n),
        .head = try s.arena.alloc(u32, n),
        .next = try s.arena.alloc(u32, n),
        .held_init = try s.arena.alloc(?u64, n),
    };
    @memset(c.caps, 0);
    @memset(c.state, .new);
    @memset(c.head, none);
    @memset(c.next, none);
    @memset(c.held_init, null);
    // Each slot's assignments and each block's breaks, one list per head.
    for (tags, datas, 0..) |tag, data, i| {
        const owner: u32 = switch (tag) {
            .assign => @backingInt(data.bin_op.lhs.toIndex() orelse continue),
            .br => @backingInt(data.br.block_inst),
            else => continue, // else: no value joins a slot or a block
        };
        c.next[i] = c.head[owner];
        c.head[owner] = @intCast(i);
    }
    for (s.device.held.items(.slot), s.device.held.items(.count), s.device.held.items(.init)) |slot, count, init| {
        for (0..count) |k| {
            const at = @backingInt(slot) + k;
            var len: u64 = 0;
            if (init != .none and init != InternPool.Index.undef) switch (ip.indexToKey(init)) {
                .str => |t| len = ip.stringToSlice(t).len,
                .aggregate => |agg| if (k < agg.elems.len) switch (ip.indexToKey(agg.elems[k])) {
                    .str => |t| len = ip.stringToSlice(t).len,
                    else => {}, // else: a number's element
                },
                else => {}, // else: a number
            };
            c.held_init[at] = len;
        }
    }
    const caps = try s.gpa.alloc(u64, n);
    errdefer s.gpa.free(caps);
    for (caps, 0..) |*out, i| {
        out.* = 0;
        if (air.typeOfIndex(ip, @fromBackingInt(@intCast(i))) != InternPool.Index.string_type) continue;
        out.* = c.cap(.fromIndex(@fromBackingInt(@intCast(i))), 0);
    }
    s.device.str_caps = caps;
}

// ---- private ----

/// The first conversion code of scan format `fmt` that §9.5.4.2's table
/// does not list (case-sensitive, as the scanner compares it), or null.
fn badScanCode(fmt: []const u8) ?u8 {
    var i: usize = 0;
    while (std.mem.findScalarPos(u8, fmt, i, '%')) |p| {
        i = p + 1;
        if (i >= fmt.len) return null;
        if (fmt[i] == '%') { // a literal percent, matched not converted
            i += 1;
            continue;
        }
        if (fmt[i] == '*') i += 1;
        while (i < fmt.len and std.ascii.isDigit(fmt[i])) i += 1;
        if (i >= fmt.len) return null;
        const conv = fmt[i];
        i += 1;
        if (std.mem.findScalar(u8, "dohxbcfegsrm", conv) == null) return conv;
    }
    return null;
}

/// The type of the variable (or array element) `r` names, or null.
fn slotType(b: *Block, r: Inst.Ref) ?Sema.Ty {
    const vir = b.unit.vir;
    var at = r;
    for (0..64) |_| {
        const i = at.toIndex() orelse return null;
        switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            .elem => at = decl.payloadOf(vir, Inst.Bin, i).lhs,
            .decl_ref => {
                const bind = b.unit.binds.get(decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl)) orelse return null;
                return switch (bind) {
                    .slot => |x| x.ty,
                    .array => |x| x.ty,
                    else => null, // else: no variable
                };
            },
            else => return null, // else: no variable
        }
    }
    return null;
}

fn str(s: *Sema, bytes: []const u8) Allocator.Error!Value {
    return .{ .ref = .fromIntern(try decl.intern(s, .{ .str = bytes })), .ty = .string };
}

fn fail(s: *Sema, b: *Block, src: Inst.Ref, msg: []const u8) Allocator.Error!Value {
    try s.fail(.E0327, b.unit.file, src, "{s}", .{msg});
    return expr.poison;
}

fn refuse(s: *Sema, b: *Block, src: Inst.Ref) Allocator.Error!Value {
    try s.fail(.E0512, b.unit.file, src, "a concatenation of sized integers is not lowered by Sema yet", .{});
    return expr.poison;
}
