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
const Ident = @import("Ident.zig");
const SysFn = @import("vams").SysFn;
const stamps = @import("stamps.zig");
const state = @import("state.zig");
const calls = @import("calls.zig");
const say = @import("say.zig");
const status = @import("status.zig");
const ops = @import("ops.zig");
const noise = @import("noise.zig");
const array = @import("array.zig");
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
/// Per parameter, its §9.19 `$param_given` bit in `Model.given__`, or
/// `no_bit`: every parameter the body asks about or `derive` fills.
given_bit: []u32 = &.{},
/// Every unknown's source spelling, `U`'s order: `nodes`, then the branch
/// currents codegen mints (`stamps.unknowns`).
u_names: []const []const u8 = &.{},
/// Per contribution: its branch-current unknown, or `none` for a flow row.
branch_u: []u32 = &.{},
/// Bit k: the body reads `calls.host_params[k]` (a `Model` field).
host_params: u8 = 0,
/// §9.15 the body reads the host's Table 9-28 strings (`strings.zig`).
host_strings: bool = false,
/// Per instruction: an `alloc`'s `Instance` field when §5.10 holds it (a
/// held array's on its first slot only: one `[n]` field).
held_field: []?[]const u8 = &.{},
/// Per instruction: the §3.2.2 array an `alloc` is an element of, and how
/// `Function` writes it (one indexed read or write per chain, `array.zig`).
group: []array.Group = &.{},
fuse: []array.Fuse = &.{},
fused: []const array.Fused = &.{},
/// §9.4 the display tasks `say` records (`say.plan`), and the liveness
/// of its body.
say_sites: []const say.Site = &.{},
say_live: Liveness = undefined,
/// §4.6.4/§4.6.3 the noise generators and `ac_stim` placed on a branch
/// (`noise.plan`), split by kind; and the liveness of `noise.genBody`'s
/// second body (roots: every `Device.noise` call and assigned resist
/// slot).
noise_rows: []const noise.Row = &.{},
ac_rows: []const noise.Row = &.{},
noise_live: Liveness = undefined,
/// §4.5.14 the lanes a `ddx` reads (`calls.zig`), in `core` or `say`.
ddx_reads: Liveness.Mask = 0,
/// Per §9.21.1 snapshot site (a `$table_model` call's `site - 1`): its
/// sample count, the length of `Instance.table_<k>` (`state.plan`).
table_len: []u32 = &.{},
/// §4.5 the operator call sites (`ops.plan`).
op_sites: []const ops.Site = &.{},
/// §9.7.3 the `$fatal`/`$error` status sites (`status.plan`).
status_sites: []const status.Site = &.{},

/// A parameter with no `given__` bit.
pub const no_bit: u32 = std.math.maxInt(u32);

/// The choices the caller makes beyond the inputs.
pub const Options = struct {
    /// Every unit strict, ignoring the verdict: the oracle's bit-identity mode.
    strict: bool = false,
};

/// `CodegenFail`: the body holds something this backend does not spell;
/// `failure` says what.
pub const Error = error{ OutOfMemory, CodegenFail };

/// `fast`, a versioned unit's fast body: `core` under `.optimized` on the
/// family's `Fast` twin (the contract's optional trait), whose primitives
/// carry the fast flags, each field brought back by `fromFast`; on `S`
/// itself for a family without it. `@setFloatMode` reaches only the
/// operators of its own function body, so the mode lives in the family
/// whose methods hold the arithmetic. A `Core(S)` field is the family's own
/// value type (`F.zOf`, named by its `mask` decl) when it needs `fromFast`;
/// a plain field (`st__`, `sa__`, an operator's own scalar) does not depend
/// on `S` and is the same type on both twins, so it is just copied. A held
/// array's field is mapped element by element.
const fast =
    \\
    \\inline fn fast(comptime S: type, x: *const [n_u]S.V, xs: D.zX(S), model: *const Model, inst: InstancePtr, sim: contract.SimState) Core(S) {
    \\    if (comptime !@hasDecl(S, "Fast")) return @call(.always_inline, core, .{ S, .optimized, xs, model, inst, sim });
    \\    const f = @call(.always_inline, core, .{ S.Fast, .optimized, D.zProbe(S.Fast, x), model, inst, sim });
    \\    const info = @typeInfo(Core(S)).@"struct";
    \\    var out: Core(S) = undefined;
    \\    inline for (info.field_names, info.field_types) |name, T| @field(out, name) = switch (@typeInfo(T)) {
    \\        .@"struct" => if (@hasDecl(T, "mask")) S.fromFast(@field(f, name)) else @field(f, name),
    \\        .array => |a| if (@typeInfo(a.child) == .@"struct" and @hasDecl(a.child, "mask")) blk: {
    \\            var o: T = undefined;
    \\            for (&o, @field(f, name)) |*e, v| e.* = S.fromFast(v);
    \\            break :blk o;
    \\        } else @field(f, name),
    \\        else => @field(f, name),
    \\    };
    \\    return out;
    \\}
    \\
;

/// `zIn`, the entry check of one input: 1 inside `[lo, hi]` (each end open
/// or closed, 0 excluded under `nonzero`), so NaN fails it; every point of a
/// batch must pass. A bit, so the guards `&` together into one branch
/// (`bench-fast`: eleven short-circuit `and`s doubled a MOSFET's eval).
const zin =
    \\
    \\inline fn zIn(v: anytype, comptime lo: f64, comptime lo_open: bool, comptime hi: f64, comptime hi_open: bool, comptime nonzero: bool) u1 {
    \\    const T = @TypeOf(v);
    \\    const vec = @typeInfo(T) == .vector;
    \\    const l: T = if (vec) @splat(lo) else lo;
    \\    const h: T = if (vec) @splat(hi) else hi;
    \\    const z: T = if (vec) @splat(0.0) else 0.0;
    \\    const a = if (lo_open) v > l else v >= l;
    \\    const b = if (hi_open) v < h else v <= h;
    \\    if (vec) return @intFromBool(@reduce(.And, a)) & @intFromBool(@reduce(.And, b)) & @intFromBool(!nonzero or @reduce(.And, v != z));
    \\    return @intFromBool(a) & @intFromBool(b) & @intFromBool(!nonzero or v != z);
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
    try stamps.unknowns(dg);
    const p = try stamps.plan(dg);
    try dg.givenBits();
    try array.plan(dg);
    try state.plan(dg);
    try ops.plan(dg);
    try status.plan(dg);

    // The body first: its uses decide `core`'s signature.
    var body: std.Io.Writer.Allocating = .init(dg.arena);
    var f: Function = .{ .dg = dg, .w = &body.writer };
    try f.genBody(dg.air.mainBody());
    try say.plan(dg);
    // `say`'s body before the tables: its `ddx` lanes join `deriv_reads`.
    const say_text = try say.genBody(dg);
    try noise.plan(dg);
    const noise_text = try noise.genBody(dg);

    try dg.print(w, "{s}", .{header});
    try dg.genUnknowns(w);
    try dg.genModel(w);
    try dg.genTables(w, p);
    try dg.genCore(w, f.uses, body.written());
    try dg.genEntries(w, p);
    try state.genEntries(dg, w);
    try ops.genBreakpoints(dg, w);
    try status.genEntries(dg, w);
    try status.genSetupInstance(dg, w);
    try say.genEntries(dg, w, say_text);
    try noise.genTables(dg, w);
    try noise.genEntries(dg, w, noise_text);
    try dg.print(w, "\ncomptime {{\n    contract.validate(Self);\n}}\n", .{});
}

/// Writes `core`'s `return`: each contribution's resistive sum and each
/// charge site's charge, read from their slots.
pub fn genReturn(dg: *DeclGen, f: *Function) Error!void {
    const d = dg.device;
    if (f.phase == .say) return dg.print(f.w, "return;", .{});
    if (f.phase == .noise) return noise.genReturn(dg, f);
    try dg.print(f.w, "return .{{", .{});
    for (d.contributions.items(.resist), 0..) |slot, k| if (dg.live.assigned[@backingInt(slot)]) try dg.print(f.w, " .r{d} = s{d},", .{ k, @backingInt(slot) });
    for (d.charge_sites.items(.slot), 0..) |slot, k| try dg.print(f.w, " .c{d} = s{d},", .{ k, @backingInt(slot) });
    for (dg.held_field, 0..) |h, i| if (h != null) try dg.print(f.w, " .h{d} = s{d},", .{ i, i });
    for (d.limit_slots.items(.slot), 0..) |slot, k| try dg.print(f.w, " .l{d} = s{d},", .{ k, @backingInt(slot) });
    try ops.genReturn(dg, f.w);
    try status.genReturn(dg, f.w);
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
    try dg.print(w, "\n/// §1.3.1 the unknowns, ports first, then the branch currents codegen mints.\npub const U = enum(u{d}) {{\n", .{if (dg.u_names.len <= 256) @as(u32, 8) else 32});
    for (dg.u_names) |n| try dg.print(w, "    {f},\n", .{Ident{ .name = n }});
    // §6.2 a module with no ports or nets: Zig spells the empty `U` `_`.
    if (dg.u_names.len == 0) try dg.print(w, "    _,\n", .{});
    try dg.print(w, "}};\npub const num_ports: usize = {d};\n", .{d.num_ports});
}

fn genModel(dg: *DeclGen, w: *std.Io.Writer) Error!void {
    const d = dg.device;
    try dg.print(w, "\n/// §3.4 the card.\npub const Model = struct {{\n", .{});
    for (d.params.items(.name), d.params.items(.default), d.params.items(.derive), d.params.items(.ty)) |n, def, der, ty| {
        if ((def == InternPool.Index.undef or def == .none) and der != .none) {
            // `derive` computes it from the card before any reader.
            try dg.print(w, "    {f}: {s},\n", .{
                Ident{ .name = dg.ip.stringToSlice(n) },
                switch (ty) {
                    .integer => "i64 = 0",
                    .string => "[]const u8 = \"\"",
                    else => "f64 = 0", // else: a real, or one typed by its default
                },
            });
            continue;
        }
        if (def == InternPool.Index.undef or def == .none) return dg.fail("parameter `{s}`'s default does not fold", .{dg.ip.stringToSlice(n)});
        try dg.print(w, "    {f}: ", .{Ident{ .name = dg.ip.stringToSlice(n) }});
        switch (dg.ip.indexToKey(def)) {
            .float => |x| try dg.print(w, "f64 = {f},\n", .{Real{ .x = x }}),
            // §3.4.6 a string parameter: its text.
            .str => |t| try dg.print(w, "[]const u8 = \"{f}\",\n", .{std.zig.fmtString(dg.ip.stringToSlice(t))}),
            .int => |i| switch (i.storage) {
                .small => |s| try dg.print(w, "i64 = {d},\n", .{s}),
                .big => return dg.fail("parameter `{s}` wider than 64 bits", .{dg.ip.stringToSlice(n)}),
            },
            else => return dg.fail("parameter `{s}` is not a number", .{dg.ip.stringToSlice(n)}), // else: a string, an array or an aggregate
        }
    }
    for (calls.host_params, 0..) |h, k| if (dg.host_params & (@as(u8, 1) << @intCast(k)) != 0)
        try dg.print(w, "    /// §9.15 `$simparam(\"{s}\")`, host-written.\n    {s}: f64 = {f},\n", .{ h.name, h.field, Real{ .x = h.default } });
    try dg.print(w, "    temperature__: f64 = 300.15,\n", .{});
    // §9.15 Table 9-28 through the GPU-safe channel: indices into the host's
    // `contract.host_strings`, 0 ("not written") unless the host writes them.
    if (dg.host_strings) try dg.print(w, "    cwd_idx__: u32 = 0,\n    analysis_name_idx__: u32 = 0,\n", .{});
    // `given__` is the last field: `genGiven` writes declarations after it.
    try dg.genGiven(w);
    try dg.print(w, "}};\n", .{});
    try dg.print(w, "\n/// §6.3.6 the instance.\npub const Instance = struct {{\n    mfactor: f64 = 1.0,\n", .{});
    // §9.15 where a CPU host writes its working directory and analysis name.
    if (dg.host_strings) try dg.print(w, "    cwd: []const u8 = \"\",\n    analysis_name: []const u8 = \"\",\n", .{});
    try state.genInstanceFields(dg, w);
    try status.genInstanceFields(dg, w);
    try dg.print(w, "}};\n", .{});
    try dg.genDerive(w);
}

/// Numbers `given_bit`: each parameter the body reads through
/// `$param_given`, or whose default `derive` computes, in card order.
fn givenBits(dg: *DeclGen) Error!void {
    const d = dg.device;
    const asked = try dg.arena.alloc(bool, d.params.len);
    @memset(asked, false);
    const tags = dg.air.instructions.items(.tag);
    const datas = dg.air.instructions.items(.data);
    for (tags, datas) |tag, data| {
        if (tag != .call) continue;
        const x = dg.air.extraData(Air.Call, data.ty_pl.payload);
        if (x.data.callee != @backingInt(SysFn.Tag.@"$param_given") or x.data.args_len != 1) continue;
        const arg: Air.Inst.Ref = @fromBackingInt(dg.air.extra[x.end]);
        const i = arg.toIndex() orelse continue;
        if (tags[@backingInt(i)] == .arg) asked[datas[@backingInt(i)].ty_index.index] = true;
    }
    dg.given_bit = try dg.arena.alloc(u32, d.params.len);
    var next: u32 = 0;
    for (dg.given_bit, asked, d.params.items(.derive)) |*b, a, der| {
        b.* = no_bit;
        if (!a and der == .none) continue;
        b.* = next;
        next += 1;
    }
}

/// `Model.given__`, `given_params` and `setGiven`: §9.19 which card entries
/// the host named (the old device's names and layout).
fn genGiven(dg: *DeclGen, w: *std.Io.Writer) Error!void {
    var n: u32 = 0;
    for (dg.given_bit) |b| n += @intFromBool(b != no_bit);
    if (n == 0) return;
    try dg.print(w, "    /// §9.19 bit k: the host's card named `given_params[k]` (`setGiven`).\n    given__: std.StaticBitSet({d}) = .empty,\n    pub const given_params = [_][]const u8{{", .{n});
    for (dg.given_bit, dg.device.params.items(.name)) |b, name| if (b != no_bit) try dg.print(w, " \"{f}\",", .{Ident{ .name = dg.ip.stringToSlice(name) }});
    try dg.print(w,
        \\ }};
        \\    /// Marks field `name` given; a name without a bit is a no-op.
        \\    pub fn setGiven(model: *Model, name: []const u8) void {{
        \\        for (given_params, 0..) |g, k| if (std.mem.eql(u8, g, name)) return model.given__.set(k);
        \\    }}
        \\
    , .{});
}

/// `derive`: each `integer` parameter's low 32 bits (§3.4.1: the host
/// writes an `i64`), then each default that reads another parameter
/// (§6.3.4), in card order, unless the card named it.
fn genDerive(dg: *DeclGen, w: *std.Io.Writer) Error!void {
    const d = dg.device;
    var any = false;
    for (d.params.items(.default), d.params.items(.derive)) |def, der| any = any or der != .none or dg.ip.indexToKey(def) == .int;
    if (!any) return;
    var body: std.Io.Writer.Allocating = .init(dg.arena);
    var f: Function = .{ .dg = dg, .w = &body.writer };
    for (d.params.items(.name), d.params.items(.default)) |n, def| {
        if (dg.ip.indexToKey(def) != .int) continue;
        const name = Ident{ .name = dg.ip.stringToSlice(n) };
        try dg.print(&body.writer, "\n    model.{f} = @as(i32, @truncate(model.{f}));", .{ name, name });
    }
    for (d.params.items(.name), d.params.items(.derive), dg.given_bit) |n, der, bit| {
        if (der == .none) continue;
        const name = Ident{ .name = dg.ip.stringToSlice(n) };
        try dg.print(&body.writer, "\n    if (!model.given__.isSet({d})) {{", .{bit});
        f.indent = 2;
        _ = try f.genTree(der);
        try dg.print(&body.writer, "\n        model.{f} = ", .{name});
        try f.valueOf(der);
        try dg.print(&body.writer, ";\n    }}", .{});
    }

    try dg.print(w, "\n/// §3.4.1 each `integer` parameter's low 32 bits; §6.3.4 each default\n/// over other parameters, unless the card named it.\npub fn derive(comptime S: type, model: *Model) void {{{s}{s}\n}}\n", .{ if (namesIdent(body.written(), "S")) "" else "\n    _ = S;", body.written() });
}

/// Whether Zig text `text` spells identifier `id` as a whole token.
fn namesIdent(text: []const u8, id: []const u8) bool {
    var at: usize = 0;
    // Each pass moves `at` past one occurrence.
    while (std.mem.findPos(u8, text, at, id)) |k| : (at = k + id.len) {
        const before = k == 0 or !isIdentByte(text[k - 1]);
        const after = k + id.len == text.len or !isIdentByte(text[k + id.len]);
        if (before and after) return true;
    }
    return false;
}

fn isIdentByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '@';
}

test namesIdent {
    try std.testing.expect(namesIdent("S.con(1)", "S"));
    try std.testing.expect(namesIdent("F.zTo(S, 0x3, v)", "S"));
    try std.testing.expect(!namesIdent("model.Sx = @as(i64, 1)", "S"));
    try std.testing.expect(!namesIdent("", "S"));
}

/// The lane tables (`deriv_reads`, `jac_pattern`) and the §5.6.1.2 charge
/// sites (`n_q`, `q_stamps`, `q_site_pattern`).
fn genTables(dg: *DeclGen, w: *std.Io.Writer, p: stamps.Plan) Error!void {
    const d = dg.device;
    var all: Liveness.Mask = 0;
    for (p.pattern) |m| all |= m;
    for (d.charge_sites.items(.slot)) |slot| all |= dg.live.masks[@backingInt(slot)];
    all |= dg.ddx_reads;
    try dg.print(w, "\n/// The unknowns whose derivative lane the device reads.\npub const deriv_reads: u64 = 0x{x};\n/// The lanes a §4.5.14 `ddx` reads.\npub const ddx_reads: u64 = 0x{x};\n", .{ all, dg.ddx_reads });
    try dg.print(w, "/// §5.6 bit `c` of row `r`: d eval[r] / d x[c] may be nonzero.\npub const jac_pattern = [n_u]u64{{", .{});
    for (p.pattern) |m| try dg.print(w, " 0x{x},", .{m});
    try dg.print(w, " }};\n", .{});

    try dg.print(w, "/// §5.6.1.2 the charge sites `q` returns.\npub const n_q: usize = {d};\n", .{d.charge_sites.len});
    try dg.print(w, "pub const q_site_pattern = [n_q]u64{{", .{});
    for (d.charge_sites.items(.slot)) |slot| try dg.print(w, " 0x{x},", .{dg.live.masks[@backingInt(slot)]});
    try dg.print(w, " }};\n", .{});
    try dg.print(w, "pub const q_stamps = [_]contract.QStamp(U){{\n", .{});
    for (p.q) |s| try dg.print(w, "    .{{ .site = {d}, .row = .{f}, .sign = {f} }},\n", .{ s.site, Ident{ .name = dg.nodeName(s.row) }, Real{ .x = s.sign } });
    try dg.print(w, "}};\n", .{});
}

/// `Core(S)`, `core` and its entry `run`: a versioned unit when the verdict
/// rates every root `.optimized` (§11.9: the box checked, then the
/// fast-math body, else the strict body).
fn genCore(dg: *DeclGen, w: *std.Io.Writer, uses: Function.Uses, body: []const u8) Error!void {
    const d = dg.device;
    // The fields typed over `S`: an integer held value is an `i64`.
    var reals = d.charge_sites.len;
    for (dg.held_field, 0..) |h, i| reals += @intFromBool(h != null and dg.air.instructions.items(.data)[i].ty == InternPool.Index.real_type);
    for (d.contributions.items(.resist)) |slot| reals += @intFromBool(dg.live.assigned[@backingInt(slot)]);
    reals += d.limit_slots.len + dg.op_sites.len;
    try dg.print(w, "\nfn Core(comptime S: type) type {{\n    {s}return struct {{", .{if (reals == 0) "_ = S;\n    " else ""});
    for (d.contributions.items(.resist), 0..) |slot, k| if (dg.live.assigned[@backingInt(slot)]) try dg.print(w, " r{d}: F.zOf(S, 0x{x}),", .{ k, dg.live.masks[@backingInt(slot)] });
    for (d.charge_sites.items(.slot), 0..) |slot, k| try dg.print(w, " c{d}: F.zOf(S, 0x{x}),", .{ k, dg.live.masks[@backingInt(slot)] });
    for (dg.held_field, 0..) |h, i| if (h != null) {
        // A held array returns whole: one `[n]` field.
        try dg.print(w, " h{d}: ", .{i});
        if (state.arrayLen(dg, i)) |n| try dg.print(w, "[{d}]", .{n});
        const ty = dg.air.instructions.items(.data)[i].ty;
        if (ty == InternPool.Index.real_type) try dg.print(w, "F.zOf(S, 0x{x}),", .{dg.live.masks[i]}) else if (ty == InternPool.Index.string_type) try dg.print(w, "[]const u8,", .{}) else try dg.print(w, "i64,", .{});
    };
    for (d.limit_slots.items(.slot), 0..) |slot, k| try dg.print(w, " l{d}: F.zOf(S, 0x{x}),", .{ k, dg.live.masks[@backingInt(slot)] });
    try ops.genCoreFields(dg, w);
    try status.genCoreFields(dg, w);
    try dg.print(w, " }};\n}}\n", .{});
    // §9.21.1 every evaluation starts from the snapshots an accepted point kept.
    const tables = dg.table_len.len != 0;
    var decls: std.Io.Writer.Allocating = .init(dg.arena);
    try ops.genDecls(dg, &decls.writer);
    try status.genDecls(dg, &decls.writer);
    try dg.print(w, "\n/// The whole analog body, once per evaluation.\nfn core(comptime S: type, comptime mode: std.builtin.FloatMode, {s}: D.zX(S), {s}: *const Model, {s}: InstancePtr, {s}: contract.SimState) Core(S) {{\n    @setFloatMode(mode);{s}{s}{s}\n}}\n", .{
        if (uses.x) "x" else "_",
        if (uses.model) "model" else "_",
        if (uses.inst or tables) "inst" else "_",
        if (uses.sim) "sim" else "_",
        if (tables) "\n    inst.table_ready = inst.table_kept;" else "",
        decls.written(),
        body,
    });
    const guards_opt = try dg.box();
    const checked = if (guards_opt) |g| g.len != 0 else false;
    try dg.print(w, "\nfn run(comptime S: type, x: *const [n_u]S.V, xs: D.zX(S), model: *const Model, inst: InstancePtr, sim: contract.SimState) Core(S) {{\n{s}", .{if (guards_opt != null) "" else "    _ = x;\n"});
    if (guards_opt) |guards| {
        if (!checked) {
            // An `.optimized` unit proven on the whole line needs no check.
            try dg.print(w, "    return fast(S, x, xs, model, inst, sim);\n}}\n{s}", .{fast});
            return;
        }
        try dg.print(w, "    if ((", .{});
        for (guards, 0..) |g, k| {
            if (k != 0) try dg.print(w, " & ", .{});
            try dg.print(w, "zIn(", .{});
            switch (g.leaf) {
                .probe => try dg.print(w, "x[{d}]", .{g.index}),
                .arg => {
                    const name = Ident{ .name = dg.paramName(g.index) };
                    if (d.params.items(.ty)[g.index] == .integer) try dg.print(w, "@as(f64, @floatFromInt(model.{f}))", .{name}) else try dg.print(w, "model.{f}", .{name});
                },
            }
            try dg.print(w, ", {f}, {any}, {f}, {any}, {any})", .{ Real{ .x = g.iv.lo }, g.iv.lo_open, Real{ .x = g.iv.hi }, g.iv.hi_open, g.iv.nonzero });
        }
        try dg.print(w, ") != 0) return fast(S, x, xs, model, inst, sim);\n", .{});
    }
    // A versioned unit's strict body is the cold path, out of line, so the
    // fast body is laid out alone (`bench-fast`: inlined beside it, the
    // MOSFET ran at half speed).
    try dg.print(w, "    return @call(.{s}, core, .{{ S, .strict, xs, model, inst, sim }});\n}}\n", .{if (checked) "never_inline" else "always_inline"});
    if (checked) try dg.print(w, "{s}{s}", .{ fast, zin });
}

/// The guard box of the versioned unit, or null for one strict body: every
/// root's box when each is `.optimized`, since `core` is shared and
/// `.strict` absorbs (`Float.Mode.strictest`). Only a body that computes a
/// transcendental is versioned: `bench-fast` measured the fast body paying
/// for its entry check there (a diode's exp, an OTA's tanh) and losing to it
/// on polynomial bodies (a square-law MOSFET, abs).
// ponytail: one box for the whole core; per-root bodies (the old
// `plan/jobs.zig` slicing) let an `.optimized` root run fast beside a
// `.strict` one.
fn box(dg: *DeclGen) Error!?[]const Air.Float.Guard {
    if (dg.options.strict) return null;
    const v = dg.verdict orelse return null;
    if (v.modes.len == 0 or !transcendental(dg.air.*)) return null;
    var guards: std.ArrayList(Air.Float.Guard) = .empty;
    for (v.modes, 0..) |mode, r| {
        if (mode == .strict) return null;
        try guards.appendSlice(dg.arena, v.box(r));
    }
    return guards.items;
}

/// Whether `air` computes a §4.3 transcendental (or §4.5.13 `limexp`, an
/// `exp`): the work fast-math's flags pay off on.
fn transcendental(air: Air) bool {
    for (air.instructions.items(.tag), air.instructions.items(.data)) |tag, data| switch (tag) {
        .exp, .expm1, .ln, .ln1p, .log10, .pow, .hypot, .sin, .cos, .tan, .asin, .acos, .atan, .atan2, .sinh, .cosh, .tanh, .asinh, .acosh, .atanh => return true,
        .call => if (air.extraData(Air.Call, data.ty_pl.payload).data.callee == @backingInt(SysFn.Tag.limexp)) return true,
        else => {}, // else: arithmetic, control and the rest of Table 4-14
    };
    return false;
}

/// `eval` and `q`, each over one `run`.
fn genEntries(dg: *DeclGen, w: *std.Io.Writer, p: stamps.Plan) Error!void {
    const d = dg.device;
    try dg.print(w, "\n/// §5.6 the resistive residual: KCL at every unknown.\npub fn eval(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) contract.Rows(Self, S) {{\n", .{});
    // §9.7.3 a latched status (`status.hasStatus`): skip `run` once it is
    // set, then latch any `$fatal`/`$error` this evaluation newly reaches
    // and zero the rows it was about to stamp.
    if (status.hasStatus(dg)) try dg.print(w, "    if (inst.vera_status__ != 0) return D.zRowsZero(S);\n", .{});
    try dg.print(w, "    const xs = D.zProbe(S, x);\n    const m = run(S, x, xs, model, inst, sim);\n", .{});
    if (status.hasStatus(dg)) try dg.print(w, "    inst.vera_status__ = m.st__;\n    inst.vera_status_args__ = m.sa__;\n", .{});
    try dg.print(w, "    var res = D.zRowsZero(S);\n    _ = .{{ &m, &res }};\n", .{});
    if (status.hasStatus(dg)) try dg.print(w, "    if (inst.vera_status__ != 0) return res;\n", .{});
    for (p.stamps) |s| {
        try dg.print(w, "    res[{d}] = D.zRow(S, .{f}, ", .{ s.row, Ident{ .name = dg.nodeName(s.row) } });
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
    if (status.hasStatus(dg)) {
        try dg.print(w, "    if (inst.vera_status__ != 0) return .{{", .{});
        for (0..d.charge_sites.len) |k| try dg.print(w, " F.zTo(S, contract.siteMask(Self, {d}), S.con(0.0)),", .{k});
        try dg.print(w, " }};\n", .{});
    }
    try dg.print(w, "    const m = run(S, x, D.zProbe(S, x), model, inst, sim);\n", .{});
    if (status.hasStatus(dg)) {
        try dg.print(w, "    inst.vera_status__ = m.st__;\n    inst.vera_status_args__ = m.sa__;\n    if (inst.vera_status__ != 0) return .{{", .{});
        for (0..d.charge_sites.len) |k| try dg.print(w, " F.zTo(S, contract.siteMask(Self, {d}), S.con(0.0)),", .{k});
        try dg.print(w, " }};\n", .{});
    }
    try dg.print(w, "    return .{{", .{});
    for (0..d.charge_sites.len) |k| try dg.print(w, " F.zTo(S, contract.siteMask(Self, {d}), m.c{d}),", .{ k, k });
    try dg.print(w, " }};\n}}\n", .{});
}

/// `V(u)`: the unknown's family value, or ground's 0.
fn voltage(dg: *DeclGen, w: *std.Io.Writer, u: u32) Error!void {
    if (u == @backingInt(Device.Node.Index.ground)) return dg.print(w, "S.con(0.0)", .{});
    try dg.print(w, "xs[{d}]", .{u});
}

fn nodeName(dg: *const DeclGen, r: u32) []const u8 {
    return dg.u_names[r];
}

pub fn print(dg: *DeclGen, w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) Error!void {
    _ = dg;
    w.print(fmt, args) catch return error.OutOfMemory;
}
