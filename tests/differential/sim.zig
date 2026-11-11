//! The differential oracle of the new digital pipeline (`zig build
//! diff-sim`, docs/rewrite/sim.md, docs/rewrite/dlower.md): every `.v`
//! fixture `vera --run` judges against a golden (the `suite -- devices` and
//! `ieee1364` sets) in, a verdict per fixture out. The new side compiles the
//! fixture from source (vams Preprocessor, Parse, AstGen, Sema's
//! elaboration, then `sema.digital.lower`), parsed and generated as
//! vera-next does a `.v` (`discrete`, `ieee1364`: else a rule the lowering
//! owns is refused at the parser and agrees by accident), and runs the `Program` in
//! `std_sim`; the oracle is lib/sim/digital's own run, the product until the
//! rewrite replaces it. A fixture agrees when both transcripts are
//! byte-equal, both runs end the same way (completed, or a runtime error),
//! the same timing checks report violations (W1199's sites), and both write
//! the same files. Each fixture is compared in a child process of its
//! own (Linux), so one that crashes either side is a difference of its
//! own and its memory is not this test's. A `//! reject` fixture agrees when both sides refuse
//! it: the new side at a stage before the lowering with the old run's first
//! error code (as vera-next words it) at its byte, or the lowering raising lib/sim/digital's code with
//! its message at its byte, or the run failing as the old run does; a crash,
//! or a lowering that refuses it as unsupported, is a difference. A known difference is a line of `sim.xfail` (`<path
//! under the fixture root> <reason>`); a listed fixture that agrees, or
//! that is not in the corpus, fails the run until its line goes.
//! Cites: IEEE 1364-2005 §9, §11, §13, §17 (through both implementations).
//!
//! Contents: tests only.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const sim = @import("sim");
const std_sim = @import("std_sim");
const diag = @import("diag");
const frontend = @import("frontend");
const vams = @import("vams");
const sema = @import("sema");
const InternPool = @import("intern_pool");
const repo_env = @import("repo_env");
const digital = sim.digital;
const Zcu = sema.Zcu;

/// The fixture directories `suite -- devices` runs (`tests/suite/Devices.zig`).
const dirs = [_][]const u8{ "verilog", "verilog-ams/digital" };

/// One run-stage diagnostic, compared by code name (old `diag.Code`'s, new
/// `vams.Diag.Code`'s) and text, in order (G3-G6: `exe.report` used to drop
/// these). `at` is the source byte when resolvable: a `.check`-blamed
/// diagnostic resolves through `Lowered.check_sites`, a `.pc`-blamed one
/// through `Lowered.pc_sites` (T3); `null` only when the lowering wrote no
/// `pc_sites` at all, so only the code and text are compared.
const RunDiag = struct { code: []const u8, at: ?u32, text: []const u8 };

/// One elaboration-stage warning (T1(b): `zcu.failed`'s W rows), compared
/// by code name and byte with the old bag's `.lower`-stage warnings.
const ElabWarn = struct { code: []const u8, at: u32 };

/// One run: what the oracle compares. `warnings`: every run-stage
/// diagnostic that did not end the run, in order. `fail`: the one that did,
/// if any (`failed` may still be true with `fail == null`: an earlier
/// stage of this same old run failed). `sites`: the source bytes of the
/// timing checks that reported a violation, sorted, each once.
const Side = struct {
    out: []const u8,
    failed: bool,
    warnings: []const RunDiag = &.{},
    fail: ?RunDiag = null,
    sites: []const u32 = &.{},
};

/// The new side's compile, from source: the `Program` and its check sites,
/// or why it stopped; the 1364 elaboration warnings it raised getting
/// there (T1(b)), whichever way it stopped.
/// `earlier`: a stage before the lowering raised an error (`Early`); `refused`: the
/// lowering does not express the design yet (or the harness cannot run
/// it); `rejected`: the lowering raised an error (`Why.code`).
const CompiledNew = struct {
    compiled: Compiled,
    elab_warnings: []const ElabWarn = &.{},
};
const Compiled = union(enum) { lowered: sema.digital.Lowered, refused: []const u8, earlier: Early, rejected: sema.digital.Why };

/// A refusal before the lowering: which stage and why, and the first
/// error's code (as vera-next reports it) and byte, which the old run's
/// first error must match.
const Early = struct { why: []const u8, code: []const u8, at: u32 };

// ---- private ----

/// Every `.v` with a `.expected.txt` golden, an `//! expect vcd` line or a
/// `//! reject` line under `dirs`, relative to `root` and sorted (the
/// `suite -- devices` corpus). `pli/` is the VPI suite's.
fn collect(arena: Allocator, io: std.Io, root: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (dirs) |sub| {
        const path = try std.fs.path.join(arena, &.{ root, sub });
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!std.mem.eql(u8, std.fs.path.extension(entry.path), ".v")) continue;
            if (std.mem.startsWith(u8, entry.path, "pli" ++ std.fs.path.sep_str)) continue;
            const stem = entry.path[0 .. entry.path.len - ".v".len];
            const golden = try std.fmt.allocPrint(arena, "{s}.expected.txt", .{stem});
            const has_golden = if (dir.access(io, golden, .{})) |_| true else |_| false;
            const source = try dir.readFileAlloc(io, entry.path, arena, .limited(1 << 22));
            if (!negative(source) and !has_golden and std.mem.find(u8, source, "//! expect vcd") == null) continue;
            try list.append(arena, try std.fs.path.join(arena, &.{ sub, entry.path }));
        }
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return list.items;
}

/// A `//! reject` or `//! reject-only` line.
fn negative(source: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "//!")) continue;
        var words = std.mem.tokenizeAny(u8, line["//!".len..], " \t");
        const word = words.next() orelse continue;
        if (std.mem.eql(u8, word, "reject") or std.mem.eql(u8, word, "reject-only")) return true;
    }
    return false;
}

/// `sim.xfail` or `sim.rulings`: one `<path> <reason>` per line; `#` and
/// blank lines are comments. A line without a reason is refused.
fn readXfail(arena: Allocator, io: std.Io, path: []const u8) !std.StringHashMapUnmanaged([]const u8) {
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 24));
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.findAny(u8, line, " \t") orelse {
            std.debug.print("diff-sim: sim.xfail line `{s}` has no reason\n", .{line});
            return error.XfailWithoutReason;
        };
        try map.put(arena, line[0..sp], std.mem.trim(u8, line[sp..], " \t"));
    }
    return map;
}

/// The settings `vera --run` gives a fixture (`tests/suite/Digital.zig`'s
/// `runnerArgs`, then `src/cli/digital.zig`'s `libraries`), for both sides:
/// its path, its `//! event-budget`, and its `//@` lines (`std`, `files`,
/// `libmap`, `liblist`, `protect-keys`), relative to its directory. Null when the lines name something the cli
/// itself would refuse.
fn options(a: Allocator, io: std.Io, source: []const u8, path: []const u8) !?digital.Options {
    var opts: digital.Options = .{ .file_name = path, .io = io };
    const dir = std.fs.path.dirname(path).?;
    var paths: std.ArrayList([]const u8) = .empty;
    try paths.append(a, path);
    var maps: std.ArrayList([]const u8) = .empty;
    var search: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.cutPrefix(u8, line, "//! event-budget")) |rest|
            opts.event_budget = std.fmt.parseInt(u64, std.mem.trim(u8, rest, " \t"), 10) catch return null;
        if (!std.mem.startsWith(u8, line, "//@")) continue;
        var words = std.mem.tokenizeAny(u8, line["//@".len..], " \t");
        const key = words.next() orelse return null;
        if (std.mem.eql(u8, key, "std")) {
            opts.language = frontend.keyword.KeywordSet.fromSpecifier(words.next() orelse return null) orelse return null;
        } else if (std.mem.eql(u8, key, "libmap")) {
            try maps.append(a, try std.fs.path.join(a, &.{ dir, words.next() orelse return null }));
        } else if (std.mem.eql(u8, key, "protect-keys")) {
            const text = std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ dir, words.next() orelse return null }), a, .limited(1 << 22)) catch return null;
            opts.protect_keys = frontend.protect.parseKeys(a, text) catch return null;
        } else if (std.mem.eql(u8, key, "liblist")) {
            while (words.next()) |lib| try search.append(a, lib);
        } else if (std.mem.eql(u8, key, "files")) {
            while (words.next()) |f| try paths.append(a, try std.fs.path.join(a, &.{ dir, f }));
        } else return null;
    }
    var bag: diag.Bag = .init(a);
    const map = frontend.libmap.load(a, io, &bag, maps.items) catch return null;
    const libs = try a.alloc([]const u8, paths.items.len);
    for (paths.items, libs) |p, *lib| {
        const real = std.Io.Dir.cwd().realPathFileAlloc(io, p, a) catch return null;
        lib.* = switch (map.libraryOf(real)) {
            .lib => |l| l,
            .ambiguous => return null,
        };
    }
    const more = try a.alloc(digital.Unit, paths.items.len - 1);
    for (paths.items[1..], libs[1..], more) |p, l, *u| u.* = .{
        .name = p,
        .text = std.Io.Dir.cwd().readFileAlloc(io, p, a, .limited(1 << 22)) catch return null,
        .lib = l,
    };
    opts.lib = libs[0];
    opts.more = more;
    if (map.incdirs.len != 0) opts.include_dirs = map.incdirs;
    opts.search = if (search.items.len != 0) search.items else try map.order(a);
    return opts;
}

/// Preprocesses, parses, AstGens, elaborates and lowers fixture `path`
/// (with its `//@ files` units) as the new pipeline does.
fn compileNew(a: Allocator, io: std.Io, source: []const u8, path: []const u8, opts: digital.Options) !CompiledNew {
    // IEEE 1364-2005 §28.2 the keys, read with the vams reader.
    var keys: vams.Preprocessor.protect.Keys = .{};
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const rest = std.mem.cutPrefix(u8, line, "//@ protect-keys") orelse continue;
        const file = try std.fs.path.join(a, &.{ std.fs.path.dirname(path).?, std.mem.trim(u8, rest, " \t") });
        const json = try std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(1 << 22));
        keys = vams.Preprocessor.protect.parseKeys(a, json) catch return .{ .compiled = .{ .refused = "a key file the vams reader refuses" } };
    }
    var pp: vams.Preprocessor = .init(a, .{
        .include_dirs = opts.include_dirs,
        .std_defs = false,
        .std_1364 = @backingInt(opts.language) < @backingInt(frontend.keyword.KeywordSet.vams_2_3),
        .protect_keys = keys,
    });
    try pp.addUnit(path, source);
    for (opts.more) |u| try pp.addUnit(u.name, u.text);
    var requests: usize = 0;
    while (try pp.run()) |req| switch (req) {
        .file => |want| {
            requests += 1;
            if (requests > 10_000) return .{ .compiled = .{ .refused = "more than 10,000 include requests" } };
            try pp.answer(std.Io.Dir.cwd().readFileAlloc(io, want.path, a, .limited(1 << 24)) catch null);
        },
    };
    const out = try a.create(vams.Preprocessor.Output);
    out.* = pp.output();
    if (out.failed) for (out.diagnostics) |d| if (d.code[0] == 'E')
        return .{ .compiled = .{ .earlier = .{ .why = try a.print("the vams preprocessor refuses it ({s})", .{d.code}), .code = d.code, .at = d.start } } };
    const text = try a.dupeSentinel(u8, out.text, 0);
    const tree = try a.create(vams.Ast);
    tree.* = try vams.Ast.parse(a, text, .{ .keywords = std.meta.stringToEnum(vams.Ast.KeywordSet, @tagName(opts.language)).?, .discrete = true });
    if (tree.errors.len != 0) {
        var w: vams.Diag.Wip = .init(a);
        try vams.Ast.parse_errors.report(tree, &w);
        const d = try w.toOwnedBundle();
        const m = d.message(d.messages()[0]);
        return .{ .compiled = .{ .earlier = .{ .why = try a.print("the vams parser refuses it ({t})", .{tree.errors[0].tag}), .code = @tagName(m.tag.code), .at = m.loc.start } } };
    }
    const vir = try vams.AstGen.generate(a, tree, .{ .directives = out.directives, .ieee1364 = true });
    // `SIM_DUMP=1` with `SIM_ONLY`: the fixture's Vir on stderr.
    if (std.process.Environ.getPosix(std.testing.environ, "SIM_DUMP") != null) {
        var dump: std.Io.Writer.Allocating = .init(a);
        try vams.Vir.print.render(&vir, &dump.writer);
        std.debug.print("{s}\n", .{dump.written()});
    }
    for (vir.diag.messages()) |m| {
        const code = vir.diag.message(m).tag.code;
        // vera-next's IEEE 1364 route words E0376 as lib/sim/digital's E1100.
        if (@tagName(code)[0] == 'E') return .{ .compiled = .{ .earlier = .{ .why = try a.print("AstGen refuses it ({t})", .{code}), .code = if (code == .E0376) "E1100" else @tagName(code), .at = vir.diag.message(m).loc.start } } };
    }
    var zcu: Zcu = try .init(a);
    const file = try zcu.addFile(path, vir, 0);
    if (std.mem.find(u8, source, "//@ libmap") != null or std.mem.find(u8, source, "//@ liblist") != null)
        try libraries(a, &zcu, file, tree, out.unit_starts, opts);
    try sema.Sema.elaborate(&zcu, .{ .roots = .all, .ieee1364 = true });
    // T1(b): every W row is an elaboration warning, kept regardless of how
    // this compile ends, for the old bag's `.lower`-stage warnings to be
    // compared against (`G1`: the hole W0252 came through this way).
    var elab_warnings: std.ArrayList(ElabWarn) = .empty;
    const zf = zcu.failed.slice();
    for (zf.items(.code), zf.items(.src), zf.items(.rule), zf.items(.part)) |code, src, rule, part| {
        // vera-next's IEEE 1364 route reports a `Rule` under lib/sim/digital's code.
        const as = @tagName(if (rule == .none) code else rule.code());
        const at = if (sema.locate.part(tree, &vir, src, part)) |span| span.bytes(tree).start else 0;
        if (@tagName(code)[0] == 'E') return .{ .compiled = .{ .earlier = .{ .why = try a.print("elaboration refuses it ({t})", .{code}), .code = as, .at = at } }, .elab_warnings = elab_warnings.items };
        try elab_warnings.append(a, .{ .code = as, .at = at });
    }
    var why: sema.digital.Why = .{};
    const lowered = sema.digital.lower(a, &zcu, .{ .sources = &.{.{ .tree = tree, .pp = out }}, .std_1364 = @backingInt(opts.language) < @backingInt(frontend.keyword.KeywordSet.vams_2_3) }, &why) catch |e| switch (e) {
        error.Unsupported => return .{ .compiled = .{ .refused = try a.print("lowering: {s}", .{why.text}) }, .elab_warnings = elab_warnings.items },
        error.Rejected => return .{ .compiled = .{ .rejected = why }, .elab_warnings = elab_warnings.items },
        error.OutOfMemory => return e,
    };
    return .{ .compiled = .{ .lowered = lowered }, .elab_warnings = elab_warnings.items };
}

/// §13.2.3 the library map `options` read, as Compilation hands it to the
/// Zcu: each design unit's library (the unit its source offset falls in,
/// `unit_starts`), and the search order.
fn libraries(a: Allocator, zcu: *Zcu, file: Zcu.File.Index, tree: *const vams.Ast, unit_starts: []const u32, opts: digital.Options) !void {
    const vir = zcu.fileVir(file);
    for (vir.decls(), 0..) |d, k| {
        const data = vir.instructions.items(.data)[@backingInt(d.inst)];
        const at = tree.tokenStart(tree.nodeMainToken(data.pl_node.src_node));
        var unit: usize = 0;
        while (unit < unit_starts.len and unit_starts[unit] <= at) unit += 1;
        const lib = if (unit == 0) opts.lib else opts.more[unit - 1].lib;
        try zcu.decl_lib.put(a, .{ .file = file, .index = @fromBackingInt(@intCast(k)) }, try zcu.intern_pool.getString(a, lib));
    }
    const order = try a.alloc(InternPool.String, opts.search.len);
    for (opts.search, order) |l, *o| o.* = try zcu.intern_pool.getString(a, l);
    zcu.lib_order = order;
}

/// `d` resolved to a comparable `RunDiag`: a `.check` blame through
/// `check_sites` (`Lowered.check_sites`); a `.pc` blame through
/// `pc_sites` (`Lowered.pc_sites`, T3), or `null` when the lowering wrote
/// none (a design that refused before reaching `std_sim`).
fn diagOf(d: std_sim.State.Diag, pc_sites: []const u32, check_sites: []const u32) RunDiag {
    return .{
        .code = @tagName(d.code),
        .at = switch (d.of) {
            .check => check_sites[d.at],
            .pc => if (pc_sites.len != 0) pc_sites[d.at] else null,
        },
        .text = d.text,
    };
}

/// Runs `p` in `std_sim`, in the working directory, with `pc_sites` and
/// `check_sites` naming each instruction's and timing check's source byte.
fn runProgram(a: Allocator, io: std.Io, p: *const std_sim.Program, pc_sites: []const u32, check_sites: []const u32, budget: u64) !Side {
    var out: std.Io.Writer.Allocating = .init(a);
    var s: std_sim.State = try .init(a, p, &out.writer);
    s.budget = budget;
    s.io = io;
    // The run nests one native frame chain per §10 activation.
    var result: std_sim.State.Error!void = {};
    const t = try std.Thread.spawn(.{ .stack_size = 1 << 30 }, struct {
        fn go(st: *std_sim.State, r: *std_sim.State.Error!void) void {
            r.* = std_sim.Interp.run(st);
        }
    }.go, .{ &s, &result });
    t.join();
    std_sim.files.closeAll(&s);
    var violated: std.ArrayList(u32) = .empty;
    for (s.checks, check_sites) |c, site| if (c.count != 0) try violated.append(a, site);
    const v = try uniqueSorted(violated.items);
    const warnings = try a.alloc(RunDiag, s.diags.items.len);
    for (s.diags.items, warnings) |d, *w| w.* = diagOf(d, pc_sites, check_sites);
    result catch |e| switch (e) {
        error.SimFailed => return .{ .out = out.written(), .failed = true, .warnings = warnings, .fail = diagOf(s.failure.?, pc_sites, check_sites), .sites = v },
        error.OutOfMemory, error.WriteFailed => return e,
    };
    return .{ .out = out.written(), .failed = false, .warnings = warnings, .sites = v };
}

/// The first run-stage diagnostic that differs, old vs new, in order
/// (code, text always; byte only when the new side resolved one): "" when
/// every one agrees. `old`/`new` are each side's warnings with its
/// failure (if any) appended, in the order they were raised.
fn diagsDiffer(a: Allocator, old: []const RunDiag, new: []const RunDiag) ![]const u8 {
    const n = @min(old.len, new.len);
    for (old[0..n], new[0..n], 0..) |o, w, i| {
        if (std.mem.eql(u8, o.code, w.code) and std.mem.eql(u8, o.text, w.text) and (w.at == null or w.at.? == o.at.?))
            continue;
        return std.fmt.allocPrint(a, "run diagnostic {d}: old {s}@{?d} \"{s}\"; new {s}@{?d} \"{s}\"", .{ i, o.code, o.at, o.text, w.code, w.at, w.text });
    }
    if (old.len != new.len) return std.fmt.allocPrint(a, "{d} run diagnostics old, {d} new", .{ old.len, new.len });
    return "";
}

/// `warnings` with `fail` appended, if any: one ordered list to feed
/// `diagsDiffer`.
fn withFail(a: Allocator, warnings: []const RunDiag, fail: ?RunDiag) ![]const RunDiag {
    const f = fail orelse return warnings;
    const out = try a.alloc(RunDiag, warnings.len + 1);
    @memcpy(out[0..warnings.len], warnings);
    out[warnings.len] = f;
    return out;
}

/// T1(b): the first elaboration warning that differs, old's `.lower`-stage
/// bag entries vs the new 1364 route's `zcu.failed` W rows, by code and
/// byte, in order: "" when every one agrees.
fn elabWarningsDiffer(a: Allocator, old: []const ElabWarn, new: []const ElabWarn) ![]const u8 {
    const n = @min(old.len, new.len);
    for (old[0..n], new[0..n], 0..) |o, w, i|
        if (!std.mem.eql(u8, o.code, w.code) or o.at != w.at)
            return std.fmt.allocPrint(a, "elaboration warning {d}: old {s}@{d}; new {s}@{d}", .{ i, o.code, o.at, w.code, w.at });
    if (old.len != new.len) return std.fmt.allocPrint(a, "{d} elaboration warnings old, {d} new", .{ old.len, new.len });
    return "";
}

/// A `sim.rulings` entry holds for a `//! reject` fixture when both sides
/// reject it under the same code (lib/sim/digital's `diag.Code` and
/// `vams.Diag.Code` compared by name): G13's "old shape, not old truth"
/// cases, where the wording and the blamed byte are not expected to agree.
fn rulingHolds(reject: bool, old_code: ?[]const u8, new_code: []const u8) bool {
    const oc = old_code orelse return false;
    return reject and std.mem.eql(u8, oc, new_code);
}

/// Runs fixture `rel` both ways: "" when they agree, else what differs.
/// `ruling`: `sim.rulings` lists `rel` (`rulingHolds` decides whether it
/// still does).
fn compare(a: Allocator, io: std.Io, root: []const u8, rel: []const u8, ruling: bool) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ root, rel });
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 22));
    const opts = try options(a, io, source, path) orelse return "a `//@` line the cli refuses";
    const cn = try compileNew(a, io, source, path, opts);
    const compiled = cn.compiled;
    const reject = negative(source);
    switch (compiled) {
        .refused => |why| return why,
        .earlier => |e| if (!reject) return e.why,
        .rejected, .lowered => {},
    }

    // Each side runs in a scratch directory of its own, so the files a
    // fixture writes are compared too and never land in the tree.
    var new_dir = std.testing.tmpDir(.{ .iterate = true });
    defer new_dir.cleanup();
    var old_dir = std.testing.tmpDir(.{ .iterate = true });
    defer old_dir.cleanup();
    const home = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer home.close(io);
    defer std.process.setCurrentDir(io, home) catch {};

    try std.process.setCurrentDir(io, old_dir.dir);
    var old_out: std.Io.Writer.Allocating = .init(a);
    var first: ?struct { code: diag.Code, at: u32, message: []const u8 } = null;
    var old_lower_warnings: std.ArrayList(ElabWarn) = .empty;
    const old: Side = old: {
        var bag: diag.Bag = .init(a);
        const failed = if (digital.run(a, source, opts, &bag, &old_out.writer)) |_| bag.failed() else |e| switch (e) {
            error.DigitalFailed => true,
            else => return e,
        };
        var sites: std.ArrayList(u32) = .empty;
        var warnings: std.ArrayList(RunDiag) = .empty;
        var fail: ?RunDiag = null;
        for (0..bag.count()) |k| {
            const d = bag.at(k);
            if (d.code == .W1199) try sites.append(a, d.span.start);
            if (first == null and d.severity == .err) first = .{ .code = d.code, .at = d.span.start, .message = d.message };
            if (d.stage == .run) {
                const rd: RunDiag = .{ .code = @tagName(d.code), .at = d.span.start, .text = d.message };
                if (d.severity == .err) {
                    if (fail == null) fail = rd;
                } else try warnings.append(a, rd);
            } else if (d.stage == .lower and d.severity == .warning) {
                try old_lower_warnings.append(a, .{ .code = @tagName(d.code), .at = d.span.start });
            }
        }
        break :old .{ .out = old_out.written(), .failed = failed, .warnings = warnings.items, .fail = fail, .sites = try uniqueSorted(sites.items) };
    };

    // T1(b): the 1364 route's elaboration warnings (`zcu.failed` W rows)
    // against the old bag's `.lower`-stage ones (G1: the hole W0252 came
    // through this way).
    {
        const d = try elabWarningsDiffer(a, old_lower_warnings.items, cn.elab_warnings);
        if (d.len != 0) return d;
    }

    const lowered = switch (compiled) {
        .lowered => |l| l,
        // An earlier stage's refusal agrees only with the old run's first
        // error: its code at its byte, unless a `sim.rulings` entry holds
        // (G13(a): the old resolves names lazily while running, a run
        // failure; the new finds the same error while lowering).
        .earlier => |e| {
            if (ruling and rulingHolds(reject, if (first) |f| @tagName(f.code) else null, e.code)) return "";
            const f = first orelse return std.fmt.allocPrint(a, "old run completed, new {s}", .{e.why});
            if (!std.mem.eql(u8, @tagName(f.code), e.code) or f.at != e.at)
                return std.fmt.allocPrint(a, "old {t} at byte {d}: {s}; new {s} at byte {d}: {s}", .{ f.code, f.at, f.message, e.code, e.at, e.why });
            return "";
        },
        .rejected => |why| {
            if (ruling and rulingHolds(reject, if (first) |f| @tagName(f.code) else null, @tagName(why.code))) return "";
            const f = first orelse return std.fmt.allocPrint(a, "old run completed, the new lowering raised {t} at byte {d}: {s}", .{ why.code, why.at, why.text });
            // Two code enums (lib/diag's and vams'), one catalogue: compared by name.
            if (!std.mem.eql(u8, @tagName(f.code), @tagName(why.code)) or !std.mem.endsWith(u8, f.message, why.text) or f.at != why.at)
                return std.fmt.allocPrint(a, "old {t} at byte {d}: {s}; new {t} at byte {d}: {s}", .{ f.code, f.at, f.message, why.code, why.at, why.text });
            return "";
        },
        .refused => unreachable, // returned above
    };

    try std.process.setCurrentDir(io, new_dir.dir);
    const new = try runProgram(a, io, &lowered.program, lowered.pc_sites, lowered.check_sites, opts.event_budget);

    if (old.failed and !new.failed) if (first) |f|
        return std.fmt.allocPrint(a, "old run failed ({t}: {s}), new run completed", .{ f.code, f.message });
    if (old.failed != new.failed)
        return std.fmt.allocPrint(a, "old run {s}, new run {s} ({s})", .{ if (old.failed) "failed" else "completed", if (new.failed) "failed" else "completed", if (new.fail) |f| f.text else "" });
    // G13(b)(c): a ruling settles for the same failure code, the wording
    // and the blamed byte left uncompared (the old side's own, not what
    // T2/T3 make the new side's).
    if (ruling and new.fail != null and rulingHolds(reject, if (old.fail) |f| f.code else null, new.fail.?.code)) return "";
    {
        const d = try diagsDiffer(a, try withFail(a, old.warnings, old.fail), try withFail(a, new.warnings, new.fail));
        if (d.len != 0) return d;
    }
    if (!std.mem.eql(u8, old.out, new.out)) return textDiff(a, old.out, new.out);
    if (!std.mem.eql(u32, old.sites, new.sites))
        return std.fmt.allocPrint(a, "the timing checks that violated differ: old at bytes {any}, new {any}", .{ old.sites, new.sites });
    try std.process.setCurrentDir(io, home);
    return sameFiles(a, io, old_dir.dir, new_dir.dir);
}

/// `compare` in a forked child (Linux): its verdict through a pipe, or the
/// signal that ended it, so a crash is that fixture's difference and the
/// child's memory never this process's.
fn isolated(a: Allocator, io: std.Io, root: []const u8, rel: []const u8, ruling: bool) ![]const u8 {
    if (builtin.os.tag != .linux) return compare(a, io, root, rel, ruling);
    const linux = std.os.linux;
    var fds: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.ForkFailed;
    if (pid == 0) {
        _ = linux.close(fds[0]);
        const why = compare(a, io, root, rel, ruling) catch |e| @errorName(e);
        var at: usize = 0;
        while (at < why.len) {
            const n = linux.write(fds[1], why[at..].ptr, why.len - at);
            if (linux.errno(n) != .SUCCESS) linux.exit_group(2);
            at += n;
        }
        linux.exit_group(0);
    }
    _ = linux.close(fds[1]);
    defer _ = linux.close(fds[0]);
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = linux.read(fds[0], &buf, buf.len);
        if (linux.errno(n) == .INTR) continue;
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(a, buf[0..n]);
    }
    var status: u32 = 0;
    while (linux.errno(linux.waitpid(@intCast(pid), @ptrCast(&status), 0)) == .INTR) {}
    if (linux.W.IFSIGNALED(status)) return std.fmt.allocPrint(a, "the comparison crashed ({t})", .{linux.W.TERMSIG(status)});
    if (linux.W.EXITSTATUS(status) != 0) return std.fmt.allocPrint(a, "the comparison exited {d}", .{linux.W.EXITSTATUS(status)});
    return out.items;
}

/// "" when both runs wrote the same files with the same bytes, else the
/// first that differs.
fn sameFiles(a: Allocator, io: std.Io, old: std.Io.Dir, new: std.Io.Dir) ![]const u8 {
    const names_old = try listing(a, io, old);
    const names_new = try listing(a, io, new);
    if (names_old.len != names_new.len) return std.fmt.allocPrint(a, "the runs wrote {d} and {d} files", .{ names_old.len, names_new.len });
    for (names_old, names_new) |x, y| {
        if (!std.mem.eql(u8, x, y)) return std.fmt.allocPrint(a, "the runs wrote `{s}` and `{s}`", .{ x, y });
        // §18.2.3.2 a dump's `$date` is the wall clock's: not compared.
        const bx = undated(try old.readFileAlloc(io, x, a, .limited(1 << 24)));
        const by = undated(try new.readFileAlloc(io, y, a, .limited(1 << 24)));
        if (!std.mem.eql(u8, bx, by)) return std.fmt.allocPrint(a, "file `{s}`: {s}", .{ x, try textDiff(a, bx, by) });
    }
    return "";
}

/// A dump file past its `$date ... $end` section; any other file whole.
fn undated(bytes: []u8) []const u8 {
    if (!std.mem.startsWith(u8, bytes, "$date")) return bytes;
    const end = std.mem.find(u8, bytes, "$end") orelse return bytes;
    return bytes[end..];
}

/// The files under `dir`, sorted.
fn listing(a: Allocator, io: std.Io, dir: std.Io.Dir) ![]const []const u8 {
    var it = try dir.walk(a);
    defer it.deinit();
    var names: std.ArrayList([]const u8) = .empty;
    while (try it.next(io)) |entry| if (entry.kind == .file) try names.append(a, try a.dupe(u8, entry.path));
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return names.items;
}

/// `items` sorted with each value once, in place.
fn uniqueSorted(items: []u32) ![]const u32 {
    std.mem.sort(u32, items, {}, std.sort.asc(u32));
    var n: usize = 0;
    for (items) |v| {
        if (n != 0 and items[n - 1] == v) continue;
        items[n] = v;
        n += 1;
    }
    return items[0..n];
}

/// The first differing byte and the text around it on each side.
fn textDiff(a: Allocator, old: []const u8, new: []const u8) ![]const u8 {
    const at = std.mem.indexOfDiff(u8, old, new).?;
    const from = at -| 30;
    return std.fmt.allocPrint(a, "transcript differs at byte {d} (old {d} bytes, new {d}): old \"{s}\" new \"{s}\"", .{
        at,                                                old.len,                                           new.len,
        try escaped(a, old[from..@min(at + 30, old.len)]), try escaped(a, new[from..@min(at + 30, new.len)]),
    });
}

fn escaped(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '\n' => try out.appendSlice(a, "\\n"),
        '\t' => try out.appendSlice(a, "\\t"),
        else => try out.append(a, c),
    };
    return out.items;
}

test "diff-sim: Sema's digital Program runs every .v fixture as lib/sim/digital does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var run_arena: std.heap.ArenaAllocator = .init(gpa);
    defer run_arena.deinit();
    const ra = run_arena.allocator();
    // Absolute: each run changes the working directory.
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, repo_env.fixtureRoot(), ra);

    const fixtures = try collect(ra, io, root);
    const xfail_path = try std.fs.path.join(ra, &.{ repo_env.repoRoot(), "tests/differential/sim.xfail" });
    const xfail = try readXfail(ra, io, xfail_path);
    const rulings_path = try std.fs.path.join(ra, &.{ repo_env.repoRoot(), "tests/differential/sim.rulings" });
    const rulings = try readXfail(ra, io, rulings_path);

    var fixture_arena: std.heap.ArenaAllocator = .init(gpa);
    defer fixture_arena.deinit();
    var agreed: usize = 0;
    var listed: usize = 0;
    var ruled: usize = 0;
    var bad: usize = 0;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    // `SIM_ONLY=<substring>`: run only the fixtures whose path holds it
    // (a debugging aid; the merge runs every fixture).
    const only = std.process.Environ.getPosix(std.testing.environ, "SIM_ONLY") orelse "";
    for (fixtures) |rel| {
        if (only.len != 0 and std.mem.find(u8, rel, only) == null) continue;
        _ = fixture_arena.reset(.retain_capacity);
        const a = fixture_arena.allocator();
        try seen.put(ra, rel, {});
        const ruling = rulings.get(rel) != null;
        const why = try isolated(a, io, root, rel, ruling);
        const reason = xfail.get(rel);
        if (why.len != 0) {
            if (ruling) {
                bad += 1;
                std.debug.print("diff-sim: RULING {s} does not hold: {s}\n", .{ rel, why });
                continue;
            }
            if (reason) |r| {
                listed += 1;
                // Not a failure: the listed reason went stale, say the new one.
                if (!std.mem.eql(u8, r, why)) std.debug.print("diff-sim: RELIST {s} {s}\n", .{ rel, why });
                continue;
            }
            bad += 1;
            std.debug.print("diff-sim: MISMATCH {s} {s}\n", .{ rel, why });
        } else if (ruling) {
            ruled += 1;
        } else if (reason) |r| {
            bad += 1;
            std.debug.print("diff-sim: XPASS {s} agrees; remove its sim.xfail line ({s})\n", .{ rel, r });
        } else agreed += 1;
    }
    if (only.len == 0) {
        var it = xfail.keyIterator();
        while (it.next()) |k| if (!seen.contains(k.*)) {
            bad += 1;
            std.debug.print("diff-sim: STALE {s} is in sim.xfail but not in the corpus\n", .{k.*});
        };
        var rit = rulings.keyIterator();
        while (rit.next()) |k| if (!seen.contains(k.*)) {
            bad += 1;
            std.debug.print("diff-sim: STALE {s} is in sim.rulings but not in the corpus\n", .{k.*});
        };
    }
    std.debug.print("diff-sim: {d} fixtures, {d} agreed, {d} listed in sim.xfail, {d} ruled by sim.rulings, {d} failed\n", .{ seen.count(), agreed, listed, ruled, bad });
    if (only.len == 0) try std.testing.expect(fixtures.len > 700);
    try std.testing.expectEqual(@as(usize, 0), bad);
}
