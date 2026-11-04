//! The jobs after elaboration: the analog lowering (answering its
//! `$table_model` data requests), the float verdict, the backend dispatch
//! with one prong per backend of lib/TODO.md §5, the link through one
//! `link.Queue` sized by `thread_limit`, and the digital lowering and run.
//! A backend that is not merged yet reports "not built" (exit status 126,
//! `frontend.notBuilt`), so the fixtures that need it are named, never
//! silently skipped. `--check` type-checks under a scratch directory of
//! its own, removed afterwards (lib/TODO.md §12: concurrent checks of one
//! model in one directory raced on a fixed path).
//!
//! Cites: VAMS-2023 §3.4 (`--param`), §9.21.1 (`$table_model` files),
//! §5.6.1.3 (the float units); IEEE 1364-2005 §12.1.3 (`--elab`), §15.5
//! (W1199), §17 (the run's transcript).
//!
//! Contents:
//! - `pub fn semaAnalog(comp: *Compilation) !bool`
//! - `pub fn airPasses(comp: *Compilation) !bool`
//! - `pub fn analogBackend(comp: *Compilation) !?Job`
//! - `pub fn codegen(comp: *Compilation, b: Compilation.Backend) !?Job`
//! - `pub fn link(comp: *Compilation, task: @FieldType(Job, "link")) !?Job`
//! - `pub fn semaDigital(comp: *Compilation) !?Job`
//! - `pub fn runDigital(comp: *Compilation) !?Job`
//! - `pub fn scratchDir(comp: *Compilation) ![]const u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const vams = @import("vams");
const sema = @import("sema");
const Air = @import("air");
const codegen_mod = @import("codegen");
const link_mod = @import("link");
const std_sim = @import("std_sim");
const Compilation = @import("../Compilation.zig");
const frontend = @import("frontend.zig");
const errors = @import("errors.zig");
const Job = Compilation.Job;

/// Lowers the root and everything below it (docs/rewrite/lower.md),
/// answering each data file it asks for: the name as written, then each
/// include directory. Checks `--param` and `--expect-module` against it.
pub fn semaAnalog(comp: *Compilation) !bool {
    const zcu = &comp.zcu;
    var asked: u32 = 0;
    const a = while (asked <= frontend.requests_max) : (asked += 1) {
        if (try sema.Sema.analyze(zcu)) |a| break a;
        const want = zcu.data_want orelse return false;
        try zcu.answerData(try findData(comp, want));
    } else return error.OutOfMemory;
    comp.analysis = a;
    return checkTop(comp);
}

/// The float verdict over codegen's roots (§11.9), each parameter's
/// ranges its box; a §4.3.2 error stops here.
pub fn airPasses(comp: *Compilation) !bool {
    const an = &comp.analysis.?;
    const a = comp.arena();
    const roots = try codegen_mod.floatRoots(a, &an.air, &an.device);
    const params = try a.alloc(Air.Float.Param, an.device.params.len);
    for (params, 0..) |*p, k| p.* = .{ .ranges = try floatRanges(a, an.device.paramRanges(@fromBackingInt(@intCast(k)))) };
    // Where each instruction's diagnostic points: the expression Sema
    // lowered it from.
    const locs = try a.alloc(vams.Diag.Loc, an.srcs.len);
    for (locs, an.srcs) |*l, s| l.* = if (s.src == .none) .none else errors.instLoc(comp.pp.output(), &comp.units.items[@backingInt(s.file)], s.src);
    comp.float = try Air.Float.analyze(comp.gpa, an.air, &comp.zcu.intern_pool, .{
        .params = params,
        .roots = roots,
        .locs = locs,
        .unknown_bound = comp.config.unknown_bound,
    }, &comp.wip);
    return !comp.wip.failed();
}

/// The backend the target names (`--lint` stops here).
pub fn analogBackend(comp: *Compilation) !?Job {
    return switch (comp.config.target) {
        .lint => null,
        .zig, .check, .so => .{ .codegen = .zig },
        .exe, .run => .{ .codegen = .exe },
        .verilog => .{ .codegen = .verilog },
        .osdi => .{ .codegen = .osdi },
        .elab, .rtlil => unreachable, // `main` refuses these for a `.va`.
    };
}

/// One backend over the analysed device; only `zig` is merged.
pub fn codegen(comp: *Compilation, b: Compilation.Backend) !?Job {
    const c = comp.config;
    switch (b) {
        .zig => {},
        .exe => return notBuilt(comp, b, "the analog testbench (--emit-exe, --run)"),
        .verilog => return notBuilt(comp, b, "the behavioural Verilog backend (--emit-verilog)"),
        .osdi => return notBuilt(comp, b, "the OSDI backend (--emit-osdi)"),
        .rtlil => return notBuilt(comp, b, "the RTLIL backend (--emit-rtlil)"),
        .digital_device => return notBuilt(comp, b, "the digital device backend (a .v --emit-zig, --check, --emit-so)"),
        .digital_exe => return notBuilt(comp, b, "the native digital executable (a .v --emit-exe)"),
        .libmap => unreachable, // Refused before preprocessing.
    }
    const an = &comp.analysis.?;
    var r = try codegen_mod.generate(comp.gpa, .zig, .{
        .air = &an.air,
        .ip = &comp.zcu.intern_pool,
        .device = &an.device,
        .verdict = &comp.float.?.verdict,
    }, .{});
    switch (r) {
        .fail => |why| {
            defer r.deinit(comp.gpa);
            _ = why;
            try comp.outputs.err.print(comp.arena(), "error: {s}: codegen refused a construct; generated output is not usable\n", .{c.paths[0]});
            comp.outputs.status = 1;
            return null;
        },
        .ok => |out| comp.device = out,
    }
    if (c.check or c.target == .check) return .{ .link = .check };
    if (c.target == .so) return .{ .link = .so };
    try writeText(comp);
    return null;
}

/// `--check` or `--emit-so` of the device, through a `link.Queue` of
/// `thread_limit` slots.
pub fn link(comp: *Compilation, task: @FieldType(Job, "link")) !?Job {
    const c = comp.config;
    const a = comp.arena();
    const slots = try a.alloc(link_mod.Server, c.thread_limit);
    var q: link_mod.Queue = .init(slots);
    const engine = try engineModules(a, c.contract.?);
    switch (task) {
        .check => {
            const dir = scratchDir(comp) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => |io_error| {
                    try comp.outputs.err.print(a, "error: {s}: cannot create the check's scratch directory: {t}\n", .{ c.paths[0], io_error });
                    comp.outputs.status = 1;
                    return null;
                },
            };
            defer Io.Dir.cwd().deleteTree(comp.io, dir) catch {};
            var err: Io.Writer.Allocating = .init(a);
            const f: link_mod.File = .{ .kind = .check, .work_dir = dir, .name = "check", .optimize = c.optimize, .modules = &engine, .zig_exe = c.zig_exe, .check_pause = c.check_pause };
            const v = link_mod.typeCheck(f, comp.gpa, comp.io, &q, comp.device.?.text, c.paths[0], &err.writer) catch |e| {
                try comp.outputs.err.print(a, "error: {s}: type check failed: {t}\n", .{ c.paths[0], e });
                comp.outputs.status = 1;
                return null;
            };
            try comp.outputs.err.appendSlice(a, err.written());
            if (v == .fails) {
                comp.outputs.status = 1;
                return null;
            }
            if (c.target == .so) return .{ .link = .so };
            if (c.target == .zig) try writeText(comp);
            return null;
        },
        .so => {
            const wd = c.work_dir orelse return refuse(comp, 2, "error: --emit-so needs --work-dir DIR\n");
            const dyn = c.dyn orelse return refuse(comp, 2, "error: --emit-so needs --dyn PATH\n");
            const top = comp.zcu.intern_pool.stringToSlice(comp.zcu.instances.items(.name)[0]);
            const mods = engine ++ [_]link_mod.Module{.{ .name = "dyn", .root = dyn, .deps = &.{"contract"} }};
            const f: link_mod.File = .{ .kind = .so, .work_dir = wd, .name = try link_mod.fileStem(a, top), .optimize = c.optimize, .modules = &mods, .zig_exe = c.zig_exe, .debug_info = c.debug_info };
            var built = f.flush(comp.gpa, comp.io, &q, comp.device.?, 1) catch |e| {
                try comp.outputs.err.print(a, "error: {s}: building the device failed: {t}\n", .{ c.paths[0], e });
                comp.outputs.status = 1;
                return null;
            };
            defer built.deinit(comp.gpa);
            switch (built) {
                .ok => |p| try comp.outputs.out.print(a, "{s}\n", .{p}),
                .failed => |bundle| {
                    try comp.outputs.err.print(a, "error: {s}: the generated device did not compile:\n", .{c.paths[0]});
                    var w: Io.Writer.Allocating = .init(a);
                    try bundle.renderToWriter(.{}, &w.writer);
                    try comp.outputs.err.appendSlice(a, w.written());
                    comp.outputs.status = 1;
                },
            }
            if (c.zig) try writeText(comp);
            return null;
        },
    }
}

/// The digital lowering (docs/rewrite/dlower.md) of the elaborated
/// design, then the target's job: `--run` runs it, `--elab` stops.
pub fn semaDigital(comp: *Compilation) !?Job {
    const sources = try comp.arena().alloc(sema.digital.Source, comp.units.items.len);
    const out = try comp.arena().create(vams.Preprocessor.Output);
    out.* = comp.pp.output();
    for (sources, comp.units.items) |*s, *u| s.* = .{ .tree = &u.tree, .pp = out };
    var why: sema.digital.Why = .{};
    comp.lowered = sema.digital.lower(comp.arena(), &comp.zcu, .{ .sources = sources }, &why) catch |e| switch (e) {
        error.Unsupported => return notBuiltFmt(comp, "the digital lowering", why.text),
        error.Rejected => {
            // A refusal before the run: a compile error, under the summary.
            try comp.wip.add(.lower, why.code, errors.relocate(out.*, why.at, why.at), "{s}", .{why.text});
            return null;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return switch (comp.config.target) {
        .run => .run_digital,
        .elab => null,
        .exe => .{ .codegen = .digital_exe },
        .zig, .check, .so, .osdi => .{ .codegen = .digital_device },
        .rtlil => .{ .codegen = .rtlil },
        .lint, .verilog => unreachable, // `main` refuses these for a `.v`.
    };
}

/// Runs the lowered program in `std_sim` (IEEE 1364-2005 §17's
/// transcript on stdout) on a 1 GiB stack, as the activations nest; a
/// run-time error is E1100, a violated timing check W1199.
pub fn runDigital(comp: *Compilation) !?Job {
    const l = &comp.lowered.?;
    var out: Io.Writer.Allocating = .init(comp.arena());
    var s: std_sim.State = std_sim.State.init(comp.arena(), &l.program, &out.writer) catch |e| switch (e) {
        error.SimFailed => unreachable, // `init` lays out tables; only a run fails.
        error.OutOfMemory, error.WriteFailed => |x| return x,
    };
    s.budget = comp.config.event_budget;
    s.io = comp.io;
    var result: std_sim.State.Error!void = {};
    const t = try std.Thread.spawn(.{ .stack_size = 1 << 30 }, struct {
        fn go(st: *std_sim.State, r: *std_sim.State.Error!void) void {
            r.* = std_sim.Interp.run(st);
        }
    }.go, .{ &s, &result });
    t.join();
    std_sim.files.closeAll(&s);
    try comp.outputs.out.appendSlice(comp.arena(), out.written());
    const pp = comp.pp.output();
    for (s.checks, l.check_sites) |ch, site| if (ch.count != 0) {
        try comp.wip.add(.run, .W1199, errors.relocate(pp, site, site), "a timing check reported a violation", .{});
    };
    result catch |e| switch (e) {
        error.SimFailed => try comp.wip.add(.run, .E1100, .none, "{s}", .{s.failure.?}),
        error.OutOfMemory, error.WriteFailed => |x| return x,
    };
    return null;
}

/// A directory no other invocation uses: `<base>/vera-<16 hex>`, under the
/// `-o` output's directory, else under `--work-dir` (default
/// `.zig-cache/vera-tb`). Created here; the caller removes it.
pub fn scratchDir(comp: *Compilation) ![]const u8 {
    const c = comp.config;
    const base = if (c.out_path) |o| (std.fs.path.dirname(o) orelse ".") else c.work_dir orelse ".zig-cache/vera-tb";
    var bytes: [8]u8 = undefined;
    comp.io.random(&bytes);
    const dir = try std.fs.path.join(comp.arena(), &.{ base, &std.fmt.bytesToHex(bytes, .lower) });
    try Io.Dir.cwd().createDirPath(comp.io, dir);
    assert(dir.len > base.len);
    return dir;
}

// ---- private ----

/// The modules a device compiles against, from the tree its `contract`
/// root sits in (`<tree>/lib/contract.zig`, `main`'s written tree):
/// `contract` first, then `std_kernels` and the Gompute math it imports
/// (`<tree>/gompute/math.zig`).
fn engineModules(a: Allocator, contract: []const u8) ![3]link_mod.Module {
    const tree = std.fs.path.dirname(std.fs.path.dirname(contract) orelse ".") orelse ".";
    return .{
        .{ .name = "contract", .root = contract },
        .{ .name = "std_kernels", .root = try std.fs.path.join(a, &.{ tree, "lib", "std", "kernels.zig" }), .deps = &.{ "contract", "gompute_math" } },
        .{ .name = "gompute_math", .root = try std.fs.path.join(a, &.{ tree, "gompute", "math.zig" }) },
    };
}

fn refuse(comp: *Compilation, status: u8, line: []const u8) !?Job {
    try comp.outputs.err.appendSlice(comp.arena(), line);
    comp.outputs.status = status;
    return null;
}

fn notBuilt(comp: *Compilation, b: Compilation.Backend, what: []const u8) !?Job {
    try frontend.notBuilt(comp, b, what);
    return null;
}

fn notBuiltFmt(comp: *Compilation, stage: []const u8, why: []const u8) !?Job {
    const what = try comp.arena().print("{s} of {s}", .{ stage, why });
    try frontend.notBuilt(comp, .digital_device, what);
    return null;
}

/// `--emit-zig`: the device to `-o`, else on stdout.
fn writeText(comp: *Compilation) !void {
    const text = comp.device.?.text;
    const p = comp.config.out_path orelse return comp.outputs.out.appendSlice(comp.arena(), text);
    Io.Dir.cwd().writeFile(comp.io, .{ .sub_path = p, .data = text }) catch |e| {
        try comp.outputs.err.print(comp.arena(), "error: cannot write `{s}`: {t}\n", .{ p, e });
        comp.outputs.status = 1;
    };
}

/// §9.21.1: `name` as written, then under each include directory; null
/// when none is there.
fn findData(comp: *Compilation, name: []const u8) !?[]const u8 {
    switch (try comp.read(name)) {
        .bytes => |b| return b,
        .failed => {},
    }
    for (comp.config.include_dirs) |d| switch (try comp.read(try std.fs.path.join(comp.arena(), &.{ d, name }))) {
        .bytes => |b| return b,
        .failed => {},
    };
    return null;
}

/// The old driver's checks of the analysed root: `--param` names a
/// parameter the card may set and gives a numeric one a number;
/// `--expect-module` names the root. A refusal is written on `err`.
fn checkTop(comp: *Compilation) !bool {
    const c = comp.config;
    const a = comp.arena();
    const ip = &comp.zcu.intern_pool;
    const dev = &comp.analysis.?.device;
    const top = ip.stringToSlice(comp.zcu.instances.items(.name)[0]);
    for (c.overrides) |ov| {
        const k = for (dev.params.items(.name), dev.params.items(.local), 0..) |n, local, k| {
            if (!local and std.mem.eql(u8, ip.stringToSlice(n), ov.name)) break k;
        } else {
            try comp.outputs.err.print(a, "error: --param {s}: `{s}` declares no parameter `{s}` that --param may set\n", .{ ov.name, top, ov.name });
            comp.outputs.status = 2;
            return false;
        };
        if (dev.params.items(.ty)[k] != .string and std.math.isNan(ov.value)) {
            try comp.outputs.err.print(a, "error: --param {s}={s}: `{s}` is not a number\n", .{ ov.name, ov.text, ov.text });
            comp.outputs.status = 2;
            return false;
        }
    }
    if (c.expect_module) |want| if (!std.mem.eql(u8, top, want)) {
        try comp.outputs.err.print(a, "error: {s}: Verilog-A module is `{s}` but `{s}` was expected — rename one of them\n", .{ c.paths[0], top, want });
        comp.outputs.status = 1;
        return false;
    };
    return true;
}

/// A parameter's `Device` ranges as `Float` reads them; a bound that does
/// not fold proves nothing.
fn floatRanges(a: Allocator, ranges: []const Air.Device.Range) ![]const Air.Interval.Range {
    var out: std.ArrayList(Air.Interval.Range) = .empty;
    for (ranges) |r| {
        if (r.strings) continue;
        try out.append(a, .{ .kind = if (r.exclude) .exclude else .from, .lo = r.lo, .hi = r.hi, .lo_inclusive = r.lo_closed, .hi_inclusive = r.hi_closed });
    }
    return out.items;
}
