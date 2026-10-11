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

    IFDEF EDITOR_TEST_EXROM          ; the legacy EXROM fixture built by `make check` has no room: old small path
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

    ELSE
; RC (D10, D11-DISP): x >= 0 on top of the calculator stack (popped) -> HL = its text in PRINT_BUF:
; every integer digit, '.', four decimals rounded half-up, NUL; the byte before HL is free for '-'.
; Exact for every magnitude (it printed |x| < 32768 with truncated decimals, dropped the fraction of
; larger values and saturated at 2^32): the value is unpacked into a 20-byte fixed-point number
; (FMT_BUF: 4 fraction bytes, 16 integer bytes, little-endian) and converted with integer
; arithmetic only. FMT_BUF is CALC_STACK+20..+39 (the calculator stack holds only x, in slots 0-3).
; Destroys AF, BC, DE, HL; IX and IY are preserved.
FMT_BUF EQU CALC_STACK + 20
BASIC_FLOAT_TO_STRING_EXROM:
    ld   a, (CALC_SP)
    dec  a
    ld   (CALC_SP), a            ; pop x (its bytes stay)
    ld   l, a
    ld   h, 0
    ld   d, h
    ld   e, l
    add  hl, hl
    add  hl, hl
    add  hl, de
    ld   de, CALC_STACK
    add  hl, de                  ; HL -> x
    push hl
    ld   hl, FMT_BUF
    ld   b, 20
.clr:
    ld   (hl), 0
    inc  hl
    djnz .clr
    pop  hl
    ld   a, (hl)                 ; exponent byte
    inc  hl
    or   a
    jr   nz, .general
    inc  hl                      ; the small-integer form: bytes 2-3 are the value
    ld   a, (hl)
    ld   (FMT_BUF+4), a
    inc  hl
    ld   a, (hl)
    ld   (FMT_BUF+5), a
    jr   .round
.general:
    ld   c, a                    ; C = exponent byte
    ld   de, FMT_BUF+3
    ld   a, (hl)
    or   $80                     ; the implicit top bit (x >= 0)
    ld   (de), a
    ld   b, 3
.m:
    dec  de
    inc  hl
    ld   a, (hl)
    ld   (de), a
    djnz .m                      ; FMT_BUF[0..3] = the mantissa: the value 0.m
    ld   a, c
    sub  128                     ; e (value = 0.m * 2^e)
    jr   z, .round
    jr   c, .right
    ld   b, a                    ; shift left e bits (1..127)
.sl:
    ld   hl, FMT_BUF
    ld   c, 20
    or   a
.sl1:
    rl   (hl)
    inc  hl
    dec  c
    jr   nz, .sl1
    djnz .sl
    jr   .round
.right:
    neg                          ; -e
    cp   33
    jr   nc, .round              ; below 2^-32: nothing left in the fraction
    ld   b, a
.sr:
    ld   hl, FMT_BUF+3
    ld   c, 4
    or   a
.sr1:
    rr   (hl)
    dec  hl
    dec  c
    jr   nz, .sr1
    djnz .sr
.round:                          ; + 0.00005 * 2^32 = $000346DC, carried through all 20 bytes
    ld   hl, FMT_BUF
    ld   a, (hl)
    add  a, $DC
    ld   (hl), a
    inc  hl
    ld   a, (hl)
    adc  a, $46
    ld   (hl), a
    inc  hl
    ld   a, (hl)
    adc  a, $03
    ld   (hl), a
    ld   b, 17
.rc:
    inc  hl
    ld   a, (hl)
    adc  a, 0
    ld   (hl), a
    djnz .rc
    ld   de, PRINT_BUF+40
    ld   a, "."
    ld   (de), a
    ld   a, 4                    ; four decimals: fraction * 10, the carry out is the digit
.fd:
    push af
    inc  de
    push de
    ld   hl, FMT_BUF
    ld   bc, $0400               ; B = 4 bytes, C = carry
.fm:
    ld   a, (hl)
    push hl
    ld   l, a
    ld   h, 0
    ld   d, h
    ld   e, l
    add  hl, hl
    add  hl, hl
    add  hl, de
    add  hl, hl                  ; byte * 10
    ld   e, c
    add  hl, de                  ; + carry
    ld   c, h
    ld   a, l
    pop  hl
    ld   (hl), a
    inc  hl
    djnz .fm
    pop  de
    ld   a, c
    add  a, "0"
    ld   (de), a
    pop  af
    dec  a
    jr   nz, .fd
    inc  de
    xor  a
    ld   (de), a                 ; NUL
    ld   de, PRINT_BUF+39        ; integer digits, right to left
.id:
    push de
    ld   hl, FMT_BUF+19
    ld   b, 16
    xor  a                       ; remainder
.ib:
    ld   c, (hl)
    push bc
    ld   b, 8
.ibit:
    sla  c
    rla
    cp   10
    jr   c, .ins
    sub  10
    inc  c
.ins:
    djnz .ibit
    ld   (hl), c
    pop  bc
    dec  hl
    djnz .ib
    pop  de
    add  a, "0"
    ld   (de), a
    ld   hl, FMT_BUF+4
    ld   b, 16
    xor  a
.iz:
    or   (hl)
    inc  hl
    djnz .iz
    jr   z, .idone
    dec  de
    jr   .id
.idone:
    ex   de, hl                  ; HL -> the first digit
    ret
    ENDIF

    IFNDEF V2_PRODUCTION          ; RC: only the V1 rom/exrom_storage.asm calls it
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
    ENDIF
