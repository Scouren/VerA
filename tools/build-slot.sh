#!/usr/bin/env bash
# Run `zig build` for one worktree under the machine-wide build slots (AGENTS.md, Building with
# many agents). A corpus step (diff-*, rewrite, test-comp, test-unit, bench-*, suite, ...) peaks
# near 7.5 GB and takes one of two slots, at -j2 unless the caller passes -j. `check`, `check-<module>` and
# `test-<module>` (1-2 GB) run at once. Usage: tools/build-slot.sh <worktree> <zig build args...>
set -u
wt=$1; shift
cd "$wt" || exit 2
light=1 jobs=-j2
for a in "$@"; do
  case $a in
    -j*) jobs= ;;
    -*|check|check-*|test-sema|test-vams|test-air|test-std_sim|test-std_kernels|test-intern_pool|test-link|test-codegen) ;;
    *) light=0 ;;
  esac
done
if [ $light = 1 ]; then nix develop -c zig build "$@"; exit $?; fi
# A corpus step reads tests/conformance, which a worktree symlinks to the main checkout's: a list
# graded against any other suite commit than the one HEAD pins is graded against other fixtures.
read -r mode _ pin _ < <(git ls-tree HEAD tests/conformance)
have=$(git -C tests/conformance rev-parse HEAD 2>/dev/null)
if [ "${mode:-}" != 160000 ] || [ "${pin:-}" != "$have" ]; then
  echo "build-slot: tests/conformance is at ${have:-nothing}, HEAD pins ${pin:-no submodule} (mode ${mode:-none})" >&2
  exit 2
fi
while true; do
  for s in 0 1; do
    exec {fd}>"$HOME/.cache/vera-heavy.$s.lock"
    if flock -n "$fd"; then
      nix develop -c zig build $jobs "$@"
      code=$?
      # R6 (research/builds.md): checked after each slot run, while this
      # slot is still held, so cache-budget.sh can try the other one for a
      # stop-the-world rotation. gcache empty (no nix develop, or the
      # variable unset) just skips the global cache and vera-codegen.
      gcache=$(nix develop -c sh -c 'printf %s "$ZIG_GLOBAL_CACHE_DIR"' 2>/dev/null)
      tools/cache-budget.sh "$s" "$HOME/.cache" "$(readlink -f .zig-cache 2>/dev/null || printf %s .zig-cache)" "$gcache"
      exit $code
    fi
    exec {fd}>&-
  done
  sleep 10
done
