//! The compilation (Zig's `src/Compilation.zig`, lib/TODO.md §3): a
//! `Config` in; the artifact it names, the text `main` prints and one
//! diagnostic bundle out. The only place that reads files, owns threads,
//! divides the work into jobs and decides how many run at once. Every
//! stage is a merged module called as a pure function over one input:
//! the `vams` Preprocessor, Parse and AstGen, `vams.spice`, `sema`'s
//! elaboration and its analog and digital lowering, the `Air` passes,
//! `codegen`, `link`, `std_sim`. A stage that needs a file raises a
//! request; `read` answers every one.
//!
//! ```zig
//! var comp = try Compilation.create(gpa, io, config);
//! defer comp.destroy();
//! try comp.update();
//! var errors = try comp.getAllErrors();
//! defer errors.deinit(gpa);
//! ```
//!
//! Cites: VAMS-2023 §10 (preprocessing is serial over the units, §3.1 of
//! the plan), annex E.2; IEEE 1364-2005 §13.4.1. Each stage cites its own.
//!
//! Contents:
//! - fields `gpa`, `io`, `arena_state`, `config`, `queue`, `next_job`, `reads`, `pp`, `netlist`, `units`, `zcu`, `analysis`, `float`, `device`, `bench`, `lowered`, `wip`, `outputs`, `stopped`
//! - `pub const Config`, `pub const Job`, `pub const Unit`, `pub const Read`, `pub const Outputs`, `pub const Backend`, `pub const not_built_status`, `pub const jobs_max`
//! - `pub fn create(gpa: Allocator, io: Io, config: Config) Allocator.Error!*Compilation`
//! - `pub fn destroy(comp: *Compilation) void`
//! - `pub fn update(comp: *Compilation) UpdateError!void`, `pub const UpdateError`
//! - `pub fn getAllErrors(comp: *Compilation) Allocator.Error!Diag`
//! - `pub fn sources(comp: *Compilation) Allocator.Error![]const Diag.Source`
//! - `pub fn read(comp: *Compilation, path: []const u8) Allocator.Error!Read`
//! - `pub fn arena(comp: *Compilation) Allocator`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const vams = @import("vams");
const sema = @import("sema");
const Air = @import("air");
const link = @import("link");
const codegen = @import("codegen");
const frontend = @import("Compilation/frontend.zig");
const backend = @import("Compilation/backend.zig");
const errors = @import("Compilation/errors.zig");
const Diag = vams.Diag;
const Zcu = sema.Zcu;

/// The compilation's settings, resolved.
pub const Config = @import("Compilation/Config.zig");

gpa: Allocator,
io: Io,
/// Everything that lives as long as the compilation: read bytes, paths,
/// the preprocessed texts, the outputs' slices.
arena_state: std.heap.ArenaAllocator,
config: Config,
/// The jobs in the order they run; each job queues its successors.
queue: std.ArrayList(Job) = .empty,
/// The first job of `queue` not run yet.
next_job: u32 = 0,
/// Every file the compilation read, by the path asked: the one reader.
reads: std.StringArrayHashMapUnmanaged(Read) = .empty,
pp: vams.Preprocessor,
/// Annex E.2's netlist (`--spice`), read before preprocessing.
netlist: ?vams.spice.Netlist = null,
/// The texts AstGen ran over, one per `Zcu` file, in file order.
units: std.ArrayList(Unit) = .empty,
zcu: Zcu,
analysis: ?sema.Sema.Analysis = null,
float: ?Air.Float = null,
/// The device `codegen` wrote; its text on `gpa`.
device: ?link.Output = null,
/// `--emit-exe`/`--run`: the input's `//!` testbench directives.
bench: ?codegen.bench.Spec = null,
lowered: ?sema.digital.Lowered = null,
/// The diagnostics of the stages that report through a `Wip` (the SPICE
/// reader, the float verdict) and of the compilation itself.
wip: Diag.Wip,
outputs: Outputs = .{},
/// A job found an error: no successor was queued.
stopped: bool = false,

/// One step of `update`, run in queue order (lib/TODO.md §3's table).
pub const Job = union(enum) {
    read_inputs,
    spice,
    preprocess,
    /// Parse and AstGen of `units[i]`; the jobs of one batch run at once.
    astgen: u32,
    sema_top,
    sema_analog,
    sema_digital,
    air_passes,
    codegen: Backend,
    link: enum { check, so },
    run_digital,
};

/// Every backend `codegen`'s dispatch names. Only `zig` is merged; the
/// others' prongs report "not built" (`not_built_status`).
pub const Backend = enum { zig, exe, verilog, osdi, rtlil, digital_device, digital_exe, libmap };

/// The exit status of an input that needs a backend not built yet: above
/// 125, which the conformance harness reads as "the tool could not run
/// the command", so a `//! reject` fixture never passes on a missing
/// backend (a status in 1..125 is a diagnosed refusal there).
pub const not_built_status: u8 = 126;

/// Most jobs one update queues: one per stage and one per unit, so a
/// longer queue is a loop.
pub const jobs_max: u32 = 1 << 16;

/// One AstGen'd text: the preprocessor's output (borrowed from `pp`), its
/// tree and its Vir, and how many of its leading modules are built in.
pub const Unit = struct {
    text: [:0]const u8,
    tree: vams.Ast,
    vir: vams.Vir,
    builtins: u32,
};

/// A read's outcome: the bytes, or the error that stopped it.
pub const Read = union(enum) { bytes: []const u8, failed: anyerror };

/// What `main` prints and returns; every slice in the arena.
pub const Outputs = struct {
    /// stdout: device text, a transcript, an artifact's path.
    out: std.ArrayList(u8) = .empty,
    /// Plain lines printed on stderr ahead of the diagnostics.
    err: std.ArrayList(u8) = .empty,
    /// The exit status when the diagnostics hold no error: 0, or 1/2 for a
    /// refusal written on `err`, or `not_built_status` when `not_built`
    /// names a backend.
    status: u8 = 0,
    not_built: ?Backend = null,
    /// `--emit-exe`/`--run`: the built testbench, which `main` prints or
    /// runs with `plusargs` (IEEE 1364-2005 §17.10).
    exe: ?[]const u8 = null,
    plusargs: []const []const u8 = &.{},
};

/// Every way `update` fails rather than reports.
pub const UpdateError = Allocator.Error || Io.Writer.Error || std.Thread.SpawnError || error{TooManyJobs};

const Compilation = @This();

/// A compilation of `config`, nothing read yet. `config`'s slices are
/// borrowed until `destroy`.
pub fn create(gpa: Allocator, io: Io, config: Config) Allocator.Error!*Compilation {
    assert(config.paths.len != 0);
    assert(config.thread_limit >= 1);
    const comp = try gpa.create(Compilation);
    errdefer gpa.destroy(comp);
    comp.* = .{
        .gpa = gpa,
        .io = io,
        .arena_state = .init(gpa),
        .config = config,
        .pp = undefined,
        .zcu = try .init(gpa),
        .wip = .init(gpa),
    };
    comp.wip.levels = config.levels;
    comp.pp = .init(gpa, .{
        .include_dirs = config.include_dirs,
        .defines = config.defines,
        .std_defs = config.std_defs and !config.digital(),
        .spice_primitives = !config.digital(),
        .require_std_includes = true,
        .std_1364 = @backingInt(config.language) < @backingInt(vams.Ast.KeywordSet.vams_2_3),
    });
    return comp;
}

/// Frees everything the compilation owns.
pub fn destroy(comp: *Compilation) void {
    const gpa = comp.gpa;
    for (comp.units.items) |*u| {
        u.tree.deinit(gpa);
        u.vir.deinit(gpa);
    }
    comp.units.deinit(gpa);
    if (comp.analysis) |*a| a.deinit(gpa);
    if (comp.float) |*f| f.deinit(gpa);
    if (comp.device) |d| gpa.free(d.text);
    if (comp.netlist) |*n| n.deinit();
    comp.zcu.deinit();
    comp.pp.deinit();
    comp.wip.deinit();
    comp.queue.deinit(gpa);
    comp.reads.deinit(gpa);
    comp.arena_state.deinit();
    gpa.destroy(comp);
}

/// The compilation's arena.
pub fn arena(comp: *Compilation) Allocator {
    return comp.arena_state.allocator();
}

/// Runs every job (Zig's `performAllTheWork`): reading, preprocessing
/// (serial, command-line order), then one AstGen job per unit (at most
/// `thread_limit` at once, each on a `Config.stack_size` worker), the
/// elaboration, the analog or digital lowering, the passes, the backend
/// and the link. A stage that reports an error stops the queue; what it
/// reported is `getAllErrors`'. Runs once.
pub fn update(comp: *Compilation) UpdateError!void {
    assert(comp.queue.items.len == 0);
    try comp.queue.append(comp.gpa, .read_inputs);
    var n: u32 = 0;
    while (comp.next_job < comp.queue.items.len) : (n += 1) {
        if (n == jobs_max) return error.TooManyJobs;
        const job = comp.queue.items[comp.next_job];
        comp.next_job += 1;
        switch (job) {
            .astgen => try comp.astgenBatch(),
            else => try comp.runJob(job),
        }
    }
    assert(comp.next_job == comp.queue.items.len);
}

/// The diagnostics of every stage, merged into one bundle in source order
/// (Zig's `getAllErrorsAlloc`); owned by the caller (`Diag.deinit(gpa)`).
pub fn getAllErrors(comp: *Compilation) Allocator.Error!Diag {
    return errors.bundle(comp);
}

/// The file table every `Loc` of `getAllErrors` indexes, in the arena.
pub fn sources(comp: *Compilation) Allocator.Error![]const Diag.Source {
    return errors.sources(comp);
}

/// The bytes at `path`, read once: the compilation's one reader, which
/// every request of every stage goes through.
pub fn read(comp: *Compilation, path: []const u8) Allocator.Error!Read {
    if (comp.reads.get(path)) |r| return r;
    for (comp.config.overlays) |o| if (std.mem.eql(u8, o.path, path)) return .{ .bytes = o.bytes };
    const a = comp.arena();
    const r: Read = if (path.len == 0) .{ .failed = error.FileNotFound } else if (Io.Dir.cwd().readFileAlloc(comp.io, path, a, .limited(std.math.maxInt(u32)))) |b|
        .{ .bytes = b }
    else |e|
        .{ .failed = e };
    try comp.reads.put(comp.gpa, try a.dupe(u8, path), r);
    assert(comp.reads.contains(path));
    return r;
}

// ---- private ----

/// Queues `job` after the ones queued so far.
fn queueJob(comp: *Compilation, job: Job) Allocator.Error!void {
    assert(comp.queue.items.len < jobs_max);
    try comp.queue.append(comp.gpa, job);
}

fn runJob(comp: *Compilation, job: Job) UpdateError!void {
    assert(!comp.stopped);
    const next: ?Job = switch (job) {
        .read_inputs => if (try frontend.readInputs(comp)) (if (comp.config.spice_path != null or comp.netlist != null) .spice else .preprocess) else null,
        .spice => if (try frontend.spice(comp)) .preprocess else null,
        .preprocess => if (try frontend.preprocess(comp)) .{ .astgen = 0 } else null,
        .astgen => unreachable, // `update` runs these in batches.
        .sema_top => if (try frontend.semaTop(comp)) (if (comp.config.digital()) .sema_digital else .sema_analog) else null,
        .sema_analog => if (try backend.semaAnalog(comp)) .air_passes else null,
        .sema_digital => try backend.semaDigital(comp),
        .air_passes => if (try backend.airPasses(comp)) try backend.analogBackend(comp) else null,
        .codegen => |b| try backend.codegen(comp, b),
        .link => |t| try backend.link(comp, t),
        .run_digital => try backend.runDigital(comp),
    };
    if (next) |j| try comp.queueJob(j) else comp.stopped = true;
}

/// Runs every `astgen` job queued from the current one on, up to
/// `thread_limit` at once, then queues `sema_top`.
fn astgenBatch(comp: *Compilation) UpdateError!void {
    const first = comp.next_job - 1;
    while (comp.next_job < comp.queue.items.len and comp.queue.items[comp.next_job] == .astgen) comp.next_job += 1;
    const jobs = comp.queue.items[first..comp.next_job];
    assert(jobs.len == comp.units.items.len);
    var group: Io.Group = .init;
    var failed: std.atomic.Value(bool) = .init(false);
    var oom: std.atomic.Value(bool) = .init(false);
    // Io.Threaded's limits (`thread_limit - 1` workers, as Zig's main sets
    // them) bound how many run at once; past them a job runs here.
    for (jobs) |j| group.concurrent(comp.io, frontend.astgen, .{ comp, j.astgen, &failed, &oom }) catch
        frontend.astgen(comp, j.astgen, &failed, &oom);
    group.await(comp.io) catch {};
    if (oom.load(.monotonic)) return error.OutOfMemory;
    if (failed.load(.monotonic)) {
        comp.stopped = true;
        return;
    }
    try comp.queueJob(.sema_top);
}

test {
    _ = Config;
    _ = frontend;
    _ = backend;
    _ = errors;
    _ = @import("Compilation/test.zig");
}
