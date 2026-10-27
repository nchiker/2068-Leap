; 5.4 (docs/V2_LEAPC_BACKPORT_PLAN.md): the compiler's combined-opcode peepholes, in the EXROM.
; The compiler is HOME code; it reaches these through the fixed slots V2_EXROM_FUSE_*_ADDR
; (include/v2_ktab.inc), which it may call directly because every compile runs under the shell,
; with the EXROM paged in (as the VM and the compile-time number parser call the calculator's slots).
; Production only: the test-only decompiler reads the unfused forms, so the standalone images
; compile as before. Each slot's V2_VERIFY_KTAB destroys AF on the way in.

; COMPILE_FUSE_ADD -- HL = where an assignment's expression starts, C = its target v. When the
; expression is exactly LOAD v / PUSH_I8 k / ADD (SUB), or LOAD v / LOAD w / ADD, rewrites it as
; ADD_VAR_I8 v,k (v,-k) or ADD_VAR_VAR v,w, which also store: NC. Otherwise CF (the caller emits
; STORE_VAR). C survives; destroys AF, B, DE, HL.
COMPILE_FUSE_ADD_X:
    ex de,hl                    ; DE = the expression
    ld hl,(EMIT_PTR)
    or a
    sbc hl,de                   ; HL = its length
    ld a,h
    or a
    jr nz,.no
    ld a,l
    cp 5
    jr nz,.no
    ex de,hl                    ; HL -> the expression
    ld a,(hl)
    cp 3                        ; LOAD_VAR v?
    jr nz,.no
    inc hl
    ld a,(hl)
    cp c
    jr nz,.no
    inc hl
    ld b,(hl)                   ; PUSH_I8 (1) or LOAD_VAR (3)
    inc hl
    ld e,(hl)                   ; k or w
    inc hl
    ld a,(hl)                   ; ADD (5) or SUB (7)
    dec b                       ; PUSH_I8?
    jr z,.lit
    dec b
    dec b                       ; LOAD_VAR?
    jr nz,.no
    cp 5                        ; v + w (no v - w)
    jr nz,.no
    ld a,76                     ; ADD_VAR_VAR
    jr .emit
.lit:
    cp 5
    jr z,.i8
    cp 7
    jr nz,.no
    ld a,e
    neg                         ; v - k = v + (-k)
    jp pe,.no                   ; k = -128 has no 8-bit negation
    ld e,a
.i8:
    ld a,75                     ; ADD_VAR_I8
.emit:
    dec hl
    dec hl
    dec hl
    dec hl                      ; -> the expression
    ld (hl),a
    inc hl
    ld (hl),c
    inc hl
    ld (hl),e
    inc hl
    ld (EMIT_PTR),hl
    or a                        ; NC: fused
    ret
.no:
    scf
    ret

; COMPILE_FUSE_CMP -- IF's condition. Out: A = 12 (JMPZ, to emit), or, when the condition ends with
; a relational operator (CMP_END = EMIT_PTR), that opcode turned into CMP_JMPZ (74) and A = its
; mask, emitted in JMPZ's place (the same length). Destroys AF, BC, DE, HL.
COMPILE_FUSE_CMP_X:
    ld hl,(EMIT_PTR)
    ld de,(CMP_END)
    or a
    sbc hl,de
    ld a,12
    ret nz                      ; the condition does not end with a relational operator: JMPZ
    dec de
    ld a,(de)                   ; its opcode
    ld hl,CMP_FUSE_TABLE
    ld bc,6
    cpir
    ld a,74
    ld (de),a                   ; CMP_JMPZ
    ld c,5
    add hl,bc
    ld a,(hl)                   ; the mask
    ret
CMP_FUSE_TABLE:
    db 10, 11, 40, 41, 42, 43   ; CMP_LT, EQ, LE, GT, GE, NE
    db 1, 2, 3, 4, 6, 5         ; their masks (bit 0 a < b, bit 1 a = b, bit 2 a > b)

; COMPILE_FUSE_GOTO -- IF ... THEN GOTO, at the label. When the condition became a CMP_JMPZ, its
; mask is inverted (it now jumps when the comparison is true) and HL = its operand, which takes
; the label: NC. CF: a plain JMPZ (the caller emits JMP label and patches the skip). Destroys AF, HL.
COMPILE_FUSE_GOTO_X:
    ld hl,(IF_SKIP_PATCH_TMP)
    dec hl
    ld a,(hl)                   ; JMPZ, or a CMP_JMPZ's mask (1-6)
    cp 12
    scf
    ret z
    xor 7                       ; the other three outcomes; NC
    ld (hl),a
    inc hl
    ret
