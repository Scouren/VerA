//! The errors job (lib/TODO.md §3, Zig's `Compilation.getAllErrorsAlloc`):
//! every stage's diagnostics in, one `Diag` bundle out, each location moved
//! from the stage's own text (the preprocessed text, a Vir instruction, a
//! netlist file) to the original file the user wrote, then sorted in
//! source order by `Wip.toOwnedBundle`. The file table it indexes is
//! `sources`: the preprocessor's files, then the netlist's.
//!
//! Cites no LRM clause: the stages cite theirs.
//!
//! Contents:
//! - `pub fn bundle(comp: *Compilation) Allocator.Error!Diag`
//! - `pub fn sources(comp: *Compilation) Allocator.Error![]const Diag.Source`
//! - `pub fn relocate(out: vams.Preprocessor.Output, start: u32, end: u32) Diag.Loc`
//! - `pub fn instLoc(out: vams.Preprocessor.Output, u: *const Compilation.Unit, src: Inst.Ref) Diag.Loc`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const sema = @import("sema");
const Compilation = @import("../Compilation.zig");
const Diag = vams.Diag;
const Inst = vams.Vir.Inst;
const legacy = @import("legacy.zig");

/// Every diagnostic of `comp`, relocated and sorted; owned by the caller.
pub fn bundle(comp: *Compilation) Allocator.Error!Diag {
    var w: Diag.Wip = .init(comp.gpa);
    defer w.deinit();
    w.levels = comp.config.levels;
    const out = comp.pp.output();
    const pp_files: u32 = @intCast(out.files.len);
    for (out.diagnostics) |d| {
        const code = std.meta.stringToEnum(Diag.Code, d.code) orelse unreachable; // The preprocessor reports catalogue codes.
        const loc: Diag.Loc = if (d.file == .none) .none else .{ .file = @fromBackingInt(@backingInt(d.file)), .start = source(out, d.file, d.start), .end = source(out, d.file, d.end) };
        var b = w.build(.preprocess, code, loc);
        b.msg("{s}", .{d.message});
        for (d.notes) |n| b.note("{s}", .{n});
        if (d.label) |l| b.label(.{ .file = loc.file, .start = source(out, d.file, l.start), .end = source(out, d.file, l.end) }, "{s}", .{l.text});
        try b.emit();
    }
    if (comp.netlist) |*n| try n.output().report(&w, @fromBackingInt(pp_files));
    for (comp.units.items) |*u| {
        if (u.tree.errors.len != 0) {
            var pw: Diag.Wip = .init(comp.gpa);
            defer pw.deinit();
            try vams.Ast.parse_errors.report(&u.tree, &pw);
            var parsed = try pw.toOwnedBundle();
            defer parsed.deinit(comp.gpa);
            try copy(&w, parsed, out);
        }
        // On the IEEE 1364 route a code `legacy` rewords takes the old
        // engine's words, naming the unit text under its caret.
        try copyAs(&w, u.vir.diag, out, if (comp.config.digital()) u.text else null);
    }
    const zf = comp.zcu.failed.slice();
    const ip = &comp.zcu.intern_pool;
    // lib/sim/digital stopped at its first refusal: the 1364 route reports
    // elaboration's first error and every warning.
    var refused = false;
    for (zf.items(.code), zf.items(.file), zf.items(.src), zf.items(.message), zf.items(.rule), zf.items(.name), zf.items(.nums), zf.items(.part), zf.items(.note), zf.items(.help)) |code, file, src, message, rule, name, nums, part, note, help| {
        const u = &comp.units.items[@backingInt(file)];
        const is_error = @tagName(code)[0] == 'E';
        if (comp.config.digital() and is_error) {
            if (refused) continue;
            refused = true;
        }
        const loc = partLoc(out, u, src, part);
        if (rule != .none and comp.config.digital()) {
            try legacy.rule(&w, rule, loc, ip.stringToSlice(name), nums, try legacy.searchOrder(comp.arena(), &comp.zcu));
        } else {
            var b = w.build(.lower, code, loc);
            b.msg("{s}", .{ip.stringToSlice(message)});
            if (note != .empty) b.note("{s}", .{ip.stringToSlice(note)});
            if (help != .empty) b.help("{s}", .{ip.stringToSlice(help)});
            try b.emit();
        }
    }
    var own = try comp.wip.toOwnedBundle();
    defer own.deinit(comp.gpa);
    try copyAs(&w, own, null, null);
    return w.toOwnedBundle();
}

/// The file table `bundle`'s locations index, in the arena.
pub fn sources(comp: *Compilation) Allocator.Error![]const Diag.Source {
    const a = comp.arena();
    const out = comp.pp.output();
    const net: []const vams.spice.File = if (comp.netlist) |*n| n.output().files else &.{};
    const list = try a.alloc(Diag.Source, out.files.len + net.len);
    for (list[0..out.files.len], out.files) |*s, f| s.* = .{ .name = f.name, .text = f.source, .line_starts = try Diag.lineStarts(a, f.source) };
    for (list[out.files.len..], net) |*s, f| s.* = .{ .name = f.name, .text = f.text, .line_starts = try Diag.lineStarts(a, f.text) };
    assert(list.len == out.files.len + net.len);
    return list;
}

/// A preprocessed-text range as a range of the original file its start
/// came from; an end in another file collapses to the start.
pub fn relocate(out: vams.Preprocessor.Output, start: u32, end: u32) Diag.Loc {
    if (out.source_map.len == 0) return .none;
    const s = out.resolve(@min(start, @as(u32, @intCast(out.text.len))));
    const e = out.resolve(@min(@max(start, end), @as(u32, @intCast(out.text.len))));
    const from = source(out, s.file, s.offset);
    const to = if (e.file == s.file) source(out, e.file, e.offset) else from;
    return .{ .file = @fromBackingInt(@backingInt(s.file)), .start = from, .end = @max(from, to) };
}

/// Where Vir instruction `src` of unit `u` was written, as the old
/// compiler located it: a statement `<+` at its target's first byte (no
/// width), a call at its callee's name, anything else at its main token.
pub fn instLoc(out: vams.Preprocessor.Output, u: *const Compilation.Unit, src: Inst.Ref) Diag.Loc {
    const i = src.toIndex() orelse return .none;
    const tag = u.vir.instructions.items(.tag)[@backingInt(i)];
    if (tag == .contrib or tag == .contrib_indirect) {
        const at_payload = u.vir.instructions.items(.data)[@backingInt(i)].pl_node.payload_index;
        const lhs = if (tag == .contrib) u.vir.extraData(Inst.Bin, at_payload).lhs else u.vir.extraData(Inst.Triple, at_payload).a;
        const t = instToken(u, lhs) orelse return .none;
        const at = u.tree.tokenStart(t);
        return relocate(out, at, at);
    }
    const t = instToken(u, src) orelse return .none;
    const at = u.tree.tokenStart(t);
    return relocate(out, at, at + @as(u32, @intCast(u.tree.tokenSlice(t).len)));
}

// ---- private ----

/// Where part `part` of instance `src` was written, as the old elaborators
/// located it: the first token of its k-th connection or parameter value
/// (a named one's `.`); the instance itself for `.whole`, or when the
/// list cannot be found.
fn partLoc(out: vams.Preprocessor.Output, u: *const Compilation.Unit, src: Inst.Ref, part: sema.Zcu.Part) Diag.Loc {
    const k: u32, const list_open: ?vams.Ast.TokenIndex = switch (part) {
        .whole => return instLoc(out, u, src),
        .target => return targetLoc(out, u, src),
        .attr => |k| return attrLoc(out, u, src, k),
        .conn => |k| .{ k, connOpen(u, src) },
        .param => |k| .{ k, paramOpen(u, src) },
    };
    const t = itemStart(&u.tree, list_open orelse return instLoc(out, u, src), k) orelse return instLoc(out, u, src);
    const at = u.tree.tokenStart(t);
    return relocate(out, at, at + @as(u32, @intCast(u.tree.tokenSlice(t).len)));
}

/// A defparam's target name (the lhs before its `=`), from its first
/// token; the defparam itself when it is not one.
fn targetLoc(out: vams.Preprocessor.Output, u: *const Compilation.Unit, src: Inst.Ref) Diag.Loc {
    const eq = instToken(u, src) orelse return instLoc(out, u, src);
    if (u.tree.tokenTag(eq) != .equal) return instLoc(out, u, src);
    var t = eq;
    var depth: u32 = 0;
    // Bounded by `eq`: each turn moves one token back.
    while (t > 0) : (t -= 1) switch (u.tree.tokenTag(t - 1)) {
        .r_bracket => depth += 1,
        .l_bracket => depth -|= 1,
        .comma, .keyword_defparam => if (depth == 0) break,
        else => {},
    };
    const at = u.tree.tokenStart(t);
    return relocate(out, at, at + @as(u32, @intCast(u.tree.tokenSlice(t).len)));
}

/// The name of the k-th attribute spec in the `(* ... *)` instances just
/// before the declaration or instance `src` (no `;` between); `src` itself
/// when there is none.
fn attrLoc(out: vams.Preprocessor.Output, u: *const Compilation.Unit, src: Inst.Ref, k: u32) Diag.Loc {
    const tree = &u.tree;
    var t = instToken(u, src) orelse return instLoc(out, u, src);
    // Bounded by `t`: back to the last `*)` before the item.
    while (t > 0 and tree.tokenTag(t) != .asterisk_r_paren) : (t -= 1) {
        if (tree.tokenTag(t) == .semicolon) return instLoc(out, u, src);
    }
    if (t == 0) return instLoc(out, u, src);
    // Back over the run of instances, to the first `(*`.
    var first = t;
    // Bounded by `t`: each turn moves one token back.
    while (first > 0) : (first -= 1) {
        if (tree.tokenTag(first) == .l_paren_asterisk and (first == 0 or tree.tokenTag(first - 1) != .asterisk_r_paren)) break;
    }
    var n: u32 = 0;
    var depth: u32 = 0;
    var i = first;
    // Bounded by `t`: each turn moves one token on.
    while (i < t) : (i += 1) switch (tree.tokenTag(i)) {
        .l_paren_asterisk => if (n == k) return tokenLoc(out, tree, i + 1),
        .asterisk_r_paren => n += 1,
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) {
            n += 1;
            if (n == k) return tokenLoc(out, tree, i + 1);
        },
        else => {},
    };
    return instLoc(out, u, src);
}

fn tokenLoc(out: vams.Preprocessor.Output, tree: *const vams.Ast, t: vams.Ast.TokenIndex) Diag.Loc {
    const at = tree.tokenStart(t);
    return relocate(out, at, at + @as(u32, @intCast(tree.tokenSlice(t).len)));
}

/// The `instance` node of Vir instance `src`, or null.
fn instanceNode(u: *const Compilation.Unit, src: Inst.Ref) ?vams.Ast.Node.Index {
    const i = src.toIndex() orelse return null;
    if (u.vir.instructions.items(.tag)[@backingInt(i)] != .instance) return null;
    const n = u.vir.instructions.items(.data)[@backingInt(i)].pl_node.src_node;
    return if (u.tree.nodeTag(n) == .instance) n else null;
}

/// The `(` of instance `src`'s connection list: past its name and range.
fn connOpen(u: *const Compilation.Unit, src: Inst.Ref) ?vams.Ast.TokenIndex {
    const n = instanceNode(u, src) orelse return null;
    var t = u.tree.nodeMainToken(n) + 1;
    var depth: u32 = 0;
    // Bounded by the token count: each turn moves one token on.
    while (u.tree.tokenTag(t) != .eof) : (t += 1) switch (u.tree.tokenTag(t)) {
        .l_bracket => depth += 1,
        .r_bracket => depth -|= 1,
        .l_paren => if (depth == 0) return t,
        else => {},
    };
    return null;
}

/// The `(` after `#` of the instantiation that lists instance `src`.
fn paramOpen(u: *const Compilation.Unit, src: Inst.Ref) ?vams.Ast.TokenIndex {
    const n = instanceNode(u, src) orelse return null;
    const tree = &u.tree;
    const tags = tree.nodes.items(.tag);
    // Bounded by the node count; a refusal's location only.
    for (tags, 0..) |tag, j| if (tag == .module_instantiation) {
        const m: vams.Ast.Node.Index = @fromBackingInt(@intCast(j));
        const x = tree.extraData(tree.nodeData(m).extra, vams.Ast.Node.Instantiation);
        for (tree.extraDataSlice(.{ .start = x.items_start, .end = x.items_end }, vams.Ast.Node.Index)) |it| if (it == n) {
            const hash = tree.nodeMainToken(m) + 1;
            return if (tree.tokenTag(hash) == .hash and tree.tokenTag(hash + 1) == .l_paren) hash + 1 else null;
        };
    };
    return null;
}

/// The first token of item `k` of the comma list that `open` opens, past
/// its attribute instances; null past the list's end.
fn itemStart(tree: *const vams.Ast, open: vams.Ast.TokenIndex, k: u32) ?vams.Ast.TokenIndex {
    var t = open + 1;
    var n: u32 = 0;
    var depth: u32 = 0;
    // Bounded by the token count: each turn moves one token on.
    while (tree.tokenTag(t) != .eof) : (t += 1) {
        if (n == k and depth == 0) {
            // Bounded by the token count, past `(* ... *)` runs.
            while (tree.tokenTag(t) == .l_paren_asterisk) {
                while (tree.tokenTag(t) != .asterisk_r_paren and tree.tokenTag(t) != .eof) t += 1;
                if (tree.tokenTag(t) == .eof) return null;
                t += 1;
            }
            return t;
        }
        switch (tree.tokenTag(t)) {
            .l_paren, .l_bracket, .l_brace, .l_paren_asterisk => depth += 1,
            .r_paren, .r_bracket, .r_brace, .asterisk_r_paren => if (depth == 0) return null else {
                depth -= 1;
            },
            .comma => n += @intFromBool(depth == 0),
            else => {},
        }
    }
    return null;
}

/// Every message of `d`, located in a unit's preprocessed text, into `w`.
fn copy(w: *Diag.Wip, d: Diag, out: vams.Preprocessor.Output) Allocator.Error!void {
    try copyAs(w, d, out, null);
}

/// Copies each message of `d` with its labels and notes; with `out`, every
/// location is a preprocessed-text range and moves to its original file.
fn copyAs(w: *Diag.Wip, d: Diag, out: ?vams.Preprocessor.Output, route: ?[]const u8) Allocator.Error!void {
    for (d.messages()) |i| {
        const m = d.message(i);
        if (route) |t| if (legacy.byCode(m.tag.code)) {
            try legacy.code(w, m.tag.code, move(out, m.loc), t[m.loc.start..m.loc.end]);
            continue;
        };
        var b = w.build(m.tag.stage, m.tag.code, move(out, m.loc));
        if (m.msg != .none) b.msg("{s}", .{d.string(m.msg)});
        if (m.point != .none) b.point("{s}", .{d.string(m.point)});
        for (d.labels(i)) |l| b.label(move(out, l.loc), "{s}", .{d.string(l.text)});
        for (d.notes(i)) |n| {
            if (n.replacement != .none) {
                b.suggest(.{ .loc = move(out, n.fix), .replacement = d.string(n.replacement) }, "{s}", .{d.string(n.text)});
            } else if (n.kind == .note) b.note("{s}", .{d.string(n.text)}) else b.help("{s}", .{d.string(n.text)});
        }
        try b.emit();
    }
}

fn move(out: ?vams.Preprocessor.Output, loc: Diag.Loc) Diag.Loc {
    const o = out orelse return loc;
    if (loc.isNone()) return loc;
    return relocate(o, loc.start, loc.end);
}

/// A stripped-text offset of `file` as an offset of its original bytes.
fn source(out: vams.Preprocessor.Output, file: vams.Preprocessor.File.Index, offset: u32) u32 {
    return vams.Preprocessor.toSourceOffset(out.files[@backingInt(file)].marks, offset);
}

/// The token instruction `ref` names: its main token, or for a call (whose
/// main token is its `(`) the callee's name; null for a literal.
fn instToken(u: *const Compilation.Unit, ref: Inst.Ref) ?vams.Ast.TokenIndex {
    const i = ref.toIndex() orelse return null;
    const data = u.vir.instructions.items(.data)[@backingInt(i)];
    const tok: vams.Ast.TokenIndex = switch (Inst.dataKind(u.vir.instructions.items(.tag)[@backingInt(i)])) {
        .pl_node => u.tree.nodeMainToken(data.pl_node.src_node),
        .un_node => u.tree.nodeMainToken(data.un_node.src_node),
        .decl_tok => data.decl_tok.src_tok,
        .str_tok => data.str_tok.src_tok,
        .int, .float, .str => return null,
    };
    return if (tok > 0 and u.tree.tokenTag(tok) == .l_paren) tok - 1 else tok;
}
