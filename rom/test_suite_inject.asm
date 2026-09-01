    DEFINE FULL_ENGINE_PRESENT
; ============================================================================
; rom/test_suite_inject.asm — reusable regression-suite harness, Fuse-
; debugger-injected instead of preload_gen.py's baked-in-ROM approach.
;
; WHY (2026-08-23): preload_gen.py's --autorun harness embeds the whole
; encoded test program as a PRELOAD_DATA block INSIDE the same 16K ROM
; image as all of basic.asm — after the Phase 4 dynamic-scalar-pool
; migration (see docs/programmers_reference.md's "sysvars.inc:
; assembler-computed addresses" and the scalar-pool sections),
; individual test_suite_*.asm builds ran 83-113 bytes over budget even
; though basic.asm itself still fits rom/test_basic.asm exactly. The
; fix isn't shrinking basic.asm further — the PRELOAD_DATA payload
; itself is the actual cost, and it doesn't need to live in the ROM
; image at all: tools/fuse_load_inject.py already proved (Track A of
; the SAVE/LOAD reliability plan) that Fuse's --debugger-command can
; poke arbitrary bytes into RAM at a breakpoint with zero ROM changes.
; This harness applies that same technique to the whole regression
; suite, not just SAVE/LOAD: INJECT_POINT below is a stable breakpoint
; address (same "fixed trampoline" reasoning EXROM_ENTRY_LOAD/SAVE and
; COLD_START itself already rely on) where MEM_COLD_INIT/MEM_INIT/KBD_ISR_INIT/EI
; have ALREADY run for real, and the NEXT instruction is a REAL,
; properly stack-balanced `call BASIC_RUN` — tools/fuse_suite_inject.py
; generates a .dbg script that pokes the test program's bytes at
; PROG_AREA_START, sets PROG_END/CUR_EDIT_INDEX, then lets execution
; resume normally into that real call. No PC redirection, no stack
; surgery — the breakpoint only ever injects DATA at a natural pause
; point, never skips or redirects code, so there's nothing to get
; subtly wrong here the way faking a routine's own return contract
; (fuse_load_inject.py's LOAD/SAVE short-circuit) would risk.
;
; Since NOTHING test-specific is baked into this file any more, it
; never needs rebuilding per test — build test_suite_inject.bin ONCE,
; reuse it for every fixture; only the tiny .dbg injection script
; changes per test. Same COLD_START/INCLUDE shape as rom/test_basic.asm
; and preload_gen.py's own HARNESS_TEMPLATE, with RUN_TAIL_AUTORUN's
; own two-layer border-color convention (yellow = whole-program check
; failed and BASIC_RUN never ran the program at all; otherwise whatever
; the program's own BORDER statement last set is the real verdict) —
; see preload_gen.py's own --autorun doc for the fuller writeup of that
; convention, unchanged here.
;
; Build:
;   sjasmplus rom/test_suite_inject.asm
; Run (needs tools/fuse_suite_inject.py's generated .dbg script — see
; tools/run_suite_test.sh, updated to use this harness):
;   fuse --machine ts2068 --rom-ts2068-0 test_suite_inject.bin \
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
    call MEM_COLD_INIT
    call MEM_INIT
    ; No fixture accepts keyboard input. MEM_COLD_INIT already leaves the
    ; interrupt-owned state safely zeroed, so the interactive ROM's explicit
    ; KBD_ISR_INIT call is unnecessary here. Omitting it also keeps this
    ; run-once harness within the production ROM's now one-byte margin.
    ; The two-pass RUN-state fixture performs no keyboard or timing work and
    ; exits by its border verdict, so it can leave interrupts disabled.  This
    ; also gives its extra `call BASIC_RUN` enough harness-only ROM space now
    ; that the production image has only a one-byte margin.
    IFNDEF RUN_STATE_TEST
    im   1
    ei
    ENDIF

    IFDEF STACK_AUDIT
    ; Canary the entire currently documented machine-stack headroom.
    ; The scan after BASIC_RUN records the first byte touched.
    ld   hl, $F600
    ld   bc, $FF00 - $F600
    ld   a, $A5
.stack_fill:
    ld   (hl), a
    inc  hl
    dec  bc
    ld   a, b
    or   c
    ld   a, $A5
    jr   nz, .stack_fill
    ENDIF

INJECT_POINT:
    ; Fuse breaks here (a stable label address, read via --sym the same
    ; "read live, don't hardcode" way tools/fuse_load_inject.py already
    ; reads PROG_AREA_START/STORAGE_OP_STATE/etc.) and pokes the test
    ; program's encoded bytes at PROG_AREA_START, PROG_END, and CUR_
    ; EDIT_INDEX here — matching exactly what preload_gen.py's own
    ; --autorun COLD_START does with a real `ldir` + two stores, just
    ; done via the debugger instead of baked-in ROM data. If no .dbg
    ; script is attached, this runs an EMPTY program (PROG_END still
    ; PROG_AREA_START from MEM_INIT above) — BASIC_RUN just returns
    ; immediately, harmless, not a hang.
    IFDEF TEST_RAM_EXTENSION
    call EXTENSION_MODULE_BASE       ; debugger has injected installer here
    IFDEF TEST_RAM_EXTENSION_CLEAR
    call MEM_INIT                    ; prove NEW/cold reset unregisters it
    ENDIF
    ENDIF
    call BASIC_RUN                   ; real call — properly balances
                                     ; whatever happens after MEM_INIT,
                                     ; no debugger stack manipulation
                                     ; needed at all. Unlike preload_
                                     ; gen.py's own --autorun tail, this
                                     ; does NOT check CHECK_ERROR_COUNT
                                     ; for a separate yellow "whole-
                                     ; program check failed" signal —
                                     ; a deliberate simplification (this
                                     ; is dev tooling, not shipped
                                     ; product, and every regression
                                     ; fixture is a hand-verified,
                                     ; already-passing program) to keep
                                     ; this harness's own Home ROM cost
                                     ; near zero; a real check failure
                                     ; here just leaves the border
                                     ; unset (cold-boot default) instead
                                     ; of a distinct yellow — still
                                     ; visibly different from any real
                                     ; fixture's own expected verdict
    IFDEF RUN_STATE_TEST
    call BASIC_RUN                   ; dedicated fixture deliberately runs
                                     ; the same program twice to catch state
                                     ; leaked across BASIC_RUN boundaries
    ENDIF
    IFDEF STACK_AUDIT
    ld   hl, $F600
.stack_scan:
    ld   a, (hl)
    cp   $A5
    jr   nz, .stack_found
    inc  hl
    ld   a, h
    cp   $FF
    jr   nz, .stack_scan
.stack_found:
    ld   (STORAGE_ENTRY_RETRY), hl
    ENDIF
.hang:
    jr   .hang                       ; leave whatever border color the
                                     ; program itself last set via its
                                     ; own BORDER statement — the
                                     ; verdict, same convention as
                                     ; everywhere else in this suite

    INCLUDE "basic/basic.asm"
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/math/math.asm"
    INCLUDE "kernel/sound/sound.asm"
    INCLUDE "kernel/interrupt/interrupt.asm"
    INCLUDE "kernel/bank/bank.asm"

    DS   $4000 - $, $FF

    IFDEF RUN_STATE_TEST
        SAVEBIN "test_run_state_inject.bin", $0000, $4000
    ELSE
    IFDEF STACK_AUDIT
        SAVEBIN "test_stack_audit.bin", $0000, $4000
    ELSE
        IFDEF TEST_RAM_EXTENSION
            IFDEF TEST_RAM_EXTENSION_CLEAR
                SAVEBIN "test_extension_clear_inject.bin", $0000, $4000
            ELSE
                SAVEBIN "test_extension_inject.bin", $0000, $4000
            ENDIF
        ELSE
            SAVEBIN "test_suite_inject.bin", $0000, $4000
        ENDIF
    ENDIF
    ENDIF
