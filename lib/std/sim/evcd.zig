//! IEEE 1364-2005 §18.3/§18.4 extended value change dump: the `$dumpports`
//! calls and every change of a dumped port in; one file per call out,
//! header and `$dumpports` section at the end of the call's step
//! (§18.3.1), one `#time` section per step of the ports whose state
//! (§18.4.3) changed, and `$vcdclose` when the run ends (§18.3.6.1). A
//! port's state is read from its net's drivers split at the instance
//! boundary, which the compiler stage wrote per port (`Program.EvcdPort`).
//! Cites: IEEE 1364-2005 §18.3.1-§18.3.7, §18.4.1-§18.4.3, Table 18-7.
//!
//! Contents:
//! - `pub const File = struct`
//! - `pub fn task(s: *State, a: Allocator, at: u32) Error!void`
//! - `pub fn tick(s: *State, a: Allocator) Error!void`
//! - `pub fn close(s: *State) Error!void`
//! - `pub fn request(s: *State) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Program = @import("Program.zig");
const State = @import("State.zig");
const eval = @import("eval.zig");
const logic = @import("logic.zig");
const net = @import("net.zig");
const resolve = @import("resolve.zig");
const readmem = @import("readmem.zig");
const vcd = @import("vcd.zig");
const Error = State.Error;
const Signal = net.Signal;

/// One `$dumpports` file: its name, the call that made it, its ports (a
/// `List` of `evcd_ports` rows) and header text, and each port's state text
/// when last written.
pub const File = struct {
    name: []const u8,
    call: Program.DumpPorts,
    last: [][]u8,
    file: ?std.Io.File = null,
    pos: u64 = 0,
    started: bool = false,
    on: bool = true,
    limit: ?u64 = null,
    limited: bool = false,
    last_time: ?u64 = null,
};

const none = @backingInt(Program.Ref.none);

/// A §18.4.3 port state: its character and its two strength levels.
const PortState = struct { c: u8, s0: u8, s1: u8 };

/// A port task call (`Program.PortsCall` at `at`).
pub fn task(s: *State, a: Allocator, at: u32) Error!void {
    const p = s.p;
    const c = p.extraData(Program.PortsCall, at);
    if (c.op == .ports) {
        const dp = p.extraData(Program.DumpPorts, c.ports);
        // §18.3.1: every $dumpports executes at one simulation time.
        if (s.ports_at) |t| if (t != s.scheduler.now) return s.fail("§18.3.1: every $dumpports shall execute at the same simulation time", .{});
        s.ports_at = s.scheduler.now;
        const name = if (dp.name_row == none) "dumpports.vcd" else (try readmem.text(a, try eval.eval(s, a, dp.name_row))) orelse return;
        for (s.port_files.items) |f| if (std.mem.eql(u8, f.name, name)) return s.fail("§18.3.1: the same file_pathname shall not be given to two $dumpports calls", .{});
        const last = try s.arena.alloc([]u8, dp.ports.len);
        @memset(last, &.{});
        try s.port_files.append(s.arena, .{ .name = try s.arena.dupe(u8, name), .call = dp, .last = last });
        for (p.list(dp.ports)) |k| s.port_slots[p.evcd_ports[k].slot] = true;
        return request(s);
    }
    // §18.3.7: a file_pathname naming no $dumpports file is ignored; none
    // names every one.
    var want: ?[]const u8 = null;
    if (c.name != none) want = (try readmem.text(a, try eval.eval(s, a, c.name))) orelse return;
    const size = if (c.op == .limit) std.math.lossyCast(u64, (try eval.eval(s, a, c.size)).asInt() orelse 0) else 0;
    for (s.port_files.items) |*f| {
        if (want) |w| if (!std.mem.eql(u8, w, f.name)) continue;
        switch (c.op) {
            .ports => unreachable, // returned above
            .limit => f.limit = size,
            .flush => {},
            .off => if (f.started and f.on) {
                try changes(s, a, f);
                try checkpoint(s, a, f, "$dumpportsoff", true);
                f.on = false;
            },
            .on => if (f.started and !f.on) {
                f.on = true;
                try checkpoint(s, a, f, "$dumpportson", false);
            },
            .all => if (f.started and f.on) {
                try changes(s, a, f);
                try checkpoint(s, a, f, "$dumpportsall", false);
            },
        }
    }
}

/// The step's dump event: each new file's header and checkpoint, each
/// started one's changed ports.
pub fn tick(s: *State, a: Allocator) Error!void {
    for (s.port_files.items) |*f| {
        if (f.started) {
            try changes(s, a, f);
            continue;
        }
        const io = s.io orelse return s.fail("$dumpports needs a filesystem to write `{s}`", .{f.name});
        f.file = std.Io.Dir.cwd().createFile(io, f.name, .{}) catch return s.fail("cannot create the dump file `{s}`", .{f.name});
        f.started = true;
        var w: std.Io.Writer.Allocating = .init(a);
        try vcd.preamble(&w.writer, io, s.p.str(f.call.call), s.p.finest);
        try w.writer.writeAll(s.p.str(f.call.header));
        try w.writer.writeAll("$enddefinitions $end\n");
        try put(s, f, w.written());
        try checkpoint(s, a, f, "$dumpports", false);
    }
}

/// §18.3.6.1 the run is over: each started file ends with `$vcdclose`.
pub fn close(s: *State) Error!void {
    for (s.port_files.items) |*f| if (f.started) {
        var buf: [64]u8 = undefined;
        try put(s, f, std.mem.print(&buf, "$vcdclose #{d} $end\n", .{s.scheduler.now}) catch unreachable);
    };
}

/// A dumped port's slot changed (or its strength did): one event this step.
pub fn request(s: *State) Error!void {
    return vcd.request(s);
}

// ---- private ----

fn put(s: *State, f: *File, bytes: []const u8) Error!void {
    if (f.limited or bytes.len == 0) return;
    const file = f.file orelse return;
    const io = s.io orelse return;
    var out = bytes;
    // §18.3.4: at the size limit dumping stops, with a comment.
    if (f.limit) |lim| if (f.pos + bytes.len > lim) {
        out = "$comment $dumpportslimit reached $end\n";
        f.limited = true;
    };
    file.writePositionalAll(io, out, f.pos) catch return s.fail("cannot write the dump file `{s}`", .{f.name});
    f.pos += out.len;
}

fn time(f: *File, w: *std.Io.Writer, at: u64) Error!void {
    if (f.last_time == at) return;
    f.last_time = at;
    try w.print("#{d}\n", .{at});
}

fn checkpoint(s: *State, a: Allocator, f: *File, keyword: []const u8, as_x: bool) Error!void {
    var w: std.Io.Writer.Allocating = .init(a);
    try time(f, &w.writer, s.scheduler.now);
    try w.writer.print("{s}\n", .{keyword});
    for (s.p.list(f.call.ports), 0..) |k, n| {
        const port = s.p.evcd_ports[k];
        const text = if (as_x) try unknown(a, s, port) else try state(s, a, port);
        try remember(s, &f.last[n], text);
        try w.writer.print("{s} <{d}\n", .{ text, n });
    }
    try w.writer.writeAll("$end\n");
    try put(s, f, w.written());
}

fn changes(s: *State, a: Allocator, f: *File) Error!void {
    if (!f.on) return;
    var w: std.Io.Writer.Allocating = .init(a);
    for (s.p.list(f.call.ports), 0..) |k, n| {
        const text = try state(s, a, s.p.evcd_ports[k]);
        if (std.mem.eql(u8, text, f.last[n])) continue;
        if (w.written().len == 0) try time(f, &w.writer, s.scheduler.now);
        try remember(s, &f.last[n], text);
        try w.writer.print("{s} <{d}\n", .{ text, n });
    }
    try put(s, f, w.written());
}

fn remember(s: *State, last: *[]u8, text: []const u8) Error!void {
    if (last.len == text.len) return @memcpy(last.*, text);
    last.* = try s.arena.dupe(u8, text);
}

/// §18.4.3 a port's state text: per bit, MSB first, its state character
/// and its two strength digits.
fn state(s: *State, a: Allocator, port: Program.EvcdPort) Error![]u8 {
    const width = s.p.slots.items(.ty)[port.slot].width;
    const chars = try a.alloc(u8, 3 * width);
    const value = try eval.read(s, a, port.slot);
    for (0..width) |i| {
        const bit: u32 = @intCast(width - 1 - i);
        var in: Signal = .{};
        var out: Signal = .{};
        if (port.net != none) {
            for (s.p.list(port.inside)) |d| out = out.combine(resolve.contribution(s, d, bit));
            for (s.p.list(port.outside)) |d| in = in.combine(resolve.contribution(s, d, bit));
        } else out = .of(value.bit(bit), .strong, .strong); // an output declared as a variable
        const st = portState(port.dir, in, out);
        chars[i] = st.c;
        chars[width + i] = '0' + st.s0;
        chars[2 * width + i] = '0' + st.s1;
    }
    return std.fmt.allocPrint(a, "p{s} {s} {s}", .{ chars[0..width], chars[width .. 2 * width], chars[2 * width ..] });
}

/// §18.3.2 a port dumped as unknown: N, X or ? at strength 6.
fn unknown(a: Allocator, s: *State, port: Program.EvcdPort) Error![]u8 {
    const width = s.p.slots.items(.ty)[port.slot].width;
    const c: u8 = switch (port.dir) {
        .input => 'N',
        .output => 'X',
        .inout => '?',
    };
    const out = try a.alloc(u8, 3 * width + 3);
    out[0] = 'p';
    @memset(out[1..][0..width], c);
    out[1 + width] = ' ';
    @memset(out[2 + width ..][0..width], '6');
    out[2 + 2 * width] = ' ';
    @memset(out[3 + 2 * width ..][0..width], '6');
    return out;
}

fn levels(sig: Signal) [2]u8 {
    return .{ if (sig.lo < 0) @intCast(-sig.lo) else 0, if (sig.hi > 0) @intCast(sig.hi) else 0 };
}

/// §18.4.3.2 Table 18-7 the state of a port from its input side `in` and
/// its output side `out`.
fn portState(dir: Program.PortDir, in: Signal, out: Signal) PortState {
    const li = levels(in);
    const lo = levels(out);
    if (in.none() and out.none()) return .{ .c = switch (dir) {
        .input => 'Z',
        .output => 'T',
        .inout => 'f',
    }, .s0 = 0, .s1 = 0 };
    if (out.none()) return .{ .c = pick(in.collapse(), "DUN"), .s0 = li[0], .s1 = li[1] };
    if (in.none()) return .{ .c = pick(out.collapse(), "LHX"), .s0 = lo[0], .s1 = lo[1] };
    const vi = in.collapse();
    const vo = out.collapse();
    if (vi == vo and (vi == .zero or vi == .one)) {
        const side: usize = if (vi == .zero) 0 else 1;
        const strong_in = li[side] >= 5;
        const strong_out = lo[side] >= 5;
        if (strong_in == strong_out) return .{ .c = pick(vi, "01?"), .s0 = @max(li[0], lo[0]), .s1 = @max(li[1], lo[1]) };
        if (strong_in) return .{ .c = pick(vi, "du?"), .s0 = li[0], .s1 = li[1] };
        return .{ .c = pick(vi, "lh?"), .s0 = lo[0], .s1 = lo[1] };
    }
    const both = levels(in.combine(out));
    const c: u8 = switch (vi) {
        .zero => if (vo == .one) 'A' else 'a',
        .one => if (vo == .zero) 'B' else 'b',
        .x, .z => switch (vo) {
            .zero => 'C',
            .one => 'c',
            .x, .z => '?',
        },
    };
    return .{ .c = c, .s0 = both[0], .s1 = both[1] };
}

fn pick(b: logic.Bit, set: *const [3]u8) u8 {
    return switch (b) {
        .zero => set[0],
        .one => set[1],
        .x, .z => set[2],
    };
}

test "§18.4.3.2 Table 18-7 port states from the two sides" {
    const st0: Signal = .of(.zero, .strong, .strong);
    const st1: Signal = .of(.one, .strong, .strong);
    const weak0: Signal = .of(.zero, .weak, .weak);
    try std.testing.expectEqual(PortState{ .c = '1', .s0 = 0, .s1 = 6 }, portState(.inout, st1, st1));
    try std.testing.expectEqual(PortState{ .c = 'l', .s0 = 6, .s1 = 0 }, portState(.inout, weak0, st0));
    try std.testing.expectEqual(PortState{ .c = 'A', .s0 = 6, .s1 = 6 }, portState(.inout, st0, st1));
    try std.testing.expectEqual(PortState{ .c = 'T', .s0 = 0, .s1 = 0 }, portState(.output, .{}, .{}));
}
