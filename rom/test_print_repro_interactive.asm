; ============================================================================
; rom/test_print_repro_interactive.asm — diagnostic, round 2, for the
; "PRINT "hello" doesn't run" bug. rom/test_print_repro_debug.asm
; already proved BASIC_CHECK_STATEMENT_EXROM and BASIC_RUN both work
; correctly on a HAND-ENCODED/bulk-copied program — CHK=0, ERR=0000,
; ROW=01. That bypassed the interactive editor's own commit path
; entirely (a raw LDIR into PROG_AREA_START, not a real ENTER-triggered
; MEM_LINE_STORE). This harness instead replicates BASIC_COMMAND_LOOP's
; REAL commit sequence exactly (BASIC_UPPERCASE_KEYWORD_PREFIX ->
; BASIC_TOKENIZE_LINE -> MEM_LINE_STORE -> BASIC_FULL_CHECK_EXROM, the
; same code basic.asm's `.not_load`/`.not_delete` fallthrough runs),
; starting from a genuinely fresh MEM_INIT'd empty program — the one
; difference the first diagnostic couldn't rule out.
;
; Fully automated — simulates typing "PRINT "hello"" into EDIT_LINE_BUF
; and committing it (as if ENTER were pressed on the sentinel line),
; THEN simulates typing "RUN" and running it, exactly matching the
; report's own repro steps. No keypresses needed.
;
; Row 0: "C1=x" — CHECK_ERROR_COUNT immediately after the PRINT commit
;   itself (BASIC_COMMAND_LOOP's append path re-checks the whole
;   program on every commit now, not just on RUN — see basic.asm's own
;   "REAL BUG FOUND AND FIXED" comment on that call). x=0 means the
;   freshly-committed program checks out clean at commit time already.
; Row 1: "C2=x ROW=xx COL=xx" — same three values as the first
;   diagnostic, but now after the REAL commit + a real BASIC_RUN.
; Row 2: raw bytes actually stored in the program area (PROG_AREA_START
;   up to PROG_END, capped at 16), as hex — compare against the hand-
;   encoded 0E,00,50,52,49,4E,54,20,22,68,65,6C,6C,6F,22,0D the first
;   diagnostic used directly, byte for byte.
;
; Border white (7) once drawn, stable.
;
; Build:
;   sjasmplus rom/test_print_repro_interactive.asm
;   sjasmplus rom/exrom_build.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_print_repro_interactive.bin --rom-ts2068-1 exrom.bin
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"
    DEFINE EXROM_JUMPTABLE_HOME_SIDE
    INCLUDE "include/exrom_jumptable.inc"

    DEVICE NOSLOT64K

C1_STR       EQU $8100   ; 2 bytes: "0"/"1" + null
C2_STR       EQU $8110
ROW_STR      EQU $8120
COL_STR      EQU $8130
PROG_HEX     EQU $8140   ; 33 bytes: 16 bytes * 2 hex chars + null
DUMP_READ_PTR EQU $8180  ; 2 bytes — scratch for the hexdump loop below

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
    im   1
    ei

    ; same cold-boot sysvar defaults BASIC_COMMAND_LOOP itself sets,
    ; that this harness's own commit-sequence replication depends on
    xor  a
    ld   (DELETE_INVALID_FLAG), a
    ld   hl, 0
    ld   (CHECK_ERROR_COUNT), hl
    ld   hl, $FFFF
    ld   (CUR_EDIT_POS), hl
    ld   hl, 0
    ld   (CUR_EDIT_INDEX), hl

    ; ---- simulate typing PRINT "hello" and pressing ENTER ----
    ld   hl, TYPED_PRINT
    ld   de, EDIT_LINE_BUF
    ld   bc, TYPED_PRINT_LEN
    ldir

    call BASIC_UPPERCASE_KEYWORD_PREFIX
    call BASIC_TOKENIZE_LINE            ; HL = TOKEN_BUF
    ex   de, hl                         ; DE = TOKEN_BUF

    ld   hl, (CUR_EDIT_POS)
    call BASIC_IS_SENTINEL              ; sentinel -> append path, same
                                        ; as BASIC_COMMAND_LOOP's own
                                        ; .not_delete fallthrough —
                                        ; PENDING_DELETE_POS bookkeeping
                                        ; skipped here since DELETE_
                                        ; INVALID_FLAG is already 0
    ld   hl, (PROG_END)
    call MEM_LINE_STORE

    call BASIC_FULL_CHECK_EXROM

    ld   hl, (CUR_EDIT_INDEX)
    inc  hl
    ld   (CUR_EDIT_INDEX), hl

    ; ---- Row 0 data: check state right after the commit ----
    ld   hl, (CHECK_ERROR_COUNT)
    ld   a, l
    or   h
    jr   z, .c1_zero
    ld   a, "1"
    jr   .c1_store
.c1_zero:
    ld   a, "0"
.c1_store:
    ld   (C1_STR), a
    xor  a
    ld   (C1_STR+1), a

    ; ---- simulate typing RUN and pressing ENTER ----
    call BASIC_RUN

    ld   hl, (CHECK_ERROR_COUNT)
    ld   a, l
    or   h
    jr   z, .c2_zero
    ld   a, "1"
    jr   .c2_store
.c2_zero:
    ld   a, "0"
.c2_store:
    ld   (C2_STR), a
    xor  a
    ld   (C2_STR+1), a

    xor  a
    ld   (ROW_STR+1), a
    ld   (COL_STR+1), a
    ld   a, (BASIC_OUTPUT_ROW)
    ld   de, ROW_STR
    call HEX_BYTE_TO_STR
    ld   a, (BASIC_OUTPUT_COL)
    ld   de, COL_STR
    call HEX_BYTE_TO_STR

    ; ---- dump the raw stored program bytes (PROG_AREA_START..PROG_END,
    ; capped at 16 bytes) ----
    ld   hl, PROG_AREA_START
    ld   (DUMP_READ_PTR), hl
    ld   ix, PROG_HEX
    ld   b, 16                          ; hard cap, independent of the
                                        ; PROG_END check below — safety
                                        ; against a corrupted/huge
                                        ; PROG_END overflowing PROG_HEX
.hexdump_loop:
    ld   hl, (DUMP_READ_PTR)
    ld   de, (PROG_END)
    or   a
    sbc  hl, de
    jr   nc, .hexdump_stop               ; read ptr >= PROG_END -> done

    ld   hl, (DUMP_READ_PTR)
    ld   a, (hl)
    push bc                              ; HEX_BYTE_TO_STR destroys B —
                                        ; survive our own outer counter
                                        ; across the call
    push ix
    pop  de
    call HEX_BYTE_TO_STR                 ; writes 2 hex chars + null at
                                        ; (DE) = current IX position
    pop  bc

    push de
    pop  ix                              ; IX = DE (post-call DE still
                                        ; points at PROG_HEX's running
                                        ; write position; HEX_BYTE_TO_
                                        ; STR left DE advanced 2 past
                                        ; where it started — see its own
                                        ; header)
    ld   hl, (DUMP_READ_PTR)
    inc  hl
    ld   (DUMP_READ_PTR), hl

    djnz .hexdump_loop
.hexdump_stop:
    xor  a
    ld   (ix), a                         ; null-terminate wherever the
                                        ; dump stopped

    call GFX_CLS

    ld   hl, LABEL_C1
    ld   b, 0
    ld   c, 0
    call GFX_PRINT_STRING
    ld   hl, C1_STR
    ld   b, 0
    ld   c, 3
    call GFX_PRINT_STRING

    ld   hl, LABEL_C2
    ld   b, 1
    ld   c, 0
    call GFX_PRINT_STRING
    ld   hl, C2_STR
    ld   b, 1
    ld   c, 3
    call GFX_PRINT_STRING
    ld   hl, LABEL_ROW
    ld   b, 1
    ld   c, 6
    call GFX_PRINT_STRING
    ld   hl, ROW_STR
    ld   b, 1
    ld   c, 10
    call GFX_PRINT_STRING
    ld   hl, LABEL_COL
    ld   b, 1
    ld   c, 13
    call GFX_PRINT_STRING
    ld   hl, COL_STR
    ld   b, 1
    ld   c, 17
    call GFX_PRINT_STRING

    ld   hl, PROG_HEX
    ld   b, 2
    ld   c, 0
    call GFX_PRINT_STRING

    ld   a, 7                       ; white — done
    out  (PORT_ULA), a
.done_loop:
    jr   .done_loop

LABEL_C1:  DB "C1=", 0
LABEL_C2:  DB "C2=", 0
LABEL_ROW: DB "ROW=", 0
LABEL_COL: DB "COL=", 0

TYPED_PRINT: DB 'PRINT "hello"', 0
TYPED_PRINT_LEN EQU $ - TYPED_PRINT

; ============================================================================
; HEX_BYTE_TO_STR
; In:  A = byte value, DE = destination (3 bytes: 2 hex digits + null)
; Out: destination filled; DE advanced past the 2 hex digits (points at
;      the null byte just written) — this harness's own hexdump loop
;      relies on that to chain consecutive writes
; Destroys: AF, BC
; ============================================================================
HEX_BYTE_TO_STR:
    ld   b, a
    and  $F0
    rrca
    rrca
    rrca
    rrca
    call HEX_CHAR
    ld   (de), a
    inc  de
    ld   a, b
    and  $0F
    call HEX_CHAR
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

    INCLUDE "basic/basic.asm"
    INCLUDE "kernel/editor/editor.asm"
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/math/math.asm"
    INCLUDE "kernel/interrupt/interrupt.asm"
    INCLUDE "kernel/bank/bank.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_print_repro_interactive.bin", $0000, $4000
