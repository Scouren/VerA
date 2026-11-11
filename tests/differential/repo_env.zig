//! `fixtureRoot`/`repoRoot`, read from the environment at run time instead
//! of compiled in by `b.addOptions` (F6, research/builds.md R5): a
//! worktree-specific absolute path baked into an options module misses the
//! shared cache in every other worktree building the same commit. Every
//! `tests/differential/*.zig` root is a test binary (`build/common.zig`'s
//! `testRun` always calls `b.addTest`), so `std.testing.environ` is always
//! populated here. `build/rewrite.zig` and `build/rewrite_comp.zig` set
//! `VERA_FIXTURE_ROOT`/`VERA_REPO_ROOT` on every such Run step
//! (`common.setSuiteEnv`).
//!
//! Contents:
//! - `pub fn fixtureRoot() []const u8`
//! - `pub fn repoRoot() []const u8`

const std = @import("std");

fn env(comptime name: []const u8) []const u8 {
    return std.process.Environ.getPosix(std.testing.environ, name) orelse
        std.debug.panic(name ++ " is unset (its Run step should set it; build/rewrite.zig, build/rewrite_comp.zig)", .{});
}

pub fn fixtureRoot() []const u8 {
    return env("VERA_FIXTURE_ROOT");
}

pub fn repoRoot() []const u8 {
    return env("VERA_REPO_ROOT");
}
