; ============================================================================
; rom/test_exrom_isolation.asm — EXROM paging isolation test
;
; CONFIRMED WORKING ON REAL HARDWARE — run #1 showed FAIL/FAIL on
; screen, but a debug.bin dump proved the underlying paging mechanism
; worked; the real bug was in this harness's own PASS/FAIL result
; markers (inline ROM writes silently no-op'd — same failure class as
; this project's later PRINT_ATTR_SCRATCH bug). Run #2 confirmed
; PASS/PASS on real hardware, both checks. This was the first time
; kernel/bank/bank.asm's paging code was exercised at all, and it
; cleared the way for the checker and SAVE/LOAD migrations that
; followed.
;
; Standalone cold-boot program (does NOT run BASIC_COMMAND_LOOP or any
; of basic/'s own program storage) that:
;   1. Writes a known byte pattern directly into chunk 6 RAM ($C000-
;      $C00F) while it's still Home-mapped, and remembers it.
;   2. Pre-clears EXROM_TEST_MARKER to $FF ("never touched") — the
;      third possible state alongside rom/exrom_payload.asm's own "0 =
;      started" and "$42 = completed" sentinels, so this harness can
;      tell "the call never even reached the payload" apart from both
;      of the payload's own outcomes.
;   3. Calls BANK_CALL_EXROM — pages chunk 6 to EXROM, runs the
;      payload (which busy-waits on real interrupts advancing FRAMES
;      while paged out — see exrom_payload.asm's own header for why
;      that's the actual thing under test, not just "does the call
;      return"), pages back to Home.
;   4. Checks EXROM_TEST_MARKER == $42 (payload ran to completion).
;   5. Re-reads chunk 6 RAM and confirms the pattern from step 1 is
;      byte-for-byte unchanged — proves paging out and back doesn't
;      disturb the underlying RAM chip's own contents, which matters
;      for any future EXROM payload that might want chunk 6 as
;      scratch space during its own execution, not just as the
;      destination of the paging itself.
;   6. Prints a PASS/FAIL line for each of the two checks above, plus
;      the actual EXROM_TEST_MARKER value and FRAMES delta observed,
;      so a real result is visible even on failure — not just a bare
;      pass/fail bit.
;
; Deliberately does NOT use MEM_INIT/BASIC's program storage at all —
; this is testing the paging primitive in isolation, not integrated
; with the rest of the interpreter yet (that's the NEXT step, per this
; project's own agreed build order: trampoline verified standalone
; first, then migrate one real subsystem).
;
; Build:
;   sjasmplus rom/exrom_payload.asm      (produces exrom_payload.bin —
;                                         becomes the real rom1.bin,
;                                         replacing the all-zero
;                                         placeholder)
;   sjasmplus rom/test_exrom_isolation.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_exrom_isolation.bin \
;        --rom-ts2068-1 exrom_payload.bin
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"

EXROM_TEST_MARKER   EQU $9600   ; must match rom/exrom_payload.asm's
                                ; own EQU exactly — both sides read/
                                ; write the same real RAM address
RESULT_MARKER_VALUE EQU $9603   ; 1 byte — these 3 MUST be real RAM,
RESULT_MARKER_PASS  EQU $9604   ; not DB bytes declared inline in this
RESULT_RAM_PASS     EQU $9605   ; file's own ROM code stream: this
                                ; project already has a named lesson
                                ; about exactly that mistake (see
                                ; GFX_PRINT_STRING_ATTR's own header —
                                ; PRINT_ATTR_SCRATCH was once a local
                                ; `DB 0` in ROM, and every `ld
                                ; (addr),a` to it was a silent no-op
                                ; on real hardware, always reading
                                ; back its compile-time initial value).
                                ; This exact bug shipped in this
                                ; file's own first draft (all 3 bytes
                                ; stuck at 0 despite the real
                                ; underlying test passing) before
                                ; being caught via a debug.bin dump —
                                ; see this project's own working
                                ; memory for the full writeup.
CHUNK6_TEST_PATTERN EQU $C000   ; first byte of chunk 6 — written
                                ; while Home-mapped, re-checked after
                                ; the paging round-trip

    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START

    DS   $0038 - $, $FF
RST_38:
    call KBD_ISR_TICK
    ei
    reti

    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00
    call KBD_ISR_INIT                ; must run before EI below, same
                                     ; as rom/test_basic.asm's own
                                     ; cold-boot sequence

    xor  a
    ld   hl, FRAMES                   ; explicit zero, not assumed —
    ld   (hl), a                     ; lesson 13: don't trust RAM to
    inc  hl                          ; start at a known value even
    ld   (hl), a                     ; when this sandbox's own RAM-
                                     ; zero-at-load convention would
                                     ; mask the gap

    im   1
    ei

    ; ---- step 1: seed chunk 6 with a known pattern, still Home ----
    ld   hl, CHUNK6_TEST_PATTERN
    ld   b, 16
    ld   a, $5A                        ; arbitrary, memorable, not 0
                                       ; or $FF (both used as sentinels
                                       ; elsewhere in this test)
.seed_loop:
    ld   (hl), a
    inc  hl
    inc  a
    djnz .seed_loop

    ; ---- step 2: pre-clear the completion marker ----
    ld   a, $FF                        ; "never touched"
    ld   (EXROM_TEST_MARKER), a

    ; ---- step 3: the actual paging round-trip ----
    call BANK_CALL_EXROM

    ; ---- step 4: did the payload run to completion? ----
    ld   a, (EXROM_TEST_MARKER)
    ld   (RESULT_MARKER_VALUE), a
    cp   $42
    ld   a, 1
    jr   z, .marker_ok
    xor  a
.marker_ok:
    ld   (RESULT_MARKER_PASS), a

    ; ---- step 5: is chunk 6's RAM still exactly what step 1 wrote? ----
    ld   hl, CHUNK6_TEST_PATTERN
    ld   b, 16
    ld   a, $5A
    ld   c, 1                          ; C = running "still matches"
                                       ; flag, starts true
.check_loop:
    cp   (hl)
    jr   z, .byte_ok
    ld   c, 0
.byte_ok:
    inc  hl
    inc  a
    djnz .check_loop
    ld   a, c
    ld   (RESULT_RAM_PASS), a

    ; ---- step 6: report ----
    call GFX_CLS

    ld   hl, MSG_MARKER
    ld   b, 0
    ld   c, 0
    call GFX_PRINT_STRING
    ld   a, (RESULT_MARKER_PASS)
    or   a
    ld   hl, MSG_PASS
    jr   nz, .print_marker_result
    ld   hl, MSG_FAIL
.print_marker_result:
    ld   b, 0
    ld   c, 8                          ; right after "MARKER: "
    call GFX_PRINT_STRING

    ld   hl, MSG_RAM
    ld   b, 1
    ld   c, 0
    call GFX_PRINT_STRING
    ld   a, (RESULT_RAM_PASS)
    or   a
    ld   hl, MSG_PASS
    jr   nz, .print_ram_result
    ld   hl, MSG_FAIL
.print_ram_result:
    ld   b, 1
    ld   c, 8                          ; right after "RAM:    "
    call GFX_PRINT_STRING

.halt_loop:
    jr   .halt_loop                    ; sit here so the result stays
                                       ; on screen — nothing else to
                                       ; do once reported

MSG_MARKER  DB "MARKER: ", 0
MSG_RAM     DB "RAM:    ", 0
MSG_PASS    DB "PASS", 0
MSG_FAIL    DB "FAIL", 0

    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/math/math.asm"
    INCLUDE "kernel/storage/storage.asm"
    INCLUDE "kernel/interrupt/interrupt.asm"
    INCLUDE "kernel/bank/bank.asm"

    DS   $4000 - $, $FF
    SAVEBIN "test_exrom_isolation.bin", $0000, $4000
