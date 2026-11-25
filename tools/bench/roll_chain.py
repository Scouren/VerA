"""roll_chain.py MODE IN_core.zig OUT_core.zig: a prototype of re-rolling on an emitted eval core.

The core of the generated parameter-heavy model is one stage of four statements repeated with
different setup slots, each stage taking the previous stage's result. This finds the repeat,
checks every stage is the same text but for its temporaries and slot numbers, keeps the first
stage as emitted, and replaces the rest:

  MODE roll      one loop over a table of slot rows, the stage body written once
  MODE outline   the stage body once as a noinline function, called once per stage in a row
  MODE chunk     every stage as emitted, CHUNK_STAGES (32) to a noinline function: no code is
                 shared, only the size of each function is bounded
                 (what a repeated macro or analog function looks like when it does not form a loop)

The statements, their order and the float mode are unchanged, so results are the same bits.
"""
import re, sys
mode, src_path, out_path = sys.argv[1:4]
src = open(src_path).read()
stm = list(re.finditer(r'^    const (t\d+) = (.*);\n', src, re.M))
names = [m.group(1) for m in stm]; rhs = [m.group(2) for m in stm]
# head: t0, t1, A0, B0, C0; then groups of four (D, A, B, C); tail: two statements.
HEAD, TAIL = 5, 2
body = list(range(HEAD, len(stm) - TAIL)); assert len(body) % 4 == 0, len(body)
groups = [body[i:i + 4] for i in range(0, len(body), 4)]
def canon(g, prev_c):
    d, a, b, c = (names[i] for i in g)
    text = '\n'.join(rhs[i] for i in g)
    for old, new in sorted(((prev_c, 'carry'), (d, 'sD'), (a, 'sA'), (b, 'sB'), (c, 'sC')), key=lambda p: -len(p[0])):
        text = re.sub(r'\b%s\b' % old, new, text)
    slots = re.findall(r'model\.su\.r\[(\d+)\]', text)
    it = iter(range(len(slots)))
    text = re.sub(r'model\.su\.r\[\d+\]', lambda m: 'r[row[%d]]' % next(it), text)
    return text, slots
prev = names[HEAD - 1]; canons = []
for g in groups:
    canons.append(canon(g, prev)); prev = names[g[3]]
assert all(c[0] == canons[0][0] for c in canons), 'stages differ'
others = set(re.findall(r'\bt\d+\b', canons[0][0])) - {'t1'}
assert not others, others
tail_text = ''.join(stm[i].group(0) for i in range(len(stm) - TAIL, len(stm)))
last_c = names[groups[-1][3]]
used = set(re.findall(r'\bt\d+\b', tail_text)) - {names[-1], names[-2], 't0', 't1', last_c}
assert len(used) <= 1, used
keep = None
if used:
    kname = used.pop()
    gi = next(i for i, g in enumerate(groups) if kname in [names[j] for j in g]); role = ['sD', 'sA', 'sB', 'sC'][[names[j] for j in groups[gi]].index(kname)]
    keep = (kname, gi, role)
first = groups[0]; ns = len(canons[0][1])
sD, sA, sB, sC = canons[0][0].split('\n')
out = [f'    const Row = [{ns}]u16;', '    const rows = [_]Row{'] + ['        .{ ' + ', '.join(c[1]) + ' },' for c in canons[1:]] + ['    };',
       f'    var carry = {names[first[3]]};']
if keep: out.append(f'    var keep = {names[first[["sD", "sA", "sB", "sC"].index(keep[2])]]};')
def inner(t): return re.sub(r'\bt1\b', 't1_in', re.sub(r'\bcarry\b', 'carry_in', t))
if mode == 'chunk':
    import os
    per = int(os.environ.get('CHUNK_STAGES', '32'))
    kidx = ['sD', 'sA', 'sB', 'sC'].index(keep[2]) if keep else 1
    # A value crosses each call as ONE vector of a power-of-two width, the scalar first and the
    # unused elements exactly 0. Two things measured here decide that form:
    #   - a struct crosses through memory in both directions (0.8 to 1% per iterate);
    #   - a 3-lane vector read back from memory brings its padding element with it, and stale bytes
    #     there (a pointer reads as a subnormal double) cost a floating-point assist on every
    #     operation that touches them: 450 to 600 ns per eval, on or off with the stack's alignment.
    out = [f'    const TC = @TypeOf({names[first[3]]});', f'    const TK = @TypeOf({names[first[kidx]]});', '    const T1 = @TypeOf(t1);', '    const Stages = struct {',
           '        fn FlatOf(comptime T: type) type {', '            var n: usize = 1;', '            while (n < 1 + @typeInfo(@FieldType(T, "d")).vector.len) n *= 2;', '            return @Vector(n, f64);', '        }',
           '        inline fn flatOf(val: anytype) FlatOf(@TypeOf(val)) {', '            const D = @FieldType(@TypeOf(val), "d");', '            const n = @typeInfo(D).vector.len;',
           '            var a: [@typeInfo(FlatOf(@TypeOf(val))).vector.len]f64 = @splat(0.0);', '            a[0] = val.v;', '            const d: [n]@typeInfo(D).vector.child = val.d;',
           '            inline for (0..n) |i| a[1 + i] = d[i];', '            return a;', '        }',
           '        inline fn unflatOf(comptime T: type, f: FlatOf(T)) T {', '            const D = @FieldType(T, "d");', '            const n = @typeInfo(D).vector.len;',
           '            const a: [@typeInfo(FlatOf(T)).vector.len]f64 = f;', '            // SAFETY: every element is written by the loop below.', '            var d: [n]@typeInfo(D).vector.child = undefined;',
           '            inline for (0..n) |i| d[i] = @floatCast(a[1 + i]);', '            return .{ .v = a[0], .d = d };', '        }']
    calls = []
    rest = groups[1:]
    for c in range((len(rest) + per - 1) // per):
        gs = rest[c * per:(c + 1) * per]
        prev_c = names[groups[groups.index(gs[0]) - 1][3]]
        kname = None
        body = []
        for g in gs:
            for i in g:
                text = re.sub(r'\b%s\b' % prev_c, 'carry_in', rhs[i])
                text = re.sub(r'\bt1\b', 't1_in', text).replace('model.su.r[', 'm.su.r[')
                body.append(f'            const {names[i]} = {text};')
            if keep and groups.index(g) == keep[1]: kname = names[g[kidx]]
        sig = 'cf: FlatOf(TC), t1f: FlatOf(T1), m: *const Model' + (', keep_out: *FlatOf(TK)' if kname else '')
        out += [f'        noinline fn run{c}({sig}) FlatOf(TC) {{', '            @setFloatMode(.strict);', '            const carry_in = unflatOf(TC, cf);', '            const t1_in = unflatOf(T1, t1f);'] + body
        if kname: out.append(f'            keep_out.* = flatOf({kname});')
        out += [f'            return flatOf({names[gs[-1][3]]});', '        }']
        calls.append(f'    carry_f = Stages.run{c}(carry_f, t1_f, model' + (', &keep_f' if kname else '') + ');')
    out += ['    };', f'    var carry_f = Stages.flatOf({names[first[3]]});', '    const t1_f = Stages.flatOf(t1);']
    if keep: out.append(('    const' if keep[1] == 0 else '    var') + f' keep_f = Stages.flatOf({names[first[kidx]]});')
    out += calls + ['    const carry = Stages.unflatOf(TC, carry_f);']
    if keep: out.append('    const keep = Stages.unflatOf(TK, keep_f);')
    else: out = [l for l in out if not l.startswith('    const TK = ')]
elif mode == 'roll':
    # Two loops when a mid-chain value is read later, so no iteration tests its own index.
    cut = keep[1] if keep and keep[1] > 0 else len(canons) - 1
    spans = [(0, cut, True), (cut, len(canons) - 1, False)] if cut < len(canons) - 1 else [(0, cut, bool(keep and keep[1] > 0))]
    for lo, hi, takes in spans:
        out += [f'    for (rows[{lo}..{hi}]) |*row| {{', '        const r = &model.su.r;', f'        const sD = {sD};', f'        const sA = {sA};', f'        const sB = {sB};', f'        const sC = {sC};']
        if takes and keep: out.append(f'        keep = {keep[2]};')
        out += ['        carry = sC;', '    }']
else:
    krole = keep[2] if keep else 'sA'
    out += [f'    const TC = @TypeOf({names[first[3]]});', f'    const TK = @TypeOf({names[first[["sD", "sA", "sB", "sC"].index(krole)]]});', '    const T1 = @TypeOf(t1);',
            '    const Stage = struct {', '        noinline fn run(carry_in: TC, t1_in: T1, m: *const Model, row: *const Row) struct { k: TK, c: TC } {',
            '            @setFloatMode(.strict);', '            const r = &m.su.r;',
            f'            const sD = {inner(sD)};', f'            const sA = {inner(sA)};', f'            const sB = {inner(sB)};', f'            const sC = {inner(sC)};',
            '            return .{ .k = ' + krole + ', .c = sC };', '        }', '    };']
    for k in range(len(canons) - 1):
        out.append(f'    {{ const o = Stage.run(carry, t1, model, &rows[{k}]); carry = o.c;' + (' keep = o.k;' if keep and keep[1] - 1 == k else '') + ' }')
tail = tail_text
tail = re.sub(r'\b%s\b' % last_c, 'carry', tail)
if keep: tail = re.sub(r'\b%s\b' % keep[0], 'keep', tail)
start = stm[groups[1][0]].start()
open(out_path, 'w').write(src[:start] + '\n'.join(out) + '\n' + tail + src[stm[-1].end():])
print(f'{mode}: {len(groups)} stages of 4 statements, {ns} slots each; {len(groups) - 1} replaced; keep={keep}')
