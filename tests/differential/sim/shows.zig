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
        .strobe => |sh| if (sh.file)
            l.b.extraOf(Program.Task{ .kind = .fstrobe, .a = try fileShow(l, args, sh, pc) })
        else
            l.b.extraOf(Program.Task{ .kind = .strobe, .a = try show(l, args, sh, pc) }),
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
        .readmem => |radix| blk: {
            const ex = &r.file.exprs;
            const none = @backingInt(Program.Ref.none);
            const base = r.slot(args[1]) catch return l.refuse("a $readmem memory the old engine refuses");
            const arr = r.decls.arrays.get(base) orelse return l.refuse("a $readmem of no array");
            const named = ex.tag(args[0]) == .str_literal;
            const rm = try l.b.extraOf(Program.ReadMem{
                .radix = @fromBackingInt(@intCast(@backingInt(radix))),
                .name = if (named) try l.b.string(r.file.str(ex.strOf(args[0]))) else .empty,
                .name_row = if (named) none else try l.self_(args[0], 0),
                .base = base,
                .low = std.math.cast(i32, arr.low) orelse return l.refuse("an array bound past i32"),
                .high = std.math.cast(i32, arr.high) orelse return l.refuse("an array bound past i32"),
                .start = if (args.len >= 3) try l.self_(args[2], 0) else none,
                .finish = if (args.len == 4) try l.self_(args[3], 0) else none,
            });
            break :blk l.b.extraOf(Program.Task{ .kind = .readmem, .a = rm });
        },
        .queue => l.refuse("a §17.6 queue task"),
        .pla => l.refuse("a §17.5 PLA task"),
        .fclose => l.b.extraOf(Program.Task{ .kind = .fclose, .a = try l.self_(args[0], 0) }),
        .fflush => l.b.extraOf(Program.Task{ .kind = .fflush, .a = 0 }),
        .fshow => |sh| l.b.extraOf(Program.Task{ .kind = .fshow, .a = try fileShow(l, args, sh, pc) }),
        .sshow, .sformat => blk: {
            if (args.len < 2) return l.refuse("a $swrite/$sformat with no text");
            const sh: display.Show = if (t == .sshow) t.sshow else .{ .radix = .decimal, .newline = false };
            const at = try showOf(l, args[1..], sh, pc, t == .sformat);
            const w = try l.b.extraOf(Program.SWrite{ .show = at, .place = try l.place(args[0]), .ty = try l.tyOf(try l.targetType(args[0])) });
            break :blk l.b.extraOf(Program.Task{ .kind = .swrite, .a = w });
        },
        .printtimescale => blk: {
            // Its text is fixed at elaboration: the old engine writes it here.
            var text: std.Io.Writer.Allocating = .init(l.a);
            const saved = r.out;
            r.out = &text.writer;
            defer r.out = saved;
            display.printTimescale(r, args) catch return l.refuse("a $printtimescale the old engine refuses");
            const piece = try add(l, .{ .kind = .text, .a = (try l.b.string(text.written())).start, .width = @intCast(text.written().len) });
            try l.b.shows.append(l.b.arena, .{ .pieces = try l.b.listOf(&.{piece}), .radix = .decimal, .newline = false, .scope = r.scope });
            break :blk l.b.extraOf(Program.Task{ .kind = .show, .a = @intCast(l.b.shows.items.len - 1) });
        },
        .sdf_annotate => l.refuse("$sdf_annotate"),
        .dump => |op| blk: {
            const vcd = digital.for_emitter.vcd;
            try catalog(l);
            const none = @backingInt(Program.Ref.none);
            var arg: u32 = none;
            var targets: std.ArrayList(u32) = .empty;
            var call: Program.List = .empty;
            switch (op) {
                .file => if (args.len == 1) {
                    arg = try l.self_(args[0], 0);
                    call = try l.b.string(vcd.callText(r.text, r.starts[tok]));
                },
                .vars => if (args.len != 0) {
                    arg = try l.self_(args[0], 0);
                    for (args[1..]) |e| switch (vcd.target(r, e) catch return l.refuse("a $dumpvars target the old engine refuses")) {
                        .scope => |sc| try targets.appendSlice(l.a, &.{ 0, sc }),
                        .slot => |sl| try targets.appendSlice(l.a, &.{ 1, sl }),
                    };
                } else for (r.hier.roots) |sc| try targets.appendSlice(l.a, &.{ 0, sc }),
                .limit => arg = try l.self_(args[0], 0),
                .off, .on, .all, .flush => {},
            }
            const dc = try l.b.extraOf(Program.DumpCall{ .op = std.meta.stringToEnum(Program.DumpOp, @tagName(op)).?, .arg = arg, .call = call, .targets = try l.b.listOf(targets.items) });
            break :blk l.b.extraOf(Program.Task{ .kind = .dump, .a = dc });
        },
        .ports => |op| l.b.extraOf(Program.Task{ .kind = .ports, .a = try portsCall(l, op, args, tok) }),
        .user => l.refuse("a PLI task"),
    };
}

// ---- private ----

/// §18.3 a port dump task's `Program.PortsCall`; for `$dumpports`, its
/// scopes, ports and header resolved here as `evcd.task` resolves them.
fn portsCall(l: *Lower, op: digital.for_emitter.evcd.Op, all: []const ExprId, tok: u32) E!u32 {
    const r = l.r;
    const ex = &r.file.exprs;
    const evcd = digital.for_emitter.evcd;
    const none = @backingInt(Program.Ref.none);
    const args = if (all.len == 1 and all[0] == .none) all[0..0] else all;
    if (op != .ports) {
        var c: Program.PortsCall = .{ .op = std.meta.stringToEnum(Program.PortsOp, @tagName(op)).?, .ports = 0, .name = none, .size = none };
        if (args.len != 0 and (op != .limit or args.len == 2)) c.name = try l.self_(args[args.len - 1], 0);
        if (op == .limit) c.size = try l.self_(args[0], 0);
        return l.b.extraOf(c);
    }
    var scopes: std.ArrayList(u32) = .empty;
    var name_row: u32 = none;
    for (args, 0..) |e, i| {
        if (ex.tag(e) == .ident or ex.tag(e) == .hier_ident) switch (digital.for_emitter.vcd.target(r, e) catch return l.refuse("a $dumpports target the old engine refuses")) {
            .scope => |sc| {
                try scopes.append(l.a, sc);
                continue;
            },
            .slot => {},
        };
        if (i + 1 == args.len) name_row = try l.self_(e, 0);
    }
    if (scopes.items.len == 0) try scopes.append(l.a, r.instanceOf(r.scope));
    var header: std.Io.Writer.Allocating = .init(l.a);
    const w = &header.writer;
    var ports: std.ArrayList(u32) = .empty;
    var n: u32 = 0;
    for (scopes.items) |sc| {
        w.writeAll("$scope module ") catch return error.OutOfMemory;
        evcd.path(r, w, sc) catch return error.OutOfMemory;
        w.writeAll(" $end\n") catch return error.OutOfMemory;
        const m = &r.file.modules[r.hier.scopes.items[sc].def];
        for (m.ports) |port| {
            const slot = r.hier.names.get(.{ .scope = sc, .str = port.name }) orelse continue;
            const net = r.netlist.slot_nets.get(slot);
            var inside: std.ArrayList(u32) = .empty;
            var outside: std.ArrayList(u32) = .empty;
            if (net) |k| for (r.netDrivers(k)) |d| {
                if (evcd.below(r, r.netlist.drivers[d].scope, sc)) try inside.append(l.a, d) else try outside.append(l.a, d);
            };
            const dir: Program.PortDir = switch (port.direction) {
                .input => .input,
                .output => .output,
                .inout, .unspecified => .inout,
            };
            try l.b.evcd_ports.append(l.b.arena, .{ .slot = slot, .net = net orelse none, .dir = dir, .inside = try l.b.listOf(inside.items), .outside = try l.b.listOf(outside.items) });
            try ports.append(l.a, @intCast(l.b.evcd_ports.items.len - 1));
            const width = r.values[slot].width;
            w.writeAll("$var port ") catch return error.OutOfMemory;
            if (width == 1) {
                w.writeAll("1") catch return error.OutOfMemory;
            } else {
                const range = r.vecRange(slot);
                w.print("[{d}:{d}]", .{ range.msb, range.lsb }) catch return error.OutOfMemory;
            }
            // `evcd.portName`: the first port name bound to the slot.
            const shown = for (m.ports) |mp| {
                if (r.hier.names.get(.{ .scope = sc, .str = mp.name }) == slot) break mp.name;
            } else port.name;
            w.print(" <{d} {s} $end\n", .{ n, r.file.str(shown) }) catch return error.OutOfMemory;
            n += 1;
        }
        w.writeAll("$upscope $end\n") catch return error.OutOfMemory;
    }
    const dp = try l.b.extraOf(Program.DumpPorts{
        .name_row = name_row,
        .call = try l.b.string(digital.for_emitter.vcd.callText(r.text, r.starts[tok])),
        .header = try l.b.string(header.written()),
        .ports = try l.b.listOf(ports.items),
    });
    return l.b.extraOf(Program.PortsCall{ .op = .ports, .ports = dp, .name = none, .size = none });
}

/// §18.1 the design's dump catalog, written into `Program.vcd` once, from
/// the old engine's own (`vcd.catalog`).
fn catalog(l: *Lower) E!void {
    if (l.b.p.vcd.scopes.len != 0) return;
    const r = l.r;
    const b = l.b;
    const saved = r.scope;
    defer r.scope = saved;
    const cat = digital.for_emitter.vcd.catalog(r, l.a, &.{}) catch return l.refuse("a dump catalog the old engine refuses");
    const scopes = try b.arena.alloc(Program.Vcd.VcdScope, cat.scopes.len);
    for (cat.scopes, scopes) |sc, *o| o.* = .{ .line = try b.string(sc.line), .parent = sc.parent, .lexical = sc.lexical, .child = sc.child };
    const vars = try b.arena.alloc(Program.Vcd.Var, cat.vars.len);
    for (cat.vars, vars) |v, *o| o.* = .{ .slot = v.slot, .width = v.width, .real = v.real, .event = v.event, .head = try b.string(v.head), .tail = try b.string(v.tail) };
    b.p.vcd = .{ .scopes = scopes, .var_start = try b.arena.dupe(u32, cat.var_start), .vars = vars };
}

/// The `Program.Show` of `args` (`display.walk`), whose `%m` names the
/// blocks around `pc`.
fn show(l: *Lower, args: []const ExprId, sh: display.Show, pc: u32) E!u32 {
    return showOf(l, args, sh, pc, false);
}

/// `show`; `only_first`: §17.2.3's `$sformat`, whose first argument alone
/// is a format (a variable one is not bridged), with no argument left over.
fn showOf(l: *Lower, args: []const ExprId, sh: display.Show, pc: u32, only_first: bool) E!u32 {
    const r = l.r;
    const ex = &r.file.exprs;
    var pieces: std.ArrayList(u32) = .empty;
    var arg: usize = 0;
    while (arg < args.len) : (arg += 1) {
        const e = args[arg];
        if (only_first and arg != 0) return l.refuse("a $sformat argument its format leaves over");
        if (only_first and ex.tag(e) != .str_literal) return l.refuse("a $sformat format held in a variable");
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
                'v' => {
                    arg += 1;
                    if (arg == args.len or args[arg] == .none) return l.refuse("a format with a missing argument");
                    const v = args[arg];
                    var net: u32 = @backingInt(Program.Ref.none);
                    if (ex.tag(v) == .ident) if (r.netlist.slot_nets.get(r.slot(v) catch return l.refuse("a %v name the old engine refuses"))) |k| {
                        net = k;
                    };
                    try pieces.append(l.a, try add(l, .{ .kind = .strength, .a = try l.self_(v, 0), .b = net }));
                    continue;
                },
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

/// §17.2.2 a file output task's `Program.FShow`: its descriptor, then
/// the display of the rest.
fn fileShow(l: *Lower, args: []const ExprId, sh: display.Show, pc: u32) E!u32 {
    if (args.len == 0 or args[0] == .none) return l.refuse("a file task with no descriptor");
    var plain = sh;
    plain.file = false;
    const fd = try l.self_(args[0], 0);
    return l.b.extraOf(Program.FShow{ .show = try show(l, args[1..], plain, pc), .fd = fd });
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
