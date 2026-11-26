# Reconcile: the online bundle against the local plan

Written 2026-11-25 on `refactor` at 8a64090c. Inputs: `~/Downloads/vera-rewrite-plan.bundle`
(fetched read-only as `refs/bundle/*`) and the local plans (`research/finish.md` binds;
`zero.md`, `switchover.md` and the rest under it). This file decides what of the bundle
enters `refactor`, what new tasks its findings add to `finish.md`'s tracks, and the order
and budget rules for the rest of the work. It changes no earlier `Decision:`.

## 1. Facts

- **`refactor` is not on GitHub** (`git branch -r`: `main`, `sources/v0.23.0`,
  `field-use-limit-reads-134`). The online session could see only `main` at d26fe7f1
  (v0.23.0), the old pipeline. So its plan targets code the local plan deletes at C4.
- **The bundle holds no plan text**: 5 branches, 29 commits, tools and prototypes only. The
  online plan below is inferred from the commit messages.
- **Every bundle branch merges into `refactor` without conflict** (`git merge-tree`): it
  touches `tools/bench/`, `tools/ratchet*`, `lib/osdi_dyn/`, `lib/contract/`, `lib/diag/`,
  `src/analog/contrib.zig`, `src/prove/deps.zig`, none of which `refactor` changed since
  d26fe7f1.
- **Local work stopped 2026-11-14** (45 commits since `finish.md`, the last on 11-14).
  Lists today: 2,550 lines (comp 1,614, codegen 499, lower 345, digital_exe 47,
  digital_device 29, sim 11, rtlil 5) against 2,770 in `finish.md` F1. No S1 perf task has
  landed: M0, DV0, DV1 (= codegen T40), DV2 (= M3), M1, M2 all open. G1 is done.
- **Cost so far** (`finish.md` §4.1): about 5 M tokens per comp line, almost all cache
  reads; five Sonnet implementers hit the weekly limit in one day.
- 52 worktrees; 6 local branches hold commits `refactor` lacks
  (`field-use-limit-reads-134` 14, `worktree-agent-a90bdf84` 3, `-a472c887` 2,
  `-ae7aa119` 2, `-a3bf9683` 1, `-aa4cb601` 1).

## 2. The bundle, item by item

| Branch | What it is | Verdict | Why |
|---|---|---|---|
| `rewrite/plan` `tools/bench/` (27 files) | measurement: `bench.py` + `rtime.c` (wall, CPU, true peak RSS of `vera`), `zig_shim.py` (every `zig` child's argv, CPU, peak), `osdi_host.zig` (loads a built `.so` as a simulator does, times one transient iterate, checksums every number), `origin_census.py` (a device build's instructions by origin: device hot/cold, wrapper hot/cold, contract, std), `lib_ab.py`, `llvm_passes.sh`, `gen_models.py` (synthetic wide-N, inst-K models), `parity.py` | **take** | M0 and DV0 need exactly these; `finish.md` F9 says device speed is "not measured" and no harness exists. `osdi_host`'s checksum is an equivalence oracle between two builds of one device |
| `rewrite/plan` text rewriters: `pack_branches.py`, `roll_chain.py`, `tabulate_cold.py`, `pack_gen.py`, `shape_types.py` | prototypes that rewrite the **old** backend's emitted text | **take as evidence only** | their patterns match `src/codegen/device` output, not `src/codegen/zig`; the numbers they produced become §3's tasks; never ported, never run in CI |
| `rewrite/plan` `tools/ratchet.py` `emit-sites`, `lower-rules`, `lower-mixed` | named-violation lists over `src/analog` and `lib/diag` | **drop** | both trees are deleted at C4; the new side's codes are `diagcodes.md`'s (clause keys, one table) |
| `rewrite/plan` `tools/ratchet.py` `structure` | functions > 70 lines, nesting > 4, > 5 params, structs > 24 fields; 622 rows at d26fe7f1 | **drop** (§6 Q2) | measured: the pinned Zig's own `lib/std/zig` + aro fail it on 15.0 % of 3,302 functions (225 long, 326 deep), VerA's new modules on 7.6 % of 3,320 (284 rows). It would forbid the shapes `docs/rewrite/README.md` rule 4 says to copy |
| `proto/host-tables` (7 commits, `lib/osdi_dyn/` only) | the OSDI wrapper's stamps, parameter overlay and messages by table and loop; unrolled to 256 Jacobian entries, looped above; transient stamps skip entries with no reactive half | **take, S1** | `lib/osdi_dyn` survives (C5 renames it `lib/std/osdi`) and the new link uses it (`src/link/File.zig:451`); no ABI change; cuts the wrapper's share of every OSDI build |
| `proto/host-literals` (+1 commit) | a device may carry the host's tables as data; parameter records fill at load (`lib/contract/validate.zig`, `mock_devices.zig`) | **defer to S5**, one contract minor version with DV6 (`evalBatch`) | a contract change ESPice pins; additive, so it follows decision 9's rule; the new backend must emit the tables, which is codegen work after the switch |
| `proto/rules-area` | `lib/diag/rules/`, five contribution-context rules moved out of `src/analog/contrib.zig` | **drop the code**; the idea is input to `diagcodes.md` phase A | edits the old side, which is the oracle and read-only (`docs/rewrite/README.md` rule 2) |
| `proto/deps-worklist` | `src/prove/deps.zig` fixpoint by worklist; `--emit-zig` 334 -> 88 ms at 6,400 params, bytes identical | **drop the code; port the measurement** (task M9) | old side, read-only. The new side has the same shape: `src/Air/Legalize.zig:9` "fixpoint, no worklist", `src/Air/Setup.zig:7` one optimistic fixpoint, `src/Air/Float/Walk.zig:7` iterates to a fixpoint |

## 3. New tasks from the bundle's findings

All numbers below were measured on the **old** backend's output. Each task starts by
re-measuring on `codegen/zig` output with the imported tools; a task whose premise does
not hold there is dropped with its number, not argued.

| # | Task | Measured (old side) | Oracle | Place |
|---|---|---|---|---|
| DV-C | census: `origin_census.py` and `zig_shim.py` on `codegen/zig` builds of `tests/bench/*.va`, gen_models wide 800-3200 and inst 1000 | wrapper hot/cold share, the split build's summed peak (1,493 MiB against 513 for the largest child at 3,200 params) | none needed: it decides DV7-DV9 | S1, after the import; one research agent |
| DV7 | pack isomorphic branches: four branches computed as one chain over `@Vector`, eight packs per `noinline` function, vectors in and out | eval 953 -> 533 ns (64 branches), 4,641 -> 2,928 ns (256); device build 2.90 -> 0.97 s and 22.7 -> 4.26 s | `osdi_host` checksum identical to the scalar build (`W == 1` is the oracle); diff-codegen rows identical; DV0 eval ns | S2, after DV3 (same files) |
| DV8 | bound each emitted function: a repeated sequential stage chunked 32 stages to a `noinline` function | 1,600 params: build 2.80 -> 2.24 s, peak 272 -> 170 MiB, iterate 23,087 against 23,059 ns (within main's own 78 ns spread) | diff-codegen identical rows; DV0 build ms, peak and eval ns | S2, with DV3; before G0 (changes text) |
| DV9 | cold code (`checkRange`, `setup`) as tables and loops | slots and refusals unchanged; no time recorded | diff-codegen identical rows; DV-C's cold share | only if DV-C shows cold code a real share of build time |
| M9 | the new side's fixpoints: time `--emit-zig` CPU on gen_models wide 800/1600/3200/6400; if superlinear, queue users of a changed value instead of sweeping, keeping the sweep as the asserted reference | old side was 14, 35, 105, 335 ms, superlinear | bytes identical over the corpus; the sweep reference asserted equal in a Debug run | S2, behind air passes' current task (same files) |

Layout rules the bundle measured, binding on DV7 and DV8: a value crosses a call as one
zero-padded vector of power-of-two width; never a struct (0.8-1 % slower per iterate) and
never a 3-lane vector read back from memory (a 450-600 ns slow mode that came and went with
stack alignment, consistent with stale padding read as subnormals).

## 4. Token budget rules

The work is paced by the weekly model budget, not by the tasks. Rules, in order of effect:

1. **Make the loop cheap first.** DV1 and DV2 before any list wave: the giant device is
   ~1,450 of diff-codegen's ~1,795 s, `nested_ifs_500` is 24 MB of spaces. Every gate an
   agent waits on afterwards is shorter.
2. **One implementer at a time, plus the lead** (`finish.md` §4.1 rule 1). Never more
   than the two build slots can run.
3. **A brief is one task row.** The implementer gets: the task row, its files, its oracle,
   the exact commands, the fixture filter. It does not read `research/*.md` (9,302 lines)
   or this file. The lead writes the brief from the plan; the plan stays with the lead.
4. **Batch by root cause, never by fixture.** Pick the next task by lines cleared per
   task (`tools/xfail_classes.py`), codegen first (§4.1 rule 2). A task that clears fewer
   than ~10 lines waits until a batch of its class exists.
5. **Narrow, then gate once**: `test-<module>`, then `diff-<x> -D<x>-filter=` on the
   touched fixtures, then `tools/gate.sh` once at the end (AGENTS.md step 4). Wait on a
   gate with a Monitor, never by polling its log.
6. **Stale worktrees go.** 52 worktrees confuse agents and hold disk; prune every one whose
   branch is merged, and decide the 6 with unmerged commits (step 0).
7. **Skills per role** (§6 Q3, decided): an implementer loads `zig` and the one domain
   skill its task names; the full table in AGENTS.md is the lead's.

## 5. Order

| Step | Who | What | Exit |
|---|---|---|---|
| 0 | lead | decide the 6 unmerged branches (merge, or delete with a one-line reason); `git worktree prune` and remove merged worktrees; confirm codegen T11's state; rebaseline comp.xfail; AGENTS.md's skills-per-role line (§6 Q3) | lists re-measured; worktrees ≤ the active lanes |
| 1 | lead | merge `refs/bundle/rewrite/plan` minus `tools/ratchet*` (all four checks dropped) and `refs/bundle/proto/host-tables`; run `test`, the OSDI decks (`tools/external_analog.py`), `osdi_host` checksum old wrapper vs new on 3 devices | `tools/gate.sh` green; checksums equal |
| 2 | 1 implementer | M0 + DV0 on the imported tools: `measure` step and diff-codegen eval ns per device, record + gate by name, one probe on an emitted device | a planted 2× device fails by name |
| 3 | 1 implementer | DV1 (= T40), then DV2 | diff-codegen wall measured before/after |
| 4 | 1 research agent | DV-C census; M9's timing sweep | DV7-DV9 and M9 kept or dropped, each with its number |
| 5 | 1 implementer at a time | codegen waves (T11 rest, T13-T16, ...), then zero waves 2-3, with M1/M2 behind their lanes (`finish.md` §3 S1-S2) | F1 |
| 6 | 1 implementer | DV3, DV8, DV5, DV7 (DV0-gated: no device slower) | F7-F9 targets |
| 7 | lead + user | S3 G0, S4 switch, S5 (host-literals + DV6 as one contract minor) unchanged from `finish.md` | F1-F13 |

## 6. Decisions

- **Q1. Push `refactor` to GitHub as a branch** (user, 2026-11-25: yes). Online sessions
  then plan against the rewrite. `main` is untouched.
- **Q2. The `structure` ratchet** (user left it to the lead). Decision: **drop.**
  - For: cheap, named lists by the `vera.xfail` contract, a brake on creeping functions.
  - Against, measured: Zig's own frontend fails it twice as often as VerA's new code
    (15.0 % against 7.6 %), so it penalises the reference shapes (AstGen's and Parse's
    one-switch spines, "ifs up, fors down"); `many-parameters` (141 of 284 rows) hits
    `lib/std/kernels` math entries whose scalar arguments are the device ABI's, and the
    "caller owns memory" rule adds allocator and buffer parameters by design; every rename
    turns a row stale and fails the run, which an agent then pays tokens to fix; it is a
    line count, the measure the user struck for files; and it catches no wrong number,
    the method's main bug class.
  - What it wanted is already held elsewhere: bounded loops and recursion (`assertions`),
    one spine per pipeline (`codebase-clean-code`), review.
- **Q3. Skills per role** (user: yes). An implementer loads `zig` and the one domain
  skill its task names; the full table is the lead's. Step 0 amends AGENTS.md's "Skills
  to load first" with one line saying so.
- **Q4. Codex** (user: no). **Models** (user, 2026-11-25, replaces 2026-11-11's
  Sonnet rule): implementers run on Opus at medium effort; Fable researches; the lead
  (Opus) merges.
