# vams: Preprocessor

Read `README.md` first. You own `lib/std/vams/Preprocessor.zig` (+
`Preprocessor/`), the prelude files `lib/std/vams/{constants,disciplines}.vams`
(+ any other annex text you move out of Zig strings),
`tests/differential/preprocess.zig` and `tests/differential/preprocess.xfail`.
Leave the tokenizer, Ast and Parse names in `lib/std/vams.zig` alone (another
agent's); you may edit the `Preprocessor` line and the `test` block.

## What it is

IEEE 1364-2005 §19 and VAMS-2023 §10 (plus annexes D and E's built-in text and
§28 `protect` envelopes) over an ordered list of source units, with **no I/O**:
the preprocessor never opens a file. When it needs one (an `` `include ``, a
netlist's `.HDL`), it stops and returns a **request**; the caller (later,
`Compilation`) reads the bytes and answers. This is AGENTS.md's "requests
instead of callbacks", and it is why `Compilation` can own every read, cache
and parallelism decision.

```zig
var pp: Preprocessor = try .init(gpa, .{ .defines = &.{"X=1"}, .std_defs = true, ... });
defer pp.deinit();
try pp.addUnit("top.va", top_text);           // the units, command-line order (IEEE 1364 §13.4.1)
while (try pp.run()) |req| switch (req) {     // runs until done or it needs a file
    .file => |want| pp.answer(read(want.path)), // bytes, or null for "not there": the next candidate is asked
};
const out = pp.output();                      // text, source map, directive events, diagnostics
```

The **search order** is the preprocessor's (it is language: IEEE 1364 §19.5, VD-091):
an absolute path as written; then the includer's directory; then each include
dir in order; then the built-in annex files. It asks for one candidate path at a
time; `null` moves it to the next; the built-ins never cost a request.

## Data

Copy the old preprocessor's behaviour (`lib/frontend/preprocessor.zig`,
`lib/frontend/pp/*.zig`, 4.97k lines; target about 3k) but its data in Zig's
style: a macro table keyed by name, the conditional stack, the include stack as
arrays of rows with `u32` handles; the output text one `ArrayList(u8)`; the
source map as rows `{ out_offset, file, file_offset }`; directive events as one
table per kind (`` `timescale``, `` `default_discipline``, `` `default_nettype``,
`` `celldefine``, `` `unconnected_drive``, `` `default_transition``, ...:
`lib/frontend/pp/events.zig`). Diagnostics are your own rows
`{ code: []const u8 ("E0126"), file: u32, start: u32, end: u32, message }` until
the `Diag` module exists; use the old codes (`lib/diag/codes/`) so the oracle can
compare them. The annex D/E text moves from Zig strings (`pp/annex_d.zig`,
`pp/annex_e.zig`, `pp/prelude.zig`) into `.vams` files beside the module, read by
`@embedFile`. SPICE netlist synthesis (`spice_cards`) is out of scope: a netlist's
synthesized module text arrives as one more unit.

## The oracle: `zig build diff-pp`

`tests/differential/preprocess.zig` (wired already; imports `vams`, the old
`frontend` and `diag`, and `rewrite_options.fixture_root`). For every `.va`,
`.vams` and `.v` under the fixture root, sorted, under the settings the old
compiler uses (`std_defs` and `spice_primitives` for `.va`/`.vams`, neither for
`.v`; the fixture's directory as the include dir; `require_std_includes = true`
as `vera` sets it):

1. Run the old `frontend.preprocessor.process` with a `frontend.Files` on
   `std.testing.io`; run the new one, answering its requests from disk.
2. The output text is **byte-equal**, the list of diagnostic codes is equal in
   order, and each directive event table is equal.

Print each mismatch (fixture, first differing byte or event, old vs new) and fail;
`preprocess.xfail` lists the allowed ones by fixture path with a reason. Port
`tests/unit/preprocessor_tests.zig` (1.9k lines of spec examples) to the new API.

## Done when

`zig build test-vams`, `zig build diff-pp` and `zig build check` pass; `diff-pp`
reports how many fixtures it compared and how many `preprocess.xfail` lists (each
with a reason); `tools/check_style.py` is clean on your files.
