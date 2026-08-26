; ============================================================================
; kernel/bank/bank.asm — EXROM paging trampoline
;
; HARDWARE-CONFIRMED (2026-08-18, isolation test run #2: PASS/PASS on
; real hardware/Fuse — see rom/test_exrom_isolation.asm's own header
; and this project's own working memory for the full writeup). This
; was the first bank-switching code in the project; it's now proven,
; not just designed — treat rom/test_exrom_isolation.asm's confirmed
; result as the actual proof, not this file's own doc comments.
;
; WHY THIS EXISTS: Home bank is hard-capped at 16K — see the ROM-size
; crisis writeup in this project's own working memory. EXROM gives 8K
; more, paged into chunk 6 ($C000-$DFFF) only — see docs/memory_map.md
; for the full chunk-by-chunk audit (why chunk 6 specifically: general
; RAM, distant from live sysvar state and the stack, independently
; corroborated by the stock ROM's own EXTINIT marking that chunk
; expendable too). That audit, and the interrupt-safety reasoning
; behind this file's DI/EI placement, are sourced against the real
; Timex Sinclair 2068 ROM Disassembly (David Anderson, 2023), not
; guessed — see docs/memory_map.md for the citations.
;
; INTERRUPT SAFETY — the one thing this file gets right or wrong for
; everything built on top of it: interrupts are disabled ONLY across
; the two port writes that actually change the paging state (a few
; instructions), never across the caller's subsequent use of the
; paged window. Holding DI for the whole window would reintroduce
; exactly the keyboard-lag problem this project already fixed once
; (see kernel/interrupt's own history) for anything nontrivial running
; from EXROM. It's safe to re-enable immediately because this
; project's real interrupt handler, KBD_ISR_TICK, never touches chunk
; 6 — its own sysvars all live in chunk 4, which stays Home-mapped
; the entire time chunk 6 is paged to EXROM. If kernel/interrupt ever
; grows a handler that DOES need chunk-6 data, this reasoning needs
; re-deriving, not assumed to still hold.
;
; EXROM's own entry convention: execution starts at the very first
; byte of the 8K image (i.e. $C000 once paged in), same as a ROM's own
; reset vector. Only one entry point is needed for now (this
; project's first EXROM payload is a deliberately trivial isolation
; test — see rom/exrom_payload.asm); a future payload needing
; multiple distinct entry points would extend this via its own
; internal dispatch (e.g. a selector passed in a register before the
; call), not by changing these paging primitives.
; ============================================================================

    IFNDEF KERNEL_BANK_ASM
    DEFINE KERNEL_BANK_ASM

; ============================================================================
; BANK_PAGE_EXROM_IN
; Pages chunk 6 ($C000-$DFFF) to EXROM. Every other chunk stays Home.
; See this file's own header for the DI/EI reasoning — interrupts are
; back on before this returns.
; In:  none
; Out: none
; Destroys: AF
; ============================================================================
; Nesting-safe via BANK_EXROM_DEPTH (include/sysvars.inc — see that
; sysvar's own comment for the full bug story this fixes, 2026-08-22):
; the real port writes only happen on the 0->1 depth transition — a
; call made while chunk 6 is ALREADY paged to EXROM (i.e. from code
; that's itself running as a nested call from within EXROM) just bumps
; the counter and leaves the paging alone. The single, non-nested case
; every caller before this fix used — page in, do one thing, page
; out — is completely unchanged: depth goes 0->1 here (real page-in
; happens) and 1->0 in BANK_PAGE_EXROM_OUT (real page-out happens).
BANK_PAGE_EXROM_IN:
    di
    ld   a, (BANK_EXROM_DEPTH)
    inc  a
    ld   (BANK_EXROM_DEPTH), a
    cp   1
    jr   nz, .already_paged_in       ; depth was already >=1 — chunk 6
                                     ; is already EXROM (an outer,
                                     ; still-active caller put it
                                     ; there) — nothing to do
    ld   a, (PORT_FF_SHADOW)
    or   %10000000                   ; bit 7 only — EXROM, not Dock;
                                     ; bits 0-6 (video mode, INTEN) are
                                     ; not this routine's to touch —
                                     ; same shadow-preserving discipline
                                     ; GFX_SET_MODE already established
    ld   (PORT_FF_SHADOW), a
    out  (PORT_SCLD), a

    ld   a, %01000000                ; bit 6 = chunk 6 only; every
                                     ; other chunk's bit stays 0 (Home)
    out  (PORT_BANK_HOME), a
.already_paged_in:
    ei
    ret

; ============================================================================
; BANK_PAGE_EXROM_OUT
; Restores chunk 6 to Home — but only once BANK_EXROM_DEPTH's nesting
; counter (see BANK_PAGE_EXROM_IN just above, and that sysvar's own
; comment) actually reaches back to 0; a nested call just decrements it
; and leaves chunk 6 paged to EXROM for whichever outer caller is still
; using it. PORT_SCLD's bit 7 is deliberately left exactly as BANK_
; PAGE_EXROM_IN set it, not cleared — once PORT_BANK_HOME selects Home
; for every chunk, bit 7 is moot (nothing reads EXROM/Dock for any
; chunk any more), so touching it here would only be an unneeded extra
; read-modify-write through PORT_FF_SHADOW for no observable effect.
; In:  none
; Out: none
; Destroys: AF
; ============================================================================
BANK_PAGE_EXROM_OUT:
    di
    ld   a, (BANK_EXROM_DEPTH)
    or   a
    jr   z, .depth_already_zero       ; defensive: an unbalanced OUT
                                      ; with no matching IN — nothing
                                      ; to unpage, don't underflow the
                                      ; counter
    dec  a
    ld   (BANK_EXROM_DEPTH), a
    jr   nz, .still_nested             ; still >=1 after decrementing —
                                       ; an outer caller is still
                                       ; relying on chunk 6 staying
                                       ; EXROM-mapped
    xor  a
    out  (PORT_BANK_HOME), a         ; all chunks back to Home
.still_nested:
.depth_already_zero:
    ei
    ret

; ============================================================================
; BANK_CALL_EXROM
; Convenience wrapper: pages chunk 6 in, calls its fixed entry point
; ($C000), pages back out. The EXROM payload itself runs with
; interrupts enabled throughout — see this file's header.
; In:  none
; Out: whatever the EXROM payload's own contract defines
; Destroys: whatever the EXROM payload's own contract defines, plus AF
; ============================================================================
BANK_CALL_EXROM:
    call BANK_PAGE_EXROM_IN
    call $C000
    jr BANK_PAGE_EXROM_OUT

    ENDIF
