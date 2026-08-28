; ============================================================================
; rom/demo_inject.asm — reusable "load a demo program and drop into the
; real interactive editor" harness, Fuse-debugger-injected.
;
; WHY (2026-08-23): same root motivation as rom/test_suite_inject.asm —
; baking a program into the ROM image costs real Home ROM bytes (down
; to 2 free after the Phase 4 dynamic-scalar-pool migration, see docs/
; programmers_reference.md), and a demo meant to show off the system's
; features needs far more room than that, or than tools/fuse_load_
; inject.py's own 255-byte cap (an artifact of ITS verification
; harness's 8-bit compare loop, not a real limit — see that script's
; own header). This sidesteps both: INJECT_POINT below is a stable
; breakpoint (same natural-pause-point technique test_suite_inject.asm
; already uses — MEM_INIT/KBD_ISR_INIT/EI have already run for real by
; then) where tools/fuse_demo_inject.py pokes a program's bytes at
; PROG_AREA_START and sets PROG_END, then lets execution resume
; normally into a REAL `call BASIC_COMMAND_LOOP` — the actual
; interactive editor, not a run-once-and-hang harness. CUR_EDIT_INDEX
; needs no injection: BASIC_COMMAND_LOOP's own cold-boot init already
; recounts the real statements in memory on every entry, regardless of
; how they got there (see its own comment, basic/basic.asm).
;
; From here on this IS the real product, unmodified, with a program
; already sitting in memory exactly as if it had been typed in and
; committed line by line — LIST, RUN, navigate, edit, all work
; normally. Real interrupt-driven keyboard (RST_38 -> KBD_ISR_TICK,
; unlike rom/test_editor_auto.asm's synthetic injector) since this is
; for an actual person to type at afterward, not a scripted sequence.
;
; The maximum program size this can inject is bounded only by real
; available memory (VARS_START - PROG_AREA_START — see include/
; sysvars.inc's own "Scalar variables in the dynamic pool" section for
; why that's the ceiling now, not the fixed PROG_AREA_MAX), currently
; up to 1871 bytes for program text before the program's own arrays/
; scalars start eating into the same pool at runtime.
;
; Since nothing demo-specific is baked into this file, it never needs
; rebuilding per demo — build demo_inject.bin ONCE, reuse it for any
; program; only the tiny .dbg injection script changes.
;
; Build:
;   sjasmplus rom/demo_inject.asm --sym=rom/demo_inject.sym
; Run (needs tools/fuse_demo_inject.py's generated .dbg script — see
; tools/run_demo.sh):
;   fuse --machine ts2068 --rom-ts2068-0 demo_inject.bin \
;        --rom-ts2068-1 exrom.bin --debugger-command "$(cat X.dbg)"
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"
    DEFINE EXROM_JUMPTABLE_HOME_SIDE
    INCLUDE "include/exrom_jumptable.inc"

    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START

    DS   $0028 - $, $FF
RST_28:
    jp   CALC_ENTRY_TRAMPOLINE

    DS   $0038 - $, $FF
RST_38:
    call KBD_ISR_TICK
    ei
    reti

    ORG  KTAB_BASE
    KTAB_LIST
    ASSERT $ <= KTAB_END
    DB   KTAB_MAGIC

    INCLUDE "include/shared_lowrom_data.inc"
    EMIT_SHARED_LOWROM_DATA

    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00
    call MEM_INIT
    call KBD_ISR_INIT
    im   1
    ei

INJECT_POINT:
    ; Fuse breaks here (stable label address, read via --sym) and pokes
    ; the demo program's encoded bytes at PROG_AREA_START and sets
    ; PROG_END, before real execution continues into BASIC_COMMAND_LOOP
    ; below. If no .dbg script is attached, this just boots into the
    ; normal empty editor (PROG_END still PROG_AREA_START from MEM_INIT
    ; above) — harmless, not a hang.
    call BASIC_COMMAND_LOOP          ; never returns — the real
                                     ; interactive editor, program
                                     ; already loaded, ready to LIST/
                                     ; RUN/edit exactly as if typed in

    INCLUDE "basic/basic.asm"
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/math/math.asm"
    INCLUDE "kernel/sound/sound.asm"
    INCLUDE "kernel/interrupt/interrupt.asm"
    INCLUDE "kernel/bank/bank.asm"

    DS   $4000 - $, $FF

    SAVEBIN "demo_inject.bin", $0000, $4000
