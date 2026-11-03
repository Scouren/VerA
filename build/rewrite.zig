//! The rewrite's oracle steps (docs/rewrite/README.md): each new module held
//! to the code it replaces over the whole fixture corpus. `diff-parse`
//! (vams Ast/Parse vs lib/frontend's lexer and parser), `diff-pp` (vams
//! Preprocessor vs lib/frontend's preprocessor), `diff-diag` (vams Diag vs
//! lib/diag), `diff-air` (Air's interpreter vs src/ir's opcode folds),
//! `diff-link` (link vs src/zigbuild over the same device builds), and
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
    const all = b.step("rewrite", "The rewrite's modules and their oracles: test-vams, test-intern_pool, test-air, test-link, diff-parse, diff-pp, diff-diag, diff-air, diff-link");
    for ([_][]const u8{ "vams", "intern_pool", "air", "link" }) |name| {
        all.dependOn(&b.top_level_steps.get(b.fmt("test-{s}", .{name})).?.step);
    }
    const o = b.addOptions();
    o.addOption([]const u8, "fixture_root", pathFromRoot(b, "tests/conformance/tests"));
    o.addOption([]const u8, "repo_root", pathFromRoot(b, "."));
    // `libc`: the root loads libraries (`dynlib` needs glibc on Linux).
    // `emit_zig`: fixtures whose `vera --emit-zig` text the root reads from
    // the directory `rewrite_options.emitted`, as `<stem>.zig`.
    const Diff = struct { step: []const u8, root: []const u8, what: []const u8, imports: []const []const u8, libc: bool = false, emit_zig: []const []const u8 = &.{} };
    const diffs = [_]Diff{
        .{ .step = "diff-parse", .root = "tests/differential/parse.zig", .what = "vams tokenizer/Ast/Parse against lib/frontend's lexer and parser on every fixture", .imports = &.{ "vams", "frontend", "diag", "base" } },
        .{ .step = "diff-pp", .root = "tests/differential/preprocess.zig", .what = "vams Preprocessor against lib/frontend's preprocessor on every fixture", .imports = &.{ "vams", "frontend", "diag" } },
        .{ .step = "diff-diag", .root = "tests/differential/diag.zig", .what = "vams Diag against lib/diag: the catalogue, rendering, JSON and --explain", .imports = &.{ "vams", "diag", "vera", "frontend" } },
        .{ .step = "diff-air", .root = "tests/differential/air.zig", .what = "Air's interpreter against src/ir's opcode folds", .imports = &.{ "air", "intern_pool", "ir", "kernels" } },
        .{ .step = "diff-spice", .root = "tests/differential/spice.zig", .what = "vams spice against lib/frontend's spice_cards.synthesize on every netlist the fixtures use", .imports = &.{ "vams", "frontend" } },
        .{ .step = "diff-link", .root = "tests/differential/link.zig", .what = "link against src/zigbuild: the same devices built by both, at 1 and N jobs", .imports = &.{ "link", "zigbuild", "dynlib", "contract" }, .libc = true, .emit_zig = &.{ "tests/osdi/resistor.va", "tests/osdi/diode.va", "tests/osdi/mixed.va" } },
    };
    for (diffs) |d| {
        const imports = b.allocator.alloc(Build.Module.Import, d.imports.len) catch @panic("OOM");
        for (imports, d.imports) |*i, name| i.* = .{ .name = name, .module = byName(mods, name) };
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
}
