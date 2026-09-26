; ============================================================================
; rom/test_v2_save_load.asm — Architecture B, R8 SAVE/LOAD hard-gate
; smoke test
;
; R7 explicitly deferred SAVE/LOAD to R8 (docs/v2/ARCHITECTURE_B_
; IMPLEMENTATION_PLAN.md's own R7 section). Investigation this session
; found the clean Architecture B answer: kernel/storage/storage.asm's
; STORAGE_SAVE/STORAGE_LOAD are already a GENERIC raw-byte-block
; transport, not V1-language-core-specific at all -- confirmed from
; their own real interface (STORAGE_SAVE: In: HL=filename ptr, B=
; filename length, IX=DATA POINTER, DE=DATA LENGTH; STORAGE_LOAD: In:
; IX=DESTINATION POINTER, HL=filename ptr, B=filename length, DE=max
; allowed length) and that file's own header ("the payload remains this
; ROM's own structured plain-text program representation... transport
; compatibility therefore does not imply language compatibility").
; V1's own BASIC_DO_SAVE/BASIC_DO_LOAD just happen to point IX at
; PROG_AREA_START with a V1-computed length -- nothing about STORAGE_
; SAVE/LOAD themselves cares what's actually AT that address.
;
; V2's OWN answer, proven here: SAVE the compiled BYTECODE directly
; (IX=VM_CODE_BASE, DE=however many bytes COMPILE_PROGRAM actually
; emitted -- EMIT_PTR-VM_CODE_BASE); LOAD it straight back into VM_
; CODE_BASE, ready to VM_RUN immediately with NO recompile step at all.
; LIST/EDIT after a LOAD decompiles on demand, same as any other
; freshly-compiled program -- SAVE/LOAD never touch source text, matching
; docs/v2/REWRITE_RAM_BUDGET.md's own Option 2 (bytecode-primary storage)
; extended naturally from RAM to persistent storage too. This reuses the
; REAL, unmodified, real-ROM-verified STORAGE_SAVE/STORAGE_LOAD --
; genuinely "reuse mature tape/storage primitives underneath a new V2-
; facing interface", not a new storage mechanism.
;
; TEST TECHNIQUE: kernel/storage's own established deterministic test
; substitution (rom/exrom_storage_test.asm's STORAGE_TEST_FAKE_SEND/
; STORAGE_TEST_FAKE_RECEIVE + STORAGE_TEST_ROUNDTRIP) replaces the real
; tape-pulse send/receive routines with an instant RAM-to-RAM capture/
; replay -- STORAGE_SAVE/STORAGE_LOAD's own header search, filename
; matching, type checking, and state transitions all execute completely
; unmodified; only the audio-pulse timing loop is substituted, the same
; technique rom/test_storage_named_load.asm already validates this
; primitive with.
;
; Round trip validated:
;   EDIT (compile a program) -> SAVE (real STORAGE_SAVE, fake transport)
;   -> CLEAR (overwrite VM_CODE_BASE with garbage, so LOAD can't
;   accidentally "pass" by leaving stale correct bytes behind) -> LOAD
;   (real STORAGE_LOAD, fake transport) -> LIST/EDIT (DECOMPILE_PROGRAM)
;   -> RUN (VM_RUN on the loaded bytecode) -- both the decompiled text
;   and the VM's own computed result checked byte-for-byte against a
;   real captured-then-verified expectation.
;
; Source program (same one rom/test_v2_decompiler.asm's own Phase 1
; test and rom/test_v2_editor_integration.asm both already validated
; the compiler/VM/decompiler against in isolation -- reused here so
; THIS test's own job is purely "does SAVE/LOAD correctly preserve
; compiled bytecode", not re-proving the compiler/decompiler):
;
;   A=3+4:B=A*2:IF B<10 THEN GOTO SKIP:A=999:SKIP:C=0:FOR I=1 TO 3:
;   C=C+I:NEXT I
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_save_load.sym \
;       rom/test_v2_save_load.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_save_load_zesarux.bin
;   ts2068-debug run --max-instructions 500000
;   ts2068-debug timex   (border field)
; ============================================================================

    DEFINE STORAGE_TEST_FAKE_SEND
    DEFINE STORAGE_TEST_FAKE_RECEIVE
    DEFINE STORAGE_TEST_ROUNDTRIP

; TEST_PROGRAM_LEN must NOT be plain ROM-resident DW data (this test's
; own first draft made exactly that mistake): $0000-$3FFF is the real,
; write-protected Home ROM image in this same flat-build convention
; every other file in this project's own suite already uses -- writes
; there silently do nothing (confirmed live: `ld (addr),hl` followed
; immediately by reading the same address back showed 0, not the value
; just stored). $9800 matches rom/test_v2_ext_demo.asm's own already-
; established "confirmed clear of every VM table/stack/registry
; workspace" scratch address, comfortably above VM_CODE_BASE's own
; small compiled program here.
TEST_PROGRAM_LEN: equ $9800

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"


    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START
    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00

    ; ---- EDIT: compile the source program ----
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
    ld   de, VM_CODE_BASE
    or   a
    sbc  hl, de
    ld   (TEST_PROGRAM_LEN), hl          ; real compiled length

    ; ---- SAVE: real STORAGE_SAVE, fake transport ----
    xor  a
    ld   (STORAGE_REQUEST_TYPE), a        ; STORAGE_PROGRAM_TYPE
    ld   hl, TEST_FILENAME
    ld   b, TEST_FILENAME_LEN
    ld   ix, VM_CODE_BASE
    ld   de, (TEST_PROGRAM_LEN)
    call STORAGE_SAVE

    ; ---- CLEAR: overwrite VM_CODE_BASE so a "pass" can't be a no-op ----
    ld   hl, VM_CODE_BASE
    ld   de, VM_CODE_BASE + 1
    ld   bc, 511
    ld   (hl), $FF
    ldir

    ; ---- LOAD: real STORAGE_LOAD, fake transport ----
    xor  a
    ld   (STORAGE_REQUEST_TYPE), a
    ld   ix, VM_CODE_BASE
    ld   hl, 0                            ; wildcard filename (B=0)
    ld   b, 0
    ld   de, $1000                        ; generous max length
    call STORAGE_LOAD
    jp   c, FAIL                           ; real, caught LOAD failure

    ld   hl, (TEST_PROGRAM_LEN)
    or   a
    sbc  hl, de                            ; DE = actual length LOAD
                                             ; reported; must match what
                                             ; was really compiled
    jp   nz, FAIL

    ; ---- LIST/EDIT: decompile the loaded bytecode ----
    ld   hl, VM_CODE_BASE
    ld   de, (TEST_PROGRAM_LEN)
    add  hl, de
    ld   (DECOMP_END_ADDR), hl    ; R8.5: DECOMPILE_PROGRAM's own new
                                    ; required contract
    call DECOMPILE_PROGRAM

    ld   a, (DECOMP_ERROR_CODE)
    or   a
    jp   nz, FAIL

    call CHECK_DECOMPILED_TEXT
    jp   c, FAIL

    ; ---- RUN: execute the loaded bytecode ----
    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN

    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, FAIL

    call CHECK_VM_RESULT
    jp   c, FAIL

PASS:
    ld   a, 4                ; green
    out  (PORT_ULA), a
    jr   $

FAIL:
    ld   a, 2                ; red
    out  (PORT_ULA), a
    jr   $

TEST_FILENAME: db "V2TEST"
TEST_FILENAME_LEN: equ $-TEST_FILENAME

SOURCE_TEXT:
    db "A=3+4:B=A*2:IF B<10 THEN GOTO SKIP:A=999:SKIP:C=0:FOR I=1 TO 3:"
    db "C=C+I:NEXT I", 0

; ============================================================================
; CHECK_VM_RESULT — same hand-computed expected results as rom/
; test_v2_decompiler.asm's own Phase 1 program.
; Out: carry clear = pass, carry set = fail
; ============================================================================
CHECK_VM_RESULT:
    ld   hl, SYMTAB_BASE + 1*SYM_REC_LEN
    ld   de, 14
    call .check_one           ; B
    jr   c, .fail
    ld   hl, SYMTAB_BASE + 2*SYM_REC_LEN
    ld   de, 6
    call .check_one           ; C
    jr   c, .fail
    ld   hl, SYMTAB_BASE + 3*SYM_REC_LEN
    ld   de, 4
    call .check_one           ; I
    ret
.fail:
    scf
    ret
.check_one:
    ld   a, (hl)
    cp   TAG_INT
    jr   nz, .co_fail
    inc  hl
    push de
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ex   de, hl
    pop  de
    or   a
    sbc  hl, de
    ret  z
.co_fail:
    scf
    ret

; ============================================================================
; CHECK_DECOMPILED_TEXT — the reconstructed text at DECOMP_OUT_BUF must
; match EXPECTED_TEXT byte-for-byte.
; Out: carry clear = pass, carry set = fail
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

EXPECTED_TEXT:
    db "V0 = (3+4)", 13
    db "V1 = (V0*2)", 13
    db "IF (V1<10) THEN GOTO L30", 13
    db "L25:", 13
    db "V0 = 999", 13
    db "L30:", 13
    db "V2 = 0", 13
    db "FOR V3 = 1 TO 3 STEP 1", 13   ; R8.5 Group 5 -- FOR always
                                        ; renders STEP now, even for a
                                        ; STEP-less FOR (compiles a
                                        ; literal step of 1); real
                                        ; captured text
    db "V2 = (V2+V3)", 13
    db "NEXT V3", 13
EXPECTED_TEXT_LEN: equ $-EXPECTED_TEXT

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
; rom/exrom_calc.asm (1772 lines -- the real calculator engine) is NOT
; included here: this test's own program (SOURCE_TEXT below) is pure
; integer arithmetic -- no PUSH_FLOAT_LIT, no mixed int/float ADD/SUB,
; no PRINT of a float -- so none of the float paths that reach the
; calculator are ever exercised at runtime. The 1772 real lines pushed
; this flat 16K image well over budget for zero real coverage. Stubs
; below resolve the handful of symbols rom/exrom_v2_vm_core.asm/rom/
; exrom_format.asm still reference unconditionally from their own
; (unreachable, for this program) float-handling code.
CALC_INT_TO_FP:
    ret
CALC_FP_TO_INT:
    ret
CALC_SP_TO_NEXT_FREE_PTR:
    ret
; kernel/graphics/graphics.asm (2235 real lines) is NOT included here:
; this test never checks real screen bitmap content. R8.5 Group 5's
; own real ROM growth pushed this flat 16K image over budget with
; graphics.asm included; same stubbing discipline as rom/
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
; Test-only stubs: neither this file's own test program nor its
; purpose exercises BEEP/SOUND -- rom/exrom_v2_vm_core.asm's own
; OP_BEEP/OP_SOUND still reference these unconditionally (same class
; of dependency as the LPRINT stub above), and the real kernel/sound
; module pushed this flat 16K image over budget for zero real coverage.
SOUND_BEEP:
    ret
SOUND_EXROM:
    or a
    ret
; Test-only stubs: rom/exrom_v2_vm_core.asm's own OP_PAUSE references
; IO_READ_KEY/INT_GET_FRAMES unconditionally, but this file's own test
; program never uses PAUSE (and, for the editor-integration test,
; EDITOR_LOOP's own real key-read path is deliberately bypassed too --
; see this file's own header). Same stubbing discipline as LPRINT/
; BEEP/SOUND above.
IO_READ_KEY:
    xor a
    ret
INT_GET_FRAMES:
    ld hl,0
    ret
; Test-only stub: this file's own test program never registers or calls
; a loadable extension -- same stubbing discipline as above (real
; contract: EXT2_LOOKUP's carry SET means "no match", exactly what a
; permanently-empty registry means; see rom/test_v2_editor_integration.
; asm's own identical stub for the full rationale).
EXT2_LOOKUP:
    scf
    ret
EXT2_SLOT_ADDR:
    ret
EXT_CALL_ARG0: equ $8B00
EXT_CALL_ARG4: equ $8B00
EXT2_TABLE:    equ $8B00
; kernel/memory/memory.asm is NOT included here -- checked directly:
; neither rom/exrom_v2_vm_core.asm/compiler.asm/decompiler.asm nor
; kernel/storage/storage.asm/rom/exrom_storage_test.asm reference any
; MEM_*/PROG_END/PROG_AREA_START/ARRAYS_END/VARS_START symbol, and this
; test never touches the real editor engine (kernel/editor/editor.asm,
; memory.asm's own real dependent elsewhere).
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
    INCLUDE "rom/exrom_v2_compiler.asm"
    INCLUDE "rom/exrom_v2_decompiler.asm"
    INCLUDE "kernel/storage/storage.asm"
    INCLUDE "rom/exrom_storage_test.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_save_load.bin", $0000, $4000
