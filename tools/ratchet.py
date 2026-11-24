#!/usr/bin/env python3
"""Ratchet lists for the rewrite: named violations that may only shrink.

Each check scans the tree and prints one name per violation. A name is
`path:function:detail`, never a line number, so an edit above it does not
move it. `tools/ratchet/<check>.txt` is the baseline: the names allowed to
fail today. The run fails on a name not in the baseline (a new violation)
and on a baseline name that no longer fails (stale: delete its line).
That is `tools/vera.xfail`'s contract, by name, never by count.

Checks:
  emit-sites   a diagnostic code named outside `lib/diag/codes/` and the
               code's own report function: target, every code worded once
  lower-rules  a `src/analog` function that reports a rule: target, none
               (the rules live in the semantic stage)
  lower-mixed  a `src/analog` function that both reports a rule and emits
               MIR: target, none (split into a check and a builder)
  structure    a function over 70 code lines, nested over 4 levels or
               taking over 5 parameters, or a struct over 24 fields

Usage:
  ratchet.py check [CHECK...]     compare against the baselines (default: all)
  ratchet.py list CHECK           print the current names
  ratchet.py update [CHECK...]    rewrite the baselines from the tree
  ratchet.py --self-test
"""

import os
import re
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE_DIR = os.path.join(ROOT, "tools", "ratchet")
CODE_RE = re.compile(r"\.([EW]\d{4})\b")
FN_RE = re.compile(r"^(\s*)(pub\s+)?(inline\s+|export\s+|extern\s+)*fn\s+(@?\"?[\w.]+\"?)\s*\(")
REPORT_RE = re.compile(r"\b(err|errWith|warn|warnWith|fail|failWith|refuse)\(|\.build\(|\bbag\.add\(")
BUILD_RE = re.compile(r"\b(self|l|lo|lower)\.(emit|emitAnew|call|gotoBlock|branchTo|startUnreachable)\("
                      r"|\bmir\.(emit\w*|addBlock|addFloatConst|addIntConst)\(")
# A line that names a code as data for a test, not an emit: a table row's
# `.code = .E0101`, `.want = ...`, or an `expect...(` call.
TEST_ROW_RE = re.compile(r"\.(code|want|expect\w*|verdict)\s*=\s*\.[EW]\d{4}|\b\w*[eE]xpect\w*\(")
# The home of a code's one report function, once the rewrite adds it.
REPORT_HOME = "lib/diag/report/"

LIMITS = {"body": 70, "depth": 4, "params": 5, "fields": 24}


class Fn:
    """One function: its name, header line index, body lines (comments stripped)."""

    def __init__(self, name, start, sig, body, indent):
        self.name, self.start, self.sig, self.body, self.indent = name, start, sig, body, indent


def zig_files(root, tops):
    for top in tops:
        for dp, dn, fns in os.walk(os.path.join(root, top)):
            dn[:] = sorted(d for d in dn if d not in {".zig-cache", "zig-out"})
            for f in sorted(fns):
                if f.endswith(".zig"):
                    p = os.path.join(dp, f)
                    yield os.path.relpath(p, root).replace(os.sep, "/"), p


def strip(line):
    """The line without its `//` comment (string contents are rare enough to ignore)."""
    return line.split("//", 1)[0]


def functions(lines):
    """Every non-test function with a body, outermost and nested alike."""
    in_test = False
    i = 0
    while i < len(lines):
        line = lines[i]
        if re.match(r"^test\b.*\{\s*$", line):
            in_test = True
        elif in_test and line.startswith("}"):
            in_test = False
        m = FN_RE.match(line)
        if m and not in_test:
            indent, j, sig = m.group(1), i, ""
            while j < len(lines) and not lines[j].rstrip().endswith(("{", ";")):
                sig += lines[j]
                j += 1
            if j >= len(lines) or lines[j].rstrip().endswith(";"):
                i = j + 1
                continue
            sig += lines[j]
            k = j + 1
            while k < len(lines) and lines[k] != indent + "}":
                k += 1
            body = [strip(x) for x in lines[j + 1:k]]
            yield Fn(m.group(4), i, sig, body, indent)
        i += 1


def check_emit_sites(root):
    out = set()
    for rel, p in zig_files(root, ("src", "lib")):
        if rel.startswith("lib/diag/codes/") or rel.startswith(REPORT_HOME):
            continue
        lines = open(p, encoding="utf-8", errors="replace").read().split("\n")
        in_test = False
        owner = "(file)"
        for line in lines:
            if re.match(r"^test\b.*\{\s*$", line):
                in_test = True
            elif in_test and line.startswith("}"):
                in_test = False
            m = FN_RE.match(line)
            if m:
                owner = m.group(4)
            code = strip(line)
            if in_test or TEST_ROW_RE.search(code):
                continue
            for c in CODE_RE.findall(code):
                out.add(f"{rel}:{owner}:{c}")
    return out


def analog_fns(root):
    for rel, p in zig_files(root, ("src/analog",)):
        lines = open(p, encoding="utf-8", errors="replace").read().split("\n")
        for fn in functions(lines):
            yield rel, fn


def check_lower(root, mixed):
    out = set()
    for rel, fn in analog_fns(root):
        text = "\n".join(fn.body)
        reports = REPORT_RE.search(text) and CODE_RE.search(text)
        builds = BUILD_RE.search(text)
        if reports and (builds or not mixed):
            codes = ",".join(sorted(set(CODE_RE.findall(text))))
            out.add(f"{rel}:{fn.name}:{codes}")
    return out


def params_of(sig):
    inner = sig[sig.index("(") + 1:]
    depth, cur, parts = 0, "", []
    for ch in inner:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            if depth == 0:
                break
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    parts.append(cur)
    return len([x for x in parts if x.strip()])


def check_structure(root):
    out = set()
    for rel, p in zig_files(root, ("src", "lib")):
        lines = open(p, encoding="utf-8", errors="replace").read().split("\n")
        for fn in functions(lines):
            if fn.name[:1].isupper():  # a type-returning function is a type, not a routine
                continue
            code = [x for x in fn.body if x.strip()]
            depth = max([(len(x) - len(x.lstrip(" ")) - len(fn.indent)) // 4 for x in code] or [0])
            if len(code) > LIMITS["body"]:
                out.add(f"{rel}:{fn.name}:long-function")
            if depth > LIMITS["depth"]:
                out.add(f"{rel}:{fn.name}:deep-nesting")
            if params_of(fn.sig) > LIMITS["params"]:
                out.add(f"{rel}:{fn.name}:many-parameters")
        fields = sum(1 for x in lines if re.match(r"^[a-z_]\w*\s*:\s*.+,\s*(//.*)?$", x))
        if fields > LIMITS["fields"]:
            out.add(f"{rel}:(file struct):wide-struct")
        for i, line in enumerate(lines):
            sm = re.match(r"^(\s*)(pub\s+)?const\s+(\w+)\s*=\s*(extern\s+|packed\s+)?struct\s*(\([^)]*\))?\s*\{\s*$", line)
            if not sm:
                continue
            ind, k, nf = sm.group(1), i + 1, 0
            while k < len(lines) and lines[k] != ind + "};":
                if re.match(r"^" + ind + r"    @?\"?\w+\"?\s*:\s*.+,\s*(//.*)?$", lines[k]):
                    nf += 1
                k += 1
            if nf > LIMITS["fields"]:
                out.add(f"{rel}:{sm.group(3)}:wide-struct")
    return out


CHECKS = {
    "emit-sites": check_emit_sites,
    "lower-rules": lambda r: check_lower(r, mixed=False),
    "lower-mixed": lambda r: check_lower(r, mixed=True),
    "structure": check_structure,
}


def baseline_path(name, base_dir):
    return os.path.join(base_dir, name + ".txt")


def read_baseline(name, base_dir):
    p = baseline_path(name, base_dir)
    if not os.path.exists(p):
        return set()
    return {ln.strip() for ln in open(p, encoding="utf-8") if ln.strip() and not ln.startswith("#")}


def write_baseline(name, names, base_dir):
    os.makedirs(base_dir, exist_ok=True)
    with open(baseline_path(name, base_dir), "w", encoding="utf-8") as fh:
        fh.write(f"# tools/ratchet.py {name}: names allowed to fail. Delete a line when it passes; never add one.\n")
        for n in sorted(names):
            fh.write(n + "\n")


def run_check(names, root, base_dir):
    bad = 0
    for name in names:
        got, allowed = CHECKS[name](root), read_baseline(name, base_dir)
        for n in sorted(got - allowed):
            print(f"NEW   {name}: {n}")
            bad += 1
        for n in sorted(allowed - got):
            print(f"STALE {name}: {n} (passes now: delete its line from tools/ratchet/{name}.txt)")
            bad += 1
        print(f"{name}: {len(got)} named, {len(allowed)} in baseline")
    return 1 if bad else 0


def self_test():
    src = (
        "const std = @import(\"std\");\n"
        "fn mixed(self: *Lower) !void {\n"
        "    try self.err(0, .E0421, \"x\", .{});\n"
        "    _ = try self.emit(.add, &.{});\n"
        "}\n"
        "fn check(self: *Lower) !void {\n"
        "    try self.err(0, .E0327, \"y\", .{});\n"
        "}\n"
        "fn build(self: *Lower) !void {\n"
        "    _ = try self.emit(.add, &.{});\n"
        "}\n"
        "test \"rows\" {\n"
        "    try expectVerdict(\"\", .E0999);\n"
        "}\n"
    )
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, "src", "analog"))
        open(os.path.join(d, "src", "analog", "a.zig"), "w").write(src)
        assert check_lower(d, mixed=True) == {"src/analog/a.zig:mixed:E0421"}, check_lower(d, True)
        assert check_lower(d, mixed=False) == {"src/analog/a.zig:mixed:E0421", "src/analog/a.zig:check:E0327"}
        sites = check_emit_sites(d)
        assert sites == {"src/analog/a.zig:mixed:E0421", "src/analog/a.zig:check:E0327"}, sites
        base = os.path.join(d, "base")
        write_baseline("lower-mixed", {"src/analog/a.zig:mixed:E0421"}, base)
        assert run_check(["lower-mixed"], d, base) == 0
        write_baseline("lower-mixed", {"src/analog/a.zig:gone:E0001"}, base)
        assert run_check(["lower-mixed"], d, base) == 1  # one NEW, one STALE
        long_fn = "fn f(a: u8, b: u8, c: u8, d: u8, e: u8, g: u8) void {\n" + "    x();\n" * 71 + "}\n"
        open(os.path.join(d, "src", "analog", "b.zig"), "w").write(long_fn)
        s = check_structure(d)
        assert "src/analog/b.zig:f:long-function" in s and "src/analog/b.zig:f:many-parameters" in s, s
    print("ratchet: self-test passed")
    return 0


def main(argv):
    if argv[1:] == ["--self-test"]:
        return self_test()
    if len(argv) < 2 or argv[1] not in {"check", "list", "update"}:
        print(__doc__)
        return 2
    names = argv[2:] or sorted(CHECKS)
    unknown = [n for n in names if n not in CHECKS]
    if unknown:
        print(f"unknown check: {' '.join(unknown)}; known: {' '.join(sorted(CHECKS))}")
        return 2
    if argv[1] == "list":
        for n in sorted(CHECKS[names[0]](ROOT)):
            print(n)
        return 0
    if argv[1] == "update":
        for n in names:
            write_baseline(n, CHECKS[n](ROOT), BASELINE_DIR)
            print(f"{n}: baseline written")
        return 0
    return run_check(names, ROOT, BASELINE_DIR)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
