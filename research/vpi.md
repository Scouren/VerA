# vpi: the VPI backend (`libvera-vpi-next.a`), plan and spec

No `docs/rewrite/vpi.md` exists; this file is that spec (shape of
`digital.md`/`exe.md`), then the brief's sections. Read with
`docs/rewrite/README.md`, `lib/TODO.md` §2, §3, §8, §11.6, Appendix A.8.
State read at `refactor` 90e93007; no worktree or branch holds new-side VPI
work (`rewrite/vpi`, `pass2/vpi` are old-pipeline branches, merged).
Zig references: `Z/` = `~/.cache/zig-src-d924f83bf/src/` (checked:
`git log -1` = d924f83bf3), `S/` = `/nix/store/spqy6l91i77g18ndfbaq441khlr8zd5f-zig-0.18.0-dev.349+d924f83bf/lib/`.

## What you own

| Piece | Path | Module (`build/common.zig` `module_specs`) | Zig mirror |
|---|---|---|---|
| C header, moved as-is (a copy until the switch-over) | `lib/vpi/include/vpi_user.h` | `vpi_c` = `b.addTranslateC` of it | `S/std/Build.zig` `addTranslateC` (lib/TODO.md §8) |
| Runtime a C app links | `lib/vpi/*.zig`, `lib/vpi/varargs.c` | `vpi_rt` (root `lib/vpi/root.zig`: the export list), imports `std_sim`, `kernels`, `contract`, `vpi_c` | `S/c.zig:32,63` / `S/compiler_rt.zig:40` (a shipped library exporting a C ABI from a comptime export list) |
| Emitter: Sema output -> `vpi_rt.Table` | `src/codegen/vpi.zig` + `src/codegen/vpi/{code,structure,analog}.zig` | `codegen` (gains import `vpi_rt`) | `Z/link/Dwarf.zig` (`initWipNav` :2584, `finishWipNav` :2983, `flush` :4702): compile-time writer of a table a shipped reader reads |
| The runtime's reader of that table | `lib/vpi/Table.zig`, `traverse.zig`, `property.zig` | `vpi_rt` | `S/std/debug/Dwarf.zig` (`open` :304, `findCompileUnit` :852, `getLineNumberInfo` :1297) |
| The library's `main`: one Compilation per design | `src/vpi_host.zig` | artifact root of `libvera-vpi-next.a` | `Z/main.zig:918` `buildOutputType` -> `Compilation.create` (:3642) -> `update` (`Z/Compilation.zig:1714`, `:2751`) |
| Expression printer (old `decompile.zig`) | `lib/std/vams/render.zig` | `vams` | `S/std/zig/Ast/Render.zig:319` `renderExpression` |
| Analog library (old `vpi_tail.zig.txt`, as shipped Zig) | `lib/std/sim/bench/vpi.zig`, `lib/contract/vpi_lib.zig`, `src/codegen/bench/vpi.zig` | `std_sim`, `contract`, `codegen` | `Z/codegen.zig:154` `generateFunction` + `Z/link.zig:397,975` `File.flush` with `Z/Compilation/Config.zig:7-8` `output_mode`/`link_mode` = a dynamic library |
| Build | `build/vpi_next.zig` (new), one line in `build.zig`, rows in `build/common.zig` | | |
| Oracle prong | `tests/differential/comp.zig` (`.vpi` branch), `comp/fixture.zig`, `comp/vpi.zig` (new), `build/rewrite_comp.zig` | | |

Old `src/vpi/` (45 files, 19,670 lines), `build/vpi.zig`, `tests/vpi_*` stay
read-only until the switch-over, which deletes `src/vpi`, renames
`vera-vpi-next` to `vera-vpi`, and points `build/vpi.zig` at `src/vpi_host.zig`.

## What it is: the stages

Zig's chain `Compilation -> Zcu -> InternPool -> Sema -> Air -> codegen ->
link`, with VPI as one more codegen output (as Dwarf is in Zig) and a
shipped reader (as `std.debug` is). Each row: one fixed input, one fixed
output; only `Compilation` reads files or spawns `zig`.

| # | Stage | Fixed input | Fixed output | Zig mirror |
|---|---|---|---|---|
| 1 | `vpi_host.main` (the driver) | argv, `vlog_startup_routines` | `Config` (with `user_systfs`), then one `Compilation` | `Z/main.zig:918,3642` |
| 2 | `Compilation.update` (unchanged spine) | `Config` | `Zcu`, `InternPool`, `sema.digital.Lowered` or `Sema.Analysis` (+ `Air.Device`), for `.vpi_lib` a built library path | `Z/Compilation.zig:2751` |
| 3 | Sema (digital) | Vir + `Config.user_systfs` | `Program` with `systf_task`/`systf_call` rows (an extern call), plus `Lowered` side tables `systf_sites`, `stmt_sites`, `vpi_refs`, `attrs` | `Z/Sema.zig:6605` `analyzeCall`, `:6689` extern callee -> `Z/Air.zig:380` `.call`; `Z/Sema.zig:5846` `zirDbgStmt` -> `Z/Air.zig:542` `.dbg_stmt` |
| 4 | `codegen.vpi.emit` | `Zcu.instances`, `InternPool`, `Lowered` / `Air.Device`, the units' trees for source text and lines only | `vpi_rt.Table` | `Z/link/Dwarf.zig` (writes debug_info/debug_line/debug_str from Zcu + Air dbg rows) |
| 5 | `vpi_rt` runtime | `Table`, `*const std_sim.Program`, a `*std_sim.State` | the C API's answers; the run | `S/std/debug/Dwarf.zig` (reader) + `S/std/Io.zig:26,51` (the `State.Vpi` vtable seam) |

Concretely:

1. `main` (src/vpi_host.zig): invocation and log file; startup routines
   (§12.33.2) register into `vpi_rt.session`.
2. One `Compilation` over the design. `.v` -> `target = .elab` (stops
   after `semaDigital`, `comp.lowered` set) with `Config.user_systfs` and
   `Config.vpi = true`; `.va` without analyses -> `.lint` (stops after
   `airPasses`); `.va` with `*! analysis`/`*! external` -> `.vpi_lib` (new:
   codegen with `vpi_contribs`, link a shared library; path in
   `comp.outputs.exe`).
3. `codegen.vpi.emit` -> `Table`. It never resolves a name, folds a
   constant or walks a scope: every binding (identifier -> slot), every
   folded value (parameters, attributes, delays) and every site (statement
   -> pc, call -> site) comes from Sema's output. It reads a tree only for
   `vpiDecompile` text (`render.expr`) and `vpiLineNo`/`vpiFile` (as Zig's
   Dwarf and error bundles read `Zcu.File` for source lines).
4. `vpi_rt.session.install(table, program)`; digital: a `std_sim.State`
   over `lowered.program`, run by `vpi_rt.run.simulate`; analog:
   `vpi_rt.Binding` over the library's `contract.VpiLib`.

One hierarchy: the Table's module rows `0..instances` ARE `Zcu.instances`
rows `0..instances` (asserted at install); their parent column is the
borrowed `Zcu.instances.items(.parent)`, their names `InternPool.String`s
read through the borrowed `InternPool.string_bytes`. No hierarchy copy, no
re-parse, no second elaborator (old `Builder.zig` §6.7 lookup,
`attribute.zig`'s own fold and `reverse_index.zig`'s lazy maps are not
ported).

## The oracle

- **diff-comp's `.vpi` prong** (task V0b): per fixture, compile the `.c`
  twice with `zig cc -std=c99` (old: `-I src/vpi` + old `libvera-vpi.a`;
  new: `-I lib/vpi/include` + `libvera-vpi-next.a`), run each in a fresh
  dir as `tests/conformance/tools/vera.conf` `run.vpi` does
  (`./<stem> <dir>/<design> [<c> if .va]`, env `VERA_PROTECT_KEYS` from
  `//@ protect-keys`, `VERA_ZIG`, `VERA_VPI_WORK=<dir>`), compare exit,
  stdout, stderr and written files with `judge.compare`. A `.v` whose
  same-stem `.c` names it (conform's `app_of`) runs that `.c`.
- **Tiebreaker** (README rule 3): each fixture's `//! stdout` lines and
  `.expected.txt` are hand-derived in its header (`DERIVATION`); a
  `comp.rulings` line passes when the new side meets them.
- **Switch-over gate**: `zig build suite -- vpi` against
  `lib/vpi/include/vpi_user.h`; `test-vpi-negative`/`-escaped`/`-mem` and
  `vpi_app.c` (702 checks) linked to the new library; `conformance-next`
  with `VERA_VPI_LIB`/`VERA_VPI_INCLUDE` = the new ones (today
  `build/rewrite_comp.zig:143` passes `/nonexistent/vera-next-has-no-vpi.a`).
- A planted fault per task, red first (§3). `comp.xfail` is the lead's.

## Done when

- No `comp.xfail` line reads `not built: backend vpi` or names `rw-vpi`.
- The README gate set, `diff-comp` and the switch-over gate pass.
- Report fixtures moved, rulings, line counts against A.8 (~11,580).

---

## 1. Root causes

All 114 lines (`grep -a "not built: backend vpi" tests/differential/comp.xfail`;
`digital_exe`/`digital_device`/`rtlil.xfail` hold none) share one cause:
`tests/differential/comp.zig:159` returns `.not_built = "vpi"` for every
`.vpi` fixture, and no new library exists. Grouped by the **last feature a
fixture needs** (the task that clears it), from a grep of each `.c`
(`scratchpad/vpi_cls.sh` -> `vpi_cls.txt`, `vpi_assign.txt`); a task
re-sorts its lines by first difference once V0b compares them.

| Group | Needs | Lines | Fixtures (ch11 = verilog-ams/ch11_vpi, ch12 = verilog-ams/ch12_vpi_routines, pli = verilog/pli) |
|---|---|---|---|
| G1 core | model, traversal, properties, phase cbs, printf/mcd | 4 | ch11/printf_mcd, ch12/printf_log, pli/array_object_kinds, pli/end_compile_objects |
| G2 values | + get/put value, no engine hooks | 2 | pli/vpi_value_formats .c, .v |
| G3 run + callbacks | + time walk, time/value-change cbs, sim_control, delayed put | 27 | ch11/cb_action_sim_control, cb_remove_and_info, cb_time_regions, cb_value_change, get_time_scaling, get_value_formats, get_value_unknown, instance_scopes, object_refusals, object_traversal, put_value_delays, value_time_refusals; ch12/buffers, objtype_time, readwrite_inactive, sim_control_reset, sim_control_reset_every_run_rejected, sim_control_reset_run, sim_control_scope, sim_control_stop, time_scaling; pli/mcd, utilities, vpi_event_handles .c .v, vpi_invalid_time_callback .c .v |
| G4 digital systf | + `$user` calls as Program rows, calltf/compiletf/sizetf, args | 10 | ch11/systf_digital, vlog_info; pli/argument_handle_delays_evaluation .c .v, builtin_override .c .v, retained_arguments_evaluate_on_each_read, startup_phase, systf, task_as_function |
| G5 behaviour | + statements/expressions/processes/frames, decompile, cbStmt, assign/force cbs | 11 | ch11/force_release; ch12/assign_cb, cb_fields, force_cb; pli/callback_object_relations, frames, repeat_control, stmt_registration_during_call, subroutines, timeformat, values |
| G6 structure | + primitives/UDP, specify, delays, intermod paths, tchks, pulse, attributes, module arrays, protected | 26 | ch11/behaviour_objects, callback_systf_refusals, primitives, put_delays, specify_objects; ch12/intermod_path, path_delays, pulse_limits, pulse_retain, seq_udp, tchk_violation; pli/attributes, b_G_vpi_user, behaviour, callback_registration_and_removal, delays, event_array, module_array, objects, prim_review, primitives, protected, protected_envelope, specify, structure, timing_checks |
| G7 analog model | `.va`, no analysis: disciplines, natures, nodes, branches, quantities, analog code, analog systf registration | 7 | ch11/analog_behaviour, analog_objects, empty_analog_port_relation, indexed_analog_net_bit, instance_source_line, systf_build, systf_domains |
| G8 analog run | + device library, op/tran/ac walk, analog values/time, derivtf, analog cbs | 25 | ch11/systf_analog; ch12/ac_freq_and_imaginary, accepted_point_sequence, analog_time, analog_value_formats, calltf_sites, convergence_test_rejection, derivtf_partials, fail_converge, forced_solution_points, function_partials, functype, get_real_in_calltf, reactive_branch_flow, registration_roundtrip, reject_analog_callback_times, reject_stale_callback_handle, reject_underivative_handle, remove_cb_during_dispatch, repeated_analyses, sampler_plugin, sim_control_reject_step, task_output_jacobian, time_delta_freq_at_zero; pli/analog_attributes |
| G9 external host | + `*! external`, `*! library`, `*! instances` (ESPice #83/#84) | 2 | ch12/external_host_point, two_libraries_two_instances |
| **total** | | **114** | 109 `.c` + 5 `.v` |

No group is a ruling: the old library passes all 114 in `build/vpi.zig`'s
`vpi_runs` today; rulings can only arise once compared.

**Blockers owned elsewhere** (the new side differs on the design itself):

| Design (fixtures using it) | Line today | Owner |
|---|---|---|
| ramp_load.va (8), dc_divider.va (5), systf_devices.va (2), cap_ramp.va, sampnhold.va | codegen.xfail "a flow contribution to a potential source's branch" | rw-codegen |
| two_sites.va, functype.va, square_law.va, env_probe.va (3) | codegen.xfail "a call of a user function (callee 4294967295)": `src/codegen/zig/Function.zig:570` emits no `systf_calls`/`SystfHost` call for `Air.Device.systf` (`src/Sema/syscall.zig:316` records them) | rw-codegen |
| rc_ac.va | codegen.xfail "a call of `ac_stim`" | rw-codegen |
| verilog/pli/analog_attributes.va | cleared: `$rtoi`/`$itor` fold in `eval.Env.sysCall` (lower T1, commit 75ada1a5 on `worktree-agent-a4adce0a3f2af0653`, not yet in `refactor`); off lower.xfail, only the VPI backend remains | none once merged |
| analog_system_task_registration.va, cube_solve.va | codegen.xfail "old device stopped ... 0xb": old-side crash with no app; both sides run under the host | not a blocker |

## 2. The fix, per group

### 2.1 G1 core (V0a, V0b, V1)

| What | Old (match) | New | Zig mirror |
|---|---|---|---|
| `main`, invocation, log `<app>.log`, usage, exit 1/2, `vpi_host: ...` messages verbatim | `src/vpi/host.zig:111-142`, `:507-581` | `src/vpi_host.zig` `main`, `digitalHost`, `analogHost` | `Z/main.zig:918` |
| startup routines, §26.2.4 phase refusal | `session.zig` `runStartupRoutines` | `lib/vpi/Session.zig` `startup()` | — |
| §12.2 status | `status.zig` (247) | `lib/vpi/status.zig` (~200) | — |
| printf family, MCD channels | `print.zig` (513), `varargs.c`, `cformat.zig` (474, deleted) | `lib/vpi/print.zig` (~380); `lib/vpi/varargs.c`: the four printf variants format with libc `vsnprintf` into a 4 KiB stack buffer, then a heap retry at the returned length; a `%n` is refused (§12.2 error, return EOF) by a scan before the call; `vpi_sim_control`/`vpi_control` read their variadic `int` and call `vera_vpi_control(op, arg, has_arg)` | libc, linked already (lib/TODO.md A.8 note) |
| handles | `trust.zig` + 7 registries | `lib/vpi/Handles.zig` | departure D3 |
| object model | `schema.zig`, `Design.zig`, `model*.zig`, `Builder.zig` (~3,600) | `lib/vpi/Table.zig` + `src/codegen/vpi.zig` | Dwarf writer/reader pair |
| `vpi_handle`, `_by_name`, `_by_index`, `_by_multi_index`, `vpi_iterate`, `vpi_scan` | `handle.zig` (420), `iterate.zig` (272), `reverse_index.zig` (361) | `lib/vpi/traverse.zig` (~450); drivers/loads/uses/lowConn are CSR lists the emitter writes from `Program.drivers`/`fan`, not lazy maps | `S/std/debug/Dwarf.zig:852` (lookups over frozen tables) |
| `vpi_get`, `_get_str`, `_get_real`, `vpi_compare_objects`, `vpi_free_object`, `vpi_release_handle`, `vpi_get_vlog_info` | `property.zig` (500) | `lib/vpi/property.zig` (~400) | — |
| cbEndOfCompile / cbStartOfSimulation / cbEndOfSimulation | `callback_fire.zig` | `lib/vpi/callback_fire.zig` (V1 these three; V3 the rest) | — |

### 2.2 G2 values (V2)

| What | Old | New |
|---|---|---|
| `vpi_get_value`, every §12.14 format | `value.zig` (634), `value_text.zig` (391) | `lib/vpi/value.zig` (~450): bits from `State.v/x` at `Program.slots[slot].word`; radix text through `kernels` `fmt.valueFill` (one §17.1.1.4 rule) |
| `vpi_put_value` NoDelay/Inertial/Transport/PureTransport, ReturnEvent, CancelEvent | `value_put.zig` (620) | `lib/vpi/value_put.zig` (~420) over `State.store` (now) and `State.schedulePut` (later): a request to std_sim's owner, never a plane poke; an event handle is a `Handles` `.event` row over the `State.Handle` it scheduled |
| radix string -> planes | `value_put.zig` `toPlanes` | `kernels` `integer_parse` |

### 2.3 G3 run and callbacks (V3)

std_sim seam, the only engine edit before V4. Zig mirror: `S/std/Io.zig:26`
(`vtable: *const VTable`, :51 `VTable`): a runtime interface behind a
pointer, dispatched at a cold boundary.

```zig
// lib/std/sim/State.zig
/// A VPI application watching the run (lib/vpi), or null for `--run`.
vpi: ?*const Vpi = null,
/// Existence tables over `Program.slots` / `Program.insts`: a set bit is a
/// live cbValueChange on that slot / cbStmt at that pc. Sized at `init`.
vpi_slots: std.DynamicBitSetUnmanaged = .{},
vpi_pcs: std.DynamicBitSetUnmanaged = .{},
pub const Vpi = struct {
    ctx: *anyopaque,
    /// After `slot` changed value and its waiters woke.
    changed: *const fn (ctx: *anyopaque, s: *State, slot: u32) void,
    /// Just before the instruction at `pc` runs (Table 27-6 cbStmt).
    stmt: *const fn (ctx: *anyopaque, s: *State, pc: u32) void,
    /// A `Pending.vpi` row dispatched (a time callback, a scheduled put).
    event: *const fn (ctx: *anyopaque, s: *State, row: u32) Error!void,
    /// A §9.3 assign/force/deassign/release finished.
    done: *const fn (ctx: *anyopaque, s: *State, pc: u32) void,
    /// A survived run-time error (§17.2.9; cbError).
    err: *const fn (ctx: *anyopaque, s: *State) void,
    /// V4: a `systf_task`/`systf_call` at `extra` index `at`.
    systf: *const fn (ctx: *anyopaque, s: *State, at: u32) Error!void,
};
// Pending gains `vpi: u32` (a lib/vpi event row).
pub fn force(s: *State, slot: u32, value: Literal) Error!void;   // vpiForceFlag
pub fn release(s: *State, slot: u32) Error!void;                // vpiReleaseFlag
pub fn putUdp(s: *State, driver: u32, bit: Bit) Error!void;     // §27.32 (V7 uses it)
```

Guard sites, one line each: `State.wake` (`lib/std/sim/State.zig:615`;
every landed value and every `trigger` passes it; after the waiters wake:
`if (s.vpi) |v| if (s.vpi_slots.isSet(slot)) v.changed(v.ctx, s, slot);`),
`Interp.step`'s instruction loop (`vpi_pcs`), the dispatch prong for
`.vpi`, the override completion, `State.warn`. `scheduler.zig`'s
`sync_at`/`synced` already carry cbReadWriteSynch (VAMS §8.5.1).

| What | Old | New |
|---|---|---|
| time walk, `vpi_get_time`, `vpi_sim_control` (stop, finish, reset <= 1000), time queues | `run.zig` (1046; `simulate` :224) | `lib/vpi/run.zig` (~700): `pub fn simulate(s: *Session, state: *std_sim.State) Error!void`; vpiReset = a fresh `State.init` over the same `*const Program` (no re-elaboration; the old VD-106 leak goes) |
| registry, remove, get_cb_info | `callback.zig` (848) | `lib/vpi/callback.zig` (~480) |
| dispatch | `callback_fire.zig` (566), `callback_sites.zig` | `lib/vpi/callback_fire.zig` (~450) |

### 2.4 G4 digital systf (V4)

A user `$name` is an extern call: Sema lowers it to a call row whose callee
the host binds at run time (Zig: `Z/Sema.zig:6689` `func_is_extern` ->
`Z/Air.zig:380` `.call`; the address comes from the linker).

| What | Old | New |
|---|---|---|
| the call row | old elaborator's `systf` hook; `lib/sim/digital/vpi.zig` `vpiEval` (AST at run time) | `lib/std/sim/Program.zig`: `Inst.Tag.systf_task` and `Expr.Tag.systf_call`, `a` = a `Systf` at `extra`; `pub const Systf = struct { reg: u32, site: u32, result: u32, args: List }` (`reg`: `Config.user_systfs` row; `site`: `Lowered.systf_sites` row; `result`: return cell slot, `maxInt` for a task; `args`: one `Program.Ref` per argument, `.none` for an object argument). `Interp` calls `State.Vpi.systf`; a `systf_call` reads `result` after |
| lowering | `src/Sema/digital/sysfn.zig:303` (`sys_fns.get(name) orelse` refuses) | look up `options.user_systfs` first; each value argument lowers to a retained `Program.Expr` row, re-evaluated per read (§26.6.19(e)); an object argument (scope, array, named event, module) records its binding in `systf_sites` |
| registry, compiletf/sizetf, user data, misuse (§20.3) | `systf.zig` (822) | `lib/vpi/systf.zig` (~600) |

`src/Sema/digital.zig` (V4 adds every VPI field, empty by default, so V6/V7
fill them from their own files):

```zig
// Options
user_systfs: []const UserSystf = &.{},
vpi: bool = false,
pub const UserSystf = struct { name: []const u8, kind: enum(u8) { task, function }, functype: enum(u8) { int, real, time, sized, sized_signed }, size: u32 };
// Lowered
systf_sites: []const SystfSite = &.{},   // { scope: u32, file: u32, at: u32, args: Program.List } ; args index `site_args`
site_args: []const ArgSite = &.{},       // { kind: enum(u8){value, scope, slot, event, none}, ref: u32 }
stmt_sites: []const StmtSite = &.{},     // V6: { scope: u32, file: u32, node: u32, pc: u32 }
vpi_refs: []const VpiRef = &.{},         // V6: { file: u32, node: u32, scope: u32, slot: u32 } each identifier Sema bound
attrs: []const Attr = &.{},              // V7: { owner_kind: u8, owner: u32, name: InternPool.String, value: InternPool.Index }
```

`Config.user_systfs`/`Config.vpi` (`src/next/Compilation/Config.zig`, mirror
`Z/Compilation/Config.zig`) carry them; `backend.semaDigital` passes them.

### 2.5 G5 behaviour (V5, V6)

| What | Old | New | Zig mirror |
|---|---|---|---|
| vpiDecompile text | `decompile.zig` (407) | `lib/std/vams/render.zig` (~320): `pub fn expr(w: *Writer, tree: *const Ast, node: Ast.Node.Index) Writer.Error!void`, precedence-minimal | `S/std/zig/Ast/Render.zig:319` |
| processes, statements, expressions, tasks/functions, named events, frames, ranges | `code_module.zig`, `code_stmt.zig`, `code_expr.zig`, `code_tables.zig` (~1,580) | `src/codegen/vpi/code.zig` (~450; `code/expr.zig` past 500): rows/edges/lists/props from `Lowered` (`proc_sites`, `stmt_sites`, `vpi_refs`, `subs`, `blocks`); Annex G maps as `std.EnumArray(Ast.Node.Tag, u16)` | Dwarf `initWipNav`/`finishWipNav` (one entry per analysed decl) |
| cbStmt sites | `lib/sim/digital` `StmtSite` | `Lowered.stmt_sites`, written by `src/Sema/digital/stmt.zig` when `Options.vpi` (the line table); `callback.zig` sets `vpi_pcs` | `Z/Sema.zig:5846` `dbg_stmt` -> `Z/link/Dwarf.zig:179` `DebugLine` -> `S/std/debug/Dwarf.zig:1297` |
| identifier -> object | old `Builder.zig` §6.7 lookup (not ported) | `Lowered.vpi_refs` from Sema's own binding | Air operands are already-resolved refs |
| assign/force/deassign/release cbs | `Host.done_hook` | `State.Vpi.done` | — |

### 2.6 G6 structure (V7)

| What | Old | New |
|---|---|---|
| primitives, UDP defns/instances, seq UDP put | `udp.zig`, `code_module.zig` prim arms, `vpiPutUdp` | `src/codegen/vpi/structure.zig` from `Program.drivers`/`udps`; put via `State.putUdp` |
| specify paths, pulse limits, intermod paths, get/put delays | `delays.zig` (612) | `lib/vpi/delays.zig` (~500) over `Program.paths`/`drivers` (delays folded by Sema) |
| timing checks, cbTchk | `tchkSite`, `tchk.putLimits` | rows from `Program.checks` + `Lowered.check_sites` |
| attributes | `attribute.zig` (265, own fold) | `Lowered.attrs` folded by Sema (`src/Sema/digital/attrs.zig`, new); emitter copies |
| module arrays, protected objects | `model_arrays.zig` | emitter rows from `Zcu.instances` names |

### 2.7 G7 analog model (V8)

| What | Old | New |
|---|---|---|
| disciplines, natures, nodes, branches, quantities, analog params, analog code | `model_analog.zig` (422), `model_branches.zig` (381) | `src/codegen/vpi/analog.zig` (~380) from `Air.Device` (`nodes`, `branches`, `params`, `contributions`, `systf`) and `Zcu.disciplines`/`natures` (interned in `InternPool`) |
| `vpi_register_analog_systf`, `vpi_get_analog_systf_info` | `systf.zig` analog half | `lib/vpi/systf.zig` (after V4) |
| analog properties | `property.zig` analog arms | `lib/vpi/analog.zig` `get`, called by `property.zig`'s analog prong (V1 writes a stub) |

### 2.8 G8 analog run (V9a, V9b)

| What | Old | New |
|---|---|---|
| the library's C ABI | `src/codegen/exe/vpi.zig` (86), `text/vpi_head/tail.zig.txt` (203), `analog.zig` `Lib` (16 `dlsym`s) | `lib/contract/vpi_lib.zig`: `pub const VpiLib = extern struct { open, solve, accept, x, n_u, node, breakpoint, ac, n_rows, row, rows, n_shares, shares, systf, systf_outs, n_systf }`, one exported `vera_vpi_lib` symbol; `lib/std/sim/bench/vpi.zig` implements it over `std_sim.bench` (shipped, never spliced); `src/codegen/bench/vpi.zig` `pub fn writeVpiLib(w: *Writer, title: []const u8, bench: *const Bench, facts: Facts) RenderError!void` writes the `Config` literal and the export |
| `vpi_contribs` | `codegen/device/codegen/dispatch.zig:171,220` | `codegen.generate(.zig, ..., .{ .vpi_contribs = true })`: `vpiContribs`/`vpiShares`/`vpi_share_row` (rw-codegen's files) |
| build the library | `host.zig:388` `buildAnalogLib` (spawns `zig` itself) | `Config.target = .vpi_lib`, `Backend.vpi_lib`: `backend.analogBackend` -> `.codegen = .vpi_lib` -> `link` `.so` with `shared_lib`, work dir `Config.work_dir` = `$VERA_VPI_WORK/<app stem>`; only Compilation spawns |
| op/tran/ac walk, backups, forced/rejected points, sim_control reject | `Binding.zig` (373), `analog_walk.zig` (369), `analog.zig` (527) | `lib/vpi/Binding.zig` (~330) + `lib/vpi/analog.zig` (~330); `Binding.attach(lib: *const contract.VpiLib)`: the host loads it (`dynlib`), `lib/` never `dlopen`s |
| analog value/time/delta/freq, real text | `analog_value.zig` (431, own `%e/%g`) | `lib/vpi/analog.zig`; text through `contract.str_real.zCReal` |
| calltf args, outputs, derivtf partials | `analog_call.zig` (323) | `lib/vpi/analog.zig` |
| mixed-signal refusal | `host.zig:236-292` | `src/vpi_host.zig`, same text |

### 2.9 G9 external host (V9b)

`host.zig:28-91` `External`, `readPoints`, `bannerWord` -> `src/vpi_host.zig`
(banner) + `lib/vpi/Binding.zig` `external(points, bindings, instances)`. The
`*! library <file.va>` design gets its own `Compilation` (one per design).

### 2.10 Data: the six questions per new table

| Table | In -> out | How many (capacity) | Widths | Access | Lifetime | Parallel |
|---|---|---|---|---|---|---|
| `Table.rows` (SoA `Row{vtype: u16, flags: Flags(packed u16), owner: Obj, name: Str, size: u32, payload: u32}`, 20 B, `comptime assert(@sizeOf(Row) == 20)`) | emitter writes; routines read | `objects_max = 1 << 24` (operating error `error.TooManyObjects` at emit) | vtype: Annex G max 746 -> u16; `Obj = enum(u32){ none = maxInt, _ }`; `Str` = `InternPool.String` value | `vpi_get(vpiType)` reads `vtype` only; values read `payload` (slot) | session arena, frozen | no (C API single-threaded) |
| edges CSR (`edge_start` rows+1, `edge_tag: []u16`, `edge_to: []Obj`) | single arrows | `edges_max = 16` per row, asserted | u16/u32 | scan one row's run | frozen | no |
| lists CSR (`list_start`, `list_tag: []u16`, `list_span: []Span{start, len: u32}`, `items: []Obj`) | double arrows incl. reverse relations | `items <= objects_max * 8` | u32 | `vpi_iterate` copies a span | frozen | no |
| props CSR (`prop_start`, `prop_key: []u16`, `prop_val: []u32`) | int props (i32 bitcast), string props (`Str`) | <= 32 per row | | scan one row's run | frozen | no |
| `consts` (`Const{ty: Program.Ty, words: Span}` over `const_words: []u64`, v then x) | folded parameter/constant/attribute values | per constant | Ty u32 | by `payload` | frozen | no |
| `lines` (sorted `obj: []Obj`, `file: []Str`, `line: []u32`) | §26.3.3 (existence table) | objects with a location | u32 | binary search | frozen | no |
| design-wide sets `top`, `disciplines`, `natures`, `udp_defns: []const Obj` | NULL-reference iterations | few | u32 | copy | frozen | no |
| `Session.names` (`HashMapUnmanaged(NameKey{scope: Obj, name: Str}, Obj)`, adapted lookup by bytes over `strings`) | §12.21 index, built at install | rows | 8 B key | per lookup | session | no |
| `Handles` (`packed struct(u64){ kind: Kind(u4; 0 unused, so never NULL), index: u28, gen: u32 }`) | `vpiHandle` | per kind table <= 1 << 20 | gen u32, wrap asserted | O(1) decode | per kind row | no |
| `Session.iters` (SoA `{span, at: u32, use: u64, ty: u16, gen: u32}` + `iter_items: []u64`) | live iterators | `iters_max = 1 << 20` | | cursor | until exhausted/freed (free list) | no |
| `Session.cbs` (SoA `{reason: u16, gen: u32, routine, user_data, obj: u64, time_type: u8, value_fmt: u8, row: u32}`) + per-reason intrusive lists | callbacks | `cbs_max = 1 << 20` | reason u16 | dispatch walks one reason's list | until removed | no |
| `Session.systfs` (SoA `{name: [*:0]const u8 (app's), type: u8, functype: i32, calltf, compiletf, sizetf, derivtf, user_data}`) | registrations | `systfs_max = 4096` | | by `reg` | process | no |
| `State.vpi_slots`, `vpi_pcs` | watch existence | `slots.len`, `insts.len` | 1 bit | one test per wake/instruction when `vpi != null` | run | no |

Hot/cold: `Row` hot; `lines`, `consts`, analog edges cold side tables keyed
by `Obj`. A live row is one on no free list (existence by table, gen
parity asserted), never an `active` flag.

### 2.11 C ABI surface, by usage in the 109 `.c` (files / calls)

| Routine | files | calls | Task |
|---|---|---|---|
| vpi_register_cb | 100 | 295 | V1 (phase), V3 |
| vpi_iterate / vpi_scan | 55 / 54 | 272 / 163 | V1 |
| vpi_get_value | 49 | 197 | V2 |
| vpi_get | 47 | 588 | V1 |
| vpi_handle | 44 | 477 | V1 |
| vpi_get_str | 35 | 155 | V1 |
| vpi_compare_objects | 33 | 187 | V1 |
| vpi_chk_error | 32 | 81 | V0a |
| vpi_put_value | 29 | 116 | V2, V3 (delays) |
| vpi_free_object | 22 | 39 | V1 |
| vpi_handle_by_name | 19 | 61 | V1 |
| vpi_register_systf | 18 | 50 | V4 |
| vpi_get_time | 17 | 60 | V3 |
| vpi_register_analog_systf | 16 | 43 | V8 |
| vpi_handle_by_index | 14 | 55 | V1 |
| vpi_get_analog_time | 13 | 36 | V9b |
| vpi_handle_multi | 10 | 64 | V7 |
| vpi_sim_control | 9 | 30 | V3 |
| vpi_get_delays / vpi_put_delays | 9 / 7 | 77 / 48 | V7 |
| vpi_get_cb_info / vpi_remove_cb | 8 / 7 | 28 / 37 | V3 |
| vpi_get_systf_info | 7 | 23 | V4 |
| vpi_get_analog_value | 7 | 24 | V9b |
| vpi_printf | 6 | 19 | V0a |
| vpi_get_analog_systf_info | 6 | 16 | V8 |
| vpi_mcd_open / printf / name / close | 5/4/4/4 | 28/21/30/18 | V0a |
| vpi_put_userdata / vpi_get_userdata | 4 / 4 | 8 / 7 | V4 |
| vpi_get_analog_delta | 4 | 11 | V9b |
| vpi_handle_by_multi_index | 3 | 9 | V1 |
| vpi_get_vlog_info | 3 | 12 | V1 |
| vpi_get_analog_freq | 3 | 12 | V9b |
| vpi_flush, vpi_mcd_flush, vpi_vprintf, vpi_mcd_vprintf | 3, 2, 2, 2 | 6, 5, 3, 4 | V0a |
| vpi_get_real | 2 | 13 | V1 |
| vpi_put_data / vpi_get_data | 2 / 2 | 2 / 2 | V3 (refuse as old) |
| vpi_control | 2 | 7 | V3 |
| vpi_release_handle | (tests/vpi_negative) | | V1 |

All 48 old exports exist from V0a (an unbuilt routine returns its failure
value with a §12.2 error naming itself), so `tests/vpi_negative` links early.

### 2.12 The exported module ESPice ports to, and the final paths

ESPice imports the old module in-process (its `build.zig`:
`vera.module("vpi")` as `vera_vpi` in its `src/vpi_host.zig`; reported by
plan-switchover). `build/common.zig:104` exports every `module_specs` row
with `b.addModule`, so the new runtime is exported by its row. At the
switch-over (V10) the row `vpi_rt` is renamed `vpi` (path
`lib/vpi/root.zig`), so ESPice keeps `vera.module("vpi")`; the old row
(`build/common.zig:68`, `src/vpi/root.zig`) is deleted with `src/vpi`.

| ESPice uses (old `vpi`) | New `vpi` (= `lib/vpi/root.zig`) | Change for ESPice |
|---|---|---|
| `abi.StartupFn` | `abi.StartupFn` (`lib/vpi/root.zig` re-exports `vpi_c`'s type) | none |
| `user` | `user` (= `vpi_c`, the translated `vpi_user.h`) | none |
| `analog.{HostCall, HostOut, Kind, setPoint, time}` | `analog.{HostCall, HostOut, Kind, setPoint, time}` (`lib/vpi/analog.zig`, V9b keeps the names and signatures) | none |
| `analog.Lib` (16 `dlsym`ed pointers) | `contract.VpiLib` (`lib/contract/vpi_lib.zig`, one `vera_vpi_lib` symbol); `analog.Lib` stays as `pub const Lib = contract.VpiLib` | ESPice looks up one symbol instead of 16 |
| `Binding` | `Binding` (`lib/vpi/Binding.zig`; `attach(lib: *const contract.VpiLib)`) | the attach argument type |
| `callback_fire.{convergenceRejected, endOfCompile, nextForced, startOfSimulation}` | same names in `lib/vpi/callback_fire.zig` (V3 phase cbs, V9b analog) | none |
| `session.{open, close, runStartupTable}` | `session.{open, close, runStartupTable}` in `lib/vpi/Session.zig`; `open` takes `(gpa, table: *const Table, lib: ?*const contract.VpiLib)` instead of the old `Design` | ESPice builds the `Table` through one VerA `Compilation` (`src/vpi_host.zig` `pub fn analogTable(gpa, io, cfg: Config) !Table`, exported in module `vpi_host`) instead of the old analyzer |
| `systf.{find, intAnalogNames}` | same names in `lib/vpi/systf.zig` (V8) | none |

The rule for V3, V8, V9b: these names and signatures are the ESPice
contract; a task that must change one writes the row above and a line in
`CHANGELOG.md` (ESPice migration item).

Final paths after V10:

| Artifact | Before | After | Site |
|---|---|---|---|
| library | `lib/libvera-vpi.a` from `src/vpi/host.zig` | `lib/libvera-vpi.a` from `src/vpi_host.zig` (`vera-vpi-next` renamed `vera-vpi`) | `build.zig:45-47`, `build/vpi.zig:39-47` |
| header (installed) | `include/vpi_user.h` from `src/vpi/vpi_user.h` | `include/vpi_user.h` from `lib/vpi/include/vpi_user.h` | `build.zig:48` `installFile` |
| header (build) | `build/unit.zig:129` `vpi_include = src/vpi` | `lib/vpi/include` | `build/unit.zig:129` |
| conformance | `vera.conf` defaults `$(dirname vera)/../include`, `../lib/libvera-vpi.a` | unchanged (install prefix paths do not move); `build/rewrite_comp.zig:143` drops `VERA_VPI_LIB=/nonexistent...` | `build/rewrite_comp.zig:143` |
| module | `vpi` = `src/vpi/root.zig` | `vpi` = `lib/vpi/root.zig` | `build/common.zig:68` |

## 3. Oracle and red-first per task

| Task | Oracle | Planted fault (red first) | New oracle for the class |
|---|---|---|---|
| V0a | `test-vpi_rt`; header identity | one `#define` changed in the copy | `tests/differential/vpi_header.zig`: the two headers byte-equal until the switch-over; `%n` refused (red without the scan) |
| V0b | diff-comp: 114 move from not built to compared | compare the old side with itself | determinism: new side run twice, byte-compared |
| V1 | diff-comp G1 (4) + `vpi_escaped` | emitter drops each module's last port | `tests/vpi_next/roundtrip_all.c` over every corpus `.v` design: `vpi_handle_by_name(vpi_get_str(vpiFullName, h)) == h`, `vpiModule`/`vpiParent` consistent |
| V2 | diff-comp G2 (2) | `vpiHexStrVal` prints `x` for a partial-X nibble | `tests/differential/vpi_value.zig`: 10^5 random 4-state values x every format, new vs old `value_text.zig` |
| V3 | diff-comp G3 (27) | cbReadOnlySynch before cbReadWriteSynch | model test of register/remove/fire vs a list model; lfsr 2M cycles `--run` not slower beyond noise with `State.vpi == null` |
| V4 | diff-comp G4 (10) | cache a retained argument's first value | Sema test: every user-call value argument lowers to a row, never a folded constant |
| V5 | `tests/differential/render.zig` over every corpus expression | drop parentheses around a lower-precedence operand | round trip `parse(render(e))` structurally equal to `e`, plus byte-equality with old `decompile` |
| V6 | diff-comp G5 (11) | stmt site at `pc + 1` | each `StmtSite.pc` = first pc of its statement (assert in Sema, paired in `callback.zig`) |
| V7 | diff-comp G6 (26) | `vpi_put_delays` ignores the fall delay | put-then-get round trip over every gate and path in the corpus designs |
| V8 | diff-comp G7 (7) | swap a branch's pos/neg node | Table vs `Air.Device`: every branch's nodes in its module's node list, node->net lists equal Device's |
| V9a | library builds; `test-vpi-mem` (`mem_bytes = 32768`) | `vpiContribs` omits the reactive half | the library's op point = `vera-next --run`'s op point of the same `.va` |
| V9b | diff-comp G8+G9 (27) after blockers | accept a rejected tran point | per accepted point, `vpi_get_analog_value` of each node equals the library's `x`; KCL residual < reltol*\|x\| + vntol (spice-engine) |
| V10 | switch-over gate | `vpi_include` -> an empty dir: suite `vpi` fails | — |

## 4. Tasks

One agent each (a few hours). Files listed are the only ones it edits.

| # | Task | Files | Depends | Lines |
|---|---|---|---|---|
| V0a | Runtime skeleton and build: header copy; `vpi_c`; `lib/vpi/{root,Session,Handles,status,print}.zig`, `varargs.c`; every export a refusal stub; `src/vpi_host.zig` (argv, log, startup, one `Compilation` with `.elab`/`.lint`, messages from `host.zig`); `build/vpi_next.zig` (`pub fn library(g: Graph) *Build.Step.Compile`, `test-vpi_rt`, `vera-vpi-next`); `module_specs` rows; `build.zig` call; header test | `lib/vpi/*`, `src/vpi_host.zig`, `build/vpi_next.zig`, `build/common.zig`, `build.zig`, `tests/differential/vpi_header.zig` | — | 0 |
| V0b | Oracle prong (parallel with V0a on the `library` signature): `Fixture.app`; `comp/vpi.zig` `pub fn run(arena: Allocator, io: Io, side: enum { old, new }, f: Fixture, work: []const u8, env: *const std.process.Environ.Map) !judge.Result`; replaces `comp.zig:159`; owner `rw-vpi (<stage>)`; options `zig_exe`, `vpi_old_lib`, `vpi_old_include`, `vpi_new_lib`, `vpi_new_include` | `tests/differential/comp.zig`, `comp/fixture.zig`, `comp/vpi.zig`, `build/rewrite_comp.zig` | V0a signature | 0 (114 compared; lead rebaselines) |
| V1 | `Table.zig`, `traverse.zig`, `property.zig`; `src/codegen/vpi.zig` `pub fn emit(arena: Allocator, in: Input) EmitError!vpi_rt.Table` (`Input = struct { zcu: *const Zcu, lowered: ?*const sema.digital.Lowered, analysis: ?*const sema.Sema.Analysis, trees: []const *const vams.Ast, pp: vams.Preprocessor.Output }`) for modules, gen scopes, ports, nets, regs, vars, parameters, arrays, words, ranges (from `Lowered.slot_*`, `scope_instance`, `instance_ports`, `specs`); stubs `code.emit`/`structure.emit`/`analog.emit`; phase cbs; vlog_info; roundtrip_all | `lib/vpi/{Table,traverse,property,callback_fire}.zig`, `src/codegen/vpi.zig`, `src/codegen/vpi/{code,structure,analog}.zig` (stubs), `src/codegen.zig`, `src/vpi_host.zig`, `tests/vpi_next/roundtrip_all.c`, `build/vpi_next.zig` | V0a | G1: 4 |
| V2 | values + differential value test | `lib/vpi/{value,value_put}.zig`, `tests/differential/vpi_value.zig`, `build/vpi_next.zig` | V1 | G2: 2 |
| V3 | std_sim seam (`State.Vpi`, bitsets, `Pending.vpi`, `force`/`release`/`putUdp`, guards) + `run.zig`, `callback.zig`, `callback_fire.zig` rest, delayed puts; lfsr bench | `lib/std/sim/{State,Interp}.zig`, `lib/vpi/{run,callback,callback_fire,value_put}.zig`, `src/vpi_host.zig` | V2 | G3: 27 |
| V4 | Program `Systf` rows + Interp dispatch; Sema user calls; every new `Lowered` field (empty defaults); `Config.user_systfs`/`vpi`; `lib/vpi/systf.zig`; vpiSysTfCall/argument objects | `lib/std/sim/{Program,Interp,Builder}.zig`, `src/Sema/digital.zig`, `src/Sema/digital/sysfn.zig`, `src/next/Compilation/{Config,backend}.zig`, `lib/vpi/systf.zig`, `src/codegen/vpi.zig` | V3 | G4: 10 |
| V5 | `render.zig` + `diff-render` | `lib/std/vams/render.zig`, `lib/std/vams.zig`, `tests/differential/render.zig`, `build/rewrite.zig` | — (from day one) | 0 |
| V6 | behaviour objects; `stmt_sites` and `vpi_refs` written in Sema; cbStmt, assign/force cbs | `src/codegen/vpi/code.zig` (+ `code/expr.zig`), `src/Sema/digital/stmt.zig`, `src/Sema/digital/expr.zig` (refs only), `lib/vpi/callback.zig` | V4, V5 | G5: 11 |
| V7 | structure; `Lowered.attrs` in Sema | `src/codegen/vpi/structure.zig`, `lib/vpi/delays.zig`, `lib/vpi/traverse.zig` (`vpi_handle_multi`), `src/Sema/digital/attrs.zig` (new) | V4 (parallel with V6) | G6: 26 |
| V8 | analog model + analog systf registration | `src/codegen/vpi/analog.zig`, `lib/vpi/analog.zig` (props), `lib/vpi/systf.zig` | V4 | G7: 7 |
| V9a | `contract.VpiLib`, `std_sim.bench.vpi`, `writeVpiLib`, `vpi_contribs` (with rw-codegen), `.vpi_lib` target/backend/link, host loads it | `lib/contract/vpi_lib.zig`, `lib/contract.zig`, `lib/std/sim/bench/vpi.zig`, `src/codegen/bench/vpi.zig`, `src/codegen/bench.zig`, `src/codegen/zig/*` (vpi_contribs only), `src/next/Compilation.zig`, `src/next/Compilation/{backend,Config}.zig`, `src/vpi_host.zig` | V8; rw-codegen's systf-call line | 0 |
| V9b | `Binding` walk, analog values/time, calltf/derivtf, analog cbs, External + second library + instances | `lib/vpi/{Binding,analog}.zig`, `src/vpi_host.zig` | V9a; §1 blockers | G8: 25, G9: 2 |
| V10 | switch-over gates: `build/unit.zig:129` `vpi_include` -> `lib/vpi/include`; `tests/vpi_*` + `vpi_app.c` against `vera-vpi-next`; `conformance-next` env; the §2.12 renames (module `vpi_rt` -> `vpi`, artifact -> `vera-vpi`, header install source) land with the switch-over PR, after ESPice has a branch on the §2.12 table | `build/unit.zig`, `build/vpi_next.zig`, `build/rewrite_comp.zig`, `build.zig`, `build/common.zig` | V9b | 0 (gate) |

Lanes: {V0a, V0b, V5} first; V1 -> V2 -> V3 -> V4 -> {V6, V7, V8}; V8 ->
V9a -> V9b -> V10. Clears: 4 + 2 + 27 + 10 + 11 + 26 + 7 + 27 = **114**.

Where each skill bites (every task):
- **data-oriented-design**: §2.10 is the bar; `Row` 20 B asserted;
  existence tables; no flags.
- **codebase-clean-code**: one owner per table (emitter -> Table; Session
  -> handles/cbs/systfs; std_sim -> State; VPI writes are requests through
  `store`/`schedulePut`/`force`); spine `vpi_host.main`, one line per phase;
  the `State.Vpi` seam is rung 7 with two cases today (null for `--run`, VPI).
- **api-design**: caller owns memory and flow (`emit` returns a Table into
  the caller's arena; `Binding.attach` takes a library the host loaded).
- **assertions**: two per function; paired across boundaries (emit asserts
  CSR lengths, install re-asserts; `Handles.encode`/`decode`); every
  chain walk bounded (`depth_max = rows.len`).
- **code-style**: <= 500 code lines per file; `Contents:`; one separator.
- **doc-comments**: every `pub`/export names its clause, failure value and
  §12.2 error.
- **zig / simd-loops**: no SIMD (cold, per call); the State guard measured.
- **compiler-construction**: Annex G maps as `EnumArray`; no unexplained
  `else =>`; the emitter neither resolves names nor folds (rule 3).
- **spice-engine**: V9b's certificate and op/tran parity with `--run`.
- **test-plan / tdd**: §3's oracle named before each task's code.
- **writing-perfect-verilog**: not applicable (no Verilog emitted).

## 5. Commands

Worktree setup per AGENTS.md "Building with many agents" (symlinked `.zig-cache`; the inner loop is one private `--watch` per agent; every gate and report is a plain build through `tools/build-slot.sh`, never `-fincremental`); `<wt>` = the task's.

| Task | Inner loop | Gate | Lists it may change |
|---|---|---|---|
| V0a | `nix develop -c zig build check test-vpi_rt --watch -fincremental --cache-dir .zig-cache-watch` | `tools/build-slot.sh <wt> check test-unit rewrite vera-vpi-next`; `python3 tools/check_style.py lib/vpi src/vpi_host.zig` | none |
| V0b | `tools/build-slot.sh <wt> diff-comp -Dcomp-filter='verilog/pli/mcd'` | `tools/build-slot.sh <wt> diff-comp -Dcomp-filter='ch11_vpi\|ch12_vpi_routines\|verilog/pli' -Dcomp-rebaseline=true` (report the vpi lines of `zig-out/comp.xfail.new`) | none |
| V1-V4, V6-V8 | `nix develop -c zig build check test-vpi_rt test-std_sim test-sema test-codegen --watch -fincremental --cache-dir .zig-cache-watch` | `tools/build-slot.sh <wt> diff-comp -Dcomp-filter='<group fixtures, \| separated>'`, then the vpi filter above; V3/V4 also `tools/build-slot.sh <wt> diff-sim diff-comp -Dcomp-filter=verilog/` (no `.v` line may move) and the lfsr bench | none (report comp.xfail lines) |
| V5 | `nix develop -c zig build test-vams --watch -fincremental --cache-dir .zig-cache-watch` | `tools/build-slot.sh <wt> diff-render` | `tests/differential/render.xfail` (ends empty) |
| V9a | as V1 + `test-link` | `tools/build-slot.sh <wt> diff-comp -Dcomp-filter='ch12_vpi_routines'`; codegen.xfail unchanged | none |
| V9b | as V1 | the vpi filter | none |
| V10 | — | `tools/build-slot.sh <wt> suite -- vpi`, `test-vpi-negative test-vpi-escaped test-vpi-mem`, `conformance-next` | `tools/vera.xfail` only with the lead |

Every task: the README before-commit set, `zig fmt --check`, exit code read
as `cmd > log 2>&1; echo $?`. `comp.xfail` never.

## 6. Departures from Zig

| # | Where | Zig does | Here, and why |
|---|---|---|---|
| D1 | Compiler and runtime in one process (`libvera-vpi-next.a` links `comp`) | `zig run` compiles, then spawns the program | §12.33: the application's startup routines register systfs that elaboration reads (§20.4, §26.1.1 sizetf), and its callbacks run against the design in its own address space. The compile step still goes through one `Compilation`; only the run shares the process. |
| D2 | The Table borrows `InternPool.string_bytes` and `Zcu.instances.items(.parent)` | Dwarf serializes `debug_str`/`debug_info` into the artifact; `std.debug` reads bytes | The reader lives in the compiling process, so serializing would be a copy of the hierarchy and of every string (lib/TODO.md §0: one hierarchy). Borrowed as plain slices (`lib/` imports nothing from `src/`); the `Compilation` outlives the run. |
| D3 | `Handles`: generation-checked handles the application frees | InternPool/Zcu indices are permanent; no user frees them | VPI hands out iterators, callbacks and events the C caller frees (`vpi_free_object`, `vpi_remove_cb`) and may use after free (`tests/vpi_negative`); a generation turns use-after-free into a §12.2 error instead of aliasing (the old 7 registries' bug). Object handles keep gen 0: one object, one value. |
| D4 | `State.Vpi` function-pointer table (rung 7), not a request queue | `std.Io` is the same shape (`S/std/Io.zig:26,51`); compiler stages prefer requests | VPI callbacks are synchronous by the LRM (a value-change callback runs before the next statement); a queue would reorder output against `$display`. Bounded by one bit test per wake when unwatched; lfsr bench is the proof. |
| D5 | One global `vpi_rt.session` | Zig passes `*Compilation`/`*Zcu` everywhere | The C ABI (`vpi_user.h`) passes no context; one process-global session is the LRM's model. Every export reads it once and passes `*Session` down. |
| D6 | The emitter reads trees for `vpiDecompile` and line numbers | Dwarf reads `Zcu.File` source locations; error bundles read source text | Same use (text and lines only), but the trees live in `Compilation.units`, not `Zcu.File` (an existing departure of `src/next`, lib/TODO.md §3.3); passed in `Input.trees`. |

## 7. Open questions

Risks and questions for the user, each with a recommendation.

1. **`vpiHandle` encoding needs a 64-bit `usize`. Does `cross` build the VPI library for a 32-bit target?**
   Recommendation: `comptime assert(@bitSizeOf(usize) == 64)` in `Handles.zig`, exclude the library from 32-bit cross targets. If one is required: `kind u4, index u20, gen u8` there.
   Decision: Every `cross.yaml` target is 64-bit (x86_64/aarch64 on linux, macos, windows); wasm32-wasi cannot load a VPI library. `comptime assert(@bitSizeOf(usize) == 64)` in `Handles.zig`, and the VPI library is excluded from wasm.

2. **G8/G9's 27 fixtures wait on rw-codegen (switch branches, systf calls, `ac_stim`); the rw-lower E0357 blocker is cleared by lower T1 (75ada1a5), pending its merge.**
   Recommendation: Schedule V9b after those lines clear; ask rw-codegen to own `systf_calls` + `vpi_contribs` in the Zig backend.
   Decision: Yes: V9b after those lines clear; rw-codegen owns `systf_calls` and `vpi_contribs` in the Zig backend.

3. **Gompute vs `gm` (1 ulp on cosh/sinh/log10) may move a printed digit.**
   Recommendation: Not a line: the f128 tiebreaker (README rule 3).
   Decision: Not a line: the f128 tiebreak (README rule 3). Agrees with codegen Q3b and switchover Q7.

4. **Sema gains VPI-only side tables (`stmt_sites`, `vpi_refs`, `attrs`, `systf_sites`) under `Options.vpi`.**
   Recommendation: Accept: Zig's Sema writes `dbg_stmt`/`dbg_var_*` rows for the same reason (a debug-info consumer); off for `--run`, so no cost there.
   Decision: Accept: written only under `Options.vpi`, as Zig's Sema writes `dbg_stmt` rows for its debug-info consumer.

5. **Mixed-signal designs under VPI: the old host refuses all but transient-only cases; no listed fixture is mixed.**
   Recommendation: Keep the refusal text; running mixed is new work, not in this plan.
   Decision: Keep the refusal, as an `unsup-` code under diagcodes so the gap report lists it.

6. **`vpi_get_vlog_info` strings.**
   Recommendation: Product "VerA", version from `build.zig.zon`, as old; no fixture prints them.
   Decision: As old: product "VerA", version from `build.zig.zon`.

7. **Header as a copy until the switch-over.**
   Recommendation: Yes, held by the byte-identity test; deleted at the switch-over.
   Decision: Yes, held by the byte-identity test, deleted at the switch-over.

8. **ESPice imports the `vpi` module in-process; the new `session.open` takes a `Table` built through a VerA `Compilation` instead of the old `Design`.**
   Recommendation: Keep every other name and signature ESPice uses (§2.12), export `vpi_host.analogTable` for it, rename `vpi_rt` to `vpi` only at the switch-over, and have ESPice port on a branch against `vera-vpi-next` before that PR merges.
   Decision: Accept. ESPice ports on a branch against `vera-vpi-next` before that PR merges; `vpi_rt` becomes `vpi` only at the switch-over.
