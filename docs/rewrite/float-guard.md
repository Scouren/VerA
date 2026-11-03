# air: a sound float verdict, guarded by a checked input box

Read `README.md` first, then `lib/TODO.md` §11.9. You own `src/Air/Interval.zig`,
`src/Air/Float.zig` (+ `src/Air/Float/`), `tests/differential/air_passes.zig` (+
`air_passes/`) and `air_passes.xfail`. `Legalize.zig` and `Setup.zig` are merged and
not yours; touch them only where they read `Float`'s output.

## Why

The merged `Float` (ported from the old prover) assumes `+ - * /`, `%` and `hypot`
on finite operands never overflow. That is false in IEEE 754 (`1e200 * 1e200` is
`inf`), and the verdict it feeds, `@setFloatMode(.optimized)`, turns an `inf` or
`NaN` into poison: a diverging Newton iterate can then come out as a finite
wrong number that limiting and convergence checks never catch. The falsification
oracle encodes the same assumption: it drops runs that overflow (168,381 of 10^7).
Fast-math is a measured gain, so it stays, but proven, never assumed.

## What changes

1. **Sound intervals.** Every transfer function in `Interval.zig` is sound for IEEE
   754 round-to-nearest as `Air/interp.zig` computes it: bounds rounded outward
   (`nextAfter` toward ±inf, or an exact error bound per operation), an interval
   that can exceed `floatMax` reaches ±inf and is not finite, a possible NaN is
   tracked as such. No overflow contract anywhere.
2. **Bounds are inputs.** A parameter's interval comes from its declared range
   (`from (lo:hi)`, §3.4.2) or is unbounded; an unknown's (a `probe`: a node
   voltage or branch current) from the caller's `Options.unknown_bound` (the old
   `--unknown-bound` knob, `src/prove/proof.zig` `Options`), and when that is null
   from a named default constant, `default_unknown_bound`, chosen by measurement
   (below).
3. **A verdict carries its guard.** `Float.Verdict` gives, per contribution root,
   `.strict` or `.optimized` together with the **input box** the proof assumed:
   for each input the root's slice reads (each `arg` and each `probe`), the
   interval used. Codegen (later) emits a **versioned unit**: an entry check that
   every input is inside the box (one compare pair per input, branch-free on a
   lane), then the fast-math body, else the strict body. So the fast path's
   precondition is checked, never assumed, and the unit is correct on every input.
   A root whose box is the whole real line needs no check.
4. **Choosing `default_unknown_bound`.** A larger bound proves fewer roots; a
   smaller one sends more evaluations to the strict body at run time. Measure over
   the fixture devices that have contributions (the old pipeline's MIR is not
   available to you; use the generator plus hand-built device-shaped Air: diode
   `exp(V/vt)`, MOSFET square law, BSIM-like rational expressions) the fraction of
   roots proven `.optimized` at bounds 1, 10, 100, 1e3, 1e4 (volts/amperes), and
   pick the bound that proves most while staying a physically generous envelope;
   record the table in the header and in your report.
5. **Domain diagnostics are unchanged** (E0601-E0607, E0609, W0650, W0651, W0653),
   except that they now come from sound intervals; report every case where a
   diagnostic appears or disappears relative to the merged behaviour, with why.

## The oracle (`zig build diff-air-passes`)

- Falsification **drops nothing**: for every generated program and every sampled
  point, if a root is `.optimized` and the point lies inside its guard box, the
  interpreter's values on the root's slice are all finite; a point outside the box
  makes no claim (the strict body runs there) but is still evaluated. Sample both
  inside and outside the box, including points that overflow.
- Every interval `Float` reports contains every value the interpreter sees at a
  point inside the box, NaN and ±inf included.
- Planted bugs go red first: reinstating the overflow contract; an interval that
  forgets outward rounding; a box narrower than the proof used.
- Legalize's and Setup's oracles stay green (they read the verdict).

## Done when

`zig build test-air`, `diff-air-passes`, `diff-air`, `check`, `test-unit` pass; the
report gives the bound-vs-proven table, the chosen `default_unknown_bound`, the
diagnostic changes, the guard-box layout codegen will read, and the runtime of
`diff-air-passes` (it must stay inside the merge tier: give it a fast default and a
full mode for the nightly, `-Dfull-oracles`).
