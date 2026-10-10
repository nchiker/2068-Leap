; ============================================================================
; rom/test_v2_harness_home_head.inc — shared HOME-side prologue for the
; production-shaped standalone V2 test harness (post-semantic-milestone
; test-infrastructure fix).
;
; WHY THIS EXISTS: every rom/test_v2_*.asm file used to be one flat,
; single-bank 16K image bundling rom/exrom_v2_vm_core.asm + rom/
; exrom_v2_compiler.asm (+ rom/exrom_v2_decompiler.asm, + rom/
; exrom_calc.asm, for the tests that needed them) all into the SAME
; bank. That was a reasonable compromise while those files were small,
; but the post-R9 semantic-completion milestone (FLOAT fix, nested
; FOR/NEXT, PROC/DEF-FN recursion safety, DEF FN reintegration) grew
; vm_core+compiler by 848 bytes, pushing 11 of the 14 existing
; standalone harnesses over that artificial flat-16K ceiling even
; though the REAL production ROM (rom/v2_home.asm + rom/v2_exrom.asm)
; has comfortable headroom in both its own real 16K HOME + 8K EXROM
; banks.
;
; This harness instead mirrors rom/v2_home.asm's own real structure:
; vm_core+compiler resident in a 16K HOME bank, calculator/decompiler
; (when a given test needs them) paged into a separate 8K EXROM bank
; via the SAME real kernel/bank/bank.asm BANK_PAGE_EXROM_IN/OUT
; primitives production itself uses -- not a test-only invention. This
; restores the full real 16K+8K combined capacity instead of an
; artificial single 16K ceiling, without shrinking any production code
; or omitting anything production itself doesn't omit.
;
; PAGING MODEL, confirmed against rom/v2_home.asm's own real behavior:
; V2_COLD_START calls BANK_PAGE_EXROM_IN exactly ONCE, unbalanced, then
; tail-jumps into the EXROM-resident shell -- EXROM stays paged in for
; the rest of normal operation. This is why rom/exrom_v2_vm_core.asm can
; `call CALC_INT_TO_FP` etc. directly (EQU'd to a fixed EXROM address in
; rom/v2_home.asm) with no explicit paging at each call site: EXROM is
; simply always resident by the time any of that code runs. Only the
; real arithmetic dispatch (RST $28 -> CALC_EXROM_ENTRY) uses the
; explicit nested BANK_PAGE_EXROM_IN/OUT trampoline pair, and that
; nesting nets out to a no-op against the permanent cold-boot page-in
; (BANK_EXROM_DEPTH is a counter, not a boolean -- see kernel/bank/
; bank.asm's own header). TEST_COLD_START below reproduces the same
; shape: one unconditional, unbalanced BANK_PAGE_EXROM_IN before
; anything else runs.
;
; This is a TEST-ONLY harness, never mixed with real production EXROM:
; its own fixed EXROM entry addresses (rom/test_v2_harness_addrs.inc)
; are a private convention, not part of include/v2_ktab.inc's real
; production ABI, and this file must never be included by anything
; that also includes rom/exrom_v2_shell.asm or ships as a real product.
;
; USAGE (see rom/test_v2_for_nested.asm for a worked example): the
; driving test file defines TEST_V2_NEEDS_DECOMPILE before including
; this file if it needs DECOMPILE_PROGRAM (assembled with a matching
; -DTEST_V2_NEEDS_DECOMPILE for rom/test_v2_harness_exrom.asm too). It
; must then define SOURCE_TEXT and TEST_CHECK_RESULT (called once after
; a clean VM_RUN halt -- returns with carry set to fail). If TEST_V2_
; NEEDS_DECOMPILE, a clean DECOMP_ERROR_CODE=0 is asserted automatically;
; a test that also wants to assert the exact rendered text additionally
; defines TEST_V2_CHECK_DECOMPILED_TEXT and provides TEST_CHECK_
; DECOMPILED (same carry-flag contract). A test that deliberately
; expects a nonzero VM_ERROR_CODE/COMPILE_ERROR_CODE, or drives more than
; one compile/run pass (e.g. rom/test_v2_for_nested.asm's own negative
; checks, or rom/test_v2_deffn.asm's own recursion-overflow case), skips
; this file's own default linear happy path by defining TEST_V2_CUSTOM_
; CHECKS and providing a TEST_CUSTOM_MAIN that drives COMPILER_INIT/
; COMPILE_PROGRAM/VM_INIT/VM_RUN/DECOMPILE_PROGRAM itself, ending with
; `jp TEST_PASS` or `jp TEST_FAIL`.
;
; After this include, the driving test file may define whatever GFX_*/
; IO_*/SOUND_*/EXT2_* stubs it still needs (same discipline every pre-
; existing v2 test already used), then include rom/
; test_v2_harness_home_tail.inc to pull in the real kernel/bank,
; kernel/math, vm_core, and compiler, and emit the final SAVEBIN.
; ============================================================================

    INCLUDE "include/hardware.inc"
    DEFINE V2_COMPACT_SYSVARS   ; R10.7 P5 (see include/sysvars.inc)
    INCLUDE "include/sysvars.inc"
    INCLUDE "rom/test_v2_harness_addrs.inc"

; Direct-call stubs into EXROM (assumed already paged in -- see this
; file's own header). Matches rom/v2_home.asm's own identical EQU
; pattern for the exact same five calculator helpers, plus one more
; (DECOMPILE_PROGRAM) this private test harness adds that production
; itself has no need for (the decompiler isn't resident in production).
CALC_INT_TO_FP EQU TEST_V2_INT_TO_FP_ADDR
CALC_FP_TO_INT EQU TEST_V2_FP_TO_INT_ADDR
CALC_PUSH_PI EQU TEST_V2_PUSH_PI_ADDR
CALC_PUSH_FP_RAW EQU TEST_V2_PUSH_FP_RAW_ADDR
CALC_SP_TO_NEXT_FREE_PTR EQU TEST_V2_SP_TO_PTR_ADDR
    IFDEF TEST_V2_NEEDS_DECOMPILE
DECOMPILE_PROGRAM EQU TEST_V2_DECOMP_ADDR
; RAM, not ROM, so both the HOME and EXROM assemblies can safely
; reference the same addresses independently -- must match rom/
; exrom_v2_decompiler.asm's own real equ's exactly (checked directly).
DECOMP_END_ADDR EQU $BD9F
DECOMP_ERROR_CODE EQU $BE37
DECOMP_OUT_BUF EQU $BC00
DECOMP_OUT_PTR EQU $BE34
    ENDIF

; MEM_FREE_BYTES/MEM_CLEAR_V2 -- R10.7 additions. Both are real, narrow
; reproductions (same "reproduced/stubbed narrowly" convention as this
; file's own VM_TEST_ARGTYPE_BIT precedent above), not cross-bank stubs:
; MEM_FREE_BYTES is genuine HOME-resident kernel code in production too
; (kernel/memory/memory.asm, not pulled in whole here to avoid dragging
; in the rest of that file's own dependencies this harness doesn't
; otherwise need). MEM_CLEAR_V2 is production EXROM-resident (rom/
; exrom_v2_shell.asm) but this harness has no EXT2/extension-registry
; presence at all (see rom/test_v2_harness_exrom.asm's own header) --
; the extension-registry-clear call is dropped here, matching the
; existing EXT2_TABLE-empty-is-fine precedent a few lines above for the
; decompiler's own CALL_EXT case.
TEST_V2_SOURCE_END EQU V2_SOURCE_END   ; the canonical include/v2_layout.inc value (pulled in with
                                 ; vm_core/compiler by the tail); was a stale hardcoded $A33F
TEST_V2_PACKAGE_LEN EQU $BE82   ; matches rom/exrom_v2_shell.asm's own
                                 ; real V2_PACKAGE_LEN fixed RAM address

MEM_FREE_BYTES:
        ld hl,(VARS_START)
        ld de,(ARRAYS_END)
        or a
        sbc hl,de
        ret

MEM_CLEAR_V2:
        ld hl,(PROG_END)
        ld (ARRAYS_END),hl
        ld hl,TEST_V2_SOURCE_END
        ld (VARS_START),hl
        ld hl,0
        ld (TEST_V2_PACKAGE_LEN),hl
        ret

    DEVICE NOSLOT64K
    ORG $0000
    di
    jp TEST_COLD_START
    DS $0028 - $, $FF
    jp TEST_CALC_ENTRY
    DS $0038 - $, $FF
TEST_RST_38:
    ei
    reti
    DS $0100 - $, $FF

TEST_COLD_START:
    ld sp, $FF00
    xor a
    ld (BANK_EXROM_DEPTH), a   ; cold RAM content is undefined; BANK_
                                ; PAGE_EXROM_IN's own nesting-depth check
                                ; needs this to genuinely start at 0
    call BANK_PAGE_EXROM_IN     ; ONE unbalanced page-in, matching real
                                  ; V2_COLD_START -- see this file's own
                                  ; header. Never paged back out.
    ld hl, PROG_AREA_START      ; R10.7 P2: the compile symbol table is placed
    ld (PROG_END), hl           ; at PROG_END, so every test needs a sane one
    ld (ARRAYS_END), hl         ; (cold RAM is undefined); custom tests that
    ld hl, TEST_V2_SOURCE_END   ; set their own values simply overwrite these
    ld (VARS_START), hl
    IFDEF TEST_V2_CUSTOM_CHECKS
    jp TEST_CUSTOM_MAIN
    ELSE
    call COMPILER_INIT
    ld hl, SOURCE_TEXT
    ld (SRC_PTR), hl
    ld hl, VM_CODE_BASE
    ld (EMIT_PTR), hl
    call COMPILE_PROGRAM
    ld a, (COMPILE_ERROR_CODE)
    or a
    jp nz, TEST_FAIL
    ld hl, (EMIT_PTR)
    ld (DECOMP_END_ADDR), hl
    call VM_INIT
    ld hl, VM_CODE_BASE
    ld (VM_IP), hl
    call VM_RUN
    ld a, (VM_ERROR_CODE)
    or a
    jp nz, TEST_FAIL
    call TEST_CHECK_RESULT
    jp c, TEST_FAIL
    IFDEF TEST_V2_NEEDS_DECOMPILE
    call DECOMPILE_PROGRAM
    ld a, (DECOMP_ERROR_CODE)
    or a
    jp nz, TEST_FAIL
    IFDEF TEST_V2_CHECK_DECOMPILED_TEXT
    call TEST_CHECK_DECOMPILED
    jp c, TEST_FAIL
    ENDIF
    ENDIF
    jp TEST_PASS
    ENDIF

TEST_PASS:
    ld a, 4                  ; green
    out (PORT_ULA), a
    jr $

TEST_FAIL:
    ld a, 2                  ; red
    out (PORT_ULA), a
    jr $

; TEST_CALC_ENTRY/CALC_EXIT_TRAMPOLINE -- same real shape as rom/
; v2_home.asm's own V2_CALC_ENTRY/CALC_EXIT_TRAMPOLINE (RST $28 tail-
; jumps here, the calculator's own real code calls CALC_EXIT_TRAMPOLINE
; at its own natural exit -- see rom/exrom_calc.asm's own entry
; contract). The BANK_PAGE_EXROM_IN/OUT pair here nets out to a no-op
; against TEST_COLD_START's own permanent page-in (BANK_EXROM_DEPTH is a
; real nesting counter), kept for exact parity with production's own
; shape rather than assumed harmless.
TEST_CALC_ENTRY:
    call BANK_PAGE_EXROM_IN
    jp TEST_V2_CALC_ADDR

; Placed at a fixed address (TEST_V2_CALC_EXIT_ADDR) because rom/
; exrom_calc.asm's own real code calls it as KTAB_CALC_EXIT_TRAMPOLINE
; -- a plain numeric EQU on the EXROM side (rom/test_v2_harness_exrom.
; asm), since the two harness images are separate assemblies with no
; shared label space, exactly like production's own real KTAB
; mechanism (include/v2_ktab.inc) resolves the same call.
    ORG TEST_V2_CALC_EXIT_ADDR
CALC_EXIT_TRAMPOLINE:
    jp BANK_PAGE_EXROM_OUT
