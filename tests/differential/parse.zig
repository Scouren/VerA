//! The differential oracle of `vams` tokenizer/Ast/Parse (docs/rewrite/parse.md):
//! every `.va`, `.vams` and `.v` fixture under the fixture root in, one line
//! per disagreement with lib/frontend's lexer and parser out, and a failure
//! unless each disagreeing fixture is named in `parse.xfail` (and each named
//! one still disagrees). The old preprocessor makes both sides' text; a
//! fixture it refuses is skipped and counted. Checks, in order: tokens (same
//! starts, tags related by `expectedTag`), acceptance (the old parser reports
//! an error iff `tree.errors` is not empty), structure (per module: name and
//! the counts `Shape` lists).
//! No LRM clause: this checks VerA's rewrite against VerA.
//!
//! Contents: tests only.
const std = @import("std");
const Io = std.Io;
const vams = @import("vams");
const frontend = @import("frontend");
const diag = @import("diag");
const options = @import("rewrite_options");
const OldTag = frontend.token.Tag;
const NewTag = vams.Token.Tag;

/// One fixture's verdict: null when every check agrees, else the first
/// disagreement.
const Verdict = ?[]const u8;

const Tally = struct {
    compared: u32 = 0,
    skipped: u32 = 0,
    agreed: u32 = 0,
    xfailed: u32 = 0,
    failed: u32 = 0,
};

const directive_tags = std.StaticStringMap(NewTag).initComptime(.{
    .{ "`default_nettype", .directive_default_nettype },
    .{ "`unconnected_drive", .directive_unconnected_drive },
    .{ "`nounconnected_drive", .directive_nounconnected_drive },
    .{ "`default_transition", .directive_default_transition },
});

/// A.7's three symbols the old lexer had no tag for.
const invalid_tags = std.StaticStringMap(NewTag).initComptime(.{
    .{ "=>", .equal_angle_bracket_right },
    .{ "*>", .asterisk_angle_bracket_right },
    .{ "&&&", .ampersand_ampersand_ampersand },
});

/// Old tag -> new tag. Keywords map by spelling (`kw_X` to `keyword_X`, or
/// `keyword_builtin` for an A.8.2 call name); every other row is listed,
/// and a row missing on either side fails to compile.
const tag_map = map: {
    @setEvalBranchQuota(100_000);
    const rows = .{
        .{ "invalid", "invalid" },                                          .{ "eof", "eof" },                                 .{ "identifier", "identifier" },
        .{ "escaped_identifier", "escaped_identifier" },                    .{ "system_identifier", "system_identifier" },     .{ "int_literal", "number_literal" },
        .{ "real_literal", "number_literal" },                              .{ "string_literal", "string_literal" },           .{ "plus", "plus" },
        .{ "minus", "minus" },                                              .{ "star", "asterisk" },                           .{ "slash", "slash" },
        .{ "percent", "percent" },                                          .{ "star_star", "asterisk_asterisk" },             .{ "contribute", "angle_bracket_left_plus" },
        .{ "arrow", "minus_angle_bracket_right" },                          .{ "assign_eq", "equal" },                         .{ "lt", "angle_bracket_left" },
        .{ "gt", "angle_bracket_right" },                                   .{ "lt_eq", "angle_bracket_left_equal" },          .{ "gt_eq", "angle_bracket_right_equal" },
        .{ "eq_eq", "equal_equal" },                                        .{ "bang_eq", "bang_equal" },                      .{ "eq_eq_eq", "equal_equal_equal" },
        .{ "bang_eq_eq", "bang_equal_equal" },                              .{ "bang", "bang" },                               .{ "amp_amp", "ampersand_ampersand" },
        .{ "pipe_pipe", "pipe_pipe" },                                      .{ "tilde", "tilde" },                             .{ "amp", "ampersand" },
        .{ "pipe", "pipe" },                                                .{ "caret", "caret" },                             .{ "tilde_caret", "tilde_caret" },
        .{ "caret_tilde", "caret_tilde" },                                  .{ "tilde_amp", "tilde_ampersand" },               .{ "tilde_pipe", "tilde_pipe" },
        .{ "lt_lt", "angle_bracket_angle_bracket_left" },                   .{ "gt_gt", "angle_bracket_angle_bracket_right" }, .{ "lt_lt_lt", "angle_bracket_angle_bracket_angle_bracket_left" },
        .{ "gt_gt_gt", "angle_bracket_angle_bracket_angle_bracket_right" }, .{ "question", "question_mark" },                  .{ "colon", "colon" },
        .{ "lparen", "l_paren" },                                           .{ "rparen", "r_paren" },                          .{ "lbracket", "l_bracket" },
        .{ "rbracket", "r_bracket" },                                       .{ "lbrace", "l_brace" },                          .{ "rbrace", "r_brace" },
        .{ "semicolon", "semicolon" },                                      .{ "comma", "comma" },                             .{ "dot", "period" },
        .{ "at", "at_sign" },                                               .{ "hash", "hash" },                               .{ "apostrophe_lbrace", "apostrophe_l_brace" },
        .{ "attr_open", "l_paren_asterisk" },                               .{ "attr_close", "asterisk_r_paren" },             .{ "dir_begin_keywords", "directive_begin_keywords" },
        .{ "dir_end_keywords", "directive_end_keywords" },                  .{ "dir_resetall", "directive_resetall" },
    };
    var m: std.enums.EnumArray(OldTag, ?NewTag) = .initFill(null);
    for (rows) |r| m.set(@field(OldTag, r[0]), @field(NewTag, r[1]));
    for (@typeInfo(OldTag).@"enum".field_names) |f| {
        if (!std.mem.startsWith(u8, f, "kw_") or std.mem.eql(u8, f, "kw_reserved")) continue;
        const word = f[3..];
        const builtin = for (vams.tokenizer.builtin_names) |b| {
            if (std.mem.eql(u8, b, word)) break true;
        } else false;
        m.set(@field(OldTag, f), if (builtin) .keyword_builtin else @field(NewTag, "keyword_" ++ word));
    }
    for (@typeInfo(OldTag).@"enum".field_names) |f| {
        const text_picks = std.mem.eql(u8, f, "kw_reserved") or std.mem.eql(u8, f, "dir_outside_module");
        if (m.get(@field(OldTag, f)) == null and !text_picks) @compileError("no new tag for old ." ++ f);
    }
    break :map m;
};

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

    const xfail_path = try std.fs.path.join(arena, &.{ options.repo_root, "tests/differential/parse.xfail" });
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
        const verdict = try checkFixture(per.allocator(), io, rel) orelse {
            tally.skipped += 1;
            continue;
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
            try out.writer.print("XPASS {s}: agrees now; delete its parse.xfail line\n", .{rel});
        } else tally.agreed += 1;
    }
    var it = xfail.keyIterator();
    while (it.next()) |k| if (!seen.contains(k.*)) {
        tally.failed += 1;
        try out.writer.print("STALE {s}: parse.xfail names a fixture that was not compared\n", .{k.*});
    };
    std.debug.print("{s}diff-parse: {d} fixtures compared, {d} agree, {d} listed in parse.xfail, {d} skipped (old preprocessor refused), {d} failures\n", .{ out.written(), tally.compared, tally.agreed, tally.xfailed, tally.skipped, tally.failed });
    if (tally.failed != 0) return error.DiffParseFailed;
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

/// Null when the old preprocessor refuses the fixture; else the verdict.
fn checkFixture(arena: std.mem.Allocator, io: Io, rel: []const u8) !?Verdict {
    const path = try std.fs.path.join(arena, &.{ options.fixture_root, rel });
    const digital = std.mem.eql(u8, std.fs.path.extension(rel), ".v");
    const source = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 26));
    const bag = try arena.create(diag.Bag);
    bag.* = .init(arena);
    var files: frontend.Files = .init(io, arena);
    const pp = frontend.preprocessor.process(arena, source, .{
        .include_dirs = &.{ std.fs.path.dirname(path).?, options.fixture_root ++ "/include" },
        .file_name = path,
        .std_defs = !digital,
        .spice_primitives = !digital,
        .bag = bag,
        .files = &files,
    }) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.PreprocessFailed => return null,
    };
    const text = try arena.dupeSentinel(u8, pp.text, 0);

    var old_tokens = try frontend.lexer.tokenize(arena, text, null);
    const old_tags = old_tokens.items(.tag);
    const old_starts = old_tokens.items(.start);
    if (try tokensDiffer(arena, text, old_tags, old_starts)) |why| return why;

    return @as(Verdict, null);
}

/// The first token whose start or tag disagrees, as text.
fn tokensDiffer(arena: std.mem.Allocator, text: [:0]const u8, old_tags: []const OldTag, old_starts: []const u32) !Verdict {
    var tz: vams.Tokenizer = .init(text);
    for (old_tags, old_starts, 0..) |old, start, i| {
        const new = tz.next();
        const want = expectedTag(old, frontend.lexer.tokenText(text, start));
        if (new.loc.start != start or new.tag != want)
            return try arena.print("tokens: token {d}: old {t} at {d}, new {t} at {d} (expected {t})", .{ i, old, start, new.tag, new.loc.start, want });
    }
    return null;
}

/// The new tag the old token `old` with source `text` must have: the
/// mapping table, one row per old tag, and the four old tags whose text
/// picks the new one.
fn expectedTag(old: OldTag, text: []const u8) NewTag {
    return switch (old) {
        .kw_reserved => vams.Token.getKeyword(text) orelse .invalid,
        .dir_outside_module => directive_tags.get(text) orelse .invalid,
        .invalid => invalid_tags.get(text) orelse .invalid,
        else => tag_map.get(old).?,
    };
}

test "diff-parse: vams tokenizer and Ast.parse agree with lib/frontend on every fixture" {
    var result: anyerror!void = {};
    // Compilation's workers parse on a 256 MiB stack; nesting past
    // `Parse.max_depth` is an error, not a crash.
    const t = try std.Thread.spawn(.{ .stack_size = 256 << 20 }, run, .{&result});
    t.join();
    try result;
}
