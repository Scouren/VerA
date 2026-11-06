//! Display formats of the digital lowering: a display call's arguments ->
//! `Program.Piece` rows, every literal format parsed once (§17.1.1's
//! conversions, `%m`'s scope, `%l`'s library cell, `%v`'s net, a bare
//! argument's radix; a `$sformat` format that is no literal read at each
//! call), and lib/sim/digital's refusals of a format, under its codes.
//! Cites: IEEE 1364-2005 §9.4.1, §17.1.1, §17.1.1.2, §17.1.1.5, §17.1.1.6.
//!
//! Contents:
//! - `pub const Show = struct`
//! - `pub fn show(l: *Lower, call: Inst.Index, args: []const Inst.Ref, sh: Show, pc: u32, only_first: bool) Error!u32`
//! - `pub fn add(l: *Lower, p: Program.Piece) Error!u32`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const std_sim = @import("std_sim");
const kernels = @import("kernels");
const digital = @import("../digital.zig");
const expr = @import("expr.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const none = digital.none;
const Program = std_sim.Program;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// A display task's default radix and whether it ends its line.
pub const Show = struct { radix: Program.Radix, newline: bool };

/// The `Program.Show` of system task call `call`'s arguments `args` (a
/// suffix of its argument list), its `%m` naming the blocks around `pc`.
/// With `only_first` (`$sformat`) the first argument is the one format,
/// read at each call when it is no literal.
pub fn show(l: *Lower, call: Inst.Index, args: []const Inst.Ref, sh: Show, pc: u32, only_first: bool) Error!u32 {
    const vir = l.virOf(l.frame);
    const all = vir.list(Inst.Ref, Lower.payload(vir, Inst.SysCall, call).args);
    assert(args.len <= all.len and args.ptr == all.ptr + (all.len - args.len));
    var pieces: std.ArrayList(u32) = .empty;
    var arg: usize = 0;
    while (arg < args.len) : (arg += 1) {
        const e = args[arg];
        const at = all.len - args.len + arg; // the format's argument position
        if (only_first and arg != 0) return l.refuse("a $sformat argument its format leaves over");
        if (only_first and (e.toIndex() == null or Lower.tag(vir, e.toIndex().?) != .str)) {
            try pieces.append(l.a, try dynamic(l, args, pc));
            break;
        }
        const ei = e.toIndex() orelse {
            try pieces.append(l.a, try add(l, .{ .kind = .space }));
            continue;
        };
        if (Lower.tag(vir, ei) != .str) {
            try pieces.append(l.a, try bare(l, e));
            continue;
        }
        const sd = vir.instructions.items(.data)[@backingInt(ei)].str;
        const format = vir.string_bytes[@backingInt(sd.start)..][0..sd.len];
        var text: std.ArrayList(u8) = .empty;
        var k: usize = 0;
        while (k < format.len) : (k += 1) {
            if (format[k] != '%') {
                try text.append(l.a, format[k]);
                continue;
            }
            k += 1;
            if (k == format.len) return l.rejectArg(l.frame, call, at, "unterminated display format");
            if (format[k] == '%') {
                try text.append(l.a, '%');
                continue;
            }
            const pct = k - 1;
            const sp = kernels.fmt.spec(format, &k);
            if (k == format.len) return l.rejectArg(l.frame, call, at, "unterminated display format");
            const conv = format[k];
            // §17.1.1.2 C's flags where it grants them, then `%%` (lib/sim/digital's order).
            if (conv != '%') switch (kernels.fmt.flagVerdict(sp.flags, conv)) {
                .ok => {},
                .alt => return formatError(l, .E0825, call, at, "`{s}`: '#' is C's alternative form, which IEEE 1364-2005 §17.1.1.2 grants only to %e, %f and %g", .{format[pct .. k + 1]}),
                .c_flag => return formatError(l, .E0827, call, at, "`{s}`: IEEE 1364-2005 §17.1.1.2 grants C's '-', '+' and ' ' flags to the real conversions only", .{format[pct .. k + 1]}),
            };
            if (conv == '%') return formatError(l, .E0826, call, at, "a flag, width or precision before the second `%` of `%%`", .{});
            try flush(l, &text, &pieces);
            const width: u32 = if (sp.width) |w| std.math.cast(u32, w) orelse return l.refuse("a field width past u32") else Program.Piece.none_width;
            const precision = std.math.cast(i32, sp.precision) orelse return l.refuse("a precision past i32");
            switch (conv | 0x20) {
                'm' => {
                    try pieces.append(l.a, try add(l, .{ .kind = .scope, .a = pc }));
                    continue;
                },
                'l' => {
                    const s = try l.b.string(try cellName(l));
                    try pieces.append(l.a, try add(l, .{ .kind = .lib, .a = s.start, .width = s.len }));
                    continue;
                },
                'v' => {
                    arg += 1;
                    const v = try operand(l, call, at, args, arg);
                    if ((try expr.typeOf(l, v)).width != 1) return l.reject(l.frame, v, "§17.1.1.5: %v takes a scalar net reference");
                    try pieces.append(l.a, try add(l, .{ .kind = .strength, .a = try expr.self_(l, v, 0), .b = try netOf(l, v) }));
                    continue;
                },
                else => {},
            }
            arg += 1;
            const a = try operand(l, call, at, args, arg);
            const row = switch (conv | 0x20) {
                'e', 'f', 'g', 'r' => try expr.real(l, a),
                'b', 'o', 'h', 'x', 'd', 't' => try expr.selfOrReal(l, a),
                's', 'c', 'u', 'z' => try expr.self_(l, a, 0),
                else => return l.refuse("a conversion"),
            };
            try pieces.append(l.a, try add(l, .{ .kind = .spec, .conv = conv, .flags = sp.flags, .width = width, .precision = precision, .a = row }));
        }
        try flush(l, &text, &pieces);
    }
    const list = try l.b.listOf(pieces.items);
    try l.b.shows.append(l.a, .{ .pieces = list, .radix = sh.radix, .newline = sh.newline, .scope = l.frames.items[l.frame].scope });
    return @intCast(l.b.shows.items.len - 1);
}

pub fn add(l: *Lower, p: Program.Piece) Error!u32 {
    try l.b.pieces.append(l.a, p);
    return @intCast(l.b.pieces.items.len - 1);
}

// ---- private ----

/// §17.1.1.5 the net whose signal `%v` of `e` reads (kept current from now
/// on, `strength_read`): a net named alone, else `none`.
fn netOf(l: *Lower, e: Inst.Ref) Error!u32 {
    const n = (try expr.nameOf(l, e)) orelse return none;
    if (n.kind != .net or n.dims.len != 0) return none;
    l.nets.items[n.net].strength_read = true;
    return n.net;
}

/// §17.1.1.6 `%l`: `library.cell` of the module of `Lower.frame`, its
/// library the map's (§13.2.3, `work` without one).
fn cellName(l: *Lower) Error![]const u8 {
    const d = l.zcu.instances.items(.module)[@backingInt(l.frames.items[l.frame].instance)];
    const vir = l.zcu.fileVir(d.file);
    return std.fmt.allocPrint(l.a, "{s}.{s}", .{ l.zcu.libraryOf(d), vir.string(l.zcu.declRow(d).name) });
}

/// A `$sformat` format that is no literal: read at each call, its
/// arguments' rows (and, for `%v`, nets) beside it.
fn dynamic(l: *Lower, args: []const Inst.Ref, pc: u32) Error!u32 {
    var rows: std.ArrayList(u32) = .empty;
    var nets: std.ArrayList(u32) = .empty;
    for (args[1..]) |v| {
        try rows.append(l.a, if (v == .none) none else try expr.selfOrReal(l, v));
        try nets.append(l.a, if (v == .none) none else try netOf(l, v));
    }
    const d = try l.b.extraOf(Program.Dynamic{
        .format = try expr.self_(l, args[0], 0),
        .args = try l.b.listOf(rows.items),
        .nets = try l.b.listOf(nets.items),
        .pc = pc,
        .lib = try l.b.string(try cellName(l)),
    });
    return add(l, .{ .kind = .dynamic, .a = d });
}

/// An argument with no format: the task's radix, or a real's `%#g`
/// (`$realtime` alone in `%.Nf`, N its module's precision digits).
fn bare(l: *Lower, e: Inst.Ref) Error!u32 {
    const vir = l.virOf(l.frame);
    if (!(try expr.typeOf(l, e)).real) return add(l, .{ .kind = .bare, .a = try expr.self_(l, e, 0) });
    var precision: i32 = -1;
    const i = e.toIndex().?;
    if (Lower.tag(vir, i) == .call_sys and std.mem.eql(u8, vir.string(Lower.payload(vir, Inst.SysCall, i).name), "$realtime")) {
        const scope = l.frames.items[l.frame].scope;
        precision = @intCast(std.math.log10_int(@as(u64, l.b.times.items[scope].scale.local_per_unit)));
    }
    return add(l, .{ .kind = .bare_real, .precision = precision, .a = try expr.real(l, e) });
}

fn flush(l: *Lower, text: *std.ArrayList(u8), pieces: *std.ArrayList(u32)) Error!void {
    if (text.items.len == 0) return;
    const s = try l.b.string(text.items);
    try pieces.append(l.a, try add(l, .{ .kind = .text, .a = s.start, .width = s.len }));
    text.clearRetainingCapacity();
}

/// `args[arg]`, the argument a specifier of the format at call `call`'s
/// argument `at` consumes; lib/sim/digital's refusal, at that format, when
/// there is none or it is null.
fn operand(l: *Lower, call: Inst.Index, at: usize, args: []const Inst.Ref, arg: usize) Error!Inst.Ref {
    assert(arg <= args.len);
    assert(arg > 0); // the format itself comes first
    if (arg == args.len) return l.rejectArg(l.frame, call, at, "missing display argument");
    if (args[arg] == .none) return l.rejectArg(l.frame, call, at, "§17.1.1.2: a format specification's argument is an expression, not a null argument");
    return args[arg];
}

/// lib/sim/digital's `code` refusal of the format at call `call`'s
/// argument `at`, its message formatted.
fn formatError(l: *Lower, code: vams.Diag.Code, call: Inst.Index, at: usize, comptime fmt: []const u8, args: anytype) Error {
    assert(code != .E1100); // E1100's refusals take `rejectArg`
    l.why_code = code;
    return l.rejectArgFmt(l.frame, call, at, fmt, args);
}
