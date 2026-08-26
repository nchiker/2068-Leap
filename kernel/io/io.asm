; ============================================================================
; kernel/io/io.asm — keyboard scanning
;
; CURRENT STATUS: assembled into the working ROM and exercised under
; Fuse, including interactive keyboard use and automated language I/O
; coverage. The matrix-scan mechanism itself (IO_KEY_SCAN_ROW,
; IO_KEY_SCAN_ALL) is standard, well-established Spectrum-family hardware
; behaviour and I'm confident in it electrically — the ULA's 8x5 keyboard
; matrix, read via port $FE with the row selected by the value in A at
; the time of the IN instruction, is unchanged across the whole Spectrum/
; Timex family, TS2068 included (Fuse itself emulates TS2068 keyboard
; input through the same mechanism).
;
; CORRECTED: an earlier draft of this file claimed the TS2068 has
; dedicated cursor keys, unlike a stock Spectrum's SHIFT+5/6/7/8 scheme.
; That was wrong — the TS2068 keyboard is laid out the same as the
; original Spectrum (CAPS SHIFT duplicated on both sides, plus an added
; BREAK key, otherwise identical). See docs/hardware_notes.md. This
; means the standard CAPS SHIFT+5/6/7/8/0 cursor combo scheme applies
; here directly and IS implemented below — not blocked the way the
; wrong "dedicated cursor keys" assumption made it seem.
;
; BREAK (2026-08-19): CAPS SHIFT+SPACE, the standard confirmed
; Spectrum-family combo, IS now implemented below (IO_DECODE_KEY,
; KEY_BREAK). Still genuinely unconfirmed: whether the TS2068's added
; physical BREAK keycap is a distinct matrix position rather than this
; same combo under a different keycap — see docs/hardware_notes.md's
; "Still open" list and keys.inc's KEY_BREAK comment. A genuinely
; separate matrix position, if one exists, is not implemented.
;
; Owns: raw keyboard matrix scanning (IO_KEY_SCAN_ROW/ALL, IO_ANY_KEY_
; DOWN, IO_FIND_KEY), decode into ASCII/combo codes (IO_DECODE_KEY, and
; the tables it uses — KEY_ASCII_TABLE/_UPPER/_SYMBOL), CAPS SHIFT+
; digit cursor/delete/delete-line/insert-line combo detection, CAPS
; SHIFT+letter for uppercase, and the confirmed-confidence subset of
; SYMBOL SHIFT's punctuation table. Unshifted letters are lowercase by
; design (see KEY_ASCII_TABLE's own comment — a deliberate choice for
; this redesigned ROM, not a recalled hardware fact, since a real
; Sinclair-family keyboard has no separate case keys at all).
;
; SCANNING/TIMING OWNERSHIP CHANGED (2026-08-17): IO_READ_KEY used to
; do its own blocking scan-settle-decode-wait-for-release cycle
; internally — this was the confirmed root cause of two real bugs:
; (1) no scanning happened at all while the foreground was busy (e.g.
; basic/'s per-keystroke full-program redraw), silently dropping any
; key pressed+released during that window; (2) waiting for release via
; "is ANYTHING on the matrix down" rather than the specific decoded
; key meant ordinary two-key rollover during fast typing dropped the
; second key. Real scanning/debounce/decode now happens every timer
; tick in kernel/interrupt/interrupt.asm's KBD_ISR_TICK, independent
; of the foreground — see that file's own header for the full design.
; This file still owns the matrix-scan primitive and the decode
; tables/logic (IO_FIND_KEY/IO_DECODE_KEY), which KBD_ISR_TICK calls
; into every tick; IO_READ_KEY itself is now just a thin consumer of
; the ISR's latched KBD_LASTK/KBD_KEYHIT state. Physical TS2068 hardware
; verification remains separate from the confirmed Fuse behavior.
;
; CAPS SHIFT+ENTER (KEY_INSERT_LINE, see keys.inc) is a project-specific
; combo. Unlike the digit-row combos above (which DO have documented
; real-hardware meanings this project deliberately doesn't implement —
; EDIT, GRAPHICS, etc.), this specific combination hasn't been
; independently verified against real hardware docs either way; not
; claiming it's confirmed unused, just that this project isn't trying
; to replicate original hardware behavior for it regardless. Reports
; the key; what "insert a line" actually means is entirely basic/'s
; concern, forwarded through the same EDITOR_NAV_HOOK mechanism already
; used for UP/DOWN.
;
; SYMBOL SHIFT's real table is genuinely more complex than a flat
; symbol lookup, and only the independently-verified parts are
; implemented: the digit row (! @ # $ % & ' ( ) _), eleven letter-row
; keys (Z=: M=. N=, L== K=+ J=- O=; V=/ B=* R=< T=>), confirmed via a
; slady.net Spectrum keyboard layout chart cross-checked against every
; letter-row mapping already independently verified in this project
; (matched exactly, giving confidence in the source for the newly-added
; R/T entries too). V and B were added once basic/'s expression
; evaluator actually needed / and *; R and T were added once basic/'s
; new IF/ELSEIF relational operators needed < and >. NOT implemented,
; deliberately rather than guessed: row 1 (A-G) gives BASIC keyword
; tokens on real hardware (STOP, NOT, STEP, TO, THEN), not simple
; characters, so it isn't representable this way at all; three of row
; 2's remaining keys (Q='<=' W='<>' E='>=') give compound TWO-
; CHARACTER tokens on real hardware, which this project's flat one-
; key-to-one-byte table has no way to represent (this BASIC's own
; parser reads <= <> >= as two typed characters in sequence anyway, so
; nothing is lost by leaving these three unmapped rather than adding
; multi-byte output support just for them); a handful of individual
; letter keys (X, I, U, Y, H) have no confirmed mapping either
; way (C='?' now confirmed and mapped). This got corrected once already — an earlier draft here narrowly
; implemented only SYMBOL SHIFT+P (quote), enough to unblock
; PRINT "..." but nothing else; generalized to the fuller table once
; more of it was actually needed.
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"
    INCLUDE "include/keys.inc"

; ---- keyboard matrix layout (standard Spectrum-family 8x5 matrix) ----
; Each row is selected by loading its value into A before IN A,($FE); the
; Z80's IN A,(n) instruction puts the CURRENT A on the high 8 address
; lines and n on the low 8, so A must hold the row-select byte going
; into the instruction, not coming out of it.
;
; Bits returned in A after the read (bits 0-4; active LOW = pressed;
; bits 5-7 unused/undefined):
;   Row $FE: bit0=CAPS SHIFT bit1=Z bit2=X bit3=C bit4=V
;   Row $FD: bit0=A bit1=S bit2=D bit3=F bit4=G
;   Row $FB: bit0=Q bit1=W bit2=E bit3=R bit4=T
;   Row $F7: bit0=1 bit1=2 bit2=3 bit3=4 bit4=5
;   Row $EF: bit0=0 bit1=9 bit2=8 bit3=7 bit4=6
;   Row $DF: bit0=P bit1=O bit2=I bit3=U bit4=Y
;   Row $BF: bit0=ENTER bit1=L bit2=K bit3=J bit4=H
;   Row $7F: bit0=SPACE bit1=SYMBOL SHIFT bit2=M bit3=N bit4=B
KEY_ROW_COUNT   EQU 8

; ============================================================================
; IO_KEY_SCAN_ROW
; Scans one keyboard row.
; In:  A = row-select byte (one of the $FE/$FD/.../$7F values above)
; Out: A = bits 0-4 = key state for that row (0 = pressed), bits 5-7
;      undefined
; Destroys: AF
; ============================================================================
IO_KEY_SCAN_ROW:
    in   a, (PORT_ULA)
    ret

; ============================================================================
; IO_KEY_SCAN_ALL
; Scans all 8 rows into IO_SCAN_TABLE (one byte per row, same row order as
; ROW_TABLE below — index 0 = $FE, index 7 = $7F).
; In:  none
; Out: IO_SCAN_TABLE filled; HL = IO_SCAN_TABLE (start of the table)
; Destroys: AF, BC, HL
; ============================================================================
IO_KEY_SCAN_ALL:
    ld   hl, IO_SCAN_TABLE
    ld   b, KEY_ROW_COUNT
    ld   c, 0                    ; C = index into ROW_TABLE
.scan_loop:
    push bc
    push hl
    ld   hl, ROW_TABLE
    ld   b, 0
    add  hl, bc                   ; HL -> ROW_TABLE[C]
    ld   a, (hl)                  ; A = this row's select byte
    pop  hl
    call IO_KEY_SCAN_ROW
    ld   (hl), a
    inc  hl
    pop  bc
    inc  c
    djnz .scan_loop
    ld   hl, IO_SCAN_TABLE
    ret

; ============================================================================
; IO_ANY_KEY_DOWN
; Checks whether any key anywhere on the keyboard is currently pressed.
; Convenience wrapper around IO_KEY_SCAN_ALL for simple polling (e.g. the
; interactive test in rom/test_io.asm).
; In:  none
; Out: carry set if at least one key is down, carry clear if none are
; Destroys: AF, BC, HL
; ============================================================================
IO_ANY_KEY_DOWN:
    call IO_KEY_SCAN_ALL          ; HL = IO_SCAN_TABLE
    ld   b, KEY_ROW_COUNT
.check_loop:
    ld   a, (hl)
    and  $1F                       ; only bits 0-4 are meaningful
    cp   $1F                        ; all 5 bits set = nothing pressed
                                   ; in this row
    jr   nz, .found
    inc  hl
    djnz .check_loop
    or   a                          ; clear carry: nothing found
    ret
.found:
    scf
    ret

; ============================================================================
; IO_FIND_KEY
; Scans an already-filled IO_SCAN_TABLE (caller must call IO_KEY_SCAN_
; ALL first — this does no scanning of its own, unlike the old
; IO_READ_KEY) for the single non-modifier key currently down. Row 0
; bit 0 (CAPS SHIFT) and row 7 bit 1 (SYMBOL SHIFT) are never reported
; as "the key" here — they're modifiers, read separately by
; IO_DECODE_KEY straight from IO_SCAN_TABLE.
;
; Deliberately single-slot: if two or more non-modifier keys are down
; at once (genuine simultaneous rollover, not just fast sequential
; typing), this returns "none found" rather than picking one, and the
; caller (KBD_ISR_TICK) clears whatever tracking it had and starts
; fresh next tick — same as a real release. This is a scope decision,
; not an oversight: it fixes both confirmed bugs (background scanning
; never stopping, and release now tracked per-key instead of via "is
; anything on the whole matrix down") without needing stock ROM's full
; two-slot KSTATE buffer, which a single-user text editor doesn't
; need. The tradeoff is that a single stray ambiguous/idle scan mid-
; debounce restarts that key's debounce from scratch rather than
; tolerating a one-tick blip — acceptable since debounce is only 5
; ticks (~83ms) to begin with. Worth revisiting only if either turns
; out to matter in practice.
;
; In:  IO_SCAN_TABLE already filled (via IO_KEY_SCAN_ALL)
; Out: carry set + B = row (0-7), C = bit (0-4) if exactly one
;      non-modifier key is down; carry clear (B/C undefined) if zero
;      or 2+ are down
; Destroys: AF, BC, DE, HL
; ============================================================================
IO_FIND_KEY:
    ld   hl, IO_SCAN_TABLE
    ld   d, 0                       ; D = row index (0-7)
    ld   e, $FF                     ; E = $FF until a key is recorded,
                                    ; then holds that key's row*5+bit —
                                    ; a second recording attempt with
                                    ; E already set means ambiguity
.row_loop:
    ld   a, (hl)
    and  $1F
    cp   $1F
    jr   z, .next_row                ; nothing down anywhere in this row
    ld   b, (hl)                     ; B = row byte, shifted bit-by-bit
                                    ; below as this row is walked
    ld   c, 0                       ; C = bit index within row (0-4)
.bit_loop:
    bit  0, b
    jr   nz, .bit_next                ; bit set = not pressed
    ; key pressed at (D,C) — exclude the two modifier positions
    ld   a, d
    or   a
    jr   nz, .chk_row7
    ld   a, c
    or   a
    jr   z, .bit_next                  ; row0 bit0 = CAPS SHIFT, skip
    jr   .chk_record
.chk_row7:
    cp   7
    jr   nz, .chk_record
    ld   a, c
    cp   1
    jr   z, .bit_next                  ; row7 bit1 = SYMBOL SHIFT, skip
.chk_record:
    ld   a, e
    cp   $FF
    jr   nz, .ambiguous                 ; already have one -> 2nd key
                                       ; seen this scan -> bail
    ld   a, d
    add  a, a
    add  a, a
    add  a, d                          ; A = row*5
    add  a, c                           ; A = row*5 + bit
    ld   e, a
.bit_next:
    srl  b
    inc  c
    ld   a, c
    cp   5
    jr   nz, .bit_loop
.next_row:
    inc  hl
    inc  d
    ld   a, d
    cp   8
    jr   nz, .row_loop
    ld   a, e
    cp   $FF
    jr   z, .none
    ld   a, e
    ld   b, 0
.divloop:
    cp   5
    jr   c, .divdone
    sub  5
    inc  b
    jr   .divloop
.divdone:
    ld   c, a
    scf
    ret
.none:
    or   a
    ret
.ambiguous:
    or   a
    ret

; ============================================================================
; IO_KEY_STILL_DOWN
; Checks whether ONE specific (row,bit) key is still held, ignoring
; every other key on the matrix entirely — unlike IO_FIND_KEY, which
; answers "is there exactly one key down anywhere". Added 2026-08-18
; after real testing: KBD_ISR_TICK used to re-run IO_FIND_KEY every
; tick even for an already-tracked key, so an entirely ordinary second
; key going down slightly before the first one lifts (routine two-key
; rollover during fast typing, not a rare edge case) made IO_FIND_KEY
; report "ambiguous", which cleared the in-progress debounce for
; whatever was actually being typed — explaining both a reported
; symptom of needing to hold keys longer (rollover kept resetting the
; debounce clock) and dropped keystrokes (a key released before its
; debounce ever survived one clean uninterrupted run). This routine
; lets KBD_ISR_TICK check only the ONE key it's already tracking,
; independent of anything else simultaneously down.
; In:  B = row (0-7), C = bit (0-4), IO_SCAN_TABLE already filled
; Out: carry set if that key is still down, carry clear if released.
;      B and C are UNCHANGED — callers (KBD_ISR_TICK) need them intact
;      afterward to call IO_DECODE_KEY with the same row/bit
; Destroys: AF, DE, HL
; ============================================================================
IO_KEY_STILL_DOWN:
    ld   hl, IO_SCAN_TABLE
    ld   a, b
    add  a, l
    ld   l, a
    jr   nc, .no_carry
    inc  h
.no_carry:
    ld   d, (hl)               ; D = row byte, shifted in place below
    ld   e, c                   ; E = bit index (0-4) = rotation count
                                ; -- deliberately E, not B: B holds the
                                ; row and must survive this call intact
                                ; for the caller's later IO_DECODE_KEY
                                ; call (an earlier draft used B here,
                                ; clobbering it — caught by the full
                                ; KBD_ISR_TICK integration z80sim test,
                                ; not the isolated per-routine test,
                                ; which only checked the carry flag and
                                ; never noticed B was wrong afterward)
.shift_loop:
    ld   a, e
    or   a
    jr   z, .test
    srl  d
    dec  e
    jr   .shift_loop
.test:
    bit  0, d
    jr   nz, .not_down
    scf
    ret
.not_down:
    or   a
    ret

; ============================================================================
; IO_DECODE_KEY
; Translates a (row, bit) position — as found by IO_FIND_KEY — into a
; code, using CAPS SHIFT/SYMBOL SHIFT state read straight from
; IO_SCAN_TABLE (which the caller must have already filled via
; IO_KEY_SCAN_ALL). Same combo priority the old IO_READ_KEY had, minus
; the settle/retry loop: running from an interrupt tick that never
; stops means KBD_ISR_TICK's own debounce already absorbs the timing
; slop that loop used to paper over, so a straight priority check here
; is enough.
; In:  B = row (0-7), C = bit (0-4)
; Out: A = translated code, or 0 if this position/shift combo isn't
;      mapped to anything (mirrors the old IO_READ_KEY's contract)
; Destroys: AF, DE, HL
; ============================================================================
IO_DECODE_KEY:
    ld   a, (IO_SCAN_TABLE)          ; row 0: bit0 = CAPS SHIFT
    bit  0, a
    jr   nz, .check_symshift          ; CAPS SHIFT not held

    ; --- CAPS SHIFT + cursor-digit combos, checked by (row,bit)
    ; directly rather than re-scanning IO_SCAN_TABLE — IO_FIND_KEY
    ; already identified this as the one active non-modifier key ---
    ld   a, b
    cp   3
    jr   nz, .not_row3_caps
    ld   a, c
    or   a
    jr   nz, .not_delline
    ld   a, KEY_DELETE_LINE           ; row3 bit0 = '1'
    ret
.not_delline:
    cp   4
    jr   nz, .not_row3_caps
    ld   a, KEY_CURSOR_LEFT            ; row3 bit4 = '5'
    ret
.not_row3_caps:
    ld   a, b
    cp   6
    jr   nz, .not_row6_caps
    ld   a, c
    or   a
    jr   nz, .not_row6_caps
    ld   a, KEY_INSERT_LINE            ; row6 bit0 = ENTER
    ret
.not_row6_caps:
    ld   a, b
    cp   4
    jr   nz, .not_row4_caps
    ld   a, c
    or   a
    jr   nz, .not_delete
    ld   a, KEY_DELETE                 ; row4 bit0 = '0'
    ret
.not_delete:
    cp   2
    jr   nz, .not_right
    ld   a, KEY_CURSOR_RIGHT             ; row4 bit2 = '8'
    ret
.not_right:
    cp   3
    jr   nz, .not_up
    ld   a, KEY_CURSOR_UP                 ; row4 bit3 = '7'
    ret
.not_up:
    cp   4
    jr   nz, .not_row4_caps
    ld   a, KEY_CURSOR_DOWN                ; row4 bit4 = '6'
    ret
.not_row4_caps:
    ; CAPS SHIFT + SPACE -> BREAK (row7 bit0), the standard confirmed
    ; Spectrum-family combo — checked here, same style as the row3/
    ; row4/row6 combos above, before falling through to the uppercase
    ; table (row 7's SPACE slot is unmapped there anyway, see
    ; KEY_ASCII_TABLE's own row-7 comment, so this doesn't shadow
    ; anything real)
    ld   a, b
    cp   7
    jr   nz, .not_row7_caps
    ld   a, c
    or   a
    jr   nz, .not_row7_caps
    ld   a, KEY_BREAK                  ; row7 bit0 = SPACE
    ret
.not_row7_caps:
    ; CAPS SHIFT + anything else -> uppercase letter table
    ld   a, b
    add  a, a
    add  a, a
    add  a, b                        ; A = row*5
    add  a, c                         ; A = row*5 + bit
    ld   e, a
    ld   d, 0
    ld   hl, KEY_ASCII_TABLE_UPPER
    add  hl, de
    ld   a, (hl)
    ret

.check_symshift:
    ld   a, (IO_SCAN_TABLE+7)        ; row 7: bit1 = SYMBOL SHIFT
    bit  1, a
    jr   nz, .no_shift                ; neither shift held

    ; --- SYMBOL SHIFT + A/S combo (basic/'s error nav), checked
    ; before the generic table lookup — row1 is otherwise entirely
    ; unmapped there anyway (see kernel/io's own header) ---
    ld   a, b
    cp   1
    jr   nz, .sym_table_lookup
    ld   a, c
    or   a
    jr   nz, .chk_prev_error
    ld   a, KEY_NEXT_ERROR            ; row1 bit0 = 'A'
    ret
.chk_prev_error:
    cp   1
    jr   nz, .sym_table_lookup
    ld   a, KEY_PREV_ERROR            ; row1 bit1 = 'S'
    ret

.sym_table_lookup:
    ld   a, b
    add  a, a
    add  a, a
    add  a, b
    add  a, c
    ld   e, a
    ld   d, 0
    ld   hl, KEY_ASCII_TABLE_SYMBOL
    add  hl, de
    ld   a, (hl)
    ret

.no_shift:
    ld   a, b
    add  a, a
    add  a, a
    add  a, b
    add  a, c
    ld   e, a
    ld   d, 0
    ld   hl, KEY_ASCII_TABLE
    add  hl, de
    ld   a, (hl)
    ret

; ============================================================================
; IO_READ_KEY
; Blocking read of one key. All real scanning/debounce/decode now
; happens continuously in KBD_ISR_TICK (kernel/interrupt/
; interrupt.asm), on every timer interrupt, independent of whatever
; the foreground code is doing — this fixes the two confirmed root
; causes behind the editor's lag/lost-keystroke bugs: (1) scanning
; used to happen ONLY inside this routine's own busy-wait, so nothing
; was sampled at all while EDITOR_REDRAW_SCREEN's hook (basic/'s
; full-program wrap-aware redraw) ran after every keystroke; (2) the
; old wait-for-release loop checked "is ANYTHING on the matrix down"
; rather than the specific key just decoded, so ordinary two-key
; rollover during fast typing silently dropped the second key. This
; routine is now just a thin consumer of the ISR's latched state.
; In:  none
; Out: A = translated code (same meanings as before — KEY_CURSOR_*,
;      KEY_DELETE, KEY_DELETE_LINE, KEY_INSERT_LINE, KEY_NEXT/
;      PREV_ERROR, ASCII, or 0 for an unmapped/shift-alone position)
; Destroys: AF
; ============================================================================

; ============================================================================
; IO_LATCH_AND_CLEAR
; Shared tail for IO_READ_KEY/IO_READ_KEY_NONBLOCK below: returns the
; ISR's latched key code and clears KBD_KEYHIT so the next scan starts
; fresh.
; In:  none
; Out: A = KBD_LASTK; KBD_KEYHIT cleared
; Destroys: AF
; ============================================================================
IO_LATCH_AND_CLEAR:
    ld   a, (KBD_LASTK)
    push af
    xor  a
    ld   (KBD_KEYHIT), a
    pop  af
    ret

IO_READ_KEY:
.wait_hit:
    ld   a, (KBD_KEYHIT)
    or   a
    jr   z, .wait_hit
    jr   IO_LATCH_AND_CLEAR

; ============================================================================
; IO_READ_KEY_NONBLOCK
; Non-blocking counterpart to IO_READ_KEY — same "thin consumer of the
; ISR's latched state" shape, just without the .wait_hit loop: reads
; KBD_KEYHIT exactly ONCE, returns immediately either way. Backs
; BASIC's INKEY$ (which must never block — empty result if nothing is
; currently pressed, not wait for a keypress the way IO_READ_KEY/PAUSE
; 0 deliberately do).
; In:  none
; Out: A = translated code (same meanings as IO_READ_KEY's own Out — see
;      that routine's header), or 0 if no key is currently latched.
;      KBD_KEYHIT cleared in either case that a key WAS latched (0
;      already means nothing to clear).
; Destroys: AF
; ============================================================================
IO_READ_KEY_NONBLOCK:
    ld   a, (KBD_KEYHIT)
    or   a
    ret  z                              ; nothing latched — A already 0
    jr   IO_LATCH_AND_CLEAR

; ============================================================================
; STICK_READ
; Reads a joystick's state through the AY-3-8912's I/O port A —
; confirmed from the real ROM disassembly's own STICK command routine
; (M28F8/READ-STICK): register 14 ($0E) selected via PORT_AY_REG, then
; read back via PORT_AY_DATA. Real hardware detail, not a design
; choice: only stick 1 gets a full 4-bit direction nibble; stick 2
; reports a single bit — the asymmetry is exactly what the real ROM's
; own bit-decode does (RLCA + AND $01 for stick 2 vs. AND $0F for
; stick 1), not something invented here.
; In:  HL = device (1 or 2 — caller's own job to validate; this
;      routine trusts it)
; Out: HL = stick value (device 1: 0-15, one bit per direction; device
;      2: 0 or 1)
; Destroys: AF, BC, HL
; ============================================================================
STICK_READ:
    ld   a, l
    ld   d, a                          ; D = device (1 or 2)
    ld   a, $0E
    out  (PORT_AY_REG), a               ; select AY register 14 (I/O
                                        ; port A)
    ld   c, PORT_AY_DATA
    in   a, (c)                          ; A = raw joystick lines
    cpl                                   ; active-low -> active-high
    ld   b, d                             ; B = device, DJNZ's own
                                          ; counter — decrements once;
                                          ; device 1 hits zero (falls
                                          ; through), device 2 doesn't
                                          ; (jumps to .stick2)
    djnz .stick2
    and  $0F                              ; stick 1: low nibble = the
                                          ; four direction bits
    cp   $0F
    jr   c, .done                         ; not all four bits set —
                                          ; keep the value as-is
    xor  a                                 ; all bits set (the real
                                           ; ROM's own "no real input"
                                           ; edge case) -> force 0
    jr   .done
.stick2:
    rlca                                   ; stick 2: only bit 7
                                           ; (rotated into bit 0) is
                                           ; meaningful — real hardware
                                           ; asymmetry, see this
                                           ; routine's own header
    and  $01
.done:
    ld   l, a
    ld   h, 0
    ret

; ---- row select bytes, in the order IO_SCAN_TABLE stores them ----
ROW_TABLE:
    DB   $FE, $FD, $FB, $F7, $EF, $DF, $BF, $7F

; ---- key -> ASCII translation table, 40 entries (8 rows x 5 bits) ----
; Index = row*5 + bit, using ROW_TABLE's row order above. 0 = unmapped
; (SHIFT keys, and anything not yet handled — see file header).
;
; Letters are LOWERCASE here — this is the unshifted default. Uppercase
; comes from CAPS SHIFT+letter, via KEY_ASCII_TABLE_UPPER below. This is
; a design choice, not a recalled hardware fact: a real Sinclair-family
; keyboard has no separate upper/lowercase keys at all, so some scheme
; has to be chosen. This follows the typewriter/modern-keyboard
; convention (unshifted = lowercase) rather than the machine's own
; historical BASIC-editor default (which was uppercase-first, with mode-
; switching for lowercase entry) — deliberately chosen for this
; redesigned ROM to match what most people expect from a keyboard today,
; consistent with the project's stated latitude to extend rather than
; exactly replicate. NOTE: this changed existing behaviour — unshifted
; letters used to be uppercase here.
KEY_ASCII_TABLE:
    ; row 0 ($FE): CAPS SHIFT, z, x, c, v
    DB   0, "z", "x", "c", "v"
    ; row 1 ($FD): a, s, d, f, g
    DB   "a", "s", "d", "f", "g"
    ; row 2 ($FB): q, w, e, r, t
    DB   "q", "w", "e", "r", "t"
    ; row 3 ($F7): 1, 2, 3, 4, 5
    DB   "1", "2", "3", "4", "5"
    ; row 4 ($EF): 0, 9, 8, 7, 6
    DB   "0", "9", "8", "7", "6"
    ; row 5 ($DF): p, o, i, u, y
    DB   "p", "o", "i", "u", "y"
    ; row 6 ($BF): ENTER, l, k, j, h
    DB   KEY_ENTER, "l", "k", "j", "h"
    ; row 7 ($7F): SPACE, SYMBOL SHIFT, m, n, b
    DB   " ", 0, "m", "n", "b"

; ---- CAPS SHIFT+letter translation table, same 40-entry layout as
; KEY_ASCII_TABLE above. Only letters are mapped here — digit/space/
; enter/shift positions are all 0 (unmapped): the cursor/delete combos
; already consume CAPS SHIFT+5/0/8/7/6 earlier in IO_READ_KEY, and
; nothing is implemented for CAPS SHIFT+other-digit (those had special
; meanings — EDIT, CAPS LOCK, etc. — on real Spectrum-family machines,
; not simple characters, and none of that is implemented here). ----
KEY_ASCII_TABLE_UPPER:
    ; row 0: CAPS SHIFT, Z, X, C, V
    DB   0, "Z", "X", "C", "V"
    ; row 1: A, S, D, F, G
    DB   "A", "S", "D", "F", "G"
    ; row 2: Q, W, E, R, T
    DB   "Q", "W", "E", "R", "T"
    ; row 3: 1, 2, 3, 4, 5 -> all unmapped (1 is consumed as
    ; DELETE_LINE, 5 as LEFT, both earlier)
    DB   0, 0, 0, 0, 0
    ; row 4: 0, 9, 8, 7, 6 -> all unmapped (0,8,7,6 consumed as combos)
    DB   0, 0, 0, 0, 0
    ; row 5: P, O, I, U, Y
    DB   "P", "O", "I", "U", "Y"
    ; row 6: ENTER, L, K, J, H -> this table's ENTER slot stays
    ; unmapped (it's not a letter, so it was never meant to produce
    ; one here) — CAPS SHIFT+ENTER's real meaning (INSERT_LINE) is
    ; caught earlier, before this table is ever reached, so this slot
    ; being 0 doesn't conflict with that
    DB   0, "L", "K", "J", "H"
    ; row 7: SPACE, SYMBOL SHIFT, M, N, B -> unshifted SPACE has no
    ; mapping in this table (this project doesn't produce a literal
    ; space character through the plain key path); CAPS SHIFT+SPACE
    ; is BREAK, handled separately in IO_DECODE_KEY before this table
    ; is ever reached, see KEY_BREAK
    DB   0, 0, "M", "N", "B"

; ---- SYMBOL SHIFT translation table, same 40-entry layout. Only the
; CONFIRMED-CONFIDENCE subset of the real table is here (see this
; file's header) — everything else is 0 (unmapped) rather than
; guessed. Real Spectrum-family hardware is genuinely more complex
; than a flat symbol table: row 1 (A-G) gives BASIC keyword tokens
; (STOP, NOT, STEP, TO, THEN), not simple characters, so it's not
; implementable this way at all; row 2's Q/W/E give compound two-
; character tokens (<=, <>, >=) this flat table can't represent, left
; at 0 — but R='<' and T='>' are simple single characters and ARE
; confirmed/implemented below. ----
KEY_ASCII_TABLE_SYMBOL:
    ; row 0: CAPS SHIFT, Z, X, C, V -> Z=':' confirmed; C='?' confirmed
    ; (needed for basic/ error reporting and general punctuation use —
    ; font glyph added alongside, kernel/graphics FONT_TABLE); V='/'
    ; confirmed (needed for basic/'s division operator); X not
    ; confirmed, left unmapped
    DB   0, ":", 0, "?", "/"
    ; row 1: A, S, D, F, G -> keyword tokens on real hardware, not
    ; implementable as simple characters
    DB   0, 0, 0, 0, 0
    ; row 2: Q, W, E, R, T -> R='<' and T='>' confirmed (needed for
    ; basic/'s new IF relational operators); Q/W/E give compound
    ; TOKENS on real hardware (<=, <>, >= respectively — confirmed via
    ; the same source as the rest of this table), not simple
    ; characters this flat one-key-to-one-byte table can represent, so
    ; left unmapped rather than guessed or half-implemented
    DB   0, 0, 0, "<", ">"
    ; row 3: 1, 2, 3, 4, 5
    DB   "!", "@", "#", "$", "%"
    ; row 4: 0, 9, 8, 7, 6
    DB   "_", ")", "(", "'", "&"
    ; row 5: P, O, I, U, Y -> P confirmed (needed for PRINT "..."),
    ; O confirmed; I/U/Y not confirmed
    DB   '"', ";", 0, 0, 0
    ; row 6: ENTER, L, K, J, H -> ENTER n/a; L/K/J confirmed; H not
    DB   0, "=", "+", "-", 0
    ; row 7: SPACE, SYM SHIFT, M, N, B -> SYMBOL SHIFT+SPACE itself has
    ; no confirmed meaning and stays unmapped here (BREAK is CAPS
    ; SHIFT+SPACE, a different combo — see KEY_BREAK, handled
    ; separately in IO_DECODE_KEY, not this table); M/N confirmed;
    ; B='*' confirmed (needed for basic/'s multiplication operator)
    DB   0, 0, ".", ",", "*"

; ============================================================================
; IO_CHECK_BREAK
; Non-blocking check for the BREAK combo (CAPS SHIFT+SPACE — see
; KEY_BREAK in include/keys.inc) currently being held down. Unlike
; IO_READ_KEY, this never blocks waiting for a key — meant to be
; polled once per statement from inside a running program's own
; execution loop (basic/'s BASIC_RUN) without slowing or freezing
; execution on every other keystroke. Does its own scan; the caller
; does not need to have called IO_KEY_SCAN_ALL first.
; In:  none
; Out: carry set if BREAK is currently held, carry clear otherwise
; Destroys: AF, BC, DE, HL
; ============================================================================
IO_CHECK_BREAK:
    call IO_KEY_SCAN_ALL
    call IO_FIND_KEY
    ret  nc                       ; zero, or 2+, non-modifier keys down —
                                  ; can't be an exact CAPS SHIFT+SPACE
                                  ; combo (IO_FIND_KEY's own "ambiguous
                                  ; rollover" scope decision, see its
                                  ; header — same tradeoff applies here)
    call IO_DECODE_KEY            ; B/C = the one non-modifier key found;
                                  ; checks CAPS SHIFT state itself
    cp   KEY_BREAK
    jr   z, .found
    or   a                        ; some other key/combo — clear carry
    ret
.found:
    scf
    ret
