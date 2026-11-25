"""parity.py REF_VERA NEW_VERA SUITE_DIR INCLUDE_DIR [CODE...]: the diagnostics gate of a rule move.

Runs `--lint --diagnostics=json -I INCLUDE_DIR` of both compilers on every .va and .vams under
SUITE_DIR and compares exit code, stdout and stderr byte for byte. Prints how many sources report
a diagnostic at all and how many report each CODE (the rules being moved), so a run that never
reached the moved rules is visible. Exits 1 on any difference.

  python3 -I tools/bench/parity.py vera-ref vera-new tests/conformance tests/conformance/tests/include E0405 E0406
"""
import subprocess, sys, os, re, collections
from concurrent.futures import ThreadPoolExecutor
ref, new, root, inc = sys.argv[1:5]; moved = tuple(sys.argv[5:])
files = sorted(os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs if f.endswith(('.va', '.vams')))
def run(binary, f):
    try:
        p = subprocess.run([binary, '--lint', '--diagnostics=json', '-I', inc, f], capture_output=True, timeout=60)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 'timeout', b'', b''
def both(f): return f, run(ref, f), run(new, f)
same = diff = 0; differing = []; hit = collections.Counter(); withdiag = 0
with ThreadPoolExecutor(2) as ex:
    for f, a, b in ex.map(both, files):
        if a == b: same += 1
        else: diff += 1; differing.append(f)
        found = set(re.findall(rb'[EW]\d{4}', a[1] + a[2]))
        if found: withdiag += 1
        for c in moved:
            if c.encode() in found: hit[c] += 1
print(f'files {len(files)}  identical {same}  different {diff}  with a diagnostic {withdiag}')
print('sources reporting a named code (reference):', dict(hit))
for f in differing[:10]: print('DIFF', f)
sys.exit(1 if diff else 0)
