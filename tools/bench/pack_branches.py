"""pack_branches.py IN_core.zig OUT_core.zig [K]: a prototype of the pack pass on VerA's emitted branch model.

The generated N-branch model computes every branch with the same three statements. This rewrites
the lane-carrying path of the emitted core so K branches (default 4) compute as one chain over
vectors: a value is one K-vector and one K-vector per derivative lane, and each operation applies
the reference family's own rule to all K branches at once (the same additions, multiplications,
fused multiply-adds and divisions per branch, and the same gm.exp per lane). The value-only path
is left as emitted. Results are the same bits; tools/bench/osdi_host.zig checks that end to end.
"""
import re, sys
src = open(sys.argv[1]).read(); K = int(sys.argv[3]) if len(sys.argv) > 3 else 4
stm = list(re.finditer(r'^    const (t\d+) = (.*);\n', src, re.M))
names = [m.group(1) for m in stm]; rhs = [m.group(2) for m in stm]
n = len(stm) // 3; assert len(stm) == 3 * n and n % K == 0, (len(stm), n)
probe = re.compile(r'^\(x\[@intFromEnum\(U\.(\w+)\)\]\)\.sub\(x\[@intFromEnum\(U\.(\w+)\)\]\)$')
ua = []; uc = []
for i in range(n):
    m = probe.match(rhs[i]); assert m, rhs[i]; ua.append(m.group(1)); uc.append(m.group(2))
def canon(i, text):
    for old, new in sorted(((names[i], 'q0'), (names[n + i], 'q1')), key=lambda p: -len(p[0])):
        text = re.sub(r'\b%s\b' % old, new, text)
    slots = [int(s) for s in re.findall(r'model\.su\.r\[(\d+)\]', text)]
    it = iter(range(len(slots)))
    return re.sub(r'model\.su\.r\[\d+\]', lambda m: 'SLOT%d' % next(it), text), slots
c1 = [canon(i, rhs[n + i]) for i in range(n)]; c2 = [canon(i, rhs[2 * n + i]) for i in range(n)]
assert all(c[0] == c1[0][0] for c in c1) and all(c[0] == c2[0][0] for c in c2), 'branches differ'
assert not c1[0][1], 'slots in the smoothing statement'
ret = dict((int(m.group(1)), (m.group(2), m.group(3))) for m in re.finditer(r'\.f(\d+) = zTo\(S, (0x[0-9a-f]+), (t\d+)\)', src))
assert len(ret) == n and all(ret[i][1] == names[2 * n + i] for i in range(n))
def vec(text, cl, group):
    slots_of_first = cl[group * K][1]
    # every slot of the group's branches must be the first branch's slot plus the branch offset: one vector load
    for j in range(K):
        assert [s + j for s in slots_of_first] == cl[group * K + j][1], 'slots not contiguous by role'
    for k, s in enumerate(slots_of_first): text = text.replace('SLOT%d' % k, 'Pk.slots(model, %d)' % s)
    text = re.sub(r'S\.con\((Pk\.slots\(model, \d+\))\)', r'Pk.con(\1)', text)
    text = re.sub(r'\.scale\((Pk\.slots\(model, \d+\))\)', r'.scaleK(\1)', text)
    text = text.replace('zSqrtD(S, ', 'Pk.sqrtD(')
    assert 'S.con(' not in text and 'model.su.r[' not in text, text
    return text
import os
CH = int(os.environ.get('PACK_CH', '8'))   # packs per function: bounded blocks keep LLVM's per-block passes linear
sig = re.search(r'^(pub fn (\w+)\(comptime S: type, x: anytype, model: \*const Model, [^)]*\)) struct \{\n(.*?)\n\} \{\n', src, re.S | re.M)
assert sig, 'core signature'
core_name = sig.group(2)
ret_type = f'/// The core\'s result, named so the pack functions can fill it in place.\nfn {core_name}_Ret(comptime S: type) type {{\n    return struct {{\n' + '\n'.join('    ' + l for l in sig.group(3).split('\n')) + '\n    };\n}\n'
chunks = []; calls = []
packs = n // K
for c in range((packs + CH - 1) // CH):
    gs = range(c * CH, min(packs, c * CH + CH)); m = len(gs)
    # The pack function is not generic and sees only vectors: the probes' values and lanes in,
    # the packs out. Passing the probe tuple or the result struct across the call would force
    # every probe and every result through memory, which measured 11% of an iterate at 256 branches.
    lines = [f'noinline fn {core_name}_pack{c}(model: *const Model, in: *const [{4 * m}]Pk.KV, out: *[{m}]Pk) void {{', '    @setFloatMode(.strict);']
    call = [f'        {{', f'            var in: [{4 * m}]Pk.KV = undefined;', f'            var out: [{m}]Pk = undefined;']
    for q, g in enumerate(gs):
        b = range(g * K, g * K + K)
        for w, (us, f) in enumerate(((ua, 'v'), (ua, 'd[0]'), (uc, 'v'), (uc, 'd[0]'))):
            call.append(f'            in[{4 * q + w}] = .{{ ' + ', '.join('x[@intFromEnum(U.%s)].%s' % (us[i], f) for i in b) + ' };')
        lines.append(f'    const g{g}_0 = (Pk.probes(in[{4 * q}], in[{4 * q + 1}], 0)).sub(Pk.probes(in[{4 * q + 2}], in[{4 * q + 3}], 1));')
        lines.append(f'    const g{g}_1 = ' + vec(c1[0][0], c1, g).replace('q0', f'g{g}_0') + ';')
        lines.append(f'    out[{q}] = ' + vec(c2[0][0], c2, g).replace('q1', f'g{g}_1').replace('q0', f'g{g}_0') + ';')
    call.append(f'            {core_name}_pack{c}(model, &in, &out);')
    for q, g in enumerate(gs):
        for j, i in enumerate(range(g * K, g * K + K)): call.append(f'            r.f{i} = Pk.lane(zOf(S, {ret[i][0]}), out[{q}], {j});')
    call.append('        }')
    lines.append('}')
    chunks.append('\n'.join(lines)); calls += call
body = ['    if (comptime Pk.carries(@TypeOf(x[@intFromEnum(U.%s)]))) {' % ua[0], f'        var r: {core_name}_Ret(S) = undefined;'] + calls + ['        return r;', '    }']
helper = '''
/// K branches side by side: one K-vector for the value and one per derivative lane. Each rule is
/// the reference family's rule for a two-lane value, applied to all K branches at once.
const Pk = struct {
    const k_n = %d;
    const KV = @Vector(k_n, f64);
    const fma = switch (@import("builtin").target.cpu.arch) {
        %s
    };
    v: KV,
    d0: KV,
    d1: KV,
    /// A constant per branch (the family's `con`): no lanes.
    const Con = struct { v: KV };

    fn carries(comptime A: type) bool {
        return @hasDecl(A, "mask") and A.mask != 0;
    }
    inline fn sp(c: f64) KV {
        return @splat(c);
    }
    inline fn mulAdd(a: KV, b: KV, c: KV) KV {
        return if (fma) @mulAdd(KV, a, b, c) else a * b + c;
    }
    /// K single-lane probes (their values `v` and lanes `d`) as one value whose lane `which` is
    /// theirs and whose other lane is +0, as the family widens a probe.
    inline fn probes(v: KV, d: KV, comptime which: u1) Pk {
        return if (which == 0) .{ .v = v, .d0 = d, .d1 = sp(0.0) } else .{ .v = v, .d0 = sp(0.0), .d1 = d };
    }
    inline fn slots(model: *const Model, comptime at: usize) KV {
        return model.su.r[at..][0..k_n].*;
    }
    inline fn con(c: KV) Con {
        return .{ .v = c };
    }
    /// Branch `j` as the family's own two-lane value type `R`.
    inline fn lane(comptime R: type, a: Pk, comptime j: usize) R {
        return .{ .v = a.v[j], .d = .{ a.d0[j], a.d1[j] } };
    }
    inline fn add(a: Pk, b: Pk) Pk {
        return .{ .v = a.v + b.v, .d0 = a.d0 + b.d0, .d1 = a.d1 + b.d1 };
    }
    inline fn sub(a: Pk, b: Pk) Pk {
        return .{ .v = a.v - b.v, .d0 = a.d0 - b.d0, .d1 = a.d1 - b.d1 };
    }
    inline fn mul(a: Pk, b: Pk) Pk {
        return .{ .v = a.v * b.v, .d0 = mulAdd(b.d0, a.v, a.d0 * b.v), .d1 = mulAdd(b.d1, a.v, a.d1 * b.v) };
    }
    inline fn div(a: Pk, b: anytype) Pk {
        const inv = sp(1.0) / b.v;
        const q = a.v / b.v;
        if (@TypeOf(b) == Con) return .{ .v = q, .d0 = a.d0 * inv, .d1 = a.d1 * inv };
        return .{ .v = q, .d0 = mulAdd(b.d0, -q, a.d0) * inv, .d1 = mulAdd(b.d1, -q, a.d1) * inv };
    }
    inline fn scale(a: Pk, c: f64) Pk {
        return a.scaleK(sp(c));
    }
    inline fn scaleK(a: Pk, c: KV) Pk {
        return .{ .v = a.v * c, .d0 = a.d0 * c, .d1 = a.d1 * c };
    }
    inline fn addC(a: Pk, c: f64) Pk {
        return .{ .v = a.v + sp(c), .d0 = a.d0, .d1 = a.d1 };
    }
    inline fn exp(a: Pk) Pk {
        const e = expK(a.v);
        return .{ .v = e, .d0 = a.d0 * e, .d1 = a.d1 * e };
    }
    /// The family's `sqrt`: slope 0.5/s where s > 0, else 0.
    inline fn sqrtD(a: Pk) Pk {
        const s = @sqrt(a.v);
        const slope = @select(f64, s > sp(0.0), sp(0.5) / s, sp(0.0));
        return .{ .v = s, .d0 = a.d0 * slope, .d1 = a.d1 * slope };
    }
    /// One out-of-line vector exp for the file: inlined at each use it is most of the code.
    noinline fn expK(x: KV) KV {
        return contract.gm.exp(x);
    }
};
'''
first = stm[0].start(); assert src[first - 5:first] != '    }'
fma_src = re.search(r'const fma_lanes = switch \(@import\("builtin"\)\.target\.cpu\.arch\) \{\n(.*?)\n\};', open(sys.argv[4]).read(), re.S).group(1).strip()
src2 = src[:first] + '\n'.join(body) + '\n' + src[first:]
src2 = src2.replace(sig.group(0), sig.group(1) + f' {core_name}_Ret(S) {{\n', 1)
out = src2 + '\n' + ret_type + '\n' + '\n\n'.join(chunks) + '\n' + helper % (K, fma_src)
open(sys.argv[2], 'w').write(out)
print(f'{n} branches packed {K} at a time: {n // K} packs of 3 statements in {len(chunks)} functions for the lane-carrying path; value-only path as emitted')
