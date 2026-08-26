#!/usr/bin/env python3
"""
extract_routine.py — pulls one routine's source lines out of a project
.asm file, stripped of comments, ready to feed to sim.py's Program
loader.

Usage:
    python3 extract_routine.py <source.asm> <GLOBAL_LABEL> [<END_LABEL>] > out.txt

If END_LABEL is omitted, extraction stops at the next line matching
'^[A-Za-z_][A-Za-z0-9_]*:' (i.e. the next global label) or EOF.

IMPORTANT: to preserve local-label scoping (dot-prefixed labels are
scoped to their nearest preceding GLOBAL label), always extract
starting from a real global label, not from partway through a routine
-- and if the routine you need calls into local labels that live
under a DIFFERENT global label (rare, but see BASIC_DRAW_STATUS_LINE's
own .print_status in this project), extract that whole span in one
shot rather than as two separate files, or the loader will register
the local labels under the wrong (or no) scope. See sim.py's own
Program.load_file docstring-equivalent comments for the mechanics.
"""
import sys
import re

def extract(path, start_label, end_label=None):
    lines = []
    capturing = False
    with open(path) as f:
        for raw in f:
            stripped = raw.rstrip('\n')
            if not capturing:
                if re.match(rf'^{re.escape(start_label)}:', stripped):
                    capturing = True
                else:
                    continue
            else:
                if end_label:
                    if re.match(rf'^{re.escape(end_label)}:', stripped):
                        break
                else:
                    if capturing and stripped != raw_first_line(start_label) and \
                       re.match(r'^[A-Za-z_][A-Za-z0-9_]*:', stripped) and \
                       not re.match(rf'^{re.escape(start_label)}:', stripped):
                        break
            text = stripped.split(';')[0].rstrip()
            if text.strip() == '' and stripped.strip().startswith(';'):
                continue
            if stripped.strip().startswith(';'):
                continue
            lines.append(stripped)
    return lines

def raw_first_line(label):
    return f'{label}:'

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    src = sys.argv[1]
    start = sys.argv[2]
    end = sys.argv[3] if len(sys.argv) > 3 else None
    for line in extract(src, start, end):
        print(line)
