"""Wall time and peak RSS of vera per model and mode, through wait4 (ru_maxrss of the child and its largest descendant).

Usage: bench.py VERA OUT.tsv MODEL... ; modes from BENCH_MODES (default lint,emit-zig).
emit-so builds the device with zig: its row's peak is the larger of vera's and
zig's (time -v reports the largest child), its time includes the zig compile.
"""
import os, re, subprocess, sys, tempfile, time

vera, out, models = sys.argv[1], sys.argv[2], sys.argv[3:]
modes = os.environ.get("BENCH_MODES", "lint,emit-zig").split(",")
reps = int(os.environ.get("BENCH_REPS", "3"))
rows = []
for m in models:
    for mode in modes:
        with tempfile.TemporaryDirectory() as wd:
            args = [vera, "--" + mode, m]
            if mode == "emit-zig":
                args += ["-o", os.path.join(wd, "d.zig")]
            if mode in ("emit-so", "emit-osdi", "check"):
                args += ["--work-dir", wd]
            if mode == "emit-osdi":
                args += ["-o", os.path.join(wd, "d.osdi")]
            best_t, peak, rc, extra = None, 0, 0, ""
            for _ in range(reps if mode not in ("emit-so", "emit-osdi", "check") else 1):
                t0 = time.perf_counter()
                env = dict(os.environ)
                if os.environ.get('BENCH_FRESH_GLOBAL'):
                    env['ZIG_GLOBAL_CACHE_DIR'] = os.path.join(wd, 'gcache')
                p = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
                _, status, ru = os.wait4(p.pid, 0)
                secs = time.perf_counter() - t0
                rc = os.waitstatus_to_exitcode(status)
                kb = ru.ru_maxrss
                best_t = secs if best_t is None else min(best_t, secs)
                peak = max(peak, kb)
            if mode == "emit-zig" and os.path.exists(os.path.join(wd, "d.zig")):
                z = open(os.path.join(wd, "d.zig")).read()
                extra = f"{z.count(chr(10))} lines, {len(z) // 1024} KiB"
            rows.append((os.path.basename(m), mode, f"{best_t:.3f}", f"{peak / 1024:.1f}", str(rc), extra))
            print("\t".join(rows[-1]), flush=True)
with open(out, "w") as fh:
    fh.write("model\tmode\twall_s\tpeak_MiB\texit\toutput\n")
    for r in rows:
        fh.write("\t".join(r) + "\n")
