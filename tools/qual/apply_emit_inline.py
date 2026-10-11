#!/usr/bin/env python3
"""Shrink prototype: inline the compiler's one-opcode emit stubs.

  python3 tools/qual/apply_emit_inline.py <tree> [--dry-run]

A stub is a line `NAME: ld a,N : jr EMIT_BYTE` (or `jp EMIT_BYTE`) in rom/exrom_v2_compiler.asm. Rule:
  * a stub whose ONLY references (in every rom/*.asm and include/*.inc file of the tree, test files
    included) are unconditional `call NAME` sites gets each call replaced by `ld a,N` + `rst $20`
    (RST $20 = call EMIT_BYTE, the RST shrink) -- same 3 bytes per site -- and the stub (4 B) deleted;
  * a stub with no reference at all is deleted;
  * with --full, two more reference kinds are rewritten: an unconditional tail `jp/jr NAME` becomes
    `ld a,N` + `jp EMIT_BYTE` (+2 B each), and `ld hl,NAME` feeding COMPILE_1ARG_STMT/COMPILE_2ARG_STMT
    becomes `ld a,N` (-1 B each); the two helpers then carry the opcode in A (push af / pop) and end with
    `jp EMIT_BYTE` instead of `jp (hl)`;
  * every other stub (conditional jumps, tables) is left alone.
The emitted bytecode is unchanged by construction: the inline pair loads the same A and calls the same
routine. Prints what it did.
"""
import glob
import os
import re
import sys

tree = sys.argv[1]
dry = "--dry-run" in sys.argv
full = "--full" in sys.argv
comp = os.path.join(tree, "rom/exrom_v2_compiler.asm")
STUB = re.compile(r"^(EMIT_(?:BYTE_)?OP_[A-Z0-9_]+):\s+ld a,(\$?[0-9A-Fa-f]+|[0-9]+)\s*:\s*j[pr] EMIT_BYTE\s*(;.*)?$")
files = sorted(glob.glob(os.path.join(tree, "rom/*.asm")) + glob.glob(os.path.join(tree, "include/*.inc")))
text = {f: open(f).read() for f in files}
stubs = {}
for line in text[comp].split("\n"):
    m = STUB.match(line)
    if m:
        stubs[m.group(1)] = m.group(2)
removed, kept, sites = [], [], 0
HELPER = re.compile(r"^\s+j[pr] COMPILE_[12]ARG_STMT\b")
for name, n in stubs.items():
    ref = re.compile(r"\b%s\b" % re.escape(name))
    call = re.compile(r"^(\s+)call %s(\s*)(;.*)?$" % re.escape(name))
    tail = re.compile(r"^(\s+)j[pr] %s(\s*)(;.*)?$" % re.escape(name))
    ldhl = re.compile(r"^(\s+)ld hl,%s(\s*)(;.*)?$" % re.escape(name))
    total, ok = 0, 0
    for f, t in text.items():
        lines = t.split("\n")
        for i, line in enumerate(lines):
            if ref.search(line.split(";")[0]) and not line.startswith(name + ":"):
                total += 1
                if call.match(line):
                    ok += 1
                elif full and tail.match(line):
                    ok += 1
                elif full and ldhl.match(line) and i + 1 < len(lines) and HELPER.match(lines[i + 1]):
                    ok += 1
    if total != ok:
        kept.append((name, total - ok))
        continue
    for f, t in list(text.items()):
        out = []
        lines = t.split("\n")
        for i, line in enumerate(lines):
            m = call.match(line)
            mt = tail.match(line) if full else None
            mh = ldhl.match(line) if full else None
            if m:
                out.append("%sld a,%s        ; QUAL shrink: inlined %s" % (m.group(1), n, name))
                out.append("%srst $20" % m.group(1))
                sites += 1
            elif mt:
                out.append("%sld a,%s        ; QUAL shrink: inlined %s (tail)" % (mt.group(1), n, name))
                out.append("%sjp EMIT_BYTE" % mt.group(1))
                sites += 1
            elif mh and i + 1 < len(lines) and HELPER.match(lines[i + 1]):
                out.append("%sld a,%s        ; QUAL shrink: the opcode of %s" % (mh.group(1), n, name))
                sites += 1
            elif f == comp and STUB.match(line) and line.startswith(name + ":"):
                continue
            else:
                out.append(line)
        text[f] = "\n".join(out)
    removed.append((name, ok))
if full:
    t = text[comp]
    old1 = """COMPILE_1ARG_STMT:
        push hl                  ; save the emit target -- LEX_NEXT_TOKEN/
                                   ; COMPILE_EXPR both freely destroy HL
        rst $08
        call COMPILE_EXPR
        pop hl
        jp (hl)"""
    new1 = """COMPILE_1ARG_STMT:
        push af                  ; QUAL shrink: A = the opcode (was HL = its emit stub)
        rst $08
        call COMPILE_EXPR
        pop af
        jp EMIT_BYTE"""
    old2 = """COMPILE_2ARG_STMT:
        push hl
        rst $08                 ; consume the keyword
        call COMPILE_EXPR       ; first argument
        call COMPILE_EXPECT_COMMA_EXPR  ; second argument
        pop hl
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        jp (hl)"""
    new2 = """COMPILE_2ARG_STMT:
        push af                 ; QUAL shrink: A = the opcode (was HL = its emit stub)
        rst $08                 ; consume the keyword
        call COMPILE_EXPR       ; first argument
        call COMPILE_EXPECT_COMMA_EXPR  ; second argument
        pop bc                  ; B = the opcode
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        ld a,b
        jp EMIT_BYTE"""
    assert t.count(old1) == 1 and t.count(old2) == 1, (t.count(old1), t.count(old2))
    text[comp] = t.replace(old1, new1).replace(old2, new2)
print("stubs: %d, removed: %d (%d call sites inlined), kept: %d" % (len(stubs), len(removed), sites, len(kept)))
print("kept (non-call references):", ", ".join("%s(%d)" % k for k in kept))
if not dry:
    for f, t in text.items():
        if t != open(f).read():
            open(f, "w").write(t)
