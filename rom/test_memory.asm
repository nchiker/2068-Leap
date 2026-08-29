; ============================================================================
; rom/test_memory.asm — kernel/memory smoke test
;
; Tests everything currently implemented in kernel/memory/memory.asm:
; MEM_INIT, MEM_FILL_ZERO/MEM_FILL, MEM_LINE_FIRST on an empty program,
; and MEM_SHIFT_UP/MEM_SHIFT_DOWN. MEM_LABEL_*, MEM_LINE_STORE, and
; MEM_LINE_DELETE_RANGE are still stubs — nothing real to test there yet.
;
; IMPORTANT — fixed a real bug in this file's own first draft: all
; mutable test buffers below live in RAM (EQU addresses in the $8000s),
; never as DS-reserved space inside this file's own assembled code. A
; DS-reserved buffer lives inside the ROM image itself — the same ROM-
; vs-RAM mistake as Milestone 0's border-counter bug, just in the test
; harness instead of the code under test. The first draft's TEST_BUF was
; exactly this mistake: writes to it silently failed, the buffer
; happened to start pre-zeroed by sjasmplus's DS default, and the test
; passed for the wrong reason. Any *expected* comparison data (read-only)
; is still fine as ROM data — only things this file WRITES to at runtime
; need to be in RAM.
;
; Signal method: same as Milestone 0's border-cycle test, since there's
; still no text output. Border goes GREEN on all tests passing, RED on
; the first failure. No cycling, no delay loop — it sets once and halts.
;
; This is a SEPARATE binary from rom/main.asm's Milestone 0 boot stub —
; deliberately not merged into it, so a failure here can't be confused
; with a Milestone 0 regression, and vice versa.
;
; NOT YET ASSEMBLED OR TESTED BY THE AUTHOR for the shift-test additions
; specifically — MEM_INIT/MEM_FILL_ZERO(as re-fixed)/MEM_LINE_FIRST logic
; is the same shape already confirmed working on real Fuse/TS2068
; emulation; the new MEM_SHIFT_UP/DOWN tests are reviewed-by-eye only
; until run.
;
; Build:
;   sjasmplus rom/test_memory.asm
;   (produces test_memory.bin — 16K, same as rom0.bin, since Fuse expects
;   that size for --rom-ts2068-0 regardless of what's actually in it)
;
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_memory.bin --rom-ts2068-1 rom1.bin
;
; Expect: border turns GREEN and stays there. RED means a test failed —
; which one depends on where COLD_START below jumped to FAIL, findable
; by temporarily adding a distinct border colour per test if it happens.
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"

    DEVICE NOSLOT64K

; ---- RAM scratch buffers for this test file — see header note on why
; these must be RAM addresses (EQU), never DS-reserved ROM space ----
TEST_BUF        EQU $8000
TEST_BUF_LEN    EQU 16
SHIFT_UP_BUF    EQU $8010     ; well clear of TEST_BUF's 16 bytes
SHIFT_DOWN_BUF  EQU $8030     ; well clear of SHIFT_UP_BUF's shifted range

    ORG $0000
RST_00:
    di
    jp   COLD_START
    DS   $0100 - $, $FF     ; skip past the fixed RST vectors, same
                            ; convention as rom/main.asm; none of them
                            ; are exercised by this test so they're just
                            ; padding here, not individually stubbed

COLD_START:
    ld   sp, $FF00

    call TEST_MEM_COLD_INIT
    jr   c, FAIL
    call MEM_INIT
    call TEST_MEM_LINE_FIRST_EMPTY
    jr   c, FAIL
    call TEST_MEM_FILL_ZERO
    jr   c, FAIL
    call TEST_MEM_SHIFT_UP
    jr   c, FAIL
    call TEST_MEM_SHIFT_DOWN
    jr   c, FAIL
    call TEST_MEM_LABEL_ROUNDTRIP
    jr   c, FAIL
    call TEST_MEM_LINE_STORE
    jr   c, FAIL
    call TEST_MEM_LINE_STORE_EMPTY
    jr   c, FAIL
    call TEST_MEM_LINE_INSERT
    jr   c, FAIL
    call TEST_MEM_LINE_DELETE_RANGE
    jr   c, FAIL

PASS:
    ld   a, 4                ; green
    out  (PORT_ULA), a
    jr   $                   ; halt here — deliberate, not a bug

FAIL:
    ld   a, 2                ; red
    out  (PORT_ULA), a
    jr   $

; Seed the entire ROM-owned RAM region nonzero, then prove cold init clears
; every byte.  This models hardware/emulators that randomize RAM on reset.
TEST_MEM_COLD_INIT:
    ld   hl, $8000
    ld   bc, PROG_AREA_MAX - $8000
    ld   a, $A5
    call MEM_FILL
    call MEM_COLD_INIT
    ld   hl, $8000
    ld   bc, PROG_AREA_MAX - $8000
.verify:
    ld   a, (hl)
    or   a
    jr   nz, .fail
    inc  hl
    dec  bc
    ld   a, b
    or   c
    jr   nz, .verify
    ret
.fail:
    scf
    ret

; ============================================================================
; TEST_MEM_LINE_FIRST_EMPTY
; After MEM_INIT, the program is empty (PROG_END == PROG_AREA_START), so
; MEM_LINE_FIRST must return HL = 0.
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_MEM_LINE_FIRST_EMPTY:
    call MEM_LINE_FIRST
    ld   a, h
    or   l
    jr   nz, .fail
    or   a                   ; clear carry: pass
    ret
.fail:
    scf
    ret

; ============================================================================
; TEST_MEM_FILL_ZERO
; Seeds TEST_BUF (RAM — see file header) with a non-zero pattern via
; MEM_FILL, then calls MEM_FILL_ZERO and verifies every byte actually
; came back as zero.
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_MEM_FILL_ZERO:
    ld   hl, TEST_BUF
    ld   bc, TEST_BUF_LEN
    ld   a, $AA               ; non-zero seed pattern
    call MEM_FILL

    ld   hl, TEST_BUF
    ld   bc, TEST_BUF_LEN
    call MEM_FILL_ZERO

    ld   hl, TEST_BUF
    ld   b, TEST_BUF_LEN       ; TEST_BUF_LEN fits in B alone (< 256),
                              ; so DJNZ is fine — wouldn't be for a
                              ; larger buffer
.verify_loop:
    ld   a, (hl)
    or   a
    jr   nz, .fail
    inc  hl
    djnz .verify_loop
    or   a                    ; clear carry: pass
    ret
.fail:
    scf
    ret

; ============================================================================
; TEST_MEM_SHIFT_UP
; Copies a known 5-byte pattern (read-only ROM data, fine to read) into
; SHIFT_UP_BUF (RAM), shifts it up by 3 via MEM_SHIFT_UP, then verifies
; the pattern landed at SHIFT_UP_BUF+3 unchanged and in order.
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_MEM_SHIFT_UP:
    ld   hl, SHIFT_PATTERN
    ld   de, SHIFT_UP_BUF
    ld   bc, SHIFT_PATTERN_LEN
    ldir                       ; seed: ROM pattern -> RAM buffer (a read
                              ; from ROM + write to RAM — fine, only
                              ; writing TO rom would be the problem)

    ld   hl, SHIFT_UP_BUF
    ld   bc, SHIFT_PATTERN_LEN
    ld   de, 3                 ; shift amount
    call MEM_SHIFT_UP

    ld   hl, SHIFT_UP_BUF + 3  ; where the pattern should now be
    ld   de, SHIFT_PATTERN     ; compare against the original (ROM, safe
                              ; to read)
    ld   b, SHIFT_PATTERN_LEN
.verify_loop:
    ld   a, (de)
    cp   (hl)
    jr   nz, .fail
    inc  hl
    inc  de
    djnz .verify_loop
    or   a                    ; clear carry: pass
    ret
.fail:
    scf
    ret

; ============================================================================
; TEST_MEM_SHIFT_DOWN
; Same idea as TEST_MEM_SHIFT_UP, mirrored: seed SHIFT_DOWN_BUF+3 with
; the pattern, shift down by 3, verify it landed at SHIFT_DOWN_BUF.
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_MEM_SHIFT_DOWN:
    ld   hl, SHIFT_PATTERN
    ld   de, SHIFT_DOWN_BUF + 3
    ld   bc, SHIFT_PATTERN_LEN
    ldir

    ld   hl, SHIFT_DOWN_BUF + 3
    ld   bc, SHIFT_PATTERN_LEN
    ld   de, 3
    call MEM_SHIFT_DOWN

    ld   hl, SHIFT_DOWN_BUF
    ld   de, SHIFT_PATTERN
    ld   b, SHIFT_PATTERN_LEN
.verify_loop:
    ld   a, (de)
    cp   (hl)
    jr   nz, .fail
    inc  hl
    inc  de
    djnz .verify_loop
    or   a
    ret
.fail:
    scf
    ret

; ---- read-only test data (ROM — fine, this file never writes to it) ----
SHIFT_PATTERN_LEN EQU 5
SHIFT_PATTERN:
    DB   $11, $22, $33, $44, $55

; ============================================================================
; TEST_MEM_LABEL_ROUNDTRIP
; Adds two labels ("LOOP", "DONE"), looks both up and checks their
; positions, removes "LOOP", then verifies "LOOP" is gone but "DONE" is
; still found with its original position unchanged — exercises
; MEM_LABEL_ADD, MEM_LABEL_LOOKUP, and MEM_LABEL_REMOVE together, not
; just in isolation, since REMOVE's shift-and-close-the-gap logic only
; has something real to verify when there's a second entry to disturb.
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_MEM_LABEL_ROUNDTRIP:
    ld   hl, NAME_LOOP
    ld   b, NAME_LOOP_LEN
    ld   de, $1234
    call MEM_LABEL_ADD
    jr   c, .fail

    ld   hl, NAME_DONE
    ld   b, NAME_DONE_LEN
    ld   de, $5678
    call MEM_LABEL_ADD
    jr   c, .fail

    ; look both up, check positions
    ld   hl, NAME_LOOP
    ld   b, NAME_LOOP_LEN
    call MEM_LABEL_LOOKUP
    jr   c, .fail
    ld   hl, $1234
    or   a
    sbc  hl, de
    jr   nz, .fail

    ld   hl, NAME_DONE
    ld   b, NAME_DONE_LEN
    call MEM_LABEL_LOOKUP
    jr   c, .fail
    ld   hl, $5678
    or   a
    sbc  hl, de
    jr   nz, .fail

    ; remove LOOP, confirm it's gone
    ld   hl, NAME_LOOP
    ld   b, NAME_LOOP_LEN
    call MEM_LABEL_REMOVE
    jr   c, .fail

    ld   hl, NAME_LOOP
    ld   b, NAME_LOOP_LEN
    call MEM_LABEL_LOOKUP
    jr   nc, .fail             ; should NOT be found now — carry clear
                              ; here (found) means REMOVE didn't work

    ; DONE should still be there, at its original position — this is
    ; the part that actually exercises REMOVE's shift-down, since DONE
    ; was added after LOOP and only survives correctly if the gap
    ; closed without corrupting what came after it
    ld   hl, NAME_DONE
    ld   b, NAME_DONE_LEN
    call MEM_LABEL_LOOKUP
    jr   c, .fail
    ld   hl, $5678
    or   a
    sbc  hl, de
    jr   nz, .fail

    or   a
    ret
.fail:
    scf
    ret

; ---- read-only test data ----
NAME_LOOP_LEN EQU 4
NAME_LOOP:
    DB   "LOOP"
NAME_DONE_LEN EQU 4
NAME_DONE:
    DB   "DONE"

; ============================================================================
; TEST_MEM_LINE_STORE
; Builds a two-statement program area (A, then B) directly at
; PROG_AREA_START, replaces A with a larger statement, and verifies both
; the new statement's bytes AND that B survived correctly at its new
; (shifted) position. A single-statement case wouldn't exercise the
; shift math at all — it'd degenerate to the BC=0 no-op path, same as
; the earlier hand-trace. This is deliberately a case where the shifted
; amount differs (old=5 bytes, new=7 bytes) so a size-delta bug would
; show up as B landing in the wrong place.
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_MEM_LINE_STORE:
    ld   hl, STMT_A
    ld   de, PROG_AREA_START
    ld   bc, STMT_A_LEN
    ldir

    ld   hl, STMT_B
    ld   de, PROG_AREA_START + STMT_A_LEN
    ld   bc, STMT_B_LEN
    ldir

    ld   hl, PROG_AREA_START + STMT_A_LEN + STMT_B_LEN
    ld   (PROG_END), hl

    ld   hl, PROG_AREA_START
    ld   de, STMT_NEW
    call MEM_LINE_STORE
    jr   c, .fail

    ; PROG_END should now be PROG_AREA_START + STMT_NEW_LEN + STMT_B_LEN
    ld   hl, (PROG_END)
    ld   de, PROG_AREA_START + STMT_NEW_LEN + STMT_B_LEN
    or   a
    sbc  hl, de
    jr   nz, .fail

    ; verify the new statement's bytes landed at PROG_AREA_START
    ld   hl, PROG_AREA_START
    ld   de, STMT_NEW
    ld   b, STMT_NEW_LEN
    call TEST_COMPARE_BYTES
    jr   c, .fail

    ; verify B survived, now immediately after the new (larger) statement
    ld   hl, PROG_AREA_START + STMT_NEW_LEN
    ld   de, STMT_B
    ld   b, STMT_B_LEN
    call TEST_COMPARE_BYTES
    jr   c, .fail

    or   a
    ret
.fail:
    scf
    ret

; ============================================================================
; TEST_MEM_LINE_STORE_EMPTY
; Regression test for a real bug: MEM_LINE_STORE originally assumed a
; statement already existed at the given position and unconditionally
; read 2 bytes there as "the old length" — reading uninitialized RAM
; when the program area was genuinely empty (the very first statement
; ever stored). Caught via integration testing (rom/test_basic.asm),
; not by TEST_MEM_LINE_STORE above, which only ever exercises replacing
; an EXISTING statement. This test calls MEM_INIT (empty program) and
; then MEM_LINE_STORE directly into that emptiness, so this exact class
; of bug can't silently return.
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_MEM_LINE_STORE_EMPTY:
    call MEM_INIT

    ld   hl, PROG_AREA_START
    ld   de, STMT_NEW
    call MEM_LINE_STORE
    jr   c, .fail

    ; PROG_END should now be PROG_AREA_START + STMT_NEW_LEN exactly —
    ; nothing else was ever in the program
    ld   hl, (PROG_END)
    ld   de, PROG_AREA_START + STMT_NEW_LEN
    or   a
    sbc  hl, de
    jr   nz, .fail

    ; verify the statement's bytes landed correctly at PROG_AREA_START
    ld   hl, PROG_AREA_START
    ld   de, STMT_NEW
    ld   b, STMT_NEW_LEN
    call TEST_COMPARE_BYTES
    jr   c, .fail

    or   a
    ret
.fail:
    scf
    ret

; ============================================================================
; TEST_MEM_LINE_INSERT
; Builds a two-statement program (A, B, appended in order), then
; inserts a third statement (NEW) between them — at B's current
; position, which MEM_LINE_INSERT should shift later rather than
; overwrite. Verifies the final layout: A unchanged at the start, NEW
; occupying what was B's old slot, and B surviving intact right after
; NEW, plus PROG_END reflecting the combined size of all three.
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_MEM_LINE_INSERT:
    call MEM_INIT

    ld   hl, PROG_AREA_START
    ld   de, STMT_A
    call MEM_LINE_STORE
    jr   c, .fail

    ld   hl, (PROG_END)
    ld   de, STMT_B
    call MEM_LINE_STORE
    jr   c, .fail

    ; insert NEW at B's current position (PROG_AREA_START + STMT_A_LEN)
    ld   hl, PROG_AREA_START + STMT_A_LEN
    ld   de, STMT_NEW
    call MEM_LINE_INSERT
    jr   c, .fail

    ; PROG_END should be A + NEW + B combined
    ld   hl, (PROG_END)
    ld   de, PROG_AREA_START + STMT_A_LEN + STMT_NEW_LEN + STMT_B_LEN
    or   a
    sbc  hl, de
    jr   nz, .fail

    ; A unchanged at the start
    ld   hl, PROG_AREA_START
    ld   de, STMT_A
    ld   b, STMT_A_LEN
    call TEST_COMPARE_BYTES
    jr   c, .fail

    ; NEW now occupies what was B's old slot
    ld   hl, PROG_AREA_START + STMT_A_LEN
    ld   de, STMT_NEW
    ld   b, STMT_NEW_LEN
    call TEST_COMPARE_BYTES
    jr   c, .fail

    ; B survived, shifted right after NEW
    ld   hl, PROG_AREA_START + STMT_A_LEN + STMT_NEW_LEN
    ld   de, STMT_B
    ld   b, STMT_B_LEN
    call TEST_COMPARE_BYTES
    jr   c, .fail

    or   a
    ret
.fail:
    scf
    ret

; ============================================================================
; TEST_MEM_LINE_DELETE_RANGE
; Builds a three-statement program area (A, B, C), deletes just B (a
; single-statement range whose first and last position are both B's
; start), and verifies A is untouched and C survived at its new
; (shifted) position immediately after A.
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_MEM_LINE_DELETE_RANGE:
    ld   hl, DR_STMT_A
    ld   de, PROG_AREA_START
    ld   bc, DR_STMT_A_LEN
    ldir

    ld   hl, DR_STMT_B
    ld   de, PROG_AREA_START + DR_STMT_A_LEN
    ld   bc, DR_STMT_B_LEN
    ldir

    ld   hl, DR_STMT_C
    ld   de, PROG_AREA_START + DR_STMT_A_LEN + DR_STMT_B_LEN
    ld   bc, DR_STMT_C_LEN
    ldir

    ld   hl, PROG_AREA_START + DR_STMT_A_LEN + DR_STMT_B_LEN + DR_STMT_C_LEN
    ld   (PROG_END), hl

    ld   hl, PROG_AREA_START + DR_STMT_A_LEN         ; first = B's start
    ld   de, PROG_AREA_START + DR_STMT_A_LEN         ; last = B's start too
                                                     ; (deleting just B)
    call MEM_LINE_DELETE_RANGE
    jr   c, .fail

    ld   hl, (PROG_END)
    ld   de, PROG_AREA_START + DR_STMT_A_LEN + DR_STMT_C_LEN
    or   a
    sbc  hl, de
    jr   nz, .fail

    ld   hl, PROG_AREA_START
    ld   de, DR_STMT_A
    ld   b, DR_STMT_A_LEN
    call TEST_COMPARE_BYTES
    jr   c, .fail

    ld   hl, PROG_AREA_START + DR_STMT_A_LEN
    ld   de, DR_STMT_C
    ld   b, DR_STMT_C_LEN
    call TEST_COMPARE_BYTES
    jr   c, .fail

    or   a
    ret
.fail:
    scf
    ret

; ============================================================================
; TEST_COMPARE_BYTES (internal test helper, not a kernel/memory routine)
; In:  HL = actual data, DE = expected data (read-only ROM is fine — this
;      only reads DE, never writes to it), B = length
; Out: carry clear = match, carry set = mismatch
; ============================================================================
TEST_COMPARE_BYTES:
    ld   a, (de)
    cp   (hl)
    jr   nz, .fail
    inc  hl
    inc  de
    djnz TEST_COMPARE_BYTES
    or   a
    ret
.fail:
    scf
    ret

; ---- read-only test fixtures ----
; Statement format throughout: [length:2][tokens][terminator $0D],
; length value = size of tokens+terminator, not counting itself.
STMT_A_LEN     EQU 5
STMT_A:        DB  $03, $00, $10, $20, $0D
STMT_B_LEN     EQU 4
STMT_B:        DB  $02, $00, $30, $0D
STMT_NEW_LEN   EQU 7
STMT_NEW:      DB  $05, $00, $AA, $BB, $CC, $DD, $0D

DR_STMT_A_LEN  EQU 4
DR_STMT_A:     DB  $02, $00, $01, $0D
DR_STMT_B_LEN  EQU 5
DR_STMT_B:     DB  $03, $00, $02, $03, $0D
DR_STMT_C_LEN  EQU 3
DR_STMT_C:     DB  $01, $00, $0D

    INCLUDE "kernel/memory/memory.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_memory.bin", $0000, $4000
