; ============================================================================
; rom/v2_pkg_fp.asm -- 6.2 (package ABI 2.1, service 17): float arithmetic for a package.
;
; PKG_FP_OP -- In: A = the operation (FOP_*, include/v2_ext_kinds.inc), HL -> x, DE -> y: 5-byte
; floats in the calculator's format, anywhere in RAM (the package's memory, or the float form's
; arguments, EXT_SIG_FLOAT).
;   FOP_ADD, FOP_SUB, FOP_MUL, FOP_DIV (0-3): x = x op y. A result beyond the range, or a division by
;       zero, stops the program with runtime error 67, as the same operation in BASIC does (the
;       VM's own calculator stubs; VM_ERR_COMMON unwinds from package code, item 2.3).
;   FOP_INT (4): x = the 16-bit signed integer DE.
;   FOP_TRUNC (5): HL = x truncated toward zero; CF set when it is outside -32768..32767 (HL then
;       32767 or -32768).
; Out: x, or HL; CF clear (FOP_TRUNC: as above). Destroys AF, BC, DE, HL.
;
; For an execute routine only (not the install: an error unwinds to VM_RUN). The package runs
; with the EXROM out: the calculator pages it in itself (RST $28 -> V2_CALC_ENTRY), FOP_TRUNC's
; conversion through BANK_PAGE_EXROM_IN/OUT (depth-counted). It works in calculator slots 5-6
; (PKG_FP_X and the one after it): slots 0-4 hold the float form's arguments for the whole call.
; ============================================================================
PKG_FP_SLOT:    EQU 5
PKG_FP_X:       EQU CALC_STACK + PKG_FP_SLOT*FLOAT_REC_LEN
    ASSERT VM_CALC_SUB_STUB - VM_CALC_ADD_STUB == 7    ; the stubs are 7 bytes apart (op * 7)
    ASSERT VM_CALC_MUL_STUB - VM_CALC_ADD_STUB == 14
    ASSERT VM_CALC_DIV_STUB - VM_CALC_ADD_STUB == 21

PKG_FP_OP:
        cp FOP_INT
        jr z,.from_int
        push hl                 ; x
        push de
        ld de,PKG_FP_X
        ld bc,FLOAT_REC_LEN
        ldir                    ; slot 5 = x (LDIR keeps CF: A > FOP_INT is FOP_TRUNC)
        pop hl                  ; HL -> y
        jr nc,.trunc
        ld c,FLOAT_REC_LEN
        ldir                    ; slot 6 = y; B = 0 (the stubs' literal parameter is theirs)
        ld c,a
        add a,a
        add a,a
        add a,a
        sub c                   ; op * 7
        ld c,a
        ld hl,VM_CALC_ADD_STUB
        add hl,bc
        ld a,PKG_FP_SLOT + 2
        ld (CALC_SP),a
        call VM_CALL_USR_TRAMPOLINE    ; the stub: [x op y] in slot 5, or error 67
        pop de                  ; DE -> x
        ld hl,PKG_FP_X
        ld bc,FLOAT_REC_LEN
        ldir
        ret                     ; (CF clear: the stub's check ended `or a`)
.trunc:
        pop de                  ; (x)
        ld a,PKG_FP_SLOT + 1
        ld (CALC_SP),a
        call BANK_PAGE_EXROM_IN
        call CALC_FP_TO_INT     ; HL, CF
        push af
        call BANK_PAGE_EXROM_OUT    ; (destroys AF only)
        pop af
        ret
.from_int:                      ; the small-integer form: [0][sign][low][high][0]
        ld a,d
        rla
        sbc a,a                 ; $FF negative, 0 positive
        ld (hl),0
        inc hl
        ld (hl),a
        inc hl
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld (hl),0
        or a
        ret
