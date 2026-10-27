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

; SIN(degrees) -- int-only argument (matching V1's own real SIN
; contract), a genuine 5-term (through x^9/9!) Taylor series in
; radians, real range reduction to a [0,90]-degree reference angle
; first -- same technique AND divisor table as basic.asm's own
; BASIC_SIN_FLOAT (that routine's own header has the full derivation
; of SIN_DIVISOR_TABLE's 6/20/42/72 values from the Taylor series'
; real per-term ratios). Reuses R6's own already-proven VM_CALC_*_STUB/
; CALC_INT_TO_FP/CALC_PUSH_PI/CALC_PUSH_FP_RAW/VM_FLOAT_STORE_RESULT
; infrastructure throughout, plus the REAL SIN_X_RAD/SIN_X2/SIN_POWER/
; FUNC_RESULT_FLOAT_NEGATIVE sysvars V1's own BASIC_SIN_FLOAT already
; owns for the identical purpose (include/sysvars.inc) -- real,
; permanent RAM already budgeted, not new scratch cells.
;
; Sign handling deliberately does NOT match V1's own documented
; simplification (extract the sign before reduction, and never
; reapply it to the final result -- basic.asm's own RAD/DEG header
; explains why V1 accepted that gap). V2 already has real signed-float
; negation (the same "push 0, push value, subtract" technique BUILTIN_
; FN_ABS's own float path already uses) at essentially no extra cost,
; so SIN(-x) correctly equals -SIN(x) here -- a real, deliberate
; improvement over V1, not scope creep (it costs a few extra bytes at
; the very end, not a new architecture), and required for this
; milestone's own SIN(-x)~=-SIN(x) symmetry test to pass at all.
; QUAL (Q-10): SIN/COS/TAN of a FLOAT number of degrees. The integer part k = trunc(x) is reduced
; exactly as before (16-bit, mod 360, folded to [0,90]); the fraction f = x - k (SIN_POWER, a 5-byte
; value; 0 for an INT argument) follows the same folds -- negated whenever the fold negates the
; angle (SIN_FRAC_NEG) -- and is added back before the series: angle = reference +/- f.
SIN_FRAC_NEG:   equ BFN_ABS_IDX_TMP   ; 1 byte (ABS's scratch; never live together)
BUILTIN_FN_SIN:
        rst $10                      ; HL = value, A = tag
        cp TAG_FLOAT
        jr nz,.sin_int_arg
        call VM_FLOAT_PUSH_FIRST     ; [x]
.sin_calc_arg:                       ; CALC_STACK[0] = x (CALC_SP = 1)
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
        jp c,VM_ERR_RANGE           ; |x| >= 32768 degrees: error 15
        push hl
        ld hl,SIN_POWER
        call CALC_PUSH_FP_RAW        ; [k,x]
        ld b,0
        rst $28
        db $01,$03,$38               ; exchange, subtract: [x - k] = [f]
        ld de,SIN_POWER
        call SIN_PEEK_POP            ; SIN_POWER = f
        pop hl
        jr .sin_frac_set
.sin_int_arg:
        push hl
        ld hl,SIN_POWER
        call FP_TRUNC_ZERO           ; f = 0
        pop hl
.sin_frac_set:
        xor a
        ld (SIN_FRAC_NEG),a
.sin_have_int:
        ; ---- reduce to a reference angle in [0,90], track sign ----
        ld de,360
        call MATH_MOD16                ; HL = degrees mod 360 (signed,
                                          ; sign of the dividend)
        xor a
        ld (FUNC_RESULT_FLOAT_NEGATIVE),a
        ld a,h
        or a
        jp p,.sin_nonneg
        ld a,1
        ld (FUNC_RESULT_FLOAT_NEGATIVE),a
        ld (SIN_FRAC_NEG),a          ; QUAL (Q-10): the fraction is negated with the angle
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
        sbc hl,de                       ; HL = 180-x (operands swapped
                                            ; by the ex above)
        ld a,(SIN_FRAC_NEG)
        xor 1
        ld (SIN_FRAC_NEG),a             ; QUAL (Q-10): 180 - (k + f) = (180 - k) - f
.sin_ref_done:
        ; a reference angle of exactly 0 has no sign either way (both
        ; 0 and 180 fold to a 0 reference) -- force the flag off so a
        ; fold that flipped it doesn't produce a cosmetic "-0.0000"
        ld a,h
        or l
        jr nz,.sin_ref_nonzero
        ld a,(SIN_POWER)
        or a
        jr nz,.sin_ref_nonzero        ; QUAL (Q-10): a nonzero fraction keeps its sign
        ld (FUNC_RESULT_FLOAT_NEGATIVE),a
.sin_ref_nonzero:
        ; ---- degrees -> radians: x_rad = degrees * pi / 180 ----
        xor a
        ld (CALC_SP),a
        call CALC_INT_TO_FP           ; push degrees: [d]
        ld hl,SIN_POWER
        call CALC_PUSH_FP_RAW         ; [d,f]
        ld a,(SIN_FRAC_NEG)
        or a
        jr nz,.sin_fsub
        call VM_CALC_ADD_STUB         ; [d + f]
        jr .sin_fdone
.sin_fsub:
        call VM_CALC_SUB_STUB         ; [d - f]
.sin_fdone:
        call CALC_PUSH_PI               ; push pi: [d,pi]
        call VM_CALC_MUL_STUB             ; [d*pi]
        ld hl,180
        call CALC_INT_TO_FP               ; push 180: [d*pi,180]
        call VM_CALC_DIV_STUB               ; [x_rad]
        ; ---- acc = x_rad (term_0); power = x_rad; x2 = x_rad^2 ----
        ld de,SIN_POWER
        call SIN_PEEK                         ; SIN_POWER = x_rad
        ld b,0
        rst $28
        db $31,$31,$04,$38                    ; duplicate twice, multiply:
                                                 ; [acc,x2] (cannot overflow)
        ld de,SIN_X2
        call SIN_PEEK_POP                     ; SIN_X2 = x2; [acc]

        ld hl,SIN_DIVISOR_TABLE
        ld b,4
.sin_term_loop:
        push bc
        push hl                             ; save divisor-table ptr
        ld hl,SIN_POWER
        call CALC_PUSH_FP_RAW                 ; [acc,power]
        ld hl,SIN_X2
        call CALC_PUSH_FP_RAW                  ; [acc,power,x2]
        call VM_CALC_MUL_STUB                    ; [acc,power*x2]
        pop hl                                  ; HL = divisor-table ptr
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        push hl                                  ; save advanced ptr
        ex de,hl                                  ; HL = this term's D_k
        call CALC_INT_TO_FP                        ; push D_k:
                                                       ; [acc,power*x2,D_k]
        call VM_CALC_DIV_STUB                         ; [acc,power]
        ld de,SIN_POWER
        call SIN_PEEK                                    ; SIN_POWER =
                                                             ; new power;
                                                             ; [acc,power]
        pop hl                                              ; advanced
                                                               ; table ptr
        pop bc                                                ; loop
                                                                 ; counter
        push hl
        push bc
        ld a,b
        and 1
        ; B is the DJNZ countdown (4,3,2,1 across passes k=1,2,3,4 --
        ; djnz decrements at the BOTTOM, so pass k sees B's PRE-
        ; decrement value), not k itself: B even (4,2) means k odd
        ; (1,3) -> SUBTRACT; B odd (3,1) means k even (2,4) -> ADD.
        jr z,.sin_term_sub
        call VM_CALC_ADD_STUB
        jr .sin_term_combined
.sin_term_sub:
        call VM_CALC_SUB_STUB
.sin_term_combined:
        pop bc
        pop hl
        djnz .sin_term_loop

        ; stack: [acc] -- the reference angle's own non-negative sine
        ld a,(FUNC_RESULT_FLOAT_NEGATIVE)
        or a
        jr z,.sin_done
        ld hl,CALC_STACK+1                 ; [-acc]: the sign bit flipped, the bits
        ld a,(hl)                          ; 0 - acc gives (acc is in the general form
        xor $80                            ; and not 0 here)
        ld (hl),a
.sin_done:
        jp VM_FLOAT_STORE_RESULT

SIN_DIVISOR_TABLE: dw 6, 20, 42, 72

; COS(x) -- R10.7, R10.25 class C. COS(x) = SIN(x+90); reuses SIN's own
; degree-reduction/Taylor-series body entirely (BUILTIN_FN_SIN.sin_have_
; int, same cross-scope local-label reference this file's own decompiler
; sibling already establishes as a precedent) -- only the +90 shift
; before entry is new. Int-only argument (matching RAD/DEG's own
; contract), but a FLOAT argument is still accepted and truncated first
; (same tolerance SIN itself already extends), matching R10.25's own
; audit note.
BUILTIN_FN_COS:
        rst $10                      ; HL = value, A = tag
        cp TAG_FLOAT
        jr nz,.cos_int
        call VM_FLOAT_PUSH_FIRST     ; QUAL (Q-10): COS(x) = SIN(x + 90) in FLOAT
        ld hl,90
        call CALC_INT_TO_FP
        call VM_CALC_ADD_STUB
        jp BUILTIN_FN_SIN.sin_calc_arg
.cos_int:
        ld de,90
        add hl,de
        jp BUILTIN_FN_SIN.sin_int_arg

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

