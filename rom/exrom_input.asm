; ============================================================================
; EXROM INPUT statement
;
; Supports INPUT A and INPUT A$. Numeric input is bounded to INPUT_BUF's
; seven payload bytes (plus terminator), fixing the old unchecked write past
; that buffer. String input stores at most the scalar string capacity of 31
; characters. Unrecognized keys are ignored; ENTER commits the value.
; ============================================================================

BASIC_STMT_INPUT_EXROM:
    call KTAB_BASIC_SKIP_SPACES
    IFNDEF EDITOR_TEST_EXROM
    ld   a, (hl)
    cp   '"'
    jr   nz, .target
    inc  hl
.prompt:
    ld   a, (hl)
    or   a
    jp   z, .prompt_fail
    cp   '"'
    jr   z, .prompt_done
    push hl
    push af
    ld   a, (BASIC_OUTPUT_COL)
    ld   c, a
    ld   a, (BASIC_OUTPUT_ROW)
    ld   b, a
    pop  af
    ld   d, 5
    call KTAB_BASIC_INPUT_SERVICE
    ld   hl, BASIC_OUTPUT_COL
    inc  (hl)
    pop  hl
    inc  hl
    jr   .prompt
.prompt_done:
    inc  hl
    call KTAB_BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   ';'
    jp   nz, .prompt_fail
    inc  hl
    call KTAB_BASIC_SKIP_SPACES
.target:
    ENDIF
    ld   a, (hl)
    call KTAB_BASIC_VALIDATE_VAR_LETTER
    ret  c
    ld   (CUR_VAR_LETTER), a
    inc  hl
    ld   a, (hl)
    cp   "$"
    jr   nz, .numeric_target
    inc  hl
    call KTAB_BASIC_EXPECT_STATEMENT_END
    ret  c
    ld   a, (CUR_VAR_LETTER)
    ld   d, 3
    call KTAB_BASIC_INPUT_SERVICE
    ret  c
    ld   (STR_FUNC_DEST), hl
    xor  a
    ld   (INPUT_BUF), a                 ; character count

.string_read:
    call KTAB_IO_READ_KEY
    cp   KEY_ENTER
    jr   z, .string_done
    cp   $20                            ; accept printable ASCII only
    jr   c, .string_read
    cp   $7F
    jr   nc, .string_read
    push af
    ld   a, (INPUT_BUF)
    cp   31
    jr   nc, .string_full
    ld   c, a
    inc  a
    ld   (INPUT_BUF), a
    ld   hl, (STR_FUNC_DEST)
    inc  hl
    ld   b, 0
    add  hl, bc
    pop  af
    ld   (hl), a
    call .echo_char
    jr   .string_read
.string_full:
    pop  af
    jr   .string_read

.string_done:
    ld   hl, (STR_FUNC_DEST)
    ld   a, (INPUT_BUF)
    ld   (hl), a                       ; scalar strings are length-prefixed
    ld   d, 4
    jp   KTAB_BASIC_INPUT_SERVICE

.numeric_target:
    call KTAB_BASIC_EXPECT_STATEMENT_END
    ret  c
    ld   hl, INPUT_BUF
    ld   b, 7                          ; reserve byte 7 for the terminator
.number_read:
    call KTAB_IO_READ_KEY
    cp   KEY_ENTER
    jr   z, .number_done
    cp   "-"
    jr   z, .number_char
    cp   "0"
    jr   c, .number_read
    cp   "9" + 1
    jr   nc, .number_read
.number_char:
    push af
    ld   a, b
    or   a
    jr   z, .number_full               ; bounded: never overrun INPUT_BUF
    pop  af
    ld   (hl), a
    push hl
    push bc
    push af
    ld   a, 7
    sub  b
    ld   c, a
    IFNDEF EDITOR_TEST_EXROM
    ld   a, (BASIC_OUTPUT_COL)
    add  a, c
    ld   c, a
    ENDIF
    ld   a, (BASIC_OUTPUT_ROW)
    ld   b, a
    pop  af
    ld   d, 5
    call KTAB_BASIC_INPUT_SERVICE
    pop  bc
    pop  hl
    inc  hl
    dec  b
    jr   .number_read
.number_full:
    pop  af
    jr   .number_read

.number_done:
    xor  a
    ld   (hl), a
    ld   hl, INPUT_BUF
    ld   d, 1
    call KTAB_BASIC_INPUT_SERVICE
    jr   c, .advance
    ld   a, (CUR_VAR_LETTER)
    push de
    ld   d, 2
    call KTAB_BASIC_INPUT_SERVICE
    jr   c, .oom
    pop  de
    ld   (hl), e
    inc  hl
    ld   (hl), d
.advance:
    ld   d, 4
    jp   KTAB_BASIC_INPUT_SERVICE
.oom:
    pop  de
    ret

    IFNDEF EDITOR_TEST_EXROM
.prompt_fail:
    scf
    ret
    ENDIF

; A = character, INPUT_BUF = zero-based column/count after increment.
.echo_char:
    push af
    ld   a, (INPUT_BUF)
    dec  a
    ld   c, a
    IFNDEF EDITOR_TEST_EXROM
    ld   a, (BASIC_OUTPUT_COL)
    add  a, c
    ld   c, a
    ENDIF
    ld   a, (BASIC_OUTPUT_ROW)
    ld   b, a
    pop  af
    ld   d, 5
    jp   KTAB_BASIC_INPUT_SERVICE
