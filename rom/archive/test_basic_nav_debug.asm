; ============================================================================
; rom/test_basic_nav_debug.asm — multi-line navigation diagnostic
;
; Shows the SAME rendering test_basic.asm shows (calls
; BASIC_REDRAW_PROGRAM directly, not a reimplementation of it), but
; ALSO overlays internal navigation state as hex at fixed bottom rows,
; so we can see exactly what CUR_EDIT_POS/CUR_EDIT_INDEX/VIEW_TOP_INDEX
; are doing alongside what's actually on screen — built to diagnose a
; specific report: committed lines seeming to vanish, and UP not
; showing existing text.
;
; Row 20: "P=xxxx" — CUR_EDIT_POS (should be an existing statement's
;         address when navigating one, or FFFF for the new/uncommitted line)
; Row 21: "I=xxxx" — CUR_EDIT_INDEX (0-based)
; Row 22: "T=xxxx" — VIEW_TOP_INDEX (which statement shows at row 0)
; Row 23: "E=xxxx" — PROG_END (grows as statements are added)
;   NOTE: row 23 is now ALSO used by the real status line
;   (BASIC_DRAW_STATUS_LINE), added after this diagnostic served its
;   original purpose (the navigation bugs it was built to find are all
;   fixed and confirmed). Expect this overlay and the status line to
;   overwrite each other on row 23 — not worth reworking a diagnostic
;   whose job is done, but flagged here so it isn't confusing if this
;   file gets reused later.
;
; Same REPL workflow as test_basic.asm otherwise: type a line, ENTER,
; type RUN alone to execute, arrow UP/DOWN to navigate. Watch the
; bottom rows change as you commit lines and navigate.
;
; NOT YET ASSEMBLED OR TESTED BY THE AUTHOR.
;
; Build:
;   sjasmplus rom/test_basic_nav_debug.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_basic_nav_debug.bin --rom-ts2068-1 rom1.bin
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"

    DEVICE NOSLOT64K

; ---- RAM scratch for the debug display strings ----
POS_STR    EQU $8000   ; 7 bytes: "P=" not stored here, just 4 hex + null
IDX_STR    EQU $8010
TOP_STR    EQU $8020
END_STR    EQU $8030

    ORG $0000
RST_00:
    di
    jp   COLD_START
    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00
    call MEM_INIT

    ld   hl, $FFFF
    ld   (CUR_EDIT_POS), hl
    ld   hl, 0
    ld   (CUR_EDIT_INDEX), hl
    ld   (VIEW_TOP_INDEX), hl

DEBUG_LOOP:
    call EDITOR_INIT
    ld   hl, DEBUG_REDRAW
    ld   (EDITOR_REDRAW_HOOK), hl
    ld   hl, BASIC_HANDLE_NAV
    ld   (EDITOR_NAV_HOOK), hl

    call BASIC_LOAD_EDIT_LINE

    ld   hl, (CUR_EDIT_POS)
    call BASIC_IS_SENTINEL
    jr   nz, .use_existing_pos
    ld   hl, (PROG_END)
    jr   .have_editor_pos
.use_existing_pos:
    ld   hl, (CUR_EDIT_POS)
.have_editor_pos:
    call EDITOR_ENTER

    ld   a, (EDIT_LINE_BUF)
    or   a
    jr   z, DEBUG_LOOP

    ld   hl, EDIT_LINE_BUF
    ld   de, KW_RUN
    call BASIC_MATCH_KEYWORD
    jr   c, .not_run

.check_trailing:
    ld   a, (hl)
    or   a
    jr   z, .is_run
    cp   " "
    jr   nz, .not_run
    inc  hl
    jr   .check_trailing

.is_run:
    call BASIC_RUN
    call BASIC_WAIT_FOR_KEY
    jr   DEBUG_LOOP

.not_run:
    call BASIC_UPPERCASE_KEYWORD_PREFIX
    call BASIC_TOKENIZE_LINE
    ex   de, hl

    ld   hl, (CUR_EDIT_POS)
    call BASIC_IS_SENTINEL
    jr   nz, .commit_existing

    ld   hl, (PROG_END)
    call MEM_LINE_STORE
    ld   hl, (CUR_EDIT_INDEX)
    inc  hl
    ld   (CUR_EDIT_INDEX), hl
    jr   DEBUG_LOOP

.commit_existing:
    ld   hl, (CUR_EDIT_POS)
    call MEM_LINE_STORE
    ld   a, EDIR_DOWN
    call BASIC_HANDLE_NAV
    jr   DEBUG_LOOP

; ============================================================================
; DEBUG_REDRAW
; Calls the REAL BASIC_REDRAW_PROGRAM first (same rendering the actual
; test shows), then overlays navigation state as hex at rows 20-23.
; ============================================================================
DEBUG_REDRAW:
    call BASIC_REDRAW_PROGRAM

    ld   hl, (CUR_EDIT_POS)
    ld   de, POS_STR
    call HEX_WORD_TO_STR
    ld   hl, POS_STR
    ld   b, 20
    ld   c, 0
    call GFX_PRINT_STRING

    ld   hl, (CUR_EDIT_INDEX)
    ld   de, IDX_STR
    call HEX_WORD_TO_STR
    ld   hl, IDX_STR
    ld   b, 21
    ld   c, 0
    call GFX_PRINT_STRING

    ld   hl, (VIEW_TOP_INDEX)
    ld   de, TOP_STR
    call HEX_WORD_TO_STR
    ld   hl, TOP_STR
    ld   b, 22
    ld   c, 0
    call GFX_PRINT_STRING

    ld   hl, (PROG_END)
    ld   de, END_STR
    call HEX_WORD_TO_STR
    ld   hl, END_STR
    ld   b, 23
    ld   c, 0
    call GFX_PRINT_STRING
    ret

; ============================================================================
; HEX_WORD_TO_STR
; In:  HL = word value, DE = destination (5 bytes: 4 hex digits + null)
; Out: destination filled
; Destroys: AF, BC
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

; ============================================================================
; HEX_BYTE_TO_STR
; In:  A = byte value, DE = destination (3 bytes: 2 hex digits + null)
; Out: destination filled
; Destroys: AF, BC
; ============================================================================
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

; ============================================================================
; HEX_CHAR
; In:  A = nibble (0-15)
; Out: A = ASCII hex digit
; Destroys: AF
; ============================================================================
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

    DS   $4000 - $, $FF

    SAVEBIN "test_basic_nav_debug.bin", $0000, $4000
