; VER (owner F22): the ROM's version on the status row at power-on, while the startup chime plays.
; V2_COLD_START sets V2_VER_FLAG to 2; V2_COMMAND_LOOP's one-time head draws the status row before
; STARTUP_CHIME, and V2_DRAW_STATUS shows the version while the flag is nonzero. V2_REDRAW counts the flag
; down: the editor's first redraw (still before any key) leaves 1, the redraw after the first key leaves 0
; and is a full one, so the status row shows LINE n/m again. Keys that do not redraw (LEFT, RIGHT, the
; ignored codes) leave the version up. NEW and returns to the editor do not set the flag.
; Both routines are called from the EXROM shell, with the EXROM paged in.

    INCLUDE "include/v2_version.inc"
V2_VERSION_LEN EQU $ - V2_VERSION_TEXT
    ASSERT V2_VERSION_LEN <= 20

; V2_VER_STATUS -- Out: Z = no version pending; NZ = the version copied into V2_STATUS_BUF (with its 0).
; Destroys: A, BC, DE, HL.
V2_VER_STATUS:
    ld a,(V2_VER_FLAG)
    or a
    ret z
    ld hl,V2_VERSION_TEXT
    ld de,V2_STATUS_BUF
    ld bc,V2_VERSION_LEN
    ldir                          ; (keeps Z clear)
    ret

; V2_VER_SCOPE -- Out: A = V2_REDRAW_SCOPE, or 0 (a full redraw, scope cleared) on the redraw that takes
; the version off the status row. Destroys: HL.
V2_VER_SCOPE:
    ld hl,V2_VER_FLAG
    ld a,(hl)
    or a
    jr z,.scope
    dec (hl)
    jr nz,.scope
    xor a
    ld (V2_REDRAW_SCOPE),a
    ret
.scope:
    ld a,(V2_REDRAW_SCOPE)
    ret
