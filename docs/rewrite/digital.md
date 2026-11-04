# digital: the `.v` backends (device, executable, RTLIL)

Read `README.md` first, then `comp.md` and `exe.md` (the driver and the
analog testbench these sit beside), `sim.md` and `dlower.md` (the
`std_sim.Program` these take as input), `lib/TODO.md` §3, §8, §11, §12, and
Appendix A.6's `src/codegen/digital` rows.

## What you own

| Piece | Path |
|---|---|
| The executable and device backends | `src/codegen/digital_next.zig` + `src/codegen/digital_next/` |
| The RTLIL backend | `src/codegen/rtlil.zig` |
| Dispatch | the `.digital_device`, `.digital_exe` and `.rtlil` prongs in `src/next/Compilation/backend.zig`, edited additively |

The old `src/codegen/digital/` stays read-only until the switch-over, which
renames `digital_next` to `digital`.

## What it is

Every backend reads the `std_sim.Program` that Sema's digital lowering writes,
and nothing else: no AST, no re-preprocessing, no re-parsing, and no folder of
its own. Under A.6's map, `rtlil_fold.zig`, `rtlil_table.zig` and
`plane_words.zig` have no counterpart.

1. **`.digital_exe`** (`.v --emit-exe`, `--run` builds) works in two steps:
   - **Step 1 (correctness):** the executable embeds the Program, serialized
     with `std_sim.serial` as rw-zero did for §8 mixed, and runs it through
     `std_sim`'s interpreter. This makes every `.v` fixture runnable and
     comparable.
   - **Step 2 (speed):** a native codegen from `Program` to Zig, A.6's
     `Function`. It is held against step 1's interpreter as its oracle:
     byte-equal transcripts on every `.v` fixture. AGENTS.md says a speed
     claim cites a benchmark, so measure native against interpreted. The
     native form ships only when it measurably wins; otherwise step 1 is the
     product, and you report the numbers.
2. **`.digital_device`** (`.v --emit-zig`/`--check`/`--emit-so`) makes a `.v`
   top a contract device, as the old `device.zig` does. Built through `link`.
3. **`.rtlil`** (`--emit-rtlil`) is Yosys RTLIL text over `Program`'s instances,
   processes and expressions.

## The oracle

`zig build diff-comp`: the `comp.xfail` lines reading "not built: backend
digital_device" (88), plus every `--emit-rtlil` and `.v --emit-exe` fixture,
must agree with old `vera`. Run a chapter at a time with `-Dcomp-filter=`.
- For RTLIL, also run the suite's own rtlil mode (`tests/rtlil/`); it is the
  switch-over's gate.
- Plant a fault (e.g. drop a process) and show it red first.
- `comp.xfail` belongs to the lead: never commit it. Report which lines your
  work should clear.

## Done when

- No `comp.xfail` line names these backends.
- The README gate set and `diff-comp` pass.
- Report:
  - fixtures moved from listed to agreeing;
  - the step 2 benchmark and its verdict;
  - line counts against A.6's targets.
