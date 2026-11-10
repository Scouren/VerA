# Plan: device codegen (`codegen`, the Zig device backend)

Planner: read-only research, no builds, no runs. Spec: `docs/rewrite/codegen.md`,
`docs/rewrite/float-guard.md`, `lib/TODO.md` §11.3/§11.7/§11.9/§11.10, A.5.
Old side (the oracle, never edited): `src/codegen/device/`, `src/analog/`,
`src/ir/`. New side: `src/codegen.zig`, `src/codegen/zig.zig`,
`src/codegen/zig/*`, and the `src/Sema/*`, `src/Air/Device.zig`, `src/Zcu.zig`
sites each group names.

Zig mirrors cite the pinned compiler, `~/.cache/zig-src-d924f83bf`
(`git log -1` = `d924f83bf3`, checked), as `zig:src/<file>:<line>`.

Lists covered: `tests/differential/codegen.xfail` (516 at `refactor` 90e93007)
and the `comp.xfail` lines owned by `rw-codegen` (488). The 11
`digital_device.xfail` `rw-codegen` lines go to plan-vbackends (the lead's routing).

---

## 0. Starting state

| what | where | state |
|---|---|---|
| §4.5 operator state: transition, slew, idtmod, last_crossing | worktree `.claude/worktrees/agent-a8e9cf0ce53f8a541`, commit `4a358e61` | unmerged; `git merge-tree refactor 4a358e61` is clean |
| absdelay ring (`ops/delay.zig`, untracked, 203 lines; `hist_len` 1024, `hist_max` 16384), `genCall` moved into `calls.zig`, `ops.value` pub, `ops.Field.ty`, `ops.gen{Instance,State,Commit,RevertPre,RevertPost}`, `Liveness.effect` + `.absdelay` | same worktree, **uncommitted** | together with 4a358e61: the worktree's `codegen.xfail` has **468** entries, 48 fewer (34 §4.5 + 14 absdelay) |
| `tests/differential/codegen/sides.zig`: the old preprocessor's directives passed into `AstGen.generate` (`directives`, `regions`) | same worktree, uncommitted | needed by `simparam_timescale` and the `unconnected_drive` fixtures |
| `tests/bench_fast.zig`: noise measured in-run, `least` statistic, `noise_min = 0.03`; a device that does not version only reports | same worktree, uncommitted | keep (no list effect) |
| §9.4 display records (`say.zig`, `say_sites`, `display$width`) | worktree `agent-a304e3c81ac4634e0`, commit `2cc21df1` | already merged into `refactor`: nothing to carry |

What a8e9 leaves:
- 4 absdelay lines whose reason is stale:
  - `absdelay_vera_interp_quadratic{,_uneven}.va`: Sema drops `vera_interp`. Old: `src/analog/analog_op.zig:493-499` → callee `absdelay$quad` (`src/ir/callee.zig:166`).
  - `dynamic_constant_argument_resampled_per_analysis.va`: an absdelay inside a `$strobe` operand. `say` runs the body a second time and holds no operator state.
  - `integer_parameter_precision_control.va`: cause not traced; T0 refreshes it.
- The rollback path (`stateCtl(.revert)`, `genRevertPre/Post`) is not covered by any oracle, because `dyn.zig` accepts every point (4a358e61's own message says so). T0b adds the oracle.
- `check_style.py` already reports 19 violations in `src/codegen/zig/{DeclGen,say,stamps,state}.zig`: order, plus `DeclGen.zig:75` `no_bit` missing from Contents and `stamps.zig:100` a private fn above the separator. Every task leaves the files it touches clean.

**No reason in `codegen.xfail` has been verified.** diff-codegen compares fixture *names* only (the XPASS/STALE check). The list was last rewritten at `028e986c`. Two consequences are proven:
1. Every "display record value N: old X, **versioned** Y" line is really a strict-new difference. At `tests/differential/codegen.zig:545` the say loop `for (1..sides_n) |s|` is unlabelled, so the `break` at `:557` (and at `:549`) leaves only the inner `for (a, b, 0..)`, and `s == 2` overwrites `say_why`. Since `5a291053` a body without a transcendental is not versioned, so the versioned text is the strict text.
2. The 4 absdelay lines above.

---

## 1. Root causes

### 1a. `codegen.xfail` (516 = 48 done by a8e9 + 468 below)

Done by a8e9 (48): `transition` 22, `slew` 6, `idtmod` 3, `last_crossing` 3, `absdelay` 14.

Wrong numbers and stops (75). Plan these first.

| id | cause | lines | examples | owner |
|---|---|---|---|---|
| W1 | §9.7.3 `$fatal`/`$error` are not latched: eval keeps returning rows | 9 | `ch09/fatal.va`, `severity_tasks.va`, `say_ops.va` ×2 | codegen |
| W2 | §3.6.2.1 signal-flow nets: a flow-only net's row is not the old `.set` term | 3 | `electrical_definitions.va`, `flow_signal_flow.va` | Sema + codegen |
| W3 | §9.18 `$mfactor`/`$xposition`… of a child instance are not folded | 6 | `mfactor_divides_potential_noise_power`, `geometry_hierarchical_overrides` | Sema |
| W4 | §9.19 `$param_given` in a child instance is not folded | 4 | `binding_source_overrides`, `paramset_unoverridden_defaults` | Sema |
| W5 | the constants of a plain `initial` block are not installed as initial values | 10 | `child_initial_block_is_carried` (row), `digital_initial_accepted` ×2, `discrete_bus_31` | Sema |
| W6 | a non-held array's declaration initializer is dropped | 3 | `dynamic_multidim_numeric`, `vera_scratch_uninit_tape` | Sema |
| W7 | a string literal assigned to an `integer` is not truncated to 32 bits (§3.2) | 1 | `string_literal_to_integral` | Sema |
| W8 | an analog function with no return type returns `integer`; §4.7.1 says real | 2 | `analog_function_keyword`, `function_implicit_real_return` | Sema |
| W9 | nature attributes are read from the node's discipline, not the segment's (§5.5.3, §3.6.2) | 3 | `derived_nature_from_discipline`, `node_abstol_resolved_segment` | Sema |
| W10 | IEEE 1364 §5.5.1: an unsigned operand does not make a comparison unsigned | 3 | `unsigned_operand_makes_the_expression_unsigned`, `wide_unsigned_compare_extends_each_operand` | Sema |
| W11 | derivation is refused for a ternary, `&&` or `||`, so the folded default stands | 3 | `dependent_control_host`, `dependent_control_operators` | Sema + codegen |
| W12 | defparam rows are not re-derived (`src/Sema/derive.zig:125` skips them) | 2 | `defparam_unsupported`, `paramset_outer_defparam_selection_parameter` | Sema |
| W13 | `$simparam("timeUnit")` gives 0; old folds the `` `timescale `` constant (`src/ir/simparam.zig:73-74`) | 1 | `simparam_timescale` | Sema |
| W14 | display site widths: the 9 discrete reads print `%d` where old prints `%Nd` | 9 | `procedural_continuous_semantics`, the wand interconnect, `and g(y,a,b)` | Sema |
| W15 | display site widths: `analysis()` is int (`%11d`) on the new side and real (`%20d`, VD-120) on the old | 8 | `analysis("dc")`, `analysis("static") … TRAN OP` | **ruling (Q1)** |
| W16 | ruling: `abs(+0)` gives −0 on the new side, +0 on the old | 2 | `abs.va`, `exhaustive/rounding_selection.va` | **ruling (Q2)** |
| W17 | ruling: `fmod` of a negative dividend with zero remainder: old +0, new −0 (C `fmod`) | 1 | `hypot_fmod_extreme_magnitude` | **ruling (Q3a)** |
| W18 | ruling: folded `cosh(-1)`: old `std.math.cosh` is 1 ulp off, new is correctly rounded | 2 | `ch04/cosh.va`, `exhaustive/hyperbolic.va` | **ruling (Q3b)** |
| W19 | old device segfaults: `dyn.zig` never binds `Instance.systf` | 3 | `cube_solve`, `analog_systf_resistor_call`, `analog_system_task_registration` | oracle (T0b) + R11 |

Notes:
- W1–W13 and W16–W18 together are the 38 "display record value" lines (A–K in the fork notes) plus the 17 "row" lines: 9 W1, 3 W2, 2 W5, 2 W12, 1 W13.
- W14 and W15 are the 17 "display site" lines.
- The display-record split: W3 6, W4 4, W11 3, W5 8, W6 3, W7 1, W8 2, W9 3, W10 3, W16+W17 3, W18 2.

Refusals and build failures (393):

| id | cause (new site) | lines | examples | owner |
|---|---|---|---|---|
| R1 | §4.5.10–11 events `cross` 36, `above` 9, `timer` 43 (`calls.zig:225`) | 88 | `a09_cross_rejector.va`, `va_tick.va` | codegen |
| R2 | §4.6.2 `analog$initial` (`calls.zig:225`) | 18 | `analog_initial.va`, `a09_initial_once.va` | codegen |
| R3 | absdelay leftovers (see §0) | 4 | `absdelay_vera_interp_quadratic.va` | Sema (quad) + codegen |
| R4 | §4.5.11–12 filters: `laplace_*` 19, `zi_*` 9 | 28 | `laplace_nd_dc_gain.va`, `zi_dc_gains.va` | codegen + Sema (E0540) |
| R5 | §4.6.3 `ac_stim` | 8 | `ac_stim.va`, `ac_stim_ac_analysis.va` | codegen (**VPI G8/G9**) |
| R6 | §9.19 `$port_connected` (root: the host-written `Model.port_connected__`) | 8 | `port_connected.va`, `binding_detection.va` | codegen + Sema (children, W4's fold) |
| R7 | §4.5.1 `idt$hold` | 6 | `idt_assert_release_resumes.va` | codegen |
| R8 | strings: `$sformat` 22, `$swrite` 4, `str$cmp` 3, `$sscanf` 2, "a slot of type 2 (a string)" 32 (`Function.zig:238`), "a real operand that is not a number" 9 (`Function.zig:155`), `$simparam$str` 3, "parameter `x` is not a number" 3 (`DeclGen.zig:241`) | 78 | `held_sformat_string_survives_rejected_step.va`, the ch02 `CHECKI("…", "<lit>", int)` fixtures | codegen |
| R9 | §9.16 `$test$plusargs` 3, `$value$plusargs` 2 | 5 | `plusargs.va`, `plusargs_prefix.va` | codegen |
| R10 | §9.13 `$random` 3, `$arandom` 2, `$dist_*` 8, `$rdist_*` 11 | 24 | `random.va`, `rdist_normal.va` | codegen |
| R11 | "a call of a user function (callee 4294967295)" (`calls.zig:51`): VPI systf 9, `$simprobe` 7 | 16 | `va_vpi_gain`, `env_probe`; `simprobe_reads_a_sibling_output_variable` | codegen (systf, **VPI G8/G9**) + Sema (`$simprobe`) |
| R12 | §9.17.3 `$limit` string form (`calls.zig:207`) | 26 | `limit_pnj.va`, `limit_fet.va` | codegen |
| R13 | §5.6.5 a flow contribution to a potential source's branch (`stamps.zig:130`) | 20 | `cap_ramp.va`, `natureless_domainless_port_compatibility.va` | codegen (**VPI G8/G9**) |
| R14 | §5.6.5 a potential contribution under a condition: a switch branch (`stamps.zig:121`) | 16 | `conditional_potential_open.va`, `implicit_zero_contribution.va` | codegen |
| R15 | §5.6.7 indirect contribution (`stamps.zig:118`) | 8 | `indirect_contribution.va` | codegen |
| R16 | §5.6.1.2 path latch (`Function.zig:569`) | 2 | `batch_per_instance_state.va`, `va_limit_state.va` | codegen |
| R17 | "parameter `x`'s default does not fold" (`DeclGen.zig:233`): `$simparam` in a default 4, `dependent_control_unknown_local` 1 (cause not traced) | 5 | `simparam_fallback_as_parameter_default` | Sema |
| B1 | the new device does not build, "unused local constant": noise args (`calls.zig:145` renders `S.con(0.0)`, while `Liveness` `Operands.collect` still marks the args used) | 24 | `ntab_card.va`, `hierarchy_empty_named_semantics.va` | codegen |
| B2 | the new device does not build, "unused function parameter": `updateState(S, model, inst, x, _, sim)` with only limit slots | 9 | `va_limit.va`, `a09_limit_ramp.va` | codegen |

Check: 75 + 393 = 468. R8 is 78 (31 calls + 32 + 9 + 3 + 3).

### 1b. `comp.xfail` `rw-codegen` lines (488; report only, never edited)

| id | lines | cause | fix |
|---|---|---|---|
| C1 | 335 | "exit status old 0, new 1" on a fixture `codegen.xfail` also lists | clears with that fixture's R/B/W group |
| C2 | 69 | "exit status old 0, new 1" on a fixture `lower.xfail` lists (diff-codegen skips it) | lowering first, then codegen |
| C3 | 6 | "exit status old 0, new 1", cause unknown: `spice_binned_model_selects_by_l_and_w`, `vcvs_inside_a_spice_subcircuit`, `alias_card_write_sets_original_given`, `parameter_alias`, `noise_table_file_name_parameter`, `exhaustive/parameters` | T0 runs them once with `-Dcodegen-why` (see §5) |
| C4 | 49 | "display phase": the judge misattributes Sema `= note`/`= help` lines (E0401, E0501, E0362, E0514, E0818, E0324, E0369, E0434, E0415, E0337, E0402, E0517, E0806, E0891) | not codegen; `tests/differential/comp/judge.zig` `dropped()` must skip `= note`/`= help` lines (lead, Q5) |
| C5 | 2 | "display phase" `$monitor`: `display_monitor.va`, `monitor_after_macro_process.va` | T24 |
| C6 | 3 | "display phase", not codegen: `switch_primitive_accepted` (run output), `digital_function_from_analog_{rejected,unsupported}` (the diagnostic's location) | Sema/front end (lead routes) |
| C7 | 6 | "(codegen) stderr" W0650: the unit label is empty, because `codegen.floatRoots` leaves `Root.name = ""` and `loc = .none` | T23 |
| C8 | 8 | "(codegen) stderr": E0540 ×3, E0527 ×2, W0853 ×2, W0850 ×1 | T23 (the checks move into Sema) |
| C9 | 2 | "(codegen)" `error`/`fatal_in_analog_initial` print "codegen refused" | T1 |
| C10 | 8 | "(run)": W0251 specify ×3 (front end), `res[p]` vs `x[uZ2e…]` ×4 (Sema lowers specify paths as an extra unknown), `absdelay_history_past_capacity` ×1 | not codegen, except the last one, which T0 rechecks after a8e9 (W1051) |

Check: 335 + 69 + 6 + 49 + 2 + 3 + 6 + 8 + 2 + 8 = 488.

---

## 2. The fixes (per group, with the Zig mirror)

Rule for every task:
- A table is filled by Sema, or by an Air pass, and read by codegen. Codegen never plans a fact that a later reader of Air would also need.
- Codegen code lives in a new file per family under `src/codegen/zig/`.
- A shared file (`calls.zig` dispatch, `DeclGen.genFile` order, `Function.genInst`) gains only its arm or its one call line.

### W1 status latch (T1)
- **Old**:
  - `src/codegen/device/codegen/status.zig:24-69`: `status_sites`, `zStatusStore`, `status_drop`.
  - Fields `Instance.vera_status__: u32` and `vera_status_args__: [4]f64`.
  - `dispatch.zig:378-390`: eval returns zero rows when the latch is set.
  - `dispatch_q.zig:71`; `state.zig:246`: updateState leaves the state alone.
  - Contract: `lib/contract/display_records.zig:36` `StatusSite`, `statusCode(sev, site)`. Validation at `validate_entries.zig:113-116`.
- **New**:
  - New file `src/codegen/zig/status.zig` (about 150 lines):
    - `pub const arg_max = 4;`
    - `pub const Site = struct { call: Air.Inst.Index, severity: contract.Severity, fmt: []const u8, file: []const u8, line: u32 };`
    - `pub fn plan(dg: *DeclGen) DeclGen.Error!void` collects the `$fatal`/`$error` rows of `Device.displays`.
    - `pub fn genDecls(dg: *DeclGen, w: *Writer) DeclGen.Error!void` writes `status_sites` and `zSitesZero`.
    - `pub fn record(f: *Function, inst: Air.Inst.Index) DeclGen.Error!void` writes, at the call: `if (st__ == 0) { st__ = <statusCode>; sa__ = .{…} }`.
  - Core gains locals `var st__: u32 = 0; var sa__: [4]f64 = @splat(0)` and returns them.
  - In `DeclGen.genEntries`, eval, q and evalQ do `zStatusStore(inst, m)`, then `if (inst.vera_status__ != 0) return zero rows`.
  - In `state.zig` `genEntries`, updateState returns `.ok` early when the latch is set; initState and setupInstance clear the latch.
  - `say.zig:148` keeps excluding these tags.
- **Data**:
  - Instance `vera_status__: u32`, `vera_status_args__: [4]f64`; capacity 4 args, with `comptime assert(arg_max == 4)`.
  - `Air.Device.Display` gains `file: String, line: u32`, filled by Sema where it appends `displays`. `say_sites` gets the same `file`/`line` it writes as `""`/`0` today (`say.zig:100`).
- **Zig mirror**: `@panic` and `@trap` lower in `zig:src/codegen/c.zig:4620` `airTrap` and through the panic handler at `airCall` `:4052`. The source line comes from `dbg_stmt` (`c.zig:4180` `airDbgStmt`).
- **Departure**: a device cannot trap its host, so the handler is a latch the host reads (see "Departures").
- **Clears**: 9 rows. Also comp C9 (2).

### W2 flow-only nets (T2)
- **Old**:
  - `src/codegen/device/codegen/stamps.zig:156-175`: a flow-only net's KCL row is `.set` to `xs[n] - m.r<k>`.
  - `plan/topology.zig:176-205` decides which net is flow-only, from port direction and the absence of a potential nature.
- **New**:
  - New table `Air.Device.flow_only: std.DynamicBitSetUnmanaged`, one bit per `nodes` row. Sema fills it in `src/Sema/contrib.zig`, at the place where nodes are minted, from §3.6.2.1 (a discipline whose nature binds flow only).
  - `src/codegen/zig/stamps.zig` `plan()` adds `Term.set: struct { node: u32, contrib: Contribution.Index }`. `qPlan` uses the −sign for it.
- **Zig mirror**: Sema owns the fact, codegen only renders it, as Sema's type resolution feeds `c.zig` `DeclGen.renderType` (`c.zig:1868`).
- **Clears**: 3.

### W3, W4, W13, R6-children: per-instance folds in Sema (T3)
- **Old**: `src/elab/clone_expr.zig:376-391` `rewriteSysCall` folds `$mfactor`/geometry to `unit.hier.get(k)`, `$param_given` to `unit.given`, and `$port_connected` to `unit.connected`.
- **New**, in `src/Sema/syscall.zig` `lower` (about 45-95), on a `.query` when the instance is not a root:
  - a `Zcu.SystemParam` returns the interned `zcu.instances.items(.hier)[i].get(k)`, reusing `src/Sema/eval.zig:330`;
  - `$param_given` returns bit k of the new `Zcu.Instance.given`;
  - `$port_connected` returns whether `ports[k].actual != .none`.
  - The root keeps the call (the host writes it).
  - W13: `$simparam("timeUnit"/"timePrecision")` folds to the module's `` `timescale `` (old `src/ir/simparam.zig:73-74`). This needs `sides.zig`'s directives from a8e9.
- **Data**: `Zcu.Instance.given: InternPool.Index`. It is an interned aggregate of `bool`, one per module parameter in declaration order, `.none` on a root. It is written where overrides, defparams and paramsets are applied (`src/Sema/param.zig`, `defparam.zig`, `paramset.zig`).
- **Key**: `Zcu.Instance.Key` gains `hier` and `given`. Two instances with different `$mfactor` must not share one Air.
- **Zig mirror**: a generic instantiation is keyed by all its comptime args. See `zig:src/InternPool.zig:4306` `func_instance` and `zig:src/Sema.zig:6605` `analyzeCall`. A per-instance constant is a comptime arg.
- **Risk**: `$mfactor` scaling of noise and flow probes (old `mfactorNoise`/`mfactorScale`) must not be applied twice once the value is folded. T3 checks the two noise fixtures.
- **Clears**: 6 + 4 + 1 = 11. Also R6's child part, which needs T10's root part to clear.

### W5, W6, W7 variables (T4)
- **W5**:
  - Old: `src/analog/initial_state.zig:32-102` `collectInitialState`, installed at `src/analog/module.zig:220,227,350`.
  - New file `src/Sema/initial.zig`: `pub fn collect(s: *Sema, body: Vir.Body) Allocator.Error![]const InternPool.Index`, one folded value per variable, `.none` when absent.
  - `src/Sema/variable.zig` `declare` takes it as the variable's init when `discrete.isMixed` is false.
- **W6**: in `src/Sema/variable.zig:73-110`, an `.array` bind emits its per-evaluation init (a new array value and one store per element), as `.slot` does.
- **W7**: in the `.str` arm of `variable.zig`, call `fold.strToInt(k.str, 32)` and truncate to i32.
- **Zig mirror**: a global's initializer is a comptime-folded value interned once (`zig:src/Sema.zig:2257` `resolveConstValue`).
- **Clears**: 10 + 3 + 1 = 14.

### W8, W9 (T6)
- **W8**: in `src/Sema/func.zig:62`, `.none` storage gives `.real` (VAMS §4.7.1).
- **W9**:
  - `src/Sema/hier.zig` `natureAttrOf` (about 214-238) honours the discipline's own attribute overrides.
  - `natureAttr` (about 172-212) reads the segment's declared or resolved discipline (§5.5.3 `resolveto`), not `device.nodes.items(.discipline)[row]`.
- **Zig mirror**: `zig:src/Sema.zig` resolves a declaration's type at its use site, not a parent's.
- **Clears**: 2 + 3 = 5.

### W10 signedness (T7)
- **Old**:
  - `src/analog/expr_op.zig:221-234`: each operand is zero-extended from its own width, then `constfold.unsignedCompare`.
  - Signedness from `src/analog/constfold.zig:340-397`.
- **New**:
  - `src/Sema/expr.zig:290-336` `binary`: the integer `Sema.Value` carries `signed: bool` and `width: u8`.
  - The §5.5.1 rules:
    - a literal's base and size decide;
    - `integer` is signed;
    - a comparison's result is unsigned (1 bit);
    - any unsigned operand makes the operation unsigned.
  - Before `ilt`/`ieq`, emit the zero-extend mask of each operand.
- **Zig mirror**: `zig:src/Sema.zig:32026` `cmpNumeric` compares mixed-signedness integers by widening each by its own `intInfo` (`zig:src/Type.zig:1803`).
- **Clears**: 3. Later sites of `mixed_sign_comparison_context` may surface once this lands (expected, not a regression).

### W11, W12, R17 derivation (T5)
- **W11**: `src/Sema/derive.zig:47-53` `expression` admits `block`/`cond_br`/`br` and recurses into their bodies for purity. `src/codegen/zig/Function.zig` `genTree` (about 107-137) renders such a subtree through `genInst` as labelled blocks.
- **W12**: `derive.zig:125` re-derives defparam rows. Old: `src/elab/defparam.zig:47-50`.
- **R17**:
  - A `$simparam` whose name is in `calls.host_params` is a pure read in `derive.expression`.
  - `calls.zig` `simparam` renders it as `model.<host field>` (already emitted) inside `derive`.
  - `dependent_control_unknown_local`: refresh its reason in T0 first.
- **Zig mirror**: a comptime-known function body is evaluated at the call (`zig:src/Sema.zig:6605` `analyzeCall`, comptime call).
- **Clears**: 3 + 2 + 5 = 10.

### W14 display widths (T8)
- **Old**: `src/analog/format.zig` `identSize`, and `src/analog/discrete_input.zig:204-212`. A discrete read keeps its width only for a ranged reg; otherwise it is an `integer`, 32 bits signed.
- **New**: `src/Sema/format.zig` `declSize` (:228) applies that rule, with membership read from `unit.discrete` (`src/Sema/discrete.zig` `mark`).
- **W15**: if Q1 rules for parity, `SysFn.zig:355` `analysis` → `.real`; if Q1 rules for the new type, add 8 `.rulings` lines.
- **Zig mirror**: a format argument's width comes from its type (`std.fmt` over `@TypeOf`); Sema owns the type.
- **Clears**: 9 (+8 by Q1).

### R1 events (T12)
- **Old**:
  - Eval: `call_operator.zig:186-212`. cross fires when `sim.kind == .tran and sim.dt > 0 and crossTest and enable`; timer uses `zTimerDue`; above fires when `prev <= 0 and in > 0 and enable`.
  - Slots: `op_zig.zig:115-140`. cross and above keep `prev`; timer keeps `next`, `start = NaN`, `per = NaN`.
  - Accept: `accept.zig:113,220-250` (`zCrossRetry` → `vera_cross_retry__`, `zNextTimer`).
  - Breakpoints: `breakpoints.zig:53-141` (`pendingBreakpoint`, `nextBreakpoint`); `instance.zig:116`.
- **New**:
  - New file `src/codegen/zig/ops/events.zig` (about 250 lines), a family module like a8e9's `ops/delay.zig`:
    - `pub const Kind = enum(u8) { cross, above, timer }`
    - `pub fn fields(k: Kind) []const ops.Field`
    - `pub fn genValue(f: *Function, site: ops.Site) Error!void`
    - `pub fn genCommit(dg: *DeclGen, w: *Writer, site: ops.Site) Error!void`
    - `pub fn genBreakpoints(dg: *DeclGen, w: *Writer) Error!void`: emits `nextBreakpoint` and `pendingBreakpoint`.
  - `ops.zig` `Kind` gains `.cross, .above, .timer`, each delegating to `events.zig`. `Liveness.effect` gains the three tags.
  - The kernels `zTimerDue`, `zNextTimer`, `zCrossDir`, `zCrossRetry` come from `lib/std/kernels` (port them if missing, with their old tests).
- **Data**: per site, `prev: f64` or `next/start/per: f64`; per instance, `vera_cross_retry__: f64`.
- **Zig mirror**: `c.zig` `Function` lowers each Air instruction to locals plus per-function state. Operator state that outlives a call has no Zig analogue (see "Departures").
- **Clears**: 88.

### R2, R6-root, R9, R12-A, B2 small arms (T10)
- **R2**: `.@"analog$initial"` → `@as(i64, @intFromBool(sim.analog_initial))`. Old: `call_analysis.zig:36-38`.
- **R6** (root): `.@"$port_connected"` → `@as(i64, (model.port_connected__ >> k) & 1)`, with `Model.port_connected__: u64 = maxInt(u64)` in `genModel`. Old: `call.zig:416-422`, `model.zig:125`.
- **R9**: `zPlusarg(inst.plusargs, …)`, with `Instance.plusargs: []const [:0]const u8 = &.{}`. Old: `call.zig:426-433`, `instance.zig:121-126`.
- **R12 phase A**: `$limit` with more than one argument renders `f.real(args[0])`. The old eval is the identity of the probe (`cg_limit.zig` header): the host clamps before eval.
- **B2**: in `state.zig` `genEntries`, when no reader of S/model/inst/x/sim was emitted, write `_ = .{ model, inst, x, sim }; _ = S;`. This one line keeps the parameter list fixed.
- **Zig mirror**: `c.zig:4052` `airCall` has one arm per builtin callee, from the `zig:lib/std/zig/BuiltinFn.zig:1` table.
- **Clears**: 18 + 8 + 5 + 26 + 9 = 66 (R6 needs T3 for children).

### B1, R5 noise and AC tables (T11, unblocks VPI G8/G9: ac_stim)
- **Old**: `src/codegen/device/codegen/noise.zig` (`noise_gens`, `noisePsd`, `ac_gens`, `acStim`, lines 215-270); contract `lib/contract/ac.zig:45` `AcGen`, `acStimActive`.
- **New**:
  - New file `src/codegen/zig/noise.zig` over `Air.Device.noise` (`ac_stim` is already `Noise.Kind.ac_stim`, from `src/Sema/op.zig:140`):
    - `pub fn plan(dg) Error!void`
    - `pub fn genTables(dg, w) Error!void`: `noise_gens`, `ac_gens`.
    - `pub fn genBody(dg) Error!Body`: a second body like `say.genBody` that returns the args of each source.
    - `pub fn genEntries(dg, w, b) Error!void`: `noisePsd`, `acStim`.
  - In eval, `ac_stim` is `S.con(if (acStimActive(name, sim.kind, label)) mag*cos(phase) else 0)`.
  - `Liveness`: `fn readsArgs(tag: SysFn.Tag) bool`, false for the noise family in the core roots. `noise.genBody` reads them.
- **Oracle**: `dyn.zig` gains an AC/noise comparison (T0b).
- **Zig mirror**: a second body over the same Air is `c.zig` `genLazyFn`/lazy functions (`c.zig:57`, `:2246`): extra functions emitted from the same unit.
- **Clears**: 24 + 8 = 32.

### R7, R3 (T13)
- **R7**:
  - `ops.zig` `Kind.idt_hold` with slot `off`.
  - Eval: `zIdtHold(S, in, inst.op<k>__off, ic, assert)`.
  - Accept: `if (assert != 0) off = in - ic`.
  - Old: `op_zig.zig:60-64`, `call_operator.zig:116-121`, `accept.zig:145`. Kernel: `lib/std/kernels/ops.zig:236`.
- **R3**:
  - Sema keeps `vera_interp` as a call flag. `src/Sema/op.zig` adds the 4th argument `quad: bool` to the absdelay call, and `ops/delay.zig` uses `zAbsdelayQ`/`zHistAtQ`.
  - The `$strobe`-operand case: `say.genBody` reads the op's committed value (`ops.value`), not a fresh evaluation.
- **Clears**: 6 + 4 (the 4th after T0's refresh).

### R10 random (T14)
- **Old**: per-call seed fields on the Instance, plus the commit/revert of the seed in `state.zig`.
- **New**:
  - New file `src/codegen/zig/random.zig`:
    - `pub const Site = struct { call: Air.Inst.Index, tag: SysFn.Tag, seed_slot: ?Air.Inst.Index }`
    - `genFields`
    - `genValue` maps each tag to `K.rng.<fn>` through a comptime `std.EnumArray(SysFn.Tag, ?[]const u8)`, so a missing row fails to compile.
    - `genCommit` and `genRevert`.
- **Zig mirror**: fact tables as `EnumArray`, as `BuiltinFn.list` is.
- **Clears**: 24.

### R8 strings (T15, T16)
- **Old**: `src/codegen/device/cg_strcap.zig` (rows of 4096 bytes, up to `1<<47`, `cap(g, v)`) and `cg_display.zig:223-290`.
- **New** (T15, values):
  - New file `src/codegen/zig/strings.zig` (≤500 lines).
  - A string value is `[]const u8`; a slot is `var sN: []const u8 = ""`.
  - A held string is the Instance/State field `K.str.ZStrHeldN(cap)`.
  - `str$cmp` → `std.mem.order`; `str$cat`/`str$repeat` → `zStrCat`/`zStrRepeat` into `zSRow(site, 0, cap)`.
  - `Function.real()`/`int()`: a `.str` constant is its big-endian byte value, up to 8 bytes (§2.7). This clears the 9 "not a number" lines.
  - `$simparam$str` → `@tagName(sim.kind)` (VD-118), or the host string.
  - `genModel`: a string parameter becomes `name: []const u8 = "<lit>"`.
  - `cap` lives in Sema: a `[]const u32` capacity per string slot, as `Air.Device.str_caps`, filled by a port of `cg_strcap.cap` in `src/Sema/string.zig`. Codegen reads it and does not size it.
- **New** (T16, formatting):
  - `$sformat`/`$swrite` → `zStringStore(zSFormatRt(row, fmt, scope, .{args}))` (`lib/std/kernels/printf.zig:58`).
  - `$sscanf` → `zScanN/I/R/S`.
  - `sformat_runtime_width_past_its_row_rejected` needs E1011 at run time.
- **Zig mirror**: a slice is `{ptr, len}` in `c.zig` `airSlice` (`:4024`); a buffer's size is a Sema type fact.
- **Clears**: T15 32 + 9 + 3 + 3 + 3 = 50; T16 28.

### R4 filters (T17)
- **Old**: plan/filter cascade (`laplace_*`, `zi_*`).
- **New**:
  - New file `src/codegen/zig/ops/filter.zig`. Each site is a cascade of state-space sections whose states are `op_state` nodes (`Node.Kind.op_state`) Sema mints.
  - The coefficients are interned in Sema. The E0540 rule checks run in Sema `src/Sema/op.zig` (moved by T23).
- **Clears**: 28.

### R13, R14, R15 contributions (T18, unblocks VPI G8/G9: flow contribution to a potential source's branch)
- **Old**:
  - `src/codegen/device/codegen/switch_row.zig` `emitSwitchRow`: `S.sel(flag, V(hi)-V(lo)-c, partner_flow_or_ib)`, ±ib in KCL, `flowIsMerged`, `Model.<flowu>__retained`, the guarded `jac_const` (`guardTerm`).
  - Indirect: `stamps.zig:133-152`.
- **New**:
  - Core returns each potential contribution's `wrote` flag.
  - `stamps.zig` `Term` gains `.switch: struct { pot: Contribution.Index, flow: ?Contribution.Index }`, with the partner found by `(hi, lo, branch)`.
  - A flow contribution to a potential source's branch is the `flow` arm. That is R13: the same row, with the partner unconditional.
  - Indirect: stamp ±x[u], and row u holds the contribution's resistive and reactive values.
  - Rendering the `S.sel` goes in a new file `src/codegen/zig/switch_row.zig`, so DeclGen gains one call.
- **Oracle**: `dyn.zig` rows, Jacobian and charges, plus a new finite-difference check on every row (spice-engine §5) in `dyn.zig`.
- **Clears**: 20 + 16 + 8 = 44.

### R16 path latch (T19)
- **Old**: `plan/core.zig:35-46`, `instance.zig:265-268`, `state_ctl.zig:110-111`: commit does `pb = wb; pq += wq; wq = 0`.
- **New**: new file `src/codegen/zig/paths.zig`, built like `ops.zig`. `Function.zig:569` calls it.
- **Clears**: 2.

### R11 systf (T20, unblocks VPI G8/G9: user systf calls) and `$simprobe` (T21)
- **systf**:
  - Old: `call_systf.zig`: `systf_calls = [_]contract.Systf{…}` with `.outs` and `.task`; `inst.systf.?.call(ctx, k, &zsv, &zsp)`; S rebuilt as `arg.addC(-v).scale(p)`; `$systf$out` through `zsh.output`.
  - New file `src/codegen/zig/systf.zig` over `Air.Device.systf`, which `src/Sema/syscall.zig:312-317` `userCall` already fills. `calls.zig:51` dispatches a callee > `max_tag` to it. `DeclGen` gains `Instance.systf: ?*const contract.SystfHost = null`.
  - Oracle: `dyn.zig` binds a deterministic stub `SystfHost` (T0b), which also clears W19.
- **`$simprobe`**:
  - Old: `src/analog/hier_name.zig:260-300` `lowerSimprobe`, and `resolveProbe` at about 440-465.
  - New file `src/Sema/simprobe.zig`: `pub fn lower(s: *Sema, call: Vir.Inst.Index) CompileError!Air.Inst.Ref`. It resolves over `Zcu.instances` (outputs, then params honouring `ps_hidden`, then variables), and is called before `userCall`. Errors: E0817, E0823.
- **Zig mirror**: an extern call is `c.zig:4052` `airCall` to an `@extern` (`zig:src/Sema.zig:25306` `zirBuiltinExtern`). A name resolved across the hierarchy is a Sema lookup.
- **Clears**: 9 + 3 (W19) + 7.

### vpi_contribs (T22, unblocks VPI G8/G9)
- **Old**:
  - `dispatch.zig:171,220-290` `emitVpiContribs`: `vpi_contrib_access/hi/lo/flow_u` and `pub fn vpiContribs(S, x, model, inst, sim) [n][2]f64`. Then `vpiShares`/`vpi_share_row` when instances share a row (`Lowered.contrib_shares`).
  - Set by `Options.vpi_contribs` (`codegen.zig:87`).
- **New**:
  - `src/codegen.zig` `Options` gains `vpi_contribs: bool = false`.
  - New file `src/codegen/zig/vpi.zig`: `pub fn genContribs(dg: *DeclGen, w: *Writer) Error!void`. It reads `core`'s per-contribution values as eval does.
  - `Air.Device` has no shares table: see Q6.
- **Oracle**: `sides.zig` builds both devices with `vpi_contribs`, and `dyn.zig` compares `vpiContribs` bit for bit per point.
- **Zig mirror**: a `Compilation.Config` flag that a backend reads (`zig:src/codegen/c.zig:2208` reads `zcu.comp.config.root_strip`).
- **Clears**: 0 (enables G8).

### C7, C8 diagnostics (T23)
- **C7**: `src/codegen.zig` `floatRoots` fills `Root.name` with the contribution's access text (`I(p,n)`), built from `Device.contributions` access, hi and lo and `nodes.name`, and fills `loc`.
- **C8**: these checks move out of codegen into Sema, so codegen keeps no diagnostic channel:
  - E0540 filter rules → `src/Sema/op.zig`, at the filter call.
  - E0527 "$limit seed reads the solution" → `src/Sema/kernel.zig:52-87`: walk the seed operand tree for `.probe`.
  - W0853 "$limit names no algorithm" → `kernel.zig`.
  - W0850 "`$monitor` dropped in a device" → Sema, reading the output kind from `Compilation` config (Zig's Sema reads `zcu.comp.config` the same way).
- **Zig mirror**: user diagnostics belong to Sema. Codegen only fails, through `codegenFail` (`zig:src/Zcu.zig:4847`, stored in `failed_codegen` `:194`) with an `ErrorMsg{src_loc, msg}` (`:1262`).
- **Clears**: comp 14.

### C5 `$monitor` (T24)
- **Old**: `cg_display.zig:123-170`, `zMonitor`/`zMonitorArm`, `inst.zm__[k]`, §9.4.1.
- **New**: `say.zig` `records` admits `$monitor` and records a site only when its values changed. The latch is the Instance field `zm__: [n_monitor]contract.MonitorLatch`.
- **Clears**: comp 2.

### R12 phase B: the `limit` hook (T25)
- **What**: emit `limit(S, *const Model, *const Instance, cur, old, SimState) LimitResult(n_u)` (contract `validate_entries.zig:148`), the masks (`masks.zig:91-101`), and the seed.
- **Where**: the facts that `plan/limit.zig` derives move into Sema (`Air.Device.limit_slots` gains them); the new file `src/codegen/zig/limit.zig` renders them.
- **Oracle**: `dyn.zig` calls `limit` on both devices with the same cur/old. Planted fault: invert pnjlim's sign.
- **Clears**: 0. This closes the hole phase A leaves.

---

## 3. Oracles and red-first

Every fix is held by diff-codegen against old `vera` (bit for bit, `-Dstrict`). Each task plants its fault first and shows it red under the gate in §5.

| task | planted fault (must go red first) | new oracle the class needs |
|---|---|---|
| T0a | swap the label back on `:545`, so a strict-only say difference reads "versioned" | a unit test in `tests/differential/codegen.zig` that feeds `compare()` a strict-only say difference and expects "new" |
| T0b | `revert` restores nothing (empty `genRevertPre`) on a transition fixture | rollback oracle: every 7th point is evaluated, `stateCtl(.revert)`, re-evaluated, and the rows must match. Breakpoint oracle: `nextBreakpoint`/`pendingBreakpoint`/bound_step compared per point. AC/noise oracle: `noisePsd`/`acStim` at 3 frequencies. Stub `SystfHost`. FD Jacobian check (spice-engine §5) |
| T0c | AstGen check: drop B2's `_ = …` line, and a limit-only device goes red | `src/codegen/test.zig` runs `std.zig.AstGen.generate` on every emitted test device; it fails on unused locals and parameters without a build |
| T1 | drop eval's zero-rows guard: `fatal.va` red | — |
| T2 | sign of the `.set` term: `flow_signal_flow.va` red | — |
| T3 | children keep the call: the 6 mfactor/geometry lines red | determinism: two instances that differ only in `$mfactor` must give two Airs (unit test in `src/Sema/test.zig`) |
| T4 | skip the install: `discrete_bus_31` red | — |
| T5 | reject `cond_br` again: `dependent_control_operators` red | — |
| T6 | `.none` → integer: `analog_function_keyword` red | — |
| T7 | ignore `signed`: the 3 fixtures red | metamorphic: `a < b` ≡ `!(a >= b)` over generated signed/unsigned literal pairs (`tests/generators.zig` row) |
| T8 | `declSize` 1 bit again: the wand fixture red | — |
| T10 | `analog$initial` constant 1: `analog_initial.va` red | — |
| T11 | `ac_stim` always active: the AC oracle red | — |
| T12 | drop the `sim.dt > 0` guard: a cross fixture red | breakpoint oracle (T0b) |
| T13 | `off = in` (ic dropped): `idt_assert_release_resumes.va` red | — |
| T14 | seed not committed: `random.va` red on the rollback oracle | — |
| T15/T16 | off-by-one in `str$cat` length | — |
| T17 | one section's sign flipped | — |
| T18 | drop −ib at lo; flip the `S.sel` arms | FD Jacobian (T0b) |
| T19 | `pq = wq` (no accumulate) | — |
| T20 | zero `zsp` (derivative dropped) | — |
| T22 | swap the resist/react halves | `vpiContribs` comparison (above) |
| T23 | empty `Root.name` | comp's stderr compare |
| T25 | invert pnjlim's sign | `limit` comparison |

---

## 4. Tasks

Each task is one Sonnet agent. "Lines" means `codegen.xfail` lines cleared, with comp in brackets. Waves run in order; tasks inside a wave run in parallel. A shared file is touched only at the one arm or call line named.

**Wave 0 (serial, blocks all)**

| # | task | files | deps | lines |
|---|---|---|---|---|
| T0a | Merge a8e9 (`4a358e61` + its uncommitted diff, committed as is). Label the say loop at `codegen.zig:545` (`sides: for`, `break :sides` at :549, :557). Accept `\|` in `codegen_filter` (`build/rewrite.zig:50` doc + the filter in `codegen.zig`). Rerun the whole list with `-Dcodegen-why` and rewrite every reason. Run the 6 C3 fixtures through `diff-comp`. | `tests/differential/codegen.zig`, `codegen.xfail` | — | 48 |
| T0b | `dyn.zig`: rollback oracle, breakpoint/bound_step compare, AC/noise compare, stub `SystfHost`, FD Jacobian | `tests/differential/codegen/dyn.zig`, `sides.zig` | T0a | 3 (W19 once T20 lands) |
| T0c | AstGen over every emitted test device | `src/codegen/test.zig` | — | 0 |

**Wave 1: wrong numbers**

| # | task | files | deps | lines |
|---|---|---|---|---|
| T1 | status latch | new `src/codegen/zig/status.zig`; `DeclGen.zig` (core locals, the entries' guard), `state.zig` (early return, clear); `src/Air/Device.zig` + the Sema site that appends `displays` (`file`, `line`) | T0a | 9 [+2] |
| T2 | flow-only nets | `src/Air/Device.zig` (`flow_only`), `src/Sema/contrib.zig`, `src/codegen/zig/stamps.zig` | T0a | 3 |
| T3 | per-instance folds and `Instance.given`/`Key` | `src/Sema/syscall.zig`, `src/Zcu.zig`, `src/Sema/{param,defparam,paramset}.zig` (fill `given`) | T0a | 11 |
| T4 | initial constants, array init, str→int | new `src/Sema/initial.zig`; `src/Sema/variable.zig`, `discrete.zig` | T0a | 14 |
| T5 | derivation through control flow, defparam re-derive, `$simparam` defaults | `src/Sema/derive.zig`; `src/codegen/zig/Function.zig` (`genTree`), `calls.zig` (`simparam` arm only) | T0a | 10 |
| T6 | function return type, nature attributes | `src/Sema/func.zig`, `src/Sema/hier.zig` | T0a | 5 |
| T7 | signedness | `src/Sema/expr.zig`, the `Sema.Value` definition | T0a | 3 |
| T8 | display widths (+W15 by Q1) | `src/Sema/format.zig` (+ `SysFn.zig:355` by Q1) | T0a | 9 (+8) |

**Wave 2: refusals, VPI first**

| # | task | files | deps | lines |
|---|---|---|---|---|
| T18 | **switch branches, flow on a potential branch, indirect (unblocks VPI G8/G9)** | `stamps.zig`, new `switch_row.zig`, `DeclGen.zig` (one call), `Function.zig` (`wrote` returned) | T2, T0b | 44 |
| T20 | **user systf calls, `device.systf` (unblocks VPI G8/G9)** | new `systf.zig`; `calls.zig:51`; `DeclGen.zig` (Instance field) | T0b | 12 |
| T10 | small arms | `calls.zig`, `state.zig`, `DeclGen.zig` (`genModel`, Instance fields) | T5 (calls.zig) | 66 |
| T12 | events | `ops.zig`, new `ops/events.zig`, `Liveness.zig` (`effect`), `DeclGen.zig` (breakpoint entries) | T0b | 88 |
| T21 | `$simprobe` | new `src/Sema/simprobe.zig`, `src/Sema/syscall.zig` (one call) | T3 | 7 |
| T23 | diagnostics into Sema, W0650 label | `src/codegen.zig` (`floatRoots`), `src/Sema/op.zig`, `src/Sema/kernel.zig`, `src/Sema/say` site for W0850 | T0a | 0 [+14] |
| T24 | `$monitor` | `say.zig` | T1 (say.zig `file`/`line`) | 0 [+2] |

**Wave 3**

| # | task | files | deps | lines |
|---|---|---|---|---|
| T11 | **noise and AC tables, `ac_stim` (unblocks VPI G8/G9)** | new `noise.zig`; `Liveness.zig` (`readsArgs`), `calls.zig` (two arms), `DeclGen.zig` (one call) | T10, T12 (Liveness.zig), T0b | 32 |
| T22 | **emitting `vpi_contribs` (unblocks VPI G8/G9)** | `src/codegen.zig` (`Options`), new `src/codegen/zig/vpi.zig`, `DeclGen.zig` (one call), `tests/differential/codegen/sides.zig` | T18 | 0 |
| T13 | `idt$hold` and absdelay leftovers | `ops.zig`, `ops/delay.zig`, `src/Sema/op.zig` (quad flag), `say.zig` | T12, T23 (op.zig), T24 (say.zig) | 10 |
| T14 | random | new `random.zig`; `calls.zig` (arms), `state.zig` (commit/revert lines) | T10 | 24 |
| T15 | string values | new `strings.zig`; `Function.zig` (`alloc`, `real`, `int`), `calls.zig` (arms), `DeclGen.zig` (`genModel` strings); `src/Air/Device.zig` + `src/Sema/string.zig` (`str_caps`) | T10, T5 | 50 |
| T19 | path latch | new `paths.zig`; `Function.zig:569`, `state.zig` | T1, T10 | 2 |

**Wave 4**

| # | task | files | deps | lines |
|---|---|---|---|---|
| T16 | string formatting | `strings.zig`, `calls.zig` (arms), `say.zig` (`%s`) | T15 | 28 |
| T17 | filters | new `ops/filter.zig`; `ops.zig`; `src/Sema/op.zig` (sections) | T13, T23 | 28 |
| T25 | `limit` hook | new `limit.zig`; `src/Air/Device.zig` (`limit_slots` facts), `src/Sema/kernel.zig`; `dyn.zig` | T10, T23 | 0 |

Totals:
- 27 tasks: T0a, T0b, T0c, T1–T8 and T10–T25 (there is no T9; its work is in T6).
- `codegen.xfail` 516 → 0, counting 5 ruling lines (W16–W18, Q2/Q3a/Q3b) and the 8 W15 lines (Q1). Without the rulings, the floor is 13.
- comp: C1 335 + C5 2 + C7/C8 14 + C9 2 = 353 of 488. C2's 69 lines are lowering's, C4/C6/C10 are not codegen, and C3 is unknown.

File budgets (code-style, ≤500 code lines):
- `Function.zig` is 646 lines total. T15 moves `real()`/`int()` string handling into `strings.zig`, so it does not grow there.
- `DeclGen.zig` is 508 lines. Every task adds at most one call line to it and keeps its family in its own file.
- Any file that reaches 500 code lines splits by family before the task ends.

---

## 5. Commands

Every gate is read by its exit code (`cmd > log 2>&1; echo $?`). Heavy corpus steps run through the slot script.

| task | fast gate | list gate | lists it may change |
|---|---|---|---|
| all | `nix develop -c zig build check test-codegen test-air test-sema -j4` (whichever modules it touches), `python3 tools/check_style.py <files>`, `zig fmt --check src tests` | — | — |
| T0a | as above | `~/.cache/vera-heavy.sh <wt> diff-codegen -Dcodegen-why -j4` (whole list, once); `~/.cache/vera-heavy.sh <wt> diff-comp -Dcomp-filter='spice_binned_model_selects_by_l_and_w\|vcvs_inside_a_spice_subcircuit\|alias_card_write_sets_original_given\|parameter_alias\|noise_table_file_name_parameter\|exhaustive/parameters'` | `codegen.xfail` (reasons and the 48) |
| T0b, T0c | `test-codegen` | `diff-codegen` whole list: no new line may appear except a reason a new oracle produced, and each such line goes to the owning task | `codegen.xfail` (new oracle lines only, each named in the commit) |
| T1–T25 | as above | `~/.cache/vera-heavy.sh <wt> diff-codegen -Dcodegen-filter='<the group's fixtures, \| separated>' -Dcodegen-why -j4`, then the whole `diff-codegen` (no XPASS, no new line); Sema tasks also `diff-sema` and `diff-lower` (no line moves) | `codegen.xfail` (remove its lines only); `.rulings` only after a user decision |
| T23, T24, C-lines | as above | `~/.cache/vera-heavy.sh <wt> diff-comp -Dcomp-filter='<fixtures>'` | none: report the comp lines to the lead |
| T22 | `test-codegen` | `diff-codegen` whole list (the `vpiContribs` comparison is part of it) | none |

`comp.xfail` is never edited by a task. Each task's report lists the comp lines it expects the lead to remove.

---

## 6. New tables: the six data questions

The six questions, answered per table: who writes it, who reads it, how many rows, the narrowest width, how long it lives, and whether it is hot or cold.

| table | writer | readers | count | width | lifetime | hot/cold |
|---|---|---|---|---|---|---|
| `Air.Device.Display.file/line` | Sema (append to `displays`) | codegen status/say | one per display task (≤ a few hundred) | `String` 4 B + `u32` | device | cold |
| `Air.Device.flow_only` | Sema contrib | codegen stamps | one bit per `nodes` row | 1 bit | device | cold |
| `Zcu.Instance.given` | Sema param/defparam/paramset | Sema syscall | one per instance | `InternPool.Index` 4 B (interned bool aggregate; `.none` at a root) | Zcu | cold |
| `Air.Device.str_caps` | Sema string | codegen strings | one per string slot | `u32` bytes (cap ≤ `1<<31`, assert; old allowed `1<<47`, see Q7) | device | cold |
| Instance `vera_status__`/`vera_status_args__` | emitted device | host | 1 per instance | `u32` + `[4]f64` | instance | hot (read per eval; one compare) |
| Instance `op<k>__prev/next/start/per`, `vera_cross_retry__` | emitted device | host via `nextBreakpoint` | per event site | `f64` | instance | hot |
| Instance `rng<k>__seed` | emitted device | itself | per random site | `i32` (§9.13 seed is an integer) | instance | hot |
| Instance `zm__[k]` | emitted device | itself | per `$monitor` site | `contract.MonitorLatch` | instance | warm |

Each emitted Instance/State struct keeps the existing `comptime assert(@sizeOf(...) == …)` the device writes for its hot structs. A new field updates that assert.

---

## 7. Where each skill bites

- **data-oriented-design**: the six questions are answered in §6. Facts are tables in `Air.Device`/`Zcu`, filled once by Sema. Handles are typed `enum(u32)` with a sentinel (`Contribution.Index`, `Node.Index`). Existence is expressed by tables (`flow_only`), not flags on a struct.
- **codebase-clean-code**: `Compilation` → `Sema` → `Air`/`Air.Device` → `codegen` → `link`. One owner per table, and codegen appends nothing to Air. Each family is one file; the shared spine files gain one line each.
- **api-design**: `codegen.generate(gpa, .zig, in, .{ .vpi_contribs = true })` is the caller's line, written first. The caller owns memory; `Result` keeps its `deinit`. No callbacks: `SystfHost` is the host's request table, as the contract already defines it.
- **code-style**: file order, Contents, separator, ≤500 code lines (see the §4 budgets), `check_style.py` clean on every touched file.
- **doc-comments**: every new file opens with `//!` in → out plus clauses. Every `pub` item names its fact: the arg cap 4, the `str_caps` bound, the instance key.
- **assertions**: at least two paired assertions per new function. Examples: `status.plan` asserts that each site's args ≤ `arg_max` and the site count fits `u32`; `events.genValue` asserts the site's kind; every loop over sites is bounded by its table length.
- **compiler-construction**: refusals keep their clause (`§5.6.7 …`) until removed. Fact tables are `EnumArray` (random, events), with no `else =>` over `SysFn.Tag` unless it carries a reason. User diagnostics move to Sema (C8).
- **test-plan / tdd**: the oracle is named per task (§3) before code, and every task plants a red-first fault. A new oracle (T0b/T0c) covers each class the lists showed with no oracle.
- **zig**: no `std.meta.Int`, `@backingInt`/`@fromBackingInt` for handles, `.empty` decl literals, `@splat` for arrays.
- **spice-engine**: FD Jacobian on switch rows. Breakpoints land exactly (`nextBreakpoint`). Tolerances stay bit for bit (`-Dstrict`).
- **simd-loops**: not applicable. The compiler stays scalar (compiler-construction rule 8), and the emitted device's lanes are untouched.
- **ponytail**: T10's `$limit` phase A is a one-line identity, and its ceiling is named. B2 is one line. T25 lands later, held by its own oracle.
- **writing-perfect-verilog**: W14's widths follow IEEE 1364 §17.1.1.3.

---

## 8. Departures from Zig

| where | Zig | here | why |
|---|---|---|---|
| `Air.Device` tables (contributions, nodes, noise, systf, displays, new `flow_only`, `str_caps`) | codegen reads `Air` + `InternPool` only | codegen also reads `Air.Device` | a device's §5.6 topology has no Zig analogue; the tables are Sema's output beside Air, never written by codegen |
| per-call-site operator state (`ops.zig`, events, random, paths, monitor) | function state lives in locals and stack frames | Instance/State fields and commit/revert entries | §4.5 operators and §9.13 seeds outlive one evaluation, and the host owns acceptance (`stateCtl`) |
| status latch | `@panic` traps (`c.zig:4620`) | a latch the host reads | a device cannot stop its host (contract `StatusSite`) |
| W0650/W0850/W0853 warnings | Zig has no warnings | Sema emits coded warnings | the diag catalogue is VerA's; codegen still emits none |
| second bodies (`say`, `noisePsd`) | lazy functions emitted beside a function | a second walk of the same Air in another entry | the host calls them at different times (accepted point, AC sweep) |

---

## 9. Risks

1. **Stale reasons hide moves.** A fix can clear one fixture's first difference and expose the next, so the line stays listed with a new reason. T0a's refresh and `-Dcodegen-why` on every gate cover this.
2. **Green without an oracle.**
   - B1/R5 noise and R12 phase A can clear while noise and the limit hook are untested.
   - T0b (AC/noise) must land before T11 removes its lines.
   - R12 phase A's lines may come out early only with Q4's yes.
3. **`Instance.Key` change (T3).** Adding `hier`/`given` splits analyses that were shared. Compile time can rise on arrays of instances; measure the `exhaustive/` bench before and after.
4. **Shared spine files.** `calls.zig`, `DeclGen.zig` and `Function.zig` are touched by many tasks. The waves serialize the heavy edits, and the rest are one-line arms that merge without conflict.
5. **W10 widens.** `Sema.Value` gains signedness and width, which every integer fold reads. `diff-sema` must stay unmoved.

---

## 10. Open questions

**Q1. `analysis()`'s display width (W15, 8 lines).**
- Old types `analysis()` real (callee_table:138), so VD-120 prints it at 20 columns. New types it `int` and prints 11 columns.
- VAMS §4.6.1 says only that it "returns one (1)".
- Recommendation: new is right. It is an integer like `$param_given`. Add 8 `.rulings` lines and a VD entry, rather than make it real.
- Decision: Match old (real). Revised at step 0: rw-lower2's 0474ded2, now merged, types it real as the old callee table does. §4.6.1 says it returns one and names no type, so the old side is not wrong and a ruling cannot cite it. No `.rulings` lines.

**Q2. `abs(+0)` (W16, 2 lines).**
- VAMS Table 4-14 gives C `fabs` (+0), but its text gives `(x > 0) ? x : -x` (−0).
- Recommendation: follow the table. Switch the new fold `lib/std/kernels/fold.zig:360-362` and `F.zAbs` (`lib/std/kernels/family.zig:53`) to `@abs`.
- Decision: `@abs` (+0): Table 4-14 names C `fabs`; the text's ternary is illustrative. The fold and `F.zAbs` change in one commit; diff-codegen proves it bit for bit.

**Q3a. `fmod` of a negative dividend with a zero remainder (W17, 1 line: `hypot_fmod_extreme_magnitude`).**
- Old `src/codegen/device/codegen/kernel_text/math.zig:298-306` `zFmod` adds a +0 graft to `@rem`, turning −0 into +0. New gives −0, which is what C `fmod` returns (VAMS Table 4-14 names C `fmod`).
- Recommendation: new is right. Add a `.rulings` line (or fix the old graft).
- Decision: New is right (C `fmod`, Table 4-14): a `.rulings` line. The old side is not edited.

**Q3b. Folded `cosh(-1.0)` is 1 ulp apart (W18, 2 lines: `ch04/cosh.va`, `exhaustive/hyperbolic.va`).**
- Old `lib/kernels/fold.zig:382` uses `std.math.cosh` (1.543080634815244). New `lib/std/kernels/fold.zig:386` uses Gompute's correctly rounded `cosh` (1.5430806348152437), which equals the fixture's own expected value (VAMS Table 4-15).
- Recommendation: new is right. Add `.rulings` lines, and widen the oracle's `libm_kernels` bound to the hyperbolic family and the folds.
- Decision: New is right (correctly rounded, equals the fixture's expected value): `.rulings` lines, and widen `libm_kernels` to the hyperbolic family and the folds, since a tolerance follows the oracle's own accuracy and `std.math.cosh` is not a 0-ulp oracle.

**Q4. Remove lines that clear before their oracle exists?** (B1 noise, R12 phase A)
- Recommendation: no. B1 waits for T0b's AC/noise compare. R12 phase A lines come out now, with T25 tracked as a task, because eval is bit-identical to old.
- Decision: No: a line leaves its list only when an oracle can see the fix. B1 waits for T0b; R12 phase A comes out now, T25 tracked.

**Q5. The comp judge's `dropped()` misattributes 49 Sema note/help lines to `rw-codegen`.**
- Recommendation: skip lines starting `   = note:`/`   = help:` in `tests/differential/comp/judge.zig` `dropped()`, then re-own them. This is lead-owned.
- Decision: Yes, by the lead, in the same judge commit as airpasses J0-J3.

**Q6. `vpiShares` (§5.4.1 rows shared by instances).**
- The new `Air.Device` has no shares table, because Sema flattens instances.
- Recommendation: emit only `vpiContribs` now. Add `Air.Device.contrib_shares` when a G8 fixture needs it; the vpi plan's G8 list names none.
- Decision: Emit `vpiContribs` only. `Air.Device.contrib_shares` arrives with the first fixture that needs it (factor at the second real instance). Agrees with vpi Q2.

**Q7. String capacity.**
- Old allows rows up to `1<<47` bytes. Recommendation: cap at `u32` with E1011 past it, so the field is 4 B.
- Decision: `u32` with E1011 (a `limit-` code under diagcodes). A 4 GiB string is no design, so the cap refuses nothing real; lean storage wins. Contrast lower Q8.

**Q8. C3: the 6 comp fixtures with no known cause.**
- Recommendation: T0a runs them once and routes each to its owner.
- Decision: Yes: T0a runs them once and routes each to its owner.
