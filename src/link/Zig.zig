//! What a `zig` child is told: a `Command` in, its command line out (`argv`,
//! the one builder every child goes through), and the root files a library
//! or engine build compiles beside a device (`shim.zig`, `shim_<piece>.zig`,
//! the engine root). Each `--dep` applies to the next `-M`, and the first
//! `-M` is the root module, as in `std.Build.Step.Compile.getZigArgs`.
//! Every shim byte reaches a `zig` child and is frozen: the goldens hold the
//! device shim's text (`.so/shim.zig`). Cites `contract.DevicePart` (the
//! split's pieces) and no LRM clause: the flags are Zig's.
//!
//! Contents:
//! - `pub const Backend = enum { self_hosted, llvm }`, `Backend.auto`, `Backend.forHost`, `Backend.flags`
//! - `pub const Module = struct { name, root, deps }`
//! - `pub const Split = enum { by_size, whole, parts }`
//! - `pub const Part = contract.DevicePart`
//! - `pub const Engine = enum { none, prebuilt }`
//! - `pub const Setup = enum { whole, chunked }`
//! - `pub const Piece = union(enum) { part: Part, chunk: u8 }`, `Piece.format`
//! - `pub const Command = struct`
//! - `pub const link_libc: []const []const u8`
//! - `pub const setup_chunks_max: u32`
//! - `pub const engine_root: []const u8`
//! - `pub fn argv(arena: Allocator, c: Command) Allocator.Error![]const []const u8`
//! - `pub fn strip(optimize: std.lang.Optimize, debug_info: bool) bool`
//! - `pub fn deviceShim(gpa: Allocator, name: []const u8, engine: Engine) Allocator.Error![]u8`
//! - `pub fn pieceShim(arena: Allocator, name: []const u8, p: Piece, engine: Engine, setup: Setup) Allocator.Error![]u8`
//! - `pub fn shimName(arena: Allocator, p: Piece) Allocator.Error![]const u8`

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
/// The host's split of a device into objects (`contract.DevicePart`), so the
/// tags the shims write are the ones its `exportDevicePart` takes.
pub const Part = @import("contract").DevicePart;

/// Which Zig code generator builds an artifact, independent of the optimize
/// mode. `.self_hosted` does not optimise and has no nvptx/amdgcn target.
pub const Backend = enum {
    self_hosted,
    llvm,

    /// Returns `.self_hosted` for Debug on x86_64, where build time dominates,
    /// and `.llvm` otherwise.
    pub fn auto(optimize: std.lang.Optimize, arch: std.Target.Cpu.Arch) Backend {
        return if (optimize == .debug and arch == .x86_64) .self_hosted else .llvm;
    }

    /// Returns the backend a build on this host actually uses: `.llvm` on
    /// Windows and off x86_64, whatever was asked. The self-hosted COFF linker
    /// writes a DLL at a fixed base with its relocations stripped, so a second
    /// one cannot load in the same process; and off x86_64 the self-hosted
    /// code generator panics "TODO" on a device (aarch64-macos, seen in CI).
    pub fn forHost(b: Backend) Backend {
        return if (builtin.target.os.tag == .windows or builtin.target.cpu.arch != .x86_64) .llvm else b; // os: picks a backend; every target builds
    }

    /// Returns the `zig` flags that select `forHost(b)`.
    pub fn flags(b: Backend) []const []const u8 {
        return switch (b.forHost()) {
            .self_hosted => &.{ "-fno-llvm", "-fno-lld" },
            .llvm => &.{"-fllvm"},
        };
    }
};

/// One module on the compiler command line. Strings are borrowed and must
/// outlive the build.
pub const Module = struct {
    /// The `@import` string.
    name: []const u8,
    /// The module's root source file, relative to the process cwd or
    /// absolute. Every file the module can import sits in this file's
    /// directory or below it (Zig refuses an import outside the module path).
    root: []const u8,
    /// Names of other modules on the same command line that this one imports.
    deps: []const []const u8 = &.{},
};

/// How a library build is cut into compiler processes.
pub const Split = enum {
    /// One object per piece for an LLVM build of at least
    /// `link.split_min_bytes` of device text, else whole.
    by_size,
    /// One `zig build-lib` child.
    whole,
    /// One `zig build-obj` child per piece, then a link.
    parts,
};

/// Whether the library links `sim`'s prebuilt engine object: `.prebuilt`
/// makes the shim declare `vera_prebuilt_engine`, which `sim`'s runtime
/// reads (`rt.prebuilt`).
pub const Engine = enum { none, prebuilt };

/// Whether the device's `setup` was emitted as chunks (`Output.setup_chunks`
/// above 0): a chunked `setup` makes every part's shim declare
/// `vera_setup_split`.
pub const Setup = enum { whole, chunked };

/// One object of a split build: a `Part`, or chunk `k` of a chunked `setup`.
/// Its text, `setup`/`state`/`eval` or `setup<k>`, names the object and its
/// root file.
pub const Piece = union(enum) {
    part: Part,
    chunk: u8,

    /// Writes the piece's name: the part's tag, or `setup<k>`.
    pub fn format(p: Piece, w: *Io.Writer) Io.Writer.Error!void {
        switch (p) {
            .part => |which| try w.writeAll(@tagName(which)),
            .chunk => |k| try w.print("setup{d}", .{k}),
        }
    }
};

/// One `zig` child's command line, in the order `argv` writes it: compiler,
/// `verb`, `--listen=-`, `kind`, `-O`, `--name`, `--cache-dir`, libc, `-target`, `flags`, then the modules. Strings are
/// borrowed.
pub const Command = struct {
    /// Looked up on `PATH` when bare.
    zig_exe: []const u8,
    /// `build-lib`, `build-obj` or `build-exe`.
    verb: []const u8,
    /// Output-kind flags: `-dynamic`, `-fPIC`, `-fno-entry`, `-fno-emit-bin`.
    /// (`--listen` refuses `-femit-bin`: every output lands in the cache.)
    kind: []const []const u8 = &.{},
    optimize: ?std.lang.Optimize = null,
    /// `--name`: the artifact's name in the compiler's cache.
    name: ?[]const u8 = null,
    cache_dir: []const u8,
    /// `link_libc`: the artifact is loaded with `dlopen`.
    libc: bool = false,
    target: ?[]const u8 = null,
    /// Code generation flags, then input objects.
    flags: []const []const u8 = &.{},
    /// The root module first.
    modules: []const Module = &.{},
};

/// `-lc` for every library VerA builds on a dynamic-linking host: a host
/// loads it with `dlopen`, and a thread-local in it (Zig 0.18's
/// `std.debug.print` reads `Io.Threaded.Thread.current`) must then use the
/// libc dynamic TLS model (`__tls_get_addr`). Without libc, Zig 0.18.0-dev's
/// shared library reads it at a static offset and faults (a `--emit-so`
/// device that prints, VPI, OSDI). Windows DLLs do not need it.
pub const link_libc: []const []const u8 = if (builtin.target.os.tag == .windows) &.{} else &.{"-lc"}; // os: picks a flag for the host build; every target builds, Windows with none

/// Most chunks a `setup` is emitted as: codegen's own cap (`setup_chunk.zig`
/// splits into at most 64), so a chunk index fits `Piece.chunk`.
pub const setup_chunks_max: u32 = 64;

/// The root of the engine object: `sim`'s runtime, with no root options (a
/// device's shim declares none).
pub const engine_root =
    \\// GENERATED BY VerA — DO NOT EDIT.
    \\comptime {
    \\    @import("sim").rt.engine.exportAll();
    \\}
    \\
;

/// The shim's root declarations: the `dyn` host's opt-in to the contract's
/// conformance checks, forwarded because the shim, not `dyn`, is the root
/// `contract.validating` reads.
const validate_decl =
    "pub const vera_validate_contract = @hasDecl(@import(\"dyn\"), \"vera_validate_contract\") and " ++
    "@import(\"dyn\").vera_validate_contract;\n";

/// With `Engine.prebuilt`: makes `sim`'s runtime call the linked engine
/// object.
const engine_decl = "pub const vera_prebuilt_engine = {};\n";

/// With `Setup.chunked`: a split build's parts call `setup`'s chunks through
/// the chunk objects exactly when those export them, which is when the host
/// names the value scalar it passes `setup` (`contract.DevicePart`).
const setup_split_decl = "pub const vera_setup_split = @hasDecl(@import(\"dyn\"), \"SetupValue\");\n";

comptime {
    // The shims splice the declarations in front of `comptime {`: each must
    // be whole lines.
    assert(std.mem.endsWith(u8, validate_decl, "\n"));
    assert(std.mem.endsWith(u8, engine_decl, "\n"));
    assert(std.mem.endsWith(u8, setup_split_decl, "\n"));
    assert(setup_chunks_max <= std.math.maxInt(@FieldType(Piece, "chunk")) + 1);
}

/// Returns `c` as a command line, allocated in `arena`. Asserts that the
/// compiler, the verb and the cache directory are named, and that every
/// module is.
pub fn argv(arena: Allocator, c: Command) Allocator.Error![]const []const u8 {
    assert(c.zig_exe.len > 0);
    assert(c.cache_dir.len > 0);
    var a: std.ArrayList([]const u8) = .empty;
    try a.appendSlice(arena, &.{ c.zig_exe, c.verb, "--listen=-" });
    try a.appendSlice(arena, c.kind);
    if (c.optimize) |o| try a.append(arena, try arena.print("-O{t}", .{o}));
    if (c.name) |n| try a.appendSlice(arena, &.{ "--name", n });
    try a.appendSlice(arena, &.{ "--cache-dir", c.cache_dir });
    if (c.libc) try a.appendSlice(arena, link_libc);
    if (c.target) |t| try a.appendSlice(arena, &.{ "-target", t });
    try a.appendSlice(arena, c.flags);
    for (c.modules) |m| {
        assert(m.name.len > 0);
        assert(m.root.len > 0);
        for (m.deps) |d| try a.appendSlice(arena, &.{ "--dep", d });
        try a.append(arena, try arena.print("-M{s}={s}", .{ m.name, m.root }));
    }
    assert(a.items.len >= 5 + c.flags.len + c.modules.len);
    return a.items;
}

/// Returns whether a native build passes `-fstrip`: optimized without safety
/// checks, unless the caller asked for debug information.
pub fn strip(optimize: std.lang.Optimize, debug_info: bool) bool {
    return !debug_info and (optimize == .fast or optimize == .small);
}

/// Returns the dyn-ABI export shim, which re-exports the device under the
/// host's C ABI. It depends only on `name` and `engine`, so a rebuild never
/// dirties it. `name` is written as a Zig string literal, whatever bytes it
/// holds. Caller owns the text and frees it with `gpa`.
pub fn deviceShim(gpa: Allocator, name: []const u8, engine: Engine) Allocator.Error![]u8 {
    const text = try gpa.print(
        \\// GENERATED BY VerA — DO NOT EDIT.
        \\{s}{s}comptime {{
        \\    @import("dyn").exportDevice(@import("device"), "{f}");
        \\}}
        \\
    , .{ validate_decl, engineDecl(engine), std.zig.fmtString(name) });
    assert(std.mem.endsWith(u8, text, "}\n"));
    return text;
}

/// Returns the root file of one split piece: for a part, the host's
/// `exportDevicePart` for it (a host without one gets `exportDevice` in the
/// `setup` object and nothing in the others); for a chunk, the chunk exported
/// for the host's value scalar, or nothing for a host that names none.
/// Allocated in `arena`. Asserts that a chunk index is below
/// `setup_chunks_max` and that a chunk comes from a chunked `setup`.
pub fn pieceShim(arena: Allocator, name: []const u8, p: Piece, engine: Engine, setup: Setup) Allocator.Error![]u8 {
    const text = switch (p) {
        .part => |which| try partShim(arena, name, which, engine, setup),
        .chunk => |k| text: {
            assert(k < setup_chunks_max);
            assert(setup == .chunked);
            break :text try chunkShim(arena, k, engine);
        },
    };
    assert(std.mem.startsWith(u8, text, "// GENERATED BY VerA"));
    return text;
}

/// Returns the `shim_<piece>.zig` file name of a split piece, allocated in
/// `arena`.
pub fn shimName(arena: Allocator, p: Piece) Allocator.Error![]const u8 {
    const name = try arena.print("shim_{f}.zig", .{p});
    assert(std.mem.endsWith(u8, name, ".zig"));
    return name;
}

// ---- private ----

fn engineDecl(engine: Engine) []const u8 {
    return switch (engine) {
        .none => "",
        .prebuilt => engine_decl,
    };
}

fn setupDecl(setup: Setup) []const u8 {
    return switch (setup) {
        .whole => "",
        .chunked => setup_split_decl,
    };
}

fn partShim(arena: Allocator, name: []const u8, which: Part, engine: Engine, setup: Setup) Allocator.Error![]u8 {
    const head = try std.mem.concat(arena, u8, &.{ validate_decl, engineDecl(engine), setupDecl(setup) });
    if (which == .setup) return arena.print(
        \\// GENERATED BY VerA — DO NOT EDIT.
        \\{1s}comptime {{
        \\    const dyn = @import("dyn");
        \\    if (@hasDecl(dyn, "exportDevicePart"))
        \\        dyn.exportDevicePart(@import("device"), "{0f}", .setup)
        \\    else
        \\        dyn.exportDevice(@import("device"), "{0f}");
        \\}}
        \\
    , .{ std.zig.fmtString(name), head });
    return arena.print(
        \\// GENERATED BY VerA — DO NOT EDIT.
        \\{s}comptime {{
        \\    const dyn = @import("dyn");
        \\    if (@hasDecl(dyn, "exportDevicePart")) dyn.exportDevicePart(@import("device"), "{f}", .{t});
        \\}}
        \\
    , .{ head, std.zig.fmtString(name), which });
}

fn chunkShim(arena: Allocator, k: u8, engine: Engine) Allocator.Error![]u8 {
    return arena.print(
        \\// GENERATED BY VerA — DO NOT EDIT.
        \\{s}{s}{s}comptime {{
        \\    const dyn = @import("dyn");
        \\    const D = @import("device");
        \\    if (@hasDecl(dyn, "SetupValue")) D.setup_chunks.exportChunk(dyn.SetupValue(D), {d});
        \\}}
        \\
    , .{ validate_decl, engineDecl(engine), setup_split_decl, k });
}

/// Fails the test unless `text` parses as Zig with no error.
fn expectParses(text: []const u8) !void {
    const gpa = std.testing.allocator;
    const z = try gpa.dupeSentinel(u8, text, 0);
    defer gpa.free(z);
    var tree = try std.zig.Ast.parse(gpa, z, .{});
    defer tree.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
}

// The oracle for `argv` is a command line written out by hand from `zig
// build-lib --help` and `std.Build.Step.Compile.getZigArgs`'s `--dep` rule;
// for every shim, a reviewed whole file written out by hand plus Zig's own
// parser. The library tests run them through a real `zig`.

test argv {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const lc: [link_libc.len][]const u8 = link_libc[0..link_libc.len].*;
    // Every field, in order; each `--dep` applies to the `-M` after it.
    const want = [_][]const u8{
        "zigx",   "build-lib", "--listen=-",  "-dynamic", "-fno-entry", "-Ofast",
        "--name", "dev",       "--cache-dir", "c",
    } ++ lc ++ [_][]const u8{
        "-target", "x86_64-linux-gnu", "-fstrip", "a.o", "--dep", "dev", "-Mroot=r.zig", "-Mdev=d.zig",
    };
    const got = try argv(arena.allocator(), .{
        .zig_exe = "zigx",
        .verb = "build-lib",
        .kind = &.{ "-dynamic", "-fno-entry" },
        .optimize = .fast,
        .name = "dev",
        .cache_dir = "c",
        .libc = true,
        .target = "x86_64-linux-gnu",
        .flags = &.{ "-fstrip", "a.o" },
        .modules = &.{ .{ .name = "root", .root = "r.zig", .deps = &.{"dev"} }, .{ .name = "dev", .root = "d.zig" } },
    });
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
    // The fewest: compiler, verb, server flag, cache.
    const bare = try argv(arena.allocator(), .{ .zig_exe = "zig", .verb = "build-obj", .cache_dir = "c" });
    try std.testing.expectEqual(@as(usize, 5), bare.len);
}

test strip {
    // Only fast and small drop safety, and only they strip; debug_info vetoes.
    for (std.enums.values(std.lang.Optimize)) |m| {
        try std.testing.expect(!strip(m, true));
        try std.testing.expectEqual(m == .fast or m == .small, strip(m, false));
    }
}

test shimName {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("shim_setup.zig", try shimName(arena.allocator(), .{ .part = .setup }));
    try std.testing.expectEqualStrings("shim_eval.zig", try shimName(arena.allocator(), .{ .part = .eval }));
    try std.testing.expectEqualStrings("shim_setup12.zig", try shimName(arena.allocator(), .{ .chunk = 12 }));
}

test deviceShim {
    const gpa = std.testing.allocator;
    const plain = try deviceShim(gpa, "dev", .none);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings(
        \\// GENERATED BY VerA — DO NOT EDIT.
        \\pub const vera_validate_contract = @hasDecl(@import("dyn"), "vera_validate_contract") and @import("dyn").vera_validate_contract;
        \\comptime {
        \\    @import("dyn").exportDevice(@import("device"), "dev");
        \\}
        \\
    , plain);

    // `engine` adds exactly the prebuilt-engine declaration.
    const linked = try deviceShim(gpa, "dev", .prebuilt);
    defer gpa.free(linked);
    try std.testing.expectEqualStrings(
        \\// GENERATED BY VerA — DO NOT EDIT.
        \\pub const vera_validate_contract = @hasDecl(@import("dyn"), "vera_validate_contract") and @import("dyn").vera_validate_contract;
        \\pub const vera_prebuilt_engine = {};
        \\comptime {
        \\    @import("dyn").exportDevice(@import("device"), "dev");
        \\}
        \\
    , linked);
}

test partShim {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `setup` falls back to the whole device for a host without parts.
    try std.testing.expectEqualStrings(
        \\// GENERATED BY VerA — DO NOT EDIT.
        \\pub const vera_validate_contract = @hasDecl(@import("dyn"), "vera_validate_contract") and @import("dyn").vera_validate_contract;
        \\comptime {
        \\    const dyn = @import("dyn");
        \\    if (@hasDecl(dyn, "exportDevicePart"))
        \\        dyn.exportDevicePart(@import("device"), "dev", .setup)
        \\    else
        \\        dyn.exportDevice(@import("device"), "dev");
        \\}
        \\
    , try pieceShim(a, "dev", .{ .part = .setup }, .none, .whole));

    // Any other part exports nothing for such a host; `engine` and a chunked
    // `setup` each add their declaration, in that order after the validate line.
    try std.testing.expectEqualStrings(
        \\// GENERATED BY VerA — DO NOT EDIT.
        \\pub const vera_validate_contract = @hasDecl(@import("dyn"), "vera_validate_contract") and @import("dyn").vera_validate_contract;
        \\pub const vera_prebuilt_engine = {};
        \\pub const vera_setup_split = @hasDecl(@import("dyn"), "SetupValue");
        \\comptime {
        \\    const dyn = @import("dyn");
        \\    if (@hasDecl(dyn, "exportDevicePart")) dyn.exportDevicePart(@import("device"), "dev", .eval);
        \\}
        \\
    , try pieceShim(a, "dev", .{ .part = .eval }, .prebuilt, .chunked));

    const state_tail =
        \\    if (@hasDecl(dyn, "exportDevicePart")) dyn.exportDevicePart(@import("device"), "dev", .state);
        \\}
        \\
    ;
    try std.testing.expect(std.mem.endsWith(u8, try pieceShim(a, "dev", .{ .part = .state }, .none, .whole), state_tail));
}

test chunkShim {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        \\// GENERATED BY VerA — DO NOT EDIT.
        \\pub const vera_validate_contract = @hasDecl(@import("dyn"), "vera_validate_contract") and @import("dyn").vera_validate_contract;
        \\pub const vera_setup_split = @hasDecl(@import("dyn"), "SetupValue");
        \\comptime {
        \\    const dyn = @import("dyn");
        \\    const D = @import("device");
        \\    if (@hasDecl(dyn, "SetupValue")) D.setup_chunks.exportChunk(dyn.SetupValue(D), 7);
        \\}
        \\
    , try pieceShim(arena.allocator(), "dev", .{ .chunk = 7 }, .none, .chunked));
}

test "every shim is Zig source whatever bytes the device name holds" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try expectParses(engine_root);
    // IEEE 1364-2005 §3.7.1: an escaped identifier holds any printable ASCII
    // byte, `"` and `\` included, and a digital module's name reaches
    // `File.name` as written (src/cli/digital.zig).
    for ([_][]const u8{ "dev", "a$b", "a\"b", "back\\slash", "x\"); @compileError(\"" }) |name| {
        const d = try deviceShim(std.testing.allocator, name, .none);
        defer std.testing.allocator.free(d);
        try expectParses(d);
        for (std.enums.values(Part)) |p| try expectParses(try pieceShim(a, name, .{ .part = p }, .prebuilt, .chunked));
    }
    try expectParses(try pieceShim(a, "dev", .{ .chunk = 0 }, .prebuilt, .chunked));

    // The name round-trips as a string literal: Zig's own escapes, written
    // out by hand.
    const quoted = try deviceShim(std.testing.allocator, "a\"b", .none);
    defer std.testing.allocator.free(quoted);
    try std.testing.expect(std.mem.find(u8, quoted, "\"a\\\"b\"") != null);
}
