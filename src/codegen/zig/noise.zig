//! §4.6.4 the noise generators and §4.6.3 `ac_stim`, over `Air.Device.noise`
//! (old: `src/codegen/device/codegen/noise.zig`, `src/analog/noise_op.zig`).
//! A generator's placement (the branch it stamps) and its linear factor are
//! not precomputed by Sema (`Air.Device.Noise`'s own doc: "the call's value
//! reaches their sums"), so this reads them off the body: `plan` finds,
//! for each generator, every contribution its call's value reaches (a
//! forward taint fixpoint, `reachOf`, mirroring `Liveness.propagate`'s own
//! shape) and places it (`stamps.zig`'s row/col rule: a potential source is
//! in series on its branch unknown, a flow source on its nodes). The factor
//! itself, and each call's own `pwr`/`exp`/`mag`/`phase`, come from a second
//! body over the same `Air` (`genBody`, like `say.genBody`): every
//! §4.6.4/§4.6.3 call is a root, so its own arguments render (`Liveness`'s
//! `markUsed` suppresses them only where the call is not a root), and so does
//! every assigned resistive sum, under a second `calls.zig` rendering
//! (`Function.Phase.noise`) that forces one call at a time to 1 (`hot`): the
//! difference from the same sum at no call hot (`core`'s own value, since a
//! generator's use is required linear, §4.6.4.6) is its factor.
//! Cites: VAMS-2023 §4.6.3, §4.6.4, §4.6.4.1, §4.6.4.3, §4.6.4.4, §4.6.4.6.
//!
//! Contents:
//! - `pub const Row = struct { gen, contrib, row, col, neg }`
//! - `pub fn plan(dg: *DeclGen) DeclGen.Error!void`
//! - `pub const Body = struct { text, uses }`
//! - `pub fn genBody(dg: *DeclGen) DeclGen.Error!Body`
//! - `pub fn genReturn(dg: *DeclGen, f: *Function) DeclGen.Error!void`
//! - `pub fn genTables(dg: *DeclGen, w: *std.Io.Writer) DeclGen.Error!void`
//! - `pub fn genEntries(dg: *DeclGen, w: *std.Io.Writer, b: Body) DeclGen.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Air = @import("air");
const InternPool = @import("intern_pool");
const DeclGen = @import("DeclGen.zig");
const Function = @import("Function.zig");
const Liveness = @import("Liveness.zig");
const ops = @import("ops.zig");
const status = @import("status.zig");
const Real = Function.Real;
const Device = Air.Device;
const Ref = Air.Inst.Ref;
const Error = DeclGen.Error;

/// A generator's export row: `Device.noise[gen]` placed on contribution
/// `contrib`'s branch at (`row`, `col`); `neg` when that contribution is a
/// potential source (its sign is already in the row equation, `stamps.zig`).
pub const Row = struct {
    gen: u32,
    contrib: u32,
    row: u32,
    col: u32,
    neg: bool,
};

/// No branch-current unknown (`stamps.zig`'s own sentinel).
const branch_none: u32 = std.math.maxInt(u32);
/// `noiseCore`'s "no generator forced to 1" argument.
const hot_none: u32 = std.math.maxInt(u32);

/// Fills `dg.noise_rows`, `dg.ac_rows` and `dg.noise_live`. Every
/// `Device.noise` entry is placed on every contribution its call's value
/// reaches (`reachOf`); a contribution `stamps.plan` would have refused
/// (an indirect or conditional potential row) reaches none, since its
/// `resist` slot is never assigned or its `branch_u` stays `.none`.
pub fn plan(dg: *DeclGen) Error!void {
    const d = dg.device;
    if (d.noise.len == 0) return;
    const n: u32 = @intCast(dg.air.instructions.len);
    const roots = try dg.arena.alloc(bool, n);
    @memset(roots, false);
    for (d.noise.items(.call)) |call| roots[@backingInt(call)] = true;
    for (d.contributions.items(.resist)) |slot| {
        if (dg.live.assigned[@backingInt(slot)]) roots[@backingInt(slot)] = true;
    }
    dg.noise_live = Liveness.init(dg.arena, dg.air.*, @intCast(dg.device.nodes.len), roots) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooManyUnknowns => unreachable, // `dg.live` was built over the same unknowns
    };

    var noise_rows: std.ArrayList(Row) = .empty;
    var ac_rows: std.ArrayList(Row) = .empty;
    for (d.noise.items(.call), d.noise.items(.kind), 0..) |call, kind, gi| {
        const reach = try reachOf(dg.arena, dg.air.*, call);
        for (d.contributions.items(.resist), 0..) |slot, k| {
            if (!dg.live.assigned[@backingInt(slot)]) continue;
            if (!reach[@backingInt(slot)]) continue;
            const c = d.contributions.get(k);
            const p = placeOf(dg, @intCast(k), c) orelse continue;
            const row: Row = .{ .gen = @intCast(gi), .contrib = @intCast(k), .row = p.row, .col = p.col, .neg = c.access == .potential };
            if (kind == .ac_stim) try ac_rows.append(dg.arena, row) else try noise_rows.append(dg.arena, row);
        }
    }
    dg.noise_rows = noise_rows.items;
    dg.ac_rows = ac_rows.items;
}

/// Contribution `k`'s (row, col): a potential source in series on its
/// branch unknown (`row == col == dg.branch_u[k]`, null when `stamps.plan`
/// would have refused it, so it reaches nothing); a flow source on its
/// nodes, `row == col` when one end is ground (the old `plan/noise.zig`).
fn placeOf(dg: *DeclGen, k: u32, c: Device.Contribution) ?struct { row: u32, col: u32 } {
    const ground = @backingInt(Device.Node.Index.ground);
    if (c.access == .potential) {
        const u = dg.branch_u[k];
        if (u == branch_none) return null;
        return .{ .row = u, .col = u };
    }
    const hi = @backingInt(c.hi);
    const lo = @backingInt(c.lo);
    const row = if (hi != ground) hi else lo;
    const col = if (lo != ground) lo else row;
    return .{ .row = row, .col = col };
}

/// Whether instruction `i`'s value may depend on `gen`'s call: a forward
/// taint fixpoint over the same tags `Liveness.propagate` reads lanes
/// through, seeded at `gen` (true at depth 0, matching old's `coeffAt`).
/// Bounded the same way `Liveness.init` bounds its own passes: each pass
/// only turns a bit on, so it settles in at most one pass per instruction.
fn reachOf(arena: Allocator, air: Air, gen: Air.Inst.Index) Allocator.Error![]bool {
    const n = air.instructions.len;
    const reach = try arena.alloc(bool, n);
    @memset(reach, false);
    reach[@backingInt(gen)] = true;
    const tags = air.instructions.items(.tag);
    const datas = air.instructions.items(.data);
    var changed = true;
    var pass: usize = 0;
    while (changed) : (pass += 1) {
        assert(pass <= n + 1);
        changed = false;
        for (tags, datas, 0..) |tag, data, i| {
            switch (tag) {
                // A slot's or block's reach joins every value written to
                // it, exactly as `Liveness.propagate` joins their masks.
                .assign => {
                    const slot = @backingInt(data.bin_op.lhs.toIndex().?);
                    if (!reach[slot] and refReach(reach, data.bin_op.rhs)) {
                        reach[slot] = true;
                        changed = true;
                    }
                },
                .br => {
                    if (data.br.operand != .none) {
                        const blk = @backingInt(data.br.block_inst);
                        if (!reach[blk] and refReach(reach, data.br.operand)) {
                            reach[blk] = true;
                            changed = true;
                        }
                    }
                },
                else => {
                    if (!reach[i] and reachInst(air, tag, data, reach)) {
                        reach[i] = true;
                        changed = true;
                    }
                },
            }
        }
    }
    return reach;
}

fn refReach(reach: []const bool, ref: Ref) bool {
    const i = ref.toIndex() orelse return false;
    return reach[@backingInt(i)];
}

/// `reachOf`'s one-instruction step, over the arithmetic and control tags a
/// §4.6 argument or a `<+` accumulation can hold (`Liveness.propagate`'s
/// own tag list). Anything else (an integer op, a kernel this walk does not
/// know) answers false: a conservative "does not reach", good enough since
/// a §4.6.4.6 generator's use is required linear over these tags alone.
fn reachInst(air: Air, tag: Air.Inst.Tag, data: Air.Inst.Data, reach: []const bool) bool {
    return switch (tag) {
        .load => refReach(reach, data.un_op),
        .fload => refReach(reach, data.bin_op.lhs),
        .fadd, .fsub, .fmul, .fdiv, .fmod, .pow, .hypot, .fmin, .fmax, .atan2 => refReach(reach, data.bin_op.lhs) or refReach(reach, data.bin_op.rhs),
        .fneg, .sqrt, .exp, .expm1, .ln, .ln1p, .log10, .floor, .ceil, .fabs, .sin, .cos, .tan, .asin, .acos, .atan, .sinh, .cosh, .tanh, .asinh, .acosh, .atanh, .opt_barrier, .dstop => refReach(reach, data.un_op),
        .select => blk: {
            const bin = air.extraData(Air.Bin, data.pl_op.payload).data;
            break :blk refReach(reach, bin.lhs) or refReach(reach, bin.rhs);
        },
        .call => blk: {
            const x = air.extraData(Air.Call, data.ty_pl.payload);
            for (air.extra[x.end..][0..x.data.args_len]) |w| {
                const r: Ref = @fromBackingInt(w);
                if (refReach(reach, r)) break :blk true;
            }
            break :blk false;
        },
        else => false, // else: an integer op, `alloc`, a control tag: no real lanes to carry
    };
}

/// The unique `.assign`'s right-hand `Ref` writing to `slot` (a resist
/// slot or a plain local, e.g. `ntab` in `ntab = noise_table(...); ... +
/// ntab;`), null when zero or more than one write it (an ambiguous
/// accumulation: `additiveSign` falls back to the hot/base probe for
/// that row, unchanged).
fn assignedValue(air: Air, slot: Air.Inst.Index) ?Ref {
    const tags = air.instructions.items(.tag);
    const datas = air.instructions.items(.data);
    var rhs: ?Ref = null;
    for (tags, datas) |tag, data| {
        if (tag != .assign) continue;
        const lhs = data.bin_op.lhs.toIndex() orelse continue;
        if (@backingInt(lhs) != @backingInt(slot)) continue;
        if (rhs != null) return null; // more than one write to this slot: ambiguous, bail
        rhs = data.bin_op.rhs;
    }
    return rhs;
}

/// `ref`'s net sign along a pure `fadd`/`fsub`/`fneg`/`load` path down to
/// `gen`'s own call, `.absent` once `reach` (`reachOf`'s fixpoint, seeded
/// at `gen`) says a subtree carries none of it (the branch's other,
/// deterministic terms — ignored, same as an `fadd`'s untainted operand
/// always is), and `.complex` the moment a non-additive tag (`fmul`,
/// `fdiv`, ...) carries it: a genuine §4.6.4.6 scale, e.g.
/// `2*white_noise(x)`.
const Sign = enum { absent, pos, neg, complex };

/// `visiting`'s own slot is mid-resolution (an accumulator's `s = load(s)
/// + term`, which `assignedValue`'s "more than one write" check already
/// makes the *only* way a slot can load itself with just one `.assign`):
/// its pre-accumulation baseline is, by construction, untainted, so the
/// revisit answers `.absent` instead of recursing forever.
fn signOf(air: Air, reach: []const bool, ref: Ref, gen: Air.Inst.Index, visiting: []bool) Sign {
    const idx = ref.toIndex() orelse return .absent; // an interned constant: never the call
    if (@backingInt(idx) == @backingInt(gen)) return .pos;
    if (!reach[@backingInt(idx)]) return .absent;
    const tag = air.instructions.items(.tag)[@backingInt(idx)];
    const data = air.instructions.items(.data)[@backingInt(idx)];
    return switch (tag) {
        .fadd => combineSign(signOf(air, reach, data.bin_op.lhs, gen, visiting), signOf(air, reach, data.bin_op.rhs, gen, visiting)),
        .fsub => combineSign(signOf(air, reach, data.bin_op.lhs, gen, visiting), negateSign(signOf(air, reach, data.bin_op.rhs, gen, visiting))),
        .fneg => negateSign(signOf(air, reach, data.un_op, gen, visiting)),
        // A plain local (`real ntab = noise_table(...); ... + ntab;`): the
        // call's own slot is just as pure additive a path as any operand.
        .load => blk: {
            const lslot = data.un_op.toIndex() orelse break :blk .complex;
            const li = @backingInt(lslot);
            if (visiting[li]) break :blk .absent; // self-accumulation's own baseline
            const rhs = assignedValue(air, lslot) orelse break :blk .complex;
            visiting[li] = true;
            defer visiting[li] = false;
            break :blk signOf(air, reach, rhs, gen, visiting);
        },
        else => .complex, // tainted but not a pure +/-/neg/load path: a real scale
    };
}
fn combineSign(a: Sign, b: Sign) Sign {
    return if (a == .absent) b else if (b == .absent) a else .complex; // both sides carry it: ambiguous, bail
}
fn negateSign(a: Sign) Sign {
    return switch (a) {
        .absent => .absent,
        .pos => .neg,
        .neg => .pos,
        .complex => .complex,
    };
}

/// Whether resist slot `slot`'s value is call `gen`'s own result added,
/// subtracted or negated in with nothing else along the path: an exact
/// §4.6.4.6 factor of ±1, read off the structure instead of probed.
///
/// Fixes the probe's catastrophic cancellation: `genEntries`' hot/base
/// technique computes the factor as `(D + 1.0) - (D + 0.0)` in `f64`,
/// where `D` is the branch's other, deterministic terms (e.g.
/// `V(p,n)/R`). That rounds away from `1.0` the moment `D` is not tiny
/// next to `1.0` — `D = 1.0/1000.0` gives `0.9999999999999999`, one ulp
/// short, confirmed against an independent `f128` recomputation of the
/// same `D + 1.0 - D` (ulp 0 from `new`'s f64, ulp ~1 from `old`'s, so the
/// probe itself is the wrong side). The common, unscaled case needs no
/// probe at all: the factor is the compile-time constant ±1. Null falls
/// back to the hot/base probe unchanged (a slot with more than one
/// `.assign` — an ambiguous accumulation — or a path that leaves
/// `fadd`/`fsub`/`fneg`/`load`, a genuine scale the probe must still read).
fn additiveSign(dg: *DeclGen, reach: []const bool, slot: Air.Inst.Index, gen: Air.Inst.Index) Error!?i2 {
    const rhs = assignedValue(dg.air.*, slot) orelse return null;
    const visiting = try dg.arena.alloc(bool, dg.air.instructions.len);
    @memset(visiting, false);
    visiting[@backingInt(slot)] = true; // `slot`'s own accumulation, e.g. `s = load(s) + V(p,n)/R + ntab`
    return switch (signOf(dg.air.*, reach, rhs, gen, visiting)) {
        .absent, .complex => null,
        .pos => 1,
        .neg => -1,
    };
}

/// Call `call`'s argument `k`, or null past its length.
fn argRef(dg: *DeclGen, call: Air.Inst.Index, k: usize) ?Ref {
    const data = dg.air.instructions.items(.data)[@backingInt(call)];
    const x = dg.air.extraData(Air.Call, data.ty_pl.payload);
    if (k >= x.data.args_len) return null;
    return @fromBackingInt(dg.air.extra[x.end + k]);
}

/// `ac_stim`'s own `name` argument, `"ac"` when absent (`AcGen`'s default).
fn acStimName(dg: *DeclGen, call: Air.Inst.Index) []const u8 {
    const r = argRef(dg, call, 0) orelse return "ac";
    const ii = r.toInterned() orelse return "ac";
    return switch (dg.ip.indexToKey(ii)) {
        .str => |s| dg.ip.stringToSlice(s),
        else => "ac", // else: Sema already required a string literal here
    };
}

/// `ref` as a folded `f64`, or null (a §4.6.4.3 array-parameter table knot:
/// `noiseTablePoints` carries those, which this backend does not emit yet).
fn foldFloat(dg: *DeclGen, ref: Ref) ?f64 {
    const i = ref.toInterned() orelse return null;
    return switch (dg.ip.indexToKey(i)) {
        .float => |x| x,
        .int => |n| switch (n.storage) {
            .small => |v| @floatFromInt(v),
            .big => null,
        },
        else => null, // else: not a number
    };
}

fn foldCount(dg: *DeclGen, ref: Ref) ?usize {
    const i = ref.toInterned() orelse return null;
    return switch (dg.ip.indexToKey(i)) {
        .int => |n| switch (n.storage) {
            .small => |v| if (v >= 0) @intCast(v) else null,
            .big => null,
        },
        else => null, // else: not an integer literal
    };
}

const Table = struct { interp: enum { linear, log }, points: [][2]f64 };

/// §4.6.4.3/.4 `noise_table`/`noise_table_log`'s call: `count, f0, p0, ...`
/// (`src/Sema/op.zig`'s own shape), sorted by frequency. `count` is the
/// *flat* element count `vectorArg`/`noiseFile` both push (two reals per
/// knot: `op.zig:166` interns `pairs.len` over the file's flat `f.vals`,
/// `op.zig:246` interns `elems.len` over the literal array's own flat
/// elements) — not the knot count, so it halves here before indexing.
/// Null when a knot does not fold (a §4.6.4.3 array parameter): not yet
/// spelled here.
fn foldTable(dg: *DeclGen, call: Air.Inst.Index, log: bool) Error!?Table {
    const flat = foldCount(dg, argRef(dg, call, 0) orelse return null) orelse return null;
    assert(flat % 2 == 0); // one frequency, one power per knot (contract above)
    const count = flat / 2;
    const pts = try dg.arena.alloc([2]f64, count);
    for (0..count) |k| {
        const f = foldFloat(dg, argRef(dg, call, 1 + k * 2) orelse return null) orelse return null;
        const p = foldFloat(dg, argRef(dg, call, 2 + k * 2) orelse return null) orelse return null;
        pts[k] = .{ f, p };
    }
    std.mem.sort([2]f64, pts, {}, struct {
        fn lt(_: void, a: [2]f64, b: [2]f64) bool {
            return a[0] < b[0];
        }
    }.lt);
    return .{ .interp = if (log) .log else .linear, .points = pts };
}

/// `noise.genBody`'s statements and what they read.
pub const Body = struct { text: []const u8 = "", uses: Function.Uses = .{} };

/// A second body over `dg.air.mainBody()`, like `say.genBody`: `dg.live`
/// swaps to `dg.noise_live` (roots: every §4.6 call and assigned resist
/// slot) and `Function.Phase.noise` makes `calls.zig` force one call to 1
/// at a time (the `hot` parameter `genEntries` supplies).
pub fn genBody(dg: *DeclGen) Error!Body {
    if (dg.device.noise.len == 0) return .{};
    const core_live = dg.live;
    dg.live = dg.noise_live;
    defer dg.live = core_live;
    var body: std.Io.Writer.Allocating = .init(dg.arena);
    var f: Function = .{ .dg = dg, .w = &body.writer, .phase = .noise };
    try f.genBody(dg.air.mainBody());
    return .{ .text = body.written(), .uses = f.uses };
}

/// `noiseCore`'s `return`: every assigned contribution's resistive sum
/// (`.r{k}`, `Core(S)`'s own naming) and, for every thermal, flicker or
/// `ac_stim` generator, its own value-bearing argument(s) (`.g{i}a`/`b`), so
/// `genEntries` reads `pwr`/`exp`/`mag`/`phase` without a second render.
pub fn genReturn(dg: *DeclGen, f: *Function) Error!void {
    const d = dg.device;
    try dg.print(f.w, "return .{{", .{});
    for (d.contributions.items(.resist), 0..) |slot, k| if (dg.live.assigned[@backingInt(slot)])
        try dg.print(f.w, " .r{d} = s{d},", .{ k, @backingInt(slot) });
    for (d.noise.items(.kind), d.noise.items(.call), 0..) |kind, call, i| switch (kind) {
        .thermal => {
            try dg.print(f.w, " .g{d}a = ", .{i});
            try f.valueOf(argRef(dg, call, 0).?);
            try dg.print(f.w, ",", .{});
        },
        .flicker => {
            try dg.print(f.w, " .g{d}a = ", .{i});
            try f.valueOf(argRef(dg, call, 0).?);
            try dg.print(f.w, ", .g{d}b = ", .{i});
            try f.valueOf(argRef(dg, call, 1).?);
            try dg.print(f.w, ",", .{});
        },
        .ac_stim => {
            try dg.print(f.w, " .g{d}a = ", .{i});
            if (argRef(dg, call, 1)) |r| try f.valueOf(r) else try dg.print(f.w, "1.0", .{});
            try dg.print(f.w, ", .g{d}b = ", .{i});
            if (argRef(dg, call, 2)) |r| try f.valueOf(r) else try dg.print(f.w, "0.0", .{});
            try dg.print(f.w, ",", .{});
        },
        .table, .table_log => {}, // its knots are `noise_tables`, not this body
    };
    try dg.print(f.w, " }};", .{});
}

/// §4.6.4/§4.6.3 `noise_tables`, `noise_gens` and `ac_gens`: `plan`'s rows
/// placed on a branch, every thermal/flicker/table kind to `noise_gens`,
/// every `ac_stim` to `ac_gens`. `source` is `Device.noise`'s own row
/// index: one call is one generator (§4.6.4.6), so it is already dense and
/// unique; a host that only sums independent PSDs never reads it.
pub fn genTables(dg: *DeclGen, w: *std.Io.Writer) Error!void {
    const d = dg.device;
    if (d.noise.len == 0) return;
    const table_idx = try dg.arena.alloc(?u16, d.noise.len);
    @memset(table_idx, null);
    var tables: std.ArrayList(Table) = .empty;
    for (d.noise.items(.kind), d.noise.items(.call), 0..) |kind, call, i| {
        if (kind != .table and kind != .table_log) continue;
        const t = (try foldTable(dg, call, kind == .table_log)) orelse
            return dg.fail("a §4.6.4.3/.4 noise table whose knots are not constant (a parameter array)", .{});
        table_idx[i] = @intCast(tables.items.len);
        try tables.append(dg.arena, t);
    }
    try dg.print(w, "\n/// §4.6.4.3/.4 the tabulated spectra `noise_gens[k].table` names.\npub const noise_tables = [_]contract.NoiseTable{{\n", .{});
    for (tables.items) |t| {
        try dg.print(w, "    .{{ .interp = .{s}, .points = &.{{", .{if (t.interp == .log) "log" else "linear"});
        for (t.points) |p| try dg.print(w, " .{{ {f}, {f} }},", .{ Real{ .x = p[0] }, Real{ .x = p[1] } });
        try dg.print(w, " }} }},\n", .{});
    }
    try dg.print(w, "}};\n", .{});

    try dg.print(w, "\n/// §4.6.4 the noise generators `noisePsd` prices.\npub const noise_gens = [_]contract.NoiseGen(Self){{\n", .{});
    for (dg.noise_rows) |r| {
        const kind = switch (d.noise.items(.kind)[r.gen]) {
            .thermal => "thermal",
            .flicker => "flicker",
            .table, .table_log => "table",
            .ac_stim => unreachable, // `plan` never routes `ac_stim` here
        };
        const name = dg.ip.stringToSlice(d.noise.items(.name)[r.gen]);
        try dg.print(w, "    .{{ .row = {d}, .col = {d}, .kind = .{s}, .source = {d}, .table = ", .{ r.row, r.col, kind, r.gen });
        if (table_idx[r.gen]) |ti| try dg.print(w, "{d}", .{ti}) else try dg.print(w, "null", .{});
        try dg.print(w, ", .name = \"{f}\" }},\n", .{std.zig.fmtString(name)});
    }
    try dg.print(w, "}};\n", .{});

    try dg.print(w, "\n/// §4.6.3 the stimuli `acStim` prices.\npub const ac_gens = [_]contract.AcGen(Self){{\n", .{});
    for (dg.ac_rows) |r| {
        const name = acStimName(dg, d.noise.items(.call)[r.gen]);
        try dg.print(w, "    .{{ .row = {d}, .col = {d}, .name = \"{f}\" }},\n", .{ r.row, r.col, std.zig.fmtString(name) });
    }
    try dg.print(w, "}};\n", .{});
}

/// Row `r`'s exact §4.6.4.6 factor (±1, `r.neg` folded in) when
/// `additiveSign` can read it off the structure, null when `genCoeff`
/// must fall back to the hot/base probe.
fn rowSign(dg: *DeclGen, r: Row) Error!?i2 {
    const gen_call = dg.device.noise.items(.call)[r.gen];
    const slot = dg.device.contributions.items(.resist)[r.contrib];
    const reach = try reachOf(dg.arena, dg.air.*, gen_call);
    const sign = (try additiveSign(dg, reach, slot, gen_call)) orelse return null;
    return if (r.neg) -sign else sign;
}

/// Row `r`'s `const coeff = ...;` statement, given its own `rowSign`:
/// the exact literal when non-null (no probe, no `hot` render), the
/// hot/base probe (this file's own doc: "the difference from the same
/// sum at no call hot ... is its factor") otherwise.
fn genCoeff(dg: *DeclGen, w: *std.Io.Writer, r: Row, sign: ?i2) Error!void {
    if (sign) |s| {
        try dg.print(w, "        const coeff: f64 = {f};\n", .{Real{ .x = @floatFromInt(s) }});
    } else {
        try dg.print(w, "        const hot = noiseCore(S, xs, model, inst, sim, {d});\n        const coeff = (hot.r{d}.sub(base.r{d})){s}.val();\n", .{
            @backingInt(dg.device.noise.items(.call)[r.gen]), r.contrib, r.contrib, if (r.neg) ".neg()" else "",
        });
    }
}

/// `NoiseCore(S)`, `noiseCore`, `noisePsd` and `acStim`: the second body
/// (`b`, from `genBody`) run once at no call hot (`core`'s own value) and
/// once per generator a row needs, forced to 1 (`hot`); the difference
/// from the shared baseline is that generator's §4.6.4.6 linear factor. A
/// potential contribution's row carries its sign already (`stamps.zig`),
/// so a factor placed there negates once more. `genCoeff` reads the
/// exact ±1 off the structure for the common, unscaled case instead of
/// probing for it (its own doc comment: the probe's catastrophic
/// cancellation on a branch with other, deterministic terms).
pub fn genEntries(dg: *DeclGen, w: *std.Io.Writer, b: Body) Error!void {
    const d = dg.device;
    if (d.noise.len == 0) return;
    // `r{k}` is the only field that reads `S` (`g{i}a`/`g{i}b` are plain
    // `f64`); discard it only when no row survives, or Zig's "pointless
    // discard of function parameter" rejects the usual case where it does.
    const any_row = for (d.contributions.items(.resist)) |slot| {
        if (dg.live.assigned[@backingInt(slot)]) break true;
    } else false;
    try dg.print(w, "\nfn NoiseCore(comptime S: type) type {{\n{s}    return struct {{", .{if (any_row) "" else "    _ = S;\n"});
    for (d.contributions.items(.resist), 0..) |slot, k| if (dg.live.assigned[@backingInt(slot)])
        try dg.print(w, " r{d}: F.zOf(S, 0x{x}),", .{ k, dg.live.masks[@backingInt(slot)] });
    for (d.noise.items(.kind), 0..) |kind, i| switch (kind) {
        .thermal => try dg.print(w, " g{d}a: f64,", .{i}),
        .flicker, .ac_stim => try dg.print(w, " g{d}a: f64, g{d}b: f64,", .{ i, i }),
        .table, .table_log => {},
    };
    try dg.print(w, " }};\n}}\n", .{});

    const tables = dg.table_len.len != 0;
    var decls: std.Io.Writer.Allocating = .init(dg.arena);
    try ops.genDecls(dg, &decls.writer);
    try status.genDecls(dg, &decls.writer);
    // `noisePsd`/`acStim` take `*const Instance` always (`lib/contract/noise.zig`
    // `noisePsdError`, `lib/contract/ac.zig` `acStimError`), never `InstancePtr`:
    // a `mutable_eval` device's own `InstancePtr` is `*Instance`, and passing
    // that where the contract fixes `*const Instance` is the exact
    // "expected *Instance, found *const Instance" mismatch the doc comment on
    // `status_site_beside_noise.va` names. `noiseCore` is only ever called
    // from those two, so it takes `*const Instance` too.
    try dg.print(w, "\n/// §4.6.3/§4.6.4 the body once more, `hot` forcing one §4.6 call to 1\n/// (`hot_none` for none), so a host that needs its linear factor reads\n/// the difference from the same evaluation with no call forced.\nfn noiseCore(comptime S: type, {s}: D.zX(S), {s}: *const Model, {s}: *const Instance, {s}: contract.SimState, hot: u32) NoiseCore(S) {{\n    @setFloatMode(.strict);{s}{s}{s}\n}}\n", .{
        if (b.uses.x) "x" else "_",
        if (b.uses.model) "model" else "_",
        if (b.uses.inst or tables) "inst" else "_",
        if (b.uses.sim) "sim" else "_",
        if (tables) "\n    inst.table_ready = inst.table_kept;" else "",
        decls.written(),
        b.text,
    });

    // `base.r{d}` only reaches text when some row's `genCoeff` still
    // falls back to the probe; `base.g{d}a` only for a thermal/flicker
    // row (never a table's). A device whose every noise row is a table
    // all `rowSign` resolves, so `base` would go wholly unread: the same
    // "pointless discard of function parameter" `NoiseCore`'s `S` above
    // gives, if the empty-row discard below did not also cover it.
    const psd_signs = try dg.arena.alloc(?i2, dg.noise_rows.len);
    var psd_base_used = false;
    for (dg.noise_rows, 0..) |r, i| {
        psd_signs[i] = try rowSign(dg, r);
        const kind = d.noise.items(.kind)[r.gen];
        if (kind == .thermal or kind == .flicker or psd_signs[i] == null) psd_base_used = true;
    }
    // `out` is only ever written by a row below; with none, Zig's "local
    // variable is never mutated" rejects `var` the same way it rejects the
    // pointless discard above.
    try dg.print(w, "\n/// §4.6.4 one PSD term per `noise_gens` row.\npub fn noisePsd(comptime S: type, x: [n_u]f64, model: *const Model, inst: *const Instance, sim: contract.SimState) [noise_gens.len]contract.PsdTerm {{\n    const xs = D.zProbe(S, &x);\n    const base = noiseCore(S, xs, model, inst, sim, {d});\n{s}    {s} out: [noise_gens.len]contract.PsdTerm = undefined;\n", .{ hot_none, if (!psd_base_used) "    _ = base;\n" else "", if (dg.noise_rows.len == 0) "const" else "var" });
    for (dg.noise_rows, 0..) |r, k| {
        const kind = d.noise.items(.kind)[r.gen];
        try dg.print(w, "    {{\n", .{});
        try genCoeff(dg, w, r, psd_signs[k]);
        switch (kind) {
            .thermal => try dg.print(w, "        out[{d}] = .{{ .white = base.g{d}a, .coeff = coeff }};\n", .{ k, r.gen }),
            .flicker => try dg.print(w, "        out[{d}] = .{{ .white = 0, .flicker = base.g{d}a, .ef = base.g{d}b, .coeff = coeff }};\n", .{ k, r.gen, r.gen }),
            .table, .table_log => try dg.print(w, "        out[{d}] = .{{ .white = 0, .coeff = coeff }};\n", .{k}),
            .ac_stim => unreachable,
        }
        try dg.print(w, "    }}\n", .{});
    }
    try dg.print(w, "    return out;\n}}\n", .{});

    // Unlike `base.r{d}`, `base.g{d}a`/`b` (an `ac_stim`'s own `mag`/`phase`)
    // is always read below, so the empty-row discard alone still covers it.
    const ac_signs = try dg.arena.alloc(?i2, dg.ac_rows.len);
    for (dg.ac_rows, 0..) |r, i| ac_signs[i] = try rowSign(dg, r);
    try dg.print(w, "\n/// §4.6.3 one phasor per `ac_gens` row.\npub fn acStim(comptime S: type, x: [n_u]f64, model: *const Model, inst: *const Instance, sim: contract.SimState) [ac_gens.len]contract.AcPhasor {{\n    const xs = D.zProbe(S, &x);\n    const base = noiseCore(S, xs, model, inst, sim, {d});\n{s}    {s} out: [ac_gens.len]contract.AcPhasor = undefined;\n", .{ hot_none, if (dg.ac_rows.len == 0) "    _ = base;\n" else "", if (dg.ac_rows.len == 0) "const" else "var" });
    for (dg.ac_rows, 0..) |r, k| {
        try dg.print(w, "    {{\n", .{});
        try genCoeff(dg, w, r, ac_signs[k]);
        try dg.print(w, "        out[{d}] = .{{ .mag = coeff * base.g{d}a, .phase = base.g{d}b }};\n    }}\n", .{ k, r.gen, r.gen });
    }
    try dg.print(w, "    return out;\n}}\n", .{});
}
