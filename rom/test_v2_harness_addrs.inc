; Shared fixed EXROM entry addresses for the production-shaped standalone
; V2 test harness (rom/test_v2_harness_home_head.inc / rom/
; test_v2_harness_exrom.asm). Included by both sides so they can never
; drift apart. Private test-only convention, not production ABI (compare
; include/v2_ktab.inc's real one, which this mirrors the SHAPE of, not
; the values).
;
; Mirrors rom/v2_exrom.asm's own stub-indirection pattern: rom/
; exrom_calc.asm's real CALC_INT_TO_FP/FP_TO_INT/PUSH_PI/PUSH_FP_RAW/
; SP_TO_NEXT_FREE_PTR labels float to wherever they land inside the
; EXROM image (position depends on everything assembled before them),
; so HOME-side code that wants to `call` them directly (not through
; RST $28 -- rom/exrom_v2_vm_core.asm's VM_FLOAT_PUSH_OPERAND etc. do
; exactly this) needs a FIXED-address stub to jump through, exactly
; like V2_EXROM_INT_TO_FP_ADDR's own real stub in rom/v2_exrom.asm.
    IFNDEF TEST_V2_HARNESS_ADDRS_INC
    DEFINE TEST_V2_HARNESS_ADDRS_INC
TEST_V2_CALC_ADDR EQU $C000              ; CALC_EXROM_ENTRY, via the RST
                                           ; $28 trampoline (real nested
                                           ; BANK_PAGE_EXROM_IN/OUT, same
                                           ; shape as production's own
                                           ; V2_CALC_ENTRY/CALC_EXIT_
                                           ; TRAMPOLINE)
TEST_V2_INT_TO_FP_ADDR EQU $C008          ; direct-call stubs (EXROM
TEST_V2_FP_TO_INT_ADDR EQU $C010           ; assumed already paged in --
TEST_V2_PUSH_PI_ADDR EQU $C018              ; see TEST_COLD_START's own
TEST_V2_PUSH_FP_RAW_ADDR EQU $C020           ; unconditional, unbalanced
TEST_V2_SP_TO_PTR_ADDR EQU $C028              ; BANK_PAGE_EXROM_IN call,
                                                ; matching production's
                                                ; own V2_COLD_START shape
TEST_V2_DECOMP_ADDR EQU $C900             ; DECOMPILE_PROGRAM, same
                                            ; "already paged in" assumption
TEST_V2_CALC_EXIT_ADDR EQU $0200           ; HOME-side CALC_EXIT_
                                            ; TRAMPOLINE's own fixed
                                            ; address -- rom/exrom_calc.
                                            ; asm calls KTAB_CALC_EXIT_
                                            ; TRAMPOLINE (a plain numeric
                                            ; EQU from the EXROM side,
                                            ; since the two harness
                                            ; images are separate
                                            ; assemblies with no shared
                                            ; label space), so both
                                            ; sides must agree on this
                                            ; address, not just the
                                            ; label name
    ENDIF
