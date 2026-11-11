//! System tasks of the digital lowering: a statement-level `call_sys` in
//! `Lower.frame` -> one `.task` instruction and its `Program.Task`, a
//! display's format through `format.zig`; §17.1.3's `$monitor`, §17.2's
//! file output and `$readmemb`/`$readmemh`, §17.3.2, §17.4.1.
//! Cites: IEEE 1364-2005 §17.1.2, §17.1.3, §17.2.2, §17.2.3, §17.2.6,
//! §17.2.9, §17.3.2, §17.4.1.
//!
//! Contents:
//! - `pub fn task(l: *Lower, i: Inst.Index) Error!void`
//! - `pub fn queueCall(l: *Lower, op: Program.QueueOp, args: []const Inst.Ref, outs: []const bool) Error!u32`
//! - `pub fn scopePath(l: *Lower, scope: u32, out: *std.ArrayList(u8), depth: u32) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const std_sim = @import("std_sim");
const kernels = @import("kernels");
const digital = @import("../digital.zig");
const expr = @import("expr.zig");
const place = @import("place.zig");
const vcd = @import("vcd.zig");
const sdf = @import("sdf.zig");
const hier = @import("hier.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const none = digital.none;
const Program = std_sim.Program;
const Vir = vams.Vir;
const Inst = Vir.Inst;

const format = @import("format.zig");
const Show = format.Show;
const Kind = union(enum) { show: Show, strobe: Show, monitor: Show, monitor_on, monitor_off, finish, stop, timeformat, fshow: Show, fstrobe: Show, fmonitor: Show, swrite: Show, sformat, readmem: Program.Radix, fclose, fflush, queue: Program.QueueOp, printtimescale, dump: Program.DumpOp, ports: Program.PortsOp, sdf };

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
    .{ "$fdisplay", Kind{ .fshow = .{ .radix = .decimal, .newline = true } } },
    .{ "$fdisplayb", Kind{ .fshow = .{ .radix = .binary, .newline = true } } },
    .{ "$fdisplayo", Kind{ .fshow = .{ .radix = .octal, .newline = true } } },
    .{ "$fdisplayh", Kind{ .fshow = .{ .radix = .hex, .newline = true } } },
    .{ "$fwrite", Kind{ .fshow = .{ .radix = .decimal, .newline = false } } },
    .{ "$fwriteb", Kind{ .fshow = .{ .radix = .binary, .newline = false } } },
    .{ "$fwriteo", Kind{ .fshow = .{ .radix = .octal, .newline = false } } },
    .{ "$fwriteh", Kind{ .fshow = .{ .radix = .hex, .newline = false } } },
    .{ "$fstrobe", Kind{ .fstrobe = .{ .radix = .decimal, .newline = true } } },
    .{ "$fstrobeb", Kind{ .fstrobe = .{ .radix = .binary, .newline = true } } },
    .{ "$fstrobeo", Kind{ .fstrobe = .{ .radix = .octal, .newline = true } } },
    .{ "$fstrobeh", Kind{ .fstrobe = .{ .radix = .hex, .newline = true } } },
    .{ "$fmonitor", Kind{ .fmonitor = .{ .radix = .decimal, .newline = true } } },
    .{ "$fmonitorb", Kind{ .fmonitor = .{ .radix = .binary, .newline = true } } },
    .{ "$fmonitoro", Kind{ .fmonitor = .{ .radix = .octal, .newline = true } } },
    .{ "$fmonitorh", Kind{ .fmonitor = .{ .radix = .hex, .newline = true } } },
    .{ "$swrite", Kind{ .swrite = .{ .radix = .decimal, .newline = false } } },
    .{ "$swriteb", Kind{ .swrite = .{ .radix = .binary, .newline = false } } },
    .{ "$swriteo", Kind{ .swrite = .{ .radix = .octal, .newline = false } } },
    .{ "$swriteh", Kind{ .swrite = .{ .radix = .hex, .newline = false } } },
    .{ "$sformat", Kind.sformat },
    .{ "$readmemb", Kind{ .readmem = .binary } },
    .{ "$readmemh", Kind{ .readmem = .hex } },
    .{ "$fclose", Kind.fclose },
    .{ "$fflush", Kind.fflush },
    .{ "$q_initialize", Kind{ .queue = .initialize } },
    .{ "$q_add", Kind{ .queue = .add } },
    .{ "$q_remove", Kind{ .queue = .remove } },
    .{ "$q_exam", Kind{ .queue = .exam } },
    .{ "$printtimescale", Kind.printtimescale },
    .{ "$sdf_annotate", Kind.sdf },
    .{ "$dumpports", Kind{ .ports = .ports } },
    .{ "$dumpportsoff", Kind{ .ports = .off } },
    .{ "$dumpportson", Kind{ .ports = .on } },
    .{ "$dumpportsall", Kind{ .ports = .all } },
    .{ "$dumpportslimit", Kind{ .ports = .limit } },
    .{ "$dumpportsflush", Kind{ .ports = .flush } },
    .{ "$dumpfile", Kind{ .dump = .file } },
    .{ "$dumpvars", Kind{ .dump = .vars } },
    .{ "$dumpoff", Kind{ .dump = .off } },
    .{ "$dumpon", Kind{ .dump = .on } },
    .{ "$dumpall", Kind{ .dump = .all } },
    .{ "$dumplimit", Kind{ .dump = .limit } },
    .{ "$dumpflush", Kind{ .dump = .flush } },
});

/// Appends the `.task` instruction of system task call `i`.
pub fn task(l: *Lower, i: Inst.Index) Error!void {
    const vir = l.virOf(l.frame);
    const c = Lower.payload(vir, Inst.SysCall, i);
    const name = vir.string(c.name);
    const args = vir.list(Inst.Ref, c.args);
    const scope = l.frames.items[l.frame].scope;
    const at: u32 = @intCast(l.b.p.insts.len);
    if (plaOf(name)) |pl| {
        const call = try l.b.extraOf(Program.Task{ .kind = .pla, .a = try plaCall(l, args, pl.logic, pl.plane) });
        if (!pl.async_) {
            _ = try l.b.inst(.task, call, 0, scope);
            return;
        }
        // §17.5.1 an asynchronous PLA re-evaluates whenever its memory or
        // inputs change: a loop of its own, jumped over here and spawned.
        var terms: std.ArrayList(u32) = .empty;
        var slots: std.ArrayList(u32) = .empty;
        const m = (try expr.nameOf(l, args[0])).?;
        for (0..m.count) |k| try slots.append(l.a, m.slot + @as(u32, @intCast(k)));
        try expr.reads(l, args[1], &slots);
        for (slots.items) |s| try terms.appendSlice(l.a, &.{ s, @backingInt(Program.Edge.any), 0, 0, none });
        const skip = try l.b.inst(.jump, 0, 0, scope);
        const start: u32 = @intCast(l.b.p.insts.len);
        _ = try l.b.inst(.task, call, 0, scope);
        _ = try l.b.inst(.wait_event, try l.b.extraOf(.{ .l = try l.b.listOf(terms.items) }), 0, scope);
        _ = try l.b.inst(.jump, start, 0, scope);
        l.b.setInst(skip, .jump, @intCast(l.b.p.insts.len), 0);
        _ = try l.b.inst(.spawn, start, 0, scope);
        return;
    }
    const kind = tasks.get(name) orelse return l.refuseFmt("the system task `{s}`", .{name});
    const t: Program.Task = switch (kind) {
        .show => |sh| .{ .kind = .show, .a = try format.show(l, i, args, sh, at, false) },
        .strobe => |sh| .{ .kind = .strobe, .a = try format.show(l, i, args, sh, at, false) },
        .monitor => |sh| blk: {
            for (args) |a| try place.notAutomatic(l, a, "$monitor");
            break :blk .{ .kind = .monitor, .a = try monitor(l, i, args, sh, at, none) };
        },
        // §17.2.2 files.zig:413: W1154 (an unwritten descriptor) blames
        // arg 0, the descriptor, on every file-output task, not the call.
        .fshow => |sh| blk: {
            l.b.setSite(l.argSite(l.frame, i, 0));
            break :blk .{ .kind = .fshow, .a = try fileShow(l, i, args, sh, at) };
        },
        .fstrobe => |sh| blk: {
            l.b.setSite(l.argSite(l.frame, i, 0));
            break :blk .{ .kind = .fstrobe, .a = try fileShow(l, i, args, sh, at) };
        },
        .fmonitor => |sh| blk: {
            if (args.len == 0 or args[0] == .none) return l.reject(l.frame, i.toRef(), "a §17.2.2 file output task's first argument is a descriptor");
            l.b.setSite(l.argSite(l.frame, i, 0));
            break :blk .{ .kind = .monitor, .a = try monitor(l, i, args[1..], sh, at, try expr.self_(l, args[0], 0)) };
        },
        .swrite, .sformat => blk: {
            if (args.len < 2) return l.refuse("a $swrite/$sformat with no text");
            const sh: Show = if (kind == .swrite) kind.swrite else .{ .radix = .decimal, .newline = false };
            // §17.2.3 display.zig:485: W1153 (the format mismatch) blames
            // arg 1, the format argument, not the call. This matches old's
            // "too few arguments" sub-case exactly (`short`'s
            // `sformatMismatch(self, e)` with `e = args[0]`, the format
            // expression). old's "too many" (excess argument) sub-case
            // instead blames the first leftover argument, a byte that is
            // runtime-content-dependent for a non-literal format and that
            // one static site cannot reproduce either way -- overriding or
            // not. Keep the override unconditional: it is right for "too
            // few" and no worse than the default for "too many".
            l.b.setSite(l.argSite(l.frame, i, 1));
            const w = try l.b.extraOf(Program.SWrite{ .show = try format.show(l, i, args[1..], sh, at, kind == .sformat), .place = try place.place(l, args[0]), .ty = try l.tyOf(try place.targetType(l, args[0])) });
            break :blk .{ .kind = .swrite, .a = w };
        },
        // §17.2.9 readmem.zig:381: W1150/W1156/W1157 blame arg 0, the file
        // name, not the call.
        .readmem => |radix| blk: {
            l.b.setSite(l.argSite(l.frame, i, 0));
            break :blk .{ .kind = .readmem, .a = try readmem(l, args, radix) };
        },
        .fclose => blk: {
            if (args.len != 1) return l.reject(l.frame, i.toRef(), "$fclose takes one descriptor");
            break :blk .{ .kind = .fclose, .a = try expr.self_(l, args[0], 0) };
        },
        .fflush => .{ .kind = .fflush, .a = 0 },
        .queue => |op| blk: {
            for (args) |a| if (a == .none) return l.reject(l.frame, i.toRef(), "the §17.6 queue tasks take four arguments");
            if (args.len != 4) return l.reject(l.frame, i.toRef(), "the §17.6 queue tasks take four arguments");
            // §17.6.5 Table 17-15 defines codes 1 to 6.
            if (op == .exam) if (try l.constOf(l.frame, args[1])) |code| if (code == .int and (code.int < 1 or code.int > 6))
                return l.rejectArg(l.frame, i, 1, "§17.6.5: a $q_exam q_stat_code is one of Table 17-15's codes 1 to 6");
            // §17.6.1-§17.6.5 which arguments each task writes.
            const outs: []const bool = switch (op) {
                .initialize, .add => &.{ false, false, false, true },
                .remove => &.{ false, true, true, true },
                .exam => &.{ false, false, true, true },
            };
            break :blk .{ .kind = .queue, .a = try queueCall(l, op, args, outs) };
        },
        .printtimescale => .{ .kind = .show, .a = try printTimescale(l, args) },
        .dump => |op| .{ .kind = .dump, .a = try vcd.task(l, i, op, args) },
        .ports => |op| .{ .kind = .ports, .a = try vcd.ports(l, i, op, args) },
        .sdf => .{ .kind = .sdf, .a = try sdf.task(l, args) },
        .monitor_on, .monitor_off => blk: {
            if (args.len != 0) return l.reject(l.frame, i.toRef(), "$monitoron and $monitoroff take no arguments");
            break :blk .{ .kind = if (kind == .monitor_on) .monitor_on else .monitor_off, .a = 0 };
        },
        .finish, .stop => blk: {
            if (args.len > 1) return if (kind == .stop)
                l.reject(l.frame, i.toRef(), "$stop accepts zero or one argument")
            else
                l.reject(l.frame, i.toRef(), "$finish accepts zero or one argument");
            const verbose: u32 = if (args.len == 0) none else try expr.self_(l, args[0], 0);
            break :blk .{ .kind = if (kind == .stop) .stop else .finish, .a = verbose, .b = try l.b.string(try location(l, i)) };
        },
        .timeformat => blk: {
            if (args.len == 0) break :blk .{ .kind = .timeformat, .a = none };
            if (args.len != 4) return l.refuse("$timeformat with other than four arguments");
            const s = args[2].toIndex() orelse return l.refuse("$timeformat without a suffix");
            if (Lower.tag(vir, s) != .str) return l.refuse("$timeformat with a suffix that is no string literal");
            const sd = vir.instructions.items(.data)[@backingInt(s)].str;
            // §17.3.2 "the range from 0 to -15" (Table 17-10).
            if (try l.constOf(l.frame, args[0])) |units| if (units == .int and (units.int > 0 or units.int < -15))
                return l.rejectArg(l.frame, i, 0, "§17.3.2: $timeformat's units number shall be in the range from 0 to -15");
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

/// §17.6 a queue task's or `$q_full`'s `Program.QueueCall`: its value
/// arguments' rows, then the places of those `outs` marks as written.
pub fn queueCall(l: *Lower, op: Program.QueueOp, args: []const Inst.Ref, outs: []const bool) Error!u32 {
    if (args.len > outs.len) return l.refuse("a queue task with too many arguments");
    var words: [8]u32 = @splat(none);
    var tys: [4]Program.Ty = @splat(.bit);
    for (args, outs[0..args.len], 0..) |a, out, k| {
        if (a == .none) return l.refuse("a queue task with an omitted argument");
        if (out) {
            words[4 + k] = try place.place(l, a);
            tys[k] = try l.tyOf(try place.targetType(l, a));
        } else words[k] = try expr.self_(l, a, 0);
    }
    return l.b.extraOf(Program.QueueCall{ .op = op, .scope = l.frames.items[l.frame].scope, .args = try l.b.listOf(&words), .ty1 = tys[1], .ty2 = tys[2], .ty3 = tys[3] });
}

/// §17.1.1.6 the path `%m` prints for scope `scope` (a named block is a
/// scope of its own here), as the runtime's `display.path` writes it.
pub fn scopePath(l: *Lower, scope: u32, out: *std.ArrayList(u8), depth: u32) Error!void {
    if (depth > l.b.scopes.items.len) return l.refuse("a scope chain with a cycle");
    const sc = l.b.scopes.items[scope];
    if (sc.parent != scope and scope != 0) {
        try scopePath(l, sc.parent, out, depth + 1);
        try out.append(l.a, '.');
    }
    try out.appendSlice(l.a, l.b.string_bytes.items[sc.name.start..][0..sc.name.len]);
    if (sc.index) |k| try out.print(l.a, "[{d}]", .{k});
}

// ---- private ----

/// §17.3.1 `$printtimescale`: a show of fixed text naming the current
/// instance (or the local object the argument names) and its module's time
/// unit and precision.
fn printTimescale(l: *Lower, args: []const Inst.Ref) Error!u32 {
    if (args.len > 1) return l.refuse("$printtimescale with more than one argument");
    var scope = l.frames.items[l.rootFrame(l.frame)].scope;
    var leaf: []const u8 = "";
    if (args.len == 1) {
        const vir = l.virOf(l.frame);
        const i = args[0].toIndex() orelse return l.refuse("$printtimescale of an omitted argument");
        const d: ?Inst.Index = if (Lower.tag(vir, i) == .decl_ref) vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl else null;
        const object = if (d) |x| switch (Lower.tag(vir, x)) {
            .variable, .net, .param, .io, .event => true,
            else => false, // else: an instance, block or generate block names a scope
        } else false;
        if (object) {
            leaf = vir.string(declName(vir, d.?));
        } else if (hier.scopeOf(l, args[0])) |s| {
            // §17.3.1 a scope: an instance (or named block) by its name.
            scope = s;
        } else |e| {
            if (e != error.Unsupported or Lower.tag(vir, i) != .field) return e;
            // §17.3.1 an object a hierarchical name reaches, and its scope.
            const fd = Lower.payload(vir, Inst.Field, i);
            scope = try hier.scopeOf(l, fd.operand);
            leaf = vir.string(fd.name);
        }
    }
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(l.a, "Time scale of (");
    try scopePath(l, scope, &text, 0);
    if (leaf.len != 0) try text.print(l.a, ".{s}", .{leaf});
    const t = l.b.times.items[scope];
    const prec_exp = t.unit_exp - @as(i32, std.math.log10_int(@as(u64, t.scale.local_per_unit)));
    var w: std.Io.Writer.Allocating = .init(l.a);
    w.writer.writeAll(") is ") catch return error.OutOfMemory;
    kernels.fmt.decade(&w.writer, t.unit_exp) catch return error.OutOfMemory;
    w.writer.writeAll(" / ") catch return error.OutOfMemory;
    kernels.fmt.decade(&w.writer, prec_exp) catch return error.OutOfMemory;
    w.writer.writeByte('\n') catch return error.OutOfMemory;
    try text.appendSlice(l.a, w.written());
    const s = try l.b.string(text.items);
    const piece = try format.add(l, .{ .kind = .text, .a = s.start, .width = s.len });
    try l.b.shows.append(l.a, .{ .pieces = try l.b.listOf(&.{piece}), .radix = .decimal, .newline = false, .scope = l.frames.items[l.frame].scope });
    return @intCast(l.b.shows.items.len - 1);
}

/// The name a declaration instruction declares.
fn declName(vir: *const Vir, d: Inst.Index) Vir.String {
    return switch (Lower.tag(vir, d)) {
        .variable => Lower.payload(vir, Inst.Variable, d).name,
        .net => Lower.payload(vir, Inst.Net, d).name,
        .param => Lower.payload(vir, Inst.Param, d).name,
        .io => Lower.payload(vir, Inst.Io, d).name,
        else => Lower.payload(vir, Inst.Name, d).name, // else: an event
    };
}

/// §17.5 a PLA task's logic, form and timing, by its name
/// (`$async$and$array` ... `$sync$nor$plane`), or null.
fn plaOf(name: []const u8) ?struct { logic: Program.PlaLogic, plane: bool, async_: bool } {
    const async_ = std.mem.startsWith(u8, name, "$async$");
    const rest = if (async_) name[7..] else if (std.mem.startsWith(u8, name, "$sync$")) name[6..] else return null;
    const dollar = std.mem.findScalar(u8, rest, '$') orelse return null;
    const logic = std.meta.stringToEnum(Program.PlaLogic, rest[0..dollar]) orelse return null;
    const form = rest[dollar + 1 ..];
    if (!std.mem.eql(u8, form, "array") and !std.mem.eql(u8, form, "plane")) return null;
    return .{ .logic = logic, .plane = form[0] == 'p', .async_ = async_ };
}

/// §17.5 a PLA task's `Program.PlaCall`: its personality memory, input and
/// output.
fn plaCall(l: *Lower, args: []const Inst.Ref, logic: Program.PlaLogic, plane: bool) Error!u32 {
    if (args.len != 3) return l.refuse("a PLA task without three arguments");
    const n = (try expr.nameOf(l, args[0])) orelse return l.refuse("a PLA personality that is no memory");
    if (n.dims.len != 1 or n.kind != .variable) return l.refuse("a PLA personality that is no one-dimensional memory");
    if (n.msb > n.lsb) return l.reject(l.frame, args[0], "§17.5.3: a PLA personality's bit range is ascending, as in reg [1:n]");
    return l.b.extraOf(Program.PlaCall{
        .logic = logic,
        .plane = plane,
        .base = n.slot,
        .count = n.count,
        .in = try expr.self_(l, args[1], 0),
        .out = try place.place(l, args[2]),
        .ty = try l.tyOf(try place.targetType(l, args[2])),
    });
}

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

/// §17.2.2 a file output task's `Program.FShow`: its descriptor, then the
/// display of the rest.
fn fileShow(l: *Lower, call: Inst.Index, args: []const Inst.Ref, sh: Show, pc: u32) Error!u32 {
    if (args.len == 0 or args[0] == .none) return l.reject(l.frame, call.toRef(), "a §17.2.2 file output task's first argument is a descriptor");
    const fd = try expr.self_(l, args[0], 0);
    return l.b.extraOf(Program.FShow{ .show = try format.show(l, call, args[1..], sh, pc, false), .fd = fd });
}

/// §17.2.9 a `$readmemb`/`$readmemh` call: its file name (a literal's text,
/// or a row), the one-dimensional memory it loads, and its optional start
/// and finish addresses.
fn readmem(l: *Lower, args: []const Inst.Ref, radix: Program.Radix) Error!u32 {
    const vir = l.virOf(l.frame);
    if (args.len < 2 or args.len > 4) return l.refuse("a $readmem with other than two to four arguments");
    for (args) |a| if (a == .none) return l.refuse("a $readmem with an omitted argument");
    const n = (try expr.nameOf(l, args[1])) orelse return l.refuse("a $readmem of no memory name");
    if (n.dims.len != 1 or n.kind != .variable) return l.refuse("a $readmem of no one-dimensional memory");
    const f = args[0].toIndex().?;
    const named = Lower.tag(vir, f) == .str;
    return l.b.extraOf(Program.ReadMem{
        .radix = radix,
        .name = if (named) try l.b.string(strText(vir, f)) else .empty,
        .name_row = if (named) none else try expr.self_(l, args[0], 0),
        .base = n.slot,
        .low = n.dims[0].low,
        .high = n.dims[0].high,
        .start = if (args.len >= 3) try expr.self_(l, args[2], 0) else none,
        .finish = if (args.len == 4) try expr.self_(l, args[3], 0) else none,
    });
}

fn strText(vir: *const Vir, i: Inst.Index) []const u8 {
    const sd = vir.instructions.items(.data)[@backingInt(i)].str;
    return vir.string_bytes[@backingInt(sd.start)..][0..sd.len];
}

/// §17.1.3 the `Program.Monitor` of a `$monitor` call: its show, the
/// arguments compared on a change (no call anywhere in one), the slots
/// every argument reads, and those of the arguments not compared; an
/// `$fmonitor`'s descriptor row `fd` (`none` for a `$monitor`).
fn monitor(l: *Lower, call: Inst.Index, args: []const Inst.Ref, sh: Show, pc: u32, fd: u32) Error!u32 {
    const vir = l.virOf(l.frame);
    const at = try format.show(l, call, args, sh, pc, false);
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
        .fd = fd,
    });
}

/// `monitor.comparable`: no clock query or call anywhere in `e`.
fn comparable(vir: *const Vir, e: Inst.Ref) bool {
    const i = e.toIndex() orelse return true;
    const data = vir.instructions.items(.data)[@backingInt(i)];
    return switch (Lower.tag(vir, i)) {
        .int, .big_int, .str, .real, .decl_ref, .str_ref, .field => true,
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
