; ============================================================================
; rom/test_v2_harness_home_tail.inc — shared HOME-side epilogue for the
; production-shaped standalone V2 test harness. See rom/
; test_v2_harness_home_head.inc's own header for the full design
; rationale. Include this AFTER the driving test file's own SOURCE_TEXT/
; TEST_CHECK_RESULT/stubs.
;
; Real kernel/bank/bank.asm (the same hardware-confirmed BANK_PAGE_
; EXROM_IN/OUT this harness's own trampolines call) and real kernel/
; math/math.asm (needed unconditionally: rom/exrom_v2_decompiler.asm's
; own DECOMP_COMPUTE_DIGITS needs real MATH_DIVIDE16/MULTIPLY16 for any
; multi-digit label/offset it renders, and a stub silently infinite-
; loops it instead of failing loudly -- found and documented during the
; semantic-completion milestone, see docs/v2/POST_R9_SEMANTIC_
; MILESTONE.md's own test-harness-capacity section) are both small
; enough to include for real unconditionally now that this harness has
; the full production-shaped 16K to work with, rather than re-litigate
; per test which MATH_* routines are safe to stub.
; ============================================================================
    INCLUDE "kernel/bank/bank.asm"
    INCLUDE "kernel/math/math.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"
    DS $4000 - $, $FF
    SAVEBIN "test_v2_harness_home.bin", $0000, $4000
