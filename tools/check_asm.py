#!/usr/bin/env python3
"""
check_asm.py — consolidated static checks for this project's .asm files.

Run this after any non-trivial edit to a large .asm file, and always
before considering a change finished. None of this replaces actually
assembling and running the code — sjasmplus and real testing are still
ground truth — but every check here catches a class of bug this
project has actually shipped at least once, entirely from reading the
source, with no assembler needed. Cheap, fast, and worth running
habitually rather than only when something's already gone wrong.

Usage:
    python3 tools/check_asm.py [file1.asm file2.asm ...]

With no arguments, checks basic/basic.asm (the largest, most actively
edited file, and the one every bug on this list has actually
occurred in). Exits non-zero if anything is flagged, so it can be used
as a pass/fail gate, not just an informational printout.

Checks performed, and which real bug each one guards against:

1. Duplicate global labels — sjasmplus won't always error on this the
   way you'd hope, and a duplicate silently means one definition wins
   and every reference to the other resolves to the wrong routine.

2. Local-label scope resolution — a stray BARE (non-dotted) label
   anywhere silently ends sjasmplus's local-label scoping for
   everything after it in the file, even when it's unrelated data
   with no relation to the routine it's embedded in. This caused this
   project's single most expensive debugging arc: an entire round of
   navigation-feature testing chased a bug that didn't exist, because
   the feature had never actually assembled into the binary being
   tested at all. This check walks every jr/jp/call reference to a
   dotted local label and confirms it resolves within the label's own
   correct enclosing global routine.

3. Stack-ordering fingerprint — flags any routine whose first several
   instructions include a bare `pop` before that same routine has
   pushed anything of its own. This is the exact shape of a real,
   very hard to find bug: a routine reached via `call` (which itself
   pushes a return address first) that assumed some OTHER caller's
   stashed value would be sitting on top of the stack. It wasn't —
   the routine's own return address was, and the `pop` corrupted it
   permanently, with the eventual `ret` jumping into garbage. This
   bug survived extensive hand-tracing and a full byte-for-byte
   listing-file audit; it was only found by single-stepping the real
   build in an emulator debugger. A flag from this check doesn't
   necessarily mean a bug — an intentionally audited stack protocol may
   use `; check-asm: allow-early-pop` in that routine to suppress the
   warning — but it's exactly the shape worth a manual second look.
"""

import re
import sys


def parse_routines(lines):
    """Split source lines into (name, start_index, end_index) for every
    global (non-dotted) label, where start/end are line indices into
    `lines` (end is exclusive, the next global label or EOF)."""
    routines = []
    cur_name = None
    cur_start = None
    for i, line in enumerate(lines):
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*):', line)
        if m:
            if cur_name is not None:
                routines.append((cur_name, cur_start, i))
            cur_name = m.group(1)
            cur_start = i
    if cur_name is not None:
        routines.append((cur_name, cur_start, len(lines)))
    return routines


def check_duplicate_labels(lines):
    seen = {}
    errors = []
    for i, line in enumerate(lines):
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*):', line)
        if m:
            name = m.group(1)
            if name in seen:
                errors.append(
                    f"line {i+1}: duplicate global label '{name}' "
                    f"(first defined at line {seen[name]+1})"
                )
            else:
                seen[name] = i
    return errors


def check_local_label_scope(lines):
    global_label_re = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*):')
    local_label_re = re.compile(r'^(\.[A-Za-z_][A-Za-z0-9_]*):')
    jump_re = re.compile(
        r'\b(jp|jr|call)\s+(?:[a-z]+,\s*)?(\.[A-Za-z_][A-Za-z0-9_]*)',
        re.IGNORECASE,
    )

    scope_locals = {}
    current_global = None
    current_scope_locals = set()
    for raw in lines:
        code = raw.split(';', 1)[0].rstrip('\n')
        stripped = code.strip()
        m = global_label_re.match(stripped)
        if m:
            if current_global is not None:
                scope_locals[current_global] = current_scope_locals
            current_global = m.group(1)
            current_scope_locals = set()
        else:
            m2 = local_label_re.match(stripped)
            if m2:
                current_scope_locals.add(m2.group(1))
    if current_global is not None:
        scope_locals[current_global] = current_scope_locals

    errors = []
    current_global = None
    current_scope_locals = set()
    for i, raw in enumerate(lines):
        code = raw.split(';', 1)[0].rstrip('\n')
        stripped = code.strip()
        m = global_label_re.match(stripped)
        if m:
            current_global = m.group(1)
            current_scope_locals = scope_locals.get(current_global, set())
            continue
        for jm in jump_re.finditer(code):
            target = jm.group(2)
            if target not in current_scope_locals:
                errors.append(
                    f"line {i+1} (scope={current_global}): reference to "
                    f"{target} not found in this scope -- {stripped}"
                )
    return errors


def check_stack_ordering_fingerprint(lines):
    routines = parse_routines(lines)
    warnings = []
    for name, start, end in routines:
        body_lines = lines[start:end]
        if any("check-asm: allow-early-pop" in line for line in body_lines):
            continue
        for j, line in enumerate(body_lines[1:15]):
            stripped = line.split(';', 1)[0].strip()
            if not stripped:
                continue
            if re.match(r'^push\s+', stripped, re.IGNORECASE):
                break
            if re.match(r'^call\s+', stripped, re.IGNORECASE):
                continue
            if re.match(r'^pop\s+', stripped, re.IGNORECASE):
                warnings.append(
                    f"line {start+2+j}: {name} does '{stripped}' near "
                    f"entry, before pushing anything of its own -- "
                    f"double check what's actually on top of the stack "
                    f"here (its own return address, pushed by whoever "
                    f"called it, or a caller's stashed value?)"
                )
                break
    return warnings


def main():
    paths = sys.argv[1:] if len(sys.argv) > 1 else ["basic/basic.asm"]
    any_issues = False

    for path in paths:
        print(f"== {path} ==")
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()

        dup_errors = check_duplicate_labels(lines)
        scope_errors = check_local_label_scope(lines)
        stack_warnings = check_stack_ordering_fingerprint(lines)

        if dup_errors:
            any_issues = True
            print(f"  [FAIL] {len(dup_errors)} duplicate label(s):")
            for e in dup_errors:
                print(f"    {e}")
        else:
            print("  [ok] no duplicate global labels")

        if scope_errors:
            any_issues = True
            print(f"  [FAIL] {len(scope_errors)} local-label scope error(s):")
            for e in scope_errors:
                print(f"    {e}")
        else:
            print("  [ok] all local-label references resolve in scope")

        if stack_warnings:
            # Not auto-failing: this one needs a human judgment call,
            # since a routine legitimately popping its own earlier
            # push is completely fine. Still printed prominently.
            print(f"  [REVIEW] {len(stack_warnings)} stack-ordering "
                  f"fingerprint(s) — not necessarily bugs, but worth a look:")
            for w in stack_warnings:
                print(f"    {w}")
        else:
            print("  [ok] no early-pop-before-own-push fingerprints")

        print()

    sys.exit(1 if any_issues else 0)


if __name__ == "__main__":
    main()
