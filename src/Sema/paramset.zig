//! §6.4 paramsets: an instance's target name and given values in; the
//! module it elaborates, the paramset §6.4.2 selected and the values its
//! statements give that module out. A target that names a module is the
//! module; one that names paramsets selects one by §6.4.2's rules and
//! tie-breaks, folds its parameters, and follows its chain (§6.4: "the last
//! paramset in the chain shall reference a module") with its `.name = expr`
//! statements as the next level's given values.
//! Cites: VAMS-2023 §3.4.2, §3.4.5, §6.4, §6.4.1, §6.4.2.
//!
//! Contents:
//! - `pub const Picked = struct`
//! - `pub fn resolve(s: *Sema, file: Zcu.File.Index, src: Inst.Ref, target: InternPool.String, givens: walk.Run, list: *std.ArrayList(walk.Given), dps: []const defparam.Dp, parent: ?*const Zcu.Hier) Allocator.Error!?Picked`
//! - `pub fn chainEnds(s: *Sema, name: InternPool.String, out: *std.AutoHashMapUnmanaged(InternPool.String, void)) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const fold = @import("std_kernels").fold;
const Sema = @import("../Sema.zig");
const Zcu = @import("../Zcu.zig");
const eval = @import("eval.zig");
const walk = @import("walk.zig");
const defparam = @import("defparam.zig");
const dist = @import("dist.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Env = eval.Env;
const Const = eval.Const;
const payloadOf = walk.payloadOf;

/// What an instance elaborates: its module, the first paramset selected on
/// the way (`Decl.none` for a module target), the module's given values and
/// the last paramset level's §9.18 values (null for a module target).
pub const Picked = struct { module: Zcu.Decl, paramset: Zcu.Decl, givens: walk.Run, base: ?Zcu.Hier, own: InternPool.Index = .none };

/// §6.4.2's tie-breaking rules, in the clause's order.
const TieRule = enum { un_overridden, ranged_locals, unconnected_ports };

/// Resolves `target` for an instance given `givens` (a run of `list`, to
/// which a paramset's statements append) and the defparams `dps` that reach
/// it, which a paramset target takes (§6.4.2 selects on them too). Null
/// after E0904 (no module or
/// paramset of the name, or a chain that never reaches a module), E0911 (no
/// paramset admits the values) or E0914 (still ambiguous).
pub fn resolve(s: *Sema, file: Zcu.File.Index, src: Inst.Ref, target: InternPool.String, givens: walk.Run, list: *std.ArrayList(walk.Given), dps: []const defparam.Dp, parent: ?*const Zcu.Hier) Allocator.Error!?Picked {
    assert(target != .empty);
    assert(givens.start + givens.len <= list.items.len);
    const zcu = s.zcu;
    var name = target;
    var run = givens;
    var first: Zcu.Decl = .none;
    var own: InternPool.Index = .none;
    var base: ?Zcu.Hier = null;
    for (0..zcu.paramsets.items.len + 1) |_| {
        // Annex E: a user paramset shadows a shipped primitive of its name.
        if (zcu.modules.get(name)) |d| if (!zcu.isBuiltin(d) or !try hasParamset(s, name))
            return .{ .module = d, .paramset = first, .givens = run, .base = base, .own = own };
        const level_dps = if (std.meta.eql(first, Zcu.Decl.none)) dps else &.{};
        const ps = (try select(s, file, src, name, list.items[run.start..][0..run.len], level_dps)) orelse return null;
        if (std.meta.eql(first, Zcu.Decl.none)) first = ps;
        const vir = zcu.fileVir(ps.file);
        const decl = payloadOf(vir, Inst.Paramset, zcu.declRow(ps).inst);
        var env: Env = try .init(s.gpa, s.arena, &zcu.intern_pool, vir, &.{decl.body});
        defer env.deinit();
        try walk.applyGivens(s, &env, file, src, list.items[run.start..][0..run.len], false, decl.name);
        try defparam.applyDefparams(s, &env, level_dps, decl.name);
        env.hier = try walk.hierValues(s, &env, if (base) |*b| b else parent, list.items[run.start..][0..run.len], level_dps, file, src);
        base = env.hier;
        // The first level's own parameters, kept for the instance's rows.
        if (own == .none) {
            for (env.positions.keys()) |param_inst| _ = try env.param(param_inst);
            own = try zcu.intern_pool.get(s.gpa, .{ .aggregate = .{ .ty = .none, .elems = env.values.items } });
        }
        // §6.4.1 each `.name = expr ;` gives the next level a value.
        const start: u32 = @intCast(list.items.len);
        for (vir.body(decl.body)) |i| if (vir.instructions.items(.tag)[@backingInt(i)] == .ps_override) {
            const o = payloadOf(vir, Inst.Override, i);
            const v = try dist.fold(s, &env, ps.file, o.value) orelse if (try env.body(o.value)) |c| try env.intern(c) else InternPool.Index.undef;
            try list.append(s.arena, .{ .name = try zcu.intern_pool.getString(s.gpa, vir.string(o.name)), .value = v });
        };
        run = .{ .start = start, .len = @intCast(list.items.len - start) };
        name = try zcu.intern_pool.getString(s.gpa, vir.string(decl.module));
    }
    try s.fail(.E0904, file, src, "`{s}`: the paramset chain is a cycle and never reaches a module", .{zcu.intern_pool.stringToSlice(target)});
    return null;
}

/// Adds to `out` every module a paramset chain from `name` can end at:
/// each overload's target, followed while it names paramsets. Bounded by the
/// paramset count, so a cycle ends.
pub fn chainEnds(s: *Sema, name: InternPool.String, out: *std.AutoHashMapUnmanaged(InternPool.String, void)) Allocator.Error!void {
    const before = out.count();
    defer assert(out.count() >= before);
    assert(name != .empty);
    const zcu = s.zcu;
    var work: std.ArrayList(InternPool.String) = .empty;
    try work.append(s.arena, name);
    var steps: usize = 0;
    while (work.pop()) |n| : (steps += 1) {
        if (steps > zcu.paramsets.items.len) break;
        for (zcu.paramsets.items) |d| {
            if (!try nameIs(s, d, n)) continue;
            const vir = zcu.fileVir(d.file);
            const target = try zcu.intern_pool.getString(s.gpa, vir.string(payloadOf(vir, Inst.Paramset, zcu.declRow(d).inst).module));
            const gop = try out.getOrPut(s.arena, target);
            if (!gop.found_existing) try work.append(s.arena, target);
        }
    }
}

// ---- private ----

/// §6.4.2 the one paramset named `name` that admits `givens`, after the
/// tie-breaking rules; null after E0904, E0911 or E0914.
fn select(s: *Sema, file: Zcu.File.Index, src: Inst.Ref, name: InternPool.String, givens: []const walk.Given, dps: []const defparam.Dp) Allocator.Error!?Zcu.Decl {
    assert(name != .empty);
    var candidates: u32 = 0;
    var live: std.ArrayList(Zcu.Decl) = .empty;
    for (s.zcu.paramsets.items) |d| {
        if (!try nameIs(s, d, name)) continue;
        candidates += 1;
        if (try admits(s, d, file, src, givens, dps)) try live.append(s.arena, d);
    }
    const shown = s.zcu.intern_pool.stringToSlice(name);
    if (candidates == 0) {
        try s.failRule(.{ .rule = .cell_unbound, .name = shown }, .E0904, file, src, "`{s}`", .{shown});
        return null;
    }
    // "applied in order until a unique paramset has been selected".
    for ([_]TieRule{ .un_overridden, .ranged_locals, .unconnected_ports }) |rule|
        if (live.items.len > 1) try tieBreak(s, file, src, givens, &live, rule);
    if (live.items.len == 0) {
        try s.fail(.E0911, file, src, "no paramset named `{s}` admits these parameter values", .{shown});
        return null;
    }
    if (live.items.len > 1) {
        try s.fail(.E0914, file, src, "{d} paramsets named `{s}` are still applicable after §6.4.2's tie-breaking rules", .{ live.items.len, shown });
        return null;
    }
    assert(live.items.len == 1);
    return live.items[0];
}

fn hasParamset(s: *Sema, name: InternPool.String) Allocator.Error!bool {
    assert(name != .empty);
    for (s.zcu.paramsets.items) |d| if (try nameIs(s, d, name)) return true;
    return false;
}

fn nameIs(s: *Sema, d: Zcu.Decl, name: InternPool.String) Allocator.Error!bool {
    assert(s.zcu.declRow(d).kind == .paramset);
    const vir = s.zcu.fileVir(d.file);
    return std.mem.eql(u8, vir.string(s.zcu.declRow(d).name), s.zcu.intern_pool.stringToSlice(name));
}

/// §6.4.2's selection rules: every named value names an overridable
/// parameter of the paramset (or a §9.18 system parameter), no more ordered
/// values than it has, every parameter (local ones included) within its
/// declared ranges, and the module declares every port the instance
/// connects. A value or bound that does not fold admits.
fn admits(s: *Sema, ps: Zcu.Decl, file: Zcu.File.Index, src: Inst.Ref, givens: []const walk.Given, dps: []const defparam.Dp) Allocator.Error!bool {
    assert(s.zcu.declRow(ps).kind == .paramset);
    const zcu = s.zcu;
    const vir = zcu.fileVir(ps.file);
    const decl = payloadOf(vir, Inst.Paramset, zcu.declRow(ps).inst);
    var env: Env = try .init(s.gpa, s.arena, &zcu.intern_pool, vir, &.{decl.body});
    defer env.deinit();
    var overridable: u32 = 0;
    for (env.positions.keys()) |p| overridable += @intFromBool(walk.isOverridable(vir, p));
    var ordered: u32 = 0;
    for (givens) |g| {
        if (g.name == .empty) {
            defer ordered += 1;
            var n: u32 = 0;
            for (env.positions.keys()) |q| if (walk.isOverridable(vir, q)) {
                if (n == ordered and g.value != .none) try env.given.put(s.gpa, q, g.value);
                n += 1;
            };
            continue;
        }
        const n = zcu.intern_pool.stringToSlice(g.name);
        if (env.systemNamed(n) != null) continue;
        const p = env.named(n) orelse return false;
        if (!walk.isOverridable(vir, p)) return false;
        if (g.value != .none) try env.given.put(s.gpa, p, g.value);
    }
    if (ordered > overridable) return false;
    for (dps) |dp| {
        if (env.systemNamed(dp.name) != null) continue;
        const p = env.named(dp.name) orelse return false;
        if (!walk.isOverridable(vir, p)) return false;
        try env.given.put(s.gpa, p, dp.value);
    }
    for (env.positions.keys()) |p| {
        const ranges = vir.list(Inst.ValueRange, payloadOf(vir, Inst.Param, p).ranges);
        if (ranges.len == 0) continue;
        const v = (try env.param(p)) orelse continue;
        if (!try inRanges(&env, v, ranges)) return false;
    }
    const module = zcu.modules.get(try zcu.intern_pool.getString(s.gpa, vir.string(decl.module))) orelse return true;
    const conns = instanceConns(zcu, file, src) orelse return true;
    const ports = try portNames(s, module);
    for (conns.list) |c| {
        if (c.name == .empty) continue;
        if (std.mem.findScalar(Vir.String, ports.names, c.name) == null) {
            const found = for (ports.names) |pn| {
                if (std.mem.eql(u8, ports.vir.string(pn), conns.vir.string(c.name))) break true;
            } else false;
            if (!found) return false;
        }
    }
    if (conns.list.len != 0 and conns.list[0].name == .empty and conns.list.len > ports.names.len) return false;
    return true;
}

/// §3.4.2: inside one `from` range when any is declared, and inside no
/// `exclude` range. A bound that does not fold matches a `from` and misses
/// an `exclude`, so it admits.
fn inRanges(env: *Env, v: Const, ranges: []const Inst.ValueRange) Allocator.Error!bool {
    assert(env.positions.count() == env.values.items.len);
    assert(ranges.len != 0);
    var from = false;
    var inside = false;
    for (ranges) |r| {
        const hit = (try matches(env, v, r)) orelse !r.flags.exclude;
        if (r.flags.exclude) {
            if (hit) return false;
        } else {
            from = true;
            inside = inside or hit;
        }
    }
    return !from or inside;
}

/// Whether `v` lies in `r`, or null when a bound does not fold.
fn matches(env: *Env, v: Const, r: Inst.ValueRange) Allocator.Error!?bool {
    assert(env.positions.count() == env.values.items.len);
    if (r.flags.set) {
        const insts = env.vir.body(r.lo);
        if (insts.len == 0) return null;
        const last = insts[insts.len - 1];
        const tag = env.vir.instructions.items(.tag)[@backingInt(last)];
        const elems: []const Inst.Ref = if (tag == .pattern or tag == .concat) env.vir.list(Inst.Ref, payloadOf(env.vir, Inst.Refs, last)) else &.{last.toRef()};
        for (elems) |e| {
            const x = (try env.ref(e)) orelse return null;
            if ((fold.binary(.eq, v, x, null) orelse return null).isTrue()) return true;
        }
        return false;
    }
    const lo = (try env.body(r.lo)) orelse return null;
    if (!r.flags.interval) return (fold.binary(.eq, v, lo, null) orelse return null).isTrue();
    const hi = (try env.body(r.hi)) orelse return null;
    const above = fold.binary(if (r.flags.lo_closed) .ge else .gt, v, lo, null) orelse return null;
    const below = fold.binary(if (r.flags.hi_closed) .le else .lt, v, hi, null) orelse return null;
    return above.isTrue() and below.isTrue();
}

/// Applies one tie-breaking rule: scores each surviving candidate and keeps
/// the minimum (a "greatest" rule negates its count).
fn tieBreak(s: *Sema, file: Zcu.File.Index, src: Inst.Ref, givens: []const walk.Given, live: *std.ArrayList(Zcu.Decl), rule: TieRule) Allocator.Error!void {
    assert(live.items.len <= s.zcu.paramsets.items.len);
    assert(live.items.len > 1);
    const zcu = s.zcu;
    const scores = try s.arena.alloc(i64, live.items.len);
    for (live.items, scores) |ps, *score| {
        const vir = zcu.fileVir(ps.file);
        const decl = payloadOf(vir, Inst.Paramset, zcu.declRow(ps).inst);
        score.* = switch (rule) {
            // "the fewest number of un-overridden parameters".
            .un_overridden => blk: {
                var n: i64 = 0;
                var ordered: u32 = 0;
                for (givens) |g| ordered += @intFromBool(g.name == .empty);
                var k: u32 = 0;
                for (vir.body(decl.body)) |p| {
                    if (vir.instructions.items(.tag)[@backingInt(p)] != .param or !walk.isOverridable(vir, p)) continue;
                    defer k += 1;
                    const pn = vir.string(payloadOf(vir, Inst.Param, p).name);
                    const given = k < ordered or for (givens) |g| {
                        if (g.name != .empty and std.mem.eql(u8, zcu.intern_pool.stringToSlice(g.name), pn)) break true;
                    } else false;
                    n += @intFromBool(!given);
                }
                break :blk n;
            },
            // "the greatest number of local parameters with specified ranges".
            .ranged_locals => blk: {
                var n: i64 = 0;
                for (vir.body(decl.body)) |p| {
                    if (vir.instructions.items(.tag)[@backingInt(p)] != .param) continue;
                    const pd = payloadOf(vir, Inst.Param, p);
                    n += @intFromBool(!walk.isOverridable(vir, p) and pd.ranges.len != 0);
                }
                break :blk -n;
            },
            // "the fewest ports not connected in the instance line".
            .unconnected_ports => blk: {
                const module = zcu.modules.get(try zcu.intern_pool.getString(s.gpa, vir.string(decl.module))) orelse break :blk std.math.maxInt(i64);
                const ports = try portNames(s, module);
                const conns = instanceConns(zcu, file, src) orelse break :blk @intCast(ports.names.len);
                var n: i64 = 0;
                for (ports.names, 0..) |pn, k| {
                    const connected = for (conns.list, 0..) |c, j| {
                        if (c.value.len == 0) continue;
                        if (c.name == .empty and j == k) break true;
                        if (c.name != .empty and std.mem.eql(u8, conns.vir.string(c.name), ports.vir.string(pn))) break true;
                    } else false;
                    n += @intFromBool(!connected);
                }
                break :blk n;
            },
        };
    }
    const best = std.mem.min(i64, scores);
    var kept: usize = 0;
    for (live.items, scores) |ps, score| if (score == best) {
        live.items[kept] = ps;
        kept += 1;
    };
    assert(kept != 0);
    live.shrinkRetainingCapacity(kept);
}

/// The connections of the instance instruction `src` of `file`, with the
/// Vir they are in, or null for a root.
fn instanceConns(zcu: *const Zcu, file: Zcu.File.Index, src: Inst.Ref) ?struct { vir: *const Vir, list: []const Inst.Arg } {
    assert(@backingInt(file) < zcu.files.len);
    const i = src.toIndex() orelse return null;
    const vir = zcu.fileVir(file);
    assert(vir.instructions.items(.tag)[@backingInt(i)] == .instance);
    return .{ .vir = vir, .list = vir.list(Inst.Arg, payloadOf(vir, Inst.Instance, i).conns) };
}

/// A module's port names in declaration order, with the Vir they are in.
fn portNames(s: *Sema, module: Zcu.Decl) Allocator.Error!struct { vir: *const Vir, names: []const Vir.String } {
    assert(@backingInt(module.file) < s.zcu.files.len);
    assert(s.zcu.declRow(module).kind != .paramset);
    const vir = s.zcu.fileVir(module.file);
    const m = payloadOf(vir, Inst.Module, s.zcu.declRow(module).inst);
    var names: std.ArrayList(Vir.String) = .empty;
    for (vir.body(m.ports)) |p| switch (vir.instructions.items(.tag)[@backingInt(p)]) {
        .port => try names.append(s.arena, payloadOf(vir, Inst.Port, p).name),
        .io => try names.append(s.arena, payloadOf(vir, Inst.Io, p).name),
        else => {}, // else: a header holds only ports and port declarations
    };
    return .{ .vir = vir, .names = names.items };
}
