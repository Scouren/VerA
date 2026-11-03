# sim: the digital runtime over one Program table

Read `README.md` first, then `lib/TODO.md` §8 and its maps 6 and 7 (Appendix
A.6, A.7: `lib/sim/digital` holds a second compiler; `lib/sim/rt` is a second
engine). You own `lib/std/sim.zig` and `lib/std/sim/` (a new module `std_sim`
you add to `build/common.zig`'s `module_specs`, importing `kernels` and
`contract` only: never `frontend`), `tests/differential/sim.zig`,
`tests/differential/sim.xfail`, and the `diff-sim` row in `build/rewrite.zig`.

## What it is

The runtime that executes a digital (IEEE 1364-2005) design: `vera --run`'s
interpreter, the per-process fallback of a native `--emit-exe`, and the digital
half of a mixed run. It reads ONE fixed table, `Program`, which a compiler stage
writes (later `Sema`; for now the oracle's bridge below), and never sees source,
tokens or an AST. One state struct and one engine, where today there are two
(`lib/sim/digital/Run.zig` with heap values per slot, `lib/sim/rt/State.zig`
over u64 planes).

- `Program.zig`: the table, as `lib/TODO.md` map 6 §4 sketches it: `insts:
  MultiArrayList(Inst)` (`Inst = { tag: u8, data: 8 bytes }`, asserted), `exprs:
  MultiArrayList(Expr)` (typed, names already bound to slots), `extra`, `consts`
  (v then x planes), `string_bytes`, `slots`, `init_v`/`init_x`, `procs`, `subs`,
  `scopes` (for `%m`, VPI, `$dumpvars`, SDF), `fmts` (§17 formats parsed once),
  `fan_start`/`fan`, nets, drivers, trans, UDPs, timing checks, paths. It grows
  `lib/sim/rt/design.zig`'s `Design`, which is already most of this.
- `State.zig`: run state over `*const Program`: value planes (v and x words), the
  scheduler (`lib/sim/scheduler.zig`, moved as is), waiters, net resolution, NBA,
  holds, activations, monitors, dumps (VCD, EVCD), system tasks and files, timing
  checks, the event budget. The duplicated pairs merge (map 7 finding 8: waiters,
  resolution, evcd, monitor, system, NBA, activations).
- `Interp.zig` + `eval.zig`: execute `Program.insts` and evaluate `Program.exprs`
  over the planes, with `rt/logic`'s four-state operators (non-allocating: wide
  `* / % **` through `kernels/wide_kernels.zig`, `lib/TODO.md` §9 bug 2).
  `Interp.step(pc)` is also the per-process fallback a native executable calls.
- Display and scan through `kernels` (`fmt`, `printf`/`str_real`, `str_scan`):
  `lib/sim/digital/scanf.zig` and the format walkers are duplicates to delete.

## The oracle: `zig build diff-sim`

A **bridge** stands in for Sema until it exists: test code (in
`tests/differential/sim/bridge.zig`) that takes the OLD elaborated design, a
`lib/sim/digital` `Run` after `elaborate`, and writes the new `Program` from it
(slots, processes, instructions, expressions bound to slots, nets, drivers, ...).
Then, for every `.v` fixture the old `vera --run` runs (`tests/conformance/tests/verilog/**`,
the `suite -- devices` and `suite -- ieee1364` sets; read `tests/suite/*.zig` to see
how they are run and judged):

1. Run the old interpreter (`sim.digital.run`) and capture its transcript (stdout,
   `$display`/`$monitor`/`$strobe` text, `$finish` time, exit status, VCD file if any).
2. Bridge the same elaborated `Run` into a `Program` and run the new `Interp`.
3. The transcripts are byte-equal; VCD files byte-equal.

`sim.xfail` lists fixtures by path with a reason (a construct the bridge cannot
express yet, say). Port the old runtime's own tests (`lib/sim/digital/*.zig` and
`lib/sim/rt/*.zig` test blocks, 4.8k lines) onto `Program` built by hand.

## Done when

`zig build test-std_sim`, `diff-sim`, `check`, `test-unit` pass; the report names
fixtures compared, the line count against map 6/7's targets (runtime ≈ 8.9k + rt
merge), and every `sim.xfail` line.
