; ============================================================================
; rom/test_print_repro_debug.asm — diagnostic for the reported bug:
; a program consisting of ONLY `PRINT "hello"` doesn't run — RUN
; appears to just return to the program listing, with no visible
; output, no full-screen error, nothing. Reported to also work fine
; when the same PRINT is the middle statement of a FOR/NEXT loop.
;
; Fully automated (no keypresses needed) — preloads the single-
; statement program directly into RAM at boot (same technique tools/
; preload_gen.py uses for interactive preload tests, but this harness
; skips the interactive editor entirely and just calls the two
; relevant routines directly), then dumps diagnostic state as hex text
; on screen and halts. Two separate questions, answered independently:
;
;   Row 0: "CHK=x MSG=xxxx" — does the STATIC CHECK PASS alone
;     (BASIC_CHECK_STATEMENT_EXROM, called directly on just this one
;     statement, bypassing BASIC_RUN entirely) consider `PRINT "hello"`
;     invalid? x=0 means the check passed (carry clear); x=1 means it
;     failed (carry set). MSG=xxxx is the raw PENDING_ERROR_MSG pointer
;     value in that case — NOT printed as text, deliberately: the
;     checker runs EXROM-paged and sets this from ITS OWN copy of
;     include/checker_keywords.inc's message strings (a separate
;     compilation, different address range, than basic.asm's own copy
;     of the same source) — dereferencing it after EXROM pages back out
;     would read whatever's actually in Home RAM at that address now,
;     not the real message text, so the raw pointer is the only
;     trustworthy thing to show here.
;   Row 1: "ERR=xxxx ROW=xx COL=xx" — after that, a completely separate
;     real call to BASIC_RUN (same as pressing RUN+ENTER for real):
;     ERR = CHECK_ERROR_COUNT afterward (0 = check passed inside RUN
;     too), ROW/COL = BASIC_OUTPUT_ROW/BASIC_OUTPUT_COL afterward — if
;     PRINT actually executed, ROW should have advanced past 0 (PRINT
;     always calls BASIC_ADVANCE_OUTPUT_ROW on success).
;
; Border goes white (7) once both rows are drawn — stable, not looping
; through colors, so there's a clear "diagnostic finished, read the
; screen" signal distinct from every pass/fail smoke test elsewhere in
; this project.
;
; Build:
;   sjasmplus rom/test_print_repro_debug.asm
;   sjasmplus rom/exrom_build.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_print_repro_debug.bin --rom-ts2068-1 exrom.bin
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"
    DEFINE EXROM_JUMPTABLE_HOME_SIDE
    INCLUDE "include/exrom_jumptable.inc"

    DEVICE NOSLOT64K

; ---- RAM scratch for the debug display strings ----
CHK_STR    EQU $8100   ; "0" or "1", null-terminated (2 bytes)
MSG_STR    EQU $8110   ; 4 hex digits + null (5 bytes)
ERR_STR    EQU $8120
ROW_STR    EQU $8130
COL_STR    EQU $8140

    ORG $0000
RST_00:
    di
    jp   COLD_START

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
    call KBD_ISR_INIT

    ld   hl, PRELOAD_DATA
    ld   de, PROG_AREA_START
    ld   bc, PRELOAD_LEN
    ldir
    ld   hl, PROG_AREA_START + PRELOAD_LEN
    ld   (PROG_END), hl
    ld   hl, 1
    ld   (CUR_EDIT_INDEX), hl

    im   1
    ei

    ; ---- Step A: check pass alone, on just this one statement ----
    ld   hl, PROG_AREA_START
    call BASIC_CHECK_STATEMENT_EXROM
    jr   c, .a_failed
    ld   a, "0"
    jr   .a_store
.a_failed:
    ld   a, "1"
.a_store:
    ld   (CHK_STR), a
    xor  a
    ld   (CHK_STR+1), a

    ld   hl, (PENDING_ERROR_MSG)
    ld   de, MSG_STR
    call HEX_WORD_TO_STR

    ; ---- Step B: a real RUN, same as pressing RUN+ENTER ----
    call BASIC_RUN

    ld   hl, (CHECK_ERROR_COUNT)
    ld   de, ERR_STR
    call HEX_WORD_TO_STR

    xor  a
    ld   (ROW_STR+1), a
    ld   (COL_STR+1), a
    ld   a, (BASIC_OUTPUT_ROW)
    ld   de, ROW_STR
    call HEX_BYTE_TO_STR
    ld   a, (BASIC_OUTPUT_COL)
    ld   de, COL_STR
    call HEX_BYTE_TO_STR

    ; ---- draw everything ----
    call GFX_CLS

    ld   hl, LABEL_CHK
    ld   b, 0
    ld   c, 0
    call GFX_PRINT_STRING
    ld   hl, CHK_STR
    ld   b, 0
    ld   c, 4
    call GFX_PRINT_STRING
    ld   hl, LABEL_MSG
    ld   b, 0
    ld   c, 6
    call GFX_PRINT_STRING
    ld   hl, MSG_STR
    ld   b, 0
    ld   c, 10
    call GFX_PRINT_STRING

    ld   hl, LABEL_ERR
    ld   b, 1
    ld   c, 0
    call GFX_PRINT_STRING
    ld   hl, ERR_STR
    ld   b, 1
    ld   c, 4
    call GFX_PRINT_STRING
    ld   hl, LABEL_ROW
    ld   b, 1
    ld   c, 9
    call GFX_PRINT_STRING
    ld   hl, ROW_STR
    ld   b, 1
    ld   c, 13
    call GFX_PRINT_STRING
    ld   hl, LABEL_COL
    ld   b, 1
    ld   c, 16
    call GFX_PRINT_STRING
    ld   hl, COL_STR
    ld   b, 1
    ld   c, 20
    call GFX_PRINT_STRING

    ld   a, 7                       ; white — done
    out  (PORT_ULA), a
.done_loop:
    jr   .done_loop

LABEL_CHK: DB "CHK=", 0
LABEL_MSG: DB "MSG=", 0
LABEL_ERR: DB "ERR=", 0
LABEL_ROW: DB "ROW=", 0
LABEL_COL: DB "COL=", 0

; ============================================================================
; HEX_WORD_TO_STR / HEX_BYTE_TO_STR / HEX_CHAR — same as every other
; hex-overlay diagnostic in this project (see rom/archive/test_basic_
; nav_debug.asm), copied verbatim rather than sharing a module for one
; throwaway diagnostic.
; ============================================================================
HEX_WORD_TO_STR:
    ld   a, h
    push de
    call HEX_BYTE_TO_STR
    pop  de
    inc  de
    inc  de
    ld   a, l
    call HEX_BYTE_TO_STR
    ret

HEX_BYTE_TO_STR:
    ld   b, a
    push de
    and  $F0
    rrca
    rrca
    rrca
    rrca
    call HEX_CHAR
    pop  de
    ld   (de), a
    inc  de
    push de
    ld   a, b
    and  $0F
    call HEX_CHAR
    pop  de
    ld   (de), a
    inc  de
    xor  a
    ld   (de), a
    ret

HEX_CHAR:
    cp   10
    jr   c, .digit
    add  a, "A" - 10
    ret
.digit:
    add  a, "0"
    ret

PRELOAD_DATA:
    DB   $0E,$00,$50,$52,$49,$4E,$54,$20,$22,$68,$65,$6C,$6C,$6F,$22,$0D
PRELOAD_LEN EQU $ - PRELOAD_DATA

    INCLUDE "basic/basic.asm"
    INCLUDE "kernel/editor/editor.asm"
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/math/math.asm"
    INCLUDE "kernel/interrupt/interrupt.asm"
    INCLUDE "kernel/bank/bank.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_print_repro_debug.bin", $0000, $4000
