#!/usr/bin/env python3
"""
extract_routine.py — pulls one routine's source lines out of a project
.asm file, stripped of comments, ready to feed to sim.py's Program
loader.

Usage:
    python3 extract_routine.py <source.asm> <GLOBAL_LABEL> [<END_LABEL>] > out.txt
    python3 extract_routine.py <source.asm> <GLOBAL_LABEL> [<END_LABEL>] \
        --with-locations > out.asm

--with-locations inserts assembler-comment metadata before copied lines.
Program.load_file consumes it to preserve original file/line locations for
z80sim traces and SjASMPlus listing correlation; assemblers ignore it.

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
import json

def extract(path, start_label, end_label=None, with_locations=False):
    lines = []
    capturing = False
    with open(path) as f:
        for source_line, raw in enumerate(f, 1):
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
            if with_locations and stripped.strip():
                location = json.dumps({
                    "path": str(path),
                    "line": source_line,
                    "text": text,
                }, separators=(',', ':'))
                lines.append(f"; z80sim-source: {location}")
            lines.append(stripped)
    return lines

def raw_first_line(label):
    return f'{label}:'

if __name__ == '__main__':
    args = sys.argv[1:]
    with_locations = '--with-locations' in args
    args = [arg for arg in args if arg != '--with-locations']
    if len(args) < 2:
        print(__doc__)
        sys.exit(1)
    src = args[0]
    start = args[1]
    end = args[2] if len(args) > 2 else None
    for line in extract(src, start, end, with_locations=with_locations):
        print(line)
