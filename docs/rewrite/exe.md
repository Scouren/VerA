# exe: the analog testbench backend (`--run`, `--emit-exe`)

Read `README.md` first, then `comp.md` (the driver this backend plugs into),
`codegen.md` (the device backend whose output the runner drives), `lib/TODO.md`
§3, §7, §11, §12, and Appendix A.4 (the `src/codegen/exe` rows) and A.7 (the
`lib/sim/rt`, `mixed`, `scheduler` and `time` rows: the runtime of emitted
executables).

## What you own

| Piece | Path |
|---|---|
| The backend | `src/codegen/bench.zig` + `src/codegen/bench/` |
| Runtime the runners import | `lib/std/sim/` additions |
| Its unit tests | `test-codegen`, or a new `test-bench` |
| The prong in `vera-next`'s backend dispatch | `src/next/Compilation/backend.zig` (additive) |

The old `src/codegen/exe/` stays read-only until the switch-over, which renames
`bench` to `exe`. Any runtime piece the runners need moves from `lib/sim/rt`,
`lib/sim/mixed` or `lib/sim/scheduler` into `lib/std/sim/` as A.7 maps it, with
its own differential check.

## What it is

The old pipeline turns a fixture's `//!` testbench directives (`Spec`: sweeps,
cards, points, the checks on tables, noise, AC, limit and held state, the §8
mixed-signal bench, the Clause 12 VPI host lib) plus the device into a runner
Zig program. It builds that program with the device and runs it. The runner
prints the transcript the fixture's harness compares.

The new backend does the same from the new pipeline's data only:
- the directives, parsed once into `Spec`, from the file's source or from the
  `Vir`/`Directives` the front end keeps;
- `Air.Device` and `Air.Float.Verdict` (`Facts`);
- for §8 mixed-signal, the `std_sim.Program` that Sema's digital lowering writes.
  The old runner re-elaborates digital source at run time (A.4 finding F12). The
  new one gets the `Program` at compile time.

It reads no AST, no old `Lowered` and no old module. The emitted runner
imports only `contract`, `std_kernels`, `std_sim` and the device. There is no
`frontend`, `base`, `diag`, old `kernels` or old `sim`; check this by the
runner's import list in a test. It is built through `link`, which owns the
per-invocation scratch directory and the job limit.

## The oracle

`zig build diff-comp` already runs every fixture's harness command line through
`vera` and `vera-next`. The 1744 analog `--run` fixtures are now `comp.xfail`
lines owned by "exe backend", and vera-next exits 126 on them. Your work turns
them into agreements: the same exit code, a byte-equal stdout transcript, the
same diagnostics, and the same written files.
- Value differences that the f128 or ulp rules settle elsewhere: use the
  three-way tiebreaker (README rule 3), never a line.
- Run a chapter at a time with `-Dcomp-filter=<path part>`.
- Plant a fault in the runner (e.g. drop the last sweep point) and show it red
  before trusting green.

## Done when

- No `comp.xfail` line names the exe backend.
- `zig build check`, `test-unit`, the README gate set and `diff-comp` pass.
- Report:
  - fixtures moved from listed to agreeing;
  - every ruling;
  - the runner import-list test;
  - line counts against A.4's targets (~1,900 lines for the exe rows);
  - build time per fixture, old vs new.
