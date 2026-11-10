# Plan: Sema analog lowering (owner `rw-lower`)

Planner: plan-lower. Base: `refactor` 1a74ff4d. Starting worktree: `.claude/worktrees/agent-ad5e468e82bad6022` (rw-lower2, 7 commits up to 6424a413, merge-base 4d372899) plus uncommitted `src/Sema/bits.zig` and `tests/differential/lower/values.zig`.
This is read-only research. No builds were run: every count below comes from the lists and the source. Six slice agents read every line on both sides (slices A, B1, B2, C, D1, D2) and one read the comp-only lines (E).
Spec: docs/rewrite/lower.md, elab.md, README.md; lib/TODO.md §0–§4, §11, §12, A.3.
Old side (the oracle, read-only): `src/elab/`, `src/analog/`, `src/ir/`. New side: `src/Sema.zig`, `src/Sema/`, `src/Air/Device.zig`.
Zig mirror source: `Z/` = `~/.cache/zig-src-d924f83bf/src/` (log d924f83bf3); `S/` = `/nix/store/spqy6l91i77g18ndfbaq441khlr8zd5f-zig-0.18.0-dev.349+d924f83bf/lib/std/zig/`.
`N/` = the worktree's `src/Sema/`. `H=~/.cache/vera-heavy.sh` (= `tools/build-slot.sh`).

## 0. Bookkeeping

| list | lines | where they go |
|---|---|---|
| refactor `lower.xfail` | 643 | 197 clear when rw-lower2 lands (L0a); 446 remain and are in the worktree's list |
| worktree `lower.xfail` | 448 | the 446 above plus 2 new: `task_declaration_enabled_from_initial.va` (cleared by merging refactor 9db2b032, L0a) and `reject_simprobe_runtime_name.va` (ruling, L0c) |
| comp.xfail `rw-lower (analog lowering)` | 751 | 142 clear when rw-lower2 lands; 335 have a worktree lower.xfail fixture and map to that task (§3 column "comp"); 274 are comp-only (§2) |

The 448 lines, by kind: 316 `codes` (120 of them an E0512 refusal), 114 `tables`, 15 `contribution`, 2 Air.Verify, 1 "the old side refused".
By fault class: about 140 are **wrong numbers or rows** (held, seeds, sums, folds, rows): T2–T13. The rest are missing or extra codes.

## 1. Root-cause groups (the 448 worktree lines)

Slice tags: A (arrays), B1 (ports, aliases), B2 (bridges, access), C (params, mixed rows), D1 (control, syscalls), D2 (held, values).
"Kind" is one of: **num** (wrong number or row, no crash), **code** (missing or extra code), **ruling** (the old side is wrong), **oracle** (the harness is wrong).

| G | root cause | kind | n | examples | ruling / clause | task |
|---|---|---|---|---|---|---|
| D2-A | Writes made through calls are missing from the held walk: sys-call destinations, user `output`/`inout` actuals, random seeds. `N/held.zig:228` `Walk.read` never defines a destination; `writtenFrom` (:394) has no seeds; `eventWrites` (:426) sees only `.store` | num | 28 | ch09 fgets.va, sscanf_conversion_rules.va, timer_body_effect_controls.va | §9.5.4.2 (a failed scan leaves the destination), §5.10 | T2 |
| D2-B | §9.13 seed state: no write-back to an integer seed, and no hidden `$rng.N.seed`/`.ready` | num | 7 | arandom_negative_seed.va, revert_ops.va | §9.13.1, §9.13.2 | T3 |
| D2-C | A held array is one row with a count on the new side and one row per element on the old | oracle | 3 | timer_body_array_controls.va | new is right (one `Device.Held` row) | L0c |
| D2-D + C-M1/M3/M7 | No A2D hold: an analog variable a digital process reads is not held. `discrete.mark` reads only top-level items; switch terminals are not digital-owned | num | 8 | continuous_variable_read_from_digital.va | §7.3.6.4, §8.5.3.5 | T4 |
| D2-E | No `$assigned.<x>` assignment counter | num | 4 | same_value_analog_assignment_fires.va | §7.3.6.1 | T5 |
| D2-F | Old holds digital-owned variables as A2D: it drops child tasks (`Flatten.zig:243`) and does not know the `$q_*` outputs | ruling | 3 | driver_state_histogram.va | §7.2.2; IEEE 1364 §17.6 | L0c |
| D2-G | Old holds `fold[nslot-1]` because it does not fold a localparam subscript | ruling | 1 | compact_modeling_macro_implies_its_extensions.va | §3.4.5 | L0c |
| D2-H | §5.6.1.3: a contribution does not discard the opposite quantity on the same branch | num | 3 | value_retention.va (the clause's example gives 7, new gives 8) | §5.6.1.3 | T6 |
| D2-I | An inserted connect module is lowered after its parent instead of before it, so sums differ in the last ulp | num | 10 | split_one_instance_per_port.va | none (order is fixed for determinism) | T7 |
| D2-L | `$error` in `analog initial` does not stop the run (no synthetic `$fatal`) | num | 1 | error_in_analog_initial_stops_after_initialization.va | §9.7.x | T7 |
| D2-J + C-P9 | A hierarchical system parameter that reads the card folds to `.undef`, so `mfactor` becomes 1. Also missing E0912 on double scaling | num | 3 | geometry_parameter_sweep.va, mfactor_double_scaling_rejected.va | §6.3.6 Table 9-29, §9.18 | T8 |
| D2-K + D1-B | A string function's return value and outputs start at integer 0 (`N/func.zig:168 zeroOf`), which fails Air.Verify | num | 3 | function_string_output_starts_empty.va | §4.7.1, §4.7.2.3 | T9 |
| C-I1/I2/I3/I5, D1-F/G, C-P6, D2-M | Constant evaluator gaps: unsigned compare, 64-bit literal ≥ 2^63, element wrap, reductions, `>>>`, wide literal, `$clog2`, out-of-module reads in a paramset | num+code | 19 | dependent_control_shift_mixed.va, clog2_unsigned_width.va, paramset_oomr_nonlocal_parameter_rejected.va (E0907) | §4.2.9, §4.2.1.1, §9.x `$clog2`, §6.4.1 | T10 |
| C-I6 + C-C8b | `$rtoi`/`$itor` do not fold (`N/eval.zig:325 sysCall`), giving a spurious E0357 on an attribute value | code | 2 | **verilog/pli/analog_attributes.va**, conversion_constant_expressions.va | §4.2.1.1, §2.9 | **T1 (unblocks VPI)** |
| C-I4, C-I7 | Old keeps 1e300 in an integer row, and old does not hold a ranged specparam to its range | ruling | 2 | integer_conversion_saturates.va, specparam_range_and_select.va | §4.2.1.1; IEEE 1364 §4.10.3 | L0c |
| D1-H + C-M5 | No §7.3.2 four-state planes (`__xz` rows, case equality over x/z) | num | 11 | xz_case_statement_compared.va | §7.3.2 | T11a |
| D1-X + C-M4 | No explicit D2A event sites (`__d2a{k}`, `__1b`) | num | 11 | explicit_d2a_per_delta_cycle.va | §7.3.4, §8.5.3.6 | T11b |
| D1-L/M/N/O/Z14 | Short circuits and constant conditions: an analog operator inside `&&`/`||`, a static `&&` treated as run-time, a constant condition not folded, an operator in `repeat`, a skipped operand's codes | num+code | 12 | idtmod.va, cross_under_genvar_condition.va, rng_skipped_seed_rejected.va | §4.2.x, §5.9 | T12 |
| C-P1/P2/P3/P5/P7/P8/P10, C-M6 | Paramset chains and hierarchy parameter rows: links past the first, system aliasparams below the root, tie-break, a defparam'd root parameter made local, `$mfactor` alias row order, E0926/E0237/E0314 | num+code | 19 | rc_h01_paramset_chain_far_link_parameter.va, paramset_defparam_direct_rejected.va | §6.4.1, §6.3 | T13 |
| C-P4 | Old flattens both arms of an if-generate | ruling | 5 | generate_if_instantiates_one_arm.va | §6.6.2; IEEE 1364 §12.4.3 (elab.rulings already has `drops`) | L0c |
| C-C2..C7, C-C8a, D1-E, B1-G5 | Parameter and name codes: E0314 (unbound, function non-local, genvar), E0312, E0362, E0363, E0822, statement attributes never judged, block/generate localparams, E0331/E0303 aliasparam | code | 19 | forward_parameter_reference.va, reject_limit_vera_seed_attr_not_constant.va | §3.4, §4.7.1, §6.6.1, §2.9 | T14 |
| C-C1 + B2-C8 | Module-level generate schemes are never judged (E0417–E0420, E0428, E0486), and there is no generate-scope name (E0998) | code | 13 | generate_nonterminating_rejected.va | §6.6.1; IEEE 1364 §12.4.1 | T15 |
| A-G1 | `control.operands` (`N/control.zig:91-110`) skips `Inst.Refs` payloads (concat, pattern) | code | 6 | (A slice) | §4.2.12 | T16 |
| A-G2/G3/G5/G9/G10/G10b/G11 | Whole-array assignment, pattern initialisers, slices, a pattern in a scalar position, concat forms, a replication target, part-select of a parameter array | code | 20 | (A slice) | §3.2.2, §3.4.4, A.8.2 | T17 |
| A-G4 | Array formals of analog functions | code | 12 | (A slice) | §4.7.2.3, §4.7.2.4 | T18 |
| A-G6/G7/G8/G14/G15 | Array declaration and subscript codes, the cell cap, more than 8 subscripts, `$limit` slot codes | code | 9 | (A slice) | §3.2.2 | T19 |
| A-G12/G13, D1-Z15, C-C9 | Reg bit/part-select reads, analog assignment to a reg (E0316, check before the RHS lowers), a wide-reg read (E0222) | code | 12 | wide_reg_held_across_evaluations.va | §7.3.1; VD-116 (revised 2026-10-27) | T20 |
| B1-G1/G2, B2-C5/C6/C7 | Vector child port binding (positional per bit), E0350, concatenated or null header ports, the `#k` spelling suffix | code+num | 22 | (B1 slice) | IEEE 1364 §12.3.9.2 | T21 |
| B1-G3a/G3b, B2-D8 | Branch arrays and vector branches, E0372 | code | 7 | (B1/B2 slices) | §5.4.1 | T22 |
| B1-G4, B2-D1..D7/D9 | Access-function codes: terminal E0351/E0352, generic potential/flow, E0501, access in a digital process, natureless/discrete exemption, E0365/E0366/E0344 | code | 29 | (B2 slice) | §5.4, §5.4.2, §3.6.2 | T23a |
| B2-B1..B5 | Instance-port access `I(<u.p>)`: port ammeter, instanceFlow, shared inst.branch, E0439, E0477 | code+num | 12 | primitive_segment_discipline.va | §5.4.3 | T23b |
| B1-G6/G6b, A-G16 | §9.20 `$analog_node_alias`/`$analog_port_alias` (also chosen by a parameter) | code+num | 20 | (B1 slice) | §9.20 | T24 |
| B1-G7/G8, B2-C4 | Discrete/wreal ports (`.io`), a variable output port as a slot, a child port on a parent variable or discrete | code+num | 20 | (B1 slice) | §7.2, §6.5 | T25 |
| B2-A1..A5 | Primitive terminal bridges, implicit parent net row order, E0960, E0483, `$clog2` initial | num+code | 22 | (B2 slice) | §8.4, §8.5 | T26a |
| B2-C3/C9/C10/C13 | Out-of-context declarations, implicit nets in hierarchy/nature attributes, E0924, E0367 nettype none | code | 12 | (B2 slice) | §3.6.3, §10.2 | T26b |
| B2-C1/C2/C11/C12 | Hierarchical variable E0901, a block-local parameter hierarchy name, an escaped name holding `.`, `\bus[0]` | code | 4 | (B2 slice) | §3.7.1, §6.7 | T27 |
| D1-A/C/I/J/K/P/W/Y | Control and event codes: E0403/E0404, E0241 left spine, E0701, E0702, E0705/E0513, arity order E0505 before E0506, timer E0528, E0574 | code | 19 | jump_statements.va | §5.9, §5.10, §4.5 | T28 |
| D1-D1/D2/Q/R/S1/S2/Z1–Z5/Z7/Z9–Z13/Z16/Z17 | Syscall and analog-operator codes: E0808, E1014, null-zeros, E0572, reactive flow read, factor over a `ddt` sum, E0322/E0319/E0330, hierarchical function call, bus port element, E0424, E0810, E0807, E0824, E0888, E0889, E0537, E0518 | code | 23 | fopen_type_not_in_table_9_24_rejected.va | §4.5, §9.x | T29 |
| D1-T/U/V | Statement attributes lost on `<+`, `vera_interp`, `vera_scratch` on a genvar: AstGen drops them | code | 6 | reject_vera_nodiff_contribution.va | §2.9 | T30 (after TV2) |
| D1-Z6 | `$simprobe` with a run-time name: old accepts it | ruling | 1 | reject_simprobe_runtime_name.va | §9.x simprobe (fixture `//! reject-only E0823`) | L0c |
| C-M2 | A task body's writes are digital-owned | merge | 1 | task_declaration_enabled_from_initial.va | – | L0a |
| unclear | B2-U1 connect_insertion_upper_from_ooc_below, B2-U2 constant_expression_reads_a_probe, D1-Z8 kernel_control_in_digital_context_rejected, D2-N unnamed_generate_block_external_names (one `$strobe` row short) | ? | 4 | – | – | U |

Sum: 448. Every fixture-to-task mapping is in `scratchpad/task_of.json` (generated by `scratchpad/map2.py`).

## 2. The 274 comp-only lines (report E)

| group | n | owner | fix / route | task |
|---|---|---|---|---|
| A1–A10: arity wording (`N/syscall.zig:270`), unknown function E0512, E0407, E0409, E0315, E0321, E0327, E0361 parameter name not flattened (`N/param.zig:369-399` uses `prefix`), E0373 | 38 | rw-lower | message text | T31a |
| A11–A26: E0901/E0910 hierarchy texts, E0516, E0517, E0816 (`dist.zig`), E0815/E0813 (`table.zig`), E0130 with its width (`expr.zig:201`), discrete_check texts (E0430/E0431/E0432/E0436/E0484/E0482). A22–A24 need a secondary span (§6 Q3) | 40 | rw-lower | message text | T31b |
| B1–B7: argument parts (`locate.zig:52`, `locate.zig:71 instToken` returns null for literals), event-control site (`control.zig:368/369/421/438`), declaration parts, indirect, hierarchy base, continuous-assign lhs, caret | 69 | rw-lower | `Zcu.Part.arg: u32` | T32 |
| C-G2/G3/G4: per-node abstol, nodeset, desc/units | 10 | rw-lower + rw-codegen | `Air.Device` node schema | T33 |
| C-G1: dependent default with control flow (`derive.zig:46-53` + codegen `genDerive`) | 7 | rw-lower + rw-codegen | – | T34 |
| C-G11 `%d` width of a digital-owned value (`format.zig:228 declSize`, 9); G12 noise table E0519 (3); G13 E0237 in a paramset (1); G17 drive strength (`discrete.zig:160`, 1); D3 E0337 note (`contrib.zig:600`, 3); D4 E0216 sized concat (`bits.checkSized`, 1); D5 E0247 location (1) | 19 | rw-lower | – | T35 |
| C-G5/G6/G7/G8/G9/G15/G16: flow-only signal flow, `$finish` text, the INFO t=0 prefix, discontinuity/limit verdict, `%h` padding | 23 | **rw-codegen** | retag (lead) | – |
| C-G10: `abs(0)` gives -0 (`lib/kernels/fold.zig:362`) | 2 | **kernels** | retag (lead) | – |
| C-G14: E1100 | 1 | **rw-dlower** | retag (lead) | – |
| D1: W0252 for gate/UDP statements. 15 of the 26 stop at a parse error (`Parse/prim.zig:120`, `Parse/udp.zig:97` must fill `Ast.gate_notices`, emitted at `errors.zig:43`) | 26 | **rw-comp** (frontend) | retag (lead) | – |
| D2: W0252 in a `.v` run (the `walk.zig` `!s.config.ieee1364` guard, in plan-dlower's worktree as its G1) | 1 | **rw-dlower** | retag (lead) | – |
| C-G18: SPICE subckt hierarchy probe (2); C-G19: exit 0→1 on 12 ch04 relational fixtures | 14 | unclear | one `vera-next --run greater_than.va` | U |
| S1–S6: stale, cleared by worktree commits | 24 | – | – | L0a |

Sum: 274. Of these, 183 are rw-lower work, 53 should be retagged, 14 are unclear and 24 are stale.

## 3. Tasks

Wrong numbers come first. Each task is sized for one Sonnet agent working a few hours.
"lower" is the number of worktree lower.xfail lines the task clears. "comp" is the number of comp.xfail lines expected to clear (report them; do not edit comp.xfail).

### Phase 0 (serial head)

| T | what | files | Zig mirror | lower | comp | dep |
|---|---|---|---|---|---|---|
| L0a | Land rw-lower2. Commit the uncommitted `bits.width` (§4.2.13 sized concat width) and `values.compareWidths` (a new oracle: `$display$width` operand widths). Merge refactor (9db2b032 clears C-M2). PR into refactor. Any line the new width oracle opens gets a named reason in lower.xfail | `src/Sema/bits.zig`, `tests/differential/lower/values.zig` | – | 197 on refactor's list + 1 | 142 + 24 stale | – |
| L0b | Pure file splits, no behaviour change (§4) | see §4 | Z/Sema.zig layout | 0 | 0 | L0a |
| L0c | Oracle work. Read `lower.rulings` through `settle.Rulings`, as `tests/differential/astgen.zig:83` does. Read `elab.rulings` `drops` and filter the dropped `param` rows (C-P4). Collapse old per-element held rows `x[i][j]` to `x` (D2-C). Add 7 ruling lines: C-I4, C-I7, D1-Z6, D2-F ×3, D2-G. | `tests/differential/lower.zig`, `lower/tables.zig:59`, new `tests/differential/lower.rulings` | – | 15 | 0 | L0a (parallel with L0b) |
| T1 | **Unblocks VPI.** Fold `$rtoi` (truncate; null outside [-2^31, 2^31-1] or for NaN) and `$itor` in `eval.zig:325 sysCall`, before the math lookup. Exactly one argument; a string gives null. Clears the spurious E0357 on `verilog/pli/analog_attributes.va`. After the fix that fixture reaches the table and value checks; check its next difference with `-Dlower-dump=analog_attributes` | `N/eval.zig` | Z/Sema.zig:21221 `zirIntFromFloat`, :21401 `zirFloatFromInt` (comptime fold), :2257 `resolveConstValue` | 2 | 0 | L0a (parallel with L0b: L0b leaves eval.zig alone) |
| TV1 | `lib/std/vams/SysFn.zig` facts. `Info.writes: Writes`, where `Writes = packed struct(u8) { first: u7 = none, rest: bool = false }` (`$fgets`/`$swrite`/`$sformat` {0}; `$sscanf`/`$fscanf` {2..}; `$ferror` {1..}; `$value$plusargs` {1}; `$random`/`$arandom`/`$dist_*`/`$rdist_*` {0}). `Info.fd: bool` (D1-Z12). `reserved` (D1-D2). **Coordinate with frontend T6**: same package, different file | `lib/std/vams/SysFn.zig` | S/BuiltinFn.zig:144-151 (per-builtin facts in one comptime table) | 0 | 0 | – |

### Phase 1: wrong numbers (lanes run in parallel)

| T | what | files | Zig mirror | lower | comp | dep |
|---|---|---|---|---|---|---|
| T2 | D2-A held writes. `Walk.pending: ArrayList(Inst.Ref)`. At `.call_sys`: read every argument, then queue `SysFn.info(tag).writes` destinations. At a user `.call`: `output` reads only its subscripts and queues the actual; `inout` reads and queues. `flush` runs after each statement's reads (store, contrib, condbr/case, loop, repeat, event_wait, call statement). `eventWrites` marks `callWrites` targets. Delete `writtenFrom`, since `SysFn.Info.writes` replaces it. Move `discrete_check.zig:251 function` to `func.zig` as pub | `N/held.zig`, new `N/held_writes.zig`, `N/func.zig`, `N/discrete_check.zig`, new `N/held_test.zig` | Z/Air/Liveness.zig (see §5 D2) | 28 | 0 | TV1, L0b |
| T3 | D2-B seeds. When the seed is an integer variable, write back `rng_next(...)` via `control.assignTo`. A constant or parameter seed gets hidden `$rng.N.seed` and `$rng.N.ready` held integers. An omitted seed appends `1 + 7919·ordinal` to `Device.rng_auto_seeds`. The intrinsics' form is §6 Q2. **Needs rw-codegen** for the `_next` kernel map | `N/dist.zig`, `N/Sema.zig` (`rng_sites`, `rng_ordinal`), `src/Air/Device.zig` | none (§5 D5) | 7 | 0 | T2 |
| T4 | D2-D + C-M1/M3/M7 A2D. Add `Why.a2d` and `a2dReads` = names the digital processes read, minus digital writes (`discrete.writes` over initial/always/task bodies, `callWrites`, the IEEE 1364 §17.6 `$q_*` outputs). `discrete.mark` goes through `eachItem` (M1). Switch terminals are digital-owned (M3). `isMixed` and `digital/domain.zig:322 reads` become pub | `N/held_writes.zig`, `N/discrete.zig`, `N/digital/domain.zig` | none (VAMS §7.2.2 domains) | 8 | 2 | T2 |
| T5 | D2-E `$assigned.<x>`. In `variable.declare`: an `.event`-held variable in `a2dReads` gets a counter slot and a held row. In `control.assignTo`: `c = c + 1` after the assign. `Sema.assign_counts: AutoHashMapUnmanaged(Air.Inst.Index, Air.Inst.Index)` | `N/variable.zig`, `N/control.zig` (assignTo only), `N/Sema.zig` | Z/Sema.zig:29959 `storePtr` (one store site) | 4 | 3 | T4; control.zig after T16 |
| T6 | D2-H §5.6.1.3 discard. `discardOpposite(s, b, t)` runs after `rowOf`. If the opposite-access row of the same branch is this instance's, zero its resist, react, wrote and charge sites | `N/contrib.zig` | Z/Sema.zig:4924 `zirStoreNode` (store to the target before adding) | 3 | 0 | L0b |
| T7 | D2-I lowering order + D2-L `$error`. In `decl.zig:124-127`, lower each unit's placed children in source order, then its inserted connect instances in insertion order (`instances.src == .none`, grouped by parent), then the unit; the top goes last. Add an `init_error` slot (sentinel handle, not an optional) and after the analog initial blocks a guarded `$fatal` plus a display row | `N/decl.zig`, `N/syscall.zig` (task: set flag) | Z/Zcu/PerThread.zig analysis queue (one fixed order); §5 D6 | 11 | 0 | L0b |
| T8 | D2-J + C-P9. A per-instance hierarchical parameter value that reads the card: add an existence table `Zcu.hier_srcs: ArrayList(HierSrc{ instance: Instance.Index u32, kind: SystemParam u8, value: Inst.Ref u32 })` (12 B, asserted), not a column on every instance. `mfactorOf` becomes `mfactorRef(...) Air.Inst.Ref`, composed parent ∘ own with the Table 9-29 operator. `hierRead` uses the same ref. E0912 `doubleScaling` | new `N/mfactor.zig` (from L0b), `N/syscall.zig` (hierRead), `src/Zcu.zig`, `N/walk.zig:209` (one site) | Z/Sema.zig:2257 (not comptime-known → a run-time instruction) | 3 | 1 | L0b; Zcu.zig before T13 |
| T9 | D2-K + D1-B. `zeroOf(s, ty)`: `.string` → the interned `""`. Same fix at `variable.zig:76` | `N/func.zig`, `N/variable.zig` | Z/Sema.zig:18080 `zirRetImplicit` (typed zero) | 3 | 1 | T2 (func.zig), T5 (variable.zig) |
| T10 | Constant evaluator. I1: `sign.compareConsts`/`signed` with one mask-and-flip `plan`, used at `eval.zig:290`. I2: `size == 64` reads the bit pattern (`eval.zig:460`). I3/I4: `eval.toInteger(c) ?i64` (wrap exact, saturate reals, null for NaN/inf) at `eval.zig:354`, `param.zig:332`. I5: reductions and `ashr`. D1-F: wide literal (`eval.zig:284`). D1-G: `$clog2` fold + Air lowering. C-P6/D2-M: `Env.oomrs`; a non-local is E0907. Move sysCall folds to `N/eval_fn.zig` (precedent: `eval_1364_fn.zig`) | `N/eval.zig`, new `N/eval_fn.zig`, `N/sign.zig`, `N/param.zig` (:332 only), `N/paramset.zig` (oomr), new `N/param_test.zig` | Z/Sema/arith.zig (comptime arithmetic), Z/Sema.zig:15722 `analyzeCmp` | 19 | 12 | T1 |
| T11a | D1-H + C-M5 four-state planes. `Unit.xz` (`<name>__xz` rows), case equality, `case`/`casex`/`casez` over x/z | new `N/case_eq.zig`, `N/case.zig`, `N/expr.zig:328`, `N/discrete.zig`, `N/Sema.zig` (Unit) | none (§5 D7) | 11 | 11 | T4 (discrete.zig) |
| T11b | D1-X + C-M4 explicit D2A sites `__d2a{k}`, `__1b`. The site loop runs after `decl.zig:112`, before the `$mfactor` alias (T13 M6) | `N/control.zig` (eventExpr), `N/discrete.zig`, `N/decl.zig`, `N/Sema.zig` (Unit) | Z/Sema.zig:10057 `zirSwitchBlock` style capture of a run-time event (no closer mirror) | 11 | 11 | T11a, T7 (decl.zig) |
| T12 | Short circuit and constant conditions. `&&`/`||` lower as block + cond_br. A comptime-known lhs analyses one arm only (D1-N, Z14); an analog operator inside an operand still lowers (D1-M, old evaluates both, §4.5 analog operators run every iteration). A constant `if` condition analyses one arm (D1-L). An operator in `repeat` (D1-O) | `N/expr.zig` (&&/||), `N/condbr.zig` (from L0b) | Z/Sema.zig:17465 `zirBoolBr`; :17731 `zirCondbr` (comptime-known condition → one body) | 12 | 12 | L0b |
| T13 | Paramset rows (C-P1/P2/P3/P5/P7/P8/P10, M6). `Zcu.PsLevel{ paramset, params, hier }` (36 B asserted) in a `MultiArrayList`; `Instance.levels: Vir.List(PsLevel)`. `Zcu.ps_defparams` (12 B) → E0926. System alias rows below the root. Tie-break: only non-`.none` values, aliases, defparams. `derive.zig:56` keeps E0314. Move E0237 to `.elab` in stages.zig. spice_paramset_shadow's next difference (old 2e0, new 6e0) gets a ruling (§6.4.1) | `src/Zcu.zig`, `N/paramset.zig`, `N/param.zig`, `N/param_paramset.zig`, `N/defparam.zig`, `N/decl.zig`, `N/walk.zig` (one line), `N/derive.zig`, `tests/differential/stages.zig`, `lower.rulings` (1 line) | Z/InternPool.zig:1964 `Key` (a table row per instantiation); Z/Sema.zig:6605 `analyzeCall` (generic instantiation per argument set) | 19 | 10 | T8 (Zcu.zig), T10 (paramset.zig), T7/T11b (decl.zig) |

### Phase 2: codes (after phase 0; lanes in §3.4)

| T | what | files | Zig mirror | lower | comp | dep |
|---|---|---|---|---|---|---|
| T14 | Parameter and name codes (C-C2..C7, C8a, D1-E, B1-G5). `param_check.unboundRead` E0314; E0312 at the assign; E0314 for a function reading a non-local or a genvar (`func.declaredIn`); E0362 via `checkRedeclared`; `checkOverrides` E0363; `paramGivenArg` E0822; `attr.judgeAll` for statement attributes; block/generate localparam bindings; aliasparam `checkAlias` E0331/E0303 | new `N/param_check.zig`, `N/param.zig`, `N/expr.zig` (declRef), `N/control.zig` (assign, block), `N/syscall.zig`, `N/attr.zig`, `N/variable.zig`, `N/func.zig` | Z/Sema.zig:5999 `lookupInNamespace`, :5944 `zirDeclRef` (a name not visible here is an error at the reference) | 19 | 19 | T13 (param.zig), T12 (expr.zig) |
| T15 | Generate schemes (C-C1) + scopes (B2-C8). Move the gen_for arm to `genfor.generate(..., report: Report, ...)`, where `Report = enum { report, silent }`. Only the lowering pass passes `.report` (not the `@hasDecl` flag slice C proposed). Raise E0419, E0486, E0417, E0420 (seen-value set) and E0418 in that order; E0428 for if/case. `Block.scope` for E0998 | `N/genfor.zig`, `N/decl.zig` (eachItem), `N/Sema.zig` (Block.scope) | Z/Sema.zig:5163 `zirLoop` / inline-loop unrolling in `analyzeBodyInner`; :5028 `zirCompileError` | 13 | 13 | T13 (decl.zig) |
| T16 | A-G1. In `control.operands`, `Vir.List(Inst.Ref)` payloads yield each element (`N/control.zig:96`). Affects `discrete.analogReads` and `constant` too | `N/control.zig` | Z/Air/Liveness.zig operand iteration (every operand of an aggregate) | 6 | 6 | L0b |
| T17 | Aggregates (A-G2/G3/G5/G9/G10/G10b/G11). New `slice.zig` (`ArrayRef`, `readCells`, `writeCells`, `assign`) and `pattern.zig` (`flatten`, `elems`, `check`: E0894, E0223, E1016). `expr.bindValue .array` → E0314. A pattern in a scalar position → E0509. Concat forms E0327; replication target E0317; `vectorArg` part-select | new `N/slice.zig`, new `N/pattern.zig`, `N/expr.zig`, `N/string.zig:94`, `N/param.zig:296`, `N/eval.zig:120`, `N/op.zig:239` | Z/Sema.zig:19294 `zirArrayInit`, :4404 `validateArrayInitTy`, :31482 `analyzeSlice`, :13491 `zirArrayCat` | 20 | 20 | T16, T10 (eval.zig), T14 (expr.zig) |
| T18 | A-G4 array formals (`func.zig:51-66`, `arrayActual`), E0511 | `N/func.zig` | Z/Sema.zig:6605 `analyzeCall` (argument coercion to the param type) | 12 | 10 | T17, T9 |
| T19 | A-G6/G7/G8/G14/G15 codes. `decl.zig:241` E0352→E0308; `array.zig:64/69/75/85` →E0309/E0309/E0356/E0310; more than 8 subscripts; `writtenArgs` E0894; `kernel.limitUser` E0814. The cell cap is §6 Q8 | `N/array.zig`, `N/decl.zig`, `N/kernel.zig` | Z/Sema.zig:9743 `zirElemPtr`, :27472 `elemVal` | 9 | 9 | T15 (decl.zig) |
| T20 | Reg reads and writes (A-G12/G13, D1-Z15, C-C9). New `regsel.zig` `read` (E0329/E0310/E0222, `name__w{k}` word rows via `Unit.words`). E0316 for an analog assignment to any reg, checked **before** the RHS lowers (VD-116 revised). Move E0222 to `.sema` | new `N/regsel.zig`, `N/control.zig` (assignTo), `N/expr.zig` (declRef), `N/format.zig:264` (pub `rangeWidth`), `tests/differential/stages.zig` | Z/Sema.zig:29959 `storePtr` (the type check precedes the operand); :27472 `elemVal` | 12 | 10 | T17, T5 |
| T21 | Vector child ports (B1-G1/G2, B2-C5/C6/C7). `portbind.bindChildren` / `bindChild` / `connNodes` / `memberNodes`: IEEE 1364 §12.3.9.2 positional bit mapping; delete `net.bindChildPorts`. `net.indexedRange` / `partOf`; E0350; concatenated and null header ports (`net.zig:43-49`); `#k` suffix via `appendNode` + `Sema.spellings` | `N/portbind.zig` (from L0b), `N/net.zig` | Z/Sema.zig:6605 `analyzeCall` + Z/Zcu.zig:2689 `call_arg` (an instance is a call; a port is an argument) | 22 | 19 | L0b |
| T22 | Branches (B1-G3a/G3b, B2-D8). `branch.declare` / `Term` / `terminal`; `Bind.branches{ first, msb, lsb }`; E0372 | `N/branch.zig` (from L0b), `N/Sema.zig` (Bind) | Z/Sema.zig:5964 `zirDeclVal` | 7 | 7 | L0b |
| T23a | Access codes (B1-G4, B2-D1..D7, D9). Terminal E0351/E0352 (`portOf .elem`); generic potential/flow; E0501 for a non-access call; access terminal not a digital read; child-local discipline; delete the natureless exemption at `contrib.zig:604`; `I(<p>)` discipline; access in a digital process; `net_check` E0365/E0366/E0344 | `N/access.zig` (from L0b), `N/net_check.zig`, `N/contrib.zig` (:604) | Z/Sema.zig:26280 `fieldVal`, :26982 `namespaceLookup` | 29 | 25 | T22, T6 (contrib.zig) |
| T23b | Instance-port access (B2-B1..B5). Port ammeter (the stale E0997 headers: §6 Q7); `instanceFlow`; shared inst.branch (`share.zig`); E0439; `source_check` E0477 | `N/access.zig`, new `N/share.zig`, `N/source_check.zig` | Z/Sema.zig:26280 `fieldVal` | 12 | 12 | T23a |
| T24 | §9.20 aliases (B1-G6/G6b, A-G16). `alias.lower` / `resolve`; `Unit.alias_home`; dispatch at `syscall.zig:89`; a parameter-chosen alias records `Block.alias_conds`; move the portFlow guard | new `N/alias.zig`, `N/syscall.zig`, `N/Sema.zig` (Unit, Block) | Z/Sema.zig:5999 `lookupInNamespace` (an alias resolves to its target decl) | 20 | 20 | T21, T29 (syscall.zig) |
| T25 | Discrete ports (B1-G7/G8, B2-C4). `.io` and `propagate` in discrete.zig; `variable.declareSlot` for a variable output port; a child port on a parent variable or discrete | `N/discrete.zig`, `N/variable.zig`, `N/portbind.zig` | Z/Sema.zig:27996 `coerce` (port type at the boundary) | 20 | 16 | T21, T11b (discrete.zig), T9 (variable.zig) |
| T26a | Bridges (B2-A1..A5). `primitiveBridge`; implicit parent net rows in preorder (`Sema.pending`, `implicitNets`); E0960, E0483 (`connect.zig gateTerminals`); `$clog2` in `initial` stays plain (`discrete.zig:199`) | `N/portbind.zig`, `N/connect.zig`, `N/Sema.zig`, `N/discrete.zig` | Z/Zcu/PerThread.zig work queue (pending rows in one fixed order) | 22 | 20 | T25 |
| T26b | Out-of-context declarations and implicit nets (B2-C3/C9/C10/C13): `Vir Inst.Net.flags.out_of_context`, implicit nets in hierarchy and nature attributes, E0924, E0367 | `N/net.zig`, `N/portbind.zig`, `N/net_check.zig` | Z/Sema.zig:5999 | 12 | 11 | **TV2**, T26a |
| T27 | Names (B2-C1/C2/C11/C12): E0901 for a hierarchical variable; a block-local parameter's hierarchy name; an escaped name holding `.`, interned whole; `\bus[0]` | `N/hier.zig`, `N/resolve.zig` | Z/InternPool.zig:11406 `getOrPutString` (a name is interned verbatim) | 4 | 4 | **TV2** |
| T28 | Control and event codes (D1-A/C/I/J/K/P/W/Y): E0403/E0404, E0241 iterative left spine, E0701, E0702, E0705/E0513, E0505 before E0506, timer E0528 (`timer.zig`), E0574 | `N/control.zig`, `N/condbr.zig`, new `N/timer.zig`, `N/syscall.zig` | Z/Sema.zig:5774 `zirBreak`, :18128 `zirRetNode`, :5028 | 19 | 19 | T12, T20 (control.zig) |
| T29 | Syscall and analog-operator codes (§1 row). New `fileio.zig` (`SysFn.Info.fd`, E0888/E0889); `finite.zig` + load_consts E0424; reactive flow read; factor over a `ddt` sum; E1014 via `SysFn.reserved` | `N/syscall.zig`, new `N/fileio.zig`, new `N/finite.zig`, `N/op.zig`, `N/reactive.zig`, `N/string.zig`, `N/table.zig`, `N/func.zig` (callee unit) | Z/Sema.zig:23941 `zirBuiltinCall` (arity and argument checks per builtin) | 23 | 23 | TV1, T28 (syscall.zig) |
| T30 | Attributes AstGen drops (D1-T/U/V): `leftmost` `.call` (`AstGen stmt.zig:139`), `Vir.call_attrs`, `Vir.Inst.Name.attrs`; then E0524, E0535, the `<+` statement attributes | `N/contrib.zig`, `N/attr.zig`, `N/variable.zig` | S/Zir.zig:53 `ExtraIndex` (attributes carried on the instruction) | 6 | 6 | **TV2**, T14 |
| TV2 | Vir/AstGen additions for T26b, T27, T30: `Inst.Net.flags.out_of_context` (`AstGen/decl.zig:437`); escaped `.` interned whole (`AstGen.zig:286`); `leftmost` `.call` (`AstGen/stmt.zig:139`); `Vir.call_attrs`; `Inst.Name.attrs`. **Coordinate with frontend T6**, which edits the same `Vir/Inst.zig` and `AstGen/stmt.zig`: land after T6, or in one PR with it | `lib/std/vams/Vir/Inst.zig`, `lib/std/vams/Vir.zig`, `lib/std/vams/AstGen/{decl,stmt}.zig`, `lib/std/vams/AstGen.zig`, AstGen tests | S/Zir.zig:161 `Inst` | 0 | 0 | frontend T6 |

### Phase 3: comp-only (report E)

| T | what | files | Zig mirror | comp | dep |
|---|---|---|---|---|---|
| T31a | Message texts A1–A10 | `N/syscall.zig`, `N/param.zig`, `N/expr.zig`, … | Z/Sema.zig:2641 `errMsg` | 38 | T29, T14 |
| T31b | Message texts A11–A26. The secondary span is a note with its own source location (§6 Q3) | `N/hier.zig`, `N/dist.zig`, `N/table.zig`, `N/discrete_check.zig`, `src/next/Compilation/errors.zig:61-77` | Z/Sema.zig:2614 `errNote`; Z/Zcu.zig:1262 `ErrorMsg.notes` | 40 | T27 |
| T32 | Locations: `Zcu.Part.arg: u32` (`src/Zcu.zig:285`) resolved in `locate.part` (`locate.zig:52`); `instToken` for literals (:71); event-control site; declaration parts; caret. **Frontend T1/T7 also edit `locate.zig` and `Zcu.zig`**: land after them | `src/Zcu.zig`, `N/locate.zig`, `N/control.zig` (sites) | Z/Zcu.zig:2689 `LazySrcLoc.Offset.call_arg`, resolution :1678 | 69 | frontend T1, T7; T28 |
| T33 | `Air.Device` node schema: abstol stays hot in `Node`; desc/units go in a cold `node_meta` table; nodeset is an existence table `nodesets{ node u32, value f64 }`. **Needs rw-codegen** | `src/Air/Device.zig`, `N/net.zig`, `N/nature.zig` | Z/InternPool.zig:1964 (one row per item, extras out of line) | 10 | T26b |
| T34 | Dependent default with control flow (`derive.zig:46-53`). **Needs rw-codegen** `genDerive` | `N/derive.zig` | Z/Sema.zig:2257 | 7 | T13 |
| T35 | Assorted: C-G11 (`format.zig:228`), G12 (`table.zig`), G13, G17 (`discrete.zig:160`), D3 (`contrib.zig:600` note), D4 (`bits.checkSized`), D5 (`Zcu.Part.scaled`) | as listed | Z/Sema.zig:2614 | 19 | T32 |
| U | Unclear. Spend one heavy slot: `$H <wt> diff-lower -Dlower-dump='connect_insertion_upper_from_ooc_below\|constant_expression_reads_a_probe\|kernel_control_in_digital_context\|unnamed_generate_block_external_names'` and `vera-next --run greater_than.va`; then route each line | – | – | lower 4, comp 3 + 14 | L0a |

Totals: lower 448 = L0a 1 + L0c 15 + phase 1 (T1–T13) 141 + phase 2 (T14–T30) 287 + U 4. comp: 335 via lower tasks; of the 274 comp-only, 183 via T31–T35, 24 stale (L0a), 53 retagged, 14 for U. Task count: 45 (L0a–c, T1, TV1, TV2, T2–T35 with a/b, U).

### 3.4 Lanes and file order (tasks sharing a file serialize; the order is the dependency column)

| lane | tasks, in order |
|---|---|
| head | L0a → L0b ∥ L0c ∥ T1 ∥ TV1 |
| held | T2 → T4 → T5 → T3 → T9 |
| contrib | T6 → T8 → T22 → T23a → T23b |
| eval/param | T10 → T13 → T14 → T15 → T19 |
| control | T16 → T12 → T11a → T11b → T17 → T18 → T20 → T28 → T29 → T24 |
| ports | T21 → T25 → T26a → (TV2) → T26b → T27 → T30 |
| decl.zig order | T7 → T11b → T13 → T15 → T19 |
| comp-only | T31a, T31b, T32 → T35; T33, T34 with rw-codegen |
| frontend coordination | TV1 (SysFn.zig) any time; TV2 after frontend T6; T32 after frontend T1, T7 |

Most-shared files: `control.zig` (T5, T14, T16, T20, T28, T32), `expr.zig` (T11a, T12, T14, T17, T20), `decl.zig` (T7, T11b, T13, T15, T19), `Sema.zig` (T3, T5, T11a/b, T15, T22, T24, T26a), `syscall.zig` (T7, T8, T14, T24, T28, T29), `discrete.zig` (T4, T11a/b, T25, T26a). Rebase on the previous task before starting.

## 4. Task L0b: one split plan (names resolved)

This is behaviour-free. Gate: diff-lower still agrees on 2180 of 2628, and test-sema, check_style and fmt pass. The 500-code-line budget (code-style) decides each split; Zig keeps these in one Sema.zig (§5 D1).

| from | to | why / collision resolved |
|---|---|---|
| `contrib.zig` (488 code lines) | `contrib.zig` (Target, contribute, rowOf; T6's `discardOpposite` lands here); `access.zig` (accessOf, access, terminal lookup, `I(<p>)`/port flow); `indirect.zig` (contrib_indirect); `mfactor.zig` (mfactorOf, scaled) | B1/B2's `terminal.zig` and `port_flow.zig` are **not** separate files: terminal lookup and port flow are both access lowering (§5.4), so they live in `access.zig`. D2's `retain.zig` is dropped: contrib.zig has room after the split |
| `control.zig` (458) | `control.zig` (body, block, assignTo, operands, event_wait); **`condbr.zig`** (if, case, loop, repeat) | D1 proposed `branch.zig` for this. That name goes to §5.4.1 branch declarations (B1/B2/D8). `condbr` is the Zig name (`zirCondbr`) |
| `decl.zig` branch declarations | **`branch.zig`** | B1-G3a / B2-D8 |
| `net.zig` (360) | `net.zig` (ports, nets, vectorRange); **`portbind.zig`** (bindChildPorts, bindBridges, bridgeNets, continuous) | B2 proposed `bind.zig`, which would collide with `Sema.Bind` (the name-binding union). B1's `portbind.zig` wins |
| `param.zig` (366) | `param.zig`; `param_paramset.zig` (paramsetRows, boundIn); **`param_check.zig`** (stateRead; T14 adds unboundRead, checkOverrides) | C proposed `constexpr.zig`. `param_check` follows the `discrete_check.zig` precedent and names the data checked |
| `held.zig` (377) | `held.zig`; `held_writes.zig` (target, eventWrites, elemOf) | D2 |
| `Sema.zig` Block/Bind → `Sema/Block.zig` | **not done** | Sema.zig is 342 code lines, and Zig keeps `Block` in Sema.zig (Z/Sema.zig:351) |
| `eval.zig` | not split in L0b | T1 lands first. T10 then creates `eval_fn.zig` |
| `lower_test.zig` (480) | stays; its helpers become `pub`; new tests go in `held_test.zig`, `param_test.zig`, …, registered beside it | the code-style budget |
| `walk.zig` (475 code lines) | not split | frontend T1 owns walk.zig edits; T8/T13 add one line each |

## 5. Departures from Zig

| # | departure | reason |
|---|---|---|
| D1 | Sema is split by transform into files of at most 500 code lines; Zig keeps Sema.zig as one file (Z/Sema.zig, ~37k lines), with only arith, type_resolution and comptime_ptr_access split out | AGENTS.md code-style budget. `Block` stays in Sema.zig as in Zig |
| D2 | Held variables are found by a Vir walk **before** lowering (`held.zig`). Zig finds liveness by an Air pass **after** Sema (Z/Air/Liveness.zig) | `unit.held` decides storage and the `$assigned` counters before statements lower. T2 removes the old-shape part: the syscall write list moves into `SysFn.Info.writes`, one table like S/BuiltinFn.zig. Moving to an Air pass is §6 Q1 |
| D3 | Statement order inside a unit and between units is the old flattener's, so the last ulp agrees (T7) | the oracle compares bit-exact, and §5.2 sets no order. A fixed order is still the determinism rule |
| D4 | Four-state (x/z) planes, D2A sites, A2D holds and the `$assigned` counter have no Zig analogue | VAMS §7 semantics |
| D5 | Hidden RNG seed state lives in held slots (T3) | §9.13 state has no Zig analogue. Its intrinsic form is §6 Q2 |
| D6 | The `$error` in analog initial → `$fatal` guard is synthesised by Sema (T7) | §9.7 run semantics; Zig has no equivalent |
| D7 | Rulings and oracle normalisations live in the harness (`lower.rulings`, held array rows, elab `drops`) | the tests' oracle, not the compiler |

Fixes that copied the old shape and were reshaped here:
- D2-A's `writtenFrom` string table becomes `SysFn.Info.writes`.
- D2-J's per-instance `EnumArray` column becomes the existence table `hier_srcs`.
- C-C1's `@hasDecl(visitor, "reports_schemes")` becomes an enum parameter.
- E's `label` field becomes a Zig note.
- B2's `bind.zig` is renamed `portbind.zig`.

## 6. Oracles and red-first faults (per task)

The common oracle is the old pipeline through diff-lower: codes, then tables, then Air.Verify, then values. Values are bit-exact through `kernels.fold`. Every task's first commit is the red test; the planted fault shows it fails for the right reason.

| T | oracle | red test (fails today) | planted fault (fix in, then revert one line: must go red) |
|---|---|---|---|
| L0a | old `$display` widths (values.zig) | a `{a,b}` display operand width | `width` returns 32 for every concat |
| L0c | elab.rulings `drops`; settle.Rulings | generate_if_instantiates_one_arm clears | skip the filter: the line returns |
| T1 | §4.2.1.1, the old constfold `analog/constfold.zig:86-93` | `$rtoi(1.75)=1`, `$rtoi(-1.75)=-1`, `$itor(-2147483647)` | truncate by rounding: 1.75 → 2 |
| T2 | old `held.zig:184-203` | `c = $fgets(t, fd); I(p) <+ c;` expects `held t` | drop `flush` at `.store` |
| T3 | `random.zig:224`; §9.13.1 "does not update the parameter" | `a = $arandom(7)` expects `$rng.0.seed`, `$rng.0.ready` | write back to a parameter seed |
| T4 | old `held.zig:384` | mixed `initial #1 c = x > 0; analog x = V(p);` expects `held x` | omit the `$q_*` exclusion: stochastic_queue gains a row |
| T5 | §7.3.6.1 | `assign w = lv; analog @(initial_step) lv = 1;` expects `$assigned.lv` | skip the increment in assignTo |
| T6 | the §5.6.1.3 clause example (7) | value_retention body: 7 | keep `react` unzeroed: 8 |
| T7 | bit-exact sums | split_one_instance_per_port values equal | parent first: last ulp differs |
| T8 | diff-lower values | geometry_card_mfactor scales with `k` | return 1 from `mfactorRef` |
| T9 | §4.7.2.3; Air.Verify | `s = f(1.0)` with `string f` passes Verify, value `""` | `.string => .zero` |
| T10 | C's table (I1–I7), the old constfold | `param_test.zig` `expectDefaults` rows | drop the bit-63 flip |
| T11a/b | §7.3.2 / §7.3.4; old rows | `__xz` and `__d2a0` rows | emit a row without `__xz` |
| T12 | §4.5 (analog operators run every iteration); old values | idtmod values with a short-circuited `idtmod` | lower the rhs only when taken |
| T13 | C's P table | `param u.fr.jval` row | stop after the first link |
| T14–T30 | the old code (each group's `O/` site); fixture `//! expect` codes | `expectCode` per group (the slice report's red tests) | delete the raise |
| T31–T35 | old stderr bytes (diff-comp) | the fixture's text | change one word |

Every new `Sema` function gets two or more assertions (the assertions skill): entry invariants such as `assert(depth <= depth_max)`, row-count bounds, and `assert(@sizeOf(PsLevel) == 36)`. Every loop over Vir is bounded by `depth_max` or by the table length.

## 7. Gates (per task; gate on the exit code: `cmd > log 2>&1; echo $?`)

Every task:
- `$H <wt> check test-unit test-sema rewrite`
- `python3 ~/.claude/skills/code-style/check_style.py <touched>`
- `nix develop -c zig fmt --check <touched>`
- `$H <wt> diff-lower -j4 -Dlower-dump=<a fixture>` while working, then a plain `$H <wt> diff-lower -j4` before the PR. The agree count must rise by exactly the task's lines, and no new line may appear.

| T | extra gate | lists it may change |
|---|---|---|
| L0a | `$H <wt> diff-comp -j4` (report the 142 + 24) | lower.xfail (delete; name any new width line) |
| L0b | the agree count unchanged | none |
| L0c | – | lower.xfail, **lower.rulings** (new) |
| T1 | `$H <wt> diff-comp -j4 -Dcomp-filter='analog_attributes\|conversion_constant'`; tell plan-vpi | lower.xfail |
| TV1, TV2 | `$H <wt> test-vams diff-astgen -j4` | astgen.xfail if touched |
| T7, T12 | `$H <wt> diff-lower -j4` twice: two runs must give the same bytes | lower.xfail |
| T13, T20 | – | lower.xfail, `tests/differential/stages.zig`; T13 also 1 line of lower.rulings |
| T14–T30 | `$H <wt> diff-comp -j4 -Dcomp-filter='<the task's fixtures>'` | lower.xfail |
| T31–T35 | `$H <wt> diff-comp -j4 -Dcomp-filter='<fixtures>'` | none (comp only) |

comp.xfail: never edited. Each PR body lists the comp lines it clears, for the lead.

## 8. Skill rules where they bite

| skill | bites at |
|---|---|
| data-oriented-design | The six questions for every new table. `SysFn.Info.writes` (comptime; one per tag; u8; read by held_writes, T29). `Sema.rng_sites` (writer dist.lowerCall; reader the same; count ≤ seed sites; Sema-run lifetime; key 12 B, value 8 B). `Device.rng_auto_seeds` (i64, writer dist, reader codegen). `Sema.assign_counts` (u32→u32). `Zcu.hier_srcs` (an existence table, 12 B, not a column). `Zcu.paramset_levels` (MultiArrayList, 36 B asserted). `Zcu.ps_defparams` (12 B). `Unit.xz` / `Unit.d2a`. `Bind.branches{first,msb,lsb}` (3×u32). `Zcu.Part.arg: u32`. Node meta hot/cold split (T33). `init_error` is a sentinel handle, not `?Index` |
| codebase-clean-code | `decl.run` stays the spine (T7 edits only its order lines); one owner per table (held_writes writes `unit.held`; dist writes `rng_*`); lib/std/vams is frontend-owned, so changes go as TV1/TV2 requests |
| api-design | New pub fns take caller memory (`Allocator` + the table): `mfactorRef`, `a2dReads(s, unit) []const Inst.Index` (caller's arena), `genfor.generate(..., report: Report)` |
| code-style | §4 splits; every touched file ≤500 code lines; Contents updated; the `// ---- private ----` separator |
| doc-comments | Each new file's `//!` gives in → out and the §-clauses; `Writes` documents the argument indices |
| assertions | ≥2 per function; Vir loops bounded by `depth_max`; size asserts on PsLevel, HierSrc and PsDefparam |
| test-plan, tdd | The oracle is named per task (§6); red-first; a bug class gets its generator (T2: every `SysFn` with `writes` gets a held test generated from the table) |
| zig | Sentinel enums over optionals; `packed struct(u8)` for `Writes`; `errdefer` after each table append |
| ponytail | No `retain.zig`, `terminal.zig`, `port_flow.zig` or `Block.zig`; `writtenFrom` deleted |
| compiler-construction | Coded diagnostics; goldens are the old side; rulings are named lines |
| spice-engine | T6 (§5.6.1.3 accumulators), T7 (fixed sum order), T33 (abstol per node, nodeset) |
| simd-loops, writing-perfect-verilog | No hot loop is added; no Verilog is emitted (nothing here) |

## 9. Risks

- The lower.xfail reasons are stale (they are never regenerated). Slice C found 4 stale lines and D1 found 3, so a fixed line may show a second difference: B2-C8, D1-N, Z15, P2 (geometry_top_alias_host), C8b analog_attributes. Each task re-measures with `-Dlower-dump` before claiming lines.
- T7 changes the lowering order for every design with a connect module. Watch for row-order changes in tables beyond the 10 lines.
- T12 changes `&&`/`||` lowering everywhere. D1-M's values depend on old evaluating both operands of an analog operator; confirm against §4.5 before matching the old.
- D2-G's guard: `Walk.elemOf` folds through `decl.foldRef`, which may fold card-overridable parameters and miss a hold. Fold only literals, genvars and localparams there (T2).
- Codegen dependencies (T3, T33, T34) stall unless plan-codegen schedules the matching work.
- lib/std/vams: TV1 and TV2 collide with frontend T6 and T1 (Vir/Inst.zig, AstGen/stmt.zig, Parse).

## 10. Open questions

1. **Held analysis: Vir pre-pass or Air Liveness pass?** Recommendation: keep the Vir pre-pass for T2/T4/T5 (lowering reads `unit.held`), with `SysFn.Info.writes` as the single write table. Revisit as an Air pass (Z/Air/Liveness.zig) after the switchover.
   Decision: Vir pre-pass now, `SysFn.Info.writes` the single write table. Recorded as a departure; an Air Liveness-style pass (Zig `src/Air/Liveness.zig`) is a post-switchover follow-up in research/README.md.
2. **RNG intrinsics (`rng$next`, `rng$auto`): SysFn tags or Air-internal?** Recommendation: Air-internal (an Air `call` of a Device kernel id). SysFn mirrors S/BuiltinFn.zig, which lists only spellable builtins, and this keeps T3 out of lib/std/vams.
   Decision: Air-internal: `SysFn` mirrors `BuiltinFn.zig`, which lists only spellable builtins.
3. **Secondary spans in messages (A22–A24): a new `label` field on `Zcu.Failure`, or a note with its own source location?** Recommendation: a note (Z/Zcu.zig:1262 `ErrorMsg.notes`). `errors.zig` renders a note on the primary's line as the label.
   Decision: A note with its own location (Zig `Zcu.ErrorMsg.notes`); no `label` field. Same answer as airpasses' notes.
4. **`lower.rulings`: add it, read through `settle.Rulings`, and also read `elab.rulings` `drops` in diff-lower?** Recommendation: yes. 12 lines become rulings (C-P4 ×5, C-I4, C-I7, D1-Z6, D2-F ×3, D2-G), plus spice_paramset_shadow after T13.
   Decision: Yes: `lower.rulings` through `settle.Rulings`, and diff-lower reads `elab.rulings` drops. Every line cites its LRM clause.
5. **Held arrays: normalise the oracle (one row with a count), or emit per-element rows?** Recommendation: normalise the oracle (D2-C). One row is what codegen wants.
   Decision: Normalise the oracle to one row with a count: same information, codegen's shape, and the oracle still does not compute rows the way the code does.
6. **Connect-module order (T7): match the old preorder bit-exactly, or compare with a tolerance?** Recommendation: match the preorder. The order is fixed either way, and exact comparison catches real sum bugs.
   Decision: Match the old preorder bit-exactly. The order is fixed (determinism is a test), and a tolerance would hide real sum bugs.
7. **Stale fixture headers in the conformance submodule (A-G13 E0316, VD-116 revised; B2-B1 E0997): who fixes them?** Recommendation: the lead, in one conformance PR. Not in these tasks.
   Decision: The lead, on one conformance-submodule branch together with diagcodes A5's flips; pushed only with the user's approval (it is the user's repo).
8. **Array cell cap (A-G7): keep 2^16 with E1015, or go to u32 with E1016 and a memory-backed `Bind.mem`?** Recommendation: keep 2^16 and rule the one line, unless Device/codegen already has memory arrays. `Bind.mem` is a feature, not a fix.
   Decision: Overrides the recommendation: go to `u32` cells with E1016 (a `limit-` code) and a memory-backed `Bind.mem`. A ruling needs the old side wrong; a 2^16 cap the old side lacks refuses legal designs (a 64K-word memory is a real design), which is a regression, not a ruling. Schedule it after the wrong-number tasks.
9. **Split names (§4): `portbind.zig`, `condbr.zig`, `branch.zig` (declarations), `param_check.zig`; no `Block.zig`?** Recommendation: as written.
   Decision: As written.
10. **Stage table: move E0237 to `.elab` and E0222 to `.sema`?** Recommendation: yes (T13, T20). E0926 stays `.sema`.
    Decision: Yes (T13, T20); E0926 stays `.sema`.
11. **Retags in comp.xfail (lead-only): 23 → rw-codegen (E C-G5..G9, G15, G16), 2 → kernels (C-G10), 1 + 1 → rw-dlower (C-G14, D2), 26 → rw-comp (D1 gate_notices)?** Recommendation: retag now, so rw-lower's comp count is honest.
    Decision: Yes, retag now, by the lead in the next rebaseline.
12. **D1-M: should an analog operator inside a short-circuited operand still run every iteration (old evaluates both)?** Recommendation: yes, per §4.5. The analog operator's state must advance; this is a wrong number if it is skipped.
    Decision: Yes, per VAMS §4.5: an analog operator's state advances every iteration whatever the short circuit; skipping it is a wrong number, so this task is in the first wave.
13. **TV2 ordering with frontend T6:** recommendation: one PR, with T6's `Process.attrs` and TV2's `Name.attrs`/`call_attrs` designed together (the same attribute list handle).
    Decision: One PR with one owner (frontend T6's agent takes TV2), one attribute-list handle for `Process.attrs`, `Name.attrs` and `call_attrs`.
