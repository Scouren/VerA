//! Verilog-AMS lexing (Zig's `lib/std/zig/tokenizer.zig`): preprocessed text
//! in, one `Token{tag, loc}` per `Tokenizer.next` out, ending in `.eof`
//! repeatedly. `next` depends only on `(buffer, index)`, so a token's end is
//! recovered by re-lexing from its start (`Ast.tokenSlice`). Malformed text is
//! never an error here: it lexes to `.invalid` tokens the parser reports.
//! The tokenizer ignores the §10.6 keyword set (the directives "do not affect
//! the ... tokens"); the parser applies it (Parse/keywords.zig).
//! Cites: VAMS-2023 §2.2-§2.9, Table 2-1, §10.6, annex B Table B.1, annex G
//! Tables G.6-G.7; IEEE 1364-2005 §3.5.1, §19.11, A.6.5, A.7.
//!
//! Contents:
//! - `pub const Token = struct`, `Token.Loc`, `Token.Tag`, `Tag.lexeme(tag: Tag) ?[]const u8`, `Tag.isKeyword(tag: Tag) bool`, `Token.keywords`, `Token.getKeyword(bytes: []const u8) ?Tag`
//! - `pub const builtin_names`
//! - `pub const Tokenizer = struct`, `Tokenizer.init(buffer: [:0]const u8) Tokenizer`, `Tokenizer.next(self: *Tokenizer) Token`
//! - `pub fn isIdentChar(c: u8) bool`
//! - `pub fn isSpace(c: u8) bool`

const std = @import("std");
const assert = std.debug.assert;

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    /// Every annex B keyword spelling and its tag. The A.8.2 call names
    /// (`builtin_names`) share `.keyword_builtin`; every other keyword is
    /// `.keyword_` ++ its spelling.
    pub const keywords = std.StaticStringMap(Tag).initComptime(keyword_kvs);

    /// Returns the keyword tag spelled `bytes`, or null (§2.8.2:
    /// case-sensitive, whole word).
    pub fn getKeyword(bytes: []const u8) ?Tag {
        return keywords.get(bytes);
    }

    /// Ordered `invalid, eof, names and literals, operators, punctuation,
    /// directives, keywords`, keywords contiguous and last (`isKeyword` is one
    /// compare).
    pub const Tag = enum(u8) {
        invalid,
        eof,
        /// §2.8 simple identifier.
        identifier,
        /// §2.8.1 `\name `: the span includes the backslash, not the terminator.
        escaped_identifier,
        /// §2.8.3 `$name`.
        system_identifier,
        /// §2.6.1 integer (sized and based too) or §2.6.2 real; decoded by
        /// `number_literal.zig`.
        number_literal,
        /// §2.7, one line.
        string_literal,

        plus,
        minus,
        asterisk,
        slash,
        percent,
        asterisk_asterisk,
        /// `<+` §5.6 contribution.
        angle_bracket_left_plus,
        /// `->` §5.10.4 event trigger.
        minus_angle_bracket_right,
        equal,
        angle_bracket_left,
        angle_bracket_right,
        angle_bracket_left_equal,
        angle_bracket_right_equal,
        equal_equal,
        bang_equal,
        equal_equal_equal,
        bang_equal_equal,
        bang,
        ampersand_ampersand,
        pipe_pipe,
        tilde,
        ampersand,
        pipe,
        caret,
        tilde_caret,
        caret_tilde,
        tilde_ampersand,
        tilde_pipe,
        angle_bracket_angle_bracket_left,
        angle_bracket_angle_bracket_right,
        angle_bracket_angle_bracket_angle_bracket_left,
        angle_bracket_angle_bracket_angle_bracket_right,
        question_mark,
        colon,

        l_paren,
        r_paren,
        l_bracket,
        r_bracket,
        l_brace,
        r_brace,
        semicolon,
        comma,
        period,
        at_sign,
        hash,
        /// `'{` §4.2.14 assignment pattern.
        apostrophe_l_brace,
        /// `(*` §2.9 attribute open.
        l_paren_asterisk,
        /// `*)` §2.9 attribute close.
        asterisk_r_paren,
        /// `=>` A.7.2 parallel path.
        equal_angle_bracket_right,
        /// `*>` A.7.2 full path.
        asterisk_angle_bracket_right,
        /// `&&&` A.7.5.3 timing check condition.
        ampersand_ampersand_ampersand,

        // The directives the preprocessor passes through, because only the
        // parser can check where they stand (§10.6, IEEE 1364 §19).
        directive_begin_keywords,
        directive_end_keywords,
        directive_resetall,
        directive_default_nettype,
        directive_unconnected_drive,
        directive_nounconnected_drive,
        directive_default_transition,

        // ---- keywords: everything from here to the end ----
        /// Every A.8.2 analog built-in, filter, small-signal and A.6.5 event
        /// function name (`builtin_names`): the parser reads each as a call.
        /// The spelling is the source's.
        keyword_builtin,
        keyword_module,
        keyword_macromodule,
        keyword_connectmodule,
        keyword_endmodule,
        keyword_paramset,
        keyword_endparamset,
        keyword_function,
        keyword_endfunction,
        keyword_task,
        keyword_endtask,
        keyword_analog,
        keyword_initial,
        keyword_always,
        keyword_assign,
        keyword_deassign,
        keyword_force,
        keyword_release,
        keyword_begin,
        keyword_end,
        keyword_fork,
        keyword_join,
        keyword_wait,
        keyword_generate,
        keyword_endgenerate,
        keyword_defparam,
        keyword_connectrules,
        keyword_endconnectrules,
        keyword_connect,
        keyword_resolveto,
        keyword_merged,
        keyword_split,
        keyword_parameter,
        keyword_localparam,
        keyword_aliasparam,
        keyword_specparam,
        keyword_integer,
        keyword_real,
        keyword_string,
        keyword_realtime,
        keyword_time,
        keyword_reg,
        keyword_event,
        keyword_genvar,
        keyword_branch,
        keyword_input,
        keyword_output,
        keyword_inout,
        keyword_wire,
        keyword_wreal,
        keyword_tri,
        keyword_tri0,
        keyword_tri1,
        keyword_triand,
        keyword_trior,
        keyword_trireg,
        keyword_wand,
        keyword_wor,
        keyword_uwire,
        keyword_supply0,
        keyword_supply1,
        keyword_signed,
        keyword_unsigned,
        keyword_scalared,
        keyword_vectored,
        keyword_automatic,
        keyword_and,
        keyword_nand,
        keyword_or,
        keyword_nor,
        keyword_xor,
        keyword_xnor,
        keyword_buf,
        keyword_not,
        keyword_bufif0,
        keyword_bufif1,
        keyword_notif0,
        keyword_notif1,
        keyword_tran,
        keyword_rtran,
        keyword_tranif0,
        keyword_tranif1,
        keyword_rtranif0,
        keyword_rtranif1,
        keyword_cmos,
        keyword_rcmos,
        keyword_nmos,
        keyword_pmos,
        keyword_rnmos,
        keyword_rpmos,
        keyword_pullup,
        keyword_pulldown,
        keyword_strong0,
        keyword_strong1,
        keyword_pull0,
        keyword_pull1,
        keyword_weak0,
        keyword_weak1,
        keyword_highz0,
        keyword_highz1,
        keyword_small,
        keyword_medium,
        keyword_large,
        keyword_primitive,
        keyword_endprimitive,
        keyword_table,
        keyword_endtable,
        keyword_specify,
        keyword_endspecify,
        keyword_ifnone,
        keyword_edge,
        keyword_pulsestyle_onevent,
        keyword_pulsestyle_ondetect,
        keyword_showcancelled,
        keyword_noshowcancelled,
        keyword_config,
        keyword_endconfig,
        keyword_design,
        keyword_instance,
        keyword_cell,
        keyword_liblist,
        keyword_use,
        keyword_library,
        keyword_include,
        keyword_incdir,
        keyword_discipline,
        keyword_enddiscipline,
        keyword_nature,
        keyword_endnature,
        keyword_domain,
        keyword_continuous,
        keyword_discrete,
        keyword_potential,
        keyword_flow,
        keyword_abstol,
        keyword_access,
        keyword_units,
        keyword_ddt_nature,
        keyword_idt_nature,
        keyword_ground,
        keyword_from,
        keyword_exclude,
        keyword_inf,
        keyword_if,
        keyword_else,
        keyword_case,
        keyword_casex,
        keyword_casez,
        keyword_endcase,
        keyword_default,
        keyword_for,
        keyword_while,
        keyword_repeat,
        keyword_forever,
        keyword_return,
        keyword_break,
        keyword_continue,
        keyword_disable,
        keyword_initial_step,
        keyword_final_step,
        keyword_driver_update,
        keyword_posedge,
        keyword_negedge,
        keyword_analysis,

        /// Returns the fixed spelling, or null when the source holds it
        /// (names, literals, `.invalid`, `.eof`, `.keyword_builtin`).
        pub fn lexeme(tag: Tag) ?[]const u8 {
            return switch (tag) {
                .invalid, .eof, .identifier, .escaped_identifier, .system_identifier, .number_literal, .string_literal, .keyword_builtin => null,
                inline else => |t| comptime spelling(t),
            };
        }

        /// Returns whether `tag` is an annex B keyword.
        pub fn isKeyword(tag: Tag) bool {
            return @backingInt(tag) >= @backingInt(Tag.keyword_builtin);
        }
    };
};

/// The A.8.2 `analog_built_in_function_name`s (26), filter (17) and
/// small-signal (5) function names and the A.6.5 analog event functions (4),
/// all `.keyword_builtin`.
pub const builtin_names = [_][]const u8{
    "abs",   "max",           "min",    "pow",        "sqrt",        "exp",           "ln",          "log",
    "expm1", "ln1p",          "hypot",  "floor",      "ceil",        "sin",           "cos",         "tan",
    "asin",  "acos",          "atan",   "atan2",      "sinh",        "cosh",          "tanh",        "asinh",
    "acosh", "atanh",         "ddt",    "ddx",        "idt",         "idtmod",        "absdelay",    "transition",
    "slew",  "last_crossing", "limexp", "laplace_zd", "laplace_zp",  "laplace_nd",    "laplace_np",  "zi_zd",
    "zi_zp", "zi_nd",         "zi_np",  "ac_stim",    "white_noise", "flicker_noise", "noise_table", "noise_table_log",
    "cross", "above",         "timer",  "absdelta",
};

/// A cursor over preprocessed text. `index` is the only state, so a scan
/// from any token start reproduces that token.
pub const Tokenizer = struct {
    buffer: [:0]const u8,
    index: usize,

    /// Returns a tokenizer at the start of `buffer`.
    pub fn init(buffer: [:0]const u8) Tokenizer {
        return .{ .buffer = buffer, .index = 0 };
    }

    /// Scans the token at `index` and advances past it. Returns `.eof` at the
    /// end, repeatedly; every other token advances by at least one byte.
    pub fn next(self: *Tokenizer) Token {
        assert(self.index <= self.buffer.len);
        // The preprocessor strips every §2.4 comment, so `//` here is two
        // slashes, as IEEE 1364 §19.3.1 makes of macro text pasted into one.
        while (isSpace(self.buffer[self.index])) self.index += 1;
        const start = self.index;
        if (start == self.buffer.len) return .{ .tag = .eof, .loc = .{ .start = start, .end = start } };
        const tag: Token.Tag = switch (self.buffer[start]) {
            '0'...'9' => self.number(),
            'a'...'z', 'A'...'Z', '_' => tag: {
                self.index = identEnd(self.buffer, start);
                break :tag Token.getKeyword(self.buffer[start..self.index]) orelse .identifier;
            },
            '\\' => tag: { // §2.8.1: printable ASCII 33..126, ended by white space
                self.index += 1;
                while (self.buffer[self.index] >= 33 and self.buffer[self.index] <= 126) self.index += 1;
                break :tag if (self.index == start + 1) .invalid else .escaped_identifier;
            },
            '$' => tag: { // §2.8.3
                self.index = identEnd(self.buffer, start + 1);
                break :tag if (self.index == start + 1) .invalid else .system_identifier;
            },
            '"' => self.string(),
            '\'' => tag: {
                if (self.buffer[start + 1] == '{') {
                    self.index += 2;
                    break :tag .apostrophe_l_brace;
                }
                if (self.basedTail()) |t| break :tag t;
                self.index += 1;
                break :tag .invalid;
            },
            '`' => self.directive(),
            else => self.operator(),
        };
        assert(self.index > start);
        assert(self.index <= self.buffer.len);
        return .{ .tag = tag, .loc = .{ .start = start, .end = self.index } };
    }

    // ---- private ----

    /// §2.6.1 integer and §2.6.2 real constants; cursor on a decimal digit.
    fn number(self: *Tokenizer) Token.Tag {
        const start = self.index;
        assert(std.ascii.isDigit(self.buffer[start]));
        self.unsignedNumber();
        // §2.6.1: "it shall be legal to macro substitute these three tokens",
        // so white space may sit between a size and its `'`; not after a `#`,
        // where A.6.5's delay_value is never a size.
        var i = self.index;
        while (isSpace(self.buffer[i])) i += 1;
        if (self.buffer[i] == '\'' and (i == self.index or !afterHash(self.buffer, start))) {
            const save = self.index;
            self.index = i;
            if (self.basedTail()) |tag| return tag;
            self.index = save;
        }
        // §2.6.2: a decimal point needs a digit on each side.
        if (self.buffer[self.index] == '.' and std.ascii.isDigit(self.buffer[self.index + 1])) {
            self.index += 1;
            self.unsignedNumber();
        }
        const e = self.buffer[self.index];
        if (e == 'e' or e == 'E') {
            const sign: usize = @intFromBool(self.buffer[self.index + 1] == '+' or self.buffer[self.index + 1] == '-');
            if (std.ascii.isDigit(self.buffer[self.index + 1 + sign])) {
                self.index += 1 + sign;
                self.unsignedNumber();
            }
        } else if (isScaleFactor(e) and !isIdentChar(self.buffer[self.index + 1])) {
            // Table 2-1, only when it does not head an identifier.
            self.index += 1;
        }
        assert(self.index > start);
        return .number_literal;
    }

    /// §2.6.1 `' [s|S] base [space] digits`, cursor on the `'`. Null, cursor
    /// untouched, when no base letter follows. A base with no digits ends the
    /// token at the base letter as `.invalid`.
    fn basedTail(self: *Tokenizer) ?Token.Tag {
        assert(self.buffer[self.index] == '\'');
        var i = self.index + 1;
        if (self.buffer[i] == 's' or self.buffer[i] == 'S') i += 1;
        const radix: u8 = switch (std.ascii.toLower(self.buffer[i])) {
            'b' => 2,
            'o' => 8,
            'd' => 10,
            'h' => 16,
            else => return null,
        };
        i += 1;
        const after_base = i;
        while (isSpace(self.buffer[i])) i += 1;
        const digits = i;
        while (isBasedDigit(self.buffer[i], radix)) i += 1;
        if (i == digits) {
            self.index = after_base;
            return .invalid;
        }
        self.index = i;
        return .number_literal;
    }

    fn unsignedNumber(self: *Tokenizer) void {
        const start = self.index;
        while (std.ascii.isDigit(self.buffer[self.index]) or self.buffer[self.index] == '_') self.index += 1;
        assert(self.index >= start);
    }

    /// §2.7: one line, `\` escapes. Unterminated: `.invalid` to the newline.
    fn string(self: *Tokenizer) Token.Tag {
        assert(self.buffer[self.index] == '"');
        self.index += 1;
        while (self.index < self.buffer.len) {
            const c = self.buffer[self.index];
            if (c == '\n') break;
            self.index += 1;
            if (c == '\\') {
                if (self.index < self.buffer.len and self.buffer[self.index] != '\n') self.index += 1;
                continue;
            }
            if (c == '"') return .string_literal;
        }
        assert(self.index == self.buffer.len or self.buffer[self.index] == '\n');
        return .invalid;
    }

    /// The passed-through directives; any other backtick is one `.invalid` byte.
    fn directive(self: *Tokenizer) Token.Tag {
        const name = self.index + 1;
        const end = identEnd(self.buffer, name);
        const tag = directives.get(self.buffer[name..end]) orelse {
            self.index = name;
            return .invalid;
        };
        self.index = end;
        return tag;
    }

    /// §2.5 operators by longest match (three bytes at most), §2.9's
    /// attribute delimiters and A.7's `=>`, `*>` and `&&&`: every `symbols`
    /// spelling. Any other byte is one `.invalid`.
    fn operator(self: *Tokenizer) Token.Tag {
        const start = self.index;
        var n: usize = 3;
        while (n > 0) : (n -= 1) {
            if (start + n > self.buffer.len) continue;
            const tag = operators.get(self.buffer[start..][0..n]) orelse continue;
            self.index += n;
            return tag;
        }
        self.index += 1;
        return .invalid;
    }
};

/// The fixed spelling of every tag that is not a keyword, by tag name.
const symbols = .{
    .{ "plus", "+" },                                             .{ "minus", "-" },                                             .{ "asterisk", "*" },
    .{ "slash", "/" },                                            .{ "percent", "%" },                                           .{ "asterisk_asterisk", "**" },
    .{ "angle_bracket_left_plus", "<+" },                         .{ "minus_angle_bracket_right", "->" },                        .{ "equal", "=" },
    .{ "angle_bracket_left", "<" },                               .{ "angle_bracket_right", ">" },                               .{ "angle_bracket_left_equal", "<=" },
    .{ "angle_bracket_right_equal", ">=" },                       .{ "equal_equal", "==" },                                      .{ "bang_equal", "!=" },
    .{ "equal_equal_equal", "===" },                              .{ "bang_equal_equal", "!==" },                                .{ "bang", "!" },
    .{ "ampersand_ampersand", "&&" },                             .{ "pipe_pipe", "||" },                                        .{ "tilde", "~" },
    .{ "ampersand", "&" },                                        .{ "pipe", "|" },                                              .{ "caret", "^" },
    .{ "tilde_caret", "~^" },                                     .{ "caret_tilde", "^~" },                                      .{ "tilde_ampersand", "~&" },
    .{ "tilde_pipe", "~|" },                                      .{ "angle_bracket_angle_bracket_left", "<<" },                 .{ "angle_bracket_angle_bracket_right", ">>" },
    .{ "angle_bracket_angle_bracket_angle_bracket_left", "<<<" }, .{ "angle_bracket_angle_bracket_angle_bracket_right", ">>>" }, .{ "question_mark", "?" },
    .{ "colon", ":" },                                            .{ "l_paren", "(" },                                           .{ "r_paren", ")" },
    .{ "l_bracket", "[" },                                        .{ "r_bracket", "]" },                                         .{ "l_brace", "{" },
    .{ "r_brace", "}" },                                          .{ "semicolon", ";" },                                         .{ "comma", "," },
    .{ "period", "." },                                           .{ "at_sign", "@" },                                           .{ "hash", "#" },
    .{ "apostrophe_l_brace", "'{" },                              .{ "l_paren_asterisk", "(*" },                                 .{ "asterisk_r_paren", "*)" },
    .{ "equal_angle_bracket_right", "=>" },                       .{ "asterisk_angle_bracket_right", "*>" },                     .{ "ampersand_ampersand_ampersand", "&&&" },
    .{ "directive_begin_keywords", "`begin_keywords" },           .{ "directive_end_keywords", "`end_keywords" },                .{ "directive_resetall", "`resetall" },
    .{ "directive_default_nettype", "`default_nettype" },         .{ "directive_unconnected_drive", "`unconnected_drive" },      .{ "directive_nounconnected_drive", "`nounconnected_drive" },
    .{ "directive_default_transition", "`default_transition" },
};

/// `symbols` by spelling, for `Tokenizer.operator`'s longest match.
const operators = std.StaticStringMap(Token.Tag).initComptime(ops: {
    var out: [symbols.len]struct { []const u8, Token.Tag } = undefined;
    for (symbols, &out) |row, *o| o.* = .{ row[1], @field(Token.Tag, row[0]) };
    break :ops out;
});

const directives = std.StaticStringMap(Token.Tag).initComptime(.{
    .{ "begin_keywords", .directive_begin_keywords },
    .{ "end_keywords", .directive_end_keywords },
    .{ "resetall", .directive_resetall },
    .{ "default_nettype", .directive_default_nettype },
    .{ "unconnected_drive", .directive_unconnected_drive },
    .{ "nounconnected_drive", .directive_nounconnected_drive },
    .{ "default_transition", .directive_default_transition },
});

const KV = struct { []const u8, Token.Tag };

const keyword_kvs = kvs: {
    @setEvalBranchQuota(40_000);
    const fields = @typeInfo(Token.Tag).@"enum".field_names[@backingInt(Token.Tag.keyword_builtin) + 1 ..];
    var out: [fields.len + builtin_names.len]KV = undefined;
    for (fields, 0..) |f, i| out[i] = .{ f["keyword_".len..], @field(Token.Tag, f) };
    for (builtin_names, fields.len..) |name, i| {
        if (@hasField(Token.Tag, "keyword_" ++ name)) @compileError("keyword spelled twice: " ++ name);
        out[i] = .{ name, .keyword_builtin };
    }
    break :kvs out;
};

/// §2.8: letters, digits, `$` and `_`.
pub fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

/// §2.3 white space, plus carriage return so CRLF reads as LF. Vertical tab
/// is not white space and lexes `.invalid`.
pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

// ---- private ----

/// `Tag.lexeme`'s answer for a tag with a fixed spelling: `symbols`' row,
/// or a keyword's own name less `keyword_`.
fn spelling(comptime t: Token.Tag) []const u8 {
    @setEvalBranchQuota(10_000);
    if (t.isKeyword()) return @tagName(t)["keyword_".len..];
    for (symbols) |row| if (std.mem.eql(u8, row[0], @tagName(t))) return row[1];
    @compileError("give ." ++ @tagName(t) ++ " a row in `symbols`");
}

/// Table 2-1 scale factors.
fn isScaleFactor(c: u8) bool {
    return std.mem.findScalar(u8, "TGMKkmunpfa", c) != null;
}

/// The first index at or after `i` whose byte is not an identifier byte.
/// The sentinel ends the scan.
fn identEnd(s: [:0]const u8, i: usize) usize {
    assert(i <= s.len);
    var k = i;
    while (isIdentChar(s[k])) k += 1;
    assert(k <= s.len);
    return k;
}

/// §2.6.1's digits of `radix`, `_`, and the four-state digits x, z, `?`.
fn isBasedDigit(c: u8, radix: u8) bool {
    assert(radix == 2 or radix == 8 or radix == 10 or radix == 16);
    return switch (c) {
        '_', 'x', 'X', 'z', 'Z', '?' => true,
        '0'...'9' => c - '0' < radix,
        'a'...'f', 'A'...'F' => radix == 16,
        else => false,
    };
}

/// Whether the last non-space byte before `at` is a `#`.
fn afterHash(s: []const u8, at: usize) bool {
    assert(at <= s.len);
    var k = at;
    while (k > 0 and isSpace(s[k - 1])) k -= 1;
    return k > 0 and s[k - 1] == '#';
}

fn expectTags(src: [:0]const u8, expected: []const Token.Tag) !void {
    var t: Tokenizer = .init(src);
    for (expected) |want| try std.testing.expectEqual(want, t.next().tag);
    try std.testing.expectEqual(Token.Tag.eof, t.next().tag);
}

test "operators are longest-match (§2.5); A.7's path and condition symbols are tokens" {
    try expectTags("< <= <+ << <<< > >= >> >>> = == === ! != !== ** * ~^ ^~ ~& ~| && || (* *) '{", &.{
        .angle_bracket_left,               .angle_bracket_left_equal,                       .angle_bracket_left_plus,
        .angle_bracket_angle_bracket_left, .angle_bracket_angle_bracket_angle_bracket_left, .angle_bracket_right,
        .angle_bracket_right_equal,        .angle_bracket_angle_bracket_right,              .angle_bracket_angle_bracket_angle_bracket_right,
        .equal,                            .equal_equal,                                    .equal_equal_equal,
        .bang,                             .bang_equal,                                     .bang_equal_equal,
        .asterisk_asterisk,                .asterisk,                                       .tilde_caret,
        .caret_tilde,                      .tilde_ampersand,                                .tilde_pipe,
        .ampersand_ampersand,              .pipe_pipe,                                      .l_paren_asterisk,
        .asterisk_r_paren,                 .apostrophe_l_brace,
    });
    try expectTags("-> - => *> &&&", &.{ .minus_angle_bracket_right, .minus, .equal_angle_bracket_right, .asterisk_angle_bracket_right, .ampersand_ampersand_ampersand });
}

test "numbers: bases, reals, scale factors, and the §2.6.1 three-token join" {
    try expectTags("27_195 16'b0011_0101 'h837ff 4'b01xz 2394.26331 1.30e-2 1.3u 7k 236.123_763_e-12", &.{ .number_literal, .number_literal, .number_literal, .number_literal, .number_literal, .number_literal, .number_literal, .number_literal, .number_literal });
    try expectTags(".12", &.{ .period, .number_literal });
    try expectTags("9.", &.{ .number_literal, .period });
    try expectTags("4af", &.{ .number_literal, .identifier });
    try expectTags("8'd -6", &.{ .invalid, .minus, .number_literal });
    try expectTags("2'{1}", &.{ .number_literal, .apostrophe_l_brace, .number_literal, .r_brace });
    try expectTags("8 'h A5", &.{.number_literal});
    try expectTags("#1 'h123", &.{ .hash, .number_literal, .number_literal });
    try expectTags("1e3k 1e+ 1m$x", &.{ .number_literal, .identifier, .number_literal, .identifier, .plus, .number_literal, .identifier });
    try expectTags("8' 3 'x", &.{ .number_literal, .invalid, .number_literal, .invalid, .identifier });
}

test "names, keywords, strings and directives (§2.7, §2.8, §10.6)" {
    try expectTags("module _b n$6 $temperature \\gain+trim  sin primitive", &.{ .keyword_module, .identifier, .identifier, .system_identifier, .escaped_identifier, .keyword_builtin, .keyword_primitive });
    try expectTags("\\module $ x \\ y", &.{ .escaped_identifier, .invalid, .identifier, .invalid, .identifier });
    try expectTags("\"a\\\"b\" \"open\nx", &.{ .string_literal, .invalid, .identifier });
    try expectTags("`begin_keywords \"1364-2005\" `end_keywords `default_nettype `celldefine", &.{ .directive_begin_keywords, .string_literal, .directive_end_keywords, .directive_default_nettype, .invalid, .identifier });
    try expectTags("a\x0bb\x00c", &.{ .identifier, .invalid, .identifier, .invalid, .identifier });
}

test "every fixed spelling lexes back to its own tag, whole" {
    for (std.enums.values(Token.Tag)) |t| {
        const l = t.lexeme() orelse continue;
        var buf: [32:0]u8 = @splat(0);
        @memcpy(buf[0..l.len], l);
        var tz: Tokenizer = .init(buf[0..l.len :0]);
        const tok = tz.next();
        try std.testing.expectEqual(t, tok.tag);
        try std.testing.expectEqual(l.len, tok.loc.end);
    }
}

test "tokens tile the text: only white space between them" {
    const alphabet = "aZ_$09 \t\n\r\x0c\\\"'`.+-*/<>=!&|~^(){}[];:,?@#ehxsk\x0b\x80\xff";
    var prng: std.Random.DefaultPrng = .init(0x7e57);
    const rand = prng.random();
    var buf: [97]u8 = undefined;
    for (0..4000) |_| {
        const n = rand.uintAtMost(usize, 96);
        for (buf[0..n]) |*b| b.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        buf[n] = 0;
        const src = buf[0..n :0];
        var tz: Tokenizer = .init(src);
        var prev_end: usize = 0;
        for (0..n + 1) |_| {
            const tok = tz.next();
            for (src[prev_end..tok.loc.start]) |c| try std.testing.expect(isSpace(c));
            var again: Tokenizer = .{ .buffer = src, .index = tok.loc.start };
            try std.testing.expectEqual(tok, again.next());
            prev_end = tok.loc.end;
            if (tok.tag == .eof) break;
        }
        try std.testing.expectEqual(n, prev_end);
    }
}
