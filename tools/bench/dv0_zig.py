#!/usr/bin/env python3
"""dv0_zig.py: the `--zig` dv0.py hands vera-next. Before running zig (through zig_shim.py, which
logs the process to $ZIG_SHIM_LOG), it appends the evalQ adapter to the `-Mdevice=` file when that
device declares `q` but no `evalQ`: lib/osdi_dyn calls `D.evalQ` on a device with `q`, and
codegen/zig (the new side) emits `eval` and `q` apart, so its device does not compile under the
dyn. That append is the only change made to an emitted device; once the new side emits `evalQ`
it is a no-op. Every zig process takes the same lock first, so none reads a half-patched file.
"""
import fcntl, os, sys

ADAPTER = """
// dv0 adapter (tools/bench/dv0_zig.py): lib/osdi_dyn calls `evalQ` on a device with `q`; the new side emits `eval` and `q` apart.
pub fn evalQ(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) struct { res: contract.Rows(Self, S), q: contract.Sites(Self, S) } {
    return .{ .res = eval(S, x, model, inst, sim), .q = q(S, x, model, inst, sim) };
}
"""

here = os.path.dirname(os.path.abspath(__file__))
dev = next((a[len('-Mdevice='):] for a in sys.argv[1:] if a.startswith('-Mdevice=')), None)
if dev:
    with open(dev + '.dv0lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        text = open(dev).read()
        if 'pub fn q(' in text and 'pub fn evalQ(' not in text:
            tmp = dev + '.dv0tmp'
            open(tmp, 'w').write(text + ADAPTER)
            os.replace(tmp, dev)
os.execv(sys.executable, [sys.executable, os.path.join(here, 'zig_shim.py')] + sys.argv[1:])
