; Loadable HIT(slot1,slot2) module for the BASIC extension gateway's
; function slot (grammar=2), added 2026-09-19 (Phase 0 P0.3). Ported
; verbatim from the former EXROM-resident BASIC_SPRITE_HIT (rom/
; exrom_sprite.asm) -- see that file's own removal note for why it
; needed no EXROM/EXT_SERVICE dependency at all to become a standalone
; RAM module: every SPRITE_SLOT_* array it reads, and SPRITE_SLOT_MAX,
; are plain RAM sysvars/constants, not EXROM-resident. The SPRITE
; statement itself (GRAB/SHOW/HIDE/MOVE) stays EXROM-resident this
; milestone -- its own sub-verb grammar doesn't fit either canned
; statement shape (0: expr,expr; 1: LINE-shaped) this ABI offers yet,
; see MILESTONE_01_RESULTS.md for the full writeup.

    IFDEF SPRITE_EXTENSION_CLEAR_TEST_BUILD
        INCLUDE "rom/test_extension_clear_inject.sym"
    ELSE
        IFDEF SPRITE_EXTENSION_TEST_BUILD
            INCLUDE "rom/test_extension_inject.sym"
        ELSE
            INCLUDE "build/test_basic.sym"
        ENDIF
    ENDIF

    ORG EXTENSION_MODULE_BASE
    IFDEF SPRITE_EXTENSION_CLEAR_TEST_BUILD
        OUTPUT "build/extensions/sprite_clear_test.bin"
    ELSE
        IFDEF SPRITE_EXTENSION_TEST_BUILD
            OUTPUT "build/extensions/sprite_test.bin"
        ELSE
            OUTPUT "build/extensions/sprite.bin"
        ENDIF
    ENDIF

SPRITE_EXTENSION_INSTALL:
    ld   a, (EXT_SERVICE_VERSION_ADDR)
    cp   EXT_SERVICE_ABI_VERSION
    jr   nz, .abi_fail
    ld   hl, SPRITE_EXTENSION_NAME
    ld   de, SPRITE_EXTENSION_EXEC
    ld   c, 2                          ; grammar 2 = register a function
                                       ; (always 2-argument -- see
                                       ; BASIC_EXTENSION_REGISTER's own
                                       ; header, basic/basic.asm)
    call EXT_SERVICE_REGISTER
    ld   hl, 0
    ret
.abi_fail:
    scf
    ret

SPRITE_EXTENSION_NAME:
    DB "HIT", 0

; In: BC=slot1, DE=slot2 (BASIC_TRY_EXTENSION_FUNCTION's own 2-arg
; callback convention). Out: DE=1 (collision) or 0 (no collision /
; invalid slot(s) / not both shown), carry always clear (HIT never
; errors -- see this routine's original header, rom/exrom_sprite.asm,
; for why an invalid slot is deliberately treated as "not shown" rather
; than raising).
SPRITE_EXTENSION_EXEC:
    ld   a, b
    or   c                             ; slot1's high byte must be 0 --
                                       ; BC came straight from BASIC_
                                       ; EVAL_EXPR, a full 16-bit value
    jp   nz, .no_hit
    ld   a, c
    cp   SPRITE_SLOT_MAX
    jp   nc, .no_hit
    ld   (SPRITE_EXT_SLOT1), a
    ld   a, d
    or   a
    jp   nz, .no_hit
    ld   a, e
    cp   SPRITE_SLOT_MAX
    jp   nc, .no_hit
    ld   (SPRITE_EXT_SLOT2), a

    ld   a, (SPRITE_EXT_SLOT1)
    ld   hl, SPRITE_SLOT_SHOWN
    call SPRITE_EXT_SLOT_ADDR
    ld   a, (hl)
    or   a
    jp   z, .no_hit
    ld   a, (SPRITE_EXT_SLOT2)
    ld   hl, SPRITE_SLOT_SHOWN
    call SPRITE_EXT_SLOT_ADDR
    ld   a, (hl)
    or   a
    jp   z, .no_hit

    ; standard 4-comparison rectangle-overlap test: row1 < row2+h2 AND
    ; row2 < row1+h1 AND col1 < col2+w2 AND col2 < col1+w1 -- identical
    ; to the original routine's own comment for the full reasoning.
    ld   a, (SPRITE_EXT_SLOT2)
    ld   hl, SPRITE_SLOT_ROW
    call SPRITE_EXT_SLOT_ADDR
    ld   d, (hl)
    ld   a, (SPRITE_EXT_SLOT2)
    ld   hl, SPRITE_SLOT_H
    call SPRITE_EXT_SLOT_ADDR
    ld   a, (hl)
    add  a, d
    ld   d, a
    ld   a, (SPRITE_EXT_SLOT1)
    ld   hl, SPRITE_SLOT_ROW
    call SPRITE_EXT_SLOT_ADDR
    ld   a, (hl)
    cp   d
    jp   nc, .no_hit

    ld   a, (SPRITE_EXT_SLOT1)
    ld   hl, SPRITE_SLOT_H
    call SPRITE_EXT_SLOT_ADDR
    ld   d, (hl)
    ld   a, (SPRITE_EXT_SLOT1)
    ld   hl, SPRITE_SLOT_ROW
    call SPRITE_EXT_SLOT_ADDR
    ld   a, (hl)
    add  a, d
    ld   d, a
    ld   a, (SPRITE_EXT_SLOT2)
    ld   hl, SPRITE_SLOT_ROW
    call SPRITE_EXT_SLOT_ADDR
    ld   a, (hl)
    cp   d
    jp   nc, .no_hit

    ld   a, (SPRITE_EXT_SLOT2)
    ld   hl, SPRITE_SLOT_COL
    call SPRITE_EXT_SLOT_ADDR
    ld   d, (hl)
    ld   a, (SPRITE_EXT_SLOT2)
    ld   hl, SPRITE_SLOT_W
    call SPRITE_EXT_SLOT_ADDR
    ld   a, (hl)
    add  a, d
    ld   d, a
    ld   a, (SPRITE_EXT_SLOT1)
    ld   hl, SPRITE_SLOT_COL
    call SPRITE_EXT_SLOT_ADDR
    ld   a, (hl)
    cp   d
    jp   nc, .no_hit

    ld   a, (SPRITE_EXT_SLOT1)
    ld   hl, SPRITE_SLOT_W
    call SPRITE_EXT_SLOT_ADDR
    ld   d, (hl)
    ld   a, (SPRITE_EXT_SLOT1)
    ld   hl, SPRITE_SLOT_COL
    call SPRITE_EXT_SLOT_ADDR
    ld   a, (hl)
    add  a, d
    ld   d, a
    ld   a, (SPRITE_EXT_SLOT2)
    ld   hl, SPRITE_SLOT_COL
    call SPRITE_EXT_SLOT_ADDR
    ld   a, (hl)
    cp   d
    jp   nc, .no_hit

    ld   de, 1
    or   a
    ret
.no_hit:
    ld   de, 0
    or   a
    ret

; In: A=slot index, HL=array base. Out: HL=base+index. Same trivial
; arithmetic as the original BASIC_SPRITE_SLOT_FLAG_ADDR -- reimplemented
; here rather than called cross-bank, since this module is plain RAM
; with no EXROM dependency (see this file's own header).
SPRITE_EXT_SLOT_ADDR:
    push de
    ld   e, a
    ld   d, 0
    add  hl, de
    pop  de
    ret

SPRITE_EXT_SLOT1: DB 0
SPRITE_EXT_SLOT2: DB 0

SPRITE_EXTENSION_END:
    ASSERT SPRITE_EXTENSION_END <= EXTENSION_MODULE_LIMIT
