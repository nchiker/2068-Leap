#!/usr/bin/env python3
"""
check_z80_opcodes.py — static checks for Z80 addressing-mode mistakes
that tools/z80sim/sim.py CANNOT catch (it's a loose interpreter, not a
real assembler — it executes whatever register/operand combination you
write, with no opcode-encoding validation at all) but real sjasmplus
enforces as hard errors or silent-wrong-code warnings.

Written 2026-08-21 after exactly this gap cost a full extra round-trip
on the calculator engine's arithmetic ops: z80sim reported "PASS" on
code containing `LD (DE),H`, `ADD A,(CALC_MUL_CAND)`, and other opcodes
that don't exist on real Z80 at all, and it took a real sjasmplus
submission to catch them. This project's own lesson 20 (see /areas
notes) names the underlying gap; this tool is the fix — run it BEFORE
calling anything "z80sim-verified, ready to ship", the same way
check_asm.py already gets run for label/stack issues.

Usage:
    python3 tools/check_z80_opcodes.py [file1.asm file2.asm ...]

With no arguments, checks rom/exrom_calc.asm (the file that prompted
this tool, and the one most likely to grow more real arithmetic next).
Exits non-zero if anything is flagged.

Checks performed, and which real bug each one guards against:

1. Invalid (DE)/(BC) indirect operand — real Z80 ONLY has `LD (DE),A`
   / `LD A,(DE)` / `LD (BC),A` / `LD A,(BC)` for indirect BC/DE
   addressing; no other register may appear on either side of a
   (DE)/(BC) operand at all. `(HL)` indirect is the one that accepts
   any register as source or destination — this is the single most
   common way to reach for the wrong indirect form. Caught for real:
   `LD (DE),H`/`L`/`D`/`E` in CALC_UNPACK's fast-path tail, silently
   writing garbage (worse: the routine's own return address) instead
   of a real error, because this sandbox's z80sim let it "run".

2. Invalid absolute-address ALU operand — none of ADD/ADC/SUB/SBC/
   AND/OR/XOR/CP have a form that takes a 16-bit absolute address as
   the memory operand. Only `(HL)`, `(IX+d)`, `(IY+d)`, a register, or
   an immediate are valid. `ADD A,(SOME_SYSVAR+n)` is not real Z80 —
   sjasmplus either rejects it outright or (worse) silently reinterprets
   the address as an 8-bit immediate, producing code that assembles
   clean and does something completely different at runtime. Caught
   for real: every accumulate/subtract step in CALC_ADDSUB_ENGINE and
   CALC_OP_MUL's multiply loop, all originally written this way.

3. JR/DJNZ range — both have an 8-bit signed displacement, +-127 bytes
   from the instruction after the jump. A loop body or branch that
   grows past that range assembles fine right up until it doesn't;
   this project has hit it twice for real (the stackops smoke test's
   `jr nz,FAIL` chain, and the arithmetic engine's own loops once a
   fix lengthened their bodies). Uses a real per-mnemonic Z80
   instruction-length table and proper local-label scoping (same
   scoping rules as check_asm.py) to estimate byte offsets and flag
   any jr/djnz whose displacement would be out of range. An estimate,
   not a real assembler pass — DB/DW/DS-heavy data regions or IX/IY-
   prefixed forms this table doesn't fully model could shift the real
   answer by a few bytes either way, so treat anything within ~10
   bytes of the limit as worth a second look, not just an exact "OK".
"""

import re
import sys


def strip_comment(line):
    """Removes a trailing ';' comment, respecting quoted string/char
    literals (this project's source uses both '"-"' and "'-'" style
    character constants, same convention as tools/z80sim/sim.py's own
    comma-splitting logic)."""
    in_q = None
    for i, ch in enumerate(line):
        if in_q:
            if ch == in_q:
                in_q = None
            continue
        if ch in ('"', "'"):
            in_q = ch
        elif ch == ';':
            return line[:i]
    return line


REG8 = {'a', 'b', 'c', 'd', 'e', 'h', 'l'}


def check_de_bc_indirect(lines):
    """(DE)/(BC) as an operand, paired with anything other than A on
    either side, in a LD instruction."""
    errors = []
    ld_re = re.compile(r'^ld\s+(.+?)\s*,\s*(.+)$', re.IGNORECASE)
    for i, raw in enumerate(lines):
        code = strip_comment(raw).strip()
        if not code.lower().startswith('ld '):
            continue
        m = ld_re.match(code)
        if not m:
            continue
        dst, src = m.group(1).strip().lower(), m.group(2).strip().lower()
        if dst in ('(de)', '(bc)') and src != 'a':
            errors.append(
                f"line {i+1}: `{code}` — (DE)/(BC) indirect only "
                f"supports A as the source (real Z80 has no opcode for "
                f"LD {dst.upper()},{src.upper()}) -- {code!r}"
            )
        if src in ('(de)', '(bc)') and dst != 'a':
            errors.append(
                f"line {i+1}: `{code}` — (DE)/(BC) indirect only "
                f"supports A as the destination (real Z80 has no "
                f"opcode for LD {dst.upper()},{src.upper()}) -- {code!r}"
            )
    return errors


ALU_MNEMONICS = ('add', 'adc', 'sub', 'sbc', 'and', 'or', 'xor', 'cp')


def check_alu_absolute_operand(lines):
    """ADD/ADC/SUB/SBC/AND/OR/XOR/CP with a memory operand that isn't
    (hl)/(ix+d)/(iy+d) -- i.e. any parenthesized operand that isn't one
    of those three forms is an absolute-address attempt, which doesn't
    exist for any 8-bit ALU op on real Z80."""
    errors = []
    valid_mem = re.compile(r'^\(\s*(hl|ix\s*[+-]\s*\d+|iy\s*[+-]\s*\d+)\s*\)$',
                            re.IGNORECASE)
    for i, raw in enumerate(lines):
        code = strip_comment(raw).strip()
        low = code.lower()
        mnem = low.split(None, 1)[0] if low else ''
        if mnem not in ALU_MNEMONICS:
            continue
        rest = code[len(mnem):].strip()
        # ADD/ADC/SBC also have a 16-bit form ("add hl,bc") -- not an
        # 8-bit ALU op, skip those explicitly rather than mis-flagging.
        if re.match(r'^hl\s*,', rest, re.IGNORECASE):
            continue
        # operand is either "a, X" (two explicit operands) or just "X"
        # (cp/and/or/xor/sub's implicit-A single-operand form)
        if ',' in rest:
            operand = rest.split(',', 1)[1].strip()
        else:
            operand = rest.strip()
        m = re.match(r'^\((.+)\)$', operand)
        if not m:
            continue
        if not valid_mem.match(operand):
            errors.append(
                f"line {i+1}: `{code}` — no 8-bit ALU op has an "
                f"absolute-address operand on real Z80 (only (HL), "
                f"(IX+d), (IY+d), a register, or an immediate are "
                f"valid) -- load {operand} into a register first"
            )
    return errors


# ---- rough per-mnemonic Z80 instruction byte-length table, for the
# JR/DJNZ range check below. Not a real assembler -- see this file's
# own module docstring for the caveats.
def instr_size(mnem, operand):
    mnem = mnem.lower()
    op = operand.strip().lower()
    if mnem in ('nop', 'halt', 'di', 'ei', 'ret', 'reti', 'retn', 'ex',
                'ldir', 'lddr', 'cpir', 'scf', 'ccf', 'cpl', 'daa',
                'rlca', 'rrca', 'rla', 'rra'):
        return 1
    if mnem in ('push', 'pop'):
        return 1
    if mnem in ('inc', 'dec'):
        return 3 if ('(ix' in op or '(iy' in op) else 1
    if mnem == 'ld':
        parts = [p.strip() for p in op.split(',', 1)]
        dst = parts[0] if parts else ''
        src = parts[1] if len(parts) > 1 else ''
        if '(ix' in dst or '(ix' in src or '(iy' in dst or '(iy' in src:
            return 3
        if re.match(r'^\(.+\)$', dst) and dst not in ('(hl)', '(bc)', '(de)'):
            return 3
        if re.match(r'^\(.+\)$', src) and src not in ('(hl)', '(bc)', '(de)'):
            return 3
        if dst in ('bc', 'de', 'hl', 'sp') and not src.startswith('('):
            return 3
        if dst in ('ix', 'iy'):
            return 4
        if dst in REG8 and re.match(r'^-?\$?[0-9a-fx]+$', src) and src not in REG8:
            return 2
        return 1
    if mnem in ALU_MNEMONICS:
        if op.startswith('hl'):
            return 1
        if '(ix' in op or '(iy' in op:
            return 3
        if re.match(r'^-?\$?[0-9a-fx]+$', op):
            return 2
        return 1
    if mnem in ('sla', 'sra', 'srl', 'rl', 'rr', 'bit', 'set', 'res'):
        return 2
    if mnem == 'djnz':
        return 2
    if mnem == 'jr':
        return 2
    if mnem == 'jp':
        return 1 if '(hl)' in op else 3
    if mnem == 'call':
        return 3
    return 3  # conservative default for anything unrecognized


def check_jr_range(lines):
    """Estimates byte offsets (scoped local labels, same rule as
    check_asm.py) and flags any jr/djnz whose real displacement would
    exceed the +-127-byte range."""
    offsets = []
    cum = 0
    scoped_labels = {}
    current_scope = None
    for raw in lines:
        line = strip_comment(raw).rstrip()
        stripped = line.strip()
        offsets.append(cum)
        if not stripped:
            continue
        m = re.match(r'^([A-Za-z_.][A-Za-z0-9_.]*):\s*(.*)$', stripped)
        rest = stripped
        if m:
            label = m.group(1)
            if label.startswith('.'):
                scoped_labels[(current_scope, label)] = cum
            else:
                current_scope = label
                scoped_labels[(current_scope, label)] = cum
            rest = m.group(2).strip()
            if not rest:
                continue
        parts = rest.split(None, 1)
        if not parts:
            continue
        mnem = parts[0].lower()
        if mnem in ('db', 'dw', 'ds', 'include', 'org', 'device',
                    'assert', 'defb', 'defw', 'defs'):
            continue
        operand = parts[1] if len(parts) > 1 else ''
        cum += instr_size(mnem, operand)

    warnings = []
    current_scope = None
    for i, raw in enumerate(lines):
        line = strip_comment(raw).strip()
        if not line:
            continue
        m = re.match(r'^([A-Za-z_.][A-Za-z0-9_.]*):\s*(.*)$', line)
        rest = line
        if m:
            label = m.group(1)
            if not label.startswith('.'):
                current_scope = label
            rest = m.group(2).strip()
        if not rest:
            continue
        parts = rest.split(None, 1)
        mnem = parts[0].lower()
        if mnem not in ('jr', 'djnz'):
            continue
        operand = parts[1] if len(parts) > 1 else ''
        target = operand.split(',', 1)[1].strip() if ',' in operand else operand.strip()
        key = (current_scope, target)
        tgt_off = scoped_labels.get(key) or scoped_labels.get((target, target))
        if tgt_off is None:
            continue  # not this tool's job -- check_asm.py catches unresolved labels
        this_addr = offsets[i]
        disp = tgt_off - (this_addr + 2)
        if not (-128 <= disp <= 127):
            warnings.append(
                f"line {i+1} (scope={current_scope}): `{line}` — "
                f"estimated displacement {disp:+d}, out of JR/DJNZ's "
                f"+-127-byte range"
            )
        elif not (-118 <= disp <= 117):
            warnings.append(
                f"line {i+1} (scope={current_scope}): `{line}` — "
                f"estimated displacement {disp:+d}, within 10 bytes of "
                f"the +-127 limit -- this is an ESTIMATE (see module "
                f"docstring), worth a second look if the routine grows "
                f"at all"
            )
    return warnings


def main():
    paths = sys.argv[1:] if len(sys.argv) > 1 else ["rom/exrom_calc.asm"]
    any_issues = False

    for path in paths:
        print(f"== {path} ==")
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()

        de_bc_errors = check_de_bc_indirect(lines)
        alu_errors = check_alu_absolute_operand(lines)
        jr_warnings = check_jr_range(lines)

        if de_bc_errors:
            any_issues = True
            print(f"  [FAIL] {len(de_bc_errors)} invalid (DE)/(BC) indirect operand(s):")
            for e in de_bc_errors:
                print(f"    {e}")
        else:
            print("  [ok] no invalid (DE)/(BC) indirect operands")

        if alu_errors:
            any_issues = True
            print(f"  [FAIL] {len(alu_errors)} invalid ALU absolute-address operand(s):")
            for e in alu_errors:
                print(f"    {e}")
        else:
            print("  [ok] no invalid ALU absolute-address operands")

        if jr_warnings:
            any_issues = True
            print(f"  [FAIL] {len(jr_warnings)} JR/DJNZ range issue(s):")
            for w in jr_warnings:
                print(f"    {w}")
        else:
            print("  [ok] all JR/DJNZ displacements estimated within range")

        print()

    sys.exit(1 if any_issues else 0)


if __name__ == "__main__":
    main()
