; ============================================================================
; rom/test_v2_for_nested.asm — post-R9 semantic-completion milestone: real
; nested FOR/NEXT (docs/v2/V2_SEMANTIC_CAPABILITY_AUDIT.md S9).
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's new
; compile-stack-based COMPILE_FOR/COMPILE_NEXT/COMPILE_EXIT_FOR and rom/
; exrom_v2_vm_core.asm's new VM_FOR_STACK-based OP_FOR_INIT/OP_FOR_POP.
; NOT wired into the production BASIC dispatch or the shipping EXROM
; build. Built on the shared production-shaped test harness (rom/
; test_v2_harness_home_head.inc/_tail.inc + rom/test_v2_harness_exrom.
; asm) -- see that harness's own header for why (post-semantic-milestone
; test-infrastructure fix, docs/v2/POST_R9_TEST_INFRASTRUCTURE.md).
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
;   tools/sjasmplus_strict.sh -DTEST_V2_NEEDS_DECOMPILE \
;       rom/test_v2_harness_exrom.asm
;   tools/sjasmplus_strict.sh --sym=build/test_v2_for_nested.sym \
;       rom/test_v2_for_nested.asm
; Run (PASS=green/FAIL=red border): concatenate the two output binaries
; (HOME then EXROM) and boot via ts2068-debug/Fuse, same as any other
; production-shaped combined image.
; ============================================================================

    DEFINE TEST_V2_CUSTOM_CHECKS
    DEFINE TEST_V2_NEEDS_DECOMPILE
    INCLUDE "rom/test_v2_harness_home_head.inc"
    INCLUDE "rom/test_v2_symmacros.inc"

TEST_CUSTOM_MAIN:
    call COMPILER_INIT
    ld   hl, SOURCE_TEXT
    ld   (SRC_PTR), hl
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM
    ld   a, (COMPILE_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL

    ld   hl, (EMIT_PTR)
    ld   (DECOMP_END_ADDR), hl

    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN

    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL

    ; both FOR stacks must be empty once every loop has closed normally: the
    ; compile stack (R10.7 P2: no frame open <=> SYM_LIMIT_V == V2_SOURCE_END)
    ; and the VM FOR stack -- a leak would corrupt a later nesting.
    ld   hl, (SYM_LIMIT_V)
    ld   de, V2_SOURCE_END
    or   a
    sbc  hl, de
    jp   nz, TEST_FAIL
    ld   hl, (VM_CSP)
    ld   de, (VARS_START)
    or   a
    sbc  hl, de
    jp   nz, TEST_FAIL

    call CHECK_RESULT
    jp   c, TEST_FAIL

    call DECOMPILE_PROGRAM
    ld   a, (DECOMP_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL

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
    jp   nz, TEST_FAIL

    ; ------------------------------------------------------------------
    ; R10.7 P2: the compile-time nesting limit (FOR_NEST_MAX = 4, error 55) is
    ; gone -- loop frames live on the memory-limited compile stack. A
    ; five-deep nest must now compile AND run: 2^5 = 32 innermost iterations.
    ; ------------------------------------------------------------------
    call COMPILER_INIT
    ld   hl, DEEP_SOURCE
    ld   (SRC_PTR), hl
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM
    ld   a, (COMPILE_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL
    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN
    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL
    ld   hl, (VM_CSP)
    ld   de, (VARS_START)
    or   a
    sbc  hl, de
    jp   nz, TEST_FAIL
    TSYM_LD16 1  ; S is symbol 0
    ld   de, 32
    or   a
    sbc  hl, de
    jp   nz, TEST_FAIL

    ; ------------------------------------------------------------------
    ; R10.7 P2: EXIT FOR statements per loop are no longer capped at 4
    ; (error 45): the patch addresses are threaded through the emitted code.
    ; Six EXIT FORs in one loop, only the third-from-last ever taken; every one
    ; must be patched to land after the loop (Z ends at 111).
    ; ------------------------------------------------------------------
    call COMPILER_INIT
    ld   hl, EXITS_SOURCE
    ld   (SRC_PTR), hl
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM
    ld   a, (COMPILE_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL
    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN
    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL
    TSYM_LD16 1  ; Z is symbol 0
    ld   de, 111
    or   a
    sbc  hl, de
    jp   nz, TEST_FAIL

    ; ------------------------------------------------------------------
    ; EXIT FOR with no FOR open is an explicit compile error (63) now (the
    ; old code indexed a frame that did not exist).
    ; ------------------------------------------------------------------
    call COMPILER_INIT
    ld   hl, STRAY_EXIT_SOURCE
    ld   (SRC_PTR), hl
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM
    ld   a, (COMPILE_ERROR_CODE)
    cp   63
    jp   nz, TEST_FAIL

    jp   TEST_PASS

SOURCE_TEXT:
    db "S=0:FOR I=1 TO 3:FOR J=1 TO 3:S=S+1:NEXT J:NEXT I:"
    db "T=0:FOR K=1 TO 3:FOR L=1 TO 10:IF L>2 THEN EXIT FOR ENDIF:"
    db "T=T+1:NEXT L:T=T+K:NEXT K", 0

; NEXT names the OUTER loop's own variable (I) while J's own FOR is still
; the innermost open loop -- must be rejected, not silently accepted.
MISMATCH_SOURCE:
    db "FOR I=1 TO 3:FOR J=1 TO 3:NEXT I:NEXT J", 0

; Five levels deep -- one past the OLD compile-time limit of four.
DEEP_SOURCE:
    db "S=0:FOR A=1 TO 2:FOR B=1 TO 2:FOR C=1 TO 2:FOR D=1 TO 2:"
    db "FOR E=1 TO 2:S=S+1:NEXT E:NEXT D:NEXT C:NEXT B:NEXT A", 0

; Six EXIT FOR statements in a single loop (the old cap was four).
EXITS_SOURCE:
    db "Z=0:FOR I=1 TO 10:IF I=1 THEN Z=Z+1 ENDIF:IF I=2 THEN Z=Z+10 ENDIF:"
    db "IF I>5 THEN EXIT FOR ENDIF:IF I>4 THEN EXIT FOR ENDIF:"
    db "IF I>3 THEN EXIT FOR ENDIF:IF I>3 THEN EXIT FOR ENDIF:"
    db "IF I>3 THEN EXIT FOR ENDIF:IF I>3 THEN EXIT FOR ENDIF:NEXT I:Z=Z+100", 0

STRAY_EXIT_SOURCE:
    db "EXIT FOR", 0

; ============================================================================
; CHECK_RESULT — direct SYMTAB memory reads. Compiler assigns indices in
; first-use order: 0=S, 1=I, 2=J, 3=T, 4=K, 5=L.
; ============================================================================
CHECK_RESULT:
    TSYM_LD8 0*3  ; S's own tag
    cp   0
    jr   nz, .fail
    TSYM_LD16 0*3 + 1
    ld   de, 9
    or   a
    sbc  hl, de
    jr   nz, .fail
    TSYM_LD8 3*3  ; T's own tag
    cp   0
    jr   nz, .fail
    TSYM_LD16 3*3 + 1
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

    INCLUDE "rom/test_v2_harness_home_tail.inc"
