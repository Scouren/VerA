# Research: the plans for the rest of the rewrite

Ten plans, written read-only by planners against `refactor` at 90e93007
(gate green, lists unchanged by `-Dcomp-rebaseline=true`). Each ends with its
open questions; every one has a filled `Decision:` line. Implementers follow
the plan's tasks in order and never redecide a `Decision:`.

| Plan | Owns | Lists it clears |
|---|---|---|
| `lower.md` | analog lowering in Sema (45 tasks) | lower.xfail 643, ~750 comp lines |
| `codegen.md` | `codegen/zig`, the Zig device backend (27 tasks) | codegen.xfail 516, comp lines |
| `airpasses.md` | Air passes, W0650, diff-float, judge fixes J0-J3 | comp lines, float.xfail |
| `dlower.md` | digital lowering into `std_sim.Program` | sim.xfail 26, comp lines |
| `frontend.md` | Ast, AstGen, InternPool, 1364 route | comp lines |
| `libmap.md` | library maps (`--libmap`, `-L`) | comp, digital_device |
| `vbackends.md` | digital_exe, digital_device, RTLIL | digital_exe 850, digital_device 65, rtlil 33 |
| `vpi.md` | the VPI library over the new pipeline | VPI fixtures |
| `diagcodes.md` (+ `diagcodes-map.tsv`) | spec-keyed codes, `tools/diag_gaps.py` | the gap report's gates |
| `switchover.md` | prerequisites P1-P12, switch C1-C8 | the end of `vera` |

## Decisions that bind several plans

- **Models (user, 2026-11-11).** Implementation agents run on Sonnet; research
  agents (a question the plans do not answer, an LRM reading, a rule fitted to
  fixtures) run on Fable. A rule the lead derived from fixtures alone goes to
  research before an implementer takes it (T39 -> `conversion.md`).
- **No file-length cap (user, overrides every plan).** The 500-code-line rule
  is dropped from AGENTS.md and `tools/check_style.py`. A plan task that
  splits a file only to meet that count is skipped; a split that names a
  transform (lower L0b's, done) stays.

- **Wrong numbers first.** In every plan, tasks fixing a silent wrong number
  run before code differences: lower's held/RNG/sum-order/short-circuit
  groups, libmap T3 (silent 0.0 probe), airpasses' domain fold, codegen's 75.
- **The judge first.** airpasses J0-J3, codegen Q5 and frontend Q1 are one
  lead commit to the comp judge before any list moves, so every line names the
  stage that changed.
- **A ruling needs the old side wrong** (or outside the contract), with its
  LRM clause. A cap or refusal the old side lacks is a regression, never a
  ruling: lower Q8 implements `u32` array cells. A cap no design reaches is a
  `limit-` code: codegen Q7, libmap Q3.
- **New is right** where the spec says so: `abs(+0)` via `@abs`, C `fmod`,
  correctly rounded `cosh`; `analysis()` stays real like the old side, since
  §4.6.1 names no type (rw-lower2's 0474ded2); the `libm_kernels` bound widens
  to match the oracle's accuracy (codegen Q1-Q3b, vpi Q3).
- **Messages:** secondary spans are notes with their own location
  (Zig `ErrorMsg.notes`), never labels (lower Q3).
- **Attributes:** frontend T6 and lower TV2 are one PR with one owner and one
  attribute-list handle (lower Q13, dlower Q2). Sema never reads the Ast.
- **One owner each:** G7's design-cell rule is dlower T4 (dlower Q8); the
  digital_device rw-codegen lines are vbackends T7 (vbackends Q7); the sim
  library-map lines are dlower T6b (libmap Q5).
- **Refuse, never pretend:** `--state=2` exits 2 (vbackends Q2); mixed-signal
  under VPI stays refused as an `unsup-` code (vpi Q5).
- **Codes:** clause keys with kind prefixes, old numbers as aliases; phase A
  and the gap report before G0, the flip at C6b (diagcodes Q1-Q2).

## Departures from Zig, to revisit after the switch-over

- Held variables are found by a Vir pre-pass, not an Air pass like
  `Air/Liveness.zig` (lower Q1).
- The 1364 one-byte location rule (frontend).
- Each plan's own "Departures from Zig" section; at C7 they all move into
  `docs/ARCHITECTURE.md` (switchover Q9).

## Order of work

0. Lead: merge ready worktrees (rw-lower2 to 6424a413, rw-codegen2's
   bench-fast, rw-dlower3, rw-native); the judge commit; retags (lower Q11,
   frontend Q5, dlower Q1) in one rebaseline.
1. Wave 1, file-disjoint, wrong numbers: libmap T3, lower's wrong-number
   tasks, airpasses' domain fold, codegen's wrong-number wave, diagcodes A2
   (switchover P6b needs `lookup`).
2. Then each plan's own task order, at most 5 implementers at once on the 2
   build slots (AGENTS.md, Building with many agents), honouring each plan's
   file-order table.
3. Switch-over prerequisites, measurement (P4), then C1-C8.

## Waiting on the user

- Pushing the conformance-submodule branch: fixture flips (diagcodes A5),
  stale headers (lower Q7), native markers (vbackends Q3).
- Filing GitHub issues for the changelog (switchover Q1).
- The AGENTS.md Layout rewrite at C7 (switchover Q10).
- Dropping the E1100 wording table after the switch (switchover Q8).
