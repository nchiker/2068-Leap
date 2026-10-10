; V2-native loadable GRAPHICS package: CPLOT, BLOCK, FRAME, INVERT.
; R10.7 item 3 — clean EXT2 ports of the four V1 extensions retained at
; rom/extensions/{cplot,block,frame,invert}.asm (full, working, tested
; implementations that never shipped in V2 — R10.25's own capability-
; exposure audit's headline correction). The V1 extension ABI (EXT_
; SERVICE_REGISTER/EXTENSION_ARG0..3/EXT_SERVICE_PRINT_ATTR/READ_OVER/
; WRITE_PIXEL, basic/basic.asm's now-superseded gateway) is NOT restored
; or preserved here — every call site is ported onto V2's own EXT2_
; REGISTER/EXT_CALL_ARG0../VM_COMPUTE_PRINT_ATTR/GFX_WRITE_PIXEL
; convention, the same one rom/ext_v2_shapes_module.asm's own CIRCLE/
; FILL already use.
;
; Common validation/coordinate handling factored into two shared
; routines (GRAPHICS_RESOLVE_RECT, GRAPHICS_FILL_RECT) reused by BLOCK/
; FRAME/INVERT (all three take the same 4-arg x0,y0,x1,y1 rectangle
; shape) instead of three near-copies of the same ~20-line ordering/
; attr/over resolve — the single biggest size win available in this
; package, found the same way R10.5's own shrink pass found its shared-
; prologue candidates: by direct comparison of the four V1 originals.
;
; Scratch state is declared LOCALLY in this file (not include/
; sysvars.inc), matching the four V1 originals' own precedent (CPLOT_
; BASE_X etc in rom/extensions/cplot.asm) rather than rom/ext_v2_shapes_
; module.asm's own sysvars.inc-resident GFX_CIRCLE_* cells — this
; package's state has no reason to outlive one call or be visible
; outside this package's own RAM window, so it costs nothing from the
; permanent kernel RAM budget.
;
; Deliberately ORG/SAVEBIN-agnostic (no ORG, no DEVICE, no SAVEBIN of
; its own) — same reusable shape rom/ext_mode_module.asm/rom/ext_sprite_
; module.asm already established, so this file can be INCLUDEd both by
; its own real package driver (rom/v2_package_graphics.asm, which
; supplies the fixed EXTENSION_MODULE_BASE ORG + SAVEBIN) and, address-
; agnostically, by a future test harness. rom/ext_v2_shapes_module.asm's
; own self-contained ORG+SAVEBIN shape was NOT followed here for exactly
; this reason.
GRAPHICS_INSTALL:
    ld hl,GRAPHICS_CPLOT_NAME
    ld de,GRAPHICS_CPLOT_EXEC
    ld b,2
    ld c,0
    call EXT2_REGISTER
    ret c
    ld hl,GRAPHICS_BLOCK_NAME
    ld de,GRAPHICS_BLOCK_EXEC
    ld b,4
    ld c,0
    call EXT2_REGISTER
    ret c
    ld hl,GRAPHICS_FRAME_NAME
    ld de,GRAPHICS_FRAME_EXEC
    ld b,4
    ld c,0
    call EXT2_REGISTER
    ret c
    ld hl,GRAPHICS_INVERT_NAME
    ld de,GRAPHICS_INVERT_EXEC
    ld b,4
    ld c,0
    jp EXT2_REGISTER

GRAPHICS_CPLOT_NAME:  DB "CPLOT",0
GRAPHICS_BLOCK_NAME:  DB "BLOCK",0
GRAPHICS_FRAME_NAME:  DB "FRAME",0
GRAPHICS_INVERT_NAME: DB "INVERT",0

; ---------------------------------------------------------------------
; GRAPHICS_RESOLVE_RECT — shared BLOCK/FRAME/INVERT prologue. In:
; EXT_CALL_ARG0..3 = x0,y0,x1,y1 (16-bit VM values, low byte only ever
; significant — same truncate-to-byte convention OP_PLOT/OP_LINE
; already use, no explicit x clamp needed since any byte 0-255 is
; already in range for this screen's 256-pixel width). Out: GFX_G_XMIN/
; XMAX/YMIN/YMAX (ordered low/high, y clamped 0-191 via the shared VM_
; CLAMP_Y191 same as OP_PLOT/OP_LINE/SHAPES' own CIRCLE already use),
; GFX_G_ATTR/GFX_G_OVER (real current PRINT-attribute/OVER state, same
; VM_COMPUTE_PRINT_ATTR/CURRENT_OVER read every other graphics opcode
; already uses). Destroys: AF, BC, HL.
; ---------------------------------------------------------------------
GRAPHICS_RESOLVE_RECT:
    ld hl,(EXT_CALL_ARG0)
    ld a,l
    ld b,a                   ; B = x0
    ld hl,(EXT_CALL_ARG2)
    ld a,l                   ; A = x1
    cp b
    jr nc,.x_ordered
    ld (GFX_G_XMIN),a
    ld a,b
    ld (GFX_G_XMAX),a
    jr .x_done
.x_ordered:
    ld (GFX_G_XMAX),a
    ld a,b
    ld (GFX_G_XMIN),a
.x_done:
    ld hl,(EXT_CALL_ARG1)
    ld a,l
    call VM_CLAMP_Y191
    ld b,a                    ; B = y0 (clamped)
    ld hl,(EXT_CALL_ARG3)
    ld a,l
    call VM_CLAMP_Y191         ; A = y1 (clamped)
    cp b
    jr nc,.y_ordered
    ld (GFX_G_YMIN),a
    ld a,b
    ld (GFX_G_YMAX),a
    jr .y_done
.y_ordered:
    ld (GFX_G_YMAX),a
    ld a,b
    ld (GFX_G_YMIN),a
.y_done:
    call VM_COMPUTE_PRINT_ATTR
    ld (GFX_G_ATTR),a
    ld a,(CURRENT_OVER)
    ld (GFX_G_OVER),a
    ret

; ---------------------------------------------------------------------
; GRAPHICS_FILL_RECT — shared BLOCK/INVERT body: writes every pixel in
; [GFX_G_XMIN..GFX_G_XMAX] x [GFX_G_YMIN..GFX_G_YMAX] using GFX_G_ATTR/
; GFX_G_OVER (INVERT sets GFX_G_OVER=1 itself before calling this, to
; force the XOR semantics its own real BASIC OVER state never controls
; — same real-ROM-derived distinction rom/extensions/invert.asm's own
; header already documents). Destroys: AF, BC, DE.
; ---------------------------------------------------------------------
GRAPHICS_FILL_RECT:
    ld a,(GFX_G_YMIN)
    ld (GFX_G_Y),a
.row:
    ld a,(GFX_G_XMIN)
    ld (GFX_G_X),a
.pixel:
    ld a,(GFX_G_X)
    ld b,a
    ld a,(GFX_G_Y)
    ld c,a
    ld a,(GFX_G_OVER)
    ld d,a
    ld a,(GFX_G_ATTR)
    call GFX_WRITE_PIXEL
    ld a,(GFX_G_X)
    ld b,a
    ld a,(GFX_G_XMAX)
    cp b
    jr z,.row_done
    ld a,b
    inc a
    ld (GFX_G_X),a
    jr .pixel
.row_done:
    ld a,(GFX_G_Y)
    ld b,a
    ld a,(GFX_G_YMAX)
    cp b
    jr z,.done
    ld a,b
    inc a
    ld (GFX_G_Y),a
    jr .row
.done:
    ret

; BLOCK x0,y0,x1,y1 -- filled rectangle, real CURRENT_OVER.
GRAPHICS_BLOCK_EXEC:
    call GRAPHICS_RESOLVE_RECT
    jp GRAPHICS_FILL_RECT

; INVERT x0,y0,x1,y1 -- self-inverting XOR rectangle, always OVER-style
; write regardless of the caller's own real CURRENT_OVER state.
GRAPHICS_INVERT_EXEC:
    call GRAPHICS_RESOLVE_RECT
    ld a,1
    ld (GFX_G_OVER),a
    jp GRAPHICS_FILL_RECT

; FRAME x0,y0,x1,y1 -- outline only. Corners emitted exactly once (top/
; bottom rows walk the full x range; the left/right columns then walk
; ONLY the strictly-interior y range) so OVER 1 does not XOR them back
; off, matching rom/extensions/frame.asm's own real algorithm exactly.
GRAPHICS_FRAME_EXEC:
    call GRAPHICS_RESOLVE_RECT
    ld a,(GFX_G_XMIN)
    ld (GFX_G_POS),a
.horizontal:
    ld a,(GFX_G_YMIN)
    call GRAPHICS_PLOT_AT_POS_Y
    ld a,(GFX_G_YMAX)
    ld b,a
    ld a,(GFX_G_YMIN)
    cp b
    jr z,.horizontal_advance
    ld a,b
    call GRAPHICS_PLOT_AT_POS_Y
.horizontal_advance:
    ld a,(GFX_G_POS)
    ld b,a
    ld a,(GFX_G_XMAX)
    cp b
    jr z,.vertical_setup
    ld a,b
    inc a
    ld (GFX_G_POS),a
    jr .horizontal
.vertical_setup:
    ld a,(GFX_G_YMIN)
    inc a
    ld (GFX_G_POS),a
.vertical:
    ld a,(GFX_G_YMAX)
    ld b,a
    ld a,(GFX_G_POS)
    cp b
    jr nc,.done
    ld c,a
    ld a,(GFX_G_XMIN)
    call GRAPHICS_PLOT_X_AT_C
    ld a,(GFX_G_XMAX)
    ld b,a
    ld a,(GFX_G_XMIN)
    cp b
    jr z,.vertical_advance
    ld a,(GFX_G_POS)
    ld c,a
    ld a,b
    call GRAPHICS_PLOT_X_AT_C
.vertical_advance:
    ld a,(GFX_G_POS)
    inc a
    ld (GFX_G_POS),a
    jr .vertical
.done:
    ret

; In: A=y, GFX_G_POS=x.
GRAPHICS_PLOT_AT_POS_Y:
    ld c,a
    ld a,(GFX_G_POS)
; In: A=x, C=y.
GRAPHICS_PLOT_X_AT_C:
    ld b,a
    ld a,(GFX_G_OVER)
    ld d,a
    ld a,(GFX_G_ATTR)
    jp GFX_WRITE_PIXEL

; CPLOT x,y -- coarse 64x48-grid block plotter (a V1 convenience
; wrapper over the same pixel-write primitive PLOT uses): clamps to the
; coarse grid, then fills the corresponding 4x4 fine-pixel block.
; Independent of GRAPHICS_RESOLVE_RECT/FILL_RECT (different argument
; shape and coordinate scale — confirmed unrelated to BLOCK/FRAME/
; INVERT's rectangle family, same finding R10.25's own audit already
; made).
GRAPHICS_CPLOT_EXEC:
    ld hl,(EXT_CALL_ARG0)
    ld a,l
    cp 64
    jr c,.x_ok
    ld a,63
.x_ok:
    add a,a
    add a,a
    ld (GFX_G_CPLOT_BASE_X),a
    ld hl,(EXT_CALL_ARG1)
    ld a,l
    cp 48
    jr c,.y_ok
    ld a,47
.y_ok:
    add a,a
    add a,a
    ld (GFX_G_CPLOT_BASE_Y),a
    call VM_COMPUTE_PRINT_ATTR
    ld (GFX_G_ATTR),a
    ld a,(CURRENT_OVER)
    ld (GFX_G_OVER),a
    xor a
    ld (GFX_G_CPLOT_DY),a
.row:
    xor a
    ld (GFX_G_CPLOT_DX),a
.pixel:
    ld a,(GFX_G_CPLOT_BASE_X)
    ld b,a
    ld a,(GFX_G_CPLOT_DX)
    add a,b
    ld b,a
    ld a,(GFX_G_CPLOT_BASE_Y)
    ld c,a
    ld a,(GFX_G_CPLOT_DY)
    add a,c
    ld c,a
    ld a,(GFX_G_OVER)
    ld d,a
    ld a,(GFX_G_ATTR)
    call GFX_WRITE_PIXEL
    ld a,(GFX_G_CPLOT_DX)
    inc a
    ld (GFX_G_CPLOT_DX),a
    cp 4
    jr c,.pixel
    ld a,(GFX_G_CPLOT_DY)
    inc a
    ld (GFX_G_CPLOT_DY),a
    cp 4
    jr c,.row
    ret

GFX_G_XMIN: DB 0
GFX_G_XMAX: DB 0
GFX_G_YMIN: DB 0
GFX_G_YMAX: DB 0
GFX_G_X:    DB 0
GFX_G_Y:    DB 0
GFX_G_POS:  DB 0
GFX_G_ATTR: DB 0
GFX_G_OVER: DB 0
GFX_G_CPLOT_BASE_X: DB 0
GFX_G_CPLOT_BASE_Y: DB 0
GFX_G_CPLOT_DX:     DB 0
GFX_G_CPLOT_DY:     DB 0
