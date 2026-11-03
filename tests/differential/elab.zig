//! The differential oracle of `sema`'s elaboration (docs/rewrite/elab.md):
//! every `.va`, `.vams` and `.v` fixture under the fixture root in, one line
//! per disagreement with the old elaborators out, and a failure unless each
//! disagreeing fixture is named in `elab.xfail` (and each named one still
//! disagrees). The old preprocessor makes both sides' text, as in
//! diff-astgen. Checks, in order:
//! - codes (`.va`/`.vams`): the set of codes the old `elab.elaborate` adds
//!   to its bag equals the set in `Zcu.failed` plus the per-file codes of
//!   `Vir.diag` the old elaboration owns (`elab_codes`: AstGen judges a few
//!   of its rules alone, E0373 and E0376);
//! - tree: when the old side elaborates, every instance's hierarchical path
//!   and module name, in order (`.va`/`.vams`: `Design.units`, one root; `.v`:
//!   the instance scopes of `sim.digital.elaborate`'s `Run.hier`, every root,
//!   compared as sorted sets: its scope ids follow its declaration pass, not
//!   the depth-first order);
//! - determinism: elaborating a fixture twice gives the same tree and codes.
//! A fixture the old front end refuses (preprocess, parse, the §3.7 and
//! §8.1.1 rules) or the new parser refuses is skipped and counted; a `.v`
//! the old digital route refuses is compared on nothing and counted.
//! Not yet compared (elab.md checks 2-4): folded parameter values, net
//! disciplines and connect-module inserts.
//! No LRM clause: this checks VerA's rewrite against VerA.
//!
//! Contents: tests only.

const std = @import("std");
const Io = std.Io;
const vams = @import("vams");
const sema = @import("sema");
const frontend = @import("frontend");
const diag = @import("diag");
const elab = @import("elab");
const sim = @import("sim");
const options = @import("rewrite_options");
const Zcu = sema.Zcu;
const Sema = sema.Sema;

/// Every code the old `src/elab` reports: the codes this oracle compares.
const elab_codes = [_][]const u8{ "E0235", "E0237", "E0239", "E0247", "E0337", "E0347", "E0355", "E0358", "E0363", "E0371", "E0373", "E0375", "E0376", "E0501", "E0816", "E0890", "E0901", "E0902", "E0903", "E0904", "E0905", "E0906", "E0907", "E0908", "E0909", "E0911", "E0914", "E0915", "E0916", "E0917", "E0921", "E0922", "E0923", "E0927", "E0929", "E0952", "E0982", "E0997", "W0252", "W0950", "W0951", "W1152" };

const Tally = struct {
    compared: u32 = 0,
    trees: u32 = 0,
    skipped_old: u32 = 0,
    skipped_new: u32 = 0,
    digital_refused: u32 = 0,
    agreed: u32 = 0,
    xfailed: u32 = 0,
    failed: u32 = 0,
};

/// What one fixture gave: skipped, or a verdict (null when every check
/// agrees, else the first disagreement) and whether a tree was compared.
const Outcome = union(enum) { old_refused, new_refused, verdict: struct { why: ?[]const u8, tree: bool, digital_refused: bool = false } };

/// One side's answer: the tree as `path module` lines, the codes as a
/// sorted, deduplicated list; `tree` is null when that side has none.
const Side = struct { tree: ?[]const []const u8, codes: []const []const u8 };

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

    const xfail_path = try std.fs.path.join(arena, &.{ options.repo_root, "tests/differential/elab.xfail" });
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
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var per: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer per.deinit();
    for (fixtures) |rel| {
        _ = per.reset(.retain_capacity);
        const v = switch (try checkFixture(per.allocator(), io, rel)) {
            .old_refused => {
                tally.skipped_old += 1;
                continue;
            },
            .new_refused => {
                tally.skipped_new += 1;
                continue;
            },
            .verdict => |v| v,
        };
        tally.compared += 1;
        tally.trees += @intFromBool(v.tree);
        tally.digital_refused += @intFromBool(v.digital_refused);
        const listed = xfail.get(rel) != null;
        if (listed) try seen.put(arena, rel, {});
        if (v.why) |why| {
            if (listed) {
                tally.xfailed += 1;
            } else {
                tally.failed += 1;
                try out.writer.print("FAIL {s}: {s}\n", .{ rel, why });
            }
        } else if (listed) {
            tally.failed += 1;
            try out.writer.print("XPASS {s}: agrees now; delete its elab.xfail line\n", .{rel});
        } else tally.agreed += 1;
    }
    var it = xfail.keyIterator();
    while (it.next()) |k| if (!seen.contains(k.*)) {
        tally.failed += 1;
        try out.writer.print("STALE {s}: elab.xfail names a fixture that was not compared\n", .{k.*});
    };
    std.debug.print("{s}diff-elab: {d} fixtures compared ({d} trees), {d} agree, {d} listed in elab.xfail, {d} skipped (old front end refused), {d} skipped (new parser refused), {d} .v the old digital route refused, {d} failures\n", .{ out.written(), tally.compared, tally.trees, tally.agreed, tally.xfailed, tally.skipped_old, tally.skipped_new, tally.digital_refused, tally.failed });
    if (tally.failed != 0) return error.DiffElabFailed;
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
    std.mem.sort([]const u8, list.items, {}, lessThan);
    return list.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn checkFixture(arena: std.mem.Allocator, io: Io, rel: []const u8) !Outcome {
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
        error.PreprocessFailed => return .old_refused,
    };
    const text = try arena.dupeSentinel(u8, pp.text, 0);
    const builtins: u32 = if (digital) 0 else frontend.annex_e.spice_module_count + pp.netlist_modules;
    const old: Side = if (digital) (try oldDigital(arena, source, path, &.{ dir, include })) orelse blk: {
        // Compared on nothing, but the new side must still elaborate.
        break :blk .{ .tree = null, .codes = &.{} };
    } else (try oldAnalog(arena, pp, bag)) orelse return .old_refused;
    const new = (try newSide(arena, path, text, digital, builtins)) orelse return .new_refused;
    const again = (try newSide(arena, path, text, digital, builtins)).?;
    const refused = digital and old.tree == null;
    if (!sameLines(new.codes, again.codes) or !sameLines(new.tree.?, again.tree.?))
        return .{ .verdict = .{ .why = "determinism: two elaborations differ", .tree = false, .digital_refused = refused } };
    if (!digital and !sameLines(old.codes, new.codes))
        return .{ .verdict = .{ .why = try arena.print("codes: old {s}, new {s}", .{ try join(arena, old.codes), try join(arena, new.codes) }), .tree = false } };
    const want = old.tree orelse return .{ .verdict = .{ .why = null, .tree = false, .digital_refused = refused } };
    var got = new.tree.?;
    if (digital) {
        const sorted = try arena.dupe([]const u8, got);
        std.mem.sort([]const u8, sorted, {}, lessThan);
        got = sorted;
    }
    return .{ .verdict = .{ .why = try treeDiffer(arena, want, got), .tree = true } };
}

/// The old analog route up to `elab.elaborate`, as `Compilation/analyze.zig`
/// runs it: null when a stage before elaboration refuses the source.
fn oldAnalog(arena: std.mem.Allocator, pp: frontend.preprocessor.Output, bag: *diag.Bag) !?Side {
    const std_defs = true;
    var tokens = try frontend.lexer.tokenize(arena, pp.text, try frontend.prelude.preludeTokens(std_defs));
    const starts = tokens.items(.start);
    const seed = try frontend.prelude.preludeAst(std_defs);
    var p = try frontend.Parser.Parser.initSeeded(arena, pp.text, tokens.items(.tag), starts, bag, seed);
    p.setLanguage(frontend.keyword.default_keyword_set);
    const builtins: u32 = frontend.annex_e.spice_module_count + pp.netlist_modules;
    const parse = try arena.create(frontend.Ast.SourceFile);
    parse.* = p.parseSourceFile() catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.ParseError => return null,
    };
    for (parse.udps) |u| if (u.outputs != 1 or u.ports.len == 0 or u.output != u.ports[0]) return null;
    if (bag.failed()) return null;
    const file = try arena.create(frontend.Ast.SourceFile);
    file.* = @as(*const frontend.Ast.SourceFile, parse).overlay(.{
        .builtin_modules = builtins,
        .builtin_natures = if (seed) |sd| @intCast(sd.file.natures.len) else 0,
        .annex_d_included = pp.annex_d_included,
        .netlist_modules = pp.netlist_modules,
        .netlist_unsupported = pp.netlist_unsupported,
    });
    try elab.spiceCase(arena, file);
    try frontend.wreal.check(file, starts, bag);
    if (bag.failed()) return null;
    const before = bag.count();
    const design: ?elab.Design = elab.elaborate(.{
        .arena = arena,
        .file = file,
        .src = pp.text,
        .tok_starts = starts,
        .bag = bag,
        .default_disciplines = pp.directives.disciplines,
    }) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.NoModule, error.DiagnosticsReported => null,
    };
    var codes: std.ArrayList([]const u8) = .empty;
    for (before..bag.count()) |k| try codes.append(arena, @tagName(bag.at(k).code));
    const d = design orelse return .{ .tree = null, .codes = try setOf(arena, codes.items) };
    var tree: std.ArrayList([]const u8) = .empty;
    const top = file.str(d.top.name);
    if (d.units.len == 0) {
        try tree.append(arena, try arena.print("{s} {s}", .{ top, top }));
    } else for (d.units.items(.path), d.units.items(.module)) |path, m| {
        const p_trim = if (path.len != 0) path[0 .. path.len - 1] else path;
        try tree.append(arena, try arena.print("{s}{s}{s} {s}", .{ top, if (path.len != 0) "." else "", p_trim, file.str(m) }));
    }
    return .{ .tree = tree.items, .codes = try setOf(arena, codes.items) };
}

/// The old digital route's elaboration: its instance scopes, sorted; null
/// when it refuses the source.
fn oldDigital(arena: std.mem.Allocator, source: []const u8, path: []const u8, include_dirs: []const []const u8) !?Side {
    const bag = try arena.create(diag.Bag);
    bag.* = .init(arena);
    var sink: Io.Writer.Allocating = .init(arena);
    const r = sim.digital.elaborate(arena, source, .{ .file_name = path, .include_dirs = include_dirs }, bag, &sink.writer) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.DigitalFailed, error.WriteFailed => return null,
    };
    const scopes = r.hier.scopes.items;
    var tree: std.ArrayList([]const u8) = .empty;
    for (scopes, 0..) |sc, s| {
        if (sc.lexical) continue;
        var segs: std.ArrayList([]const u8) = .empty;
        var at: usize = s;
        // Up to the root, whose parent is itself: bounded by the scope count.
        for (0..scopes.len + 1) |_| {
            const row = scopes[at];
            const name = r.file.str(row.name);
            try segs.append(arena, if (row.index) |k| try arena.print("{s}[{d}]", .{ name, k }) else name);
            if (row.parent == at) break;
            at = row.parent;
        }
        std.mem.reverse([]const u8, segs.items);
        const module = r.file.str(r.file.modules[sc.def].name);
        try tree.append(arena, try arena.print("{s} {s}", .{ try std.mem.join(arena, ".", segs.items), module }));
    }
    std.mem.sort([]const u8, tree.items, {}, lessThan);
    return .{ .tree = tree.items, .codes = &.{} };
}

/// The new side: parse, AstGen, elaborate. Null when the new parser
/// refuses the text.
fn newSide(arena: std.mem.Allocator, path: []const u8, text: [:0]const u8, digital: bool, builtins: u32) !?Side {
    const gpa = std.heap.smp_allocator;
    var tree = try vams.Ast.parse(gpa, text, .{ .keywords = if (digital) .v1364_2005 else .vams_2023 });
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return null;
    var vir = try vams.AstGen.generate(gpa, &tree, .{});
    defer vir.deinit(gpa);
    var zcu: Zcu = try .init(gpa);
    defer zcu.deinit();
    var modules: u32 = 0;
    for (vir.decls()) |d| modules += @intFromBool(d.kind == .module);
    _ = try zcu.addFile(path, vir, @min(builtins, modules));
    try Sema.elaborate(&zcu, .{ .roots = if (digital) .all else .first });
    var lines: std.ArrayList([]const u8) = .empty;
    for (0..zcu.instances.len) |k| {
        const d = zcu.instances.items(.module)[k];
        try lines.append(arena, try arena.print("{f} {s}", .{ zcu.fmtPath(@fromBackingInt(@intCast(k))), zcu.fileVir(d.file).string(zcu.declRow(d).name) }));
    }
    var codes: std.ArrayList([]const u8) = .empty;
    for (zcu.failed.items(.code)) |c| try codes.append(arena, @tagName(c));
    for (vir.diag.messages()) |m| {
        const name = @tagName(vir.diag.message(m).tag.code);
        for (elab_codes) |c| if (std.mem.eql(u8, c, name)) try codes.append(arena, name);
    }
    return .{ .tree = lines.items, .codes = try setOf(arena, codes.items) };
}

fn setOf(arena: std.mem.Allocator, codes: []const []const u8) ![]const []const u8 {
    const sorted = try arena.dupe([]const u8, codes);
    std.mem.sort([]const u8, sorted, {}, lessThan);
    var n: usize = 0;
    for (sorted) |c| {
        if (n != 0 and std.mem.eql(u8, sorted[n - 1], c)) continue;
        sorted[n] = c;
        n += 1;
    }
    return sorted[0..n];
}

fn sameLines(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn join(arena: std.mem.Allocator, codes: []const []const u8) ![]const u8 {
    return if (codes.len == 0) "{}" else std.mem.join(arena, ",", codes);
}

/// The first line where the trees differ, or null.
fn treeDiffer(arena: std.mem.Allocator, old: []const []const u8, new: []const []const u8) !?[]const u8 {
    for (0..@max(old.len, new.len)) |k| {
        const o = if (k < old.len) old[k] else "(none)";
        const n = if (k < new.len) new[k] else "(none)";
        if (!std.mem.eql(u8, o, n)) return try arena.print("tree row {d}: old `{s}`, new `{s}` ({d} old rows, {d} new)", .{ k, o, n, old.len, new.len });
    }
    return null;
}

test "diff-elab: sema's elaboration agrees with the old elaborators on every fixture" {
    var result: anyerror!void = {};
    // The old elaborators recurse with the tree; Compilation's workers run
    // on a 256 MiB stack.
    const t = try std.Thread.spawn(.{ .stack_size = 256 << 20 }, run, .{&result});
    t.join();
    try result;
}
