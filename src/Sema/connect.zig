//! §7.8 connect-module insertion over the finished instance table:
//! `Zcu.instances`, `Zcu.ports` and the resolved disciplines (`resolve.zig`)
//! in; one connect-module instance per bridge and its `Zcu.inserts` rows out,
//! the table put back in depth-first preorder. Running after the walk is
//! §7.8.4's "complete hierarchical examination of each signal": every
//! segment below a port is known before the port is judged, with no dry
//! walk. A port (or §7.8.5.1 a primitive's terminal) is mixed when its
//! upper and lower connections resolve to different domains; it matches
//! exactly one connect statement (§7.8.4; E0922 for several, E0927 for
//! none), whose module is instantiated in the upper connection's module,
//! one per signal, statement and bottom discipline when merged (§7.8.3, the
//! default, and always for an analog lower connection), else one per port,
//! named by §7.8.5.
//! Cites: VAMS-2023 §3.6.2.2, §3.11.1, §7.4.4.1, §7.6 (Table 7-2), §7.7.1,
//! §7.7.2, §7.7.3, §7.8.2-§7.8.5, Annex F.2.
//!
//! Contents:
//! - `pub fn run(s: *Sema, waiting: defparam.Waiting) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Sema = @import("../Sema.zig");
const Zcu = @import("../Zcu.zig");
const eval = @import("eval.zig");
const walk = @import("walk.zig");
const discipline = @import("discipline.zig");
const defparam = @import("defparam.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Instance = Zcu.Instance;
const String = InternPool.String;
const payloadOf = walk.payloadOf;
const resolve = @import("resolve.zig");
const Net = resolve.Net;

/// One side of a connect statement read as Table 7-2's pair.
const Side = struct { port: String, discipline: []const u8, dir: Inst.Direction };

/// One usable connect statement.
const Rule = struct { module: Zcu.Decl, file: Zcu.File.Index, src: Inst.Index, cont: Side, disc: Side, split: bool, params: Vir.List(Inst.Arg) };

/// A mixed port one statement matched.
/// `child` is none for a primitive's terminal (`port` its instruction,
/// `terminal` its position); `name` names the instance for §7.8.5.
const Hit = struct { parent: Instance.Index, child: Instance.Index, port: Inst.Index, terminal: u32 = 0, name: String, port_name: String, sig: String, bottom: []const u8, rule: u32 };

/// A port's or terminal's place, for E0922/E0927 and its `Hit`.
const Site = struct { parent: Instance.Index, child: Instance.Index, port: Inst.Index, terminal: u32, name: String, port_name: String, file: Zcu.File.Index, src: Inst.Ref };

/// Resolves, inserts, and restores preorder; a defparam `waiting` for an
/// inserted connect module sets its parameter (§7.8.5 names are
/// hierarchical names). A design with no connect statement still resolves
/// its disciplines and judges its mixed ports (E0927).
pub fn run(s: *Sema, waiting: defparam.Waiting) Allocator.Error!void {
    assert(s.zcu.inserts.len == 0);
    for (waiting.rows) |r| assert(r.origin < waiting.origins.len);
    const zcu = s.zcu;
    const rules = try collectRules(s);
    const count = zcu.instances.len;
    // Each instance's children, in table order.
    const kids = try s.arena.alloc(std.ArrayList(Instance.Index), count);
    for (kids) |*k| k.* = .empty;
    for (zcu.instances.items(.parent), 0..) |p, k| if (p != .none) try kids[@backingInt(p)].append(s.arena, @fromBackingInt(@intCast(k)));
    try resolve.run(s, kids);
    var hits: std.ArrayList(Hit) = .empty;
    for (0..count) |p| {
        for (kids[p].items) |c| try mixedPorts(s, rules, @fromBackingInt(@intCast(p)), c, &hits);
        try gateTerminals(s, rules, @fromBackingInt(@intCast(p)), &hits);
    }
    if (hits.items.len == 0) return;
    try insert(s, rules, hits.items, waiting);
    try preorder(s);
}

// ---- private ----

/// §7.7.1 every statement whose connect module has one continuous and one
/// discrete port, read with its overrides. An override discipline
/// incompatible with the side it replaces is E0915 (§3.11.1).
fn collectRules(s: *Sema) Allocator.Error![]const Rule {
    const zcu = s.zcu;
    var rules: std.ArrayList(Rule) = .empty;
    for (0..zcu.files.len) |f| {
        const file: Zcu.File.Index = @fromBackingInt(@intCast(f));
        const vir = zcu.fileVir(file);
        for (vir.decls()) |d| if (d.kind == .connectrules) for (vir.body(payloadOf(vir, Inst.ConnectRules, d.inst).body)) |i| {
            if (vir.instructions.items(.tag)[@backingInt(i)] != .connect_insert) continue;
            const ins = payloadOf(vir, Inst.ConnectInsert, i);
            const m = zcu.modules.get(try zcu.intern_pool.getString(s.gpa, vir.string(ins.module))) orelse continue;
            if (zcu.declRow(m).kind != .connectmodule) continue;
            const mvir = zcu.fileVir(m.file);
            const header = mvir.body(payloadOf(mvir, Inst.Module, zcu.declRow(m).inst).ports);
            if (header.len != 2) continue;
            var sides: [2]Side = undefined;
            var domains: [2]?discipline.Domain = undefined;
            const decls = try resolve.netsOf(s, m);
            for (header, &sides, &domains) |h, *side, *dom| {
                const name = try zcu.intern_pool.getString(s.gpa, resolve.portName(mvir, h));
                const n = decls.get(name) orelse Net{ .discipline = "", .dir = .none };
                side.* = .{ .port = name, .discipline = n.discipline, .dir = n.dir };
                dom.* = try discipline.domainOf(s, n.discipline);
            }
            const c: usize = if (domains[0] == .continuous and domains[1] == .discrete) 0 else if (domains[1] == .continuous and domains[0] == .discrete) 1 else continue;
            var r: Rule = .{ .module = m, .file = file, .src = i, .cont = sides[c], .disc = sides[1 - c], .split = ins.flags.split, .params = ins.params };
            const ok = for ([_]struct { Inst.Direction, Vir.String }{ .{ ins.flags.a_dir, ins.a }, .{ ins.flags.b_dir, ins.b } }) |ov| {
                if (ov[1] == .empty) continue;
                const name = vir.string(ov[1]);
                const side = if (try discipline.domainOf(s, name) == .continuous) &r.cont else &r.disc;
                if (!try discipline.compatible(s, side.discipline, name)) {
                    try s.fail(.E0915, file, i.toRef(), "`{s}` cannot stand for `{s}`'s `{s}` (§3.11.1)", .{ name, mvir.string(zcu.declRow(m).name), zcu.intern_pool.stringToSlice(side.port) });
                    break false;
                }
                side.discipline = name;
                if (ov[0] != .none) side.dir = ov[0];
            } else true;
            if (ok) try rules.append(s.arena, r);
        };
    }
    return rules.items;
}

/// §7.8.4 judges each port of child `c` of `p`: mixed when its upper and
/// lower connections resolve to different domains, then matched against
/// the statements (E0922 for more than one, E0927 for none).
fn mixedPorts(s: *Sema, rules: []const Rule, p: Instance.Index, c: Instance.Index, hits: *std.ArrayList(Hit)) Allocator.Error!void {
    assert(s.zcu.instances.items(.parent)[@backingInt(c)] == p);
    const before = hits.items.len;
    defer assert(hits.items.len >= before);
    const zcu = s.zcu;
    const pmod = zcu.instances.items(.module)[@backingInt(p)];
    const cmod = zcu.instances.items(.module)[@backingInt(c)];
    if (zcu.declRow(cmod).kind == .connectmodule) return;
    const vir = zcu.fileVir(pmod.file);
    const cvir = zcu.fileVir(cmod.file);
    const cdecls = try resolve.netsOf(s, cmod);
    const pdecls = try resolve.netsOf(s, pmod);
    const run_ = zcu.instances.items(.ports)[@backingInt(c)];
    for (zcu.ports.items(.formal)[run_.start..][0..run_.len], zcu.ports.items(.actual)[run_.start..][0..run_.len]) |formal, actual| {
        const inner = try zcu.intern_pool.getString(s.gpa, resolve.internalName(cvir, formal));
        const sig = try resolve.netName(s, vir, actual) orelse {
            try analogActual(s, pmod.file, vir, c, inner, actual, formal, cvir);
            continue;
        };
        const upper = zcu.net_discipline.get(.{ .instance = p, .net = sig }) orelse continue;
        const lower = zcu.net_discipline.get(.{ .instance = c, .net = inner }) orelse continue;
        const up = zcu.intern_pool.stringToSlice(upper);
        const low = zcu.intern_pool.stringToSlice(lower);
        const du = try discipline.domainOf(s, up) orelse continue;
        const dl = try discipline.domainOf(s, low) orelse continue;
        if (du == dl) {
            // §3.11.1 one domain, so no bridge: a net and a port both
            // declared must agree. An undeclared net took a child's
            // discipline (F.2), and a shipped primitive's ports take the
            // net's (E.3.2.2).
            const declared = if (pdecls.get(sig)) |n| n.discipline.len != 0 else false;
            if (declared and !zcu.isBuiltin(cmod) and !try discipline.compatible(s, up, low))
                try s.fail(.E0355, pmod.file, zcu.instances.items(.src)[@backingInt(c)], "port `{s}` is `{s}` and its net `{s}` is `{s}`: incompatible disciplines (§3.11.1)", .{ resolve.portName(cvir, formal), low, zcu.intern_pool.stringToSlice(sig), up });
            continue;
        }
        const dir = if (cdecls.get(inner)) |n| n.dir else Inst.Direction.none;
        try judge(s, rules, .{
            .parent = p,
            .child = c,
            .port = formal,
            .terminal = 0,
            .name = zcu.instances.items(.name)[@backingInt(c)],
            .port_name = try zcu.intern_pool.getString(s.gpa, resolve.portName(cvir, formal)),
            .file = pmod.file,
            .src = zcu.instances.items(.src)[@backingInt(c)],
        }, dir, sig, up, low, hits);
    }
}

/// §7.8.4 one mixed port or terminal: the statement that bridges it, a
/// `Hit`; E0922 when several do, E0927 when none does.
fn judge(s: *Sema, rules: []const Rule, at: Site, dir: Inst.Direction, sig: String, up: []const u8, low: []const u8, hits: *std.ArrayList(Hit)) Allocator.Error!void {
    assert(at.port_name != .empty);
    assert(try discipline.domainOf(s, up) != try discipline.domainOf(s, low));
    const ip = &s.zcu.intern_pool;
    var found: ?u32 = null;
    var n: u32 = 0;
    for (rules, 0..) |r, ri| if (try matches(s, r, dir, up, low)) {
        n += 1;
        if (found == null) found = @intCast(ri);
    };
    if (n > 1) return s.fail(.E0922, at.file, at.src, "port `{s}` of `{s}` matches more than one connect statement ({d})", .{ ip.stringToSlice(at.port_name), ip.stringToSlice(at.name), n });
    const rule = found orelse
        return s.fail(.E0927, at.file, at.src, "port `{s}` of `{s}` is `{s}` and its net `{s}` is `{s}`, and no connect statement bridges them", .{ ip.stringToSlice(at.port_name), ip.stringToSlice(at.name), low, ip.stringToSlice(sig), up });
    try hits.append(s.arena, .{ .parent = at.parent, .child = at.child, .port = at.port, .terminal = at.terminal, .name = at.name, .port_name = at.port_name, .sig = sig, .bottom = low, .rule = rule });
}

/// §3.9/§7.8.5.1 each terminal of instance `i`'s gate, switch and pull
/// primitives is a port: its lower connection is the `default_discipline`
/// in force at the primitive (for a `wire`), discrete, and its upper one
/// the net it names, so a terminal on a continuous net is mixed and judged
/// as a port, named `<type>$<n>` when the primitive is unnamed and
/// `g[k]` per element of an array. A mixed terminal no bridge can take
/// whole is E0929: a part-select, a vector net, a switch array.
/// ponytail: primitives directly in the module's body; one in a generate
/// block takes no bridge.
fn gateTerminals(s: *Sema, rules: []const Rule, i: Instance.Index, hits: *std.ArrayList(Hit)) Allocator.Error!void {
    assert(@backingInt(i) < s.zcu.instances.len);
    const before = hits.items.len;
    defer assert(hits.items.len >= before);
    const zcu = s.zcu;
    const ip = &zcu.intern_pool;
    const module = zcu.instances.items(.module)[@backingInt(i)];
    if (zcu.declRow(module).kind == .primitive) return;
    const vir = zcu.fileVir(module.file);
    const m = payloadOf(vir, Inst.Module, zcu.declRow(module).inst);
    const decls = try resolve.netsOf(s, module);
    var unnamed: std.StringHashMapUnmanaged(u32) = .empty;
    for (vir.body(m.body)) |g| {
        if (vir.instructions.items(.tag)[@backingInt(g)] != .instance) continue;
        const in = payloadOf(vir, Inst.Instance, g);
        if (in.flags.kind != .gate) continue;
        const ty = vir.string(in.target);
        const base = if (in.name != .empty) vir.string(in.name) else named: {
            const n = try unnamed.getOrPutValue(s.arena, ty, 0);
            n.value_ptr.* += 1;
            break :named try std.fmt.allocPrint(s.arena, "{s}${d}", .{ ty, n.value_ptr.* });
        };
        const bottom = inForce(vir, vir.list(Inst.Default, in.defaults)) orelse continue;
        if (try discipline.domainOf(s, bottom) != .discrete) continue;
        const terms = vir.list(Inst.Arg, in.conns);
        const lanes = try laneRange(s, vir, in) orelse continue;
        for (terms, 0..) |t, k| {
            const role = terminal(ty, k, terms.len) orelse continue;
            const value = vir.body(t.value);
            if (value.len == 0) continue;
            const last = value[value.len - 1];
            const whole = try resolve.netName(s, vir, last.toRef());
            const sig = whole orelse try ip.getString(s.gpa, selectBase(vir, last) orelse continue);
            const upper = zcu.net_discipline.get(.{ .instance = i, .net = sig }) orelse continue;
            const up = ip.stringToSlice(upper);
            if (try discipline.domainOf(s, up) != .continuous) continue;
            const why: ?[]const u8 = if (whole == null)
                "the terminal selects part of the net"
            else if (if (decls.get(sig)) |n| n.vector else false)
                "the net is a vector"
            else if (role.switch_ and in.range.len != 0)
                "the switch is an instance array"
            else
                null;
            if (why) |w| {
                try s.fail(.E0929, module.file, g.toRef(), "terminal `{s}` of `{s}` is on `{s}` (`{s}`) and gets no connect module: {s}", .{ role.port, base, ip.stringToSlice(sig), up, w });
                continue;
            }
            var lane = lanes.lo;
            while (lane <= lanes.hi) : (lane += 1) {
                const name = if (in.range.len == 0) base else try std.fmt.allocPrint(s.arena, "{s}[{d}]", .{ base, lane });
                try judge(s, rules, .{
                    .parent = i,
                    .child = .none,
                    .port = g,
                    .terminal = @intCast(k),
                    .name = try ip.getString(s.gpa, name),
                    .port_name = try ip.getString(s.gpa, role.port),
                    .file = module.file,
                    .src = g.toRef(),
                }, role.dir, sig, up, bottom, hits);
            }
        }
    }
}

/// §7.8.5.1's name and direction of terminal `k` of `n` of a primitive of
/// type `ty`: an n-input gate's `out`, `in1`...; `buf`/`not`'s `out1`...
/// and `in`; an enable gate's `out`, `in`, `enable`; a pull's `out`; a MOS
/// switch's `source`, `drain`, `gate` (`ngate`, `pgate` for CMOS); a pass
/// switch's `source`, `drain` (inout) and `gate`. Null for a UDP or an
/// unknown keyword.
fn terminal(ty: []const u8, k: usize, n: usize) ?struct { port: []const u8, dir: Inst.Direction, switch_: bool = false } {
    assert(k < n);
    const words = std.StaticStringMap(enum { nin, nout, enable, pull, mos, cmos, pass }).initComptime(.{
        .{ "and", .nin },       .{ "nand", .nin },      .{ "or", .nin },        .{ "nor", .nin },       .{ "xor", .nin },       .{ "xnor", .nin },
        .{ "buf", .nout },      .{ "not", .nout },      .{ "bufif0", .enable }, .{ "bufif1", .enable }, .{ "notif0", .enable }, .{ "notif1", .enable },
        .{ "pullup", .pull },   .{ "pulldown", .pull }, .{ "nmos", .mos },      .{ "pmos", .mos },      .{ "rnmos", .mos },     .{ "rpmos", .mos },
        .{ "cmos", .cmos },     .{ "rcmos", .cmos },    .{ "tran", .pass },     .{ "rtran", .pass },    .{ "tranif0", .pass },  .{ "tranif1", .pass },
        .{ "rtranif0", .pass }, .{ "rtranif1", .pass },
    });
    const outs = [_][]const u8{ "out1", "out2", "out3", "out4", "out5", "out6", "out7", "out8" };
    const ins = [_][]const u8{ "in1", "in2", "in3", "in4", "in5", "in6", "in7", "in8" };
    return switch (words.get(ty) orelse return null) {
        .nin => if (k == 0) .{ .port = "out", .dir = .output } else if (k - 1 < ins.len) .{ .port = ins[k - 1], .dir = .input } else null,
        .nout => if (k + 1 == n) .{ .port = "in", .dir = .input } else if (k < outs.len) .{ .port = outs[k], .dir = .output } else null,
        .enable => if (k < 3) .{ .port = ([_][]const u8{ "out", "in", "enable" })[k], .dir = if (k == 0) .output else .input } else null,
        .pull => if (k == 0) .{ .port = "out", .dir = .output } else null,
        .mos => if (k < 3) .{ .port = ([_][]const u8{ "source", "drain", "gate" })[k], .dir = if (k == 0) .output else .input, .switch_ = true } else null,
        .cmos => if (k < 4) .{ .port = ([_][]const u8{ "source", "drain", "ngate", "pgate" })[k], .dir = if (k == 0) .output else .input, .switch_ = true } else null,
        .pass => if (k < 3) .{ .port = ([_][]const u8{ "source", "drain", "gate" })[k], .dir = if (k < 2) .inout else .input, .switch_ = true } else null,
    };
}

/// IEEE 1364-2005 §7.1.5 an instance array's elements, lowest first; one
/// lane for a scalar instance. Null after E0909 when the range does not
/// fold.
fn laneRange(s: *Sema, vir: *const Vir, in: Inst.Instance) Allocator.Error!?struct { lo: i64, hi: i64 } {
    if (in.range.len == 0) return .{ .lo = 0, .hi = 0 };
    var env: eval.Env = try .init(s.gpa, s.arena, &s.zcu.intern_pool, vir, &.{});
    defer env.deinit();
    const r = vir.body(in.range);
    const bin = payloadOf(vir, Inst.Bin, r[r.len - 1]);
    const msb = ((try env.ref(bin.lhs)) orelse return null).asIntExact() orelse return null;
    const lsb = ((try env.ref(bin.rhs)) orelse return null).asIntExact() orelse return null;
    assert(@min(msb, lsb) <= @max(msb, lsb));
    return .{ .lo = @min(msb, lsb), .hi = @max(msb, lsb) };
}

/// The net a bit- or part-select names (`bus[1]`, `bus[3:2]`), or null.
fn selectBase(vir: *const Vir, i: Inst.Index) ?[]const u8 {
    const tag = vir.instructions.items(.tag)[@backingInt(i)];
    const operand: Inst.Ref = switch (tag) {
        .elem => payloadOf(vir, Inst.Bin, i).lhs,
        .slice, .slice_up, .slice_down => payloadOf(vir, Inst.Triple, i).a,
        else => return null, // else: only a select names part of a net
    };
    const o = operand.toIndex() orelse return null;
    if (vir.instructions.items(.tag)[@backingInt(o)] != .decl_ref) return null;
    const d = vir.instructions.items(.data)[@backingInt(o)].decl_tok.decl;
    return switch (vir.instructions.items(.tag)[@backingInt(d)]) {
        .net => vir.string(payloadOf(vir, Inst.Net, d).name),
        .io => vir.string(payloadOf(vir, Inst.Io, d).name),
        else => null, // else: a select of a variable names no net
    };
}

/// §10.2 the discipline in force for a `wire` among `defaults`: one
/// qualified `wire`, else the unqualified one (AstGen lists those last).
fn inForce(vir: *const Vir, defaults: []const Inst.Default) ?[]const u8 {
    var fallback: ?[]const u8 = null;
    for (defaults) |d| {
        if (d.flags.qualified and d.flags.qualifier == .wire) return vir.string(d.discipline);
        if (!d.flags.qualified) fallback = vir.string(d.discipline);
    }
    return fallback;
}

/// §6.5 a continuous port joins a net: a variable (§6.5.1 lists no
/// variable port expression) or another expression (§6.2.2 allows one for a
/// digital input only) as its actual is E0906. A select or concatenation
/// names net parts and is judged where it is bound.
fn analogActual(s: *Sema, file: Zcu.File.Index, vir: *const Vir, c: Instance.Index, inner: String, actual: Inst.Ref, formal: Inst.Index, cvir: *const Vir) Allocator.Error!void {
    assert(@backingInt(c) < s.zcu.instances.len);
    const zcu = s.zcu;
    const i = actual.toIndex() orelse return;
    const low = zcu.net_discipline.get(.{ .instance = c, .net = inner }) orelse return;
    if (try discipline.domainOf(s, zcu.intern_pool.stringToSlice(low)) != .continuous) return;
    switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .elem, .slice, .slice_up, .slice_down, .concat, .decl_ref => {},
        else => return s.fail(.E0906, file, zcu.instances.items(.src)[@backingInt(c)], "port `{s}` is continuous and its connection is an expression, not a net", .{resolve.portName(cvir, formal)}), // else: every other instruction is an expression
    }
    if (vir.instructions.items(.tag)[@backingInt(i)] != .decl_ref) return;
    const d = vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl;
    if (vir.instructions.items(.tag)[@backingInt(d)] == .variable)
        try s.fail(.E0906, file, zcu.instances.items(.src)[@backingInt(c)], "port `{s}` is continuous and its connection is a variable: it joins only a net", .{resolve.portName(cvir, formal)});
}

/// Table 7-2 and §7.7.1: statement `r` bridges a port of direction `dir`
/// whose upper connection is `upper` and lower `lower` when its sides'
/// disciplines are compatible with the two and its directions carry the
/// signal the port's way (an inout pair any way).
fn matches(s: *Sema, r: Rule, dir: Inst.Direction, upper: []const u8, lower: []const u8) Allocator.Error!bool {
    assert(r.cont.port != r.disc.port);
    if (r.cont.dir == .inout and r.disc.dir == .inout) {
        const up_cont = try discipline.domainOf(s, upper) == .continuous;
        const c = if (up_cont) upper else lower;
        const d = if (up_cont) lower else upper;
        return try compat(s, r.cont.discipline, c) and try compat(s, r.disc.discipline, d);
    }
    const in_side, const out_side = if (r.cont.dir == .input and r.disc.dir == .output)
        .{ r.cont, r.disc }
    else if (r.cont.dir == .output and r.disc.dir == .input)
        .{ r.disc, r.cont }
    else
        return false;
    const source, const sink = switch (dir) {
        .input => .{ upper, lower },
        .output => .{ lower, upper },
        .inout, .none => return false,
    };
    return try compat(s, in_side.discipline, source) and try compat(s, out_side.discipline, sink);
}

fn compat(s: *Sema, a: []const u8, b: []const u8) Allocator.Error!bool {
    return try discipline.domainOf(s, a) == try discipline.domainOf(s, b) and try discipline.compatible(s, a, b);
}

/// Appends one bridge instance per merged group or split port, as a child
/// of the upper connection's instance, and one `Zcu.inserts` row per port.
fn insert(s: *Sema, rules: []const Rule, hits: []const Hit, waiting: defparam.Waiting) Allocator.Error!void {
    assert(hits.len != 0);
    defer assert(s.zcu.inserts.len == hits.len);
    const zcu = s.zcu;
    const bridges = try s.arena.alloc(Instance.Index, hits.len);
    for (hits, bridges, 0..) |h, *out, k| {
        const r = rules[h.rule];
        const low_analog = try discipline.domainOf(s, h.bottom) == .continuous;
        // §7.8.2: an analog lower connection is never split.
        const merged = !r.split or low_analog;
        const owner: ?usize = if (merged) for (hits[0..k], 0..) |g, j| {
            if (g.parent == h.parent and g.sig == h.sig and g.rule == h.rule and std.mem.eql(u8, g.bottom, h.bottom)) break j;
        } else null else null;
        const bridge: Instance.Index = if (owner) |o| bridges[o] else made: {
            const mvir = zcu.fileVir(r.module.file);
            const name = if (merged)
                try std.fmt.allocPrint(s.arena, "{s}__{s}__{s}", .{ zcu.intern_pool.stringToSlice(h.sig), mvir.string(zcu.declRow(r.module).name), h.bottom })
            else
                try std.fmt.allocPrint(s.arena, "{s}__{s}__{s}", .{ zcu.intern_pool.stringToSlice(h.sig), zcu.intern_pool.stringToSlice(h.name), zcu.intern_pool.stringToSlice(h.port_name) });
            break :made try bridgeInstance(s, r, h.parent, try zcu.intern_pool.getString(s.gpa, name), try defparam.waitingFor(s, waiting, h.parent, name));
        };
        out.* = bridge;
        try zcu.inserts.append(s.gpa, .{ .instance = if (h.child == .none) h.parent else h.child, .port = h.port, .bridge = bridge, .terminal = h.terminal });
    }
}

/// One connect-module instance under `parent`, its parameters folded with
/// the statement's values (§7.7.3).
fn bridgeInstance(s: *Sema, r: Rule, parent: Instance.Index, name: String, dps: []const defparam.Dp) Allocator.Error!Instance.Index {
    assert(@backingInt(parent) < s.zcu.instances.len);
    assert(name != .empty);
    const zcu = s.zcu;
    const mvir = zcu.fileVir(r.module.file);
    const row = zcu.declRow(r.module);
    const m = payloadOf(mvir, Inst.Module, row.inst);
    var env: eval.Env = try .init(s.gpa, s.arena, &zcu.intern_pool, mvir, &.{ m.params, m.body });
    defer env.deinit();
    // The statement's values are constants of the connectrules' file.
    var at: eval.Env = try .init(s.gpa, s.arena, &zcu.intern_pool, zcu.fileVir(r.file), &.{});
    defer at.deinit();
    var givens: std.ArrayList(walk.Given) = .empty;
    const rvir = zcu.fileVir(r.file);
    for (rvir.list(Inst.Arg, r.params)) |a| {
        const v = if (try at.body(a.value)) |c| try at.intern(c) else InternPool.Index.undef;
        try givens.append(s.arena, .{ .name = try zcu.intern_pool.getString(s.gpa, rvir.string(a.name)), .value = v });
    }
    try walk.applyGivens(s, &env, r.file, r.src.toRef(), givens.items, true, row.name);
    try defparam.applyDefparams(s, &env, dps, row.name);
    for (env.positions.keys()) |p| _ = try env.param(p);
    const params = try zcu.intern_pool.get(s.gpa, .{ .aggregate = .{ .ty = .none, .elems = env.values.items } });
    const index: Instance.Index = @fromBackingInt(@intCast(zcu.instances.len));
    try zcu.instances.append(s.gpa, .{
        .module = r.module,
        .parent = parent,
        .name = name,
        .params = params,
        .paramset = .none,
        .src = .none,
        .hier = zcu.instances.items(.hier)[@backingInt(parent)],
        .ports = .{ .start = @intCast(zcu.ports.len), .len = 0 },
    });
    const gop = try zcu.instance_map.getOrPut(s.gpa, .{ .module = r.module, .params = params });
    if (!gop.found_existing) gop.value_ptr.* = index;
    return index;
}

/// Puts the instance table back in depth-first preorder (each parent's
/// children in table order, so a bridge follows its siblings' subtrees),
/// remapping every index that names a row.
fn preorder(s: *Sema) Allocator.Error!void {
    const zcu = s.zcu;
    const n = zcu.instances.len;
    const parents = zcu.instances.items(.parent);
    const kids = try s.arena.alloc(std.ArrayList(u32), n);
    for (kids) |*k| k.* = .empty;
    var stack: std.ArrayList(u32) = .empty;
    var k = n;
    while (k > 0) {
        k -= 1;
        if (parents[k] == .none) try stack.append(s.arena, @intCast(k)) else try kids[@backingInt(parents[k])].insert(s.arena, 0, @intCast(k));
    }
    // `kids` lists are in table order; push them reversed so the first pops first.
    const order = try s.arena.alloc(u32, n);
    const new_of = try s.arena.alloc(u32, n);
    var at: u32 = 0;
    while (stack.pop()) |i| {
        order[at] = i;
        new_of[i] = at;
        at += 1;
        var j = kids[i].items.len;
        while (j > 0) {
            j -= 1;
            try stack.append(s.arena, kids[i].items[j]);
        }
    }
    assert(at == n);
    var next: std.MultiArrayList(Instance) = .empty;
    try next.ensureTotalCapacity(s.gpa, n);
    for (order) |old| {
        var row = zcu.instances.get(old);
        if (row.parent != .none) row.parent = @fromBackingInt(new_of[@backingInt(row.parent)]);
        next.appendAssumeCapacity(row);
    }
    zcu.instances.deinit(s.gpa);
    zcu.instances = next;
    var it = zcu.instance_map.valueIterator();
    while (it.next()) |v| v.* = @fromBackingInt(new_of[@backingInt(v.*)]);
    for (zcu.defparams.keys()) |*key| key.instance = @fromBackingInt(new_of[@backingInt(key.instance)]);
    try zcu.defparams.reIndex(s.gpa);
    for (zcu.inserts.items(.instance), zcu.inserts.items(.bridge)) |*i, *b| {
        i.* = @fromBackingInt(new_of[@backingInt(i.*)]);
        b.* = @fromBackingInt(new_of[@backingInt(b.*)]);
    }
    var segs: std.AutoHashMapUnmanaged(Zcu.NetKey, String) = .empty;
    var nit = zcu.net_discipline.iterator();
    while (nit.next()) |e| try segs.put(s.gpa, .{ .instance = @fromBackingInt(new_of[@backingInt(e.key_ptr.instance)]), .net = e.key_ptr.net }, e.value_ptr.*);
    zcu.net_discipline.deinit(s.gpa);
    zcu.net_discipline = segs;
}
