# Plan: Air passes and the float guard (owner `rw-zero`, 461 comp.xfail lines)

Base: `refactor` at 90e93007. No rw-zero air-pass work is in flight: the last
air-pass commits (`750193c5`, `11cab6a5`, `08fec462`, `70f01868`) are merged;
worktree `agent-a9e9a7c040ea69ce8` (dec34c43) is 0 ahead and clean. Every other
"rw-zero" merge since is the exe backend. Start from `refactor`. **But** rw-lower2's
unmerged commits up to `6424a413` (worktree `agent-ad5e468e82bad6022`; also
merged into rw-comp3's worktree `agent-a90bdf8430320620a`, and carrying
`0474ded2` "analysis() is real") edit `src/Sema.zig`, `Sema/contrib.zig`,
`Sema/param.zig` and add `Sema/timepoint.zig`: T1 and T4 start after rw-lower2's
commits up to 6424a413 are merged into `refactor`.

Evidence: no builds. `--lint` runs of the already-built
`.claude/worktrees/agent-aa4cb6011fbcec340/zig-out/bin/{vera,vera-next}` (built
from 15298382; `git diff 15298382 refactor` touches no file on the analog
path) over every listed fixture. Group files: `scratchpad/zero/*.txt`
(`A_W0650_label.txt`, `B_new_only_W0650.txt`, `D_exit0_1.txt`, `D_runs.txt`, ...).

## 0. The one cause the lead suspected, confirmed

`src/codegen.zig:91-112` `floatRoots` builds each `Air.Float.Root` with only
`.refs`; `name` stays `""` and `loc` stays `.none`. `src/next/Compilation/backend.zig:90-108`
`airPasses` passes them on, and builds every `Air.Float.Param` with `.ranges`
only (no `name`, no `loc`), and passes **no `.calls`**. Consequences, all from
this one site:

1. `verdict.zig:388` prints `unit N —  — compiles...` (empty name).
2. With `root.loc == .none` the renderer prints no `-->`, no snippet, and drops
   the culprit label (`verdict.zig:391`), so the whole block differs.
3. `Diag.Wip` dedupes on (code, file, start) (`lib/std/vams/Diag/Wip.zig:127-148`):
   every W0650 of a device collapses into one (old 2-5 units, new 1: 25 lines of group D).
4. A none-located W0650 sorts first, ahead of W0951/W0651/W0653 (3 lines).
5. W0651/W0653 print `parameter 0` instead of `` `rs` `` (no `Param.name`).
6. No `calls` table: every `call` is `CallFacts{}` = `.unknown`, so `$temperature`,
   `$abstime`, `$mfactor`, `analysis()`, every integer/string-valued call
   (`$fopen`, `$fgets`, `str$cmp`, `$clog2`, ...) makes its root `.strict`: about
   56 of the 99 new-only W0650 fixtures (group B + D).

And one attribution bug in the oracle (`tests/differential/comp/judge.zig:154-170`)
keeps ~90 lines on rw-zero that are not air-pass differences (section 1, J0/J3).

## 1. Root causes (all 461 lines)

Count = comp.xfail lines. "Agree" = expected to agree after the fix;
"re-own" = leaves rw-zero for its real owner but still differs.

| # | group | count | examples | cause | fix |
|---|---|---|---|---|---|
| G1 | W0650 headline `unit N —  —` (old `unit N — I(a,b) —`) | 224 | `spice/passive_named_ports.va`, `spice/primitive_capacitor.va` | §0 items 1-2 | T1: agree |
| G2 | W0650 dedupe: old 2-5 W0650, new 1, then `exit status old 0, new 1` | 27 (D) | `ch04_expressions/noise_correlated_scale.va`, `spice/limit_pnjlimds_bulk_rung.va` | §0 item 3 (+ a later codegen/run failure) | T1 + J0: re-own (rw-codegen) |
| G3 | W0651/W0653/W0951 shown after a none-located W0650 or as `parameter 0` | 3 | `ch03_data_types/range_closed_on_inf_warns.va`, `ch04_expressions/divisor_unproven_accepted.va`, `spice/spice_paramset_shadow_warning.va` | §0 items 4-5 | T1: agree |
| G4 | transcript differs; W0650 blocks also differ, so `firstChanged` blames W0650; after T1 the `a[0]` fallback (`judge.zig:166`) still blames W0650 | 46 (F) | `ch04_expressions/correlated_noise.va` (`noise count got=0`), `ch06_hierarchy/mfactor_multiplies_a_flow_contribution.va` (`x[flow]` 1 vs 3) | not air passes: noise, mfactor, `$param_given`, paramset, `$simparam`, display width of `analysis()` | T1 + J0: re-own (see section 7) |
| G5 | runtime §4.3.2 errors the old device prints after the run banner (`=== name ===`), new device traps or exits 0 | 12 | `modulo_integer_display_zero.va` (`Illegal instruction`), `runtime_ln_domain_rejected.va` (`panic: division by zero`), `runtime_sqrt_domain_rejected.va` (exit 1 vs 0) | the Zig device backend has no run-time domain checks; the code (E0601-E0603) is proof-stage in `stages.zig:123`, so the judge blames rw-zero | J3: re-own (rw-codegen) |
| G6 | constant §4.3.2 violation folded by Sema to NaN/inf, so no E06xx and the program is accepted | 4 | `ch04_expressions/ln1p_domain_rejected.va` (E0603), `standard_math_domain_rejected.va` (E0602), `transcendental_domain_rejected.va` (E0605), `pow_negative_base_fractional_exponent_rejected.va` (E0609) | `src/Sema/fold.zig:118-131` folds `ln1p(-2.0)` etc. through `std_kernels.fold.math` (`lib/std/kernels/fold.zig:348-376`), which returns NaN/inf, never null | T3: agree. **Wrong answer: an illegal program compiles** |
| G7 | W0650 presence: new warns, old does not | 52 (B) + 43 (D) + 4 (E) = 99 | `ch09_system_tasks/temperature.va`, `ch05_analog_behavior/resistor.va`, `ch03_data_types/string_comparisons.va` | (a) no `calls` table, ~56; (b) §11.9 sound overflow: `V(p,n)/r` with `r from (0:inf)` reaches inf (old assumed finite), ~36; (c) unknown, ~7 (`idt` with `ic`: `op$static`/`idt$hold`) | T2 fixes (a); (b) is old-side unsound by the settled §11.9 (lib/TODO.md:450-466, :557-561): T5 witness; (c) T5 surfaces, T6 |
| G8 | W0650 presence: old warns, new does not | 45 (C) | `annex_a_syntax/expression_primaries.va` (old: array `fload` "a computed expression"), `ch05_analog_behavior/case_first_matching_item_wins.va`, `for_zero_iterations.va` | new proves more: arrays are slots, Sema folds `s = 2`, probes bounded by `default_unknown_bound = 10`. Old with `--unknown-bound=10` still warns on 38 of 45 (measured), so it is precision, not the bound | T5: certify by falsification, delegate |
| G9 | E0531 missing (`vera_timepoint` reads the iterate) | 1 | `ch05_analog_behavior/reject_vera_timepoint_reads_iterate.va` | Sema records no timepoint region; `Air.Setup.timepoint` (`src/Air/Setup.zig:256-270`) is never called | T4: agree |
| G10 | codegen-owned codes blamed on the W0650 mismatch | 4 | `ch11_vpi/analog_system_task_registration.va` (W0852), `ch12_vpi_routines/analog_systf_resistor_call.va` (W0852), `ch04_expressions/idt_abstol_dynamic_rejected.va` (E0515) , `ch09_system_tasks/sformat_runtime_width_past_its_row_rejected.va` | W0650 (proof) is earlier than codegen in `earliestUnmatched` | T1 + J1: re-own (rw-codegen) |
| G11 | old exit 1 at run, new 0, run-time rejects | 3 | `range_card_value_below_from_rejected.va`, `range_card_value_excluded_rejected.va` (E0377 card check), `fatal_in_iteration_terminates.va` ($fatal exit code) | runner / card check, plus a W0650 presence difference | J1 + J3: re-own (rw-codegen) |
| | **total** | **461** (224+27+3+46+12+4+99+45+1+4+3 = 468; 7 fixtures sit in two rows: G7's 4 E-lines include G6's 2 and G11's 2, G5's 12 include 3 G2/E overlaps) | | | |

Rulings (old side wrong): G7(b) only. Clause: VAMS-2023 §4.3.2 and the
project's settled lib/TODO.md §11.9 ("The float verdict is proven, never
assumed"; IEEE 754 round-to-nearest: `20 / 5e-324 = inf`). Not an LRM clause
about W0650 itself: W0650 is VerA's lint, so its tiebreaker is a witness, not
a fixture's `//! lrm` line (T5).

## 2. Fixes

### T1: name and place every float diagnostic (G1, G2, G3, G10; wrong text)

Old side to match:
- `src/prove/verdict.zig:118-163` `warnNotFinite`: headline
  `unit {d} — {V|I}({hi},{lo}) — compiles with @setFloatMode(.strict)` (`V` iff
  `access == .potential`; ground spelled `gnd`, `src/ir/Lowered.zig:1069-1073`),
  at `tokenSpan(c.tok)`; label at the culprit's span; help by culprit kind.
- `c.tok` = `mainTok(lhs)` of the first `<+` that made the row
  (`src/analog/contrib.zig:165`, `accum.zig:34-58,87-94`), the indirect's lhs
  (`analog/indirect.zig:90`), the operator call for an operator-state row
  (`analog/reactive.zig:99-103`; the `idt` token, rendered `^^^`).
- `src/prove/message.zig:107-127` `describe`: `parameter `{name}``,
  `a probe of node `{name}``, `the constant {d}`, `the result of `{name}()``,
  `an expression of {leaf}`, `a computed expression`.
- `src/prove/seed.zig:160-182` W0651 at the parameter's declaration token
  (`analog/param.zig:234,291`: `decl.main_tok`).

Data (no new table; one existing side table gets two more kinds of row):
`Sema.Analysis.srcs` (`src/Sema.zig:146-150`) is "where each Air instruction
was written". T1 extends it to two instruction kinds that have none today:
an `arg` gets its parameter declaration, and a contribution row's `resist`
`alloc` gets the first `<+` target (or operator call) that declared the row.
Rule, written in the `srcs` doc comment: "an `alloc` or `arg` points at the
declaration that made it". Zig mirror: source locations live beside the IR,
resolved only when a message is rendered (`Zcu.zig:217` `LazySrcLoc`,
`Sema.zig:2641` `errMsg`); Air holds none.

Six questions (new `Float.Input.probe_names`, `CallFacts.name`):
1. In: `Device.nodes.items(.name)`, SysFn spellings. Out: words in W0650/E06xx.
2. One per solver unknown (≤ `Device.rows_max`); one per SysFn tag (comptime).
3. Slices into the InternPool / static strings; cold, never on a hot path.
4. Random access by probe index / callee, only when a diagnostic is built.
5. `comp.arena()` for `probe_names`; static for `CallFacts.name`.
6. No.

Changes, in order:

| file:line | change |
|---|---|
| `src/Sema.zig:364-372` | factor `addInst`'s src write into `pub fn setSrc(s: *Sema, i: Air.Inst.Index, file: Zcu.File.Index, src: Inst.Ref) Allocator.Error!void` (grows `inst_srcs` with `.none` like today, then writes). Asserts: `@backingInt(i) < s.air.instructions.len`; after, `s.inst_srcs.items.len > @backingInt(i)`. `addInst` calls it. Update `Analysis.srcs` doc (line 146) with the alloc/arg rule. |
| `src/Sema/contrib.zig:230` | `pub fn rowOf(s: *Sema, b: *const Block, t: Target, src: Inst.Ref) ...`: on a new row only, `try s.setSrc(resist, b.unit.file, src)`. Doc: "`src` is the access call (`I(p,n)`) or operator call that declared the row; W0650 points at its name". |
| `src/Sema/contrib.zig:124` (`contribute`) | `rowOf(s, b, t, x.lhs)` (the Vir call; `locate.inst` gives its callee-name token, `src/Sema/locate.zig:72-84`, the old `mainTok(lhs)`). |
| `src/Sema/contrib.zig:172-185` (`indirect`) | after the append, `try s.setSrc(row's resist, file, x.a)`. |
| `src/Sema/op.zig:289` `stampOpRow` | pass `s.expr_src` (the operator call being lowered: `expr.zig:63-65` sets it for the call) to `rowOf`. |
| `src/Sema/param.zig:130`, `:203`, `src/Sema/discrete.zig:112` (and every `.tag = .arg` site rw-lower2's commits add, e.g. its `systemAlias`) | after each `arg` `addInst`: `try s.setSrc(arg, unit.file, <the param's Vir decl ref>)` (`i.toRef()`; `addRow` gains a `src: Inst.Ref` parameter, `declareArray` passes `i.toRef()`; paramset rows pass the paramset param `i`). |
| `src/Air/Device.zig` | `pub fn nodeName(d: *const Device, ip: *const InternPool, n: Node.Index) []const u8` (ground: `"gnd"`; asserts `n` is ground or `< nodes.len`). `Sema/contrib.zig:295` `nodeName` calls it (one spelling of ground). |
| `src/Air.zig:288` `CallFacts` | add `name: []const u8 = ""` ("the callee's spelling, for messages"). |
| `src/Air/Float.zig:180-190` `Input` | add `probe_names: []const []const u8 = &.{}` ("one per `probe` index: the unknown's name, for messages"). |
| `src/Air/Float/verdict.zig:145-175` `Who` | `.probe`: `a probe of node `{s}`` from `in.probe_names` (fallback `a probe of unknown {d}`); `.call`: `the result of `{s}()`` from `in.calls[callee].name` (fallback `the result of a call`). |
| `src/Air/Float/verdict.zig:384-405` `warnNotFinite` | help for `.call`: `facts.range == .limexp or .vt` -> "constrain the operands with a range or a guard the prover can see"; else "the prover does not model `{name}()`, so its range is unknown" (old `verdict.zig:144-156`). New asserts: `if (in.locs.len != 0) assert(!root.loc.isNone())`; `if (in.locs.len != 0) assert(root.name.len != 0)` (a caller that locates instructions must locate and name its roots: the bug class of §0). |
| `src/codegen.zig:91` | `floatRoots` returns `[]Air.Float.Root` (mutable; names stay the caller's). |
| new `src/next/Compilation/air_passes.zig` | move `airPasses` + `floatRanges` here (`backend.zig` is at ~497 code lines; this adds ~40). `pub fn run(comp: *Compilation) !bool`: roots from `floatRoots`; for root `k`: `.name = "{V|I}({hi},{lo})"` via `Device.nodeName`, `.loc = locs[resist[k]]`; params: `.name = ip.stringToSlice(params.name[k])`, `.loc = locs[arg_k]` (the `arg` whose `ty_index.index == k`: one pass over the prologue); `probe_names` from `device.nodes`; `.calls` (T2). Asserts: `roots.len == device.contributions.len`; every root `name.len != 0`; `params.len == device.params.len`. `Compilation.zig:269` calls `air_passes.run`. Zig mirror: `Zcu/PerThread.zig:4502` `runCodegenInner`, the job that runs the Air passes for a function and acts on them (`Air.Verify.run` 4525, `air.legalize` 4527, `Liveness` 4533, `Liveness.Verify` under `runtime_safety` 4551). |

Expected: G1 224 + G3 3 agree; G2 27, G10 4 re-own (with J0/J1).

### T2: the callee facts table (G7(a), ~56 lines; precision)

Old side: `src/prove/transfer.zig:75-115` `callAbstract` (int-typed -> i64
range finite; str -> finite; `analysis`, `analog$initial`, `initial_step`,
`final_step`, `cross`, `above`, `timer`, `op$static` -> [0,1];
`$vt`/`$temperature`/`$mfactor` -> >0; `$abstime`/`$realtime` -> ≥0; else
unknown), `Prover.callTransfer` (`limexp`, `$vt(T)` from the argument),
`invariance.zig:370-390` `callInvariant`, `timepoint.zig:101-112`
`callTimepoint`, the first-point flag (`analog$initial`).

Data: new `src/Sema/call_facts.zig`:
```zig
/// What the Air passes know of each SysFn callee (`Air.Call.callee` is the
/// tag's integer): the old prove/transfer.zig `callAbstract`, invariance.zig
/// `callInvariant`, timepoint.zig `callTimepoint`. `user_callee` is past the
/// end: unknown.
pub const table: [@typeInfo(SysFn.Tag).@"enum".fields.len]Air.CallFacts = blk: { ... facts(tag) for each tag ... };
fn facts(t: SysFn.Tag) Air.CallFacts // exhaustive switch over the special tags; `else` by `SysFn.get(t).ty`: .int -> .int, .str -> .finite, .real/.none -> .unknown, with `// else: every other callee is typed by its row`
```
`name = @tagName(t)` in every row. Comptime: `assert(table.len == @typeInfo(SysFn.Tag).@"enum".fields.len)`;
`comptime for (table) |f| if (f.first_point) assert(f.range == .unit or f.range == .int)`.
Six questions: in SysFn.Tag, out CallFacts; ~170 rows; 1 byte enum + 3 bools + a
slice; read per `call` instruction by index; static; n/a. Zig mirror:
`lib/std/zig/BuiltinFn.zig:153` `list` (a comptime table of builtin facts the
compiler switches on, never strings). Re-export `pub const call_facts` from
`src/sema.zig`.

`air_passes.run` passes `.calls = &sema.call_facts.table`; assert
`calls.len == @typeInfo(vams.SysFn.Tag).@"enum".fields.len`.

`src/Air/Float/Walk.zig:300-305`: argument-free `$vt` is `.positive`
(`const range = if (facts.range == .vt and x.data.args_len == 0) .positive else facts.range;`),
as old `callAbstract` had it.

Expected: the calls share of G7 (~56) agree when the rest of the proof
matches; whatever remains is G7(b)/(c), shown with its culprit after T1.

### T3: constant §4.3.2 violations are not folded (G6, 4 lines; wrong answer first)

Old side: the old MIR keeps `ln1p(-2.0)` as a call; `src/prove/domain.zig`
reports E0603 "ln1p() is the constant -2 with known range [-2:-2]".
New: `Sema/fold.zig:118` `tag` folds it to NaN; Float never sees a call.

Fix, one site every caller routes through (`expr.zig:95,102`):
- `src/Air.zig:327` `Domain`: `pub fn admits(d: Domain, x: f64, y: f64, y_int: bool) bool`,
  the point form of each domain (Table 4-14/4-15; `nonzero_divisor`: `y != 0`;
  `pow_sign`: `x > 0 or (x == 0 and y > 0) or (x < 0 and y_int)`;
  `tan_poles`: true; `positive`: `x > 0`; ...). A NaN operand admits (NaN in,
  NaN out is not a domain error). Zig mirror: a per-tag predicate kept in Air,
  `Air.zig:1929` `mustLower`.
- `src/Sema/fold.zig:118`: `if (!Air.tag_info.get(t).domain.admits(x, y, y_int)) return null;`
  before folding (left to run time, so `Float` reports E0601-E0609 with the
  operand "the constant -2").
- Paired check, `src/Air/Float/domain.zig` test: for every tag with
  `domain != .all` and every pair from a grid {±0, ±0.5, ±1, ±2, -1-2^-52, ±inf, NaN,
  floatTrueMin, floatMax}, `check(t, .point(x), .point(y), y_int).state == .violated`
  iff `!admits(...)` (except `tan_poles`: never violated). Two implementations,
  one interval and one point, held to each other.

Departure from Zig: Zig's Sema raises the comptime error itself
(`Sema.zig:2353` `failWithDivideByZero`). Here Sema leaves the instruction for
`Air.Float`, the one reporter of E0601-E0609 (stage `.proof` in
`tests/differential/stages.zig:123`), so a constant and a ranged parameter get
the same words.

Expected: 4 agree.

### T4: E0531 from `Air.Setup.timepoint` (G9, 1 line)

Depends on rw-lower2's `Sema/timepoint.zig` (its commits up to 6424a413, worktree agent-ad5e468e82bad6022, merged into refactor) and T2 (`timepoint` facts).
Old side: `src/codegen/device/prepare.zig:176-190` `reportTimepoints`
(code E0531 at the statement token, label "this value can change between
iterations" at the value's token), over `Lowered.timepoints` (`src/ir/Lowered.zig:195,798`).

Data: `Device.timepoints: std.MultiArrayList(Timepoint)`, `Timepoint = struct { region: Air.Inst.Index }`
(u32; ≤ rows_max; read once by `air_passes.run`; same lifetime as `Device`).
Sema (`Sema/timepoint.zig`'s `enter`): lower the attributed statement into its
own `block` and append the row; `setSrc(block, file, statement src)`.
`air_passes.run`: per row, `if (try Air.Setup.timepoint(gpa, air, ip, calls, region)) |v|`
build `.codegen, .E0531` at `locs[region]`, label at `locs[v]`. Zig mirror:
`Zcu/PerThread.zig:4502-4560` (`runCodegenInner`: a pass run by the job, its result acted on there).

Expected: 1 agrees; `vera_timepoint_cache.va` (rw-codegen) is the legal neighbour to keep green.

### T5: the W0650-presence oracle `diff-float` and the judge (G4, G5, G7(b), G8, G10, G11)

Needs the lead's approval (open question Q1/Q2): it changes what
`diff-comp` compares and who it blames.

Judge (`tests/differential/comp/judge.zig`):
- **J0** `owner` (`:166`): when `firstChanged` is null (every diagnostic
  block matches), the difference is the run's text: `rw-codegen (run)` /
  `rw-dlower (run)`, never `a[0]`'s stage.
- **J1** `earliestUnmatched` (`:174`): W0650 is not counted (its presence is
  `diff-float`'s).
- **J2** `compare` (`:140`): before comparing stderr, delete each W0650 block
  whose `unit N` the other side lacks, and every `warning: N warning(s) emitted`
  line (derived data). Blocks both sides have are still compared byte for byte.
- **J3** `codes`/`stageOf`: a code after the run banner (`=== <name> ===`) is
  stage `.run`.

New oracle `tests/differential/float.zig` (+ `float/`), step `diff-float`
(`build/rewrite.zig` row, imports as `diff-lower` plus `prove`), list
`tests/differential/float.xfail` (owner rw-zero). Shares the both-sides
setup with `diff-lower`: extract `checkFixture`'s old/new lowering
(`tests/differential/lower.zig:174-330`) into `tests/differential/lower/sides.zig`
(coordinate with rw-lower2; no behaviour change, `diff-lower` byte-identical).
Per analog fixture whose tables agree:
- old `prove.proof.prove(...)`.unit_modes vs new `Float.analyze(...)`.verdict.modes, unit by unit;
- new `.optimized`, old `.strict` (G8): certify by falsification: 10^3 seeded
  points inside the root's guard box (`Guard.admits`), `Air.interp.run` with an
  `Observer`, every value on the slice finite; any non-finite fails the step
  (a soundness bug, not an xfail);
- new `.strict`, old `.optimized` (G7): certify by a witness: candidate values
  per input (a probe: `{-B, -1, 0, 1, B}`; a ranged parameter: each closed end,
  `nextUp`/`nextDown` of an open end, `floatTrueMin` when 0 is an open lower end,
  the default; an unranged real: `{±floatMax, ±floatTrueMin, 0, 1, default}`),
  the full product when it is ≤ 4,096 points, else 4,096 seeded picks; a witness
  is a point where a slice value is ±inf or NaN. Found: an old-side bug, counted
  and printed as RULED §11.9. Not found: a `float.xfail` line (new imprecision,
  rw-zero's T6);
- calls the interpreter's `Calls` hook answers from `CallFacts.range` (a
  representative value: 300.15 for `$temperature`, 0/1 for `.unit`, ...);
  `error.Unsupported` makes no claim at that point.
Six questions: per fixture, roots ≤ contributions, inputs ≤ params + nodes;
`f64` points; read sequentially; per-fixture arena; fixtures run in parallel
like `diff-lower`. Runtime budget: merge tier ≤ 3 min (`-Dfull-oracles` for 10^4 points).

Expected: G4 46, G5 12, G10 4, G11 3 re-own; G7(b) and G8 (~80) leave
`comp.xfail` for `diff-float` (RULED or `float.xfail`).

### T6: new imprecision `diff-float` lists (G7(c), ~7, unknown until T5)

One line per `float.xfail` entry: fix the transfer or slice rule in
`src/Air/Interval.zig` / `Float/Walk.zig` / `Float/verdict.zig`, re-run
`diff-air-passes` (soundness) and `diff-float`. First suspects: `idt` with an
`ic` (`op$static` select, `Sema/op.zig:265`) and `idt$hold` (`:267`) with no facts.

## 3. Oracles and red-first

| task | oracle (named before code) | planted fault that must go red first | new oracle for the bug class |
|---|---|---|---|
| T1 | old `vera` via `diff-comp` on G1/G3 fixtures; the old renderer's text is the spec | (a) leave `root.name` empty: the new unit test fails; (b) leave `root.loc = .none`: the `warnNotFinite` assert fires; (c) drop `probe_names`: the probe-culprit test fails | test in `src/next/Compilation/test.zig`: "W0650 names each unit and points at its `<+`": two contributions `I(p,n) <+ V(p,n)/r; I(a,b) <+ V(a,b)/r;` with `r` unranged give two W0650, headlines `unit 0 — I(p,n) —` and `unit 1 — I(a,b) —`, locations `I` on each line, culprit `an expression of parameter `r``; plus `Input.unknown_bound = inf` gives `a probe of node `p``. Plus the two asserts (the class "a pass input built without its names") |
| T2 | old `callAbstract` (transfer.zig:75-115) | drop `.calls` in `air_passes.run`: the comptime/len assert fires; with the assert removed, the test below fails | test: `I(p,n) <+ V(p,n) * analysis("dc")` and `I(p,n) <+ V(p,n) + $fopen("x")` rate `.optimized` (old does); `$vt()` argument-free is `.positive`. `diff-float` (T5) is the corpus oracle for "a table left empty in production" |
| T3 | the four fixtures' `//! reject` codes and old E06xx text | remove the `admits` guard: `ln1p(-2.0)` compiles, the test fails | the domain.zig paired test (interval check vs point `admits`); Sema test: `fold.tag(.ln, &.{.{ .real = -1 }}) == null`, `fold.tag(.ln, &.{.{ .real = 1 }}) != null` |
| T4 | the fixture's `//! reject-only E0531`; old `prepare.zig:176` | skip the `Setup.timepoint` call: the fixture and a Sema test (region recorded, E0531 raised) fail | `vera_timepoint_cache.va` (legal neighbour) stays green |
| T5 | interpreter (`Air/interp.zig`, independent of Float) for both certificates | (a) reinstate the overflow contract in `Interval`'s `fdiv` transfer: `diff-float`'s falsification fails on `resistor.va`; (b) make the witness search return null: G7(b) fixtures become `float.xfail` lines (the stale-line check fails); (c) J0 reverted: judge unit test fails | judge unit tests over synthetic stderr pairs (J0: same W0650 blocks + different transcript -> `rw-codegen (run)`; J2: W0650-only presence -> equal; J3: E0601 after the banner -> run) |

## 4. Tasks (one Sonnet agent each)

| id | depends on | files | wrong number? |
|---|---|---|---|
| T3 | — | `src/Air.zig` (Domain.admits), `src/Air/Float/domain.zig` (test), `src/Sema/fold.zig` | yes: illegal program accepted |
| T1 | rw-lower2's commits up to 6424a413 (worktree agent-ad5e468e82bad6022) merged into refactor | `src/Sema.zig`, `src/Sema/contrib.zig`, `src/Sema/op.zig`, `src/Sema/param.zig`, `src/Sema/discrete.zig`, `src/Air/Device.zig`, `src/Air.zig` (CallFacts.name), `src/Air/Float.zig`, `src/Air/Float/verdict.zig`, `src/codegen.zig`, new `src/next/Compilation/air_passes.zig`, `src/next/Compilation/backend.zig` (remove moved code), `src/next/Compilation.zig:269`, `src/next/Compilation/test.zig` | no (wrong text) |
| T2 | T1 (same `air_passes.zig`, `Air.zig`) | new `src/Sema/call_facts.zig`, `src/sema.zig`, `src/next/Compilation/air_passes.zig`, `src/Air/Float/Walk.zig`, `src/next/Compilation/test.zig` | precision |
| T4 | T2; rw-lower2's commits up to 6424a413 (worktree agent-ad5e468e82bad6022) merged into refactor | `src/Sema/timepoint.zig`, `src/Air/Device.zig`, `src/next/Compilation/air_passes.zig` | wrong answer (accepted) |
| T5 | T1, T2; Q1/Q2 approved; rw-lower2 agrees to the `lower/sides.zig` extraction | `tests/differential/comp/judge.zig` (+ its tests), new `tests/differential/float.zig`, `float/`, `float.xfail`, `tests/differential/lower/sides.zig`, `tests/differential/lower.zig`, `build/rewrite.zig` | oracle |
| T6 | T5 | `src/Air/Interval.zig`, `src/Air/Float/Walk.zig`, `src/Air/Float/verdict.zig` | precision |

T3 runs in parallel with everything (its `Air.zig` hunk is `Domain`, T1's is
`CallFacts`: separate hunks). T1 -> T2 -> T4 sequential (shared `air_passes.zig`).
T5 can start its judge half (J0-J3) right after T1.

## 5. Commands (W = the task's worktree; `.zig-cache` and `tests/conformance` symlinked per docs/rewrite/README.md)

Every task, before commit:
`~/.cache/vera-heavy.sh W check test-air test-sema test-codegen`,
`~/.cache/vera-heavy.sh W diff-air-passes`, `~/.cache/vera-heavy.sh W test-unit`,
`~/.cache/vera-heavy.sh W rewrite`, `python3 tools/check_style.py <files>`,
`nix develop -c zig fmt --check <files>`; gate on `$?` (`cmd > log 2>&1; echo $?`).

| task | targeted gate |
|---|---|
| T1 | `~/.cache/vera-heavy.sh W diff-comp -Dcomp-filter='spice/passive_named_ports|spice/primitive_capacitor|ch04_expressions/noise_correlated_scale|ch03_data_types/range_closed_on_inf_warns|ch04_expressions/divisor_unproven_accepted|spice/spice_paramset_shadow_warning|annex_f_resolution/digital_behavioral_net_is_digital'`, then the whole G1 list: `-Dcomp-filter="$(awk '{print $1}' scratchpad/zero/A_W0650_label.txt scratchpad/zero/A2_W0650_other.txt | paste -sd'|')"`; `~/.cache/vera-heavy.sh W diff-lower` (Sema srcs must not move a table) |
| T2 | `-Dcomp-filter='ch09_system_tasks/temperature.va|ch09_system_tasks/abstime.va|ch03_data_types/string_comparisons|ch09_system_tasks/fgets|ch06_hierarchy/mfactor.va|ch09_system_tasks/vt_temperature'` |
| T3 | `-Dcomp-filter='ln1p_domain_rejected|pow_negative_base_fractional|standard_math_domain_rejected|transcendental_domain_rejected|ln1p_expm1|standard_math_traditional|transcendental_math'` (the neighbours stay green); `~/.cache/vera-heavy.sh W diff-kernels` |
| T4 | `-Dcomp-filter='vera_timepoint'` |
| T5 | `~/.cache/vera-heavy.sh W diff-float`, `diff-lower` (byte-identical report), `diff-comp -Dcomp-rebaseline` and hand `zig-out/comp.xfail.new`'s owner diff to the lead |
| T6 | `diff-air-passes -Dfull-oracles`, `diff-float` |

Lists a task may change: `air_passes.xfail` (T6 only, if a transfer changes),
`float.xfail` (T5, T6). **Never `comp.xfail`**: each task reports the lines
it expects to clear and the `-Dcomp-rebaseline` diff.

## 6. Skills where they bite

- data-oriented-design: six answers above for `probe_names`, `CallFacts.name`,
  `call_facts.table`, `Device.timepoints`, diff-float's per-fixture arrays; no
  new hot row (all cold, message-only or once per compile).
- compiler-construction: rule 4 (call facts as a table, exhaustive switch, `// else:`
  with reason), rule 5 (codes and words unchanged: only their inputs), rule 3
  (passes read `*const Device`, Compilation fills `Input`), rule 9 (T1 keeps
  every non-W0650 golden byte-identical: `diff-lower` unchanged).
- assertions: two per changed function (listed per row in §2); `setSrc`
  entry/exit pair; `admits` vs `check` pair; comptime table-length asserts.
- code-style: `backend.zig` is at the 500-line edge, hence `air_passes.zig`;
  `Sema/contrib.zig` (455) and `verdict.zig` (341) stay under.
- doc-comments: every new `pub` (`setSrc`, `nodeName`, `admits`, `call_facts.table`,
  `probe_names`, `CallFacts.name`, `air_passes.run`) carries its fact and asserts;
  `//!` `Contents:` lists updated.
- api-design: caller owns memory (`probe_names` in the comp arena), no callbacks
  added (diff-float's `Calls` hook is the interpreter's existing seam).
- test-plan / tdd: oracle before code, planted fault red first (§3); G1-G11
  each mapped to an oracle; flaky-free (seeded).
- zig, simd-loops: no SIMD (rule 8: the compiler stays scalar); spice-engine,
  writing-perfect-verilog: not on this path.
- ponytail: no new pass, no new IR: one side-table rule, one facts table, one
  predicate, one moved function.

## 7. Lines that leave rw-zero for another owner (report to the lead)

| to | count | lines | note |
|---|---|---|---|
| rw-codegen (run) | 12 (G5) | `modulo_integer_display_zero`, `modulo_integer_unused_zero`, `modulo_real_dynamic_zero`, `runtime_ln_domain_rejected`, `runtime_ln1p_domain_rejected`, `runtime_log_domain_rejected`, `runtime_pow_constant_exponent_rejected`, `runtime_pow_domain_rejected`, `runtime_sqrt_domain_rejected`, `transcendental_domain_runtime_error`, `modulo_integer_dynamic_zero` (`narrow_check FAIL: dres[p]/dx[p]`), `fatal_in_iteration_terminates` | the Zig device has no run-time §4.3.2 checks; a trap is a crash, not E0601 |
| rw-codegen | 27 (G2) + 4 (G10) + 2 | G2 exit 0 -> 1 after the W0650s; W0852 x2, E0515, sformat width; `range_card_value_{below_from,excluded}_rejected` (E0377 run-time card check) | |
| rw-codegen (noise) | 21 of G4 | `noise count got=0` | |
| rw-lower | ~12 of G4 | `$param_given` x4, paramset defparam x3, `hierarchy_empty_paramset_tie`, `geometric_position_*`, `geometry_parameter_sweep`, `simparam_timescale`, `mfactor_multiplies_a_flow_contribution` (x[flow] 1 vs 3), `spice_x_card_subcircuit_instance` (x[mid] 0.857 vs 0.75), `digital_value_has_zero_derivative` (x[k] 0.2 vs 0): **wrong numbers** | |
| rw-lower2 (`0474ded2`, in its commits up to 6424a413?) | 3 of G4 | `analysis.va`, `analysis_modes_and_severity.va`, `directives.va` (`got=                   1` vs `got=          1`: `analysis()` printed as real) | check after rw-lower2's merge |
| triage | 4 of G4 | `direction_override_redirects_a_bridge`, `discipline_and_direction_overrides`, `merged_generated_name_defparam`, `split_one_instance_per_port` (`res[a] = ±1e-19`, old 0) | possibly the versioned unit's fast body rounding (§11.9). Discriminator: rerun new with `--unknown-bound=0` (every nonzero point takes the strict body): `res` 0 -> by design, needs a tolerance ruling; still nonzero -> rw-codegen |

## 8. Departures from Zig

Zig citations are checked at `~/.cache/zig-src-d924f83bf` (`git log -1` = d924f83bf):
`src/Air.zig:1929` `mustLower`; `src/Sema.zig:2353` `failWithDivideByZero`, `:2641` `errMsg`;
`src/Zcu.zig:217` `LazySrcLoc` `src()`; `src/Zcu/PerThread.zig:4502-4560` `runCodegenInner`;
`lib/std/zig/BuiltinFn.zig:153` `list`. The stage chain this plan keeps:
Compilation (`src/next/Compilation/air_passes.zig` fills the pass inputs) -> Zcu/InternPool
(names are `InternPool.String`s) -> Sema (`Analysis.srcs`, `call_facts`, the no-fold rule) -> Air
(`Air.Float`, `Air.Setup`) -> codegen (reads the verdict only). No stage reads a sibling's
tables, and nothing copies the old `Lowered`/`Mir` shape in: no `tok` field on a Device row
(the location is Sema's side table), no callee strings (the callee is the SysFn tag).

Departures:

1. An Air pass emits diagnostics (`Air.Float` -> W0650, E06xx). Zig's Air passes
   (Liveness, Legalize) emit none; Sema does. Settled by docs/rewrite/air-passes.md;
   the inputs that make the words (names, locations) come from Compilation, as
   Zig resolves `LazySrcLoc` only at render time.
2. A constant domain violation is reported by `Air.Float`, not by Sema at fold
   (Zig: `Sema.zig:2353`), so one stage owns E0601-E0609 (T3).
3. Callee facts are a table in `Sema/` keyed by `SysFn.Tag`, not tags of Air
   (Zig gives each builtin its own Air tag); `Air.Call.callee` is already the
   SysFn integer, and Air sits below `vams`.
4. `diff-float` checks a pass's verdict against an older compiler; Zig has no
   such oracle (its passes have no predecessor), the rewrite's rule 2 asks for it.

## 9. Open questions

### Q1. Delegate W0650 **presence** from diff-comp to diff-float (J1, J2)? README says the end-to-end oracle demands every code; §11.9 made W0650's rule deliberately different, so ~140 fixtures can never byte-agree

Recommendation: Yes. diff-float certifies every disagreement (falsification or witness) and lists the uncertified as rw-zero debt; W0650 blocks both sides have stay byte-compared

Decision: Yes. diff-float certifies every disagreement (a certificate, cheaper and stronger than byte equality for a rule that differs by design); uncertified lines are named in float.xfail. W0650 blocks both sides emit stay byte-compared in diff-comp.

### Q2. J0/J3 change attribution in the lead's oracle

Recommendation: Yes: today ~90 lines blame the stage of whichever code comes first in stderr, not the stage that changed

Decision: Yes. A line must name the stage that changed or its owner fixes someone else's line. J0-J3 land first (lead), with codegen Q5 and frontend Q1, before any list moves.

### Q3. W0650's location: the access name token (old `mainTok(lhs)`) or `locate.inst(contrib)`'s point at the target's first byte

Recommendation: Access token: old parity, and the op-row case needs the operator's name (`^^^` under `idt`)

Decision: The access name token: old parity, and the op row needs the operator's name.

### Q4. W0650's help for a probe culprit: old names `proof.Options.unknown_bound`

Recommendation: Name the flag, `--unknown-bound=X`; no fixture reaches it (probes are bounded by default)

Decision: Name the flag, `--unknown-bound=X`. No fixture reaches it, so a unit test plants a probe culprit (red first).

### Q5. The witness search can miss a real overflow (sampling), leaving a sound-but-imprecise-looking line

Recommendation: Acceptable: the miss lands in `float.xfail` as debt, never as a silent pass

Decision: Accept as debt: a missed witness is a named float.xfail line, never a pass. Each one found joins the witness search's seeds (a found bug is a hole in the oracle set).

### Q6. T1 conflicts with rw-lower2's unmerged commits up to 6424a413 (contrib.zig, param.zig, Sema.zig)

Recommendation: Merge rw-lower2's commits up to 6424a413 (worktree agent-ad5e468e82bad6022) merged into refactor first; T3 can start now

Decision: Merge rw-lower2 up to 6424a413 first (lead, step 0 of research/README.md); T3 starts now.

### Q7. The `res = ±1e-19` mixed fixtures may be the fast body's rounding, a §11.9 by-design difference diff-comp would need a tolerance for

Recommendation: Run the `--unknown-bound=0` discriminator before deciding; if by design, a ruling with the f128 reference of the residual as tiebreaker

Decision: Run the `--unknown-bound=0` discriminator first. By design: a ruling with the f128 residual as tiebreak. Otherwise it is a wrong number and goes first.
