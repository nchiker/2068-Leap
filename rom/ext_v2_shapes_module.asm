; V2-native loadable CIRCLE/FILL package. Primitives are the validated
; graphics implementation retained from the former V1 SHAPES package.
    INCLUDE "include/hardware.inc"
    INCLUDE "include/v2_package_abi.inc"   ; R10.9: the ONLY HOME interface a package may use
    PKG_SVC_LIST
    PKG_CONST_LIST
    PKG_PIN_LIST
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
    jr   c, .room
    ld   a, 1                    ; STUDY (D7): a dropped seed is recorded; SHAPES_RESCAN recovers it
    ld   (SHAPES_OVF), a
    ret
.room:
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

; R10.7 P5: FILL is now a scanline SPAN fill. The old per-pixel 4-neighbour
; fill pushed up to four seeds per pixel and needed ~4 KB of stack (and lost
; part of any large region when that filled). The span fill paints a whole
; horizontal run, then pushes ONE seed per run of fillable pixels on the rows
; above and below, so the stack stays tiny. Fillable = pixel equals the seed's
; original value AND is not yet visited; the visited bitmap is unchanged.

; SHAPES_VISITED_ADDR -- B = x, C = y. Out: HL = visited-bitmap byte, E = mask.
; Destroys: AF, D.
SHAPES_VISITED_ADDR:
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
    ld   e, (hl)
    pop  hl
    ret

; SHAPES_GFX_FILL_VISITED_CHECK_SET -- mark (B,C) visited; carry set if it was.
SHAPES_GFX_FILL_VISITED_CHECK_SET:
    call SHAPES_VISITED_ADDR
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

; SHAPES_FILLABLE -- B = x, C = y. Carry clear if the pixel still equals the
; seed's original value and is unvisited. Preserves BC.
SHAPES_FILLABLE:
    push bc
    call GFX_READ_PIXEL
    ld   e, a
    ld   a, (GFX_FILL_TARGET)
    cp   e
    jr   nz, .no
    pop  bc
    push bc
    call SHAPES_VISITED_ADDR
    ld   a, (hl)
    and  e
    jr   z, .yes
.no:
    pop  bc
    scf
    ret
.yes:
    pop  bc                 ; (AND cleared carry)
    ret

; SHAPES_FILL_ROW -- C = row. Push one seed at the start of every run of
; fillable pixels between SHAPES_XL and SHAPES_XR.
SHAPES_FILL_ROW:
    xor  a
    ld   (SHAPES_PREV), a
    ld   a, (SHAPES_XL)
    ld   b, a
.x:
    call SHAPES_FILLABLE
    jr   c, .not
    ld   a, (SHAPES_PREV)
    or   a
    jr   nz, .next
    inc  a
    ld   (SHAPES_PREV), a
    call SHAPES_GFX_FILL_PUSH
    jr   .next
.not:
    xor  a
    ld   (SHAPES_PREV), a
.next:
    ld   a, (SHAPES_XR)
    cp   b
    ret  z
    inc  b
    jr   .x

SHAPES_GFX_FILL:
    xor  a
    ld   (SHAPES_OVF), a
    ld   (SHAPES_DIRTY), a
    ld   (SHAPES_SCANNING), a
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
    call SHAPES_GFX_FILL_PUSH

.loop:
    call SHAPES_GFX_FILL_POP
    jr   c, .dry
    ld   a, c
    ld   (SHAPES_Y), a
    call SHAPES_FILLABLE
    jr   c, .loop

    push bc                 ; seed
.left:
    ld   a, b
    or   a
    jr   z, .left_done
    dec  b
    call SHAPES_FILLABLE
    jr   nc, .left
    inc  b
.left_done:
    ld   a, b
    ld   (SHAPES_XL), a
    pop  bc
.right:
    ld   a, b
    cp   255
    jr   z, .right_done
    inc  b
    call SHAPES_FILLABLE
    jr   nc, .right
    dec  b
.right_done:
    ld   a, b
    ld   (SHAPES_XR), a

    ld   a, (SHAPES_XL)
    ld   b, a
.paint:
    push bc
    call SHAPES_GFX_FILL_VISITED_CHECK_SET
    pop  bc
    push bc
    ld   d, 0
    ld   a, (GFX_FILL_ATTR)
    call GFX_WRITE_PIXEL
    pop  bc
    ld   a, (SHAPES_XR)
    cp   b
    jr   z, .painted
    inc  b
    jr   .paint
.painted:
    ld   a, (SHAPES_Y)
    or   a
    jr   z, .no_up
    dec  a
    ld   c, a
    call SHAPES_FILL_ROW
.no_up:
    ld   a, (SHAPES_Y)
    cp   191
    jr   nc, .loop
    inc  a
    ld   c, a
    call SHAPES_FILL_ROW
    jr   .loop

; STUDY (D7): the seed stack ran dry.  A push dropped during a drain (SHAPES_OVF) means an unfilled region
; may touch the painted area, so SWEEP: walk the visited bitmap in row-major order and seed every fillable
; 4-neighbour of every visited pixel.  The sweep is resumable (cursor SHAPES_RX/RY): when a seed does not fit
; it stops at that pixel, the stack is drained, and the sweep resumes there.  A drop during a drain marks the
; sweep dirty -> one more sweep from the top.  Done when a whole sweep seeds nothing and nothing was dropped.
.dry:
    ld   a, (SHAPES_OVF)
    or   a
    jr   z, .dry_clean
    xor  a
    ld   (SHAPES_OVF), a
    inc  a
    ld   (SHAPES_DIRTY), a
.dry_clean:
    ld   a, (SHAPES_SCANNING)
    or   a
    jr   nz, .sweep
    ld   a, (SHAPES_DIRTY)
    or   a
    ret  z
    xor  a
    ld   (SHAPES_DIRTY), a
    ld   (SHAPES_RX), a
    ld   (SHAPES_RY), a
    inc  a
    ld   (SHAPES_SCANNING), a
.sweep:
    xor  a
    ld   (SHAPES_PUSHED), a
    ld   a, (SHAPES_RX)
    ld   b, a
    ld   a, (SHAPES_RY)
    ld   c, a
.rs_px:
    push bc
    call SHAPES_VISITED_ADDR
    ld   a, (hl)
    pop  bc
    or   a
    jr   nz, .rs_byte
    ld   a, b                    ; empty byte: skip to the next one
    or   7
    inc  a
    ld   b, a
    jr   nz, .rs_px
    jr   .rs_nextrow
.rs_byte:
    push bc
    call SHAPES_VISITED_ADDR     ; E = mask of this pixel
    ld   a, (hl)
    pop  bc
    and  e
    jr   z, .rs_adv
    call SHAPES_NEIGHBOURS
    ld   a, (SHAPES_OVF)
    or   a
    jr   z, .rs_adv
    xor  a                       ; the stack is full: resume at this pixel after the drain
    ld   (SHAPES_OVF), a
    ld   a, b
    ld   (SHAPES_RX), a
    ld   a, c
    ld   (SHAPES_RY), a
    jp   .loop
.rs_adv:
    inc  b
    jr   nz, .rs_px
.rs_nextrow:
    inc  c
    ld   a, c
    cp   192
    jr   c, .rs_px_row
    xor  a                       ; sweep complete
    ld   (SHAPES_SCANNING), a
    ld   a, (SHAPES_PUSHED)
    or   a
    jp   nz, .loop               ; drain what this last stretch seeded
    jp   .dry_clean              ; dirty? -> a new sweep, else done
.rs_px_row:
    ld   b, 0
    jr   .rs_px

; SHAPES_NEIGHBOURS -- B,C = a visited pixel; seed each fillable 4-neighbour. Preserves BC.
SHAPES_NEIGHBOURS:
    ld   a, b
    or   a
    jr   z, .nl
    dec  b
    call SHAPES_SEED
    inc  b
.nl:
    ld   a, b
    inc  a
    jr   z, .nr
    inc  b
    call SHAPES_SEED
    dec  b
.nr:
    ld   a, c
    or   a
    jr   z, .nu
    dec  c
    call SHAPES_SEED
    inc  c
.nu:
    ld   a, c
    cp   191
    ret  nc
    inc  c
    call SHAPES_SEED
    dec  c
    ret

SHAPES_SEED:
    call SHAPES_FILLABLE
    ret  c
    ld   a, 1
    ld   (SHAPES_PUSHED), a
    jp   SHAPES_GFX_FILL_PUSH

; span-fill scratch (the package image lives in RAM)
SHAPES_OVF:    DB 0
SHAPES_PUSHED: DB 0
SHAPES_DIRTY:  DB 0
SHAPES_SCANNING: DB 0
SHAPES_RX:     DB 0
SHAPES_RY:     DB 0
SHAPES_XL:   DB 0
SHAPES_XR:   DB 0
SHAPES_Y:    DB 0
SHAPES_PREV: DB 0

V2_SHAPES_PACKAGE_END:
    ASSERT $ <= EXTENSION_MODULE_LIMIT
    SAVEBIN "build/v2_package_shapes.bin", EXTENSION_MODULE_BASE, V2_SHAPES_PACKAGE_END-EXTENSION_MODULE_BASE
