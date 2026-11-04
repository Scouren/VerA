//! What a fixture's `//!` lines say (`Spec`), split by reader: `Bench`,
//! the data the runner runs (`std_sim.bench`'s, written into the runner as
//! a literal), and `Harness`, what the caller compiles, runs and judges
//! with. `parse.zig` writes a `Spec`.
//! Cites: §2.4, §3.4, §4.6.1, §7.4.4, §9.4, §9.15; Annex E.
//!
//! Contents:
//! - `pub const ParseError`, `pub const RenderError`, `pub const Diagnostics = struct { line: u32 }`
//! - `pub const Spec = struct { bench: Bench, harness: Harness }`, `Spec.parse`
//! - `pub const Harness = struct`
//! - from `std_sim.bench`: `Bench`, `Config`, `Digital`, `Binding`, `Sweep`, `LimitCase`, `Analysis`, `Print`, `NoiseWant`, `AcWant`, `AcDynWant`, `points_max`

const std = @import("std");
const Allocator = std.mem.Allocator;
const rows = @import("std_sim").bench_data;

pub const Bench = rows.Bench;
pub const Config = rows.Config;
pub const Digital = rows.Digital;
pub const Binding = rows.Binding;
pub const Sweep = rows.Sweep;
pub const LimitCase = rows.LimitCase;
pub const Analysis = rows.Analysis;
pub const Print = rows.Print;
pub const NoiseWant = rows.NoiseWant;
pub const AcWant = rows.AcWant;
pub const AcDynWant = rows.AcDynWant;
pub const points_max = rows.points_max;

/// Every way `Spec.parse` fails. The failing line is in `Diagnostics.line`;
/// `arena` may hold the partial result, nothing else is written.
pub const ParseError = Allocator.Error || error{
    /// A `//!` line opened with a word that is no directive. Refused so a
    /// typo cannot silently check nothing.
    UnknownDirective,
    /// An operand was not a number, or not the plain decimal digits a count
    /// or an exit status takes.
    BadNumber,
    /// An operand does not have its directive's documented form (a missing
    /// `name = value`, an unknown field key, an empty name), or two lines
    /// contradict each other (`reject` beside `checks`, `warn` beside `nowarn`).
    BadSyntax,
    /// A `//! lrm` or `//! inherited` cite is not a section number.
    BadLrmSection,
    /// A `bias`/`sweep`/`wave`/`seed`/`abstol`/`limit` line named something
    /// that is not a solver unknown, such as the branch potential `V(a,c)`.
    BadUnknownName,
    /// A `//! time` before 0: a transient starts at 0 (§4.5.4's `$abstime`
    /// is not negative), and the digital half's ticks count up from it.
    BadTime,
};

/// Every way a renderer fails. Nothing is written on `TooManyPoints`; on
/// the others the writer holds a prefix of the runner. `OutOfMemory` is the
/// mixed runner's `scratch` running out.
pub const RenderError = Allocator.Error || error{
    /// The writer failed (an `Allocating` writer's out of memory).
    WriteFailed,
    /// The `sweep` and `psweep` lengths multiply past `points_max`.
    TooManyPoints,
};

/// Where `Spec.parse` failed, filled only on error.
pub const Diagnostics = struct {
    /// 1-based line of the rejected directive; 0 when two lines contradict
    /// each other and no one line is at fault. Saturates past 2^32 - 1.
    line: u32 = 0,
};

/// Everything the `//!` lines of one fixture said. With no directives the
/// fixture runs one point, every unknown at zero and every parameter at its
/// §3.4 default. Every slice points into the arena `parse` was given, so a
/// `Spec` must not outlive it.
pub const Spec = struct {
    bench: Bench = .{},
    harness: Harness = .{},

    /// Parses the `//!` lines of RAW source (`parse.zig`).
    pub const parse = @import("parse.zig").parse;
};

/// What the caller compiles, runs and judges with; no renderer reads it.
pub const Harness = struct {
    /// Expected normal exit status; a signal always fails the fixture.
    expected_exit: u8 = 0,
    /// Exact number of runtime verdict columns across the run, when stated.
    expected_checks: ?u32 = null,
    /// Runtime argv entries in source order, each printable ASCII starting
    /// with `+` and holding another byte; no quoting or expansion.
    plusargs: []const []const u8 = &.{},
    /// Annex E `//! spice` netlist lines joined with `\n`, verbatim.
    spice: []const u8 = "",
    /// §7.4.4 the mode the fixture is compiled in.
    discipline_resolution: enum { basic, detail } = .basic,
    /// §9.4 the device records its display tasks (`--display=record`).
    display_record: bool = false,
    /// `//! reject` substrings: non-empty makes this a fixture that must not
    /// compile, every substring appearing in the diagnostics.
    reject: []const []const u8 = &.{},
    /// `//! reject-only`: every error must also match one of `reject`.
    reject_only: bool = false,
    /// `//! reject-run` substrings: the run (not the compile) refuses, exits
    /// `expected_exit` (non-zero) and prints an `error[...]` line per entry.
    reject_run: []const []const u8 = &.{},
    /// Legal twins of a refusal, relative to the fixture's directory.
    neighbours: []const []const u8 = &.{},
    /// Substrings each matching a warning the compile reported.
    warn: []const []const u8 = &.{},
    /// `//! nowarn`: the compile reports no warning at all.
    nowarn: bool = false,
    /// The clauses this fixture pins (`5.8`, `5.6.1.3:2`); no verdict reads them.
    lrm: []const []const u8 = &.{},
    /// `//! xfail` reason: a requirement VerA does not meet yet.
    xfail: ?[]const u8 = null,
    /// `//! fd-exempt` reason: the `--certify` gates do not apply.
    fd_exempt: ?[]const u8 = null,
};
