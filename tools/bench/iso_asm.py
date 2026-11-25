"""iso_asm.py WORKDIR: re-run each zig command the shim logged for one device build, with assembly
output, and report the functions that hold the device math: instructions, packed and scalar
double operations, and calls. Scalar operations and one exp call per branch mean the backend left
the isomorphic branches unpacked.

Usage: ZIG_SHIM_LOG=$W/zig.tsv vera --emit-osdi in.va --zig tools/bench/zig_shim.py --work-dir $W -o $W/d.osdi
       BENCH_RTIME=/path/to/rtime python3 tools/bench/iso_asm.py $W
"""
import collections, glob, os, re, subprocess, sys
w = sys.argv[1]
RT = os.environ['BENCH_RTIME']
arith = re.compile(r'^v?f?n?m?(?:add|sub|mul|div|sqrt|max|min)[0-9]*(p|s)d$')
for i, line in enumerate(open(os.path.join(w, 'zig.tsv'))):
    f = line.rstrip('\n').split('\t')
    args = [a for a in f[5].split(' ') if a != '--listen=-']
    if args[0] not in ('build-lib', 'build-obj'): continue
    for k, a in enumerate(args):
        if a == '--cache-dir': args[k + 1] = os.path.join(w, 'zc_asm')
    s = os.path.join(w, f'asm_{i}.s')
    r = subprocess.run([RT, 'zig'] + args + [f'-femit-asm={s}', '-fno-emit-bin'], capture_output=True, text=True)
    print(f'{os.path.basename(w)}\tprocess {i}\twall_s cpu_s peak_MiB exit = {r.stderr.strip().splitlines()[-1]}')
for path in sorted(glob.glob(os.path.join(w, 'asm_*.s'))):
    cur = None; body = collections.OrderedDict()
    for l in open(path):
        m = re.match(r'^("?)([^\t ].*)\1:\s*$', l)
        if m and not re.match(r'^"?\.L(BB|CPI|tmp|func|JTI)', l): cur = m.group(2); body[cur] = []; continue
        if cur and l.startswith('\t') and not l.strip().startswith('.'): body[cur].append(l.strip())
    for name, b in body.items():
        if not re.search(r'Eval\(device\)\.eval|device\.eval|device\.core', name): continue
        ops = collections.Counter(x.split()[0] for x in b)
        p = sum(v for k, v in ops.items() if arith.match(k) and arith.match(k).group(1) == 'p')
        sc = sum(v for k, v in ops.items() if arith.match(k) and arith.match(k).group(1) == 's')
        print(f'{os.path.basename(w)}\t{name[:48]}\tinsns={len(b)}\tpacked_fp={p}\tscalar_fp={sc}\tcalls={ops.get("call", 0)}')
