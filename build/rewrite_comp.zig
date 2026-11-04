//! The rewrite's driver and its oracles (docs/rewrite/comp.md): the
//! `vera-next` executable (`src/next/main.zig` over the `comp` module),
//! `diff-comp` (every fixture through `vera` and `vera-next`, compared)
//! and `conformance-next` (the conformance suite's own harness, `conform`
//! built here from the suite's `harness/conform.c`, with `vera-next` as
//! the tool, against `tools/vera.xfail`). `build/rewrite.zig` calls `add`.
//! Clauses: none (build wiring).
//!
//! Contents:
//! - `pub fn add(g: Graph, all: *Build.Step) void`

const std = @import("std");
const common = @import("common.zig");
const Build = std.Build;
const Graph = common.Graph;
const byName = common.byName;
const pathFromRoot = common.pathFromRoot;
const testRun = common.testRun;

pub fn add(g: Graph, all: *Build.Step) void {
    const b = g.b;
    const next = nextExe(g);
    const install = b.addInstallArtifact(next, .{});
    b.step("vera-next", "Build and install vera-next, the rewrite's driver (src/next/main.zig)").dependOn(&install.step);
    all.dependOn(&next.step);
    // The driver's own tests: the flag tables, the LSP session.
    const cli_tests = testRun(b, "vera-next", next.root_module, g.runner, g.results_dir);
    b.step("test-vera-next", "Run vera-next's driver tests (src/next/main.zig, cli/, lsp)").dependOn(&cli_tests.step);
    all.dependOn(&cli_tests.step);

    // diff-comp: both drivers over the corpus, as child processes.
    const o = b.addOptions();
    o.addOption([]const u8, "fixture_root", pathFromRoot(b, "tests/conformance/tests"));
    o.addOption([]const u8, "repo_root", pathFromRoot(b, "."));
    o.addOptionPath("vera", g.exe.getEmittedBin());
    o.addOptionPath("vera_next", next.getEmittedBin());
    o.addOption([]const u8, "filter", b.option([]const u8, "comp-filter", "diff-comp: only the fixtures whose path holds this") orelse "");
    o.addOption(u32, "jobs", b.option(u32, "comp-jobs", "diff-comp: fixtures compared at once (default 4; the machine is shared)") orelse 4);
    o.addOption(u32, "j1_sample", b.option(u32, "comp-j1", "diff-comp: also run this many fixtures' new side at -j1 and compare the bytes with -jN (default 200)") orelse 200);
    o.addOption(bool, "rebaseline", b.option(bool, "comp-rebaseline", "diff-comp: write every disagreement to zig-out/comp.xfail.new instead of failing on it") orelse false);
    // `vams`: the stage-ownership table (`stages.zig`) names codes by `Diag.Code`.
    const mod = g.m.make("tests/differential/comp.zig", &.{.{ .name = "vams", .module = byName(g.mods, "vams") }});
    mod.addOptions("comp_options", o);
    const r = testRun(b, "diff-comp", mod, g.runner, g.results_dir);
    r.has_side_effects = true; // Reads the fixture tree and runs both drivers.
    const step = b.step("diff-comp", "vera-next against vera on every fixture's harness command line: exit code, diagnostics, stdout, emitted files");
    step.dependOn(&r.step);
    all.dependOn(&r.step);

    // §12: concurrent --check runs of one model in one directory.
    const race_mod = g.m.make("tests/differential/comp_check.zig", &.{});
    race_mod.addOptions("comp_options", o);
    const race = testRun(b, "comp-check-race", race_mod, g.runner, g.results_dir);
    race.has_side_effects = true; // Spawns vera-next, which spawns zig.
    b.step("comp-check-race", "Eight concurrent `vera-next --emit-zig --check` runs of one model in one directory all succeed (lib/TODO.md §12)").dependOn(&race.step);
    all.dependOn(&race.step);

    // conformance-next: the suite's harness with vera-next as the tool.
    const conform = b.addExecutable(.{ .name = "conform", .root_module = b.createModule(.{ .target = g.m.target, .optimize = .ReleaseSafe, .link_libc = true }) });
    conform.root_module.addCSourceFile(.{ .file = b.path("tests/conformance/harness/conform.c"), .flags = &.{ "-std=gnu11", "-D_GNU_SOURCE" } });
    const run = b.addSystemCommand(&.{
        "sh", "-c",
        \\mkdir -p zig-out && VERA="$1" VERA_VPI_LIB=/nonexistent/vera-next-has-no-vpi.a "$2" -t tests/conformance/tools/vera.conf -x tools/vera.xfail -j "${CONFORM_JOBS:-4}" -T 300 \
        \\  -o zig-out/conformance-next.tsv tests/conformance/tests tests/conformance/external/*.manifest
        ,
        "sh",
    });
    run.addArtifactArg2(next, .{ .make_absolute = true });
    run.addArtifactArg2(conform, .{ .make_absolute = true });
    run.has_side_effects = true;
    b.step("conformance-next", "The conformance suite through its own harness with vera-next as the tool, against tools/vera.xfail: the switch-over gate").dependOn(&run.step);
}

// ---- private ----

/// `vera-next`: `src/next/main.zig` over `comp`, with the embedded `lib/`
/// tree and Gompute's math (written beside a build that needs the
/// contract), on a `Config.stack_size` main stack.
fn nextExe(g: Graph) *Build.Step.Compile {
    const b = g.b;
    const gm = b.dependency("gompute", .{}).module("math").root_source_file.?;
    const wf = b.addWriteFiles();
    var list: std.Io.Writer.Allocating = .init(b.allocator);
    list.writer.writeAll("pub const files = [_][2][]const u8{\n") catch @panic("OOM");
    for ([_][]const u8{ "math.zig", "math_data.zig", "math_pio2.zig" }) |f| {
        _ = wf.addCopyFile(gm.dirname().path(b, f), b.fmt("gompute/{s}", .{f}));
        list.writer.print("    .{{ \"gompute/{s}\", @embedFile(\"gompute/{s}\") }},\n", .{ f, f }) catch @panic("OOM");
    }
    list.writer.writeAll("};\n") catch @panic("OOM");
    const gompute_sources = b.createModule(.{ .root_source_file = wf.add("gompute_sources.zig", list.written()) });
    const mod = g.m.make("src/next/main.zig", &.{
        .{ .name = "comp", .module = byName(g.mods, "comp") },
        .{ .name = "vams", .module = byName(g.mods, "vams") },
        .{ .name = "contract", .module = byName(g.mods, "contract") },
        .{ .name = "sim_sources", .module = common.simSources(b) },
        .{ .name = "gompute_sources", .module = gompute_sources },
    });
    const exe = b.addExecutable(.{ .name = "vera-next", .root_module = mod });
    exe.stack_size = 256 << 20;
    return exe;
}
