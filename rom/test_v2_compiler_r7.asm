; ============================================================================
; rom/test_v2_compiler_r7.asm — Architecture B, R7 smoke test
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's R7 additions
; (the graphics/system command family: CLS/BORDER/INK/PAPER/PLOT, plus the
; new TOK_COMMA lexer support PLOT's "x,y" argument list needs) together
; with rom/exrom_v2_vm_core.asm's five new R7 opcodes (OP_CLS/OP_BORDER/
; OP_INK/OP_PAPER/OP_PLOT) — each a real native-call into the existing,
; UNMODIFIED kernel/graphics primitives (GFX_CLS/GFX_SET_BORDER/
; GFX_PAINT_ATTR/GFX_WRITE_PIXEL/GFX_READ_PIXEL), per docs/v2/
; ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's R7 scope ("calling convention
; into existing platform modules, no changes to those modules
; themselves"). NOT wired into the production BASIC dispatch or the
; shipping EXROM build.
;
; Source program compiled and executed:
;
;   INK 6:PAPER 1:CLS:BORDER 2:PLOT 10,20:
;   LINE 30,30 TO 35,30:BEEP 0,100:SOUND 8,10:
;   POKE 38912,77:PAUSE 2:RANDOMISE 42
;
; Exercises Phase 1's five opcodes (INK/PAPER/CLS/BORDER/PLOT — see their
; own original account below) PLUS Phase 2's six (LINE/BEEP/SOUND/POKE/
; PAUSE/RANDOMISE — the real remainder of this ROM's own graphics/system
; statement set, added in the same milestone after the coordinator judged
; the SAVE/LOAD editor-boundary question a genuine R8 problem, not a
; blocker on finishing the rest of R7 mechanically). PAUSE specifically
; needed real interrupts actually running (im 1/ei in COLD_START, a real
; RST $38 vector installed) rather than a stand-in, since it waits on the
; real interrupt-driven FRAMES counter — the one place in R7 needing more
; real setup than "call straight into the existing primitive."
;
; Hand-computed expected results (V1-as-oracle, computed from the real,
; documented algorithms these opcodes call into — GFX_SET_BORDER masks to
; the low 3 bits, VM_COMPUTE_PRINT_ATTR/BASIC_COMPUTE_PRINT_ATTR pack
; paper<<3|ink with no INVERSE/BRIGHT/FLASH set here):
;   CURRENT_INK   = 6
;   CURRENT_PAPER = 1
;   attribute byte everywhere (post-CLS) = (1<<3)|6 = $0E
;   PORT_FE_SHADOW low 3 bits (post-BORDER) = 2
;   pixel (10,20) = SET (1); pixel (0,0) = still CLEAR
;   pixels (30,30) and (35,30) = SET (LINE's own endpoints); pixel
;     (40,30) = still CLEAR (just past the line's own end)
;   SOUND 8,10 -> AY chip register 8 (amplitude, channel A) reads back 10
;   POKE 38912,77 -> byte at $9800 = 77
;   RANDOMISE 42 -> RND_STATE = 42
;   BEEP 0,100 -> not independently checkable at runtime (see
;     CHECK_RESULT's own comment for why, and how its argument order was
;     verified instead)
;
; CHECK_RESULT verifies pixel/AY state WITHOUT ever hand-decoding the
; real (non-linear) Spectrum-style bitmap address formula or the AY
; chip's own internals: it asks the real GFX_READ_PIXEL primitive and
; the real AY hardware register-read directly, the exact same "ask the
; real engine instead of hand-decoding its internal format" pattern R5/
; R6's own float/string verification already established.
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_compiler_r7.sym \
;       rom/test_v2_compiler_r7.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_compiler_r7_zesarux.bin
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
    ; resolve for this whole image to assemble, exactly as rom/
    ; test_v2_compiler_r6.asm's own header explains.
    jp   CALC_EXROM_ENTRY
    DS   $0038 - $, $FF
    ; RST $38 -- the real maskable-interrupt vector (IM1), needed for
    ; real reasons this time, not just to satisfy the assembler: OP_PAUSE
    ; (R7 Phase 2) waits on the real, interrupt-driven FRAMES counter
    ; (kernel/interrupt's KBD_ISR_TICK increments it on every tick) --
    ; without a real ISR actually running, FRAMES would never advance and
    ; a real "PAUSE n" (n>0) test would hang forever waiting for a target
    ; frame count that never arrives. This is the one place in this
    ; milestone genuinely needing more real setup than a stand-in.
    ;
    ; BUG FOUND (real hardware): the first version of this vector was a
    ; plain `jp KBD_ISR_TICK` -- but KBD_ISR_TICK's own real body
    ; (kernel/interrupt/interrupt.asm) ends in a plain `ret`, not `reti`,
    ; and never executes `ei` itself (by design -- it's a subroutine
    ; CALLED by the real vector, not the vector itself; the real
    ; production ROM's own RST_38 wraps it exactly as below). A Z80's
    ; own interrupt hardware clears IFF1 automatically the moment it
    ; accepts a maskable interrupt; nothing re-enables it without an
    ; explicit `ei`. Confirmed live: OP_PAUSE's wait_loop parked forever
    ; (FRAMES stuck at 2, IFF1 reported "clear" by `regs`) after exactly
    ; ONE interrupt ever fired -- the plain-`jp` vector's `ret` returned
    ; control with interrupts permanently disabled, so no second tick
    ; could ever arrive. Fixed by copying rom/test_basic.asm's own real,
    ; already-correct RST_38 pattern (`call .../ ei / reti`) verbatim,
    ; rather than assuming a bare jump was equivalent.
    call KBD_ISR_TICK
    ei
    reti
    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00
    call KBD_ISR_INIT        ; zeroes keyboard state FRAMES itself
                               ; doesn't depend on, but this is the real,
                               ; documented init KBD_ISR_TICK's own
                               ; contract expects before it ever runs
    im   1
    ei                        ; real interrupts now running — needed for
                               ; OP_PAUSE's real frame-wait below, per
                               ; the $0038 vector's own comment above

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
; CHECK_RESULT — VM_ERROR_CODE must be 0, then every real, visible
; platform effect must match the hand-computed V1-oracle values above.
; Out: carry clear = pass, carry set = fail
; ============================================================================
CHECK_RESULT:
    ld   a, (VM_ERROR_CODE)
    or   a
    jr   nz, .fail

    ld   a, (CURRENT_INK)
    cp   6
    jr   nz, .fail

    ld   a, (CURRENT_PAPER)
    cp   1
    jr   nz, .fail

    ld   a, (ATTR_ADDR)       ; any untouched-by-PLOT cell confirms CLS's
                                ; own whole-screen repaint independent of
                                ; PLOT's own single-pixel effect
    cp   $0E
    jr   nz, .fail

    ld   a, (PORT_FE_SHADOW)
    and  $07
    cp   2
    jr   nz, .fail

    ld   b, 10                ; GFX_READ_PIXEL: B=x, C=y -> A=0/1
    ld   c, 20
    call GFX_READ_PIXEL
    cp   1
    jr   nz, .fail

    ld   b, 0                 ; a DIFFERENT pixel must still be clear —
    ld   c, 0                  ; confirms PLOT only set its own pixel,
    call GFX_READ_PIXEL         ; not the whole bitmap
    or   a
    jr   nz, .fail

    ; --- R7 Phase 2: LINE/SOUND/POKE/RANDOMISE (real, checkable state) ---
    ld   b, 30                ; LINE 30,30 TO 35,30 -- a horizontal
    ld   c, 30                  ; segment; both endpoints must be SET
    call GFX_READ_PIXEL
    cp   1
    jr   nz, .fail
    ld   b, 35
    ld   c, 30
    call GFX_READ_PIXEL
    cp   1
    jr   nz, .fail
    ld   b, 40                 ; just past the line's own end -- must
    ld   c, 30                   ; still be clear (confirms LINE only
    call GFX_READ_PIXEL           ; drew its own segment, not beyond it)
    or   a
    jr   nz, .fail

    ld   a, 8                  ; SOUND 8,10 -- read the AY chip's own
    out  (PORT_AY_REG), a        ; register 8 (amplitude, channel A)
    in   a, (PORT_AY_DATA)        ; back to confirm the real write
    cp   10                        ; landed, not a hand-decoded guess
    jr   nz, .fail

    ld   a, ($9800)            ; POKE 38912,77 -- 38912 decimal = $9800,
                                  ; a plain RAM address (TS2068 RAM starts
                                  ; at $4000; this ROM image itself only
                                  ; occupies $0000-$3FFF, so $9800 needs
                                  ; no label/reservation in this file at
                                  ; all -- it's real, always-present RAM,
                                  ; comfortably clear of every VM table/
                                  ; stack (all $8500-$87FF) and the
                                  ; compiled program itself (VM_CODE_BASE
                                  ; $9000, a few hundred bytes at most)
    cp   77
    jr   nz, .fail

    ld   hl, (RND_STATE)       ; RANDOMISE 42 -> MATH_RND_SEED(42) ->
    ld   de, 42                  ; RND_STATE = 42, directly observable
    or   a
    sbc  hl, de
    jr   nz, .fail

    ; BEEP 0,100 is NOT independently verified here: SOUND_BEEP's own
    ; documented contract makes duration=0 an unconditional no-op
    ; ("ld a,d / or e / ret z"), checked before pitch is ever read, so
    ; a real runtime check can't distinguish a correct duration/pitch
    ; argument order from an accidentally-swapped one at these values --
    ; BEEP produces no other persistent, checkable state (it only
    ; toggles a speaker port in real time). Its own opcode's argument
    ; order was instead verified by direct comparison against V1's real
    ; BASIC_STMT_BEEP source (both push duration first, pitch second) --
    ; an honest, documented gap in RUNTIME verification specifically,
    ; not a silently assumed one. PAUSE 2 (between POKE and RANDOMISE in
    ; the program below) is likewise only verified by REACHING this
    ; point at all: OP_PAUSE's real frame-wait loop, using the real
    ; interrupt-driven FRAMES counter (im 1/ei set up in COLD_START),
    ; would leave the VM parked in VM_RUN forever (observable as
    ; VM_HALTED never becoming nonzero within the bounded ts2068-debug
    ; run) if the wait genuinely hung instead of completing.

    ret
.fail:
    scf
    ret

SOURCE_TEXT:
    db 'INK 6:PAPER 1:CLS:BORDER 2:PLOT 10,20:'
    db 'LINE 30,30 TO 35,30:BEEP 0,100:SOUND 8,10:'
    db 'POKE 38912,77:PAUSE 2:RANDOMISE 42', 0

    ; KTAB_CALC_EXIT_TRAMPOLINE — see rom/test_v2_compiler_r6.asm's own
    ; header for the full explanation; unchanged here, still required for
    ; the same reason (RST $28's own literal-stream mechanism, unused by
    ; this test's own program but still compiled into exrom_v2_vm_core.asm).
KTAB_CALC_EXIT_TRAMPOLINE:
    ret

    INCLUDE "kernel/math/math.asm"
    INCLUDE "rom/exrom_calc.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/sound/sound.asm"
    INCLUDE "rom/exrom_sound.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/interrupt/interrupt.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_compiler_r7.bin", $0000, $4000
