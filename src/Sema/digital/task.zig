//! System tasks of the digital lowering: a statement-level `call_sys` in
//! `Lower.frame` -> one `.task` instruction and its `Program.Task`, every
//! display format parsed once into `Program.Piece` rows (§17.1.1's
//! conversions, `%m`'s scope, a bare argument's radix).
//! Cites: IEEE 1364-2005 §9.4.1, §17.1.1, §17.1.2, §17.1.3, §17.3.2,
//! §17.4.1.
//!
//! Contents:
//! - `pub fn task(l: *Lower, i: Inst.Index) Error!void`

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

const Show = struct { radix: Program.Radix, newline: bool };
const Kind = union(enum) { show: Show, strobe: Show, monitor: Show, monitor_on, monitor_off, finish, stop, timeformat };

const tasks = std.StaticStringMap(Kind).initComptime(.{
    .{ "$display", Kind{ .show = .{ .radix = .decimal, .newline = true } } },
    .{ "$displayb", Kind{ .show = .{ .radix = .binary, .newline = true } } },
    .{ "$displayo", Kind{ .show = .{ .radix = .octal, .newline = true } } },
    .{ "$displayh", Kind{ .show = .{ .radix = .hex, .newline = true } } },
    .{ "$write", Kind{ .show = .{ .radix = .decimal, .newline = false } } },
    .{ "$writeb", Kind{ .show = .{ .radix = .binary, .newline = false } } },
    .{ "$writeo", Kind{ .show = .{ .radix = .octal, .newline = false } } },
    .{ "$writeh", Kind{ .show = .{ .radix = .hex, .newline = false } } },
    .{ "$strobe", Kind{ .strobe = .{ .radix = .decimal, .newline = true } } },
    .{ "$strobeb", Kind{ .strobe = .{ .radix = .binary, .newline = true } } },
    .{ "$strobeo", Kind{ .strobe = .{ .radix = .octal, .newline = true } } },
    .{ "$strobeh", Kind{ .strobe = .{ .radix = .hex, .newline = true } } },
    .{ "$monitor", Kind{ .monitor = .{ .radix = .decimal, .newline = true } } },
    .{ "$monitorb", Kind{ .monitor = .{ .radix = .binary, .newline = true } } },
    .{ "$monitoro", Kind{ .monitor = .{ .radix = .octal, .newline = true } } },
    .{ "$monitorh", Kind{ .monitor = .{ .radix = .hex, .newline = true } } },
    .{ "$monitoron", Kind.monitor_on },
    .{ "$monitoroff", Kind.monitor_off },
    .{ "$finish", Kind.finish },
    .{ "$stop", Kind.stop },
    .{ "$timeformat", Kind.timeformat },
});

/// Appends the `.task` instruction of system task call `i`.
pub fn task(l: *Lower, i: Inst.Index) Error!void {
    const vir = l.virOf(l.frame);
    const c = Lower.payload(vir, Inst.SysCall, i);
    const name = vir.string(c.name);
    const args = vir.list(Inst.Ref, c.args);
    const scope = l.frames.items[l.frame].scope;
    const at: u32 = @intCast(l.b.p.insts.len);
    const kind = tasks.get(name) orelse return l.refuseFmt("the system task `{s}`", .{name});
    const t: Program.Task = switch (kind) {
        .show => |sh| .{ .kind = .show, .a = try show(l, args, sh, at) },
        .strobe => |sh| .{ .kind = .strobe, .a = try show(l, args, sh, at) },
        .monitor => |sh| .{ .kind = .monitor, .a = try monitor(l, args, sh, at) },
        .monitor_on => .{ .kind = .monitor_on, .a = 0 },
        .monitor_off => .{ .kind = .monitor_off, .a = 0 },
        .finish, .stop => blk: {
            if (args.len > 1) return l.refuse("$finish/$stop with more than one argument");
            const verbose: u32 = if (args.len == 0) none else try expr.self_(l, args[0], 0);
            break :blk .{ .kind = if (kind == .stop) .stop else .finish, .a = verbose, .b = try l.b.string(try location(l, i)) };
        },
        .timeformat => blk: {
            if (args.len == 0) break :blk .{ .kind = .timeformat, .a = none };
            if (args.len != 4) return l.refuse("$timeformat with other than four arguments");
            const s = args[2].toIndex() orelse return l.refuse("$timeformat without a suffix");
            if (Lower.tag(vir, s) != .str) return l.refuse("$timeformat with a suffix that is no string literal");
            const sd = vir.instructions.items(.data)[@backingInt(s)].str;
            const tf = try l.b.extraOf(Program.TimeFormat{
                .units = try expr.self_(l, args[0], 0),
                .precision = try expr.self_(l, args[1], 0),
                .suffix = try l.b.string(vir.string_bytes[@backingInt(sd.start)..][0..sd.len]),
                .width = try expr.self_(l, args[3], 0),
                .scope = scope,
            });
            break :blk .{ .kind = .timeformat, .a = tf };
        },
    };
    _ = try l.b.inst(.task, try l.b.extraOf(t), 0, scope);
    assert(l.b.p.insts.len == at + 1);
}

// ---- private ----

/// `$finish`'s location text: the source file and the byte of the call
/// (the old engine's `bag.locate` of its token).
fn location(l: *Lower, i: Inst.Index) Error![]const u8 {
    const src = l.options.sources[@backingInt(l.fileOf(l.frame))];
    const offset = l.srcOffset(l.frame, i);
    const loc = src.pp.resolve(offset);
    if (loc.file == .none) return l.refuse("a $finish with no source location");
    const file = src.pp.files[@backingInt(loc.file)];
    const byte = vams.Preprocessor.toSourceOffset(file.marks, loc.offset);
    return std.fmt.allocPrint(l.a, "{s} byte {d}", .{ file.name, byte });
}

/// The `Program.Show` of a display call's arguments, its `%m` naming the
/// blocks around `pc`.
fn show(l: *Lower, args: []const Inst.Ref, sh: Show, pc: u32) Error!u32 {
    const vir = l.virOf(l.frame);
    var pieces: std.ArrayList(u32) = .empty;
    var arg: usize = 0;
    while (arg < args.len) : (arg += 1) {
        const e = args[arg];
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
            if (k == format.len) return l.refuse("an unterminated format");
            if (format[k] == '%') {
                try text.append(l.a, '%');
                continue;
            }
            const sp = kernels.fmt.spec(format, &k);
            if (k == format.len) return l.refuse("an unterminated format");
            const conv = format[k];
            try flush(l, &text, &pieces);
            const width: u32 = if (sp.width) |w| std.math.cast(u32, w) orelse return l.refuse("a field width past u32") else Program.Piece.none_width;
            const precision = std.math.cast(i32, sp.precision) orelse return l.refuse("a precision past i32");
            switch (conv | 0x20) {
                'm' => {
                    try pieces.append(l.a, try add(l, .{ .kind = .scope, .a = pc }));
                    continue;
                },
                'l', 'v' => return l.refuse("a %l or %v conversion"),
                else => {},
            }
            arg += 1;
            if (arg == args.len or args[arg] == .none) return l.refuse("a format with a missing argument");
            const a = args[arg];
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

fn add(l: *Lower, p: Program.Piece) Error!u32 {
    try l.b.pieces.append(l.a, p);
    return @intCast(l.b.pieces.items.len - 1);
}

/// §17.1.3 the `Program.Monitor` of a `$monitor` call: its show, the
/// arguments compared on a change (no call anywhere in one), the slots
/// every argument reads, and those of the arguments not compared.
fn monitor(l: *Lower, args: []const Inst.Ref, sh: Show, pc: u32) Error!u32 {
    const vir = l.virOf(l.frame);
    const at = try show(l, args, sh, pc);
    var compared: std.ArrayList(u32) = .empty;
    var slots: std.ArrayList(u32) = .empty;
    var loose: std.ArrayList(u32) = .empty;
    for (args) |e| {
        const ei = e.toIndex() orelse continue;
        if (Lower.tag(vir, ei) == .str) continue;
        if (comparable(vir, e)) {
            try compared.append(l.a, try expr.selfOrReal(l, e));
        } else try expr.reads(l, e, &loose);
        try expr.reads(l, e, &slots);
    }
    return l.b.extraOf(Program.Monitor{
        .show = at,
        .compared = try l.b.listOf(compared.items),
        .slots = try l.b.listOf(slots.items),
        .loose = try l.b.listOf(loose.items),
        .fd = none,
    });
}

/// `monitor.comparable`: no clock query or call anywhere in `e`.
fn comparable(vir: *const Vir, e: Inst.Ref) bool {
    const i = e.toIndex() orelse return true;
    const data = vir.instructions.items(.data)[@backingInt(i)];
    return switch (Lower.tag(vir, i)) {
        .int, .big_int, .str, .real, .decl_ref, .str_ref => true,
        .pos, .neg, .not, .bit_not, .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor => comparable(vir, data.un_node.operand),
        .add, .sub, .mul, .div, .mod, .pow, .shl, .shr, .ashl, .ashr, .lt, .gt, .lte, .gte, .eq, .neq, .case_eq, .case_neq, .bit_and, .bit_or, .bit_xor, .bit_xnor, .bool_and, .bool_or, .elem, .replicate => blk: {
            const b = Lower.payload(vir, Inst.Bin, i);
            break :blk comparable(vir, b.lhs) and comparable(vir, b.rhs);
        },
        .ternary, .slice, .slice_up, .slice_down => blk: {
            const t = Lower.payload(vir, Inst.Triple, i);
            break :blk comparable(vir, t.a) and comparable(vir, t.b) and comparable(vir, t.c);
        },
        .concat => for (vir.list(Inst.Ref, Lower.payload(vir, Inst.Refs, i))) |x| {
            if (!comparable(vir, x)) break false;
        } else true,
        else => false, // else: a system or user call
    };
}
