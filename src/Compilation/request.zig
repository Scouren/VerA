//! The outcome of one `Compilation.compile`: what was built and what to
//! print (`Config` is what it was asked). A plain value the spine fills.
//!
//! Cites: IEEE 1364-2005 §17.10 (`Outcome.plusargs`).
//!
//! Contents:
//! - `pub const CompileError = Allocator.Error || Io.Writer.Error || zigbuild.CheckError`
//! - `pub const Outcome = struct` (`Outcome.Report`), `Outcome.deinit(o: *Outcome, gpa: Allocator) void`,
//!   `Outcome.done(o: *Outcome, status: u8) void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const zigbuild = @import("zigbuild");
const Result = @import("Result.zig");
const analysis = @import("analyze.zig");

/// Every way `compile` fails, as opposed to refusing (`Outcome.status`):
/// memory, a message the arena could not hold, or a `zig` child that could
/// not be run for `--check`. `o` is filled as far as the call got.
pub const CompileError = Allocator.Error || Io.Writer.Error || zigbuild.CheckError;

/// What `compile` did, for its caller to print: stdout gets `path`, then
/// `text`; stderr gets `err` and the bag in the order `report` says. Every
/// slice lives in the arena `compile` was given or in `device`, which
/// `deinit` frees. Start it as `.{}`.
pub const Outcome = struct {
    /// Exit status: 0 built, 1 refused or failed, 2 a request this source
    /// cannot take.
    status: u8 = 0,
    /// The library `so` built (`osdi`: where it was copied).
    path: ?[]const u8 = null,
    /// The device (`zig`) or the Verilog module (`verilog`) when no
    /// `out_path` took it.
    text: []const u8 = "",
    /// The testbench `exe` built.
    exe: ?[]const u8 = null,
    /// The testbench's `//! plusargs` (IEEE 1364 §17.10), the argv `--run`
    /// gives `exe` after its path.
    plusargs: []const []const u8 = &.{},
    /// The refusal; empty when there is none.
    err: []const u8 = "",
    /// Whether the bag's diagnostics are printed, and where.
    report: Report = .none,
    /// The analysis, once one succeeded.
    result: ?Result = null,
    /// The generated device, once codegen ran; `text` may borrow it.
    device: ?Result.Device = null,

    /// Where the bag's diagnostics go relative to `err` on stderr.
    pub const Report = union(enum) {
        /// `err` alone: the call stopped before the diagnostics were final.
        none,
        /// `err`, then the bag.
        after,
        /// The analysis failed: the bag, then this error's name unless the
        /// bag explains it (`CompileFailed`, `NoModule`).
        failed: analysis.Error,
    };

    /// Frees `device` and `result`; invalidates every slice borrowed from
    /// them. `gpa` is the one `compile` was given.
    pub fn deinit(o: *Outcome, gpa: Allocator) void {
        if (o.device) |*d| d.deinit(gpa);
        if (o.result) |*r| r.deinit(gpa);
        o.* = undefined;
    }

    /// Sets the exit status, once per `compile`. Asserts that it is one of
    /// the statuses `status` documents and that none was set before.
    pub fn done(o: *Outcome, status: u8) void {
        assert(status <= 2);
        assert(o.status == 0); // One verdict per call.
        o.status = status;
    }
};
