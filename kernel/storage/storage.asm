; ============================================================================
; kernel/storage/storage.asm -- tape SAVE / LOAD / VERIFY: headers, names, versions, progress
;
; The tape format is the stock TS2068's (two blocks: a 17-byte header with flag $00, then the data
; with flag $FF), so V2 tapes load on stock tooling and stock tapes header-check here. The block I/O
; itself (one block's signal out or in) is kernel/storage/tapeblock.asm: clean-room code from
; 2068-Leap-C, named STORAGE_SEND_BLOCK / STORAGE_RECEIVE_BLOCK below (back-port plan item 3.1).
; It replaced V2's port of the stock ROM's SA-BYTES / LD-BYTES, so no stock-ROM code remains here.
;
; This file: the header layout and acceptance (STORAGE_LOAD: name match, header type, the R10.9
; version word, the length bound), STORAGE_SAVE's framing, the clean / touched / aborted failure
; classification, and the progress hook.
; ============================================================================

STORAGE_TYPE_HEADER EQU $00   ; the block flag of a header (the stock tape
                               ; format: flag < $80 = header, long pilot)
STORAGE_TYPE_DATA   EQU $FF

STORAGE_HEADER_TYPE_OFF      EQU 0
STORAGE_HEADER_NAME_OFF      EQU 1
STORAGE_HEADER_LENGTH_OFF    EQU 11
STORAGE_HEADER_AUTOSTART_OFF EQU 13
STORAGE_HEADER_PROGLEN_OFF   EQU 15
STORAGE_HEADER_PAYLOAD_LEN   EQU 17
STORAGE_LOAD_BAD_VERSION     EQU $FE     ; R10.9 failure return marker: the header's
                                         ; version word is not this ROM's; nothing was
                                         ; written (a clean failure, like A = 0)
STORAGE_LOAD_DATA_TOUCHED    EQU $FF     ; failure return marker: at least
                                         ; one destination byte was written
STORAGE_NO_AUTOSTART         EQU $8000

    ASSERT STORAGE_HEADER_NAME_OFF + STORAGE_HEADER_FILENAME_LEN = STORAGE_HEADER_LENGTH_OFF
    ASSERT STORAGE_HEADER_PROGLEN_OFF + 2 = STORAGE_HEADER_PAYLOAD_LEN

STORAGE_HEADER_ATTEMPTS_MAX EQU 15  ; STORAGE_LOAD's own .header_search
                               ; retry cap. The receiver's own search
                               ; budget (TR_TICKS, tapeblock.asm: ~8.6 s,
                               ; as the stock-derived receiver's was) is
                               ; what actually provides real-
                               ; world dead-air tolerance for a single
                               ; attempt (a genuine signal can take
                               ; several real seconds to start); this
                               ; outer count only needs to cover a
                               ; handful of complete-but-wrong attempts
                               ; (found something, but wrong name/too
                               ; long/SPACE), not waiting through
                               ; silence. Worst case if every attempt
                               ; somehow burned its full inner budget:
                               ; roughly 15 * ~8.6s ≈ 2 minutes.

; ---- the block I/O: kernel/storage/tapeblock.asm (clean-room, from 2068-Leap-C) ----
; TAPE_SEND_BLOCK -- In: A = flag, IX = payload, DE = length. Out: carry set = sent whole, clear =
;   SPACE stopped it. TAPE_RECV_BLOCK -- In: A = expected flag, carry set = load (clear = verify), IX,
;   DE. Out: carry clear = good, DE = 0; carry set = failure (silence for ~8.6 s, SPACE, wrong flag,
;   mismatch, dropout, checksum), DE = the payload bytes not yet stored (STORAGE_LOAD's touched test).
;   Both destroy AF, AF', BC, DE, HL, IX and leave interrupts off; the receiver uses
;   STORAGE_ENTRY_RETRY as its search budget. The test builds substitute their fake transports.
    IFDEF STORAGE_TEST_FAKE_RECEIVE
STORAGE_RECEIVE_BLOCK EQU STORAGE_TEST_RECEIVE_BLOCK
    ELSE
STORAGE_RECEIVE_BLOCK EQU TAPE_RECV_BLOCK
    ENDIF
STORAGE_SEND_BLOCK EQU TAPE_SEND_BLOCK

    INCLUDE "kernel/storage/tapeblock.asm"

    IFDEF STORAGE_VERSIONED
; ============================================================================
; STORAGE_VERSION_WORD (R10.9)
; Out: DE = the V2 tape version word for STORAGE_REQUEST_TYPE -- the package ABI
;      word for extension (package) tapes, the program/array format word otherwise.
;      include/v2_package_abi.inc defines both.
; Destroys: AF, DE (HL, BC, IX preserved)
; ============================================================================
STORAGE_VERSION_WORD:
    ld   a, (STORAGE_REQUEST_TYPE)
    ld   de, V2_FORMAT_WORD
    cp   STORAGE_EXTENSION_TYPE
    ret  nz
    ld   de, PKG_ABI_WORD
    ret
    ENDIF

; ============================================================================
; STORAGE_SAVE
; In:  HL = filename pointer, B = filename length, IX = data pointer,
;      DE = data length
; Out: carry clear = saved; carry set = SPACE aborted it (the header or the
;      data block was cut short; after an aborted header the data block is
;      not sent at all). Back-port plan item 2.1, after 2068-Leap-C: before
;      it, the data block was sent after an aborted header and SAVED shown.
; Destroys: AF, BC, DE, HL, IX
; ============================================================================
STORAGE_SAVE:
    di
    ld   a, b
    cp   STORAGE_HEADER_FILENAME_LEN + 1
    jr   c, .name_len_ok
    ld   b, STORAGE_HEADER_FILENAME_LEN   ; transport field is fixed-width
.name_len_ok:
    push ix
    push de
    ld   (STORAGE_SEND_LEN), de           ; stash the caller's own data
                                         ; ptr/length before HL/BC get
                                         ; reused building the header —
                                         ; STORAGE_SEND_LEN is scratch
                                         ; here (not the running-
                                         ; countdown role it had in the
                                         ; archived design; renamed
                                         ; comment, same sysvar slot)

    ld   a, (STORAGE_REQUEST_TYPE)
    ld   (STORAGE_HEADER_BUF + STORAGE_HEADER_TYPE_OFF), a
    ld   de, STORAGE_HEADER_BUF + STORAGE_HEADER_NAME_OFF
    ld   a, b
    or   a
    jr   z, .name_done                    ; zero-length name — leave
                                         ; the buffer's own default
                                         ; padding as-is (BASIC_DO_SAVE
                                         ; always supplies a real name
                                         ; today, kept defensive)
    push bc
    ld   b, a
.name_copy:
    ld   a, (hl)
    ld   (de), a
    inc  hl
    inc  de
    djnz .name_copy
    pop  bc
.name_done:
    ld   a, STORAGE_HEADER_FILENAME_LEN
    sub  b
    jr   z, .len_set
    ld   b, a
    ld   a, ' '
.pad:
    ld   (de), a
    inc  de
    djnz .pad
.len_set:
    ld   hl, (STORAGE_SEND_LEN)
    ld   (STORAGE_HEADER_BUF + STORAGE_HEADER_LENGTH_OFF), hl
    IFDEF STORAGE_VERSIONED
    ; R10.9: every V2 header carries a version word in the autostart field
    ; (docs/PACKAGE_ABI.md s6) -- program/array format or package ABI.
    call STORAGE_VERSION_WORD             ; DE = word for STORAGE_REQUEST_TYPE
    ELSE
    ld   a, (STORAGE_REQUEST_TYPE)
    cp   STORAGE_EXTENSION_TYPE
    ld   de, (STORAGE_HEADER_BUF + STORAGE_HEADER_AUTOSTART_OFF)
    jr   nz, .autostart_ready
    ld   de, EXT_SERVICE_ABI_VERSION
    ENDIF
.autostart_ready:
    ld   (STORAGE_HEADER_BUF + STORAGE_HEADER_AUTOSTART_OFF), de
    ; The stock BASIC header's second parameter is the program portion
    ; length. RC: for a program tape it is PROG_END - PROG_AREA_START, which
    ; SAVE ... ALL makes shorter than the data (the variable session follows);
    ; array and package tapes keep the data length.
    ld   a, (STORAGE_REQUEST_TYPE)
    or   a
    jr   nz, .proglen
    ld   hl, (PROG_END)
    ld   de, -PROG_AREA_START
    add  hl, de
.proglen:
    ld   (STORAGE_HEADER_BUF + STORAGE_HEADER_PROGLEN_OFF), hl

    xor  a
    ld   (STORAGE_PROGRESS_PCT), a
    ld   a, 1
    ld   (STORAGE_OP_STATE), a            ; SAVING
    call STORAGE_REPORT_PROGRESS

    ld   a, STORAGE_TYPE_HEADER
    ld   ix, STORAGE_HEADER_BUF
    ld   de, STORAGE_HEADER_PAYLOAD_LEN
    IFDEF STORAGE_TEST_FAKE_SEND
    call STORAGE_TEST_SEND_BLOCK
    ELSE
    call STORAGE_SEND_BLOCK
    ENDIF
    jr   nc, .aborted_header              ; SPACE during the header: no data block

    ld   a, 10
    ld   (STORAGE_PROGRESS_PCT), a
    call STORAGE_REPORT_PROGRESS          ; safe inter-block update;
                                         ; never draw inside a tape block

    pop  de                               ; caller's real data length
    pop  ix                               ; caller's real data pointer
    ld   a, STORAGE_TYPE_DATA
    IFDEF STORAGE_TEST_FAKE_SEND
    call STORAGE_TEST_SEND_BLOCK
    ELSE
    call STORAGE_SEND_BLOCK               ; stock format: one data block
    ENDIF
    jr   nc, .aborted

    ld   a, 2
    ld   (STORAGE_OP_STATE), a            ; SAVED
    ld   a, 100
    ld   (STORAGE_PROGRESS_PCT), a
    call STORAGE_REPORT_PROGRESS          ; BASIC_DRAW_STATUS_LINE is
                                         ; only ever reached through
                                         ; this hook, not the normal
                                         ; editor redraw cycle, so
                                         ; without this call SAVED would
                                         ; never actually reach the
                                         ; screen
    or   a
    ret

.aborted_header:
    pop  de                               ; the caller's length and pointer,
    pop  ix                               ; unused: no data block is sent
.aborted:
    xor  a
    ld   (STORAGE_OP_STATE), a            ; idle (not SAVED)
    scf
    ret

; ============================================================================
; STORAGE_LOAD
; In:  IX = destination pointer, HL = filename pointer, B = filename
;      length (0 = wildcard, LOAD ""), DE = max allowed data length
; Out: DE = actual data length received (only meaningful if carry
;          clear), A = 0 on success or a clean failure,
;          STORAGE_LOAD_DATA_TOUCHED on failure after destination writes
;      Carry set = total failure (no matching header, or header's own
;          claimed length exceeds the caller's bound, or the data block
;          failed). A distinguishes whether destination bytes were written
;          (0 clean / STORAGE_LOAD_DATA_TOUCHED) or an unsupported version
;          (STORAGE_LOAD_BAD_VERSION).  R10.9: B is nonzero on a failure
;          if SPACE (the tape-abort key) was held; B = 0 on success.
;          In VERIFY mode (STORAGE_VERIFY_MODE != 0) nothing is ever stored
;          to IX, so a failure is always clean (A = 0).
; Destroys: AF, BC, DE, HL, IX
; ============================================================================
STORAGE_LOAD:
    di
    ld   (STORAGE_MAX_LEN), de
    push hl                               ; caller's filename pointer
    push bc                               ; caller's filename length
    push ix                               ; caller's real destination
                                         ; pointer — IX gets reused for
                                         ; STORAGE_HEADER_BUF below

    xor  a
    ld   (STORAGE_PROGRESS_PCT), a
    ld   a, 3
    ld   (STORAGE_OP_STATE), a            ; LOADING
    call STORAGE_REPORT_PROGRESS

    ld   b, STORAGE_HEADER_ATTEMPTS_MAX
.header_search:
    push bc                               ; B = attempts remaining —
                                         ; STORAGE_RECEIVE_BLOCK
                                         ; destroys BC, so this must be
                                         ; saved/restored around each
                                         ; attempt, same pattern as the
                                         ; entry-pushed HL/BC/IX below
    ld   a, STORAGE_TYPE_HEADER
    scf
    ld   ix, STORAGE_HEADER_BUF
    ld   de, STORAGE_HEADER_PAYLOAD_LEN       ; the receive loop
                                         ; naturally reads and
                                         ; checksums the trailing
                                         ; checksum byte too, on top of
                                         ; this real length — no +1
                                         ; needed here (verified via
                                         ; z80sim, see STORAGE_HEADER_
                                         ; BUF's own header)
    call STORAGE_RECEIVE_BLOCK
    pop  bc
    jr   nc, .header_found
    call .space_held                      ; R10.9: a user abort ends the search
    jr   nc, .header_giveup               ; now (it used to burn all retries)
    djnz .header_search
.header_giveup:
    ; exhausted every attempt (or aborted) — give up cleanly instead of
    ; retrying forever. Rebalance the entry-pushed IX/BC/HL (never consumed
    ; on this path) before falling into .total_failure.
    pop  ix
    pop  bc
    pop  hl
    jp   .total_failure                   ; JP not JR — out of JR's
                                         ; +-127 range from here

.header_found:
    ; Keep the outer header-search budget before restoring the caller's
    ; registers.  A nonmatching header is not a LOAD failure: it may be
    ; an earlier file on a multi-file (or appended) tape, so .name_mismatch
    ; must be able to resume .header_search with this same remaining count.
    ; STORAGE_CHECKSUM is otherwise unused by the current real-ROM-derived
    ; protocol (its running XOR lives in H), making it safe scratch here.
    ld   a, b
    ld   (STORAGE_CHECKSUM), a
    ld   a, (STORAGE_HEADER_BUF + STORAGE_HEADER_TYPE_OFF)
    ld   c, a
    ld   a, (STORAGE_REQUEST_TYPE)
    cp   c
    jr   nz, .header_rejected
    pop  ix                               ; caller's real destination
                                         ; pointer, restored
    pop  bc                               ; caller's filename length
    pop  hl                               ; caller's filename pointer
    ld   a, b
    or   a
    jr   z, .name_ok                      ; wildcard — LOAD ""
    ; Preserve the original inputs while the fixed-width comparison
    ; consumes HL/B.  They are needed if this is a different file and
    ; the search continues at the following header.
    push bc
    push hl
    push ix
    ld   de, STORAGE_HEADER_BUF + STORAGE_HEADER_NAME_OFF
    ld   b, STORAGE_HEADER_FILENAME_LEN
.name_cmp:
    ld   a, (de)
    cp   (hl)
    jr   nz, .name_mismatch
    inc  hl
    inc  de
    djnz .name_cmp
    pop  ix
    pop  hl
    pop  bc
    jr   .name_ok
.name_mismatch:
    pop  ix
    pop  hl
    pop  bc
    push hl                               ; restore STORAGE_LOAD's
    push bc                               ; entry stack shape so a later
    push ix                               ; matching header gets its
                                         ; original destination/name
    ld   a, (STORAGE_CHECKSUM)
    ld   b, a
    djnz .header_search
    pop  ix
    pop  bc
    pop  hl
    jp   .total_failure

.header_rejected:
    ; A valid standard header for another file type is not corruption;
    ; continue looking for a BASIC-program header on the tape.
    pop  ix
    pop  bc
    pop  hl
    push hl
    push bc
    push ix
    ld   a, (STORAGE_CHECKSUM)
    ld   b, a
    djnz .header_search
    pop  ix
    pop  bc
    pop  hl
    jr   .total_failure

.name_ok:
    IFDEF STORAGE_VERSIONED
    ; R10.9: reject a header whose version word is not ours BEFORE any byte is
    ; received, so a stock/unversioned/future tape can never overwrite the program
    ; or the package window.  Rule: tag bit and major must match exactly, the
    ; tape's minor must not exceed ours.  Clean failure (A = STORAGE_LOAD_BAD_VERSION).
    ld   hl, (STORAGE_HEADER_BUF + STORAGE_HEADER_AUTOSTART_OFF)
    call STORAGE_VERSION_WORD             ; DE = expected word (IX/HL preserved)
    ld   a, h
    cp   d
    jr   nz, .bad_version                 ; JP: out of JR range
    ld   a, e
    cp   l                                ; carry if our minor < the tape's
    jr   c, .bad_version
    ENDIF
    ld   hl, (STORAGE_HEADER_BUF + STORAGE_HEADER_LENGTH_OFF)
    ld   de, (STORAGE_MAX_LEN)
    or   a
    sbc  hl, de
    jr   c, .length_ok                    ; header length < max — fine
    ld   a, h
    or   l
    jr   z, .length_ok                    ; header length == max — fine
    jr   .total_failure                   ; JP not JR — out of range;
                                         ; header length > max

.length_ok:
    ld   de, (STORAGE_HEADER_BUF + STORAGE_HEADER_LENGTH_OFF)
    ld   a, 10
    ld   (STORAGE_PROGRESS_PCT), a
    ld   a, 7
    ld   (STORAGE_OP_STATE), a            ; PROGRAM: <name> — matching
                                         ; header confirmed, about to
                                         ; receive the data block. Real
                                         ; ROM's own LOAD shows the
                                         ; found program's name at
                                         ; exactly this point, not just
                                         ; at final completion.
    call STORAGE_REPORT_PROGRESS
    push ix
    push de
    ld   a, STORAGE_TYPE_DATA
    push af                               ; preserve A/F (Z included)
                                         ; exactly as STORAGE_RECEIVE_
                                         ; BLOCK's own internal AF'
                                         ; stash-and-restore protocol
                                         ; needs, undisturbed by the
                                         ; verify-mode test below --
                                         ; tested BEFORE popping back
                                         ; (an earlier version of this
                                         ; branch popped first, which
                                         ; clobbered the verify-mode
                                         ; test's own flags with the
                                         ; just-restored ones before
                                         ; the jr z below ever read
                                         ; them -- caught by this
                                         ; milestone's own real-ZEsarUX
                                         ; storage-transport test)
    ld   a, (STORAGE_VERIFY_MODE)
    or   a
    jr   z, .data_load_mode
    pop  af
    scf
    ccf                                    ; carry clear, Z/S/A
                                         ; untouched by scf/ccf
    jr   .data_recv
.data_load_mode:
    pop  af
    scf
.data_recv:
    call STORAGE_RECEIVE_BLOCK
    jr   c, .data_failed
.data_ok:
    pop  de                               ; discard the saved retry
                                         ; state — reload the real
                                         ; length below instead, since
                                         ; STORAGE_RECEIVE_BLOCK's own
                                         ; DE counts DOWN to 0 on
                                         ; success, not what our own
                                         ; caller needs
    pop  ix
    ld   de, (STORAGE_HEADER_BUF + STORAGE_HEADER_LENGTH_OFF)
    ld   a, 4
    ld   (STORAGE_OP_STATE), a            ; LOADED
    ld   a, 100
    ld   (STORAGE_PROGRESS_PCT), a
.success_done:
    call STORAGE_REPORT_PROGRESS          ; without this, LOADED would never
                                         ; actually reach the screen —
                                         ; see STORAGE_SAVE's own
                                         ; matching comment for why
    xor  a
    ld   b, a                            ; B = 0 (no abort) on success
    ret

.data_failed:
    ; DE is the receiver's remaining byte count; the stack holds the
    ; original length. If they differ, part (or all) of the destination
    ; has already been overwritten and the caller must not retain the old
    ; program as though it were still trustworthy.
    pop  hl
    pop  ix
    ld   a, (STORAGE_VERIFY_MODE)
    or   a
    jr   nz, .total_failure               ; R10.9: VERIFY never stores to IX, so
                                         ; a VERIFY failure is always clean
    ld   a, d
    cp   h
    jr   nz, .data_touched
    ld   a, e
    cp   l
    jr   nz, .data_touched
.total_failure:
    xor  a                               ; clean failure: no program bytes
                                         ; were written
    jr   .abort_check
    IFDEF STORAGE_VERSIONED
.bad_version:
    ld   a, STORAGE_LOAD_BAD_VERSION     ; clean failure, distinguishable
    jr   .report_failure
    ENDIF
.data_touched:
    ld   a, STORAGE_LOAD_DATA_TOUCHED
.abort_check:
    ; R10.9: B = nonzero iff the user is holding SPACE (the receiver's abort
    ; key) as the failure is reported, so callers can say "ABORTED" instead of
    ; "LOAD FAILED".  The receiver samples SPACE thousands of times a second
    ; and a keypress lasts milliseconds, so re-reading it here is reliable.
    ld   c, a
    call .space_held
    sbc  a, a                             ; $FF if SPACE released, 0 if held
    cpl
    ld   b, a
    ld   a, c
.report_failure:
    push af                              ; preserve clean/dirty result marker
    ld   a, 6
    ld   (STORAGE_OP_STATE), a            ; LOAD FAILED
    call STORAGE_REPORT_PROGRESS          ; without this, LOAD FAILED
                                         ; would never actually reach
                                         ; the screen — see STORAGE_
                                         ; SAVE's own matching comment
                                         ; for why
    pop  af
    scf
    ret

; .space_held -- Out: carry CLEAR iff SPACE is down.  Destroys A.
.space_held:
    ld   a, $7f
    in   a, (PORT_ULA)
    rra
    ret

; ============================================================================
; STORAGE_REPORT_PROGRESS
; Calls STORAGE_PROGRESS_HOOK if one is set, so BASIC can redraw its
; own status bar to reflect the current STORAGE_OP_STATE live, mid-
; operation. This ROM has no interrupts during SAVE/LOAD (see this
; file's own top header), so there is no other way for a live status
; update to reach the screen during a block transfer.
; In:  none
; Out: none
; Destroys: nothing the hook itself doesn't (the hook's own contract is
;      "no input, no output" — callers of THIS routine should still
;      preserve their own live registers across it defensively, same
;      as the archived design's own convention)
; ============================================================================
STORAGE_REPORT_PROGRESS:
    push af
    push bc
    push de
    push hl
    push ix
    ld   hl, (STORAGE_PROGRESS_HOOK)
    ld   a, h
    or   l
    jr   z, .none
    call .call_hl
.none:
    pop  ix
    pop  hl
    pop  de
    pop  bc
    pop  af
    ret
.call_hl:
    jp   (hl)
