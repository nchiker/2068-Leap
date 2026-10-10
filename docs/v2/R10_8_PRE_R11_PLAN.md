# R10.8 — Pre-R11 Plan: Priorities, Sequence, Budgets, Gates

**Status: PROPOSAL for owner review. Nothing here is implemented.** No R10.9, R10.10 or R11 work has
begun; nothing is committed. Inputs: [`R10_8_GAP_ANALYSIS.md`](R10_8_GAP_ANALYSIS.md) (findings `D*`, `R*`, `L*`),
[`R10_8_EDITOR_USABILITY_AUDIT.md`](R10_8_EDITOR_USABILITY_AUDIT.md) (`U*`, `ED*`, `I*`),
[`R10_8_FEATURE_MATRIX.md`](R10_8_FEATURE_MATRIX.md).

All ROM/RAM figures are **[E] estimates** from reading the code that would change; none has been
assembled. Current headroom (measured): **HOME 546 B, EXROM 1,385 B**, package window spare 229 B (SHAPES).
Principle: *make the existing system reliable and pleasant before adding capability*; preserve the current
memory architecture; no general-purpose memory manager; do not reclaim the ~450 B of upper-RAM V1 leftovers
without a demonstrated need (none found).

## 1. Prioritised findings

### 1.1 MUST FIX before R11

R11 freezes architecture and interfaces. An item is MUST if it is a confirmed correctness/data-loss
defect, a serious usability failure, or an interface that would be hard to change after the freeze.

| ID | Finding(s) | Change | Subsystem | HOME | EXROM | RAM | Reuse / smaller alternative | Impl. risk | Regression risk |
|---|---|---|---|---:|---:|---:|---|---|---|
| **M-1** | D1, D2 — tape failure exits reported as success; failed VERIFY erases program | Restore the stock convention in `STORAGE_RECEIVE_BLOCK` (success = carry **set**: final test becomes `ld a,h / cp 1 / ret`), flip the two caller tests (`STORAGE_LOAD` `.header_search`, `.data_recv`) and the fake transport (`rom/exrom_storage_test.asm`); in `V2_LOAD.failed` skip the wipe when `STORAGE_VERIFY_MODE` is set | `kernel/storage/storage.asm`, `rom/exrom_v2_shell.asm` | 0 | −4…+10 | 0 | Smaller alternative: `scf` at the four failure exits (+4 B) — rejected as it perpetuates the project/stock inversion | **M** (flags only, but timing-critical code) | **H** for tape; needs Fuse/physical round trip |
| **M-2** | D3 — silent compile truncation; unclosed `(`; `FOR` without `NEXT` | In `COMPILE_PROGRAM` require `TOK_EOF` after the statement list; in `.after_stmt` require `:`/EOF/closing keyword (`ELSE ENDIF ENDP`) else raise a *new* "unexpected token" code; require `)` in `COMPILE_FACTOR`; error if the compile stack still holds an open `FOR` at EOF | `rom/exrom_v2_compiler.asm` | +25…+45 | +10…+15 (message) | 0 | smallest useful subset = the `.after_stmt` terminator check alone (+10…+14 B), which catches every D3 family seen | **L–M** | **M**: stricter compile may reject programs that "worked" by accident → release-note it; run all 38+19 tests |
| **M-3** | D4 — wrong error line | Lexer increments a `LEX_LINE` counter when it consumes a record separator; `V2_JUMP_TO_ERROR_LINE` sets `CUR_EDIT_INDEX = LEX_LINE`; delete the chain walk | compiler + shell | +10…+15 | −30…−40 (net; the old chain walk is 45 B measured) | +2 | none needed | **L** | **L** |
| **M-4** | D5, D5b — no BREAK for running programs; BREAK key inserted as text | ISR sets `VM_BREAK` when `IO_DECODE_KEY` returns `KEY_BREAK`; `OP_JMP`, `OP_FOR_NEXT` (and `PAUSE`) test it and raise `BREAK` through the existing `VM_ERR_*` path; `EDITOR_LOOP` ignores unhandled codes `< $20` | `kernel/interrupt`, `rom/exrom_v2_vm_core.asm`, editor | +20…+35 | +6…+12 | +1 | testing only on backward branches costs ≈ 7 T per jump (≈ 1 % on an empty loop); a check in every opcode was rejected (≈ 20 T/op) | **L** | **L** |
| **M-5** | D6 — array `LOAD` unusable | **Owner decision** (see §4): (A) *fix* via name-keyed "preloaded array adoption" (VM_INIT keeps a preload list; `OP_DIM` adopts) — [E] HOME +120…+200, EXROM +20…+40, medium risk in the allocation path; (B) *retire* `SAVE/LOAD … ARRAY` for V2.0, reserve header type 8, delete `V2_SAVE_ARRAY` (119 B), `V2_LOAD_ARRAY` (187 B), `V2_SCAN_ARRAY_NAME` (100 B) — **406 B measured from `build/exrom.sym`** — plus the two messages (32 B), the `ARRAY` keyword and the qualifier/dispatch branches ([E] 20–60 B) — HOME 0, **EXROM −430…−470**, low risk; (C) defer by making `LOAD … ARRAY` print a clear "NOT USABLE YET" — pointless for a freeze | shell + VM | A: +120…+200 / B: 0 | A: +20…+40 / B: −430…−470 | A: +4 | **Recommendation: B**, revisit as a *program-level* statement (`LOAD "f" DATA a()` executed by the VM at the `DIM`) after R11 (cost [E] ≥ 150 B HOME, so not before the freeze) | A: **M–H**, B: **L** | A: **M**, B: **L** |
| **M-6** | R1, R3, A1–A7 — package ABI bound to absolute HOME addresses and sysvar layout; unversioned program tape | (a) Add a **package service jump table** in the free KTAB padding (`$0091–$00FF`, 111 B) for the 16 HOME routines packages use (`EXT2_REGISTER`, `GFX_SET_MODE`, `GFX_CHAR_TO_FONT_OFFSET`, `GFX_SPRITE_CAPTURE/DRAW`, `MEM_LINE_FIRST/NEXT`, `MATH_MULTIPLY16/NEGATE16`, `GFX_PLOT_CLIPPED`, `GFX_READ/WRITE_PIXEL`, `VM_NUM_TO_TEXT`, `VM_STR_ADDR`, `VM_CLAMP_Y191`, `VM_COMPUTE_PRINT_ATTR` = 48 B) and rebuild packages against the table only; (b) pin the package-visible RAM (`EXT_CALL_ARG0–4`, `VM_ERROR_CODE`, `VM_HALTED`, `CURRENT_*`, `GFX_FILL_*`/`GFX_CIRCLE_*`/sprite scratch) at fixed addresses with `ASSERT`s; (c) bump `V2_PACKAGE_ABI_VERSION` to 2 and add a table-version byte check; (d) put a *program format version* in the program header's autostart word and reject unknown versions in `V2_LOAD`; (e) write the ABI down (`docs/v2/PACKAGE_ABI.md`) incl. chunk-6 rules (gap §4.6) | `include/v2_ktab.inc`, `build/v2_crossbank.inc`, `tools/write_v2_crossbank.py`, packages, shell | **0** (uses padding) | +25…+40 | 0 | smaller alternative: only add a ROM-build signature check (detects, does not fix) | **M** (touches every package) | **M**: existing package tapes become invalid once (intentional, version bump) |
| **M-7** | U1, U2, U3, U7, ED3 — typing latency 0.3–0.6 s/key; no fast navigation; commands only at last line | Editor audit I1–I4: selective redraw (active line; two-line move; sticky viewport), navigation keys (page/top/bottom/line start/end), run-from-anywhere key, reject command words typed on stored lines | `rom/exrom_editor.asm`, `rom/exrom_v2_shell.asm`, `kernel/io/io.asm`, `include/keys.inc` | +40…+70 | +250…+400 | +4…+8 | existing LEFT/RIGHT fast path, `V2_DRAW_TEXT`, `GFX_CLEAR_ROW_TEXT`, wrap tables. Smaller first cut: I1 + top/bottom keys only (HOME +20…+30, EXROM +120…+180) | **M** (`V2_REDRAW` is central) | **M**, mitigated by a **differential screen-hash oracle** (selective vs full redraw) |
| **M-8** | D9 — edits discarded on UP/DOWN; typed line lost on `PROGRAM FULL` | Commit-on-navigate when the buffer differs from the record; keep buffer/cursor on `PROGRAM FULL` | shell | 0 | +15…+30 | 0 | | **L** | **L** |
| **M-9** | D7 — FILL silently incomplete | Package-only: set an overflow flag in `SHAPES_GFX_FILL_PUSH`; when the stack empties with the flag set, rescan the visited bitmap for painted pixels with an unpainted fillable neighbour, push, repeat until a pass paints nothing; add the six adversarial scenarios to `tools/v2_fill_check.py` | `rom/ext_v2_shapes_module.asm` | 0 | 0 (package **+60…+100 B** of 229 B spare) | 0 | enlarging the stack into `$DC00–$DFFF` only moves the threshold | **L** | **L** |

### 1.2 SHOULD FIX before R11

| ID | Finding(s) | Change | HOME | EXROM | RAM | Notes |
|---|---|---|---:|---:|---:|---|
| **S-1** | D8 — `CLEAR` half-implemented | `CLEAR` = zero the carved variable/array-pointer block (`VARS_START…V2_SOURCE_END`; the control stack is *below* it) and reset `ARRAYS_END`; **stop clearing packages** | 0…+10 | −6…0 | 0 | exact stock-like "clear variables" semantics |
| **S-2** | D10 — float display truncates | add half-unit rounding at the 4th decimal in the float→string path (`BASIC_FLOAT_TO_STRING_EXROM`, `rom/exrom_format.asm`) | 0 | +20…+40 | 0 | root cause not traced yet — first step of the work |
| **S-3** | D11 — silent integer wrap | owner policy (§4): promote to float on `+ - *` overflow (reuses the existing float path; `jp pe` after add/sub, high-word test for `*`) **or** raise `OVERFLOW`; integer literals > 32767 → float literal or compile error | +20…+40 | +10…+20 | 0 | spec says "hybrid promotion" |
| **S-4** | U4, R8 — opaque messages | show error code/name; distinct messages for source/bytecode/array/stack memory; `FREE nnnn` in the status bar (editor audit I9) | 0 | +80…+150 | 0 | strings dominate the cost |
| **S-5** | U6 — display/attribute state leaks | reset mode/colours at RUN start and on return to the editor (I8) | 0 | +15…+25 | 0 | reuse the init block at the top of `V2_COMMAND_LOOP` |
| **S-6** | spec gap — string `<>`, `>=` (and `>`, `<=`) | `<>` = `EQ`+`NOT`; `>=` = `LT`+`NOT`; `>`/`<=` need an operand-order swap | +15…+30 | 0 | 0 | specified as MUST HAVE in `V2_LANGUAGE_SPEC.md`; only `=` and `<` exist |
| **S-7** | R4 — production-ROM test gap | headless tests on the production image for: editor key paths (inject `KBD_LASTK/KBD_KEYHIT`), the differential screen hash, tape-transport failure injection (the D1/D2 recipes), package install+run (SHAPES, SPRITE, MODE), `MODE 1` return; add `sprite_module` to the runner; repair or retire `ext_concurrent` | 0 | 0 | 0 | gating for M-1, M-7 |
| **S-8** | DD-1…DD-11 — documentation | new V2 language reference replacing V1-era sections; mark/retire `CURRENT_LIMITATIONS.md`, the stock matrix (superseded by this matrix), README test counts and package list; error-code table in one place | 0 | 0 | 0 | prerequisite for freezing "the language" |
| **S-9** | R5, gap §6.G — V1 validation | decide V1 support status; if supported, run `make test-legacy` once after R10.10 **with owner authorisation** | 0 | 0 | 0 | not now |
| **S-10** | ED4/R9 — cursor can vanish on long wrapped lines | when the active line would extend past row 22, shift the viewport up | 0 | +10…+20 | 0 | part of I2's viewport policy |

### 1.3 DEFER (after R11, or only on demonstrated need)

| ID | Item | Why deferred | Cost note [E] |
|---|---|---|---|
| X-1 | Runtime error line numbers (I11) | needs a design (IP→line table or `OP_LINE` ops; ops would slow loops 10–30 %) | HOME +30…+60, EXROM +40…+80, ~2 B/line of pool |
| X-2 | Variable inspection after RUN / `CONT` | changes the "every RUN re-zeroes" model | large |
| X-3 | Multi-item `PRINT` (`;` `,`), `PRINT AT/TAB`, `INPUT "prompt"` | language extension; the most common BASIC idiom, so **top post-freeze language item**; M-2 turns today's silent failure into a clear error | HOME +60…+120 |
| X-4 | Single-line `IF … THEN stmt`, `ELSEIF` | design choice (L1); `ELSE IF` works | HOME +40…+80 |
| X-5 | `GOSUB/RETURN`, `DATA/READ/RESTORE`, `MERGE`, `INSTR`, 2-D arrays, `ASN ACS ATN EXP LN`, `^` | recorded product decisions / large | — |
| X-6 | `STICK` joystick, `IN`/`OUT` | new capability; `STICK` was removed R10.7; small but never scoped | HOME ~+30 + exposure |
| X-7 | Two packages resident at once | needs a larger or relocatable window | RAM/ROM significant |
| X-8 | Decompiler fragment width; float-behaviour round trip | test-only (L10) | test-harness EXROM +15 |
| X-9 | Faster per-line draw (keyword-span caching, faster `GFX_PUTCHAR`) | optional after I1/I2 | — |
| X-10 | Editor search, block mark/copy/move, undo, word movement, `NEW/LOAD` confirmation | enhancements (U8, U10) | EXROM +30…+120 each |
| X-11 | Compile progress/abort, faster symbol lookup (R7) | only matters for large, many-symbol programs; BREAK (M-4) covers abort of RUN, not compile | — |
| X-12 | Reclaiming the ~450 B upper-RAM V1 leftovers | no demonstrated need; V1 coupling unverified | — |

## 2. Dependencies

```
S-7 (test infrastructure) ─┬─> M-1 ─┐
                           ├─> M-7 ─┤
M-6 (ABI pin, versions) ──────────────> must precede any other HOME-moving change that packages see
M-2 ──> M-3 ──> (M-7: status/cursor code shares V2_JUMP_TO_ERROR_LINE)
M-5 decision ──> (if A: after M-6; if B: any time, frees EXROM for M-7)
M-1 + M-6(d) tape-header version: ONE physical tape validation round
M-4, M-8, M-9: independent
S-3 policy ──> S-2 ordering irrelevant; S-6 independent
```

Rationale for ordering: package-visible addresses move whenever HOME changes, so the ABI must be pinned
**first** (otherwise every later step re-breaks every package tape); tape fixes and tape-header versioning
share one physical validation round; editor work needs the differential oracle built before it starts.

## 3. Recommended sequence

### R10.9 — "Make it trustworthy" (correctness, safety, interfaces)

| Step | Items | Effort [E] | Validation gate |
|---|---|---|---|
| 9.0 | S-7 (partial): production test scaffolding — key injection harness, screen-hash differential helper, tape-failure injection tests (D1/D2), package install helper | 1 session | the new tests **fail on current `main`** (negative control) and are in `make test` |
| 9.1 | M-6: package service table + pinned RAM block + ABI v2 + program-format version + `docs/v2/PACKAGE_ABI.md` | 1 session | rebuild all five packages; production package-run tests pass; HOME/EXROM budget unchanged for HOME |
| 9.2 | M-2 → M-3: compiler diagnostics, error-line counter | 1 session | new negative tests (every D3 family now errors); `t23` error-line oracle passes for 5/25/65-char lines; 38+19 existing tests unchanged |
| 9.3 | M-4 (+D5b), M-8 | 0.5 session | BREAK test (`top: GOTO top` returns to the editor), edit-preserve tests |
| 9.4 | M-1 (tape) | 0.5 session + **owner** | D1/D2 injection tests pass; **physical/Fuse**: SAVE→LOAD round trip, dropout, SPACE abort, VERIFY match/mismatch/checksum, EXT and program tapes with the new header |
| 9.5 | M-9 (FILL) | 0.5 session | extended `v2_fill_check.py` (adversarial set) 16/16 |
| 9.6 | M-5 (per owner decision) | B: 0.5 / A: 2 sessions | B: grep shows no references; budget +EXROM; A: array LOAD → RUN round trip test |
| 9.7 | S-1 (CLEAR) | 0.25 session | `t22` inverted |
| **Close** | | | `make check`, `make test` green; budget report; **HOME free ≥ 350 B, EXROM free ≥ 800 B** (proposed floor); no new unexplained diffs in `git diff --stat` beyond planned files |

Estimated R10.9 budget [E]: HOME +55…+105 B (M-2, M-3, M-4, S-1); EXROM **−470…−360 B** with M-5 = B (i.e. net
*recovered*; +21…+117 B with M-5 = A); RAM +3 B; package +60…+100 B (M-9).

### R10.10 — "Make it pleasant" (usability, polish, documentation)

| Step | Items | Effort [E] | Validation gate |
|---|---|---|---|
| 10.1 | M-7 stage 1: I1 selective redraw (typing), I5/I6 if not done | 1 session | differential screen-hash 0 mismatches over scripted sessions; typing redraw ≤ 120 k T (vs 1.0–2.1 M T today) |
| 10.2 | M-7 stage 2: I2 viewport + two-line moves, I3 navigation keys, I4 run-from-anywhere, S-10 | 1.5 sessions | UP/DOWN in-window ≤ 200 k T; page/top/bottom boundary tests; command-on-stored-line rejected |
| 10.3 | S-4 + S-5: messages with codes, `FREE` in status, display reset | 1 session | message-selection table test; `MODE 1` return test; second-run attribute test |
| 10.4 | S-3 (policy), S-2, S-6: numerics and string compare | 1 session | `n1/n2`-style display oracle: `SIN(30)`→`0.5000`, `0.1+0.2`→`0.3000`, `PI()`→`3.1416`; overflow tests per policy; string-compare tests |
| 10.5 | S-8 documentation reconciliation; S-9 decision | 1 session | `make check` doc checks; DD-1…DD-11 closed |
| **Owner** | physical keyboard/ergonomics trial of the key set, flicker/feel trial, tape round trip (§5) | — | sign-off list in §5 |
| **Close** | | | `make check`, `make test` green; **HOME free ≥ 250 B, EXROM free ≥ 500 B**; freeze checklist (§6) complete |

Estimated R10.10 budget [E]: HOME +75…+140 B, EXROM +385…+655 B, RAM +4…+8 B.

### Combined ledger [E]

| | Now (measured) | After R10.9 | After R10.10 (all MUST+SHOULD) |
|---|---:|---:|---:|
| HOME free | 546 | 441…491 | **301…416** |
| EXROM free, M-5 = B (retire array LOAD/SAVE) | 1,385 | 1,745…1,855 | **1,090…1,470** |
| EXROM free, M-5 = A (fix) | 1,385 | 1,268…1,364 | **613…979** |
| HOME free, M-5 = A | 546 | 241…371 | **101…296** (A adds ≈ 120…200 B) |
| Sysvar/RAM added | — | +3 B | +7…+11 B (28 B free in the `$BE84–$BED7` gap) |
| Package window spare (SHAPES) | 229 | 129…169 | same |

Option A therefore consumes most of the HOME safety margin (to ≈ 100–300 B free), which is the main budget
argument for B before the freeze. **These are estimates; the first step of every item is to assemble and measure.**

## 4. Decisions requested from the owner

| # | Decision | Recommendation |
|---|---|---|
| 1 | **Array tape (D6):** fix (A), retire for V2.0 (B), or defer | **B**; revisit as a program-level statement after R11 |
| 2 | **Integer overflow (D11):** promote to float, or raise an error; out-of-range literals | promote (matches the spec's hybrid-numeric intent); literals > 32767 become float literals |
| 3 | **Strict compile (M-2):** accept that programs which only worked because trailing junk was ignored will now error | yes; announce in release notes |
| 4 | **Key set:** approve the proposed chords (SYMBOL+Q/A/W/S/SPACE, CAPS+4/9) subject to a physical typing trial | approve for implementation; freeze only after the trial |
| 5 | **V1 status:** supported product, or "assembles only" | "assembles only" unless there is a user need; then one authorised `make test-legacy` after R10.10 |
| 6 | **PRINT multi-item (X-3)** pre- or post-freeze | post-freeze, but first in the queue |
| 7 | **Physical tests:** who runs them and when (§5) | owner, interleaved with R10.9.4 and at R10.10 close |
| 8 | **Commit policy for the audit documents** | not committed; awaiting authorisation |

## 5. Physical-hardware tests required (cannot be done headless)

| When | Test | Gate for |
|---|---|---|
| R10.9.4 | SAVE→LOAD→VERIFY round trip of a program (small and ≈ 6 KB) on a real recorder/line-in; deliberate dropout; SPACE abort; wrong-name tape; extension tape; (if A) array tape | M-1, M-6(d) |
| R10.9.3 | BREAK of a `GOTO` loop; BREAK keycap matrix position if a separate BREAK key exists | M-4 |
| R10.10.1–2 | typing 20 characters at normal speed; held-key repeat on UP/DOWN; flicker; the proposed chords (ergonomics, accidental activation) | M-7 |
| R10.10.3 | `MODE 1`/hi-res return; ULAplus/PALETTE on supporting hardware | S-5 |
| any | contention-adjusted redraw time; `FILL`/`CIRCLE` speed; AY `SOUND`; boot chime; printer (`LPRINT`/`LLIST`) | information |

## 6. R11 freeze-readiness checklist (proposed definition)

1. Package ABI v2 documented and pinned (service table, RAM block, chunk-6 rules); all packages rebuilt.
2. File formats versioned and documented: program, extension, array (or reserved/retired).
3. A single authoritative error-code table; compile error `D3` class eliminated; error line exact.
4. Production-ROM tests cover editor keys, tape-failure injection, packages, display-mode return.
5. BREAK, edit-preservation and navigation in place; typing latency ≤ 120 k T on the production ROM.
6. Language reference rewritten for V2 (DD-1…DD-11 closed); stale documents marked.
7. Budget floors met (HOME ≥ 250 B, EXROM ≥ 500 B free); sysvar layout assertions in place for pinned addresses.
8. Physical-hardware sign-off list (§5) completed or each open item explicitly accepted.

## 7. Explicitly *not* recommended

* A general-purpose heap/workspace manager (no demonstrated need; R10.7 already delivered bounded arenas).
* Recovering the upper-RAM V1 leftovers (`$F100` region) — safety unproven, no use identified.
* Adding language features (multi-item PRINT, string slicing, 2-D arrays, GOSUB) *before* the correctness
  and usability items above; they are queued in §1.3.
* Changing the bytecode format, VM opcode numbering, or compile/run memory layout for any item above —
  every proposed fix is local to a routine, a package, or a jump-table slot.

## 8. Stop point

The audit ends here. **No R10.9/R10.10/R11 change will be made until the owner reviews this plan and the
decisions in §4.** The four R10.8 documents are untracked in the working tree and are not committed.
