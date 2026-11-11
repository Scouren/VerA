//! The rewrite's oracle steps (docs/rewrite/README.md): each new module held
//! to the code it replaces over the whole fixture corpus. `diff-parse`
//! (vams Ast/Parse vs lib/frontend's lexer and parser), `diff-pp` (vams
//! Preprocessor vs lib/frontend's preprocessor), `diff-diag` (vams Diag vs
//! lib/diag), `diff-air` (Air's interpreter vs src/ir's opcode folds),
//! `diff-air-passes` (the Air passes against Air's interpreter over
//! generated programs; `-Dfull-oracles` runs the nightly's full sweep),
//! `diff-sim` (sema's digital lowering run in std_sim vs lib/sim/digital
//! over every `.v`), `diff-link` (link vs src/zigbuild over the same device
//! builds),
//! `diff-astgen` (vams AstGen/Vir vs the old compiler's per-file codes and
//! design units), `diff-elab` (sema's elaboration vs src/elab and the
//! digital route's), `diff-lower` (sema's analog lowering vs src/analog,
//! values by the old MIR interpreter against Air's), `diff-codegen`
//! (codegen's Zig backend against src/codegen/device, both devices built
//! and run), `diff-kernels`
//! (std_kernels vs lib/kernels and the old kernel text; Gompute's math vs
//! gm), and
//! `rewrite`, which runs them and the new modules' own tests. All are in
//! `test`. `build.zig` calls `add` once.
//!
//! Contents:
//! - `pub fn add(g: Graph) void`

const std = @import("std");
const common = @import("common.zig");
const Build = std.Build;
const Graph = common.Graph;
const byName = common.byName;
const pathFromRoot = common.pathFromRoot;
const testRun = common.testRun;
const setSuiteEnv = common.setSuiteEnv;
/// `vera-next`, `diff-comp` and `conformance-next` (docs/rewrite/comp.md).
const comp = @import("rewrite_comp.zig");

pub fn add(g: Graph) void {
    const b = g.b;
    const mods = g.mods;
    // One description for every new module: each oracle names itself in its row below.
    const all = b.step("rewrite", "The rewrite's modules' tests (test-<module>) and every diff-* oracle below");
    for ([_][]const u8{ "vams", "intern_pool", "air", "link", "std_sim", "sema", "std_kernels", "codegen", "comp" }) |name| {
        all.dependOn(&b.top_level_steps.get(b.fmt("test-{s}", .{name})).?.step);
    }
    // `fixture_root`/`repo_root` are not here (R5, research/builds.md): a
    // worktree-specific absolute path baked in by `addOption` misses the
    // shared cache in every other worktree. `repo_env.zig` reads them from
    // the environment at run time; `setSuiteEnv` sets it on every diff Run
    // step below.
    const repo_env = g.m.make("tests/differential/repo_env.zig", &.{});
    const o = b.addOptions();
    o.addOption([]const u8, "lower_dump", b.option([]const u8, "lower-dump", "diff-lower: print both sides' tables of the fixtures whose path holds this") orelse "");
    // The merge tier runs a generated-program oracle at a size inside its
    // budget; the nightly passes `-Dfull-oracles` for the whole sweep.
    o.addOption(bool, "full_oracles", b.option(bool, "full-oracles", "diff-air-passes: the nightly's full sweep (10^4 programs x 10^3 points) instead of the merge tier's") orelse false);
    o.addOption([]const u8, "codegen_filter", b.option([]const u8, "codegen-filter", "diff-codegen: only the fixtures whose path holds one of these `|`-separated substrings") orelse "");
    o.addOption(bool, "codegen_keep", b.option(bool, "codegen-keep", "diff-codegen: keep the built devices under zig-out/codegen-work") orelse false);
    o.addOption(bool, "codegen_why", b.option(bool, "codegen-why", "diff-codegen: print why each fixture codegen.xfail names still differs") orelse false);
    // R2, research/builds.md: a directory per Zig store path (the flake's
    // `ZIG_GLOBAL_CACHE_DIR`), not this worktree's, so unlike the R5 fields
    // above this one is safe to compile in: every worktree on that store
    // path gets the same string and so the same cache key. Null (the
    // variable unset, outside `nix develop`) leaves every batch uncached,
    // today's behaviour.
    const default_codegen_cache = if (b.graph.environ_map.get("ZIG_GLOBAL_CACHE_DIR")) |dir| b.fmt("{s}/vera-codegen", .{dir}) else null;
    o.addOption(?[]const u8, "codegen_cache", b.option([]const u8, "codegen-cache", "diff-codegen: the built libraries' cache directory (default $ZIG_GLOBAL_CACHE_DIR/vera-codegen)") orelse default_codegen_cache);
    // diff-codegen builds devices that import std_kernels, which imports Gompute's math.
    o.addOptionPath("gompute_math", b.dependency("gompute", .{}).module("math").root_source_file.?);
    // `libc`: the root loads libraries (`dynlib` needs glibc on Linux).
    // `emit_zig`: fixtures whose `vera --emit-zig` text the root reads from
    // the directory `rewrite_options.emitted`, as `<stem>.zig`.
    // `old_interp`: `src/codegen/verilog/Interp.zig` as a module of its
    // own, the old concrete MIR interpreter diff-lower holds Air's against.
    const old_interp = g.m.make("src/codegen/verilog/Interp.zig", &.{.{ .name = "ir", .module = byName(mods, "ir") }});
    const Diff = struct { step: []const u8, root: []const u8, what: []const u8, imports: []const []const u8, libc: bool = false, emit_zig: []const []const u8 = &.{} };
    const diffs = [_]Diff{
        .{ .step = "diff-parse", .root = "tests/differential/parse.zig", .what = "vams tokenizer/Ast/Parse against lib/frontend's lexer and parser on every fixture", .imports = &.{ "vams", "frontend", "diag", "base" } },
        .{ .step = "diff-pp", .root = "tests/differential/preprocess.zig", .what = "vams Preprocessor against lib/frontend's preprocessor on every fixture", .imports = &.{ "vams", "frontend", "diag" } },
        .{ .step = "diff-diag", .root = "tests/differential/diag.zig", .what = "vams Diag against lib/diag: the catalogue, rendering, JSON and --explain", .imports = &.{ "vams", "diag", "vera", "frontend" } },
        .{ .step = "diff-air", .root = "tests/differential/air.zig", .what = "Air's interpreter against src/ir's opcode folds", .imports = &.{ "air", "intern_pool", "ir", "kernels" } },
        .{ .step = "diff-spice", .root = "tests/differential/spice.zig", .what = "vams spice against lib/frontend's spice_cards.synthesize on every netlist the fixtures use", .imports = &.{ "vams", "frontend" } },
        .{ .step = "diff-astgen", .root = "tests/differential/astgen.zig", .what = "vams AstGen/Vir against the old compiler's per-file codes and design units on every fixture", .imports = &.{ "vams", "frontend", "diag", "vera" } },
        .{ .step = "diff-air-passes", .root = "tests/differential/air_passes.zig", .what = "the Air passes (Interval, Float, Legalize, Setup) against Air's interpreter over generated programs", .imports = &.{ "air", "intern_pool", "vams" } },
        .{ .step = "diff-sim", .root = "tests/differential/sim.zig", .what = "sema's digital lowering run in std_sim against lib/sim/digital: every .v fixture's transcript from source", .imports = &.{ "sema", "vams", "std_sim", "sim", "frontend", "diag", "intern_pool" } },
        .{ .step = "diff-elab", .root = "tests/differential/elab.zig", .what = "sema's elaboration against src/elab and the digital route's elaboration on every fixture", .imports = &.{ "sema", "vams", "frontend", "diag", "elab", "sim" } },
        .{ .step = "diff-lower", .root = "tests/differential/lower.zig", .what = "sema's analog lowering against src/analog: tables, codes, and every contribution's value by both interpreters", .imports = &.{ "sema", "air", "intern_pool", "vams", "frontend", "diag", "elab", "analog", "ir", "old_interp" } },
        .{ .step = "diff-codegen", .root = "tests/differential/codegen.zig", .what = "codegen's Zig backend against src/codegen/device: both devices built and run, rows, Jacobians and charges bit for bit", .imports = &.{ "sema", "air", "intern_pool", "vams", "codegen", "link", "dynlib", "frontend", "diag", "vera", "contract" }, .libc = true },
        .{ .step = "diff-link", .root = "tests/differential/link.zig", .what = "link against src/zigbuild: the same devices built by both, at 1 and N jobs", .imports = &.{ "link", "zigbuild", "dynlib", "contract" }, .libc = true, .emit_zig = &.{ "tests/osdi/resistor.va", "tests/osdi/diode.va", "tests/osdi/mixed.va" } },
    };
    for (diffs) |d| {
        const imports = b.allocator.alloc(Build.Module.Import, d.imports.len) catch @panic("OOM");
        for (imports, d.imports) |*i, name| i.* = .{ .name = name, .module = if (std.mem.eql(u8, name, "old_interp")) old_interp else byName(mods, name) };
        const mod = g.m.make(d.root, imports);
        if (d.libc and g.m.target.result.os.tag == .linux) mod.link_libc = true;
        const opts = if (d.emit_zig.len == 0) o else emitted: {
            const own = b.addOptions();
            const wf = b.addWriteFiles();
            for (d.emit_zig) |va| {
                const run = b.addRunArtifact(g.exe);
                run.addArgs(&.{ "--emit-zig", "-o" });
                const out = run.addOutputFileArg("device.zig");
                run.addFileArg(b.path(va));
                run.expectExitCode(0);
                // Warnings (W0650, ...) are the compiler's business, not this oracle's.
                _ = run.captureStdErr(.{});
                _ = wf.addCopyFile(out, b.fmt("{s}.zig", .{std.fs.path.stem(va)}));
            }
            own.addOptionPathDirectory("emitted", wf.getDirectory());
            break :emitted own;
        };
        mod.addOptions("rewrite_options", opts);
        mod.addImport("repo_env", repo_env);
        if (std.mem.eql(u8, d.step, "diff-codegen")) mod.addImport("scratch_device", scratchDevice(g));
        const r = testRun(b, d.step, mod, g.runner, g.results_dir);
        setSuiteEnv(b, r);
        // Reads the fixture tree at run time.
        r.has_side_effects = true;
        const step = b.step(d.step, d.what);
        step.dependOn(&r.step);
        if (std.mem.eql(u8, d.step, "diff-codegen")) {
            codegenHosts(g, step);
            benchFast(g);
        }
        all.dependOn(&r.step);
        g.test_step.dependOn(&r.step);
    }
    // diff-kernels: std_kernels against lib/kernels and against the old
    // kernel text itself, which `kernels_text.zig` writes out as one file
    // (an `h.zig`) so the oracle can compile and call it; Gompute against gm.
    const text_gen = b.addExecutable(.{ .name = "kernels-text", .root_module = g.m.make("tests/differential/kernels_text.zig", &.{.{ .name = "device", .module = byName(mods, "device") }}) });
    const text_run = b.addRunArtifact(text_gen);
    const old_text = b.createModule(.{
        .root_source_file = text_run.addOutputFileArg("old_text.zig"),
        .target = g.m.target,
        .optimize = g.m.optimize,
        .imports = &.{.{ .name = "contract", .module = byName(mods, "contract") }},
    });
    const kmod = g.m.make("tests/differential/kernels.zig", &.{
        .{ .name = "std_kernels", .module = byName(mods, "std_kernels") },
        .{ .name = "kernels", .module = byName(mods, "kernels") },
        .{ .name = "contract", .module = byName(mods, "contract") },
        .{ .name = "gompute_math", .module = b.dependency("gompute", .{}).module("math") },
        .{ .name = "old_text", .module = old_text },
        .{ .name = "sema", .module = byName(mods, "sema") },
        .{ .name = "air", .module = byName(mods, "air") },
    });
    const kr = testRun(b, "diff-kernels", kmod, g.runner, g.results_dir);
    const kt = b.step("kernels-targets", "std_kernels built for x86_64, aarch64, NVPTX and AMDGCN, its f64 math and the strict family's kernels held to no optional contraction on each, the Fast family's to the fast flags");
    kernelTargets(b, kt);
    const kd = b.step("diff-kernels", "std_kernels against lib/kernels and the old kernel text, bit for bit; Gompute against gm and an f128 reference; kernels-targets");
    kd.dependOn(&kr.step);
    kd.dependOn(kt);
    all.dependOn(kd);
    g.test_step.dependOn(kd);
    comp.add(g, all);
}

// ---- private ----

/// The contract's behavioural hosts (`tests/host/*_host.zig`) run on the
/// new devices of their fixtures, where diff-codegen agrees on the fixture
/// and the host reads only what the Zig backend writes.
fn codegenHosts(g: Graph, step: *Build.Step) void {
    const b = g.b;
    const Host = struct { host: []const u8, va: []const u8 };
    const hosts = [_]Host{
        .{ .host = "tests/host/integer_param_host.zig", .va = "tests/conformance/tests/verilog-a/ch03_data_types/integer_param_low32.va" },
    };
    const names = [_][]const u8{ "sema", "air", "intern_pool", "vams", "codegen", "frontend", "diag", "vera" };
    var imports: [names.len]Build.Module.Import = undefined;
    for (&imports, names) |*i, n| i.* = .{ .name = n, .module = byName(g.mods, n) };
    const gen = b.addExecutable(.{ .name = "codegen-device", .root_module = g.m.make("tests/differential/codegen/device_gen.zig", &imports) });
    for (hosts) |h| {
        const run = b.addRunArtifact(gen);
        run.addFileArg(b.path(h.va));
        run.addArg(pathFromRoot(b, "tests/conformance/tests/include"));
        const device = b.createModule(.{
            .root_source_file = run.addOutputFileArg("device.zig"),
            .target = g.m.target,
            .optimize = g.m.optimize,
            .imports = &.{
                .{ .name = "contract", .module = byName(g.mods, "contract") },
                .{ .name = "std_kernels", .module = byName(g.mods, "std_kernels") },
            },
        });
        const host = g.m.make(h.host, &.{
            .{ .name = "contract", .module = byName(g.mods, "contract") },
            .{ .name = "device", .module = device },
        });
        step.dependOn(&testRun(b, b.fmt("codegen-{s}", .{std.fs.path.stem(h.host)}), host, g.runner, g.results_dir).step);
    }
}

/// `bench-fast`: `tests/bench_fast.zig` over the new devices of
/// `tests/bench/*.va`, ReleaseFast as a device is: strict against fast-math
/// evaluation time (AGENTS.md: a speed claim cites a benchmark).
fn benchFast(g: Graph) void {
    const b = g.b;
    const names = [_][]const u8{ "sema", "air", "intern_pool", "vams", "codegen", "frontend", "diag", "vera" };
    var imports: [names.len]Build.Module.Import = undefined;
    for (&imports, names) |*i, n| i.* = .{ .name = n, .module = byName(g.mods, n) };
    const gen = b.addExecutable(.{ .name = "bench-device", .root_module = g.m.make("tests/differential/codegen/device_gen.zig", &imports) });
    const contract = b.createModule(.{ .root_source_file = b.path("lib/contract.zig"), .target = g.m.target, .optimize = .ReleaseFast });
    const kernels = b.createModule(.{ .root_source_file = b.path("lib/std/kernels.zig"), .target = g.m.target, .optimize = .ReleaseFast, .imports = &.{
        .{ .name = "contract", .module = contract },
        .{ .name = "gompute_math", .module = b.dependency("gompute", .{ .optimize = .ReleaseFast }).module("math") },
    } });
    const root = b.createModule(.{ .root_source_file = b.path("tests/bench_fast.zig"), .target = g.m.target, .optimize = .ReleaseFast, .imports = &.{
        .{ .name = "contract", .module = contract },
        .{ .name = "std_kernels", .module = kernels },
    } });
    for ([_][]const u8{ "diode", "mosfet", "abs", "tanh_amp", "mos_exp" }) |name| for ([_][]const u8{ "", "_v" }) |side| {
        const run = b.addRunArtifact(gen);
        run.addFileArg(b.path(b.fmt("tests/bench/{s}.va", .{name})));
        run.addArg(pathFromRoot(b, "tests/conformance/tests/include"));
        const out = run.addOutputFileArg("device.zig");
        if (side.len != 0) run.addArg("versioned");
        root.addImport(b.fmt("{s}{s}", .{ name, side }), b.createModule(.{
            .root_source_file = out,
            .target = g.m.target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "contract", .module = contract },
                .{ .name = "std_kernels", .module = kernels },
            },
        }));
    };
    const exe = b.addExecutable(.{ .name = "bench-fast", .root_module = root });
    const step = b.step("bench-fast", "Strict against fast-math device evaluation time held to no device slower versioned than strict (tests/bench/*.va, ReleaseFast, median and least of 101 runs)");
    step.dependOn(&b.addRunArtifact(exe).step);
}

/// diff-codegen's scratch-array device (`codegen.examples.stack`, the
/// bsource.va stack of lib/TODO.md §11.10), written by a generator so the
/// oracle compiles it and holds it to `Air.interp`.
fn scratchDevice(g: Graph) *Build.Module {
    const b = g.b;
    const gen = b.addExecutable(.{ .name = "codegen-scratch", .root_module = g.m.make("tests/differential/codegen/scratch_gen.zig", &.{
        .{ .name = "codegen", .module = byName(g.mods, "codegen") },
        .{ .name = "intern_pool", .module = byName(g.mods, "intern_pool") },
    }) });
    const run = b.addRunArtifact(gen);
    return b.createModule(.{
        .root_source_file = run.addOutputFileArg("scratch_device.zig"),
        .target = g.m.target,
        .optimize = g.m.optimize,
        .imports = &.{
            .{ .name = "contract", .module = byName(g.mods, "contract") },
            .{ .name = "std_kernels", .module = byName(g.mods, "std_kernels") },
        },
    });
}

/// `tests/differential/kernels_targets.zig` for each device target, ReleaseFast
/// as a device is: every exported kernel built, and the `f64` math's LLVM IR
/// grepped for optional contraction (exit 1: none). The grep's own canary,
/// an optimized-mode `a * b + c`, must be found on each target, so a pattern
/// that misses a target's spelling fails instead of passing everything.
fn kernelTargets(b: *Build, step: *Build.Step) void {
    const targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 } },
        .{ .cpu_arch = .aarch64, .os_tag = .linux },
        .{ .cpu_arch = .nvptx64, .os_tag = .cuda, .cpu_model = .{ .explicit = &std.Target.nvptx.cpu.sm_80 } },
        .{ .cpu_arch = .amdgcn, .os_tag = .amdhsa, .cpu_model = .{ .explicit = &std.Target.amdgcn.cpu.gfx1100 } },
    };
    const gompute_math = b.dependency("gompute", .{}).module("math");
    for (targets) |q| {
        const t = b.resolveTargetQuery(q);
        const contract = b.createModule(.{ .root_source_file = b.path("lib/contract.zig"), .target = t, .optimize = .ReleaseFast });
        const kernels = b.createModule(.{ .root_source_file = b.path("lib/std/kernels.zig"), .target = t, .optimize = .ReleaseFast, .imports = &.{
            .{ .name = "contract", .module = contract },
            .{ .name = "gompute_math", .module = gompute_math },
        } });
        // `family`: the generic kernels over the strict reference family;
        // `fast`: over its `Fast` twin, which must carry the fast flags.
        const Part = enum { all, math, family, fast, control };
        for ([_]Part{ .all, .math, .family, .fast, .control }) |part| {
            const o = b.addOptions();
            o.addOption(bool, "math_only", part == .math);
            o.addOption(bool, "control", part == .control);
            o.addOption(bool, "family_only", part == .family or part == .fast);
            o.addOption(bool, "fast", part == .fast);
            const root = b.createModule(.{ .root_source_file = b.path("tests/differential/kernels_targets.zig"), .target = t, .optimize = .ReleaseFast, .imports = &.{
                .{ .name = "std_kernels", .module = kernels },
                .{ .name = "contract", .module = contract },
            } });
            root.addOptions("kernels_targets_options", o);
            const obj = b.addObject(.{ .name = b.fmt("kernels-{s}-{s}", .{ @tagName(q.cpu_arch.?), @tagName(part) }), .root_module = root });
            if (part == .all) {
                step.dependOn(&obj.step);
                continue;
            }
            // What Zig hands LLVM: no `llvm.fmuladd` and no `contract`/`fast`
            // flag, on every target: contraction each target may or may not
            // do. An explicit `@mulAdd` (`llvm.fma`) rounds once everywhere
            // and is allowed (lib/TODO.md §11.8).
            const ir = b.addSystemCommand(&.{ "grep", "-Eq", "fmuladd|(fadd|fsub|fmul|fdiv|fneg)[a-z ]* (contract|fast)" });
            ir.addFileArg(obj.getEmittedLlvmIr());
            ir.expectExitCode(if (part == .control or part == .fast) 0 else 1);
            step.dependOn(&ir.step);
        }
    }
}
