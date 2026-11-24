"""Peak snapshot of a massif file -> the largest frames under the allocator, by bytes."""
import re, sys, collections
lines = open(sys.argv[1]).read().split('\n')
peak = None; i = 0
snaps = []
while i < len(lines):
    if lines[i].startswith('snapshot='):
        j = i; d = {}
        while j < len(lines) and not lines[j].startswith('heap_tree='): 
            k, _, v = lines[j].partition('='); d[k] = v; j += 1
        kind = lines[j].split('=')[1] if j < len(lines) else 'empty'
        snaps.append((int(d.get('mem_heap_B', 0)), kind, j))
        i = j + 1; continue
    i += 1
best = max(s for s in snaps if s[1] in ('peak', 'detailed'))
j = best[2] + 1
print('peak bytes', best[0], 'kind', best[1])
# walk tree; record each node's bytes at depth and its label
agg = collections.Counter()
stack = []
while j < len(lines) and lines[j].strip().startswith('n'):
    line = lines[j]; ind = len(line) - len(line.lstrip())
    m = re.match(r'\s*n(\d+): (\d+) (.*)', line)
    if not m: break
    stack = stack[:ind]; stack.append(m.group(3))
    fn = re.search(r': (\S+) \(', m.group(3))
    name = fn.group(1) if fn else m.group(3)[:60]
    if int(m.group(1)) == 0:  # leaf: attribute bytes to the first vera frame that names a stage
        path = ' <- '.join(re.sub(r'^0x[0-9A-F]+: ', '', s).split(' (')[0] for s in stack[1:])
        agg[path[:400]] += int(m.group(2))
    j += 1
for p, b in agg.most_common(int(sys.argv[2]) if len(sys.argv) > 2 else 12):
    print(f"{b/1048576:7.2f} MiB  {p[:330]}")
