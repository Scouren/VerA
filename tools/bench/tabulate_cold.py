"""tabulate_cold.py IN_device.zig OUT_device.zig: a prototype of "cold code as data" on an emitted device.

Rewrites two functions of the emitted text, where their statements have the shapes below, into a
table and a loop. Each function is rewritten only when every statement of it is recognised, and
is otherwise left as VerA emitted it, so a mixed function is never half rewritten.

  checkRange   { const v: f64 = model.F; if (!((v > LO and v < HI))) return "F"; }   per parameter
               -> rows of field offset and name, grouped in runs that share one range
  setup        const tN = S.con((model.F) * (K));  model.su.r[I] = (tN).val();
               model.su.r[I] = (S.con(model.F)).val();
               -> rows of slot, field offset and factor; rows of slot and field offset

The loops read the same field, compare or multiply in the same float mode, and visit the rows in
the emitted order, so the results are the same bits and the same first failing name.
"""
import re, sys
src = open(sys.argv[1]).read()

def body(name_re):
    m = re.search(name_re, src, re.M)
    if not m: return 0, 0, ''
    i = m.start(); j = src.index('\n}\n', i) + 3
    return i, j, src[i:j]

# ---- checkRange ----
i, j, text = body(r'^pub fn checkRange\(model: \*const Model\) \?\[\]const u8 \{')
blk = re.compile(r'    \{\n        const v: f64 = model\.(\w+);\n        if \(!\(\(v (>=?) (.+?) and v (<=?) (.+?)\)\)\) return "(\w+)";\n    \}\n')
rows = blk.findall(text)
rest = blk.sub('', text)
check_ok = bool(rows) and re.sub(r'\s+', '', rest) == 'pubfncheckRange(model:*constModel)?[]constu8{returnnull;}'
n_range = 0; runs = []
if check_ok:
    runs = []   # (lo_op, lo, hi_op, hi, first, count)
    for k, (f, lo_op, lo, hi_op, hi, name) in enumerate(rows):
        assert f == name
        key = (lo_op, lo, hi_op, hi)
        if runs and tuple(runs[-1][:4]) == key: runs[-1][5] += 1
        else: runs.append([lo_op, lo, hi_op, hi, k, 1])
    blob = ''.join(r[0] for r in rows)
    offs = []; o = 0
    for r in rows: offs.append(o); o += len(r[0])
    new = ['/// §3.4.2 ranges as data: one row per parameter (field offset, name), in runs that share a range.',
           'const RangeRun = struct { lo: f64, hi: f64, lo_incl: bool, hi_incl: bool, first: u32, count: u32 };',
           'const range_runs = [_]RangeRun{']
    for lo_op, lo, hi_op, hi, first, count in runs:
        new.append(f'    .{{ .lo = {lo}, .hi = {hi}, .lo_incl = {"true" if lo_op == ">=" else "false"}, .hi_incl = {"true" if hi_op == "<=" else "false"}, .first = {first}, .count = {count} }},')
    new += ['};', 'const range_off = [_]u32{ ' + ', '.join(f'@offsetOf(Model, "{r[0]}")' for r in rows) + ' };',
            'const range_name_at = [_]u32{ ' + ', '.join(map(str, offs + [o])) + ' };',
            f'const range_names = "{blob}";', '',
            'pub fn checkRange(model: *const Model) ?[]const u8 {',
            '    const base: [*]const u8 = @ptrCast(model);',
            '    for (&range_runs) |*run| {',
            '        for (run.first..run.first + run.count) |k| {',
            '            const v = @as(*const f64, @ptrCast(@alignCast(base + range_off[k]))).*;',
            '            const lo_ok = if (run.lo_incl) v >= run.lo else v > run.lo;',
            '            const hi_ok = if (run.hi_incl) v <= run.hi else v < run.hi;',
            '            if (!(lo_ok and hi_ok)) return range_names[range_name_at[k]..range_name_at[k + 1]];',
            '        }', '    }', '    return null;', '}', '']
    src = src[:i] + '\n'.join(new) + src[j:]
    n_range = len(rows)

# ---- setup ----
i, j, text = body(r'^pub fn setup\(comptime V: type, model: \*Model\) void \{')
tdef = dict((m.group(1), (m.group(2), m.group(3))) for m in re.finditer(r'    const (t\d+) = S\.con\(\(model\.(\w+)\) \* \((.+?)\)\);\n', text))
scale = []; copy = []
for m in re.finditer(r'    model\.su\.r\[(\d+)\] = \((t\d+)\)\.val\(\);\n', text):
    fk = tdef.pop(m.group(2), None)
    if fk is None: tdef['?'] = None; continue
    scale.append((m.group(1), fk[0], fk[1]))
for m in re.finditer(r'    model\.su\.r\[(\d+)\] = \(S\.con\(model\.(\w+)\)\)\.val\(\);\n', text): copy.append((m.group(1), m.group(2)))
rest = re.sub(r'    const t\d+ = S\.con\(\(model\.\w+\) \* \(.+?\)\);\n|    model\.su\.r\[\d+\] = \(t\d+\)\.val\(\);\n|    model\.su\.r\[\d+\] = \(S\.con\(model\.\w+\)\)\.val\(\);\n', '', text)
want = 'pubfnsetup(comptimeV:type,model:*Model)void{@setFloatMode(.strict);constS=V;if(std.debug.runtime_safetyandcontract.validating)model.su_ok=true;return;}'
setup_ok = bool(scale or copy) and not tdef and re.sub(r'\s+', '', rest) == want
if setup_ok:
    new = ['/// Setup slots as data: slot = field * factor, and slot = field.',
           'const SetupScale = struct { k: f64, dst: u32, off: u32 };',
           'const setup_scale = [_]SetupScale{'] + [f'    .{{ .k = {k}, .dst = {d}, .off = @offsetOf(Model, "{f}") }},' for d, f, k in scale] + ['};',
           'const SetupCopy = struct { dst: u32, off: u32 };',
           'const setup_copy = [_]SetupCopy{'] + [f'    .{{ .dst = {d}, .off = @offsetOf(Model, "{f}") }},' for d, f in copy] + ['};', '',
           'pub fn setup(comptime V: type, model: *Model) void {', '    @setFloatMode(.strict);', '    _ = V;',
           '    const base: [*]const u8 = @ptrCast(model);',
           '    for (&setup_scale) |*r| model.su.r[r.dst] = @as(*const f64, @ptrCast(@alignCast(base + r.off))).* * r.k;',
           '    for (&setup_copy) |*r| model.su.r[r.dst] = @as(*const f64, @ptrCast(@alignCast(base + r.off))).*;',
           '    if (std.debug.runtime_safety and contract.validating) model.su_ok = true;', '    return;', '}', '']
    src = src[:i] + '\n'.join(new) + src[j:]
open(sys.argv[2], 'w').write(src)
print(f'checkRange: ' + (f'{n_range} parameters in {len(runs)} runs' if check_ok else 'left as emitted') + '; setup: ' + (f'{len(scale)} scaled slots, {len(copy)} copied slots' if setup_ok else 'left as emitted'))
