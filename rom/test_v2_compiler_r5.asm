; ============================================================================
; rom/test_v2_compiler_r5.asm — Architecture B, R5 smoke test
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's R5 additions
; (string assignment, concatenation, ordering/equality comparison, NAME$
; identifiers) together with R1's real rom/exrom_v2_vm_core.asm's new
; string opcodes (PUSH_STR_LIT/STORE_STR_VAR/STR_CONCAT/STR_CMP_LT/
; STR_CMP_EQ) — real strings, compiled and executed for real, per
; docs/v2/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's R5 success gate. NOT
; wired into the production BASIC dispatch or the shipping EXROM build.
;
; Source program compiled and executed:
;
;   A$="APPLE"
;   B$="BANANA"
;   C$=A$+B$
;   D$=A$
;   IF A$<B$ THEN GOTO LESS
;   F=0
;   GOTO DONEA
;   LESS:
;   F=1
;   DONEA:
;   IF D$=A$ THEN GOTO EQ
;   G=0
;   GOTO DONEB
;   EQ:
;   G=1
;   DONEB:
;   H=1
;
; Exercises: string literal assignment, concatenation (C$=A$+B$), a true
; ordering comparison (A$<B$, since 'A'<'B' lexicographically), a true
; equality comparison (D$=A$, D$ was assigned as a copy of A$), and that
; execution reaches the final statement (H=1) correctly — a full round
; trip through every R5 mechanism together, not just each in isolation.
;
; Hand-computed expected results:
;   A$ = "APPLE"        (5 bytes)
;   B$ = "BANANA"        (6 bytes)
;   C$ = "APPLEBANANA"   (11 bytes, real concatenation)
;   D$ = "APPLE"          (5 bytes, a copy, not aliased -- STORE_STR_VAR
;         really copies content, not a reference, so later changes to A$
;         (none occur in this program, but the design intent is real)
;         would not be reflected in D$)
;   F  = 1  (A$<B$ is true)
;   G  = 1  (D$=A$ is true)
;   H  = 1  (execution reached the end)
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_compiler_r5.sym \
;       rom/test_v2_compiler_r5.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_compiler_r5_zesarux.bin
;   ts2068-debug run --max-instructions 500000
;   ts2068-debug timex   (border field)
; ============================================================================

    INCLUDE "include/hardware.inc"
    DEFINE V2_COMPACT_SYSVARS   ; R10.7 P5: drop V1-only sysvars (see include/sysvars.inc)
    INCLUDE "include/sysvars.inc"
    INCLUDE "rom/test_v2_symmacros.inc"

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

    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN

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
; CHECK_RESULT — VM_ERROR_CODE must be 0.
;   Numeric symbols (order): 0=F(1) 1=G(1) 2=H(1)
;   String symbols  (order): 0=A$("APPLE") 1=B$("BANANA") 2=C$("APPLEBANANA")
;                             3=D$("APPLE")
; Out: carry clear = pass, carry set = fail
; ============================================================================
CHECK_RESULT:
    ld   a, (VM_ERROR_CODE)
    or   a
    jr   nz, .fail
    TSYM_ADDR 0*SYM_REC_LEN
    ld   de, 1
    call .check_num           ; F
    jr   c, .fail
    TSYM_ADDR 1*SYM_REC_LEN
    ld   de, 1
    call .check_num           ; G
    jr   c, .fail
    TSYM_ADDR 2*SYM_REC_LEN
    ld   de, 1
    call .check_num           ; H
    jr   c, .fail
    TSTR_ADDR 0*STR_REC_LEN
    ld   de, STR_APPLE
    ld   b, 5
    call .check_str           ; A$
    jr   c, .fail
    TSTR_ADDR 1*STR_REC_LEN
    ld   de, STR_BANANA
    ld   b, 6
    call .check_str           ; B$
    jr   c, .fail
    TSTR_ADDR 2*STR_REC_LEN
    ld   de, STR_APPLEBANANA
    ld   b, 11
    call .check_str           ; C$
    jr   c, .fail
    TSTR_ADDR 3*STR_REC_LEN
    ld   de, STR_APPLE
    ld   b, 5
    call .check_str           ; D$
    ret
.fail:
    scf
    ret

; .check_num — input: HL=record address, DE=expected value.
.check_num:
    ld   a, (hl)
    cp   TAG_INT
    jr   nz, .cn_fail
    inc  hl
    push de
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ex   de, hl
    pop  de
    or   a
    sbc  hl, de
    ret  z
.cn_fail:
    scf
    ret

; .check_str — input: HL=STRTAB record address, DE=expected content
; pointer, B=expected length.
.check_str:
    ld   a, (hl)
    cp   b
    jr   nz, .cs_fail
    inc  hl
    or   a
    jr   z, .cs_ok             ; zero-length: nothing more to compare
.cs_loop:
    ld   a, (de)
    cp   (hl)
    jr   nz, .cs_fail
    inc  hl
    inc  de
    djnz .cs_loop
.cs_ok:
    ret
.cs_fail:
    scf
    ret

STR_APPLE:        db "APPLE"
STR_BANANA:       db "BANANA"
STR_APPLEBANANA:  db "APPLEBANANA"

SOURCE_TEXT:
    db 'A$="APPLE":B$="BANANA":C$=A$+B$:D$=A$:'
    db 'IF A$<B$ THEN GOTO LESS:F=0:GOTO DONEA:'
    db 'LESS:F=1:DONEA:'
    db 'IF D$=A$ THEN GOTO EQ:G=0:GOTO DONEB:'
    db 'EQ:G=1:DONEB:'
    db 'H=1', 0

; KTAB_CALC_EXIT_TRAMPOLINE -- required once rom/exrom_v2_vm_core.asm
; started calling into rom/exrom_calc.asm (R6's own float support);
; see rom/test_v2_compiler_r6.asm's own header for the full
; explanation. Added retroactively here (R8): this file predates R6/R7/
; R7.5, which each added more unconditional dependencies (calc, then
; graphics/sound/io/interrupt, then the R7.5 extension registry) that
; broke every earlier standalone test harness's own build without
; anyone updating them -- a real, confirmed regression-suite gap found
; while re-running the full V2 suite after an R8 lexer change.
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
    INCLUDE "kernel/sound/sound.asm"
    INCLUDE "rom/exrom_sound.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/interrupt/interrupt.asm"
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/extensions/ext_registry.asm"
    INCLUDE "rom/exrom_format.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_compiler_r5.bin", $0000, $4000
