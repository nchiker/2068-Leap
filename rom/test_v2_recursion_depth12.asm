; ============================================================================
; rom/test_v2_recursion_depth12.asm — R10.7 item 7 (re-attempted) capacity
; regression test: PROC/CALL/DEF FN recursion depth 6->12.
;
; Same shape as rom/test_v2_proc_recursion.asm (post-R9 PROC/DEF-FN
; recursion-safety correction), but driven to the new maximum depth
; instead of the original milestone's depth-4 smoke case, to prove the
; widened VM_CALL_STACK (6->12 entries, FLOOR extended from $B694 to
; $B688) and VM_PARAM_SAVE stack (6->12 frames, TOP extended from $B762
; to $B792) both work correctly at their new real capacity, not just
; that the shallow original case still passes.
;
; Source program compiled and executed:
;
;   PROC COUNT(N):IF N>0 THEN CALL COUNT(N-1) ENDIF:R=R+N:ENDP
;   R=0:CALL COUNT(11):PRINT R
;
; COUNT(11) recurses 11 times (N=11,10,...,0), so exactly 12 calls are
; simultaneously open at the deepest point (N=0) — the new maximum depth,
; not one short of it. R accumulates 0+1+...+11 = 66.
;
; Symbol declaration order (CSYM_FIND_OR_CREATE, first appearance):
;   0=N (PROC COUNT's own parameter) 1=R.
; ============================================================================

    DEFINE TEST_V2_NEEDS_DECOMPILE
    INCLUDE "rom/test_v2_harness_home_head.inc"
    INCLUDE "rom/test_v2_symmacros.inc"

SOURCE_TEXT:
    db "PROC COUNT(N):IF N>0 THEN CALL COUNT(N-1) ENDIF:R=R+N:ENDP:"
    db "R=0:CALL COUNT(11):PRINT R", 0

; ============================================================================
; TEST_CHECK_RESULT — both the call stack and the parameter-save stack
; must be back to their own empty (TOP) state once the 12-deep recursion
; has fully unwound, then R must be exactly 66 (0+1+...+11).
; ============================================================================
TEST_CHECK_RESULT:
    ld   hl, (VM_CSP)
    ld   de, (VARS_START)
    or   a
    sbc  hl, de
    jr   nz, .fail
    TSYM_LD8 1*3  ; R's own tag
    cp   0
    jr   nz, .fail
    TSYM_LD16 1*3 + 1
    ld   de, 66                      ; 0+1+...+11
    or   a
    sbc  hl, de
    jr   nz, .fail
    ret
.fail:
    scf
    ret

; Test-only stubs: this file's own test program never exercises PRINT's
; own real screen output, LPRINT/BEEP/SOUND/PAUSE/INPUT, and never
; registers or calls a loadable extension -- same stubbing discipline as
; every other v2 test.
BASIC_STMT_LPRINT_EXROM:
    ret
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
EXT_CALL_ARG0: equ $8B00
EXT_CALL_ARG4: equ $8B00
EXT2_TABLE:    equ $8B00

GFX_CLS:
    ret
GFX_PAINT_ATTR:
    ret
GFX_SET_BORDER:
    ret
GFX_WRITE_PIXEL:
    ret
GFX_LINE:
    ret
GFX_PRINT_STRING_ATTR:
    ret
GFX_SCROLL_OUTPUT_UP:
    ret
GFX_SET_MODE:
    ret
GFX_SPRITE_CAPTURE:
    or a
    ret
GFX_SPRITE_DRAW:
    or a
    ret
GFX_READ_PIXEL:
    xor a
    ret
GFX_CELL_ATTR_ADDR:
    scf
    ret
    INCLUDE "rom/exrom_format.asm"
IO_READ_KEY_NONBLOCK:
        xor a
        ret

    INCLUDE "rom/test_v2_harness_home_tail.inc"
