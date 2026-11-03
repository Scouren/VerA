# vams: AstGen and Vir

Read `README.md` first. You own `lib/std/vams/Vir.zig` (+ `Vir/`),
`lib/std/vams/AstGen.zig` (+ `AstGen/`), their lines in `lib/std/vams.zig`,
`tests/differential/astgen.zig`, `tests/differential/astgen.xfail`, and the
`diff-astgen` row you add to `build/rewrite.zig`. You may move lines out of
`tests/differential/parse.xfail` when your oracle takes a fixture over (below).

## What it is

Zig's `AstGen` + `Zir` for Verilog-AMS: **one file's `Ast` in, one `Vir` out**,
with no information from any other file, so Compilation can run it per file in
parallel and cache it by the file's hash (Z/Zcu/PerThread.zig:600-662). Vir is
untyped: names a file can resolve on its own (locals, ports, nets, parameters,
genvars, block and function scopes, generate-scope names) are resolved to
instructions; names that need another file (modules, natures, disciplines from a
prelude or another unit, hierarchical paths) stay as string references for Sema.

```zig
var tree = try vams.Ast.parse(gpa, source, .{ .keywords = .vams_2023 });
defer tree.deinit(gpa);
var vir = try vams.AstGen.generate(gpa, &tree, .{});   // per file, pure
defer vir.deinit(gpa);
const diag = vir.diag; // a vams.Diag bundle: the per-file checks below
```

## Data (Z = `lib/std/zig/Zir.zig`, `AstGen.zig`)

- `Vir = { instructions: MultiArrayList(Inst).Slice, extra: []u32, string_bytes: []u8, diag: vams.Diag }`
  (Zir.zig:26-36), `Inst = { tag, data }` with `Data` asserted ≤ 8 bytes, `Inst.Ref`
  (Zir.zig:2233) and `Inst.Index`.
- A **declaration table** at a fixed place in `extra` (Zir's `ExtraIndex.imports`
  analogue): every module, connectmodule, macromodule, paramset, UDP, nature,
  discipline, connectrules and config of the file, with its name (a string) and its
  body. Sema reads only this table to build `Zcu.modules`.
- A module body is a list of item instructions (ports with directions, parameters
  with their ranges and default-expression bodies, nets and variables with their
  types and dimensions, branches, instances with connections and overrides,
  generate regions as nested bodies with their scheme, analog/initial/always
  blocks, functions, tasks, specify items, defparams). Statements and expressions
  are instruction bodies, as Zir's are: `block`, `condbr`, `loop`, `call`
  (system calls tagged with the system-function name; a `SysFn` table can come
  later), operators, literals as decoded constants, `decl_ref` to a resolved local,
  `str_ref` to an unresolved name.
- Generate: **not unrolled** (that needs parameter values: Sema). The generate
  scheme and body are kept as a body; AstGen names unnamed generate scopes
  (`genblk<n>`, IEEE 1364-2005 §12.4.3) and resolves names inside them.
- Positional directives (`` `default_discipline``, `` `default_nettype``, ...) arrive
  from the Preprocessor's output tables; AstGen stamps the one in force on each
  declaration (`lib/TODO.md` Appendix A.3, `node_discipline.zig`).

## Per-file checks (moved here from the old parser and elaborator)

Everything a file can judge alone, reported into Vir's `Diag` with the old codes:
the semantic refusals `tests/differential/parse.xfail` lists that need only this
file: E0245 (module path rules over the module's ports), E0230 (generate block
name clashes), E0218 (port declared twice), E0248 (conflicting UDP rows), E0238
(loop index not a genvar), E0206 (a body declaration names no header port), E0225
(formal without a declaration), E0295 (min:typ:max in an analog expression); plus
the old elaborator's per-file rules (`lib/TODO.md` Appendix A.2 "Per-file", map 2
finding 26: local scopes and block/function hiding, §6.5.2.2 port directions, the
§3.4.7 alias source check, wreal structure, UDP §8.1.1, annex C.4). E0207, E0237
(access functions need the disciplines, which may be in another file) and E0216
(needs folding) stay for Sema: say so in `astgen.xfail`.

## The oracle: `zig build diff-astgen`

For every fixture (as `diff-parse` enumerates and preprocesses them): run the old
compiler's `vera.analyze` (as `diff-diag` does) and keep the diagnostics whose
codes are in your per-file set; run the new `Ast.parse` + `AstGen.generate`.

1. **Acceptance with codes:** the set of per-file codes the old compiler reports on
   the file equals the set Vir's `Diag` holds. Each `parse.xfail` line your codes
   cover leaves that file and passes here.
2. **Declaration table:** the file's declarations, kinds and names, in order, equal
   the old `Ast.SourceFile`'s (modules, natures, disciplines, paramsets, UDPs,
   connectrules, configs), past the old prelude's built-ins.
3. **Determinism and purity:** generating each file twice, and the corpus on 1 and N
   threads, gives the same Vir bytes; Vir depends on nothing but its `Ast`.

Also a `Vir/print.zig` text dump (Zig's `print_zir.zig`) and its golden examples,
for debugging.

## Done when

`zig build test-vams`, `diff-astgen`, `diff-parse` (with its shortened xfail),
`check`, `test-unit` pass; the report names fixtures compared and every
`astgen.xfail` line.
