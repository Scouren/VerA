"""Pack-pass premise, measured: for each configuration, generate a scalar and a packed body with
pack_gen.py, time the compile of the body alone through rtime (fresh cache), run both for
nanoseconds per evaluation and a checksum, and read eval's instruction mix from the assembly.

Usage: BENCH_RTIME=/path/to/rtime python3 tools/bench/pack_run.py OUT.tsv CONFIG...
       CONFIG is G:N:cpu:params:flow:only[:outline[:chunk]], for example
       64:3:x86_64_v3:contiguous:mixed:-:outline      64 groups of 4 chains, 3 derivative lanes
       1024:3:x86_64_v3:contiguous:mixed:-:outline:50 the same body as noinline functions of 50 groups
Run from the repository root; generated sources and binaries go to $BENCH_WORK (default /tmp/vera-pack).
"""
import os, re, shutil, subprocess, sys, collections
HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.environ.get('BENCH_WORK', '/tmp/vera-pack')
GM = os.path.join(os.path.dirname(os.path.dirname(HERE)), 'lib', 'contract', 'gm.zig')
RT = os.environ['BENCH_RTIME']
out = sys.argv[1]
cfgs = [c.split(':') for c in sys.argv[2:]]   # G:N:cpu:params:flow:only[:outline]
rows = []
def asm_eval(path):
    b = []; on = False
    for l in open(path):
        if re.match(r'^"?(\.L[^:]*\.)?eval"?:\s*$', l): on = True; continue
        if on and re.match(r'^\s*\.cfi_endproc', l): break
        if on and l.startswith('\t') and not l.strip().startswith('.'): b.append(l.strip())
    ops = collections.Counter(x.split()[0] for x in b)
    arith = re.compile(r'^v?f?n?m?(?:add|sub|mul|div|sqrt|max|min)[0-9]*(p|s)d$')
    packed = sum(v for k, v in ops.items() if arith.match(k) and arith.match(k).group(1) == 'p')
    scal = sum(v for k, v in ops.items() if arith.match(k) and arith.match(k).group(1) == 's')
    return len(b), packed, scal, ops.get('call', 0)
for cfg in cfgs:
    G, N, cpu, params, flow, only = cfg[:6]
    outline = len(cfg) > 6 and cfg[6] == 'outline'
    chunk = cfg[7] if len(cfg) > 7 else '0'
    res = {}
    for variant in ('scalar', 'packed'):
        tag = f'{variant}_{G}_{N}_{cpu}_{params}_{flow}_{only}'.replace('-', 'all') + ('_ol' if outline else '') + ('_c' + chunk if chunk != '0' else '')
        src = os.path.join(WORK, 'gen', tag + '.zig'); os.makedirs(os.path.dirname(src), exist_ok=True)
        a = ['python3', '-I', os.path.join(HERE, 'pack_gen.py'), variant, G, N, src, '--params', params, '--flow', flow]
        if only != '-': a += ['--only', only]
        if outline: a += ['--outline']
        if chunk != '0': a += ['--chunk', chunk]
        subprocess.run(a, check=True)
        lines = sum(1 for l in open(src) if l.startswith('    const g') or l.startswith('    put'))
        body = src[:-4] + '_body.zig'
        subprocess.run(a[:6] + [body] + a[7:] + ['--no-main'], check=True)
        zc = os.path.join(WORK, 'zc'); shutil.rmtree(zc, ignore_errors=True)
        exe = os.path.join(WORK, 'gen', tag)
        rec = os.path.join(WORK, 'gen', tag + '.rt')
        if os.path.exists(rec): os.remove(rec)
        env = dict(os.environ, RTIME_OUT=rec, RTIME_QUIET='1')
        flags = ['-OReleaseFast', f'-mcpu={cpu}', '-fllvm', '-fstrip', '--dep', 'gm']
        # Compile cost: the body alone as an object, as a device piece is built.
        subprocess.run([RT, 'zig', 'build-obj'] + flags + [f'-Mroot={body}', f'-Mgm={GM}', '--cache-dir', zc, f'-femit-bin={exe}.o'], env=env, check=True)
        wall, cpu_s, peak, code = open(rec).read().split()
        assert code == '0', (tag, code)
        asm = exe + '.s'; ll = exe + '.ll'
        subprocess.run(['zig', 'build-obj'] + flags + [f'-Mroot={body}', f'-Mgm={GM}', '--cache-dir', zc, '-fno-emit-bin', f'-femit-asm={asm}', f'-femit-llvm-ir={ll}'], check=True)
        insns, packed, scal, calls = asm_eval(asm)
        ir = 0; on = False
        for l in open(ll):
            if l.startswith('define') and re.search(r'[@.]eval"?\(', l): on = True; continue
            if on and l.startswith('}'): break
            if on and l.strip() and not l.strip().endswith(':'): ir += 1
        text = int(subprocess.run(['python3', '-I', '-c', "import sys,struct\nd=open(sys.argv[1],'rb').read()\nshoff=struct.unpack_from('<Q',d,0x28)[0];shentsize,shnum,shstrndx=struct.unpack_from('<HHH',d,0x3A)\nsh=lambda i:struct.unpack_from('<IIQQQQIIQQ',d,shoff+i*shentsize)\nstro=sh(shstrndx)[4]\nt=0\nfor i in range(shnum):\n    s=sh(i);name=d[stro+s[0]:d.index(b'\\0',stro+s[0])].decode()\n    if name.startswith('.text'): t+=s[5]\nprint(t)", exe + '.o'], capture_output=True, text=True).stdout or 0)
        subprocess.run(['zig', 'build-exe'] + flags + [f'-Mroot={src}', f'-Mgm={GM}', '--cache-dir', zc, '--name', tag, f'-femit-bin={exe}'], check=True)
        ns = []; h = None
        for _ in range(3):
            o = subprocess.run([exe], capture_output=True, text=True).stderr.split()
            ns.append(float(o[0])); h = o[1]
        res[variant] = dict(lines=lines, cpu=float(cpu_s), peak=float(peak), ns=min(ns), h=h, insns=insns, packed=packed, scal=scal, calls=calls, ir=ir, text=text)
        for f in (asm, ll, exe + '.o'):
            if os.path.exists(f): os.remove(f)
    s, p = res['scalar'], res['packed']
    row = [G, N, cpu, params, flow, only + ('+outline' if outline else '') + ('+chunk' + chunk if chunk != '0' else ''), s['lines'], p['lines'], f"{s['cpu']:.2f}", f"{p['cpu']:.2f}", f"{s['peak']:.0f}", f"{p['peak']:.0f}", s['ir'], p['ir'], s['insns'], p['insns'], s['text'], p['text'],
           f"{s['packed']}/{s['scal']}", f"{p['packed']}/{p['scal']}", f"{s['ns']:.1f}", f"{p['ns']:.1f}", f"{s['ns']/p['ns']:.2f}", 'same' if s['h'] == p['h'] else 'DIFFERENT']
    rows.append(row); print('\t'.join(map(str, row)), flush=True)
hdr = ['groups', 'deriv_lanes', 'cpu', 'params', 'flow', 'only', 'lines_scalar', 'lines_packed', 'compile_cpu_s_scalar', 'compile_cpu_s_packed', 'compile_peak_MiB_scalar', 'compile_peak_MiB_packed',
       'ir_scalar', 'ir_packed', 'insns_scalar', 'insns_packed', 'text_bytes_scalar', 'text_bytes_packed', 'packed/scalar_fp_ops_in_scalar', 'packed/scalar_fp_ops_in_packed', 'ns_scalar', 'ns_packed', 'speedup', 'bits']
with open(out, 'w') as fh:
    fh.write('\t'.join(hdr) + '\n')
    for r in rows: fh.write('\t'.join(map(str, r)) + '\n')
