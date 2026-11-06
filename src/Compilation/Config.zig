//! One compilation's configuration: what the command line or a library
//! caller decides about a source before it is read (the analysis' settings)
//! and which targets it asks for (`check`, `exe`, `so`, `zig`, `verilog`,
//! `osdi`), with how `zig` runs for them (`build`). `analyze` reads the
//! settings; `compile` reads all of it. A plain value; every slice is
//! borrowed and must outlive the call it is passed to (and, for `lint`, the
//! bag that call fills). Zig's `Compilation/Config.zig` resolved options.
//!
//! Cites: §3.4 (`param_overrides`), §3.6.2 (`std_defs`), §7.4.4
//! (`discipline_resolution`), §9.4 (`display`), §10 (`defines`,
//! `include_dirs`), §12.32.1 (`int_systfs`), annex C (`sim`), annex E.2
//! (`spice_netlist`), A.1.2 (`empty_unit_ok`); §4.6.4.6 and §9.17 (what
//! `osdi` refuses).
//!
//! Contents (fields, each with a default):
//! - `file_name: []const u8`, `include_dirs: []const []const u8`,
//!   `defines: []const []const u8`, `std_defs: bool`,
//!   `require_std_includes: bool`, `language: KeywordSet`, `sim: Sim`
//! - `param_overrides: []const ParamOverride`,
//!   `discipline_resolution: DisciplineResolution`, `empty_unit_ok: bool`
//! - `spice_netlist: []const u8`, `spice_path: ?[]const u8`, `files: ?*Files`
//! - `lint: diag.Levels`, `proof: proof.Options`, `display: Display`,
//!   `int_systfs: []const []const u8`
//! - `codegen: Codegen`, `verilog: ?Verilog`, `osdi: bool`,
//!   `expect_module: ?[]const u8`, `check: bool`, `exe: ?Exe`, `so: bool`,
//!   `zig: bool`, `out_path: ?[]const u8`, `build: Build`
//! - `pub const Verilog = struct`, `pub const Exe = struct`, `pub const Build = struct`
//! - `pub fn lints(c: Config) bool`

const diag = @import("diag");
const std = @import("std");
const keyword = @import("frontend").keyword;
const prove = @import("prove");
const zigbuild = @import("zigbuild");
const Display = @import("device").Display;
const Codegen = @import("Result.zig").Codegen;
const ParamOverride = @import("base").ParamOverride;
const DisciplineResolution = @import("base").DisciplineResolution;

/// The name diagnostics print for the top-level source.
file_name: []const u8 = "<source>",
/// Searched in order for an `include, ahead of the built-in annex D files;
/// also where a §9.21.1 `$table_model` data file is found.
include_dirs: []const []const u8 = &.{},
/// `vera -D`: `NAME` or `NAME=TEXT` macros, defined before the source.
defines: []const []const u8 = &.{},
/// Prepends annex D.2 constants.vams and annex D.1 disciplines.vams
/// (§3.6.2). The Table E.1 primitives are prepended either way (annex E.2).
std_defs: bool = true,
/// The source must `include the annex D files it uses: a D.2 macro without
/// constants.vams is E0115, a D.1 discipline without disciplines.vams is
/// E0371. `vera` sets it in every mode, as does the fixture harness; a
/// library caller compiling text it generated keeps the implicit prelude.
require_std_includes: bool = false,
/// The keyword set, `vera --std=`.
language: keyword.KeywordSet = keyword.default_keyword_set,
/// `vera --sim=`: all of Verilog-AMS, or annex C's Verilog-A subset, in
/// which a digital or mixed-signal construct is E0250. `.verilog` never
/// reaches the analysis: a `.v` design goes through `sim.digital`.
sim: keyword.Sim = .verilog_ams,
/// §3.4 compile-time values for the top module's parameters (`--param`).
/// A shape parameter is compiled to its value and its card may not move
/// it; any other stays a run-time card value whose default this replaces.
param_overrides: []const ParamOverride = &.{},
/// §7.4.4 basic or detail discipline resolution.
discipline_resolution: DisciplineResolution = .basic,
/// A source with no module of its own to elaborate (A.1.2's `source_text`
/// of only connect modules, UDPs, disciplines, pragmas, or nothing) is
/// `error.NothingToElaborate` instead of E1001. A check that builds nothing
/// sets it; a request for a device has none to build (§6.2).
empty_unit_ok: bool = false,
/// Annex E.2 SPICE netlist text whose `.MODEL` and `.SUBCKT` cards the
/// source may instantiate. One card per line, `+` continuations included.
spice_netlist: []const u8 = "",
/// `--spice`: an annex E.2 netlist file, which `compile` reads whole into
/// `spice_netlist`; its `.INCLUDE`, `.LIB` and `.HDL` cards find files beside
/// it. Null resolves them against the working directory. `compile` sets it
/// to the source when a testbench's `//! spice` cards are the netlist.
spice_path: ?[]const u8 = null,
/// Reads every file the source names (`include, netlist cards,
/// `$table_model` data) and records each; `compile` passes the one it makes
/// from its `io`. Null: `analyze` reads through its own.
files: ?*@import("frontend").Files = null,
/// Per-code lint levels (`--allow=W0650`, `--deny=W0651`). Borrowed: the
/// bag the analysis fills reads it until that bag is freed.
lint: diag.Levels = .empty,
/// Class-6 knobs (the solver's compliance bound).
proof: prove.proof.Options = .{},
/// What becomes of the model's display tasks (§9.4): `.record` keeps them
/// for the host (`say`), `.drop` removes them, `.emit` prints them in a
/// testbench. Decided here, not at codegen, because lowering keeps or drops
/// what a card could observe, and W0850 names each task a device drops.
display: Display = .drop,
/// §12.32.1 the user analog system functions registered with sysfunctype
/// vpiIntFunc: a call to one returns an integer. With none, every
/// unresolved `$name` returns a real.
int_systfs: []const []const u8 = &.{},
/// What codegen emits for `check`, `exe`, `so` and `zig`.
codegen: Codegen = .{},
/// `--emit-verilog`: the behavioural module, and nothing else.
verilog: ?Verilog = null,
/// `--emit-osdi`, with `so` and the OSDI dyn as `build.dyn`: refuses what
/// OSDI 0.4 cannot carry (E1099; W1098 warns) before `so` builds, and
/// copies the library to `out_path`, else `<module>.osdi`.
osdi: bool = false,
/// `--expect-module`: refuses a top module of another name.
expect_module: ?[]const u8 = null,
/// `--check`: type-checks the device under the contract's checks.
check: bool = false,
/// `--emit-exe`/`--run`: builds the testbench `Outcome.exe` names.
exe: ?Exe = null,
/// `--emit-so`: builds the device into a library (`Outcome.path`).
so: bool = false,
/// `--emit-zig`: the device text, in `out_path` or on `Outcome.text`.
zig: bool = false,
/// `-o`: where `zig`, `verilog`, `exe` or `osdi` writes its artifact.
out_path: ?[]const u8 = null,
/// How `check`, `exe` and `so` run `zig`.
build: Build = .{},

/// `--emit-verilog`'s pins and supply.
pub const Verilog = struct {
    /// `--digital-pins`: a file of port names when one exists, else the list.
    digital_pins: ?[]const u8 = null,
    power_pins: bool = false,
    /// Logic-high potential in volts.
    vdd: f64 = 1.8,
};

/// `--emit-exe`'s testbench settings.
pub const Exe = struct {
    /// `--validate-contract`: the contract's checks on in the testbench.
    validate_contract: bool = false,
};

/// The `zig` children's settings.
pub const Build = struct {
    /// The `contract` module root. `check`, `exe` and `so` need it.
    contract: ?[]const u8 = null,
    /// The `dyn` module root (`so`).
    dyn: ?[]const u8 = null,
    /// Scratch and artifact directory; `exe` and `osdi` default to
    /// `.zig-cache/vera-tb`, and `so` without `osdi` needs one.
    work_dir: ?[]const u8 = null,
    zig_exe: []const u8 = "zig",
    optimize: std.lang.Optimize = .fast,
    backend: zigbuild.Backend = .llvm,
    /// Keep DWARF in a release artifact.
    debug_info: bool = false,
    /// `zigbuild.Options.artifact_cache` for an `osdi` build.
    artifact_cache: ?[]const u8 = null,
    /// `-j`: most `zig` children alive at once (`zigbuild.Options.jobs`);
    /// null is the CPU count.
    jobs: ?u32 = null,
};

const Config = @This();

/// Whether the request builds nothing: `vera --lint`.
pub fn lints(c: Config) bool {
    return c.verilog == null and !c.check and c.exe == null and !c.so and !c.zig;
}
