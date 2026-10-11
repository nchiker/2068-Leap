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
    ld   a, (CALC_TRUNC_FLAG)       ; STUDY (D11): the integer part does not fit INT16
    or   a
    jr   nz, FLOAT_BIG_TO_STRING
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

; STUDY (D11): |x| >= 32768 (x >= 0 here; VM_NUM_TO_TEXT strips the sign) is on top of the calculator
; stack.  Integer part = the 32-bit mantissa >> (160 - exponent byte), printed in decimal as "<digits>.0000"
; (the fraction of a float this large is not shown).  Exponent byte > 160 (>= 2^32) saturates the shift
; at 0.  Digits are written right to left ending at PRINT_BUF+11; the string is returned in HL.
FLOAT_BIG_TO_STRING:
    call CALC_SP_TO_TOP_PTR     ; HL -> the 5-byte record
    ld   a, (CALC_SP)
    dec  a
    ld   (CALC_SP), a           ; pop it (the bytes stay where they are)
    ld   c, (hl)                ; C = exponent byte
    inc  hl
    ld   a, (hl)
    or   $80
    ld   d, a
    inc  hl
    ld   e, (hl)
    inc  hl
    ld   a, (hl)
    inc  hl
    ld   l, (hl)
    ld   h, a                   ; DE:HL = mantissa with the implied 1 restored
    ld   a, 160
    sub  c
    jr   nc, .shift
    xor  a
.shift:
    ld   b, a
    inc  b
    jr   .shift_test
.shift_loop:
    srl  d
    rr   e
    rr   h
    rr   l
.shift_test:
    djnz .shift_loop
    ld   ix, PRINT_BUF + 11
.digit:
    ld   b, 32                  ; DE:HL = DE:HL / 10, remainder in A
    xor  a
.bit:
    add  hl, hl
    rl   e
    rl   d
    rla
    cp   10
    jr   c, .no_sub
    sub  10
    inc  l
.no_sub:
    djnz .bit
    add  a, "0"
    ld   (ix+0), a
    dec  ix
    ld   a, d
    or   e
    or   h
    or   l
    jr   nz, .digit
    ld   hl, .suffix
    ld   de, PRINT_BUF + 12
    ld   bc, 6
    ldir
    push ix
    pop  hl
    inc  hl
    ret
.suffix:
    DB   ".0000", 0

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
