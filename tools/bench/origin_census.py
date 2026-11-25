"""origin_census.py WORKDIR...: where one device build's code and time come from.

For each work directory of a build logged by zig_shim.py, re-run every zig command with a fresh
cache and dump the IR LLVM is given (--verbose-llvm-ir), the IR it leaves (-femit-llvm-ir) and
the assembly. Count instructions per function and group them by origin:

  device hot    the device's eval, charge and state functions
  device cold   the device's setup, range checks and everything else it declares
  host hot      the OSDI wrapper's per-iterate code (osdi_dyn eval.zig, load.zig)
  host cold     the rest of the wrapper (params, setup, descriptor, tables, abi)
  contract      lib/contract, including the gm math kernels
  std           Zig's standard library

Then time three runs through rtime: semantic analysis only, analysis plus unoptimized bitcode,
and the full build, so the frontend and LLVM shares are known.

Usage: BENCH_RTIME=/path/to/rtime [CENSUS_LIB=/other/tree/lib] python3 tools/bench/origin_census.py OUT.tsv WORKDIR...
"""
import collections, os, re, shutil, subprocess, sys
RT = os.environ['BENCH_RTIME']
ORDER = ['device hot', 'device cold', 'host hot', 'host cold', 'contract', 'std']
def origin(name):
    n = name.lstrip('.L')
    if n.startswith('osdi_dyn.'):
        return 'host hot' if re.match(r'osdi_dyn\.(eval|load)\.', n) else 'host cold'
    if n.startswith('contract.'): return 'contract'
    if n.startswith('device.') or re.match(r'u\.|[\w]+__common__', n):
        return 'device hot' if re.match(r'device\.(eval|evalQ|q|core|updateState|stateCtl|noisePsd|limit|seed|z[A-Z])', n) or '__core' in n else 'device cold'
    return 'std'
def ir_funcs(path):
    out = collections.OrderedDict(); cur = None
    for l in open(path, errors='replace'):
        if l.startswith('define'):
            m = re.search(r'@("(?:[^"\\]|\\.)*"|[\w.$]+)\(', l); cur = m.group(1).strip('"'); out[cur] = 0; continue
        if cur is not None:
            if l.startswith('}'): cur = None; continue
            s = l.strip()
            if s and not s.endswith(':') and not s.startswith(';'): out[cur] += 1
    return out
def asm_funcs(path):
    out = collections.OrderedDict(); cur = None
    for l in open(path, errors='replace'):
        m = re.match(r'^("?)([^\t ].*)\1:\s*$', l)
        if m and not re.match(r'^"?\.L(BB|CPI|tmp|func|JTI|__anon|__unnamed)', l): cur = m.group(2); out[cur] = 0; continue
        if cur and l.startswith('\t') and not l.strip().startswith('.'): out[cur] += 1
    return out
def timed(args):
    r = subprocess.run([RT, 'zig'] + args, capture_output=True, text=True)
    wall, cpu, peak, code = r.stderr.strip().splitlines()[-1].split('\t')
    if code != '0': sys.exit('zig failed: ' + r.stderr[-800:])
    return float(cpu), float(peak)
rows = []
for w in sys.argv[2:]:
    tot = {k: collections.Counter() for k in ('pre', 'post', 'asm')}; nfun = collections.Counter()
    t = collections.Counter(); peak = 0.0; top = []
    for i, line in enumerate(open(os.path.join(w, 'zig.tsv'))):
        args = [a for a in line.rstrip('\n').split('\t')[5].split(' ') if a != '--listen=-']
        lib = os.environ.get('CENSUS_LIB')   # another lib/ tree to build against, e.g. a prototype branch's
        if lib: args = [re.sub(r'=.*?/vera-src/lib/', '=' + lib.rstrip('/') + '/', x) if x.startswith(('-Mcontract=', '-Mdyn=')) else x for x in args]
        if args[0] not in ('build-lib', 'build-obj'): continue
        zc = os.path.join(w, 'zc_census')
        for k, a in enumerate(args):
            if a == '--cache-dir': args[k + 1] = zc
        def fresh(): shutil.rmtree(zc, ignore_errors=True)
        pre, post, asm = (os.path.join(w, f'{x}_{i}') for x in ('pre.ll', 'post.ll', 'out.s'))
        fresh(); c, p = timed(args + ['-fno-emit-bin']); t['sema'] += c
        fresh(); c, p = timed(args + ['-fno-emit-bin', f'-femit-llvm-bc={w}/pre_{i}.bc']); t['bitcode'] += c
        fresh(); c, p = timed(args); t['full'] += c; peak = max(peak, p)
        fresh(); subprocess.run(['zig'] + args + [f'--verbose-llvm-ir={pre}', f'-femit-llvm-ir={post}', f'-femit-asm={asm}'], capture_output=True)
        for key, fn, path in (('pre', ir_funcs, pre), ('post', ir_funcs, post), ('asm', asm_funcs, asm)):
            for name, n in fn(path).items():
                tot[key][origin(name)] += n
                if key == 'pre': nfun[origin(name)] += 1; top.append((n, name))
        fresh()
    name = os.path.basename(w.rstrip('/'))
    for key in ('pre', 'post', 'asm'):
        s = sum(tot[key].values()) or 1
        rows.append([name, {'pre': 'IR given to LLVM', 'post': 'IR after optimization', 'asm': 'machine instructions'}[key], s] + [tot[key][o] for o in ORDER] + [f'{100 * tot[key][o] / s:.0f}%' for o in ORDER])
    rows.append([name, 'functions given to LLVM', sum(nfun.values())] + [nfun[o] for o in ORDER] + [''] * len(ORDER))
    rows.append([name, 'cpu_s: analysis only / plus bitcode / full; peak MiB', f"{t['sema']:.2f} / {t['bitcode']:.2f} / {t['full']:.2f}; {peak:.0f}"] + [''] * (2 * len(ORDER)))
    print(name, 'largest given to LLVM:', '; '.join(f'{n} {nm[:44]}' for n, nm in sorted(top, reverse=True)[:5]), file=sys.stderr)
hdr = ['device', 'measure', 'total'] + ORDER + [o + ' share' for o in ORDER]
with open(sys.argv[1], 'w') as fh:
    fh.write('\t'.join(hdr) + '\n')
    for r in rows: fh.write('\t'.join(map(str, r)) + '\n'); print('\t'.join(map(str, r)))
