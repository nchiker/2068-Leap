; ============================================================================
; rom/test_v2_vm_milestone01.asm — Architecture B, Milestone 01 smoke test
;
; Standalone ROM image exercising rom/exrom_v2_vm_core.asm, following this
; project's own established isolated-module-test pattern (see
; rom/test_math.asm, tools/build_smoke_roms.sh) — NOT wired into the
; production BASIC dispatch or the shipping EXROM build.
;
; Three tests, run from COLD_START (both terminate, so both can chain to a
; single PASS/FAIL border verdict):
;   TEST1 — arithmetic: PUSH_I8 5, PUSH_I8 3, ADD, STORE_VAR 0, HALT.
;           Checks VM_ERROR_CODE==0 and symbol 0 == (INT) 8.
;   TEST3 — stack-overflow negative test: an infinite PUSH_I8/JMP loop that
;           must be caught by VM_PUSH's bounds check, not crash. Checks
;           VM_ERROR_CODE==2 (overflow) after VM_RUN returns.
;
; TEST2 (the loop/branch-cost validation) is deliberately NOT chained from
; COLD_START: it is a genuinely unbounded loop by construction (this
; 7-opcode slice has no conditional branch, so nothing inside the bytecode
; itself can end it) — that is the correct shape for the intended
; measurement, not a bug. It is reached separately by an external harness
; setting PC directly to VM_TEST2_ENTRY via `ts2068-debug set-register PC`,
; then running BOUNDED (`--max-instructions`) from outside, exactly per
; ts2068-debug's own designed workflow for this kind of measurement — see
; docs/v2/STATEMENT_COMPILER_SPIKE.md's "GOTO/branch architecture
; verification" for what this test is meant to demonstrate on real hardware
; (a real ZEsarUX TSTATES measurement, not just code inspection).
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_vm_milestone01.sym \
;       rom/test_v2_vm_milestone01.asm
; Run (TEST1/TEST3 chain, PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/test_v2_vm_milestone01_zesarux.bin
;   ts2068-debug run --max-instructions 200000
;   ts2068-debug timex   (border field)
; Run (TEST2 loop/branch timing, separate entry point):
;   ts2068-debug reset
;   ts2068-debug set-register PC <VM_TEST2_ENTRY address, from the .sym file>
;   ts2068-debug set-register SP 0xFF00
;   ts2068-debug run --max-instructions <N>
;   ts2068-debug regs   (TSTATES)
;   ts2068-debug mem <SYMTAB_BASE+3> 3   (counter variable's current value)
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"

    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START
    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00

    ; --- copy the bytecode images from ROM into RAM at VM_CODE_BASE ---
    ld   hl, BYTECODE_IMAGE
    ld   de, VM_CODE_BASE
    ld   bc, BYTECODE_IMAGE_END - BYTECODE_IMAGE
    ldir

    call VM_INIT
    ld   hl, VM_CODE_BASE + TEST1_OFFSET
    ld   (VM_IP), hl
    call VM_RUN
    call CHECK_TEST1
    jp   c, FAIL

    call VM_INIT
    ld   hl, VM_CODE_BASE + TEST3_OFFSET
    ld   (VM_IP), hl
    call VM_RUN
    call CHECK_TEST3
    jp   c, FAIL

    call VM_INIT
    ld   hl, VM_CODE_BASE + TEST4_OFFSET
    ld   (VM_IP), hl
    call VM_RUN
    call CHECK_TEST4
    jp   c, FAIL

    call VM_INIT
    ld   hl, VM_CODE_BASE + TEST5_OFFSET
    ld   (VM_IP), hl
    call VM_RUN
    call CHECK_TEST5
    jp   c, FAIL

    call VM_INIT
    ld   hl, VM_CODE_BASE + TEST6_OFFSET
    ld   (VM_IP), hl
    call VM_RUN
    call CHECK_TEST6
    jp   c, FAIL

PASS:
    ld   a, 4                ; green
    out  (PORT_ULA), a
    jr   $                   ; halt here — deliberate, not a bug

FAIL:
    ld   a, 2                ; red
    out  (PORT_ULA), a
    jr   $

; ============================================================================
; CHECK_TEST1 — arithmetic: symbol 0 must be (INT) 8, VM_ERROR_CODE must be 0.
; Out: carry clear = pass, carry set = fail (same idiom as rom/test_math.asm)
; ============================================================================
CHECK_TEST1:
    ld   a, (VM_ERROR_CODE)
    or   a
    jr   nz, .fail
    ld   hl, SYMTAB_BASE            ; record 0: [tag][value_lo][value_hi]
                                     ; (matches rom/exrom_v2_vm_core.asm's
                                     ; actual OP_STORE_VAR/OP_LOAD_VAR layout
                                     ; -- an earlier version of this check
                                     ; assumed [value_lo][value_hi][tag] and
                                     ; failed a structurally-correct VM
                                     ; result; fixed after a real ZEsarUX
                                     ; run caught the mismatch)
    ld   a, (hl)
    cp   TAG_INT
    jr   nz, .fail
    inc  hl
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ld   hl, 8
    or   a
    sbc  hl, de
    ret  z
.fail:
    scf
    ret

; ============================================================================
; CHECK_TEST3 — stack-overflow negative test: VM_ERROR_CODE must be 2.
; Out: carry clear = pass, carry set = fail
; ============================================================================
CHECK_TEST3:
    ld   a, (VM_ERROR_CODE)
    cp   2
    ret  z
    scf
    ret

; ============================================================================
; CHECK_TEST4 — comparison: symbol 2 must be (INT) 1 (3<5 is true).
; ============================================================================
CHECK_TEST4:
    ld   a, (VM_ERROR_CODE)
    or   a
    jr   nz, .fail
    ld   hl, SYMTAB_BASE + 2*SYM_REC_LEN
    ld   a, (hl)
    cp   TAG_INT
    jr   nz, .fail
    inc  hl
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ld   hl, 1
    or   a
    sbc  hl, de
    ret  z
.fail:
    scf
    ret

; ============================================================================
; CHECK_TEST5 — FOR/NEXT real terminating loop: symbol 4 (SUM, 1+2+3+4+5)
; must be (INT) 15.
; ============================================================================
CHECK_TEST5:
    ld   a, (VM_ERROR_CODE)
    or   a
    jr   nz, .fail
    ld   hl, SYMTAB_BASE + 4*SYM_REC_LEN
    ld   a, (hl)
    cp   TAG_INT
    jr   nz, .fail
    inc  hl
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ld   hl, 15
    or   a
    sbc  hl, de
    ret  z
.fail:
    scf
    ret

; ============================================================================
; CHECK_TEST6 — CALL/RET: symbol 5 (RESULT) must be (INT) 14 (7 doubled via
; a real bytecode procedure call/return).
; ============================================================================
CHECK_TEST6:
    ld   a, (VM_ERROR_CODE)
    or   a
    jr   nz, .fail
    ld   hl, SYMTAB_BASE + 5*SYM_REC_LEN
    ld   a, (hl)
    cp   TAG_INT
    jr   nz, .fail
    inc  hl
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ld   hl, 14
    or   a
    sbc  hl, de
    ret  z
.fail:
    scf
    ret

; ============================================================================
; Bytecode images (ROM-resident template data; copied to VM_CODE_BASE RAM by
; COLD_START before use — RAM is where the VM actually executes from).
; ============================================================================
BYTECODE_IMAGE:
TEST1_OFFSET:       equ $ - BYTECODE_IMAGE
    ; PUSH_I8 5, PUSH_I8 3, ADD, STORE_VAR 0, HALT
    db 1, 5
    db 1, 3
    db 5
    db 4, 0
    db 0
    DS TEST2_OFFSET - ($ - BYTECODE_IMAGE), 0

TEST2_OFFSET:       equ 16
    ; PUSH_I16 0, STORE_VAR 1, [loop-top:] LOAD_VAR 1, PUSH_I8 1, ADD,
    ; STORE_VAR 1, JMP loop-top. An intentionally unbounded loop -- see the
    ; header comment. VM_TEST2_ENTRY is this same address, exported so the
    ; external harness can set PC there directly without chaining through
    ; COLD_START/TEST1/TEST3.
VM_TEST2_ENTRY:      equ VM_CODE_BASE + TEST2_OFFSET
    db 2, 0, 0          ; PUSH_I16 0            (offset 16-18)
    db 4, 1             ; STORE_VAR 1            (offset 19-20)
TEST2_LOOP_TOP:      equ $ - BYTECODE_IMAGE      ; = offset 21 ($0015)
    db 3, 1             ; LOAD_VAR 1             (offset 21-22)
    db 1, 1             ; PUSH_I8 1              (offset 23-24)
    db 5                ; ADD                    (offset 25)
    db 4, 1             ; STORE_VAR 1            (offset 26-27)
    db 6, low(TEST2_LOOP_TOP), high(TEST2_LOOP_TOP)   ; JMP loop-top (28-30)
    DS TEST3_OFFSET - ($ - BYTECODE_IMAGE), 0

TEST3_OFFSET:       equ 64
TEST3_LOOP_TOP:      equ TEST3_OFFSET
    db 1, 7             ; PUSH_I8 7
    db 6, low(TEST3_OFFSET), high(TEST3_OFFSET)   ; JMP back to itself --
                                                    ; pushes forever until
                                                    ; VM_PUSH's real bounds
                                                    ; check fires
    DS TEST4_OFFSET - ($ - BYTECODE_IMAGE), 0

TEST4_OFFSET:       equ 80
    ; PUSH_I8 3, PUSH_I8 5, CMP_LT, STORE_VAR 2, HALT  -- 3<5 -> symbol 2 = 1
    db 1, 3
    db 1, 5
    db 10               ; CMP_LT
    db 4, 2             ; STORE_VAR 2
    db 0                ; HALT
    DS TEST5_OFFSET - ($ - BYTECODE_IMAGE), 0

TEST5_OFFSET:       equ 96
    ; FOR I=1 TO 5 : SUM=SUM+I : NEXT I  (symbol 3=I, symbol 4=SUM)
    db 1, 1             ; PUSH_I8 1              (initial value for I)
    db 1, 5             ; PUSH_I8 5              (limit)
    db 13, 3            ; FOR_INIT 3             (I = 1, remember limit 5)
    db 2, 0, 0          ; PUSH_I16 0
    db 4, 4             ; STORE_VAR 4            (SUM = 0)
TEST5_LOOP_TOP:      equ $ - BYTECODE_IMAGE
    db 3, 4             ; LOAD_VAR 4             (SUM)
    db 3, 3             ; LOAD_VAR 3             (I)
    db 5                ; ADD
    db 4, 4             ; STORE_VAR 4            (SUM = SUM + I)
    db 14, 3, low(TEST5_LOOP_TOP), high(TEST5_LOOP_TOP)   ; FOR_NEXT 3, loop-top
    db 0                ; HALT
    DS TEST6_OFFSET - ($ - BYTECODE_IMAGE), 0

TEST6_OFFSET:       equ 128
    ; PUSH_I8 7, STORE_VAR 6 (ARG=7), CALL DOUBLE_PROC, LOAD_VAR 6,
    ; STORE_VAR 5 (RESULT=ARG), HALT
    db 1, 7             ; PUSH_I8 7
    db 4, 6             ; STORE_VAR 6            (ARG = 7)
    db 15, low(TEST6_PROC), high(TEST6_PROC)  ; CALL DOUBLE_PROC (operand is
                                                ; an absolute bytecode offset
                                                ; from VM_CODE_BASE, same as
                                                ; JMP's operand convention)
    db 3, 6             ; LOAD_VAR 6             (ARG, now doubled)
    db 4, 5             ; STORE_VAR 5            (RESULT = ARG)
    db 0                ; HALT
TEST6_PROC:          equ $ - BYTECODE_IMAGE
    ; DOUBLE_PROC: ARG = ARG + ARG ; RET
    db 3, 6             ; LOAD_VAR 6
    db 3, 6             ; LOAD_VAR 6
    db 5                ; ADD
    db 4, 6             ; STORE_VAR 6            (ARG = ARG*2)
    db 16               ; RET
BYTECODE_IMAGE_END:

    ; Real, already-verified platform primitive reused by
    ; rom/exrom_v2_vm_core.asm's OP_MUL/OP_DIV/OP_CMP_LT/OP_CMP_EQ/
    ; OP_FOR_NEXT (MATH_MULTIPLY16/MATH_DIVIDE16/MATH_COMPARE16) — the
    ; "reuse mature platform components" principle applied for real,
    ; not merely stated.
    INCLUDE "kernel/math/math.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_vm_milestone01.bin", $0000, $4000
