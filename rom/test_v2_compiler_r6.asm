; ============================================================================
; rom/test_v2_compiler_r6.asm — Architecture B, R6 smoke test
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's R6 additions
; (decimal-literal lexing, TOK_FLOAT_NUMBER) together with rom/
; exrom_v2_vm_core.asm's new R6 opcode (OP_PUSH_FLOAT_LIT) and R6-modified
; opcodes (OP_ADD/OP_SUB/OP_MUL int/float promotion, OP_DIV's "stay float
; if inexact" behavior, OP_STORE_VAR's dedicated-per-variable FLOATTAB
; slot) — the real, unmodified production calculator (rom/exrom_calc.asm)
; does all the actual arithmetic, per NUMERIC_DESIGN.md's reuse decision.
; NOT wired into the production BASIC dispatch or the shipping EXROM
; build.
;
; Source program compiled and executed:
;
;   X=10.5
;   A=3
;   Y=A+0.5
;   Z=5/2
;   W=6/2
;   V=A-0.5
;   Q=8.0
;   U=Q/2
;   T=X*2
;
; Exercises: a plain decimal literal (X=10.5), int/float promotion at "+"
; (Y=A+0.5, A is INT), "/" staying float when the division is inexact
; (Z=5/2 => 2.5, not 2), and "/" staying INT (fast path, no calculator
; involvement) when the division IS exact (W=6/2 => 3, tag TAG_INT) —
; together, one program that exercises every R6 mechanism, not just each
; in isolation. V/Q/U/T were added during this milestone's own
; retrospective register-clobber audit (docs/
; ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's R6 section) specifically to
; cover three paths X/Y/Z/W never touched: OP_SUB's float_path (V=A-0.5,
; int-float), OP_MUL's float_path (T=X*2, float-int), and OP_DIV's OTHER
; float_path — the one taken when the DIVIDEND is already FLOAT-tagged
; rather than just the divisor (U=Q/2, Q itself float).
;
; Hand-computed expected results (symbol order = first appearance):
;   X (index 0) = 10.5  (FLOAT)
;   A (index 1) = 3      (INT)
;   Y (index 2) = 3.5    (FLOAT — int A promoted, added to float 0.5)
;   Z (index 3) = 2.5    (FLOAT — 5/2 is inexact, calculator fallback)
;   W (index 4) = 3      (INT  — 6/2 is exact, fast native-int path,
;         no calculator/FLOATTAB involvement at all)
;   V (index 5) = 2.5    (FLOAT — OP_SUB float_path, int A minus float 0.5)
;   Q (index 6) = 8.0    (FLOAT — plain decimal literal, whole-valued but
;         still FLOAT-tagged because of the "8.0" syntax, not its value)
;   U (index 7) = 4.0    (FLOAT — OP_DIV float_path with dividend Q
;         already FLOAT-tagged, divisor a plain int)
;   T (index 8) = 21.0   (FLOAT — OP_MUL float_path, float X times int 2)
;
; CHECK_RESULT verifies floats WITHOUT ever hand-decoding the calculator's
; internal 5-byte float format: it copies the variable's own FLOATTAB
; record onto the real CALC_STACK, multiplies by the real int 2 via the
; real calculator (RST $28, literal MUL), converts back to int via
; CALC_FP_TO_INT, and compares the truncated result against
; expected*2 — exact for every value in this test (10.5*2=21, 3.5*2=7,
; 2.5*2=5), so truncation never masks a real mismatch here.
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_compiler_r6.sym \
;       rom/test_v2_compiler_r6.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_compiler_r6_zesarux.bin
;   ts2068-debug run --max-instructions 500000
;   ts2068-debug timex   (border field)
; ============================================================================

    INCLUDE "include/hardware.inc"
    DEFINE V2_COMPACT_SYSVARS   ; R10.7 P5: drop V1-only sysvars (see include/sysvars.inc)
    INCLUDE "include/sysvars.inc"
    INCLUDE "rom/test_v2_symmacros.inc"

    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START
    DS   $0028 - $, $FF
    ; RST $28 -- the real calculator's real entry vector, per rom/
    ; exrom_calc.asm's own documented "ENTRY CONTRACT" header: a plain
    ; `jp CALC_EXROM_ENTRY` is exactly right here, no paging trampoline
    ; needed, because this whole test image is a single flat bank (no
    ; real HOME/EXROM split) -- see KTAB_CALC_EXIT_TRAMPOLINE below for
    ; the one place that DOES need a stand-in, and why.
    jp   CALC_EXROM_ENTRY
    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00

    call COMPILER_INIT
    ld   hl, SOURCE_TEXT
    ld   (SRC_PTR), hl
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM

    ld   a, (COMPILE_ERROR_CODE)
    or   a
    jp   nz, FAIL

    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN

    call CHECK_RESULT
    jp   c, FAIL

PASS:
    ld   a, 4                ; green
    out  (PORT_ULA), a
    jr   $

FAIL:
    ld   a, 2                ; red
    out  (PORT_ULA), a
    jr   $

; ============================================================================
; CHECK_RESULT — VM_ERROR_CODE must be 0.
;   Numeric symbols (order): 0=X(10.5,FLOAT) 1=A(3,INT) 2=Y(3.5,FLOAT)
;                             3=Z(2.5,FLOAT)  4=W(3,INT)   5=V(2.5,FLOAT)
;                             6=Q(8.0,FLOAT)  7=U(4.0,FLOAT) 8=T(21.0,FLOAT)
;
;   V/Q/U/T (retrospective-audit addition, see docs/
;   ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's R6 section): X/Y/Z/W above
;   only ever exercised OP_ADD's and OP_DIV's fast-path/inexact-fallback
;   float branches. OP_SUB's and OP_MUL's own float_path branches, and
;   OP_DIV's OTHER float_path (the one taken when the DIVIDEND is already
;   FLOAT-tagged, not just the divisor) had never been exercised by any
;   test program before this addition -- exactly the kind of unexercised
;   path the register-clobber bug class has hidden in five separate
;   times already. All three share VM_FLOAT_PUSH_OPERAND (fixed above),
;   so this is confirmation the fix generalizes, not a new fix.
; Out: carry clear = pass, carry set = fail
; ============================================================================
CHECK_RESULT:
    ld   a, (VM_ERROR_CODE)
    or   a
    jr   nz, .fail
    TSYM_ADDR 0*SYM_REC_LEN
    ld   de, 21                ; X = 10.5 -> *2 = 21
    call .check_float
    jr   c, .fail
    TSYM_ADDR 1*SYM_REC_LEN
    ld   de, 3
    call .check_num           ; A
    jr   c, .fail
    TSYM_ADDR 2*SYM_REC_LEN
    ld   de, 7                 ; Y = 3.5 -> *2 = 7
    call .check_float
    jr   c, .fail
    TSYM_ADDR 3*SYM_REC_LEN
    ld   de, 5                 ; Z = 2.5 -> *2 = 5
    call .check_float
    jr   c, .fail
    TSYM_ADDR 4*SYM_REC_LEN
    ld   de, 3
    call .check_num           ; W (exact 6/2 -> stays INT, fast path)
    jr   c, .fail
    TSYM_ADDR 5*SYM_REC_LEN
    ld   de, 5                 ; V = A-0.5 = 2.5 -> *2 = 5 (OP_SUB float_path)
    call .check_float
    jr   c, .fail
    TSYM_ADDR 6*SYM_REC_LEN
    ld   de, 16                ; Q = 8.0 -> *2 = 16 (plain float literal)
    call .check_float
    jr   c, .fail
    TSYM_ADDR 7*SYM_REC_LEN
    ld   de, 8                 ; U = Q/2 = 4.0 -> *2 = 8 (OP_DIV float_path,
                                 ; dividend already FLOAT-tagged)
    call .check_float
    jr   c, .fail
    TSYM_ADDR 8*SYM_REC_LEN
    ld   de, 42                ; T = X*2 = 21.0 -> *2 = 42 (OP_MUL float_path)
    call .check_float
    ret
.fail:
    scf
    ret

; .check_num — input: HL=record address, DE=expected value. Requires
; TAG_INT (a real hardware regression here would mean the fast exact-
; division path, or plain int assignment, wrongly went float).
.check_num:
    ld   a, (hl)
    cp   TAG_INT
    jr   nz, .cn_fail
    inc  hl
    push de
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ex   de, hl
    pop  de
    or   a
    sbc  hl, de
    ret  z
.cn_fail:
    scf
    ret

; .check_float — input: HL=SYMTAB record address, DE=expected value*2.
; Requires TAG_FLOAT, then verifies the ACTUAL stored float content by
; asking the real calculator: copies the FLOATTAB record for this
; variable's own index onto CALC_STACK, multiplies by int 2 via RST $28,
; converts back to int via CALC_FP_TO_INT, and compares against DE. This
; never inspects/decodes the calculator's own float byte format by hand
; -- the real engine does 100% of the arithmetic, exactly as it does in
; the interpreter itself, so this check is real end-to-end verification,
; not a mock.
.check_float:
    ld   a, (hl)
    cp   TAG_FLOAT
    jr   nz, .cf_fail
    inc  hl                    ; HL -> value_lo byte (the FLOATTAB index)
    push de                   ; save expected*2
    xor  a
    ld   (CALC_SP), a         ; clean calculator stack
    ld   a, (hl)               ; A = this variable's FLOATTAB index
    call VM_FLOAT_ADDR         ; HL -> source floattab record
    ld   (VM_FLOAT_B_VAL), hl  ; BUG FOUND (real hardware): park the source
                                 ; address in memory before the next call --
                                 ; CALC_SP_TO_NEXT_FREE_PTR's own header
                                 ; documents "Destroys: AF, BC, DE, HL", so
                                 ; holding the source in HL across it (the
                                 ; first version of this check did) silently
                                 ; copied garbage (in practice, whatever HL
                                 ; happened to become) instead of the real
                                 ; source record -- confirmed via real `mem`
                                 ; reads: CALC_STACK held a DIFFERENT
                                 ; variable's float bytes than the one being
                                 ; checked. Same clobber-across-a-call bug
                                 ; class as OP_STORE_VAR's fix above, found
                                 ; independently in this driver's own code.
    call CALC_SP_TO_NEXT_FREE_PTR  ; DE -> dest = CALC_STACK slot 0
    ld   hl, (VM_FLOAT_B_VAL)  ; recover the real source address
    push de
    ld   bc, FLOAT_REC_LEN
    ldir
    pop  de
    ld   a, (CALC_SP)
    inc  a
    ld   (CALC_SP), a          ; CALC_SP = 1 (the copied float)
    ld   hl, 2
    call CALC_INT_TO_FP         ; push int 2 -> CALC_SP = 2
    call VM_CALC_MUL_STUB        ; result at slot 0, CALC_SP = 1
    call CALC_FP_TO_INT          ; HL = truncated int result, CALC_SP = 0
    pop  de                      ; expected*2
    or   a
    sbc  hl, de
    ret  z
.cf_fail:
    scf
    ret

SOURCE_TEXT:
    db 'X=10.5:A=3:Y=A+0.5:Z=5/2:W=6/2:V=A-0.5:Q=8.0:U=Q/2:T=X*2', 0

    ; KTAB_CALC_EXIT_TRAMPOLINE — the ONE stand-in this spike needs. The
    ; real production build resolves this name through a real jump table
    ; (include/exrom_jumptable.inc) to basic.asm's own CALC_EXIT_
    ; TRAMPOLINE, which pages HOME back in before returning (real
    ; HOME/EXROM bank switching). This flat, single-bank test image has
    ; no banks to switch, so a plain `ret` is the complete, correct
    ; behavior here: CALC_OP_END_CALC (rom/exrom_calc.asm) has ALREADY
    ; pushed the real resume address onto the Z80 stack (CALC_LITERAL_
    ; PTR's own value, i.e. the address right after this test's inline
    ; `rst $28 / DB <literal>,$38` sequences) before jumping here, so
    ; `ret` resumes exactly the right place. Nothing about the
    ; calculator's own arithmetic is stubbed by this — only the one
    ; HOME-side "page back in" step a real paged build would need and a
    ; flat test image does not.
; Test-only stub: rom/exrom_v2_vm_core.asm's own OP_LPRINT_NUM/STR
; reference the real rom/exrom_printer.asm's BASIC_STMT_LPRINT_EXROM
; unconditionally, but pulling in that whole (real-ZX-printer-
; hardware-facing, ~300-line) file pushed this standalone flat 16K
; test image over budget with no LPRINT coverage to show for it (this
; file's own test program never calls LPRINT). A dedicated PRINT/
; LPRINT test (rom/test_v2_print.asm) includes the real file and
; genuinely exercises it; every other test stubs it, same discipline
; as this file's own existing KTAB_CALC_EXIT_TRAMPOLINE stub just below.
BASIC_STMT_LPRINT_EXROM:
    ret

KTAB_CALC_EXIT_TRAMPOLINE:
    ret

    INCLUDE "kernel/math/math.asm"
    INCLUDE "rom/exrom_calc.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/sound/sound.asm"
    INCLUDE "rom/exrom_sound.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/interrupt/interrupt.asm"
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/extensions/ext_registry.asm"
    INCLUDE "rom/exrom_format.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/test_v2_local_dim.inc"   ; R10.9 2C: test-only DIM handlers
    INCLUDE "rom/exrom_v2_compiler.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_compiler_r6.bin", $0000, $4000
