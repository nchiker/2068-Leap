#!/usr/bin/env python3
"""check_basic_source.py -- pre-flight validator for what 2068-Leap's own
whole-program checker (rom/exrom_checker.asm) deliberately does NOT catch.

Idea: nchiker/2068-Leap#3 ("a pre-flight dialect validator, in the spirit of
zmakebas+"). The first draft of this tool reimplemented single-letter-name
and PRINT-pattern checks in Python -- but the ROM already has a real,
authoritative whole-program static checker that runs before every RUN, and
it already enforces both of those:

  - Single-letter variable/array names: KTAB_BASIC_VALIDATE_VAR_LETTER is
    called from .check_dim, .check_assignment, .check_array_assignment,
    .check_next, .check_input, .check_goto (rom/exrom_checker.asm).
  - The PRINT string;numeric pattern (github.com/nchiker/2068-Leap/issues/1):
    .check_print now calls BASIC_EXPECT_STATEMENT_END, same as the runtime
    fix.

Reimplementing either of those in Python would mean maintaining a second,
inferior parser that can only drift from the real one (exactly what
happened to this file's own first draft: a hand-copied keyword list had
already silently dropped a real keyword before the drift was even noticed).
For anything the real checker already validates, the actual pre-flight
check is to run it: `ts2068-debug type <program>` then read the checker's
own "N ERROR(S) FOUND" verdict (see the 2068-debug skill) -- authoritative,
zero drift, no second implementation to maintain.

What's left, and what this script actually checks, is the two things the
real checker's own source says it deliberately does NOT validate:

  1. DIM bounds. .check_dim's own comment: "whether <size> is a sensible
     positive value [is a] runtime-only question" -- DIM's argument is a
     full expression (KTAB_BASIC_EVAL_EXPR), not just a literal, so this
     can't be fully checked statically in general, but a LITERAL
     out-of-bounds access, or a `FOR x = 1 TO n` loop paired with an array
     DIM'd to that same n (the classic 0-vs-1-indexed off-by-one), both
     are checkable from the source text alone.
  2. The label table's fixed byte budget (LABEL_TABLE_MAXLEN, derived live
     from include/sysvars.inc below, not hardcoded). The checker's own
     rebuild pass calls MEM_LABEL_ADD but "ignore[s] failure" on a full
     table (rom/exrom_checker.asm) -- a label past the budget silently
     fails to register, producing a confusing "LABEL NOT FOUND" at the
     GOTO/GOSUB site instead of at the label definition.

Like tools/check_asm.py, this is a source-only sanity pass, not a
substitute for actually running the program -- or, for anything not listed
above, for actually running the real checker.
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

_FALLBACK_LABEL_TABLE_MAXLEN = 128
_LABEL_TABLE_MAXLEN_RE = re.compile(r"\bLABEL_TABLE_MAXLEN\s+EQU\s+(\d+)")


def extract_label_table_budget(repo_root: Path = REPO_ROOT) -> int:
    """Read the real budget from source instead of hardcoding it a second time."""
    path = repo_root / "include" / "sysvars.inc"
    if path.exists():
        m = _LABEL_TABLE_MAXLEN_RE.search(path.read_text(errors="replace"))
        if m:
            return int(m.group(1))
    print(
        f"check_basic_source: warning: could not read LABEL_TABLE_MAXLEN from "
        f"{path}; falling back to a hardcoded {_FALLBACK_LABEL_TABLE_MAXLEN}, which "
        f"may be stale",
        file=sys.stderr,
    )
    return _FALLBACK_LABEL_TABLE_MAXLEN


LABEL_TABLE_MAXLEN = extract_label_table_budget()
LABEL_COUNT_SIZE = 2      # table header: entry count
LABEL_NAMELEN_SIZE = 1    # per entry: [name_len:1][name][position:2]
LABEL_POS_SIZE = 2
LABEL_TABLE_USABLE = LABEL_TABLE_MAXLEN - LABEL_COUNT_SIZE

def _is_comment_line(line: str) -> bool:
    # Matches tools/type_basic.py's own filter exactly: blank lines and lines
    # starting with ';;' are this fixture format's documentation convention,
    # stripped before injection -- never reach the ROM, so never real source.
    stripped = line.strip()
    return not stripped or stripped.startswith(";;")


_LABEL_DEF_RE = re.compile(r"^([A-Za-z]+)\s*:\s*$")
_DIM_RE = re.compile(r"\bDIM\s+([A-Za-z])(\$?)\s*\(\s*(\d+)\s*\)", re.IGNORECASE)
_ARRAY_LITERAL_RE = re.compile(r"\b([A-Za-z])(\$?)\s*\(\s*(\d+)\s*\)")
_FOR_RE = re.compile(r"\bFOR\s+([A-Za-z])\s*=\s*1\s+TO\s+(\d+)\b", re.IGNORECASE)
_NEXT_RE = re.compile(r"\bNEXT\b", re.IGNORECASE)


@dataclass
class Finding:
    line: int
    message: str


def check_dim_bounds(lines: list[str]) -> list[Finding]:
    findings: list[Finding] = []
    bounds: dict[str, tuple[int, int]] = {}  # "A" or "A$" -> (size, dim_lineno)
    for lineno, line in enumerate(lines, 1):
        for m in _DIM_RE.finditer(line):
            name, suffix, size = m.group(1).upper(), m.group(2), int(m.group(3))
            bounds[name + suffix] = (size, lineno)

    if not bounds:
        return findings

    # Literal out-of-bounds access, anywhere in the program.
    for lineno, line in enumerate(lines, 1):
        stripped = re.sub(r'"[^"]*"', '""', line)
        for m in _ARRAY_LITERAL_RE.finditer(stripped):
            name, suffix, index = m.group(1).upper(), m.group(2), int(m.group(3))
            key = name + suffix
            if key in bounds and _DIM_RE.search(line) is None:  # not the DIM line itself
                size, dim_line = bounds[key]
                if index >= size:
                    findings.append(
                        Finding(
                            lineno,
                            f"{name}{suffix}({index}) is out of bounds -- DIM {name}{suffix}"
                            f"({size}) on line {dim_line} allocates valid indices 0..{size - 1}",
                        )
                    )

    # Heuristic: FOR x = 1 TO n paired with an access into an array DIM'd
    # with that same size n, inside the loop body -- classic off-by-one
    # (skips index 0, and the final iteration indexes one past the end).
    for_stack: list[tuple[str, int, int]] = []  # (var, size, for_lineno)
    for lineno, line in enumerate(lines, 1):
        for m in _FOR_RE.finditer(line):
            for_stack.append((m.group(1).upper(), int(m.group(2)), lineno))
        if _NEXT_RE.search(line) and for_stack:
            for_stack.pop()
            continue
        if for_stack:
            var, size, for_lineno = for_stack[-1]
            stripped = re.sub(r'"[^"]*"', '""', line)
            for arr_key, (arr_size, dim_line) in bounds.items():
                if arr_size == size and re.search(
                    rf"\b{re.escape(arr_key[0])}{re.escape(arr_key[1:])}\s*\(\s*{var}\s*\)",
                    stripped,
                    re.IGNORECASE,
                ):
                    findings.append(
                        Finding(
                            lineno,
                            f"FOR {var} = 1 TO {size} (line {for_lineno}) indexing "
                            f"{arr_key}({var}) -- DIM {arr_key}({size}) (line {dim_line}) is "
                            f"0-indexed with valid indices 0..{size - 1}; a loop from 1 skips "
                            f"index 0 and overruns index {size} on its last pass. If that's "
                            f"intentional (e.g. index 0 deliberately unused), ignore this.",
                        )
                    )
    return findings


def check_label_budget(lines: list[str]) -> list[Finding]:
    findings = []
    total = LABEL_COUNT_SIZE
    labels: list[tuple[str, int]] = []
    for lineno, line in enumerate(lines, 1):
        m = _LABEL_DEF_RE.match(line.strip())
        if m:
            name = m.group(1)
            labels.append((name, lineno))
            total += LABEL_NAMELEN_SIZE + len(name) + LABEL_POS_SIZE

    if total > LABEL_TABLE_MAXLEN:
        findings.append(
            Finding(
                0,
                f"label table would use {total} bytes across {len(labels)} labels, over the "
                f"fixed {LABEL_TABLE_MAXLEN}-byte budget ({LABEL_TABLE_USABLE} usable after the "
                f"{LABEL_COUNT_SIZE}-byte count header) -- labels past the limit silently fail "
                f"to register, producing 'LABEL NOT FOUND' at the GOTO/GOSUB site rather than "
                f"at the label definition. Shorten label names or use fewer labels.",
            )
        )
    return findings


def check_source(text: str) -> list[Finding]:
    # Blank out (not remove -- line numbers in findings must stay accurate)
    # comment/blank lines once, centrally, so every check below naturally
    # sees nothing there rather than each having to re-implement the filter.
    lines = ["" if _is_comment_line(l) else l for l in text.splitlines()]
    findings: list[Finding] = []
    findings += check_dim_bounds(lines)
    findings += check_label_budget(lines)
    return sorted(findings, key=lambda f: f.line)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="+", help="2068-Leap BASIC source file(s) to check")
    args = parser.parse_args(argv)

    exit_code = 0
    for path in args.paths:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
        findings = check_source(text)
        if not findings:
            print(f"{path}: no issues found")
            continue
        exit_code = 1
        for finding in findings:
            where = f"line {finding.line}" if finding.line else "whole program"
            print(f"{path}: {where}: {finding.message}")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
