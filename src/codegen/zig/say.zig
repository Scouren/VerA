//! §9.4 the display tasks as records (`contract.SaySite`, `contract.Say`):
//! each `$strobe`/`$display`/`$write`/`$debug`/`$warning`/`$info` row of
//! `Device.displays` whose values are numbers -> one `say_sites` entry (one
//! C-style format over the recorded values) and, in `say`, a second body
//! over the same Air that records it where it runs (the old device's
//! `.record` mode, `src/codegen/device/cg_say.zig`, so the formats and
//! records are the old ones). `core` never runs a print; `say` never
//! writes state.
//! Cites: VAMS-2023 §9.4.1 (`$debug` per iteration, `$display` as
//! `$strobe`), §9.4.3 (the format), §9.4.6 (output at an accepted point),
//! §9.7.3 (`$warning`/`$info`'s severity word); IEEE 1364-2005 §17.1.1.3
//! (a decimal field sized automatically).
//!
//! Contents:
//! - `pub const Site = struct`
//! - `pub fn plan(dg: *DeclGen) DeclGen.Error!void`
//! - `pub const Body = struct`, `pub fn genBody(dg: *DeclGen) DeclGen.Error!Body`
//! - `pub fn genEntries(dg: *DeclGen, w: *std.Io.Writer, b: Body) DeclGen.Error!void`
//! - `pub fn record(f: *Function, inst: Air.Inst.Index) DeclGen.Error!void`
//! - `pub fn strConst(dg: *DeclGen, ref: Ref) ?[]const u8`
//! - `pub fn format(dg: *DeclGen, args: []const Ref, fmt: *std.ArrayList(u8), vals: *std.ArrayList(Ref)) DeclGen.Error!bool`

const std = @import("std");
const assert = std.debug.assert;
const Air = @import("air");
const InternPool = @import("intern_pool");
const SysFn = @import("vams").SysFn;
const zcFlag = @import("contract").str_real.zcFlag;
const DeclGen = @import("DeclGen.zig");
const Function = @import("Function.zig");
const Liveness = @import("Liveness.zig");
const state = @import("state.zig");
const Ref = Air.Inst.Ref;
const Error = DeclGen.Error;

/// One recorded display task.
pub const Site = struct {
    call: Air.Inst.Index,
    /// The C-style format over `vals` (`contract.SaySite.fmt`).
    fmt: []const u8,
    /// The operands a record carries, in format order.
    vals: []const Ref,
    /// §9.4.1 `$debug`: `Say.putDebug`.
    debug: bool,
};

/// Fills `dg.say_sites` in source order and `dg.say_live`, the liveness of
/// the body with those calls as effects. A task with a value that is no
/// number (a string that is not a constant) records nothing, as the old
/// device's W0850.
pub fn plan(dg: *DeclGen) Error!void {
    const d = dg.device;
    var sites: std.ArrayList(Site) = .empty;
    for (d.displays.items(.name), d.displays.items(.call)) |n, call| {
        const tag = SysFn.Tag.fromName(dg.ip.stringToSlice(n)) orelse continue;
        if (!records(tag)) continue;
        var fmt: std.ArrayList(u8) = .empty;
        var vals: std.ArrayList(Ref) = .empty;
        // §9.7.3: the severity is the message's reason for existing.
        switch (tag) {
            .@"$warning" => try fmt.appendSlice(dg.arena, "WARNING: "),
            .@"$info" => try fmt.appendSlice(dg.arena, "INFO: "),
            else => {}, // else: a plain print
        }
        const x = dg.air.extraData(Air.Call, dg.air.instructions.items(.data)[@backingInt(call)].ty_pl.payload);
        const args: []const Ref = @ptrCast(dg.air.extra[x.end..][0..x.data.args_len]);
        if (!try format(dg, args, &fmt, &vals)) continue;
        // §9.4.1: `$write` is the member that does not end the line.
        if (tag != .@"$write") try fmt.append(dg.arena, '\n');
        try sites.append(dg.arena, .{ .call = call, .fmt = fmt.items, .vals = vals.items, .debug = tag == .@"$debug" });
    }
    dg.say_sites = sites.items;
    if (sites.items.len == 0) return;
    const roots = try dg.arena.alloc(bool, dg.air.instructions.len);
    @memset(roots, false);
    for (sites.items) |s| roots[@backingInt(s.call)] = true;
    dg.say_live = Liveness.init(dg.arena, dg.air.*, @intCast(dg.device.nodes.len), roots, dg.device.arrays.items) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooManyUnknowns => unreachable, // `dg.live` was built over the same unknowns
    };
}

/// `say`'s statements and what they read.
pub const Body = struct { text: []const u8 = "", uses: Function.Uses = .{} };

/// `say`'s statements, empty when no task records.
pub fn genBody(dg: *DeclGen) Error!Body {
    if (dg.say_sites.len == 0) return .{};
    const core_live = dg.live;
    dg.live = dg.say_live;
    defer dg.live = core_live;
    var body: std.Io.Writer.Allocating = .init(dg.arena);
    var f: Function = .{ .dg = dg, .w = &body.writer, .phase = .say };
    try f.genBody(dg.air.mainBody());
    return .{ .text = body.written(), .uses = f.uses };
}

/// `say_sites` and `say` (`b`, from `genBody`) when a task records.
pub fn genEntries(dg: *DeclGen, w: *std.Io.Writer, b: Body) Error!void {
    if (dg.say_sites.len == 0) return;
    try dg.print(w, "\n/// §9.4 the display tasks `say` records, in source order.\npub const say_sites = [_]contract.SaySite{{\n", .{});
    for (dg.say_sites) |s| try dg.print(w, "    .{{ .fmt = \"{f}\", .file = \"\", .line = 0, .nargs = {d} }},\n", .{ std.zig.fmtString(s.fmt), s.vals.len });
    try dg.print(w, "}};\n", .{});
    const f = b;
    const tables = dg.table_len.len != 0;
    try dg.print(w, "\n/// §9.4 the body once more at an accepted point, recording each display\n/// task that runs into `out` (`contract.formatSay` renders them).\npub fn say(comptime S: type, {s}: *const [n_u]S.V, {s}: *const Model, {s}: InstancePtr, {s}: contract.SimState, out: *contract.Say) void {{\n    @setFloatMode(.strict);{s}{s}{s}\n}}\n", .{
        if (f.uses.x) "x_in" else "_",
        if (f.uses.model) "model" else "_",
        if (f.uses.inst or tables) "inst" else "_",
        if (f.uses.sim) "sim" else "_",
        if (f.uses.x) "\n    const x = D.zProbe(S, x_in);" else "",
        if (tables) "\n    inst.table_ready = inst.table_kept;" else "",
        b.text,
    });
}

/// Writes display call `inst`'s record into `out`, or nothing when it is
/// not a site.
pub fn record(f: *Function, inst: Air.Inst.Index) Error!void {
    assert(f.phase == .say);
    const k = for (f.dg.say_sites, 0..) |s, j| {
        if (s.call == inst) break j;
    } else return;
    const s = f.dg.say_sites[k];
    try f.line();
    try f.print("out.{s}({d}, &.{{", .{ if (s.debug) "putDebug" else "put", k });
    for (s.vals, 0..) |v, i| {
        try f.print("{s}", .{if (i == 0) " " else ", "});
        if (f.isIntRef(v)) {
            try f.print("@as(f64, @floatFromInt(", .{});
            try f.int(v);
            try f.print("))", .{});
        } else {
            try f.print("(", .{});
            try f.real(v);
            try f.print(").val()", .{});
        }
    }
    try f.print(" }});", .{});
}

/// §9.4.1's argument list as one C-style format over recorded numbers (the
/// old `sayFormat`): a string argument is a format whose conversions take
/// the arguments after it, a constant string under `%s` is spliced in as
/// text; an argument no format took is `%d` (integer) or `%g`, and a bare
/// `%d` gets IEEE 1364's automatic field (`decimal`). False when a value
/// has no numeric record. Shared with `status.zig` (§9.7.3's `$fatal`/
/// `$error` render their message by the same rules, `contract.formatStatus`
/// over `contract.formatC`).
/// Whether `ref` is a string literal, as the text; null for anything else
/// (shared with `status.zig`: §9.7.3's `finish_number` is the one argument
/// before the message `$fatal` allows).
pub fn strConst(dg: *DeclGen, ref: Ref) ?[]const u8 {
    const i = ref.toInterned() orelse return null;
    return switch (dg.ip.indexToKey(i)) {
        .str => |s| dg.ip.stringToSlice(s),
        else => null, // else: not a string literal
    };
}

pub fn format(dg: *DeclGen, args: []const Ref, fmt: *std.ArrayList(u8), vals: *std.ArrayList(Ref)) Error!bool {
    const a = dg.arena;
    var i: usize = 0;
    // Each pass consumes at least one argument.
    while (i < args.len) {
        const s = strConst(dg, args[i]) orelse {
            if (isString(dg, args[i])) return false;
            if (isIntRef(dg, args[i])) try decimal(dg, fmt, args[i]) else try fmt.appendSlice(a, "%g");
            try vals.append(a, args[i]);
            i += 1;
            continue;
        };
        i += 1;
        var j: usize = 0;
        while (j < s.len) : (j += 1) {
            if (s[j] != '%' or j + 1 == s.len) {
                try fmt.append(a, s[j]);
                continue;
            }
            const start = j;
            j += 1;
            while (j < s.len and (std.ascii.isDigit(s[j]) or s[j] == '.' or zcFlag(s[j]) != null)) j += 1;
            if (j == s.len) {
                try fmt.appendSlice(a, s[start..]);
                break;
            }
            const conv = std.ascii.toLower(s[j]);
            if (conv == '%' or conv == 'm') {
                try fmt.appendSlice(a, s[start .. j + 1]);
                continue;
            }
            if (conv == 'l') return dg.fail("a `%l` in a display task (the library cell name)", .{});
            // A conversion with no operand renders 0, the old answer.
            if (i == args.len) {
                try fmt.appendSlice(a, s[start .. j + 1]);
                continue;
            }
            const v = args[i];
            i += 1;
            if (conv == 's') {
                const text = strConst(dg, v) orelse return false;
                for (text) |ch| {
                    if (ch == '%') try fmt.append(a, '%');
                    try fmt.append(a, ch);
                }
                continue;
            }
            // A number, or §2.7 a string literal's integer.
            if (isString(dg, v) and strConst(dg, v) == null) return false;
            if (conv == 'd' and j == start + 1) try decimal(dg, fmt, v) else try fmt.appendSlice(a, s[start .. j + 1]);
            try vals.append(a, v);
        }
    }
    assert(i == args.len);
    return true;
}

// ---- private ----

/// Whether task `tag` is a record: §9.4.1's printing tasks and
/// `$warning`/`$info`, not `$monitor` (its change detection is state a
/// device does not keep) nor `$fatal`/`$error` (the status channel).
fn records(tag: SysFn.Tag) bool {
    if (SysFn.get(tag).family != .display) return false;
    return switch (tag) {
        .@"$monitor", .@"$fatal", .@"$error" => false,
        else => true, // else: a plain text record
    };
}

/// `%d` with IEEE 1364 §17.1.1.3's automatic field, as wide as the
/// operand's largest value (the old `decimalField`): a real's 64 signed
/// bits (`%20d`); an integer's from its `display$width(v, bits, signed)`
/// marker, none without one (a 1-bit result).
fn decimal(dg: *DeclGen, fmt: *std.ArrayList(u8), v: Ref) Error!void {
    // §2.7 a string's integer has no fixed width.
    if (isString(dg, v)) return fmt.appendSlice(dg.arena, "%d");
    if (!isIntRef(dg, v)) return fmt.appendSlice(dg.arena, "%20d");
    const bits: u7, const signed = if (comptime has_width_tag) blk: {
        const m = widthOf(dg, v) orelse return fmt.appendSlice(dg.arena, "%d");
        break :blk m;
    } else if (oneBit(dg, v)) return fmt.appendSlice(dg.arena, "%d") else .{ 32, true };
    const cols = fieldCols(bits, signed);
    if (cols == 1) return fmt.appendSlice(dg.arena, "%d");
    var buf: [8]u8 = undefined;
    try fmt.appendSlice(dg.arena, std.fmt.bufPrint(&buf, "%{d}d", .{cols}) catch unreachable);
}

/// Whether Sema marks a print operand's width (rw-lower's `display$width`).
const has_width_tag = @hasField(SysFn.Tag, "display$width");

/// `(bits, signed)` of `v`'s three-argument `display$width` marker, or null.
fn widthOf(dg: *DeclGen, v: Ref) ?struct { u7, bool } {
    const i = v.toIndex() orelse return null;
    if (dg.air.instructions.items(.tag)[@backingInt(i)] != .call) return null;
    const x = dg.air.extraData(Air.Call, dg.air.instructions.items(.data)[@backingInt(i)].ty_pl.payload);
    if (x.data.callee > std.math.maxInt(@typeInfo(SysFn.Tag).@"enum".tag_type)) return null;
    const tag: SysFn.Tag = @fromBackingInt(@intCast(x.data.callee));
    if (!std.mem.eql(u8, @tagName(tag), "display$width") or x.data.args_len != 3) return null;
    const args: []const Ref = @ptrCast(dg.air.extra[x.end..][0..3]);
    const bits = state.intConst(dg, args[1]) orelse return null;
    const signed = state.intConst(dg, args[2]) orelse return null;
    if (bits < 1 or bits > 64) return null;
    return .{ @intCast(bits), signed != 0 };
}

/// The columns of the largest value of a `bits`-wide integer, its sign
/// included (the old `cg_format.fieldCols`).
fn fieldCols(bits: u7, signed: bool) usize {
    assert(bits >= 1 and bits <= 64);
    const most: u64 = if (signed) @as(u64, 1) << @intCast(bits - 1) else @as(u64, std.math.maxInt(u64)) >> @intCast(@as(u8, 64) - bits);
    return std.math.log10_int(most) + 1 + @intFromBool(signed);
}

test fieldCols {
    // IEEE 1364 §17.1.1.3: an `integer` is 11 columns, a real's 64 signed
    // bits 20, one unsigned bit 1.
    try std.testing.expectEqual(@as(usize, 11), fieldCols(32, true));
    try std.testing.expectEqual(@as(usize, 20), fieldCols(64, true));
    try std.testing.expectEqual(@as(usize, 1), fieldCols(1, false));
}

/// Until Sema marks widths: a comparison or logical result is one bit, and
/// so, most often, is a folded constant (a check's `ok`).
fn oneBit(dg: *DeclGen, v: Ref) bool {
    // ponytail: a guess; goes when `display$width` lands (`has_width_tag`).
    const i = v.toIndex() orelse return true;
    return switch (dg.air.instructions.items(.tag)[@backingInt(i)]) {
        .flt, .fgt, .fle, .fge, .feq, .fne, .ilt, .igt, .ile, .ige, .ieq, .ine, .logand, .logor, .lognot => true,
        else => false, // else: an `integer`
    };
}

fn isString(dg: *DeclGen, ref: Ref) bool {
    return dg.air.typeOf(dg.ip, ref) == InternPool.Index.string_type;
}

fn isIntRef(dg: *DeclGen, ref: Ref) bool {
    return Function.isInt(dg.ip, dg.air.typeOf(dg.ip, ref));
}
