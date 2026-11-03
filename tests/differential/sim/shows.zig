//! The bridge's §17 half: an old `.task` instruction's arguments, in the
//! scope `Run.scope` names, -> a `Program.Show` (the format strings parsed
//! once into `Program.Piece` rows, as lib/sim/digital's `display.walk`
//! reads them at every call) and the `Program.Task` the new engine runs.
//! Test code: Sema replaces it.
//! Cites: IEEE 1364-2005 §9.4.1, §17.1.1, §17.1.3, §17.3.2, §17.4.1.
//!
//! Contents:
//! - `pub fn task(l: *Lower, t: Task, args: []const ExprId, tok: u32, pc: u32) E!u32`

const std = @import("std");
const assert = std.debug.assert;
const sim = @import("sim");
const std_sim = @import("std_sim");
const frontend = @import("frontend");
const kernels = @import("kernels");
const Ast = frontend.Ast;
const ExprId = Ast.ExprId;
const digital = sim.digital;
const compile = digital.for_emitter.compile;
const display = digital.for_emitter.display;
const Program = std_sim.Program;
const Lower = @import("lower.zig").Lower;
const E = @import("lower.zig").E;
const Task = display.Task;

/// The `Program.Task` (in `extra`) of a system task call at `pc`.
pub fn task(l: *Lower, t: Task, args: []const ExprId, tok: u32, pc: u32) E!u32 {
    const r = l.r;
    return switch (t) {
        .show => |sh| l.b.extraOf(Program.Task{ .kind = .show, .a = try show(l, args, sh, pc) }),
        .strobe => |sh| if (sh.file) l.refuse("$fstrobe") else l.b.extraOf(Program.Task{ .kind = .strobe, .a = try show(l, args, sh, pc) }),
        .monitor => |sh| if (sh.file) l.refuse("$fmonitor") else l.b.extraOf(Program.Task{ .kind = .monitor, .a = try monitor(l, args, sh, pc) }),
        .monitor_enable => |on| l.b.extraOf(Program.Task{ .kind = if (on) .monitor_on else .monitor_off, .a = 0 }),
        .finish => |stop| blk: {
            const verbose: u32 = if (args.len == 0) @backingInt(Program.Ref.none) else try l.self_(args[0], 0);
            const start_byte = r.starts[tok];
            const loc = r.bag.locate(.{ .start = start_byte, .end = start_byte }, .none);
            const where = try std.fmt.allocPrint(l.a, "{s} byte {d}", .{ r.bag.fileName(loc.file), loc.offset });
            break :blk l.b.extraOf(Program.Task{ .kind = if (stop) .stop else .finish, .a = verbose, .b = try l.b.string(where) });
        },
        .timeformat => blk: {
            if (args.len == 0) break :blk l.b.extraOf(Program.Task{ .kind = .timeformat, .a = @backingInt(Program.Ref.none) });
            const ex = &r.file.exprs;
            const tf = try l.b.extraOf(Program.TimeFormat{
                .units = try l.self_(args[0], 0),
                .precision = try l.self_(args[1], 0),
                .suffix = try l.b.string(r.file.str(ex.strOf(args[2]))),
                .width = try l.self_(args[3], 0),
                .scope = r.scope,
            });
            break :blk l.b.extraOf(Program.Task{ .kind = .timeformat, .a = tf });
        },
        .readmem => l.refuse("$readmem"),
        .queue => l.refuse("a §17.6 queue task"),
        .pla => l.refuse("a §17.5 PLA task"),
        .fclose, .fflush, .fshow => l.refuse("a §17.2 file task"),
        .sshow, .sformat => l.refuse("$swrite/$sformat"),
        .printtimescale => l.refuse("$printtimescale"),
        .sdf_annotate => l.refuse("$sdf_annotate"),
        .dump => l.refuse("a §18 VCD task"),
        .ports => l.refuse("a §18.3 EVCD task"),
        .user => l.refuse("a PLI task"),
    };
}

// ---- private ----

/// The `Program.Show` of `args` (`display.walk`), whose `%m` names the
/// blocks around `pc`.
fn show(l: *Lower, args: []const ExprId, sh: display.Show, pc: u32) E!u32 {
    const r = l.r;
    const ex = &r.file.exprs;
    var pieces: std.ArrayList(u32) = .empty;
    var arg: usize = 0;
    while (arg < args.len) : (arg += 1) {
        const e = args[arg];
        if (e == .none) {
            try pieces.append(l.a, try add(l, .{ .kind = .space }));
            continue;
        }
        if (ex.tag(e) != .str_literal) {
            try pieces.append(l.a, try bare(l, e));
            continue;
        }
        const format = r.file.str(ex.strOf(e));
        var text: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < format.len) : (i += 1) {
            if (format[i] != '%') {
                try text.append(l.a, format[i]);
                continue;
            }
            i += 1;
            if (i == format.len) return l.refuse("an unterminated format");
            if (format[i] == '%') {
                try text.append(l.a, '%');
                continue;
            }
            const sp = kernels.fmt.spec(format, &i);
            if (i == format.len) return l.refuse("an unterminated format");
            const conv = format[i];
            try flush(l, &text, &pieces);
            const width: u32 = if (sp.width) |w| std.math.cast(u32, w) orelse return l.refuse("a field width past u32") else Program.Piece.none_width;
            const precision = std.math.cast(i32, sp.precision) orelse return l.refuse("a precision past i32");
            switch (conv | 0x20) {
                'm' => {
                    try pieces.append(l.a, try add(l, .{ .kind = .scope, .a = pc }));
                    continue;
                },
                'l' => {
                    const def = r.hier.scopes.items[r.scope].def;
                    const name = try std.fmt.allocPrint(l.a, "{s}.{s}", .{ r.file.str(r.hier.def_lib[def]), r.file.str(r.file.modules[def].name) });
                    const s = try l.b.string(name);
                    try pieces.append(l.a, try add(l, .{ .kind = .lib, .a = s.start, .width = s.len }));
                    continue;
                },
                'v' => return l.refuse("%v"),
                else => {},
            }
            arg += 1;
            if (arg == args.len or args[arg] == .none) return l.refuse("a format with a missing argument");
            const a = args[arg];
            const row = switch (conv | 0x20) {
                'e', 'f', 'g', 'r' => try l.real(a),
                'b', 'o', 'h', 'x', 'd', 't' => try l.selfOrReal(a),
                's', 'c', 'u', 'z' => try l.self_(a, 0),
                else => return l.refuse("a conversion"),
            };
            try pieces.append(l.a, try add(l, .{ .kind = .spec, .conv = conv, .flags = sp.flags, .width = width, .precision = precision, .a = row }));
        }
        try flush(l, &text, &pieces);
    }
    const list = try l.b.listOf(pieces.items);
    try l.b.shows.append(l.b.arena, .{ .pieces = list, .radix = @fromBackingInt(@intCast(@backingInt(sh.radix))), .newline = sh.newline, .scope = r.scope });
    return @intCast(l.b.shows.items.len - 1);
}

/// An argument with no format: the task's radix, or a real's `%#g`
/// (`$realtime` alone in `%.Nf`, N its module's precision digits).
fn bare(l: *Lower, e: ExprId) E!u32 {
    const r = l.r;
    const ex = &r.file.exprs;
    if (!compile.typeOf(r, e).real) return add(l, .{ .kind = .bare, .a = try l.self_(e, 0) });
    var precision: i32 = -1;
    if (ex.tag(e) == .sys_call and r.typing.sys_calls[@backingInt(e)].? == .realtime)
        precision = @intCast(std.math.log10_int(@as(u64, r.timeOf(r.scope).scale.local_per_unit)));
    return add(l, .{ .kind = .bare_real, .precision = precision, .a = try l.real(e) });
}

fn flush(l: *Lower, text: *std.ArrayList(u8), pieces: *std.ArrayList(u32)) E!void {
    if (text.items.len == 0) return;
    const s = try l.b.string(text.items);
    try pieces.append(l.a, try add(l, .{ .kind = .text, .a = s.start, .width = s.len }));
    text.clearRetainingCapacity();
}

fn add(l: *Lower, p: Program.Piece) E!u32 {
    try l.b.pieces.append(l.b.arena, p);
    return @intCast(l.b.pieces.items.len - 1);
}

/// §17.1.3 the `Program.Monitor` of a `$monitor` call: its show, the
/// arguments compared on a change (`monitor.comparable` ones), the slots
/// every argument reads, and those of the arguments not compared.
fn monitor(l: *Lower, args: []const ExprId, sh: display.Show, pc: u32) E!u32 {
    const r = l.r;
    const ex = &r.file.exprs;
    const at = try show(l, args, sh, pc);
    var compared: std.ArrayList(u32) = .empty;
    var slots: std.ArrayList(u32) = .empty;
    var loose: std.ArrayList(u32) = .empty;
    var probes: std.ArrayList(ExprId) = .empty;
    for (args) |e| {
        if (e == .none or ex.tag(e) == .str_literal) continue;
        if (comparable(r, e)) {
            try compared.append(l.a, try l.selfOrReal(e));
        } else compile.sensitivityProbes(r, e, &loose, &probes) catch return l.refuse("a monitor argument the old engine refuses");
        compile.sensitivityProbes(r, e, &slots, &probes) catch return l.refuse("a monitor argument the old engine refuses");
    }
    if (probes.items.len != 0) return l.refuse("an analog probe in $monitor");
    return l.b.extraOf(Program.Monitor{
        .show = at,
        .compared = try l.b.listOf(compared.items),
        .slots = try l.b.listOf(slots.items),
        .loose = try l.b.listOf(loose.items),
    });
}

/// `monitor.comparable`: no clock query, call or probe anywhere in `e`.
fn comparable(r: *digital.Run, e: ExprId) bool {
    const ex = &r.file.exprs;
    return switch (ex.tag(e)) {
        .int_literal, .logic_literal, .str_literal, .real_literal, .ident, .hier_ident => true,
        .index => comparable(r, ex.lhs(e)) and comparable(r, ex.rhs(e)),
        .unary, .binary, .multi_concat, .ternary, .concat, .range, .indexed_range => {
            var buf: [3]ExprId = undefined;
            for (ex.children(e, &buf)) |c| if (c != .none and !comparable(r, c)) return false;
            return true;
        },
        else => false, // else: a system or user call, an analog probe
    };
}
