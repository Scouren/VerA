"""pack_devices.py REPS LIB WORKDIR...: the emitted devices of the listed work directories built one
library each, against one library holding all of them. Prints CPU seconds and peak MiB for both.

The wrapper exports one descriptor per library today, so this works on a copy of LIB with one
measurement-only hook appended (exportDeviceAs: a further device's descriptor under its own
symbol). The copy and the build products go to $BENCH_WORK (default /tmp/vera-packdev).

Usage: BENCH_RTIME=/path/to/rtime python3 tools/bench/pack_devices.py 3 lib /tmp/w_res /tmp/w_dio /tmp/w_nmos1
"""
import os, re, shutil, subprocess, sys
RT = os.environ['BENCH_RTIME']; reps = int(sys.argv[1]); ws = [os.path.abspath(w) for w in sys.argv[3:]]
here = os.environ.get('BENCH_WORK', '/tmp/vera-packdev'); os.makedirs(here, exist_ok=True)
lib = os.path.join(here, 'lib'); shutil.rmtree(lib, ignore_errors=True); shutil.copytree(sys.argv[2], lib)
HOOK = '''/// Measurement only: a further device's descriptor under its own symbol, so several devices
/// compile in one library. A real pack would list them all in `OSDI_DESCRIPTORS`.
pub fn exportDeviceAs(comptime D: type, comptime name: []const u8, comptime sym: []const u8) void {
    const Lib = descriptor.Library(D, name, false);
    contract.validateHost(Lib, D);
    @export(&Lib.descriptors, .{ .name = sym });
}

'''
src = open(os.path.join(lib, 'osdi_dyn.zig')).read(); cut = src.index('// ---- private ----')
open(os.path.join(lib, 'osdi_dyn.zig'), 'w').write(src[:cut] + HOOK + src[cut:])
def timed(args):
    best = None
    for _ in range(reps):
        zc = os.path.join(here, 'zc'); shutil.rmtree(zc, ignore_errors=True)
        r = subprocess.run([RT, 'zig'] + args + ['--cache-dir', zc], capture_output=True, text=True)
        wall, cpu, peak, code = r.stderr.strip().splitlines()[-1].split('\t')
        if code != '0': sys.exit(r.stderr[-1500:])
        if best is None or float(cpu) < best[0]: best = (float(cpu), float(peak), float(wall))
    return best
common = ['build-lib', '-dynamic', '-OReleaseFast', '-lc', '-fllvm', '-fstrip']
tail = [f'-Mcontract={lib}/contract.zig', '--dep', 'contract', f'-Mdyn={lib}/osdi_dyn.zig']
sep = []
for i, w in enumerate(ws):
    shim = os.path.join(here, f'one_{i}.zig')
    open(shim, 'w').write(f'comptime {{ @import("dyn").exportDevice(@import("d{i}"), "dev{i}"); }}\n')
    sep.append(timed(common + ['--name', f'one{i}', '--dep', 'contract', '--dep', 'dyn', '--dep', f'd{i}', f'-Mroot={shim}', '--dep', 'contract', f'-Md{i}={w}/device.zig'] + tail))
shim = os.path.join(here, 'all.zig')
lines = []
for i in range(len(ws)):
    if i == 0: lines.append('    @import("dyn").exportDevice(@import("d0"), "dev0");\n')
    else: lines.append('    @import("dyn").exportDeviceAs(@import("d%d"), "dev%d", "OSDI_DESCRIPTORS_%d");\n' % (i, i, i))
open(shim, 'w').write('comptime {\n' + ''.join(lines) + '}\n')
args = common + ['--name', 'all', '--dep', 'contract', '--dep', 'dyn'] + sum((['--dep', f'd{i}'] for i in range(len(ws))), []) + [f'-Mroot={shim}']
for i, w in enumerate(ws): args += ['--dep', 'contract', f'-Md{i}={w}/device.zig']
allb = timed(args + tail)
print(f'{len(ws)} devices, lib {sys.argv[2]}')
print(f'  one library each: cpu {sum(s[0] for s in sep):.2f} s; peak {max(s[1] for s in sep):.0f} MiB each, {sum(s[1] for s in sep):.0f} MiB if all run at once')
print(f'  one library for all: cpu {allb[0]:.2f} s; peak {allb[1]:.0f} MiB; wall {allb[2]:.2f} s')
