# R10.9 Phase 2D — strict compilation and exact compile-error line

**Status:** implemented on top of `6789f36` (Phase 2C), committed locally on `v2-development`, **not pushed** (the Phase 2C checkpoint was pushed
at the start of this phase, `origin/v2-development` = `6789f36`; nothing from Phase 2D has been). Evidence tags: **[M]** measured on the real
production image through the project's harness, **[S]** read from source. Everything below is **emulator-tested**; nothing is hardware-qualified.

Work-sequence step **2.1** (M-2 → M-3), repairing **D3** (silent partial compilation) and **D4** (wrong error line).

## 1. What was wrong [S][M]

* **D3.** `COMPILE_STATEMENT_LIST` ended compilation "cleanly" on any token it could not dispatch, and `.after_stmt` ended it on any token that was
  not `:`. A stray `ENDIF`, trailing text, a missing `:` between two statements, `PRINT x; x`, `x = 7 MOD 2`, `a$(2 TO 3)`, a leading line number,
  a `'` comment, a doubled quote… all stopped the compiler at that token with `COMPILE_ERROR_CODE = 0`: the program ran (the part before the
  token), the rest was dropped without a word. `(` had no `)` check, a `FOR` could stay open at end of source, an unterminated string literal swallowed
  the following source lines. (Measured side effect: demo files whose first line is a V1 `;;` comment "compiled" to an *empty* program.)
* **D4.** `V2_JUMP_TO_ERROR_LINE` walked the line store to the record named by `CHUNK_CUR_REC_PTR`, the record most recently *appended* to the 264-byte
  rolling source window. The lexer keeps ≥ 128 bytes of look-ahead, so that record is up to several lines past the failing token: with five-character
  lines every error landed on the last line, with 29-character lines 3–5 lines late, with 69-character lines two lines late (measured Phase 1: 12 of 15 matrix cases wrong).

## 2. What was built

| Area | Change |
|---|---|
| Source-line counter | `LEX_LINE` (2 B, the former `CHUNK_CUR_REC_PTR` cell, so no RAM layout change) counts line ends as the lexer consumes them. Bits 0–14 = zero-based index of the line the lexer is on = the line-store index; bit 15 (`LEX_NEWLINE_PENDING`) = "a line end was consumed and not yet counted". A **CR token** sets the flag and the **next** token fetch applies it, so while the CR itself is the current token (`x = 1 +` cut off at its line end) the counter still names its own line. `COMPILER_INIT` zeroes it. |
| Continuation lines | A record that ends in `:` used to get no CR (colon continuation). `CHUNK_APPEND_ONE_RECORD` now appends an **LF** (`$0A`) there; `LEX_SKIP_SPACES` treats it as white space that raises the same pending flag, so every record contributes exactly one line end and the count is the line-store index. A CR and an LF are never adjacent (an LF always follows a `:`). |
| Error line | `V2_JUMP_TO_ERROR_LINE` is now `CUR_EDIT_INDEX = LEX_LINE & $7FFF` and falls through into `V2_SET_EDIT_FROM_INDEX`. The record-chain walk and the `CHUNK_CUR_REC_PTR` store in `CHUNK_APPEND_ONE_RECORD` are gone. An error found at end of source (index = number of lines) puts the cursor on the empty append line after the last one (§5). |
| Statement terminator | `.after_stmt` accepts only `:`/line end, end of source, `ENDP`, `ELSE`, `ENDIF` after a statement; anything else raises **error 64**. The dispatcher's fall-through (a token that starts no statement) raises 64 instead of returning. |
| End of program | `COMPILE_PROGRAM` requires the statement list to have stopped at **end of source** (a stray `ENDP`/`ELSE`/`ENDIF` raises 64) and that no `FOR` frame is open (**error 65**, `FOR` without `NEXT`; it uses the existing compile stack, `CSTK_TOP`). |
| Parentheses | `COMPILE_FACTOR`'s `(`…`)` now verifies the `)` (**error 66**). All other `)` sites already did. |
| Strings | `LEX_SCAN_STRING` stops at any control character (NUL/CR/LF): an unterminated string is a `TOK_UNKNOWN` token and error 64 on its own line. A string now lies inside one record, so the R10.7 mid-scan `CHUNK_REFILL` logic (needed only for strings spanning records) was **deleted**. |
| `REM` | Stops at LF as well as CR (a `REM` line ending in `:` no longer comments out the next line), and returns to the dispatcher loop, since the next token follows with no `:`. |
| Message | Error 64 → `UNEXPECTED TOKEN` (`V2_MSG_UNEXPECTED`, `V2_COMPILE_MSG`). 65 and 66 show `SYNTAX ERROR`. |

Not changed: grammar, bytecode, token set, the existing error codes, any ABI-pinned cell or service slot (`check_package_abi.py` passes), the editor, `BREAK`, the Array Store.
`tools/write_v2_crossbank.py` is unchanged (the shell reads `LEX_LINE` from `include/v2_layout.inc`).

## 3. Defects repaired

| ID | Before | Now |
|---|---|---|
| D3 | 18 malformed-program families compiled "successfully" | all 18 are compile errors with a fixed code (64 / 65 / 66), and the program does not run |
| D4 | cursor on a later line (12 of 15 matrix cases wrong) | cursor on the exact failing line in all 15 cases and in 14 further boundary cases |

## 4. Compiler compatibility changes (also in `COMPATIBILITY_BREAKS.md`, Break 4)

1. Programs that were silently truncated now fail at `RUN` with a compile error. Valid programs and bytecode are unchanged: all 38 standalone component programs, the 19 production checks and the
   98-case Array Store gate pass without modification of their *programs*.
2. A string literal cannot span lines. (Pre-2D an unterminated string swallowed the next lines, CR bytes included; nothing documented relied on it. Two standalone tests did exercise it by construction and were re-engineered, §6.)
3. A `REM` ending in `:` ends at its line.
4. A `)` is required to close `( expression`.
5. `PRINT a; b` / `PRINT a, b` remain unsupported (step 2.8 is an assessment only), but are now an error instead of a silent truncation.

## 5. Limitations and observations

* **End-of-source errors do not name the opening statement.** An unclosed `FOR` (65), `PROC` (16), block `IF` (9) and an undefined `GOTO`/`CALL` label (7, checked after the last statement) can only be detected at
  end of source; the cursor goes to the empty line after the last one (the place the missing `NEXT`/`ENDP`/`ENDIF`/label is typed). Recording the opening line (a 2-byte field per `FOR` frame, a stack slot per `PROC`/`IF`, a line per forward
  `GOTO` fixup) was not done: it is a separate, measurable cost (≈ 20–60 B HOME) and no acceptance case requires it. Candidate follow-up.
* Error codes 65 and 66 share the `SYNTAX ERROR` text; only 64 has its own message.
* Immediate-mode (`: …`) compile errors still do not move the cursor (unchanged by design: there is no stored line).
* **Observed, not caused by this phase, not fixed:** `CALL p(FN f(x))` (a `DEF FN` call as the argument of a `PROC` call) passes `0` on both the Phase 2C baseline and this build (verified on a pristine `git archive` of `6789f36`).
  `demos/showcase.txt` does not compile on either build (`MOD(N,15)` is not a V2 function); the corrected line number (34) is reported where the baseline said 41.
* `LEX_LINE` is 15 bits (32 767 lines); the line store cannot approach it.

## 6. Tests

* `tools/v2_prod_regress.py` (production gate, **115 cases**: 57 pre-existing + 58 new) holds every former D3/D4 case plus boundary cases. D3: all 18 families assert the exact error code *and* that nothing executed; 2 already-correct controls; 8 further cases
  (valid colon line, a program using every closer / continuation / label-with-statement / `REM …:` / `:` inside a string, the `UNEXPECTED TOKEN` message, unterminated string ×2, `:`/keywords in a string, `REM …:`, fail-then-good recompile).
  D4: the 15-case matrix; continuation lines before / on the failing line; trailing junk first/last line; an expression cut off at its line end; blank and `REM` lines; label lines; a stray `ENDIF`; an unclosed `(`; the four end-of-source errors
  (+ one after a last line ending in `:`); and a typed `run` through the real key path (cursor *and* the loaded edit line).
* `tools/v2_known_defects.py` no longer contains D3/D4 (36 cases moved: 18 + 3 + 15). Remaining strict XFAIL: **14** — D5b, D5 (BREAK), D7 ×5 (FILL), D9a, D9b, D11 ×4 (overflow), U6 (display reset); 3 positive controls.
* Standalone: `rom/test_v2_chunk_refill_boundary.asm` TEST3 (an unterminated string is now an error on line 0) and TEST4 (`LEX_LINE` instead of `CHUNK_CUR_REC_PTR`) rewritten; `rom/test_v2_chunk_boundary_values.asm` TEST A re-engineered
  (a closing quote at a refill boundary can no longer occur; it now proves a maximal 127-byte one-record string compiled right after a refill).
* Baseline for comparison, measured before any change: 6 PASS + 30 XFAIL for the D3/D4 cases of the known-defect suite.

## 7. ROM budget [M] (`make budget`)

| | HOME free | EXROM free |
|---|---:|---:|
| Phase 2C | 585 | 788 |
| **Phase 2D final** | **565** (−20) | **802** (+14) |
| Reserve targets | ≥ 350 ✔ | ≥ 800 ✔ |
| Work-sequence estimate [E] | −35…−60 | +20…+25 |

HOME: `LEX_SCAN_STRING` shrank from 108 B to 47 B (−61 B, the mid-scan refill block and its duplicate loops are gone); the line counter, the strict checks, the `)` check, the end-of-program check and the new error codes add
81 B, net +20 B. EXROM: `V2_JUMP_TO_ERROR_LINE` shrank from 45 B (the chain walk) to 8 B (−37 B); the `UNEXPECTED TOKEN` text (+17 B) and its compare in `V2_COMPILE_MSG` (+6 B) cost 23 B; net −14 B,
i.e. 14 B freed. (An earlier variant kept the CR adjustment and an end-of-source clamp in the shell, 767 B free; moving the CR counting into the lexer and ending the cursor on the append position put 32 B back.)
Z80 Shrink: the `z80_pattern_scan` text scanner has no model of HOME/EXROM banking, so candidates were evaluated by hand against flags, registers and the ABI; accepted: lazy line counting, LF handled with the same flag (no separate helper),
fall-through instead of `jp`. No approved feature was removed.

## 8. Final qualification [M]

One full `make test` on the final tree (exit status 0, no Fuse/X11: `make -n test | grep -ci fuse` = 0; `make test-legacy` and the V1 Fuse suite were **not** run), after `make check` (rc 0, including `check_package_abi.py`:
"ABI 2.0 — 16 service slots, 34 pinned cells, 11 constants, 5 packages: all checks passed", `check_storage_contract.py`, `check_ram_aliases.py`, `check_docs.py`, `check_test_targets.sh`):

| Check | Phase 2C | Phase 2D |
|---|---|---|
| Headless smoke ROMs | 9/9 | **9/9** |
| V2 standalone (component tests) | 38/38 | **38/38** (two tests re-engineered, §6) |
| `v2_production_checks.py` | 19/19 | **19/19** (`FAILURES: 0`) |
| `v2_fill_check.py` | 10/10 | **10/10** |
| Production gate `v2_prod_regress.py` | 57 PASS | **115 PASS**, 0 XFAIL, 0 FAIL, 0 XPASS (57 + 58 new D3/D4 cases) |
| Array Store gate `v2_prod_arrays.py` | 98 PASS | **98 PASS**, 0 FAIL (unchanged) |
| Known defects `v2_known_defects.py` | 9 PASS, 44 XFAIL | **3 PASS, 14 XFAIL**, 0 FAIL, 0 XPASS |

Known-defect arithmetic: XFAIL 44 − 30 (D3 18, D4 12) = 14; PASS 9 − 6 positive controls moved with their defects (D3-ok ×3, D4 `line19` ×3) = 3. The 14 remaining are D5, D5b, D7 ×5, D9 ×2, D11 ×4, U6 — none belongs to Phase 2D.
Earlier iterations of the code were run through the same suites during development (including a gate run with 2 failures in new test cases that were mistakes in the tests, corrected before this run); the table is the final tree only.

Final budget [M]: HOME 565 free (floor 350 ✔), EXROM 802 free (floor 800 ✔).

Compatibility spot-check [M]: `demos/smoketest.txt` compiles on the baseline and the new build; `shooting_gallery.txt` and `clamp_consolidation_test_v2.txt` (V1-style `;;` first line) compiled to an empty program on the baseline and are now `UNEXPECTED TOKEN` on line 0;
`showcase.txt` fails on both builds (error 40, `MOD(N,15)` is not a V2 function) — the baseline put the cursor on line 41, this build on line 34, the failing line.

## 9. Hardware

Nothing in this phase needs new physical testing: the lexer and shell changes are CPU-only. The earlier hardware checklist (Phase 1 report §6, Phase 2A §11, Phase 2C §10) is unchanged.

## 10. Recommended next item

Work-sequence **step 2.2** (BREAK, edit preservation: D5, D5b, D9): `V2_JUMP_TO_ERROR_LINE` is now trivial and no longer shared state with the editor navigation, so the ordering reason for doing 2.1 first is satisfied. Optional small follow-up
carried from §5: record opening lines for `FOR`/`PROC`/`IF`/forward-label errors if the owner wants them (≈ 20–60 B HOME).
