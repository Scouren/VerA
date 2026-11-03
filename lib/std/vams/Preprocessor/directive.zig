//! Compiler directives: one '`'-led word and its logical line in, its effect
//! out (a conditional level pushed or popped, an `include scanned
//! (Preprocessor/include.zig), a `Directives` event recorded
//! (Preprocessor/handlers.zig), a §28 envelope decrypted and scanned, or the
//! word handed to Preprocessor/macro.zig as a macro use). `directive` is the
//! dispatch; the conditionals follow it.
//! Cites: LRM §10.1 Table 10-1, §10.2, §10.3, §10.6; IEEE 1364-2005 §19.1,
//! §19.2, §19.4 Syntax 19-5, §19.6, §19.9, §19.10, §28.2, §28.4.
//!
//! Contents:
//! - `pub const Directive = enum(u8)`, `Directive.marksRegion(kind: Directive) bool`
//! - `pub const directive_map: std.StaticStringMap(Directive)`
//! - `pub fn directive(pp: *Pass, text: []const u8, at: usize) Error!usize`
//! - `pub fn logicalLineEnd(text: []const u8, i: usize) usize`

const std = @import("std");
const assert = std.debug.assert;
const Pass = @import("Pass.zig");
const Error = Pass.Error;
const events = @import("events.zig");
const scan = @import("scan.zig");
const Rest = scan.Rest;
const macro = @import("macro.zig");
const include = @import("include.zig");
const handlers = @import("handlers.zig");
const protect = @import("protect.zig");
const File = @import("../Preprocessor.zig").File;

/// Directives handled here. LRM §10 Table 10-1.
pub const Directive = enum(u8) {
    define, // §10.4
    undef, // §10.4
    ifdef, // IEEE 1364 §19.4
    ifndef,
    elsif,
    @"else",
    endif,
    include, // IEEE 1364 §19.5
    resetall, // IEEE 1364 §19.6: directive state only; §19.3 keeps macros
    keywords, // §10.6: emitted verbatim for the parser
    default_discipline, // §10.2
    default_transition, // §10.3
    line, // IEEE 1364 §19.7
    timescale, // IEEE 1364 §19.8
    default_nettype, // IEEE 1364 §19.2
    celldefine, // IEEE 1364 §19.1
    endcelldefine,
    unconnected_drive, // IEEE 1364 §19.9
    nounconnected_drive,
    pragma, // IEEE 1364 §19.10: no effect, except §28's `protect`

    /// Returns whether the directive records a `Directives` event, a region
    /// that opens at its own offset in the output.
    pub fn marksRegion(kind: Directive) bool {
        return switch (kind) {
            .resetall, .default_discipline, .default_transition, .timescale => true,
            .default_nettype, .celldefine, .endcelldefine => true,
            .unconnected_drive, .nounconnected_drive => true,
            .define, .undef, .ifdef, .ifndef, .elsif, .@"else", .endif => false,
            .include, .keywords, .line, .pragma => false,
        };
    }
};

/// Directive name, without its backtick, to kind.
pub const directive_map = std.StaticStringMap(Directive).initComptime(.{
    .{ "define", .define },
    .{ "undef", .undef },
    .{ "ifdef", .ifdef },
    .{ "ifndef", .ifndef },
    .{ "elsif", .elsif },
    .{ "else", .@"else" },
    .{ "endif", .endif },
    .{ "include", .include },
    .{ "resetall", .resetall },
    // §10.6: which words are reserved, and where, is the parser's question.
    .{ "begin_keywords", .keywords },
    .{ "end_keywords", .keywords },
    .{ "default_discipline", .default_discipline },
    .{ "line", .line },
    .{ "default_transition", .default_transition },
    .{ "timescale", .timescale },
    .{ "default_nettype", .default_nettype },
    .{ "celldefine", .celldefine },
    .{ "endcelldefine", .endcelldefine },
    .{ "unconnected_drive", .unconnected_drive },
    .{ "nounconnected_drive", .nounconnected_drive },
    // §19.10: an unrecognized pragma "shall have no effect".
    .{ "pragma", .pragma },
});

/// Handles the directive or macro use whose '`' is at `at` and returns the
/// offset to resume scanning from, always past `at`. Inside an inactive arm
/// only the conditionals act; every other directive emits its newlines. In
/// an active arm a '`' followed by no name is E0103; each handler names its
/// own failures. Asserts that `text[at]` is the '`'.
pub fn directive(pp: *Pass, text: []const u8, at: usize) Error!usize {
    assert(at < text.len);
    assert(text[at] == '`');
    const name_start = at + 1;
    var j = name_start;
    // §2.8.1: no directive is spelled with a backslash, so `\name is a use.
    if (j < text.len and text[j] == '\\') {
        const body = j + 1;
        j = scan.escapedEnd(text, body);
        if (j == body) {
            if (!pp.emitting()) return at + 1;
            return pp.fail(pp.spanAt(at, at + 1), "E0103", "", .{});
        }
        return macro.expand(pp, text, at, j, text[body..j]);
    }
    j = scan.identEnd(text, j);
    if (j == name_start) {
        if (!pp.emitting()) return at + 1;
        return pp.fail(pp.spanAt(at, at + 1), "E0103", "", .{});
    }
    const name = text[name_start..j];
    const kind = directive_map.get(name) orelse return macro.expand(pp, text, at, j, name);

    // Conditionals run even inside an inactive arm, because they nest.
    switch (kind) {
        .ifdef, .ifndef, .elsif, .@"else", .endif => return conditional(pp, text, at, j, kind),
        else => {}, // else: the line-oriented directives, below
    }
    // A directive with no operand (IEEE 1364 §19.1, §19.6, §19.9) is its word
    // alone; the rest take their operands to the end of the line.
    const end = switch (kind) {
        .celldefine, .endcelldefine, .nounconnected_drive, .resetall => j,
        .default_nettype, .unconnected_drive => operandLineEnd(text, j),
        else => logicalLineEnd(text, j), // else: every other directive reads the rest of its line
    };
    if (!pp.emitting()) {
        try pp.putNewlines(text[at..end]);
        return end;
    }
    // A region directive in a macro actual passes through whole and runs
    // when the expansion that substitutes it is rescanned, in the output.
    if (pp.in_actual and kind.marksRegion()) {
        try pp.out.appendSlice(pp.arena, text[at..end]);
        return end;
    }
    switch (kind) {
        .define => try macro.handleDefine(pp, text[j..end], at, j),
        .undef => try macro.removeDefine(pp, text[j..end], at, j),
        .include => try include.handleInclude(pp, text[j..end], at, j),
        .resetall => {
            // §10.2's "In addition to `resetall": the empty discipline.
            try pp.events.disciplines.append(pp.arena, .{ .at = @intCast(pp.out.items.len), .qualifier = null, .discipline = "" });
            // §19.6: every directive back to its default, as events, so the
            // text above keeps what earlier directives did to it.
            try pp.mark(&pp.events.timescales, null);
            try pp.mark(&pp.events.nettypes, events.NetType.default);
            try pp.mark(&pp.events.cells, false);
            try pp.mark(&pp.events.drives, events.Drive.default);
            try pp.mark(&pp.events.transitions, null);
            // §19.6 bars it inside a module, which only the parser sees.
            try pp.out.appendSlice(pp.arena, text[at..j]);
            return j;
        },
        .default_discipline => try handlers.defaultDiscipline(pp, text[j..end], j),
        // Applied here, and the word passed through for the parser to
        // refuse inside a module (§10.3).
        .default_transition => {
            try handlers.defaultTransition(pp, text[j..end], j);
            try pp.out.appendSlice(pp.arena, text[at..j]);
            try pp.putNewlines(text[j..end]);
            return end;
        },
        .line => try handlers.line(pp, text[j..end], at, j),
        .timescale => try handlers.timescale(pp, text[j..end], j),
        // Applied here, and the word passed through (IEEE 1364 §19.2, §19.9).
        .default_nettype, .unconnected_drive, .nounconnected_drive => {
            switch (kind) {
                .default_nettype => try handlers.defaultNettype(pp, text[j..end], j),
                .unconnected_drive => try handlers.unconnectedDrive(pp, text[j..end], j),
                else => try pp.mark(&pp.events.drives, .float), // else: `nounconnected_drive, the one other arm
            }
            try pp.out.appendSlice(pp.arena, text[at..j]);
            try pp.putNewlines(text[j..end]);
            return end;
        },
        .celldefine => try pp.mark(&pp.events.cells, true),
        .endcelldefine => try pp.mark(&pp.events.cells, false),
        // §28 reserves `protect: §28.2 obliges decryption, which VerA does;
        // it provides no encryption, so `begin` and a bare block are refused.
        .pragma => {
            var r: Rest = .{ .s = text[j..end] };
            const pragma_name = r.ident() orelse return pp.fail(pp.spanAt(at, j), "E0147", "", .{});
            if (std.mem.eql(u8, pragma_name, "protect")) {
                const list = r.s[r.i..];
                if (envelopeKeyword(list)) |kw| {
                    if (!std.mem.eql(u8, kw, "begin_protected"))
                        return pp.fail(pp.spanAt(at, end), "E0146", "`{s}`", .{kw});
                    return decryptionEnvelope(pp, text, at, end, list);
                }
            }
        },
        // §10.6: passed through with its own newlines for the parser.
        .keywords => {
            try pp.out.appendSlice(pp.arena, text[at..end]);
            return end;
        },
        .ifdef, .ifndef, .elsif, .@"else", .endif => unreachable, // returned above
    }
    try pp.putNewlines(text[at..end]);
    assert(end > at);
    return end;
}

/// Returns the end of the logical line at `i`: the next newline not
/// continued by a `\` (§10.4 multi-line macro text), or EOF.
pub fn logicalLineEnd(text: []const u8, i: usize) usize {
    assert(i <= text.len);
    var k = i;
    while (k < text.len) {
        if (text[k] == '\\') {
            var n = k + 1;
            while (n < text.len and (text[n] == ' ' or text[n] == '\t' or text[n] == '\r')) n += 1;
            if (n < text.len and text[n] == '\n') {
                k = n + 1;
                continue;
            }
        } else if (text[k] == '\n') return k;
        k += 1;
    }
    assert(k == text.len);
    return text.len;
}

// ---- private ----

/// IEEE 1364-2005 §28.2: decrypts the envelope whose `begin_protected` line
/// is `text[at..end]` and scans its cleartext in its place. Returns the
/// offset past the `end_protected` line.
///
/// ponytail: a diagnostic inside the cleartext quotes it; §28's rule that a
/// tool not reveal decrypted text is not applied to diagnostics.
fn decryptionEnvelope(pp: *Pass, text: []const u8, at: usize, end: usize, list: []const u8) Error!usize {
    assert(at < end);
    assert(end <= text.len);
    const span = pp.spanAt(at, end);
    const r = try protect.open(pp.arena, pp.opts.protect_keys, list, text, @min(end + 1, text.len));
    switch (r.opened) {
        .fail => |f| return pp.failCode(span, f.code, f.why),
        .text => |clear| try pp.nested(span, Pass.runFile, .{ pp, clear, protect.file_name, File.Index.none }),
    }
    try pp.checkTextSize(span);
    try pp.putNewlines(text[at..r.end]);
    return r.end;
}

/// The first §28.4 keyword in a `pragma protect list that opens or carries
/// an envelope, or null: every other keyword is metadata with no action
/// outside an envelope (§19.10). Strings and parenthesized values are opaque.
fn envelopeKeyword(list: []const u8) ?[]const u8 {
    const opens = [_][]const u8{ "begin", "begin_protected", "data_block", "key_block", "digest_block" };
    var depth: usize = 0;
    var item = true;
    var i: usize = 0;
    while (i < list.len) : (i += 1) {
        const c = list[i];
        if (c == '"') {
            i = scan.stringStop(list, i);
            continue;
        }
        if (c == '(') depth += 1;
        if (c == ')' and depth > 0) depth -= 1;
        if (c == ',' and depth == 0) item = true;
        if (!item or !scan.isIdentStart(c)) continue;
        const e = scan.identEnd(list, i);
        const word = list[i..e];
        for (opens) |o| if (std.mem.eql(u8, o, word)) return word;
        item = false;
        assert(e > i);
        i = e - 1;
    }
    return null;
}

/// `ifdef's view of a macro. Under `require_std_includes` the prelude's
/// annex D macros are hidden until the source includes their file, so
/// `` `ifndef DISCIPLINES_VAMS `include ... `` works as without a prelude.
fn isDefined(pp: *const Pass, name: []const u8) bool {
    assert(name.len > 0);
    const m = pp.macros.get(name) orelse return false;
    if (!pp.opts.require_std_includes or pp.in_std_defs) return true;
    if (m.annex_d2) return pp.constants_included;
    if (m.annex_d1) return pp.disciplines_included;
    return true;
}

/// `ifdef / `ifndef / `elsif / `else / `endif (IEEE 1364 §19.4).
fn conditional(pp: *Pass, text: []const u8, at: usize, after_name: usize, kind: Directive) Error!usize {
    assert(after_name > at);
    assert(after_name <= text.len);
    // The operand is on the directive's line; text after it is source.
    var r: Rest = .{ .s = text[after_name..logicalLineEnd(text, after_name)] };
    const sp = pp.spanAt(at, after_name);
    switch (kind) {
        .ifdef, .ifndef => {
            // A text_macro_identifier, simple or escaped (A.9.3).
            const name = r.escapedIdent() orelse r.ident() orelse
                return pp.fail(sp, "E0104", "`{s}", .{@tagName(kind)});
            const parent = pp.emitting();
            const defined = isDefined(pp, name);
            const active = parent and (if (kind == .ifdef) defined else !defined);
            try pp.conds.append(pp.arena, .{ .parent_active = parent, .active = active, .taken = active, .span = sp, .file = pp.cur_file });
        },
        .elsif, .@"else" => {
            const n = pp.conds.items.len;
            if (n == 0) return pp.fail(sp, "E0105", "`{s}", .{@tagName(kind)});
            const top = &pp.conds.items[n - 1];
            if (top.seen_else) return pp.fail(sp, "E0106", "`{s}", .{@tagName(kind)});
            if (kind == .@"else") {
                top.seen_else = true;
                top.active = top.parent_active and !top.taken;
                top.taken = true;
            } else {
                const name = r.escapedIdent() orelse r.ident() orelse
                    return pp.fail(sp, "E0107", "", .{});
                top.active = top.parent_active and !top.taken and isDefined(pp, name);
                if (top.active) top.taken = true;
            }
        },
        .endif => if (pp.conds.pop() == null) return pp.fail(sp, "E0108", "", .{}),
        else => unreachable, // else: `directive` routes only the five conditionals here
    }
    const end = after_name + r.i;
    assert(end <= text.len);
    try pp.putNewlines(text[at..end]);
    return end;
}

/// Returns the end of the line holding the operand of a directive whose word
/// ends at `i`: Syntax 19-2 and 19-9 put no line break inside, so a word
/// alone on its line takes the next nonblank line (iverilog br_gh782f).
fn operandLineEnd(text: []const u8, i: usize) usize {
    assert(i <= text.len);
    const end = logicalLineEnd(text, i);
    var k = i;
    while (k < text.len and scan.isSpace(text[k])) k += 1;
    return if (k < end) end else logicalLineEnd(text, k);
}
