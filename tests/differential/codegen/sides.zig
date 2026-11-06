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
//! - `pub fn new(gpa: Allocator, arena: Allocator, io: Io, path: []const u8, source: []const u8, include: []const []const u8) !New`

const std = @import("std");
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
    var vir = try vams.AstGen.generate(gpa, &tree, .{});
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
                .card = .{ .names = names.items, .defaults = defaults.items, .ranges = ranges.items, .n_u = @intCast(a.device.nodes.len), .box = box, .arg_of = arg_of.items, .args = args },
                .optimized = optimized,
                .roots = @intCast(f.verdict.modes.len),
            } };
        },
    }
}

// ---- private ----

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
