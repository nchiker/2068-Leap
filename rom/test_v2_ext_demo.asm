; ============================================================================
; rom/test_v2_ext_demo.asm — Architecture B, R7.5 smoke test
;
; Exercises the V2-native loadable-extension mechanism (kernel/
; extensions/ext_registry.asm's EXT2_REGISTER/EXT2_LOOKUP/EXT2_SLOT_ADDR,
; rom/exrom_v2_vm_core.asm's OP_CALL_EXT opcode, rom/exrom_v2_compiler.
; asm's registry-fallback in COMPILE_STATEMENT_LIST) end to end — a real
; demo "extension" registers itself, a real V2 program compiled
; AFTERWARD calls it by name, and the V2 VM dispatches through the
; registry at runtime. Deliberately NOT an adapted V1 extension module
; (rom/extensions/*.asm) — this is a fresh, V2-native demo. NOT wired
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
; Hand-computed expected result: byte at $9800 (38912 decimal) becomes
; 3+4 = 7.
;
; Dynamic Data Phase 2 migration: this test used to be its own flat,
; single-bank 16K image (the SAME artificial-ceiling problem rom/
; test_v2_harness_home_head.inc's own header documents for the 14 tests
; already migrated post-R9) -- the string-array work grew vm_core+
; compiler enough to overflow it by 190 bytes with zero TRIADD-relevant
; content to show for the extra budget. Migrated onto the SAME shared
; production-shaped two-bank harness rom/test_v2_shapes_circle.asm/rom/
; test_v2_graphics_module.asm already use for an EXT2-registry-needing
; test (that harness has no EXT2 presence of its own -- kernel/
; extensions/ext_registry.asm is pulled in explicitly below, same as
; those two). No change to the real TRIADD/SUM3 test logic itself.
; ============================================================================

    DEFINE TEST_V2_CUSTOM_CHECKS
    INCLUDE "rom/test_v2_harness_home_head.inc"

DECOMP_END_ADDR: equ $9900   ; this test never includes the decompiler
                               ; (compile+run only); COMPILE_PROGRAM
                               ; still unconditionally sets this

TEST_CUSTOM_MAIN:
    call EXT2_CLEAR_ALL
    call SUM3_INSTALL
    jp   c, TEST_FAIL          ; registration itself failed (shouldn't,
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
    jp   nz, TEST_FAIL

    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN

    call CHECK_RESULT
    jp   c, TEST_FAIL

    jp   TEST_PASS

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
    ld   c, 0                  ; argtypes = 0 (all-numeric) -- EXT2_
                                ; REGISTER's own typed-argument parameter;
                                ; TRIADD has no string arguments
    jp   EXT2_REGISTER          ; carry already set/clear correctly by
                                  ; EXT2_REGISTER itself

SOURCE_TEXT:
    db 'TRIADD 3,4,38912', 0

; Test-only stubs: this file's own test program never exercises PRINT/
; LPRINT/BEEP/SOUND/PAUSE/INPUT/arrays, and never checks real screen
; bitmap content -- only EXT2 registry reachability is in scope here
; (same discipline rom/test_v2_shapes_circle.asm's own stub block
; already established).
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
GFX_READ_PIXEL:
    xor a
    ret
GFX_CELL_ATTR_ADDR:
    scf
    ret
; kernel/memory/memory.asm is NOT included here -- but EXT2_CLEAR_ALL
; (kernel/extensions/ext_registry.asm) genuinely calls its real
; MEM_FILL_ZERO to zero the registry table, so that one routine needs a
; real (not no-op) stub: fills BC bytes at HL with zero, matching its
; real In:HL=dest,BC=count contract exactly (same stub rom/test_v2_
; shapes_circle.asm/rom/test_v2_dynamic_arrays.asm already use).
    INCLUDE "kernel/extensions/ext_registry.asm"
    INCLUDE "rom/exrom_format.asm"
IO_READ_KEY_NONBLOCK:
        xor a
        ret

    INCLUDE "rom/test_v2_harness_home_tail.inc"
