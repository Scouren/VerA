#!/bin/sh
# no_slowdown.sh WORKDIR NAME [pack|chunk]: one emitted device in the configuration that costs
# nothing per iterate. WORKDIR is a device as VerA emitted it, with the zig.tsv that zig_shim.py
# logged for its build. The steps:
#   - range checks and setup as tables (tabulate_cold.py), every device;
#   - pack: independent isomorphic branches computed 4 at a time (pack_branches.py);
#   - chunk: a repeated sequential stage in bounded functions (roll_chain.py chunk);
#   - the wrapper's tables appended as literals (emit_tables.zig, emit_params.zig);
#   - the build re-run against the wrapper at LIB (proto/host-literals), best of 3.
# Prints build CPU seconds, peak MiB, library bytes and the OSDI host's line (osdi_host.zig).
# Environment: LIB (the wrapper's lib directory), OUT (scratch), RTIME (rtime.c built),
# HOST (osdi_host.zig built), CHUNK_STAGES (stages to a function, default 32).
set -eu
src=$1; name=$2; shift 2
T=$(cd "$(dirname "$0")" && pwd)
LIB=${LIB:?the lib directory of a tree at proto/host-literals}
OUT=${OUT:-/tmp/vera-no-slowdown}; RTIME=${RTIME:?rtime.c built}; HOST=${HOST:?osdi_host.zig built}
d=$OUT/$name; mkdir -p "$OUT/libs"; mkdir "$d"
cp -r "$src/device.zig" "$src/h.zig" "$src/shim.zig" "$src/u" "$src/vera-src" "$d/"
sed "s#$src/#$d/#g" "$src/zig.tsv" > "$d/zig.tsv"
python3 -I "$T/tabulate_cold.py" "$src/device.zig" "$d/device.zig" | sed "s/^/  $name: /"
core=$(ls "$d"/u/*core*.zig | head -1)
for step in "$@"; do
  case $step in
    chunk) python3 -I "$T/roll_chain.py" chunk "$src/u/$(basename "$core")" "$core" | sed "s/^/  $name: /";;
    pack) python3 -I "$T/pack_branches.py" "$src/u/$(basename "$core")" "$core" 4 "$LIB/contract/family.zig" | sed "s/^/  $name: /";;
    *) echo "unknown step $step"; exit 2;;
  esac
done
# The two harnesses read the wrapper's own files, so they are built inside a copy of it.
[ -d "$OUT/lib" ] || { cp -r "$LIB" "$OUT/lib"; cp "$T/emit_tables.zig" "$T/emit_params.zig" "$OUT/lib/osdi_dyn/"; }
for h in emit_tables emit_params; do
  zig build-exe -ODebug --dep contract --dep device -Mroot="$OUT/lib/osdi_dyn/$h.zig" --dep contract -Mdevice="$d/device.zig" -Mcontract="$OUT/lib/contract.zig" --cache-dir "$OUT/zc" -femit-bin="$d/$h" 2>&1 | head -5
  "$d/$h" 2> "$d/$h.txt"
done
cat "$d/emit_tables.txt" "$d/emit_params.txt" >> "$d/device.zig"
args=$(cut -f6 "$d/zig.tsv" | head -1 | sed 's/--listen=- //' | sed -E "s#=[^ ]*/vera-src/lib/#=$LIB/#g")
best=999
for i in 1 2 3; do
  # shellcheck disable=SC2086
  o=$("$RTIME" zig $args --cache-dir "$OUT/zc_t/$name$i" -femit-bin="$OUT/libs/$name.osdi" 2>&1 >/dev/null | tail -1)
  [ "$(echo "$o" | cut -f4)" = 0 ] || { echo "$name: build FAILED"; exit 1; }
  best=$(python3 -c "print(min($best,$(echo "$o" | cut -f2)))"); pk=$(echo "$o" | cut -f3)
done
echo "$name: build ${best}s peak ${pk}MiB library $(stat -c %s "$OUT/libs/$name.osdi") bytes; $("$HOST" "$OUT/libs/$name.osdi" 2>&1)"
