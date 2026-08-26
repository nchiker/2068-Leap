; ============================================================================
; rom/test_nav_hook_debug.asm — nav-hook dispatch + state diagnostic
;
; Uses rom/editor_navdebug_copy.asm (a copy of kernel/editor/editor.asm
; with border-color markers and a loop-alive hex counter added around
; the UP/DOWN nav-hook dispatch) in place of the real
; kernel/editor/editor.asm. ALSO overlays CUR_EDIT_POS/CUR_EDIT_INDEX
; as hex at the bottom of the screen, on top of the real
; BASIC_REDRAW_PROGRAM rendering — combining both diagnostics into one,
; since the lockup this was originally built for is now fixed, but
; navigation still doesn't visibly move between lines despite the
; dispatch mechanism and loop both confirmed working.
;
; Border colors during a press: RED (entered dispatch) -> YELLOW (hook
; confirmed set) -> CYAN (about to jump) -> GREEN (successfully
; returned). Top-right: cycling hex digit, proves the loop is alive.
; Bottom two rows: "P=xxxx" (CUR_EDIT_POS), "I=xxxx" (CUR_EDIT_INDEX) —
; watch whether these actually CHANGE when you press UP/DOWN. If they
; don't change at all, BASIC_HANDLE_NAV is being reached (border proves
; that) but isn't updating state — if they DO change but the screen
; still doesn't look different, the bug is in BASIC_REDRAW_PROGRAM's
; rendering logic instead.
;
; This reimplements BASIC_COMMAND_LOOP's loop rather than calling it
; directly, since that routine sets the redraw hook internally and
; this needs to install a different (combined) one instead — reuses
; all the same real underlying routines unchanged.
;
; NOT YET ASSEMBLED OR TESTED BY THE AUTHOR.
;
; Build:
;   sjasmplus rom/test_nav_hook_debug.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_nav_hook_debug.bin --rom-ts2068-1 rom1.bin
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"

    DEVICE NOSLOT64K

; ---- RAM scratch for the debug display strings ----
POS_STR    EQU $8000   ; 5 bytes: 4 hex digits + null
IDX_STR    EQU $8010

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
; Calls the REAL BASIC_REDRAW_PROGRAM first, then overlays
; CUR_EDIT_POS/CUR_EDIT_INDEX as hex at rows 20-21.
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
    INCLUDE "rom/editor_navdebug_copy.asm"
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/math/math.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_nav_hook_debug.bin", $0000, $4000
