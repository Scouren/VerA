# codegen: the Zig device backend

Read `README.md` first, then `lib/TODO.md` §5, §6, §7, §11.3 (structured Air),
§11.7 (slots), §11.9 (the sound verdict and versioned units), §11.10 (scratch
masks) and Appendix map 5 (A.5: all 76 `src/codegen/device` files, the old
pipeline, the proposed `codegen.zig` dispatch, `DeclGen`, `Function`, `Liveness`,
findings 1-21). You own a new module `codegen` (root `src/codegen.zig`; row in
`build/common.zig` after `sema` and `link`, importing `air`, `intern_pool`, `vams`,
`sema`, `std_kernels`, `contract`, `link`), `src/codegen/zig.zig` + `src/codegen/zig/`
(the backend is named for the language it emits, as Zig's `codegen/c.zig` is; the
old `src/codegen/device/` stays until the switch-over), `tests/differential/codegen.zig`,
`tests/differential/codegen.xfail`, and the `diff-codegen` row in `build/rewrite.zig`.

## What it is

Zig's `codegen/c.zig` for VerA: `Air` + `Air.Device` + `Air.Float.Verdict` (+ the
Air passes' facts) in; one device's Zig source out, as `link.Output` rows that
`link` builds into a library. It reads nothing else: no AST, no elaboration, no
old `Lowered` (constraint 1). Shape (map 5 §3): `codegen.generate(backend, ...)`
dispatches; `DeclGen` holds what lives for the whole device; `Function` emits one
unit (its body, its slots as `var`s, its uses recorded while rendering, never by
scanning the emitted text: map 5 findings 5-6); `Liveness` is the slicing (jobs,
the shared core, inline decisions).

- **Kernels are imported, not spliced:** the device `@import`s `std_kernels` (merged:
  `lib/std/kernels.zig`, the same `z…` names the old text used). No kernel text,
  no `prelude.zig`, no `wideText`: `std_kernels.Family(n_u, deriv_reads)`.
- **Versioned units (§11.9):** for a root `Float` rates `.optimized` with a
  non-empty `Verdict.box(r)`, emit the entry check (each guard's `admits`: one
  compare pair per input, branch-free), then the `@setFloatMode(.optimized)` body,
  else the strict body. An empty box on an `.optimized` root needs no check; a
  `.strict` root has one body.
- **Scratch masks (§11.10):** a scratch array of at most 64 elements gets a
  written-element bitmask: a read of an unwritten element returns 0, a write sets
  its bit, the per-evaluation reset clears one word. No memset.
- **Structured Air** maps to structured Zig directly (`block`/`br` to labelled
  blocks, `cond_br` to `if`, `loop` to `while`), so the old relooper
  (`codegen/cfg.zig`) and the setup re-parser (`setup_chunk.zig`) have no
  counterpart.
- The emitted device satisfies the contract: `comptime contract.validate(D)` passes.

## The oracle: `zig build diff-codegen`

Device text changes by design, so the oracle is behavioural. For the fixtures
`diff-lower` agrees on (its agreed list; more as lowering grows):

1. Build the OLD device (`vera --emit-zig` of the old pipeline, through the old
   zigbuild or `link`) and the NEW device (new front end + Sema + codegen + `link`).
2. Load both (`dynlib`, the contract's entry points) and evaluate at 10^3 seeded
   points (parameters inside their ranges, unknowns, analysis kind, time): the
   residual rows, the Jacobian (the derivative lanes), the charges, the noise
   and AC tables, the limit and held state, the display records.
3. **With every unit forced strict** (a codegen option for the oracle), results are
   bit-identical. **With versioned units**, a point inside a root's box may differ
   only by the fast-math ulps (bounded and measured), and a point outside the box
   is bit-identical to strict (the strict body ran).
4. A codegen test: a scratch array emits no memset, and a read-before-write still
   reads 0 (the bsource.va stack pattern from §11.10).
5. `tests/host/*_host.zig` hosts (the contract's behavioural tests) run against the
   new devices where their fixture is in the agreed list.

`codegen.xfail` lists fixtures with a reason. Report device text size against the
old (map 5: ~71% of a device was kernel text) and build time per device.

## Done when

`zig build test-codegen`, `diff-codegen`, `check`, `test-unit` pass; the report
gives fixtures compared, points, the strict bit-equality result, the
versioned-unit ulp bound, size and build time, every `codegen.xfail` line, and
the line count against map 5's target (~17k for device + facts).
