; ============================================================================
; rom/exrom_payload.asm — first-ever EXROM image: trivial isolation
; test payload
;
; CONFIRMED WORKING ON REAL HARDWARE — this isolation test's run #1
; showed FAIL/FAIL on screen, but a debug.bin dump proved the paging
; mechanism itself worked; the bug was in the test harness's own
; result markers (inline ROM writes silently no-op'd — see this
; project's lesson on that failure class). Run #2 confirmed PASS/PASS
; on real hardware. Kept in the tree (and still referenced by
; rom/test_exrom_isolation.asm's build instructions) as the minimal
; standing reference for the paging mechanism in isolation, separate
; from the real checker/storage EXROM payloads it cleared the way for.
;
; Assembled STANDALONE, from ITS OWN perspective (ORG $C000, matching
; the real runtime address once kernel/bank/bank.asm's BANK_PAGE_
; EXROM_IN pages chunk 6 to EXROM) — this is NOT INCLUDEd into
; rom/test_exrom_isolation.asm the way every other kernel module is
; included into rom/test_basic.asm. It's a genuinely separate 8K
; binary, its own sjasmplus invocation, that becomes the
; --rom-ts2068-1 file Fuse loads.
;
; Purpose: prove the paging mechanism itself works, before trusting
; anything real to live here. Does three things, each independently
; checkable from the Home side afterward:
;   1. Writes a "started" sentinel to EXROM_TEST_MARKER (chunk 4,
;      stays Home-mapped the whole time chunk 6 is EXROM) — proves
;      code physically executed from $C000 and could write outside
;      chunk 6.
;   2. Busy-waits on FRAMES (chunk 4, also always Home-mapped) actually
;      advancing by a deliberately-nontrivial amount before continuing
;      — proves real interrupts fired WHILE chunk 6 was paged to
;      EXROM, not just that the call/return mechanism itself works. A
;      fixed-iteration busy-wait with no such check would prove
;      nothing about interrupt safety, which is the entire point of
;      this test.
;   3. Only after that wait completes does it write the real
;      completion marker — so the Home side can tell "ran but hung in
;      the wait loop" apart from "genuinely finished" if something's
;      wrong, rather than a single pass/fail bit collapsing both.
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"

EXROM_TEST_MARKER   EQU $9600   ; 1 byte — see rom/test_exrom_
                                ; isolation.asm's own header for why
                                ; this address is safe scratch space
                                ; (this harness never runs the real
                                ; BASIC interpreter or touches
                                ; PROG_AREA_START-based storage, so
                                ; using space past it is harmless here)
EXROM_START_FRAMES  EQU $9601   ; 2 bytes
EXROM_WAIT_TICKS    EQU 10      ; how many real FRAMES increments to
                                ; wait for before declaring success —
                                ; deliberately more than one, so this
                                ; can't pass by coincidentally
                                ; sampling FRAMES either side of a
                                ; single tick boundary

    DEVICE NOSLOT64K
    ORG $C000

EXROM_ENTRY:
    xor  a
    ld   (EXROM_TEST_MARKER), a      ; 0 = "started, not yet done" —
                                     ; distinct from both $FF (the
                                     ; Home side's own "never touched"
                                     ; pre-clear sentinel) and the real
                                     ; completion value below

    ld   hl, (FRAMES)
    ld   (EXROM_START_FRAMES), hl

.wait_loop:
    ld   hl, (FRAMES)
    ld   de, (EXROM_START_FRAMES)
    or   a
    sbc  hl, de                       ; HL = ticks elapsed since entry
    ld   de, EXROM_WAIT_TICKS
    or   a
    sbc  hl, de
    jr   c, .wait_loop                 ; elapsed < EXROM_WAIT_TICKS —
                                       ; keep waiting; every one of
                                       ; these iterations runs with
                                       ; interrupts enabled (kernel/
                                       ; bank's BANK_PAGE_EXROM_IN
                                       ; already re-EI'd before this
                                       ; code was ever reached) — this
                                       ; loop can only ever exit
                                       ; because a real interrupt
                                       ; incremented FRAMES while
                                       ; chunk 6 was paged out from
                                       ; Home, which is the one fact
                                       ; this whole test exists to
                                       ; confirm

    ld   a, $42                        ; arbitrary confirmed-complete
                                       ; marker value — not 0 (the
                                       ; "started" sentinel above) or
                                       ; $FF (the Home side's own
                                       ; "never touched" sentinel)
    ld   (EXROM_TEST_MARKER), a
    ret

    DS   $E000 - $, $FF                ; pad to a full 8K image
    SAVEBIN "exrom_payload.bin", $C000, $2000
