# air: the passes (prove/ on structured Air)

Read `README.md` first, then `lib/TODO.md` §6 (prove/ is five jobs; Step B: on
structured Air it shrinks to about 3,000 lines) and §11.7 (variables are slots).
You own `src/Air/Interval.zig`, `src/Air/Float.zig` (+ `src/Air/Float/`),
`src/Air/Legalize.zig`, `src/Air/Setup.zig`, their lines in `src/Air.zig`'s
re-exports and `test` block, `tests/differential/air_passes.zig`,
`tests/differential/air_passes.xfail`, and the `diff-air-passes` row you add to
`build/rewrite.zig`. `src/Air.zig`'s data, `print`, `Verify` and `interp` are
merged and not yours: read them, extend them only by adding what a pass needs
and saying so in your report.

## What it is

The analyses the old `src/prove/` runs on a CFG with phis (9,016 lines, of which
about 4,150 are shipped logic), redone as recursive passes over structured Air,
the way Zig's `Air/Liveness.zig` and `Air/Legalize.zig` work: one walk of the
nesting, no CFG, no dominator tree. Dominance is nesting; the guards on a value
are the enclosing `cond_br` conditions; a block's result is the join of its `br`
operands; a slot's state at a block's exit is the join of its states on every
path out; at a `loop`, iterate to a fixpoint with widening.

- `Interval.zig`: the lattice `{ lo, hi, lo_open, hi_open, nonzero }` × finite,
  meet/join/widen, and a transfer function per opcode (`src/prove/Interval.zig`,
  `transfer.zig`). Every transfer is sound for `Air/interp.zig`'s semantics.
- `Float.zig`: the float verdict (`src/prove/{proof,Prover,seed,guards,walk,verdict}.zig`):
  for each contribution root, `optimized` when no value on its backward slice can be
  non-finite (so `@setFloatMode(.optimized)` is safe), else `strict`; plus the §4.3.2
  domain diagnostics (E0601-E0607, E0609, W0650, W0651, W0653: `src/prove/domain.zig`,
  `message.zig`) into a `vams.Diag.Wip`.
- `Legalize.zig`: if-conversion (`src/prove/ifconv.zig`, 1,335 lines): a `cond_br`
  whose bodies are pure and leave one block result becomes a `select`; in
  speculate mode, domain operations guarded. One post-order recursion, no fixpoint
  and no worklist.
- `Setup.zig`: solve invariance and placement (`invariance.zig`, `setup.zig`), the
  `vera_timepoint` variance check (E0531, `timepoint.zig`), the held-slot prune
  (`held.zig`).

## The oracles: `zig build diff-air-passes`

No differential against the old `prove/` is possible yet (it reads MIR; Sema does
not exist), so:

1. **Soundness by falsification** (the old `src/prove/falsify.zig` is the model):
   a seeded generator of well-formed structured Air programs (`Air/Verify.zig`
   accepts each: arithmetic, the math opcodes, nested `cond_br`, `select`, loops
   with bounded trip counts, slots), parameter ranges, and for each program and
   10^3 random parameter points inside the ranges: run `Air/interp.zig`. If
   `Float` says a root is `optimized`, the interpreter never produces a NaN or an
   infinity on that root's slice; every interval `Float` computes contains every
   value the interpreter sees. Run 10^4 programs.
2. **Legalize preserves meaning:** for each generated program, interp before and
   after `Legalize` gives the same bits at every sampled point (a metamorphic pair).
3. **Setup:** a value `Setup` calls invariant takes one value across every sampled
   point with only the solution (probes) changing.
4. **Spec examples:** port `src/prove`'s own tests (`transfer.zig`'s contains
   sampling, `ifconv`'s shapes, `verdict`'s cases) onto hand-built Air.

Each oracle goes red on a planted bug before it is trusted.

## Done when

`zig build test-air`, `diff-air-passes`, `diff-air`, `check`, `test-unit` pass;
the report gives programs and points compared, the line counts against the
~3,000 target, and every xfail line.
