#!/usr/bin/env bash
# The merge gate on `refactor` (research/finish.md §4 #4, G1): `test` (the
# merge tier), then every `diff-*` step, each its own build-slot.sh call
# (AGENTS.md: one corpus step per call), two at a time on the two slots.
# Exits non-zero when any step fails and names each one; logs go to
# <log dir>/<step>.log. The steps come from `zig build -l`, so a new diff
# step joins the gate without an edit here.
# diff-rtlil is not here: its Yosys tiebreaker needs `nix develop .#external`
# (build/rewrite_comp.zig), the external gate's shell.
# Usage: tools/gate.sh <worktree> [log dir]
#        tools/gate.sh selftest   (the script's own oracle, in `test`)
# VERA_GATE_SLOT and VERA_GATE_STEPS replace build-slot.sh and the step list
# only so the selftest can plant a failing step without a build.
set -u
if [ "${1:-}" = selftest ]; then
  T=$(mktemp -d) || exit 1
  printf '#!/bin/sh\n[ "$2" != diff-b ]\n' > "$T/slot"; chmod +x "$T/slot"
  fail=0
  out=$(VERA_GATE_SLOT="$T/slot" VERA_GATE_STEPS="diff-a diff-b" bash "$0" "$T" "$T/logs" 2>&1)
  [ $? -ne 0 ] || { echo "FAIL: a failing step passed the gate" >&2; fail=1; }
  case $out in *"FAIL diff-b"*) ;; *) echo "FAIL: the failing step is not named: $out" >&2; fail=1 ;; esac
  case $out in *"FAIL diff-a"* | *"FAIL test"*) echo "FAIL: a passing step is named: $out" >&2; fail=1 ;; esac
  VERA_GATE_SLOT="$T/slot" VERA_GATE_STEPS="diff-a" bash "$0" "$T" "$T/logs" > /dev/null 2>&1 || { echo "FAIL: passing steps failed the gate" >&2; fail=1; }
  rm -rf "$T"
  exit $fail
fi
wt=$(readlink -f "$1")
logs=${2:-$wt/zig-out/gate}
here=$(dirname "$(readlink -f "$0")")
mkdir -p "$logs" || exit 2
slot=${VERA_GATE_SLOT:-$here/build-slot.sh}
steps=${VERA_GATE_STEPS:-$(cd "$wt" && nix develop -c zig build -l 2>/dev/null | awk '$1 ~ /^diff-/ && $1 != "diff-rtlil" {print $1}')}
[ -n "$steps" ] || { echo "gate: no diff-* steps listed in $wt" >&2; exit 2; }
run() {
  "$slot" "$wt" "$1" > "$logs/$1.log" 2>&1
  code=$?
  echo "$code $1" >> "$logs/status"
  return $code
}
export -f run
export slot wt logs
: > "$logs/status"
printf '%s\n' test $steps | xargs -P2 -I{} bash -c 'run {}'
failed=$(awk '$1 != 0 {print $2}' "$logs/status" | sort)
ran=$(wc -l < "$logs/status")
want=$(printf '%s\n' test $steps | wc -l)
[ "$ran" -eq "$want" ] || { echo "gate: $ran of $want steps reported" >&2; exit 1; }
if [ -n "$failed" ]; then
  for s in $failed; do echo "gate: FAIL $s (log: $logs/$s.log)" >&2; done
  exit 1
fi
echo "gate: $want steps passed (logs: $logs)"
