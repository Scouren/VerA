#!/usr/bin/env python3
# Vendored (K3) from https://github.com/OmarSiwy/OmarSiwy.github.io
#   path:   Resources/perf-kit/lint/perf_tidy.py
#   commit: 30f7110ad4270aa3d642e319e227483f82c010f3
# Unmodified below this header. Licence: the source repository carries no LICENSE file at that
# commit (only build/gds/LICENSE.md, which covers other content); the copyright stays with its
# author, vendored here by the project's choice. To update: copy the file at a newer commit and
# change the SHA above. VerA runs it on its emitted devices through tools/bench/tidy_devices.py.
"""perf_tidy: one mechanical-sympathy linter for Rust, C++ and Zig.

It enforces the rules from "Software Fundamentals for the LLM Era" that a
compiler will not: layout, allocation, branching, SIMD hygiene, concurrency,
I/O batching and assertion discipline. It complements clippy, clang-tidy and
compiler warnings; it does not replace them.

    perf_tidy.py [--strict] [--format text|cargo|github] PATH...
    perf_tidy.py --list-rules

Exit status is 1 when an error-level finding remains, so it can gate a build.
Python 3.9+, standard library only.

Annotations, written as comments in the source:

    // tidy: hot-file                 every function in this file is a hot path
    // tidy: hot                      the next function is a hot path
    // tidy: allow(rule) reason       silence `rule` on this line or the next
    // tidy: allow-fn(rule) reason    silence `rule` in the next function or type
    // tidy: allow-file(rule) reason  silence `rule` in the whole file

A reason is mandatory. An allow without one is itself a finding.
"""

from __future__ import annotations

import argparse
import bisect
import dataclasses
import re
import sys
from pathlib import Path

LANGUAGE_BY_SUFFIX = {
    ".rs": "rust", ".zig": "zig",
    ".cpp": "cpp", ".cc": "cpp", ".cxx": "cpp", ".hpp": "cpp", ".hh": "cpp", ".hxx": "cpp", ".h": "cpp",
}
BUILD_FILE_NAMES = {"Cargo.toml", "CMakeLists.txt", "build.zig", "config.toml", "Makefile", "meson.build"}
SKIPPED_DIRECTORIES = {"target", "zig-out", ".zig-cache", "zig-cache", "build", ".git", "node_modules", "vendor"}

FUNCTION_LINES_MAX = 70      # Tiger Style: a function fits on one screen.
LINE_COLUMNS_MAX = 100       # Tiger Style: two files side by side.
PARAMETERS_MAX = 6           # System V passes six integer arguments in registers.
GENERIC_LINES_MAX = 25       # Larger generic bodies are copied per instantiation.
INLINE_LINES_MAX = 20
ASSERTION_FREE_LINES_MAX = 15

WARNINGS = {
    "allocation-in-loop", "io-call-in-loop", "boxed-elements", "simd-without-dispatch",
    "release-build-not-tuned", "warnings-not-strict", "missing-reserve", "large-generic-function",
}


# Rule catalog: rule -> (article topic, what it enforces). `--list-rules` prints it,
# and the self-test fails if a rule is reported that is not listed here.
RULES = {
    # 1. Clean code
    "function-too-long": (1, "A function is at most 70 lines."),
    "line-too-long": (1, "A line is at most 100 columns."),
    "recursion": (1, "No recursion without a stated depth bound."),
    "dynamic-dispatch-in-hot-path": (1, "No virtual, dyn or function-pointer calls on a hot path."),
    # 2. API design
    "too-many-parameters": (2, "At most six parameters: more spill out of the registers."),
    "bool-parameters": (2, "At most one bool parameter: use an enum or an options struct."),
    "small-type-by-reference": (2, "Small values are passed by value (C++)."),
    "global-allocator-in-library": (2, "Library code takes its allocator as a parameter (Zig)."),
    # 3. Data-oriented design
    "linked-list": (3, "No linked lists."),
    "boxed-elements": (3, "No container of individually heap-allocated elements."),
    "nested-growable": (3, "No growable array of growable arrays: flatten it."),
    "node-container-in-hot-path": (3, "No std::map, std::set or unordered containers on a hot path (C++)."),
    "siphash-in-hot-path": (3, "No default-hasher HashMap on a hot path (Rust)."),
    "struct-padding": (3, "Fixed-layout structs are ordered so that no padding is wasted."),
    "bool-heavy-struct": (3, "No struct with three or more bool fields."),
    "missing-size-assert": (3, "Every struct in a hot file pins its size at compile time."),
    "arch-sized-field": (3, "No usize or size_t fields in hot structs: choose the width."),
    # 4. Branchless programming
    "branch-in-hot-loop": (4, "A branch in a hot loop is removed or justified in a comment."),
    "manual-bit-trick": (4, "Use the popcount and count-zeros intrinsics, not a bit loop."),
    "division-in-hot-loop": (4, "No division by a run-time value in a hot loop."),
    # 5. SIMD
    "simd-helper-not-inlined": (5, "A macerator helper is #[inline(always)] (Rust)."),
    "simd-tail-unhandled": (5, "A chunked SIMD loop handles its remainder (Rust)."),
    "intrinsics-without-target": (5, "A function using AVX intrinsics carries a target attribute (C++)."),
    "simd-without-dispatch": (5, "Code compiled for a newer CPU is guarded by a CPU check (C++)."),
    "fixed-vector-width": (5, "Vector widths come from the target, not from a literal (Zig)."),
    "default-prefetch-options": (5, "@prefetch spells out its options (Zig)."),
    # 6. Parallelism
    "float-reduction-single-chain": (6, "A hot float reduction uses several accumulators or SIMD."),
    "atomic-array-unpadded": (6, "Adjacent atomics are padded to separate cache lines."),
    "lock-in-hot-path": (6, "No mutex on a hot path."),
    "shared-ownership-in-hot-path": (6, "No reference counting on a hot path."),
    "unbounded-queue": (6, "Channels and queues have an explicit bound (Rust)."),
    "seqcst-unjustified": (6, "Sequentially consistent ordering is justified in a comment."),
    # 7. Measurement
    "benchmark-without-black-box": (7, "Timing code hides its inputs and results from the optimizer."),
    # 8. Allocation
    "allocation-in-hot-path": (8, "No allocation on a hot path."),
    "allocation-in-loop": (8, "No allocation inside a loop (warning)."),
    "missing-reserve": (8, "A list filled by a counted loop reserves its capacity first (warning)."),
    # 10. Working with the compiler
    "member-accumulator": (10, "A loop accumulates into a local, not through a pointer or member."),
    "large-generic-function": (10, "A generic function over 25 lines is split into a thin shell and a body (warning)."),
    "inline-always-large": (10, "No forced inlining of a function over 20 lines."),
    "float-mode-unjustified": (10, "@setFloatMode(.optimized) is justified in a comment (Zig)."),
    "native-cpu-in-build": (10, "The build names a CPU baseline instead of -march=native."),
    "fast-math-global": (10, "No fast-math for the whole build."),
    # 11. Binary size and build settings
    "release-build-not-tuned": (11, "Release builds enable link-time optimization (warning)."),
    "warnings-not-strict": (11, "The build adopts the strict warning and lint set (warning)."),
    # 12. I/O
    "endl": (12, "No std::endl (C++)."),
    "unbuffered-writer": (12, "No writer with an empty buffer (Zig)."),
    "unbuffered-file-write": (12, "File writes go through a BufWriter (Rust)."),
    "print-in-loop": (12, "No print call inside a loop."),
    "flush-in-loop": (12, "No flush inside a loop."),
    "io-call-in-loop": (12, "No open, stat or sync call inside a loop (warning)."),
    # 13. Correctness
    "missing-assertion": (13, "A function over 15 lines asserts something."),
    "compound-assertion": (13, "One condition per assertion."),
    "swallowed-error": (13, "No discarded errors."),
    "unbounded-loop": (13, "An endless loop states what ends it."),
    "exception-in-hot-path": (13, "No throw or try on a hot path (C++)."),
    "allow-without-reason": (13, "Every `tidy: allow` carries a reason."),
}


@dataclasses.dataclass(frozen=True)
class Finding:
    path: str
    line: int
    rule: str
    message: str

    @property
    def level(self) -> str:
        return "warning" if self.rule in WARNINGS else "error"


@dataclasses.dataclass
class Function:
    name: str
    header_start: int   # offset of the signature
    body_start: int     # offset of '{'
    body_end: int       # offset of the matching '}'
    params: str
    prefix: str         # attributes, template header and qualifiers before the signature
    is_test: bool = False
    is_hot: bool = False


# --------------------------------------------------------------------------- lexing

def mask_source(text: str, language: str) -> tuple[str, dict[int, str]]:
    """Returns the code with comments and literal contents blanked, plus comments by line."""
    out = list(text)
    comments: dict[int, str] = {}
    line = 1
    i, n = 0, len(text)

    def blank(start: int, end: int) -> None:
        for k in range(start, min(end, n)):
            if out[k] != "\n":
                out[k] = " "

    def note(start: int, end: int, at_line: int) -> None:
        comments[at_line] = (comments.get(at_line, "") + " " + text[start:end]).strip()

    while i < n:
        c = text[i]
        two = text[i:i + 2]
        if c == "\n":
            line += 1
            i += 1
        elif two == "//":
            end = text.find("\n", i)
            end = n if end < 0 else end
            note(i, end, line)
            blank(i, end)
            i = end
        elif two == "/*" and language != "zig":
            depth, j = 1, i + 2
            while j < n and depth:
                if text[j:j + 2] == "/*" and language == "rust":
                    depth, j = depth + 1, j + 2
                elif text[j:j + 2] == "*/":
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            start_line = line
            for offset, piece in enumerate(text[i:j].split("\n")):
                comments[start_line + offset] = (comments.get(start_line + offset, "") + " " + piece).strip()
            line += text.count("\n", i, j)
            blank(i, j)
            i = j
        elif language == "zig" and two == "\\\\":
            end = text.find("\n", i)
            end = n if end < 0 else end
            blank(i, end)
            i = end
        elif language == "rust" and (m := re.compile(r'b?r(#*)"').match(text, i)) and not _ident_before(text, i):
            close = text.find('"' + m.group(1), m.end())
            close = n if close < 0 else close + 1 + len(m.group(1))
            line += text.count("\n", i, close)
            blank(m.end(), close - 1 - len(m.group(1)))
            i = close
        elif language == "cpp" and (m := re.compile(r'R"([^()\s\\]{0,16})\(').match(text, i)) and not _ident_before(text, i):
            terminator = ")" + m.group(1) + '"'
            close = text.find(terminator, m.end())
            close = n if close < 0 else close + len(terminator)
            line += text.count("\n", i, close)
            blank(m.end(), close - len(terminator))
            i = close
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"' and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            blank(i + 1, j)
            i = j + 1
        elif c == "'":
            if language == "cpp" and i > 0 and text[i - 1].isalnum() and i + 1 < n and text[i + 1].isalnum():
                i += 1  # digit separator: 1'000
            elif text[i + 1:i + 2] == "\\":
                j = text.find("'", i + 2)
                j = i + 1 if j < 0 else j
                blank(i + 1, j)
                i = j + 1
            elif text[i + 2:i + 3] == "'":
                blank(i + 1, i + 2)
                i += 3
            else:
                i += 1  # a Rust lifetime or label
        else:
            i += 1
    return "".join(out), comments


def _ident_before(text: str, i: int) -> bool:
    return i > 0 and (text[i - 1].isalnum() or text[i - 1] == "_")


def match_pairs(code: str, opener: str, closer: str) -> dict[int, int]:
    pairs, stack = {}, []
    for i, c in enumerate(code):
        if c == opener:
            stack.append(i)
        elif c == closer and stack:
            pairs[stack.pop()] = i
    return pairs


# --------------------------------------------------------------------------- one file

class SourceFile:
    def __init__(self, path: str, text: str, language: str, path_heuristics: bool = True):
        self.path, self.text, self.language = path, text, language
        self.code, self.comments = mask_source(text, language)
        self.line_starts = [0] + [m.end() for m in re.finditer("\n", text)]
        self.braces = match_pairs(self.code, "{", "}")
        self.parens = match_pairs(self.code, "(", ")")
        self.findings: list[Finding] = []
        name = Path(path).name.lower()
        # Tests, benchmarks and build scripts are exempt from the rules for shipped code.
        self.is_test_file = name in ("build.zig", "build.rs") or \
            (path_heuristics and bool(re.search(r"test|bench|fuzz|example|probe", name)))
        self.is_bench_file = bool(re.search(r"bench", name))
        self.hot_file = any("tidy: hot-file" in c for c in self.comments.values())
        self.test_ranges = self._test_ranges()
        self.functions = self._functions()
        self.loops = self._loops()

    # ---- positions

    def line_of(self, offset: int) -> int:
        return bisect.bisect_right(self.line_starts, offset)

    def line_text(self, line: int) -> str:
        start = self.line_starts[line - 1]
        end = self.line_starts[line] if line < len(self.line_starts) else len(self.code)
        return self.code[start:end]

    def comment_near(self, line: int) -> str:
        """The comment on `line` plus the comment block directly above it."""
        parts = [self.comments.get(line, "")]
        above = line - 1
        while above >= 1 and above in self.comments and not self.line_text(above).strip():
            parts.append(self.comments[above])
            above -= 1
        return " ".join(parts)

    def in_ranges(self, offset: int, ranges: list[tuple[int, int]]) -> bool:
        return any(start <= offset < end for start, end in ranges)

    def in_loop(self, offset: int) -> bool:
        return self.in_ranges(offset, self.loops)

    def in_test(self, offset: int) -> bool:
        return self.is_test_file or self.in_ranges(offset, self.test_ranges)

    def function_at(self, offset: int) -> Function | None:
        best = None
        for function in self.functions:  # the signature counts: parameter types are part of the function
            if function.header_start <= offset <= function.body_end:
                if best is None or function.body_start > best.body_start:
                    best = function
        return best

    def is_hot(self, offset: int) -> bool:
        function = self.function_at(offset)
        return self.hot_file or bool(function and function.is_hot)

    def report(self, offset_or_line: int, rule: str, message: str, *, is_line: bool = False) -> None:
        line = offset_or_line if is_line else self.line_of(offset_or_line)
        self.findings.append(Finding(self.path, line, rule, message))

    # ---- structure

    def _test_ranges(self) -> list[tuple[int, int]]:
        ranges = []
        if self.language == "rust":
            for m in re.finditer(r"#\[cfg\(test\)\]\s*(?:pub\s+)?mod\s+\w+\s*\{", self.code):
                ranges.append((m.start(), self.braces.get(m.end() - 1, len(self.code))))
        elif self.language == "zig":
            for m in re.finditer(r'(?m)^\s*test\b[^{;]*\{', self.code):
                ranges.append((m.start(), self.braces.get(m.end() - 1, len(self.code))))
        return ranges

    def _functions(self) -> list[Function]:
        finder = {"rust": self._rust_functions, "zig": self._zig_functions, "cpp": self._cpp_functions}
        functions = finder[self.language]()
        for function in functions:
            first_line = self.line_of(function.header_start)
            prefix_line = self.line_of(function.header_start - len(function.prefix))
            block = " ".join(self.comment_near(line) for line in range(prefix_line, first_line + 1))
            function.is_hot = self.hot_file or bool(re.search(r"tidy: hot(?!-)", block))
            function.is_test = self.in_test(function.header_start) or "#[test]" in function.prefix
        if self.language == "zig":  # test blocks are analysed like functions
            for start, end in self.test_ranges:
                brace = self.code.find("{", start)
                functions.append(Function("test", start, brace, end, "", "", is_test=True))
        return functions

    def _prefix_before(self, offset: int, pattern: str) -> str:
        """Attribute and qualifier lines directly above `offset`."""
        line = self.line_of(offset)
        start = self.line_starts[line - 1]
        while line > 1:
            previous = self.line_text(line - 1).strip()
            if previous and not re.match(pattern, previous):
                break
            if not previous and (line - 1) not in self.comments:
                break
            line -= 1
            start = self.line_starts[line - 1]
        return self.code[start:offset]

    def _body_after(self, offset: int) -> int | None:
        """Offset of the '{' that opens a body, or None for a bare declaration."""
        depth = 0
        for i in range(offset, len(self.code)):
            c = self.code[i]
            if c in "([":
                depth += 1
            elif c in ")]":
                depth -= 1
            elif depth == 0 and c == ";":
                return None
            elif depth == 0 and c == "{":
                return i
            elif depth < 0:
                return None
        return None

    def _rust_functions(self) -> list[Function]:
        functions = []
        for m in re.finditer(r"\bfn\s+([A-Za-z_]\w*)", self.code):
            open_paren = self.code.find("(", m.end())
            if open_paren < 0 or open_paren not in self.parens:
                continue
            close_paren = self.parens[open_paren]
            body = self._body_after(close_paren + 1)
            if body is None or body not in self.braces:
                continue
            prefix = self._prefix_before(m.start(), r"#!?\[")
            generics = self.code[m.end():open_paren]
            functions.append(Function(m.group(1), m.start(), body, self.braces[body],
                                      self.code[open_paren + 1:close_paren], prefix + generics))
        return functions

    def _zig_functions(self) -> list[Function]:
        functions = []
        for m in re.finditer(r"\bfn\s+([A-Za-z_]\w*)\s*\(", self.code):
            open_paren = m.end() - 1
            if open_paren not in self.parens:
                continue
            close_paren = self.parens[open_paren]
            body = self._body_after(close_paren + 1)
            if body is None or body not in self.braces:
                continue
            line_start = self.line_starts[self.line_of(m.start()) - 1]
            functions.append(Function(m.group(1), m.start(), body, self.braces[body],
                                      self.code[open_paren + 1:close_paren], self.code[line_start:m.start()]))
        return functions

    def _cpp_functions(self) -> list[Function]:
        functions = []
        control = {"if", "for", "while", "switch", "catch", "return", "sizeof", "alignof", "decltype", "requires"}
        for body in sorted(self.braces):
            # Walk back over qualifiers to the ')' that ends a parameter list.
            head = self.code[max(0, body - 400):body]
            m = re.search(r"\)\s*((?:const|noexcept|override|final|mutable|volatile|&&?|\s|"
                          r"noexcept\s*\([^()]*\)|->\s*[\w:<>,&*\s]+|\[\[[^\]]*\]\]|__restrict)*)$", head)
            if not m:
                continue
            close_paren = max(0, body - 400) + m.start()
            open_paren = next((o for o, c in self.parens.items() if c == close_paren), None)
            if open_paren is None:
                continue
            name_match = re.search(r"(operator\s*\S+?|~?[A-Za-z_][\w:]*)\s*$", self.code[max(0, open_paren - 120):open_paren])
            if not name_match:
                continue
            name = name_match.group(1).split("::")[-1]
            if name in control or not re.match(r"~?[A-Za-z_]|operator", name):
                continue
            header_start = max(0, open_paren - 120) + name_match.start()
            statement_start = max(self.code.rfind(";", 0, header_start), self.code.rfind("}", 0, header_start),
                                  self.code.rfind("{", 0, header_start)) + 1
            lead = self.code[statement_start:header_start]
            if directive := list(re.finditer(r"(?m)^[ \t]*#.*$", lead)):
                statement_start += directive[-1].end()  # preprocessor lines end no statement
                lead = lead[directive[-1].end():]
            if label := re.match(r"\s*(?:(?:public|private|protected)\s*:\s*)+", lead):
                statement_start += label.end()  # an access label is not part of the definition
                lead = lead[label.end():]
            if re.search(r"[=]|\b(return|new|else|case|co_return|throw)\b", lead):
                continue  # an initializer or expression, not a definition
            if any(f.body_start < body < f.body_end for f in functions):
                continue  # a lambda or local block inside a function
            functions.append(Function(name, statement_start + len(lead) - len(lead.lstrip()), body, self.braces[body],
                                      self.code[open_paren + 1:close_paren], lead))
        return functions

    def _loops(self) -> list[tuple[int, int]]:
        """Loop bodies. Also fills `counted_loops`: loops whose trip count is known on entry."""
        loops = []
        self.counted_loops: list[tuple[int, int]] = []
        code = self.code
        if self.language == "rust":
            for m in re.finditer(r"(?<![\w.])(for\s+(?!<)|while\b|loop\b)", code):
                body = self._body_after(m.end())
                if body is not None and body in self.braces and self.function_at(body):
                    loops.append((body, self.braces[body]))
                    if m.group(1).startswith("for") and re.search(r"\.\.|\.iter(?:_mut)?\(\)|\.len\(\)|\bin\s+&", code[m.end():body]):
                        self.counted_loops.append(loops[-1])
            adapters = r"\.(for_each|map|filter|filter_map|flat_map|fold|any|all|position|retain|inspect|scan)\s*\("
            for m in re.finditer(adapters, code):
                if (m.end() - 1) in self.parens:
                    loops.append((m.end() - 1, self.parens[m.end() - 1]))
        else:
            for m in re.finditer(r"(?<![\w.@])(for|while)\s*\(", code):
                open_paren = m.end() - 1
                if open_paren not in self.parens:
                    continue
                i = self.parens[open_paren] + 1
                if self.language == "zig":  # captures and continue expression
                    rest = re.match(r"\s*(\|[^|]*\|)?\s*(:\s*\()?", code[i:])
                    i += rest.end()
                    if rest.group(2):
                        i = self.parens.get(i - 1, i) + 1
                rest = re.match(r"\s*", code[i:])
                i += rest.end()
                if code[i:i + 1] == "{" and i in self.braces:
                    loops.append((i, self.braces[i]))
                else:
                    end = self._statement_end(i)
                    loops.append((i, end))
                if m.group(1) == "for":
                    self.counted_loops.append(loops[-1])
            if self.language == "cpp":
                for m in re.finditer(r"\bdo\s*\{", code):
                    loops.append((m.end() - 1, self.braces.get(m.end() - 1, m.end())))
                for m in re.finditer(r"\bstd::(?:ranges::)?(for_each|transform|generate|accumulate)\s*\(", code):
                    if (m.end() - 1) in self.parens:
                        loops.append((m.end() - 1, self.parens[m.end() - 1]))
        return loops

    def _statement_end(self, offset: int) -> int:
        depth = 0
        for i in range(offset, len(self.code)):
            c = self.code[i]
            if c in "([{":
                depth += 1
            elif c in ")]}":
                depth -= 1
                if depth < 0:
                    return i
            elif c == ";" and depth == 0:
                return i
        return len(self.code)

    def body_line_count(self, function: Function) -> int:
        body = self.code[function.body_start + 1:function.body_end]
        return sum(1 for line in body.split("\n") if line.strip())


# --------------------------------------------------------------------------- pattern rules

def P(rule, languages, scope, regex, message):
    return (rule, languages.split(), scope, re.compile(regex), message)


ALLOCATION = {
    "rust": r"\b(?:Vec|String|Box|HashMap|HashSet|BTreeMap|VecDeque|Rc|Arc)::(?:new|with_capacity|from)\s*\(|\bvec!\s*\[|"
            r"\bformat!\s*\(|\.to_string\(\)|\.to_owned\(\)|\.to_vec\(\)|\.collect\s*(?:::<[^;()]*>)?\s*\(\)",
    "cpp": r"\bnew\s+[A-Za-z_(]|\bstd::make_(?:unique|shared)\b|\b(?:malloc|calloc|realloc|strdup)\s*\(|"
           r"\bstd::(?:to_string|format)\s*\(|\bstd::(?:o|i)?stringstream\b|"
           r"(?:(?<=[;{}])|(?<=^))\s*(?:const\s+)?std::(?:vector|string|map|unordered_map|set|unordered_set|deque|list)\b"
           r"(?:<[^;=()]*>)?\s+\w+\s*[;({=]",
    "zig": r"\b(?!arena\b|scratch\b|fba\b|bump\b)\w+\.(?:alloc|create|dupe|dupeZ|alignedAlloc|realloc)\s*\(|"
           r"\ballocPrint\s*\(|\balloc(?:Lower|Upper)String\s*\(\s*(?:gpa|allocator|alloc)\b|"
           r"\.(?:append|appendSlice|addOne|addManyAsSlice|ensureTotalCapacity|put|getOrPut)\s*\(\s*(?:gpa|allocator|alloc)\b",
}

PATTERNS = [
    # --- 1 clean code / 3 data-oriented design
    P("dynamic-dispatch-in-hot-path", "rust", "hot", r"\bdyn\s", "dynamic dispatch on a hot path: use an enum or a table indexed by kind"),
    P("dynamic-dispatch-in-hot-path", "cpp", "hot", r"\bvirtual\b|\bstd::function\b|\bdynamic_cast\b", "dynamic dispatch on a hot path: use a switch, a table, or a template"),
    P("dynamic-dispatch-in-hot-path", "zig", "hot", r"\banyopaque\b|\*const\s+fn\b", "indirect call on a hot path: use a tagged union or a table indexed by kind"),
    P("linked-list", "rust", "any", r"\bLinkedList\b", "linked list: every hop is a cache miss; use a Vec or VecDeque"),
    P("linked-list", "cpp", "any", r"\bstd::(?:forward_)?list\b", "linked list: every hop is a cache miss; use std::vector or std::deque"),
    P("linked-list", "zig", "any", r"\b(?:Singly|Doubly)LinkedList\b", "linked list: every hop is a cache miss; use an ArrayList"),
    P("boxed-elements", "rust", "any", r"\bVec\s*<\s*(?:Box|Rc|Arc)\s*<", "one heap object per element: store values inline, or use indices into a pool"),
    P("boxed-elements", "cpp", "any", r"\bstd::vector\s*<\s*std::(?:unique_ptr|shared_ptr)\s*<", "one heap object per element: store values inline, or use indices into a pool"),
    P("nested-growable", "rust", "any", r"\bVec\s*<\s*Vec\s*<", "Vec of Vec: one allocation per row; use one flat Vec with computed indices"),
    P("nested-growable", "cpp", "any", r"\bstd::vector\s*<\s*std::vector\s*<", "vector of vector: one allocation per row; use one flat vector with computed indices"),
    P("nested-growable", "zig", "any", r"\bArrayList\(\s*(?:std\.)?ArrayList\(", "ArrayList of ArrayList: one allocation per row; use one flat list with computed indices"),
    P("node-container-in-hot-path", "cpp", "hot", r"\bstd::(?:multi)?(?:map|set)\b|\bstd::unordered_(?:multi)?(?:map|set)\b", "node-based container on a hot path: use a sorted std::vector or a flat hash map"),
    P("siphash-in-hot-path", "rust", "hot", r"\bHash(?:Map|Set)::(?:new|with_capacity)\s*\(", "default SipHash on a hot path: pick a faster hasher, or index a Vec"),
    P("shared-ownership-in-hot-path", "rust", "hot", r"\b(?:Rc|Arc)\s*<", "reference counting on a hot path: borrow, or hand out handles"),
    P("shared-ownership-in-hot-path", "cpp", "hot", r"\bstd::shared_ptr\b", "reference counting on a hot path: pass references, or hand out handles"),
    # --- 4 branchless
    P("manual-bit-trick", "rust cpp zig", "loop", r"\b(\w+)\s*&=\s*\1\s*-%?\s*1\b", "hand-rolled bit loop: use the popcount or trailing-zeros intrinsic"),
    P("division-in-hot-loop", "rust cpp zig", "hot-loop", r"[\w)\]]\s*(?<![/*])[/%](?![/=*])\s*(?![0-9]|[A-Z][A-Z0-9_]*\b)[a-z_(]", "division by a run-time value in a hot loop: hoist a reciprocal, use a power of two and a mask, or justify it"),
    # --- 5 SIMD
    P("fixed-vector-width", "zig", "nontest", r"@Vector\(\s*\d+\s*,\s*[fiu]\d+\s*\)", "hard-coded vector width: use std.simd.suggestVectorLength so the target decides"),
    P("default-prefetch-options", "zig", "any", r"@prefetch\([^;]*,\s*\.\{\s*\}\s*\)", "spell out the @prefetch options (rw, locality, cache) at the call site"),
    # --- 6 parallelism
    P("atomic-array-unpadded", "rust", "any", r"\bVec\s*<\s*Atomic\w+\s*>|\[\s*Atomic\w+\s*;", "adjacent atomics share a cache line: wrap each in a #[repr(align(64))] struct"),
    P("atomic-array-unpadded", "cpp", "any", r"\bstd::(?:vector|array)\s*<\s*std::atomic\b", "adjacent atomics share a cache line: wrap each in an alignas(64) struct"),
    P("atomic-array-unpadded", "zig", "any", r"\[[^\]]*\]\s*std\.atomic\.Value\(", "adjacent atomics share a cache line: give each one align(std.atomic.cache_line)"),
    P("lock-in-hot-path", "rust", "hot", r"\b(?:Mutex|RwLock)\b", "lock on a hot path: partition the data, or batch outside the lock"),
    P("lock-in-hot-path", "cpp", "hot", r"\bstd::(?:mutex|shared_mutex|lock_guard|unique_lock|scoped_lock)\b", "lock on a hot path: partition the data, or batch outside the lock"),
    P("lock-in-hot-path", "zig", "hot", r"\bMutex\b|\bRwLock\b", "lock on a hot path: partition the data, or batch outside the lock"),
    P("unbounded-queue", "rust", "any", r"\bmpsc::channel\s*(?:::<[^;()]*>)?\s*\(", "unbounded channel: use sync_channel with an explicit bound"),
    # --- 8 allocation
    P("global-allocator-in-library", "zig", "nontest", r"\bstd\.heap\.(?:page_allocator|c_allocator|smp_allocator)\b", "take an Allocator parameter instead of reaching for a global one"),
    # --- 10 working with the compiler
    P("small-type-by-reference", "cpp", "params", r"\bconst\s+(?:float|double|bool|char|short|int|long|unsigned|std::size_t|size_t|std::u?int(?:8|16|32|64)_t)\s*&(?!&)", "small value passed by const reference: pass by value so it cannot alias and stays in a register"),
    P("member-accumulator", "cpp", "loop", r"\b(?:this->\w+|\w+_|m_\w+)\s*[+\-*|&^]=(?!=)", "accumulating into a member inside a loop: use a local and store once"),
    # --- 12 I/O
    P("endl", "cpp", "any", r"\bstd::endl\b", "std::endl flushes: write '\\n' and flush once"),
    P("unbuffered-writer", "zig", "nontest", r"\.writer\(\s*(?:\w+\s*,\s*)?&\.\{\s*\}\s*\)", "writer with an empty buffer: every write is a system call"),
    P("print-in-loop", "rust", "loop", r"\be?print(?:ln)?!\s*\(", "print in a loop locks and may flush every time: write into a BufWriter"),
    P("print-in-loop", "cpp", "loop", r"\bstd::c(?:out|err)\b", "stream output in a loop: format into a buffer and write once"),
    P("print-in-loop", "zig", "loop", r"\bstd\.debug\.print\s*\(", "std.debug.print in a loop is an unbuffered write each time: use a buffered writer"),
    P("flush-in-loop", "rust zig", "loop", r"\.flush\(\)", "flush inside a loop: flush once after it"),
    P("flush-in-loop", "cpp", "loop", r"\.flush\(\)|\bstd::flush\b|\bfflush\s*\(", "flush inside a loop: flush once after it"),
    P("io-call-in-loop", "rust", "loop", r"\bFile::(?:open|create)\s*\(|\bfs::\w+\s*\(|\.sync_(?:all|data)\(\)", "system call per iteration: batch the work or hoist the call"),
    P("io-call-in-loop", "cpp", "loop", r"\b(?:fopen|fsync|fdatasync|open|stat)\s*\(|::(?:read|write|send|recv)\s*\(|\bstd::[io]?fstream\b", "system call per iteration: batch the work or hoist the call"),
    P("io-call-in-loop", "zig", "loop", r"\.(?:openFile|createFile|sync|stat)\s*\(", "system call per iteration: batch the work or hoist the call"),
    # --- 13 correctness
    P("compound-assertion", "rust", "any", r"\b(?:debug_)?assert!\s*\((?:[^;()]|\([^()]*\))*&&", "split the assertion: one condition each, so a failure names its cause"),
    P("compound-assertion", "cpp", "any", r"\b(?:assert|CHECK|DCHECK)\s*\((?:[^;()]|\([^()]*\))*&&", "split the assertion: one condition each, so a failure names its cause"),
    P("compound-assertion", "zig", "any", r"\bassert\s*\((?:[^;()]|\([^()]*\))*\band\b", "split the assertion: one condition each, so a failure names its cause"),
    P("swallowed-error", "rust", "nontest", r"\blet\s+_\s*=\s*[\w:.]+\s*\(|\.ok\(\)\s*;", "error discarded: handle it, or propagate it with `?`"),
    P("swallowed-error", "cpp", "nontest", r"\bcatch\s*\(\s*\.\.\.\s*\)\s*\{\s*\}", "empty catch-all: handle the error or let it propagate"),
    P("swallowed-error", "zig", "nontest", r"\bcatch\s*(?:\|\w+\|)?\s*\{\s*\}|\bcatch\s+unreachable\b", "error discarded: handle it, or return it with `try`"),
    P("exception-in-hot-path", "cpp", "hot", r"\bthrow\b|\btry\s*\{", "exceptions on a hot path: return an error value and keep the slow path out of line"),
]

JUSTIFIED = [
    # (rule, languages, regex, words that justify it in a nearby comment, message)
    ("seqcst-unjustified", "rust cpp zig", r"\bSeqCst\b|\bmemory_order_seq_cst\b|\.seq_cst\b", r"\w",
     "SeqCst is rarely needed: use Relaxed for counters and Release/Acquire for hand-offs, or say why in a comment"),
    ("unbounded-loop", "rust", r"(?<![\w.])loop\s*\{|\bwhile\s+true\b", r"(?i)bound|until|forever|event loop",
     "loop without a stated bound: say in a comment what ends it"),
    ("unbounded-loop", "cpp", r"\bfor\s*\(\s*;\s*;\s*\)|\bwhile\s*\(\s*(?:true|1)\s*\)", r"(?i)bound|until|forever|event loop",
     "loop without a stated bound: say in a comment what ends it"),
    ("unbounded-loop", "zig", r"\bwhile\s*\(\s*true\s*\)", r"(?i)bound|until|forever|event loop",
     "loop without a stated bound: say in a comment what ends it"),
    ("float-mode-unjustified", "zig", r"@setFloatMode\(\s*\.optimized\s*\)", r"\w",
     "@setFloatMode(.optimized) changes results: say in a comment why that is acceptable here"),
]

BRANCH = {"rust": r"(?<![\w.])(?:if|match)\b", "cpp": r"(?<![\w.])(?:if|switch)\s*\(", "zig": r"(?<![\w.@])(?:if|switch)\s*\("}
ASSERTION = {"rust": r"\b(?:debug_)?assert(?:_eq|_ne)?!\s*\(", "cpp": r"\b(?:assert|static_assert|CHECK|DCHECK)\s*\(", "zig": r"\bassert\s*\(|\bexpect\w*\s*\("}
CLOCK = {"rust": r"\bInstant::now\b", "cpp": r"\b(?:steady_clock|high_resolution_clock)::now\b|\b__rdtsc\b", "zig": r"\bTimestamp\.now\b|\bnanoTimestamp\b|\bTimer\.start\b"}
BLACK_BOX = {"rust": r"\bblack_box\b", "cpp": r"\bDoNotOptimize\b|\bdo_not_optimize\b|asm\s+volatile", "zig": r"\bdoNotOptimizeAway\b"}


def check_patterns(source: SourceFile) -> None:
    language = source.language
    for rule, languages, scope, regex, message in PATTERNS:
        if language not in languages:
            continue
        for m in regex.finditer(source.code):
            offset = m.start()
            function = source.function_at(offset)
            if scope == "params":
                if not any(f.header_start <= offset < f.body_start for f in source.functions):
                    continue
            elif scope == "nontest":
                if source.in_test(offset) or (function and function.is_test):
                    continue
            elif scope != "any":
                if function is None or function.is_test:
                    continue
                if "hot" in scope and not function.is_hot:
                    continue
                if "loop" in scope and not source.in_loop(offset):
                    continue
            source.report(offset, rule, message)

    allocation = re.compile(ALLOCATION[language])
    for m in allocation.finditer(source.code):
        function = source.function_at(m.start())
        if function is None or function.is_test:
            continue
        offset = m.end() - len(m.group(0).lstrip())  # a match may begin with the newline before a declaration
        if function.is_hot:
            source.report(offset, "allocation-in-hot-path", "allocation on a hot path: reuse a buffer, or take memory from an arena")
        elif source.in_loop(offset):
            source.report(offset, "allocation-in-loop", "allocation inside a loop: hoist the buffer out and reuse it, or use an arena")

    for rule, languages, regex, justification, message in JUSTIFIED:
        if language not in languages:
            continue
        for m in re.finditer(regex, source.code):
            line = source.line_of(m.start())
            comment = re.sub(r"tidy:.*", "", source.comment_near(line))
            if not re.search(justification, comment):
                source.report(m.start(), rule, message)

    for m in re.finditer(BRANCH[language], source.code):
        function = source.function_at(m.start())
        if function and function.is_hot and not function.is_test and source.in_loop(m.start()):
            comment = source.comment_near(source.line_of(m.start()))
            if not re.search(r"(?i)predictable|rare|never|always|cold", comment):
                source.report(m.start(), "branch-in-hot-loop",
                              "data-dependent branch in a hot loop: make it branchless, or note in a comment why it is predictable")


# --------------------------------------------------------------------------- structural rules

def split_top_level(text: str) -> list[str]:
    parts, depth, current = [], 0, []
    for c in text:
        if c in "(<[{":
            depth += 1
        elif c in ")>]}":
            depth -= 1
        if c == "," and depth == 0:
            parts.append("".join(current))
            current = []
        else:
            current.append(c)
    parts.append("".join(current))
    return [part.strip() for part in parts if part.strip()]


def check_functions(source: SourceFile) -> None:
    language = source.language
    assertion = re.compile(ASSERTION[language])
    for function in source.functions:
        if function.name == "test":
            continue
        line = source.line_of(function.header_start)
        body = source.code[function.body_start + 1:function.body_end]
        lines = source.body_line_count(function)
        params = [p for p in split_top_level(function.params) if not re.match(r"(&\s*(mut\s+)?)?self\b|void$", p)]

        if lines > FUNCTION_LINES_MAX:
            source.report(line, "function-too-long", f"`{function.name}` is {lines} lines; the limit is {FUNCTION_LINES_MAX}. "
                          "Keep control flow in the parent and move straight-line work into helpers", is_line=True)
        if len(params) > PARAMETERS_MAX:
            source.report(line, "too-many-parameters", f"`{function.name}` takes {len(params)} parameters; more than {PARAMETERS_MAX} "
                          "spill to the stack. Group them in a struct", is_line=True)
        bools = [p for p in params if re.search(r":\s*bool\b|^\s*(?:const\s+)?bool\b", p)]
        if len(bools) >= 2:
            source.report(line, "bool-parameters", f"`{function.name}` takes {len(bools)} bool parameters: call sites become "
                          "unreadable. Use an enum or an options struct", is_line=True)
        if re.search(r"(?<![\w.:])" + re.escape(function.name) + r"\s*\(", body) and not function.name.startswith("operator"):
            source.report(line, "recursion", f"`{function.name}` calls itself: use a loop, or state the depth bound in an allow", is_line=True)
        if function.is_test:
            continue
        # `fn List(comptime T: type) type` is a type definition; its methods are checked on their own.
        if language == "zig" and re.search(r"\)\s*type\s*$", source.code[function.header_start:function.body_start]):
            continue
        if lines > ASSERTION_FREE_LINES_MAX and not assertion.search(body):
            source.report(line, "missing-assertion", f"`{function.name}` is {lines} lines with no assertion: "
                          "assert what it expects of its arguments and its result", is_line=True)

        generic = {
            "rust": re.search(r"<[^>]*\b[A-Z]\w*\s*(?::|,|>)", function.prefix[function.prefix.rfind("\n") + 1:] + " ")
                    and not re.search(r":\s*(?:macerator::)?Simd\b", function.prefix),
            "cpp": re.search(r"\btemplate\s*<", function.prefix),
            "zig": re.search(r"\banytype\b|\bcomptime\s+\w+\s*:\s*type\b", function.params),
        }[language]
        if generic and lines > GENERIC_LINES_MAX:
            source.report(line, "large-generic-function", f"generic `{function.name}` is {lines} lines and is compiled once per type: "
                          "keep a thin generic shell and move the body into a non-generic function", is_line=True)

        forced_inline = {
            "rust": "inline(always)" in function.prefix,
            "cpp": bool(re.search(r"always_inline|__forceinline", function.prefix)),
            "zig": bool(re.search(r"\binline\s*$", function.prefix)),
        }[language]
        if forced_inline and lines > INLINE_LINES_MAX:
            source.report(line, "inline-always-large", f"`{function.name}` is {lines} lines and forced inline: "
                          "every call site gets a copy. Let the compiler decide", is_line=True)

        if language == "rust":
            check_rust_simd(source, function, body, line)
            check_missing_reserve(source, function, body, r"let\s+mut\s+(\w+)(?:\s*:[^=;]+)?\s*=\s*Vec::new\(\)",
                                  r"\.push\(", r"\.reserve\(|with_capacity|\.extend\(")
            if re.search(r"\bFile::(?:create|open)\s*\(|\bOpenOptions\b", body) and \
                    re.search(r"\bwrite(?:ln)?!\s*\(|\.write_all\(", body) and "BufWriter" not in body:
                source.report(line, "unbuffered-file-write", f"`{function.name}` writes to a File directly: "
                              "wrap it in a BufWriter and flush once", is_line=True)
        elif language == "zig":
            check_missing_reserve(source, function, body, r"var\s+(\w+)\s*:\s*[\w.]*ArrayList\([^;=]*=\s*\.empty",
                                  r"\.append\(", r"ensure(?:Total|Unused)Capacity|initCapacity|AssumeCapacity")
            for m in re.finditer(r"\b(\w+)\.\w+\s*[+\-*|&^]%?=(?!=)", body):
                offset = function.body_start + 1 + m.start()
                if source.in_loop(offset) and re.search(r"\b" + m.group(1) + r"\s*:\s*\*(?!const)", function.params):
                    source.report(offset, "member-accumulator", "accumulating through a pointer inside a loop: "
                                  "use a local and store once (the pointer may alias the data being read)")
        elif language == "cpp":
            if re.search(r"\b_mm(?:256|512)_\w+", body) and not re.search(r"target\s*\(", function.prefix):
                source.report(line, "intrinsics-without-target", f"`{function.name}` uses AVX intrinsics without a target attribute: "
                              "add [[gnu::target(\"avx2\")]] and dispatch on the CPU at run time", is_line=True)

        if function.is_hot:
            declared = {"rust": r"let\s+mut\s+(\w+)(?:\s*:\s*f(?:32|64))?\s*=\s*0\.0(?:_?f(?:32|64))?\s*;|let\s+mut\s+(\w+)\s*:\s*f(?:32|64)\s*=",
                        "cpp": r"\b(?:float|double)\s+(\w+)\s*(?:=|\{)", "zig": r"\bvar\s+(\w+)\s*:\s*f(?:32|64)\s*="}[language]
            for m in re.finditer(declared, body):
                name = next(group for group in m.groups() if group)
                for use in re.finditer(r"\b" + name + r"\s*\+=", body):
                    offset = function.body_start + 1 + use.start()
                    if source.in_loop(offset):
                        source.report(offset, "float-reduction-single-chain", f"`{name}` is one floating-point dependency chain: "
                                      "use several accumulators or explicit SIMD (the compiler may not reorder float sums)")
                        break


def check_rust_simd(source: SourceFile, function: Function, body: str, line: int) -> None:
    if not re.search(r":\s*(?:macerator::)?Simd\b", function.prefix + function.params):
        return
    if "with_simd" in function.prefix:
        # Handled means: the remainder is read, or the scan continues from an index (`values[base..]`).
        if "chunks_exact" in body and not re.search(r"\.(?:into_)?remainder\(\)|vload_partial|\[\s*\w+\s*\.\.\s*\]", body):
            source.report(line, "simd-tail-unhandled", f"`{function.name}` iterates chunks_exact but never reads the remainder: "
                          "the last few elements are dropped", is_line=True)
    elif "inline(always)" not in function.prefix:
        source.report(line, "simd-helper-not-inlined", f"`{function.name}` is generic over a SIMD backend but not #[inline(always)]: "
                      "it will be compiled without the backend's CPU features", is_line=True)


def check_missing_reserve(source: SourceFile, function: Function, body: str, declare: str, push: str, reserve: str) -> None:
    for m in re.finditer(declare, body):
        name = m.group(1)
        if re.search(r"\b" + name + r"(?:\.items)?\s*" + reserve, body) or re.search(reserve.split("|")[-1], m.group(0)):
            continue
        for use in re.finditer(r"\b" + name + push, body):
            offset = function.body_start + 1 + use.start()
            if source.in_ranges(offset, source.counted_loops):
                source.report(function.body_start + 1 + m.start(), "missing-reserve",
                              f"`{name}` grows inside a counted loop from empty: reserve the capacity once before the loop")
                break


# --------------------------------------------------------------------------- structs and layout

PRIMITIVES = {
    "rust": {"u8": 1, "i8": 1, "bool": 1, "u16": 2, "i16": 2, "u32": 4, "i32": 4, "f32": 4, "char": 4,
             "u64": 8, "i64": 8, "f64": 8, "usize": 8, "isize": 8, "u128": 16, "i128": 16},
    "zig": {"u8": 1, "i8": 1, "bool": 1, "u16": 2, "i16": 2, "u32": 4, "i32": 4, "f32": 4,
            "u64": 8, "i64": 8, "f64": 8, "usize": 8, "isize": 8, "u128": 16, "i128": 16},
    "cpp": {"bool": 1, "char": 1, "std::uint8_t": 1, "std::int8_t": 1, "uint8_t": 1, "int8_t": 1, "std::byte": 1,
            "unsigned char": 1, "signed char": 1, "short": 2, "std::uint16_t": 2, "std::int16_t": 2, "uint16_t": 2,
            "int16_t": 2, "unsigned short": 2, "int": 4, "unsigned": 4, "unsigned int": 4, "float": 4,
            "std::uint32_t": 4, "std::int32_t": 4, "uint32_t": 4, "int32_t": 4, "long": 8, "unsigned long": 8,
            "long long": 8, "unsigned long long": 8, "double": 8, "std::uint64_t": 8, "std::int64_t": 8,
            "uint64_t": 8, "int64_t": 8, "std::size_t": 8, "size_t": 8, "std::ptrdiff_t": 8, "std::uintptr_t": 8},
}
ARCH_SIZED = {"rust": r"^[ui]size$", "zig": r"^[ui]size$", "cpp": r"^(?:unsigned\s+)?long$|^(?:std::)?(?:size_t|ptrdiff_t)$"}


def size_and_align(type_text: str, language: str) -> tuple[int, int] | None:
    type_text = " ".join(type_text.split())
    primitives = PRIMITIVES[language]
    if type_text in primitives:
        size = primitives[type_text]
        return size, size
    if language == "rust" and (m := re.fullmatch(r"\[(.+);\s*(\d+)\]", type_text)):
        inner = size_and_align(m.group(1), language)
        return (inner[0] * int(m.group(2)), inner[1]) if inner else None
    if language == "zig" and (m := re.fullmatch(r"\[(\d+)\](.+)", type_text)):
        inner = size_and_align(m.group(2), language)
        return (inner[0] * int(m.group(1)), inner[1]) if inner else None
    if re.match(r"\*|&|\[\*\]|\?\*|Box<|Option<&|Option<Box<", type_text) or type_text.endswith("*"):
        return 8, 8
    return None


def struct_fields(body: str, language: str) -> list[tuple[str, str]] | None:
    """(name, type) per field, or None when the struct has anything this parser does not model."""
    fields = []
    if language in ("rust", "zig"):
        for part in split_top_level(body):
            part = re.sub(r"^(?:pub(?:\([^)]*\))?\s+)?", "", part.strip())
            if language == "zig" and re.match(r"(?:pub\s+)?(?:const|var|fn|comptime|test|usingnamespace)\b", part):
                return fields if fields else None  # declarations follow the fields
            m = re.match(r"(?:#\[[^\]]*\]\s*)*(\w+)\s*:\s*([^=]+?)(?:\s+align\([^)]*\))?(?:\s*=.*)?$", part, re.S)
            if not m:
                return None
            fields.append((m.group(1), m.group(2).strip()))
        return fields
    for statement in body.split(";"):
        statement = statement.strip()
        if not statement:
            continue
        if re.search(r"[(){}]|\b(?:virtual|static|using|friend|template|typedef|public|private|protected|operator)\b", statement):
            return None
        m = re.match(r"(?:const\s+)?([\w:\s]+?[\w>])\s*(\*?)\s*(\w+(?:\s*,\s*\w+)*)\s*(?:\[(\d+)\])?\s*(?:=.*)?$", statement, re.S)
        if not m:
            return None
        base = m.group(1).strip() + m.group(2)
        for name in m.group(3).split(","):
            fields.append((name.strip(), f"{base}[{m.group(4)}]" if m.group(4) else base))
    return fields


def cpp_size_and_align(type_text: str) -> tuple[int, int] | None:
    if (m := re.fullmatch(r"(.+)\[(\d+)\]", type_text)):
        inner = size_and_align(m.group(1), "cpp")
        return (inner[0] * int(m.group(2)), inner[1]) if inner else None
    return size_and_align(type_text, "cpp")


def laid_out_size(sizes: list[tuple[int, int]]) -> int:
    offset, alignment = 0, 1
    for size, align in sizes:
        offset = (offset + align - 1) // align * align + size
        alignment = max(alignment, align)
    return (offset + alignment - 1) // alignment * alignment


def check_structs(source: SourceFile) -> None:
    language = source.language
    pattern = {
        "rust": r"((?:#\[[^\]]*\]\s*)*)(?:pub(?:\([^)]*\))?\s+)?struct\s+(\w+)\s*(?:<[^>{]*>)?\s*\{",
        "zig": r"()(?:pub\s+)?const\s+(\w+)\s*=\s*(extern\s+|packed\s+)?struct\s*\{",
        "cpp": r"()\b(?:struct|class)\s+(?:alignas\([^)]*\)\s*)?(\w+)\s*(final\s*)?(:[^{;]*)?\{",
    }[language]
    for m in re.finditer(pattern, source.code):
        open_brace = m.end() - 1
        if open_brace not in source.braces or source.in_test(m.start()):
            continue
        name = m.group(2)
        body = source.code[open_brace + 1:source.braces[open_brace]]
        fields = struct_fields(body, language)
        hot = source.hot_file
        if hot and not re.search(r"size_?[oO]f\s*(?:::<|\(|<)\s*" + name + r"\b|@sizeOf\(\s*" + name + r"\s*\)", source.code):
            source.report(m.start(2), "missing-size-assert", f"`{name}` is in a hot file without a size assertion: "
                          "pin its size at compile time so a new field cannot silently bloat it")
        if not fields:
            continue
        bools = [field for field, type_text in fields if type_text == "bool"]
        if len(bools) >= 3:
            source.report(m.start(2), "bool-heavy-struct", f"`{name}` has {len(bools)} bool fields: pack them into one flags "
                          "integer, or split the objects into one array per state")
        if hot:
            for field, type_text in fields:
                if re.search(ARCH_SIZED[language], type_text):
                    source.report(m.start(2), "arch-sized-field", f"`{name}.{field}` is `{type_text}`: use an explicitly sized type "
                                  "(u32 indices halve the footprint of u64 ones)")
        fixed_layout = (language == "cpp" and not m.group(4)) or (language == "rust" and "repr(C" in m.group(1)) or \
                       (language == "zig" and (m.group(3) or "").startswith("extern"))
        if not fixed_layout:
            continue
        sizer = cpp_size_and_align if language == "cpp" else (lambda t: size_and_align(t, language))
        sizes = [sizer(type_text) for _, type_text in fields]
        if any(size is None for size in sizes):
            continue
        current = laid_out_size(sizes)
        order = sorted(range(len(fields)), key=lambda i: (-sizes[i][1], i))
        best = laid_out_size([sizes[i] for i in order])
        if best < current:
            names = ", ".join(fields[i][0] for i in order)
            source.report(m.start(2), "struct-padding", f"`{name}` is {current} bytes but {best} would do: "
                          f"order fields by decreasing alignment ({names})")


# --------------------------------------------------------------------------- file-level rules

def check_file(source: SourceFile) -> None:
    language = source.language
    for number, raw in enumerate(source.text.split("\n"), start=1):
        if len(raw) > LINE_COLUMNS_MAX and "://" not in raw:
            source.report(number, "line-too-long", f"{len(raw)} columns; the limit is {LINE_COLUMNS_MAX}", is_line=True)
    if (source.is_bench_file or re.search(r"\bfn\s+bench\b|\bbench\s*\(", source.code)) and \
            (clock := re.search(CLOCK[language], source.code)) and not re.search(BLACK_BOX[language], source.code):
        source.report(clock.start(), "benchmark-without-black-box", "timing code with no black box: "
                      "the compiler may delete or pre-compute the work being measured")
    # String contents are blanked in `source.code`, so this rule reads the raw text.
    newer_cpu = r"target\s*\(\s*\"[^\"]*(?:avx|sse4|bmi|fma)"
    if language == "cpp" and (m := re.search(newer_cpu, source.text)) and \
            not re.search(r"cpu_supports|cpu_is|__cpuid|IsProcessorFeaturePresent|target_clones", source.code):
        source.report(m.start(), "simd-without-dispatch", "this file compiles code for a newer CPU but never checks the CPU: "
                      "dispatch with __builtin_cpu_supports before calling it")


def check_build_file(path: str, text: str) -> list[Finding]:
    findings = []

    def report(pattern: str, rule: str, message: str) -> None:
        for number, line in enumerate(text.split("\n"), start=1):
            stripped = line.split("#")[0] if not path.endswith(".zig") else line.split("//")[0]
            if re.search(pattern, stripped):
                findings.append(Finding(path, number, rule, message))

    report(r"-m(?:arch|tune|cpu)=native|target-cpu=native", "native-cpu-in-build",
           "building for the build machine's CPU: name a baseline (x86-64-v3) and dispatch at run time")
    report(r"-ffast-math|-Ofast|-funsafe-math-optimizations|/fp:fast", "fast-math-global",
           "fast-math for the whole build changes every float result: relax only the functions that need it")
    name = Path(path).name
    if name == "Cargo.toml" and "[package]" in text:
        release = re.search(r"\[profile\.release\](.*?)(?=\n\[|\Z)", text, re.S)
        if not release or not re.search(r"\blto\s*=", release.group(1)) or not re.search(r"codegen-units\s*=\s*1\b", release.group(1)):
            findings.append(Finding(path, 1, "release-build-not-tuned",
                                    "[profile.release] should set lto and codegen-units = 1 so inlining crosses crate boundaries"))
        if not re.search(r"^\[(?:workspace\.)?lints", text, re.M):
            findings.append(Finding(path, 1, "warnings-not-strict", "no [lints] table: adopt the clippy set from lint/rust/lints.toml"))
    if name == "CMakeLists.txt" and "project(" in text:
        if not re.search(r"INTERPROCEDURAL_OPTIMIZATION|-flto|PerfLint", text):
            findings.append(Finding(path, 1, "release-build-not-tuned",
                                    "enable CMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE so inlining crosses translation units"))
        if not re.search(r"-Werror|PerfLint|perf_lint", text):
            findings.append(Finding(path, 1, "warnings-not-strict", "warnings are not errors: include lint/cpp/PerfLint.cmake"))
    return findings


# --------------------------------------------------------------------------- driver

def apply_suppressions(source: SourceFile) -> list[Finding]:
    allow_file: set[str] = set()
    allow_line: dict[int, set[str]] = {}
    allow_span: list[tuple[int, int, set[str]]] = []
    extra = []
    for line, comment in source.comments.items():
        for m in re.finditer(r"tidy:\s*allow(-file|-fn)?\(([^)]*)\)\s*(.*)", comment):
            rules = {rule.strip() for rule in m.group(2).split(",") if rule.strip()}
            if len(m.group(3).strip()) < 3:
                extra.append(Finding(source.path, line, "allow-without-reason", "an allow needs a reason after the parenthesis"))
            if m.group(1) == "-file":
                allow_file |= rules
            elif m.group(1) == "-fn":
                # The next brace-delimited item after the comment: a function, a struct, a test.
                brace = source.code.find("{", source.line_starts[line - 1])
                if brace >= 0:
                    allow_span.append((line, source.line_of(source.braces.get(brace, brace)), rules))
            else:
                target = line
                if not source.line_text(line).strip():  # comment on its own line: applies to the next code line
                    target = line + 1
                    while target in source.comments and not source.line_text(target).strip():
                        target += 1
                allow_line.setdefault(line, set()).update(rules)
                allow_line.setdefault(target, set()).update(rules)

    def allowed(finding: Finding) -> bool:
        if finding.rule in allow_file or finding.rule in allow_line.get(finding.line, set()):
            return True
        return any(first <= finding.line <= last and finding.rule in rules for first, last, rules in allow_span)

    kept = [f for f in source.findings if not allowed(f)]
    return sorted(set(kept + extra), key=lambda f: (f.line, f.rule))


def lint_text(path: str, text: str, path_heuristics: bool = True) -> list[Finding]:
    name = Path(path).name
    findings: list[Finding] = []
    if name in BUILD_FILE_NAMES:
        findings += check_build_file(path, text)
    language = LANGUAGE_BY_SUFFIX.get(Path(path).suffix)
    if language is None:
        return findings
    source = SourceFile(path, text, language, path_heuristics)
    check_file(source)
    check_patterns(source)
    check_functions(source)
    check_structs(source)
    return findings + apply_suppressions(source)


def collect(paths: list[str]) -> list[Path]:
    files = []
    for raw in paths:
        path = Path(raw)
        if path.is_dir():
            for child in sorted(path.rglob("*")):
                if child.is_file() and not (set(child.parts) & SKIPPED_DIRECTORIES) and \
                        (child.suffix in LANGUAGE_BY_SUFFIX or child.name in BUILD_FILE_NAMES):
                    files.append(child)
        elif path.is_file():
            files.append(path)
    return files


def main() -> int:
    parser = argparse.ArgumentParser(description="Mechanical-sympathy linter for Rust, C++ and Zig.")
    parser.add_argument("paths", nargs="*")
    parser.add_argument("--list-rules", action="store_true", help="print the rule catalog and exit")
    parser.add_argument("--strict", action="store_true", help="treat warnings as errors")
    parser.add_argument("--format", choices=["text", "cargo", "github"], default="text")
    parser.add_argument("--allow", action="append", default=[], help="rule to switch off everywhere (repeatable)")
    parser.add_argument("--no-path-heuristics", action="store_true", help="do not treat *test*/*bench* files as test code")
    args = parser.parse_args()
    if args.list_rules:
        for rule, (topic, text) in sorted(RULES.items(), key=lambda item: (item[1][0], item[0])):
            print(f"{topic:>2}  {rule:<32} {'warning' if rule in WARNINGS else 'error':<8} {text}")
        return 0
    if not args.paths:
        parser.error("give at least one file or directory")

    findings: list[Finding] = []
    for file in collect(args.paths):
        findings += lint_text(str(file), file.read_text(encoding="utf-8", errors="replace"), not args.no_path_heuristics)
    findings = [f for f in findings if f.rule not in args.allow]

    errors = 0
    for finding in findings:
        level = "error" if args.strict else finding.level
        errors += level == "error"
        where = f"{finding.path}:{finding.line}"
        if args.format == "cargo":
            print(f"cargo::{level}={where}: [{finding.rule}] {finding.message}")
        elif args.format == "github":
            print(f"::{level} file={finding.path},line={finding.line},title={finding.rule}::{finding.message}")
        else:
            print(f"{where}: {level}: [{finding.rule}] {finding.message}")
    if findings and args.format == "text":
        print(f"perf_tidy: {errors} error(s), {len(findings) - errors} warning(s)", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
