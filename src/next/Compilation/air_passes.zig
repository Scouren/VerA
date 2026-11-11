//! The float verdict job (research/airpasses.md T1): `codegen.floatRoots`'
//! and the device's bare rows named and located as the user wrote them —
//! `V(hi,lo)`/`I(hi,lo)` at the first `<+` that opened a contribution row,
//! a parameter at its declaration, a probe by its node — so §4.3.2's
//! diagnostics (W0650 above all) read the old prover's words instead of
//! an empty headline (`unit N —  —`). Split out of `backend.zig` once this
//! grew past a backend job: it only names and locates the pass's inputs.
//! Cites: VAMS-2023 §4.3.2, §5.6.1.3 (a contribution is a float unit).
//!
//! Contents:
//! - `pub fn run(comp: *Compilation) !bool`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Air = @import("air");
const InternPool = @import("intern_pool");
const codegen = @import("codegen");
const Compilation = @import("../Compilation.zig");
const errors = @import("errors.zig");
const Device = Air.Device;

/// The float verdict over codegen's roots (§11.9), each parameter's
/// ranges its box; a §4.3.2 error stops here.
pub fn run(comp: *Compilation) !bool {
    const an = &comp.analysis.?;
    const a = comp.arena();
    const ip = &comp.zcu.intern_pool;
    const device = &an.device;
    const roots = try codegen.floatRoots(a, &an.air, device);
    assert(roots.len == device.contributions.len);
    // Where each instruction's diagnostic points: the expression Sema
    // lowered it from (`Analysis.srcs`'s alloc/arg rule).
    const locs = try a.alloc(vams.Diag.Loc, an.srcs.len);
    for (locs, an.srcs) |*l, s| l.* = if (s.src == .none) .none else errors.instLoc(comp.pp.output(), &comp.units.items[@backingInt(s.file)], s.src);

    try nameRoots(a, roots, device, ip, locs);
    const params = try paramsOf(a, &an.air, device, ip, locs);
    const probe_names = try a.alloc([]const u8, device.nodes.len);
    for (probe_names, 0..) |*n, k| n.* = Device.nodeName(device, ip, @fromBackingInt(@as(u32, @intCast(k))));

    comp.float = try Air.Float.analyze(comp.gpa, an.air, ip, .{
        .params = params,
        .roots = roots,
        .locs = locs,
        .probe_names = probe_names,
        .unknown_bound = comp.config.unknown_bound,
    }, &comp.wip);
    return !comp.wip.failed();
}

// ---- private ----

/// Names and locates each contribution root as the user wrote its first
/// `<+` (`V(hi,lo)`/`I(hi,lo)`, ground spelled `gnd` by `Device.nodeName`):
/// W0650's headline. Asserts every root gets one: a pass input built with
/// no name is the bug class `floatRoots` used to leave (airpasses.md §0).
fn nameRoots(a: Allocator, roots: []Air.Float.Root, device: *const Device, ip: *const InternPool, locs: []const vams.Diag.Loc) Allocator.Error!void {
    assert(roots.len == device.contributions.len);
    const access = device.contributions.items(.access);
    const hi = device.contributions.items(.hi);
    const lo = device.contributions.items(.lo);
    const resist = device.contributions.items(.resist);
    for (roots, 0..) |*r, k| {
        r.name = try std.fmt.allocPrint(a, "{s}({s},{s})", .{
            if (access[k] == .potential) "V" else "I",
            Device.nodeName(device, ip, hi[k]),
            Device.nodeName(device, ip, lo[k]),
        });
        r.loc = locs[@backingInt(resist[k])];
    }
    for (roots) |r| assert(r.name.len != 0);
}

/// Each `device.params` row, named and located at its declaration
/// (`Sema/param.zig`'s `setSrc` calls): one pass over every `arg`
/// instruction maps a row to it, since lowering mints exactly one per row.
fn paramsOf(a: Allocator, air: *const Air, device: *const Device, ip: *const InternPool, locs: []const vams.Diag.Loc) Allocator.Error![]Air.Float.Param {
    const n = device.params.len;
    const arg_of = try a.alloc(u32, n);
    @memset(arg_of, std.math.maxInt(u32));
    const tags = air.instructions.items(.tag);
    const datas = air.instructions.items(.data);
    for (tags, datas, 0..) |tag, data, i| {
        if (tag != .arg) continue;
        const k = data.ty_index.index;
        if (k < n) arg_of[k] = @intCast(i);
    }
    const names = device.params.items(.name);
    const params = try a.alloc(Air.Float.Param, n);
    for (params, 0..) |*p, k| {
        assert(arg_of[k] != std.math.maxInt(u32)); // every row gets its `arg`
        p.* = .{
            .ranges = try floatRanges(a, device.paramRanges(@fromBackingInt(@as(u32, @intCast(k))))),
            .name = ip.stringToSlice(names[k]),
            .loc = locs[arg_of[k]],
        };
    }
    assert(params.len == device.params.len);
    return params;
}

/// A parameter's `Device` ranges as `Float` reads them; a bound that does
/// not fold proves nothing.
fn floatRanges(a: Allocator, ranges: []const Device.Range) Allocator.Error![]const Air.Interval.Range {
    var out: std.ArrayList(Air.Interval.Range) = .empty;
    for (ranges) |r| {
        if (r.strings) continue;
        try out.append(a, .{ .kind = if (r.exclude) .exclude else .from, .lo = r.lo, .hi = r.hi, .lo_inclusive = r.lo_closed, .hi_inclusive = r.hi_closed });
    }
    return out.items;
}
