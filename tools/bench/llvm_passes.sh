#!/bin/sh
# llvm_passes.sh WORKDIR [clang flags...]: which LLVM passes one device build spends its time in.
#
# Re-runs the first zig command the shim logged for WORKDIR up to unoptimized bitcode
# (--verbose-llvm-bc), then optimizes and compiles that bitcode with `zig cc -O3 -ftime-report`
# and prints the top of the pass report. Extra flags go to clang, for example
#   -mllvm -enable-gvn-memdep=false     -fno-slp-vectorize     -mllvm -enable-misched=false
# Zig's own pipeline is not the same binary path, but on the devices tried the code it produced
# ran at the same speed (3,046 against 3,048 ns per evaluation of a 256-branch model).
#
# Usage: sh tools/bench/llvm_passes.sh /tmp/w16
set -eu
w=$1; shift
args=$(cut -f6 "$w/zig.tsv" | head -1 | sed 's/--listen=- //')
# shellcheck disable=SC2086
zig $args --cache-dir "$w/zc_passes" -fno-emit-bin --verbose-llvm-bc="$w/pre.bc"
zig cc -O3 -fPIC "$@" -c "$w/pre.bc" -o "$w/pre.o" -ftime-report 2> "$w/passes.txt"
awk '/Pass execution timing report/{on=1} on' "$w/passes.txt" | sed -n 3,18p
