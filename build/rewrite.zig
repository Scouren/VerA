//! The rewrite's oracle steps (docs/rewrite/README.md): each new module held
//! to the code it replaces over the whole fixture corpus. `diff-parse`
//! (vams Ast/Parse vs lib/frontend's lexer and parser), `diff-pp` (vams
//! Preprocessor vs lib/frontend's preprocessor), `diff-diag` (vams Diag vs
//! lib/diag), `diff-air` (Air's interpreter vs src/ir's opcode folds),
//! `diff-air-passes` (the Air passes against Air's interpreter over
//! generated programs; `-Dfull-oracles` runs the nightly's full sweep),
//! `diff-sim` (the std_sim runtime vs lib/sim/digital over every `.v`),
//! `diff-link` (link vs src/zigbuild over the same device builds),
//! `diff-dlower` (sema's digital lowering vs lib/sim/digital and the bridge),
//! `diff-astgen` (vams AstGen/Vir vs the old compiler's per-file codes and
//! design units), `diff-elab` (sema's elaboration vs src/elab and the
//! digital route's), `diff-lower` (sema's analog lowering vs src/analog,
//! values by the old MIR interpreter against Air's), `diff-kernels`
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

pub fn add(g: Graph) void {
    const b = g.b;
    const mods = g.mods;
    // One description for every new module: each oracle names itself in its row below.
    const all = b.step("rewrite", "The rewrite's modules' tests (test-<module>) and every diff-* oracle below");
    for ([_][]const u8{ "vams", "intern_pool", "air", "link", "std_sim", "sema", "std_kernels" }) |name| {
        all.dependOn(&b.top_level_steps.get(b.fmt("test-{s}", .{name})).?.step);
    }
    const o = b.addOptions();
    o.addOption([]const u8, "fixture_root", pathFromRoot(b, "tests/conformance/tests"));
    o.addOption([]const u8, "repo_root", pathFromRoot(b, "."));
    o.addOption([]const u8, "lower_dump", b.option([]const u8, "lower-dump", "diff-lower: print both sides' tables of the fixtures whose path holds this") orelse "");
    // The merge tier runs a generated-program oracle at a size inside its
    // budget; the nightly passes `-Dfull-oracles` for the whole sweep.
    o.addOption(bool, "full_oracles", b.option(bool, "full-oracles", "diff-air-passes: the nightly's full sweep (10^4 programs x 10^3 points) instead of the merge tier's") orelse false);
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
        .{ .step = "diff-sim", .root = "tests/differential/sim.zig", .what = "the std_sim runtime against lib/sim/digital: every .v fixture's transcript, through the bridge", .imports = &.{ "std_sim", "sim", "frontend", "diag", "kernels" } },
        .{ .step = "diff-dlower", .root = "tests/differential/dlower.zig", .what = "sema's digital lowering against lib/sim/digital: every .v fixture's transcript from source, and against the bridge's Program", .imports = &.{ "sema", "vams", "std_sim", "sim", "frontend", "diag", "kernels", "intern_pool" } },
        .{ .step = "diff-elab", .root = "tests/differential/elab.zig", .what = "sema's elaboration against src/elab and the digital route's elaboration on every fixture", .imports = &.{ "sema", "vams", "frontend", "diag", "elab", "sim" } },
        .{ .step = "diff-lower", .root = "tests/differential/lower.zig", .what = "sema's analog lowering against src/analog: tables, codes, and every contribution's value by both interpreters", .imports = &.{ "sema", "air", "intern_pool", "vams", "frontend", "diag", "elab", "analog", "ir", "old_interp" } },
        .{ .step = "diff-link", .root = "tests/differential/link.zig", .what = "link against src/zigbuild: the same devices built by both, at 1 and N jobs", .imports = &.{ "link", "zigbuild", "dynlib", "contract" }, .libc = true, .emit_zig = &.{ "tests/osdi/resistor.va", "tests/osdi/diode.va", "tests/osdi/mixed.va" } },
    };
    for (diffs) |d| {
        const imports = b.allocator.alloc(Build.Module.Import, d.imports.len) catch @panic("OOM");
        for (imports, d.imports) |*i, name| i.* = .{ .name = name, .module = if (std.mem.eql(u8, name, "old_interp")) old_interp else byName(mods, name) };
        const mod = g.m.make(d.root, imports);
        if (d.libc and g.m.target.result.os.tag == .linux) mod.link_libc = true;
        const opts = if (d.emit_zig.len == 0) o else emitted: {
            const own = b.addOptions();
            own.addOption([]const u8, "fixture_root", pathFromRoot(b, "tests/conformance/tests"));
            own.addOption([]const u8, "repo_root", pathFromRoot(b, "."));
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
        const r = testRun(b, d.step, mod, g.runner, g.results_dir);
        // Reads the fixture tree at run time.
        r.has_side_effects = true;
        b.step(d.step, d.what).dependOn(&r.step);
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
    });
    const kr = testRun(b, "diff-kernels", kmod, g.runner, g.results_dir);
    const kt = b.step("kernels-targets", "std_kernels built for x86_64, aarch64, NVPTX and AMDGCN, its f64 math held to no fused multiply-add on each");
    kernelTargets(b, kt);
    const kd = b.step("diff-kernels", "std_kernels against lib/kernels and the old kernel text, bit for bit; Gompute against gm and an f128 reference; kernels-targets");
    kd.dependOn(&kr.step);
    kd.dependOn(kt);
    all.dependOn(kd);
    g.test_step.dependOn(kd);
}

// ---- private ----

/// `tests/differential/kernels_targets.zig` for each device target, ReleaseFast
/// as a device is: every exported kernel built, and the `f64` math's
/// assembly grepped for a fused multiply-add (exit 1: none). The grep's own
/// canary, an `@mulAdd`, must be found on each target, so a pattern that
/// misses a target's spelling fails instead of passing everything.
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
        const Part = enum { all, math, control };
        for ([_]Part{ .all, .math, .control }) |part| {
            const o = b.addOptions();
            o.addOption(bool, "math_only", part == .math);
            o.addOption(bool, "control", part == .control);
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
            // What Zig hands LLVM: no `llvm.fma`/`fmuladd` call and no
            // `contract` flag, on every target.
            const ir = b.addSystemCommand(&.{ "grep", "-Eq", "llvm\\.fma|fmuladd|(fadd|fsub|fmul|fneg)[a-z ]* contract" });
            ir.addFileArg(obj.getEmittedLlvmIr());
            ir.expectExitCode(if (part == .control) 0 else 1);
            step.dependOn(&ir.step);
            // What the backend emits: no FMA instruction (`fmax` is a
            // maximum). AMDGCN's own f64 division and sqrt are FMA
            // sequences (v_div_fmas_f64) that round correctly, so there only
            // the canary is grepped.
            if (q.cpu_arch.? == .amdgcn and part == .math) continue;
            const asm_ = b.addSystemCommand(&.{ "grep", "-Eiq", "fma([^x]|$)|fn?m(add|sub)|fml[as]" });
            asm_.addFileArg(obj.getEmittedAsm());
            asm_.expectExitCode(if (part == .control) 0 else 1);
            step.dependOn(&asm_.step);
        }
    }
}
