# vams: tokenizer, Ast, Parse

Read `README.md` first. You own `lib/std/vams/tokenizer.zig`,
`lib/std/vams/number_literal.zig`, `lib/std/vams/Ast.zig` (+ `Ast/`),
`lib/std/vams/Parse.zig` (+ `Parse/`), `tests/differential/parse.zig` and
`tests/differential/parse.xfail`. You may add your names to `lib/std/vams.zig`'s
re-exports and `test` block; leave `Preprocessor` there alone (another agent's).

## What it is

Preprocessed Verilog-AMS (VAMS-2023, which contains IEEE 1364-2005) text in;
a syntax tree out, the way `std.zig.Ast.parse` works: purely syntactic,
context-free, recovering at module-item boundaries, errors kept in the tree.

```zig
const vams = @import("vams");
var tree = try vams.Ast.parse(gpa, source, .{ .keywords = .vams_2023 });
defer tree.deinit(gpa);
for (tree.errors) |e| ... // Ast.Error{ tag, token, extra }
```

## Data (copy Zig's shapes: S = `lib/std/zig/`)

- `Token = struct { tag: Tag, loc: Loc }`, `Tokenizer.next()`, keywords as a
  `std.StaticStringMap(Tag)` (S/tokenizer.zig:3,12,391). One keyword table plus a
  per-word "first set" column for the §10.6/§19.11 keyword sets (`KeywordSet`:
  `v1364_1995 < v1364_2001 < v1364_2001_noconfig < v1364_2005 < vams_2_3 < vams_2023`;
  old: `lib/frontend/keyword.zig`): under an older set the word is an identifier.
- `Ast`: `source: [:0]const u8`, `tokens: MultiArrayList{tag, start: u32}.Slice`,
  `nodes: MultiArrayList(Node).Slice` with `Node = { tag: Node.Tag, main_token: u32, data: Data }`
  (`Data` 8 bytes, asserted), `extra_data: []u32`, `errors: []const Error`
  (S/Ast.zig:20-36, 2830, 2914). `Node.Index = enum(u32)`, node 0 is the root.
- **No strings in the tree.** Identifiers are tokens; text is `tree.tokenSlice(i)`
  (S/Ast.zig:279). Literals are not decoded here: `number_literal.zig` decodes on
  demand (S/number_literal.zig), as AstGen will.
- **No semantic work in the parser.** The old parser folds constants, decodes
  literals, unrolls replication, tracks ~20 mode flags and keeps a table of
  access-function names learned from disciplines (`access_names`). The new one
  does none of that: `V(p, n)` is a call node, `{3{a}}` a replication node, a
  `discipline` body just syntax. Anything the grammar cannot decide alone is
  AstGen's or Sema's. Where the old parser used context to *accept* or *reject*
  text, find the context-free reading that accepts the same corpus and write it
  down; if none exists, list the fixture in `parse.xfail` with the reason.
- Full payload views like `Ast.full.ModuleDecl` (S/Ast.zig `full`) for nodes
  with many children, built from `extra_data` on demand.
- Recursion: expression chains of one precedence loop (S/Parse.zig:1574
  `parseExprPrecedence`), so `a+b+...` costs no depth. Other nesting is bounded
  by `max_depth` (a named constant, at least 10_000: fixtures nest 1,100) and
  past it is `Error.Tag.nesting_too_deep`; tests run the parser on a thread with
  a 256 MiB stack, as `Compilation`'s workers will.

## The grammar

Everything the old parser accepts: VAMS-2023 Annex A plus IEEE 1364-2005 Annex A
(modules and macromodules, connectmodules, ports and port lists, parameters,
localparams, aliasparams, paramsets, nets and variables with ranges and arrays,
branches, natures, disciplines, connectrules, analog blocks and `analog initial`,
analog functions, digital functions and tasks, initial/always, every statement
(blocking, nonblocking, procedural continuous, event controls `@`, `#` delays,
`wait`, case/casex/casez, loops, fork/join, disable, named blocks), generate
regions and loop/if/case generate, module/gate/switch/UDP instantiation with
strengths and delays, UDP declarations and tables, specify blocks, specparams,
timing checks, `config` blocks, `library` source text, attributes `(* *)` on every
item, contributions `<+`, indirect contributions `: ... == ...`, every operator).
Read the old parser to learn exact coverage:
`lib/frontend/{token,keyword,lexer,token_value}.zig`, `lib/frontend/ast*.zig`,
`lib/frontend/parser.zig`, `lib/frontend/parser/*.zig` (8.6k lines; your target
is about 7.5k for Parse, 2.3k for Ast, 1.8k for tokenizer + literals,
`lib/TODO.md` appendix A.1).

## The oracle: `zig build diff-parse`

`tests/differential/parse.zig` (wired already; imports `vams`, the old `frontend`,
`diag`, `base`, and `rewrite_options.fixture_root`). For every `.va`, `.vams` and
`.v` under the fixture root, sorted:

1. Preprocess with the OLD preprocessor (`frontend.preprocessor.process`, with a
   `frontend.Files` on `std.testing.io` and the fixture's own directory as the
   include dir; `std_defs = true`, `spice_primitives = true` for `.va`/`.vams`,
   `std_defs = false` for `.v`). A fixture the old preprocessor rejects is skipped
   (that is the preprocessor oracle's business) and counted.
2. **Tokens:** the old lexer (`frontend.lexer.tokenize`) and the new tokenizer over
   the same text give the same token starts, and tags that map one to one (write
   the mapping table; an unmapped pair is a failure).
3. **Acceptance:** the old parser (as `src/Compilation/analyze.zig` drives it:
   `Parser.init`, `setLanguage(vams_2023)` for `.va`/`.vams`, `.v1364_2005` and
   `digital = true` for `.v`) reports a parse-stage error iff `tree.errors` is not
   empty.
4. **Structure:** for each accepted file, per module in order: the module name and
   the counts of ports, parameters, nets/variables, branches, instances, analog
   blocks, initial/always blocks, functions and tasks are equal between the old
   `Ast.SourceFile.modules[i]` (skip the prelude's leading built-in modules: the
   old file's `builtin_modules` count) and the new tree.

Print each mismatch (fixture, check, old vs new) and fail; `parse.xfail` lists the
allowed ones by fixture path with a reason. Also port the old parser's own unit
tests (`tests/unit/parser_tests.zig`, `lib/frontend/parser*.zig` test blocks) as
spec examples, adapted to the new tree.

## Done when

`zig build test-vams`, `zig build diff-parse` and `zig build check` pass;
`diff-parse` reports how many fixtures it compared and how many `parse.xfail`
lists (each with a reason); `tools/check_style.py` is clean on your files.
