; ============================================================================
; rom/exrom_checker.asm — whole-program checker, migrated to EXROM
;
; CONFIRMED WORKING ON REAL HARDWARE (2026-08-19) — build order step
; (3), the first real subsystem migrated onto the EXROM trampoline
; (kernel/bank/bank.asm, itself hardware-confirmed PASS/PASS earlier).
; Live-typing validation (`x = 1c` / `INK 1c` showing red WHILE
; TYPING) confirmed the checker runs correctly through EXROM paging.
;
; WHAT MOVED HERE (cut verbatim from basic/basic.asm, not rewritten):
; BASIC_SCAN_LABELS, BASIC_CHECK_ASSIGNMENT, BASIC_CHECK_STATEMENT,
; BASIC_CHECK_STATEMENT_CONTENT, BASIC_CHECK_MULTI_STATEMENT, and
; BASIC_CHECK_PROGRAM — the whole-program label scan and the
; per-statement grammar checker it depends on. This is the actual
; code-weight win (the per-statement checker is a long, repetitive
; per-keyword grammar validator — see BASIC_CHECK_STATEMENT_CONTENT's
; own header in this file for why it can't easily be table-driven).
; This resolved the project's 233-byte Home ROM overage (see
; "ROM-SIZE CRISIS" in working memory) with room to spare — confirmed
; real counts, post-migration: Home 14660/16384 used (1724 free),
; EXROM 2457/8192 used (5735 free).
;
; WHY THIS CODE LIVES AT $C000-$DFFF: chunk 6 is only EXROM-mapped
; while kernel/bank/bank.asm's BANK_PAGE_EXROM_IN is active, so
; anything here must physically assemble into that 8K window, not
; inside Home's own INCLUDE tree. This file is now one INGREDIENT of
; that image, not the whole thing — see rom/exrom_build.asm (the real
; driver: DEVICE/ORG/SAVEBIN) and rom/exrom_storage.asm (SAVE/LOAD,
; the other subsystem sharing this same image, added 2026-08-19).
;
; HOW THIS CALLS BACK INTO HOME: every call this file makes to a
; routine that still lives in Home (MEM_LINE_FIRST, BASIC_PARSE_
; IDENTIFIER, BASIC_EVAL_EXPR, etc. — kernel/memory and the rest of
; basic.asm never move) goes through the fixed jump table in include/
; exrom_jumptable.inc (KTAB_*), NOT a direct call to the real label.
; A direct call would silently break the next time basic.asm is
; edited and every downstream address shifts, since this file has no
; way to see that shift (it's a separate compilation unit with no
; real linker between the two). See exrom_jumptable.inc's own header
; for the full reasoning and the Home-side table this depends on.
; Calls between routines that moved here TOGETHER (BASIC_CHECK_
; ASSIGNMENT, BASIC_CHECK_STATEMENT, BASIC_CHECK_STATEMENT_CONTENT
; calling each other) are untouched, real, direct calls — they're all
; in this same compilation unit now, same as they were in basic.asm.
;
; TWELVE FIXED ENTRY POINTS, six bytes apart (2026-08-18: widened from
; three when EXROM_VERIFY_KTAB_MAGIC's own consistency check was
; added — every entry now runs that check before the real jump, not
; just a bare `jp`; 2026-08-19: widened again from three to five when
; SAVE/LOAD's own migration — rom/exrom_storage.asm — landed in this
; same image and needed two entries of its own, then again from five
; to six when HELP's own migration — rom/exrom_help.asm — added a
; sixth; 2026-08-20: widened again from six to seven when the
; calculator engine's own migration — rom/exrom_calc.asm —
; added a seventh, $C024, EXROM_ENTRY_CALCULATE; 2026-08-21: widened
; again from seven to nine when BASIC's own "/" operator was wired
; through the calculator engine — CALC_INT_TO_FP/CALC_FP_TO_INT needed
; entries of their own, $C02A and $C030, since neither is a CALC_TABLE
; literal reachable via the existing $C024 RST $28 dispatch; 2026-08-22:
; widened again from nine to eleven for SQR/SIN's "function-result
; float" wiring — CALC_PUSH_PI ($C036) and the generic CALC_PUSH_FP_RAW
; ($C03C), neither a CALC_TABLE literal either, same reasoning as
; $C02A/$C030; 2026-08-22: widened again from eleven to twelve for
; BASIC_FORMAT_STORAGE_STATUS's own EXROM migration ($C042) — a ROM-
; size audit candidate (see rom/exrom_storage.asm's own new content),
; same
; "selector before the call" pattern kernel/bank/bank.asm's
; own header anticipated for a future payload needing more than one
; entry — chosen because Home callers need different behaviors (see
; basic/basic.asm's own BASIC_SCAN_LABELS_EXROM / BASIC_FULL_CHECK_
; EXROM / BASIC_CHECK_STATEMENT_EXROM / BASIC_SAVE_EXROM / BASIC_LOAD_
; EXROM / BASIC_SHOW_HELP_EXROM wrapper comments for which callers
; need which):
;   $C000 — EXROM_ENTRY_SCAN_LABELS: label table rebuild only
;   $C006 — EXROM_ENTRY_FULL_CHECK: label rebuild + full syntax check
;           (the label rebuild must run first — GOTO validation inside
;           the checker needs the table already populated, same
;           ordering the original two-call Home site always used)
;   $C00C — EXROM_ENTRY_CHECK_STATEMENT_ONLY: single-statement re-
;           check, no label rebuild — used by BASIC_DRAW_STATUS_LINE
;           to redraw the cursor line's own error message. THIS WAS A
;           HOT PATH (every status-line redraw during normal editing,
;           not just RUN/EDIT/LOAD) until BASIC_DRAW_STATUS_LINE grew
;           its own caller-side cache — see that routine's own
;           comments; still flagged for extra hardware-timing scrutiny
;           since it's the only one of the three reachable from a
;           tight interactive loop at all, same class of concern this
;   $C012 — EXROM_ENTRY_SAVE: STORAGE_SAVE, bare trampoline
;   $C018 — EXROM_ENTRY_LOAD: STORAGE_LOAD, bare trampoline. Both of
;           these run with interrupts already off for their entire
;           duration (STORAGE_SAVE/LOAD's own internal `di`, `ei` left
;           to the Home caller after return — see kernel/storage/
;           storage.asm's own header) — unlike the three above, there
;           is no interrupt-during-paging question to worry about here
;           at all, since nothing fires while either is running.
;   $C01E — EXROM_ENTRY_HELP: BASIC_SHOW_HELP, bare trampoline — only
;           ever called from the editor's HELP dispatch (see basic/
;           basic.asm's `.is_help`), never from a running program or
;           any interactive hot path, so no timing scrutiny needed the
;           way $C00C's got.
;   $C024 — EXROM_ENTRY_CALCULATE: CALC_EXROM_ENTRY (rom/exrom_calc.
;           asm), bare trampoline — UNLIKE the six above, reached via
;           `jp` from basic/basic.asm's CALC_ENTRY_TRAMPOLINE, never
;           `call` (RST $28's return address has to survive untouched
;           on the stack — see that trampoline's own header for why).
;   $C02A — EXROM_ENTRY_CALC_INT_TO_FP: CALC_INT_TO_FP, bare
;           trampoline — pushes a signed 16-bit int (HL) onto
;           CALC_STACK as a float. Not a CALC_TABLE literal, so it
;           needed its own entry rather than going through $C024.
;   $C030 — EXROM_ENTRY_CALC_FP_TO_INT: CALC_FP_TO_INT, bare
;           trampoline — pops the top of CALC_STACK, converts to a
;           signed 16-bit int (HL), truncating toward zero. Same
;           reasoning as $C02A above.
;   $C036 — EXROM_ENTRY_CALC_PUSH_PI: CALC_PUSH_PI, bare trampoline —
;           pushes the constant pi. SIN's degrees->radians conversion
;           needs it; CALC_INT_TO_FP only handles plain ints.
;   $C03C — EXROM_ENTRY_CALC_PUSH_FP_RAW: CALC_PUSH_FP_RAW, bare
;           trampoline — pushes an arbitrary already-packed 5-byte
;           float (HL = Home-resident pointer, e.g. basic.asm's
;           FUNC_RESULT_FLOAT). Generic where CALC_PUSH_PI is a fixed
;           constant, for the opposite direction (feeding a value BACK
;           into the calculator to print it) — see basic.asm's
;           BASIC_FLOAT_TO_STRING.
;   $C042 — EXROM_ENTRY_FORMAT_STORAGE_STATUS: BASIC_FORMAT_STORAGE_
;           STATUS (rom/exrom_storage.asm), bare trampoline — builds
;           the SAVE/LOAD status-bar text. Cold path: only ever called
;           while STORAGE_OP_STATE is nonzero, i.e. during or just
;           after an actual SAVE/LOAD (see basic/basic.asm's BASIC_
;           DRAW_STATUS_LINE, which gates every call to it behind that
;           check) — NOT on every status-line redraw the way $C00C
;           used to be, so no interactive-hot-path scrutiny needed.
;           Reentrancy note: this CAN run nested inside an already-
;           paged-in EXROM call — STORAGE_SAVE/STORAGE_LOAD (also
;           EXROM-resident) call it repeatedly mid-transfer via
;           STORAGE_PROGRESS_HOOK, itself set to Home's BASIC_DRAW_
;           STATUS_LINE (never paged — see rom/exrom_storage.asm's own
;           header) — which is exactly why kernel/bank/bank.asm's
;           BANK_PAGE_EXROM_IN/_OUT needed to become nesting-safe
;           (BANK_EXROM_DEPTH) before this move was safe to make.
;   $C048 — EXROM_ENTRY_SOUND: SOUND_EXROM (rom/exrom_sound.asm), bare
;           trampoline — BEEP's own EXROM_ENTRY-less kernel/sound
;           module was Home-resident (small enough), but SOUND's real
;           body (register-range validation + two OUT instructions)
;           was pushed to EXROM instead purely for Home ROM budget —
;           see kernel/sound/sound.asm's own header for the reasoning.
;   $C054 — EXROM_ENTRY_SPRITE: BASIC_STMT_SPRITE (rom/exrom_sprite.
;           asm), bare trampoline — SPRITE GRAB/SHOW/HIDE's entire
;           587-byte family moved here whole in a ROM-shrink pass
;           (2026-08-22), once Phase 3's string work left only 159
;           Home ROM bytes free — see that file's own header.
;   $C05A — EXROM_ENTRY_STRFUNC: STRFUNC_EXROM (rom/exrom_strfuncs.
;           asm), bare trampoline — the single shared entry point for
;           all eight string-returning functions (CHR$/STR$/UPPER$/
;           LOWER$/LEFT$/RIGHT$/INKEY$/VAL — FILL$/INSTR were dropped
;           2026-08-22 to fit Home ROM's own budget), dispatching
;           internally by STR_FUNC_CALL_ID rather than needing a stub
;           each.
;   $C060 — EXROM_ENTRY_EDITOR_INIT: EDITOR_INIT (rom/exrom_editor.
;           asm), bare trampoline.
;   $C066 — EXROM_ENTRY_EDITOR_ENTER: EDITOR_ENTER, bare trampoline —
;           runs the whole interactive edit session before returning.
;   $C06C — EXROM_ENTRY_EDITOR_WRAP_CALC: EDITOR_WRAP_CALC, bare
;           trampoline.
;   $C072 — EXROM_ENTRY_EDITOR_WRAP_TABLE_ADDR: EDITOR_WRAP_TABLE_ADDR,
;           bare trampoline.
;   $C078 — EXROM_ENTRY_EDITOR_WRAP_OFFSET_TO_ROWCOL: EDITOR_WRAP_
;           OFFSET_TO_ROWCOL, bare trampoline.
;   $C07E — EXROM_ENTRY_EDITOR_WRAP_ROWCOL_TO_OFFSET: EDITOR_WRAP_
;           ROWCOL_TO_OFFSET, bare trampoline.
;   $C084 — EXROM_ENTRY_EDITOR_BLOCK_DELETE: EDITOR_BLOCK_DELETE, bare
;           trampoline. These seven (2026-08-22) are kernel/editor's
;           own ROM-shrink migration — the full-screen editor moved
;           here whole once the string-functions feature alone still
;           left Home ROM hundreds of bytes over budget; see rom/
;           exrom_editor.asm's own header.
; All twenty-five (as of the DIMN/multi-keyword-highlighting/sprite-HIT
; additions, 2026-08-22/23) are tiny fixed-size stubs at FIXED offsets
; so Home's
; callers have a stable target regardless of how the real routine
; bodies below are ordered or how big they are.
;
; RESTRUCTURED (2026-08-19): this file is no longer assembled on its
; own. SAVE/LOAD's own EXROM migration (rom/exrom_storage.asm) has to
; land in the SAME 8K image as this checker — there's only one real
; rom1.bin, not a swappable second EXROM bank — so the DEVICE/ORG/
; INCLUDEs-of-hardware-sysvars-jumptable/SAVEBIN this file used to
; open and close with now live in rom/exrom_build.asm, the actual
; top-level driver. This file is INCLUDEd from there and contributes
; pure content: the entry-stub block below (now eleven stubs, grown
; from the original three — see the SAVE/LOAD, HELP, CALCULATE, and
; CALC_INT_TO_FP/CALC_FP_TO_INT entries added since) plus everything
; from EXROM_VERIFY_KTAB_MAGIC onward. Build: sjasmplus rom/
; exrom_build.asm.
; ============================================================================

; ---- twenty-five fixed entry stubs, six bytes apart (call EXROM_VERIFY_
; KTAB_MAGIC + jp <target>) so Home's callers have stable targets
; regardless of how the real routine bodies are ordered or sized —
; see EXROM_VERIFY_KTAB_MAGIC's own header for what the magic check
; guards against and why every entry runs it first. Widened from the
; original 3-byte-apart layout (which only had room for a bare `jp`)
; when this check was added. ----
EXROM_ENTRY_SCAN_LABELS:
    call EXROM_VERIFY_KTAB_MAGIC
    jp   BASIC_SCAN_LABELS

    ORG $C006
EXROM_ENTRY_FULL_CHECK:
    call EXROM_VERIFY_KTAB_MAGIC
    jp   EXROM_FULL_CHECK_IMPL

    ORG $C00C
EXROM_ENTRY_CHECK_STATEMENT_ONLY:
    ; In: HL = pointer to the statement's length prefix (same contract
    ; BASIC_CHECK_STATEMENT's own header documents) — this trampoline
    ; and the Home-side wrapper that calls it (BASIC_CHECK_STATEMENT_
    ; EXROM) both leave HL untouched, so it passes straight through.
    ; This entry exists because BASIC_DRAW_STATUS_LINE calls BASIC_
    ; CHECK_STATEMENT directly to redraw the cursor line's own error
    ; message — a HOT PATH (every status-line redraw during normal
    ; editing, not just RUN/EDIT/LOAD), unlike this file's other two
    ; entries; BASIC_DRAW_STATUS_LINE's own caller-side cache now skips
    ; this entire call except when the cursor lands on a genuinely new
    ; flagged statement — see that routine's own comments. Flagged for
    ; extra hardware-timing scrutiny once this is actually tested —
    ; same class of concern this project's own build order already
    ; raised about SAVE/LOAD's interrupt timing.
    call EXROM_VERIFY_KTAB_MAGIC
    jp   BASIC_CHECK_STATEMENT

    ORG $C012
EXROM_ENTRY_SAVE:
    ; In/Out/Destroys: identical to STORAGE_SAVE's own contract (see
    ; kernel/storage/storage.asm) — this is a bare trampoline, no
    ; argument massaging needed. HL = data pointer, DE = length in,
    ; same as STORAGE_SAVE always took; carry-set-on-too-large is
    ; STORAGE_SAVE's own result, untouched by this stub.
    call EXROM_VERIFY_KTAB_MAGIC
    jp   STORAGE_SAVE

    ORG $C018
EXROM_ENTRY_LOAD:
    ; In/Out/Destroys: identical to STORAGE_LOAD's own contract — IX/
    ; HL/B in, DE (actual length)/A (blocks lost)/carry (failure) out,
    ; untouched by this stub. See basic.asm's BASIC_LOAD_EXROM for why
    ; ALL THREE of those outputs need protecting across the page-out
    ; step on the Home side (this stub itself doesn't touch them).
    call EXROM_VERIFY_KTAB_MAGIC
    jp   STORAGE_LOAD

    ORG $C01E
EXROM_ENTRY_HELP:
    ; In/Out/Destroys: identical to BASIC_SHOW_HELP's own original
    ; contract (HL = topic-name text pointer in, Destroys: AF, BC, DE,
    ; HL, no meaningful output) — bare trampoline, same shape as the
    ; three checker entries above and unlike SAVE/LOAD's, needs no
    ; argument massaging.
    call EXROM_VERIFY_KTAB_MAGIC
    jp   BASIC_SHOW_HELP

    ORG $C024
EXROM_ENTRY_CALCULATE:
    ; Bare trampoline into CALC_EXROM_ENTRY (rom/exrom_calc.asm) — same
    ; shape as EXROM_ENTRY_HELP above, EXCEPT this one's caller (basic/
    ; basic.asm's CALC_ENTRY_TRAMPOLINE) reaches it via `jp`, never
    ; `call` — see that trampoline's own header for why. This `call
    ; EXROM_VERIFY_KTAB_MAGIC` is still safe despite that: it's a
    ; genuine call/ret pair that's fully resolved (net stack-neutral)
    ; before the `jp` below fires, so it doesn't disturb the literal-
    ; pointer address sitting one level deeper on the stack, underneath
    ; where this call's own return address briefly lives.
    call EXROM_VERIFY_KTAB_MAGIC
    jp   CALC_EXROM_ENTRY

    ORG $C02A
EXROM_ENTRY_CALC_INT_TO_FP:
    ; Bare trampoline into CALC_INT_TO_FP (rom/exrom_calc.asm) — same
    ; shape as EXROM_ENTRY_HELP above. Added 2026-08-21 alongside the
    ; next entry when BASIC's own "/" operator was wired to compute
    ; through the calculator engine instead of kernel/math's
    ; MATH_DIVIDE16 (see basic/basic.asm's BASIC_EVAL_TERM, .divide_ok)
    ; — CALC_INT_TO_FP/CALC_FP_TO_INT aren't CALC_TABLE literals (no
    ; RST $28 dispatch reaches them), so unlike CALC_OP_ADD/SUB/MUL/DIV
    ; they had no way to be called from Home at all until now.
    ; In/Out/Destroys: identical to CALC_INT_TO_FP's own contract (HL =
    ; signed int in; Destroys: AF, BC, DE, HL; no meaningful output
    ; register — CALC_SP/CALC_STACK are the real result) — bare
    ; trampoline, no argument massaging needed.
    call EXROM_VERIFY_KTAB_MAGIC
    jp   CALC_INT_TO_FP

    ORG $C030
EXROM_ENTRY_CALC_FP_TO_INT:
    ; Bare trampoline into CALC_FP_TO_INT — same reasoning as the entry
    ; just above. HL is this routine's real output (the converted int),
    ; and BANK_PAGE_EXROM_OUT only ever destroys AF (see its own
    ; header), so a plain tail-jump on the Home side is enough to get
    ; it back safely — no BASIC_EXROM_EXIT_PROTECTED-style flag
    ; protection needed, unlike BASIC_CHECK_STATEMENT_EXROM's carry
    ; result.
    ; In/Out/Destroys: identical to CALC_FP_TO_INT's own contract
    ; (Destroys: AF, BC, DE, HL; Out: HL = converted int,
    ; CALC_TRUNC_FLAG set on overflow).
    call EXROM_VERIFY_KTAB_MAGIC
    jp   CALC_FP_TO_INT

    ORG $C036
EXROM_ENTRY_CALC_PUSH_PI:
    ; Bare trampoline into CALC_PUSH_PI (rom/exrom_calc.asm). Added
    ; 2026-08-22 alongside the next entry, for SIN's degrees->radians
    ; conversion (needs pi on CALC_STACK; CALC_INT_TO_FP can only push
    ; plain ints).
    ; In: none. Out/Destroys: identical to CALC_PUSH_FP_RAW's own
    ; contract (Destroys: AF, BC, DE, HL; CALC_SP incremented by 1).
    call EXROM_VERIFY_KTAB_MAGIC
    jp   CALC_PUSH_PI

    ORG $C03C
EXROM_ENTRY_CALC_PUSH_FP_RAW:
    ; Bare trampoline into CALC_PUSH_FP_RAW — same reasoning as the
    ; entry just above, but generic: HL (a Home-resident RAM pointer to
    ; a 5-byte packed float — e.g. basic.asm's FUNC_RESULT_FLOAT) is
    ; passed straight through, untouched by this stub or by
    ; BANK_PAGE_EXROM_IN/OUT, same as CALC_INT_TO_FP_HOME's own HL
    ; argument.
    ; In:  HL = pointer to a 5-byte packed float.
    ; Out/Destroys: identical to CALC_PUSH_FP_RAW's own contract.
    call EXROM_VERIFY_KTAB_MAGIC
    jp   CALC_PUSH_FP_RAW

    ORG $C042
EXROM_ENTRY_FORMAT_STORAGE_STATUS:
    ; Bare trampoline into BASIC_FORMAT_STORAGE_STATUS (rom/exrom_
    ; storage.asm — new content there, not part of the wholesale
    ; kernel/storage/storage.asm INCLUDE that file otherwise is). See
    ; this file's own entry-point doc block above for the reentrancy
    ; note (STORAGE_SAVE/LOAD can call this nested, via STORAGE_
    ; PROGRESS_HOOK, while already running from a paged-in EXROM call).
    ; In: none. Out: STATUS_BUF filled and null-terminated (memory,
    ; survives regardless). Destroys: AF, BC, DE, HL.
    call EXROM_VERIFY_KTAB_MAGIC
    jp   BASIC_FORMAT_STORAGE_STATUS

    ORG $C048
EXROM_ENTRY_SOUND:
    ; Bare trampoline into SOUND_EXROM (rom/exrom_sound.asm, new
    ; content — this file's own INCLUDE below pulls it in) — same
    ; shape as EXROM_ENTRY_HELP above. No BASIC_EXROM_EXIT_PROTECTED-
    ; style flag protection needed on the Home side beyond the plain
    ; carry-preserving `push af / call BANK_PAGE_EXROM_OUT / pop af`
    ; every other carry-returning wrapper already uses — SOUND_EXROM's
    ; only output is that carry flag (register out of range), no
    ; message text set from EXROM: this project's established pattern
    ; (see BASIC_DO_LOAD's own MSG_LOAD_FAILED) is that RUNTIME error
    ; messages must be Home-resident strings set AFTER paging back out,
    ; never an EXROM-resident PENDING_ERROR_MSG pointer left to be
    ; dereferenced once EXROM is unpaged — unlike the check-time-only
    ; KTAB_BASIC_SET_PENDING_ERROR calls elsewhere in this file, which
    ; are safe only because they're read back while still paged in,
    ; same statement, before this file's own EXROM_ENTRY_* callers ever
    ; page out.
    ; In:  B = register (1-16), C = data (0-255)
    ; Out: carry set if register out of range, clear on success
    ; Destroys: AF
    call EXROM_VERIFY_KTAB_MAGIC
    jp   SOUND_EXROM

    ORG $C054
EXROM_ENTRY_SPRITE:
    ; Bare trampoline into BASIC_STMT_SPRITE (rom/exrom_sprite.asm, new
    ; content — this file's own INCLUDE below pulls it in) — same
    ; shape as EXROM_ENTRY_HELP above. Home's own BASIC_SPRITE_EXROM
    ; wrapper needs BASIC_EXROM_EXIT_PROTECTED (carry is this entry's
    ; real output — a malformed/out-of-range SPRITE statement — and
    ; must survive the page-out).
    ; In:  HL = text right after "SPRITE"
    ; Out: carry clear on success; carry set + error already recorded
    ;      otherwise
    ; Destroys: AF, BC, DE, HL
    call EXROM_VERIFY_KTAB_MAGIC
    jp   BASIC_STMT_SPRITE

    ORG $C05A
EXROM_ENTRY_STRFUNC:
    ; Bare trampoline into STRFUNC_EXROM (rom/exrom_strfuncs.asm, new
    ; content — this file's own INCLUDE below pulls it in) — the
    ; single shared entry point for CHR$/STR$/UPPER$/LOWER$/LEFT$/
    ; RIGHT$/FILL$/INKEY$/VAL/INSTR, dispatching internally by
    ; STR_FUNC_CALL_ID rather than needing ten separate stubs.
    ; In:  STR_FUNC_CALL_ID set, plus whatever per-ID arguments that
    ;      function needs — see STRFUNC_EXROM's own header
    ; Out: see STRFUNC_EXROM's own header
    ; Destroys: AF, BC, DE, HL, IX
    call EXROM_VERIFY_KTAB_MAGIC
    jp   STRFUNC_EXROM

    ORG $C060
EXROM_ENTRY_EDITOR_INIT:
    ; Bare trampoline into EDITOR_INIT (rom/exrom_editor.asm, new
    ; content — this file's own INCLUDE below pulls it in) — same
    ; shape as EXROM_ENTRY_HELP above.
    ; In/Out/Destroys: identical to EDITOR_INIT's own original contract
    ; (In: none; Out: none; Destroys: AF, HL, BC)
    call EXROM_VERIFY_KTAB_MAGIC
    jp   EDITOR_INIT

    ORG $C066
EXROM_ENTRY_EDITOR_ENTER:
    ; Bare trampoline into EDITOR_ENTER — runs the ENTIRE interactive
    ; edit session (every keystroke) before ever returning, including
    ; its own internal EDITOR_EXIT tail-jump; chunk 6 stays paged to
    ; EXROM for the whole session as a result (BASIC_EDITOR_ENTER_
    ; EXROM's own page-in/out bracket on the Home side), which is
    ; fine — BANK_EXROM_DEPTH (kernel/bank/bank.asm) makes any nested
    ; page-in/out the session's own hooks trigger (EDITOR_NAV_HOOK/
    ; EDITOR_REDRAW_HOOK calling back into Home, which may itself call
    ; back into OTHER EXROM entries) a cheap counter bump, never a
    ; real double port write, and nothing this project cares about
    ; lives in chunk 6 for that whole window to disturb.
    ; In/Out/Destroys: identical to EDITOR_ENTER's own original
    ; contract (In: HL = pointer to program text; Out: none; Destroys:
    ; AF, BC, DE, HL)
    call EXROM_VERIFY_KTAB_MAGIC
    jp   EDITOR_ENTER

    ORG $C06C
EXROM_ENTRY_EDITOR_WRAP_CALC:
    ; Bare trampoline into EDITOR_WRAP_CALC.
    ; In/Out/Destroys: identical to EDITOR_WRAP_CALC's own original
    ; contract (In: HL = pointer to a null-terminated line; Out:
    ; EDIT_WRAP_COUNT/START/LEN populated; Destroys: AF, BC, DE, HL, IX)
    call EXROM_VERIFY_KTAB_MAGIC
    jp   EDITOR_WRAP_CALC

    ORG $C072
EXROM_ENTRY_EDITOR_WRAP_TABLE_ADDR:
    ; Bare trampoline into EDITOR_WRAP_TABLE_ADDR.
    ; In/Out/Destroys: identical to EDITOR_WRAP_TABLE_ADDR's own
    ; original contract (In: HL = table base, A = index; Out: HL =
    ; table base + index; Destroys: AF)
    call EXROM_VERIFY_KTAB_MAGIC
    jp   EDITOR_WRAP_TABLE_ADDR

    ORG $C078
EXROM_ENTRY_EDITOR_WRAP_OFFSET_TO_ROWCOL:
    ; Bare trampoline into EDITOR_WRAP_OFFSET_TO_ROWCOL.
    ; NOTE (2026-08-23): this routine no longer takes A as a real
    ; input — it reads EDIT_BUF_OFFSET from memory directly instead,
    ; specifically because THIS trampoline's own EXROM_VERIFY_KTAB_
    ; MAGIC call below unconditionally clobbers A before the jp ever
    ; runs, silently replacing whatever a caller passed in A with the
    ; magic byte. See EDITOR_WRAP_OFFSET_TO_ROWCOL's own header (rom/
    ; exrom_editor.asm) for the full bug writeup.
    ; In/Out/Destroys: identical to that routine's own current
    ; contract (In: none, reads EDIT_BUF_OFFSET; Out: B = row index,
    ; C = column; Destroys: AF, DE, HL)
    call EXROM_VERIFY_KTAB_MAGIC
    jp   EDITOR_WRAP_OFFSET_TO_ROWCOL

    ORG $C07E
EXROM_ENTRY_EDITOR_WRAP_ROWCOL_TO_OFFSET:
    ; Bare trampoline into EDITOR_WRAP_ROWCOL_TO_OFFSET.
    ; In/Out/Destroys: identical to that routine's own original
    ; contract (In: B = row index, C = column; Out: A = buffer offset;
    ; Destroys: AF, HL)
    call EXROM_VERIFY_KTAB_MAGIC
    jp   EDITOR_WRAP_ROWCOL_TO_OFFSET

    ORG $C084
EXROM_ENTRY_EDITOR_BLOCK_DELETE:
    ; Bare trampoline into EDITOR_BLOCK_DELETE.
    ; In/Out/Destroys: identical to that routine's own original
    ; contract (In: HL = first line position, DE = last line position;
    ; Out: carry clear on success, carry set + program unchanged on
    ; abort; Destroys: AF, BC, DE, HL)
    call EXROM_VERIFY_KTAB_MAGIC
    jp   EDITOR_BLOCK_DELETE

    ORG $C08A
EXROM_ENTRY_DIMN:
    ; Bare trampoline into ARRAY_EXROM_DIMN (rom/exrom_arrays.asm, new
    ; content — this file's own INCLUDE below pulls it in) — DIMN's
    ; real body, moved out to EXROM 2026-08-22 (multi-dimensional
    ; arrays' own budget cost forced it out, same "cold statement,
    ; move it whole" pattern SAVE/LOAD/HELP/the editor/SPRITE/SOUND
    ; already used).
    ; Unlike every other EXROM_ENTRY_* stub, this one does its OWN full
    ; argument parsing from EXPR_PARSE_PTR rather than receiving pre-
    ; parsed input — DIMN(name)'s argument is a bare array-name letter,
    ; never evaluated as an expression, so there's no single Home-side
    ; value to hand across a normal In register the way every numeric
    ; function argument otherwise would be.
    ; In: none (reads EXPR_PARSE_PTR itself). Out: carry clear + HL =
    ; result, EXPR_PARSE_PTR advanced past the closing ")"; carry set
    ; + error already recorded otherwise. Destroys: AF, BC, DE, HL
    call EXROM_VERIFY_KTAB_MAGIC
    jp   ARRAY_EXROM_DIMN

    ORG $C090
EXROM_ENTRY_DETECT_KEYWORDS:
    ; Bare trampoline into BASIC_DETECT_KEYWORD_PREFIX_EXROM_BODY (rom/
    ; exrom_highlight.asm, new content — this file's own INCLUDE below
    ; pulls it in). The multi-keyword bold-highlighting scan moved out
    ; here whole, 2026-08-23, once the plain Home version (~159 bytes)
    ; left the Home build too tight for the preload test harness to
    ; still fit alongside it — same "cold-ish, move it whole" pattern
    ; every other budget-forced migration in this project used. "Cold-
    ; ish" because this runs once per SETTLED line per redraw (every
    ; keystroke), not once per character — closer to EDITOR_WRAP_CALC's
    ; own call frequency than to a true hot per-character loop (that
    ; part, BASIC_KW_OFFSET_BOLD, stayed Home-resident on purpose — see
    ; its own header).
    ; In/Out/Destroys: identical to BASIC_DETECT_KEYWORD_PREFIX's own
    ; original contract (In: HL = line text pointer; Out: HILITE_KW_
    ; COUNT/START/SPANLEN populated; Destroys: AF, BC, DE, HL, IX)
    call EXROM_VERIFY_KTAB_MAGIC
    jp   BASIC_DETECT_KEYWORD_PREFIX_EXROM_BODY

    ORG $C096
EXROM_ENTRY_SPRITE_HIT:
    ; Bare trampoline into BASIC_SPRITE_HIT (rom/exrom_sprite.asm) —
    ; HIT(slot1,slot2), added 2026-08-23 alongside SPRITE MOVE and the
    ; SPRITE_SLOT_MAX increase. Reuses BASIC_SPRITE_SLOT_FLAG_ADDR
    ; directly since it's EXROM-resident already (unlike DIMN's own
    ; array lookup, no cross-compilation-unit addressing problem
    ; here). Takes its two slot numbers in HL/DE rather than A —
    ; deliberately, since this trampoline's own EXROM_VERIFY_KTAB_MAGIC
    ; call below clobbers A (see EDITOR_WRAP_OFFSET_TO_ROWCOL's own
    ; header, rom/exrom_editor.asm, for the full bug writeup that
    ; established why A specifically can never survive this trampoline
    ; shape) — HL/DE are untouched by both BANK_PAGE_EXROM_IN and this
    ; magic check, so passing the slot numbers there instead sidesteps
    ; that whole bug class from the start rather than needing a fix
    ; later.
    ; In/Out/Destroys: identical to BASIC_SPRITE_HIT's own contract
    ; (In: L = slot1, E = slot2; Out: HL = 1 or 0; Destroys: AF, BC,
    ; DE, HL)
    call EXROM_VERIFY_KTAB_MAGIC
    jp   BASIC_SPRITE_HIT

    ORG $C09C
EXROM_ENTRY_NUM_TO_STRING:
    call EXROM_VERIFY_KTAB_MAGIC
    jp   BASIC_NUM_TO_STRING_EXROM

    ORG $C0A2
EXROM_ENTRY_APPEND_STR:
    call EXROM_VERIFY_KTAB_MAGIC
    jp   BASIC_APPEND_STR_EXROM

    ORG $C0A8
EXROM_ENTRY_FLOAT_TO_STRING:
    call EXROM_VERIFY_KTAB_MAGIC
    jp   BASIC_FLOAT_TO_STRING_EXROM

    ORG $C0AE
EXROM_ENTRY_ULAPLUS:
    call EXROM_VERIFY_KTAB_MAGIC
    jp   BASIC_STMT_ULAPLUS_EXROM

    ORG $C0B4
EXROM_ENTRY_INPUT:
    call EXROM_VERIFY_KTAB_MAGIC
    jp   BASIC_STMT_INPUT_EXROM

    ORG $C0BA
EXROM_ENTRY_DIM:
    call EXROM_VERIFY_KTAB_MAGIC
    jp   BASIC_STMT_DIM_EXROM

    ORG $C0C0
EXROM_ENTRY_DEF_FN:
    call EXROM_VERIFY_KTAB_MAGIC
    jp   BASIC_PARSE_DEF_FN_SHARED
    ASSERT $ == $C0C6

    ORG $C0C6

; ============================================================================
; EXROM_VERIFY_KTAB_MAGIC
; Runs first on every entry above. Checks the KTAB_MAGIC byte Home
; stamped into ROM at KTAB_MAGIC_ADDR (see include/exrom_jumptable.inc)
; against THIS EXROM image's own KTAB_MAGIC — same include file, same
; EQU, so the two only disagree if this binary was built against a
; different exrom_jumptable.inc than whatever test_basic.bin it's
; currently paired with (one side reassembled/redeployed, the other
; not). The macro-generated single-source-of-truth table (see that
; file's own header) prevents the SOURCE going out of sync; it can't
; prevent pairing two independently-built BINARIES that came from
; different versions of that source. This is the check for that.
;
; On mismatch: sets EXROM_KTAB_MISMATCH_FLAG and halts, rather than
; letting the caller proceed into a jump table that might resolve to
; the wrong routine entirely — a silent wrong-routine call would be
; far harder to diagnose (looks like a random, unrelated crash) than
; an obvious, flagged hang. Matches this project's own lesson 10
; ("when a diagnostic is needed, print real values rather than
; guess") — a debug.bin dump after a hang shows exactly what happened
; and why, rather than leaving it to be reconstructed from symptoms.
; In:  none
; Out: none (falls through / returns) if the magic matches
; Destroys: AF — never returns at all if it doesn't match
; ============================================================================
EXROM_VERIFY_KTAB_MAGIC:
    ld   a, (KTAB_MAGIC_ADDR)
    cp   KTAB_MAGIC
    ret  z
    ld   a, $FF
    ld   (EXROM_KTAB_MISMATCH_FLAG), a
.halt_loop:
    jr   .halt_loop

; ============================================================================
; EXROM_FULL_CHECK_IMPL
; Real body for the $C006 entry — kept as its own routine (rather than
; inlined into the entry stub above) so every entry stub stays a
; uniform, fixed size regardless of how many instructions the real
; logic needs — the earlier draft of this file inlined a 2-instruction
; body directly into an entry stub, which collided with the next fixed
; offset; this indirection avoids that class of packing mistake
; entirely, here and for any future entry added the same way.
; ============================================================================

EXROM_FULL_CHECK_IMPL:
    call BASIC_SCAN_LABELS              ; must happen before the check
                                        ; pass — GOTO validation needs
                                        ; the label table populated —
                                        ; same ordering/reasoning as
                                        ; the original BASIC_RUN call
                                        ; site in basic.asm
    jp   BASIC_CHECK_PROGRAM

; ============================================================================
; BASIC_SCAN_LABELS
; Rebuilds the label table from scratch by walking the whole program
; once, looking for statements that are ENTIRELY a bare identifier
; followed by ':' (nothing else on the line) — a label definition. The
; label's recorded position is the label STATEMENT's own position, not
; the statement after it: this deliberately lets BASIC_EXEC_STATEMENT's
; existing "unrecognized statement, silently skip" fallback double as
; the label's own no-op execution, rather than needing special-case
; handling for label statements anywhere in the executor. GOTO jumps
; there, that statement no-ops, BASIC_RUN's loop naturally continues to
; whatever comes next — no new execution path needed at all.
;
; Called once at the START of every RUN, not maintained incrementally
; as the program is edited. This is a deliberate simplification, not a
; missed optimization: labels can appear anywhere and the editor
; already supports inserting/deleting/replacing any line, so trying to
; keep positions correct incrementally through arbitrary edits would
; be real synchronization complexity for a program small enough that
; a full rescan is imperceptible. Uses MEM_LABEL_TABLE_CLEAR (not full
; MEM_INIT) specifically so the program itself is left untouched —
; only the label table resets.
;
; SCAN_STMT_POS (memory, not a register) holds the current statement's
; position across BASIC_PARSE_IDENTIFIER's own use of HL/DE — same
; reasoning as EXPR_PARSE_PTR elsewhere in this file: MEM_LINE_NEXT
; needs the real, unclobbered statement pointer afterward.
; In:  none
; Out: none — label table populated as a side effect
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_SCAN_LABELS:
    call KTAB_MEM_LABEL_TABLE_CLEAR
    call KTAB_MEM_LINE_FIRST
.loop:
    ld   a, h
    or   l
    ret  z
    ld   (SCAN_STMT_POS), hl

    inc  hl
    inc  hl                            ; content start
    call KTAB_BASIC_PARSE_IDENTIFIER          ; HL = name start (still content
                                        ; start), B = length, DE =
                                        ; position right after
    ld   a, b
    or   a
    jr   z, .advance                      ; no identifier here at all

    ld   a, (de)
    cp   ":"
    jr   nz, .advance                       ; identifier not immediately
                                           ; followed by ':' — not a label

    inc  de
    ld   a, (de)
    cp   $0D
    jr   nz, .advance                         ; something else follows the
                                             ; ':' — this scope requires
                                             ; "name:" to be the WHOLE
                                             ; statement, nothing more

    ; genuinely a label definition — HL/B are still the name/length
    ; from BASIC_PARSE_IDENTIFIER above, untouched since
    ld   de, (SCAN_STMT_POS)
    call KTAB_MEM_LABEL_ADD                        ; ignore failure (duplicate
                                             ; name or full table) for
                                             ; now — TODO error reporting

.advance:
    ld   hl, (SCAN_STMT_POS)
    call KTAB_MEM_LINE_NEXT
    jr   .loop
; ============================================================================
; BASIC_CHECK_STR_ASSIGNMENT
; Same recognition logic as BASIC_TRY_STR_ASSIGNMENT (string-variable
; letter, '=', string EXPRESSION — a primary, or several joined with
; '+') but never writes the result anywhere — same "check pass must not
; mutate real state" reasoning BASIC_CHECK_ASSIGNMENT's own header
; already gives, just for the string case.
; STR_EXPR_SCRATCH DOES get overwritten by KTAB_BASIC_EVAL_STR_EXPR
; here — harmless, it's scratch, not a real variable's own storage
; (unlike STR_TABLE, which this routine never touches).
; In:  HL = statement content start
; Out: carry clear if this is a valid string assignment; carry set
;      otherwise (matches BASIC_CHECK_ASSIGNMENT's own carry-only
;      ambiguity)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_CHECK_STR_ASSIGNMENT:
    push hl
    call KTAB_BASIC_DETECT_STRVAR
    jr   c, .strassign_fail
    ld   a, (hl)
    cp   "("
    jr   nz, .strassign_skip1
    inc  hl
    call KTAB_BASIC_EVAL_EXPR
    jr   c, .strassign_fail
    call KTAB_BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   ")"
    jr   nz, .strassign_fail
    inc  hl
.strassign_skip1:
    ld   a, (hl)
    cp   " "
    jr   nz, .strassign_eq
    inc  hl
    jr   .strassign_skip1
.strassign_eq:
    cp   "="
    jr   nz, .strassign_fail
    inc  hl
.strassign_skip2:
    ld   a, (hl)
    cp   " "
    jr   nz, .strassign_value
    inc  hl
    jr   .strassign_skip2
.strassign_value:
    ld   de, STR_EXPR_SCRATCH + 1
    ld   c, 31
    call KTAB_BASIC_EVAL_STR_EXPR
    jr   c, .strassign_fail
    call KTAB_BASIC_EXPECT_STATEMENT_END
    jr   c, .strassign_fail

    pop  af
    or   a
    ret
.strassign_fail:
    pop  hl
    scf
    ret

; ============================================================================
; BASIC_CHECK_ARRAY_ASSIGNMENT
; Same recognition logic as BASIC_TRY_ARRAY_ASSIGNMENT (letter, "(",
; index expr, ")", "=", value expr) but never touches real array
; state — same "check pass must not mutate real state" reasoning
; BASIC_CHECK_ASSIGNMENT/BASIC_CHECK_STR_ASSIGNMENT's own headers
; already give. Doesn't call BASIC_ARRAY_FIND at all — an array
; referenced here may not be DIM'd yet during a static whole-program
; pre-pass (DIM is itself just another statement, not necessarily
; executed before this one is checked), so "does the array exist" is
; deliberately a runtime-only question, same split MODE's own range
; check and this project's other statements already established.
; In:  HL = statement content start
; Out: carry clear if this is a valid array assignment; carry set
;      otherwise (matches BASIC_CHECK_ASSIGNMENT's own carry-only
;      ambiguity)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_CHECK_ARRAY_ASSIGNMENT:
    push hl
    ld   a, (hl)
    call KTAB_BASIC_VALIDATE_VAR_LETTER
    jr   c, .arrassign_fail
    inc  hl
    ld   a, (hl)
    cp   "("
    jr   nz, .arrassign_fail
    inc  hl
    call KTAB_BASIC_EVAL_EXPR
    jr   c, .arrassign_fail
    call KTAB_BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   ")"
    jr   nz, .arrassign_fail
    inc  hl
    call KTAB_BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   "="
    jr   nz, .arrassign_fail
    inc  hl
    call KTAB_BASIC_EVAL_EXPR
    jr   c, .arrassign_fail
    call KTAB_BASIC_EXPECT_STATEMENT_END
    jr   c, .arrassign_fail

    pop  af
    or   a
    ret
.arrassign_fail:
    pop  hl
    scf
    ret

; ============================================================================
; BASIC_CHECK_ASSIGNMENT
; Same recognition logic as BASIC_TRY_ASSIGNMENT (variable letter,
; '=', expression) but never writes the result anywhere — the check
; pass must never mutate a variable's actual value as a side effect of
; validating a program, since it isn't really running anything.
; In:  HL = statement content start
; Out: carry clear if this is a valid assignment; carry set otherwise
;      (either it doesn't look like an assignment at all, or the value
;      expression is malformed — the caller can't distinguish which
;      from carry alone, matching BASIC_TRY_ASSIGNMENT's own existing
;      behavior)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_CHECK_ASSIGNMENT:
    push hl
    ld   a, (hl)
    call KTAB_BASIC_VALIDATE_VAR_LETTER
    jr   c, .fail
    inc  hl
.skip_spaces1:
    ld   a, (hl)
    cp   " "
    jr   nz, .check_equals
    inc  hl
    jr   .skip_spaces1
.check_equals:
    cp   "="
    jr   nz, .fail
    inc  hl
.skip_spaces2:
    ld   a, (hl)
    cp   " "
    jr   nz, .parse_value
    inc  hl
    jr   .skip_spaces2
.parse_value:
    call KTAB_BASIC_EVAL_EXPR
    jr   c, .fail

    call KTAB_BASIC_EXPECT_STATEMENT_END ; BASIC_EXPECT_STATEMENT_END fix —
                                        ; THE bug this project's "Real
                                        ; end-to-end hardware test #1"
                                        ; found ("x = 1c" was silently
                                        ; accepted). Destroys AF/HL
                                        ; only, so DE (unused here
                                        ; anyway — this routine never
                                        ; writes the value) doesn't
                                        ; matter either way
    jr   c, .fail                        ; same restore-original-
                                        ; position path as every other
                                        ; failure in this routine

    pop  af                             ; discard saved start position —
                                        ; success, nothing to restore
    or   a
    ret
.fail:
    pop  hl                                ; restore original position
    scf
    ret

; ============================================================================
; BASIC_CHECK_STATEMENT
; Validates one statement WITHOUT executing it — no screen output, no
; variable writes, no waiting for keyboard input, no actual jumping.
; Mirrors BASIC_EXEC_STATEMENT's own dispatch structure closely (same
; keyword checks, same order) and reuses the exact same validation
; primitives it does — BASIC_MATCH_KEYWORD_BOUNDARY,
; BASIC_EVAL_EXPR, BASIC_PARSE_IDENTIFIER, MEM_LABEL_LOOKUP,
; BASIC_IS_LABEL_DEFINITION, BASIC_SET_PENDING_ERROR — every one of
; which is already side-effect-free by nature (they compute or look
; things up, they don't display or store anything). The only
; genuinely new logic here is INPUT's check (a variable letter must
; follow, but nothing waits for a keypress) and skipping the final
; commit step in PRINT/GOTO/assignment specifically.
;
; A malformed expression inside PRINT relies on the exact same "first,
; most specific error wins" behavior real execution has: if the
; expression contains something like "5/0", BASIC_EVAL_EXPR's own call
; chain already recorded DIVISION BY ZERO via BASIC_SET_PENDING_ERROR
; before returning failure here, and this routine's own generic
; SYNTAX ERROR call won't overwrite it.
; In:  HL = pointer to the statement's length prefix
; Out: carry set if this statement is invalid (a message has been
;      recorded via BASIC_SET_PENDING_ERROR); carry clear if it's fine
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_CHECK_STATEMENT:
    inc  hl
    inc  hl                          ; content start
    jp   BASIC_CHECK_MULTI_STATEMENT

; ============================================================================
; BASIC_CHECK_STATEMENT_CONTENT
; The real validation dispatch, split out from BASIC_CHECK_STATEMENT
; the same way — and for the same reason — BASIC_EXEC_STATEMENT_CONTENT
; was split from BASIC_EXEC_STATEMENT: BASIC_STMT_IF's single-line
; short form needs to validate its own trailing statement text using
; this exact same dispatch, with no length prefix of its own to skip.
; END IF's compound check comes before bare END for the same reason as
; in the execution dispatch — see BASIC_MATCH_ENDIF's header.
;
; Note this checker validates each IF/ELSEIF/ELSE/END IF line's OWN
; syntax in isolation — same as every other statement — but does NOT
; verify whole-program IF/END IF balance (that every IF eventually has
; a matching END IF, correctly nested). That's a structural, cross-
; statement property BASIC_CHECK_PROGRAM's per-statement design was
; never built to catch (see that routine's own header — it already
; doesn't claim exhaustiveness). A genuinely mismatched IF is instead
; caught at RUN time, when BASIC_RESOLVE_IF_CHAIN or
; BASIC_SKIP_TO_ENDIF's own forward scan runs off the end of the
; program and reports MSG_MISSING_ENDIF.
; In:  HL = statement content start (text, past any length prefix)
; Out: carry set if this statement is invalid (a message has been
;      recorded via BASIC_SET_PENDING_ERROR); carry clear if it's fine
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_CHECK_STATEMENT_CONTENT:
    call KTAB_BASIC_MATCH_ENDIF
    jp   nc, .ok                       ; END IF takes no argument

    push ix                              ; preserve caller's IX
    ld   ix, CHECK_STATEMENT_DISPATCH_TABLE
.dispatch_loop:
    ld   e, (ix+0)
    ld   d, (ix+1)
    ld   a, d
    or   e
    jr   z, .try_assignments
    call KTAB_BASIC_MATCH_KEYWORD_BOUNDARY
    jr   nc, .dispatch_match
    ld   de, 4
    add  ix, de
    jr   .dispatch_loop
.dispatch_match:
    ld   e, (ix+2)
    ld   d, (ix+3)
    pop  ix
    push de
    ret

.try_assignments:
    pop  ix
    ld   de, (EXTENSION_MAGIC)
    ld   a, e
    cp   LOW EXTENSION_REG_MAGIC
    jr   nz, .no_extension
    ld   a, d
    cp   HIGH EXTENSION_REG_MAGIC
    jr   nz, .no_extension
    ld   de, (EXTENSION_NAME_PTR)
    call KTAB_BASIC_MATCH_KEYWORD_BOUNDARY
    jp   nc, .check_at                  ; v1 registry grammar: expr,expr
.no_extension:
    call BASIC_CHECK_STR_ASSIGNMENT
    jp   nc, .ok                          ; string assignment handled
                                         ; it — tried first, same
                                         ; ordering/reasoning as
                                         ; basic/basic.asm's own
                                         ; dispatch (BASIC_TRY_STR_
                                         ; ASSIGNMENT's own header)

    call BASIC_CHECK_ARRAY_ASSIGNMENT
    jp   nc, .ok                          ; array-element assignment
                                         ; handled it — same reasoning,
                                         ; tried before the plain
                                         ; scalar check below

    call BASIC_CHECK_ASSIGNMENT
    jp   nc, .ok

    call KTAB_BASIC_IS_LABEL_DEFINITION
    jp   nc, .ok

    ld   hl, MSG_SYNTAX_ERROR
    call KTAB_BASIC_SET_PENDING_ERROR
    scf
    ret

.check_if:
    call KTAB_BASIC_SKIP_SPACES
    call KTAB_BASIC_EVAL_CONDITION
    jr   c, .syntax_fail

    call KTAB_BASIC_SKIP_SPACES
    ld   de, KW_THEN
    call KTAB_BASIC_MATCH_KEYWORD_BOUNDARY
    jr   c, .syntax_fail
    call KTAB_BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   $0D
    jp   z, .ok                          ; block form — nothing more
                                        ; to check on THIS line; the
                                        ; body's own statements each
                                        ; get checked independently as
                                        ; BASIC_CHECK_PROGRAM walks on
    jp   BASIC_CHECK_MULTI_STATEMENT       ; single-line form — check
                                          ; the trailing statement (now
                                          ; potentially colon-separated
                                          ; several) the same way a
                                          ; top-level line would be

.check_elseif:
    call KTAB_BASIC_SKIP_SPACES
    call KTAB_BASIC_EVAL_CONDITION
    jr   c, .syntax_fail
    call KTAB_BASIC_SKIP_SPACES
    ld   de, KW_THEN
    call KTAB_BASIC_MATCH_KEYWORD_BOUNDARY
    jr   c, .syntax_fail
    call KTAB_BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   $0D
    jp   z, .ok                           ; ELSEIF is block-only — no
                                         ; single-line short form, so
                                         ; anything left after THEN is
                                         ; invalid; valid end jumps to
                                         ; the shared success tail

.syntax_fail:
    ld   hl, MSG_SYNTAX_ERROR
    call KTAB_BASIC_SET_PENDING_ERROR            ; won't overwrite a more
                                           ; specific error already
                                           ; recorded deeper in the
                                           ; condition's own evaluation
    scf
    ret

.check_for:
    call KTAB_BASIC_PARSE_FOR_HEADER            ; shared with BASIC_STMT_FOR's
                                          ; own real execution — see
                                          ; that routine's header
    ret  c                                 ; error already recorded
    jp   .ok

.check_next:
    call KTAB_BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   $0D
    jp   z, .ok                            ; bare NEXT
    call KTAB_BASIC_VALIDATE_VAR_LETTER
    jr   c, .syntax_fail
    inc  hl                                ; advance past the letter —
                                          ; BASIC_EXPECT_STATEMENT_END
                                          ; fix needs the real position
                                          ; here, same as BASIC_STMT_
                                          ; NEXT's own Home-side fix
    call KTAB_BASIC_EXPECT_STATEMENT_END     ; "NEXT xy" is malformed —
                                          ; one letter is the whole
                                          ; grammar here; matching the
                                          ; actual FOR at RUN time is
                                          ; BASIC_STMT_NEXT's own job,
                                          ; not this per-line static
                                          ; check's (same split as
                                          ; IF/END IF — see this
                                          ; dispatch's header)
    ret  c
    jp   .ok

.check_exit:
    ; only "EXIT FOR" is valid syntax — see BASIC_STMT_EXIT's own
    ; header for why bare EXIT is deliberately not accepted for FOR.
    ; Whether a FOR is actually open at this point in the program is a
    ; RUN-time question (BASIC_STMT_EXIT's own FOR_STACK_DEPTH check) —
    ; same split every other construct here already has: this per-line
    ; check validates syntax only, never whole-program construct
    ; balance (see FOR/NEXT's own .check_for/.check_next above).
    call KTAB_BASIC_SKIP_SPACES
    ld   de, KW_FOR
    call KTAB_BASIC_MATCH_KEYWORD_BOUNDARY
    jr   c, .syntax_fail
    call KTAB_BASIC_EXPECT_STATEMENT_END
    ret  c
    jp   .ok

.check_def_fn:
    ld   b, 0                         ; checker: parse, then validate expression
    call BASIC_PARSE_DEF_FN_SHARED
    jp   c, .syntax_fail
    jp   .ok

.check_sprite:
    ; validates ARGUMENT COUNT/shape only (GRAB=5, SHOW=3, HIDE=1,
    ; MOVE=3 comma-separated expressions) — same split every other
    ; construct here already has: slot range, row/col/w/h range, and
    ; whether a slot is defined/shown are all RUN-time questions
    ; (BASIC_STMT_SPRITE_GRAB/SHOW/HIDE/MOVE's own checks), not caught
    ; here.
    call KTAB_BASIC_SKIP_SPACES
    ld   de, KW_GRAB
    call KTAB_BASIC_MATCH_KEYWORD_BOUNDARY
    jr   nc, .check_sprite_5args

    ld   de, KW_SHOW
    call KTAB_BASIC_MATCH_KEYWORD_BOUNDARY
    jr   nc, .check_sprite_3args

    ld   de, KW_HIDE
    call KTAB_BASIC_MATCH_KEYWORD_BOUNDARY
    jr   nc, .check_sprite_1arg

    ld   de, KW_MOVE
    call KTAB_BASIC_MATCH_KEYWORD_BOUNDARY
    jr   nc, .check_sprite_3args          ; MOVE <slot>,<row>,<col> —
                                          ; identical shape to SHOW

    jp   .syntax_fail

.check_sprite_1arg:
    call KTAB_BASIC_EVAL_EXPR
    jp   c, .syntax_fail
    call KTAB_BASIC_EXPECT_STATEMENT_END
    ret  c
    jp   .ok

.check_sprite_3args:
    call KTAB_BASIC_EVAL_EXPR
    jp   c, .syntax_fail
    call KTAB_BASIC_EXPECT_COMMA_EXPR
    ret  c
    call KTAB_BASIC_EXPECT_COMMA_EXPR
    ret  c
    call KTAB_BASIC_EXPECT_STATEMENT_END
    ret  c
    jp   .ok

.check_sprite_5args:
    call KTAB_BASIC_EVAL_EXPR
    jp   c, .syntax_fail
    call KTAB_BASIC_EXPECT_COMMA_EXPR
    ret  c
    call KTAB_BASIC_EXPECT_COMMA_EXPR
    ret  c
    call KTAB_BASIC_EXPECT_COMMA_EXPR
    ret  c
    call KTAB_BASIC_EXPECT_COMMA_EXPR
    ret  c
    call KTAB_BASIC_EXPECT_STATEMENT_END
    ret  c
    jp   .ok

.check_border:
.check_attr_expr:                        ; INK/PAPER/FLASH/INVERSE/OVER/
                                         ; TAB/MODE/PALETTE all validate
                                         ; the same way as BORDER — one
                                         ; expression, no further
                                         ; syntax — so this falls
                                         ; straight through into the
                                         ; same check
    call KTAB_BASIC_EVAL_EXPR                  ; skips its own leading
                                         ; spaces, same as .check_print
                                         ; relies on for PRINT's
                                         ; expression form
    jp   c, .syntax_fail
    call KTAB_BASIC_EXPECT_STATEMENT_END       ; BASIC_EXPECT_STATEMENT_END
                                         ; fix — mirrors the Home-side
                                         ; masked-expr consolidation's
                                         ; own check
    jp   c, .syntax_fail
    jp   .ok

.check_at:
    call KTAB_BASIC_EVAL_EXPR                  ; row expression (also PLOT's
                                         ; x expression — see this
                                         ; block's shared dispatch
                                         ; entry above)
    jp   c, .syntax_fail
    call KTAB_BASIC_EXPECT_COMMA_EXPR          ; col expression (PLOT's y) —
                                         ; error already recorded on
                                         ; failure, so just propagate
    ret  c
    call KTAB_BASIC_EXPECT_STATEMENT_END       ; BASIC_EXPECT_STATEMENT_END fix
    ret  c
    jp   .ok

.check_dim:
    ; DIM <letter>(<size>) — grammar only; whether the letter is
    ; already DIM'd, and whether <size> is a sensible positive value,
    ; are both runtime-only questions (basic/basic.asm's BASIC_STMT_
    ; DIM), same "grammar here, values at runtime" split every other
    ; statement in this file already follows.
    call KTAB_BASIC_SKIP_SPACES
    ld   a, (hl)
    call KTAB_BASIC_VALIDATE_VAR_LETTER
    jp   c, .syntax_fail
    inc  hl
    ld   a, (hl)
    cp   "$"
    jr   nz, .check_dim_open
    inc  hl
    ld   a, (hl)
.check_dim_open:
    cp   "("
    jp   nz, .syntax_fail
    inc  hl
    call KTAB_BASIC_EVAL_EXPR
    jp   c, .syntax_fail
    call KTAB_BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   ")"
    jp   nz, .syntax_fail
    inc  hl
    call KTAB_BASIC_EXPECT_STATEMENT_END
    ret  c
    jp   .ok

.check_line:
    call KTAB_BASIC_EVAL_EXPR                  ; x0
    jp   c, .syntax_fail
    call KTAB_BASIC_EXPECT_COMMA_EXPR          ; y0
    ret  c
    call KTAB_BASIC_SKIP_SPACES
    ld   de, KW_TO
    call KTAB_BASIC_MATCH_KEYWORD_BOUNDARY
    jp   c, .syntax_fail
    call KTAB_BASIC_EVAL_EXPR                  ; x1
    jp   c, .syntax_fail
    call KTAB_BASIC_EXPECT_COMMA_EXPR          ; y1
    ret  c
    call KTAB_BASIC_EXPECT_STATEMENT_END       ; BASIC_EXPECT_STATEMENT_END fix
    ret  c
    jp   .ok

.check_circle:
    call KTAB_BASIC_EVAL_EXPR                  ; x
    jp   c, .syntax_fail
    call KTAB_BASIC_EXPECT_COMMA_EXPR          ; y
    ret  c
    call KTAB_BASIC_EXPECT_COMMA_EXPR          ; r
    ret  c
    call KTAB_BASIC_EXPECT_STATEMENT_END       ; BASIC_EXPECT_STATEMENT_END fix
    ret  c
    jp   .ok

.check_print:
    call KTAB_BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   '"'
    jp   z, .ok                          ; a string literal — real
                                        ; execution doesn't validate
                                        ; the closing quote either, so
                                        ; checking stays consistent
                                        ; with that

    call KTAB_BASIC_DETECT_STRVAR
    jp   nc, .ok                          ; a string-variable reference
                                         ; (X$) — same lenient "don't
                                         ; validate what follows"
                                         ; treatment as the literal
                                         ; case above, matching real
                                         ; execution's own .print_strvar
                                         ; path (basic/basic.asm's
                                         ; BASIC_STMT_PRINT) exactly

    ; a string-FUNCTION call (UPPER$(...), CHR$(...), ...) — same
    ; check real execution's own .print_func_call does (basic/basic.
    ; asm's BASIC_STMT_PRINT). REAL BUG FOUND (2026-08-22, caught by
    ; actually running the emulator, not by static review): this
    ; branch was missing entirely when string functions first landed —
    ; "PRINT UPPER$(A$)" fell straight through to the numeric path
    ; below and failed the whole-program check with a SYNTAX ERROR,
    ; even though it executes fine at runtime. STR_EXPR_SCRATCH is the
    ; same "safe to overwrite during a check pass" buffer BASIC_CHECK_
    ; STR_ASSIGNMENT already uses for its own real KTAB_BASIC_EVAL_
    ; STR_EXPR call just above in this file.
    call KTAB_BASIC_TRY_EVAL_STR_FUNCTION
    jr   c, .print_not_str_func
    ld   de, STR_EXPR_SCRATCH + 1
    ld   c, 31
    call KTAB_BASIC_EVAL_STR_FUNCTION_CALL
    jp   c, .syntax_fail
    jr   .ok
.print_not_str_func:

    call KTAB_BASIC_EVAL_EXPR
    jp   c, .syntax_fail
    call KTAB_BASIC_EXPECT_STATEMENT_END       ; BASIC_EXPECT_STATEMENT_END
                                         ; fix — numeric branch only;
                                         ; the string-literal branch
                                         ; above is a deliberate,
                                         ; already-documented
                                         ; simplification (real
                                         ; execution doesn't validate
                                         ; the closing quote either),
                                         ; not this gap, left alone
    jp   c, .syntax_fail
    jp   .ok

.check_input:
    call KTAB_BASIC_SKIP_SPACES
    ld   a, (hl)
    call KTAB_BASIC_VALIDATE_VAR_LETTER
    jr   c, .input_fail
    inc  hl                                ; advance past the letter
    ld   a, (hl)
    cp   "$"                              ; INPUT accepts numeric or
    jr   nz, .input_target_done            ; string scalar targets
    inc  hl
.input_target_done:
                                           ; needed for the end-check
                                           ; below, same as BASIC_STMT_
                                           ; INPUT's own Home-side fix
    call KTAB_BASIC_EXPECT_STATEMENT_END     ; BASIC_EXPECT_STATEMENT_END
                                           ; fix — "INPUT xy" is
                                           ; malformed; one scalar
                                           ; variable is the whole grammar
    jr   nc, .ok
.input_fail:
    ld   hl, MSG_SYNTAX_ERROR
    call KTAB_BASIC_SET_PENDING_ERROR
    scf
    ret

.check_goto:
    call KTAB_BASIC_SKIP_SPACES
    call KTAB_BASIC_PARSE_IDENTIFIER     ; HL = name start, B = length,
                                         ; DE = real source-text
                                         ; position right after the
                                         ; identifier (BASIC_PARSE_
                                         ; IDENTIFIER's own internal
                                         ; read pointer, left where it
                                         ; stopped — same fact BASIC_
                                         ; STMT_GOTO's own Home-side
                                         ; fix relies on)
    ld   a, b
    or   a
    jr   nz, .goto_have_ident

    ld   hl, MSG_SYNTAX_ERROR
    call KTAB_BASIC_SET_PENDING_ERROR
    scf
    ret

.goto_have_ident:
    push de                              ; stash the real source
                                         ; position — MEM_LABEL_LOOKUP
                                         ; destroys DE for its own
                                         ; return value below
    call KTAB_MEM_LABEL_LOOKUP
    jr   nc, .goto_found

    pop  de                              ; keep the stack balanced —
                                         ; discard, error already
                                         ; recorded below
    ld   hl, MSG_LABEL_NOT_FOUND
    call KTAB_BASIC_SET_PENDING_ERROR
    scf
    ret

.goto_found:
    pop  hl                              ; HL = stashed real source
                                         ; position (the checker only
                                         ; needs to validate syntax, not
                                         ; act on the lookup result —
                                         ; unlike BASIC_STMT_GOTO, there
                                         ; is no GOTO_TARGET to set here)
    call KTAB_BASIC_EXPECT_STATEMENT_END   ; BASIC_EXPECT_STATEMENT_END
                                         ; fix — "GOTO labelx extra" is
                                         ; malformed
    ret  c
    jr   .ok

.ok:
    or   a
    ret

; Shared DEF FN header parser for the runtime entry and static checker.
; In: HL after DEF keyword; B=0 checker (also evaluate expression), B=1 runtime
; (store definition only). Out: carry set on malformed syntax.
BASIC_PARSE_DEF_FN_SHARED:
    push bc
    call KTAB_BASIC_SKIP_SPACES
    ld   de, KW_FN
    call KTAB_BASIC_MATCH_KEYWORD_BOUNDARY
    jr   c, .bad
    call KTAB_BASIC_SKIP_SPACES
    call KTAB_BASIC_VALIDATE_VAR_LETTER
    jr   c, .bad
    ld   (DEF_FN_NAME), a
    inc  hl
    call KTAB_BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   '('
    jr   nz, .bad
    inc  hl
    call KTAB_BASIC_SKIP_SPACES
    call KTAB_BASIC_VALIDATE_VAR_LETTER
    jr   c, .bad
    ld   (DEF_FN_PARAM), a
    inc  hl
    call KTAB_BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   ')'
    jr   nz, .bad
    inc  hl
    call KTAB_BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   '='
    jr   nz, .bad
    inc  hl
    call KTAB_BASIC_SKIP_SPACES
    push hl                            ; expression is parsed from transient
    ld   de, MULTI_STMT_BUF            ; MULTI_STMT_BUF; store the matching
    or   a                              ; persistent program-text address
    sbc  hl, de
    ld   de, (MULTI_SEG_START)
    add  hl, de
    ld   (DEF_FN_EXPR_PTR), hl
    pop  hl                             ; checker still evaluates transient text
    xor  a
    ld   (DEF_FN_ACTIVE), a
    pop  bc
    ld   a, b
    or   a
    ret  nz
    call KTAB_BASIC_EVAL_EXPR
    ret  c
    jp   KTAB_BASIC_EXPECT_STATEMENT_END
.bad:
    pop  bc
    scf
    ret

; Keyword pointer + grammar-handler pointer. The order matches execution
; dispatch. Multiple keywords intentionally share validators where their
; grammar is identical; END IF remains the compound pre-check above.
CHECK_STATEMENT_DISPATCH_TABLE:
    DW KW_PRINT, BASIC_CHECK_STATEMENT_CONTENT.check_print
    DW KW_CLS, BASIC_CHECK_STATEMENT_CONTENT.ok
    DW KW_REM, BASIC_CHECK_STATEMENT_CONTENT.ok
    DW KW_BORDER, BASIC_CHECK_STATEMENT_CONTENT.check_border
    DW KW_INK, BASIC_CHECK_STATEMENT_CONTENT.check_attr_expr
    DW KW_PAPER, BASIC_CHECK_STATEMENT_CONTENT.check_attr_expr
    DW KW_FLASH, BASIC_CHECK_STATEMENT_CONTENT.check_attr_expr
    DW KW_BRIGHT, BASIC_CHECK_STATEMENT_CONTENT.check_attr_expr
    DW KW_INVERSE, BASIC_CHECK_STATEMENT_CONTENT.check_attr_expr
    DW KW_OVER, BASIC_CHECK_STATEMENT_CONTENT.check_attr_expr
    DW KW_AT, BASIC_CHECK_STATEMENT_CONTENT.check_at
    DW KW_TAB, BASIC_CHECK_STATEMENT_CONTENT.check_attr_expr
    DW KW_PLOT, BASIC_CHECK_STATEMENT_CONTENT.check_at
    DW KW_LINE, BASIC_CHECK_STATEMENT_CONTENT.check_line
    DW KW_CIRCLE, BASIC_CHECK_STATEMENT_CONTENT.check_circle
    DW KW_FILL, BASIC_CHECK_STATEMENT_CONTENT.check_at
    DW KW_BEEP, BASIC_CHECK_STATEMENT_CONTENT.check_at
    DW KW_SOUND, BASIC_CHECK_STATEMENT_CONTENT.check_at
    DW KW_DIM, BASIC_CHECK_STATEMENT_CONTENT.check_dim
    DW KW_MODE, BASIC_CHECK_STATEMENT_CONTENT.check_border
    DW KW_ULAPLUS, BASIC_CHECK_STATEMENT_CONTENT.check_border
    DW KW_PALETTE, BASIC_CHECK_STATEMENT_CONTENT.check_at
    DW KW_END, BASIC_CHECK_STATEMENT_CONTENT.ok
    DW KW_STOP, BASIC_CHECK_STATEMENT_CONTENT.ok
    DW KW_INPUT, BASIC_CHECK_STATEMENT_CONTENT.check_input
    DW KW_GOTO, BASIC_CHECK_STATEMENT_CONTENT.check_goto
    DW KW_IF, BASIC_CHECK_STATEMENT_CONTENT.check_if
    DW KW_ELSEIF, BASIC_CHECK_STATEMENT_CONTENT.check_elseif
    DW KW_ELSE, BASIC_CHECK_STATEMENT_CONTENT.ok
    DW KW_FOR, BASIC_CHECK_STATEMENT_CONTENT.check_for
    DW KW_NEXT, BASIC_CHECK_STATEMENT_CONTENT.check_next
    DW KW_EXIT, BASIC_CHECK_STATEMENT_CONTENT.check_exit
    DW KW_SPRITE, BASIC_CHECK_STATEMENT_CONTENT.check_sprite
    DW KW_POKE, BASIC_CHECK_STATEMENT_CONTENT.check_at
    DW KW_PAUSE, BASIC_CHECK_STATEMENT_CONTENT.check_border
    DW KW_RANDOMISE, BASIC_CHECK_STATEMENT_CONTENT.check_border
    DW KW_GOSUB, BASIC_CHECK_STATEMENT_CONTENT.check_goto
    DW KW_CALL, BASIC_CHECK_STATEMENT_CONTENT.check_goto
    DW KW_RETURN, BASIC_CHECK_STATEMENT_CONTENT.ok
    DW KW_DEF, BASIC_CHECK_STATEMENT_CONTENT.check_def_fn
    DW 0

; ============================================================================
; BASIC_CHECK_MULTI_STATEMENT
; Check-pass counterpart to BASIC_EXEC_MULTI_STATEMENT — same colon-
; splitting shape (label-definition check first via the unmodified
; BASIC_IS_LABEL_DEFINITION, then segment-by-segment via
; BASIC_FIND_STATEMENT_BOUNDARY, empty segments silently skipped),
; calling BASIC_CHECK_STATEMENT_CONTENT per segment instead of
; BASIC_EXEC_STATEMENT_CONTENT. Needed so a syntax error in the
; SECOND (or later) colon-separated statement on a line is caught by
; the static check pass too, not just discovered at RUN time when
; execution actually reaches it — matching how a malformed FIRST
; statement on a line already gets caught today.
;
; Deliberately a separate, duplicated routine rather than sharing code
; with BASIC_EXEC_MULTI_STATEMENT via an indirect call — the two
; differ only in which _CONTENT routine they call, but keeping each
; version simple and independently traceable matches this project's
; established preference (see BASIC_HANDLE_NAV/DELETE's own scroll-
; formula duplication) over adding an indirection layer to save a
; couple dozen lines.
;
; Stops at the FIRST failing segment (same "carry set = this line is
; invalid" contract BASIC_CHECK_STATEMENT_CONTENT already has for a
; single statement) rather than continuing to check remaining segments
; on the same line — BASIC_CHECK_PROGRAM only ever records one
; position per failing line regardless, so checking further segments
; on an already-flagged line would find nothing new to report.
; In:  HL = content start (a statement's own text, past any length
;      prefix — or IF's single-line THEN form's trailing text)
; Out: carry set if any part of this line is invalid (a message has
;      been recorded via BASIC_SET_PENDING_ERROR); carry clear if the
;      whole line — every colon-separated segment of it — is fine
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_CHECK_MULTI_STATEMENT:
    push hl
    call KTAB_BASIC_IS_LABEL_DEFINITION
    pop  hl
    jp   nc, BASIC_CHECK_STATEMENT_CONTENT  ; IS a label — whole line,
                                           ; unsplit, same reasoning as
                                           ; BASIC_EXEC_MULTI_STATEMENT

.loop:
    ld   (MULTI_SEG_START), hl
    call KTAB_BASIC_FIND_STATEMENT_BOUNDARY
    ld   (MULTI_SEG_END), de
    ld   (MULTI_SEG_BOUNDARY_CHAR), a

    ld   hl, (MULTI_SEG_START)
    or   a
    sbc  hl, de
    jr   z, .next_segment                  ; empty segment — skip

    ld   hl, (MULTI_SEG_START)
    ld   de, MULTI_STMT_BUF
.copy_loop:
    ld   bc, (MULTI_SEG_END)
    ld   a, h
    cp   b
    jr   nz, .copy_one
    ld   a, l
    cp   c
    jr   z, .copy_done
.copy_one:
    ld   a, (hl)
    ld   (de), a
    inc  hl
    inc  de
    jr   .copy_loop
.copy_done:
    ld   a, $0D
    ld   (de), a

    ld   hl, MULTI_STMT_BUF
    call BASIC_CHECK_STATEMENT_CONTENT
    jr   c, .stop

.next_segment:
    ld   a, (MULTI_SEG_BOUNDARY_CHAR)
    cp   $0D
    jr   z, .all_done

    ld   hl, (MULTI_SEG_END)
    inc  hl                              ; skip past the ':' — next
                                        ; segment starts right after it
    call KTAB_BASIC_SKIP_SPACES               ; ...and past any run of
                                        ; spaces before it — a natural
                                        ; "a: b" style otherwise leaves
                                        ; the next segment starting on
                                        ; a space, which nothing
                                        ; downstream (BASIC_EXEC_
                                        ; STATEMENT_CONTENT's own
                                        ; keyword checks included)
                                        ; tolerates. Found via a real
                                        ; SYNTAX ERROR on every colon-
                                        ; joined statement in a preload
                                        ; test program, traced to
                                        ; exactly this — same fix
                                        ; applies to BASIC_CHECK_MULTI_
                                        ; STATEMENT's own identical
                                        ; next-segment advance below
    jr   .loop

.stop:
    scf
    ret
.all_done:
    or   a
    ret

; ============================================================================
; BASIC_CHECK_PROGRAM
; Walks the whole program once, calling BASIC_CHECK_STATEMENT on every
; statement — unlike BASIC_RUN, this never stops early and never
; follows a GOTO; it checks every statement in program order
; regardless of whether real execution would ever actually reach it.
; Counts how many failed (CHECK_ERROR_COUNT), remembers the earliest
; one's position (CHECK_FIRST_ERROR_STMT), and records every failing
; position up to 16 of them (CHECK_ERROR_LIST) — see that sysvar's own
; comment for why 16 is a deliberate cap, not a discovered limit.
;
; PENDING_ERROR_MSG is reset before EACH statement check, not once for
; the whole pass — it exists to track "what went wrong within the
; statement currently being checked," the same role it plays during
; real execution; the check pass needs a fresh answer to that question
; for every single statement, not just the first one found across the
; whole program.
; In:  none
; Out: none — CHECK_ERROR_COUNT, CHECK_FIRST_ERROR_STMT, and
;      CHECK_ERROR_LIST set as a side effect
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_CHECK_PROGRAM:
    ld   hl, 0
    ld   (CHECK_ERROR_COUNT), hl
    ld   (CHECK_FIRST_ERROR_STMT), hl
    call KTAB_MEM_LINE_FIRST
.loop:
    ld   a, h
    or   l
    ret  z

    ld   (SCAN_STMT_POS), hl              ; reused — BASIC_SCAN_LABELS'
                                         ; own scratch, safe to share
                                         ; since the two never run at
                                         ; the same time
    ld   de, 0
    ld   (PENDING_ERROR_MSG), de            ; fresh per statement — see
                                           ; this routine's own header
    call BASIC_CHECK_STATEMENT
    jr   nc, .next                          ; this statement is fine

    ld   hl, (CHECK_ERROR_COUNT)
    inc  hl
    ld   (CHECK_ERROR_COUNT), hl

    ld   hl, (CHECK_FIRST_ERROR_STMT)
    ld   a, h
    or   l
    jr   nz, .have_first                      ; already have a first
                                              ; one — this isn't it

    ld   hl, (SCAN_STMT_POS)
    ld   (CHECK_FIRST_ERROR_STMT), hl

.have_first:
    ; add this position to CHECK_ERROR_LIST too, if there's still room
    ; — CHECK_ERROR_COUNT (just incremented) is this error's 1-based
    ; index; if it's 16 or less, write it at slot (count-1)
    ld   hl, (CHECK_ERROR_COUNT)
    ld   a, h
    or   a
    jr   nz, .list_full                       ; count >= 256, way past
                                              ; the cap
    ld   a, l
    cp   17
    jr   nc, .list_full                         ; count >= 17, list is
                                                ; already full

    dec  a                                        ; a = count-1 (0-based
                                                  ; slot, 0..15)
    add  a, a                                       ; a = slot*2 (byte
                                                    ; offset, 0..30)
    ld   e, a
    ld   d, 0
    ld   hl, CHECK_ERROR_LIST
    add  hl, de                                       ; hl = this
                                                      ; entry's write
                                                      ; address

    ld   de, (SCAN_STMT_POS)
    ld   (hl), e
    inc  hl
    ld   (hl), d

.list_full:
.next:
    ld   hl, (SCAN_STMT_POS)
    call KTAB_MEM_LINE_NEXT
    jr   .loop


; ============================================================================
; Keyword/message string data — shared with basic.asm, not duplicated
; (2026-08-19). Was a hand-duplicated byte-for-byte copy here, kept in
; sync by tools/check_exrom_data_sync.py (retired) — see include/
; checker_keywords.inc's own header for the full history and why a
; genuine INCLUDE works here (single source) where the checker's own
; ROUTINES couldn't just be INCLUDEd the same way basic.asm never
; moves and this file has no real linker to it. Every `ld de,
; KW_PRINT`/`ld hl, MSG_SYNTAX_ERROR` reference already inside the
; moved checker code above resolves against THIS copy, which is now
; the SAME text as basic.asm's, by construction, not by discipline.
; ============================================================================
    INCLUDE "include/checker_keywords.inc"

; ---- no DS pad / SAVEBIN here anymore — this file is INCLUDEd from
; rom/exrom_build.asm now, which does both once, after ALSO including
; rom/exrom_storage.asm. See that file's own header. ----
