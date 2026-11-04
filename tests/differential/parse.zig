//! The differential oracle of `vams` tokenizer/Ast/Parse (docs/rewrite/parse.md):
//! every `.va`, `.vams` and `.v` fixture under the fixture root in, one line
//! per disagreement with lib/frontend's lexer and parser out, and a failure
//! unless each disagreeing fixture is named in `parse.xfail` (and each named
//! one still disagrees). The old preprocessor makes both sides' text; a
//! fixture it refuses is skipped and counted. Checks, in order: tokens (same
//! starts, tags related by `expectedTag`), acceptance (the old parser reports
//! an error iff `tree.errors` is not empty, or AstGen's per-file checks
//! fail the tree's Vir; an old error whose code a stage after AstGen owns,
//! by `stages.ownerUnder` and the fixture's `//! lrm` clauses, is that
//! stage's to raise and is set aside, named in the summary), structure (per
//! module: name and the counts `Shape` lists).
//! No LRM clause: this checks VerA's rewrite against VerA.
//!
//! Contents: tests only.
const std = @import("std");
const Io = std.Io;
const vams = @import("vams");
const frontend = @import("frontend");
const diag = @import("diag");
const options = @import("rewrite_options");
const settle = @import("settle.zig");
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

/// The per-module counts the structure check compares.
const Shape = struct {
    ports: u32 = 0,
    params: u32 = 0,
    nets: u32 = 0,
    vars: u32 = 0,
    branches: u32 = 0,
    instances: u32 = 0,
    analog: u32 = 0,
    discrete: u32 = 0,
    functions: u32 = 0,
    tasks: u32 = 0,
};

/// What the old parser knew of a header port while it folded body
/// declarations into it: whether it has a discipline, and (a digital
/// parse) whether a net type declaration completed it.
const PortState = struct { disc: bool, typed: bool };

/// Recounts a new module the way the old parser filled its `Body`: generate
/// blocks hoist branches and functions always, nets and processes in an
/// analog parse only; a net declaration naming a header port completes it.
const Counter = struct {
    arena: std.mem.Allocator,
    tree: *const vams.Ast,
    digital: bool,
    shape: Shape = .{},
    ports: std.StringHashMapUnmanaged(PortState) = .empty,
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

    var later: settle.Later = .{ .arena = arena };
    const fixtures = try collect(arena, io);
    var tally: Tally = .{};
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var per: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer per.deinit();
    for (fixtures) |rel| {
        _ = per.reset(.retain_capacity);
        const verdict = try checkFixture(per.allocator(), io, rel, &later) orelse {
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
    try later.print(&out.writer, "diff-parse");
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

/// Null when the old preprocessor refuses the fixture; else the verdict. An
/// old refusal by a later stage's codes alone counts them in `later`.
fn checkFixture(arena: std.mem.Allocator, io: Io, rel: []const u8, later: *settle.Later) !?Verdict {
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

    var p = frontend.Parser.Parser.init(arena, text, old_tags, old_starts, bag);
    p.digital = digital;
    p.setLanguage(if (digital) .v1364_2005 else .vams_2023);
    const old_file = p.parseSourceFile() catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.ParseError => null,
    };
    const tree = try vams.Ast.parse(arena, text, .{ .keywords = if (digital) .v1364_2005 else .vams_2023 });
    if (old_file == null and tree.errors.len == 0) {
        // A per-file rule the old parser judged by names is AstGen's now
        // (docs/rewrite/astgen.md): the new frontend rejects when Vir's does.
        const vir = try vams.AstGen.generate(arena, &tree, .{});
        if (vir.diag.failed()) return @as(Verdict, null);
        var errors: std.ArrayList([]const u8) = .empty;
        for (0..bag.count()) |i| if (bag.at(i).severity == .err) try errors.append(arena, @tagName(bag.at(i).code));
        const cited = try settle.clauses(arena, source);
        const c = try settle.codesDiffer(arena, errors.items, &.{}, .{ .first = .parse, .last = .astgen }, cited);
        if (c.why != null) return try firstOldError(arena, bag);
        try later.add(c.later, cited);
        return @as(Verdict, null);
    }
    if (old_file != null and tree.errors.len != 0) return try newErrorText(arena, &tree);
    const file = old_file orelse return @as(Verdict, null);
    const builtins: u32 = if (digital) 0 else frontend.annex_e.spice_module_count + pp.netlist_modules;
    return try compareStructure(arena, &file, builtins, &tree, digital);
}

fn firstOldError(arena: std.mem.Allocator, bag: *const diag.Bag) ![]const u8 {
    for (0..bag.count()) |i| {
        const e = bag.at(i);
        if (e.severity == .err) return try arena.print("acceptance: old rejects ({t}: {s}), new accepts", .{ e.code, e.message });
    }
    return "acceptance: old rejects (no error kept), new accepts";
}

fn newErrorText(arena: std.mem.Allocator, tree: *const vams.Ast) ![]const u8 {
    const e = tree.errors[0];
    const at = tree.tokenStart(e.token);
    var line: usize = 1;
    for (tree.source[0..at]) |c| line += @intFromBool(c == '\n');
    return try arena.print("acceptance: old accepts, new rejects ({t} at line {d} `{s}`)", .{ e.tag, line, tree.tokenSlice(e.token) });
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

fn compareStructure(arena: std.mem.Allocator, file: *const frontend.Ast.SourceFile, builtins: u32, tree: *const vams.Ast, digital: bool) !Verdict {
    var news: std.ArrayList(vams.Ast.Node.Index) = .empty;
    for (tree.rootDecls()) |d| if (tree.nodeTag(d) == .module_decl) try news.append(arena, d);
    if (file.modules.len != news.items.len) return try arena.print("structure: {d} modules old, {d} new", .{ file.modules.len, news.items.len });
    for (file.modules[builtins..], news.items[builtins..]) |om, nm| {
        const m = vams.Ast.full.moduleDecl(tree, nm);
        const name = try normalName(arena, tree, m.name);
        if (!std.mem.eql(u8, file.str(om.name), name)) return try arena.print("structure: module `{s}` old, `{s}` new", .{ file.str(om.name), name });
        const want: Shape = .{
            .ports = @intCast(om.ports.len),
            .params = @intCast(om.params.len),
            .nets = @intCast(om.nets.len),
            .vars = @intCast(om.vars.len),
            .branches = @intCast(om.branches.len),
            .instances = @intCast(om.instances.len),
            .analog = @intCast(om.analog.len),
            .discrete = @intCast(om.discrete.len),
            .functions = @intCast(om.functions.len),
            .tasks = @intCast(om.tasks.len),
        };
        var c: Counter = .{ .arena = arena, .tree = tree, .digital = digital };
        for (m.params) |d| c.shape.params += paramCount(tree, d);
        for (m.ports) |port| try headerPort(&c, port);
        try countItems(&c, m.items, false);
        inline for (@typeInfo(Shape).@"struct".field_names) |f| {
            if (@field(want, f) != @field(c.shape, f)) return try arena.print("structure: module `{s}`: {s} old {d}, new {d}", .{ name, f, @field(want, f), @field(c.shape, f) });
        }
    }
    return null;
}

/// A name token's text as the old parser interned it: an escaped
/// identifier without its `\`, each `.` in it a space.
fn normalName(arena: std.mem.Allocator, tree: *const vams.Ast, tok: vams.Ast.TokenIndex) ![]const u8 {
    const text = tree.tokenSlice(tok);
    if (tree.tokenTag(tok) != .escaped_identifier) return text;
    const out = try arena.dupe(u8, text[1..]);
    std.mem.replaceScalar(u8, out, '.', ' ');
    return out;
}

fn paramCount(tree: *const vams.Ast, d: vams.Ast.Node.Index) u32 {
    var n: u32 = 0;
    const spec = tree.tokenTag(tree.nodeMainToken(d)) == .keyword_specparam;
    for (vams.Ast.full.decl(tree, d).items) |a| {
        if (spec and std.mem.startsWith(u8, tree.tokenSlice(tree.nodeMainToken(a)), "PATHPULSE$")) continue;
        n += 1;
    }
    return n;
}

/// A header port: one old `Port` per port reference.
fn headerPort(c: *Counter, port: vams.Ast.Node.Index) !void {
    const tree = c.tree;
    switch (tree.nodeTag(port)) {
        .port, .named_port => {
            const e = tree.nodeData(port).opt_node.unwrap() orelse {
                c.shape.ports += 1;
                return;
            };
            const refs: []const vams.Ast.Node.Index = if (tree.nodeTag(e) == .concat) vams.Ast.full.list(tree, e) else &.{e};
            for (refs) |r| {
                c.shape.ports += 1;
                const base = switch (tree.nodeTag(r)) {
                    .identifier => r,
                    .index => tree.nodeData(r).node_and_node[0],
                    else => tree.nodeData(r).node_and_extra[0],
                };
                try addPort(c, tree.nodeMainToken(base), false);
            }
        },
        .port_decl => {
            const d = vams.Ast.full.decl(tree, port);
            const disc = portDisc(tree, d.main_token);
            for (d.items) |x| {
                c.shape.ports += 1;
                try addPort(c, tree.nodeMainToken(x), disc);
                if (variablePort(tree, d.main_token)) c.shape.vars += 1;
            }
        },
        else => unreachable,
    }
}

fn addPort(c: *Counter, tok: vams.Ast.TokenIndex, disc: bool) !void {
    const slot = try c.ports.getOrPut(c.arena, try normalName(c.arena, c.tree, tok));
    if (!slot.found_existing) slot.value_ptr.* = .{ .disc = disc, .typed = false };
}

/// A port declaration's `[discipline]`: a name another name follows.
fn portDisc(tree: *const vams.Ast, dir: vams.Ast.TokenIndex) bool {
    return tree.tokenTag(dir + 1) == .identifier and isName(tree.tokenTag(dir + 2));
}

/// A.2.1.2's variable arms: `reg`, `integer` or `time` after the direction,
/// discipline, net type and `signed`.
fn variablePort(tree: *const vams.Ast, dir: vams.Ast.TokenIndex) bool {
    var i = dir + 1;
    if (portDisc(tree, dir)) i += 1;
    while (true) : (i += 1) switch (tree.tokenTag(i)) {
        .keyword_wire, .keyword_tri, .keyword_tri0, .keyword_tri1, .keyword_triand, .keyword_trior, .keyword_trireg, .keyword_wand, .keyword_wor, .keyword_uwire, .keyword_supply0, .keyword_supply1, .keyword_wreal, .keyword_signed => {},
        .keyword_reg, .keyword_integer, .keyword_time => return true,
        else => return false,
    };
}

fn isName(tag: vams.Token.Tag) bool {
    return tag == .identifier or tag == .escaped_identifier;
}

fn countItems(c: *Counter, items: []const vams.Ast.Node.Index, in_block: bool) error{OutOfMemory}!void {
    const tree = c.tree;
    const full = vams.Ast.full;
    for (items) |item| switch (tree.nodeTag(item)) {
        .param_decl => if (!in_block) {
            c.shape.params += paramCount(tree, item);
        },
        .specify_block => if (!in_block) for (full.list(tree, item)) |s| {
            if (tree.nodeTag(s) == .param_decl) c.shape.params += paramCount(tree, s);
        },
        .var_decl => if (!in_block) {
            const d = full.decl(tree, item);
            c.shape.vars += @intCast(d.items.len);
            if (regDisc(tree, d.main_token)) for (d.items) |x| {
                if (c.ports.getPtr(try normalName(c.arena, tree, tree.nodeMainToken(x)))) |port| port.disc = true;
            };
        },
        .port_decl => {
            const d = full.decl(tree, item);
            const disc = portDisc(tree, d.main_token);
            for (d.items) |x| {
                if (variablePort(tree, d.main_token)) c.shape.vars += 1;
                if (!disc) continue;
                if (c.ports.getPtr(try normalName(c.arena, tree, tree.nodeMainToken(x)))) |port| port.disc = true;
            }
        },
        .net_decl => try countNets(c, item, in_block),
        .branch_decl => {
            const b = tree.extraData(tree.nodeData(item).extra, vams.Ast.Node.Branch);
            c.shape.branches += @backingInt(b.items_end) - @backingInt(b.items_start);
        },
        .module_instantiation => if (!in_block) {
            const x = tree.extraData(tree.nodeData(item).extra, vams.Ast.Node.Instantiation);
            c.shape.instances += @backingInt(x.items_end) - @backingInt(x.items_start);
        },
        .udp_instantiation => if (!in_block and c.digital) {
            c.shape.instances += @intCast(full.decl(tree, item).items.len);
        },
        .analog, .analog_initial => if (!in_block) {
            c.shape.analog += 1;
        },
        .initial, .always => if (!in_block or !c.digital) {
            c.shape.discrete += 1;
        },
        .function_decl => {
            if (tree.tokenTag(tree.nodeMainToken(item)) == .keyword_analog or !c.digital) {
                c.shape.functions += 1;
            } else if (!in_block) c.shape.tasks += 1;
        },
        .task_decl => if (!in_block) {
            c.shape.tasks += 1;
        },
        .generate_region => try countItems(c, full.list(tree, item), in_block),
        .generate_for, .generate_if, .generate_case => {
            if (!in_block) c.shape.analog += 1;
            switch (tree.nodeTag(item)) {
                .generate_for => try countBody(c, tree.extraData(tree.nodeData(item).extra, vams.Ast.Node.For).body),
                .generate_if => {
                    const x = tree.extraData(tree.nodeData(item).node_and_extra[1], vams.Ast.Node.If);
                    try countBody(c, x.then);
                    if (x.@"else".unwrap()) |e| try countBody(c, e);
                },
                else => {
                    const arms = tree.extraData(tree.nodeData(item).node_and_extra[1], vams.Ast.Node.SubRange);
                    for (tree.extraDataSlice(arms, vams.Ast.Node.Index)) |arm| try countBody(c, tree.nodeData(arm).extra_and_node[1]);
                },
            }
        },
        else => {},
    };
}

/// A generate block, whose items are counted as the old parser hoisted them.
fn countBody(c: *Counter, body: vams.Ast.Node.Index) error{OutOfMemory}!void {
    switch (c.tree.nodeTag(body)) {
        .generate_block => try countItems(c, vams.Ast.full.list(c.tree, body), true),
        .null_stmt => {},
        else => try countItems(c, &.{body}, true),
    }
}

/// Net declarations: a name that is a header port without a discipline
/// completes the port (no net row unless it has a nodeset); any other
/// name is a net, a generate block's only in an analog parse.
fn countNets(c: *Counter, item: vams.Ast.Node.Index, in_block: bool) !void {
    const tree = c.tree;
    const main = tree.nodeMainToken(item);
    const ground = tree.tokenTag(main) == .keyword_ground;
    const disc = netDisc(tree, main);
    const x = tree.extraData(tree.nodeData(item).extra, vams.Ast.Node.NetDecl);
    for (tree.extraDataSlice(.{ .start = x.items_start, .end = x.items_end }, vams.Ast.Node.Index)) |d| {
        const name = tree.nodeMainToken(d);
        const init = tree.nodeData(d).extra_and_opt_node[1] != .none;
        const dotted = tree.tokenTag(name + 1) == .period;
        const port = if (ground or in_block or dotted) null else c.ports.getPtr(try normalName(c.arena, tree, name));
        if (port) |pt| if (!pt.disc and (!pt.typed or disc)) {
            pt.disc = disc;
            if (c.digital) pt.typed = true;
            if (init) c.shape.nets += 1;
            continue;
        };
        if (!in_block or !c.digital) c.shape.nets += 1;
    }
}

/// Whether a net declaration names a discipline.
fn netDisc(tree: *const vams.Ast, main: vams.Ast.TokenIndex) bool {
    switch (tree.tokenTag(main)) {
        .identifier, .escaped_identifier => return true,
        .keyword_ground, .keyword_wreal => return portDisc(tree, main),
        else => {},
    }
    var i = main + 1;
    if (tree.tokenTag(i) == .l_paren) {
        while (tree.tokenTag(i) != .r_paren) i += 1;
        i += 1;
    }
    if (tree.tokenTag(i) == .keyword_vectored or tree.tokenTag(i) == .keyword_scalared) i += 1;
    return tree.tokenTag(i) == .identifier and isName(tree.tokenTag(i + 1));
}

/// A `reg`'s discipline: a name followed by a name, `signed`, or a range a
/// name follows.
fn regDisc(tree: *const vams.Ast, main: vams.Ast.TokenIndex) bool {
    if (tree.tokenTag(main) != .keyword_reg or !isName(tree.tokenTag(main + 1))) return false;
    var i = main + 2;
    if (tree.tokenTag(i) == .keyword_signed) return true;
    if (tree.tokenTag(i) == .l_bracket) {
        while (tree.tokenTag(i) != .r_bracket) i += 1;
        i += 1;
    }
    return isName(tree.tokenTag(i));
}

test "diff-parse: vams tokenizer and Ast.parse agree with lib/frontend on every fixture" {
    var result: anyerror!void = {};
    // Compilation's workers parse on a 256 MiB stack; nesting past
    // `Parse.max_depth` is an error, not a crash.
    const t = try std.Thread.spawn(.{ .stack_size = 256 << 20 }, run, .{&result});
    t.join();
    try result;
}

test {
    // The stage-ownership table's own tests.
    _ = settle.stages;
}
