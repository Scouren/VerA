# std_kernels: the kernels shipped once, with Gompute's math

Read `README.md` first, then `lib/TODO.md` §7 ("Kernels ship once, like
compiler_rt"), §11.4, §11.8, and Appendix maps 5 and 7 (A.5 findings 1-4 and
19; A.7: every `lib/kernels` and `lib/contract/gm*` file, who uses it). You own
`lib/std/kernels.zig` + `lib/std/kernels/` (a new module `std_kernels`, row in
`build/common.zig` after `contract`), the Gompute dependency in `build.zig.zon`
(and its Nix packaging in `flake.nix` if the Nix build needs it),
`tests/differential/kernels.zig`, `tests/differential/kernels.xfail`, and the
`diff-kernels` row in `build/rewrite.zig`.

## What it is

Today the device kernels are TEXT: `lib/kernels/root.zig` and
`src/codegen/device/codegen/kernel_text*.zig` splice ~31-235 KB of Zig into every
generated device (71% of a diode's text). Zig ships `compiler_rt` once and links
it; VerA will do the same: `std_kernels` is a real, type-checked module a device
`@import`s (installed beside `contract/` as `share/vera/kernels/`), and
`kernels.fold` calls the same functions a device runs, so the fold oracle IS the
kernel.

- Port `lib/kernels/*` (the runtime kernels: str, file, table, filter, limit, hist,
  ops, timer, wide, rng, printf/str_real (now the contract's), fmt, Integer, fold)
  and `codegen/device/codegen/kernel_text/{math,family,ac,storage}.zig` (string
  literals today) into real Zig under `lib/std/kernels/`, one file per data domain
  (map 7 finding 12). `fn Family(comptime n_u: u16) type` replaces the text
  widening (`prelude.zig` `wideText`).
- **Gompute 2.0.0 replaces `lib/contract/gm`** (§11.8): `git+https://github.com/OmarSiwy/Gompute`
  at tag `v2.0.0` (commit `70b722d`; a local checkout is at
  `~/Documents/Projects/Gompute`, read it), pinned by commit and content hash in
  `build.zig.zon` (`zig fetch --save` once; the repository is public, so no
  credentials). `gompute.math` gives the device-safe `exp`, `log`, `pow`, ... that
  `gm` hand-ports today (fma-free, identical on host, NVPTX and AMDGCN).
- The old pipeline keeps `lib/kernels` and `lib/contract/gm` until the switch-over;
  the new codegen will import `std_kernels`.

## The oracle: `zig build diff-kernels`

1. **Every kernel against its old self:** for each function `lib/kernels` exposes to
   devices or folds, the new `std_kernels` function and the old one agree bit for bit
   over the specials and 10^5 seeded inputs each (string kernels: byte-equal text).
2. **Gompute against gm:** for each function `gm` provides, `gompute.math` agrees
   with `gm` bit for bit, or within both libraries' documented ulps with the
   difference listed by name in `kernels.xfail` and measured (max ulps seen); also
   against a high-precision reference (f128 or the 60-digit model rw-ir used for
   `diff-air`) so a disagreement says which side is wrong.
3. **Targets:** `std_kernels` builds for x86_64, aarch64, NVPTX and AMDGCN (`zig
   build-obj -target ...`), and its math is fma-free on each (no `fma` in the
   emitted code; probe like `tests/codegen_probe.zig`).

## Done when

`zig build test-std_kernels`, `diff-kernels`, `check`, `test-unit` pass; `nix
build` (or the flake's package) still builds offline after the pin; the report
names functions and inputs compared, every `kernels.xfail` line with its measured
ulps, the Gompute pin (commit + hash), and the line counts.
