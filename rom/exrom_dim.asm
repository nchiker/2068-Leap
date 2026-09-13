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
    ; Reject count >= 32766, not just count >= 32768 (the old `bit 7,h`
    ; check here). count*2 alone fits in 16 bits for any count < 32768,
    ; but the array header's own +4 (added a few lines below) then
    ; overflows too for count 32766/32767 specifically (32766*2+4 =
    ; 65536, wraps to 0). That wrapped, tiny ARRAY_ALLOC_BYTES value is
    ; what the out-of-memory check below actually tests, so it silently
    ; passes an allocation that's really ~64K — but the zero-init loop
    ; at .zero reloads the REAL, un-wrapped ARRAY_ALLOC_BYTES afterward
    ; and walks that many bytes, corrupting memory across the entire
    ; address space. CONFIRMED real bug, not theoretical: `DIM A(32767)`
    ; typed from ordinary BASIC reaches this exact path — ARRAY_DIM_COUNT
    ; comes straight from KTAB_BASIC_EVAL_EXPR, an ordinary signed 16-bit
    ; expression, ordinary user input. 32765 is the largest count that
    ; doesn't overflow (32765*2+4 = 65534, fits); 32766 is the first that
    ; does (32766*2+4 = 65536 -> 0).
    ld   de, 32766
    or   a
    sbc  hl, de
    jr   nc, .out_of_memory          ; no borrow: count >= 32766, reject
    ld   hl, (ARRAY_DIM_COUNT)        ; reload the real count -- SBC
                                     ; above destroyed HL
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
