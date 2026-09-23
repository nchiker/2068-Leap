; ============================================================================
; rom/test_v2_ext_demo.asm — Architecture B, R7.5 smoke test
;
; Standalone ROM image exercising the new V2-native loadable-extension
; mechanism (kernel/extensions/ext_registry.asm's EXT2_REGISTER/
; EXT2_LOOKUP/EXT2_SLOT_ADDR, rom/exrom_v2_vm_core.asm's new OP_CALL_EXT
; opcode, rom/exrom_v2_compiler.asm's registry-fallback in
; COMPILE_STATEMENT_LIST) end to end — a real demo "extension" registers
; itself, a real V2 program compiled AFTERWARD calls it by name, and the
; V2 VM dispatches through the registry at runtime. Deliberately NOT an
; adapted V1 extension module (rom/extensions/*.asm) — this is a fresh,
; V2-native demo, per the user's own explicit "existing V1 extensions
; may require rebuilding... that is acceptable" direction. NOT wired
; into the production BASIC dispatch or the shipping EXROM build.
;
; Demo extension: TRIADD <a>,<b>,<destaddr> — writes (a+b)'s low byte to
; the given address. Three arguments deliberately, not two — the exact
; shape V1's OWN extension ABI (grammar 0=expr,expr, grammar 1=LINE-
; shaped, grammar 3=expr,expr,expr, each a DIFFERENT special case) could
; only reach via its own CIRCLE-shaped grammar 3; this design handles
; 0-4 args through ONE uniform code path, no special-casing needed.
;
; Source program compiled and executed (AFTER SUM3_INSTALL has already
; registered):
;
;   TRIADD 3,4,38912
;
; Hand-computed expected result: byte at $9800 (38912 decimal — the
; same plain, otherwise-unused RAM address rom/test_v2_compiler_r7.asm's
; own POKE test already used, comfortably clear of every VM table/
; stack/registry workspace) becomes 3+4 = 7.
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_ext_demo.sym \
;       rom/test_v2_ext_demo.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_ext_demo_zesarux.bin
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
    ; RST $28 -- still needed even though this test never exercises a
    ; float opcode: rom/exrom_v2_vm_core.asm is ONE file with R6's float
    ; code still compiled in, so its CALC_* label references must still
    ; resolve for this whole image to assemble.
    jp   CALC_EXROM_ENTRY
    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00

    call EXT2_CLEAR_ALL       ; real cold-init, mirroring V1's own
                                ; EXTENSION_MAGIC reset (see EXT2_CLEAR_
                                ; ALL's own header for why this matters)
    call SUM3_INSTALL
    jp   c, FAIL              ; registration itself failed (shouldn't,
                              ; on a fresh table) — a real, checked
                              ; failure path, not assumed to always work

    call COMPILER_INIT
    ld   hl, SOURCE_TEXT
    ld   (SRC_PTR), hl
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM

    ld   a, (COMPILE_ERROR_CODE)
    or   a
    jp   nz, FAIL

    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN

    call CHECK_RESULT
    jp   c, FAIL

PASS:
    ld   a, 4                ; green
    out  (PORT_ULA), a
    jr   $

FAIL:
    ld   a, 2                ; red
    out  (PORT_ULA), a
    jr   $

; ============================================================================
; CHECK_RESULT — VM_ERROR_CODE must be 0, and $9800 must hold 7 (3+4,
; TRIADD's own real, computed result — not a hand-decoded guess: the
; extension's own exec routine did the add and the write, exactly as it
; would for a real user-loaded module).
; ============================================================================
CHECK_RESULT:
    ld   a, (VM_ERROR_CODE)
    or   a
    jr   nz, .fail
    ld   a, ($9800)
    cp   7
    jr   nz, .fail
    ret
.fail:
    scf
    ret

; ============================================================================
; TRIADD — the demo extension itself. In: EXT_CALL_ARG0=a, EXT_CALL_ARG1=b,
; EXT_CALL_ARG2=destaddr (all real 16-bit values, per this registry's
; own memory-based argument-passing convention — see kernel/extensions/
; ext_registry.asm's own header for why this replaces V1's register-
; passed ABI). Out: (destaddr) = low byte of a+b.
; ============================================================================
SUM3_NAME:
    db "TRIADD", 0

SUM3_EXEC:
    ld   hl, (EXT_CALL_ARG0)
    ld   de, (EXT_CALL_ARG1)
    add  hl, de              ; HL = a+b
    ld   a, l                  ; low byte of the sum
    ld   de, (EXT_CALL_ARG2)    ; DE = destination address (a plain
                                ; VALUE the caller passed, used here AS
                                ; an address — the extension's own job,
                                ; same as any real POKE-shaped routine)
    ex   de, hl                  ; HL = destination address; A (the sum)
                                ; is untouched by ex de,hl
    ld   (hl), a
    ret

SUM3_INSTALL:
    ld   hl, SUM3_NAME
    ld   de, SUM3_EXEC
    ld   b, 3                  ; argcount = 3
    call EXT2_REGISTER
    ret                          ; carry already set/clear correctly by
                                ; EXT2_REGISTER itself — nothing more to
                                ; do here

SOURCE_TEXT:
    db 'TRIADD 3,4,38912', 0

    ; KTAB_CALC_EXIT_TRAMPOLINE -- see rom/test_v2_compiler_r6.asm's own
    ; header for the full explanation; unchanged here.
; Test-only stub: rom/exrom_v2_vm_core.asm's own OP_LPRINT_NUM/STR
; reference the real rom/exrom_printer.asm's BASIC_STMT_LPRINT_EXROM
; unconditionally, but pulling in that whole (real-ZX-printer-
; hardware-facing, ~300-line) file pushed this standalone flat 16K
; test image over budget with no LPRINT coverage to show for it (this
; file's own test program never calls LPRINT). A dedicated PRINT/
; LPRINT test (rom/test_v2_print.asm) includes the real file and
; genuinely exercises it; every other test stubs it, same discipline
; as this file's own existing KTAB_CALC_EXIT_TRAMPOLINE stub just below.
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

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_ext_demo.bin", $0000, $4000
