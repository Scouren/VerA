# link: the zig runner, the cache, the task queue

Read `README.md` first. You own `src/link.zig` (+ `src/link/`: `Zig.zig` the argv
and device tree, `Server.zig` the `zig --listen` client),
`tests/differential/link.zig` and `tests/differential/link.xfail`, and the `link`
row you add to `build/common.zig`'s `module_specs` (imports: `contract`, `dynlib`
for the tests that load a library) plus its `diff-link` row in
`build/rewrite.zig`.

## What it is

Zig's `src/link.zig` + `src/link/Queue.zig` for a compiler whose backends emit
Zig source: generated text in, a library / object / executable out, every `zig`
child run through one bounded queue, every artifact keyed in `std.Build.Cache`.
It replaces `src/zigbuild/` (2,951 lines; target about 1,550: `lib/TODO.md`
Appendix A.5) and keeps its observable behaviour.

- `link.File { kind: .so | .osdi | .exe | .check, work_dir, cache, modules, objects }`
  and `flush(queue) !Artifact` (Z/link.zig:397, Z/link/C.zig:733 flush).
- `link.Task = union(enum) { write_tree, build_obj: { part, key }, build_kernels, link, check }`
  (Z/link.zig:1505 `ZcuTask`, Z/link/Queue.zig): a split device is one
  `build_obj` per `contract.DevicePart` and setup chunk, then `link`.
- `Queue`: at most `jobs` children alive; the caller owns the queue (later
  `Compilation`); the stage never spawns on its own.
- One way to run zig: `Server` (`--listen=-`, `std.zig.Server` messages, an
  `ErrorBundle` on failure), one argv builder. The old code has three
  (`server.zig`, `exe.zig`'s `std.process.run`, `check.zig`'s spawn + watchdog)
  and two argv heads.
- `std.Build.Cache` replaces `artifact_cache.zig` (a 64-bit Wyhash that re-reads
  every module file): hash the zig exe, optimize, backend, target and the part's
  text closure; `addFilePath` the support modules (Z/Compilation.zig:5434
  `updateCObject` is the pattern).
- Per-unit objects are impossible (units are generic over the host's `comptime S`;
  `lib/TODO.md` §7); the cut is per device part.

## The oracle: `zig build diff-link`

The old `zigbuild` and the new `link` build the same inputs: the
`tests/unit/zigbuild_tests.zig` devices and the `tests/conformance/tests/vera/osdi`
fixtures (emit their text with the installed old `vera --emit-zig`, or through
the old `zigbuild.buildLibrary` path), at `jobs` 1 and N. The libraries' exported
symbol tables are equal, and the new one's bytes equal at 1 and N jobs; a
compile error gives an `ErrorBundle` with the same messages. Port
`tests/unit/zigbuild_tests.zig` as spec examples.

## Done when

`zig build test-link`, `zig build diff-link`, `zig build check` pass; the report
names the artifacts compared and every `link.xfail` line.
