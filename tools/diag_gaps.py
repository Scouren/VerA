#!/usr/bin/env python3
"""Joins VerA's diagnostic catalogue to the two specification ledgers and
reports, and gates, the join (research/diagcodes.md).

    tools/diag_gaps.py report [--tsv PATH]     # the clause tables + gate summary
    tools/diag_gaps.py check                   # report's gates, exit 0/1, no tables
    tools/diag_gaps.py selftest                 # this script's own oracle
    tools/diag_gaps.py ledger --std AMS|V2005 [--show CLAUSE] [--update] [--write] [--ledger-dir DIR]

In: `lib/std/vams/Diag/codes.zon` (the catalogue), `src/**` and `lib/**` (raise
sites), `tests/conformance/tests/**` and `tests/conformance/vera/{rtlil,osdi,
beh_verilog,host}` (fixture `//!` directives), `tests/conformance/vera/ledger/
OBLIGATIONS*.tsv` (the AMS and IEEE 1364 requirement ledgers), `tools/vera.xfail`
and `tests/conformance/vera/xfail` (named unsup evidence), `tools/diag_gaps.xfail`
(this script's own known misses). Out: a per-clause verdict table (`report`), a
gated pass/fail (`check`), or a refreshed `OBLIGATIONS-1364.tsv` seed (`ledger`).

`ledger --update` never writes the submodule unless `--write` is also given
(tests/conformance is the user's repo, never dirtied by a dry run); its
default prints the would-be match/moved/added/vanished counts only.
"""
import argparse
import collections
import hashlib
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import conformance  # noqa: E402  (LRM_SHA256, IEEE_SHA256: one place for the pins)

SUBMODULE = ROOT / "tests/conformance"
DEFAULT_LEDGER_DIR = SUBMODULE / "vera/ledger"
CLAUSES_DIR = SUBMODULE / "vera/clauses"
FIXTURE_ROOTS = (SUBMODULE / "tests", SUBMODULE / "vera/rtlil", SUBMODULE / "vera/osdi",
                  SUBMODULE / "vera/beh_verilog", SUBMODULE / "vera/host")
CODES_ZON = ROOT / "lib/std/vams/Diag/codes.zon"
RAISE_ROOTS = (ROOT / "lib", ROOT / "src")
RAISE_SKIP = (ROOT / "lib/std/vams/Diag", ROOT / "lib/diag/codes")
VERA_XFAIL = SUBMODULE / "vera/xfail"
TOOLS_XFAIL = ROOT / "tools/vera.xfail"
DIAG_XFAIL = ROOT / "tools/diag_gaps.xfail"
LRM_PDF = ROOT / "docs/specification/VAMS-LRM-2023.pdf"
IEEE_PDF = ROOT / "docs/specification/1364-2005.pdf"
IEEE_CLAUSES_TSV = CLAUSES_DIR / "ieee1364/CLAUSES.tsv"

CODE_RE = re.compile(r"^[EW][0-9]{4}$")

Row = collections.namedtuple("Row", "name kind std clause also severity")

# ---------------------------------------------------------------------------
# codes.zon: a ~30-line ZON-subset reader (research/diagcodes.md §1.3)
# ---------------------------------------------------------------------------

ROW_START = re.compile(r'^    \.(\w+) = \.\{$')
FIELD = re.compile(r'^        \.(\w+) = (?:"((?:[^"\\]|\\.)*)"|\.(\w+))')


def read_codes(path=CODES_ZON):
    """{name: Row}, in file order. Before C6b the ZON key *is* the code's
    spelling (`E0415`); `aliases` are therefore just {name} (checked here
    against `code.zig`'s `specRow`, which does the same)."""
    text = path.read_text()
    rows = {}
    name = None
    fields = {}
    starts = 0
    for line in text.splitlines():
        m = ROW_START.match(line)
        if m:
            starts += 1
            name, fields = m.group(1), {}
            continue
        if name is None:
            continue
        fm = FIELD.match(line)
        if fm:
            key, s, enum_v = fm.groups()
            fields[key] = s if s is not None else enum_v
        if line.strip() == "},":
            rows[name] = Row(
                name=name,
                kind=fields.get("kind", "rule"),
                std=fields.get("std", "none"),
                clause=fields.get("clause", ""),
                also=fields.get("also", ""),
                severity=fields.get("severity", "warning" if name[0] == "W" else "err"),
            )
            name = None
    assert len(rows) == starts, f"parsed {len(rows)} rows but saw {starts} row starts"
    return rows


def row_clauses(row):
    """[(std, clause), ...] a row's own clause plus `also`, lowercase std."""
    out = []
    if row.clause:
        out.append((row.std, row.clause))
    if row.also:
        std, _, clause = row.also.partition("-")
        out.append((std.lower(), clause))
    return out


# ---------------------------------------------------------------------------
# raise sites: a dotted tag or a bracketed/quoted spelling, anywhere in
# lib/** or src/**, skipping the catalogue's own directories and `test { }`
# blocks (research/diagcodes.md §1.3)
# ---------------------------------------------------------------------------

TEST_START = re.compile(r'\btest\s+(?:"(?:[^"\\]|\\.)*"\s*)?\{')
UNKNOWN_RE = re.compile(r"\[([EW][0-9]{4})\]|\"([EW][0-9]{4})\"")


def strip_test_blocks(text):
    """Removes every `test { ... }` body by brace depth, string-naively
    (good enough: fixture-grade Zig, never adversarial)."""
    out = []
    i = 0
    for m in TEST_START.finditer(text):
        if m.start() < i:
            continue
        out.append(text[i:m.start()])
        depth = 1
        j = m.end()
        while j < len(text) and depth:
            if text[j] == "{":
                depth += 1
            elif text[j] == "}":
                depth -= 1
            j += 1
        i = j
    out.append(text[i:])
    return "".join(out)


def source_files():
    for root in RAISE_ROOTS:
        for path in root.rglob("*"):
            if not path.is_file() or path.suffix not in (".zig", ".txt"):
                continue
            if path.suffix == ".txt" and not path.name.endswith(".zig.txt"):
                continue
            if any(skip in path.parents for skip in RAISE_SKIP):
                continue
            yield path


def scan_raises(names):
    """{spelling: [(path, lineno), ...]} for every catalogue spelling found
    as a `.tag` token or a bracketed/quoted string, plus every bracketed or
    quoted `[EW]\\d{4}` spelling that names no row (`unknown`, keyed "")."""
    tagged = {re.compile(r"\." + re.escape(n) + r"\b"): n for n in names}
    raises = collections.defaultdict(list)
    unknown = collections.defaultdict(list)
    for path in source_files():
        text = strip_test_blocks(path.read_text(errors="replace"))
        for lineno, line in enumerate(text.splitlines(), 1):
            for pattern, name in tagged.items():
                if pattern.search(line):
                    raises[name].append((path, lineno))
            for um in UNKNOWN_RE.finditer(line):
                spelling = um.group(1) or um.group(2)
                if spelling in names:
                    raises[spelling].append((path, lineno))
                else:
                    unknown[spelling].append((path, lineno))
    return raises, unknown


def wording_hits(raises, codes):
    """Code names whose first raise site's string literal, within 6 lines
    after the token, reads like an engine refusal (`wording` gate) while the
    row's own kind says it is a checked rule."""
    bad_re = re.compile(r"\byet\b|not implemented|not lowered|unsupported|cannot render", re.I)
    lit_re = re.compile(r'"((?:[^"\\]|\\.)*)"')
    hits = set()
    for name, sites in raises.items():
        row = codes.get(name)
        if row is None or row.kind in ("unsup", "limit", "ice", "retired"):
            continue
        path, lineno = sites[0]
        lines = path.read_text(errors="replace").splitlines()
        window = "\n".join(lines[lineno - 1:lineno + 6])
        lm = lit_re.search(window)
        if lm and bad_re.search(lm.group(1)):
            hits.add(name)
    return hits


# ---------------------------------------------------------------------------
# fixtures: the `//!` directives of every file under the fixture roots
# (research/diagcodes.md §1.4)
# ---------------------------------------------------------------------------

NUMBERED = re.compile(r"^[0-9A-H](?:\.[0-9]+)*$")


def fixture_files():
    for root in FIXTURE_ROOTS:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if path.is_file():
                yield path


def directive_lines(path):
    lines = path.read_text(errors="replace").splitlines()
    return [ln.strip()[3:].strip() for ln in lines if ln.strip().startswith("//!")][:64]


def scan_fixtures():
    """(uses, cites): uses[spelling] = [path, ...] from reject/reject-only/
    reject-run/warn; cites[path] = [(std, clause), ...] from lrm/inherited
    (+ -reject variants). `std` is "ams" for `lrm`, "v2005" for `inherited`."""
    uses = collections.defaultdict(list)
    cites = collections.defaultdict(list)
    for path in fixture_files():
        rel = str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path)
        for directive in directive_lines(path):
            word, _, rest = directive.partition(" ")
            rest = rest.strip()
            if word in ("reject", "reject-only", "reject-run", "warn"):
                for token in rest.split():
                    if CODE_RE.match(token):
                        uses[token].append(rel)
            elif word in ("lrm", "lrm-reject"):
                clause = rest.split(":", 1)[0].strip()
                if clause:
                    cites[rel].append(("ams", clause))
            elif word in ("inherited", "inherited-reject"):
                tokens = [t for t in rest.split() if NUMBERED.match(t) and t != "1364"]
                if tokens:
                    cites[rel].append(("v2005", tokens[-1]))
    return uses, cites


# ---------------------------------------------------------------------------
# xfail lists (research/diagcodes.md §1.4, §1.7)
# ---------------------------------------------------------------------------

def read_path_xfail(path):
    """{reason-named path -> reason} from a `<path> # reason` list."""
    out = {}
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        body, _, reason = line.partition("#")
        body = body.strip()
        if body and not line.lstrip().startswith("#"):
            out[body] = reason.strip()
    return out


def listed_unsup(name, vera_xfail, tools_xfail):
    """True when some xfail reason names `name` and that line's path exists."""
    for xfail, base in ((vera_xfail, SUBMODULE), (tools_xfail, ROOT)):
        for path, reason in xfail.items():
            if name in reason and (base / path).exists():
                return True
    return False


def read_diag_xfail(path=DIAG_XFAIL):
    """{gate: {subject, ...}} from `<gate> <subject> # reason` lines."""
    out = collections.defaultdict(set)
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        body, _, _ = line.partition("#")
        parts = body.split()
        if len(parts) >= 2:
            out[parts[0]].add(parts[1])
    return out


# ---------------------------------------------------------------------------
# AMS ledger extraction from the PDF (restores the `obligations` extractor
# tools/conformance.py's header used to name; research/diagcodes.md §1.2)
# ---------------------------------------------------------------------------

AMS_SECTION = re.compile(r"^((?:[1-9][0-9]?|[A-H])(?:\.[0-9]+)+)\s+(.+)$")
AMS_CHAPTER = re.compile(r"^([1-9][0-9]?)\.\s+([A-Z].+)$")
MANUAL_ORDINAL = 1000
MODALS = [
    ("shall-not", re.compile(r"\bshall not\b|\bshall never\b|\bshall neither\b")),
    ("error", re.compile(r"\bis (?:an |)(?:error|illegal)\b|\bshall be an error\b|\bare (?:errors|illegal)\b"
                         r"|\bnot (?:be |)(?:allowed|permitted)\b|\billegal\b|\berror shall be\b"
                         r"|\bshall (?:report|issue|flag|generate|produce) an? error\b"
                         r"|\bshall be (?:reported|flagged) as an? error\b")),
    ("shall", re.compile(r"\bshall\b")),
    ("must", re.compile(r"\bmust\b")),
    ("impl-defined", re.compile(r"\bimplementation[- ](?:defined|dependent|specific)\b")),
    ("unspecified", re.compile(r"\bunspecified\b|\bundefined\b")),
    ("may", re.compile(r"\bmay\b|\bis optional\b|\bare optional\b")),
]
KIND_DEFAULT = {
    "non-normative": ("0", "non-normative"), "optional": ("0", "optional"),
    "unspecified": ("0", "unspecified"), "not-supported": ("0", "not-supported"),
    "no-prohibition": ("+", "-"), "implementation-defined": ("+", "implementation-defined"),
    "resource-limit": ("+-", "resource-limit"),
}
LEDGER_COLUMNS = ("id", "hash", "modal", "pol", "kind", "oracle", "text")
LEDGER_HEAD = (
    "# The AMS LRM's normative sentences: the requirement ledger.\n"
    "# Rows are extracted by `tools/diag_gaps.py ledger --update --std AMS`; a\n"
    "# reader classifies `pol`, `kind` and `oracle` and adds `declar.` rows\n"
    "# (ordinal >= 1000, hash `manual`) for rules stated without a modal verb.\n"
    "# A changed hash means the text moved, and the row's classification is\n"
    "# reset to `?` for a re-read.\n"
    "# id\thash\tmodal\tpol\tkind\toracle\ttext\n"
)


def pdftotext(pdf):
    return subprocess.run(["pdftotext", "-layout", str(pdf), "-"], capture_output=True, text=True, check=True).stdout


def ams_sections(pdf):
    """{clause: {title, page, text}}, ported from `pdf_sections` (tools/
    conformance.py before 2fbfcd28; reference only, not read at run time)."""
    sections = {}
    current = chapter = None
    started = False
    for page, text in enumerate(pdftotext(pdf).split("\f"), 1):
        lines = text.splitlines()
        if not started:
            if "1. Verilog-AMS introduction" not in lines:
                continue
            started = True
        for index, line in enumerate(lines):
            stripped = line.strip()
            if (not stripped or "Accellera Std VAMS-2023" in line
                    or "Accellera Standard for VERILOG-AMS" in line
                    or "Copyright © 2024 Accellera" in line
                    or (re.fullmatch(r"\d+", stripped) and
                        next((t.strip() for t in lines[index + 1:] if t.strip()), "")
                        .startswith("Copyright © 2024 Accellera"))):
                continue
            top = AMS_CHAPTER.match(stripped) or re.fullmatch(r"Annex ([A-H])", stripped)
            sec = AMS_SECTION.match(stripped)
            new_id = None
            if top:
                proposed = top.group(1)
                order = [str(n) for n in range(1, 13)] + list("ABCDEFGH")
                expected = order[0] if chapter is None else (
                    order[order.index(chapter) + 1] if chapter != "H" else None)
                if proposed == expected and (current != "1.5" or page >= 24):
                    chapter = proposed
                    new_id = proposed
            elif sec and sec.group(1).split(".")[0] == chapter and sec.group(1) not in sections:
                new_id = sec.group(1)
            if new_id and new_id not in sections:
                current = new_id
                sections[current] = {"title": stripped, "page": page, "text": ""}
            elif current:
                # A list item's own PDF line starts with the literal bullet
                # ("— ") or number ("1) ") glyph; the HTML LRM this ledger
                # was first built from (gone: 2fbfcd28) rendered those via list
                # markup, never as text, so only a line-*leading* one is
                # dropped here. An inline em-dash, which the HTML kept, never
                # opens a physical line.
                body = stripped
                if body.startswith("— "):
                    body = body[2:]
                else:
                    body = re.sub(r"^\d+\)\s+", "", body)
                sections[current]["text"] += body + "\n"
    return sections


def dehyphenate(text):
    # pdftotext -layout keeps the typesetter's line-wrap hyphens
    # ("bind-\ning"); a genuine compound (Verilog-\nAMS) is followed by an
    # uppercase letter and is left alone.
    return re.sub(r"-\n\s*(?=[a-z])", "", text)


def sentences(text):
    flat = re.sub(r"\s+", " ", dehyphenate(text)).strip()
    return [s for s in re.split(r'(?<=[.!?])\s+(?=[A-Z"“(`$])', flat) if s]


def modal(sentence):
    low = sentence.lower()
    for name, pattern in MODALS:
        if pattern.search(low):
            return name
    return None


def sentence_hash(sentence):
    return hashlib.sha256(re.sub(r"\s+", " ", sentence).strip().encode()).hexdigest()[:8]


def extract_modal_sentences(section_text):
    """[(ordinal, hash, modal, sentence), ...] in reading order."""
    rows = []
    for sent in sentences(section_text):
        m = modal(sent)
        if m:
            rows.append((len(rows) + 1, sentence_hash(sent), m, sent))
    return rows


def sort_key(clause):
    return tuple((0, int(p)) if p.isdigit() else (1, p) for p in clause.split("."))


def ledger_sort_key(row_id):
    clause, _, n = row_id.partition(":")
    return sort_key(clause) + ((0, int(n) if n.isdigit() else 0),)


def read_ledger(path):
    rows = {}
    if not path.exists():
        return rows
    for line in path.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        cells = line.split("\t")
        cells += [""] * (len(LEDGER_COLUMNS) - len(cells))
        rows[cells[0]] = dict(zip(LEDGER_COLUMNS, cells))
    return rows


def write_ledger(rows, path, head=LEDGER_HEAD):
    with open(path, "w") as f:
        f.write(head)
        for rid in sorted(rows, key=ledger_sort_key):
            r = rows[rid]
            text = r["text"].replace("\t", " ").replace("\n", " ")
            f.write("\t".join(r.get(c, "") if c != "id" else rid for c in LEDGER_COLUMNS) + "\n")


def clause_kinds():
    """{(std, clause): kind} from every CLAUSES.tsv's non-`-` kind column
    (`std` is "ams" or "ieee"; the ordinary-clause marker `-` is skipped)."""
    out = {}
    for path in sorted(CLAUSES_DIR.rglob("CLAUSES.tsv")):
        std = "ieee" if "ieee1364" in path.parts else "ams"
        for line in path.read_text().splitlines():
            if not line.strip() or line.startswith("#"):
                continue
            cells = line.split("\t")
            if len(cells) > 1 and cells[1].strip() != "-":
                out[(std, cells[0].strip())] = cells[1].strip()
    return out


def default_class(clause, m, sentence, kinds):
    if sentence.startswith("NOTE"):
        return "0", "non-normative"
    k = kinds.get(("ams", clause))
    if k in KIND_DEFAULT:
        return KIND_DEFAULT[k]
    if m in ("shall-not", "error"):
        return "-", "-"
    if m == "unspecified":
        return "0", "unspecified"
    if m == "impl-defined":
        return "+", "implementation-defined"
    return "?", "?"


def merge_ledger(old, found, classify, titles=None):
    """(new_rows, moved, added, vanished): the hash-reset merge every ledger
    refresh shares. `found` is {clause: [(ordinal, hash, modal, sentence),
    ...]}; a row whose hash is unchanged keeps its reviewed columns
    verbatim, and everything else (a new sentence, or one whose text moved)
    resets to `classify`'s default. This is the part the red-first fault
    (research/diagcodes.md A3) exercises without ever reading the PDF."""
    new, moved, added = {}, [], []
    for clause, rows in found.items():
        for n, h, m, sent in rows:
            rid = f"{clause}:{n}"
            prev = old.get(rid)
            if prev and prev["hash"] == h:
                new[rid] = prev
                continue
            pol, kind = classify(clause, m, sent)
            (moved if prev else added).append(rid)
            new[rid] = {"hash": h, "modal": m, "pol": pol, "kind": kind, "oracle": "?", "text": sent[:400]}
        if not rows and titles is not None and titles.get(clause, {}).get("declare", True):
            rid = f"{clause}:{MANUAL_ORDINAL}"
            if rid not in old:
                pol, kind = classify(clause, "declar.", "")
                title = titles[clause]["title"]
                new[rid] = {"hash": "manual", "modal": "declar.", "pol": pol, "kind": kind, "oracle": "?",
                            "text": f"(no modal sentence in §{clause} {title}; state its rules here)"}
    for rid, r in old.items():
        if r["hash"] == "manual":
            new[rid] = r
    vanished = sorted(set(old) - set(new), key=ledger_sort_key)
    return new, moved, added, vanished


def ams_refresh(old, kinds):
    """(new_rows, moved, added, vanished): re-extracts the AMS ledger from
    the pinned PDF and merges it with `old`."""
    sections = ams_sections(LRM_PDF)
    found = {clause: extract_modal_sentences(item["text"]) for clause, item in sections.items()}
    titles = {clause: {"title": item["title"], "declare": kinds.get(("ams", clause)) != "non-normative"}
              for clause, item in sections.items()}

    def classify(clause, m, sent):
        if m == "declar.":
            return KIND_DEFAULT.get(kinds.get(("ams", clause)), ("?", "?"))
        return default_class(clause, m, sent, kinds)

    return merge_ledger(old, found, classify, titles)


# ---------------------------------------------------------------------------
# V2005 (IEEE 1364-2005) ledger seed: driven by the reviewed clause list in
# CLAUSES.tsv, never by a re-derived table of contents (research/
# diagcodes.md §1.2; A1b classifies `pol` by hand afterwards, so the seed
# records no licensed text)
# ---------------------------------------------------------------------------

NEG_RE = re.compile(r"\b(shall not|shall be an error|illegal|is an error|shall be a compil"
                     r"|shall result in an error|shall issue an error|shall be reported)\b", re.I)
IEEE_HEADING = re.compile(r"^\s{0,24}((?:[0-9]+|[A-H])(?:\.[0-9]+)*)\s+(\S.*?)\s*$")


def ieee_clause_titles():
    """{clause: title} from the committed, reviewed heading list: the PDF
    is licensed, so no body text or a re-derived TOC backs this."""
    out = {}
    for line in IEEE_CLAUSES_TSV.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        cells = line.split("\t")
        out[cells[0].strip()] = cells[2].strip() if len(cells) > 2 else ""
    return out


def ieee_sections(pdf, titles):
    """{clause: text}, matching a heading line to `titles` by id and a
    case-insensitive 12-char title prefix (the probe this plan's numbers
    came from; a cross-reference mid-sentence never repeats the title)."""
    sections = collections.defaultdict(list)
    current = None
    for line in pdftotext(pdf).splitlines():
        m = IEEE_HEADING.match(line)
        if m and m.group(1) in titles and titles[m.group(1)][:12].lower() == m.group(2)[:12].lower():
            current = m.group(1)
            continue
        if current:
            sections[current].append(line)
    return {c: "\n".join(ls) for c, ls in sections.items()}


def ieee_seed(old):
    """(new_rows, moved, added, vanished) seeding pol by the prohibition
    regex alone (`-` or `?`); `text` is always "-" (no licensed text)."""
    sections = ieee_sections(IEEE_PDF, ieee_clause_titles())
    found = {clause: extract_modal_sentences(text) for clause, text in sections.items()}
    new, moved, added, vanished = merge_ledger(
        old, found, lambda clause, m, sent: ("-" if NEG_RE.search(sent) else "?", "?"))
    for r in new.values():
        r["text"] = "-"  # the PDF is licensed; CLAUSES.tsv's rule (§1.2) applies here too
    return new, moved, added, vanished


IEEE_LEDGER_HEAD = (
    "# The IEEE 1364-2005 \"shall\" sentences: a seed, not a reviewed ledger\n"
    "# (research/diagcodes.md A1b classifies `pol` by hand next). `text` is\n"
    "# always \"-\": the PDF is licensed and not in git (CLAUSES.tsv's rule), so\n"
    "# `tools/diag_gaps.py ledger --show CLAUSE` reads the sentence from the\n"
    "# local PDF instead of storing it. `pol` is seeded `-` by the prohibition\n"
    "# regex (`shall not`, `illegal`, `is an error`, ...) and `?` otherwise.\n"
    "# id\thash\tmodal\tpol\tkind\toracle\ttext\n"
)


def checkable_clauses(ledger_rows, std):
    """{clause: neg_sentence_count} over every clause with at least one row
    whose `pol` contains "-" and whose `kind` is not non-normative."""
    out = collections.Counter()
    for rid, r in ledger_rows.items():
        if r["kind"] == "non-normative":
            continue
        if "-" in r["pol"]:
            out[rid.partition(":")[0]] += 1
    return out


def clause_related(a, b):
    """True when `a` and `b` are the same clause, or one is a dotted
    ancestor of the other (`cite`'s "equal to, above, or below")."""
    return a == b or a.startswith(b + ".") or b.startswith(a + ".")


# ---------------------------------------------------------------------------
# The join: codes x ledgers x fixtures x xfail -> a `Model`, read by both
# `report` and `check` (research/diagcodes.md §1.1, §1.5-§1.7)
# ---------------------------------------------------------------------------

class Model:
    """Everything `report`/`check`/`selftest` need, computed once. `codes`,
    `raises`, `unknown`, `uses`, `cites` come from the live tree; `ledgers`
    maps "ams"/"v2005" to a ledger dict (empty, never missing, when a
    standard's file does not exist yet)."""

    def __init__(self, codes, raises, unknown, uses, cites, ledgers,
                 vera_xfail, tools_xfail, clause_kinds_map, ledger_missing):
        self.codes = codes
        self.raises = raises
        self.unknown = unknown
        self.uses = uses
        self.cites = cites
        self.ledgers = ledgers
        self.vera_xfail = vera_xfail
        self.tools_xfail = tools_xfail
        self.clause_kinds = clause_kinds_map
        self.ledger_missing = ledger_missing  # set of std names with no ledger file
        self.wording = wording_hits(raises, codes)

    @classmethod
    def build(cls, ledger_dir=DEFAULT_LEDGER_DIR):
        codes = read_codes(CODES_ZON)
        raises, unknown = scan_raises(set(codes))
        uses, cites = scan_fixtures()
        ledgers, missing = {}, set()
        for std, name in (("ams", "OBLIGATIONS.tsv"), ("v2005", "OBLIGATIONS-1364.tsv")):
            path = ledger_dir / name
            if path.exists():
                ledgers[std] = read_ledger(path)
            else:
                ledgers[std] = {}
                missing.add(std)
        return cls(codes, raises, unknown, uses, cites, ledgers,
                    read_path_xfail(VERA_XFAIL), read_path_xfail(TOOLS_XFAIL),
                    clause_kinds(), missing)

    def rule_rows(self, std):
        """{code_name: [clauses]} for every live `rule`/`syntax` row of `std`."""
        out = collections.defaultdict(list)
        for row in self.codes.values():
            if row.kind not in ("rule", "syntax"):
                continue
            for s, c in row_clauses(row):
                if s == std:
                    out[row.name].append(c)
        return out

    def unsup_rows(self, std):
        out = collections.defaultdict(list)
        for row in self.codes.values():
            if row.kind != "unsup":
                continue
            for s, c in row_clauses(row):
                if s == std:
                    out[row.name].append(c)
        return out

    def clause_verdicts(self, std):
        """[(clause, neg, rule_names, unsup_names, verdict, sub)], sorted."""
        ledger = self.ledgers.get(std, {})
        checkable = checkable_clauses(ledger, std)
        rule = self.rule_rows(std)
        unsup = self.unsup_rows(std)
        by_clause_rule = collections.defaultdict(list)
        for name, clauses in rule.items():
            for c in clauses:
                by_clause_rule[c].append(name)
        by_clause_unsup = collections.defaultdict(list)
        for name, clauses in unsup.items():
            for c in clauses:
                by_clause_unsup[c].append(name)
        cited = {c for clauses in self.cites.values() for s, c in clauses if s == std}
        ledgered = {rid.partition(":")[0] for rid in ledger}
        all_clauses = set(checkable) | set(by_clause_rule) | set(by_clause_unsup) | cited | ledgered
        rows = []
        for clause in all_clauses:
            neg = checkable.get(clause, 0)
            rules = sorted(by_clause_rule.get(clause, []))
            unsups = sorted(by_clause_unsup.get(clause, []))
            if neg == 0:
                verdict = "positive-only" if clause in cited else "uncited"
                sub = ""
            elif rules:
                verdict = "partial" if len(set(rules)) < neg else "checked"
                sub = ""
            elif unsups:
                verdict = "refused"
                sub = ""
            else:
                verdict = "unchecked"
                deeper = sorted(c for c in by_clause_rule if c != clause and clause_related(c, clause) and c.startswith(clause))
                sub = ",".join(deeper)
            rows.append((clause, neg, rules, unsups, verdict, sub))
        rows.sort(key=lambda r: sort_key(r[0]))
        return rows

    def all_clauses(self, std):
        """Every clause id `std` is known to have, ledger rows included
        (the `nospec` existence check; research/diagcodes.md §1.2)."""
        out = {rid.partition(":")[0] for rid in self.ledgers.get(std, {})}
        if std == "v2005":
            out |= set(ieee_clause_titles())
        else:
            for path in CLAUSES_DIR.rglob("CLAUSES.tsv"):
                if "ieee1364" in path.parts:
                    continue
                for line in path.read_text().splitlines():
                    if line.strip() and not line.startswith("#"):
                        out.add(line.split("\t")[0].strip())
        return out

    def gates(self):
        """{gate: {subject, ...}} for every named gate (research/
        diagcodes.md §1.7); report-only verdicts are not gates."""
        g = collections.defaultdict(set)
        live = {n: r for n, r in self.codes.items() if r.kind != "retired"}
        retired = {n: r for n, r in self.codes.items() if r.kind == "retired"}
        for name in live:
            if name not in self.raises:
                g["dead"].add(name)
        for name in retired:
            if name in self.raises:
                g["dead"].add(name)
        for spelling in self.unknown:
            g["unknown"].add(spelling)
        for name, row in live.items():
            if row.kind in ("rule", "syntax") and name not in self.uses:
                g["untested"].add(name)
            if row.kind == "unsup" and name not in self.uses and not listed_unsup(name, self.vera_xfail, self.tools_xfail):
                g["unlisted"].add(name)
        shared = SUBMODULE / "tests"
        for name, paths in self.uses.items():
            row = self.codes.get(name)
            if row is None or row.kind not in ("unsup", "limit", "lint", "ice"):
                continue
            for path in paths:
                if (ROOT / path).is_relative_to(shared):
                    g["misuse"].add(path)
        for name, row in live.items():
            if row.kind != "rule" or name not in self.uses:
                continue
            clauses = row_clauses(row)
            if not clauses:
                continue
            for path in self.uses[name]:
                cites = self.cites.get(path, [])
                if not any(s == rs and clause_related(c, rc) for s, c in cites for rs, rc in clauses):
                    g["cite"].add(path)
        for name, row in live.items():
            for s, c in row_clauses(row):
                if s in self.ledger_missing:
                    continue
                ledger = self.ledgers.get(s, {})
                has_sentence = any(rid.partition(":")[0] == c and "-" in r["pol"] and r["kind"] != "non-normative"
                                    for rid, r in ledger.items())
                if row.kind in ("rule", "syntax") and not has_sentence and self.clause_kinds.get((s, c)) != "no-prohibition":
                    g["nospec"].add(name)
                elif row.kind == "unsup" and c not in self.all_clauses(s):
                    g["nospec"].add(name)
        for name in self.wording:
            g["wording"].add(name)
        for std in self.ledger_missing:
            g["ledger"].add(std)
        return g


# ---------------------------------------------------------------------------
# report / check: the §1.5 table and the §1.7 gate summary. Both read the
# same `Model`; `check` prints only the delta against `tools/diag_gaps.xfail`.
# ---------------------------------------------------------------------------

STD_LABEL = {
    "ams": "AMS (Verilog-AMS 2023; vera/ledger/OBLIGATIONS.tsv)",
    "v2005": "V2005 (IEEE 1364-2005; vera/ledger/OBLIGATIONS-1364.tsv)",
}


def render_std(model, std, out):
    if std in model.ledger_missing:
        print(f"{STD_LABEL[std]}: ledger missing (tools/diag_gaps.py ledger --update --std "
              f"{'AMS' if std == 'ams' else 'V2005'} --write has not been applied yet)", file=out)
        return
    rows = model.clause_verdicts(std)
    provisional = std == "v2005" and any(r["pol"] == "?" for r in model.ledgers[std].values())
    label = STD_LABEL[std] + (f", {len(model.ledgers[std])} rows" + (": PROVISIONAL, pol unreviewed" if provisional else ""))
    print(label, file=out)
    print("clause\tneg\trule\tunsup\tverdict", file=out)
    tally = collections.Counter()
    for clause, neg, rule, unsup, verdict, sub in rows:
        tally[verdict] += 1
        rule_s = ",".join(f"{n}({len(model.uses.get(n, []))})" for n in rule) or "-"
        unsup_s = ",".join(f"{n}({len(model.uses.get(n, []))})" for n in unsup) or "-"
        tail = f" (sub: {sub})" if sub else ""
        print(f"{clause}\t{neg}\t{rule_s}\t{unsup_s}\t{verdict}{tail}", file=out)
    total = len(rows)
    print(f"{std.upper()}: {total} clauses: {tally['checked']} checked ({tally['partial']} partial), "
          f"{tally['refused']} refused, {tally['unchecked']} unchecked, "
          f"{tally['positive-only']} positive-only, {tally['uncited']} uncited", file=out)


def render_vera(model, out):
    rows = [n for n, r in model.codes.items() if r.std == "vera" and r.kind != "retired"]
    print(f"VERA: {len(rows)} codes, no ledger", file=out)
    for n in sorted(rows):
        print(f"  {n}\t{model.codes[n].kind}\tfixtures={len(model.uses.get(n, []))}", file=out)


GATES = ("dead", "unknown", "untested", "unlisted", "misuse", "cite", "nospec", "wording", "ledger")


def render_report(model, out=sys.stdout):
    for std in ("ams", "v2005"):
        render_std(model, std, out)
    render_vera(model, out)
    gates = model.gates()
    live = sum(1 for r in model.codes.values() if r.kind != "retired")
    parts = ", ".join(f"{g} {len(gates.get(g, ()))}" for g in GATES)
    print(f"codes: {live} live: {parts}", file=out)
    return gates


def write_tsv(model, path):
    with open(path, "w") as f:
        f.write("std\tclause\tneg\trule\tunsup\tverdict\tsub\n")
        for std in ("ams", "v2005"):
            if std in model.ledger_missing:
                continue
            for clause, neg, rule, unsup, verdict, sub in model.clause_verdicts(std):
                f.write(f"{std}\t{clause}\t{neg}\t{','.join(rule) or '-'}\t{','.join(unsup) or '-'}\t{verdict}\t{sub}\n")


def gate_delta(gates, xfail):
    """(new_failures, xpass): subjects a gate names today but `diag_gaps.xfail`
    does not, and xfail lines whose gap no longer exists (always gated)."""
    new = {}
    xpass = []
    for name in GATES:
        found = gates.get(name, set())
        expected = xfail.get(name, set())
        extra = found - expected
        if extra:
            new[name] = extra
        xpass.extend(f"{name} {s}" for s in sorted(expected - found))
    return new, xpass


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def cmd_ledger(argv):
    p = argparse.ArgumentParser(prog="diag_gaps.py ledger")
    p.add_argument("--std", choices=("AMS", "V2005"), required=True)
    p.add_argument("--show", metavar="CLAUSE")
    p.add_argument("--update", action="store_true")
    p.add_argument("--write", action="store_true", help="actually write --ledger-dir; default is a dry-run report")
    p.add_argument("--ledger-dir", type=Path, default=DEFAULT_LEDGER_DIR)
    args = p.parse_args(argv)
    is_ams = args.std == "AMS"
    pdf, digest_want = (LRM_PDF, conformance.LRM_SHA256) if is_ams else (IEEE_PDF, conformance.IEEE_SHA256)
    ledger_name = "OBLIGATIONS.tsv" if is_ams else "OBLIGATIONS-1364.tsv"
    ledger_path = args.ledger_dir / ledger_name

    if args.show:
        sections = ams_sections(pdf) if is_ams else ieee_sections(pdf, ieee_clause_titles())
        item = sections.get(args.show)
        if item is None:
            print(f"ledger: no clause {args.show} found in the PDF", file=sys.stderr)
            return 2
        text = item["text"] if is_ams else item
        for n, h, m, sent in extract_modal_sentences(text):
            print(f"{args.show}:{n}\t{h}\t{m}\t{sent}")
        return 0

    if not args.update:
        p.error("ledger: pass --show CLAUSE or --update")

    digest = hashlib.sha256(pdf.read_bytes()).hexdigest()
    if digest != digest_want:
        print(f"ledger: {pdf} does not match the pinned sha256 ({digest_want}); got {digest}", file=sys.stderr)
        return 2
    old = read_ledger(ledger_path)
    if is_ams:
        new, moved, added, vanished = ams_refresh(old, clause_kinds())
        head = LEDGER_HEAD
    else:
        new, moved, added, vanished = ieee_seed(old)
        head = IEEE_LEDGER_HEAD
    print(f"ledger {args.std}: {len(new)} rows; {len(old) - len(moved) - len(vanished)} match, "
          f"{len(moved)} moved, {len(added)} new, {len(vanished)} vanished"
          + ("" if args.write else " (dry run: --ledger-dir unwritten; pass --write to commit)"))
    for rid in moved[:20]:
        print("  moved:", rid)
    for rid in vanished[:20]:
        print("  vanished:", rid)
    if args.write:
        args.ledger_dir.mkdir(parents=True, exist_ok=True)
        write_ledger(new, ledger_path, head)
        return 0
    return 1 if (moved or added or vanished) else 0


def cmd_report(argv):
    p = argparse.ArgumentParser(prog="diag_gaps.py report")
    p.add_argument("--tsv", type=Path)
    p.add_argument("--ledger-dir", type=Path, default=DEFAULT_LEDGER_DIR)
    args = p.parse_args(argv)
    model = Model.build(args.ledger_dir)
    gates = render_report(model)
    if args.tsv:
        write_tsv(model, args.tsv)
    xfail = read_diag_xfail()
    new, xpass = gate_delta(gates, xfail)
    if new or xpass:
        for name, subs in new.items():
            print(f"check: {name} names {len(subs)} subject(s) not in tools/diag_gaps.xfail: {sorted(subs)[:10]}", file=sys.stderr)
        for line in xpass:
            print(f"check: xpass: {line}", file=sys.stderr)
        return 1
    return 0


def cmd_check(argv):
    p = argparse.ArgumentParser(prog="diag_gaps.py check")
    p.add_argument("--ledger-dir", type=Path, default=DEFAULT_LEDGER_DIR)
    args = p.parse_args(argv)
    model = Model.build(args.ledger_dir)
    gates = model.gates()
    xfail = read_diag_xfail()
    new, xpass = gate_delta(gates, xfail)
    live = sum(1 for r in model.codes.values() if r.kind != "retired")
    print(f"codes: {live} live: " + ", ".join(f"{g} {len(gates.get(g, ()))}" for g in GATES))
    if not new and not xpass:
        print("check: clean (every gate matches tools/diag_gaps.xfail)")
        return 0
    for name, subs in new.items():
        print(f"FAIL {name}: {len(subs)} new subject(s) not in tools/diag_gaps.xfail:")
        for s in sorted(subs)[:30]:
            print(f"  {name} {s}")
    for line in xpass:
        print(f"FAIL xpass: {line} no longer reproduces; drop its tools/diag_gaps.xfail line")
    return 1


# ---------------------------------------------------------------------------
# selftest: this script's own oracle (research/diagcodes.md §1.7). Each
# expected value below is written by hand; none is recomputed the way the
# script computes it.
# ---------------------------------------------------------------------------

class LedgerHashReset(unittest.TestCase):
    """A1's red-first fault: `ledger --update` must never keep a reviewed
    row whose sentence changed, and must never disturb one that did not."""

    def test_unchanged_hash_keeps_the_reviewed_columns(self):
        found = {"9.9": [(1, "deadbeef", "shall", "A widget shall not glow.")]}
        old = {"9.9:1": {"hash": "deadbeef", "modal": "shall", "pol": "-", "kind": "-",
                         "oracle": "hand2", "text": "A widget shall not glow."}}
        new, moved, added, vanished = merge_ledger(old, found, lambda c, m, s: ("?", "?"))
        self.assertEqual((moved, added, vanished), ([], [], []))
        self.assertEqual(new["9.9:1"]["oracle"], "hand2")

    def test_changed_hash_resets_the_row(self):
        # The fault this plants: an edit to the sentence (here, standing in
        # for a real --update after the LRM's own text moved) changes the
        # hash. The row must come back `moved`, not keep the stale pol/oracle.
        edited = "A widget shall not glow brightly."
        found = {"9.9": [(1, sentence_hash(edited), "shall", edited)]}
        old = {"9.9:1": {"hash": "deadbeef", "modal": "shall", "pol": "-", "kind": "-",
                         "oracle": "hand2", "text": "A widget shall not glow."}}
        new, moved, added, vanished = merge_ledger(old, found, lambda c, m, s: ("?", "?"))
        self.assertEqual(moved, ["9.9:1"])
        self.assertEqual(new["9.9:1"]["pol"], "?")
        self.assertNotEqual(new["9.9:1"]["oracle"], "hand2")


class SyntheticWorld(unittest.TestCase):
    """Layer 1 (§1.7): a world built from strings, every expected gate
    written by hand. Builds a temp tree shaped like the real one and points
    the module's path constants at it, so `Model.build` runs the real
    reader/scanner code, never a re-implementation of it."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.tmp.cleanup)
        root = Path(cls.tmp.name)
        lib = root / "lib"; lib.mkdir()
        # Mirrors SUBMODULE/"tests": the one fixture root the real `misuse`
        # gate checks (line ~737 patches SUBMODULE to `root` below), so a
        # reject of an unsup/limit/lint/ice code under here is testable.
        fixtures = root / "tests"; fixtures.mkdir()
        ledger_dir = root / "ledger"; ledger_dir.mkdir()
        clauses_dir = root / "clauses"; clauses_dir.mkdir()

        codes_zon = root / "codes.zon"
        codes_zon.write_text(
            ".{\n"
            + "".join(
                f'    .{n} = .{{\n        .key = "k",\n        .kind = .{k},\n'
                f'        .std = .ams,\n        .clause = "{c}",\n        .title = "t",\n    }},\n'
                for n, k, c in (
                    ("E0001", "rule", "A.1"), ("E0002", "rule", "A.1"), ("E0003", "rule", "A.1"),
                    ("E0004", "unsup", "A.2"), ("E0005", "unsup", "A.2"), ("E0006", "rule", "A.1"),
                    ("E0007", "rule", "Z.9"),
                )
            )
            + "}\n"
        )

        (lib / "stage.zig").write_text(
            "fn f() void {\n"
            "    s.fail(.E0002, \"glows\");\n"
            "    s.fail(.E0004, \"refused\");\n"
            "    s.fail(.E0005, \"refused too\");\n"
            "    s.fail(.E0006, \"not implemented\");\n"
            "    s.fail(.E0007, \"also glows\");\n"
            "}\n"
            "test \"never raised in a test block\" {\n"
            "    s.fail(.E0001, \"dead except here\");\n"
            "}\n"
        )
        (lib / "body.zig.txt").write_text('error[E0003]\nerror[E9998]\n')

        shared = fixtures / "shared"; shared.mkdir()
        (shared / "a_rejected.va").write_text("//! lrm A.1\n//! reject-only E0002\nmodule a; endmodule\n")
        (shared / "b_rejected.va").write_text("//! lrm A.1\n//! reject E0003\nmodule b; endmodule\n")
        (shared / "c_rejected.va").write_text("//! reject-only E0004\nmodule c; endmodule\n")
        (fixtures / "d_positive.va").write_text("//! lrm A.4\nmodule d; endmodule\n")
        (fixtures / "e_rejected.va").write_text("//! lrm A.1\n//! reject-only E0006\nmodule e; endmodule\n")

        (ledger_dir / "OBLIGATIONS.tsv").write_text(
            "# id\thash\tmodal\tpol\tkind\toracle\ttext\n"
            "A.1:1\th1\tshall\t-\t-\t?\tt1\n"
            "A.2:1\th2\tshall\t-\t-\t?\tt2\n"
            "A.3:1\th3\tshall\t-\t-\t?\tt3\n"
            "A.4:1\th4\tshall\t+\t-\t?\tt4\n"
            "A.5:1\th5\tshall\t+\t-\t?\tt5\n"
        )

        cls.patched = {
            "CODES_ZON": codes_zon, "RAISE_ROOTS": (lib,), "RAISE_SKIP": (),
            "FIXTURE_ROOTS": (fixtures,), "VERA_XFAIL": root / "no-vera-xfail",
            "TOOLS_XFAIL": root / "no-tools-xfail", "CLAUSES_DIR": clauses_dir,
            "SUBMODULE": root,
        }
        saved = {k: globals()[k] for k in cls.patched}
        cls.addClassCleanup(globals().update, saved)
        globals().update(cls.patched)
        cls.model = Model.build(ledger_dir)
        cls.misuse_path = str(shared / "c_rejected.va")

    def test_gates(self):
        g = self.model.gates()
        self.assertEqual(g["dead"], {"E0001"})
        self.assertEqual(g["unknown"], {"E9998"})
        self.assertEqual(g["untested"], {"E0001", "E0007"})
        self.assertEqual(g["unlisted"], {"E0005"})
        self.assertEqual(g["misuse"], {self.misuse_path})
        self.assertEqual(g["cite"], set())
        self.assertEqual(g["nospec"], {"E0007"})
        self.assertEqual(g["wording"], {"E0006"})
        self.assertEqual(g["ledger"], {"v2005"})

    def test_clause_verdicts(self):
        verdicts = {clause: verdict for clause, _, _, _, verdict, _ in self.model.clause_verdicts("ams")}
        self.assertEqual(verdicts["A.1"], "checked")
        self.assertEqual(verdicts["A.2"], "refused")
        self.assertEqual(verdicts["A.3"], "unchecked")
        self.assertEqual(verdicts["A.4"], "positive-only")
        self.assertEqual(verdicts["A.5"], "uncited")

    def test_xpass_names_an_xfail_line_whose_gap_is_gone(self):
        new, xpass = gate_delta(self.model.gates(), {"dead": {"PLANTED_NOT_DEAD"}})
        self.assertIn("dead PLANTED_NOT_DEAD", xpass)
        self.assertIn("dead", new)  # E0001 is still unlisted in this xfail


class RealTreePlantedGaps(unittest.TestCase):
    """Layer 2 (§1.7): a planted gap on the real tree, in memory — never
    written to disk, never touching tests/conformance."""

    @classmethod
    def setUpClass(cls):
        cls.model = Model.build()

    def test_a_planted_ledger_row_is_unchecked(self):
        model = self.model
        model.ledgers["ams"] = dict(model.ledgers["ams"])
        model.ledgers["ams"]["99.99:1"] = {"hash": "x", "modal": "shall", "pol": "-",
                                            "kind": "-", "oracle": "?", "text": "planted"}
        verdicts = {clause: verdict for clause, _, _, _, verdict, _ in model.clause_verdicts("ams")}
        self.assertEqual(verdicts.get("99.99"), "unchecked")  # red-first #1: delete the branch, this names 99.99

    def test_a_planted_dead_row_is_dead(self):
        model = self.model
        model.codes = dict(model.codes)
        model.codes["planted_dead"] = Row(name="planted_dead", kind="rule", std="ams", clause="A.1", also="", severity="err")
        self.assertIn("planted_dead", model.gates()["dead"])

    def test_the_bag_add_raise_form_is_not_mistaken_for_dead(self):
        # red-first #2: narrow scan_raises to a specific call-form regex and
        # this fails, naming E1099 (osdi.zig's `bag.add(.codegen, .E1099 ...)`).
        self.assertNotIn("E1099", self.model.gates()["dead"])

    def test_removing_a_fixtures_use_makes_its_rule_untested(self):
        model = self.model
        self.assertIn("E0415", model.uses)  # today's fixture evidence
        model.uses = dict(model.uses)
        del model.uses["E0415"]
        self.assertIn("E0415", model.gates()["untested"])

    def test_a_wrong_clause_makes_cite_name_its_fixtures(self):
        # red-first #3: in a scratch copy, give E0415 the clause 5.6.7.1.
        model = self.model
        model.codes = dict(model.codes)
        real = model.codes["E0415"]
        model.codes["E0415"] = real._replace(clause="5.6.7.1")
        self.assertTrue(model.gates()["cite"])  # names at least one of E0415's fixtures


def load_tests(loader, standard_tests, pattern):
    # Only this module's own cases, never argparse's or conformance.py's
    # (the module's import at top of file would otherwise pull them in).
    suite = unittest.TestSuite()
    for case in (LedgerHashReset, SyntheticWorld, RealTreePlantedGaps):
        suite.addTests(loader.loadTestsFromTestCase(case))
    return suite


def main(argv):
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "ledger":
        return cmd_ledger(rest)
    if cmd == "report":
        return cmd_report(rest)
    if cmd == "check":
        return cmd_check(rest)
    if cmd == "selftest":
        sys.argv = ["diag_gaps.py selftest"] + rest
        return 0 if unittest.main(module=sys.modules[__name__], argv=sys.argv, exit=False).result.wasSuccessful() else 1
    print(f"diag_gaps.py: unknown subcommand {cmd!r}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
