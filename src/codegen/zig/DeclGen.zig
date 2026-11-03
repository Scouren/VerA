//! What lives for the whole device (Zig's `codegen/c.zig` `DeclGen`): the
//! inputs (`Air`, the pool, `Air.Device`, the float verdict, `Liveness`)
//! and the file-scope declarations of the emitted device, in the order a
//! reader meets them: the imports, the unknowns (`U`), the card (`Model`),
//! the instance, the lane tables, the charge sites, `core` (the one body,
//! `Function`), its versioned entry (§11.9), and the entry points `eval`
//! and `q` over it. The device imports `std_kernels` for every kernel; no
//! kernel text is written. `comptime contract.validate(Self)` closes it.
//! Cites: VAMS-2023 §1.3.1, §3.4, §3.4.2, §4.4, §5.6, §5.6.1.2, §9.10.
//!
//! Contents:
//! - fields `gpa`, `arena`, `air`, `ip`, `device`, `verdict`, `live`, `options`, `failure`
//! - `pub const Options = struct { strict }`, `pub const Error = error{ OutOfMemory, CodegenFail }`
//! - `pub fn genFile(dg: *DeclGen, w: *std.Io.Writer) Error!void`
//! - `pub fn genReturn(dg: *DeclGen, f: *Function) Error!void`
//! - `pub fn unconditional(dg: *const DeclGen, slot: Air.Inst.Index) bool`
//! - `pub fn paramName(dg: *const DeclGen, k: u32) []const u8`
//! - `pub fn fail(dg: *DeclGen, comptime fmt: []const u8, args: anytype) Error`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Air = @import("air");
const InternPool = @import("intern_pool");
const contract = @import("contract");
const Function = @import("Function.zig");
const Liveness = @import("Liveness.zig");
const stamps = @import("stamps.zig");
const Device = Air.Device;
const Real = Function.Real;

gpa: Allocator,
/// Scratch for one `generate`.
arena: Allocator,
air: *const Air,
ip: *const InternPool,
device: *const Device,
/// Per contribution: its mode and guard box; null rates every root `.strict`.
verdict: ?*const Air.Float.Verdict,
live: Liveness,
options: Options,
/// Why `generate` failed, once it has (`fail`).
failure: ?[]const u8 = null,

/// The choices the caller makes beyond the inputs.
pub const Options = struct {
    /// Every unit strict, ignoring the verdict: the oracle's bit-identity mode.
    strict: bool = false,
};

/// `CodegenFail`: the body holds something this backend does not spell;
/// `failure` says what.
pub const Error = error{ OutOfMemory, CodegenFail };

/// `zIn`, the entry check of one input: inside `[lo, hi]` (each end open or
/// closed, 0 excluded under `nonzero`), so NaN fails it; every point of a
/// batch must pass.
const zin =
    \\
    \\inline fn zIn(v: anytype, comptime lo: f64, comptime lo_open: bool, comptime hi: f64, comptime hi_open: bool, comptime nonzero: bool) bool {
    \\    const T = @TypeOf(v);
    \\    const vec = @typeInfo(T) == .vector;
    \\    const l: T = if (vec) @splat(lo) else lo;
    \\    const h: T = if (vec) @splat(hi) else hi;
    \\    const z: T = if (vec) @splat(0.0) else 0.0;
    \\    const a = if (lo_open) v > l else v >= l;
    \\    const b = if (hi_open) v < h else v <= h;
    \\    if (vec) return @reduce(.And, a) and @reduce(.And, b) and (!nonzero or @reduce(.And, v != z));
    \\    return a and b and (!nonzero or v != z);
    \\}
    \\
;

const header =
    \\//! A VerA device (codegen's Zig backend, src/codegen/zig.zig): the
    \\//! contract's entry points over one `core`; every kernel is `std_kernels`.
    \\
    \\const std = @import("std");
    \\const contract = @import("contract");
    \\const K = @import("std_kernels");
    \\const M = K.math;
    \\const F = K.Family(n_u, deriv_reads);
    \\const D = K.family.Device(Self);
    \\const Self = @This();
    \\const n_u = contract.nU(Self);
    \\const InstancePtr = contract.InstancePtr(Self);
    \\
    \\pub const vera_version = "
++ contract.vera_version ++
    \\";
    \\
;

const DeclGen = @This();

/// Writes the whole device to `w`.
pub fn genFile(dg: *DeclGen, w: *std.Io.Writer) Error!void {
    const d = dg.device;
    if (d.nodes.len == 0) return dg.fail("a device with no unknowns", .{});
    if (d.held.len != 0) return dg.fail("a §5.10 held variable", .{});
    if (d.limit_slots.len != 0) return dg.fail("a §9.17.3 `$limit`", .{});
    const p = try stamps.plan(dg);

    // The body first: its uses decide `core`'s signature.
    var body: std.Io.Writer.Allocating = .init(dg.arena);
    var f: Function = .{ .dg = dg, .w = &body.writer };
    try f.genBody(dg.air.mainBody());

    try dg.print(w, "{s}", .{header});
    try dg.genUnknowns(w);
    try dg.genModel(w);
    try dg.genTables(w, p);
    try dg.genCore(w, f.uses, body.written());
    try dg.genEntries(w, p);
    try dg.print(w, "\ncomptime {{\n    contract.validate(Self);\n}}\n", .{});
}

/// Writes `core`'s `return`: each contribution's resistive sum and each
/// charge site's charge, read from their slots.
pub fn genReturn(dg: *DeclGen, f: *Function) Error!void {
    const d = dg.device;
    try dg.print(f.w, "return .{{", .{});
    for (d.contributions.items(.resist), 0..) |slot, k| if (dg.live.assigned[@backingInt(slot)]) try dg.print(f.w, " .r{d} = s{d},", .{ k, @backingInt(slot) });
    for (d.charge_sites.items(.slot), 0..) |slot, k| try dg.print(f.w, " .c{d} = s{d},", .{ k, @backingInt(slot) });
    try dg.print(f.w, " }};", .{});
}

/// Whether some `assign` to `slot` sits in the main body itself, not under
/// a condition or a loop: then it runs at every evaluation.
pub fn unconditional(dg: *const DeclGen, slot: Air.Inst.Index) bool {
    const tags = dg.air.instructions.items(.tag);
    const datas = dg.air.instructions.items(.data);
    for (dg.air.mainBody()) |i| {
        if (tags[@backingInt(i)] == .assign and datas[@backingInt(i)].bin_op.lhs.toIndex() == slot) return true;
    }
    return false;
}

/// Parameter `k`'s name: its `Model` field.
pub fn paramName(dg: *const DeclGen, k: u32) []const u8 {
    assert(k < dg.device.params.len);
    return dg.ip.stringToSlice(dg.device.params.items(.name)[k]);
}

/// Records why the device cannot be written and returns `error.CodegenFail`.
pub fn fail(dg: *DeclGen, comptime fmt: []const u8, args: anytype) Error {
    assert(dg.failure == null);
    dg.failure = try std.fmt.allocPrint(dg.arena, fmt, args);
    return error.CodegenFail;
}

// ---- private ----

fn genUnknowns(dg: *DeclGen, w: *std.Io.Writer) Error!void {
    const d = dg.device;
    try dg.print(w, "\n/// §1.3.1 the unknowns, ports first.\npub const U = enum(u{d}) {{\n", .{if (d.nodes.len <= 256) @as(u32, 8) else 32});
    for (d.nodes.items(.name)) |n| try dg.print(w, "    {f},\n", .{std.zig.fmtId(dg.ip.stringToSlice(n))});
    try dg.print(w, "}};\npub const num_ports: usize = {d};\n", .{d.num_ports});
}

fn genModel(dg: *DeclGen, w: *std.Io.Writer) Error!void {
    const d = dg.device;
    try dg.print(w, "\n/// §3.4 the card.\npub const Model = struct {{\n", .{});
    for (d.params.items(.name), d.params.items(.default)) |n, def| {
        if (def == InternPool.Index.undef or def == .none) return dg.fail("parameter `{s}`'s default does not fold", .{dg.ip.stringToSlice(n)});
        try dg.print(w, "    {f}: ", .{std.zig.fmtId(dg.ip.stringToSlice(n))});
        switch (dg.ip.indexToKey(def)) {
            .float => |x| try dg.print(w, "f64 = {f},\n", .{Real{ .x = x }}),
            .int => |i| switch (i.storage) {
                .small => |s| try dg.print(w, "i64 = {d},\n", .{s}),
                .big => return dg.fail("parameter `{s}` wider than 64 bits", .{dg.ip.stringToSlice(n)}),
            },
            // else: a string, an array or an aggregate
            else => return dg.fail("parameter `{s}` is not a number", .{dg.ip.stringToSlice(n)}),
        }
    }
    try dg.print(w, "    temperature__: f64 = 300.15,\n}};\n", .{});
    try dg.print(w, "\n/// §6.3.6 the instance.\npub const Instance = struct {{\n    mfactor: f64 = 1.0,\n}};\n", .{});
}

/// The lane tables (`deriv_reads`, `jac_pattern`) and the §5.6.1.2 charge
/// sites (`n_q`, `q_stamps`, `q_site_pattern`).
fn genTables(dg: *DeclGen, w: *std.Io.Writer, p: stamps.Plan) Error!void {
    const d = dg.device;
    var all: Liveness.Mask = 0;
    for (p.pattern) |m| all |= m;
    for (d.charge_sites.items(.slot)) |slot| all |= dg.live.masks[@backingInt(slot)];
    try dg.print(w, "\n/// The unknowns whose derivative lane the device reads.\npub const deriv_reads: u64 = 0x{x};\n", .{all});
    try dg.print(w, "/// §5.6 bit `c` of row `r`: d eval[r] / d x[c] may be nonzero.\npub const jac_pattern = [n_u]u64{{", .{});
    for (p.pattern) |m| try dg.print(w, " 0x{x},", .{m});
    try dg.print(w, " }};\n", .{});

    try dg.print(w, "/// §5.6.1.2 the charge sites `q` returns.\npub const n_q: usize = {d};\n", .{d.charge_sites.len});
    try dg.print(w, "pub const q_site_pattern = [n_q]u64{{", .{});
    for (d.charge_sites.items(.slot)) |slot| try dg.print(w, " 0x{x},", .{dg.live.masks[@backingInt(slot)]});
    try dg.print(w, " }};\n", .{});
    try dg.print(w, "pub const q_stamps = [_]contract.QStamp(U){{\n", .{});
    for (p.q) |s| try dg.print(w, "    .{{ .site = {d}, .row = .{f}, .sign = {f} }},\n", .{ s.site, std.zig.fmtId(dg.nodeName(s.row)), Real{ .x = s.sign } });
    try dg.print(w, "}};\n", .{});
}

/// `Core(S)`, `core` and its entry `run`: a versioned unit when the verdict
/// rates every root `.optimized` (§11.9: the box checked, then the
/// fast-math body, else the strict body).
fn genCore(dg: *DeclGen, w: *std.Io.Writer, uses: Function.Uses, body: []const u8) Error!void {
    const d = dg.device;
    var fields = d.charge_sites.len;
    for (d.contributions.items(.resist)) |slot| fields += @intFromBool(dg.live.assigned[@backingInt(slot)]);
    try dg.print(w, "\nfn Core(comptime S: type) type {{\n    {s}return struct {{", .{if (fields == 0) "_ = S;\n    " else ""});
    for (d.contributions.items(.resist), 0..) |slot, k| if (dg.live.assigned[@backingInt(slot)]) try dg.print(w, " r{d}: F.zOf(S, 0x{x}),", .{ k, dg.live.masks[@backingInt(slot)] });
    for (d.charge_sites.items(.slot), 0..) |slot, k| try dg.print(w, " c{d}: F.zOf(S, 0x{x}),", .{ k, dg.live.masks[@backingInt(slot)] });
    try dg.print(w, " }};\n}}\n", .{});
    try dg.print(w, "\n/// The whole analog body, once per evaluation.\nfn core(comptime S: type, comptime mode: std.builtin.FloatMode, {s}: D.zX(S), {s}: *const Model, {s}: InstancePtr, {s}: contract.SimState) Core(S) {{\n    @setFloatMode(mode);{s}\n}}\n", .{
        if (uses.x) "x" else "_",
        if (uses.model) "model" else "_",
        if (uses.inst) "inst" else "_",
        if (uses.sim) "sim" else "_",
        body,
    });
    const guards_opt = try dg.box();
    try dg.print(w, "\nfn run(comptime S: type, x: *const [n_u]S.V, xs: D.zX(S), model: *const Model, inst: InstancePtr, sim: contract.SimState) Core(S) {{\n{s}", .{if (guards_opt == null) "    _ = x;\n" else ""});
    if (guards_opt) |guards| {
        try dg.print(w, "    if (", .{});
        if (guards.len == 0) try dg.print(w, "true", .{});
        for (guards, 0..) |g, k| {
            if (k != 0) try dg.print(w, " and ", .{});
            try dg.print(w, "zIn(", .{});
            switch (g.leaf) {
                .probe => try dg.print(w, "x[{d}]", .{g.index}),
                .arg => {
                    const name = std.zig.fmtId(dg.paramName(g.index));
                    if (d.params.items(.ty)[g.index] == .integer) try dg.print(w, "@as(f64, @floatFromInt(model.{f}))", .{name}) else try dg.print(w, "model.{f}", .{name});
                },
            }
            try dg.print(w, ", {f}, {any}, {f}, {any}, {any})", .{ Real{ .x = g.iv.lo }, g.iv.lo_open, Real{ .x = g.iv.hi }, g.iv.hi_open, g.iv.nonzero });
        }
        try dg.print(w, ") return @call(.always_inline, core, .{{ S, .optimized, xs, model, inst, sim }});\n", .{});
    }
    try dg.print(w, "    return @call(.always_inline, core, .{{ S, .strict, xs, model, inst, sim }});\n}}\n", .{});
    if (guards_opt != null) try dg.print(w, "{s}", .{zin});
}

/// The guard box of the versioned unit, or null for one strict body: every
/// root's box when each is `.optimized`, since `core` is shared and
/// `.strict` absorbs (`Float.Mode.strictest`).
// ponytail: one box for the whole core; per-root bodies (the old
// `plan/jobs.zig` slicing) let an `.optimized` root run fast beside a
// `.strict` one.
fn box(dg: *DeclGen) Error!?[]const Air.Float.Guard {
    if (dg.options.strict) return null;
    const v = dg.verdict orelse return null;
    if (v.modes.len == 0) return null;
    var guards: std.ArrayList(Air.Float.Guard) = .empty;
    for (v.modes, 0..) |mode, r| {
        if (mode == .strict) return null;
        try guards.appendSlice(dg.arena, v.box(r));
    }
    return guards.items;
}

/// `eval` and `q`, each over one `run`.
fn genEntries(dg: *DeclGen, w: *std.Io.Writer, p: stamps.Plan) Error!void {
    const d = dg.device;
    try dg.print(w, "\n/// §5.6 the resistive residual: KCL at every unknown.\npub fn eval(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) contract.Rows(Self, S) {{\n", .{});
    try dg.print(w, "    const xs = D.zProbe(S, x);\n    const m = run(S, x, xs, model, inst, sim);\n    var res = D.zRowsZero(S);\n    _ = .{{ &m, &res }};\n", .{});
    for (p.stamps) |s| {
        try dg.print(w, "    res[{d}] = D.zRow(S, .{f}, ", .{ s.row, std.zig.fmtId(dg.nodeName(s.row)) });
        if (s.op != .set) try dg.print(w, "res[{d}].{t}(", .{ s.row, s.op });
        switch (s.term) {
            .resist => |k| try dg.print(w, "m.r{d}", .{k}),
            .x => |u| try dg.print(w, "xs[{d}]", .{u}),
            .branch => |b| {
                try dg.voltage(w, b.hi);
                try dg.print(w, ".sub(", .{});
                try dg.voltage(w, b.lo);
                try dg.print(w, ")", .{});
                if (b.k != std.math.maxInt(u32)) {
                    if (dg.live.assigned[@backingInt(d.contributions.items(.resist)[b.k])]) try dg.print(w, ".sub(m.r{d})", .{b.k}) else try dg.print(w, ".sub(S.con(0.0))", .{});
                }
            },
            .port => |pp| try dg.print(w, "xs[{d}].sub(res[{d}])", .{ pp.u, pp.p }),
        }
        try dg.print(w, "{s});\n", .{if (s.op != .set) ")" else ""});
    }
    try dg.print(w, "    return res;\n}}\n", .{});
    try dg.print(w, "\n/// §5.6.1.2 the charges, one per site.\npub fn q(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) contract.Sites(Self, S) {{\n", .{});
    if (d.charge_sites.len == 0) {
        try dg.print(w, "    _ = .{{ x, model, inst, sim }};\n    return .{{}};\n}}\n", .{});
        return;
    }
    try dg.print(w, "    const m = run(S, x, D.zProbe(S, x), model, inst, sim);\n    return .{{", .{});
    for (0..d.charge_sites.len) |k| try dg.print(w, " F.zTo(S, contract.siteMask(Self, {d}), m.c{d}),", .{ k, k });
    try dg.print(w, " }};\n}}\n", .{});
}

/// `V(u)`: the unknown's family value, or ground's 0.
fn voltage(dg: *DeclGen, w: *std.Io.Writer, u: u32) Error!void {
    if (u == @backingInt(Device.Node.Index.ground)) return dg.print(w, "S.con(0.0)", .{});
    try dg.print(w, "xs[{d}]", .{u});
}

fn nodeName(dg: *const DeclGen, r: u32) []const u8 {
    return dg.ip.stringToSlice(dg.device.nodes.items(.name)[r]);
}

fn print(dg: *DeclGen, w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) Error!void {
    _ = dg;
    w.print(fmt, args) catch return error.OutOfMemory;
}
