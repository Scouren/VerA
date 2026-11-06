//! `Diag`'s spec examples, through its public API: diagnostics built with
//! `Wip`, rendered, checked against transcripts and counts derived by hand
//! from the contract each test names, or against an independent model.
//! Ported from tests/unit/diag_tests.zig; `zig build diff-diag` holds the
//! rest of the behaviour to lib/diag byte for byte.
//!
//! Cites: the catalogue's §4.2.10, §4.2.11, §3.6.1.2 and A.1.2 rows (#62,
//! #68); otherwise none, the format is VerA's own.
//!
//! Contents: tests only.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Diag = @import("../Diag.zig");
const Wip = Diag.Wip;
const Code = Diag.Code;
const Level = Diag.Level;
const Levels = Diag.Levels;

// ---- private ----

fn at(file: u32, start: u32, end: u32) Diag.Loc {
    return .{ .file = @fromBackingInt(file), .start = start, .end = end };
}

/// Renders `d` over one file `name` holding `text`, into `gpa` memory the
/// caller frees.
fn renderOver(gpa: Allocator, d: Diag, name: []const u8, text: []const u8, opts: Diag.RenderOptions) ![]u8 {
    const starts = try Diag.lineStarts(gpa, text);
    defer gpa.free(starts);
    const sources = [_]Diag.Source{.{ .name = name, .text = text, .line_starts = starts }};
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try d.render(&sources, &aw.writer, opts);
    try d.renderJson(&sources, &aw.writer);
    return aw.toOwnedSlice();
}

/// Builds and renders one full diagnostic on `gpa`, for the
/// allocation-failure sweep.
fn buildAndRender(gpa: Allocator) !void {
    var wip: Wip = .init(gpa);
    defer wip.deinit();
    var b = wip.build(.lower, .E0313, at(0, 12, 13));
    b.msg("`{s}`", .{"x"});
    b.label(at(0, 0, 6), "here", .{});
    b.suggestHere("y");
    try b.emit();
    var d = try wip.toOwnedBundle();
    defer d.deinit(gpa);
    // A fixed writer: every failure the sweep can see is the Wip's.
    const text = "module m;\n  x = 1;\nendmodule\n";
    const starts = try Diag.lineStarts(gpa, text);
    defer gpa.free(starts);
    const sources = [_]Diag.Source{.{ .name = "o.va", .text = text, .line_starts = starts }};
    var out: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try d.render(&sources, &w, .{});
    try d.renderJson(&sources, &w);
}

/// The counters against a model written from `Builder.emit`'s contract: an
/// allowed code is never counted, a full `Wip` counts the rest as
/// suppressed, and otherwise (code, file, start) dedupes.
fn modelOne(_: void, s: *testing.Smith) anyerror!void {
    var wip: Wip = .init(testing.allocator);
    defer wip.deinit();
    const codes = [_]Code{ .E0313, .W0650, .W0651 };
    const warning_levels = [_]Level{ .allow, .warn, .deny, .forbid };
    var level: [codes.len]Level = .{ .deny, .warn, .warn };
    for (1..codes.len) |c| {
        level[c] = warning_levels[s.index(warning_levels.len)];
        try wip.levels.set(codes[c], level[c]);
    }
    var seen = std.mem.zeroes([codes.len][32]bool);
    var kept: u32 = 0;
    var errs: u32 = 0;
    var warns: u32 = 0;
    var dups: u32 = 0;
    var supp: u32 = 0;
    var n: usize = 0;
    while (n < 200 and !s.eos()) : (n += 1) {
        const c = s.index(codes.len);
        const start = s.index(32);
        try wip.add(.lower, codes[c], at(0, @intCast(start), @intCast(start + 1)), "", .{});
        if (level[c] == .allow) continue;
        if (seen[c][start]) {
            dups += 1;
            continue;
        }
        if (level[c] == .warn) warns += 1 else errs += 1;
        if (kept >= Diag.max_entries) {
            supp += 1;
            continue;
        }
        seen[c][start] = true;
        kept += 1;
    }
    try testing.expectEqual(errs != 0, wip.failed());
    var d = try wip.toOwnedBundle();
    defer d.deinit(testing.allocator);
    const h = d.header();
    try testing.expectEqual(kept, h.len);
    try testing.expectEqual(supp, h.suppressed);
    try testing.expectEqual(dups, h.deduped);
    try testing.expectEqual(errs, h.err_count);
    try testing.expectEqual(warns, h.warn_count);
}

/// Arbitrary text and arbitrary (inverted, past-the-end) locations, labels
/// and fixes: rendering never panics, prints one headline per kept row, and
/// the JSON line and column of each primary location match a byte count.
fn renderAnyOne(_: void, s: *testing.Smith) anyerror!void {
    const gpa = testing.allocator;
    var text_buf: [256]u8 = undefined;
    const text = text_buf[0..s.slice(&text_buf)];
    var wip: Wip = .init(gpa);
    defer wip.deinit();
    const hi: u32 = if (s.boolWeighted(7, 1)) @intCast(text.len + 4) else std.math.maxInt(u32);
    var n: usize = 0;
    while (n < 80 and !s.eos()) : (n += 1) {
        var b = wip.build(.parse, .E0207, at(0, s.valueRangeAtMost(u32, 0, hi), s.valueRangeAtMost(u32, 0, hi)));
        if (s.boolWeighted(1, 1)) b.point("p", .{});
        if (s.boolWeighted(1, 1)) b.label(at(0, s.valueRangeAtMost(u32, 0, hi), s.valueRangeAtMost(u32, 0, hi)), "l", .{});
        if (s.boolWeighted(1, 1)) {
            const fix = at(0, s.valueRangeAtMost(u32, 0, hi), s.valueRangeAtMost(u32, 0, hi));
            b.suggest(.{ .loc = fix, .replacement = "r\tµ" }, "h", .{});
        }
        try b.emit();
    }
    var d = try wip.toOwnedBundle();
    defer d.deinit(gpa);
    const out = try renderOver(gpa, d, "f.va", text, .{});
    defer gpa.free(out);
    try testing.expectEqual(@as(usize, d.count()), std.mem.count(u8, out, "error[E0207]"));
    for (d.messages()) |i| {
        const loc = d.message(i).loc;
        const upto = @min(loc.start, text.len);
        const want_line = std.mem.countScalar(u8, text[0..upto], '\n') + 1;
        const line_start = if (std.mem.findScalarLast(u8, text[0..upto], '\n')) |nl| nl + 1 else 0;
        var buf: [128]u8 = undefined;
        const want = try std.fmt.bufPrint(&buf, "\"span\":{{\"file\":\"f.va\",\"line\":{d},\"col\":{d},\"byte_start\":{d},", .{
            want_line, loc.start - line_start + 1, loc.start,
        });
        try testing.expect(std.mem.find(u8, out, want) != null);
    }
}

test "render: an exact transcript, label above the primary" {
    const gpa = testing.allocator;
    var wip: Wip = .init(gpa);
    defer wip.deinit();
    // Line starts 0, 10, 19, 29; the `x` at 12 is line 2, column 3.
    var b = wip.build(.lower, .E0313, at(0, 12, 13));
    b.msg("`x`", .{});
    b.point("not declared", .{});
    b.label(at(0, 0, 6), "in here", .{});
    b.note("n", .{});
    b.help("h", .{});
    try b.emit();
    var d = try wip.toOwnedBundle();
    defer d.deinit(gpa);
    const out = try renderOver(gpa, d, "t.va", "module m;\n  x = 1;\nendmodule\n", .{});
    defer gpa.free(out);
    try testing.expectEqualStrings(
        "error[E0313]: unknown variable: `x`\n" ++
            " --> t.va:2:3\n" ++
            "  |\n" ++
            "1 | module m;\n" ++
            "  | ------ in here\n" ++
            "2 |   x = 1;\n" ++
            "  |   ^ not declared\n" ++
            "  |\n" ++
            "  = note: LRM 6.8\n" ++
            "  = note: n\n" ++
            "  = help: h\n" ++
            "  = help: run `vera --explain E0313` for a detailed explanation\n" ++
            "\n" ++
            "error: could not compile due to 1 previous error(s)\n" ++
            "{\"code\":\"E0313\",\"level\":\"error\",\"stage\":\"lower\",\"lrm\":\"6.8\",\"title\":\"unknown variable\"," ++
            "\"message\":\"`x`\",\"span\":{\"file\":\"t.va\",\"line\":2,\"col\":3,\"byte_start\":12,\"byte_end\":13}," ++
            "\"labels\":[{\"text\":\"in here\",\"span\":{\"file\":\"t.va\",\"line\":1,\"col\":1,\"byte_start\":0,\"byte_end\":6}}]," ++
            "\"notes\":[{\"kind\":\"note\",\"text\":\"n\"},{\"kind\":\"help\",\"text\":\"h\"}]}\n",
        out,
    );
}

test "render: a fix inserts with +, and the explain hint follows each code once" {
    const gpa = testing.allocator;
    var wip: Wip = .init(gpa);
    defer wip.deinit();
    var b = wip.build(.lower, .E0313, at(0, 12, 13));
    b.suggest(.{ .loc = at(0, 13, 13), .replacement = "yz" }, "add", .{});
    try b.emit();
    try wip.add(.lower, .E0313, at(0, 16, 17), "", .{});
    var d = try wip.toOwnedBundle();
    defer d.deinit(gpa);
    const out = try renderOver(gpa, d, "t.va", "module m;\n  x = 1;\nendmodule\n", .{ .summary = false });
    defer gpa.free(out);
    try testing.expect(std.mem.find(u8, out, "2 |   xyz = 1;\n  |    ++\n") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "--explain E0313"));
}

test "Wip: dedupe, cap, level promotion" {
    const gpa = testing.allocator;
    var wip: Wip = .init(gpa);
    defer wip.deinit();
    try wip.add(.lower, .E0313, at(0, 10, 13), "unknown variable {s}", .{"vd"});
    // Same code, file and start: deduped.
    try wip.add(.lower, .E0313, at(0, 10, 13), "unknown variable {s}", .{"vd"});
    // Same code and start in another file: kept.
    try wip.add(.lower, .E0313, at(1, 10, 13), "", .{});
    try testing.expect(wip.failed());
    try wip.add(.proof, .W0650, at(0, 20, 24), "", .{});
    try wip.levels.set(.W0650, .deny);
    try wip.add(.proof, .W0650, at(0, 30, 34), "", .{});
    try wip.levels.set(.W0650, .allow);
    try testing.expect(!wip.enabled(.W0650));
    try wip.add(.proof, .W0650, at(0, 40, 44), "", .{});
    var d = try wip.toOwnedBundle();
    defer d.deinit(gpa);
    const h = d.header();
    try testing.expectEqual(@as(u32, 4), h.len);
    try testing.expectEqual(@as(u32, 1), h.deduped);
    try testing.expectEqual(@as(u32, 3), h.err_count);
    try testing.expectEqual(@as(u32, 1), h.warn_count);
    // Source order: file 0 by start, then file 1.
    const order = [_]u32{ 10, 20, 30, 10 };
    for (d.messages(), order) |i, start| try testing.expectEqual(start, d.message(i).loc.start);
    try testing.expectEqual(Diag.Severity.err, d.message(d.messages()[2]).tag.severity);
}

test "Wip: the cap counts what it drops, and the trailer says so" {
    const gpa = testing.allocator;
    var wip: Wip = .init(gpa);
    defer wip.deinit();
    for (0..Diag.max_entries + 10) |i| try wip.add(.lower, .E0313, at(0, @intCast(i * 4), @intCast(i * 4 + 2)), "x", .{});
    var d = try wip.toOwnedBundle();
    defer d.deinit(gpa);
    try testing.expectEqual(Diag.max_entries, d.count());
    try testing.expectEqual(@as(u32, 10), d.header().suppressed);
    const out = try renderOver(gpa, d, "t.va", "", .{});
    defer gpa.free(out);
    try testing.expect(std.mem.find(u8, out, "warning: 10 further diagnostic(s) not shown (limit 64)\n" ++
        "error: could not compile due to 74 previous error(s)\n") != null);
}

test "Wip: nothing reported allocates nothing and is the empty bundle" {
    var wip: Wip = .init(testing.failing_allocator);
    defer wip.deinit();
    try wip.levels.set(.W0650, .allow);
    try wip.add(.proof, .W0650, at(0, 1, 2), "{s}", .{"never formatted"});
    var d = try wip.toOwnedBundle();
    try testing.expectEqual(@as(usize, 0), d.extra.len);
    try testing.expectEqual(@as(u32, 0), d.count());
    try testing.expect(!d.failed());
    var buf: [8]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try d.render(&.{}, &w, .{});
    try testing.expectEqual(@as(usize, 0), w.end);
    d.deinit(testing.failing_allocator);
}

test "Wip: every allocation failure while building and rendering propagates, leak-free" {
    try testing.checkAllAllocationFailures(testing.allocator, buildAndRender, .{});
}

test "Wip: the counters agree with a model of emit" {
    try testing.fuzz({}, modelOne, .{});
}

test "render never panics on any location over any text" {
    try testing.fuzz({}, renderAnyOne, .{ .corpus = &.{ "ab\r\ncd", "\t\tµ\n", "x" } });
}

test "levels: errors stay errors, forbid is one-way, parseFlag reads exact directives" {
    var levels: Levels = .empty;
    try testing.expectEqual(Level.warn, levels.get(.W0650));
    try testing.expectEqual(Level.deny, levels.get(.E0601));
    try levels.set(.W0650, .allow);
    try testing.expectEqual(Level.allow, levels.get(.W0650));
    try testing.expectError(error.CannotAllowError, levels.set(.E0601, .allow));
    try testing.expectEqual(Level.deny, levels.get(.E0601));
    try levels.set(.W0651, .forbid);
    try testing.expectError(error.Forbidden, levels.set(.W0651, .allow));
    try testing.expectEqual(Level.forbid, levels.get(.W0651));
    try testing.expect(try levels.parseFlag("deny=W0650"));
    try testing.expectEqual(Level.deny, levels.get(.W0650));
    try testing.expect(!try levels.parseFlag("deny=w0650"));
    try testing.expect(!try levels.parseFlag("not-a-flag"));
}

test "explain prints the catalogue entry, verbatim" {
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try Diag.explain(.E0102, &w, .off);
    try testing.expect(std.mem.startsWith(u8, w.buffered(), "E0102: unterminated block comment\nLRM 2.4\n\nA `/*` comment"));
    w.end = 0;
    try Diag.explain(.E0207, &w, .off);
    try testing.expect(std.mem.startsWith(u8, w.buffered(), "E0207: "));
    try testing.expect(std.mem.find(u8, w.buffered(), "\nLRM annex A.1.2\n") != null);
}

test "a refusal cites the clause that states its rule (#62, #68)" {
    // §4.2.11: arithmetic shifts; §4.2.10: reduction operators.
    try testing.expectEqualStrings("4.2.11", Diag.info(.E0324).lrm);
    try testing.expectEqualStrings("4.2.10", Diag.info(.E0320).lrm);
    try testing.expectEqualStrings("3.6.1.2", Diag.info(.E0501).lrm);
    // A.1.2: "source_text ::= { description }".
    try testing.expectEqualStrings("A.1.2", Diag.info(.E0201).lrm);
    try testing.expectEqualStrings("A.1.2", Diag.info(.E0207).lrm);
}

test "every citation is a clause, an annex, or an IEEE 1364-2005 clause; every cited code exists" {
    for (std.enums.values(Code)) |c| {
        const i = Diag.info(c);
        if (i.lrm.len != 0) try testing.expect((i.lrm[0] >= '0' and i.lrm[0] <= '9') or
            (i.lrm[0] >= 'A' and i.lrm[0] <= 'H') or std.mem.startsWith(u8, i.lrm, "IEEE 1364-2005 "));
        const text = i.explain;
        for (0..text.len -| 4) |k| {
            if (text[k] != 'E' and text[k] != 'W') continue;
            if (k > 0 and std.ascii.isAlphanumeric(text[k - 1])) continue;
            const word = text[k..][0..5];
            if (!std.ascii.isDigit(word[1]) or !std.ascii.isDigit(word[4])) continue;
            if (k + 5 < text.len and std.ascii.isAlphanumeric(text[k + 5])) continue;
            try testing.expect(std.meta.stringToEnum(Code, word) != null);
        }
    }
}

test "did you mean: transpositions are one edit, ties break on spelling" {
    try testing.expectEqual(@as(usize, 1), Diag.editDistance("abc", "acb", 4));
    try testing.expect(Diag.editDistance("abc", "zzzzzz", 2) > 2);
    const cands = [_][]const u8{ "vds", "vgs", "temp" };
    try testing.expectEqualStrings("vds", Diag.didYouMean("vdss", &cands).?);
    try testing.expect(Diag.didYouMean("completely_different", &cands) == null);
    const a = [_][]const u8{ "vbs", "vas_" };
    const b = [_][]const u8{ "vas_", "vbs" };
    try testing.expectEqualStrings(Diag.didYouMean("vas", &a).?, Diag.didYouMean("vas", &b).?);
}
