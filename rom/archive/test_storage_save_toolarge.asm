; ============================================================================
; rom/test_storage_save_toolarge.asm — SAVE-too-large regression test.
;
; Real product code throughout, no Track A injection needed: STORAGE_
; SAVE's own size check (kernel/storage/storage.asm) runs and returns
; BEFORE any DI/pilot-tone/pulse code — it's a plain register compare
; against STORAGE_BLOCK_MAX_COUNT*STORAGE_BLOCK_SIZE (127*128=16256
; bytes), completely independent of tape timing, so this is fast and
; 100% deterministic without any debugger short-circuit.
;
; Directly relevant to a future dynamic-memory-pool migration: this
; exercises the exact PROG_AREA_MAX-adjacent boundary arithmetic
; (`cp $3F` / `cp $81` against D/E in STORAGE_SAVE) that a pool
; migration would need to preserve or deliberately change. PROG_END is
; poked directly to PROG_AREA_START+16257 (one byte over the limit) —
; building a real 16257-byte BASIC program would need a fixture
; thousands of characters long, which buys nothing a direct poke
; doesn't already prove for this specific boundary check.
;
; Verdict: green if SAVE correctly reports STORAGE_OP_STATE=7 (SAVE
; FAILED - TOO LARGE) and refuses to send anything; red otherwise
; (accepted an oversized program, or failed for the wrong reason).
;
; Build:
;   sjasmplus rom/test_storage_save_toolarge.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_storage_save_toolarge.bin --rom-ts2068-1 exrom.bin
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

    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00
    call MEM_INIT

    ; one byte over STORAGE_SAVE's own 16256-byte cap (STORAGE_BLOCK_
    ; MAX_COUNT*STORAGE_BLOCK_SIZE, kernel/storage/storage.asm) — never
    ; actually written, PROG_END is all STORAGE_SAVE looks at to derive
    ; the length it checks
    ld   hl, PROG_AREA_START + 16257
    ld   (PROG_END), hl

    ld   hl, SAVE_CMD_TEXT
    call BASIC_DO_SAVE

    ld   a, (STORAGE_OP_STATE)
    cp   7                         ; 7 = SAVE FAILED (too large)
    jr   nz, .fail

    ld   a, 4                      ; green — pass
    jr   .done
.fail:
    ld   a, 2                      ; red — fail
.done:
    out  (PORT_ULA), a
    jr   $

SAVE_CMD_TEXT: DB '"TEST"', 0

    INCLUDE "basic/basic.asm"
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/math/math.asm"
    INCLUDE "kernel/sound/sound.asm"
    INCLUDE "kernel/interrupt/interrupt.asm"
    INCLUDE "kernel/bank/bank.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_storage_save_toolarge.bin", $0000, $4000
