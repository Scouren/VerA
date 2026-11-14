#!/usr/bin/env bash
# R6 (research/builds.md): the collector build-slot.sh calls after every
# corpus step. Three caches, two policies:
#
# - `.zig-cache` (the one every worktree symlinks to) and the global Zig
#   cache (`ZIG_GLOBAL_CACHE_DIR`): no entry inside either is safe to name
#   from outside Zig's own cache code (long-term-garbage-collection's
#   zig.md: "the collector owns every Zig cache" -- there is no native GC
#   yet), so over budget means a whole-cache rotation: renamed aside (same
#   filesystem, so it is instant) and deleted in the background.
#
#   That is stop-the-world, and holding both build-slot.sh slots is not
#   enough: `check` and `test-<module>` run without a slot, so `busy` also
#   waits out every `zig`/`maker` process whose cwd is under the checkout
#   or a worktree before the `mv`. Either guard failing just skips
#   rotation this round; the next slot run checks again.
# - `$ZIG_GLOBAL_CACHE_DIR/vera-codegen` (R2's diff-codegen library cache):
#   its entries are content-addressed library builds behind `link.File`'s
#   own `cache_dir`, and a flush that finds one gone heals it instead of
#   failing (R2b), so evicting the oldest `o/<digest>` entries needs
#   neither a slot nor `busy`.
#
# Usage: tools/cache-budget.sh <held slot 0|1> <lock dir> <.zig-cache path>
#   [global Zig cache path]
#        tools/cache-budget.sh selftest   (the script's own oracle, in `test`)
# The global cache path is optional (build-slot.sh may not be able to read
# `ZIG_GLOBAL_CACHE_DIR`, e.g. outside `nix develop`); when it is empty,
# the global cache and vera-codegen are left unchecked.
set -u
# The oracle: scratch trees, scratch locks, small budgets. vera-codegen is
# moved only under both guards: with the other slot held, a read-only global
# cache must see no `mv` at all (the park R6 first did before the guards).
if [ "${1:-}" = selftest ]; then
  T=$(mktemp -d) || exit 1
  fail=0
  setup() {
    rm -rf "$T/locks" "$T/root" "$T/g"*
    mkdir -p "$T/locks" "$T/root/.zig-cache" "$T/g/vera-codegen/o/a" "$T/g/o/x"
    head -c 4096 /dev/zero > "$T/g/o/x/f"
    echo keep > "$T/g/vera-codegen/o/a/f"
  }
  run() { bash "$0" 0 "$T/locks" "$T/root/.zig-cache" "$T/g"; }
  setup
  exec {other}>"$T/locks/vera-heavy.1.lock"
  flock -n "$other"
  chmod a-w "$T/g"
  err=$(VERA_BUDGET_GLOBAL_CACHE=1 run 2>&1 >/dev/null)
  chmod u+w "$T/g"
  exec {other}>&-
  [ -z "$err" ] || { echo "FAIL: touched the global cache while the other slot ran: $err" >&2; fail=1; }
  setup
  VERA_BUDGET_GLOBAL_CACHE=1 run || fail=1
  [ "$(cat "$T/g/vera-codegen/o/a/f" 2>/dev/null)" = keep ] || { echo "FAIL: rotation lost vera-codegen" >&2; fail=1; }
  [ ! -e "$T/g/o/x/f" ] || { echo "FAIL: over budget, not rotated" >&2; fail=1; }
  setup
  run || fail=1
  [ -e "$T/g/o/x/f" ] && [ -e "$T/g/vera-codegen/o/a/f" ] || { echo "FAIL: under budget, changed" >&2; fail=1; }
  rm -rf "$T"
  exit $fail
fi
held=${1:-}
lock_dir=${2:-}
zig_cache=${3:-}
global_cache=${4:-}
if [ -z "$held" ] || [ -z "$lock_dir" ] || [ -z "$zig_cache" ]; then
  echo "usage: tools/cache-budget.sh <held slot 0|1> <lock dir> <.zig-cache path> [global cache path]" >&2
  exit 2
fi
# The checkout root a worktree's `.zig-cache` symlinks to; worktrees nest
# under it, so one cwd prefix check covers the checkout and every worktree.
root=$(dirname "$zig_cache")

# Named capacities (bytes). .zig-cache's 80 GiB came from the lead (a full
# gate from an empty cache, so one gate's own footprint never triggers a
# rotation); global and vera-codegen are starting points, not fit to a
# measured growth curve. Retune here, never by hand on the box. The
# VERA_BUDGET_* overrides exist only so a scratch-cache test can use a
# small, fast-to-build tree instead of real-sized dummy data; build-slot.sh
# never sets them.
budget_zig_cache=${VERA_BUDGET_ZIG_CACHE:-$((80 * 1024 * 1024 * 1024))}
budget_global_cache=${VERA_BUDGET_GLOBAL_CACHE:-$((20 * 1024 * 1024 * 1024))}
budget_codegen=${VERA_BUDGET_CODEGEN:-$((10 * 1024 * 1024 * 1024))}

du_bytes() {
  du -sb "$1" 2>/dev/null | cut -f1
}

# True while a `zig` or `maker` process has its cwd under `root`: a light
# step (`check`, `test-<module>`) runs without a slot, so the two slots
# alone do not prove nothing is reading or writing the cache.
busy() {
  for p in /proc/[0-9]*; do
    exe=$(readlink "$p/exe" 2>/dev/null) || continue
    case $exe in
    */zig | */maker) ;;
    *) continue ;;
    esac
    cwd=$(readlink "$p/cwd" 2>/dev/null) || continue
    case $cwd in
    "$root" | "$root"/*) return 0 ;;
    esac
  done
  return 1
}

# Rotates `path` aside and deletes it in the background: only while also
# holding the slot `held` did not already hold, and only while `busy`
# reports every light step done. Does nothing under budget, and does
# nothing (this round, skip and retry next time) when either guard fails.
# `keep`, a subdirectory name, is left out of the size and survives the
# rotation: it is moved out and back only under both guards, never while a
# build on the other slot could be using it.
rotate_if_over() {
  path=$1
  budget=$2
  keep=${3:-}
  [ -d "$path" ] || return 0
  size=$(du -sb ${keep:+--exclude="$keep"} "$path" 2>/dev/null | cut -f1)
  [ -n "$size" ] && [ "$size" -gt "$budget" ] || return 0
  other=$((1 - held))
  exec {ofd}>"$lock_dir/vera-heavy.$other.lock"
  if ! flock -n "$ofd"; then
    exec {ofd}>&-
    return 0
  fi
  if busy; then
    exec {ofd}>&-
    return 0
  fi
  aside="$path.evicted.$$"
  if [ -n "$keep" ] && [ -d "$path/$keep" ]; then
    mv "$path/$keep" "$path.$keep.$$"
    mv "$path" "$aside"
    mkdir -p "$path"
    mv "$path.$keep.$$" "$path/$keep"
  else
    mv "$path" "$aside"
  fi
  exec {ofd}>&-
  nohup rm -rf "$aside" >/dev/null 2>&1 &
  disown
}

# Deletes the oldest `o/<digest>` entries under `codegen_dir` until it is
# back under `budget_codegen`. "Oldest" is by mtime, and a hit never
# touches an entry's mtime (only `cacheStore`'s initial write does), so
# this evicts the oldest BUILT, not the least recently USED; acceptable; an
# LRU policy would need a touch on every hit, not added here.
evict_codegen() {
  codegen_dir=$1
  objects="$codegen_dir/o"
  [ -d "$objects" ] || return 0
  size=$(du_bytes "$codegen_dir")
  [ -n "$size" ] || return 0
  while [ "$size" -gt "$budget_codegen" ]; do
    oldest=$(find "$objects" -maxdepth 1 -mindepth 1 -printf '%T@ %p\n' 2>/dev/null | sort -n | head -1 | cut -d' ' -f2-)
    [ -n "$oldest" ] || break
    freed=$(du_bytes "$oldest")
    rm -rf "$oldest"
    [ -n "$freed" ] || break
    size=$((size - freed))
  done
}

rotate_if_over "$zig_cache" "$budget_zig_cache"
if [ -n "$global_cache" ]; then
  rotate_if_over "$global_cache" "$budget_global_cache" vera-codegen
  evict_codegen "$global_cache/vera-codegen"
fi
