# The rewrite: VerA as a Zig-shaped compiler

Read this whole file before writing code, then your module's spec beside it
(`parse.md`, `preprocess.md`, `core-ir.md`, ...). `lib/TODO.md` is the full
plan: §2 the target tree, §3 the stage contract, §5 the new structs, §6 prove/,
§11 the settled decisions, and its Appendix maps every old file to its target.

## What and how

VerA is being rewritten into the shape of the Zig compiler: a reusable
frontend in `lib/std/vams` (Zig's `lib/std/zig`), and a compiler in `src/`
made of `Compilation`, `Zcu`, `InternPool`, `Sema`, `Air` (+ passes),
`codegen`, `link`. The old pipeline keeps running and stays the product until
the new one matches it; it is also the **oracle** for the new one.

The rules of the rewrite:

1. **Each new module builds and tests alone.** It is a row of
   `build/common.zig`'s `module_specs` and imports only std or modules above it
   in that list. `zig build test-<module>` runs its tests in seconds (`test-vams`
   is 3.6 s after an edit). Never import an old module (`frontend`, `elab`,
   `analog`, `ir`, `prove`, `diag`, `base`, ...) from a new one.
2. **The old code is the behaviour spec, read-only.** Read it to learn what
   the new code must do; never edit it. The new module must reproduce its
   observable behaviour, judged by a **differential oracle**: a test root under
   `tests/differential/` imports both the old and the new module and compares
   them over the whole fixture corpus (`tests/conformance/tests`, 4,242 `.va`,
   `.vams`, `.v` files, plus VerA's own under `tests/`).
3. **A known difference is a named marker, never a count or a skip.** Each
   oracle has a `tests/differential/<name>.xfail` file: one line per fixture
   path that may differ, with the reason. A listed fixture that now agrees fails
   the run until its line goes (AGENTS.md: an unexpected pass fails).
4. **Data first.** Answer the six data questions (the `data-oriented-design`
   skill) before code: SoA (`std.MultiArrayList`), typed `u32` handles with a
   sentinel, narrowest widths, an `extra: []u32` side array for variable-length
   payloads, a compile-time `@sizeOf` assertion on every hot row. Copy Zig's
   shapes; they are the hand-written reference.
5. **Small, Zig-like files.** One struct per file named after it
   (`Ast.zig`, `Parse.zig`); helpers that would push a file past
   `tools/check_style.py`'s 500 code lines go to a subfolder of the same name
   (`Parse/expr.zig`), as Zig's `Sema/` does.

## The modules

| module | root | imports | spec | status |
|---|---|---|---|---|
| `vams` | `lib/std/vams.zig` | std | `parse.md` (tokenizer, Ast, Parse), `preprocess.md` (Preprocessor) | in progress |
| `intern_pool` | `src/InternPool.zig` | std | `core-ir.md` | in progress |
| `air` | `src/Air.zig` | `intern_pool` | `core-ir.md` | in progress |
| `link` | `src/link.zig` | `contract`, `dynlib` | `link.md` | spec ready |
| `vams` (`Diag`) | `lib/std/vams/Diag.zig` | std | `diag.md` | spec ready |
| next: `AstGen`+`Vir` (after Ast), `Zcu`+`Sema` (after Vir, InternPool, Air), Air passes, `codegen`, `Compilation` | | | written when their inputs exist | |

The handle types other modules build against are fixed already:
`InternPool.Index = enum(u32) { none = maxInt(u32), _ }` and
`InternPool.String = enum(u32) { empty = 0, _ }`. Keep them.

## The Zig reference

- std frontend: `/nix/store/spqy6l91i77g18ndfbaq441khlr8zd5f-zig-0.18.0-dev.349+d924f83bf/lib/std/zig/`
  (`tokenizer.zig`, `Ast.zig`, `Parse.zig`, `AstGen.zig`, `Zir.zig`, `ErrorBundle.zig`,
  `number_literal.zig`, `string_literal.zig`, `Ast/Render.zig`).
- aro (a C preprocessor in Zig): `.../lib/compiler/aro/aro/` (`Preprocessor.zig`, `Compilation.zig`, `Diagnostics.zig`).
- the compiler, at the commit this repo pins (`d924f83bf`):
  `/tmp/claude-1000/-home-omare-Documents-Projects-EDA-Tools-Simulator-VerA/f1a34fb7-d252-47c9-8482-f90578a3d320/scratchpad/zig/src/`
  (`InternPool.zig`, `Air.zig`, `Air/Liveness.zig`, `Air/print.zig`, `Air/Verify.zig`,
  `Sema.zig`, `Zcu.zig`, `Compilation.zig`, `codegen/c.zig`, `link.zig`). If the
  directory is gone: `git clone --filter=blob:none https://codeberg.org/ziglang/zig.git`
  then `git checkout d924f83bf`.

## Building and iterating

- Every `zig build` runs inside `nix develop -c ...` (AGENTS.md "Building").
- In a fresh git worktree: `ln -s /home/omare/Documents/Projects/EDA-Tools/Simulator/VerA/.zig-cache .zig-cache`
  (share the warm cache) and `git submodule update --init tests/conformance` (the fixtures).
- The loop: `nix develop -c zig build test-<module> -j4`, then your oracle
  `nix develop -c zig build diff-<name> -j4`. Before you finish:
  `zig build check`, `zig build rewrite`, `python3 tools/check_style.py <your files>`,
  `zig fmt --check <your files>`.
- The machine is shared (other agents, another project's GPU builds): pass
  `-j4`, run one build at a time, and never run the whole `zig build test`
  (the lead runs it when merging).
- Gate on the command's own exit code: `cmd > log 2>&1; echo $?`, then read the
  log. In zsh, `exit "${PIPESTATUS[0]}"` exits 0 whatever happened.

## The method (AGENTS.md, binding)

Load these skills first (Skill tool): `zig`, `data-oriented-design`,
`compiler-construction`, `assertions`, `code-style`, `doc-comments`, `tdd`,
`ponytail`. Then:

- Name the oracle before writing the code; a new test goes red before it is
  trusted green; the main bug class is a wrong answer with no crash.
- Two or more paired assertions per function, a bound on every loop, recursion
  bounded on input-controlled depth (a fixed cap with its own error is settled:
  `lib/TODO.md` §11.2).
- An operating error returns to the caller; a bug hits an assertion. Input is
  validated once, at the edge.
- Every `pub` item has a doc comment carrying a fact the signature cannot; every
  file starts with a `//!` header ending in a `Contents:` list of its `pub`
  declarations (house style, kept).
- Tests of a file's private declarations stay beside them; tests of the public
  API go in the module's own test files or in `tests/differential/`.

## Finishing

Commit on your branch, in steps that each pass their tests (one commit per
coherent piece; message: what and why, the oracle, the numbers). Do not push,
do not merge, do not touch `main`. Report: what exists, the oracle and its
result (fixtures compared, agreed, listed in `.xfail` and why), line counts,
and every decision the spec left open and how you took it.
