//! A minimal OSDI host: loads one library the way a simulator does and drives its first descriptor
//! through setup_model, setup_instance, eval and every load at a few operating points, for the
//! default card and for a perturbed one. Prints the descriptor's sizes, one checksum over every
//! number the library handed back, and the time of one transient iterate (eval, load_spice_rhs_tran,
//! load_jacobian_tran). Two builds of one device are equivalent here when the checksums match.
//! The timed loops pass their inputs and outputs through `std.mem.doNotOptimizeAway` (K2): the
//! calls are already opaque (a dlopen'd function pointer), the black box keeps them so.
//! tools/bench/dv0.py runs it at four stack alignments (the environment's size) and takes the min.
//!
//! Build: zig build-exe -OReleaseFast -lc --dep abi -Mroot=tools/bench/osdi_host.zig -Mabi=lib/osdi_dyn/abi.zig
//! Run:   ./osdi_host path/to/device.osdi
const std = @import("std");
const abi = @import("abi");

extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: *anyopaque, name: [*:0]const u8) ?*anyopaque;
extern "c" fn dlerror() ?[*:0]const u8;
extern "c" fn calloc(n: usize, size: usize) ?*anyopaque;

const calc_all: u32 = 1 | 2 | 4 | 8 | 64 | 128;
const analysis_dc: u32 = 2048 | 32768;

var h: u64 = 0xcbf29ce484222325;
fn mixU(v: u64) void {
    h = (h ^ v) *% 0x100000001b3;
}
fn mixF(xs: []const f64) void {
    for (xs) |v| mixU(@bitCast(v));
}
fn now() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
fn zeroed(comptime T: type, n: usize) []T {
    const p: [*]T = @ptrCast(@alignCast(calloc(@max(n, 1), @sizeOf(T)) orelse @panic("calloc")));
    return p[0..n];
}
fn logLine(_: ?*anyopaque, msg: [*:0]const u8, lvl: u32) callconv(.c) void {
    mixU(lvl);
    var i: usize = 0;
    while (msg[i] != 0) : (i += 1) mixU(msg[i]);
}

pub fn main(init: std.process.Init.Minimal) void {
    const path = init.args.vector[1];
    const lib = dlopen(path, 2) orelse {
        std.debug.print("dlopen: {s}\n", .{dlerror() orelse "?"});
        return;
    };
    const d: *const abi.Descriptor = @ptrCast(@alignCast(dlsym(lib, "OSDI_DESCRIPTORS").?));
    const log_slot: *?*const fn (?*anyopaque, [*:0]const u8, u32) callconv(.c) void = @ptrCast(@alignCast(dlsym(lib, "osdi_log").?));
    log_slot.* = &logLine;
    const n = d.num_nodes;
    const nj = d.num_jacobian_entries;

    // The descriptor's own tables.
    mixU(n);
    mixU(d.num_terminals);
    mixU(nj);
    mixU(d.num_params);
    mixU(d.num_instance_params);
    mixU(d.num_noise_src);
    mixU(d.num_collapsible);
    for (0..d.num_params) |i| {
        const p = d.param_opvar[i];
        mixU(p.flags);
        mixU(p.num_alias);
        var k: usize = 0;
        const name = p.name[0].?;
        while (name[k] != 0) : (k += 1) mixU(name[k]);
    }
    for (0..nj) |k| {
        mixU(d.jacobian_entries[k].nodes.node_1);
        mixU(d.jacobian_entries[k].nodes.node_2);
        mixU(d.jacobian_entries[k].flags);
    }

    const null_name = [_]abi.Str{null};
    const paras: abi.SimParas = .{ .names = &null_name, .vals = null, .names_str = &null_name, .vals_str = null };
    var iter_ns: u64 = std.math.maxInt(u64);
    var part_ns: [3]u64 = @splat(std.math.maxInt(u64));
    for (0..2) |card| {
        const model = zeroed(u8, d.model_size);
        const inst = zeroed(u8, d.instance_size);
        var info: abi.InitInfo = .{ .flags = 0, .num_errors = 0, .errors = null };
        if (card == 1) {
            // Read the defaults back from a set-up model, then give every 7th real parameter 1.03 times its default.
            const probe = zeroed(u8, d.model_size);
            d.setup_model(null, probe.ptr, &paras, &info);
            var i: u32 = d.num_instance_params;
            while (i < d.num_params) : (i += 7) {
                if (d.param_opvar[i].flags & 3 != abi.para_ty_real) continue;
                const src: *const f64 = @ptrCast(@alignCast(d.access(null, probe.ptr, i, 0).?));
                mixF(&.{src.*});
                const dst: *f64 = @ptrCast(@alignCast(d.access(null, model.ptr, i, abi.access_flag_set).?));
                dst.* = src.* * 1.03;
            }
        }
        d.setup_model(null, model.ptr, &paras, &info);
        mixU(info.flags);
        d.setup_instance(null, inst.ptr, model.ptr, 300.15, d.num_terminals, &paras, &info);
        mixU(info.flags);
        const map: [*]u32 = @ptrCast(@alignCast(inst.ptr + d.node_mapping_offset));
        for (0..n) |i| map[i] = @intCast(i);
        const mat = zeroed(f64, nj);
        const mat_q = zeroed(f64, nj);
        const jp: [*]?*f64 = @ptrCast(@alignCast(inst.ptr + d.jacobian_ptr_resist_offset));
        for (0..nj) |k| {
            jp[k] = &mat[k];
            const off = d.jacobian_entries[k].react_ptr_off;
            if (off != abi.no_off) @as(*?*f64, @ptrCast(@alignCast(inst.ptr + off))).* = &mat_q[k];
        }
        const x = zeroed(f64, n + 1);
        const st0 = zeroed(f64, d.num_states + 1);
        const st1 = zeroed(f64, d.num_states + 1);
        const out = zeroed(f64, n + 1);
        const arr = zeroed(f64, nj + 1);
        const dens = zeroed(f64, d.num_noise_src + 1);
        for (0..3) |pt| {
            for (x, 0..) |*v, i| v.* = 0.15 + 0.11 * @as(f64, @floatFromInt((i * 7 + pt * 3) % 6)) + 0.01 * @as(f64, @floatFromInt(pt));
            for ([_]u32{ calc_all | analysis_dc, calc_all | abi.analysis_tran | abi.enable_lim, calc_all | abi.analysis_tran | abi.init_lim }) |flags| {
                var sim: abi.SimInfo = .{ .paras = paras, .abstime = 1.0e-9 * @as(f64, @floatFromInt(pt)), .prev_solve = x.ptr, .prev_state = st0.ptr, .next_state = st1.ptr, .flags = flags };
                mixU(d.eval(null, inst.ptr, model.ptr, &sim));
                @memset(out, 0);
                d.load_residual_resist(inst.ptr, model.ptr, out.ptr);
                mixF(out);
                @memset(out, 0);
                d.load_residual_react(inst.ptr, model.ptr, out.ptr);
                mixF(out);
                @memset(out, 0);
                d.load_limit_rhs_resist(inst.ptr, model.ptr, out.ptr);
                mixF(out);
                @memset(out, 0);
                d.load_limit_rhs_react(inst.ptr, model.ptr, out.ptr);
                mixF(out);
                @memset(out, 0);
                d.load_spice_rhs_dc(inst.ptr, model.ptr, out.ptr, x.ptr);
                mixF(out);
                @memset(out, 0);
                d.load_spice_rhs_tran(inst.ptr, model.ptr, out.ptr, x.ptr, 1.0e9);
                mixF(out);
                @memset(mat, 0);
                @memset(mat_q, 0);
                d.load_jacobian_resist(inst.ptr, model.ptr);
                mixF(mat);
                d.load_jacobian_react(inst.ptr, model.ptr, 2.0e6);
                mixF(mat_q);
                @memset(mat, 0);
                d.load_jacobian_tran(inst.ptr, model.ptr, 1.0e9);
                mixF(mat);
                @memset(arr, 0);
                d.write_jacobian_array_resist(inst.ptr, model.ptr, arr.ptr);
                mixF(arr);
                @memset(arr, 0);
                d.write_jacobian_array_react(inst.ptr, model.ptr, arr.ptr);
                mixF(arr);
                if (d.num_noise_src > 0) {
                    @memset(dens, 0);
                    d.load_noise(inst.ptr, model.ptr, 1.0e3, dens.ptr);
                    mixF(dens);
                }
            }
        }
        // One transient iterate, as a simulator's load loop calls it.
        var sim: abi.SimInfo = .{ .paras = paras, .abstime = 1.0e-9, .prev_solve = x.ptr, .prev_state = st0.ptr, .next_state = st1.ptr, .flags = calc_all | abi.analysis_tran };
        // Each timed loop runs about 2 ms (3000 to 30000 iterates for a small device, fewer for a
        // large one, at least 20): a calibration of 16 warm iterates sets the count.
        var per: u64 = 1;
        for (0..2) |_| { // the first pass warms the caches and the predictors; the second counts
            const cal0 = now();
            for (0..16) |_| {
                std.mem.doNotOptimizeAway(d.eval(null, inst.ptr, model.ptr, &sim));
                d.load_spice_rhs_tran(inst.ptr, model.ptr, out.ptr, x.ptr, 1.0e9);
                d.load_jacobian_tran(inst.ptr, model.ptr, 1.0e9);
            }
            per = @max((now() - cal0) / 16, 1);
        }
        const reps: usize = std.math.clamp(2_000_000 / per, 20, @as(u64, if (nj > 500) 3000 else 30000));
        for (0..5) |_| {
            const t0 = now();
            for (0..reps) |r| {
                x[0] = 0.15 + 1.0e-7 * @as(f64, @floatFromInt(r & 15));
                std.mem.doNotOptimizeAway(x.ptr);
                std.mem.doNotOptimizeAway(d.eval(null, inst.ptr, model.ptr, &sim));
                d.load_spice_rhs_tran(inst.ptr, model.ptr, out.ptr, x.ptr, 1.0e9);
                d.load_jacobian_tran(inst.ptr, model.ptr, 1.0e9);
                std.mem.doNotOptimizeAway(out.ptr);
                std.mem.doNotOptimizeAway(mat.ptr);
            }
            iter_ns = @min(iter_ns, (now() - t0) / reps);
        }
        // The same three calls timed one at a time.
        for (0..5) |_| {
            inline for (0..3) |which| {
                const t0 = now();
                for (0..reps) |r| {
                    x[0] = 0.15 + 1.0e-7 * @as(f64, @floatFromInt(r & 15));
                    std.mem.doNotOptimizeAway(x.ptr);
                    switch (which) {
                        0 => std.mem.doNotOptimizeAway(d.eval(null, inst.ptr, model.ptr, &sim)),
                        1 => d.load_spice_rhs_tran(inst.ptr, model.ptr, out.ptr, x.ptr, 1.0e9),
                        else => d.load_jacobian_tran(inst.ptr, model.ptr, 1.0e9),
                    }
                    std.mem.doNotOptimizeAway(out.ptr);
                    std.mem.doNotOptimizeAway(mat.ptr);
                }
                part_ns[which] = @min(part_ns[which], (now() - t0) / reps);
            }
        }
    }
    std.debug.print("nodes {d} entries {d} params {d} instance_bytes {d} model_bytes {d} iterate_ns {d} (eval {d} rhs_tran {d} jac_tran {d}) checksum {x}\n", .{ n, nj, d.num_params, d.instance_size, d.model_size, iter_ns, part_ns[0], part_ns[1], part_ns[2], h });
}
