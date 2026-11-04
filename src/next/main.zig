//! `vera-next`, the rewrite's command-line driver (docs/rewrite/comp.md):
//! argv -> one `Compilation.Config` -> `Compilation.update` -> what it
//! built printed, the diagnostics on stderr, the exit status. The old
//! `vera`'s flags, streams, exit codes and messages (`src/main.zig`), so
//! the conformance harness drives either; at the switch-over this file
//! replaces `src/main.zig`.
//!
//! Exit status: 0 on success (warnings do not fail), 1 on a diagnosed
//! error, 2 on a usage error, 126 (`Compilation.not_built_status`) when
//! the input needs a backend `vera-next` does not have yet (named on
//! stderr).
//!
//! Like Zig's `main.zig`, `main` owns the `Io`: an `Io.Threaded` whose
//! workers get `Config.stack_size` stacks and whose limits are `-j`.
//!
//! Cites: IEEE 1800 (refused, E1104); the rest are the stages'.
//!
//! Contents:
//! - `pub fn main(init: std.process.Init.Minimal) !u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const vams = @import("vams");
const Compilation = @import("comp");
const args = @import("cli/args.zig");
const lsp = @import("lsp.zig");
const Diag = vams.Diag;
const Config = Compilation.Config;

/// Returns the process exit status (see the file header).
pub fn main(init: std.process.Init.Minimal) !u8 {
    const gpa = std.heap.smp_allocator;
    var threaded: Io.Threaded = .init(gpa, .{ .stack_size = Config.stack_size, .argv0 = .init(init.args), .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();
    var stdout_buf: [1 << 16]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buf);
    var stderr_buf: [1 << 16]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(io, &stderr_buf);
    const status = drive(gpa, io, &threaded, init, &stdout.interface, &stderr.interface);
    const out_flushed = stdout.interface.flush();
    const err_flushed = stderr.interface.flush();
    const code = try status;
    try out_flushed;
    try err_flushed;
    return code;
}

// ---- private ----

fn drive(gpa: Allocator, io: Io, threaded: *Io.Threaded, init: std.process.Init.Minimal, out: *Io.Writer, err: *Io.Writer) !u8 {
    var cli: args.Options = .{};
    defer cli.deinit(gpa);
    var argv = try init.args.iterateAllocator(gpa);
    defer argv.deinit();
    _ = argv.skip();
    if (try args.parse(&cli, gpa, &argv, out, err)) |code| return code;
    if (try args.resolve(&cli, err)) |code| return code;
    if (cli.lsp) {
        var stdin_buf: [1 << 16]u8 = undefined;
        var stdin = Io.File.stdin().readerStreaming(io, &stdin_buf);
        return lsp.serve(gpa, io, &cli, &stdin.interface, out, err);
    }
    assert(cli.paths.items.len != 0);
    const in_path = cli.paths.items[0];
    const json = cli.json;
    const color = switch (cli.color) {
        .always => true,
        .never => false,
        .auto => Io.File.stderr().isTty(io) catch false,
    };
    if (try refuseLanguage(gpa, in_path, json, err)) |code| return code;
    const digital = std.mem.eql(u8, std.fs.path.extension(in_path), ".v");
    if (try refuseFlags(&cli, digital, in_path, err)) |code| return code;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (try contractTree(io, arena, &cli, digital, err)) |code| return code;
    const threads: u32 = @intCast(@max(1, std.Thread.getCpuCount() catch 1));
    const config = args.config(&cli, cli.paths.items, threads);
    // Zig's `setThreadLimit`: `thread_limit` threads, the main one included.
    threaded.setAsyncLimit(.limited(config.thread_limit - 1));
    threaded.concurrent_limit = .limited(config.thread_limit - 1);

    const comp = try Compilation.create(gpa, io, config);
    defer comp.destroy();
    try comp.update();
    var bundle = try comp.getAllErrors();
    defer bundle.deinit(gpa);
    const o = &comp.outputs;
    // A `--param` refusal (status 2) is the old driver's: the line alone.
    if (o.status == 2) {
        try err.writeAll(o.err.items);
        return 2;
    }
    // `--run`: the testbench runs first, inheriting both streams; the old
    // driver's buffered stderr put its own lines and the warnings after
    // the transcript.
    const ran: ?u8 = if (o.exe != null and config.target == .run and !bundle.failed()) try runTestbench(io, arena, o.exe.?, o.plusargs) else null;
    try out.writeAll(o.out.items);
    try err.writeAll(o.err.items);
    if (bundle.count() != 0 or bundle.header().suppressed != 0) {
        const sources = try comp.sources();
        if (json) try Diag.renderJson(bundle, sources, err) else try Diag.render(bundle, sources, err, .{ .palette = if (color) .on else .off });
        try err.flush();
    }
    if (bundle.failed()) return @max(o.status, 1);
    if (ran) |code| return code;
    const bin = o.exe orelse return o.status;
    try out.print("{s}\n", .{bin});
    return 0;
}

/// `--run`: the testbench inherits both streams, before anything else is
/// printed, and its exit status is `vera`'s (IEEE 1364-2005 §17.10: the
/// plusargs are its arguments).
fn runTestbench(io: Io, arena: Allocator, bin: []const u8, plusargs: []const []const u8) !u8 {
    const argv = try arena.alloc([]const u8, 1 + plusargs.len);
    argv[0] = bin;
    @memcpy(argv[1..], plusargs);
    var child = try std.process.spawn(io, .{ .argv = argv });
    return switch (try child.wait(io)) {
        .exited => |c| c,
        else => 1,
    };
}

/// Refuses an input whose language has no compilation path: IEEE 1800 is
/// E1104, VHDL a plain refusal. Null for any other extension.
fn refuseLanguage(gpa: Allocator, in_path: []const u8, json: bool, err: *Io.Writer) !?u8 {
    const ext = std.fs.path.extension(in_path);
    if (std.mem.eql(u8, ext, ".sv")) {
        var w: Diag.Wip = .init(gpa);
        defer w.deinit();
        try w.add(.parse, .E1104, .none, "`{s}` is an IEEE 1800 source", .{in_path});
        var d = try w.toOwnedBundle();
        defer d.deinit(gpa);
        if (json) try Diag.renderJson(d, &.{}, err) else try Diag.render(d, &.{}, err, .{});
        return 2;
    }
    if (std.mem.eql(u8, ext, ".vhd") or std.mem.eql(u8, ext, ".vhdl")) {
        try err.print("error: {s}: this language extension has no enabled compilation path\n", .{in_path});
        try err.writeAll("note: use --run FILE.v for the documented digital Verilog execution subset\n");
        return 2;
    }
    return null;
}

/// The old driver's refusals of the flags the source's language cannot
/// take (`src/main.zig` `refuseFlags`, `src/cli/digital.zig` `run`).
fn refuseFlags(cli: *const args.Options, digital: bool, in_path: []const u8, err: *Io.Writer) Io.Writer.Error!?u8 {
    assert(cli.paths.items.len != 0);
    if (cli.sim == .verilog and !digital) return refused(err, "error: --sim=verilog compiles IEEE 1364 designs (.v); `{s}` is not one\n", in_path);
    if (cli.sim == .verilog_a and digital) return refused(err, "error: --sim=verilogA compiles Verilog-A models (.va); `{s}` is a digital design\n", in_path);
    if (!digital) {
        if (cli.paths.items.len > 1) return refused(err, "error: more than one input file\n", "");
        if (cli.libmaps.items.len != 0 or cli.search.items.len != 0) return refused(err, "error: --libmap and -L configure a .v design's libraries\n", "");
    }
    if (cli.logic_flag) |f| if (!digital or cli.run_exe) return refused(err, "error: {s} builds a .v design's executable; it takes --emit-exe and a .v file\n", f);
    if (!digital and cli.emit_rtlil) return refused(err, "error: {s}: --emit-rtlil takes an IEEE 1364 design (.v)\n", in_path);
    if (!digital and cli.elab) return refused(err, "error: {s}: --elab takes an IEEE 1364 design (.v); --lint elaborates a Verilog-A/AMS source\n", in_path);
    if (digital and cli.emit_verilog) return refused(err, "error: {s}: --emit-verilog takes a Verilog-A model (.va)\n", in_path);
    if (digital) {
        const device = cli.emit_zig or cli.check or cli.emit_so;
        if (!cli.emit_rtlil and !cli.elab and ((cli.exe_flag == null) == !device or cli.lint_flag or (cli.out_path != null and !cli.emit_zig and !cli.emit_osdi)))
            return refused(err, "error: digital .v source takes --run or --emit-exe, or --emit-zig, --check or --emit-so for a contract device\n", "");
    }
    return null;
}

fn refused(err: *Io.Writer, comptime fmt: []const u8, arg: []const u8) Io.Writer.Error!?u8 {
    if (comptime std.mem.find(u8, fmt, "{s}") != null) try err.print(fmt, .{arg}) else try err.writeAll(fmt);
    return 2;
}

/// When a `zig` build needs a contract, checks a typed `--contract` and,
/// without one, writes this vera's own `lib/` tree under the work
/// directory and points `cli.contract_path` into it (the old driver's
/// `contractTree`).
fn contractTree(io: Io, arena: Allocator, cli: *args.Options, digital: bool, err: *Io.Writer) !?u8 {
    const builds = cli.check or cli.emit_so or (cli.exe_flag != null and !(digital and cli.run_exe));
    if (!builds) return null;
    if (cli.contract_path) |p| Io.Dir.cwd().access(io, p, .{}) catch |e| {
        try err.print("error: --contract {s}: {t}\n", .{ p, e });
        return 2;
    };
    if (cli.contract_path != null and !cli.emit_osdi) return null;
    const wd = cli.work_dir orelse ".zig-cache/vera-tb";
    const c = simTree(io, arena, wd) catch |e| {
        try err.print("error: writing the engine sources under {s} failed: {t}\n", .{ wd, e });
        return 1;
    };
    if (cli.contract_path == null) cli.contract_path = c;
    if (cli.emit_osdi) cli.dyn_path = try std.fs.path.join(arena, &.{ std.fs.path.dirname(c).?, "osdi_dyn.zig" });
    assert(cli.contract_path != null);
    return null;
}

/// Writes the embedded `lib/` and Gompute trees under `dir`, each file atomically (a
/// concurrent `vera-next` writing the same tree never exposes half a
/// file); returns the `contract` root.
fn simTree(io: Io, arena: Allocator, dir: []const u8) ![]const u8 {
    assert(dir.len != 0);
    const root = try std.fs.path.join(arena, &.{ dir, "vera-src" });
    var d = try Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer d.close(io);
    // `lib/`, then Gompute's math beside it as `gompute/` (std_kernels'
    // `gompute_math`), as the switch-over ships it (lib/TODO.md §12).
    const files = @import("sim_sources").files ++ @import("gompute_sources").files;
    comptime assert(files.len != 0);
    for (files) |f| {
        var af = try d.createFileAtomic(io, f[0], .{ .make_path = true, .replace = true });
        defer af.deinit(io);
        try af.file.writeStreamingAll(io, f[1]);
        try af.replace(io);
    }
    return std.fs.path.join(arena, &.{ root, "lib", "contract.zig" });
}

test {
    _ = args;
    _ = lsp;
    _ = @import("lsp_diagnostics.zig");
}
