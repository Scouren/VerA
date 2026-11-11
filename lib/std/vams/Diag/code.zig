//! The diagnostic catalogue: `codes.zon` in, the `Code` enum, one `Info`
//! and one `Spec` row per code, and the spelling map out, all built at
//! comptime. `Code` is reified from the ZON keys in file order, so the
//! catalogue is the only list of codes; a duplicate key fails the ZON parse
//! and a malformed row (a missing field, a bad spelling, a titled-retired
//! row with a clause, a clause key off its kind's grammar, a duplicate or
//! skipped clause key) fails the build here.
//!
//! Cites no LRM clause: each row cites its own in `Spec.clause`. The key
//! grammar is research/diagcodes.md §3.1.
//!
//! Contents:
//! - `pub const Code = enum(u16)`, reified from `codes.zon`'s keys
//! - `pub const Info = struct { title, lrm, explain: []const u8 }`, `annexPrefix`
//! - `pub const Severity` (`word`), `Spec` (`Kind`, `Standard`), `Lookup`
//! - `pub fn info(c: Code) Info`, `spec`, `lookup`, `keyHasPrefix`

const std = @import("std");
const assert = std.debug.assert;
const catalogue = @import("codes.zon");

/// Every diagnosable condition, in `codes.zon` order (`E0101` is 0). The
/// tag name is the rendered spelling: one letter, then four digits. The
/// letter is the severity (`E` error, `W` warning) and the first two digits
/// the owning stage class. A code is never renumbered or reused; a retired
/// one keeps its row (`Info.title` is "(retired)"). The tag order is the
/// last key of the source sort, so a new code goes at the end of its run.
pub const Code = @Enum(u16, .exhaustive, &names, &std.simd.iota(u16, names.len));

/// Static documentation for one code; every field is a comptime string.
pub const Info = struct {
    /// Headline after `error[E0313]: `: a lowercase noun phrase with no
    /// trailing period; "(retired)" for a retired code.
    title: []const u8,
    /// LRM clause (`"5.6.1"`, `"A.6.4"`), printed under every diagnostic;
    /// empty for an engine limit or a retired code.
    lrm: []const u8,
    /// The `--explain` long form, pre-wrapped at 76 columns, printed verbatim.
    explain: []const u8,

    /// Returns `"annex "` when `lrm` names an annex (a letter A to H) and
    /// `""` otherwise, so `LRM annex C` never reads as a typo.
    pub fn annexPrefix(self: Info) []const u8 {
        if (self.lrm.len == 0) return "";
        return if (self.lrm[0] >= 'A' and self.lrm[0] <= 'H') "annex " else "";
    }

    comptime {
        assert(@sizeOf(Info) <= 48); // Three slices, one row per code.
    }
};

/// How a kept diagnostic affects the compilation: an `err` fails it. The
/// row's `severity`, which the comptime check ties to the code's first
/// letter, unless `--deny` promotes a warning.
pub const Severity = enum(u1) {
    err,
    warning,

    /// Returns the rendered word, also the JSON `level`.
    pub fn word(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
        };
    }
};

/// The identity half of a row (`Info` keeps the prose): what the gap
/// report joins against the specification ledgers.
pub const Spec = struct {
    /// The clause key (`AMS-5.6.7.2b`, `unsup-systemverilog`); a retired
    /// row's key is its own `Code` name.
    key: []const u8,
    /// A second clause the rule spans (`AMS-A.4.1`), or empty.
    also: []const u8,
    /// The clause under `std` (`5.6.7.2`, `A`), or empty with `.none`.
    clause: []const u8,
    /// Other spellings that resolve to this code: its `Code` name.
    aliases: []const []const u8,
    kind: Kind,
    std: Standard,
    severity: Severity,

    /// What a code's condition is, and so what the gap report reads it as.
    pub const Kind = enum(u3) {
        /// The source breaks a "shall" sentence of the cited clause.
        rule,
        /// The text does not derive from the grammar annex (`AMS-A-a`).
        syntax,
        /// A legal construct VerA refuses, or accepts and drops part of.
        unsup,
        /// A fixed engine capacity.
        limit,
        /// VerA's own advice on legal source; always a warning.
        lint,
        /// A compiler defect.
        ice,
        /// Kept so `--explain` and old scripts resolve; never raised.
        retired,
    };

    /// The pinned edition a clause belongs to: `AMS` is Verilog-AMS 2023,
    /// `V2005` IEEE 1364-2005, `VERA` VerA's own extensions (docs/using/).
    pub const Standard = enum(u3) { none, ams, v2005, vera, osdi, spice };

    comptime {
        assert(@sizeOf(Spec) <= 104); // Five slices and three small enums.
    }
};

/// What a spelling from outside names: one code, or a group alias's codes.
pub const Lookup = union(enum) { one: Code, group: []const Code };

/// The ZON keys, in file order: `Code`'s fields.
const names: [field_names.len][]const u8 = blk: {
    var out: [field_names.len][]const u8 = undefined;
    for (&out, field_names) |*o, n| o.* = n;
    break :blk out;
};
const field_names = @typeInfo(@TypeOf(catalogue)).@"struct".field_names;

comptime {
    assert(names.len < 1 << 10);
}

const table: std.enums.EnumArray(Code, Info) = blk: {
    @setEvalBranchQuota(200 * names.len);
    var t: std.enums.EnumArray(Code, Info) = undefined;
    for (names) |n| {
        const r = @field(catalogue, n);
        const row: Info = .{ .title = r.title, .lrm = r.lrm, .explain = r.explain };
        checkRow(n, row);
        t.set(@field(Code, n), row);
    }
    break :blk t;
};

const specs: std.enums.EnumArray(Code, Spec) = blk: {
    @setEvalBranchQuota(2000 * names.len);
    var t: std.enums.EnumArray(Code, Spec) = undefined;
    for (names) |n| t.set(@field(Code, n), specRow(n, @field(catalogue, n)));
    break :blk t;
};

/// Every key and every alias, each once.
const spellings: std.StaticStringMap(Lookup) = blk: {
    @setEvalBranchQuota(20 * names.len);
    const KV = struct { []const u8, Lookup };
    var kvs: [2 * names.len]KV = undefined;
    var len: usize = 0;
    for (names) |n| {
        const c = @field(Code, n);
        kvs[len] = .{ specs.get(c).key, .{ .one = c } };
        len += 1;
        for (specs.get(c).aliases) |a| {
            kvs[len] = .{ a, .{ .one = c } };
            len += 1;
        }
    }
    const final = kvs[0..len].*;
    break :blk .initComptime(final);
};

// The cross-row checks: no key is spelt twice, and a clause's letters run
// a, b, c... in catalogue order with none skipped.
comptime {
    @setEvalBranchQuota(2000 * names.len);
    for (names) |n| {
        const c = @field(Code, n);
        const s = specs.get(c);
        const o = spellings.get(s.key).?.one;
        if (o != c) @compileError(n ++ ": key `" ++ s.key ++ "` is also " ++ @tagName(o) ++ "'s key");
        const letters = parseKey(n, s.key, s.kind).letters;
        if (letters.len != 0 and !std.mem.eql(u8, letters, "a")) {
            const prev = s.key[0 .. s.key.len - letters.len] ++ previousLetters(letters);
            const p = (spellings.get(prev) orelse @compileError(n ++ ": key `" ++ s.key ++ "` skips `" ++ prev ++ "`")).one;
            if (@backingInt(p) > @backingInt(c)) @compileError(n ++ ": key `" ++ s.key ++ "` comes before `" ++ prev ++ "` (" ++ @tagName(p) ++ ")");
        }
    }
}

/// A key's clause part; all empty for a slug or a retired key.
const Parsed = struct { std: Spec.Standard = .none, clause: []const u8 = "", letters: []const u8 = "" };

/// Returns the documentation for `c` with one indexed load.
pub fn info(c: Code) Info {
    return table.get(c);
}

/// Returns `c`'s identity row with one indexed load.
pub fn spec(c: Code) Spec {
    return specs.get(c);
}

/// Returns what `spelling` names: a clause key or a `Code` name (`E0415`),
/// matched exactly and case-sensitively; null for anything else.
pub fn lookup(spelling: []const u8) ?Lookup {
    return spellings.get(spelling);
}

/// Returns true when `c`'s key starts with `prefix` on a clause boundary:
/// `AMS-5.6` matches `AMS-5.6.7.2b` and `AMS-5.6a`, not `AMS-5.60a`.
pub fn keyHasPrefix(c: Code, prefix: []const u8) bool {
    const key = spec(c).key;
    if (!std.mem.startsWith(u8, key, prefix)) return false;
    if (prefix.len == 0 or prefix.len == key.len) return true;
    return !(std.ascii.isDigit(prefix[prefix.len - 1]) and std.ascii.isDigit(key[prefix.len]));
}

// ---- private ----

/// Fails the build on a row the renderer would print wrong.
fn checkRow(comptime n: []const u8, comptime row: Info) void {
    if (n.len != 5 or (n[0] != 'E' and n[0] != 'W')) @compileError(n ++ ": a code is E or W and four digits");
    for (n[1..]) |ch| if (!std.ascii.isDigit(ch)) @compileError(n ++ ": a code is E or W and four digits");
    if (row.title.len == 0 or row.title[row.title.len - 1] == '.') @compileError(n ++ ": a title is non-empty with no trailing period");
    if (row.explain.len == 0) @compileError(n ++ ": no explain text");
    if (std.mem.eql(u8, row.title, "(retired)") and row.lrm.len != 0) @compileError(n ++ ": a retired code cites no clause");
}

/// Builds `n`'s `Spec` from its ZON row, or fails the build on a key off
/// its kind's grammar, a clause column the key contradicts, a malformed
/// tag or `also`, or a severity its letter or kind forbids.
fn specRow(comptime n: []const u8, comptime r: anytype) Spec {
    const T = @TypeOf(r);
    const s: Spec = .{
        .key = r.key,
        .also = if (@hasField(T, "also")) r.also else "",
        .clause = if (@hasField(T, "clause")) r.clause else "",
        .aliases = if (r.kind == .retired) &.{} else &.{n},
        .kind = r.kind,
        .std = if (@hasField(T, "std")) r.std else .none,
        .severity = if (@hasField(T, "severity")) r.severity else .err,
    };
    const p = parseKey(n, s.key, s.kind);
    if (p.std != .none and (p.std != s.std or !std.mem.eql(u8, p.clause, s.clause)))
        @compileError(n ++ ": key `" ++ s.key ++ "` disagrees with its std and clause columns");
    if ((s.std == .none) != (s.clause.len == 0)) @compileError(n ++ ": std and clause come together");
    if (s.also.len != 0) {
        const dash = std.mem.findScalar(u8, s.also, '-') orelse @compileError(n ++ ": `also` is <std>-<clause>");
        if (standardNamed(s.also[0..dash]) == null or !isNumbered(s.also[dash + 1 ..])) @compileError(n ++ ": `also` is <std>-<clause>");
    }
    const tag: []const u8 = r.tag;
    if (s.kind == .retired) {
        if (!std.mem.eql(u8, tag, n)) @compileError(n ++ ": a retired row's tag is its name");
    } else if (tag.len > 48 or !isWord(tag)) @compileError(n ++ ": a tag is snake_case, at most 48 bytes");
    if ((s.severity == .warning) != (n[0] == 'W')) @compileError(n ++ ": severity disagrees with the code's letter");
    const want: ?Severity = switch (s.kind) {
        .lint => .warning,
        .limit, .ice, .syntax => .err,
        .rule, .unsup, .retired => null,
    };
    if (want != null and want.? != s.severity) @compileError(n ++ ": a " ++ @tagName(s.kind) ++ " code is " ++ @tagName(want.?));
    return s;
}

/// Splits `key` as its kind's grammar reads it, or fails the build.
fn parseKey(comptime n: []const u8, comptime key: []const u8, comptime kind: Spec.Kind) Parsed {
    const prefix: []const u8 = switch (kind) {
        .rule, .syntax => "",
        .retired => {
            if (!std.mem.eql(u8, key, n)) @compileError(n ++ ": a retired row's key is its name");
            return .{};
        },
        else => @tagName(kind) ++ "-",
    };
    const bad = n ++ ": key `" ++ key ++ "` is not a " ++ @tagName(kind) ++ " key";
    if (!std.mem.startsWith(u8, key, prefix)) @compileError(bad);
    const body = key[prefix.len..];
    if (clauseKey(body)) |p| {
        if (kind == .limit or kind == .lint or kind == .ice) @compileError(bad);
        if ((kind == .syntax) != std.mem.eql(u8, p.clause, "A")) @compileError(bad);
        return p;
    }
    if (kind == .rule or kind == .syntax or !isSlug(body)) @compileError(bad);
    return .{};
}

/// Splits `std "-" clause sep letters`; null when `body` is not that shape.
fn clauseKey(body: []const u8) ?Parsed {
    const dash = std.mem.findScalar(u8, body, '-') orelse return null;
    const s = standardNamed(body[0..dash]) orelse return null;
    const rest = body[dash + 1 ..];
    var l = rest.len;
    while (l > 0 and std.ascii.isLower(rest[l - 1])) l -= 1;
    const letters = rest[l..];
    if (letters.len == 0 or letters.len > 2 or l == 0) return null;
    const sep = rest[l - 1] == '-';
    const clause = rest[0 .. l - @intFromBool(sep)];
    if (clause.len == 0) return null;
    if (isWord(clause)) {
        if (s != .vera or !sep) return null;
    } else if (!isNumbered(clause) or sep == std.ascii.isDigit(clause[clause.len - 1])) return null;
    return .{ .std = s, .clause = clause, .letters = letters };
}

fn standardNamed(s: []const u8) ?Spec.Standard {
    const spelt = [_][]const u8{ "AMS", "V2005", "VERA", "OSDI", "SPICE" };
    const value = [_]Spec.Standard{ .ams, .v2005, .vera, .osdi, .spice };
    for (spelt, value) |name, v| if (std.mem.eql(u8, s, name)) return v;
    return null;
}

/// `(digits | "A".."H") ("." digits)*`: a TOC or ledger number.
fn isNumbered(s: []const u8) bool {
    var it = std.mem.splitScalar(u8, s, '.');
    const head = it.first();
    const annex = head.len == 1 and head[0] >= 'A' and head[0] <= 'H';
    if (!annex and !isDigits(head)) return false;
    while (it.next()) |part| if (!isDigits(part)) return false;
    return true;
}

fn isDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

/// `[a-z][a-z0-9_]*`: a VERA clause word, and a tag.
fn isWord(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isLower(s[0])) return false;
    for (s) |ch| if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '_') return false;
    return true;
}

/// `[a-z0-9]+ ("-" [a-z0-9]+)*`.
fn isSlug(s: []const u8) bool {
    var it = std.mem.splitScalar(u8, s, '-');
    while (it.next()) |part| {
        if (part.len == 0) return false;
        for (part) |ch| if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch)) return false;
    }
    return true;
}

/// The letters before `letters` in the order a, ..., z, aa, ab, ...
fn previousLetters(comptime letters: []const u8) []const u8 {
    if (letters.len == 1) return &.{letters[0] - 1};
    if (letters[1] != 'a') return &.{ letters[0], letters[1] - 1 };
    return if (letters[0] == 'a') "z" else &.{ letters[0] - 1, 'z' };
}

test "a code's spelling is a letter and four digits, in catalogue order" {
    try std.testing.expectEqual(@as(u16, 0), @backingInt(Code.E0101));
    try std.testing.expectEqualStrings("E0101", @tagName(@as(Code, @fromBackingInt(0))));
    try std.testing.expect(names.len > 500);
}

test "clauseKey reads the §3.1 grammar and refuses its near misses" {
    const ok = [_][3][]const u8{
        .{ "AMS-5.6.7.2b", "5.6.7.2", "b" }, .{ "AMS-A-a", "A", "a" },
        .{ "AMS-A.1.3a", "A.1.3", "a" },     .{ "VERA-limit_seed-a", "limit_seed", "a" },
        .{ "V2005-19.4ab", "19.4", "ab" },
    };
    for (ok) |o| {
        const p = clauseKey(o[0]).?;
        try std.testing.expectEqualStrings(o[1], p.clause);
        try std.testing.expectEqualStrings(o[2], p.letters);
    }
    // A sep where the clause ends in a digit, none after a letter, a word
    // outside VERA, three letters, no letter, an unknown standard.
    for ([_][]const u8{ "AMS-5.6-b", "AMS-Aa", "AMS-limit_seed-a", "AMS-5.6abc", "AMS-5.6", "IEEE-5.6a", "AMS-5..6a" }) |k|
        try std.testing.expect(clauseKey(k) == null);
}

test "previousLetters steps back across the two-letter boundary" {
    try std.testing.expectEqualStrings("a", previousLetters("b"));
    try std.testing.expectEqualStrings("z", previousLetters("aa"));
    try std.testing.expectEqualStrings("aa", previousLetters("ab"));
    try std.testing.expectEqualStrings("az", previousLetters("ba"));
}
