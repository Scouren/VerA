# VerA → Zig-compiler architecture: refactor plan

Status: research done 2026-11-03, nothing implemented. Every file in `src/`, `lib/`, `build/`
(607 files, 212,919 lines) is mapped in the Appendix. Your original brief is kept at the bottom.

Reference used as the "perfect hand-written code": the Zig compiler at the exact commit this repo
pins (`0.18.0-dev.349+d924f83bf`): `lib/std/zig/{tokenizer,Parse,Ast,AstGen,Zir,ErrorBundle}.zig` and
compiler `src/{Compilation,Zcu,Zcu/PerThread,InternPool,Sema,Air,Air/Liveness,Air/Legalize,codegen,codegen/c,link,link/Queue}.zig`.
`Z/` below = Zig compiler `src/`, `S/` = `lib/std/zig/`.

---

## 0. Headline

| | today | target | how |
|---|---|---|---|
| lines in `src/`+`lib/`+`build/` | 212,919 | ~148,000 (−30%) | 8,150 of it is `--explain` prose (irreducible data) |
| moved to `tests/` (test support + public-API tests that ship today) | — | ~12,000 | falsify, mocks, fixtures, ref4, `test` blocks of public APIs |
| elaborators | 2 (`src/elab` analog, `lib/sim/digital/elab_*` digital) | 1 (`src/Sema`) | Zig generic instantiation: re-analyse Vir per `(module, params)` key, no AST cloning |
| constant folders | 5 | 1 (`Sema` comptime eval, `kernels/fold` as oracle) | |
| C printf implementations | 5 | 1 (`kernels/printf`) + libc in libvpi | one of them is a **live bug** (§9) |
| places that read files | 10+ | 1 (`Compilation`) | stages emit read requests |
| copies of the design hierarchy | 4 (elab, digital Run, vpi analog model, vpi digital model) | 1 (`Zcu.instances`) | |
| analysis parallelism | none (`deep_stack` threads join at once) | per file (AstGen) + per instance (Sema) + per artifact (link) | `Compilation` owns the pool |
| runtime that parses Verilog | yes (`.v` exe fallback, mixed exe, libvpi) | never | `lib/std/sim` reads one `Program` table |

---

## 1. Correction to the brief: Zig puts the compiler in `src/`, not `lib/`

Your sketch moves `Compilation.zig`, `main.zig` and the whole frontend into `lib/` with only
`src/main.zig` left. Zig does the opposite, and VerA's current top-level split already matches it:

- `lib/` = what ships and what a user build compiles against. `lib/std/zig/` holds only the *reusable*
  frontend (tokenizer, Parse, Ast, AstGen, Zir, ErrorBundle), because `zig fmt`, ZLS and the build runner
  read it too. `lib/compiler_rt` is runtime and **never contains the compiler**.
- `src/` = the compiler: `Compilation`, `Zcu`, `InternPool`, `Sema`, `Air`, `Type`, `Value`,
  `codegen/`, `link/`, `main.zig`.

VerA's real problem is not the top-level split. It is that compiler code leaked into `lib/`
(`lib/sim/digital` holds a whole second compiler: preprocess, lex, parse, elaborate, compile to
bytecode, 10.3k lines, and 59 of its 60 files import `frontend`) and that stages in `src/` reach
into each other (lowering calls `elab.elaborate`, codegen calls `prove.Analysis.build`, analysis calls
`device.sayRecords`). The plan fixes both.

## 2. Target tree

```
lib/                              # ships; embedded in `vera`; imports nothing from src/
  std/
    vams.zig                      # thin namespace (= std/zig.zig)
    vams/                         # = lib/std/zig: frontend shared by compiler, LSP, runtime readers
      tokenizer.zig               # Token{tag, loc}, Tokenizer, keywords per KeywordSet      (S/tokenizer.zig:3,12,391)
      number_literal.zig          # real/int/string literal decoding                           (S/number_literal.zig:63)
      Preprocessor.zig + Preprocessor/{scan,directive,events,macro,protect}.zig   # no I/O: yields include requests (aro Preprocessor)
      Ast.zig + Ast/full.zig      # ONE node table: Node{tag, main_token, data} + extra_data   (S/Ast.zig:20-25,2914)
      Parse.zig + Parse/{expr,stmt,module,decl,design,prim,udp}.zig                            (S/Parse.zig:18-25)
      AstGen.zig + AstGen/        # Ast -> Vir, one file at a time                            (S/AstGen.zig:143)
      Vir.zig                     # = Zir: instructions MultiArrayList, extra, string_bytes   (S/Zir.zig:26-36,161)
      SysFn.zig                   # ONE system-function table, analog + digital              (S/BuiltinFn.zig)
      Diag.zig + Diag/codes.zon   # ErrorBundle layout + code + severity + fix-its          (S/ErrorBundle.zig:17-19,356)
      render.zig                  # Ast expr printer (today vpi/decompile.zig)               (S/Ast/Render.zig)
      spice.zig + spice/          # netlist cards (emit requests, no reads)
      constants.vams disciplines.vams spice_primitives.vams driver_access.vams   # preludes as real files
    kernels.zig + kernels/        # = compiler_rt + std.math: runtime kernels AND the fold oracle; shipped once, imported by devices
      printf.zig fmt.zig fold.zig rng.zig wide.zig Integer.zig + Integer/ str.zig file.zig ops.zig table.zig filter.zig limit.zig math.zig family.zig ac.zig storage.zig
    contract.zig + contract/      # device ABI, installed (gm/ stays: deterministic libm)
    osdi.zig + osdi/              # OSDI 0.4 dyn (= lib/c.zig: an exported C ABI)
    sim.zig + sim/                # runtime of emitted executables. NO frontend import.
      Program.zig                 # the ONE digital program table (lives in lib for the reason Zir does: a shipped reader)
      State.zig Interp.zig eval.zig scheduler.zig time.zig net/ logic/ dump/ system/ mixed.zig Device.zig snapshot.zig tchk.zig sdf.zig
  vpi/                            # libvera-vpi runtime that C apps link (like libc/compiler_rt): imports {sim, kernels, contract, vpi_c}
    Table.zig Handles.zig traverse.zig property.zig value.zig value_put.zig delays.zig callback.zig callback_fire.zig systf.zig run.zig status.zig analog.zig Binding.zig print.zig varargs.c include/vpi_user.h
src/                              # the compiler
  main.zig                        # argv -> Config.Options; usage text (cli/ folded in, Z/main.zig)
  Compilation.zig                 # the spine: reads, units, job queue, thread pool, Cache, ErrorBundle (Z/Compilation.zig)
  Compilation/Config.zig          # Options -> resolve -> Config                                     (Z/Compilation/Config.zig:18,160)
  Compilation/libmap.zig          # §13.2 library map (reads go through Compilation)
  Zcu.zig + Zcu/PerThread.zig     # File, Module map, Instance table, failed_* maps                   (Z/Zcu.zig:183,863,956)
  InternPool.zig                  # strings, types (real/int{bits,signed}/array), nature, discipline, constants, instance keys (Z/InternPool.zig:1726,1964,3945)
  Type.zig Value.zig Discipline.zig   # thin views over InternPool.Index
  Sema.zig + Sema/{Ssa,decl,expr,control,contrib,syscall,discrete,disciplines,connect,paramset,digital}.zig   # Vir -> Air | Program, ONE elaborator
  Air.zig                         # analog SSA IR (today ir/Mir + opcode table)                       (Z/Air.zig:22-38,1371)
  Air/{Device,Analysis,Interval,Float,Legalize,Setup,Facts,Verify,interp}.zig + Air/digital/{Schedule,StepLocal}.zig   # passes (today prove/ + codegen plan/)
  codegen.zig                     # dispatch: switch (backend) -> generate                            (Z/codegen.zig:154)
  codegen/device.zig + device/{DeclGen,Function,Liveness,tables}.zig (+ subfolders)    # = codegen/c.zig shape (Z/codegen/c.zig:477,719)
  codegen/exe.zig + exe/{Spec,checks}.zig
  codegen/digital.zig  codegen/rtlil.zig  codegen/verilog.zig + verilog/write.zig  codegen/vpi.zig + vpi/code.zig  codegen/osdi.zig
  link.zig + link/{Zig,Server}.zig   # today zigbuild/: File, Task, Queue, std.Build.Cache             (Z/link.zig:397, Z/link/Queue.zig)
  lsp.zig                         # drives Compilation.update per document
  vpi_host.zig                    # libvpi `main`: one Compilation per design
  dynlib.zig
```

File counts per area (from the maps): analog 68 → 8 Sema files, device codegen 76 → ~16, prove 27 → 9-11, vpi 45 → ~20, lib/sim/digital 60 → runtime-only files under `lib/std/sim`.

## 3. The stage contract: one fixed input, one fixed output, `Compilation` owns everything else

Rule (your constraint): a stage is a pure function over ONE fixed input and writes ONE fixed output.
It never reads a file, never spawns a thread, never touches a sibling's or an earlier stage's
structures. `Compilation.zig` alone streams source, divides code units, queues jobs and decides
how many run at once. This is exactly Zig: `Zcu/PerThread.zig:356 workerUpdateFile` runs
read → parse → AstGen per file inside an `Io.Group`, caches ZIR by file stat/hash (`:606`, `:657`),
and discovers imports from ZIR (`:394`) to queue more files; Sema only ever sees `code: Zir`.

| # | job | fixed input | fixed output | parallel unit | Zig mirror |
|---|---|---|---|---|---|
| 1 | `read` | path (+ include/spice/table/libmap requests) | bytes in `Zcu.File.source` | per file, I/O only here | `PerThread.updateFile` |
| 2 | `preprocess` | file bytes + macro state from the previous file | pp text + `Directives` + include requests | **serial** in command-line order (§3.1) | aro `Preprocessor` |
| 3 | `astgen` | one file's pp text | `Ast` then `Vir`, cached by hash(pp text, macro-state digest) | **per file** | `AstGen.generate` (`S/AstGen.zig:143`) |
| 4 | `sema_top` | every `Vir` + `Config` | `Zcu.modules`, `Zcu.instances`, defparams, Annex F table, connect inserts | serial (one pass over a table, no dry/seed walks) | Zcu analysis roots |
| 5 | `sema_instance` | one `Vir` module decl + one `Instance.Key` | `Air` (analog) or `Program` rows (digital) | **per instance key** | `Sema` per `AnalUnit` |
| 6 | `air_passes` | one `Air` | `Air'` + `Air.Facts` + `Float.Verdict` | per `Air` | `Air/Liveness`, `Air/Legalize` |
| 7 | `codegen` | `Air` + `Facts` + `Verdict` (or `Program` + `Schedule`) | text rows in `link.Output` | per backend × artifact | `codegen.generateFunction` |
| 8 | `link` | `link.Output` | artifact (`.so`, `.osdi`, exe) | `link.Task` queue, bounded by `thread_limit` | `link/Queue.zig` |
| 9 | `errors` | `Zcu.failed_*` maps | `Diag` bundle | end of update | `Compilation.getAllErrors` (`Z/Compilation.zig:3829`) |

### 3.1 A Verilog compilation unit is not a file

`define`, `timescale` and `default_nettype` carry from file to file (IEEE 1364 §19), and today spans
are offsets into one concatenated text (`lib/frontend/preprocessor.zig:229-258`). So:
- Preprocess stays **serial** over the ordered file list. It is cheap (a byte scan).
- Everything after it runs **per file in parallel**. The AstGen cache key = hash(pp text) + digest of the
  macro state the file started with, so an edit to file A re-runs B only if A changed a macro B uses.
- Spans become `(File.Index, offset)`; the macro source map moves from `diag.Bag` to `Preprocessor.Output`.

### 3.2 `Compilation` (src/Compilation.zig)

```zig
gpa: Allocator,
io: Io,
arena: std.heap.ArenaAllocator,      // replaces BigArena + Result.arena + compile's `arena` param
config: Config,                      // replaces cli.Cli (60 fields) + Settings + Request + args.Settled
zcu: Zcu,                            // replaces Result.{file,module,unit_paths} and elab.Design
cache: *std.Build.Cache,             // replaces artifact_cache.zig (64-bit Wyhash, full re-read), global_cache.zig, the prelude snapshot
thread_limit: u32,                   // NEW `-j`; sizes every Io.Group (Z/main.zig:3553-3557)
stack_size: usize = 256 << 20,       // workers get one big lazily-committed stack (Z/main.zig:41); replaces deep_stack.zig
mutex: Io.Mutex = .init,             // guards zcu.failed_* and queue appends (Z/Compilation.zig:244)
queue: std.ArrayList(Job) = .empty,  // replaces the hard-coded step order in compile() and analyze.stages()
link_queue: link.Queue,              // replaces zigbuild/library.zig spawning 3+64 zig processes at once
outputs: Outputs = .{},              // replaces Outcome; printing stays main's

pub const Job = union(enum) {
    read: Zcu.File.Index, preprocess: Zcu.File.Index, astgen: Zcu.File.Index,
    sema_top, sema_instance: Zcu.Instance.Index, air_passes: Air.Index,
    codegen: struct { backend: codegen.Backend, air: Air.Index }, link: link.Task,
};
pub fn create(gpa: Allocator, io: Io, config: Config) !*Compilation;   // Z/Compilation.zig:1714
pub fn update(comp: *Compilation) !void;                                // Z:2751 -> performAllTheWork Z:4360
pub fn getAllErrors(comp: *Compilation) !Diag;                          // Z:3829 getAllErrorsAlloc; replaces bag detach (analyze.zig:79-119)
```

One `update` serves all three entry points that exist today (CLI `compile`, LSP calling
`vera.analyze` directly, the `.v` route through `cli/digital.zig` that bypasses `Compilation`).
Shape cards (§3.4) stop re-running the whole pipeline (`Compilation.zig:240-252`): with
`Instance.Key = (module, params)` only `sema_instance` re-runs.

### 3.3 `Zcu` (src/Zcu.zig)

```zig
files: std.MultiArrayList(File),                       // replaces the one concatenated text + Ast overlay chains
modules: std.AutoArrayHashMapUnmanaged(InternPool.String, Vir.Decl.Index), // last-wins insert; replaces findModule/lastNamed scans
instances: std.MultiArrayList(Instance),               // replaces Design.units, Flatten.Unit chain, walk.Tree, segment.State,
                                                       //   digital Run.hier, vpi model_analog/model_digital hierarchies
instance_map: std.AutoHashMapUnmanaged(Instance.Key, Instance.Index),
defparams: std.AutoHashMapUnmanaged(struct { Instance.Index, InternPool.String }, Vir.Inst.Ref),
net_discipline: std.AutoHashMapUnmanaged(struct { Instance.Index, InternPool.String }, InternPool.Index), // ONE Annex F table (today 6 files, ~2,700 lines)
intern_pool: InternPool,
top: Instance.Index,
failed_files, failed_instances: std.AutoArrayHashMapUnmanaged(_, Diag),

pub const File = struct {
    path: []const u8, kind: enum { vams, v1364, spice_netlist, prelude }, lib: InternPool.String,
    status: enum { never_loaded, retryable_failure, astgen_failure, success },
    hash: Cache.BinDigest, source: ?[:0]const u8, tree: ?Ast, vir: ?Vir, directives: Directives,
};
pub const Instance = struct {       // Zig: a generic instance keyed by owner + comptime args (Z/InternPool.zig:9537)
    module: Vir.Decl.Index, file: File.Index, parent: Index, name: InternPool.String,
    params: InternPool.Index,       // folded tuple: overrides + defparams applied
    paramset: Vir.Decl.OptionalIndex, gate: InternPool.Index, hier: [6]InternPool.Index,
    ports: struct { start: u32, len: u32 },
    pub const Index = enum(u32) { top = 0, none = std.math.maxInt(u32), _ };
    pub const Key = struct { module: Vir.Decl.Index, params: InternPool.Index };
    pub fn fmtPath(i: Index, zcu: *const Zcu) Formatter; // path rendered on demand; no flat-name strings, no `sep` splitting
};
```

## 4. Answers to the brief's open questions

**Do we need AstGen? (comptime behaviour)** Yes. Verilog elaboration *is* Zig comptime: parameters,
localparams, `generate` for/if/case, genvars, constant functions, defparam, paramsets. Zig splits
the work in two:
- Per-file and untyped (AstGen → Vir): local scopes and block/function hiding, generate-scope naming
  (`genblk<n>`), port directions §6.5.2.2, alias source check, UDP §8.1.1, annex C.4, wreal structure,
  the positional directive in force on each decl, the discrete-context mark, `SysFn.Tag` on each call.
- Cross-unit (Sema): pick top, module namespace, overrides/defparams, paramset selection, generate
  evaluation, port binding, Annex F, connect-module insertion, `$mfactor`/§9.18/§9.19, hierarchical names.

Why it matters: elab clones every child's AST once per instance (`clone_*.zig`, 1,031 lines) and
walks the tree up to 3 times (seed, dry, real: `elaborate.zig:84-117`), because its output is an AST
that a second walker (lowering) reads. Zig never copies ZIR: an inline call swaps `inst_map` and
points Sema at the callee's ZIR (`Z/Sema.zig:7270-7300`). Order: fuse elab into lowering as one Sema
first (kills cloning), then add Vir (adds caching, parallelism, one input for analog, digital and LSP).

**Do we need Sema? (typing)** Yes. Verilog-AMS is statically declared but expression widths and
signedness are context-determined (§5.4/§5.5), which is Zig's result-type inference; plus
real↔integer coercion (§4.2.1) and discipline resolution (§7.4.4, Annex F). Today three type enums
say "real/integer/string" (`base.Type`, `Lowered.Ty`, `callee_table.Ty`) and the wide width is stored
in five more places; they become one `InternPool.Index` with `Type.zig` as the view.

**Codegen lightweight?** Yes, once the semantic planning leaves it. Today ~4.4k lines of
`codegen/device/codegen/plan/*` decide W0853, E0519/E0520, E0531, charge sites, topology: those move
to `src/Air/` passes and arrive as read-only `Air.Facts`. Codegen keeps Liveness-like slicing and
text. Zig's C backend is 2 files (`c.zig` 8.1k, `c/type.zig` 1.2k); VerA's device backend is 76.

**Where does `prove/` go?** Not under Sema: Zig puts post-Sema passes in `src/Air/` (Liveness,
Legalize, Verify). See §6.

**Diagnostics "an identifier for each".** Keep the coded catalogue (AGENTS requires coded
diagnostics), but as data: the 22 `codes/class*.zig` files become one `Diag/codes.zon` and `Code` is
reified from its keys (deletes the duplicate `names` list, `code.zig:67-181`). Storage follows
`S/ErrorBundle.zig` (`string_bytes` + `extra` + `Wip`), plus code/severity/fix columns it lacks.
Parse errors become `Ast.Error{tag, token}` like `S/Ast.zig:2830`. The Bag stops owning the file
table and the macro map (those are `Zcu.File` and `Preprocessor.Output`).

**"Run in parallel on each code unit, not each Verilog module".** Yes, and §3 is that. Units = files
after the serial preprocess; Sema parallelism is per instance key; link parallelism is per artifact
part. All three pools are `Compilation`'s.

## 5. New structs and what each one controls

| struct | file | controls | replaces (today) | Zig mirror |
|---|---|---|---|---|
| `Token`, `Tokenizer` | lib/std/vams/tokenizer.zig | lexing, keywords per `KeywordSet` | lexer.zig, token.zig, keyword.zig (already Zig-shaped; `Lexer.Seed` deleted) | S/tokenizer.zig:3,12,391 |
| `Preprocessor`, `Preprocessor.Output` | lib/std/vams/Preprocessor.zig | `define/`include/`ifdef/annex D-E; yields include requests | preprocessor.zig, pp/* (file reads via a hidden global `io` deleted) | aro Preprocessor.zig:28,3470 |
| `Ast`, `Ast.Node`, `Ast.Error` | lib/std/vams/Ast.zig | parse tree, SoA, no strings, read-only | ast.zig + ast_expr (SoA) + ast_stmt (AoS union pool) + ast_decl (`ModuleDecl` with 22 slices) + overlay/continuing chains | S/Ast.zig:20-25,2830,2914 |
| `Parse` | lib/std/vams/Parse.zig | parser state, recovery | parser.zig (~30 fields, 20 mode flags) + parser/* ; folding/literal decoding leave it | S/Parse.zig:18-25,208,1574 |
| `AstGen`, `GenVir`, `Scope` | lib/std/vams/AstGen.zig | per-file desugar + local name resolution | clone_decl `hide`, generate naming, discrete_mark, port directions | S/AstGen.zig:143,11121,11291 |
| `Vir`, `Vir.Inst`, `Vir.Inst.Ref` | lib/std/vams/Vir.zig | untyped per-file IR, cacheable | the AST overlay that elab and the sim append to | S/Zir.zig:26-36,161,2233 |
| `SysFn` | lib/std/vams/SysFn.zig | every `$`-name → tag + arity/type/context/opcode | ir/callee.zig, callee_table, analog/sysfunc_context, sim/digital/system_functions, elab/dist, math.zig tables, 108 `eql(name, "...")` | S/BuiltinFn.zig |
| `Diag`, `Diag.Wip` | lib/std/vams/Diag.zig | diagnostic rows, levels, render, JSON | diag/{bag,builder,entry,level,render,json,suggest,code}.zig | S/ErrorBundle.zig:17-19,178,356 |
| `Compilation`, `Config`, `Job` | src/Compilation.zig | the spine (§3.2) | Compilation.zig + Compilation/* + cli/{Cli,analog,digital,args.resolve} | Z/Compilation.zig |
| `Zcu`, `Zcu.File`, `Zcu.Instance` | src/Zcu.zig | what was analysed, from where, what failed | elab.Design (19 side tables), Flatten.Unit, Result, Run.hier | Z/Zcu.zig:183,863,956 |
| `InternPool`, `.Index`, `.String` | src/InternPool.zig | every string, type, constant, nature, discipline, instance key | base/interner.zig, Mir.strings + consts + fconst/iconst maps, `Lowered.disciplines` StringHashMap, string-keyed maps in Design | Z/InternPool.zig:1726,1964,3945 |
| `Sema`, `Sema.Block` | src/Sema.zig | elaboration + lowering per instance; comptime folding at emit | analog/Lower.zig (68 fields, ~25 hand-restored context flags), elab/*, sim/digital/elab_* + compile* | Z/Sema.zig:40-71,351 |
| `Air`, `Air.Inst{tag,data}`, `Air.Inst.Ref` | src/Air.zig | analog SSA; result Ref = inst index; constants interned | ir/Mir.zig (25 B/row + Value table + alias union-find) → 9 B/row | Z/Air.zig:22-38,1249,1371 |
| `Air.Device` | src/Air/Device.zig | per-instance device tables codegen reads | the per-instance half of ir/Lowered.zig (55 fields, 4 owners) | (none; Zig keeps it in IP) |
| `Analysis`, `Float`, `Legalize`, `Setup`, `Facts`, `Verify` | src/Air/*.zig | fact tables, float verdict, if-conversion, setup tiers, topology/limit/noise/qsite facts | prove/* (27 files) + codegen/device/codegen/plan/{limit,noise,qsite,topology} | Z/Air/Liveness.zig:142, Legalize.zig, Verify.zig |
| `Program` | lib/std/sim/Program.zig | the digital design as one table: Inst/Expr/Slot/Proc/Sub/Scope/Fmt rows | sim/digital bytecode.Program (holds `Ast.ExprId`), expr_types.Typing, Run.{hier,decls,routines,netlist}, rt.Design | Zir/Air row+extra idiom |
| `State`, `Interp` | lib/std/sim/{State,Interp}.zig | run state over `*const Program`; one engine | digital/Run.zig (god struct) + rt/State.zig (two state structs) | — |
| `codegen.Backend` + `DeclGen`, `Function`, `Liveness` | src/codegen.zig, codegen/device/ | one emitter per backend | Gen.zig (~50 fields, 15 plan tables), prepare, file, render*, cfg, unit*, call*, cg_* | Z/codegen.zig:154, c.zig:477,719 |
| `link.File`, `link.Task`, `link.Queue` | src/link.zig | per-part objects, cache, bounded spawns, final link | zigbuild/{library,artifact_cache,check,exe,argv,shim,tree} | Z/link.zig:397,1505, link/Queue.zig |
| `vpi.Table`, `vpi.Handles` | lib/vpi/{Table,Handles}.zig | the VPI object model as one emitted SoA table; one handle range | schema.Obj (200 B AoS), Design.zig, 7 handle registries | link/Dwarf.zig → std.debug reader |

## 6. `prove/`: why it is bulky and how small it gets

What it actually is (measured): 9,016 lines = 4,902 code + 1,773 doc + 1,881 test + 460 blank, and
~700 of the code is test oracles (`falsify.zig`, verify breakers, transfer helpers). The ~4,150
shipped lines are **five unrelated jobs** sharing one directory:

| job | files | shipped code | target |
|---|---|---|---|
| codegen's fact tables (CFG, per-value types/deps/folds) | Analysis, cfg, postdom, value_types, deps, folds | ~1,185 | `Air/Analysis.zig` (= Liveness: tables read by codegen) |
| float verdict + §4.3.2 domain diagnostics | proof, Prover, seed, guards, walk, domain, message, verdict, Interval, transfer | ~1,460 | `Air/Float.zig` + `Air/Interval.zig` |
| if-conversion | ifconv, revisit | ~510 | `Air/Legalize.zig` |
| setup tiers (invariance, timepoint, held) | setup, invariance, timepoint, held | ~630 | `Air/Setup.zig` |
| MIR verifier (Debug only) | verify | ~330 | `Air/Verify.zig` (= Z/Air/Verify.zig, 468 lines) |

The prover proper is already ONE forward pass (`walk.zig:52`, dominator preorder, lattice
`Interval{lo,hi,lo_open,hi_open,nonzero} × finite`) plus ONE backward slice per unit (`verdict.zig:28`).
There is no smaller algorithm that decides the same verdicts. The bulk is fragmentation + tests + the
CFG it has to rebuild because Air is a CFG with phis.

**Step A (byte-identical, 27 files → 9-11 under `src/Air/`, ~4,880 lines):** merge by job; one
`Csr(T)` replaces 9 pool/offset pairs; one generic CHK `dominators(dir)` replaces two copies;
`xdeps`/`pdeps` (full `nv × dep_words` u64 columns read only as "any bit set") become 2 bits per
value; `controlDeps` built once instead of at 3 call sites; `input.zig` and `root.zig` deleted;
oracles move to `tests/`. Proof: `zig build suite -- golden before` on main, then an empty
`golden diff` after every PR.

**Step B (the "much simpler" version, ~3,000 lines, plus ~1,000 fewer in analog + codegen):** make
Air structured like Zig's (`block` with result + `br`, `cond_br` with two bodies, `loop`) instead of
a CFG with phis. Verilog-A is structured already: no goto; `&&`/`||`, case, while, for and events nest.
Today the compiler lowers structure to a CFG (`analog/ssa.zig`, `dom_tree.zig`), rebuilds it in
`prove/cfg.zig` + `postdom.zig` (~860), then re-structures it in `codegen/device/codegen/cfg.zig`
("Beyond Relooper", 536) + `plan/branches.zig`. With structured Air:
- dominance = nesting; steering and control deps = the stack of enclosing `cond_br`s → the CFG half of Analysis is deleted;
- Float walk = recursive descent that pushes a guard fact entering a `cond_br` body, pops on leaving; a block result = the interval hull of its `br` operands (this answers the "prove needs phis" objection);
- Legalize = "a `cond_br` with pure bodies yielding one block result → `select`", one post-order recursion, no fixpoint, no worklist (613 → ~150);
- codegen's relooper disappears: Air is already structured text-shaped.
Cost: device text changes (labels, value numbering), so goldens are re-baselined against behavioural
oracles (conformance 6818/6818, the `.sp` decks, `falsify`, ngspice external), not byte diff.

Also: `verify.zig` and `falsify.zig` are oracles, not shipped logic. Verify stays (Debug-only, as in
Zig); falsify moves to `tests/` and gets one shared `Air/interp.zig` with `codegen/verilog`
(there are two MIR interpreters today).

## 7. Linking (your item 4), and the LLVM question

**What exists.** `zigbuild/library.zig` already splits a device into up to 3 parts + 64 setup chunks and
links them, but spawns them all at once (`:206`, no bound), keys the cache with a 64-bit Wyhash that
re-reads every module file (`artifact_cache.zig:73,148`), and runs `zig` three different ways
(Server, `process.run`, spawn + watchdog) with two argv builders.

**Per-unit objects do not work as stated.** Analog units are `fn u(comptime S: type, ...)`: generic over
the host's family `S`, so they have no object code until the host's `dyn` fixes `S`. And eval inlines
core on purpose (the emitted comment measures +43% when out of line). The workable cut:
- one object per **device part** (`contract.DevicePart`: setup, state, eval), each its own module whose
  imported text closure is its `std.Build.Cache` key (`Z/Compilation.zig:5434 updateCObject` pattern);
- kernels compiled **once per vera version** as a prebuilt object (`Task.build_kernels`; the
  `buildEngine` path for `.v` devices already does this = compiler_rt's `.obj` strategy, `Z/Compilation.zig:5175`);
- `-fincremental` with `u/<unit>.zig` files stays the per-unit reuse;
- every spawn goes through `link.Queue`, sized by `Compilation.thread_limit`.

```zig
pub const Task = union(enum) {
    write_tree, build_obj: struct { part: contract.DevicePart, key: Cache.BinDigest },
    build_kernels, link, check,
};
```

**Kernels ship once, like compiler_rt.** 71% of every emitted device is fixed kernel text spliced in
(diode.va: lines 1-656 of 949; up to ~235 KB per device). As a shipped `kernels` module/object:
`prelude.zig`, `kernel_text.zig`, `unit_file.zig` and the `wideText` string-replace go (509 lines), and ~1,000 lines of kernels-in-string-literals become real, type-checked Zig;
`fn Family(comptime n_u: u16) type` replaces text widening; `kernels/fold.zig` calls the same `math`
functions the device runs, so the fold oracle *is* the kernel. **Downstream:** ESPice must install
`share/vera/kernels/` beside `contract/` (a pinned-consumer change; CONTRIBUTING's pin policy applies).

**Emit LLVM directly?** Not first; later, as a second backend behind `codegen.zig`, never a replacement.
- No libLLVM link needed: `zig cc -O2 -c t.ll` with the pinned toolchain compiles hand-written IR
  (verified), and `std.zig.llvm.Builder` (pure-Zig bitcode writer, ~20k lines in std) is what Zig's own
  `src/codegen/llvm.zig` uses.
- "Lose Zig-specific optimizations" is mostly false: in ReleaseFast Zig's optimizer *is* LLVM.
- Real gains: per-instruction fast-math flags (`nnan ninf contract`), finer than `@setFloatMode` per
  scope, so the float verdict can relax per op; `DILocation` debug info that points at `.va` lines
  (step through Verilog-A in gdb — the biggest debugging win available); no Zig analysis of the
  generated text (compile time; unmeasured).
- Real losses: Debug safety checks in generated devices (bounds, overflow, `unreachable`), readable
  Zig goldens, free use of `lib/std/{kernels,contract,sim}` (they become a linked object with
  hand-declared signatures).
- Order: one Air + `codegen.zig` dispatch first (Zig itself keeps `codegen/c.zig` and `codegen/llvm.zig`
  side by side over one Air); keep the Zig-text backend as the oracle; add `codegen/llvm/`; run both
  over the conformance suite; switch the default only on measured numbers (`zig build-obj` time per
  device vs `zig cc` on `.ll`, device speed with per-op flags).

## 8. The digital side and VPI

- `vera --run`, `--emit-exe`, `.v` devices and `--emit-rtlil` are three pipelines today: the
  interpreter's own compiler in `lib/sim/digital`, a native emitter that reads the interpreter's
  mutable `Run` (43 sites mutate `r.scope`), and RTLIL that re-preprocesses and re-parses with its own
  folder and symbol table. Target: one Sema writes one `Program`; the interpreter, `codegen/digital`
  and `codegen/rtlil` read it (rtlil groups by `Scope.spec`, which also fixes per-override modules).
- Runtime never parses: today any one of 171 `refuse(` sites in codegen/digital makes the exe embed
  the whole source and run the interpreter (`program.zig:83-105`); mixed exes call
  `sim.digital.elaborate` at startup (`mixed_tail.zig.txt:69`). Target: per-process fallback
  (`Dispatch` calls `Interp.step(pc)` over the same `Program`).
- Expressions get lowered: today `Instruction` rows hold `Ast.ExprId` and every identifier read
  hashes `(ExprId, scope)` into a memo at run time (`name_search.zig:163-170`). Target: typed, bound
  `Program.Expr` rows; three AST walkers that "must agree arm for arm" become one table.
- One engine: `Run` (heap `Int.Literal` per value) and `rt/State` (u64 planes) merge into
  `sim.State` over planes; waiters, resolution, evcd, monitor, system, NBA, activations stop existing twice (~3.5k lines).
- VPI: one emitted `vpi.Table` (SoA row ≤32 B instead of a 200 B `Obj`; 3 tagged CSRs; sparse existence
  tables) written by `codegen/vpi.zig` from Sema output, like `link/Dwarf.zig` writes debug info for
  `std.debug`. One `Handles` range replaces 7 registries and stops stale handles aliasing recycled
  pointers. `vpi_user.zig` + `abi.zig` (1,277 hand-translated lines) become `b.addTranslateC`
  (`std/Build.zig:953`). The host compiles each design once, not 2-3 times.

## 9. Bugs and hazards found during the mapping (fix first, independent of the refactor)

1. **`$display` real formatting disagrees between host and device (wrong text, no crash).**
   `lib/contract/c_format.zig:209 cReal` renders through `std.fmt.float.render`, which rounds half away
   from zero. Verified on the pinned toolchain: `%.0f` of 2.5 → `3` (C: `2`), `%.1f` of 0.25 → `0.3`
   (C: `0.2`), `%.2e` of 1.125 → `1.13e+00` (C: `1.12e+00`). `kernels/str_real.zig zCReal` is correct and
   documents why. `tests/printf_reference.zig` only covers `zCReal`. Fix: delete c_format's renderer
   (~190 lines), call `zCReal`; point the printf reference oracle at `formatC` too (the oracle that
   would have caught the class). `src/vpi/cformat.zig` is a third copy (→ libc `vsnprintf`). **Fixed on `refactor` (§12).**
2. Hot-path allocation in emitted exes: `rt/logic/operators.zig:392` builds an `ArenaAllocator` per wide
   `* / % **`; `kernels/wide_kernels.zig zwL` already has the non-allocating version.
3. Test support ships in every `vera` binary (`simSources` embeds all of `lib/`): `mock_devices`,
   `osdi_dyn/fixture`, `ref4`, `integer_fixture`, `falsify`, `expectRun` helpers.
4. `wreal.check` runs twice per compile (`analyze.zig:223`, `elaborate.zig:61`).
5. A compiler module depends on test inputs: `elab` gets conformance fixtures as anonymous imports
   (`build/common.zig:89-92`).
6. Two owners of the unknown vector: `codegen/device/codegen/plan/names.zig:33` appends branch-current
   unknowns after lowering already allocated flow unknowns (`analog/node.zig:333`).
7. Codegen re-parses its own output: `setup_chunk.zig` (947) counts braces; 38 sites scan emitted text
   with `std.zig.Tokenizer` to learn facts the renderer already had.

## 10. Migration order (main stays green; every step is one or more PRs)

Oracle per step: **G** = `golden diff` empty against a `golden before` snapshot of main (byte-identical
emitted text + full diagnostic stream). **B** = re-baselined goldens, held by conformance 6818/6818, the
`.sp` decks, `falsify`, ngspice external.

| step | what | oracle | size |
|---|---|---|---|
| 0 | §9 bugs 1-2, 4-5 with their regression tests | new tests red first | small |
| 1 | Move test support and public-API `test` blocks out of `lib/`/`src/` into `tests/` (~12k lines); delete re-export-only roots | G | mechanical |
| 2 | Diag: 22 code files → `codes.zon`; ErrorBundle layout; file table/macro map out of Bag | G | medium |
| 3 | `Compilation` owns I/O: read requests from preprocessor/spice/table_model/libmap/`.hdl`; `Config` merges Cli+Settings+Request; `std.Build.Cache`; `link.Queue` bounded by `-j`; one zig-runner path | G | medium |
| 4 | Frontend to Zig shape: one `tokenizer.zig`; one Ast node table; parser stops folding; prelude as `.vams` files; `deep_stack` → big-stack workers + depth cap | G | large |
| 5 | Fuse `src/elab` into lowering as one `Sema` with `Zcu.instances` + `InternPool`; delete `clone_*`, seed/dry walks, flat-name splitting; one Annex F table | G | large |
| 6 | AstGen + Vir, per-file parallel + cached | G | large |
| 7 | Digital onto the same Sema → `lib/std/sim/Program.zig`; delete `lib/sim/digital` elab/compile; native, interpreter and RTLIL read `Program`; runtime drops `frontend` (assert by import list) | G | largest |
| 8 | `Mir` → `Air` layout; `prove` step A into `src/Air/`; codegen reads `Air` + `Facts` + `Verdict` only; planning passes move upstream; delete `setup_chunk` and the text scans | G | large |
| 9 | Kernels as a shipped module/object; device text loses ~31 KB each; per-part objects | B (device text changes) + ESPice coordination | medium |
| 10 | Structured Air (`prove` step B); delete the relooper | B | large |
| 11 | One runtime `sim.State`; `vpi.Table` emitter; translate-c for `vpi_user.h` | G for run transcripts, B for VPI layout | large |
| 12 | Optional `codegen/llvm/` behind the dispatch, compared against the Zig-text backend | differential, both backends | later |

Steps 1-3 change no data shapes and can start now. 5 must precede 6 (fusing removes the reason
for cloning; Vir then adds caching). 7 depends on 5. 10 depends on 8.

## 11. Decisions (settled 2026-11-03)

1. **≤500-code-line rule: bent for files that are one struct** (`Sema.zig`, `Sema/*.zig`,
   `Air/Analysis.zig`, `Air/Float.zig`, `sim/State.zig`, ...), as Zig keeps them. `check_style.py`
   needs the exemption before the first such merge; the 128 forwarders in `rt/State.zig` can then go.
2. **Nesting depth: a fixed cap is accepted.** Big-stack workers (256 MiB, lazily committed) + a
   parse depth cap with its own code; binary chains loop, so they cost no depth.
3. **Structured Air (step 10): yes**, with every device golden re-baselined against the behavioural oracles.
4. **Kernels ship as a module (step 9): yes**; ESPice installs `share/vera/kernels/` beside `contract/`.
5. **`Contents:` lists stay** (AGENTS.md house style). The LOC estimates in the maps that counted
   deleting them (~593 lines in analog+ir, ~834 in `lib/sim/digital`, more elsewhere) are therefore
   high by roughly 2,000-3,000 lines; the target is ~150k, not ~148k.
7. **Air variables are slots, not phis** (2026-11-03, from building `Air`): structured Air with
   no phis cannot carry a variable across loop iterations or merge several out of an if/else, so,
   as in Zig's Air, a variable is a slot: `alloc` (its type), `load`, `assign` (no result). Block
   results via `br` stay for expression merges (`?:`, `&&`, `||`). Sema needs no SSA builder
   (Appendix A.3's `Sema/Ssa.zig`, ~1,060 lines, disappears); the float pass joins slot states at a
   block's exit and widens at a loop. A slot is a `var` in the emitted Zig, which LLVM promotes.
8. **The hand-written math kernels become Gompute 2.0.0** (`git@github.com:OmarSiwy/Gompute.git`,
   tag `v2.0.0`, commit `70b722d`; its `gompute.math` is device-safe math), when the kernels become
   a shipped module (step 9). In scope: `lib/contract/gm.zig` + `gm/` (fma-free exp/log/pow and the
   musl/ARM ports, 1,906 lines) and the math half of the spliced kernel text (`kernel_text/math.zig`).
   Pinned in `build.zig.zon` by commit and content hash (AGENTS.md). The contract is installed for
   hosts, so ESPice resolves the same Gompute. Oracle before the swap: Gompute's results equal `gm`'s
   bit for bit over `gm`'s test corpus and the constant folds (`kernels.fold`, `prove`'s transfers), or
   each difference is bounded by both libraries' documented ulps and listed by name; host, NVPTX and
   AMDGCN still round alike (the reason `gm` exists).
9. **The float verdict is proven, never assumed** (2026-11-03). The old prover (and the first
   port, `src/Air/Float.zig`) assumed `+ - * /`, `%`, `hypot` on finite operands never overflow;
   under `@setFloatMode(.optimized)` an overflow is poison, so a diverging Newton iterate could
   come out a finite wrong number. Fast-math is a measured gain, so it stays, but: sound,
   outward-rounded intervals with ±inf; bounds as inputs (declared parameter ranges,
   `--unknown-bound` or a measured default for unknowns); every `.optimized` verdict carries the
   input box it assumed, and codegen emits a **versioned unit** (an entry check of the box, then
   the fast-math body, else the strict body), so the fast path's precondition is checked. Per-op
   flags (`nnan`/`ninf` without `contract`/`reassoc`, which change rounding against `gm`'s
   cross-target determinism) wait for the LLVM backend. A deliberate behaviour change: devices
   re-baselined with §11.3's. The old pipeline keeps the unsound rule until the switch-over.
   Spec: `docs/rewrite/float-guard.md`.
10. **Scratch arrays: a written-element mask, not a memset, in the rewrite's codegen only**
    (2026-11-03, from ESPice's bsource.va: the per-eval zeroing of a 1152 B stack was 3.5% of a
    benchmark's cycles). VAMS §3.2 makes an unwritten element read 0, and a stack indexed by a
    moving pointer cannot be proven written-before-read, so the old codegen's memset stays in the
    shipped product (ESPice uses `(* vera_scratch = "uninit" *)` plus a guard meanwhile: -7.4%).
    The new codegen gives each scratch array of at most 64 elements a bitmask of written elements;
    a read of an unwritten one returns 0, every write sets its bit, and the per-eval reset clears
    one word instead of the array. Exact §3.2 semantics, no attribute, no undefined behaviour.
    Oracle: bit-identical device results against the memset version on every fixture with a
    scratch array, plus a codegen test that no memset is emitted; measured on bsource.va
    (hand-deleted memset: -17%, the ceiling). When it lands, tell the ESPice session (espice-8a):
    ESPice's branch dev/bsource-uninit (d6796553) then drops the attribute and keeps the guard.
6. **VPI runtime goes to `lib/vpi/`** (Zig's rule: what a user's program links ships in `lib/`);
   only the host driver (`src/vpi_host.zig`) and the emitter (`src/codegen/vpi.zig`) stay in `src/`.

## 12. Progress (branch `refactor`)

**Target: the rewrite ships as v0.30.0.** It lands on `main` through one gated pull request once
the new pipeline compiles the conformance suite end to end (6818/6818), the goldens re-baselined
for §11.3/§11.9/§11.10 are reviewed, and the old pipeline is deleted. The release follows
`CONTRIBUTING.md` (release-prep: the measured changelog, every target built, every artifact
checked, the bundle smoked). ESPice bumps its pin after it.

- [x] Step 0, bug 1: `formatC` printed reals through `std.fmt.float`. Red first: the new
  `tests/printf_reference.zig` test "the host's formatC = snprintf" failed 16,306 of 92,432
  conversions. Fix: `str_real.zig` moved into the contract (a leaf module, so no cycle with
  `kernels`, and installed hosts reach it), `formatC`'s real path is `zCReal` + `writePadded`, the
  `std.fmt.float` renderer is deleted. The same alignment fixed `%r`: the host printed `2.2k` and
  `%.2r` of 999.996 as `1000.00` where the device prints `2.2K` and `1.00K`. Spliced device text is
  byte-identical (the file's device-text half is unchanged). `zig build test-printf` runs the oracle alone.
  Issue #132.
- [ ] Step 0, bug 2 (deferred to step 11): the per-call arena in `rt/logic/operators.zig:392`.
  Replacing it with `wide_kernels.zwL` touches 4-state X, divide-by-zero and §5.1.5's power table;
  it needs a differential oracle against `Integer.Literal` and a benchmark (AGENTS.md: a speed
  claim cites one). It lands with the runtime merge.
- [x] Step 0, bug 4: `wreal.check` judged once (`analyze.zig`); elab's copy could report nothing.
- [x] Step 0, bug 5: the two Annex F fixtures are anonymous imports of `elab`'s test twin only
  (`build/common.zig` `testRoot`), not of the exported module.
- [x] Step 3 (part): `zigbuild` split builds keep at most `Options.jobs` `zig` children alive
  (default: CPU count; was every piece at once, up to 67). Oracle: 1 job and N jobs give the same
  library bytes (`tests/unit/zigbuild_tests.zig`). `Options.jobs` becomes `Config.thread_limit` (`-j`)
  when step 3 merges the config types.
- Step 1 is folded into the steps that rewrite each subsystem: several tests that use
  `contract/mock_devices.zig` also check private declarations (`lead.region`'s signature helpers,
  `validate`'s allowlist and shape rules), so a mass move gains little; each step moves its own tests.
- [x] Step 3 (part): `Compilation/Config.zig` replaces `Settings`, `Request` and `Request.Build`
  (one flat value, same field names; `analyze` and `compile` take it). `--jobs=N` sets
  `Config.build.jobs` on both routes. `Cli` stays the as-typed layer (Zig's `main.zig` locals);
  its digital fields (`schedule`, `logic`, `event_budget`) join `Config` in step 7, once the `.v`
  route goes through `Compilation` (they live in `sim`, below `vera` in `module_specs`).
- [ ] Step 3 rest: read requests (preprocessor includes, `.hdl`, SPICE `.INCLUDE`/`.LIB`,
  `$table_model` data, libmap), `std.Build.Cache` for `artifact_cache`, one zig-runner path.
- [x] Step 3 (part): `frontend.Files`, the one reader the compilation owns; the preprocessor,
  the SPICE reader and `$table_model` read through it (`Config.files`).
- **The rewrite is under way (2026-11-03): steps 4-12 are now built as new modules beside the old
  pipeline, not as edits to it.** Each new module is its own `module_specs` row that builds and tests
  alone (`zig build test-vams`: 3.6 s after an edit) and is held to the old code by a differential
  oracle over the whole fixture corpus (`zig build diff-*`, `build/rewrite.zig`). The old pipeline
  stays the product until the new one matches it, then is deleted. `docs/rewrite/` is the contract
  every module's author reads: `README.md` (rules, references, build), one spec per module.
  - merged: `intern_pool` + `air` (diff-air: 68 opcodes, 7,008,886 operand sets, 4 named ulp
    differences; it found three accuracy bugs in Zig's own `std.math.acosh`, `std.math.pow` and
    `@log10`), `vams` Preprocessor (diff-pp: 4,243/4,243 fixtures byte-equal, empty xfail).
    Preprocessor follow-ups: each `run` restarts from the top and replays earlier answers, quadratic
    in include depth (`ponytail:`, fix: an explicit scan stack); a synthesized SPICE netlist runs as
    an ordinary unit after the `-D` defines, where the old code ran it before them as shipped text.
  - merged: `vams` tokenizer/Ast/Parse (diff-parse: 4,140/4,170 agree on tokens, acceptance and
    structure; 30 named refusals that need names, folding or another file move to AstGen/Sema),
    `vams` Diag (diff-diag: 511 codes and `--explain` byte-equal, 21k scripted rows, 972/975
    reject/warn fixtures; 3 named, all macro locations now in the original file), `link` (diff-link:
    8/8 builds agree with zigbuild; library bytes equal at 1 and N jobs). Full `zig build test` green
    on `refactor` with all six merged.
  - merged: SPICE reader (diff-spice: 66,453/66,453 netlists), AstGen + Vir (diff-astgen:
    3,790/3,793; parse.xfail 30 -> 3), the Air passes (prove/ 9,016 -> 2,635 lines: Interval,
    Float, Legalize, Setup; 10^7 falsification runs, 2*10^7 Legalize comparisons, four soundness
    bugs found and fixed). Float's inherited overflow assumption is being replaced (§11.9).
  - merged: the digital runtime `std_sim` (diff-sim: 710/807 bridged and agree, 97 constructs
    listed), Zcu + elaboration (diff-elab: 3,727/3,776, 49 named), the sound float verdict
    (§11.9: IEEE 754 intervals, no overflow contract, per-root guard boxes for versioned units,
    `default_unknown_bound = 10` measured; 10^7 runs incl. 165,717 overflowing, 0 failures).
  - merged follow-ups: diff-sim 815/815 (sim.xfail empty; non-allocating wide `* / % **`, §9 bug 2
    done), diff-elab 3,756/3,776 (elab.xfail 49 -> 20: 15 per-instance checks for lowering, 5
    old-elaborator quirks).
  - merged: `std_kernels` (diff-kernels: 737 names, 68.8M comparisons bit-identical to lib/kernels
    and the old kernel text) with Gompute 2.0.0 replacing `gm` (cosh/sinh/log10 1 ulp apart, the f128
    reference sides with Gompute). Gompute is a `build.zig.zon` fetch (the user's choice; AGENTS.md
    amended). Gompute 2.0.1 pinned (bd8800b: `atan(±0) = ±0`, musl's scalar `atan`); VerA's own `atan`
    copy is gone, and `kernels-targets` holds the IR to no OPTIONAL contraction (`llvm.fmuladd`,
    `contract`/`fast` flags, with a canary): an explicit `@mulAdd` rounds once everywhere and is
    allowed. diff-kernels unchanged on 2.0.1 (737 names, 0 failures). At the switch-over,
    `share/vera/kernels/` must ship Gompute's `math.zig`, `math_data.zig`, `math_pio2.zig`.
  - in progress: Sema analog lowering (`lower.md`), Sema digital lowering (`dlower.md`).
  - settled: no default box for parameters. A parameter's guard interval is its declared range
    (§3.4.2 `from`), which the specification sets; an open-ended one (`Is from (0:inf)` times
    `exp(...)`) stays `.strict`. `default_unknown_bound` stays: unknowns have no declared range,
    and the bound only partitions inputs between the fast and strict bodies (every value is still
    computed exactly), so it restricts nothing the specification allows.
  - next: Sema analog lowering (Vir -> Air), digital lowering (Vir -> Program), codegen (with
    versioned units), kernels + Gompute, lib/vpi, Compilation; then the switch-over and the old
    pipeline's deletion.
- [x] Changelog: formatC (#132) and `--jobs` (#133), issues filed.

Notes from this session:
- The shared `.zig-cache` had 10,349 manifests in `h/` whose `o/` outputs were deleted on
  2026-11-02 around 16:30 (9 `checking cache failed: FileNotFound` steps). Collected: manifests
  older than the oldest surviving `o/` entry were deleted, which costs only a recompile; a plain
  `zig build test` is green again. A collector must delete a step's manifest with its output.
- In zsh, `exit "${PIPESTATUS[0]}"` exits 0 (zsh spells it `pipestatus`, 1-based); gate on `$?`
  of the command itself, or run the pipeline under bash.

---

## Appendix: per-file mapping

Each table maps every file of one subtree: current path, lines, role, duplicates, target path, the new
struct that absorbs it, estimated lines after, action. Reconciliations across maps, applied in §2:
`src/vpi` runtime → `lib/vpi/`; diag → `lib/std/vams/Diag.zig`; prove → Step A targets in `src/Air/`
(Step B shrinks them further); codegen/device `plan/{limit,noise,qsite,topology}` → `src/Air/Facts`.
Abbreviations: `Z/` Zig compiler `src/`, `S/` Zig `lib/std/zig/`, `D/` `src/codegen/device`,
`ZB/` `src/zigbuild`, `IP` InternPool, `Dev` `src/Air/Device.zig`, `SysFn` `lib/std/vams/SysFn.zig`.

| map | scope | before | after (src+lib) | test lines leaving src/lib |
|---|---|---|---|---|
| A.1 | lib/frontend, lib/base, lib/diag | 37,120 | ~28,445 (8,150 data) | ≈3,600 in-file test blocks |
| A.2 | src/elab, Compilation, main, cli, dynlib, build | 17,928 | ~9,980 | not totalled |
| A.3 | src/analog, src/ir | 29,988 | ~21,070 | ≈3,900 in-file test blocks |
| A.4 | src/prove, codegen/exe, codegen/verilog | 13,299 | ~8,255 (Step B ~6,400) | ~2,970 |
| A.5 | codegen/device, zigbuild | 28,818 | ~18,650 + ~3,570 moved to Air facts / lib kernels | ≈3,210 in-file test blocks |
| A.6 | lib/sim/digital, codegen/digital | 34,885 | ~19,340 | ~4,844 |
| A.7 | lib/sim/{rt,mixed,…}, kernels, contract, osdi_dyn | 31,211 | ~27,430 | ~2,740 |
| A.8 | src/vpi | 19,670 | ~11,580 | ~1,400 |
| | **total** | **212,919** | **~148,300** | ~12,000 explicitly moved (A.4, A.6, A.7, A.8) |

### A.1 lib/frontend, lib/base, lib/diag


| current path | LOC | role (<=12 words) | key pub types | duplicates (path) | target path | absorbing struct | LOC after | action |
|---|---|---|---|---|---|---|---|---|
| lib/base/BigArena.zig | 402 | arena that passes large blocks through to the backing allocator | BigArena | wraps std.heap.ArenaAllocator | (none) | gpa-owned tables (Ast/Vir/Air/InternPool `.deinit(gpa)`) + std.heap.ArenaAllocator | 0 | delete |
| lib/base/deep_stack.zig | 456 | recursion on threads with reserved stacks, segmented every 4096 levels | Segments, run, runGuarded, exhausted | Zig uses one worker stack size | src/Compilation.zig (worker `stack_size`); runtime guard to lib/std/sim | Compilation thread pool | 90 | delete (frontend), move guard |
| lib/base/design.zig | 168 | cross-layer elaboration rows kept in base so ir avoids frontend | Inserted, DisciplineResolution, ParamOverride, SystemParam | (none) | src/Sema.zig, src/Compilation/Config.zig | Sema, Compilation.Config | 120 | move |
| lib/base/directive.zig | 96 | timescale value and positional event row | Timescale, Region(T) | (none) | lib/std/vams/Preprocessor.zig | Preprocessor.Directives | 50 | merge |
| lib/base/interner.zig | 390 | string intern table over borrowed slices, with a base chain | StrId, StringInterner | Mir.strings; zsrc/InternPool.zig strings | src/InternPool.zig (+ Vir.string_bytes in AstGen) | InternPool.String | 0 | delete |
| lib/base/root.zig | 60 | re-exports | (none) | (none) | (none) | (none) | 0 | delete |
| lib/base/syntax.zig | 39 | ExprId, Type and Direction leaf enums | ExprId, Type, Direction | (none) | lib/std/vams/Ast.zig | Ast.Node.Index | 10 | merge |
| lib/diag/bag.zig | 439 | SoA diagnostic rows plus file table, source map and detach | Bag | Z/ErrorBundle.zig Wip; aro/Diagnostics.zig | lib/std/vams/Diag.zig | Diag (ErrorBundle layout) | 250 | rewrite |
| lib/diag/builder.zig | 221 | one diagnostic built as message, labels, notes and fixes | Builder | Z/ErrorBundle.zig:356 Wip | lib/std/vams/Diag.zig | Diag.Wip | 120 | merge |
| lib/diag/entry.zig | 133 | row, label, note and fix records | Row, LabelRow, NoteRow, Entry, Fix | ErrorBundle.ErrorMessage | lib/std/vams/Diag.zig | Diag.Message | 60 | merge |
| lib/diag/level.zig | 135 | allow, warn, deny and forbid per code; severity from the first letter | Severity, Level, Levels | aro/Diagnostics.zig:359 set | lib/std/vams/Diag.zig | Diag.Levels | 80 | merge |
| lib/diag/location.zig | 291 | spans, macro source map and line index | Span, FileId, Segment, SourceMap, LineIndex | (none) | Span to Diag; SourceMap to Preprocessor.Output; LineIndex to src/Zcu.zig File | Zcu.File, Preprocessor.Output | 150 | split/move |
| lib/diag/render.zig | 435 | terminal render and `--explain` | render, explain, Palette | Z/ErrorBundle.zig:178 renderToWriter | lib/std/vams/Diag.zig | Diag.render | 300 | merge |
| lib/diag/json.zig | 111 | JSON Lines render | renderJson | (none) | lib/std/vams/Diag.zig | Diag.renderJson | 80 | merge |
| lib/diag/suggest.zig | 118 | edit distance and did-you-mean | editDistance, didYouMean | (none) | lib/std/vams/Diag.zig | Diag | 100 | merge |
| lib/diag/code.zig | 291 | Code enum built from a list of names; comptime Info table | Code, Info, info | `names` repeats the row keys | lib/std/vams/Diag/code.zig | Diag.Code | 150 | rewrite (delete `names`) |
| lib/diag/root.zig | 93 | re-exports only | (none) | (none) | (none) | (none) | 0 | delete |
| lib/diag/codes/class01a..class12b.zig (22 files) | 8,445 | catalogue rows: title, LRM clause and explain prose | `rows` | (none) | lib/std/vams/Diag/codes.zon | Diag.Code table | 8,150 | merge (data) |
| lib/frontend/token.zig | 580 | token tags, lexemes, call groups, stored row | Tag, Stored, CallGroup | Z/tokenizer.zig:3 | lib/std/vams/tokenizer.zig | Token.Tag | 450 | merge |
| lib/frontend/keyword.zig | 548 | keyword StaticStringMap and §10.6 reserved sets | KeywordSet, lookupKeyword, isReserved | Z/tokenizer.zig:12 | lib/std/vams/tokenizer.zig | Token.keywords | 350 | merge |
| lib/frontend/lexer.zig | 925 | tokenize to MultiArrayList{tag,start}; re-lex finds the token end | TokenList, Lexer, Seed | Z/tokenizer.zig:391; Z/Ast.zig:279 | lib/std/vams/tokenizer.zig | Tokenizer | 700 | merge (drop Seed) |
| lib/frontend/token_value.zig | 366 | real, string and escape decoding from token text | parseReal, stringContents, scaleExp | Z/number_literal.zig:63, Z/string_literal.zig | lib/std/vams/number_literal.zig | number_literal | 330 | move |
| lib/frontend/preprocessor.zig | 335 | preprocessor spine; also reads `.hdl` files | Options, Output, process, readText | aro/Preprocessor.zig | lib/std/vams/Preprocessor.zig | Preprocessor | 180 | rewrite (no I/O) |
| lib/frontend/pp/Pp.zig | 511 | preprocessor state, file table writes into the Bag | Pp | aro/Preprocessor.zig | lib/std/vams/Preprocessor.zig | Preprocessor | 400 | merge |
| lib/frontend/pp/scan.zig | 185 | main byte scan | scan | (none) | lib/std/vams/Preprocessor/scan.zig | Preprocessor | 180 | merge |
| lib/frontend/pp/comments.zig | 177 | comment stripping with strip marks | strip | (none) | lib/std/vams/Preprocessor/scan.zig | Preprocessor | 150 | merge |
| lib/frontend/pp/directive.zig | 423 | directive dispatch | dispatch | (none) | lib/std/vams/Preprocessor/directive.zig | Preprocessor | 400 | move |
| lib/frontend/pp/directive_events.zig | 320 | operands of directives that last past their line, to events | (handlers) | pp/events.zig | lib/std/vams/Preprocessor/events.zig | Preprocessor.Directives | 280 | merge |
| lib/frontend/pp/events.zig | 202 | directive event types | Directives, NetType, Drive | base/directive.zig | lib/std/vams/Preprocessor/events.zig | Preprocessor.Directives | 150 | merge |
| lib/frontend/pp/include.zig | 173 | `include search and file read | readInclude | aro/Preprocessor.zig:3470 | Preprocessor emits a request; src/Compilation.zig resolves it | Compilation (aro/Compilation.zig:2587 findInclude) | 120 | rewrite |
| lib/frontend/pp/macro.zig | 647 | define, undef and expansion | (handlers) | (none) | lib/std/vams/Preprocessor/macro.zig | Preprocessor | 600 | move |
| lib/frontend/pp/protect.zig | 565 | §28 decryption envelopes | Keys | (none) | lib/std/vams/Preprocessor/protect.zig | Preprocessor | 550 | move |
| lib/frontend/pp/prelude.zig | 233 | process-global prelude snapshot replayed into each compile | Prelude, preludeAst | (none) | (none): the prelude becomes ordinary Zcu.File entries cached by hash | Compilation, Zcu.File | 0 | delete |
| lib/frontend/pp/annex_d.zig | 379 | annex D text as Zig strings | annex text | (none) | lib/std/vams/constants.vams, disciplines.vams | (data file) | 0 .zig | move (to .vams) |
| lib/frontend/pp/annex_e.zig | 493 | Table E.1 modules and D.3 as Zig strings | spice_primitives | (none) | lib/std/vams/spice_primitives.vams, driver_access.vams | (data file) | 0 .zig | move (to .vams) |
| lib/frontend/ast.zig | 1,020 | SourceFile root, overlay, side lists, re-export aliases | SourceFile, StmtId | Z/Ast.zig | lib/std/vams/Ast.zig | Ast | 600 | rewrite |
| lib/frontend/ast_expr.zig | 707 | SoA expression nodes, literals and payload pool | Node, ExprStore, ExprTag | Z/Ast.zig:2914 | lib/std/vams/Ast.zig | Ast.Node | 400 | merge |
| lib/frontend/ast_stmt.zig | 735 | statement union pool and edges/writes walks | Stmt, StmtRow, BlockRow | (none) | lib/std/vams/Ast.zig (stmt node tags) | Ast.Node | 350 | rewrite |
| lib/frontend/ast_decl.zig | 660 | AoS declaration structs; ModuleDecl has 22 slices | ModuleDecl, ParamDecl, NetDecl... | (none) | lib/std/vams/Ast/full.zig (extra payloads) | Ast.Node + extra_data | 400 | rewrite |
| lib/frontend/ast_design.zig | 351 | nature, discipline, paramset, connectrules and config rows | NatureDecl, DisciplineDecl... | (none) | lib/std/vams/Ast/full.zig | Ast.Node + extra_data | 200 | rewrite |
| lib/frontend/ast_prim.zig | 522 | gate, switch, UDP, specify and timing-check rows | GateInst, UdpDecl, SpecPath... | (none) | lib/std/vams/Ast/full.zig | Ast.Node + extra_data | 300 | rewrite |
| lib/frontend/parser.zig | 891 | Parser state (about 30 fields), recovery, segments | Parser, Seed | Z/Parse.zig:18-25 | lib/std/vams/Parse.zig | Parse | 650 | rewrite |
| lib/frontend/parser/source.zig | 446 | source_text, library text, configs | (fns) | Z/Parse.zig:208 parseRoot | lib/std/vams/Parse.zig | Parse | 400 | merge |
| lib/frontend/parser/expr.zig | 724 | precedence climbing, primaries, calls | (fns) | Z/Parse.zig:1574 | lib/std/vams/Parse/expr.zig | Parse | 650 | move |
| lib/frontend/parser/concat.zig | 298 | brace forms; unrolls and folds literal replication | (fns) | the folding duplicates Sema | lib/std/vams/Parse/expr.zig | Parse (desugar to AstGen) | 180 | rewrite |
| lib/frontend/parser/literal.zig | 157 | decodes literals at parse time | (fns) | Zig decodes in AstGen | lib/std/vams/AstGen.zig | AstGen | 100 | move |
| lib/frontend/parser/hier.zig | 131 | hierarchical names in declaration positions | (fns) | imports constfold (hier.zig:20) | lib/std/vams/Parse/expr.zig | Parse | 100 | merge |
| lib/frontend/parser/attributes.zig | 277 | §2.9 attribute instances | (fns) | (none) | lib/std/vams/Parse/decl.zig | Parse | 250 | merge |
| lib/frontend/parser/stmt.zig | 547 | analog and digital statements | (fns) | (none) | lib/std/vams/Parse/stmt.zig | Parse | 500 | move |
| lib/frontend/parser/event.zig | 215 | @, #, wait and event expressions | (fns) | (none) | lib/std/vams/Parse/stmt.zig | Parse | 200 | merge |
| lib/frontend/parser/module.zig | 793 | module items accumulated into Body lists | Body | Z/Parse.zig:25 scratch | lib/std/vams/Parse/module.zig | Parse | 600 | rewrite |
| lib/frontend/parser/generate.zig | 401 | generate regions, loop and if generates | (fns) | (none) | lib/std/vams/Parse/module.zig | Parse | 380 | merge |
| lib/frontend/parser/inst.zig | 528 | module, gate and switch instances; initial and always | (fns) | (none) | lib/std/vams/Parse/module.zig | Parse | 500 | merge |
| lib/frontend/parser/decl.zig | 395 | parameters, variables, events, dimensions | (fns) | (none) | lib/std/vams/Parse/decl.zig | Parse | 380 | move |
| lib/frontend/parser/net.zig | 571 | ports, nets, branches, strengths, delays | (fns) | (none) | lib/std/vams/Parse/decl.zig | Parse | 520 | merge |
| lib/frontend/parser/function.zig | 531 | analog functions, digital functions and tasks | (fns) | (none) | lib/std/vams/Parse/decl.zig | Parse | 480 | merge |
| lib/frontend/parser/discipline.zig | 157 | nature and discipline declarations | (fns) | (none) | lib/std/vams/Parse/design.zig | Parse | 150 | merge |
| lib/frontend/parser/connectrules.zig | 121 | connectrules | (fns) | (none) | lib/std/vams/Parse/design.zig | Parse | 115 | merge |
| lib/frontend/parser/paramset.zig | 216 | paramsets | (fns) | (none) | lib/std/vams/Parse/design.zig | Parse | 200 | merge |
| lib/frontend/parser/specify.zig | 521 | specify blocks and specparams | (fns) | (none) | lib/std/vams/Parse/prim.zig | Parse | 500 | move |
| lib/frontend/parser/timing_check.zig | 264 | §15 timing checks | (fns) | (none) | lib/std/vams/Parse/prim.zig | Parse | 250 | merge |
| lib/frontend/parser/udp.zig | 458 | UDP declarations and tables | (fns) | (none) | lib/std/vams/Parse/udp.zig | Parse | 440 | move |
| lib/frontend/constfold.zig | 852 | §4.2 constant-expression walker over the Ast | fold, foldSized, Const | src/elab/fold.zig, src/analog/constfold.zig, src/codegen/digital/rtlil_fold.zig, lib/sim/digital/evaluate.zig | src/Sema/eval.zig | Sema (comptime eval) | 450 | move/merge |
| lib/frontend/constfold_size.zig | 481 | width and signedness sizing for the folder | measure, IntPlan, Sizes | rtlil_fold sizing | src/Sema/eval.zig | Sema | 250 | move/merge |
| lib/frontend/wreal.zig | 305 | E0918/E0919 wreal driver and port rules | check | (none) | src/Sema/ (rule over Vir) | Sema | 280 | move |
| lib/frontend/libmap.zig | 718 | §13.2 library map: reads files, resolves paths | Map, load | (none) | src/Compilation/libmap.zig | Compilation.Config | 650 | move |
| lib/frontend/spice_cards.zig | 1,092 | SPICE cards to Verilog-AMS module text (741 test lines) | synthesize | (none) | lib/std/vams/spice.zig | spice.Netlist | 1,000 | move |
| lib/frontend/spice/card.zig | 180 | card rows, refusals, tokens | Card, Refusals | (none) | lib/std/vams/spice/card.zig | spice | 170 | move |
| lib/frontend/spice/emit.zig | 432 | card to module text | (fns) | (none) | lib/std/vams/spice/emit.zig | spice | 420 | move |
| lib/frontend/spice/expr.zig | 214 | `{expr}` evaluator | (fns) | (none) | lib/std/vams/spice/expr.zig | spice | 210 | move |
| lib/frontend/spice/model.zig | 420 | `.MODEL` binding and binning | Value | (none) | lib/std/vams/spice/model.zig | spice | 410 | move |
| lib/frontend/spice/names.zig | 126 | SPICE numbers and names | spiceNumber | src/vpi/host.zig:369 spiceNumber | lib/std/vams/spice/card.zig | spice | 110 | merge |
| lib/frontend/spice/reader.zig | 172 | reads netlist files; expands .INCLUDE/.LIB | (fns) | (none) | lib/std/vams/spice/reader.zig (emits requests) | Compilation does the reads | 120 | rewrite |
| lib/frontend/root.zig | 106 | re-exports (incl. Integer and deep_stack) | (none) | (none) | lib/std/vams.zig | (namespace) | 30 | rewrite |


### A.2 src/elab, Compilation, main, cli, dynlib, build


| current path | LOC | role (<=12 words) | key pub types | duplicates (path) | target path | absorbing struct | LOC after | action |
|---|---|---|---|---|---|---|---|---|
| src/elab/root.zig | 66 | re-exports only | – | – | – | – | 0 | delete |
| src/elab/design.zig | 353 | Ctx in, Design out: flat top + 19 side tables | Ctx, Design, Unit, UnitId, ModuleId, PortConcat, NetPart, … | analog/Lower.zig `design` field mirrors it | src/Zcu.zig (+ Air extra rows) | Zcu.Instance, Air | 60 | delete; NetPart/PortConcat rows move to Air extra |
| src/elab/elaborate.zig | 937 (719 test) | pickTop, global checks, seed/dry/real walks | `elaborate` | – | src/Sema.zig `analyzeTop` + Zcu `pickTop` | Sema, Zcu | 700 | rewrite: one hierarchy pass, no seed or dry walk |
| src/elab/Flatten.zig | 411 | per-walk state, `fate` table, publish Design | Flatten, Unit, Decls, Out | Lower's own state | src/Sema.zig | Sema (inst_map, current Instance) | 120 | rewrite: state is Sema's, output is Air not Ast |
| src/elab/clone_expr.zig | 436 | copy child expr rows renamed, per-instance rewrites | cloneExpr, cloneArgs | generate.substIdent/mapIdents | – (arms go to Sema expr analysis) | Sema | 0 | delete: Sema re-analyses Vir per instance (Z/Sema.zig:7270-7300) |
| src/elab/clone_stmt.zig | 241 | copy child statements renamed, mfactor scale | cloneStmt | – | – | Sema | 0 | delete |
| src/elab/clone_decl.zig | 354 | copy params/vars/funcs/dims renamed; block hide/unhide | cloneParams, cloneDim, cloneVar, hide, unhide | – | std/vams/AstGen.zig Scope (hide) | AstGen.Scope | 0 | delete; scoping becomes AstGen's (S/AstGen.zig Scope) |
| src/elab/flat_name.zig | 252 | path+local -> flat StrId, rename map, §6.6.2 unnamed scopes | flatReference, join, bind, flat, PathKey | analog/hier_name.zig re-splits on `sep` | src/Zcu.zig `Instance.fmtPath` | Zcu.Instance | 40 | delete; names are (Instance, decl), path only rendered |
| src/elab/fold.zig | 237 | const-fold in flat namespace, param cache | constInt, constValue, Cache, ParamEnv | lib/frontend/constfold, src/analog/constfold, prove/folds, kernels/fold | src/Sema.zig comptime eval over InternPool | Sema + InternPool | 0 | delete |
| src/elab/generate.zig | 521 | instance-generate lists, scopes, gates, genvar loop | genInstanceList, genvarLoop, genInstances, conj, substIdent(s) | lib/sim/digital/elab_generate.zig (364); lowering's unroll | AstGen (scope names) + Sema (scheme eval) | AstGen, Sema | 300 | split: naming per file, evaluation per instance |
| src/elab/walk.zig | 524 | instance walk on heap stack, dry-walk Tree, E0905 | walkInstances, Tree, TreeKid | lib/sim/digital/elab.zig hierarchy walk | src/Sema.zig hierarchy worklist | Zcu.instances | 250 | rewrite: fills Zcu.instances once; Tree deleted |
| src/elab/instance.zig | 314 | inline one instance: bind ports, overrides, clone body | inlineInstance | – | src/Sema.zig `analyzeInstance` | Sema | 250 | rewrite as Zig's inline-call path (fresh inst_map) |
| src/elab/override.zig | 359 | #() overrides, §9.18 values, §9.19 given | collectOverrides, parameterBinding, checkSystemParam | lib/sim/digital/elab_params.zig (284) | src/Sema.zig | Zcu.Instance.params (InternPool key) | 220 | merge |
| src/elab/defparam.zig | 532 | §6.3.1 table keyed by flat string, §12.8.1 seeding | Table, Defparam, collectDefparams, seedDefparams | lib/sim/digital/elab_defparams.zig (269) | src/Sema.zig (hierarchy pass) | Zcu.defparams keyed (Instance, String) | 220 | rewrite: no seed walk once the instance table exists first |
| src/elab/paramset.zig | 231 | paramset overrides, output vars, statements | paramsetOverrides | – | src/Sema/paramset.zig | Sema | 140 | merge with paramset_select |
| src/elab/paramset_select.zig | 395 | §6.4.2 selection + tie-breaks, §3.4.2 range order | selectParamset, matchingParamsets, checkRanges | – | src/Sema/paramset.zig | Sema | 260 | merge |
| src/elab/paramset_dist.zig | 169 | §9.13 dist in paramset folded by device rng | rewriteParamsetDist | analog/random.zig | src/Sema.zig (comptime call arm) | Sema | 100 | merge |
| src/elab/dist.zig | 175 | Table 9-10 distribution rows | Dist, dists, of | analog/random.zig reads it | src/Sema/builtins (one sysfunc table) | – | 150 | move; one table for both readers |
| src/elab/hier_param.zig | 99 | Table 9-29 system-param kinds and composition | Kind, Values, compose | base.SystemParam | src/Sema.zig table | – | 80 | move |
| src/elab/ports.zig | 627 | connection shape, binding, net parts, flow-read, dirs | connectionFor, bindPorts, netPart, checkPortDirections | lib/sim/digital/elab_ports.zig | AstGen (dirs §6.5.2.2) + Sema (binding) | Sema, Zcu.Instance.ports | 450 | split |
| src/elab/access.zig | 210 | child access across a port join, mfactor scaling | localAccess, mfactorScale, mfactorNoise | analog/discipline.zig access map | src/Sema.zig (access arm) | Sema | 100 | merge |
| src/elab/alias.zig | 200 | §3.4.7 alias use: source check, flat check | original, checkSource, checkFlat | – | AstGen (checkSource) + Sema (checkFlat) | AstGen, Sema | 120 | split |
| src/elab/decl_check.zig | 170 | connectrules names, net discipline names | checkConnectRules, checkNetDisciplines | analog/discipline.zig decl checks | Zcu namespace pass (after AstGen) | Zcu | 100 | merge |
| src/elab/lookup.zig | 247 | module/paramset lookup, last-wins, shadows | findModule, chainEnd, isPrimitive, warnRedefinedModules | lib/sim/digital module lookup | src/Zcu.zig `Namespace` | Zcu.modules map | 100 | rewrite: one map built once (vs linear scans) |
| src/elab/spice_case.zig | 102 | E.2.1 case-folded netlist names | spiceCase | – | Zcu namespace lookup (netlist File kind) | Zcu | 40 | merge |
| src/elab/primitive.zig | 155 | Table E.1 port_discipline attr, V/I respelling | checkPortDiscipline, primitiveAccess | – | src/Sema.zig | Sema | 100 | merge |
| src/elab/discipline_rules.zig | 309 | §3.6 discipline/nature queries, §3.11.1 compat | declOf, domainOf, accessOf, disciplineConflict | analog/discipline.zig (495), analog/node_discipline.zig (255) | src/Discipline.zig (Type.zig-like view over InternPool) | InternPool key `discipline` | 200 | merge the three |
| src/elab/resolve.zig | 639 | Annex F on flat nets, multi-candidate step 4.b | State, addNet, resolveDiscipline, resolveMultiCandidates | segment.zig, ooc.zig, analog/node_discipline | src/Sema/disciplines.zig | table over Zcu.instances × nets | 350 | merge: one Annex F pass |
| src/elab/segment.zig | 762 (300 test) | Annex F on unflattened hierarchy for insertion | State, Seg, up, down | resolve.zig | src/Sema/disciplines.zig | same | 250 | merge |
| src/elab/ooc.zig | 228 | out-of-context discipline decls, hier nodesets | State, collectOoc, oocDiscipline, applyOocInits | resolve.zig | src/Sema/disciplines.zig | same | 100 | merge |
| src/elab/connect_rule.zig | 388 | §7.7.1 connect rules, matching, E0927 | Rule, Unbridged, ruleOf, matchRules | – | src/Sema/connect.zig | Sema | 200 | merge with insert |
| src/elab/insert.zig | 475 | §7.8.4 connect-module insertion planning | plan, moduleOf | – | src/Sema/connect.zig | Sema over Zcu.instances | 250 | rewrite: runs on the table, no dry walk |
| src/elab/fixture.zig | 127 | test fixture: text -> Ctx | Fixture, parse, parseWithPrelude | analog Harness, prove fixture | tests/unit Sema harness | – | 80 | move |
| src/Compilation.zig | 838 (462 test) | `compile` spine: directives, spice, analyze x2, targets | compile, re-exports | cli/digital.zig (second spine) | src/Compilation.zig | Compilation | 750 | rewrite: create/update/job loop (Z/Compilation.zig:1714,2751,4360) |
| src/Compilation/analyze.zig | 324 | stage sequence, bag detach, deep_stack | analyze, Error | lsp calls it directly | Compilation.performAllTheWork jobs | Compilation, Job | 0 | absorb (~120 lines into Compilation.zig) |
| src/Compilation/Settings.zig | 79 | analysis settings value | Settings | cli/Cli.zig, request.Request.Build | src/Compilation/Config.zig | Config | 250 | merge Settings+Request+Cli+resolve |
| src/Compilation/request.zig | 156 | Request (targets) and Outcome (what to print) | Request, Outcome, CompileError | cli/Cli.zig | Config (Request) + Compilation fields (Outcome) | Config, Compilation | 40 | merge |
| src/Compilation/Result.zig | 133 | arena+AST+MIR+verdict, `generate` | Result, Device, Codegen | – | Compilation/Zcu fields; codegen.zig dispatch | Compilation | 0 | delete |
| src/Compilation/library.zig | 97 | --emit-so/--emit-osdi build + copy | build | cli/digital.zig emitDevice so path | src/link.zig (link.File .so/.osdi) | link.File | 80 | move (link scope) |
| src/Compilation/testbench.zig | 123 | --emit-exe runner build | build | cli/digital.zig emitDigital | src/link.zig (exe task) | link.Task | 110 | move |
| src/Compilation/verilog.zig | 76 | --emit-verilog, reads digital-pins file | emit | – | codegen.zig dispatch; file read -> Compilation | Compilation | 40 | merge |
| src/Compilation/osdi.zig | 46 | OSDI 0.4 refusals E1099/W1098 | check | – | src/codegen/osdi | codegen | 46 | move |
| src/Compilation/read_failed.zig | 38 | the read-failure line | ReadError, readFailed | – | src/Compilation.zig (file reads are its) | Compilation | 25 | merge |
| src/main.zig | 267 | drive: argv, refusals, contract tree, dispatch .v/.va | main | – | src/main.zig | – | 220 | keep; dispatch collapses to Compilation.update |
| src/cli/args.zig | 1039 (392 test) | argv -> Cli via two StaticStringMaps; resolve conflicts | parse, resolve, Settled | – | src/main.zig (parse) + Config.resolve (conflicts) | Config.Options | 650 | merge; keep the tables (smaller than Z/main.zig:1215 if-chain) |
| src/cli/Cli.zig | 124 | command line as typed, 60 fields | Cli | Settings, Request | Compilation/Config.zig `Options` | Config.Options | 0 | delete |
| src/cli/analog.zig | 161 | Cli -> Request field copy, run compile, print Outcome | run | cli/digital.zig | src/main.zig | – | 0 | delete (~40 lines into main) |
| src/cli/digital.zig | 632 | the `.v` spine: libraries, keys, elab/rtlil/device/exe | run | Compilation.compile, library.zig, testbench.zig | Compilation (units, reads) + codegen/link dispatch | Compilation, Job | 120 | absorb; keep `device_check` root text |
| src/cli/global_cache.zig | 33 | Zig global cache dir lookup | globalCache | zigbuild/artifact_cache | Compilation.cache dirs | Compilation | 0 | delete |
| src/cli/report.zig | 56 | bag -> stderr text or JSON | Style, report | lsp_diagnostics | std.zig.ErrorBundle.renderToWriter | ErrorBundle | 20 | shrink |
| src/cli/usage.zig | 128 | --help text | usage_text | – | src/main.zig (Zig keeps usage in main.zig) | – | 128 | merge |
| src/cli/lsp.zig | 514 | LSP session, lints each doc via `vera.analyze` | serve | second entry point to analysis | src/lsp.zig | Compilation.update per doc | 450 | move; drive Compilation, reuse cached Files |
| src/cli/lsp_diagnostics.zig | 353 | bag -> publishDiagnostics, URI<->path | diagnostics, Diagnostic | report.zig | src/lsp.zig | ErrorBundle | 300 | merge |
| src/dynlib.zig | 173 | dlopen/ntdll loader for tests and VPI host | DynLib | – | src/dynlib.zig (or link/) | – | 173 | keep |
| build.zig | 95 | build spine | build | – | build.zig | – | 95 | keep |
| build/common.zig | 222 | module_specs, cliExe, simSources, helpers | module_specs, Graph, M | – | build/common.zig | – | 190 | edit: elab/analog/prove/ir fold into `vera`; drop elab's conformance anon imports (common.zig:89-92) |
| build/unit.zig | 208 | per-module test roots, check step | add, Added | – | build/unit.zig | – | 190 | edit: fewer module roots |
| build/runs.zig | 163 | suite, host.py, canaries runs | add | – | build/runs.zig | – | 163 | keep |
| build/devices.zig | 239 | contract device hosts | add, Gen | – | build/devices.zig | – | 239 | keep |
| build/external.zig | 137 | verilator/iverilog/yosys checks | add | – | build/external.zig | – | 137 | keep |
| build/vpi.zig | 229 | libvera-vpi + VPI apps | library, add | – | build/vpi.zig | – | 229 | keep |


### A.3 src/analog, src/ir


#### src/ir (5,307 → ~3,620)

| current path | LOC | role (≤12 words) | key pub types | duplicates (path) | target path | absorbing struct | LOC after | action |
|---|---|---|---|---|---|---|---|---|
| src/ir/root.zig | 28 | re-exports Mir, op, Lowered, simparam, names | — | — | — | — | 0 | delete |
| src/ir/Mir.zig | 433 | SSA tables, handles, row types, method re-export list | `Inst`, `Value`, `Block`, `InstRow`, `ValueRow`, `Def`, `InstData` | 70 lines of `pub const x = file.x` re-exports | src/Air.zig | `Air` | 250 | rewrite: `Inst{tag,data}`; the Value table is gone |
| src/ir/mir_insts.zig | 541 | encode/decode instruction rows, extra pool | `emit*`, `instData` | prove/verify.zig decodes the columns a second time | src/Air.zig (decode) + src/Sema.zig (`Block.addInst`) | `Air`, `Sema.Block` | 300 | merge |
| src/ir/mir_values.zig | 420 | constant/param/probe Values, dedup maps, alias union-find | `addFloatConst`, `valueDef`, `resolveAlias` | `base.StringInterner` copy per Mir | src/InternPool.zig (consts, strings) + `Air.Inst.Ref` decode | `InternPool`, `Air.Inst.Ref` | 100 (+120 in IP) | split |
| src/ir/mir_blocks.zig | 262 | intrusive `next` chains, unlink/splice/moveTailBefore | `InstIterator` | — | src/Air.zig (`Block` body in `extra`) | `Air.Block` | 200 | merge |
| src/ir/mir_guards.zig | 101 | speculation guard literal chains (ifconv output) | `GuardLit`, `GuardIter` | — | src/Air.zig side table | `Air.guards` | 80 | merge |
| src/ir/opcode.zig | 586 | `Opcode` set + `EnumArray(Opcode, Info)` facts + fold | `Opcode`, `OpClass`, `Domain`, `Info`, `table`, `fold` | `kernels/fold` (kernel; no duplication) | src/Air.zig | `Air.Inst.Tag`, `Air.tag_info` | 450 | move as-is (already EnumArray) |
| src/ir/op.zig | 119 | `OpKind` + 3 switch fns (acDynamic, needsInput, enableArg) | `OpKind` | a derived column of callee_table | SysFn | `SysFn.OpKind` + `EnumArray(OpKind, OpInfo)` | 50 | merge into a table |
| src/ir/callee.zig | 331 | `Callee` enum (call names) + `fromName` StaticStringMap | `Callee` | lib/sim/digital/system_functions.zig `SysFn`; analog/sysfunc_context.zig; elab/dist.zig | SysFn | `SysFn.Tag` | 250 | merge (one table for both domains) |
| src/ir/callee_table.zig | 476 | `EnumArray(Callee, Info)`: ty, arity, family, fd, op | `Ty`, `Arity`, `Family`, `Info` | `Ty` = Lowered.Ty = base.Type | SysFn | `SysFn.Info` | 400 | merge |
| src/ir/simparam.zig | 183 | §9.15 name → Source map, host_params array | `HostParam`, `Source` | `Lowered.Kernel.host_*` (6 members repeat host_params) | SysFn | `SysFn.SimParam` + `EnumArray` | 110 | rewrite as an enum table |
| src/ir/Lowered.zig | 1170 | 55 fields: every table lowering hands later stages | `Lowered`, 7 handles, `Node`, `Contribution`, `HeldVar`, `WideNode`, `Kernel`… | `Ty` (3rd type enum); `src`/`tok_starts`/`token_span` repeat Zcu.File | src/Air/Device.zig + Zcu.Instance + IP | `Air.Device`, `Zcu.Instance`, `InternPool` | 860 (650+150+60) | split by reader |
| src/ir/names.zig | 657 | unit enumeration, stable emitted names, field spellers | `Unit`, `Role`, `sanitize`, `enumerateUnits` | codegen/device/codegen/plan/names.zig | src/codegen.zig (`codegen.names`) | codegen | 450 | move to codegen; Sema emits no spellings |

#### src/analog → Sema (24,681 → ~17,450)

| current path | LOC | role (≤12 words) | key pub types | duplicates (path) | target path | absorbing struct | LOC after | action |
|---|---|---|---|---|---|---|---|---|
| src/analog/root.zig | 21 | re-exports Lower, Ssa | — | — | — | — | 0 | delete |
| src/analog/Lower.zig | 902 | pass state (68 fields), entry, emit/call/diag helpers | `Lower`, `TypedValue`, `VarSlot`, `ArrayInfo`, `Accum`, `Options`, `Output` | 26 row-type aliases of Lowered; 12 re-export lines | src/Sema.zig | `Sema`, `Sema.Block` | 350 | rewrite (context fields → `Block`) |
| src/analog/module.zig | 583 | spine: calls `elab.elaborate`, then lowers the module in order | `lowerFile` | Compilation's job (it calls elab) | src/Sema.zig (`analyzeInstance`) | `Sema` | 300 | rewrite (drop the elab call and directive reads) |
| src/analog/stmt.zig | 358 | statement dispatch, blocks, disable, jumps | `lowerStmt`, `State` | — | src/Sema.zig (`analyzeBody`) | `Sema` | 300 | merge |
| src/analog/expr.zig | 226 | expression dispatch on Ast tag | `lowerExpr`, `lowerOperand` | — | src/Sema.zig (`analyzeBodyInner` switch) | `Sema` | 180 | merge |
| src/analog/coerce.zig | 236 | §4.2.1 conversions, unify, astTy | `coerceTo`, `toReal`, `unify` | — | src/Sema.zig (`coerce`, = Sema.zig:27996) | `Sema` | 150 | merge |
| src/analog/constfold.zig | 559 | Env adapters that feed frontend/constfold from Lower tables | `constEval`, `shapeEval`, `foldExpr`, clog2* | lib/frontend/constfold.zig, constfold_size.zig, src/elab/fold.zig (three Envs over one AST walker) | src/Sema.zig (`resolveConstValue`, = Sema.zig:2257) | `Sema` | 150 | rewrite: fold at emit via `Air.tag_info.fold` |
| src/analog/finite.zig | 169 | E0424: rescans MIR constants for NaN/inf | `FiniteScan`, `checkFiniteContribution` | prove/folds.zig, `analysis.foldConst` | src/Sema.zig (check on the interned Ref) | `Sema` | 30 | delete the scan; constants are already interned |
| src/analog/phi_value.zig | 38 | Braun trivial-phi rule over pairs | `sameValue` | — | src/Sema/Ssa.zig | `Ssa` | 20 | merge (pure helper) |
| src/analog/ssa.zig | 1025 | Braun SSA builder: places, seal, read/write | `Place`, `SsaBuilder` | — | src/Sema/Ssa.zig | `Ssa` | 900 | move (Value → Air.Inst.Ref) |
| src/analog/dom_tree.zig | 144 | incremental dominator spans for SSA read skipping | `Dom`, `Span`, `skipUp` | prove/cfg.zig `findDominators` (CHK), prove/postdom.zig | src/Sema/Ssa.zig | `Ssa` | 140 | merge |
| src/analog/discipline.zig | 495 | disciplines/natures, access map, §3.11 compatibility | `collectDisciplines`, `natureOf` | elab/discipline_rules.zig | src/Sema/decl.zig | `Sema` + IP keys `nature`/`discipline` | 300 | rewrite (IP keys replace StringHashMaps) |
| src/analog/node_discipline.zig | 255 | per-node discipline, `default_discipline`, nettype, unconnected drive | `resolveDisciplines` | directive regions also read in elab | src/Sema/decl.zig | `Sema` | 150 | rewrite (AstGen stamps the directive in force on each decl) |
| src/analog/node.zig | 608 | ports, nets, solver-unknown order, flow unknowns | `State`, `internNode`, `flowUnknown` | — | src/Sema/decl.zig | `Air.Device.nodes` writer | 450 | merge |
| src/analog/node_ref.zig | 410 | net/port/branch expr → node row; branch decls | `nodeOf`, `declareBranches` | elab/ports.zig (port ranges) | src/Sema/decl.zig | `Sema` | 300 | merge |
| src/analog/param.zig | 893 | model-card params, aliasparam, attributes, decl meta | `lowerParams`, `addParam`, `collectDeclMeta` | elab/override.zig, elab/hier_param.zig | src/Sema/decl.zig | `Air.Device.params` writer | 600 | merge (values through resolveConst) |
| src/analog/var.zig | 797 | variable scopes, storage, retention, mem arrays | `declareVarDecl`, `ScopeEntry`, `State` | — | src/Sema/decl.zig | `Sema.Block` scope | 600 | merge (scope undo log → Block chain) |
| src/analog/shape.zig | 426 | array bounds, row-major cells, element names, patterns | `Bounds`, `flatIndex`, `elemName` | elab/clone_* scalarization | src/Sema/decl.zig | IP `array_type` key | 300 | rewrite |
| src/analog/held.zig | 556 | AST pre-scan: held vars, mem arrays; `dropHeld` | `markHeldVars`, `dropHeld` | prove/held.zig (prune) | src/Sema/decl.zig | `Sema` | 400 | merge; `dropHeld` becomes an Air pass output |
| src/analog/initial_state.zig | 114 | digital `initial` constant assigns → start values | `collectInitialState` | lib/sim/digital initial handling | src/Sema/decl.zig | `Sema` | 80 | merge |
| src/analog/source_check.zig | 278 | end-of-module probe/parallel-source sweeps | `checkProbeBranches`, `HierPotential` | — | src/Sema/decl.zig | `Sema` | 220 | merge |
| src/analog/expr_access.zig | 404 | V()/I() reads, port flows, ammeters | `lowerBranchAccess` | — | src/Sema/expr.zig | `Sema` | 330 | merge |
| src/analog/expr_case.zig | 112 | four-state `===` / case match | `caseEquality`, `caseMatch` | lib/sim/digital case compare | src/Sema/expr.zig | `Sema` | 100 | merge |
| src/analog/expr_concat.zig | 211 | concat/replication as string or int | `lowerConcat` | — | src/Sema/expr.zig | `Sema` | 170 | merge |
| src/analog/expr_cond.zig | 199 | `?:`, `&&`, `||` short circuit | `lowerTernary`, `lowerShortCircuit` | — | src/Sema/expr.zig | `Sema` | 170 | merge |
| src/analog/expr_name.zig | 229 | identifier and hierarchical name resolution | `lookupName`, `flatName` | elab/lookup.zig, elab/flat_name.zig | src/Sema/expr.zig | `Sema` (Zcu namespace lookup) | 120 | rewrite (14 elab reads → Zcu.Instance) |
| src/analog/expr_op.zig | 342 | unary/binary opcode choice by operand types | `lowerUnary`, `lowerBinary`, `cmp` | — | src/Sema/expr.zig (≈ Sema/arith.zig role) | `Sema` | 260 | merge |
| src/analog/expr_select.zig | 333 | element, bit and part selects | `lowerIndex`, `selectBound` | — | src/Sema/expr.zig | `Sema` | 260 | merge |
| src/analog/math.zig | 169 | Table 4-14/15 name → opcode StaticStringMaps | `unaryMathOp`, `lowerBuiltin` | `Callee.$sqrt…` rows; Opcode table | src/Sema/expr.zig + SysFn | `SysFn` column `opcode` | 60 | delete the tables; AstGen tags the call |
| src/analog/clog2.zig | 115 | `$clog2` at self-determined widths | `lowerClog2` | constfold_size.clog2Width | src/Sema/expr.zig | `Sema` | 90 | merge |
| src/analog/wide.zig | 612 | wide (>32 bit) reg expression trees | `rhs`, `select`, `fromInt` | lib/kernels/wide_kernels.zig (runtime) | src/Sema/expr.zig | `Air.Device.wide_nodes` writer | 500 | merge |
| src/analog/lvalue.zig | 241 | assignable locations, subscript checks | `Lvalue`, `resolveLvalue` | — | src/Sema/expr.zig | `Sema` | 200 | merge |
| src/analog/slice.zig | 234 | array slice read/write | `arrayRef`, `copyArraySlice` | — | src/Sema/expr.zig | `Sema` | 200 | merge |
| src/analog/assign.zig | 355 | §5.7 procedural assignment | `lowerAssign`, `runtimeArrayIndex` | — | src/Sema/expr.zig | `Sema` | 300 | merge |
| src/analog/static.zig | 347 | static-condition test: AST spelling + MIR worklist | `isAnalysisOrConst`, `isStaticValue` | prove/invariance.zig (the same fixpoint over MIR) | src/Sema/expr.zig | `Sema` | 150 | rewrite (a per-Ref flag set at emit; `static_calls` → SysFn column) |
| src/analog/control.zig | 317 | if/case diamonds, generate-scheme checks | `lowerIf`, `lowerCase` | elab/generate.zig | src/Sema/control.zig | `Sema` (= `zirCondbr`, Sema.zig:17714) | 260 | merge |
| src/analog/loop.zig | 323 | while/repeat/for loops, genvar unroll | `lowerWhile`, `lowerFor` | elab/generate.zig unroll | src/Sema/control.zig | `Sema` (= `zirLoop`, Sema.zig:5163) | 270 | merge |
| src/analog/event.zig | 286 | `@(...)` event controls → guard calls | `lowerEventControl`, `EventRef` | — | src/Sema/control.zig | `Sema` | 220 | merge |
| src/analog/event_args.zig | 208 | cross/above/timer argument checks | `checkEventArgBounds` | 12 name compares that SysFn arity can answer | src/Sema/control.zig | `Sema` | 120 | merge |
| src/analog/timer.zig | 530 | timer argument capture and replay | `TimerCapture`, `finishTimers` | — | src/Sema/control.zig | `Sema` | 400 | merge (replay through inst_map) |
| src/analog/func.zig | 641 | user functions inlined; recursion check; call pre-scan | `lowerUserCall`, `scanCallSites` | — | src/Sema/control.zig | `Sema` (= `analyzeCall` inline, Sema.zig:6605) | 450 | merge (`Block.inlining`) |
| src/analog/timepoint.zig | 192 | `vera_timepoint` cache diamonds | `lowerTimepoint` | prove/timepoint.zig | src/Sema/control.zig | `Sema` | 160 | merge |
| src/analog/contrib.zig | 389 | `<+` spine | `lowerContribute`, `State` | — | src/Sema/contrib.zig | `Sema` | 320 | merge |
| src/analog/accum.zig | 174 | contribution rows and accumulator places | `contribIndex`, `newContrib` | — | src/Sema/contrib.zig | `Air.Device.contributions` writer | 150 | merge |
| src/analog/branch.zig | 369 | access call → (access, pair, branch) target | `Target`, `branchOf`, `accessOn` | elab/access.zig | src/Sema/contrib.zig | `Sema` | 300 | merge |
| src/analog/reactive.zig | 406 | resistive/reactive split, charge sites | `Split`, `splitContribution` | — | src/Sema/contrib.zig | `Sema` | 350 | merge |
| src/analog/indirect.zig | 246 | §5.6.7 indirect contributions | `lowerIndirect` | — | src/Sema/contrib.zig | `Sema` | 200 | merge |
| src/analog/noise_src.zig | 156 | noise generators reached from an expression | `noiseSrcsOf`, `addNoiseSrc` | — | src/Sema/contrib.zig | `Sema` | 130 | merge |
| src/analog/noise_op.zig | 519 | noise/ac_stim calls, PSD maps keyed by Ast.ExprId | `lowerNoise`, `noiseCoeff` | 10 name compares | src/Sema/contrib.zig | `Sema` (`inst_map` replaces the 3 ExprId maps) | 380 | merge |
| src/analog/analog_op.zig | 857 | §4.5 operators: ddt/idt/absdelay/transition/laplace… | `lowerFilter`, `opDdt`, `NatureRef` | 17 name compares; the `maxArgs` table duplicates SysFn arity | src/Sema/contrib.zig | `Sema` | 600 | merge |
| src/analog/limit.zig | 182 | `$limit` slots | `addLimitSlot`, `lowerLimitUser` | — | src/Sema/contrib.zig | `Air.Device.limit_slots` writer | 150 | merge |
| src/analog/sysfunc.zig | 513 | `$`-call dispatch in expression position | `lowerSysCall`, `refuseReserved` | 27 name compares | src/Sema/syscall.zig | `Sema` (= builtin-call handling) | 330 | merge (switch on `SysFn.Tag`) |
| src/analog/sysfunc_args.zig | 201 | arity, descriptor and format-arg checks | `checkArity`, `lowerSysArg` | — | src/Sema/syscall.zig | `Sema` | 170 | merge |
| src/analog/sysfunc_context.zig | 157 | 3 StaticStringMap name sets (digital/analog/connect only) | `isDigitalOnlySysFunc`… | lib/sim/digital/system_functions.zig; ir/callee | SysFn | `SysFn.Info.context` column | 0 | delete (becomes a column) |
| src/analog/systask.zig | 280 | task-statement routing by family | `lowerSysTask`, `State` | — | src/Sema/syscall.zig | `Sema` | 220 | merge |
| src/analog/display.zig | 349 | display chain, deferred re-lowering of operands | `queueDisplay`, `finishDisplays` | — | src/Sema/syscall.zig | `Air.Device.displays` writer | 280 | merge |
| src/analog/format.zig | 497 | format-string pairing checks, width recording | `checkFormatPairing`, `prepareFormatArgs` | private `nextConv` (:221) = `kernels/fmt.spec` (:315) + `flagVerdict` | src/Sema/syscall.zig | `Sema` | 330 | merge; call `kernels.fmt.spec` |
| src/analog/string_io.zig | 344 | `$swrite`/`$sscanf`/`$fgets`/plusargs | `lowerScan`, `lowerStringWrite` | — | src/Sema/syscall.zig | `Sema` | 290 | merge |
| src/analog/status.zig | 123 | `$fatal`/`$error` status sites | `lowerStatus` | — | src/Sema/syscall.zig | `Sema` | 100 | merge |
| src/analog/kernel_ctl.zig | 272 | `$bound_step`, `$discontinuity`, reject-step | `lowerKernelCtl` | — | src/Sema/syscall.zig | `Sema` | 220 | merge |
| src/analog/random.zig | 283 | §9.13 distributions, seeds | `lowerRandom`, `State` | src/elab/dist.zig | src/Sema/syscall.zig | `Sema` | 230 | merge |
| src/analog/table_model.zig | 467 | `$table_model`, **reads data files** (:283-295) | `lowerTableModel`, `readNoiseTableFile` | — | src/Sema/syscall.zig | `Sema` (file comes from `Zcu.EmbedFile`) | 330 | rewrite (Compilation reads the file) |
| src/analog/hier_name.zig | 632 | `$simprobe`, §9.20 hierarchical strings | `lowerSimprobe`, `aliasProbe` | elab/flat_name.zig | src/Sema/syscall.zig | `Sema` (Zcu namespace) | 450 | rewrite (15 elab reads) |
| src/analog/context.zig | 673 | §7.2.2 discrete-context marks and rules | `DiscreteCtx`, `collectWrites`, `d2aTerm` | lib/sim/digital/elab_* | src/Sema/discrete.zig | `Sema` | 500 | merge |
| src/analog/discrete_check.zig | 391 | analog constructs in a digital context | `checkDiscreteContext` | — | src/Sema/discrete.zig | `Sema` | 330 | merge |
| src/analog/discrete_mark.zig | 234 | syntactic per-expr discrete flag (AST walk) | `markDiscreteExprs`, `Reads` | — | lib/std/vams/AstGen.zig (tag on the Vir inst) | `AstGen` | 0 here (~80 in AstGen) | move to AstGen |
| src/analog/discrete_input.zig | 280 | digital values read by analog → Model inputs | `declareDiscreteInputs` | — | src/Sema/discrete.zig | `Air.Device.discrete` writer | 230 | merge |
| src/analog/harness.zig | 194 | test support: source → verdict | `Harness`, `Case`, `expectVerdict` | prove/fixture.zig, elab/fixture.zig | tests/unit/sema.zig | — | 150 | move to tests |

Resulting Sema files, with the Zig file each one mirrors:

| target | sources | LOC before → after | Zig file |
|---|---|---|---|
| src/Sema.zig | Lower, module, stmt, expr, coerce, constfold, finite, root | 3,054 → 1,460 | Sema.zig (`Sema`, `Block`, `analyzeBodyInner` :1109, `coerce` :27996, `resolveConstValue` :2257) |
| src/Sema/Ssa.zig | ssa, dom_tree, phi_value | 1,207 → 1,060 | none (Zig's Air has no phis); closest is `inst_map` |
| src/Sema/decl.zig | discipline, node_discipline, node, node_ref, param, var, shape, held, initial_state, source_check | 4,832 → 3,400 | Sema/type_resolution.zig |
| src/Sema/expr.zig | expr_*, math, clog2, wide, lvalue, slice, assign, static | 3,903 → 2,910 | Sema/arith.zig + Sema.zig `zir*` expression handlers |
| src/Sema/control.zig | control, loop, event, event_args, timer, func, timepoint | 2,497 → 1,880 | Sema.zig `zirBlock` :5251, `zirLoop` :5163, `zirCondbr` :17714, `analyzeCall` :6605 |
| src/Sema/contrib.zig | contrib, accum, branch, reactive, indirect, noise_*, analog_op, limit | 3,298 → 2,580 | none (analog-specific) |
| src/Sema/syscall.zig | sysfunc*, systask, display, format, string_io, status, kernel_ctl, random, table_model, hier_name | 4,118 → 2,950 | Sema.zig builtin-call handling over `BuiltinFn` |
| src/Sema/discrete.zig | context, discrete_check, discrete_input (discrete_mark goes to AstGen) | 1,578 → 1,060 | none |

Eight files instead of 68. Four of them are over 500 code lines, so either `check_style.py`'s 500-line rule bends for them (Zig's Sema.zig is 35.7k lines) or each one stays a directory. Constraint 4 favours bending the rule.


### A.4 src/prove, codegen/exe, codegen/verilog


Targets follow TARGET.md: `src/Air.zig` (today's `ir/Mir`) plus `src/Air/` passes.
"LOC after" is this file's share of its target in `src/` (code plus trimmed docs). Tests moved to `tests/unit/air_*.zig` are not counted there; they are listed in §5.
Tier A = byte-identical output.

| current path | LOC | role (≤12 words) | key pub types | duplicates (path) | target path | absorbing struct | LOC after | action |
|---|---|---|---|---|---|---|---|---|
| src/prove/root.zig | 43 | re-exports only | — | — | — | — | 0 | delete (Zig: codegen imports `Air/Liveness.zig` directly) |
| src/prove/Analysis.zig | 737 | codegen's CFG + per-Value fact tables, built once | `Analysis`, `VTy` | 9 `*_pool/*_off` pairs, each with its own accessor | src/Air/Analysis.zig | `Analysis` (≈ zig Air/Liveness.zig: tables over Air, read by codegen) | 260 | merge; one `Csr(T)` type replaces the 9 pool/off pairs; 340 test lines → tests |
| src/prove/cfg.zig | 664 | RPO, preds/succs, CHK idom, dom tree, pools, loops | — | analog/dom_tree.zig (SSA-time dom tree); codegen/device/codegen/cfg.zig (re-structures this CFG) | src/Air/Analysis.zig (Cfg half) | `Analysis` | 320 | merge; one generic CHK `dominators(dir)` shared with postdom; 271 test lines → tests |
| src/prove/postdom.zig | 194 | ipdom (CHK on reverse CFG) + steer pool | — | cfg.zig `intersect`/`findDominators` (same algorithm twice); verdict.zig `pushSteering` (idom-path steering, different precision) | src/Air/Analysis.zig | `Analysis` | 105 | merge; reuse the generic CHK |
| src/prove/value_types.zig | 187 | def_block, arr_of, vty, wide_w per Value | — | `def_block` ≈ `Mir.instBlock` (ir/mir_insts.zig:193) for linked rows | src/Air/Analysis.zig | `Analysis` | 160 | merge (Tier B: Sema types Air, then delete) |
| src/prove/deps.zig | 323 | derivative/varying bitset fixpoints (deps, xdeps, pdeps, acdyn) | — | invariance.zig and timepoint.zig are the same "varies" lattice with other seeds; codegen plan/core.zig `Mark` | src/Air/Analysis.zig | `Analysis.flags` + `deps`, `acdyn` | 240 | merge; `xdeps`/`pdeps` become 1 bit each (F3) |
| src/prove/folds.zig | 165 | constant-fold column per param policy | `FoldColumn` | frontend/constfold, analog/constfold (559), elab/fold, kernels/fold; analog/finite.zig (E0424 folds to non-finite) | src/Air/Analysis.zig | `Analysis.folds` | 135 | merge (kernel is already `opcode.fold`; only leaf policy here) |
| src/prove/input.zig | 55 | `Input` bag {arena, mir, an, lowered}; `strArg` | `Input`, `strArg` | `Analysis.mir` already holds the MIR | src/Air/Analysis.zig | `Analysis.strArg` | 10 | delete `Input`: planners take `*const Analysis` (it has `.mir`) + `*const Lowered`, as zig codegen `Function` holds `air` + `liveness` |
| src/prove/fixture.zig | 73 | test-only hand-built MIR + Analysis | `Fixture` | — | src/Air/fixture.zig | `Fixture` | 73 | move as-is (AGENTS.md allows exported test support) |
| src/prove/proof.zig | 177 | spine: build, seed, classes, arms, walk, rate | `FloatMode`, `Verdict`, `Options`, `prove` | — | src/Air/Float.zig | `Float` (spine) | 130 | merge |
| src/prove/Prover.zig | 228 | prover state SoA + fact env + operand reads | `Prover`, `Fact`, `GuardRef`, `Saved` | `operands()` re-decodes `InstData` (also deps.zig `depRow`, ifconv `keepSlice`, verdict) | src/Air/Float.zig | `Float` | 167 | merge |
| src/prove/seed.zig | 182 | leaf intervals: consts, §3.4.2 ranges, probes; W0651 | — | — | src/Air/Float.zig | `Float.seed` | 145 | merge |
| src/prove/guards.zig | 319 | congruence classes, select-arm guards, fact undo log | — | `isPredicateValue` also used by ifconv `peelToBool` | src/Air/Float/guards.zig | `Float` | 270 | merge (separate file only for the ≤500 rule) |
| src/prove/walk.zig | 235 | the one forward dom-preorder interval + finite pass | — | — | src/Air/Float.zig | `Float.walk` | 190 | merge |
| src/prove/domain.zig | 241 | three-way §4.3.2 domain check; E0601-7/9, W0653 | — | falsify.zig `inDomain`, transfer.zig `inDomain1` (test oracles) | src/Air/Float/domain.zig | `Float` | 195 | merge with message |
| src/prove/message.zig | 170 | diagnostic phrasing for domain/verdict | — | — | src/Air/Float/domain.zig | `Float` | 145 | merge |
| src/prove/verdict.zig | 163 | per-unit backward slice AND; W0650 | — | `pushSteering` vs postdom `steer_pool` (two steering notions) | src/Air/Float.zig | `Float.rate` | 135 | merge |
| src/prove/Interval.zig | 272 | interval lattice: meet/join/predicates | `Interval` | — | src/Air/Interval.zig | `Interval` | 160 | merge with transfer; 78 test lines → tests |
| src/prove/transfer.zig | 648 | per-opcode interval transfer + call ranges | `Abstract`, transfers | lines 443-548 are test-only helpers (`samplePoints`, `device1/2`, `inDomain1`) | src/Air/Interval.zig | `Interval.transfer*` | 346 | merge; ~105 helper + 95 test lines → tests |
| src/prove/ifconv.zig | 1335 | diamond/triangle → select, pure and speculate, guards rows | `Mode`, `run`, `keepSlice` | `cardOnly` ≈ "invariant" lattice; `keepSlice` ≈ verdict slice walk | src/Air/Legalize.zig | `Legalize` (≈ zig Air/Legalize.zig: Air rewritten in place for a backend) | 513 | merge; 641 test lines + `Shape` → tests |
| src/prove/revisit.zig | 159 | worklist schedule for ifconv's fixpoint | `Revisit` | — | src/Air/Legalize.zig | `Legalize` | 100 | Tier A: fold in (perf only, F6). Tier B: delete |
| src/prove/setup.zig | 328 | `Invariance` result, control deps, branch helpers | `Invariance`, `ControlDeps`, `plan`, `candidate` | `controlDeps` recomputed at 3 call sites (F5) | src/Air/Setup.zig (+ `controlDeps` → Analysis) | `Setup` | 110 | merge; control deps become an `Analysis` table built once |
| src/prove/invariance.zig | 406 | optimistic solve-invariance + placement + homes fixpoint | `solve`, `fillHomes`, `callInvariant` | timepoint.zig `rule`/`varies` (same shape) | src/Air/Setup.zig | `Setup` | 340 | merge |
| src/prove/timepoint.zig | 181 | `vera_timepoint` per-iteration variance (E0531) | `varying` | invariance.zig (`callTimepoint` already calls `callInvariant`) | src/Air/Setup.zig | `Setup.timepointVarying` | 115 | merge; share the operand scan |
| src/prove/held.zig | 181 | §3.2 prune unobservable held slots; keep mask | `prune` | analog/held.zig (AST half of the same decision) | src/Air/Setup.zig | `Setup.pruneHeld` | 125 | merge |
| src/prove/verify.zig | 726 | MIR well-formedness checker, panics in safe builds | `Invariant`, `Violation`, `check` | asserts in the Analysis builders | src/Air/Verify.zig | `Verify` (= zig Air/Verify.zig, Air/Liveness/Verify.zig) | 390 | move; 223 test lines + `sample`/`Breaker` → tests |
| src/prove/falsify.zig | 624 | random-MIR oracle against the prover (test only) | none public | verilog/Interp.zig (second MIR interpreter) | tests/unit/air_falsify.zig | — | 0 | move to tests (an oracle, not shipped) |
| src/codegen/exe/root.zig | 78 | re-exports and pipeline doc | — | — | — | — | 0 | delete (keep the pipeline example as `exe.zig`'s header, ~20) |
| src/codegen/exe/spec.zig | 325 | directive types: Spec, Bench, Harness, Facts, wants | `Spec`, `Bench`, `Facts`, `Mixed` | — | src/codegen/exe/Spec.zig | `Spec` | 230 | merge (171 doc lines, trim) |
| src/codegen/exe/parse.zig | 436 | `//!` lines of raw source → Spec | `parse` | — | src/codegen/exe/Spec.zig | `Spec.parse` | 330 | merge; 72 test lines → tests |
| src/codegen/exe/operands.zig | 479 | directive operand parsers (numbers, bindings, rows) | operand fns | `frontend.token_value.scaleExp` reused (fine) | src/codegen/exe/Spec.zig | `Spec` | 380 | merge; 59 test lines → tests |
| src/codegen/exe/facts.zig | 135 | Facts/Mixed from Lowered+Mir; W0750 | `compileFacts`, `mixedPlan` | — | src/codegen/exe.zig | `Exe` | 110 | merge |
| src/codegen/exe/runner.zig | 200 | fixed-grid runner Zig source writer | `writeRunner` | — | src/codegen/exe.zig | `Exe` | 170 | merge |
| src/codegen/exe/mixed.zig | 212 | §8 mixed-signal runner writer | `writeMixed` | emits `sim.digital.elaborate(source)` at runner start (F12) | src/codegen/exe.zig | `Exe` | 180 | merge |
| src/codegen/exe/vpi.zig | 86 | Clause 12 analog host lib writer | `writeVpiLib` | — | src/codegen/exe.zig | `Exe` | 80 | merge |
| src/codegen/exe/parts.zig | 248 | shared runner lines (head, cards, points, f64 literals) | `fmtF64`, writers | `fmtF64` vs kernels/fmt, cg_format | src/codegen/exe.zig | `Exe` | 190 | merge; 37 test lines → tests |
| src/codegen/exe/points.zig | 103 | cartesian sweep iterator | `Row`, `pointCount` | — | src/codegen/exe.zig | `Exe.Row` | 70 | merge |
| src/codegen/exe/table_checks.zig | 383 | runner text checking device comptime tables | 6 writers | point_checks.zig (same got/want/ok line shape) | src/codegen/exe/checks.zig | `Exe` | 300 | merge with point_checks; one got/want/ok row writer |
| src/codegen/exe/point_checks.zig | 169 | runner text checking noise/ac/acdyn/limit at a point | 4 writers | table_checks.zig | src/codegen/exe/checks.zig | `Exe` | 150 | merge |
| src/codegen/exe/text.zig | 39 | `@embedFile`s of `text/*.zig.txt` | 8 consts | — | — | — | 0 | delete: `@embedFile` at the use site (F11 for the .txt files) |
| src/codegen/verilog/root.zig | 152 | `emit`: ports→drive→sample→settle→write | `emit`, `Options`, `Error` | — | src/codegen/verilog.zig | `Verilog` (≈ zig codegen/c.zig `DeclGen`) | 110 | merge |
| src/codegen/verilog/ports.zig | 147 | pin kind per port from attrs / `--digital-pins` | `Pin`, `Attrs` | — | src/codegen/verilog.zig | `Verilog` | 120 | merge |
| src/codegen/verilog/drive.zig | 130 | which nodes contributions drive; vars | `Drive`, `Contrib` | — | src/codegen/verilog.zig | `Verilog` | 110 | merge |
| src/codegen/verilog/sample.zig | 142 | one Interp run per variable assignment | `Samples` | — | src/codegen/verilog.zig | `Verilog` | 120 | merge |
| src/codegen/verilog/settle.zig | 215 | residual/charge → bit, tau, delays | `Settled`, `Bit` | — | src/codegen/verilog.zig | `Verilog` | 185 | merge |
| src/codegen/verilog/refusal.zig | 108 | refusal reasons as data, frozen messages | `Refusal` | — | src/codegen/verilog.zig | `Verilog.Refusal` | 90 | merge |
| src/codegen/verilog/write.zig | 251 | IEEE 1364 text writer (truth tables, inertial assign) | `Plan`, `write` | — | src/codegen/verilog/write.zig | `Verilog` | 210 | keep (≤500 split) |
| src/codegen/verilog/Interp.zig | 245 | concrete MIR interpreter over `opcode.fold` | `Interp`, `Val` | prove/falsify.zig `evaluate/exec/value`; transfer.zig `device1/2` | src/Air/interp.zig | `Interp` | 220 | move; also the falsify oracle's evaluator (keeps the oracle independent of the prover) |


### A.5 src/codegen/device, src/zigbuild


Target layout (one struct per file or subfolder, Zig `Sema/` style subfiles for the house ≤500-code-line rule):
`src/codegen.zig` (dispatch) · `src/codegen/device.zig` (root + `generate`) · `device/DeclGen.zig` + `DeclGen/{residual,state,setup,limit}.zig`
· `device/Function.zig` + `Function/{render,call,print}.zig` · `device/Liveness.zig` + `Liveness/{jobs,core}.zig` · `device/tables.zig`
· `lib/std/kernels/{math,family,ac,storage}.zig` (real Zig, shipped) · `src/Air/facts/*` (upstream; owned by the Sema/Air map)
· `src/link.zig` + `src/link/{Zig.zig,Server.zig}`.

| current path | LOC | role (≤12 words) | key pub types | duplicates (path) | target path | absorbing struct | LOC after | action |
|---|---|---|---|---|---|---|---|---|
| D/root.zig | 65 | module root, re-exports only | — | — | — | — | 0 | delete (device.zig is root) |
| D/codegen.zig | 246 | `generate`: Mir+Lowered+Verdict → Output | Options, Device, Error, Display, VTy | — | src/codegen/device.zig | `generate` (= Z/codegen/c.zig:2280) | 150 | merge; drop `Analysis.build` (input) |
| D/Gen.zig | 422 | emitter state: inputs, 15 plans, out, Decl, accumulators | Gen, Decl, SystfSite | Z/codegen/c.zig:477/719 | device/DeclGen.zig + Function.zig | DeclGen (device) / Function (Decl) | 300 | split state by lifetime; plan fields leave |
| D/prepare.zig | 216 | runs every planner in data order, reports E0519/E0520/E0531 | prepare | — | device/Liveness.zig | Liveness.init | 60 | rewrite: semantic plans move upstream |
| D/cg_display.zig | 916 | §9.4/9.5/9.7 tasks → print blocks | buildArgs, emitDisplayTask… | lib/sim/digital/display.zig | device/Function/print.zig | Function | 600 | merge; call runtime walker |
| D/cg_file_io.zig | 338 | §9.5 file calls → file kernel calls | emitFileCall, emitMonitorArm | lib/sim/digital/files.zig | device/Function/print.zig | Function | 250 | merge |
| D/cg_filters.zig | 484 | laplace/zi → FilterPlan sections + coefficient readers | FilterPlan | — | Air facts (plan) + DeclGen/state.zig (emit) | Air.Facts.filters / DeclGen | 150 | split: planAll upstream |
| D/cg_format.zig | 591 | §9.4.3 format → std.fmt spec text | PrintArg, Spec, WidthRecord | lib/kernels/str_format.zig, kernels/fmt.zig:315 `spec`, analog/format.zig:221 `nextConv` | device/Function/print.zig | Function | 150 | rewrite: drop translateFormat/appendConv; keep operand typing |
| D/cg_limit_args.zig | 210 | $limit args → where read at clamp time | emitCore, writeArg | — | device/DeclGen/limit.zig | DeclGen | 180 | merge |
| D/cg_limit_seed.zig | 159 | $limit cold-start `seed` hook | emit | — | device/DeclGen/limit.zig | DeclGen | 140 | merge |
| D/cg_limit.zig | 493 | `limit` hook, reads/writes masks, W0853/W0854/E0527 | Live, emit | — | device/DeclGen/limit.zig | DeclGen | 380 | merge; diagnostics upstream |
| D/cg_say.zig | 250 | `.record` say sites + passes | SaySite, sayRecords | lib/contract/c_format.zig (host render) | device/Function/print.zig | Function | 200 | merge; `sayRecords` → ir/callee_table |
| D/cg_strcap.zig | 269 | string row capacities | cap, emitHeldType | — | device/Function/print.zig | Function | 260 | move |
| D/codegen/accept.zig | 384 | accepted-step work: updateState/acceptQ | emitAcceptQ | — | device/DeclGen/state.zig | DeclGen | 370 | merge (drop insertSlice patch :78) |
| D/codegen/breakpoints.zig | 141 | delays, next/pending breakpoint hooks | emitDelays | — | device/DeclGen/state.zig | DeclGen | 141 | move |
| D/codegen/call_analysis.zig | 361 | analysis()/ac_stim tests text | emitAnalysis | — | device/Function/call.zig | Function | 361 | merge |
| D/codegen/call_gate.zig | 204 | task per-pass gates, dropped tasks | emitTask | — | device/Function/call.zig | Function | 204 | merge |
| D/codegen/call_operator.zig | 366 | §4.5 operator kernel calls | emitOperator | — | device/Function/call.zig | Function | 350 | merge; drop out-text scan :63 |
| D/codegen/call_systf.zig | 189 | VPI user systf hand-off + table | emitSystfTable | — | device/Function/call.zig | Function | 189 | merge |
| D/codegen/call.zig | 629 | exhaustive switch over Mir.Callee | emitCall, abort | Z/codegen/c.zig airCall | device/Function/call.zig | Function | 600 | merge |
| D/codegen/card_checks.zig | 158 | checkShape/Card/Range | emitShapeCheck | — | device/DeclGen.zig | DeclGen | 158 | merge |
| D/codegen/cfg.zig | 536 | relooper: CFG → structured Zig | emitTree, renderCond | Z/codegen/c.zig airBlock/airLoop | device/Function.zig | Function | 536 | merge |
| D/codegen/collapse.zig | 156 | §5.6.5 collapse tables | emitCollapse | — | device/DeclGen/residual.zig | DeclGen | 156 | merge |
| D/codegen/dispatch_q.zig | 131 | `q` + site tables | emitQ | — | device/DeclGen/residual.zig | DeclGen | 131 | merge |
| D/codegen/dispatch.zig | 469 | eval/q/evalQ + Jac evidence | Jac | — | device/DeclGen/residual.zig | DeclGen | 455 | merge; drop out-scan :371 |
| D/codegen/family.zig | 270 | mask literals, zTo/zOf, lane_masks | Constant | — | device/DeclGen/residual.zig | DeclGen | 270 | merge |
| D/codegen/file.zig | 370 | the spine: emitFile + kernel splicing | Features, UnitFile | Z/link/C.zig:733 flush order | device/DeclGen.zig | DeclGen.genFile | 240 | merge; splice block → one `@import("kernels")` |
| D/codegen/float/lanes.zig | 185 | batch lane pinning decisions | — | — | device/Function.zig | Function | 185 | merge |
| D/codegen/float/mode.zig | 98 | per-job float mode | Float, Jac | — | device/Function.zig | Function | 60 | merge |
| D/codegen/harness.zig | 152 | test: parse+lower+gen a source | Harness | Compilation test path | tests/unit/device_harness.zig | — | 152 | move (frees device of frontend/analog deps) |
| D/codegen/host_expr.zig | 486 | param/control exprs as host f64 text, E0515 | f64Expr | — | device/Function/render.zig | Function | 486 | merge |
| D/codegen/instance.zig | 507 | Instance struct, State twin | emitInstance | — | device/DeclGen/state.zig | DeclGen | 507 | merge |
| D/codegen/jac_tables.zig | 190 | jac_pattern/deriv_reads/jac_const | emitPattern | — | device/DeclGen/residual.zig | DeclGen | 190 | merge |
| D/codegen/kernel_text/ac.zig | 263 | H(jω) kernels as string literal | ac_txt | — | lib/std/kernels/ac.zig | real Zig | 0 (230 in lib) | move as real Zig |
| D/codegen/kernel_text/family.zig | 131 | family helpers as string, widened by text replace | family_txt | — | lib/std/kernels/family.zig | `fn Family(comptime n_u)` | 0 (110 in lib) | move; comptime generic kills `wideText` |
| D/codegen/kernel_text/math.zig | 436 | Table 4-14/15 math kernels as string | math_txt | lib/kernels/fold.zig:346 `math`, :394 `clog2` | lib/std/kernels/math.zig | real Zig, also fold oracle | 0 (400 in lib) | move; fold calls the same fns |
| D/codegen/kernel_text/storage.zig | 204 | timepoint/array/absdelay kernels as string | tp_txt, hist_txt | lib/kernels/hist_kernels.zig | lib/std/kernels/storage.zig | real Zig | 0 (180 in lib) | move |
| D/codegen/kernel_text/unit_file.zig | 116 | `u/<key>.zig` alias prologue | appendAliases | — | — | — | 0 | delete (units import `kernels`) |
| D/codegen/kernel_text.zig | 231 | re-exports every kernel text | *_txt | lib/kernels/root.zig:104 `text` | — | — | 0 | delete (15-line header → DeclGen) |
| D/codegen/mask.zig | 169 | u64-word unknown sets + type text | Hex | std.bit_set | device/DeclGen/residual.zig | DeclGen | 80 | shrink: set ops via std.bit_set |
| D/codegen/model.zig | 436 | Model, given bits, derive | emitModel | — | device/DeclGen.zig | DeclGen | 436 | merge |
| D/codegen/noise.zig | 411 | noise/ac source tables emit | emitNoiseTable | — | device/DeclGen/state.zig | DeclGen | 411 | merge |
| D/codegen/opcode_zig.zig | 200 | Mir.Opcode → Zig spelling rows | Spell, Row | — | device/tables.zig | comptime table | 200 | merge |
| D/codegen/operator_ctrl.zig | 226 | operator control args per frame | ctrlEval | — | device/Function/call.zig | Function | 226 | merge |
| D/codegen/opvars.zig | 123 | op-point variable report | emitOpVarTable | — | device/DeclGen/state.zig | DeclGen | 123 | merge |
| D/codegen/op_zig.zig | 199 | OpKind → Instance fields rows | Slot, Row | — | device/tables.zig | comptime table | 199 | merge |
| D/codegen/plan/args.zig | 289 | call-arg value facts; Display enum | Display | — | device/Liveness.zig (Display → Compilation.Config) | Liveness | 260 | merge |
| D/codegen/plan/branches.zig | 142 | dead branches, edge actions | — | Z/Air/Liveness.zig | device/Liveness.zig | Liveness | 142 | merge |
| D/codegen/plan/core.zig | 416 | shared-core live-outs, field order | Core | Z/Air/Liveness.zig | device/Liveness/core.zig | Liveness | 416 | move |
| D/codegen/plan/inline.zig | 246 | use counts, inline/fuse decisions | — | Z/codegen/c.zig:477 locals | device/Liveness.zig | Liveness | 246 | merge |
| D/codegen/plan/jac.zig | 251 | deriv_reads/jac_const from evidence | JacConst | — | device/DeclGen/residual.zig | DeclGen | 251 | merge |
| D/codegen/plan/jobs.zig | 683 | every value the core returns, and why | Jobs, Job | — | device/Liveness/jobs.zig | Liveness | 683 | move |
| D/codegen/plan/limit.zig | 844 | $limit honoured/declined sites, seed tree | Limits, Alg | — | src/Air/facts (upstream) | Air.Facts.limits | 0 (≈700 upstream) | move upstream (it decides W0853) |
| D/codegen/plan/names.zig | 316 | identifiers + **appends branch-current unknowns** | Names | analog/node.zig:333 `flowUnknown` | split: unknowns → Lowered/Air; idents → DeclGen | DeclGen.ident | 100 | split; one owner of U |
| D/codegen/plan/noise.zig | 565 | noise rows + E0519/E0520 | Noise, NoiseRow | — | src/Air/facts (upstream) | Air.Facts.noise | 0 (≈550 upstream) | move upstream |
| D/codegen/plan/qsite.zig | 266 | §5.6.1.2 charge sites | QSites, Stamp | — | src/Air/facts (upstream) | Air.Facts.qsites | 0 (≈260 upstream) | move upstream |
| D/codegen/plan/topology.zig | 653 | free flows, collapsible switches, retention | Topology | codegen/verilog/drive.zig (contributions walk) | src/Air/facts (upstream) | Air.Facts.topology | 0 (≈640 upstream) | move upstream |
| D/codegen/plan/unit.zig | 824 | per-unit backward slice, slots | UnitPlan | Z/Air/Liveness.zig | device/Liveness.zig | Liveness | 824 | merge |
| D/codegen/prelude.zig | 162 | h.zig/prelude text, wideText, (de)publish | — | — | — | — | 0 | delete (kernels as module) |
| D/codegen/render_array.zig | 231 | §3.2.2 array storage/load text | — | — | device/Function/render.zig | Function | 231 | merge |
| D/codegen/render_op.zig | 602 | opcode → Zig expression | — | Z/codegen/c.zig airBinOp | device/Function/render.zig | Function | 600 | merge |
| D/codegen/render_sysfunc.zig | 216 | scan/rng/table/idx kernel calls | — | — | device/Function/render.zig | Function | 216 | merge |
| D/codegen/render.zig | 594 | value/inst → Zig text | Subst, Spine | Z/codegen/c.zig genBody | device/Function.zig | Function.genBody | 594 | merge |
| D/codegen/setup_chunk.zig | 947 | **re-parses emitted setup text** into chunks | chunk, hasWord | std.zig.Tokenizer/Ast | — | — | 0 | delete: DeclGen emits setup parts per root group |
| D/codegen/setup.zig | 544 | setup roots, Setup, setup fn | Setup | prove/setup.zig | device/DeclGen/setup.zig | DeclGen | 480 | merge; drop text patches :275-292 |
| D/codegen/stamp_lin.zig | 98 | linear stamp coefficients | — | — | device/DeclGen/residual.zig | DeclGen | 98 | merge |
| D/codegen/stamps.zig | 404 | §5.6 stamp rows | — | — | device/DeclGen/residual.zig | DeclGen | 404 | merge |
| D/codegen/state_ctl.zig | 214 | State twins, stateCtl | — | — | device/DeclGen/state.zig | DeclGen | 214 | merge |
| D/codegen/state.zig | 403 | state machine hooks | Accept | — | device/DeclGen/state.zig | DeclGen | 403 | merge |
| D/codegen/status.zig | 111 | §9.7.3 status sites | — | — | device/DeclGen/state.zig | DeclGen | 111 | merge |
| D/codegen/switch_row.zig | 268 | §5.6.1.3 switch-branch rows | — | — | device/DeclGen/residual.zig | DeclGen | 268 | merge |
| D/codegen/timepoint.zig | 220 | vera_timepoint fields/fills + block map | — | prove/timepoint.zig | DeclGen/state.zig (emit); tpBlocks upstream | DeclGen | 170 | split |
| D/codegen/unit_body.zig | 505 | slot declarations, hoist, body | Probe, Hoist, Place | Z/codegen/c.zig:477 locals/allocs | device/Function.zig | Function | 505 | merge |
| D/codegen/unit.zig | 545 | unit fn + core; **scans own output** | Uses, SimReads | std.zig.Tokenizer on output | device/Function.zig | Function.genUnit | 430 | merge; SimReads from Air, not text |
| D/codegen/unknowns.zig | 197 | U enum, abstol, nodeset, decl_meta | emitTopology | — | device/DeclGen.zig | DeclGen | 197 | merge |
| D/codegen/wide.zig | 325 | §5.4 wide integers → zw* calls | Read | — | device/Function/render.zig | Function | 325 | merge |
| ZB/root.zig | 100 | re-exports | — | — | src/link.zig | — | 0 | delete |
| ZB/argv.zig | 488 | zig command lines (lib, obj, link, engine) | Backend, Module, Split, Options | ZB/exe.zig:264 `argvHead`, ZB/check.zig argv; std.Build.Step.Compile.getZigArgs | src/link/Zig.zig | link.Zig.argv | 350 | merge 3 argv builders into one |
| ZB/artifact_cache.zig | 288 | whole-library cache key (Wyhash over lib/ trees) | key, fetch, store | std.Build.Cache Manifest | src/link.zig | Cache use | 60 | replace with std.Build.Cache |
| ZB/check.zig | 195 | `--check`: build-obj -fno-emit-bin, stderr text | Check, Verdict | ZB/server.zig | src/link.zig | link.Task.check | 30 | rewrite as a Task over Server |
| ZB/exe.zig | 398 | testbench build-exe/batch via std.process.run | BuildOptions, Staged, runtime_modules | ZB/library.zig | src/link/Zig.zig | link.File (.exe) | 150 | merge; Server path, ErrorBundle |
| ZB/library.zig | 517 | build spine: key, spawn N, write, link, publish | Artifact | Z/link.zig File.flush | src/link.zig | link.File + Queue | 300 | rewrite as tasks |
| ZB/server.zig | 293 | std.zig.Server protocol client | Server, Update | std.Build.Step evalZigProcess (private) | src/link/Server.zig | Server | 293 | keep (std has no public client) |
| ZB/shim.zig | 312 | root shims per part/chunk/engine | Piece, Part, Engine | — | src/link/Zig.zig | link.Zig | 120 | shrink: parts become modules, chunks gone |
| ZB/tree.zig | 360 | device tree on disk, writeIfChanged, Output | Output, Tree | Z/link/C.zig AvBlock | src/link/Zig.zig | link.Zig.writeTree | 250 | merge |


### A.6 lib/sim/digital, src/codegen/digital


#### lib/sim/digital

| current path | LOC | role (<=12 words) | key pub types | duplicates (path) | target path | absorbing struct | LOC after | action |
|---|---|---|---|---|---|---|---|---|
| lib/sim/digital/activations.zig | 256 | §10 sync/timed subroutine activations, automatic frames | Calls | lib/sim/rt/processes.zig (timed acts), codegen/digital/calls.zig | lib/std/sim/Interp.zig | Interp | 180 | merge (runtime) |
| lib/sim/digital/analog_link.zig | 266 | D2A reads, A2D monitors, analog events for mixed run | Link | lib/sim/mixed/monitors.zig | lib/std/sim/mixed.zig (+ registration → src/Sema/digital.zig) | State.analog | 200 | split |
| lib/sim/digital/bind.zig | 275 | §13 library/config binding: instance → module row | (fns) | src/elab/lookup.zig, lib/frontend/libmap.zig | src/Sema/lookup.zig | Sema (module lookup) | 150 | merge (compiler) |
| lib/sim/digital/bytecode.zig | 245 | Instruction union + Program; rows hold Ast.ExprId | Instruction, Program, Type | lib/sim/rt/design.zig `Design` | lib/std/sim/Program.zig | Program | 300 | rewrite (the fixed table) |
| lib/sim/digital/compile_holds.zig | 195 | §9.3 assign/force → hold process rows | Bits, Slice | lib/sim/rt/holds.zig (runtime half) | src/Sema/digital/stmt.zig | Sema.Digital | 120 | move (compiler) |
| lib/sim/digital/compile_stmt.zig | 562 | statement → Instruction rows | — | codegen/digital/instruction.zig (its inverse) | src/Sema/digital/stmt.zig | Sema.Digital | 450 | move (compiler) |
| lib/sim/digital/compile.zig | 847 | AST→bytecode spine, Routines, checkExpr (383 test lines) | Routines, Type, Bits | — | src/Sema/digital.zig | Sema.Digital | 300 | move; tests → tests/ |
| lib/sim/digital/constness.zig | 211 | §5.2 is-constant-expression check | — | lib/frontend/constfold.zig `firstStateRead` | src/Sema/digital/expr.zig | Sema (comptime check) | 60 | merge |
| lib/sim/digital/declared.zig | 234 | decl widths/bounds/delays folded by the runtime evaluator | Times, Decls | src/elab/fold.zig, lib/frontend/constfold.zig, rtlil_fold.zig | src/Sema (resolveConst) | Sema | 80 | merge |
| lib/sim/digital/display.zig | 938 | §17 format walk + value text; null-allocator validation mode | Show, Task, TimeFormat | kernels/str_format.zig, device/cg_display.zig, vpi/cformat.zig, contract/c_format.zig, analog/format.zig | lib/std/sim/display.zig (validation → Sema `Fmt` rows) | Program.fmts | 400 | split |
| lib/sim/digital/driver.zig | 462 | VAMS §9.22 driver access + elaboration-time `segregate` | State | src/elab/insert.zig, src/elab/segment.zig | lib/std/sim/driver.zig (+ segregate → Sema) | State.drv | 250 | split |
| lib/sim/digital/elab_declare.zig | 630 | declarations → slots, events, named blocks, implicit nets | — | src/elab/clone_decl.zig, src/elab/decl_check.zig | src/Sema/digital/decl.zig | Sema | 300 | merge |
| lib/sim/digital/elab_defparams.zig | 269 | defparam binding against hierarchy | — | src/elab/defparam.zig (532) | src/Sema/defparam.zig | Sema | 0 | delete (src/elab has it) |
| lib/sim/digital/elab_drivers.zig | 473 | cont. assigns, gates, switches, port bridges → driver rows | — | src/elab/instance.zig (port nets), codegen/digital/nets.zig | src/Sema/digital/nets.zig | Sema | 350 | move |
| lib/sim/digital/elab_generate.zig | 364 | §12.4 generate scopes, genvars | — | src/elab/generate.zig (521) | src/Sema/generate.zig | Sema | 0 | delete (src/elab has it) |
| lib/sim/digital/elab_params.zig | 284 | parameter values + overrides, specify ordering | — | src/elab/override.zig, src/elab/hier_param.zig, src/elab/fold.zig | src/Sema/params.zig | Sema | 60 | merge |
| lib/sim/digital/elab_paths.zig | 154 | specify module paths → delay tables | — | — | src/Sema/digital/specify.zig | Sema | 140 | move |
| lib/sim/digital/elab_ports.zig | 373 | port connections, by position/name, instance arrays | — | src/elab/ports.zig (627) | src/Sema/ports.zig | Sema | 80 | merge |
| lib/sim/digital/elab_slots.zig | 291 | slot allocation for vars/arrays/nets/frames, wreal | — | — | src/Sema/digital/decl.zig | Sema | 200 | merge |
| lib/sim/digital/elab_stages.zig | 552 | spine: parse, top, timescales, declare…arm | Parsed, Top | rtlil.zig `emitDeep` parse, src/elab/elaborate.zig | Compilation (parse) + src/Sema/digital.zig | Sema | 150 | delete parse; merge |
| lib/sim/digital/elab_steps.zig | 294 | disables, net runs, process order, time-0 queue | — | — | src/Sema/digital.zig | Sema | 200 | move |
| lib/sim/digital/elab_udps.zig | 140 | §8 UDP table check/bind | — | src/elab/primitive.zig (partial) | src/Sema/digital/decl.zig | Sema | 120 | move |
| lib/sim/digital/elab_warnings.zig | 162 | §12.3 port width/direction warnings | — | src/elab/ports.zig shape checks | src/Sema/ports.zig | Sema | 60 | merge |
| lib/sim/digital/elab.zig | 1020 | instance-tree walk, Elab, pickTops (492 test lines) | Elab | src/elab/elaborate.zig, walk.zig, instance.zig, lookup.zig | src/Sema.zig (Instance walk) | Sema / Zcu.Instance | 200 | merge |
| lib/sim/digital/evaluate.zig | 635 | AST expression eval over heap Int.Literal | Place, Sel | codegen/digital/expr.zig, rtlil_expr.zig, rt/logic/operators.zig | lib/std/sim/eval.zig | Eval | 350 | rewrite over Program.exprs + rt.logic |
| lib/sim/digital/evcd.zig | 669 | §18.3 extended VCD writer | File | lib/sim/rt/evcd.zig (241) | lib/std/sim/dump/evcd.zig | Dumps | 400 | merge with rt |
| lib/sim/digital/exec_delays.zig | 79 | delay expr → ticks | — | codegen/digital/timing.zig | lib/std/sim/Interp.zig | Interp | 30 | merge (constants folded in Sema) |
| lib/sim/digital/exec.zig | 1108 | dispatch: Pending rows, execute(pc) (333 test lines) | Pending, Row, Rows, Scratch | codegen/digital/instruction.zig, rt/processes.zig | lib/std/sim/Interp.zig | Interp | 500 | rewrite on Program.Inst |
| lib/sim/digital/expr_types.zig | 586 | §5.4/5.5 sizing; Typing keyed by (scope,ExprId) | Typing | lib/frontend/constfold_size.zig, rtlil_expr.zig `shape`, analog sizing | src/Sema/sizing.zig | Sema | 250 | merge (one sizer) |
| lib/sim/digital/files.zig | 635 | §17.2 file tasks over contract.FileIo | — | lib/sim/rt/system.zig, kernels/file_table.zig | lib/std/sim/system/files.zig | State.tasks | 400 | merge with rt |
| lib/sim/digital/gate_tables.zig | 456 | §7.8.5 gate, §7.6 switch, §8 UDP tables | — | — | lib/std/sim/net/gates.zig | — | 290 | move |
| lib/sim/digital/instructions.zig | 278 | sys task / driver / §9.3 instruction bodies | — | codegen/digital/tasks.zig, drivers.zig | lib/std/sim/Interp.zig | Interp | 200 | merge |
| lib/sim/digital/monitor.zig | 352 | $monitor/$fmonitor end-of-step lines | Monitoring | lib/sim/rt/observe.zig | lib/std/sim/system/monitor.zig | State.monitoring | 250 | merge with rt |
| lib/sim/digital/name_search.zig | 439 | name → slot at run time, memo hash | Hierarchy | src/elab/flat_name.zig, src/elab/lookup.zig | src/Sema (bind once) + Program.scopes | Sema | 100 | rewrite |
| lib/sim/digital/net.zig | 829 | net types, strengths, Driver/Net/Delay tables | Net, NetCold, Driver, Delay, Tran | lib/sim/rt/net/* (imports it) | lib/std/sim/net/root.zig | Program.nets | 600 | move |
| lib/sim/digital/options.zig | 195 | Options, Mixed, Param, Insert | Options, Mixed, Insert | Compilation.Config, src/cli/args.zig | Compilation.Config + lib/std/sim/root.zig RunOptions | — | 60 | split |
| lib/sim/digital/places.zig | 420 | lvalue → place, writes, selects | Place | codegen/digital/assign.zig, expr_select.zig | lib/std/sim/eval.zig | Eval | 180 | merge |
| lib/sim/digital/queues.zig | 254 | §17.6 stochastic queues | — | — | lib/std/sim/system/queues.zig | State.tasks | 180 | move |
| lib/sim/digital/readmem.zig | 693 | §17.2.9 memory file reader | — | rt/tasks.zig (calls it) | lib/std/sim/system/readmem.zig | — | 500 | move |
| lib/sim/digital/real_eval.zig | 275 | real expressions, §4.8.2 conversions | — | codegen/digital/expr_real.zig, rt/logic/reals.zig | lib/std/sim/eval.zig | Eval | 100 | merge |
| lib/sim/digital/resolution.zig | 1060 | net resolution engine, delayed transitions (434 test lines) | — | lib/sim/rt/net/resolution.zig (591) | lib/std/sim/net/resolution.zig | — | 450 | merge with rt |
| lib/sim/digital/root.zig | 927 | run/elaborate spine + 40 re-exports (508 test lines) | Error, for_emitter | — | lib/std/sim/root.zig | — | 60 | rewrite; tests → tests/ |
| lib/sim/digital/run_diag.zig | 98 | runtime/elab refusal → E-code | — | — | lib/std/sim/State.zig | State | 60 | merge |
| lib/sim/digital/run_nets.zig | 135 | net cold rows, transition state | Netlist | rt/net/layout.zig | lib/std/sim/net/root.zig | State.nets | 100 | merge |
| lib/sim/digital/run_rows.zig | 333 | row types: Name, Array, Sub, Frame, Monitor… | ~25 rows | rt/records.zig | Program.zig (static) / State.zig (dynamic) | Program, State | 120 | split |
| lib/sim/digital/run_until.zig | 217 | §11 event loop, upward name search | EventBudget | rt/main.zig `loop`, rt/engine.zig | lib/std/sim/Interp.zig | Interp | 150 | merge |
| lib/sim/digital/Run.zig | 446 | god struct: compile tables + run state + 50 method aliases | Run | lib/sim/rt/State.zig (955) | lib/std/sim/State.zig | State | 200 | rewrite (drop compile fields) |
| lib/sim/digital/scanf.zig | 472 | $sscanf/$fscanf | — | kernels/str_scan.zig (334) | kernels/str_scan.zig (+4-state convs) | — | 100 | delete; extend kernels |
| lib/sim/digital/sdf_text.zig | 198 | SDF S-expression reader | — | — | lib/std/sim/sdf.zig | — | 180 | merge |
| lib/sim/digital/sdf.zig | 585 | $sdf_annotate onto instances by name | — | — | lib/std/sim/sdf.zig | — | 520 | keep (runtime file read; uses Program.scopes) |
| lib/sim/digital/signal.zig | 635 | §7.9/§7.10 strength-signal resolution (321 test lines) | Signal | — | lib/std/sim/net/signal.zig | — | 310 | move |
| lib/sim/digital/system_functions.zig | 304 | SysFn table: arg checks, result types | SysFn | src/analog/sysfunc_context.zig, src/ir/callee.zig | src/Sema/sysfn.zig (one table, analog+digital) | Sema | 250 | move |
| lib/sim/digital/system.zig | 477 | §17 stateful tasks | TaskState, Queue | lib/sim/rt/system.zig (292) | lib/std/sim/system/root.zig | State.tasks | 300 | merge with rt |
| lib/sim/digital/tchk_build.zig | 418 | timing checks → Tchk rows bound to slots | — | — | src/Sema/digital/specify.zig | Sema | 350 | move |
| lib/sim/digital/tchk.zig | 973 | §15 timing checks at run time (321 test lines) | Checks, Tchk | — | lib/std/sim/tchk.zig | State.checks | 600 | keep |
| lib/sim/digital/vcd_text.zig | 222 | VCD id codes, value text, %.16g | — | — | lib/std/sim/dump/vcd.zig | — | 130 | merge |
| lib/sim/digital/vcd.zig | 722 | §18.1 VCD writer | Dumps, Catalog | lib/sim/rt/observe.zig | lib/std/sim/dump/vcd.zig | Dumps | 550 | keep |
| lib/sim/digital/vpi.zig | 145 | VPI requests: eval retained expr, UDP put | Host | src/vpi/* (73 Run sites) | lib/std/sim/vpi.zig | State.host | 100 | keep, over Program.exprs |
| lib/sim/digital/waiters.zig | 1005 | write path, wake fan-out/terms/watch (215 test lines) | Waits, ProcAssigns | lib/sim/rt/waiters.zig (313), rt/holds.zig, rt/stores.zig | lib/std/sim/waiters.zig | State.waits | 500 | merge with rt |
| lib/sim/digital/wait_lists.zig | 485 | event control / @* → slot lists | — | codegen/digital/timing.zig, plan_nodes.zig | src/Sema/digital/stmt.zig | Sema.Digital | 350 | move |

#### src/codegen/digital

| current path | LOC | role (<=12 words) | key pub types | duplicates (path) | target path | absorbing struct | LOC after | action |
|---|---|---|---|---|---|---|---|---|
| src/codegen/digital/assign.zig | 340 | assignment → Zig store over rt | — | sim/digital/places.zig, evaluate.zig | src/codegen/digital.zig | Function | 250 | rewrite on Program |
| src/codegen/digital/calls.zig | 126 | §10 call → activation Zig | — | sim/digital/activations.zig | src/codegen/digital.zig | Function | 100 | merge |
| src/codegen/digital/design_table.zig | 271 | writes `const design: rt.Design` literal | — | rt/design.zig (it IS the table) | src/codegen/digital.zig (serialize Program) | Function | 120 | rewrite: dump Program |
| src/codegen/digital/device.zig | 155 | .v top → contract device root | Device, DeviceRoot | — | src/codegen/digital/device.zig | Function | 130 | keep |
| src/codegen/digital/drivers.zig | 203 | continuous driver / gate → Zig | — | sim/digital/instructions.zig | src/codegen/digital.zig | Function | 150 | merge |
| src/codegen/digital/Emitter.zig | 213 | emission state holding `*Run` | Emitter, Logic, Reason | codegen/c.zig Function shape | src/codegen/digital.zig | Function | 150 | rewrite (`*const Program`) |
| src/codegen/digital/expr.zig | 419 | AST expr → Zig, "evalContext arm for arm" | — | sim/digital/evaluate.zig | src/codegen/digital.zig genExpr | Function | 600 (all four expr files) | merge to one switch on Expr.Tag |
| src/codegen/digital/expr_real.zig | 179 | real AST expr → Zig f64 | — | sim/digital/real_eval.zig | src/codegen/digital.zig genExpr | Function | 0 (in expr) | merge |
| src/codegen/digital/expr_select.zig | 169 | selects → Zig over rt.logic | — | sim/digital/places.zig | src/codegen/digital.zig genExpr | Function | 0 (in expr) | merge |
| src/codegen/digital/expr_system.zig | 266 | system functions → Zig | — | sim/digital/system.zig | src/codegen/digital.zig genExpr | Function | 0 (in expr) | merge |
| src/codegen/digital/instruction.zig | 312 | Instruction → switch prong, "exec.execute arm for arm" | — | sim/digital/exec.zig | src/codegen/digital.zig genInst | Function | 250 | rewrite on Program.Inst |
| src/codegen/digital/layout.zig | 216 | slot → plane word layout, block ends, forced parts | Planes, BlockEnds | Program.slots.word (new) | src/codegen/digital.zig | Function | 60 | shrink: layout is a Program column |
| src/codegen/digital/native.zig | 203 | native spine: layout, plan, processes, tables | — | — | src/codegen/digital.zig `generate` | Function | 150 | keep |
| src/codegen/digital/nets.zig | 190 | which nets go through rt.net | Rows, PortFile | sim/digital/elab_drivers.zig | src/Air/digital/NetPlan (pass) | Schedule | 100 | move to pass |
| src/codegen/digital/plane_words.zig | 55 | width → plane words/masks | — | rt/logic `words` | lib/std/sim/rt/logic | — | 0 | delete |
| src/codegen/digital/plan_nodes.zig | 306 | settle-node / triggered candidates | — | sim/digital/wait_lists.zig | src/Air/digital/Schedule.zig | Schedule | 550 (with plan) | move to pass |
| src/codegen/digital/plan.zig | 473 | scheduling plan: reach, roles, topo nodes | Plan, Reach, Schedule | — | src/Air/digital/Schedule.zig (= Air/Liveness.zig shape) | Schedule | 0 (in plan_nodes row) | merge |
| src/codegen/digital/processes.zig | 146 | process → Zig fn + pc dispatch table | — | — | src/codegen/digital.zig | Function | 120 | keep |
| src/codegen/digital/program.zig | 107 | exe root; fallback embeds source + rt.interpret | Embed, Program | rt/main.zig interpret | src/codegen/digital.zig | Function | 40 | rewrite: no source embed |
| src/codegen/digital/root.zig | 82 | re-exports | — | — | src/codegen/digital.zig | — | 20 | merge |
| src/codegen/digital/rtlil.zig | 88 | --emit-rtlil: re-preprocess + reparse | Error | sim/digital/elab_stages.zig parse | src/codegen/rtlil.zig | Rtlil | 20 | rewrite: input = Program |
| src/codegen/digital/rtlil_emitter.zig | 378 | RTLIL state, sigspec/cell writers | Emitter, Proc, Shape | — | src/codegen/rtlil.zig | Rtlil | 250 | keep |
| src/codegen/digital/rtlil_expr.zig | 404 | expr → sigspec/$cells with own sizing | — | sim/digital/expr_types.zig, evaluate.zig | src/codegen/rtlil.zig | Rtlil | 300 | rewrite on Program.exprs |
| src/codegen/digital/rtlil_fold.zig | 492 | own 4-state constant folder | — | frontend/constfold.zig, src/elab/fold.zig, declared.zig, kernels/fold | — | — | 0 | delete (Sema folds) |
| src/codegen/digital/rtlil_module.zig | 361 | per-module wires/assigns/gates/instances | — | sim/digital/elab_drivers.zig | src/codegen/rtlil.zig | Rtlil | 250 | rewrite over Program instances |
| src/codegen/digital/rtlil_proc.zig | 245 | always/initial → RTLIL process | — | — | src/codegen/rtlil.zig | Rtlil | 220 | keep |
| src/codegen/digital/rtlil_table.zig | 127 | own symbol table per module | — | sim/digital/name_search.zig | — | — | 0 | delete (Program.slots) |
| src/codegen/digital/settle.zig | 129 | settle-node Zig functions | — | — | src/codegen/digital.zig | Function | 110 | keep |
| src/codegen/digital/show.zig | 301 | $display formats walked at emit time | — | sim/digital/display.zig walk | src/codegen/digital.zig | Function | 150 | shrink: reads Program.fmts |
| src/codegen/digital/step_local.zig | 292 | must-write-before-read dataflow for --state=auto | — | — | src/Air/digital/StepLocal.zig (one forward pass) | — | 250 | move to pass |
| src/codegen/digital/tasks.zig | 252 | `.task` instruction → Zig | — | sim/digital/instructions.zig | src/codegen/digital.zig | Function | 200 | merge |
| src/codegen/digital/timing.zig | 128 | delays/event terms → Zig | — | sim/digital/exec_delays.zig, wait_lists.zig | src/codegen/digital.zig | Function | 80 | shrink: delays pre-folded |
| (new) src/Sema/digital/expr.zig | 0 | Ast/Vir expr → typed, bound Expr rows | — | replaces 3 AST walkers | src/Sema/digital/expr.zig | Sema.Digital | 600 | new |


### A.7 lib/sim/{rt,mixed,scheduler,time}, lib/kernels, lib/contract, lib/osdi_dyn


#### lib/sim/rt → lib/std/sim/ (the runtime of emitted executables; mirrors lib/std/start.zig + lib/compiler_rt.zig)

| current path | LOC | role | used by | duplicates | target path | absorbing struct | LOC after | action |
|---|---|---|---|---|---|---|---|---|
| lib/sim/root.zig | 31 | namespace: digital, time, scheduler, mixed, rt | X | — | lib/std/sim.zig | `sim` namespace | 0 | merge → sim.zig |
| lib/sim/rt/root.zig | 108 | `sim.rt.<name>` re-exports, emitted code's ABI | X | — | lib/std/sim.zig | `sim` namespace | 230 | merge (root+main+sim/root) |
| lib/sim/rt/main.zig | 198 | exe `main`, `--state=auto` phases, interpreter fallback | X | — | lib/std/sim.zig | `sim` (like std/start.zig) | 0 | merge; delete `interpret` (finding 9) |
| lib/sim/rt/State.zig | 955 | one native run; 128 method forwarders | X | digital/Run.zig | lib/std/sim/State.zig | `State` | 1100 | keep, absorb records+diagnostics |
| lib/sim/rt/records.zig | 118 | State row types, payload map | X | digital/waiters.zig Susp/Term | lib/std/sim/State.zig | `State` | 0 | merge |
| lib/sim/rt/diagnostics.zig | 61 | E1100/W11xx lines on stderr | X | digital/run_diag.zig | lib/std/sim/State.zig | `State` | 0 | merge |
| lib/sim/rt/design.zig | 236 | `Design` tables the emitter writes as constants | X | — | lib/std/sim/Design.zig | `Design` | 230 | move/rename |
| lib/sim/rt/planes.zig | 329 | plane reads/writes, `View`, repeat counts | X | digital/places.zig | lib/std/sim/State/planes.zig | `State` | 540 | merge planes+stores |
| lib/sim/rt/stores.zig | 237 | store a slot, dirty marks | X | digital/waiters.zig `store` | lib/std/sim/State/planes.zig | `State` | 0 | merge |
| lib/sim/rt/waiters.zig | 313 | slot change wakes event controls/processes | X | digital/waiters.zig, wait_lists.zig | lib/std/sim/State/waiters.zig | `State` | 313 | move |
| lib/sim/rt/nonblocking.zig | 126 | NBA rows | X | digital/run_rows.zig | lib/std/sim/State/updates.zig | `State` | 300 | merge nonblocking+holds |
| lib/sim/rt/holds.zig | 187 | assign/force/release/disable | X | digital/compile_holds.zig, exec.zig | lib/std/sim/State/updates.zig | `State` | 0 | merge |
| lib/sim/rt/processes.zig | 264 | continuations, §10 activations, frames | X | digital/activations.zig | lib/std/sim/State/processes.zig | `State` | 264 | move |
| lib/sim/rt/observe.zig | 179 | $strobe/$monitor/VCD region events | X | digital/monitor.zig | lib/std/sim/State/display.zig | `State` | 340 | merge observe+transcript |
| lib/sim/rt/transcript.zig | 180 | §17.1 operand text onto transcript | X | digital/display.zig (shares it) | lib/std/sim/State/display.zig | `State` | 0 | merge |
| lib/sim/rt/system.zig | 292 | §17.2 file I/O, held $sformat | X | digital/system.zig, files.zig (shares) | lib/std/sim/State/tasks.zig | `State` | 480 | merge system+tasks |
| lib/sim/rt/tasks.zig | 209 | $time/$random/$readmem/$stop tasks | X | digital/system_functions.zig | lib/std/sim/State/tasks.zig | `State` | 0 | merge |
| lib/sim/rt/evcd.zig | 241 | $dumpports for native exe | X | digital/evcd.zig (`Dump` adapter twice) | lib/std/sim/evcd.zig | `Dump` | 200 | one `Dump` adapter shared |
| lib/sim/rt/snapshot.zig | 316 | State ↔ bytes at tick boundary | X | — | lib/std/sim/snapshot.zig | `State` | 316 | move |
| lib/sim/rt/engine.zig | 172 | prebuilt-engine C seam (`exportAll`) | X (zigbuild/shim.zig:64) | — | lib/std/sim/engine.zig | — | 172 | move |
| lib/sim/rt/device.zig | 614 | native `.v` design as contract device, A2D/D2A bridges | X (codegen/digital/device.zig:116) | digital/analog_link.zig | lib/std/sim/Device.zig | `Device` | 614 | move |
| lib/sim/rt/logic/root.zig | 206 | 63 `L.<name>` re-exports | X | — | lib/std/sim/logic.zig | `logic` | 80 | trim (doc-only lines) |
| lib/sim/rt/logic/values.zig | 286 | `W`, `Wide(n)`, masks, extension | X | kernels/integer_words.zig | lib/std/sim/logic/values.zig | — | 286 | move |
| lib/sim/rt/logic/operators.zig | 571 | comptime-width 4-state operators | X | kernels/integer_logic/arith (oracle), wide_kernels | lib/std/sim/logic/operators.zig | — | 550 | wide mul/div → `wide.zwL` (finding 10) |
| lib/sim/rt/logic/reals.zig | 253 | real↔int conversions, $rtoi | X | digital/real_eval.zig | lib/std/sim/logic/reals.zig | — | 253 | move |
| lib/sim/rt/logic/selects.zig | 351 | bit/part selects, concat, case match | X | digital/evaluate.zig | lib/std/sim/logic/selects.zig | — | 351 | move |
| lib/sim/rt/net/root.zig | 94 | `rt.net.<name>` re-exports | X | — | lib/std/sim/net.zig | `Nets` | 60 | trim |
| lib/sim/rt/net/layout.zig | 342 | §7.9 net/driver tables, `Nets` | X | digital/net.zig tables (shared) | lib/std/sim/net/layout.zig | `Nets` | 342 | move |
| lib/sim/rt/net/driving.zig | 271 | driver output → resolution queue | X | digital/resolution.zig gateValue/udpValue | lib/std/sim/net/drive.zig | `Nets` | 330 | merge driving+switches |
| lib/sim/rt/net/switches.zig | 72 | tran switch group re-resolve | X | digital/resolution.zig `Switches` | lib/std/sim/net/drive.zig | `Nets` | 0 | merge |
| lib/sim/rt/net/resolution.zig | 591 | resolve, inertial delay, decay | X | digital/resolution.zig (1060) | lib/std/sim/net/resolve.zig | `Nets` | 690 | merge resolution+module_paths |
| lib/sim/rt/net/module_paths.zig | 111 | §14 module path delays | X | digital/net.zig pathTable | lib/std/sim/net/resolve.zig | `Nets` | 0 | merge |

#### lib/sim/{mixed,scheduler,time}

| current path | LOC | role | used by | duplicates | target path | absorbing struct | LOC after | action |
|---|---|---|---|---|---|---|---|---|
| lib/sim/mixed/root.zig | 27 | `sim.mixed` names | X (tb runner text), vpi/host.zig | — | lib/std/sim/mixed.zig | — | 0 | merge into run |
| lib/sim/mixed/run.zig | 878 | VAMS §8 mixed run spine (544 test lines) | X, src/vpi | — | lib/std/sim/mixed.zig | `mixed.run` | 880 | move; retarget to `sim.State` (finding 9) |
| lib/sim/mixed/coordinator.zig | 341 | digital `Run` + analog solver lockstep | X | — | lib/std/sim/mixed/coordinator.zig | `Coordinator(A)` | 610 | merge coordinator+monitors |
| lib/sim/mixed/monitors.zig | 291 | cross/above/timer/absdelta A2D | X | kernels/timer_kernels (shared) | lib/std/sim/mixed/coordinator.zig | `Coordinator(A)` | 0 | merge |
| lib/sim/scheduler.zig | 1125 | §11/§8.5 region queue over `std.PriorityQueue` | X, digital, vpi | — | lib/std/sim/scheduler.zig | `Scheduler` | 1125 | move as-is |
| lib/sim/time.zig | 438 | §19.8 timescale → exact ticks | X, digital, vpi | — | lib/std/sim/time.zig | `Scale` | 438 | move as-is |

#### lib/kernels → lib/std/kernels/ (= lib/compiler_rt + std.math: run-time kernels AND the compiler's fold oracle)

| current path | LOC | role | used by | duplicates | target path | absorbing struct | LOC after | action |
|---|---|---|---|---|---|---|---|---|
| lib/kernels/root.zig | 170 | re-exports + `deviceText` splice machinery | C, D, X | src/codegen/device/codegen/kernel_text/unit_file.zig `appendAliases` | lib/std/kernels.zig | `kernels` | 70 | delete splicing (finding 1) |
| lib/kernels/str_real.zig | 468 | C11 %e/%f/%g/%r, exact rounding | C (analog/format, cg_format, codegen/digital/show), D, X | contract/c_format.zig, vpi/cformat.zig | lib/std/kernels/printf.zig | — | 650 | merge str_real+str_format; absorbs c_format users |
| lib/kernels/str_format.zig | 204 | run-time format string `zSFormatRt` | D | sim/digital/display.zig (1364 side) | lib/std/kernels/printf.zig | — | 0 | merge |
| lib/kernels/str_scan.zig | 334 | §9.5.4.2 $sscanf/$fscanf | D | sim/digital/scanf.zig (472) | lib/std/kernels/str.zig | — | 560 | merge str_scan+str_store |
| lib/kernels/str_store.zig | 244 | per-site string rows, $monitor latch | D | — | lib/std/kernels/str.zig | — | 0 | merge |
| lib/kernels/file_table.zig | 618 | §9.5 descriptor table `ZfTable` | D, X (digital/files, rt/State) | — | lib/std/kernels/file.zig | `ZfTable` | 800 | merge file_table+file_kernels |
| lib/kernels/file_kernels.zig | 226 | `zF*` ABI over `ZfTable`, `contract.FileIo` | D, X | — | lib/std/kernels/file.zig | `ZfTable` | 0 | merge |
| lib/kernels/rng_kernels.zig | 421 | §17.9.3 listing, bit-exact $dist_* | C (elab/dist, paramset_dist, ir/Lowered), D, X | — | lib/std/kernels/rng.zig | — | 421 | move (std.Random unusable, finding 4) |
| lib/kernels/table_kernels.zig | 406 | §9.21 $table_model interpolation | D | — | lib/std/kernels/table.zig | — | 406 | move |
| lib/kernels/filter_kernels.zig | 547 | §4.5.11/12 laplace/zi filters | D | — | lib/std/kernels/filter.zig | — | 547 | move |
| lib/kernels/limit_kernels.zig | 233 | §4.5.15 pnjlim/fetlim/limvds, branchless | D (probe: tests/codegen_probe.zig) | — | lib/std/kernels/limit.zig | — | 233 | move |
| lib/kernels/hist_kernels.zig | 228 | §4.5.7 absdelay ring | D | — | lib/std/kernels/ops.zig | — | 470 | merge hist+ops+timer |
| lib/kernels/ops_kernels.zig | 172 | §4.5 idt/slew/transition (private, text only) | D | — | lib/std/kernels/ops.zig | — | 0 | merge |
| lib/kernels/timer_kernels.zig | 77 | §5.10.3.3 timer deadlines | D, X (mixed) | — | lib/std/kernels/ops.zig | — | 0 | merge |
| lib/kernels/wide_kernels.zig | 624 | non-allocating any-width 2-state ints | D | rt/logic/operators.zig `big` | lib/std/kernels/wide.zig | `ZW(n)` | 624 | move; reuse from rt (finding 10) |
| lib/kernels/integer.zig | 384 | 4-state `Literal` type, shape ops | C (frontend literals, rtlil_fold), X | rt/logic/values.zig | lib/std/kernels/Integer.zig | `Literal` | 480 | absorb integer_words |
| lib/kernels/integer_words.zig | 114 | word count/mask/extension helpers | C, X | rt/logic/values.zig masks | lib/std/kernels/Integer.zig | `Literal` | 0 | merge |
| lib/kernels/integer_arith.zig | 574 | arithmetic via `std.math.big.int.Managed` | C, X | wide_kernels | lib/std/kernels/Integer/arith.zig | `Literal` | 574 | move |
| lib/kernels/integer_logic.zig | 608 | bitwise/shift/relational/reduce | C, X | rt/logic/operators.zig | lib/std/kernels/Integer/logic.zig | `Literal` | 608 | move |
| lib/kernels/integer_parse.zig | 346 | literal text → `Literal` (big for decimal) | C, X | frontend/token_value.zig | lib/std/kernels/Integer/parse.zig | `Literal` | 346 | move (or → std/vams/number_literal.zig) |
| lib/kernels/integer_fixture.zig | 56 | test patterns for integer*.zig | T | — | tests/unit/integer_tests.zig | — | 0 | move to tests |
| lib/kernels/ref4.zig | 676 | per-bit §5 oracle, no shared code | T | — | tests/ref4.zig | — | 0 | move to tests (like rng_reference.zig) |
| lib/kernels/fmt.zig | 840 | §17.1 4-state radix/time text | C (codegen/digital/show), X | digital/display.zig (delegates) | lib/std/kernels/fmt.zig | — | 840 | move |
| lib/kernels/fold.zig | 708 | §4.2 `Const` folds, operator enums | C only | frontend/constfold, elab/fold, analog/constfold, ir/opcode | lib/std/kernels/fold.zig | `Const` | 708 | move (one fold oracle) |

#### lib/contract.zig + lib/contract/ → lib/std/contract.zig + contract/ (the device ABI, installed; like lib/std/lang.zig: types compiler and user code agree on)

| current path | LOC | role | used by | duplicates | target path | absorbing struct | LOC after | action |
|---|---|---|---|---|---|---|---|---|
| lib/contract.zig | 331 | version, host_strings, 81 re-exports | C, D, H | — | lib/std/contract.zig | `contract` | 260 | mock tests → tests/unit; absorb build_config |
| lib/contract/build_config.zig | 49 | `validating`, `DevicePart` | D, H | — | lib/std/contract.zig | — | 0 | merge |
| lib/contract/display_records.zig | 279 | Status/Say records + render | D, H, C (analog/status) | — | lib/std/contract/display.zig | `Say` | 494 | merge with c_format glue |
| lib/contract/c_format.zig | 506 | 2nd C printf over `std.fmt.float` | H (via formatSay/Status) | kernels/str_real.zig, vpi/cformat.zig | lib/std/contract/display.zig | `Say` | 0 | delete renderer, call `printf.zCReal` (finding 2) |
| lib/contract/sim_state.zig | 177 | SimState, UpdateResult, StateClass | D, H | — | lib/std/contract/sim_state.zig | `SimState` | 177 | keep |
| lib/contract/metadata.zig | 94 | DeclMeta, UnknownKind | D, H | — | lib/std/contract/metadata.zig | `DeclMeta` | 94 | keep |
| lib/contract/host.zig | 146 | `validateHost` obligations | D, H | — | lib/std/contract/host.zig | — | 433 | merge host+host_fields+host_callbacks |
| lib/contract/host_fields.zig | 132 | host-written field tables | D, H | — | lib/std/contract/host.zig | — | 0 | merge |
| lib/contract/host_callbacks.zig | 200 | Systf, SystfHost, FileIo | D, H | — | lib/std/contract/host.zig | `Systf` | 0 | merge |
| lib/contract/ac.zig | 194 | AC stimuli, ac_dyn_slots | D, H | — | lib/std/contract/ac.zig | `AcGen` | 145 | mock tests → tests/unit |
| lib/contract/noise.zig | 351 | NoiseGen, NoiseTable, PSD | D, H, C, osdi | — | lib/std/contract/noise.zig | `NoiseTable` | 240 | mock tests → tests/unit |
| lib/contract/masks.zig | 358 | deriv/limit/ddx masks, jac_const | D, H | — | lib/std/contract/jacobian.zig | `Mask(D)` | 400 | merge masks+rows; mock tests out |
| lib/contract/rows.zig | 257 | Rows/Sites/qRows, charge sites | D, H | — | lib/std/contract/jacobian.zig | `Rows` | 0 | merge |
| lib/contract/family.zig | 511 | `RefFamily` value+derivative lanes | D, H, osdi, tests/host | — | lib/std/contract/family.zig | `RefFamily` | 670 | merge family+family_check |
| lib/contract/family_check.zig | 170 | `expectFamily` host-family checker | H | — | lib/std/contract/family.zig | — | 0 | merge |
| lib/contract/lead.zig | 356 | batch_lead protocol, LeadState | D (kernel_text/math), H | — | lib/std/contract/lead.zig | `LeadState` | 282 | mock tests → tests/unit |
| lib/contract/validate.zig | 314 | `validate(D)` spine + allowlist | D (codegen file.zig:264), C | — | lib/std/contract/validate.zig | — | 840 | merge 4 validate files; mock tests out |
| lib/contract/validate_entries.zig | 266 | entry-point rules | D | — | lib/std/contract/validate.zig | — | 0 | merge |
| lib/contract/validate_shape.zig | 192 | signature/array shape checks | D | — | lib/std/contract/validate.zig | — | 0 | merge |
| lib/contract/validate_tables.zig | 175 | optional-table rules | D | — | lib/std/contract/validate.zig | — | 0 | merge |
| lib/contract/mock_devices.zig | 545 | MockR/MockAll/... test devices | T (only test blocks) | osdi_dyn/fixture.zig | tests/unit/contract_mocks.zig | — | 0 | move to tests (finding 6) |
| lib/contract/gm.zig | 584 | deterministic exp/log/pow + GPU libm | C (fold, prove), D, H | compiler_rt exp/log | lib/std/contract/gm.zig | — | 584 | keep (finding 5) |
| lib/contract/gm/arm_exp.zig | 273 | ARM exp, fma-free | C, D | compiler_rt/exp.zig (older musl) | lib/std/contract/gm/arm_exp.zig | — | 273 | keep |
| lib/contract/gm/arm_log.zig | 258 | ARM log, fma-free | C, D | compiler_rt/log.zig (same algorithm) | lib/std/contract/gm/arm_log.zig | — | 258 | keep (vector form) |
| lib/contract/gm/arm_pow.zig | 351 | ARM pow | C, D | std/math/pow.zig (less accurate) | lib/std/contract/gm/arm_pow.zig | — | 351 | keep |
| lib/contract/gm/bits.zig | 124 | scalar-or-vector IEEE field helpers | C, D | — | lib/std/contract/gm/bits.zig | — | 124 | keep |
| lib/contract/gm/musl.zig | 316 | expm1/log1p/sin/cos for NVPTX/AMDGCN | D (GPU) | std.math expm1/log1p, compiler_rt sin/cos | lib/std/contract/gm/musl.zig | — | 316 | keep (GPU only) |

#### lib/osdi_dyn.zig + lib/osdi_dyn/ → lib/std/osdi.zig + osdi/ (a `--dyn` host; like lib/c.zig: an exported C ABI)

| current path | LOC | role | used by | duplicates | target path | absorbing struct | LOC after | action |
|---|---|---|---|---|---|---|---|---|
| lib/osdi_dyn.zig | 156 | OSDI 0.4 exports root | X (`--emit-osdi`, src/main.zig:207) | — | lib/std/osdi.zig | — | 156 | move |
| lib/osdi_dyn/abi.zig | 303 | osdi_0_4.h as extern structs | X | — | lib/std/osdi/abi.zig | `OsdiDescriptor` | 303 | keep |
| lib/osdi_dyn/tables.zig | 296 | comptime params/Jacobian/collapse rows | X | contract/masks.zig, rows.zig readers | lib/std/osdi/tables.zig | — | 420 | merge tables+blobs |
| lib/osdi_dyn/blobs.zig | 133 | model/instance blob layout | X | — | lib/std/osdi/tables.zig | — | 0 | merge |
| lib/osdi_dyn/descriptor.zig | 687 | builds `OsdiDescriptor` (332 test lines) | X | — | lib/std/osdi/descriptor.zig | — | 355 | fixture tests → tests/ |
| lib/osdi_dyn/eval.zig | 369 | eval callback, limiting | X | — | lib/std/osdi/eval.zig | — | 440 | merge eval+load; fixture tests out |
| lib/osdi_dyn/load.zig | 180 | load_* stamps, noise | X | — | lib/std/osdi/eval.zig | — | 0 | merge |
| lib/osdi_dyn/params.zig | 243 | param slots ↔ Model | X | — | lib/std/osdi/params.zig | — | 380 | merge params+setup |
| lib/osdi_dyn/setup.zig | 144 | setup_model/instance | X | — | lib/std/osdi/params.zig | — | 0 | merge |
| lib/osdi_dyn/fixture.zig | 299 | test devices + ngspice stand-ins | T | contract/mock_devices.zig | tests/osdi_fixture.zig | — | 0 | move to tests |


### A.8 src/vpi


| current path | LOC | role (<=12 words) | key pub types | duplicates (path) | target path | absorbing struct | LOC after | action |
|---|---|---|---|---|---|---|---|---|
| src/vpi/root.zig | 104 | re-exports; comptime list of files with `export fn` | — | — | lib/vpi/root.zig | — | 30 | rewrite: keep only the export list |
| src/vpi/vpi_user.h | 1145 | installed C header, Annex G + VAMS numbers, prototypes | C types | vpi_user.zig, abi.zig (hand copies) | lib/vpi/include/vpi_user.h | the single source of truth | 1145 | move as-is |
| src/vpi/vpi_user.zig | 1083 | hand copy of 491 header macros; 351 doc lines; 204 test lines | `vpi*` consts | vpi_user.h | — (`b.addTranslateC` module `vpi_c`) | `@import("vpi_c")` | 0 | delete; tests to tests/unit/vpi.zig |
| src/vpi/abi.zig | 194 | hand copy of header structs as `extern struct` | Value, Time, CbData, Delay, SystfData… | vpi_user.h | — (`vpi_c`) | `vpi_c.s_vpi_value` … | 0 | delete |
| src/vpi/varargs.c | 91 | variadic shims; `va_arg` accessors | — | — | lib/vpi/varargs.c | — | 75 | rewrite: `vsnprintf` with `%n` refused |
| src/vpi/va.zig | 49 | opaque va_list + accessor externs | List | — | lib/vpi/print.zig | print | 0 | merge (only `vpi_control` reads args) |
| src/vpi/cformat.zig | 474 | C11 printf reimplemented over va_list | cformat | lib/contract/c_format.zig, lib/kernels/str_real.zig, src/analog/format.zig, vpi/analog_value.zig | — (libc `vsnprintf`, linked already) | — | 0 | delete |
| src/vpi/print.zig | 513 | MCD channels, vpi_printf family, shared HDL fds | setLogFile, vpi_mcd_* | lib/kernels/file_table.zig (ZfTable mcd rows) | lib/vpi/print.zig | print | 380 | shrink (tests out; channels could sit in ZfTable) |
| src/vpi/session.zig | 208 | global design, open/close, startup routines, vlog_info | design, Error | — | lib/vpi/Table.zig | Table (load) + root | 100 | merge |
| src/vpi/Design.zig | 157 | installed model: rows + iters + name map + userdata | Design | Zcu-like design copy | lib/vpi/Table.zig | Table | 120 | merge |
| src/vpi/schema.zig | 552 | 200-byte AoS `Obj`, Cold, Scope, Iter; typeOf/typeName | Obj, Cold, Scope, ObjId, Slot, Kind | — | lib/vpi/Table.zig | Table.Row SoA | 300 | rewrite as SoA |
| src/vpi/trust.zig | 156 | pointer membership checks, compare/free | asObj, asIter, issued | 7 per-registry `live` maps | lib/vpi/Handles.zig | Handles | 250 | rewrite: one handle table |
| src/vpi/handle.zig | 420 | vpi_handle, by_name, by_index, multi_index | export fns | — | lib/vpi/traverse.zig | Table reads | 280 | shrink: edges are CSR reads |
| src/vpi/iterate.zig | 272 | vpi_iterate/scan, heap iterators | export fns | — | lib/vpi/traverse.zig | Handles(.iter) | 170 | merge |
| src/vpi/reverse_index.zig | 361 | lazy drivers/loads/uses/lowConn reverse maps | Relations | model.Csr | src/codegen/vpi.zig | VpiTable.lists (CSR emitted) | 100 | move to emit time |
| src/vpi/property.zig | 500 | vpi_get/get_real/get_str per class | export fns | — | lib/vpi/property.zig | Table columns | 400 | shrink; strings are table offsets |
| src/vpi/value.zig | 634 | vpi_get_value from engine planes / consts / call args | Bits, Store | — | lib/vpi/value.zig | value | 450 | shrink (tests out) |
| src/vpi/value_text.zig | 391 | Table 12-4 radix text, toReal, plane helpers | radixString… | lib/kernels/fmt.zig `valueFill` (§17.1.1.4 same x/X rule), kernels Integer | lib/vpi/value.zig | kernels.fmt | 60 | delete text, keep plane helpers |
| src/vpi/value_put.zig | 620 | vpi_put_value: formats to planes, schedule, force, events | Event, toPlanes | lib/kernels/integer_parse.zig (radix strings) | lib/vpi/value_put.zig | Handles(.event) | 420 | shrink |
| src/vpi/delays.zig | 612 | get/put delays, inter-module paths | InterModPath | — | lib/vpi/delays.zig | Handles(.path) | 500 | shrink (delays come folded from Sema) |
| src/vpi/callback.zig | 848 | cb registry, remove, get_cb_info | Cb | — | lib/vpi/callback.zig | Handles(.cb) | 480 | shrink (212 test lines out) |
| src/vpi/callback_sites.zig | 125 | cbStmt sites, engine stmt hook | sites | — | lib/vpi/callback.zig | callback | 100 | merge |
| src/vpi/callback_fire.zig | 566 | dispatch occurrences to live callbacks | fireAll… | — | lib/vpi/callback_fire.zig | — | 450 | keep, shrink |
| src/vpi/systf.zig | 822 | systf registry, compiletf/sizetf, digital hook, user data | Systf, hook | contract.SystfHost (analog side) | lib/vpi/systf.zig | Handles(.systf) | 600 | shrink (196 test lines out) |
| src/vpi/run.zig | 1046 | digital time walk, vpi_get_time, sim_control, queues | Queue, Harness | sim/digital run_until (drives it) | lib/vpi/run.zig | Handles(.queue) | 700 | shrink; Harness to tests |
| src/vpi/status.zig | 247 | §12.2 error status, `enter`/`refused` | Unanswered | — | lib/vpi/status.zig | — | 200 | keep |
| src/vpi/analog.zig | 527 | analog point globals, `Lib` fn-pointer ABI, Analysis | Lib, Analysis, Kind | src/codegen/exe/text/vpi_tail.zig.txt (other side of the same ABI, by hand) | lib/vpi/analog.zig | contract.VpiLib (extern struct) | 330 | rewrite: ABI type lives in lib/contract |
| src/vpi/analog_call.zig | 323 | running analog call: args, outputs, derivatives | Active, Out, Deriv | — | lib/vpi/analog.zig | analog | 250 | merge |
| src/vpi/analog_value.zig | 431 | vpi_get_analog_value + its own C %e/%g | Value | lib/kernels/str_real.zig, contract/c_format.zig | lib/vpi/analog.zig | analog | 240 | merge; real text through kernels.str_real |
| src/vpi/Binding.zig | 373 | one attached device library + its call map | Binding | — | lib/vpi/Binding.zig | Binding | 320 | keep |
| src/vpi/analog_walk.zig | 369 | op/tran/ac walk with callbacks and backups | Mixed | sim.mixed.run contract | lib/vpi/Binding.zig | Binding | 330 | merge |
| src/vpi/model.zig | 467 | Rows builder, freeze, Csr, path join helpers | Rows, Building, Csr | — | src/codegen/vpi.zig | VpiTable.Builder | 150 | rewrite |
| src/vpi/model_analog.zig | 422 | vera.Result (AST+elab+Lowered) to Design | build, splitPath | Sema/Zcu hierarchy; model_digital | src/codegen/vpi.zig | one emitter over Sema output | 200 | merge with model_digital |
| src/vpi/model_digital.zig | 524 | sim.digital.Run (lib/sim's elaborator) to Design | buildDigital | Sema/Zcu hierarchy; model_analog | src/codegen/vpi.zig | one emitter | 250 | merge with model_analog |
| src/vpi/model_arrays.zig | 317 | array, range, bit, instance-array rows | addArray… | — | src/codegen/vpi.zig | emitter | 150 | merge |
| src/vpi/model_branches.zig | 381 | disciplines, natures, nodes, branches, quantities | addAnalog | Lowered nodes/contributions | src/codegen/vpi.zig | emitter | 180 | merge |
| src/vpi/attribute.zig | 265 | attribute rows; own constfold hook | ByOwner, AnalogEnv | frontend/constfold, analog/constfold | src/codegen/vpi.zig | emitter (Sema folded) | 100 | shrink |
| src/vpi/udp.zig | 112 | UDP definition rows | udpDefns | — | src/codegen/vpi.zig | emitter | 70 | merge |
| src/vpi/Builder.zig | 436 | scope-building state, §6.7 name lookup | Builder, Analog | Sema scope resolution | src/codegen/vpi/code.zig | emitter | 200 | shrink (names resolved by Sema) |
| src/vpi/code_module.zig | 542 | module items to code rows; literal-only delay fold | module, primitive… | — | src/codegen/vpi/code.zig | emitter | 300 | merge |
| src/vpi/code_stmt.zig | 274 | statements to code rows | stmt, contrib | — | src/codegen/vpi/code.zig | emitter | 150 | merge |
| src/vpi/code_expr.zig | 254 | expressions to code/constant rows | expr, select | — | src/codegen/vpi/code.zig | emitter | 130 | merge |
| src/vpi/code_tables.zig | 508 | Ast enum to Annex G maps; typeName; packedWidth | ScopeLists | packedWidth also in model_analog.zig:399 | src/codegen/vpi/code.zig | `std.EnumArray` tables | 150 | shrink |
| src/vpi/decompile.zig | 407 | Ast expression to vpiDecompile text (precedence-minimal) | decompile | no other Ast printer exists | lib/std/vams/render.zig | `render.expr` | 320 | move; called at emit time |
| src/vpi/host.zig | 548 | `main` of libvera-vpi.a: compile, build lib, run | — (`External`) | Compilation (analyzes the source 2-3x) | src/vpi/host.zig | Compilation client | 420 | rewrite: one Compilation per design |

The `cformat` and `analog_value` C formatting can drop to libc only because the artifact already links libc (build/vpi.zig:50). On Windows, zig's mingw uses UCRT, which is C99-conformant for `%e`, so that path is safe.

---

## Original brief (kept verbatim)

We have a compilation.zig that orchestrates the compilation process, and a directory called frontend/ that contains:

Note: The compilation.zig handles the streaming of data into the tokenizer buffer and the SPLITTING of reading to _modules_ this is a compiler chosen prospect, to promote incremental compilation. Also, it will have helpers for it (the current base), Arenas, InterPool, etc... (using structures that are data-oriented mutliArrayList, StaticStringMap, StaticBitSets, etc...)

Frontend:

1. Tokenizer (Unified for Verilog-AMS (should be able to take in Verilog, Verilog-A, and Verilog-AMS)),

```Zig
//! I forgot the syntax but something like this
pub const Tags = StaticStringMap(u8).init({
    "" => .Unknown,
})

pub const Tokenizer = struct {
    buffer: [:0] const u8,
    index: usize,
    tok: Token,

    pub fn next(self: *Tokenizer) !Token {
    }
}

pub const Token = struct {
    tag: TokenTag,
    Loc: (u8, u8),

    //! All keywords of the language
    pub const TokenTag = comptime iteration over the Tags from Tags
}
```

Run in parallel using the interpool on each *module* not the verilog modules, rather a code unit.

2. Parser,

```Zig

```

3. Lowering,

To first begin planning this, we need to understand WHY ARE WE LOWERING? WHAT ARE WE LOWERING TO.

Is our goal an agnostic language backend that we dump to? No its dumping to Zig directly, so this determines the number of lowering stages.

Zig has AstGen, Sema, and Codegen. 
- AstGen helps do comptime behavior
- Sema is for giving types
- Codegen is lowering to the different systems depending on the target architecture.

For us:
- Do we have comptime behavior or macros-like in C? If so, we need AstGen
- Do we have a strongly-typed system, or are they inferred? If we don't, we need Sema.
- Codegen is needed, but should be lightweight.

4. Linking

To speed up compilation of devices, we can compile them as different units under LLVM and link them together, this isn't implemented currently at all and would be perfect to implement.

5. The STD library aka for us the contract and constants.vam and displicine.vam


Result should be a structure like:
```
lib/
    Compilation.zig
    main.zig
    std/ # Files that will be referenced by Verilog IEEE1364-2005, Verilog-A, Verilog-AMS
        contract/ # For The Devices that are produced and inherently reference this contract.
        kernels/ # The kernels that are used within the code dumped.
        base/ # The helpers InternPool, Arena, etc...
        sim/ # The harness that will wrap over the codegen output to simulate it.
        constants.vam
        discipline.vam
        ...
    diagnostics/ # Consumed by the parser, AstGen, Sema, that will create FOR EACH ONE an identifer that will emit the diagnostic
        ...
    frontend/
        tokenizer.zig # should only be 1 file if we do it in that structure
        parser/ # Should be the parser
            types.zig
            root.zig
            ...
        AstGen/
            types.zig
            root.zig
            ...
        Sema/ # When we lower the types, this is where we prove the type and whether we can use LLVM optimized or strict for floats
            prove/
            types.zig
            root.zig
            ...
        Codegen/
            OSDI/
            Device/
            Digital/ # We need to research how can we dump a Verilog device that would work with Yosys AND work with analog spice simulators fast.
            ...
        Simulation/ # This is a stage that consumes the CodeGenned output wrapping it in a simulation harness that will use the library defined in lib/std/sim/
            ...
        Linking/
            ...
src/
    main.zig
        
```

- **Zero `.xfail` (user, 2026-11-03):** "I want 100% green, no xfails." Every
  `tests/differential/*.xfail` is empty before the switch-over, and an agent is
  done only with its file empty. A difference ends as built code, as a stage
  that owns the check (a stage-ownership table for diagnostic codes), or as an
  old-side bug that an independent tiebreaker settles (an f128 reference, or an
  `//! lrm` fixture). Never as a line. `docs/rewrite/README.md` rule 3.

- **`--check` scratch per invocation (ESPice espice-8a, 2026-11-03; v0.30.0 only, no v0.23.1):**
  the old `src/zigbuild/check.zig` writes `.zig-cache/vera-check/<model>.check.zig`
  at a fixed path, so two builds that share a `.zig-cache` symlink read each
  other's half-written file ("contract requires `pub U`"). `link.check` takes
  `f.work_dir` from its caller. The rewrite's driver (rw-comp) gives each
  invocation its own directory: under the `-o` output's directory, or a
  mkdtemp-style name with a random suffix, removed afterwards. It never uses a
  fixed path under the cwd, and a cache-relative path is not enough, because
  the caches are shared on purpose. Oracle: one model, one cwd, N concurrent
  `vera --emit-zig --check` runs in a test, all of which succeed. Tell
  espice-8a the tag when v0.30.0 ships.

- **The goal (user, 2026-11-03, overnight):** "the complete rewrite, passing at 0 xfails, all green."
  This means:
  - every `tests/differential/*.xfail` is empty;
  - `vera-next` passes conformance 6818/6818;
  - `zig build test` is green with the new pipeline as the product;
  - the old pipeline is deleted.

  "Then a final audit using AGENTS.md over the codegen code part to make sure it
  codegens performance critical code." The audit covers:
  - the assembly probes (FOLDED/IDENTICAL/EQUIVALENT/NEGATIVE; RESIDUE fails);
  - dispatch per batch;
  - SoA with size assertions;
  - versioned units that actually take the fast body;
  - a benchmark behind every speed claim.

  Order: rw-zero, rw-dlower, rw-codegen, rw-lower and rw-comp (`docs/rewrite/comp.md`)
  run now, at most 5 agents at once. The backends follow as slots free: exe,
  verilog, osdi, digital native, rtlil, VPI. Then the switch-over, then the audit.

- **Morning items for the user (overnight 2026-11-03):**
  - **diff-kernels criterion:** on every input, Gompute must be within its documented
    bound, and its worst case must be no larger than gm's. gm is closer on 79 cosh
    inputs, so a per-input rule would require a correctly rounded Gompute.
  - **Conformance fixture `verilog/12_hierarchy/listed_port_undeclared_rejected.v`:**
    it expects E1100, but the new pipeline raises E0376 (ruled by IEEE 1364 §12.3.3).
    The fixture lives in the suite repository, so changing it is the user's call.
  - **Air.interp:** exp, log10 and tan are now correctly rounded. diff-air found the
    old fold farther from f128 on 24,804 tan inputs (max 1.98 ulp).
  - **Follow-up (rw-zero):**
    - Sema's fold moves to std_kernels, so a folded constant equals the device's
      runtime value.
    - Interval's library margin is derived from the device kernel's measured error,
      not a flat 2 ulps.
    - The float falsifier evaluates with std_kernels rather than interp.
- **Backends (2026-11-04):** `comp.xfail` lists 1752 fixtures under "not built: backend exe",
  114 under vpi and 100 under digital_device. rw-zero takes exe
  (`docs/rewrite/exe.md`, new `src/codegen/bench/`, renamed to `exe` at the switch-over).
  VPI and digital_device follow as slots free.
- **Morning item: E1100 on the 1364 route.** The conformance suite's `.v` reject
  fixtures expect `//! reject E1100`, the old digital engine's catch-all code,
  where the new front end has specific codes: E0906 "connected twice", E0904,
  E0907, E0908, E0239, E0376, and others. vera-next reports them as E1100 with
  the old wording through one table in the driver, so conformance-next passes
  the suite unedited. Switching the 1364 route to the specific codes means
  editing the suite (the user's repository) and deleting that table. That is
  the user's call.
- **Morning item: versioned units bought nothing until now.** rw-codegen found that
  `@setFloatMode(.optimized)` in a device's fast body reaches only the operators
  written directly in it. Every float op goes through a kernel-family method, whose
  body stays strict, so the fast body was bit-identical to the strict one.
  Fix underway: the float mode becomes a comptime parameter of the family.
  - The strict instantiation keeps the "no optional contraction" rule.
  - A probe proves the optimized instantiation carries the fast flags.
  - In-box ulp bounds are measured per root.
  - A ReleaseFast benchmark decides whether versioning stays. If the gain is not
    measurable, deleting versioned units (simpler code) is the user's call,
    with the numbers.
- **abs.va zero Jacobian (wrong number, no crash):** the device agrees with the
  old device at 763 in-box points, so the fault is in the new bench host's lane
  handling (`lib/std/sim/bench`). rw-zero is tracing it red-first.
