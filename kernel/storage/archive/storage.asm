; ============================================================================
; kernel/storage/storage.asm — from-scratch block-based tape I/O for SAVE/LOAD
;
; MIGRATED TO EXROM (2026-08-19, see rom/exrom_storage.asm) — this
; module's own source is UNCHANGED and stays the single source of
; truth for the tape protocol (unlike the checker migration, which
; copied basic.asm's routines verbatim into rom/exrom_checker.asm; a
; hand-copy here would mean keeping ~1700 lines of tape-timing code in
; sync by hand across two files, and would defeat the whole point of
; freeing Home ROM space in the first place). Instead, this file keeps
; using plain `call` for everything internal, but its only two calls
; OUT to a routine that isn't itself (MATH_MULTIPLY16/MATH_DIVIDE16,
; both in .report_save_progress and inside STORAGE_LOAD's own progress
; calc) go through STORAGE_MATH_MULTIPLY16/STORAGE_MATH_DIVIDE16 —
; EQUs the includer must define BEFORE this INCLUDE line:
;   - rom/test_storage.asm (Home-only isolated primitive testing, no
;     ROM-size ceiling — see that file's own header): aliases them
;     directly to the real MATH_MULTIPLY16/MATH_DIVIDE16, since
;     kernel/math is INCLUDEd in that same standalone build.
;   - rom/exrom_storage.asm (the real production path): aliases them
;     to KTAB_MATH_MULTIPLY16/KTAB_MATH_DIVIDE16 (include/exrom_
;     jumptable.inc) instead, since Home's real kernel/math never
;     moves and this file now runs from EXROM.
; This file has NO idea which one it's getting — that's the point.
;
; This project's SAVE/LOAD went through many rounds of trying to
; faithfully reproduce the real Sinclair/TS2068 cassette format,
; culminating in a byte-for-byte match of the real ROM's own LD-
; START/LD-WAIT/LD-LEADER/LD-SYNC — independently verified working (a
; tape our own SAVE produced loaded correctly on the genuine stock
; TS2068 ROM). But real-signal testing kept finding the underlying
; edge/pilot detection noisier in this specific environment than that
; all-or-nothing real protocol tolerates well. This project doesn't
; need historical backward compatibility — it's a reimagining, not a
; recreation — so this is a genuinely new design built on the proven
; low-level primitives (STORAGE_PULSE, STORAGE_WAIT_EDGE, STORAGE_
; SEND_BYTE/RECEIVE_BYTE, STORAGE_SEND_BLOCK/RECEIVE_BLOCK — all kept
; exactly as they were, unchanged and already real-signal-tested).
;
; The framing above those primitives is what changed: many small,
; independently checksummed 128-byte blocks, each sent TWICE — two
; full passes over the whole file, not interleaved, so a brief
; localized noise burst is unlikely to hit both copies of the same
; block — with a receiver that tracks which blocks it still needs and
; fills them in from whichever copy arrives intact. A bad block is
; now a small, recoverable, local event instead of a catastrophic
; all-or-nothing failure requiring an elaborate, strict-confirmation
; gate before trusting any data at all. That let the per-block pilot
; shrink way down too (STORAGE_BLOCK_PILOT_COUNT below, a few hundred
; pulses, not the old header/data split of 8063/3223) and let pilot
; confirmation itself simplify drastically (STORAGE_WAIT_PILOT below)
; since checksums plus redundancy are now the real safety net, not an
; elaborate up-front gate.
;
; Every data block is always exactly 128 bytes on the wire, including
; the last one — the last block's "real" length is derived after the
; fact from the header's own total-length field and the block's own
; ID, not carried as a separate length field on the wire. This means
; SEND may read a few bytes past the real end of program text for the
; final block's own padding (whatever happens to be in RAM there,
; harmless — it's never trusted as real data by anything that
; respects the header's own length), and RECEIVE always writes a full
; 128 bytes to a scratch buffer before deciding how much of it is
; real. Both sides get simpler for it: no length field to transmit,
; no special-casing the last block's size anywhere in the pulse-level
; protocol.
;
; Filename matching (LOAD "name" checking against what's actually on
; the tape) is real now — the header carries a filename, and the
; caller's requested name is compared against it. LOAD "" (empty
; string) is treated as a wildcard: accepts whatever header is found,
; no name check. Scope is deliberately narrower than the real
; Sinclair convention in one way: a non-matching header is a hard
; failure here, not a "skip forward and keep searching the rest of
; the tape for a differently-named file" — this project's own tape
; usage so far has always been one file per tape, and building true
; multi-file-tape scanning is a bigger, separate piece not attempted
; in this pass.
;
; Uses the standard ZX Spectrum-format pulse widths (Sinclair Wiki,
; "Spectrum tape interface" — verified via web search, not assumed):
;   pilot pulse  2168T
;   sync pulses   667T, 735T
;   '0' bit      2 x 855T
;   '1' bit      2 x 1710T
; Everything ABOVE the pulse level (block sizes, redundancy, framing,
; the header format) is this project's own design, not derived from
; any external source. The TS2068's Z80 clock (~3.58MHz) differs
; slightly from the Spectrum's 3.5MHz, which is irrelevant here: SAVE
; and LOAD both run on this ROM at this clock, so the T-state counts
; are self-consistent regardless of real-world duration.
; ============================================================================

    IFNDEF STORAGE_ASM
    DEFINE STORAGE_ASM

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"

STORAGE_MIC_BIT      EQU %00001000  ; bit 3 of port $FE = MIC output

; Delay-loop counts for STORAGE_PULSE's B register, one per pulse
; width, solved from the exact instruction sequence below (LD B,n +
; CALL + DJNZ-loop(B) + shadow read/xor/write + OUT (C),A == target
; T-states). Unchanged from the original design — these are real,
; already-verified pulse-level constants, not part of what changed.
STORAGE_B_PILOT      EQU 161   ; -> 2167T (target 2168T)
STORAGE_B_SYNC1      EQU 46    ; ->  672T (target  667T)
STORAGE_B_SYNC2      EQU 51    ; ->  737T (target  735T)
STORAGE_B_BIT0       EQU 60    ; ->  854T (target  855T)
STORAGE_B_BIT1       EQU 126   ; -> 1712T (target 1710T)

; Per-block pilot tone — short, since checksums + redundancy are the
; real safety net now, not an elaborate confirmation gate. Chosen to
; comfortably outlast STORAGE_PILOT_CONFIRM_COUNT below with margin
; for real-world jitter, while keeping per-block overhead small given
; this pilot plays out potentially hundreds of times per SAVE/LOAD
; (once per block, times two for redundancy).
STORAGE_BLOCK_PILOT_COUNT EQU 200

; Block-ID space: 0 is reserved for the header; 1..STORAGE_BLOCK_MAX_
; COUNT are data blocks. Capped at 127 (not 128) specifically so that
; 2x the count (both redundant passes) still fits comfortably in an
; 8-bit counter (2x127=254) — see STORAGE_SEND_DATA_BLOCKS/STORAGE_
; LOAD's own internal counters. 127 blocks x 128 bytes = 16256 bytes
; maximum program size — generous for this project's own short,
; token-based, single-file BASIC programs; a real, deliberate
; tradeoff against this already-tight sysvar range, not an oversight.
STORAGE_HEADER_ID       EQU 0
STORAGE_BLOCK_MAX_COUNT EQU 127
STORAGE_BLOCK_SIZE      EQU 128
; STORAGE_HEADER_FILENAME_LEN moved to include/sysvars.inc (2026-08-19)
; — basic.asm needs this same constant on the Home side (BASIC_DO_
; LOAD's filename padding) and no longer INCLUDEs this file at all
; now that SAVE/LOAD lives in EXROM. Still INCLUDEd here via sysvars.
; inc above, same name, no call-site changes needed in this file.

; STORAGE_HEADER_BUF layout (sysvars.inc), 12 bytes:
;   +0..+9   filename, 10 chars, space-padded/truncated
;   +10..+11 total data length (2 bytes, little-endian)
; Simplified from the old 18-byte real-Sinclair-format header (which
; also carried a program TYPE and two autostart PARAMS fields, neither
; meaningful for this custom ROM's own label-based BASIC).

; ============================================================================
; STORAGE_PULSE — UNCHANGED, proven, real-signal-tested.
; Emits one MIC-bit transition and holds it for a caller-chosen
; delay, forming half of one tape pulse edge. Reads PORT_FE_SHADOW
; (the byte GFX_SET_BORDER also maintains — see sysvars.inc) rather
; than writing the port blind, so an in-progress border colour
; survives a tape operation and vice versa.
;
; In:  B = delay-loop count (one of STORAGE_B_* above), set by the
;          caller immediately before CALL
;      C = PORT_ULA ($FE) — caller must set this ONCE before the
;          first pulse of a sequence and must NOT touch C again
;          until the sequence ends; this routine relies on it
;          staying $FE across every call.
; Out: B = 0 (guaranteed by DJNZ loop exit)
;      C unchanged (PORT_ULA)
; Destroys: A, B
; ============================================================================
STORAGE_PULSE:
    djnz $                       ; delay loop; exits with B=0
    ld   a, (PORT_FE_SHADOW)
    xor  STORAGE_MIC_BIT
    ld   (PORT_FE_SHADOW), a
    out  (c), a                  ; B=0 here, C=PORT_ULA -> port $00FE
    ret

; ============================================================================
; STORAGE_PILOT_TONE — UNCHANGED, proven, real-signal-tested.
; Emits the pilot tone preceding a block: DE equal-width pulses via
; repeated STORAGE_PULSE calls.
;
; In:  DE = pulse count (e.g. STORAGE_BLOCK_PILOT_COUNT)
;      C  = PORT_ULA — caller sets once before calling
; Out: DE = 0
; Destroys: A, B, DE
; ============================================================================
STORAGE_PILOT_TONE:
.loop:
    ld   b, STORAGE_B_PILOT
    call STORAGE_PULSE
    dec  de
    ld   a, d
    or   e
    jr   nz, .loop
    ret

; ============================================================================
; STORAGE_SYNC — UNCHANGED, proven, real-signal-tested.
; Emits the two sync pulses that end a pilot tone and mark the start
; of data bits.
;
; In:  C = PORT_ULA — caller sets once before calling
; Out: none
; Destroys: A, B
; ============================================================================
STORAGE_SYNC:
    ld   b, STORAGE_B_SYNC1
    call STORAGE_PULSE
    ld   b, STORAGE_B_SYNC2
    jp STORAGE_PULSE

; ============================================================================
; STORAGE_SEND_BYTE — UNCHANGED, proven, real-signal-tested.
; Sends one byte as 8 pairs of pulses, MSB first.
;
; In:  A = byte to send
;      C = PORT_ULA — caller sets once before calling
; Out: none
; Destroys: AF, B, DE
; ============================================================================
STORAGE_SEND_BYTE:
    ld   d, a
    ld   e, 8
.bitloop:
    rlc  d
    jr   c, .one
    ld   b, STORAGE_B_BIT0
    call STORAGE_PULSE
    ld   b, STORAGE_B_BIT0
    call STORAGE_PULSE
    jr   .next
.one:
    ld   b, STORAGE_B_BIT1
    call STORAGE_PULSE
    ld   b, STORAGE_B_BIT1
    call STORAGE_PULSE
.next:
    dec  e
    jr   nz, .bitloop
    ret

; ============================================================================
; STORAGE_SEND_BLOCK — UNCHANGED, proven, real-signal-tested.
; Sends a Block ID byte, then a run of payload bytes via STORAGE_
; SEND_BYTE, then appends a checksum byte (running XOR of the ID and
; every payload byte). Caller is responsible for the pilot tone and
; sync pulses beforehand.
;
; In:  A  = Block ID (0 = header, 1..STORAGE_BLOCK_MAX_COUNT = data)
;      HL = pointer to payload
;      DE = payload length — may be 0
;      C  = PORT_ULA — caller sets once before calling
; Out: none
; Destroys: AF, BC (B; C unchanged), DE, HL
; ============================================================================
STORAGE_SEND_BLOCK:
    ld   (STORAGE_CHECKSUM), a
    ld   (STORAGE_SEND_LEN), de
    call STORAGE_SEND_BYTE       ; send the ID byte itself
    ld   de, (STORAGE_SEND_LEN)
    ld   a, d
    or   e
    jr   z, .send_checksum       ; DE was 0 — empty payload
.byteloop:
    ld   a, (hl)
    ld   b, a
    ld   a, (STORAGE_CHECKSUM)
    xor  b
    ld   (STORAGE_CHECKSUM), a
    ld   a, b
    call STORAGE_SEND_BYTE
    inc  hl
    ld   de, (STORAGE_SEND_LEN)
    dec  de
    ld   (STORAGE_SEND_LEN), de
    ld   a, d
    or   e
    jr   nz, .byteloop
.send_checksum:
    ld   a, (STORAGE_CHECKSUM)
    jp STORAGE_SEND_BYTE

; ============================================================================
; STORAGE_WAIT_EDGE — UNCHANGED, proven, real-signal-tested.
; Waits for the EAR input bit (port $FE bit 6) to change from its
; last-known state, counting loop iterations elapsed as a proxy for
; time.
;
; In:  C = PORT_ULA — caller sets once for an entire receive sequence
; Out: A = iteration count elapsed (only meaningful if carry clear)
;      Carry set = timeout (no edge within STORAGE_EDGE_TIMEOUT
;           iterations)
; Destroys: AF, B (held fixed at 0 throughout), E, IY
; ============================================================================
STORAGE_EDGE_TIMEOUT  EQU 255   ; IYL wraps 255->0 as the timeout

STORAGE_WAIT_EDGE:
    ld   iy, 0
    ld   b, 0
    ld   a, (STORAGE_EAR_STATE)
    ld   e, a
.loop:
    inc  iyl
    jr   z, .timeout
    in   a, (c)
    and  %01000000
    cp   e
    jr   z, .loop
    ld   (STORAGE_EAR_STATE), a
    ld   a, iyl
    or   a                                ; clear carry: found an edge
    ret
.timeout:
    scf
    ret

; ============================================================================
; STORAGE_RECEIVE_INIT — UNCHANGED (diagnostic writes removed — see
; STORAGE_RECEIVE_BYTE's own header for why).
; Seeds STORAGE_EAR_STATE with the CURRENT actual EAR bit value.
; In:  C = PORT_ULA
; Out: none (STORAGE_EAR_STATE updated)
; Destroys: AF, B
; ============================================================================
STORAGE_RECEIVE_INIT:
    ld   b, 0
    in   a, (c)
    and  %01000000
    ld   (STORAGE_EAR_STATE), a
    ret

; ============================================================================
; STORAGE_RECEIVE_BYTE — bit-classification logic UNCHANGED, proven,
; real-signal-tested (dual-edge-sum classification). Diagnostic writes
; to the old STORAGE_BIT_LAST_B/STORAGE_BIT_MIN_B were removed when
; those sysvars were reclaimed for the new block-protocol design —
; but STORAGE_BIT_LAST_SUM and STORAGE_BIT_MIN_SUM (sysvars.inc) were
; added back after the new design's first successful pilot-
; confirmation run showed every received header byte coming back $FF,
; the same "every bit reads as 1" pattern seen before, and the exact
; same header content coming back byte-for-byte identical across two
; separate LOAD attempts on the same tape — needing real evidence
; rather than another guessed threshold, and specifically the real
; spread (LAST alone couldn't distinguish "every reading runs high"
; from "readings vary but something else keeps landing on this same
; wrong pattern"). The border-flip-per-edge feature (adopted from
; the real ROM during the earlier design) is kept for basic liveliness
; feedback, simplified to a single flip (no red/cyan-vs-blue/yellow
; phase distinction — the new status bar's live percentage is the
; primary progress signal now).
;
; Receives one byte as 8 pairs of edges, MSB first, classifying each
; bit from the SUM of both edges' timing (not just the first) — this
; averages out much of the single-edge noise that plagued the earlier
; design, found by comparing against the real ROM's own LD-BYTE
; routine.
;
; Uses IX as its bit-loop counter (not HL), so a caller can hold a
; destination buffer pointer in HL across repeated calls.
;
; In:  C = PORT_ULA (already set; STORAGE_EAR_STATE already seeded
;          via STORAGE_RECEIVE_INIT)
; Out: A = received byte (only meaningful if carry clear)
;      Carry set = timeout partway through
; Destroys: AF, B, D, E, IX, IY. Does NOT touch HL or C.
; ============================================================================
STORAGE_BIT_THRESHOLD EQU 32    ; iteration-SUM (both edges combined)
                                 ; below this = bit0, at or above =
                                 ; bit1. ORIGINALLY 51 (theoretical
                                 ; T-state-model midpoint: bit0 ~34.2,
                                 ; bit1 ~68.4 — see this project's own
                                 ; working notes). REVISED (2026-08-24)
                                 ; after a real user-reported LOAD
                                 ; FAILED against a genuinely-recorded
                                 ; Fuse tape (not this project's own
                                 ; debugger-injection shortcut) showed
                                 ; STORAGE_BIT_MIN_SUM consistently
                                 ; landing at 21-22 across several
                                 ; separate real attempts — well below
                                 ; the modeled bit0 target of 34.2, and
                                 ; too consistent across retries to be
                                 ; random Fuse timing noise (pilot
                                 ; detection, which shares the same
                                 ; STORAGE_WAIT_EDGE primitive but its
                                 ; own separately-calibrated
                                 ; STORAGE_PILOT_THRESHOLD, was
                                 ; SUCCEEDING throughout — this
                                 ; discrepancy looks specific to the
                                 ; data-bit pulses, not a uniform
                                 ; "our loop runs faster than modeled"
                                 ; issue). Rescaled proportionally from
                                 ; the observed ~21.5 real minimum
                                 ; against the 34.2 theoretical bit0
                                 ; target (scale ~0.629), giving 51*
                                 ; 0.629~=32. NOT YET independently
                                 ; confirmed against a real recorded-
                                 ; tape round trip — first real-world
                                 ; test of this revised value is
                                 ; pending; if LOAD still fails, the
                                 ; new STORAGE_BIT_LAST_SUM diagnostic
                                 ; (" L=", alongside " B=") on the next
                                 ; attempt will show whether real bit1
                                 ; sums are landing near the ~43
                                 ; rescaled target this value assumes,
                                 ; letting this be refined with real
                                 ; data instead of guessed again blind.

STORAGE_RECEIVE_BYTE:
    ld   ix, 8
    ld   d, 0
.bitloop:
    call STORAGE_WAIT_EDGE
    jr   c, .timeout
    push af                               ; stash first edge's count
    call .flip_border
    call STORAGE_WAIT_EDGE                ; second edge
    jr   c, .timeout_pop
    ld   b, a                             ; B = second edge's count
    call .flip_border
    pop  af                               ; A = first edge's count
    add  a, b                             ; A = sum of both edges
    jr   nc, .no_overflow
    ld   a, 255                           ; clamp rather than wrap —
                                         ; an overflowing sum is
                                         ; unambiguously a long
                                         ; (bit1-ish) reading either way
.no_overflow:
    ld   (STORAGE_BIT_LAST_SUM), a         ; diagnostic aid — see
                                         ; sysvars.inc. A holds the
                                         ; final (possibly clamped)
                                         ; sum here regardless of
                                         ; which path reached this
                                         ; point; LD (nn),A doesn't
                                         ; touch flags or A itself
    ld   b, a                              ; stash — B already
                                         ; documented as destroyed by
                                         ; this routine, free scratch
    ld   a, (STORAGE_BIT_MIN_SUM)
    cp   b
    jr   c, .no_new_min                    ; current min < b -- b is
                                         ; not a new low, skip
    ld   a, b
    ld   (STORAGE_BIT_MIN_SUM), a          ; diagnostic aid — see
                                         ; sysvars.inc
.no_new_min:
    ld   a, b                              ; restore the sum for
                                         ; classification below
    cp   STORAGE_BIT_THRESHOLD
    jr   c, .bit0
    ld   a, 1
    jr   .have_bit
.bit0:
    xor  a
.have_bit:
    or   a
    jr   z, .shift_zero
    sla  d
    inc  d
    jr   .shifted
.shift_zero:
    sla  d
.shifted:
    dec  ix
    ld   a, ixh
    or   ixl
    jr   nz, .bitloop
    ld   a, d
    or   a                                ; clear carry: success
    ret
.timeout_pop:
    pop  af
.timeout:
    scf
    ret

.flip_border:
    ; Simple liveliness feedback on every genuine edge — destroys AF
    ; freely, every call site here already has the value it needs
    ; preserved elsewhere (the stack, or B) before calling this.
    ld   a, (PORT_FE_SHADOW)
    xor  %00000111
    ld   (PORT_FE_SHADOW), a
    out  (c), a
    ret

; ============================================================================
; STORAGE_RECEIVE_BLOCK — UNCHANGED IN LOGIC, proven, real-signal-
; tested. Receives an ID byte, then a run of payload bytes via
; STORAGE_RECEIVE_BYTE, verifying a checksum byte at the end. Caller
; is responsible for the pilot/sync wait beforehand.
;
; In:  HL = destination buffer pointer (for payload bytes only)
;      DE = expected payload length — always STORAGE_BLOCK_SIZE (128)
;           for a data block, or 12 for the header, in this design
;      C  = PORT_ULA (already set; STORAGE_EAR_STATE already seeded)
; Out: A = received Block ID (only meaningful if carry clear)
;      Carry set = timeout OR checksum mismatch
; Destroys: AF, BC (B), DE, HL, IY (transitively)
; ============================================================================
STORAGE_RECEIVE_BLOCK:
    ld   (STORAGE_RECV_LEN), de
    call STORAGE_RECEIVE_BYTE             ; ID byte
    jr   c, .timeout
    ld   (STORAGE_CHECKSUM), a
    push af                               ; stash ID byte — this is
                                         ; this routine's own return
                                         ; value, but DE/AF get reused
                                         ; below before we're ready to
                                         ; hand it back

    ld   de, (STORAGE_RECV_LEN)
    ld   a, d
    or   e
    jr   z, .recv_checksum                ; DE was 0 — empty payload
.byteloop:
    call STORAGE_RECEIVE_BYTE
    jr   c, .timeout_pop
    ld   (hl), a
    inc  hl
    ld   b, a
    ld   a, (STORAGE_CHECKSUM)
    xor  b
    ld   (STORAGE_CHECKSUM), a
    ld   de, (STORAGE_RECV_LEN)
    dec  de
    ld   (STORAGE_RECV_LEN), de
    ld   a, d
    or   e
    jr   nz, .byteloop
.recv_checksum:
    call STORAGE_RECEIVE_BYTE             ; the checksum byte itself
    jr   c, .timeout_pop
    ld   b, a
    ld   a, (STORAGE_CHECKSUM)
    cp   b
    jr   nz, .mismatch_pop
    pop  af                               ; A = ID byte (success)
    or   a
    ret

.mismatch_pop:
.timeout_pop:
    pop  af                               ; discard stashed ID byte —
                                         ; rebalances the stack
.timeout:
    scf
    ret

; ============================================================================
; STORAGE_WAIT_PILOT
; Finds and consumes one block's pilot tone and both sync pulses.
; Rebuilt from scratch (see this file's header) for the new block
; protocol: much shorter pilot, and — critically — genuinely BOUNDED
; and TOLERANT of failure now, unlike the old real-ROM-faithful
; design. A failed search here just means "this one block attempt
; didn't pan out" to the caller, which can cheaply try again for the
; next block; there's no elaborate confirmation gate to protect
; anymore, because a corrupted or missed block is now individually
; recoverable (checksums + redundancy), not catastrophic.
;
; STORAGE_PILOT_THRESHOLD is the same real-signal-derived single-edge
; value the earlier design used (pulse widths haven't changed, only
; the framing above them) — an iteration count at/above which an edge
; counts as pilot-width.
;
; In:  C = PORT_ULA (already set)
; Out: Carry clear = pilot confirmed and both sync pulses found
;      Carry set = gave up (bounded search exhausted, or a genuine
;           STORAGE_WAIT_EDGE timeout) — not a failure the caller
;           needs to treat as catastrophic, see above
; Destroys: AF, BC, D, E (via STORAGE_WAIT_EDGE), HL, IY
;
; Also writes STORAGE_PILOT_ATTEMPTS and STORAGE_PILOT_LAST_EDGE
; (sysvars.inc) as diagnostic aids — added after a real LOAD attempt
; came back with STORAGE_HEADER_BUF completely untouched and an
; immediate failure, twice in a row, against a tape independently
; re-verified byte-perfect and freshly re-opened both times. ATTEMPTS
; shows how many search iterations actually ran before giving up
; (near 5000 = genuinely exhausted the search; small = gave up much
; earlier for some other reason). LAST_EDGE shows the most recent
; genuine (non-timeout) edge width seen — zero here alongside a small
; ATTEMPTS value would mean not even one real edge was ever detected.
; ============================================================================
STORAGE_PILOT_THRESHOLD     EQU 39
STORAGE_PILOT_CONFIRM_COUNT EQU 10    ; consecutive pilot-width edges
                                     ; required before trusting it —
                                     ; far fewer than the old design's
                                     ; 256, deliberately: enough to
                                     ; reject a lone stray reading,
                                     ; small enough to be fast, since
                                     ; checksums catch anything this
                                     ; lighter check lets through
STORAGE_PILOT_SEARCH_LIMIT_HI EQU 1   ; 500 split into bytes —
STORAGE_PILOT_SEARCH_LIMIT_LO EQU 244 ; Python-checked, not hand-
                                     ; derived (1*256+244=500).
                                     ; REVISED (2026-08-24) from the
                                     ; original 5000 after a real
                                     ; user-reported apparent lockup
                                     ; at 7% that turned out, via a
                                     ; real debug.bin memory-dump
                                     ; snapshot, to be genuinely
                                     ; bounded but impractically slow:
                                     ; STORAGE_RECEIVE_ATTEMPTS (the
                                     ; OUTER retry cap, see STORAGE_
                                     ; LOAD's own .receive_loop) was
                                     ; only at 5 -- nowhere near its
                                     ; 2000 cap -- while STORAGE_
                                     ; PILOT_ATTEMPTS showed 5000
                                     ; (this INNER search had just
                                     ; fully exhausted its old budget)
                                     ; and STORAGE_CONSECUTIVE_FAILS
                                     ; was only 1 of the 3 needed to
                                     ; trip the existing "tape ended"
                                     ; exit. At up to ~3.6ms per
                                     ; STORAGE_WAIT_EDGE call (its own
                                     ; 255-iteration budget), a single
                                     ; fully-exhausted 5000-attempt
                                     ; search could cost ~18 REAL
                                     ; seconds under Fuse -- and the
                                     ; existing 3-consecutive-failures
                                     ; safety net needed up to 3 of
                                     ; those before giving up, ~54s,
                                     ; indistinguishable from a true
                                     ; hang to a live tester watching
                                     ; an unmoving percentage and an
                                     ; unresponsive keyboard (LOAD
                                     ; blocks synchronously, no
                                     ; interrupts). Cutting this inner
                                     ; limit 10x does NOT reduce per-
                                     ; edge sensitivity at all (STORAGE_
                                     ; WAIT_EDGE's own timeout and
                                     ; STORAGE_PILOT_THRESHOLD are
                                     ; unchanged) -- it just gives up
                                     ; on THIS specific search sooner
                                     ; and defers to the OUTER receive_
                                     ; loop's own retry logic (which
                                     ; already existed, and now also
                                     ; has STORAGE_RECEIVE_ATTEMPTS_MAX
                                     ; as a hard backstop) for further
                                     ; attempts, at roughly 1/10th the
                                     ; real-time cost per attempt and
                                     ; therefore 1/10th the worst-case
                                     ; wait before either a real pilot
                                     ; is found or a genuine failure is
                                     ; reported.
STORAGE_WAIT_END_LIMIT EQU 250        ; REAL BUG FOUND AND FIXED
                                       ; (2026-08-24): .wait_end (below,
                                       ; inside this same routine) used
                                       ; to have NO bound of its own at
                                       ; all -- as long as real edges
                                       ; kept arriving at or above
                                       ; STORAGE_PILOT_THRESHOLD, it
                                       ; would loop forever waiting for
                                       ; a genuine sync transition,
                                       ; completely invisible to every
                                       ; other backstop in this file
                                       ; (STORAGE_RECEIVE_ATTEMPTS_MAX,
                                       ; the "3 consecutive failures"
                                       ; check) since none of those
                                       ; update until STORAGE_WAIT_PILOT
                                       ; actually returns -- found via a
                                       ; real user report of a genuine,
                                       ; indefinite freeze at a fixed
                                       ; percentage that persisted well
                                       ; past every other bound in this
                                       ; file, with STORAGE_RECEIVE_
                                       ; ATTEMPTS confirmed (via a debug.
                                       ; bin snapshot) frozen the whole
                                       ; time -- proving the hang was
                                       ; INSIDE one single STORAGE_WAIT_
                                       ; PILOT call, not in any of the
                                       ; outer retry logic already
                                       ; audited and fixed earlier this
                                       ; session. 250 comfortably covers
                                       ; this ROM's own STORAGE_SAVE
                                       ; (200-pulse pilot, minus the 10
                                       ; already consumed reaching
                                       ; STORAGE_PILOT_CONFIRM_COUNT)
                                       ; with margin, while guaranteeing
                                       ; this loop can no longer run
                                       ; longer than any other bounded
                                       ; search in this file.

STORAGE_WAIT_PILOT:
    call STORAGE_RECEIVE_INIT             ; fresh seed every call —
                                         ; avoids the staleness bug
                                         ; found in the earlier design
                                         ; (a stored reference going
                                         ; stale across a real-time
                                         ; gap between attempts)
    ld   hl, 0                            ; total attempts this search
    ld   d, 0                             ; consecutive good streak
.search:
    inc  hl
    ld   a, h
    cp   STORAGE_PILOT_SEARCH_LIMIT_HI
    jr   c, .try
    jp    nz, .giveup
    ld   a, l
    cp   STORAGE_PILOT_SEARCH_LIMIT_LO
    jp    nc, .giveup
.try:
    call STORAGE_WAIT_EDGE
    jp   c, .retry_flash                  ; REAL BUG FOUND AND FIXED:
                                         ; this used to jump straight
                                         ; to .giveup on a single
                                         ; per-edge timeout, reasoned
                                         ; as "nothing to find right
                                         ; now, not worth a retry" —
                                         ; but real-signal testing
                                         ; found this timeout firing
                                         ; on literally the FIRST
                                         ; attempt every time, even
                                         ; though rom/test_port_
                                         ; monitor.asm — using the
                                         ; exact same port-read logic,
                                         ; just with NO timeout at all
                                         ; — DID successfully detect
                                         ; real edges on this exact
                                         ; same tape (confirmed by the
                                         ; user's own observation of a
                                         ; genuine cyan/yellow loading
                                         ; pattern). That's conclusive:
                                         ; real signal reaches the
                                         ; emulated EAR input, it just
                                         ; doesn't always arrive within
                                         ; STORAGE_WAIT_EDGE's own 255-
                                         ; iteration (~3.6ms) budget —
                                         ; the exact T-state-vs-real-
                                         ; time mismatch this project
                                         ; already hit and fixed once
                                         ; before, in the earlier real-
                                         ; ROM-faithful design, and
                                         ; this newer, simplified
                                         ; STORAGE_WAIT_PILOT
                                         ; reintroduced by treating a
                                         ; single timeout as decisive
                                         ; instead of retrying. Now
                                         ; loops back to .search
                                         ; instead, consuming one unit
                                         ; of the existing outer 5000-
                                         ; attempt budget per retry
                                         ; rather than giving up
                                         ; outright on the first one —
                                         ; still genuinely bounded
                                         ; overall, just no longer
                                         ; fatally impatient on any
                                         ; single attempt
    ld   (STORAGE_PILOT_LAST_EDGE), a     ; diagnostic aid — see
                                         ; sysvars.inc (A still holds
                                         ; the count, LD (nn),A doesn't
                                         ; touch flags or A itself)
    cp   STORAGE_PILOT_THRESHOLD
    jr   nc, .streak_hit
    ; REAL FIX (leaky, not hard reset): real-signal testing showed
    ; the search genuinely exhausting its full 5000-attempt budget
    ; with a real, valid pilot-width edge detected along the way
    ; (STORAGE_PILOT_LAST_EDGE nonzero and above threshold) — meaning
    ; real signal IS being found, it just never strings together 10
    ; consecutive clean reads before a single miss wipes the whole
    ; streak back to zero. A hard reset has zero tolerance for the
    ; real-world intermittent noise this environment has shown
    ; throughout this whole project; a much earlier design pass tried
    ; exactly this same fix for exactly this same symptom and it
    ; worked then too. A single miss now costs one point of progress,
    ; not the entire streak.
    ld   a, d
    or   a
    jp    z, .search                       ; already at 0, nothing to
                                         ; decay further
    dec  d
    jp    .search
.streak_hit:
    ld   a, (PORT_FE_SHADOW)              ; simple liveliness flip —
    xor  %00000111                        ; see STORAGE_RECEIVE_BYTE's
    ld   (PORT_FE_SHADOW), a              ; own .flip_border for the
    out  (c), a                           ; same idea
    inc  d
    ld   a, d
    cp   STORAGE_PILOT_CONFIRM_COUNT
    jp    c, .search                       ; not enough consecutive yet
    ld   d, 0                              ; D's "consecutive good
                                         ; streak" job is done -- reused
                                         ; below as .wait_end's own
                                         ; bounded iteration counter
.wait_end:
    call STORAGE_WAIT_EDGE
    jp    c, .giveup
    ld   (STORAGE_PILOT_LAST_EDGE), a     ; diagnostic aid — see above
    cp   STORAGE_PILOT_THRESHOLD
    jr   c, .maybe_sync1                  ; short edge — possible sync1
    inc  d
    ld   a, d
    cp   STORAGE_WAIT_END_LIMIT
    jp    nc, .giveup                      ; consumed too many still-
                                          ; pilot-width edges without
                                          ; ever seeing a sync
                                          ; transition -- bounded
                                          ; backstop, see STORAGE_WAIT_
                                          ; END_LIMIT's own comment
    jr   .wait_end                        ; still pilot-width, keep
                                         ; consuming
.maybe_sync1:
    ; A short edge found -- POSSIBLE sync1, but a single short
    ; reading could be noise during otherwise-genuine pilot tone
    ; (matching this whole file's own established real-signal
    ; variability). The real Sinclair sync convention has BOTH sync
    ; pulses short — require the second one to also confirm before
    ; committing, rather than trusting one reading unconditionally.
    ; REAL BUG FOUND AND FIXED: without this check, a spurious short
    ; reading mid-pilot would be mistaken for the real transition,
    ; and the very next (still genuinely pilot-width) edge would get
    ; misread as sync2 — sending byte reception straight into the
    ; middle of the pilot tone instead of real data. This matches
    ; real-signal evidence exactly: received header bytes consistently
    ; garbled at the START (pilot-width edges reading as bit1) but
    ; varying in WHICH bytes across separate attempts on the same
    ; tape — consistent with the false-alarm point itself varying
    ; run to run, not a fixed miscalibration.
    call STORAGE_WAIT_EDGE                ; candidate second sync pulse
    jr   c, .giveup
    ld   (STORAGE_PILOT_LAST_EDGE), a     ; diagnostic aid — see above
    cp   STORAGE_PILOT_THRESHOLD
    jr   c, .sync_confirmed
    inc  d
    ld   a, d
    cp   STORAGE_WAIT_END_LIMIT
    jp    nc, .giveup
    jr   .wait_end                        ; candidate was ALSO still
                                         ; pilot-width -- the first
                                         ; short reading was a false
                                         ; alarm, not a genuine
                                         ; transition. Loop back
                                         ; rather than give up — this
                                         ; edge itself becomes a fresh
                                         ; pilot-width check, nothing
                                         ; wasted
.sync_confirmed:
    ; Both readings genuinely short -- real sync confirmed
    or   a                                ; clear carry: success
    ret

.retry_flash:
    ; Visible "still searching, not stuck" feedback for the retry
    ; loop above — a genuinely long bounded search (up to 5000
    ; individual-edge retries) with no visible activity would look
    ; identical to a real lockup from the outside. Same simple flip
    ; every other border-feedback point in this file uses.
    ld   a, (PORT_FE_SHADOW)
    xor  %00000111
    ld   (PORT_FE_SHADOW), a
    out  (c), a
    jp   .search

.giveup:
    ld   (STORAGE_PILOT_ATTEMPTS), hl     ; diagnostic aid — see
                                         ; sysvars.inc. HL still holds
                                         ; the total-attempts counter
                                         ; regardless of which jr
                                         ; above landed here
    scf
    ret

; ============================================================================
; STORAGE_REPORT_PROGRESS
; Calls STORAGE_PROGRESS_HOOK if one is set, so BASIC can redraw its
; own status bar to reflect the current STORAGE_OP_STATE/_PROGRESS_
; PCT/_BLOCKS_LOST live, mid-operation. This ROM has no interrupts, so
; SAVE/LOAD run as one long blocking call — there is no other way for
; a live percentage to reach the screen during it. Same "no input, no
; output, ret when done" hook contract as kernel/editor's own EDITOR_
; REDRAW_HOOK, but CALLED (not tail-jumped) since the caller needs
; control back afterward to keep processing more blocks.
;
; In:  none (reads the sysvars above directly)
; Out: none
; Destroys: nothing — preserves every register, so this can be called
;      freely from the middle of any block loop with no extra
;      save/restore needed at the call site.
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
    jr   z, .done
    ld   de, .done
    push de
    jp   (hl)
.done:
    pop  ix
    pop  hl
    pop  de
    pop  bc
    pop  af
    ret

; ============================================================================
; STORAGE_BUILD_HEADER
; Fills STORAGE_HEADER_BUF (sysvars.inc) with the caller's filename
; (space-padded/truncated to 10 chars) and total data length. Pure
; memory work, no pulses/ports touched.
;
; In:  HL = filename pointer
;      B  = filename length (0-10, clamped to 10 defensively — a
;           length over 10 here would overflow into the length field
;           that follows it in a fixed-size buffer)
;      DE = total data length
; Out: STORAGE_HEADER_BUF filled
; Destroys: AF, BC, DE, HL
; ============================================================================
STORAGE_BUILD_HEADER:
    ld   (STORAGE_HEADER_BUF+10), de

    ld   a, b
    cp   STORAGE_HEADER_FILENAME_LEN + 1
    jr   c, .len_ok
    ld   b, STORAGE_HEADER_FILENAME_LEN
.len_ok:
    ld   de, STORAGE_HEADER_BUF
    ld   c, STORAGE_HEADER_FILENAME_LEN
.copy:
    ld   a, b
    or   a
    jr   z, .pad_char
    ld   a, (hl)
    inc  hl
    dec  b
    jr   .store
.pad_char:
    ld   a, ' '
.store:
    ld   (de), a
    inc  de
    dec  c
    jr   nz, .copy
    ret

; ============================================================================
; STORAGE_SAVE
; The full save sequence: build the header, size-check the data,
; compute the block count, then send the header (two redundant
; copies) followed by every data block across two full redundant
; passes (all first copies, then all second copies — not
; interleaved, so a brief localized noise burst is unlikely to hit
; both copies of the same block).
;
; A defensive DI opens this sequence (kept from the earlier design —
; see STORAGE_LOAD's own header for why EI must never be added
; without a real interrupt handler existing first, which this ROM
; still doesn't have).
;
; In:  HL = filename pointer
;      B  = filename length (0-10, clamped — see STORAGE_BUILD_HEADER)
;      IX = data pointer (the actual bytes to save)
;      DE = data length (may be 0 — an empty program is real)
; Out: Carry clear = success. Carry set = DE exceeded STORAGE_BLOCK_
;      MAX_COUNT*STORAGE_BLOCK_SIZE (16256 bytes) — too large for this
;      format; nothing is sent in this case, checked before anything
;      else happens.
; Destroys: AF, BC, DE, HL, IY (transitively). IX unchanged.
; ============================================================================
STORAGE_SAVE:
    ; Size check FIRST, before touching anything else — verified via
    ; Python against every boundary value, not hand-derived and
    ; trusted blind.
    ld   a, d
    cp   $3F
    jr   c, .size_ok
    jr   nz, .too_large
    ld   a, e
    cp   $81
    jr   c, .size_ok
.too_large:
    ld   a, 7
    ld   (STORAGE_OP_STATE), a            ; SAVE FAILED (too large) —
                                         ; deliberately set even
                                         ; though C/DI haven't
                                         ; happened yet here: this
                                         ; failure is checked and
                                         ; reported before any pulses
                                         ; are ever sent
    scf
    ret
.size_ok:
    call STORAGE_BUILD_HEADER             ; stores DE (data length)
                                         ; into STORAGE_HEADER_BUF+10
                                         ; as its very first action,
                                         ; then reuses DE internally
                                         ; for the filename copy loop
                                         ; — reload the real value
                                         ; below rather than trust DE
                                         ; to have survived the call
    ld   de, (STORAGE_HEADER_BUF+10)
    call .compute_block_count             ; sets STORAGE_BLOCK_COUNT

    di
    ld   c, PORT_ULA
    xor  a
    ld   (STORAGE_PROGRESS_PCT), a
    ld   a, 1
    ld   (STORAGE_OP_STATE), a            ; SAVING
    call STORAGE_REPORT_PROGRESS

    ; header, copy A, then copy B — identical, sent twice
    call .send_header_copy
    call .send_header_copy

    ld   a, (STORAGE_BLOCK_COUNT)
    or   a
    jr   z, .no_data_blocks                ; empty program — header
                                         ; alone is the whole file

    ld   iy, 0                            ; step_base = 0 for pass 1
                                         ; — IY is untouched by every
                                         ; SEND-side primitive above,
                                         ; free to hold this across
                                         ; the whole pass
    call .send_one_pass
    ld   a, (STORAGE_BLOCK_COUNT)
    ld   iyl, a                           ; step_base = N for pass 2
    ld   iyh, 0
    call .send_one_pass

.no_data_blocks:
    ld   a, 2
    ld   (STORAGE_OP_STATE), a            ; SAVED
    or   a                                ; clear carry: success
    ret

; ---- STORAGE_SAVE's own local helpers ----

.send_header_copy:
    ; One header-block transmission — sent twice in a row (identical),
    ; same redundant-copy convention every other block uses.
    ld   de, STORAGE_BLOCK_PILOT_COUNT
    call STORAGE_PILOT_TONE
    call STORAGE_SYNC
    ld   a, STORAGE_HEADER_ID
    ld   hl, STORAGE_HEADER_BUF
    ld   de, 12
    jp   STORAGE_SEND_BLOCK        ; tail call — STORAGE_SEND_BLOCK's
                                   ; own ret returns straight to
                                   ; .send_header_copy's caller

.compute_block_count:
    ; N = ceil(DE/128), DE already known <= 16256 by the caller's own
    ; size check — verified exhaustively via Python against every
    ; value 0-16384 before this was written.
    ld   a, d
    or   e
    jr   z, .zero_len
    ld   a, d
    add  a, a                             ; A = D*2 (D<<1) — safe,
                                         ; D<=$3F here so A<=$7E
    ld   b, a
    ld   a, e
    and  $80
    jr   z, .no_carry_bit
    inc  b
.no_carry_bit:
    ld   a, e
    and  $7F
    or   a
    jr   z, .no_round_up
    inc  b
.no_round_up:
    ld   a, b
    ld   (STORAGE_BLOCK_COUNT), a
    ret
.zero_len:
    xor  a
    ld   (STORAGE_BLOCK_COUNT), a
    ret

.send_one_pass:
    ; Sends data blocks 1..N once (one full redundant pass), using
    ; IY as this pass's step_base (0 or N) for progress percentage —
    ; set by the caller immediately before this call.
    ld   a, 1
    ld   (STORAGE_CURRENT_ID), a
.pass_loop:
    ; source address = IX + (id-1)*128
    ld   a, (STORAGE_CURRENT_ID)
    dec  a
    ld   h, a
    ld   l, 0
    srl  h
    rr   l                                ; HL = (id-1)*128
    push ix
    pop  de
    add  hl, de                           ; HL = source address
    ex   de, hl                           ; DE = source address (HL
                                         ; about to be clobbered by
                                         ; the pilot/sync calls below)

    push de                               ; stash source address
    ld   de, STORAGE_BLOCK_PILOT_COUNT
    call STORAGE_PILOT_TONE
    call STORAGE_SYNC
    pop  hl                               ; HL = source address
    ld   a, (STORAGE_CURRENT_ID)
    push af                               ; stash ID — SEND_BLOCK's
                                         ; own DE parameter load below
                                         ; doesn't touch A, but being
                                         ; explicit here costs nothing
                                         ; and removes any doubt
    ld   de, STORAGE_BLOCK_SIZE
    pop  af
    call STORAGE_SEND_BLOCK

    call .report_save_progress

    ld   a, (STORAGE_CURRENT_ID)
    ld   hl, STORAGE_BLOCK_COUNT
    cp   (hl)
    jr   z, .pass_done                    ; just processed the last
                                         ; block of this pass — stop
    inc  a
    ld   (STORAGE_CURRENT_ID), a
    jp    .pass_loop
.pass_done:
    ret

.report_save_progress:
    ; percentage = (IYL + STORAGE_CURRENT_ID) * 100 / (2 * N)
    push bc
    push de
    push hl
    ld   a, (STORAGE_CURRENT_ID)
    add  a, iyl                           ; A = total steps done so
                                         ; far across both passes —
                                         ; safe from overflow: IYL
                                         ; and STORAGE_CURRENT_ID are
                                         ; each <= 127, sum <= 254
    ld   l, a
    ld   h, 0                             ; HL = steps done (widened)
    ld   de, 100
    call STORAGE_MATH_MULTIPLY16                  ; HL = steps_done * 100
    push hl                               ; stash product
    ld   a, (STORAGE_BLOCK_COUNT)
    add  a, a                             ; A = 2*N — safe, N<=127
                                         ; so 2N<=254
    ld   e, a
    ld   d, 0                             ; DE = 2*N (divisor)
    pop  hl                               ; HL = product (dividend)
    call STORAGE_MATH_DIVIDE16                    ; HL = percentage
    ld   a, l
    ld   (STORAGE_PROGRESS_PCT), a
    call STORAGE_REPORT_PROGRESS
    pop  hl
    pop  de
    pop  bc
    ret

; ============================================================================
; STORAGE_LOAD
; The full load sequence: receive the header (trying both redundant
; copies), match or wildcard its filename, compute the expected block
; count, then repeatedly search for and receive data blocks — from
; either redundant pass, tracked via STORAGE_BLOCK_BITMAP — until
; every needed block is filled or the tape appears to have ended.
;
; Filename matching: if the caller's B is 0, treat as LOAD "" (accept
; whatever header is found, no name check — the Sinclair wildcard
; convention). Otherwise the caller's HL/B must match the header's
; own filename exactly (space-padding included) or this fails
; outright — no scanning forward for a differently-named file
; elsewhere on the tape, a deliberately narrower scope than the real
; convention; see this file's header comment.
;
; In:  IX = destination pointer for the loaded data
;      HL = filename to match (ignored if B=0)
;      B  = filename length (0 = wildcard, LOAD "")
;      DE = max allowed data length (see STORAGE_MAX_LEN in sysvars.
;           inc) — the header's own claimed length is checked against
;           this before any data block is requested; a header
;           claiming more is rejected the same way a totally missing
;           header would be, rather than trusted and written
; Out: DE = actual data length received (from the header's own length
;           field — only meaningful if carry clear)
;      A  = STORAGE_BLOCKS_LOST count (0 if every block was recovered)
;      Carry set = total failure — no matching header ever found, OR
;      the header's claimed length exceeded the caller's bound. A
;      partial load (some data blocks lost even after both redundant
;      copies) is NOT a carry-set failure — it returns success with a
;      nonzero A, since the header and most/all of the program did
;      arrive; the caller decides how to present that.
; Destroys: AF, BC, DE, HL, IY (transitively). IX unchanged.
; ============================================================================
STORAGE_RECEIVE_ATTEMPTS_MAX EQU 2000  ; hard cap on .receive_loop's own
                                       ; total iteration count — see
                                       ; STORAGE_RECEIVE_ATTEMPTS's own
                                       ; sysvars.inc header for why this
                                       ; exists. A full-size program
                                       ; (STORAGE_BLOCK_COUNT near its
                                       ; own ~127 max) needs close to
                                       ; 254 genuine iterations just for
                                       ; both redundant passes with
                                       ; perfect signal, so this is set
                                       ; generously above that rather
                                       ; than tight — it only needs to
                                       ; be FINITE, not minimal; a real
                                       ; "tape ended" is still normally
                                       ; caught first by the existing
                                       ; 3-consecutive-pilot-failures
                                       ; check, which is far faster.
STORAGE_HEADER_ATTEMPTS_MAX EQU 30    ; header search's own bound —
                                       ; see the .header_retry loop's
                                       ; own comment (STORAGE_LOAD
                                       ; below) for why this exists
                                       ; separately from STORAGE_
                                       ; RECEIVE_ATTEMPTS_MAX above. At
                                       ; ~1.8s/attempt (STORAGE_PILOT_
                                       ; SEARCH_LIMIT_HI/_LO), 30 gives
                                       ; ~54s total real-world patience
                                       ; for the header's own pilot
                                       ; tone to actually start —
                                       ; comfortably at or above the
                                       ; old fixed-two-tries design's
                                       ; ~36s, not tight.
STORAGE_LOAD:
    di                                     ; see STORAGE_SAVE's own
                                         ; header for why EI must
                                         ; never be added without a
                                         ; real interrupt handler
                                         ; existing first
    ld   (STORAGE_MAX_LEN), de             ; stash the caller's bound
                                         ; before DE gets reused below
                                         ; — this is STORAGE_LOAD's
                                         ; only chance to save it
    ld   c, PORT_ULA

    ld   a, 255
    ld   (STORAGE_BIT_MIN_SUM), a          ; diagnostic aid — see
                                         ; sysvars.inc. Reset once
                                         ; here, not inside STORAGE_
                                         ; WAIT_PILOT/RECEIVE_INIT
                                         ; (which run on every pilot-
                                         ; search retry — far too
                                         ; often to be a meaningful
                                         ; reset point)

    ld   a, 1
    ld   (STORAGE_LOAD_STAGE), a           ; diagnostic aid — see
                                         ; sysvars.inc
    ld   a, $EE
    ld   (STORAGE_HEADER_BUF), a           ; sentinel — a real header
                                         ; byte 0 is always the first
                                         ; filename character, never
                                         ; $EE, so this can't be
                                         ; mistaken for genuine
                                         ; leftover-from-a-prior-
                                         ; success data if THIS
                                         ; attempt hasn't reached
                                         ; header reception yet

    push hl                               ; stash caller's filename
    push bc                               ; and its length, across
                                         ; the header-receive attempts
                                         ; below (which use HL/BC
                                         ; freely themselves)

    xor  a
    ld   (STORAGE_PROGRESS_PCT), a
    ld   a, 3
    ld   (STORAGE_OP_STATE), a            ; LOADING
    call STORAGE_REPORT_PROGRESS

    ld   b, STORAGE_HEADER_ATTEMPTS_MAX   ; REVISED (2026-08-24): used to
                                         ; be a fixed "try exactly twice"
                                         ; (one shot at each of the
                                         ; header's own two redundant
                                         ; copies), relying entirely on
                                         ; STORAGE_WAIT_PILOT's OWN inner
                                         ; search budget for patience —
                                         ; fine while that budget was
                                         ; 5000 (~18s/attempt, ~36s
                                         ; total), but once that budget
                                         ; was cut to 500 for
                                         ; responsiveness elsewhere (see
                                         ; STORAGE_PILOT_SEARCH_LIMIT_HI/
                                         ; _LO's own comment), "try
                                         ; twice" alone gave the header
                                         ; only ~3.6s of real patience —
                                         ; not enough to ride out a real
                                         ; recording's lead-in gap before
                                         ; its pilot tone actually
                                         ; starts, causing a genuine
                                         ; regression: immediate LOAD
                                         ; FAILED (S=01, P=00 — zero
                                         ; edges ever seen) on a tape
                                         ; that was still actively
                                         ; playing. A bounded retry loop
                                         ; here restores comparable
                                         ; total patience (~54s worst
                                         ; case) while keeping the
                                         ; cheaper, more responsive per-
                                         ; attempt cost.
.header_retry:
    push bc                               ; B (attempts remaining) must
                                         ; survive the call below —
                                         ; STORAGE_WAIT_PILOT/RECEIVE_
                                         ; BLOCK both destroy BC. C
                                         ; (PORT_ULA) round-trips
                                         ; unchanged through the same
                                         ; push/pop regardless of what
                                         ; the call does to it
                                         ; internally.
    call .try_receive_header
    pop  bc
    jr   nc, .header_ok
    djnz .header_retry
    jp   .header_failed

.header_ok:
    ; A real header block arrived (checksum verified, ID==0 already
    ; confirmed by .try_receive_header below) — check the filename
    pop  bc                               ; BC = caller's filename
                                         ; length (B) — restore
    pop  hl                               ; HL = caller's filename
                                         ; pointer — restore
    ld   a, b
    or   a
    jp    z, .name_matches                  ; wildcard — LOAD ""
    ld   a, b
    cp   STORAGE_HEADER_FILENAME_LEN
    jr   nz, .name_mismatch                ; caller's own name isn't
                                         ; even 10 chars — can't
                                         ; match a space-padded field
                                         ; (BASIC_DO_LOAD is expected
                                         ; to have already space-
                                         ; padded a real filename to
                                         ; 10 before calling here;
                                         ; this is a defensive check,
                                         ; not the primary contract)
    push hl
    ld   de, STORAGE_HEADER_BUF
    ld   b, STORAGE_HEADER_FILENAME_LEN
.name_cmp:
    ld   a, (de)
    cp   (hl)
    jr   nz, .name_cmp_fail
    inc  hl
    inc  de
    djnz .name_cmp
    pop  hl
    jr   .name_matches
.name_cmp_fail:
    pop  hl
.name_mismatch:
    ld   a, 6
    ld   (STORAGE_OP_STATE), a            ; LOAD FAILED
    scf
    ret

.name_matches:
    ld   a, 2
    ld   (STORAGE_LOAD_STAGE), a           ; diagnostic aid — see
                                         ; sysvars.inc
    ld   de, (STORAGE_HEADER_BUF+10)      ; DE = total data length —
                                         ; this is STORAGE_LOAD's own
                                         ; success return value too,
                                         ; stashed on the stack across
                                         ; everything below
    ld   hl, (STORAGE_MAX_LEN)             ; reject here, before any
    or   a                               ; data block is requested,
    sbc  hl, de                          ; rather than trust a claim
    jr   c, .name_mismatch                ; that would overrun the
                                         ; caller's destination —
                                         ; same failure path/state as
                                         ; a real filename mismatch,
                                         ; this is just another way
                                         ; the header turned out to
                                         ; be unusable
    push de
    call .compute_block_count             ; sets STORAGE_BLOCK_COUNT
                                         ; (shared with STORAGE_SAVE's
                                         ; own identical logic —
                                         ; DEFINE'd once, see below)

    call .zero_bitmap
    xor  a
    ld   (STORAGE_BLOCKS_LOST), a

    ld   a, (STORAGE_BLOCK_COUNT)
    or   a
    jp    z, .load_complete                 ; empty program — header
                                         ; alone was the whole file

    ld   a, 3
    ld   (STORAGE_LOAD_STAGE), a           ; diagnostic aid — see
                                         ; sysvars.inc
    ld   d, 0                             ; D = consecutive pilot
                                         ; failures in a row — 3 in a
                                         ; row is treated as "tape has
                                         ; ended", see the main loop
                                         ; below
    ld   hl, 0
    ld   (STORAGE_RECEIVE_ATTEMPTS), hl    ; hard backstop — see that
                                          ; sysvar's own header for why
                                          ; this loop needs one
                                          ; independent of D above
.receive_loop:
    push de                                ; D (consecutive-pilot-
                                          ; failure count) must survive
                                          ; this check unchanged — C
                                          ; alone (not the DE pair) is
                                          ; this routine's own PORT_ULA,
                                          ; set once at entry and relied
                                          ; on for the rest of it, so DE
                                          ; is safe to use here as long
                                          ; as D itself is restored
    ld   hl, (STORAGE_RECEIVE_ATTEMPTS)
    inc  hl
    ld   (STORAGE_RECEIVE_ATTEMPTS), hl
    ld   de, STORAGE_RECEIVE_ATTEMPTS_MAX
    or   a
    sbc  hl, de
    pop  de
    jp   nc, .tape_ended                   ; hit the hard cap — give up
                                          ; exactly like the existing
                                          ; "3 consecutive pilot
                                          ; failures" path does, rather
                                          ; than retry forever
    call STORAGE_WAIT_PILOT
    jr   nc, .pilot_ok
    inc  d
    ld   a, d
    ld   (STORAGE_CONSECUTIVE_FAILS), a    ; diagnostic aid — see
                                         ; sysvars.inc
    cp   3
    jp    nc, .tape_ended
    jr   .receive_loop
.pilot_ok:
    ld   d, 0                             ; reset — found real signal
    ld   a, d
    ld   (STORAGE_CONSECUTIVE_FAILS), a    ; diagnostic aid — see
                                         ; sysvars.inc
    ld   hl, EDIT_LINE_BUF                ; scratch receive target —
                                         ; unused during SAVE/LOAD,
                                         ; exactly STORAGE_BLOCK_SIZE
                                         ; (128) bytes, avoids needing
                                         ; a new sysvar for this
    ld   de, STORAGE_BLOCK_SIZE
    call STORAGE_RECEIVE_BLOCK
    jr   c, .receive_loop                 ; timeout or checksum
                                         ; mismatch on this attempt —
                                         ; just try the next one, this
                                         ; block is still recoverable
                                         ; from its other copy
    ; A = received Block ID
    or   a
    jp    z, .receive_loop                 ; ID 0 — the header's own
                                         ; second redundant copy,
                                         ; encountered again during
                                         ; the data phase; ignore it
    ld   (STORAGE_CURRENT_ID), a
    ld   hl, STORAGE_BLOCK_COUNT
    cp   (hl)
    jr   nc, .id_range_check              ; A >= N — could be exactly
                                         ; N (valid) or corrupted
                                         ; above it (invalid); check
                                         ; precisely below
    jr   .id_in_range
.id_range_check:
    jr   z, .id_in_range                  ; A == N — valid, the last
                                         ; block
    jp    .receive_loop                    ; A > N — out of range,
                                         ; vanishingly unlikely given
                                         ; the checksum already
                                         ; passed, but discard rather
                                         ; than trust it
.id_in_range:
    call .bitmap_test_and_set             ; carry set if this ID was
                                         ; ALREADY marked (a duplicate
                                         ; from the other redundant
                                         ; pass) — sets it either way
    jp    c, .receive_loop                 ; already had it — discard
                                         ; this copy, don't re-copy
                                         ; or double-count progress

    ld   a, 10
    ld   (STORAGE_LOAD_STAGE), a           ; diagnostic aid — see
                                         ; sysvars.inc. Narrow
                                         ; checkpoint: confirms this
                                         ; exact point was reached —
                                         ; genuinely new block, about
                                         ; to copy it

    ; genuinely new block — copy from the scratch buffer to its real
    ; destination
    ld   a, (STORAGE_CURRENT_ID)
    dec  a
    ld   h, a
    ld   l, 0
    srl  h
    rr   l                                ; HL = (id-1)*128 offset
    push ix
    pop  de
    add  hl, de                           ; HL = real destination
    ex   de, hl                           ; DE = destination, HL free
    ld   hl, EDIT_LINE_BUF
    ld   bc, STORAGE_BLOCK_SIZE
    ldir                                  ; copy all 128 bytes — any
                                         ; trailing padding beyond the
                                         ; real total length is
                                         ; harmless, never trusted as
                                         ; real data by anything that
                                         ; respects the header's own
                                         ; length field

    ld   a, 11
    ld   (STORAGE_LOAD_STAGE), a           ; diagnostic aid — see
                                         ; sysvars.inc. Narrow
                                         ; checkpoint: confirms the
                                         ; copy itself completed,
                                         ; about to check for overall
                                         ; completion

    call .report_load_progress
    call .bitmap_all_set
    jp    nc, .receive_loop                 ; still more needed
    jr   .load_complete

.tape_ended:
.load_complete:
    ld   a, 4
    ld   (STORAGE_LOAD_STAGE), a           ; diagnostic aid — see
                                         ; sysvars.inc
    call .count_lost_blocks               ; sets STORAGE_BLOCKS_LOST
    ld   a, (STORAGE_BLOCKS_LOST)
    or   a
    jr   nz, .some_lost
    ld   a, 4
    ld   (STORAGE_OP_STATE), a            ; LOADED, no errors
    jr   .finish
.some_lost:
    ld   a, 5
    ld   (STORAGE_OP_STATE), a            ; LOADED, some blocks lost
.finish:
    pop  de                               ; DE = total data length
                                         ; (stashed way above)
    ld   a, (STORAGE_BLOCKS_LOST)
    or   a                                ; clear carry: success
                                         ; either way — a partial
                                         ; load is not a hard failure,
                                         ; see this routine's own
                                         ; header
    ret

.header_failed:
    pop  bc                               ; rebalance the two pushes
    pop  hl                               ; from this routine's own
                                         ; entry — matches .header_ok's
                                         ; own pops, kept balanced on
                                         ; every exit path
    ld   a, 6
    ld   (STORAGE_OP_STATE), a            ; LOAD FAILED
    scf
    ret

; ---- STORAGE_LOAD's own local helpers ----

.try_receive_header:
    call STORAGE_WAIT_PILOT
    ret  c                                 ; relay a pilot-search
                                         ; failure directly
    ld   hl, STORAGE_HEADER_BUF
    ld   de, 12
    call STORAGE_RECEIVE_BLOCK
    ret  c                                 ; relay a receive failure
    or   a
    jr   z, .is_header
    scf                                    ; got a real block, but
                                         ; not the header (ID != 0) —
                                         ; treat as failure for this
                                         ; attempt
    ret
.is_header:
    or   a                                 ; clear carry: genuine
                                         ; header received
    ret

.compute_block_count:
    ; identical logic to STORAGE_SAVE's own .compute_block_count —
    ; duplicated rather than shared across a routine boundary here,
    ; since both are short, self-contained, and this avoids adding
    ; another cross-section CALL target for a few lines of simple
    ; arithmetic
    ld   a, d
    or   e
    jr   z, .zero_len
    ld   a, d
    add  a, a
    ld   b, a
    ld   a, e
    and  $80
    jr   z, .no_carry_bit
    inc  b
.no_carry_bit:
    ld   a, e
    and  $7F
    or   a
    jr   z, .no_round_up
    inc  b
.no_round_up:
    ld   a, b
    ld   (STORAGE_BLOCK_COUNT), a
    ret
.zero_len:
    xor  a
    ld   (STORAGE_BLOCK_COUNT), a
    ret

.zero_bitmap:
    push hl
    push bc
    ld   hl, STORAGE_BLOCK_BITMAP
    ld   b, 16
    xor  a
.zb_loop:
    ld   (hl), a
    inc  hl
    djnz .zb_loop
    pop  bc
    pop  hl
    ret

.bitmap_test_and_set:
    ; In: STORAGE_CURRENT_ID (1-based). Out: carry set if this bit
    ; was ALREADY set (a duplicate); sets the bit either way.
    push bc
    push hl
    ld   a, (STORAGE_CURRENT_ID)
    dec  a                                ; 0-based bit index
    ld   c, a
    and  %00000111                        ; bit position within byte
    ld   b, a
    ld   a, c
    rrca
    rrca
    rrca
    and  %00011111                        ; byte index (0-15)
    ld   c, a
    ld   b, 0
    ld   hl, STORAGE_BLOCK_BITMAP
    add  hl, bc
    ld   c, (hl)                          ; C = the byte holding this
                                         ; bit
    ld   a, (STORAGE_CURRENT_ID)
    dec  a
    and  %00000111
    ld   b, a                             ; B = bit position (0-7)
    ld   a, 1
.shift_mask:
    or   a
    jr   z, .mask_ready
    dec  b
    jp   m, .mask_ready
    sla  a
    jr   .shift_mask
.mask_ready:
    ; A = mask with the target bit set (a crude but simple shift —
    ; B counts down from the bit position, shifting A left that many
    ; times; harmless once B goes negative, "jp m" catches that)
    ld   b, a
    ld   a, c
    and  b
    or   a
    jr   nz, .already_set
    ld   a, c
    or   b
    ld   c, a
    ld   a, (STORAGE_CURRENT_ID)
    dec  a
    and  %00000111
    ld   b, a
    ld   a, c
    ld   (hl), a
    pop  hl
    pop  bc
    or   a                                ; clear carry: new bit
    ret
.already_set:
    pop  hl
    pop  bc
    scf                                    ; carry set: duplicate
    ret

.bitmap_all_set:
    ; Out: carry set if every needed block (1..STORAGE_BLOCK_COUNT)
    ; is marked in the bitmap
    push bc
    push de
    push hl
    ld   a, (STORAGE_BLOCK_COUNT)
    ld   b, a                             ; B = N, blocks still to
                                         ; verify
    ld   hl, STORAGE_BLOCK_BITMAP
    ld   c, 0                             ; C = current bit index
                                         ; (0-based), across the
                                         ; whole bitmap
.check_loop:
    ld   a, b
    or   a
    jp    z, .all_set                      ; checked N bits, all set
    ld   a, c
    and  %00000111
    ld   d, a                             ; D = bit position
    ld   a, c
    rrca
    rrca
    rrca
    and  %00011111
    ld   e, a                             ; E = byte offset
    push hl
    ld   a, l
    add  a, e
    ld   l, a
    ld   a, h
    adc  a, 0
    ld   h, a                             ; HL = STORAGE_BLOCK_BITMAP
                                         ; + byte offset — deliberately
                                         ; NOT read yet (see .test_ready)
    push bc
    ld   b, d
    ld   c, 1
.test_shift:
    ld   a, b
    or   a
    jr   z, .test_ready
    dec  b
    sla  c
    jr   .test_shift
.test_ready:
    ; REAL BUG FOUND AND FIXED: this used to read the bitmap byte into
    ; A, then "pop hl" (restoring the caller's own HL), before ever
    ; reaching .test_shift — whose own "ld a,b" (its loop-counter
    ; check) overwrites A with the counter's value, almost always 0
    ; by the time the loop exits, destroying the just-read byte
    ; before "and c" ever tested it. Made this routine effectively
    ; unable to detect ANY set bit, for any block, ever — see
    ; .rlp_test's own comment in .report_load_progress for the full
    ; story (found via a full instruction-level simulator, the same
    ; fix applied there). Fixed by moving the read AND the "pop hl"
    ; that used to immediately follow it to here — HL still correctly
    ; points at the byte (nothing between the offset computation and
    ; here touches H or L), and delaying the "pop hl" to right after
    ; keeps the push/pop pairing correctly LIFO-ordered (push hl,
    ; push bc .. pop bc, pop hl) despite moving both later.
    ld   a, (hl)
    and  c
    pop  bc
    pop  hl
    or   a
    jr   z, .not_all_set                  ; this bit isn't set — bail
                                         ; out early, not all set
    inc  c
    dec  b
    jp    .check_loop
.all_set:
    pop  hl
    pop  de
    pop  bc
    scf
    ret
.not_all_set:
    pop  hl
    pop  de
    pop  bc
    or   a
    ret

.count_lost_blocks:
    ; Counts unset bits within 1..STORAGE_BLOCK_COUNT, stores the
    ; result in STORAGE_BLOCKS_LOST.
    push bc
    push de
    push hl
    ld   a, (STORAGE_BLOCK_COUNT)
    ld   b, a
    ld   c, 0                             ; C = current bit index
    ld   d, 0                             ; D = lost count so far
.clb_loop:
    ld   a, b
    or   a
    jp    z, .clb_done
    ld   a, c
    and  %00000111
    ld   e, a
    push bc
    ld   a, c
    rrca
    rrca
    rrca
    and  %00011111
    ld   b, 0
    ld   c, a
    ld   hl, STORAGE_BLOCK_BITMAP
    add  hl, bc                           ; HL = this bit's byte
                                         ; address — deliberately NOT
                                         ; read yet (see .clb_test)
    pop  bc
    push bc
    ld   b, e
    ld   c, 1
.clb_shift:
    ld   a, b
    or   a
    jr   z, .clb_test
    dec  b
    sla  c
    jr   .clb_shift
.clb_test:
    ; Same real bug, same fix as .rlp_test in .report_load_progress —
    ; see that routine's own comment for the full story. This third
    ; occurrence hadn't shown symptoms yet (STAGE never reached the
    ; point where this runs, until the other two were fixed), but
    ; would have made every block look "lost" even after a genuinely
    ; complete load, the moment execution did reach it.
    ld   a, (hl)
    and  c
    pop  bc
    or   a
    jr   nz, .clb_next                    ; bit set — not lost
    inc  d
.clb_next:
    inc  c
    dec  b
    jp    .clb_loop
.clb_done:
    ld   a, d
    ld   (STORAGE_BLOCKS_LOST), a
    pop  hl
    pop  de
    pop  bc
    ret

.report_load_progress:
    ; percentage = (blocks received so far) * 100 / N — counts bits
    ; set in the bitmap up to N, reusing the same counting shape as
    ; .count_lost_blocks but inverted (counts SET bits, not unset)
    push bc
    push de
    push hl
    ld   a, (STORAGE_BLOCK_COUNT)
    ld   b, a
    ld   c, 0
    ld   d, 0                             ; D = received count so far
.rlp_loop:
    ld   a, b
    or   a
    jp    z, .rlp_done
    ld   a, c
    and  %00000111
    ld   e, a
    push bc
    ld   a, c
    rrca
    rrca
    rrca
    and  %00011111
    ld   b, 0
    ld   c, a
    ld   hl, STORAGE_BLOCK_BITMAP
    add  hl, bc                           ; HL = this bit's byte
                                         ; address — deliberately NOT
                                         ; read yet (see below)
    pop  bc
    push bc
    ld   b, e
    ld   c, 1
.rlp_shift:
    ld   a, b
    or   a
    jr   z, .rlp_test
    dec  b
    sla  c
    jr   .rlp_shift
.rlp_test:
    ; REAL BUG FOUND AND FIXED: this used to read the bitmap byte
    ; into A *before* .rlp_shift, but .rlp_shift's own "ld a,b" (its
    ; loop-counter check) overwrites A with the counter's value —
    ; almost always 0 by the time the loop exits — destroying the
    ; just-read byte before this "and c" ever got to test it. That
    ; made this routine effectively unable to detect ANY set bit,
    ; for any block, ever — the root cause of every "block genuinely
    ; received but never recognized as complete" symptom throughout
    ; this whole debugging session. Found via a full instruction-by-
    ; instruction Z80 simulator (built specifically because earlier,
    ; hand-translated Python simulations of this exact routine had
    ; unknowingly "fixed" the bug in translation by testing the loop
    ; counter as its own variable instead of literally replaying the
    ; overwrite) rather than assumed safe from re-reading the source.
    ; Fixed by simply moving the read here — HL still correctly
    ; points at the byte (nothing between the original read point and
    ; here touches H or L), so reading it now, after the mask is
    ; already built in C, removes the collision entirely. Re-verified
    ; via Python for all 8 bit positions, both set and unset, before
    ; applying.
    ld   a, (hl)
    and  c
    pop  bc
    or   a
    jr   z, .rlp_next
    inc  d
.rlp_next:
    inc  c
    dec  b
    jp    .rlp_loop
.rlp_done:
    ld   l, d
    ld   h, 0                             ; HL = received count
    ld   de, 100
    call STORAGE_MATH_MULTIPLY16
    push hl
    ld   a, (STORAGE_BLOCK_COUNT)
    ld   e, a
    ld   d, 0                             ; DE = N (divisor)
    pop  hl
    call STORAGE_MATH_DIVIDE16
    ld   a, l
    ld   (STORAGE_PROGRESS_PCT), a
    call STORAGE_REPORT_PROGRESS
    pop  hl
    pop  de
    pop  bc
    ret

    ENDIF
