//! The rewrite's oracle steps (docs/rewrite/README.md): each new module held
//! to the code it replaces over the whole fixture corpus. `diff-parse`
//! (vams Ast/Parse vs lib/frontend's lexer and parser), `diff-pp` (vams
//! Preprocessor vs lib/frontend's preprocessor), `diff-air` (Air's
//! interpreter vs src/ir's opcode folds), and `rewrite`, which runs them
//! and the new modules' own tests. All are in `test`. `build.zig` calls
//! `add` once.
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
    const all = b.step("rewrite", "The rewrite's modules and their oracles: test-vams, test-intern_pool, test-air, diff-parse, diff-pp, diff-air");
    for ([_][]const u8{ "vams", "intern_pool", "air" }) |name| {
        all.dependOn(&b.top_level_steps.get(b.fmt("test-{s}", .{name})).?.step);
    }
    const o = b.addOptions();
    o.addOption([]const u8, "fixture_root", pathFromRoot(b, "tests/conformance/tests"));
    o.addOption([]const u8, "repo_root", pathFromRoot(b, "."));
    const Diff = struct { step: []const u8, root: []const u8, what: []const u8, imports: []const []const u8 };
    const diffs = [_]Diff{
        .{ .step = "diff-parse", .root = "tests/differential/parse.zig", .what = "vams tokenizer/Ast/Parse against lib/frontend's lexer and parser on every fixture", .imports = &.{ "vams", "frontend", "diag", "base" } },
        .{ .step = "diff-pp", .root = "tests/differential/preprocess.zig", .what = "vams Preprocessor against lib/frontend's preprocessor on every fixture", .imports = &.{ "vams", "frontend", "diag" } },
        .{ .step = "diff-air", .root = "tests/differential/air.zig", .what = "Air's interpreter against src/ir's opcode folds", .imports = &.{ "air", "intern_pool", "ir", "kernels" } },
    };
    for (diffs) |d| {
        const imports = b.allocator.alloc(Build.Module.Import, d.imports.len) catch @panic("OOM");
        for (imports, d.imports) |*i, name| i.* = .{ .name = name, .module = byName(mods, name) };
        const mod = g.m.make(d.root, imports);
        mod.addOptions("rewrite_options", o);
        const r = testRun(b, d.step, mod, g.runner, g.results_dir);
        // Reads the fixture tree at run time.
        r.has_side_effects = true;
        b.step(d.step, d.what).dependOn(&r.step);
        all.dependOn(&r.step);
        g.test_step.dependOn(&r.step);
    }
}
