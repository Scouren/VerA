"""lib_ab.py REPS LIB_B WORKDIR...: the device build of each work directory logged by zig_shim.py, timed
against the lib/ tree it was built with (A) and against another lib/ tree (B), for example a
prototype branch's. Fresh cache per run, best of REPS; prints CPU seconds and peak MiB for both.

Usage: BENCH_RTIME=/path/to/rtime python3 tools/bench/lib_ab.py 3 /path/to/other/lib /tmp/w_res /tmp/w_wide
"""
import os, re, shutil, subprocess, sys
RT = os.environ['BENCH_RTIME']; reps = int(sys.argv[1]); libb = sys.argv[2].rstrip('/')
def run(w, lib):
    best = None
    for _ in range(reps):
        cpu = 0.0; peak = 0.0; wall = 0.0
        for line in open(os.path.join(w, 'zig.tsv')):
            args = [a for a in line.rstrip('\n').split('\t')[5].split(' ') if a != '--listen=-']
            if args[0] not in ('build-lib', 'build-obj'): continue
            zc = os.path.join(w, 'zc_ab'); shutil.rmtree(zc, ignore_errors=True)
            for k, a in enumerate(args):
                if a == '--cache-dir': args[k + 1] = zc
            if lib: args = [re.sub(r'=.*?/vera-src/lib/', '=' + lib + '/', x) if x.startswith(('-Mcontract=', '-Mdyn=')) else x for x in args]
            r = subprocess.run([RT, 'zig'] + args, capture_output=True, text=True)
            wl, c, p, code = r.stderr.strip().splitlines()[-1].split('\t')
            assert code == '0', r.stderr[-600:]
            cpu += float(c); peak = max(peak, float(p)); wall += float(wl)
            shutil.rmtree(zc, ignore_errors=True)
        if best is None or cpu < best[0]: best = (cpu, peak)
    return best
print('device\tcpu_s_A\tcpu_s_B\tchange\tpeak_MiB_A\tpeak_MiB_B')
for w in sys.argv[3:]:
    a = run(w, None); b = run(w, libb)
    print(f'{os.path.basename(w.rstrip("/"))}\t{a[0]:.2f}\t{b[0]:.2f}\t{100 * (b[0] - a[0]) / a[0]:+.0f}%\t{a[1]:.0f}\t{b[1]:.0f}', flush=True)
