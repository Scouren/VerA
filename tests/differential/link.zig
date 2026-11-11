//! The `diff-link` oracle: `link` against the old `zigbuild`, building the
//! same devices with the same compiler. The devices are the
//! `tests/unit/zigbuild_tests.zig` stand-ins (whole, per-unit, split by
//! part, and broken whole and split) and the `vera --emit-zig` text of the
//! `tests/osdi` fixtures under the OSDI dyn, split by part as `--emit-osdi`
//! builds them. Each is built by `zigbuild.buildLibrary` at N jobs and by
//! `link.File.flush` at 1 job and at N. Agreement: both fail, with the same
//! message texts (and the new one's the same at 1 and N jobs), or both
//! succeed, every symbol the host's dyn exports resolves in both libraries,
//! on ELF the two exported dynamic symbol tables are equal, and a stripped
//! new library's bytes are equal at 1 and N jobs (a Debug one's DWARF names
//! its own work directory). A case that disagrees passes
//! only when a line of `link.xfail` names it, and a listed case that agrees
//! fails the run (an unexpected pass).
//! Cites: §8.3's device-side ABI; OSDI 0.4 (`lib/osdi_dyn.zig`'s exports).
//!
//! Contents: none public; tests only.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const link = @import("link");
const zigbuild = @import("zigbuild");
const DynLib = @import("dynlib").DynLib;
const options = @import("rewrite_options");
const repo_env = @import("repo_env");

/// The parallel job count, against 1. Each child holds a whole device's
/// analysis; the machine is shared.
const jobs_n = 3;

/// The `dyn` a case builds under: a stand-in with `exportDevice` alone, one
/// with `exportDevicePart`, or the shipped OSDI dyn.
const Dyn = enum { plain, parts, osdi };

/// Where a case's device text comes from: written here, the two-unit
/// device in codegen's per-unit shape, or `vera --emit-zig` of a fixture.
const Source = union(enum) { text: []const u8, units, emitted: []const u8 };

const Case = struct {
    /// The `link.xfail` key.
    id: []const u8,
    source: Source,
    dyn: Dyn,
    optimize: std.lang.Optimize,
    backend: link.Backend,
    split: link.Split,
    /// Symbols the dyn exports for this device: each must resolve in both
    /// libraries, on every object format.
    exports: []const [:0]const u8,
};

const scale_dev = "pub fn eval(x: f64) callconv(.c) f64 { return x * @import(\"contract\").k; }\n";
const k_dev =
    \\pub fn k() callconv(.c) f64 { return @import("contract").k; }
    \\pub fn eval(x: f64) callconv(.c) f64 { return x * @import("contract").k; }
    \\
;
const broken_dev = "pub fn eval() callconv(.c) void { @compileError(\"boom\"); }\n";
const osdi_exports = [_][:0]const u8{ "OSDI_VERSION_MAJOR", "OSDI_VERSION_MINOR", "OSDI_NUM_DESCRIPTORS", "OSDI_DESCRIPTOR_SIZE", "OSDI_DESCRIPTORS", "osdi_log" };

const cases = [_]Case{
    .{ .id = "unit/whole", .source = .{ .text = scale_dev }, .dyn = .plain, .optimize = .debug, .backend = .self_hosted, .split = .whole, .exports = &.{"arp_eval"} },
    .{ .id = "unit/units", .source = .units, .dyn = .plain, .optimize = .debug, .backend = .self_hosted, .split = .whole, .exports = &.{"arp_eval"} },
    .{ .id = "unit/parts", .source = .{ .text = k_dev }, .dyn = .parts, .optimize = .fast, .backend = .llvm, .split = .parts, .exports = &.{ "arp_k", "arp_eval" } },
    .{ .id = "unit/broken", .source = .{ .text = broken_dev }, .dyn = .plain, .optimize = .debug, .backend = .self_hosted, .split = .whole, .exports = &.{} },
    .{ .id = "unit/broken-parts", .source = .{ .text = broken_dev }, .dyn = .parts, .optimize = .fast, .backend = .llvm, .split = .parts, .exports = &.{} },
    .{ .id = "osdi/resistor", .source = .{ .emitted = "resistor" }, .dyn = .osdi, .optimize = .fast, .backend = .llvm, .split = .parts, .exports = &osdi_exports },
    .{ .id = "osdi/diode", .source = .{ .emitted = "diode" }, .dyn = .osdi, .optimize = .fast, .backend = .llvm, .split = .parts, .exports = &osdi_exports },
    .{ .id = "osdi/mixed", .source = .{ .emitted = "mixed" }, .dyn = .osdi, .optimize = .fast, .backend = .llvm, .split = .parts, .exports = &osdi_exports },
};

const plain_dyn =
    \\pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
    \\    _ = name;
    \\    @export(&D.eval, .{ .name = "arp_eval" });
    \\}
    \\
;
const parts_dyn =
    \\pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
    \\    _ = .{ D, name };
    \\    @compileError("a split build calls exportDevicePart");
    \\}
    \\pub fn exportDevicePart(comptime D: type, comptime name: []const u8, comptime part: @TypeOf(.setup)) void {
    \\    _ = name;
    \\    if (part == .setup and @hasDecl(D, "k")) @export(&D.k, .{ .name = "arp_k" });
    \\    if (part == .eval) @export(&D.eval, .{ .name = "arp_eval" });
    \\}
    \\
;

// The two-unit device in codegen's per-unit shape (prologue, two tiling
// unit ranges, dispatcher tail): src/zigbuild/tree.zig's `splitOutput`.
const split_prologue = "const contract = @import(\"contract\");\npub const k2: f64 = 2.0;\n";
const split_unit_a = "fn unit_a(y: f64) f64 {\n    return y * k2;\n}\n";
const split_unit_b = "fn unit_b(y: f64) f64 {\n    return y + k2;\n}\n";
const split_tail = "pub fn eval(x: f64) callconv(.c) f64 {\n    return unit_a(x) + unit_b(x);\n}\n";
const a_hi = split_prologue.len + split_unit_a.len;
const b_hi = a_hi + split_unit_b.len;
const units_names = [_][]const u8{ "unit_a", "unit_b" };
const units_lo = [_]u32{ split_prologue.len, a_hi };
const units_hi = [_]u32{ a_hi, b_hi };

/// One build's outcome as the oracle reads it, in `arena`.
const Outcome = union(enum) {
    /// The library's bytes.
    ok: []const u8,
    /// The report's message texts, in order.
    failed: []const []const u8,
};

/// One line of `link.xfail`: `<case id> <reason>`.
const Allowed = struct { id: []const u8, line: u32, seen: bool = false };

// ---- private ----

/// The support modules of `dyn`: the repository's `contract` and OSDI dyn,
/// or a stand-in contract (`k = 2.0`) and dyn written under `base`.
fn modules(arena: Allocator, io: Io, base: []const u8, dyn: Dyn) ![]const link.Module {
    if (dyn == .osdi) return arena.dupe(link.Module, &.{
        .{ .name = "contract", .root = try std.fs.path.join(arena, &.{ repo_env.repoRoot(), "lib", "contract.zig" }) },
        .{ .name = "dyn", .root = try std.fs.path.join(arena, &.{ repo_env.repoRoot(), "lib", "osdi_dyn.zig" }), .deps = &.{"contract"} },
    });
    const dir = try arena.print("{s}/mods-{t}", .{ base, dyn });
    try Io.Dir.cwd().createDirPath(io, dir);
    const contract = try std.fs.path.join(arena, &.{ dir, "contract.zig" });
    const dyn_root = try std.fs.path.join(arena, &.{ dir, "dyn.zig" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = contract, .data = "pub const k: f64 = 2.0;\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dyn_root, .data = if (dyn == .parts) parts_dyn else plain_dyn });
    return arena.dupe(link.Module, &.{ .{ .name = "contract", .root = contract }, .{ .name = "dyn", .root = dyn_root } });
}

fn oldModules(arena: Allocator, mods: []const link.Module) ![]const zigbuild.Module {
    const out = try arena.alloc(zigbuild.Module, mods.len);
    for (out, mods) |*o, m| o.* = .{ .name = m.name, .root = m.root, .deps = m.deps };
    return out;
}

fn deviceOf(arena: Allocator, io: Io, s: Source) !link.Output {
    return switch (s) {
        .text => |t| .{ .text = t },
        .units => .{
            .text = split_prologue ++ split_unit_a ++ split_unit_b ++ split_tail,
            .names = &units_names,
            .unit_lo = &units_lo,
            .unit_fn = &units_lo,
            .unit_hi = &units_hi,
            .prelude = "const dev = @import(\"../device.zig\");\nconst k2 = dev.k2;\n",
            .helpers = "pub const k3: f64 = 3.0;\n",
        },
        .emitted => |stem| .{ .text = try Io.Dir.cwd().readFileAlloc(io, try arena.print("{s}/{s}.zig", .{ options.emitted, stem }), arena, .limited(64 << 20)) },
    };
}

/// Reads a build's outcome into `arena`: the library's bytes, or the report's
/// message texts.
fn outcome(arena: Allocator, io: Io, r: union(enum) { ok: []const u8, failed: std.zig.ErrorBundle }) !Outcome {
    switch (r) {
        .ok => |path| return .{ .ok = try Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) },
        .failed => |b| {
            const msgs = b.getMessages();
            const texts = try arena.alloc([]const u8, msgs.len);
            for (texts, msgs) |*t, m| t.* = try arena.dupe(u8, b.nullTerminatedString(b.getErrorMessage(m).msg));
            return .{ .failed = texts };
        },
    }
}

/// Returns why the builds disagree, or null when they agree (the header's
/// rule). `old_path` and `new_path` are the libraries to load.
fn compare(arena: Allocator, c: Case, old: Outcome, new: [2]Outcome, old_path: ?[]const u8, new_path: ?[]const u8) !?[]const u8 {
    if (std.meta.activeTag(new[0]) != std.meta.activeTag(new[1])) return try arena.print("new at 1 job {t}, at {d} {t}", .{ new[0], jobs_n, new[1] });
    if (std.meta.activeTag(old) != std.meta.activeTag(new[1])) return try arena.print("old {t}, new {t}", .{ old, new[1] });
    switch (old) {
        .failed => |want| {
            for (new) |n| if (!sameStrings(want, n.failed))
                return try arena.print("messages differ: old {d}, new {d}", .{ want.len, n.failed.len });
            return null;
        },
        .ok => |old_bytes| {
            // A Debug library's DWARF names the work directory it was built
            // in, and the two builds have their own.
            if (link.strip(c.optimize, false) and !std.mem.eql(u8, new[0].ok, new[1].ok))
                return "new library bytes differ between 1 job and N";
            if (builtin.target.ofmt == .elf) {
                const want = try elfExports(arena, old_bytes);
                const got = try elfExports(arena, new[1].ok);
                if (!sameStrings(want, got)) return try arena.print("exported symbols differ: old {d}, new {d}", .{ want.len, got.len });
            }
            for ([_][]const u8{ old_path.?, new_path.? }) |p| {
                var lib = DynLib.open(p) catch |e| return try arena.print("{s} does not load: {t}", .{ p, e });
                defer lib.close();
                for (c.exports) |name| if (lib.lookup(*const anyopaque, name) == null)
                    return try arena.print("{s} does not export {s}", .{ p, name });
            }
            return null;
        },
    }
}

/// An ELF symbol's `st_info`: binding in the high nibble, type in the low.
fn info(bind: u8, kind: u8) u8 {
    return bind << 4 | kind;
}

fn sameStrings(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// The names of the defined global and weak symbols in an ELF64 file's
/// `.dynsym`, sorted, allocated in `arena`. Fails with `error.NotElf64` or
/// `error.Truncated` on a file that is not one.
fn elfExports(arena: Allocator, bytes: []const u8) ![]const []const u8 {
    const Ehdr = std.elf.Elf64_Ehdr;
    const Shdr = std.elf.Elf64_Shdr;
    const Sym = std.elf.Elf64_Sym;
    if (bytes.len < @sizeOf(Ehdr) or !std.mem.eql(u8, bytes[0..4], std.elf.MAGIC)) return error.NotElf64;
    if (bytes[std.elf.EI_CLASS] != std.elf.ELFCLASS64) return error.NotElf64;
    const eh = std.mem.bytesToValue(Ehdr, bytes[0..@sizeOf(Ehdr)]);
    const shdrs = try table(Shdr, arena, bytes, eh.e_shoff, @as(u64, eh.e_shnum) * @sizeOf(Shdr));
    var names: std.ArrayList([]const u8) = .empty;
    for (shdrs) |sh| {
        if (sh.sh_type != std.elf.SHT_DYNSYM) continue;
        if (sh.sh_link >= shdrs.len) return error.Truncated;
        const strs = shdrs[sh.sh_link];
        if (strs.sh_offset + strs.sh_size > bytes.len) return error.Truncated;
        const strtab = bytes[strs.sh_offset..][0..strs.sh_size];
        for (try table(Sym, arena, bytes, sh.sh_offset, sh.sh_size)) |s| {
            const bind = s.st_info >> 4;
            if (s.st_shndx == std.elf.SHN_UNDEF) continue;
            if (bind != std.elf.STB_GLOBAL and bind != std.elf.STB_WEAK) continue;
            if (s.st_name >= strtab.len) return error.Truncated;
            try names.append(arena, std.mem.sliceTo(strtab[s.st_name..], 0));
        }
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.items;
}

/// The `T` rows at `offset` spanning `size` bytes of `bytes`, copied into
/// `arena` (the file's alignment is not `T`'s).
fn table(comptime T: type, arena: Allocator, bytes: []const u8, offset: u64, size: u64) ![]const T {
    if (offset + size > bytes.len or size % @sizeOf(T) != 0) return error.Truncated;
    const rows = try arena.alloc(T, size / @sizeOf(T));
    @memcpy(std.mem.sliceAsBytes(rows), bytes[offset..][0..size]);
    return rows;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Parses `link.xfail`: `#` comments, blank lines, and `<case id> <reason>`.
/// Every id must name a case.
fn parseXfail(arena: Allocator, text: []const u8) ![]Allowed {
    var out: std.ArrayList(Allowed) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var line: u32 = 0;
    while (it.next()) |raw| {
        line += 1;
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len == 0 or l[0] == '#') continue;
        const id = l[0 .. std.mem.findScalar(u8, l, ' ') orelse return error.XfailLineHasNoReason];
        for (cases) |c| {
            if (std.mem.eql(u8, c.id, id)) break;
        } else return error.XfailNamesNoCase;
        try out.append(arena, .{ .id = id, .line = line });
    }
    return out.items;
}

test "diff-link: link agrees with zigbuild on every case" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try arena.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    const allowed = try parseXfail(arena, @embedFile("link.xfail"));

    var slots: [jobs_n]link.Server = undefined;
    var differ: u32 = 0;
    for (cases, 0..) |c, i| {
        const mods = try modules(arena, io, base, c.dyn);
        const device = try deviceOf(arena, io, c.source);
        const name = switch (c.source) {
            .emitted => |stem| stem,
            else => "dev",
        };
        var old_path: ?[]const u8 = null;
        const old = old: {
            const o: zigbuild.Options = .{
                .work_dir = try arena.print("{s}/old{d}", .{ base, i }),
                .name = name,
                .optimize = c.optimize,
                .backend = switch (c.backend) {
                    .self_hosted => .self_hosted,
                    .llvm => .llvm,
                },
                .modules = try oldModules(arena, mods),
                .split = switch (c.split) {
                    .by_size => .by_size,
                    .whole => .whole,
                    .parts => .parts,
                },
                .cold_self_hosted = c.dyn == .osdi,
                .jobs = jobs_n,
            };
            var r = try zigbuild.buildLibrary(gpa, io, o, .{
                .text = device.text,
                .names = device.names,
                .unit_lo = device.unit_lo,
                .unit_fn = device.unit_fn,
                .unit_hi = device.unit_hi,
                .prelude = device.prelude,
                .helpers = device.helpers,
                .setup_chunks = device.setup_chunks,
            }, 1);
            defer r.deinit(gpa);
            if (r == .ok) old_path = try arena.dupe(u8, r.ok);
            break :old try outcome(arena, io, switch (r) {
                .ok => |p| .{ .ok = p },
                .failed => |b| .{ .failed = b },
            });
        };
        var new: [2]Outcome = undefined;
        var paths: [2]?[]const u8 = .{ null, null };
        for ([_]usize{ 1, jobs_n }, &new, &paths) |jobs, *out, *path| {
            var q: link.Queue = .init(slots[0..jobs]);
            const f: link.File = .{
                .kind = if (c.dyn == .osdi) .osdi else .so,
                .work_dir = try arena.print("{s}/new{d}j{d}", .{ base, i, jobs }),
                .name = name,
                .optimize = c.optimize,
                .backend = c.backend,
                .modules = mods,
                .split = c.split,
            };
            var r = try f.flush(gpa, io, &q, device, 1);
            defer r.deinit(gpa);
            if (r == .ok) path.* = try arena.dupe(u8, r.ok);
            out.* = try outcome(arena, io, switch (r) {
                .ok => |p| .{ .ok = p },
                .failed => |b| .{ .failed = b },
            });
        }
        const why = try compare(arena, c, old, new, old_path, paths[1]);
        const listed = for (allowed) |*a| {
            if (std.mem.eql(u8, a.id, c.id)) break a;
        } else null;
        if (why) |w| {
            std.debug.print("diff-link: {s}: {s}{s}\n", .{ c.id, w, if (listed != null) " (link.xfail)" else "" });
            if (listed) |a| a.seen = true else differ += 1;
        } else {
            std.debug.print("diff-link: {s}: agrees ({t})\n", .{ c.id, old });
        }
    }
    var unexpected: u32 = 0;
    for (allowed) |a| if (!a.seen) {
        std.debug.print("diff-link: link.xfail line {d} ({s}) agrees: an unexpected pass, remove the line\n", .{ a.line, a.id });
        unexpected += 1;
    };
    std.debug.print("diff-link: {d} cases, {d} differ unlisted, {d} listed\n", .{ cases.len, differ, allowed.len });
    try std.testing.expectEqual(@as(u32, 0), differ);
    try std.testing.expectEqual(@as(u32, 0), unexpected);
}

test elfExports {
    // The oracle's own reader against a hand-made table: two defined
    // globals, a weak one, an undefined import and a local, out of order.
    // It reads bytes, so it runs on every host.
    const Sym = std.elf.Elf64_Sym;
    const Shdr = std.elf.Elf64_Shdr;
    const strtab = "\x00zeta\x00alpha\x00weak\x00undef\x00local\x00";
    const syms = [_]Sym{
        std.mem.zeroes(Sym),
        .{ .st_name = 1, .st_info = info(std.elf.STB_GLOBAL, std.elf.STT_FUNC), .st_other = 0, .st_shndx = 9, .st_value = 0, .st_size = 0 },
        .{ .st_name = 6, .st_info = info(std.elf.STB_GLOBAL, std.elf.STT_OBJECT), .st_other = 0, .st_shndx = 9, .st_value = 0, .st_size = 0 },
        .{ .st_name = 12, .st_info = info(std.elf.STB_WEAK, std.elf.STT_FUNC), .st_other = 0, .st_shndx = 9, .st_value = 0, .st_size = 0 },
        .{ .st_name = 17, .st_info = info(std.elf.STB_GLOBAL, std.elf.STT_FUNC), .st_other = 0, .st_shndx = 0, .st_value = 0, .st_size = 0 },
        .{ .st_name = 23, .st_info = info(std.elf.STB_LOCAL, std.elf.STT_FUNC), .st_other = 0, .st_shndx = 9, .st_value = 0, .st_size = 0 },
    };
    const eh_size = @sizeOf(std.elf.Elf64_Ehdr);
    const syms_at = eh_size;
    const str_at = syms_at + @sizeOf(@TypeOf(syms));
    const sh_at = comptime std.mem.alignForward(usize, str_at + strtab.len, 8);
    var bytes: [sh_at + 3 * @sizeOf(Shdr)]u8 align(8) = @splat(0);
    var eh = std.mem.zeroes(std.elf.Elf64_Ehdr);
    @memcpy(eh.e_ident[0..4], std.elf.MAGIC);
    eh.e_ident[std.elf.EI_CLASS] = std.elf.ELFCLASS64;
    eh.e_shoff = sh_at;
    eh.e_shentsize = @sizeOf(Shdr);
    eh.e_shnum = 3;
    @memcpy(bytes[0..eh_size], std.mem.asBytes(&eh));
    @memcpy(bytes[syms_at..str_at], std.mem.sliceAsBytes(&syms));
    @memcpy(bytes[str_at..][0..strtab.len], strtab);
    var sh: [3]Shdr = .{ std.mem.zeroes(Shdr), std.mem.zeroes(Shdr), std.mem.zeroes(Shdr) };
    sh[1].sh_type = std.elf.SHT_DYNSYM;
    sh[1].sh_offset = syms_at;
    sh[1].sh_size = @sizeOf(@TypeOf(syms));
    sh[1].sh_entsize = @sizeOf(Sym);
    sh[1].sh_link = 2;
    sh[2].sh_type = std.elf.SHT_STRTAB;
    sh[2].sh_offset = str_at;
    sh[2].sh_size = strtab.len;
    @memcpy(bytes[sh_at..], std.mem.sliceAsBytes(&sh));

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try elfExports(arena.allocator(), &bytes);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    for ([_][]const u8{ "alpha", "weak", "zeta" }, got) |w, g| try std.testing.expectEqualStrings(w, g);
}
