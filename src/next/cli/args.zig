//! `vera-next`'s argv -> one `Options` value, then one `Compilation.Config`:
//! what the user typed, flag by flag, in order (`parse`), then the conflicts
//! between well-formed flags refused and what they derive settled
//! (`resolve`), whatever their order, then the resolved configuration
//! (`config`). The old `src/cli/args.zig`'s tables and messages, verbatim:
//! the flags, their spelling and every message are user-visible and frozen.
//! `--help`, `--version` and `--explain` answer in `parse`; a malformed flag
//! is refused there with exit status 2.
//!
//! Cites: LRM 3.4 (`--param`), annex E.2 (`--spice`), IEEE 1364-2005 §3.7.1
//! (`-D` names), §13.2 and §13.7.1 (`--libmap`, `-L`), §15.5.4
//! (`--negative-timing`).
//!
//! Contents:
//! - `pub const usage_text` (from `usage.zig`), `pub const Options`
//! - `pub const ParseError = Allocator.Error || Io.Writer.Error`
//! - `pub fn parse(cli: *Options, gpa: Allocator, args: anytype, out: *Io.Writer, err: *Io.Writer) ParseError!?u8`
//! - `pub fn resolve(cli: *Options, err: *Io.Writer) Io.Writer.Error!?u8`
//! - `pub fn missing(w: *Io.Writer, flag: []const u8, what: []const u8) Io.Writer.Error!u8`
//! - `pub fn config(cli: *const Options, paths: []const []const u8, thread_limit: u32) Config`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const vams = @import("vams");
const Config = @import("comp").Config;
const diag = vams.Diag;
const Display = Config.Display;
/// The VerA release: what `--version` prints.
const vera_version = @import("contract").vera_version;

/// `--help`, and what a command line naming no input prints to stderr.
pub const usage_text = @import("usage.zig").usage_text;

/// One command line, as typed.
pub const Options = @import("Options.zig");

/// Every way `parse` fails: the lists could not grow, or `out`/`err` could
/// not take the answer. `cli` keeps what it read before the failure.
pub const ParseError = Allocator.Error || Io.Writer.Error;

const Cli = Options;

/// A whole-argument flag. Those that take a value read the next argument.
const Switch = enum {
    help,
    version,
    explain,
    lint,
    elab,
    lsp,
    emit_zig,
    emit_verilog,
    emit_rtlil,
    digital_pins,
    power_pins,
    check,
    emit_so,
    emit_osdi,
    emit_exe,
    run,
    validate_contract,
    jac_f32,
    jac_f32_host,
    contract,
    param,
    dyn,
    work_dir,
    debug_info,
    zig,
    negative_timing,
    two_state,
    out,
    spice,
    libmap,
    protect_keys,
    library,
    include,
    no_std_defs,
    json,
    text,
    color_always,
    color_never,
    color_auto,
};

const switches = std.StaticStringMap(Switch).initComptime(.{
    .{ "--help", .help },                       .{ "-h", .help },
    .{ "--version", .version },                 .{ "-v", .version },
    .{ "-V", .version },                        .{ "--explain", .explain },
    .{ "--lint", .lint },                       .{ "--elab", .elab },
    .{ "--lsp", .lsp },                         .{ "--emit-zig", .emit_zig },
    .{ "--emit-verilog", .emit_verilog },       .{ "--emit-rtlil", .emit_rtlil },
    .{ "--digital-pins", .digital_pins },       .{ "--power-pins", .power_pins },
    .{ "--check", .check },                     .{ "--emit-so", .emit_so },
    .{ "--emit-osdi", .emit_osdi },             .{ "--emit-exe", .emit_exe },
    .{ "--run", .run },                         .{ "--validate-contract", .validate_contract },
    .{ "--jac-f32", .jac_f32 },                 .{ "--jac-f32-host", .jac_f32_host },
    .{ "--contract", .contract },               .{ "--param", .param },
    .{ "--dyn", .dyn },                         .{ "--work-dir", .work_dir },
    .{ "--debug-info", .debug_info },           .{ "--zig", .zig },
    .{ "--negative-timing", .negative_timing }, .{ "--two-state", .two_state },
    .{ "-o", .out },                            .{ "--spice", .spice },
    .{ "--libmap", .libmap },                   .{ "--protect-keys", .protect_keys },
    .{ "-L", .library },                        .{ "-I", .include },
    .{ "--no-std-defs", .no_std_defs },         .{ "--diagnostics=json", .json },
    .{ "--diagnostics=text", .text },           .{ "--color=always", .color_always },
    .{ "--color=never", .color_never },         .{ "--color=auto", .color_auto },
});

/// A `--name=value` flag, keyed by its text through the `=`.
const Valued = enum {
    vdd,
    display,
    optimize,
    state,
    schedule,
    event_budget,
    zig_backend,
    expect_module,
    std,
    sim,
    discipline_resolution,
    unknown_bound,
    jobs,
};

const valued = std.StaticStringMap(Valued).initComptime(.{
    .{ "--vdd=", .vdd },                                     .{ "--display=", .display },
    .{ "--optimize=", .optimize },                           .{ "--state=", .state },
    .{ "--schedule=", .schedule },                           .{ "--event-budget=", .event_budget },
    .{ "--zig-backend=", .zig_backend },                     .{ "--expect-module=", .expect_module },
    .{ "--std=", .std },                                     .{ "--sim=", .sim },
    .{ "--discipline-resolution=", .discipline_resolution }, .{ "--unknown-bound=", .unknown_bound },
    .{ "--jobs=", .jobs },
});

/// `--optimize=` names. Zig 0.17 renamed `std.lang.Optimize`'s tags
/// (`fast`, ...); the flag keeps the names it always took.
const optimize_names = std.StaticStringMap(std.lang.Optimize).initComptime(.{
    .{ "Debug", .debug },
    .{ "ReleaseSafe", .safe },
    .{ "ReleaseFast", .fast },
    .{ "ReleaseSmall", .small },
});

/// The arguments one command line may hold: past this the line is refused,
/// so a runaway generator cannot grow the lists without bound.
const args_max: u32 = 1 << 20;

/// A fixed command line, the iterator shape `parse` reads.
const TestArgv = struct {
    items: []const []const u8,
    i: usize = 0,

    fn next(a: *TestArgv) ?[]const u8 {
        if (a.i == a.items.len) return null;
        defer a.i += 1;
        return a.items[a.i];
    }
};

/// Reads every argument after argv[0] into `cli`, in order. Returns null to
/// go on, or the process exit code when the line is answered here: 0 after
/// `--help` (usage on `out`), `--version` (`vera <contract.vera_version>` on
/// `out`) or `--explain CODE` (the explanation on `out`), 2 after a
/// malformed flag (the reason on `err`). Stops at the first such flag, so
/// the rest of the line is never read. `args` is any iterator whose `next()`
/// returns each argument as a `?[]const u8` (`std.process.Args.Iterator`, a
/// tokenizer, a test's fixed list); `cli` borrows every argument it keeps, so
/// the iterator's storage must outlive `cli`. The lists grow in `gpa`, which
/// `Cli.deinit` takes.
pub fn parse(cli: *Cli, gpa: Allocator, args: anytype, out: *Io.Writer, err: *Io.Writer) ParseError!?u8 {
    const paths_before = cli.paths.items.len;
    var n: u32 = 0;
    while (args.next()) |arg| : (n += 1) {
        if (n == args_max) {
            try err.print("error: more than {d} arguments\n", .{args_max});
            return 2;
        }
        if (switches.get(arg)) |s| {
            if (try takeSwitch(cli, gpa, s, arg, args, out, err)) |code| return code;
        } else if (valuedKey(arg)) |v| {
            if (try takeValued(cli, v, arg, arg[std.mem.findScalar(u8, arg, '=').? + 1 ..], err)) |code| return code;
        } else if (std.mem.startsWith(u8, arg, "-D")) {
            const d = if (arg.len > 2) arg[2..] else args.next() orelse return try missing(err, "-D", "NAME[=TEXT]");
            const name = d[0 .. std.mem.findScalar(u8, d, '=') orelse d.len];
            if (!isMacroName(name)) {
                try err.print("error: -D {s}: `{s}` is not a macro name (a simple identifier, IEEE 1364-2005 3.7.1)\n", .{ d, name });
                return 2;
            }
            try cli.defines.append(gpa, d);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            // --allow=X / --warn=X / --deny=X / --forbid=X
            const applied = cli.levels.parseFlag(arg[2..]) catch |e| switch (e) {
                error.CannotAllowError => {
                    try err.print("error: `{s}`: an error code cannot be allowed or warned away — it is a statement about the program, not a preference\n", .{arg});
                    return 2;
                },
                error.Forbidden => {
                    try err.print("error: `{s}`: this code was already --forbid'd\n", .{arg});
                    return 2;
                },
            };
            if (!applied) {
                try err.print("error: unknown option `{s}`\n", .{arg});
                return 2;
            }
        } else {
            if (try nameTooLong(err, "an input", arg)) return 2;
            try cli.paths.append(gpa, arg);
        }
    }
    assert(cli.paths.items.len >= paths_before);
    assert(n <= args_max);
    return null;
}

/// Refuses the well-formed flags that conflict, whatever order they came in,
/// and settles what they derive: `--display=record` beside a testbench makes
/// it print the device's records, `--sim=verilog` without a `--std` reads as
/// IEEE 1364-2005, and `--emit-rtlil`/`--emit-osdi` make `-o` name their own
/// file rather than a device. Returns null to go on, or exit status 2 with
/// the reason on `err`, or the usage when the line names no input. Runs
/// once, after `parse` returned null.
pub fn resolve(cli: *Cli, err: *Io.Writer) Io.Writer.Error!?u8 {
    // `--sim=verilog` is IEEE 1364 Verilog and the other two are Verilog-AMS
    // keyword sets, so a `--std=` of the other family conflicts.
    if (cli.sim_flag) |f| {
        const is_1364 = @backingInt(cli.language) < @backingInt(vams.Ast.KeywordSet.vams_2_3);
        if (cli.std_flag) |s| if (is_1364 != (cli.sim == .verilog)) {
            try err.print("error: `{s}` and `{s}` conflict: {s}\n", .{ f, s, if (cli.sim == .verilog) "--sim=verilog compiles IEEE 1364 Verilog" else "Verilog-A is a Verilog-AMS keyword set" });
            return 2;
        };
        if (cli.sim == .verilog and cli.std_flag == null) cli.language = .v1364_2005;
    }
    if (cli.exe_flag) |f| if (cli.display_flag == Display.drop) {
        try err.print("error: `{s}` and `--display=drop` conflict: the testbench IS the display output, and `--display=drop` discards every print\n", .{f});
        return 2;
    };
    // §9.4 a testbench over the device a host gets: it prints the records
    // the device's `say` makes, whichever flag came first.
    if (cli.exe_flag != null and cli.display_flag == Display.record) cli.display = .record;
    if (cli.validate_contract and cli.exe_flag == null) {
        try err.writeAll("error: `--validate-contract` turns the checks on in an --emit-exe or --run testbench; --check always runs them\n");
        return 2;
    }
    const elab_other: ?[]const u8 = cli.codegen_flag orelse if (cli.lint_flag) "--lint" else if (cli.emit_rtlil) "--emit-rtlil" else null;
    if (cli.elab) if (elab_other) |f| {
        try err.print("error: `--elab` and `{s}` conflict: --elab stops after elaboration\n", .{f});
        return 2;
    };
    if (cli.lint_flag) if (cli.codegen_flag) |f| {
        try err.print("error: `--lint` and `{s}` conflict: --lint stops after the frontend and `{s}` needs codegen\n", .{ f, f });
        return 2;
    };
    if (cli.lsp) {
        if (cli.lint_flag or cli.codegen_flag != null) {
            try err.print("error: `--lsp` and `{s}` conflict: the server lints each open document itself\n", .{cli.codegen_flag orelse "--lint"});
            return 2;
        }
        if (cli.paths.items.len != 0) {
            try err.writeAll("error: `--lsp` takes no input file: the editor sends the documents\n");
            return 2;
        }
        return null;
    }
    if (cli.emit_verilog) if (cli.check or cli.emit_so or cli.exe_flag != null) {
        try err.writeAll("error: `--emit-verilog` builds no device: it takes neither --check, --emit-so, --emit-exe nor --run\n");
        return 2;
    };
    if (cli.emit_rtlil) {
        if (cli.check or cli.emit_so or cli.emit_zig_typed or cli.exe_flag != null or cli.emit_verilog) {
            try err.writeAll("error: `--emit-rtlil` builds no device: it takes neither --check, --emit-zig, --emit-so, --emit-verilog, --emit-exe nor --run\n");
            return 2;
        }
        cli.emit_zig = false; // `-o` names the RTLIL file
    }
    if (cli.emit_osdi) {
        if (cli.dyn_path != null or cli.emit_zig_typed or cli.exe_flag != null) {
            try err.writeAll("error: `--emit-osdi` builds under this vera's own OSDI dyn: it takes neither --dyn, --emit-zig, --emit-exe nor --run\n");
            return 2;
        }
        cli.emit_zig = false; // `-o` names the .osdi
    }
    // A testbench is its own artifact: beside it a library or a device text
    // was silently not built. `-o` names the executable, so only a typed
    // `--emit-zig` conflicts.
    if (cli.exe_flag) |f| if (cli.emit_so or cli.emit_zig_typed) {
        try err.print("error: `{s}` and `{s}` conflict: one run builds one artifact\n", .{ f, if (cli.emit_so) "--emit-so" else "--emit-zig" });
        return 2;
    };
    if (cli.paths.items.len == 0) {
        try err.writeAll(usage_text);
        return 2;
    }
    assert(!(cli.emit_rtlil and cli.emit_zig));
    assert(!(cli.emit_osdi and cli.emit_zig));
    return null;
}

/// Prints `error: <flag> needs <what>` on `w`; returns exit status 2.
pub fn missing(w: *Io.Writer, flag: []const u8, what: []const u8) Io.Writer.Error!u8 {
    assert(flag.len != 0);
    assert(what.len != 0);
    try w.print("error: {s} needs {s}\n", .{ flag, what });
    return 2;
}

/// The resolved command line as one `Compilation.Config` over `paths`
/// (`cli.paths` for the command line, the open document for the LSP); its
/// slices borrow `cli`'s and `paths`. `thread_limit` is used unless
/// `--jobs=` was typed. Asserts that `resolve` returned null.
pub fn config(cli: *const Options, paths: []const []const u8, thread_limit: u32) Config {
    assert(paths.len != 0);
    assert(thread_limit >= 1);
    const target: Config.Target = if (cli.elab) .elab else if (cli.emit_rtlil) .rtlil else if (cli.emit_verilog) .verilog else if (cli.exe_flag != null)
        (if (cli.run_exe) .run else .exe)
    else if (cli.emit_osdi) .osdi else if (cli.emit_so) .so else if (cli.emit_zig) .zig else if (cli.check) .check else .lint;
    return .{
        .paths = paths,
        .include_dirs = cli.include_dirs.items,
        .defines = cli.defines.items,
        .std_defs = cli.std_defs,
        .language = cli.language,
        .sim = cli.sim,
        .levels = cli.levels,
        .overrides = cli.overrides.items,
        .discipline_resolution = cli.discipline_resolution,
        .display = cli.display,
        .unknown_bound = cli.unknown_bound,
        .spice_path = cli.spice_path,
        .protect_keys = cli.protect_keys,
        .libmaps = cli.libmaps.items,
        .search = cli.search.items,
        .event_budget = cli.event_budget,
        .negative_timing = cli.negative_timing,
        .target = target,
        .check = cli.check,
        .zig = cli.emit_zig,
        .expect_module = cli.expect_module,
        .out_path = cli.out_path,
        .work_dir = cli.work_dir,
        .contract = cli.contract_path,
        .dyn = cli.dyn_path,
        .zig_exe = cli.zig_exe,
        .optimize = cli.optimize orelse if (cli.exe_flag != null) .debug else .fast,
        .debug_info = cli.debug_info,
        .jac_f32 = cli.jac_f32,
        .jac_f32_host = cli.jac_f32_host,
        .thread_limit = cli.jobs orelse thread_limit,
    };
}

// ---- private ----

/// Applies one `switches` row; reads its value from `args` when it takes one.
fn takeSwitch(cli: *Cli, gpa: Allocator, s: Switch, arg: []const u8, args: anytype, out: *Io.Writer, err: *Io.Writer) ParseError!?u8 {
    assert(arg.len != 0);
    assert(switches.get(arg) == s);
    switch (s) {
        .help => {
            try out.writeAll(usage_text);
            return 0;
        },
        .version => {
            try out.writeAll("vera " ++ vera_version ++ "\n");
            return 0;
        },
        .explain => {
            const name = args.next() orelse return try missing(err, "--explain", "a code, e.g. --explain W0650");
            const code = std.meta.stringToEnum(diag.Code, name) orelse {
                try err.print("error: unknown diagnostic code `{s}`\n", .{name});
                return 2;
            };
            try diag.explain(code, out, if (cli.color == .never) .off else .on);
            return 0;
        },
        .lint => cli.lint_flag = true,
        .elab => cli.elab = true,
        .lsp => cli.lsp = true,
        .emit_zig => {
            cli.emit_zig = true;
            cli.emit_zig_typed = true;
            cli.codegen_flag = arg;
        },
        .emit_verilog => {
            cli.emit_verilog = true;
            cli.codegen_flag = arg;
        },
        .emit_rtlil => {
            cli.emit_rtlil = true;
            cli.codegen_flag = arg;
        },
        .digital_pins => cli.digital_pins = args.next() orelse return try missing(err, "--digital-pins", "a list of ports or a file"),
        .power_pins => cli.power_pins = true,
        .check => {
            cli.check = true;
            cli.codegen_flag = arg;
        },
        .emit_so => {
            cli.emit_so = true;
            cli.codegen_flag = arg;
        },
        .emit_osdi => {
            cli.emit_so = true;
            cli.emit_osdi = true;
            cli.codegen_flag = arg;
        },
        .emit_exe, .run => {
            // The testbench IS the display output, so asking for one and then
            // dropping the prints would build an artifact with nothing to say.
            cli.run_exe = cli.run_exe or s == .run;
            cli.display = .emit;
            cli.codegen_flag = arg;
            cli.exe_flag = arg;
        },
        .validate_contract => cli.validate_contract = true,
        .jac_f32 => cli.jac_f32 = true,
        .jac_f32_host => cli.jac_f32_host = true,
        .contract => cli.contract_path = try pathValue(args, err, arg, "a path") orelse return 2,
        .param => {
            const kv = args.next() orelse return try missing(err, "--param", "NAME=VALUE");
            const eq = std.mem.findScalar(u8, kv, '=') orelse return try missing(err, "--param", "NAME=VALUE");
            // `=1`: no name, which no design declares.
            if (eq == 0) return try missing(err, "--param", "NAME=VALUE");
            // A string parameter takes the text; a numeric one refuses a NaN
            // once its type is known (the analysis, the digital elaboration).
            const text = kv[eq + 1 ..];
            const value = std.fmt.parseFloat(f64, text) catch std.math.nan(f64);
            try cli.overrides.append(gpa, .{ .name = kv[0..eq], .value = value, .text = text });
        },
        .dyn => cli.dyn_path = try pathValue(args, err, arg, "a path") orelse return 2,
        .work_dir => cli.work_dir = try pathValue(args, err, arg, "a directory") orelse return 2,
        .debug_info => cli.debug_info = true,
        .zig => cli.zig_exe = try pathValue(args, err, arg, "a path") orelse return 2,
        .negative_timing => cli.negative_timing = true,
        .two_state => {
            cli.logic = .two;
            cli.logic_flag = arg;
        },
        .out => {
            cli.out_path = try pathValue(args, err, arg, "a path") orelse return 2;
            cli.emit_zig = true;
            cli.codegen_flag = arg;
        },
        .spice => cli.spice_path = try pathValue(args, err, arg, "a path") orelse return 2,
        .libmap => try cli.libmaps.append(gpa, try pathValue(args, err, arg, "a library map file") orelse return 2),
        .protect_keys => cli.protect_keys = try pathValue(args, err, arg, "a key file") orelse return 2,
        .library => try cli.search.append(gpa, try pathValue(args, err, arg, "a library name") orelse return 2),
        .include => try cli.include_dirs.append(gpa, try pathValue(args, err, arg, "a directory") orelse return 2),
        .no_std_defs => cli.std_defs = false,
        .json => cli.json = true,
        .text => cli.json = false,
        .color_always => cli.color = .always,
        .color_never => cli.color = .never,
        .color_auto => cli.color = .auto,
    }
    return null;
}

/// The `valued` row whose `--name=` begins `arg`, if any. `arg` is user text
/// and may be empty (`vera ""`), which matches no row.
fn valuedKey(arg: []const u8) ?Valued {
    const eq = std.mem.findScalar(u8, arg, '=') orelse return null;
    return valued.get(arg[0 .. eq + 1]);
}

/// Applies one `valued` row to the `value` after its `=`.
fn takeValued(cli: *Cli, v: Valued, arg: []const u8, value: []const u8, err: *Io.Writer) Io.Writer.Error!?u8 {
    assert(valuedKey(arg) == v);
    assert(std.mem.endsWith(u8, arg, value));
    switch (v) {
        .vdd => {
            cli.vdd = std.fmt.parseFloat(f64, value) catch 0;
            if (!(cli.vdd > 0) or !std.math.isFinite(cli.vdd)) {
                try err.print("error: `{s}`: not a positive number\n", .{arg});
                return 2;
            }
        },
        .display => {
            const d = std.meta.stringToEnum(Display, value) orelse {
                try err.print("error: unknown option `{s}`\n", .{arg});
                return 2;
            };
            cli.display = d;
            cli.display_flag = d;
        },
        .optimize => cli.optimize = optimize_names.get(value) orelse {
            try err.print("error: `{s}`: not Debug|ReleaseSafe|ReleaseFast|ReleaseSmall\n", .{arg});
            return 2;
        },
        .state => {
            cli.logic = if (std.mem.eql(u8, value, "auto")) .auto else if (std.mem.eql(u8, value, "2")) .two else if (std.mem.eql(u8, value, "4")) .four else {
                try err.print("error: `{s}`: not auto|2|4\n", .{arg});
                return 2;
            };
            cli.logic_flag = arg;
        },
        .schedule => cli.schedule = std.meta.stringToEnum(Options.Schedule, value) orelse {
            try err.print("error: `{s}`: not static|fifo\n", .{arg});
            return 2;
        },
        .event_budget, .jobs => {
            const n = std.fmt.parseInt(u64, value, 10) catch 0;
            if (n == 0 or (v == .jobs and n > std.math.maxInt(u32))) {
                try err.print("error: `{s}`: not a positive integer\n", .{arg});
                return 2;
            }
            if (v == .jobs) cli.jobs = @intCast(n) else cli.event_budget = n;
        },
        .zig_backend => cli.zig_backend = if (std.mem.eql(u8, value, "auto")) null else if (std.mem.eql(u8, value, "llvm")) .llvm else if (std.mem.eql(u8, value, "native")) .self_hosted else {
            try err.print("error: `{s}`: not auto|llvm|native\n", .{arg});
            return 2;
        },
        .expect_module => cli.expect_module = value,
        .std => {
            const set = vams.Ast.KeywordSet.fromSpecifier(value) orelse {
                try err.print("error: `{s}`: not a `begin_keywords version specifier\n", .{arg});
                return 2;
            };
            // VerA compiles Verilog-AMS as VAMS-2023 only. "VAMS-2.3" stays a
            // `begin_keywords specifier in source, which §10.6 requires.
            if (set == .vams_2_3) {
                try err.print("error: `{s}`: Verilog-AMS is compiled as VAMS-2023; use `begin_keywords \"VAMS-2.3\" in the source for its keyword set\n", .{arg});
                return 2;
            }
            cli.language = set;
            cli.std_flag = arg;
        },
        .sim => {
            cli.sim = simFromFlag(value) orelse {
                try err.print("error: `{s}`: not verilogAMS|verilogA|verilog\n", .{arg});
                return 2;
            };
            cli.sim_flag = arg;
        },
        .discipline_resolution => cli.discipline_resolution = std.meta.stringToEnum(@FieldType(Config, "discipline_resolution"), value) orelse {
            try err.print("error: `{s}`: not basic|detail\n", .{arg});
            return 2;
        },
        .unknown_bound => {
            const b = std.fmt.parseFloat(f64, value) catch std.math.nan(f64);
            if (std.math.isNan(b)) {
                try err.print("error: `{s}` is not a number\n", .{arg});
                return 2;
            }
            cli.unknown_bound = b;
        },
    }
    return null;
}

/// The value after the path-valued `flag`, or null once `missing` printed
/// `error: <flag> needs <what>`: the line ended there, or the value is empty,
/// which names no file. Every path flag reads its value here, so an empty
/// one is refused before anything opens or spawns it (#47).
fn pathValue(args: anytype, err: *Io.Writer, flag: []const u8, what: []const u8) Io.Writer.Error!?[]const u8 {
    assert(switches.get(flag) != null);
    assert(what.len != 0);
    const v = args.next() orelse "";
    if (v.len == 0) {
        _ = try missing(err, flag, what);
        return null;
    }
    if (try nameTooLong(err, flag, v)) return null;
    return v;
}

/// Refuses (on `err`, true) a path with a name longer than any filesystem
/// holds (`Io.Dir.max_name_bytes`). It is user text: Windows reports such a
/// name as OBJECT_NAME_INVALID, which std treats as a programmer bug and
/// panics on, so it never reaches a file call.
fn nameTooLong(err: *Io.Writer, what: []const u8, path: []const u8) Io.Writer.Error!bool {
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |name| if (name.len > Io.Dir.max_name_bytes) {
        try err.print("error: {s}: a name in `{s}...` is {d} bytes, longer than a file name can be ({d})\n", .{ what, path[0..@min(path.len, 40)], name.len, Io.Dir.max_name_bytes });
        return true;
    };
    return false;
}

/// A simple identifier (IEEE 1364-2005 §3.7.1), what `define names.
fn isMacroName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '$')) return false;
    return true;
}

/// `--sim=`'s value: `verilogAMS`, `verilogA` or `verilog`.
fn simFromFlag(text: []const u8) ?Config.Sim {
    const map = std.StaticStringMap(Config.Sim).initComptime(.{ .{ "verilogAMS", .verilog_ams }, .{ "verilogA", .verilog_a }, .{ "verilog", .verilog } });
    return map.get(text);
}

test "the old driver's command lines settle to their targets" {
    // Oracle: src/cli/args.zig's `resolve` and the old compile spine's
    // target order (`--check` alone checks; `-o` implies `--emit-zig`).
    const gpa = std.testing.allocator;
    const Case = struct { argv: []const []const u8, target: Config.Target, check: bool = false };
    for ([_]Case{
        .{ .argv = &.{"a.va"}, .target = .lint },
        .{ .argv = &.{ "--check", "a.va" }, .target = .check, .check = true },
        .{ .argv = &.{ "--emit-zig", "--check", "-o", "x.zig", "a.va" }, .target = .zig, .check = true },
        .{ .argv = &.{ "--run", "a.v" }, .target = .run },
        .{ .argv = &.{ "--elab", "a.v" }, .target = .elab },
        .{ .argv = &.{ "--emit-so", "a.va" }, .target = .so },
    }) |c| {
        var cli: Options = .{};
        defer cli.deinit(gpa);
        var it: TestArgv = .{ .items = c.argv };
        var discard: Io.Writer.Discarding = .init(&.{});
        try std.testing.expectEqual(@as(?u8, null), try parse(&cli, gpa, &it, &discard.writer, &discard.writer));
        try std.testing.expectEqual(@as(?u8, null), try resolve(&cli, &discard.writer));
        const cfg = config(&cli, cli.paths.items, 4);
        try std.testing.expectEqual(c.target, cfg.target);
        try std.testing.expectEqual(c.check, cfg.check);
        try std.testing.expectEqual(@as(u32, 4), cfg.thread_limit);
    }
}

test "a malformed flag is the old driver's refusal, byte for byte" {
    // Oracle: src/cli/args.zig's message (frozen, user-visible).
    const gpa = std.testing.allocator;
    var cli: Options = .{};
    defer cli.deinit(gpa);
    var it: TestArgv = .{ .items = &.{ "--jobs=0", "a.va" } };
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    try std.testing.expectEqual(@as(?u8, 2), try parse(&cli, gpa, &it, &out.writer, &err.writer));
    try std.testing.expectEqualStrings("error: `--jobs=0`: not a positive integer\n", err.written());
}
