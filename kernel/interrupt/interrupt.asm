; ============================================================================
; kernel/interrupt/interrupt.asm — real-time keyboard scan/debounce/repeat
;
; CURRENT STATUS: assembled into the working ROM and exercised under
; Fuse through normal editor/keyboard operation and the automated suite.
; Timing constants still need confirmation on physical TS2068 hardware;
; that limitation is documented below rather than conflated with build
; or emulator status.
;
; WHY THIS EXISTS: kernel/io's old IO_READ_KEY did its own scanning,
; entirely inside a blocking busy-wait, called once per EDITOR_LOOP
; iteration. Two confirmed bugs came from that: (1) kernel/interrupt/
; was empty and nothing scanned the matrix in the background, so any
; key pressed+released while EDITOR_REDRAW_SCREEN's hook (basic/'s
; full-program wrap-aware redraw) ran was never sampled at all — lost,
; not delayed; (2) IO_READ_KEY's wait-for-release loop checked "is
; ANYTHING on the matrix down" rather than the specific key it had
; just decoded, so ordinary two-key rollover during fast typing
; silently dropped the second key while waiting for the whole matrix
; to go idle. Both traced directly from the real kernel/io/io.asm and
; kernel/editor/editor.asm in the delivered tarball, not guessed.
;
; A THIRD bug in this file's own first draft, found via real testing
; (not z80sim — z80sim's per-instruction checks all passed, this only
; showed up as a real usability problem): KBD_ISR_TICK used to re-run
; IO_FIND_KEY ("is there exactly one key down anywhere") every tick,
; even for an already-tracked key. Ordinary two-key rollover — the
; next key going down slightly before the current one lifts, which is
; just how fast typing works — made IO_FIND_KEY report "ambiguous",
; which wiped the in-progress debounce for whatever was actually being
; typed. Reported as two symptoms that turned out to be one cause:
; needing to hold keys noticeably longer (rollover kept resetting the
; debounce clock before it could complete) and occasional dropped
; keystrokes (a key released before its debounce ever survived one
; clean uninterrupted run). Fixed by adding IO_KEY_STILL_DOWN
; (kernel/io/io.asm) — KBD_ISR_TICK now checks only the ONE key it's
; already tracking once tracking has started, ignoring anything else
; simultaneously down, and only falls back to the general "find a new
; key" search when nothing is currently tracked. See KBD_ISR_TICK's
; own header for the exact state machine.
;
; DESIGN: a real IM1 handler (RST_38), run every 50/60Hz timer tick
; regardless of what the foreground is doing — modeled on the stock
; TS2068 HOME ROM's KEYBOARD/UPD_K (see docs/hardware_notes.md's
; keyboard research), simplified to a single tracked key rather than
; stock's two-slot KSTATE buffer. This does NOT mean rollover is
; unhandled — see the paragraph above — only that two keys can't BOTH
; be mid-debounce/latching at once; the currently-typed key's own
; progress is fully protected from a second key going down alongside
; it, which is what real typing actually needs.
;
; Each tick: scan the matrix (IO_KEY_SCAN_ALL), then either confirm
; the already-tracked key is still down (IO_KEY_STILL_DOWN) or look
; for a new one (IO_FIND_KEY), then run a small debounce/repeat state
; machine against KBD_CUR_ROW/KBD_CUR_BIT/KBD_DEBOUNCE/KBD_REPEAT (see
; sysvars.inc): a newly-seen key must hold for KBD_DEBOUNCE_TICKS
; consecutive ticks before being decoded (via IO_DECODE_KEY) and
; latched into KBD_LASTK/KBD_KEYHIT; once latched, holding it further
; auto-repeats after KBD_REPDEL ticks, then every KBD_REPPER ticks
; after that — same two-stage timing stock uses (REPDEL/REPPER),
; values chosen to match stock's own defaults (roughly 583ms initial
; delay, ~83ms/12-per-second repeat rate at 60Hz — see the constants
; below for the exact tick counts and the assumption they're built
; on).
;
; TIMER RATE ASSUMPTION: KBD_DEBOUNCE_TICKS/KBD_REPDEL/KBD_REPPER below
; are tuned assuming this ISR runs at 50 or 60Hz (the TS2068's real
; vertical-interrupt rate, same as stock). This hasn't been confirmed
; against how COLD_START actually configures the interrupt source on
; real TS2068 hardware (the ULA's own frame interrupt vs. some other
; timer) — flagging as an open item rather than assuming, per this
; project's own "verify hardware facts, never guess" lesson. If the
; real tick rate turns out to differ, only these three constants need
; retuning, not the state machine itself.
;
; Owns: KBD_ISR_INIT (called once from COLD_START before EI), KBD_
; ISR_TICK (called from RST_38 on every interrupt). Depends on kernel/
; io's IO_KEY_SCAN_ALL/IO_FIND_KEY/IO_DECODE_KEY and the KBD_* sysvars
; in sysvars.inc.
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"
    INCLUDE "include/keys.inc"

KBD_DEBOUNCE_TICKS   EQU 2    ; ticks a newly-seen key must hold before
                              ; being accepted as genuinely pressed.
                              ; REDUCED from 5 after real-hardware
                              ; feedback 2026-08-18: [stated] reported
                              ; general lag and quick taps (space bar,
                              ; hit briefly with a thumb rather than
                              ; rested on) sometimes not registering at
                              ; all. Stock's 5-tick value (~83ms @
                              ; 60Hz) was copied without re-deriving
                              ; whether THIS design still needs it that
                              ; long — and it largely doesn't: stock's
                              ; own disassembly notes that duration was
                              ; mostly about giving a human time to
                              ; settle between holding a shift key and
                              ; reaching a second key for combo
                              ; detection (see kernel/io's old IO_READ_
                              ; KEY, now removed, which needed up to a
                              ; ~1 second retry budget for exactly
                              ; that), not pure electrical contact-
                              ; bounce filtering — a membrane matrix's
                              ; real bounce settles in a few ms, well
                              ; under even 1 tick at 50/60Hz. This
                              ; design decodes shift state fresh at
                              ; acceptance time (IO_DECODE_KEY reads
                              ; IO_SCAN_TABLE directly), so it never
                              ; needed that settle window in the first
                              ; place. Repeat timing (KBD_REPDEL/
                              ; KBD_REPPER below, same tick-rate
                              ; assumption) tested correctly on real
                              ; hardware, which is why this is narrowed
                              ; to just the debounce constant rather
                              ; than the tick-rate assumption itself.
                              ; 2 is a first cut, not a proven final
                              ; value — retune further if real testing
                              ; still shows lag, or if a shorter value
                              ; ever lets through spurious double-
                              ; registers from genuine contact bounce.
KBD_REPDEL           EQU 35   ; ticks held before auto-repeat starts —
                              ; matches stock REPDEL's default ($23),
                              ; confirmed feeling correct on real
                              ; hardware 2026-08-18
KBD_REPPER           EQU 5    ; ticks between repeats after that —
                              ; matches stock REPPER's default ($05),
                              ; confirmed feeling correct on real
                              ; hardware 2026-08-18

; ============================================================================
; KBD_ISR_INIT
; One-time setup, called from COLD_START before the real EI that turns
; interrupts on. Clears all ISR-owned state to a known "nothing
; pressed, nothing latched" starting point — real hardware RAM can't be
; trusted to start zeroed (see this project's own lesson 13 on
; defensive state init), and KBD_CUR_ROW=$FF specifically means "no key
; currently tracked", not zero.
; In:  none
; Out: none
; Destroys: AF
; ============================================================================
KBD_ISR_INIT:
    xor  a
    ld   (KBD_LASTK), a
    ld   (KBD_KEYHIT), a
    ld   (KBD_CUR_BIT), a
    ld   (KBD_DEBOUNCE), a
    ld   (KBD_REPEAT), a
    ld   a, $FF
    ld   (KBD_CUR_ROW), a           ; $FF = no key currently tracked
    ret

; ============================================================================
; KBD_ISR_TICK
; Called from RST_38 on every maskable interrupt. Preserves every
; register it uses (AF/BC/DE/HL) — this can interrupt literally
; anything in the foreground, including mid-instruction-sequence state
; kernel/memory or basic/'s own routines are relying on staying intact
; across a `call` boundary — so nothing here may be left dirty.
;
; State machine per tick:
;   - Nothing currently tracked (KBD_CUR_ROW == $FF) -> look for a new
;     single key via IO_FIND_KEY. Found -> start tracking it fresh
;     (KBD_DEBOUNCE counts down from KBD_DEBOUNCE_TICKS). Not found
;     (idle, or two+ brand-new keys appearing in the exact same tick —
;     rare) -> nothing to do this tick.
;   - Something IS currently tracked -> check ONLY that specific key
;     via IO_KEY_STILL_DOWN, ignoring anything else on the matrix (see
;     that routine's own header for why this replaced re-running
;     IO_FIND_KEY every tick: ordinary two-key rollover during fast
;     typing was being misread as "ambiguous", wiping the in-progress
;     debounce for whatever was actually being typed). Still down ->
;     continue debounce/repeat exactly as before. Released -> clear
;     tracking, then immediately look for a new key this SAME tick
;     (IO_FIND_KEY) rather than waiting for the next one, so a fast
;     successive keystroke isn't delayed an extra tick.
;
; KBD_KEYHIT is deliberately NOT checked/waited-on here before
; latching a new value — if the foreground hasn't consumed the
; previous KBD_LASTK yet when a new one is ready, the previous one is
; simply overwritten. This matches stock's own single-slot LASTK
; behavior (no queue) and is an accepted, documented simplification:
; the foreground (IO_READ_KEY) is expected to consume promptly, and
; typical redraw-then-poll timing is far shorter than one debounce/
; repeat interval.
; In:  none
; Out: none
; Destroys: none (all registers preserved)
; ============================================================================
KBD_ISR_TICK:
    push af
    push bc
    push de
    push hl

    ld   hl, (FRAMES)                  ; unconditional, first thing —
    inc  hl                            ; every real interrupt counts
    ld   (FRAMES), hl                  ; once, before any of this
                                      ; routine's own early-exit paths

    call IO_KEY_SCAN_ALL

    ld   a, (KBD_CUR_ROW)
    cp   $FF
    jr   z, .look_for_new           ; nothing currently tracked

    ; something is tracked -- check ONLY that key, regardless of
    ; anything else currently down on the matrix
    ld   b, a
    ld   a, (KBD_CUR_BIT)
    ld   c, a
    call IO_KEY_STILL_DOWN
    jr   c, .still_down

    ; released -- stop tracking, then fall through to look for a
    ; replacement key this same tick (no extra latency)
    ld   a, $FF
    ld   (KBD_CUR_ROW), a

.look_for_new:
    call IO_FIND_KEY
    jr   nc, .done                  ; nothing new (or ambiguous) found
    jr   .new_key                   ; B = row, C = bit

.still_down:
    ; B = row, C = bit already loaded above (the tracked key)
    ld   a, (KBD_DEBOUNCE)
    or   a
    jr   z, .already_accepted

    dec  a
    ld   (KBD_DEBOUNCE), a
    jr   nz, .done                    ; not time to accept yet

    ; debounce just reached 0 -- accept and latch, start repeat timer
    call IO_DECODE_KEY
    ld   (KBD_LASTK), a
    ld   a, $FF
    ld   (KBD_KEYHIT), a
    ld   a, KBD_REPDEL
    ld   (KBD_REPEAT), a
    jr   .done

.already_accepted:
    ld   a, (KBD_REPEAT)
    dec  a
    ld   (KBD_REPEAT), a
    jr   nz, .done

    ; repeat fires
    call IO_DECODE_KEY
    ld   (KBD_LASTK), a
    ld   a, $FF
    ld   (KBD_KEYHIT), a
    ld   a, KBD_REPPER
    ld   (KBD_REPEAT), a
    jr   .done

.new_key:
    ld   a, b
    ld   (KBD_CUR_ROW), a
    ld   a, c
    ld   (KBD_CUR_BIT), a
    ld   a, KBD_DEBOUNCE_TICKS - 1     ; -1: this tick IS the first
                                      ; sighting, so only
                                      ; KBD_DEBOUNCE_TICKS-1 FURTHER
                                      ; ticks should be needed to
                                      ; reach KBD_DEBOUNCE_TICKS total
                                      ; — without the -1, a z80sim
                                      ; test caught this taking 6
                                      ; ticks to accept instead of 5
                                      ; (this tick sets the counter,
                                      ; then N more decrements were
                                      ; needed before it ever hit 0)
    ld   (KBD_DEBOUNCE), a
    ; KBD_REPEAT is only meaningful once KBD_DEBOUNCE reaches 0 (see
    ; .already_accepted above, reached only via that path first
    ; setting it to KBD_REPDEL) -- no need to touch it here

.done:
    pop  hl
    pop  de
    pop  bc
    pop  af
    ret

; ============================================================================
; INT_GET_FRAMES
; Reads the current FRAMES tick count — the only way basic/ (or any
; other code outside kernel/) is allowed to see it, per this project's
; own "nothing outside kernel/ touches a system-variable address
; directly" rule (include/kernel_api.inc's own header). Backs BASIC's
; PAUSE <n>, which waits for FRAMES to advance by n.
; In:  none
; Out: HL = FRAMES
; Destroys: HL
; ============================================================================
INT_GET_FRAMES:
    ld   hl, (FRAMES)
    ret
