#!/usr/bin/env python3
"""Logging shim for zig: pass it as `vera --zig tools/bench/zig_shim.py` to see every zig process a build runs.

Appends one TSV line per invocation to $ZIG_SHIM_LOG: start, end, wall seconds, peak MiB, exit status,
full argv, CPU seconds. Processes of a split build overlap, so its peak memory is the sum of the
overlapping lines, not the largest. The real compiler is $ZIG_SHIM_REAL (default: `zig` on PATH).
"""
import os, shutil, sys, time
REAL = os.environ.get("ZIG_SHIM_REAL") or shutil.which("zig")
log = os.environ.get("ZIG_SHIM_LOG", "/tmp/zig-shim.tsv")
t0 = time.time()
pid = os.fork()
if pid == 0:
    os.execv(REAL, [REAL] + sys.argv[1:])
_, status, ru = os.wait4(pid, 0)
t1 = time.time()
with open(log, "a") as fh:
    fh.write(f"{t0:.3f}\t{t1:.3f}\t{t1 - t0:.3f}\t{ru.ru_maxrss / 1024:.1f}\t{os.waitstatus_to_exitcode(status)}\t{' '.join(sys.argv[1:])}\t{ru.ru_utime + ru.ru_stime:.2f}\n")
sys.exit(os.waitstatus_to_exitcode(status))
