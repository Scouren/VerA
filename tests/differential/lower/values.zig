//! diff-lower's value check (tests/differential/lower.zig): one fixture's
//! old MIR and `Lowered`, and its new `Air` and `Air.Device`, in; whether
//! every contribution's resistive and reactive sum, and every operand each
//! display row printed at its last run, agrees out, evaluated at `points`
//! seeded points by the old MIR interpreter
//! (`src/codegen/verilog/Interp.zig`) and by `Air.interp`. A print or task
//! is a 0 on both sides and a print operand's width record its operand (the
//! old interpreter refuses a run at any call it does not model); a root the
//! old interpreter refuses is skipped and counted. Values reached through
//! exp, pow, tan or log10 at run time may differ by diff-air's named ulps
//! (air.xfail). A display operand the old side computes wrong is settled
//! by `rulings` (its tiebreaker: an LRM clause or a 40-digit reference)
//! and counted as an old-side bug.
//! Clauses: §4.3.1 (the abs ruling); otherwise VerA's rewrite against VerA.
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
    /// Where a host call's string result lives.
    scratch: std.mem.Allocator,
    /// The display row each `call` instruction is, by instruction.
    display_of: []const ?u32,
    /// Each display row's operands at its last run this point, or null.
    display_args: []?[]const Air.interp.Value,
    /// The operands of the print call `hostCall` answered last.
    last_args: ?[]const Air.interp.Value = null,
    fn seen(ctx: *anyopaque, inst: Air.Inst.Index, val: Air.interp.Value) void {
        const o: *Observe = @ptrCast(@alignCast(ctx));
        const i = @backingInt(inst);
        if (o.display_of[i]) |k| if (o.last_args) |a| {
            o.display_args[k] = a;
        };
        o.last_args = null;
        if (o.air.instructions.items(.tag)[i] != .assign) return;
        const slot = o.air.instructions.items(.data)[i].bin_op.lhs.toIndex().?;
        o.finals[@backingInt(slot)] = val;
    }
};

/// A display operand the old side computes wrong: the tiebreaker `why`
/// names gives `want`, which the new side must equal bit for bit.
const Ruling = struct { fixture: []const u8, display: u32, operand: u32, want: f64, why: []const u8 };

/// Every ruled display operand. cosh(1) against the 40-digit reference
/// 1.5430806348152437784779...: the nearest double is ...2437, std_kernels'
/// (Gompute's, the device's kernel, which Sema folds with); the old fold's
/// gm is 1 ulp above (lib/TODO.md §12, the accepted Gompute ruling).
const rulings = [_]Ruling{
    .{ .fixture = "verilog-a/exhaustive/rounding_selection.va", .display = 7, .operand = 2, .want = -0.0, .why = "§4.3.1 \"abs(x) is equivalent to (x > 0) x : -x\": abs(+0.0) is -0.0, as the old device kernel computes; the old fold's @abs gives +0.0" },
    .{ .fixture = "verilog-a/ch04_expressions/abs.va", .display = 2, .operand = 2, .want = -0.0, .why = "§4.3.1 \"abs(x) is equivalent to (x > 0) x : -x\": abs(+0.0) is -0.0, as the old device kernel computes; the old fold's @abs gives +0.0" },
    .{ .fixture = "verilog-a/ch04_expressions/cosh.va", .display = 2, .operand = 2, .want = 1.5430806348152437, .why = "cosh(1) correctly rounded (40-digit reference); the old fold's gm is 1 ulp above" },
    .{ .fixture = "verilog-a/exhaustive/hyperbolic.va", .display = 2, .operand = 2, .want = 1.5430806348152437, .why = "cosh(1) correctly rounded (40-digit reference); the old fold's gm is 1 ulp above" },
};

/// Evaluates every contribution's sums at `points` seeded points by both
/// interpreters. Asserts the tables agree.
pub fn compareValues(arena: std.mem.Allocator, rel: []const u8, mir: *Mir, lw: *Lowered, zcu: *const Zcu, a: *const Sema.Analysis) !Verdict {
    const d = &a.device;
    std.debug.assert(lw.nodes.len == d.nodes.len);
    std.debug.assert(lw.contributions.items.len == d.contributions.len);
    std.debug.assert(lw.displays.items.len == d.displays.len);
    if (d.contributions.len == 0 and d.displays.len == 0) return .{ .why = null, .tables = true };
    // Each display's operands, read before its call becomes a 0 below.
    const old_display_args = try arena.alloc([]const Mir.Value, lw.displays.items.len);
    for (old_display_args, lw.displays.items) |*x, disp| x.* = try arena.dupe(Mir.Value, mir.instData(mir.valueDef(disp.val).inst_result).call.args);
    const display_of = try arena.alloc(?u32, a.air.instructions.len);
    @memset(display_of, null);
    for (d.displays.items(.call), 0..) |call, k| display_of[@backingInt(call)] = @intCast(k);
    const display_args = try arena.alloc(?[]const Air.interp.Value, d.displays.len);
    // §17.1.1.3 the width (and sign) each print operand is formatted at.
    if (try compareWidths(arena, mir, old_display_args, &a.air, &zcu.intern_pool, d)) |why| return .{ .why = why, .tables = true };
    // A parameter's reference value, read through the old interpreter.
    // The old interpreter refuses a whole run at any call it does not
    // model; a print or task has no value a contribution reads, so each
    // becomes a 0 here, as the new side's `Calls` answers it.
    for (0..mir.instCount()) |k| {
        const inst: Mir.Inst = @fromBackingInt(@intCast(k));
        if (mir.instOp(inst) != .call) continue;
        const call = mir.instData(inst).call;
        // A print operand's width record is the operand, as `hostCall`
        // answers it; the old interpreter refuses the whole run at one.
        if (call.callee == .@"$display$width") {
            mir.insts.items(.op)[k] = .opt_barrier;
            mir.insts.items(.a)[k] = @backingInt(call.args[0]);
            continue;
        }
        switch (Mir.callee.family(call.callee)) {
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
    const arg_types = try arena.alloc(InternPool.Index, d.params.len);
    @memset(arg_types, .real_type);
    for (a.air.instructions.items(.tag), a.air.instructions.items(.data)) |tag, data| {
        if (tag == .arg) arg_types[data.ty_index.index] = data.ty_index.ty;
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
        for (args, refs, arg_types) |*x, r, ty| {
            const c = (old.get(r) catch null) orelse {
                x.* = switch (ty) {
                    .integer_type => .{ .int = 0 },
                    .string_type => .{ .str = "" },
                    else => .{ .real = 0 }, // else: a real
                };
                continue;
            };
            x.* = switch (ty) {
                .integer_type => .{ .int = switch (c.c) {
                    .int => |i| i,
                    .real => |f| std.math.lossyCast(i64, @round(f)),
                    .str => 0,
                } },
                .string_type => .{ .str = if (c.c == .str) c.c.str else "" },
                else => .{ .real = c.c.asReal() }, // else: a real
            };
        }
        @memset(finals, null);
        @memset(display_args, null);
        var obs: Observe = .{ .finals = finals, .air = &a.air, .scratch = scratch.allocator(), .display_of = display_of, .display_args = display_args };
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
        if (old_ran) if (try compareDisplays(arena, rel, &old, old_display_args, display_args, libm, &v.old_bugs)) |why| {
            v.why = why;
            return v;
        };
    }
    return v;
}

// ---- private ----

/// The first display operand both sides computed this point and that
/// differs, or null. An operand either side did not reach (an untaken
/// arm, a call the old interpreter refuses) is not compared. Under run-time
/// libm a real may be ulps apart and a comparison over it may flip. A
/// difference a `rulings` row settles for the new side counts in `old_bugs`.
fn compareDisplays(arena: std.mem.Allocator, rel: []const u8, old: *const OldInterp, old_args: []const []const Mir.Value, new_args: []const ?[]const Air.interp.Value, libm: bool, old_bugs: *u32) !?[]const u8 {
    std.debug.assert(old_args.len == new_args.len);
    for (old_args, new_args, 0..) |oa, maybe_na, k| {
        const na = maybe_na orelse continue;
        if (oa.len != na.len) return try arena.print("display {d}: old {d} operands, new {d}", .{ k, oa.len, na.len });
        for (oa, na, 0..) |ov, nv, j| {
            const o = (old.get(ov) catch null) orelse continue;
            const same = switch (o.c) {
                .str => |s| nv == .str and std.mem.eql(u8, s, nv.str),
                .int => nv != .str and (sameBits(o.c.asReal(), realOf(nv)) or (libm and nv == .int)),
                .real => nv != .str and (sameBits(o.c.real, realOf(nv)) or (libm and ulpsApart(o.c.real, realOf(nv)) <= libm_ulps)),
            };
            if (same) continue;
            if (ruled(rel, @intCast(k), @intCast(j), nv)) {
                old_bugs.* += 1;
                continue;
            }
            return try arena.print("display {d} operand {d}: old {any}, new {any}", .{ k, j, o.c, nv });
        }
    }
    return null;
}

/// The first print operand whose `display$width` record (bits, and the
/// sign when given) differs between the sides, or null. A record only one
/// side makes differs.
fn compareWidths(arena: std.mem.Allocator, mir: *const Mir, old_args: []const []const Mir.Value, air: *const Air, ip: *const InternPool, d: *const Device) !?[]const u8 {
    std.debug.assert(old_args.len == d.displays.len);
    for (old_args, d.displays.items(.call), 0..) |oa, call, k| {
        const x = air.extraData(Air.Call, air.instructions.items(.data)[@backingInt(call)].ty_pl.payload);
        const na: []const Air.Inst.Ref = @ptrCast(air.extra[x.end..][0..x.data.args_len]);
        if (oa.len != na.len) continue; // the value check reports the count
        for (oa, na, 0..) |ov, nv, j| {
            const old_w = oldWidth(mir, ov);
            const new_w = newWidth(air, ip, nv);
            if (old_w == null and new_w == null) continue;
            if (old_w != null and new_w != null and old_w.? == new_w.?) continue;
            return try arena.print("display {d} operand {d}: old width {?d}, new {?d}", .{ k, j, old_w, new_w });
        }
    }
    return null;
}

/// The bits an old operand's `$display$width` call records, or null.
fn oldWidth(mir: *const Mir, v: Mir.Value) ?i64 {
    const r = mir.resolveAlias(v);
    const inst = switch (mir.valueDef(r)) {
        .inst_result => |i| i,
        else => return null, // else: not a call
    };
    if (mir.instOp(inst) != .call) return null;
    const c = mir.instData(inst).call;
    if (c.callee != .@"$display$width" or c.args.len < 2) return null;
    return switch (mir.valueDef(mir.resolveAlias(c.args[1]))) {
        .int_const => |n| n,
        else => null, // else: a width that is no constant
    };
}

/// The bits a new operand's `display$width` call records, or null.
fn newWidth(air: *const Air, ip: *const InternPool, r: Air.Inst.Ref) ?i64 {
    const i = r.toIndex() orelse return null;
    if (air.instructions.items(.tag)[@backingInt(i)] != .call) return null;
    const x = air.extraData(Air.Call, air.instructions.items(.data)[@backingInt(i)].ty_pl.payload);
    if (x.data.callee != @backingInt(vams.SysFn.Tag.@"display$width") or x.data.args_len < 2) return null;
    const bits: Air.Inst.Ref = @fromBackingInt(air.extra[x.end + 1]);
    return switch (ip.indexToKey(bits.toInterned() orelse return null)) {
        .int => |n| n.storage.small,
        else => null, // else: a width that is no constant
    };
}

/// Whether a `rulings` row names this operand and the new side gives its value.
fn ruled(rel: []const u8, display: u32, operand: u32, got: Air.interp.Value) bool {
    for (rulings) |r| {
        if (r.display != display or r.operand != operand or !std.mem.eql(u8, r.fixture, rel)) continue;
        return got == .real and sameBits(got.real, r.want);
    }
    return false;
}

/// The new side's model of the host, the old interpreter's
/// (`src/codegen/verilog/Interp.zig`'s `call`): a print or task is 0; a
/// §4.5.7-§4.5.9 operator its settled argument; `limexp` `@exp`; the
/// environment at a transient point (300.15 K, `$mfactor` 1). An analog
/// operator, noise source, event, kernel or user call is one the old
/// interpreter refuses, so every root its value reaches (through data or a
/// condition) is skipped there and never compared: it is a 0 of its type, so
/// the run reaches the roots that are. A file, random or query call is not
/// modelled (a loop on `$feof` would never end).
fn hostCall(ctx: *anyopaque, callee: u32, args: []const Air.interp.Value) Air.interp.Error!Air.interp.Value {
    const o: *Observe = @ptrCast(@alignCast(ctx));
    if (callee > std.math.maxInt(@typeInfo(vams.SysFn.Tag).@"enum".tag_type)) return .{ .real = 0 };
    const tag: vams.SysFn.Tag = @fromBackingInt(@intCast(callee));
    switch (tag) {
        .transition, .absdelay, .slew => return args[0],
        .limexp => return .{ .real = @exp(realOf(args[0])) },
        // Table 9-29's top-level values, the old card defaults.
        .@"$mfactor", .@"$hflip", .@"$vflip" => return .{ .real = 1 },
        .@"$xposition", .@"$yposition", .@"$angle" => return .{ .real = 0 },
        .@"$temperature" => return .{ .real = 300.15 },
        .@"op$static" => return .{ .int = 0 },
        // A reader's destinations: the old interpreter refuses the reader.
        .@"scan$item" => return .{ .real = 0 },
        .@"scan$str" => return .{ .str = "" },
        // A print operand's width record: the operand.
        .@"display$width" => return args[0],
        // §3.3 Table 3-3 over strings, as the old `$str$cat`/`$str$repeat`
        // and string comparison compute them.
        .@"str$cmp" => return if (args[0] != .str or args[1] != .str) error.Unsupported else .{ .int = switch (std.mem.order(u8, args[0].str, args[1].str)) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        } },
        .@"str$cat" => {
            var out: std.ArrayList(u8) = .empty;
            for (args) |x| try out.appendSlice(o.scratch, if (x == .str) x.str else return error.Unsupported);
            return .{ .str = out.items };
        },
        .@"str$repeat" => {
            var out: std.ArrayList(u8) = .empty;
            if (args[0] != .int or args[1] != .str) return error.Unsupported;
            for (0..@intCast(@max(args[0].int, 0))) |_| try out.appendSlice(o.scratch, args[1].str);
            return .{ .str = out.items };
        },
        .@"$vt" => return .{ .real = 1.380649e-23 * (if (args.len > 0) realOf(args[0]) else 300.15) / 1.602176634e-19 },
        else => {}, // else: by family below
    }
    const info = vams.SysFn.get(tag);
    if (info.family == .display or info.family == .file_out or info.family == .simctl) o.last_args = try o.scratch.dupe(Air.interp.Value, args);
    return switch (info.family) {
        .display, .simctl, .file_out, .string => switch (info.ty) {
            .str => .{ .str = "" },
            .int => .{ .int = 0 },
            .real, .none => .{ .real = 0 },
        },
        .analog_op, .event, .kernel => if (info.ty == .int) .{ .int = 0 } else .{ .real = 0 },
        .math, .query, .convert, .file_func, .random => error.Unsupported,
    };
}

fn realOf(x: Air.interp.Value) f64 {
    return switch (x) {
        .real => |f| f,
        .int => |i| @floatFromInt(i),
        .array, .str => std.math.nan(f64),
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
