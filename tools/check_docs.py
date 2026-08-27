#!/usr/bin/env python3
"""
check_docs.py — cross-checks docs against the source they describe.

check_asm.py catches bug classes in the code itself. This catches a
different, real class of bug this project has already shipped twice:
docs quietly going stale relative to the source of truth (both times
it was a *count* — punctuation characters and font glyphs — that
drifted after later additions). Nothing here replaces a human reading
the docs; it only catches numbers and lists that can be checked
mechanically against the actual tables.

Usage:
    python3 tools/check_docs.py

Exits non-zero if anything is flagged, so it can be used as a gate.

Checks performed, and which real staleness bug each guards against:

1. Font glyph count — kernel/graphics/graphics.asm's FONT_TABLE is
   counted directly (one DB line per glyph) and compared against every
   "N glyphs" mention in docs/programmers_reference.md. This exact
   count (83 -> 85) went stale in two docs after the '/' and '*'
   additions, and again would have after < and > if not re-checked by
   hand each time.

2. Punctuation character count — PUNCT_CHAR_COUNT (graphics.asm) is
   compared against every "N punctuation characters" mention in
   docs/programmers_reference.md. Same drift risk as #1, same root
   cause (a doc restates a count that lives in source).

3. HELP topic coverage — if rom/exrom_help.asm ever grows a
   HELP_TOPIC_TABLE again (HELP is currently a single, permanent
   EDITOR-only screen with no such table — see that file's own
   header), every topic name in it gets checked for a mention in both
   docs/programmers_reference.md and README.md, so a new HELP topic
   silently unmentioned in the docs gets flagged rather than
   discovered later. A no-op today.

4. Integrated fixture count — the current count quoted in README.md is
   checked against tests/*.txt so adding a regression cannot silently leave
   the project status stale again.

None of this checks prose accuracy or design intent — only that
specific numbers/names quoted in docs still match the tables they're
quoting.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GRAPHICS_ASM = ROOT / "kernel" / "graphics" / "graphics.asm"
BASIC_ASM = ROOT / "basic" / "basic.asm"
PROG_REF = ROOT / "docs" / "programmers_reference.md"
README = ROOT / "README.md"
SYSVARS = ROOT / "include" / "sysvars.inc"

issues = []


def read(path):
    return path.read_text()


def extract_block(text, start_label, end_label=None):
    """Return the source lines from start_label to end_label (or EOF)."""
    if end_label is None:
        pattern = re.compile(re.escape(start_label) + r":(.*)\Z", re.DOTALL)
    else:
        pattern = re.compile(
            re.escape(start_label) + r":(.*?)" + re.escape(end_label) + r":",
            re.DOTALL,
        )
    m = pattern.search(text)
    if not m:
        return None
    return m.group(1)


def count_db_lines(block):
    return len(re.findall(r"^\s*DB\s", block, re.MULTILINE))


def check_font_glyph_count():
    src = read(GRAPHICS_ASM)
    block = extract_block(src, "FONT_TABLE")
    if block is None:
        issues.append(
            "check_font_glyph_count: could not locate FONT_TABLE in graphics.asm "
            "— table layout may have changed; update this script."
        )
        return
    actual = count_db_lines(block)

    doc_text = read(PROG_REF)
    mentions = set(int(n) for n in re.findall(r"(\d+)\s+glyphs", doc_text))
    if not mentions:
        issues.append(
            "check_font_glyph_count: no 'N glyphs' mention found in "
            "programmers_reference.md to check against."
        )
        return
    for n in mentions:
        if n != actual:
            issues.append(
                f"check_font_glyph_count: programmers_reference.md says {n} glyphs, "
                f"but FONT_TABLE actually has {actual}."
            )


def check_punctuation_count():
    src = read(GRAPHICS_ASM)
    m = re.search(r"PUNCT_CHAR_COUNT\s+EQU\s+(\d+)", src)
    if not m:
        issues.append(
            "check_punctuation_count: could not find PUNCT_CHAR_COUNT EQU in "
            "graphics.asm — update this script if it moved/renamed."
        )
        return
    actual = int(m.group(1))

    doc_text = read(PROG_REF)
    mentions = set(
        int(n) for n in re.findall(r"(\d+)\s+punctuation\s+characters", doc_text)
    )
    if not mentions:
        issues.append(
            "check_punctuation_count: no 'N punctuation characters' mention found "
            "in programmers_reference.md to check against."
        )
        return
    for n in mentions:
        if n != actual:
            issues.append(
                f"check_punctuation_count: programmers_reference.md says {n} "
                f"punctuation characters, but PUNCT_CHAR_COUNT is actually {actual}."
            )


def extract_help_topic_names():
    # HELP_TOPIC_TABLE moved to rom/exrom_help.asm during HELP's EXROM
    # migration (2026-08-20) — check there first, fall back to
    # basic.asm in case a future move ever puts it back.
    src = read(ROOT / "rom" / "exrom_help.asm")
    table_m = re.search(r"HELP_TOPIC_TABLE:(.*?)\n\n", src, re.DOTALL)
    if not table_m:
        src = read(BASIC_ASM)
        table_m = re.search(r"HELP_TOPIC_TABLE:(.*?)\n\n", src, re.DOTALL)
    if not table_m:
        return None
    entries = re.findall(r"DW\s+(KW_HELP_TOPIC_\w+)", table_m.group(1))
    names = []
    for label in entries:
        name_m = re.search(re.escape(label) + r':\s*DB\s*"([^"]+)"', src)
        if name_m:
            names.append(name_m.group(1))
    return names


def check_help_topics_documented():
    # HELP was reverted to a single, permanent EDITOR-only screen
    # (2026-08-23, see rom/exrom_help.asm's own header) — no more
    # HELP_TOPIC_TABLE to drift out of sync with the docs, so "not
    # found" is the expected, N/A case now, not a staleness signal.
    names = extract_help_topic_names()
    if names is None:
        return
    prog_ref_text = read(PROG_REF)
    readme_text = read(README)
    for name in names:
        if name.upper() not in prog_ref_text.upper():
            issues.append(
                f"check_help_topics_documented: HELP topic '{name}' exists in "
                f"basic.asm but isn't mentioned in programmers_reference.md."
            )
        if name.upper() not in readme_text.upper():
            issues.append(
                f"check_help_topics_documented: HELP topic '{name}' exists in "
                f"basic.asm but isn't mentioned in README.md."
            )


def check_sysvar_declared_sizes():
    """Catch a DEFS count disagreeing with its same-line byte comment."""
    for lineno, line in enumerate(read(SYSVARS).splitlines(), 1):
        match = re.search(
            r"^(\w+):\s+DEFS\s+(\d+).*?;\s*(\d+)\s+bytes?\b", line, re.I
        )
        if not match:
            continue
        name, reserved, documented = match.groups()
        if int(reserved) != int(documented):
            issues.append(
                f"check_sysvar_declared_sizes: sysvars.inc:{lineno} {name} "
                f"reserves {reserved} bytes but its comment says {documented}."
            )


def check_integrated_fixture_count():
    actual = len(list((ROOT / "tests").glob("*.txt")))
    text = read(README)
    mentions = {
        int(value)
        for value in re.findall(
            r"(\d+)[ -](?:passing fixtures|fixture integrated language suite)",
            text,
        )
    }
    if not mentions:
        issues.append(
            "check_integrated_fixture_count: README.md has no current fixture "
            "count to validate."
        )
        return
    for documented in mentions:
        if documented != actual:
            issues.append(
                "check_integrated_fixture_count: README.md says "
                f"{documented} fixtures, but tests/*.txt contains {actual}."
            )


def main():
    check_font_glyph_count()
    check_punctuation_count()
    check_help_topics_documented()
    check_sysvar_declared_sizes()
    check_integrated_fixture_count()

    if issues:
        print(f"check_docs.py: {len(issues)} issue(s) found:\n")
        for issue in issues:
            print(f"  - {issue}")
        return 1

    print("check_docs.py: all checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
