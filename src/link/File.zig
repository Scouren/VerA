//! One artifact's build (Zig's `link.File`): what it is, where it is
//! written and how `zig` compiles it, and the library flush in `Task` order:
//! write the device tree, one `build_obj` per device part when split, then
//! `link`, every child through the caller's `Queue`; a finished library is
//! keyed in `std.Build.Cache` (`File.cache_dir`) by every input that decides
//! its bytes (Zig's `Compilation.updateCObject` pattern). Also the prebuilt
//! engine object (`buildEngine`, Zig's `Compilation.buildRt`). The host owns
//! dlopen, dlclose and state reset; a fresh path per generation gives it a
//! fresh inode. Cites §8.3's device-side ABI and no other clause.
//!
//! Contents:
//! - fields `kind`, `work_dir`, `name`, `optimize`, `modules`, `backend`, `zig_exe`, `debug_info`, `strip`, `target`, `split`, `engine`, `cache_dir`, `out_path`
//! - `pub const Kind = enum { so, osdi, exe, check }`
//! - `pub const Artifact = union(enum) { ok: []u8, failed: std.zig.ErrorBundle }`, `Artifact.deinit`
//! - `pub const Error`
//! - `pub const Task = union(enum) { write_tree, build_obj: Piece, link }`
//! - `pub const split_min_bytes: usize`
//! - `pub fn flush(f: File, gpa: Allocator, io: Io, q: *Queue, device: Output, generation: u32) Error!Artifact`
//! - `pub fn plan(arena: Allocator, split: bool, chunks: u32) Allocator.Error![]const Task`
//! - `pub fn buildEngine(f: File, gpa: Allocator, io: Io, q: *Queue, cache_dir: []const u8) Error!Artifact`
//! - `pub fn backendOf(f: File) Backend`
//! - `pub fn stripOf(f: File) bool`

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Cache = std.Build.Cache;
const assert = std.debug.assert;
const Zig = @import("Zig.zig");
const tree = @import("tree.zig");
const Queue = @import("Queue.zig");
const Server = @import("Server.zig");
const Backend = Zig.Backend;
const Module = Zig.Module;
const Piece = Zig.Piece;
const Split = Zig.Split;
const Output = tree.Output;

kind: Kind,
/// VerA-owned directory: the generated tree and shims, the compiler
/// cache of a library build, and the versioned libraries or the binary.
/// Created if absent. For `.check`, the scratch directory.
work_dir: []const u8,
/// Device or module name. A library is `<work_dir>/lib<name>.<generation>.so`
/// as the target spells it.
name: []const u8,
/// Independent of `backend`; `Backend.auto` is the usual pairing.
optimize: std.lang.Optimize,
/// The support modules, in argv order; every one is a dependency of the
/// root and of the device. A library needs `contract` (the device
/// imports it) and `dyn`, whose root exposes
/// `pub fn exportDevice(comptime D: type, comptime name: []const u8) void`
/// and may expose `exportDevicePart` (`contract.DevicePart`). A testbench
/// needs `contract`, plus `runtime_modules` when it runs on `sim`.
modules: []const Module,
/// Null is `Backend.auto(optimize, <this host>)`.
backend: ?Backend = null,
/// The compiler to spawn, looked up on `PATH` when bare. It must be the
/// Zig VerA was built with, or the build fails with `error.ProtocolMismatch`.
zig_exe: []const u8 = "zig",
/// Keep DWARF in a ReleaseFast/ReleaseSmall build. Debug information is
/// about half of a large device's LLVM time, and the machine code is the
/// same with or without it.
debug_info: bool = false,
/// Overrides `strip(optimize, debug_info)` when set. The fixture suite
/// strips its Debug testbenches: it reads only the transcript.
strip: ?bool = null,
/// `-target`, e.g. `x86_64-linux-gnu`: a host that dlopens the library
/// passes its own, so the library links the host's libc. Null is the
/// detected native target, which inside a Nix sandbox is musl.
target: ?[]const u8 = null,
split: Split = .by_size,
/// A `.v` device's prebuilt engine object (`buildEngine`): linked in,
/// and the shim declares `vera_prebuilt_engine`.
engine: ?[]const u8 = null,
/// A directory of finished libraries keyed by every input that decides
/// their bytes: a flush whose key is there copies the library instead of
/// compiling, whatever its `work_dir`. Not used with `engine`, a prebuilt
/// object outside the key.
cache_dir: ?[]const u8 = null,
/// A testbench's binary path instead of `<work_dir>/<name>`.
out_path: ?[]const u8 = null,

/// What a `File` becomes. `.so`: a device library for a `dyn` host.
/// `.osdi`: the same under the OSDI dyn, whose cold pieces may build
/// self-hosted (`File` doc). `.exe`: a testbench binary, or with `buildExe`
/// a runner library. `.check`: a type-check that emits nothing.
pub const Kind = enum { so, osdi, exe, check };

/// A build's outcome. Either payload is owned by the `gpa` the build was
/// given; free it with `deinit`.
pub const Artifact = union(enum) {
    /// The built file's path: a library's fresh generation path, the engine
    /// object in its cache directory, or a testbench binary.
    ok: []u8,
    /// The compiler's report on the generated code.
    failed: std.zig.ErrorBundle,

    /// Frees the payload with `gpa` and invalidates `self`.
    pub fn deinit(self: *Artifact, gpa: Allocator) void {
        switch (self.*) {
            .ok => |path| gpa.free(path),
            .failed => |*bundle| bundle.deinit(gpa),
        }
        self.* = undefined;
    }
};

/// Every way a build fails short of a compiler report: a child could not be
/// run or answered wrongly (`Server.Error`), the compiler reported success
/// but no artifact is where it said (`NoArtifact`), or a file could not be
/// written or copied (std's names). Every child is reaped and every
/// allocation freed; files already written stay.
pub const Error = Server.Error || tree.TreeError || error{NoArtifact} ||
    Io.Dir.CopyFileError || Io.Dir.AccessError || Io.File.Atomic.ReplaceError || Io.File.Writer.Error;

/// One step of a library flush, in order (`plan`): Zig's `link.ZcuTask`
/// with processes for tasks. `build_obj` is one `zig build-obj` child per
/// piece, run through the `Queue`; `link` is the one child that makes the
/// library, over the objects or, unsplit, from the whole tree. Per-unit
/// objects do not exist: units are generic over the host's `comptime S`
/// and have no code until the host's `dyn` fixes it (lib/TODO.md §7).
pub const Task = union(enum) {
    write_tree,
    build_obj: Piece,
    link,
};

/// Emitted device text from which `Split.by_size` splits an LLVM build into
/// pieces. Measured 2026-10-01 (stripped, slots grouped): the split leaves
/// eval's instructions per call unchanged but moves code, and that layout
/// shift was neutral to favourable on bsim4va (818 KB), psp103 (1.4 MB) and
/// coupled_ltra (5.8 MB) yet cost txl (590 KB) +47% eval cycles at identical
/// instructions; the threshold sits between them. Each extra process also
/// costs fixed std/process work, so mos1 (125 KB) gains nothing.
pub const split_min_bytes: usize = 768 * 1024;

const File = @This();

/// The parts, then at most `setup_chunks_max` chunks.
const pieces_max = std.enums.values(Zig.Part).len + Zig.setup_chunks_max;

/// Most module directories a cached library may span: `std.Build.Cache`'s
/// prefixes, one per directory, so a manifest never names an absolute path.
const cache_dirs_max = 5;

/// The cache key's format: a change to what `cacheOpen` hashes moves it.
const cache_format = "vera-link-1";

/// One flush's view of the library cache: `std.Build.Cache` over
/// `File.cache_dir` with one prefix per module directory, and the manifest
/// it checked. Lives in the flush's arena; must not move (`man` points at
/// `cache`).
const Stored = struct {
    cache: Cache,
    man: Cache.Manifest,
    dirs: [cache_dirs_max]Io.Dir,
    dirs_len: u8,
    /// The cached library on a hit; null on a miss, with `man` locked for
    /// `cacheStore`.
    hit: ?[]const u8,
    cwd: []const u8,

    fn close(s: *Stored, io: Io) void {
        s.man.deinit();
        s.cache.manifest_dir.close(io);
        for (s.dirs[0..s.dirs_len]) |d| d.close(io);
        s.* = undefined;
    }
};

/// Builds `device` cold into `<f.work_dir>/lib<f.name>.<generation>.so` as
/// this target spells a library, every child through `q`. With
/// `f.cache_dir` (and no `f.engine`) a flush whose key is cached copies that
/// library instead, and a fresh build is stored there. Caller owns the
/// result and frees it with `Artifact.deinit` and `gpa`. Fails as `Error`
/// says; a compile error in the generated code is `.failed`, not an error.
/// Asserts that `f` is a library, `f.modules` is not empty and
/// `device.setup_chunks` is at most `Zig.setup_chunks_max`.
pub fn flush(f: File, gpa: Allocator, io: Io, q: *Queue, device: Output, generation: u32) Error!Artifact {
    assert(f.kind == .so or f.kind == .osdi);
    assert(f.modules.len > 0);
    assert(device.setup_chunks <= Zig.setup_chunks_max);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const split = splits(f, device);

    // The manifest stays locked through the build, so a concurrent flush of
    // the same key waits for this one's library instead of building it too.
    const stored: ?*Stored = if (f.cache_dir != null and f.engine == null) try cacheOpen(gpa, io, arena, f, device, split) else null;
    defer if (stored) |s| s.close(io);
    if (stored) |s| if (s.hit) |src| {
        const dst = try generationPath(gpa, f, generation);
        errdefer gpa.free(dst);
        try Io.Dir.cwd().createDirPath(io, f.work_dir);
        // An entry gone from under its manifest is rebuilt.
        if (Io.Dir.cwd().copyFile(src, .cwd(), dst, io, .{})) {
            return .{ .ok = dst };
        } else |_| gpa.free(dst);
    };

    const tasks = try plan(arena, split, device.setup_chunks);
    assert(tasks[0] == .write_tree);
    assert(tasks[tasks.len - 1] == .link);
    const objs = tasks[1 .. tasks.len - 1];

    const engine: Zig.Engine = if (f.engine != null) .prebuilt else .none;
    _ = try tree.writeTree(gpa, io, .{ .work_dir = f.work_dir, .name = f.name, .engine = engine }, device);
    if (split) {
        var dir = try Io.Dir.cwd().openDir(io, f.work_dir, .{});
        defer dir.close(io);
        const setup: Zig.Setup = if (device.setup_chunks != 0) .chunked else .whole;
        for (objs) |t| {
            const text = try Zig.pieceShim(arena, f.name, t.build_obj, engine, setup);
            _ = try tree.writeIfChanged(gpa, io, dir, try Zig.shimName(arena, t.build_obj), text);
        }
    }

    // Each piece analyses the whole device, so a device error arrives from
    // every piece; the first piece's report is the one returned.
    const done = try arena.alloc(Server.Done, objs.len + 1);
    const objects = try arena.alloc([]const u8, objs.len);
    if (objs.len > 0) {
        const argvs = try arena.alloc([]const []const u8, objs.len);
        for (argvs, objs) |*a, t| a.* = try libraryArgv(arena, f, t.build_obj);
        if (try q.run(gpa, io, arena, argvs, done[0..objs.len])) |b| return .{ .failed = b };
        for (objects, done[0..objs.len], objs) |*o, d, t| o.* = try objectPath(arena, f, d.digest orelse return error.NoArtifact, t.build_obj);
    }
    const link_argv = if (split) try linkArgv(arena, f, objects) else try libraryArgv(arena, f, null);
    if (try q.run(gpa, io, arena, &.{link_argv}, done[objs.len..])) |b| return .{ .failed = b };

    const t = &builtin.target;
    const lib = try std.fs.path.join(arena, &.{
        f.work_dir,                                                            ".zig-cache",                                                                   "o",
        &Cache.binToHex(done[objs.len].digest orelse return error.NoArtifact), try arena.print("{s}{s}{s}", .{ t.libPrefix(), f.name, t.dynamicLibSuffix() }),
    });
    const dst = try generationPath(gpa, f, generation);
    errdefer gpa.free(dst);
    // A copy, so the host dlopens a fresh inode; a hard link would share the
    // cache entry's.
    Io.Dir.cwd().copyFile(lib, .cwd(), dst, io, .{}) catch return error.NoArtifact;
    // A cache that cannot be written costs a later flush a compile, never
    // this one its library.
    if (stored) |s| if (s.hit == null) cacheStore(s, arena, io, f, done, lib);
    assert(std.mem.startsWith(u8, dst, f.work_dir));
    return .{ .ok = dst };
}

/// Returns a library flush's tasks: `write_tree`, then for a split build
/// one `build_obj` per part in `contract.DevicePart` order and one per
/// `setup` chunk, then `link`. Allocated in `arena`. Asserts that `chunks`
/// is at most `Zig.setup_chunks_max` and that only a split build has chunks
/// built apart.
pub fn plan(arena: Allocator, split: bool, chunks: u32) Allocator.Error![]const Task {
    assert(chunks <= Zig.setup_chunks_max);
    const parts = comptime std.enums.values(Zig.Part);
    const n: usize = if (split) parts.len + chunks else 0;
    const tasks = try arena.alloc(Task, n + 2);
    tasks[0] = .write_tree;
    if (split) {
        for (tasks[1..][0..parts.len], parts) |*t, which| t.* = .{ .build_obj = .{ .part = which } };
        for (tasks[1 + parts.len ..][0..chunks], 0..) |*t, k| t.* = .{ .build_obj = .{ .chunk = @intCast(k) } };
    }
    tasks[n + 1] = .link;
    assert(tasks.len <= pieces_max + 2);
    return tasks;
}

/// Builds `sim`'s design-independent runtime (`rt/engine.zig`) as a
/// position-independent object for `File.engine`, with `f`'s compiler,
/// optimize mode, backend, `-fstrip` and modules (`dyn` aside), under
/// `cache_dir`, through `q`. Every device built with the same of each
/// shares one object: the compiler's own cache keys it on its version, the
/// target and CPU, every flag, and the path and content of every source
/// file reached (compiler_rt's prebuilt-object strategy, Zig's
/// `Compilation.buildRt`). A stale object cannot be linked: the engine's
/// symbol names carry its layout hash (`engine.tag`). Caller owns the result
/// and frees it with `Artifact.deinit` and `gpa`. Fails as `Error` says.
/// Asserts that `cache_dir` is not empty.
pub fn buildEngine(f: File, gpa: Allocator, io: Io, q: *Queue, cache_dir: []const u8) Error!Artifact {
    assert(cache_dir.len > 0);
    assert(f.name.len > 0);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cwd: Io.Dir = .cwd();
    try cwd.createDirPath(io, cache_dir);
    // Named by its content, so it is written once and never changes.
    const name = comptime std.fmt.comptimePrint("vera_engine_{x:0>16}.zig", .{std.hash.Wyhash.hash(0, Zig.engine_root)});
    const root = try std.fs.path.join(arena, &.{ cache_dir, name });
    cwd.access(io, root, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // Atomic: a concurrent `vera` never reads half the file.
            var af = try cwd.createFileAtomic(io, root, .{ .replace = true });
            defer af.deinit(io);
            try af.file.writeStreamingAll(io, Zig.engine_root);
            try af.replace(io);
        },
        else => |e| return e,
    };

    var modules: std.ArrayList(Module) = .empty;
    try modules.append(arena, .{ .name = "root", .root = root, .deps = &.{"sim"} });
    for (f.modules) |m| if (!std.mem.eql(u8, m.name, "dyn")) try modules.append(arena, m);
    var flags: std.ArrayList([]const u8) = .empty;
    try flags.appendSlice(arena, backendOf(f).flags());
    if (stripOf(f)) try flags.append(arena, "-fstrip");
    const a = try Zig.argv(arena, .{
        .zig_exe = f.zig_exe,
        .verb = "build-obj",
        .kind = &.{"-fPIC"},
        .optimize = f.optimize,
        .name = "vera_engine",
        .cache_dir = cache_dir,
        .libc = true,
        .target = f.target,
        .flags = flags.items,
        .modules = modules.items,
    });
    var done: [1]Server.Done = undefined;
    if (try q.run(gpa, io, arena, &.{a}, &done)) |b| return .{ .failed = b };
    const object = try std.fs.path.join(gpa, &.{
        cache_dir, "o", &Cache.binToHex(done[0].digest orelse return error.NoArtifact), "vera_engine" ++ comptime builtin.target.ofmt.fileExt(builtin.target.cpu.arch),
    });
    assert(std.mem.startsWith(u8, object, cache_dir));
    return .{ .ok = object };
}

/// `backend`, or `Backend.auto` for the optimize mode on this host.
pub fn backendOf(f: File) Backend {
    return f.backend orelse Backend.auto(f.optimize, builtin.target.cpu.arch);
}

/// `strip`, or `-fstrip` exactly when optimized without safety checks and
/// no debug information was asked for.
pub fn stripOf(f: File) bool {
    return f.strip orelse Zig.strip(f.optimize, f.debug_info);
}

// ---- private ----

/// Whether `flush` builds `device` as pieces.
fn splits(f: File, device: Output) bool {
    const split = switch (f.split) {
        .whole => false,
        .parts => true,
        .by_size => backendOf(f).forHost() == .llvm and device.text.len >= split_min_bytes,
    };
    if (f.split == .by_size and split) assert(device.text.len >= split_min_bytes);
    return split;
}

/// Returns the `zig build-lib` of the whole library, rooted at `shim.zig`,
/// or for a piece `p` the `zig build-obj` of `shim_<p>.zig` into
/// `<name>_<p>.o`. Only the whole library takes `f.engine`.
fn libraryArgv(arena: Allocator, f: File, p: ?Piece) Allocator.Error![]const []const u8 {
    assert(f.name.len > 0);
    assert(f.work_dir.len > 0);
    const host = backendOf(f).forHost();
    const backend: Backend = if (p) |q| (if (coldSelfHosted(f, q)) .self_hosted else host) else host;
    var flags: std.ArrayList([]const u8) = .empty;
    try flags.appendSlice(arena, backend.flags());
    // The only backend that patches in place, so the only one where
    // `-fincremental` pays. Not for a cold piece of an LLVM build: lld links
    // it beside the LLVM objects and refuses an incremental object's padded
    // `.eh_frame` ("corrupted .eh_frame: FDE version 1 or 3 expected").
    if (backend == .self_hosted and host == .self_hosted) try flags.append(arena, "-fincremental");
    if (stripOf(f)) try flags.append(arena, "-fstrip");
    if (p == null) if (f.engine) |e| try flags.append(arena, e);

    const names = try arena.alloc([]const u8, f.modules.len + 1);
    for (names[0..f.modules.len], f.modules) |*n, m| n.* = m.name;
    names[f.modules.len] = "device";
    const modules = try arena.alloc(Module, f.modules.len + 2);
    const root = if (p) |q| try Zig.shimName(arena, q) else "shim.zig";
    modules[0] = .{ .name = "root", .root = try std.fs.path.join(arena, &.{ f.work_dir, root }), .deps = names };
    modules[1] = .{ .name = "device", .root = try std.fs.path.join(arena, &.{ f.work_dir, "device.zig" }), .deps = names[0..f.modules.len] };
    @memcpy(modules[2..], f.modules);
    // An object linked into a shared library must be position independent.
    return Zig.argv(arena, .{
        .zig_exe = f.zig_exe,
        .verb = if (p == null) "build-lib" else "build-obj",
        .kind = if (p == null) &.{"-dynamic"} else &.{"-fPIC"},
        .optimize = f.optimize,
        .name = if (p) |q| try arena.print("{s}_{f}", .{ f.name, q }) else f.name,
        .cache_dir = try std.fs.path.join(arena, &.{ f.work_dir, ".zig-cache" }),
        .libc = true,
        .target = f.target,
        .flags = flags.items,
        .modules = modules,
    });
}

/// Returns the `zig build-lib -dynamic` that links a split build's
/// `objects` (and `f.engine`) into the library. The link takes `-O` and
/// `-fstrip` for the compiler_rt it adds; no Zig root module brings
/// start.zig's `_DllMainCRTStartup`, which a Windows DLL otherwise needs.
fn linkArgv(arena: Allocator, f: File, objects: []const []const u8) Allocator.Error![]const []const u8 {
    assert(objects.len > 0);
    var flags: std.ArrayList([]const u8) = .empty;
    if (stripOf(f)) try flags.append(arena, "-fstrip");
    try flags.appendSlice(arena, objects);
    if (f.engine) |e| try flags.append(arena, e);
    assert(flags.items.len >= objects.len);
    return Zig.argv(arena, .{
        .zig_exe = f.zig_exe,
        .verb = "build-lib",
        .kind = &.{ "-dynamic", "-fno-entry" },
        .optimize = f.optimize,
        .name = f.name,
        .cache_dir = try std.fs.path.join(arena, &.{ f.work_dir, ".zig-cache" }),
        .libc = true,
        .target = f.target,
        .flags = flags.items,
    });
}

/// Whether piece `p` builds self-hosted in an `.osdi` flush: a piece other
/// than `eval` and `state` (they run once per instance or card, so
/// unoptimized code costs the simulation nothing, and they leave LLVM's
/// critical path: psp103's three setup chunks, 1.35 s each under LLVM, take
/// 0.7 s), in an LLVM build for the native x86_64 Linux target, the one
/// place this compiler's self-hosted ELF objects link beside its LLVM ones.
/// Sound only for a `dyn` that keeps every per-iterate entry point out of
/// `.setup`, as `osdi_dyn` does.
fn coldSelfHosted(f: File, p: Piece) bool {
    if (f.kind != .osdi or backendOf(f).forHost() != .llvm or f.target != null) return false;
    if (builtin.target.cpu.arch != .x86_64 or builtin.target.os.tag != .linux) return false; // os: the self-hosted backend's ELF objects link beside LLVM's here
    return switch (p) {
        .part => |which| which == .setup,
        .chunk => true,
    };
}

/// The object a piece's child wrote, in the work directory's compiler cache.
fn objectPath(arena: Allocator, f: File, digest: Cache.BinDigest, p: Piece) Allocator.Error![]const u8 {
    assert(f.name.len > 0);
    const t = &builtin.target;
    return std.fs.path.join(arena, &.{
        f.work_dir,                                                                ".zig-cache", "o", &Cache.binToHex(digest),
        try arena.print("{s}_{f}{s}", .{ f.name, p, t.ofmt.fileExt(t.cpu.arch) }),
    });
}

/// `<work_dir>/lib<name>.<generation>.so`, spelled as this target names a
/// library: the fresh path a host dlopens. Caller owns it.
fn generationPath(gpa: Allocator, f: File, generation: u32) Allocator.Error![]u8 {
    const t = &builtin.target;
    const path = try gpa.print("{s}{c}{s}{s}.{d}{s}", .{
        f.work_dir, std.fs.path.sep, t.libPrefix(),
        f.name,     generation,      t.dynamicLibSuffix(),
    });
    assert(std.mem.endsWith(u8, path, t.dynamicLibSuffix()));
    return path;
}

/// Opens the library cache and checks `f`'s key: the compiler VerA was
/// built with and the one it spawns, every option that reaches a command
/// line, every byte of `device`, whether it splits, and each support
/// module's name, deps and root file. The root's sibling files join the key
/// after a build (`cacheStore`, from what the compiler read). Each module
/// directory is a cache prefix, so the manifest names a file by its path
/// inside its module, never an absolute path, and two checkouts share
/// entries. Returns null, uncached, when the modules span more than
/// `cache_dirs_max` directories or the cache cannot be opened or checked.
fn cacheOpen(gpa: Allocator, io: Io, arena: Allocator, f: File, device: Output, split: bool) Allocator.Error!?*Stored {
    assert(f.cache_dir != null);
    assert(f.modules.len > 0);
    const s = try arena.create(Stored);
    s.dirs_len = 0;
    s.hit = null;
    s.cwd = std.process.currentPathAlloc(io, arena) catch return null;
    // `distinct[0..dirs_len]` are the prefixes; `of[i]` is module i's.
    var distinct: [cache_dirs_max]Cache.Directory = undefined;
    const of = try arena.alloc(Cache.Directory, f.modules.len);
    var opened = false;
    defer if (!opened) for (s.dirs[0..s.dirs_len]) |d| d.close(io);
    for (f.modules, of) |m, *p| {
        const dir = std.fs.path.dirname(m.root) orelse ".";
        p.* = for (distinct[0..s.dirs_len]) |e| {
            if (std.mem.eql(u8, e.path.?, dir)) break e;
        } else new: {
            if (s.dirs_len == cache_dirs_max) return null;
            s.dirs[s.dirs_len] = Io.Dir.cwd().openDir(io, dir, .{}) catch return null;
            distinct[s.dirs_len] = .{ .path = dir, .handle = s.dirs[s.dirs_len] };
            s.dirs_len += 1;
            break :new distinct[s.dirs_len - 1];
        };
    }
    const manifests = std.fs.path.join(arena, &.{ f.cache_dir.?, "h" }) catch return null;
    s.cache = .{ .gpa = gpa, .io = io, .cwd = s.cwd, .manifest_dir = Io.Dir.cwd().createDirPathOpen(io, manifests, .{}) catch return null };
    for (distinct[0..s.dirs_len]) |p| s.cache.addPrefix(p);
    opened = true;

    s.man = s.cache.obtain();
    errdefer s.close(io);
    const h = &s.man.hash;
    h.addBytes(cache_format);
    h.addBytes(builtin.zig_version_string);
    // The spawned compiler's path: a Nix store path names its build.
    h.addBytes(f.zig_exe);
    h.add(f.kind);
    h.add(f.optimize);
    h.add(backendOf(f).forHost());
    h.addOptionalBytes(f.target);
    h.addBytes(f.name);
    h.add(f.debug_info);
    h.add(stripOf(f));
    h.add(split);
    h.addBytes(device.text);
    h.addListOfBytes(device.names);
    for ([_][]const u32{ device.unit_lo, device.unit_fn, device.unit_hi }) |offsets| h.addBytes(std.mem.sliceAsBytes(offsets));
    h.addBytes(device.prelude);
    h.addBytes(device.helpers);
    h.add(device.setup_chunks);
    for (f.modules, of) |m, p| {
        h.addBytes(m.name);
        h.addListOfBytes(m.deps);
        _ = try s.man.addInputPath(.{ .root_dir = p, .sub_path = std.fs.path.basename(m.root) }, .{});
    }
    var diag: Cache.Manifest.CheckDiagnostic = undefined;
    const result = s.man.checkProgressless(&diag) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.Canceled, error.CacheCheckFailed => {
            s.close(io);
            return null;
        },
    };
    if (result == .hit) s.hit = try libraryIn(arena, f, s.man.hitDigestHex());
    return s;
}

/// Finishes a missed key: every file the compiler read inside a module
/// directory joins it, then the library is copied in and the manifest
/// written. Gives up silently, leaving no manifest, on any failure, and on a
/// read file that is neither in the work directory (the tree, whose bytes
/// are keyed already) nor in a module directory.
fn cacheStore(s: *Stored, arena: Allocator, io: Io, f: File, done: []const Server.Done, library: []const u8) void {
    assert(s.hit == null);
    const work = std.fs.path.resolveAlloc(arena, &.{ s.cwd, f.work_dir }) catch return;
    for (done) |d| {
        var it = std.mem.splitScalar(u8, d.inputs, 0);
        while (it.next()) |entry| {
            if (entry.len < 2) continue;
            // The compiler's prefixes (`std.zig.Server.Message.PathPrefix`),
            // sent + 1: cwd and the build root are this process's cwd; the
            // Zig library and the caches are the compiler's own, keyed by
            // its version and path.
            const prefix = entry[0] -% 1;
            const Prefix = std.zig.Server.Message.PathPrefix;
            if (prefix != @backingInt(Prefix.cwd) and prefix != @backingInt(Prefix.build_root)) continue;
            const path = std.fs.path.resolveAlloc(arena, &.{ s.cwd, entry[1..] }) catch return;
            if (inside(work, path)) continue;
            const known = for (s.cache.prefixes()) |p| {
                const dir = std.fs.path.resolveAlloc(arena, &.{ s.cwd, p.path.? }) catch return;
                if (inside(dir, path)) break true;
            } else false;
            if (!known) return;
            s.man.addDiscoveredPath(.{ .discovered_path = .{ .unresolved = .{ .root_dir = .cwd(), .sub_path = path } } }) catch return;
        }
    }
    const dst = libraryIn(arena, f, s.man.missDigestHex()) catch return;
    Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(dst).?) catch return;
    Io.Dir.cwd().copyFile(library, .cwd(), dst, io, .{}) catch return;
    s.man.finalize() catch return;
}

/// `<cache_dir>/o/<digest>/lib<name>.so`, allocated in `arena`.
fn libraryIn(arena: Allocator, f: File, digest: Cache.HexDigest) Allocator.Error![]const u8 {
    const t = &builtin.target;
    return std.fs.path.join(arena, &.{ f.cache_dir.?, "o", &digest, try arena.print("{s}{s}{s}", .{ t.libPrefix(), f.name, t.dynamicLibSuffix() }) });
}

/// Whether resolved `path` lies strictly inside resolved `dir`.
fn inside(dir: []const u8, path: []const u8) bool {
    return path.len > dir.len and std.mem.startsWith(u8, path, dir) and std.fs.path.isSep(path[dir.len]);
}

test plan {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The tasks of each flush, and the names a split build gives its
    // objects and shims, written out.
    for ([_]bool{ false, true, true }, [_]u32{ 0, 0, 2 }, [_][]const u8{
        "write_tree link ",
        "write_tree setup state eval link ",
        "write_tree setup state eval setup0 setup1 link ",
    }) |split, chunks, want| {
        var got: std.ArrayList(u8) = .empty;
        for (try plan(a, split, chunks)) |t| switch (t) {
            .build_obj => |p| try got.print(a, "{f} ", .{p}),
            else => try got.print(a, "{t} ", .{t}),
        };
        try std.testing.expectEqualStrings(want, got.items);
    }
}

test "splits: an explicit choice wins over the size rule" {
    const tiny: Output = .{ .text = "x" };
    var f: File = .{ .kind = .so, .work_dir = "w", .name = "d", .optimize = .fast, .backend = .self_hosted, .modules = &.{}, .split = .parts };
    try std.testing.expect(splits(f, tiny));
    f.backend = .llvm;
    f.split = .whole;
    const huge = try std.testing.allocator.alloc(u8, split_min_bytes);
    defer std.testing.allocator.free(huge);
    try std.testing.expect(!splits(f, .{ .text = huge }));
    // One byte under the threshold stays whole; at it an LLVM build splits.
    f.split = .by_size;
    try std.testing.expect(!splits(f, .{ .text = huge[1..] }));
    try std.testing.expect(splits(f, .{ .text = huge }));
    f.backend = .self_hosted;
    try std.testing.expectEqual(Backend.self_hosted.forHost() == .llvm, splits(f, .{ .text = huge }));
}

test inside {
    try std.testing.expect(inside("/a/b", "/a/b/c.zig"));
    try std.testing.expect(!inside("/a/b", "/a/bc.zig"));
    try std.testing.expect(!inside("/a/b", "/a/b"));
}
