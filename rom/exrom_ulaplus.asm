; Minimal ULAplus statement family.
; B=0: ULAPLUS 0|1
; B=1: PALETTE index,value (index 0-63, value 0-255 GGGRRRBB)

BASIC_STMT_ULAPLUS_EXROM:
    ld   a, b
    or   a
    jr   nz, .palette

    call KTAB_BASIC_EVAL_EXPR
    ret  c
    call KTAB_BASIC_EXPECT_STATEMENT_END
    ret  c
    ld   a, d
    or   a
    jr   nz, .range_error
    ld   a, e
    cp   2
    jr   nc, .range_error
    push af
    ld   a, ULAPLUS_MODE_GROUP
    ld   bc, PORT_ULAPLUS_SELECT
    out  (c), a
    pop  af
    ld   bc, PORT_ULAPLUS_DATA
    out  (c), a
    or   a
    ret

.palette:
    call KTAB_BASIC_EVAL_EXPR
    ret  c
    push de
    call KTAB_BASIC_EXPECT_COMMA_EXPR
    jr   c, .palette_parse_error
    call KTAB_BASIC_EXPECT_STATEMENT_END
    jr   c, .palette_parse_error
    pop  hl
    ld   a, h
    or   a
    jr   nz, .range_error
    ld   a, l
    cp   64
    jr   nc, .range_error
    ld   a, d
    or   a
    jr   nz, .range_error
    ld   a, l
    ld   bc, PORT_ULAPLUS_SELECT
    out  (c), a
    ld   a, e
    ld   bc, PORT_ULAPLUS_DATA
    out  (c), a
    or   a
    ret

.palette_parse_error:
    pop  de
.range_error:
    scf
    ret
