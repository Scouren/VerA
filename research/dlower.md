# Plan: Sema digital lowering and the std_sim run (owner `rw-dlower`)

Planner: plan-dlower. Base: `refactor` 90e93007. Read-only research, no builds run (every count below is from the lists and the source, not measured).
Spec: docs/rewrite/dlower.md, sim.md. Old side (oracle, read-only): `lib/sim/digital/`. New side: `src/Sema/digital*`, `lib/std/sim/`.
Zig mirror source: `Z/` = `~/.cache/zig-src-d924f83bf/` (checked: `git log -1` = d924f83bf3), `S/` = `/nix/store/spqy6l91i77g18ndfbaq441khlr8zd5f-zig-0.18.0-dev.349+d924f83bf/lib/std/`.

Revision 2 (the binding Zig-structure rule): sites are a debug-info line table keyed by pc (Air `dbg_stmt` → DWARF), the W1199 instance path is interned at Sema time (InternPool `fqn`), and three old-shape artefacts (a run-stage name error, a machine-sized stack message, a budget error at token 0) are rulings instead of being copied into the new code.

## 0. Starting state (read from the worktrees)

| worktree | state | content |
|---|---|---|
| `agent-a37de88a540af66c7` | merged into refactor (26bc9fb3 is an ancestor) | nothing to do |
| `agent-a34fe4095a0d4d67d` | HEAD = fcfc2a35, unmerged, no uncommitted src | duplicate of the next row; delete after T0 |
| `agent-aa4cb6011fbcec340` (rw-dlower3) | fcfc2a35 (unmerged) + merge of refactor (15298382) + **uncommitted** + untracked `src/Sema/digital/timescale.zig` | the starting point; T0 lands it |

fcfc2a35: uwire two drivers per bit (§4.6.6), a gate array identifier used twice (§7.1.5), a real variable connected to a port (§12.3.7). sim.xfail −3.

Uncommitted work (read in full; T0 keeps it unless noted):

| file | change | clears |
|---|---|---|
| `src/Sema/walk.zig:543` | W0252 only `if (!s.config.ieee1364)` | G1 |
| `src/Sema/digital/constness.zig` (+104) | `constantCalls`: §10.4.5, every call in a parameter's value judged a constant function (`notConstant`; `gather` capped at `depth_max = 4096`) | constant_function_hierarchical |
| `src/Sema/digital/vars.zig:486` | `lateParam` calls `constantCalls` | ″ |
| `src/Sema/digital/place.zig` | `partBound`: part-select bounds folded by `eval.v1364.value` (x/z and >i64 rejected) | native_wide_index_bound_limit |
| `src/Sema/digital/ports.zig:365` | VAMS §6.5.7.1 port/net size mismatch rejected unless `options.std_1364` | port_width_mismatch_vams |
| `src/Sema/digital.zig` | `Options.std_1364`; `ScopeInfo.implicit`; time scales moved to `digital/timescale.zig` (untracked) with §19.8 "`timescale inside a module" | timescale_inside_module |
| `src/Sema/digital/decl.zig:409`, `hier.zig:106` | an unnamed generate block (`genblk<n>`) is unreachable by a hierarchical name | unnamed_block_referenced |
| `src/Sema/digital/sub.zig` | `callee(.., enabling)`: an undeclared (`str_ref`) task name rejected "undeclared task `…`" | escaped_system_task (byte agrees, quote wrong: G6) |
| `src/Sema/digital/sysfn.zig` | `vams_digital_unrun`: VAMS §9.2 digital-context functions refused E0829 | vams_digital_temperature_refused |
| `src/Sema/digital/vcd.zig` | §18.3.1 a duplicate `$dumpports` scope; a variable as scope | dumpports_duplicate_scope, dumpports_variable_scope |
| `src/Zcu.zig` | `Rule.code()` (one table, read by `legacy.zig` and `sim.zig`) | – |
| `src/next/Compilation/backend.zig:228`, `legacy.zig` | pass `std_1364`; `rule()` uses `r.code()` | – |
| `tests/differential/sim.zig` | (a) `compileNew` reads `rule.code()` and passes `std_1364`: **kept**. (b) `rejects()` + `options(.., refused)`: the harness's own map reader (`frontend.libmap.load`, the old one) refuses and the fixture's `//! reject` grades it: **dropped by T0**. The new side refuses nothing there, so the line would pass by construction (it grades the old reader, not vera-next); reading a map is `Compilation`'s input (Z/src/Compilation.zig: the only stage that reads files), not Sema's or std_sim's | (b) would hide the 7 libmap lines; they are G14 |

sim.xfail after T0 (the worktree without hunk (b)): 26 → 15: the 8 the worktree names (attribute_value_is_constant, escaped_system_task (new reason), defparam_absolute…, defparam_across…, cell_not_in_its_library, design_cell_missing, design_names_config, scaled_delay_udp) plus the 7 G14 libmap lines.

## 1. Root causes

Totals: sim 26, comp 112 rw-dlower + 3 `not built: backend digital_lowering` = 115, digital_exe 112, digital_device 23, rtlil 2 = 278. "wt" = cleared by the worktree.

| G | root cause | sim | comp | exe | dev | rtlil | examples | fix |
|---|---|---|---|---|---|---|---|---|
| G1 | W0252 "gate primitive … computes nothing" raised on the 1364 route, where the UDP runs | – | 31 | 31 | 6 | – | 08_udp/udp_dff.v, 08_udp/combinational_reg_rejected.v | T0 (wt) |
| G2 | rejections the lowering missed (old exit 1, new 0), built in wt | 11 | 9 + 3 not built | 9 | 9 | – | type_uwire_multiple_drivers_rejected.v, timescale_inside_module_rejected.v | T0 (wt) |
| G3 | the run's warnings have no code and no site, other words, and `exe.report` drops them (`State.warnings: [][]const u8`, never rendered) | – | 36 | 36 | – | – | 17_system_tasks/readmem_warn_empty.v (W1150), readmem_malformed_hex_digit_load_terminated.v (W1157) | T2, T3 |
| G4 | W1199 is one fixed sentence: no check kind, instance path or times (`lib/std/sim/exe.zig:63`) | – | 21 | 21 | – | – | 15_timing_checks/setup.v | T2, T3 |
| G5 | a run-time E1100 has no location (`exe.report` passes `.none`) | – | 2 | 2 | – | – | 18_vcd/dumpports_same_file_rejected.v (28:19), dumpvars_later_time_rejected.v (11:8) | T2, T3 |
| G6 | lowering/run message or code differs | 1 | 1 | 1 | – | – | sdf_annotate_rejected.v (E1102 vs E1100); escaped_system_task_rejected.v (sim: quote `\$display`) | T0 (quote), T2 (code) |
| G7 | §13.3.1.1 a config `design` cell no library holds is accepted (`src/Sema/library.zig:80` and `src/Sema.zig:438` `configRoots`, both `orelse continue`) | 3 | 2 | 2 | 2 | – | design_cell_missing_rejected.v, design_names_config_rejected.v, cell_not_in_its_library_rejected.v | T4 |
| G8 | §3.8 a non-constant attribute value: Vir drops a module item's attribute spec (`Inst.Process` has no `attrs`) | 1 | 1 | 1 | 1 | – | attribute_value_is_constant_rejected.v | T5 (needs frontend) |
| G9 | **ruling**: old `$stop` line names byte 107, which is `spende` inside a comment; `$stop` is at byte 797, as the new side says | – | 1 | 1 | – | – | 17_system_tasks/stop_suspends.v | lead (comp.rulings) |
| G10 | **ruling**: old `--emit-rtlil` writes `autoidx 1` for a design it rejects (§12.1.1 no top, §12.1 self-instantiation) | – | – | – | – | 2 | no_top_level_module_rejected.v, self_instantiation_rejected.v | T6 |
| G11 | **ruling**: pinless top under old `--check` (lib/sim/rt/device.zig indexes an empty `spec.pins`), the class digital_device.rulings rules 680 times | – | – | – | 2 | – | B_keywords/b_B_keywords.v, dumpports_same_file_rejected.v | T6 |
| G12 | **plan-frontend** (routed, not planned): defparam in a generate block / array element (§12.2.1), a scaled literal in a UDP delay (E0247 byte) | 3 | 3 | 3 | 3 | – | defparam_absolute…, defparam_relative…, scaled_delay_udp_rejected.v | – |
| G14 | **blocked on libmap T2, then ruling** (plan-libmap Q5): a library-map or `-L` refusal (E0244) is a `Compilation` input refusal, before Sema and std_sim; diff-sim drives Sema directly and has no map input. sim.xfail lines: config_in_map_rejected, library_without_path_rejected, source_text_in_map_rejected, two_libraries_match_rejected, undeclared_library_rejected, b_A_1_1_include_without_path_rejected, b_A_1_1_include_without_semicolon_rejected | 7 | – | – | – | – | 13_configuration/config_in_map_rejected.v | once libmap T2 lands and diff-comp grades them end to end, T6b moves them to `sim.rulings`: "IEEE 1364-2005 §13.2: a library map is a Compilation input, outside std_sim's contract; diff-comp grades it" |
| G13 | **ruling**: old shape, not old truth. (a) forward_reference_reg: the old resolves names lazily while running (lib/sim/digital/name_search.zig:208), so a §4.11 use-before-declaration reaches stderr as a run failure with no compile summary; the new finds it while lowering, a compile error with the summary, as Zig reports every name error (Z/src/Sema.zig:2671 `fail`). (b) recursion_without_end: the old names its own reservation, a sixteenth of physical memory (1987 MiB here, lib/base/deep_stack.zig:314); the new names its own. (c) forever_without_timing, zero_delay_always, zero_delay_loop: the old blames token 0, the first token of the file (run_until.zig:95, exec.zig:446 `fail(0, …)`), which names nothing; the new blames the looping statement | – | 5 | 5 | – | – | forward_reference_reg_rejected.v, recursion_without_end_rejected.v, zero_delay_loop_rejected.v | lead (comp.rulings) + T2/T3 make the new side's words and site right |

Bookkeeping: sim 26 = G2 11 + G6 1 + G7 3 + G8 1 + G12 3 + G14 7. comp "digital lowering" 55 = G1 31 + G2 9 + G5 2 + G6 1 + G7 2 + G8 1 + G9 1 + G12 3 + G13 5; comp "run" 57 = G3 36 + G4 21; comp "not built" 3 ∈ G2. digital_exe 112 = the same groups (G1 31, G2 9, G3 36, G4 21, G5 2, G6 1, G7 2, G8 1, G9 1, G12 3, G13 5). digital_device 23 = G1 6 + G2 9 + G7 2 + G8 1 + G11 2 + G12 3. The 22 exe lines whose old first line is no `note:` (G1 6, G2 9, G5 1, G7 2, G8 1, G12 3) clear; the other 90 (old line 1 is a native-build `note:`) become `digital_exe (build remarks)` lines once the `--run` twin agrees: re-owned to the lead's 707-line decision.

Expected after T0-T6 (G8 and G12 waiting on frontend): sim 26 → 4 = 26 − 11 (T0, G2) − 1 (T0, G6 quote) − 3 (T4, G7; diff-sim's harness already feeds the map's placement, so cell_not_in_its_library clears in sim with T4 alone) − 7 (T6b, G14 rulings, only after libmap T2) = G8 1 + G12 3. Before libmap T2 lands: 26 → 11; comp 115 → 4 + 6 rulings (G9, G13); digital_device 23 → 4; rtlil 2 → 0 (rulings); digital_exe: 18 cleared, 90 re-owned, 4 waiting.

## 2. Fixes, each with its Zig mirror

### G1 W0252 on the 1364 route (wt)
- Old: lib/sim/digital runs the UDP and raises nothing; src/elab/walk.zig:344 raises W0252 on the analog route only.
- New: `src/Sema/walk.zig:543` (wt). Zig mirror: Sema reports by the compilation's config, one elaborator for both routes (Z/src/Sema.zig:2671 `fail`, reading `block.ownerModule()` options as at Z/src/Sema.zig:5847).
- Missing in wt: a red-first test in `src/Sema/test.zig` beside :466 with `.ieee1364 = true`, expecting `&.{ .E0247 }`. Plant: drop the guard.

### G2 the worktree's rejections (wt)
- Old sites: elab_drivers (uwire), elab_declare (split array), elab_warnings/ports, constness.zig:79, name_search, evcd.zig:160-235, elab_stages.
- New: §0. Zig mirror: compile errors raised by Sema at the offending instruction (Z/src/Sema.zig:2641 `errMsg`, :2671 `fail`). Missing: one `src/Sema/digital_test.zig` test per rule (`lower` → `Rejected`, `Why.code`/`.text`), red when its `reject` is deleted.

### G3 G4 G5 G6(code): coded run diagnostics over a pc line table (T2 runtime, T3 Sema)

Zig mirror, the whole design:
- Sema emits `dbg_stmt` per statement (Z/src/Sema.zig:5846 `zirDbgStmt`; Z/src/Air.zig:542, :1323 line/column); codegen turns them into a line table keyed by pc (Z/src/codegen/x86_64/CodeGen.zig:87823), which link writes as DWARF, apart from the code (Z/src/link/Dwarf.zig:4660). At run time a failure knows only its pc; `std.debug` resolves pc → file:line:column when it reports (S/debug/Dwarf.zig:1297 `getLineNumberInfo`, S/debug.zig:1283 `printLineInfo`).
- A runtime failure is a fixed panic id with runtime arguments (Z/src/Zcu.zig:496 `panic.*`, S/debug.zig:116 `outOfBounds(index, len)`).
- Names in messages are interned once at analysis (Z/src/InternPool.zig:3213 `fqn`, Z/src/Zcu.zig:942 `internFullyQualifiedName`), never walked at run time.
- The driver collects every diagnostic into one bundle and renders it once (Z/src/Compilation.zig:3829 `getAllErrorsAlloc`, S/zig/ErrorBundle.zig:473, :178).

So:

| new piece | mirrors |
|---|---|
| `Lowered.pc_sites: []const u32`: per `Program.insts` row, the pp byte its diagnostics blame (`none` where none can fire). Kept out of `Program`, like DWARF out of `.text`; the exe gets it as `Config.pc_sites` (`[]const Diag.Loc`, relocated by the driver) | Air `dbg_stmt` → line table → DWARF |
| `Lowered.check_sites` (exists: per `Program.checks` row) | – (checks are not instructions; same table shape) |
| `State.diags: std.ArrayList(Diag)`, `Diag = struct { code: vams.Diag.Code, pc: u32, text: []const u8 }`; `State.failure: ?Diag` | a panic id + its args + the return address |
| `State.pc: u32`, written by `Interp.step` before each instruction dispatches; `warn`/`fail` record it | the return address a panic reads |
| `Program.Check.name: List`: `` `$setup` in b_15_2_1_setup.u`` written by Sema (path from `Zcu.PathFormatter`, the one hierarchy, Z mirror `fqn`) | InternPool `fqn` |
| `exe.report` drains `diags` then `failure` into the `Wip`, resolving `pc` through `pc_sites` (checks through `check_sites`) | `getAllErrorsAlloc` + `printLineInfo` |

Six data questions:
1. `pc_sites`: in Sema's offsets; out Locs. Count = `insts.len` (one u32 each; cold, read only on report). Width u32 byte, `none` sentinel. Written once by Sema (the builder appends one per `insts` append: `Builder` gets `site: u32` set by Sema before each statement, mirror `zirDbgStmt` setting the current line). Lifetime: compilation arena / the exe's constant data. Not parallel.
2. `State.diags`: AoS (every field read together, once). Bound `diags_max: u32 = 1 << 16`; past it `warn` counts `diags_dropped` and stores nothing (the Wip caps rendering anyway). Lifetime: the run arena.
3. `State.pc`: one u32 store per dispatched instruction in `Interp.step`'s loop. Hot path: T2 measures `zig build bench-run` before/after (AGENTS.md: a speed claim cites a benchmark; the expected cost is noise next to `eval`).
4. `Check.name`: one string per check, in `string_bytes`; `serial.zig` carries it if it reflects fields (check; else add).

Blame token per instruction (Sema chooses it, as Zig's `dbg_stmt` carries a column): the statement's main token, except where the old's diagnostic points at an argument:

| instruction | blame (old site) | old text to copy verbatim |
|---|---|---|
| `$readmemb/h` | arg 0 main token (lib/sim/digital/readmem.zig:381) | W1150 `mismatch_text` (:306), W1156 `outside_text` (:309), W1157 `not_a_name`/`cannot_read`/`unknown_bound`/`outside_memory`/`MemLoad.out_of_range_text`/`MemLoad.message(e)` each `++ load_ended` (:290-335, :403-430, :508-516) |
| `$fdisplay` & co. | arg 0 (descriptor) (files.zig:413) | W1154 `unwritten` (files.zig:69, the new text already equal) |
| `$sformat`/`$swrite` | the format argument (display.zig:485) | W1153 `sformat_mismatch` (display.zig:251) |
| an expression holding `$dist_*` | the call token (system.zig:251); the enclosing instruction's pc is the blame, so Sema blames the first `$dist_*` call in the statement when there is one | W1151 `dist_warning` (system.zig:155) |
| `$dumpports` | the file-name argument (evcd.zig:231, 28:19) | E1100 as today |
| `$dumpvars` & co. | the task name token (vcd.zig:441-554, 11:8) | ″ |
| `$sdf_annotate` | the task token | E1102 for every `failWith(.E1102, …)` of lib/sim/digital/sdf.zig:113-209; W1105 `"{file}:{line}: " ++ …` (sdf.zig:71; new sdf.zig:44 already prefixes) |
| a user call | the call token | E1100 `nesting here exhausts the {d} MiB stack VerA reserved for it` with `{d}` = the new run thread's stack (`exe.stack_size >> 20`, 1024): the words the fixture's `//! reject` pins, the number the new side's own (G13b) |
| any other instruction | the statement main token | – |

The two budget failures (`Interp.zig:75`, `:383`) record the pc dispatched last: the looping statement (G13c).

W1199: at a check's first violation (`count == 0` before `+|= 1`, lib/std/sim/tchk.zig:314), `warn(.W1199, …)` with text `"{s}: timestamp event at {d}, timecheck event at {d}"` over `Check.name` and `realAt(stamp)`, `realAt(check)` of `p.times[p.scopes[c.scope].time].scale` (old: lib/sim/digital/tchk.zig:599-617, `{d}` of the f64). Its Diag carries `pc = none` and the check index in a second field, or (simpler) `Diag.site_kind: enum(u1) { pc, check }`: pick `Diag = struct { code, at: u32, of: enum(u8) { pc, check }, text }`.

Signatures:
```zig
// lib/std/sim/State.zig
pub const Diag = struct { code: vams.Diag.Code, at: u32, of: Of, text: []const u8, pub const Of = enum(u8) { pc, check } };
pub const diags_max: u32 = 1 << 16;
pub fn fail(s: *State, code: vams.Diag.Code, comptime f: []const u8, args: anytype) Error; // records s.pc; asserts an E-code, failure == null
pub fn warn(s: *State, code: vams.Diag.Code, comptime f: []const u8, args: anytype) Error!void; // records s.pc; asserts a W-code
pub fn warnCheck(s: *State, i: u32, comptime f: []const u8, args: anytype) Error!void; // W1199 at check i; asserts i < checks.len
// lib/std/sim/exe.zig
pub const Config = struct { program, sources, pc_sites: []const Diag.Loc, check_sites: []const Diag.Loc, budget };
pub fn report(s: *const State, result: State.Error!void, wip: *Diag.Wip, pc_sites: []const Diag.Loc, check_sites: []const Diag.Loc) error{ OutOfMemory, WriteFailed }!void;
// asserts pc_sites.len == s.p.insts.len and check_sites.len == s.p.checks.len (the pair of Sema's appends)
```
Callers: 34 `s.fail(` gain a code (E1100 except sdf's E1102); ~30 `s.warn(` gain a code and the old words (`readmem.zig`, `display.zig:265`, `eval.zig:457`, `files.zig:106`, `sdf.zig:44`); `tchk.zig:314` → `warnCheck`. `backend.zig:checkSites` → `runSites` returning both tables; `codegen/digital_next.writeExe` passes both (one-line signature change in plan-codegen's file: coordinate, or keep the one-slice parameter as `pc_sites ++ check_sites` with a split index; prefer the two slices).

### G6 escaped task quote (T0)
- Old quotes the identifier as written, `\$display` (§3.7.1). wt `sub.zig:callee` slices `pp.text[why_at..]`. Fix: the quote is the call's callee token text from the Ast (`tree.tokenSlice`), byte unchanged. Zig mirror: messages quote source by token (Z/src/Sema.zig:12919 quotes the operand as written).

### G7 config design cell (T4)
- Old: lib/sim/digital/bind.zig:215 `designCell` → :199-201 "undeclared module in instantiation: library `{lib}` holds no cell `{cell}`" at the config token; a config is no cell.
- New: `src/Sema/library.zig:80` `orelse continue` → `s.failRule(.{ .rule = .design_cell, .name = "library `L` holds no cell `C`" }, .E0904, cfg.decl.file, <the config decl's inst, as :163>, "`{s}`", …)`; `designCell` (:266) returns null when the decl found is not a module. `src/Zcu.zig` `Rule.design_cell`; `legacy.zig:rule` prong `"undeclared module in instantiation: {s}"`; `Rule.code()` maps it to E1100 by its `else`. Analog route keeps E0904 (paramset.zig:149).
- Zig mirror: a root the build names that no module provides is a compile error at its reference (Z/src/Zcu/PerThread.zig:2483 `error.ModuleNotFound` → Z/src/Sema.zig:12919 `fail` "no module named …").

### G8 attribute values (T5, blocked on frontend)
- Old: lib/sim/digital/constness.zig:69 `checkAttributes` over every attribute spec of the module, in each instance, not in a mixed run.
- Needs (plan-frontend, AstGen): `Inst.Process` gains `attrs: List(Attr) = .empty` (`decl.prefixAttrs(ag, scope, main_token)` for `initial`/`always`). Zig mirror: Zir keeps a declaration's attribute bodies on the declaration (S/zig/Zir.zig:2719-2729 `align_body`, `linksection_body`), never dropping what Sema must judge.
- T5: `src/Sema/digital/decl.zig` (module items) runs `constness.offender(l, vir, value, true)` on every `attrs` list Vir holds; non-null → `l.reject(f, ref, "§3.8: an attribute value must be a constant expression")`; skipped when `options.mixed`.

### Rulings (G9 G10 G11 G13)
| list | fixture | clause and why | tiebreak |
|---|---|---|---|
| comp.rulings (lead) | 17_system_tasks/stop_suspends.v | IEEE 1364-2005 §17.4.2 (VD-070 text): old byte 107 is inside a comment; `$stop` is at 797 | gold stdout |
| comp.rulings (lead) | 03_lexical_conventions/forward_reference_reg_rejected.v | IEEE 1364-2005 §4.11: a use before declaration is a compile error; the old reports it as a run failure only because it binds names while running | reject status |
| comp.rulings (lead) | 10_tasks_functions/recursion_without_end_rejected.v | §10.4.1: the old's MiB is a sixteenth of the machine's memory; each side names its own reservation (the fixture pins the words, not the number) | reject status |
| comp.rulings (lead) | 09_behavioral_modeling/forever_without_timing_rejected.v, zero_delay_always_rejected.v, 11_scheduling/zero_delay_loop_rejected.v | §9.6/§11.4: the old blames the file's first token; the new blames the looping statement | reject status |
| rtlil.rulings (T6) | 12_hierarchy/no_top_level_module_rejected.v, self_instantiation_rejected.v | §12.1.1, §12.1: a rejected design has no RTLIL; the old writes `autoidx 1` | reject status |
| digital_device.rulings (T6) | B_keywords/b_B_keywords.v, 18_vcd/dumpports_same_file_rejected.v | the file's VAMS-2023 §7.8 pinless-top text | device builds and matches `--run` (a reject fails too). If dumpports_same_file's does not hold, the device path skips §18.3.1: report to plan-codegen, keep the line |

## 3. Oracles and red-first

| fix | oracle | planted fault | class oracle |
|---|---|---|---|
| G1 | diff-comp, diff-digital-device; `src/Sema/test.zig` | drop the `ieee1364` guard | T1(b): diff-sim compares the 1364 route's elaboration warnings (zcu.failed W rows, code + byte) with the old bag's `.lower` warnings: the hole W0252 came through |
| G2 | diff-sim | delete each `reject` | – |
| G3-G6 | diff-sim's run-diagnostic comparison | red today on 59+ fixtures; after T2/T3 plant `report` skipping `diags` | **T1(a)**: diff-sim compares every run diagnostic `(code, byte, text)` in order, old bag vs new `diags` + `failure` resolved through `pc_sites`/`check_sites`. diff-sim compared stdout, the failed flag and W1199 sites only, so wrong or missing stderr text passed: the bug class of G3-G6 |
| G13 | comp.rulings tiebreaks; for diff-sim, T1 adds `sim.rulings` (path + clause; holds when the new side fails with the same code and the fixture is `//! reject`) | – | – |
| G7 | diff-sim (3); `src/Sema/test.zig` `.ieee1364 = true` expecting E0904 + `Rule.design_cell` | restore `orelse continue` | – |
| G8 | diff-sim; AstGen test (frontend); Sema digital test | drop the check | – |
| `$stop` byte | `src/Sema/digital_test.zig`: `task.zig:location`'s byte indexes `$stop` | `byte + 1` | – |

## 4. Tasks

| T | what | files | depends | lines |
|---|---|---|---|---|
| T0 | Land rw-dlower3 without `sim.zig` hunk (b): rebase onto refactor, red-first tests for G1/G2, fix the G6 quote, commit `timescale.zig`; delete wt a34 | §0 files + `src/Sema/test.zig`, `src/Sema/digital_test.zig` | – | sim −12, comp −43, exe −15 cleared / 25 re-owned, dev −15 |
| T1 | diff-sim (a) run diagnostics, (b) 1364 elaboration warnings, (c) `sim.rulings`; red, then sim.xfail rebaselined with each new line naming its first difference | `tests/differential/sim.zig`, `sim.xfail`, new `sim.rulings` | T0 | adds the G3-G6/G13 debts as lines; any other new line is a finding, reported |
| T2 | std_sim: `Diag`, `fail`/`warn`/`warnCheck`, `State.pc`, old words, E1102, `exe.Config`/`report`, recursion words; bench-run before/after | `lib/std/sim/{State,exe,Interp,readmem,display,files,tchk,sdf,evcd,vcd,calls,eval,Program,serial,test}.zig` | T0 (parallel with T1) | none alone |
| T3 | Sema writes `pc_sites` (Builder `site`, blame table above), `Check.name`; driver `runSites`; sim.zig passes both tables | `src/Sema/digital.zig`, `digital/{task,tchk,sysfn,sub,stmt}.zig`, `lib/std/sim/Builder.zig`, `src/next/Compilation/backend.zig`, `tests/differential/sim.zig`, (`src/codegen/digital_next*`: the `writeExe` argument, with plan-codegen) | T1, T2 | comp −59 (G3 36, G4 21, G5 2) + G6 sdf −1, exe −1 / 59 re-owned |
| T4 | config design cell, at both sites (`library.zig:80` with a map; `Sema.zig:438` without: design_cell_missing and design_names_config carry no map) | `src/Sema/library.zig`, `src/Sema.zig`, `src/Zcu.zig`, `src/next/Compilation/legacy.zig`, `src/Sema/test.zig` | T0 | sim −3, comp −2, exe −2, dev −2 |
| T5 | attribute values | `src/Sema/digital/decl.zig` | frontend `Process.attrs`, T0 | sim −1, comp −1, exe −1, dev −1 |
| T6 | (a) rtlil + device rulings; (b, after libmap T2) the 7 G14 lines to `sim.rulings`; `$stop` byte test; hand the six comp.rulings lines (G9, G13) to the lead | `tests/differential/{rtlil,digital_device,sim}.rulings`, `{rtlil,digital_device,sim}.xfail`, `src/Sema/digital_test.zig` | T0; (b) libmap T2 | rtlil −2, dev −2, sim −7 (b) |

Lanes after T0: T1, T2, T4, T6 share no file (T6 after T0 because both add to `digital_test.zig`). T3 joins T1 + T2. Wrong-text-no-crash first: T1 → T2 → T3 is the critical path.

Per task: `python3 tools/check_style.py` on touched files (≤500 code lines; `State.zig`, `Sema/digital.zig` are one-struct files, §11.1); `zig fmt --check`; every new `pub` item documented with its fact (`pc_sites`: index = `Program.insts` row, `none` = no blame; `fail`: asserts an E-code and no earlier failure); ≥2 paired asserts per new function (`warn` asserts W-code ↔ `report` asserts table lengths equal Sema's appends); every loop bounded.

## 5. Commands (`H=~/.cache/vera-heavy.sh <wt>`)

| task | gates |
|---|---|
| all | `$H check test-sema test-std_sim`; before commit `$H test-unit rewrite` |
| T0 | `$H diff-sim -j4`; `$H diff-elab -j4`; `$H diff-comp -j4 -Dcomp-filter='08_udp|b_A_5|b_A_source_text|attribute_positions|_rejected|native_wide_index|vams_digital_temperature'`; `$H diff-digital-device -j4 -Dcomp-filter='_rejected'` |
| T1 | `$H diff-sim -j4` (red first, then green on the rebaselined list) |
| T2 | `$H test-std_sim`; `$H bench-run` before and after (the `State.pc` store); `$H diff-sim -j4` |
| T3 | `$H diff-sim -j4`; `$H diff-comp -j4 -Dcomp-filter='15_timing_checks|16_sdf|17_system_tasks|18_vcd'`; `$H diff-digital-exe -j4 -Dcomp-filter=<same> -Dcomp-rebaseline` (move only rw-dlower lines) |
| T4 | `$H diff-sim -j4`; `$H diff-elab -j4`; `$H diff-comp -j4 -Dcomp-filter='13_configuration'`; `$H diff-digital-device -j4 -Dcomp-filter='13_configuration'` |
| T5 | frontend's `$H test-vams diff-astgen -j4`; then `$H diff-sim -j4`; `$H diff-comp -j4 -Dcomp-filter=attribute` |
| T6 | `nix develop .#external -c zig build diff-rtlil -j4 -Dcomp-filter='no_top_level|self_instantiation'` (Yosys; take a slot by hand); `$H diff-digital-device -j4 -Dcomp-filter='b_B_keywords|dumpports_same_file'` |

Lists a task may change: sim.xfail, sim.rulings (new), the rw-dlower lines of digital_exe.xfail / digital_device.xfail / rtlil.xfail, rtlil.rulings, digital_device.rulings. Never comp.xfail or comp.rulings: report cleared comp paths and the five ruling lines to the lead.

## 6. Skills, where they bite

| skill | here |
|---|---|
| data-oriented-design | six answers for `pc_sites`, `diags`, `State.pc`, `Check.name` (§2); u32 + `none`; cold tables apart from hot rows |
| codebase-clean-code | owners: Sema writes `pc_sites`/`check_sites`/`Check.name`, std_sim writes `diags`, the driver resolves; no new seam |
| api-design | `report` takes the caller's tables and `Wip`; nothing retained |
| code-style | sizes, order, `Contents:` per file |
| assertions | §4 last paragraph |
| doc-comments | the `pub` facts listed in §4 |
| test-plan, tdd | oracle first, planted fault red first, class oracle T1 before the fixes |
| compiler-construction | rule 5 (coded rows, rendered once), rule 3 (no reaching back to the Ast: G8 goes through Vir) |
| zig | Zig's own structure is the mirror table in §2 |
| ponytail ultra | no new files except `sim.rulings`; no stack-formula port; W1199 text built from an interned name, no run-time path walk |
| simd-loops | nothing hot added except one store per instruction, benchmarked |
| writing-perfect-verilog, spice-engine | not applicable (no Verilog emitted, no solver) |

## 7. Departures from Zig

| where | departure | why |
|---|---|---|
| `State.diags` / `warn` | the run records warnings and goes on; Zig's runtime only panics | IEEE 1364-2005 §17.2.9 and §15.5 require warn-and-continue |
| `State.pc` | an explicit store per instruction instead of a return address | `std_sim` is an interpreter: there is no machine pc to unwind; the store is the interpreter's equivalent, measured |
| blame token per instruction | Sema picks an argument's token for some tasks, where `dbg_stmt` carries the statement's line/column | the old (and the fixtures' locations) point at the argument the diagnostic is about; a column inside the statement is what `dbg_stmt` already allows |
| `Program` vs `pc_sites` | none: the line table stays out of `Program` as DWARF stays out of code | – |

## 8. Open questions

1. **digital_exe re-owning (90 lines).** Recommendation: the lead moves them to `digital_exe (build remarks)` in the same rebaseline.
   Decision: Yes, the lead re-owns them in the same rebaseline; vbackends Q1 then turns the build-remark lines into rulings.

2. **G8 needs AstGen's `Process.attrs`** (plan-frontend). Recommendation: frontend adds it; reading the Ast from Sema is the old shape (two stages back).
   Decision: Frontend adds `Process.attrs` (T6, in one PR with lower TV2). Sema never reads the Ast.

3. **Five comp rulings (G13) instead of copying old artefacts** (lazy name binding, machine-sized stack, token-0 blame). Recommendation: accept; each tiebreak is the fixture's own `//! reject`. If the lead prefers byte equality, the alternative is porting those shapes, which the brief forbids.
   Decision: Accept the five rulings; each tiebreak is the fixture's own `//! reject`. Porting old artefacts is the old shape.

4. **T1 will surface more differences** (SDF W1105, W1162, W1152/W1160/W1161 on the 1364 route). Recommendation: accept the growth; each is a named line and a small follow-up.
   Decision: Accept. Each new difference is a named line; a better oracle growing the list is progress (name lists, not counts).

5. **`writeExe` signature** lives in `src/codegen/digital_next*` (plan-codegen). Recommendation: T3 changes the one argument, agreed with plan-codegen.
   Decision: Yes: T3 changes the one argument; plan-codegen's owner reviews it.

6. **`State.pc` cost.** If `bench-run` shows a measurable slowdown, the fallback is passing pc to the task handlers and recording it only on warn/fail paths (no hot store); decide on the number.
   Decision: Decide on the number: paired, order-alternated `bench-run` before and after T3 (switchover Q13). A slowdown outside the noise takes the fallback (pc only on warn/fail paths).

7. **Shared files** (`src/Zcu.zig`, `library.zig`, `walk.zig`, `backend.zig`, `legacy.zig`) are edited additively; merge order T0 → T4 → T3.
   Decision: Yes: additive edits, merge order T0 -> T4 -> T3.

8. **G7 owner.** plan-libmap's plan gives the design-cell rule to plan-frontend; this plan has it as T4 (it is a Sema root rule: `library.zig:80`, `Sema.zig:438`). Recommendation: one owner, T4 here, and plan-frontend drops it; whoever owns it covers both sites.
   Decision: One owner: T4 here; plan-frontend drops G7's design-cell rule, and T4 covers both sites.
