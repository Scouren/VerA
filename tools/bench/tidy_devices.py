#!/usr/bin/env python3
"""tidy_devices.py (K3): tools/perf_tidy.py over the devices vera-next emits, as hot files.

Each tests/bench/*.va goes through `vera-next --emit-zig`; the text is linted as if it carried
`// tidy: hot-file` (every function a hot path), without the path heuristics (a name holding
`bench` would make it test code). A finding is dropped only by a row of tools/bench/perf_tidy.allow:
`rule<TAB>regex<TAB>reason`, the regex searched in the finding's source line; a row without a reason,
or a row no finding used, fails the run (an allow that matches nothing is stale, as an xfail that
passes is).

Usage: tidy_devices.py VERA_NEXT [--keep DIR]
       tidy_devices.py selftest VERA_NEXT   the oracle: the clean devices pass; diode with an
                                            allocation, then a print, planted in its `core` fails
                                            naming that rule.
`zig build tidy-devices` runs both.
"""
import importlib.util, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
ALLOW = os.path.join(HERE, 'perf_tidy.allow')
spec = importlib.util.spec_from_file_location('perf_tidy', os.path.join(ROOT, 'tools', 'perf_tidy.py'))
perf_tidy = importlib.util.module_from_spec(spec)
sys.modules['perf_tidy'] = perf_tidy  # dataclasses look their module up here
spec.loader.exec_module(perf_tidy)


def read_allow():
    rows = []
    for k, line in enumerate(open(ALLOW), 1):
        if not line.strip() or line.startswith('#'):
            continue
        parts = line.rstrip('\n').split('\t')
        if len(parts) != 3 or len(parts[2].strip()) < 10:
            sys.exit(f'{ALLOW}:{k}: want rule<TAB>regex<TAB>reason (a reason of 10 characters or more)')
        rows.append((k, parts[0], re.compile(parts[1]), parts[2]))
    return rows


def lint(name, text, allow, used):
    """The kept error findings of one emitted device; marks the allow rows used."""
    lines = text.split('\n')
    kept = []
    for f in perf_tidy.lint_text(name + '.zig', text + '\n// tidy: hot-file\n', path_heuristics=False):
        src = lines[f.line - 1] if 0 < f.line <= len(lines) else ''
        hit = [k for k, rule, rx, _ in allow if rule == f.rule and rx.search(src)]
        if hit:
            used.update(hit)
        elif f.level == 'error':
            kept.append(f'{name}.zig:{f.line}: [{f.rule}] {f.message}\n    {src.strip()[:120]}')
    return kept


def emit(vera, va):
    r = subprocess.run([vera, '--emit-zig', va], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f'vera-next --emit-zig {va} failed: {r.stderr[-800:]}')
    return r.stdout


def devices(vera):
    bench = os.path.join(ROOT, 'tests', 'bench')
    return {f[:-3]: emit(vera, os.path.join(bench, f)) for f in sorted(os.listdir(bench)) if f.endswith('.va')}


def check(texts, keep=None):
    allow, used, bad = read_allow(), set(), []
    for name, text in texts.items():
        if keep:
            open(os.path.join(keep, name + '.zig'), 'w').write(text)
        bad += lint(name, text, allow, used)
    stale = [f'{ALLOW}:{k}: allow row matched no finding ({rule}: {rx.pattern})' for k, rule, rx, _ in allow if k not in used]
    return bad, stale


def plant(text, stmt):
    """`stmt` as the first statement of the emitted core (the device's per-iterate body)."""
    m = re.search(r'\nfn \w*core\w*\([^\n]*\{\n', text) or re.search(r'\n(?:pub )?fn \w*[cC]ore\w*\([^\n]*\{\n', text)
    if not m:
        sys.exit('selftest: no core function in the emitted device: update `plant`')
    return text[:m.end()] + '    ' + stmt + '\n' + text[m.end():]


def selftest(vera):
    texts = devices(vera)
    bad, stale = check(texts)
    ok = not bad and not stale
    print(f'tidy selftest: clean devices -> {len(bad)} finding(s), {len(stale)} stale allow(s)')
    allow = read_allow()
    for rule, stmt in (('allocation-in-hot-path', 'const planted = std.heap.page_allocator.alloc(u8, 64) catch unreachable; _ = planted;'),
                       ('print-in-loop', 'for (0..2) |planted| std.debug.print("{d}\\n", .{planted});')):
        found = lint('diode_planted', plant(texts['diode'], stmt), allow, set())
        named = [f for f in found if f'[{rule}]' in f]
        print(f'tidy selftest: planted {rule} -> {"caught" if named else "MISSED"} ({len(found)} finding(s))')
        ok = ok and bool(named)
    print('tidy selftest:', 'ok' if ok else 'FAILED')
    return 0 if ok else 1


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == 'selftest':
        return selftest(os.path.abspath(sys.argv[2]))
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    keep = sys.argv[sys.argv.index('--keep') + 1] if '--keep' in sys.argv else None
    if keep:
        os.makedirs(keep, exist_ok=True)
    bad, stale = check(devices(os.path.abspath(sys.argv[1])), keep)
    for line in bad + stale:
        print(line)
    print(f'tidy_devices: {len(bad)} finding(s), {len(stale)} stale allow row(s)')
    return 1 if bad or stale else 0


if __name__ == '__main__':
    sys.exit(main())
