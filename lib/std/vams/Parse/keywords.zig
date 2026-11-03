//! §10.6 reserved-keyword sets (IEEE 1364-2005 §19.11): a keyword's spelling
//! and the set in effect in, whether the set reserves it out. The tokenizer
//! always lexes the full annex B table; the parser asks `reservedUnder` where
//! the grammar wants an identifier, so a keyword an older set frees reads as
//! a name there (§10.6: "`input sin;` ... OK since sin is not a keyword in
//! 1364-2005").
//! Cites: VAMS-2023 §10.6, annex B, annex G Tables G.6-G.7; IEEE 1364-1995,
//! 1364-2001 and 1364-2005 reserved-word lists, §19.11.
//!
//! Contents:
//! - `pub const KeywordSet = enum(u8)`, `KeywordSet.fromSpecifier(text: []const u8) ?KeywordSet`, `KeywordSet.specifier(set: KeywordSet) []const u8`
//! - `pub fn reservedUnder(word: []const u8, set: KeywordSet) bool`

const std = @import("std");
const assert = std.debug.assert;
const Token = @import("../tokenizer.zig").Token;

/// A §10.6 version_specifier: the reserved-keyword set in effect. Five sets
/// form a chain, oldest first, so a word is reserved under `s` iff its
/// introduction set is no later than `s`; IEEE 1364-2005 §19.11's
/// "1364-2001-noconfig" is 1364-2001 less its ten configuration words.
pub const KeywordSet = enum(u8) {
    v1364_1995,
    v1364_2001,
    v1364_2001_noconfig,
    v1364_2005,
    vams_2_3,
    vams_2023,

    /// Parses a version_specifier's text (no quotes); null for any of the
    /// strings §10.6 and §19.11 do not name.
    pub fn fromSpecifier(text: []const u8) ?KeywordSet {
        const set = specifiers.get(text) orelse return null;
        assert(std.mem.eql(u8, set.specifier(), text));
        return set;
    }

    /// Returns the version_specifier text that selects `set`.
    pub fn specifier(set: KeywordSet) []const u8 {
        return switch (set) {
            .v1364_1995 => "1364-1995",
            .v1364_2001 => "1364-2001",
            .v1364_2001_noconfig => "1364-2001-noconfig",
            .v1364_2005 => "1364-2005",
            .vams_2_3 => "VAMS-2.3",
            .vams_2023 => "VAMS-2023",
        };
    }
};

const specifiers = std.StaticStringMap(KeywordSet).initComptime(.{
    .{ "1364-1995", KeywordSet.v1364_1995 },
    .{ "1364-2001", KeywordSet.v1364_2001 },
    .{ "1364-2001-noconfig", KeywordSet.v1364_2001_noconfig },
    .{ "1364-2005", KeywordSet.v1364_2005 },
    .{ "VAMS-2.3", KeywordSet.vams_2_3 },
    .{ "VAMS-2023", KeywordSet.vams_2023 },
});

/// IEEE 1364-1995's reserved words (102), the oldest §10.6 set.
const kw_1364_1995 = [_][]const u8{
    "always",    "and",         "assign",  "begin",       "buf",       "bufif0",       "bufif1",     "case",
    "casex",     "casez",       "cmos",    "deassign",    "default",   "defparam",     "disable",    "edge",
    "else",      "end",         "endcase", "endfunction", "endmodule", "endprimitive", "endspecify", "endtable",
    "endtask",   "event",       "for",     "force",       "forever",   "fork",         "function",   "highz0",
    "highz1",    "if",          "ifnone",  "initial",     "inout",     "input",        "integer",    "join",
    "large",     "macromodule", "medium",  "module",      "nand",      "negedge",      "nmos",       "nor",
    "not",       "notif0",      "notif1",  "or",          "output",    "parameter",    "pmos",       "posedge",
    "primitive", "pull0",       "pull1",   "pulldown",    "pullup",    "rcmos",        "real",       "realtime",
    "reg",       "release",     "repeat",  "rnmos",       "rpmos",     "rtran",        "rtranif0",   "rtranif1",
    "scalared",  "small",       "specify", "specparam",   "strong0",   "strong1",      "supply0",    "supply1",
    "table",     "task",        "time",    "tran",        "tranif0",   "tranif1",      "tri",        "tri0",
    "tri1",      "triand",      "trior",   "trireg",      "vectored",  "wait",         "wand",       "weak0",
    "weak1",     "while",       "wire",    "wor",         "xnor",      "xor",
};

/// Added by IEEE 1364-2001 (21).
const kw_1364_2001 = [_][]const u8{
    "automatic",          "cell",          "config",   "design",   "endconfig", "endgenerate", "generate",        "genvar",
    "incdir",             "include",       "instance", "liblist",  "library",   "localparam",  "noshowcancelled", "pulsestyle_ondetect",
    "pulsestyle_onevent", "showcancelled", "signed",   "unsigned", "use",
};

/// IEEE 1364-2005 §19.11's words "excluded from the reserved list" under
/// "1364-2001-noconfig".
const noconfig_words = std.StaticStringMap(void).initComptime(.{
    .{"cell"},    .{"config"},   .{"design"},  .{"endconfig"}, .{"incdir"},
    .{"include"}, .{"instance"}, .{"liblist"}, .{"library"},   .{"use"},
});

/// VAMS keywords after the "VAMS-2.3" specifier: annex G Table G.6 items
/// 4349, 4803 and Table G.7 items 830, 7780. Every other VAMS word dates
/// from "VAMS-2.3".
const kw_vams_2023 = [_][]const u8{ "absdelta", "break", "continue", "expm1", "ln1p", "noise_table_log", "return" };

const introduced = std.StaticStringMap(KeywordSet).initComptime(intro: {
    @setEvalBranchQuota(20_000);
    const KS = struct { []const u8, KeywordSet };
    var out: [kw_1364_1995.len + kw_1364_2001.len + 1 + kw_vams_2023.len]KS = undefined;
    var i: usize = 0;
    for (.{ kw_1364_1995, kw_1364_2001, [_][]const u8{"uwire"}, kw_vams_2023 }, [_]KeywordSet{ .v1364_1995, .v1364_2001, .v1364_2005, .vams_2023 }) |names, set| {
        for (names) |name| {
            out[i] = .{ name, set };
            i += 1;
        }
    }
    break :intro out;
});

/// Returns whether the keyword spelled `word` is reserved under `set`
/// (§10.6, IEEE 1364-2005 §19.11). Asserts that `word` is a keyword.
pub fn reservedUnder(word: []const u8, set: KeywordSet) bool {
    assert(Token.keywords.has(word));
    if (set == .v1364_2001_noconfig and noconfig_words.has(word)) return false;
    const reserved = @backingInt(introduced.get(word) orelse KeywordSet.vams_2_3) <= @backingInt(set);
    // Annex B is the union of every set: the newest reserves every keyword.
    if (set == .vams_2023) assert(reserved);
    return reserved;
}

// ---- private ----

test "§10.6 keyword sets nest; the intro table names only keywords" {
    for (introduced.keys()) |name| try std.testing.expect(Token.keywords.has(name));
    try std.testing.expectEqual(102, kw_1364_1995.len);
    try std.testing.expectEqual(21, kw_1364_2001.len);
    for (Token.keywords.keys()) |name| {
        var prev = false;
        for ([_]KeywordSet{ .v1364_1995, .v1364_2001, .v1364_2005, .vams_2_3, .vams_2023 }) |s| {
            const now = reservedUnder(name, s);
            try std.testing.expect(!prev or now);
            prev = now;
        }
    }
    try std.testing.expect(!reservedUnder("sin", .v1364_2005));
    try std.testing.expect(reservedUnder("sin", .vams_2_3));
    try std.testing.expect(!reservedUnder("config", .v1364_2001_noconfig));
    try std.testing.expect(!reservedUnder("ln1p", .vams_2_3));
    try std.testing.expect(!reservedUnder("wreal", .v1364_2005));
    try std.testing.expectEqual(KeywordSet.v1364_2005, KeywordSet.fromSpecifier("1364-2005").?);
    try std.testing.expectEqual(@as(?KeywordSet, null), KeywordSet.fromSpecifier("VAMS-2.4"));
    // §2.8.2: annex B Table B.1 carries neither.
    try std.testing.expectEqual(@as(?Token.Tag, null), Token.getKeyword("assert"));
    try std.testing.expectEqual(@as(?Token.Tag, null), Token.getKeyword("net_resolution"));
}
