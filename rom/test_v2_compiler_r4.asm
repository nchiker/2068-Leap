; ============================================================================
; rom/test_v2_compiler_r4.asm — Architecture B, R4 smoke test
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's R4 additions
; (PROC/ENDP declarations, CALL, by-value parameter binding) together with
; R1's real rom/exrom_v2_vm_core.asm's CALL/RET opcodes — real procedures,
; compiled and executed for real, per
; docs/v2/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's R4 success gate. NOT
; wired into the production BASIC dispatch or the shipping EXROM build.
;
; Source program compiled and executed:
;
;   PROC DOUBLE(N):RESULT=N+N:ENDP
;   CALL DOUBLE(21)
;   ANSWER=RESULT
;   CALL TRIPLE(5)
;   ANSWERB=RESULTB
;   PROC TRIPLE(N):RESULTB=N+N+N:ENDP
;   FINAL=1
;
; Exercises: a BACKWARD-referenced CALL (DOUBLE is declared before the
; CALL that targets it — resolved immediately, no fixup needed, same as
; R3's backward GOTO); a FORWARD-referenced CALL (TRIPLE is declared AFTER
; the CALL that targets it — genuinely tests RESOLVE_ALL_FIXUPS for a
; procedure, the one path GOTO's own R3 test didn't cover, since a
; procedure entry point's own JMP-skip-over-body also has to be resolved
; before that fixup pass, unlike a plain label); by-value parameter
; binding (both procedures use a parameter named "N" — deliberately the
; SAME name, since this milestone's scope has no separate local-variable
; frame, per the procedure-compiler section's own header note in
; exrom_v2_compiler.asm — sharing one global slot is expected, documented
; behavior here, not a bug, and is exercised on purpose rather than
; avoided); and that normal sequential execution correctly skips over
; BOTH procedure bodies via their own leading JMP, landing on "FINAL=1"
; without ever falling into TRIPLE's body a second time.
;
; Hand-computed expected results (symbol declaration order: 0=N, 1=RESULT,
; 2=ANSWER, 3=RESULTB, 4=ANSWERB, 5=FINAL):
;   RESULT  = 21+21 = 42        (DOUBLE(21), backward-referenced CALL)
;   ANSWER  = RESULT = 42
;   RESULTB = 5+5+5 = 15        (TRIPLE(5), forward-referenced CALL)
;   ANSWERB = RESULTB = 15
;   FINAL   = 1                  (proves execution didn't get stuck inside
;             either procedure body or its own skip-over machinery)
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_compiler_r4.sym \
;       rom/test_v2_compiler_r4.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_compiler_r4_zesarux.bin
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
; CHECK_RESULT — VM_ERROR_CODE must be 0. Symbol declaration order in the
; source (each is [tag][value_lo][value_hi] at SYMTAB_BASE + index*3):
;   0=N 1=RESULT(42) 2=ANSWER(42) 3=RESULTB(15) 4=ANSWERB(15) 5=FINAL(1)
; Out: carry clear = pass, carry set = fail
; ============================================================================
CHECK_RESULT:
    ld   a, (VM_ERROR_CODE)
    or   a
    jr   nz, .fail
    ld   hl, SYMTAB_BASE + 1*SYM_REC_LEN
    ld   de, 42
    call .check_one           ; RESULT
    jr   c, .fail
    ld   hl, SYMTAB_BASE + 2*SYM_REC_LEN
    ld   de, 42
    call .check_one           ; ANSWER
    jr   c, .fail
    ld   hl, SYMTAB_BASE + 3*SYM_REC_LEN
    ld   de, 15
    call .check_one           ; RESULTB
    jr   c, .fail
    ld   hl, SYMTAB_BASE + 4*SYM_REC_LEN
    ld   de, 15
    call .check_one           ; ANSWERB
    jr   c, .fail
    ld   hl, SYMTAB_BASE + 5*SYM_REC_LEN
    ld   de, 1
    call .check_one           ; FINAL
    ret
.fail:
    scf
    ret
; .check_one — input: HL=record address, DE=expected value.
; Out: carry clear=pass, carry set=fail.
.check_one:
    ld   a, (hl)
    cp   TAG_INT
    jr   nz, .co_fail
    inc  hl
    push de
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ex   de, hl               ; HL = actual value
    pop  de                    ; DE = expected value (restored)
    or   a
    sbc  hl, de
    ret  z
.co_fail:
    scf
    ret

SOURCE_TEXT:
    db "PROC DOUBLE(N):RESULT=N+N:ENDP:"
    db "CALL DOUBLE(21):ANSWER=RESULT:"
    db "CALL TRIPLE(5):ANSWERB=RESULTB:"
    db "PROC TRIPLE(N):RESULTB=N+N+N:ENDP:"
    db "FINAL=1", 0

; KTAB_CALC_EXIT_TRAMPOLINE -- required once rom/exrom_v2_vm_core.asm
; started calling into rom/exrom_calc.asm (R6's own float support);
; see rom/test_v2_compiler_r6.asm's own header for the full
; explanation. Added retroactively here (R8): this file predates R6/R7/
; R7.5, which each added more unconditional dependencies (calc, then
; graphics/sound/io/interrupt, then the R7.5 extension registry) that
; broke every earlier standalone test harness's own build without
; anyone updating them -- a real, confirmed regression-suite gap found
; while re-running the full V2 suite after an R8 lexer change.
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
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_compiler_r4.bin", $0000, $4000
