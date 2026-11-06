# sema: Zcu and elaboration

Read `README.md` first, then `lib/TODO.md` §3 (the stage contract), §4 ("Do we need
AstGen?"), §5, and its map 2 in the Appendix (A.2: every `src/elab` file, the
proposed `Compilation`/`Zcu`/`Zcu.File`/`Zcu.Instance` fields, findings 1-28).
You own a new module `sema` (root `src/sema.zig`, re-exports only; add its row to
`build/common.zig`'s `module_specs` after `air`, importing `vams`, `intern_pool`,
`air`, `kernels`), `src/Zcu.zig` (+ `src/Zcu/`), `src/Sema.zig` (+ `src/Sema/`:
the elaboration files), `tests/differential/elab.zig`, `tests/differential/elab.xfail`,
and the `diff-elab` row in `build/rewrite.zig`.

## What it is

The cross-unit half of Zig's Sema for Verilog-AMS: the files' `Vir` (each from the
merged `vams.AstGen`) and a `Config` in; the elaborated design out, as tables in
`Zcu`. ONE elaborator for analog and digital (the old code has two: `src/elab`,
which clones and flattens the AST, and `lib/sim/digital/elab_*`, with per-instance
scopes). Nothing is cloned: an instance is a key `(module, folded parameter tuple)`
in the `InternPool`, analysed once, as Zig instantiates a generic function
(Z/InternPool.zig:9537 `GetFuncInstanceKey`, Z/Sema.zig:7044-7052, 7270-7300).

- `Zcu`: `files` (path, kind, Vir), `modules` (name -> declaration, last wins,
  IEEE 1364 §13.2.1.1), `instances: MultiArrayList(Instance)` with
  `Instance { module, file, parent, name: InternPool.String, params: InternPool.Index,
  paramset, gate, hier: [6]InternPool.Index, ports }` and `instance_map` (dedup by key),
  `defparams` keyed by `(Instance, name)`, `net_discipline` keyed by `(Instance, net)`
  (ONE Annex F table for what the old code does in six files), `inserts` (§7.8.4),
  `failed_*`, and the `intern_pool`. `Instance.fmtPath` renders a hierarchical path
  on demand: no flat-name strings, no splitting on a separator.
- `Sema`'s elaboration, in this order (each a pass over a table, no seed or dry
  walks): pick the top(s) (§6.2.2, `src/elab/elaborate.zig` pickTop; the old `.v`
  route's `elab.pickTops`); walk the hierarchy filling `instances`, folding each
  instance's parameters through overrides (§6.3, `#()`, `--param`), defparams
  (§6.3.1, §12.8.1 upward paths), paramset selection (§6.4.2 with its tie-breaks)
  and the hierarchical system parameters (§9.18 Table 9-29); evaluate generate
  schemes and unroll them (§6.6, IEEE 1364 §12.4) with genvars as constants; bind
  ports (§6.5, connection shapes, widths); resolve disciplines (Annex F, basic and
  detail §7.4.4, `default_discipline`, out-of-context declarations); plan
  connect-module insertion (§7.7, §7.8.4); the cross-unit checks (`astgen.xfail`'s
  E0373; `parse.xfail`'s E0207, E0237, E0216 if they are elaboration's).
- Constant folding: ONE comptime evaluator over Vir expressions into `InternPool`
  values, with `kernels.fold` as the operator oracle (`lib/TODO.md` map 1 finding
  13: today there are five folders).

## The oracle: `zig build diff-elab`

For every `.va`/`.vams`/`.v` fixture: run the old elaboration (`.va`/`.vams`: the old
`vera.analyze` up to `elab.elaborate`'s `Design`, e.g. through `Lower.Harness` or the
`elab/fixture.zig` support; `.v`: `sim.digital.elaborate`'s `Run.hier`), and the new
`Preprocessor` + `Ast.parse` + `AstGen` + elaboration. Compare:

1. the instance tree: every instance's hierarchical path and module name, in order;
2. each instance's folded parameter values (where the old side exposes them: the
   top's `Lowered.params`, the digital `Run.decls`);
3. the discipline of every net (old `Design.signal_disciplines`, port disciplines);
4. the connect-module inserts (old `Design.inserts`);
5. the elaboration-stage diagnostic codes (E09xx, E1001, ...), as a set per fixture.

`elab.xfail` lists fixtures by path with a reason. Port `src/elab`'s tests (in-file,
~3k lines, and `lib/sim/digital/elab*.zig`'s) as spec examples.

## Done when

`zig build test-sema`, `diff-elab`, `check`, `test-unit` pass; the report names
fixtures compared, every `elab.xfail` line, and the line count against map 2's
target (`src/elab` 11,245 -> ~5,330 plus the digital elaborator's 5,006 gone).
