# Plan: front end and elaboration leftovers (owner `rw-comp`)

Planner: plan-frontend. Base: `refactor` 1a74ff4d (90e93007 + an AGENTS.md commit). Read-only research: no build run; the
"SAME" verdicts below come from running the binaries already built in the rw-comp3 worktree (11:53) with the
harness argv (`tests/differential/comp/fixture.zig` `argv`), so they cover the worktree's state at that time only.
Spec: docs/rewrite/comp.md, parse.md, astgen.md, elab.md, diag.md. Old side (oracle, read-only): `lib/frontend/`,
`src/elab/`, `lib/sim/digital/`. New side: `lib/std/vams/{Parse,Ast,AstGen,Vir,Diag}*`, `src/Sema*`, `src/Zcu.zig`,
`src/InternPool.zig`, `src/next/Compilation*`.
Zig mirrors: `Z/` = `/nix/store/spqy6l91i77g18ndfbaq441khlr8zd5f-zig-0.18.0-dev.349+d924f83bf/lib/std/zig/`,
`S/` = `~/.cache/zig-src-d924f83bf/src/` (checked: `git log -1` = d924f83bf3; every `S/` line cited was re-read there).
`H` = `~/.cache/vera-heavy.sh <wt>` (= `tools/build-slot.sh`, which runs `nix develop -c zig build`).

## 0. Starting state

| worktree | branch | state |
|---|---|---|
| `agent-a90bdf8430320620a` (rw-comp3) | `worktree-agent-a90bdf8430320620a`, base 2af9db2f | the starting point: 2 own commits, 10 foreign commits (merges), uncommitted work |
| `agent-af193f43066b56fe9` | same two own commits, nothing uncommitted | duplicate; delete after T1 |

Own commits (land in T1): **b87dbead** (Sema: E0922/E0927 at the port connection via `Part.conn`; E0247 at the
scaled literal via a new `Zcu.Part.scaled` and `locate.zig` `scaled()`; W0950 once, at the second matching
resolveto). **8261c3bd** (`Sema/checks.zig` `paramsetReach`: VAMS §6.4.1 a paramset statement `m.p` naming a non-local
parameter is E0907 at `m`).
Foreign commits (do **not** land in T1): e6788383, 4b533f5e, 09fa46a0, 6424a413, d6034c37 (merges of refactor and of
rw-lower's `worktree-agent-ad5e468e82bad6022`), 0474ded2, e8fa3a12, ae2c8821, f64248a1, 9fa85ebf (rw-lower's; ae2c8821
is not in refactor yet).

Uncommitted work (files edited 11:29-12:03; the binary is from 11:53, so the 12:0x edits are unverified):

| file | change | clears (group) | state |
|---|---|---|---|
| `lib/std/vams/Ast.zig`, `Ast/errors.zig` | `ParseOptions.verilog_a`; tag `outside_verilog_a` → E0250 "`{s}` under --sim=verilogA"; E0131/E0133 underline the number token only | G1, G2 | SAME |
| `lib/std/vams/Parse.zig` (+`Parse/expr.zig`, `stmt.zig`, `module.zig`) | `refuseDigital(p, i)`: E0250 on `connectmodule`, `initial`, `always`, `assign`, `reg`, `function`, gates, `config`, `library`, `task`, `specify`, ... under `verilog_a`; `===`/`!==`, `casex`/`casez` refused; `analogGrammar` `!p.discrete and ...` | G1, G11 | SAME (Parse.zig re-edited 12:03: re-verify) |
| `lib/std/vams/Parse/stmt.zig:258` | IEEE 1364: a declaration in an unnamed block `failAt`s, abandoning the item (recovery reads the rest as module items) | G6 | unverified |
| `lib/std/vams/Parse/function.zig` | an item error abandons the whole function declaration | G7 cascade shape | unverified |
| `lib/std/vams/Diag/Wip.zig`, `src/next/Compilation/errors.zig` | `Builder.dedupe` (off for copied bundles, so a macro argument expanded twice reports twice as the old did); `relocate` end = start + width | G2, G3 (duplicates) | unverified |
| `src/Sema.zig`, `src/Sema/subset.zig` (untracked) | `Config.verilog_a`; `subset.run`: E0250 "`domain discrete` under --sim=verilogA" at a port/net/reg of a discrete discipline | G1 | SAME |
| `src/next/Compilation/frontend.zig` | E0250 per `` `default_discipline `` under verilogA (in `preprocess`); `semaTop` returns on `comp.wip.failed()`; passes `verilog_a` to `Ast.parse` and `Sema.elaborate`; **`declFiles` + `annex_d_included`** | G1 | SAME; the last two need ae2c8821 (rw-lower): drop them |
| `src/next/Compilation/test.zig` | an E0342 duplicate-nature test | – (rw-lower's) | drop |

## 1. Root causes

comp.xfail rw-comp lines: 42. "SAME" = old and worktree vera-next print the same bytes and exit.

| G | root cause | comp | exe | dev | rtlil | sim | examples | fix |
|---|---|---|---|---|---|---|---|---|
| G1 | VAMS Annex C.4 (Verilog-A subset): a digital construct, `domain discrete`, or `` `default_discipline `` under `--sim=verilogA` not refused (E0250) | 10 | – | – | – | – | library_declaration_in_design_rejected.va, discrete_disciplines.va | T1 (wt, SAME) |
| G2 | parse/preprocess carets: the underline spans more than the old token (`'`-number tails, a directive's arguments) | 9 | 2 | 2 | 2 | – | binary_digit_f_rejected.va, default_nettype_inside_module_rejected.v | T1 (wt, SAME) |
| G3 | §2.7 Table 2-2 escapes: only the first `\ooo` above `\377` per string is E0148, and an undefined escape is no W0149 (old: each one, at the escape's bytes) | 2 | – | – | – | – | octal_escape_above_377_rejected.va, undefined_escape_keeps_character.va | T5 |
| G4 | two parser warnings missing: W0259 (a function named `expm1`/`ln1p` where the active §10.6 set reserves it; VAMS Annex G.7) and W0253 (a `config` read in an analog compile; IEEE 1364-2005 §13.3) | 2 | – | – | – | – | own_expm1_function_warns.va, configuration_source_text.va | T5 |
| G5 | VAMS §4.4 / A.8.2 `branch_probe_function_call` takes one branch or one or two nets: `V(p, n, q)` is E0207 "found `,`, expected `)`"; new says E0512 | 1 | – | – | – | – | access_three_nets_rejected.va (`//! reject-only E0207`) | T7 |
| G6 | IEEE 1364-2005 §9.8.1 a declaration in an unnamed `begin`/`fork` (and A.2.8 in a task): the old parse abandons the item and reads the rest as module items (E0240 cascade) | 4 | 4 | 4 | 4 | – | unnamed_block_declaration_rejected.v, b_A_2_8_net_block_item_rejected.v | T1 (wt, unverified) |
| G7 | **ruling**: after a fatal parse error the old side reports E0206 on recovered text (`input x` of a refused function header; `output q` of a UDP inside a module). Parse errors stop AstGen (Zig `Z/AstGen.zig:187-189`) | 3 | 1 | 1 | 1 | – | keyword_function_name_rejected.va, definition_inside_module_rejected.v | T8 |
| G8 | elaboration locations (port connection, scaled literal, resolveto) | 7 | – | – | – | 1 | unknown_discipline_mixed_port.va, reject_ambiguous_connect_statements.va | T1 (b87dbead, SAME); resolveto_two_subset_rules_warn.va keeps a transcript diff: re-tag rw-codegen |
| G9 | VAMS §6.4.1 paramset `m.p` naming a non-local parameter | 1 | – | – | – | – | paramset_oomr_nonlocal_parameter_rejected.va | T1 (8261c3bd, SAME) |
| G10 | IEEE 1364-2005 §12.8.1 an upward defparam whose value reads a parameter cycle: old names the cycle and reports every defparam reading it; new reports only the self-read one in other words | 1 | – | – | – | – | defparam_upward_value_cycle_rejected.va (`//! reject-only the cycle ...`) | T3 |
| G11 | IEEE 1364 null statement under `discrete` parse (E0219 refused a 1364 `;`) | 1 | – | – | – | – | std_1364_ams_keywords_reserved_by_default.v | T1 (wt, SAME) |
| G12 | **misrouted**: a run-time model-card check (`$mfactor` k=0, VAMS §9.18): Sema lowers it (lower.xfail:396 `resist` 2.0587 vs 1) and codegen emits `checkCard` | 1 | – | – | – | – | geometry_card_mfactor_outside_domain_is_fatal.va | re-tag rw-lower (e8fa3a12 "$mfactor scaling" is on its branch) |
| G13 | **ruling copy**: macro_text_1800_forms_warn.v (comp.rulings already rules it, §19.3.1) | – | 1 | – | – | – | macro_text_1800_forms_warn.v | T8 |
| G14 | `--emit-rtlil` refuses a design outside its subset before elaborating it (old E12xx); new elaborates first and reports Sema's E1100/E0901/E0907 | – | – | – | 3 | – | defparam_early_resolution_rejected.v (old E1202), defparam_names_nothing_rejected.v (E1205), defparam_relative_out_of_array_element_rejected.v (E1251) | T4 |

Routed here (tagged rw-dlower / rw-lower in the lists):

| G | root cause | comp | exe | dev | rtlil | sim | examples | fix |
|---|---|---|---|---|---|---|---|---|
| G15 | **wrong text, no crash**: `InternPool.getString(bytes)` with `bytes` inside `string_bytes` reads them after `ensureUnusedCapacity` reallocated (`src/InternPool.zig:353-368`): the E1100 "inside `u[0]`" prints `����`. `Sema.failRule` (`src/Sema.zig:424`) interns `why.name`, which `outsideElement` sliced from the pool | 1 | 1 | 1 | – | – | defparam_relative_out_of_array_element_rejected.v | T2 |
| G16 | IEEE 1364-2005 §12.2.1 "a defparam statement in a hierarchy in or under a generate block instance or an array of instances shall not change a parameter value outside that hierarchy": only the upward-relative form with a selected head is judged (`outsideElement`); the absolute form and a generate block's sibling are accepted | 2 | 2 | 2 | – | 2 | defparam_absolute_out_of_array_element_rejected.v, defparam_across_generate_instances_rejected.v | T2 |
| G17 | the 1364 route's elaboration errors keep Sema's span; lib/sim/digital located every failure at one byte (`lib/sim/digital/run_diag.zig:77` `.end = start`) | 1 | – | – | – | – | verilog-ams/digital/scaled_delay_udp_rejected.v (old `^` at 18:25, new `^^`; with dlower G1 for its W0252) | T4 |
| G18 | §3.8/§2.9 an `initial`/`always` construct's attribute instance is dropped: `Vir.Inst.Process` (`lib/std/vams/Vir/Inst.zig:429`) has no `attrs` | (1) | (1) | (1) | – | (1) | attribute_value_is_constant_rejected.v | T6 here (Vir), then plan-dlower T5 (the Sema check) |
| – | **owned elsewhere**: §13.3.1.1 config design cell missing (design_cell_missing, design_names_config, cell_not_in_its_library; both sites `src/Sema.zig:438` `configRoots` and `src/Sema/library.zig:80` `roots`) | – | – | – | – | – | – | lead's decision: plan-dlower T4 (`research/dlower.md` G7); plan-libmap depends on it for cell_not_in_its_library_rejected.v. Not planned here |
| – | W0252 on the 1364 route | – | – | – | – | – | – | plan-dlower G1 (its worktree) |

Bookkeeping, comp.xfail rw-comp 42 = G1 10 + G2 9 + G3 2 + G4 2 + G5 1 + G6 4 + G7 3 + G8 7 + G9 1 + G10 1 + G11 1 + G12 1.
digital_exe rw-comp 8 = G2 2 + G6 4 + G7 1 + G13 1. digital_device rw-comp 7 = G2 2 + G6 4 + G7 1.
rtlil rw-comp 10 = G2 2 + G6 4 + G7 1 + G14 3.

The 21 comp "not built: backend libmap" lines are plan-libmap's (`research/libmap.md`).

## 2. Fixes, each with its Zig mirror

### T1 land rw-comp3 (G1, G2, G6, G8, G9, G11)
- Cherry-pick b87dbead, 8261c3bd onto `refactor`; apply the uncommitted diff minus the `declFiles` function, the two
  `decl_files`/`annex_d_included` lines in `semaTop`, and the E0342 test in `Compilation/test.zig` (they need
  rw-lower's ae2c8821). Copy the untracked `src/Sema/subset.zig`.
- Zig mirrors: `Z/Parse.zig:134` `warn` (a non-fatal error row), `Z/Parse.zig:515` `findNextContainerMember` (G6:
  recover at the next container member), `S/Zcu.zig:2343` `LazySrcLoc` (G8: `locate.zig` resolves a `Part` at render
  time), `S/Sema.zig:2671` `fail`.
- If G6 is still a diff after the build: the error from `stmt.zig:258` must propagate out of the `initial` item to
  `Parse/module.zig:84` `parseItems`, whose `recoverItem` (`Parse.zig:309`) skips past the next `;`, which is the old
  recovery (old: `found r`, then `found end`). Find the catch between them (`grep -n 'error.ParseError' lib/std/vams/Parse/*.zig`)
  and let the 1364 case through. Do not add a new recovery mode.

### T2 interned-slice aliasing and the §12.2.1 containment rule (G15, G16)
Old: `lib/sim/digital/elab_defparams.zig:85-122` `checkDefparams` (after the hierarchy is complete, for each scope
from the defparam's to the root: if the scope is an array element or a generate block and the target is not
within it, E1100 "§12.2.1: a defparam inside `{name}[{k}]` cannot change ...", innermost scope first).

1. `src/InternPool.zig:353` `getString`: assert the input is not interned bytes. Two asserts, split:
   `assert(!aliases(ip, bytes));` after the length assert, and the existing exit `assert(eql(...))`. Private
   `fn aliases(ip, bytes) bool` compares `@intFromPtr` ranges against `ip.string_bytes.allocatedSlice()`. Doc line:
   "Asserts that `bytes` is not a `stringToSlice` result (copy it first)". Zig mirror: `S/InternPool.zig:11406`
   `getOrPutString` appends `slice` into `string_bytes` with the same hazard and documents none; VerA asserts it.
2. Delete `outsideElement` (`src/Sema/defparam.zig:360-372`) and its call (`:191-197`). Replace with one rule over
   every defparam form, in `collect` after the anchor/`rel` resolution (after `:205`, before the self-read check):
   - `walk.zig:487`: pass `prefix` (the generate-block prefix `items` already has) to `collect`:
     `pub fn collect(w: *Walk, env: *Env, index: Instance.Index, file: Zcu.File.Index, i: Inst.Index, prefix: []const u8) Allocator.Error!void`.
   - new private `fn outsideScope(w: *Walk, index: Instance.Index, prefix: []const u8, anchor: Instance.Index, rel: []const u8) Allocator.Error!?[]const u8`:
     target path `T = fmtPath(anchor) ++ ("." ++ rel if rel != "")`. The containing scopes, innermost first: each
     segment of `prefix` (every one a generate block, innermost = last), then for `it = index` up the
     `instances.parent` chain: the instance's own last name segment if it ends in `]` (an array element), then the
     other segments of its name (`Zcu.instances.name` carries its generate prefix, `walk.zig:525/538`), innermost
     first. Scope path `S` = the parent's `fmtPath` ++ the segments up to it. Returns `arena.dupe(last segment of S)`
     for the first `S` with `T != S` and not `startsWith(T, S ++ ".")`; null otherwise. Loop bound: the path depth,
     asserted `< Zcu.instances_max`.
   - On a hit (only `s.config.ieee1364`, as today): `origins[origin].used = true;` and
     `failRule(.{ .rule = .defparam_outside, .name = element, .part = .target }, .E1100, file, i.toRef(), "a defparam inside `{s}` cannot change a parameter outside the generate block instance or array element it is in (IEEE 1364-2005 12.2.1)", .{element})`.
   - ponytail: segments split on `.`; an escaped name holding `.` (§3.7.1) is one segment only where `walk.zig` already
     spells it `\name `. Ceiling named in the comment.
3. Zig mirror: none for generate scopes (a departure, §7); the check lives in `Sema` beside the other defparam
   placement rules, reading only `Zcu.instances` and the walk's own `prefix` (no sibling table).
- Data: no new table. `Origin` is unchanged (the prefix is a parameter, read once).

### T3 the §12.8.1 value cycle in old words (G10)
Old: `src/elab/defparam.zig:193-200` `seededValue` + `:329-364` `substitutionCycle`: a seeded defparam whose value,
with each undeclared parameter replaced by its final expression (another defparam's value, else its default),
reaches a cycle: E0907 "`{path}{local}` is applied before its declaring instance is elaborated, and its value reads
the cycle `a` → `b` → `a`, which no replacement ends (IEEE 1364-2005 12.8.1)", once per such defparam, in source order.
- `src/Sema/eval.zig` `Env`: two fields.
  - `pending: std.AutoHashMapUnmanaged(Inst.Index, Vir.Body) = .empty`: a parameter's own-instance defparam value,
    standing for its default while a cycle is looked for. Capacity: one per `param` instruction of the module.
  - `trail: std.ArrayList(Inst.Index) = .empty`: the parameters `param()` is folding, outermost first (the ordered
    twin of `busy`). Bound: `eval_depth_max`.
  - `param()` (`eval.zig:184`): push/pop `trail` beside `busy`; on the `busy` hit (`:189`) record
    `env.cycle = trail[from p ..] ++ p` (arena) if `env.cycle.len == 0`; read
    `env.pending.get(p) orelse decl.value` before `given`/`decl.value` only while `pending.count() != 0`.
  - `pub fn cycleOf(env: *Env, b: Vir.Body, pending: []const Pending) Allocator.Error!?[]const Inst.Index`, modelled
    on `dependsOn` (`eval.zig:157`): save `values`, `@memset(.none)`, fill `pending`, fold `b`, restore, return the
    recorded cycle. Asserts: `busy.count() == 0` on entry and on exit; `pending.count() == 0` on exit.
- `src/Sema/defparam.zig`:
  - `walk.zig:487`: before the collect loop, `try defparams.ownTargets(w, env, index, insts)` fills
    `w.own: std.ArrayList(eval.Pending)` (`Pending = struct { param: Inst.Index, value: Vir.Body }`), the defparams of
    this body whose target is a parameter of `index` itself: rendered text `rel == ""` and not upward, or `rel` one
    segment with `upwardAnchor(w, index, rel) == index`. Cleared with `w.prefixes` per instance (`walk.zig:309`).
  - `collect`: replace the self-read block (`:206-211`) with: `if (try env.cycleOf(a.rhs, w.own.items)) |cycle|`
    → `used = true`; `failRule(.{ .part = .target }, .E0907, ..., "`{s}` is applied before its declaring instance is elaborated, and its value reads the cycle {s}, which no replacement ends (IEEE 1364-2005 12.8.1)", .{ flat, names })`
    where `flat` = `fmtPathBelowRoot(anchor)` ++ `.` ++ `rel` ++ `.` ++ `param` (empty parts dropped: `u.g`, `w.x`) and
    `names` = each cycle parameter as `` `{below_root(index)}.{name}` `` joined by ` → ` (`` `w.y` → `w.x` → `w.y` ``).
    Then `return` (not placed), as the old `seededValue` returned null.
  - ponytail: `ownTargets` sees the defparams of the body being walked; one in a sibling generate block is not a
    replacement. Ceiling in the comment.
- Zig mirror: `S/Sema.zig` comptime dependency loops are reported where resolution meets its own in-progress decl
  (`Zcu` `dependency loop` errors); here `trail` is that in-progress stack.

### T4 Compilation: rtlil refusal before Sema, 1364 points (G14, G17)
- G14. Old `--emit-rtlil` refused from its own parse and never elaborated. Move the call at
  `src/next/Compilation/backend.zig:230` into `frontend.semaTop`, after the `addFile` loop and before
  `sema.Sema.elaborate` (`frontend.zig:199`): `if (c.target == .rtlil and try backend.rtlilRefused(comp, comp.pp.output())) return false;`
  and make `rtlilRefused` `pub`. It reads only `zcu.files`' Vir (`src/Sema/digital/sites.zig:124-130`), so it is
  valid there. Zig mirror: `S/Compilation.zig:4360` `performAllTheWork` orders the stages; only Compilation calls them.
- G17. `src/next/Compilation/errors.zig:70`: on the 1364 route set `loc.end = loc.start` for every `zcu.failed` row
  (`legacy.rule` already does it for rule rows). Cite `lib/sim/digital/run_diag.zig:77`. Zig mirror:
  `S/Compilation.zig:3829` `getAllErrorsAlloc` is the one place a failure becomes a located message.
- G17 needs plan-dlower's W0252 guard (`walk.zig:512`, its G1) for scaled_delay_udp_rejected.v to clear.

### T5 parser diagnostics: escapes, W0259, W0253 (G3, G4)
- G3. Old `lib/frontend/parser/source.zig:226-241` `checkEscapes` + `lib/frontend/token_value.zig:180`
  `badEscape(text, from) ?BadEscape`. New:
  - `lib/std/vams/number_literal.zig:158`: `pub fn badEscape(text: []const u8, from: u32) ?Escape` with
    `pub const Escape = struct { start: u32, end: u32, above_377: bool }` (byte offsets in the token), the old
    `token_value.badEscape` ported (undefined escape = a `\c` Table 2-2 does not list).
  - `lib/std/vams/Parse.zig:424` `checkStrings`: loop `while (badEscape(text, from)) |b| : (from = b.end)`, one row
    each: `Ast.Error{ .tag = if (b.above_377) .invalid_string_escape else .undefined_string_escape, .token = i, .arg = b.start | (b.end - b.start) << 24 }`
    (escape length <= 4: comptime-assert the packing). Bound: the token length.
  - `Ast.zig` `Error.Tag`: `undefined_string_escape` (W0149). `Ast/errors.zig:183`: both tags render at
    `tokenStart + start .. + len`, message `` `{s}` `` of those bytes; drop the scan loop.
- G4 W0259. Old `lib/frontend/parser.zig:464-475` `warnOwnMathFn`. New `lib/std/vams/Parse/function.zig:52`:
  `if (own) { if (keywords.reservedUnder(p.tokenText(p.tok_i), p.language)) try p.warnSite(.own_math_function, .generic, p.tok_i, @intFromEnum(p.language)); p.tok_i += 1; }`.
  Tag `own_math_function` → W0259, message `` `{s}` is a built-in under "{s}"; calls in this file reach the declared function `` with `KeywordSet.specifier()` of `arg`.
  Check that `p.language` is the set in force at the token (`` `begin_keywords ``); if it is the file's only, say so in the open questions.
- G4 W0253. Old `lib/frontend/parser/source.zig:377` (`if (!self.digital)` at the `config` keyword, after the config
  parses). New `lib/std/vams/Parse/design.zig:185` `parseConfig`: at its end, `if (!p.discrete) try p.warnAt(.config_binds_nothing, kw);`
  Tag → W0253, no message text (the catalogue title is the line).
- Zig mirror: `Z/Parse.zig:134` `warn`. Escapes are AstGen's in Zig (`Z/AstGen.zig:10833` `failWithStrLitError`):
  departure §7.1.

### T6 "Vir Process.attrs": AstGen keeps an `initial`/`always` item's `(* *)` attributes (G18; order before plan-dlower T5)
- `lib/std/vams/Vir/Inst.zig:429`: `pub const Process = extern struct { body: Body, attrs: List(Attr) = .empty };`
- `lib/std/vams/AstGen/stmt.zig:57` `process`: `.attrs = try decl.prefixAttrs(ag, scope, tree.nodeMainToken(node))`.
- Grep every `Inst.Process` reader (`grep -rn 'Inst.Process\|Process{' src lib`) and keep them compiling; no reader
  changes behaviour. The Sema judgement is plan-dlower T5 (`src/Sema/digital/decl.zig`).
- Zig mirror: Zir keeps a declaration's attribute bodies on it (`Z/Zir.zig:2719-2729` per plan-dlower).

### T7 access arity is E0207 (G5)
Old: the old parser knew the access names and refused the third net as a syntax error at the `,`
(`error[E0207]: unexpected token: found `,``, label "expected `)`", help "insert `)` after the previous item", a fix-it).
- `src/Zcu.zig:273` `Part`: add `sep: u32` (the `,` before argument `k`). `src/Sema/locate.zig:53` `part`: `.sep => |k|`
  the token before the first token of the call's argument `k` (`Ast.full` call view).
- `src/Zcu.zig:279` `Rule`: add `access_arity` ("VAMS §4.4: an access function takes one branch or one or two nets").
- `src/Sema/contrib.zig:258`: `if (args.len > 2) return failRule(.{ .rule = .access_arity, .part = .{ .sep = 2 } }, .E0207, unit.file, src, "`{s}` with {d} arguments", ...)`
  (keep E0512 for `args.len == 0`).
- `lib/std/vams/Ast/errors.zig:68`: `one` becomes `pub fn reportOne(tree, e, w)`.
- `src/next/Compilation/errors.zig` (zcu.failed loop, both routes): `if (rule == .access_arity)` render
  `Ast.parse_errors.reportOne(&u.tree, .{ .tag = .expected_token, .token = <sep token>, .extra = .{ .expected_tag = .r_paren } }, &tmp)`
  and copy it through `copyAs` (relocated), so E0207 has one renderer. Zig mirror: `S/Compilation.zig:3829`.
- Departure §7.3.

### T8 rulings (G7, G13)
Lines the task proposes (clause first, as `tests/differential/comp.rulings` does):
- `verilog-a/annex_b_keywords/keyword_function_name_rejected.va` "VAMS-2023 §2.8 / §4.7.1: `repeat` is refused as the function's name (E0208, as both sides say); the old side then reads `input x;` as a module item and reports E0206 for a function formal; parse errors are fatal (AstGen does not run on a tree with errors), so the new side reports E0208 alone"
- `verilog-a/ch04_expressions/reject_4_7_2_1_analog_function_with_range.va` same clause with "§4.7.2.1: `[0:1]`".
- `verilog/08_udp/definition_inside_module_rejected.v` "IEEE 1364-2005 §8.1: `primitive` inside a module is refused (E0205, both sides); the old side then reports E0206 for `output q`, a UDP terminal (§8.1 Syntax 8-1), as if it were a module port"
- `verilog/19_compiler_directives/macro_text_1800_forms_warn.v`: copy the comp.rulings line verbatim into `digital_exe.rulings`.
Files: `tests/differential/digital_exe.rulings` (new; header as `rtlil.rulings`), `tests/differential/rtlil.rulings`
(definition_inside_module). comp.rulings: report the three lines to the lead. digital_device: open question 1.

## 3. Oracles and red-first

| fix | oracle (named before code) | planted fault that must go red first | new oracle for the class |
|---|---|---|---|
| T1 | diff-comp, diff-digital-device, diff-digital-exe, diff-rtlil (old `vera` bytes); diff-parse, diff-astgen, diff-elab, diff-diag | revert `refuseDigital`'s call in `parseItem`: G1 lines return | – (the lists are it) |
| T2 (G15) | old `vera` bytes ("inside `u[0]`", digital_device:29); the new assert in `getString` (a panic is not testable in-process, so the assert is the oracle and the Sema test below exercises it) | remove the `arena.dupe` in `outsideScope`: the Sema relative-path test panics on the assert | the assert itself: every aliasing call site is now a crash in every diff run (the class "interned slice fed back to the pool") |
| T2 (G16) | old `vera --elab` on the three fixtures (sim.xfail:13-14, the device/exe lines); `src/Sema/test.zig`: three `.ieee1364 = true` cases (absolute, generate sibling, relative) expecting `&.{ .E1100 }` and the name `u[0]` / `somename[0]` | drop the prefix segments from `outsideScope`: the generate case goes green-wrong (accepted) | a metamorphic Sema test: the same defparam moved inside/outside a `begin : g` block flips accept/refuse |
| T3 | the fixture's own `//! reject-only the cycle ...`; diff-comp | keep the old self-read check: the line still differs | Sema test: `defparam w.x = y; parameter y = x;` names `` `w.y` → `w.x` → `w.y` `` and reports both defparams |
| T4 | diff-rtlil (3 lines), diff-comp scaled_delay_udp | move the call back to `backend.zig:230`: the 3 lines return | a Compilation test (`src/next/Compilation/test.zig`): an rtlil target with a defparam to nothing reports one E12xx and no E0901 |
| T5 | diff-comp (old bytes); `lib/std/vams/Ast/test.zig`: `"\400\q\500"` gives E0148, W0149, E0148 with byte ranges 1-5, 5-7, 7-11 | `badEscape` returning only the first: the test fails | the table test of `badEscape` over Table 2-2 (every listed escape: null; `\8`, `\q`: undefined; `\400`: above) |
| T6 | AstGen test: `(* a = N *) initial ...` lowers a Process with one Attr | leave `.attrs` default: test red | plan-dlower T5's diff-sim line |
| T7 | the fixture's `//! reject-only E0207`; diff-comp bytes | keep E0512: line differs | Sema test: `V(a,b,c)` → E0207 with `Part.sep = 2` |
| T8 | the fixtures' own `//! reject` (comp.zig `tiebreak`) | – (a ruling holds only while new status is 1..125) | – |

## 4. Tasks

Wrong-text bugs first (T2, T3). Each sized for one Sonnet agent.

| T | what | files | depends on | expected list changes |
|---|---|---|---|---|
| T1 | land rw-comp3 (§2 T1) | `lib/std/vams/{Ast,Ast/errors,Ast/test,Parse,Parse/expr,Parse/stmt,Parse/module,Parse/function,Diag/Wip,Diag/tests}.zig`, `src/Sema.zig`, `src/Sema/subset.zig`, `src/Sema/{walk,locate,checks,connect,resolve,test}.zig` (b87dbead/8261c3bd), `src/Zcu.zig`, `src/next/Compilation/{errors,frontend}.zig` | – | comp −31 (report); exe −6, dev −6, rtlil −6; sim −1 (scaled_delay_udp byte) |
| T2 | G15 + G16 | `src/InternPool.zig`, `src/Sema/defparam.zig`, `src/Sema/walk.zig` (one call), `src/Sema/test.zig` | T1 (walk.zig) | comp −3 (report: 1860-1862); exe −3 (408, 409, 413); dev −3 (27-29); sim −2 (13, 14) |
| T3 | G10 | `src/Sema/eval.zig`, `src/Sema/defparam.zig`, `src/Sema/walk.zig`, `src/Sema/test.zig` | T2 (same files) | comp −1 |
| T4 | G14 + G17 | `src/next/Compilation/{frontend,backend,errors,test}.zig` | T1 | rtlil −3 (16-18); comp −1 (scaled_delay_udp_rejected.v, after plan-dlower G1) |
| T5 | G3 + G4 | `lib/std/vams/{number_literal,Parse,Ast,Ast/errors,Ast/test}.zig`, `lib/std/vams/Parse/{function,design}.zig` | T1 | comp −4 |
| T6 | "Vir Process.attrs" (G18), before plan-dlower T5 | `lib/std/vams/Vir/Inst.zig`, `lib/std/vams/AstGen/stmt.zig`, AstGen test file | – (parallel with all) | none alone; unblocks plan-dlower T5 (sim −1, comp −1, exe −1, dev −1) |
| T7 | G5 | `src/Zcu.zig`, `src/Sema/{locate,contrib,test}.zig`, `lib/std/vams/Ast/errors.zig`, `src/next/Compilation/errors.zig` | T4, T5 (errors.zig, Ast/errors.zig) | comp −1 |
| T8 | rulings | `tests/differential/{digital_exe,rtlil}.rulings` | T1 (shows the cascade shape) | exe −2, rtlil −1; comp −3 (lead, comp.rulings) |

Lanes: T6 anytime, and before plan-dlower T5 (it unblocks attribute_value_is_constant_rejected.v). T1 → {T2 → T3} ∥ {T4, T5} → T7; T8 after T1.
Re-tags for the lead (comp.xfail is lead-only): geometry_card_mfactor_outside_domain_is_fatal.va → rw-lower;
resolveto_two_subset_rules_warn.va → rw-codegen (after T1 its first difference is the transcript).
Expected totals: comp rw-comp 42 → 2 re-tagged (40 cleared incl. 3 by ruling); plus 4 routed comp lines (3 G16/G15, 1 G17).
digital_exe rw-comp 8 → 0 (+3 rw-dlower lines). digital_device rw-comp 7 → 1 (definition_inside_module, Q1) (+3).
rtlil rw-comp 10 → 0. sim −3.

## 5. Commands (`H=~/.cache/vera-heavy.sh <wt>`)

Every task, before commit: `$H <wt> check test-unit test-vams test-sema test-air test-intern_pool test-link test-std_sim test-std_kernels test-codegen test-comp`;
`python3 ~/.claude/skills/code-style/check_style.py <touched files>`; `nix develop -c zig fmt --check <touched files>`.
Gate each on its exit code (`cmd > log 2>&1; echo $?`).

| T | diff gates | lists the task may edit |
|---|---|---|
| T1 | `$H <wt> diff-parse diff-astgen diff-elab diff-diag -j4`; `$H <wt> diff-comp -j4 -Dcomp-filter='annex_a_syntax|annex_d_standard|ch02_lexical|ch05_analog|ch06_hierarchy|ch08_sched|ch10_directives|annex_f_resolution|ch03_data_types|ch07_mixed|verilog-ams/digital|09_behavioral|19_compiler|A_formal_syntax|annex_b_keywords|ch04_expr'`; `$H <wt> diff-digital-device -j4`; `$H <wt> diff-digital-exe -j4`; `nix develop .#external -c zig build rtlil-equiv diff-rtlil -j4` (in the worktree) | parse/astgen/elab/diag/digital_device/digital_exe/rtlil `.xfail` lines it clears; comp.xfail: report |
| T2 | `$H <wt> test-intern_pool test-sema`; `$H <wt> diff-sim -j4`; `$H <wt> diff-elab -j4`; `$H <wt> diff-comp -j4 -Dcomp-filter='12_hierarchy|ch06_hierarchy'`; `$H <wt> diff-digital-device -j4 -Dcomp-filter=12_hierarchy`; `$H <wt> diff-digital-exe -j4 -Dcomp-filter=12_hierarchy` | sim, digital_device, digital_exe, elab |
| T3 | `$H <wt> test-sema`; `$H <wt> diff-elab -j4`; `$H <wt> diff-comp -j4 -Dcomp-filter='defparam'` | elab |
| T4 | `$H <wt> test-comp`; `nix develop .#external -c zig build rtlil-equiv diff-rtlil -j4`; `$H <wt> diff-comp -j4 -Dcomp-filter='verilog/|\.v$'` (the point rule touches every 1364 elaboration error); `$H <wt> diff-digital-device -j4`; `$H <wt> diff-digital-exe -j4` | rtlil, digital_device, digital_exe |
| T5 | `$H <wt> test-vams diff-parse diff-diag -j4`; `$H <wt> diff-comp -j4 -Dcomp-filter='ch02_lexical|own_expm1|configuration_source|annex_a_syntax'` | parse, diag |
| T6 | `$H <wt> test-vams diff-astgen -j4` | astgen |
| T7 | `$H <wt> test-sema test-comp`; `$H <wt> diff-elab -j4`; `$H <wt> diff-comp -j4 -Dcomp-filter='ch04_expressions'` | elab |
| T8 | `$H <wt> diff-digital-exe -j4 -Dcomp-filter='definition_inside_module|macro_text_1800'`; `nix develop .#external -c zig build diff-rtlil -j4 -Dcomp-filter=definition_inside_module` | digital_exe.rulings, rtlil.rulings, their .xfail lines |

## 6. Skills, where they bite

| skill | bites at |
|---|---|
| data-oriented-design | T3 `Env.pending` (who writes: `cycleOf`; who reads: `param()`; count: params of one module; lifetime: one `cycleOf` call; layout: hash map, cleared on exit; width: `Inst.Index` u32) and `Env.trail` (writer/reader `param()`; count <= `eval_depth_max`; lifetime: one fold; ArrayList of u32). T2 adds no table. T7 `Part.sep: u32` (an argument index, < 2^16 in practice; u32 matches `Part`'s other payloads). T6 `Process.attrs` (a `List(Attr)`, Vir's existing (start,len) handle). T5 `Escape` packs `start`/`len` in `Ast.Error.arg` (len <= 4: comptime-assert 8 bits suffice) |
| codebase-clean-code | one owner per table: Sema writes `zcu.failed`, Compilation renders it (T4, T7); T4 keeps the stage order in Compilation only; T2 deletes `outsideElement` instead of adding a second rule |
| api-design | `collect` gains a parameter, not a field; `cycleOf` takes the replacements as a slice (caller owns them); `reportOne` is the immediate twin of `report` |
| code-style | `src/Sema/*.zig` exempt from 500 lines (TODO §11.1); `lib/std/vams/Parse.zig`, `number_literal.zig`, `Ast/errors.zig`, `Compilation/errors.zig`, `InternPool.zig` are not: run `check_style.py`, update each header's Contents for every new/changed `pub` (`collect`, `cycleOf`, `badEscape`, `Escape`, `reportOne`, `rtlilRefused`) |
| doc-comments | every new `pub`: rank 1 ("Asserts that ...": `getString`'s alias assert, `cycleOf`'s busy/pending asserts), rank 3 (`outsideScope`'s result is arena-owned) |
| assertions | >= 2 split asserts per new function (`outsideScope`: `index < instances.len`, result's name non-empty; `cycleOf`: entry/exit `busy.count() == 0`); every loop bounded (`outsideScope` by depth, `checkStrings` by token length, `trail` by `eval_depth_max`); `// else: reason` on any new boundary-enum `else` prong (`Part`, `Rule`, `Error.Tag` switches stay exhaustive) |
| test-plan / tdd | §3: oracle named first, planted fault red first, one new oracle per class |
| compiler-construction | coded rows rendered once (`Ast.Error` → `Ast/errors.zig`; `zcu.failed` → `Compilation/errors.zig`); goldens are the old binary's bytes |
| zig | no `?u32` in new hot structs (none hot here); `errdefer` after each arena-free allocation crossing a `try` (`cycleOf` restores `values` with `defer`) |
| ponytail | T2/T3 ceilings named in `ponytail:` comments; T7 reuses the parse renderer rather than adding label/fix-it fields to `Zcu.Failure` |
| simd-loops | no hot loop: every loop here is per diagnostic or per defparam (scalar, stop) |
| writing-perfect-verilog | the T2/T3 Sema tests' Verilog sources: one module per item, declarations above use |
| spice-engine | G12 only (re-routed: `checkCard` is a run-time model-card check, rw-codegen's) |

## 7. Departures from Zig

1. **Escape diagnostics in Parse** (T5), where Zig reports them in AstGen (`Z/AstGen.zig:10833`). Parse errors are
   fatal before AstGen (`Z/AstGen.zig:187-189`), so in AstGen a file with any syntax error would lose its E0148s; the
   old side reports them first, over every string token. Kept in `Parse.checkStrings`, where they are today.
2. **Dialect-subset refusals in Parse** (T1 `refuseDigital`, T5 W0253, W0259): Zig has one dialect. The subset is
   lexical (a keyword under `--sim=verilogA`), so the parser is its earliest owner; `domain discrete` is semantic and
   stays in Sema (`subset.zig`).
3. **E0207 for a Sema finding** (T7): Sema finds the arity (only it knows `V` is an access function); the message is
   the parse renderer's, so E0207 has one renderer. Zig would say "expected 2 arguments, found 3" from
   `S/Sema.zig:6308` `checkCallArgumentCount`; the fixture pins E0207.
4. **`` `default_discipline `` E0250 in `Compilation.preprocess`** (T1, as the worktree has it): Compilation raises a
   language rule. Recommendation: T1 moves it into the Preprocessor's diagnostics (a `verilog_a` option) if diff-comp
   G1 stays green; otherwise it stays and this line stands.
5. **Generate scopes are names, not rows** (T2): `Zcu.instances` is the one hierarchy; a generate block is the prefix
   of its instances' names. Zig has no generate.
6. **The 1364 route's single-byte locations** (T4): a compatibility rule for lib/sim/digital's reports, applied once
   in `Compilation/errors.zig`.

## 8. Open questions

1. digital_device cannot rule a `//! reject` fixture: `comp.zig:285` `deviceTiebreak` returns "the new side builds no
   device" for any nonzero status, so definition_inside_module_rejected.v (G7) stays a digital_device line.
   Recommendation: `deviceTiebreak` returns null for `f.reject and new.status in 1..125` (the generic `tiebreak`'s rule),
   a 2-line harness change by the diff-comp owner.
   Decision: Yes: `deviceTiebreak` takes the generic rule (`f.reject` and status 1..125). The lead lands it with the judge fixes (airpasses J0-J3).
2. G7 by ruling vs by cascade: matching the old E0206 would run AstGen on a tree with errors (against Zig).
   Recommendation: rule it (T8).
   Decision: Rule it (T8). Zig's AstGen never runs on a tree with parse errors.
3. `getString` aliasing (T2): assert (a crash in every caller that does it) or accept it (re-slice after the grow).
   Recommendation: assert; it is a programmer error, and the diff suites find the callers.
   Decision: Assert: aliasing is a programmer error, and a bug hits an assertion. The diff suites find the callers.
4. G17 point rule covers every 1364-route elaboration error, not only E0247. Recommendation: the whole route
   (`run_diag.zig:77` located all of them that way); T4's full `.v` diff-comp run is its gate.
   Decision: The whole 1364 route; T4's full `.v` diff-comp run is its gate.
5. G12 geometry_card and the resolveto transcript leave rw-comp. Recommendation: re-tag in comp.xfail to rw-lower and
   rw-codegen.
   Decision: Yes, the lead retags them to rw-lower and rw-codegen.
6. T5 W0259 reads `p.language`; if `` `begin_keywords `` sections change the set mid-file and `p.language` is the
   file's set, the warning can be wrong inside a section. Recommendation: T5 checks it with one Ast test and reports.
   Decision: Yes: T5 checks it with one Ast test. If the file's set is wrong inside a section, the language set becomes per section in AstGen, not a check in Sema.
