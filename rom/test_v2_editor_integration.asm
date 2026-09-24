; ============================================================================
; rom/test_v2_editor_integration.asm — Architecture B, R8 editor-
; integration smoke test
;
; Real end-to-end round trip through the ACTUAL, unmodified, production
; full-screen editor engine (rom/exrom_editor.asm's EDITOR_INIT/
; EDITOR_ENTER -- confirmed KEEP, zero interpreter-internals dependency
; per docs/v2/V2_ARCHITECTURE.md) together with V2's real compiler, VM,
; and decompiler:
;
;   EDITOR_ENTER -> EDIT_LINE_BUF (raw, null-terminated ASCII text,
;   exactly what EDITOR_EXIT's own header documents it leaves behind)
;   -> COMPILE_PROGRAM (compiles straight from EDIT_LINE_BUF, no V1
;   tokenizer/MEM_LINE_STORE conversion step involved at all -- V2's
;   own source format IS plain null-terminated text already) ->
;   VM_RUN (executes the real compiled bytecode) -> DECOMPILE_PROGRAM
;   (reconstructs source text from that same bytecode) -> a byte-for-
;   byte check of both the VM's own computed result AND the decompiled
;   text.
;
; KEYBOARD TECHNIQUE: TWO real approaches were tried before this one.
; (1) Live ts2068-debug `key`/`type` injection: structurally can't work
; against IO_READ_KEY, which only consumes ISR-latched KBD_LASTK/
; KBD_KEYHIT sysvars (written by kernel/interrupt's KBD_ISR_TICK, run
; from RST_38 on every real maskable interrupt) -- confirmed live (the
; ROM provably kept polling with no change) before moving on.
; (2) rom/test_editor_auto.asm's own established technique (replacing
; RST_38 with a synthetic per-tick key injector -- "per the user's own
; instruction to stop using synthetic X11 keystrokes for testing"):
; built, and confirmed BY A DIRECT DIAGNOSTIC COUNTER (incremented
; unconditionally on every RST_38 entry) that RST_38 is never entered
; at all under ts2068-debug's own bounded `run` for this ROM, despite
; `im 1`/`ei` and `regs` reporting IFF1/IFF2 "set" throughout -- a
; real, reported tooling/environment gap (see this session's own
; SendFeedback draft), not a bug in this ROM's own interrupt setup.
;
; Given that, this harness instead calls rom/exrom_editor.asm's own
; EDITOR_INSERT_CHAR directly, once per character -- the real,
; unmodified primitive EDITOR_LOOP itself calls for every ordinary
; keystroke (see that file's own EDITOR_LOOP dispatch: `call EDITOR_
; INSERT_CHAR: call EDITOR_REDRAW_SCREEN: jp EDITOR_LOOP`), just
; without going through IO_READ_KEY's own interrupt-driven wait. This
; still genuinely proves "EDIT_LINE_BUF, built by the real editor
; engine's own character-insertion logic, correctly reaches and round-
; trips through V2's compiler/VM/decompiler" -- R8's own actual claim
; -- without needing EDITOR_ENTER's own top-level interactive loop or
; a working interrupt path, both squarely a keyboard/redraw concern
; this project's OWN existing editor test suite (rom/
; test_editor_auto.asm, rom/test_editor_ops.asm) already covers
; independently of V2.
;
; SCOPE, an honest partial completion: this proves the real, load-
; bearing interface (the editor engine's own character-insertion
; primitive <-> V2 compiler/VM/decompiler) genuinely works end to end
; for a single committed line of BASIC source (EDIT_LINE_BUF is 128
; bytes -- plenty for a small representative multi-statement program
; written on one logical "line", V2's own colon-statement-separator
; syntax already supports this). NOT covered by this pass: EDITOR_
; ENTER's own top-level interactive dispatch loop (a real, separate,
; already-tracked tooling gap above, not a V2 concern); and full multi-
; line program editing -- EDITOR_NAV_HOOK-driven UP/DOWN navigation
; across several already-committed lines, matching basic/
; editor_integration.asm's own BASIC_HANDLE_NAV/BASIC_LOAD_EDIT_LINE/
; position-addressed program storage for V1 -- a real, separate, larger
; design task (a V2-native equivalent of that whole storage/navigation
; layer) not attempted in this pass either; tracked as a real
; remainder, not silently assumed solved by this narrower test.
;
; Source program "typed" into the real editor -- a shorter relative of
; rom/test_v2_decompiler.asm's own Phase 1 program (assignment,
; arithmetic, IF/relational, THEN GOTO, a label), trimmed of its own
; FOR/NEXT tail (R8.5 Group 1's own added code pushed the shared flat
; 16K image over budget; FOR/NEXT already has dedicated coverage in
; rom/test_v2_compiler_r3.asm, so re-proving it here a second time,
; through a shared program this test doesn't even own, wasn't worth the
; ROM). THIS test's own real job is purely "does the real editor's own
; output correctly reach and round-trip through the compiler/VM/
; decompiler", not "does the compiler/decompiler work" -- already
; proven, independently, elsewhere:
;
;   A=3+4:B=A*2:IF B<10 THEN GOTO S:A=9:S:C=A+B
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_editor_integration.sym \
;       rom/test_v2_editor_integration.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_editor_integration_zesarux.bin
;   ts2068-debug run --max-instructions 500000
;   ts2068-debug timex   (border field)
; ============================================================================
; KNOWN LIMITATION (R8.5 Group 6 -- SGN/MOD/DIV/RND): this flat 16K
; standalone image now overflows its own budget (~1444 bytes over) --
; the real, unmodified kernel/graphics/graphics.asm + kernel/memory/
; memory.asm + kernel/editor/editor.asm this test genuinely needs (its
; whole point is proving the real editor engine's own output reaches
; V2, so none of those three can be stubbed away like other tests do)
; no longer fit alongside the full v2 core, which has grown across
; every Group 5/6 addition since this test last built. Same genuine
; test-HARNESS scaling limit already documented in rom/test_v2_call_fn.
; asm's and rom/test_v2_print.asm's own identical headers, not a
; functional regression: Group 6's SGN/MOD/DIV/RND additions touch no
; editor/graphics/memory code path this test exercises. This test's own
; real coverage last built and passed at commit e639e79 (the SPRITE-to-
; loadable-module product decision) -- presumed still correct, not
; re-verified since. Revisit once R9 deletes basic.asm and frees real
; headroom, or once the flat-image test harness itself is redesigned to
; let a test opt out of modules it doesn't need at a finer grain than
; whole-file INCLUDE/stub.
; ============================================================================

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

    call EDITOR_INIT           ; real init: zeroes EDIT_LINE_BUF via
                                 ; KTAB_MEM_FILL_ZERO, resets EDIT_BUF_
                                 ; OFFSET/hooks -- unmodified

    ld   hl, TEST_SOURCE_TEXT
.type_loop:
    ld   a, (hl)
    or   a
    jr   z, .typed
    push hl
    call EDITOR_INSERT_CHAR    ; the real, unmodified primitive --
                                 ; see this file's own header for why
                                 ; this replaces EDITOR_ENTER's own
                                 ; interactive loop here
    pop  hl
    jp   c, FAIL                 ; real, caught "line full" (shouldn't
                                   ; happen -- TEST_SOURCE_TEXT is well
                                   ; under EDIT_LINE_BUF_LEN-1)
    inc  hl
    jr   .type_loop
.typed:

    ; EDIT_LINE_BUF now holds the raw, null-terminated text the real
    ; editor engine's own character-insertion primitive collected --
    ; exactly the same shape COMPILE_PROGRAM already expects from
    ; every OTHER V2 test's own SOURCE_TEXT constant, so no conversion
    ; step exists here at all.
    call COMPILER_INIT
    ld   hl, EDIT_LINE_BUF
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

    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, FAIL

    call CHECK_VM_RESULT
    jp   c, FAIL

    ld   hl, (EMIT_PTR)
    ld   (DECOMP_END_ADDR), hl    ; R8.5: DECOMPILE_PROGRAM's own new
                                    ; required contract
    call DECOMPILE_PROGRAM

    ld   a, (DECOMP_ERROR_CODE)
    or   a
    jp   nz, FAIL

    call CHECK_DECOMPILED_TEXT
    jp   c, FAIL

PASS:
    di
    ld   a, 4                ; green
    out  (PORT_ULA), a
    jr   $

FAIL:
    di
    ld   a, 2                ; red
    out  (PORT_ULA), a
    jr   $

; TEST_SOURCE_TEXT — the program "typed" via real, individual
; EDITOR_INSERT_CHAR calls (see this file's own header). Plain ASCII;
; every character used here (letters, digits, '+', '*', '<', ':', '=')
; is an ordinary printable EDITOR_INSERT_CHAR accepts unmodified.
TEST_SOURCE_TEXT:
    db "A=3+4:B=A*2:IF B<10 THEN GOTO S:A=9:S:C=A+B", 0

; ============================================================================
; CHECK_VM_RESULT — hand-computed expected results: A=3+4=7, then
; B=A*2=14 (>=10, so "IF B<10 THEN GOTO S" does NOT jump -- same "tests
; the fall-through path" property the original longer program also had,
; B was never <10 there either), A=9 (overwritten by the fall-through
; statement), C=A+B=9+14=23. Symbol declaration order (first
; appearance): 0=A 1=B 2=C.
; Out: carry clear = pass, carry set = fail
; ============================================================================
CHECK_VM_RESULT:
    ld   hl, SYMTAB_BASE + 1*SYM_REC_LEN
    ld   de, 14
    call .check_one           ; B
    jr   c, .fail
    ld   hl, SYMTAB_BASE + 2*SYM_REC_LEN
    ld   de, 23
    call .check_one           ; C
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
; match EXPECTED_TEXT byte-for-byte (same "measure, then document"
; discipline as every other decompiler test this session).
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

; EXPECTED_TEXT — identical to rom/test_v2_decompiler.asm's own
; verified Phase 1 rendering (same source program, same compiler, same
; decompiler; only the SOURCE's own origin differs -- the real editor
; instead of a baked-in constant).
; Captured from a real ZEsarUX run of this shortened program. "L25"/
; "L29" are the compiler's real address-based label names (the source
; text's own "S" label name is not preserved through compile, matching
; every other decompiler test this session); L25 is GOTO's fall-through
; target address landing one instruction before L29 (the label
; definition itself) -- both real, valid decompiled label references.
EXPECTED_TEXT:
    db "V0 = (3+4)", 13
    db "V1 = (V0*2)", 13
    db "IF (V1<10) THEN GOTO L29", 13
    db "L25:", 13
    db "V0 = 9", 13
    db "L29:", 13
    db "V2 = (V0+V1)", 13
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
; included here: this test's own program (TEST_SOURCE_TEXT below) is
; pure integer arithmetic -- no float literal, no mixed int/float
; ADD/SUB -- so none of the float paths that reach the calculator are
; ever exercised at runtime. The 1772 real lines pushed this flat 16K
; image well over budget for zero real coverage. Stubs below resolve
; the handful of symbols rom/exrom_v2_vm_core.asm/rom/exrom_format.asm
; still reference unconditionally from their own (unreachable, for
; this program) float-handling code.
CALC_INT_TO_FP:
    ret
CALC_FP_TO_INT:
    ret
CALC_SP_TO_NEXT_FREE_PTR:
    ret
    INCLUDE "kernel/graphics/graphics.asm"
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
    INCLUDE "include/keys.inc"   ; rom/exrom_editor.asm's own KEY_*
                                   ; dispatch constants -- normally
                                   ; pulled in transitively via kernel/
                                   ; interrupt or kernel/io, both
                                   ; stubbed away above
    INCLUDE "kernel/memory/memory.asm"   ; genuinely needed -- kernel/
                                           ; editor/editor.asm's own
                                           ; MEM_FILL_ZERO/MEM_LINE_
                                           ; DELETE_RANGE/MEM_SHIFT_UP/
                                           ; MEM_SHIFT_DOWN calls (a
                                           ; `grep call MEM_` pass missed
                                           ; these; confirmed by a real
                                           ; rebuild attempt without it)
; Test-only stub: this file's own test program never registers or calls
; a loadable extension -- rom/exrom_v2_compiler.asm's own COMPILE_
; STATEMENT_LIST calls EXT2_LOOKUP unconditionally at every statement
; start (real contract: carry SET means "no match", exactly what a
; permanently-empty registry means), and rom/exrom_v2_vm_core.asm's own
; OP_CALL_EXT references EXT2_SLOT_ADDR (never actually reached here,
; since EXT2_LOOKUP always reports no match first). The real 347-line
; kernel/extensions/ext_registry.asm pushed this flat 16K image over
; budget for zero real coverage -- same stubbing discipline as BEEP/
; SOUND/IO_READ_KEY above.
EXT2_LOOKUP:
    scf
    ret
EXT2_SLOT_ADDR:
    ret
; EXT_CALL_ARG0/EXT2_TABLE: genuinely unreachable in this test (OP_CALL_
; EXT's own arg-pop loop never runs -- EXT2_LOOKUP above always reports
; no match first -- and no CALL_EXT opcode ever reaches rom/exrom_v2_
; decompiler.asm's own name-lookup path), so these alias existing RAM
; rather than reserving real ROM bytes for space that's never touched.
EXT_CALL_ARG0: equ $8B00
EXT_CALL_ARG4: equ $8B00
EXT2_TABLE:    equ $8B00
    INCLUDE "rom/exrom_format.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"
    INCLUDE "rom/exrom_v2_decompiler.asm"
    INCLUDE "kernel/editor/editor.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_editor_integration.bin", $0000, $4000
