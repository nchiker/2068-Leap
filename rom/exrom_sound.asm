; ============================================================================
; rom/exrom_sound.asm — SOUND command (AY-3-8912 PSG)
;
; Real TS2068 ROM's own SOUND command, confirmed directly from the ROM
; disassembly (M2127, "SOUND Command Routine"): writes the register
; number to port $F5 (PORT_AY_REG, the PSG's address register) and the
; data byte to port $F6 (PORT_AY_DATA). Register validated to 1-16
; inclusive — the real ROM's own check ("CP $11 / JP NC, REPORT-C" for
; too-high, "DEC A / INC A / JP M, REPORT-C" for zero) — reproduced
; here as a plain 1-16 range test.
;
; Scope note: the real ROM's SOUND accepts a semicolon-chained list of
; register,data pairs on one line ("SOUND 8,15;0,200;..."). Not
; implemented — this project's colon statement-separator already gives
; the same effect (SOUND 8,15:SOUND 0,200), and semicolon isn't
; recognized syntax anywhere else in this dialect yet. See kernel/
; sound/sound.asm's own header for BEEP's parallel scope note.
;
; Why EXROM and not kernel/sound alongside BEEP: this routine's own
; body is tiny (a range check + two OUT instructions), but Home ROM
; budget was already tight by the time this landed (BEEP itself used
; ~100 bytes) — moving the body here costs only the fixed six-byte
; entry stub (rom/exrom_checker.asm's EXROM_ENTRY_SOUND) plus a thin
; Home-side page-in/call/page-out wrapper (basic/basic.asm's
; BASIC_SOUND_EXROM), following the exact migration pattern this
; project used for SAVE/LOAD/HELP/BASIC_FORMAT_STORAGE_STATUS.
; ============================================================================

; ============================================================================
; SOUND_EXROM
; In:  B = register (1-16), C = data (0-255)
; Out: carry set if the register is out of range (nothing written to
;      either port); carry clear on success
; Destroys: AF
; ============================================================================
SOUND_EXROM:
    ld   a, b
    or   a
    jr   z, .bad_register             ; register 0 -> error
    cp   17
    jr   nc, .bad_register             ; register >= 17 -> error
    out  (PORT_AY_REG), a
    ld   a, c
    out  (PORT_AY_DATA), a
    or   a
    ret
.bad_register:
    scf
    ret
