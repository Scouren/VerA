"""roll_chain.py MODE IN_core.zig OUT_core.zig: a prototype of re-rolling on an emitted eval core.

The core of the generated parameter-heavy model is one stage of four statements repeated with
different setup slots, each stage taking the previous stage's result. This finds the repeat,
checks every stage is the same text but for its temporaries and slot numbers, keeps the first
stage as emitted, and replaces the rest:

  MODE roll      one loop over a table of slot rows, the stage body written once
  MODE outline   the stage body once as a noinline function, called once per stage in a row
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
if mode == 'roll':
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
