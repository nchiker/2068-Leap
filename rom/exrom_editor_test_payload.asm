; Test-only verifier at a stable high EXROM address. Not shipped.
    ASSERT $ <= $DFC0
    ORG $DFC0

TEST_EXROM_VERIFY:
    ld   hl, EDIT_LINE_BUF
    ld   b, 33
.check_loop:
    ld   a, (hl)
    cp   "A"
    jr   nz, .fail
    inc  hl
    djnz .check_loop
    ld   a, (hl)
    or   a
    jr   nz, .fail
    call EDITOR_WRAP_OFFSET_TO_ROWCOL
    ld   a, b
    cp   1
    jr   nz, .fail
    ld   a, c
    cp   1
    jr   nz, .fail
    ld   a, 4
    out  (PORT_ULA), a
    ret
.fail:
    ld   a, 2
    out  (PORT_ULA), a
    ret
