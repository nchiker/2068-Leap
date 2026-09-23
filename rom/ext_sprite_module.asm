; ============================================================================
; rom/ext_sprite_module.asm — loadable SPRITE package (post-R8.5 ROM
; reconciliation)
;
; SPRITE GRAB/SHOW/HIDE/MOVE was originally implemented as 4 resident VM
; opcodes (real cost: 1,399 bytes across vm_core/compiler/decompiler,
; measured). Once the complete required R8.5 scope (Group 6's ~24
; functions + DEF FN) was shown to need that headroom, the product
; decision was: keep resident ROM for general-purpose BASIC language
; capability, make sprites loadable instead of deleting the capability
; outright.
;
; This is NOT a new module-loading architecture. It is 4 ordinary
; extensions registered through the EXISTING R7.5 mechanism (kernel/
; extensions/ext_registry.asm's own EXT2_REGISTER/OP_CALL_EXT) -- the
; SAME mechanism rom/test_v2_ext_demo.asm's own TRIADD demo already
; validates. COMPILE_EXT_CALL (compiler) and .op_call_ext (decompiler)
; are BOTH already fully generic (any name, any argcount, resolved live
; from the registry) -- neither needed a single byte of change for this.
; The only resident change anywhere was raising EXT2_REGISTER's own
; argcount cap from 4 to 5 (GRAB needs slot,row,col,w,h) -- a same-size
; instruction swap (`cp 5`->`cp 6`) plus one new EXT_CALL_ARG4 workspace
; cell in a confirmed-free gap, see kernel/extensions/ext_registry.asm's
; own header for the full account.
;
; SYNTAX CHANGE from the old resident implementation: "SPRITE GRAB
; s,r,c,w,h" becomes plain "GRAB s,r,c,w,h" -- the "SPRITE" prefix was
; pure grouping syntax, not real capability; COMPILE_EXT_CALL's own
; grammar is "keyword arg,arg,...", with no sub-keyword nesting, so
; registering GRAB/SHOW/HIDE/MOVE as 4 independent extension names is
; what lets this reuse the existing mechanism with zero new resident
; parser code (per the user's own explicit "prefer fixed, simple
; calling conventions... over arbitrary parser hooks" direction). All
; four keywords, all arguments, and all real semantics (state machine,
; validation, MOVE's own 3-step sequencing) are otherwise IDENTICAL to
; the removed resident implementation -- this file's own 4 exec
; routines below are a direct adaptation of rom/exrom_v2_vm_core.asm's
; former OP_SPRITE_GRAB/SHOW/HIDE/MOVE (see git history, commit
; da546d2), with VM_POP-based argument popping replaced by this
; registry's own EXT_CALL_ARG0-4 memory-based convention.
;
; ERROR REPORTING: OP_CALL_EXT itself does not (yet) check an
; extension's own return status -- confirmed by reading its own body:
; it blindly `call`s the exec routine then falls straight through to
; VM_RUN.loop. Rather than adding new resident dispatch machinery for
; this, these exec routines write VM_ERROR_CODE/VM_HALTED directly --
; both are already plain, public memory cells (same ones VM_ERR_COMMON
; itself writes), not VM-internal secrets a loaded module is barred
; from touching. Error codes below are this MODULE's own numbering
; (15-20, matching the resident implementation's own former numbering
; for continuity with anyone who saw them before removal), not part of
; rom/exrom_v2_vm_core.asm's own documented list.
;
; Reaches kernel/graphics's real GFX_SPRITE_CAPTURE/GFX_SPRITE_DRAW and
; the existing SPRITE_SLOT_*/SPRITE_SLOT_IMG_BUF/BG_BUF sysvar state
; directly -- unchanged from the resident implementation; that state
; was always real sysvar RAM (include/sysvars.inc), never something the
; resident opcodes allocated fresh, so a loaded module reaches the
; exact same permanent state.
;
; Build (standalone, like every other rom/test_v2_*.asm/rom/test_v2_
; ext_demo.asm this session): this file is included by rom/
; test_v2_sprite_module.asm, which registers all 4 extensions, compiles
; and runs a real GRAB/SHOW/MOVE/HIDE sequence, and checks the same
; SPRITE_SLOT_* state the old resident test checked.
; ============================================================================

; ---------------------------------------------------------------------------
; Module-private workspace. Freely chosen -- this file is loaded
; separately from the resident ROM's own equ space, so it doesn't need
; to avoid resident v2 workspace, only real sysvar RAM (checked against
; include/sysvars.inc's own real DEFS chain, same discipline every
; other new table this session used).
; ---------------------------------------------------------------------------
SPR_SLOT:      equ $9800
SPR_ROW:       equ $9801
SPR_COL:       equ $9802
SPR_W:         equ $9803
SPR_H:         equ $9804
SPR_NEW_ROW:   equ $9805
SPR_NEW_COL:   equ $9806
SPR_IMG_ADDR:  equ $9807
SPR_BG_ADDR:   equ $9809

; SPR_COMPUTE_ADDRS -- input: SPR_SLOT. Output: SPR_IMG_ADDR/SPR_BG_ADDR
; = this slot's own real image/background buffer addresses. Destroys:
; AF, DE, HL.
SPR_COMPUTE_ADDRS:
        ld a,(SPR_SLOT)
        ld l,a
        ld h,0
        ld de,SPRITE_SLOT_BYTES
        call MATH_MULTIPLY16
        push hl
        ld de,SPRITE_SLOT_IMG_BUF
        add hl,de
        ld (SPR_IMG_ADDR),hl
        pop hl
        ld de,SPRITE_SLOT_BG_BUF
        add hl,de
        ld (SPR_BG_ADDR),hl
        ret

; SPR_RAISE -- input: A = this module's own error code. Sets
; VM_ERROR_CODE/VM_HALTED directly (both plain, public memory cells --
; see this file's own header) then returns to OP_CALL_EXT's own caller
; via a plain ret; VM_RUN.loop notices VM_HALTED on its very next
; iteration and stops, the same real halt path VM_ERR_COMMON itself
; uses. Destroys: AF.
SPR_RAISE:
        ld (VM_ERROR_CODE),a
        ld a,1
        ld (VM_HALTED),a
        ret

; ---------------------------------------------------------------------------
; GRAB slot,row,col,w,h — capture the screen rectangle into this slot's
; own image buffer. Error codes: 15=slot range, 16=row/col/w/h range,
; 18=already shown, 20=doesn't fit the screen.
; ---------------------------------------------------------------------------
SPR_GRAB_NAME: db "GRAB", 0
SPR_GRAB_EXEC:
        ld hl,(EXT_CALL_ARG0)
        ld a,l
        ld (SPR_SLOT),a
        cp SPRITE_SLOT_MAX
        jp nc,.err_slot
        ld hl,(EXT_CALL_ARG1)
        ld a,l
        ld (SPR_ROW),a
        cp 24
        jp nc,.err_range
        ld hl,(EXT_CALL_ARG2)
        ld a,l
        ld (SPR_COL),a
        cp 32
        jp nc,.err_range
        ld hl,(EXT_CALL_ARG3)
        ld a,l
        ld (SPR_W),a
        or a
        jp z,.err_range
        cp SPRITE_CELL_MAX+1
        jp nc,.err_range
        ld hl,(EXT_CALL_ARG4)
        ld a,l
        ld (SPR_H),a
        or a
        jp z,.err_range
        cp SPRITE_CELL_MAX+1
        jp nc,.err_range
        ld a,(SPR_SLOT)             ; refuse GRAB while shown
        ld hl,SPRITE_SLOT_SHOWN
        ld e,a
        ld d,0
        add hl,de
        ld a,(hl)
        or a
        jp nz,.err_shown
        call SPR_COMPUTE_ADDRS
        ld a,(SPR_ROW)
        ld b,a
        ld a,(SPR_COL)
        ld c,a
        ld a,(SPR_W)
        ld d,a
        ld a,(SPR_H)
        ld e,a
        ld hl,(SPR_IMG_ADDR)
        call GFX_SPRITE_CAPTURE
        jp c,.err_bounds
        ld a,(SPR_SLOT)
        ld hl,SPRITE_SLOT_W
        ld e,a
        ld d,0
        add hl,de
        ld a,(SPR_W)
        ld (hl),a
        ld a,(SPR_SLOT)
        ld hl,SPRITE_SLOT_H
        ld e,a
        add hl,de
        ld a,(SPR_H)
        ld (hl),a
        ld a,(SPR_SLOT)
        ld hl,SPRITE_SLOT_DEFINED
        ld e,a
        add hl,de
        ld a,1
        ld (hl),a
        ret
.err_slot:
        ld a,15
        jp SPR_RAISE
.err_range:
        ld a,16
        jp SPR_RAISE
.err_shown:
        ld a,18
        jp SPR_RAISE
.err_bounds:
        ld a,20
        jp SPR_RAISE

; ---------------------------------------------------------------------------
; SHOW slot,row,col — capture the real background at the new position
; (save-under), then draw the sprite there. Error codes: 15/16/18 as
; above, 17=never GRABbed, 20=doesn't fit.
; ---------------------------------------------------------------------------
SPR_SHOW_NAME: db "SHOW", 0
SPR_SHOW_EXEC:
        ld hl,(EXT_CALL_ARG0)
        ld a,l
        ld (SPR_SLOT),a
        cp SPRITE_SLOT_MAX
        jp nc,.err_slot
        ld hl,(EXT_CALL_ARG1)
        ld a,l
        ld (SPR_ROW),a
        cp 24
        jp nc,.err_range
        ld hl,(EXT_CALL_ARG2)
        ld a,l
        ld (SPR_COL),a
        cp 32
        jp nc,.err_range
        ld a,(SPR_SLOT)
        ld hl,SPRITE_SLOT_DEFINED
        ld e,a
        ld d,0
        add hl,de
        ld a,(hl)
        or a
        jp z,.err_not_defined
        ld a,(SPR_SLOT)
        ld hl,SPRITE_SLOT_SHOWN
        ld e,a
        add hl,de
        ld a,(hl)
        or a
        jp nz,.err_shown
        ld a,(SPR_SLOT)
        ld hl,SPRITE_SLOT_W
        ld e,a
        add hl,de
        ld a,(hl)
        ld (SPR_W),a
        ld a,(SPR_SLOT)
        ld hl,SPRITE_SLOT_H
        ld e,a
        add hl,de
        ld a,(hl)
        ld (SPR_H),a
        call SPR_COMPUTE_ADDRS
        ld a,(SPR_ROW)
        ld b,a
        ld a,(SPR_COL)
        ld c,a
        ld a,(SPR_W)
        ld d,a
        ld a,(SPR_H)
        ld e,a
        ld hl,(SPR_BG_ADDR)
        call GFX_SPRITE_CAPTURE
        jp c,.err_bounds
        ld a,(SPR_ROW)
        ld b,a
        ld a,(SPR_COL)
        ld c,a
        ld a,(SPR_W)
        ld d,a
        ld a,(SPR_H)
        ld e,a
        ld hl,(SPR_IMG_ADDR)
        call GFX_SPRITE_DRAW
        jp c,.err_bounds
        ld a,(SPR_SLOT)
        ld hl,SPRITE_SLOT_SHOWN
        ld e,a
        ld d,0
        add hl,de
        ld a,1
        ld (hl),a
        ld a,(SPR_SLOT)
        ld hl,SPRITE_SLOT_ROW
        ld e,a
        add hl,de
        ld a,(SPR_ROW)
        ld (hl),a
        ld a,(SPR_SLOT)
        ld hl,SPRITE_SLOT_COL
        ld e,a
        add hl,de
        ld a,(SPR_COL)
        ld (hl),a
        ret
.err_slot:
        ld a,15
        jp SPR_RAISE
.err_range:
        ld a,16
        jp SPR_RAISE
.err_not_defined:
        ld a,17
        jp SPR_RAISE
.err_shown:
        ld a,18
        jp SPR_RAISE
.err_bounds:
        ld a,20
        jp SPR_RAISE

; ---------------------------------------------------------------------------
; HIDE slot — restore the saved background at this slot's own recorded
; position. Error codes: 15, 19=not shown, 20=doesn't fit.
; ---------------------------------------------------------------------------
SPR_HIDE_NAME: db "HIDE", 0
SPR_HIDE_EXEC:
        ld hl,(EXT_CALL_ARG0)
        ld a,l
        ld (SPR_SLOT),a
        cp SPRITE_SLOT_MAX
        jp nc,.err_slot
        ld a,(SPR_SLOT)
        ld hl,SPRITE_SLOT_SHOWN
        ld e,a
        ld d,0
        add hl,de
        ld a,(hl)
        or a
        jp z,.err_not_shown
        ld a,(SPR_SLOT)
        ld hl,SPRITE_SLOT_ROW
        ld e,a
        add hl,de
        ld a,(hl)
        ld (SPR_ROW),a
        ld a,(SPR_SLOT)
        ld hl,SPRITE_SLOT_COL
        ld e,a
        add hl,de
        ld a,(hl)
        ld (SPR_COL),a
        ld a,(SPR_SLOT)
        ld hl,SPRITE_SLOT_W
        ld e,a
        add hl,de
        ld a,(hl)
        ld (SPR_W),a
        ld a,(SPR_SLOT)
        ld hl,SPRITE_SLOT_H
        ld e,a
        add hl,de
        ld a,(hl)
        ld (SPR_H),a
        call SPR_COMPUTE_ADDRS
        ld a,(SPR_ROW)
        ld b,a
        ld a,(SPR_COL)
        ld c,a
        ld a,(SPR_W)
        ld d,a
        ld a,(SPR_H)
        ld e,a
        ld hl,(SPR_BG_ADDR)
        call GFX_SPRITE_DRAW
        jp c,.err_bounds
        ld a,(SPR_SLOT)
        ld hl,SPRITE_SLOT_SHOWN
        ld e,a
        ld d,0
        add hl,de
        xor a
        ld (hl),a
        ret
.err_slot:
        ld a,15
        jp SPR_RAISE
.err_not_shown:
        ld a,19
        jp SPR_RAISE
.err_bounds:
        ld a,20
        jp SPR_RAISE

; ---------------------------------------------------------------------------
; MOVE slot,row,col — restore at the OLD position, capture+draw at the
; NEW one. Error codes: 15, 16, 19, 20.
; ---------------------------------------------------------------------------
SPR_MOVE_NAME: db "MOVE", 0
SPR_MOVE_EXEC:
        ld hl,(EXT_CALL_ARG0)
        ld a,l
        ld (SPR_SLOT),a
        cp SPRITE_SLOT_MAX
        jp nc,.err_slot
        ld hl,(EXT_CALL_ARG1)
        ld a,l
        ld (SPR_NEW_ROW),a
        cp 24
        jp nc,.err_range
        ld hl,(EXT_CALL_ARG2)
        ld a,l
        ld (SPR_NEW_COL),a
        cp 32
        jp nc,.err_range
        ld a,(SPR_SLOT)
        ld hl,SPRITE_SLOT_SHOWN
        ld e,a
        ld d,0
        add hl,de
        ld a,(hl)
        or a
        jp z,.err_not_shown
        ld a,(SPR_SLOT)             ; w/h stay constant across the move
        ld hl,SPRITE_SLOT_W
        ld e,a
        add hl,de
        ld a,(hl)
        ld (SPR_W),a
        ld a,(SPR_SLOT)
        ld hl,SPRITE_SLOT_H
        ld e,a
        add hl,de
        ld a,(hl)
        ld (SPR_H),a
        call SPR_COMPUTE_ADDRS
        ld a,(SPR_SLOT)             ; step 1: restore at the OLD position
        ld hl,SPRITE_SLOT_ROW
        ld e,a
        add hl,de
        ld a,(hl)
        ld b,a
        ld a,(SPR_SLOT)
        ld hl,SPRITE_SLOT_COL
        ld e,a
        add hl,de
        ld a,(hl)
        ld c,a
        ld a,(SPR_W)
        ld d,a
        ld a,(SPR_H)
        ld e,a
        ld hl,(SPR_BG_ADDR)
        call GFX_SPRITE_DRAW
        jp c,.err_bounds
        ld a,(SPR_NEW_ROW)          ; step 2: capture the NEW position
        ld b,a
        ld a,(SPR_NEW_COL)
        ld c,a
        ld a,(SPR_W)
        ld d,a
        ld a,(SPR_H)
        ld e,a
        ld hl,(SPR_BG_ADDR)
        call GFX_SPRITE_CAPTURE
        jp c,.err_bounds
        ld a,(SPR_NEW_ROW)          ; step 3: draw at the NEW position
        ld b,a
        ld a,(SPR_NEW_COL)
        ld c,a
        ld a,(SPR_W)
        ld d,a
        ld a,(SPR_H)
        ld e,a
        ld hl,(SPR_IMG_ADDR)
        call GFX_SPRITE_DRAW
        jp c,.err_bounds
        ld a,(SPR_SLOT)              ; step 4: record the new position
        ld hl,SPRITE_SLOT_ROW
        ld e,a
        ld d,0
        add hl,de
        ld a,(SPR_NEW_ROW)
        ld (hl),a
        ld a,(SPR_SLOT)
        ld hl,SPRITE_SLOT_COL
        ld e,a
        add hl,de
        ld a,(SPR_NEW_COL)
        ld (hl),a
        ret
.err_slot:
        ld a,15
        jp SPR_RAISE
.err_range:
        ld a,16
        jp SPR_RAISE
.err_not_shown:
        ld a,19
        jp SPR_RAISE
.err_bounds:
        ld a,20
        jp SPR_RAISE

; ---------------------------------------------------------------------------
; SPR_INSTALL — registers all 4 sprite operations. Call once (from
; whatever real loader eventually brings this module into RAM -- for
; now, this test's own COLD_START calls it directly, matching TRIADD's
; own demo pattern). Out: carry set on failure (any one registration
; failed -- table full, or this module loaded twice without a NEW/
; EXT2_CLEAR_ALL in between). Destroys: AF, BC, DE, HL.
; ---------------------------------------------------------------------------
SPR_INSTALL:
        ld hl,SPR_GRAB_NAME
        ld de,SPR_GRAB_EXEC
        ld b,5
        call EXT2_REGISTER
        ret c
        ld hl,SPR_SHOW_NAME
        ld de,SPR_SHOW_EXEC
        ld b,3
        call EXT2_REGISTER
        ret c
        ld hl,SPR_HIDE_NAME
        ld de,SPR_HIDE_EXEC
        ld b,1
        call EXT2_REGISTER
        ret c
        ld hl,SPR_MOVE_NAME
        ld de,SPR_MOVE_EXEC
        ld b,3
        jp EXT2_REGISTER
