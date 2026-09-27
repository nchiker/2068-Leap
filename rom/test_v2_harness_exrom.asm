; ============================================================================
; rom/test_v2_harness_exrom.asm — shared EXROM-side image for the
; production-shaped standalone V2 test harness. See rom/
; test_v2_harness_home_head.inc's own header for the full design
; rationale.
;
; This file is the SAME for every test (unlike the HOME side, which
; carries each test's own SOURCE_TEXT/checks): the real calculator is
; included when the driving assembly defines TEST_V2_NEEDS_CALC, and the
; real decompiler when it defines TEST_V2_NEEDS_DECOMPILE (`sjasmplus
; -DTEST_V2_NEEDS_CALC -DTEST_V2_NEEDS_DECOMPILE ...`) -- both optional,
; since decompiler alone (needed by most tests) plus the real calculator
; (needed by only a few) together would overflow the 8K EXROM bank, and
; most tests need only one or neither. A test that defines neither gets
; harmless `ret` stubs at every entry point, same as the old flat-bank
; harnesses did for whichever of these two subsystems they didn't need.
;
; TEST_V2_CALC_ADDR/TEST_V2_DECOMP_ADDR/etc. are this harness's own
; private fixed addresses (never production's real EXROM ABI, include/
; v2_ktab.inc) -- defined once in rom/test_v2_harness_addrs.inc and read
; back by each test's own HOME-side head via the same shared include, so
; the two sides can never drift apart.
; ============================================================================
    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"
    INCLUDE "rom/test_v2_harness_addrs.inc"

KTAB_CALC_EXIT_TRAMPOLINE EQU TEST_V2_CALC_EXIT_ADDR

    DEVICE NOSLOT64K
    ORG TEST_V2_CALC_ADDR
    IFDEF TEST_V2_NEEDS_CALC
    jp CALC_EXROM_ENTRY
    ELSE
    ret
    ENDIF
    ORG TEST_V2_INT_TO_FP_ADDR
    IFDEF TEST_V2_NEEDS_CALC
    jp CALC_INT_TO_FP
    ELSE
    ret
    ENDIF
    ORG TEST_V2_FP_TO_INT_ADDR
    IFDEF TEST_V2_NEEDS_CALC
    jp CALC_FP_TO_INT
    ELSE
    ret
    ENDIF
    ORG TEST_V2_PUSH_PI_ADDR
    IFDEF TEST_V2_NEEDS_CALC
    jp CALC_PUSH_PI
    ELSE
    ret
    ENDIF
    ORG TEST_V2_PUSH_FP_RAW_ADDR
    IFDEF TEST_V2_NEEDS_CALC
    jp CALC_PUSH_FP_RAW
    ELSE
    ret
    ENDIF
    ORG TEST_V2_SP_TO_PTR_ADDR
    IFDEF TEST_V2_NEEDS_CALC
    jp CALC_SP_TO_NEXT_FREE_PTR
    ELSE
    ret
    ENDIF

    IFDEF TEST_V2_NEEDS_DECOMPILE
    ORG TEST_V2_DECOMP_ADDR
    jp DECOMPILE_PROGRAM
    ENDIF

    IFDEF TEST_V2_NEEDS_CALC
    INCLUDE "rom/exrom_calc.asm"
    ENDIF

    IFDEF TEST_V2_NEEDS_DECOMPILE
; rom/exrom_v2_decompiler.asm has a handful of direct cross-references
; into rom/exrom_v2_vm_core.asm/exrom_v2_compiler.asm and kernel/
; extensions/ext_registry.asm (VM_CODE_BASE, ARRAY_MAX_COUNT, real
; MATH_DIVIDE16/MULTIPLY16 for its own digit rendering, VM_TEST_
; ARGTYPE_BIT, EXT2_TABLE) -- fine in production, where nothing pulls
; the decompiler in at all, but real here since this harness deliberately
; keeps vm_core+compiler (10,439 bytes together, already over the 8K
; EXROM bank on their own) HOME-resident and the decompiler EXROM-
; resident. Reproduced/stubbed narrowly rather than pulling vm_core or
; compiler wholesale into EXROM too:
VM_CODE_BASE EQU $A455        ; matches include/v2_layout.inc's own
                                ; V2_CODE_BASE -- bytecode JMP offsets
                                ; are relative to this, not absolute,
                                ; so the exact value only needs to
                                ; match what rom/exrom_v2_compiler.asm
                                ; (HOME-resident here) itself uses
ARRAY_MAX_COUNT EQU 4          ; must match rom/exrom_v2_vm_core.asm's
                                ; own real constant (checked directly)
EXT2_TABLE EQU $BF00           ; real address (kernel/extensions/
                                ; ext_registry.asm); no test using this
                                ; harness decompiles a CALL_EXT, so an
                                ; empty table here is harmless
; VM_TEST_ARGTYPE_BIT -- real body copied verbatim from rom/
; exrom_v2_vm_core.asm (10 bytes); a real ROUTINE, not just a constant,
; so it can't be reproduced as a bare EQU the way the others above are.
VM_TEST_ARGTYPE_BIT:
        ld d,b
        ld b,a
.rot_loop:
        ld a,d
        or a
        jr z,.done
        ld a,b
        srl a
        ld b,a
        dec d
        jr .rot_loop
.done:
        ld a,b
        bit 0,a
        ret
    INCLUDE "kernel/math/math.asm"
    INCLUDE "rom/exrom_v2_decompiler.asm"
    ENDIF
    DS $E000 - $, $FF
    SAVEBIN "test_v2_harness_exrom.bin", $C000, $2000
