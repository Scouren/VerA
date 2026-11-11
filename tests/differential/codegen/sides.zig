//! diff-codegen's two sides of one fixture: the old pipeline's device text
//! (`vera.analyze` + `Result.generate`, every unit forced strict) and the new
//! one's (the old preprocessor's text through vams, Sema, `Air.Float` over
//! `codegen.floatRoots`, `codegen.generate` strict and versioned), with the card the oracle
//! draws parameters from.
//! No LRM clause: this checks VerA's rewrite against VerA.
//!
//! Contents:
//! - `pub const Card = struct`, `pub const New = union(enum)`
//! - `pub fn old(gpa: Allocator, arena: Allocator, path: []const u8, source: []const u8, include: []const []const u8) !?[]const u8`
//! - `pub fn picked(rel: []const u8, filter: []const u8) bool`
//! - `pub fn new(gpa: Allocator, arena: Allocator, io: Io, path: []const u8, source: []const u8, include: []const []const u8) !New`

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const sema = @import("sema");
const Air = @import("air");
const InternPool = @import("intern_pool");
const codegen = @import("codegen");
const frontend = @import("frontend");
const diag = @import("diag");
const vera = @import("vera");
const Zcu = sema.Zcu;
const Sema = sema.Sema;
const events = vams.Preprocessor.events;

/// The real parameters a point may move, each near its default inside its
/// §3.4.2 ranges, and the unknown count.
pub const Card = struct {
    names: []const [:0]const u8,
    defaults: []const f64,
    ranges: []const []const Air.Device.Range,
    n_u: u32,
    /// The versioned unit's guard box (every root `.optimized`), null for one
    /// strict body; and what it reads: each card entry's `arg` index and
    /// every `arg`'s default.
    box: ?[]const Air.Float.Guard = null,
    arg_of: []const u32 = &.{},
    args: []const f64 = &.{},
    /// A bit per `Air.Device.Node.Index` row (research/codegen.md T0d): set
    /// where a tainted contribution's resist or react slot reaches that row
    /// (its `hi`, `lo` or flow unknown). Tainted means the slot's value
    /// depends on an op VerA's Jacobian defines by rule rather than as the
    /// finite-difference limit: `ddx`, `vera_nodiff` (`dstop`), an
    /// `integer`<->`real` cast, `$realtobits`/`$bitstoreal`, `%`/`fmod`.
    /// `dyn.zig`'s FD Jacobian check skips exactly these rows, by this
    /// table of ops, never by the fixture's name.
    fd_skip: u64 = 0,
};

/// The new side's outcome.
pub const New = union(enum) {
    /// A stage before codegen refused the source, or lowered no device.
    refused,
    /// Codegen does not spell something yet: why.
    fail: []const u8,
    /// `text` every unit strict; `versioned` the verdict's versioned units,
    /// null when no root is `.optimized` (the same device).
    ok: struct { text: []const u8, versioned: ?[]const u8, card: Card, optimized: u32, roots: u32 },
};

/// Instruction tags VerA's Jacobian defines by rule rather than as the
/// calculus limit a central difference measures: §2.9 `vera_nodiff`
/// (`dstop`), §4.2.1.1/.2 the `integer`<->`real` casts, §4.2.4 `%`/`fmod`.
const rule_jac_tags: std.EnumSet(Air.Inst.Tag) = .initMany(&.{ .dstop, .fi_cast, .if_cast, .fmod, .imod });
/// System-function callees of the same kind: §4.5.6 `ddx` (no further
/// Jacobian lane of its own result) and §9.11 `$realtobits`/`$bitstoreal`
/// (an integer bit pattern, no derivative).
const rule_jac_calls: std.EnumSet(vams.SysFn.Tag) = .initMany(&.{ .ddx, .@"$realtobits", .@"$bitstoreal" });

/// The old device's text with every unit strict, in `arena`; null when the
/// old pipeline refuses the source or its codegen refuses a construct.
pub fn old(gpa: Allocator, arena: Allocator, path: []const u8, source: []const u8, include: []const []const u8) !?[]const u8 {
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    var r = vera.analyze(gpa, source, .{ .file_name = path, .include_dirs = include, .display = .record }, &bag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return null, // else: a refusal before codegen
    };
    defer r.deinit(gpa);
    if (!r.verdict.ok()) return null;
    @memset(@constCast(r.verdict.unit_modes), .strict);
    var d = r.generate(gpa, .{}, null) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return null, // else: codegen refused
    };
    defer d.deinit(gpa);
    if (d.refused) return null;
    return try arena.dupe(u8, d.output.text);
}

/// The new device's text and card, in `arena`.
pub fn new(gpa: Allocator, arena: Allocator, io: Io, path: []const u8, source: []const u8, include: []const []const u8) !New {
    const bag = try arena.create(diag.Bag);
    bag.* = .init(arena);
    const files = try arena.create(frontend.Files);
    files.* = .init(io, arena);
    const pp = frontend.preprocessor.process(arena, source, .{
        .include_dirs = include,
        .file_name = path,
        .std_defs = true,
        .spice_primitives = true,
        .bag = bag,
        .files = files,
    }) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.PreprocessFailed => return .refused,
    };
    const text = try arena.dupeSentinel(u8, pp.text, 0);
    const builtins: u32 = frontend.annex_e.spice_module_count + pp.netlist_modules;
    var tree = try vams.Ast.parse(gpa, text, .{ .keywords = .vams_2023 });
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return .refused;
    // The old preprocessor's directives, as the new AstGen reads them
    // (diff-lower does the same): an `unconnected_drive fixture otherwise
    // lowers different unknowns.
    var vir = try vams.AstGen.generate(gpa, &tree, .{ .directives = try directives(arena, pp.directives) });
    defer vir.deinit(gpa);
    var zcu: Zcu = try .init(gpa);
    defer zcu.deinit();
    var modules: u32 = 0;
    for (vir.decls()) |d| modules += @intFromBool(d.kind == .module);
    _ = try zcu.addFile(path, vir, @min(builtins, modules));
    try Sema.elaborate(&zcu, .{ .roots = .first });
    for (zcu.failed.items(.code)) |c| if (@tagName(c)[0] == 'E') return .refused;
    for (vir.diag.messages()) |m| if (@tagName(vir.diag.message(m).tag.code)[0] == 'E') return .refused;
    if (zcu.instances.len == 0) return .refused;
    var a = (try Sema.analyze(&zcu)) orelse return .refused;
    defer a.deinit(gpa);
    const ip = &zcu.intern_pool;

    // The verdict over codegen's roots, each parameter's ranges its box.
    const roots = try codegen.floatRoots(arena, &a.air, &a.device);
    const fd_skip = try fdSkipMask(arena, &a.air, &a.device, roots);
    const params = try arena.alloc(Air.Float.Param, a.device.params.len);
    for (params, 0..) |*p, k| p.* = .{ .ranges = try floatRanges(arena, a.device.paramRanges(@fromBackingInt(@intCast(k)))) };
    var wip: vams.Diag.Wip = .init(gpa);
    defer wip.deinit();
    var f = try Air.Float.analyze(gpa, a.air, ip, .{ .params = params, .roots = roots }, &wip);
    defer f.deinit(gpa);
    var optimized: u32 = 0;
    for (f.verdict.modes) |m| optimized += @intFromBool(m == .optimized);

    var r = try codegen.generate(gpa, .zig, .{ .air = &a.air, .ip = ip, .device = &a.device, .verdict = &f.verdict }, .{ .strict = true });
    defer r.deinit(gpa);
    const box = try boxOf(arena, &f.verdict);
    var vr: ?codegen.Result = if (box != null) try codegen.generate(gpa, .zig, .{ .air = &a.air, .ip = ip, .device = &a.device, .verdict = &f.verdict }, .{}) else null;
    defer if (vr) |*v| v.deinit(gpa);
    if (vr) |v| if (v == .fail) return .{ .fail = try arena.dupe(u8, v.fail) };
    switch (r) {
        .fail => |why| return .{ .fail = try arena.dupe(u8, why) },
        .ok => |out| {
            var names: std.ArrayList([:0]const u8) = .empty;
            var defaults: std.ArrayList(f64) = .empty;
            var ranges: std.ArrayList([]const Air.Device.Range) = .empty;
            var arg_of: std.ArrayList(u32) = .empty;
            const args = try arena.alloc(f64, a.device.params.len);
            for (args, a.device.params.items(.default)) |*v, def| v.* = switch (if (def == InternPool.Index.undef or def == .none) InternPool.Key{ .float = 0 } else ip.indexToKey(def)) {
                .float => |x| x,
                .int => |i| if (i.storage == .small) @floatFromInt(i.storage.small) else 0,
                else => 0, // else: a string or an array, which no guard reads
            };
            for (a.device.params.items(.name), a.device.params.items(.default), a.device.params.items(.local), 0..) |n, def, local, k| {
                // The card the old device takes: the root's own parameters.
                if (local or std.mem.findScalar(u8, ip.stringToSlice(n), '.') != null) continue;
                if (def == InternPool.Index.undef or def == .none) continue;
                const x = switch (ip.indexToKey(def)) {
                    .float => |x| x,
                    else => continue, // else: an integer, a string: kept at its default
                };
                try names.append(arena, try arena.printSentinel("{f}", .{codegen.zig.Ident{ .name = ip.stringToSlice(n) }}, 0));
                try defaults.append(arena, x);
                try ranges.append(arena, try arena.dupe(Air.Device.Range, a.device.paramRanges(@fromBackingInt(@intCast(k)))));
                try arg_of.append(arena, @intCast(k));
            }
            return .{ .ok = .{
                .text = try arena.dupe(u8, out.text),
                .versioned = if (vr) |v| try arena.dupe(u8, v.ok.text) else null,
                .card = .{ .names = names.items, .defaults = defaults.items, .ranges = ranges.items, .n_u = @intCast(a.device.nodes.len), .box = box, .arg_of = arg_of.items, .args = args, .fd_skip = fd_skip },
                .optimized = optimized,
                .roots = @intCast(f.verdict.modes.len),
            } };
        },
    }
}

/// Whether fixture path `rel` holds one of `filter`'s `|`-separated
/// substrings; an empty filter picks every fixture.
pub fn picked(rel: []const u8, filter: []const u8) bool {
    if (filter.len == 0) return true;
    var it = std.mem.splitScalar(u8, filter, '|');
    while (it.next()) |part| if (part.len != 0 and std.mem.find(u8, rel, part) != null) return true;
    return false;
}

// ---- private ----

/// `src`, the old preprocessor's §10.2/§10.3 and IEEE 1364 §19 directive
/// events, in the new `events.Directives` shape (each region's value by
/// name).
fn directives(arena: Allocator, src: anytype) !events.Directives {
    const disciplines = try arena.alloc(events.DefaultDiscipline, src.disciplines.len);
    for (src.disciplines, disciplines) |e, *d| d.* = .{
        .at = e.at,
        .qualifier = if (e.qualifier) |q| std.meta.stringToEnum(events.Qualifier, @tagName(q)).? else null,
        .discipline = e.discipline,
    };
    return .{
        .disciplines = disciplines,
        .transitions = try regions(?f64, arena, src.transitions),
        .timescales = try regions(?events.Timescale, arena, src.timescales),
        .nettypes = try regions(events.NetType, arena, src.nettypes),
        .cells = try regions(bool, arena, src.cells),
        .drives = try regions(events.Drive, arena, src.drives),
    };
}

/// One list of old regions as `events.Region(T)`: an enum by its tag's
/// name, a timescale field by field, any other value as it is.
fn regions(comptime T: type, arena: Allocator, src: anytype) ![]const events.Region(T) {
    const out = try arena.alloc(events.Region(T), src.len);
    for (src, out) |e, *r| r.* = .{
        .at = e.at,
        .value = switch (@typeInfo(T)) {
            .@"enum" => std.meta.stringToEnum(T, @tagName(e.value)).?,
            .optional => |o| if (o.child == f64) e.value else if (e.value) |t| events.Timescale{ .unit = t.unit, .precision = t.precision } else null,
            else => e.value, // else: a bool
        },
    };
    return out;
}

/// Returns a bit mask over `device.nodes.len` rows (`Air.Device.Node.Index`
/// backing ints; `Liveness.unknowns_max`-sized, so `u64` holds every
/// device): a contribution whose resist or react slot's value is tainted
/// (`taintBody`) by `rule_jac_tags`/`rule_jac_calls` sets its `hi`, `lo` and
/// flow rows. `dyn.zig`'s FD Jacobian check skips exactly these rows
/// (research/codegen.md T0d): a table of ops, not a fixture's name, so it
/// also exempts any other fixture built the same way, and nothing else.
fn fdSkipMask(arena: Allocator, air: *const Air, device: *const Air.Device, roots: []const Air.Float.Root) Allocator.Error!u64 {
    const taint = try arena.alloc(bool, air.instructions.len);
    @memset(taint, false);
    taintBody(air, taint, air.mainBody(), 0);
    var mask: u64 = 0;
    const hi = device.contributions.items(.hi);
    const lo = device.contributions.items(.lo);
    const flow = device.contributions.items(.flow);
    assert(roots.len == hi.len);
    for (roots, hi, lo, flow) |root, h, l, fl| {
        const tainted = for (root.refs) |ref| {
            const i = ref.toIndex() orelse continue;
            if (taintOf(taint, air.instructions.items(.data)[@backingInt(i)].bin_op.rhs)) break true;
        } else false;
        if (!tainted) continue;
        for ([_]Air.Device.Node.Index{ h, l, fl }) |node| {
            if (node == .ground or node == .none) continue;
            mask |= @as(u64, 1) << @intCast(@backingInt(node));
        }
    }
    return mask;
}

/// Whether `ref` resolves to a tainted instruction; false for `.none` and
/// for an interned constant (`Air.Inst.Ref.toIndex`'s ref-bit case).
fn taintOf(taint: []const bool, ref: Air.Inst.Ref) bool {
    const i = ref.toIndex() orelse return false;
    return taint[@backingInt(i)];
}

/// Fills `taint`'s entries for every instruction of `insts`, recursing into
/// a nested `block`/`loop`/`cond_br` body at `depth + 1`. Asserts the same
/// nesting cap the interpreter's own walk holds to (`Air.nesting_max`,
/// `src/Air/interp.zig`'s `Run.body`, whose per-tag dispatch this mirrors).
/// A `block`/`loop`'s own slot starts `false` (`@memset`) and is set by a
/// `br` that targets it, reached during the recursive call above; the
/// shared `taint[i] = taint[i] or own` below an `or` with that, never an
/// overwrite.
fn taintBody(air: *const Air, taint: []bool, insts: []const Air.Inst.Index, depth: u32) void {
    assert(depth <= Air.nesting_max);
    for (insts) |inst| {
        const i = @backingInt(inst);
        const tag = air.instructions.items(.tag)[i];
        const data = air.instructions.items(.data)[i];
        var own = rule_jac_tags.contains(tag);
        switch (tag) {
            .block, .loop => {
                const x = air.extraData(Air.Block, data.ty_pl.payload);
                taintBody(air, taint, air.body(x.end, x.data.body_len), depth + 1);
            },
            .cond_br => {
                const x = air.extraData(Air.CondBr, data.pl_op.payload);
                taintBody(air, taint, air.body(x.end, x.data.then_body_len), depth + 1);
                taintBody(air, taint, air.body(x.end + x.data.then_body_len, x.data.else_body_len), depth + 1);
                own = own or taintOf(taint, data.pl_op.operand);
            },
            .br => {
                if (data.br.operand != .none and taintOf(taint, data.br.operand)) taint[@backingInt(data.br.block_inst)] = true;
                continue;
            },
            .assign => {
                taint[@backingInt(data.bin_op.lhs.toIndex().?)] = taintOf(taint, data.bin_op.rhs);
                continue;
            },
            .call => {
                const x = air.extraData(Air.Call, data.ty_pl.payload);
                const refs: []const Air.Inst.Ref = @ptrCast(air.extra[x.end..][0..x.data.args_len]);
                for (refs) |a| own = own or taintOf(taint, a);
                const max_tag = std.math.maxInt(@typeInfo(vams.SysFn.Tag).@"enum".tag_type);
                if (x.data.callee <= max_tag and rule_jac_calls.contains(@fromBackingInt(@intCast(x.data.callee)))) own = true;
            },
            .select, .store => {
                const bin = air.extraData(Air.Bin, data.pl_op.payload).data;
                own = own or taintOf(taint, data.pl_op.operand) or taintOf(taint, bin.lhs) or taintOf(taint, bin.rhs);
            },
            else => switch (Air.tag_info.getPtrConst(tag).class) { // else: every other tag is plain arithmetic, a comparison, `load`, `fload`/`iload`, `anew`, `arg`, `probe` or `ret`; `tag_info`'s class says which `Data` field (if any) is its operand
                .un_op => own = own or taintOf(taint, data.un_op),
                .bin_op => own = own or taintOf(taint, data.bin_op.lhs) or taintOf(taint, data.bin_op.rhs),
                // `pl_op` here is unreachable: `select`/`store`/`cond_br` (the
                // only `pl_op` tags) are handled above. `ty_pl`/`ty`/`ty_index`/
                // `br`/`repeat` read no Ref worth tainting (a fresh array, a
                // leaf, or a control tag with no value).
                .pl_op, .ty_pl, .ty, .ty_index, .br, .repeat => {},
            },
        }
        taint[i] = taint[i] or own;
    }
}

/// The box the device's versioned unit checks, read off the verdict as the
/// spec states it (§11.9: every root `.optimized`, the union of their
/// boxes), so a codegen that checks a different box disagrees here.
fn boxOf(arena: Allocator, v: *const Air.Float.Verdict) !?[]const Air.Float.Guard {
    if (v.modes.len == 0) return null;
    var out: std.ArrayList(Air.Float.Guard) = .empty;
    for (v.modes, 0..) |m, r| {
        if (m == .strict) return null;
        try out.appendSlice(arena, v.box(r));
    }
    return out.items;
}

/// A parameter's `Device` ranges as `Float` reads them; a bound that does
/// not fold proves nothing.
fn floatRanges(arena: Allocator, ranges: []const Air.Device.Range) ![]const Air.Interval.Range {
    var out: std.ArrayList(Air.Interval.Range) = .empty;
    for (ranges) |r| {
        if (r.strings) continue;
        try out.append(arena, .{
            .kind = if (r.exclude) .exclude else .from,
            .lo = r.lo,
            .hi = r.hi,
            .lo_inclusive = r.lo_closed,
            .hi_inclusive = r.hi_closed,
        });
    }
    return out.items;
}
