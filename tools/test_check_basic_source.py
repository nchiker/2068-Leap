#!/usr/bin/env python3
"""test_check_basic_source.py -- regression coverage for tools/check_basic_source.py.

Covers both real findings (DIM literal out-of-bounds, the FOR-loop off-by-one
heuristic, label-table budget overflow) and, just as importantly, the false
positives found and fixed while building this tool against this project's own
real fixtures: REM/`;;`-comment content, `@PLACEHOLDER@` template markers, and
(no longer applicable now that the redundant checks were dropped, but the
underlying lesson stands) anything the ROM's own real whole-program checker
already validates authoritatively shouldn't be reimplemented here at all.
"""
import sys

sys.path.insert(0, "tools")
import check_basic_source as cbs

FAILURES = []


def check(name, actual, expected):
    if actual != expected:
        FAILURES.append(f"{name}: expected {expected!r}, got {actual!r}")


def findings_text(source):
    return [f.message for f in cbs.check_source(source)]


# ---- DIM bounds: literal out-of-bounds ------------------------------------

check(
    "literal out-of-bounds flagged",
    len(findings_text("DIM A(3)\nX = A(10)\n")),
    1,
)
check(
    "in-bounds literal not flagged",
    len(findings_text("DIM A(3)\nX = A(0)\nY = A(2)\n")),
    0,
)
check(
    "the DIM line itself is never flagged as an access",
    len(findings_text("DIM A(3)\n")),
    0,
)

# ---- DIM bounds: FOR-loop off-by-one heuristic -----------------------------

check(
    "FOR x = 1 TO n indexing a same-sized array is flagged",
    len(findings_text("DIM A(5)\nFOR I = 1 TO 5\nX = A(I)\nNEXT I\n")),
    1,
)
check(
    "FOR x = 0 TO n-1 indexing is NOT flagged (correct 0-indexed usage)",
    len(findings_text("DIM A(5)\nFOR I = 0 TO 4\nX = A(I)\nNEXT I\n")),
    0,
)

# ---- label table budget ----------------------------------------------------

# Budget is derived live from include/sysvars.inc; build a program certain to
# exceed it regardless of the real value. Label names are letters-only in this
# dialect (digits/underscores aren't valid -- confirmed the hard way per
# docs/basic_language_reference.md), so repeat one real label name enough
# times to blow any realistic budget rather than trying to generate unique
# ones; check_label_budget sums bytes over every match, duplicates included.
over_budget_labels = "\n".join(["LOOPLABEL:"] * (cbs.LABEL_TABLE_MAXLEN // 4 + 5))
check(
    "enough long labels overflow the real, source-derived budget",
    len(findings_text(over_budget_labels)) >= 1,
    True,
)
check(
    "one short label never overflows",
    len(findings_text("loop:\nX = 1\n")),
    0,
)

# ---- false positives found against this project's own real fixtures -------

check(
    "';;' documentation-header lines are never scanned as source",
    len(
        findings_text(
            ";; DIM A(15): per-target data, 3 targets x 5 fields\n"
            "DIM A(15)\nDIM B(9)\nA(12)=2\n"
        )
    ),
    0,
)
check(
    "blank lines are inert",
    len(findings_text("\n\nDIM A(3)\n\nX = A(0)\n\n")),
    0,
)
check(
    "label-table budget math ignores ';;' comment lines that merely mention EQU/labels",
    len(findings_text(";; not a real label: LABEL_TABLE_MAXLEN EQU 128\nloop:\n")),
    0,
)

# ---- extract_label_table_budget() reads the real source, not a hardcoded copy --

real_budget = cbs.extract_label_table_budget()
check("extracted budget is a sane positive byte count", 0 < real_budget <= 65536, True)

# Prove it's a live read, not a hardcoded copy: point it at a fake sysvars.inc
# with a deliberately different value and confirm that value comes back.
import tempfile
from pathlib import Path

with tempfile.TemporaryDirectory() as tmp:
    fake_root = Path(tmp)
    (fake_root / "include").mkdir()
    (fake_root / "include" / "sysvars.inc").write_text("LABEL_TABLE_MAXLEN  EQU 77\n")
    check(
        "extract_label_table_budget reads whatever the source currently says, live",
        cbs.extract_label_table_budget(fake_root),
        77,
    )

# ---- results ----------------------------------------------------------

if FAILURES:
    print(f"FAIL ({len(FAILURES)}):")
    for f in FAILURES:
        print(f"  {f}")
    sys.exit(1)
else:
    print("PASS: all check_basic_source checks passed")
