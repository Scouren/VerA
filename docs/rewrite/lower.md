# sema: analog lowering (Vir -> Air + the device tables)

Read `README.md` first, then `lib/TODO.md` §5, §6, §11.7 (slots), §11.9 (the sound
float verdict) and its Appendix map 3 (A.3: all 68 `src/analog` files and 14
`src/ir` files, what each does, the proposed `Sema`, `Sema.Block`, `Air.Device` and
InternPool keys, findings 1-15). You own `src/Sema/` lowering files (map 3's plan:
`decl.zig`, `expr.zig`, `control.zig`, `contrib.zig`, `syscall.zig`, `discrete.zig`,
plus any `Sema/` subfolder a file over 500 code lines needs), `src/Air/Device.zig`,
`lib/std/vams/SysFn.zig` (the one system-function table, Zig's `BuiltinFn.zig`),
`tests/differential/lower.zig`, `tests/differential/lower.xfail`, and the
`diff-lower` row in `build/rewrite.zig`. `src/Zcu.zig`, `src/Sema.zig` and the
elaboration files are merged (rw-elab): extend them only as lowering needs, and
report each change.

## What it is

The lowering half of Sema, as Zig's `Sema` analyses ZIR bodies into AIR: for the
top instance of an analog design (and every instance under it, through the
`Zcu.instances` table elaboration filled), each `analog` block, `analog initial`
block and analog function is lowered from Vir into ONE `Air` body, with:

- variables as slots (`alloc`/`load`/`assign`, §11.7): no SSA builder, no phis;
- constants folded at emit time through `kernels.fold` and interned (map 3 finding
  9: one folder, where the old code has four drivers);
- `Sema.Block` carrying the context the old `Lower` restored by hand (~25 flags:
  loops, inlining, runtime-condition depth, analog-initial and function restrictions,
  event and d2a statements, the lte/interp/nodiff attribute stack, the current unit,
  the scope path), as Zig's `Sema.Block` does (Z/Sema.zig:351);
- `Air.Device`: the per-instance tables codegen reads besides the body (map 3 §3:
  nodes and ports, unknowns (one owner: map 5 finding 9), branches, parameters with
  their ranges, contributions, charge sites, held slots, memory arrays, limit slots,
  timepoints, table samples, rng seeds, displays, status sites, timer controls,
  systf tasks, the discrete-input tables, the root Refs, the facility set);
- one `SysFn` table (name -> tag + arity, type, context, family, opcode, static) that
  AstGen tags calls with and Sema switches on, replacing four tables and 108 string
  compares (map 3 finding 12);
- the lowering diagnostics (the E04xx-E08xx, E05xx, E06xx-not-proof codes the old
  `src/analog` raises) into a `vams.Diag.Wip`;
- `$table_model` data files: read through a request, like the Preprocessor's (no
  stage reads a file).

## The oracle: `zig build diff-lower`

For every analog fixture (`.va`/`.vams` with an analog block, as `diff-elab`
enumerates them): the old pipeline's `vera.analyze` gives `Mir` + `Lowered`; the new
pipeline gives `Air` + `Air.Device`. Compare:

1. **Tables:** the unknowns (names, kinds, order), branches, parameters (names,
   types, ranges, defaults), contributions (target branch, kind), charge sites, held
   variables, limit slots and displays agree, row for row.
2. **Values, by differential evaluation:** draw 10^3 seeded points (parameter values
   inside their ranges, unknown values, `$abstime`, analysis kind) per fixture;
   evaluate every contribution root with the OLD concrete MIR interpreter
   (`src/codegen/verilog/Interp.zig`, over `opcode.fold`) and with `Air/interp.zig`;
   the results agree bit for bit (NaN as NaN). A root the old interpreter cannot
   evaluate (a call it does not model) is skipped and counted, never silently.
3. **Diagnostics:** the set of lowering-stage codes per fixture agrees (reject fixtures
   included).

`lower.xfail` lists fixtures by path with a reason. Port `src/analog`'s tests
(~2.8k lines) and the `Lower.Harness` examples as spec examples.

## Done when

`zig build test-sema`, `diff-lower`, `diff-elab`, `check`, `test-unit` pass; the
report names fixtures, roots and points compared, every `lower.xfail` line, and the
line count against map 3's target (~21k for `src/analog` + `src/ir`, less the SSA
builder §11.7 removes). This is the largest module of the rewrite: commit working
increments (tables first, then expressions, control, contributions, analog
operators, system calls, discrete context) and keep `lower.xfail` honest.
