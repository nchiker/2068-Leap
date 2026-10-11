#!/usr/bin/env python3
"""Apply the RST-vector shrink rule of study/qualification-shrink (ff7f0be) to the HOME sources of a tree.

  python3 tools/qual/apply_rst_rule.py <tree>     (after taking rom/v2_rst_vectors.inc, rom/v2_rst30.inc and the
                                                   rom/v2_home.asm / test-harness hunks of ff7f0be)
Rule (identical to ff7f0be): every UNCONDITIONAL
    call LEX_NEXT_TOKEN      -> rst $08
    call VM_POP              -> rst $10
    call VM_POP_COERCE_INT   -> rst $18
    call EMIT_BYTE           -> rst $20
    jp/jr COMPILE_RAISE_ERROR -> rst $30   (tail jump: the $30 vector drops the RST return address)
in rom/exrom_v2_compiler.asm, rom/exrom_v2_vm_core.asm, rom/exrom_v2_symtab.asm. Conditional forms are left alone (an RST
cannot be conditional). Comments are kept. Prints the number of sites converted per target; a second run converts nothing.
"""
import os
import re
import sys

TARGETS = {"LEX_NEXT_TOKEN": "$08", "VM_POP": "$10", "VM_POP_COERCE_INT": "$18", "EMIT_BYTE": "$20"}
FILES = ("rom/exrom_v2_compiler.asm", "rom/exrom_v2_vm_core.asm", "rom/exrom_v2_symtab.asm")
CALL = re.compile(r"^(\s+)call (LEX_NEXT_TOKEN|VM_POP|VM_POP_COERCE_INT|EMIT_BYTE)(?=\s|$)(\s*)(;.*)?$")
RAISE = re.compile(r"^(\s+)j[pr] COMPILE_RAISE_ERROR(?=\s|$)(\s*)(;.*)?$")


def convert(path):
    counts = {}
    out = []
    for line in open(path).read().split("\n"):
        m = CALL.match(line)
        if m:
            old = "call " + m.group(2)
            ins = "rst " + TARGETS[m.group(2)]
            line = (m.group(1) + ins + " " * (len(old) - len(ins) + len(m.group(3) or "")) + (m.group(4) or "")).rstrip()
            counts[m.group(2)] = counts.get(m.group(2), 0) + 1
        else:
            m = RAISE.match(line)
            if m:
                line = (m.group(1) + "rst $30" + " " * (len("jp COMPILE_RAISE_ERROR") - 7 + len(m.group(2) or ""))
                        + (m.group(3) or "")).rstrip()
                counts["COMPILE_RAISE_ERROR"] = counts.get("COMPILE_RAISE_ERROR", 0) + 1
        out.append(line)
    open(path, "w").write("\n".join(out))
    return counts


def main():
    tree = sys.argv[1] if len(sys.argv) > 1 else "."
    for f in FILES:
        print(f, convert(os.path.join(tree, f)))


if __name__ == "__main__":
    main()
