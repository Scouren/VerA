# Plan: the `.v` backends (`.v --emit-exe`, `--emit-rtlil`, `.digital_device`)

Planner: plan-vbackends. Specs: `docs/rewrite/digital.md`, `exe.md`. Base: `refactor` at 90e93007.
Read-only research; one fact taken from an existing log (no build run): rw-native2's
`zig-out/bench.log` of 2026-11-06 12:04 (below).

Skills applied (where each bites is marked **[skill]** in the tasks): data-oriented-design (six
questions per new table), codebase-clean-code (owner per table, rung per seam), api-design
(caller owns flow: no new callbacks), code-style (≤500 code lines, `check_style.py`), assertions
(paired, bounded loops), doc-comments, test-plan + tdd (oracle named first, red first), zig
(residue), compiler-construction (refuse by clause, no stage reach-back, scalar compiler),
writing-perfect-verilog (generated `.v`), simd-loops (verdict: none, see §6), spice-engine (verdict:
none touched; §8 mixed runners do not set the native hook), ponytail ultra (what is not built).

---

## 0. State found

| Where | What | Status |
|---|---|---|
| `refactor` | interpreted `.v --emit-exe` (step 1), RTLIL over `Program`, `.digital_device` | merged |
| rw-native `agent-a3bf9683adf0e800d` | 06eac376 (case labels/driver values on the stack), 4bb87511 (11 digital_exe lines gone), 758316a6 merge | **committed, unmerged** |
| rw-native, uncommitted | native step prototype: `src/codegen/digital_next/native.zig` (389 lines, untracked), `State.Native` hook, `exe.Config.native`, `VERA_INTERPRET`, `diff-native` step (`build/rewrite_comp.zig`, `comp.zig`, `comp/judge.zig runTwice`), `resolve.zig` plain-net read skip, `small.zig` helpers made pub, `tools/bench_exe.sh` native column | works on 4/6 bench designs; never gated |
| rw-rtlil `agent-aeb4492f7798e9ae5` | branch fully merged (90e93007) | — |
| rw-rtlil, uncommitted | `rtlil/paramod.zig` (untracked, Yosys `$paramod\m\P=v` names), `tests/differential/rtlil_yosys.zig` (untracked, Yosys `read_verilog` oracle), `tests/rtlil_next/param_specs.v` (untracked), `--rtlil-unrefused` flag, `comp/yosys.zig` `Gold`/`against`/`reads` | **never run** (`zig-out/y.log`: no yosys in the default shell) |
| both worktrees | `tests/conformance` shows as modified | never `git add` it (README) |

Measured (rw-native2, `tools/bench_exe.sh 5`, ReleaseFast, median of 5, 2026-11-06):

| design | old native | interpreted | native step | native ÷ interp | gap to old (native step) |
|---|---|---|---|---|---|
| lfsr (2M cycles) | 0.35 s | 1.23 s | 1.27 s | 0.97× (slower) | 3.6× |
| cpu | 0.21 s | 1.26 s | 1.19 s | 1.06× | 5.7× |
| des | 1.01 s | 6.93 s | 1.55 s | **4.47×** | 1.5× |
| mult16 | 0.21 s | 0.65 s | 0.53 s | 1.23× | 2.5× |
| pic, div16 | built | — | **build failed** (new side printed no path) | — | — |

Profiles (callgrind, rw-native `cg-n2`/`cg-pic`/`cg-des2`, before the native step): the time
the native step cannot touch is the scheduler and the scratch arena: `State.wake` 3.5–4.6%,
`enqueueBuf` 4.3–5.8%, `Scheduler.allocate` 1.9–2.5%, `State.claim` 1.9–2.4%, `State.watch` 3.6%,
`ArenaAllocator.reset` 7.9% (lfsr), `ArenaAllocator.alloc` 2.8–16.6%, `runFrom` dispatch 4–11%.
lfsr is clocked only (`always #1 clk = ~clk`, one `@(posedge clk)` block of 3 NBAs): its cost is
events, not expressions, which is why the native step gains nothing there.

---

## 1. Root causes: every line in the area, grouped

### digital_exe.xfail (850 lines)

| # | Group | Lines | Examples | Owner / verdict |
|---|---|---|---|---|
| E1 | Old native codegen's `note:` build remarks; stdout, status, files equal | **707** | `03_lexical_conventions/ams_lexical_escaped_ascii.v` ("4-state: nothing delays"), `11_scheduling/auto_state_two.v` ("2-state once…") | **mine: ruling (T1)** — §2 |
| E2 | `not built: backend libmap` | 21 | `13_configuration/cfg1_default_liblist.v`, `A_formal_syntax/b_A_1_1_incdir.v` | plan-libmap |
| E3 | `not built: backend digital_lowering` | 2 | `05_expressions/native_wide_index_bound_limit.v` (fold past 64 bits), `03_lexical_conventions/escaped_system_task_rejected.v` (`\$display` as user task) | plan-dlower (also sim.xfail) |
| E4 | rw-dlower (digital lowering / run / location / message) | 112 | — | plan-dlower |
| E5 | rw-comp (parse / astgen / preprocess) | 8 | — | plan-frontend |

E1 by remark text (first difference): 221 "2-state once a time step begins with no live x or
z; 4-state until then", 207 "4-state: nothing delays", 96 "4-state: a §7.9 net…", 64 "4-state: a
constant with an x or z bit (file:line)", 30 "not native (…)" (26 of them §15 timing checks),
22 "4-state: a §7.6 pass switch", 22 "4-state: §17.2 file I/O", 17 "4-state: an automatic
task", 9 `===`, 9 `delay3`, 4 extended VCD, 3 `$sscanf`, 2 PLA, 1 plane PLA. Source:
`src/cli/digital.zig:366-378` (old) and `src/codegen/digital/native.zig:104` + 12 more
`Emitter.keepFour` sites.

### digital_device.xfail (65 lines)

| # | Group | Lines | Examples | Owner |
|---|---|---|---|---|
| D1 | `not built: backend libmap` | 21 | as E2 | plan-libmap |
| D2 | `not built: backend digital_lowering` | 2 | as E3 | plan-dlower |
| D3 | old `--check` exits 1, new builds the device (`rw-codegen (codegen) message`) | 11 | `12_hierarchy/extra_ordered_value_ignored.v`, `28_protected_envelopes/protected_md5_digest.v` | **mine (T7)**: `.digital_device` is digital.md's; tagged rw-codegen by the judge's heuristic only |
| D4 | `//! reject` fixture: old E1103 "a name the engine resolves only at run time", new E1100 "a name is used before its declaration" | 1 | `03_lexical_conventions/forward_reference_reg_rejected.v` | **mine (T7)**: ruling, the fixture's `//! reject a name is used before its declaration` sides with new |
| D5 | rw-dlower | 23 | `04_data_types/type_uwire_multiple_drivers_rejected.v` | plan-dlower |
| D6 | rw-comp | 7 | — | plan-frontend |

### rtlil.xfail (33 lines) — none is this area's code

| # | Group | Lines | Owner |
|---|---|---|---|
| R1 | `not built: backend libmap` | 21 | plan-libmap |
| R2 | rw-comp parse (4), parse location (2), astgen (1), elab (3: defparam E0907 vs old E1202/E1205/E1251) | 10 | plan-frontend |
| R3 | rw-dlower: no top / self-instantiation (old writes `autoidx 1`) | 2 | plan-dlower |

Every R line is a fixture `--run` differs on too; each clears when its comp.xfail owner's fix
lands (the judge re-tags; `-Dcomp-rebaseline`).

### comp.xfail

No line names `digital_exe`, `digital_device` or `rtlil` (checked: 0 of 1,993). digital.md's
"done when" holds for comp.xfail already.

---

## 2. Part 1: the 707 build remarks — the user's decision

What the remarks are: old `vera --emit-exe` on a `.v` defaults to `--state=auto`: the native
code runs 4-state until a time step begins with no live x/z, then switches to a second, 2-state
compiled copy of every process; a store of x/z in the 2-state phase reruns the whole design
4-state from time 0 and prints only the rerun's output past the point already printed
(`lib/sim/rt/main.zig:41-55, 120-153`). The remark says which way that went and why ("4-state:
<the first construct that pins 4-state> (file:line)", or "not native (<the refusal>)" when the
whole design fell back to the embedded interpreter). It is a `note:` on stderr; the stdout
transcript is the 4-state one by construction. The new `.v` exe is IEEE 4-state throughout and
has no 2-state phase, no rerun and no whole-design fallback.

### Option A: port the remarks with their meaning on the new engine

To print the same bytes *truthfully* the new engine must actually have what they describe:

| Piece | Old source | New site | Size |
|---|---|---|---|
| the 2-state phase + `live` x tracking + boundary check + rerun with transcript skip | `lib/sim/rt/main.zig` autoDeep, `State.boundary`, `rt/planes.zig`, `rt/snapshot.zig` (316) | `lib/std/sim/{exe,State,Interp}.zig` | ~400 |
| a 2-state twin of every compiled process (the only place 2-state saves anything) | `Phase(true)` dispatch, codegen/digital twin bodies | `codegen/digital_next/native.zig` (a second `native2` prong set) | ~300 |
| the "why 4-state" analysis, its 13 reasons and their source lines | `Emitter.keepFour` ×13, `step_local.zig` (292) | a new `src/Air/digital/StepLocal.zig`-like pass over `Program` + `Lowered.slot_at` | ~450 |
| "not native (why)": the old 171-site whole-design refusal predicate | `src/codegen/digital/*` `refuse(` ×171 | a predicate over `Program` reproducing the old set | ~350 |

Total ~1,500 lines, 4 tasks. Gains: zero measured. `small.value` already takes the machine
path for any x-free value of ≤64 bits (f23e06b5), so a 2-state interpreter phase saves nothing;
the saving exists only for a 2-state *native* twin, which is not built (§3). The "not native"
predicate is the old pipeline's shape reproduced in the new code (the user's binding rule
forbids that), and it would describe a fallback the new exe does not have (the native step falls
back per instruction, not per design). A byte-equal port without the machinery prints claims
that are false.

### Option B (recommended): a ruling, plus refusing the flags the new engine cannot honour

- **Argument (LRM + contract).** IEEE 1364-2005 §3.1 and §4.1 define a net or variable's value
  set as 0, 1, x, z; the 4-state run *is* the specified behaviour, and `--state=auto` was an
  implementation strategy whose contract was "the transcript is the 4-state one"
  (`lib/sim/rt/main.zig:41-47`). The observable contract of `--emit-exe` is the exit status, the
  stdout transcript, the diagnostics about the design, and the files written. The remarks are
  none of these: they report how the old backend compiled. Zig's mirror: no backend prints notes
  about its lowering strategy; `Compilation.getAllErrors` (Z/Compilation.zig:3829) carries only
  diagnostics about the program.
- **Mechanism.** `tests/differential/digital_exe.rulings` (new, 707 lines, one per fixture, by
  name), clause prefix `build remark:`, e.g.
  `verilog/11_scheduling/auto_state_two.v build remark: IEEE 1364-2005 §3.1, §4.1 (4-state is the specified run): old --emit-exe's note on its --state=auto strategy; the 4-state executable has none`.
  Its tiebreaker (`remarkTiebreak`, T1) holds only when: status equal, files equal, new stderr ==
  old stderr with exactly the remark lines removed (three shapes, anchored on `note: <fixture>:`
  then `2-state once a time step begins`, `4-state: `, `not native (`), and new stdout ==
  the fixture's `.expected.txt` when it has one (801 of 1,293 `.v` fixtures; README rule 3's
  independent tiebreaker), else == old stdout.
- **The flags.** vera-next parses `--state=` / `--two-state` / `--schedule=` and ignores them
  (`src/next/cli/args.zig:443-446, 498-508`; nothing reads `cli.logic` or `cli.schedule`):
  `--two-state` silently runs 4-state. Refuse at parse what cannot be honoured
  (compiler-construction rule 6; Zig mirror: `fatal("unrecognized parameter")`, Z/main.zig:1893):
  `--state=2` and `--two-state` exit 2 with
  `error: \`--state=2\`: the .v executable is IEEE 1364 §4.1 4-state; it has no 2-state mode`;
  `--state=auto|4` and `--schedule=fifo|static` are accepted (auto = 4; both schedules are §11.4.1
  legal orders and the interpreter's is fixed), usage text says so.
- **Cost.** One task (T1), ~150 lines (tiebreak ~40, remark filter ~25, args refusal ~20,
  tests ~60) plus a generated 707-line rulings file. Clears 707 digital_exe lines.
- **Switch-over consequence.** The old suite's `--native` mode markers lose meaning: `//
  native-state: 2|4|rerun` (7 fixtures), `// native-required` (74 fixtures),
  `--native=two-state`, `--vera-state`, `--vera-snapshot` (`tests/suite/Native.zig`). See Q3.

**Recommendation: B.** A gives no speed, ~1,500 lines, and either rebuilds the old pipeline's
shape or prints false notes.

---

## 3. Part 2: native `.v` codegen (digital.md step 2)

### Verdict with numbers

- The per-instruction native step (rw-native's prototype, A.6 `Function`'s minimum) is a
  measured win where expressions dominate: des 6.93 → 1.55 s (4.47×), mult16 1.23×. It is
  neutral or slightly worse where events dominate: lfsr 0.97×, cpu 1.06×. Geometric mean over the
  four that built: (0.97·1.06·4.47·1.23)^¼ = **1.54×**. Ship it (T2) after the two failing
  builds are fixed and its oracle is green.
- The remaining gap (lfsr 3.6×, cpu 5.7× vs old native) is in the runtime's per-event work
  (profiles above), which a Program→Zig translation of instructions cannot remove. Attack it in
  `std_sim` (T3), which speeds the interpreted and the native path alike.
- A.6's full `Function` + `Air/digital/Schedule.zig` (levelized combinational logic,
  compiled wake lists: the old `plan.zig` 473 + `plan_nodes.zig` 306 + `settle.zig` 129 →
  A.6 target ~550 lines) is **not planned now**. Decision point D-N3 after T3: build it only if
  lfsr or cpu is still > 2× old native and the user wants that closed (Q5).

### Design (T2) — Zig mirror: `Z/codegen/c.zig:477` `Function`, `:2765` `genBodyInner` (one
prong per instruction tag); `Z/codegen.zig:154` `generateFunction`.

- Input: `*const std_sim.Program` only (no Vir, no Lowered). Output: Zig text appended to the
  exe root by `digital_next.writeExe`: `fn native(...)` (one labelled `switch (pc)` prong per
  compiled pc, `continue :sw` on forward edges) and `const native_pcs = [_]u64{...}`.
- **Hook, rung 7, dispatched per compiled run, not per instruction** [codebase-clean-code,
  AGENTS "dispatch per batch"]. The prototype calls `s.native` through a pointer before *every*
  instruction (`Interp.zig:169`), including the ones it does not compile — the likely cause of
  lfsr's 3% loss. Replace with an existence bitset: `runFrom` tests bit `pc` of
  `s.native_pcs` and calls `native` only on a set bit; `native` runs prongs until it reaches an
  uncompiled pc and returns false there. Residue: one indirect call per entry into a compiled
  run; recorded in the file header. Rung 6 (comptime `native` into a generic `runFrom`) fails
  its axis: `VERA_INTERPRET` must pick interpreter-only at run time in the same binary (the
  oracle), which would double-instantiate `runFrom` and the scheduler that calls it.
- Signature change: `pub const Native = *const fn (*State, *std.heap.ArenaAllocator, *u32) Error!bool`
  (drop the unused `*bool restarted`; the prototype does `_ = restarted`).
- Six questions, `native_pcs` [data-oriented-design]: in = `Program.insts`, out = one bit per
  pc (set ⇔ a prong exists); count = `insts.len` (fixtures ≤10⁴, designs ≤10⁶ → ≤16 K words);
  width `u64` words; access: one random read per interpreter instruction, by pc; lifetime:
  static `const` in the exe; parallel: read-only. Existence table, not a flag column in
  `Program` (the Program is the interpreter's and the serial format's; the bitset is the
  backend's output).
- Paired asserts [assertions]: `native.write` asserts `prongs == @popCount` over the bitset it
  writes and `bitset.len == @divCeil(insts.len, 64)`; `exe.go` asserts the same length against
  the deserialized Program before `s.native_pcs = cfg.native_pcs`; `runFrom` asserts
  `pc < insts.len` (exists) and, after `native` returns false, `!bit(pc)` (it stopped at an
  uncompiled pc) — the negative space.
- Oracle (named before code) [test-plan]: the interpreter. `zig build diff-native`: every `.v`
  fixture's binary run as built and with `VERA_INTERPRET=1`, byte-equal status, stdout, stderr,
  files; list `tests/differential/native.xfail`, which must be **empty** at commit. Bug class:
  wrong value at a width/sign edge of an inlined operator (≤64 bits, x/z fallback). Fixtures
  rarely hit the edges → **new generator** (the oracle-set hole): `tools/gen_native_v.py SEED`
  writes one `.v` (header: seed, command, "Oracle: the interpreter, diff-native"); 8 seeds
  checked in under `tests/differential/native/gen_<seed>.v`; diff-native also collects that
  directory (`fixture.collect` on a second root, `comp.zig` `runAll`, only when
  `v_run.name == "native"`). Each design [writing-perfect-verilog: declared before use, every
  literal sized]: regs of widths {1, 7, 8, 31, 32, 33, 63, 64, 65} signed and unsigned,
  initialised from sized constants with x/z in one in four; 256 `initial` assignments of random
  trees (depth ≤ 4) over native.zig's ops (`+ - * & | ^ ~^ ~ - ! << >> <<< >>> == != === !== < <= > >= && || ?:`,
  the six reductions, constant part-selects, `case`/`casez`/`casex` statements with 4 arms); one
  `$display("%b", r)` per target. 65-bit operands exercise the `leaf` fallback.
- Red first (each planted, shown red in diff-native, reverted; named in the commit message):
  P1 `.add` emits `-%`; P2 `casez`'s wildcard mask uses `casex`'s; P3 the signed `>>>` path
  drops `small.signExtend`.
- Benchmark gate (AGENTS: a speed claim cites a benchmark): `tools/bench_exe.sh 5 <refactor's
  vera-next>` prints old native, interpreted, native, and build seconds (new `build` column,
  `/usr/bin/env time -f %e` around `build()`). Ships when: all 6 designs build and every
  binary's stdout equals old vera's; geometric mean native÷interpreted ≥ 1.2×; no design
  slower than interpreted × 1.05; `--emit-exe` build time ≤ 1.15× the BEFORE vera-next's on
  every design. Otherwise the native step stays out (digital.md: "step 1 is the product") and
  the numbers go in the report.

### T3 — the runtime's per-event cost (`lib/std/sim`), profile-driven

Order (each one commit with its own `bench_exe.sh 5` numbers; stop when no single function
>3% of Ir on lfsr, cpu, pic):
1. `Interp.tidy` (`Interp.zig:370`): `ArenaAllocator.reset(.retain_capacity)` every 64 steps
   even when nothing was allocated (7.9% of lfsr). Reset only when the arena moved since the
   last reset (compare its end index / first-node pointer, read once after each reset).
2. Event rows: `Scheduler.allocate` + `State.claim` + `enqueueBuf` (≈ 8–10% together): reuse
   freed rows from a free list sized once from the step's high-water mark; no per-event
   `ArrayList.append` growth (`array_list.append` 1.9% of pic).
3. `State.wake`/`watch`: whatever callgrind shows next.
Oracles: diff-sim (1281 fixtures, list unchanged), `exe-run`, `test-std_sim`, diff-native
(empty), diff-digital-exe (list unchanged). Red first per change: a test in `lib/std/sim/test.zig`
that fails on the planted fault (e.g. the free list hands out a live row → a two-event
same-time test reads the wrong value).
Gate: each commit ≥5% on at least one bench design, none slower >2%.
Decision point D-N3 after T3: lfsr or cpu > 2× old native ⇒ report to the user with numbers
(Q5); do not start Schedule.zig without a yes.

---

## 4. Part 3: RTLIL follow-ups

### T5 — commit rw-rtlil's uncommitted oracle (`rtlil-yosys`)

- Already written (uncommitted): `tests/differential/rtlil_yosys.zig` (every `.v` fixture + tests/rtlil
  + tests/rtlil_next through `vera-next --emit-rtlil --rtlil-unrefused`, each text held
  Yosys-equivalent to Yosys's own `read_verilog -nodisplay` of the source; a source Yosys cannot
  read is OUTSIDE, named, not a failure); `comp/yosys.zig` `Gold`, `against`, `reads`; the
  build step; the flag through `src/next/cli/{args,Options}.zig`, `Compilation/Config.zig`,
  `backend.zig:230`.
- The oracle is independent of both VerA emitters (Yosys's Verilog front end) — it closes the
  hole that rtlil-equiv (old vs new) cannot see: a bug both emitters share.
- Red first: plant in `src/codegen/rtlil/expr.zig` the `~` (`$not`) cell as `$neg` → red on
  `tests/rtlil_next/param_specs.v` (q = ~a); plant 2: the spec module body written from spec 0's
  instance for every spec (wrong `M`) → red on param_specs (m4 = 5). Both reverted.
- First full run writes `tests/differential/rtlil_yosys.xfail` lines for every FAIL, each with
  owner and first difference (a debt list like the others); tests/rtlil and rtlil_next take no line.
- `--rtlil-unrefused` is test support in the product CLI: keep it out of the usage text and
  name it as such in its doc comment (Zig keeps `--debug-*` the same way). Q6.

### T6 — `$paramod` names: computed in Sema, spelled in the backend

- Problem: `rtlil/paramod.zig` (codegen) reads the parent instance's Vir instruction and the
  module's Vir params to find which parameters the instance's `#()` set — a stage reaching two
  stages back (compiler-construction rule 3), duplicating `Sema/digital/top.zig:197 overridden`.
  Zig mirror: Sema names an instantiated generic from its comptime arguments at analysis time
  (`Z/Sema.zig:35317` `setTypeName`, `.func` strategy, :35359); the backend owns only target
  spellings (compiler-construction rule 4).
- Data change: `sema.digital.Spec` gains
  `overrides: []const Override = &.{}` with `pub const Override = struct { name: []const u8, value: InternPool.Index }`,
  the parameters the spec's first instance sets by `#()` (ordered or named) or defparam, in the
  module's declaration order. Six questions: in = `Zcu.instances` row + its Vir site (Sema reads
  Vir already); out = ≤ params-per-module rows per spec; widths: `Index` u32, name a slice into
  Vir string bytes (as `Spec.module` already is); access: once per spec at emit; lifetime: the
  Compilation arena; parallel: n/a.
- Sites: `src/Sema/digital.zig:113` (`Spec`), `src/Sema/digital/top.zig:119 specs` (fill
  `overrides` from a new `fn overrides(l, k) Error![]const Override` replacing `overridden`'s
  bool; `defaults` unchanged), `src/codegen/rtlil/paramod.zig` (keep only `names(arena, ip,
  specs)` + `writeConst`; no `Zcu`, no Vir import), `emit.zig`/`Module.zig` `In.spec_names`,
  `src/next/Compilation/backend.zig:351`.
- Oracle: module names against Yosys's own derivation — new `yosys.moduleNames(arena, io, yosys,
  gold)`: `read_verilog -nodisplay <f>; hierarchy -auto-top; write_rtlil <work>/names.il`, the
  `module ` lines; rtlil-yosys asserts every `$paramod` name vera-next writes is in that set.
  Red first: `writeConst` drops the `s` of a signed value → red on param_specs. This also settles
  the parameter order inside a name (declaration vs Yosys's own order), which the prototype
  claims but no test checks.
- Fallback `$paramod\<m>\spec<j>` (a real/string/unknown value) stays, with its `ponytail:`.

### T8 — docs: A.6 rows and status (lead or any task, `lib/TODO.md` only)

- A.6 `(new)` rows: `src/Sema/digital/sites.zig` 147 + `sites/Walk.zig` 473 = 620 lines,
  "E12xx first-refusal walk in the old emitter's order; deleted at the switch-over, when the
  refusal becomes the first `error.Unsupported` the emitter meets (Zig: the backend refuses at
  its codegen site, `Function.fail`, Z/codegen/c.zig:643)"; `src/codegen/rtlil{,/}` 1,183 lines
  vs A.6's rtlil rows 1,040; `codegen/digital_next/native.zig` 389 vs A.6's `Function` ~2,000.
- §12: the remark decision, the T2 bench table, D-N3's outcome.

---

## 5. Tasks (one Sonnet agent each, ordered; wrong numbers first)

| T | What | Worktree | Files | Depends | Lists it may change |
|---|---|---|---|---|---|
| T0 | Merge rw-native's committed 06eac376 + 4bb87511 (lead) | refactor | — | — | digital_exe.xfail (its −11) |
| T2 | Native step: finish, oracle, gate | rw-native (`agent-a3bf9683adf0e800d`) | `lib/std/sim/{Interp,State,exe}.zig`, `src/codegen/digital_next.zig`, `src/codegen/digital_next/native.zig`, `build/rewrite_comp.zig`, `tests/differential/comp.zig`, `comp/judge.zig`, `tools/bench_exe.sh`, `tools/gen_native_v.py` (new), `tests/differential/native/` (new, 8 files), `tests/differential/native.xfail` (new, empty) | T0 | native.xfail (must end empty) |
| T5 | rtlil-yosys oracle committed, red first, first run | rw-rtlil (`agent-aeb4492f7798e9ae5`) | its uncommitted files | — | rtlil_yosys.xfail (new) |
| T6 | `$paramod` names from Sema + name oracle | rw-rtlil | `src/Sema/digital.zig`, `src/Sema/digital/top.zig`, `src/codegen/rtlil/{paramod,emit,Module}.zig`, `src/next/Compilation/backend.zig`, `tests/differential/{rtlil_yosys.zig,comp/yosys.zig}` | T5 | rtlil_yosys.xfail |
| T1 | Remark ruling + flag refusal (if the user picks B) | new from refactor after T2 merges | `tests/differential/comp.zig`, `comp/judge.zig`, `tests/differential/digital_exe.rulings` (new), `digital_exe.xfail`, `src/next/cli/args.zig`, `src/next/cli/usage*` (the `--state` lines), `src/next/main.zig:162` | T2 merged (comp.zig/judge.zig), T5 merged (args.zig) | digital_exe.xfail (−707), digital_exe.rulings (+707) |
| T3 | Runtime per-event cost | rw-native after T2 | `lib/std/sim/{Interp,State,scheduler}.zig`, `lib/std/sim/test.zig` | T2 | none (all lists unchanged) |
| T7 | digital_device D3 + D4 | new from refactor | `tests/differential/digital_device.rulings`, `digital_device.xfail` | — | digital_device.xfail (−12), .rulings (+≤12) |
| T8 | A.6/§12 doc rows | lead | `lib/TODO.md` | T2, T3 numbers | — |

Parallel now: T2 ∥ T5→T6 ∥ T7. T1 after T2 and T5 merge. T3 after T2.

### T1 detail
1. Red first: write `remarkTiebreak` test cases in `comp/judge.zig` (old stderr with each of
   the three remark shapes + an unrelated `note:` that must *not* be stripped; new stderr with
   an extra `note:` that must make it fail). Then `pub fn withoutRemarks(arena, text, fixture_rel) ![]const u8`
   (replaces `withoutNotes`, which strips *every* `note:` line: too wide).
2. `comp.zig one()`: rulings whose clause starts `build remark:` → `remarkTiebreak(arena, io, f, old, new)`
   (status, files, `withoutRemarks(old.stderr) == new.stderr`, then the existing `tiebreak`'s
   golden check when `.expected.txt` exists, else `old.stdout == new.stdout`).
3. Generate `digital_exe.rulings` from the 707 `digital_exe (build remarks)` lines (script in
   scratch, not committed); delete those lines from `digital_exe.xfail`.
4. Planted fault (red, reverted): `lib/std/sim/exe.zig` writes `note: x\n` to stderr → every
   ruled fixture reports "the ruling does not hold".
5. Args: `--state=2`/`--two-state` → exit 2 with the message in §2; unit test in
   `src/next/cli/args.zig`'s tests written first (red: today it returns null).

### T2 detail
1. Rebase the uncommitted work on T0's merge; never stage `tests/conformance`.
2. `vera-next --emit-exe zig-out/bench/pic.v` and `div16.v`: read why no path is printed (a
   native prong that does not compile, or vera-next refusing); fix in `native.zig`.
3. Bitset hook (§3 design); drop `restarted` from `Native`.
4. Generator + `tests/differential/native/`; diff-native collects it.
5. P1–P3 red, reverted; diff-native green with `native.xfail` empty; diff-digital-exe list
   unchanged.
6. `bench_exe.sh` build column; run the gate; commit with the table.
7. Style: `native.zig` ≤500 code lines; every `Gen` fn ≥2 asserts (today `inst`, `expr`,
   `goto`, `pure` have 0–1) **[assertions]**; `//!` header records the residue line **[zig]**.

### T7 detail
1. `~/.cache/vera-heavy.sh <wt> diff-digital-device -Dcomp-filter='extra_ordered|port_input_width|port_output_width|ams_keywords_instance|protected_|forward_reference_reg'`
   and read old's stderr for each (the list shows only the status).
2. Where old's error is an E1103 native-codegen refusal: a rulings line in the existing class
   ("the old native codegen refused … as a device; the interpreter-backed device runs it");
   `deviceTiebreak` checks it. D4: rulings line citing IEEE 1364-2005 §4.11 / the fixture's
   `//! reject a name is used before its declaration`; the existing `//! reject` tiebreak checks it.
3. A line whose old error is anything else stays, re-tagged to its real owner, and is reported.

---

## 6. Commands (gate on `$?`, read the log after)

Light steps run directly; corpus steps through the slot script; Yosys steps need the external shell.

| Task | Commands |
|---|---|
| all | `~/.cache/vera-heavy.sh <wt> check test-unit rewrite -j4 > zig-out/g.log 2>&1; echo $?`; `python3 tools/check_style.py <touched files>`; `nix develop -c zig fmt --check <touched .zig>` |
| T2 | `~/.cache/vera-heavy.sh <wt> test-std_sim test-codegen -j4`; `~/.cache/vera-heavy.sh <wt> diff-native -j4 > zig-out/dn.log 2>&1; echo $?` (red runs: `-Dcomp-filter=differential/native`); `~/.cache/vera-heavy.sh <wt> diff-digital-exe diff-sim exe-run -j4`; bench: `cd <wt> && flock $HOME/.cache/vera-heavy.0.lock nix develop -c bash tools/bench_exe.sh 5 <refactor-vera-next> > zig-out/bench.log 2>&1; echo $?` |
| T3 | as T2, bench after every commit; profile: scratchpad `rwnative2/prof.sh zig-out/bench/lfsr.v t3` |
| T5/T6 | `cd <wt> && flock $HOME/.cache/vera-heavy.0.lock nix develop .#external -c zig build rtlil-equiv diff-rtlil rtlil-yosys -j4 > zig-out/ry.log 2>&1; echo $?` (fails, never skips, without Yosys); red runs: add `-Dcomp-filter=no_such_fixture` so only the always-run stems (tests/rtlil + tests/rtlil_next) go through |
| T1 | `~/.cache/vera-heavy.sh <wt> diff-digital-exe -j4 > zig-out/dx.log 2>&1; echo $?` (red: `-Dcomp-filter=verilog/11_scheduling`); `~/.cache/vera-heavy.sh <wt> test-vera-next -j4` |
| T7 | `~/.cache/vera-heavy.sh <wt> diff-digital-device -j4` |

comp.xfail: no task touches it; expected comp.xfail change from this plan: none.

Expected lines cleared: digital_exe −707 (T1, option B), −11 already committed (T0);
digital_device −12 (T7, if old's errors are native refusals as the judge's tag suggests); rtlil 0
by this area (33 clear with plan-libmap 21, plan-frontend 10, plan-dlower 2). New lists:
native.xfail (empty), rtlil_yosys.xfail (debt from T5's first run, unknown size).

SIMD verdict [simd-loops, compiler-construction rule 8]: none. The compiler side is scalar;
the emitted exe runs one chain of events per design (no lane axis inside a run; a lane axis
would be N designs or N seeds, not a use case today).

---

## 7. Departures from Zig

| # | Departure | Why |
|---|---|---|
| Z1 | The shipped `.v` exe interprets a serialized `Program` (`std_sim`); Zig ships no interpreter | settled by digital.md step 1 |
| Z2 | The native step falls back to the interpreter per instruction; Zig's backends fail (`Function.fail`, c.zig:643) or legalize (`Air/Legalize.zig:330`), never fall back at run time | the interpreter is the runtime of scheduling and effects anyway; per-instruction fallback lets prongs grow one tag at a time under the interpreter as oracle |
| Z3 | The hook is a function pointer (rung 7), entered per compiled run | `VERA_INTERPRET` (the oracle) picks interpreter-only at run time in the same binary |
| Z4 | `Sema/digital/sites` (620 lines) is a Sema-side walk serving one backend's refusal order | byte-equal E12xx with the old emitter until the switch-over; then refusals move to the emitter's own sites and the walk goes (T8 records it) |
| Z5 | `tests/rtlil_next/` holds one file (house style: a folder holds two) | build/external.zig globs `tests/rtlil` for the *old* emitter, which cannot write param_specs Yosys can elaborate; merge into `tests/rtlil` at the switch-over |
| Z6 | Today's `rtlil/paramod.zig` reads Vir from codegen | removed by T6 (Sema names, backend spells: Z/Sema.zig:35317) |

---

## 8. Risks

| R | Risk | Mitigation |
|---|---|---|
| R1 | rw-native and rw-rtlil both edit `build/rewrite_comp.zig` (adjacent rows) | merge T2 first, T5 rebases |
| R2 | T2's generator could find real `small.value` bugs (the interpreter is the oracle) | a disagreement there is checked against `eval.evalRow` (the Literal path) as third vote before blaming the native step |
| R3 | Interpreted des is noisy (5.45 s at 06eac376, 6.93 s in the native run) | gate on medians of 5 and on ratios within one bench run, never across runs |

---

## Open questions

**Q1. Build remarks (707 digital_exe lines): port them (option A: ~1,500 lines, no measured speed gain, rebuilds the old pipeline's shape or prints false notes) or rule them (option B: `digital_exe.rulings`, ~150 lines, §2)?**
Recommendation: B, the ruling.
Decision: B, the ruling: remarks describe the old engine's native build, not the design's behaviour, so they are outside the contract. Speed is diff-native's and bench's job.

**Q2. vera-next accepts `--state=2`/`--two-state` and silently runs 4-state. Refuse them, or implement a 2-state mode?**
Recommendation: refuse (exit 2, message in §2); accept `--state=auto|4` and `--schedule=static|fifo`, with the usage text saying the run is 4-state and its event order fixed.
Decision: Refuse with exit 2. Silently running 4-state when 2-state was asked is a wrong answer with no crash; unsupported fails.

**Q3. At the switch-over, what happens to the suite's native markers (`// native-required` ×74, `// native-state:` ×7, `--native=two-state`, `--vera-state`, `--vera-snapshot` in `tests/suite/Native.zig`)?**
Recommendation: retire them with the old engine (a conformance-suite PR removes the comments); diff-native takes over their purpose.
Decision: Retire them with the old engine at the switch-over, in the conformance PR (user approves the push). diff-native takes over their purpose.

**Q4. T2's ship gate for the native step: geometric mean native/interpreted ≥ 1.2×, no design slower than interpreted × 1.05, `--emit-exe` build time ≤ 1.15× today's?**
Recommendation: accept these thresholds; the prototype already passes the first two on the 4 designs that build.
Decision: Accept, checked by a script in the bench step; the verdict and its numbers go in the CHANGELOG, measured.
Measured at w3-native (merged, wave 3), on a machine shared with four agents' builds: geomean 1.313× (passes); mult16 native 0.39 s vs interpreted 0.37 s (1.054×, over 1.05× at `time`'s 10 ms resolution); div16 `--emit-exe` build 1.327× before (over 1.15×), while mult16's went 0.763× and des's 0.887× the other way. The verdict is open: re-measure with `tools/bench_exe.sh` on a quiet machine (no other build running) before the CHANGELOG line; a miss there is a T3 task, not a waiver.

**Q5. If lfsr/cpu are still > 2× slower than old native after T3, build `Air/digital/Schedule.zig` + compiled wake lists (~550+ lines, A.6's full `Function`)?**
Recommendation: no, unless you name a design that needs it; interpreted + native step is the product (digital.md).
Decision: No, unless a named design needs it. Interpreted plus the native step is the product.

**Q6. `--rtlil-unrefused` is a test-only flag in the shipped CLI (the Yosys `read_verilog` oracle needs it). Keep it?**
Recommendation: keep it, out of the usage text, its doc comment saying "test support"; or rename it `--debug-rtlil-unrefused` if you prefer Zig's `--debug-*` spelling.
Decision: Rename it `--debug-rtlil-unrefused` (Zig's `--debug-*` spelling), out of the usage text, doc comment says test support.

**Q7. Who owns digital_device's 12 lines the judge tags rw-codegen (11 old `--check` exit-1, 1 reject-fixture code)?**
Recommendation: this area (task T7), since digital.md assigns `.digital_device` here; plan-codegen does not also take them.
Decision: This area (T7); plan-codegen does not take them.
