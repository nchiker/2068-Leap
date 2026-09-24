; ============================================================================
; rom/ext_mode_module.asm — loadable MODE/ULAPLUS/PALETTE package (post-
; R8.5 Group 6 ROM reconciliation)
;
; MODE/ULAPLUS/PALETTE were originally 3 resident VM opcodes (real cost
; measured across vm_core/compiler/decompiler). Once the complete
; required R8.5 scope (the remaining Group 6 functions + DEF FN) was
; shown to no longer fit alongside them, the product decision was the
; same one already applied to SPRITE: keep resident ROM for general-
; purpose BASIC language capability, make this specialized/optional
; hardware facility loadable instead of deleting it outright.
;
; This is NOT a new module-loading architecture -- it is 3 ordinary
; extensions registered through the EXISTING R7.5 mechanism (kernel/
; extensions/ext_registry.asm's own EXT2_REGISTER/OP_CALL_EXT), the
; exact same mechanism rom/ext_sprite_module.asm already established
; and rom/test_v2_ext_demo.asm's own TRIADD demo originally validated.
; COMPILE_EXT_CALL (compiler) and .op_call_ext (decompiler) are both
; already fully generic -- neither needed a single byte of change for
; this move.
;
; SYNTAX: identical to the removed resident statements -- "MODE m",
; "ULAPLUS u", "PALETTE i,v" -- since COMPILE_EXT_CALL's own grammar
; ("keyword arg,arg,...") already matches what these three statements
; looked like as resident keywords. No syntax change, unlike SPRITE
; (which dropped its own "SPRITE " prefix): these three never had a
; shared prefix keyword to drop.
;
; ERROR REPORTING: OP_CALL_EXT does not check an extension's own return
; status (confirmed by reading its own body) -- these exec routines
; write VM_ERROR_CODE/VM_HALTED directly, same pattern rom/ext_sprite_
; module.asm already established. Error codes below (12-14) match the
; former resident implementation's own numbering, for continuity with
; anyone who saw them before this move.
;
; Reaches kernel/graphics's real GFX_SET_MODE and two real `out (c),a`
; port writes directly -- unchanged from the resident implementation
; (see the removed OP_MODE/OP_ULAPLUS/OP_PALETTE's own former header,
; git history, commit acb549c, for the original reuse-audit reasoning).
;
; Build (standalone, like every other rom/test_v2_*.asm this session):
; this file is included by rom/test_v2_mode_module.asm, which registers
; all 3 extensions, compiles and runs a real MODE/ULAPLUS/PALETTE
; sequence, and checks results the same way the old resident test did.
; ============================================================================

; MODE_RAISE -- input: A = this module's own error code. Sets
; VM_ERROR_CODE/VM_HALTED directly (both plain, public memory cells)
; then returns to OP_CALL_EXT's own caller via a plain ret; VM_RUN.loop
; notices VM_HALTED on its very next iteration and stops, the same real
; halt path VM_ERR_COMMON itself uses. Destroys: AF.
MODE_RAISE:
        ld (VM_ERROR_CODE),a
        ld a,1
        ld (VM_HALTED),a
        ret

; ---------------------------------------------------------------------------
; MODE m — real, raised error (code 12) for an out-of-range value, not
; silently masked, matching V1's own real MSG_INVALID_MODE.
; ---------------------------------------------------------------------------
MODE_MODE_NAME: db "MODE", 0
MODE_MODE_EXEC:
        ld hl,(EXT_CALL_ARG0)
        ld a,h
        or a
        jp nz,.err_mode
        ld a,l
        cp 2
        jp nc,.err_mode
        call GFX_SET_MODE
        ret
.err_mode:
        ld a,12
        jp MODE_RAISE

; ---------------------------------------------------------------------------
; ULAPLUS u — two real `out (c),a` port writes: select the mode group,
; then write the enable/disable value.
; ---------------------------------------------------------------------------
MODE_ULAPLUS_NAME: db "ULAPLUS", 0
MODE_ULAPLUS_EXEC:
        ld hl,(EXT_CALL_ARG0)
        ld a,h
        or a
        jp nz,.err_ulaplus
        ld a,l
        cp 2
        jp nc,.err_ulaplus
        push af
        ld a,ULAPLUS_MODE_GROUP
        ld bc,PORT_ULAPLUS_SELECT
        out (c),a
        pop af
        ld bc,PORT_ULAPLUS_DATA
        out (c),a
        ret
.err_ulaplus:
        ld a,13
        jp MODE_RAISE

; ---------------------------------------------------------------------------
; PALETTE i,v — select palette index i, then write value v.
; ---------------------------------------------------------------------------
MODE_PALETTE_NAME: db "PALETTE", 0
MODE_PALETTE_EXEC:
        ld hl,(EXT_CALL_ARG0)
        ld a,h
        or a
        jp nz,.err_palette
        ld a,l
        cp 64
        jp nc,.err_palette
        ld bc,PORT_ULAPLUS_SELECT
        out (c),a
        ld hl,(EXT_CALL_ARG1)
        ld a,l
        ld bc,PORT_ULAPLUS_DATA
        out (c),a
        ret
.err_palette:
        ld a,14
        jp MODE_RAISE

; ---------------------------------------------------------------------------
; MODE_INSTALL — registers all 3 operations. Call once (from whatever
; real loader eventually brings this module into RAM -- for now, this
; test's own COLD_START calls it directly, matching the sprite module's
; own demo pattern). Out: carry set on failure. Destroys: AF, BC, DE, HL.
; ---------------------------------------------------------------------------
; All 3 operations are fully numeric (argtypes=0 -- C=0 on every call
; below): EXT2_REGISTER's own C=argtypes parameter (printer-package ROM
; reconciliation) generalizes typed arguments for extensions that need
; them (the new printer package's own LPRINT).
MODE_INSTALL:
        ld hl,MODE_MODE_NAME
        ld de,MODE_MODE_EXEC
        ld b,1
        ld c,0
        call EXT2_REGISTER
        ret c
        ld hl,MODE_ULAPLUS_NAME
        ld de,MODE_ULAPLUS_EXEC
        ld b,1
        ld c,0
        call EXT2_REGISTER
        ret c
        ld hl,MODE_PALETTE_NAME
        ld de,MODE_PALETTE_EXEC
        ld b,2
        ld c,0
        jp EXT2_REGISTER
