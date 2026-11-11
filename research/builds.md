# Research: build time and memory across agents and worktrees

Planner: r-builds (Fable). Base: `refactor` at 23bc8f65. Measured, not read: every number below
was taken on this machine on 2026-11-11 between 11:30 and 12:30, with the method in its row.
Zig 0.18.0-dev.349+d924f83bf; `Z/` = its source (`~/.cache/zig-src-d924f83bf/`, `git log -1` =
d924f83bf). Machine: 32 cores, 31 GB RAM + 31 GB swap (6 GB of it in use), one ext4 volume at
96 % (41 GB free). Four to seven other agents built throughout (load average 4 to 14, two corpus
steps holding the slots most of the time), so every time is a min and a median over repeats,
and a difference under about 20 % is called noise. `taskset` was not used: the cores were
shared with the other agents' builds, so pinning mine would not have isolated it.

Tools (scratch, not committed): a wall clock around the command (`time.monotonic`), the
compiler's own phase split (`zig build-* --listen=- --time-report`, the `TimeReport` message,
`Z/lib/std/zig/Server.zig:199`), `/usr/bin/time` for max RSS, and a `/proc` sampler of a
process tree's RSS every 0.5 s. A corpus step was never started outside `tools/build-slot.sh`;
corpus numbers come from earlier full-run logs (named in their row), from sampling other
agents' running corpus steps read-only, and from rebuilding one captured `diff-codegen` batch
by hand with its exact `zig build-lib` argv.

## 0. The answer in five lines

1. **Light test steps never cache under `nix develop`** (F1): every call gets a fresh `TMPDIR`,
   and a Run step that sets one variable hashes the whole environment. Eight `test-<module>`
   steps cost 10.1-11.5 s per call with nothing changed; with a stable environment, 0.44 s.
2. **`diff-codegen`'s build time is one device and no cache** (F7): one 9.7 MB generated
   device took 1213 s and 4.93 GB to build; the old side's libraries (frozen code) are
   rebuilt from scratch on every run although `link.File` has a library cache.
3. **The edit loop's cost is memory** (F4): `check --watch -fincremental` re-checks an edit in
   0.07-0.09 s, but holds 38 compiler processes, 6.4-6.5 GB, per agent; six agents is more
   than the machine has.
4. **The shared `.zig-cache` mostly ping-pongs** (F6): one manifest per (root, flags), so two
   worktrees with different sources evict each other; a second worktree at the *same* commit
   still misses the four longest `check` roots because absolute paths are compiled in.
5. **What does not pay**: splitting the compiler into objects, another linker, LLVM in Debug,
   skipping `nix develop` (about 1 s), a different Zig build: Section 4, F8 and F10.

## 1. Baseline

| What | How | n | min / median | State |
|---|---|---|---|---|
| `nix develop -c true` | wall | 7 | 0.85 / 0.96 s | flake eval cache warm |
| same, right after an edit dirtied the tree | wall | 4 | 0.70 / 0.84 s | |
| `check`, nothing changed, through `nix develop` | wall | 5 | 1.70 / 1.83 s | 0 compile steps rerun |
| `check`, nothing changed, no `nix develop` (same zig, same global cache) | wall | 5 | 0.69 / 0.81 s | 0 rerun; a sixth run reran 4 roots another worktree had evicted (4.68 s, F6) |
| `check` cold: empty local cache, warm global | wall | 3 | 9.10 / 10.14 s | 37 roots, 81 MB of cache |
| `check` after a one-line body edit (`lib/std/vams/tokenizer.zig` `next`), plain build | wall | 5 | 6.03 / 6.50 s | 9 roots rerun |
| same edit under `check --watch -fincremental --cache-dir <private>` | build-runner log | 6 | 0.07 / 0.09 s | first build 11.6-16.0 s; 38 processes, 6.40-6.51 GB RSS |
| `test-vams`, nothing changed, through `nix develop` | wall | 3 | 2.38 / 2.41 s | test binary cached, **test run reruns** |
| `test-vams`, nothing changed, stable env | wall | 1 | 0.67 s | run cached |
| `test-vams` after the tokenizer edit | wall | 3 | 5.02 / 5.77 s | compile 3 s, run 1 s |
| 8 light steps (`test-sema test-vams test-air test-std_sim test-std_kernels test-intern_pool test-link test-codegen`), nothing changed, through `nix develop` | wall | 3 | 10.13 / 10.51 s | all 8 runs rerun (std_kernels 9 s, link 6 s) |
| same, stable env | wall | 2 | 0.44 / 0.45 s | all cached |
| first build ever on this Zig: `check` with empty global and local caches | `/usr/bin/time` | 1 | 74.9 s (user 151 s), 1.16 GB | build runner (`maker`) compile ≈ 60 s of it; global cache +61 MB |
| second worktree, same commit, shared cache: `check` | wall | 1 | 9.86 s | 4 of 37 roots missed |
| two worktrees alternating `check` (one differs by a doc line in `src/InternPool.zig`) | wall | 4 | 4.83 / 5.32 s (8.59 s first) | 5 roots recompiled every time |
| `vera-next` exe, Debug, self-hosted, from an empty local cache | `--time-report` | 3 | 4.27 / 4.60 s, 0.60 GB | Sema 3.9-4.7 CPU-s |
| same with `-fnew-linker` | `--time-report` | 3 | 5.01 / 5.41 s | |
| same with `-fllvm` | `--time-report` | 2 | 25.1 / 25.9 s, 1.9 GB | LLVM emit 16-19 s |
| `vera-next --run` of `ch02_lexical/analog_statement_attributes.va`, fresh work dir | `/usr/bin/time` | 5 | 0.30 / 0.31 s, 165 MB | spawns one Debug `zig build-exe` |
| same, same work dir again | `/usr/bin/time` | 4 | 0.04 / 0.04 s | link's cache: no `zig` spawned |
| old `vera --run`, same fixture, fresh or reused dir | `/usr/bin/time` | 10 | 0.31 / 0.33 s | never cached (F5) |
| one `diff-codegen` library: 24 old devices, 1.05 MB text, ReleaseFast LLVM | `--time-report` | 3 | 1.38 / 1.94 s, 0.31 GB | LLVM emit 0.95-1.49 s |
| same, 34 new devices, 223 KB | `--time-report` | 3 | 1.73 / 1.78 s | |
| same, one device (40 KB or 6 KB) | `--time-report` | 6 | 0.29 / 0.32 s, 0.27 GB | fixed cost: 618 files of std and support modules |
| same 24 old devices, Debug self-hosted | `--time-report` | 3 | 0.48 / 0.49 s | |
| one batch with the 9.7 MB device (`b26`, 35 new devices), ReleaseFast LLVM | `/proc` sampled every 5 s | 1 | **1213 s, 4.93 GB peak** | another agent's `diff-codegen` |
| the 9.7 MB device alone: `-fno-emit-bin` / Debug self-hosted | `--time-report` | 1 each | 6.7 s / 18.8 s, 0.48 GB | |
| `diff-codegen` full runs, "build old, new" line | the step's summary, scratch logs | 5 | see F7 | |

## 2. Findings

### F1. `nix develop` makes every test Run step rerun

`nix develop` exports `NIX_BUILD_TOP`, `TMPDIR`, `TMP`, `TEMP` and `TEMPDIR` as a fresh
`mktemp -d` on every call (`nix print-dev-env`: `export NIX_BUILD_TOP="$(mktemp -d -t
nix-shell.XXXXXX)"`; two calls' `env` differ in exactly these five). `build/common.zig:175`
`testRun` calls `r.setEnvironmentVariable("CLICOLOR_FORCE", "true")`; the first such call
clones the build's whole environment into the step (`Z/lib/std/Build/Step/Run.zig:669`), and
the build runner hashes every key and value of a Run step's map into its cache key
(`Z/lib/compiler/Maker/Step/Run.zig:60-64`). So every `nix develop -c zig build test-<module>`
reruns the tests, though the binary is cached: 10.1-11.5 s for the eight light steps against
0.44 s with a stable environment, 2.4 s against 0.67 s for `test-vams`. A Run step that sets no
variable inherits the environment unhashed (the map is hashed only when present, `:61`). The
same clone carries the worktree's own path (`PWD`, `out`, `NIX_LDFLAGS`), so no test run is
ever shared between worktrees either. Other sites that clone: `build/vpi.zig:139,158,159,190,191`,
`build/runs.zig:51,52,108,151,152` (several also set `has_side_effects`, which reruns anyway).

### F2. `nix develop` itself costs about 1 s, not 4-6 s

0.85-1.12 s over 7 calls, and 0.70-1.00 s over 4 more after dirtying the tree. A no-op `check` is 1.83 s through
it and 0.81 s without it (same zig, same `ZIG_GLOBAL_CACHE_DIR`), so the wrapper is about 1.0 s
per call. The 4-6 s report was not reproduced; a cold flake evaluation (after a `flake.lock`
or `flake.nix` change) is the likely source. The cost that matters is F1's, not the startup.

### F3. Where a `check` goes: Sema, one thread per root, 38 times

Each of `check`'s 38 roots is its own `zig` process (`build/unit.zig:165`, `-fno-emit-bin`).
Compiled one at a time from an empty local cache, the roots sum to 71.7 s wall and, in CPU
seconds, parse 9.9, AstGen 32.4, **Sema 64.4**, codegen 0.5, link 0.6. The longest roots are
`tests/unit.zig` (5.79 s, Sema 5.40, 559 MB), `tests/suite.zig` as an exe (5.77 s), `src/main.zig`
(4.88 s), `src/next/Compilation.zig` tests (3.80 s); these set the cold `check`'s 9-11 s.
Within one compilation, AstGen runs as a parallel group (`Z/src/Zcu/PerThread.zig:164`) and
codegen per function on worker threads (`:2320`), but semantic analysis runs on the thread that
called `update` (`Z/src/Compilation.zig:4400-4402`). The time report agrees: for `vera-next`,
Sema 3.87 CPU-s against 3.97 s of real time in the declaration phase, and 2.2 CPU-s of codegen
overlapped with it. The LLVM backend does not take separate codegen threads at all
(`Z/src/target.zig:985-989`, `.stage2_llvm => false`). So a root's wall is its Sema.

### F4. Incremental compilation lives only inside one `--watch` process

`-fincremental` selects `CacheMode.incremental` (`Z/src/main.zig:3626`), whose output
directory is keyed on options and module paths, not contents (`Z/src/Compilation.zig:1348`,
the `.incremental` branch at `:2271`, the directory at `:2306`). The state is written
(`Compilation.saveState`, `:3574`, a `<root>.zcs` file, `:3804`) but nothing in the pinned
compiler reads a `.zcs` back: the only reuse is the in-memory state of a process that stays
alive, and the build runner keeps a compiler process alive only under `--watch` or the web UI
(`Z/lib/compiler/Maker/Step/Compile.zig:55`). Consequences:

- a plain `zig build -fincremental` is a full compile every time, with no whole-mode content
  check either; AGENTS.md's ban is right for speed as well as for the miscompilations;
- there is nothing on disk to share between worktrees, so a stable build-root path, bind
  mounts or a path-independent key cannot make it shareable; they would only make two watches
  write the same `o/<digest>` directory, which the private `--cache-dir` already prevents;
- the watch is fast (0.07-0.09 s per re-check) and heavy: `check --watch` keeps all 38 compiler
  processes resident, 6.40-6.51 GB in total, for as long as the agent works. Six agents each
  following AGENTS.md's edit loop need about 39 GB on a 31 GB machine.

### F5. VerA passes `-fincremental` to one-shot compiler children

`src/link/File.zig:373` adds `-fincremental` to every self-hosted library build (a Debug
`.so`/`.osdi`), and `src/zigbuild/argv.zig:183` (old, frozen) does the same. Each build is a
fresh child (`src/link/Queue.zig:61` spawns one per argv), so the incremental state is never
reused, and the flag turns off the whole-mode cache. Rebuilding the 24-device batch in Debug
with the inputs unchanged: 0.79-0.81 s with the flag, 0.09 s without (a cache hit); cold, 0.87-0.96 s
against 0.53-0.69 s (`--time-report`, n = 3 each). It also exposes these builds to the
miscompilations AGENTS.md keeps out of plain builds. (`link.File.cache_dir`, where set, sits
above this and hides it.) The old driver's `--run` passes `-femit-bin=<path>` without
`--listen`, which makes the CLI's cache mode `.none` (`Z/src/main.zig:3442-3450`, `:3622-3627`):
every old `vera --run` recompiles its testbench (0.31-0.36 s on a trivial fixture, Section 1),
while `vera-next --run` reuses it (0.04 s).

### F6. Across worktrees: what keys an entry, and where it leaks

A compile step's manifest is named by a digest of its flags and its input *paths*, not their
contents (`Z/lib/std/Build/Cache.zig:904`: "This is *not* hashing the contents"), with paths
made relative to five prefixes: cwd, the Zig lib dir, the local and global caches, the build
root (`Z/src/Compilation.zig:1976-1980`; module roots by `addModuleTableToCacheHash`, `:1649`).
The contents decide hit or miss only after the manifest is found, and the manifest holds one
entry. Two facts follow, both measured:

- **Ping-pong.** Worktrees on different branches share every manifest name; each miss
  rewrites it, so alternating builds evict each other. Two worktrees differing by one doc-comment
  line in `src/InternPool.zig`, alternating `check`: 8.59, 5.81, 4.83, 4.83 s, five roots
  recompiled each time, against 1.83 s for a no-op. Seen in the wild too: a `check` with no
  edit of mine reran four roots (4.68 s) because another worktree had built them in between.
  The losing entry's `o/` directory stays on disk.
- **Path leaks.** A second worktree at the *same* commit missed 4 of 37 `check` roots (9.86 s;
  cold is 9.1-11.0 s, so the shared cache saved nothing on wall). The four are the roots that
  import an options module holding absolute paths: `build/unit.zig:73` (`repo_root`),
  `:125-130` (`fixture_root`, `repo_root`, `work_root`, `contract`, `vpi_include`, `zig_exe`);
  the same pattern is in `build/rewrite.zig:44-45,83-84` and `build/rewrite_comp.zig:33-36`
  (`addOptionPath` of the emitted `vera`/`vera-next`, a path under the worktree's own
  `.zig-cache` symlink). `checkoutWorkDir` (`build/common.zig:236-237`) is per checkout on
  purpose and only reaches Run arguments.

The shared local cache is 132 GB (5,615 manifests, 4,407 `o/` directories); nothing collects it.

### F7. `diff-codegen`: one giant device, no library cache, sides built in turn

The step's own summary line, from full runs in the scratch logs:

| Log (date) | Fixtures built | build old | build new |
|---|---|---|---|
| `rewrite.log` (11-04) | 853 | 97,064 ms | 96,975 ms |
| `gate64.log` (11-10 18:13) | 1,226 | 904,299 ms | 1,576,557 ms |
| `dcg.log` (11-10 23:20) | 1,248 | 995,466 ms | 1,675,786 ms |
| `dcg3.log` (11-11 01:49) | 1,258 | 846,680 ms | 1,486,825 ms |
| `final_test.log` (11-11 09:46) | 1,266 | 1,200,645 ms | 1,535,828 ms |

- **The giant.** The new device of `verilog-a/ch05_analog_behavior/vera_timepoint_held_history.va`
  is 9,725,485 B and 139,728 lines (the old one is 65,780 B). One generic function, `core`, runs
  from line 4,150 to 55,485, over held-history cells unrolled into scalar fields
  (`ht__held__27: f64`, ...). Its batch library (35 new devices) built in 1213 s at 4.93 GB peak;
  the other 34 devices alone build in 1.7-2.5 s; the giant alone is 6.7 s through Sema and 18.8 s
  as a Debug self-hosted build. So, if the logged runs carried the same device, about 1200 s of
  their ~1,500 s new side is LLVM optimising one function, and 34 small devices wait on it. The new side's text, 69 MB against a median of
  5.4 KB per device, says there are other large ones.
- **No library cache.** `tests/differential/codegen.zig:299` builds each side with
  `link.File{ ..., .optimize = .fast, .backend = .llvm, .split = .whole }` and no `cache_dir`,
  in a work directory deleted after the run (`:195`, `:252`). `link.File.cache_dir`
  (`src/link/File.zig:81`) already keys a finished library on the compiler, every option, every
  byte of the device and the support modules' files, with module directories as prefixes so
  checkouts share entries (`:463-471`). The old pipeline is frozen (docs/rewrite/README.md rule 2),
  so the old side's 847-1201 s is the same work every run.
- **Batches are cut by position** (`:190`, 24 at a time over the ready list): one fixture
  entering or leaving the list shifts every later batch, so a per-batch cache would need stable
  boundaries to keep its hits.
- **Sides in turn.** The queue has `jobs = 2` slots (`:57`, `:186`), but each batch builds old,
  then new, then evaluates; one child at a time. A batch that fails is retried with the culprit
  dropped, and each retry rebuilds both sides (the `attempt` loop at `:270`; `:303` sums every try).
- **Not explained.** A 24-device old batch builds in 1.4-2.0 s, so ~53 batches account for about
  100 s, yet the old side reports 847-1201 s. Retries, large old devices or load could each
  explain it; the step prints no per-batch time, so it cannot be told from the logs.

### F8. Backends and linkers

- Debug on x86_64 self-hosted (the default, `Z/src/Compilation/Config.zig:367` prefers LLVM
  only for release; `src/link/Zig.zig:45` `Backend.auto` mirrors it) is right: `vera-next` in
  4.6 s and 0.60 GB against 25.9 s and 1.9 GB with `-fllvm`.
- The new ELF linker (`-fnew-linker`) gave no gain on `vera-next` (5.41 against 4.60 s median;
  link CPU 1.9-2.7 s against 1.1-1.4 s).
- For `-Ofast` device libraries the link is 0.001-0.034 s of a 1.4-2.0 s build: LLD 1.38/1.94 s,
  the self-hosted ELF linker (`-fno-lld`) 1.38/1.39 s, `-fnew-linker` 1.39/1.39 s (min/median,
  n = 3); the spread is LLVM emission (0.95-1.49 s), so linker choice is inside noise.
- mold does not apply: the compiler links with LLD in process or its own linkers
  (`Config.zig`'s `use_lld` / `use_new_linker`), with no external-linker hook for Zig code.

### F9. Memory

Sampled read-only every 0.5 s over four minutes of other agents' corpus steps, and from the
batch rebuilds:

| Process | Peak RSS |
|---|---|
| a `diff-codegen` library build, typical batch | 0.27-0.36 GB |
| the same, the two largest batches seen (the second holds the 9.7 MB device) | 2.68 GB, 4.93 GB |
| a step's own binary (`diff-codegen`, `diff-lower`, `vera-suite`) | 0.02, 0.08, 0.57 GB |
| a test binary's compile (`zig test`), a `check` root | 0.14-0.56 GB |
| the build runner, the configurer | 0.06-0.07, 0.11-0.17 GB |
| one agent's `check --watch -fincremental` (38 processes) | 6.40-6.51 GB |

A corpus step's peak is its largest compiler child; the 7.5 GB slot budget matches a giant
device's batch plus the step's own compiles. Outside the giants a corpus step stayed under 1 GB
in the window sampled. The largest steady consumer is the edit loop (F4), not the corpus steps.

### F10. Toolchain and the first build

The Nix Zig is the ziglang.org release build (a static ELF with no `PT_INTERP`, 186 MB,
repackaged by `zig-overlay`), so there is no faster compiler build to take. The first build on a
new Zig store path is 74.9 s, of which about 60 s compiles the build runner into the global
cache (its `maker` landed 60 s after `compiler_rt`); the flake's `shellHook` already gives each
store path its own `ZIG_GLOBAL_CACHE_DIR` (1.7 GB today). It is paid once per Zig per machine.

## 3. Recommendations, ranked by gain over cost

**R1. Stop hashing the environment into test runs.** `build/common.zig:175`: drop
`setEnvironmentVariable("CLICOLOR_FORCE", "true")` and pass colour as an argument
`tools/zrunner.zig` reads (`r.addArg("--color=on")`; zrunner today reads `CLICOLOR_FORCE` at
`:245`). With no variable set, the Run step's map stays null and is not hashed (F1). For the
sites that must set a variable (`build/vpi.zig`, `build/runs.zig`), one helper in `common.zig`
removes `NIX_BUILD_TOP TMPDIR TMP TEMP TEMPDIR` after setting.
Gain (measured): a no-op light call 10.1-11.5 s to 0.44 s; `test-vams` 2.4 to 0.67 s; every
`test` merge-gate run skips the unit tests whose binary did not change (std_kernels 9 s, link
6 s, ... each). With the env gone, test runs also hit across worktrees when the binary matches.
Cost: about 15 lines, one hour. Risk: a test that reads an inherited variable at run time now
caches across a change of it; none found (zrunner reads only colour variables).
Oracle: "a no-op build is a no-op": a second `nix develop -c zig build test-vams --summary all`
prints `run test vams cached`; red today.

**R2. Give `diff-codegen` the library cache, with stable batch boundaries.**
`tests/differential/codegen.zig:299`: set `.cache_dir` to a machine-wide directory per Zig (a
`-Dcodegen-cache` option defaulting to `<global cache>/vera-codegen`), and cut batches where
`hash(rel) % 24 == 0` (at most 48 per batch) instead of every 24th ready fixture, so a fixture
joining or leaving the list changes one batch's key. Print hits and misses in the summary.
Gain: on a rerun with the same ready list the old side builds nothing: 847-1201 s saved per
run (F7), and the new side rebuilds only batches whose text changed; the giant's 1213 s is paid
once per change of its own text. Disk: about 0.2 MB per library (`libcg0o.1.so` was 210 KB),
about 22 MB per distinct run.
Cost: about 20 lines. Risk: a stale hit if an input is outside the key; `cacheOpen` keys the
compiler, every option, every device byte and each support module's read files
(`src/link/File.zig:463-471`), so `dyn.zig` and `contract.zig` edits miss as they should. It
returns null (silently uncached) past five module directories (`cache_dirs_max`, `:149`), and
this step uses exactly five (lib, lib/std, Gompute, codegen/, the batch dir): the printed hit
count shows a fallback. Oracle: two consecutive runs print the same summary except build ms and
the hit count (all hits the second time); touching `dyn.zig` turns every batch into a miss.

**R3. Build a giant device alone, name the slowest builds, and fix the giant at its source.**
In `runBatch`, a device whose text exceeds `link.split_min_bytes` (768 KiB) goes to a batch of
its own, so its LLVM time no longer holds 34 neighbours; the summary names the five slowest
library builds (fixture, bytes, ms), which would have found this one without `ps`. The source
fix belongs to the codegen plan: `vera_timepoint_held_history`'s 51,000-line `core` comes from
unrolling held-history cells into scalar fields; arrays (`[n]f64`) would keep the function
small. Gain: with R2, the giant costs nothing on runs that do not change it; with the codegen
fix, about 1200 s off every run that does (estimate: the 34 neighbours build in 1.7-2.5 s).
Cost: about 15 lines here; the codegen change is that plan's. Risk: none for the oracle (same
devices, same mode). Oracle: the per-build timing line; F7's table recomputed.

**R4. Watch narrow roots in the edit loop.** `build/unit.zig`: a `check-<module>` step per
module root (`-fno-emit-bin`, the same loop as `test-<module>`), and AGENTS.md's edit loop
becomes `zig build check-<module> ... --watch -fincremental --cache-dir .zig-cache-watch` over
the modules being edited; the full `check` stays the pre-commit plain build.
Gain (measured per root): a watched root holds 0.14-0.56 GB instead of 6.4-6.5 GB for all 38;
three roots per agent is about 1 GB, six agents about 6 GB instead of 39 GB. The re-check stays
0.07-0.09 s and the first build drops from 11.6-16.0 s to the roots watched.
Cost: about 10 lines and the AGENTS.md text. Risk: an edit that breaks a root nobody watches
shows at the plain `check`, which already gates. Oracle: the tree-RSS sampler on one agent's
watch; `check` stays the gate.

**R5. Take absolute paths out of compiled-in options.** `build/unit.zig:73,125-130`,
`build/rewrite.zig:44-45,83-84`, `build/rewrite_comp.zig:33-36`: hand the paths to the Run step
(`addArg`, `addFileArg`, `addDirectoryArg`) and read them from argv in the test binaries, so a
binary built from the same sources in two worktrees is the same binary.
Gain: a fresh worktree's first `check` at a commit another worktree built: 9.86 s to about
1.8 s (the four missed roots, F6); each corpus test binary likewise compiles once per source
state instead of once per worktree (not measured). There were about 40 worktrees today.
Cost: about 10 sites plus the binaries' option reads; half a day. Risk: low. Oracle: a second
worktree's `check` at the same commit reruns 0 compile steps (`--summary all`).

**R6. Collect the shared cache.** 132 GB, unowned, on a volume 96 % full (F6). A collector
script takes both `~/.cache/vera-heavy.{0,1}.lock` (stop-the-world: no corpus step runs) and
deletes `o/` entries and manifests not used in N days, keeping the cache under a byte budget
(the `long-term-garbage-collection` skill's shape). Gain: no speed; it removes the failure
every agent hits when the disk fills. Cost: about 30 lines. Risk: a light build running during
collection (light steps take no slot); collect while no `zig` runs. Oracle: the size after
collection is under budget and the gate stays green.

**R7. Drop `-fincremental` from one-shot library children.** `src/link/File.zig:373`: pass it
only to a child that receives more than one update (none does today). Leave the frozen
`src/zigbuild/argv.zig:183` alone. Gain (measured): an unchanged Debug library rebuild 0.80 s
to 0.09 s, cold 0.87 to about 0.59 s, and no incremental miscompilation in device builds. It
touches only Debug `.so`/`.osdi` builds (the default is `.fast`), so the day-to-day gain is
small; the correctness exposure is the reason. Cost: one line and its comment. Risk: `diff-link`
compares outcomes, not argv (`tests/differential/link.zig:1-14`), so it is unaffected. Oracle:
`diff-link` and `test-link` green; the argv no longer carries the flag.

**R8. Build both sides of a batch at once.** `runBatch` hands both sides' commands to the queue
it already has (`jobs = 2`) and pipelines the next batch's build with this batch's evaluation.
Gain (estimate): a typical batch from about 3.5 s (1.4-2.0 + 1.7-2.5 s) to about 2.5 s, about
50-100 s per full run; most of it disappears under R2 anyway. Cost: a restructure of `runBatch`.
Risk: memory, two children at 0.3 GB typical, 4.9 + 0.3 GB with a giant; R3 isolates those.
Oracle: the summary is identical to the serial run's except build ms.

## 4. What not to do, and why

- **Split the compiler into objects or static libraries per module.** Each object re-analyses
  what it imports; `check` already shows the price: 38 roots, 107 CPU-s summed, against 5.8 s
  for the largest. Comptime generics and inlining stop at the seam, and an `export` (C-ABI) seam
  cannot carry slices, error unions or tagged unions. The modules everything imports
  (`intern_pool`, `vams`, `air`) are where edits land, and an edit there invalidates every
  object anyway. The edit loop already re-checks in 0.08 s (F4). AGENTS.md's "cut the artifact
  graph where edits land" pays on generated units (devices, R2/R3), where the graph breaks it
  today: `diff-codegen` puts 24-35 generated devices in one uncached unit.
- **Use LLVM in Debug** (5.6 times slower, 3.2 times the memory, F8), or change linkers: the
  link is under 2 % of a device build and the new ELF linker is not faster on `vera-next`.
- **Run plain builds with `-fincremental`** to "reuse state": nothing reuses it outside a live
  process, and it disables the whole-mode cache (F4, F5).
- **Try to share incremental state across worktrees** (stable paths, bind mounts, a
  path-independent key): there is no state on disk to share; a shared key would only make two
  watches overwrite one directory.
- **Lower `diff-codegen`'s optimise mode for speed** before the oracle question is answered
  (Q3): the oracle compares devices built the way users get them.
- **Skip `nix develop` in `tools/build-slot.sh`** with a cached environment: about 1 s per call,
  against the risk of a stale toolchain or a missing variable; R1 removes the cost that matters.
- **Rebuild Zig or change how it is built**: the pinned binary is already the release build.

## 5. What carries over to ESPice

Read from ESPice's `build.zig`, `build.zig.zon`, `flake.nix` and `AGENTS.md` only; nothing was
built there. ESPice pins VerA at 0bc0092b (v0.23.0) and Gompute 2.0.0 (`build.zig.zon`), builds
VerA's `vera` at `.fast` for the host (`build.zig:20`) and runs it per model (`:50-70`), and
links one object per model (`:97`). It runs `nix develop .#ci -c` (AGENTS.md `:296`). Not measured: `build.zig:20` builds VerA's
`vera` ReleaseFast with LLVM for the host, once per VerA pin bump; `vera-next` alone takes 25 s
with LLVM even in Debug here, so expect minutes per bump, cached after that.

| Rec | ESPice | Why |
|---|---|---|
| R1 env | Applies with a change: `build.zig:221,224,301,306,523` | Its Run steps set `ZIG` and `ESPICE_PERF`, which clones the environment, and `nix develop .#ci` gives each call a fresh `TMPDIR` the same way; those test runs never cache. Remove the five per-call keys after setting, or pass the values as arguments. |
| R2 library cache | Does not apply | `diff-codegen` is VerA's oracle. ESPice already keys each model's generation as a Run step with declared inputs (`build.zig:50-70`). |
| R3 giant device | Applies through VerA | A model whose generated text is huge costs its own object only (one object per model, `:97`), but the codegen fix (held cells as arrays) reaches ESPice when it bumps its VerA pin. |
| R4 narrow watch | Applies with a change: `build.zig:213` and AGENTS.md `:297` | Its `check` also type-checks every test root under one watch; per-root `check-<root>` steps give the same memory cut. Its AGENTS.md notes `-fincremental` segfaults on roots that import the device module, so those roots get a plain `--watch`. Memory not measured there. |
| R5 paths in options | Applies with a change, to test roots only | `build.zig:25-29` compiles absolute paths (`contract_path`, `dyn_path`, `device_abi_path`, `core_path`, `gompute_path`) into an options module; a test root that imports it misses in every other worktree. The shipped `espice` needs them at run time (its runtime `.hdl` loader), so keep them there. |
| R6 collect the cache | Applies as is | Its AGENTS.md (`:110-111`) also symlinks every worktree's `.zig-cache` to one, and nothing collects it. |
| R7 `-fincremental` in children | Does not apply | ESPice's own runtime builds pass no `-fincremental` (`src/device/hdl_gpu.zig`); it reaches VerA's `link` only through `vera --emit-zig --check`, a type check. |
| R8 both sides at once | Does not apply | VerA's oracle only. |
| F2 nix startup | Applies as is | Same wrapper, same ~1 s; not worth removing. |
| F6 ping-pong | Applies as is | Same cache, same one-manifest-per-root rule; Q4's decision carries over. |
| F8 backends | Applies as is | `build.zig:16` (`use_llvm = optimize != .debug`) already builds Debug self-hosted; `build.zig` defaults to ReleaseFast, so day-to-day builds must pass `-Doptimize=Debug` (its AGENTS.md says so). |
| F10 toolchain | Applies as is | `flake.nix:147` already gives each Zig store path its own global cache; ESPice's Zig is a different store path, so it pays its own ~60 s build-runner compile once. |

## 6. What was not measured, and why

- **A corpus step end to end under the sampler.** Both slots were held by five other agents'
  corpus steps for the whole session; a filtered `diff-codegen` of mine waited 11 minutes without
  a slot and was withdrawn so the queue served the work agents. Corpus numbers come from earlier
  full-run logs, read-only sampling of running steps and the hand-built batch (Section 1).
- **Why the old side grew from 97 s (11-04) to 847-1201 s (11-10)**: needs a per-batch timing
  line (R3) on one full run.
- **The cross-worktree hit rate of corpus steps**, and their test binaries' compile times: one
  corpus step at a time made a paired measurement too long for the session.
- **The 4-6 s `nix develop` report**: not reproduced (0.70-1.12 s over 11 calls).
- **ESPice**: read, never built, as asked.

## Open questions

**Q1. R1's shape: colour as a zrunner argument (no environment clone), or keep the variable and
remove `nix develop`'s five per-call keys after every set?**
The argument removes the hash entirely, so test runs also hit across worktrees; the removal list
is shorter to write but must track what `nix develop` exports.
Recommendation: the argument for `testRun`; the removal helper for the few steps that need a
real variable.
Decision: as recommended (user, 2026-11-11).

**Q2. Where does `diff-codegen`'s library cache live, and who collects it?**
Recommendation: under the per-store-path global cache (`<ZIG_GLOBAL_CACHE_DIR>/vera-codegen`),
so a Zig bump starts clean and checkouts share it; R6's collector owns it.
Decision: as recommended (user, 2026-11-11).

**Q3. Should `diff-codegen` ever build a device below ReleaseFast/LLVM?** The giant builds in
18.8 s Debug against 1213 s ReleaseFast. The oracle compares devices as users build them, and
Debug adds safety checks and ignores `.optimized` float mode, so the versioned units' box would
go untested.
Recommendation: no; keep ReleaseFast everywhere, let R2 make the giant a once-per-change cost and
the codegen plan fix its size. Revisit only with one full run built both ways and compared bit
for bit.
Decision: as recommended (user, 2026-11-11).

**Q4. The shared `.zig-cache` symlink: keep it, or give light steps a private local cache?**
Shared saves a fresh worktree's first builds (about 10 s for `check`; corpus binaries more) but
ping-pongs between branches (4.8-8.6 s per alternation of `check`) and grows without owner
(132 GB). A private cache costs one cold build per worktree and dies with the worktree.
Recommendation: R5 first (it is what makes the shared cache hit at all); then try a private
`--cache-dir` for light steps in `tools/build-slot.sh` for one day, counting reruns per no-op
call both ways, and decide on the count.
Decision: as recommended (user, 2026-11-11). R6's collector must never leave a manifest that hits on a deleted `o/` entry: the pinned build runner populates paths from the hit digest without checking they exist (`lib/compiler/Maker/Step/Run.zig:571`), and a manifest does not name its output dir. On 2026-11-11 every `o/` entry was under a day old (the dir was created 2026-11-10 16:28), so an age trim had nothing to take; the lead held the trim the user approved until R6 exists.

**Q5. Change AGENTS.md's edit loop to per-module `check-<module>` watches (R4)?**
Recommendation: yes; the full `check` watch is the one practice that can run the machine out of
memory by itself.
Decision: as recommended (user, 2026-11-11). The AGENTS.md edit-loop text changes with R4.

**Q6. A third build slot?**
Recommendation: not yet. Outside giant-device batches the sampled corpus steps stayed under 1 GB,
but the window was four minutes and missed the test-binary compile phases. Land R2, R3 and R4,
sample a day of peaks, then decide.
Decision: as recommended (user, 2026-11-11).

**Q7. Split `tests/unit.zig` (the longest `check` root, 5.8 s, every module) into per-namespace
roots?**
Recommendation: no for now. The merged root is AGENTS.md's design; with R4 nobody watches it, and
the plain `check` runs its roots in parallel anyway. Revisit if `check`'s wall after an edit
matters once R1 to R5 are in.
Decision: as recommended (user, 2026-11-11).

**Q8. Drop `-fincremental` from `link`'s one-shot children (R7), leaving the frozen
`zigbuild` as it is?**
Recommendation: yes; the flag buys nothing in a one-shot child and brings the miscompilation
class into device builds.
Decision: as recommended (user, 2026-11-11).
