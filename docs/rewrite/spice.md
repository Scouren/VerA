# vams: the SPICE netlist reader

Read `README.md` first. You own `lib/std/vams/spice.zig` (+ `lib/std/vams/spice/`),
its line in `lib/std/vams.zig`, `tests/differential/spice.zig`,
`tests/differential/spice.xfail`, and the `diff-spice` row you add to
`build/rewrite.zig`.

## What it is

VAMS annex E.2: a SPICE netlist's `.MODEL` and `.SUBCKT` cards in, Verilog-AMS
module text out (the old `lib/frontend/spice_cards.zig` + `lib/frontend/spice/*.zig`,
2,636 lines; target about 2,440), so a source can instantiate them. Keep the text
round trip (it is cheap and easy to test: `lib/TODO.md` map 1 finding 19). Two
changes from the old code:

- **No I/O, by request**, exactly as the merged `vams.Preprocessor` does it: when a
  `.INCLUDE` or `.LIB` card names a file, `run` returns a request with one
  candidate path and the caller answers with bytes or null
  (`lib/std/vams/Preprocessor.zig` is the model to copy; read its API and header).
  `.HDL` names are returned in the output for the caller to add as units.
- **Diagnostics** go to a `vams.Diag.Wip` (merged), with the old codes (E0928,
  E0953, ...).

## The oracle: `zig build diff-spice`

For every netlist the fixtures use (`tests/conformance/tests/spice/**`,
`tests/conformance/tests/netlist/**`, and each fixture's `//! spice` cards or
`--spice` file), and for the generated card-shaped inputs the old
`spice_cards.zig` fuzz test uses: the old `spice_cards.synthesize` (with a
`frontend.Files` on `std.testing.io`) and the new reader (answering its requests
from disk) give byte-equal module text, the same module count, the same refusal
messages and codes in order, and the same `.HDL` list. Port the old module's tests
(`lib/frontend/spice_cards.zig`, `lib/frontend/spice/*.zig` test blocks) as spec
examples.

## Done when

`zig build test-vams`, `diff-spice`, `check`, `test-unit` pass; the report names
netlists compared and every `spice.xfail` line.
