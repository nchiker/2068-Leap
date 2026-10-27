; ===========================================================================
; rom/exrom_v2_float_fn.asm -- the float built-ins SIN, COS and TAN (5.9,
; docs/V2_LEAPC_BACKPORT_PLAN.md). Production assembles them into the EXROM
; (rom/v2_exrom.asm), reached from HOME's BUILTIN_FN_JUMP_TABLE through the
; fixed slots V2_EXROM_FN_*_ADDR (include/v2_ktab.inc): they run only from
; OP_CALL_FN, which the VM dispatches with the EXROM paged in (the same
; condition as the calculator they call); the compiler never calls them. The
; standalone test images, one flat bank, include this file from
; rom/exrom_v2_vm_core.asm instead. From the EXROM, the HOME routines and
; cells used here come from build/v2_crossbank.inc (tools/write_v2_crossbank.py).
; ===========================================================================

; SIN_PEEK_POP -- copies the calculator's current top-of-stack (5
; bytes) to (DE), then pops it (CALC_SP -= 1). SIN_PEEK -- the same
; copy, without the pop. CALC_STACK/CALC_SP are plain RAM; the slot's
; address is the calculator's own CALC_SP_TO_NEXT_FREE_PTR after the pop
; (5.9; the two-bank test harness offers that one to HOME too).
; In: DE = destination. Out: (DE) = the top. Destroys: AF, BC, DE, HL.
SIN_PEEK:
        call SIN_PEEK_POP
        ld hl,CALC_SP
        inc (hl)
        ret
SIN_PEEK_POP:
        ld hl,CALC_SP
        dec (hl)
        push de
        call CALC_SP_TO_NEXT_FREE_PTR   ; DE -> the popped slot
        ex de,hl
        pop de
        ld bc,5
        ldir
        ret

; SIN(degrees), COS(degrees). COS(x) = SIN(x + 90): COS enters SIN with a
; shift of 90 (SIN_SHIFT), added after k is reduced mod 360 and reduced again
; (5.10, Q-35: the 90 was added first, in 16 bits, so COS(32687) wrapped and
; COS of a FLOAT above 32677 was error 15).
; The reduction is exact: the integer part k = trunc(x) is reduced in 16 bits
; (mod 360, folded to a reference d in [0,90] by sin(-x) = -sin(x),
; sin(x+180) = -sin(x), sin(180-x) = sin(x)); the fraction f = x - k
; (SIN_POWER, 0 for an INT argument) is negated with the angle (its sign bit)
; and added back: a = d + f, |a| < 91. Signs: FUNC_RESULT_FLOAT_NEGATIVE; a
; reference of exactly 0 has none (no "-0.0000").
; The series (5.10): x = a * pi/180 (one multiply), then
; sin x = x + x^3 (c3 + c5 x^2 + c7 x^4 + c9 x^6 + c11 x^8), the coefficients a
; minimax fit for |x| <= 91 degrees (relative error 4.8e-11, ~0.2 ulp) rounded
; to 5 bytes (SIN_COEFFS; tools/qual/qsinfit.py). Eight multiplies and six
; adds on the calculator stack, no divides (it was 5 terms of the Taylor
; series, a divide each, ending at x^9/9!: up to 3.6e-6 off near 90 degrees).
; Results are within ~2 ulp of the exact values (qfndiff --exact).
SIN_SHIFT:      equ BFN_ABS_IDX_TMP   ; 1 byte: 0 SIN, 90 COS (ABS's scratch; never live together)
BUILTIN_FN_COS:
        ld a,90
        jr BUILTIN_FN_SIN.shift
BUILTIN_FN_SIN:
        xor a
.shift:
        ld (SIN_SHIFT),a
        rst $10                      ; HL = value, A = tag
        cp TAG_FLOAT
        jr nz,.sin_int_arg
        call VM_FLOAT_PUSH_FIRST     ; [x]
        ld hl,CALC_STACK
        ld de,SIN_POWER
        ld bc,5
        ldir                         ; SIN_POWER = x
        ld hl,CALC_STACK
        call FP_TRUNC                ; [k]
        ld b,0
        rst $28
        db $31,$38                   ; [k,k]
        call CALC_FP_TO_INT          ; HL = k, [k]
        jp c,VM_ERR_RANGE            ; |x| >= 32768 degrees: error 15
        push hl
        ld hl,SIN_POWER
        call CALC_PUSH_FP_RAW        ; [k,x]
        ld b,0
        rst $28
        db $01,$03,$38               ; exchange, subtract: [x - k] = [f]
        ld de,SIN_POWER
        call SIN_PEEK_POP            ; SIN_POWER = f
        pop hl
        jr .sin_have_int
.sin_int_arg:
        push hl
        ld hl,SIN_POWER
        call FP_TRUNC_ZERO           ; f = 0
        pop hl
.sin_have_int:
        ; ---- reduce to a reference angle in [0,90], track sign ----
        ld de,360
        call MATH_MOD16              ; HL = k mod 360 (signed, the sign of k)
        ld a,(SIN_SHIFT)
        ld e,a
        ld d,0
        add hl,de                    ; COS: + 90, -269..449
        ld de,360
        call MATH_MOD16
        xor a
        ld (FUNC_RESULT_FLOAT_NEGATIVE),a
        ld a,h
        or a
        jp p,.sin_nonneg
        ld a,1
        ld (FUNC_RESULT_FLOAT_NEGATIVE),a
        ld a,(SIN_POWER+1)
        xor $80
        ld (SIN_POWER+1),a           ; the fraction is negated with the angle
        ld a,h
        cpl
        ld h,a
        ld a,l
        cpl
        ld l,a
        inc hl
.sin_nonneg:
        ; HL = |degrees mod 360| in [0,359]; fold [180,359] down via
        ; sin(x+180) = -sin(x)
        ld a,h
        or a
        jr nz,.sin_ge180
        ld a,l
        cp 180
        jr c,.sin_lt180
.sin_ge180:
        ld de,180
        or a
        sbc hl,de
        ld a,(FUNC_RESULT_FLOAT_NEGATIVE)
        xor 1
        ld (FUNC_RESULT_FLOAT_NEGATIVE),a
.sin_lt180:
        ; HL in [0,179]; fold (90,179] down: reference = x if x<=90
        ; else 180-x
        ld a,l
        cp 91
        jr c,.sin_ref_done
        ld de,180
        ex de,hl
        or a
        sbc hl,de                    ; HL = 180-x (operands swapped
                                     ; by the ex above)
        ld a,(SIN_POWER+1)
        xor $80
        ld (SIN_POWER+1),a           ; 180 - (k + f) = (180 - k) - f
.sin_ref_done:
        ld a,h
        or l
        jr nz,.sin_ref_nonzero
        ld a,(SIN_POWER)
        or a
        jr nz,.sin_ref_nonzero       ; a nonzero fraction keeps its sign
        ld (FUNC_RESULT_FLOAT_NEGATIVE),a
.sin_ref_nonzero:
        xor a
        ld (CALC_SP),a
        call CALC_INT_TO_FP          ; [d]
        ld hl,SIN_POWER
        call CALC_PUSH_FP_RAW        ; [d,f] (f negated by its sign bit; a 0 stays 0)
        call VM_CALC_ADD_STUB        ; [a], degrees
        ld hl,SIN_COEFFS
        call CALC_PUSH_FP_RAW        ; [a,pi/180]; HL -> c3
        push hl
        ld b,0
        rst $28
        db $04,$31,$31,$31,$04,$38   ; multiply, duplicate 3 times, multiply:
                                     ; [x,x,x^2], x in radians
        ld de,SIN_X2
        call SIN_PEEK                ; SIN_X2 = x^2
        ld b,0
        rst $28
        db $04,$38                   ; [x,x^3]
        pop hl
        ld b,5
.sin_coeff:
        push bc
        call CALC_PUSH_FP_RAW        ; HL -> the next one
        pop bc
        djnz .sin_coeff              ; [x,x^3,c3,c5,c7,c9,c11]
        ld b,4
.sin_horner:
        push bc
        ld hl,SIN_X2
        call CALC_PUSH_FP_RAW        ; the 8th slot at most
        ld b,0
        rst $28
        db $04,$0F,$38               ; [..,c,s] -> [..,c + s x^2]
        pop bc
        djnz .sin_horner             ; [x,x^3,P]
        ld b,0
        rst $28
        db $04,$0F,$38               ; [x + x^3 P]. Nothing in the series
                                     ; can overflow (|x| < 1.6)
        ld a,(FUNC_RESULT_FLOAT_NEGATIVE)
        or a
        jr z,.sin_done
        ld hl,CALC_STACK+1           ; [-sin]: the sign bit flipped (the
        ld a,(hl)                    ; result is in the general form and not
        xor $80                      ; 0 here)
        ld (hl),a
.sin_done:
        jp VM_FLOAT_STORE_RESULT

; 5.10: pi/180, then c3 .. c11 (5-byte floats; values to 12 digits).
SIN_COEFFS:
        db $7B,$0E,$FA,$35,$13       ;  1.745329252299e-02 = pi/180
        db $7E,$AA,$AA,$AA,$A5       ; -1.666666663368e-01
        db $7A,$08,$88,$86,$4C       ;  8.333331250469e-03
        db $74,$D0,$0B,$EA,$79       ; -1.984086480320e-04
        db $6E,$38,$B6,$AF,$CD       ;  2.752447426424e-06
        db $67,$CC,$FD,$BB,$92       ; -2.386410992428e-08

; TAN(x) -- R10.7, R10.25 class C. TAN(x) = SIN(x)/COS(x) via the
; existing calculator division primitive, with a divide-by-zero guard
; (COS(x)=0 at x=90+180n) -- the calculator itself already raises
; overflow on divide-by-zero (VM_CALC_DIV_STUB's own callers elsewhere
; in this file rely on the same behavior), so no new error path is
; invented here.
; QUAL (Q-10): TAN(x) = SIN(x)/COS(x). x is first copied into a fresh FLOAT temp T that stays
; referenced at the bottom of the operand stack while COS and SIN run, so neither result can be
; stored into its slot (the old version re-pushed the caller's slot after SIN had freed it, and COS
; then read SIN's result: TAN(45.5) gave 0.7133).
BUILTIN_FN_TAN:
        rst $10
        call VM_FLOAT_PUSH_FIRST
        call VM_FLOAT_STORE_RESULT   ; [T]
        rst $10                      ; A/HL = T
        push af
        push hl
        call VM_PUSH
        pop hl
        pop af
        push af
        push hl
        call VM_PUSH                 ; [T, T]
        call BUILTIN_FN_COS          ; [T, c]
        pop hl
        pop af
        call VM_PUSH                 ; [T, c, T]
        call BUILTIN_FN_SIN          ; [T, c, s]
        call VM_PREPARE_BINARY_OPERANDS   ; A = c, B = s; [T]
        rst $10                      ; drop T
        ld a,(VM_FLOAT_A_TAG)
        ld hl,(VM_FLOAT_A_VAL)
        call VM_FLOAT_TEST_ZERO      ; COS(x) = 0 at x = 90 + 180n
        jp z,VM_ERR_DIVIDE_BY_ZERO
        call VM_CALC_PUSH_AB         ; [c, s]
        ld b,0
        rst $28
        db $01,$05,$38               ; exchange, divide: [s / c]
        jp VM_FLOAT_STORE_RESULT

