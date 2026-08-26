; Shared decimal/status formatting, migrated from Home for ROM headroom.

DIV10_EXROM:
    ld   de, 0
    ld   b, 16
.loop:
    add  hl, hl
    rl   e
    rl   d
    ld   a, d
    or   a
    jr   nz, .do_sub
    ld   a, e
    cp   10
    jr   c, .no_sub
.do_sub:
    ld   a, e
    sub  10
    ld   e, a
    ld   a, d
    sbc  a, 0
    ld   d, a
    inc  hl
.no_sub:
    djnz .loop
    ret

BASIC_NUM_TO_STRING_EXROM:
    ld   c, 0
    ld   a, d
    bit  7, a
    jr   z, .positive
    ld   a, d
    cpl
    ld   d, a
    ld   a, e
    cpl
    ld   e, a
    inc  de
    ld   c, 1
.positive:
    ex   de, hl
    ld   de, PRINT_BUF + 7
    xor  a
    ld   (de), a
    dec  de
.divide_loop:
    push de
    call DIV10_EXROM
    ld   a, e
    add  a, "0"
    pop  de
    ld   (de), a
    dec  de
    ld   a, h
    or   l
    jr   nz, .divide_loop
    ld   a, c
    or   a
    jr   z, .done_sign
    ld   a, "-"
    ld   (de), a
    dec  de
.done_sign:
    inc  de
    ex   de, hl
    ret

BASIC_FLOAT_TO_STRING_EXROM:
    rst  $28
    DB   $31, $38
    call CALC_FP_TO_INT
    ld   (FLOAT_PRINT_INTPART), hl
    ex   de, hl
    call BASIC_NUM_TO_STRING_EXROM
    push hl
    ld   a, "."
    ld   (PRINT_BUF+7), a
    ld   hl, (FLOAT_PRINT_INTPART)
    call CALC_INT_TO_FP
    rst  $28
    DB   $03, $38
    ld   de, PRINT_BUF + 8
    ld   b, 4
.digit_loop:
    push bc
    push de
    ld   hl, 10
    call CALC_INT_TO_FP
    rst  $28
    DB   $04, $38
    rst  $28
    DB   $31, $38
    call CALC_FP_TO_INT
    pop  de
    pop  bc
    ld   a, l
    add  a, "0"
    ld   (de), a
    inc  de
    push bc
    push de
    call CALC_INT_TO_FP
    rst  $28
    DB   $03, $38
    pop  de
    pop  bc
    djnz .digit_loop
    xor  a
    ld   (de), a
    call CALC_FP_TO_INT
    pop  hl
    ret

BASIC_APPEND_STR_EXROM:
    push hl
    ld   hl, STATUS_BUF + 28
    ld   de, (STATUS_WRITE_PTR)
    or   a
    sbc  hl, de
    jr   c, .no_budget
    ld   a, l
    jr   .have_budget
.no_budget:
    xor  a
.have_budget:
    ld   b, a
    pop  hl
.append_loop:
    ld   a, (hl)
    or   a
    jr   z, .append_done
    ld   a, b
    or   a
    jr   z, .append_done
    ld   a, (hl)
    ld   (de), a
    inc  hl
    inc  de
    dec  b
    jr   .append_loop
.append_done:
    xor  a
    ld   (de), a
    ld   (STATUS_WRITE_PTR), de
    ret
