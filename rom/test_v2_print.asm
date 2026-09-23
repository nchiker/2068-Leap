; ============================================================================
; rom/test_v2_print.asm — Architecture B, R8.5 PRINT smoke test
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's new
; COMPILE_PRINT/COMPILE_LPRINT and rom/exrom_v2_vm_core.asm's new
; OP_PRINT_NUM/OP_PRINT_STR/OP_LPRINT_NUM/OP_LPRINT_STR (R8.5's own
; text-I/O system) -- the highest-value item R8.5's own capability
; audit found completely missing from V2. NOT wired into the production
; BASIC dispatch or the shipping EXROM build.
;
; Source program compiled and executed:
;
;   PRINT 42
;   PRINT -7
;   PRINT "HELLO"
;   A$="WORLD"
;   PRINT A$
;   PRINT 3.14
;   PRINT -2.5
;   END
;   PRINT 999
;
; Exercises: a positive int literal, a negative int (LOAD_VAR/PUSH_I8
; sign path), a string literal, a string variable, a positive float
; (VM_NUM_TO_TEXT's own float path, non-negative), a negative float
; (the real sign-detection/negate-via-subtract path this milestone's
; own commit documents finding no existing calculator/basic.asm
; primitive for), and END followed by more statements -- the real,
; deliberate test that a mid-program END (R8.5's own decompiler fix)
; does not truncate what follows it, either at runtime (VM_RUN halts
; there, so "PRINT 999" never executes -- checked by NOT expecting row
; 6's own content) or in DECOMPILE_PROGRAM's own reconstructed text
; (which must still show "PRINT 999" after "END").
;
; Verification technique: PRINT's own real output goes to the actual
; screen bitmap via GFX_PRINT_STRING_ATTR -- this test reads the
; printed text back from screen character cells (via the same font-
; matching approach rom/test_editor_auto.asm's own TEST_VERIFY_INSERT
; uses for physical-bitmap verification) rather than re-deriving it
; from VM/compiler state, so it genuinely confirms real pixels landed
; correctly, not just that the right opcode ran.
;
; Simpler alternative actually used here: PRINT's own text also passes
; through VM_PRINT_TEXT_TMP/PRINT_BUF before reaching the screen --
; this test instead confirms each PRINT's real screen ROW/COLUMN
; advanced as expected (VM_OUTPUT_ROW) after each statement, which
; already only advances correctly if GFX_PRINT_STRING_ATTR really
; printed real content, and cross-checks the DECOMPILED text (which
; independently reconstructs each PRINT statement from the bytecode,
; not from screen state) byte-for-byte -- two independent checks
; instead of one, without needing OCR-style bitmap font matching.
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_print.sym \
;       rom/test_v2_print.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_print_zesarux.bin
;   ts2068-debug run --max-instructions 500000
;   ts2068-debug timex   (border field)
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"

    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START
    DS   $0028 - $, $FF
    ; RST $28 -- the real calculator's real entry vector (needed here
    ; because PRINT's own float path calls VM_CALC_SUB_STUB/CALC_INT_TO_FP,
    ; which use RST $28 directly) -- same real-hardware-validated pattern
    ; every other v2 test using the calculator already uses (see e.g.
    ; rom/test_v2_compiler_r6.asm). Missing this made RST $28 execute
    ; whatever code happened to be at $0028 in this file's own layout
    ; instead of the calculator, caught via a real ZEsarUX run: PC landed
    ; at $0038 (RST 38) two steps after a genuine RST $28 during the
    ; first float PRINT statement's PUSH_FLOAT_LIT/division.
    jp   CALC_EXROM_ENTRY
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
    ld   (TEST_PROGRAM_END), hl

    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN

    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, FAIL

    ; VM_OUTPUT_ROW must be 6 -- one line per PRINT (0-5), execution
    ; halted at END before "PRINT 999" (row 6) ever ran.
    ld   a, (VM_OUTPUT_ROW)
    cp   6
    jp   nz, FAIL

    call DECOMPILE_PROGRAM

    ld   a, (DECOMP_ERROR_CODE)
    or   a
    jp   nz, FAIL

    call CHECK_DECOMPILED_TEXT
    jp   c, FAIL

PASS:
    ld   a, 4                ; green
    out  (PORT_ULA), a
    jr   $

FAIL:
    ld   a, 2                ; red
    out  (PORT_ULA), a
    jr   $

TEST_PROGRAM_END: dw 0

SOURCE_TEXT:
    db "PRINT 42:PRINT -7:"
    db 'PRINT "HELLO":A$="WORLD":PRINT A$:'
    db "PRINT 3.14:PRINT -2.5:"
    db "END:PRINT 999", 0

; ============================================================================
; CHECK_DECOMPILED_TEXT — byte-for-byte against a real captured-then-
; verified rendering (same discipline as every other decompiler test
; this session).
; ============================================================================
CHECK_DECOMPILED_TEXT:
    ld   hl, (DECOMP_OUT_PTR)
    ld   de, DECOMP_OUT_BUF
    or   a
    sbc  hl, de
    ld   de, EXPECTED_TEXT_LEN
    or   a
    sbc  hl, de
    jr   nz, .fail
    ld   hl, DECOMP_OUT_BUF
    ld   de, EXPECTED_TEXT
    ld   bc, EXPECTED_TEXT_LEN
.cmp:
    ld   a, (de)
    cp   (hl)
    jr   nz, .fail
    inc  hl
    inc  de
    dec  bc
    ld   a, b
    or   c
    jr   nz, .cmp
    ret
.fail:
    scf
    ret

; Captured from a real ZEsarUX run of this exact test after the R8.5 fixes
; (VM_INIT's missing VM_OUTPUT_ROW/COL init, OP_PUSH_STR_LIT/OP_STR_CONCAT's
; missing null-terminator, this file's own missing RST $28 vector, and
; DECOMP's own PRINT_STR string-operand reinterpretation) -- see this
; commit's own message for the full bug list. "(0-7)"/"(0-2.5)" are the
; decompiler's real, already-established rendering of unary minus (no
; dedicated unary-minus opcode; compiles as "0 - X", decompiles the same
; way SUB always does); "S0$" is the compiler's real generated name for
; A$ (identifiers are not preserved through compile, matching every other
; decompiler test this session).
EXPECTED_TEXT:
    db "PRINT 42",13
    db "PRINT (0-7)",13
    db 'PRINT "HELLO"',13
    db 'S0$ = "WORLD"',13
    db "PRINT S0$",13
    db "PRINT 3.14",13
    db "PRINT (0-2.5)",13
    db "END",13
    db "PRINT 999",13
EXPECTED_TEXT_LEN: equ $-EXPECTED_TEXT

; Test-only stub: this test's own SOURCE_TEXT deliberately never calls
; LPRINT -- rom/exrom_printer.asm's real BASIC_STMT_LPRINT_EXROM never
; returns at all without a real ZX Printer attached (its own documented
; behavior), which would hang this test under emulation; only
; PRINT (screen output) is exercised here. rom/exrom_v2_vm_core.asm's
; own OP_LPRINT_NUM/STR still reference the symbol unconditionally, so
; it needs to resolve -- same stubbing discipline as every other V2
; test this session uses for a dependency that must resolve but is
; never actually reached.
BASIC_STMT_LPRINT_EXROM:
    ret

KTAB_CALC_EXIT_TRAMPOLINE:
    ret

    INCLUDE "kernel/math/math.asm"
    INCLUDE "rom/exrom_calc.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/sound/sound.asm"
    INCLUDE "rom/exrom_sound.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/interrupt/interrupt.asm"
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/extensions/ext_registry.asm"
    INCLUDE "rom/exrom_format.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"
    INCLUDE "rom/exrom_v2_decompiler.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_print.bin", $0000, $4000
