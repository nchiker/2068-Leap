; ============================================================================
; rom/test_v2_proc_recursion.asm — post-R9 semantic-completion milestone:
; PROC/DEF-FN recursion safety (docs/v2/V2_SEMANTIC_CAPABILITY_AUDIT.md S11).
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's new
; EMIT_OP_PARAM_BIND/EMIT_OP_PARAM_UNBIND (COMPILE_PROC) and rom/
; exrom_v2_vm_core.asm's new VM_PARAM_SAVE_SP-based OP_PARAM_BIND/
; OP_PARAM_UNBIND. NOT wired into the production BASIC dispatch or the
; shipping EXROM build.
;
; Source program compiled and executed:
;
;   PROC COUNT(N):IF N>0 THEN CALL COUNT(N-1) ENDIF:R=R+N:ENDP
;   R=0:CALL COUNT(3):PRINT R
;
; Genuine recursion (COUNT calls itself 3 times, depth 4: N=3,2,1,0), and
; critically, "R=R+N" reads N AFTER the recursive CALL COUNT(N-1) returns
; -- exactly the audit's own failing case (docs/v2/
; V2_SEMANTIC_CAPABILITY_AUDIT.md S11: "a function that reads its own
; parameter after a recursive self-call"). Under the OLD shared-global-
; slot design, N would read the INNERMOST call's own leftover value (0)
; at every level, giving R=0. Under the fixed design, each level's own N
; is saved before the recursive call rebinds it and restored the moment
; that call returns, so R correctly accumulates 0+1+2+3=6.
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_proc_recursion.sym \
;       rom/test_v2_proc_recursion.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_proc_recursion_zesarux.bin
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

    ; VM_CALL_STACK and VM_PARAM_SAVE_SP must both be back to their own
    ; empty state once every CALL/ENDP pair has closed normally -- a leak
    ; in either would silently exhaust real headroom for later, deeper
    ; recursive programs.
    ld   hl, (VM_CALL_SP)
    ld   de, VM_CALL_STACK_TOP
    or   a
    sbc  hl, de
    jp   nz, FAIL
    ld   hl, (VM_PARAM_SAVE_SP)
    ld   de, VM_PARAM_SAVE_STACK_TOP
    or   a
    sbc  hl, de
    jp   nz, FAIL

    call CHECK_RESULT
    jp   c, FAIL

    call DECOMPILE_PROGRAM
    ld   a, (DECOMP_ERROR_CODE)
    or   a
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
    db "PROC COUNT(N):IF N>0 THEN CALL COUNT(N-1) ENDIF:R=R+N:ENDP:"
    db "R=0:CALL COUNT(3):PRINT R", 0

; ============================================================================
; CHECK_RESULT — direct SYMTAB memory reads. Compiler assigns indices in
; first-use order: N is registered as PROC COUNT's own parameter (first
; identifier compiled at all -> index 0); R is first referenced inside
; COUNT's own body ("R=R+N", compiled as part of the PROC's inline body
; during the same top-to-bottom pass, before the top-level "R=0" is ever
; reached) -> index 1.
; ============================================================================
CHECK_RESULT:
    ld   a, (SYMTAB_BASE + 1*3)     ; R's own tag
    cp   0
    jr   nz, .fail
    ld   hl, (SYMTAB_BASE + 1*3 + 1)
    ld   de, 6                       ; 0+1+2+3
    or   a
    sbc  hl, de
    jr   nz, .fail
    ret
.fail:
    scf
    ret

; Test-only stubs: this file's own test program never exercises PRINT's
; own real screen output, LPRINT/BEEP/SOUND/PAUSE/INPUT, and never
; registers or calls a loadable extension -- same stubbing discipline as
; every other v2 test.
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
; this test never checks real screen bitmap content or calls PRINT's own
; real rendering path.
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

    SAVEBIN "test_v2_proc_recursion.bin", $0000, $4000
