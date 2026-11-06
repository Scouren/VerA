# Compilation: the spine, the driver, and `vera-next`

Read `README.md` first, then `lib/TODO.md` §3 (the stage contract, §3.1-§3.3),
§7 (linking), §10 (migration order), §11, §12, and Appendix A.2 (`src/elab`,
`Compilation`, `main`, `cli`, `dynlib`, `build`). Read Zig's `src/Compilation.zig`
(`create`, `update`, `performAllTheWork`, `getAllErrorsAlloc`), `src/Zcu/PerThread.zig`
(`updateFile`, `workerUpdateFile`) and `src/main.zig` (`buildOutputType`, the
`-j` thread limit, the big worker stack) in the Zig checkout `README.md` names.

You own the new spine, `src/next/Compilation.zig` + `src/next/Compilation/`, and
the new driver, `src/next/main.zig` + `src/next/cli/`. Together they build a
second executable, `vera-next`. You also own `tests/differential/comp.zig`,
`tests/differential/comp.xfail`, and the `diff-comp` and `conformance-next` rows
in `build/rewrite.zig`. The old `src/main.zig`, `src/Compilation.zig` and
`src/cli/` stay the product, read-only, until the switch-over. At the
switch-over, `src/next/*` moves over them and `vera-next` becomes `vera`.

## What it is

Zig's `Compilation` for VerA: the one place that reads files, owns threads,
divides work into units, and decides how many units run at once. Every stage is a
pure function over one fixed input with one fixed output (§3's table). The
stages already exist as merged modules:

| Stage | Module |
|---|---|
| Preprocessor | `vams` (`run`/`answer` include requests) |
| Parse, AstGen → `Vir` | `vams` |
| SPICE netlist | `vams.spice` (`Netlist.answer`) |
| Sema elaboration → `Zcu` | `sema` |
| Analog lowering → `Air` + `Air.Device` | `sema` (`zcu.data_want` / `answerData` for `$table_model` data) |
| Digital lowering → `std_sim.Program` | `sema` |
| Air passes → `Facts` + `Float.Verdict` | `air` |
| Zig device backend | `codegen` |
| Building libraries | `link` |
| Digital runtime | `std_sim` |

You write no stage. You write:

- **`Compilation`**: `create(gpa, io, config)`, `update()`, `getAllErrors()`.
  - A `Job` queue as in §3.2.
  - Preprocessing runs serially in command-line order (§3.1).
  - AstGen runs per file in parallel. Its cache key is hash(pp text) plus the
    digest of the macro state the file started with.
  - Sema runs per `Instance.Key`. Codegen runs per backend × artifact. Link
    tasks run through `link`'s queue.
  - `Config.thread_limit` (`-j`) sizes every `Io.Group`. Workers get one big
    stack plus the depth cap (§11.2).
  - Answer every request the stages raise from one read loop: includes, `.hdl`,
    SPICE `.INCLUDE`/`.LIB`, `$table_model` data, libmaps. No stage reads a
    file.
  - Errors come from `Zcu`'s failures and each stage's `Diag`, merged into one
    bundle in a fixed order.
- **`main` + `cli`**: the `vera` command line, every flag the old `src/cli/` accepts,
  parsed into `Config`. Output and printing belong to `main`.
- **The LSP entry**: the old one calls `vera.analyze`. The new one calls
  `Compilation.update` up to Sema and reads the diagnostics.
- **`--check` with its own scratch per invocation** (`lib/TODO.md` §12, ESPice's
  race):
  - `link.check` takes `f.work_dir` from its caller. Give it a directory
    unique to this invocation: under the `-o` output's directory, or a
    random-suffix temporary name. Remove it afterwards.
  - Never a fixed path under the cwd, and never only cache-relative, because
    the caches are shared on purpose.
  - Test: one model, one cwd, N ≥ 8 concurrent `vera-next --emit-zig --check`
    runs; all must succeed. It must go red against a fixed path first.

Backends that don't exist yet (`exe` testbench, `verilog`, `osdi`, digital native and
`.v` executable, `rtlil`, VPI) are other agents' work. The dispatch has a
prong for each. Until a backend lands, its prong returns a coded "not built"
error, and the fixtures that need it are `comp.xfail` lines. Those lines are
debt that the backend agents pay off, not results.

## The oracle

1. **`zig build diff-comp`** runs every fixture in the corpus with the command
   line its harness uses: the `//!` headers the old `suite`/conformance runner
   reads. Read `tests/suite/*.zig` and the conformance `conform` harness to find
   it. Run `vera` and `vera-next`, and compare:
   - the exit code;
   - the full diagnostic stream, byte for byte (codes, locations, text, order);
   - stdout;
   - every emitted text file;
   - for an emitted device, behaviour, by reusing `tests/differential/codegen.zig`'s
     comparison (the residual/Jacobian rows from the `.so`). Device text differs by
     design (§11.9, §11.10);
   - for a digital run, the transcript.

   A disagreement where the old side is wrong is settled by a tiebreaker as
   README rule 3 says: an `//! lrm` ruling in `tests/differential/comp.rulings`.
   It is never settled by a line.
2. **`zig build conformance-next`**: the conformance suite's own harness with
   `vera-next` as the tool, against `tools/vera.xfail`, which is empty: 6818/6818.
   This is the switch-over gate.
3. **Determinism:** `-j1` and `-jN` write the same bytes for every fixture's
   outputs and diagnostics. Run `diff-comp` with `-jN` and spot-check 200
   fixtures at `-j1`.

## Done when

- `comp.xfail` is empty, or holds only lines for backends that are not merged
  yet, each line naming its backend.
- `zig build check`, `test-unit`, `diff-comp` and `conformance-next` pass, as far
  as the merged backends reach.
- The concurrent `--check` test passes.
- Report:
  - the fixtures compared and agreed, and every ruling;
  - the lines left, by backend;
  - the line count against A.2's target;
  - build time per fixture, old vs new.
