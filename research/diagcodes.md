# Plan: diagnostic codes keyed by the specification, and the gap report they feed

User's request (verbatim): "rewriting the error codes to reference the specification to
know if we handle it or not, rather than a random number that our compiler arbitrarily
picked."

Lead's framing (verbatim): "the codes exist so that a Python script (tools/, one file, per
AGENTS.md layout) can compare every code the compiler can emit against the
specification's clauses and print the gaps: clauses with no code (a rule we never check),
clauses whose only code is 'not supported yet' (a feature we refuse), and codes with no
fixture. That gap report is the main deliverable; design the scheme around making it
trivially machine-checkable."

State read at `refactor` 90e93007 (conformance submodule at 044c6cc). No builds were run.
Every number below comes from a script over `lib/std/vams/Diag/codes.zon`, `src/`, `lib/`,
the fixture tree, the submodule's ledgers and the two PDFs in `docs/specification/`
(`pdftotext -layout`). Those scripts are in this session's scratchpad (`dc/gaps_probe.py`
is the gap report's prototype). The per-code result is `research/diagcodes-map.tsv`
(511 rows).

Zig references: `S/` = `/nix/store/spqy6l91i77g18ndfbaq441khlr8zd5f-zig-0.18.0-dev.349+d924f83bf/lib/`,
`Z/` = the pinned compiler source under this session's scratchpad (`zig/`).

## 0. One screen

- **The report's top level, today** (prototype `dc/gaps_probe.py`; every clause of each
  standard's ledger gets exactly one verdict):

  | standard | clauses | checked | refused (target gap) | unchecked (no code) | positive-only | uncited |
  |---|---|---|---|---|---|---|
  | AMS 2023 | 522 | 137 (35 partial) | 7 | 146 (all 146 have positive fixtures) | 228 | 4 |
  | IEEE 1364-2005 (provisional) | 779 | 10 | 12 | 92 (81 have positive fixtures; 26 hidden behind E1100) | 382 | 283 |

  - *checked*: the clause states a prohibition and a `rule` code cites it.
  - *refused*: only `unsup` codes cite it. This is a feature VerA refuses, i.e. a
    compiler target gap.
  - *unchecked*: it states a prohibition and no code cites it, i.e. a rule VerA never
    checks.
  - *positive-only*: it states no prohibition, and fixtures exercise it positively.
  - *uncited*: neither.

  Codes: 482 live, 0 dead (no raise site), 0 raised without a row, 36 rule codes with no
  fixture, 97 `unsup` codes with no xfailed fixture.
- **The deliverable is `tools/diag_gaps.py`** (§1). It is one Python file with three
  subcommands: `report`, `ledger` and `selftest`. It reads three things:
  1. the spec side: the submodule's sentence ledgers;
  2. the compiler side: `codes.zon` plus a token scan of `src/` and `lib/`;
  3. the evidence: the fixtures' `//!` lines and the two xfail lists.

  It prints the table above, per standard, with one line per clause. It is run by the
  `zig build diag-coverage` step, which checks the exit code. No Zig program is
  involved: the script reads `codes.zon` directly.
  - The IEEE 1364-2005 row is provisional: its ledger does not exist yet, and its 114
    prohibition clauses come from a regex seed (§1.2).
- **Gates.** These fail the merge gate: a dead code, a raised code with no catalogue row, a rule code with no fixture, an
  `unsup` code with no xfailed fixture, a shared fixture that demands refusal of legal
  code, a code whose clause disagrees with its fixtures' citations, a code whose clause
  has no matching ledger sentence, and refusal wording on a `rule` code. Every known
  miss is a named line in `tools/diag_gaps.xfail`, and an unexpected pass fails.
  Unchecked and partly checked clauses are reported only.
- **What the scheme gives the script** (§1.6):
  - the key carries the standard, the clause and the kind, so one regex parses it;
  - one catalogue file holds every code;
  - one source token names each raise site;
  - fixtures and xfail lines name codes by key or alias.
- **The spelling** (§3):
  - a rule is `<std>-<clause><letter>` (`AMS-5.6.7.2b`, `V2005-19.4a`);
  - a refusal of legal code is `unsup-<std>-<clause><letter>`;
  - the other kinds are `limit-…`, `lint-…` and `ice-…`;
  - source names codes by mnemonic tags (as aro does), and the old E/W numbers stay
    as permanent aliases.
- **The mapping** (§4): 511 rows (482 live, 29 retired).
  - Kinds: 344 rule, 6 syntax, 97 unsup, 20 limit, 14 lint, 1 ice.
  - 24 rows cite the wrong clause, 19 live rows cite none, and 20 are suspect.
- **Migration** (§5): the script and the additive columns land before G0 and change no
  output. The spelling flip is switchover.md's **C6b**; the splits come after it.
- **Tasks:** 7 in phase A, 2 in C6b and 7 in phase D: 16 in total (§7).

### Where each skill bites

| skill | where |
|---|---|
| test-plan / tdd | the report is an oracle (§1.4); the script's own oracle is a planted clause, code and fixture that must show up as gaps (§1.7); each task has a red-first fault (§7) |
| assertions | the script asserts its parsed counts against an independent count (rows vs `^    \.\w+ = \.\{` lines, ledger rows vs non-comment lines); the comptime `checkRow` is the catalogue's contract |
| data-oriented-design | six questions for the script's tables (§1.8) and the catalogue's `Spec` (§3.9); `Kind`/`Standard` are `enum(u3)`; `Code` stays `enum(u16)` |
| codebase-clean-code | one owner per table: `lib/std/vams/Diag/` writes the catalogue, the submodule's `vera/ledger/` holds the spec side, and the script only reads; the CLI parses a spelling once, at `args.zig` |
| api-design | usage code first (§3.6); `lookup` returns a value; the script's output is a TSV the caller (CI, release notes) reads, with no callbacks |
| code-style | the script is one file under 500 code lines; `code.zig` stays one transformation |
| doc-comments | the script's module docstring states in → out and the two specs it cites; each new `pub` in `code.zig` states the invariant its check enforces |
| compiler-construction | rule 5 (codes as data: "never renumbered" becomes "never reused, aliased forever"), rule 6 (`unsup` is the refusal kind with a clause), rule 9 (C6b's golden diff is checked by a script), rule 10 (two-way evidence: `untested` + `misuse`) |
| ponytail (ultra) | no new runtime surface beyond three catalogue columns and one lookup. **Dropped** from the previous draft: `clauses.zon`, `tools/spec_clauses.py` and the Zig `tests/diagcov.zig`, because the submodule's ledgers already hold the clause list. Also rejected: a legacy output flag and a JSON catalogue dump |
| zig | `std.StaticStringMap(Lookup).initComptime`; `@Enum` reification from ZON field names; `@hasField` for optional ZON columns |
| writing-perfect-verilog | the ~79 `--emit-rtlil` refusals are classified against the synthesizable subset. Zero replication, variable-base part-selects and selects of parameters are legal IEEE 1364-2005, so they are `unsup`, not rules |
| spice-engine | the Annex E rows (`E0928`, `E0952`, `E0953`) are `unsup-AMS-E.*`, because E.1.2 makes the primitive set implementation-defined |
| simd-loops | not applicable: everything here is cold |

## 1. The gap report: `tools/diag_gaps.py`

### 1.1 What it answers, and from what

| question | spec side | compiler side | evidence |
|---|---|---|---|
| Which prohibitions do we never check? | ledger rows whose `pol` contains `-` | no `rule` key cites the clause | — |
| Which features do we refuse? | the same rows | only `unsup` keys cite the clause | xfailed positive fixture |
| Which codes can never fire? | — | a live row with no raise site | — |
| Which codes are never tested? | — | a live row | no fixture names it (rule), or no xfail line names it (unsup) |
| Does a code cite the right clause? | the ledger has a `-` sentence at the clause | the key's clause | the fixtures' own `//! lrm` / `//! inherited` |

### 1.2 Spec side: the ledgers

One ledger per standard, in the submodule beside the other evidence ledgers
(`tests/conformance/vera/README.md:12`).

| std | file | exists | rows | what "checkable" means |
|---|---|---|---|---|
| `AMS` | `vera/ledger/OBLIGATIONS.tsv` | yes | 1643 sentences over 522 clauses. `pol`: `+` 938, `+-` 283, `-` 214, `0` 208. `kind`: 1406 `-`, 127 `non-normative`, 42 `unspecified`, 39 `optional`, 26 `implementation-defined`, 3 `resource-limit` | a clause with at least one row where `pol` contains `-` and `kind` is not `non-normative`: **290 clauses, 497 sentences** |
| `V2005` | `vera/ledger/OBLIGATIONS-1364.tsv` (**new**, task A1) | no; `vera/clauses/ieee1364/CLAUSES.tsv` has the 808 headings without text | seed: 1617 "shall" sentences in 350 clauses, of which 221 sentences in 114 clauses read as prohibitions by regex (`shall not`, `illegal`, `is an error`, `shall be an error`, …) | the same rule once a reader has classified `pol` (A1b); until then the regex seed, marked provisional in the report header |
| `VERA` | none | — | — | no denominator: VERA codes are listed with their evidence only |

Ledger format (the existing one, unchanged): `id hash modal pol kind oracle text`, where
`id` is `clause:ordinal` and `ordinal >= 1000` marks a hand-written `declar.` row. A
changed hash resets the row's classification to `?` (OBLIGATIONS.tsv header).

- **The IEEE ledger has no text column.** `tests/conformance/vera/clauses/ieee1364/CLAUSES.tsv`
  states the licensing rule: "The PDF is licensed and not in git, so this file is its
  committed stand-in; titles are headings, no" body text. Its `text` column is therefore `-`.
  `diag_gaps.py ledger --show 19.4` prints the sentences from the local PDF, so a reader
  can classify them (open question 9).
- **Refresh is by hand, never in CI.** `diag_gaps.py ledger --update --std AMS|V2005`
  - requires `pdftotext`, which is in no dev shell today; A1 adds `poppler_utils` to
    `flake.nix`'s `external` shell, pinned by `flake.lock`;
  - checks each PDF's sha256 against `LRM_SHA256` and `IEEE_SHA256`, imported from
    `tools/conformance.py`, so the constants stay in one place;
  - re-extracts the modal sentences and keeps the classification of every row whose
    hash is unchanged.

  This also restores the extractor that OBLIGATIONS.tsv's header names
  (`tools/conformance.py obligations --update`), a subcommand that no longer exists.
- **Clause existence** (the `nospec` gate) is checked against the ledger. A rule key
  must cite a clause with a `-` sentence. An unsup key needs only a clause that exists:
  a ledger row, or for V2005 a heading in `CLAUSES.tsv`.
- The per-chapter `vera/clauses/<chapter>/CLAUSES.tsv` files mark AMS clauses
  `no-prohibition` (88 clauses). The script asserts that they never conflict with a `-`
  ledger row (0 conflicts today). It reports any rule code that cites one: there are 2
  today, at 4.3 and 5.8, and A6 rules on them.

### 1.3 Compiler side: the catalogue and the raise sites

- **Catalogue.** The script reads `lib/std/vams/Diag/codes.zon` with a ZON-subset reader
  of about 30 lines. Each row starts with `^    \.(\w+) = \.\{`, and its fields are
  `^        \.(\w+) = ("…"|\.\w+|\.\{…\})`; multiline `\\` text is skipped.
  - Paired assertion: the number of rows parsed equals the number of row-start lines.
  - Before C6b, the row name is the key (`E0415`), and the script takes `kind`, `std`,
    `clause` and `also` from the A2 columns.
  - After C6b, the row name is the tag, and the script parses `key` with the §3.1
    grammar.
- **Raise sites.** A code is *raised* when any of these appears in `src/**` or `lib/**`:
  - its tag token `.tag` (before C6b: `.E0415`) in a `.zig` or `.zig.txt` file;
  - its spelling inside a string, as `[KEY]` or `"KEY"`.

  The scan skips the catalogue directories (`lib/std/vams/Diag/`, `lib/diag/codes/`)
  and `test "…" { … }` blocks (by brace depth). The scan must include:
  - `src/Compilation/osdi.zig:24,26` (`bag.add(.codegen, .E1099 …)`, `.W1098`);
  - the spelled runtime strings `src/codegen/exe/text/body.zig.txt:72,104`
    (`error[E0377]`), `lib/kernels/hist_kernels.zig:119` and
    `lib/std/kernels/ops.zig:177` (`warning[W1051]`).

  The first prototype missed exactly these, and reported E0377, W1051, E1099 and W1098
  as dead. The selftest plants one raise site of each form (§1.7).
- **Which tokens count.** Any `.tag` token outside the skipped areas counts. That is a
  superset of the `fail`/`failWith`/`Why{.code = …}`/`bag.add`/`warn` call forms, so a
  new call form cannot hide a raise.
  - The scan covers all of `lib/`, not only `lib/std`. Until C4, the old runtime
    (`lib/kernels/hist_kernels.zig:119`) is the only raiser of W1051 in shipped
    executables.
  - **Raised without a row** (`unknown`): a spelling in `[…]` or `"…"` that matches the
    key grammar or `[EW]\d{4}` but names no row or alias. Before C6b, the compiler
    already rejects an unknown `.E…` tag, but only this check catches spelled strings.
    The count today is 0. The only candidate, `W9999` at `src/cli/args.zig:671,942`,
    sits in `test` blocks and is correctly skipped.
- **No tag collides with another identifier.** The script fails if a tag is also
  declared as a function, constant or field name anywhere in `src/` or `lib/`, so a
  `.tag` token always means the code.
- **Measured today:**
  - Over the whole tree, **0 dead** live codes. 29 rows are retired, and none of them
    is raised.
  - Over the new side only (`src/next`, `src/Sema*`, `src/Air*`, `src/codegen/zig*`,
    `src/codegen/digital_next*`, `src/codegen/rtlil*`, `lib/std`), 256 codes are not
    raised. That is expected while the backends are incomplete, so it is report-only
    until C4 deletes the old side. The script's `NEW_ROOTS` constant is deleted at C4.

### 1.4 Evidence side: fixtures and xfail lists

- **Fixtures.** The script reads the first 64 `//!` lines of every file under
  `tests/conformance/tests/` and `tests/conformance/vera/{rtlil,osdi,beh_verilog,host}/`.
  It does not read `canary/`, which holds the fixtures that are wrong on purpose.
  - The directives read are `reject`, `reject-only`, `reject-run` and `warn`, plus the
    citations `lrm`, `inherited`, `lrm-reject` and `inherited-reject`.
  - A directive names a code by key or alias. A group alias does not count as evidence,
    because it cannot say which member fired.
  - There are 1332 directive files today: `reject-only` 840, `reject` 444, `warn` 43,
    `reject-run` 14.
- **Xfail lists.** `tests/conformance/vera/xfail` and `tools/vera.xfail` contain
  `<path> # <reason>` lines. An `unsup` code is *listed* when a reason names it and the
  path exists. Both lists are empty today.
- **Unit tests.** About 496 lines in `tests/unit/*.zig` name codes. The report shows
  them in a `unit` column, but they do not satisfy `untested`: only a fixture runs the
  whole driver.

### 1.5 Output

```
$ python3 tools/diag_gaps.py report            # stdout; --tsv PATH also writes the table
AMS (Verilog-AMS 2023; vera/ledger/OBLIGATIONS.tsv, 1643 rows)
clause     neg  rule                     unsup                   verdict
5.6.7.2    1    AMS-5.6.7.2b(2)          -                       checked
2.6.1      4    AMS-2.6.1a(3)            -                       partial
5.10.3.3   1    -                        unsup-AMS-5.10.3.3a(0)  refused
1.3.4.2    2    -                        -                       unchecked
...
AMS: 522 clauses: 137 checked (35 partial), 7 refused, 146 unchecked, 228 positive-only, 4 uncited
V2005 (IEEE 1364-2005; vera/ledger/OBLIGATIONS-1364.tsv; PROVISIONAL: 1617 rows, pol unreviewed)
...
V2005: 779 clauses: 10 checked, 12 refused, 92 unchecked, 382 positive-only, 283 uncited
VERA: 16 codes, no ledger
codes: 482 live: dead 0, unknown 0, untested 36, unlisted 97, misuse 32, cite 258+E1100, nospec 26, wording 36
```

- **Columns.**
  - `neg`: the clause's `-` sentence count.
  - `rule` and `unsup`: keys whose clause or `also` equals the clause, each with its
    fixture count in parentheses.
- **Verdicts.**
  - `checked`: at least one rule key.
  - `partial`: as checked, but with fewer rule keys than `neg` sentences. This is a
    heuristic, so it is report-only.
  - `refused`: unsup keys only.
  - `unchecked`: neither.
  - `positive-only`: no prohibition sentence, and at least one fixture cites the
    clause (`//! lrm`, `//! inherited`).
  - `uncited`: neither a prohibition nor a citing fixture.
  - A clause whose only rule keys sit on a sub-clause is still `unchecked`. The report
    adds `(sub: AMS-x.y.z…)`, so the reader sees whether the sub-clause covers it.
    There are 9 such AMS clauses today.
- `zig build diag-coverage` writes the TSV to an output file argument for the release asset.
  Nothing generated is committed.

### 1.6 What the scheme must give the script (the design requirements)

| # | requirement | why the script needs it | where in §3 |
|---|---|---|---|
| R1 | the key carries std, clause and kind, parseable by one regex | joins a code to a ledger clause with no side table | §3.1 grammar |
| R2 | one catalogue file, one row per code, including retired rows | the denominator of `dead`/`untested`; aliases resolve fixture spellings | §3.9 |
| R3 | one source token per raise site: the tag, or the key inside a rendered string | `dead` is a grep, not a call-graph analysis | §3.4 |
| R4 | an `unsup` kind distinct from `rule` | "refused" vs "checked" is a column read, not a prose guess | §3.2 |
| R5 | aliases in the catalogue | old fixture lines (`//! reject E0415`) still count until D1 rewrites them | §3.5 |
| R6 | `also` for a rule that spans clauses | one code may legitimately check two clauses | §3.3 |

Before C6b, R1 holds through the A2 columns (`kind`, `std`, `clause`, `also`) on rows
still named `E0415`. So the report and its gates run from phase A on, and C6b only
changes spellings.

### 1.7 Gates, known misses, and the script's own oracle

| gate | fails when | today | when it gates |
|---|---|---|---|
| `dead` | a live row has no raise site, or a retired row has one (§1.3) | 0 | from A3 |
| `unknown` | a raised spelling names no row, alias or group (§1.3) | 0 | from A3 |
| `untested` | a `rule`/`syntax` row has no fixture directive naming it by key or alias | 36 (§4.4) | from A3, with the 36 in xfail; D7 drains them |
| `unlisted` | an `unsup` row is named by no xfail reason whose path exists | 97 | from A3, with the 97 in xfail; A5 and the D-tasks drain them |
| `misuse` | a shared fixture's `//! reject*` names an `unsup`/`limit`/`lint`/`ice` row, i.e. the tool-neutral suite demands that every tool refuse legal code | 32 files, 14 codes | from A3; A5 drains it |
| `cite` | a fixture rejecting a `rule` row cites (`lrm`, `inherited`, `-reject` forms) no clause equal to, above or below the row's clause or `also`; syntax is exempt | 258 uses over 116 codes, plus E1100's 182 (one line `cite E1100 *`) | from A3; A6 triages; D2 and D3 drain |
| `nospec` | a `rule` row's clause has no `-` ledger sentence, or an `unsup` row's clause is not in the ledger or the heading list | 26 AMS clauses (e.g. 4.3, 5.8, which are `no-prohibition`; parents 4.5, 10); V2005 waits for A1b | from A3 for AMS; for V2005 after A1b |
| `wording` | a raise site whose string literal (the first literal within 6 lines of the token) matches `\byet\b`, `not implemented`, `not lowered`, `unsupported` or `cannot render`, on a row whose kind is not `unsup`/`limit`/`ice` | 33 (`.E0512` new side) + E0816 ×2 + E0819 ×1 | from A3; A4 drains it |
| `xpass` | an xfail line whose gap no longer exists | — | always |
| report-only | `unchecked`, `partial`, `positive-only`, `uncited`, `old-only` (not raised on the new side, until C4) | 146 + 92, 35, 228 + 382, 4 + 283, 256 | never |

- **Known misses.** Each is a line `<gate> <subject> # <reason>` in
  `tools/diag_gaps.xfail`, beside `tools/vera.xfail`. Names are compared, never counts
  (AGENTS.md). The A3 PR seeds the file from the first run.
- **Wiring.** In `build/runs.zig`, beside `conformance_selftest`, as two system commands
  added to `test_step` (the merge tier):
  - `python3 tools/diag_gaps.py check`
  - `python3 tools/diag_gaps.py selftest`

  Both use `PYTHONUTF8=1`, `expectExitCode(0)` and `has_side_effects = true`, since they
  read the fixture tree and source directories. One run reads about 4,300 fixture
  headers and the source tree in about a second.
  The `diag-coverage` step runs `report --tsv` with `addOutputFileArg` and
  `expectExitCode(0)`; it exits 1 when any gate fails.
- **The script's oracle: `selftest`.** It uses `unittest`, as `conformance.py selftest`
  does, and has two layers. Each expected value is written by hand; none is recomputed
  the way the script computes it.
  1. **A synthetic world in strings** with this content:
     - a 4-clause ledger: one `-` clause with a rule code and a fixture, one `-` clause
       with only an unsup code, one `-` clause with no code, and one `+`-only clause;
     - a 6-row catalogue: a dead code, an untested rule, a rule raised only through a
       `[KEY]` string in a `.zig.txt` file, an alias used by a fixture, a `misuse`
       fixture, and a `wording` site;
     - a `.zig.txt` line spelling `[E9998]`, which has no row (`unknown`);
     - one xfail line for a gap that is not a gap.

     The expected report is a literal: three verdict lines, the totals, and one line
     per gate, plus `xpass`.
  2. **A planted gap on the real tree, in memory.** The test adds:
     - the ledger row `99.99:1 … shall not … pol -`, which must appear as
       `unchecked 99.99`;
     - the catalogue row `planted_dead`, which must appear under `dead`;
     - and it removes one fixture's directive for `E0415`, after which `E0415` must
       appear under `untested`.

  - **Red-first:** with the `unchecked` branch deleted, layer 1 fails, and layer 2
    fails naming `99.99`.
- **G4 is the bug class this plan exists for**: a wrong clause, with no crash. The
  `cite` and `nospec` gates are its two independent oracles. `cite` checks against the
  fixtures' hand-written citations, and `nospec` checks against the ledger's sentences.

### 1.8 The script's data (six questions)

| table | in → out | how many | fields | access | lifetime |
|---|---|---|---|---|---|
| `ledger` | OBLIGATIONS*.tsv → `(std, clause, ordinal, pol, kind)` | 1643 AMS + about 1600 V2005 | strings | grouped by `(std, clause)` once | one run |
| `codes` | codes.zon → `(tag, key, kind, std, clause, also, aliases, severity)` | 511, at most 1024 | strings | dict by every spelling (key, alias) | one run |
| `raises` | src/lib scan → `spelling → [file:line]` | about 3k | | membership test | one run |
| `uses` | fixtures → `(file, directive, spelling)` | about 1,400 | | per code | one run |
| `cites` | fixtures → `(file, std, clause)` | about 9,000 | | per file | one run |
| `xfail` | two lists + `diag_gaps.xfail` | under 1,000 | | set of names | one run |

Every loop runs over a finite list. Parallelism is not needed: one run takes about 1 s.

## 2. What is there today

| fact | number | source |
|---|---|---|
| catalogue rows | 511 (482 live, 29 `(retired)`) | `codes.zon`, `lib/diag/codes/*.zig` (equal, diff-diag) |
| live rows with empty `lrm` | 19 | map `flag=lrm-empty` |
| rows whose `lrm` names the wrong clause | 24 (confirmed against the PDF's TOC and text) | map `flag=lrm-wrong` |
| fixture files whose `//!` directive names a code | 1332 | `tests/conformance/tests` |
| codes that fire on fixtures citing a *different* clause | 125 codes, 660 uses (258 once syntax and E1100 are set aside) | `cite` |
| E1100 "digital source execution failed" | 183 fixtures over 129 clauses; about 270 old raise sites (`lib/sim/digital/run_diag.zig:63`) and the new `src/Sema/digital.zig:163,261` | |
| new-side `.E0512` used as "not lowered by Sema yet" | 33 sites (`src/Sema/{string,syscall,kernel,reactive,expr,control,array,contrib,hier,discrete}.zig`) | `wording` |
| shared fixtures that demand refusal of a legal construct | 32 files over 14 codes, plus E1100's unsupported half | `misuse` |
| code-spelling readers | `tests/differential/settle.zig:185`, `comp/judge.zig:229,237`, `astgen.zig:246`, `stages.zig`, `diag.zig:479-514`, `tests/suite/Reject.zig:228-234` (`asCode`), `src/cli/args.zig:405`, `Diag/Levels.zig`, ESPice `build.zig:53-54,227,231` (`--allow=W0650/W0651/W0850/W0149`), `docs/examples/**/*.out`, `CHANGELOG.md` (34 mentions) | |

Three findings decide the design:

1. **A code is coarser than a rule.**
   - E0501 is pinned by 20 fixtures citing 10 clauses.
   - E1100 stands for 129 IEEE 1364 clauses.
   - So today a code cannot answer "do we check §4.4".
2. **Three kinds share one number space.**
   - E0512 is a rule, yet the new side raises it for an engine gap.
   - E0528 says it is "an implementation limit, not illegal AMS".
   - E1239 refuses a legal variable base.
3. **The shared, tool-neutral suite encodes VerA's gaps as prohibitions.**
   `timer_changed_effectful_input_rejected.va` says `//! reject E0528`.

## 3. The scheme

### 3.1 Grammar (one token, ASCII, shell-safe, case-sensitive)

```
key     := rule | syntax | unsup | limit | lint | ice | retired
rule    := std "-" clause sep letters          AMS-5.6.7.2b  V2005-9.9.1a  VERA-scratch-c
syntax  := std "-A-" letters                   AMS-A-a   (a generic parser error)
unsup   := "unsup-" (std "-" clause sep letters | slug)   unsup-AMS-5.10.3.3a  unsup-systemverilog
limit   := "limit-" slug                       limit-files
lint    := "lint-" slug                        lint-unproven-finite
ice     := "ice-" slug                         ice-codegen-call
retired := "E" d4 | "W" d4                     E0114 (never fires, --explain only)
std     := "AMS" | "V2005" | "VERA" | "OSDI" | "SPICE"
clause  := (digits | "A".."H") ("." digits)* | word   TOC/ledger numbering; a word ([a-z][a-z0-9_]*) only under VERA
sep     := "" when clause ends in a digit, "-" when it ends in a letter or is a word
letters := "a".."z" | "a".."z" "a".."z"        catalogue order within the clause; never reused
slug    := [a-z0-9]+ ("-" [a-z0-9]+)*
```

The script's single regex (R1):
`^(?:(unsup|limit|lint|ice)-)?(?:(AMS|V2005|VERA|OSDI|SPICE)-((?:\d+|[A-H])(?:\.\d+)*|[a-z][a-z0-9_]*)-?([a-z]{1,2}))?([a-z0-9-]*)$`
(checked on `AMS-5.6.7.2b`, `AMS-A-a`, `AMS-A.1.3a`, `VERA-limit_seed-a`, `unsup-osdi-reject-step`).
`OSDI` and `SPICE` are reserved and unused today.

### 3.2 Kinds

| kind | means | default severity | key | the report reads it as |
|---|---|---|---|---|
| rule | the source breaks a "shall" sentence of the cited clause | error; a warning only where the clause says "a warning shall be issued" (W1150, W1151, W1152, W1156, W1160, W1162, W1199, W0951) | `AMS-…`/`V2005-…`/`VERA-…` | checked |
| syntax | the text does not derive from the grammar annex | error | `AMS-A-a`…`f` (E0201, E0207-E0210, E0240) | checked (clause A); exempt from `cite` |
| unsup | the construct is legal and VerA refuses it, or accepts it and drops part of it | error / warning | `unsup-<std>-<clause>…` or `unsup-<slug>` | refused |
| limit | a fixed engine capacity | error | `limit-<slug>` | not a clause |
| lint | VerA's own advice on legal source | warning | `lint-<slug>` | not a clause |
| ice | a compiler defect (`E1020`) | error | `ice-<slug>` | not a clause |
| retired | kept so `--explain` and old scripts resolve | never emitted | the old spelling | must have no raise site |

### 3.3 The hard cases

| case | rule |
|---|---|
| several rules in one clause | one key each, lettered in catalogue order (`V2005-19.4a`…`f`) |
| one rule spanning clauses | the key cites the clause that holds the normative sentence; the others go in `also` (E0246 → `AMS-A.1.3a`, also `AMS-A.4.1`) |
| a later edition renumbers | `AMS` means 2023 forever; a later edition gets a new tag, and a row adds `also`. A key is rewritten only when its 2023 citation was wrong |
| the clause was wrong | the key changes, and the old key goes into `aliases` (rustc keeps renamed lints resolving) |
| one code is several rules (E1100, E0130, E0205, E0813, E0816, E0819, E1234) | split; the old spelling becomes a **group alias** (Verilator's `WIDTH` over `WIDTHTRUNC`/`WIDTHEXPAND`) |
| two codes are one rule (E1224/E0314, E1240/E0309, E1244/E0313, E1245/E0316, E1246/E0312, E1247/E0482, E0327/E0216, E0322/E0318, E0348/E0319) | one key; the other becomes its alias (D4) |
| VerA's own language (`vera_*` attributes, `$vera_reject_step`, the `$limit` seed) | `VERA-<feature>-<letter>`, citing `docs/using/attributes.md` and `docs/using/limit.md` |
| an explain that quotes a permission ("Implementations may issue an error", E0148) | `rule`, citing the clause that grants it |

### 3.4 Tags are not keys

The ZON field name and the Zig enum tag become a `snake_case` mnemonic of at most 48
characters. All 511 are generated in the map's `tag` column
(`branch_already_has_direct_contribution`, `unterminated_ifdef`, `unsup_rtlil_memory`,
`limit_files`). Source names a code by its tag:
`s.fail(.branch_already_has_direct_contribution, …)`.

Keys can be corrected without touching source, and a tag is one greppable token (R3). This
is aro's shape: `pub const expected_expr: Diagnostic = .{ .fmt, .kind, .opt }`
(`S/compiler/aro/aro/Parser/Diagnostic.zig:9-16,61`).

### 3.5 Aliases

- `aliases` is a per-row list of old spellings: the E/W number and any key retired by a
  correction.
- A group alias is a top-level `groups` entry (`.E1100 = .{ .digital_redeclared, … }`).
- One comptime `std.StaticStringMap(Lookup)` holds every key, alias and group name. The
  comptime check fails on a duplicate spelling.
- Aliases resolve everywhere a code is read:
  - `--explain`;
  - `--allow`/`--warn`/`--deny`/`--forbid` (a group sets every member);
  - the suite's `//! reject`/`//! warn`;
  - the JSON `alias` field.

### 3.6 Usage code first

```zig
// src/cli/args.zig: the one place a spelling from outside is parsed
const hit = Diag.lookup(name) orelse return refuse("unknown diagnostic code `{s}`", name);
switch (hit) {
    .one => |c| try levels.set(c, level),
    .group => |cs| for (cs) |c| try levels.set(c, level),
}

// --explain AMS-5.6.7   (a clause prefix: every key VerA has under it)
// --explain unsup-      (every refusal of a legal construct)
// --explain E0415       (prints "E0415 is now AMS-5.6.7.2b", then the entry)
for (std.enums.values(Diag.Code)) |c| if (Diag.keyHasPrefix(c, arg)) try Diag.explainLine(c, out);

// a stage, unchanged in shape
try s.fail(.branch_already_has_direct_contribution, file, src, "`{s}` already has a direct contribution", .{name});

// tests/suite/Reject.zig (switchover P6b): headline `error\[([^\]]+)\]`, then
const code = Diag.lookup(spelling) orelse return error.UnknownCode;
```

A prefix matches only on a clause boundary. `AMS-5.6` matches `AMS-5.6.7.2b` and
`AMS-5.6a`, and does not match `AMS-5.60a`.

### 3.7 Rendering

| element | today | after C6b |
|---|---|---|
| headline | `error[E0415]: branch already has a direct contribution` | `error[AMS-5.6.7.2b]: …` |
| clause note | `= note: LRM 5.6.7.2` (`render.zig:270-273`) | dropped when the key carries the clause; `= note: also <std> <clause>` for `also` |
| `--explain` head | `E0415 … LRM 5.6.7.2` (`render.zig:212-222`) | `AMS-5.6.7.2b (was E0415): <title>`, then `Verilog-AMS 2023 §5.6.7.2` |
| JSON | `"code":"E0415",…,"lrm":"5.6.7.2"` (`render.zig:175-176`) | `"code":"AMS-5.6.7.2b","kind":"rule","alias":"E0415","std":"AMS","clause":"5.6.7.2"` |

### 3.8 Against other compilers

| tool | identifier | kind visible | spec reference | rename/split | `--explain` |
|---|---|---|---|---|---|
| Zig | none: `ErrorBundle` rows are message + notes (`S/std/zig/ErrorBundle.zig:53,70`) | "TODO …" text only (`Z/src/Sema.zig:5651`, `Z/src/codegen/c.zig:3014`) | none | n/a | none |
| aro (in Zig's tree) | decl name (`Parser/Diagnostic.zig:61`) + `-W` group (`Diagnostics.zig:75`) | `kind`, `extension`, a `todo` diagnostic (`Parser/Diagnostic.zig:21`) | `suppress_version` ties a diagnostic to a C version | groups | none |
| rustc | `E0308`, sequential, never reused | errors vs lints | none | renamed lints keep resolving | `rustc --explain` |
| clang | internal `err_`/`warn_`/`ext_` ids; users see `-W` groups | id prefix | prose ("is a C99 extension") | group aliases in `DiagnosticGroups.td` | none |
| Verilator | named codes (`WIDTH`, `LATCH`), `%Error-UNSUPPORTED` | an `UNSUPPORTED` code | none | `WIDTH` kept as a group | a docs page per code |
| **VerA** | clause key + mnemonic tag | prefix (`unsup-`, `limit-`, `lint-`, `ice-`) | the key itself, joined to a sentence ledger | per-row and group aliases | key, alias or clause prefix |

None of these tools can produce a gap report, because none has a single normative document
with stable numbering for its whole input. VerA has two pinned editions, 9,038 fixture
`//! lrm` lines, and an AMS sentence ledger already classified by polarity. Joining codes
to that ledger is the cheapest machine check of "do we handle it".

Rejected: **a stable number plus a clause column**. That is today's `lrm` column, which
was wrong or empty on 43 of 482 live rows with no gate noticing. The `nospec` and `cite`
gates would catch those errors under either spelling (open question 1). The key is
preferred because it puts the clause in every log line and fixture a human reads.

### 3.9 Data: the catalogue after C6b

```zig
// lib/std/vams/Diag/codes.zon, one row (the field name is the tag)
.branch_already_has_direct_contribution = .{
    .key = "AMS-5.6.7.2b",
    .kind = .rule,
    .aliases = .{"E0415"},
    .title = "branch already has a direct contribution",
    .explain = \\...
    ,
},
// optional fields, read with @hasField: .severity = .warning, .also = "AMS-4.2.13", .cites = "AMS-4.2.4"
.groups = .{ .E1100 = .{ .digital_redeclared, ... } }, // phase D2
```

```zig
// lib/std/vams/Diag/code.zig (new public surface)
pub const Kind = enum(u3) { rule, syntax, unsup, limit, lint, ice, retired };
pub const Standard = enum(u3) { none, ams, v2005, vera, osdi, spice };
/// The identity half of a row; `info` keeps title and explain (cold, --explain only).
pub const Spec = struct {
    key: []const u8, also: []const u8, cites: []const u8,
    clause: []const u8, // sliced from `key` at comptime
    aliases: []const []const u8,
    kind: Kind, std: Standard, severity: Severity,
};
pub const Lookup = union(enum) { one: Code, group: []const Code };
pub fn spec(c: Code) Spec;
pub fn lookup(spelling: []const u8) ?Lookup;
pub fn keyHasPrefix(c: Code, prefix: []const u8) bool;
```

`severityOf` (`Diag.zig:227`) becomes `spec(c).severity`. The comptime `checkRow`
(`code.zig:71`) also asserts:

- the key matches its kind's grammar;
- the letter is the next free one for its clause;
- aliases and keys are disjoint;
- `lint` is a warning, and `limit`, `ice` and `syntax` are errors.

Clause existence is the script's `nospec` gate. The ledger is test data in the
submodule, and `lib/std` does not embed it.

| table | in → out | how many | widths | access | lifetime |
|---|---|---|---|---|---|
| `Spec` (`EnumArray(Code, Spec)`) | `codes.zon` → one row per code | 511; at most 1024 after D2 (`comptime assert(names.len < 1 << 10)`) | 5 slices + 3 × u3; `@sizeOf(Spec) <= 104`, asserted | one row per rendered diagnostic | comptime static |
| alias map | keys + aliases + groups → `Lookup` | about 1,040 | `StaticStringMap` | once per CLI flag | static |

## 4. The mapping

`research/diagcodes-map.tsv` has these columns:
`old key tag kind sev std clause also backend owner fixtures ex title lrm flag suspect dup note`.
`owner` is `tests/differential/stages.zig`'s stage.

### 4.1 Wrong clause, corrected (24)

| rows | was | is | evidence |
|---|---|---|---|
| E0101 E0104-E0108 | AMS 10.5 (Predefined macros) | V2005 19.4 | conditional compilation is IEEE 1364-2005 19.4; AMS 10.1 inherits the 1364 directives |
| E0121-E0126, E0144 | AMS 10.3 / 10.1 | V2005 19.5 | `include`; E0144's explain quotes 19.5 |
| E0128 | AMS 10.7 | V2005 19.7 | `line` |
| E0140 / E0141 / E0142 / E0236 | AMS 10.1 | V2005 19.2 / 19.9 / 19.8 / 19.6 | `default_nettype`, `unconnected_drive`, `timescale`, `resetall` |
| E0217 | AMS 3.2.1 | AMS 4.2.13 | concatenation width |
| E0509 | AMS 4.5.11 | AMS 4.2.14 | assignment patterns |
| E0511, E0510 | AMS 4.7.2 / 4.7.1 | AMS 4.7.3 | call and recursion rules |
| E0421 | AMS 4.7.2 | AMS 4.7.1 | "shall not use access functions" |
| W0852 | AMS 12.32.3 | AMS 2.8.3 | the permission quoted is 2.8.3 |

### 4.2 Empty clause (19)

- **An engine limit or a defect** (14): E0154, E0241, E1011, E1013-E1016, E1019-E1022,
  E1275-E1277.
- **Needs a clause or a slug** (5): E1200 → `unsup-AMS-7a`, E1202 → `unsup-AMS-5.2a`,
  E1219 → `unsup-V2005-3.6a`, E1104 → `unsup-systemverilog`, E1099 →
  `unsup-osdi-reject-step`.

### 4.3 Suspect (20, ruled in A6)

E0514, E0425, E0602, E0907, E0953, E0918, E0291, E0317, E0484, E0352, E0354, E0428,
E0207, W0250/W0252, W0251, W0253, W1153, E0826, E0827. The `suspect` column in the map
holds each one's candidate clause. A6 also rules on the 26 AMS code clauses that
`nospec` flags; 4.3 and 5.8 among them are marked `no-prohibition`.

### 4.4 Kind problems

| problem | rows | phase |
|---|---|---|
| engine refusals under rule codes | **E1100** (about 150 rule keys + some unsup), E0512's 33 new-side sites, E0816 (`src/Sema/dist.zig:112,207`), E0819 (`src/Sema/format.zig:103`), E0813 | A4, D2, D5 |
| two rules in one code | E0130, E0205, E1234 | D5 |
| duplicates | E1224, E1240, E1244, E1245, E1246, E1247, E0327, E0322, E0348 | D4 |
| misleading title | E0201, E0316, E0330 | D6 |
| conflict | E1272 (rtlil refuses) vs W1161 (engine warns) over V2005 12.2.2.1 | D6, open question 6 |
| `untested` rule keys | E0132 E0147 E0152 E0153 E0217 E0231 E0245 E0250 E0306 E0307 E0311 E0329 E0374 E0375 E0402 E0431 E0433 E0530 E0708 W1150 W1151 W1156 W1160 W1162 W1199 E1224 E1234 E1238 E1240 E1244 E1245 E1246 E1247 E1272 E0824 E0486 | D7 |

## 5. Migration

### 5.1 Order (agreed with plan-switchover: switchover.md §2, rows C6b and D1-D6)

| when | what | what an oracle sees |
|---|---|---|
| A (on `refactor`, before G0) | **A2 first**, because switchover P6b's `Reject.zig` needs `vams.Diag.lookup`. Then the columns `kind/std/clause/also/key/tag` in `codes.zon` (row names stay `E0415`), `lookup`, `tools/diag_gaps.py` + `tools/diag_gaps.xfail`, the IEEE ledger, the fixture flips, and E0575 | no rendered byte changes. diff-diag compares title, lrm, explain and rendered text, so it does not see the new columns. E0575 is the one row that exists only on the new side (A4) |
| C1-C6 | switchover.md; old oracles deleted at C1, old modules at C4 | at C4 the script's `NEW_ROOTS` and its `old-only` column are deleted |
| **C6b** | the flip: tags become ZON names, keys render, aliases resolve, `lrm` is removed, source is rewritten by tag, docs/examples are re-rendered, CHANGELOG. **Includes** the spelled strings in `src/codegen/exe/text/body.zig.txt:72,104`, `lib/kernels/hist_kernels.zig:119` and `lib/std/kernels/ops.zig:177` | g0 → g1 is checked by `tools/diagcodes_rewrite.py golden g0 g1`: g0 with the alias map applied must equal g1 byte for byte. `conformance` stays at 6818, because the fixtures' old numbers resolve as aliases. `diag_gaps.py check` is unchanged, because it reads keys and aliases alike |
| D (after C6b, before C7) | splits and merges, one commit each, each re-recording a golden, gated by `diagcodes_rewrite.py --expect-split <map>` | goldens; `diag_gaps.py`'s `cite`/`unchecked` lines shrink |

Why the flip waits for C6b:

- diff-comp compares stderr byte for byte (`comp/judge.zig:1-10`).
- diff-diag asserts equal catalogue lengths (`diag.zig:514`).
- `settle.zig:185` and `judge.zig:229,237` resolve old spellings.

Per plan-switchover, no oracle keeps an old side after C1, so no old→new map is ever
needed in an oracle.

Collision: switchover P11 may add `codes.zon` rows after A2. Each such row fills in A2's
columns, and the `nospec`/`dead` gates fail if it does not.

### 5.2 The shared suite (tool-neutral)

`conform` never matches the note (`tests/conformance/README.md`, "`//! reject <note>`"),
and only VerA's harness reads codes. Because aliases resolve forever, the suite moves at
its own pace:

1. **A5 (before G0), suite PR 1.**
   - The 32 `misuse` fixtures become positive tests, each with a `vera/xfail` and a
     `tools/vera.xfail` line whose reason names the code. That satisfies `unlisted`.
   - Where a ruling finds the construct really is prohibited, the code's kind becomes
     `rule` instead.
2. **D1 (after C6b), suite PR 2.**
   - `tools/diagcodes_rewrite.py fixtures` rewrites every
     `//! reject|reject-only|reject-run|warn` code to its key.
   - The README's "The note names the expected error, often as VerA's code" becomes
     "often as a clause key (`AMS-5.6.7.2b`); `vera --explain` resolves VerA's older
     numbers".
3. ESPice pins its own suite commit and its own VerA, so neither PR affects it.

### 5.3 Consumers outside the repo

| consumer | effect | action |
|---|---|---|
| ESPice `build.zig:53-54,227,231` `--allow=W0650/W0651/W0850/W0149` | keeps working (aliases) | at its next VerA bump, `--allow=lint-unproven-finite`, `lint-range-infinity`, `unsup-AMS-9.4a` and `lint-escape`; not forced |
| ESPice docs (W0850, W0852) | stale text | a release note |
| user scripts matching `error\[E\d{4}\]` | **break** | a CHANGELOG entry, the JSON `alias` field, and `--explain E0415` |
| `docs/examples/**/*.out` (`tools/doctest.py`) | re-rendered in C6b | the rewrite script's `docs` mode |

## 6. Policy

The new header text for `codes.zon`, replacing "A code is never renumbered or reused":

> A key names the clause of a pinned edition (`AMS` = Verilog-AMS 2023, `V2005` = IEEE
> 1364-2005, `VERA` = VerA's extensions) and the kind of the condition. A key is never
> reused for another condition. It changes only when its clause was wrong or its rule
> splits, and every spelling it ever had stays in `aliases` (a split's in `groups`),
> resolving wherever a code is read: `--explain`, `--allow`/`--warn`/`--deny`/`--forbid`,
> `//! reject`. A retired condition keeps its row (`kind = .retired`) and is never
> raised. A rule's letter is the next unused one for its clause.
> `tools/diag_gaps.py check` enforces the join to the specification ledgers.

The CHANGELOG line for C6b. Its numbers are re-measured by `diag_gaps.py report` at the
time.

> **Diagnostic codes name the clause they enforce** (`AMS-5.6.7.2b` for E0415,
> `unsup-AMS-5.10.3.3a` for a legal construct VerA refuses, `limit-…`, `lint-…`).
> `vera --explain AMS-5.6.7` lists what VerA checks under a clause, and
> `tools/diag_gaps.py report` lists the clauses it does not (AMS: N of 290 checked).
> Every old E/W number still works in `--explain`, `--allow` and the other level flags,
> and JSON carries it as `alias` (#issue).

## 7. Tasks

Each task is sized for one Sonnet agent. Tasks are file-disjoint unless marked "after".
Tasks that fix a wrong number come first: the wrong clauses (A2 carries §4.1) and the
misuse of E0512 (A4). Every gate command runs under `nix develop -c`, and every result is
gated on the command's own exit code (`cmd > log 2>&1; echo $?`).

| # | task | files | depends | gate commands | red-first fault | lists it may change |
|---|---|---|---|---|---|---|
| A2 | **first.** Add catalogue columns from the map (`kind`, `std`, `clause`, `also`, `key`, `tag`, `severity` where W). `code.zig` gains `Kind`, `Standard`, `Spec`, `spec`, `lookup` (keys + current E/W names), `keyHasPrefix`, and the §3.9 checks. No renderer change | `lib/std/vams/Diag/codes.zon`, `Diag/code.zig`, `Diag/tests.zig`, `Diag.zig` | — | `tools/build-slot.sh <wt> test-vams`; `tools/build-slot.sh <wt> diff-diag` (511 compared, same xfail); `tools/build-slot.sh <wt> check` | give E0415 the key `AMS-5.6.7.2a` (a duplicate) → compile error naming both rows | none |
| A1 | the `ledger` subcommand of `tools/diag_gaps.py` (`--update`, `--show`, sha256 from `conformance.py`); `poppler_utils` in `flake.nix`'s `external` shell; generate `vera/ledger/OBLIGATIONS-1364.tsv` (no text; `pol` seeded `-` by the prohibition regex, else `?`); re-run AMS `--update` and expect zero changed rows | `tools/diag_gaps.py` (ledger part), `flake.nix`, `tests/conformance/vera/ledger/OBLIGATIONS-1364.tsv` (suite patch), the OBLIGATIONS.tsv header line | — | `nix develop .#external -c python3 tools/diag_gaps.py ledger --update --std AMS` leaves OBLIGATIONS.tsv byte-identical; `nix flake check` | edit one AMS sentence's hash → `--update` resets that row to `?` | none |
| A1b | classify IEEE `pol` row by row (a reader with the local PDF, `ledger --show`); data only | `OBLIGATIONS-1364.tsv` | A1 | `diag_gaps.py report` (the V2005 header drops PROVISIONAL once no `?` is left) | — | none |
| A3 | `report`, `check` and `selftest` (§1.3-§1.7); `tools/diag_gaps.xfail` seeded from the first run; the `build/runs.zig` wiring and the `diag-coverage` step; a TESTING.md row in the merge tier | `tools/diag_gaps.py` (after A1: same file, sequential), `tools/diag_gaps.xfail`, `build/runs.zig`, `TESTING.md` | A1, A2 | `python3 tools/diag_gaps.py selftest`; `python3 tools/diag_gaps.py check`; `tools/build-slot.sh <wt> test` | (1) delete the `unchecked` branch → selftest fails naming `99.99`; (2) drop the `bag.add` form from the raise scan → selftest names `E1099` dead; (3) in a scratch copy, give E0415 the clause `5.6.7.1` → `cite` names its fixtures; (4) a seeded xfail line that passes → `xpass` | `tools/diag_gaps.xfail` (new) |
| A4 | add the row `E0575` "a construct the rewrite does not lower yet" (kind unsup; aro's `todo`, `Parser/Diagnostic.zig:21`) and replace the 33 `.E0512` sites; `diag.zig:514` gains a named `new_only = .{"E0575"}` | `codes.zon`, `src/Sema/{string,syscall,kernel,reactive,expr,control,array,contrib,hier,discrete}.zig`, `tests/differential/diag.zig` | A3; land between plan-lower's and plan-dlower's commits on the same Sema files | `test-sema`, `diff-diag`, `diff-lower`, `diag_gaps.py check` (the `wording` lines for E0512 go away) | revert one site to `.E0512` → `wording` names `src/Sema/expr.zig:179` | `tools/diag_gaps.xfail`; report `lower.xfail`/`elab.xfail` text quoting E0512 to its owner; never `comp.xfail` |
| A5 | the `misuse` flips. Each fixture gets a ruling (clause + sentence), then either becomes positive with xfail lines naming the code, or the code's kind is corrected. Delivered as a suite patch for the lead | `tests/conformance/tests/**` (32 files), `vera/xfail`, `tools/vera.xfail`, `codes.zon` kind fixes | A3 | `suite -- ams`, `suite -- ieee1364`, `conformance` (XFAIL, no FAIL), `diag_gaps.py check` | before the flip, `check` lists each file under `misuse` | `tools/diag_gaps.xfail` |
| A6 | rule on the 20 suspects and the 26 `nospec` AMS clauses; triage the 258 `cite` uses into split / fixture citation wrong / clause wrong. Data only | `research/diagcodes-map.tsv`, `tools/diag_gaps.xfail` reasons | A3 | `diag_gaps.py check` | — | `tools/diag_gaps.xfail` |
| C6b-1 | the flip: `codes.zon` keyed by tag with `key`/`aliases`, `lrm` removed; `Levels` + `args.zig` through `lookup`; `--explain` prefix + alias notice; render as in §3.7; `tools/diagcodes_rewrite.py` (modes `src`, `golden`, `fixtures`, `docs`); §6 header | `lib/std/vams/Diag/**`, `src/cli/args.zig`, `tools/diagcodes_rewrite.py`, `CHANGELOG.md` | switchover C1-C6 | `zig build test`, `golden -Dgolden-record=g1`, then `python3 tools/diagcodes_rewrite.py golden g0 g1`; `conformance` 6818; `diag_gaps.py check` unchanged | one wrong map entry → `golden` mode names the file | none |
| C6b-2 | `diagcodes_rewrite.py src` over `src/`, `lib/` (the `.zig.txt` templates and the spelled `[CODE]` strings too) and `tests/`; `docs` over `docs/**` | mechanical, same PR | C6b-1 | `zig build test`, `python3 tools/doctest.py`, `diag_gaps.py check` (`dead` still 0) | leave `body.zig.txt` unrewritten → `dead` names its code | none |
| D1 | suite PR 2 (§5.2) | `tests/conformance/tests/**`, suite README | C6b | `suite`, `conformance`, `diag_gaps.py check` | — | — |
| D2a-e | the E1100 split, one sub-task per `src/Sema/digital/` subtree. Each site gets a key from its fixtures' `//! inherited` clause; `groups.E1100` lists them | `src/Sema/digital/**` (split by file), `codes.zon` (append-only; D2a owns the block) | C6b | `suite -- ieee1364`, golden + `--expect-split E1100`, `diag_gaps.py report` (V2005 checked rises; the `cite E1100 *` line shrinks) | a key one clause off → `cite` names the fixture | `tools/diag_gaps.xfail` |
| D3 | the `cite` split queue from A6 (E0501, E0214, E0314, E0907, E0906, E0246, E0115, E0352, …) | `src/Sema/*.zig` by code, `codes.zon` | A6, C6b | as D2 | as D2 | `tools/diag_gaps.xfail` |
| D4 | merge the 9 duplicates (the dropped spelling → `aliases`) | `codes.zon`, raise sites, `src/codegen/rtlil.zig` | C6b | golden `--expect-split`, `rtlil-equiv`, `diag_gaps.py check` (`dead` 0) | — | — |
| D5 | split E0130, E0205, E0813, E0816, E0819, E1234; retire E0575 once it has zero sites | as in §4.4 | C6b | as D2 | — | — |
| D6 | retitle E0201, E0316, E0330; turn E1020 into an `assert` (row retired); rule on E1272 vs W1161 | `codes.zon`, the E1020 site | C6b | `zig build test`, golden `--expect-split`, `diag_gaps.py check` (`dead` also fails a retired row that still has a raise site) | — | — |
| D7 | the 36 `untested` rule keys: one `_rejected` fixture each, with a legal neighbour, in a suite PR | `tests/conformance/tests/**` | C6b | `suite`, `diag_gaps.py check` | each new fixture written first with a wrong key → `cite` fails | `tools/diag_gaps.xfail` |

Parallel lanes: A2 ‖ A1 (A1b follows A1). A3 waits for both, and A4, A5 and A6 run in
parallel after A3.

Expected movement, as measured by `diag_gaps.py report` (names are gated, never counts):

| gate | today | after |
|---|---|---|
| `misuse` | 32 | 0 after A5 |
| `wording` | 36 | 0 after A4 and D5 |
| `cite` | 258 + E1100 | A6's residue, then 0 after D2 and D3 |
| `untested` | 36 | 0 after D7 |
| `unlisted` | 97 | 14 cleared by A5; the rest (mostly the 79 rtlil rows) get one xfailed positive fixture each under `vera/rtlil` |
| V2005 checked | 10 of 114 | up to 36 after D2 (the 26 clauses E1100 hides) |

## 8. Departures from Zig

| where | Zig | here | why |
|---|---|---|---|
| codes at all | none: `ErrorBundle` has no code column (`S/std/zig/ErrorBundle.zig:70`) | a coded catalogue keyed by clause | AGENTS ("coded diagnostics"); aro, which Zig ships, has named diagnostics (`S/compiler/aro/aro/Parser/Diagnostic.zig:61`) |
| a spec-derived tool | Zig derives tables from external specs with Zig programs in `tools/` (`Z/tools/gen_spirv_spec.zig`, `Z/tools/update_cpu_features.zig`) and commits the output | Python in `tools/`, and only the ledgers are committed (in the submodule); the report is generated | AGENTS.md's layout puts scripts in `tools/` as Python (`conformance.py`, `report.py`); the lead asked for Python; the report reads text, not Zig ASTs |
| the stage contract | stages append rows; spelling is the renderer's (`S/std/zig/ErrorBundle.zig:356`) | unchanged | spelling resolves only at render and at the CLI edge |

## 9. Risks

| risk | mitigation |
|---|---|
| a clause attribution is wrong, so a key is wrong | `cite` + `nospec` (two independent oracles), and an alias on every correction; A6 rules before C6b |
| the IEEE ledger is unreviewed, so V2005 verdicts mislead | the report header says PROVISIONAL until no `?` row is left (A1b); `nospec` does not gate V2005 until then |
| the raise scan misses a new emission form (as it missed `bag.add` and `[CODE]` strings) | the selftest plants each form; a new form starts as a false `dead`, which fails loudly, never silently |
| a tag collides with an ordinary identifier, making a dead code look live | the script fails on any tag declared elsewhere in `src/`/`lib/` |
| C6b collides with other switch-over goldens | the C6b golden check is a byte transform, so any other change shows as a mismatch |
| E1100's split is large (about 270 sites) | it runs after C6b, in five file-disjoint sub-tasks |
| user scripts matching `E\d{4}` break | CHANGELOG, JSON `alias`, permanent input aliases |

## 10. Open questions

1. **The spelling.** I recommend clause keys + kind prefixes + mnemonic tags + permanent
   aliases. The alternative keeps the E/W numbers and adds the A2 columns. The gap report
   and every gate work the same under both, because the script joins on the columns. Only
   the key, though, shows the clause in logs, fixtures and `--allow`.
   Decision: Clause keys, kind prefixes, mnemonic tags, old numbers as permanent aliases.
2. **When.** I recommend the additive phase A (and the gap report) before G0, the flip at
   C6b, and the splits after it.
   Decision: Phase A and the gap report before G0; the flip at C6b; splits after.
3. **A legacy output switch** (`--diag-codes=legacy`). I recommend no: input aliases and
   the JSON `alias` field cover scripts.
   Decision: No: input aliases and the JSON `alias` field cover scripts.
4. **E0575 before G0** (one new-side-only code for "not lowered yet"). I recommend yes: it
   makes the rewrite's remaining refusals show as `unsup` in the report, not as fake rule
   coverage.
   Decision: Yes, before G0.
5. **Fixture flips in the shared suite (A5).** I recommend positive tests + VerA xfail
   lines, so the suite stops demanding that other tools refuse legal AMS.
   Decision: Positive tests plus VerA xfail lines, on the same submodule branch as lower Q7; pushed with the user's approval.
6. **E1272 vs W1161** (too many ordered parameter overrides). I recommend that IEEE
   1364-2005 12.2.2.1 decides once, for both paths, read in A6.
   Decision: Yes: IEEE 1364-2005 §12.2.2.1 decides once, for both paths, in A6.
7. **`AMS` tag spelling** (`AMS` vs `VAMS23`). I recommend `AMS`, fixed to 2023 by the
   policy text.
   Decision: `AMS`, fixed to 2023 by the policy text.
8. **Syntax codes.** I recommend one generic `AMS-A-*` family that is exempt from `cite`.
   Decision: One generic `AMS-A-*` family, exempt from `cite`.
9. **IEEE ledger text.** I recommend committing hashes, modals and classifications
   without the sentence text, which `ledger --show` prints from the local PDF. That
   follows CLAUSES.tsv's licensing rule. The alternative commits the text: classifying is
   easier, but it publishes licensed text in the submodule.
   Decision: Hashes, modals and classifications only; no licensed text in the submodule.
10. **Which gaps gate.** I recommend gating `dead`, `untested`, `unlisted`, `misuse`,
    `cite`, `nospec` and `wording` with named xfail lines. `unchecked` and `partial`
    stay report-only, since there is no ratchet on clause counts. The alternative also
    gates `unchecked` through xfail lines (one per clause, 238 today), which would force
    every newly checked clause to delete its line.
    Decision: Gate `dead`, `untested`, `unlisted`, `misuse`, `cite`, `nospec`, `wording` with named xfail lines. `unchecked` and `partial` are report-only.
11. **Granularity.** I recommend clause-level verdicts, plus the `partial` heuristic
    (35 AMS clauses have fewer codes than prohibitions). The alternative is an optional
    `obligation = "5.6.7.2:3"` column per row, for sentence-level verdicts. I recommend
    adding it only if `partial` hides real gaps after A6.
    Decision: Clause level plus `partial`; the `obligation` column only if `partial` hides real gaps after A6.
