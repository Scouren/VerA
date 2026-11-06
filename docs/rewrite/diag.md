# vams: Diag

Read `README.md` first. You own `lib/std/vams/Diag.zig` (+ `Diag/`, including
`Diag/codes.zon`), its line in `lib/std/vams.zig`, `tests/differential/diag.zig`
and `tests/differential/diag.xfail`, and the `diff-diag` row you add to
`build/rewrite.zig`.

## What it is

The diagnostics every new stage reports into and every front end renders: Zig's
`std.zig.ErrorBundle` layout (`string_bytes` + `extra: []u32` + a `Wip` builder;
S/ErrorBundle.zig:17-19, 70, 178, 356) with the columns VerA needs that it lacks:
a `Code` (E/W number), a severity, `allow/warn/deny/forbid` levels per code
(aro/Diagnostics.zig:359 `set`), labels, notes and fix-its, and a JSON renderer.
It replaces `lib/diag/` (2,267 lines of code, target about 1,290: `lib/TODO.md`
Appendix A.1) without the file table and macro source map the old `Bag` carries
(those become `Zcu.File` and `Preprocessor` output).

- The catalogue: the 22 `lib/diag/codes/class*.zig` files (482 rows, 40 retired;
  5,177 lines of `--explain` prose) become one `Diag/codes.zon`; `Code` is reified
  at comptime from its keys (deleting the duplicate `names` list,
  `lib/diag/code.zig:67-181`), and a build fails on a missing or duplicate row.
- A location is `{ file: u32, start: u32, end: u32 }`; rendering takes a table the
  caller passes in (file names, texts and line starts), so `Diag`
  imports nothing but std.

## The oracle: `zig build diff-diag`

Build the same diagnostics both ways (the old `diag.Bag` + `builder` and the new
`Diag.Wip`) from a corpus: every code in the catalogue with a message, a label, a
note and a fix-it, at every severity and level, plus the diagnostics the old
compiler emits on the conformance fixtures' `//! error`/`//! warning` lines
(run the old `vera.analyze` and copy each row into the new bundle). The rendered
text (both colour modes) and the JSON are byte-equal; `--explain <code>` text is
byte-equal for every code.

## Done when

`zig build test-vams`, `zig build diff-diag`, `zig build check` pass; the report
names the rows compared and every `diag.xfail` line.
