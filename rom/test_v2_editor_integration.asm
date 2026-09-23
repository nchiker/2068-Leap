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
; Source program "typed" (queued, see TEST_KEY_QUEUE) into the real
; editor -- the SAME program rom/test_v2_decompiler.asm's own Phase 1
; test already validated the compiler/VM/decompiler against in
; isolation, reused here so THIS test's own job is purely "does the
; real editor's own output correctly reach and round-trip through
; them", not "does the compiler/decompiler work", already proven
; elsewhere:
;
;   A=3+4:B=A*2:IF B<10 THEN GOTO SKIP:A=999:SKIP:C=0:FOR I=1 TO 3:
;   C=C+I:NEXT I
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_editor_integration.sym \
;       rom/test_v2_editor_integration.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_editor_integration_zesarux.bin
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
    db "A=3+4:B=A*2:IF B<10 THEN GOTO SKIP:A=999:SKIP:C=0:FOR I=1 TO 3:C=C+I:NEXT I", 0

; ============================================================================
; CHECK_VM_RESULT — same hand-computed expected results as rom/
; test_v2_decompiler.asm's own Phase 1 program (identical source):
; B=(3+4)*2=14, C=0+1+2+3=6, I=4 (one past FOR's own limit of 3).
; Symbol declaration order (first appearance): 0=A 1=B 2=C 3=I.
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
EXPECTED_TEXT:
    db "V0 = (3+4)", 13
    db "V1 = (V0*2)", 13
    db "IF (V1<10) THEN GOTO L30", 13
    db "L25:", 13
    db "V0 = 999", 13
    db "L30:", 13
    db "V2 = 0", 13
    db "FOR V3 = 1 TO 3", 13
    db "V2 = (V2+V3)", 13
    db "NEXT V3", 13
EXPECTED_TEXT_LEN: equ $-EXPECTED_TEXT

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
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"
    INCLUDE "rom/exrom_v2_decompiler.asm"
    INCLUDE "kernel/editor/editor.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_editor_integration.bin", $0000, $4000
