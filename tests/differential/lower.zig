//! The differential oracle of Sema's analog lowering (docs/rewrite/lower.md):
//! every `.va` and `.vams` fixture under the fixture root in, one line per
//! disagreement with the old lowering (`src/analog`'s `Lower.lower`) out,
//! and a failure unless each disagreeing fixture is named in `lower.xfail`
//! (and each named one still disagrees). The old preprocessor makes both
//! sides' text, as in diff-elab. Checks, in order:
//! - codes: the set of codes the old `Lower.lower` adds to its bag, less
//!   elaboration's (`elab_codes`, diff-elab's), equals the set the new side
//!   raises (`Vir.diag`, `Zcu.failed` after elaboration and `Sema.analyze`)
//!   less the same codes;
//! - tables: when both lower, the unknowns (name, kind, order), the
//!   parameters (name, type, local, folded default, ranges), the named
//!   branches the contributions target, the contributions (access, kind,
//!   branch, terminals), and the counts of charge sites, held variables,
//!   limit slots and displays, row for row, rendered as text lines;
//! - values: when the tables agree, `points` seeded points per fixture
//!   (every unknown a value in [-2, 2], every real parameter with a folded
//!   default a value inside its ranges near the default): each
//!   contribution's resistive and reactive sum, and each display row's
//!   operands at its last run, by the old MIR interpreter
//!   (`src/codegen/verilog/Interp.zig`, over `opcode.fold`) and by
//!   `Air.interp`, bit for bit, NaN as NaN. A root the old interpreter
//!   refuses (a call it does not model, an event, an array) is skipped and
//!   counted, never compared.
//! The old tables are read as the new side writes them: the rows of an
//! instance `elab.rulings` `drops` (an unselected generate arm, §6.6.2)
//! are left out, and an array's per-element held rows (`held x[0]`) are
//! the one row `held x`.
//! A codes or tables disagreement the LRM settles for the new side is a
//! line of `lower.rulings` (`settle.Rulings`), whose expected result is
//! the new side's codes, comma-separated, or its tables' difference:
//! `-<old row>` and `+<new row>`, joined by `; `.
//! A fixture the old front end refuses (preprocess, parse, the §3.7 and
//! §8.1.1 rules) or the new parser refuses is skipped and counted.
//! `zig build diff-lower -Dlower-dump='<substring>|<substring>'` prints both
//! sides' tables of the fixtures whose path holds one of them.
//! No LRM clause: this checks VerA's rewrite against VerA.
//!
//! Contents:
//! - `pub const Verdict` (lower/values.zig fills it)

const std = @import("std");
const Io = std.Io;
const vams = @import("vams");
const sema = @import("sema");
const Air = @import("air");
const InternPool = @import("intern_pool");
const frontend = @import("frontend");
const diag = @import("diag");
const elab = @import("elab");
const analog = @import("analog");
const ir = @import("ir");
const OldInterp = @import("old_interp");
const options = @import("rewrite_options");
const Zcu = sema.Zcu;
const Sema = sema.Sema;
const Mir = ir.Mir;
const Lowered = ir.Lowered;
const Device = Air.Device;
const values = @import("lower/values.zig");
const tables = @import("lower/tables.zig");
const settle = @import("settle.zig");
/// The codes elaboration owns (`stages.zig`): diff-elab compares them, so
/// this oracle leaves them out and demands every other.
const elab_codes = @import("stages.zig").elab_codes;

/// One fixture's verdict: null `why` when every check agrees.
pub const Verdict = struct { why: ?[]const u8, tables: bool = false, roots: u32 = 0, values: u64 = 0, values_libm: u64 = 0, skipped: u32 = 0, old_bugs: u32 = 0 };

const Tally = struct {
    compared: u32 = 0,
    tables: u32 = 0,
    roots: u32 = 0,
    values: u64 = 0,
    values_libm: u64 = 0,
    old_bugs: u32 = 0,
    old_bug_fixtures: u32 = 0,
    roots_skipped: u32 = 0,
    skipped_old: u32 = 0,
    skipped_new: u32 = 0,
    agreed: u32 = 0,
    ruled: u32 = 0,
    xfailed: u32 = 0,
    failed: u32 = 0,
};

const Outcome = union(enum) { old_refused, new_refused, ruled, verdict: Verdict };

/// The old side: its codes, and its tables when it lowered.
/// The old side: its codes, and its tables when it lowered; and the
/// source file of each nature and discipline declaration, in order, 0 for
/// the prelude's (`Zcu.File.decl_files`).
const Old = struct { codes: []const []const u8, lw: ?*Lowered, mir: *Mir, nature_files: []const u32, disc_files: []const u32, annex_d_included: bool };

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

    const xfail_path = try std.fs.path.join(arena, &.{ options.repo_root, "tests/differential/lower.xfail" });
    const xfail_text = try Io.Dir.cwd().readFileAlloc(io, xfail_path, arena, .limited(1 << 22));
    var xfail: std.StringHashMapUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, xfail_text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.findScalar(u8, line, ' ') orelse return error.XfailLineHasNoReason;
        try xfail.put(arena, line[0..sp], line[sp + 1 ..]);
    }
    const dump = options.lower_dump;
    var rulings = try settle.Rulings.read(arena, io, options.repo_root, "lower");
    const drops = try elabDrops(arena, io);

    const fixtures = try collect(arena, io);
    var tally: Tally = .{};
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var per: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer per.deinit();
    for (fixtures) |rel| {
        _ = per.reset(.retain_capacity);
        const show = dumped(rel, dump);
        const v = switch (try checkFixture(per.allocator(), io, rel, show, &rulings, drops.get(rel) orelse &.{})) {
            .old_refused => {
                tally.skipped_old += 1;
                continue;
            },
            .new_refused => {
                tally.skipped_new += 1;
                continue;
            },
            .ruled => {
                tally.compared += 1;
                tally.ruled += 1;
                if (xfail.get(rel) != null) {
                    try seen.put(arena, rel, {});
                    tally.failed += 1;
                    try out.writer.print("XPASS {s}: settled by lower.rulings; delete its lower.xfail line\n", .{rel});
                }
                continue;
            },
            .verdict => |v| v,
        };
        tally.compared += 1;
        tally.tables += @intFromBool(v.tables);
        tally.roots += v.roots;
        tally.values += v.values;
        tally.values_libm += v.values_libm;
        tally.old_bugs += v.old_bugs;
        tally.old_bug_fixtures += @intFromBool(v.old_bugs != 0);
        if (v.old_bugs != 0) try out.writer.print("OLD-BUG {s}: {d} display operands the old side computes wrong (values.zig rulings)\n", .{ rel, v.old_bugs });
        tally.roots_skipped += v.skipped;
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
            try out.writer.print("XPASS {s}: agrees now; delete its lower.xfail line\n", .{rel});
        } else tally.agreed += 1;
    }
    var it = xfail.keyIterator();
    while (it.next()) |k| if (!seen.contains(k.*)) {
        tally.failed += 1;
        try out.writer.print("STALE {s}: lower.xfail names a fixture that was not compared\n", .{k.*});
    };
    tally.failed += try rulings.finish(&out.writer);
    std.debug.print("{s}diff-lower: {d} fixtures compared ({d} with agreeing tables; {d} roots, {d} values equal bit for bit, {d} within the libm ulp bound, {d} roots the old interpreter refused, {d} display operands an old-side bug in {d} fixtures), {d} agree ({d} by a ruling), {d} listed in lower.xfail, {d} skipped (old front end refused), {d} skipped (new parser refused), {d} failures\n", .{ out.written(), tally.compared, tally.tables, tally.roots, tally.values, tally.values_libm, tally.roots_skipped, tally.old_bugs, tally.old_bug_fixtures, tally.agreed + tally.ruled, tally.ruled, tally.xfailed, tally.skipped_old, tally.skipped_new, tally.failed });
    if (tally.failed != 0) return error.DiffLowerFailed;
}

/// Every `.va`/`.vams` fixture path relative to the fixture root, sorted.
fn collect(arena: std.mem.Allocator, io: Io) ![]const []const u8 {
    var dir = try Io.Dir.cwd().openDir(io, options.fixture_root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var list: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.path);
        if (!std.mem.eql(u8, ext, ".va") and !std.mem.eql(u8, ext, ".vams")) continue;
        try list.append(arena, try arena.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, list.items, {}, lessThan);
    return list.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Whether `-Dlower-dump`'s `|`-separated substrings name fixture `rel`.
fn dumped(rel: []const u8, dump: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, dump, '|');
    while (it.next()) |part| if (std.mem.find(u8, rel, part) != null) return true;
    return false;
}

/// `elab.rulings`' `drops` rows by fixture: the instance paths the new
/// tree omits, less the top module's segment, as the old rows name them.
fn elabDrops(arena: std.mem.Allocator, io: Io) !std.StringHashMapUnmanaged([]const []const u8) {
    const r = try settle.Rulings.read(arena, io, options.repo_root, "elab");
    var out: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    for (r.map.keys(), r.map.values()) |path, ruling| {
        const rest = std.mem.cutPrefix(u8, ruling.expected, "drops ") orelse continue;
        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, rest, ' ');
        while (it.next()) |inst| {
            const dot = std.mem.findScalar(u8, inst, '.') orelse return error.ElabDropNamesTheTop;
            try list.append(arena, inst[dot + 1 ..]);
        }
        try out.put(arena, path, list.items);
    }
    return out;
}

/// One fixture's verdict; a disagreement `rulings` settles is `.ruled`.
/// `dropped` are the instance paths elaboration's rulings drop.
fn checkFixture(arena: std.mem.Allocator, io: Io, rel: []const u8, show: bool, rulings: *settle.Rulings, dropped: []const []const u8) !Outcome {
    const path = try std.fs.path.join(arena, &.{ options.fixture_root, rel });
    const dir = std.fs.path.dirname(path).?;
    const include = options.fixture_root ++ "/include";
    const source = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 26));
    const bag = try arena.create(diag.Bag);
    bag.* = .init(arena);
    const files = try arena.create(frontend.Files);
    files.* = .init(io, arena);
    const pp = frontend.preprocessor.process(arena, source, .{
        .include_dirs = &.{ dir, include },
        .file_name = path,
        .std_defs = true,
        .spice_primitives = true,
        .bag = bag,
        .files = files,
    }) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.PreprocessFailed => return .old_refused,
    };
    const text = try arena.dupeSentinel(u8, pp.text, 0);
    const builtins: u32 = frontend.annex_e.spice_module_count + pp.netlist_modules;
    const old = (try oldSide(arena, pp, bag, &.{ dir, include }, files)) orelse return .old_refused;

    const gpa = std.heap.smp_allocator;
    var tree = try vams.Ast.parse(gpa, text, .{ .keywords = .vams_2023 });
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return .new_refused;
    // The old preprocessor's §10.2 events, as the new AstGen reads them.
    const defaults = try arena.alloc(vams.Preprocessor.events.DefaultDiscipline, pp.directives.disciplines.len);
    for (pp.directives.disciplines, defaults) |e, *d| d.* = .{
        .at = e.at,
        .qualifier = if (e.qualifier) |q| std.meta.stringToEnum(vams.Preprocessor.events.Qualifier, @tagName(q)).? else null,
        .discipline = e.discipline,
    };
    const E = vams.Preprocessor.events;
    const transitions = try arena.alloc(E.Region(?f64), pp.directives.transitions.len);
    for (pp.directives.transitions, transitions) |e, *d| d.* = .{ .at = e.at, .value = e.value };
    const timescales = try arena.alloc(E.Region(?E.Timescale), pp.directives.timescales.len);
    for (pp.directives.timescales, timescales) |e, *d| d.* = .{ .at = e.at, .value = if (e.value) |t| .{ .unit = t.unit, .precision = t.precision } else null };
    const nettypes = try arena.alloc(E.Region(E.NetType), pp.directives.nettypes.len);
    for (pp.directives.nettypes, nettypes) |e, *d| d.* = .{ .at = e.at, .value = std.meta.stringToEnum(E.NetType, @tagName(e.value)).? };
    const cells = try arena.alloc(E.Region(bool), pp.directives.cells.len);
    for (pp.directives.cells, cells) |e, *d| d.* = .{ .at = e.at, .value = e.value };
    const drives = try arena.alloc(E.Region(E.Drive), pp.directives.drives.len);
    for (pp.directives.drives, drives) |e, *d| d.* = .{ .at = e.at, .value = std.meta.stringToEnum(E.Drive, @tagName(e.value)).? };
    var vir = try vams.AstGen.generate(gpa, &tree, .{ .directives = .{ .disciplines = defaults, .transitions = transitions, .timescales = timescales, .nettypes = nettypes, .cells = cells, .drives = drives } });
    defer vir.deinit(gpa);
    var zcu: Zcu = try .init(gpa);
    defer zcu.deinit();
    var modules: u32 = 0;
    for (vir.decls()) |d| modules += @intFromBool(d.kind == .module);
    const file = try zcu.addFile(path, vir, @min(builtins, modules));
    zcu.files.items(.decl_files)[@backingInt(file)] = try declFiles(arena, &vir, old);
    zcu.files.items(.annex_d_included)[@backingInt(file)] = old.annex_d_included;
    try Sema.elaborate(&zcu, .{ .roots = .first });
    const elab_failed = hasError(&zcu, &vir);
    var analysis: ?Sema.Analysis = if (elab_failed or zcu.instances.len == 0) null else try Sema.analyze(&zcu);
    // A data file is answered as the old side reads one: each include
    // directory, then the name itself.
    while (zcu.data_want) |name| {
        const bytes: ?[]const u8 = for ([_][]const u8{ dir, include, "" }) |base| {
            const full = if (base.len == 0) name else try std.fs.path.join(arena, &.{ base, name });
            break Io.Dir.cwd().readFileAlloc(io, full, arena, .unlimited) catch continue;
        } else null;
        try zcu.answerData(bytes);
        analysis = try Sema.analyze(&zcu);
    }
    defer if (analysis) |*a| a.deinit(gpa);

    var codes: std.ArrayList([]const u8) = .empty;
    for (zcu.failed.items(.code)) |c| try codes.append(arena, @tagName(c));
    for (vir.diag.messages()) |m| try codes.append(arena, @tagName(vir.diag.message(m).tag.code));
    const new_codes = try lowerCodes(arena, codes.items);
    if (show) std.debug.print("== {s}\nold codes: {s}\nnew codes: {s}\n", .{ rel, try join(arena, old.codes), try join(arena, new_codes) });
    if (show) for (zcu.failed.items(.code), zcu.failed.items(.message)) |c, m| std.debug.print("  new {t}: {s}\n", .{ c, zcu.intern_pool.stringToSlice(m) });
    if (show and analysis == null) if (old.lw) |w| {
        std.debug.print("-- old tables (the new side refused)\n", .{});
        for (try tables.oldTables(arena, w, dropped)) |l| std.debug.print("  {s}\n", .{l});
    };
    const cited = try settle.clauses(arena, source);
    if (!sameLines(old.codes, new_codes)) {
        const why = try arena.print("codes: old {s}, new {s}{s}", .{ try join(arena, old.codes), try join(arena, new_codes), try firstMessage(arena, &zcu) });
        return ruled(arena, rulings, rel, cited, why, try join(arena, new_codes));
    }
    const lw = old.lw orelse return .{ .verdict = .{ .why = if (analysis != null) "the old side refused, the new side lowered" else null } };
    const a = &(analysis orelse return .{ .verdict = .{ .why = "the old side lowered, the new side refused" } });
    const want = try tables.oldTables(arena, lw, dropped);
    const got = try tables.newTables(arena, &zcu, &a.device);
    if (show) {
        std.debug.print("-- old tables\n", .{});
        for (want) |l| std.debug.print("  {s}\n", .{l});
        std.debug.print("-- new tables\n", .{});
        for (got) |l| std.debug.print("  {s}\n", .{l});
    }
    if (try linesDiffer(arena, want, got)) |why| return ruled(arena, rulings, rel, cited, why, try rowsDiffer(arena, want, got));
    if (try Air.Verify.verify(gpa, a.air, &zcu.intern_pool)) |bad|
        return .{ .verdict = .{ .why = try arena.print("Air.Verify: {t} at instruction {d}", .{ bad.rule, @backingInt(bad.inst) }) } };
    return .{ .verdict = try values.compareValues(arena, rel, old.mir, lw, try tables.keptParams(arena, lw, dropped), &zcu, a) };
}

/// `why` settled by fixture `rel`'s ruling when the new side gave `got`:
/// `.ruled`, else the verdict `why` (and why the ruling does not hold).
fn ruled(arena: std.mem.Allocator, rulings: *settle.Rulings, rel: []const u8, cited: []const []const u8, why: []const u8, got: []const u8) !Outcome {
    if (rulings.get(rel) == null) return .{ .verdict = .{ .why = why } };
    const no = (try rulings.settle(arena, rel, cited, got)) orelse return .ruled;
    return .{ .verdict = .{ .why = try arena.print("{s}; {s}", .{ why, no }) } };
}

/// What a tables ruling compares: each old row the new side lacks as
/// `-<row>`, then each new row the old lacks as `+<row>`, joined by `; `.
/// Rows are a multiset: a row twice on one side and once on the other is
/// one difference.
fn rowsDiffer(arena: std.mem.Allocator, old: []const []const u8, new: []const []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for ([2][]const []const u8{ old, new }, [2][]const []const u8{ new, old }, "-+") |these, those, sign| {
        const matched = try arena.alloc(bool, those.len);
        @memset(matched, false);
        outer: for (these) |row| {
            for (those, matched) |other, *m| if (!m.* and std.mem.eql(u8, row, other)) {
                m.* = true;
                continue :outer;
            };
            try parts.append(arena, try arena.print("{c}{s}", .{ sign, row }));
        }
    }
    return std.mem.join(arena, "; ", parts.items);
}

/// The first lowering failure's message, for a reader of the report.
fn firstMessage(arena: std.mem.Allocator, zcu: *const Zcu) ![]const u8 {
    for (zcu.failed.items(.code), zcu.failed.items(.message)) |c, m| {
        const name = @tagName(c);
        for (elab_codes) |e| {
            if (std.mem.eql(u8, e, name)) break;
        } else return arena.print(" ({s}: {s})", .{ name, zcu.intern_pool.stringToSlice(m) });
    }
    return "";
}

/// Whether elaboration or AstGen raised an error.
fn hasError(zcu: *const Zcu, vir: *const vams.Vir) bool {
    for (zcu.failed.items(.code)) |c| if (@tagName(c)[0] == 'E') return true;
    for (vir.diag.messages()) |m| if (@tagName(vir.diag.message(m).tag.code)[0] == 'E') return true;
    return false;
}

/// The old analog route up to `Lower.lower`, as `Compilation/analyze.zig`
/// runs it: null when a stage before lowering refuses the source.
fn oldSide(arena: std.mem.Allocator, pp: frontend.preprocessor.Output, bag: *diag.Bag, include_dirs: []const []const u8, files: *frontend.Files) !?Old {
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
    const mir = try arena.create(Mir);
    mir.* = .{};
    const out: ?analog.Lower.Output = analog.Lower.lower(arena, mir, file, pp.text, starts, bag, .{
        .directives = pp.directives,
        .include_dirs = include_dirs,
        .files = files,
    }) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.NoModule, error.DiagnosticsReported => null,
    };
    var codes: std.ArrayList([]const u8) = .empty;
    for (before..bag.count()) |k| try codes.append(arena, @tagName(bag.at(k).code));
    var lw: ?*Lowered = null;
    if (out) |o| {
        lw = try arena.create(Lowered);
        lw.?.* = o.lowered;
    }
    // The old `fileOf`: the file a declaration's token came from; the
    // seeded prelude's are 0.
    const seed_natures: usize = if (seed) |sd| sd.file.natures.len else 0;
    const seed_discs: usize = if (seed) |sd| sd.file.disciplines.len else 0;
    const nature_files = try arena.alloc(u32, file.natures.len);
    for (file.natures, nature_files, 0..) |n, *f, k| f.* = if (k < seed_natures) 0 else 1 + @as(u32, @backingInt(bag.locate(frontend.lexer.tokenSpan(pp.text, starts, n.main_tok), .none).file));
    const disc_files = try arena.alloc(u32, file.disciplines.len);
    for (file.disciplines, disc_files, 0..) |d, *f, k| f.* = if (k < seed_discs) 0 else 1 + @as(u32, @backingInt(bag.locate(frontend.lexer.tokenSpan(pp.text, starts, d.main_tok), .none).file));
    return .{ .codes = try lowerCodes(arena, codes.items), .lw = lw, .mir = mir, .nature_files = nature_files, .disc_files = disc_files, .annex_d_included = pp.annex_d_included };
}

/// Each declaration-table row's source file, from the old side's
/// (natures and disciplines are in the same order on both sides); empty
/// when the counts differ.
fn declFiles(arena: std.mem.Allocator, vir: *const vams.Vir, old: Old) ![]const u32 {
    const out = try arena.alloc(u32, vir.decls().len);
    var n: usize = 0;
    var d: usize = 0;
    for (vir.decls(), out) |row, *f| f.* = switch (row.kind) {
        .nature => blk: {
            defer n += 1;
            break :blk if (n < old.nature_files.len) old.nature_files[n] else return &.{};
        },
        .discipline => blk: {
            defer d += 1;
            break :blk if (d < old.disc_files.len) old.disc_files[d] else return &.{};
        },
        else => 1, // else: no per-file rule reads another unit's file
    };
    if (n != old.nature_files.len or d != old.disc_files.len) return &.{};
    return out;
}

/// `codes` less elaboration's, sorted and deduplicated.
fn lowerCodes(arena: std.mem.Allocator, codes: []const []const u8) ![]const []const u8 {
    var keep: std.ArrayList([]const u8) = .empty;
    outer: for (codes) |c| {
        for (elab_codes) |e| if (std.mem.eql(u8, c, e)) continue :outer;
        try keep.append(arena, c);
    }
    return setOf(arena, keep.items);
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

/// The first line where the tables differ, or null.
fn linesDiffer(arena: std.mem.Allocator, old: []const []const u8, new: []const []const u8) !?[]const u8 {
    for (0..@max(old.len, new.len)) |k| {
        const o = if (k < old.len) old[k] else "(none)";
        const n = if (k < new.len) new[k] else "(none)";
        if (!std.mem.eql(u8, o, n)) return try arena.print("tables row {d}: old `{s}`, new `{s}`", .{ k, o, n });
    }
    return null;
}

test "diff-lower: Sema's analog lowering agrees with src/analog on every fixture" {
    var result: anyerror!void = {};
    // The old lowering recurses with the tree.
    const t = try std.Thread.spawn(.{ .stack_size = 256 << 20 }, run, .{&result});
    t.join();
    try result;
}
