#!/usr/bin/env python3
"""Classify every known-failure line: one symptom type (what the oracle sees) and one root-cause
category (what has to change). A comp line borrows its category from the stage list that names
the same fixture, since comp's own line often says only `exit status`.
Usage: xfail_classes.py <repo> <out.tsv>"""
import collections, re, sys
from pathlib import Path

repo, out = Path(sys.argv[1]), Path(sys.argv[2])
JUDGED = ["comp", "digital_exe", "digital_device", "rtlil", "native"]
DIAG = re.compile(r"(error|warning|note)\[([EWN]\d+)\]")


def rows(name):
    p = repo / name
    if not p.exists():
        return []
    return [l for l in p.read_bytes().decode("utf-8", "replace").split("\n") if l.strip() and not l.lstrip().startswith("#")]


def norm(s):
    s = re.sub(r"`[^`]*`", "`…`", s)
    return re.sub(r"\d+(\.\d+)?(e-?\d+)?", "N", s).strip()


def old_new(d):
    """The two quoted sides of a `line N: old `X`, new `Y`` difference."""
    i, j = d.find("old `"), d.rfind(", new `")
    if i < 0 or j < 0:
        return "", ""
    return d[i + 5 : j].rstrip("`"), d[j + 7 :].rstrip("`")


def code(s):
    m = DIAG.search(s)
    return m.group(2) if m else ""


stage = {}  # path -> (list, category) from the stage lists, which say why


def put(path, lst, cat):
    stage.setdefault(path, (lst, cat))


out_rows = []


def emit(lst, path, owner, kind, typ, cat):
    out_rows.append((lst, path, owner, kind, typ, cat))


for l in rows("tests/differential/lower.xfail"):
    path, d = l.split(" ", 1)
    m = re.match(r"codes: old (\S+), new (\S+)(?: \((E\d+): (.*)\))?$", d)
    if m:
        o, n, _, why = m.groups()
        if o == "{}":
            typ = "new refuses"
        elif n == "{}":
            typ = "new accepts"
        else:
            typ = "wrong code"
        cat = "lower: " + norm(why) if why else f"lower: {o} not raised" if n == "{}" else f"lower: old {o}, new {n}"
    elif d.startswith(("tables row", "contribution", "values:")):
        typ, cat = "wrong number", "lower: " + norm(d.split(":")[0])
    else:
        typ, cat = "other", "lower: " + norm(d)[:60]
    emit("lower", path, "rw-lower", "", typ, cat)
    put(path, "lower", cat)

for l in rows("tests/differential/codegen.xfail"):
    path, d = l.split(" ", 1)
    d = d.removeprefix("codegen: ")
    m = re.match(r"a call of `([^`]*)`", d)
    if m:
        typ, cat = "new refuses", f"codegen: call `{m.group(1)}`"
    elif d.startswith(("point", "the display", "row")):
        typ, cat = "wrong number", "codegen: " + norm(d.split(":")[0])[:50]
    elif "does not build" in d:
        typ, cat = "new does not build", "codegen: device does not build"
    else:
        typ, cat = "new refuses", "codegen: " + norm(d)[:70]
    emit("codegen", path, "rw-codegen", "", typ, cat)
    put(path, "codegen", cat)

for l in rows("tests/differential/sim.xfail"):
    path, d = l.split(" ", 1)
    if d.startswith("old run failed"):
        typ, cat = "new accepts", "dlower: " + norm(re.sub(r"^old run failed \((E\d+): ", "", d).split(")")[0])[:60]
    elif d.startswith("run diagnostic"):
        typ, cat = "message text", "dlower: timing-check run diagnostic text"
    else:
        typ, cat = "other", "dlower: " + norm(d)[:60]
    emit("sim", path, "rw-dlower", "", typ, cat)
    put(path, "sim", cat)

for lst in JUDGED:
    for l in rows(f"tests/differential/{lst}.xfail"):
        m = re.match(r"(\S+) (not built|rw-[\w-]+(?: \([^)]*\))?)(?: (message|location|notes))?: (.*)$", l)
        if not m:
            emit(lst, l.split(" ", 1)[0], "?", "", "unparsed", "unparsed")
            continue
        path, owner, kind, d = m.groups()
        kind = kind or ""
        if owner == "not built" or d.startswith("backend "):
            emit(lst, path, "not built", "", "not built", "backend " + d.split()[1] if d.startswith("backend ") else "not built")
            continue
        e = re.match(r"exit status old (\d+), new (\d+)", d)
        if e:
            a, b = int(e.group(1)), int(e.group(2))
            typ = {(0, 1): "new refuses", (1, 0): "new accepts"}.get((a, b), f"abnormal exit {a}->{b}")
        elif d.startswith("stderr"):
            o, n = old_new(d)
            co, cn = code(o), code(n)
            if kind == "message":
                typ = "message text"
            elif kind == "location":
                typ = "location"
            elif kind == "notes":
                typ = "notes"
            elif co and cn and co != cn:
                typ = "wrong code"
            elif co and not cn:
                typ = "missing diagnostic"
            elif cn and not co:
                typ = "extra diagnostic"
            else:
                typ = "message text"
        elif d.startswith("stdout"):
            typ = "wrong number"
        else:
            typ = "other"
        st = stage.get(path)
        if st and owner.split()[0] in ("rw-lower", "rw-codegen", "rw-dlower"):
            cat = st[1]
        elif typ in ("message text", "location", "notes", "wrong code", "missing diagnostic", "extra diagnostic"):
            o, n = old_new(d)
            c = code(n) or code(o) or "no code"
            cat = f"{owner.split()[0].removeprefix('rw-')}: {typ} {c}"
        else:
            cat = f"{owner.split()[0].removeprefix('rw-')}: {typ} (no stage reason)"
        emit(lst, path, owner, kind, typ, cat)

for l in rows("tools/diag_gaps.xfail"):
    gate, what = l.split("#")[0].split()[:2]
    emit("diag_gaps", what, "diagcodes", "", f"coverage: {gate}", f"diagcodes: {gate}")

with out.open("w") as f:
    f.write("list\tpath\towner\tkind\ttype\tcategory\n")
    for r in out_rows:
        f.write("\t".join(r) + "\n")

by_list = collections.Counter(r[0] for r in out_rows)
print("lines by list:", dict(by_list.most_common()))
t = collections.Counter((r[4]) for r in out_rows if r[0] != "diag_gaps")
print("\ntype (differential lists):")
for k, n in t.most_common():
    print(f"  {n:5} {k}")
c = collections.Counter(r[5] for r in out_rows if r[0] != "diag_gaps")
fx = collections.defaultdict(set)
for r in out_rows:
    fx[r[5]].add(r[1])
print(f"\n{len(c)} categories; top 60 by lines (fixtures):")
for k, n in c.most_common(60):
    print(f"  {n:5} ({len(fx[k]):4}) {k}")
print("\nunparsed:", sum(1 for r in out_rows if r[4] == "unparsed"))
diff = [r for r in out_rows if r[0] != "diag_gaps"]
print("fixtures in the differential lists:", len({r[1] for r in diff}))
ft = collections.defaultdict(set)
for r in diff:
    ft[r[4]].add(r[1])
print("fixtures by type:", {k: len(v) for k, v in sorted(ft.items(), key=lambda x: -len(x[1]))})
own = collections.Counter((r[2].split()[0], r[4]) for r in diff)
owners = sorted({o for o, _ in own}, key=lambda o: -sum(n for (x, _), n in own.items() if x == o))
types = [k for k, _ in t.most_common()]
print("\nowner x type (lines):")
print("owner".ljust(12) + "".join(x[:10].rjust(11) for x in types))
for o in owners:
    print(o.ljust(12) + "".join(str(own.get((o, x), "")).rjust(11) for x in types))
