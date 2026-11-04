//! One compilation's configuration, resolved: what `vera-next`'s command
//! line (or the LSP, or a test) decides before any file is read. Replaces
//! the old `Cli` + `Settings` + `Request` (lib/TODO.md §3.2, Appendix A.2):
//! one flat value, every slice borrowed for the `Compilation`'s life. Zig's
//! `Compilation/Config.zig` resolved options.
//!
//! Cites: §3.4 (`overrides`), §3.6.2 (`std_defs`), §7.4.4
//! (`discipline_resolution`), §9.4 (`display`), §10 (`defines`,
//! `include_dirs`), annex C (`sim`), annex E.2 (`spice_path`); IEEE
//! 1364-2005 §13.2 (`libmaps`, `search`), §28 (`protect_keys`).
//!
//! Contents:
//! - fields, each with a default
//! - `pub const Sim`, `pub const Display`, `pub const Override`, `pub const Overlay`, `pub const Target`
//! - `pub const stack_size: usize`
//! - `pub fn digital(c: Config) bool`

const std = @import("std");
const vams = @import("vams");

/// The inputs; `paths[0]` is the one compiled, the rest are `.v` units
/// after it in command-line order (IEEE 1364-2005 §13.4.1).
paths: []const []const u8 = &.{},
/// Searched in order for an `include, ahead of the built-in annex D files.
include_dirs: []const []const u8 = &.{},
/// `-D`: `NAME` or `NAME=TEXT`, defined before the sources.
defines: []const []const u8 = &.{},
/// Prepends annex D (§3.6.2); the Table E.1 primitives come either way.
std_defs: bool = true,
language: vams.Ast.KeywordSet = .vams_2023,
sim: Sim = .verilog_ams,
/// `--allow=`/`--warn=`/`--deny=`/`--forbid=`.
levels: vams.Diag.Levels = .empty,
/// §3.4 `--param`, in order.
overrides: []const Override = &.{},
discipline_resolution: enum { basic, detail } = .basic,
display: Display = .record,
/// The solver's compliance bound (`--unknown-bound`); null is
/// `Air.Float.default_unknown_bound`.
unknown_bound: ?f64 = null,
/// `--spice`: an annex E.2 netlist read beside the source.
spice_path: ?[]const u8 = null,
/// `--protect-keys`: IEEE 1364-2005 §28's key file.
protect_keys: ?[]const u8 = null,
libmaps: []const []const u8 = &.{},
search: []const []const u8 = &.{},
/// A `.v` design's events at one time step before a zero-delay loop is
/// refused (`--event-budget=`).
event_budget: u64 = 10_000_000,
negative_timing: bool = false,
/// What the compilation builds.
target: Target = .lint,
/// `--check` beside another target (`--emit-zig -o x --check`).
check: bool = false,
/// `--emit-zig` or `-o` beside `--check`/`--emit-so`: the device text too.
zig: bool = false,
/// `--expect-module=`: refuses a top module of another name.
expect_module: ?[]const u8 = null,
/// `-o`.
out_path: ?[]const u8 = null,
/// Where a `zig` child's files go; null: `.zig-cache/vera-tb`.
work_dir: ?[]const u8 = null,
/// The `contract` module root a `zig` child compiles the device against.
contract: ?[]const u8 = null,
/// `--dyn`: the `dyn` module root an `--emit-so` library exports through.
dyn: ?[]const u8 = null,
zig_exe: []const u8 = "zig",
optimize: std.lang.Optimize = .fast,
debug_info: bool = false,
jac_f32: bool = false,
jac_f32_host: bool = false,
/// `-j`/`--jobs=`: sizes every `Io.Group` and the `link.Queue`.
thread_limit: u32 = 1,
/// Test hook (`--test-check-pause-ms=`): `link.File.check_pause` of a
/// `--check`, so a test overlaps two checks deterministically.
check_pause: std.Io.Duration = .zero,
/// Files whose bytes are given instead of read (the LSP's open documents);
/// borrowed.
overlays: []const Overlay = &.{},

/// `--sim=`: the language family.
pub const Sim = enum { verilog_ams, verilog_a, verilog };
/// §9.4's display modes.
pub const Display = enum { record, drop, emit };
/// One `--param NAME=VALUE`: its text (a string parameter's value) and the
/// number, NaN when the text is not one.
pub const Override = struct { name: []const u8, text: []const u8, value: f64 };

/// One file's bytes as an editor holds them.
pub const Overlay = struct { path: []const u8, bytes: []const u8 };

/// The one artifact a compilation ends in. `lint` stops after the
/// analysis; the rest name a backend (`Compilation/backend.zig`).
pub const Target = enum {
    lint,
    /// A `.v` design elaborated, then stopped (IEEE 1364-2005 §12.1.3).
    elab,
    /// The device text (`--emit-zig`; with `check`, type-checked too).
    zig,
    /// `--check` alone.
    check,
    so,
    osdi,
    exe,
    run,
    verilog,
    rtlil,
};

/// Every worker's stack, lazily committed (Zig's `main.zig` thread stack;
/// lib/TODO.md §11.2): the stages recurse with the source's nesting, up to
/// `vams.Parse.max_depth`.
pub const stack_size: usize = 256 << 20;

const Config = @This();

/// Whether the design is IEEE 1364 (a `.v` input): it runs in `std_sim`
/// instead of becoming a device.
pub fn digital(c: Config) bool {
    std.debug.assert(c.paths.len != 0);
    return std.mem.eql(u8, std.fs.path.extension(c.paths[0]), ".v");
}
