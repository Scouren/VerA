//! The suite's absolute paths (`fixtureRoot`, `repoRoot`, `workRoot`,
//! `contract`, `vpiInclude`, `zigExe`), read from the environment at run
//! time instead of compiled in by `b.addOptions` (F6, research/builds.md
//! R5): a compiled-in absolute path makes `tests/suite.zig`'s root
//! worktree-specific, so a second worktree at the same commit misses the
//! shared `.zig-cache` even at check (type-check only, never runs). Both
//! `tests/suite.zig`'s `main` (the `vera-suite` executable) and
//! `tools/zrunner.zig` (the `test-suite`/`test-unit`/`check` compiles) set
//! `std.testing.environ` before any of this is read.
//!
//! `tests/suite.zig` also builds as the `vera-suite` executable, where
//! `std.testing.environ` is `@compileError("not testing")` (it is declared
//! only under `builtin.is_test`), so `Suite.main` calls `setEnviron` with
//! its own `std.process.Init.environ` first; a test binary never calls it
//! and reads `std.testing.environ` instead, already set by zrunner.
//!
//! Contents:
//! - `pub fn setEnviron(e: std.process.Environ) void`
//! - `pub fn fixtureRoot() []const u8`
//! - `pub fn repoRoot() []const u8`
//! - `pub fn workRoot() []const u8`
//! - `pub fn contract() []const u8`
//! - `pub fn vpiInclude() []const u8`
//! - `pub fn zigExe() []const u8`

const std = @import("std");
const builtin = @import("builtin");

/// The executable's own environ, set once by `Suite.main` before anything
/// below reads it; unused in a test binary (`environ` below reads
/// `std.testing.environ` there instead).
var exe_environ: std.process.Environ = .empty;

/// Call once, first, from `Suite.main` (the `vera-suite` executable only).
pub fn setEnviron(e: std.process.Environ) void {
    if (!builtin.is_test) exe_environ = e;
}

fn environ() std.process.Environ {
    return if (builtin.is_test) std.testing.environ else exe_environ;
}

/// Panics if `name` is unset: a wiring bug (`build/unit.zig`'s Run step
/// should set it, or `Suite.main` should have called `setEnviron`), not a
/// runtime error.
fn env(comptime name: []const u8) []const u8 {
    return std.process.Environ.getPosix(environ(), name) orelse
        std.debug.panic(name ++ " is unset (build/unit.zig's Run step should set it)", .{});
}

/// The VAMS Conformance Suite's `tests/` this run walks, or another tree
/// laid out the same way under `--fixture-root=`.
pub fn fixtureRoot() []const u8 {
    return env("VERA_FIXTURE_ROOT");
}

/// The repo root `build/unit.zig` ran this run from.
pub fn repoRoot() []const u8 {
    return env("VERA_REPO_ROOT");
}

/// Scratch space under `.vera-work`, keyed by checkout (`checkoutWorkDir`).
pub fn workRoot() []const u8 {
    return env("VERA_WORK_ROOT");
}

/// `lib/contract.zig`'s path, for a child `vera` invocation's `--contract`.
pub fn contract() []const u8 {
    return env("VERA_CONTRACT");
}

/// `src/vpi`'s path, for a VPI fixture's C compile.
pub fn vpiInclude() []const u8 {
    return env("VERA_VPI_INCLUDE");
}

/// The Zig this build runs, for a child `vera` invocation that itself
/// spawns `zig` (device builds).
pub fn zigExe() []const u8 {
    return env("VERA_ZIG_EXE");
}
