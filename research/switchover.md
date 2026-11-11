# Plan: the switch-over (vera-next becomes vera, the old pipeline goes)

Planner: plan-switchover. Repo `refactor` @ 90e93007. Read-only research, no builds run.
Sources: `lib/TODO.md` §0, §2, §10-§12, Appendix; `docs/rewrite/README.md`, `comp.md`,
`exe.md`, `digital.md`, `kernels.md`; `build.zig`, `build/*.zig`; `tests/**`; ESPice
`build.zig` + `src/device/loader.zig` + `src/vpi_host.zig` (../ESPice @ 9bbd4d7f, which pins
VerA 0bc0092b = v0.23.0).

## 0. What this plan decides, in one screen

- **No list line is the switch-over's.** It starts only when every
  `tests/differential/*.xfail` is empty (gate G0, §2). Until then it ships additive
  prerequisite tasks (P1-P12) that make the flip a pure delete+rename.
- **Order:** P-tasks (parallel, additive) → G0 → C1 retire old-side oracles → C2 flip the
  product binary → C3 delete old tests → C4 delete old modules → C5 renames → C6 build
  cleanup → C6b + D1-D6 diag-code rename (plan-diagcodes) → C7 docs → C8 audit. No step
  between G0 and C6b re-records a golden. Every C-step builds, passes `zig build test`, and
  `golden diff` prints IDENTICAL against the G0 snapshot (compiler-construction rule 9).
- **Oracles after the old side is gone:** none keeps running against a pinned old binary.
  Two become goldens with recorded provenance (diff-comp's four runs; diff-codegen's device
  rows). Five keep their independent side and drop the old one (air→f128, kernels→f128,
  link→1-vs-N jobs, rtlil-equiv→recorded `.il`, digital-device tiebreak→nightly
  `test-vdev-run`). Nine retire (§3).
- **ESPice is an in-process consumer** of `vera`, `zigbuild`, `sim`, `digital`, `vpi`,
  `contract` (its `build.zig:19-21,86-87,466-469`). The switch breaks its build; the
  downstream check is ESPice ported on a branch, built with `zig build --fork=<VerA>`
  (Zig 0.18 `Maker.zig:393`), green before the v0.30.0 tag (§5).
- **Measurement before the switch** (§8): `zig build measure` on the fixtures where
  diff-comp agrees, old `vera` vs `vera-next`, paired per fixture, peak RSS + wall + CPU,
  ReleaseFast, inside one build slot. Report to the user before C1.
- **Line count:** survivors today 108,932 lines in 313 tracked files (old side 204,549);
  projected ~123k after the backends still to come, under §0's ~148k (§7).

### Where each skill bites

| Skill | Bites at |
|---|---|
| data-oriented-design | the three new tables: measure `Row` (§8.4), golden snapshot layout (§3.2), harvest list (P7); six questions answered there |
| codebase-clean-code | module DAG after C4 (§4.1): `module_specs` order is the DAG, `lib/` imports nothing from `src/`; one spine (`src/Compilation.zig`) after C5 |
| api-design | ESPice migration: usage code first (`tests/downstream/espice.zig`, P12) written from ESPice's real calls before any surface is changed |
| code-style | every new file ≤500 code lines, `//!` header with in→out + `Contents:`, `check_style.py` on touched files; C5 is `git mv` only |
| doc-comments | every new `pub` (measure options, golden options, `Config.int_systfs`, `--certify`) carries a fact the signature cannot |
| assertions | measure: rows == 2 × modes × fixtures, wall > 0, loop bound = fixture count ≤ 1<<16; golden load: status parses, files ≤ `judge.files_max` |
| test-plan / tdd | §3 names the oracle for every retired/kept check; every new oracle goes red on a planted fault first (§2 table "red first") |
| compiler-construction | rule 9 (byte-identical refactors: golden diff IDENTICAL per C-step), rule 4 (exhaustive guard moved to the new boundary enums, P2), rule 6 (`not built` prongs become coded refusals, P11) |
| zig | rusage via `std.process` `request_resource_usage_statistics` (no external `time`), `--fork` for the downstream build |
| simd-loops | none in this plan: the compiler stays scalar (compiler-construction rule 8); the codegen perf audit (§12 "final audit") is the next phase, not this one |
| writing-perfect-verilog | `--emit-verilog`/`--emit-rtlil` outputs stay judged by verilator/iverilog/yosys (`test-external`) and the recorded `.il` goldens (P8e) |
| spice-engine | device numbers after the switch: FD certificate (`--certify`, P3), golden device rows bit-exact (P5b), ngspice OSDI decks; tolerances follow the oracle (FD by h, Gompute by its documented ulps) |
| ponytail (ultra) | no pinned old binary, no new harness where diff-comp's `fixture`/`judge` already exist, no renames beyond the four the brief lists (+ one optional), rulings files deleted not migrated |

## 1. Root causes

None: no `.xfail` line names the switch-over. What blocks it (non-comment lines today):

| list | lines | owners (from the line's 2nd field) |
|---|---|---|
| comp.xfail | 1993 | rw-lower 751, rw-codegen 488, rw-zero 453, not built 139 (vpi 114, libmap 21, digital_lowering 3, exe 1), rw-dlower 112, rw-comp 42 |
| digital_exe.xfail | 850 | dlower / digital backends |
| lower.xfail | 643 | rw-lower |
| codegen.xfail | 516 | rw-codegen |
| digital_device.xfail | 65 | digital backends |
| rtlil.xfail | 33 | rtlil |
| sim.xfail | 26 | dlower |
| all others | 0 | — |

Not in any list but blocking (found here): **P9** vera-next never built for the cross
targets or wasm (`build/rewrite_comp.zig` adds it only to `rewrite`, not `build-all`);
**P12** the new `Config` lacks `int_systfs` (ESPice passes it, `loader.zig:256`; old
`src/Compilation/Config.zig:97`); **P2** the `else =>` guard checks only OLD enums
(`tests/unit/exhaustive_tests.zig:24-41`), so new code is unguarded today; **P1** the new
modules still import old `kernels` (`src/Sema/{eval_1364,eval_1364_fn,format}.zig`,
`src/Sema/digital/{decl,expr,format,sysfn,task}.zig`, `lib/std/sim/{display,eval:472,files,logic:26,State:54,wide,mixed/monitors:25}.zig`,
`src/next/Compilation/backend.zig:301-302,416-417,483-484`), and `std_kernels` has no
`timer` (`lib/kernels/timer_kernels.zig`: `zNextTimer`, `zTimerPending`, `zTimerDue`).

## 2. Phases and gates

### G0: the switch may start when all hold (lead checks, one command each)

| # | condition | command (in `nix develop`, via `~/.cache/vera-heavy.sh <repo>`) |
|---|---|---|
| 1 | every `tests/differential/*.xfail` has 0 non-comment lines | `for f in tests/differential/*.xfail; do grep -cv '^\s*\(#\|$\)' $f; done` all 0 |
| 2 | diff-comp, diff-digital-exe, diff-digital-device green | `diff-comp diff-digital-exe diff-digital-device -j4` |
| 3 | diff-rtlil + rtlil-equiv green | `nix develop .#external -c zig build rtlil-equiv diff-rtlil -j4` (slot) |
| 4 | conformance-next 6818/6818, `tools/vera.xfail` empty, with the NEW libvera-vpi | `conformance-next` (after plan-vpi switches its VPI_LIB arg) |
| 5 | full `zig build test` green | `test -j4` |
| 6 | P1-P12 merged | `git log refactor` |
| 7 | measurement §8 reported, user says go | — |
| 8 | golden snapshot `g0` recorded from vera-next (P5) | `golden -Dgolden-record=.zig-cache/vera-golden/g0` |

### Prerequisite tasks (additive, before G0; each a commit on `refactor`, green alone)

| id | what | red first (planted fault) | proves |
|---|---|---|---|
| P1 | new modules off `kernels`: `timer` into `std_kernels` | diff-kernels with a wrong `zNextTimer` copy | diff-kernels names `timer.*`; diff-sim/elab/lower/comp no new line |
| P2 | `else =>` guard over the new boundary enums | an unannotated `else =>` over `Air.Inst.Tag` in a scratch file | test-unit fails on it |
| P3 | `--certify` in the new driver | a runner with `fd_certify` forced false: suite `--certify` on `tests/canary` FD canary stays green → must go red | nightly certify is portable |
| P4 | `comp.agree` list + `measure` step | measure on 3 fixtures vs GNU `time -v` (§8.6) | §8 numbers |
| P5 | golden record/against in diff-comp and diff-codegen | `golden -Dgolden-against=g0` after flipping one byte of one recorded stdout → fails naming that fixture | post-switch regression oracle |
| P6a-c | test harness off old modules | per sub-task below | suite/generators/fuzz/runners/oom on new code |
| P7 | harvest old unit-test sources, run both drivers | — (a one-off differential) | no hidden disagreement in deleted tests' inputs |
| P8a-e | surviving oracles as their own roots | per row §3.1 | §3 |
| P9 | vera-next in `build-all` (cross + wasm) | — | cross.yaml/wasm job on the new driver |
| P10 | install `share/vera/kernels*` + `gompute/`; flake smoke; `nofast_host` | smoke without the gompute files → fails | §5 downstream proxy |
| P11 | every `notBuilt` prong → coded refusal or deleted | a fixture forcing the RTLIL unsupported shape still exits 126 → must exit 1 with the code | rule 6 |
| P12 | ESPice API parity: `Config.int_systfs` + `tests/downstream/espice.zig` | the downstream test with `int_systfs` dropped → wrong value/code | §5 |
| P13 | `src/codegen/zig` emits `field_use` and `limit_sim_reads` (#134), the old backend's `src/codegen/device/codegen/field_use.zig` and `cg_limit.zig` facts, so switching does not drop a contract fact ESPice's N6 limit stage reads | a device built by the new backend with `field_use`/`limit_sim_reads` left undeclared → `contract.fieldUse`/`limitSimReads` fall back to the all-read superset, which the #134 perturbation oracle (`tests/host/a04_idt_hold_revert_host.zig`) cannot then distinguish from a real read | the new backend is at contract parity with the old one on #134's facts before G0 |

### The switch series (after G0; branch `switch` off `refactor`, one commit per row)

| C | what | gate after (all also: `zig build test` green) |
|---|---|---|
| C1 | delete old-side oracles (§3 "retire" rows + old halves), their build rows, every `.xfail`/`.rulings` | `golden -Dgolden-against=g0` IDENTICAL (product still old vera) |
| C2 | flip: `vera` artifact = new driver; devices/vdev/vpi/conformance wiring to new modules | golden IDENTICAL (by G0#2 the new outputs equal the snapshot); `conformance` 6818 |
| C3 | delete old test namespaces/roots (§6.2) | test green |
| C4 | delete old modules: `module_specs` rows + dirs (§4.1) | test green; golden IDENTICAL; `vera --help` byte-equal |
| C5 | renames (§4.3), `git mv` only + import paths | golden IDENTICAL; `check_style.py` on moved files |
| C6 | build cleanup (§4.2): `rewrite*.zig` dissolved, step renames | every TESTING.md step exists in `zig build --help` |
| C6b | **diag-code rename (plan-diagcodes' PR, not this plan's work)**: lands here, after the last byte-identical step and before the docs, as its own behaviour-change commit; then `golden -Dgolden-record=.zig-cache/vera-golden/g1`, the g0→g1 diff reviewed to contain only code spellings; g1 replaces g0 as the baseline | `python3 tools/diagcodes_rewrite.py golden .zig-cache/vera-golden/g0 .zig-cache/vera-golden/g1` exits 0 (g0 with the alias map applied == g1 byte for byte); `golden -Dgolden-against=g1` IDENTICAL; `conformance` 6818 (`//! reject` old numbers accepted as aliases) |
| D1-D6 | **plan-diagcodes' follow-ups** (E1100 split into IEEE 1364 rule keys, duplicate merges, fixture flips), one commit each, each re-recording g2, g3, … and gated by `tools/diagcodes_rewrite.py --expect-split <map>`; after C6b, before C7 | as C6b, against the new snapshot |
| C7 | docs (§6, §9 Q), written with the C6b spellings | `tools/doctest.py` green |
| C8 | line-count audit (§7) | report only |

## 3. The differential oracles after the old side is gone

### 3.1 Disposition

| oracle (step) | compares today | after | new name | why / red first |
|---|---|---|---|---|
| diff-parse | vams vs lib/frontend | retire | — | old module gone; acceptance held by conformance + golden; `test-vams` keeps Ast/Parse tests |
| diff-pp | vams Preprocessor vs old | retire | — | 4243/4243 byte-equal at merge; preprocessing reaches every golden output |
| diff-diag | vams Diag vs lib/diag | retire | — | `codes.zon` is now the catalogue; `--explain` text is in the golden via diagnostics |
| diff-spice | vams spice vs old | retire | — | 66,453/66,453 at merge; `.sp` decks via `test-spice` |
| diff-astgen | AstGen codes vs old | retire | — | end-to-end codes in golden |
| diff-elab | Sema elab vs src/elab | retire | — | same |
| diff-lower | Sema Air vs src/analog (tables, MIR interp values) | retire | — | device rows golden (P5b) + FD certify + fixtures' checks |
| diff-sim | std_sim vs lib/sim/digital | retire | — | `.expected.txt` golds in conformance, `exe-run`, `suite -- devices` |
| diff-air | Air.interp vs old fold **and f128** | keep f128 side | `test-air-ref` | f128 is independent; red: interp `tan` +1 ulp → fails |
| diff-kernels | std_kernels vs lib/kernels, old text, gm, **f128**; fold==device; libErr | keep f128 + fold==device + libErr + kernels-targets | `test-kernels-ref` | red: Gompute `exp` result +2 ulp in a wrapper → fails |
| diff-link | link vs zigbuild; **1 vs N jobs bytes** | keep 1-vs-N (metamorphic) | `test-link-jobs` | red: write a job-index byte into one library → fails |
| diff-air-passes | passes vs Air.interp | unchanged | `diff-air-passes` | no old side |
| diff-codegen | new device vs old device rows bit-exact; versioned vs old | **golden device rows** (P5b) + versioned-vs-strict (both new) | `golden-devices`, `codegen-versions` | red: versioned body with one op flipped → `codegen-versions` fails; golden: perturb one recorded row → fails |
| codegen hosts / bench-fast / scratch stack | new only | keep; hosts fold into `build/devices.zig` (C2 makes them run on new devices anyway) | `bench-fast`, scratch test inside `codegen-versions` | unchanged |
| diff-comp (+digital-exe, rtlil, digital-device) | both binaries | **golden snapshot** (P5a) | `golden` | provenance below |
| comp.rulings / digital_device.rulings / rtlil.rulings / elab / astgen / diag rulings | old-side bugs | delete; summarized in CHANGELOG by clause (§6.3) | — | rulings exist only while an old side exists |
| digital-device tiebreak (`comp/device.zig`) | device stepped vs `--run` | keep as nightly metamorphic oracle over every pinless `.v` | `test-vdev-run` | red: vdev_run drops the last step → fails |
| rtlil-equiv | Yosys: new RTLIL ≡ old RTLIL | Yosys: new ≡ recorded `tests/rtlil/<name>.expected.il` (recorded by OLD vera at P8e) + canary | `rtlil-equiv` | canary already planted |
| exe-run, bench-run, comp-check-race, vdev-next | new only | keep | `exe-run`, `bench-run`, `test-check-race`, rows in devices.zig | unchanged |
| conformance-next | conform harness on vera-next | becomes `conformance` (built `conform` from the submodule's `harness/conform.c`, as `rewrite_comp.zig:136-151` does) | `conformance` | the release gate |

**Pinned old `vera` binary: none.** After the switch every intentional change (§11.3
re-baselines, the E1100 table, fixes) would have to be ruled "old is wrong" against it,
forever; a golden is re-recorded and reviewed instead. A bisect that needs the old
compiler uses the v0.23.0 release tarball.

### 3.2 Golden snapshot (P5): data and provenance

Six questions. In: one driver run per fixture per run kind (`judge.Run`: status, stdout,
stderr, files). Out: a directory tree. How many: ~4,300 fixtures × 4 kinds (harness,
`--emit-exe` .v, `--emit-rtlil` .v, `--check` .v) + device rows for ~2,000 analog
fixtures. Widths: status u8, files ≤ `judge.files_max` (4096), rows f64 written as
`{x}` hex floats (bit-exact text). Access: written once per record, read sequentially by
`against`. Lifetime: on disk; the run's arena per fixture. Parallel: per fixture (comp's
worker pool).

Layout `<dir>/<kind>/<rel>/status`, `stdout`, `stderr`, `files/<path>`; device rows
`<dir>/devices/<rel>.rows`; `<dir>/PROVENANCE`:
```
vera <vera --version> commit <sha> recorded <date> by `zig build golden -Dgolden-record=<dir>`
equal to vera@<P sha> under diff-comp, diff-digital-exe, diff-rtlil, diff-digital-device and
diff-codegen (all lists empty), except the ruled fixtures: <count per rulings file>.
```
The `g0` snapshot is recorded from vera-next at the G0 commit (`P` = same commit; old
vera built there). Published as release asset `vera-golden-0.30.0.tar.zst` + sha256 in
the release notes. Kept by hand, as TESTING.md's golden row is today (not a merge gate).

## 4. Build changes

### 4.1 `build/common.zig` `module_specs` after C4 (in this order; it is the DAG)

```zig
.{ .name = "contract",    .path = "lib/contract.zig" },
.{ .name = "std_kernels", .path = "lib/std/kernels.zig", .imports = &.{ "contract", "gompute_math" } },
.{ .name = "vams",        .path = "lib/std/vams.zig" },
.{ .name = "intern_pool", .path = "src/InternPool.zig" },
.{ .name = "air",         .path = "src/Air.zig",         .imports = &.{ "intern_pool", "vams", "std_kernels" } },
.{ .name = "std_sim",     .path = "lib/std/sim.zig",     .imports = &.{ "std_kernels", "contract", "vams" } },   // P1: was "kernels"
.{ .name = "sema",        .path = "src/sema.zig",        .imports = &.{ "vams", "intern_pool", "air", "std_sim", "std_kernels" } }, // P1: drop "kernels"
.{ .name = "dynlib",      .path = "src/dynlib.zig" },
.{ .name = "link",        .path = "src/link.zig",        .imports = &.{ "contract", "dynlib" } },
.{ .name = "codegen",     .path = "src/codegen.zig",     .imports = &.{ "air", "intern_pool", "vams", "sema", "std_kernels", "std_sim", "contract", "link" } },
.{ .name = "vera",        .path = "src/Compilation.zig", .imports = &.{ "vams", "intern_pool", "air", "sema", "std_sim", "codegen", "link" } }, // C5: was "comp" at src/next/Compilation.zig
// + plan-vpi's rows (lib/vpi runtime, its `.c`), below "vera" if they import it.
```
Removed (C4): `base`, `kernels`, `diag`, `frontend`, `elab`, `ir`, `analog`, `prove`,
`zigbuild`, `device`, `verilog`, `exe`, `sim`, `digital`, old `vpi`, and (C5) `comp`.
`testRoot`: delete the `elab` twin branch (`common.zig` `testRoot`, the two
`addAnonymousImport` lines). `cliExe` becomes `nextExe`'s body
(`build/rewrite_comp.zig` `nextExe`: root `src/main.zig`, imports `vera`, `vams`,
`contract`, `sim_sources`, `gompute_sources`, `exe.stack_size = 256 << 20`), keeping the
`build_options.version` option only if `src/cli/args.zig` reads it (it reads
`contract.vera_version`: drop `build_options` and the `ams` flag).

### 4.2 Per build file

| file | C | edit |
|---|---|---|
| `build.zig` | C2 | `exe` = new driver (`common.cliExe` new body); drop `Language`/`-Dlanguage` (§9 Q3); vpi library from plan-vpi's root; `installFile` vpi_user.h from plan-vpi's path; add (P10) `installFile("lib/std/kernels.zig","share/vera/kernels.zig")`, `installDirectory(lib/std/kernels → share/vera/kernels)`, gompute `math.zig`, `math_data.zig`, `math_pio2.zig` → `share/vera/gompute/`; `conformance` step = `rewrite_comp.zig:136-151`'s form with `VERA_VPI_LIB`/`VERA_VPI_INCLUDE` = the new lib/header, `-j ${CONFORM_JOBS:-$(nproc)}`; remove `rewrite.add(g)` (C6) |
| `build/unit.zig` | C3/C6 | drop `other_exe` (vera-verilog); `all_mod` imports new modules; `fuzz_test` imports `vera`, `codegen`, `std_sim`; `rng_ref`, `printf_ref`, `codegenProbe` import `std_kernels` (P1; probe `expect:` lines re-checked — a RESIDUE is fixed, not relaxed); `suite_mod` imports `vera`, `vams`, `codegen`, `link`, `std_sim` (P6); osdi_mod path (C5 if Q4); `cli` test = new driver root, keep step `test-cli` |
| `build/runs.zig` | P6/C2 | `runners_mod` imports `vera`, `codegen`, `link`; rows unchanged |
| `build/devices.zig` | C2 | host `device` module imports `contract` + `std_kernels` (GPU twins too: `std_kernels` built for gt with `gompute_math`); vdev devices import `contract` + `std_sim`; delete rows duplicated by `rewrite_comp.zig` vdev-next |
| `build/vpi.zig` | C2 | `library()` root/imports per plan-vpi |
| `build/external.zig` | — | none (uses `g.exe`) |
| `build/rewrite.zig` | C1/C6 | C1: delete the `diffs` rows parse, pp, diag, air (old), spice, astgen, sim, elab, lower, codegen (old side), link (old side), `old_interp`, `kernels_text` gen. C6: move survivors (`diff-air-passes`, `test-air-ref`, `test-kernels-ref`, `kernels-targets`, `test-link-jobs`, `codegen-versions`, `golden-devices`, `bench-fast`) into a new `build/oracles.zig` (one `add(g)`), delete `rewrite.zig` and the `rewrite` step |
| `build/rewrite_comp.zig` | C6 | survivors → `build/oracles.zig`: `golden` (four kinds), `rtlil-equiv`, `test-check-race`, `bench-run`, `exe-run`, `measure`; `nextExe` → `common.cliExe`; delete `vera-next`, `diff-*`, `conformance-next` steps |

### 4.3 Renames (C5, `git mv`, no content change but import paths)

| from | to | edits |
|---|---|---|
| `src/next/main.zig`, `src/next/cli/`, `src/next/lsp.zig`, `src/next/lsp_diagnostics.zig` | `src/main.zig`, `src/cli/`, `src/lsp.zig`, `src/lsp_diagnostics.zig` | `@import("comp")` → `@import("vera")` in `main.zig`, `cli/Options.zig`, `cli/args.zig`, `lsp.zig`; headers drop "vera-next"/"at the switch-over" |
| `src/next/Compilation.zig`, `src/next/Compilation/` | `src/Compilation.zig`, `src/Compilation/` (C4 must already have deleted the old `src/Compilation.zig` and `src/Compilation/{analyze,Config,library,osdi,read_failed,request,Result,testbench,verilog}.zig`: `Config.zig` collides) | `../Compilation.zig` imports unchanged (same relative shape); module row `comp` → `vera` |
| `src/codegen/bench.zig`, `src/codegen/bench/` | `src/codegen/exe.zig`, `src/codegen/exe/` | `src/codegen.zig:36-37,116` `bench` → `exe`; `Compilation.zig:74` `codegen.bench.Spec` → `codegen.exe.Spec`; `Compilation/backend.zig:445-453` |
| `src/codegen/digital_next.zig` | `src/codegen/digital.zig` | `codegen.zig:41,117`; `backend.zig:286,296,360,366,388,390`; `lib/std/sim/Device.zig:51` comment |
| `lib/osdi_dyn.zig`, `lib/osdi_dyn/` | `lib/std/osdi.zig`, `lib/std/osdi/` (§2) | `build/unit.zig` osdi_mod; backend/link module lists naming the path; `build.zig` install source paths (installed names unchanged) |
| `lib/contract.zig`, `lib/contract/` | `lib/std/contract.zig`, `lib/std/contract/` (§2) | `build/common.zig` `contract` row path; `build.zig` installs from the new path to the SAME `share/vera/contract.zig` + `contract/` (hosts see no change); `flake.nix` smoke paths unchanged |
| kept | `src/codegen/zig.zig` (not §2's `device.zig`) | §9 Q5 |
| kept | `lib/std/sim/bench*` (the testbench runtime) | the name is right there |

C5 oracle: `golden -Dgolden-against=g0` IDENTICAL, `zig build test` green.

## 5. ESPice: the contract and the downstream check

### 5.1 What changes for a host

| item | change | kind |
|---|---|---|
| `lib/contract.zig` entry points | none; additive: `formatC`, `str_real`, `str_real_source` | compatible |
| `contract/family.zig` | optional traits `Fast` + `fromFast` (`checkFamily` refuses `Fast` without `fromFast`); `RefOptions.math` | compatible: a family without `Fast` runs the fast body on `S` (`src/codegen/zig/DeclGen.zig:93`) |
| device imports | `@import("std_kernels")` (`DeclGen.zig:129`), which imports `gompute_math`; ~31 KB less text per device | **breaking**: host build must add modules `std_kernels` (`share/vera/kernels.zig` or `vera.module("std_kernels")`) and `gompute_math` |
| `vera_version` | 0.23.0 → 0.30.0 (release-prep) | regenerate devices |
| in-process modules ESPice imports | `vera` (`fastvaf.analyze`, `Result.generate`, `Device`, `diag.Bag/render/AddFileError`), `zigbuild` (`buildLibrary`, `buildExe`, `buildBatch`, `stage`, `Output`, `Options`, `Module`, `compileRelease`, `BuildError`), `sim` (`digital.Error`), `digital` (`emitDevice`), `vpi` (§ list sent to plan-vpi) | **breaking**: port map below |
| `--check` | per-invocation scratch (§12, espice-8a) | fixes ESPice's race; drop its workaround |
| scratch arrays | written-element mask (§11.10) | ESPice branch `dev/bsource-uninit` (d6796553) drops `(* vera_scratch = "uninit" *)` |

Port map (the content of `docs/using/espice-0.30.md`, written in C7):
`fastvaf.analyze`+`generate` → `vera.Compilation.create(gpa, io, .{ .paths, .include_dirs, .display = .record, .int_systfs, .target = .zig })` + `update` + `outputs` + `getAllErrors` (Diag render);
`zigbuild.buildLibrary` → `link.File.flush(f, gpa, io, q, device, generation)`;
`zigbuild.buildExe/buildBatch/stage` → `link.exe.buildExe/buildBatch/stage`;
`digital.emitDevice` → `vera.Compilation` with a `.v` path and `.target = .zig` (codegen.digital device);
`vpi.*` → plan-vpi's module.

### 5.2 The downstream check

1. **P12 `tests/downstream/espice.zig`** (VerA side, in `test`): ESPice's
   `loader.zig:240-292` flow re-written against the new exported modules, usage code first
   (api-design): compile `tests/osdi/diode.va` with `int_systfs = &.{"$espice_int"}`
   through `vera.Compilation`, build the library through `link.File.flush` with
   `contract` + `std_kernels` modules, open it with `dynlib`, evaluate one point, compare
   the diode's closed form `I = Is·(exp(V/Vt)−1)` at V = 0.6 V, Is = 1e-14, Vt = 0.025852
   to 1e-12 relative (oracle: closed form; tolerance = Gompute exp's ≤1 ulp × κ≈23).
   Also a `.v` device (`v_inv.v`) through the same entry. Red first: drop `int_systfs`
   from `Config` → the `$espice_int` call must be refused (code) or mis-typed → test fails.
2. **P10 install smoke** (in `nix.yaml` via `flake.nix` `smoke`, and `zig build
   install-smoke`): after install, `vera --emit-zig r.va > r.zig`, then
   ```
   zig build-obj -fno-emit-bin --dep contract --dep std_kernels -Mroot=r.zig \
     -Mcontract=$out/share/vera/contract.zig \
     --dep contract --dep gompute_math -Mstd_kernels=$out/share/vera/kernels.zig \
     -Mgompute_math=$out/share/vera/gompute/math.zig
   ```
   plus the existing loop extended to `kernels/` and `gompute/` imports. Red: omit
   `math_data.zig` from the install → fails.
3. **P10 `tests/host/nofast_host.zig`** (`//! device tests/bench/diode.va`, built versioned
   via `device_gen.zig ... versioned` as `bench-fast` does): a family that re-exports
   `RefFamily`'s decls except `Fast`/`fromFast`; asserts every row equals the strict
   device's within `codegen.fast_ulps` (the bound diff-codegen uses). ESPice's family has
   no `Fast` today; this is its path.
4. **ESPice port (ESPice side, before the tag):** ESPice branch `dev/vera-0.30` ported
   per §5.1, built and tested with `cd ../ESPice && nix develop -c zig build
   --fork=/home/omare/Documents/Projects/EDA-Tools/Simulator/VerA test` against the C6
   commit. Green is the downstream gate for tagging v0.30.0; then ESPice bumps its pin
   (`zig fetch --save git+https://github.com/OpenFAT/VerA#<v0.30.0 sha>`).
   `spice.yaml` stays disabled until ESPice publishes a release built on 0.30.0 (§9 Q6).

## 6. TESTING.md, tests/, docs

### 6.1 Tier map after C6 (replaces TESTING.md "Tiers"; the implementer measures the
"Measured" column at C6 and writes the numbers)

| Tier | Command | Contents |
|---|---|---|
| Pre-commit (<10 s) | `zig build check` | type-check every root, `zig fmt --check` |
| Merge: `test.yaml` | `zig build test` | `test-<module>` for every `module_specs` row, `test-cli`, `test-unit` (modules, exhaustive guard on new enums, oom on `vera.Compilation`, contract/ulp/integer/kernel on `std_kernels`, vpi negative), `test-air-ref`, `test-kernels-ref`, `kernels-targets`, `test-link-jobs`, `diff-air-passes` (merge size), `codegen-versions`, `test-check-race`, `bench-run`, `exe-run`, hosts (`devices.zig`, incl. `nofast_host`), `test-downstream`, runners, argv, generators, canary, host.py, conformance selftest, rng/printf refs, probe, VPI apps |
| Merge: `conformance.yaml` | `zig build conformance`; `suite -- devices`, `-- vpi`, `-- devices --native` | 6818 by name against `tools/vera.xfail`; `suite -- ams` per §9 Q2 |
| Merge: `external.yaml` | `nix develop .#external -c zig build test-external rtlil-equiv` | verilator/iverilog/yosys, RTLIL equivalence to recorded `.il` |
| Merge: `cross.yaml`, `nix.yaml` | `build-all` ×5 + wasm parity; `nix flake check` + smoke | the new driver on every target; install smoke (§5.2) |
| Nightly | `nightly.yaml` | `suite -- --perturb`, `suite -- --certify` (spawning `vera --run -DVERA_PERTURB=δ` / `--certify`), fuzz 200K, determinism, sweep, `diff-air-passes -Dfull-oracles`, `test-vdev-run`, `golden-devices` against the latest release snapshot |
| Release | `publish.yaml` | merge gate, `conformance.py --check`, every target, install smoke, golden snapshot asset |
| By hand | `zig build golden -Dgolden-record=A` / `-Dgolden-against=A` | every refactor: IDENTICAL or a reviewed diff |

TESTING.md "Domains" table: replace every `lib/frontend`, `src/elab`, `src/ir`,
`src/analog`, `src/prove`, `lib/sim`, `lib/kernels`, `src/zigbuild`, `src/vpi`,
`lib/base`, `lib/diag` path with its §2 successor; delete the `src/prove/falsify.zig` row
(replaced by `diff-air-passes`' falsify); fix the stale Downstream row (`pages.yaml`
compiles no ESPice model) to §5.2; add rows for `golden`, `test-vdev-run`,
`test-downstream`.

### 6.2 tests/ disposition (C3 unless marked)

| file | fate |
|---|---|
| `tests/unit/{codegen,lower,proof,prove_oom,ssa,verilog,parser,preprocessor,diag,rtlil,sim_digital,digital,exe,vpi,zigbuild}_tests.zig`, `contract_names.zig` | delete (old modules), after P7 harvest; `contract_names`: every device is compiled by conformance, so a missing decl fails there |
| `tests/unit/{integer,kernel}_tests.zig` | P1: retarget to `std_kernels` names; a test with no `std_kernels` counterpart is deleted (diff-kernels proved bit-equality, 737 names) |
| `tests/unit/oom_tests.zig` | P6c: `checkAllAllocationFailures` over `vera.Compilation.create`+`update`+`destroy`, `.target = .lint` on one fixture per chapter dir, `.zig` on two (same fixtures as today, `oom_tests.zig` list) |
| `tests/unit/exhaustive_tests.zig` | P2 adds new rows; C4 deletes the old rows |
| `tests/unit/{contract,ulp}_tests.zig`, `vpi_negative_tests.zig` | keep (vpi: plan-vpi retargets) |
| `tests/unit/modules.zig` | C4: rows = §4.1 modules |
| `tests/fuzz.zig` | P6c: `exe.Spec.parse` → `codegen.exe.Spec.parse` (C5 name; `codegen.bench` before), `vera.analyze` → `Compilation` to `.lint`, `sim.digital.run` → Compilation `.v` `.run` |
| `tests/runners.zig` | P6c: `codegen.bench.writeRunner` + `link.exe.buildExe` |
| `tests/generators/{wide,files,escaped}.zig` | P6c: in-process `Compilation` per row; `files`' E0154 now the vams code for the 65535-file table (same code number, `Diag.Code.E0154`) |
| `tests/suite/{Analog,Fixtures,Suite,Canary}.zig` | P6a: spawn `vera --run` per analog fixture (`Child.zig`), `--perturb` = `-DVERA_PERTURB=<δ>` arg (check.vh reads it; `Analog.zig:340` does it by text today), `--certify` = the P3 flag; `tb.Spec.parse` → `codegen.bench.Spec.parse`; batching (`buildBatch`) deleted |
| `tests/suite/{Reject,SizeSweep}.zig` | P6b: codes from spawned `vera --lint` stderr, headlines matched by `error\[([^\]]+)\]` (any spelling, not 5 characters) and resolved with `vams.Diag.lookup(spelling)` (key, old E/W alias or group alias, per plan-diagcodes), so C6b touches no harness; SizeSweep writes generated sources to its work dir and spawns `vera --emit-zig`/`--emit-so` |
| `tests/suite/Golden.zig` | P5: deleted; `suite -- golden` usage line points to `zig build golden` |
| `tests/differential/*` | C1: delete per §3.1; keep `comp.zig` (→ golden), `comp/{fixture,judge,yosys,device}.zig` (judge: delete `owner`, `notBuilt`; drop `stages.zig`), `codegen.zig` (→ golden-devices/codegen-versions), `codegen/{device_gen,dyn,scratch_gen,ulps}.zig`, `air_passes*`, `kernels/{reference,fold_device,lib_err,gen,math}.zig`, `kernels_targets.zig`, `rtlil_equiv.zig`, `comp_check.zig`, `bench_run.zig`, `exe_run.zig`, `settle.zig` (if imported by survivors), new `measure.zig`. C6 moves the survivors to `tests/oracles/` (same file names) |
| `tests/README.md` | C7: the suites list |

### 6.3 CHANGELOG (C7; the lead files the issues, §9 Q1)

One line each, numbers measured: the rewrite replaces the compiler (conformance 6818/6818,
lines §7, speed §8); devices import `std_kernels` (breaking for hosts, §5.1); `--check`
scratch per invocation; versioned units §11.9; written-element masks §11.10; old-compiler
bugs fixed, grouped by clause from the rulings files (VAMS-2023 §7.8 pinless `.v`
devices: 639 fixtures; IEEE 1364-2005 RTLIL refusals: 46; 1364 `--run` legality: 42;
front-end rulings: 10 — recount from the files at C1 before deleting them).

## 7. Line-count audit (C8)

Command (all tracked files, the measure §0 used, minus the plan document):
```
git ls-files src lib build build.zig ':!lib/TODO.md' | xargs wc -l | tail -1
git ls-files src lib build build.zig ':!lib/TODO.md' | grep '\.zig$' | xargs awk '/^test /{t=1} t{n++} /^}/{t=0} END{print n}'   # test-block lines left in src/lib
python3 tools/check_style.py src lib   # report only; §11.1 exemption for one-struct files
```
Today: whole 313,481; old side 204,549; survivors 108,932 (313 files), of which 10,222
test-block lines. Per Appendix area (survivors today → A-target):

| area | survivors today | target | note |
|---|---|---|---|
| A.1 frontend (`lib/std/vams` incl. codes.zon 8,255) | 28,967 | ~28,445 | on target |
| A.2 elab/Compilation/main/cli/dynlib/build | `src/next` 3,601 + `Zcu` 474 + dynlib 173 + build 1,792 = 6,040 (+ Sema elab share) | ~9,980 | under |
| A.3 analog/ir → Sema + Air | `src/Sema` 24,059 (incl. digital 9,497) + `Air.zig` 676 + IP 675 | ~21,070 (+A.6 Sema share) | — |
| A.4 prove/exe/verilog | `src/Air/*` 4,492 + `codegen/bench` 1,331 (+ verilog TBD) | ~8,255 | under |
| A.5 device/zigbuild | `codegen/zig` 2,616 + `link` 3,088 + codegen.zig 474 | ~18,650 | far under (codegen.xfail 516 open) |
| A.6 digital | `lib/std/sim` 15,904 + `digital_next` 174 + `rtlil` 1,068 (+ Sema/digital above) | ~19,340 | — |
| A.7 runtime/kernels/contract/osdi | `std/kernels` 10,000 + contract 7,882 (gm 1,906 stays, §9 Q7) + osdi 2,810 | ~27,430 | — |
| A.8 vpi | (plan-vpi) | ~11,580 | to come |

Projected at C8: 108.9k + vpi ~11.6k + verilog ~1.4k + osdi/libmap ~1.5k ≈ **123k**
vs §0 ~148k (§11.5: ~150k). The C8 report prints the real numbers per row from the
commands above and every area over its target with the files that put it there.

## 8. Measurement step (before the switch; report to the user)

### 8.1 What

Old `vera` vs `vera-next`, both ReleaseFast, built from the same commit, on the fixtures
where diff-comp agrees (`zig-out/comp.agree`). Per fixture, paired (old and new back to
back, order alternating by fixture index so neither side always runs warm):

| mode | argv | measures |
|---|---|---|
| `text` (compile time, VerA alone, no `zig` child) | analog: harness argv with argv[0] → `--emit-zig -o <work>/d.zig`; `.v`: argv[0] → `--elab` | wall, user+sys, peak RSS of VerA itself |
| `harness` (end to end) | `fixture.argv` unchanged (`--run`/`--check`/`--elab`) | wall, user+sys incl. children, peak RSS = max(vera, its zig children) (wait4 rusage semantics: say so in the report) |
| existing: `.v` executable run time | `tools/bench_exe.sh 5` | median wall of the emitted programs |
| existing: analog device eval | `zig build bench-fast` | strict vs fast median |

### 8.2 Code (P4, one agent)

- `tests/differential/comp.zig` `report()`: also write `zig-out/<v_run.name>.agree`, the
  sorted `rel` of every outcome `.agree`/`.equivalent` (one per line). ~10 lines.
- New `tests/differential/measure.zig` (≤300 lines): reads `zig-out/comp.agree`,
  `fixture.collect` + `fixture.argv` for argv, spawns with `std.process` spawn options
  `.request_resource_usage_statistics = true`, wall from `Io.Clock.awake`, CPU =
  `ru.utime + ru.stime`, RSS = `Child.ResourceUsageStatistics.getMaxRss()`. Env:
  `ZIG_LOCAL_CACHE_DIR = zig-out/measure/<side>-cache` (deleted at start); warm-up: the
  first 5 fixtures of each language run once per side, unrecorded. Writes
  `zig-out/measure/<mode>.tsv` and prints the summary.
- `build/rewrite_comp.zig`: step `measure`, options `-Dmeasure-mode=text|harness`
  (default text), `-Dmeasure-jobs=N` (default 1), `-Dmeasure-sample=N` (0 = all; else
  every k-th agreeing fixture per language dir), reuses `-Dcomp-filter`;
  `has_side_effects = true`; depends on `g.exe` and `next`.

Row (six questions): in = one child run; ~2 × 4,300 × 2 modes ≤ 17,200 rows; fields
`fixture: u32` (index into the agree list), `mode: enum(u1)`, `side: enum(u1)`,
`status: u8`, `wall_us: u32` (≤ 300 s timeout = 3·10⁸), `cpu_us: u64` (children ×
threads can pass u32), `rss_kb: u32`; access: appended under the worker mutex, read once
sorted by (mode, lang); lifetime: the run's arena; parallel: per fixture. Plain
`ArrayList(Row)` (cold, written once), `comptime assert(@sizeOf(Row) <= 24)`.
Asserts: each fixture yields exactly one row per side per mode; wall_us > 0; the
fixture loop is bounded by the agree count (≤ 1<<16).

Summary printed (and the user's report): per (mode, lang ∈ verilog-a, verilog-ams,
spice, verilog): n, Σwall old/new, median and p90 of new/old ratio for wall, CPU, RSS,
geometric mean of the ratio, and the 10 fixtures with the worst wall ratio and the 10
with the worst RSS ratio, by name.

### 8.3 Exact commands (repo root; one build slot)

```
# 0. the agree list (both drivers, current lists)
~/.cache/vera-heavy.sh "$PWD" diff-comp -Doptimize=ReleaseFast -Dcomp-jobs=4 -Dcomp-rebaseline=true
# 1. compile time and VerA's own RSS: sequential, clean numbers (~40 min est.)
~/.cache/vera-heavy.sh "$PWD" measure -Doptimize=ReleaseFast -Dmeasure-mode=text -Dmeasure-jobs=1
# 2. end to end, paired, 4 at once (~1.5-3 h est.); a quick look: add -Dmeasure-sample=400
~/.cache/vera-heavy.sh "$PWD" measure -Doptimize=ReleaseFast -Dmeasure-mode=harness -Dmeasure-jobs=4
# 3. emitted-program speed (existing tools)
~/.cache/vera-heavy.sh "$PWD" install vera-next -Doptimize=ReleaseFast && nix develop -c bash tools/bench_exe.sh 5
~/.cache/vera-heavy.sh "$PWD" bench-fast
```

### 8.4 Keeping it within one build slot

`measure` is not in `vera-heavy.sh`'s light list, so the script takes one of the two flock
slots (`~/.cache/vera-heavy.{0,1}.lock`) and holds it for the build of both binaries and
the whole run. `-Dmeasure-jobs ≤ 4` keeps peak memory under the slot's ~7.5 GB (four
`zig` device builds + two VerA processes). Steps 1-3 run one after another, never two at
once. For absolute numbers start when the other slot is idle
(`flock -n ~/.cache/vera-heavy.1.lock true && flock -n ~/.cache/vera-heavy.0.lock true`
both succeed); the paired, order-alternated design keeps the ratios valid either way.

### 8.5 Fixtures

All of `zig-out/comp.agree` (at G0: every fixture but the ruled ones). External manifests
(ivtest etc., part of the 6818) are not in diff-comp and are not measured; say so.

### 8.6 The measurement's own oracle

Before trusting the TSV, three fixtures by hand with GNU time (NixOS path; no
`/usr/bin/time` on this machine):
```
T=/run/current-system/sw/bin/time; R=$PWD; W=$(mktemp -d)
for exe in zig-out/bin/vera zig-out/bin/vera-next; do
  (cd "$W" && ZIG_LOCAL_CACHE_DIR=$W/zc $T -v "$R/$exe" --emit-zig -o "$W/d.zig" --no-std-defs \
     -I "$R/tests/conformance/tests/include" "$R/tests/conformance/tests/verilog-a/ch04_expressions/multiply.va") 2>&1 |
     grep -E 'Maximum resident|Elapsed \(wall|User time|System time'
done
```
(also `verilog/09_behavioral_modeling/<any agreeing>.v` with `--elab`, and one `--run`).
`measure`'s RSS must be within 5% of `Maximum resident set size`; else the tool is wrong.

## 9. Tasks (one Sonnet agent each; lanes = no shared file)

| task | files | deps | lane |
|---|---|---|---|
| P1 kernels retarget | new `lib/std/kernels/timer.zig` (copy of `lib/kernels/timer_kernels.zig`), `lib/std/kernels.zig` (+`pub const timer`), `src/Sema/{eval_1364,eval_1364_fn,format}.zig`, `src/Sema/digital/{decl,expr,format,sysfn,task}.zig`, `lib/std/sim/{display,eval,files,logic,State,wide,mixed/monitors}.zig`, `src/next/Compilation/backend.zig:301-302,416-417,483-484` (module lists: `std_kernels` + `gompute_math` instead of `kernels`), `build/common.zig` rows, `tests/differential/kernels.zig` (timer names), `tests/unit/{integer,kernel}_tests.zig`, `tests/{rng,printf}_reference.zig`, `tests/codegen_probe.zig`, `build/unit.zig` probe/refs imports | — | A |
| P2 guard registry | `tests/unit/exhaustive_tests.zig` (rows: `vams.Ast.Node.Tag`, `vams.Vir.Inst.Tag`, `vams.SysFn.Tag`, `Air.Inst.Tag`, `std_sim.Program.Inst.Tag`, `std_sim.Program.Expr.Tag`, `vams.Preprocessor.directive.Directive`, `vams.Token.Tag` last), `lib/std/vams/Preprocessor.zig` (`pub const directive = @import("Preprocessor/directive.zig");`), every unannotated `else =>` it then finds in new code (annotate `// else: <reason>` or make exhaustive) | — | B |
| P3 `--certify` | `src/next/cli/args.zig` (flag, not in `--help`: argv table tests documented flags only), `src/next/Compilation/Config.zig` (`certify: bool = false`), `src/next/Compilation/backend.zig` (bench `Facts.certify`), `src/next/Compilation/test.zig` | — | C |
| P11 not-built → refusals | `src/next/Compilation/{backend,frontend}.zig`, `Compilation.zig` (`not_built_status`, `Outputs.not_built`, `Backend.digital_lowering`), `test.zig:164-172`, `src/next/main.zig:9`; each remaining site gets the code the old driver gives the same input (find in `src/Compilation/*.zig`/`src/cli/*.zig`) | P3, all backends merged | C |
| P4 measure | `tests/differential/comp.zig` (`report`), new `tests/differential/measure.zig`, `build/rewrite_comp.zig` | — | D |
| P5a golden (driver) | `tests/differential/comp.zig` (`-Dgolden-record`, `-Dgolden-against`: `one()` loads `old` from the snapshot instead of running), `comp/judge.zig` (`save`, `load`), `build/rewrite_comp.zig` (step `golden`); delete `tests/suite/Golden.zig` + its mode in `Suite.zig`/`suite.zig` | P4 | D |
| P5b golden (devices) + codegen-versions | `tests/differential/codegen.zig` (record/against rows; versioned vs NEW strict), `build/rewrite.zig` rows `golden-devices`, `codegen-versions` | — | E |
| P6a suite analog | `tests/suite/{Analog,Fixtures,Suite,Canary}.zig`, `build/unit.zig` suite_mod imports | P3 | F |
| P6b suite reject/sweep | `tests/suite/{Reject,SizeSweep}.zig` | P6a; `vams.Diag.lookup` from plan-diagcodes' additive catalogue PR | F |
| P6c in-process users | `tests/{fuzz,runners}.zig`, `tests/generators/{wide,files,escaped}.zig`, `tests/unit/oom_tests.zig`, `build/runs.zig`, `build/unit.zig` (fuzz, gen imports) | — | G |
| P7 harvest | scratch script (not committed): every `\\` multiline literal holding `module`…`endmodule` in the §6.2 delete-list files + in-file tests of the old dirs → `<scratch>/harvest/{verilog-a,verilog}/<file>__<line>.{va,v}` with first line `//! lrm harvested from <file>:<line>`, `include/` copied from the fixture root; run `diff-comp -Dcomp-root=<scratch>/harvest -Dcomp-rebaseline=true` (add the `comp-root` option: `rewrite_comp.zig` `fixture_root`) | — | D (after P4) |
| P8a-e oracles | a: `tests/differential/air.zig` → new root `air_ref.zig` (f128 half); b: `kernels.zig` → `kernels_ref.zig` (reference, fold_device, lib_err); c: `link.zig` → `link_jobs.zig`; d: `comp/device.zig` + new `vdev_run.zig` (every pinless `.v`: `vera --emit-zig` device stepped by `tests/host/vdev_run.zig` = `vera --run` stdout); e: `tests/rtlil/<name>.expected.il` recorded by OLD vera (`# recorded by vera <sha> --emit-rtlil`), `rtlil_equiv.zig` compares new vs file; `build/rewrite.zig` rows | — | H |
| P9 cross targets | `build/rewrite_comp.zig` (`g.all_step.dependOn(&next.step)`), fixes the targets need (wasm: `--emit-*` text paths only; spawning paths return `error.Unsupported` → coded refusal, as old `src/main.zig` does) | — | I |
| P10 install + smoke + nofast | `build.zig` installs, `flake.nix` `smoke`, new `tests/host/nofast_host.zig`, `build/devices.zig` (std_kernels for host devices of the new driver's devices) | P1 | I |
| P12 ESPice parity | `src/next/Compilation/Config.zig` (`int_systfs: []const []const u8 = &.{}`), Sema's systf typing site (where old `src/analog/sysfunc*.zig` reads `int_systfs`), new `tests/downstream/espice.zig`, `build/unit.zig` step `test-downstream` | P1 | J |
| C1-C8 | §2, §4, §6 | G0 | serial, one agent |

Wrong-number risks first: P1, P5b, P8a-b, P12 before the rest.

## 10. Commands per task (gate on `$?`, never a pipe)

| task | commands (`W` = worktree) | lists it may change |
|---|---|---|
| P1 | `vera-heavy.sh W test-std_kernels test-std_sim test-sema check`; `vera-heavy.sh W diff-kernels diff-sim diff-elab diff-lower`; `vera-heavy.sh W diff-comp -Dcomp-filter='ch09|09_behav'` | kernels.xfail only (must stay empty) |
| P2 | `vera-heavy.sh W test-unit check` | none |
| P3, P11 | `vera-heavy.sh W test-vera-next test-comp check`; `vera-heavy.sh W diff-comp` | none; report comp.xfail effect to lead |
| P4 | `vera-heavy.sh W measure -Dmeasure-sample=20` then §8.6 | none |
| P5a | `vera-heavy.sh W golden -Dgolden-record=.zig-cache/vera-golden/t1 -Dcomp-filter=ch04`; same with `-Dgolden-against=…/t1` → IDENTICAL; flip a byte → red | none |
| P5b | `vera-heavy.sh W codegen-versions golden-devices -Dcodegen-filter=ch04` | none |
| P6a-c | `vera-heavy.sh W test-suite test-generators test-runners test-unit`; `vera-heavy.sh W suite -- ams ch04`; `vera-heavy.sh W suite -- --perturb ch04` (canary red/green as today) | tests/suite.xfail (lead review) |
| P7 | as in §9 | none (findings → owners) |
| P8 | `vera-heavy.sh W test-air-ref test-kernels-ref test-link-jobs test-vdev-run`; `nix develop .#external -c zig build rtlil-equiv` (slot) | none |
| P9 | `vera-heavy.sh W build-all -Dtarget=x86_64-windows`, `-Dtarget=aarch64-macos`, `-Dtarget=wasm32-wasi` | none |
| P10 | `vera-heavy.sh W install --prefix zig-out/smoke` + §5.2 build-obj; `nix build .#default && nix flake check` (slot) | none |
| P12 | `vera-heavy.sh W test-downstream test-comp` | none |
| C1-C6 | each: `vera-heavy.sh W test -j4`; `vera-heavy.sh W golden -Dgolden-against=.zig-cache/vera-golden/g0`; C2+: `vera-heavy.sh W conformance`; C2: `nix develop .#external -c zig build test-external rtlil-equiv` | C1 deletes every list |

`comp.xfail` is the lead's: no task commits it.

## 11. Zig mirrors and departures from Zig

Zig cited at `0.18.0-dev.349+d924f83bf` (`~/.cache/zig-src-d924f83bf`, lib in
`/nix/store/qgqwh2cz7qhkvqb7b8g7kgrvk6kmzdjs-zig-0.18.0-dev.349+d924f83bf/lib`).

| this plan | Zig mirror |
|---|---|
| after C5 the spine is `src/Compilation.zig` (`create`/`update`/`destroy`), driven by `src/main.zig` | `src/Compilation.zig:1714` `create`, `:2751` `update`, `:2582` `destroy`; `src/main.zig:277` `mainArgs`, `:918` `buildOutputType` |
| `src/` holds `Compilation`, `Zcu`, `InternPool`, `Sema`, `Air`, `codegen`, `link` as siblings; no `src/next/` | `src/{Compilation,Zcu,InternPool,Sema,Air,codegen,link}.zig` |
| `codegen/zig.zig` named for the language it emits (Q5) | `src/codegen.zig:55` `.stage2_c => @import("codegen/c.zig")`; `src/codegen/{c,llvm,wasm}.zig` |
| `lib/std/vams` = the front end a host may import | `lib/std/zig.zig:23-32` (Token, Tokenizer, Ast, AstGen, Zir) |
| golden snapshot of compiler outputs, by fixture | `test/cases/` + `build.zig:480` `test-cases` (expected output beside each case) |
| measurement via spawn rusage, no external `time` | `lib/std/process.zig:416` `request_resource_usage_statistics`; `lib/std/process/Child.zig:34-38` |
| downstream build against a local VerA | `lib/compiler/Maker.zig:393` `--fork=` |
| delete the old pipeline outright, no pinned old binary | Zig's stage1 removal: `src/stage1/` deleted, no stage1 oracle kept |

Departures:

| where | departure | why |
|---|---|---|
| `lib/contract.zig` + `share/vera/contract/`, `kernels/`, `gompute/` | an installed device ABI and runtime with no counterpart in Zig | VerA emits source a host compiles (ESPice); Zig ships `lib/` as its std, the nearest match |
| `lib/std/sim` (runtime of emitted executables) | a runtime that is not std-like | Zig's equivalent is `compiler_rt`/`std.start`; kept under `lib/std` per lib/TODO.md §2 |
| goldens recorded once from the differential state (§3.2) | Zig's cases are hand-written expectations | the old compiler is the provenance; re-recorded per reviewed change, like `test/cases` updates |
| E1100 legacy wording table (Q8) | Zig keeps no compatibility wording | byte-identical switch (compiler-construction rule 9) |
| build modules `sema`, `air`, `codegen`, `link`, `vera` (roots `src/sema.zig` beside `src/Sema.zig`, etc.) | Zig compiles `src/` as ONE module rooted at `src/main.zig` | VerA's `module_specs` DAG is the dependency-direction check (AGENTS.md Layout) and gives per-module `test-<module>`; kept |
| `src/cli/{args,Options,usage}.zig` | §2 folds `cli/` into `main.zig` like Z/main.zig (one file, thousands of lines) | ≤500 code lines per file (code-style); `args.zig` alone is 643 lines; kept as a folder, §2 amended |
| `src/Compilation/{backend,errors,frontend,legacy,test}.zig` | Zig has only `src/Compilation/Config.zig`; the rest lives in the ~8k-line `Compilation.zig` | ≤500-line rule; one file per job of the spine; kept |
| `src/lsp.zig`, `src/lsp_diagnostics.zig` | no LSP in the Zig compiler (zls is separate) | §2 lists `lsp.zig`; the diagnostics half splits for the 500-line rule |
| `codegen/zig.zig` (§2 says `device.zig`) | matches Zig (`codegen/c.zig`: named for the output language) | departure from §2, not from Zig; §2 amended (Q5) |
| not yet in the tree at C8: `Zcu/PerThread.zig`, `Type.zig`, `Value.zig`, `Discipline.zig`, `Compilation/libmap.zig`, `codegen/{verilog,vpi,osdi}.zig`, `lib/vpi/`, `src/vpi_host.zig` | §2 rows owned by other plans (sema, libmap, vbackends, vpi) | C8's audit lists each §2 row present/absent; an absent row is a finding for its owner, not a switch-over task |

## 12. Open questions (each with a recommendation)

- **Q1.** CHANGELOG lines must cite issues; filing GitHub issues is outward-facing
  Recommendation: lead asks the user once, then files one issue per §6.3 line
  Decision: One issue per changelog line, yes. Filing them is outward-facing: the lead asks the user once before filing.

- **Q2.** after the switch, `suite -- ams` (spawning) repeats `conformance`'s work in the merge tier (13-21 min each today)
  Recommendation: drop the plain `-- ams` pass from `conformance.yaml`, keep `--perturb`/`--certify` nightly; evidence first: plant "drop the last sweep point" in the runner, both `suite -- ams` and `conformance` must name the same FAIL set
  Decision: Drop the plain `-- ams` pass once the planted fault shows both name the same FAIL set (name lists, not counts). `--perturb`/`--certify` stay nightly.

- **Q3.** `-Dlanguage=verilog` (a 1364-only `vera`) has no consumer and the new driver never implemented it (its usage text still mentions it, `src/next/cli/usage.zig:113`)
  Recommendation: drop the option and the usage line in C2; doctest re-run
  Decision: Drop the option and the usage line in C2; doctest re-run.

- **Q4.** `lib/osdi_dyn` → `lib/std/osdi` and `lib/contract*` → `lib/std/contract*` are in §2 but not in the lead's rename list
  Recommendation: do both in C5 (installed paths unchanged, so hosts see nothing), unless plan-vbackends already moved osdi
  Decision: Both in C5, installed paths unchanged. plan-vbackends did not move osdi.

- **Q5.** §2 names the Zig backend `codegen/device.zig`; it is `codegen/zig.zig`
  Recommendation: keep `zig.zig` (the language it emits, as Zig's `codegen/c.zig`; leaves room for `llvm.zig`, §10 step 12); amend §2
  Decision: Keep `codegen/zig.zig`; amend §2.

- **Q6.** `spice.yaml` stays disabled; the only downstream gate is the ESPice port built with `--fork` by hand
  Recommendation: accept for v0.30.0; enable `spice.yaml` with ESPice's first release on 0.30
  Decision: Accept for v0.30.0; enable `spice.yaml` with ESPice's first release on 0.30.

- **Q7.** `lib/contract/gm` (1,906 lines) is still `RefOptions.math`'s default; deleting it makes the installed contract depend on Gompute
  Recommendation: keep gm through 0.30.0; move the default to `std_kernels.math` in a contract change agreed with ESPice
  Decision (revised by the user, 2026-11-11): `gm` and `gm/` are deleted; Gompute provides all
  device math. `asinh`, `acosh`, `atanh` and `atan2` move from `lib/std/kernels/math.zig` into
  Gompute (a new tag, pinned by commit and hash in `build.zig.zon` and `flake.nix`), and every `gm`
  user (`RefOptions.math`'s default, `family_check`, the old kernel text, `prove`, `Air/interp`,
  `lib/kernels`, `ulp_tests`) takes Gompute's `math`. The installed contract ships Gompute's math
  files beside itself. Oracle: diff-kernels' f128 reference (each function within Gompute's
  documented ulps), fold == device, host/NVPTX/AMDGCN rounding alike (`kernels-targets`); device
  build time measured before and after on the largest models and reported.

- **Q8.** E1100 wording table (`src/next/Compilation/legacy.zig`) keeps old codes on the 1364 route
  Recommendation: keep at the switch (byte-identical); dropping it means editing the suite (user's repo), user's call after
  Decision: Keep it at the switch (byte-identical). Dropping it edits the suite, so it is the user's call afterwards; diagcodes C6b covers the rename.

- **Q9.** `lib/TODO.md` and `docs/rewrite/` are the rewrite's contract; after C7 they are history
  Recommendation: move §2 (as built), §3, §11 into `docs/ARCHITECTURE.md`; delete the rest and `docs/rewrite/` (git keeps them)
  Decision: Move §2 (as built), §3, §11 and every plan's "Departures from Zig" into `docs/ARCHITECTURE.md`; delete the rest and `docs/rewrite/` (git keeps them).

- **Q10.** AGENTS.md "Layout" describes the old tree
  Recommendation: C7 rewrites it (writing-for-agents skill); the user approves the diff, no agent message can
  Decision: C7 rewrites it; the user approves the diff.

- **Q11.** ESPice in-process API (`fastvaf`, `zigbuild`, `sim`, `digital`, `vpi`) breaks; VPI surface is plan-vpi's (message sent)
  Recommendation: P12 + §5.2 step 4 before the tag; tell espice-8a the tag and the port map
  Decision: Yes: P12 and §5.2 step 4 before the tag; espice-8a gets the tag and the port map.

- **Q12.** deleting ~1,250 in-file + ~730 `tests/unit` old tests drops regression tests whose inputs are not fixtures
  Recommendation: P7 harvest runs every embedded source through both drivers before C3; the ~40 tests citing a bug/issue (`grep -ciE '#[0-9]{2,}
  Decision: Yes: P7 harvest before C3. The ~40 tests that cite a bug become fixtures with recorded provenance; a bug's regression test is never dropped.

- **Q13.** measurement noise from the other build slot
  Recommendation: paired + order-alternated rows; absolute numbers only when both slots were idle (§8.4)
  Decision: Accept: paired, order-alternated rows; absolute numbers only with both slots idle.
