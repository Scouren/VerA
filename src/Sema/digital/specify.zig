//! Specify blocks of the digital lowering: a `specify` of frame `f` in; its
//! specparams bound to slots, per module path one `Program.Path` row per
//! source on each destination net, with §14.6's pulse limits and pulse
//! styles (`nets.finish` lays the rows out per net), and its timing checks
//! (`tchk.zig`), out. As lib/sim/digital builds them: a destination's
//! select is read as its whole net and a parallel path as a full one; a
//! variable output port's path times the net its §12.3.3 bridge drives.
//! Cites: IEEE 1364-2005 §14.2, §14.3, §14.6, §15.
//!
//! Contents:
//! - `pub fn block(l: *Lower, f: u32, i: Inst.Index) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const std_sim = @import("std_sim");
const digital = @import("../digital.zig");
const expr = @import("expr.zig");
const place = @import("place.zig");
const vars = @import("vars.zig");
const tchk = @import("tchk.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const none = digital.none;
const Program = std_sim.Program;
const net = std_sim.net;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// The `PATHPULSE$` prefix of §14.6.1's pulse limit specparams.
const pathpulse = "PATHPULSE$";

/// Specify block `i` of frame `f`: its specparams, then its module paths
/// and pulse style declarations, then its timing checks.
pub fn block(l: *Lower, f: u32, i: Inst.Index) Error!void {
    const vir = l.virOf(f);
    const items = vir.body(Lower.payload(vir, Inst.Process, i).body);
    const saved = l.frame;
    defer l.frame = saved;
    l.frame = f;
    for (items) |d| if (Lower.tag(vir, d) == .param) {
        if (!std.mem.startsWith(u8, vir.string(Lower.payload(vir, Inst.Param, d).name), pathpulse)) _ = try vars.param(l, f, d);
    };
    for (items) |d| switch (Lower.tag(vir, d)) {
        .path => try path(l, f, items, d),
        .timing_check => try tchk.check(l, f, d),
        else => {}, // else: a specparam (above), a pulse style (below), an expression
    };
    for (items) |d| if (Lower.tag(vir, d) == .pulse_style) try pulseStyle(l, vir, d);
}

// ---- private ----

/// §14.2 one module path: per destination net, a row per source.
fn path(l: *Lower, f: u32, items: []const Inst.Index, i: Inst.Index) Error!void {
    const vir = l.virOf(f);
    const p = Lower.payload(vir, Inst.Path, i);
    const scope = l.frames.items[f].scope;
    const delays = vir.list(Inst.Ref, p.delays.values);
    switch (delays.len) {
        1, 2, 3, 6, 12 => {},
        else => return l.refuse("§14.3.1 a path with other than 1, 2, 3, 6 or 12 delays"),
    }
    var ticks: [12]u64 = undefined;
    const rows = try l.a.alloc(u32, delays.len);
    for (delays, ticks[0..delays.len], rows) |d, *t, *row| {
        t.* = try delayTicks(l, f, d);
        row.* = try expr.selfOrReal(l, d);
    }
    const table = net.pathTable(ticks[0..delays.len]);
    const delay_rows = try l.b.listOf(rows);
    const cond_body = vir.body(p.cond);
    const cond: u32 = if (cond_body.len == 0) none else try expr.self_(l, cond_body[cond_body.len - 1].toRef(), 0);
    const edge: Program.Edge = switch (p.flags.edge) {
        .none => .any,
        .posedge => .posedge,
        .negedge => .negedge,
    };
    for (vir.list(Inst.Ref, p.outputs.values)) |o| {
        const dst = try baseName(l, o);
        var dests: std.ArrayList(u32) = .empty;
        if (dst.n.kind == .net) {
            try dests.append(l.a, dst.n.net);
        } else for (l.wires.items) |w| if (w.source == .bridge and w.source.bridge.src == dst.n.slot) try dests.append(l.a, w.net);
        for (vir.list(Inst.Ref, p.inputs.values)) |in| {
            const src = try baseName(l, in);
            const lim = try pulseLimits(l, f, items, src.text, dst.text);
            const row: Program.Path = .{ .src = src.n.slot, .src_bit = src.bit, .edge = edge, .cond = cond, .ifnone = p.flags.ifnone, .scope = scope, .table = table, .reject = lim[0], .err = lim[1], .delays = delay_rows };
            for (dests.items) |n| try l.nets.items[n].paths.append(l.a, row);
        }
    }
}

/// A path terminal: the name it is or selects from, its text, and the bit
/// a constant bit-select of it picks (0 otherwise).
fn baseName(l: *Lower, r: Inst.Ref) Error!struct { n: digital.Name, text: []const u8, bit: u32 } {
    const vir = l.virOf(l.frame);
    const i = r.toIndex() orelse return l.refuse("an omitted path terminal");
    var leaf = i;
    var bit: u32 = 0;
    switch (Lower.tag(vir, i)) {
        .decl_ref, .str_ref => {},
        .elem, .slice, .slice_up, .slice_down => {
            const s = try place.selectOf(l, i);
            const first: i64 = switch (s.mode) {
                .const_part => s.first,
                .bit, .up, .down => blk: {
                    const idx = try l.intOf(l.frame, s.index);
                    break :blk if (s.name.msb >= s.name.lsb) idx -| s.name.lsb else s.name.lsb -| idx;
                },
            };
            bit = std.math.cast(u32, @max(first, 0)) orelse return l.refuse("§14.2 a path terminal select outside its port");
            const base = if (Lower.tag(vir, i) == .elem) Lower.payload(vir, Inst.Bin, i).lhs else Lower.payload(vir, Inst.Triple, i).a;
            leaf = base.toIndex() orelse return l.refuse("a path terminal select of nothing");
            if (Lower.tag(vir, leaf) != .decl_ref) return l.refuse("a path terminal select of no name");
        },
        else => return l.refuse("a path terminal that is no name or select"),
    }
    const n = try expr.leafName(l, leaf);
    if (n.kind != .net and n.kind != .variable) return l.refuse("§14.2.1 a path terminal that is no net or variable");
    const d = vir.instructions.items(.data)[@backingInt(leaf)];
    const text = if (Lower.tag(vir, leaf) == .decl_ref) declText(vir, d.decl_tok.decl) else vir.string(d.str_tok.start);
    return .{ .n = n, .text = text, .bit = bit };
}

fn declText(vir: *const Vir, d: Inst.Index) []const u8 {
    return vir.string(switch (Lower.tag(vir, d)) {
        .variable => Lower.payload(vir, Inst.Variable, d).name,
        .net => Lower.payload(vir, Inst.Net, d).name,
        .io => Lower.payload(vir, Inst.Io, d).name,
        else => return "", // else: no other declaration is a path terminal
    });
}

/// §14.3.1 a path delay folded to ticks; "a negative value shall be
/// treated as zero".
fn delayTicks(l: *Lower, f: u32, r: Inst.Ref) Error!u64 {
    const c = (try l.constOf(f, r)) orelse return l.refuse("a path delay Sema/eval.zig does not fold");
    const scale = l.b.times.items[l.frames.items[f].scope].scale;
    return switch (c) {
        .int => |v| if (v < 0) 0 else scale.signedDelay(v) catch l.refuse("a delay past 2^64 ticks"),
        .real => |v| if (v < 0) 0 else scale.realDelay(v) catch l.refuse("a delay past 2^64 ticks"),
        .str => l.refuse("a string path delay"),
    };
}

/// §14.6.1 the reject and error limits of the path from `in` to `out`:
/// `PATHPULSE$in$out`, else the block's `PATHPULSE$`, else none (the path
/// delay). A reject limit alone is both.
fn pulseLimits(l: *Lower, f: u32, items: []const Inst.Index, in: []const u8, out: []const u8) Error![2]?u64 {
    const vir = l.virOf(f);
    const specific = try std.fmt.allocPrint(l.a, "{s}{s}${s}", .{ pathpulse, in, out });
    var pick: ?Inst.Param = null;
    var pick_specific = false;
    for (items) |d| {
        if (Lower.tag(vir, d) != .param) continue;
        const p = Lower.payload(vir, Inst.Param, d);
        const name = vir.string(p.name);
        if (std.mem.eql(u8, name, specific)) {
            pick = p;
            pick_specific = true;
        } else if (std.mem.eql(u8, name, pathpulse) and !pick_specific) pick = p;
    }
    const p = pick orelse return .{ null, null };
    const b = vir.body(p.value);
    if (b.len == 0) return l.refuse("a PATHPULSE$ specparam with no value");
    const last = b[b.len - 1];
    if (Lower.tag(vir, last) != .pulse_limits) {
        const reject = try delayTicks(l, f, last.toRef());
        return .{ reject, reject };
    }
    const lim = Lower.payload(vir, Inst.Bin, last);
    const reject = try delayTicks(l, f, lim.lhs);
    const err = if (lim.rhs == .none) reject else try delayTicks(l, f, lim.rhs);
    return .{ reject, @max(reject, err) };
}

/// §14.6.4 a pulse style or showcancelled declaration: on every net its
/// outputs name, the last of each pair winning.
fn pulseStyle(l: *Lower, vir: *const Vir, i: Inst.Index) Error!void {
    const ps = Lower.payload(vir, Inst.PulseStyle, i);
    const kw = vir.string(ps.keyword);
    for (vir.list(Inst.Ref, ps.terms.values)) |t| {
        const n = (try baseName(l, t)).n;
        if (n.kind != .net) continue;
        const row = &l.nets.items[n.net];
        if (std.mem.eql(u8, kw, "pulsestyle_ondetect")) row.ondetect = true;
        if (std.mem.eql(u8, kw, "pulsestyle_onevent")) row.ondetect = false;
        if (std.mem.eql(u8, kw, "showcancelled")) row.showcancelled = true;
        if (std.mem.eql(u8, kw, "noshowcancelled")) row.showcancelled = false;
    }
    assert(kw.len != 0);
}
