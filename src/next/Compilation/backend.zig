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
    if (!try checkTop(comp)) return false;
    // §3.4 a testbench card of a shape parameter is a compile-time value
    // (the old spine's `shapeCards`): elaborate again with it as a
    // `--param`, which a `--param` of the same name beats. Once: the
    // second pass finds every such card already given.
    if (try shapeCards(comp)) {
        comp.analysis.?.deinit(comp.gpa);
        comp.analysis = null;
        comp.zcu.deinit();
        comp.zcu = try .init(comp.gpa);
        if (!try frontend.semaTop(comp)) return false;
        return semaAnalog(comp);
    }
    // VAMS §7, §8: a mixed design's digital half, for the §8 runner.
    if (a.mixed and (comp.config.target == .exe or comp.config.target == .run)) {
        const sources = try comp.arena().alloc(sema.digital.Source, comp.units.items.len);
        const out = try comp.arena().create(vams.Preprocessor.Output);
        out.* = comp.pp.output();
        for (sources, comp.units.items) |*s, *u| s.* = .{ .tree = &u.tree, .pp = out };
        var why: sema.digital.Why = .{};
        comp.analysis.?.digital = sema.digital.lower(comp.arena(), zcu, .{ .sources = sources, .mixed = true }, &why) catch |e| switch (e) {
            // The §8 runner has no digital half to run: not built, named.
            error.Unsupported => {
                try frontend.notBuilt(comp, .exe, try comp.arena().print("the mixed-signal testbench's digital half ({s})", .{why.text}));
                return false;
            },
            error.Rejected => {
                try comp.wip.add(.lower, why.code, errors.relocate(out.*, why.at, why.at), "{s}", .{why.text});
                return false;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
    return true;
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
        .zig, .exe => {},
        .verilog => return notBuilt(comp, b, "the behavioural Verilog backend (--emit-verilog)"),
        .osdi => return notBuilt(comp, b, "the OSDI backend (--emit-osdi)"),
        .rtlil => return rtlilText(comp),
        .digital_device => return digitalDevice(comp),
        .digital_exe => return digitalExe(comp),
        .libmap => unreachable, // Refused before preprocessing.
        .digital_lowering => unreachable, // A stage, not a backend: `semaDigital` names it.
    }
    const an = &comp.analysis.?;
    // §8: the mixed runner needs the digital half Sema lowers beside it.
    if (b == .exe and an.mixed and an.digital == null) return notBuilt(comp, b, "the mixed-signal testbench (VAMS §8, a design with a digital half)");
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
    if (b == .exe) return testbench(comp);
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
    const engine = try deviceModules(comp);
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
            const f: link_mod.File = .{ .kind = .check, .work_dir = dir, .name = "check", .optimize = c.optimize, .modules = engine, .zig_exe = c.zig_exe, .check_pause = c.check_pause };
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
            const mods = try std.mem.concat(a, link_mod.Module, &.{ engine, &.{.{ .name = "dyn", .root = dyn, .deps = &.{"contract"} }} });
            const f: link_mod.File = .{ .kind = .so, .work_dir = wd, .name = try link_mod.fileStem(a, top), .optimize = c.optimize, .modules = mods, .zig_exe = c.zig_exe, .debug_info = c.debug_info };
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
    if (comp.config.target == .rtlil and try rtlilRefused(comp, out.*)) return null;
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
    const result = std_sim.exe.run(&s);
    try comp.outputs.out.appendSlice(comp.arena(), out.written());
    try std_sim.exe.report(&s, result, &comp.wip, try checkSites(comp));
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

/// `.v --emit-exe`: an executable that runs the lowered Program through
/// `std_sim.exe`, as `--run` does (`codegen.digital_next.writeExe`), built
/// through `link` under `--work-dir` (default `.zig-cache/vera-tb`), named
/// for the input's stem; `main` prints its path.
fn digitalExe(comp: *Compilation) !?Job {
    const c = comp.config;
    const a = comp.arena();
    const all = try comp.sources();
    const sources = try a.alloc(std_sim.exe.Source, all.len);
    for (sources, all) |*s, d| s.* = .{ .name = d.name, .text = d.text };
    var root: Io.Writer.Allocating = .init(a);
    try codegen_mod.digital_next.writeExe(&root.writer, a, &comp.lowered.?.program, sources, try checkSites(comp), c.event_budget);
    const slots = try a.alloc(link_mod.Server, c.thread_limit);
    var q: link_mod.Queue = .init(slots);
    const tree = std.fs.path.dirname(std.fs.path.dirname(c.contract.?) orelse ".") orelse ".";
    const mods = [_]link_mod.Module{
        .{ .name = "std_sim", .root = try std.fs.path.join(a, &.{ tree, "lib", "std", "sim.zig" }), .deps = &.{ "kernels", "contract", "vams" } },
        .{ .name = "kernels", .root = try std.fs.path.join(a, &.{ tree, "lib", "kernels", "root.zig" }), .deps = &.{"contract"} },
        .{ .name = "contract", .root = c.contract.? },
        .{ .name = "vams", .root = try std.fs.path.join(a, &.{ tree, "lib", "std", "vams.zig" }) },
    };
    const f: link_mod.File = .{ .kind = .exe, .work_dir = c.work_dir orelse ".zig-cache/vera-tb", .name = std.fs.path.stem(c.paths[0]), .optimize = c.optimize, .modules = &mods, .zig_exe = c.zig_exe, .debug_info = c.debug_info, .out_path = c.out_path };
    var built = link_mod.buildExe(f, comp.gpa, comp.io, &q, null, root.written()) catch |e| {
        try comp.outputs.err.print(a, "error: {s}: building the executable failed: {t}\n", .{ c.paths[0], e });
        comp.outputs.status = 1;
        return null;
    };
    defer built.deinit(comp.gpa);
    switch (built) {
        .ok => |p| comp.outputs.exe = try a.dupe(u8, p),
        .failed => |bundle| {
            try comp.outputs.err.print(a, "error: {s}: the generated executable does not compile — this is an engine bug, not a problem with the design:\n", .{c.paths[0]});
            var w: Io.Writer.Allocating = .init(a);
            try bundle.renderToWriter(.{}, &w.writer);
            try comp.outputs.err.appendSlice(a, w.written());
            comp.outputs.status = 1;
        },
    }
    return null;
}

/// `--emit-rtlil`'s refusal (`codegen.rtlil.refusal`), read from the
/// files' Vir before the lowering as the old emitter read its own parse:
/// reported, and true, when the design is outside the subset.
fn rtlilRefused(comp: *Compilation, out: vams.Preprocessor.Output) !bool {
    const a = comp.arena();
    const trees = try a.alloc(*const vams.Ast, comp.units.items.len);
    for (trees, comp.units.items) |*t, *u| t.* = &u.tree;
    const s = try sema.digital.sites.collect(a, &comp.zcu, trees);
    const r = (try codegen_mod.rtlil.refusal(a, &s)) orelse return false;
    try comp.wip.add(.codegen, r.code, errors.relocate(out, r.at, r.at), "{s}", .{r.detail});
    return true;
}

/// `--emit-rtlil`'s text (`codegen.rtlil.emit`, over the lowered design and
/// `Zcu.instances`' parents and names) to `-o`, else on stdout.
fn rtlilText(comp: *Compilation) !?Job {
    const a = comp.arena();
    const zi = comp.zcu.instances.slice();
    const parent = try a.alloc(u32, zi.len);
    const name = try a.alloc([]const u8, zi.len);
    for (parent, name, zi.items(.parent), zi.items(.name)) |*p, *n, zp, zn| {
        p.* = @backingInt(zp);
        n.* = comp.zcu.intern_pool.stringToSlice(zn);
    }
    var text: Io.Writer.Allocating = .init(a);
    codegen_mod.rtlil.emit(&text.writer, a, .{ .lowered = &comp.lowered.?, .parent = parent, .name = name }) catch |e| switch (e) {
        error.Unsupported => return notBuilt(comp, .rtlil, "the RTLIL text of a shape outside the subset"),
        error.OutOfMemory, error.WriteFailed => |x| return x,
    };
    comp.device = .{ .text = try comp.gpa.dupe(u8, text.written()) };
    try writeText(comp);
    return null;
}

/// A `.v` top as a contract device (`codegen.digital_next.writeDevice`):
/// E1103 when it cannot be one, W1155 when its tick is 1 s, then the
/// target's link (`--check`, `--emit-so`) or the text (`--emit-zig`).
fn digitalDevice(comp: *Compilation) !?Job {
    const c = comp.config;
    const a = comp.arena();
    const dn = codegen_mod.digital_next;
    if (c.target == .osdi) return notBuilt(comp, .digital_device, "the digital device backend (a .v --emit-osdi)");
    const l = &comp.lowered.?;
    const ports = try topPorts(comp);
    const top = comp.zcu.intern_pool.stringToSlice(comp.zcu.instances.items(.name)[0]);
    const at = topLoc(comp);
    if (dn.deviceRefusal(&l.program, ports)) |why| {
        try comp.wip.add(.lower, .E1103, at, "module `{s}`: {s}", .{ top, why });
        return null;
    }
    if (l.program.finest == 0) try comp.wip.add(.lower, .W1155, at, "module `{s}`: no `timescale sets a finer precision", .{top});
    var text: Io.Writer.Allocating = .init(a);
    try dn.writeDevice(&text.writer, a, &l.program, ports);
    assert(text.written().len != 0);
    comp.device = .{ .text = try comp.gpa.dupe(u8, text.written()) };
    if (c.check or c.target == .check) return .{ .link = .check };
    if (c.target == .so) return .{ .link = .so };
    try writeText(comp);
    return null;
}

/// The root's ports as the device reads them (`Lowered.ports`).
fn topPorts(comp: *Compilation) ![]const codegen_mod.digital_next.Port {
    const l = &comp.lowered.?;
    const out = try comp.arena().alloc(codegen_mod.digital_next.Port, l.ports.len);
    for (out, l.ports) |*o, p| o.* = .{ .name = p.name, .dir = switch (p.dir) {
        .input => .input,
        .output => .output,
        .inout => .inout,
    }, .slot = p.slot, .ty = p.ty, .msb = p.msb, .lsb = p.lsb, .scalar = p.scalar, .integer = p.integer };
    return out;
}

/// Where the device's diagnostics point: the root module's `module`
/// keyword (`Lowered.top_at`).
fn topLoc(comp: *Compilation) vams.Diag.Loc {
    const at = comp.lowered.?.top_at;
    return errors.relocate(comp.pp.output(), at, at);
}

/// The modules a device compiles against: `engineModules`, and for a `.v`
/// one `std_sim` and what it imports, from the same tree.
fn deviceModules(comp: *Compilation) ![]const link_mod.Module {
    const a = comp.arena();
    const contract = comp.config.contract.?;
    const engine = try engineModules(a, contract);
    if (comp.lowered == null) return a.dupe(link_mod.Module, &engine);
    const tree = std.fs.path.dirname(std.fs.path.dirname(contract) orelse ".") orelse ".";
    return a.dupe(link_mod.Module, &[_]link_mod.Module{
        engine[0],
        .{ .name = "std_sim", .root = try std.fs.path.join(a, &.{ tree, "lib", "std", "sim.zig" }), .deps = &.{ "kernels", "contract", "vams" } },
        .{ .name = "kernels", .root = try std.fs.path.join(a, &.{ tree, "lib", "kernels", "root.zig" }), .deps = &.{"contract"} },
        .{ .name = "vams", .root = try std.fs.path.join(a, &.{ tree, "lib", "std", "vams.zig" }) },
    });
}

/// Each timing check's W1199 site (`Lowered.check_sites`), relocated to
/// the file the user wrote.
fn checkSites(comp: *Compilation) ![]const vams.Diag.Loc {
    const l = &comp.lowered.?;
    const pp = comp.pp.output();
    const out = try comp.arena().alloc(vams.Diag.Loc, l.check_sites.len);
    for (out, l.check_sites) |*o, site| o.* = errors.relocate(pp, site, site);
    return out;
}

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

/// `--emit-exe`/`--run`: the runner over the device (`codegen.bench`),
/// built beside it through `link` as the old spine did (under
/// `--work-dir`, default `.zig-cache/vera-tb`, named for the top module);
/// `main` prints the binary's path or runs it.
fn testbench(comp: *Compilation) !?Job {
    const c = comp.config;
    const a = comp.arena();
    const bench = codegen_mod.bench;
    const spec = &comp.bench.?;
    const an = &comp.analysis.?;
    // The mixed runner places a point at each event; the fixed grid does not.
    if (!an.mixed) if (bench.gridEvent(&an.air)) |i| {
        const s = an.srcs[@backingInt(i)];
        const loc: vams.Diag.Loc = if (s.src == .none) .none else errors.instLoc(comp.pp.output(), &comp.units.items[@backingInt(s.file)], s.src);
        try comp.wip.add(.codegen, .W0750, loc, "the testbench inserts no timepoint at it", .{});
        // `--deny=W0750` refuses before anything is built.
        if (comp.wip.failed()) return null;
    };
    var facts = try bench.facts(a, &an.device);
    facts.validate_contract = c.validate_contract;
    if (an.mixed) {
        const low = &an.digital.?;
        const names = try a.alloc(bench.Digital.Name, low.names.len);
        for (names, low.names) |*n, x| n.* = .{ .path = x.path, .slot = x.slot, .real = x.ty.real };
        var unresolved: []const u8 = "";
        facts.mixed = bench.digital(a, &low.program, names, &an.device, &comp.zcu.intern_pool, &unresolved) catch |e| {
            if (e == error.UnknownProbe) try comp.wip.add(.lower, .E0901, .none, "`{s}` names no net or branch in the elaborated design", .{unresolved});
            return if (e == error.UnknownProbe) null else error.OutOfMemory;
        };
    }
    var runner: Io.Writer.Allocating = .init(a);
    bench.writeRunner(&runner.writer, std.fs.path.stem(c.paths[0]), &spec.bench, facts) catch |e| switch (e) {
        error.TooManyPoints => return refuse(comp, 2, try a.print("error: {s}: `//!` directive: the sweeps expand to more than {d} points\n", .{ c.paths[0], bench.points_max })),
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };
    const slots = try a.alloc(link_mod.Server, c.thread_limit);
    var q: link_mod.Queue = .init(slots);
    const engine = try engineModules(a, c.contract.?);
    // The runner is `std_sim.bench` (and the old `kernels` `std_sim`
    // imports), from the same tree as the contract.
    const tree = std.fs.path.dirname(std.fs.path.dirname(c.contract.?) orelse ".") orelse ".";
    const sim_mods = engine ++ [_]link_mod.Module{
        .{ .name = "std_sim", .root = try std.fs.path.join(a, &.{ tree, "lib", "std", "sim.zig" }), .deps = &.{ "kernels", "contract" } },
        .{ .name = "kernels", .root = try std.fs.path.join(a, &.{ tree, "lib", "kernels", "root.zig" }), .deps = &.{"contract"} },
    };
    const top = comp.zcu.intern_pool.stringToSlice(comp.zcu.instances.items(.name)[0]);
    const f: link_mod.File = .{ .kind = .exe, .work_dir = c.work_dir orelse ".zig-cache/vera-tb", .name = top, .optimize = c.optimize, .modules = &sim_mods, .zig_exe = c.zig_exe, .debug_info = c.debug_info, .out_path = c.out_path };
    var built = link_mod.buildExe(f, comp.gpa, comp.io, &q, comp.device.?.text, runner.written()) catch |e| {
        try comp.outputs.err.print(a, "error: {s}: building the testbench failed: {t}\n", .{ c.paths[0], e });
        comp.outputs.status = 1;
        return null;
    };
    defer built.deinit(comp.gpa);
    switch (built) {
        .ok => |p| {
            comp.outputs.exe = try a.dupe(u8, p);
            comp.outputs.plusargs = spec.harness.plusargs;
        },
        .failed => |bundle| {
            try comp.outputs.err.print(a, "error: {s}: the generated testbench does not compile — this is an engine bug, not a problem with the model:\n", .{c.paths[0]});
            var w: Io.Writer.Allocating = .init(a);
            try bundle.renderToWriter(.{}, &w.writer);
            try comp.outputs.err.appendSlice(a, w.written());
            comp.outputs.status = 1;
        },
    }
    return null;
}

/// Appends each `//! param` card naming one of the root's shape
/// parameters (`Zcu.shape_params`) that no override names to the config's
/// overrides; whether it appended one.
fn shapeCards(comp: *Compilation) Allocator.Error!bool {
    const spec = comp.bench orelse return false;
    const ip = &comp.zcu.intern_pool;
    var all: std.ArrayList(Compilation.Config.Override) = .empty;
    try all.appendSlice(comp.arena(), comp.config.overrides);
    for (spec.bench.params) |card| {
        const shape = for (comp.zcu.shape_params.keys()) |n| {
            if (std.mem.eql(u8, ip.stringToSlice(n), card.name)) break true;
        } else false;
        if (!shape) continue;
        const given = for (all.items) |o| {
            if (std.mem.eql(u8, o.name, card.name)) break true;
        } else false;
        if (!given) try all.append(comp.arena(), .{ .name = card.name, .text = try comp.arena().print("{d}", .{card.value}), .value = card.value });
    }
    assert(all.items.len >= comp.config.overrides.len);
    if (all.items.len == comp.config.overrides.len) return false;
    comp.config.overrides = all.items;
    return true;
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
    try frontend.notBuilt(comp, .digital_lowering, what);
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
