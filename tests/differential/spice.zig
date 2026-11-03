//! The differential oracle of the vams SPICE reader (`zig build diff-spice`,
//! docs/rewrite/spice.md): every netlist the fixtures use in, a verdict per
//! netlist out. The oracle is lib/frontend's `spice_cards.synthesize`, the
//! product until the rewrite replaces it: both read the same bytes under the
//! same path, the old one through `frontend.Files`, the new one answering its
//! requests from the same disk. The corpus: every `.sp`, `.inc`, `.lib`,
//! `.spice` and `.cir` file under `tests/` (the conformance decks and
//! VerA's own), each fixture's `//! spice` cards (joined as the harness joins
//! them, read beside the fixture as `vera` reads them), and `generated`
//! card-shaped inputs built from the old fuzz test's words. A netlist agrees
//! when the module text is byte-equal, the module counts are equal, the
//! refusals are equal in order (code, message, file name, offset, length),
//! and the unsupported-model, `.HDL` and file lists are equal. A known
//! difference is a line of `spice.xfail` (`<key> <reason>`, the key a path
//! under `tests/` or `gen:<n>`); a listed netlist that agrees, or that is
//! not in the corpus, fails the run until its line goes.
//! Cites: LRM annex E.1.2, E.2, E.3, E.4 (through both implementations).
//!
//! Contents: tests only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const frontend = @import("frontend");
const rewrite_options = @import("rewrite_options");
const spice = vams.spice;
const old = frontend.spice_cards;
const readText = frontend.preprocessor.readText;

/// Card-shaped inputs compared, each from its own seed.
const generated = 20_000;

/// The old `spice_cards.zig` fuzz test's words (`fuzz_words`), copied: the
/// generator both sides read. No `.include`, `.lib` or `.hdl`, so a
/// generated netlist reads no file.
const fuzz_words = [_][]const u8{ ".subckt", ".ends", ".model", ".param", ".endl", "+", "r1", "c1", "v1", "i1", "e1", "f1", "g1", "h1", "m1", "q1", "j1", "d1", "x1", "k1", "a", "b", "0", "1", "1k", "2n2222", "nch", "nch.1", "npn", "nmos", "bsim4", "params:", "w=1", "l={2*w}", "m=2", "lmin=0", "lmax=1", "{w*2}", "'w+1'", "{", "}", "'", "(", ")", ",", "=", "**", "-", "poly", "value={1}", "*", ";", "$", "\n", "1e999k", "wire" };

/// One netlist of the corpus: its key, its bytes and the path both readers
/// are given ("" for a generated one).
const Case = struct { key: []const u8, text: []const u8, path: []const u8 };

// ---- private ----

/// Every netlist under `tests/`, sorted by key (`Dir.walk` order is
/// undefined).
fn collect(a: Allocator, io: std.Io, tests_root: []const u8) ![]const Case {
    var dir = try std.Io.Dir.cwd().openDir(io, tests_root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var list: std.ArrayList(Case) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.path);
        const path = try std.fs.path.join(a, &.{ tests_root, entry.path });
        const key = try a.dupe(u8, entry.path);
        if (isAny(ext, &.{ ".sp", ".inc", ".lib", ".spice", ".cir" })) {
            try list.append(a, .{ .key = key, .text = try readText(io, .cwd(), path, a), .path = path });
        } else if (isAny(ext, &.{ ".va", ".vams", ".v" })) {
            const cards = try spiceCards(a, try readText(io, .cwd(), path, a));
            if (cards.len != 0) try list.append(a, .{ .key = key, .text = cards, .path = path });
        }
    }
    std.mem.sort(Case, list.items, {}, struct {
        fn lt(_: void, x: Case, y: Case) bool {
            return std.mem.lessThan(u8, x.key, y.key);
        }
    }.lt);
    return list.items;
}

fn isAny(ext: []const u8, set: []const []const u8) bool {
    for (set) |e| if (std.mem.eql(u8, ext, e)) return true;
    return false;
}

/// A fixture's `//! spice` operands joined by newlines, as
/// src/codegen/exe/parse.zig builds `Harness.spice`: each line trimmed, the
/// directive after `//!` trimmed, its operand trimmed and verbatim.
fn spiceCards(a: Allocator, text: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const body = std.mem.trim(u8, std.mem.cutPrefix(u8, line, "//!") orelse continue, " \t");
        const kw_end = std.mem.findAny(u8, body, " \t") orelse body.len;
        if (!std.mem.eql(u8, body[0..kw_end], "spice")) continue;
        const rest = std.mem.trim(u8, body[kw_end..], " \t");
        if (rest.len != 0) try parts.append(a, rest);
    }
    return std.mem.join(a, "\n", parts.items);
}

/// Generated netlist `n`: words of `fuzz_words` drawn from seed `n`, each
/// followed by a blank, up to the old fuzz test's 2048-byte buffer.
fn generate(a: Allocator, n: u64) ![]const u8 {
    var prng: std.Random.DefaultPrng = .init(n);
    const r = prng.random();
    const words = r.uintLessThan(usize, 160);
    var out: std.ArrayList(u8) = .empty;
    for (0..words) |_| {
        const w = fuzz_words[r.uintLessThan(usize, fuzz_words.len)];
        if (out.items.len + w.len + 1 > 2048) break;
        try out.appendSlice(a, w);
        try out.append(a, ' ');
    }
    return out.items;
}

/// `spice.xfail`: one `<key> <reason>` per line; `#` lines and blank lines
/// are comments. A line without a reason is refused.
fn readXfail(a: Allocator, io: std.Io, path: []const u8) !std.StringHashMapUnmanaged([]const u8) {
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    const text = try readText(io, .cwd(), path, a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.findAny(u8, line, " \t") orelse {
            std.debug.print("diff-spice: spice.xfail line `{s}` has no reason\n", .{line});
            return error.XfailWithoutReason;
        };
        try map.put(a, line[0..sp], std.mem.trim(u8, line[sp..], " \t"));
    }
    return map;
}

/// What the agreeing netlists exercised, printed with the verdict so a
/// green run shows it compared something.
const Coverage = struct { modules: usize = 0, refusals: usize = 0, requests: usize = 0, hdl: usize = 0, bytes: usize = 0 };

/// Runs both readers on `c` and returns null when they agree, else what
/// differs first.
fn compare(a: Allocator, io: std.Io, c: Case, cov: *Coverage) !?[]const u8 {
    var files: frontend.Files = .init(io, a);
    const o = try old.synthesize(a, c.text, c.path, &files);

    var n: spice.Netlist = .init(a, c.path, c.text);
    defer n.deinit();
    var requests: usize = 0;
    while (try n.run()) |req| switch (req) {
        .file => |want| {
            requests += 1;
            if (requests > 10_000) return "more than 10,000 requests";
            try n.answer(readText(io, .cwd(), want.path, a) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => null,
            });
        },
    };
    const out = n.output();

    if (o.modules != out.modules) return try a.print("modules: old {d}, new {d}", .{ o.modules, out.modules });
    if (!std.mem.eql(u8, o.text, out.text)) return try textDiff(a, o.text, out.text);
    if (o.refused.len != out.refusals.len) return try a.print("refusals: old {d}, new {d}{s}", .{
        o.refused.len, out.refusals.len, try firstRefusals(a, o, out),
    });
    for (o.refused, out.refusals, 0..) |x, y, k| {
        const same = std.mem.eql(u8, @tagName(x.code), @tagName(y.code)) and std.mem.eql(u8, x.why, y.message) and
            std.mem.eql(u8, o.files[x.file].name, out.files[y.file].name) and x.at == y.at and x.len == y.len;
        if (!same) return try a.print("refusal {d}: old {t} {s}:{d}+{d} \"{s}\", new {t} {s}:{d}+{d} \"{s}\"", .{
            k, x.code, o.files[x.file].name, x.at, x.len, x.why, y.code, out.files[y.file].name, y.at, y.len, y.message,
        });
    }
    if (!sameList(o.unsupported, out.unsupported)) return "unsupported models differ";
    if (!sameList(o.hdl, out.hdl)) return try a.print("hdl: old {s}, new {s}", .{ try std.mem.join(a, ",", o.hdl), try std.mem.join(a, ",", out.hdl) });
    if (o.files.len != out.files.len) return try a.print("files: old {d}, new {d}", .{ o.files.len, out.files.len });
    for (o.files, out.files) |x, y| if (!std.mem.eql(u8, x.name, y.name) or !std.mem.eql(u8, x.text, y.text))
        return try a.print("file: old {s}, new {s}", .{ x.name, y.name });
    cov.modules += out.modules;
    cov.refusals += out.refusals.len;
    cov.requests += requests;
    cov.hdl += out.hdl.len;
    cov.bytes += out.text.len;
    return null;
}

fn firstRefusals(a: Allocator, o: old.Synthesized, out: spice.Output) ![]const u8 {
    return a.print(" (old first: \"{s}\", new first: \"{s}\")", .{
        if (o.refused.len != 0) o.refused[0].why else "",
        if (out.refusals.len != 0) out.refusals[0].message else "",
    });
}

fn sameList(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    return true;
}

/// The first differing byte and the text around it on each side.
fn textDiff(a: Allocator, o: []const u8, n: []const u8) ![]const u8 {
    const at = std.mem.indexOfDiff(u8, o, n).?;
    const from = at -| 40;
    return a.print("text differs at byte {d} (old {d} bytes, new {d}): old \"{f}\" new \"{f}\"", .{
        at,                                               o.len,                                            n.len,
        std.zig.fmtString(o[from..@min(at + 40, o.len)]), std.zig.fmtString(n[from..@min(at + 40, n.len)]),
    });
}

test "diff-spice: the vams SPICE reader agrees with spice_cards.synthesize on every netlist" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var run_arena: std.heap.ArenaAllocator = .init(gpa);
    defer run_arena.deinit();
    const ra = run_arena.allocator();
    const tests_root = try std.fs.path.join(ra, &.{ rewrite_options.repo_root, "tests" });

    var cases: std.ArrayList(Case) = .empty;
    try cases.appendSlice(ra, try collect(ra, io, tests_root));
    const from_disk = cases.items.len;
    for (0..generated) |k| try cases.append(ra, .{ .key = try ra.print("gen:{d}", .{k}), .text = try generate(ra, k), .path = "" });
    const xfail = try readXfail(ra, io, try std.fs.path.join(ra, &.{ tests_root, "differential/spice.xfail" }));

    var case_arena: std.heap.ArenaAllocator = .init(gpa);
    defer case_arena.deinit();
    var agreed: usize = 0;
    var listed: usize = 0;
    var bad: usize = 0;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var cov: Coverage = .{};
    for (cases.items) |c| {
        _ = case_arena.reset(.retain_capacity);
        try seen.put(ra, c.key, {});
        const why = try compare(case_arena.allocator(), io, c, &cov);
        const reason = xfail.get(c.key);
        if (why) |w| {
            if (reason != null) {
                listed += 1;
                continue;
            }
            bad += 1;
            if (bad <= 40) std.debug.print("diff-spice: MISMATCH {s}: {s}\n", .{ c.key, w });
        } else if (reason) |r| {
            bad += 1;
            std.debug.print("diff-spice: XPASS {s} agrees; remove its spice.xfail line ({s})\n", .{ c.key, r });
        } else agreed += 1;
    }
    var it = xfail.keyIterator();
    while (it.next()) |k| if (!seen.contains(k.*)) {
        bad += 1;
        std.debug.print("diff-spice: STALE {s} is in spice.xfail but not in the corpus\n", .{k.*});
    };
    std.debug.print("diff-spice: {d} netlists compared ({d} from tests/, {d} generated), {d} agreed, {d} listed in spice.xfail, {d} failed\n", .{ cases.items.len, from_disk, generated, agreed, listed, bad });
    std.debug.print("diff-spice: compared {d} module text bytes, {d} modules, {d} refusals, {d} .hdl names, {d} file requests\n", .{ cov.bytes, cov.modules, cov.refusals, cov.hdl, cov.requests });
    try std.testing.expect(from_disk > 900);
    try std.testing.expectEqual(@as(usize, 0), bad);
}
