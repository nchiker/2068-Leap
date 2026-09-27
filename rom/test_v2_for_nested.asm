; ============================================================================
; rom/test_v2_for_nested.asm — post-R9 semantic-completion milestone: real
; nested FOR/NEXT (docs/v2/V2_SEMANTIC_CAPABILITY_AUDIT.md S9).
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's new
; CFOR_STACK-based COMPILE_FOR/COMPILE_NEXT/COMPILE_EXIT_FOR and rom/
; exrom_v2_vm_core.asm's new VM_FOR_STACK-based OP_FOR_INIT/OP_FOR_POP.
; NOT wired into the production BASIC dispatch or the shipping EXROM
; build.
;
; Part 1 — real 2-level nesting, arithmetic correctness:
;
;   S=0:FOR I=1 TO 3:FOR J=1 TO 3:S=S+1:NEXT J:NEXT I:
;
; Under the OLD single-scratch-cell design this silently compiled wrong
; bytecode (inner J's own VM_FOR_STEP/LIMIT would overwrite outer I's, so
; I's own NEXT would compare against J's stale limit/step) or ran the
; inner loop against the outer's own corrupted bookkeeping. Expects
; S=9 (3*3) if truly independent.
;
; Part 2 — outer variable survives an inner EXIT FOR and inner loop reuse
; across repeated outer iterations:
;
;   T=0:FOR K=1 TO 3:FOR L=1 TO 10:IF L>2 THEN EXIT FOR ENDIF:T=T+1:
;       NEXT L:T=T+K:NEXT K:
;
; Inner loop runs L=1,2 (T+=1 twice) then EXIT FOR at L=3; T+=K happens
; AFTER the inner loop, using K's own value undisturbed by the inner
; loop's own now-popped frame. Expects T=12 ((1+1)+1 + (1+1)+2 +
; (1+1)+3 = 2+1 + 2+2 + 2+3 = 12).
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_for_nested.sym \
;       rom/test_v2_for_nested.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_for_nested_zesarux.bin
;   ts2068-debug run --max-instructions 3000000
;   ts2068-debug timex   (border field)
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

    call COMPILER_INIT
    ld   hl, SOURCE_TEXT
    ld   (SRC_PTR), hl
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM

    ld   a, (COMPILE_ERROR_CODE)
    or   a
    jp   nz, FAIL

    ld   hl, (EMIT_PTR)
    ld   (DECOMP_END_ADDR), hl

    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN

    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, FAIL

    ; both FOR_STACK depths must be back to 0 once every loop has closed
    ; normally -- if either leaked, a later real program's own FOR_NEST_MAX
    ; check would wrongly refuse further nesting.
    ld   a, (CFOR_STACK_DEPTH)
    or   a
    jp   nz, FAIL
    ld   a, (VM_FOR_STACK_DEPTH)
    or   a
    jp   nz, FAIL

    call CHECK_RESULT
    jp   c, FAIL

    call DECOMPILE_PROGRAM
    ld   a, (DECOMP_ERROR_CODE)
    or   a
    jp   nz, FAIL

    ; ------------------------------------------------------------------
    ; Negative check 1: NEXT variable that doesn't match the innermost
    ; open FOR must now be a real compile-time error (56), not silently
    ; accepted (docs/v2/V2_SEMANTIC_CAPABILITY_AUDIT.md S9's own finding:
    ; "this R3 scope does not verify the name matches the innermost open
    ; FOR"). Fresh compile, same session -- exercises COMPILER_INIT's own
    ; CFOR_STACK_DEPTH reset too.
    ; ------------------------------------------------------------------
    call COMPILER_INIT
    ld   hl, MISMATCH_SOURCE
    ld   (SRC_PTR), hl
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM
    ld   a, (COMPILE_ERROR_CODE)
    cp   56
    jp   nz, FAIL

    ; ------------------------------------------------------------------
    ; Negative check 2: nesting past VM_FOR_NEST_MAX/CFOR_STACK's own
    ; depth (4) must be a real compile-time error (55), not a silent
    ; frame-table overrun.
    ; ------------------------------------------------------------------
    call COMPILER_INIT
    ld   hl, TOODEEP_SOURCE
    ld   (SRC_PTR), hl
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM
    ld   a, (COMPILE_ERROR_CODE)
    cp   55
    jp   nz, FAIL

PASS:
    ld   a, 4                ; green
    out  (PORT_ULA), a
    jr   $

FAIL:
    ld   a, 2                ; red
    out  (PORT_ULA), a
    jr   $

SOURCE_TEXT:
    db "S=0:FOR I=1 TO 3:FOR J=1 TO 3:S=S+1:NEXT J:NEXT I:"
    db "T=0:FOR K=1 TO 3:FOR L=1 TO 10:IF L>2 THEN EXIT FOR ENDIF:"
    db "T=T+1:NEXT L:T=T+K:NEXT K", 0

; NEXT names the OUTER loop's own variable (I) while J's own FOR is still
; the innermost open loop -- must be rejected, not silently accepted.
MISMATCH_SOURCE:
    db "FOR I=1 TO 3:FOR J=1 TO 3:NEXT I:NEXT J", 0

; Five levels deep -- one past CFOR_STACK/VM_FOR_STACK's own explicit
; four-deep limit.
TOODEEP_SOURCE:
    db "FOR A=1 TO 2:FOR B=1 TO 2:FOR C=1 TO 2:FOR D=1 TO 2:"
    db "FOR E=1 TO 2:NEXT E:NEXT D:NEXT C:NEXT B:NEXT A", 0

; ============================================================================
; CHECK_RESULT — direct SYMTAB memory reads. Compiler assigns indices in
; first-use order: 0=S, 1=I, 2=J, 3=T, 4=K, 5=L.
; ============================================================================
CHECK_RESULT:
    ld   a, (SYMTAB_BASE + 0*3)     ; S's own tag
    cp   0
    jr   nz, .fail
    ld   hl, (SYMTAB_BASE + 0*3 + 1)
    ld   de, 9
    or   a
    sbc  hl, de
    jr   nz, .fail
    ld   a, (SYMTAB_BASE + 3*3)     ; T's own tag
    cp   0
    jr   nz, .fail
    ld   hl, (SYMTAB_BASE + 3*3 + 1)
    ld   de, 12
    or   a
    sbc  hl, de
    jr   nz, .fail
    ret
.fail:
    scf
    ret

; Test-only stubs: this file's own test program never exercises PRINT/
; LPRINT/BEEP/SOUND/PAUSE/INPUT, and never registers or calls a loadable
; extension -- same stubbing discipline as every other v2 test.
BASIC_STMT_LPRINT_EXROM:
    ret
SOUND_BEEP:
    ret
SOUND_EXROM:
    or a
    ret
IO_READ_KEY:
    xor a
    ret
INT_GET_FRAMES:
    ld hl,0
    ret
EXT2_LOOKUP:
    scf
    ret
EXT2_SLOT_ADDR:
    ret
EXT_CALL_ARG0: equ $8B00
EXT_CALL_ARG4: equ $8B00
EXT2_TABLE:    equ $8B00

KTAB_CALC_EXIT_TRAMPOLINE:
    ret

; kernel/math/math.asm is included FOR REAL below, entirely unstubbed.
; This file's own DECOMPILE_PROGRAM call needs real MATH_DIVIDE16/
; MULTIPLY16 for ANY multi-digit label/offset it renders (DECOMP_
; COMPUTE_DIGITS's own real body divides by 10 to extract each decimal
; digit) -- stubbing those to save space, tried and reverted here,
; silently infinite-loops the decompiler instead of failing loudly
; (each "digit" computes as a bogus 0 forever, since a bare `ret` leaves
; the dividend unchanged). math.asm's own routines are not independently
; include-able, so "stub the rest, keep DIVIDE/MULTIPLY real" isn't
; possible either without hand-duplicating everything DIVIDE16's own
; real call chain (SIGN_PREP/UDIV16/APPLY_SIGN) needs -- not attempted;
; the whole file is small enough to include as-is.
    INCLUDE "kernel/math/math.asm"
; rom/exrom_calc.asm (1772 real lines) is NOT included here: this test's
; own program is pure integer arithmetic -- same stubbing discipline as
; rom/test_v2_for_step.asm's own identical header note.
CALC_INT_TO_FP:
    ret
CALC_FP_TO_INT:
    ret
CALC_SP_TO_NEXT_FREE_PTR:
    ret
CALC_PUSH_PI:
    ret
CALC_PUSH_FP_RAW:
    ret
; kernel/graphics/graphics.asm (2235 real lines) is NOT included here:
; this test never checks real screen bitmap content or calls PRINT.
GFX_CLS:
    ret
GFX_PAINT_ATTR:
    ret
GFX_SET_BORDER:
    ret
GFX_WRITE_PIXEL:
    ret
GFX_LINE:
    ret
GFX_PRINT_STRING_ATTR:
    ret
GFX_SCROLL_OUTPUT_UP:
    ret
GFX_SET_MODE:
    ret
GFX_SPRITE_CAPTURE:
    or a
    ret
GFX_SPRITE_DRAW:
    or a
    ret
GFX_READ_PIXEL:
    xor a
    ret
GFX_CELL_ATTR_ADDR:
    scf
    ret
; kernel/memory/memory.asm is NOT included here -- checked directly:
; neither rom/exrom_v2_vm_core.asm/compiler.asm/decompiler.asm reference
; any MEM_*/PROG_END/PROG_AREA_START/ARRAYS_END/VARS_START symbol, and
; this test never touches the real editor engine.
    INCLUDE "rom/exrom_format.asm"
IO_READ_KEY_NONBLOCK:
        xor a
        ret

    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"
    INCLUDE "rom/exrom_v2_decompiler.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_for_nested.bin", $0000, $4000
