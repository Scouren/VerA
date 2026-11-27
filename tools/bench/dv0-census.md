# DV-C census: where the new side's device code and build go

Measured 2026-11-27 with `vera-next` built `-Doptimize=ReleaseFast` from `f58247d5` (P1's commits
change no compiler source), harness `tools/bench/dv0.py census` at the P1 commits, on a shared
4-core, 15 GB machine. Each device builds through `--emit-so` under the work tree's
`lib/osdi_dyn.zig`, with the evalQ adapter `dv0_zig.py` appends (vera-next does not have its OSDI
backend yet). `origin_census.py` groups the functions by origin; `run` and `fast` (codegen/zig's
per-iterate wrappers around `core`) count as device hot.

Reproduce: `BENCH_RTIME=<rtime built> flock ~/.cache/vera-heavy.1.lock nix develop -c python3 -I
tools/bench/dv0.py census zig-out/bin/vera-next OUT.tsv`.

## Shares of machine instructions (IR given to LLVM in brackets)

| device | total instr | device hot | device cold | wrapper hot | wrapper cold | contract | std |
|---|---|---|---|---|---|---|---|
| wide800 | 28204 | 93% (90%) | 0% (0%) | 4% (3%) | 2% (3%) | 1% (3%) | 1% (1%) |
| wide1600 | 54166 | 96% (95%) | 0% (0%) | 0% (2%) | 1% (1%) | 0% (2%) | 2% (0%) |
| wide3200 | 106204 | 98% (97%) | 0% (0%) | 0% (1%) | 1% (1%) | 0% (1%) | 1% (0%) |
| inst62 | 78063 | 7% (5%) | 0% (0%) | 92% (84%) | 1% (0%) | 0% (10%) | 0% (0%) |
| inst1000 | refused by codegen/zig (inst 62, 64 nodes, is the largest inst it emits) | | | | | | |

In inst62 the device's `eval` is inlined into the wrapper's `evaluate` (66448 IR lines) at
analysis, so its code counts as wrapper hot. inst62's contract share is 5553 small
`contract.family` functions in the IR given to LLVM, 0% after optimization.

## Build: CPU seconds and memory

| device | zig processes | analysis only | + bitcode | full | largest process peak | summed peak of the split build |
|---|---|---|---|---|---|---|
| wide800 | 1 | 0.57 s | 2.21 s | 3.16 s | 246 MiB | 266 MiB |
| wide1600 | 4 (3 units + link) | 3.83 s | 10.08 s | 12.31 s | 412 MiB | 727 MiB |
| wide3200 | 4 (3 units + link) | 10.74 s | 32.52 s | 39.76 s | 630 MiB | 1182 MiB |
| inst62 | 1 | 1.37 s | 7.79 s | 9.08 s | 412 MiB | 406 MiB |

Largest function given to LLVM: `device.run` with 45935 IR lines (wide800), 91665 (wide1600),
183135 (wide3200). In the split builds it is given to LLVM three times, once in each unit (eval,
setup, state): 3 x 91665 of 289914 lines (wide1600), 3 x 183135 of 564324 (wide3200); LLVM drops
two copies as unused (IR after optimization: 46974 and 93921 device-hot lines).

## Iterate time (tools/bench/dv0-baseline.tsv, ns, min of 20)

wide64 1992, wide256 8733, wide1600 43396: about 27 ns a stage, eval alone equal to the iterate
(rhs and Jacobian loads ~10 ns on 3 nodes). inst62: iterate 8553, eval alone 2478 (29%).

## Verdicts

- **DV7 (pack isomorphic branches): premise holds only for instance-shaped models, with a 29%
  ceiling.** The wide models' stages are one serial chain (each `t{i}` reads `t{i-1}`): nothing
  independent to pack, although device hot is 93-98% of their instructions. inst62's 62 cells are
  independent and isomorphic, but its eval is 2478 of 8553 ns an iterate (29%); the Jacobian and
  rhs loads of 64 nodes are the rest. Packing could at most remove part of that 29%.
- **DV8 (bound emitted function size): premise holds.** One function, `device.run`, is 90-97% of
  the IR given to LLVM and grows linearly with the model (45935 / 91665 / 183135 lines), while the
  LLVM time (full minus bitcode) grows superlinearly: 0.95 s, 2.23 s (2.3x), 7.24 s (3.2x) per
  doubling, and the build's summed peak 266 / 727 / 1182 MiB. The larger cost at wide3200 is the
  frontend's bitcode for three copies of that function (32.52 - 10.74 = 21.8 s of 39.76 s): a split
  build that gave `run` to its eval unit alone would cut that by about two thirds, a finding outside
  DV7-DV9.
- **DV9 (cold code as tables): premise does not hold on the new side.** Device cold is 0% and
  wrapper cold 1-2% of machine instructions in every device measured (wide800 2%, wide1600 1%,
  wide3200 1%, inst62 1%); in the IR given to LLVM, 0-3%. Cold code is not where the instructions,
  the time or the memory go.
