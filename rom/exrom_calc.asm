; ============================================================================
; rom/exrom_calc.asm — calculator engine (RST $28), EXROM-resident
;
; REWORKED 2026-08-20 (was a byte-for-byte port until this pass — see
; this project's own /areas notes for the full before/after). The real
; Spectrum ROM's CALCULATE (skoolkid.github.io/rom/asm/335B.html — real,
; fetched, not estimated) leans on EXX/EX (SP),HL register-banking and a
; push-then-RET computed-dispatch trick, both there purely to save bytes
; and registers on 1982 hardware under real scarcity. Neither scarcity
; applies here the same way: [stated] design goal is smallest possible
; HOME ROM footprint once TRIG functions land — that's an argument for
; keeping ALL of this in EXROM (already true, see rom/exrom_checker.
; asm's $C024 stub), not an argument for the register trick, which
; costs RAM sysvars either way regardless of which ROM bank holds the
; code. This project already spends RAM sysvars freely elsewhere
; (CALC_STACK etc.) and already rejected the real ROM's OTHER space-
; saving trick (dynamic stack) for the same reason this rework rejects
; this one: incremental/hidden state that ~60 future op routines would
; each have to get right is a worse bet than a few bytes of RAM holding
; the truth explicitly. Concretely, this version:
;   - has NO exx, NO ex (sp),hl, NO primed registers anywhere. The
;     literal-stream position lives in CALC_LITERAL_PTR (sysvar).
;   - dispatches via LD HL,(table entry) / JP (HL), not push+ret. This
;     is NOT a novel trick for this codebase — it's the same mechanism
;     kernel/storage/storage.asm's STORAGE_PROGRESS_HOOK callback
;     already uses, so it's proven, testable, and idiomatic here.
;   - recomputes CALC_OP1_PTR/CALC_OP2_PTR fresh from CALC_SP on EVERY
;     iteration (include/sysvars.inc's own comment on those has the
;     full reasoning), rather than trusting a carried-forward pointer
;     the way the real ROM's HL/DE are maintained.
;   - RLCA -> ADD A,A and RRCA x4 -> SRL A x4: exact substitutes given
;     the branch guards already in place (A<$80 confirmed by the `jp p`
;     test before DOUBLE_A's real RLCA; the AND $60 before the real
;     RRCA x4 already zeroed the bits a rotate would otherwise wrap
;     into, so a plain shift is identical to the rotate here) — chosen
;     because this project's own z80sim (tools/z80sim/sim.py) doesn't
;     implement RLCA/RRCA/EXX/EX (SP),HL/DW, and re-deriving the same
;     arithmetic with instructions it DOES support was cheaper and more
;     legible than extending the simulator for a one-off need.
;   - CALC_OP_UNIMPLEMENTED hangs via `jr` to itself, not the Z80 HALT
;     opcode — this project's own established idiom (EXROM_VERIFY_KTAB_
;     MAGIC, rom/exrom_checker.asm) already does exactly this; using
;     HALT in the version before this rework was an inconsistency with
;     the project's own convention, caught and fixed here, independent
;     of the simulator question.
;
; WHAT'S STILL A FAITHFUL PORT: the overall literal-decode arithmetic
; (which bits mean what, the $18/$7C/$60/$1F magic numbers, the binary-
; vs-unary/manipulatory split) is unchanged from the real ROM — only
; the REGISTER CHOREOGRAPHY around it changed, not the decode logic
; itself, so CALC_TABLE's literal numbering still matches the real ROM
; exactly (see that table's own header) and porting a real op body
; later still needs zero literal-value translation.
;
; VALIDATION STATUS: assembled by sjasmplus as part of the production
; HOME/EXROM build and exercised by tools/z80sim/test_calc_dispatcher.py,
; the dedicated calculator smoke ROMs, and the integrated BASIC suite.
; See docs/calculator_review.md for the current coverage and the explicit
; robustness limits that remain before this can be treated as a general-
; purpose replacement for the original ROM calculator.
;
; ENTRY CONTRACT (CALC_EXROM_ENTRY, reached via the $C024 stub — rom/
; exrom_checker.asm): stack top = pointer to the literal-op byte stream
; (RST $28's own return address, untouched by both Home-side trampolines
; — see basic/basic.asm's CALC_ENTRY_TRAMPOLINE/CALC_EXIT_TRAMPOLINE
; headers, unaffected by this rework). B = operation offset/counter,
; passed through unchanged from the RST $28 call site (0 for an
; ordinary top-level call — the real ROM's literal $3B single-op
; shortcut isn't ported yet, same reasoning as the other 65
; unimplemented ops: nothing calls it yet).
; ============================================================================

CALC_EXROM_ENTRY:
CALC_GEN_ENT_1:
    ld   a, b
    ld   (CALC_BREG), a
CALC_GEN_ENT_2:
    ; Grab the literal-byte-code pointer off the real stack (RST $28's
    ; own return address, or CALC_ENTRY_TRAMPOLINE's tail-jump target —
    ; either way, untouched) directly into CALC_LITERAL_PTR. No primed
    ; registers, no placeholder stack slot — the real stack is simply
    ; one item shorter from here until CALC_OP_END_CALC pushes the
    ; final return address back.
    pop  hl
    ld   (CALC_LITERAL_PTR), hl

; ----------------------------------------------------------------------
; CALC_RE_ENTRY / CALC_SCAN_ENT / CALC_FIRST_3D / CALC_ENT_TABLE
; Fetch-decode-dispatch loop. Decode arithmetic matches 335B.html; the
; register plumbing around it does not (see file header).
; ----------------------------------------------------------------------
CALC_RE_ENTRY:
    ld   hl, (CALC_LITERAL_PTR)
    ld   a, (hl)              ; fetch next literal
    inc  hl
    ld   (CALC_LITERAL_PTR), hl  ; persist the advanced pointer
                                 ; immediately — CALC_OP_END_CALC reads
                                 ; it straight from here, no separate
                                 ; "true return address" bookkeeping
                                 ; needed (see that op's own header)
CALC_SCAN_ENT:
    and  a
    jp   p, CALC_FIRST_3D       ; literal < $80 -> simple/manipulatory
    ; "Multi-purpose" literal (>=$80): extract category (bits 5-6) and
    ; parameter (bits 0-4). Real ROM: RRCA x4 then ADD A,$7C. Here:
    ; SRL A x4 is an exact substitute (AND $60 already zeroed the bits
    ; a rotate would wrap into — see file header).
    ld   d, a
    and  $60
    srl  a
    srl  a
    srl  a
    srl  a
    add  a, $7C
    ld   c, a                  ; C = table index (doubled already, since
                                ; $7C's low bit pattern accounts for it —
                                ; matches the real ROM's own L-register
                                ; use here exactly, just renamed)
    ld   a, d
    and  $1F
    ld   (CALC_LITERAL_PARAM), a  ; not read by any op yet — see
                                    ; sysvars.inc's own comment on this
    jr   CALC_DISPATCH
CALC_FIRST_3D:
    cp   $18
    jr   nc, CALC_UNARY_OR_MANIP  ; literal >= $18 -> no operand-2
    ; Binary op ($00-$17): both operand pointers needed.
    push af                       ; protect the literal value across
                                   ; the pointer-computation call
    call CALC_STK_PNTRS_BINARY    ; sets CALC_OP1_PTR + CALC_OP2_PTR
    pop  af
    jr   CALC_DOUBLE_A
CALC_UNARY_OR_MANIP:
    push af
    call CALC_STK_PNTRS_UNARY      ; sets CALC_OP1_PTR only
    pop  af
CALC_DOUBLE_A:
    add  a, a                       ; x2 (ADD A,A substitutes RLCA here
                                    ; — safe, A<$80 confirmed by the
                                    ; `jp p` test above; see file header)
    ld   c, a
CALC_DISPATCH:
    ld   b, 0
    ld   hl, CALC_TABLE
    add  hl, bc
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ex   de, hl                     ; HL = op routine address
    ld   a, (CALC_BREG)
    ld   b, a                        ; B = BREG, matches the real ROM's
                                     ; own contract for ops that use it
    jp   (hl)                        ; -> the op routine. Its own first
                                     ; instruction(s) reload HL/DE from
                                     ; CALC_OP1_PTR/CALC_OP2_PTR — see
                                     ; those sysvars' own comments

; ============================================================================
; CALC_STK_PNTRS_UNARY / CALC_STK_PNTRS_BINARY
; This project's replacement for the real ROM's STK_PNTRS (35BF) —
; computed fresh from CALC_SP against the fixed CALC_STACK array every
; call, not carried incrementally (see CALC_OP1_PTR's own sysvars.inc
; comment for why). Split into two entry points rather than one with a
; branch, since the binary case needs one extra pointer and the real
; ROM's own text already frames these as conceptually separate steps
; ("presume a unary operation..." vs. the FIRST_3D binary adjustment).
; In:  CALC_SP = current stack depth (0 = empty)
; Out: CALC_OP1_PTR = CALC_STACK + (CALC_SP-1)*5 (top-of-stack operand —
;      only meaningful if CALC_SP > 0; an op called on an empty stack
;      is a caller bug this doesn't defend against, same as real ROM)
;      CALC_OP2_PTR (CALC_STK_PNTRS_BINARY only) = CALC_STACK +
;      (CALC_SP-1)*5 (top-of-stack — the SECOND operand, matching the
;      real ROM's own HL=first(lower)/DE=second(top) convention — see
;      335B.html's FIRST_3D binary branch: DE=original top, HL=top-5)
; Destroys: AF, BC, DE, HL
; ============================================================================
CALC_STK_PNTRS_UNARY:
    jp CALC_SP_TO_TOP_PTR

CALC_STK_PNTRS_BINARY:
    ; FIXED 2026-08-20: this used to set CALC_OP1_PTR=top and CALC_
    ; OP2_PTR=top-5 — backwards from the real ROM's own convention
    ; (confirmed against 335B.html's FIRST_3D: DE=original top=SECOND
    ; operand, HL=top-5=FIRST operand). Caught while cross-checking
    ; real exchange/delete semantics before implementing them — those
    ; ops' real bodies assume HL=first(lower)/DE=second(top), so
    ; getting this backwards would have silently swapped their
    ; behavior. Nothing shipped depended on the old (wrong) mapping —
    ; CALC_STK_PNTRS_BINARY had no real caller yet — so this was safe
    ; to fix outright rather than needing a compatibility shim.
    call CALC_SP_TO_TOP_PTR         ; HL = top; also stored into
                                    ; CALC_OP1_PTR by this call (that's
                                    ; the UNARY case's own home for it —
                                    ; overwritten below for the binary
                                    ; case, which needs OP2_PTR there
                                    ; instead)
    ld   (CALC_OP2_PTR), hl          ; correct home: top = SECOND operand
    ld   bc, -5
    add  hl, bc                       ; HL = top - 5 = FIRST operand
    ld   (CALC_OP1_PTR), hl
    ret

; ----------------------------------------------------------------------
; CALC_SP_TO_TOP_PTR — shared arithmetic: computes CALC_STACK +
; (CALC_SP-1)*5 (the top-of-stack slot) into HL, and stores it into
; CALC_OP1_PTR (correct as-is for the unary caller above; the binary
; caller above immediately relocates it to CALC_OP2_PTR instead, since
; for a binary op the top is the SECOND operand, not the first — see
; that routine's own comment). Destroys: AF, BC, DE, HL
; ----------------------------------------------------------------------
CALC_SP_TO_TOP_PTR:
    ld   a, (CALC_SP)
    dec  a                       ; A = CALC_SP-1 (index of top slot)
    ld   c, a
    ld   b, 0
    ld   hl, 0
    add  hl, bc
    add  hl, hl                  ; HL = index*2
    add  hl, hl                  ; HL = index*4
    add  hl, bc                  ; HL = index*5
    ld   de, CALC_STACK
    add  hl, de
    ld   (CALC_OP1_PTR), hl
    ret

; ----------------------------------------------------------------------
; CALC_SP_TO_NEXT_FREE_PTR — CALC_STACK + CALC_SP*5 (one past the
; current top — where a new push, e.g. duplicate, lands). Returns in
; DE (not HL) since callers typically already hold a source address in
; HL and need DE free for LDIR's destination. Destroys: AF, BC, DE, HL
; ----------------------------------------------------------------------
CALC_SP_TO_NEXT_FREE_PTR:
    ld   a, (CALC_SP)
    ld   c, a
    ld   b, 0
    ld   hl, 0
    add  hl, bc
    add  hl, hl
    add  hl, hl
    add  hl, bc
    ld   de, CALC_STACK
    add  hl, de
    ex   de, hl
    ret

; ============================================================================
; CALC_OP_END_CALC (literal $38 — CALC_TABLE index $38, matches the
; real ROM's own numbering exactly: "The last literal in the list is
; always +38 which leads to an end to the whole operation" — 335B.html)
;
; CALC_LITERAL_PTR already holds the correct resume address at this
; point (advanced past the $38 literal itself by CALC_RE_ENTRY before
; dispatch, same as every other literal) — no separate "true return"
; tracking needed at all in this reworked version, unlike the real
; ROM's own placeholder-stack-slot dance (see file header).
;
; STILL can't page out from here directly — this file is EXROM-
; resident, and paging Home back in changes what's AT this very address
; range if the next fetch is still $C000-$DFFF (see basic/basic.asm's
; Tail-jumps to CALC_EXIT_TRAMPOLINE (Home-resident) via KTAB_CALC_
; EXIT_TRAMPOLINE (include/exrom_jumptable.inc) — not a direct label
; reference, since this file and basic.asm are separate compilation
; units (see this op's own code below for the full reasoning).
; In:  CALC_LITERAL_PTR = the true resume address
; Out: none (tail-jumps toward the true original caller)
; Destroys: AF, HL
; ============================================================================
CALC_OP_END_CALC:
    ld   hl, (CALC_LITERAL_PTR)
    push hl
    jp   KTAB_CALC_EXIT_TRAMPOLINE ; NOT a direct `jp CALC_EXIT_
                                   ; TRAMPOLINE` — this file is a
                                   ; separate compilation unit from
                                   ; basic.asm (assembled via rom/
                                   ; exrom_build.asm, not rom/
                                   ; test_basic.asm), so that label
                                   ; genuinely doesn't exist here.
                                   ; Routed through the KTAB_* jump
                                   ; table (include/exrom_jumptable.
                                   ; inc) instead, same as every other
                                   ; EXROM->Home call in this project —
                                   ; caught by a real sjasmplus "Label
                                   ; not found" error this sandbox
                                   ; can't reproduce; direct-reference
                                   ; version never should have shipped

; ============================================================================
; CALC_OP_EXCHANGE (literal $01 — CALC_TABLE index $02, confirmed
; against skoolkid.github.io/rom/asm/343C.html, "THE 'EXCHANGE'
; SUBROUTINE (offset +01)": swaps the top two 5-byte stack slots byte
; by byte via a DJNZ loop. Ported directly, unmodified from the real
; body — this routine never used EXX or any primed-register trick even
; in the original, so unlike CALCULATE's own dispatch loop, nothing
; here needed reworking at all.
;
; Real ROM's own final `EX DE,HL` (before its RET) exists only to fix
; up HL for callers that expect it to still hold a meaningful pointer
; afterward — irrelevant here, since CALC_RE_ENTRY recomputes CALC_
; OP1_PTR/OP2_PTR fresh from CALC_SP every iteration rather than
; trusting carried-forward register state (see those sysvars' own
; comments) — so that fixup step is dropped, not overlooked.
;
; In:  CALC_OP1_PTR = first operand (lower slot), CALC_OP2_PTR = second
;      operand (top slot) — set by CALC_STK_PNTRS_BINARY before dispatch
; Out: the two slots' contents are swapped; CALC_SP unchanged (same
;      depth, just reordered)
; Destroys: AF, BC, DE, HL
; ============================================================================
CALC_OP_EXCHANGE:
    ld   hl, (CALC_OP1_PTR)
    ld   de, (CALC_OP2_PTR)
    ld   b, 5
.swap_byte:
    ld   a, (de)
    ld   c, (hl)
    ex   de, hl
    ld   (de), a
    ld   (hl), c
    inc  hl
    inc  de
    djnz .swap_byte
    jp   CALC_RE_ENTRY

; ============================================================================
; CALC_OP_DELETE (literal $02 — CALC_TABLE index $04, confirmed against
; 335B.html: "delete... contains only the single RET instruction... the
; first number [is] considered as the resulting 'last value' and the
; second number considered as being deleted.")
;
; Real ROM needs no data movement at all — the first operand's slot IS
; already where the shrunk stack's new top belongs. Same is true here,
; for the same reason: CALC_OP1_PTR = CALC_STACK+(CALC_SP-2)*5, which
; equals CALC_STACK+(new_CALC_SP-1)*5 the instant CALC_SP decrements —
; the exact address CALC_STK_PNTRS_UNARY would compute as "top" on the
; very next dispatch. The only thing our fixed-CALC_SP design needs
; that the real ROM's raw-pointer model didn't: explicitly decrementing
; the depth counter, since nothing else tracks it implicitly here.
;
; In:  CALC_SP >= 2 (a caller invoking a binary op on a shorter stack is
;      a bug this doesn't defend against, same as the real ROM doesn't)
; Out: CALC_SP decremented by 1; no data moved
; Destroys: AF
; ============================================================================
CALC_OP_DELETE:
    ld   a, (CALC_SP)
    dec  a
    ld   (CALC_SP), a
    jp   CALC_RE_ENTRY

; ============================================================================
; CALC_OP_DUPLICATE (literal $31 — CALC_TABLE index $62, confirmed
; against skoolkid.github.io/rom/asm/33C0.html, "THE 'MOVE A FLOATING-
; POINT NUMBER' SUBROUTINE (offset +31)": "duplicates the number at the
; top of the calculator stack... thereby extending the stack by five
; bytes." Real body: `CALL TEST_5_SP` (bounds check against free RAM)
; then `LDIR` (5 bytes, HL->DE) then `RET`.
;
; Ours needs a DIFFERENT bounds check — the real ROM's stack grows into
; free RAM and only fails on genuine memory exhaustion; this project's
; CALC_STACK is a fixed 8 slots (see that sysvar's own comment), so an
; 8-deep RPN expression alone can hit the cap, a normal-ish case worth
; its own clear diagnostic (CALC_STACK_OVERFLOW_FLAG) rather than
; silently writing past the array's end.
;
; Literal $31 is >=$18 (unary/manipulatory path, not binary) — matches
; the real ROM's own literal-numbering split — so CALC_OP2_PTR is NOT
; set by dispatch for this op; the destination (next free slot) is
; this routine's own responsibility, same as the real ROM's own DE
; input has to come from somewhere the generic dispatch doesn't provide
; for every manipulatory op (not all of them grow the stack).
;
; In:  CALC_OP1_PTR = top (source) — set by CALC_STK_PNTRS_UNARY
; Out: CALC_SP incremented by 1; the new top slot is a copy of the old
;      one. On overflow (CALC_SP already 8): hangs via its own local
;      jr-to-self loop, same shape as CALC_OP_UNIMPLEMENTED's (this
;      project's established diagnostic-hang idiom) but not a shared
;      cross-routine jump target — a reader shouldn't need to chase
;      into a different op's internals to understand this one's own
;      overflow path, and tools/z80sim/sim.py's resolve_label has no
;      support for a qualified GLOBAL.local reference anyway (confirmed
;      by reading its implementation, not assumed) — 2 duplicated bytes
;      is a fair trade for both
; Destroys: AF, BC, DE, HL
; ============================================================================
CALC_OP_DUPLICATE:
    ld   a, (CALC_SP)
    cp   8
    jr   nc, .overflow
    ld   hl, (CALC_OP1_PTR)      ; source = top
    push hl
    call CALC_SP_TO_NEXT_FREE_PTR ; DE = destination = next free slot
    pop  hl
    ld   bc, 5
    ldir
    ld   a, (CALC_SP)
    inc  a
    ld   (CALC_SP), a
    jp   CALC_RE_ENTRY
.overflow:
    ld   (CALC_STACK_OVERFLOW_FLAG), a
.hang_loop:
    jr   .hang_loop

; ============================================================================
; CALC_UNPACK / CALC_PACK — general float <-> internal record conversion,
; shared by INT_TO_FP/FP_TO_INT and the arithmetic engine below. Internal
; record (6 bytes, at CALC_UNP_A or CALC_UNP_B — see sysvars.inc): byte0
; = sign ($00/$FF, matching the float format's own small-int-form
; convention), byte1 = biased exponent (0 = zero value), bytes2-5 = 32-
; bit mantissa MSB-first with the implicit leading bit made explicit.
; A single unpack routine that checks the small-int fast-path form
; FIRST is mandatory here — the Python model this was ported from hit a
; real bug from splitting that check out (see project /areas notes,
; "unpack() split into two functions" entry) where a general-only
; unpacker silently treated fast-path zero as general zero and vice
; versa, since both forms use byte0=$00.
;
; CALC_UNPACK  In: HL=src 5-byte float ptr, DE=dest 6-byte record ptr
;              Out: record filled. Destroys AF,BC,DE,HL
; CALC_PACK    In: HL=src 6-byte record ptr, DE=dest 5-byte float ptr.
;              Always writes GENERAL form (never re-derives the small-
;              int fast form for an exact-integer result) — FP_TO_INT
;              already handles both forms on read, so nothing
;              downstream needs the fast form specifically.
;              Out: float written. Destroys AF,BC,DE,HL
; ============================================================================
CALC_UNPACK:
    ld   a, (hl)
    or   a
    jr   nz, .cu_general
    inc  hl
    ld   a, (hl)                 ; sign byte ($00/$FF)
    push af
    inc  hl
    ld   c, (hl)                  ; low byte of pattern
    inc  hl
    ld   b, (hl)                   ; high byte of pattern
    ld   a, b
    or   c
    jr   nz, .cu_fast_nonzero
    pop  af
    xor  a
    ld   (de), a
    inc  de
    ld   (de), a
    inc  de
    ld   (de), a
    inc  de
    ld   (de), a
    inc  de
    ld   (de), a
    inc  de
    ld   (de), a
    ret
.cu_fast_nonzero:
    pop  af
    or   a
    jr   z, .cu_fast_write_sign
    push af
    xor  a
    sub  c
    ld   c, a
    ld   a, 0
    sbc  a, b
    ld   b, a
    pop  af
.cu_fast_write_sign:
    ld   (de), a                  ; record byte0 = sign
    push de
    ld   h, 0
    ld   l, 0
    ld   d, b
    ld   e, c
    ld   b, 0
.cu_norm_loop:
    bit  7, h
    jr   nz, .cu_norm_done
    sla  e
    rl   d
    rl   l
    rl   h
    inc  b
    jr   .cu_norm_loop
.cu_norm_done:
    ld   a, 160
    sub  b
    ld   b, e                      ; FIXED: D/E currently hold mantissa
                                   ; bytes 1/0 -- popping DE next would
                                   ; destroy them (DE becomes the
                                   ; record address instead), so stash
                                   ; them in B/C first (B is free, its
                                   ; only other job -- the shift
                                   ; counter -- is done). Also fixes a
                                   ; SECOND bug this uncovered: `LD
                                   ; (DE),H/L/D/E` isn't a real Z80
                                   ; opcode at all -- (DE)-indirect
                                   ; only ever supports A as the
                                   ; source (LD (DE),A, opcode $12) —
                                   ; sjasmplus would have rejected this
                                   ; outright. Every write below now
                                   ; goes through A, the only valid
                                   ; source register for a (DE) write.
                                   ; Found by decoding a real unpacked
                                   ; record back through the verified
                                   ; Python model and noticing bytes
                                   ; 4-5 exactly matched (record_addr+4)
                                   ; and (record_addr+5)'s own high/low
                                   ; bytes -- i.e. this routine was
                                   ; writing its OWN pointer back into
                                   ; itself, not the mantissa at all.
    ld   c, d
    pop  de
    inc  de
    ld   (de), a                  ; exponent
    inc  de
    ld   a, h
    ld   (de), a                    ; mantissa MSB
    inc  de
    ld   a, l
    ld   (de), a
    inc  de
    ld   a, c                       ; mantissa byte1 (was D)
    ld   (de), a
    inc  de
    ld   a, b                        ; mantissa LSB (was E)
    ld   (de), a
    ret
.cu_general:
    push af                        ; A = exponent (byte0), saved
    inc  hl
    ld   a, (hl)                    ; byte1
    ld   c, a
    and  $80
    jr   z, .cu_gen_pos
    ld   a, $FF
    jr   .cu_gen_sign_done
.cu_gen_pos:
    xor  a
.cu_gen_sign_done:
    ld   (de), a
    inc  de
    pop  af
    ld   (de), a                    ; exponent
    inc  de
    ld   a, c
    and  $7F
    or   $80
    ld   (de), a                     ; mantissa MSB (implicit bit set)
    inc  de
    inc  hl
    ld   a, (hl)
    ld   (de), a
    inc  de
    inc  hl
    ld   a, (hl)
    ld   (de), a
    inc  de
    inc  hl
    ld   a, (hl)
    ld   (de), a
    ret

CALC_PACK:
    ld   a, (hl)
    push af
    inc  hl
    ld   a, (hl)                     ; exponent
    or   a
    jr   z, .cp_zero
    ld   (de), a
    inc  de
    pop  af
    and  $80
    ld   b, a
    inc  hl
    ld   a, (hl)                      ; mantissa MSB (bit7 already 1)
    and  $7F
    or   b
    ld   (de), a
    inc  de
    inc  hl
    ld   a, (hl)
    ld   (de), a
    inc  de
    inc  hl
    ld   a, (hl)
    ld   (de), a
    inc  de
    inc  hl
    ld   a, (hl)
    ld   (de), a
    ret
.cp_zero:
    pop  af
    xor  a
    ld   (de), a
    inc  de
    ld   (de), a
    inc  de
    ld   (de), a
    inc  de
    ld   (de), a
    inc  de
    ld   (de), a
    ret

; ============================================================================
; CALC_INT_TO_FP — boundary converter, NOT a CALC_TABLE literal (the
; real ROM's analog, STACK-A, isn't one either — see project /areas
; notes). Pushes a 16-bit signed int onto CALC_STACK as the small-int
; fast form (always valid for a 16-bit source — no mantissa math
; needed at all).
; In:  HL = signed 16-bit int
; Out: CALC_SP incremented by 1. On overflow (CALC_SP already at the
;      8-slot cap): same diagnostic idiom as CALC_OP_DUPLICATE's own
;      overflow path (CALC_STACK_OVERFLOW_FLAG + local hang) — not
;      shared cross-routine, same reasoning as that routine's own
;      header (tools/z80sim/sim.py's resolve_label has no qualified-
;      label support).
; Destroys: AF, BC, DE, HL
; ============================================================================
CALC_INT_TO_FP:
    push hl
    ld   a, (CALC_SP)
    cp   8
    jr   nc, .cif_overflow
    call CALC_SP_TO_NEXT_FREE_PTR
    pop  hl
    xor  a
    ld   (de), a
    inc  de
    ld   a, h
    or   a
    jp   p, .cif_pos
    ld   a, $FF
    jr   .cif_sign_done
.cif_pos:
    xor  a
.cif_sign_done:
    ld   (de), a
    inc  de
    ld   a, l
    ld   (de), a
    inc  de
    ld   a, h
    ld   (de), a
    inc  de
    xor  a
    ld   (de), a
    ld   a, (CALC_SP)
    inc  a
    ld   (CALC_SP), a
    ret
.cif_overflow:
    pop  hl
    ld   a, (CALC_SP)
    ld   (CALC_STACK_OVERFLOW_FLAG), a
.cif_hang:
    jr   .cif_hang

; ============================================================================
; CALC_FP_TO_INT — boundary converter (real ROM's STK-TO-A/STK-TO-BC
; analog), pops the top of CALC_STACK and converts to a signed 16-bit
; int. Handles both the small-int fast form (always exact, no range
; check needed) and the general form (truncate-toward-zero, matching
; the real "truncate" literal $3A's semantics, plus an explicit 16-bit
; range check).
; Out: HL = converted int (best-effort even on overflow — lesson 10:
;      store the real value, don't guess). CALC_TRUNC_FLAG (sysvars.inc
;      — already the documented hook for exactly this) set to 1 on
;      overflow, 0 otherwise. [stated]'s confirmed decision: a future
;      LET-assignment integration is responsible for turning a set
;      CALC_TRUNC_FLAG into a real BASIC "Integer out of range" error
;      (matching the real ROM's own idiom) — that wiring doesn't exist
;      yet (no caller does real LET-assignment through the calculator
;      yet, same status as every other op here), so this routine only
;      raises the flag, per the project's own established "cheap hook
;      now vs. redesign later" reasoning for CALC_TRUNC_FLAG itself.
;      CALC_SP decremented by 1.
; In:  CALC_SP > 0 (caller bug otherwise, same as every other op here)
; Destroys: AF, BC, DE, HL
; ============================================================================
CALC_FP_TO_INT:
    ld   a, (CALC_SP)
    dec  a
    ld   (CALC_SP), a
    call CALC_SP_TO_NEXT_FREE_PTR
    ex   de, hl
    ld   a, (hl)
    or   a
    jr   nz, .fpi_general
    inc  hl
    ld   a, (hl)
    inc  hl
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ex   de, hl
    xor  a
    ld   (CALC_TRUNC_FLAG), a
    ret
.fpi_general:
    ld   (CALC_UNP_A+1), a
    inc  hl
    ld   a, (hl)
    ld   c, a
    and  $80
    ld   (CALC_SHIFT_COUNT), a        ; stash sign bit ($00/$80)
    ld   a, c
    and  $7F
    or   $80
    ld   (CALC_UNP_A+2), a
    inc  hl
    ld   a, (hl)
    ld   (CALC_UNP_A+3), a
    inc  hl
    ld   a, (hl)
    ld   (CALC_UNP_A+4), a           ; source byte4 (true LSB) dropped —
                                     ; see header, never affects the
                                     ; overflow/no-overflow verdict for
                                     ; this BASIC's 16-bit-sourced range
    ld   a, (CALC_UNP_A+1)
    sub  128
    jr   z, .fpi_result_zero
    jp   m, .fpi_result_zero
    cp   17
    jr   nc, .fpi_overflow_noshift    ; unbiased exponent >= 17 ->
                                       ; magnitude always >= 65536,
                                       ; never a valid 16-bit int
    ; FIXED (found by re-deriving this in Python against the verified
    ; model before trusting it, not caught by eye): the real shift
    ; needed is (32-EXP_UNBIASED) applied to the FULL 32-bit mantissa,
    ; but since EXP_UNBIASED here is always 1-16, that shift is always
    ; >=16 -- meaning the result depends ONLY on the mantissa's top 16
    ; bits (this record's MSB byte + the next byte), shifted by
    ; (16-EXP_UNBIASED), 0..15. The original version tracked a 3rd
    ; mantissa byte and read out the WRONG 16-bit window afterward (a
    ; 16-bit position error) -- dropped that byte and the wrong
    ; register entirely rather than patching the read-out math.
    ld   b, a
    ld   a, 16
    sub  b
    ld   b, a                          ; shift amount, 0..15
    ld   a, (CALC_UNP_A+2)
    ld   h, a
    ld   a, (CALC_UNP_A+3)
    ld   l, a
    ld   a, b
    or   a
    jr   z, .fpi_shift_done
.fpi_shift_loop:
    srl  h
    rr   l
    djnz .fpi_shift_loop
.fpi_shift_done:
    ld   a, (CALC_SHIFT_COUNT)
    or   a
    jr   z, .fpi_check
    xor  a
    sub  l
    ld   l, a
    ld   a, 0
    sbc  a, h
    ld   h, a
.fpi_check:
    ld   a, (CALC_SHIFT_COUNT)
    ld   c, a
    ld   a, h
    and  $80
    cp   c
    jr   nz, .fpi_overflow
    xor  a
    ld   (CALC_TRUNC_FLAG), a
    ret
.fpi_overflow:
    ld   a, 1
    ld   (CALC_TRUNC_FLAG), a
    ret
.fpi_overflow_noshift:
    ld   hl, 0
    ld   a, 1
    ld   (CALC_TRUNC_FLAG), a
    ret
.fpi_result_zero:
    ld   hl, 0
    xor  a
    ld   (CALC_TRUNC_FLAG), a
    ret

; ============================================================================
; CALC_PUSH_FP_RAW — boundary converter, same family as CALC_INT_TO_FP/
; CALC_FP_TO_INT above (not a CALC_TABLE literal — nothing in the
; literal stream needs "push an arbitrary constant", every literal
; program built so far only ever pushes plain ints via CALC_INT_TO_FP).
; Added 2026-08-22 for SIN: the degrees->radians conversion needs pi
; itself on the stack, and pi isn't a 16-bit int CALC_INT_TO_FP could
; produce. Copies an already-packed 5-byte float verbatim onto
; CALC_STACK's next free slot — no packing/unpacking at all, since the
; source bytes are already in exactly the on-stack format (same
; overflow-check shape as CALC_INT_TO_FP's own).
; In:  HL = pointer to a 5-byte packed float (ROM or RAM — ordinary
;      data, unaffected by EXROM paging either way)
; Out: CALC_SP incremented by 1
; Destroys: AF, BC, DE, HL
; ============================================================================
CALC_PUSH_FP_RAW:
    ld   a, (CALC_SP)
    cp   8
    jr   nc, .overflow
    push hl
    call CALC_SP_TO_NEXT_FREE_PTR   ; DE = dest (next free slot)
    pop  hl
    ld   bc, 5
    ldir
    ld   a, (CALC_SP)
    inc  a
    ld   (CALC_SP), a
    ret
.overflow:
    ld   a, (CALC_SP)
    ld   (CALC_STACK_OVERFLOW_FLAG), a
.hang:
    jr   .hang

; ============================================================================
; CALC_PUSH_PI — pushes the constant pi (packed float, PI_CONST below)
; via CALC_PUSH_FP_RAW. Its own fixed entry stub (rom/exrom_checker.
; asm) is what basic.asm's CALC_PUSH_PI_HOME actually calls — this
; label itself is EXROM-internal only, same reasoning as every other
; op in this file (see CALC_OP_END_CALC's own header on why EXROM
; can't be called by direct label reference from Home).
; In/Out/Destroys: same as CALC_PUSH_FP_RAW.
; ============================================================================
CALC_PUSH_PI:
    ld   hl, PI_CONST
    jp   CALC_PUSH_FP_RAW

; pi = 3.14159265..., encoded by hand via this project's own documented
; pack algorithm (docs/programmers_reference.md's calculator section)
; and cross-checked in Python before trusting it here: byte0=$82 ->
; unbiased exponent 2 (value = mantissa * 4, mantissa in [0.5,1)); the
; decoded round-trip value differs from math.pi by ~4e-9, negligible
; against the 4-decimal-digit display BASIC_FLOAT_TO_STRING produces.
; These exact bytes also match the real Sinclair ROM's own well-known
; PI constant, a happy confirmation (not a requirement) that the
; encoding is right.
PI_CONST: DB $82, $49, $0F, $DA, $A2

; ============================================================================
; CALC_ADDSUB_ENGINE — shared add/subtract-via-sign-flip engine.
; Combines the already-unpacked records at CALC_UNP_A/CALC_UNP_B,
; leaving the result in CALC_UNP_A. CALC_OP_SUB flips CALC_UNP_B's sign
; before calling this, matching A-B = A+(-B); CALC_OP_ADD calls it
; directly.
;
; Algorithm: zero shortcuts, then pick the WINNER (larger-scale
; operand — bigger exponent, or if tied, bigger mantissa) and swap the
; two records if B is the winner, so CALC_UNP_A always ends up holding
; the winner and CALC_UNP_B the loser — this means the align/combine
; code below only ever has to handle ONE case, not two symmetric ones.
; Loser's mantissa is then shifted right by (winner_exp - loser_exp)
; to align scales. Same-sign -> 32-bit add with carry-out
; renormalization (shift right 1, exponent+1). Different-sign -> 32-bit
; subtract (guaranteed non-negative, since winner>=loser after
; alignment) with left-shift renormalization for cancellation, clamped
; to exact zero on underflow (near-total-cancellation edge case — a
; documented simplification, not a hidden gap: the real ROM does exact
; bit-level cancellation here, this doesn't for extreme cases, which
; this BASIC's 16-bit-int-sourced values essentially never produce).
; In:  CALC_UNP_A, CALC_UNP_B — both already unpacked
; Out: CALC_UNP_A holds the combined result
; Destroys: AF, BC, DE, HL
; ============================================================================
CALC_ADDSUB_ENGINE:
    ld   a, (CALC_UNP_A+1)
    or   a
    jr   nz, .ae_a_nonzero
    ld   hl, CALC_UNP_B
    ld   de, CALC_UNP_A
    ld   bc, 6
    ldir
    ret
.ae_a_nonzero:
    ld   a, (CALC_UNP_B+1)
    or   a
    ret  z
    ; winner selection
    ld   a, (CALC_UNP_A+1)
    ld   c, a
    ld   a, (CALC_UNP_B+1)
    cp   c
    jr   c, .ae_no_swap             ; expB < expA -> A wins
    jr   nz, .ae_do_swap             ; expB > expA -> B wins
    ld   hl, CALC_UNP_A+2
    ld   de, CALC_UNP_B+2
    ld   b, 4
.ae_mant_cmp:
    ld   a, (de)
    ld   c, a
    ld   a, (hl)
    cp   c
    jr   nz, .ae_mant_cmp_done
    inc  hl
    inc  de
    djnz .ae_mant_cmp
.ae_mant_cmp_done:
    jr   c, .ae_do_swap              ; A's byte < B's byte -> B is bigger
    jr   .ae_no_swap                  ; A's byte >= B's byte, or exact tie
.ae_do_swap:
    ld   hl, CALC_UNP_A
    ld   de, CALC_UNP_B
    ld   b, 6
.ae_swap_byte:
    ld   a, (de)
    ld   c, (hl)
    ex   de, hl
    ld   (de), a
    ld   (hl), c
    inc  hl
    inc  de
    djnz .ae_swap_byte
.ae_no_swap:
    ; CALC_UNP_A = winner, CALC_UNP_B = loser. diff = winnerExp-loserExp
    ld   a, (CALC_UNP_A+1)
    ld   b, a
    ld   a, (CALC_UNP_B+1)
    ld   c, a
    ld   a, b
    sub  c
    cp   32
    jr   c, .ae_diff_ok
    xor  a
    ld   (CALC_UNP_B+2), a
    ld   (CALC_UNP_B+3), a
    ld   (CALC_UNP_B+4), a
    ld   (CALC_UNP_B+5), a
    jr   .ae_shift_done
.ae_diff_ok:
    ld   b, a
    ld   a, (CALC_UNP_B+2)
    ld   h, a
    ld   a, (CALC_UNP_B+3)
    ld   l, a
    ld   a, (CALC_UNP_B+4)
    ld   d, a
    ld   a, (CALC_UNP_B+5)
    ld   e, a
    ld   a, b
    or   a
    jr   z, .ae_shift_loop_done
.ae_shift_loop:
    srl  h
    rr   l
    rr   d
    rr   e
    djnz .ae_shift_loop
.ae_shift_loop_done:
    ld   a, h
    ld   (CALC_UNP_B+2), a
    ld   a, l
    ld   (CALC_UNP_B+3), a
    ld   a, d
    ld   (CALC_UNP_B+4), a
    ld   a, e
    ld   (CALC_UNP_B+5), a
.ae_shift_done:
    ld   a, (CALC_UNP_A)
    ld   b, a
    ld   a, (CALC_UNP_B)
    cp   b
    jr   z, .ae_same_sign
    jr   .ae_diff_sign
.ae_same_sign:
    ; No absolute-address form of ADD/ADC exists on real Z80 (only
    ; register, immediate, and (HL)/(IX+d)/(IY+d) operands) — every
    ; byte routed through C as scratch below. sjasmplus caught this
    ; (real ground truth, this sandbox's z80sim is looser and let the
    ; invalid form slide, silently truncating the address to an
    ; immediate instead of erroring) — same underlying lesson as the
    ; CALC_UNPACK (DE)-write bug: know exactly which addressing modes
    ; a real opcode supports, don't assume the simulator enforcing
    ; nothing means the syntax is valid.
    ld   a, (CALC_UNP_B+5)
    ld   c, a
    ld   a, (CALC_UNP_A+5)
    add  a, c
    ld   (CALC_UNP_A+5), a
    ld   a, (CALC_UNP_B+4)
    ld   c, a
    ld   a, (CALC_UNP_A+4)
    adc  a, c
    ld   (CALC_UNP_A+4), a
    ld   a, (CALC_UNP_B+3)
    ld   c, a
    ld   a, (CALC_UNP_A+3)
    adc  a, c
    ld   (CALC_UNP_A+3), a
    ld   a, (CALC_UNP_B+2)
    ld   c, a
    ld   a, (CALC_UNP_A+2)
    adc  a, c
    ld   (CALC_UNP_A+2), a
    jr   nc, .ae_add_no_carry
    ; carry out of the 32-bit add -- shift right 1 (carry chain first,
    ; THEN set the new MSB bit as a separate final pass -- 'or' clears
    ; carry, so it can't sit between the srl and the rr chain that
    ; needs that carry)
    ld   a, (CALC_UNP_A+2)
    srl  a
    ld   (CALC_UNP_A+2), a
    ld   a, (CALC_UNP_A+3)
    rr   a
    ld   (CALC_UNP_A+3), a
    ld   a, (CALC_UNP_A+4)
    rr   a
    ld   (CALC_UNP_A+4), a
    ld   a, (CALC_UNP_A+5)
    rr   a
    ld   (CALC_UNP_A+5), a
    ld   a, (CALC_UNP_A+2)
    or   $80
    ld   (CALC_UNP_A+2), a
    ld   a, (CALC_UNP_A+1)
    inc  a
    ld   (CALC_UNP_A+1), a
.ae_add_no_carry:
    ret
.ae_diff_sign:
    ld   a, (CALC_UNP_B+5)
    ld   c, a
    ld   a, (CALC_UNP_A+5)
    sub  c
    ld   (CALC_UNP_A+5), a
    ld   a, (CALC_UNP_B+4)
    ld   c, a
    ld   a, (CALC_UNP_A+4)
    sbc  a, c
    ld   (CALC_UNP_A+4), a
    ld   a, (CALC_UNP_B+3)
    ld   c, a
    ld   a, (CALC_UNP_A+3)
    sbc  a, c
    ld   (CALC_UNP_A+3), a
    ld   a, (CALC_UNP_B+2)
    ld   c, a
    ld   a, (CALC_UNP_A+2)
    sbc  a, c
    ld   (CALC_UNP_A+2), a
    or   a
    jr   nz, .ae_sub_nonzero
    ld   a, (CALC_UNP_A+3)
    or   a
    jr   nz, .ae_sub_nonzero
    ld   a, (CALC_UNP_A+4)
    or   a
    jr   nz, .ae_sub_nonzero
    ld   a, (CALC_UNP_A+5)
    or   a
    jr   nz, .ae_sub_nonzero
    jr   .ae_result_zero
.ae_sub_nonzero:
    ld   b, 0
.ae_renorm_loop:
    ld   a, (CALC_UNP_A+2)
    bit  7, a
    jr   nz, .ae_renorm_done
    ld   a, (CALC_UNP_A+1)
    dec  a
    jr   z, .ae_result_zero
    ld   (CALC_UNP_A+1), a
    ld   a, (CALC_UNP_A+5)
    sla  a
    ld   (CALC_UNP_A+5), a
    ld   a, (CALC_UNP_A+4)
    rl   a
    ld   (CALC_UNP_A+4), a
    ld   a, (CALC_UNP_A+3)
    rl   a
    ld   (CALC_UNP_A+3), a
    ld   a, (CALC_UNP_A+2)
    rl   a
    ld   (CALC_UNP_A+2), a
    inc  b
    ld   a, b
    cp   32
    jr   nc, .ae_result_zero          ; safety cap, shouldn't be reached
    jr   .ae_renorm_loop
.ae_renorm_done:
    ret
.ae_result_zero:
    xor  a
    ld   (CALC_UNP_A), a
    ld   (CALC_UNP_A+1), a
    ld   (CALC_UNP_A+2), a
    ld   (CALC_UNP_A+3), a
    ld   (CALC_UNP_A+4), a
    ld   (CALC_UNP_A+5), a
    ret

; ============================================================================
; CALC_OP_ADD (literal $0F — CALC_TABLE index $1E, addition)
; CALC_OP_SUB (literal $03 — CALC_TABLE index $06, subtract)
; Both: unpack the two stack operands (CALC_OP1_PTR=first/lower=A,
; CALC_OP2_PTR=second/top=B — matches the real ROM's HL=first/DE=second
; convention, same as exchange/delete above), combine via the shared
; engine, pack the result back into OP1's slot (the lower of the two
; consumed slots becomes the new top — same structural shape as
; CALC_OP_DELETE), CALC_SP -1 net (two consumed, one produced).
; SUB computes A-B by flipping B's unpacked sign before the shared add
; engine runs (A + (-B) = A-B) — literal $03's own real-ROM semantics:
; first(lower) operand minus second(top) operand.
; In:  CALC_OP1_PTR/CALC_OP2_PTR set by CALC_STK_PNTRS_BINARY
; Out: CALC_SP decremented by 1; OP1's slot holds the result
; Destroys: AF, BC, DE, HL
; ============================================================================
CALC_OP_ADD:
    ld   hl, (CALC_OP1_PTR)
    ld   de, CALC_UNP_A
    call CALC_UNPACK
    ld   hl, (CALC_OP2_PTR)
    ld   de, CALC_UNP_B
    call CALC_UNPACK
    call CALC_ADDSUB_ENGINE
    ld   hl, CALC_UNP_A
    ld   de, (CALC_OP1_PTR)
    call CALC_PACK
    ld   a, (CALC_SP)
    dec  a
    ld   (CALC_SP), a
    jp   CALC_RE_ENTRY

CALC_OP_SUB:
    ld   hl, (CALC_OP1_PTR)
    ld   de, CALC_UNP_A
    call CALC_UNPACK
    ld   hl, (CALC_OP2_PTR)
    ld   de, CALC_UNP_B
    call CALC_UNPACK
    ld   a, (CALC_UNP_B)
    xor  $FF                        ; flip sign ($00<->$FF) -- CPL would
                                    ; do the same but tools/z80sim/sim.py
                                    ; doesn't implement it (confirmed by
                                    ; a real run, not assumed); XOR $FF
                                    ; is an exact substitute here since
                                    ; the only two values ever stored in
                                    ; this byte are $00 and $FF
    ld   (CALC_UNP_B), a
    call CALC_ADDSUB_ENGINE
    ld   hl, CALC_UNP_A
    ld   de, (CALC_OP1_PTR)
    call CALC_PACK
    ld   a, (CALC_SP)
    dec  a
    ld   (CALC_SP), a
    jp   CALC_RE_ENTRY

; ============================================================================
; CALC_OP_MUL (literal $04 — CALC_TABLE index $08, multiply)
; Real 32x32->64 unsigned multiply via shift-add (CALC_MUL_ACC/
; CALC_MUL_CAND, 8 bytes each — no hardware multiply on Z80, same
; reasoning as kernel/math's MATH_UMUL16, extended to full 64-bit width
; since a float mantissa product genuinely needs it, unlike that
; routine's deliberate 16-bit truncation). Sign = XOR of the two
; operand signs (works directly on the existing 0/$FF encoding — same
; value either way). Result exponent: bit63 of the 64-bit product set
; -> exponent=expA+expB-128, top32 of product = mantissa; bit63 clear
; -> shift product left 1 first, exponent=expA+expB-129 (derivation:
; value = mantissaA*mantissaB/2^64 * 2^(expA+expB-256), normalized back
; into mantissa/2^32*2^(exp-128) form — see project /areas notes for
; the full algebra this was worked out from).
; In:  CALC_OP1_PTR/CALC_OP2_PTR set by CALC_STK_PNTRS_BINARY
; Out: CALC_SP decremented by 1; OP1's slot holds the result
; Destroys: AF, BC, DE, HL
; ============================================================================
CALC_OP_MUL:
    ld   hl, (CALC_OP1_PTR)
    ld   de, CALC_UNP_A
    call CALC_UNPACK
    ld   hl, (CALC_OP2_PTR)
    ld   de, CALC_UNP_B
    call CALC_UNPACK
    ld   a, (CALC_UNP_A+1)
    or   a
    jp   z, .cm_zero
    ld   a, (CALC_UNP_B+1)
    or   a
    jp   z, .cm_zero
    ld   a, (CALC_UNP_A)
    ld   b, a
    ld   a, (CALC_UNP_B)
    xor  b
    ld   (CALC_SHIFT_COUNT), a       ; stash result sign
    xor  a
    ld   (CALC_MUL_ACC), a
    ld   (CALC_MUL_ACC+1), a
    ld   (CALC_MUL_ACC+2), a
    ld   (CALC_MUL_ACC+3), a
    ld   (CALC_MUL_ACC+4), a
    ld   (CALC_MUL_ACC+5), a
    ld   (CALC_MUL_ACC+6), a
    ld   (CALC_MUL_ACC+7), a
    ld   (CALC_MUL_CAND+4), a
    ld   (CALC_MUL_CAND+5), a
    ld   (CALC_MUL_CAND+6), a
    ld   (CALC_MUL_CAND+7), a
    ; FIXED: mantissaA must start in CAND's LOW 32 bits (bytes 0-3),
    ; not the high half -- the standard shift-and-add algorithm needs
    ; the multiplicand UNSHIFTED at iteration 0, growing left into the
    ; upper 32 bits only as the 32 iterations proceed. The original
    ; version put it in the high half with the low half zeroed, which
    ; produced a wildly wrong product (not just a misaligned one) —
    ; caught by decoding a real 2*3 z80sim result back to a float
    ; (7.76, not 6) and comparing byte-for-byte against the verified
    ; Python model's expected encoding, not by inspection.
    ld   a, (CALC_UNP_A+5)
    ld   (CALC_MUL_CAND), a
    ld   a, (CALC_UNP_A+4)
    ld   (CALC_MUL_CAND+1), a
    ld   a, (CALC_UNP_A+3)
    ld   (CALC_MUL_CAND+2), a
    ld   a, (CALC_UNP_A+2)
    ld   (CALC_MUL_CAND+3), a
    ld   b, 32
.cm_loop:
    ; B (the 32-iteration counter) is never touched by anything in this
    ; body -- no push/pop bc needed around it, unlike a routine that
    ; genuinely reuses B for scratch mid-loop.
    ld   a, (CALC_UNP_B+2)
    srl  a
    ld   (CALC_UNP_B+2), a
    ld   a, (CALC_UNP_B+3)
    rr   a
    ld   (CALC_UNP_B+3), a
    ld   a, (CALC_UNP_B+4)
    rr   a
    ld   (CALC_UNP_B+4), a
    ld   a, (CALC_UNP_B+5)
    rr   a
    ld   (CALC_UNP_B+5), a
    jr   nc, .cm_no_add
    ; No absolute-address ADD/ADC exists on real Z80 -- route every
    ; byte through C (free here; not the loop counter). Same lesson
    ; as the ADDSUB engine's own fix just above: sjasmplus is the only
    ; real ground truth for which addressing modes an opcode supports.
    ld   a, (CALC_MUL_CAND)
    ld   c, a
    ld   a, (CALC_MUL_ACC)
    add  a, c
    ld   (CALC_MUL_ACC), a
    ld   a, (CALC_MUL_CAND+1)
    ld   c, a
    ld   a, (CALC_MUL_ACC+1)
    adc  a, c
    ld   (CALC_MUL_ACC+1), a
    ld   a, (CALC_MUL_CAND+2)
    ld   c, a
    ld   a, (CALC_MUL_ACC+2)
    adc  a, c
    ld   (CALC_MUL_ACC+2), a
    ld   a, (CALC_MUL_CAND+3)
    ld   c, a
    ld   a, (CALC_MUL_ACC+3)
    adc  a, c
    ld   (CALC_MUL_ACC+3), a
    ld   a, (CALC_MUL_CAND+4)
    ld   c, a
    ld   a, (CALC_MUL_ACC+4)
    adc  a, c
    ld   (CALC_MUL_ACC+4), a
    ld   a, (CALC_MUL_CAND+5)
    ld   c, a
    ld   a, (CALC_MUL_ACC+5)
    adc  a, c
    ld   (CALC_MUL_ACC+5), a
    ld   a, (CALC_MUL_CAND+6)
    ld   c, a
    ld   a, (CALC_MUL_ACC+6)
    adc  a, c
    ld   (CALC_MUL_ACC+6), a
    ld   a, (CALC_MUL_CAND+7)
    ld   c, a
    ld   a, (CALC_MUL_ACC+7)
    adc  a, c
    ld   (CALC_MUL_ACC+7), a
.cm_no_add:
    ld   a, (CALC_MUL_CAND)
    sla  a
    ld   (CALC_MUL_CAND), a
    ld   a, (CALC_MUL_CAND+1)
    rl   a
    ld   (CALC_MUL_CAND+1), a
    ld   a, (CALC_MUL_CAND+2)
    rl   a
    ld   (CALC_MUL_CAND+2), a
    ld   a, (CALC_MUL_CAND+3)
    rl   a
    ld   (CALC_MUL_CAND+3), a
    ld   a, (CALC_MUL_CAND+4)
    rl   a
    ld   (CALC_MUL_CAND+4), a
    ld   a, (CALC_MUL_CAND+5)
    rl   a
    ld   (CALC_MUL_CAND+5), a
    ld   a, (CALC_MUL_CAND+6)
    rl   a
    ld   (CALC_MUL_CAND+6), a
    ld   a, (CALC_MUL_CAND+7)
    rl   a
    ld   (CALC_MUL_CAND+7), a
    ; DJNZ's displacement is +-127 bytes (lesson 2) -- this loop body
    ; is far too long for it (found by real sjasmplus, not this
    ; sandbox's z80sim, which has no range-checking at all). Plain
    ; DEC B + JP NZ instead, same pattern this project already uses
    ; everywhere else a jump might be far from its target.
    dec  b
    jp   nz, .cm_loop
    ld   a, (CALC_MUL_ACC+7)
    bit  7, a
    jr   nz, .cm_no_renorm
    ld   a, (CALC_MUL_ACC)
    sla  a
    ld   (CALC_MUL_ACC), a
    ld   a, (CALC_MUL_ACC+1)
    rl   a
    ld   (CALC_MUL_ACC+1), a
    ld   a, (CALC_MUL_ACC+2)
    rl   a
    ld   (CALC_MUL_ACC+2), a
    ld   a, (CALC_MUL_ACC+3)
    rl   a
    ld   (CALC_MUL_ACC+3), a
    ld   a, (CALC_MUL_ACC+4)
    rl   a
    ld   (CALC_MUL_ACC+4), a
    ld   a, (CALC_MUL_ACC+5)
    rl   a
    ld   (CALC_MUL_ACC+5), a
    ld   a, (CALC_MUL_ACC+6)
    rl   a
    ld   (CALC_MUL_ACC+6), a
    ld   a, (CALC_MUL_ACC+7)
    rl   a
    ld   (CALC_MUL_ACC+7), a
    ld   a, (CALC_UNP_A+1)
    ld   b, a
    ld   a, (CALC_UNP_B+1)
    add  a, b
    sub  129
    jr   .cm_store_exp
.cm_no_renorm:
    ld   a, (CALC_UNP_A+1)
    ld   b, a
    ld   a, (CALC_UNP_B+1)
    add  a, b
    sub  128
.cm_store_exp:
    ld   (CALC_UNP_A+1), a
    ld   a, (CALC_SHIFT_COUNT)
    ld   (CALC_UNP_A), a
    ld   a, (CALC_MUL_ACC+7)
    ld   (CALC_UNP_A+2), a
    ld   a, (CALC_MUL_ACC+6)
    ld   (CALC_UNP_A+3), a
    ld   a, (CALC_MUL_ACC+5)
    ld   (CALC_UNP_A+4), a
    ld   a, (CALC_MUL_ACC+4)
    ld   (CALC_UNP_A+5), a
    jr   .cm_pack
.cm_zero:
    xor  a
    ld   (CALC_UNP_A), a
    ld   (CALC_UNP_A+1), a
    ld   (CALC_UNP_A+2), a
    ld   (CALC_UNP_A+3), a
    ld   (CALC_UNP_A+4), a
    ld   (CALC_UNP_A+5), a
.cm_pack:
    ld   hl, CALC_UNP_A
    ld   de, (CALC_OP1_PTR)
    call CALC_PACK
    ld   a, (CALC_SP)
    dec  a
    ld   (CALC_SP), a
    jp   CALC_RE_ENTRY

; ============================================================================
; CALC_OP_DIV (literal $05 — CALC_TABLE index $0A, division; real ROM's
; own numbering — see 335B.html's literal list — division sits right
; after multiply, same as here)
;
; Computes OP1/OP2 (first(lower) operand divided by second(top), same
; first/second convention as CALC_OP_SUB — real ROM semantics, not this
; project's own invention).
;
; ALGORITHM (verified via Python simulation, both an abstract-integer
; model and a byte-accurate simulation of this exact instruction
; sequence, >5000 random signed cases plus the multiply test's own
; 181*181=32761 as a round-trip check — 32761/181 decodes back to
; BYTE-IDENTICAL record bytes as encoding 181 directly, not just a
; numerically-close value — before any Z80 was written, same discipline
; as kernel/math's MATH_DIVIDE16 and this file's own CALC_OP_MUL):
;
; Both mantissas (MA, MB — CALC_UNP_A+2..+5 / CALC_UNP_B+2..+5) are
; already normalized into [0.5,1) as 32-bit fractions (implicit leading
; bit forced by CALC_UNPACK). Precondition the shift-subtract loop below
; on MA < MB (true division needs the dividend strictly smaller than
; the divisor to produce a quotient that itself lands back in [0.5,1)
; with NO renormalization needed afterward — see the derivation this
; was worked out from in project /areas notes): if MA >= MB, shift MA
; right by 1 first (guaranteed to make it < MB, since MA is always <
; 2*MB when both mantissas are already normalized) and bump the result
; exponent by 1 to compensate — this is the ONLY exponent adjustment
; ever needed; unlike CALC_OP_MUL, there is no post-loop renormalization
; branch at all, because the pre-shift decision is made up front instead
; of after the fact.
;
; Main loop: 32 iterations of shift-and-subtract (same shape as kernel/
; math's MATH_UDIV16 restoring division, scaled from 16-bit to 32-bit
; mantissas): shift CALC_DIV_REM left 1 bit each iteration. The carry
; OUT of that shift (the "33rd bit" — REM's true value momentarily
; exceeding 32 bits) is checked FIRST and, if set, unconditionally
; forces a subtract — REM's true value is then guaranteed >= MB, since
; MB itself is always < 2^32. This matters: a shift-left-then-truncate-
; to-32-bits-then-compare approach (without checking that carry
; explicitly) would silently misjudge exactly this case, the same class
; of truncation bug this project already has reason to be wary of. If
; the carry is clear, an ordinary MSB-first 4-byte compare against MB
; decides. Either way, the actual subtract (REM -= MB, done as a
; straight 4-byte mod-2^32 subtract via the stored, possibly-truncated
; REM bytes) is provably correct regardless of which path set it up —
; (REM - MB) mod 2^32 and (REM + 2^32 - MB) mod 2^32 are the same value,
; so the subtract chain needs no special-casing between the two entry
; paths. Each iteration also shifts CALC_DIV_QUOT left, ORing in this
; iteration's quotient bit (1 if subtracted, 0 if not).
;
; Zero shortcuts: divisor mantissa zero (CALC_UNP_B+1 = 0, i.e. B is
; exactly zero) hangs via jr-to-self — division by zero, no error-
; reporting integration into BASIC exists for this engine yet, same
; documented gap as every other op here, same idiom as CALC_OP_
; UNIMPLEMENTED rather than silently returning a wrong value. Dividend
; mantissa zero (A is exactly zero, B nonzero) short-circuits straight
; to a zero result, same shape as CALC_OP_MUL's own .cm_zero path.
;
; In:  CALC_OP1_PTR/CALC_OP2_PTR set by CALC_STK_PNTRS_BINARY
; Out: CALC_SP decremented by 1; OP1's slot holds the result. Hangs
;      (never returns) on division by zero.
; Destroys: AF, BC, DE, HL
; ============================================================================
CALC_OP_DIV:
    ld   hl, (CALC_OP1_PTR)
    ld   de, CALC_UNP_A
    call CALC_UNPACK
    ld   hl, (CALC_OP2_PTR)
    ld   de, CALC_UNP_B
    call CALC_UNPACK

    ld   a, (CALC_UNP_B+1)
    or   a
    jp   z, .cd_divzero

    ld   a, (CALC_UNP_A+1)
    or   a
    jp   z, .cd_zero

    ld   a, (CALC_UNP_A)
    ld   b, a
    ld   a, (CALC_UNP_B)
    xor  b
    ld   (CALC_SHIFT_COUNT), a       ; stash result sign

    ld   a, (CALC_UNP_B+1)
    ld   b, a
    ld   a, (CALC_UNP_A+1)
    sub  b
    add  a, 128
    ld   (CALC_UNP_A+1), a           ; provisional exponent, no preshift

    ; preshift decision: compare MA (CALC_UNP_A+2..+5) vs MB (CALC_UNP_B
    ; +2..+5), MSB first — mirrors CALC_ADDSUB_ENGINE's own mantissa
    ; tie-break compare, fully unrolled (4 bytes) rather than DJNZ'd so
    ; nothing here needs a spare register beyond what the compare itself
    ; uses (B holds the outer 32-iteration counter later, not yet — see
    ; CALC_OP_MUL's own comment on why B stays untouched mid-loop; this
    ; block runs before that counter is even loaded, so it's moot here,
    ; but keeping the same discipline avoids a footgun if this ever gets
    ; refactored into a shared loop)
    ld   hl, CALC_UNP_A+2
    ld   de, CALC_UNP_B+2
    ld   a, (de)
    ld   c, a
    ld   a, (hl)
    cp   c
    jr   c, .cd_no_preshift
    jr   nz, .cd_preshift
    inc  hl
    inc  de
    ld   a, (de)
    ld   c, a
    ld   a, (hl)
    cp   c
    jr   c, .cd_no_preshift
    jr   nz, .cd_preshift
    inc  hl
    inc  de
    ld   a, (de)
    ld   c, a
    ld   a, (hl)
    cp   c
    jr   c, .cd_no_preshift
    jr   nz, .cd_preshift
    inc  hl
    inc  de
    ld   a, (de)
    ld   c, a
    ld   a, (hl)
    cp   c
    jr   c, .cd_no_preshift
    ; MA >= MB (including an exact tie) -> preshift
.cd_preshift:
    ld   a, (CALC_UNP_A+1)
    inc  a
    ld   (CALC_UNP_A+1), a
    ld   a, (CALC_UNP_A+2)
    srl  a
    ld   (CALC_DIV_REM), a
    ld   a, (CALC_UNP_A+3)
    rr   a
    ld   (CALC_DIV_REM+1), a
    ld   a, (CALC_UNP_A+4)
    rr   a
    ld   (CALC_DIV_REM+2), a
    ld   a, (CALC_UNP_A+5)
    rr   a
    ld   (CALC_DIV_REM+3), a
    jr   .cd_setup_done
.cd_no_preshift:
    ld   a, (CALC_UNP_A+2)
    ld   (CALC_DIV_REM), a
    ld   a, (CALC_UNP_A+3)
    ld   (CALC_DIV_REM+1), a
    ld   a, (CALC_UNP_A+4)
    ld   (CALC_DIV_REM+2), a
    ld   a, (CALC_UNP_A+5)
    ld   (CALC_DIV_REM+3), a
.cd_setup_done:
    xor  a
    ld   (CALC_DIV_QUOT), a
    ld   (CALC_DIV_QUOT+1), a
    ld   (CALC_DIV_QUOT+2), a
    ld   (CALC_DIV_QUOT+3), a

    ld   b, 32
.cd_loop:
    ; shift CALC_DIV_REM left 1 bit (no bit injected — pure left shift);
    ; the carry left in the flags afterward is the true 33rd bit
    ld   a, (CALC_DIV_REM+3)
    sla  a
    ld   (CALC_DIV_REM+3), a
    ld   a, (CALC_DIV_REM+2)
    rl   a
    ld   (CALC_DIV_REM+2), a
    ld   a, (CALC_DIV_REM+1)
    rl   a
    ld   (CALC_DIV_REM+1), a
    ld   a, (CALC_DIV_REM)
    rl   a
    ld   (CALC_DIV_REM), a
    jr   c, .cd_do_subtract           ; carry out of the top byte -> REM's
                                      ; true value is already >= 2^32,
                                      ; unconditionally >= MB (<2^32)
    ld   a, (CALC_UNP_B+2)
    ld   c, a
    ld   a, (CALC_DIV_REM)
    cp   c
    jr   c, .cd_no_subtract
    jr   nz, .cd_do_subtract
    ld   a, (CALC_UNP_B+3)
    ld   c, a
    ld   a, (CALC_DIV_REM+1)
    cp   c
    jr   c, .cd_no_subtract
    jr   nz, .cd_do_subtract
    ld   a, (CALC_UNP_B+4)
    ld   c, a
    ld   a, (CALC_DIV_REM+2)
    cp   c
    jr   c, .cd_no_subtract
    jr   nz, .cd_do_subtract
    ld   a, (CALC_UNP_B+5)
    ld   c, a
    ld   a, (CALC_DIV_REM+3)
    cp   c
    jr   c, .cd_no_subtract
    ; REM >= MB (including an exact tie) -> fall through to subtract
.cd_do_subtract:
    ld   a, (CALC_UNP_B+5)
    ld   c, a
    ld   a, (CALC_DIV_REM+3)
    sub  c
    ld   (CALC_DIV_REM+3), a
    ld   a, (CALC_UNP_B+4)
    ld   c, a
    ld   a, (CALC_DIV_REM+2)
    sbc  a, c
    ld   (CALC_DIV_REM+2), a
    ld   a, (CALC_UNP_B+3)
    ld   c, a
    ld   a, (CALC_DIV_REM+1)
    sbc  a, c
    ld   (CALC_DIV_REM+1), a
    ld   a, (CALC_UNP_B+2)
    ld   c, a
    ld   a, (CALC_DIV_REM)
    sbc  a, c
    ld   (CALC_DIV_REM), a
    scf                                ; this iteration's quotient bit = 1
    jr   .cd_shift_quot
.cd_no_subtract:
    or   a                              ; clears carry -> quotient bit = 0
.cd_shift_quot:
    ld   a, (CALC_DIV_QUOT+3)
    rl   a
    ld   (CALC_DIV_QUOT+3), a
    ld   a, (CALC_DIV_QUOT+2)
    rl   a
    ld   (CALC_DIV_QUOT+2), a
    ld   a, (CALC_DIV_QUOT+1)
    rl   a
    ld   (CALC_DIV_QUOT+1), a
    ld   a, (CALC_DIV_QUOT)
    rl   a
    ld   (CALC_DIV_QUOT), a
    ; B (the 32-iteration counter) is never touched by anything above —
    ; same discipline as CALC_OP_MUL's own loop
    dec  b
    jp   nz, .cd_loop

    ld   a, (CALC_SHIFT_COUNT)
    ld   (CALC_UNP_A), a
    ld   a, (CALC_DIV_QUOT)
    ld   (CALC_UNP_A+2), a
    ld   a, (CALC_DIV_QUOT+1)
    ld   (CALC_UNP_A+3), a
    ld   a, (CALC_DIV_QUOT+2)
    ld   (CALC_UNP_A+4), a
    ld   a, (CALC_DIV_QUOT+3)
    ld   (CALC_UNP_A+5), a
    jr   .cd_pack
.cd_zero:
    xor  a
    ld   (CALC_UNP_A), a
    ld   (CALC_UNP_A+1), a
    ld   (CALC_UNP_A+2), a
    ld   (CALC_UNP_A+3), a
    ld   (CALC_UNP_A+4), a
    ld   (CALC_UNP_A+5), a
.cd_pack:
    ld   hl, CALC_UNP_A
    ld   de, (CALC_OP1_PTR)
    call CALC_PACK
    ld   a, (CALC_SP)
    dec  a
    ld   (CALC_SP), a
    jp   CALC_RE_ENTRY
.cd_divzero:
.cd_divzero_hang:
    jr   .cd_divzero_hang

; ============================================================================
; CALC_OP_UNIMPLEMENTED
; Default target for every CALC_TABLE entry that isn't CALC_OP_END_CALC
; yet. Hangs via jr-to-self — this project's own established idiom
; (EXROM_VERIFY_KTAB_MAGIC, rom/exrom_checker.asm), not the Z80 HALT
; opcode (an earlier version of this file used HALT; inconsistent with
; the project's own convention, fixed in this rework). Lesson 10: store
; the real value, don't guess.
;
; Records C (the table index actually used to reach here), not a
; reconstructed "literal byte value" — deliberate: A means different
; things depending which CALC_SCAN_ENT branch got here (the doubled
; literal on the $00-$3D path, but the PARAMETER on the multi-purpose
; ($80+) path, which overwrites A with `and $1F` after computing the
; index) — halving A back would silently misreport on that second path.
; C survives untouched from CALC_DISPATCH through to here on BOTH
; paths, so it's the only value that's always correct. index>>1 = the
; original literal for the $00-$3D path (recoverable by hand if needed
; when debugging); the multi-purpose path's index doesn't map back to
; a single literal byte at all (the parameter bits are lost by design,
; already saved separately in CALC_LITERAL_PARAM before dispatch), so
; recording the index directly is the only universally meaningful
; choice, not a simplification of a "should reconstruct the literal"
; ideal.
; In:  C = table index (byte offset into CALC_TABLE) that dispatched
;      here
; Out: never returns
; Destroys: AF
; ============================================================================
CALC_OP_UNIMPLEMENTED:
    ld   a, c
    ld   (CALC_UNIMPLEMENTED_LITERAL_FLAG), a
.hang_loop:
    jr   .hang_loop

; ============================================================================
; CALC_TABLE — 66 entries (indices $00-$41), 2 bytes each = 132 bytes,
; matching the real ROM's own CALCADDR table byte-for-byte in size and
; layout (confirmed against skoolkid.github.io/rom/asm/32D7.html and
; 335B.html's index-derivation logic — literal N -> index N for
; N=$00-$3D; $3E-$41 covers the real ROM's "multi-purpose" literals
; >=$80). Every index is CALC_OP_UNIMPLEMENTED except $38 (end-calc).
; ============================================================================
CALC_TABLE:
    ; $00-$07 -- $01=exchange, $02=delete, $03=subtract, $04=multiply,
    ; $05=division
    DW CALC_OP_UNIMPLEMENTED, CALC_OP_EXCHANGE, CALC_OP_DELETE, CALC_OP_SUB
    DW CALC_OP_MUL, CALC_OP_DIV, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED
    ; $08-$0F -- $0F=addition
    DW CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED
    DW CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_ADD
    ; $10-$17
    DW CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED
    DW CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED
    ; $18-$1F
    DW CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED
    DW CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED
    ; $20-$27
    DW CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED
    DW CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED
    ; $28-$2F
    DW CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED
    DW CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED
    ; $30-$37 -- $31=duplicate
    DW CALC_OP_UNIMPLEMENTED, CALC_OP_DUPLICATE, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED
    DW CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED
    ; $38-$3F — $38 = end-calc, the one real op so far
    DW CALC_OP_END_CALC, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED
    DW CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED
    ; $40-$41
    DW CALC_OP_UNIMPLEMENTED, CALC_OP_UNIMPLEMENTED
