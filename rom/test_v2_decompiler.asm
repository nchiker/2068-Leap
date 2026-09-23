; ============================================================================
; rom/test_v2_decompiler.asm — Architecture B, R8 Phase 1 smoke test
;
; Standalone ROM image exercising rom/exrom_v2_decompiler.asm's own
; DECOMPILE_PROGRAM entry point against a real program compiled by
; rom/exrom_v2_compiler.asm -- covering every opcode this decompiler's own
; R1-R3 scope claims (PUSH_I8/PUSH_I16, LOAD_VAR/STORE_VAR, ADD/SUB/MUL/
; DIV/CMP_LT/CMP_EQ, JMP/JMPZ via GOTO and IF...THEN GOTO, FOR_INIT/
; FOR_NEXT), a real forward-referenced label, and a real backward-
; referenced FOR loop -- not a full V2 round trip yet (that needs R8's
; own remaining editor-integration work), just "does this decompiler
; produce a valid, re-lexable reconstruction of a real compiled program."
; NOT wired into the production BASIC dispatch or the shipping EXROM
; build.
;
; Source program compiled (bytecode only -- this test never VM_RUNs it;
; the decompiler works directly on VM_CODE_BASE's own compiled bytes):
;
;   A=3+4
;   B=A*2
;   IF B<10 THEN GOTO SKIP
;   A=999
;   SKIP:
;   C=0
;   FOR I=1 TO 3
;   C=C+I
;   NEXT I
;
; Symbol declaration order (CSYM_FIND_OR_CREATE, first appearance):
;   0=A 1=B 2=C 3=I
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_decompiler.sym \
;       rom/test_v2_decompiler.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_decompiler_zesarux.bin
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
    db "A=3+4:B=A*2:IF B<10 THEN GOTO SKIP:A=999:SKIP:"
    db "C=0:FOR I=1 TO 3:C=C+I:NEXT I", 0

; EXPECTED_TEXT — filled in from a real DECOMP_OUT_BUF readback (this
; decompiler's own label/branch-target text is a real bytecode address,
; not something to hand-predict without assembling first -- same
; "measure, then document" discipline R7.5's own registry readback used).
; Confirmed via a real ts2068-debug run (see this file's own commit):
; A/B/C/I -> V0/V1/V2/V3 (first-appearance declaration order); L25/L30
; are the IF...THEN GOTO's own two synthesized branch-target labels --
; L25 (the JMPZ's own "false" fallthrough, landing exactly on the very
; next statement) is a real, harmless, documented characteristic: pass
; 1 records every JMP/JMPZ target it walks over, including this one,
; before pass 2's own IF-pattern collapse decides it needs no separate
; statement of its own -- valid, re-lexable text either way, per this
; file's own "valid but not byte-identical" bar.
EXPECTED_TEXT:
    db "V0 = (3+4)", 13
    db "V1 = (V0*2)", 13
    db "IF (V1<10) THEN GOTO L30", 13
    db "L25:", 13
    db "V0 = 999", 13
    db "L30:", 13
    db "V2 = 0", 13
    db "FOR V3 = 1 TO 3", 13
    db "V2 = (V2+V3)", 13
    db "NEXT V3", 13
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
; SOUND/PAUSE, and never registers or calls a loadable extension -- same
; stubbing discipline (and same real contracts: EXT2_LOOKUP's carry SET
; means "no match", exactly what a permanently-empty registry means)
; already established for rom/test_v2_editor_integration.asm/rom/
; test_v2_save_load.asm/rom/test_v2_decompiler_phase2.asm. The real
; kernel/sound+kernel/io+kernel/interrupt+kernel/extensions/
; ext_registry.asm modules pushed this flat 16K image over budget for
; zero real coverage.
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
EXT2_LOOKUP:
    scf
    ret
EXT2_SLOT_ADDR:
    ret
EXT_CALL_ARG0: equ $8B00   ; unreachable -- see rom/test_v2_editor_
EXT2_TABLE:    equ $8B00   ; integration.asm's own identical stub note
; kernel/memory/memory.asm is NOT included here -- checked directly:
; neither rom/exrom_v2_vm_core.asm/compiler.asm/decompiler.asm reference
; any MEM_*/PROG_END/PROG_AREA_START/ARRAYS_END/VARS_START symbol (V2's
; own storage model never used V1's line/label MEM_* apparatus), and
; this test never touches the real editor engine (kernel/editor/
; editor.asm, memory.asm's own real dependent elsewhere).
    INCLUDE "rom/exrom_format.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"
    INCLUDE "rom/exrom_v2_decompiler.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_decompiler.bin", $0000, $4000
