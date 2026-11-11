//! Timing checks of the digital lowering: an A.7.5 `system_timing_check` of
//! a specify block in; one `Program.Check` row (its reference and data
//! events bound to the slots they name, its limits in ticks, its notifier,
//! conditions and flags) and the byte its W1199 report is filed at, out; at
//! the end, per slot the check codes its change reaches (`tchk.arm`'s
//! order). As lib/sim/digital builds them, the negative timing option off:
//! a negative `$setuphold`/`$recrem` limit is 0 and their delayed signals
//! are zero-delay copies (§15.5.4).
//! Cites: IEEE 1364-2005 §15.1-§15.6, A.7.5.
//!
//! Contents:
//! - `pub fn check(l: *Lower, f: u32, i: Inst.Index) Error!void`
//! - `pub fn finish(l: *Lower) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const std_sim = @import("std_sim");
const digital = @import("../digital.zig");
const expr = @import("expr.zig");
const place = @import("place.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const none = digital.none;
const Program = std_sim.Program;
const Bit = std_sim.logic.Bit;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// §15.4 `posedge` (01, 0x, x1) and `negedge` (10, x0, 1x); bits 0..5 are
/// the transitions 01, 0x, 10, 1x, x0, x1.
const posedge_mask: u8 = 0b100011;
const negedge_mask: u8 = 0b011100;

/// Timing check `i` of frame `f` (the instance whose specify block wrote
/// it): its `Program.Check` row (its `name` the W1199 report's quoted
/// text, lib/sim/digital's own words) and its report site.
pub fn check(l: *Lower, f: u32, i: Inst.Index) Error!void {
    const vir = l.virOf(f);
    const t = Lower.payload(vir, Inst.TimingCheck, i);
    const args = vir.list(Inst.Ref, t.args.values);
    const name = vir.string(t.name);
    const kind = std.meta.stringToEnum(Program.Check.Kind, name[1..]) orelse return l.refuseFmt("the timing check `{s}`", .{name});
    if (args.len == 0) return l.refuse("a timing check with no argument");
    const arg = struct {
        fn at(a: []const Inst.Ref, k: usize) Inst.Ref {
            return if (k < a.len) a[k] else .none;
        }
    }.at;
    // W1199's quoted name, lib/sim/digital's words: the task as written
    // (`name` keeps its leading `$`) and the scope's hierarchical path.
    const check_name = try std.fmt.allocPrint(l.a, "`{s}` in {f}", .{ name, l.zcu.fmtPath(l.frames.items[f].instance) });
    var c: Program.Check = .{ .kind = kind, .scope = l.frames.items[f].scope, .name = try l.b.string(check_name), .ev = .{ .{}, .{} }, .lim = .{ 0, 0 }, .notifier = none, .stamp_cond = .{}, .check_cond = .{}, .event_based = false, .remain_active = false, .delay = .{ 0, 0 }, .v = .{ 0, 0 }, .x = .{ 0, 0 } };
    switch (kind) {
        .width, .period => {
            try event(l, &c, 0, args[0]);
            c.ev[1] = c.ev[0];
            c.v[1] = c.v[0];
            c.x[1] = c.x[0];
            // §15.3.4 "data event = reference event signal with opposite
            // edge"; §15.3.5 "... with the same edge".
            if (kind == .width) c.ev[1].mask = opposite(c.ev[0].mask);
            c.lim[0] = try nonNegative(l, f, arg(args, 1), name, "limit");
            if (kind == .width) {
                // Syntax 15-12: "the default value for the threshold zero".
                if (arg(args, 2) != .none) c.lim[1] = try nonNegative(l, f, arg(args, 2), name, "threshold");
                c.notifier = try notifier(l, arg(args, 3));
            } else c.notifier = try notifier(l, arg(args, 2));
        },
        // A.7.5.1: `$setup` writes its data event first.
        .setup => {
            try event(l, &c, 0, arg(args, 1));
            try event(l, &c, 1, args[0]);
            c.lim[0] = try nonNegative(l, f, arg(args, 2), name, "limit");
            c.notifier = try notifier(l, arg(args, 3));
        },
        .removal => {
            try event(l, &c, 0, args[0]);
            try event(l, &c, 1, arg(args, 1));
            c.lim[0] = try nonNegative(l, f, arg(args, 2), name, "limit");
            c.notifier = try notifier(l, arg(args, 3));
        },
        .hold, .recovery => {
            try event(l, &c, 0, args[0]);
            try event(l, &c, 1, arg(args, 1));
            c.lim[1] = try nonNegative(l, f, arg(args, 2), name, "limit");
            c.notifier = try notifier(l, arg(args, 3));
        },
        .setuphold, .recrem => {
            try event(l, &c, 0, args[0]);
            try event(l, &c, 1, arg(args, 1));
            c.stamp_cond = try cond(l, arg(args, 5));
            c.check_cond = try cond(l, arg(args, 6));
            // §15.5.4 the negative timing option off: a negative limit is 0.
            const a: u64 = @intCast(@max(try limitTicks(l, f, arg(args, 2), name), 0));
            const b: u64 = @intCast(@max(try limitTicks(l, f, arg(args, 3), name), 0));
            c.lim = if (kind == .setuphold) .{ a, b } else .{ b, a };
            c.notifier = try notifier(l, arg(args, 4));
            try delayed(l, f, args[0], arg(args, 7));
            try delayed(l, f, arg(args, 1), arg(args, 8));
        },
        // $skew is $timeskew with both flags set (§15.3.2).
        .skew, .timeskew, .fullskew => {
            try event(l, &c, 0, args[0]);
            try event(l, &c, 1, arg(args, 1));
            c.lim[0] = try nonNegative(l, f, arg(args, 2), name, "limit");
            var k: usize = 3;
            if (kind == .fullskew) {
                c.lim[1] = try nonNegative(l, f, arg(args, 3), name, "limit");
                k = 4;
            }
            c.notifier = try notifier(l, arg(args, k));
            c.event_based = kind == .skew or try flag(l, f, arg(args, k + 1));
            c.remain_active = kind == .skew or try flag(l, f, arg(args, k + 2));
        },
        // §15.3.6 the reference edge's level is the window.
        .nochange => {
            try event(l, &c, 0, args[0]);
            try event(l, &c, 1, arg(args, 1));
            if (c.ev[0].mask == 0) return l.refuse("§15.3.6 a $nochange reference event that is no edge");
            c.lim[0] = @bitCast(try limitTicks(l, f, arg(args, 2), name));
            const end = try limitTicks(l, f, arg(args, 3), name);
            if (end < 0) return l.refuse("§15.3.6 a $nochange with a negative end edge offset");
            c.lim[1] = @intCast(end);
            c.notifier = try notifier(l, arg(args, 4));
        },
    }
    try l.checks.append(l.a, c);
    try l.check_sites.append(l.a, l.srcOffset(f, i));
    assert(l.checks.items.len == l.check_sites.items.len);
}

/// Writes `Program.checks` and, per slot, the codes (`check * 2 + event`)
/// its change reaches; `$width` and `$period` watch their reference only.
pub fn finish(l: *Lower) Error!void {
    const checks = l.checks.items;
    if (checks.len == 0) return;
    l.b.p.checks = checks;
    const n = l.b.p.slots.len;
    const start = try l.a.alloc(u32, n + 1);
    @memset(start, 0);
    for (checks) |c| for (c.ev[0..watched(c.kind)]) |e| {
        start[e.slot + 1] += 1;
    };
    for (1..n + 1) |k| start[k] += start[k - 1];
    const fill = try l.a.dupe(u32, start[0..n]);
    const codes = try l.a.alloc(u32, start[n]);
    for (checks, 0..) |c, k| for (c.ev[0..watched(c.kind)], 0..) |e, j| {
        codes[fill[e.slot]] = @intCast(k * 2 + j);
        fill[e.slot] += 1;
    };
    assert(std.mem.eql(u32, fill, start[1..]));
    l.b.p.check_start = start;
    l.b.p.check_codes = codes;
}

// ---- private ----

fn watched(kind: Program.Check.Kind) usize {
    return if (kind == .width or kind == .period) 1 else 2;
}

/// §15.3.4 each transition of `mask` turned around (01 <-> 10, 0x <-> x0,
/// 1x <-> x1).
fn opposite(mask: u8) u8 {
    const swap = [6]u3{ 2, 4, 0, 5, 1, 3 };
    var out: u8 = 0;
    for (swap, 0..) |to, from| if (mask & (@as(u8, 1) << @intCast(from)) != 0) {
        out |= @as(u8, 1) << to;
    };
    return out;
}

/// §15.4 the mask bit of transition `from` -> `to` (a z read as x).
fn transition(from: u8, to: u8) u8 {
    const f: u8 = if (from == 'z') 'x' else from;
    const t: u8 = if (to == 'z') 'x' else to;
    if (f == t) return 0;
    return switch (f) {
        '0' => if (t == '1') 1 << 0 else 1 << 1,
        '1' => if (t == '0') 1 << 2 else 1 << 3,
        else => if (t == '0') 1 << 4 else 1 << 5, // else: x, the only other level after the z fold
    };
}

/// Event `k` of check `c` from argument `r`: A.7.3's terminal (a name or a
/// constant select of one), its event control and its `&&&` condition.
fn event(l: *Lower, c: *Program.Check, k: usize, r: Inst.Ref) Error!void {
    const vir = l.virOf(l.frame);
    var term = r;
    var e: Program.CheckEvent = .{};
    if (r.toIndex()) |i| if (Lower.tag(vir, i) == .timing_event) {
        const te = Lower.payload(vir, Inst.TimingEvent, i);
        term = te.term;
        e.cond = try cond(l, te.cond);
        e.mask = switch (te.flags.edge) {
            .none => 0,
            .posedge => posedge_mask,
            .negedge => negedge_mask,
            .edge => try edgeMask(l, vir.string(te.edges)),
        };
    };
    const ti = term.toIndex() orelse return l.refuse("a timing check with an omitted event");
    switch (Lower.tag(vir, ti)) {
        .decl_ref, .str_ref => {
            const n = try expr.leafName(l, ti);
            try eventName(l, n);
            e.slot = n.slot;
        },
        .elem, .slice, .slice_up, .slice_down => {
            const s = try place.selectOf(l, ti);
            try eventName(l, s.name);
            const first = try selectFirst(l, s);
            if (first < 0 or first + s.count > s.name.ty.width or s.count > 64) return l.refuse("a timing check event select outside its signal or past 64 bits");
            e.slot = s.name.slot;
            e.lo = @intCast(first);
            e.width = s.count;
            // The select's bits at time 0.
            const word = l.b.p.slots.items(.word)[e.slot];
            c.v[k] = bitsOf(l.b.init_v.items[word..], e.lo, e.width);
            c.x[k] = bitsOf(l.b.init_x.items[word..], e.lo, e.width);
        },
        else => return l.refuse("a timing check event that is no name or constant select (A.7.3)"),
    }
    c.ev[k] = e;
}

fn eventName(l: *Lower, n: digital.Name) Error!void {
    if (n.kind != .net and n.kind != .variable) return l.refuse("a timing check event naming no net or variable (A.7.3)");
    if (n.ty.real or n.dims.len != 0) return l.refuse("a timing check event naming a real or an array (A.7.3)");
}

/// Bits [lo, lo + width) of a plane, at most 64 of them.
fn bitsOf(plane: []const u64, lo: u32, width: u32) u64 {
    assert(width <= 64);
    var out: u64 = 0;
    for (0..width) |k| {
        const at = lo + k;
        out |= ((plane[at / 64] >> @intCast(at % 64)) & 1) << @intCast(k);
    }
    return out;
}

/// A.7.5.3 an `edge [...]` control's descriptors (`01,0x,...`).
fn edgeMask(l: *Lower, text: []const u8) Error!u8 {
    var mask: u8 = 0;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |d| {
        if (d.len != 2) return l.refuse("an edge descriptor of other than two characters");
        const a = std.ascii.toLower(d[0]);
        const b = std.ascii.toLower(d[1]);
        if (std.mem.findScalar(u8, "01xz", a) == null or std.mem.findScalar(u8, "01xz", b) == null) return l.refuse("an edge descriptor of no 0, 1, x or z");
        mask |= transition(a, b);
    }
    return mask;
}

/// §15.6 condition `r` as `tchk.enabled` reads it: none, a bare
/// expression, `~` of one, or a comparison of a signal with a literal.
fn cond(l: *Lower, r: Inst.Ref) Error!Program.Cond {
    const i = r.toIndex() orelse return .{};
    const vir = l.virOf(l.frame);
    var out: Program.Cond = .{ .op = .plain };
    var signal = r;
    switch (Lower.tag(vir, i)) {
        .bit_not => {
            out.op = .invert;
            signal = vir.instructions.items(.data)[@backingInt(i)].un_node.operand;
        },
        .eq, .neq, .case_eq, .case_neq => |tg| {
            const b = Lower.payload(vir, Inst.Bin, i);
            if (try literalBit(l, b.rhs)) |want| {
                out.op = switch (tg) {
                    .eq => .eq,
                    .neq => .neq,
                    .case_eq => .case_eq,
                    else => .case_neq, // else: the fourth comparison
                };
                out.want = want;
                signal = b.lhs;
            }
        },
        else => {}, // else: any other expression is a bare one
    }
    out.signal = try expr.self_(l, signal, 0);
    return out;
}

/// The least significant bit of literal `r`, or null when `r` is no literal.
fn literalBit(l: *Lower, r: Inst.Ref) Error!?Bit {
    const vir = l.virOf(l.frame);
    const i = r.toIndex() orelse return null;
    const data = vir.instructions.items(.data)[@backingInt(i)];
    switch (Lower.tag(vir, i)) {
        .int => return if (data.int & 1 == 1) .one else .zero,
        .big_int => {
            const b = Lower.payload(vir, Inst.BigInt, i);
            const digits = vir.string(b.digits);
            if (digits.len == 0) return null;
            const last = std.ascii.toLower(digits[digits.len - 1]);
            if (last == 'x') return .x;
            if (last == 'z' or last == '?') return .z;
            const v = std.fmt.charToDigit(last, 16) catch return l.refuse("a malformed literal in a timing check condition");
            return if (v & 1 == 1) .one else .zero;
        },
        else => return null,
    }
}

/// A limit in ticks, with its sign: "constant expression" (§15.1).
fn limitTicks(l: *Lower, f: u32, r: Inst.Ref, name: []const u8) Error!i64 {
    if (r == .none) return l.refuse("a timing check with an omitted limit");
    const c = (try l.constOf(f, r)) orelse {
        l.why_code = .E1148;
        return l.rejectFmt(f, r, "a limit of `{s}` is a constant expression (IEEE 1364-2005 §15.1); this one reads a signal", .{name});
    };
    const scale = l.b.times.items[l.frames.items[f].scope].scale;
    const negative, const mag = switch (c) {
        .int => |v| .{ v < 0, scale.unsignedDelay(@abs(v)) catch return l.refuse("a timing check limit past 2^64 ticks") },
        .real => |v| .{ v < 0, scale.realDelay(@abs(v)) catch return l.refuse("a timing check limit past 2^64 ticks") },
        .str => return l.refuse("a string timing check limit"),
    };
    const ticks = std.math.cast(i64, mag) orelse return l.refuse("a timing check limit past 2^63 ticks");
    return if (negative) -ticks else ticks;
}

/// A "non-negative constant expression" limit (Tables 15-1 to 15-12),
/// the `what` (limit or threshold) of timing check `name`; a negative one
/// is lib/sim/digital's E1148.
fn nonNegative(l: *Lower, f: u32, r: Inst.Ref, name: []const u8, what: []const u8) Error!u64 {
    assert(name.len > 0 and what.len > 0);
    const v = try limitTicks(l, f, r, name);
    if (v < 0) {
        l.why_code = .E1148;
        return l.rejectFmt(f, r, "the {s} of `{s}` is a non-negative constant expression (IEEE 1364-2005 §15), and this one is negative", .{ what, name });
    }
    assert(v >= 0);
    return @intCast(v);
}

/// §15.5.2 the notifier register, or `none`.
fn notifier(l: *Lower, r: Inst.Ref) Error!u32 {
    if (r == .none) return none;
    const n = (try expr.nameOf(l, r)) orelse return l.refuse("a notifier that is no name");
    if (n.kind != .variable or n.ty.real or n.dims.len != 0) {
        l.why_code = .E1147;
        return l.reject(l.frame, r, "this notifier is not a reg (IEEE 1364-2005 §15.5: \"The notifier is a reg\")");
    }
    return n.slot;
}

/// §15.3.2 an `event_based_flag` or `remain_active_flag`: false when absent.
fn flag(l: *Lower, f: u32, r: Inst.Ref) Error!bool {
    if (r == .none) return false;
    const c = (try l.constOf(f, r)) orelse return l.refuse("a timing check flag Sema/eval.zig does not fold");
    return switch (c) {
        .int => |v| v != 0,
        .real => |v| v != 0,
        .str => l.refuse("a string timing check flag"),
    };
}

/// §15.5.1 a delayed signal `dst` of signal `src` (`none`: none given): a
/// zero-delay copy, the negative timing option off (§15.5.4).
fn delayed(l: *Lower, f: u32, src: Inst.Ref, dst: Inst.Ref) Error!void {
    if (dst == .none) return;
    const from = try terminal(l, src);
    const to = try terminal(l, dst);
    const n = l.slot_net.get(to.slot) orelse return l.refuse("§15.5.1 a delayed signal that is no net");
    if (from.width != to.width) return l.refuse("§15.5.1 a delayed signal not as wide as the signal it delays");
    try l.wires.append(l.a, .{ .net = n, .frame = f, .source = .{ .bridge = .{ .src = from.slot, .src_lo = from.lo, .dst_lo = to.lo, .width = from.width } } });
}

/// A.7.3 a timing check terminal (with its event control stripped): a name
/// or a constant select of one, as a slot and bits.
fn terminal(l: *Lower, r: Inst.Ref) Error!struct { slot: u32, lo: u32, width: u32 } {
    const vir = l.virOf(l.frame);
    var term = r;
    if (r.toIndex()) |i| if (Lower.tag(vir, i) == .timing_event) {
        term = Lower.payload(vir, Inst.TimingEvent, i).term;
    };
    const ti = term.toIndex() orelse return l.refuse("an omitted timing check terminal");
    switch (Lower.tag(vir, ti)) {
        .decl_ref, .str_ref => {
            const n = try expr.leafName(l, ti);
            return .{ .slot = n.slot, .lo = 0, .width = n.ty.width };
        },
        .elem, .slice, .slice_up, .slice_down => {
            const s = try place.selectOf(l, ti);
            const first = try selectFirst(l, s);
            return .{ .slot = s.name.slot, .lo = std.math.cast(u32, first) orelse return l.refuse("a timing check terminal select outside its signal"), .width = s.count };
        },
        else => return l.refuse("a timing check terminal that is no name or select (A.7.3)"),
    }
}

/// The first bit position a constant select picks, from its declared range.
fn selectFirst(l: *Lower, s: place.Sel) Error!i64 {
    return switch (s.mode) {
        .const_part => s.first,
        .bit, .up, .down => blk: {
            const idx = try l.intOf(l.frame, s.index);
            break :blk if (s.name.msb >= s.name.lsb) idx -| s.name.lsb else s.name.lsb -| idx;
        },
    };
}
