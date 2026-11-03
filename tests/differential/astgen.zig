//! The differential oracle of `vams` AstGen and Vir (docs/rewrite/astgen.md):
//! every `.va`, `.vams` and `.v` fixture under the fixture root in, one line
//! per disagreement with the old compiler out, and a failure unless each
//! disagreeing fixture is named in `astgen.xfail` (and each named one still
//! disagrees). The old preprocessor makes the new side's text, as in
//! diff-parse; a fixture it refuses, or the new parser refuses, is skipped
//! and counted. Checks, in order:
//! - codes: the set of per-file codes (`per_file`) the old compiler reports
//!   (`vera.analyze` on a `.va`/`.vams`; on a `.v`, which `analyze` does
//!   not compile, the digital route's parse stage: the old parser under
//!   `vera`'s default set and the §3.7 wreal rule, plus the analysis
//!   spine's §8.1.1 UDP rule) equals the set in `Vir.diag`;
//! - declarations: Vir's declaration table, per kind in order, names the
//!   design units of the old `Ast.SourceFile`, past the old prelude's
//!   built-in modules;
//! - determinism: generating a fixture twice gives the same Vir bytes, and
//!   the corpus on 1 and on `threads` workers gives the same bytes per file.
//! No LRM clause: this checks VerA's rewrite against VerA.
//!
//! Contents: tests only.

const std = @import("std");
const Io = std.Io;
const vams = @import("vams");
const frontend = @import("frontend");
const diag = @import("diag");
const vera = @import("vera");
const options = @import("rewrite_options");
const Vir = vams.Vir;

/// The codes a file can judge alone: AstGen's, the rest stay Sema's.
const per_file = [_][]const u8{ "E0206", "E0218", "E0225", "E0230", "E0238", "E0245", "E0248", "E0295", "E0373", "E0376", "E0918", "E1100" };

/// Workers of the N-thread determinism pass (the machine is shared: `-j4`).
const threads = 4;

/// One fixture's verdict: null when every check agrees, else the first
/// disagreement.
const Verdict = ?[]const u8;

const Tally = struct {
    compared: u32 = 0,
    skipped_pp: u32 = 0,
    skipped_parse: u32 = 0,
    agreed: u32 = 0,
    xfailed: u32 = 0,
    failed: u32 = 0,
};

/// A fixture the N-thread pass regenerates: its text, language and the
/// 1-thread pass's hash.
const Job = struct { text: [:0]const u8, digital: bool, hash: u64 };

/// What one fixture gave: skipped, or a verdict.
const Outcome = union(enum) { pp_refused, parse_refused, verdict: Verdict };

// ---- private ----

fn run(result: *anyerror!void) void {
    result.* = runAll();
}

fn runAll() !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const xfail_path = try std.fs.path.join(arena, &.{ options.repo_root, "tests/differential/astgen.xfail" });
    const xfail_text = try Io.Dir.cwd().readFileAlloc(io, xfail_path, arena, .limited(1 << 20));
    var xfail: std.StringHashMapUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, xfail_text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.findScalar(u8, line, ' ') orelse return error.XfailLineHasNoReason;
        try xfail.put(arena, line[0..sp], line[sp + 1 ..]);
    }

    const fixtures = try collect(arena, io);
    var tally: Tally = .{};
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var jobs: std.ArrayList(Job) = .empty;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var per: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer per.deinit();
    for (fixtures) |rel| {
        _ = per.reset(.retain_capacity);
        const outcome = try checkFixture(per.allocator(), arena, io, rel, &jobs);
        const verdict = switch (outcome) {
            .pp_refused => {
                tally.skipped_pp += 1;
                continue;
            },
            .parse_refused => {
                tally.skipped_parse += 1;
                continue;
            },
            .verdict => |v| v,
        };
        tally.compared += 1;
        const listed = xfail.get(rel) != null;
        if (listed) try seen.put(arena, rel, {});
        if (verdict) |why| {
            if (listed) {
                tally.xfailed += 1;
            } else {
                tally.failed += 1;
                try out.writer.print("FAIL {s}: {s}\n", .{ rel, why });
            }
        } else if (listed) {
            tally.failed += 1;
            try out.writer.print("XPASS {s}: agrees now; delete its astgen.xfail line\n", .{rel});
        } else tally.agreed += 1;
    }
    var it = xfail.keyIterator();
    while (it.next()) |k| if (!seen.contains(k.*)) {
        tally.failed += 1;
        try out.writer.print("STALE {s}: astgen.xfail names a fixture that was not compared\n", .{k.*});
    };
    const differ = try threaded(jobs.items);
    if (differ != 0) {
        tally.failed += 1;
        try out.writer.print("FAIL determinism: {d} fixtures give other bytes on {d} threads than on 1\n", .{ differ, threads });
    }
    std.debug.print("{s}diff-astgen: {d} fixtures compared, {d} agree, {d} listed in astgen.xfail, {d} skipped (old preprocessor refused), {d} skipped (new parser refused), {d} regenerated on {d} threads, {d} failures\n", .{ out.written(), tally.compared, tally.agreed, tally.xfailed, tally.skipped_pp, tally.skipped_parse, jobs.items.len, threads, tally.failed });
    if (tally.failed != 0) return error.DiffAstGenFailed;
}

/// Every fixture path relative to the fixture root, sorted.
fn collect(arena: std.mem.Allocator, io: Io) ![]const []const u8 {
    var dir = try Io.Dir.cwd().openDir(io, options.fixture_root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var list: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.path);
        if (!std.mem.eql(u8, ext, ".va") and !std.mem.eql(u8, ext, ".vams") and !std.mem.eql(u8, ext, ".v")) continue;
        try list.append(arena, try arena.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return list.items;
}

/// Compares one fixture; a fixture both sides parse is queued in `jobs`
/// (its text on `keep`) for the N-thread pass.
fn checkFixture(arena: std.mem.Allocator, keep: std.mem.Allocator, io: Io, rel: []const u8, jobs: *std.ArrayList(Job)) !Outcome {
    const gpa = std.heap.smp_allocator;
    const path = try std.fs.path.join(arena, &.{ options.fixture_root, rel });
    const dir = std.fs.path.dirname(path).?;
    const include = options.fixture_root ++ "/include";
    const digital = std.mem.eql(u8, std.fs.path.extension(rel), ".v");
    const source = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 26));
    const bag = try arena.create(diag.Bag);
    bag.* = .init(arena);
    var files: frontend.Files = .init(io, arena);
    const pp = frontend.preprocessor.process(arena, source, .{
        .include_dirs = &.{ dir, include },
        .file_name = path,
        .std_defs = !digital,
        .spice_primitives = !digital,
        .bag = bag,
        .files = &files,
    }) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.PreprocessFailed => return .pp_refused,
    };
    const text = try keep.dupeSentinel(u8, pp.text, 0);

    // The new side.
    var tree = try vams.Ast.parse(gpa, text, .{ .keywords = if (digital) .v1364_2005 else .vams_2023 });
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return .parse_refused;
    var vir = try vams.AstGen.generate(gpa, &tree, .{});
    defer vir.deinit(gpa);
    const bytes = try virBytes(arena, &vir);
    {
        var again = try vams.AstGen.generate(gpa, &tree, .{});
        defer again.deinit(gpa);
        if (!std.mem.eql(u8, bytes, try virBytes(arena, &again))) return .{ .verdict = "determinism: two generations of one tree differ" };
    }
    try jobs.append(keep, .{ .text = text, .digital = digital, .hash = std.hash.Wyhash.hash(0, bytes) });
    var new_codes: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (vir.diag.messages()) |m| try new_codes.put(arena, @tagName(vir.diag.message(m).tag.code), {});

    // The old side: its parse, for the declarations and a `.v`'s codes, as
    // the digital route parses (`vera` reads a `.v` under its default set).
    var old_tokens = try frontend.lexer.tokenize(arena, text, null);
    const parse_bag = try arena.create(diag.Bag);
    parse_bag.* = .init(arena);
    var p = frontend.Parser.Parser.init(arena, text, old_tokens.items(.tag), old_tokens.items(.start), parse_bag);
    p.digital = digital;
    p.setLanguage(.vams_2023);
    const old_file = p.parseSourceFile() catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.ParseError => null,
    };
    var old_codes: std.StringArrayHashMapUnmanaged(void) = .empty;
    if (digital) {
        // The digital route's parse stage (`elab_stages.parse`): the parse,
        // then the §3.7 wreal rule on what it recovered.
        try frontend.wreal.check(&(old_file orelse p.file), old_tokens.items(.start), parse_bag);
        try keepCodes(arena, &old_codes, parse_bag);
        // The analysis spine's IEEE 1364-2005 §8.1.1 rule on every UDP.
        if (old_file) |f| for (f.udps) |u| if (u.outputs != 1 or u.ports.len == 0 or u.output != u.ports[0]) try old_codes.put(arena, "E1100", {});
    } else {
        var analyze_bag: diag.Bag = .init(gpa);
        defer analyze_bag.deinit(gpa);
        if (vera.analyze(gpa, source, .{ .file_name = rel, .include_dirs = &.{ dir, include } }, &analyze_bag)) |res| {
            var r = res;
            r.deinit(gpa);
        } else |e| switch (e) {
            error.OutOfMemory => return e,
            error.CompileFailed, error.NoModule, error.NothingToElaborate => {},
        }
        try keepCodes(arena, &old_codes, &analyze_bag);
    }
    if (try codesDiffer(arena, &old_codes, &new_codes)) |why| return .{ .verdict = why };
    const file = old_file orelse return .{ .verdict = null };
    const builtins: u32 = if (digital) 0 else frontend.annex_e.spice_module_count + pp.netlist_modules;
    return .{ .verdict = try declsDiffer(arena, &file, builtins, &vir) };
}

/// The per-file codes among `bag`'s rows.
fn keepCodes(arena: std.mem.Allocator, set: *std.StringArrayHashMapUnmanaged(void), bag: *const diag.Bag) !void {
    for (0..bag.count()) |i| {
        const name = @tagName(bag.at(i).code);
        for (per_file) |c| if (std.mem.eql(u8, c, name)) try set.put(arena, c, {});
    }
}

fn codesDiffer(arena: std.mem.Allocator, old: *const std.StringArrayHashMapUnmanaged(void), new: *const std.StringArrayHashMapUnmanaged(void)) !Verdict {
    var same = old.count() == new.count();
    for (old.keys()) |k| same = same and new.contains(k);
    if (same) return null;
    return try arena.print("codes: old {s}, new {s}", .{ try setText(arena, old), try setText(arena, new) });
}

fn setText(arena: std.mem.Allocator, set: *const std.StringArrayHashMapUnmanaged(void)) ![]const u8 {
    const keys = try arena.dupe([]const u8, set.keys());
    std.mem.sort([]const u8, keys, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return if (keys.len == 0) "{}" else try std.mem.join(arena, ",", keys);
}

/// The declaration table against the old file's lists, per kind in order.
fn declsDiffer(arena: std.mem.Allocator, file: *const frontend.Ast.SourceFile, builtins: u32, vir: *const Vir) !Verdict {
    const Kind = Vir.Decl.Kind;
    var olds: std.ArrayList([]const u8) = .empty;
    var news: std.ArrayList([]const u8) = .empty;
    const groups = .{
        .{ "modules", &[_]Kind{ .module, .macromodule, .connectmodule } },
        .{ "natures", &[_]Kind{.nature} },
        .{ "disciplines", &[_]Kind{.discipline} },
        .{ "paramsets", &[_]Kind{.paramset} },
        .{ "udps", &[_]Kind{.primitive} },
        .{ "connectrules", &[_]Kind{.connectrules} },
        .{ "configs", &[_]Kind{.config} },
    };
    inline for (groups) |g| {
        olds.clearRetainingCapacity();
        news.clearRetainingCapacity();
        const list = @field(file, g[0]);
        const skip: usize = if (comptime std.mem.eql(u8, g[0], "modules")) builtins else 0;
        for (list[@min(skip, list.len)..]) |d| try olds.append(arena, file.str(d.name));
        var k: usize = 0;
        for (vir.decls()) |d| if (std.mem.findScalar(Kind, g[1], d.kind) != null) {
            if (k >= skip) try news.append(arena, try normal(arena, vir.string(d.name)));
            k += 1;
        };
        if (olds.items.len != news.items.len) return try arena.print("declarations: {d} {s} old, {d} new", .{ olds.items.len, g[0], news.items.len });
        for (olds.items, news.items) |o, n| if (!std.mem.eql(u8, o, n)) return try arena.print("declarations: {s} `{s}` old, `{s}` new", .{ g[0], o, n });
    }
    return null;
}

/// A name as the old parser interned it: an escaped identifier's `.` a space.
fn normal(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, name);
    std.mem.replaceScalar(u8, out, '.', ' ');
    return out;
}

/// Every byte of a Vir: the tags, `extra`, `string_bytes`, and the dump,
/// which reads every `Data` through its tag (a `Data` row's own bytes
/// carry a safety tag and padding in safe builds).
fn virBytes(arena: std.mem.Allocator, vir: *const Vir) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll(std.mem.sliceAsBytes(vir.instructions.items(.tag)));
    try out.writer.writeAll(std.mem.sliceAsBytes(vir.extra));
    try out.writer.writeAll(vir.string_bytes);
    try Vir.print.render(vir, &out.writer);
    return out.written();
}

/// Regenerates every job on `threads` workers; returns how many hash
/// differently than on one thread.
fn threaded(jobs: []const Job) !u32 {
    var next: std.atomic.Value(usize) = .init(0);
    var differ: std.atomic.Value(u32) = .init(0);
    var failure: std.atomic.Value(bool) = .init(false);
    var workers: [threads]std.Thread = undefined;
    for (&workers) |*w| w.* = try std.Thread.spawn(.{ .stack_size = 256 << 20 }, worker, .{ jobs, &next, &differ, &failure });
    for (workers) |w| w.join();
    if (failure.load(.monotonic)) return error.OutOfMemory;
    return differ.load(.monotonic);
}

fn worker(jobs: []const Job, next: *std.atomic.Value(usize), differ: *std.atomic.Value(u32), failure: *std.atomic.Value(bool)) void {
    const gpa = std.heap.smp_allocator;
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    while (true) {
        const i = next.fetchAdd(1, .monotonic);
        if (i >= jobs.len) return;
        _ = arena_state.reset(.retain_capacity);
        const same = regenerate(gpa, arena_state.allocator(), jobs[i]) catch {
            failure.store(true, .monotonic);
            return;
        };
        if (!same) _ = differ.fetchAdd(1, .monotonic);
    }
}

fn regenerate(gpa: std.mem.Allocator, arena: std.mem.Allocator, job: Job) !bool {
    var tree = try vams.Ast.parse(gpa, job.text, .{ .keywords = if (job.digital) .v1364_2005 else .vams_2023 });
    defer tree.deinit(gpa);
    var vir = try vams.AstGen.generate(gpa, &tree, .{});
    defer vir.deinit(gpa);
    return std.hash.Wyhash.hash(0, try virBytes(arena, &vir)) == job.hash;
}

test "diff-astgen: vams AstGen agrees with the old compiler's per-file codes and design units on every fixture" {
    var result: anyerror!void = {};
    // Compilation's workers run on a 256 MiB stack; AstGen recurses with
    // the tree, which the parser caps.
    const t = try std.Thread.spawn(.{ .stack_size = 256 << 20 }, run, .{&result});
    t.join();
    try result;
}
