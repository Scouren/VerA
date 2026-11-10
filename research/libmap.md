# libmap: IEEE 1364-2005 §13.2 library maps in vera-next (+ the one "backend exe" line)

Planner: plan-libmap. Base: `refactor` at 90e93007. No worktree holds libmap work (all 16 scanned:
no diff or commit mentions libmap, decl_lib, lib_order or the probe fixture).

## Spec (the shape of docs/rewrite/digital.md)

### What you own

| Piece | Path |
|---|---|
| The library-map reader: map bytes in; libraries, specs, `-incdir`s and refusals out. No I/O, request-driven | `src/next/Compilation/libmap.zig` (new; it becomes `src/Compilation/libmap.zig` at the switch-over, as lib/TODO.md §2 line 78 places it) |
| Answering its requests, placing each command-line unit in a library, filling `Zcu.decl_lib` / `Zcu.lib_order` | `src/next/Compilation/frontend.zig` (`readInputs`, `semaTop`), `src/next/Compilation.zig` (`realPath`, the `libmap` field) |
| Reporting its refusals | `src/next/Compilation/errors.zig` (`bundle`, `sources`) |
| The "backend exe" line: a §6.7.1 hierarchical probe terminal read from a digital process of a mixed `.va` | `src/Sema/digital/domain.zig` `terminal`, `src/codegen/bench.zig`, `lib/std/sim/bench/{spec,mixed}.zig`, `src/next/Compilation/backend.zig` `testbench` |

The old `lib/frontend/libmap.zig` (718 lines) and `src/cli/digital.zig:252-305` (`libraries`) stay
read-only. Appendix A.1 row 671 marks them "move, ~650".

### What it is

- **The binding is already built.** `src/Sema/library.zig` (310 lines) ports `lib/sim/digital/bind.zig`
  and runs whenever `zcu.decl_lib.count() != 0` (`src/Sema.zig:434`, `:486`, `src/Sema/walk.zig:547`).
  `%l` (`src/Sema/digital/format.zig:142`) and E1100's search order (`legacy.zig:80`) already read
  `Zcu.libraryOf`/`lib_order`. `src/Sema/test.zig:92 treeUnderMap` tests it. **Nothing fills the two
  fields**: `frontend.zig:47` refuses every `--libmap`/`-L` as "not built". The work is the
  Compilation side.
- Pipeline (one new job step, inside `read_inputs`):
  1. read `paths[0]`, as today. The old `main` read it before `libraries` ran.
  2. **libraries**: run `libmap.Reader` over `config.libmaps`, answering each `.file` request with
     `comp.read` + `comp.realPath`. Then `realPath` every `config.paths[k]`, place it
     (`Output.libraryOf`), and check each `-L` name (`Output.declares`). Store
     `comp.unit_libs: []InternPool.String` (one per path) and `comp.lib_order`. Append
     `Output.incdirs` to `comp.pp.options.include_dirs`; that is how `readInputs` already sets
     `pp.options.protect_keys` (`frontend.zig:65`).
  3. read `paths[1..]`, as today.
  4. `semaTop`, after `zcu.addFile`: for every decl of unit 0, its command-line unit is the
     partition point of its main token's offset in `pp.output().unit_starts`. Set
     `zcu.decl_lib[decl] = unit_libs[unit]` and `zcu.lib_order = comp.lib_order`. This mirrors the
     old `bind.zig:41 libraries` (`unitOf(more_starts, main_tok)`).
- Done only when `config.libmaps.len != 0 or config.search.len != 0`. Without either, nothing
  changes (open question Q1).

### The oracle

- **Differential** (the old `vera` is the reference): `diff-comp`, `diff-rtlil`,
  `diff-digital-exe` and `diff-digital-device` over the 21 fixtures below.
- **Spec examples** (independent of both compilers): each positive fixture's `.expected.txt`, derived
  by hand from §13.5/§13.7 and A.1.1 (`%m %l` per instance). The unit tests carry the §13.7.2 and
  §13.7.3 examples as literal tables. They move with the code from `lib/frontend/libmap.zig:438-483`.
- **Reference implementation**: `glob` against `testGlobOracle`, the dynamic program, exhaustively
  (`libmap.zig:554`, moved). New: `libraryOf` against a brute-force reference (below).

### Done when

- No `.xfail` line reads `not built: backend libmap`, and `Compilation.Backend` has no `libmap` variant.
- `comp.xfail` loses all 21 libmap lines (20 by T2; `cell_not_in_its_library_rejected` once
  dlower T4's design-cell rule lands), plus the `backend exe` line (T3).
- The README gate set passes. `check_style.py` passes on every touched file, and `libmap.zig` is
  ≤500 code lines (the old one is ~405 before its tests).

---

## 1. Root causes

| # | Group | Lines | Examples |
|---|---|---|---|
| A | **Map reading not built**: a map refusal (E0244) must stop the compile before anything else. Old: `lib/frontend/libmap.zig:124-222` (`Loader.read`), `src/cli/digital.zig:261-287` | comp 7, rtlil 7, digital_exe 7, digital_device 7 | `config_in_map_rejected`, `library_without_path_rejected`, `source_text_in_map_rejected`, `two_libraries_match_rejected` (§13.2.1.1 tie), `undeclared_library_rejected` (`-L nosuch`), `b_A_1_1_include_without_path_rejected`, `b_A_1_1_include_without_semicolon_rejected` |
| B | **Library placement not fed to Sema**: positives that bind through a map or `-L` and print `%l` | comp 13; rtlil 13; digital_exe 13; digital_device 13 | `cfg1_default_liblist`, `cfg2_gate_first`, `cfg3_cell_use`, `cfg4_instance_liblist`, `cfg6_hierarchical`, `command_line_search_order`, `config_overrides_command_line`, `default_search_order`, `include_map`, `parent_library_by_map`, `resolution_order`, `b_A_1_1_incdir`, `b_A_1_1_library_text` |
| C | **Design cell absent from its library**, refused by no new code. Owned by **plan-dlower T4** (see Boundary) | comp 1, rtlil 1, digital_exe 1, digital_device 1 | `cell_not_in_its_library_rejected` (old: E1100 "library `gateLib` holds no cell `top`", `lib/sim/digital/bind.zig:199-201`) |
| D | **Hierarchical probe terminal from digital**: the mixed runner's digital half refuses `V(u.p)` | comp 1 (`not built: backend exe`) | `verilog-ams/ch06_hierarchy/hierarchical_analog_probes_from_digital.va`. Refused at `src/Sema/digital/domain.zig:294` ("a probe terminal that is no simple name // ponytail: lib/sim/digital also takes a hierarchical one") |

Totals: 21 per list × 4 lists = 84 libmap lines, plus 1 exe line. Every line lands in a group.

**Where each group-B line goes after T2** (the four lists differ):

| List | Group B outcome | Why |
|---|---|---|
| comp | clears (13) | `--run`: Sema's library path is already ported and tested |
| rtlil | clears (13), expected | the non-libmap `13_configuration` fixtures all agree in rtlil today (only `unbound_instance_rejected` is ruled) |
| digital_device | **ruled** (13): appended to `digital_device.rulings` | ruling by VAMS-2023 §7.8 ("a design with no ports is a device of no pins"): every libmap positive's top is pinless, and the old device of a pinless top does not compile. The same ruling already covers 639 fixtures, including 13 non-libmap `13_configuration` ones (`digital_device.rulings:429-441`) |
| digital_exe | **re-owned** (13): owner becomes `digital_exe (build remarks)` | the old exe prints the `note: ... 2-state once ...` build remark and the new one prints none. This is the backend's own debt (707 such lines today, the 15 non-libmap config fixtures among them). Not libmap's to clear: report it |

Group-A lines clear in all four lists, because the refusal comes before any backend. Group C clears
once dlower T4's rule exists.

### Boundary with plan-dlower T4 (the configuration-cell bug)

- **plan-dlower's T4 owns** the Sema refusal for a config's `design [lib.]cell` naming a cell its
  library lacks (the lead's ownership decision; `research/dlower.md` G7, T4). It adds
  `Zcu.Rule.design_cell` (E0904 on the analog route; `legacy.zig:rule` rewords it to E1100
  "undeclared module in instantiation: library `L` holds no cell `C`" on the 1364 route) at both
  sites: `src/Sema/library.zig:80` (`roots`, the map path, `designCell(...) orelse continue`) and
  `src/Sema.zig:438` (`configRoots`, the no-map path, `orelse continue`). G7 lists
  `cell_not_in_its_library_rejected.v` beside comp.xfail:1876-1877 (`design_cell_missing_rejected`,
  `design_names_config_rejected`).
- **libmap owns** everything up to `zcu.decl_lib`/`lib_order` being filled, and touches no file in
  `src/Sema/`. T3 is the exception: it touches `src/Sema/digital/domain.zig`, which is plan-dlower's.
- Group C clears with dlower T4's rule plus T2. Both must land; the order between them does not
  matter.

---

## 2. The fixes

### Group A+B: `src/next/Compilation/libmap.zig` (task T1)

**Zig mirror.** The map is a tiny language of its own, parsed purely, with diagnostics as rows. That
is Zig's `build.zig.zon` manifest: `lib/compiler/Maker/Package/Manifest.zig:59 parse(gpa, ast, …)`
returns a value whose `errors: []ErrorMessage` (`:50`) the caller renders, while I/O stays with the
caller (`lib/compiler/Maker/Fetch.zig:885 loadManifest`). The `include` request/answer loop follows
aro `Preprocessor.zig:3470 include` and the in-repo readers built on it: `vams.Preprocessor.run/answer`
and `vams.spice.Netlist.run/answer` (`lib/std/vams/spice.zig:104,136`). Compilation answers every
request, as lib/TODO.md §3 row 1 says.

**Six data questions** (for `Reader` and `Output`):

1. In: the map files' bytes, in `--libmap` order (§13.2.1 "read in the order in which they are
   specified"), plus each `include`d map. Out: `libraries` (name and its specs),
   `incdirs`, `files` (for diagnostics), and at most one refusal.
2. How many: a few map files, ≤ dozens of libraries and specs. Capacity: map files ≤
   `vams.Preprocessor.files_max` (65535; past it E0244 "past {d} source files", as old `:142`).
3. Widths: file index `u32`; `Class = enum(u8) {file, wildcard, directory}` (old `enum(u2)`, widened
   for array storage, no packing gain at this count); offsets `u32` (map text ≤
   `Preprocessor.max_text_bytes`).
4. Access: `libraryOf` is called once per command-line path and scans every library's specs in
   declaration order (old `:54-74`). `declares` is called once per `-L`. It runs once per
   compilation, so it is cold.
5. Lifetime: the compilation arena (`comp.arena()`), all of it, freed with the compilation.
6. Parallel: no. Include order is semantic (§13.2.2 "as though the contents … appear in place"), and
   this is a serial pre-pass like preprocessing (§3.1 of the plan).

So the old AoS stays: `Library{name, specs: []const Spec}`, `Spec{pattern, class}`. A cold table of
dozens gains nothing from SoA. No `@sizeOf` assert: nothing here is hot (AGENTS.md asks for one on
hot structs only). `ponytail: AoS, cold, run once`.

**Surface** (write the caller's code first; this is it, in `frontend.libraries`):

```zig
var r: libmap.Reader = .init(comp.arena(), comp.config.libmaps);
while (try r.run()) |req| switch (req) {
    .file => |want| try r.answer(switch (try comp.read(want.path)) {
        .failed => |e| .{ .unreadable = e },
        .bytes => |b| switch (try comp.realPath(want.path)) {
            .failed => |e| .{ .unresolvable = e },
            .path => |real| .{ .file = .{ .bytes = b, .real = real } },
        },
    }),
};
const map = r.output();
if (map.refusal != null) return false; // errors.bundle reports it
```

```zig
//! IEEE 1364-2005 §13.2 library map files with no I/O: map bytes in, a `Map` out ...
//! Cites: §13.2.1, §13.2.1.1, §13.2.2, §13.2.3, §13.5.1, §13.7.1, A.1.1.
pub const Class = enum(u8) { file, wildcard, directory };
pub const Spec = struct { pattern: []const u8, class: Class };
pub const Library = struct { name: []const u8, specs: []const Spec };
pub const File = struct { name: []const u8, text: []const u8 };
/// One E0244: `file` null for a top-level map that cannot be read (no file to point into).
pub const Refusal = struct { file: ?u32, start: u32, end: u32, message: []const u8 };
pub const Placement = union(enum) { lib: []const u8, ambiguous: [2][]const u8 };
pub const Request = union(enum) { file: struct { path: []const u8 } };
pub const Answer = union(enum) {
    file: struct { bytes: []const u8, real: []const u8 },
    unreadable: anyerror,   // "cannot read library map `{s}`: {t}"
    unresolvable: anyerror, // "cannot resolve library map `{s}`: {t}"
};
pub const Output = struct {
    libraries: []const Library = &.{},
    incdirs: []const []const u8 = &.{},
    files: []const File = &.{},
    refusal: ?Refusal = null,
    pub fn libraryOf(out: Output, file: []const u8) Placement;          // old :54
    pub fn order(out: Output, arena: Allocator) Allocator.Error![]const []const u8; // old :79
    pub fn declares(out: Output, name: []const u8) ?usize;            // old :91
    pub fn report(out: Output, wip: *Diag.Wip, first: Diag.File) Allocator.Error!void; // spice.zig:184 shape
};
pub const Reader = struct {
    arena: Allocator,
    pending: []const []const u8,   // config.libmaps not started yet
    frames: std.ArrayList(Frame),  // the include stack, outermost first
    open: std.ArrayList([]const u8), // real paths of `frames`, for the cycle check
    want: ?[]const u8 = null,
    want_at: ?Site = null,         // the `include` naming `want` (null: top level)
    libs: std.ArrayList(struct { name: []const u8, specs: std.ArrayList(Spec) }),
    incdirs: std.ArrayList([]const u8),
    files: std.ArrayList(File),
    refusal: ?Refusal = null,
    done: bool = false,
    pub fn init(arena: Allocator, maps: []const []const u8) Reader;
    pub fn run(r: *Reader) Allocator.Error!?Request;
    pub fn answer(r: *Reader, a: Answer) Allocator.Error!void;
    pub fn output(r: *const Reader) Output;
};
const Frame = struct { file: u32, pos: u32, dir: []const u8 };
pub fn matches(pattern: []const u8, file: []const u8) bool; // old :294, unchanged
```

- `run` steps the top frame's `Tokens` (old `:232-263`, unchanged). It handles `library` inline,
  exactly as old `:163-196`. On `include` it resolves the spec against `frame.dir`, sets `want` and
  returns `.file`. A frame at end of text pops and drops its `open` entry, then the next path of
  `pending` is requested. This is an **explicit stack**: it replaces the old recursion plus
  `deep_stack.run` (`:159`), per compiler-construction rule 7. The bound is the
  `files_max` frames, asserted.
- `answer`: for `.file`, a `real` already in `open` is the cycle refusal (message as old `:132-135`,
  chain `a -> b -> a`). Otherwise append `File{name = want, text = bytes}`, then push a
  `Frame{dir = slashed(dirname(real))}`. For `.unreadable`/`.unresolvable` it records the refusal at
  `want_at`.
- Every message is copied verbatim from old `:127-222`. The fixtures pin the code and a substring;
  diff-comp pins the whole line.
- **New fixed cap with its own error** (lib/TODO.md §11.2): a `file_path_spec` longer than
  `std.fs.max_path_bytes` is E0244 "`{s}…` is longer than a path". `segments` recurses once per
  `/`-separated name, so this bounds its depth on input the user controls. No fixture is near it.
- Errors: `Allocator.Error` only. A refusal is data (`Output.refusal`), never an error return,
  following the Manifest/spice shape.
- Assertions: `run` asserts `want == null` on entry and `frames.items.len <= files_max`. `answer`
  asserts `want != null` and, after, `want == null`. `Tokens.next`/`glob` keep their asserts (old
  `:240,259,260,388,403`). `libraryOf` keeps `best != null or tie == null` (`:71`). `report` asserts
  each refusal's `file < files.len`.

**Tests** (in the file, moved and adapted; no tmpDir, since the reader does no I/O):
moved from old `:438-718` (§13.7.2 table, §13.7.3 table, Tokens, isIdentifier/unquote, resolveSpec,
matches, glob exhaustive vs DP, glob many-stars, libraryOf ties, order/declares). `load` tests become
request-driven: answer from an in-memory `[(path, real, bytes)]` table. That covers library and
include statements with a library declared twice, a 40-deep include chain (a stack, so 10^4 deep
also runs: add that case), the 20 malformed-statement refusals of old `:682-706` (each `Refusal`
message), and a top-level unreadable map giving `file == null`.
**New oracle** (the bug class: a file placed in the wrong library is a wrong `%l` and a wrong
binding with no crash): `test "libraryOf agrees with a brute-force reference"`. Seeded
`std.Random.DefaultPrng` builds 10^4 random maps (1-5 libraries × 1-3 specs from a small alphabet of
`a`, `b`, `*`, `?`, `...`, `/`, a trailing `/`) and random files. The reference computes, per
library, the minimum class over specs matched by **`testGlobOracle`-based** segment matching, then
the first minimum and the first tie in declaration order (§13.2.1.1), written independently of
`libraryOf`'s loop.

### Group A+B wiring (task T2)

| Site | Change |
|---|---|
| `src/next/Compilation.zig:103` | delete `libmap` from `Backend`. The compiler then lists `backend.zig:131` (delete the prong) and `frontend.zig:48`; change radius 3 |
| `src/next/Compilation.zig` fields | add `libmap: ?libmap.Output = null`, `unit_libs: []const InternPool.String = &.{}`, `lib_order: []const InternPool.String = &.{}` (the last two in the arena; borrowed by `zcu.lib_order`) |
| `src/next/Compilation.zig` after `read` (`:238`) | `pub fn realPath(comp, path) Allocator.Error!RealPath`, with `pub const RealPath = union(enum) { path: []const u8, failed: anyerror }`: `Io.Dir.cwd().realPathFileAlloc(comp.io, path, comp.arena())`. It is the only other filesystem touch; doc comment: "the only symlink resolution; §13.2.1 matching needs both sides resolved alike". Cache by path in a second `StringArrayHashMapUnmanaged` (`real_paths`), like `reads` |
| `src/next/Compilation.zig` `test` block (`:299`) | `_ = @import("Compilation/libmap.zig");` |
| `src/next/Compilation/frontend.zig:44-74` `readInputs` | delete the not-built branch. New order: read `paths[0]` (fail: status 2, as now); then `if (c.libmaps.len != 0 or c.search.len != 0) if (!try libraries(comp)) { status = 1; return false; }`; then `paths[1..]` (fail: status 1, as now) |
| `frontend.zig` new private `fn libraries(comp) !bool` (~45 lines) | the caller code above. Then, per path, `realPath`: failure prints `error: cannot read \`{s}\`: {t}\n` on `outputs.err` (old `digital.zig:270-272`). Then `libraryOf(real)`: `.ambiguous` is `comp.wip.add(.parse, .E0244, .none, "\`{s}\` matches file path specifications of libraries \`{s}\` and \`{s}\` (IEEE 1364-2005 §13.2.1.1)", .{p, two[0], two[1]})` (old `:276`). Each `-L l` with `declares(l) == null and l != "work"` is `.E0244, .none, "-L {s}: no library map declares library \`{s}\` (IEEE 1364-2005 §13.7.1)"` (old `:284`). Intern the libraries into `unit_libs`; `lib_order` = `config.search` if non-empty, else `map.order()` (old `:303`: `opts.search` is never empty from the CLI). `comp.pp.options.include_dirs = concat(config.include_dirs, map.incdirs)`, with the old ponytail (`:299-302`) carried: every unit gets every library's `-incdir` |
| `frontend.zig:173` `semaTop`, after `addFile` | `if (comp.unit_libs.len != 0) try assignLibraries(comp, file, u)` (new private fn, ~15 lines). For each `d, k` in `u.vir.decls()[u.builtins..]`, `unit = partitionPoint(unit_starts, offset(d))`, then `zcu.decl_lib.put(gpa, decl, unit_libs[unit])`. Set `zcu.lib_order = comp.lib_order`. Asserts: `unit_libs.len == config.paths.len`; `unit_starts.len + 1 == unit_libs.len`; after, `decl_lib.count() == decls - builtins`. Offset: the decl's main-token start, as `declSource` (`frontend.zig:255`) computes it. Factor that line into `fn declStart(u, d) u32` and call it from both (second real instance) |
| `src/next/Compilation/errors.zig:42` | after the netlist report, `if (comp.libmap) \|m\| try m.report(&w, @fromBackingInt(pp_files + net_files))` |
| `errors.zig:88` `sources` | append `comp.libmap.?.files` after the netlist's (same `Diag.Source` construction) |
| `frontend.zig` header, `Compilation.zig` header | Contents and Cites (§13.2, §13.7.1) updated |

The library-map step runs **before** preprocessing, so on a refusal `pp.output().files` is empty and
the map files start at index 0 + netlist. `report` takes that base.

### Group D: hierarchical probe terminals (task T3)

Old behaviour: the digital half names a probe terminal by its parts joined with `.`
(`lib/sim/digital/wait_lists.zig:90 probeName`). The analog lowering resolves that key to a node
pair (`src/analog/discrete_check.zig:300 recordProbeTerminal`):

- a named branch when it is the probe's only argument, else `(net, ground)`;
- a hierarchical name that names neither is E0901 "`{s}` names no net or branch in the elaborated
  design";
- the runner reads a `probe_terminals` map (`src/codegen/exe/mixed.zig:110-118`).

New: `lib/std/sim/bench/mixed.zig:204 nodeValue` looks the name up in the unknowns and **returns 0.0
when it is not there**. A named-branch probe (`V(u.sense)`, `V(sense)`) is no unknown name, so it
reads 0.0 silently. **That is a wrong-number hole**, and this fixture is its only witness today
(its `CHECKX(..., 2.0)` lines).

| Site | Change |
|---|---|
| `src/Sema/digital/domain.zig:288` `terminal` | add a `.field` prong. Walk the `Inst.Field{operand, name}` chain iteratively down to a `.decl_ref`/`.str_ref` head, collecting names (bound: chain length ≤ `vir.instructions.len`, asserted), reverse, then join with `.`. `.elem` in the chain refuses "a probe terminal of an instance array element" (the old `nameParts` holds identifiers only). Drop the `ponytail:` comment |
| `src/Sema/digital_test.zig` | `test "VAMS §7.3.6.3 a hierarchical probe terminal lowers to its dotted name"` over `V(u.p)` and `V(u.sense)` in an `initial`. Expect `p.str(probe.a)` to equal `"u.p"` and `"u.sense"` (the pattern of `:244`) |
| `lib/std/sim/bench/spec.zig:47` `Digital` | add `probes: []const Probe = &.{}`, with `pub const Probe = struct { name: []const u8, hi: u32, lo: ?u32 }` (`hi`/`lo` are unknown indices; `lo` null is ground). Six questions: one row per distinct probe terminal (≤ hundreds); `u32` covers `Liveness.unknowns_max`; read once per probe call by name; it lives for the runner (comptime data); not parallel |
| `src/codegen/bench.zig:96` `digital` | takes `device: *const Air.Device, ip`, scans `program`'s `.probe` exprs, and resolves each distinct terminal name once: `Device.branches` by name when the probe has one argument, else `Device.nodes` by name with ground. An unresolved name returns `error.UnknownProbe` with the name (`Digital.unresolved`). Compilation turns it into E0901 at the call, using old's words. Signature: `pub fn digital(arena, program, names, device: *const Air.Device, ip: *const InternPool) (Allocator.Error \|\| error{UnknownProbe})!Digital` |
| `src/next/Compilation/backend.zig:469` `testbench` | pass the device; on `UnknownProbe`, `comp.wip.add(.lower, .E0901, .none, "\`{s}\` names no net or branch in the elaborated design", …)`, then stop |
| `lib/std/sim/bench/mixed.zig:200-207` | `potential` looks the name up in a comptime `std.StaticStringMap` built from `digital.probes`. A miss is `unreachable` (codegen guarantees completeness), so it is no longer a silent 0.0. Delete `nodeValue` |

---

## 3. Oracle and red-first, per task

| Task | Proving oracle | Planted fault that must go red first | New oracle for the class |
|---|---|---|---|
| T1 | `zig build test-comp` (libmap.zig tests: LRM §13.7.2/§13.7.3 tables, glob vs DP exhaustive) | in `libraryOf`, `<` becomes `<=` at the best-class compare (old `:64`): §13.7.3 `foover.v` stops being a tie and the test goes red. Second plant: `resolveSpec` classes `rtl/` as `.wildcard`: the resolveSpec table goes red | `libraryOf` vs brute-force reference, 10^4 seeded random maps |
| T2 | `diff-comp -Dcomp-filter='13_configuration|A_1_1'` (old vera as reference), then the three `.v` diffs; each positive's `.expected.txt` hand-derived from §13.5/§13.7 | (a) `assignLibraries` puts every decl in `unit_libs[0]`: `b_A_1_1_library_text` prints `work.a` for `liba.a`, red. (b) `lib_order` drops `work`: `default_search_order` red. (c) skip `pp.options.include_dirs` update: no fixture fails. Report that `-incdir` has no observable fixture (b_A_1_1_incdir says so itself) and add a test-comp case (below) | test-comp `test "a -incdir directory serves an \`include of a unit in that library"` through `Compilation` with `Config.overlays` (map and sources in memory, no disk): red under plant (c) |
| T3 | `diff-comp -Dcomp-filter='hierarchical_analog_probes_from_digital'`; the fixture's own `CHECKX` lines (2.0 V by construction, `//! lrm 6.7.1:1005`) | (a) before the fix, the new `digital_test.zig` test is red (Unsupported). (b) after it, plant `potential` falling back to unknown-name lookup with 0.0: the fixture's branch `CHECKX` goes red | the completeness check itself (every Program probe resolves at codegen, or E0901) removes the silent-0.0 class. A test-codegen test for `bench.digital` over a device with a branch, a net and an unknown name expects `UnknownProbe` |

---

## 4. Tasks

| # | Task (one Sonnet agent each) | Files | Depends | Wrong-number? |
|---|---|---|---|---|
| T3 | Hierarchical probe terminals + probe table (group D) | `src/Sema/digital/domain.zig`, `src/Sema/digital_test.zig`, `src/codegen/bench.zig`, `lib/std/sim/bench/spec.zig`, `lib/std/sim/bench/mixed.zig`, `src/next/Compilation/backend.zig` (`testbench` only) | none | **yes** (silent 0.0 for a branch probe): first |
| T1 | `libmap.zig`: the request-driven reader, moved matcher, tests + brute-force oracle | `src/next/Compilation/libmap.zig` (new), `src/next/Compilation.zig` (test-block import line only) | none | yes (placement): parallel with T3 |
| T2 | Wiring: `realPath`, `libraries`, `assignLibraries`, errors/sources, delete `Backend.libmap`, list maintenance | `src/next/Compilation.zig`, `src/next/Compilation/frontend.zig`, `src/next/Compilation/errors.zig`, `src/next/Compilation/backend.zig` (delete prong `:131` only), `src/next/Compilation/test.zig`, `tests/differential/{rtlil,digital_exe,digital_device}.xfail`, `digital_device.rulings` | T1; rebase over T3 (one-line overlap in backend.zig) | yes |

T1 and T3 share no file. T2 and T3 overlap only in `backend.zig`, at distant lines (`:131` vs `:449-470`).
T2 shares no file with dlower T4's Sema work (`src/Sema.zig`, `src/Sema/library.zig`, `src/next/Compilation/legacy.zig`).

## 5. Commands (gate on `$?`, never a pipe)

| Task | Commands | Lists it may change |
|---|---|---|
| T1 | `~/.cache/vera-heavy.sh <wt> test-comp -j4 > l 2>&1; echo $?`, then `check`, `python3 tools/check_style.py src/next/Compilation/libmap.zig`, `zig fmt --check src/next/Compilation/libmap.zig` | none |
| T2 | `~/.cache/vera-heavy.sh <wt> test-comp test-vera-next -j4`; `~/.cache/vera-heavy.sh <wt> diff-comp -Dcomp-filter='13_configuration\|A_1_1' -j4`; `~/.cache/vera-heavy.sh <wt> diff-digital-exe -Dcomp-filter='13_configuration\|A_1_1' -j4`; `~/.cache/vera-heavy.sh <wt> diff-digital-device -Dcomp-filter='13_configuration\|A_1_1' -j4`; `nix develop .#external -c zig build diff-rtlil -Dcomp-filter='13_configuration\|A_1_1' -j4` (under the heavy lock); then once unfiltered `diff-comp`, to show no other fixture moved; `check rewrite test-unit` | `rtlil.xfail`, `digital_exe.xfail` (drop 7, re-own 13 as `digital_exe (build remarks)`, as the run's `.new` file writes them), `digital_device.xfail` (drop 20) + `digital_device.rulings` (13 lines of the existing pinless text, only for fixtures whose old run fails on the pinless device). **Never comp.xfail**: report its 20 lines (21 after dlower T4) |
| T3 | `~/.cache/vera-heavy.sh <wt> test-sema test-codegen test-std_sim -j4`; `~/.cache/vera-heavy.sh <wt> diff-comp -Dcomp-filter='hierarchical_analog_probes_from_digital\|ch07_mixed_signal\|ch08' -j4` (the mixed corpus, to show no probe regressed); `check rewrite test-unit` | none in its own lists. Report comp.xfail:1505 |

## 6. Departures from Zig

Every Zig file:line in this plan is cited from the checkout at
`scratchpad/zig` (`git log -1` = `d924f83bf`, the pinned commit). `~/.cache/zig-src-d924f83bf`
still showed `3e4c8a80` when checked, so it was not used.

Mirrors by stage: map parse = `Manifest.zig:59` (pure, `errors` rows `:50`), its I/O =
`Fetch.zig:885` (here `Compilation.read`/`realPath`, the only reader); include requests = aro
`Preprocessor.zig:3470`; placement = `Zcu.File.mod` (`Zcu.zig:1004`) set by
`computeAliveFiles` (`Zcu/PerThread.zig:2601,2628`), the tie = `multi_module_err`
(`Zcu.zig:149`); refusal rendering = `getAllErrorsAlloc` (`Compilation.zig:3829`, here
`errors.bundle`). Sema reads only `zcu.libraryOf`/`zcu.lib_order`; no stage reaches into a
sibling's tables, and the old `opts.lib`/`opts.more`/`opts.search` shape is not reproduced.

1. **Library per `Decl`, not per `Zcu.File`.** In Zig a file's module is `Zcu.File.mod`
   (`src/Zcu.zig:1004`), set by `computeAliveFiles` (`src/Zcu/PerThread.zig:2601`, `:2628`). Zig's
   one-file-in-two-modules error, `multi_module_err` (`src/Zcu.zig:149`), is the §13.2.1.1 tie. vera-next
   AstGens one unit per compilation (`frontend.zig:131` `ponytail:`), so every command-line file
   shares `Zcu.File` 0 and the library must key on `Decl` (`Zcu.decl_lib`, already Sema's input).
   When units split per file (docs/rewrite/comp.md "decisions"), `decl_lib` becomes
   `Zcu.File.lib: InternPool.String` and `assignLibraries` becomes one store per file. No other code
   moves, because Sema reads only `zcu.libraryOf`.
2. **Symlinks resolved** (`realPath`). Zig's `Compilation.Path` (`src/Compilation.zig:377`)
   normalises without resolving symlinks. §13.2.1 resolves specs against the map file's own
   directory and compares against the parsed file's path. A worktree's `tests/conformance` is a
   symlink, so unresolved paths would make the map side and the source side disagree. Old and new
   resolve both sides alike.
3. **The reader lives in `Compilation/`, not `lib/std/vams/`.** That is where the SPICE reader is,
   but lib/TODO.md §2 puts it there, its only consumer is `Compilation`, and Zig keeps its manifest
   parser out of `std.zig` too.

## 7. Risks

| # | Risk | Handling |
|---|---|---|
| R1 | Sema's map path (`src/Sema/library.zig`) has run only in `src/Sema/test.zig`, never on the corpus, so a group-B positive may differ after T2 | That is an elab-owned line (`rw-elab (elaboration)`), not a T2 failure. T2 reports each with its first difference and must not patch Sema |
| R2 | digital_exe group-B lines stay listed (re-owned to `digital_exe (build remarks)`) | Expected; not libmap debt |
| R3 | Group C (`cell_not_in_its_library_rejected`) clears only once plan-dlower T4's design-cell rule lands (`src/Sema.zig:438` `configRoots`, `src/Sema/library.zig:80` `roots`) | Boundary stated in §1; either order of landing works |

## Open questions

**Q1. Fill `Zcu.decl_lib` only when `--libmap` or `-L` is given, or for every `.v` design?**
The old driver always ran its library path (empty map: everything in `work`, search `work`); Sema's
no-map path differs (one config level, `liblist` binds nothing: `src/Sema.zig:418-420` ponytail).
Recommendation: only with `--libmap`/`-L`. The no-map path agrees on every current fixture;
switching risks them. Revisit when Sema's no-map ponytail goes.
Decision: Only with `--libmap`/`-L` for now, marked `ponytail:` with its ceiling. Merge it with the map path when Sema's no-map ponytail goes.

**Q2. May T2 append the 13 `digital_device.rulings` lines for the libmap positives (pinless top)?**
Recommendation: yes, verbatim in the existing VAMS-2023 §7.8 ruling text, and only for fixtures
whose old run fails with the pinless-device error; any other difference stays listed and reported.
Decision: Yes, verbatim in the VAMS-2023 §7.8 ruling text, only for fixtures whose old run fails with the pinless-device error.

**Q3. Accept a new E0244 refusal for a `file_path_spec` longer than `std.fs.max_path_bytes`?**
It bounds `segments`' recursion on input-controlled depth; the old code had no bound.
Recommendation: accept. It is lib/TODO.md §11.2's settled "fixed cap with its own error", and no
fixture is near it.
Decision: Accept: a `limit-` code under diagcodes, bounding recursion on input-controlled depth (lib/TODO.md §11.2).

**Q4. T3 edits plan-dlower's `src/Sema/digital/domain.zig` and plan-codegen's `src/codegen/bench.zig`. Who runs it?**
Recommendation: run T3 as its own task (it fixes the silent 0.0 branch-probe wrong number, so
first) and tell both owners; the change is additive (one `terminal` prong, one `digital` parameter).
Decision: T3 runs first as its own task (silent 0.0 is a wrong number); both owners are told; the change is additive.

**Q5. Who owns `tests/differential/sim.xfail` 's 7 library-map refusal lines (G14 in `research/dlower.md`)?**
diff-sim drives Sema directly and has no map input, so an E0244 map refusal can never agree there.
Recommendation: as dlower's plan already records (G14, T6b): once T2 lands and diff-comp grades
them end to end, dlower T6b moves them to `sim.rulings` ("IEEE 1364-2005 §13.2: a library map is a
`Compilation` input, outside std_sim's contract; diff-comp grades it"). libmap edits no sim list.
Decision: As dlower G14/T6b: after T2, dlower moves them to `sim.rulings` citing IEEE 1364-2005 §13.2. libmap edits no sim list.
