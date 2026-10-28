; ============================================================================
; rom/v2_package_fptest.asm -- 6.2-6.4: a test package for the float form, FP_OP, VM_RAISE_ERROR and the slot traps.
;
; The float form (EXT_SIG_FLOAT, signature bit 5): the numeric arguments arrive as the addresses
; of 5-byte floats (an INT converted), and a numeric function's value is a float (EXT_CALL_RESULT
; -> its 5 bytes). FP_OP (service 17): float arithmetic on 5-byte values. Checked by
; tools/qual/qpkgfn.py (with rom/v2_package_fntest.asm; the registry's 12 names do not hold both).
;
;   FADD(x, y)           x + y                          FOP_ADD
;   FSUB(x, y)           x - y                          FOP_SUB
;   FDIV(x, y)           x / y                          FOP_DIV (y = 0: runtime error 67)
;   FPOLY(a, b, c, d, e) ((((e*10+d)*10+c)*10+b)*10+a)  five float arguments, FOP_MUL, FOP_INT
;   FTI(x)               x truncated (FOP_TRUNC), back as a float (FOP_INT); package error 15 when
;                        x is outside -32768..32767
;   FSET x               keeps x                        a float-form statement
;   FGET()               the x FSET kept                no arguments, a float value
;   FSGN$(x)             "-" when x < 0, else "+"       a float-form string function
;   TRYREG(n)            EXT2_REGISTER of the float form with a string argument (n = 0) or the
;                        float form alone (n = 1, as ZZ): 1 if refused, 0 if registered
;   RAISE(n)             runtime error n through VM_RAISE_ERROR (service 18, 6.3), which does not
;                        return (error 99 if it did)
;   TRAP(n)              calls the first reserved slot (n = 0) or the last (n = 1): runtime error 9
;                        (6.4; 99 if the slot returned)
; ============================================================================
    INCLUDE "include/hardware.inc"
    INCLUDE "include/v2_package_abi.inc"
    PKG_SVC_LIST
    PKG_CONST_LIST
    PKG_PIN_LIST
    DEVICE NOSLOT64K
    ORG EXTENSION_MODULE_BASE
    ld hl,FQ_EXPORTS
    jp EXT2_EXPORTS

FQ_EXPORTS:
    DB "FADD",0
    DW FQ_FADD
    DB 2, EXT_KIND_FN | EXT_SIG_FLOAT
    DB "FSUB",0
    DW FQ_FSUB
    DB 2, EXT_KIND_FN | EXT_SIG_FLOAT
    DB "FDIV",0
    DW FQ_FDIV
    DB 2, EXT_KIND_FN | EXT_SIG_FLOAT
    DB "FPOLY",0
    DW FQ_FPOLY
    DB 5, EXT_KIND_FN | EXT_SIG_FLOAT
    DB "FTI",0
    DW FQ_FTI
    DB 1, EXT_KIND_FN | EXT_SIG_FLOAT
    DB "FSET",0
    DW FQ_FSET
    DB 1, EXT_KIND_STMT | EXT_SIG_FLOAT
    DB "FGET",0
    DW FQ_FGET
    DB 0, EXT_KIND_FN | EXT_SIG_FLOAT
    DB "FSGN",0
    DW FQ_FSGN
    DB 1, EXT_KIND_STR | EXT_SIG_FLOAT
    DB "TRYREG",0
    DW FQ_TRYREG
    DB 1, EXT_KIND_FN
    DB "RAISE",0
    DW FQ_RAISE
    DB 1, EXT_KIND_FN
    DB "TRAP",0
    DW FQ_TRAP
    DB 1, EXT_KIND_FN
    DB 0

; A = the operation: x (EXT_CALL_ARG0's float) = x op y (EXT_CALL_ARG1's); the value is x
FQ_FOP2:
    ld hl,(EXT_CALL_ARG0)
    ld de,(EXT_CALL_ARG1)
    push hl
    call FP_OP
    pop hl
FQ_RESULT:
    ld (EXT_CALL_RESULT),hl
    ret

FQ_FADD:
    ld a,FOP_ADD
    jr FQ_FOP2
FQ_FSUB:
    ld a,FOP_SUB
    jr FQ_FOP2
FQ_FDIV:
    ld a,FOP_DIV
    jr FQ_FOP2

FQ_FPOLY:                   ; FQ_ACC = e; then FQ_ACC = FQ_ACC*10 + the next, d down to a
    ld hl,FQ_TEN
    ld de,10
    ld a,FOP_INT
    call FP_OP
    ld hl,(EXT_CALL_ARG4)
    ld de,FQ_ACC
    ld bc,5
    ldir
    ld hl,EXT_CALL_ARG3
    ld b,4
.next:
    push bc
    push hl
    ld hl,FQ_ACC
    ld de,FQ_TEN
    ld a,FOP_MUL
    call FP_OP
    pop hl                  ; -> the next argument's cell (ARG3 down to ARG0)
    ld e,(hl)
    inc hl
    ld d,(hl)
    dec hl
    dec hl
    dec hl
    push hl
    ld hl,FQ_ACC
    ld a,FOP_ADD
    call FP_OP
    pop hl
    pop bc
    djnz .next
    ld hl,FQ_ACC
    jr FQ_RESULT

FQ_FTI:
    ld hl,(EXT_CALL_ARG0)
    ld a,FOP_TRUNC
    call FP_OP              ; HL, CF = outside 16 bits
    jr nc,.ok
    ld a,15
    ld (VM_ERROR_CODE),a
    ld a,1
    ld (VM_HALTED),a
.ok:
    ex de,hl
    ld hl,FQ_ACC
    ld a,FOP_INT
    call FP_OP
    ld hl,FQ_ACC
    jr FQ_RESULT

FQ_FSET:
    ld hl,(EXT_CALL_ARG0)
    ld de,FQ_KEPT
    ld bc,5
    ldir
    ret

FQ_FGET:
    ld hl,FQ_KEPT
    jp FQ_RESULT

FQ_FSGN:
    ld hl,(EXT_CALL_ARG0)
    inc hl
    ld a,(hl)               ; the sign: bit 7 of byte 1 in both forms
    rla
    ld a,'+'
    jr nc,.put
    ld a,'-'
.put:
    ld hl,FQ_STR
    ld (hl),1
    inc hl
    ld (hl),a
    dec hl
    jp FQ_RESULT

FQ_TRYREG:
    ld a,(EXT_CALL_ARG0)
    or a
    ld c,EXT_KIND_FN | EXT_SIG_FLOAT | %00001
    jr z,.try
    ld c,EXT_KIND_FN | EXT_SIG_FLOAT
.try:
    ld hl,FQ_ZZ
    ld de,FQ_FGET
    ld b,0
    call EXT2_REGISTER
    ld hl,0
    jr nc,FQ_INT
    inc hl
FQ_INT:
    jp FQ_RESULT

FQ_TRAP:
    ld a,(EXT_CALL_ARG0)
    or a
    jr nz,.last
    call PKG_SVC_ENTRIES + 3*PKG_SVC_COUNT
    jr FQ_RETURNED
.last:
    call PKG_SVC_CODE - 3
    jr FQ_RETURNED

FQ_RAISE:
    ld a,(EXT_CALL_ARG0)
    call VM_RAISE_ERROR
FQ_RETURNED:
    ld a,99
    ld (VM_ERROR_CODE),a
    ld a,1
    ld (VM_HALTED),a
    ret

FQ_ZZ:      DB "ZZ",0
FQ_TEN:     DS 5
FQ_ACC:     DS 5
FQ_KEPT:    DS 5
FQ_STR:     DS 2

V2_PACKAGE_FPTEST_END:
    ASSERT $ <= EXTENSION_MODULE_LIMIT
    SAVEBIN "build/v2_package_fptest.bin", EXTENSION_MODULE_BASE, V2_PACKAGE_FPTEST_END-EXTENSION_MODULE_BASE
