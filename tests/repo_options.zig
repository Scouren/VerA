//! `repo_root`, read from the environment at run time instead of compiled
//! in by `b.addOptions` (F6, research/builds.md R5): an absolute path baked
//! into a generated options file makes that root's compile cache-key
//! worktree-specific, so a second worktree at the same commit misses the
//! shared `.zig-cache` even though nothing changed. `build/unit.zig` sets
//! `VERA_REPO_ROOT` on the Run step instead (`tools/common.dropNixTmpKeys`
//! keeps that Run step cacheable); `tools/zrunner.zig` already assigns
//! `std.testing.environ` before any test runs, so this needs no plumbing
//! of its own.
//!
//! Contents:
//! - `pub fn repoRoot() []const u8`

const std = @import("std");

/// The repo root `build/unit.zig` ran this test binary from. Panics if
/// unset: a test root that imports this without the matching `addArg` on
/// its Run step is a build-wiring bug, not a runtime error.
pub fn repoRoot() []const u8 {
    return std.process.Environ.getPosix(std.testing.environ, "VERA_REPO_ROOT") orelse
        std.debug.panic("VERA_REPO_ROOT is unset (build/unit.zig's Run step should set it)", .{});
}
