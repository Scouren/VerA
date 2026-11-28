# TODO: the rest of the VerA rewrite

Written 2026-11-28 when the user stopped the run. It is the hand-off: what is merged, what
sits on which branch, what is left, in what order, and how to run it. The binding plans stay
where they are: `research/finish.md` (done criteria F1-F13, tracks, stages),
`research/reconcile.md` (§2 bundle verdicts, §3/§3b/§3c/§3d tasks, §4 rules, §5 order, §6
decisions), and the per-area plans listed in `research/README.md`. This file orders them and
records the state; where it and a plan disagree on a `Decision:`, the plan wins.

Stopping condition (user): run until every `tests/differential/*.xfail` is empty (F1), unless
a difference is an old-side bug (a ruling with its LRM clause). Then G0 (`research/g0.md`),
the switch C1-C8, and F1-F13. Outward actions are allowed through the repo's rules: `main`
only through a PR whose required checks passed, a release only through `publish`, a contract
change with its CHANGELOG line.

## 1. State on 2026-11-28

### Merged on `refactor` (pushed)

| Commit | What | Measured |
|---|---|---|
| c9e65c05 | DV1 = codegen T40: a declared array is one `[n]` slot | new-side build 2,212 -> 583 s; text 69.6 -> 58.4 MB |
| 0fa12902 | DV2 = M3: indentation capped at 32 levels; diff-codegen certifies no line past 128 spaces (red shown on `nested_ifs_500`, 4,004 spaces) | text 58.4 -> 35.8 MB; build 583 -> 506 s |
| e8b74984, fb6e8d3c, 24b32c12 | P1: `tools/bench/dv0.py` (OSDI eval ns + checksum per device, by-name gate, K2 method), DV-C census (`tools/bench/dv0-census.md`), K3 `tools/perf_tidy.py` vendored with provenance + `tools/bench/perf_tidy.allow` | see `reconcile.md` §3c |
| 964a1fd1 | T12: §5.10 `cross`, `above`, `timer` as operator state | codegen.xfail 461 -> 365 |
| d163e5ac | comp.xfail rebaseline after T12 | 1,579 -> 1,536 |
| 8228a21a, 7ca9d2c9, aa371fb6, 638646a3 | AGENTS.md (15 GB machines), reconcile.md §3c/§3d | — |

Lists on `refactor` now: comp 1,536, codegen 361, lower 345, digital_exe 47,
digital_device 29, sim 11, rtlil 5 (F1 total 2,334); diag_gaps 726 (F3, after the switch).

### Branches pushed but NOT merged (in merge order)

| Branch | Holds | Verified | To merge |
|---|---|---|---|
| `p2-m9` @ 5f2d030c | P2 = M9 (also covers M1/M2): Sema builds each instance's parameter layout once (`src/Sema/eval.zig`, `decl.zig`); `Air.Float.Walk` saves/joins slot state through an undo log (whole-table copy kept as the Debug reference). `--emit-zig` wide 6400: 10.2 s -> 0.12 s, 1,074 -> 39 MiB, bytes identical at 800-6400; `tools/bench/m9.md` | gate half A passed (14 steps); half B (diff-comp, diff-digital-exe, diff-native, diff-digital-device) was stopped | run gate half B, merge |
| `cand2` @ 02a1e780 | refactor + T15/T16 (strings: string slots, `$sformat`/`$swrite`/`$sscanf`, `str$cmp`, `$simparam$str`, strings as numbers) + TF harness (each side in its own directory, written files compared byte for byte; red shown) + TF (§9.5 calls are the W0850 zero answer, the device contract) | on their own branches: diff-codegen 0 failures (codegen.xfail 361 -> 227 here), diff-lower 0 failures; the cand2 gate itself was stopped before finishing half A | full gate; in half B run `diff-comp -Dcomp-rebaseline=true` and accept `zig-out/comp.xfail.new` only if `comm -13` of the sorted path columns (current vs new) prints nothing; commit as `comp.xfail after T15/T16/TF: a -> b` (TF's own run on the old base gave 1,579 -> 1,478, so expect ~1,435) |
| `t15-strings`, `tf-fileio` | the original commits of cand2's work (tf-fileio also has 376d607f, a comp.xfail rebaseline against the OLD 1,579-line list: do not merge that commit) | — | delete once cand2 is merged |
| `o23` @ 7fe3b481 (on cand2) | **WIP, stopped mid-task, unverified**: O3 (dependency masks past 64 unknowns) and O2 (`evalQ`) in progress; touches `src/codegen/zig/{Liveness,stamps,calls,...}.zig`, `tests/differential/codegen/{dyn,sides}.zig`, `tools/bench/dv0*.py`; codegen.xfail 227 -> 225 in the tree | nothing | read the diff, finish per §3 O2/O3 below, red-first, gate |
| `p3-host-literals` @ 225d9b3d | 2c8e306c = the bundle's 91870118 cherry-picked (lib side: six optional host-table declarations, records filled at load); then **WIP, stopped mid-task, unverified**: new `src/codegen/zig/host.zig`, edits to `lib/osdi_dyn/*`, `lib/contract/*`, `build/unit.zig`. The agent was mid "red run" when stopped: **check that no planted bug is left in the WIP diff** (it reported the plant reverted) | nothing | finish per §3 P3 below |
| `dv1-arrays` (remote only) | merged as c9e65c05; the proxy refused the remote delete | — | delete on GitHub |

The `bundle/*` branches on origin are inputs (`reconcile.md` §2), not work.

## 2. How to resume (environment)

- Machine: 4 CPUs, 15 GB RAM. One corpus step peaks near 7.5 GB, so **two corpus steps at
  once is the ceiling**: two implementers, one per lane, sharing the two slots through
  `tools/build-slot.sh` (it holds `~/.cache/vera-heavy.{0,1}.lock`). Any other heavy run (a
  `dv0.py` build, a census) runs under `flock ~/.cache/vera-heavy.1.lock`.
- Cloud sessions here cannot download GitHub tarballs (the proxy allows only the session's
  repo), but `git` over https to public repos works. Before the first `nix develop`, put each
  `flake.lock` github input in the store by git, which gives the same narHash:
  ```bash
  python3 -c "import json;d=json.load(open('flake.lock'))
  for k,v in d['nodes'].items():
    l=v.get('locked',{})
    if l.get('type')=='github': print(l['owner'],l['repo'],l['rev'])" | sort -u |
  while read o r rev; do d=$(mktemp -d); git -C $d init -q && git -C $d fetch -q --depth 1 https://github.com/$o/$r $rev && git -C $d checkout -q FETCH_HEAD && rm -rf $d/.git && nix store add --name source --hash-algo sha256 $d; done
  ```
  (the x86_64-darwin nixpkgs is not needed on Linux). Zig's own fetcher cannot reach GitHub
  either: clone Gompute at the `build.zig.zon` rev and `nix develop -c zig fetch <dir>`; the
  printed hash must equal `build.zig.zon`'s.
- After cloning: `git submodule update --init tests/conformance`. Each worktree symlinks
  `tests/conformance` and `.zig-cache` to the main checkout's (do not commit the
  `tests/conformance` typechange).
- Background commands are killed at 2 h. The full gate takes longer, so run it in two halves:
  ```bash
  VERA_GATE_STEPS="diff-parse diff-pp diff-diag diff-air diff-spice diff-astgen diff-air-passes diff-sim diff-elab diff-lower diff-codegen diff-link diff-kernels" tools/gate.sh <wt> <logdir>-A
  ```
  ```bash
  VERA_GATE_STEPS="diff-comp diff-digital-exe diff-native diff-digital-device" tools/gate.sh <wt> <logdir>-B
  ```
  Half A ~1.5 h, half B ~1 h on a warm cache. `diff-rtlil` needs `nix develop .#external`.
- Every codegen merge moves comp.xfail: a fixture codegen stopped refusing either agrees
  (XPASS: its line must go) or first differs later (its reason changes). So half B runs
  `diff-comp -Dcomp-rebaseline=true` and the lead accepts the new list only when it adds no
  path. A FAIL on an unlisted path is a real regression and blocks the merge.

## 3. The work left, in order

Two lanes at once (reconcile.md §5), one implementer each (Opus, medium effort, `zig` plus
the one domain skill the task names), each in a temporary worktree, gated, merged into
`refactor`, branch deleted. Each brief is one task row: goal and exit lines, the files it
may edit, the old-side files that are the oracle (read-only), the oracle named first and a
planted bug shown red, the narrow commands (`test-<module>`, `diff-<x> -D<x>-filter=`), the
slot rule, the commit trailer, no push or merge.

### 3.1 Merge queue (lead, first)
1. `p2-m9`: gate half B, merge.
2. `cand2`: full gate with the comp rebaseline, merge; delete `t15-strings`, `tf-fileio`.
3. `o23` and `p3-host-literals`: finish (below), gate, merge.

### 3.2 Lists lane (codegen first, by lines per task; counts are cand2's codegen.xfail)

| # | Task | Lines (codegen) | Oracle / note |
|---|---|---|---|
| L1 | **O3** masks past 64 unknowns (a regression, never a ruling) + **O2** `evalQ` = one core evaluation (WIP on `o23`) | 2 + inst >= 63 models; unblocks osdi_dyn | diff-codegen; ladder70 red with a mask that drops word 2; `dv0.py` checksums unchanged with `tools/bench/dv0_zig.py`'s evalQ patch removed; stale-q plant red |
| L2 | **T18** flow contribution to a potential source's branch (27), potential contribution under a condition / switch branch (17), §5.6.7 indirect contribution (8) | 52 | `research/codegen.md` R-section for T18; FD Jacobian (T0b); unblocks VPI G8/G9 |
| L3 | **T10** small arms: `analog$initial` (22), `$port_connected` (8, needs T3 for children), `$test$plusargs`/`$value$plusargs` (5), `$limit` with >1 argument; B2 unused-parameter line (`the new device does not build: unused function parameter/local` 13) | ~48 | `codegen.md` "R2, R6-root, R9, R12-A, B2 small arms (T10)" |
| L4 | **R12** `$limit` string form, the host's `limit` hook | 26 | `codegen.md` R12 phase B |
| L5 | **T17** filters `laplace_nd/zp/np`, `zi_nd/zp/np` (`ops/filter.zig`) | 28 | `codegen.md` R4; after T13 |
| L6 | **T13** `idt$hold` and absdelay leftovers | 7 | `codegen.md` R7/R3 |
| L7 | **T20** user systf calls (`a call of a user function (callee 4294967295)`) | 9 | unblocks VPI G8/G9 |
| L8 | random family: `$random`, `$arandom`, `$rdist_*`, `$dist_normal` | ~14 | rollback oracle (seed committed, T14) |
| L9 | the 21 "point N" wrong numbers (silent wrong numbers: first by the method's rule) | 21 | each: name the oracle, find the class, add the generator that catches it |
| L10 | tail: noise tables with parameter-array knots (3), path latch T19 (2), display-site count (2), `amount`'s default does not fold (1) | ~8 | per plan |
| L11 | **oracle holes** (`reconcile.md` §3d): T12b (`dt = 0` point and `stateCtl(.query)` comparison in `dyn.zig`), T16b (format generator: flags x width x conversion, zero-fill), SW1 (`intSize` of an unranged `localparam` = its value's width, IEEE 1364 §12.2), SW2 (`$simparam$str("path")` in a generate block) | moves lines | each lands with its oracle; expect T12b to move other operators' lines |
| L12 | lowering (`research/lower.md`, 345 lines): tables row N (104 lines / 60 fixtures), a net or branch read as a value (66/33), "not lowered by Sema yet" (selects, port access, task enable, hierarchical names: ~66), four-state/wide literals (18), E-code gaps (E0926, E0528, E0501, E0706 ...) | 345 + ~750 comp | `lower.md` task order; wrong numbers first |
| L13 | text and locations (`zero.md`): location without a code (zero 214 + lower 112), W0650 label/extra/message (~120), notes (54), message text | ~500 comp | `airpasses.md` J0-J3/T23 (W0650 label is one fix for ~260 lines), `diagcodes.md` |
| L14 | VPI (`research/vpi.md` V0-V10): the 114 "backend vpi / not built" | 114 + F2's VPI fixtures | after T18, T20, T11, T22 |
| L15 | digital (`dlower.md`, `vbackends.md`, `libmap.md`): dlower T3/T4/T6b, digital_exe 47, digital_device 29, sim 11, rtlil 5 | ~92 | Yosys tiebreaker for rtlil (`nix develop .#external`) |
| L16 | **TD1** `--display=emit` devices: the new driver has no `--display`; the old emit mode prints §9.4 text and does real §9.5 I/O (`plan/args.zig:27`, `call_gate.zig:52-57,104,143,189`, `cg_file_io.zig`) | switch prerequisite | harness `sides.old` at `.emit` for §9.4/§9.5 fixtures, stdout + written files compared (TF's harness does the files), `dyn.zig` drives `displayPass` as the old runner |
| L17 | **O1** `vera-next --emit-osdi` (exits 126 today) over `lib/osdi_dyn` | F2 | OSDI decks in ngspice 30/30 (`tools/external_analog.py`); `osdi_host` checksum equal to `--emit-so` + osdi_dyn |
| L18 | the rest, re-measured with `tools/xfail_classes.py . out.tsv` after each merge: batch by root cause; a cause under ~10 lines waits for its batch | to 0 | — |

### 3.3 Perf lane (each lands before G0: it changes device text)

| # | Task | Premise (P1's numbers) | Oracle |
|---|---|---|---|
| P3 | host literals: lib side (on `p3-host-literals`) + `codegen/zig` emits the six tables (WIP `src/codegen/zig/host.zig`); CHANGELOG line under Unreleased (the contract version is the release's `vera_version`) | old side: 1,600 params 549 -> 174 KB, build 0.71 -> 0.46 s | `dv0.py` checksums unchanged; carried tables equal the derived ones element for element (planted swapped entry red); diff-codegen 0 failures; OSDI decks if `.#external` builds |
| P4 | DV7 for instance-array models only (`@Vector`, power-of-two zero-padded, vectors across calls, never a struct or a 3-lane vector from memory) + K4 `noalias` + K5 (`.optimized` units only) | inst62: eval 2,478 of 8,553 ns per iterate (29 % ceiling); wide models are one serial chain, nothing to pack | `W == 1` bit for bit; DV0 eval ns down, none slower; diff-codegen identical |
| P5 | DV8 bound each emitted function (32 stages per `noinline` chunk) + DV8b one unit owns `device.run` in a split build | `device.run` is 90-97 % of LLVM's IR; LLVM 0.95 -> 2.23 -> 7.24 s at wide 800/1600/3200; split build sends `device.run` to all 3 units (21.8 of 39.8 s at wide3200) | diff-codegen identical rows; DV0 build ms and peak down, eval ns within noise |
| P6 | DV3 emit less (branch on the comparison, no empty `else`, no unused labels, slot reads in place), DV5 one function per child module, K6 `@sizeOf` assertions on `Model`/`Instance` | `sequential_ifs_10000` 12.5 MB / 59 s build; `generate_loop_4097_instances` 8.4 MB / 50 s | diff-codegen rows identical; DV0 bytes, build ms, eval ns no slower |
| — | DV9 (cold code as tables): **dropped**, cold code is 1-2 % of instructions | — | — |
| P7 | **DB1, the digital bridge** (user, 2026-11-28; `research/patches/vera-digital-bridge.patch`, 2 commits on 0bc0092, applies cleanly to `main` and `refactor`). See §3.5 | old side, 2,000-flip-flop design in ESPice (Debug): arena 105,912 -> 9,358 B per active step; (rebuild + restore + save) / run 3.93 -> 1.30 | the patch's `tests/host/vdev_host.zig` tests (red on 0bc0092) against both devices; diff-digital-device unchanged; a 2,000-flip-flop bench row |

### 3.5 DB1: the digital bridge patch, on both pipelines

What the patch does (old side, `lib/sim/rt`):
1. `device.zig`: after each saved boundary the engine runs on with inputs held (`look`, at most
   `look_cap` = 1,024 event ticks) to the first tick an **output pin's** level or drive
   changes, or the engine stops. `pendingBreakpoint` reports that time (merged with any
   further visible change less than `ttol` after it), not the next internal event; a step
   that reaches neither it nor an input crossing runs no engine. `wakes` is the union over
   the ticks `look` ran; a crossing past them wakes conservatively.
2. `device.zig`: a crossing more than `ttol` late in a step that wakes a process returns
   `.request_reject_at` (its secant time + `ttol`/2), so a host re-lands once; `late_cross`
   stays for hosts that query. A `profile` debug flag prints each active step's cost split.
3. `State.zig`/`transcript.zig`: `quietState` no longer builds the 64 KiB stdout buffer a
   quiet engine never writes (`initTo` prints into the quiet sink; the buffer only for a
   real run), so the device's per-step arena stays inside the allocator's size classes.
4. Tests: `tests/host/vdev/v_edge_clock.v` (metamorphic with `v_edge`), the one-retry, and
   `v_skew.v`'s merge window in `tests/host/vdev_host.zig`; `test-vdev` runs the host alone
   (`build/devices.zig`); a TESTING.md line.

Integration (one lane task, one branch, one gate; the old side is diff-digital-device's
oracle, so both halves land together or the digital_device list grows):
- **DB1a, old side:** `git am research/patches/vera-digital-bridge.patch` on the task branch.
  Separately, the same two commits go to `main` as their own PR (consumers following `main`
  and ESPice get it now; required checks must pass).
- **DB1b, new side:** the same semantics in `lib/std/sim/Device.zig` (already has
  `late_cross`, `pendingBreakpoint`, `updateState`'s `.request_reject_at` on a moved pin, in
  the old shape) and the quiet-state change in `lib/std/sim/State.zig` (or wherever its quiet
  engine allocates its transcript buffer): look-ahead to the first visible output change
  with a named `look_cap`, the `ttol` merge window, no engine run on a step that reaches
  neither, the `wakes` union, and the secant + `ttol`/2 re-land request.
- **Oracle:** the patch's three host tests run against both the old device and the new
  `--check` device (extend `tests/host/vdev_host.zig` or its new-side twin), each shown red
  on the pre-patch code first; diff-digital-device with no list change; a bench row in
  `lib/std/sim/bench` over a 2,000-flip-flop design recording arena bytes per active step
  and (rebuild + restore + save) / run, held by name like DV0.
- **Order:** after the `cand2` merge, before L15 (the digital lists), since it changes what
  diff-digital-device compares.

### 3.4 After F1: G0 and the switch (`research/switchover.md`, `finish.md` §1)

1. **G0** (`research/g0.md`): every differential list empty; `conformance` 6,818/6,818 by name
   on the new driver with the new VPI library; `measure` report (F5-F11: compiler RSS and
   speed, device text/build/speed, `.v` executable speed, determinism 1 job = N jobs).
2. **C1-C8**: the switch, one agent per step (switchover.md), the old pipeline deleted;
   Z1-Z3 folds as pure moves inside C5; AGENTS.md Layout rewrite at C7.
3. **F2-F13**: F3 diag gaps (726 lines; B3 after C6b), F12 the Zig layout audit at C8, F13
   the ESPice port on `dev/vera-0.30` (green with `zig build --fork=<VerA>`).
4. Release through `publish`, a PR to `main` whose required checks pass; CHANGELOG by hand,
   one line per change citing its issue, numbers measured.

## 4. External blockers and questions

- Gompute PR #5 (asinh/acosh/atanh/atan2, 2.1.0) waits on CI, blocked by the account's billing
  lock; the `v2.1.0` tag waits until every pending Gompute PR is merged.
- The conformance-suite pushes queued in `research/README.md` "Waiting on the user" (fixture
  flips, stale headers, native markers, `integer_conversion_low32.va`, strings R1-R5,
  expectations.tsv BSIM rows) are allowed (reconcile.md §6 Q6) and not yet done.
- GitHub issues for the changelog (switchover Q1) not yet filed.
- `dv1-arrays` remote branch: delete on GitHub (the session's proxy refused the delete).

## 5. Lessons from this run (keep them in the briefs)

- A planted bug that stays green is a hole in the oracle, not a pass: T12's `dt > 0` plant
  stayed green because `dyn.zig` never runs at `dt = 0` (now L11/T12b).
- Check what the oracle actually builds before trusting agreement: diff-codegen's old side is
  the `.record` display build, so §9.5 calls are the W0850 zero answer there; real I/O is a
  different mode (TD1), not a bug in TF.
- A codegen merge always needs the comp rebaseline in the same gate (§2).
- Profile before fixing: M9's cost was the fold environment rebuilt per fold, not the
  fixpoints the plan named.
