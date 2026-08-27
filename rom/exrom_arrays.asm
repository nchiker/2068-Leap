; ============================================================================
; rom/exrom_arrays.asm — DIMN's body (2026-08-22)
;
; DIMN moved out to EXROM whole once a Home-resident first draft of
; multi-dimensional array support (2D DIM, 2D read/write, DIMN) landed
; well over Home ROM's own budget — same "cold statement, move it
; whole" pattern SAVE/LOAD/HELP/the editor/SPRITE/SOUND already used.
; That 2D support (DIM, read, write) was itself archived the same day
; — see docs/programmers_reference.md's "Multi-dimensional arrays
; (archived)" section — once actually measuring Home/EXROM's real
; deficits (rather than estimating) showed the win wasn't worth its
; own budget cost. DIMN alone survived the archival: still genuinely
; useful with only one dimension (DIMN(name) — no second "which
; dimension" argument left to ask for), and still cheap enough to stay
; EXROM-resident on its own without needing DIM alongside it.
;
; Array READ and WRITE stay Home-resident too (.do_array_read/
; BASIC_TRY_ARRAY_ASSIGNMENT, basic/basic.asm) — those run on every
; single array access, potentially inside a tight loop, so paging
; in/out on every one would be a real, avoidable cost; DIMN typically
; runs once per loop setup (a FOR loop's own TO bound is evaluated
; once at entry, not re-evaluated every iteration), so paging for it
; costs nothing that matters.
;
; BASIC_ARRAY_FIND itself stays Home-resident too (it's the one
; routine both the hot read/write path and this cold one need),
; reached from here via the one new KTAB entry this feature needed —
; every other Home call DIMN makes (BASIC_VALIDATE_VAR_LETTER, BASIC_
; SKIP_SPACES, BASIC_SET_PENDING_ERROR) already had one from earlier
; features.
; ============================================================================

; ============================================================================
; ARRAY_EXROM_DIMN ($C08A entry stub target)
; DIMN(name) — returns an array's declared size. Lets a procedure loop
; over an array without hardcoding its size, e.g. "FOR i = 0 TO
; DIMN(A)-1". Does its own full parse from EXPR_PARSE_PTR rather than
; receiving pre-parsed input — see EXROM_ENTRY_DIMN's own header (rom/
; exrom_checker.asm) for why.
; In:  none (reads EXPR_PARSE_PTR — positioned right after "DIMN(" by
;      the Home-side dispatch that calls in here)
; Out: carry clear + HL = result, EXPR_PARSE_PTR advanced past the
;      closing ")"; carry set + error already recorded otherwise
; Destroys: AF, BC, DE, HL
; ============================================================================
ARRAY_EXROM_DIMN:
    ld   hl, (EXPR_PARSE_PTR)
    ld   a, (hl)
    call KTAB_BASIC_VALIDATE_VAR_LETTER
    jp   c, .dimn_syntax_fail
    push af                              ; the array letter — survives
                                         ; the ")" check below
    inc  hl
    ld   c, ARRAY_KIND_NUM
    ld   a, (hl)
    cp   "$"
    jr   nz, .dimn_after_kind
    ld   c, ARRAY_KIND_STR
    inc  hl
.dimn_after_kind:
    push bc                              ; kind survives syntax checks
    call KTAB_BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   ")"
    jp   nz, .dimn_fail_pop
    inc  hl
    ld   (EXPR_PARSE_PTR), hl
    pop  bc                              ; C = requested array kind
    pop  af                              ; A = array letter (restored)

    ; BASIC_CHECK_ONLY-guarded, same reasoning basic.asm's own
    ; .do_array_read gives (real bug found and fixed here 2026-08-22:
    ; this guard was missing entirely at first — DIMN(A) called the
    ; real KTAB_BASIC_ARRAY_FIND lookup even during the static whole-
    ; program check pass, where A may genuinely not be DIM'd yet since
    ; DIM is just another statement, not necessarily executed before
    ; the one referencing it is checked — "ARRAY NOT DIMENSIONED" was
    ; being recorded as a real check failure for a program that ran
    ; fine). Grammar (the letter, the closing paren) is still fully
    ; validated above regardless of check mode; only the real lookup
    ; is skipped here.
    ld   b, a                            ; stash the letter past the
                                         ; BASIC_CHECK_ONLY read below
    ld   a, (BASIC_CHECK_ONLY)
    or   a
    jr   nz, .dimn_check_only

    ld   a, b
    call KTAB_BASIC_ARRAY_FIND            ; HL = data, DE = count;
                                         ; carry set if the name isn't
                                         ; DIM'd at all
    jp   c, .dimn_not_dimmed
    ex   de, hl                          ; HL = count — the result
    or   a
    ret

.dimn_check_only:
    ld   hl, 0
    or   a
    ret

.dimn_not_dimmed:
    ld   hl, MSG_ARRAY_NOT_DIMMED
    call KTAB_BASIC_SET_PENDING_ERROR
    scf
    ret
.dimn_fail_pop:
    pop  bc                              ; discard kind stash
    pop  af                              ; discard the letter stash
.dimn_syntax_fail:
    ld   hl, MSG_SYNTAX_ERROR
    call KTAB_BASIC_SET_PENDING_ERROR
    scf
    ret
