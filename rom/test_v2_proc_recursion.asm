; ============================================================================
; rom/test_v2_proc_recursion.asm — post-R9 semantic-completion milestone:
; PROC/DEF-FN recursion safety (docs/v2/V2_SEMANTIC_CAPABILITY_AUDIT.md S11).
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's new
; EMIT_OP_PARAM_BIND/EMIT_OP_PARAM_UNBIND (COMPILE_PROC) and rom/
; exrom_v2_vm_core.asm's new VM_PARAM_SAVE_SP-based OP_PARAM_BIND/
; OP_PARAM_UNBIND. NOT wired into the production BASIC dispatch or the
; shipping EXROM build. Built on the shared production-shaped test
; harness (rom/test_v2_harness_home_head.inc/_tail.inc + rom/
; test_v2_harness_exrom.asm) -- see that harness's own header for why
; (post-semantic-milestone test-infrastructure fix, docs/v2/
; POST_R9_TEST_INFRASTRUCTURE.md).
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
; ============================================================================

    DEFINE TEST_V2_NEEDS_DECOMPILE
    INCLUDE "rom/test_v2_harness_home_head.inc"
    INCLUDE "rom/test_v2_symmacros.inc"

SOURCE_TEXT:
    db "PROC COUNT(N):IF N>0 THEN CALL COUNT(N-1) ENDIF:R=R+N:ENDP:"
    db "R=0:CALL COUNT(3):PRINT R", 0

; ============================================================================
; TEST_CHECK_RESULT — VM_CALL_STACK and VM_PARAM_SAVE_SP must both be back
; to their own empty state once every CALL/ENDP pair has closed normally
; (a leak in either would silently exhaust real headroom for later,
; deeper recursive programs), then direct SYMTAB memory reads. Compiler
; assigns indices in first-use order: N is registered as PROC COUNT's own
; parameter (first identifier compiled at all -> index 0); R is first
; referenced inside COUNT's own body ("R=R+N", compiled as part of the
; PROC's inline body during the same top-to-bottom pass, before the
; top-level "R=0" is ever reached) -> index 1.
; ============================================================================
TEST_CHECK_RESULT:
    ld   hl, (VM_CSP)
    ld   de, (VARS_START)
    or   a
    sbc  hl, de
    jr   nz, .fail
    TSYM_LD8 1*3  ; R's own tag
    cp   0
    jr   nz, .fail
    TSYM_LD16 1*3 + 1
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

    INCLUDE "rom/test_v2_harness_home_tail.inc"
