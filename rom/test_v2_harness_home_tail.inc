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
; semantic-completion milestone, see docs/POST_R9_SEMANTIC_
; MILESTONE.md's own test-harness-capacity section) are both small
; enough to include for real unconditionally now that this harness has
; the full production-shaped 16K to work with, rather than re-litigate
; per test which MATH_* routines are safe to stub.
; ============================================================================
; MEM_FILL_ZERO -- R10.7 P3: VM_INIT now zeroes the carved run-time tables in every
; build (it used to do so only in production), so every test image needs the
; kernel routine (copied narrowly where kernel/memory is not linked).
; TEST_V2_WITH_KERNEL_MEMORY (qualification study): a test that needs the REAL line store
; (MEM_LINE_FIRST/MEM_LINE_NEXT -- the stored-program RUN path, CHUNK_APPEND_ONE_RECORD's
; KERNEL_MEMORY_PRESENT branch) links kernel/memory/memory.asm itself instead of this copy.
    IFDEF TEST_V2_WITH_KERNEL_MEMORY
    INCLUDE "kernel/memory/memory.asm"
    ELSE
MEM_FILL_ZERO:
    xor  a
    ld   (hl), a
    ld   d, h
    ld   e, l
    inc  de
    dec  bc
    ld   a, b
    or   c
    ret  z
    ldir
    ret
    ENDIF
    INCLUDE "kernel/bank/bank.asm"
    INCLUDE "kernel/math/math.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/test_v2_local_dim.inc"   ; R10.9 2C: test-only DIM handlers
    INCLUDE "rom/exrom_v2_compiler.asm"
    DS $4000 - $, $FF
    SAVEBIN "test_v2_harness_home.bin", $0000, $4000
