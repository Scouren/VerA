# Zero: the plan to empty every known-failure list

Measured on `refactor` at b1b9da86 (lists as merged: libmap, derive, clog2,
diagcodes, w5-builds R2/R3/R5, fielduse; comp.xfail after 3ca710c1).
`tools/xfail_classes.py <repo> <out.tsv>` gives every line one **type** (what
the oracle sees) and one **root cause** (what has to change); a comp line
takes its root cause from the stage list (lower/codegen/sim.xfail) naming the
same fixture. Rerun it to re-measure; every count below comes from its TSV or
from the four area sections at the end (written read-only by four research
agents, 2026-11-11). Plans keep their task ids; this file only orders them and
counts what each clears. A `Decision:` in a plan still binds.

## The lists today

| List | Lines |
|---|---|
| comp.xfail | 1,749 (1,770 before the libmap/derive drop, 3ca710c1) |
| codegen.xfail | 498 |
| lower.xfail | 381 |
| digital_exe.xfail | 72 |
| sim.xfail | 33 |
| digital_device.xfail | 32 |
| rtlil.xfail | 5 |
| native, parse, astgen, elab, diag, preprocess, spice, link, kernels, air, air_passes | 0 |
| **differential total** | **2,770** over 1,875 fixtures |
| `tools/diag_gaps.xfail` (not differential; scope question below) | 726 |

## Types (what the oracle sees), counted before the libmap drop (2,791)

| Class | Type | Lines | Fixtures |
|---|---|---|---|
| Wrong answers | wrong number: values or rows differ, no error | 121 | 121 |
| Missing features | new refuses what `vera` compiles or runs | 1,137 | 643 |
| | not built: no backend yet (VPI 114; libmap 21, now cleared) | 135 | 135 |
| | the emitted device does not compile | 34 | 34 |
| Missing checks | new accepts what `vera` rightly rejects | 220 | 151 |
| Different diagnostics | wrong code | 157 | 94 |
| | missing diagnostic / extra diagnostic | 62 / 59 | 62 / 59 |
| Presentation | message text (same code, other words) | 565 | 543 |
| | location / notes | 237 / 54 | 197 / 54 |
| Other | | 10 | 10 |

The wrong-number count understates the class: 25 more wrong numbers sit under
the W0650 headline (air passes row 6, below) and 64 comp lines owned by
lowering print a `got=/want=` or table row; the lowering section counts 146.

## Root causes by owner

| Owner | Lines | Planned | Plan | Biggest root causes |
|---|---|---|---|---|
| Analog lowering | 1,111 | 925 lower.md + 61 elsewhere + 28 partly | `lower.md` (45 tasks) | codes `vera` raises and Sema does not (181); table rows (111, wrong numbers); locations (106); "not lowered by Sema yet" (66); nets read as values (66) |
| Codegen | 979 | 826 codegen.md + 36 elsewhere | `codegen.md` (T1-T40) | calls the backend lacks: `$fopen` 80, `timer` 79, `cross` 67, `$sformat` 60, `analog$initial` 35; string slots and forms (116); devices that do not build (65); potential-branch contributions (86) |
| Air passes | 349 (+52 owned by lowering) | all | `airpasses.md` | W0650 drops the unit's label (309, one fix) |
| Digital lowering | 206 | all but 4 | `dlower.md`, `vbackends.md` | run-diagnostic locations (about 100, T3); timing-check text (63) |
| VPI (not built) | 114 | all | `vpi.md` (V0-V10) | no VPI library in `vera-next` |
| Front end | 10 | all | `frontend.md` | wrong codes (7) |

Not yet planned anywhere (each named in its area section with its files):

| New task | Lines | Area |
|---|---|---|
| TF: §9.5 file I/O in a device (`files.zig`; runtime and Sema exist) | 82 | codegen |
| T10b `$clog2` codes, T12b operator under a constant condition, T36 §3.13 redeclaration codes, T29b run-time `$simprobe` name, T2b held write in a timer body | 14 + 6 + 5 + 2 + 1 | lowering |
| TU masks past 64 unknowns (the code's own ponytail note), TE §3.4.4 card range at run time | 3 + 2 | codegen |
| The codegen half of lowering T33 (abstol, nodeset, desc per node) and T34 (`genDerive`): wrong numbers, no codegen.md task | 10 + 2 | codegen, for lowering's wave 1 |
| dlower T2b: W1150/W1153 that `--run` never prints (and an oracle hole in diff-sim) | 4 | digital |
| Routing only: W0251/W0252/W0253/W0259/E0207 run-stage lines the judge blames on codegen | 14 | frontend or dlower |
| Attribution first (one `--run`, `-Dlower-dump` or `-Dcodegen-why` each) | 34 | lowering 25, codegen 9 |

`strings.md` (R1-R5) and conversion C1, C3, C5-C7 clear no line in today's
lists: their fixtures wait on the suite push. Conversion C2 (10 lines) and C4
(5) are in wave 1.

## Waves

Rules carried from `README.md`: wrong numbers first; the judge first (J0, J1,
J3 have landed); at most 5 implementers at once; a corpus step through
`tools/build-slot.sh`. Counts are sums of the area sections' wave tables;
where two areas share a fix (codegen T23 is airpasses T1) it is counted once.

### Wave 0: attribution and lists (lead, plus list-only tasks; now)

- Lead: full `-Dcomp-rebaseline` taking `.new`'s owners (re-owns 12 run-time
  E06xx lines to `rw-codegen (run)`, J3 landed); hand-retag the 25 wrong
  numbers hidden under W0650 (air passes row 6) and lowering's 95 (51 W0650 to
  air passes, 25 to codegen, 2 kernels, 17 front end); comp.rulings +6.
- dlower T6a/T6b, vbackends T7, frontend T8, digital_exe.rulings +3: rulings
  already decided, list files only.
- The 34 attribution runs and the 14 routings above.
- diag gaps B0 (46): `RAISE_SKIP`, the `VERA-*` exemption, the user's ledger push.

Clears about 90 differential lines (air passes section) and 46 gap lines;
the rest of wave 0 moves owners, it does not clear.

### Wave 1: wrong numbers, and the two fixes nothing waits on (about 714)

| Lane | Tasks | Clears |
|---|---|---|
| Lowering wrong numbers | T5→T3→T9, T7→T8, conversion C2, T11a→T11b→T12b, T21, T2b, T35a, then T13→T34, T33 | 193 |
| Codegen wrong numbers | T11 (noise/AC), T2, T3, Q2, Q3a/Q3b rulings, T4, conversion C4 + TE | 105 |
| Air passes T1 (W0650 label; = codegen T23) | one task | 261 |
| Digital | dlower T4 → T3 (Decision Q7), frontend T6 → dlower T5, frontend T4 after T1 and T3 | 155 |
| VPI A0 | V0a, V0b, V5 | 0 (the 114 become compared) |

First five to launch (file-disjoint): codegen T11, lowering T21, lowering
T7→T8, air passes T1, dlower T4→T3. Shared files to serialize on are in each
section (`Sema.zig`, `discrete.zig`, `backend.zig`, `DeclGen.zig`).

### Wave 2: the big refusal families (about 1,100)

| Lane | Tasks | Clears |
|---|---|---|
| Codegen B | T18 contributions, T12 events (timer/cross/above), T10 small arms, T20 systf, T24 `$monitor` | 405 |
| Lowering codes | T14→T15→T19 + T10b; T17→T18→T20→T28→T29→T29b→T24; T22→T23a→T23b; T25→T26a→TV2→T26b→T27→T30; T36 | 526 |
| Air passes and digital | airpasses T2, T4; frontend T3, T7; dlower T2b; the generated `build remark:` rulings | about 126 |
| VPI A1 | V1→V2→V3→V4 | 43 |

### Wave 3: state, formatting, text (about 785)

| Lane | Tasks | Clears |
|---|---|---|
| Codegen C, D | T15 strings, T14 random, T13, T19, TU, T22; T16 `$sformat`, TF file I/O, T17 filters, T25 | 394 |
| Lowering text | T32 locations, T31a/T31b/T31x texts and notes, T35 rest | 272 |
| Air passes | T5 (J2 + diff-float), T6 | about 48 + the §11.9 remainder |
| VPI A2, A3 | V6, V7, V8; V9a→V9b→V10 (after codegen T18/T20/T11/T22) | 71 |

Wave sums: about 90 + 714 + 1,100 + 785 ≈ 2,690 of 2,770. The remaining
≈ 80 are the attribution, routing and ruling lines above; each becomes a task
in wave 2 or 3 once wave 0 names it.

### diag gaps (726, separate)

B0 (46) in wave 0; B1 (386: data and fixtures, suite PRs through the user's
push) any time; B2 (20: compiler ports, before the switch); B3 (274: the
E1100 split and cite splits) only after switchover C6b (diagcodes Decision
Q2). None of the 726 is new to `vera-next`: the old compiler has every gap.

## Decisions for the user

1. **Does the zero rule cover `tools/diag_gaps.xfail`?** Facts and costs are
   in the VPI and diag section below. Zero there is reachable only after C6b,
   never at the switch.
2. **The if-generate display-sites ruling (2 codegen lines).** The old side
   flattens both arms of an if-generate (VAMS §6.6.2, IEEE 1364-2005 §12.4.3:
   only the selected block exists); codegen.md §5 puts `.rulings` after a user
   decision.
3. **What `test` covers.** On `refactor` it runs every diff step, about an
   hour per merge gate; TESTING.md's tiers put those in a separate gate.

---

The four area sections follow as written; each carries its category table,
its unplanned lines, its waves with files and dependencies, and the lines it
could not attribute. Their routing scripts were scratch and are not kept;
re-derive a task's fixtures from its category rows and the lists.

## Zero plan: analog lowering (owner `rw-lower`)

Source: `xfail_classes.tsv` rows with owner `rw-lower` (381, all lower.xfail) and
`rw-lower (analog lowering)` (730, all comp.xfail): 1,111 lines. No digital list
carries an rw-lower line. Task ids are `research/lower.md`'s; `conv-C2` is
`research/conversion.md` §8 C2 (+C5 fixtures); `T2b/T10b/T12b/T29b/T36` are new
tasks named in §2. Fixture-to-task mapping: the plan's `task_of.json` (370 of
the 381 lower paths), overridden where I read the line and it says otherwise
(every override is listed in §1.1); the 11 unmapped lower paths and every
comp-only path are routed by reading the line (`zero_lower_calc.py` beside this
file holds the exact routing; `zero_lower_tasks.json` is path -> task).

Landed since the plan (git log on int-w5): L0a, L0b, L0c, T1, TV1, T2, T4, T6,
T10, T12, T16. Their leftover lines are re-routed in §1.1.

Totals: planned in lower.md 925; planned elsewhere 61 (conversion.md C2 10,
airpasses T2/T5 51); partly planned 28 (T31x); unplanned 53 (T2b 1, T10b 14,
T12b 6, T29b 2, T36 5, U 25); retag 44 (rw-codegen 25, kernels 2, frontend 17).
925 + 61 + 28 + 53 + 44 = 1,111. Wrong-number lines: 146 (lower 82 by
type; comp 64 whose stderr is a `got=/want=`, `x[]`, `res[]` or table row).

### 1. Categories

Columns: category (TSV `category`, `lower: ` prefix dropped) | type | lines per
list | fixtures (unique paths) | task(s) with line counts | coverage | wrong
number? (count). Rows with fewer than 4 lines are grouped by task at the end.

| category | type | lines | fx | tasks | coverage | wrong number? |
|---|---|---|---|---|---|---|
| location no code | location 106 | comp 106 | 106 | T32 106 | planned | n |
| tables row N (split in §1.2) | wrong number 65, message text 23, new refuses 3 | lower 65, comp 26 | 65 | T26a 17, T13 12, T5 10, T26b 9, T25 8, T3 7, T21 5, conv-C2 5, T27 4, T14 4, U 2, T11b 2, T11a 2, T10b 2, T2b 1, T7 1 | planned (conv-C2: conversion.md; T2b/T10b: unplanned; U) | y (86) |
| `…` is not lowered by Sema yet | new refuses 38, wrong code 28 | lower 36, comp 30 | 36 | T17 18, T18 14, T23a 12, T14 8, T20 8, T28 4, T29 2 | planned | n |
| a net or branch is not a value; read it through an access function | new refuses 52, wrong code 14 | lower 33, comp 33 | 33 | T24 38, T25 28 | planned | n |
| notes no code (old `= note:`/`= help:` text, new only `--explain`: 27/27) | notes 54 | comp 54 | 54 | T31b 54 | planned (Q3: notes with their own location) | n |
| extra diagnostic W0650 | extra diagnostic 51 | comp 51 | 51 | airpasses T2/T5 (G7) 51 | planned in airpasses.md; retag to rw-zero | n |
| message text no code (split in §1.3) | message text 36 | comp 36 | 36 | rw-codegen retag 15, T33 10, T31b 3, U 3, T34 2, T30 2, T35 1 | planned (T33/T34 need rw-codegen) / retag / U | y (27) |
| an access of a name with no node | new refuses 25, wrong code 7, extra diagnostic 1 | lower 17, comp 16 | 17 | T26a 20, T23a 7, T22 4, T27 2 | planned | n |
| the net was not declared with a range | new refuses 24, wrong code 6 | lower 15, comp 15 | 15 | T21 26, T22 4 | planned | n |
| contribution N resist | wrong number 12, extra diagnostic 6, message text 4 | lower 12, comp 10 | 12 | T7 20 (last-ulp order, 10 fixtures), T8 2 (`$mfactor` card) | planned | y (16) |
| the analog backend cannot execute this four-state or wide literal | new refuses 17 | lower 9, comp 8 | 9 | T11a 16, T10b 1 | planned / T10b unplanned | n |
| new refuses (no stage reason) | new refuses 15 | comp 15 | 15 | U 14, T10b 1 | unplanned (plan §2 C-G18 2, C-G19 12, +`dynamic_array_index`) | n |
| `…` names nothing in the elaborated design | new refuses 12, wrong code 2 | lower 7, comp 7 | 7 | T15 6, T26b 6, T27 2 | planned | n |
| a bit or part select of a scalar is not lowered by Sema yet | wrong code 8, new refuses 4 | lower 6, comp 6 | 6 | T18 6, T19 2, T20 2, T24 2 | planned | n |
| E0926 not raised | new accepts 12 | lower 6, comp 6 | 6 | T13 12 | planned | n |
| old {}, new E0706 | new refuses 12 | lower 6, comp 6 | 6 | T11b 12 | planned | n |
| message text E0361 | message text 11 | comp 11 | 11 | T31a 11 | planned | n |
| new accepts (no stage reason) | new accepts 11 | comp 11 | 11 | T36 5 (E0335 x2, E0336, E0342, +1 `reject-only`), rw-codegen retag 3 (`$fatal` exit status, `//! exit 1`), T35 2 (noise table E0519), T13 1 (`reject_6_4_1_paramset_access_function`) | T36 unplanned / retag / planned | n |
| a port access of an instance's port (`…`) is not lowered by Sema yet | new refuses 8, wrong code 2 | lower 5, comp 5 | 5 | T23b 8, T23a 2 | planned | n |
| a user task enable is not lowered by Sema yet (misdiagnosed: all 5 are array patterns/concats) | new refuses 10 | lower 5, comp 5 | 5 | T17 10 | planned (plan had T16, which landed) | n |
| an access of a select or a hierarchical name is not lowered by Sema yet | new refuses 7, wrong code 2, message text 1 | lower 5, comp 5 | 5 | T23b 6, T26b 2, U 2 | planned / U | n |
| E0528 not raised | new accepts 5, missing diagnostic 5 | lower 5, comp 5 | 5 | T28 10 | planned | n |
| message text E0130 | message text 10 | comp 10 | 10 | T31b 10 | planned | n |
| E0501 not raised | new accepts 9 | lower 6, comp 3 | 6 | T23a 9 | planned | n |
| values (display widths) | wrong number 5, message text 4 | lower 5, comp 4 | 5 | conv-C2 5 (`integer_parameter_precision_*` 64-bit copies), T35 4 (C-G11: ranged discrete net read in analog, Table 7-1 width) | planned (conversion.md / lower T35) | y (9) |
| N subscripts for N dimensions | new refuses 6, wrong code 2 | lower 4, comp 4 | 4 | T17 4, T19 2, T18 2 | planned | n |
| initialising array parameter `…` | new refuses 8 | lower 4, comp 4 | 4 | T17 8 | planned | n |
| codegen: point N (stage list is codegen.xfail) | message text 8 | comp 8 | 8 | rw-codegen retag 6 (signal-flow x3 = C-G5, absdelay interp x2, `dynamic_multidim_numeric`), kernels retag 2 (`abs(0)` = -0, C-G10) | retag (lower Q11 Decision) | y (8) |
| wrong code E0207 (old W0252 gate notice, new parse error) | wrong code 7 | comp 7 | 7 | frontend retag 7 | retag (plan §2 D1, Q11) | n |
| E0314 not raised | new accepts 5, missing diagnostic 1 | lower 3, comp 3 | 3 | T14 4, T13 2 | planned | n |
| an assignment to a name with no slot | wrong code 2, new refuses 2, new accepts 2 | lower 3, comp 3 | 3 | T30 2, T14 2, T29 2 | planned | n |
| `…` (an operator under a constant condition) | new refuses 6 | lower 3, comp 3 | 3 | T12b 4, T29 2 | T12b unplanned / planned | n |
| E0419 not raised | new accepts 6 | lower 3, comp 3 | 3 | T15 6 | planned | n |
| E0893 not raised | new accepts 5, missing diagnostic 1 | lower 3, comp 3 | 3 | T10b 6 | unplanned | n |
| old {}, new E0704 | new refuses 6 | lower 3, comp 3 | 3 | T11b 6 | planned | n |
| E0424 not raised | new accepts 6 | lower 3, comp 3 | 3 | T29 6 | planned | n |
| message text E0887 | message text 6 | comp 6 | 6 | T31a 6 | planned | n |
| message text E0314 | message text 5 | comp 5 | 5 | T31x 5 | partly planned | n |
| missing diagnostic W0252 | missing diagnostic 5 | comp 5 | 5 | frontend retag 5 | retag | n |
| message text E0360 | message text 5 | comp 5 | 5 | T31x 5 | partly planned | n |
| `…` outside a function | wrong code 4 | lower 2, comp 2 | 2 | T28 4 | planned | n |
| E0894 not raised | new accepts 2, missing diagnostic 2 | lower 2, comp 2 | 2 | T17 2, T19 2 | planned | n |
| an array bound is not constant | wrong code 4 | lower 2, comp 2 | 2 | T19 4 | planned | n |
| E0365 not raised | new accepts 4 | lower 2, comp 2 | 2 | T23a 4 | planned | n |
| an assignment to a name that is not a variable | wrong code 4 | lower 2, comp 2 | 2 | T14 2, T17 2 | planned | n |
| E0352 not raised | new accepts 4 | lower 2, comp 2 | 2 | T22 2, T21 2 | planned | n |
| `…` takes N to N, given N | wrong code 4 | lower 2, comp 2 | 2 | T28 4 | planned | n |
| an access of a vector element at a run-time index | wrong code 4 | lower 2, comp 2 | 2 | T23a 4 | planned | n |
| E0572 not raised | new accepts 2, missing diagnostic 2 | lower 2, comp 2 | 2 | T29 4 | planned | n |
| E0524 not raised | new accepts 2, missing diagnostic 2 | lower 2, comp 2 | 2 | T30 4 | planned | n |
| an assignment to a select is not lowered by Sema yet | wrong code 4 | lower 2, comp 2 | 2 | T17 2, T19 2 | planned | n |
| E0477 not raised | new accepts 4 | lower 2, comp 2 | 2 | T23b 4 | planned | n |
| `…` outside a loop | wrong code 4 | lower 2, comp 2 | 2 | T28 4 | planned | n |
| a port access in an instance below the root is not lowered by Sema yet | new refuses 4 | lower 2, comp 2 | 2 | T23b 4 | planned (fixtures newer than the plan) | n |
| E0363 not raised | new accepts 3, missing diagnostic 1 | lower 2, comp 2 | 2 | T14 4 | planned | n |
| E0417 not raised | new accepts 4 | lower 2, comp 2 | 2 | T15 4 | planned | n |
| E0822 not raised | new accepts 2, missing diagnostic 2 | lower 2, comp 2 | 2 | T14 4 | planned | n |
| E0925 not raised | new accepts 4 | lower 2, comp 2 | 2 | T21 4 | planned | n |
| E0888 not raised | new accepts 2, missing diagnostic 2 | lower 2, comp 2 | 2 | T29 4 | planned | n |
| E0892 not raised | new accepts 3, missing diagnostic 1 | lower 2, comp 2 | 2 | T10b 4 | unplanned | n |
| E0367 not raised | new accepts 4 | lower 2, comp 2 | 2 | T26b 4 | planned | n |
| old E0501, new E0408 | wrong code 4 | lower 2, comp 2 | 2 | T23a 4 | planned | n |
| `…`/`…` in an analog body | new refuses 4 | lower 2, comp 2 | 2 | T11a 4 | planned | n |
| message text E0512 | message text 4 | comp 4 | 4 | T31a 4 | planned | n |
| message text E0901 | message text 4 | comp 4 | 4 | T31b 4 | planned | n |
| message text E0816 | message text 4 | comp 4 | 4 | T31b 4 | planned | n |

Grouped rows (categories under 4 lines, by task; the category names are the TSV's):

| categories | type | lines | fx | task | coverage | wrong number? |
|---|---|---|---|---|---|---|
| E0808, E0518, E0824, E0889, E1014, E0537, E0810, E0807 not raised; a string is not a number; old E0319, new E0348; a select of this is not lowered; a read of a reactive flow source; a reactive term of this shape | new accepts 10, wrong code 7, missing diagnostic 5, new refuses 4 | lower 13, comp 13 | 13 | T29 | planned | n |
| message text E0407, E0315, E0327, E0321, E0506, E0409, E0373 | message text 20 | comp 20 | 20 | T31a | planned | n |
| message text E0815, E0482, E0517, E0430, E0432, E0484, E0516, E0910, E0813, E0431, E0436 | message text 19 | comp 19 | 19 | T31b | planned | n |
| message text E0332, E0354, E0811, E0425, E0510, E0313, E0419, E0427, E0530, E0529 | message text 18 | comp 18 | 18 | T31x | partly planned (same work as T31a/b; code not named in the plan) | n |
| N levels deep; E0574, E0702 not raised; old E0513, new E0706; this event expression is not lowered; old E0702, new E0707 | wrong code 6, new refuses 2, new accepts 2, missing diagnostic 2 | lower 6, comp 6 | 6 | T28 | planned | n |
| an access of a whole vector; old {}, new E0408,E0512; E0337, E0344, E0366 not raised; `…` is not an access function of `…` | new accepts 6, new refuses 4, wrong code 2 | lower 6, comp 6 | 6 | T23a | planned | n |
| E0357, E0331, E0303, E0362 not raised; E0314,E0363 not raised | new accepts 7, missing diagnostic 3 | lower 5, comp 5 | 5 | T14 | planned | n |
| E0418, E0428, E0420, E0998, E0486 not raised | new accepts 10 | lower 5, comp 5 | 5 | T15 | planned | n |
| the array has N elements, past N; an array of more than N dimensions; E0310 not raised | new refuses 4, new accepts 2 | lower 3, comp 3 | 3 | T19 | planned (cell cap: Q8 Decision, u32 cells + E1016) | n |
| E0526, E0523, E0530 not raised | new accepts 6 | lower 3, comp 3 | 3 | T30 | planned (after TV2) | n |
| wrong code E0209, E0929, E0907 (old W0252 gate notice) | wrong code 5 | comp 5 | 5 | frontend retag | retag | n |
| E0372, E0353 not raised | new accepts 4 | lower 2, comp 2 | 2 | T22 | planned | n |
| E0337,E0363 not raised; E0484,E0821 not raised | new accepts 2, missing 1, wrong code 1 | lower 2, comp 2 | 2 | U | plan's U | n |
| E0351, E0350 not raised | new accepts 4 | lower 2, comp 2 | 2 | T21 | planned | n |
| E0960, E0483 not raised | new accepts 4 | lower 2, comp 2 | 2 | T26a | planned | n |
| E0222 not raised; a digital array the analog block reads is not lowered (`clog2_reg_analog_conversion`) | new accepts 2, new refuses 2 | lower 3, comp 1 | 3 | T20 | planned | n |
| Air.Verify: types at instruction N; `…` with a value is not lowered | other 2, new refuses 1 | lower 3 | 3 | T9 | planned | n |
| a concatenation of sized integers is not lowered; wrong code E0512 (`concatenation_unsized_rejected`, old E0216) | wrong code 3 | lower 1, comp 2 | 2 | T17 | planned | n |
| E0439 not raised | new accepts 1, missing 1 | lower 1, comp 1 | 1 | T23b | planned | n |
| the condition is not a constant expression (`indirect_under_parameter_condition`) | new refuses 2 | lower 1, comp 1 | 1 | T12b | unplanned | n |
| E0912 not raised | new accepts 2 | lower 1, comp 1 | 1 | T8 | planned | n |
| E0901,E0924 not raised | new accepts 1, missing 1 | lower 1, comp 1 | 1 | T26b | planned | n |
| E0237 not raised | new accepts 1, missing 1 | lower 1, comp 1 | 1 | T13 | planned | n |
| this `…` name has no value until the analog block runs (`simprobe_runtime_name_resolves`) | new refuses 2 | lower 1, comp 1 | 1 | T29b | unplanned (plan's D1-Z6 ruling is void: the reject fixture no longer exists; the suite keeps only the accepting twin, `checks 2`, old accepts) | n |
| old E0406, new E0704 | wrong code 2 | lower 1, comp 1 | 1 | T11b | planned | n |
| wrong code W0650 (`noise_table_file_name_variable_rejected`, old E0519) | wrong code 1 | comp 1 | 1 | T35 (G12) | planned | n |
| abnormal exit 2->0 (`fatal_finish_number_2_exit_status`) | abnormal exit 1 | comp 1 | 1 | rw-codegen retag (run: `$fatal` exit status) | retag | n |

#### 1.1 Overrides of the plan's `task_of.json` (derived from the lines)

| paths | plan said | now | why |
|---|---|---|---|
| `assignment_pattern_variable`, `array_assignment`, `replication_zero_effect`, `ddt_inside_array_pattern_argument`, `strobe_flow_read_inside_array_pattern_argument` (5 lower + 5 comp) | T16 (landed) | T17 | every one is an array pattern or concat; "user task enable" is the misdiagnosis |
| `integer_parameter_precision{,_derive,_real_dependents,_real_dependents_host,_conditional,_host,_override}` (7 lower + 3 comp) | T10 (landed) / unmapped | conv-C2 | conversion.md §8 C2 names these lines (Q1 Decision W) |
| `clog2_nested_contexts`, `clog2_unsigned_width`, `reject_clog2_real{,_default}`, `reject_clog2_wide_{arithmetic,arithmetic_default,widening}`, `clog2_inferred_parameter_width` (7 lower + 7 comp) | T10 (landed) / unmapped | T10b | T10 folded `$clog2`; its E0892/E0893 refusals, the E0130 on a wide operand and the 255-vs-15 width row are still open (w4-clog2 fixed the run-time width, codegen T37) |
| `analysis_or_constant_primaries`, `conditional_ddt_contribution_static`, `indirect_under_parameter_condition` (3 lower + 3 comp) | T12 (landed) | T12b | an analog operator (`ddt`) under a constant `if`, and an indirect contribution under a parameter condition |
| `timer_effectful_file_leaf` (1 lower, `held line`) | T2 (landed) | T2b | a `$fgets` destination inside a timer body is still not held |
| `continuous_variable_interpolation_host` x2, `continuous_variable_read_from_digital` (3 lower + 3 comp, `held $assigned.*`) | T4 (landed) | T5 | the `$assigned` counter is T5's |
| `attributes_on_module_items`, `generate_block_event_declaration`, `variable_in_parameter_initializer`, `function_reads_genvar_rejected`, `reject_limit_vera_seed_attr_not_constant` (5 lower + 5 comp) | T4 / L0c / ?C:C8 | T14 | parameter rows under an attribute or in a generate block, E0314 for a variable in a parameter initializer and for a function reading a genvar, E0357 (all plan T14 constructs) |
| `dynamic_multidim_scope` (1 lower, `held inner.a`) | L0c | U | not in lower.rulings; I cannot cite why the old side's hold is wrong |
| `ddiscrete_net_continuously_assigned`, `onebit_dac_reads_a_discrete_wire` (2 lower + 2 comp), `drive_strength_unsupported`, 2 noise-table E0519, `noise_table_file_name_variable_rejected` (4 comp) | unmapped | T35 | C-G11 `declSize` width of a discrete read, C-G17, C-G12 |
| `port_access_own_port_inside_instance`, `port_branch_own_port_inside_instance`, `port_access_hierarchical_potential_source` (3 lower + 3 comp) | unmapped (newer fixtures) | T23b | instance-port access |
| `concatenation_unsized_rejected` (1 comp) | – | T17 | concat forms E0216/E0327 |
| comp lines of kind location/notes/exit-only on any fixture | the fixture's lower task | T32 / T31b / U | the comp line is a different difference from the lower line |

#### 1.2 `tables row N` (65 lower lines + 26 comp twins = 91), split by what the row says

| rows say | lower | comp | task |
|---|---|---|---|
| bridge/connect node rows: `node k m.out__X_d2a__Y.d net` vs `netd`, `__xz` param, `__d2a0` param, switch/primitive bridge nets (`auto_insertion_figure_7_6_*` x4, `discipline_resolution_*` x2, `detail_top_down_parent_before_child`, `digital_primitive_on_mixed_net_with_default_discipline`, `switch_primitive_accepted`, `receiver_reads_loaded_analog_state`, `named_event_from_digital_reaches_analog`, `ieee_1364_system_functions_in_both_contexts`, ...) | 13 | 8 | T26a 17, T11a 2, T11b 2 |
| paramset / hierarchy parameter rows (`spice_paramset_shadow_warning`, `hierarchy_empty_paramset_tie`, `paramset_aliasparam_names_a_system_parameter`, `paramset_outer_defparam_chain`, `rc_h01_paramset_chain_far_link_parameter`, `defparam_upward_collect_first`, `geometry_defparam_alias`, `geometry_paramset`, `geometry_top_alias_host`, ...) | 9 | 3 | T13 12 |
| `held $assigned.<x>` vs `limit_slots 0` (7 fixtures) | 7 | 3 | T5 10 |
| `held $rng.0.seed` vs `limit_slots 0` (`revert_ops` x2, `arandom_*` x4, `rng_constant_distribution_stream`) | 7 | 0 | T3 7 |
| out-of-context declarations and specify specparams as rows (`out_of_context_declaration{,_detail}`, `compatible_hierarchical_override`, `nodeset_hierarchical_declaration`, `specify_*` x4, `timing_checks_design_runs`) | 9 | 0 | T26b 9 |
| discrete/variable port rows (`real_value_{inout,output}_port_accepted`, `node_abstol_vector_ports`, ...) | 6 | 2 | T25 8 |
| port-binding rows (`concatenated_port`, `null_port_connects_nothing`, `net_named_gnd_is_not_ground` `#1` suffix, ...) | 3 | 2 | T21 5 |
| integer parameter precision rows (`= ?`, `4294967297`, `unspecified`) | 4 | 1 | conv-C2 5 |
| escaped / `$root` names (`escaped_name_vs_vector_element`, `escaped_period_is_not_a_path`, `root_anchored_paths`) | 3 | 1 | T27 4 |
| attribute / generate parameter rows (`operating_point_report_attributes` x2, `attributes_on_module_items`, `generate_block_event_declaration`) | 4 | 0 | T14 4 |
| `$clog2` width row (`clog2_inferred_parameter_width` 255 vs 15) | 1 | 1 | T10b 2 |
| `held line` in a timer body | 1 | 0 | T2b 1 |
| `$fatal` row after `analog initial` `$error` | 1 | 0 | T7 1 |
| one `$strobe` row short (`unnamed_generate_block_external_names`); `held inner.a` (`dynamic_multidim_scope`) | 2 | 0 | U 2 |

Counts per task are exact (from the routing); the row-kind labels are derived.

#### 1.3 `message text no code` (36 comp lines), split by the line

| the line | n | task |
|---|---|---|
| `abstol[...] got=1e-6 want=...` (per-node abstol: `annex_d_access_v_without_include`, `ddt_output_abstol`, `nature_as_ddt_abstol_argument`, `mixed_signal_smallest_abstol`, `node_abstol_resolved_segment`) | 5 | T33 (C-G2) |
| `meta count got=0 want=3` (`desc_net_rows`, `desc_units_output_variable_rows`) | 2 | T33 (C-G4) |
| nodeset `got=1 want=3` (`nodeset_01`, `nodeset_02`, `spice_nodeset_cubic`) | 3 | T33 (C-G3) |
| `dependent_control_clog2` ($clog2(5) got=1), `dependent_control_host` (got=0) | 2 | T34 (C-G1) |
| `vera_scratch_uninit_*` (unwritten slot got=0) | 2 | T30 (D1-U/V `vera_scratch`) |
| `drive_strength_unsupported` (`x[w]` 1 vs 0) | 1 | T35 (C-G17) |
| `= note: §3.6.2.4 ...` vs `--explain` (`no_discipline_rejected`, `default_discipline_reset_leaves_no_default`, `resetall_clears_default_discipline`) | 3 | T31b |
| discontinuity/limit verdict x5, `$finish`/`$stop` text x3, `INFO: t=0`/`WARNING: p=1` prefix x4, `%h` padding x1, `idt_is_a_charge_site` (`lte` flag) x1, `monitor_at_analog_only_solutions` x1 | 15 | rw-codegen retag (plan §2 C-G5..G9, G15, G16; Q11 Decision) |
| `digital_value_has_zero_derivative` (`x[k]` 0 vs 0.2), `mixed_event_parameters_{override,sweep}` (`x[p]` 0.6 vs 0.375) | 3 | U (wrong numbers; need a dump to route) |

#### 1.4 `location no code` (106), derived split

Same line, column differs 78; same line, new column 1 (the statement start) 8;
line differs 10; no `-->` line at all on the new side (a `= note: LRM ...`
replaces it) 9; caret width `^^^` vs `^` 1. All T32 (B1-B7: argument parts,
event-control site, declaration parts, caret).

### 2. Unplanned categories

| what | lines | needs |
|---|---|---|
| T10b `$clog2` codes | lower 7, comp 7 | new task, `src/Sema/eval_fn.zig` (+ `expr.zig` for the run-time path): E0892 (real argument, §9.14), E0893 (wide arithmetic/widening), a wide `$clog2` operand is not an E0130, the inferred width row (255 vs 15, §6.3.4). Fixtures are `reject-only`, so no ruling. |
| T12b operator under a constant condition | lower 3, comp 3 | new task, `src/Sema/condbr.zig`, `expr.zig`: a constant `if` folds one arm but an analog operator in the dropped arm still declares its state (Q12 Decision, §4.5); E0412 for an indirect contribution under a parameter condition. |
| T36 §3.13 redeclaration codes | comp 5 | new task, `src/Sema/nature.zig`/`discipline.zig`: E0335 (duplicate access name, §3.13.2, x2), E0336 (nature/discipline namespace collision, §3.13.1), E0342 (duplicate nature, §3.6.1), `duplicate_discipline_name` (`reject-only`). frontend.md:39 dropped rw-lower's E0342 test; it comes back here. |
| T29b run-time `$simprobe` name | lower 1, comp 1 | new task, `src/Sema/simprobe.zig`: resolve a name that is a variable at run time (§9.16). The plan's D1-Z6 ruling cannot stand: `reject_simprobe_runtime_name.va` is gone and the suite's `simprobe_runtime_name_resolves.va` (old accepts, `checks 2`) is the oracle. |
| T2b held write in a timer body | lower 1 | one site in `src/Sema/held_writes.zig`: `timer(...)` bodies go through the same `flush` as event bodies. |
| T31x message texts (E0332, E0354, E0811, E0425, E0510, E0313, E0419, E0427, E0530, E0529, E0314, E0360) | comp 28 | same work as T31a/b (old stderr bytes are the spec); the plan's A-list just does not name these codes. Add to T31a. |
| T33/T34 codegen half | comp 12 | lower.md says "needs rw-codegen"; codegen.md has no `node_meta`/`nodeset`/`genDerive` task (grep). plan-codegen must schedule the matching half or the 12 wrong numbers stall. T3's half does exist (codegen.md:288 `K.rng.<fn>`, :512 `rng<k>__seed`). |
| U, 25 lines | lower 5, comp 20 | §4. |

No new ruling candidates: every unplanned line has either a `reject-only`
fixture the old side honours, an accepting fixture the old side passes, or a
wrong number I cannot attribute without a build.

### 3. Waves

Wave 0 (lead, no code, one rebaseline; lower Q11 and frontend Q5 Decisions):
retag 51 W0650 lines to rw-zero (airpasses T2/T5 clear them), 25 to rw-codegen,
2 to kernels, 17 to rw-comp (frontend D1 gate notices). rw-lower's comp count
drops 730 -> 635.

#### Wave 1: wrong numbers (clears 193: lower 107, comp 86)

| lane | tasks in order | lines (lower/comp) | depends on |
|---|---|---|---|
| held | T5 -> T3 -> T9 | 7/3, 7/0, 3/0 | T2, T4 landed; T3 needs rw-codegen's `_next` kernel map (codegen.md:288) |
| decl/contrib | T7 -> T8 | 11/10, 3/1 | nothing (L0b landed) |
| conversion | conv-C2 (+C5 fixtures: user push) | 7/3 | conversion.md Q1-Q8 decided; one implementer for C1-C4 |
| four-state/D2A | T11a -> T11b -> T12b | 11/11, 11/11, 3/3 | T4 landed; T11b after T7 (decl.zig) |
| ports | T21 | 22/19 | nothing |
| small | T2b; T35a (the width/drive-strength half of T35: `format.zig` declSize, `discrete.zig:160`) | 1/0; 2/3 | nothing; discrete.zig after T11a |
| then | T13 -> T34; T33 | 19/10, 0/2; 0/10 | T13 after T8 (Zcu.zig), T11b (decl.zig), conv-C2 (param.zig); T33 after T3 (Air/Device.zig) and T21 (net.zig); T33/T34 need plan-codegen's half |

Disjoint starting set (file-disjoint, can run as parallel agents): T7, T11a,
T21, conv-C2, T2b. T5 starts when conv-C2's one-line `variable.zig:152` edit
is in (or rebases). Shared files to serialize on: `Sema.zig` (T5, T3, T11a,
T11b), `syscall.zig` (T7, T8), `variable.zig` (conv-C2, T5, T9), `discrete.zig`
(T11a, T11b, T35a), `decl.zig` (T7, T11b, T13), `Air/Device.zig` (T3, T33).
README cap: 5 implementers at once.

#### Wave 2: codes (clears 526: lower 269, comp 257)

| lane | tasks in order | lines (lower/comp) | depends on |
|---|---|---|---|
| eval/param | T14 -> T15 -> T19; T10b alongside | 21/17, 13/13, 9/9; 7/7 | T13; T10b is file-disjoint (eval_fn.zig) |
| control | T17 -> T18 -> T20 -> T28 -> T29 -> T29b -> T24 | 24/25, 12/10, 8/6, 19/19, 23/23, 1/1, 20/20 | T16, T10 landed; T17 after T14 (expr.zig); T20 after T5; T24 after T21 |
| contrib | T22 -> T23a -> T23b | 7/7, 29/25, 12/12 | T8 (plan lane); T23a after T6 (landed) |
| ports | T25 -> T26a -> [TV2: frontend T6's agent, Q13] -> T26b -> T27 -> T30 | 20/16, 22/19, 12/11, 4/4, 6/8 | T21, T11b, T9; TV2 before T26b/T27/T30 |
| small | T36 | 0/5 | nothing (nature.zig/discipline.zig) |

Disjoint starting set once wave 1's T13 and T21 are in: T14, T17 (after T14's
expr.zig, or rebase), T22, T25, T36, T10b. Most-shared files are the plan's
(§3.4): `control.zig`, `expr.zig`, `decl.zig`, `Sema.zig`, `syscall.zig`,
`discrete.zig`; rebase on the previous lane task.

#### Wave 3: comp-only text and locations (clears 272, all comp)

| task | lines | depends on | disjoint from |
|---|---|---|---|
| T32 locations | 106 | frontend T1 (landed), T7 (`Part.scaled`, `locate.zig`), lower T28 | T31a/b (texts vs `Zcu.zig`/`locate.zig`) |
| T31b notes + A11-A26 texts | 94 | T27 (hier.zig), Q3 (notes with their own location) | T32 |
| T31a A1-A10 texts + T31x (28) | 41 + 28 | T29, T14 | T32; shares files with T31b: serialize or one agent |
| T35 rest (noise table E0519 x3) | 3 | T32 | – |

Running total: 193 + 526 + 272 = 991 cleared by rw-lower tasks; 95 retagged;
25 unattributed.

### 4. Lines I cannot attribute (25: lower 5, comp 20)

| lines | why |
|---|---|
| 15 comp `exit status old 0, new 1`, no stderr line: 10 `ch04_expressions` relational/logical fixtures (`conditional_operator`, `greater_equal`, `greater_than`, `less_equal`, `less_than`, `logical_and`, `logical_equal`, `logical_not`, `logical_unequal`, `relational_logical`), `conditional_no_else`, `dynamic_array_index`, `cccs_inside_a_spice_subcircuit`, `mfactor_on_a_netlist_subckt` (14); `clog2_unsigned_width` is the 15th and went to T10b | the fixtures pass diff-lower (not in lower.xfail), so the refusal is downstream of Sema; the plan's U already asks for one slot: `vera-next --run greater_than.va`, then route (C-G18, C-G19) |
| 3 comp wrong numbers: `digital_value_has_zero_derivative` (`x[k]` 0 vs 0.2), `mixed_event_parameters_override`, `mixed_event_parameters_sweep` (`x[p]` 0.6 vs 0.375) | pass diff-lower; a `-Dlower-dump` or `--run` decides lower vs codegen |
| plan's U, 4 lower + 2 comp: `constant_expression_reads_a_probe_rejected` (E0337,E0363 not raised), `unnamed_generate_block_external_names` (one `$strobe` row short), `connect_insertion_upper_from_ooc_below`, `kernel_control_in_digital_context_rejected` (E0484,E0821 not raised) | the plan's own "unclear" set; its `-Dlower-dump` slot is still owed |
| `dynamic_multidim_scope` (1 lower: old `held inner.a`, new nothing) | the line's note ("a named block's array with a declaration initializer, written in the block") reads like a ruling candidate (D2-G's shape: written before read in one run), but I cannot cite the clause without the dump; not in lower.rulings |

## Zero plan: codegen (owner `rw-codegen`)

Scope: every TSV line with owner `rw-codegen` (codegen.xfail, 498) or `rw-codegen (codegen|run|display phase)` (comp.xfail, 372 + 102 + 7) = **979**. Lists read from `int-w5` HEAD (`git show`, the working copies were mid-rebaseline). Counts come from `xfail_classes.tsv` through `zero_codegen_map.py` (beside this file; rerun it to reproduce every number). Plan state at HEAD: T0a-T0d, T1, T4, T5, T8, T21 (`$simprobe`, via rw-lower e8fa3a12), T36-T38, T5-W12 landed; T6/T7 have no line left in either list.

Column key: lines = codegen / comp:codegen / comp:run / comp:display. "derived" = a split I made by reading the lines, not a TSV category.

### 1. Categories

| category | type | lines (cg/cc/cr/cd) | fixtures | task | coverage | wrong number? |
|---|---|---|---|---|---|---|
| call `timer` | new refuses | 79 (51/11/17/0) | `va_tick.va`, `analog_event.va` | codegen.md T12 | planned | n |
| call `cross` | new refuses | 67 (37/6/24/0) | `a09_cross_rejector.va` ×7 | codegen.md T12 | planned | n |
| call `above` | new refuses | 18 (9/1/8/0) | | codegen.md T12 | planned | n |
| call `$fopen` + the task `$fwrite` | new refuses | 82 (42/40/0/0) | 41 `ch09_system_tasks/f*.va`, `file_*`, `monitor_*` (the `$fmonitor` three), `combined/file_*`, `file_descriptor_shared_across_contexts.va` | **none** -> new TF | **unplanned** | n |
| a slot of type 2 (a string) | new refuses | 65 (33/32/0/0) | the ch02 `CHECKI("…", "<lit>", int)` set | codegen.md T15 | planned | n |
| a real operand that is not a number | new refuses | 18 (9/6/3/0) | | codegen.md T15 | planned | n |
| parameter `…` is not a number | new refuses | 10 (5/5/0/0) | `simprobe_string_parameter_name_resolves.va` | codegen.md T15 | planned | n |
| call `str$cmp` / `$simparam$str` | new refuses | 8 (4/4) + 4 (3/1) | | codegen.md T15 | planned | n |
| call `$sformat` / `$swrite` / `$sscanf` | new refuses | 60 (30/30) + 10 (5/5) + 10 (5/4/1) | `held_sformat_string_survives_rejected_step.va` | codegen.md T16 | planned | n |
| flow contribution to a potential source's branch | new refuses | 52 (27/23/2/0) | `cap_ramp.va` | codegen.md T18 | planned | n |
| potential contribution under a condition (switch branch) | new refuses | 34 (17/17/0/0) | `conditional_potential_open.va` | codegen.md T18 | planned | n |
| indirect contribution | new refuses | 14 (8/6/0/0) | `indirect_contribution.va` | codegen.md T18 | planned | n |
| §9.17.3 `$limit` string form | new refuses | 50 (26/14/10/0) | `limit_pnj.va`, `limit_fet.va` | codegen.md T10 phase A (+T25, 0 lines, Q4 decided) | planned | n |
| call `analog$initial` (+1 message text) | new refuses | 35 (21/13/1/0) | `analog_initial.va` | codegen.md T10 | planned | n |
| call `$port_connected` | new refuses | 14 (8/6/0/0) | `port_connected.va` | codegen.md T10 (root) + T3 (children) | planned | n |
| call `$test$plusargs` / `$value$plusargs` | new refuses | 6 (3/3) + 4 (2/2) | `plusargs.va` | codegen.md T10 | planned | n |
| device does not build: unused local constant (derived: noise args, B1) | new does not build | 49 (25/24/0/0) | 23 `noise_*`/`psd_*`/`spice_noise_*`, `ntab_card.va`, `generate_replaced_by_analog_for.va` | codegen.md T11 | planned | n (but see PSD row) |
| device does not build: unused function parameter (derived: limit-only `updateState`, B2) | new does not build | 16 (9/7/0/0) | 7 `limit_*.va`, `va_limit.va`, `a09_limit_ramp.va` | codegen.md T10 (B2 line) | planned | n |
| point N: noise PSD at 1 Hz old X, new 0 (derived) | wrong number | 23 (23/0/0/0) | 6 `va_noise.assets/*`, 11 `ch04 noise_*`, 6 `ch06 mfactor_*noise*` | codegen.md T11 (`noisePsd` entry; T0b's PSD oracle sees it) | planned | **y** |
| point N: flow-only net row (derived, W2) | wrong number | 3 (3/0/0/0) | `electrical_definitions.va`, `flow_signal_flow.va`, `signal_flow_single_nature_contributions.va` | codegen.md T2 | planned | **y** |
| point N: absdelay `vera_interp` quadratic (derived, R3) | wrong number | 2 (2/0/0/0) | `absdelay_vera_interp_quadratic{,_uneven}.va` | codegen.md T13 | planned | **y** |
| point N: `abs(+0)` (derived, W16) | wrong number | 2 (2/0/0/0) | `abs.va`, `exhaustive/rounding_selection.va` | codegen.md Q2 Decision: `@abs` in `fold.zig` + `F.zAbs`, one commit | planned (decided) | **y** |
| point N: folded `cosh(-1)` (derived, W18) | wrong number | 2 (2/0/0/0) | `cosh.va`, `exhaustive/hyperbolic.va` | codegen.md Q3b Decision: `.rulings` + widen `libm_kernels` | ruling (decided) | y (old is 1 ulp off) |
| point N: `fmod` −0 (derived, W17) | wrong number | 1 (1/0/0/0) | `hypot_fmod_extreme_magnitude.va` | codegen.md Q3a Decision: `.rulings` | ruling (decided) | y (old grafts +0) |
| point N: `$simparam("timeUnit")` (derived, W13) | wrong number | 1 (1/0/0/0) | `simparam_timescale.va` | codegen.md T3 | planned | **y** |
| point N: `dynamic_multidim_numeric` record 69 old 0, new 12 (derived, W6) | wrong number | 1 (1/0/0/0) | | codegen.md T4 landed, line stayed: retrace with `-Dcodegen-why` | partly planned | **y** |
| call `laplace_nd/zp/np/zd`, `zi_nd/zp/np` | new refuses | 58 (29/29/0/0): nd 20, zp 12, np 6, zd 2 / zi 12, 4, 2 | `laplace_nd_dc_gain.va`, `zi_dc_gains.va` | codegen.md T17 | planned | n |
| call `$random`/`$arandom`/`$dist_*` (7)/`$rdist_*` (7) (+1 message text) | new refuses | 48 (24/23/1/0) | `random.va`, `rdist_normal.va` | codegen.md T14 | planned | n |
| call `ac_stim` | new refuses | 16 (8/8/0/0) | `ac_stim.va` | codegen.md T11 | planned | n |
| call `idt$hold` | new refuses | 12 (7/5/0/0) | `idt_assert_release_resumes.va` | codegen.md T13 | planned | n |
| a call of a user function (callee 4294967295) | new refuses | 12 (9/0/3/0) | `va_vpi_gain.va`, `env_probe.va`, 5 `ch12_vpi_routines/*` | codegen.md T20 | planned | n |
| missing diagnostic W0852 | missing diagnostic | 2 (0/0/2/0) | `analog_system_task_registration.va`, `analog_systf_resistor_call.va` | T20 emits the export; T23 moves the warning to Sema `userCall` | planned | n |
| wrong code W0650 (old E0527 ×2, E0540 ×3, W0853 ×2) + missing W0850 | wrong code | 8 (0/6/2/0) | `reject_limit_seed_reads_solution*.va`, `z_filter_period_rejected.va`, `limit.va`, `say_device_records.va` | codegen.md T23 (C8) | planned | n |
| message text W0650: empty unit label | message text | 6 (0/6/0/0) | `reject_4_5_1x_*`, `laplace_zd_unpaired_zero_rejected.va` | codegen.md T23 (C7) = airpasses.md T1 (`Root.name`) | planned | n |
| message text no code: `$monitor` | message text | 2 (0/0/0/2) | `display_monitor.va`, `monitor_after_macro_process.va` | codegen.md T24 | planned | n |
| path latch | new refuses | 3 (2/1/0/0) | `batch_per_instance_state.va`, `va_limit_state.va` | codegen.md T19 | planned | n |
| more than 64 unknowns | new refuses | 3 (2/1/0/0) | `ladder70.va`, `vector_port_past_256_unknowns.va` | **none** -> new TU | **unplanned** (a cap the old side lacks: a regression, README) | n |
| new accepts (no stage reason): card range | new accepts | 2 (0/0/2/0) | `range_card_value_{below_from,excluded}_rejected.va` | **none** -> new TE (airpasses.md G11 names it codegen's: E0377 run-time card check) | **unplanned** | y (silent acceptance) |
| the display sites differ in number | wrong number | 2 (2/0/0/0) | `generate_if_instantiates_one_arm.va`, `if_generate_values_drive_paramset_selection.va` | ruling candidate: lower.md C-P4 (L0c, elab.rulings `drops`) | ruling candidate | n (the old side has the extra site) |
| parameter `…`'s default does not fold | new refuses | 2 (1/1/0/0) | `dependent_control_unknown_local.va` | codegen.md R17 "cause not traced"; T5 landed, line stayed | untraced | ? |
| lower categories on my owner (tables row N 20, Air.Verify 2, E0222 2, resist 1, four-state 1, values 1, with a value 1) | mixed | 28 (0/19/8/1) | `integer_parameter_precision*` ×5, `arandom_*` ×4, `specify_*` ×4, `clog2_nested_contexts.va`, … | lower.md (C2: lowering first); conversion.md C1-C7 for the 5 precision fixtures | other plan | per lower |
| new refuses (no stage reason): aliases | new refuses | 3 (0/3/0/0) | `alias_card_write_sets_original_given.va`, `parameter_alias.va`, `macro_alias_parameter_ranges.va` | lower.md T24 (C3 routing) | other plan | n |
| location no code | location | 2 (0/2/0/0) | `ddt_abstol_dynamic_rejected.va`, `idt_abstol_dynamic_rejected.va` | lower.md T31 (message texts/locations) | other plan | n |
| message text no code: diagnostic location | message text | 2 (0/0/0/2) | `digital_function_from_analog_{rejected,unsupported}.va` | codegen.md C6 -> Sema (lead routes) | other plan | n |
| missing diagnostic W0650 (display phase) | missing diagnostic | 2 (0/0/0/2) | `sinh.va`, `cosh.va` | airpasses.md T5 (presence via diff-float) | other plan | n |
| new accepts (no stage reason): E0531 | new accepts | 1 (0/1/0/0) | `reject_vera_timepoint_reads_iterate.va` | airpasses.md G9 | other plan | n |
| message text no code: digital `%d` width | message text | 1 (0/0/1/0) | `gate_ordered_terminals.va` (`got=1` vs `got=          1`, the run stage is std_sim) | dlower.md (std_sim display width) (derived) | other plan | n |
| new refuses (no stage reason): C3 routed | new refuses | 2 (0/2/0/0) | `spice_binned_model_selects_by_l_and_w.va` (bench card route), `noise_table_file_name_parameter.va` (Sema `noise_table` file) | codegen.md "C3 owners" note | other plan | n |
| missing/message W0251, W0252 ×9, W0253, W0259; wrong code E0207 | missing diagnostic | 14 (0/0/14/0) | 9 gate/UDP primitives, 2 specify, `configuration_source_text.va`, `own_expm1_function_warns.va`, `reject_A_7_1_pulsestyle_parenthesized.va` | **none**: diagcodes-map stages them parse/sema/run; no plan names them | **unplanned, not codegen** | n |
| untraced comp lines | new refuses/accepts/message | 7 (0/5/2/0) | see §4 | — | untraced | ? |

### 2. Unplanned categories

- **TF, §9.5 file I/O in a device (82).** New `src/codegen/zig/files.zig`: the §9.5 calls rendered in `say`'s second body (the old `cg_file_io.zig` did them in the display unit), `Instance.zf__: K.file.ZfTable` per instance, the integer result latched for the other units (old `zFKeep`), `$fdisplay`/`$fwrite`/`$fstrobe` through `say.format`, `$fmonitor` through T24's latch, `$fgets` into a T15 string slot, `$fscanf` through T16's `zScan*`. The runtime side exists: `lib/std/kernels/file.zig` (`ZfTable`, the `zF*` ABI) and `contract.FileIo`. Sema side: lower T29's `fileio.zig` (E0888/E0889 are its 3 lower.xfail lines; the 41 fixtures here already lower). Oracle: diff-codegen bit for bit plus a `dyn.zig` file-table compare (open descriptors and bytes written per point). After T15, T16, T24.
- **TU, past 64 unknowns (3).** `src/codegen/zig/Liveness.zig` `Mask = u64`, `unknowns_max = 64`; its own `ponytail:` note names the upgrade (`[]u64` column of `mw` words, "add it with the first such fixture"); `contract.MaskOf(|U|)` already handles >64 (`lib/contract.zig:309` test). Regression, never a ruling (README). `stamps.zig:96` drops the refusal. Files: `Liveness.zig`, `stamps.zig`, `DeclGen.zig` (`deriv_reads`/`ddx_reads` as `MaskOf(nU)`).
- **TE, the §3.4.4 card range check at run time (2).** `range_card_value_*_rejected.va`: old exits 1 (E0377) when a host card value falls outside `from`/`exclude`; new runs it. `DeclGen.genDerive`/`setupInstance` gains the range check the Model's `ranges` table describes (old `model.zig` card validation). A silent acceptance of an invalid card is a wrong-number class: wave A.
- **W0251/W0252/W0253/W0259/E0207 (14, not codegen).** Parse (W0253, W0259, E0207 on `pulsestyle_onevent (`), Sema (W0252 gate primitive accepted), run (W0251 specify) codes the judge blames on `rw-codegen (run)`. No research plan names any of them: lead routes to frontend.md/dlower.md, or diagcodes.md's gap report.
- **Ruling candidate, if-generate display sites (2).** Old flattens both arms of an if-generate (lower.md C-P4, elab.rulings `drops`; VAMS §6.6.2 and IEEE 1364-2005 §12.4.3: only the selected generate block exists), so the old device records a display site from the dead arm. A `codegen.rulings` line per fixture citing the same clause, after the user's decision (codegen.md §5: `.rulings` only after a user decision).

### 3. Waves

Wrong numbers first (README). T6 and T7 (W8-W10) hold no line now; they stay in codegen.md until a line names them.

**Wave A: wrong numbers** — clears codegen 66, comp:codegen 32, comp:run 2 (100), plus conversion C4's 5 comp lines from the lower-category row (105).

| task | lines | depends on | files |
|---|---|---|---|
| T11 noise/AC (`noise.zig`, `noisePsd`, `acStim`, B1's `S.con` args, `Liveness.readsArgs`) | 88 (cg 56: PSD 23 + B1 25 + ac_stim 8; cc 32) | T0b landed. Plan listed T10/T12 as deps only for `Liveness.zig`/`calls.zig` contention: T12 rebases its `effect` edit on T11 | new `noise.zig`; `Liveness.zig`, `calls.zig` (two arms), `DeclGen.zig` (one call) |
| T2 flow-only nets | 3 | — | `Air/Device.zig` (`flow_only`), `Sema/contrib.zig`, `stamps.zig` |
| T3 per-instance folds (+ `$port_connected` children for T10) | 1 | — | `Sema/syscall.zig`, `Zcu.zig`, `Sema/{param,defparam,paramset}.zig` |
| Q2 `@abs` (decided) | 2 | — | `lib/std/kernels/fold.zig`, `family.zig` |
| Q3a/Q3b `.rulings` (decided) + `libm_kernels` widen | 3 | — | `codegen.rulings`, `tests/differential/codegen.zig` |
| T4 retrace `dynamic_multidim_numeric` | 1 | — | `Sema/variable.zig` |
| conversion.md C4 (codegen sites) + TE card range | 5 lower-category comp + 2 | after w4-derive/clog2/gompute merges (README) | `DeclGen.zig` `genDerive`, `state.zig:205`, `calls.zig:155`; TE in `DeclGen.zig` |

Parallel: T11 ∥ T2 ∥ T3 ∥ Q2 ∥ T4 (disjoint). Conversion C4 + TE are one agent (both in `genDerive`) and run after T11 (both touch `DeclGen.zig`).

**Wave B: refusals, VPI first and the big families** — clears codegen 227, comp:codegen 121, comp:run 69, comp:display 2 (419).

| task | lines | depends on | files |
|---|---|---|---|
| T18 contributions (unblocks VPI G8/G9) | 100 | T2 | `stamps.zig`, new `switch_row.zig`, `DeclGen.zig` (one call), `Function.zig` (`wrote`) |
| T12 events (timer, cross, above: one `ops/events.zig`, one breakpoint entry) | 164 | T11 (`Liveness.zig`) | `ops.zig`, new `ops/events.zig`, `Liveness.zig` (`effect`), `DeclGen.zig` (breakpoints) |
| T10 small arms (`analog$initial`, `$port_connected` root, plusargs, `$limit` A, B2) | 125 | T3 (children) | `calls.zig` (arms), `state.zig`, `DeclGen.zig` (`genModel`) |
| T20 systf (unblocks VPI G8/G9) + W0852 | 14 | T0b landed | new `systf.zig`, `calls.zig:51`, `DeclGen.zig` (Instance field) |
| T23 diagnostics into Sema, W0650 label (= airpasses T1) | 14 | — | `src/codegen.zig` (`floatRoots`), `Sema/op.zig`, `Sema/kernel.zig` |
| T24 `$monitor` | 2 | T1 landed | `say.zig` |

Parallel: T18 ∥ T12 ∥ T23 ∥ T24 (disjoint). T10 and T20 both add to `calls.zig` and `DeclGen.zig` (one arm / one line each): run in parallel, merge in either order.

**Wave C: state families** — clears codegen 91, comp:codegen 78, comp:run 5 (174).

| task | lines | depends on | files |
|---|---|---|---|
| T15 string values (slot, `str$cmp`, not-a-number ×2, `$simparam$str`: one `strings.zig`, `Air.Device.str_caps`) | 106 | T10 (`calls.zig`), T5 landed | new `strings.zig`; `Function.zig` (`real`/`int`), `calls.zig`, `DeclGen.zig` (`genModel`); `Air/Device.zig`, `Sema/string.zig` |
| T14 random (14 categories, one `random.zig`, `EnumArray` over `SysFn.Tag`) | 48 | T10 (`state.zig`) | new `random.zig`; `calls.zig`, `state.zig` |
| T13 `idt$hold` + absdelay quad | 14 | T12 (`ops.zig`), T23 (`Sema/op.zig`), T24 (`say.zig`) | `ops.zig`, `ops/delay.zig`, `Sema/op.zig`, `say.zig` |
| T19 path latch | 3 | T10 | new `paths.zig`; `Function.zig:569`, `state.zig` |
| TU wide masks | 3 | — | `Liveness.zig`, `stamps.zig`, `DeclGen.zig` |
| T22 `vpi_contribs` | 0 (G8) | T18 | `src/codegen.zig`, new `vpi.zig`, `sides.zig` |

Parallel: T15 ∥ T14 ∥ T13 ∥ TU ∥ T22. T19 after T14 (`state.zig`).

**Wave D: formatting, filters, files** — clears codegen 111, comp:codegen 108, comp:run 1 (220).

| task | lines | depends on | files |
|---|---|---|---|
| T16 `$sformat`/`$swrite`/`$sscanf` | 80 | T15 | `strings.zig`, `calls.zig`, `say.zig` (`%s`) |
| TF file I/O | 82 | T15, T16, T24 | new `files.zig`; `say.zig` (format), `DeclGen.zig` (`Instance.zf__`), `dyn.zig` (file compare) |
| T17 filters (7 categories, one `ops/filter.zig`, `op_state` nodes) | 58 | T13, T23 | new `ops/filter.zig`; `ops.zig`, `Sema/op.zig` |
| T25 `limit` hook | 0 | T10, T23 | new `limit.zig`; `Air/Device.zig`, `Sema/kernel.zig`, `dyn.zig` |

Parallel: T17 ∥ T25 ∥ T16; TF after T16 (both in `strings.zig`/`say.zig`).

Shared code (one task each, never split): timer/cross/above = `ops/events.zig` + breakpoints (T12); B1 build failure + PSD 0 + `ac_stim` = `noise.zig` + `readsArgs` (T11); the 14 random tags = one `EnumArray` (T14); the 7 filter tags = one cascade renderer (T17); the 3 contribution forms = one `S.sel` row (T18); the 5 string-value categories = `strings.zig` (T15); file I/O = one `ZfTable` field and one body (TF).

Wave sums (script output, `--- waves ---`): A 100 + conversion C4 5 + B 419 + C 174 + D 220 = 918 cleared by my tasks; the other 61 = other plans 36 (lower-category 23, aliases 3, locations 2, C6 2, W0650 presence 2, E0531 1, dlower 1, C3-routed 2) + misrouted run codes 14 + untraced 9 + ruling candidate 2. 918 + 61 = 979.

### 4. Lines I can't attribute (9)

| line | list | reason |
|---|---|---|
| `dependent_control_unknown_local.va` ×2 | cg, cc | R17 "cause not traced"; T5 landed and the line kept "parameter `amount`'s default does not fold". Needs one `-Dcodegen-why` run |
| `spice_subcircuit.va`, `subckt_source_card_drives_the_node.va`, `absdelay_ac_phase.va`, `exhaustive/parameters.va` | cc | "exit status old 0, new 1" with no stage list naming them (diff-codegen never compared them: a silent refusal before codegen, or a device not built). One diff-comp each |
| `vcvs_inside_a_spice_subcircuit.va` | cc | codegen.md C3 note: "refused construct + empty W0650 unit name, untraced" |
| `probe_in_continuous_assign_refused.va` | cr | old exits 1, new 0, in the run stage (std_sim): a mixed-signal refusal nobody plans; dlower or libmap, not codegen |
| `absdelay_history_past_capacity.va` (W1051) | cr | codegen.md C10 "T0 rechecks after a8e9": a8e9 landed, the line stayed. The old device warns when the 1024-sample history fills; the new ring grows to `hist_max` silently. Fix (warn at the same fill) or ruling: needs the run |

Not mine but on my owner (route, don't fix here): the 28 lower-category comp lines (lower.md C2, conversion.md), aliases 3 (lower T24), locations 2 (lower T31), `digital_function_from_analog_*` 2 (C6, Sema), W0650 presence 2 (airpasses T5), E0531 1 (airpasses G9), `gate_ordered_terminals.va` 1 (dlower), C3-routed 2, the 14 W025x/E0207 run codes (frontend/dlower, unplanned anywhere).

## Zero plan: air passes, digital lowering, front end (rw-zero, rw-dlower, rw-comp)

Read against int-w5 at a04a621c and `xfail_classes.tsv` (the lists there match the TSV line for line: comp 1770, sim 33, digital_exe 72, digital_device 32, rtlil 5). No build run.

Landed since the plans (changes what each task still clears): judge J0/J1/J3 (3ab64437) and frontend Q1's `deviceTiebreak` reject rule (comp.zig:361); airpasses T3 (909e20c5: the four G6 fixtures agree); dlower T0, T1, T2 (23bc8f65: coded run diagnostics, sim.rulings with 5 G13 lines); frontend T1 and T2 (e20308dd, 58b73c98); libmap T1, T2 (a04a621c); vbackends T1 remark rulings (8290fac6, `remarkTiebreak`). Not landed: airpasses T1, T2, T4, T5 (J2 + diff-float), T6; dlower T3, T4, T5, T6; frontend T3, T4, T5, T6, T7, T8.

Lines in the area: rw-zero 349 (comp) + rw-dlower 206 (comp 69, sim 33, digital_exe 70, digital_device 30, rtlil 4) + rw-comp 10 (comp 6, digital_exe 2, digital_device 1, rtlil 1) + W0650 lines owned by rw-lower 52 (comp) = **617**, plus 6 rw-lower comp lines whose symptom is the same W0650 but whose TSV category is lower's (`contribution N resist`), noted in row 3.

### 1. Categories

Lines are from the TSV; a split marked *derived* was read from the comp.xfail lines themselves (the first-difference text). "re-own" = the line leaves my owner for its real one without a code change in my area.

| # | category | type | lines (per list) | fixtures | clears it | coverage | wrong number? |
|---|---|---|---|---|---|---|---|
| 1 | zero: W0650 headline `unit N —  —` vs old `unit N — I(a,b) —` (*derived*: 258 of the 309 "message text W0650"; old and new both print the block) | message text | comp 258 | 258 | airpasses T1 (G1, G2, G10) | planned | n. The G2 share (~27 at plan time, old 2-5 units, new 1) then shows `exit 0 → 1`: J0 (landed) re-owns it to rw-codegen |
| 2 | zero: W0650 old warns at stderr line N, new prints nothing there (*derived*: 48; plan G8 was 45, so ~3 may be reordered blocks, estimate) | message text | comp 48 | 48 | airpasses T5 (J2 + diff-float falsification certificate), T6 for any imprecision it names | planned (Decision Q1) | n: the new side proves more; a non-finite point found by falsification fails the step, never lists |
| 3 | lower: extra diagnostic W0650 (owner rw-lower: new warns, old does not, old stderr has no other code so the judge falls through to rw-lower) | extra diagnostic | comp 51 (+6 with lower's category, same symptom: connect_insertion_follows_paramset_selection, connect_plain_discipline_override, connect_rule_parameter_is_applied, inserted_at_upper_connection_level, merged_is_the_default_one_instance, split_generated_names_defparam) | 51 (+6) | airpasses T2 (callee facts table, G7a: ~56 of 99 at plan time), then T5's witness (G7b, RULED §11.9) and T6 (G7c) | planned | n |
| 4 | dlower: run diagnostic with no `-->` (new line 2 is `= note: LRM …`): readmem W1157 ×21, W1150 ×9, W1156, W1154 closed channel, W1153 sformat excess, W1151 dist, E1102 sdf, run-time E1100 dumpports_same_file/dumpvars_later_time | location | comp 35 (run) + 2 (G5); digital_exe 35 + 2 | 37 | dlower T3 (`pc_sites`, G3/G5; blame table in dlower.md §2) | planned | n |
| 5 | dlower: W1199 one fixed sentence (old `` `$setup` in b_15_2_1_setup.u: timestamp …``) | message text (comp), location (exe), text (sim) | comp 21, sim 21, digital_exe 21 | 21 | dlower T3 (`Check.name`, G4) | planned | n |
| 6 | zero: transcript differs, hidden by the W0650 headline (G4): `noise count got=0` ×16, `meta count got=0`, `qsite lte`, paramset tie `got=10`, paramset selection `got=4`, wide card `got=0`, swept x `got=2`, timeUnit `got=0`, wreal `got=0`, spice_fet_card `res[d]` | location (really the transcript) | comp 25 | 25 | not air passes: J0 (landed) re-owns them once T1 makes the W0650 blocks equal; owners per airpasses §7: rw-codegen (noise, 16), rw-lower (paramset ×3, geometry, simparam, charge sites, meta, wreal, spice card) | planned re-own; the fixes are codegen's and lower's plans | **y** (24 of 25 are wrong numbers with no crash) |
| 7 | digital_device: libmap positives, old `--check` exit 1, new builds the device (cfg1-cfg6, command_line_search_order, config_overrides_command_line, default_search_order, include_map, parent_library_by_map, resolution_order, b_A_1_1_incdir, b_A_1_1_library_text) | new accepts | digital_device 13 | 13 | clearing now (libmap merge: 9e00fe7a retagged them rw-dlower; none is in digital_device.rulings yet) | clearing now | n |
| 8 | zero: G5/G11 run-time §4.3.2 and card checks the Zig device lacks: `Illegal instruction` for E0601 ×3, `thread panic` for E0602/E0603, exit 1 → 0 for runtime_log/pow/pow_constant/sqrt/transcendental/fatal_in_iteration, `narrow_check FAIL` modulo_integer_dynamic_zero | missing diagnostic / new accepts / message | comp 12 | 12 | re-own to rw-codegen (run): J3 is in the judge since 3ab64437, but these lines' owner text dates from b1cb5ffd (11-04); a full `-Dcomp-rebaseline` taking `.new`'s owners re-owns them (if it does not, the old E06xx precedes the banner and J3 needs widening). The fix is codegen's | planned re-own; fix outside my area | **y**: modulo_integer_dynamic_zero (`jac_const` says 0, a unit step moves the row). The 11 others: wrong answers (illegal value accepted, or a trap instead of E06xx) |
| 9 | digital_device: old `--check` exit 1, new builds (extra_ordered ×2, port_input_width_extends, port_output_width_truncates, ams_keywords_instance_names, 28_protected ×6) | new accepts | digital_device 11 | 11 | vbackends T7 (D3; Decision Q7). Each is a ruling candidate: old native codegen refused a legal design (E1103 class, digital_device.rulings already has 42 such) | planned (ruling) | n |
| 10 | dlower: config `design` cell no library holds, accepted (design_cell_missing, design_names_config, cell_not_in_its_library) | new accepts | comp 2, sim 3, digital_exe 3, digital_device 3 | 3 | dlower T4 (G7; Decision Q8: one owner, both sites) | planned | wrong answer: y (an illegal design accepted) |
| 11 | dlower G13/G9 shape rulings: forward_reference_reg (new adds the compile summary), recursion_without_end (stack MiB), forever_without_timing / zero_delay_always / zero_delay_loop (old blames token 0, new has no site yet), stop_suspends (old `$stop` byte 107 is inside a comment) | message / location / extra | comp 6, digital_exe 6 | 6 | comp.rulings +6 (lead; Decision dlower Q3) and digital_exe.rulings +6 (the `//! reject` tiebreak holds today for the 5 rejects; stop_suspends by gold stdout); dlower T3 gives the three budget ones their site | planned ruling (sim.rulings already rules 5 of them) | n |
| 12 | sim: a library-map or `-L` refusal diff-sim cannot see (config_in_map, library_without_path, source_text_in_map, two_libraries_match, b_A_1_1_include_without_path, b_A_1_1_include_without_semicolon, undeclared_library) | other / new accepts | sim 7 | 7 | dlower T6b: sim.rulings, IEEE 1364-2005 §13.2 (Decision libmap Q5); unblocked by the libmap merge | planned ruling | n |
| 13 | frontend G7/G13 parse-cascade rulings: keyword_function_name, reject_4_7_2_1 (old E0206 on recovered text), definition_inside_module (comp, exe, dev, rtlil), macro_text_1800 (exe copy of the comp ruling) | wrong code / location | comp 3, digital_exe 2, digital_device 1, rtlil 1 | 4 | frontend T8 (Decision Q2; Q1's deviceTiebreak rule is landed, so the digital_device line can be ruled too) | planned ruling | n |
| 14 | dlower: §3.8 attribute value not constant, accepted (attribute_value_is_constant_rejected) | new accepts | comp 1, sim 1, digital_exe 1, digital_device 1 | 1 | frontend T6 (`Vir.Process.attrs`) then dlower T5 (Decision dlower Q2) | planned | wrong answer: y |
| 15 | zero: exit 0 → 1 after the W0650s (behavioral_statements, modulo_integer_dynamic_nonzero, transition; G2's tail) | new refuses | comp 3 | 3 | airpasses T1, then J0 re-owns to rw-codegen | planned re-own | n |
| 16 | zero: W0651/W0653/W0951 printed after a none-located W0650 or as `parameter 0` (G3) | message text | comp 3 | 3 | airpasses T1 | planned | n |
| 17 | dlower: `--emit-rtlil` of defparam_absolute_out_of_array_element / defparam_across_generate_instances: old E1251/E1202 (the rtlil subset refusal, before elaboration), new Sema's §12.2.1 E1100 | wrong code | rtlil 2 | 2 | frontend T4 (G14: `rtlilRefused` moves before `Sema.elaborate`); the judge tags them rw-dlower | planned | n |
| 18 | dlower: old `--emit-rtlil` writes `autoidx 1` for a design it rejects (no_top_level_module, self_instantiation) | wrong number (stdout) | rtlil 2 | 2 | dlower T6a: rtlil.rulings, §12.1.1 / §12.1 (Decision) | planned ruling | n (stdout of a rejected design) |
| 19 | dlower: pinless top under old `--check` (b_B_keywords, dumpports_same_file) | new accepts | digital_device 2 | 2 | dlower T6a: digital_device.rulings, VAMS-2023 §7.8 (Decision) | planned ruling | n |
| 20 | dlower: W1150 (readmem_count_warning) and W1153 (native_sformat_dynamic) never printed by `--run` / `--emit-exe`; std_sim has the warn sites (readmem.zig:248, display.zig:265) and diff-sim lists neither | missing diagnostic | comp 2, digital_exe 2 | 2 | none | **unplanned** | n (a missing warning) |
| 21 | sim: dumpports_same_file `0 run diagnostics old, 1 new` (the old raises its E1100 at elaboration, the new as a run failure counted among the diags) | other | sim 1 | 1 | dlower T3 (or a T1 follow-up in tests/differential/sim.zig: count `failure` alike on both sides) | partly planned | n |
| 22 | comp: defparam_upward_value_cycle E0907 words (G10) | message text | comp 1 | 1 | frontend T3 | planned | n |
| 23 | comp: access_three_nets E0207 vs E0512 (G5) | wrong code | comp 1 | 1 | frontend T7 | planned | n |
| 24 | comp: scaled_delay_udp caret `^` vs `^^` (the 1364 one-byte rule, G17) | location | comp 1 | 1 | frontend T4 | planned | n |
| 25 | lower: noise_table_file_name_variable_rejected: old E0519, new only W0650 | wrong code | comp 1 | 1 | not W0650's: lower (E0519 not raised); rw-lower's plan | outside my area | wrong answer: y (an unusable noise table accepted) |
| 26 | digital_exe: 65 of the 70 rw-dlower lines have the old build remark as stderr line 1 and no digital_exe.rulings line (overlaps rows 4, 5, 11, 20). Once T3 makes the rest agree, the judge says `digital_exe (build remarks)` and each needs a `build remark:` rulings line | — | digital_exe 65 (overlap) | 65 | lead's rebaseline after T3: generate the lines (vbackends T1's script, `remarkTiebreak` exists) | partly planned (mechanism yes, lines no) | n |

Sums: rw-zero 258+48+25+12+3+3 = 349. rw-dlower comp 37+21+2+6+1+2 = 69, sim 21+3+7+1+1 = 33, digital_exe 37+21+3+6+1+2 = 70, digital_device 13+11+3+1+2 = 30, rtlil 2+2 = 4. rw-comp 7+1+1+1 = 10. rw-lower W0650 51+1 = 52.

Outside my owners but cleared by my plans' tasks: `reject_vera_timepoint_reads_iterate.va` (comp, rw-codegen: exit 1 → 0) is airpasses T4 (E0531 from `Air.Setup.timepoint`); a wrong answer (an illegal program accepted). The 21 comp `not built: backend libmap` lines: clearing now (libmap merge).

### 2. Unplanned

- Row 20 (4 lines): new dlower task T2b, `lib/std/sim/{readmem,display,exe}.zig` and `tests/differential/sim.zig`: why `--run` prints no W1150 for a four-load `$readmemh` with an explicit range and no W1153 for a run-time format, when the neighbours (readmem_warn_empty, sformat_excess_argument_warning) print theirs; and why diff-sim lists neither (either the old bag lacks them too, or the exe path drops them: an oracle hole either way, T1's class).
- Row 21 (1 line): fold into dlower T3's sim.zig change (count the old bag's failure and the new `failure` the same way).
- Row 26 (65 lines): a generated step, not a task: after T3, the lead's rebaseline writes one `build remark:` line per fixture whose only remaining difference is the remark (vbackends T1 mechanism).
- Row 8's fixes (12 lines) and row 6's (25) are codegen's and lower's: not planned here, only re-owned.

No new ruling candidate beyond the ones already decided (rows 9, 11, 12, 13, 18, 19): every remaining line is a fix.

### 3. Waves

Order: lists first (the README's "judge first" is done; what is left is attribution), then wrong answers, then text. No wrong number in my area is fixed here (rows 6, 8, 25 are re-owned to codegen/lower, where they go first).

#### Wave 0: lists, no code (now; parallel, every item touches a different file)

| task | files | clears | depends on |
|---|---|---|---|
| lead: full `-Dcomp-rebaseline` taking `.new`'s owners; retag row 6's 25 by hand per airpasses §7 (T1 is the only thing hiding them, and their owners should start now); comp.rulings +6 (row 11) | comp.xfail, comp.rulings | comp: 12 + 25 re-own, 6 ruled, 21 libmap drop | none |
| dlower T6a + T6b (+ the `$stop` byte test) | rtlil.rulings/.xfail, digital_device.rulings/.xfail, sim.rulings/.xfail, src/Sema/digital_test.zig | rtlil 2, digital_device 2 (+13 libmap if still listed), sim 7 | libmap merge (done) |
| vbackends T7 | digital_device.rulings/.xfail (after T6a: same file) | digital_device 11 (+1 rw-codegen D4) | a diff-digital-device run to read the old stderr |
| frontend T8 | digital_exe.rulings, rtlil.rulings, digital_device.rulings (after T6a/T7), comp.rulings lines to the lead | comp 3 (lead), digital_exe 2, digital_device 1, rtlil 1 | none |
| digital_exe.rulings +6 for row 11 (with T8, same file) | digital_exe.rulings/.xfail | digital_exe 3 now (forward_reference_reg, recursion, stop_suspends: no site needed); 3 after T3 | — |

#### Wave 1: the two big fixes and the wrong answers

| lane | task | files | clears | depends on |
|---|---|---|---|---|
| A | airpasses T1 | src/Sema/{Sema,contrib,op,param,discrete}.zig, src/Air/{Device,Float,Float/verdict}.zig, src/Air.zig (CallFacts.name), src/codegen.zig, new src/next/Compilation/air_passes.zig, src/next/Compilation/backend.zig, src/next/Compilation.zig, Compilation/test.zig | comp 258 + 3 (row 16); then J0 re-owns rows 6 and 15 (28) | none (rw-lower2's 6424a413 is merged) |
| B | dlower T3 | src/Sema/digital.zig, src/Sema/digital/{task,tchk,sysfn,sub,stmt}.zig, lib/std/sim/Builder.zig, src/next/Compilation/backend.zig, tests/differential/sim.zig, src/codegen/digital_next (`writeExe` argument, Decision Q5) | comp 58 (rows 4, 5), sim 21 (+1 row 21), digital_exe 57 agree modulo remark → row 26's rulings lines | T1, T2 (done); `bench-run` before/after (Decision Q6) |
| C | dlower T4 | src/Sema/library.zig, src/Sema.zig, src/Zcu.zig, src/next/Compilation/legacy.zig, src/Sema/test.zig | comp 2, sim 3, digital_exe 3, digital_device 3 | none (Decision Q7: merge order T4 before T3) |
| D | frontend T6 → dlower T5 | lib/std/vams/Vir/Inst.zig, lib/std/vams/AstGen/stmt.zig, AstGen test; then src/Sema/digital/decl.zig | comp 1, sim 1, digital_exe 1, digital_device 1 | none |
| E | frontend T4 | src/next/Compilation/{frontend,backend,errors,test}.zig | rtlil 2 (row 17), comp 1 (row 24) | after A and B merge (backend.zig) |

Parallel: A, C, D are file-disjoint except `src/Sema.zig` (A: `setSrc`; C: `configRoots` — distinct hunks) and `src/next/Compilation/backend.zig` (A removes `airPasses`, B renames `checkSites`: distinct hunks; merge B after A). D touches nothing the others do. E waits for A and B.

#### Wave 2: after T1

| task | files | clears | depends on |
|---|---|---|---|
| airpasses T2 | new src/Sema/call_facts.zig, src/sema.zig, air_passes.zig, src/Air/Float/Walk.zig, Compilation/test.zig | row 3's calls share (plan: ~56 of 99 then; of today's 57, unknown until run) | T1 |
| airpasses T4 | src/Sema/timepoint.zig, src/Air/Device.zig, air_passes.zig | comp 1 (rw-codegen-owned reject_vera_timepoint_reads_iterate; wrong answer) | T2 (same air_passes.zig) |
| frontend T3 | src/Sema/{eval,defparam,walk,test}.zig | comp 1 (row 22) | none; disjoint from T2/T4 |
| frontend T7 | src/Zcu.zig, src/Sema/{locate,contrib,test}.zig, lib/std/vams/Ast/errors.zig, src/next/Compilation/errors.zig | comp 1 (row 23) | E (errors.zig), A (contrib.zig) |
| dlower T2b (new, row 20) | lib/std/sim/{readmem,display,exe}.zig, tests/differential/sim.zig | comp 2, digital_exe 2 | B (sim.zig) |
| lead: row 26's generated rulings | digital_exe.rulings/.xfail | digital_exe 57 + 3 + 2 | B, T2b |

Parallel: T2→T4 sequential; T3 ∥ T2; T7 after E; T2b after B.

#### Wave 3: W0650 presence leaves diff-comp

| task | files | clears | depends on |
|---|---|---|---|
| airpasses T5 | tests/differential/comp/judge.zig (J2), new tests/differential/float.zig + float/ + float.xfail, tests/differential/lower/sides.zig, lower.zig, build/rewrite.zig | comp: row 2's 48 and row 3's remainder (RULED §11.9 by witness, or float.xfail lines) | T1, T2; rw-lower agrees to the `sides.zig` extraction (Decisions Q1, Q2, Q5 made) |
| airpasses T6 | src/Air/Interval.zig, src/Air/Float/Walk.zig, src/Air/Float/verdict.zig | float.xfail lines | T5 |

### 4. Lines I cannot attribute exactly

- Row 1 vs row 15/G2: the first-difference line of a dedupe fixture is still the unit-0 headline, so how many of the 258 become `exit 0 → 1` after T1 is the plan's 27, not a count from the list.
- Row 2: 48 vs the plan's 45: the ~3 extra may be reordered blocks (first-diff text cannot tell); T5's certificate sorts them.
- Row 3: the split of today's 57 into T2 (calls), T5 witness (§11.9) and T6 (unknown) needs the `--lint` runs the plan did at 90e93007; the plan's 56/36/7 were over 99 lines.
- Row 8: the re-own to rw-codegen (run) is expected from the landed J3 but unverified (the lines were not re-judged since 11-04).
- Row 17: attributed to frontend T4 by mechanism (old rtlil refuses before elaboration); the plan's G14 named three other fixtures that have since cleared.
- Row 20: cause unknown without one run (see §2).

## Zero plan: the VPI backend (114 comp lines) and `tools/diag_gaps.xfail` (726 lines)

Read-only, against `int-w5` (comp.xfail, codegen.xfail, `tools/diag_gaps.xfail`,
`research/{vpi,switchover,diagcodes,codegen,dlower}.md`, `tools/diag_gaps.py`)
and `xfail_classes.tsv`. Counts marked (est.) are estimates; every other number
is a `grep`/script count over the lists. Scratch script:
`scratchpad/dg_breakdown.py` (imports `diag_gaps.Model`, read-only).

### Part (a): `not built: backend vpi`, 114 comp.xfail lines

One `xfail_classes.tsv` category (`comp`, owner `not built`, type `not built`,
category `backend vpi`); all 114 come from `tests/differential/comp.zig:208`
(`if (f.lang == .vpi) return .{ .not_built = "backend vpi" }`). By directory:
ch11_vpi 29, ch12_vpi_routines 44, verilog/pli 41; 109 `.c` + 5 `.v` (a `.v`
runs through its same-stem `.c`, so it shares that `.c`'s fate). Grouped by
vpi.md §1's "last feature needed" table, re-counted from the list (matches
vpi.md exactly):

| category (vpi.md group) | type | lines | plan task(s) that clear it | coverage |
|---|---|---|---|---|
| G1 core: model, traversal, properties, phase cbs, printf/mcd | not built | 4 | V0a, V0b (oracle prong), V1 | planned |
| G2 values: get/put value | not built | 2 (`vpi_value_formats.c` + `.v`) | V2 | planned |
| G3 run + callbacks: time walk, cbs, sim_control, delayed put | not built | 27 (incl. 2 `.v`) | V3 (the `State.Vpi` seam in `lib/std/sim`) | planned |
| G4 digital systf: `$user` calls as Program rows | not built | 10 (incl. 2 `.v`) | V4 | planned |
| G5 behaviour: statements, decompile, cbStmt, assign/force cbs | not built | 11 | V5 (render), V6 | planned |
| G6 structure: primitives, specify, delays, tchks, attributes, arrays, protected | not built | 26 | V7 | planned |
| G7 analog model: disciplines, nodes, branches, analog systf registration | not built | 7 | V8 | planned |
| G8 analog run, design not on any other list | not built | 2 (`task_output_jacobian.c`/cube_solve.va, `systf_analog.c`/analog_system_task_registration.va) | V9a, V9b | planned |
| G8+G9 analog run, design on codegen.xfail (rw-codegen) | not built | 25 | V9a, V9b after codegen T18 (R13 "flow contribution to a potential source's branch": ramp_load 8, dc_divider 5, systf_devices 2, cap_ramp, sampnhold, analog_attributes = 18), T20 (R11 "call of a user function (callee N)": env_probe 2, two_sites, functype, square_law, env_twin = 6), T11 (R5 `ac_stim`: rc_ac = 1), T22 (`vpi_contribs`) | planned across two plans (vpi Q2 Decision: V9b after those lines clear; rw-codegen owns `systf_calls` + `vpi_contribs`) |
| total | | 114 | | |

The design lines themselves are 13 codegen.xfail lines + 8 comp.xfail lines
(rw-codegen), in plan-codegen's section, not here.

#### Will they agree once built?

V0b compares exit, stdout, stderr and written files byte for byte
(`judge.compare`). Every ch12 `.c` (44/44) carries a hand-derived `//! stdout`
/DERIVATION, and the old library passes all 114 today (`build/vpi.zig`
`vpi_runs`, `tools/vera.xfail` has no VPI line), so the old side meets every
derivation. Which tasks reproduce the old library and which re-derive:

| vpi.md task | reproduces old? | expected result on first compare |
|---|---|---|
| V0a host messages/usage/exit codes ("verbatim" from `host.zig:111-142,507-581`); V1 `vpi_get_vlog_info` (Q6 "as old"); V9b mixed-signal refusal ("same text") | yes, by construction | agree |
| V2 value text (differential `vpi_value.zig`: 10^5 values vs old `value_text.zig`); V5 render (byte-equal to old `decompile`, `diff-render`) | yes, with its own oracle | agree (G2, text half of G5) |
| V1 object model and `vpi_iterate` order (CSR lists from `Program.drivers`/`fan`; old `Builder.zig` lookup, `reverse_index.zig`, `attribute.zig` fold "not ported") | no: re-derived from Sema tables | new differences in iteration order on fixtures that print scans (G1, G3, G6) (est.) |
| V3 time walk and dispatch (`run.zig` 1046 -> ~700 lines; vpiReset = fresh `State.init`, old re-elaborated) | no: rewritten | new differences in callback order within a step (G3) (est.) |
| V6 cbStmt sites (`Lowered.stmt_sites` pcs; old AST sites); V7 delays (folded by Sema; old own fold); V8 node/branch order from `Air.Device` | no: re-derived | some differences (G5, G6, G7) (est.) |
| V9a/V9b analog walk over `std_sim.bench` (old: `lib/sim` runtime, `analog_walk.zig`) | no: a different engine | the 6 G8 fixtures that print the point sequence (accepted_point_sequence, forced_solution_points, convergence_test_rejection, fail_converge, sim_control_reject_step, repeated_analyses) likely differ |

Under the zero rule a ruling needs the old side wrong; here the old side meets
every derivation. So a new/old byte difference is either a new-side bug (fix)
or a byte the derivation does not pin, and the second kind has no ruling path
except vpi Q3's Decision (digits: the f128 tiebreak, "not a line"). Order and
point-sequence differences therefore must match the old library, not be ruled.
V0b itself changes no count: all 114 become `rw-vpi (<stage>)` lines with
real differences (refusal stubs) until V1+.

#### Unplanned or cross-plan (a)

| item | what it needs |
|---|---|
| vpi Q5 Decision: mixed-signal refusal becomes an `unsup-` code | a fixture or `tools/vera.xfail` line naming it in the same PR, or it lands as a new `unlisted` line in `tools/diag_gaps.xfail` (part b) |
| V4 adds `Config.user_systfs`; switchover P12 adds `Config.int_systfs` (ESPice) | one systf-registration field, not two: V4 extends P12's row |
| V3/V4 edit `lib/std/sim/{State,Interp,Program,Builder}.zig`, `src/Sema/digital/sysfn.zig`, which dlower.md also edits (dlower.md:31, :120) | a file-order entry: dlower's commits first, or one owner per file |
| V7's new `src/Sema/digital/attrs.zig` | the one attribute-list handle of frontend T6 + lower TV2 (README Decision) |

#### Waves (a)

| wave | tasks | clears | depends on | parallel |
|---|---|---|---|---|
| A0 | V0a, V0b, V5 | 0 (V0b moves 114 from "not built" to compared; lead rebaselines) | nothing (V0b on V0a's `library` signature) | all three |
| A1 | V1 -> V2 -> V3 -> V4 | 4 + 2 + 27 + 10 = 43 | A0; V3/V4 after dlower's std_sim commits | none inside (a chain); the wave runs beside codegen T11/T18/T20/T22 |
| A2 | V6, V7, V8 | 11 + 26 + 7 = 44 | V4 (V6 also V5; V7 the attrs handle) | all three |
| A3 | V9a -> V9b -> V10 | 2 now, 25 once the 13 codegen.xfail design lines clear | V8; codegen T11/T18/T20/T22; V10 needs ESPice's branch (vpi Q8) and gates switchover C2 and G0 condition 4 (`conformance-next` with the new library) | V9a beside codegen T22 |
| total | | 114 | | |

### Part (b): `tools/diag_gaps.xfail`, 726 lines

Not old-vs-new. `tools/diag_gaps.py check` (build/runs.zig:120-126, in `zig
build test`) joins `codes.zon` x raise sites (`src/**`, `lib/**`) x fixture
`//!` directives x the ledgers x the two vera xfails; every line is `<gate>
<subject>`, all 726 still "auto-seeded from the first real run" (the live
gates equal the file exactly: no new, no xpass). Gates present: `cite` 285,
`misuse` 253, `unlisted` 78, `nospec` 44, `untested` 36, `dead` 29, `ledger`
1. (`unknown` and `wording` are 0; `wording` reads only a code's first raise
site, so E0512's 33 new-side "not lowered yet" sites are invisible to it. A4's
E0575 is not in `codes.zon` yet.)

"Old-only" below = raised nowhere under the new roots (`src/Compilation*`,
`src/Sema*`, `src/Air*`, `src/codegen/{zig,digital_next,rtlil}*`, `lib/std`).

| gate (what it flags) | type | lines | sub-category | what clearing takes | plan task(s) | coverage |
|---|---|---|---|---|---|---|
| dead (live row with no raise site, or retired row with one) | catalogue | 29 | all 29 are `.kind = .retired`; their one "site" is the quoted spelling in the OLD catalogue table `lib/diag/code.zig:67-` (module `diag` = `lib/diag/root.zig`) | nothing: C4 deletes `lib/diag`; or now, `lib/diag` added to `RAISE_SKIP` (1 line) | switchover C4 | planned, implicitly (no plan names these lines) |
| untested (rule/syntax row with no `//! reject*`/`warn` naming it) | fixture | 36 | 20 raised both sides: one `_rejected` fixture each (W1150/W1151/W1156/W1199 need a runnable `.v`) | fixture | D7 | planned (D7 listed after C6b; nothing technical forces that) |
| | | | 6 D4 duplicates (E1224 E1240 E1244 E1245 E1246 E1247): row becomes an alias | catalogue merge | D4 | planned |
| | | | E1272 (rtlil refuses, engine warns W1161) | ruling once | D6 | planned |
| | | | 9 old-only (E0132 E0306 E0307 E0311 E0329 E0824 E1234 E1238 W1162) | Sema port + fixture | none (E1234: D5 split) | unplanned |
| unlisted (unsup row with no fixture and no vera.xfail reason naming it) | fixture + xfail line | 78 | 63 rtlil `E12xx` + 5 others raised both sides (68) | one positive fixture + `tools/vera.xfail` line each | diagcodes §7 "one xfailed positive fixture each under vera/rtlil" (no task number); A5 covers 14 | partly planned |
| | | | 10 old-only (E0997 E1004 E1149 E1200 E1232 E1242 E1243 E1271 E1274 W0250) | port the refusal, or retire the row once the new side accepts the construct | none | unplanned |
| misuse (shared fixture `//! reject*`/`warn` names an unsup/limit/lint/ice row) | fixture | 253 | E1100: 183 (A2 re-kinded the group code `unsup`; the digital fixtures that reject it) | split E1100 into IEEE rule keys (~270 sites) | D2a-e | planned (after C6b) |
| | | | W1157: 21 (`//! warn`, kind lint, V2005 17.2.9; siblings W1150/W1156 at 17.2.9 are rules "a warning shall be issued") | one kind ruling | A6 | planned |
| | | | 49 over 27 codes (A5's 32 files grew; 10 old-only codes among them, about 22 lines) | ruling + flip to positive + `vera/xfail` and `tools/vera.xfail` lines, or kind fix | A5 | planned |
| cite (fixture rejecting a rule row cites no clause equal/above/below the row's) | fixture or catalogue | 285 | 47 fixtures with no `//! lrm`/`inherited` line at all (12 of them `verilog/13_configuration`, E0244/E0243) | add the citation line | A6 + D1 suite PR | planned |
| | | | ~155 cite a different clause (est.) | fixture citation or catalogue clause corrected | A6 (data) | planned |
| | | | ~83 (est.) on the split queue: E0501 20, E0130 9, E0214 8, E0314 7, E0906 7, E0907 7, E0115 6, E0352 6, E0819 5, E0813 4, E0246 4 | new codes at raise sites | D3, D5 | planned (after C6b) |
| nospec (rule row's clause has no `-` ledger sentence) | ledger or catalogue | 44 | 16 `VERA-*` rows: VERA has no ledger by design (§1.2) but the gate does not exempt it | 1-line script exemption, or a VERA ledger from `docs/using/{attributes,limit}.md` | none | unplanned |
| | | | 26 AMS clauses (E0103 E0214 E0250 E0318 E0322 E0367 E0368 E0408 E0502 E0505 E0515 E0516 E0520 E0540 E0573 E0704 E0808 E0815 E0826 E0827 E0887 E0892 E0901 E0907 E0982 W0951) | an LRM reading per clause: ledger `pol` -> `-`, or the code's clause/kind | A6 | planned |
| | | | E0512 (33 new-side sites) | A4's E0575 | A4 | planned, not landed |
| | | | E0816 (dist.zig refusals under a rule code) | split | D5 | planned |
| ledger (a standard's ledger file missing) | ledger | 1 | `v2005`: `OBLIGATIONS-1364.tsv` absent from submodule a763eee (A1's seed is staged outside, README "Waiting on the user") | the user's submodule push; then A1b (hand `pol` over ~1600 rows) | A1, A1b | planned, user-gated |
| total | | 726 | | | | |

#### Mechanical vs compiler

| kind | lines | what |
|---|---|---|
| mechanical (a fixture, a ledger row, an xfail line, a catalogue column, a script line) | 439 | dead 29, nospec 16 + 26, ledger 1, untested 20 + 6 + 1, unlisted 68, misuse 21 + 49, cite 47 + ~155 (est.) |
| compiler (new raise sites, ports, splits) | 287 | misuse 183 (E1100), cite ~83 (est.), untested 9 ports, unlisted 10 ports-or-retires, nospec 2 (A4, D5) |
| of the mechanical, submodule edits (suite PRs through the user's push) | ~339 | cite 202, misuse 49, unlisted 68, untested 20, + their `vera/xfail` lines |

#### Which the old compiler also lacks

All 726: fixtures, the catalogue and the ledgers are shared, and no gate reads
which compiler. The only asymmetry is raise sites. Codes raised only on the
old side: dead 29 (the old table), untested 9, unlisted 10, nospec 9 (E0367
E0520 E0523 E0524 E0527 E0531 E0540 E0808 E0892), cite 12 codes (16 uses),
misuse 10 codes. After C4 each of these ~40 live codes turns into a `dead`
line unless ported or retired: that is the new compiler's extra gap. Nothing
goes the other way today (E0575 is not in the catalogue).

#### Waves (b)

| wave | tasks | clears | depends on | parallel |
|---|---|---|---|---|
| B0: no compiler, no submodule | `RAISE_SKIP` += `lib/diag` (or wait for C4); VERA exemption in `nospec`; the user pushes `OBLIGATIONS-1364.tsv` | 29 + 16 + 1 = 46 | the ledger line on the user | all three |
| B1: data, one suite PR series | A6 (26 nospec rulings, W1157 kind, cite triage), A5 (49 flips), the 47 missing citations + ~155 corrections, 68 unlisted fixtures + xfail lines, D7's 20 fixtures | 26 + 21 + 49 + 202 + 68 + 20 = 386 | A3 (landed); the user's push per suite PR; D7 as listed waits for C6b (lead's call: aliases resolve either way) | A5, A6, D7 fixtures, rtlil fixtures: file-disjoint by chapter |
| B2: compiler, before the switch | A4 (E0575, 33 sites) for E0512; 9 Sema ports for the old-only untested rules; 10 port-or-retire for the old-only unsup rows | 1 + 9 + 10 = 20 | A4 lands between lower's and dlower's Sema commits (diagcodes A4); retirements only once the new side accepts the construct | by file |
| B3: after C6b (Decision diagcodes Q2) | D2a-e (E1100 split), D3 + D5 (cite splits, E0816), D4 (6 aliases), D6 (E1272) | 183 + 83 + 1 + 6 + 1 = 274 | switchover C1-C6, C6b | D2a-e file-disjoint; D3 by code |
| total | | 726 | | |

The count moves on its own: up when `OBLIGATIONS-1364.tsv` lands (V2005
`nospec` wakes on a regex-seeded, provisional `pol`; size unknown until then)
and when vpi Q5's `unsup-` code lands without a fixture; down at C4 (dead 29)
and after each D-split.

### The diag_gaps scope question (facts, not a decision)

Does the zero rule cover `tools/diag_gaps.xfail`, or only the differential lists?

Facts that decide it:

1. No line has an old side. A ruling ("old side wrong, LRM clause") is
   undefined here; each line goes by a fixture, a ledger row, a catalogue
   edit, a script line or a code split.
2. The file sits in `tools/` beside `tools/vera.xfail`, not in
   `tests/differential/`. switchover.md's G0 condition 1 reads
   `tests/differential/*.xfail` only, so the switch-over gate as written
   excludes it. TESTING.md:52 lists it as the catalogue's named-gap list in the
   merge tier; it is already green by machine and ratchets (an xpass fails).
3. diagcodes.md Decisions bind the order: Q2 (phase A before G0, the flip at
   C6b, splits after) puts wave B3's 274 lines after the switch; Q10 fixes
   which gates are gated, so the 726 are exactly those gates' lines. Zero on
   this list is therefore reachable only after C6b, never at the switch.
4. ~339 of the 439 mechanical lines are submodule edits: suite PRs through the
   user's push queue, where A5 and the other submodule items already wait.
5. The count is not stable: +V2005 `nospec` when the IEEE ledger lands (A1b's
   ~1600-row reading first), +1 per new `unsup-` code without a fixture, -29
   at C4.

Cost of each answer:

| answer | cost |
|---|---|
| yes, the zero rule covers it | 726 lines: 287 compiler (E1100 ~270 sites in D2a-e, ~10 splits, 19 ports), ~339 submodule edits over several suite PRs, A1b before the V2005 lines are even known; by Decision Q2 it can gate C7 or the release, not the switch |
| no, differential lists only | the list stays a 726-line ratchet with no deadline; diagcodes.md §7's "after" column (misuse 0 after A5+D2, cite 0 after D2/D3, untested 0 after D7) is the only drain; B3 happens anyway (Decision'd tasks); the risk is B1's 386 data lines having no owner |
| a third reading the lead may put to the user | "zero" for this list at C7/release rather than at the switch, with B0-B2 (452 lines) before the switch and B3 after |

