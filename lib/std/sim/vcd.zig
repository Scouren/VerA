//! IEEE 1364-2005 §18.1/§18.2 four-state value change dump: the `$dump*`
//! calls and every change of a dumped slot in; the VCD file out, header at
//! the end of the `$dumpvars` step (§18.1.3), then one `#time` section per
//! step of the variables that changed (§18.1.4). The design's side, what a
//! `$dumpvars` can select, is `Program.Vcd` (its scopes' `$scope` lines and
//! variables' `$var` text), written once by the compiler stage.
//! Cites: IEEE 1364-2005 §17.4.1, §18.1.1-§18.1.6, §18.2.1-§18.2.3,
//! §18.4.1 (the header's `$date` and `$version`).
//!
//! Contents:
//! - `pub const Dump = struct`
//! - `pub fn task(s: *State, a: Allocator, at: u32) Error!void`
//! - `pub fn tick(s: *State, a: Allocator) Error!void`
//! - `pub fn fired(s: *State, slot: u32) Error!void`
//! - `pub fn request(s: *State) Error!void`
//! - `pub fn preamble(w: *std.Io.Writer, io: std.Io, call: []const u8, finest: i32) std.Io.Writer.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Program = @import("Program.zig");
const State = @import("State.zig");
const eval = @import("eval.zig");
const logic = @import("logic.zig");
const readmem = @import("readmem.zig");
const Error = State.Error;
const Var = Program.Vcd.Var;

/// One run's dump: the file and its name, the `$dumpvars` selection, the
/// codes minted in the header (one per distinct dumped slot) with the value
/// each last wrote, and §18.1.5's limit.
pub const Dump = struct {
    name: []const u8 = "dump.vcd",
    call: ?[]const u8 = null,
    scopes: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    slots: std.AutoHashMapUnmanaged(u32, void) = .empty,
    selected_at: ?u64 = null,
    started: bool = false,
    on: bool = true,
    pending: bool = false,
    codes: std.ArrayList(Code) = .empty,
    file: ?std.Io.File = null,
    pos: u64 = 0,
    limit: ?u64 = null,
    limited: bool = false,
    last_time: ?u64 = null,
};

const none = @backingInt(Program.Ref.none);

/// One identifier code: the variable that minted it, its value when last
/// written, and whether its event fired this step.
const Code = struct { v: u32, last: []u64, fired: bool = false };

/// A dump task call (`Program.DumpCall` at `at` in `extra`).
pub fn task(s: *State, a: Allocator, at: u32) Error!void {
    const p = s.p;
    const c = p.extraData(Program.DumpCall, at);
    const d = &s.dump;
    switch (c.op) {
        .file => if (c.arg != none and !d.started) {
            const name = (try readmem.text(a, try eval.eval(s, a, c.arg))) orelse return;
            d.name = try s.arena.dupe(u8, name);
            d.call = p.str(c.call);
        },
        .vars => {
            // §18.1.2: every $dumpvars executes at one simulation time.
            if (d.selected_at) |t| if (t != s.scheduler.now or d.started) return s.fail("§18.1.2: every $dumpvars shall execute at the same simulation time", .{});
            d.selected_at = s.scheduler.now;
            const levels: u32 = if (c.arg == none) 0 else std.math.lossyCast(u32, (try eval.eval(s, a, c.arg)).asInt() orelse 0);
            const targets = p.list(c.targets);
            assert(targets.len % 2 == 0);
            var k: usize = 0;
            while (k < targets.len) : (k += 2) {
                if (targets[k] == 0) try d.scopes.put(s.arena, targets[k + 1], levels) else try d.slots.put(s.arena, targets[k + 1], {});
            }
            try request(s);
        },
        .limit => d.limit = std.math.lossyCast(u64, (try eval.eval(s, a, c.arg)).asInt() orelse 0),
        .off => if (d.started and d.on) {
            try changes(s, a);
            try checkpoint(s, a, "$dumpoff", true);
            d.on = false;
        },
        .on => if (d.started and !d.on) {
            d.on = true;
            try checkpoint(s, a, "$dumpon", false);
        },
        .all => if (d.started and d.on) {
            try changes(s, a);
            try checkpoint(s, a, "$dumpall", false);
        },
        // Every section is written as it happens: nothing to flush.
        .flush => {},
    }
}

/// The step's one dump event (the monitor region): the header and the
/// `$dumpvars` checkpoint the first time, the changed variables after.
pub fn tick(s: *State, a: Allocator) Error!void {
    const d = &s.dump;
    d.pending = false;
    if (d.selected_at == null) return;
    if (d.started) return changes(s, a);
    try header(s, a);
    try checkpoint(s, a, "$dumpvars", false);
}

/// §18.2.2 named event `slot` occurred: its marker is due this step.
pub fn fired(s: *State, slot: u32) Error!void {
    const v = s.p.vcd.vars;
    for (s.dump.codes.items) |*c| if (v[c.v].slot == slot) {
        c.fired = true;
    };
    return request(s);
}

/// One dump event this step, for the VCD and the §18.3 port dumps alike.
pub fn request(s: *State) Error!void {
    if (s.dump.pending) return;
    s.dump.pending = true;
    try s.enqueueMonitor(.vcd_tick);
}

/// §18.2.3 the header before the definitions: the date, the version (naming
/// the dump call), and the timescale of a tick (the precision).
pub fn preamble(w: *std.Io.Writer, io: std.Io, call: []const u8, finest: i32) std.Io.Writer.Error!void {
    const t = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, @divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s))) };
    const yd = t.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = t.getDaySeconds();
    try w.print("$date\n\t{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}\n$end\n", .{ yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
    try w.print("$version\n\tVerA\n\t{s}\n$end\n", .{call});
    const units = [_][]const u8{ "fs", "ps", "ns", "us", "ms", "s" };
    const k: i32 = @divFloor(finest, 3);
    try w.print("$timescale {d}{s} $end\n", .{ std.math.pow(u32, 10, @intCast(finest - 3 * k)), units[@intCast(k + 5)] });
}

// ---- private ----

fn fail(s: *State, comptime what: []const u8) Error {
    return s.fail(what ++ " `{s}`", .{s.dump.name});
}

fn put(s: *State, bytes: []const u8) Error!void {
    const d = &s.dump;
    if (d.limited or bytes.len == 0) return;
    const f = d.file orelse return;
    var out = bytes;
    // §18.1.5: at the limit "the dumping stops, and a comment is inserted".
    if (d.limit) |lim| if (d.pos + bytes.len > lim) {
        out = "$comment $dumplimit reached $end\n";
        d.limited = true;
    };
    f.writePositionalAll(s.io.?, out, d.pos) catch return fail(s, "cannot write the dump file");
    d.pos += out.len;
}

fn header(s: *State, a: Allocator) Error!void {
    const d = &s.dump;
    const cat = s.p.vcd;
    const io = s.io orelse return fail(s, "$dumpvars needs a filesystem to write");
    d.file = std.Io.Dir.cwd().createFile(io, d.name, .{}) catch return fail(s, "cannot create the dump file");
    d.started = true;
    var w: std.Io.Writer.Allocating = .init(a);
    // §18.2.3.8: the $dumpfile call as written, or one naming the default.
    try preamble(&w.writer, io, d.call orelse try std.fmt.allocPrint(a, "$dumpfile(\"{s}\")", .{d.name}), s.p.finest);
    // Every top-level module is a root: scope 0 and each its own parent.
    for (cat.scopes, 0..) |sc, i| if (i == 0 or sc.parent == i) try dumpScope(s, &w, @intCast(i), null);
    try w.writer.writeAll("$enddefinitions $end\n");
    try put(s, w.written());
}

fn dumpScope(s: *State, aw: *std.Io.Writer.Allocating, sc_at: u32, inherited: ?u32) Error!void {
    const d = &s.dump;
    const cat = s.p.vcd;
    const w = &aw.writer;
    const info = cat.scopes[sc_at];
    const own = d.scopes.get(sc_at);
    const eff: ?u32 = if (inherited == null) own else if (own == null) inherited else if (inherited.? == 0 or own.? == 0) 0 else @max(inherited.?, own.?);
    const mark = aw.written().len;
    try w.writeAll(s.p.str(info.line));
    const body = aw.written().len;
    for (cat.vars[cat.var_start[sc_at]..cat.var_start[sc_at + 1]], cat.var_start[sc_at]..) |v, i| {
        if (eff == null and !d.slots.contains(v.slot)) continue;
        const code: u32 = for (d.codes.items, 0..) |c, j| {
            if (cat.vars[c.v].slot == v.slot) break @intCast(j);
        } else blk: {
            try d.codes.append(s.arena, .{ .v = @intCast(i), .last = try s.arena.alloc(u64, 2 * Program.words(v.width)) });
            s.dumped[v.slot] = true;
            break :blk @intCast(d.codes.items.len - 1);
        };
        try w.writeAll(s.p.str(v.head));
        try codeText(w, code);
        try w.writeAll(s.p.str(v.tail));
    }
    // A generate iteration is a `begin` scope of its instance, not a level.
    const down: ?u32 = if (info.lexical) eff else if (eff) |n| (if (n == 0) 0 else if (n == 1) null else n - 1) else null;
    for (cat.scopes, 0..) |child, i| {
        if (i == 0 or i == sc_at or child.parent != sc_at or !child.child) continue;
        try dumpScope(s, aw, @intCast(i), down);
    }
    if (aw.written().len == body) {
        aw.shrinkRetainingCapacity(mark);
        return;
    }
    try w.writeAll("$upscope $end\n");
}

fn time(s: *State, w: *std.Io.Writer, now: u64) Error!void {
    const d = &s.dump;
    if (d.last_time == now) return;
    d.last_time = now;
    try w.print("#{d}\n", .{now});
}

/// A variable's planes now; a real is its bits.
fn planes(s: *State, v: Var, out: []u64) void {
    const sl = s.p.slots.get(v.slot);
    const n = Program.words(sl.ty.width);
    assert(out.len == 2 * n);
    @memcpy(out[0..n], s.v[sl.word..][0..n]);
    @memcpy(out[n..], s.x[sl.word..][0..n]);
}

fn checkpoint(s: *State, a: Allocator, keyword: []const u8, as_x: bool) Error!void {
    const cat = s.p.vcd;
    var w: std.Io.Writer.Allocating = .init(a);
    try time(s, &w.writer, s.scheduler.now);
    try w.writer.print("{s}\n", .{keyword});
    for (s.dump.codes.items, 0..) |c, i| {
        if (cat.vars[c.v].event) continue;
        planes(s, cat.vars[c.v], c.last);
        try value(&w.writer, cat.vars[c.v], c.last, @intCast(i), as_x);
    }
    try w.writer.writeAll("$end\n");
    try put(s, w.written());
}

fn changes(s: *State, a: Allocator) Error!void {
    const d = &s.dump;
    const cat = s.p.vcd;
    if (!d.on) return;
    var w: std.Io.Writer.Allocating = .init(a);
    var buf: std.ArrayList(u64) = .empty;
    for (d.codes.items, 0..) |*c, i| {
        // §18.2.2: an event is dumped as a scalar marker of its trigger.
        if (cat.vars[c.v].event) {
            if (!c.fired) continue;
            c.fired = false;
            if (w.written().len == 0) try time(s, &w.writer, s.scheduler.now);
            try w.writer.writeByte('1');
            try codeText(&w.writer, @intCast(i));
            try w.writer.writeByte('\n');
            continue;
        }
        try buf.resize(a, c.last.len);
        planes(s, cat.vars[c.v], buf.items);
        if (std.mem.eql(u64, c.last, buf.items)) continue;
        if (w.written().len == 0) try time(s, &w.writer, s.scheduler.now);
        @memcpy(c.last, buf.items);
        try value(&w.writer, cat.vars[c.v], c.last, @intCast(i), false);
    }
    try put(s, w.written());
}

/// §18.2.1 identifier codes from `!` to `~`, counting on in base 94.
fn codeText(w: *std.Io.Writer, code: u32) std.Io.Writer.Error!void {
    var n = code;
    var chars: u32 = 0;
    while (true) : (chars += 1) {
        assert(chars < 5);
        try w.writeByte(@intCast('!' + n % 94));
        if (n < 94) return;
        n = n / 94 - 1;
    }
}

/// §18.2.2 one value change: a scalar's value and code, a vector's `b`
/// digits (Table 18-1's redundant leading digit dropped) and a space, a
/// real's `r` and `%.16g`.
fn value(w: *std.Io.Writer, v: Var, p: []const u64, code: u32, as_x: bool) std.Io.Writer.Error!void {
    const lit: logic.Literal = .{ .width = v.width, .signed = false, .sized = true, .planes = @constCast(p) };
    if (v.real and !as_x) {
        var buf: [64]u8 = undefined;
        try w.print("r{s} ", .{g16(&buf, @bitCast(p[0]))});
    } else if (v.width == 1) {
        try w.writeByte(if (as_x) 'x' else bitChar(lit.bit(0)));
    } else {
        try w.writeByte('b');
        var i = v.width;
        if (as_x) i = 1;
        while (i > 1) : (i -= 1) {
            const top = lit.bit(i - 1);
            const next = lit.bit(i - 2);
            const redundant = if (top == .zero) next == .zero or next == .one else top != .one and top == next;
            if (!redundant) break;
        }
        while (i > 0) : (i -= 1) try w.writeByte(if (as_x) 'x' else bitChar(lit.bit(i - 1)));
        try w.writeByte(' ');
    }
    try codeText(w, code);
    try w.writeByte('\n');
}

fn bitChar(b: logic.Bit) u8 {
    return "01zx"[@backingInt(b)];
}

/// §18.2.1 "A real number is dumped using a %.16g printf() format".
fn g16(buf: *[64]u8, r: f64) []const u8 {
    if (std.math.isNan(r)) return "nan";
    if (std.math.isInf(r)) return if (r < 0) "-inf" else "inf";
    var sci_buf: [64]u8 = undefined;
    const sci = std.mem.print(&sci_buf, "{e:.15}", .{r}) catch unreachable;
    const e_at = std.mem.findScalar(u8, sci, 'e').?;
    const x = std.fmt.parseInt(i32, sci[e_at + 1 ..], 10) catch unreachable;
    if (x < -4 or x >= 16) {
        const mant = strip(sci[0..e_at]);
        return std.mem.print(buf, "{s}e{c}{d:0>2}", .{ mant, @as(u8, if (x < 0) '-' else '+'), @abs(x) }) catch unreachable;
    }
    return strip(std.mem.print(buf, "{d:.[1]}", .{ r, @as(usize, @intCast(15 - x)) }) catch unreachable);
}

fn strip(s: []const u8) []const u8 {
    if (std.mem.findScalar(u8, s, '.') == null) return s;
    const t = std.mem.trimEnd(u8, s, "0");
    return if (t[t.len - 1] == '.') t[0 .. t.len - 1] else t;
}

test "g16 is C's %.16g; codes count on in base 94" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0.1", g16(&buf, 0.1));
    try std.testing.expectEqualStrings("1e+20", g16(&buf, 1e20));
    try std.testing.expectEqualStrings("1.5e-05", g16(&buf, 1.5e-5));
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    try codeText(&w.writer, 0);
    try codeText(&w.writer, 93);
    try codeText(&w.writer, 94);
    try std.testing.expectEqualStrings("!~!!", w.written());
}
