# Research: a `\`-newline inside a string literal (E0138 on every BSIM3/BSIM4)

Planner: r-strings (Fable). Base: `refactor` at 60e0f836. Read-only research: no build run; every
"today" claim is read from the source cited beside it. LRM text is from `pdftotext -layout` of
`docs/specification/VAMS-LRM-2023.pdf` and `1364-2005.pdf`, cited by clause and printed page.
This revisits `docs/specification/Vague_Decisions.md` VD-021 (`:65`, `:388-397`, `DECIDED (a)`),
which the lead asked to reopen; its reasoning is quoted where it still holds.

## 0. The question and the state found

The construct, byte for byte (`tests/conformance/external/OpenVAF-Reloaded/integration_tests/BSIM4/bsim4.va:6374`,
the same text in `VA-Models/code/bsim4/vacode/bsim4.va:3608` and
`OpenVAF-Reloaded/external/vacask/devices/bsim4v8.va:6373`):

```
                    $strobe("Temperature effect has caused cjs to be negative. \
                             Cjs is clamped to zero.\n");
```

A `\` immediately before LF (no CR, no trailing blanks, in all 106 sites, checked) inside a `$strobe`
string. VerA, old and new side, lexes the string as `.invalid` at the newline and reports
`E0138: a string literal may not span lines`.

VerA today gives this one construct three different answers:

| position | old side | new side | result |
|---|---|---|---|
| a statement (BSIM3, BSIM4) | `lib/frontend/lexer.zig:284` stops at the newline; `parser.zig:777` E0138 | `lib/std/vams/tokenizer.zig:461`; `Ast/errors.zig:75` E0138 | **refused** |
| inside a `` `define `` body (BSIM6, BSIMBULK) | `pp/macro.zig:317` `joinContinuations` collapses `\`+LF+indent to one space, strings included; `:610` `splitsString` then sees a closed string | `Preprocessor/macro.zig:226`, `:494` | **accepted silently as one space** |
| inside an inactive `` `ifdef `` arm | `pp/scan.zig:164` `stringStop` crosses `\`+LF as an escape pair, so the string is "closed" and `:94`'s E0138 does not fire | `Preprocessor/scan.zig:255`, `:94` | **accepted verbatim** (`tests/unit/preprocessor_tests.zig:1615`, `Preprocessor/tests.zig:750`) |

So VD-021's rule ("a raw newline or a `\`-newline continuation inside a string is an error") is
implemented only in the lexer; the preprocessor never enforced it, and the four BSIMBULK rows and
`va-models/bsim6.0.va` are `compile` in the manifests today because of the macro join, not because
of the rule.

## 1. The LRM text

### VAMS-LRM-2023

- §1.1 (p. 1): "Verilog-AMS HDL is derived from IEEE Std 1364-2005 Verilog HDL".
- §2.3 (p. 11): "White space shall contain the characters for spaces, tabs, newlines, and formfeeds.
  These characters shall be ignored except when they serve to separate other lexical tokens.
  However, spaces and tabs shall be considered significant characters in strings (see 2.7)."
- §2.7 (p. 16): "A string literal is a sequence of characters enclosed by double quotes (") and
  contained on a single line." "Certain characters can only be used in a string literal when
  preceded by an introductory character called an escape character. Table 2-2 lists these
  characters". Table 2-2 (p. 16) has exactly five rows: `\n`, `\t`, `\\`, `\"`, `\ddd`. There is
  no `\`-newline row.
- §3.3 (p. 25): "Verilog-AMS includes the string data type from IEEE Std 1800 SystemVerilog";
  "IEEE Std 1364 Verilog supports string literals, but only at the lexical level. [...] In
  Verilog-AMS, string literals behave exactly the same as in Verilog."
- §10.4 (p. 270): "The `define and `undef compiler directives are described in IEEE Std 1364
  Verilog." (Syntax 10-3 gives the form only; the continuation rule is inherited.)
- A.8.8 (p. 383): `string_literal ::= " { Any_ASCII_Characters } "`. `Any_ASCII_Characters` is
  never defined in Annex A (A.9.4 defines `Any_ASCII_character` for comments and escaped
  identifiers).
- Annex G (informative), Table G.5 "Changes from v2.3 to v2.3.1" (p. 419): "2535 Corrected
  definition for multiline strings A.8.8". It does not say what the correction allows.
- Silent on: a backslash before a newline anywhere but macro text; any form of line
  continuation in a string; IEEE 1800 §5.9. The LRM names its 1800 imports one by one (the
  string type §3.3, assignment patterns §4.2.14, the `$root` prefix) and string literal syntax is not
  among them.

### IEEE 1364-2005

- §3.6 (p. 12): "A string is a sequence of characters enclosed by double quotes ("") and
  contained on a single line."
- A.8.8 (p. 507): `string ::= " { Any_ASCII_Characters_except_new_line } "`.
- §19.3.1 (p. 350): "The macro text can be any arbitrary text specified on the same line as the
  text macro name. If more than one line is necessary to specify the text, the newline shall be
  preceded by a backslash (\). The first newline not preceded by a backslash shall end the macro
  text. The newline preceded by a backslash shall be replaced in the expanded macro with a
  newline (but without the preceding backslash character)."
- §19.3.1 (p. 351-352): "The text specified for macro text shall not be split across the
  following lexical tokens: — Comments — Numbers — Strings — Identifiers — Keywords — Operators",
  then "The following is illegal syntax because it is split across a string:
  `` `define first_half "start of string `` / `` $display(`first_half end of string"); ``".
  Read with the sentence above it, a `\`-newline inside a string in macro text expands to a raw
  newline inside the string, which §3.6 forbids: under 1364 the macro form is illegal too, and
  VerA's one-space join (§0) hides it.
- §19.4 (p. 354): "Any group of lines that the compiler ignores shall still follow the Verilog
  HDL lexical conventions for white space, comments, numbers, strings, identifiers, keywords, and
  operators."

### IEEE 1800: what this repo holds

No 1800 PDF is in `docs/specification`. Three external tests reproduce §5.9 and fix its meaning
without quoting it:

- `tests/conformance/external/ispras-sv-tests/ieee-1800-2012/05/05.09_01.sv` (`! TYPE: POSITIVE`,
  the standard's own example): `$display("Humpty Dumpty sat on a wall. \` / `Humpty Dumpty had a
  great fall.");` and the two-line variant `"...wall.\n\` / `Humpty...`. The pair only makes
  sense if `\`+LF contributes nothing and `\n` is the one way to get a newline.
- `iverilog/ivtest/ivltests/string12.v`: `if ("this matches" == "this\` / ` matches")
  $display("PASSED");` in Icarus's `regress-vlg.list`. So `\`+LF is removed and the next line's
  leading blank is kept: the exact bytes.
- `sv-tests/tests/chapter-5/5.9-string-broken-line.sv` (`:tags: 5.9`): `$display("broken \` /
  `              line");`.

The repo's own notes agree: `lib/frontend/lexer.zig:642` ("IEEE 1800 §5.9 continuation, as in
bsim4va's $strobe") and the E0138 note text at `parser.zig:786-792` / `Ast/errors.zig:77`.

## 2. Every place the repo pins the behaviour

### Suite fixtures (`tests/conformance/tests`, the user's repo)

| fixture | header | input | stays? |
|---|---|---|---|
| `verilog-a/ch02_lexical/string_line_continuation_rejected.va` | `//! reject-only E0138`, `//! lrm 2.7`, `//! lrm 2.7:1001`, `//! neighbour string_escapes.va`; comment: "Verbatim from bsim4va.va:3658 -- a vendor extension, not a lexer gap, so the rejection is the correct answer and is pinned here" | the BSIM4 `$strobe` | **flips** (§5) |
| `verilog-a/ch02_lexical/multiline_string_rejected.va` | `reject-only E0138`, `lrm 2.7`, `2.7:1001` | `string value = "first` / `second";` (raw newline) | stays |
| `verilog-a/annex_a_syntax/reject_A_8_8_string_spans_lines.va` | `lrm A.8`, `A.8.8`, `2.7`, `A.8.8:1000`, `reject-only E0138` | `code = "A` / `B";` (raw newline) | stays |
| `verilog-a/ch09_system_tasks/display_newline_only_by_escape_rejected.va` | `lrm 9.4.2`, `lrm 2.7`, `reject-only E0138` | `$strobe("first line` / `second line");` (raw newline) | stays |
| `verilog/A_formal_syntax/b_A_8_8_string_across_newline_rejected.v` | `inherited IEEE 1364-2005 A.8.8`, `reject E0138` | raw newline | stays |
| `verilog/19_compiler_directives/ignored_group_lexical_rejected.v` | `inherited IEEE 1364-2005 19.4`, `reject E0138` | unclosed string in an ignored `` `ifdef `` arm | stays |
| `verilog/03_lexical_conventions/string_line_continuation_rejected.v` | `inherited IEEE 1364-2005 3.6`, `reject E0138`; comment: "the backslash-newline continuation is IEEE 1800 (string12)" | string12's `"this\` / ` matches"` | stays under §5 (`.v` keeps E0138); flips only under Q2's alternative |
| `verilog/03_lexical_conventions/string_spans_lines_rejected.v` | `inherited IEEE 1364-2005 3.6`, `reject E0138`, `neighbour lexical_packed_strings.v` | raw newline | stays |
| `verilog-a/ch10_directives/macro_text_does_not_split_a_string.va` | `lrm 10.4`, `reject-only E0145` | `` `define `` whose string never closes | stays |
| `verilog/19_compiler_directives/split_string_rejected.v` | `inherited IEEE 1364-2005 19.3.1`, `reject E0145`, `neighbour text_macros.v` | the §19.3.1 illegal example | stays |

Over all 4243 suite files, exactly two contain a `\`+LF inside a string: the two
`string_line_continuation_rejected` fixtures. No accept fixture, and no `` `define `` body in the
suite, has one; the macro join's one-space meaning is pinned nowhere in the suite (only
`tests/unit/preprocessor_tests.zig:1691-1694`, for macro text outside a string).

### External expectations (`tests/conformance/external/expectations.tsv`, regenerated into the manifests by `manifests.py`)

| row | want | reason | under §5 |
|---|---|---|---|
| `:223 openvaf/integration_tests/BSIM3/bsim3.va` | reject | `VAMS-2023 2.7 (+1364-2005 3.6; VD-021) (forbids it; suite issue #1)` | row deleted: upstream's `compile` |
| `:224 openvaf/integration_tests/BSIM4/bsim4.va` | reject | `VAMS-2023 2.7 (VD-021)` | row deleted |
| `:231 va-models/bsim4/vacode/bsim4.va` | reject | `VAMS-2023 2.7 (VD-021)` | row deleted |
| `:37 gnucap-modelgen/dump_escape.1.vams` | reject | `VAMS A.1.2; VAMS 2.7 (+VD-021)` | stays reject; reason trimmed to A.1.2 (`module test()`) |
| `:215 ivtest/ivltests/string12.v` | reject | `3.6/A.8.8` | stays (`.v`) |
| `:225 openvaf/integration_tests/BSIM6/bsim6.va` | reject | `A.6.3/A.6.4 (Syntax 5-1)` | unrelated, stays |
| `va-models.manifest:15-19` bsim6.0, bsimbulk, bsimbulk106, bsimbulk107; `openvaf.manifest:28` bsimbulk | compile | (upstream default) | stay `compile`; their bytes change (§5, macro rule) |

`external/vacask/devices/bsim4v8.va` and `bsim3v3.va` are in no manifest (vacask is not a
selected suite), so nothing grades them today.

### The external corpus

`find -L tests/conformance/external` `.va`/`.vams`: 599 files. With a `\`+LF inside a string
literal (comments stripped): **13 files, 106 sites**; 66 in plain statements and 40 inside
`` `define `` bodies. Every site is `\` immediately followed by LF (no CRLF, no blanks between).

| file | sites | where |
|---|---:|---|
| OpenVAF `integration_tests/BSIM4/bsim4.va`, VA-Models `bsim4/vacode/bsim4.va`, vacask `bsim4v8.va` | 17, 9, 17 | `$strobe` statements |
| OpenVAF `integration_tests/BSIM3/bsim3.va`, vacask `bsim3v3.va` | 11, 11 | `$strobe` statements |
| OpenVAF `BSIM6/bsim6.va`, VA-Models `bsim6/vacode/bsim6.0.va` | 10, 10 | `` `STROBE2(...) `` inside `` `define `` bodies |
| VA-Models `bsimbulk.va`, `bsimbulk106.va`, `bsimbulk107.va`, OpenVAF `BSIMBULK/bsimbulk.va`, vacask `bsimbulk106.va` | 4 each | `` `define `` bodies |
| gnucap `tests/dump_escape.1.vams` | 1 | `$strobe` (a deliberate test of the form) |

### Code pins

- Old side: `lib/frontend/lexer.zig:276-294` `lexString` ("§2.7: contained on a single line";
  `:284` pairs `\` with any byte but LF), `:631-637` test "strings (§2.7)", `:640-658` test
  "stringRunaway names the §2.7 mistake (E0138)" (the `.line_continuation` case);
  `lib/frontend/token_value.zig:46-53` `StringRunaway`, `:215-232` `stringRunaway`, `:125`
  `stringContents` (an unlisted escape decodes to the escaped byte, so `\`+LF would already give
  LF), `badEscape` (W0149 on any escape outside Table 2-2); `lib/frontend/parser.zig:666`
  `failAt` → `:777-795` `failRunawayString` (E0138 plus the §5.9 note); `lib/frontend/pp/scan.zig:82-97`
  (strings opaque; `:94` E0138 in an inactive arm), `:164` `stringStop`;
  `pp/directive.zig:266` `logicalLineEnd`; `pp/macro.zig:317` `joinContinuations`, `:610`
  `splitsString`; `tests/unit/preprocessor_tests.zig:675` (E0145), `:1615`, `:1691-1694`,
  `:2186-2196` (`stringStop` crosses `"a\`+LF+`b"` to index 5).
- New side (a mirror): `lib/std/vams/tokenizer.zig:453-468` `string` (`:461`);
  `lib/std/vams/Ast/errors.zig:25` `Runaway`, `:73-80` E0138 and the note, `:349-360` `runaway`;
  `lib/std/vams/number_literal.zig:158` `badEscape` (octal only), `:179` `stringContents`, called
  from `lib/std/vams/AstGen/expr.zig:179`, `:253`; `lib/std/vams/Preprocessor/scan.zig:82-96`
  (`:94` E0138), `:255` `stringStop`; `Preprocessor/directive.zig:212` `logicalLineEnd`;
  `Preprocessor/macro.zig:226` `joinContinuations`, `:494` `splitsString`;
  `Preprocessor/tests.zig:374` (E0145), `:749-750`.
- Neither lexer knows the language; the preprocessor does (`lib/frontend/preprocessor.zig:85`,
  `lib/std/vams/Preprocessor.zig:86` `std_1364`, set from `config.language` at
  `src/next/Compilation.zig:172`), and already uses it to warn about an 1800 macro form in a
  1364 unit (W0151, `pp/macro.zig:116-119`).
- Records: `Vague_Decisions.md:65`, `:388-397` (VD-021); `research/diagcodes-map.tsv:43` (E0138
  → `AMS-2.7a`, fixture `reject_A_8_8_string_spans_lines.va`).

## 3. What the two lexers do with `\`+LF (summary)

| context | old side | new side |
|---|---|---|
| in a string, statement | token ends at LF as `.invalid` (`lexer.zig:281,284`); `stringRunaway` → `.line_continuation`; E0138 with the "IEEE 1800 §5.9" note (`parser.zig:783-792`) | identical (`tokenizer.zig:458,461`; `errors.zig:75-79`) |
| in a string, `` `define `` body | `logicalLineEnd` joins the line; `joinContinuations` emits one space (unless the text already ends in one) and eats the next line's blanks and tabs, inside strings too; the lexer then sees a one-line string | identical (`macro.zig:226-247`) |
| in a string, inactive `` `ifdef `` arm | `stringStop` pairs `\`+LF, the string counts as closed, the arm's newlines are emitted; nothing is reported | identical |
| raw LF in a string | `.invalid`, E0138 (`.unterminated`) | identical |
| `\`+LF outside a string, outside macro text | `\` starts an escaped identifier (§2.8.1) that LF terminates: an empty escaped identifier, `.invalid` | identical |

## 4. Other tools in the repo

- **OpenVAF** (`tests/conformance/external/OpenVAF-Reloaded`). Lexer `openvaf/lexer/src/lib.rs:391-405`
  `double_quoted_string`: runs to the next `"` across any number of newlines, pairing only `\\`
  and `\"` (`:398`); only EOF makes it unterminated (`openvaf/tokens/src/lib.rs:46-47`
  `UnterminatedStr`). A top-level `\`+LF is whitespace (`lib.rs:85-88`, `:305`). Value:
  `openvaf/syntax/src/ast/expr_ext.rs` `StrLit::unescaped_value`, a chain of `.replace`:
  `\n`→LF, `\\`→`\`, `\t`→TAB, `\"`→`"`, then `"\\\n"`→`"\n"` and `"\\\r\n"`→`"\r\n"`. So the
  **backslash is dropped and the newline kept**, the next line's indentation kept; a raw newline
  is accepted and kept. Used for `$strobe` arguments at `openvaf/hir_def/src/body/lower.rs:505-506`.
  BSIM4's message therefore prints as two lines, the second indented by 29 blanks. (The chain is
  order-dependent, e.g. `\\n` is rewritten twice; it is not an oracle for edge cases.)
- **ngspice** (`external/ngspice`): no Verilog-A front end in the tree; it loads OSDI objects that
  OpenVAF builds. `NEWS:261` "ADMS is declared deprecated", `:169` "Remove some ADMS remnants".
  No ADMS source is in the repo.
- **gnucap-modelgen-verilog** (`external/gnucap-modelgen-verilog/src/mg_pp.cc:288-316`, the
  quoted-string reader): after a `\`, only `\\`, `"` and `n` are copied as a pair; any other byte
  is left to the loop head, whose `while (f.peek() && !isgraph(f.peek())) data += f.ctoc();`
  copies the newline and the indentation. So gnucap keeps **backslash, newline and indentation
  verbatim** in the string data; its `tests/dump_escape.1.vapp` shows the continuation unchanged
  (that test exists to exercise the form; the repo grades it `reject` for A.1.2, not for this).
- **Icarus Verilog** (`.v` only): `ivtest/ivltests/string12.v` is in its regression list and
  prints `PASSED`, i.e. Icarus accepts the form with the 1800 bytes (`\`+LF removed, leading
  blank kept) in a 1364 unit.

No tool in the repo refuses the form. Three meanings exist: 1800's (Icarus, the ispras and
sv-tests witnesses: `\`+LF removed), OpenVAF's (`\` removed, LF kept), gnucap's (everything
kept). VerA's macro join is a fourth (one space, indentation eaten).

## 5. Recommended rule

**R1 (Verilog-A/AMS units): accept.** Inside a string literal, a `\` immediately followed by LF
(or CR LF) continues the literal on the next line; those bytes contribute nothing to the value and
nothing else changes: the next line's leading blanks and tabs are part of the string (§2.3:
"spaces and tabs shall be considered significant characters in strings"). This is IEEE 1800
§5.9's meaning as the three in-repo witnesses fix it, the only meaning under which
`"this\`+LF+` matches" == "this matches"`, and what the BSIM authors wrote for.
Not OpenVAF's (keeps the LF: contradicts the witnesses and prints the BSIM4 message on two
lines); not the macro join's (one space, indent eaten: no standard says it); not gnucap's.
`\` followed by blanks then LF is not a continuation (the `\` escapes the blank, as today).
A raw newline stays E0138: VD-021's core reading stands, 1800 forbids it too, only OpenVAF
accepts it, and every raw-newline fixture (§2) stays red.

Why reopen VD-021 for this half: (1) the rule was never a rule: VerA already accepts the same
bytes in a macro body and in a dead arm, with two other meanings (§0), so "refuse" today means
"refuse unless a macro hides it"; (2) the cost is the BSIM family, the reason a SPICE engine
consumes VerA, and the files cannot be changed; (3) the VAMS text has a hook 1364 lacks: A.8.8
dropped `_except_new_line` and change 2535 says the string production was corrected "for
multiline strings"; §3.3 already imports 1800's string type; (4) every tool in the repo accepts
the form. VD-021's portability point ("what VerA accepts, a 1364-based tool accepts too") is kept
where it is true, in `.v`.

**R2 (IEEE 1364 units, `.v`): keep E0138.** §3.6 and A.8.8 (`Any_ASCII_Characters_except_new_line`)
are explicit, the two `.v` fixtures and string12's expectation pin it, and the 1364 route's
identity is the standard by the book. Site: the preprocessor's string branch under `std_1364`
(`pp/scan.zig:82-97`, `Preprocessor/scan.zig:82-96`), where the flag lives and where E0138 is
already raised for a dead arm; the E0138 message keeps today's §5.9 note there. The lexers need
no language flag. (The alternative, accept with a warning in the shape of W0151, is Q2.)

**R3: no warning under VAMS.** Precedent: W0151 reads 1800's macro forms silently under VAMS and
warns only in a 1364 unit (`pp/macro.zig:116-119`). A warning per BSIM4 build names nothing the
user can act on. (Q1 if the lead wants one.)

**R4: one meaning in macro text.** `joinContinuations` (both sides) treats a `\`+LF inside a
string literal as R1 does: removed outright, no space inserted, the next line's blanks kept; its
end assertion (no LF in the body) still holds. So `` `define M "a\``+LF+`b" `` and the plain
literal give the same bytes, and the macro route stops being a second decoder. In a 1364 unit
the same spot is E0145 (`macro text splits a string literal`: §19.3.1's "replaced ... with a
newline" makes the split certain), beside the `std_1364` branch W0151 already has. BSIMBULK's
and BSIM6's `$strobe` bytes change (tabs kept instead of one space); no gold holds them.

**R5: E0138's `.line_continuation` arm goes** on both sides (`token_value.zig:46-53`, `:215-232`;
`parser.zig:786-792`; `errors.zig:25`, `:77`, `:349-360`): a VAMS unit never reaches it, and the
1364 unit's refusal moved to the preprocessor (R2). The lexer tests at `lexer.zig:640-658` and
the tokenizer's flip to `.string_literal`.

### Sites and their oracles (one PR, both sides together, red first)

| # | site | change | oracle |
|---|---|---|---|
| S0 | suite (user's repo): `ch02_lexical/string_line_continuation.va` (new accept fixture, §6), `ch10_directives/macro_string_line_continuation.va` (new), `string_line_continuation_rejected.va` deleted; `expectations.tsv` rows `:223`, `:224`, `:231` deleted, `:37` reason trimmed; `manifests.py` rerun | the fixtures are **red today** (E0138; the macro one gives `"a b"`), and `zig build conformance`/`test-external` then require BSIM3 and BSIM4 to compile | the §2.7 base-256 numeral (`CHECKI`, as `string_escapes.va`), the BSIM4 model compiling, string12 staying refused |
| S1 | `lexer.zig:284`, `tokenizer.zig:461` | pair `\` with LF (and CR) like any escaped byte | S0; `lexer.zig:632-638` gains `"a\`+LF+`b"` → `.string_literal`; `"a\\`+LF+`b"` stays `.invalid` (the `\\` is Table 2-2's pair) |
| S2 | `token_value.zig:125` and `number_literal.zig:179` `stringContents` | `\`+LF (and `\`+CR+LF) emit nothing | unit test per side: `"a\`+LF+`b"` → `ab`, `"a\`+LF+`  b"` → `a  b`, `"a\n\`+LF+`b"` → `a`,LF,`b` |
| S3 | `token_value.zig` `badEscape` | `\`+LF is not W0149 | the S0 accept fixture carries `//! nowarn` |
| S4 | `pp/scan.zig:82-97`, `Preprocessor/scan.zig:82-96` | in a `std_1364` unit, a closed string whose text holds `\`+LF fails E0138 with the §5.9 note | `string_line_continuation_rejected.v`, string12 (`expectations.tsv:215`); pp unit test both sides |
| S5 | `pp/macro.zig:317`, `Preprocessor/macro.zig:226` `joinContinuations` | inside a string: drop `\`+LF only (R4); `std_1364`: E0145 | S0's macro fixture (red today: one space); `preprocessor_tests.zig:1691-1694` stays (outside a string); new case per side |
| S6 | R5's deletions; `research/diagcodes-map.tsv:43` (fixture path); `Vague_Decisions.md:65`, `:388-397` (VD-021 revised: (c) for VAMS, (a) for 1364, dated, citing this file) | — | `check_style.py`, `zig build check` |
| S7 | diff-comp | both drivers see the two new fixtures; no `comp.xfail` line expected since both sides change together | `tools/build-slot.sh <wt> diff-comp -Dcomp-filter='string_line_continuation\|macro_string_line_continuation'`, exit code |

Narrow before wide: `test-frontend`/`test-<new lexer module>`, then S7, then the full gate once.

## 6. The fixtures to propose (not written: the suite is the user's repo)

`tests/conformance/tests/verilog-a/ch02_lexical/string_line_continuation.va`, the legal twin of
`multiline_string_rejected.va`, oracle: §2.7's numeral rule, as `string_escapes.va` uses it.

```
// §2.7 reads a string literal as a base-256 numeral, most significant character
// first, and §2.3 makes a blank inside it significant. A `\` immediately before
// the newline continues the literal on the next line and contributes nothing
// (IEEE 1800 §5.9's form, which the BSIM3/BSIM4 models use in $strobe);
// everything on the next line, its indentation included, is in the string.
// A raw newline is still refused: multiline_string_rejected.va.
//   "a\<newline>b"      is "ab"   = 97*256 + 98                      = 24930
//   "a\<newline> b"     is "a b"  = 97*65536 + 32*256 + 98           = 6365282
//   "a\n\<newline>b"    is "a",LF,"b" = 97*65536 + 10*256 + 98       = 6359650
//! lrm 2.7
//! lrm 2.3
//! nowarn
//! neighbour multiline_string_rejected.va
//! neighbour string_escapes.va
`include "check.vh"
module ch02_string_line_continuation(p, n);
    inout p, n;
    electrical p, n;
    analog begin
        `CHECKI("backslash-newline joins the lines", "a\
b", 24930);
        `CHECKI("the next line's blank is kept", "a\
 b", 6365282);
        `CHECKI("\\n is the one way to put a newline in", "a\n\
b", 6359650);
        I(p, n) <+ 0.0;
    end
endmodule
```

`tests/conformance/tests/verilog-a/ch10_directives/macro_string_line_continuation.va`: the same
three numerals through `` `define M1 "a\``+LF+`b" `` etc., plus one metamorphic check that
`` `M1 == "a\``+LF+`b" `` (the macro route and the lexer route agree). Header `//! lrm 10.4`,
`//! lrm 2.7`, `//! nowarn`, `//! neighbour macro_text_does_not_split_a_string.va`. Red today:
the join gives `"a b"` (6365282) for M1.

`verilog/03_lexical_conventions/string_line_continuation_rejected.v` stays as is (R2). If Q2
goes the other way it becomes the `.v` accept twin with `$display("%0d", ...)` and an
`.expected.txt`, and `expectations.tsv:215` becomes `passed`.

`external/expectations.tsv`: delete `:223`, `:224`, `:231`; `:37` keeps `reject` for
`VAMS A.1.2` alone. The openvaf and va-models manifests then carry upstream's `compile` for
BSIM3/BSIM4, the end-to-end oracle ("a BSIM4 model parsing and building").

## 7. Risks

- A consumer that compared `$strobe` text with OpenVAF's output sees one line where OpenVAF
  prints two. No gold in the repo holds any `$strobe` text with a continuation.
- BSIMBULK/BSIM6 messages change bytes (R4). Same: no gold.
- The first `compile` of BSIM3/BSIM4 may uncover the next refusal behind E0138 (the lead's
  question was only the lexer). If so, the rows get a new `LRM=` reason, not VD-021's.

## Open questions

**Q1. Warn under VAMS when a string continues across a line?**
Recommendation: no (R3): W0151's precedent, and nothing the user can do about BSIM4.
Decision: No warning (R3).

**Q2. `.v` (1364 unit): keep E0138 (R2), or accept with a warning in W0151's shape?**
Keeping it costs one `if` in the preprocessor and keeps two `.v` fixtures and string12's
expectation. Accepting matches Icarus and 1800 but contradicts 3.6/A.8.8's explicit
`except_new_line`, and the 1364 route is the standard by the book elsewhere (W0151 warns, the
rest refuses).
Recommendation: keep E0138 in a 1364 unit; the message keeps the §5.9 note.
Decision: Keep E0138 in a 1364 unit (R2); the message keeps the §5.9 note.

**Q3. Exact bytes: 1800's (`\`+LF removed, next line verbatim) or trim the continuation line's
indentation?**
No tool and no standard trims; §2.3 makes the blanks significant; BSIM4's message then carries
29 inner blanks, as it does in every SystemVerilog tool.
Recommendation: 1800's bytes, nothing invented.
Decision: IEEE 1800's bytes (user, 2026-11-11): `\`+LF removed, the next line kept verbatim; nothing invented.

**Q4. Macro text (R4): make the join give R1's bytes inside a string (one meaning), or leave the
one-space join and document two meanings?**
One meaning is a few lines in each `joinContinuations` and a red fixture; two meanings are a
wrong-text-no-crash class with no oracle. In a 1364 unit, E0145 there follows §19.3.1 directly.
Recommendation: one meaning (R4), E0145 under `std_1364`.
Decision: One meaning (R4): the join gives R1's bytes inside a string; E0145 under `std_1364`.

**Q5. VD-021: revise the entry in place or add VD-0xx?**
Recommendation: revise in place (the rule changes for half its scope), keep the original text
under a "Revised 2026-11-11" line citing `research/strings.md`, status back to `no` until S0-S7
land.
Decision: Revise VD-021 in place, keeping the original text as its history.
