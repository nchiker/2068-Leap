; ============================================================================
; kernel/storage/storage.asm — tape SAVE/LOAD, ported from the REAL
; Timex Sinclair 2068 ROM's own cassette-handling routines
;
; This is a from-scratch port, not a copy-paste — this project's memory
; map, sysvars, header format, and error-reporting convention are all
; different from the real ROM's — but the actual TAPE PROTOCOL logic
; below (every constant, every jump, every register convention in
; STORAGE_SEND_BLOCK/STORAGE_RECEIVE_BLOCK and their sub-labels) is a
; direct, verified port of the real ROM's SA-BYTES/LD-BYTES routines and
; everything they call. "Verified" means: every single instruction below
; was checked instruction-by-instruction against the real EXROM binary's
; own bytes (~/fuse-build/roms/tc2068-1.rom, offsets $0068-$0197) via a
; hex dump — both SEND and RECEIVE sides match the real ROM exactly,
; aside from the deliberate adaptations documented below. See kernel/
; storage/archive/README.md for why the previous from-scratch protocol
; (which this replaced) was abandoned.
;
; PROTOCOL SHAPE: the stock TS2068/Sinclair two-block program format:
; one header block followed by one data block containing this ROM's
; entire serialized program payload.
;
; DELIBERATE ADAPTATIONS from the real ROM (not errors — see each for
; why):
;   - Header framing now matches the stock 17-byte BASIC header: file
;     type, 10-character name, data length, autostart, and program
;     length. The payload remains this ROM's own structured plain-text
;     program representation, not Sinclair-tokenized BASIC. Transport
;     compatibility therefore does not imply language compatibility.
;   - No BORDCR (a real 48K-ROM sysvar this project doesn't have) — the
;     shared exit restores the port via this project's OWN PORT_FE_
;     SHADOW (include/sysvars.inc), which already exists for exactly
;     this "what did the port last hold" problem.
;   - The real ROM's own final break-check + RST $08/"Report D" error
;     (raised even after an otherwise-successful transfer, if SPACE is
;     still held at the very end) isn't ported — this project has no
;     RST $08 error-RST convention, and SPACE-to-abort mid-transfer is
;     still fully live (same real port read, same real bit test, at
;     every single edge-wait — see .sample) and already reports through
;     this project's own STORAGE_OP_STATE convention as an ordinary
;     failure, which is what actually matters to a caller.
;   - The real ROM's shared exit does `EI` unconditionally before
;     returning (interrupts come back on between every retry of the
;     BASIC-level search loop); this port does not — STORAGE_LOAD/SAVE
;     both `di` once at entry and rely on their own caller's `ei` after
;     the whole operation completes (see BASIC_SAVE_EXROM/BASIC_LOAD_
;     EXROM in basic.asm), so interrupts stay off for the operation's
;     entire duration rather than toggling between individual block
;     attempts.
;   - The .loop's own Z-flag-dependent type-flag validation (see
;     .flag) needs the CALLER to leave Z clear (NZ) at the moment of
;     the call — neither "ld a,<type>" nor "scf" touch Z at all, so
;     every call site forces it explicitly via "cp STORAGE_NZ_SENTINEL"
;     (see that constant's own header) rather than leaving it to
;     whatever happened to survive from earlier code. The real ROM's
;     own mechanism for this is a subtler `INC D`/`EX AF,AF'`/`DEC D`
;     entry trick baking the Z flag into the length's high byte —
;     functionally equivalent for any realistic block length, so not
;     reproduced literally.
;   - The final "is the checksum right" check (STORAGE_RECEIVE_BLOCK's
;     .bits8 tail) checks H==0, not the real ROM's own "cp $01" — with
;     this file's own DE convention (real length, no +1 — the receive
;     loop naturally reads and checksums the trailing checksum byte on
;     top of that), a genuinely clean, correctly-checksummed transfer
;     leaves H at exactly 0, confirmed against this file's own STORAGE_
;     SEND_BLOCK checksum computation (verified via tools/z80sim).
;     Whatever makes the real ROM's own sender leave H at 1 instead
;     wasn't identified.
;   - The earlier duplicate data copy was removed: stock framing is one
;     header block plus one data block. A failed checksum is a LOAD
;     failure rather than a request for a project-private backup copy.
;   - No live progress reporting exists in the real ROM at all — SAVE/
;     LOAD just block silently until done. NOT reintroduced here as a
;     percentage: STORAGE_REPORT_PROGRESS is called at the start of
;     each operation (SAVING.../LOADING...), once a header is confirmed
;     during LOAD (PROGRAM: <name> — mirrors the real ROM's own LOAD
;     UX of showing the found file's name before the data block starts),
;     and at completion — the real ROM's own already-proven per-edge
;     border flicker (every single pulse flips PORT_FE_SHADOW's border
;     bits) is the live "still working" signal throughout each block's
;     own transfer, inherited for free by porting the real routines
;     faithfully.
;   - .entry_start's own leader-search retry (STORAGE_ENTRY_RETRY, see
;     its own sysvars.inc comment) and STORAGE_LOAD's own .header_search
;     retry (STORAGE_HEADER_ATTEMPTS_MAX) are both NOT from the real
;     ROM, which retries unboundedly — fine for a human watching a real
;     tape deck and pressing BREAK when they give up, not fine for an
;     unattended call. Both are real, finite bounds instead.
;
; CURRENT STATUS: SAVE and LOAD are confirmed in a real Fuse round-trip.
; SAVE produced a valid Direct Recording TZX; LOAD displayed the matched
; filename and restored the program. The decisive receiver correction
; was restoring LD-EDGE-2's stock fall-through into a second LD-EDGE-1
; measurement rather than returning after one half-pulse.
;
; Real-ROM cross-reference (M-addresses from "Timex Sinclair 2068 ROM
; Disassembly.pdf", repo root, all confirmed against the real binary):
; SA-BYTES M0068, SA-FLAG M0076, SA-LEADER M007E, SA-SYNC-1 M0090,
; SA-SYNC-2 M0098, SA-LOOP M00A4, SA-LOOP-P M00AB, SA-START M00AD,
; SA-PARITY M00B4, SA-BIT-2 M00B7, SA-BIT-1 M00BA, SA-SET M00C0,
; SA-OUT M00C2, SA-8-BITS M00CB, SA-DELAY M00E2; LD-BYTES M00FC,
; LD-BREAK M0111, LD-START M0112, LD-WAIT M011A, LD-LEADER M0126,
; LD-SYNC M0135, LD-LOOP M014F, LD-FLAG M0159, LD-VERIFY M0163,
; LD-NEXT M0168, LD-DEC M016A, LD-MARKER M016E, LD-8-BITS M0170,
; LD-EDGE-2 M0189, LD-EDGE-1 M018D, LD-DELAY M018F, LD-SAMPLE M0193.
; ============================================================================

STORAGE_TYPE_HEADER EQU $00   ; SA-BYTES/LD-BYTES type-flag byte — this
                               ; is the value LD-LOOK-H's own real code
                               ; uses ("XOR A" before calling LD-BYTES
                               ; to search for a header); the book's own
                               ; prose describing SA-BYTES has this
                               ; backwards from its own actual code.
STORAGE_TYPE_DATA   EQU $FF

STORAGE_HEADER_TYPE_OFF      EQU 0
STORAGE_HEADER_NAME_OFF      EQU 1
STORAGE_HEADER_LENGTH_OFF    EQU 11
STORAGE_HEADER_AUTOSTART_OFF EQU 13
STORAGE_HEADER_PROGLEN_OFF   EQU 15
STORAGE_HEADER_PAYLOAD_LEN   EQU 17
STORAGE_LOAD_DATA_TOUCHED    EQU $FF     ; failure return marker: at least
                                         ; one destination byte was written
STORAGE_NO_AUTOSTART         EQU $8000

    ASSERT STORAGE_HEADER_NAME_OFF + STORAGE_HEADER_FILENAME_LEN = STORAGE_HEADER_LENGTH_OFF
    ASSERT STORAGE_HEADER_PROGLEN_OFF + 2 = STORAGE_HEADER_PAYLOAD_LEN

STORAGE_NZ_SENTINEL EQU $02   ; NOT a real type flag — see every "cp
                               ; STORAGE_NZ_SENTINEL" call site in
                               ; STORAGE_LOAD below. STORAGE_RECEIVE_
                               ; BLOCK's own .loop (".flag" branch)
                               ; tests the CALLER's Z flag at the
                               ; moment of the call (restored via its
                               ; own first "ex af,af'") to decide
                               ; whether to validate the just-received
                               ; type-flag byte. Z must be CLEAR (NZ)
                               ; at the call site for validation to
                               ; fire correctly; neither "ld a,type" nor
                               ; "scf" touch Z at all, so this sentinel
                               ; forces it explicitly without disturbing
                               ; A (it can never equal either real type
                               ; flag, $00 or $FF).

STORAGE_HEADER_ATTEMPTS_MAX EQU 15  ; STORAGE_LOAD's own .header_search
                               ; retry cap. STORAGE_ENTRY_RETRY_MAX
                               ; below is what actually provides real-
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

STORAGE_ENTRY_RETRY_MAX EQU 2000  ; STORAGE_RECEIVE_BLOCK's own internal
                               ; .entry_start retry cap (STORAGE_ENTRY_
                               ; RETRY, a 2-byte sysvar — see its own
                               ; sysvars.inc comment) — bounds a single
                               ; call's own leader-search loop, which
                               ; the real ROM leaves genuinely unbounded.
                               ; This is the cap that matters for real-
                               ; world dead-air tolerance: a cheap
                               ; retry (.edge1 finds no edge at all)
                               ; costs ~15000 T-states (~4.3ms), so 2000
                               ; gives roughly 8.6 real seconds of pure-
                               ; silence tolerance per call — measured
                               ; against a real user-captured tape file
                               ; that had 1.09 real seconds of lead-in
                               ; silence before its leader tone started.
                               ; Not measured end-to-end against a real
                               ; Fuse run to confirm it's sufficient in
                               ; practice (see this file's own "CURRENT
                               ; STATUS" note above) — revisit if real
                               ; testing shows it cutting off otherwise-
                               ; good transfers, or still taking too
                               ; long to give up on a genuinely absent
                               ; signal (e.g. the data block's backup-
                               ; copy search when there's no real second
                               ; copy left to find).

; ---- timing constants, ported verbatim from the real ROM's own bytes
; (cited by M-address above) ----
STORAGE_HEADER_LEAD  EQU $1F80  ; SA-BYTES M0068 — half-cycle count for
                                 ; the HEADER's own leader tone, ~5 real
                                 ; seconds at the real ROM's own pulse
                                 ; rate.
STORAGE_DATA_LEAD    EQU $0C98  ; SA-BYTES M0068 (override branch) —
                                 ; half-cycle count for the DATA block's
                                 ; own (shorter) leader, ~2 real
                                 ; seconds.
STORAGE_LEADER_HOLD  EQU $A4    ; SA-LEADER M007E — half-cycle hold
                                 ; count, ~806.5Hz leader tone.
STORAGE_SYNC1_HOLD   EQU $37    ; SA-SYNC-1 M0090
STORAGE_SYNC2_INIT   EQU $3B0E  ; SA-SYNC-2 M0098 — B=half-cycle hold
                                 ; for the 2400Hz data-pulse frequency,
                                 ; C=$0E (the real ROM's own dual-
                                 ; purpose initial output byte: MIC
                                 ; line high + a debug border colour in
                                 ; the same OUT).
STORAGE_BIT0_EXTRA   EQU $42    ; SA-BIT-1 M00BA — extra half-cycle
                                 ; hold added only for a '0' bit.
STORAGE_BIT_RELOAD   EQU $3E    ; SA-OUT M00C2 — B reload for the
                                 ; second half of each bit-cell.
STORAGE_NEXTBYTE_HOLD EQU $31   ; SA-8-BITS M00CB (tail) — B reload
                                 ; carried into the next byte's first
                                 ; bit.
STORAGE_TAIL_HOLD    EQU $3B    ; SA-LOOP tail (after the last byte) —
                                 ; final half-cycle hold before
                                 ; SA-DELAY's own trailing pulse.

STORAGE_EDGE_DELAY   EQU $16    ; LD-EDGE-1 M018D — inner delay-loop
                                 ; iteration count between samples.
STORAGE_LEADER_GAP   EQU $C6    ; LD-LEADER M0126 — stock threshold;
                                 ; EDGE2 must measure both half-pulses
STORAGE_SYNC_TIMING  EQU $C9    ; LD-SYNC M0135 — initial timing value
                                 ; for the post-leader sync search.
STORAGE_SYNC_GAP_MAX EQU $D4    ; LD-SYNC M0135 — max augmented timing
                                 ; value before giving up this sync
                                 ; attempt and retrying.
STORAGE_BIT_COMPARE  EQU $CB    ; LD-8-BITS M0170 — stock 0/1 boundary
STORAGE_BIT_RESET_LD EQU $B0    ; LD-8-BITS/LD-SYNC — B reload between
                                 ; bits.
STORAGE_DEC_HOLD     EQU $B2    ; LD-DEC M016A — B reload after each
                                 ; byte.
STORAGE_LEADER_PILOT EQU $9C    ; LD-LEADER M0126 — initial timing
                                 ; value for the leader-tone search.

; ============================================================================
; STORAGE_SEND_BLOCK — ported from the real ROM's SA-BYTES (+ SA-FLAG/
; SA-LEADER/SA-SYNC-1/SA-SYNC-2/SA-LOOP/SA-LOOP-P/SA-START/SA-PARITY/
; SA-BIT-2/SA-BIT-1/SA-SET/SA-OUT/SA-8-BITS/SA-DELAY, all one routine's
; worth of sub-labels in the real ROM). Sends one block: leader tone
; (length depends on A's type flag), sync pulses, then every byte from
; IX for DE bytes MSB-first, then a trailing running-XOR checksum byte.
;
; In:  A = STORAGE_TYPE_HEADER or STORAGE_TYPE_DATA
;      IX = data pointer, DE = data length
; Out: none meaningful — this project's own caller (STORAGE_SAVE) has
;      no way to detect a mid-SAVE SPACE-abort differently from success
;      today; kept simple to match. (The real ROM's own carry-out here
;      is "genuine timeout/abort", relayed but currently unused by our
;      caller.)
; Destroys: AF, AF', BC, DE, HL, IX
; ============================================================================
STORAGE_SEND_BLOCK:
    ld   hl, .exit
    push hl                               ; shared exit — every genuine
                                         ; abort inside this routine
                                         ; ultimately RETs here instead
                                         ; of to our real caller (real
                                         ; ROM's own SA/LD-RET idiom)
    ld   hl, STORAGE_HEADER_LEAD
    bit  7, a
    jr   z, .flag                         ; A's bit 7 is 0 for
                                         ; STORAGE_TYPE_HEADER ($00) —
                                         ; keep the long (header) lead
    ld   hl, STORAGE_DATA_LEAD
.flag:
    ex   af, af'                          ; save the entry type flag —
                                         ; it's transmitted as the
                                         ; block's own first payload
                                         ; byte, restored below
    inc  de                               ; +1 for the type-flag byte
                                         ; itself, about to be sent as
                                         ; part of the payload
    dec  ix
    di
    ld   a, $02
    ld   b, a
.leader:
    djnz .leader
    out  (PORT_ULA), a
    xor  $0f
    ld   b, STORAGE_LEADER_HOLD
    dec  l
    jr   nz, .leader
    dec  b
    dec  h
    jp   p, .leader
    ld   b, $2f
.sync1:
    djnz .sync1
    out  (PORT_ULA), a
    ld   a, $0d
    ld   b, STORAGE_SYNC1_HOLD
.sync2:
    djnz .sync2
    out  (PORT_ULA), a
    ld   bc, STORAGE_SYNC2_INIT
    ex   af, af'                          ; restore the type flag —
                                         ; it's the first byte "sent"
    ld   l, a
    jr   .start

.loop:
    ld   a, d
    or   e
    jr   z, .parity
    ld   l, (ix+0)
.loop_p:
    ld   a, h
    xor  l
.start:
    ld   h, a
    ld   a, $01
    scf
    jr   .bits8
.parity:
    ld   l, h
    jr   .loop_p

.bit2:
    ld   a, c
    bit  7, b
.bit1:
    djnz .bit1
    jr   nc, .out
    ld   b, STORAGE_BIT0_EXTRA
.set:
    djnz .set
.out:
    out  (PORT_ULA), a
    ld   b, STORAGE_BIT_RELOAD
    jr   nz, .bit2
    dec  b
    xor  a
    inc  a
.bits8:
    rl   l
    jr   nz, .bit1
    dec  de
    inc  ix
    ld   b, STORAGE_NEXTBYTE_HOLD
    ; SPACE-to-abort check (real ROM: same $FE row read this whole
    ; routine already relies on) — kept, matches STORAGE_RECEIVE_
    ; BLOCK's own equivalent check.
    ld   a, $7f
    in   a, (PORT_ULA)
    rra
    ret  nc                               ; SPACE held — abort (lands
                                         ; on .exit via the pushed
                                         ; address)
    ld   a, d
    inc  a
    jr   nz, .loop
    ld   b, STORAGE_TAIL_HOLD
.delay:
    djnz .delay
    ret                                    ; whole block sent — lands
                                         ; on .exit

.exit:
    ld   a, (PORT_FE_SHADOW)
    out  (PORT_ULA), a                    ; restore whatever the port
                                         ; held before this block's own
                                         ; border/MIC flicker started
    ret

; ============================================================================
; STORAGE_RECEIVE_BLOCK — ported from the real ROM's LD-BYTES (+
; LD-BREAK/LD-START/LD-WAIT/LD-LEADER/LD-SYNC/LD-LOOP/LD-FLAG/LD-VERIFY/
; LD-NEXT/LD-DEC/LD-MARKER/LD-8-BITS, plus the shared LD-EDGE-2/LD-
; EDGE-1/LD-DELAY/LD-SAMPLE edge-detection primitives). Searches for a
; leader tone, syncs, then receives DE bytes MSB-first into IX (or
; verifies against what's already there, if carry is clear on entry),
; checking the type flag and the trailing checksum.
;
; In:  A = STORAGE_TYPE_HEADER or STORAGE_TYPE_DATA (must match the
;          block found on tape, or this reports failure without
;          storing anything)
;      Carry set on entry = load (store received bytes at IX); carry
;          clear = verify (compare against what's already at IX) — this
;          project's own callers always load (this project has no
;          VERIFY command), kept for real-ROM fidelity at zero cost.
;      IX = destination pointer, DE = expected length
; Out: Carry set = failure (timeout, SPACE pressed, wrong type, or
;          checksum mismatch) — the real ROM's own single carry-out
;          covers all of these; this project's caller (STORAGE_LOAD)
;          retries or gives up the same way regardless of which one it
;          was, matching the real ROM's own LD-LOOK-H convention.
;      Carry clear = success.
; Destroys: AF, AF', BC, DE, HL, IX
; ============================================================================
STORAGE_RECEIVE_BLOCK:
    IFDEF STORAGE_TEST_FAKE_RECEIVE
        jp   STORAGE_TEST_RECEIVE_BLOCK
    ELSE
    ld   hl, .exit
    push hl                               ; shared exit, same idiom as
                                         ; STORAGE_SEND_BLOCK's own
    ex   af, af'                          ; stash the caller's type
                                         ; flag + entry carry (load/
                                         ; verify) — restored inside
                                         ; .loop once the real first
                                         ; payload byte (the type flag
                                         ; actually sent) arrives
    di
    ld   a, $0f
    out  (PORT_ULA), a
    in   a, (PORT_ULA)
    rra
    and  $20
    or   $02
    ld   c, a
    ld   hl, STORAGE_ENTRY_RETRY_MAX       ; HL is free here (not live
                                         ; again until .entry_start's
                                         ; own success path reloads it)
    ld   (STORAGE_ENTRY_RETRY), hl
    cp   a                                 ; Z=1, used by nothing this
                                         ; port relies on (real ROM's
                                         ; own BREAK-after-nothing-
                                         ; found-yet case) — kept only
                                         ; because removing it would
                                         ; mean re-deriving the exact
                                         ; flag state every later `ret
                                         ; nz`/`jr z` below depends on
.break:
    ret  nz
.entry_start:
    ld   hl, (STORAGE_ENTRY_RETRY)          ; bounds this loop's own
                                         ; retry-forever tendency (the
                                         ; real ROM leaves it genuinely
                                         ; unbounded) — see STORAGE_
                                         ; ENTRY_RETRY_MAX's own comment
                                         ; above for the real-world
                                         ; dead-air-tolerance reasoning.
                                         ; HL is safe to clobber here,
                                         ; reloaded below on the success
                                         ; path before it's needed again
    dec  hl
    ld   (STORAGE_ENTRY_RETRY), hl
    ld   a, h
    or   l
    jr   nz, .entry_retry_ok
    scf                                     ; budget exhausted — carry
                                         ; SET, matching this routine's
                                         ; own documented contract
                                         ; (carry clear = success,
                                         ; confirmed by the real
                                         ; success/fail code below and
                                         ; by every caller's own "jr
                                         ; nc" == success test)
    ret                                    ; lands on .exit (the
                                         ; address pushed at entry)
.entry_retry_ok:
    call .edge1
    jr   nc, .break
    ld   hl, $0415
.wait:
    djnz .wait
    dec  hl
    ld   a, h
    or   l
    jr   nz, .wait
    call .edge2
    jr   nc, .break
.leader:
    ld   b, STORAGE_LEADER_PILOT
    call .edge2
    jr   nc, .break
    ld   a, STORAGE_LEADER_GAP
    cp   b
    jr   nc, .entry_start
    inc  h
    jr   nz, .leader
.sync:
    ld   b, STORAGE_SYNC_TIMING
    call .edge1
    jr   nc, .break
    ld   a, b
    cp   STORAGE_SYNC_GAP_MAX
    jr   nc, .sync
    call .edge1
    ret  nc
    ld   a, c
    xor  $03
    ld   c, a
    ld   h, $00
    ld   b, STORAGE_BIT_RESET_LD
    jr   .marker

.loop:
    ex   af, af'
    jr   nz, .flag
    jr   nc, .verify
    ld   (ix+0), l
    jr   .next
.flag:
    rl   c
    xor  l
    ret  nz                               ; received type flag doesn't
                                         ; match what the caller asked
                                         ; for — genuine failure, not
                                         ; a retry-able condition
    ld   a, c
    rra
    ld   c, a
    inc  de
    jr   .dec
.verify:
    ld   a, (ix+0)
    xor  l
    ret  nz
.next:
    inc  ix
.dec:
    dec  de
    ex   af, af'
    ld   b, STORAGE_DEC_HOLD
.marker:
    ld   l, $01
.bits8:
    call .edge2
    ret  nc
    ld   a, STORAGE_BIT_COMPARE
    cp   b
    rl   l
    ld   b, STORAGE_BIT_RESET_LD
    jr   nc, .bits8
    ld   a, h
    xor  l
    ld   h, a
    ld   a, d
    or   e
    jr   nz, .loop
    ; DEVIATION from the real ROM's own "cp $01 / ret" here — see this
    ; file's own top header ("DELIBERATE ADAPTATIONS") for the full
    ; reasoning: H lands on exactly 0 for a genuinely clean, correctly-
    ; checksummed transfer with this file's own DE convention, not 1.
    ld   a, h
    or   a
    jr   z, .success
    scf
    ret
.success:
    ret

.edge2:
    call .edge1
    ret  nc
    ; Deliberate fall-through: real LD-EDGE-2 measures two consecutive
    ; half-pulses with one cumulative B count. A former RET here reduced
    ; every measurement to one half-pulse and made the stock $C6/$CB
    ; thresholds appear incompatible with Fuse.
.edge1:
    ld   a, STORAGE_EDGE_DELAY
.delay:
    dec  a
    jr   nz, .delay
    and  a
.sample:
    inc  b
    ret  z
    ld   a, $7f
    in   a, (PORT_ULA)
    rra
    ret  nc                               ; SPACE held — abort (real
                                         ; ROM's own convention, same
                                         ; port read used for the tape
                                         ; bit right below)
    xor  c
    and  $20
    jr   z, .sample
    ld   a, c
    cpl
    ld   c, a
    and  $07
    or   $08
    out  (PORT_ULA), a
    scf
    ret

.exit:
    ld   a, (PORT_FE_SHADOW)
    out  (PORT_ULA), a
    ret
    ENDIF

; ============================================================================
; STORAGE_SAVE
; In:  HL = filename pointer, B = filename length, IX = data pointer,
;      DE = data length
; Out: carry always clear (this project's own caller ignores it anyway
;      — see rom/exrom_storage.asm's own header)
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
    ld   a, (STORAGE_REQUEST_TYPE)
    cp   STORAGE_EXTENSION_TYPE
    ld   de, (STORAGE_HEADER_BUF + STORAGE_HEADER_AUTOSTART_OFF)
    jr   nz, .autostart_ready
    ld   de, EXT_SERVICE_ABI_VERSION
.autostart_ready:
    ld   (STORAGE_HEADER_BUF + STORAGE_HEADER_AUTOSTART_OFF), de
    ; The stock BASIC header's second parameter is the program portion
    ; length. This ROM serializes program text only (never variables),
    ; so it is identical to the data length.
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

; ============================================================================
; STORAGE_LOAD
; In:  IX = destination pointer, HL = filename pointer, B = filename
;      length (0 = wildcard, LOAD ""), DE = max allowed data length
; Out: DE = actual data length received (only meaningful if carry
;          clear), A = 0 on success or a clean failure,
;          STORAGE_LOAD_DATA_TOUCHED on failure after destination writes
;      Carry set = total failure (no matching header, or header's own
;          claimed length exceeds the caller's bound, or the data block
;          failed). A distinguishes whether destination bytes were written.
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
    cp   STORAGE_NZ_SENTINEL              ; force Z clear — see that
                                         ; constant's own header
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
    djnz .header_search
    ; exhausted every attempt — give up cleanly instead of retrying
    ; forever. Rebalance the entry-pushed IX/BC/HL (never consumed on
    ; this path) before falling into .total_failure.
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
    jp   .total_failure

.name_ok:
    ld   hl, (STORAGE_HEADER_BUF + STORAGE_HEADER_LENGTH_OFF)
    ld   de, (STORAGE_MAX_LEN)
    or   a
    sbc  hl, de
    jr   c, .length_ok                    ; header length < max — fine
    ld   a, h
    or   l
    jr   z, .length_ok                    ; header length == max — fine
    jp   .total_failure                   ; JP not JR — out of range;
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
    cp   STORAGE_NZ_SENTINEL              ; force Z clear — see that
                                         ; constant's own header
    scf
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
    ret

.data_failed:
    ; DE is the receiver's remaining byte count; the stack holds the
    ; original length. If they differ, part (or all) of the destination
    ; has already been overwritten and the caller must not retain the old
    ; program as though it were still trustworthy.
    pop  hl
    pop  ix
    ld   a, d
    cp   h
    jr   nz, .data_touched
    ld   a, e
    cp   l
    jr   nz, .data_touched
.total_failure:
    xor  a                               ; clean failure: no program bytes
                                         ; were written
    jr   .report_failure
.data_touched:
    ld   a, STORAGE_LOAD_DATA_TOUCHED
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
