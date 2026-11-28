#!/usr/bin/env python3
"""dv0.py: the DV0 harness. vera-next's OSDI devices, their size, build time, iterate time and checksum.

The devices: tests/bench/*.va, and gen_models.py's wide 64, 256, 1600 and inst 1000. Each is built
with `vera-next --emit-osdi` in a fresh work directory (the global zig cache warm: build ms is the
device's own compile) and driven by osdi_host.zig, which prints the time of one transient iterate
(eval + load_spice_rhs_tran + load_jacobian_tran, the least of 5 timed loops over two cards) and
one checksum over every number the library hands back.

Measurement (K2). One osdi_host run is one sample. A round runs every device of every build once
at each of four stack alignments (the environment's size, padded so that argv plus environment
is the same length for every device and moves in steps of 16 bytes), the builds interleaved
device by device: A, B, A, B, so drift on a shared machine lands on both. `iter_ns_min` is the
least sample, `iter_ns_median` the median; the eval-only column is the same for d.eval alone.
Every sample of a device must print the same checksum, or the run fails (a nondeterminism).

TSV columns: name, osdi_bytes, build_ms, iter_ns_min, iter_ns_median, eval_ns_min,
eval_ns_median, samples, checksum.

Gate: `gate BASE.tsv NEW.tsv` compares by device name. It fails, naming each device, when one is
missing or added, when its checksum changed, or when its iter_ns_min is more than TOL (default
0.30) slower than the baseline's, plus a floor of FLOOR_NS (default 3 ns, the resolution osdi_host
reports in). TOL follows the measured spread: two runs of the same builds on this shared 4-core
machine moved one device's min by 22% (wide64: 1637 vs 1992 ns) and the smallest by 3 ns.

Usage (inside `nix develop -c`, holding a build slot: `flock ~/.cache/vera-heavy.1.lock ...`):
  dv0.py run VERA_NEXT OUT.tsv [--work DIR] [--rounds N] [--only a,b]
  dv0.py ab VERA_A VERA_B A.tsv B.tsv [--work DIR] [--rounds N] [--only a,b]   two drivers, interleaved
  dv0.py gate BASE.tsv NEW.tsv [--tol 0.30] [--floor-ns 3]
  dv0.py selftest VERA_NEXT [--work DIR]   the gate's oracle, red then green (see `selftest`)
  dv0.py census VERA_NEXT OUT.tsv [--work DIR]   DV-C: zig_shim + origin_census over wide 800,
                                                 1600, 3200 and inst 1000 (needs BENCH_RTIME)
`zig build bench-dv0-selftest` runs `selftest` (minutes: it builds and times devices, so it is not
part of `test`); `zig build test` runs `gate-selftest`, the gate's logic on planted rows (< 1 s).
"""
import argparse, os, re, shutil, statistics, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
COLS = ['name', 'osdi_bytes', 'build_ms', 'iter_ns_min', 'iter_ns_median', 'eval_ns_min', 'eval_ns_median', 'samples', 'checksum']
ALIGNMENTS = (0, 16, 32, 48)  # bytes added to the environment: four 16-byte stack offsets in one cache line
HOST_LINE = re.compile(r'iterate_ns (\d+) \(eval (\d+) rhs_tran \d+ jac_tran \d+\) checksum ([0-9a-f]+)')
# inst 1000 is refused by codegen/zig at this commit (inst 62 is the largest it emits: 63 cells, 64
# nodes), so it stays as a `refused` row (its name is compared like any other) and inst62 is measured.
GENERATED = (('wide64', 'wide', 64), ('wide256', 'wide', 256), ('wide1600', 'wide', 1600), ('inst1000', 'inst', 1000),
             ('inst62', 'inst', 62))
CENSUS = (('wide800', 'wide', 800), ('wide1600', 'wide', 1600), ('wide3200', 'wide', 3200), ('inst1000', 'inst', 1000),
          ('inst62', 'inst', 62))


def die(msg):
    sys.exit('dv0: ' + msg)


def models(work, generated):
    """name -> .va path: tests/bench/*.va by file stem, then the generated models."""
    out = {}
    bench = os.path.join(ROOT, 'tests', 'bench')
    for f in sorted(os.listdir(bench)):
        if f.endswith('.va'):
            out[f[:-3]] = os.path.join(bench, f)
    gdir = os.path.join(work, 'models')
    os.makedirs(gdir, exist_ok=True)
    for name, kind, n in generated:
        path = os.path.join(gdir, name + '.va')
        r = subprocess.run([sys.executable, '-I', os.path.join(HERE, 'gen_models.py'), kind, str(n), path])
        if r.returncode != 0:
            die(f'gen_models.py {kind} {n} failed')
        out[name] = path
    return out


def build_host(work):
    host = os.path.join(work, 'osdi_host')
    args = ['zig', 'build-exe', '-OReleaseFast', '-lc', '--dep', 'abi', '-Mroot=' + os.path.join(HERE, 'osdi_host.zig'),
            '-Mabi=' + os.path.join(ROOT, 'lib', 'osdi_dyn', 'abi.zig'), '--cache-dir', os.path.join(work, 'zc-host'),
            '-femit-bin=' + host]
    r = subprocess.run(args)
    if r.returncode != 0:
        die('building osdi_host failed')
    return host


NOT_BUILT = 'is not built in vera-next yet'
REFUSED = 'codegen refused a construct'  # the new side declines the model: a row, not a crash


def shim_rows(log):
    return [l.rstrip('\n').split('\t') for l in open(log) if l.strip()]


def build_device(vera, va, out_dir, name):
    """A device's .osdi and its build ms (vera-next's wall time, zig included), in a fresh work
    directory, every zig process logged by zig_shim.py in <wd>/zig.tsv (the census reads it) through
    dv0_zig.py.
    `vera-next --emit-osdi`; while vera-next refuses that (its OSDI backend is not built), the route
    --emit-osdi resolves to (src/next/main.zig `contractTree`): --emit-so under the work tree's own
    lib/osdi_dyn.zig, the library copied to <name>.osdi. A model codegen refuses gives (None, ms)."""
    wd = os.path.join(out_dir, name)
    shutil.rmtree(wd, ignore_errors=True)
    os.makedirs(wd)
    osdi = os.path.join(out_dir, name + '.osdi')
    zig = ['--zig', os.path.join(HERE, 'dv0_zig.py')]
    env = dict(os.environ, ZIG_SHIM_LOG=os.path.join(wd, 'zig.tsv'), ZIG_SHIM_REAL=shutil.which('zig'))
    t0 = time.perf_counter()
    r = subprocess.run([vera, '--emit-osdi', va, '-o', osdi, '--work-dir', wd] + zig, env=env, capture_output=True, text=True)
    if r.returncode == 0 and os.path.exists(osdi):
        return osdi, (time.perf_counter() - t0) * 1000
    if REFUSED in r.stderr:
        return None, (time.perf_counter() - t0) * 1000
    if NOT_BUILT not in r.stderr:
        die(f'{name}: vera-next --emit-osdi failed (exit {r.returncode}):\n{r.stderr[-2000:]}')
    shutil.rmtree(wd)
    os.makedirs(wd)
    t0 = time.perf_counter()
    r = subprocess.run([vera, '--emit-so', va, '--work-dir', wd, '--dyn', os.path.join(wd, 'vera-src', 'lib', 'osdi_dyn.zig')] + zig,
                       env=env, capture_output=True, text=True)
    ms = (time.perf_counter() - t0) * 1000
    if REFUSED in r.stderr:
        return None, ms
    lib = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ''
    if r.returncode != 0 or not os.path.isfile(lib):
        die(f'{name}: vera-next --emit-so failed (exit {r.returncode}):\n{r.stderr[-2000:]}')
    shutil.copyfile(lib, osdi)
    return osdi, ms


def sample(host, osdi, pad):
    """One osdi_host run; the environment holds only the pad, so its size sets the stack's offset."""
    r = subprocess.run([host, osdi], env={'DV0_PAD': 'x' * pad}, capture_output=True, text=True)
    m = HOST_LINE.search(r.stderr)
    if r.returncode != 0 or not m:
        die(f'osdi_host {osdi} failed (exit {r.returncode}): {r.stderr[-800:]}')
    return int(m.group(1)), int(m.group(2)), m.group(3)


def measure(host, builds, rounds):
    """builds: list of {name: (osdi, build_ms)} over the same names. Interleaved rounds; returns rows per build."""
    names = sorted(builds[0])
    for b in builds:
        if sorted(b) != names:
            die('interleaved builds name different devices')
    longest = max(len(osdi) for b in builds for osdi, _ in b.values() if osdi)
    samples = [{n: [] for n in names} for _ in builds]
    for _ in range(rounds):
        for align in ALIGNMENTS:
            for n in names:
                for k, b in enumerate(builds):
                    osdi = b[n][0]
                    if osdi is None:
                        continue
                    # argv plus environment the same length for every device: only `align` moves the stack.
                    samples[k][n].append(sample(host, osdi, longest - len(osdi) + align))
    tables = []
    for k, b in enumerate(builds):
        rows = []
        for n in names:
            s = samples[k][n]
            if b[n][0] is None:
                rows.append(dict({c: '-' for c in COLS}, name=n, osdi_bytes=0, build_ms=round(b[n][1]), samples=0, checksum='refused'))
                continue
            sums = {c for _, _, c in s}
            if len(sums) != 1:
                die(f'{n}: osdi_host printed {len(sums)} checksums over {len(s)} runs: {sorted(sums)}')
            it = [x for x, _, _ in s]
            ev = [x for _, x, _ in s]
            rows.append({'name': n, 'osdi_bytes': os.path.getsize(b[n][0]), 'build_ms': round(b[n][1]),
                         'iter_ns_min': min(it), 'iter_ns_median': statistics.median(it), 'eval_ns_min': min(ev),
                         'eval_ns_median': statistics.median(ev), 'samples': len(s), 'checksum': sums.pop()})
        tables.append(rows)
    return tables


def write_tsv(path, rows):
    with open(path, 'w') as fh:
        fh.write('\t'.join(COLS) + '\n')
        for r in rows:
            fh.write('\t'.join(str(r[c]) for c in COLS) + '\n')


def read_tsv(path):
    lines = open(path).read().splitlines()
    if not lines or lines[0].split('\t') != COLS:
        die(f'{path}: not a dv0 TSV (header {lines[:1]})')
    out = {}
    for line in lines[1:]:
        r = dict(zip(COLS, line.split('\t')))
        if r['name'] in out:
            die(f'{path}: device {r["name"]} twice')
        out[r['name']] = r
    return out


def gate(base, new, tol, floor_ns):
    """The failures, one line per device, by name; empty when the gate passes."""
    fails = []
    for n in sorted(set(base) - set(new)):
        fails.append(f'{n}: missing (in the baseline, not measured)')
    for n in sorted(set(new) - set(base)):
        fails.append(f'{n}: added (measured, not in the baseline)')
    for n in sorted(set(base) & set(new)):
        b, x = base[n], new[n]
        if b['checksum'] != x['checksum']:
            fails.append(f'{n}: checksum {b["checksum"]} -> {x["checksum"]}')
        if 'refused' in (b['checksum'], x['checksum']):
            continue  # a refusal on one side is a checksum change above; on both, nothing to time
        bt, xt = float(b['iter_ns_min']), float(x['iter_ns_min'])
        if xt > bt * (1 + tol) + floor_ns:
            fails.append(f'{n}: iter_ns_min {bt:g} -> {xt:g} ({xt / bt:.2f}x; allowed {1 + tol:.2f}x + {floor_ns:g} ns)')
    return fails


def run_gate(base, new, tol, floor_ns):
    fails = gate(read_tsv(base), read_tsv(new), tol, floor_ns)
    for f in fails:
        print('dv0 gate: FAIL ' + f)
    print(f'dv0 gate: {"FAIL" if fails else "ok"} ({len(fails)} failure(s); tol {tol:g}, floor {floor_ns:g} ns)')
    return 1 if fails else 0


def build_set(vera, srcs, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    built = {}
    for n, va in srcs.items():
        built[n] = build_device(vera, va, out_dir, n)
        print(f'dv0: {"built" if built[n][0] else "REFUSED by codegen:"} {n} in {built[n][1]:.0f} ms', file=sys.stderr, flush=True)
    return built


def pick(srcs, only):
    if not only:
        return srcs
    want = only.split(',')
    missing = [w for w in want if w not in srcs]
    if missing:
        die(f'--only names no device: {missing}')
    return {n: srcs[n] for n in want}


def cmd_run(a):
    srcs = pick(models(a.work, GENERATED), a.only)
    host = build_host(a.work)
    built = build_set(a.vera, srcs, os.path.join(a.work, 'a'))
    rows, = measure(host, [built], a.rounds)
    write_tsv(a.out, rows)
    sys.stdout.write(open(a.out).read())
    return 0


def cmd_ab(a):
    srcs = pick(models(a.work, GENERATED), a.only)
    host = build_host(a.work)
    ba = build_set(a.vera_a, srcs, os.path.join(a.work, 'a'))
    bb = build_set(a.vera_b, srcs, os.path.join(a.work, 'b'))
    ra, rb = measure(host, [ba, bb], a.rounds)
    write_tsv(a.out_a, ra)
    write_tsv(a.out_b, rb)
    for p in (a.out_a, a.out_b):
        sys.stdout.write(p + '\n' + open(p).read())
    return 0


# The planted slowdown: diode.va with a chain of `reps` exps of the junction voltage, each fed by the
# last, compared once against a constant and never added (a select of 0.0): every output number and
# the descriptor stay the same and only the time moves. Each exp's argument is <= 0, so the chain is
# in (0, 1] and the comparison with a point inside that range cannot be decided at compile time.
SLOW_DECL = '  real vd, vt, id;\n'
SLOW_BODY = '    id = is * (exp(vd / vt) - 1.0) + gmin * vd;\n'


def plant_slow(src, reps):
    text = open(src).read()
    assert SLOW_DECL in text and SLOW_BODY in text, 'diode.va changed: update the planted copies'
    chain = ['    s0 = exp(-vd * vd / vt);\n'] + \
        [f'    s{k} = exp(-(vd * vd + {k}.0e-3) * (1.0 + s{k - 1}) / vt);\n' for k in range(1, reps)]
    names = [f's{k}' for k in range(reps)]
    text = text.replace(SLOW_DECL, '  real vd, vt, id, ' + ', '.join(names) + ';\n')
    return text.replace(SLOW_BODY, SLOW_BODY + ''.join(chain) + f'    id = id + (({" + ".join(names)}) == 0.123456789 ? 1.0 : 0.0);\n')


def cmd_selftest(a):
    """The gate's oracle on real builds: baseline (abs, diode), a planted no-op (a comment in diode)
    and a planted slow diode, measured interleaved. Green only when the no-op passes and the slow one
    fails naming diode alone, on time, with its checksum unchanged."""
    bench = os.path.join(ROOT, 'tests', 'bench')
    pdir = os.path.join(a.work, 'planted')
    os.makedirs(pdir, exist_ok=True)
    diode = os.path.join(bench, 'diode.va')
    noop = os.path.join(pdir, 'diode_noop.va')
    slow = os.path.join(pdir, 'diode_slow.va')
    open(noop, 'w').write(open(diode).read().replace('analog begin', 'analog begin // dv0: a planted no-op', 1))
    open(slow, 'w').write(plant_slow(diode, a.reps))
    host = build_host(a.work)
    base = build_set(a.vera, {'abs': os.path.join(bench, 'abs.va'), 'diode': diode}, os.path.join(a.work, 'base'))
    nb = build_set(a.vera, {'abs': os.path.join(bench, 'abs.va'), 'diode': noop}, os.path.join(a.work, 'noop'))
    sb = build_set(a.vera, {'abs': os.path.join(bench, 'abs.va'), 'diode': slow}, os.path.join(a.work, 'slow'))
    rb, rn, rs = measure(host, [base, nb, sb], a.rounds)
    paths = {}
    for tag, rows in (('base', rb), ('noop', rn), ('slow', rs)):
        paths[tag] = os.path.join(a.work, tag + '.tsv')
        write_tsv(paths[tag], rows)
        for r in rows:
            print(f'dv0 selftest: {tag:4} {r["name"]:6} iter_ns_min {r["iter_ns_min"]:>6} median {r["iter_ns_median"]:>7} checksum {r["checksum"]}')
    base_t, noop_t, slow_t = (read_tsv(paths[t]) for t in ('base', 'noop', 'slow'))
    f_noop = gate(base_t, noop_t, a.tol, a.floor_ns)
    f_slow = gate(base_t, slow_t, a.tol, a.floor_ns)
    print('dv0 selftest: noop gate ->', f_noop or 'pass')
    print('dv0 selftest: slow gate ->', f_slow or 'pass')
    ok = not f_noop and len(f_slow) == 1 and f_slow[0].startswith('diode: iter_ns_min')
    print('dv0 selftest:', 'ok' if ok else 'FAILED: want the no-op to pass and the slow diode alone to fail on time')
    return 0 if ok else 1


def gate_selftest():
    """The gate's logic on planted rows (cheap; part of `zig build test`)."""
    def row(n, t, c='aa'):
        return {'name': n, 'iter_ns_min': str(t), 'checksum': c}
    base = {'a': row('a', 100), 'b': row('b', 10), 'c': row('c', 50)}
    cases = [
        ({'a': row('a', 100), 'b': row('b', 10), 'c': row('c', 50)}, []),
        ({'a': row('a', 115), 'b': row('b', 13), 'c': row('c', 40)}, []),
        ({'a': row('a', 200), 'b': row('b', 10), 'c': row('c', 50)}, ['a: iter_ns_min']),
        ({'a': row('a', 100), 'b': row('b', 10, 'bb'), 'c': row('c', 50)}, ['b: checksum']),
        ({'a': row('a', 100), 'b': row('b', 10), 'd': row('d', 50)}, ['c: missing', 'd: added']),
        ({'a': row('a', '-', 'refused'), 'b': row('b', 10), 'c': row('c', 50)}, ['a: checksum aa -> refused']),
    ]
    bad = 0
    for new, want in cases:
        got = gate(base, new, 0.20, 3)
        if len(got) != len(want) or not all(g.startswith(w) for g, w in zip(got, want)):
            print(f'dv0 gate-selftest: FAIL {sorted(new)}: want {want}, got {got}')
            bad += 1
    print(f'dv0 gate-selftest: {"FAIL" if bad else "ok"} ({len(cases)} cases)')
    return 1 if bad else 0


def summed_peak(log):
    """The largest sum of peak MiB over zig processes alive at one moment (an upper bound)."""
    rows = [tuple(map(float, l.split('\t')[:4])) for l in open(log) if l.strip()]
    best = 0.0
    for t0, _, _, _ in rows:
        best = max(best, sum(mib for s, e, _, mib in rows if s <= t0 < e))
    return best, len(rows)


def cmd_census(a):
    if 'BENCH_RTIME' not in os.environ:
        die('census needs BENCH_RTIME: zig cc -O2 -o rtime tools/bench/rtime.c')
    srcs = pick(models(a.work, CENSUS), a.only)
    srcs = {n: srcs[n] for n, _, _ in CENSUS if n in srcs}
    out_dir = os.path.join(a.work, 'census')
    os.makedirs(out_dir, exist_ok=True)
    dirs = []
    peaks = []
    for n, va in srcs.items():
        log = os.path.join(out_dir, n, 'zig.tsv')
        wd = os.path.join(out_dir, n)
        osdi, ms = build_device(a.vera, va, out_dir, n)
        if osdi is None:
            peaks.append((n, ms, 0, 0.0))
            print(f'dv0 census: {n} REFUSED by codegen ({ms:.0f} ms)', file=sys.stderr, flush=True)
            continue
        peak, procs = summed_peak(log)
        peaks.append((n, ms, procs, peak))
        print(f'dv0 census: {n} build {ms:.0f} ms, {procs} zig processes, summed peak {peak:.0f} MiB', file=sys.stderr, flush=True)
        dirs.append(wd)
    r = subprocess.run([sys.executable, '-I', os.path.join(HERE, 'origin_census.py'), a.out] + dirs)
    with open(a.out, 'a') as fh:
        for n, ms, procs, peak in peaks:
            fh.write(f'{n}\tsplit build: wall ms / zig processes / summed peak MiB\t' +
                     (f'{ms:.0f} / {procs} / {peak:.0f}\n' if procs else 'refused by codegen\n'))
    return r.returncode


def main():
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = p.add_subparsers(dest='cmd', required=True)
    def common(s, rounds=True):
        s.add_argument('--work', default=None)
        s.add_argument('--only', default='')
        if rounds:
            s.add_argument('--rounds', type=int, default=5)
    s = sub.add_parser('run'); s.add_argument('vera'); s.add_argument('out'); common(s)
    s = sub.add_parser('ab'); s.add_argument('vera_a'); s.add_argument('vera_b'); s.add_argument('out_a'); s.add_argument('out_b'); common(s)
    s = sub.add_parser('gate'); s.add_argument('base'); s.add_argument('new')
    s.add_argument('--tol', type=float, default=0.30); s.add_argument('--floor-ns', type=float, default=3)
    s = sub.add_parser('selftest'); s.add_argument('vera'); common(s)
    s.add_argument('--tol', type=float, default=0.30); s.add_argument('--floor-ns', type=float, default=3)
    s.add_argument('--reps', type=int, default=3, help='exp chains planted in the slow diode')
    sub.add_parser('gate-selftest')
    s = sub.add_parser('census'); s.add_argument('vera'); s.add_argument('out'); common(s, rounds=False)
    a = p.parse_args()
    if a.cmd == 'gate':
        return run_gate(a.base, a.new, a.tol, a.floor_ns)
    if a.cmd == 'gate-selftest':
        return gate_selftest()
    a.work = os.path.abspath(a.work or tempfile.mkdtemp(prefix='dv0-'))
    os.makedirs(a.work, exist_ok=True)
    if hasattr(a, 'vera'):
        a.vera = os.path.abspath(a.vera)
    return {'run': cmd_run, 'ab': cmd_ab, 'selftest': cmd_selftest, 'census': cmd_census}[a.cmd](a)


if __name__ == '__main__':
    sys.exit(main())
