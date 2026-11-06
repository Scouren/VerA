//! The `Preprocessor`'s spec examples, through its public request API:
//! source in, expanded text, directive events, diagnostics and requests
//! checked out. Each expected value is derived by hand from the clause it
//! cites, or is the oracle named beside it (openssl, iverilog). Ported from
//! tests/unit/preprocessor_tests.zig; files are answered from memory, so no
//! test touches a disk.
//! Cites: LRM §2.2, §2.4, §2.6.2, §2.7, §2.8, §9.15, §10, annex D; IEEE
//! 1364-2005 §13.4.1, §19, §28; IEEE 1800-2017 §22.5.1.
//!
//! Contents: tests only.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Preprocessor = @import("../Preprocessor.zig");
const Options = Preprocessor.Options;
const events = Preprocessor.events;
const directive_map = @import("directive.zig").directive_map;

/// A file the tests answer a request with: (path, bytes).
const DiskFile = struct { []const u8, []const u8 };

/// Files the tests answer requests from; any other path is "not there".
const Disk = []const DiskFile;

/// `std_model`-style sources read annex D through these two lines.
const std_includes = "`include \"disciplines.vams\"\n`include \"constants.vams\"\n";

/// The openssl key of the §28 tests: `-K 0123456789abcdef -iv 1234567890abcdef`.
const des_keys: Preprocessor.protect.Keys = .{
    .iv = .{ 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef },
    .keys = &.{.{ .owner = "o", .name = "k", .key = .{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef } }},
};

// ---- private ----

/// Runs `pp` to the end, answering from `disk`.
fn finish(pp: *Preprocessor, disk: Disk) !void {
    while (try pp.run()) |req| switch (req) {
        .file => |want| try pp.answer(for (disk) |f| {
            if (std.mem.eql(u8, f[0], want.path)) break f[1];
        } else null),
    };
}

/// A finished preprocessor over `src` (unit `<source>`); the caller deinits.
fn preprocess(opts: Options, src: []const u8, disk: Disk) !Preprocessor {
    var pp: Preprocessor = .init(testing.allocator, opts);
    errdefer pp.deinit();
    try pp.addUnit("<source>", src);
    try finish(&pp, disk);
    return pp;
}

/// Expects `src`, preprocessed without the prelude, to be exactly
/// `expected`, with no diagnostic.
fn expectPp(expected: []const u8, src: []const u8) !void {
    var pp = try preprocess(.{ .std_defs = false }, src, &.{});
    defer pp.deinit();
    const out = pp.output();
    try testing.expectEqual(@as(usize, 0), out.diagnostics.len);
    try testing.expectEqualStrings(expected, out.text);
}

/// Expects `src` to keep its newline count, and the output to contain every
/// `present` string and no `absent` one.
fn expectPreserved(src: []const u8, present: []const []const u8, absent: []const []const u8) !void {
    var pp = try preprocess(.{ .std_defs = false }, src, &.{});
    defer pp.deinit();
    const out = pp.output();
    try testing.expect(!out.failed);
    try testing.expectEqual(std.mem.countScalar(u8, src, '\n'), std.mem.countScalar(u8, out.text, '\n'));
    for (present) |s| try testing.expect(std.mem.find(u8, out.text, s) != null);
    for (absent) |s| try testing.expect(std.mem.find(u8, out.text, s) == null);
}

/// Expects `src` to fail with exactly one diagnostic, `code`, whose span
/// lies inside the file it names.
fn expectFail(src: []const u8, code: []const u8) !void {
    try expectFailWith(.{ .std_defs = false }, src, &.{}, code);
}

fn expectFailWith(opts: Options, src: []const u8, disk: Disk, code: []const u8) !void {
    var pp = try preprocess(opts, src, disk);
    defer pp.deinit();
    const out = pp.output();
    try testing.expect(out.failed);
    try testing.expectEqual(@as(usize, 1), out.diagnostics.len);
    const d = out.diagnostics[0];
    try testing.expectEqualStrings(code, d.code);
    try testing.expect(d.file != .none);
    try testing.expect(d.start <= d.end);
    try testing.expect(d.end <= out.files[@backingInt(d.file)].text.len);
}

/// The text of `src` preprocessed without the prelude, on `testing.allocator`.
fn textOf(src: []const u8) ![]u8 {
    var pp = try preprocess(.{ .std_defs = false }, src, &.{});
    defer pp.deinit();
    try testing.expect(!pp.output().failed);
    return testing.allocator.dupe(u8, pp.output().text);
}

/// Expects the source map sorted by `out` (`Output.resolve` bisects it) and
/// every event table in text-stream order inside the text.
fn expectSorted(out: Preprocessor.Output) !void {
    const m = out.source_map;
    for (m[0..m.len -| 1], m[@min(1, m.len)..]) |a, b| try testing.expect(a.out <= b.out);
    inline for (@typeInfo(events.Directives).@"struct".field_names) |name| {
        const list = @field(out.directives, name);
        for (list, 0..) |e, k| {
            try testing.expect(e.at <= out.text.len);
            if (k > 0) try testing.expect(list[k - 1].at <= e.at);
        }
    }
}

/// `src` with `n` nested uses of `M(x) (x)` around `1`, and its expansion.
fn nestedUses(n: usize) !struct { src: []u8, want: []u8 } {
    var src: std.ArrayList(u8) = .empty;
    errdefer src.deinit(testing.allocator);
    var want: std.ArrayList(u8) = .empty;
    errdefer want.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "`define M(x) (x)\n");
    try want.append(testing.allocator, '\n');
    for (0..n) |_| try src.appendSlice(testing.allocator, "`M(");
    try want.appendNTimes(testing.allocator, '(', n);
    try src.append(testing.allocator, '1');
    try want.append(testing.allocator, '1');
    try src.appendNTimes(testing.allocator, ')', n);
    try want.appendNTimes(testing.allocator, ')', n);
    return .{ .src = try src.toOwnedSlice(testing.allocator), .want = try want.toOwnedSlice(testing.allocator) };
}

/// A chain `M<k>` = `M<k-1>` of `n` macros ending in `end`, used once.
fn chain(n: usize) ![]u8 {
    var src: std.ArrayList(u8) = .empty;
    errdefer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "`define M0 end\n");
    for (1..n) |k| try src.print(testing.allocator, "`define M{d} `M{d}\n", .{ k, k - 1 });
    try src.print(testing.allocator, "`M{d}\n", .{n - 1});
    return src.toOwnedSlice(testing.allocator);
}

fn runAll(gpa: Allocator, src: []const u8) !void {
    var pp: Preprocessor = .init(gpa, .{ .std_defs = false, .include_dirs = &.{"d"} });
    defer pp.deinit();
    try pp.addUnit("<source>", src);
    while (try pp.run()) |_| try pp.answer(null);
}

test "requests: the includer's directory, each include dir in order, then the built-ins at no cost" {
    // Oracle: IEEE 1364 §19.5 and VD-091's search order, as the old reader
    // tried it; each candidate is asked once, and a null moves on.
    var pp: Preprocessor = .init(testing.allocator, .{ .std_defs = false, .include_dirs = &.{ "i1", "i2" } });
    defer pp.deinit();
    try pp.addUnit("src/top.va", "`include \"a.vh\"\n`include \"a.vh\"\n`include \"constants.vams\"\n");
    const want = [_][]const u8{ "src/a.vh", "i1/a.vh", "i2/a.vh", "src/constants.vams", "i1/constants.vams", "i2/constants.vams" };
    var asked: usize = 0;
    while (try pp.run()) |req| {
        try testing.expectEqualStrings(want[asked], req.file.path);
        asked += 1;
        try pp.answer(if (asked == 3) "`define A 1\n" else null);
    }
    try testing.expectEqual(want.len, asked);
    const out = pp.output();
    try testing.expect(!out.failed);
    // `__FILE__` in an include reads the path it was opened by (§10.7).
    try testing.expectEqualStrings("i2/a.vh", out.files[1].name);
    try testing.expectEqualStrings("constants.vams", out.files[3].name);
}

test "requests: an absolute path is asked as written, and a unit named <...> has no directory" {
    var pp: Preprocessor = .init(testing.allocator, .{ .std_defs = false });
    defer pp.deinit();
    try pp.addUnit("<source>", "`include \"/abs/abs.vh\"\n`ABS_OK\n");
    const req = (try pp.run()).?;
    try testing.expectEqualStrings("/abs/abs.vh", req.file.path);
    try pp.answer("`define ABS_OK 7\n");
    try testing.expectEqual(@as(?Preprocessor.Request, null), try pp.run());
    try testing.expectEqualStrings("\n\n7\n", pp.output().text);
}

test "requests: an answer past max_text_bytes is E1013" {
    // A slice with the length of a file one byte past the bound; the
    // preprocessor refuses it by its length and never reads it.
    var one: [1]u8 = .{0};
    const huge = @as([*]const u8, &one)[0 .. @as(usize, Preprocessor.max_text_bytes) + 1];
    try expectFailWith(.{ .std_defs = false, .include_dirs = &.{"d"} }, "`include \"huge.vh\"\n", &.{.{ "d/huge.vh", huge }}, "E1013");
}

test "§2.4 comments vanish, newlines do not, but the separator survives" {
    try expectPp("a\n\nb\n", "a// gone\n/* two\n   lines */b\n");
    try expectPp("\"// not a comment\"\n", "\"// not a comment\"\n");
    // Block comments do not nest: the first `*/` closes it.
    try expectPp("x   y\n", "x /* a /* b */ y\n");
    try expectFail("x\n/* never closed\n", "E0102");
    // §2.2: a comment is a token separator.
    try expectPp("1 2", "1/*c*/2");
    try expectPp("a < = b", "a </*c*/= b");
    try expectPp("1\n2", "1/*\n*/2");
}

test "§2.4 comment corners: end of file, `/*/`, and markers inside opaque tokens" {
    try expectPp("a", "a// x");
    try expectFail("/*/", "E0102");
    try expectPp("a b", "a/**/b");
    try expectPp("\\a//b c", "\\a//b c");
    try expectPp("\"a\\\"//b\"", "\"a\\\"//b\"");
    try expectPp("a\nb", "a//c\r\nb");
    try expectPp("\"abc\n\nx", "\"abc\n// c\nx");
    // IEEE 1364 §19.3.1: the `\` ending a `//` comment in macro text still
    // continues the macro (iverilog br_gh435); outside a `define it does not.
    try expectPp("\n\na b\n", "`define M a // c \\\n  b\n`M\n");
    try expectPp("\n\n\na b\n", "`define M \\\n  a // c \\\n  b\n`M\n");
    try expectPp("a \nb", "a // c \\\nb");
}

test "IEEE 1364 §19.3.1: a `\\` ending a line inside a block comment continues `define text" {
    // Oracle: iverilog macro_comment_multiline.
    try expectPp("\n\n(1 + 2)", "`define T(a,b) (a + /* x \\\n y */ b)\n`T(1,2)");
    try expectPp("a\n b", "a/* x \\\n y */ b");
}

test "§10.4 object-like and function-like macros" {
    try expectPp("\n3.0*v", "`define GAIN 3.0\n`GAIN*v");
    try expectPp("\n((v)*(v))", "`define SQ(x) ((x)*(x))\n`SQ(v)");
    try expectPp("\n\n(((v)*(v)) + (v))", "`define I(x) ((x)*(x))\n`define O(x) (`I(x) + (x))\n`O(v)");
    try expectPp("\n\n(1 + 2)", "`define P (1 + \\\n2)\n`P");
    // A formal is substituted only as a whole identifier, never in a string.
    try expectPp("\n\"x\" ax 1", "`define M(x) \"x\" ax x\n`M(1)");
    try expectPp("\n(max(a,b))+(c)", "`define A(p,q) (p)+(q)\n`A(max(a,b), c)");
    try expectFail("`define SQ(x) x\n`SQ\n", "E0116");
    try expectFail("`define SQ(x) x\n`SQ(1,2)\n", "E0117");
    try expectPp("\nreal \\sig-x ;", "`define M(x) real \\sig-x ;\n`M(1)");
}

test "IEEE 1800-2017 §22.5.1 `\" `\\`\" and `` in macro text, and W0151 under IEEE 1364" {
    // Oracle: the clause's own examples, as the LRM prints them (and as
    // `iverilog -E` expands them).
    const cases = [_][2][]const u8{
        .{ "\n$display(\"left side: \\\"right side\\\"\");", "`define msg(x,y) `\"x: `\\`\"y`\\`\"`\"\n$display(`msg(left side,right side));" },
        .{ "\nclock_master", "`define append(f) f``_master\n`append(clock)" },
        .{ "\n\"x\" \"1\"", "`define M(x) \"x\" `\"x`\"\n`M(1)" },
        .{ "\n\"a b\"", "`define S `\"a b`\"\n`S" },
    };
    for (cases) |c| {
        try expectPp(c[0], c[1]);
        var pp = try preprocess(.{ .std_defs = false, .std_1364 = true }, c[1], &.{});
        defer pp.deinit();
        const out = pp.output();
        try testing.expectEqualStrings(c[0], out.text);
        try testing.expectEqual(@as(usize, 1), out.diagnostics.len);
        try testing.expectEqualStrings("W0151", out.diagnostics[0].code);
        try testing.expect(!out.failed);
    }
    try expectFail("`\"a`\"\n", "E0103");
}

test "§10.4 macro argument brackets must match their openers" {
    try expectPp("\n{[(a)],b}", "`define SQ(x) x\n`SQ({[(a)],b})");
    try expectFail("`define SQ(x) x\n`SQ(2.0]\n", "E0120");
    try expectFail("`define SQ(x) x\n`SQ({a)}\n", "E0120");
    try expectFail("`define SQ(x) x\n`SQ([1,2)]\n", "E0120");
}

test "§10.4 a nested invocation in an actual argument is not recursion" {
    try expectPp(
        "\n((((1.0)>(2.0)?(1.0):(2.0)))>(3.0)?(((1.0)>(2.0)?(1.0):(2.0))):(3.0))",
        "`define MAX(a,b) ((a)>(b)?(a):(b))\n`MAX(`MAX(1.0,2.0),3.0)",
    );
    try expectPp("\n\n((7.0)>(2.0)?(7.0):(2.0))", "`define A 7.0\n`define MAX(a,b) ((a)>(b)?(a):(b))\n`MAX(`A,2.0)");
    try expectFail("`define R `R\n`R\n", "E0118");
    try expectFail("`define F(x) `F(x)\n`F(1)\n", "E0118");
    try expectFail("`define A(x) `B(x)\n`define B(y) `A(y)\n`A(1)\n", "E0118");
}

test "E0150: the text bound, on an expansion and on the whole stream" {
    // A macro doubling its text 40 times is 2^40 bytes: refused by name once
    // it passes the bound (lowered to 64 KiB here); 14 doublings fit.
    var dbl: std.ArrayList(u8) = .empty;
    defer dbl.deinit(testing.allocator);
    try dbl.appendSlice(testing.allocator, "`define D0 x\n");
    for (1..41) |i| try dbl.print(testing.allocator, "`define D{d} `D{d} `D{d}\n", .{ i, i - 1, i - 1 });
    const head = dbl.items.len;
    try dbl.appendSlice(testing.allocator, "`D40\n");
    try expectFailWith(.{ .std_defs = false, .text_limit = 1 << 16 }, dbl.items, &.{}, "E0150");
    dbl.shrinkRetainingCapacity(head);
    try dbl.appendSlice(testing.allocator, "`D14\n");
    var pp = try preprocess(.{ .std_defs = false, .text_limit = 1 << 16 }, dbl.items, &.{});
    defer pp.deinit();
    try testing.expect(!pp.output().failed);
    try testing.expectEqual(@as(usize, 1 << 14), std.mem.countScalar(u8, pp.output().text, 'x'));
    // The prelude alone passes 64 bytes, though the unit is under it.
    try expectFailWith(.{ .text_limit = 64 }, "module m; endmodule\n", &.{}, "E0150");
}

test "lib/TODO.md §11.2: nesting is capped at nesting_max with E0119, and runs to the cap" {
    // 129 nested uses was one past the old 128-level cap; the cap is now
    // `nesting_max`, which each shape reaches inside the test's stack.
    for ([_]usize{ 129, Preprocessor.nesting_max - 1 }) |n| {
        const t = try nestedUses(n);
        defer testing.allocator.free(t.src);
        defer testing.allocator.free(t.want);
        try expectPp(t.want, t.src);
    }
    {
        const t = try nestedUses(Preprocessor.nesting_max + 1);
        defer testing.allocator.free(t.src);
        defer testing.allocator.free(t.want);
        try expectFail(t.src, "E0119");
    }
    // A chain: M<k> expands to M<k-1>, one level each.
    {
        const src = try chain(Preprocessor.nesting_max);
        defer testing.allocator.free(src);
        const got = try textOf(src);
        defer testing.allocator.free(got);
        try testing.expect(std.mem.endsWith(u8, got, "end\n"));
    }
    {
        const src = try chain(Preprocessor.nesting_max + 1);
        defer testing.allocator.free(src);
        try expectFail(src, "E0119");
    }
    // A file that includes itself one conditional deeper each time never
    // repeats its state (so no E0125) and nests until the cap: E0119 after
    // the deepest stack the include shape builds, from one request.
    try expectFailWith(.{ .std_defs = false, .include_dirs = &.{"d"} }, "`define X\n`include \"self.vh\"\n", &.{
        .{ "d/self.vh", "`ifdef X\n`include \"self.vh\"\n`endif\n" },
    }, "E0119");
    // A chain of 40 distinct files (the old cap was 32) ends.
    var disk: std.ArrayList(DiskFile) = .empty;
    defer {
        for (disk.items) |f| {
            testing.allocator.free(f[0]);
            testing.allocator.free(f[1]);
        }
        disk.deinit(testing.allocator);
    }
    for (0..40) |k| {
        const name = try testing.allocator.print("d/a{d}.vh", .{k});
        const data = if (k + 1 == 40) try testing.allocator.dupe(u8, "deepest\n") else try testing.allocator.print("`include \"a{d}.vh\"\n", .{k + 1});
        try disk.append(testing.allocator, .{ name, data });
    }
    var pp = try preprocess(.{ .std_defs = false, .include_dirs = &.{"d"} }, "`include \"a0.vh\"\n", disk.items);
    defer pp.deinit();
    try testing.expect(std.mem.find(u8, pp.output().text, "deepest") != null);
    try expectFail("`define A `B\n`define B `A\n`A\n", "E0118");
}

test "escaped identifiers reach `undef, the conditionals and `default_discipline" {
    try expectPreserved("`define \\M-X 1\n`ifdef \\M-X\nyes\n`else\nno\n`endif\n", &.{"yes"}, &.{"no"});
    try expectPreserved("`define \\M-X 1\n`undef \\M-X\n`ifndef \\M-X\nyes\n`endif\n", &.{"yes"}, &.{});
    try expectPreserved("`define \\M-X 1\n`ifdef NOPE\na\n`elsif \\M-X\nb\n`else\nc\n`endif\n", &.{"b"}, &.{ "a", "c" });
    var pp = try preprocess(.{ .std_defs = false }, "`default_discipline \\logic\n", &.{});
    defer pp.deinit();
    const defs = pp.output().directives.disciplines;
    try testing.expectEqual(@as(usize, 1), defs.len);
    try testing.expectEqualStrings("logic", defs[0].discipline);
}

test "IEEE 1364 §19.5: only white space or a comment follows an `include" {
    try expectFail("`include \"constants.vams\" x\n", "E0144");
    testing.allocator.free(try textOf("`include \"constants.vams\" // why\n`include \"constants.vams\" /* why */\n"));
}

test "§2.8: a macro name does not start with $, unless escaped" {
    try expectFail("`define $X 1\n", "E0109");
    try expectPreserved("`define \\$X 1\n`\\$X \n", &.{"1"}, &.{});
}

test "IEEE 1364 §19.3.1: macro text does not split a string" {
    try expectFail("`define first_half \"start of string\n", "E0145");
    try expectPreserved("`define S \"a \\\" b\"\n`S\n", &.{"b"}, &.{});
    try expectPreserved("`define E \\q\"x \n`E\n", &.{"q\"x"}, &.{});
}

test "IEEE 1364 §19.3.1: every directive name is refused as a macro name, escaped or not" {
    try expectFail("`define __LINE__ 7\n", "E0143");
    try expectPreserved("`define includes 1\n`includes\n", &.{"1"}, &.{});
    for (directive_map.keys()) |name| {
        for ([_][]const u8{ "", "\\" }) |prefix| {
            const src = try testing.allocator.print("`define {s}{s} 1\n", .{ prefix, name });
            defer testing.allocator.free(src);
            try expectFail(src, "E0143");
        }
    }
}

test "§10.4 undef, and IEEE 1364 §19.4 conditionals" {
    try expectPreserved("`define A\n`undef A\n`ifdef A\ntaken\n`else\nother\n`endif\n", &.{"other"}, &.{"taken"});
    try expectPreserved("`define S\n`ifdef F\n1\n`elsif S\n2\n`else\n3\n`endif\n", &.{"2"}, &.{ "1", "3" });
    try expectPreserved("`define O\n`define I\n`ifdef O\n`ifdef I\nsix\n`else\ntwo\n`endif\n`else\none\n`endif\n", &.{"six"}, &.{ "two", "one" });
    try expectPreserved("`ifndef NOPE\nyes\n`else\nno\n`endif\n", &.{"yes"}, &.{"no"});
    try expectPreserved("`ifdef NOPE\n`MISSING\n`endif\n", &.{}, &.{"MISSING"});
    try expectFail("`ifdef A\nx\n", "E0101");
    try expectFail("`endif\n", "E0108");
    try expectFail("`ifdef A\n`else\n`else\n`endif\n", "E0106");
}

test "IEEE 1364 §19.4: the first true arm wins, a dead parent kills every arm, and text may follow the operand" {
    try expectPreserved("`define A\n`define B\n`ifdef A\na\n`elsif B\nb\n`else\nc\n`endif\n", &.{"a"}, &.{ "b", "c" });
    try expectPreserved("`ifdef N\n`ifdef M\nx\n`else\ny\n`endif\n`endif\n", &.{}, &.{ "x", "y" });
    try expectPreserved("`ifdef N\n`elsif N\nx\n`elsif __VERA__\ny\n`endif\n", &.{"y"}, &.{"x"});
    try expectPp("\n x\n\n", "`define A\n`ifdef A x\n`endif\n");
    try expectPreserved("`ifdef N\n`else junk\n`endif\n", &.{"junk"}, &.{});
    try expectFail("`else\n", "E0105");
    try expectFail("`elsif A\n", "E0105");
    try expectFail("`ifdef A\n`elsif\n`endif\n", "E0107");
    try expectFail("`ifdef A\n`else\n`elsif B\n`endif\n", "E0106");
    try expectFail("`ifndef\n", "E0104");
    try expectPreserved("`ifdef N\n`define X\n`endif\n`ifdef X\nyes\n`endif\n", &.{}, &.{"yes"});
}

test "E0101 points at the end of the file the open `ifdef is in" {
    const src = "x\n`ifdef A\ny\n";
    var pp = try preprocess(.{ .std_defs = false }, src, &.{});
    defer pp.deinit();
    const d = pp.output().diagnostics[0];
    try testing.expectEqualStrings("E0101", d.code);
    try testing.expectEqual(@as(u32, src.len), d.start);
}

test "§10.5 predefined macros survive undef; user macros survive resetall" {
    try expectPreserved("`ifdef __VAMS_ENABLE__\nyes\n`endif\n", &.{"yes"}, &.{});
    try expectPreserved("`undef __VAMS_ENABLE__\n`ifdef __VAMS_ENABLE__\nyes\n`endif\n", &.{"yes"}, &.{});
    // IEEE 1364 §19.3: "The text macro facility is not affected by ... `resetall".
    try expectPreserved("`define V 2.0\n`resetall\n`V\n", &.{"2.0"}, &.{});
    try expectPreserved("`resetall\n`ifdef __VAMS_ENABLE__\nyes\n`endif\n", &.{"yes"}, &.{});
}

test "§9.15 Table 9-27 reads `timescale back, in seconds" {
    const T = struct {
        /// The last `timescale event of `src`: the one §9.15 reads.
        fn ts(src: []const u8) !?events.Timescale {
            var pp = try preprocess(.{ .std_defs = false }, src, &.{});
            defer pp.deinit();
            const list = pp.output().directives.timescales;
            return if (list.len == 0) null else list[list.len - 1].value;
        }
    };
    const t = (try T.ts("`timescale 1ns/1ps\n")).?;
    try testing.expectEqual(@as(f64, 1e-9), t.unit);
    try testing.expectEqual(@as(f64, 1e-12), t.precision);
    const t2 = (try T.ts("`timescale 100us / 10 ns\n")).?;
    try testing.expectEqual(@as(f64, 100e-6), t2.unit);
    try testing.expectEqual(@as(f64, 10e-9), t2.precision);
    try testing.expectEqual(@as(?events.Timescale, null), try T.ts("module m; endmodule\n"));
    try testing.expectEqual(@as(?events.Timescale, null), try T.ts("`timescale 1ns/1ps\n`resetall\n"));
    for ([_][]const u8{
        "`timescale 2ns/1ps\n",  "`timescale 1sec/1ps\n",     "`timescale 1ns 1ps\n",
        "`timescale 1ps/1ns\n",  "`timescale 1ns/1ps junk\n", "`timescale\n",
        "`timescale 01ns/1ps\n",
    }) |src| try expectFail(src, "E0142");
    try testing.expectEqual(@as(f64, 1e-3), (try T.ts("`timescale 1ns/1ps\n`timescale 1ms/1us\n")).?.unit);
    // Table 19-1: every magnitude and unit is its exact decimal. Oracle: the
    // literal `1e<n>` through `std.fmt.parseFloat`, which rounds correctly.
    var buf: [16]u8 = undefined;
    for ([_]struct { []const u8, i32 }{ .{ "1", 0 }, .{ "10", 1 }, .{ "100", 2 } }) |m| {
        for ([_]struct { []const u8, i32 }{ .{ "s", 0 }, .{ "ms", -3 }, .{ "us", -6 }, .{ "ns", -9 }, .{ "ps", -12 }, .{ "fs", -15 } }) |u| {
            const want = try std.fmt.parseFloat(f64, try std.mem.print(&buf, "1e{d}", .{m[1] + u[1]}));
            const src = try testing.allocator.print("`timescale {s}{s}/1fs\n", .{ m[0], u[0] });
            defer testing.allocator.free(src);
            try testing.expectEqual(want, (try T.ts(src)).?.unit);
        }
    }
}

test "directives that contribute no text, and rejected ones" {
    try expectPp("\n\n\n", "`timescale 1ns/1ps\n`celldefine\n`pragma f harmless\n");
    try expectPp("`default_nettype\n`unconnected_drive\n", "`default_nettype wire\n`unconnected_drive pull1\n");
    try expectFail("`pragma\n", "E0147");
    try expectFail("`line 3 \"f.v\" 0 // no\n", "E0128");
    try expectPp("\n`default_transition\n", "`default_discipline electrical\n`default_transition 1n\n");
    try expectPp("`begin_keywords \"VAMS-2023\"\n`end_keywords\n", "`begin_keywords \"VAMS-2023\"\n`end_keywords\n");
    try expectPp("\n\n\n", "`ifdef NOPE\n`begin_keywords \"VAMS-2.3\"\n`endif\n");
    try expectFail("`MISSING\n", "E0115");
    try expectFail("`nosuchdirective_or_macro\n", "E0115");
}

test "§10.1 a region directive written as a macro actual opens its region where the expansion lands" {
    // Oracle: the same directive written in place of the call.
    const head = "`define ID(x) x\nmodule a; endmodule\n";
    const tail = "\nmodule b; endmodule\n";
    for ([_][]const u8{
        "`timescale 1ns/1ps",       "`default_discipline electrical", "`default_transition 1n",
        "`default_nettype none",    "`celldefine",                    "`endcelldefine",
        "`unconnected_drive pull1", "`nounconnected_drive",           "`resetall",
    }) |d| {
        const direct_src = try std.mem.concat(testing.allocator, u8, &.{ head, d, tail });
        defer testing.allocator.free(direct_src);
        const actual_src = try std.mem.concat(testing.allocator, u8, &.{ head, "`ID(", d, ")", tail });
        defer testing.allocator.free(actual_src);
        var direct = try preprocess(.{ .std_defs = false }, direct_src, &.{});
        defer direct.deinit();
        var actual = try preprocess(.{ .std_defs = false }, actual_src, &.{});
        defer actual.deinit();
        try testing.expectEqual(@as(usize, 0), direct.output().diagnostics.len + actual.output().diagnostics.len);
        try testing.expectEqualStrings(direct.output().text, actual.output().text);
        try testing.expectEqualDeep(direct.output().directives, actual.output().directives);
    }
}

test "IEEE 1364 §19.2 `default_nettype publishes a region per directive" {
    var all = try preprocess(.{ .std_defs = false },
        \\`default_nettype wire
        \\`default_nettype tri
        \\`default_nettype tri0
        \\`default_nettype tri1
        \\`default_nettype wand
        \\`default_nettype triand
        \\`default_nettype wor
        \\`default_nettype trior
        \\`default_nettype trireg
        \\`default_nettype uwire
        \\`default_nettype none
        \\
    , &.{});
    defer all.deinit();
    const n = all.output().directives.nettypes;
    try testing.expectEqual(@as(usize, 11), n.len);
    try testing.expectEqual(events.NetType.wire, n[0].value);
    try testing.expectEqual(events.NetType.uwire, n[9].value);
    try testing.expectEqual(events.NetType.none, n[10].value);
    // Syntax 19-2: a word alone on its line takes the next nonblank one.
    var next = try preprocess(.{ .std_defs = false }, "`default_nettype\n\n  none\n`unconnected_drive\npull1\n", &.{});
    defer next.deinit();
    try testing.expectEqual(events.NetType.none, next.output().directives.nettypes[0].value);
    try testing.expectEqual(events.Drive.pull1, next.output().directives.drives[0].value);
    try testing.expectEqualStrings("`default_nettype\n\n\n`unconnected_drive\n\n", next.output().text);
    for ([_][]const u8{
        "`default_nettype reg\n",   "`default_nettype real\n", "`default_nettype supply0\n",
        "`default_nettype wires\n", "`default_nettype\n",      "`default_nettype wire tri\n",
    }) |src| try expectFail(src, "E0140");
    // §19.6: `resetall is an event, not an erasure.
    var reset = try preprocess(.{ .std_defs = false }, "`default_nettype none\n`resetall\n", &.{});
    defer reset.deinit();
    const r = reset.output().directives.nettypes;
    try testing.expectEqual(@as(usize, 2), r.len);
    try testing.expectEqual(events.NetType.none, r[0].value);
    try testing.expectEqual(events.NetType.wire, r[1].value);
}

test "IEEE 1364 §19.1 `celldefine and §19.9 `unconnected_drive publish their regions" {
    var cells = try preprocess(.{ .std_defs = false }, "module a; endmodule\n`celldefine\nmodule c; endmodule\n`endcelldefine\n", &.{});
    defer cells.deinit();
    const c = cells.output().directives.cells;
    try testing.expectEqual(@as(usize, 2), c.len);
    try testing.expect(c[0].value);
    try testing.expect(!c[1].value);
    try testing.expect(c[0].at < c[1].at);
    var drives = try preprocess(.{ .std_defs = false }, "`unconnected_drive pull1\n`nounconnected_drive\n`unconnected_drive pull0\n`nounconnected_drive pull1\n", &.{});
    defer drives.deinit();
    const d = drives.output().directives.drives;
    try testing.expectEqual(@as(usize, 4), d.len);
    try testing.expectEqual(events.Drive.pull1, d[0].value);
    try testing.expectEqual(events.Drive.float, d[1].value);
    try testing.expectEqual(events.Drive.pull0, d[2].value);
    // The operand-less directive does not police its line.
    try testing.expectEqual(events.Drive.float, d[3].value);
    for ([_][]const u8{ "`unconnected_drive\n", "`unconnected_drive pull2\n", "`unconnected_drive float\n", "`unconnected_drive pull1 pull0\n" }) |src|
        try expectFail(src, "E0141");
    // Two directives with no text between them publish at one offset.
    var two = try preprocess(.{ .std_defs = false }, "`celldefine`endcelldefine\n", &.{});
    defer two.deinit();
    const t = two.output().directives.cells;
    try testing.expectEqual(t[0].at, t[1].at);
}

test "§10.1 scopes a directive across a source file boundary" {
    var pp = try preprocess(.{ .std_defs = false }, "`default_nettype none\n`celldefine\n`include \"constants.vams\"\nmodule after; endmodule\n", &.{});
    defer pp.deinit();
    const d = pp.output().directives;
    try testing.expectEqual(@as(usize, 1), d.nettypes.len);
    try testing.expectEqual(@as(usize, 1), d.cells.len);
}

test "IEEE 1364 §19.6: `resetall writes one default event to every list" {
    var pp = try preprocess(.{ .std_defs = false }, "`resetall\n", &.{});
    defer pp.deinit();
    const out = pp.output();
    try testing.expectEqualStrings("`resetall\n", out.text);
    const d = out.directives;
    inline for (@typeInfo(events.Directives).@"struct".field_names) |name| {
        try testing.expectEqual(@as(usize, 1), @field(d, name).len);
    }
    try testing.expectEqual(events.NetType.wire, d.nettypes[0].value);
    try testing.expect(!d.cells[0].value);
    try testing.expectEqual(events.Drive.float, d.drives[0].value);
    try testing.expectEqual(@as(?f64, null), d.transitions[0].value);
    try testing.expectEqual(@as(?events.Timescale, null), d.timescales[0].value);
    try testing.expectEqualStrings("", d.disciplines[0].discipline);
}

test "§10.2 `default_discipline Syntax 10-1 publishes its name and qualifier" {
    try expectPp("\n\n\n", "`default_discipline\n`default_discipline electrical\n`default_discipline electrical wire\n");
    try expectFail("`default_discipline electrical electrical\n", "E0127");
    try expectFail("`default_discipline electrical wire junk\n", "E0127");
    var pp = try preprocess(.{ .std_defs = false }, "`default_discipline \\logic wreal\n`default_discipline\n`resetall\n", &.{});
    defer pp.deinit();
    const d = pp.output().directives.disciplines;
    try testing.expectEqual(@as(usize, 3), d.len);
    try testing.expectEqualStrings("logic", d[0].discipline);
    try testing.expectEqual(@as(?events.Qualifier, .wreal), d[0].qualifier);
    try testing.expectEqualStrings("", d[1].discipline);
    try testing.expectEqual(@as(?events.Qualifier, null), d[1].qualifier);
    try testing.expectEqualStrings("", d[2].discipline);
    try testing.expectEqual(@as(u32, 0), d[0].at);
    try testing.expectEqual(@as(u32, 1), d[1].at);
    try testing.expectEqual(@as(u32, 2), d[2].at);
}

test "§10.3 `default_transition Syntax 10-2: one finite non-negative §2.6 number" {
    const T = struct {
        fn first(src: []const u8) !?f64 {
            var pp = try preprocess(.{ .std_defs = false }, src, &.{});
            defer pp.deinit();
            return pp.output().directives.transitions[0].value;
        }
    };
    // Every §2.6.2 spelling of 4 ns.
    for ([_][]const u8{ "4n", "4e-9", "0.000000004", "4_000p", "+4n" }) |t| {
        const src = try testing.allocator.print("`default_transition {s}\n", .{t});
        defer testing.allocator.free(src);
        try testing.expectEqual(@as(?f64, 4e-9), try T.first(src));
    }
    try testing.expectEqual(@as(?f64, 0.0), try T.first("`default_transition 0\n"));
    var two = try preprocess(.{ .std_defs = false }, "`default_transition 8n\n`default_transition 4n\n`resetall\n", &.{});
    defer two.deinit();
    const e = two.output().directives.transitions;
    try testing.expectEqual(@as(usize, 3), e.len);
    try testing.expectEqual(@as(?f64, 8e-9), e[0].value);
    try testing.expect(e[0].at < e[1].at);
    try testing.expectEqual(@as(?f64, null), e[2].value);
    for ([_][]const u8{ "", "    ", "electrical", "-4n", "4n junk", "1e400", "inf", "nan", "0x10", "1.", ".5", "_1", "1e", "-", "4n4" }) |op| {
        const src = try testing.allocator.print("`default_transition {s}\n", .{op});
        defer testing.allocator.free(src);
        try expectFail(src, "E0129");
    }
}

test "§10.7 `__FILE__ and `__LINE__" {
    try expectPp("\"<source>\"\n", "`__FILE__\n");
    try expectPp("\n\n\n4 4\n", "// c\n`define X 1\n\n`__LINE__ `__LINE__\n");
    // IEEE 1364 §19.7 numbers the line after the directive.
    try expectPp("\n100\n101\n", "`line 100 \"virtual.va\" 0\n`__LINE__\n`__LINE__\n");
    try expectPp("\n\"virtual.va\"\n", "`line 100 \"virtual.va\" 0\n`__FILE__\n");
    try expectPp("\n6\n", "`line 6 \"f.va\" 2\n`__LINE__\n");
    for ([_][]const u8{ "`line\n", "`line nope\n", "`line 5\n", "`line 5 \"f.va\"\n", "`line 0 \"f.va\" 0\n", "`line 5 \"f.va\" 3\n", "`line 5 \"f.va\" 1 x\n" }) |src|
        try expectFail(src, "E0128");
    // In macro text and arguments: the invocation's line.
    try expectPp("\n\n3\n", "`define L `__LINE__\n\n`L\n");
    try expectPp("\n2\n\n", "`define I(x) x\n`I(\n`__LINE__)\n");
    try expectPp("\n2", "`undef __LINE__\n`__LINE__");
    // §2.7: a file name's `"` and `\` are escaped in the literal.
    var pp: Preprocessor = .init(testing.allocator, .{ .std_defs = false });
    defer pp.deinit();
    try pp.addUnit("<a\"b\\c.va>", "`__FILE__");
    try finish(&pp, &.{});
    try testing.expectEqualStrings("\"<a\\\"b\\\\c.va>\"", pp.output().text);
}

test "IEEE 1364 §19.7: only white space shares a `line directive's line" {
    try expectPp("  \n3\n", "  `line 3 \"f\" 0\n`__LINE__\n");
    try expectPp("\n\n3\n", "// c\n`line 3 \"f\" 0\n`__LINE__\n");
    try expectPp("\n\n\n3\n", "/* a\n b */\n`line 3 \"f\" 0\n`__LINE__\n");
    try expectFail("/* a\n*/`line 3 \"f\" 0\n", "E0128");
    try expectFail("`line 3 \"f\" 0 /* a\nb */\n", "E0128");
    try expectFail("x `line 3 \"f\" 0\n", "E0128");
    try expectFail("`line 4294967296 \"f\" 0\n", "E0128");
    try expectFail("`line 3 \"f 0\n", "E0128");
}

test "`include resolves the built-in annex files by basename, and reports which" {
    const got = try textOf("`include \"constants.vams\"\n`P_CELSIUS0 `P_K\n");
    defer testing.allocator.free(got);
    try testing.expect(std.mem.find(u8, got, "273.15") != null);
    try testing.expect(std.mem.find(u8, got, "1.3806503e-23") != null);
    // VD-091: a built-in is found by its basename wherever the name points.
    const pi = try textOf("`include \"no/such/dir/constants.vams\"\n`M_PI\n");
    defer testing.allocator.free(pi);
    try testing.expect(std.mem.find(u8, pi, "3.14159265358979323846") != null);
    // Annex D.3 is shipped, and not preloaded.
    const d3 = try textOf("`include \"driver_access.vams\"\n`DRIVER_WAND\n");
    defer testing.allocator.free(d3);
    try testing.expect(std.mem.find(u8, d3, "32'b10000000000") != null);
    try expectFail("`include \"no_such_file.vams\"\n", "E0126");
    try expectFail("`include nonsense\n", "E0122");
    try expectFail("`include <constants.vams>\n", "E0122");
    try expectFail("`include\n", "E0121");
    try expectFail("`include \"abc\n", "E0123");
    try expectFail("`include \"\"\n", "E0124");
    // VD-096: only annex D.1, under either name, asks for annex D's natures.
    for ([_]struct { []const u8, bool }{ .{ "disciplines.vams", true }, .{ "discipline.h", true }, .{ "constants.vams", false }, .{ "constants.h", false } }) |c| {
        const src = try testing.allocator.print("`include \"{s}\"\n", .{c[0]});
        defer testing.allocator.free(src);
        var pp = try preprocess(.{ .std_defs = false }, src, &.{});
        defer pp.deinit();
        try testing.expectEqual(c[1], pp.output().annex_d_included);
    }
}

test "§10.4 the NAME may be escaped and the TEXT may not begin with __VAMS_" {
    try expectPp("\n3.0 *v", "`define \\MY-GAIN 3.0\n`\\MY-GAIN *v");
    try expectPp("\n1", "`define \\SQ!(x) 1\n`\\SQ!(x)");
    try expectFail("`define MY_ENABLE __VAMS_ENABLE__\n", "E0139");
    try expectPp("\n7.0", "`define __VAMS_USER 7.0\n`__VAMS_USER");
}

test "§10.4 definitions: redefinition, empty text, empty lists and the formal list's grammar" {
    try expectPp("\n\n2", "`define A 1\n`define A 2\n`A");
    try expectPp("\n[]", "`define E\n[`E]");
    try expectPp("\nz", "`define Z() z\n`Z()");
    try expectFail("`define Z() z\n`Z\n", "E0116");
    try expectFail("`define Z() z\n`Z(1)\n", "E0117");
    try expectPp("\n[]", "`define I(x) [x]\n`I()");
    try expectFail("`define M(\n", "E0110");
    try expectFail("`define M(1) x\n", "E0110");
    try expectFail("`define M(a\n", "E0111");
    try expectFail("`define M(a b) x\n", "E0112");
    try expectFail("`define M($x) $x\n", "E0110");
    try expectFail("`define M(a,) a\n", "E0110");
    try expectFail("`define M(,a) a\n", "E0110");
    try expectPp("\n\na b", "`define P a \\\n   b\n`P");
    try expectPp("\n\na b", "`define P a\\\r\nb\n`P");
    try expectPp("\nx", "`undef NOPE\nx");
    try expectFail("`undef\n", "E0113");
    try expectFail("`define\n", "E0109");
}

test "IEEE 1364 §19.3.1 substitution: what a formal is not, and actuals that span lines" {
    try expectPp("\n\n9", "`define x 9\n`define M(x) `x\n`M(1)");
    try expectPp("\n1e-3+2", "`define M(e) 1e-3+e\n`M(2)");
    try expectPp("\n\"a,b)\"|c", "`define A(p,q) p|q\n`A(\"a,b)\", c)");
    try expectPp("\n\n7\n", "`define D `define X 7\n`D\n`X\n");
    try expectPp("\n[a +b]\n\nz\n", "`define M(x) [x]\n`M(a\n+b)\nz\n");
    try expectPp("\n\n[1+2]\n\n", "`define N(a,b) a+b\n`define M(x) [x]\n`M(`N(1,\n2))\n");
    // An escaped-identifier actual keeps its terminator (§2.8.1).
    try expectPreserved("`define ID(A) (A)\n`ID(\\a.b )\n", &.{"(\\a.b )"}, &.{});
    try expectPreserved("`define ID(A) (A)\n`ID(\"x\\n\")\n", &.{"(\"x\\n\")"}, &.{});
}

test "§2.7 strings and §2.8.1 escaped identifiers are opaque to the scan" {
    try expectPp("\"abc\nx", "\"abc\nx");
    try expectPp("\"`NOPE\" \\a`b c", "\"`NOPE\" \\a`b c");
    try expectFail("`ifdef N\n\"abc\n`endif\n", "E0138");
    try expectPreserved("`ifdef N\n\"a\\\nb\"\n`endif\n", &.{}, &.{ "a", "b" });
}

test "a grave accent needs a name, except inside an inactive arm" {
    try expectFail("`\n", "E0103");
    try expectFail("` x\n", "E0103");
    try expectFail("`\\ x\n", "E0103");
    try expectPp("\n\n\n", "`ifdef N\n` x\n`endif\n");
}

test "IEEE 1364-2005 §28.4: protect metadata has no action outside an envelope" {
    try expectPp("\nx", "`pragma protect author=\"a, b\", comment=\"c\"\nx");
    try expectPp("\n\n", "`pragma protect\n`pragma protect end\n");
    try expectFail("`pragma protect data_method=\"x\", begin_protected\n", "E0146");
    try expectFail("`pragma protect encoding=(enctype=\"raw\"), begin\n", "E0146");
    try expectFail("`pragma protect data_block\n", "E0146");
}

test "IEEE 1364-2005 §28.2: a decryption envelope is scanned as its cleartext" {
    // Oracle: openssl. `printf '`define IN 7\nwire [`OUT:0] w;\n' | openssl
    // enc -des-cbc -K 0123456789abcdef -iv 1234567890abcdef | base64`.
    const src =
        \\`define OUT 3
        \\`pragma protect data_keyowner="o", data_keyname="k", data_method="des-cbc", begin_protected
        \\`pragma protect encoding=(enctype="base64", bytes=32), data_block
        \\n1Wn+COi7/PUYfw8LBpbP5gnjLT1WISNkOj0IsRnLq0=
        \\`pragma protect end_protected
        \\`IN
    ;
    var pp = try preprocess(.{ .std_defs = false, .protect_keys = des_keys }, src, &.{});
    defer pp.deinit();
    try testing.expectEqualStrings("\n\nwire [3:0] w;\n\n\n\n\n7", pp.output().text);
    try expectFail(src, "E0152");
    var wrong = des_keys;
    wrong.keys = &.{.{ .owner = "o", .name = "k", .key = @splat(0x13) }};
    try expectFailWith(.{ .std_defs = false, .protect_keys = wrong }, src, &.{}, "E0153");
}

test "IEEE 1364-2005 §28.4.28.2/§28.4.29.2: a model that needs a license is refused" {
    // Oracle: openssl, as above, over a cleartext naming a license library.
    const blocks = [_][]const u8{
        "CEwlPH76i0/T4ErznDzLTXiO/fE6M6hG3GhSHNfS7/xDln8Ij9YhlGvDdSAiWfxQwSrnuASTQUpW74zwFRsSJn9W7P96MsHSpspQji6DPl8OZgiasP3VMkEDmOyydfAs",
        "CEwlPH76i0/T4ErznDzLTf2CoUC4gdarIYnP3ZIMKbeRxjsdv/x8HzRzbmiT/cbcKjOyXX+w/u5DBgRZCS+jhtg4w9j0XU9Yjek/BBdWArASDFx6mvaKTKeskF+d+fkK",
    };
    for (blocks) |blk| {
        const src = try std.fmt.allocPrint(testing.allocator,
            \\`pragma protect data_keyowner="o", data_keyname="k", data_method="des-cbc", begin_protected
            \\`pragma protect encoding=(enctype="base64", bytes=96), data_block
            \\{s}
            \\`pragma protect end_protected
            \\
        , .{blk});
        defer testing.allocator.free(src);
        try expectFailWith(.{ .std_defs = false, .protect_keys = des_keys }, src, &.{}, "E0146");
    }
}

test "IEEE 1364-2005 §28.4.20: the digest key comes from the key_block, and each digest_block checks the block before it" {
    // The suite's protected_digest_decrypt_key.v (oracle: openssl, its
    // known_keys.json).
    const src =
        \\`pragma protect begin_protected
        \\`pragma protect key_keyowner="VerAConformance"
        \\`pragma protect key_keyname="exchange-fixture"
        \\`pragma protect key_method="des-cbc"
        \\`pragma protect digest_method="sha1"
        \\`pragma protect encoding=(enctype="base64",line_length=64,bytes=312)
        \\`pragma protect key_block
        \\HmR1lmmwZqix46pT213GCLJGD4OtmME9U7vcCpo4YqZvYw+xhz92F0XGsaoWCFUk
        \\7XX/HumQ/bJdtzV3L+V4hQ3xGQyD7cLJLKoHdUxF8U7PIUJWgVCgCzSqfXu4TQP0
        \\iLgc2dAxR7SLK1htwsLXI/uy0zMeDaVolUPGaRbW/+aWxd3Tf1ZtBGXIMDkIJ0xS
        \\q3071/nhOjSo/9Eb2gv3e7HxFXrM4TS2SE15E0GD8JEcaC0iro6aKyrlkb4osjlQ
        \\b4UWhpuTdN04tYDnrbbrj+UtDTbDlXty+9kM7xnYQ8e7IPait0kqpDgelCW9YcAx
        \\UQvMAHXAkI9pyfRdE75E3rC1KrYcAB4wY24GIsz6NIe5XxgDVgpru2s2thawBglq
        \\X008Pg5N4cOU/N/X4jHd/rYLcmWvsCB/
        \\`pragma protect encoding=(enctype="base64",line_length=64,bytes=24)
        \\`pragma protect digest_block
        \\QcnzcPxM6OaQOKgXHWfiEaeS8KZi4LB2
        \\`pragma protect encoding=(enctype="base64",line_length=64,bytes=80)
        \\`pragma protect data_block
        \\gHbCKL32373t8sEGvD15nckvxrVeIl860S8eWw2QhIG1ZVCMR+++LjLuTsN2m/dY
        \\N3sNtdQRLWi/uhem7bk4Jp0vCWN1q5BIQ0GHXjC9v7s=
        \\`pragma protect encoding=(enctype="base64",line_length=64,bytes=24)
        \\`pragma protect digest_block
        \\iRM7BMo+TyISaFZ2SU/cwn3BCebCzX3m
        \\`pragma protect end_protected
    ;
    const keys: Preprocessor.protect.Keys = .{
        .iv = des_keys.iv,
        .keys = &.{.{ .owner = "VerAConformance", .name = "exchange-fixture", .key = .{ 0x13, 0x34, 0x57, 0x79, 0x9b, 0xbc, 0xdf, 0xf1 } }},
    };
    var pp = try preprocess(.{ .std_defs = false, .protect_keys = keys }, "`define PROTECTED_VALUE 42\n" ++ src, &.{});
    defer pp.deinit();
    try testing.expect(std.mem.find(u8, pp.output().text, "$display(\"decrypted=%0d\",42)") != null);
    const bad = try std.mem.replaceOwned(u8, testing.allocator, src, "QcnzcPxM6OaQOKgXHWfiEaeS8KZi4LB2", "iRM7BMo+TyISaFZ2SU/cwn3BCebCzX3m");
    defer testing.allocator.free(bad);
    try expectFailWith(.{ .std_defs = false, .protect_keys = keys }, bad, &.{}, "E0153");
}

test "annex D prelude: deterministic, self-guarded, and an ABSTOL override reaches D.1" {
    const src = "`include \"disciplines.vams\"\nmodule m; endmodule\n";
    var a = try preprocess(.{}, src, &.{});
    defer a.deinit();
    var b = try preprocess(.{}, src, &.{});
    defer b.deinit();
    try testing.expectEqualStrings(a.output().text, b.output().text);
    // D.1 reached the output once: the re-include is guarded empty.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, a.output().text, "discipline electrical;"));
    try testing.expect(std.mem.endsWith(u8, a.output().text, "\nmodule m; endmodule\n"));
    var o = try preprocess(.{ .std_defs = false }, "`define CURRENT_ABSTOL 1e-15\n`include \"disciplines.vams\"\n", &.{});
    defer o.deinit();
    try testing.expect(std.mem.find(u8, o.output().text, "abstol      = 1e-15;") != null);
    try testing.expect(std.mem.find(u8, o.output().text, "abstol      = 1e-12;") == null);
}

test "require_std_includes: annex D reaches only a source that includes it" {
    const opts: Options = .{ .require_std_includes = true };
    // A D.2 macro without constants.vams is E0115; with it, it expands.
    try expectFailWith(opts, "`M_PI\n", &.{}, "E0115");
    var with = try preprocess(opts, std_includes ++ "`M_PI\n", &.{});
    defer with.deinit();
    try testing.expect(std.mem.endsWith(u8, with.output().text, "3.14159265358979323846\n"));
    try testing.expect(with.output().disciplines_included);
    // The suite's check.vh: D.1's guard reads undefined until the include,
    // so the include is not hidden by the prelude's copy.
    const guarded = "`ifndef DISCIPLINES_VAMS\nGUARD_OPEN\n`endif\n`include \"disciplines.vams\"\n`ifndef DISCIPLINES_VAMS\nGUARD_SHUT\n`endif\n";
    var g = try preprocess(opts, guarded, &.{});
    defer g.deinit();
    try testing.expect(std.mem.find(u8, g.output().text, "GUARD_OPEN") != null);
    try testing.expect(std.mem.find(u8, g.output().text, "GUARD_SHUT") == null);
    // Without the option the guards are the prelude's.
    var plain = try preprocess(.{}, guarded, &.{});
    defer plain.deinit();
    try testing.expect(std.mem.find(u8, plain.output().text, "GUARD_OPEN") == null);
}

test "IEEE 1364-2005 §13.4.1: units given together are one text stream" {
    var pp: Preprocessor = .init(testing.allocator, .{ .std_defs = false });
    defer pp.deinit();
    try pp.addUnit("<a>", "`define W 2\n`ifdef W\na");
    try pp.addUnit("b.v", "`W `__FILE__\n`endif\n");
    try finish(&pp, &.{});
    try testing.expectEqualStrings("\n\na\n2 \"b.v\"\n\n", pp.output().text);
    try testing.expectEqualSlices(u32, &.{4}, pp.output().unit_starts);
}

test "IEEE 1364 §19.5: include nesting repeats only in a repeating state, which is E0125" {
    // One file including itself under a guard that defines one more macro
    // each time (100 deep, so the state never repeats) ends; a file including
    // itself unchanged, or a pair including each other, never would.
    var guard: std.ArrayList(u8) = .empty;
    defer guard.deinit(testing.allocator);
    for (0..100) |k| try guard.print(testing.allocator, "`ifndef L{d}\n`define L{d}\n`else\n", .{ k, k });
    try guard.appendSlice(testing.allocator, "bottom\n`define DONE\n");
    for (0..100) |_| try guard.appendSlice(testing.allocator, "`endif\n");
    try guard.appendSlice(testing.allocator, "`ifndef DONE\n`include \"self.vh\"\n`endif\n");
    const disk: Disk = &.{
        .{ "d/self.vh", guard.items },
        .{ "d/loop.vh", "x\n`include \"loop.vh\"\n" },
        .{ "d/p.vh", "`include \"q.vh\"\n" },
        .{ "d/q.vh", "`include \"p.vh\"\n" },
    };
    const opts: Options = .{ .std_defs = false, .include_dirs = &.{"d"} };
    var self = try preprocess(opts, "`include \"self.vh\"\n", disk);
    defer self.deinit();
    try testing.expect(!self.output().failed);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, self.output().text, "bottom"));
    try expectFailWith(opts, "`include \"loop.vh\"\n", disk, "E0125");
    try expectFailWith(opts, "`include \"p.vh\"\n", disk, "E0125");
}

test "§10.7: a file included through a macro numbers its own lines and owns its diagnostics" {
    const disk: Disk = &.{
        .{ "d/lines.vh", "`define FROM_INC 5\n\n`__LINE__\n" },
        .{ "d/bad.vh", "\n\n`NOPE\n" },
        .{ "d/word.vh", "wire_from_inc\n" },
    };
    const opts: Options = .{ .std_defs = false, .include_dirs = &.{"d"} };
    {
        var pp = try preprocess(opts, "`define INC `include \"lines.vh\"\n`INC\n`FROM_INC\n", disk);
        defer pp.deinit();
        try testing.expectEqualStrings("\n\n\n3\n\n5\n", pp.output().text);
        try expectSorted(pp.output());
    }
    {
        var pp = try preprocess(opts, "`define INC `include \"bad.vh\"\n`INC\n", disk);
        defer pp.deinit();
        const out = pp.output();
        const d = out.diagnostics[0];
        try testing.expectEqualStrings("E0115", d.code);
        const f = out.files[@backingInt(d.file)];
        try testing.expectEqualStrings("d/bad.vh", f.name);
        try testing.expectEqualStrings("`NOPE", f.text[d.start..d.end]);
    }
    {
        // Through an actual, the included text maps to the invocation.
        const src = "`define INC `include \"word.vh\"\n`define ID(x) x\n`ID(`INC) tail\n";
        var pp = try preprocess(opts, src, disk);
        defer pp.deinit();
        const out = pp.output();
        try expectSorted(out);
        const r = out.resolve(@intCast(std.mem.find(u8, out.text, "wire_from_inc").?));
        try testing.expectEqual(@as(Preprocessor.File.Index, @fromBackingInt(@intCast(0))), r.file);
        try testing.expect(std.mem.startsWith(u8, src[r.offset..], "`ID("));
        const tail = out.resolve(@intCast(std.mem.find(u8, out.text, "tail").?));
        try testing.expectEqualStrings("tail\n", src[tail.offset..]);
    }
}

test "the source map: an include resolves to its own file, an expansion to its use" {
    const src = "module m;\n`include \"disciplines.vams\"\nendmodule\n`define SQ(x) ((x)*(x))\ny = `SQ(v) + 1;\n";
    var pp = try preprocess(.{ .std_defs = false }, src, &.{});
    defer pp.deinit();
    const out = pp.output();
    try expectSorted(out);
    const needle = "discipline electrical;";
    const r = out.resolve(@intCast(std.mem.find(u8, out.text, needle).?));
    const f = out.files[@backingInt(r.file)];
    try testing.expectEqualStrings("disciplines.vams", f.name);
    try testing.expectEqualStrings(needle, f.text[r.offset..][0..needle.len]);
    const top = out.resolve(@intCast(std.mem.find(u8, out.text, "module m;").?));
    try testing.expectEqual(@as(u32, 0), top.offset);
    const after = out.resolve(@intCast(std.mem.find(u8, out.text, "endmodule").?));
    try testing.expectEqualStrings("endmodule\n", src[after.offset..][0..10]);
    // Bytes that exist only in the expansion resolve to the `SQ that made them.
    const inside = out.resolve(@intCast(std.mem.find(u8, out.text, "((v)*(v))").? + 4));
    try testing.expect(std.mem.startsWith(u8, src[inside.offset..], "`SQ(v)"));
    const plus = out.resolve(@intCast(std.mem.find(u8, out.text, "+ 1").?));
    try testing.expectEqualStrings("+ 1;\n", src[plus.offset..]);
}

test "a diagnostic after a comment maps back to the column the user wrote" {
    // The '`' is at stripped offset 3 and at source offset 24.
    const src = "/* a leading comment */ `NOPE\n";
    var pp = try preprocess(.{ .std_defs = false }, src, &.{});
    defer pp.deinit();
    const out = pp.output();
    const d = out.diagnostics[0];
    try testing.expectEqualStrings("E0115", d.code);
    try testing.expectEqual(@as(u32, 2), d.start);
    try testing.expectEqual(@as(u32, 24), Preprocessor.toSourceOffset(out.files[0].marks, d.start));
}

test "every successful run keeps the line count and leaves sorted provenance" {
    // Swarm-style: random whole-line snippets. A failing sequence has its
    // diagnostic; every other one gives the output exactly the newlines of
    // the files it read, a sorted source map and sorted event tables.
    const snippets = [_][]const u8{
        "`define A 1\n",           "`define F(x) [x]\n",   "`define G(y) `F(y)\n", "`define B \\\n 2\n",
        "`A\n",                    "`B\n",                 "`F(a)\n",              "`F(a\nb)\n",
        "`G(b\nc)\n",              "`F(`A\n)\n",           "`F(`F(\nz))\n",        "`F(\"s\n",
        "/* c\n */\n",             "// c\n",               "x y\n",                "\"s\"\n",
        "`ifdef A\n",              "`ifndef A\n",          "`else\n",              "`endif\n",
        "`undef A\n",              "`timescale 1ns/1ps\n", "`celldefine\n",        "`endcelldefine\n",
        "`default_nettype none\n", "`resetall\n",          "`__LINE__\n",          "`include \"constants.vams\"\n",
    };
    var prng: std.Random.DefaultPrng = .init(0x11e5);
    const rand = prng.random();
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    for (0..3000) |_| {
        src.clearRetainingCapacity();
        for (0..rand.uintAtMost(usize, 12)) |_| try src.appendSlice(testing.allocator, snippets[rand.uintLessThan(usize, snippets.len)]);
        var pp = try preprocess(.{ .std_defs = false }, src.items, &.{});
        defer pp.deinit();
        const out = pp.output();
        if (out.failed) {
            try testing.expect(out.diagnostics.len > 0);
            continue;
        }
        var want: usize = 0;
        for (out.files) |f| want += std.mem.countScalar(u8, f.text, '\n');
        try testing.expectEqual(want, std.mem.countScalar(u8, out.text, '\n'));
        try expectSorted(out);
    }
}

test "run reports every allocation failure as OutOfMemory and leaks nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, runAll, .{
        "`define F(x) [x]\n`include \"constants.vams\"\n`ifdef M_PI\n`F(`M_PI)\n`endif\n" ++
            "`timescale 1ns/1ps\n`default_discipline electrical\n/* c */ `__LINE__ `__FILE__\n`include \"x.vh\"\n",
    });
}
