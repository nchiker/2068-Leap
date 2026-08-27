; ============================================================================
; rom/test_sqr_sin_visual.asm — SCRATCH, throwaway visual smoke test for
; BASIC_SQR_FLOAT/BASIC_SIN_FLOAT (2026-08-22). NOT part of the normal
; test suite (not referenced from README/docs) — calls the two new
; routines directly with known arguments and prints each result's
; fractional string straight to the screen via BASIC_FLOAT_TO_STRING,
; one per row, so the actual computed digits can be read by eye/
; screenshot instead of trusting a hand-derived expected-byte table
; (this project's own established smoke-test style compares exact
; expected bytes, but that requires replicating this algorithm's exact
; 32-bit-mantissa rounding path in Python first — a real risk of
; comparing against the WRONG "expected" value, the exact mistake
; already caught once in rom/test_calc_smoke_division.asm's own
; history). A quick visual read sidesteps that risk for this first
; pass; border turns green once every row has printed (never red —
; this harness doesn't itself judge correctness).
;
; Build:
;   sjasmplus rom/test_sqr_sin_visual.asm
;   sjasmplus rom/exrom_build.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_sqr_sin_visual.bin --rom-ts2068-1 exrom.bin
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

CUR_ROW EQU CUR_VAR_LETTER      ; RAM scratch this test never otherwise
                                ; touches (ROM can't be written — see
                                ; this project's own "testing gotcha"
                                ; on mutable scratch, docs/programmers_
                                ; reference.md)

COLD_START:
    ld   sp, $FF00
    call GFX_CLS

    xor  a
    ld   (CUR_ROW), a

    ; ---- SQR(2) ----
    ld   hl, 2
    call BASIC_SQR_FLOAT
    ld   hl, FUNC_RESULT_FLOAT
    call CALC_PUSH_FP_RAW_HOME
    call BASIC_FLOAT_TO_STRING
    call SHOW_ROW

    ; ---- SQR(9) ----
    ld   hl, 9
    call BASIC_SQR_FLOAT
    ld   hl, FUNC_RESULT_FLOAT
    call CALC_PUSH_FP_RAW_HOME
    call BASIC_FLOAT_TO_STRING
    call SHOW_ROW

    ; ---- SIN(0) ----
    ld   hl, 0
    call BASIC_SIN_FLOAT
    call SHOW_SIN_ROW

    ; ---- SIN(30) ----
    ld   hl, 30
    call BASIC_SIN_FLOAT
    call SHOW_SIN_ROW

    ; ---- SIN(45) ----
    ld   hl, 45
    call BASIC_SIN_FLOAT
    call SHOW_SIN_ROW

    ; ---- SIN(90) ----
    ld   hl, 90
    call BASIC_SIN_FLOAT
    call SHOW_SIN_ROW

    ; ---- SIN(180) ----
    ld   hl, 180
    call BASIC_SIN_FLOAT
    call SHOW_SIN_ROW

    ; ---- SIN(-30) ----
    ld   hl, -30
    call BASIC_SIN_FLOAT
    call SHOW_SIN_ROW

    ; ---- SIN(-90) ----
    ld   hl, -90
    call BASIC_SIN_FLOAT
    call SHOW_SIN_ROW

    ; ---- SIN(270) ----
    ld   hl, 270
    call BASIC_SIN_FLOAT
    call SHOW_SIN_ROW

    ; ---- SQR(0) ----
    ld   hl, 0
    call BASIC_SQR_FLOAT
    ld   hl, FUNC_RESULT_FLOAT
    call CALC_PUSH_FP_RAW_HOME
    call BASIC_FLOAT_TO_STRING
    call SHOW_ROW

    ; ---- SQR(-5) ----
    ld   hl, -5
    call BASIC_SQR_FLOAT
    ld   hl, FUNC_RESULT_FLOAT
    call CALC_PUSH_FP_RAW_HOME
    call BASIC_FLOAT_TO_STRING
    call SHOW_ROW

    ; ---- real BASIC_STMT_PRINT calls, not direct routine calls —
    ; exercises the actual FUNC_RESULT_IS_FLOAT hook added to
    ; BASIC_STMT_PRINT itself, the one piece none of the calls above
    ; touch at all ----
    call BASIC_RESET_TEXT_ATTR       ; sane INK/PAPER before
                                     ; BASIC_COMPUTE_PRINT_ATTR reads
                                     ; them — this harness never runs
                                     ; the normal boot init that would
                                     ; otherwise set these
    ld   a, (CUR_ROW)
    ld   (BASIC_OUTPUT_ROW), a
    xor  a
    ld   (BASIC_OUTPUT_COL), a
    ld   hl, STMT_SQR2
    call BASIC_STMT_PRINT
    ld   a, (CUR_ROW)
    inc  a
    ld   (CUR_ROW), a

    ld   a, (CUR_ROW)
    ld   (BASIC_OUTPUT_ROW), a
    xor  a
    ld   (BASIC_OUTPUT_COL), a
    ld   hl, STMT_SIN30
    call BASIC_STMT_PRINT
    ld   a, (CUR_ROW)
    inc  a
    ld   (CUR_ROW), a

    ld   a, (CUR_ROW)
    ld   (BASIC_OUTPUT_ROW), a
    xor  a
    ld   (BASIC_OUTPUT_COL), a
    ld   hl, STMT_SIN45_PLUS1
    call BASIC_STMT_PRINT           ; "integer core" check: SIN(45)+1
                                    ; composes with "+1", so this must
                                    ; print a plain truncated int (1),
                                    ; NOT a fractional value — the
                                    ; do_add clear-site's own job
    ld   a, (CUR_ROW)
    inc  a
    ld   (CUR_ROW), a

    ld   a, 4                       ; green — all rows printed
    out  (PORT_ULA), a
.done_loop:
    jr   .done_loop

; SHOW_SIN_ROW: pushes FUNC_RESULT_FLOAT, converts it, and — if
; FUNC_RESULT_FLOAT_NEGATIVE is set — pokes a "-" into the unused byte
; immediately before the returned string (BASIC_NUM_TO_STRING always
; leaves at least one byte free there for a non-negative, few-digit
; int_part; fine for this throwaway harness's small values) and prints
; from there instead. Falls into SHOW_ROW either way.
SHOW_SIN_ROW:
    ld   hl, FUNC_RESULT_FLOAT
    call CALC_PUSH_FP_RAW_HOME
    call BASIC_FLOAT_TO_STRING       ; HL = string ptr
    ld   a, (FUNC_RESULT_FLOAT_NEGATIVE)
    or   a
    jr   z, SHOW_ROW
    dec  hl
    ld   (hl), "-"
    ; fall into SHOW_ROW

; SHOW_ROW: HL = null-terminated string. Prints it at (row=CUR_ROW,
; col=0), advances CUR_ROW. Kept in memory, not a register — every
; call in between (BASIC_SQR_FLOAT, BASIC_SIN_FLOAT, BASIC_FLOAT_TO_
; STRING) destroys BC among other things, so a register-held row
; counter doesn't survive from one test case to the next.
; Destroys: AF, BC, DE, HL.
SHOW_ROW:
    ld   a, (CUR_ROW)
    ld   b, a
    ld   c, 0
    ld   a, $38                      ; ink 0 / paper 7 — same default
                                    ; byte BASIC_COMPUTE_PRINT_ATTR
                                    ; produces for INK 0/PAPER 7
    ld   d, 0
    call GFX_PRINT_STRING_ATTR
    ld   a, (CUR_ROW)
    inc  a
    ld   (CUR_ROW), a
    ret

    INCLUDE "basic/basic.asm"
    INCLUDE "kernel/editor/editor.asm"
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/math/math.asm"
    INCLUDE "kernel/interrupt/interrupt.asm"
    INCLUDE "kernel/bank/bank.asm"

MINUS_STR: DB "-", 0
STMT_SQR2: DB "SQR(2)", $0D
STMT_SIN30: DB "SIN(30)", $0D
STMT_SIN45_PLUS1: DB "SIN(45)+1", $0D

    DS   $4000 - $, $FF

    SAVEBIN "test_sqr_sin_visual.bin", $0000, $4000
