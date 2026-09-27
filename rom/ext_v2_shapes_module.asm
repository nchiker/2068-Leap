; V2-native loadable CIRCLE/FILL package. Primitives are the validated
; graphics implementation retained from the former V1 SHAPES package.
    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"
    INCLUDE "build/v2_crossbank.inc"
    DEVICE NOSLOT64K
    ORG EXTENSION_MODULE_BASE
    jp SHAPES_INSTALL

SHAPES_INSTALL:
    ld hl,SHAPES_CIRCLE_NAME
    ld de,SHAPES_CIRCLE_EXEC
    ld b,3
    ld c,0
    call EXT2_REGISTER
    ret c
    ld hl,SHAPES_FILL_NAME
    ld de,SHAPES_FILL_EXEC
    ld b,2
    ld c,0
    jp EXT2_REGISTER

SHAPES_CIRCLE_NAME: DB "CIRCLE",0
SHAPES_FILL_NAME: DB "FILL",0

SHAPES_CIRCLE_EXEC:
    ld hl,(EXT_CALL_ARG0)
    ld a,l
    ld (GFX_CIRCLE_XC),a
    ld hl,(EXT_CALL_ARG1)
    ld a,l
    call VM_CLAMP_Y191
    ld (GFX_CIRCLE_YC),a
    ld hl,(EXT_CALL_ARG2)
    ld a,l
    ld (GFX_CIRCLE_R),a
    call VM_COMPUTE_PRINT_ATTR
    ld (GFX_CIRCLE_ATTR),a
    ld a,(CURRENT_OVER)
    ld (GFX_CIRCLE_OVER),a
    jp SHAPES_GFX_CIRCLE

SHAPES_FILL_EXEC:
    ld hl,(EXT_CALL_ARG0)
    ld a,l
    ld (GFX_FILL_X),a
    ld hl,(EXT_CALL_ARG1)
    ld a,l
    call VM_CLAMP_Y191
    ld (GFX_FILL_Y),a
    call VM_COMPUTE_PRINT_ATTR
    ld (GFX_FILL_ATTR),a
    jp SHAPES_GFX_FILL

SHAPES_GFX_CIRCLE_PLOT_OFFSET:
    push de
    ld   a, (GFX_CIRCLE_XC)
    ld   e, a
    ld   d, 0
    add  hl, de
    pop  de
    push hl
    ld   a, (GFX_CIRCLE_YC)
    ld   l, a
    ld   h, 0
    add  hl, de
    ex   de, hl
    pop  hl
    ld   a, (GFX_CIRCLE_OVER)
    ld   b, a
    ld   a, (GFX_CIRCLE_ATTR)
    jp   GFX_PLOT_CLIPPED

SHAPES_GFX_CIRCLE_PLOT_POLES:
    ld   a, (GFX_CIRCLE_Y)
    ld   e, a
    ld   d, 0
    ld   hl, 0
    call SHAPES_GFX_CIRCLE_PLOT_OFFSET
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    ld   de, 0
    call SHAPES_GFX_CIRCLE_PLOT_OFFSET
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    ld   de, 0
    call SHAPES_GFX_CIRCLE_PLOT_OFFSET
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    ex   de, hl
    ld   hl, 0
    jp   SHAPES_GFX_CIRCLE_PLOT_OFFSET

SHAPES_GFX_CIRCLE_PLOT_GENERAL:
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    ex   de, hl
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    call SHAPES_GFX_CIRCLE_PLOT_OFFSET
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    ex   de, hl
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    call SHAPES_GFX_CIRCLE_PLOT_OFFSET
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    ex   de, hl
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    call SHAPES_GFX_CIRCLE_PLOT_OFFSET
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    ex   de, hl
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    call SHAPES_GFX_CIRCLE_PLOT_OFFSET

    ld   a, (GFX_CIRCLE_X)
    ld   b, a
    ld   a, (GFX_CIRCLE_Y)
    cp   b
    ret  z

    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    ex   de, hl
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call SHAPES_GFX_CIRCLE_PLOT_OFFSET
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    ex   de, hl
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    call SHAPES_GFX_CIRCLE_PLOT_OFFSET
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    ex   de, hl
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call SHAPES_GFX_CIRCLE_PLOT_OFFSET
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    ex   de, hl
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    jp   SHAPES_GFX_CIRCLE_PLOT_OFFSET

SHAPES_GFX_CIRCLE:
    ld   a, (GFX_CIRCLE_R)
    or   a
    jr   nz, .r_nonzero

    ld   a, (GFX_CIRCLE_XC)
    ld   l, a
    ld   h, 0
    ld   a, (GFX_CIRCLE_YC)
    ld   e, a
    ld   d, 0
    ld   a, (GFX_CIRCLE_OVER)
    ld   b, a
    ld   a, (GFX_CIRCLE_ATTR)
    jp   GFX_PLOT_CLIPPED

.r_nonzero:
    xor  a
    ld   (GFX_CIRCLE_X), a
    ld   a, (GFX_CIRCLE_R)
    ld   (GFX_CIRCLE_Y), a

    ld   hl, 1
    ld   e, a
    ld   d, 0
    or   a
    sbc  hl, de
    ld   (GFX_CIRCLE_D), hl

    call SHAPES_GFX_CIRCLE_PLOT_POLES

.loop:
    ld   a, (GFX_CIRCLE_X)
    inc  a
    ld   (GFX_CIRCLE_X), a

    ld   hl, (GFX_CIRCLE_D)
    bit  7, h
    jr   z, .d_not_negative

    ld   a, (GFX_CIRCLE_X)
    ld   e, a
    ld   d, 0
    add  hl, de
    add  hl, de
    inc  hl
    ld   (GFX_CIRCLE_D), hl
    jr   .step_done

.d_not_negative:
    ld   a, (GFX_CIRCLE_Y)
    dec  a
    ld   (GFX_CIRCLE_Y), a
    ld   e, a
    ld   d, 0
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    or   a
    sbc  hl, de
    add  hl, hl
    inc  hl
    ex   de, hl
    ld   hl, (GFX_CIRCLE_D)
    add  hl, de
    ld   (GFX_CIRCLE_D), hl

.step_done:
    ld   a, (GFX_CIRCLE_X)
    ld   b, a
    ld   a, (GFX_CIRCLE_Y)
    cp   b
    ret  c

    call SHAPES_GFX_CIRCLE_PLOT_GENERAL
    jp   .loop

; ---- ported verbatim from kernel/graphics/graphics.asm's own
; GFX_FILL_PUSH/POP/TRY_NEIGHBOR/VISITED_CHECK_SET/GFX_FILL — see that
; file's own removal note for the original headers/verification history
; (the OVER/XOR bug, the cell-granularity-dedup bug, the 51x51/256x192
; Python stress checks). Only the names gained a SHAPES_ prefix, and
; BIT_MASK_TABLE (originally shared with other graphics code, not worth
; duplicating a second copy of) is reproduced locally since this module
; has no other way to reach the Home original at $C000-$DFFF-adjacent
; addresses reliably build-to-build. ----

SHAPES_BIT_MASK_TABLE:
    DB   %10000000, %01000000, %00100000, %00010000
    DB   %00001000, %00000100, %00000010, %00000001

SHAPES_GFX_FILL_PUSH:
    ld   hl, (GFX_FILL_SP)
    ld   de, GFX_FILL_STACK_END
    or   a
    sbc  hl, de
    ret  nc

    ld   hl, (GFX_FILL_SP)
    ld   (hl), b
    inc  hl
    ld   (hl), c
    inc  hl
    ld   (GFX_FILL_SP), hl
    ret

SHAPES_GFX_FILL_POP:
    ld   hl, (GFX_FILL_SP)
    ld   de, GFX_FILL_STACK
    or   a
    sbc  hl, de
    jr   z, .empty

    ld   hl, (GFX_FILL_SP)
    dec  hl
    ld   c, (hl)
    dec  hl
    ld   b, (hl)
    ld   (GFX_FILL_SP), hl
    or   a
    ret
.empty:
    scf
    ret

SHAPES_GFX_FILL_TRY_NEIGHBOR:
    push bc
    call GFX_READ_PIXEL
    ld   e, a
    ld   a, (GFX_FILL_TARGET)
    cp   e
    jr   nz, .not_match

    pop  bc
    push bc
    call SHAPES_GFX_FILL_VISITED_CHECK_SET
    jr   c, .not_match

    pop  bc
    push bc
    ld   d, 0
    ld   a, (GFX_FILL_ATTR)
    call GFX_WRITE_PIXEL
    pop  bc
    jp   SHAPES_GFX_FILL_PUSH
.not_match:
    pop  bc
    ret

SHAPES_GFX_FILL_VISITED_CHECK_SET:
    ld   a, c
    ld   l, a
    ld   h, 0
    add  hl, hl
    add  hl, hl
    add  hl, hl
    add  hl, hl
    add  hl, hl
    ld   a, b
    srl  a
    srl  a
    srl  a
    ld   e, a
    ld   d, 0
    add  hl, de
    ld   de, GFX_FILL_VISITED
    add  hl, de

    ld   a, b
    and  %00000111
    ld   e, a
    ld   d, 0
    push hl
    ld   hl, SHAPES_BIT_MASK_TABLE
    add  hl, de
    ld   a, (hl)
    pop  hl
    ld   e, a
    ld   a, (hl)
    and  e
    jr   nz, .already
    ld   a, (hl)
    or   e
    ld   (hl), a
    or   a
    ret
.already:
    scf
    ret

SHAPES_GFX_FILL:
    ld   hl, GFX_FILL_STACK
    ld   (GFX_FILL_SP), hl

    ld   hl, GFX_FILL_VISITED
    ld   (hl), 0
    ld   de, GFX_FILL_VISITED + 1
    ld   bc, 6144 - 1
    ldir

    ld   a, (GFX_FILL_X)
    ld   b, a
    ld   a, (GFX_FILL_Y)
    ld   c, a
    call GFX_READ_PIXEL
    ld   (GFX_FILL_TARGET), a

    ld   a, (GFX_FILL_X)
    ld   b, a
    ld   a, (GFX_FILL_Y)
    ld   c, a
    call SHAPES_GFX_FILL_VISITED_CHECK_SET
    ld   a, (GFX_FILL_X)
    ld   b, a
    ld   a, (GFX_FILL_Y)
    ld   c, a
    ld   d, 0
    ld   a, (GFX_FILL_ATTR)
    call GFX_WRITE_PIXEL
    ld   a, (GFX_FILL_X)
    ld   b, a
    ld   a, (GFX_FILL_Y)
    ld   c, a
    call SHAPES_GFX_FILL_PUSH

.loop:
    call SHAPES_GFX_FILL_POP
    ret  c

    ld   a, b
    ld   (GFX_FILL_X), a
    ld   a, c
    ld   (GFX_FILL_Y), a

    ld   a, (GFX_FILL_X)
    cp   255
    jr   z, .skip_right
    ld   b, a
    inc  b
    ld   a, (GFX_FILL_Y)
    ld   c, a
    call SHAPES_GFX_FILL_TRY_NEIGHBOR
.skip_right:

    ld   a, (GFX_FILL_X)
    or   a
    jr   z, .skip_left
    ld   b, a
    dec  b
    ld   a, (GFX_FILL_Y)
    ld   c, a
    call SHAPES_GFX_FILL_TRY_NEIGHBOR
.skip_left:

    ld   a, (GFX_FILL_Y)
    cp   191
    jr   nc, .skip_down
    ld   c, a
    inc  c
    ld   a, (GFX_FILL_X)
    ld   b, a
    call SHAPES_GFX_FILL_TRY_NEIGHBOR
.skip_down:

    ld   a, (GFX_FILL_Y)
    or   a
    jr   z, .skip_up
    ld   c, a
    dec  c
    ld   a, (GFX_FILL_X)
    ld   b, a
    call SHAPES_GFX_FILL_TRY_NEIGHBOR
.skip_up:

    jp   .loop

V2_SHAPES_PACKAGE_END:
    ASSERT $ <= EXTENSION_MODULE_LIMIT
    SAVEBIN "build/v2_package_shapes.bin", EXTENSION_MODULE_BASE, V2_SHAPES_PACKAGE_END-EXTENSION_MODULE_BASE
