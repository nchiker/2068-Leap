; ============================================================================
; rom/test_storage.asm — kernel/storage smoke test
;
; Two tests, updated for the from-scratch block-based protocol (see
; kernel/storage/storage.asm's own header for the full design):
;  - TEST_SEND_BLOCK_CHECKSUM: STORAGE_SEND_BLOCK's checksum/loop logic
;    against a known 3-byte payload with a Block ID byte, hand-computed
;    expected checksum (verified with a one-line Python check, not by
;    hand-arithmetic alone). Mechanism and expected value are UNCHANGED
;    from the original real-Sinclair-format test — Block ID 0 is the
;    same numeric value STORAGE_FLAG_HEADER always was.
;  - TEST_BUILD_HEADER: STORAGE_BUILD_HEADER's field layout against a
;    known filename/length, byte-for-byte against an expected 12-byte
;    buffer — SHRUNK from the original 18 bytes (no more TYPE/PARAMS
;    fields; this project's own format doesn't need them).
;
; IMPORTANT SCOPE: neither test verifies STORAGE_SEND_BYTE's actual
; pulse output, or the new block-count/size-check arithmetic in
; STORAGE_SAVE's own local .compute_block_count helper (a local label,
; not callable from outside STORAGE_SAVE's own scope) — that math was
; instead exhaustively verified in Python against every possible
; length 0-16384 before being written, the same discipline kernel/
; math's own routines used. Neither test calls STORAGE_SAVE itself,
; for the same reason as the original test: it's the one routine here
; that actually emits pulses, so testing it wouldn't add anything
; these two don't already cover at the logic level, while taking real
; seconds to run.
;
; Signal method: same as every other kernel-module test in this
; project — border goes GREEN on all tests passing, RED on the first
; failure.
;
; Build:
;   sjasmplus rom/test_storage.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_storage.bin --rom-ts2068-1 rom1.bin
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

    call TEST_SEND_BLOCK_CHECKSUM
    jr   c, FAIL
    call TEST_BUILD_HEADER
    jr   c, FAIL

PASS:
    ld   a, 4                    ; green
    out  (PORT_ULA), a
    jr   $                       ; halt here — deliberate, not a bug

FAIL:
    ld   a, 2                    ; red
    out  (PORT_ULA), a
    jr   $

; ============================================================================
; TEST_SEND_BLOCK_CHECKSUM
; Block ID=$00 (the header's own reserved ID), payload=$AA,$55,$A5 ->
; checksum $00^$AA^$55^$A5 = $5A (same value XORing 0 doesn't change
; it — checked via python3 -c "print(hex(0^0xAA^0x55^0xA5))"). This is
; also the exact scenario that caught the real STORAGE_SEND_BLOCK bug
; earlier in this project's history (an ID of $00 specifically was
; what triggered the D/E-clobbering empty-payload misread) — kept
; deliberately as this test's own scenario rather than picked fresh,
; so this regression stays covered going forward.
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_SEND_BLOCK_CHECKSUM:
    ld   c, PORT_ULA             ; set once, per STORAGE_PULSE's contract
                                 ; — must not be touched again below
    xor  a                      ; Block ID = $00
    ld   hl, TEST_BUFFER
    ld   de, TEST_BUFFER_LEN
    call STORAGE_SEND_BLOCK

    ld   a, (STORAGE_CHECKSUM)
    cp   TEST_EXPECTED_CHECKSUM
    ret  z
    scf
    ret

; ============================================================================
; TEST_BUILD_HEADER
; filename="TEST" (4 chars), data length=100 -> compares the resulting
; STORAGE_HEADER_BUF byte-for-byte against EXPECTED_HEADER (12 bytes:
; filename+length only, no flag/type/params).
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_BUILD_HEADER:
    ld   hl, TEST_FILENAME
    ld   b, TEST_FILENAME_LEN
    ld   de, 100
    call STORAGE_BUILD_HEADER

    ld   hl, STORAGE_HEADER_BUF
    ld   de, EXPECTED_HEADER
    ld   b, EXPECTED_HEADER_LEN
.verify_loop:
    ld   a, (de)
    cp   (hl)
    jr   nz, .fail
    inc  hl
    inc  de
    djnz .verify_loop
    or   a                       ; clear carry: pass
    ret
.fail:
    scf
    ret

TEST_BUFFER:
    DB   $AA, $55, $A5
TEST_BUFFER_LEN EQU $ - TEST_BUFFER
TEST_EXPECTED_CHECKSUM EQU $5A   ; python3 -c "print(hex(0^0xAA^0x55^0xA5))"

TEST_FILENAME:
    DB   "TEST"
TEST_FILENAME_LEN EQU $ - TEST_FILENAME

EXPECTED_HEADER:
    DB   "TEST      "            ; filename, space-padded to 10
    DB   100, 0                  ; data length = 100, little-endian
EXPECTED_HEADER_LEN EQU $ - EXPECTED_HEADER

    INCLUDE "kernel/math/math.asm"

; storage.asm's own two external calls now go through these aliases
; (see that file's own header) — direct, since this standalone test
; build has kernel/math right here, unlike the real EXROM build.
STORAGE_MATH_MULTIPLY16 EQU MATH_MULTIPLY16
STORAGE_MATH_DIVIDE16   EQU MATH_DIVIDE16

    INCLUDE "kernel/storage/storage.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_storage.bin", $0000, $4000
