//! §3.3 string values and §9.5.3/§9.5.4.2 string formatting in the Zig
//! device: a string is a `[]const u8`, a slot `var s<i>: []const u8`, a
//! §5.10 held one an `Instance` field of `K.str.ZStrHeldN(cap)` bytes. Every
//! string a call builds while the device runs lives in its call site's row
//! (`K.str.zSRow(site, 0, cap)`), sized by Sema (`Air.Device.str_caps`), so
//! no legal model overruns one; run-time text past it is E1011 (`zSOver`),
//! as the old device. `$sformat`/`$swrite` translate their §9.4.1 argument
//! list into one run-time format at compile time (the old `buildArgs` and
//! `appendConv`: IEEE 1364 §17.1.1.3's automatic fields resolved here) and
//! run it through `K.printf.zSFormatRt`; `$sscanf` is `K.str.zScanNul*`.
//! Each spelling is the old device's (`cg_display.emitStringFormat`,
//! `cg_format.appendConv`, `call.zig`'s `emitString`), so the two compute
//! the same bytes.
//! Cites: VAMS-2023 §2.7, §3.3 (Table 3-3), §4.2.1.1, §5.10, §9.4.1, §9.4.3,
//! §9.4.5, §9.5.3, §9.5.4.2, §9.15 (Table 9-28); IEEE 1364-2005 §17.1.1.2,
//! §17.1.1.3.
//!
//! Contents:
//! - `pub fn isStr(f: *const Function, ref: Air.Inst.Ref) bool`, `pub fn isStrType(ty: InternPool.Index) bool`
//! - `pub fn operand(f: *Function, ref: Air.Inst.Ref) DeclGen.Error!void`
//! - `pub fn strToInt(bytes: []const u8) i64`
//! - `pub fn gen(f: *Function, inst: Air.Inst.Index, tag: SysFn.Tag, args: []const Air.Inst.Ref) DeclGen.Error!bool`
//! - `pub fn scanInt(f: *Function, ref: Air.Inst.Ref) DeclGen.Error!bool`
//! - `pub fn capOf(dg: *DeclGen, i: usize) DeclGen.Error!u64`

const std = @import("std");
const assert = std.debug.assert;
const Air = @import("air");
const InternPool = @import("intern_pool");
const SysFn = @import("vams").SysFn;
const str_real = @import("contract").str_real;
const DeclGen = @import("DeclGen.zig");
const Function = @import("Function.zig");
const state = @import("state.zig");
const Device = Air.Device;
const Ref = Air.Inst.Ref;
const Error = DeclGen.Error;

/// How one translated operand reaches `zSFormatRt`'s tuple.
const How = enum {
    /// An `i64`: an integer, a real rounded (§4.2.1.1), a string literal's
    /// §2.7 value; at `bits`, its two's-complement pattern at that width.
    int,
    /// An `f64`: a real, or an integer converted (§4.2.1.1).
    real,
    /// The operand's text.
    str,
    /// A real's shortest round-trip decimal (the old bare-real deviation),
    /// written into a stack scratch and passed as text.
    shortest,
};

/// One operand of the run-time format: `ref`, or `.none` for a conversion
/// with no operand left (the old `Mir.Value.f_zero`).
const Op = struct { ref: Ref, how: How, bits: u7 = 64 };

/// A parsed `%[flags][width][.precision]` prefix.
const Spec = struct { flags: u8 = 0, width: u64 = 0, prec: ?u64 = null };

const Width = struct { bits: u7, signed: bool };

/// Whether operand `ref` is a string.
pub fn isStr(f: *const Function, ref: Ref) bool {
    return isStrType(f.dg.air.typeOf(f.dg.ip, ref));
}

/// Whether `ty` is §3.3's `string`.
pub fn isStrType(ty: InternPool.Index) bool {
    return ty == InternPool.Index.string_type;
}

/// Writes a string operand as §3.3 stores it: a literal with its NUL bytes
/// removed ("hello\0world" is "helloworld"), or the value that holds it. A
/// number where a string is read is the empty string (the old
/// `renderVal(.str)`).
pub fn operand(f: *Function, ref: Ref) Error!void {
    if (ref.toIndex()) |i| return f.print("v{d}", .{@backingInt(i)});
    switch (f.dg.ip.indexToKey(ref.toInterned().?)) {
        .str => |t| {
            try f.print("\"", .{});
            for (f.dg.ip.stringToSlice(t)) |c| if (c != 0) try f.print("{f}", .{std.zig.fmtString(&.{c})});
            return f.print("\"", .{});
        },
        else => return f.print("\"\"", .{}), // else: a number read as a string
    }
}

/// §2.7 a string literal as a number: the unsigned base-256 integer its last
/// eight bytes spell, as an `i64` (`kernels.fold.strToInt(s, 64)`).
pub fn strToInt(bytes: []const u8) i64 {
    const kept = bytes[bytes.len - @min(bytes.len, 8) ..];
    var acc: u64 = 0;
    for (kept) |c| acc = acc << 8 | c;
    assert(kept.len <= 8);
    return @bitCast(acc);
}

/// Writes call `inst`'s value when `tag` is a string call this file spells
/// (§3.3's `str$cmp`/`str$cat`/`str$repeat`, §9.5.3's writers, §9.5.4.2's
/// `$sscanf` and its items, §9.15's `$simparam$str`); false for any other.
pub fn gen(f: *Function, inst: Air.Inst.Index, tag: SysFn.Tag, args: []const Ref) Error!bool {
    const i = @backingInt(inst);
    switch (tag) {
        .@"str$cmp" => {
            if (args.len != 2) return f.dg.fail("a malformed `str$cmp` call", .{});
            try f.print("M.zStrCmp(", .{});
            try operand(f, args[0]);
            try f.print(", ", .{});
            try operand(f, args[1]);
            try f.print(")", .{});
        },
        // §3.3 Table 3-3 a string built while the device runs, into this
        // call site's own row.
        .@"str$cat" => {
            try f.print("K.str.zStrCat(", .{});
            try row(f, i);
            try f.print(", &.{{", .{});
            for (args, 0..) |a, k| {
                try f.print("{s}", .{if (k == 0) " " else ", "});
                try operand(f, a);
            }
            try f.print(" }})", .{});
        },
        .@"str$repeat" => {
            if (args.len != 2) return f.dg.fail("a malformed `str$repeat` call", .{});
            try f.print("K.str.zStrRepeat(", .{});
            try row(f, i);
            try f.print(", ", .{});
            try f.int(args[0]);
            try f.print(", ", .{});
            try operand(f, args[1]);
            try f.print(")", .{});
        },
        .@"$sformat", .@"$swrite" => if (tag == .@"$sformat" and args.len != 0 and strConst(f, args[0]) == null)
            try formatRt(f, i, args)
        else
            try formatLiteral(f, i, args),
        // §9.5.4.2 "For $sscanf, null characters shall also be considered
        // white space": the `Nul` kernels. The count, then each item by
        // index, each a pure function of the two strings.
        .@"$sscanf" => {
            if (args.len < 2) return f.dg.fail("a malformed `$sscanf` call", .{});
            try f.print("K.str.zScanNulN(", .{});
            try raw(f, args[0]);
            try f.print(", ", .{});
            try raw(f, args[1]);
            try f.print(")", .{});
        },
        .@"scan$item" => try scanItem(f, "zScanNulR", args),
        .@"scan$str" => try scanItem(f, "zScanNulS", args),
        .@"$simparam$str" => try simparamStr(f, args),
        else => return false, // else: not a string call
    }
    return true;
}

/// When `ref` is a `$sscanf` item (`scan$item`) Sema coerces to an integer
/// destination, writes the old `$sscanf$int` item (`zScanNulI`, C's
/// truncation of a real field) and returns true; false otherwise.
pub fn scanInt(f: *Function, ref: Ref) Error!bool {
    const i = ref.toIndex() orelse return false;
    const air = f.dg.air;
    if (air.instructions.items(.tag)[@backingInt(i)] != .call) return false;
    const x = air.extraData(Air.Call, air.instructions.items(.data)[@backingInt(i)].ty_pl.payload);
    if (x.data.callee != @backingInt(SysFn.Tag.@"scan$item")) return false;
    const args: []const Ref = @ptrCast(air.extra[x.end..][0..x.data.args_len]);
    // The real item's own value is read, so it is never an unused local.
    try f.print("si{d}: {{ std.mem.doNotOptimizeAway(v{d}.val()); break :si{d} ", .{ @backingInt(i), @backingInt(i), @backingInt(i) });
    try scanItem(f, "zScanNulI", args);
    try f.print("; }}", .{});
    return true;
}

/// Row `i` of `Device.str_caps`: the most bytes instruction `i`'s string can
/// hold. Fails past what a device can address (the old compile-time E1011).
pub fn capOf(dg: *DeclGen, i: usize) Error!u64 {
    const caps = dg.device.str_caps;
    if (i >= caps.len or caps[i] == 0) return dg.fail("a string with no capacity (instruction {d})", .{i});
    if (caps[i] > Device.str_row_max) return dg.fail("a string row of {d} bytes, more than a device can address", .{caps[i]});
    return caps[i];
}

// ---- private ----

/// Writes a string operand with a literal's bytes as written: a format's
/// `%s` field pads the original bytes before §3.3 removes the NULs, and
/// §9.5.4.2's `$sscanf` reads a NUL as white space.
fn raw(f: *Function, ref: Ref) Error!void {
    if (ref.toIndex()) |i| return f.print("v{d}", .{@backingInt(i)});
    switch (f.dg.ip.indexToKey(ref.toInterned().?)) {
        .str => |t| return f.print("\"{f}\"", .{std.zig.fmtString(f.dg.ip.stringToSlice(t))}),
        else => return f.print("\"\"", .{}), // else: a number read as a string
    }
}

/// Call site `i`'s row of `str_caps[i]` bytes.
fn row(f: *Function, i: u32) Error!void {
    const cap = try capOf(f.dg, i);
    assert(cap >= Device.str_row);
    try f.print("K.str.zSRow({d}, 0, {d})", .{ i, cap });
}

/// The string constant `ref` reads, or null.
fn strConst(f: *const Function, ref: Ref) ?[]const u8 {
    const index = ref.toInterned() orelse return null;
    return switch (f.dg.ip.indexToKey(index)) {
        .str => |t| f.dg.ip.stringToSlice(t),
        else => null, // else: not a string literal
    };
}

/// `scan$item`/`scan$str(call, k)`: item `k` of the `$sscanf` call `call`
/// (its source and format), through `kernel`, under the count: an item the
/// scan never reached is the kernel's zero (0, or ""), and the count is
/// read, so it is never an unused local.
fn scanItem(f: *Function, comptime kernel: []const u8, args: []const Ref) Error!void {
    if (args.len != 2) return f.dg.fail("a malformed scan item", .{});
    const air = f.dg.air;
    const r = args[0].toIndex() orelse return f.dg.fail("a scan item of no scan", .{});
    const rd = air.instructions.items(.data)[@backingInt(r)];
    if (air.instructions.items(.tag)[@backingInt(r)] != .call) return f.dg.fail("a scan item of no scan", .{});
    const rx = air.extraData(Air.Call, rd.ty_pl.payload);
    const max_tag = std.math.maxInt(@typeInfo(SysFn.Tag).@"enum".tag_type);
    if (rx.data.callee > max_tag) return f.dg.fail("a scan item of no scan", .{});
    const scan: SysFn.Tag = @fromBackingInt(@intCast(rx.data.callee));
    if (scan != .@"$sscanf") return f.dg.fail("a call of `{s}`", .{@tagName(scan)});
    const sargs: []const Ref = @ptrCast(air.extra[rx.end..][0..rx.data.args_len]);
    const k = state.intConst(f.dg, args[1]) orelse return f.dg.fail("a scan item at no constant index", .{});
    const zero = comptime if (std.mem.eql(u8, kernel, "zScanNulR")) "0.0" else if (std.mem.eql(u8, kernel, "zScanNulS")) "\"\"" else "0";
    const real = comptime std.mem.eql(u8, kernel, "zScanNulR");
    try f.print("{s}(if (v{d} > {d}) K.str.{s}(", .{ if (real) "S.con" else "", @backingInt(r), k, kernel });
    try raw(f, sargs[0]);
    try f.print(", ", .{});
    try raw(f, sargs[1]);
    try f.print(", {d}) else {s})", .{ k, zero });
}

/// §9.15 Table 9-28 `$simparam$str`: "analysis_type" is the running
/// analysis's `AnalysisKind` spelling and "module" the top module's name, as
/// the old device answered them; "cwd" and "analysis_name" are what the host
/// wrote (`contract.hostString`: its table at the `Model` row's index when
/// nonzero, else the `Instance` slice); any other name "". A name known only
/// at run time is looked up then.
fn simparamStr(f: *Function, args: []const Ref) Error!void {
    if (args.len == 0) return f.dg.fail("a malformed `$simparam$str` call", .{});
    const name = f.dg.ip.stringToSlice(f.dg.device.name);
    if (strConst(f, args[0])) |nm| {
        if (std.mem.eql(u8, nm, "analysis_type")) {
            f.uses.sim = true;
            return f.print("@as([]const u8, @tagName(sim.kind))", .{});
        }
        if (std.mem.eql(u8, nm, "module")) return f.print("@as([]const u8, \"{f}\")", .{std.zig.fmtString(name)});
        if (std.mem.eql(u8, nm, "cwd") or std.mem.eql(u8, nm, "analysis_name")) {
            hostStrings(f);
            return f.print("contract.hostString(model.{0s}_idx__, inst.{0s})", .{nm});
        }
        return f.print("@as([]const u8, \"\")", .{});
    }
    f.uses.sim = true;
    hostStrings(f);
    try f.print("@as([]const u8, if (std.mem.eql(u8, ", .{});
    try operand(f, args[0]);
    try f.print(", \"analysis_type\")) @tagName(sim.kind) else if (std.mem.eql(u8, ", .{});
    try operand(f, args[0]);
    try f.print(", \"module\")) \"{f}\" else ", .{std.zig.fmtString(name)});
    for ([_][]const u8{ "cwd", "analysis_name" }) |field| {
        try f.print("if (std.mem.eql(u8, ", .{});
        try operand(f, args[0]);
        try f.print(", \"{0s}\")) contract.hostString(model.{0s}_idx__, inst.{0s}) else ", .{field});
    }
    try f.print("\"\")", .{});
}

/// The body reads the host's Table 9-28 strings: `Model.cwd_idx__` and
/// `analysis_name_idx__`, `Instance.cwd` and `analysis_name` exist.
fn hostStrings(f: *Function) void {
    f.uses.model = true;
    f.uses.inst = true;
    f.dg.host_strings = true;
}

/// §9.5.3 `$sformat` whose format_string is a string variable: its content
/// walked at run time (`zSFormatRt`), each operand in its own type (the old
/// `emitStringFormatRt`).
fn formatRt(f: *Function, i: u32, args: []const Ref) Error!void {
    try f.print("K.str.zStringStore(K.printf.zSFormatRt(", .{});
    try row(f, i);
    try f.print(", ", .{});
    try operand(f, args[0]);
    try f.print(", \"{f}\", .{{", .{std.zig.fmtString(f.dg.ip.stringToSlice(f.dg.device.name))});
    for (args[1..], 0..) |a, k| {
        try f.print("{s}", .{if (k == 0) " " else ", "});
        if (isStr(f, a)) {
            try f.print("@as([]const u8, ", .{});
            try operand(f, a);
        } else if (f.isIntRef(a)) {
            try f.print("@as(i64, ", .{});
            try f.int(a);
        } else {
            try f.print("@as(f64, (", .{});
            try f.real(a);
            try f.print(").val()", .{});
        }
        try f.print(")", .{});
    }
    try f.print(" }}))", .{});
}

/// §9.5.3 `$swrite`/`$sformat` with a literal format: `buildArgs`'s §9.4.1
/// walk, translated into one `zSFormatRt` format whose automatic fields are
/// written out, then stored with its NULs removed (§3.3) in the call site's
/// row.
fn formatLiteral(f: *Function, i: u32, args: []const Ref) Error!void {
    var fmt: std.ArrayList(u8) = .empty;
    var ops: std.ArrayList(Op) = .empty;
    var k: usize = 0;
    // Each pass consumes at least one argument.
    while (k < args.len) {
        const s = strConst(f, args[k]) orelse {
            try conv(f, &fmt, &ops, args[k], 0, .{});
            k += 1;
            continue;
        };
        k += 1;
        k += try translate(f, s, args[k..], &fmt, &ops);
    }
    assert(k == args.len);
    try f.print("zs{d}: {{ ", .{i});
    for (ops.items, 0..) |o, n| if (o.how == .shortest) try f.print("var zb{d}: [512]u8 = undefined; ", .{n});
    try f.print("break :zs{d} K.str.zStringStore(K.printf.zSFormatRt(", .{i});
    try row(f, i);
    try f.print(", \"{f}\", \"{f}\", .{{", .{ std.zig.fmtString(fmt.items), std.zig.fmtString(f.dg.ip.stringToSlice(f.dg.device.name)) });
    for (ops.items, 0..) |o, n| {
        try f.print("{s}", .{if (n == 0) " " else ", "});
        try renderOp(f, o, n);
    }
    try f.print(" }})); }}", .{});
}

/// The old `translateFormat`: format literal `src` over `operands`,
/// appended to `fmt` and `ops`. Returns how many operands it consumed.
fn translate(f: *Function, src: []const u8, operands: []const Ref, fmt: *std.ArrayList(u8), ops: *std.ArrayList(Op)) Error!usize {
    const a = f.dg.arena;
    var next: usize = 0;
    var j: usize = 0;
    // Each pass consumes at least one byte of `src`.
    while (j < src.len) {
        const c = src[j];
        j += 1;
        if (c != '%') {
            try fmt.append(a, c);
            continue;
        }
        if (j >= src.len) break;
        if (src[j] == '%') { // §9.4.3 `%%` is a literal percent
            try fmt.appendSlice(a, "%%");
            j += 1;
            continue;
        }
        var spec: Spec = .{};
        while (j < src.len) : (j += 1) spec.flags |= str_real.zcFlag(src[j]) orelse break;
        while (j < src.len and std.ascii.isDigit(src[j])) : (j += 1) spec.width = spec.width *| 10 +| (src[j] - '0');
        if (j < src.len and src[j] == '.') {
            j += 1;
            var p: u64 = 0;
            while (j < src.len and std.ascii.isDigit(src[j])) : (j += 1) p = p *| 10 +| (src[j] - '0');
            spec.prec = p;
        }
        if (j >= src.len) break;
        const letter = src[j];
        j += 1;
        // §9.4.3 `%m` and `%l` consume no operand: the module, and
        // "library.cell" in library work (IEEE 1364-2005 §13.2.1).
        switch (letter) {
            'm', 'M', 'l', 'L' => {
                if (letter == 'l' or letter == 'L') try fmt.appendSlice(a, "work.");
                for (f.dg.ip.stringToSlice(f.dg.device.name)) |ch| {
                    if (ch == '%') try fmt.append(a, '%');
                    try fmt.append(a, ch);
                }
                continue;
            },
            else => {}, // else: a conversion that consumes an operand
        }
        const v: Ref = if (next < operands.len) operands[next] else .none;
        next += 1;
        try conv(f, fmt, ops, v, letter, spec);
    }
    return @min(next, operands.len);
}

/// The old `appendConv`: one conversion (`letter` 0: the operand's default)
/// of `v` (`.none`: the real 0 of a missing operand).
fn conv(f: *Function, fmt: *std.ArrayList(u8), ops: *std.ArrayList(Op), v: Ref, letter: u8, spec_in: Spec) Error!void {
    const a = f.dg.arena;
    const kind: enum { int, real, str } = if (v == .none) .real else if (isStr(f, v)) .str else if (f.isIntRef(v)) .int else .real;
    const rec = if (v == .none) null else widthRecord(f, v);
    const bits: u7 = if (rec) |r| r.bits else 64;
    const lower = std.ascii.toLower(letter);
    // §9.4.3 a bare integer is "the default decimal format", `%d`'s field.
    if (lower == 0 and kind == .int) return conv(f, fmt, ops, v, 'd', spec_in);
    var spec = spec_in;
    // IEEE 1364 §17.1.1.3 automatic sizing, unless a flag or width says otherwise.
    const zc = str_real;
    if (spec.width == 0 and spec.flags & (zc.zc_zero | zc.zc_left | zc.zc_plus | zc.zc_space) == 0) switch (lower) {
        'h', 'x' => if (rec != null) {
            spec = .{ .width = (@as(u64, bits) + 3) / 4, .flags = zc.zc_zero };
        },
        'o' => if (rec != null) {
            spec = .{ .width = (@as(u64, bits) + 2) / 3, .flags = zc.zc_zero };
        },
        'b' => if (rec != null) {
            spec = .{ .width = bits, .flags = zc.zc_zero };
        },
        'd' => if (decimalCols(kind == .real, rec)) |cols| {
            spec = .{ .width = cols };
        },
        else => {},
    };
    switch (lower) {
        'e', 'f', 'g', 'r' => {
            if (kind == .str) return f.dg.fail("`%{c}` of a string", .{letter});
            try spell(a, fmt, spec, true, letter);
            try ops.append(a, .{ .ref = v, .how = .real });
        },
        'b', 'o', 'h', 'x' => {
            try spell(a, fmt, .{ .flags = spec.flags & (zc.zc_zero | zc.zc_left), .width = spec.width }, false, lower);
            try ops.append(a, .{ .ref = v, .how = .int, .bits = bits });
        },
        'c' => {
            try spell(a, fmt, .{ .flags = spec.flags & zc.zc_left, .width = spec.width }, false, 'c');
            try ops.append(a, .{ .ref = v, .how = .int });
        },
        's' => {
            try spell(a, fmt, .{ .flags = spec.flags & zc.zc_left, .width = spec.width }, false, 's');
            try ops.append(a, .{ .ref = v, .how = if (kind == .str) .str else .int, .bits = bits });
        },
        'd' => {
            try spell(a, fmt, .{ .flags = spec.flags, .width = spec.width }, false, 'd');
            try ops.append(a, .{ .ref = v, .how = .int });
        },
        0 => switch (kind) {
            .str => {
                try fmt.appendSlice(a, "%s");
                try ops.append(a, .{ .ref = v, .how = .str });
            },
            // A bare real prints its shortest round trip (the old deviation).
            else => {
                try fmt.appendSlice(a, "%s");
                try ops.append(a, .{ .ref = v, .how = .shortest });
            },
        },
        else => return f.dg.fail("a `%{c}` conversion in a string writer", .{letter}),
    }
}

/// Appends `%[flags][width][.precision]letter`; `prec` only where `zCReal`
/// reads it.
fn spell(a: std.mem.Allocator, fmt: *std.ArrayList(u8), spec: Spec, prec: bool, letter: u8) Error!void {
    try fmt.append(a, '%');
    const zc = str_real;
    if (spec.flags & zc.zc_left != 0) try fmt.append(a, '-');
    if (spec.flags & zc.zc_plus != 0) try fmt.append(a, '+');
    if (spec.flags & zc.zc_space != 0) try fmt.append(a, ' ');
    if (spec.flags & zc.zc_zero != 0) try fmt.append(a, '0');
    if (spec.flags & zc.zc_alt != 0) try fmt.append(a, '#');
    var buf: [24]u8 = undefined;
    if (spec.width != 0) try fmt.appendSlice(a, std.fmt.bufPrint(&buf, "{d}", .{spec.width}) catch unreachable);
    if (prec) if (spec.prec) |p| try fmt.appendSlice(a, std.fmt.bufPrint(&buf, ".{d}", .{p}) catch unreachable);
    try fmt.append(a, letter);
}

/// IEEE 1364 §17.1.1.3's automatic decimal field (the old `decimalField`):
/// a real's 64 signed bits, an integer's recorded width; null for one column
/// or no record.
fn decimalCols(real: bool, rec: ?Width) ?u64 {
    const r: Width = if (real) .{ .bits = 64, .signed = true } else rec orelse return null;
    const most: u64 = if (r.signed) @as(u64, 1) << @intCast(r.bits - 1) else @as(u64, std.math.maxInt(u64)) >> @intCast(@as(u8, 64) - r.bits);
    const cols = std.math.log10_int(most) + 1 + @intFromBool(r.signed);
    assert(cols >= 1 and cols <= 20);
    return if (cols > 1) cols else null;
}

/// The width Sema recorded on a format operand (`display$width(v, bits[,
/// signed])`), or null.
fn widthRecord(f: *const Function, v: Ref) ?Width {
    const i = v.toIndex() orelse return null;
    const air = f.dg.air;
    if (air.instructions.items(.tag)[@backingInt(i)] != .call) return null;
    const x = air.extraData(Air.Call, air.instructions.items(.data)[@backingInt(i)].ty_pl.payload);
    if (x.data.callee != @backingInt(SysFn.Tag.@"display$width")) return null;
    if (x.data.args_len < 2) return null;
    const args: []const Ref = @ptrCast(air.extra[x.end..][0..x.data.args_len]);
    const bits = state.intConst(f.dg, args[1]) orelse return null;
    if (bits < 1 or bits > 64) return null;
    const signed = args.len == 3 and (state.intConst(f.dg, args[2]) orelse 0) != 0;
    return .{ .bits = @intCast(bits), .signed = signed };
}

/// Writes operand `n` of the tuple, in the type `zSFormatRt` reads it in.
fn renderOp(f: *Function, o: Op, n: usize) Error!void {
    switch (o.how) {
        .real => {
            if (o.ref == .none) return f.print("@as(f64, 0.0)", .{});
            if (f.isIntRef(o.ref)) {
                try f.print("@as(f64, @floatFromInt(", .{});
                try f.int(o.ref);
                return f.print("))", .{});
            }
            try f.print("@as(f64, (", .{});
            try f.real(o.ref);
            try f.print(").val())", .{});
        },
        .str => {
            try f.print("@as([]const u8, ", .{});
            try raw(f, o.ref);
            try f.print(")", .{});
        },
        .shortest => {
            try f.print("@as([]const u8, std.fmt.bufPrint(&zb{d}, \"{{d}}\", .{{", .{n});
            if (o.ref == .none) try f.print("@as(f64, 0.0)", .{}) else {
                try f.print("(", .{});
                try f.real(o.ref);
                try f.print(").val()", .{});
            }
            try f.print("}}) catch unreachable)", .{});
        },
        .int => {
            if (o.bits < 64) try f.print("@as(i64, @as(u{d}, @truncate(@as(u64, @bitCast(", .{o.bits}) else try f.print("@as(i64, ", .{});
            try intOf(f, o.ref);
            try f.print("{s}", .{if (o.bits < 64) ")))))" else ")"});
        },
    }
}

/// Operand `ref` as an `i64` (the old `renderVal(.int)`): an integer, a real
/// rounded (`zRoundI`), a string literal's §2.7 value, any other string 0.
fn intOf(f: *Function, ref: Ref) Error!void {
    if (ref == .none) return f.print("@as(i64, 0)", .{});
    if (isStr(f, ref)) return f.print("@as(i64, {d})", .{if (strConst(f, ref)) |s| strToInt(s) else 0});
    if (f.isIntRef(ref)) return f.int(ref);
    try f.print("M.zRoundI(S, ", .{});
    try f.real(ref);
    try f.print(")", .{});
}

test strToInt {
    // §2.7: "\n" is 10, "AB" 0x4142, nine bytes keep the last eight.
    try std.testing.expectEqual(@as(i64, 10), strToInt("\n"));
    try std.testing.expectEqual(@as(i64, 0x4142), strToInt("AB"));
    try std.testing.expectEqual(@as(i64, 0x4243444546474849), strToInt("ABCDEFGHI"));
    try std.testing.expectEqual(@as(i64, 0), strToInt(""));
}

test decimalCols {
    // IEEE 1364 §17.1.1.3: an `integer` is 11 columns, a real 20, one bit none.
    try std.testing.expectEqual(@as(?u64, 11), decimalCols(false, .{ .bits = 32, .signed = true }));
    try std.testing.expectEqual(@as(?u64, 20), decimalCols(true, null));
    try std.testing.expectEqual(@as(?u64, null), decimalCols(false, .{ .bits = 1, .signed = false }));
    try std.testing.expectEqual(@as(?u64, null), decimalCols(false, null));
}
