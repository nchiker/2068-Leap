; EXROM-resident DIM allocator. Returns an error code in A so the Home
; wrapper can attach Home-resident runtime message pointers after paging out.
; A=0 success, 1 syntax, 2 invalid size, 3 already DIM'd, 4 out of memory.
BASIC_STMT_DIM_EXROM:
    call KTAB_BASIC_SKIP_SPACES
    ld   a, (hl)
    call KTAB_BASIC_VALIDATE_VAR_LETTER
    jp   c, .syntax
    push af
    inc  hl
    xor  a
    ld   (ARRAY_DIM_KIND), a
    ld   a, (hl)
    cp   "$"
    jr   nz, .after_dollar
    ld   a, ARRAY_KIND_STR
    ld   (ARRAY_DIM_KIND), a
    inc  hl
.after_dollar:
    ld   a, (hl)
    cp   "("
    jp   nz, .syntax_pop
    inc  hl
    call KTAB_BASIC_EVAL_EXPR
    jp   c, .syntax_pop
    ld   (ARRAY_DIM_COUNT), de
    call KTAB_BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   ")"
    jp   nz, .syntax_pop
    inc  hl
    call KTAB_BASIC_EXPECT_STATEMENT_END
    jp   c, .syntax_pop
    pop  af
    ld   (CUR_VAR_LETTER), a

    ld   hl, (ARRAY_DIM_COUNT)
    ld   a, h
    or   l
    jp   z, .bad_size
    ld   a, (CUR_VAR_LETTER)
    ld   b, a
    ld   a, (ARRAY_DIM_KIND)
    ld   c, a
    ld   a, b
    push hl                         ; preserve the validated dimension;
                                    ; pool lookup owns all main registers
    call KTAB_BASIC_ARRAY_FIND
    pop  hl                         ; POP preserves lookup's carry result
    jr   nc, .already

    ld   a, (ARRAY_DIM_KIND)
    cp   ARRAY_KIND_STR
    jr   nz, .numeric_size
    ld   a, h
    or   a
    jr   nz, .bad_size
    ld   a, l
    cp   32
    jr   nc, .bad_size              ; max 31 strings (992 data bytes)
    add  hl, hl
    add  hl, hl
    add  hl, hl
    add  hl, hl
    add  hl, hl
    jr   .size_ready
.numeric_size:
    bit  7, h                       ; count*2 would overflow 16 bits
    jr   nz, .out_of_memory
    add  hl, hl
.size_ready:
    ld   (ARRAY_ALLOC_BYTES), hl
    ld   de, 4
    add  hl, de
    ld   de, (ARRAYS_END)
    add  hl, de
    ld   de, (VARS_START)
    or   a
    sbc  hl, de
    jr   c, .fits
    jr   z, .fits
.out_of_memory:
    ld   a, 4
    ret
.fits:
    ld   hl, (ARRAY_ALLOC_BYTES)
    ld   de, 4
    add  hl, de
    ld   de, (ARRAYS_END)
    push de
    add  hl, de
    ld   (ARRAYS_END), hl
    pop  hl
    ld   a, (ARRAY_DIM_KIND)
    ld   (hl), a
    inc  hl
    ld   a, (CUR_VAR_LETTER)
    ld   (hl), a
    inc  hl
    ld   de, (ARRAY_DIM_COUNT)
    ld   (hl), e
    inc  hl
    ld   (hl), d
    inc  hl
    ld   de, (ARRAY_ALLOC_BYTES)
.zero:
    ld   a, d
    or   e
    jr   z, .success
    ld   (hl), 0
    inc  hl
    dec  de
    jr   .zero
.success:
    xor  a
    ret
.syntax_pop:
    pop  af
.syntax:
    ld   a, 1
    ret
.bad_size:
    ld   a, 2
    ret
.already:
    ld   a, 3
    ret
