#!/usr/bin/env python3
"""
tools/fuse_load_inject.py — Track A of the SAVE/LOAD reliability plan
(see /home/charlie.day/.claude/plans/replicated-crunching-deer.md):
generates a Fuse debugger script that makes `LOAD` deterministic while
developing/testing under Fuse, by short-circuiting the real pulse-timing
receive code entirely — no tape, no timing, zero ROM changes.

WHY: kernel/storage/storage.asm's real LOAD path decodes tape pulses via
a busy-loop edge-timing routine that has proven non-deterministic under
Fuse (same tape file, different results across runs) and is the subject
of separate, real-hardware-focused hardening work (Track B of the plan
above). This script sidesteps that work entirely for day-to-day Fuse
testing: it sets a Fuse debugger breakpoint at EXROM_ENTRY_LOAD ($C018,
rom/exrom_checker.asm — a fixed trampoline address, stable across any
future EXROM edit), and when execution reaches it, pokes the requested
program's bytes directly into memory and fakes STORAGE_LOAD's own
successful-return contract (DE=length, carry clear, STORAGE_OP_STATE/
STORAGE_PROGRESS_PCT/STORAGE_BLOCKS_LOST sysvars set) before jumping
back to the caller — the real STORAGE_LOAD body in EXROM never runs.

The generated script ALSO breakpoints EXROM_ENTRY_SAVE ($C012, same
file) and fakes an immediate successful SAVE return (carry clear,
STORAGE_OP_STATE=2 "SAVED") — the real STORAGE_SAVE pulse transmission
never runs either, so a `SAVE "x"` in the same Fuse session completes
instantly instead of taking real wall-clock seconds for a full pulse
train. This does NOT capture what was saved anywhere: Fuse's debugger
scripting has no host-file-write primitive (`print`'s "standard
output" target is the GUI debugger pane's own text widget, not the
process's real stdout — confirmed empirically, nothing appears in the
process's own stdout/log even though the command executes without
error) — so there's no way to turn a live SAVE's actual bytes into a
reusable artifact through this mechanism alone. That's fine here: this
tool's own LOAD injection already gets its payload straight from the
Python-encoded source listing, never from a real SAVE's output, so nothing
downstream needs SAVE's bytes captured — the SAVE breakpoint exists
purely to make `SAVE` itself fast/deterministic too, for a dev-loop
session that does both.

This only activates when the generated .dbg script is actually passed to
Fuse via --debugger-command; it changes no ROM code, and has zero effect
on real hardware. Confirmed against the installed Fuse 1.9.1's actual
debugger grammar (man fuse, MONITOR/DEBUGGER section): `z80:<register>`
reads/writes any register or pair via `set`, `[address]` dereferences a
memory byte, `set address value` pokes a byte (address must be a bare
numeric literal, NOT an expression — confirmed empirically, see
EXROM_ENTRY_LOAD's own comment below), and `commands <id> ... end`
attaches an auto-run script to a breakpoint (the only way to enter a
multi-line debugger command, per the manual — hence generating a script
file rather than typing this interactively). Multiple breakpoints in one
script get sequential ids (1, 2, ... in definition order) — confirmed
empirically, not just assumed.

Reuses tools/preload_gen.py's own encode_program() for the payload
bytes, so an injected LOAD leaves PROG_AREA in the exact byte-for-byte
format a real LOAD (or a real typed-and-committed program) would.

A real, unrelated bug this surfaced: EXROM_VERIFY_KTAB_MAGIC (rom/
exrom_checker.asm) halts forever on every single EXROM entry point,
including EXROM_ENTRY_LOAD/_SAVE, unless the calling Home-side build
stamps KTAB_MAGIC at KTAB_BASE (include/exrom_jumptable.inc's own
KTAB_LIST macro) — the older scratch rom/test_storage_load_*.asm
harnesses from earlier this session never did this and had gone stale
relative to that check. The generated _check.asm harness below does it
correctly (mirrors tools/preload_gen.py's own HARNESS_TEMPLATE).

Usage:
    python3 tools/fuse_load_inject.py <program.txt> <out_prefix>

<program.txt>: same plain-text format preload_gen.py takes (one BASIC
statement per line, blank lines and ';;'-prefixed lines skipped).

Output:
    <out_prefix>.dbg — pass to Fuse via --debugger-command "$(cat
        <out_prefix>.dbg)" (the option takes the multi-line command
        text itself, not a filename — see man fuse's --debugger-command
        entry).
    <out_prefix>_check.asm — a standalone test harness (same COLD_START/
        INCLUDE shape as rom/test_storage_load_auto.asm) that calls
        BASIC_LOAD_EXROM directly (IX=PROG_AREA_START, wildcard filename,
        generous max length) and checks the injected result against the
        SAME encoded bytes the .dbg script pokes — border green/pass,
        red/fail, matching this project's established convention. Needs
        the Fuse invocation to pass the matching .dbg script for the
        injection to actually happen; without it, this harness calls
        the real (currently unreliable) tape-timing LOAD path with no
        tape actually connected, which does not fail quickly — the
        floating/noisy EAR bit reading with nothing attached can keep
        STORAGE_WAIT_PILOT finding spurious near-pilot edges
        indefinitely rather than cleanly timing out. That's a real
        Track B observation, not a bug in this harness — it isn't a
        test of the real LOAD path either way, only of the injected
        one.
    <out_prefix>_roundtrip.asm — the actual SAVE/LOAD regression test:
        calls the real command-level BASIC_DO_SAVE/BASIC_DO_LOAD (not
        the raw EXROM_ENTRY_* wrappers _check.asm uses), with a real
        `"TEST"` filename, so it also exercises filename parsing/
        padding — the exact bug class already found and fixed this
        session (see BASIC_DO_LOAD's own "REAL BUG FOUND AND FIXED"
        comment, basic/basic.asm). PROG_AREA is wiped between the SAVE
        and LOAD calls so a pass proves LOAD actually restored the
        program, not that it was just still sitting there.

Assumes EXROM_ENTRY_LOAD's breakpoint gets id 1 — true as long as this
is the only breakpoint Fuse has when the script runs (a fresh process
with no other --debugger-command breakpoints set first).
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from preload_gen import encode_program, to_db_lines  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
SYSVARS_INC = REPO_ROOT / "include" / "sysvars.inc"

EXROM_ENTRY_LOAD = 0xC018  # rom/exrom_checker.asm — fixed trampoline,
                           # stable across EXROM edits (see this
                           # script's own header)
EXROM_ENTRY_SAVE = 0xC012  # same file, same stability guarantee —
                           # STORAGE_SAVE's own fixed trampoline

# Fuse 1.9.1's debugger `set address value` command only accepts a bare
# numeric literal for `address` — NOT a general expression (confirmed
# empirically: `set (z80:ix+0) val` and even `set (0xbc01+1) val`, a
# purely-literal arithmetic expression with no register reference at
# all, both fail with "Invalid debugger command: syntax error" the
# moment the breakpoint actually fires and the command runs, while
# `print (z80:ix+1)` and `set z80:pc (expr)` — an expression in a
# VALUE slot, or as a plain `print` argument — both work fine. So the
# payload's destination addresses are computed here in Python as plain
# literals (PROG_AREA_START + i) rather than relative to z80:ix at
# runtime. This only matches real callers because every one of them
# (BASIC_DO_LOAD's own .load_call/.load_wildcard, basic/basic.asm)
# always sets IX = PROG_AREA_START before calling BASIC_LOAD_EXROM —
# there is no other real call site with a different destination.


_SYSVARS_SYM_CACHE = None


def _sysvars_symbols():
    """Assembles a throwaway file that just INCLUDEs sysvars.inc and
    dumps sjasmplus's own --sym table — the addresses below PROG_
    AREA_START are DEFS-computed by the assembler now (see sysvars.
    inc's own header), not hand-written hex, so there's no address
    left in the source text for a regex to scrape any more. Reading
    the real assembled symbol table instead of re-deriving offsets
    here keeps the same "read live, don't hardcode" intent the old
    regex-based version had, and stays correct across ANY future
    sysvars.inc layout change, not just this one. Cached per process
    — every call site wants the same handful of symbols."""
    global _SYSVARS_SYM_CACHE
    if _SYSVARS_SYM_CACHE is not None:
        return _SYSVARS_SYM_CACHE
    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)
        stub = tmp / "sysvars_stub.asm"
        sym = tmp / "sysvars_stub.sym"
        stub.write_text('    ORG $0000\n    INCLUDE "include/sysvars.inc"\n')
        subprocess.run(
            ["sjasmplus", str(stub), f"--sym={sym}"],
            cwd=REPO_ROOT, check=True, capture_output=True, text=True,
        )
        symbols = {}
        pat = re.compile(r'^(\S+):\s+EQU\s+0x([0-9A-Fa-f]+)', re.MULTILINE)
        for m in pat.finditer(sym.read_text()):
            symbols[m.group(1)] = int(m.group(2), 16)
    _SYSVARS_SYM_CACHE = symbols
    return symbols


def read_equ(name):
    """Looks up a sysvars.inc address from the real assembled symbol
    table (see _sysvars_symbols) — read live rather than hardcoded, so
    a future sysvar renumbering can't leave this script silently
    poking the wrong address."""
    symbols = _sysvars_symbols()
    if name not in symbols:
        raise ValueError(f"{name} not found in assembled {SYSVARS_INC} symbols")
    return symbols[name]


DBG_TEMPLATE = """breakpoint 0x{bp_addr:04x}
commands 1
{pokes}
set z80:de {length}
set z80:a 0
set z80:f (z80:f & 0xfe)
set 0x{op_state:04x} 4
set 0x{progress_pct:04x} 100
set 0x{blocks_lost:04x} 0
set z80:pc (([z80:sp]) + 256*([z80:sp+1]))
set z80:sp (z80:sp+2)
continue
end
breakpoint 0x{save_bp_addr:04x}
commands 2
set z80:f (z80:f & 0xfe)
set 0x{op_state:04x} 2
set 0x{progress_pct:04x} 100
set z80:pc (([z80:sp]) + 256*([z80:sp+1]))
set z80:sp (z80:sp+2)
continue
end
"""

CHECK_HARNESS_TEMPLATE = '''; ============================================================================
; {outname} — Track A injection-verification harness, generated by
; tools/fuse_load_inject.py. NOT hand-written — regenerate from the
; source .txt listing rather than hand-editing EXPECTED_DATA below.
;
; Calls the real product path (BASIC_LOAD_EXROM -> EXROM_ENTRY_LOAD,
; rom/exrom_checker.asm's own $C018 fixed trampoline) with a wildcard
; LOAD "" — no tape file involved. Only meaningful when Fuse is given
; the matching {dbgname} via --debugger-command: that script's
; breakpoint at $C018 intercepts before STORAGE_LOAD's real body runs
; and pokes this exact payload in instead. Run without the .dbg script
; attached, this exercises the real (currently unreliable) pulse-timing
; LOAD path and is expected to fail — that's not what this harness
; tests.
;
; Build:
;   sjasmplus {outname}
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 {binname} --rom-ts2068-1 exrom.bin \\
;        --debugger-command "$(cat {dbgname})"
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"
    DEFINE EXROM_JUMPTABLE_HOME_SIDE     ; must precede the INCLUDE
                                         ; below — see tools/preload_
                                         ; gen.py's own HARNESS_TEMPLATE,
                                         ; which this mirrors
    INCLUDE "include/exrom_jumptable.inc"

    DEVICE NOSLOT64K
    ORG $0000

RST_00:
    di
    jp   COLD_START

    DS   $0028 - $, $FF
RST_28:
    jp   CALC_ENTRY_TRAMPOLINE    ; must be a bare `jp`, not `call` —
                                  ; see basic/basic.asm's own header on
                                  ; why. Unused by this harness directly
                                  ; but EXROM_ENTRY_LOAD's real callee
                                  ; chain assumes RST $28 works even
                                  ; when not exercised by THIS payload.

    DS   $0038 - $, $FF
RST_38:
    call KBD_ISR_TICK
    ei
    reti

    ; EXROM call table — KTAB_MAGIC_ADDR ($0040-based) MUST be stamped
    ; by a real Home-side build, or EXROM_VERIFY_KTAB_MAGIC (rom/
    ; exrom_checker.asm) halts forever on every EXROM entry, including
    ; EXROM_ENTRY_LOAD — this bit this script's own harness the first
    ; time it was tried (2026-08-23): the earlier, pre-KTAB-check test_
    ; storage_load_*.asm scratch harnesses never defined this either,
    ; and had gone stale relative to exrom_checker.asm's later magic-
    ; check addition.
    ORG  KTAB_BASE
    KTAB_LIST
    ASSERT $ <= KTAB_END
    DB   KTAB_MAGIC

    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00
    call MEM_INIT

    ld   ix, PROG_AREA_START     ; matches BASIC_DO_LOAD's own real
                                 ; destination for LOAD ""
    ld   hl, 0                  ; filename ptr — unused, B=0 = wildcard
    ld   b, 0
    ld   de, PROG_AREA_MAX - PROG_AREA_START  ; same bound BASIC_DO_LOAD
                                              ; itself passes
    call BASIC_LOAD_EXROM        ; EXROM_ENTRY_LOAD ($C018) is the
                                 ; injection script's breakpoint target
    jp   c, .fail                ; carry set = failure (injection
                                 ; script never fired, or was wrong)

    ld   hl, EXPECTED_LEN
    or   a
    sbc  hl, de
    jr   nz, .fail                ; DE must equal the injected length

    ld   a, (STORAGE_BLOCKS_LOST)
    or   a
    jr   nz, .fail

    ld   hl, PROG_AREA_START
    ld   de, EXPECTED_DATA
    ld   b, EXPECTED_LEN
.cmp_loop:
    ld   a, (de)
    cp   (hl)
    jr   nz, .fail
    inc  hl
    inc  de
    djnz .cmp_loop

    ; also confirm the status bar renders LOADED, same as a real
    ; successful LOAD — visual/screenshot confirmation, not just an
    ; in-memory check. GFX_CLS first: this harness never runs a real
    ; BASIC_DO_LOAD (which always clears/attributes the screen itself),
    ; so screen memory here is still whatever cold-boot left it —
    ; without this the status text can render invisible (uninitialized
    ; ink==paper attribute bytes).
    call GFX_CLS
    call BASIC_FORMAT_STORAGE_STATUS_EXROM
    ld   hl, STATUS_BUF
    ld   b, 0
    ld   c, 0
    call GFX_PRINT_STRING

    ld   a, 4                    ; green — pass
    jr   .done
.fail:
    ld   a, 2                    ; red — fail
.done:
    out  (PORT_ULA), a
    jr   $

EXPECTED_DATA:
{db_lines}
EXPECTED_LEN EQU $ - EXPECTED_DATA

    INCLUDE "basic/basic.asm"
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/math/math.asm"
    INCLUDE "kernel/sound/sound.asm"
    INCLUDE "kernel/interrupt/interrupt.asm"
    INCLUDE "kernel/bank/bank.asm"

    DS   $4000 - $, $FF

    SAVEBIN "{binname}", $0000, $4000
'''

ROUNDTRIP_HARNESS_TEMPLATE = '''; ============================================================================
; {outname} — SAVE/LOAD regression test, generated by tools/fuse_
; load_inject.py. NOT hand-written — regenerate from the source .txt
; listing rather than hand-editing TEST_PROGRAM below.
;
; Unlike {checkname} (which calls BASIC_LOAD_EXROM directly, bypassing
; command parsing entirely), this calls the REAL command-level entry
; points — BASIC_DO_SAVE and BASIC_DO_LOAD (basic/basic.asm) — with
; hand-built `"TEST"` command text, exercising the actual filename
; parsing/padding path a typed `SAVE "TEST"` / `LOAD "TEST"` goes
; through (this is exactly the class of bug this project already found
; and fixed once this session: BASIC_DO_LOAD not space-padding a typed
; filename to the header's fixed 10-char width). Real regression
; coverage, not just a check that injection itself works.
;
; Only meaningful when Fuse is given the matching {dbgname} via
; --debugger-command: SAVE completes instantly (EXROM_ENTRY_SAVE,
; $C012, fakes success — the real pulse transmission never runs) and
; LOAD is served this exact TEST_PROGRAM payload (EXROM_ENTRY_LOAD,
; $C018) rather than anything SAVE actually produced — Fuse's debugger
; scripting has no way to capture SAVE's real output to feed back into
; LOAD (see this script's own module header for why), so the two sides
; are independently faked from the SAME source bytes instead. Between
; SAVE and LOAD, PROG_AREA is deliberately wiped and PROG_END zeroed —
; proof LOAD actually restores the program rather than it just still
; being there from before.
;
; Run without the .dbg script attached, SAVE takes real pulse-
; transmission time and LOAD then needs a real tape with a real
; "TEST"-named recording on it to pass at all — not what this test is
; for.
;
; Build:
;   sjasmplus {outname}
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 {binname} --rom-ts2068-1 exrom.bin \\
;        --debugger-command "$(cat {dbgname})"
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"
    DEFINE EXROM_JUMPTABLE_HOME_SIDE
    INCLUDE "include/exrom_jumptable.inc"

    DEVICE NOSLOT64K
    ORG $0000

RST_00:
    di
    jp   COLD_START

    DS   $0028 - $, $FF
RST_28:
    jp   CALC_ENTRY_TRAMPOLINE

    DS   $0038 - $, $FF
RST_38:
    call KBD_ISR_TICK
    ei
    reti

    ORG  KTAB_BASE
    KTAB_LIST
    ASSERT $ <= KTAB_END
    DB   KTAB_MAGIC

    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00
    call MEM_INIT

    ; load a known program into PROG_AREA, as if it had been typed in.
    ; LDIR leaves DE = PROG_AREA_START + TEST_PROGRAM_LEN (both
    ; pointers advance together) — reused directly for PROG_END below
    ; rather than recomputing the same address a second time.
    ld   hl, TEST_PROGRAM
    ld   de, PROG_AREA_START
    ld   bc, TEST_PROGRAM_LEN
    ldir
    ld   (PROG_END), de

    ; SAVE "TEST" — real command-level entry, real filename parsing.
    ; No carry/status check here: TEST_CMD_TEXT below is a fixed,
    ; always-well-formed buffer this code controls directly (unlike a
    ; real user's typed command), and the injection breakpoint fakes
    ; success unconditionally — nothing here could actually fail. The
    ; two LOAD checks below are what actually exercises real product
    ; logic (filename parsing/padding, PROG_END, content).
    ld   hl, TEST_CMD_TEXT
    call BASIC_DO_SAVE

    ; LOAD "TEST" — real command-level entry, real filename parsing
    ; (matching-name, non-wildcard path — the actual bug class already
    ; found and fixed in BASIC_DO_LOAD this session). Same buffer as
    ; SAVE above — neither routine writes back through HL, both only
    ; ever read the command text, so one shared "TEST" buffer covers
    ; both calls (saves a few bytes in a tight 16K test-binary budget).
    call .wipe_prog                ; LOAD must actually restore this,
                                   ; not just find it already there
    ld   hl, TEST_CMD_TEXT
    call BASIC_DO_LOAD
    call .verify_loaded
    jr   c, .fail

    ; repeat via LOAD "" — the OTHER real dispatch path (.load_wildcard
    ; in BASIC_DO_LOAD, B=0, no filename padding/match at all) — same
    ; injected payload either way, since the injection breakpoint
    ; doesn't look at the filename, so this is purely a second,
    ; independent exercise of BASIC_DO_LOAD's own wildcard branch, not
    ; a second content check.
    call .wipe_prog
    ld   hl, WILDCARD_CMD_TEXT
    call BASIC_DO_LOAD
    call .verify_loaded
    jr   c, .fail

    ld   a, 4                     ; green — pass
    jr   .done
.fail:
    ld   a, 2                     ; red — fail
.done:
    out  (PORT_ULA), a
    jr   $

; wipes PROG_AREA so a passing LOAD below proves content was actually
; restored, not just still sitting there. Does NOT touch PROG_END —
; unlike a real NEW/cold-boot reset, this doesn't need to: BASIC_DO_
; LOAD's own real code unconditionally overwrites PROG_END from the
; actual received length on success (`ld hl,PROG_AREA_START / add
; hl,de / ld (PROG_END),hl`, basic/basic.asm), never reads the old
; value first, so leaving it stale here costs nothing and saves a
; couple of instructions in a tight 16K test-binary budget.
; Destroys AF, BC, HL.
.wipe_prog:
    ld   hl, PROG_AREA_START
    ld   bc, PROG_AREA_MAX - PROG_AREA_START
    call MEM_FILL_ZERO
    ret

; shared by both the "TEST" and "" LOAD checks above — carry set means
; failure. Destroys AF, BC, DE, HL.
.verify_loaded:
    ld   a, (STORAGE_OP_STATE)
    cp   4                        ; 4 = LOADED, no errors
    scf
    ret  nz

    ld   hl, (PROG_END)
    ld   de, PROG_AREA_START + TEST_PROGRAM_LEN
    or   a
    sbc  hl, de
    scf
    ret  nz

    ld   hl, PROG_AREA_START
    ld   de, TEST_PROGRAM
    ld   b, TEST_PROGRAM_LEN
.cmp_loop:
    ld   a, (de)
    cp   (hl)
    scf
    ret  nz
    inc  hl
    inc  de
    djnz .cmp_loop
    or   a
    ret

TEST_CMD_TEXT: DB '"TEST"', 0
WILDCARD_CMD_TEXT: DB '""', 0

TEST_PROGRAM:
{db_lines}
TEST_PROGRAM_LEN EQU $ - TEST_PROGRAM

    INCLUDE "basic/basic.asm"
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/math/math.asm"
    INCLUDE "kernel/sound/sound.asm"
    INCLUDE "kernel/interrupt/interrupt.asm"
    INCLUDE "kernel/bank/bank.asm"

    DS   $4000 - $, $FF

    SAVEBIN "{binname}", $0000, $4000
'''


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    src_path, out_prefix = sys.argv[1], sys.argv[2]

    with open(src_path) as f:
        lines = [l.rstrip('\n') for l in f]
    lines = [l for l in lines if l.strip() and not l.strip().startswith(';;')]

    data = encode_program(lines)
    if len(data) > 255:
        # EXPECTED_LEN's own compare loop below uses B as an 8-bit
        # DJNZ counter — matches this project's other short, token-
        # based test programs; a payload needing more than one byte's
        # worth of length is a bigger harness change, not attempted here
        raise ValueError(
            f"payload too large for this harness's 8-bit compare loop "
            f"({len(data)} bytes, max 255): shorten the program")

    prog_area_start = read_equ('PROG_AREA_START')
    pokes = '\n'.join(
        f'set 0x{prog_area_start + i:04x} 0x{b:02x}'
        for i, b in enumerate(data))

    dbg_text = DBG_TEMPLATE.format(
        bp_addr=EXROM_ENTRY_LOAD,
        save_bp_addr=EXROM_ENTRY_SAVE,
        pokes=pokes,
        length=len(data),
        op_state=read_equ('STORAGE_OP_STATE'),
        progress_pct=read_equ('STORAGE_PROGRESS_PCT'),
        blocks_lost=read_equ('STORAGE_BLOCKS_LOST'),
    )

    dbg_path = f"{out_prefix}.dbg"
    with open(dbg_path, 'w') as f:
        f.write(dbg_text)

    asm_path = f"{out_prefix}_check.asm"
    outname = asm_path.split('/')[-1]
    dbgname = dbg_path.split('/')[-1]
    binname = outname.rsplit('.', 1)[0] + '.bin'
    db_lines = '\n'.join(to_db_lines(data))

    with open(asm_path, 'w') as f:
        f.write(CHECK_HARNESS_TEMPLATE.format(
            outname=outname, dbgname=dbgname, binname=binname,
            db_lines=db_lines))

    rt_path = f"{out_prefix}_roundtrip.asm"
    rt_outname = rt_path.split('/')[-1]
    rt_binname = rt_outname.rsplit('.', 1)[0] + '.bin'
    with open(rt_path, 'w') as f:
        f.write(ROUNDTRIP_HARNESS_TEMPLATE.format(
            outname=rt_outname, checkname=outname, dbgname=dbgname,
            binname=rt_binname, db_lines=db_lines))

    print(f"Encoded {len(lines)} statement(s), {len(data)} bytes")
    print(f"Wrote {dbg_path} (--debugger-command \"$(cat {dbg_path})\")")
    print(f"Wrote {asm_path} (sjasmplus {asm_path} -> {binname})")
    print(f"Wrote {rt_path} (sjasmplus {rt_path} -> {rt_binname}) "
          f"— SAVE/LOAD regression test")


if __name__ == '__main__':
    main()
