//! A `.v` design's run, the one place it is defined: `vera --run`'s
//! interpreter (the driver calls `run` and `report`) and the executable
//! `vera --emit-exe` builds (`main`, over the `Config` its root declares:
//! the `Program` as `std_sim.serial` bytes, the source texts its
//! diagnostics point into, and each timing check's site), so the two
//! print the same bytes by construction.
//! Cites: IEEE 1364-2005 §15.5 (W1199), §17 (the transcript).
//!
//! Contents:
//! - `pub const Config = struct`, `pub const Source = struct`
//! - `pub const stack_size: usize`
//! - `pub fn run(s: *State) State.Error!void`
//! - `pub fn report(s: *const State, result: State.Error!void, wip: *Diag.Wip, pc_sites: []const Diag.Loc, check_sites: []const Diag.Loc) error{ OutOfMemory, WriteFailed }!void`
//! - `pub fn main(init: std.process.Init.Minimal) u8`

const std = @import("std");
const assert = std.debug.assert;
const Diag = @import("vams").Diag;
const State = @import("State.zig");
const Interp = @import("Interp.zig");
const files = @import("files.zig");
const serial = @import("serial.zig");

/// What an executable's root declares as `vera_digital`.
pub const Config = struct {
    /// The `Program`, saved by `std_sim.serial`.
    program: []const u8,
    /// The files the diagnostics' locations index, in their order.
    sources: []const Source,
    /// Per `Program.insts` row, the byte its diagnostics blame; empty
    /// until Sema writes it (`Lowered.pc_sites`): every pc-blamed
    /// diagnostic then renders with no location.
    pc_sites: []const Diag.Loc = &.{},
    /// Per timing check (`Program.checks` order), where its W1199 points.
    check_sites: []const Diag.Loc,
    /// Events at one time step before a zero-delay loop is refused.
    budget: u64 = State.default_budget,
    /// The design's instructions compiled (`State.native`), or none: the
    /// interpreter runs every one.
    native: ?State.Native = null,
    /// `native`'s bitset (`State.native_pcs`); empty when `native` is null.
    native_pcs: []const u64 = &.{},
};

/// One source file: its name as a diagnostic prints it, and its text.
pub const Source = struct { name: []const u8, text: []const u8 };

/// The run's stack: the activations nest with the design (1 GiB, lazily
/// committed).
pub const stack_size: usize = State.stack_size;

/// Runs `s` to completion on a `stack_size` thread, then closes every file
/// it left open (§17.2.1).
pub fn run(s: *State) State.Error!void {
    var result: State.Error!void = {};
    const t = std.Thread.spawn(.{ .stack_size = stack_size }, struct {
        fn go(st: *State, r: *State.Error!void) void {
            r.* = Interp.run(st);
        }
    }.go, .{ s, &result }) catch return error.OutOfMemory;
    t.join();
    files.closeAll(s);
    return result;
}

/// The run's diagnostics into `wip`: every warning `State.diags` kept, in
/// order, then the failure that ended the run, if any (`State.failure`).
/// Each resolves its byte range through `pc_sites` (`Diag.Of.pc`; `.none`
/// while `pc_sites` is empty, not yet wired by Sema) or `check_sites`
/// (`Diag.Of.check`).
pub fn report(s: *const State, result: State.Error!void, wip: *Diag.Wip, pc_sites: []const Diag.Loc, check_sites: []const Diag.Loc) error{ OutOfMemory, WriteFailed }!void {
    assert(pc_sites.len == 0 or pc_sites.len == s.p.insts.len);
    assert(check_sites.len == s.p.checks.len);
    for (s.diags.items) |d| try wip.add(.run, d.code, locOf(d, pc_sites, check_sites), "{s}", .{d.text});
    result catch |e| switch (e) {
        error.SimFailed => {
            const f = s.failure.?;
            try wip.add(.run, f.code, locOf(f, pc_sites, check_sites), "{s}", .{f.text});
        },
        error.OutOfMemory, error.WriteFailed => |x| return x,
    };
}

/// `d`'s byte range, through the table `d.of` names.
fn locOf(d: State.Diag, pc_sites: []const Diag.Loc, check_sites: []const Diag.Loc) Diag.Loc {
    return switch (d.of) {
        .pc => if (pc_sites.len != 0) pc_sites[d.at] else Diag.Loc.none,
        .check => check_sites[d.at],
    };
}

/// The executable's `main`: the run of the root's `vera_digital`, its
/// transcript on stdout, its diagnostics on stderr; 1 when one is an error.
/// A non-empty `VERA_INTERPRET` in the environment runs it without
/// `Config.native`.
pub fn main(init: std.process.Init.Minimal) u8 {
    var cfg: Config = @import("root").vera_digital;
    const gpa = std.heap.smp_allocator;
    // The native step's oracle (`diff-native`) and its benchmark run the
    // same binary through the interpreter alone.
    if (init.environ.containsUnempty(gpa, "VERA_INTERPRET") catch false) cfg.native = null;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out_buf: [1 << 16]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var err_buf: [1 << 16]u8 = undefined;
    var err = std.Io.File.stderr().writerStreaming(io, &err_buf);
    const status = go(arena, io, cfg, &out.interface, &err.interface) catch |e| fail: {
        err.interface.print("error: {t}\n", .{e}) catch {};
        break :fail 1;
    };
    out.interface.flush() catch return 1;
    err.interface.flush() catch return 1;
    return status;
}

// ---- private ----

fn go(arena: std.mem.Allocator, io: std.Io, cfg: Config, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const p = try serial.load(arena, cfg.program);
    var s = State.init(arena, &p, out) catch |e| switch (e) {
        error.SimFailed => unreachable, // `init` lays out tables; only a run fails.
        error.OutOfMemory, error.WriteFailed => |x| return x,
    };
    s.budget = cfg.budget;
    if (cfg.native) |native| {
        assert(cfg.native_pcs.len == @divCeil(p.insts.len, 64));
        s.native = native;
        s.native_pcs = cfg.native_pcs;
    }
    s.io = io;
    const result = run(&s);
    var wip: Diag.Wip = .init(arena);
    try report(&s, result, &wip, cfg.pc_sites, cfg.check_sites);
    var bundle = try wip.toOwnedBundle();
    if (bundle.count() != 0 or bundle.header().suppressed != 0) {
        const sources = try arena.alloc(Diag.Source, cfg.sources.len);
        for (sources, cfg.sources) |*d, src| d.* = .{ .name = src.name, .text = src.text, .line_starts = try Diag.lineStarts(arena, src.text) };
        try Diag.render(bundle, sources, err, .{ .palette = .off });
    }
    return @intFromBool(bundle.failed());
}
