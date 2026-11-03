//! diff-lower's value check (tests/differential/lower.zig): one fixture's
//! old MIR and `Lowered`, and its new `Air` and `Air.Device`, in; whether
//! every contribution's resistive and reactive sum agrees out, evaluated at
//! `points` seeded points by the old MIR interpreter
//! (`src/codegen/verilog/Interp.zig`) and by `Air.interp`. A print or task
//! is a 0 on both sides (the old interpreter refuses a run at any call it
//! does not model); a root the old interpreter refuses is skipped and
//! counted. Values reached through exp, pow, tan or log10 at run time may
//! differ by diff-air's named ulps (air.xfail).
//! No LRM clause: this checks VerA's rewrite against VerA.
//!
//! Contents:
//! - `pub const points`, `pub const libm_ulps: u64`
//! - `pub fn compareValues(arena: std.mem.Allocator, rel: []const u8, mir: *Mir, lw: *Lowered, zcu: *const Zcu, a: *const Sema.Analysis) !Verdict`

const std = @import("std");
const vams = @import("vams");
const sema = @import("sema");
const Air = @import("air");
const InternPool = @import("intern_pool");
const ir = @import("ir");
const OldInterp = @import("old_interp");
const Zcu = sema.Zcu;
const Sema = sema.Sema;
const Mir = ir.Mir;
const Lowered = ir.Lowered;
const Device = Air.Device;
const Verdict = @import("../lower.zig").Verdict;

/// How far apart a value reached through exp, pow, tan or log10 may be:
/// diff-air's bounds (at most 3 ulps per operation), grown by the
/// arithmetic after them; a lowering bug is far past it.
pub const libm_ulps: u64 = 1 << 10;

/// Seeded points per fixture for the value check.
pub const points = 1000;

/// The old interpreter's refusal slot (its own file's type).
const Refusal = std.meta.Child(@FieldType(OldInterp, "refusal"));

/// Records the last value assigned to each slot, by its `alloc`.
const Observe = struct {
    finals: []?Air.interp.Value,
    air: *const Air,
    fn seen(ctx: *anyopaque, inst: Air.Inst.Index, val: Air.interp.Value) void {
        const o: *Observe = @ptrCast(@alignCast(ctx));
        const i = @backingInt(inst);
        if (o.air.instructions.items(.tag)[i] != .assign) return;
        const slot = o.air.instructions.items(.data)[i].bin_op.lhs.toIndex().?;
        o.finals[@backingInt(slot)] = val;
    }
};

/// Evaluates every contribution's sums at `points` seeded points by both
/// interpreters. Asserts the tables agree.
pub fn compareValues(arena: std.mem.Allocator, rel: []const u8, mir: *Mir, lw: *Lowered, zcu: *const Zcu, a: *const Sema.Analysis) !Verdict {
    const d = &a.device;
    std.debug.assert(lw.nodes.len == d.nodes.len);
    std.debug.assert(lw.contributions.items.len == d.contributions.len);
    if (d.contributions.len == 0) return .{ .why = null, .tables = true };
    // A parameter's reference value, read through the old interpreter.
    // The old interpreter refuses a whole run at any call it does not
    // model; a print or task has no value a contribution reads, so each
    // becomes a 0 here, as the new side's `Calls` answers it.
    for (0..mir.instCount()) |k| {
        const inst: Mir.Inst = @fromBackingInt(@intCast(k));
        if (mir.instOp(inst) != .call) continue;
        switch (Mir.callee.family(mir.instData(inst).call.callee)) {
            .display, .simctl, .file_out => {
                mir.insts.items(.op)[k] = .opt_barrier;
                mir.insts.items(.a)[k] = @backingInt(Mir.Value.f_zero);
            },
            .none, .file_func, .file_read => {},
        }
    }
    const refs = try arena.alloc(Mir.Value, lw.params.items.len);
    for (refs, 0..) |*r, k| r.* = try mir.addParamRef(arena, @intCast(k));
    const volts = try arena.alloc(f64, lw.nodes.len);
    var refusal: Refusal = undefined;
    var old = try OldInterp.init(arena, mir, lw, volts, &refusal);
    const defaults = try arena.alloc(?Lowered.Const, lw.params.items.len);
    for (defaults, lw.params.items) |*x, p| x.* = p.folded;
    var prng: std.Random.DefaultPrng = .init(std.hash.Wyhash.hash(0, rel));
    const rand = prng.random();
    const args = try arena.alloc(Air.interp.Value, d.params.len);
    // Each `arg`'s type, which the value handed to it must have.
    const int_args = try arena.alloc(bool, d.params.len);
    @memset(int_args, false);
    for (a.air.instructions.items(.tag), a.air.instructions.items(.data)) |tag, data| {
        if (tag == .arg) int_args[data.ty_index.index] = data.ty_index.ty == InternPool.Index.integer_type;
    }
    const finals = try arena.alloc(?Air.interp.Value, a.air.instructions.len);
    // Whether the body computes exp, pow, tan or log10 at run time.
    const libm = for (a.air.instructions.items(.tag)) |tag| switch (tag) {
        .exp, .pow, .tan, .log10 => break true,
        else => {}, // else: computed alike by both interpreters
    } else false;
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    var v: Verdict = .{ .why = null, .tables = true, .roots = @intCast(2 * d.contributions.len) };
    const refused = try arena.alloc(bool, 2 * d.contributions.len);
    @memset(refused, false);
    for (0..points) |_| {
        _ = scratch.reset(.retain_capacity);
        for (volts) |*x| x.* = rand.float(f64) * 4 - 2;
        for (lw.params.items, defaults, 0..) |*p, def, k| {
            p.folded = def;
            const c = def orelse continue;
            if (c != .real or p.shape) continue;
            p.folded = .{ .real = drawIn(rand, c.real, d.paramRanges(@fromBackingInt(@intCast(k)))) };
        }
        const old_ran = if (old.run()) true else |e| switch (e) {
            error.OutOfMemory => return e,
            error.Refused => false,
        };
        for (args, refs, int_args) |*x, r, int| {
            const c = (old.get(r) catch null) orelse {
                x.* = if (int) .{ .int = 0 } else .{ .real = 0 };
                continue;
            };
            x.* = if (int) .{ .int = switch (c.c) {
                .int => |i| i,
                .real => |f| std.math.lossyCast(i64, @round(f)),
                .str => 0,
            } } else .{ .real = c.c.asReal() };
        }
        @memset(finals, null);
        var obs: Observe = .{ .finals = finals, .air = &a.air };
        const new_result = Air.interp.run(scratch.allocator(), a.air, &zcu.intern_pool, .{
            .args = args,
            .probes = volts,
            .loop_cap = 1 << 20,
            .observe = .{ .ctx = &obs, .seen = Observe.seen },
            .calls = .{ .ctx = &obs, .value = hostCall },
            .paths_zero = true,
        });
        for (0..d.contributions.len) |k| for (0..2) |half| {
            const root = 2 * k + half;
            if (refused[root]) continue;
            const old_val = if (!old_ran) null else old.get(if (half == 0) lw.contributions.items[k].resist_val else lw.contributions.items[k].react_val) catch null;
            const ov = old_val orelse {
                refused[root] = true;
                v.skipped += 1;
                continue;
            };
            const slot = if (half == 0) d.contributions.items(.resist)[k] else d.contributions.items(.react)[k];
            const want = ov.c.asReal();
            _ = new_result catch |e| {
                v.why = try arena.print("contribution {d} {s}: old {e}, new had no value ({t})", .{ k, if (half == 0) "resist" else "react", want, e });
                return v;
            };
            const got = if (finals[@backingInt(slot)]) |x| realOf(x) else 0;
            if (!sameBits(want, got)) {
                // diff-air's named ulp differences (air.xfail): the old side
                // runs gm's exp/pow/tan/log10, Air.interp the builtins.
                if (libm and ulpsApart(want, got) <= libm_ulps) {
                    v.values_libm += 1;
                    continue;
                }
                v.why = try arena.print("contribution {d} {s}: old {e}, new {e}", .{ k, if (half == 0) "resist" else "react", want, got });
                return v;
            }
            v.values += 1;
        };
    }
    return v;
}

// ---- private ----

/// The new side's model of the host, the old interpreter's
/// (`src/codegen/verilog/Interp.zig`'s `call`): a print or task is 0; a
/// §4.5.7-§4.5.9 operator its settled argument; `limexp` `@exp`; the
/// environment at a transient point (300.15 K, `$mfactor` 1). Every other
/// call is not modelled.
fn hostCall(ctx: *anyopaque, callee: u32, args: []const Air.interp.Value) Air.interp.Error!Air.interp.Value {
    _ = ctx;
    if (callee > std.math.maxInt(@typeInfo(vams.SysFn.Tag).@"enum".tag_type)) return error.Unsupported;
    const tag: vams.SysFn.Tag = @fromBackingInt(@intCast(callee));
    switch (tag) {
        .transition, .absdelay, .slew => return args[0],
        .limexp => return .{ .real = @exp(realOf(args[0])) },
        .@"$mfactor" => return .{ .real = 1 },
        .@"$temperature" => return .{ .real = 300.15 },
        .@"op$static" => return .{ .int = 0 },
        .@"$vt" => return .{ .real = 1.380649e-23 * (if (args.len > 0) realOf(args[0]) else 300.15) / 1.602176634e-19 },
        else => {}, // else: by family below
    }
    return switch (vams.SysFn.get(tag).family) {
        .display, .simctl, .file_out, .string => .{ .real = 0 },
        .math, .analog_op, .event, .query, .convert, .file_func, .random, .kernel => error.Unsupported,
    };
}

fn realOf(x: Air.interp.Value) f64 {
    return switch (x) {
        .real => |f| f,
        .int => |i| @floatFromInt(i),
        .array => std.math.nan(f64),
    };
}

/// How many representable doubles lie between `a` and `b`; max for a NaN
/// against a number or a sign change.
fn ulpsApart(a: f64, b: f64) u64 {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.maxInt(u64);
    if ((a < 0) != (b < 0)) return if (a == 0 and b == 0) 0 else std.math.maxInt(u64);
    const x: i64 = @bitCast(@abs(a));
    const y: i64 = @bitCast(@abs(b));
    return @abs(x - y);
}

fn sameBits(a: f64, b: f64) bool {
    if (std.math.isNan(a) and std.math.isNan(b)) return true;
    return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
}

/// A value near `def` inside every `from` range (closed bounds kept
/// inside), outside every `exclude` point; `def` when none is found.
fn drawIn(rand: std.Random, def: f64, ranges: []const Device.Range) f64 {
    for (0..16) |_| {
        const x = def * (0.5 + rand.float(f64)) + (rand.float(f64) - 0.5) * 1e-3;
        if (admits(x, ranges)) return x;
    }
    return def;
}

fn admits(x: f64, ranges: []const Device.Range) bool {
    for (ranges) |r| {
        if (r.strings) continue;
        const lo = r.lo orelse -std.math.inf(f64);
        const hi = r.hi orelse std.math.inf(f64);
        const in = (if (r.lo_closed) x >= lo else x > lo) and (if (r.hi_closed) x <= hi else x < hi);
        if (in == r.exclude) return false;
    }
    return true;
}
