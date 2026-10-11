; ============================================================================
; rom/v2_lowrom_fill.asm -- RC shrink: small production routines placed in the low-ROM padding of
; the HOME image (the unused bytes of the RST slots). Each one's usual definition (kernel/, rom/)
; is kept for the other builds under IFNDEF V2_PRODUCTION; nothing references these by address
; ranges, only by name (call / jp / dw), and none is the fall-through target of the code before it.
; ============================================================================
V2_LOWROM_RESUME equ $
    ORG $0004                     ; after di / jp V2_COLD_START
MATH_RND_SEED:
    ld   (RND_STATE), hl
    ret
    ASSERT $ <= $0008
    ORG $000B                     ; after RST $08's jp
INT_GET_FRAMES:
    ld   hl, (FRAMES)
    ret
    ASSERT $ <= $0010
    ORG $0013                     ; after RST $10's jp
OP_NL:
    call VM_ADVANCE_OUTPUT_ROW
    jp (iy)
    ASSERT $ <= $0018
    ORG $001B                     ; after RST $18's jp
COMPILE_PAUSE:                    ; PAUSE <n>
    ld a,32                       ; OP_PAUSE
    jp COMPILE_1ARG_STMT
    ASSERT $ <= $0020
    ORG $0023                     ; after RST $20's jp
COMPILE_CLS:
    rst $08                       ; consume CLS
    ld a,23                       ; OP_CLS
    rst $20
    ret
    ASSERT $ <= $0028
    ORG $002B                     ; after RST $28's jp
COMPILE_CLEAR:
    rst $08                       ; consume CLEAR
    ld a,62                       ; OP_CLEAR
    rst $20
    ret
    ASSERT $ <= $0030
    ORG $0035                     ; after RST $30's code
IO_KEY_SCAN_ROW:
    in   a, (PORT_ULA)
    ret
    ASSERT $ <= $0038
    ORG V2_LOWROM_RESUME
