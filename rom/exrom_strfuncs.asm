; ============================================================================
; rom/exrom_strfuncs.asm — string function bodies (CHR$/STR$/UPPER$/
; LOWER$/LEFT$/RIGHT$/INKEY$/VAL)
;
; (FILL$ and INSTR were originally part of this set too — dropped
; 2026-08-22, along with their own named-scratch fields in include/
; sysvars.inc, to fit Home ROM's own budget; see basic/basic.asm's
; FUNC_ID_INSTR comment for the full reasoning. STR_FUNC_POOL's own
; 4-slot sizing predates that drop and was originally partly justified
; by INSTR's two-simultaneous-buffer need — it's kept at 4 regardless,
; since nested string-function calls like UPPER$(LEFT$(A$,3)) still
; want more than one slot alive at once.)
;
; All EXROM-resident — Home ROM was down to ~186 bytes free by the time
; this feature landed (Phase 3's own string/array work already spent
; most of it), so every byte of ACTUAL transform logic lives here.
; What stays Home-resident (basic/basic.asm) is only what genuinely
; can't move: argument PARSING (BASIC_EVAL_EXPR/BASIC_EVAL_STR_EXPR are
; themselves Home-resident, hot-path routines used everywhere, so
; anything that calls them has to run on that side of the boundary)
; and the two functions trivial enough (LEN, CODE) that an EXROM round
; trip would cost more than the routine itself.
;
; Single shared entry point (STRFUNC_EXROM, via EXROM_ENTRY_STRFUNC)
; dispatches internally by STR_FUNC_CALL_ID — cheaper than a stub per
; function and this project's already-established pattern (SOUND_EXROM,
; BASIC_STMT_SPRITE both do the same single-entry-point-then-internal-
; dispatch shape).
;
; Convention: Home has ALREADY parsed every argument by the time it
; calls in here — a string argument is a fully-formed [length][content]
; buffer (one of basic/'s STR_FUNC_POOL slots), a numeric argument is
; already in a register. This routine's only job is the actual
; transform, writing STRING results straight into (STR_FUNC_DEST) —
; the caller's real destination, wherever that is; writing there
; directly from EXROM is fine, paging only affects CODE fetches, not
; data reads/writes — and the NUMBER result (VAL) in DE instead.
;
; Shared shape: every copy-based function here (UPPER$/LOWER$/LEFT$/
; RIGHT$) precomputes the exact number of bytes it's about to write
; BEFORE looping, stashes that count across the DJNZ loop (which needs
; B as its own countdown) via a single push/pop, then restores it as
; the real "bytes written" return value once the loop ends.
; ============================================================================

; ============================================================================
; STRFUNC_EXROM
; In:  STR_FUNC_CALL_ID already set (basic/basic.asm's own scratch,
;      shared — this file just reads it, doesn't own it)
;      C = max bytes to write (budget) — only meaningful for the
;      string-returning IDs
;      Per-ID arguments:
;        CHR$/STR$            : DE = numeric argument
;        UPPER$/LOWER$/VAL     : HL = source string buffer
;        LEFT$/RIGHT$          : HL = source string buffer, DE =
;                                numeric argument
;        INKEY$                : no arguments
; Out: string-returning IDs: result written into (STR_FUNC_DEST), B =
;      bytes written, carry clear; carry set + error recorded on
;      failure (CHR$ argument out of 0-255 range is the only one)
;      VAL: DE = result value, carry clear (never fails — anything
;      unparseable is treated as 0, matching classic BASIC)
;      (FILL$/INSTR were here too originally — dropped 2026-08-22 to
;      fit Home ROM's own budget; see basic/basic.asm's FUNC_ID_INSTR
;      comment for the full reasoning)
; Destroys: AF, BC, DE, HL, IX
; ============================================================================
STRFUNC_EXROM:
    ld   a, (STR_FUNC_CALL_ID)
    cp   STRFUNC_ID_CHR
    jp   z, .f_chr
    cp   STRFUNC_ID_STR
    jp   z, .f_str
    cp   STRFUNC_ID_UPPER
    jp   z, .f_upper
    cp   STRFUNC_ID_LOWER
    jp   z, .f_lower
    cp   STRFUNC_ID_LEFT
    jp   z, .f_left
    cp   STRFUNC_ID_RIGHT
    jp   z, .f_right
    cp   STRFUNC_ID_INKEY
    jp   z, .f_inkey
    cp   STRFUNC_ID_VAL
    jp   z, .f_val
    scf                                  ; unreachable as long as the
    ret                                 ; table and this chain stay in
                                        ; sync

; ---- CHR$(n) — 1-byte string, the character with ASCII code n ----
.f_chr:
    ld   a, d
    or   a
    jr   nz, .chr_bad                    ; d<>0 -> n outside 0-255 in
                                         ; either direction (a negative
                                         ; two's-complement value has
                                         ; d<>0 too — e.g. -1 = $FFFF)
    ld   a, c
    or   a
    jr   z, .chr_no_room                  ; caller's budget is already 0
    ld   a, e
    ld   hl, (STR_FUNC_DEST)
    ld   (hl), a
    ld   b, 1
    or   a
    ret
.chr_no_room:
    ld   b, 0
    or   a
    ret
.chr_bad:
    ld   hl, MSG_INVALID_ARGUMENT
    call KTAB_BASIC_SET_PENDING_ERROR
    scf
    ret

; ---- STR$(n) — n formatted as a decimal string ----
.f_str:
    ld   a, c                            ; stash the caller's budget —
                                         ; BASIC_NUM_TO_STRING's own
                                         ; contract destroys BC, and the
                                         ; bare KTAB trampoline does no
                                         ; save/restore of its own (real
                                         ; bug found and fixed 2026-08-22:
                                         ; STR$(n) always returned "" —
                                         ; C landed on garbage before the
                                         ; copy loop's own "cp c" budget
                                         ; check ever ran)
    push af
    call BASIC_NUM_TO_STRING_EXROM          ; HL = null-terminated
                                          ; decimal string (in Home's
                                          ; PRINT_BUF)
    pop  af
    ld   c, a
    ld   de, (STR_FUNC_DEST)
    ld   b, 0
.str_loop:
    ld   a, (hl)
    or   a
    jr   z, .str_done
    ld   a, b
    cp   c
    jr   z, .str_done                     ; hit the caller's budget
    ld   a, (hl)
    ld   (de), a
    inc  hl
    inc  de
    inc  b
    jr   .str_loop
.str_done:
    or   a
    ret

; ---- UPPER$(s) — case-convert, byte for byte ----
.f_upper:
    ld   a, (hl)                           ; A = source length
    cp   c
    jr   c, .upper_len_ok
    ld   a, c                              ; clamp to the budget
.upper_len_ok:
    inc  hl                                ; HL = source content
    or   a
    jr   z, .upper_zero
    push af                                ; stash copy_len
    ld   b, a
    ld   de, (STR_FUNC_DEST)
.upper_loop:
    ld   a, (hl)
    cp   "a"
    jr   c, .upper_copy
    cp   "z" + 1
    jr   nc, .upper_copy
    sub  32
.upper_copy:
    ld   (de), a
    inc  hl
    inc  de
    djnz .upper_loop
    pop  af
    ld   b, a
    or   a
    ret
.upper_zero:
    ld   b, 0
    or   a
    ret

; ---- LOWER$(s) — case-convert, byte for byte ----
.f_lower:
    ld   a, (hl)
    cp   c
    jr   c, .lower_len_ok
    ld   a, c
.lower_len_ok:
    inc  hl
    or   a
    jr   z, .lower_zero
    push af
    ld   b, a
    ld   de, (STR_FUNC_DEST)
.lower_loop:
    ld   a, (hl)
    cp   "A"
    jr   c, .lower_copy
    cp   "Z" + 1
    jr   nc, .lower_copy
    add  a, 32
.lower_copy:
    ld   (de), a
    inc  hl
    inc  de
    djnz .lower_loop
    pop  af
    ld   b, a
    or   a
    ret
.lower_zero:
    ld   b, 0
    or   a
    ret

; ---- LEFT$(s,n) — first n characters of s ----
.f_left:
    ld   a, (hl)                           ; A = source length
    inc  hl                                ; HL = source content
    ld   b, a                              ; B = source length (temp)
    ld   a, d
    bit  7, a
    jr   nz, .left_n_neg                   ; n < 0 -> copy_len = 0
    or   a
    jr   nz, .left_use_srclen              ; d<>0, n>=0 -> n>=256,
                                          ; definitely > any real
                                          ; source length (max 31)
    ld   a, e
    cp   b
    jr   nc, .left_use_srclen              ; n >= source length -> take
                                          ; the whole thing
    ld   b, a                              ; n < source length -> use n
    jr   .left_have_len
.left_n_neg:
    ld   b, 0
    jr   .left_have_len
.left_use_srclen:
    ; B already holds source length
.left_have_len:
    ld   a, b
    cp   c
    jr   c, .left_len_ok
    ld   a, c                              ; clamp to the budget too
.left_len_ok:
    or   a
    jr   z, .left_zero
    push af
    ld   b, a
    ld   de, (STR_FUNC_DEST)
.left_loop:
    ld   a, (hl)
    ld   (de), a
    inc  hl
    inc  de
    djnz .left_loop
    pop  af
    ld   b, a
    or   a
    ret
.left_zero:
    ld   b, 0
    or   a
    ret

; ---- RIGHT$(s,n) — last n characters of s ----
.f_right:
    ld   a, (hl)                           ; A = source length
    ld   b, a                              ; B = source length (temp)
    ld   a, d
    bit  7, a
    jr   nz, .right_n_neg
    or   a
    jr   nz, .right_use_srclen
    ld   a, e
    cp   b
    jr   nc, .right_use_srclen
    ld   b, a
    jr   .right_have_len
.right_n_neg:
    ld   b, 0
    jr   .right_have_len
.right_use_srclen:
.right_have_len:
    ld   a, b
    cp   c
    jr   c, .right_len_ok
    ld   a, c
.right_len_ok:
    or   a
    jr   z, .right_zero
    ; source content start = HL+1; copy starts at offset
    ; (source_length - copy_len) within the content — HL still points
    ; at the original length byte here (never advanced yet), so
    ; re-reading it below is safe
    push af                                ; stash copy_len
    ld   b, a                               ; B = copy_len
    ld   a, (hl)                            ; A = source_length again
    sub  b                                  ; A = start offset
    inc  hl                                 ; HL = source content start
    ld   e, a
    ld   d, 0
    add  hl, de                             ; HL = source content +
                                           ; start offset
    ld   de, (STR_FUNC_DEST)
.right_loop:
    ld   a, (hl)
    ld   (de), a
    inc  hl
    inc  de
    djnz .right_loop
    pop  af
    ld   b, a
    or   a
    ret
.right_zero:
    ld   b, 0
    or   a
    ret

; ---- INKEY$() — one keypress, as a 0-or-1-character string ----
.f_inkey:
    call KTAB_IO_READ_KEY_NONBLOCK          ; A = ASCII code, or 0 if
                                           ; nothing currently pressed
    or   a
    jr   z, .inkey_empty
    ld   b, a                               ; B = character (temp)
    ld   a, c
    or   a
    jr   z, .inkey_empty                    ; caller's budget is 0
    ld   hl, (STR_FUNC_DEST)
    ld   (hl), b
    ld   b, 1
    or   a
    ret
.inkey_empty:
    ld   b, 0
    or   a
    ret

; ---- VAL(s) — parse s's content as a signed decimal integer ----
; Tolerant, not strict: stops at the first non-digit (or end of
; string) and returns whatever was parsed so far, same "parse what you
; can" spirit real classic BASIC's VAL has. An empty string, or one
; starting with a non-digit/non-minus character, returns 0.
.f_val:
    ld   a, (hl)                            ; A = source length
    ld   b, a
    inc  hl                                 ; HL = source content
    push hl
    pop  ix                                 ; IX = source content
                                           ; pointer — kept separate
                                           ; from HL so HL is free to
                                           ; use as arithmetic scratch
                                           ; in the digit loop below
    ld   de, 0                              ; DE = accumulator
    ld   c, 0                               ; C = sign flag
    ld   a, b
    or   a
    jr   z, .val_done
    ld   a, (ix+0)
    cp   "-"
    jr   nz, .val_loop
    ld   c, 1
    inc  ix
    dec  b
.val_loop:
    ld   a, b
    or   a
    jr   z, .val_sign
    ld   a, (ix+0)
    cp   "0"
    jr   c, .val_sign
    cp   "9" + 1
    jr   nc, .val_sign
    sub  "0"                                 ; A = digit value 0-9
    push af                                  ; stash digit
    ex   de, hl                              ; HL = old accumulator
    add  hl, hl                              ; x2
    push hl                                  ; stash old_acc*2
    add  hl, hl                              ; x4
    add  hl, hl                              ; x8
    pop  de                                  ; DE = old_acc*2
    add  hl, de                              ; HL = old_acc*8 +
                                            ; old_acc*2 = old_acc*10
    pop  af                                  ; A = digit
    ld   e, a
    ld   d, 0
    add  hl, de                              ; HL = old_acc*10 + digit
    ex   de, hl                              ; DE = new accumulator
    inc  ix
    dec  b
    jr   .val_loop
.val_sign:
    ld   a, c
    or   a
    jr   z, .val_done
    ld   a, d
    cpl
    ld   d, a
    ld   a, e
    cpl
    ld   e, a
    inc  de
.val_done:
    or   a
    ret
; FILL$/INSTR were here too originally — dropped 2026-08-22 to fit Home
; ROM's own budget; see basic/basic.asm's FUNC_ID_INSTR comment for the
; full reasoning.
