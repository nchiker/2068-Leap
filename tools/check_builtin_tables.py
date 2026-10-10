#!/usr/bin/env python3
"""Static consistency check of the three built-in function tables.

The compiler's BUILTIN_FN_TABLE, the VM's BUILTIN_FN_JUMP_TABLE and the
decompiler's DECOMP_BUILTIN_FN_TABLE are separate hand-kept tables that must
agree on fn_index, name, argument count and argument-type bits. This fails
(non-zero exit) if they drift, which is how FREE/COS/TAN/MID/FREE(n) went
missing from the decompiler unnoticed.
"""
import re, sys

def block(text, start, end):
    i = text.index(start)
    return text[i:text.index(end, i)]

comp = open("rom/exrom_v2_compiler.asm").read()
vm = open("rom/exrom_v2_vm_core.asm").read()
dec = open("rom/exrom_v2_decompiler.asm").read()

rows = re.findall(r'^\s*db\s+(\d+),\s*"([^"]+)",\s*(\d+),\s*(\d+),\s*(\$?[0-9A-Fa-f]+)\s*(?:;.*)?$',
                  block(comp, "BUILTIN_FN_TABLE:\n", "BUILTIN_FN_FIND:") if False else
                  comp[comp.index("\nBUILTIN_FN_TABLE:\n"):], re.M)
# stop at the first row that is not part of the table (rows are all within the table block)
table = {}
for ln, name, argc, idx, at in rows:
    if int(ln) != len(name): continue
    at = int(at[1:], 16) if at.startswith("$") else int(at)
    table[int(idx)] = (name, int(argc), at)
count = int(re.search(r'^BUILTIN_FN_TABLE_COUNT:\s*equ\s+(\d+)', comp, re.M).group(1))

jump = re.findall(r'dw\s+(\w+)\s*;\s*fn_index\s+(\d+)',
                  block(vm, "BUILTIN_FN_JUMP_TABLE:", "\n\n"))

names = dict(re.findall(r'^(STR_\w+):\s+db\s+"([^"]*)"', dec, re.M))
drows = re.findall(r'dw\s+(\w+)[^\n]*\n\s*db\s+\w+,\s*(\d+),\s*(\d+)',
                   block(dec, "DECOMP_BUILTIN_FN_TABLE:", "STR_GOTO:"))

errs = []
if count != len(table): errs.append(f"BUILTIN_FN_TABLE_COUNT={count} but {len(table)} rows parsed")
if sorted(table) != list(range(len(table))): errs.append(f"compiler fn_indexes not contiguous 0..{len(table)-1}: {sorted(table)}")
if len(jump) != len(table): errs.append(f"VM jump table has {len(jump)} entries, compiler {len(table)}")
for k, (_, i) in enumerate(jump):
    if int(i) != k: errs.append(f"VM jump table entry {k} is labelled fn_index {i}")
if len(drows) != len(table): errs.append(f"decompiler table has {len(drows)} rows, compiler {len(table)}")
for i, (name, argc, at) in sorted(table.items()):
    if i >= len(drows): continue
    sym, dargc, dat = drows[i]
    want = name + ("$" if at & 0x80 else "")
    got = names.get(sym)
    if got != want: errs.append(f"fn_index {i}: compiler '{want}', decompiler '{got}'")
    if int(dargc) != argc: errs.append(f"fn_index {i} {want}: argcount compiler {argc}, decompiler {dargc}")
    if (int(dat) & 3) != (at & 3): errs.append(f"fn_index {i} {want}: argtype bits compiler {at & 3}, decompiler {int(dat) & 3}")
for e in errs: print("check_builtin_tables:", e, file=sys.stderr)
if errs: sys.exit(1)
print(f"check_builtin_tables: ok ({len(table)} built-in functions agree across compiler, VM and decompiler)")
