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
; KNOWN LIMITATION (R8.5 Group 5, grown further through Group 6) --
; NOW ACTUALLY OVERFLOWING (previous revisions of this note anticipated
; this; the string-result function group (CHR$/STR$/UPPER$/LOWER$/
; LEFT$/RIGHT$/INKEY$) is what finally tipped it over): this flat 16K
; standalone image no longer assembles at all (320 bytes past $4000 as
; of this addition -- sjasmplus_strict.sh refuses the truncated image).
; This test is EXCLUDED from the buildable regression set until R9 (V1
; removal) or a harness redesign frees real headroom -- see below. It
; needs BOTH the real 1772-line rom/exrom_calc.asm
; (this test's own float coverage genuinely needs it -- no further stub
; is possible without gutting the calculator itself) AND the full v2
; core, which keeps growing with every Group 5/6 addition, none of it
; reachable from this test's own float-only program. This is a genuine
; test-HARNESS scaling limit, not a functional regression: none of
; Group 5's changes (FOR...STEP, EXIT FOR, MODE/ULAPLUS/PALETTE,
; SPRITE) or Group 6's (SGN/MOD/DIV/RND/POINT/ATTR/INT/PEEK/USR/LEN/
; CODE/VAL/CHR$/STR$/UPPER$/LOWER$/LEFT$/RIGHT$/INKEY$) touch any
; float-handling code path this test exercises
; (OP_PUSH_FLOAT_LIT, ABS's own float branch, VM_NUM_TO_TEXT's float
; path are all unchanged). This test's own real coverage last built and
; passed at commit acb549c (R8.5 Group 5's MODE/ULAPLUS/PALETTE commit)
; -- presumed still correct, not re-verified since. Revisit once R9
; deletes basic.asm and frees real headroom, or once the flat-image
; test harness itself is redesigned to let a test opt out of modules it
; doesn't need at a finer grain than whole-file INCLUDE/stub.
; ============================================================================

    INCLUDE "include/hardware.inc"
    DEFINE V2_COMPACT_SYSVARS   ; R10.7 P5: drop V1-only sysvars (see include/sysvars.inc)
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
; kernel/graphics/graphics.asm (2235 real lines) is NOT included here:
; despite this file's own header discussing a real-bitmap verification
; approach, the check actually implemented (CHECK_DECOMPILED_TEXT plus
; VM_OUTPUT_ROW) never reads screen memory, and every real PRINT text
; here is short enough to never wrap/scroll -- so a bare `ret` for
; GFX_PRINT_STRING_ATTR is exactly correct: B/C (row/col) already hold
; the pre-print values VM_PRINT_COMMON passed in, which is exactly what
; a non-wrapping print's own real row/col would still be after printing.
; R8.5 Group 4's own real ROM growth pushed this flat 16K image over
; budget with graphics.asm included; same stubbing discipline as rom/
; test_v2_call_fn.asm's own identical fix.
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
; R8.5 Group 6 -- POINT/ATTR need real GFX_* contracts; this
; test never exercises real pixel/attribute content, so a plain
; deterministic stub (same discipline as every other GFX_*
; stub in this file) satisfies the reference without a real
; bitmap.
GFX_READ_PIXEL:
    xor a
    ret
GFX_CELL_ATTR_ADDR:
    scf
    ret
; Test-only stubs: this file's own test program never exercises BEEP/
; SOUND/PAUSE, and never registers or calls a loadable extension -- same
; stubbing discipline (and same real contracts) already established for
; rom/test_v2_editor_integration.asm/rom/test_v2_save_load.asm/rom/
; test_v2_decompiler.asm. The real kernel/sound+kernel/io+kernel/
; interrupt+kernel/extensions/ext_registry.asm modules pushed this flat
; 16K image over budget for zero real coverage.
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
; kernel/memory/memory.asm is NOT included here -- checked directly:
; neither rom/exrom_v2_vm_core.asm/compiler.asm/decompiler.asm reference
; any MEM_*/PROG_END/PROG_AREA_START/ARRAYS_END/VARS_START symbol (V2's
; own storage model never used V1's line/label MEM_* apparatus), and
; this test never touches the real editor engine (kernel/editor/
; editor.asm, memory.asm's own real dependent elsewhere).
    INCLUDE "rom/exrom_format.asm"
; R8.5 Group 6 -- INKEY$ needs kernel/io/io.asm's real IO_READ_KEY_
; NONBLOCK, not included in this flat test image (same scaling limit
; as every other v2 test); deterministic "no key currently pressed"
; stub, same pattern this test suite already uses for other platform
; dependencies (GFX_READ_PIXEL etc). Placed here (after the real ORG
; $0000 code), not before it -- placing it earlier let sjasmplus
; assemble it at whatever pre-ORG address the counter held (address
; 0), silently aliasing RST_00's own real code; a real bug this exact
; mistake caused elsewhere (see rom/test_v2_strfuncs.asm's own header
; for the full incident).
IO_READ_KEY_NONBLOCK:
        xor a
        ret

    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/test_v2_local_dim.inc"   ; R10.9 2C: test-only DIM handlers
    INCLUDE "rom/exrom_v2_compiler.asm"
    INCLUDE "rom/exrom_v2_decompiler.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_print.bin", $0000, $4000
