; Deterministic unit test for the canonical editor's character operations.
; Green border = insert/backspace/delete and cursor bounds all passed.

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"

    DEVICE NOSLOT64K
    ORG $0000

RST_00:
    di
    jp   COLD_START
    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00
    call MEM_INIT
    call EDITOR_INIT

    ld   a, "A"
    call EDITOR_INSERT_CHAR
    jr   c, .fail
    ld   a, "B"
    call EDITOR_INSERT_CHAR
    jr   c, .fail
    ld   a, "C"
    call EDITOR_INSERT_CHAR
    jr   c, .fail

    ; ABC| -> AB|C -> A|C -> AB|C -> AB|
    ld   a, EDIR_LEFT
    call EDITOR_MOVE_CURSOR
    call EDITOR_BACKSPACE
    ld   a, "B"
    call EDITOR_INSERT_CHAR
    call EDITOR_DELETE_CHAR

    ; RIGHT at the end must clamp; HOME and forward-delete then produce B.
    ld   a, EDIR_RIGHT
    call EDITOR_MOVE_CURSOR
    ld   a, EDIR_HOME
    call EDITOR_MOVE_CURSOR
    call EDITOR_DELETE_CHAR

    ld   hl, (EDIT_BUF_OFFSET)
    ld   a, h
    or   l
    jr   nz, .fail
    ld   hl, EDIT_LINE_BUF
    ld   a, (hl)
    cp   "B"
    jr   nz, .fail
    inc  hl
    ld   a, (hl)
    or   a
    jr   nz, .fail

    ; Reinsert A at the front and verify END lands after "AB".
    ld   a, "A"
    call EDITOR_INSERT_CHAR
    jr   c, .fail
    ld   a, EDIR_END
    call EDITOR_MOVE_CURSOR
    ld   hl, (EDIT_BUF_OFFSET)
    ld   a, h
    or   a
    jr   nz, .fail
    ld   a, l
    cp   2
    jr   nz, .fail
    ld   hl, EDIT_LINE_BUF
    ld   a, (hl)
    cp   "A"
    jr   nz, .fail
    inc  hl
    ld   a, (hl)
    cp   "B"
    jr   nz, .fail
    inc  hl
    ld   a, (hl)
    or   a
    jr   nz, .fail

    ld   a, 4
    out  (PORT_ULA), a
    jr   $

.fail:
    ld   a, 2
    out  (PORT_ULA), a
    jr   $

    INCLUDE "kernel/editor/editor.asm"
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/math/math.asm"

    DS   $4000 - $, $FF
    SAVEBIN "test_editor_ops.bin", $0000, $4000
