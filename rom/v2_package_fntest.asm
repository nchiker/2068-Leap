; ============================================================================
; rom/v2_package_fntest.asm -- 6.1 prototype: a test package for package functions (ABI 2.1).
;
; Registered through its export table (EXT2_EXPORTS, service 16), Leap-C's model: per export the
; name, the entry, the argument count and the signature byte (bits 7-6 the kind, EXT_KIND_*;
; bits 4-0 the argument types, bit n = argument n is a string).  Checked by tools/qual/qpkgfn.py.
;
;   ADD3(a, b, c)        a + b + c                      numeric function, 3 arguments
;   SEVEN()              7                              numeric function, none
;   SLEN(s$)             LEN(s$)                        numeric function, a string argument
;   MIX(a, b, s$, d, e)  a + 2b + 3 LEN(s$) + 4d + 5e   five arguments, the third a string
;   HEX$(n)              n as 4 hex digits              string function
;   REV$(s$)             s$ reversed                    string function, a string argument
;   SETR n               keeps n                        statement
;   GETR()               the n SETR kept                numeric function
;   BAD(n)               n; package error 15 if n <> 0  an error from a function
;   ABS(n)               999 (never bound: the ROM's ABS wins)
; ============================================================================
    INCLUDE "include/hardware.inc"
    INCLUDE "include/v2_package_abi.inc"
    PKG_SVC_LIST
    PKG_CONST_LIST
    PKG_PIN_LIST
    DEVICE NOSLOT64K
    ORG EXTENSION_MODULE_BASE
    ld hl,FT_EXPORTS
    jp EXT2_EXPORTS

FT_EXPORTS:
    DB "ADD3",0
    DW FT_ADD3
    DB 3, EXT_KIND_FN
    DB "SEVEN",0
    DW FT_SEVEN
    DB 0, EXT_KIND_FN
    DB "SLEN",0
    DW FT_SLEN
    DB 1, EXT_KIND_FN | %00001
    DB "MIX",0
    DW FT_MIX
    DB 5, EXT_KIND_FN | %00100
    DB "HEX",0
    DW FT_HEX
    DB 1, EXT_KIND_STR
    DB "REV",0
    DW FT_REV
    DB 1, EXT_KIND_STR | %00001
    DB "SETR",0
    DW FT_SETR
    DB 1, EXT_KIND_STMT
    DB "GETR",0
    DW FT_GETR
    DB 0, EXT_KIND_FN
    DB "BAD",0
    DW FT_BAD
    DB 1, EXT_KIND_FN
    DB "ABS",0
    DW FT_ABS
    DB 1, EXT_KIND_FN
    DB 0

FT_ADD3:
    ld hl,(EXT_CALL_ARG0)
    ld de,(EXT_CALL_ARG1)
    add hl,de
    ld de,(EXT_CALL_ARG2)
    add hl,de
FT_RESULT:
    ld (EXT_CALL_RESULT),hl
    ret

FT_SEVEN:
    ld hl,7
    jr FT_RESULT

FT_ABS:
    ld hl,999
    jr FT_RESULT

FT_GETR:
    ld hl,(FT_KEPT)
    jr FT_RESULT

FT_SETR:
    ld hl,(EXT_CALL_ARG0)
    ld (FT_KEPT),hl
    ret

FT_BAD:
    ld hl,(EXT_CALL_ARG0)
    ld a,h
    or l
    jr z,FT_RESULT
    ld a,15
    ld (VM_ERROR_CODE),a
    ld a,1
    ld (VM_HALTED),a
    jr FT_RESULT

; A = string-table index -> A = its length, HL -> its first character
FT_STR:
    call VM_STR_ADDR
    ld a,(hl)
    inc hl
    ret

FT_SLEN:
    ld a,(EXT_CALL_ARG0)
    call FT_STR
    ld l,a
    ld h,0
    jr FT_RESULT

FT_MIX:
    ld a,(EXT_CALL_ARG2)
    call FT_STR
    ld l,a
    ld h,0
    ld d,h
    ld e,l
    add hl,hl
    add hl,de               ; 3 LEN(s$)
    ld de,(EXT_CALL_ARG0)
    add hl,de
    ld de,(EXT_CALL_ARG1)
    add hl,de
    add hl,de
    ld de,(EXT_CALL_ARG3)
    ld b,4
.d4:
    add hl,de
    djnz .d4
    ld de,(EXT_CALL_ARG4)
    ld b,5
.e5:
    add hl,de
    djnz .e5
    jp FT_RESULT

FT_HEX:
    ld de,FT_BUF+1
    ld a,(EXT_CALL_ARG0+1)
    call .byte
    ld a,(EXT_CALL_ARG0)
    call .byte
    ld a,4
.done:
    ld (FT_BUF),a
    ld hl,FT_BUF
    jp FT_RESULT
.byte:
    push af
    rrca
    rrca
    rrca
    rrca
    call .nib
    pop af
.nib:
    and 15
    add a,'0'
    cp '9'+1
    jr c,.put
    add a,'A'-'9'-1
.put:
    ld (de),a
    inc de
    ret

FT_REV:
    ld a,(EXT_CALL_ARG0)
    call FT_STR
    ld de,FT_BUF+1
    ld b,a
    or a
    jp z,FT_HEX.done
    ld c,a
    push bc
    ld b,0
    add hl,bc               ; HL -> one past the last character
    pop bc
.copy:
    dec hl
    ld a,(hl)
    ld (de),a
    inc de
    djnz .copy
    ld a,c
    jp FT_HEX.done

FT_KEPT:    DW 0
FT_BUF:     DS 32

V2_PACKAGE_FNTEST_END:
    ASSERT $ <= EXTENSION_MODULE_LIMIT
    SAVEBIN "build/v2_package_fntest.bin", EXTENSION_MODULE_BASE, V2_PACKAGE_FNTEST_END-EXTENSION_MODULE_BASE
