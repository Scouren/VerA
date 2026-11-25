"""shape_types.py IN_core.zig OUT_core.zig: a prototype of typing values by shape on the emitted branch model.

Every branch of the generated N-branch model reads two unknowns of its own, so today each branch's
values have a type of their own (one per derivative mask) and every family operation is
instantiated once per branch. This rewrites the emitted core so each branch computes on the two
lowest lanes instead: the probes are re-typed on the way in and each result is re-typed to its
own mask on the way out. A re-type copies the value and its lanes unchanged, so the arithmetic
and the results are the same bits; only the number of distinct types falls.
"""
import re, sys
src = open(sys.argv[1]).read()
helper = '''
/// The type `a` takes on the way into a branch computed on shared lanes: lane-less values stay
/// as they are, so the value-only entry points instantiate nothing new.
fn ZShapeIn(comptime S: type, comptime m: anytype, comptime A: type) type {
    return if (@hasDecl(A, "mask") and @popCount(A.mask) == @popCount(zOf(S, m).mask)) zOf(S, m) else A;
}
/// `a` under the mask `m` of the same lane count: the same value and the same lanes.
inline fn zShapeIn(comptime S: type, comptime m: anytype, a: anytype) ZShapeIn(S, m, @TypeOf(a)) {
    const R = ZShapeIn(S, m, @TypeOf(a));
    if (R == @TypeOf(a)) return a;
    return .{ .v = a.v, .d = a.d };
}
/// `a` as `zOf(S, m)`: re-typed when it carries as many lanes, widened as `zTo` otherwise.
inline fn zShapeOut(comptime S: type, comptime m: anytype, a: anytype) zOf(S, m) {
    const A = @TypeOf(a);
    const R = zOf(S, m);
    if (A == R) return a;
    if (@hasDecl(A, "mask") and @popCount(A.mask) == @popCount(R.mask) and A.mask != 0) return .{ .v = a.v, .d = a.d };
    return zTo(S, m, a);
}
'''
n_in = [0]
def probe(m):
    n_in[0] += 1
    return 'zShapeIn(S, 0x%d, x[@intFromEnum(U.%s%s)])' % (1 if m.group(1) == 'a' else 2, m.group(1), m.group(2))
out = re.sub(r'x\[@intFromEnum\(U\.(a|c)(\d+)\)\]', probe, src)
out, n_out = re.subn(r'(\.f\d+ = )zTo\(S, (0x[0-9a-f]+), (t\d+)\)', r'\1zShapeOut(S, \2, \3)', out)
i = out.index('pub fn '); j = out.rfind('\n', 0, i)
# The helpers use zOf and zTo from the device file; the core file gets them the same way it gets its other helpers.
need = [n for n in ('zOf', 'zTo') if not re.search(r'^const %s\b|^fn %s\b' % (n, n), out, re.M)]
open(sys.argv[2], 'w').write(out + helper)
print(f'{n_in[0]} probes and {n_out} results re-typed; helpers the core must already see: zOf, zTo; missing: {need}')
