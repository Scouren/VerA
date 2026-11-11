# Finish: the plan to a complete rewrite

The whole road from today to "the rewrite is done": every known-failure list
empty, the old pipeline deleted, the tree laid out as the Zig compiler is, and
the compiler and the devices it emits leaner and faster than the old ones, each
claim checked by a script. Written 2026-11-11 on `refactor` at 600440db.

Sources, each kept as its own plan: `zero.md` (the lists), `switchover.md`
(G0 and C1-C8), `builds.md` (build cost), `vpi.md`, `vbackends.md`,
`diagcodes.md`, and three sections written for this file by research agents and
appended below as written: **compiler** (VerA's own RSS and time, measured),
**device** (the emitted code's size, build cost and speed, measured) and
**architecture** (the tree against Zig's, cited). This head orders them; a task
keeps the id its plan gave it, and a `Decision:` in a plan still binds.

Two user decisions frame it:

- **Zig only** (2026-11-11). `codegen/zig` is the one device backend; there is
  no LLVM backend (`lib/TODO.md` §7). Every device-size and device-speed lever
  below works through the emitted Zig and the pinned `zig`.
- **No file-length cap.** A Zig-mirror fold is no longer blocked by a line count
  (architecture §2).

## 1. Done means

Each row is one command's exit code or one number a script prints. "Today" is
measured unless marked.

| # | Criterion | Target | Checked by | Today |
|---|---|---|---|---|
| F1 | Differential lists | every `tests/differential/*.xfail` empty | switchover G0#1 | 2,770 lines (comp 1,749, codegen 498, lower 381, digital_exe 72, sim 33, digital_device 32, rtlil 5) |
| F2 | The specification suite | `conformance` 6,818/6,818 by name on the new driver with the new VPI library; `tools/vera.xfail` empty | G0#4 | `tools/vera.xfail` empty on the old driver; 114 VPI fixtures cannot run on the new one until `vpi.md` lands |
| F3 | Diagnostic coverage of the spec | `tools/diag_gaps.xfail` empty | `tools/diag_gaps.py` (diagcodes B0-B3) | 726 lines; B3 (274) waits on C6b, so F3 closes after the switch, not at it |
| F4 | The old pipeline gone | C1-C8 landed; C8's audit printed | switchover §7 | 325,337 tracked lines in `src lib build build.zig`; projected ~123k at C8 |
| F5 | Compiler peak RSS | new ≤ old + 2 MB on every agreeing fixture, by name; ESPice models ≤ 64 MB; trivial fixture ≤ 8 MB | `measure -Dmeasure-gate` (compiler T1, T3, T7) | holds on 14 of 20 sampled; bsim4va/psp103/psp103_nqs 6-12× (Debug) |
| F6 | Compiler speed | median and p90 wall new/old ≤ 1.0 per language; ESPice models ≤ 300 ms CPU | `measure` (compiler T2, T3) | new 2-5× faster on 15 of 20; psp103/bsim4va 1.1-1.4× slower |
| F7 | Device text | every device ≤ 1.5× old and ≤ 1 MB; total ≤ half the old total | diff-codegen `-Dcodegen-gate` (device DT1, DV0) | median 7.6× smaller; 13 devices larger, 7 of them hold 85.5 % of the bytes |
| F8 | Device build cost (the `zig` child) | diff-codegen's total new build ms ≤ old; no batch over 10 s | diff-codegen summary and R3's slow lines (device DT2) | new 1,795 s against old 1,053 s; the giant's batch alone 1,450 s |
| F9 | Device speed | p90 of new/old evaluation ns ≤ 1.0 by device; no device slower versioned; zero RESIDUE, with probes on an emitted device | DV0's gate, `bench-fast`, `tools/asm_probe.py` (device DT3, DT4) | **not measured** old against new; no probe covers emitted code |
| F10 | `.v` executable speed | lfsr and cpu ≤ 2× the old native build, des and mult16 no slower than old | `tools/bench_exe.sh 5` (vbackends T3, D-N3) | lfsr 3.6×, cpu 5.7×, des 1.5×, mult16 2.5× the old native (2026-11-06) |
| F11 | Determinism | 1 job and N jobs write the same bytes | `test-link-jobs`; `measure` hash column at jobs 1 and 4 (compiler T5) | link: yes; compiler: not measured |
| F12 | The Zig layout | the tree is architecture §4's; one `codegen.generate` prong (`zig`) | C8 audit against architecture §4 | 8 departures void (architecture §2), none folded yet |
| F13 | Downstream | ESPice ported on `dev/vera-0.30`, green with `zig build --fork=<VerA>` before v0.30.0 | switchover §5.2 | not started (P12) |

F1-F2 are the switch's gate (G0). F5-F11 are checked at G0 too: G0#7 is the
`measure` report, and it should show the compiler that ships, so the perf tasks
that change no bytes land before G0 (§3). F3, F12 and the post-switch perf tasks
close after C8.

## 2. Tracks

Seven tracks. A, B, D and F change what a list or a golden sees; C and E
change no output bytes; G is the build itself. Each row: what clears, the plan that owns it, when.

### A. Correctness: the lists (`zero.md`)

| Wave | Clears | Content |
|---|---|---|
| 0 | ~90 lines; moves owners | rebaseline, hand retags (25 hidden wrong numbers, lowering's 95), rulings already decided, 34 attribution runs, 14 routings |
| 1 (running: codegen T11, lowering T21, T7→T8, air passes T1, dlower T4→T3) | ~714 | wrong numbers first; W0650's label (261 lines, one fix) |
| 2 | ~1,100 | the refusal families: contributions, events, systf, lowering codes, VPI A1 |
| 3 | ~785 | strings, random, `$sformat`, file I/O, texts and locations, VPI A2-A3 |

Sum ≈ 2,690 of 2,770; the other ≈ 80 become wave 2-3 tasks once wave 0's
attribution names them. Unplanned tasks are listed in `zero.md` (TF, T10b, T12b,
T36, T29b, T2b, TU, TE, dlower T2b, T33/T34's codegen half).

### B. The specification: conformance and diagnostics

- **VPI** (`vpi.md` V0-V10, zero.md lanes A0-A3): the 114 "not built" lines
  and F2's VPI fixtures. A3 waits on codegen T18/T20/T11/T22.
- **diag gaps** (`diagcodes.md`, zero.md "diag gaps"): B0 (46) in wave 0; B1
  (386, fixture data, through the user's suite pushes) any time; B2 (20,
  compiler ports) before the switch; B3 (274, the E1100 split) after C6b.

### C. The compiler's own cost (compiler §5)

| Task | What | Bytes | When |
|---|---|---|---|
| M0 | P4 `measure`, plus a hash column, a `lint` mode, `-Dmeasure-record`, `-Dmeasure-gate`, an in-tree baseline | none | now: every perf claim below cites it |
| M1 (+M4) | the float walk's per-branch state copies on a per-depth buffer stack; drop `iv`/`nan`/`domain` after use | identical | behind air passes T1 (same files); est. psp103 333 → ~45 MB |
| M2 | the fold environment built once per Vir file, not once per fold | identical | behind the lowering eval/param lane's current task; est. -60 % of psp103's instructions |
| M3, M3b | indentation cap; held-history cells as arrays | text | in track D as DV2 and DV1 |
| M5-M8 | text as pieces; free Sema/Float before the child; borrow the preprocessed text; unload the Ast | identical | after C8 (the peak is the `zig` child's, so these move the parent only) |

Not planned, measured out: threads in Sema or codegen, an InternPool shard, a
`--time-report` flag (compiler §3: the whole compile is ≤ 0.3 s ReleaseFast on
the worst model against 1.4-1,213 s for one `zig` child).

### D. The emitted code (device §6)

| Task | What | Bytes | When |
|---|---|---|---|
| DV0 | measure: evaluation ns per device old and new in diff-codegen, a per-device record and gate by name, probe lines on one emitted device | none | S1, with M0 |
| DV1 = codegen T40 | held-history cells and declared arrays as `[n]` slots | text | S1, first: the giant's ~1,450 s leaves every diff-codegen run |
| DV2 = compiler M3 | indentation capped at 32 levels | text | S1, after codegen T11 merges |
| DV3 | emit less: branch on the comparison, no empty `else`, no unused labels, slot reads in place | text | S2, between codegen waves |
| DV4 | fold slots whose every write is a constant (the unrolled genvar loops) | text | S2, after air passes T2/T4 |
| DV5 | one function per child module, called per instance | text | S2, after codegen wave B |
| DV6 | `evalBatch` and instance-axis `@Vector` lanes (a contract change) | text + contract | S5, only on decision 9 |

Plus the digital executable: vbackends T3 (the runtime's per-event cost in
`lib/std/sim`: the arena reset, event-row reuse, `wake`/`watch`), each commit
≥ 5 % on one bench design and none > 2 % slower; then decision point D-N3.

### E. The layout: following the Zig compiler (architecture §5)

| Task | What | When |
|---|---|---|
| Z0 | strike the text that cites the void 500-line cap | now (lead, docs only) |
| Z1-Z3 | fold `cli/` into `main.zig`, `lsp_diagnostics` into `lsp.zig`, `Compilation/{frontend,backend,errors,test,air_passes}` into `Compilation.zig` | inside C5, as pure moves (golden IDENTICAL, `vera --help` byte-equal) |
| Z4 = M6 | free Air and Float once codegen returned | after C8 (compiler §5: the peak is the child's) |
| Z5 | public-API test files out of `src/`/`lib/` into `tests/unit/` | at C3, or amend Layout at C7 (decision 6) |
| Z6 | `src/Air/Liveness.zig` (`used`/`assigned`); lanes stay in `codegen/zig` | after C7 |
| Z7 | `Type.zig`/`Value.zig` as InternPool views; `Sema.Ty` and `Sema.Value` go | after the switch and the lowering waves (touches 44 `Sema/` files) |
| Z8 (+M8) | per-file units; the Ast unloaded after AstGen and reparsed for a diagnostic | after the switch |
| Z9 | `Zcu/PerThread.zig` | **dropped**: a VerA compile is too small for threads (compiler §3); reopen only if `measure` shows VerA's own wall above its children's |
| Z10 | dependency tracking (`--watch`, LSP) | only on the user's yes (decision 7) |

Lead rulings on architecture §6 (no user call needed): fold `cli/` (item 1, yes;
`lsp.zig` imports `main.zig`); `Sema/` stays split by transform (item 3, V5 as
written); `legacy.zig` stays a file (item 6); one `codegen.generate` prong (item
7: Zig only, so there is no second Air backend to factor for); the Ast unload
waits for Z8 (item 8).

### F. The switch (`switchover.md`)

P1-P13 (additive, before G0; none landed) → G0 (8 conditions) → C1 retire the
old-side oracles → C2 flip `vera` → C3 delete old tests → C4 delete old modules
→ C5 renames (+ Z1-Z3) → C6 build cleanup → C6b + D1-D6 diagnostic codes → C7
docs → C8 audit. Every C-step: `test` green and `golden -Dgolden-against=g0`
IDENTICAL until C6b re-records.

### G. The throughput of the work itself

The build slots, not the agents, pace every wave: the full gate on
b1b9da86 took 60 min for `test` and 25 min for the longest diff step, and
six corpus steps queued behind it today. In order of effect:

1. DV1 (= codegen T40): the giant device costs ~1,450 s of every diff-codegen
   run that builds it (builds.md R3).
2. DV2 (= M3): `nested_ifs_500`'s 24 MB of indentation, compiled by a `zig`
   child on every run.
3. builds.md R8 (both sides of a diff-codegen batch built at once): merged,
   600440db.
4. decision 4 (what `test` covers): on `refactor` it runs every diff step.

## 3. The order

Five stages. At most 5 implementers at once; one corpus step per slot call.

| Stage | Runs | Exit |
|---|---|---|
| S1 now | zero waves 0-1; M0 and DV0; DV1 (= T40) and DV2 (= M3) after codegen T11 merges; Z0 | wave 1 merged; `measure` gives the first ReleaseFast numbers; compiler T3 budgets set from them |
| S2 | zero waves 2-3; VPI A1-A3; M1+M4 behind air passes T1; M2 behind the eval lane; DV3-DV5 between the codegen waves; vbackends T3; P1-P13 (additive, file-disjoint from the waves); diag B0-B2 | every list empty (F1); P-tasks merged |
| S3 G0 | the 8 G0 conditions; `measure -Dmeasure-record` writes the old side's baseline (nothing old survives C2); the report to the user (F5-F11 against targets) | the user says go |
| S4 switch | C1-C8 with Z1-Z3 in C5, Z5 at C3, C6b + D1-D6, diag B3; ESPice port (F13); tag v0.30.0 | F2, F3, F4, F12, F13 |
| S5 after | M5-M8, Z6, Z7, Z8; DV6, Z10 and D-N3 if chosen | F5-F10 re-measured against the G0 baseline |

The rule that orders S1 and S2: a task that changes no bytes lands as soon as
its files are free; a task that changes text bytes (M3, T40, the device track)
lands before G0, so g0 records the devices that ship; a task that moves files
waits for C5.

## 4. Decisions for the user

| # | Decision | Recommendation |
|---|---|---|
| 1 | Does "0 XFAILs according to the specifications" include `tools/diag_gaps.xfail` (726)? | yes, as this plan reads it: F3 closes after C6b, so 100 % is after the switch |
| 2 | M1 and M2 before G0, behind the owning lanes' current tasks | yes: byte-identical, under 50 lines each; otherwise G0's report shows a 6-12× RSS regression on every big model |
| 3 | The `measure` gate's tier: RSS + hash + status on a 100-fixture sample in `test`, the full agree list and wall nightly, the absolute budgets in `publish` | yes |
| 4 | What `test` covers on `refactor` (today: every diff step, about an hour per gate) | keep the diff steps required until G0, but as their own step, so `test` is the fast merge tier again (TESTING.md) and a gate can run them on the two slots side by side |
| 5 | The if-generate display-sites ruling (2 codegen lines; zero.md decision 2) | rule it: VAMS §6.6.2, IEEE 1364-2005 §12.4.3 |
| 6 | Public-API test files in `src/`/`lib/`: move at C3 (Z5) or amend Layout at C7 | move at C3: the Layout rule already says so |
| 7 | Dependency tracking for `--watch` / LSP (Z10) | no, unless you want `--watch` for model work: nothing measured gains from it |
| 8 | D-N3: build `Air/digital/Schedule.zig` if lfsr or cpu is still > 2× the old native after vbackends T3 | decide on T3's numbers |
| 9 | `evalBatch` (DV6): a batch entry in the device contract, so a versioned unit checks its box once per batch and lanes run along the instance axis; ESPice must adopt it | after the switch, with ESPice's agreement, measured on bench-fast first; it is the one route left to faster polynomial devices with Zig only |
| 10 | DV5: a hierarchical device calls one function per child module instead of inlining every instance | yes, gated on DV0's evaluation ns; no contract change |

---

Where a section's placement of a task differs from §3 (architecture Z4 put the
Air free before G0; the compiler measurement moved it after C8), §3 binds. The
three sections follow, with two edits: the architecture
section's LLVM mentions are struck (Zig only), and paths under `scratchpad/`
name scratch files that were not kept (re-run the commands each section gives).

## Section: the compiler's own peak RSS and speed

Research, read-only, `refactor` at ffe932dd (code identical to 48d34d67), 2026-11-11.
No `zig build` run. Zig cited as `Z/` = `~/.cache/zig-src-d924f83bf/src`.
Every number is **measured** (source named) or **est.** (estimated).

### 0. One screen

- The old compiler's own cost was measured once (2026-10-01, ReleaseFast): psp103
  29.5 MB / 117 ms CPU, hisimhv 52.1 MB / 223 ms, median fixture 5.9 MB. Nothing of
  the new compiler's own RSS or CPU had been measured before today.
- Sample today (20 fixtures, both binaries Debug, loaded machine): the new compiler is
  **about half the RSS and 2-5x faster on 14 of 20**, and **6-12x the RSS on the three
  big models that reach the Air passes** (psp103 `--lint`: 333 MB against 37 MB).
- Two profiles name the causes (psp103, new, Debug):
  - **RSS:** 320 of 341 MB are per-branch copies of the whole slot state that the float
    walk keeps in an arena until the pass ends (`src/Air/Float/Walk.zig:141,204,236`).
  - **CPU:** 64 % of all instructions rebuild one `AutoArrayHashMap(Vir.Inst.Index,u32)`
    per constant fold (`src/Sema/eval.zig:102-116` from `src/Sema/decl.zig:181-185`),
    once per parameter default, range bound and attribute: O(params^2) hashed puts.
  - **Text:** `nested_ifs_500.va` emits 24 MB of device text (old: 102 KB); it is
    indentation, 4 spaces per nesting level with no cap (`src/codegen/zig/Function.zig:171`).
- Three fixes, each under 50 lines and byte-identical in output (the third changes
  text bytes, so it is the codegen plan's and lands before G0), bring the sample under
  the old compiler on every row (est.). The targets and the gate are P4's `measure`
  with three additions (§4).
- Threads inside VerA do not pay: the whole compile is under 0.3 s ReleaseFast on the
  worst model while one `zig` child costs 1.4-1213 s (builds.md F7); the one parallel
  unit that matters, the `link` queue of children, exists.
- Binding decision (user, 2026-11-11, lib/TODO.md §7, 548780f3): VerA emits Zig only;
  `codegen.generate` keeps one prong, no `codegen/llvm` and no second Air backend. Every
  task below is on that one backend. "LLVM" in this section names only the mode the
  `zig` child compiles a device in (builds.md F7/F8), never a VerA backend.

### 1. Baseline

#### 1.1 What was measured before today

| What | Number | Source |
|---|---|---|
| old `vera --emit-zig`, ReleaseFast, peak RSS: psp103 / bsim4va / hisimhv / median of 2220 | 29.5 / 23.4 / 52.1 / 5.9 MB | `git show 15423f8c:docs/measurements/memory-2026-10-01.md` (file since deleted) |
| same, CPU (min of 15): psp103 / hisimhv | 117 / 223 ms | same |
| old, Debug, hisimhv RSS | 70.3 MB (1.35x ReleaseFast) | same |
| old, by stage on hisimhv (ReleaseFast): start / pp+lex / parse / lower / analysis / prepare / emit | 5 / 8.1 / 13.8 / 28.9 (44 transient) / 36.6 / 42.8 / 53.5 MB | same, "Where the remaining bytes are" |
| old, psp103 `--emit-zig` 15 interleaved runs: RSS / wall | 31.7 MB / 0.16-0.22 s | `git show c28f9924:docs/seams/s1-diag.md` |
| `vera-next --run` (Debug) one trivial fixture: wall / RSS | 0.30 s / 165 MB (spawns `zig build-exe`); 0.04 s warm | research/builds.md:59-60 |
| old `vera --run`, same | 0.31-0.33 s, never cached | builds.md:61, F5 |
| `vera-next` executable build, Debug | 4.6 s, 0.60 GB | builds.md:56 |
| a test may raise its process's peak RSS by at most 640 MiB | `tools/zrunner.zig:76,141` (`getrusage`, `:491`) | commit 7f91a489 |
| `--emit-rtlil` 10,000-arm else-if chain | 3.9 MB text, was 977 MB and a 5.9 GB peak | commit 7f91a489 (indent cap, `src/codegen/digital/rtlil_emitter.zig:354-358`) |
| old device text and MIR sizes per generated shape (contrib/vals/inst x 1..4096) | e.g. contrib 4096: 247,087 B, 16,386 defs | `tests/suite/SizeSweep.zig:56-80` (asserted under `zig build test`, old compiler only) |
| RAM budgeted per concurrent fixture build in the suite | 2 GiB (`job_ram`), at most 8 jobs | `tests/suite/Fixtures.zig:259-269` |
| `diff-codegen` giant device (`vera_timepoint_held_history`) | 9,725,485 B text; batch 1213 s, 4.93 GB (LLVM) | builds.md F7 |

**Unmeasured before today:** every number of the new compiler's own process (RSS, wall,
CPU, by stage); the old compiler's numbers on this Zig (0.18) and this tree; harness
(end-to-end) ratios; emitted-program speed is bench_exe/bench-fast's, not this section's.

#### 1.2 Measured today (sample)

Method: `/run/current-system/sw/bin/time -v`, one process at a time, sides alternated by
fixture index, 2 reps; RSS = max over reps, wall and user = min over reps. Text mode: `.va`
= `--emit-zig -o d.zig --no-std-defs -I include -I <dir>`; `.v` = `--elab`; ESPice models
= `--emit-zig -o d.zig -I ../ESPice/models` (`../ESPice/models/*.va`). Binaries: both
**Debug, self-hosted** (`.comment` = `zig 0.18.0-dev.349+d924f83bf`, 201 MB / 132 MB,
12 DWARF sections), built 14:37 today from `refactor` at 48d34d67:
`.zig-cache/o/5599a47d302a514f024f7b5c8b8316de/vera` (= `zig-out/gen/vera`) and
`.zig-cache/o/ac67003fd2e30ac1352081cfbbe9aafe/vera-next`. Load average 35-57 (a full
gate and five implementers): **wall is noisy; user time and RSS are not.** No zig child
is spawned in these modes. Script and TSV: `scratchpad/measure.sh`, `measure.tsv`.

| fixture | old st | new st | old RSS MB | new RSS MB | RSS new/old | old wall s | new wall s | old user s | new user s | old text KB | new text KB |
|---|---|---|---|---|---|---|---|---|---|---|---|
| ch02 analog_statement_attributes.va | 0 | 0 | 26.6 | 14.2 | 0.53 | 0.04 | 0.01 | 0.04 | 0.01 | 39 | 4 |
| ch04 multiply.va | 0 | 0 | 26.4 | 14.4 | 0.55 | 0.04 | 0.01 | 0.04 | 0.01 | 39 | 4 |
| ch03 ansi_ports.va (both refuse) | 2 | 2 | 9.9 | 4.7 | 0.48 | 0.03 | 0.00 | 0.03 | 0.00 | 0 | 0 |
| ch09 quadratic_spline.va | 0 | 0 | 27.1 | 15.0 | 0.55 | 0.06 | 0.02 | 0.06 | 0.01 | 93 | 52 |
| ch04 absdelay_history_past_capacity.va | 0 | 0 | 26.6 | 14.2 | 0.53 | 0.06 | 0.01 | 0.06 | 0.00 | 71 | 10 |
| ch05 nested_ifs_500.va | 0 | 0 | 29.5 | **83.5** | **2.83** | 0.27 | 0.35 | 0.25 | 0.28 | 102 | **23,795** |
| annex_a sum_chain_past_the_old_parser_limit.va (lower.xfail) | 0 | 1 | 53.8 | 25.9 | 0.48 | 0.23 | 0.07 | 0.21 | 0.06 | 39 | 0 |
| annex_b all_case_keywords.va (55 KB source) | 0 | 0 | 28.6 | 16.8 | 0.59 | 0.40 | 0.08 | 0.39 | 0.07 | 239 | 276 |
| ch05 vera_timepoint_held_history.va (the giant) | 0 | 0 | 27.6 | **41.7** | **1.51** | 0.05 | 0.45 | 0.04 | 0.43 | 67 | **9,498** |
| ams ch07 receiver_count_reports_ordinary_receivers.va (codegen.xfail) | 0 | 1 | 27.9 | 14.0 | 0.50 | 0.04 | 0.01 | 0.04 | 0.01 | 38 | 0 |
| spice primitive_vsine.va (codegen.xfail) | 0 | 1 | 28.8 | 14.2 | 0.49 | 0.05 | 0.02 | 0.05 | 0.01 | 58 | 0 |
| pli stmt_registration_during_call.v (new: not built, 126) | 1 | 126 | 16.5 | 12.3 | 0.74 | 0.04 | 0.00 | 0.03 | 0.00 | 0 | 0 |
| 19 conditional_compilation.v | 0 | 0 | 17.1 | 12.8 | 0.75 | 0.03 | 0.00 | 0.03 | 0.00 | 0 | 0 |
| 28 protected_eight_nested_envelopes.v (both refuse) | 1 | 1 | 13.1 | 6.5 | 0.50 | 0.03 | 0.00 | 0.03 | 0.00 | 0 | 0 |
| model vbic13_4t.va (new: codegen refuses) | 0 | 1 | 29.9 | 22.9 | 0.77 | 0.50 | 0.13 | 0.48 | 0.12 | 295 | 0 |
| model bsim4va.va (449 KB; new: codegen refuses) | 0 | 1 | 43.0 | **267.1** | **6.22** | 3.20 | 3.43 | 3.15 | 3.30 | 1,516 | 0 |
| model psp103.va (413 KB; new: codegen refuses) | 0 | 1 | 44.2 | **331.9** | **7.51** | 3.24 | 4.34 | 3.19 | 3.94 | 1,873 | 0 |
| model psp103_nqs.va (413 KB; new: codegen refuses) | 0 | 1 | 49.4 | **476.8** | **9.66** | 3.78 | 4.07 | 3.71 | 3.79 | 2,485 | 0 |
| model hicumL2_v320.va (new: Sema refuses) | 0 | 1 | 31.4 | 17.4 | 0.56 | 0.54 | 0.19 | 0.53 | 0.19 | 579 | 0 |
| model hisimhv.va (617 KB; new: Sema refuses) | 0 | 1 | 77.3 | 38.0 | 0.49 | 10.46 | 2.59 | 10.32 | 2.55 | 6,392 | 0 |

Stage split, `--lint` (front end + Sema + Air passes, no codegen) on the big ones, 1 rep:

| fixture | old st | new st | old RSS MB | new RSS MB | new/old | old user s | new user s |
|---|---|---|---|---|---|---|---|
| vera_timepoint_held_history.va | 0 | 0 | 23.9 | 38.1 | 1.60 | 0.06 | 0.30 |
| vbic13_4t.va | 0 | 0 | 25.3 | 22.4 | 0.89 | 0.12 | 0.19 |
| bsim4va.va | 0 | 0 | 35.9 | **266.3** | 7.4 | 1.50 | 4.19 |
| psp103.va | 0 | 0 | 36.7 | **332.8** | 9.1 | 2.26 | 3.42 |
| psp103_nqs.va | 0 | 0 | 40.1 | **475.9** | 11.9 | 3.16 | 5.34 |
| hicumL2_v320.va | 0 | 1 | 27.5 | 16.9 | 0.61 | 0.35 | 0.27 |
| hisimhv.va | 0 | 1 | 60.3 | 38.4 | 0.64 | 4.97 | 3.58 |

Read: on the three models where the new side reaches the Air passes, the whole excess
RSS and most of the time is already there at `--lint`; codegen adds nothing (it refuses).
On the giant, `--lint` is 38 MB and 0.30 s of the 42 MB / 0.43 s, and the text is 9.5 MB.

#### 1.3 Profiles (psp103, new, Debug; `scratchpad/prof/`)

massif `--pages-as-heap=yes` on `--lint` (peak 619 MB mapped; RSS 341 MB):

| share | bytes | site |
|---|---|---|
| 27.0 % | 176 MB | `Air.Float.Walk.condBr` `arena.dupe(Abstract, state)`: the state copy before each `cond_br` (`Walk.zig:204`) |
| 22.1 % | 144 MB | `Walk.body` block frames' `slots` (`Walk.zig:141`) and loop heads (`:236-237`), via `arm`/`condBr` |
| 3.2 % | 21 MB | `Float.analyze` gpa tables (`Float.zig:225`, per-inst `iv`/`nan`/`domain`), kept to the end |
| 41.2 % | 269 MB | one AstGen worker's 256 MiB stack mmap (`Config.stack_size`, `Config.zig:116`; `Compilation.zig:324`): address space only, not RSS |
| 5 % | 33 MB | the binary and the rest |

callgrind on `--emit-zig` (20.6 G instructions; inclusive unless noted):

| share | function |
|---|---|
| 76.5 % | `Sema.analyze` (`backend.semaAnalog`) |
| 71.3 % / 71.0 % / 70.9 % | `Sema.decl.foldBody` / `envOf` / `Sema.eval.Env.init` |
| 63.7 % | `AutoArrayHashMap(Vir.Inst.Index,u32).put` from `Env.init` |
| 36.6 % / 34.8 % / 15.7 % | callers: `param.declare` / `attr.check` / `param.checkRange` |
| 25.0 % excl. | `Wyhash.hash` + `Wyhash.init` (hashing u32 keys) |
| 4.8 % excl. | `debug.assert` (Debug only) |
| ~7 % excl. | `Air.Interval.join`, `isEmpty`, `Walk.joinAbs`, `Walk.exit` (the float walk) |

The recursive `Walk.body'2` 74.6 % inclusive is a callgrind cycle artefact; the walk's
exclusive cost is the ~7 % row, and `airPasses` is below `param.checkRange` (< 15.7 %).

### 2. Where the new compiler's memory and time go, by stage

Stages in `src/next/Compilation.zig:99-113` (`Job`), run once (`update`, `:229-243`).
Everything is freed only in `destroy` (`:197-216`): the arena (`:178`, a plain
`ArenaAllocator`), every `Unit`'s `tree` and `vir`, `analysis`, `float`, `device.text`,
the `Zcu` with its `InternPool`.

| stage | storage | layout | lifetime | verdict |
|---|---|---|---|---|
| read | raw bytes per file in the arena (`Compilation.zig:258-269`) | `[]u8` | to the end | fine; 1x source |
| preprocess | `pp.result.text` on pp's gpa (`lib/std/vams/Preprocessor.zig:103-105,288`) + a `dupeSentinel` into the arena per unit (`frontend.zig:175`) | text | both to the end | **3x the source text alive** (raw, pp, unit); <= 1.3 MB on hisimhv; H7 |
| tokenize/parse | `Ast`: tokens 5 B, nodes 13 B, `extra_data` (`lib/std/vams/Ast.zig:44-52`, asserts `:436-437`) | MultiArrayList, u32 handles | to the end (`errors.zig:51,125-135` locate diagnostics through `tree`+`vir`) | SoA, Zig-identical; Zig unloads the tree and reparses on demand (`Z/Zcu.zig:1079,1160`); H8 |
| AstGen | `Vir`: insts 9 B, `extra`, `string_bytes` (`lib/std/vams/Vir.zig:40-48`, `Vir/Inst.zig:275-280`); scratch `decl_insts`/`block_insts` `AutoHashMap(Node.Index, ...)` (`AstGen.zig:69-71`) | SoA; two maps keyed by a dense index | Vir to the end; maps per generate | maps where `[]Inst.Index` columns fit (time only, not in the top profile) |
| Sema elaborate | `Zcu`: `files`, `instances` (row-size asserts `Zcu.zig:376-378`), `instance_map`, `ports`, defparam maps (`Zcu.zig:46-70`); `InternPool`: items 5 B + `extra` + `string_bytes` + ArrayHashMap with stored hash (`src/InternPool.zig:43-53,174`) | SoA, u32 handles | to the end | fine |
| Sema lower | `Sema` fields: 22 hash maps, five keyed by `[]const u8` (`src/Sema.zig:96-100,115,132-133`); `inst_srcs` in the elaborate arena then copied to gpa (`Sema.zig:389-392`); Air via `Builder` | AoS in maps; string keys | per `analyze` | **H2 (time):** `foldBody` builds a fresh `Env` per fold (`decl.zig:181-185,274-283`), `Env.init` re-`put`s every `param` of the module into `positions` (`eval.zig:60,102-116`); called per parameter default (`param.zig:48`), range bound (`:250-251`), attribute (`attr.zig:73,94`): O(P^2) hashed inserts, 64 % of psp103's instructions |
| Air | insts 9 B + `extra` (`src/Air.zig:22-25,264,665`); `Analysis.srcs` 8 B/inst (`Sema.zig:159-176`) | SoA | to the end | fine; `Legalize` clones the Air (`Legalize.zig:305-306`) but only tests call it (`tests/differential/air_passes/examples.zig:412`) |
| Air Float | two walks over one scratch arena (`Float.zig:207-238`); per `block` a `slots` copy (`Walk.zig:141`), per `cond_br` a `before` copy (`:204`), per `loop` a `head` + frame (`:236-237`), **all on `w.arena`, never freed before the pass ends**; `Abstract` = `Interval` 24 B + `nan` = 32 B (`Interval.zig:66-73,84`); result tables `iv`/`nan`/`domain` per inst on gpa to the end (`:225,261-270`) though codegen reads `verdict` only (`backend.zig:140`); `locs` per inst in the arena (`backend.zig:98-99`) | AoS `[]Abstract` per frame | arena to the end of the pass | **H1 (RSS):** blocks x slots x 32 B x 2 walks; psp103 320 MB of 341; H6: 26 B/inst kept past use |
| codegen | `generate` arena (Liveness: three `[]bool` columns + masks, `Liveness.zig:46-50`) freed on return (`codegen/zig.zig:26-48`); the body written into an arena `Allocating` (`DeclGen.zig:164`), then printed whole into the file writer (`:174`, `:412-420` `{s}`), then `toOwnedSlice` (`zig.zig:47`) | text | body copy to the end of `generate`; text to the end | **H3 (size):** indentation 4 spaces x depth, uncapped (`Function.zig:171`, bound `nesting_max+1` `:99`): nested_ifs_500 = 24 MB of spaces; **H4:** 2-3x text alive at the peak (body buffer + out + the realloc) |
| link | `tree.zig` wants one contiguous `text` cut by unit offsets (`src/link/tree.zig:26-49`), `writeIfChanged` (`:149`); `--check`/`.so` keep `analysis`, `float`, `zcu`, `units` alive while the `zig` child runs (`backend.zig:161-220` reads only `device.text` and one instance name `:197`) | | to the end | H5: parent keeps ~30-40 MB (est.) beside a 0.3-5 GB child; peak is the child's |
| threads | `Io.Threaded`, limit = CPU count (`main.zig:84-88`), each worker a 256 MiB stack (`Config.zig:116`) | | | virtual only (massif 269 MB mapped, RSS unaffected); no task |

Hot spots against the method, ranked by measured effect:

| id | rule broken | site | measured / est. cost |
|---|---|---|---|
| H1 | arena lifetime past use; AoS copy of the whole state per branch | `src/Air/Float/Walk.zig:141,204,236-237`, `Float.zig:208-210` | 320 MB of psp103's 341 MB (massif) |
| H2 | a map rebuilt per query where a table built once fits; hashing u32 keys | `src/Sema/eval.zig:60,102-116`; `src/Sema/decl.zig:181-185,274-283` | 64 % of psp103's instructions (callgrind) |
| H3 | quadratic text in nesting depth | `src/codegen/zig/Function.zig:171` | nested_ifs_500: 24 MB text, 84 MB RSS (measured); every `zig` child pays it |
| H3b | held-history cells unrolled into scalar fields | codegen (builds.md R3, codegen.md) | the giant: 9.7 MB text, 1213 s / 4.93 GB child (builds.md F7) |
| H4 | whole-file text concatenation, 2-3 copies | `DeclGen.zig:164-176,412-420`; `codegen/zig.zig:44-47`; `link/tree.zig:26-49` | +1-2x text at the peak: giant +10-20 MB (est.) |
| H5 | a stage's tables kept through the next stage | `backend.zig:150-156,161-220` | 20-40 MB (est.) beside the child; peak unchanged |
| H6 | per-inst columns kept past their reader | `src/Air/Float.zig:225,246-255` (`iv`, `nan`, `domain`) | 26 B x insts: psp103 21 MB mapped (massif 3.2 %) |
| H7 | three copies of the source text | `Compilation.zig:258-269`, `Preprocessor.zig:103`, `frontend.zig:175` | <= 1.3 MB (hisimhv), est. |
| H8 | the Ast kept to the end for diagnostics it rarely renders | `frontend.zig:301-308`, `errors.zig:125-135` | 5 B/token + 13 B/node: 2-3 MB on psp103 (est.) |
| H9 | maps keyed by text where interned handles fit; maps keyed by dense indexes | `src/Sema.zig:96-100,115,132-133`; `AstGen.zig:69-71` | not in the top profile; no task |

Not hot: the InternPool, Ast, Vir, Air and Zcu layouts are SoA with u32 handles and
size asserts; `Liveness` lives in codegen's arena; no re-lexing on the hot path
(`tokenSlice` re-lexes one token on demand, as Zig's does).

### 3. Zig's techniques

| technique | Zig | VerA has / could | buys |
|---|---|---|---|
| InternPool layout: items `{tag u8, data u32}` + `extra` + `string_bytes`, dedup by a hash map that re-reads the key from the item | `Z/InternPool.zig:960-1000` (`Local`: per-thread append-only lists in a per-thread arena), `:1449-1460` (`Shard`: `map`/`string_map` each with a mutex), `:240` (shard = hash & (len-1)), `:7256` (`get` takes a `tid`) | has the layout (`src/InternPool.zig:43-53,174`), single-threaded by design (header); could shard | nothing: one Sema thread (below); sharding costs cache lines (`align(cache_line)`) and buys contention relief VerA never has |
| MultiArrayList everywhere a row has a tag and a payload | `Z/lib/std/zig/Ast.zig:29,33`, `Zir.zig:26`, `Z/src/Air.zig:22` | has: Ast, Vir, Air, InternPool items, Zcu files/instances/ports, Device tables | done; the remaining AoS is `[]Abstract` in the float walk (H1) |
| per-thread AstGen, Sema on the calling thread, codegen per function on workers, a link thread fed by a queue | `Z/Zcu/PerThread.zig:164` (astgen group), `Z/Compilation.zig:4398-4404` (`active.pt.update`: Sema on this thread), `PerThread.zig:2320-2324` (codegen task + `link_queue.enqueueZcu`), `Compilation.zig:4381` (`link_queue.start`) | has AstGen as an `Io.Group` of `thread_limit` (`Compilation.zig:314-333`) and a `link.Queue` of `thread_limit` child slots (`backend.zig:164-165`, `link/File.zig:184-230`); Sema and codegen single-threaded; Air is one body (`mainBody`), so there is no per-function unit to hand a worker | AstGen: nothing, a compile has one unit; codegen threads: nothing until the body is split (the split build already cuts text by parts and setup chunks, `File.zig:370-372`); **a VerA compile is not big enough for threads:** ReleaseFast psp103 117 ms CPU (2026-10) against 1.4-2 s per `zig` child (builds.md F8); after H2 the Debug compile is ~1 s (est.) |
| per-function Air and Liveness freed right after codegen | `Z/Zcu/PerThread.zig:2299` (`air.deinit` when owned), `:4533-4537` (liveness freed), `Z/Air/Liveness.zig:284` | Liveness: has (codegen arena, `codegen/zig.zig:26-28`); Air: kept to `destroy` (`Compilation.zig:204`) through `link` | H5: 20-40 MB off the parent during the child (est.); peak unchanged in text mode |
| incremental dependency tracking | `Z/InternPool.zig:44-89` (dep maps), `Z/Zcu.zig:270-276,3243-3318` (`potentially_outdated`) | no; `update` runs once (`Compilation.zig:229-243`); the reuse unit is the content-keyed artifact cache (`link/File.zig:463-471`), which the new `--run` already hits (0.04 s warm, builds.md:60) | nothing: no long-lived compiler process but the LSP (`src/next/lsp.zig`), whose inputs are one file |
| streaming output: codegen writes into the open output file piece by piece; the C backend collects buffers and `pwritev`s them | `Z/link/Elf.zig:1663,1672` (`updateFunc`/`updateNav`), `Z/link/Queue.zig:59,81,96`, `Z/link/C.zig:733,1213` | no: one contiguous text (`tree.zig:26-49`), built from a body buffer printed into a second buffer (H4) | H4: one text copy off the peak; the pieces (prologue, body, per-unit, tail) are the offsets `tree.zig` already keeps |
| `--time-report` per phase | `Z/Compilation.zig:252,358-360`; `Z/lib/std/zig/Server.zig:199` | no stage timer (`rg time-report src/next` empty) | not needed: P4's `--lint` mode gives the split (§1.2) without compiler code |
| Ast unloaded after AstGen, reparsed for an error | `Z/Zcu.zig:1072-1084` (`unloadTree`), `:1160` (`getTree`) | no (`Unit.tree` to the end) | H8: 2-3 MB on psp103 (est.) |

### 4. Targets

All per fixture **by name**, over `zig-out/comp.agree` (switchover §8.2), text mode,
ReleaseFast, through P4's `measure`. "old" = the old `vera` while it exists (before C2),
then the baseline P4 recorded from it at G0 (the only old numbers that survive C2).

| id | target | checkable now? | status in today's sample (Debug) |
|---|---|---|---|
| T1 | new peak RSS <= old peak RSS + 2 MB on every agreeing fixture (2 MB = huge-page swing, 2026-10 doc) | yes, after P4 | holds on 14 of 20 (0.48-0.77x); fails on nested_ifs_500 (2.8x), the giant (1.5x), bsim4va/psp103/psp103_nqs (6-10x); est. all pass after M1-M3 |
| T2 | median and p90 of wall new/old <= 1.0 per language (verilog-a, verilog-ams, spice, verilog), paired, order-alternated (switchover Q13) | yes, after P4; wall gated only with both slots idle | new 2-5x faster on 15 of 20; 1.1-1.4x slower on bsim4va/psp103 (H2); est. pass after M2 |
| T3 | absolute, largest models (`../ESPice/models`, ReleaseFast): peak RSS <= 64 MB, CPU <= 300 ms each (old: 52 MB / 223 ms on hisimhv) | **not until P4 has run once** on ReleaseFast builds; provisional numbers | psp103 332 MB Debug today |
| T4 | device text: new <= 1.5x old bytes per agreeing fixture; <= 1 MB for any conformance fixture (codegen plan rulings excepted, named) | yes, from `measure`'s `out_bytes` column | nested_ifs_500 233x, the giant 142x; all_case_keywords 1.15x |
| T5 | determinism: `measure` sha256 of every written output identical between `-Dmeasure-jobs=1` and `4` (AGENTS.md) | yes, after P4 adds the column | not measured |
| T6 | harness mode (end to end, children included): p90 wall ratio <= 1.0 | **not until P4**: the child dominates and only the new side caches `--run` (builds.md F5) | not measured |
| T7 | floor: a trivial fixture <= 8 MB ReleaseFast (old median 5.9 MB) | after P4 | 14.2 MB Debug new, 26.6 MB Debug old |

What P4 must add to switchover §8.2 for these to be a gate:

| addition | why |
|---|---|
| a `sha256` (or 64-bit) column of the written output per row (`d.zig`, `--elab` stdout) | the byte oracle for every perf task: a refactor's run must show identical hashes and better ratios in one TSV |
| `-Dmeasure-mode=lint` beside `text` and `harness` | the stage split (front end + Sema + passes vs codegen) with no compiler flag |
| `-Dmeasure-record=<path>`: writes the baseline TSV with a provenance header (commit, Zig, optimize, machine, both slots idle or not) | the old side's numbers must be recorded once at G0; after C2 there is no old binary |
| `-Dmeasure-gate=<baseline.tsv>`: compares by fixture name; fails on status mismatch, hash mismatch, RSS > budget (baseline x 1.25 + 2 MB), text bytes > budget; wall and CPU reported, gated only when the header says both slots were idle | T1, T4, T5 are machine-checkable; wall is noisy on a shared machine (Q13) |
| the baseline file in the tree (`tests/measure/baseline.tsv`, like `SizeSweep`'s `expected`) | "a release ships on numbers a script checks" (AGENTS.md); `publish` re-measures |
| the top-10 worst RSS and wall ratios by name (already in §8.2) | the report to the user at G0#7 |

Tier: RSS + hash + status over a 100-fixture sample (`-Dmeasure-sample`) in `test`
(~1 min, est.: one process per fixture at 0.01-0.5 s); the full agree list and wall in
`nightly`; T3 absolute budgets in `publish`.

### 5. Tasks, in order

Each: files, mechanism, effect, oracle, place. "Byte-identical" = diff-comp/golden
IDENTICAL plus identical `measure` hashes. Collisions use research/zero.md's shared
files (`Sema.zig`, `discrete.zig`, `backend.zig`, `DeclGen.zig`, zero.md:105-107) and
lane files (eval/param lane zero.md:391; airpasses T1/T5 on Float).

| # | task | files | mechanism | effect | oracle | place |
|---|---|---|---|---|---|---|
| M0 | P4 `measure` + the §4 additions | `tests/differential/measure.zig` (new), `build/rewrite_comp.zig`, `tests/differential/comp.zig` (`report` writes `.agree`) | switchover §8.2; rows `fixture u32, mode u1, side u1, status u8, wall_us u32, cpu_us u64, rss_kb u32, out_bytes u32, hash u64`, `comptime assert(@sizeOf(Row) <= 32)` | the numbers §1 lacks, ReleaseFast | §8.6: RSS within 5 % of GNU `time -v` on three fixtures; a planted +1 byte in one output fails the gate by name | before G0 (it is G0#7) |
| M1 | float walk: free the per-branch state copies | `src/Air/Float/Walk.zig:87,141,204,236-237`, `Float.zig:208-210` | a stack of reusable `[]Abstract` buffers, one per nesting level (bounded by `nesting_max`), pushed on `block`/`cond_br`/`loop` entry and popped on exit; `before`/`head`/`slots` come from it, never from the arena | psp103 `--lint` 333 MB -> ~45 MB, psp103_nqs 476 -> ~55 MB, bsim4va 266 -> ~40 MB (est.: massif puts 320 of 341 MB at these sites); time -5-10 % (est., the memsets) | byte-identical: diff-air/air-passes goldens, the W0650 verdict set, `measure` hashes; `Air.Verify` in Debug | before G0, after airpasses T1 lands (same files) or by its agent |
| M2 | Sema: build the fold environment once per unit | `src/Sema/eval.zig:60,102-116`, `src/Sema/decl.zig:181-195,274-283` | `positions` becomes a dense `[]u32` column over `Vir.Inst.Index` (sentinel for non-params) built once per Vir file and cached on `Zcu.File`; `envOf` then only `memcpy`s the instance's values; or one `Env` per `Unit`, reset (`genvars`, `busy`, `trail`, `pending`) between bodies | psp103 Debug: -60 % instructions (callgrind: 64 % in `positions.put`), lint 3.4 s -> ~1.3 s (est.); ReleaseFast CPU below the old's 117 ms (est.) | byte-identical: diff-lower, diff-comp, `measure` hashes | before G0, after the lowering eval/param lane's current task (zero.md:391) lands; 2 files, ~30 lines, the lowering owner |
| M3 | cap codegen indentation | `src/codegen/zig/Function.zig:171` (+ `:41,99`) | `for (0..@min(f.indent, max_indent))`, `max_indent = 32`, as `src/codegen/digital/rtlil_emitter.zig:354-358` (commit 7f91a489) | nested_ifs_500 text 24 MB -> ~1 MB, RSS 84 -> ~20 MB (est.); every `zig` child's parse time down | **changes text bytes**: diff-codegen device rows identical (numbers), `zig fmt --check`-neutral is not required; goldens re-recorded by the codegen owner | before G0, codegen plan (DeclGen/Function are its wave files) |
| M3b | held-history cells as arrays (builds.md R3's source fix) | codegen plan's task; `src/codegen/zig/state.zig:45-47` names the unrolled fields | `[n]f64` per held cell instead of `__held__k` scalars | the giant 9.7 MB -> ~0.2 MB text (est.), child 1213 s -> seconds (builds.md R3) | diff-codegen rows identical; `measure` out_bytes | before G0, codegen plan |
| M4 | drop `iv`/`nan`/`domain` after `rate` (H6) | `src/Air/Float.zig:225-233,246-255` | allocate the three per-inst columns in the scratch arena; `Float` keeps `verdict` and `error_count` only | -26 B x insts (psp103 ~20 MB mapped, est.) | byte-identical; nothing outside `Float.zig` reads `iv`/`nan`/`domain` or `finite()` (`rg` over `src/codegen`, `src/next`: only `verdict`, `backend.zig:140`) | with M1 (same files) |
| M5 | codegen text as pieces (H4) | `src/codegen/zig.zig:44-47`, `DeclGen.zig:164-176,412-420`, `src/link/tree.zig:26-49,149`, `backend.zig:552-558` | `link.Output` = prologue, core body, tail slices (the offsets `tree.zig` keeps today), written in sequence (`writeAll` x 3 or `writev`); no `{s}` of the body into a second buffer | -1x text at the peak: giant -10 MB, typical -5 KB (est.); after M3/M3b the texts are small | byte-identical on disk (`measure` hash, golden) | after C8 (DeclGen is a codegen wave file; low value after M3) |
| M6 | free Sema/Float after codegen for `check`/`so`/`exe` (H5) | `src/next/Compilation/backend.zig:150-156,197`, `Compilation.zig:197-216` | `analysis.deinit`, `float.deinit` once `comp.device` is set; dupe the top name into the arena first | parent -20-40 MB during the child (est.); peak unchanged | byte-identical | after C8 |
| M7 | borrow the preprocessed text instead of duplicating it (H7) | `frontend.zig:175`, `Compilation.zig:131-138` | `Unit.text` = `pp.output().text` (pp outlives units) | -1x preprocessed text (<= 0.6 MB, est.) | byte-identical | anywhere; trivial |
| M8 | unload the Ast after AstGen, reparse for a diagnostic (Zig `unloadTree`/`getTree`) | `frontend.zig:301-308`, `errors.zig:51-54,125-135`, `Compilation.zig:197-203` | `tree.deinit` after a clean `generate`; `errors.bundle` reparses `Unit.text` when a located diagnostic needs it | -2-3 MB on psp103 (est.); a reparse only on the error path | byte-identical; diag goldens | after C8 |
| M9 | H9 maps | `src/Sema.zig:96-133`, `AstGen.zig:69-71` | not now: below the profile's threshold; revisit if P4's CPU column says otherwise | | | none (YAGNI) |

Not tasks: threads in Sema/codegen (§3), an InternPool shard, a `--time-report` flag,
a BigArena for the compilation arena (its contents are read bytes and small outputs;
the big tables are on gpa already), stack sizes.

### 6. For the user

1. **Place of M1 and M2.** Both are byte-identical and under 50 lines, but they touch
   wave files (Float; eval/param). Recommendation: land each right behind the owning
   lane's current task, before G0, so the §8 report at G0#7 measures the compiler that
   ships; else the report shows a 6-12x RSS regression on every big model.
2. **T3's absolute budgets** are provisional (64 MB / 300 ms on the ESPice models) until
   P4 runs once on ReleaseFast builds with both slots idle; the lead sets them from that
   run.
3. **Gate tier.** RSS + hash on a sample in `test`, wall nightly (§4). Yes or no.
4. The codegen plan's text-size rulings (M3, M3b) change device bytes and so land before
   G0; the giant's fix is already builds.md R3's.

## Section: the device code (size, build cost, speed)

Research, `refactor` at 548780f3, 2026-11-11. The sweep is f-device's (it stopped at
its usage limit after the sweep finished); the lead read the tail and wrote this
section. Every number is **measured** (source named) or **est.** Zig only: every
lever works through the emitted Zig and the pinned `zig`.

### 0. One screen

- The median device is **7.6× smaller** than the old one (5,580 B against 42,453 B;
  p90 of new/old 0.23), mostly the ~31 KB of kernels a device now imports from
  `std_kernels` instead of carrying. 1,308 of the 1,321 devices both sides emit are no
  larger.
- **Seven devices hold 85.5 % of the new side's bytes** (59.6 of 69.7 MB) and the
  giant alone about 1,450 s of diff-codegen's 1,795 s build time. Without the giant
  the new side builds in about a third of the old's time.
- Four causes, all in the emitted text, none a Zig limit: unbounded indentation;
  array and held-history cells emitted as one scalar each; unrolled genvar loops
  that the old compiler folded or kept small, plus three-statement branch conditions
  in every unrolled copy; every child instance's body emitted in line.
- **Nothing measures device evaluation speed old against new.** diff-codegen times
  builds, not evaluations; bench-fast compares strict and fast on the new side only,
  over five small devices; none of the 13 assembly probes covers emitted device code.

### 1. Measured

Sweep: `--emit-zig` on every analog fixture (2,851 `.va` under
`tests/conformance/tests/{verilog-a,verilog-ams,spice}`), text only (no `zig`
child), both binaries Debug from 48d34d67, one niced process (f-device's
`sweep.sh`, `analyze.py`; scratch, not kept).

| | old | new |
|---|---|---|
| fixtures emitted | 1,884 | 1,401 (1,321 by both) |
| bytes, both emitted | 71,046,121 | 69,672,040 |
| median bytes | 42,453 | 5,580 |
| new/old per device | | p50 0.131, p90 0.232, max 233 |
| emit wall, both emitted (Debug, loaded) | 117,353 ms | 40,629 ms |
| devices ≥ 768 KiB (`link.split_min_bytes`) | 2 (12.0 MB) | 7 (59.6 MB, 85.5 %) |
| new > old | | 13 devices; 12 of them ≥ 100 KiB |

Build cost (the last full diff-codegen run, 2,895 fixtures, 1,275 devices built and
compared, 0 failures; lead's brief): old 1,052,882 ms, new 1,794,764 ms in total;
the giant's batch 1,449,486 ms new against 202 ms old (builds.md R3). The new side
without that batch: about 345 s.

### 2. The tail, by cause

Leading-space bytes measured by counting each line's indentation in the emitted file
(the lead re-emitted these with the same binary).

| Device | old B | new B | indentation | Cause | Fix |
|---|---|---|---|---|---|
| `nested_ifs_500` | 104,515 | 24,366,460 | 24,076,204 (98.8 %) | 4 spaces per nesting level, no cap (`src/codegen/zig/Function.zig:171`) | DV2 |
| `sequential_ifs_10000` | 3,142,021 | 12,468,028 | 2,960,180 (24 %) | a 10,000-step genvar loop unrolled, as the old did, but ~1,250 B per step against ~314: the condition takes three statements (`@intFromBool(cmp)`, `!= 0`, `if (v != 0)`: 2.84 MB), an empty `else { break :b; }` per `if`, a slot copy `const v = s0;` per read (0.38 MB) | DV2, DV3 |
| `generate_loop_4097_instances` | 8,881,611 | 10,138,355 | 1,704,468 | 4,097 instances of one child module, each body emitted in line (90,136 values); the old did the same | DV5 |
| `vera_timepoint_held_history` (the giant) | 68,559 | 9,725,485 | 1,477,400 | each held-history cell its own field and its own straight-line code (codegen T40) | DV1 |
| `multidimensional_array` | 41,904 | 1,277,489 | 71,372 | `real vtable[0:16][0:7][0:64]`: 8,840 cells, one scalar slot and one `_ = &s;` line each | DV1 |
| `genvar_loop_4097_iterations`, `_at_unroll_limit` | 39,722 | 793,899 / 793,699 | 98,496 | `x = x + 1.0` unrolled 4,097 times, three lines per step; the result is a constant the old folded | DV4 |

The smaller "new > old" devices (1.1-1.7×: `all_case_keywords`, `all_escaped_keywords`,
`vera_scratch_uninit_tape`, `primitive_ipwl`, `primitive_ipulse`,
`erfc_as_an_analog_function`) are the same patterns at smaller scale; DV2 and DV3 are
expected to bring them under (est.).

### 3. Speed: what exists and what does not

| Question | Answer |
|---|---|
| old vs new evaluation time | **not measured anywhere.** diff-codegen evaluates both devices at 1,000 points and compares values (`tests/differential/codegen.zig`); its summary carries bytes and build ms only (`:274`) |
| strict vs fast | `zig build bench-fast` (`build/rewrite.zig:193-228`): new devices of `tests/bench/{abs,diode,mos_exp,mosfet,tanh_amp}.va`, median of 101; fails a device slower versioned. Recorded: diode strict 5.8 ns, versioned 4.4 ns; MOSFET strict 6.5 ns (lib/TODO.md, 2026-11-06) |
| assembly probes | 13 `expect:` lines in `tests/codegen_probe.zig`: fills, lexer and preprocessor scans, logic kernels, the old `kernels` module's limit clamps. **None on an emitted device**: no claim that the `S` family's methods (`S.con`, `.add`, `F.zTo`) fold to plain float operations is backed by a probe |
| large models | psp103, bsim4va, vbic and hisimhv do not reach a built device on the new side yet (compiler §1.2: codegen or Sema refuses), so no speed number exists for them on either path |

### 4. Levers

| Lever | Verdict | Why |
|---|---|---|
| cells as arrays (T40, declared arrays) | do (DV1) | the giant and `multidimensional_array`; build time is roughly linear in text (builds.md) |
| indentation cap | do (DV2 = compiler M3) | 24 MB of spaces on one device; the RTLIL emitter already caps at 32 (`src/codegen/digital/rtlil_emitter.zig:354-358`) |
| emit less per statement | do (DV3) | branch on the comparison, drop empty `else`, drop labels with no `break`, read a slot in place: every device, and the zig child parses all of it even when LLVM deletes it |
| constant propagation through slots | do (DV4) | a slot whose every write is a constant folds; the old did it |
| one function per child module, called per instance | do (DV5) | Zig emits a function once and calls it (`Z/codegen.zig:154` `generateFunction` per function); text stops scaling with the instance count |
| comptime generic over the host family `S` | have | units are `fn u(comptime S: type, …)` (lib/TODO.md §7); ESPice instantiates its family |
| Liveness-driven dead stores | have, partly | `src/codegen/zig/Liveness.zig` (`used`, `assigned`); architecture Z6 moves it to `Air/` after the switch, no new effect claimed |
| dispatch per batch: `evalBatch(S, xs, …)` over one model's instances | **contract change, decision** | the entry check of a versioned unit runs once per batch, so polynomial devices can be versioned again (lib/TODO.md: MOSFET versioned per point was slower); ESPice evaluates per point today |
| `@Vector` lanes along the instance axis, `W == 1` the scalar oracle | after `evalBatch` | needs the batch entry; the family already has `batch_ok` and a vector `V` |
| `link.split_min_bytes` (768 KiB, `src/link/File.zig:140`) | leave | after DV1-DV5 no conformance device is expected above it (est.); splitting adds link work, not less |
| float mode | leave | strict units are W0650's soundness verdict (1,056 of 1,556 roots `.optimized`); per-operation flags have no route without an LLVM backend (lib/TODO.md §7) |

### 5. Targets (by device name, checked by script)

| id | Target | Needs |
|---|---|---|
| DT1 | every device's bytes ≤ 1.5× old and ≤ 1 MB; total new bytes ≤ half the old total | diff-codegen's per-device bytes by name (DV0) |
| DT2 | diff-codegen's total new build ms ≤ old; no batch over 10 s in the "slow" lines | the existing summary and R3's slow lines |
| DT3 | p90 of new/old evaluation ns per device ≤ 1.0 | **new: DV0** |
| DT4 | zero RESIDUE in the probes, including new probes on one emitted device | **new: DV0's probe lines** |
| DT5 | bytes, build ms and eval ns per device recorded per release and compared by name | DV0's record and gate |

### 6. Tasks, in order

| # | Task | Files | Effect | Oracle | Place |
|---|---|---|---|---|---|
| DV0 | measure: diff-codegen times each side's evaluation (min of k runs over its 1,000 points) and writes bytes, build ms and eval ns per device to a TSV; `-Dcodegen-record` and `-Dcodegen-gate=<baseline>` compare by name; `codegen_probe` builds `tests/bench/diode.va`'s new device and holds `eval` to `expect:` lines (no call left to an `S` method, no memset) | `tests/differential/codegen.zig`, `tests/codegen_probe.zig`, `tools/asm_probe.py`, `build/rewrite.zig` | DT3-DT5 become checkable; G0's report gets device numbers | a planted 2× slower device (a doubled loop in one fixture's runner) fails the gate by name; a probe line goes red on a planted `noinline` | S1, with compiler M0 |
| DV1 = codegen T40 | held-history cells and declared arrays as `[n]` slots, indexed in a loop | `src/codegen/zig/{state,Function,DeclGen}.zig` | giant 9.7 MB → ~0.2 MB (est.), its batch ~1,450 s → seconds (builds.md R3); `multidimensional_array` 1.28 MB → ~45 KB (est.) | diff-codegen bit for bit on every held-history and array fixture; bytes and build ms from DV0 | S1, first: every corpus run gets faster |
| DV2 = compiler M3 | indentation capped at 32 levels | `src/codegen/zig/Function.zig:41,99,171` | `nested_ifs_500` 24.4 → ~0.3 MB; 15-24 % off every deep device (measured shares above) | diff-codegen rows identical; bytes | S1, after codegen T11 merges |
| DV3 | emit less: branch on the comparison, no empty `else`, no unused labels, slot reads in place | `src/codegen/zig/Function.zig` (and `ops` for the condition) | `sequential_ifs_10000` 12.5 MB → ~5 MB (est.); a few % on every device (est.) | diff-codegen rows identical; DV0 bytes, build ms and eval ns (no slower) | S2, between codegen waves (same files) |
| DV4 | fold slots whose every write is a constant | an Air pass beside `src/Air/Setup.zig` (air passes owner), or Sema's fold | `genvar_loop_*` 794 KB → ~5 KB (est.) | diff-air-passes, diff-codegen identical rows | S2, after air passes T2/T4 |
| DV5 | one function per child module, called per instance with its parameters | `src/codegen/zig/{DeclGen,Function}.zig`; Sema's instance table read as data | `generate_loop_4097_instances` 10.1 → ~0.2 MB (est.); evaluation cost: one call per instance, inlined or not by LLVM (DV0 measures) | diff-codegen identical rows; DV0 eval ns no slower | S2, after codegen wave B (T18 contributions edit the same emission) |
| DV6 | `evalBatch` and instance-axis `@Vector` lanes | `lib/contract.zig`, `lib/contract/family.zig`, `src/codegen/zig/DeclGen.zig`; ESPice's loader | polynomial devices versioned again; lanes per batch (est.; nothing measured) | `W == 1` against `W == 4` bit for bit; bench-fast; ESPice's own decks | S5, only on the user's yes and ESPice's agreement (a CHANGELOG contract line) |

DV1-DV5 change device text, not numbers, so they land before G0: g0 then records the
devices that ship (switchover §3.2).

### 7. For the user

1. **`evalBatch` (DV6)** is a contract change ESPice must adopt; it is the only
   route left to faster polynomial devices with Zig only. Recommendation: after the
   switch, with ESPice's agreement, measured first on bench-fast.
2. **DV5** changes how a hierarchical device is laid out (a call per child instance).
   No contract change; recommendation: do it, gated on DV0's eval ns.

## Section: the target architecture, after the Zig compiler

Research only (branch `refactor`, read-only; no build run). Zig cited from the pinned
source `~/.cache/zig-src-d924f83bf` (`Z/` = its `src/`, `S/` = its `lib/std/zig/`,
`C/` = its `lib/compiler/`). VerA cited from the tree as of this reading. Line
counts are `wc -l`.

Two facts frame everything below:

- The user dropped the ≤500-code-line rule (`research/README.md` "No file-length
  cap"); `tools/check_style.py` no longer carries it. Every departure from Zig
  that cited that rule is void.
- Zig's own `update` runs Sema on the calling thread (`Z/Compilation.zig:4400-4402`
  `active.pt.update`); only AstGen (`Z/Zcu/PerThread.zig:164` `astgen_group`) and
  per-function codegen (`:2320` `codegen_task_pool.start`) are parallel. "Mirror
  Zig" never means "parallel Sema".

### 1. The map today

| Zig stage | Zig (file:line) | VerA counterpart | Fidelity | Where it departs |
|---|---|---|---|---|
| `std.zig` namespace | `S/../zig.zig:20-33` (ErrorBundle, Token, Tokenizer, Ast, AstGen, Zir) | `lib/std/vams.zig:14-24` (tokenizer, Ast, Preprocessor, Diag, spice, Vir, AstGen, SysFn) | mirrored | adds Preprocessor (aro's), spice, SysFn (`S/BuiltinFn.zig`), `.vams` preludes: VAMS needs them |
| Tokenizer | `S/tokenizer.zig:3-5` `Token{tag, loc}` | `lib/std/vams/tokenizer.zig` (686) `Token`, `Tokenizer` | mirrored | keyword sets per dialect |
| Ast + Parse | `S/Ast.zig:18-22` `source, tokens, nodes, extra_data`; `:149 parse`; `S/Parse.zig` | `lib/std/vams/Ast.zig` (774) + `Ast/{full,errors,sites}`; `Parse.zig` + `Parse/` (9 files) | mirrored | `Ast/sites.zig` (VPI sites) has no Zig twin |
| AstGen → Zir | `S/AstGen.zig:143 generate(gpa, tree) Zir`; `S/Zir.zig:26-36` instructions/string_bytes/extra | `lib/std/vams/AstGen.zig` + `AstGen/` (10) → `Vir.zig` + `Vir/Inst.zig` (622): instructions, extra, string_bytes | mirrored | — |
| ErrorBundle | `S/ErrorBundle.zig:70-75` (msg, count, src_loc, notes; no code) | `lib/std/vams/Diag.zig` + `Diag/codes.zon` (10,764) | mirrored + a code column | coded diagnostics are AGENTS.md policy (diagcodes §8) |
| Compilation | `Z/Compilation.zig:1714 create`, `:2751 update`, `:2582 destroy`, `:3829 getAllErrorsAlloc`, `:4360 performAllTheWork`; `:55 io`, `:244 mutex`; `src/Compilation/` holds only `Config.zig` | `src/next/Compilation.zig` (342): `create :170`, `update :229`, `destroy :197`, `getAllErrors :247`, one reader `read :258`/`realPath :274`; `Config.zig` (125) | partly | split into `Compilation/{backend 615, frontend 401, errors 176, legacy 81, libmap 1010, test 194}.zig`; `update` "Runs once" (`:228`), Zig's is per generation |
| the job queue | Zig has no serial job list: `misc_group`/`prelink_group` `Io.Group`s (`:4378-4379`, `:4428`), `QueuedJobs` is prelink flags (`:285`), Zcu work via `pt.update` (`:4402`), a `link.Queue` (`Z/link/Queue.zig:96 enqueueZcu`, `:147 finishZcuQueue`) | `queue: ArrayList(Job)` + `next_job` (`:62-64`), `Job` union of 12 tags (`:100`), `runJob :294` serial, `astgenBatch :314` an `Io.Group` | partly | a serial list is simpler than Zig and right for one unit; it is the seam a `PerThread` would open (§3a) |
| thread pool | `Z/main.zig:180-181` `Io.Threaded` with `thread_stack_size :41` (60 MiB); `:3553-3557 thread_limit`/`setThreadLimit` | `src/next/main.zig:35` `Io.Threaded` with `Config.stack_size` (256 MiB); `:82-86` `thread_limit`, `concurrent_limit = thread_limit - 1` | mirrored | — |
| Zcu | `Z/Zcu.zig:177 intern_pool`, `:956 File` (`status`, `source :990`, `tree :992`, `zir :994`, `unload :1072-1093`), `:863 Namespace`, `:276-279 potentially_outdated/outdated`, `:347 codegen_task_pool` | `src/Zcu.zig` (508): `intern_pool :50`, `files :51` (MultiArrayList), `modules :54`, `instances :64` + `instance_map :66` (generic-instance key), `failed :83` | partly | `File` holds `vir` only; source and tree live in `Compilation.units` (one unit per compilation, `frontend.zig:172` `ponytail:`); no outdated maps, no generation |
| Zcu.PerThread | `Z/Zcu/PerThread.zig:39-45` `{zcu, tid}`; `:356 workerUpdateFile`; `:460 updateFile` (ZIR cache by stat/hash); `:2195 ensureFuncBodyUpToDate`; `:4449 runCodegen` | none | missing | `Compilation.astgenBatch` is the one `Io.Group`; sema, passes, codegen, link run on the update thread, as Zig's Sema does |
| InternPool | `Z/InternPool.zig:3945 Index`, `:1964 Key`, `:1726 String`, `:7256 get(ip, gpa, io, tid, key)` over `:23 locals`/`:26 shards`, `:101 single_threaded`; deps `:137 TrackedInst`, `:422 AnalUnit`, `:746 Dependee`, `:828 addDependency` | `src/InternPool.zig` (694): `Index :52`, `String :78`, `Key :82`, `get(ip, gpa, key) :260`; header says "single-threaded" | partly | no shards, no dependency tables: both only matter with §3a/§3e |
| Sema | `Z/Sema.zig:46 code: Zir`, `:47-48 air_instructions/air_extra`, `:1030 analyzeFnBody`, `:125-128 dependencies`; `Z/Sema/` = 5 files (arith, comptime_ptr_access, LowerZon, reinterpret, type_resolution) | `src/Sema.zig` (563): `air: Air.Builder :4`, `elaborate`, `analyze`; `src/Sema/` 96 files, 28,277 lines; `src/sema.zig` (64) re-export root; `Sema/eval.zig` = `resolveConstValue` | partly | one `Air` for the whole design ("lowered flat", `Air/Device.zig` header), Zig has one per function; the 96-file split is lower.md D1 (void as a rule, §2) |
| Type / Value | `Z/Type.zig:20 ip_index`, `:725 fromInterned`, `:730 toIntern`; `Z/Value.zig:19`, `:134`, `:139` | none as files. `Air.typeOf :612` returns `InternPool.Index` (mirrored); `Sema.Ty = enum(u8){real, integer, string}` (`Sema.zig:128`), `Sema.Value{ref, ty}` (`:190`), `Sema.digital.Type` a third | missing | three type representations; `Ty` cannot name `InternPool.Key.IntType{bits, signed}` or `ArrayType` (codegen.md risk 5: "`Sema.Value` gains signedness and width") |
| Air | `Z/Air.zig:22 instructions`, `:25 extra`, `:34 Inst`, `:1904 deinit` | `src/Air.zig` (703): `instructions :72`, `extra :74`, `Inst`, `Builder`, `deinit` | mirrored | slots not phis (lib/TODO §11.7), as Zig |
| Air passes | `Z/Air/{Legalize,Liveness,print,Verify}.zig`; Liveness `:142 analyze`, optional per backend (`Z/codegen.zig:92 wantsLiveness`, run at `PerThread.zig:4533` after `legalize :4527`, freed `:4537`) | `src/Air/{Legalize,print,Verify}.zig` mirrored; `Liveness` lives in `src/codegen/zig/Liveness.zig` (314); VerA-only `Air/{Interval,Float,Setup,Device,interp,tan}.zig` | partly | Liveness inside the backend (§3c); analog passes have no Zig twin |
| codegen | `Z/codegen.zig:154-160 generateFunction(lf, pt, func, air, liveness)` → `switch (backend)` (`:31, :51, :116, :133`), `:104 AnyMir`; `Z/codegen/{c,llvm,wasm,x86_64,…}.zig` | `src/codegen.zig` (119) `generate(gpa, backend, Input, Options) Result{ok: link.Output, fail}`; `Backend = enum { zig }`; `codegen/zig.zig` + `zig/{DeclGen, Function, Liveness, …}` (`c.zig`'s shape) | partly | the dispatch has one prong; `bench`, `digital_next`, `rtlil` are entry points `Compilation/backend.zig` calls directly, not prongs (§6 item 7) |
| link / link.File | `Z/link.zig:397 File`, `:532 open`, `:556 createEmpty`, `:939 destroy`, `:975 flush(base, arena, tid, prog_node)`; tasks in-process (`:1512 link_func`, `:1827 codegen_task.wait`) | `src/link.zig` re-exports; `link/File.zig` (646) `flush(f, gpa, io, q, device, generation)`, `Task` union; `Queue.zig` (89) bounds `zig` children; `Server.zig` = `std.zig.Server` client | mirrored in name | tasks are `zig` child processes: VerA's backend emits Zig source, so "link" is "compile the text" |
| main.zig | `Z/main.zig:166 main`, `:277 mainArgs` (command dispatch), `:918 buildOutputType` (argv parsed inline, ~2.6k lines), `:5592 cmdAstCheck` | `src/next/main.zig` (227) `main`/`drive`; argv in `cli/{args 682, Options 103, usage 133}.zig`; `lsp.zig` (502), `lsp_diagnostics.zig` (203) | partly | `cli/` split and `lsp_diagnostics` split are the 500-line departures (§2); LSP itself has no Zig twin (zls is separate) |
| lib/compiler | `C/` = aro, `Maker.zig` (build runner), `test_runner.zig`, reduce, objcopy, translate-c | nothing; `tests/*.zig` roots and `tools/*.py` | not applicable | VerA ships no build runner |
| lib/std beyond the frontend | `lib/std` (the language's std), `lib/compiler_rt` | `lib/std/kernels` (9,915 lines, 23 files) = compiler_rt + std.math; `lib/std/sim` (16,106, 49 files) = runtime of emitted exes; `lib/contract`, `lib/osdi_dyn` | VerA-specific | real departure: VerA emits source a host compiles (switchover §11) |

Note for switchover §11's "not yet in the tree at C8" row: `Compilation/libmap.zig`
is in the tree now (`src/next/Compilation/libmap.zig`, 1,010 lines); the C8 audit
row should drop it. Still absent: `Zcu/PerThread.zig`, `Type.zig`, `Value.zig`,
`Discipline.zig`, `codegen/{verilog,vpi,osdi}.zig`, `lib/vpi/`, `src/vpi_host.zig`,
`Air/Liveness.zig`.

### 2. Departures that are now void

Every departure that cited the ≤500-line rule, across the plans and the tree, and
the folding that mirrors Zig.

| # | Where it is written | Departure | Folding that mirrors Zig | Lines after |
|---|---|---|---|---|
| V1 | switchover §11, lib/TODO §2 (`main.zig … cli/ folded in`) | `src/cli/{args, Options, usage}.zig` kept as a folder | fold the three into `src/main.zig` (Zig parses argv inline in `buildOutputType`, `Z/main.zig:918`); `Options` a nested `pub const`, `usage_text` a const; `lsp.zig` reaches them by `@import("main.zig")` (a file cycle inside one module is legal; `main.zig` already imports `lsp.zig`) or `serve` takes a `Config` | 227+682+103+133 = 1,145 in one `main.zig` |
| V2 | switchover §11 | `src/Compilation/{backend, errors, frontend, legacy, test}.zig` beside `Compilation.zig` | fold `frontend`, `backend`, `errors`, `test` into `Compilation.zig` under `// ---- private ----` (Zig's `src/Compilation/` holds only `Config.zig`); keep `Config.zig` (Zig has it), `libmap.zig` (lib/TODO §2 names it; a request-driven reader like Zig's `Package/Fetch.zig`), `legacy.zig` (see "stays") | 342+615+401+176+194 = 1,728 in one `Compilation.zig` |
| V3 | airpasses.md §7 (`backend.zig` "at the 500-line edge, hence `air_passes.zig`") | a new `src/next/Compilation/air_passes.zig` created for the count | lands in `Compilation.zig` with V2, once zero.md wave A (airpasses T1) and wave 2 (T2, T4) have merged: they create and edit it | joins V2 |
| V4 | switchover §11 | `src/lsp_diagnostics.zig` split from `src/lsp.zig` | fold into `lsp.zig` | 502+203 = 705 |
| V5 | lower.md §5 D1, lib/TODO §11.1 | `Sema/` split into ≤500-line files; Zig keeps one `Sema.zig` with five split-outs | the rule is void; the files are not: docs/rewrite/README rule 5 keeps a split "by transform", and L0b's names were resolved on that basis. No mass fold (96 files, 28k lines, a move inside zero.md's live waves). Fold only a file whose name is a count, not a transform, when its owner next edits it | — |
| V6 | codegen.md §4 "File budgets", R8 (`strings.zig ≤500`), "Any file that reaches 500 code lines splits by family" | a budget per codegen file | drop the budget lines from the plan; `Function.zig` (744) and `DeclGen.zig` (548) already exceed it; `strings.zig` stays as a transform (string values) | — |
| V7 | vpi.md §3 (`code/expr.zig past 500`), vbackends.md §6 item 7 (`native.zig ≤500`), libmap.md §2 (≤500; the reader is 1,010 today), dlower.md §5, frontend.md "Where each skill bites", switchover §0 code-style row, diagcodes.md §1 | text citing the cap | strike the text; no file moves | — |
| V8 | lib/TODO §11.1 ("bent for one-struct files"; `check_style.py` exemption) | the exemption | superseded by the drop; the "128 forwarders in `rt/State.zig`" note is moot | — |

Departures that stay, with the reason that still holds:

| Where | Departure | Reason (switchover §11 unless noted) |
|---|---|---|
| `lib/contract.zig` + `share/vera/contract/`, `kernels/`, `gompute/` | an installed device ABI | VerA emits source a host (ESPice) compiles; Zig has no equivalent |
| `lib/std/sim` | a runtime that is not std-like | Zig's `compiler_rt`/`std.start`; kept under `lib/std` per lib/TODO §2. It imports `vams` only for `Diag.Code` (`State.zig:44`, `exe.zig:18`): the runtime still never parses |
| `module_specs` DAG (`sema`, `air`, `codegen`, `link`, `vera` rows) | Zig compiles `src/` as one module | the DAG is the import-direction check and gives `test-<module>`/`check-<module>` (`build/unit.zig:49-52`, `:173-180`); user decision §6 item 2 |
| `src/Compilation/legacy.zig` (E1100 table) | Zig keeps no compatibility wording | byte-identical switch (Q8); a separate file keeps its later deletion a `git rm` |
| `src/Compilation/Config.zig`, `Compilation/libmap.zig` | — | Zig has `Config.zig`; libmap is lib/TODO §2's row, request-driven like `Package/Fetch.zig` |
| `src/lsp.zig` | no LSP in Zig | lib/TODO §2 lists it; one file after V4 |
| `codegen/zig.zig` | — | matches `codegen/c.zig` (Q5) |
| Diag code column | `ErrorBundle` has none | AGENTS coded diagnostics (diagcodes §8) |
| held variables by a Vir pre-pass (lower D2) | Zig: `Air/Liveness` | README "to revisit after the switch-over"; §3c |
| Air passes emit diagnostics (airpasses §8 item 1-2) | Zig's passes emit none | settled by docs/rewrite/air-passes.md |
| VPI in-process, borrowed tables, generation handles (vpi §6 D1-D6) | `zig run` spawns | LRM §12.33 callbacks run in the design's process |
| goldens recorded from the differential state (§3.2) | hand-written cases | the old compiler is the provenance |
| `Zcu.File` without `source`/`tree` (vpi D6, lib/TODO §3.3) | Zig's `File` holds both | not a 500-line departure: it is the one-unit `ponytail:` (`frontend.zig:172`); §3a/§3b change it |

### 3. Zig structures VerA lacks, against the user's other goals

Goals: lower peak RSS, faster compiler, smaller and faster device code. One fact
from research/builds.md F9 bounds the first two: the compiler's own process is
0.02-0.08 GB; the `zig` child that compiles the emitted device is 0.27-4.93 GB.
Peak RSS of a device build is the child, not `vera`.

#### 3a. `Zcu.PerThread`, the job queue, the thread pool

| | |
|---|---|
| Zig | `Z/Zcu/PerThread.zig:39-45` `{zcu, tid}`, `tid.acquire/release :56`; AstGen as an `Io.Group` of `workerUpdateFile` (`:164`, `:356`); Sema on the update thread (`Z/Compilation.zig:4400-4402`); codegen per function on workers through `Zcu.CodegenTaskPool` (`Z/Zcu.zig:5366`), bounded to ~10 MiB of AIR in flight (`:5369-5376`); the linker waits per task (`Z/link.zig:1827`); InternPool sharded per thread (`Z/InternPool.zig:23, :26, :7256 get(…, tid, …)`) |
| VerA today | `Compilation.astgenBatch` (`:314-330`) is already an `Io.Group` sized by `thread_limit`, but there is one unit (`frontend.zig:172`), so it runs one job; `sema_*`, `air_passes`, `codegen`, `link` serial (`runJob :294`); `link.Queue` bounds `zig` children by `thread_limit` (the link-side parallelism Zig has) |
| Where it sits | `src/Zcu/PerThread.zig` as `{zcu, tid}` once a stage has more than one unit of work: (1) AstGen per file after the per-file split (comp.md "decisions": `Directives` per unit); (2) codegen per device part, if the Zig backend ever emits parts in-process (today parts are `link.Task.build_obj: Piece`, already parallel across children); Sema stays on the update thread as in Zig |
| Buys | wall time on multi-file designs (AstGen) and on split devices; nothing on a one-file device |
| Costs | a sharded `InternPool.get` (Zig's takes `tid`), a mutex on `zcu.failed`, determinism tests (1 job and N jobs same bytes, as `test-link-jobs`); Zig's `PerThread.zig` is 4.6k lines |
| When | after the switch, after P4 `measure` shows where a compile's wall goes (builds.md F3: in Zig it is Sema; nothing measured for `vera-next` yet). Prerequisite: the per-file unit split (§5 Z8) |

#### 3b. Per-function Air freed after codegen

| | |
|---|---|
| Zig | `Z/Zcu/PerThread.zig:2299` `defer if (air_owned) air.deinit(gpa)`, `:2320` the pool takes the Air and frees it after codegen; the Ast and source are dropped after AstGen (`:547 file.unload`; `Z/Zcu.zig:1072-1093`); the tree is re-parsed only to render an error |
| VerA today | `Compilation.analysis: ?Sema.Analysis` (one `Air` + `Air.Device` for the design) lives until `destroy` (`:197-215`); so do every unit's `tree` and `vir` and the device text (`device: ?link.Output`). Peak = source + pp text + Ast + Vir + Zcu + Air + Device + Float + text + the child |
| Where it sits | `Compilation.runJob`: `an.air.deinit` and `float.deinit` once `codegen.generate` returned (nothing later reads the body; `backend.zig:582` reads `Device` only, keep it); the tree cannot go after AstGen yet: `errors.instLoc` reads it (`errors.zig:125`, `sema.locate.inst(&u.tree, &u.vir, src)`); either Vir carries byte offsets or the tree is re-parsed at `getAllErrors` as Zig does |
| Buys | the compiler's RSS during link; small in absolute terms (F9), real on the giant devices (9.7 MB of text) |
| Costs | a few `deinit` moves; the tree part is a Vir change (frontend owner) |
| When | the Air/Float part before G0 as an additive P-task (byte-identical, reported by P4's RSS column), after zero.md wave A has merged (it edits `backend.zig`/`Compilation.zig`); the tree part after the switch |

#### 3c. Liveness as a separate pass

| | |
|---|---|
| Zig | `Z/Air/Liveness.zig:142 analyze(zcu, air, ip)`, a backend opt-in (`Z/codegen.zig:92`), run after `Legalize` (`PerThread.zig:4527-4533`), freed after codegen |
| VerA today | `src/codegen/zig/Liveness.zig` (314): `masks` (derivative lanes per unknown, a Zig-backend fact), `used`, `assigned` (generic) |
| Where it sits | `src/Air/Liveness.zig` for `used`/`assigned` (+ the held-variable fact lower D2 computes by a Vir pre-pass); `masks` stay in `codegen/zig` |
| Buys | one liveness for the Zig backend and the held pass (lower Q1); dead values elided before codegen |
| Costs | ~300 lines moved and split; no output change |
| When | after the switch (README lists it there); together with lower Q1 |

#### 3d. Type and Value as InternPool indices

| | |
|---|---|
| Zig | `Z/Type.zig:20 ip_index`, `Z/Value.zig:19`; every type and constant is one `InternPool.Index`; Sema carries no second enum |
| VerA today | `Air.typeOf` already answers in `InternPool.Index` (`Air.zig:612`); but `Sema.Ty` (`Sema.zig:128`, 3 values) is read in 44 of 96 `Sema/` files; `Sema.Value{ref, ty}` (`:190`); `Sema.digital.Type` a third; `InternPool.Key.IntType{bits, signed}`/`ArrayType` exist (`InternPool.zig:82`) and `Ty` cannot name them |
| Where it sits | `src/Type.zig` and `src/Value.zig` as thin views (lib/TODO §2 lists them); `Sema.Ty` → `Type`; `Sema.Value` collapses to `Air.Inst.Ref` (its type is `air.typeOf`): 8 bytes → 4 |
| Buys | one type system for elaboration (`eval.zig`), analog and digital lowering, codegen; width and sign for codegen W10 and the 1364 route without a second table |
| Costs | 44 lowering files touched; collides with zero.md's lower and codegen waves, which own `src/Sema/*` |
| When | after the switch and after those waves; golden IDENTICAL is the oracle |

#### 3e. Incremental dependency tracking (`--watch`, LSP)

| | |
|---|---|
| Zig | `Z/InternPool.zig:137 TrackedInst`, `:422 AnalUnit`, `:746 Dependee`, `:828 addDependency`, `:925 DepEntry`; `Z/Zcu.zig:276-279 potentially_outdated/outdated`, `:3212 markDependeeOutdated`, `:3381 findOutdatedToAnalyze`; `Z/Sema.zig:125-128 dependencies`; ZIR cached by file stat and hash (`PerThread.zig:460`); `Z/Compilation.zig:1366 CacheMode.incremental` (`-fincremental` only; AGENTS.md notes its known miscompilations) |
| VerA today | none; `update` runs once (`:228`), the LSP builds a new `Compilation` per keystroke (`lsp.zig:383` `ponytail:`) |
| Where it sits | first rung: the per-file AstGen cache keyed by hash(pp text) + macro-state digest (lib/TODO §3 row 3), which needs the per-file split (§5 Z8); second rung: `Zcu` outdated maps + InternPool dependency rows per `Instance.Key`, and `update` re-entrant per generation |
| Buys | LSP latency on multi-file designs; a `--watch` for model development (ESPice iterating on one device) |
| Costs | the largest item here: Zig's machinery spans four files and every `addDependency` site in Sema; nothing byte-visible to gate on but the determinism test (a cold and a warm update write the same bytes) |
| When | last; after 3a, 3b, 3d; only if the user wants `--watch` (decision §6 item 5) |

### 4. The target tree after the switch

`src/` and `lib/std/` as they should look; `→` = Zig counterpart; `[later]` = after
the switch (§3), not a switch-over task. Differences from switchover §4.1/§4.3 are
marked `Δ`.

```
lib/
  std/
    vams.zig  vams/                        → lib/std/zig.zig, lib/std/zig/
      tokenizer.zig number_literal.zig     → tokenizer.zig, number_literal.zig
      Ast.zig Ast/{full,errors,sites}.zig  → Ast.zig (+ Ast/Render.zig: render.zig absent, vpi's decompile)
      Parse.zig Parse/                      → Parse.zig
      AstGen.zig AstGen/  Vir.zig Vir/      → AstGen.zig, Zir.zig
      Diag.zig Diag/codes.zon Diag/         → ErrorBundle.zig (+ codes: VerA)
      Preprocessor.zig Preprocessor/        → lib/compiler/aro Preprocessor (no std.zig twin)
      spice.zig spice/  SysFn.zig           → (none), BuiltinFn.zig
      constants.vams disciplines.vams spice_primitives.vams driver_access.vams   → lib/std's own .zig files
    kernels.zig kernels/                   → compiler_rt + std.math (shipped: share/vera/kernels)
    sim.zig sim/  (bench/ stays, §4.3)     → compiler_rt/std.start (runtime of emitted exes)
    contract.zig contract/                 → none (installed ABI); §4.3: from lib/contract
    osdi.zig osdi/                         → lib/c.zig (an exported C ABI); §4.3: from lib/osdi_dyn
  vpi/  (plan-vpi)                         → what a user's program links (lib/)
src/
  main.zig                                 → src/main.zig   Δ cli/{args,Options,usage} folded in (V1)
  lsp.zig                                  → none (zls)     Δ lsp_diagnostics folded in (V4)
  Compilation.zig                          → src/Compilation.zig   Δ frontend/backend/errors/test(/air_passes) folded in (V2, V3)
  Compilation/Config.zig                   → src/Compilation/Config.zig
  Compilation/libmap.zig                   → Package/{Manifest,Fetch}.zig (request-driven reader)
  Compilation/legacy.zig                   → none (E1100 table, dies after Q8)
  Zcu.zig                                  → src/Zcu.zig
  Zcu/PerThread.zig  [later, 3a]           → src/Zcu/PerThread.zig
  InternPool.zig                           → src/InternPool.zig
  Type.zig Value.zig  [later, 3d]          → src/Type.zig, src/Value.zig
  Sema.zig Sema/ (96 files)                → src/Sema.zig, src/Sema/ (5)   V5: split stays by transform
    Sema/digital.zig Sema/digital/         → (none: the Program lowering)   vbackends Z4: Sema/digital/sites* deleted at the switch
  sema.zig                                 → none   Δ a module root only; goes with §6 item 2
  Air.zig Air/{Legalize,print,Verify}.zig  → src/Air.zig, src/Air/{Legalize,print,Verify}.zig
  Air/Liveness.zig  [later, 3c]            → src/Air/Liveness.zig
  Air/{Interval,Float,Setup,Device,interp,tan}.zig   → none (analog passes)
  codegen.zig                              → src/codegen.zig (switch on backend)
  codegen/zig.zig codegen/zig/             → src/codegen/c.zig (DeclGen, Function, Liveness, …)
  codegen/exe.zig codegen/exe/             → none; §4.3: from codegen/bench
  codegen/digital.zig codegen/digital/     → none; §4.3: from codegen/digital_next
  codegen/rtlil.zig codegen/rtlil/         → none
  codegen/{verilog,vpi,osdi}.zig (plans vbackends, vpi)   → none
  codegen/examples.zig                     → test/ (test support)   Δ candidate for tests/ at C3 (§6 item 4)
  link.zig link/{File,Queue,Server,Zig,tree,exe,check}.zig   → src/link.zig, src/link/Queue.zig
  dynlib.zig                               → none
  vpi_host.zig (plan-vpi)                  → none
```

Gone at C4 (unchanged from §4.1): `src/{elab,ir,analog,prove,zigbuild,vpi,cli}/`,
`src/codegen/{device,exe,verilog,digital}/` (old), old `src/Compilation*`,
`lib/{base,diag,frontend,kernels,sim}/`. `tests/` disposition is §6.2's.

`module_specs` after C4 stays §4.1's unless §6 item 2 collapses it; with V1-V4
no row changes (the folded files were never roots).

### 5. Tasks, in order

Oracle for a pure move: `golden -Dgolden-against=g0` IDENTICAL and `vera --help`
byte-equal (plus `tests/argv.zig`, the degenerate-argv table, for `main.zig`).
Oracle for a structural change: diff-comp/golden IDENTICAL plus the `measure`
step (P4) reporting peak RSS and wall. Every task is one commit on the slot
(`tools/build-slot.sh`), gated on `$?`.

| # | Task | Files | Mechanism | Oracle | Place | Avoids |
|---|---|---|---|---|---|---|
| Z0 | strike the void text | research/switchover.md (§0 code-style row, §11 rows cli/Compilation/lsp, "not in tree" row minus libmap), codegen.md §4 budgets, airpasses.md §7 line, vpi.md/vbackends.md/libmap.md/dlower.md/frontend.md/diagcodes.md cap lines, lib/TODO §2 (`cli/ folded in` is now right), §11.1 | docs only | `tools/doctest.py` green | now (lead) | nothing |
| Z1 | fold `cli/` into `main.zig` (V1) | `src/next/main.zig`, `src/next/cli/{args,Options,usage}.zig` → `src/main.zig`; `src/next/lsp.zig` (its `args` import) | `git mv` `main.zig`, append the three files' bodies, `pub const Options`, `pub const usage_text`; `lsp.zig`: `const main = @import("main.zig")` | `vera --help` byte-equal; `tests/argv.zig`; `test-cli` (the LSP tests walk the fixtures, `build/unit.zig:56`); golden IDENTICAL | C5 (with §4.3's `src/next/main.zig → src/main.zig` row) | zero.md touches none of these |
| Z2 | fold `lsp_diagnostics.zig` into `lsp.zig` (V4) | `src/next/{lsp,lsp_diagnostics}.zig` → `src/lsp.zig` | append under `// ---- private ----`; `pub` only what `main.zig` calls | `test-cli` LSP tests; golden IDENTICAL | C5 | — |
| Z3 | fold `Compilation/{frontend,backend,errors,test}.zig` (+ `air_passes.zig`) into `Compilation.zig` (V2, V3) | `src/next/Compilation.zig`, `src/next/Compilation/{frontend,backend,errors,test,air_passes}.zig` → `src/Compilation.zig`; keep `Compilation/{Config,libmap,legacy}.zig` | `git mv` the spine, append bodies in job order (read, spice, preprocess, astgen, sema_top, sema_analog, air_passes, codegen, link, digital, errors); the parts' `pub fn`s become private; `scratchDir` stays `pub` (tests) | golden IDENTICAL; `test-vera` (the module's tests); `comp-check-race` | C5, after §4.3's `src/next/Compilation.zig → src/Compilation.zig` and after zero.md waves A, B, C, E and frontend T7 have merged (they edit exactly these files) | zero.md waves 1-2 |
| Z4 | free Air and Float after codegen (3b, Air half) | `src/Compilation.zig` (`runJob`: `.codegen` prong), `Sema.Analysis` (`air` becomes optional or `Analysis.deinitAir`) | `an.air.deinit(gpa)`, `comp.float.?.deinit` once `codegen.generate` returned; `Device` kept (`backend.zig:582`) | golden IDENTICAL; P4 `measure` RSS column reported before/after on the giant devices | P-task before G0 (additive, byte-identical), after wave A merges; or C6 if P4 lands late | wave A's `backend.zig` hunks |
| Z5 | `tests/` for the public-API tests now in `src/` (§6 item 4, if decided) | `src/Sema/{test,lower_test,param_test,derive_test,digital_test}.zig`, `src/Sema/digital/sites_test.zig`, `src/codegen/test.zig`, `src/link/test.zig`, `src/next/Compilation/test.zig`, `lib/std/vams/{Ast,AstGen,Diag,Preprocessor,spice}/test(s).zig`, `lib/std/sim/{test,mixed/test}.zig` → `tests/unit/<namespace>.zig` | move; the module's `test {}` block references drop; `tests/unit.zig` gains namespaces | `test-unit` runs the same test names (name lists, not counts: `-Dtest-results` before/after) | C3 (§6.2 tests disposition) | — |
| Z6 | `src/Air/Liveness.zig` (3c) | `src/codegen/zig/Liveness.zig` → `src/Air/Liveness.zig` (`used`, `assigned`) + `src/codegen/zig/Lanes.zig` (`masks`) | split by fact; `codegen.generate` calls `Air.Liveness.analyze` then the lanes | golden IDENTICAL (device rows bit-exact); `test-air`, `test-codegen` | after C7; with lower Q1 (held variables as an Air pass) | zero.md's codegen waves (`Function.zig`, `DeclGen.zig`) |
| Z7 | `Type.zig`, `Value.zig` (3d) | `src/Type.zig`, `src/Value.zig` new; `src/Sema.zig:128,190`; 44 `Sema/` files; `Sema/digital.zig` `Type` | `Sema.Ty` → `Type` over `InternPool.Index`; `Sema.Value` → `Air.Inst.Ref` | golden IDENTICAL; diff-sema/test-sema; codegen W10 reads `Type` | after the switch and after zero.md's lower/codegen waves | `src/Sema/*` (owned by those waves until then) |
| Z8 | per-file units (prerequisite of 3a, 3e) | `lib/std/vams/Preprocessor.zig` (`Directives` per unit), `src/Compilation.zig` (`units` per path), `src/Zcu.zig` (`File.source/tree`), `Compilation/libmap.zig` (`decl_lib` → `File.lib`, libmap §6 item 1) | the comp.md "decisions" item; `astgenBatch` then has N jobs | diff-pp byte-equal; golden IDENTICAL (locations unchanged); `measure` wall on multi-file fixtures | after Z4 | — |
| Z9 | `Zcu/PerThread.zig` (3a) | new `src/Zcu/PerThread.zig`; `src/InternPool.zig` (`get` takes `tid`, shards); `src/Compilation.zig` | `{zcu, tid}`; AstGen group per file; codegen per part in-process if ever | 1 job and N jobs same bytes (the `test-link-jobs` pattern); golden IDENTICAL; `measure` | after Z8 and a `measure` run that names the wall | — |
| Z10 | dependency tracking (3e) | `src/Zcu.zig` (outdated maps), `src/InternPool.zig` (deps), `src/Sema.zig` (`addDependency` sites), `src/Compilation.zig` (`update` per generation), `src/lsp.zig` | Zig's rows, keyed by `Instance.Key` | cold and warm update same bytes; LSP latency measured | last; only on the user's yes (§6 item 5) | — |

Z1-Z3 are pure moves inside C5 and keep §4.3's oracle (golden IDENTICAL,
`check_style.py` on moved files). Z4 is the one structural change worth doing
before the switch. Z6-Z10 are after it; none blocks the end of `vera`.

### 6. What needs a user decision

| # | Decision | Facts | Recommendation |
|---|---|---|---|
| 1 | Fold `cli/` into `main.zig` at C5 (Z1) | the only reason to keep the folder was the cap; Zig's `main.zig` is 5.6k+ lines with argv inline (`Z/main.zig:918`); 1,145 lines after the fold; `lsp.zig` needs `Options` (file cycle, or `serve` takes a `Config`) | yes; `lsp.zig` imports `main.zig` (the cheaper rung; `serve(Config)` is an API change, not a move) |
| 2 | Collapse the `src/` build modules (`intern_pool`, `air`, `sema`, `link`, `codegen`, `vera`) into one `vera` module rooted at `src/main.zig`, as Zig compiles `src/` as one module | keeps: the DAG is the import-direction check by construction (Zig relies on review); `test-<module>`/`check-<module>` come from the rows (`build/unit.zig:49-52`, `:173-180`) and the AGENTS edit loop depends on them (0.14-0.56 GB per root against 6.4 GB, builds.md R4); ESPice imports `vera`, `link`, `std_sim`, `codegen`, `contract` by name (switchover §5.1 port map). costs: re-export roots (`src/sema.zig` 64 lines, `src/link.zig` "re-exports only"), `@import("air")` instead of `@import("../Air.zig")`, two spellings `sema.zig`/`Sema.zig` | keep the DAG for `src/`; delete only the pure re-export root `src/sema.zig` by pointing the `sema` row at `src/Sema.zig` (a struct file is a legal module root: `vera` already is one) with `pub const Zcu`, `digital`, `fold`, `locate` on it. `lib/` rows stay separate regardless (they are what ships) |
| 3 | Re-fold `Sema/` (96 files) toward Zig's one `Sema.zig` (V5) | the README's rule 5 keeps splits by transform; a mass fold is a 28k-line move inside zero.md's live waves | no; confirm V5 as written (fold a count-named file only when its owner next edits it) |
| 4 | Public-API test files inside `src/` and `lib/std/` (Z5) | AGENTS Layout: "`src/` and `lib/` keep only the `test` blocks beside the private declaration they check, as in Zig's std"; docs/rewrite/README says "in the module's own test files or in `tests/differential/`"; the tree has 14 such files | move at C3, or amend Layout at C7 (Q10) to allow a module's `test.zig`; the lead picks one so C8's audit has a rule |
| 5 | Invest in `PerThread`/dependency tracking at all (3a, 3e: Z9, Z10) | Zig's Sema is serial; VerA's compiler process is 0.02-0.08 GB against a 0.27-4.93 GB `zig` child (F9); nothing measured for `vera-next` yet (P4) | decide after P4's numbers; Z4 and Z8 are worth doing regardless |
| 6 | Keep `Compilation/legacy.zig` as its own file | Q8 keeps the table through the switch; the user drops it afterwards | keep; a `git rm` later |
| 7 | One `codegen.generate` dispatch over every backend (Zig: `switch (backend)` at `Z/codegen.zig:31,51,116,133` with `AnyMir`) vs today's per-backend entry points (`bench.writeRunner`, `digital_next.writeExe`, `rtlil.emit` called from `Compilation/backend.zig`) | the inputs differ (Air, Program, Spec); Zig unifies them because every backend takes Air; VerA's one Air backend is `zig` | settled: Zig only (lib/TODO §7, user 2026-11-11), so there is no second Air backend; `Backend = enum { zig }` and the entry points stay |
| 8 | Free the Ast after AstGen (3b, tree half) | needs Vir byte offsets or a re-parse at `getAllErrors` (Zig re-parses); `errors.zig:125` reads the tree today | after the switch, as part of Z8 (per-file units), where the frontend owner changes Vir anyway |
