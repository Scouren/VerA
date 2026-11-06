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
    // diff-rtlil's tiebreaker (tests/differential/comp/yosys.zig): required, never skipped.
    o.addOption([]const u8, "yosys", b.option([]const u8, "yosys", "diff-rtlil, rtlil-equiv: the Yosys executable (default `yosys` on PATH, as `nix develop .#external` has it)") orelse "yosys");
    o.addOption(bool, "rebaseline", b.option(bool, "comp-rebaseline", "diff-comp: write every disagreement to zig-out/comp.xfail.new instead of failing on it") orelse false);
    // diff-comp itself, then the `.v` backends' runs (docs/rewrite/digital.md):
    // the same fixtures with `--run` swapped for the backend's flag, each
    // against its own xfail list.
    const runs = [_]struct { step: []const u8, flag: []const u8, list: []const u8, what: []const u8 }{
        .{ .step = "diff-comp", .flag = "", .list = "comp", .what = "vera-next against vera on every fixture's harness command line: exit code, diagnostics, stdout, emitted files" },
        .{ .step = "diff-digital-exe", .flag = "--emit-exe", .list = "digital_exe", .what = "every .v fixture through --emit-exe and the binary it built, vera-next against vera" },
        .{ .step = "diff-rtlil", .flag = "--emit-rtlil", .list = "rtlil", .what = "every .v fixture through --emit-rtlil, vera-next against vera" },
        .{ .step = "diff-digital-device", .flag = "--check", .list = "digital_device", .what = "every .v fixture through --check (a .v top as a contract device), vera-next against vera" },
    };
    for (runs) |run_row| {
        const vo = b.addOptions();
        vo.addOption([]const u8, "flag", run_row.flag);
        vo.addOption([]const u8, "name", run_row.list);
        const mod = g.m.make("tests/differential/comp.zig", &.{.{ .name = "vams", .module = byName(g.mods, "vams") }});
        mod.addOptions("comp_options", o);
        mod.addOptions("v_options", vo);
        const r = testRun(b, run_row.step, mod, g.runner, g.results_dir);
        r.has_side_effects = true; // Reads the fixture tree and runs both drivers.
        b.step(run_row.step, run_row.what).dependOn(&r.step);
        // diff-rtlil's tiebreaker needs Yosys (`nix develop .#external`):
        // it runs in the README's external gate line, not in `rewrite`.
        if (!std.mem.eql(u8, run_row.list, "rtlil")) all.dependOn(&r.step);
    }

    // rtlil-equiv: diff-rtlil's Yosys tiebreaker on its canary and on tests/rtlil.
    const eq_mod = g.m.make("tests/differential/rtlil_equiv.zig", &.{});
    eq_mod.addOptions("comp_options", o);
    const eq = testRun(b, "rtlil-equiv", eq_mod, g.runner, g.results_dir);
    eq.has_side_effects = true; // Runs both drivers and Yosys.
    b.step("rtlil-equiv", "tests/rtlil through vera and vera-next --emit-rtlil, held equivalent by Yosys (required: `nix develop .#external`), and a planted fault caught").dependOn(&eq.step);
    // Needs Yosys: the README's external gate line runs it, not `rewrite`.

    // §12: concurrent --check runs of one model in one directory.
    const race_mod = g.m.make("tests/differential/comp_check.zig", &.{});
    race_mod.addOptions("comp_options", o);
    const race = testRun(b, "comp-check-race", race_mod, g.runner, g.results_dir);
    race.has_side_effects = true; // Spawns vera-next, which spawns zig.
    b.step("comp-check-race", "Eight concurrent `vera-next --emit-zig --check` runs of one model in one directory all succeed (lib/TODO.md §12)").dependOn(&race.step);
    all.dependOn(&race.step);

    // bench-run: `vera-next --run` over hand-derived benches (docs/rewrite/exe.md).
    const bench_mod = g.m.make("tests/differential/bench_run.zig", &.{});
    bench_mod.addOptions("comp_options", o);
    const bench = testRun(b, "bench-run", bench_mod, g.runner, g.results_dir);
    bench.has_side_effects = true; // Spawns vera-next, which spawns zig.
    b.step("bench-run", "vera-next --run on a swept and re-carded resistor: every transcript line against Ohm's law").dependOn(&bench.step);
    all.dependOn(&bench.step);

    // exe-run: a `.v --emit-exe` binary against vera-next's own `--run`.
    const exe_mod = g.m.make("tests/differential/exe_run.zig", &.{});
    exe_mod.addOptions("comp_options", o);
    const exe_run = testRun(b, "exe-run", exe_mod, g.runner, g.results_dir);
    exe_run.has_side_effects = true; // Spawns vera-next, which spawns zig.
    b.step("exe-run", "A .v --emit-exe binary prints what vera-next --run prints, byte for byte").dependOn(&exe_run.step);
    all.dependOn(&exe_run.step);

    // vdev-next: tests/host/vdev_host.zig's hand-derived host oracles over
    // the `.v` devices vera-next writes (`std_sim.Device`), as `devices`
    // runs them over the old ones (build/devices.zig).
    const vdev = g.m.make("tests/host/vdev_host.zig", &.{.{ .name = "contract", .module = byName(g.mods, "contract") }});
    for ([_][]const u8{ "v_inv", "v_buf", "v_count", "v_a2d", "v_edge", "v_any", "v_wide", "v_huge", "v_say" }) |name| {
        const gen = b.addRunArtifact(next);
        gen.addArg("--emit-zig");
        gen.addFileArg(b.path(b.fmt("tests/conformance/tests/verilog-ams/ch07_mixed_signal/{s}.v", .{name})));
        gen.addArg("-o");
        vdev.addImport(name, b.createModule(.{
            .root_source_file = gen.addOutputFileArg2(b.fmt("{s}.zig", .{name}), .{}),
            .target = g.m.target,
            .optimize = g.m.optimize,
            .imports = &.{ .{ .name = "contract", .module = byName(g.mods, "contract") }, .{ .name = "std_sim", .module = byName(g.mods, "std_sim") } },
        }));
    }
    const vdev_run = testRun(b, "vdev-next", vdev, g.runner, g.results_dir);
    const vdev_step = b.step("vdev-next", "tests/host/vdev_host.zig over the .v devices vera-next writes (std_sim.Device), and the old device's refusals");
    vdev_step.dependOn(&vdev_run.step);
    all.dependOn(&vdev_run.step);
    // The old device's refusals, byte for byte (build/devices.zig's rows).
    for ([_]struct { []const u8, u8, []const u8 }{
        .{ "v_inout", 1, "error[E1103]: design cannot be a contract device: module `v_inout`: an inout port" },
        .{ "v_integer", 1, "error[E1103]: design cannot be a contract device: module `v_integer`: an integer or time port" },
        .{ "v_pins", 1, "error[E1103]: design cannot be a contract device: module `v_pins`: more than 65535 pins" },
        .{ "v_tran", 1, "error[E1103]: design cannot be a contract device: module `v_tran`: a §7.6 pass switch" },
        .{ "v_seconds", 0, "warning[W1155]: device digital tick is 1 s" },
    }) |r| {
        const run = b.addRunArtifact(next);
        run.addArg("--emit-zig");
        run.addFileArg(b.path(b.fmt("tests/conformance/tests/verilog-ams/ch07_mixed_signal/{s}.v", .{r[0]})));
        run.addArg("-o");
        _ = run.addOutputFileArg2("device.zig", .{});
        run.expectExitCode(r[1]);
        run.addCheck(.{ .expect_stderr_match = r[2] });
        vdev_step.dependOn(&run.step);
        all.dependOn(&run.step);
    }

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
