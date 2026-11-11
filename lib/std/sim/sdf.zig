//! IEEE 1364-2005 §17.2.10 `$sdf_annotate` and the §16 SDF annotator: the
//! file read as OVI SDF 3.0 S-expressions (`sdf_text.parse`), then each
//! CELL's constructs mapped onto the instances it names, as §16.2's tables
//! map them: IOPATH onto module path tables (Table 16-1), INTERCONNECT onto
//! the load instance's continuous drivers (§16.2.4), LABEL onto specparams
//! with the paths reading them re-folded (§16.2.3), TIMINGCHECK onto §15
//! check limits (Table 16-2), PATHPULSE onto path reject and error limits.
//! ABSOLUTE replaces, INCREMENT adds (§16.3), in file order (§16.4). What is
//! not applied warns; a file that cannot be read or parsed ends the run.
//! What it changes is the run's (`State.paths`, `State.drv_delay`,
//! `tchk.Run.lim`); the names it matches are `Program.SdfScope`'s.
//! Cites: IEEE 1364-2005 §16.1-§16.6, §17.2.10, §19.8; OVI SDF 3.0.
//!
//! Contents:
//! - `pub fn annotate(s: *State, a: Allocator, at: u32) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Program = @import("Program.zig");
const State = @import("State.zig");
const eval = @import("eval.zig");
const logic = @import("logic.zig");
const net = @import("net.zig");
const readmem = @import("readmem.zig");
const sdf_text = @import("sdf_text.zig");
const Error = State.Error;
const Node = sdf_text.Node;
const Bit = logic.Bit;

const none = @backingInt(Program.Ref.none);

/// One annotation's file and settings: its name, mtm_spec member, DIVIDER
/// and TIMESCALE.
const Ctx = struct {
    s: *State,
    a: Allocator,
    file: []const u8,
    mtm: u2 = 1,
    divider: u8 = '.',
    ts_mult: f64 = 1,
    ts_exp: i32 = -9,

    fn warn(c: *Ctx, line: u32, comptime f: []const u8, args: anytype) Error!void {
        try c.s.warn(.W1105, "{s}:{d}: " ++ f, .{ c.file, line } ++ args);
    }

    /// `v` in the file's timescale as ticks of scope `scope`'s precision,
    /// rounded as a real delay is (§19.8); null when no delay holds it.
    fn ticks(c: *Ctx, scope: u32, v: f64) ?i128 {
        const p = c.s.p;
        const tm = p.times[p.scopes[scope].time];
        const k = c.ts_exp - tm.unit_exp;
        const pw = std.math.pow(f64, 10, @floatFromInt(@abs(k)));
        const units = @abs(v) * c.ts_mult;
        const scaled = if (k >= 0) units * pw else units / pw;
        const t = tm.scale.realDelay(scaled) catch return null;
        return if (v < 0) -@as(i128, t) else t;
    }
};

/// An SDF port_spec: a port name and its edge.
const PortSpec = struct { name: []const u8, edge: Program.Edge = .any };

/// Table 16-4's twelve positions, (from, to).
const positions = [12][2]Bit{
    .{ .zero, .one }, .{ .one, .zero }, .{ .zero, .z }, .{ .z, .one },  .{ .one, .z }, .{ .z, .zero },
    .{ .zero, .x },   .{ .x, .one },    .{ .one, .x },  .{ .x, .zero }, .{ .x, .z },   .{ .z, .x },
};

/// The `Program.SdfCall` at `at` in `extra`, run.
pub fn annotate(s: *State, a: Allocator, at: u32) Error!void {
    const p = s.p;
    const call = p.extraData(Program.SdfCall, at);
    const name = (try readmem.text(a, try eval.eval(s, a, call.name))) orelse return s.fail(.E1102, "$sdf_annotate's file name has x or z bits", .{});
    var c: Ctx = .{ .s = s, .a = a, .file = name };
    if (call.mtm != none) {
        const m = (try readmem.text(a, try eval.eval(s, a, call.mtm))) orelse "";
        c.mtm = if (std.ascii.eqlIgnoreCase(m, "MINIMUM")) 0 else if (std.ascii.eqlIgnoreCase(m, "MAXIMUM")) 2 else if (std.ascii.eqlIgnoreCase(m, "TYPICAL") or std.ascii.eqlIgnoreCase(m, "TOOL_CONTROL")) 1 else return s.fail(.E1102, "§17.2.10: mtm_spec is \"MINIMUM\", \"TYPICAL\", \"MAXIMUM\" or \"TOOL_CONTROL\"", .{});
    }
    const io = s.io orelse return s.fail(.E1102, "{s}: the SDF file cannot be read", .{name});
    const file = readmem.sideFile(io, a, p.str(p.file_name), name) catch return s.fail(.E1102, "{s}: the SDF file cannot be read", .{name});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var in = file.reader(io, &buf);
    const text = in.interface.allocRemaining(a, .unlimited) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return s.fail(.E1102, "{s}: the SDF file cannot be read", .{name}),
    };
    var line: u32 = 0;
    const top = sdf_text.parse(a, text, &line) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => return s.fail(.E1102, "{s}:{d}: not an SDF file: unbalanced parentheses or a stray token", .{ name, line }),
        error.TooDeep => return s.fail(.E1102, "{s}:{d}: the SDF file nests lists deeper than {d}", .{ name, line, sdf_text.depth_max }),
    };
    if (!top.is("DELAYFILE")) return s.fail(.E1102, "{s}:{d}: an SDF file is one (DELAYFILE ...)", .{ name, top.line });
    for (top.kids[1..]) |h| {
        if (h.is("TIMESCALE")) try timescale(&c, h) else if (h.is("DIVIDER")) {
            const d = if (h.kids.len == 2) h.kids[1].atom orelse "" else "";
            if (d.len != 1 or (d[0] != '.' and d[0] != '/')) return s.fail(.E1102, "{s}:{d}: DIVIDER is . or /", .{ name, h.line });
            c.divider = d[0];
        } else if (h.is("CELL")) try cell(&c, h, call.scope);
        // else: the header entries inform and set nothing.
    }
}

// ---- private ----

fn timescale(c: *Ctx, h: Node) Error!void {
    var text: std.ArrayList(u8) = .empty;
    for (h.kids[1..]) |k| try text.appendSlice(c.a, k.atom orelse "");
    const t = text.items;
    var i: usize = 0;
    while (i < t.len and (std.ascii.isDigit(t[i]) or t[i] == '.')) i += 1;
    const mult = std.fmt.parseFloat(f64, t[0..i]) catch 0;
    const units = [_]struct { []const u8, i32 }{ .{ "s", 0 }, .{ "ms", -3 }, .{ "us", -6 }, .{ "ns", -9 }, .{ "ps", -12 }, .{ "fs", -15 } };
    for (units) |u| if (std.ascii.eqlIgnoreCase(t[i..], u[0]) and (mult == 1 or mult == 10 or mult == 100)) {
        c.ts_mult = mult;
        c.ts_exp = u[1];
        return;
    };
    return c.s.fail(.E1102, "{s}:{d}: TIMESCALE is 1, 10 or 100 of s, ms, us, ns, ps or fs", .{ c.file, h.line });
}

fn cell(c: *Ctx, h: Node, scope: u32) Error!void {
    const p = c.s.p;
    var celltype: []const u8 = "";
    var targets: std.ArrayList(u32) = .empty;
    var named = false;
    for (h.kids[1..]) |k| {
        if (k.is("CELLTYPE")) {
            celltype = if (k.kids.len == 2) k.kids[1].atom orelse "" else "";
        } else if (k.is("INSTANCE")) {
            named = true;
            if (k.kids.len == 1) {
                try targets.append(c.a, scope);
            } else if (std.mem.eql(u8, k.kids[1].atom orelse "", "*")) {
                for (p.sdf_scopes, 0..) |info, sc| {
                    if (info.lexical or sc == scope or !below(p, @intCast(sc), scope)) continue;
                    if (std.mem.eql(u8, p.str(info.module), celltype)) try targets.append(c.a, @intCast(sc));
                }
            } else {
                const parts = try splitPath(c.a, k.kids[1].atom orelse "", c.divider);
                if (child(p, scope, parts)) |sc| try targets.append(c.a, sc) else try c.warn(k.line, "INSTANCE {s} names no instance below the annotation scope; the cell is not applied", .{k.kids[1].atom orelse "(...)"});
            }
        }
    }
    if (!named) try targets.append(c.a, scope);
    for (targets.items) |sc| for (h.kids[1..]) |k| {
        if (k.is("DELAY")) {
            for (k.kids[1..]) |d| {
                if (d.is("ABSOLUTE") or d.is("INCREMENT")) {
                    for (d.kids[1..]) |e| {
                        if (e.is("IOPATH")) try ioPath(c, sc, e, d.is("INCREMENT")) else if (e.is("INTERCONNECT")) try interconnect(c, sc, e) else try c.warn(e.line, "{s} is not applied", .{e.head()});
                    }
                } else if (d.is("PATHPULSE")) try pathPulse(c, sc, d) else try c.warn(d.line, "DELAY's {s} is not applied", .{d.head()});
            }
        } else if (k.is("TIMINGCHECK")) {
            for (k.kids[1..]) |t| try timingCheck(c, sc, t);
        } else if (k.is("LABEL")) {
            for (k.kids[1..]) |d| {
                if (!(d.is("ABSOLUTE") or d.is("INCREMENT"))) {
                    try c.warn(d.line, "LABEL's {s} is not applied", .{d.head()});
                    continue;
                }
                for (d.kids[1..]) |e| try label(c, sc, e, d.is("INCREMENT"));
            }
        } else if (!(k.is("CELLTYPE") or k.is("INSTANCE"))) try c.warn(k.line, "CELL's {s} is not applied", .{k.head()});
    };
}

fn below(p: *const Program, s: u32, top: u32) bool {
    var at = s;
    var steps: usize = 0;
    while (at != top) : (steps += 1) {
        assert(steps < p.scopes.len);
        const parent = p.scopes[at].parent;
        if (parent == at) return false;
        at = parent;
    }
    return true;
}

fn child(p: *const Program, scope: u32, parts: []const []const u8) ?u32 {
    var at = scope;
    for (parts) |part| {
        at = for (p.scopes, 0..) |info, sc| {
            if (sc != at and info.parent == at and !p.sdf_scopes[sc].lexical and std.mem.eql(u8, p.str(info.name), part)) break @intCast(sc);
        } else return null;
    }
    return at;
}

/// The slot port `name` of instance `scope` is, or null.
fn portSlot(p: *const Program, scope: u32, name: []const u8) ?u32 {
    const triples = p.list(p.sdf_scopes[scope].ports);
    var k: usize = 0;
    while (k < triples.len) : (k += 3) {
        if (std.mem.eql(u8, p.str(.{ .start = triples[k], .len = triples[k + 1] }), name)) return if (triples[k + 2] == none) null else triples[k + 2];
    }
    return null;
}

fn unescape(a: Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len) i += 1;
        try out.append(a, raw[i]);
    }
    return out.items;
}

fn splitPath(a: Allocator, raw: []const u8, divider: u8) ![]const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\') {
            i += 1;
            continue;
        }
        if (raw[i] == divider) {
            try parts.append(a, try unescape(a, raw[start..i]));
            start = i + 1;
        }
    }
    try parts.append(a, try unescape(a, raw[start..]));
    return parts.items;
}

fn portSpec(c: *Ctx, n: Node) Error!?PortSpec {
    var edge: Program.Edge = .any;
    var raw = n.atom;
    if (raw == null) {
        if (n.kids.len != 2 or n.kids[1].atom == null) return null;
        edge = if (n.is("posedge")) .posedge else if (n.is("negedge")) .negedge else return null;
        raw = n.kids[1].atom;
    }
    var name = try unescape(c.a, raw.?);
    if (std.mem.indexOfScalar(u8, name, '[')) |b| name = name[0..b];
    return .{ .name = name, .edge = edge };
}

fn rvalues(c: *Ctx, kids: []const Node) error{ Syntax, OutOfMemory }![]const ?f64 {
    const out = try c.a.alloc(?f64, kids.len);
    for (kids, out) |k, *o| o.* = try sdf_text.rvalue(k, c.mtm);
    return out;
}

/// The nets port slot `slot` is, or the nets its port windows drive.
fn destNets(c: *Ctx, slot: u32) Error![]const u32 {
    const s = c.s;
    if (s.netOf(slot)) |n| return c.a.dupe(u32, &.{n});
    var out: std.ArrayList(u32) = .empty;
    for (s.p.drivers) |d| if (d.source == .bridge and d.source.bridge.src == slot) try out.append(c.a, d.net);
    return out.items;
}

fn ioPath(c: *Ctx, sc: u32, e: Node, increment: bool) Error!void {
    const s = c.s;
    const p = s.p;
    if (e.kids.len < 4) return c.warn(e.line, "IOPATH names an input, an output and its values", .{});
    const in = (try portSpec(c, e.kids[1])) orelse return c.warn(e.line, "IOPATH's input is a port or (posedge|negedge port)", .{});
    const out = (try portSpec(c, e.kids[2])) orelse return c.warn(e.line, "IOPATH's output is a port", .{});
    var kids = e.kids[3..];
    if (kids.len != 0 and kids[0].is("RETAIN")) kids = kids[1..];
    const vals = rvalues(c, kids) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => return c.warn(e.line, "IOPATH has a malformed value", .{}),
    };
    if (!(vals.len == 1 or vals.len == 2 or vals.len == 3 or vals.len == 6 or vals.len == 12)) return c.warn(e.line, "IOPATH has 1, 2, 3, 6 or 12 values, not {d}", .{vals.len});
    const src = portSlot(p, sc, in.name) orelse return c.warn(e.line, "IOPATH input {s} is no port of this instance", .{in.name});
    const dst = portSlot(p, sc, out.name) orelse return c.warn(e.line, "IOPATH output {s} is no port of this instance", .{out.name});
    var hit = false;
    for (try destNets(c, dst)) |n| {
        const r = p.nets[n].paths;
        for (s.paths[r.start..][0..r.len]) |*path| {
            if (path.scope != sc or path.src != src) continue;
            if (in.edge != .any and path.edge != .any and path.edge != in.edge) continue;
            hit = true;
            var d: [12]u64 = undefined;
            for (vals, 0..) |v, k| {
                const old = path.table[@backingInt(positions[k][0])][@backingInt(positions[k][1])];
                const t = if (v) |x| c.ticks(sc, x) orelse return c.warn(e.line, "IOPATH value {d} is no delay", .{x}) else null;
                d[k] = if (t) |x| @intCast(std.math.clamp(if (increment) @as(i128, old) + x else x, 0, std.math.maxInt(u64))) else old;
            }
            path.table = net.pathTable(d[0..vals.len]);
        }
    }
    if (!hit) try c.warn(e.line, "IOPATH {s} {s} names no module path of this instance", .{ in.name, out.name });
}

// ponytail: a process or a path in the load instance still sees the port
// undelayed; a per-load copy of the net is the upgrade (the old engine's).
fn interconnect(c: *Ctx, sc: u32, e: Node) Error!void {
    const s = c.s;
    const p = s.p;
    if (e.kids.len < 4 or e.kids[2].atom == null) return c.warn(e.line, "INTERCONNECT names a source, a load and its values", .{});
    const parts = try splitPath(c.a, e.kids[2].atom.?, c.divider);
    const inst = child(p, sc, parts[0 .. parts.len - 1]) orelse return c.warn(e.line, "INTERCONNECT load {s} names no instance port", .{e.kids[2].atom.?});
    var port = parts[parts.len - 1];
    if (std.mem.indexOfScalar(u8, port, '[')) |b| port = port[0..b];
    const slot = portSlot(p, inst, port) orelse return c.warn(e.line, "INTERCONNECT load {s} names no instance port", .{e.kids[2].atom.?});
    const vals = rvalues(c, e.kids[3..]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => return c.warn(e.line, "INTERCONNECT has a malformed value", .{}),
    };
    if (vals.len == 0 or vals.len > 3) return c.warn(e.line, "INTERCONNECT has 1, 2 or 3 values", .{});
    var t: [3]u64 = .{ 0, 0, 0 };
    for (vals, 0..) |v, k| t[k] = @intCast(@max(0, if (v) |x| c.ticks(inst, x) orelse 0 else 0));
    if (vals.len < 2) t[1] = t[0];
    if (vals.len < 3) t[2] = @min(t[0], t[1]);
    var hit = false;
    for (p.drivers, s.drv_delay) |d, *dl| {
        if (d.scope != inst or std.mem.indexOfScalar(u32, p.list(d.sensitivity), slot) == null) continue;
        hit = true;
        dl.* = .{ .present = true, .rise = dl.rise +| t[0], .fall = dl.fall +| t[1], .off = dl.off +| t[2] };
    }
    if (!hit) try c.warn(e.line, "INTERCONNECT load {s} feeds no continuous driver, so no delay applies", .{e.kids[2].atom.?});
}

/// §16.2.3 a specparam set, and every path of the instance whose delay
/// reads one re-folded from its delay rows.
fn label(c: *Ctx, sc: u32, e: Node, increment: bool) Error!void {
    const s = c.s;
    const p = s.p;
    if (e.kids.len != 2 or e.kids[0].atom == null) return c.warn(e.line, "a LABEL entry is (specparam value)", .{});
    const name = try unescape(c.a, e.kids[0].atom.?);
    const triples = p.list(p.sdf_scopes[sc].specparams);
    const at = blk: {
        var k: usize = 0;
        while (k < triples.len) : (k += 3) {
            if (std.mem.eql(u8, p.str(.{ .start = triples[k], .len = triples[k + 1] }), name)) break :blk triples[k + 2];
        }
        return c.warn(e.line, "LABEL {s} is no specparam of this instance", .{name});
    };
    const v = (sdf_text.rvalue(e.kids[1], c.mtm) catch return c.warn(e.line, "LABEL {s} has a malformed value", .{name})) orelse return;
    const tm = p.times[p.scopes[sc].time];
    const k = c.ts_exp - tm.unit_exp;
    const pw = std.math.pow(f64, 10, @floatFromInt(@abs(k)));
    var units = v * c.ts_mult;
    units = if (k >= 0) units * pw else units / pw;
    // The specparam's own storage, written as elaboration wrote it: no
    // process watches a specparam.
    const sl = p.slots.get(at);
    const n = Program.words(sl.ty.width);
    const dv = s.v[sl.word..][0..n];
    const dx = s.x[sl.word..][0..n];
    if (sl.ty.real) {
        const old: f64 = @bitCast(dv[0]);
        dv[0] = @bitCast(if (increment) old + units else units);
    } else {
        const cur = try eval.read(s, c.a, at);
        const old: f64 = @floatFromInt(cur.asInt() orelse 0);
        const iv = try logic.intOfReal(c.a, if (increment) old + units else units);
        @memset(dx, 0);
        for (dv, 0..) |*w, i| w.* = if (i < iv.values().len) iv.values()[i] else if (iv.values()[iv.values().len - 1] >> 63 != 0) std.math.maxInt(u64) else 0;
        if (sl.ty.width % 64 != 0) dv[n - 1] &= (@as(u64, 1) << @intCast(sl.ty.width % 64)) - 1;
    }
    for (s.paths) |*q| {
        if (q.scope != sc or q.delays.len == 0) continue;
        var ticks: [12]u64 = undefined;
        for (p.list(q.delays), ticks[0..q.delays.len]) |row, *t| t.* = try refold(s, c.a, row, sc);
        q.table = net.pathTable(ticks[0..q.delays.len]);
    }
}

/// One A.7.4 path delay row folded as elaboration folds it: a negative
/// integer is 0, a real rounds to the precision.
fn refold(s: *State, a: Allocator, row: u32, sc: u32) Error!u64 {
    const p = s.p;
    const scale = p.times[p.scopes[sc].time].scale;
    if (p.exprs.items(.ty)[row].real) return scale.realDelay(try eval.real(s, a, row)) catch s.fail(.E1102, "digital delay cannot be represented", .{});
    const v = try eval.eval(s, a, row);
    const i = v.asInt() orelse return s.fail(.E1102, "a declared delay cannot contain x or z", .{});
    if (v.signed and i < 0) return 0;
    return scale.signedDelay(i) catch s.fail(.E1102, "digital delay cannot be represented", .{});
}

fn timingCheck(c: *Ctx, sc: u32, e: Node) Error!void {
    const s = c.s;
    const p = s.p;
    const K = Program.Check.Kind;
    const Fam = struct { []const u8, []const K, u2, u2 };
    const fams = [_]Fam{
        .{ "SETUP", &.{ .setup, .setuphold }, 2, 1 },
        .{ "HOLD", &.{ .hold, .setuphold }, 2, 1 },
        .{ "SETUPHOLD", &.{.setuphold}, 2, 2 },
        .{ "RECOVERY", &.{ .recovery, .recrem }, 2, 1 },
        .{ "REMOVAL", &.{ .removal, .recrem }, 2, 1 },
        .{ "RECREM", &.{.recrem}, 2, 2 },
        .{ "WIDTH", &.{.width}, 1, 1 },
        .{ "PERIOD", &.{.period}, 1, 1 },
    };
    const fam = for (fams) |f| {
        if (e.is(f[0])) break f;
    } else return c.warn(e.line, "TIMINGCHECK's {s} is not applied", .{e.head()});
    if (e.kids.len < 1 + @as(usize, fam[2]) + fam[3]) return c.warn(e.line, "{s} names {d} ports and {d} values", .{ fam[0], fam[2], fam[3] });
    var slots: [2]u32 = undefined;
    for (0..fam[2]) |k| {
        const ps = (try portSpec(c, e.kids[1 + k])) orelse return c.warn(e.line, "{s}'s port is a port or (posedge|negedge port)", .{fam[0]});
        slots[k] = portSlot(p, sc, ps.name) orelse return c.warn(e.line, "{s} port {s} is no port of this instance", .{ fam[0], ps.name });
    }
    const vals = rvalues(c, e.kids[1 + fam[2] ..][0..fam[3]]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => return c.warn(e.line, "{s} has a malformed value", .{fam[0]}),
    };
    var hit = false;
    for (p.checks, s.checks) |t, *st| {
        if (t.scope != sc or std.mem.indexOfScalar(K, fam[1], t.kind) == null) continue;
        const ok = if (fam[2] == 1) t.ev[0].slot == slots[0] else (t.ev[0].slot == slots[0] and t.ev[1].slot == slots[1]) or (t.ev[0].slot == slots[1] and t.ev[1].slot == slots[0]);
        if (!ok) continue;
        hit = true;
        for (vals, 0..) |v, k| {
            const x = v orelse continue;
            const ticks: u64 = @intCast(@max(0, c.ticks(sc, x) orelse 0));
            const at: usize = if (fam[3] == 2) (if (std.mem.eql(u8, fam[0], "SETUPHOLD")) k else 1 - k) else if (std.mem.eql(u8, fam[0], "HOLD") or std.mem.eql(u8, fam[0], "RECOVERY")) 1 else 0;
            st.lim[at] = ticks;
        }
    }
    if (!hit) try c.warn(e.line, "{s} names no timing check of this instance", .{fam[0]});
}

fn pathPulse(c: *Ctx, sc: u32, e: Node) Error!void {
    const s = c.s;
    const p = s.p;
    var kids = e.kids[1..];
    var ends: ?[2]u32 = null;
    if (kids.len >= 2 and kids[0].atom != null) {
        const in = (try portSpec(c, kids[0])) orelse return c.warn(e.line, "PATHPULSE's input is a port", .{});
        const out = (try portSpec(c, kids[1])) orelse return c.warn(e.line, "PATHPULSE's output is a port", .{});
        ends = .{
            portSlot(p, sc, in.name) orelse return c.warn(e.line, "PATHPULSE input {s} is no port of this instance", .{in.name}),
            portSlot(p, sc, out.name) orelse return c.warn(e.line, "PATHPULSE output {s} is no port of this instance", .{out.name}),
        };
        kids = kids[2..];
    }
    if (kids.len == 0 or kids.len > 2) return c.warn(e.line, "PATHPULSE has a reject limit and an optional error limit", .{});
    const vals = rvalues(c, kids) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => return c.warn(e.line, "PATHPULSE has a malformed value", .{}),
    };
    const reject: ?u64 = if (vals[0]) |v| @intCast(@max(0, c.ticks(sc, v) orelse 0)) else null;
    const err: ?u64 = if (vals.len == 2) (if (vals[1]) |v| @as(u64, @intCast(@max(0, c.ticks(sc, v) orelse 0))) else null) else reject;
    const nets: []const u32 = if (ends) |x| try destNets(c, x[1]) else blk: {
        var all: std.ArrayList(u32) = .empty;
        for (p.nets, 0..) |n, k| if (n.cold) try all.append(c.a, @intCast(k));
        break :blk all.items;
    };
    var hit = false;
    for (nets) |n| {
        const r = p.nets[n].paths;
        for (s.paths[r.start..][0..r.len]) |*path| {
            if (path.scope != sc) continue;
            if (ends) |x| if (path.src != x[0]) continue;
            hit = true;
            if (reject) |v| path.reject = v;
            if (err) |v| path.err = @max(v, path.reject orelse v);
        }
    }
    if (!hit) try c.warn(e.line, "PATHPULSE names no module path of this instance", .{});
}
