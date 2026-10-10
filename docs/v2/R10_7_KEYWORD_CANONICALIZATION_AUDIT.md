# R10.7 — Keyword-Case Canonicalization (Audit + Implementation)

> ## SUPERSEDED — final product decision: render-time uppercase (read this first)
>
> The **authoritative source is never rewritten**. Keyword capitalization is a
> *display* property, applied in the editor/LIST rendering path. The
> commit-time canonicalizer (`V2_CANONICALIZE_KEYWORDS`, "approach B" below,
> 199 B EXROM) was **removed**; sections below are kept as history and as the
> record of the boundary rules (strings, REM, `To1`/`To$`) that the
> replacement had to preserve.
>
> ### What the replacement is
>
> One scanner, not two: the existing bolding pass `V2_KW_DETECT_SPANS`
> (`rom/exrom_v2_shell.asm`) now (1) skips `"..."` string contents,
> (2) treats a word as an identifier -- never a keyword -- when letters run
> into digits or a trailing `$` (`To1`, `x1for`, `To$`), and (3) stops
> scanning after a matched `REM` (compared by token value, `TOK_KW_REM`,
> exported through `tools/write_v2_crossbank.py`, no new table). The draw
> loop (`V2_DRAW_TEXT`) already chose bold glyphs for span characters; it now
> also applies `and $DF` to those characters, which are all letters by
> construction. Typed case stays in memory, SAVE/LOAD, and RUN input.
> Matching remains case-insensitive via the unchanged `KEYWORD_TABLE`.
>
> Pre-existing, unchanged UX: the row being edited is drawn plain
> (not live-as-you-type); a keyword is capitalised/bolded when its row is
> settled or LISTed. Pre-existing cap: `KW_SPAN_MAX = 8` keyword spans per
> line -- keywords beyond the 8th on one line render as typed (the removed
> canonicalizer had no such cap; lines with more than 8 keywords are
> unusual, but this is a small behavioural difference to be aware of).
>
> ### Measured (assembled, `make build` + `tools/report_budget.py`)
>
> | | HOME free | EXROM free |
> |---|---:|---:|
> | With `V2_CANONICALIZE_KEYWORDS` (working tree at resume) | 173 B | 1,409 B |
> | Render-time replacement | 173 B | **1,566 B** |
> | Net | 0 | **+157 B recovered** |
>
> The new rendering logic costs about 42 B (string skip, identifier-boundary
> scan, REM stop, uppercase mask) against the removed 199 B, i.e. 79% cheaper,
> and it also fixes two latent defects of the old bolding scan (keywords
> bolded inside strings/REM text, and `To1` bolding its `To`). No RAM
> change; `V2_KW_TMP_OFFSET` is now used as a one-byte "matched token" cell.
>
> ### Validation (production ROM, `build/ts2068rom_zesarux.bin`)
>
> * Live, typed mixed case: `for i = 1 to 3 / Print i / next i / if i > 2 then
>   print "ok" else print "no" / endif`. Source bytes verified by memory dump
>   before and after `RUN`: exactly as typed (`for`, `Print`, `next`, ...).
>   `RUN` printed `1 2 3 ok`. `LIST` showed `FOR i = 1 TO 3`, `PRINT i`,
>   `NEXT i`, `IF i > 2 THEN PRINT "ok" ELSE PRINT "no"`, `ENDIF`, with only
>   keywords bold; `i` and string text keep typed case. A second program with
>   `Print i; "for to"; To1` / `rEm for next print` rendered `PRINT i; "for
>   to"; To1` and `REM for next print` (REM bold, comment untouched).
> * `tools/test_v2_kw_spans.py` (new): drives `V2_KW_DETECT_SPANS` directly in
>   the production ROM over 22 lines and compares the recorded spans:
>   FOR/TO/STEP/NEXT/IF/THEN/ELSE/ENDIF/PRINT/DIM/PROC/CALL/DEF/FN/GOTO/EXIT/
>   RANDOMISE, mixed case, doubled quotes, unterminated strings, `To1`,
>   `To$`, `x1for`, `forx`, `fo`, REM with keywords inside. **22/22 pass.**
> * `make check` clean; `make test` rc=0 (27/27 V2 standalone, editor auto
>   x2, storage named-load / extension x6 / autorun x4, smoke 9/9);
>   `rom/test_v2_chunk_refill_boundary.asm`, `rom/test_v2_chunk_boundary_
>   values.asm`, `rom/test_v2_for_first_token.asm` each border 4 (PASS). The
>   chunk-buffer implementation and the EOF-NUL handling in
>   `CHUNK_APPEND_ONE_RECORD` were not touched.
> * Not separately re-run: a SAVE/LOAD round trip of mixed-case source (both
>   operate on the stored bytes verbatim and the stored bytes are now
>   provably untouched by this feature; `storage_*` suites above pass).
> * Harness caveat: ZRCP keystroke injection drops characters intermittently;
>   every live program above was re-verified by memory dump rather than trusted.

Audit of three approaches for making the V2 editor's **authoritative source**
store recognized BASIC keywords in canonical uppercase (`print "Hello"` ->
`PRINT "Hello"`), while leaving identifiers, string contents, and REM/comment
text exactly as typed, and leaving the case-insensitive lexer/compiler
unchanged. Decision rule per spec: implement approach B only if it is
clearly cheapest (or essentially equal cost) versus A/C. B was found cheap
and safe and is implemented.

## Prior state (before this change)

- `rom/exrom_v2_compiler.asm` (`LEX_CLASSIFY_KEYWORD`, `KEYWORD_TABLE`) is
  already fully case-insensitive at compile time via `FOLD_UPPER` — this was
  never at risk and is **unchanged** by this work.
- `rom/exrom_v2_shell.asm` (`V2_KW_DETECT_SPANS`) already walks
  `KEYWORD_TABLE` (reused via `KTAB_GET_KEYWORD_TABLE`, no duplicate table)
  to find keyword spans for **bolding only**, at redraw/LIST time, on
  already-settled rows. It does not mutate anything.
- `V2_TOKENIZE` (`rom/exrom_v2_shell.asm`), called once per `ENTER` from
  `V2_COMMAND_LOOP`'s `.store` path, was a pure verbatim byte copy of
  `EDIT_LINE_BUF` into the stored-line record — confirmed by direct memory
  inspection (see Validation) that V2's stored/SAVEd source was exactly
  as-typed, in every case, before this change.
- V2's sibling V1 stack (`basic/basic.asm`) already does something similar
  in spirit (`BASIC_UPPERCASE_KEYWORD_PREFIX`, mutates the leading keyword of
  `EDIT_LINE_BUF` at `ENTER`) but that stack is not production (not reached
  by `Makefile`'s `build` target) and only covers the *first* keyword per
  statement, not every keyword on the line.

## A/B/C comparison

| | ROM cost | Mechanism | Meets "authoritative source becomes uppercase"? |
|---|---|---|---|
| **A** (current) | 0 (no change) | Bold spans only, recomputed every settled-row redraw/LIST | No — stored text is exactly as typed |
| **B** (implemented) | **+199 bytes EXROM, +0 bytes RAM**, one-time cost at `ENTER` | New routine, run once per commit, mutates `EDIT_LINE_BUF` in place before the existing verbatim copy into the stored record | Yes |
| **C** (display-only) | Would require teaching the render loop (`V2_DRAW_TEXT`/`V2_KW_OFFSET_BOLD`) a second, per-character case override, re-paid on **every** redraw/LIST of **every** settled row, forever — not a one-time cost | Screen shows uppercase; stored/SAVEd bytes stay exactly as typed | **No** — explicitly fails the actual requirement (SAVEd/LISTed authoritative source), and the user's own spec says not to prefer repeated redraw-time conversion over one-time canonicalization |

B wins outright: it is both cheaper in the metric that matters (one-time vs.
forever-repeated cost) and the only one of the three that actually satisfies
the stated product requirement. C was never a real contender once "the
*authoritative source*" was read literally — it only produces the right
*screen*, not the right *stored bytes*.

## Cheapest point found

`V2_COMMAND_LOOP`'s own `.store` label (`rom/exrom_v2_shell.asm`), reached
exactly once per `ENTER`-commit of a program line, immediately before the
existing `call V2_TOKENIZE`. This is EXROM-resident, the same file that
already hosts `V2_KW_DETECT_SPANS`'s keyword-matching logic and
`KTAB_GET_KEYWORD_TABLE`, so no new KTAB entry, no new cross-bank plumbing,
and no RAM-sysvar growth was needed — the new routine reuses
`V2_KW_WORD_START`/`V2_KW_SCAN_RESUME`/`V2_KW_WORD_LEN` (already-allocated
scratch, free at commit time since nothing else uses them then) and
`V2_KW_TMP_OFFSET` (declared in the R10 keyword-bolding sysvar block but
never actually consumed by `V2_KW_DETECT_SPANS` — repurposed here as the
one in-string toggle flag this needs, at zero extra RAM cost).

This confirms the architecture question in the spec directly: keyword
recognition already happens via one shared table (`KEYWORD_TABLE`) and one
proven word-scan shape, reused a third time here (compiler lexer, display
bolding, now commit-time canonicalization) — **no second keyword parser**
was introduced.

## Correctness gaps closed (required for B to be safe)

`V2_KW_DETECT_SPANS`'s existing word-scan (used only for cosmetic bolding,
so these gaps were latent/harmless there) is **not** safe to reuse verbatim
for a *mutating* pass, so the new routine fixes three things on top of the
same shape:

1. **String literals**: a `"` toggles an in-string flag; nothing inside a
   string is ever scanned as a candidate word. (The old bolding scan has no
   such awareness — `PRINT "FOR SALE"` would already have been incorrectly
   *bolded* under approach A; it would have been actively *corrupted* under
   a naive port of that scan to B.)
2. **REM**: the moment the word `REM` itself matches, the scan stops dead —
   everything after it is comment text, matching `COMPILE_PROGRAM`'s own
   REM handling (`rom/exrom_v2_compiler.asm`: "a REM line simply contributes
   nothing... no opcode emitted at all").
3. **Digit/`$`-suffixed identifiers**: the real lexer's identifier grammar
   (`LEX_SCAN_IDENT`-equivalent lines in `rom/exrom_v2_compiler.asm`) is
   `[A-Z][A-Z0-9]*[$]?`, but the old bolding word-scan only ever extended
   over `A-Z` — so an identifier like `To1` or `To$` would have its `To`
   prefix exactly match keyword `TO` by length+content. Already a latent
   cosmetic bolding bug under A; would have **corrupted the identifier**
   (`To1` -> `TO1`) under a naive B. Fixed by checking the real terminating
   byte: a digit or `$` immediately after the letter-run means this is a
   longer identifier, not a bare keyword, and the word is left untouched.

Editing a keyword into a non-keyword (or vice versa) needed no special-case
code: the whole line is re-scanned from scratch on every `ENTER`, with no
persisted per-position "this was a keyword" state anywhere, so it is
naturally idempotent and self-correcting (verified: `FOR` -> `FORM`).

## Implementation

- `rom/exrom_v2_shell.asm`: new `V2_CANONICALIZE_KEYWORDS` routine, called
  once from `V2_COMMAND_LOOP.store` right before `V2_TOKENIZE`.
- No changes to `rom/exrom_v2_compiler.asm` (lexer/compiler untouched —
  loaded/externally-produced lowercase source still compiles correctly,
  unaffected by this change since `FOLD_UPPER`/`LEX_CLASSIFY_KEYWORD` were
  never touched).
- No new RAM sysvars (scratch bytes reused, see above).

### Measured cost

- HOME free: 437 B -> **437 B (unchanged)** — all new code is EXROM-resident.
- EXROM free: 1,520 B -> **1,321 B** (-199 B).
- RAM: +0 bytes (reused existing scratch).

## Validation

All validation was performed against direct authoritative-source memory
inspection (program-text store at `PROG_AREA_START`/`PROG_END`,
`EDIT_LINE_BUF` at `$F228`), via `ts2068-debug` against the real production
`build/ts2068rom_zesarux.bin`/`build/exrom.sym` build — not just the screen.

| Typed | Stored (verified via memory dump) | Result |
|---|---|---|
| `print "Hello"` | `PRINT "Hello"\r` | keyword uppercased; string untouched |
| `for Counter=1 to 10` | `FOR Counter=1 TO 10\r` | both keywords uppercased; identifier case preserved |
| `print To1` | `PRINT To1\r` | `To1` left **exactly** as typed — digit-suffix boundary check confirmed working; this was the critical edge case |
| `rem this is for testing` | `REM this is for testing\r` | only the leading `REM` uppercased; `for` inside the comment left lowercase |
| `print "FOR SALE"` | `PRINT "FOR SALE"\r` | string content unaffected (already uppercase, so also re-verified with... |
| `print "for sale"` | `PRINT "for sale"\r` | ...a lowercase string: confirmed byte-for-byte, including the lowercase `for` inside quotes, via a direct `EDIT_LINE_BUF` write + `ENTER` to rule out a keystroke-injection timing artifact seen on the first (flaky) attempt |
| Existing `FOR Counter=1 TO 10`, edited to insert `M` after `FOR` | `FORM Counter=1 TO 10\r` | re-editing a keyword into a non-keyword does not corrupt it; `FORM` is correctly left plain/unbolded on screen too |

Additional checks:
- `make check` (full static suite: `check_asm.py`, `check_docs.py`,
  `check_ram_aliases.py`, `check_storage_contract.py`,
  `check_commit_validation.py`, `check_basic_source.py` over
  `tests/*.txt`/`demos/*.txt`, z80sim dispatcher/sprite tests,
  `build_smoke_roms.sh`) — all passed, 0 errors.
- `tools/run_v2_standalone_tests.sh` — **27/27 PASS**, including the
  `case_insensitive` component test (compiler-side case-insensitivity
  unaffected).
- RUN sanity check: a fresh lowercase-typed program
  (`for Counter=1 to 3` / `print Counter` / `next Counter` / `run`)
  compiled and executed correctly, printing `1 2 3`.
- LIST/EDIT display: canonicalized keywords render bold+uppercase on
  settled rows as before (pre-existing `V2_KW_DETECT_SPANS` bolding, now
  operating on already-uppercase stored text); `To1`/`FORM` correctly never
  bold.
- SAVE/LOAD round-trip: not independently runtime-tested this pass — both
  operate on the already-canonicalized stored record bytes verbatim
  (`V2_LOAD_EDIT`'s own copy-to-`EDIT_LINE_BUF` loop and the storage
  save/load path are unchanged, byte-copy-only code), so no new risk is
  introduced, but this was not separately re-proven live.

### Edge case discovered during validation (test-harness, not ROM)

`ts2068-debug`'s ZRCP keystroke-string injection (`type`) dropped one
character on two separate attempts at typing `print "for sale"` (different
character dropped each time — `sal` then `fr sale`), while the canonicalized
`PRINT` and the untouched quoted content were correct in both cases. This
reproduced as a keystroke-injection timing artifact, not a logic defect: the
scan never mutates bytes inside `"..."` by construction (no code path exists
for it to drop or alter a character there), and a direct `EDIT_LINE_BUF`
memory write bypassing keystroke injection entirely produced the correct,
deterministic result. Not a 2068-Leap ROM issue.

## Out of scope (per spec, not touched)

No changes to case-insensitive language semantics, no identifier
uppercasing, no GRAPHICS/capacity work, no startup chime/status bar changes,
no unrelated optimization, no dormant-architecture audit, no R11 work. Not
committed.
