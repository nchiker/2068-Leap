; ============================================================================
; rom/test_v2_decompiler_phase2.asm — Architecture B, R8 Phase 2 smoke test
;
; Standalone ROM image exercising rom/exrom_v2_decompiler.asm's own R8
; Phase 2 additions: strings (R5), floats (R6), the native-call/platform
; family (R7/R7.5), and procedures (R4's PROC/CALL/RET) -- the real
; remainder Phase 1's own commit flagged as deliberately out of scope.
; Compiles a real program covering every new opcode this phase adds,
; decompiles it, and byte-compares the reconstructed text against a real
; captured-then-verified expected rendering (same discipline as rom/
; test_v2_decompiler.asm's own Phase 1 test). NOT wired into the
; production BASIC dispatch or the shipping EXROM build.
;
; Source program compiled:
;
;   PROC ADDONE(N)
;   N=N+1
;   ENDP
;   CLS
;   BORDER 2
;   INK 5
;   PAPER 1
;   PLOT 10,20
;   LINE 1,2 TO 3,4
;   BEEP 1,2
;   SOUND 3,4
;   POKE 100,7
;   PAUSE 5
;   RANDOMISE 1
;   A$="hi"
;   B$=A$+"!"
;   IF B$="hi!" THEN GOTO SKIP
;   A$="wrong"
;   SKIP:
;   X=3.14
;   CALL ADDONE(5)
;
; Symbol declaration order (numeric CSYMTAB, first appearance): 0=N,
; 1=X. String symbols (STRSYMTAB, separate namespace): 0=A$, 1=B$.
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_decompiler_phase2.sym \
;       rom/test_v2_decompiler_phase2.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_decompiler_phase2_zesarux.bin
;   ts2068-debug run --max-instructions 500000
;   ts2068-debug timex   (border field)
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"

    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START
    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00

    call COMPILER_INIT
    ld   hl, SOURCE_TEXT
    ld   (SRC_PTR), hl
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM

    ld   a, (COMPILE_ERROR_CODE)
    or   a
    jp   nz, FAIL

    ld   hl, (EMIT_PTR)
    ld   (DECOMP_END_ADDR), hl    ; R8.5: DECOMPILE_PROGRAM's own new
                                    ; required contract
    call DECOMPILE_PROGRAM

    ld   a, (DECOMP_ERROR_CODE)
    or   a
    jp   nz, FAIL

    call CHECK_RESULT
    jp   c, FAIL

PASS:
    ld   a, 4                ; green
    out  (PORT_ULA), a
    jr   $

FAIL:
    ld   a, 2                ; red
    out  (PORT_ULA), a
    jr   $

; ============================================================================
; CHECK_RESULT — the reconstructed text at DECOMP_OUT_BUF must match
; EXPECTED_TEXT byte-for-byte, and DECOMP_OUT_PTR must land exactly
; EXPECTED_TEXT_LEN bytes past DECOMP_OUT_BUF (no trailing garbage).
; Out: carry clear = pass, carry set = fail
; ============================================================================
CHECK_RESULT:
    ld   hl, (DECOMP_OUT_PTR)
    ld   de, DECOMP_OUT_BUF
    or   a
    sbc  hl, de              ; HL = actual output length
    ld   de, EXPECTED_TEXT_LEN
    or   a
    sbc  hl, de
    jr   nz, .fail
    ld   hl, DECOMP_OUT_BUF
    ld   de, EXPECTED_TEXT
    ld   bc, EXPECTED_TEXT_LEN
.cmp:
    ld   a, (de)
    cp   (hl)
    jr   nz, .fail
    inc  hl
    inc  de
    dec  bc
    ld   a, b
    or   c
    jr   nz, .cmp
    ret
.fail:
    scf
    ret

SOURCE_TEXT:
    db "PROC ADDONE(N):N=N+1:ENDP:"
    db "CLS:BORDER 2:INK 5:PAPER 1:PLOT 10,20:LINE 1,2 TO 3,4:"
    db "BEEP 1,2:SOUND 3,4:POKE 100,7:PAUSE 5:RANDOMISE 1:"
    db 'A$="hi":B$=A$+"!":IF B$="hi!" THEN GOTO SKIP:A$="wrong":SKIP:'
    db "X=3.14:CALL ADDONE(5)", 0

; EXPECTED_TEXT — filled in from a real DECOMP_OUT_BUF readback (same
; "measure, then document" discipline as rom/test_v2_decompiler.asm's
; own Phase 1 expected text; PROC/GOTO's own synthesized addresses are
; real bytecode addresses, not hand-predictable without assembling
; first). ADDONE -> P3, N -> V0 (numeric symtab), A$/B$ -> S0$/S1$
; (separate strsym namespace, first-appearance order), X -> V1. L13/L88
; are the same kind of harmless synthesized label already documented in
; rom/test_v2_decompiler.asm's own header (a JMPZ/JMP target pass 1
; records before pass 2's own pattern-collapse decides it needs no
; separate statement there -- valid, re-lexable text either way).
EXPECTED_TEXT:
    db "PROC P3(V0)", 13
    db "V0 = (V0+1)", 13
    db "ENDP", 13
    db "L13:", 13
    db "CLS", 13
    db "BORDER 2", 13
    db "INK 5", 13
    db "PAPER 1", 13
    db "PLOT 10,20", 13
    db "LINE 1,2 TO 3,4", 13
    db "BEEP 1,2", 13
    db "SOUND 3,4", 13
    db "POKE 100,7", 13
    db "PAUSE 5", 13
    db "RANDOMISE 1", 13
    db 'S0$ = "hi"', 13
    db 'S1$ = (S0$+"!")', 13
    db 'IF (S1$="hi!") THEN GOTO L97', 13
    db "L88:", 13
    db 'S0$ = "wrong"', 13
    db "L97:", 13
    db "V1 = 3.14", 13
    db "CALL P3(5)", 13
EXPECTED_TEXT_LEN: equ $-EXPECTED_TEXT

; Test-only stub: rom/exrom_v2_vm_core.asm's own OP_LPRINT_NUM/STR
; reference the real rom/exrom_printer.asm's BASIC_STMT_LPRINT_EXROM
; unconditionally, but pulling in that whole (real-ZX-printer-
; hardware-facing, ~300-line) file pushed this standalone flat 16K
; test image over budget with no LPRINT coverage to show for it (this
; file's own test program never calls LPRINT). A dedicated PRINT/
; LPRINT test (rom/test_v2_print.asm) includes the real file and
; genuinely exercises it; every other test stubs it, same discipline
; as this file's own existing KTAB_CALC_EXIT_TRAMPOLINE stub just below.
BASIC_STMT_LPRINT_EXROM:
    ret

KTAB_CALC_EXIT_TRAMPOLINE:
    ret

    INCLUDE "kernel/math/math.asm"
    INCLUDE "rom/exrom_calc.asm"
    INCLUDE "kernel/graphics/graphics.asm"
; Test-only stubs: this file's own test program never exercises BEEP/
; SOUND/PAUSE -- rom/exrom_v2_vm_core.asm's own OP_BEEP/OP_SOUND/OP_PAUSE
; still reference these unconditionally, and the real kernel/sound+
; kernel/io+kernel/interrupt modules pushed this flat 16K image over
; budget for zero real coverage, same stubbing discipline already used
; by rom/test_v2_save_load.asm and rom/test_v2_editor_integration.asm.
SOUND_BEEP:
    ret
SOUND_EXROM:
    or a
    ret
IO_READ_KEY:
    xor a
    ret
INT_GET_FRAMES:
    ld hl,0
    ret
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/extensions/ext_registry.asm"
    INCLUDE "rom/exrom_format.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"
    INCLUDE "rom/exrom_v2_decompiler.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_decompiler_phase2.bin", $0000, $4000
