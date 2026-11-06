//! Text macros: a `define or `undef line in, a macro table entry out; a macro
//! use in, its expansion scanned into the output (arguments pre-expanded,
//! recursion refused).
//! Cites: LRM §2.7, §2.8.1, §10.4, §10.5, §10.7; IEEE 1364-2005 §19.3,
//! §19.3.1; IEEE 1800-2017 §22.5.1 (the `" `\`" `` macro text forms).
//!
//! Expansion recursion (a body rescanned, an actual pre-expanded) runs
//! through `Pass.nested`, so its depth is capped (E0119), and the cycle guard
//! (`Pass.expanding_set`, E0118) is what makes a rescan terminate.
//!
//! Contents:
//! - `pub fn handleDefine(pp: *Pass, rest: []const u8, at: usize, off: usize) Error!void`
//! - `pub fn removeDefine(pp: *Pass, rest: []const u8, at: usize, off: usize) Error!void`
//! - `pub fn expand(pp: *Pass, text: []const u8, at: usize, after_name: usize, name: []const u8) Error!usize`

const std = @import("std");
const assert = std.debug.assert;
const Pass = @import("Pass.zig");
const Error = Pass.Error;
const Span = Pass.Span;
const Macro = Pass.Macro;
const scan = @import("scan.zig");
const Rest = scan.Rest;
const stringStop = scan.stringStop;
const isIdentStart = scan.isIdentStart;
const identEnd = scan.identEnd;
const escapedEnd = scan.escapedEnd;
const directive_map = @import("directive.zig").directive_map;

/// A macro use's trimmed actual arguments and the offset just past its `)`.
const MacroArgs = struct { args: []const []const u8, end: usize };

/// A pre-expanded actual's bytes on the actuals stack (`Pass.actualStack`).
const Region = struct { start: usize, end: usize };

/// Parses a §10.4 `define and adds or replaces its macro. `rest` is the
/// logical line after the word, starting at offset `off`; `at` is the '`'.
/// The macro borrows `rest`. Fails with E0109 (no name), E0143 (a
/// directive's name), E0110-E0112 (the formal list), E0139 (text begins with
/// __VAMS_) or E0145 (text splits a string); warns W0151 under
/// `Options.std_1364` for §22.5.1's forms.
pub fn handleDefine(pp: *Pass, rest: []const u8, at: usize, off: usize) Error!void {
    assert(off > at);
    const macros_before = pp.macros.count();
    var r: Rest = .{ .s = rest };
    // Syntax 10-3: text_macro_identifier ::= identifier (simple or escaped),
    // formal_argument_identifier ::= simple_identifier. §2.8 bars a first `$`.
    const name = r.escapedIdent() orelse (if (r.peek() == '$') null else r.ident()) orelse
        return pp.fail(pp.spanAt(at, off), "E0109", "", .{});
    // IEEE 1364 §19.3.1: "it shall be illegal to redefine a compiler
    // directive as a macro name"; Table 10-1 names `__FILE__ and `__LINE__.
    if (directive_map.has(name) or std.mem.eql(u8, name, "__FILE__") or std.mem.eql(u8, name, "__LINE__"))
        return pp.fail(pp.spanAt(off + r.i - name.len, off + r.i), "E0143", "`{s}` is a compiler directive", .{name});

    var m: Macro = .{ .body = "" };
    // The '(' of a formal list must touch the name (§10.4).
    if (r.peek() == '(') {
        r.i += 1;
        m.is_func = true;
        var params: std.ArrayList([]const u8) = .empty;
        // Each pass reads one formal or the closing `)`.
        while (true) {
            r.skipSpace();
            // `()` is an empty list; `M(a,)` is malformed.
            if (params.items.len == 0 and r.peek() == ')') {
                r.i += 1;
                break;
            }
            const p = (if (r.peek() == '$') null else r.ident()) orelse
                return pp.fail(pp.spanAt(off + r.i, off + r.i + 1), "E0110", "`{s}`", .{name});
            try params.append(pp.arena, p);
            r.skipSpace();
            const c = r.peek() orelse
                return pp.fail(pp.spanAt(off + r.i, off + r.i), "E0111", "`{s}`", .{name});
            r.i += 1;
            if (c == ',') continue;
            if (c == ')') break;
            r.i -= 1;
            return pp.fail(pp.spanAt(off + r.i, off + r.i + 1), "E0112", "`{s}`", .{name});
        }
        m.params = params.items;
    }
    r.skipSpace();
    m.body = try joinContinuations(pp, std.mem.trimEnd(u8, r.s[r.i..], " \t\r"));

    // §10.4: "the `define compiler directive's macro text shall not begin
    // with __VAMS_".
    if (std.mem.startsWith(u8, m.body, "__VAMS_"))
        return pp.fail(pp.spanAt(off + r.i, off + r.s.len), "E0139", "`{s}` begins with __VAMS_", .{m.body});
    // IEEE 1364 §19.3.1: macro text "shall not be split across ... Strings".
    if (splitsString(m.body))
        return pp.fail(pp.spanAt(off + r.i, off + r.s.len), "E0145", "`{s}`", .{name});
    // IEEE 1364-2005 Syntax 19-3 has none of §22.5.1's forms.
    if (pp.opts.std_1364 and (std.mem.find(u8, m.body, "`\"") != null or std.mem.find(u8, m.body, "``") != null))
        try pp.warn(pp.spanAt(at, off), "W0151", "`{s}`", .{name});
    // §10.4: a redefinition silently replaces; a predefined macro stays one.
    if (pp.macros.get(name)) |old| m.predefined = old.predefined;
    try pp.putMacro(name, m);
    assert(pp.macros.count() >= macros_before);
}

/// Parses a §10.4 `undef and removes the macro; a §10.5 predefined macro is
/// left alone, and an undefined name is no error. Arguments as for
/// `handleDefine`. Fails with E0113 when no name follows.
pub fn removeDefine(pp: *Pass, rest: []const u8, at: usize, off: usize) Error!void {
    assert(off > at);
    var r: Rest = .{ .s = rest };
    const name = r.escapedIdent() orelse r.ident() orelse
        return pp.fail(pp.spanAt(at, off), "E0113", "", .{});
    if (pp.macros.get(name)) |m| if (m.predefined) return;
    pp.removeMacro(name);
    assert(!pp.macros.contains(name));
}

/// Expands the macro use whose '`' is at `at`, with `after_name` just past
/// the name, into `pp.out`; handles §10.7 `__LINE__` and `__FILE__`. Returns
/// the offset to resume scanning from (`after_name`, with nothing emitted,
/// inside an inactive arm). Fails with E0115 (undefined), E0116/E0117 (the
/// argument list), E0118 (recursion), E0120 (unbalanced arguments), E0150
/// (the text bound) or E0119 (the nesting cap).
pub fn expand(pp: *Pass, text: []const u8, at: usize, after_name: usize, name: []const u8) Error!usize {
    assert(after_name > at);
    assert(after_name <= text.len);
    if (!pp.emitting()) return after_name;
    const sp = pp.spanAt(at, after_name);

    const m = pp.macros.get(name) orelse {
        // §10.7: both depend on where the use sits.
        if (std.mem.eql(u8, name, "__LINE__")) {
            // "in the form of a simple decimal number".
            try pp.out.print(pp.arena, "{d}", .{pp.currentLine(at)});
            return after_name;
        }
        if (std.mem.eql(u8, name, "__FILE__")) {
            // "in the form of a string literal": '"' and '\' escaped.
            try pp.out.append(pp.arena, '"');
            for (pp.file_override orelse pp.file(pp.cur_file).name) |c| {
                if (c == '"' or c == '\\') try pp.out.append(pp.arena, '\\');
                try pp.out.append(pp.arena, c);
            }
            try pp.out.append(pp.arena, '"');
            return after_name;
        }
        return pp.fail(sp, "E0115", "`{s}", .{name});
    };
    // `require_std_includes`: annex D.2 reaches only a source including it.
    if (m.annex_d2 and pp.opts.require_std_includes and !pp.constants_included and !pp.in_std_defs)
        return pp.fail(sp, "E0115", "`{s} is annex D.2's: add `include \"constants.vams\"", .{name});

    var end = after_name;
    var args: []const []const u8 = &.{};
    if (m.is_func) {
        var k = after_name;
        while (k < text.len and scan.isSpace(text[k])) k += 1;
        if (k >= text.len or text[k] != '(')
            return pp.fail(sp, "E0116", "`{s}` takes {d} argument(s)", .{ name, m.params.len });
        const parsed = try macroArgs(pp, text, k, at, name);
        args = parsed.args;
        end = parsed.end;
        // `M()` on a zero-parameter macro is an empty list, not one empty arg.
        if (m.params.len == 0 and args.len == 1 and args[0].len == 0) args = &.{};
        if (args.len != m.params.len)
            return pp.fail(sp, "E0117", "expected {d}, found {d}", .{ m.params.len, args.len });
    }
    if (pp.expanding_set.contains(name)) {
        const note = try pp.arena.print("expansion chain: {s}", .{try pp.joinChain(pp.expanding.items, name)});
        return pp.failNoted(sp, "E0118", "`{s}`", .{name}, try pp.arena.dupe([]const u8, &.{note}));
    }

    // Arguments expand fully before substitution, before `name` is pushed:
    // a nested use in an actual is not recursion, a self-use in the body is.
    // The body is built in this depth's buffer and handed back when its text
    // holds no '`' (no directive can borrow it).
    const depth = pp.expanding.items.len;
    var buf: std.ArrayList(u8) = .empty;
    var kept = true;
    defer if (!kept) {
        pp.bodies.items[depth] = buf;
    };
    const body = if (m.is_func or std.mem.findScalar(u8, m.body, '`') != null) blk: {
        const actuals = try expandActuals(pp, args, sp, at);
        if (pp.bodies.items.len <= depth) try pp.bodies.appendNTimes(pp.arena, .empty, depth + 1 - pp.bodies.items.len);
        buf = pp.bodies.items[depth];
        pp.bodies.items[depth] = .empty;
        buf.clearRetainingCapacity();
        try substitute(pp, &buf, m.body, m.params, actuals.args);
        if (actuals.base) |b| pp.actualStack().shrinkRetainingCapacity(b);
        // ponytail: a body with a '`' stays on the arena, so nested uses of
        // such a macro take memory quadratic in their depth.
        kept = std.mem.findScalar(u8, buf.items, '`') != null;
        break :blk buf.items;
    } else m.body;
    try pp.expanding.append(pp.arena, name);
    try pp.expanding_set.put(pp.arena, name, {});
    defer {
        _ = pp.expanding.pop();
        _ = pp.expanding_set.remove(name);
    }

    // Provenance: the outermost expansion maps its whole text to the use.
    const outermost = pp.expand_site == null;
    if (outermost) {
        const site: u32 = @intCast(at);
        if (!pp.in_actual) {
            pp.expansion_map = @intCast(pp.maps.items.len);
            try pp.maps.append(pp.arena, .{ .out = @intCast(pp.out.items.len), .offset = site, .file = pp.cur_file, .kind = .expansion });
        }
        pp.expand_site = site;
    }
    defer if (outermost) {
        pp.expand_site = null;
    };
    // The rescan expands nested uses; the cycle guard ends it.
    try pp.nested(sp, scan.scan, .{ pp, body });
    try pp.checkTextSize(sp);
    // The invocation may have spanned lines; keep the count.
    try pp.putNewlines(text[at..end]);
    assert(end >= after_name);
    return end;
}

// ---- private ----

/// A macro body is one logical line: `\`+newline collapses to a space (the
/// caller re-emits the newlines). Copies only when there is one.
fn joinContinuations(pp: *Pass, body: []const u8) Error![]const u8 {
    if (std.mem.findScalar(u8, body, '\n') == null) return body;
    var out: std.ArrayList(u8) = try .initCapacity(pp.arena, body.len);
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] == '\\') {
            var k = i + 1;
            while (k < body.len and (body[k] == ' ' or body[k] == '\t' or body[k] == '\r')) k += 1;
            if (k < body.len and body[k] == '\n') {
                // One separating space, and the continuation's indent eaten.
                if (out.items.len != 0 and out.items[out.items.len - 1] != ' ') out.appendAssumeCapacity(' ');
                i = k;
                while (i + 1 < body.len and (body[i + 1] == ' ' or body[i + 1] == '\t')) i += 1;
                continue;
            }
        }
        if (body[i] == '\n' or body[i] == '\r') continue;
        out.appendAssumeCapacity(body[i]);
    }
    assert(std.mem.findScalar(u8, out.items, '\n') == null);
    return out.items;
}

/// `args` with each one holding a '`' fully expanded (`expandArg`), and
/// where their regions begin on the actuals stack, which the caller pops
/// once substituted. With none to expand, `args` comes back as is.
fn expandActuals(pp: *Pass, args: []const []const u8, sp: Span, at: usize) Error!struct { args: []const []const u8, base: ?usize } {
    const first = for (args, 0..) |a, k| {
        if (std.mem.findScalar(u8, a, '`') != null) break k;
    } else return .{ .args = args, .base = null };
    const base = pp.actualStack().items.len;
    const copy = try pp.arena.dupe([]const u8, args);
    const regions = try pp.arena.alloc(?Region, args.len - first);
    for (copy[first..], regions) |a, *r| try pp.nested(sp, expandArg, .{ pp, a, at, r });
    // Sliced only now: a later actual's expansion may move the stack.
    const stack = pp.actualStack().items;
    for (copy[first..], regions) |*slot, r| if (r) |x| {
        slot.* = stack[x.start..x.end];
    };
    assert(regions[0] != null);
    return .{ .args = copy, .base = base };
}

/// Expands `arg` onto the actuals stack and sets `region` to where it
/// landed (null for '`'-free text). Scans with `in_actual` set and
/// `expand_site` at the invocation, as a body rescan does.
fn expandArg(pp: *Pass, arg: []const u8, at: usize, region: *?Region) Error!void {
    region.* = null;
    if (std.mem.findScalar(u8, arg, '`') == null) return;
    // Outside an actual the output is swapped for the stack and back.
    const outer = !pp.in_actual;
    const saved_out = pp.out;
    const saved_site = pp.expand_site;
    const saved_base = pp.out_base;
    if (outer) {
        pp.out = pp.actuals;
        pp.actuals = .empty;
    }
    const start = pp.out.items.len;
    pp.in_actual = true;
    pp.out_base = start;
    if (pp.expand_site == null) pp.expand_site = @intCast(at);
    defer {
        if (outer) {
            pp.actuals = pp.out;
            pp.out = saved_out;
        }
        pp.expand_site = saved_site;
        pp.in_actual = !outer;
        pp.out_base = saved_base;
    }
    try scan.scan(pp, arg);
    region.* = .{ .start = start, .end = pp.out.items.len };
    assert(region.*.?.end >= start);
}

/// Splits the top-level comma list opening at `lparen`. Nested (), [], {},
/// strings and escaped identifiers are opaque; a closer that does not match
/// its opener, or a missing `)`, is E0120. Asserts `text[lparen] == '('`.
fn macroArgs(pp: *Pass, text: []const u8, lparen: usize, at: usize, name: []const u8) Error!MacroArgs {
    assert(text[lparen] == '(');
    assert(lparen > at);
    var args: std.ArrayList([]const u8) = .empty;
    const opens = &pp.brackets;
    opens.clearRetainingCapacity();
    var i = lparen;
    var arg_start = lparen + 1;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            '"' => i = stringStop(text, i),
            // §2.8.1: an escaped identifier runs to white space.
            '\\' => i = escapedEnd(text, i + 1) - 1,
            '(', '[', '{' => try opens.append(pp.arena, c),
            ')', ']', '}' => {
                // The '(' at `lparen` was pushed first; the list returns
                // the moment the stack empties.
                const open = opens.pop().?;
                const want: u8 = switch (open) {
                    '(' => ')',
                    '[' => ']',
                    else => '}',
                };
                if (c != want) return pp.fail(pp.spanAt(i, i + 1), "E0120", "`{s}`: `{c}` cannot close `{c}`", .{ name, c, open });
                if (opens.items.len == 0) {
                    try args.append(pp.arena, try oneLine(pp, std.mem.trim(u8, text[arg_start..i], " \t\r\n")));
                    return .{ .args = args.items, .end = i + 1 };
                }
            },
            ',' => if (opens.items.len == 1) {
                try args.append(pp.arena, try oneLine(pp, std.mem.trim(u8, text[arg_start..i], " \t\r\n")));
                arg_start = i + 1;
            },
            else => {},
        }
        i += 1;
    }
    return pp.fail(pp.spanAt(at, at + 1 + name.len), "E0120", "`{s}`", .{name});
}

/// `arg` with each newline outside a string turned into a space (copied
/// only when there is one): `expand` emits the invocation's newlines after
/// the expansion, so one kept in an actual would reach the output twice.
fn oneLine(pp: *Pass, arg: []const u8) Error![]const u8 {
    if (std.mem.findScalar(u8, arg, '\n') == null) return arg;
    const copy = try pp.arena.dupe(u8, arg);
    var i: usize = 0;
    while (i < copy.len) : (i += 1) {
        if (copy[i] == '"') {
            // A string keeps its bytes; one left open ends at its newline.
            i = stringStop(copy, i);
            if (i == copy.len or copy[i] != '\n') continue;
        }
        if (copy[i] == '\n') copy[i] = ' ';
    }
    assert(copy.len == arg.len);
    return copy;
}

/// Appends `body` to `out` with each whole-identifier formal replaced by its
/// actual. Strings, escaped identifiers, numbers and the name after a '`'
/// are never substituted into. Asserts one actual per formal.
fn substitute(pp: *Pass, out: *std.ArrayList(u8), body: []const u8, params: []const []const u8, args: []const []const u8) Error!void {
    assert(params.len == args.len);
    assert(out.items.len == 0);
    try out.ensureTotalCapacity(pp.arena, body.len);
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '"') {
            const start = i;
            i += 1;
            while (i < body.len and body[i] != '"') {
                if (body[i] == '\\' and i + 1 < body.len) i += 1;
                i += 1;
            }
            if (i < body.len) i += 1;
            try out.appendSlice(pp.arena, body[start..i]);
            continue;
        }
        if (c == '`') {
            // §22.5.1: `` is an empty separator; `" opens a string whose
            // formals are still substituted.
            if (i + 1 < body.len and body[i + 1] == '`') {
                i += 2;
                continue;
            }
            if (i + 1 < body.len and body[i + 1] == '"') {
                i = try stringify(pp, out, body, i + 2, params, args);
                continue;
            }
            const start = i;
            i = identEnd(body, i + 1);
            try out.appendSlice(pp.arena, body[start..i]);
            continue;
        }
        if (c == '\\') {
            // §2.8.1: in `define M(x) real \sig-x ; the `x` is no formal.
            const start = i;
            i = escapedEnd(body, i + 1);
            try out.appendSlice(pp.arena, body[start..i]);
            continue;
        }
        if (isIdentStart(c)) {
            const start = i;
            i = identEnd(body, i);
            const word = body[start..i];
            const idx = formalIndex(params, word);
            try out.appendSlice(pp.arena, if (idx) |k| args[k] else word);
            // §19.3.1 substitutes "literally", and an escaped identifier's
            // terminating white space is part of it: put back what
            // `macroArgs` trimmed, or `(ARG)` reads `\a.b)`.
            if (idx) |k| if (endsInEscapedIdent(args[k])) try out.append(pp.arena, ' ');
            continue;
        }
        if (std.ascii.isDigit(c)) {
            // A number is one token: the `e` of `1e-3`, the `k` of `2k`.
            const start = i;
            i += 1;
            while (i < body.len) : (i += 1) {
                const d = body[i];
                if (scan.isIdentChar(d) or d == '.') continue;
                if ((d == '+' or d == '-') and (body[i - 1] | 0x20) == 'e') continue;
                break;
            }
            try out.appendSlice(pp.arena, body[start..i]);
            continue;
        }
        try out.append(pp.arena, c);
        i += 1;
    }
    assert(i >= body.len);
}

/// Copies the §22.5.1 `"...`" string whose text starts at `start` into `out`
/// as a "..." literal and returns the offset past its closing `". Formals
/// are replaced, `\`" becomes \" and `` vanishes. An unclosed one ends with
/// the body.
fn stringify(pp: *Pass, out: *std.ArrayList(u8), body: []const u8, start: usize, params: []const []const u8, args: []const []const u8) Error!usize {
    assert(params.len == args.len);
    assert(start <= body.len);
    try out.append(pp.arena, '"');
    var i = start;
    while (i < body.len) {
        const c = body[i];
        if (c == '`') {
            if (std.mem.startsWith(u8, body[i..], "`\\`\"")) {
                try out.appendSlice(pp.arena, "\\\"");
                i += 4;
                continue;
            }
            if (std.mem.startsWith(u8, body[i..], "``")) {
                i += 2;
                continue;
            }
            if (std.mem.startsWith(u8, body[i..], "`\"")) {
                i += 2;
                break;
            }
        }
        if (c == '\\' and i + 1 < body.len) {
            try out.appendSlice(pp.arena, body[i .. i + 2]);
            i += 2;
            continue;
        }
        if (isIdentStart(c)) {
            const w = i;
            i = identEnd(body, i);
            const word = body[w..i];
            try out.appendSlice(pp.arena, if (formalIndex(params, word)) |k| args[k] else word);
            continue;
        }
        try out.append(pp.arena, c);
        i += 1;
    }
    try out.append(pp.arena, '"');
    return i;
}

fn formalIndex(params: []const []const u8, word: []const u8) ?usize {
    for (params, 0..) |formal, n| {
        if (std.mem.eql(u8, formal, word)) return n;
    }
    return null;
}

/// Does `text` open a string literal it does not close? An escaped
/// identifier's `"` and §22.5.1's `" are no quotes.
fn splitsString(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '`' => if (std.mem.startsWith(u8, text[i..], "`\\`\"")) {
                i += 3;
            } else if (std.mem.startsWith(u8, text[i..], "`\"")) {
                i += 1;
            },
            '"' => {
                i = stringStop(text, i);
                if (i >= text.len or text[i] != '"') return true;
            },
            '\\' => i = escapedEnd(text, i + 1) - 1,
            else => {},
        }
    }
    return false;
}

/// Does `text` end inside a §2.8.1 escaped identifier, with no white space
/// after its last `\`-started run? Strings are skipped.
fn endsInEscapedIdent(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '"' => i = stringStop(text, i),
            '\\' => {
                i = escapedEnd(text, i + 1);
                if (i == text.len) return true;
            },
            else => {},
        }
    }
    return false;
}
