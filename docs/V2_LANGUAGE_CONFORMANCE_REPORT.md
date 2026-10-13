# 2068-Leap V2 — Language conformance report (qualification study, Phase A)

> **Addendum (2026-10-11, owner-decision review — `docs/V2_OWNER_DECISIONS_REVIEW.md`).** Two more defects were found after this report.
> **Q-32** (CRITICAL, Essential/Enhanced): an address computed above 32767 is saturated to 32767 by `POKE/PEEK/USR/IN/OUT`. It was **introduced by
> the overnight D11 promotion prototype**, so this report's statement that no defect came from the prototypes no longer holds.
> **Q-33** (HIGH, all configurations): a FLOAT package-statement argument arrives as its slot index. Both are fixed on `study/proto-lc`.
> The report as delivered is unchanged on `study/qualification-a`.

**Status:** complete for the scope stated in §1. Nothing here is integrated: `~/2068-Leap` / `v2-development` stay at `7ae0599`, nothing was
pushed, the overnight `study/*` prototype branches were not modified. New work lives on `study/qualification-a` (this report, the tools),
`study/qualification-b` (test infrastructure), `study/qualification-costs` (measured fixes) and `study/qualification-shrink` (measured shrink).

**Evidence classes.** **[M]** run on the *real assembled production image* (HOME + EXROM, packages) in a headless ZEsarUX through the qualification
harness, results read back from the machine (screen through the ROM's own font, RAM, error codes, edit cursor); **[S]** read from source;
**[E]** estimate. Emulator evidence only — **nothing is hardware-qualified**. The legacy Fuse suite was not run.

**Machine-readable results:** `docs/V2_LANGUAGE_COVERAGE.csv` (one row per language feature, aggregated per configuration) and
`docs/V2_LANGUAGE_CASES.csv` (one row per test case: program, expectation, observed result per configuration, defect id).

---------------------------------------------------------------------------------------------------------------------------

## 0. Summary

* **The language surface was inventoried from the source tables** (keyword table, statement dispatch, expression parser, built-in function table, VM
  opcode table, shell commands, package registrations): **118 items** — 52 implemented and documented, 3 implemented but undocumented, 33 partially
  implemented, 8 documented but missing, 9 intentionally unsupported, 13 needing physical hardware for full qualification (§2).
* **A 619-case conformance corpus** with independent expectations (exact rational arithmetic, the manual and the V2 design decisions — never the ROM's own output)
  was run on all three configurations on the real production images (§3):

  | Configuration | Cases | PASS | XFAIL (documented defect reproduced) | FAIL (unexplained) | XPASS | N/A | BLOCKED |
  |---|---:|---:|---:|---:|---:|---:|---:|
  | Phase 2D baseline `7ae0599` | 619 | 454 | 156 | 0 | 0 | 9 | 0 |
  | V2 Essential `0dedab3` | 619 | 477 | 140 | 0 | 0 | 2 | 0 |
  | V2 Enhanced `8379ab5` | 619 | 477 | 140 | 0 | 0 | 2 | 0 |
  | Essential + fixes `b1463c7` (22 ids marked fixed) | 619 | 551 | 61 | 5 | 0 | 2 | 0 |
  | Essential + fixes + RST `b716d4e` (same) | 619 | 551 | 61 | 5 | 0 | 2 | 0 |
  | Enhanced + fixes `c461d7c` (same, Enhanced expectations) | 619 | 551 | 61 | 5 | 0 | 2 | 0 |
  | Enhanced + fixes + RST `162dd59` (same) | 619 | 551 | 61 | 5 | 0 | 2 | 0 |

  Merged from `qual-runs/full3` + `supp1..4` (`tools/qual/qmerge.py`; every record re-checked against the current markers). The 5 FAILs on the fixed builds are
  Q-08 mitigated only (float `FOR` → error 11, 4 cases) and Q-17 partly fixed (`VAL("99999")` wraps).
* **Correctness is not at release level in any configuration.** The corpus exposed **31 defects not previously recorded** (Q-01 … Q-31), **6 of them critical**
  (silent memory corruption or loss of the program) and **8 high** (silently wrong results in ordinary programs — among them Q-29 SPRITE `MOVE` and Q-30, float
  arguments of `CHR$ LEFT$ RIGHT$ MID$ PAUSE BORDER` used as their slot index). **All of them are pre-existing in the Phase 2D baseline**; none was introduced by the overnight prototypes. The critical ones, each reproduced on the real ROM:

  | ID | What a user sees |
  |---|---|
  | Q-01 | `k$="n": IF k$="y" THEN` … is **true**: string `=` and `<` compare only lengths |
  | Q-02 | `PRINT 1.5+2.5*3.5` → `12.2500`; `PRINT UPPER$("a")+LOWER$("B")` → `bb` |
  | Q-03 | `x=0.5: IF x AND 1 THEN` … → the machine cold-restarts and **the program is erased** |
  | Q-04 | `DIM a(4200)` → cold restart, **program erased** (`DIM a(4000)` works) |
  | Q-18 | `DIM a(5): a(5)=99` → error, but `a(0)` is now 99; `a(-1)=2` changes the array's size |
  | Q-28 | `DIM a(3): a(0)=7: s$="x": t$="<31 characters>": PRINT a(0)` → `0` |

* **Every critical and high defect except Q-10 (float arguments of `SGN/SQR/RAD/DEG/SIN…`) has a measured fix** on `study/qualification-costs` (`b1463c7`,
  V2 Essential base; Q-08 only *mitigated*: a float `FOR` bound is now a clean error 11): HOME 353 → 196 free, EXROM 488 → 482, SPRITE package +2 B. With the RST
  shrink on top (`study/qualification-final`, `b716d4e`) the same fixes build at **HOME 741 / EXROM 482**; on Enhanced (`study/qualification-enh-final`)
  at **HOME 578 / EXROM 233** (fixes alone: 23 / 233). On both fixed builds every fixed defect's cases PASS, no
  other case changed status, and the project's gate battery passes (§6.2).
* **Prototype retests (A3):** BREAK, edit preservation, display restoration, D11 promotion and literals, big-float display, nested FN/PROC calls, bare words,
  `IN/OUT/STICK`, multi-item `PRINT`, prompted `INPUT`, `FOR` error line, FILL and the shrink changes behave as the cost study reported on their own
  ground. The cost study's own tools were re-run on both combined builds: every case passed, the integer oracle found 0 mismatches in 4 × 8 476 pairs, and the
  selective-redraw diff found 0 mismatches in 12 scenarios (§4.1). The prototypes' *edges* add Q-05 (`-32768`), Q-09 (5+ decimals) and Q-23 (`STICK(5)`) (§4).
* **Test infrastructure (A5):** `chunk_refill_boundary` migrated to the two-bank harness (38/38 on Enhanced, mutation-checked); a further silent defect found and fixed —
  the CALC variant of the component-test EXROM was 1653–1670 B over 8 KB and truncated without error; 15 component-test sources are never run; the test-only
  decompiler does not reconstruct multi-item `PRINT` and rejects `OUT` (§5).

---------------------------------------------------------------------------------------------------------------------------

## 1. Method

### 1.1 Builds

| Configuration | Commit | HOME free | EXROM free | Built from |
|---|---|---:|---:|---|
| Phase 2D baseline | `7ae0599` | 565 | 802 | `tools/qual/build_configs.sh`: `git archive` of the commit → `make build v2-packages` → `make budget` **[M]** |
| V2 Essential | `0dedab3` (`study/combined-essential`) | 353 | 488 | same; image byte-identical to the overnight worktree build **[M]** |
| V2 Enhanced | `8379ab5` (`study/combined-enhanced`) | 180 | 239 | same; byte-identical **[M]** |

All three budgets reproduce the cost study's figures exactly. No worktree was built in place: every configuration is an export under
`~/2068-Leap-study/qual-builds/<name>` (no `.git`), so the prototype worktrees are untouched.

### 1.2 Harness (`tools/qual/qharness.py`)

The existing `tools/v2_prod.py` spawns one `ts2068-debug` process per command and cold-boots per case (≈ 2 s + run time). For a corpus of this size the
qualification harness keeps one ZRCP socket per emulator and restores a ZEsarUX snapshot of the booted machine before every case (≈ 20 ms), so a case
costs its own emulated time (typically 0.4–0.7 s wall). What runs is the production path from `V2_RUN_STORED` on: chunked source staging, lexer,
compiler, VM, HOME/EXROM banking, display, the INPUT key wait, every error path and message. Substitutions are those of `tools/v2_prod.py`: the program is
written into the line store (no typing), keys go through the ISR latch (`KBD_LASTK/KBD_KEYHIT`), packages are copied to `$F400` and their real entry is
called. Output is read **from the screen bitmap through the ROM's own font** (the font is rendered once by the real `GFX_PUTCHAR` per session), i.e. what a
user sees; compile and runtime error codes, the message shown, the edit cursor after a compile error, and (for memory-safety cases) RAM after the run are
also recorded. A case that does not reach the program's final key wait within its instruction budget is reported `HUNG`.
Parallelism: one emulator per configuration (two or three workers per configuration for the larger runs), private ports and state directories.

### 1.3 Expectations (`tools/qual/qexpect.py`, `tools/qual/corpus.py`)

* **Numbers** are checked against an exact rational oracle (Python `Fraction`). Display rule (manual example `SQR(2)` → `1.4142`, R10.8 matrix): an INT
  prints as an integer, a FLOAT with four decimals **rounded**. A result that equals the *truncated* form instead is the documented defect **D10** and is
  classified automatically (that is the only automatic classification).
* **Text, errors, cursor positions** come from the manual (`docs/v1/user_manual.md`, a V1-era text with a V2 note), the V2 decisions (`R10_8_FEATURE_MATRIX.md`,
  `R10_9_*` reports, `COMPATIBILITY_BREAKS.md`, the cost study) or classic BASIC semantics where V2 is silent. Where the documents disagree or are silent, the
  case says so (`decision` field) and accepts each defensible outcome (`OkOrErr`: the documented result *or* a clean error) — never a silent wrong value.
* **Strict accounting** (as the project's suites): `PASS`; `XFAIL` = a defect documented *before* this study (D*, L*, N*, from the cost study / R10.8) or assigned
  a `Q-*` id by this study after investigation, reproduced; `FAIL` = unexpected; `XPASS` = a marked defect behaves correctly. `N/A` = the feature is not part
  of that configuration by design (e.g. `OUT` in the baseline). A run on a fix branch passes `--fixed Q-…` so the marker is dropped and the fix must PASS.
* No expectation was weakened to fit a result. Five expectations of mine were wrong and were corrected *as oracle errors*, each recorded: `SQR(32767)` is
  181.0166 (I had used √32768); `PRINT` scrolling leaves row 23 blank; `PLOT` pixels must not share the screen with the printed result; the ROM font has no
  `[ ] |` glyphs (the cases now use `< > !`; the missing glyphs are recorded as Q-26); a label named `out` collides with the `OUT` keyword in Essential/Enhanced.

### 1.4 Reproduction

```
cd ~/2068-Leap-study/qualification-a
tools/qual/build_configs.sh ~/2068-Leap-study/qual-builds                     # the three configurations
python3 tools/qual/qrun.py --out /tmp/run --cfg baseline,essential,enhanced --port 10450          # whole corpus (~10-20 min)
python3 tools/qual/qrun.py --out /tmp/run --cfg essential --filter strcmp.,crash.               # a subset (ids or feature prefixes)
python3 tools/qual/qprobe.py essential -- 'a$ = "abc"' 'IF a$ = "xyz" THEN' 'PRINT "EQUAL"' 'ENDIF'   # one program
python3 tools/qual/qcoverage.py /tmp/run --features cov.csv --cases cases.csv                     # matrices
```

---------------------------------------------------------------------------------------------------------------------------

## 2. Language inventory (A1)

Derived from the source, not from the V1 reference (`docs/v1/basic_language_reference.md` describes V1). Full table: `V2_LANGUAGE_COVERAGE.csv`
(columns `syntax`, `source`, `documented_in`, `classification`, per-configuration status, tests, defects).

| Kind | Items | Notes |
|---|---:|---|
| Statements | 39 | 44 resident keywords (Ess/Enh; 43 baseline) + package statements (`MODE ULAPLUS PALETTE GRAB SHOW HIDE MOVE LPRINT LLIST CIRCLE FILL CPLOT BLOCK FRAME INVERT`) |
| Built-in functions | 35 | `BUILTIN_FN_TABLE`: 30 rows baseline, 32 Ess/Enh (`IN`, `STICK`); `DIMN` is parsed separately; `FN` user functions |
| Operators / syntax / literals | 16 | `+ - * /` unary `-`, `= <> < > <= >=`, `AND OR NOT`, string `+`, string `= <`; identifiers (31 chars, case-insensitive), `$` strings, `:` separators/continuations, decimal literals |
| Semantics rows | 8 | bounds/type checks, string records, scalars, strict compilation, error line, built-in call checking, runtime errors, unsupported keywords |
| Packages, commands, editor, display | 20 | `RUN LIST NEW SAVE LOAD VERIFY` (`EXT`/`ARRAY`), `:` immediate, editor keys, BREAK, selective redraw, font |

| Classification | Count | Items (selection) |
|---|---:|---|
| **ID** implemented and documented | 52 | assignment, labels, `GOTO`, `IF…THEN GOTO`, `EXIT FOR`, `DEF FN`, `PRINT` (single), `AT/TAB`, colour statements, `LINE`, `POKE/PEEK/USR`, `RND`, `LEN CODE CHR$ STR$ UPPER$ LOWER$ LEFT$ RIGHT$ INKEY$ FREE POINT ATTR PI`, strict compilation, error line, `RUN LIST NEW` |
| **IU** implemented, undocumented | 3 | multi-item `PRINT` (Enhanced), `MID$` (absent from the manual's table), GRAPHICS package (manual says “not linked”) |
| **PI** partially implemented | 33 | `FOR` (Q-07/08/19/20), block `IF` (Q-06), `PROC` (Q-11), `INPUT` (Q-15/16), `DIM` (Q-04), `CLS` (Q-14), arithmetic (Q-02, D11), `AND/OR` (Q-03, no short-circuit), string `+`/`=`/`<` (Q-01, Q-02), `ABS SGN MOD DIV INT SQR RAD DEG SIN COS TAN VAL DIMN` (Q-10, Q-13, Q-17, D11-EXT), large/decimal literals (L-A, Q-05, Q-09), font (Q-26), SPRITE, SHAPES |
| **DM** documented, missing | 8 | bare `NEXT`, `PRINT AT/TAB` items, string `<> > <= >=`, `INSTR`, `HIT`, `DELETE/EDIT/HELP`, `SYMBOL SHIFT+A/S`, **save/restore program with its current variables** (storage goal 2, see `V2_REMAINING_COMPLETION_BUDGET.md`) |
| **NS** intentionally unsupported | 9 | single-line `IF` (R10.8 L1 — the V1 manual still documents it), `GOSUB/RETURN`, `DATA/READ/RESTORE`, `LET MERGE CONT COPY DRAW SCREEN$`, `^`, infix `MOD/DIV`, hex/exponent literals, `ATN ASN ACS EXP LN` |
| **HW** needs hardware | 13 | `BEEP SOUND LPRINT OUT IN STICK BORDER`, MODE/PRINTER packages, `SAVE/LOAD/VERIFY` (analogue path), BREAK keycap, visible flicker |

Documentation discrepancies found while inventorying (beyond DD-1…DD-11 of R10.8): the manual's string-array element size (31 characters; the default
width 16 holds 15 — **DD-1**), `VAL` “stops at the first non-digit” (it skips them — Q-17), `FOR` “classic entry semantics” (the body runs once — Q-07),
`MOD/DIV` “DIVISION BY ZERO” (they return 0 — Q-13), `STICK` “INVALID ARGUMENT” (any n is accepted — Q-23), “ULAplus is program-scoped” (U6 does not reset it —
hardware), the `PACKAGE_ABI.md` slot 15 record description `[len][content…, NUL]` (Q-27/Q-28: the NUL is neither guaranteed nor safe).

---------------------------------------------------------------------------------------------------------------------------

## 3. Results (A2)

### 3.1 Totals

The totals are the table in §0. They merge the full run `qual-runs/full3` with four supplementary runs (`supp1` … `supp4`: cases added or re-marked after
full3). `tools/qual/qmerge.py` merges case by case (later run wins) and reports cases no run covered (none). Every merged record was re-checked against the
current markers and expectations; the one stale record (`strrec.31_vs_array_write`, a control whose marker was removed) was re-run. Every case with its program,
expectation, observed output per configuration and defect id: `V2_LANGUAGE_CASES.csv`.

### 3.2 Results by area

| Area | Cases | Baseline | Essential | Enhanced | Main findings |
|---|---:|---|---|---|---|
| Integer literals, lexer, identifiers, comments, separators | 75 | defects D11 (literals wrap), N-2 (bare word) | L-A as designed; **Q-05** `-32768` | as Essential | identifiers 31 chars ✓, case-insensitive ✓, keywords reserved ✓, `'` comment rejected ✓ |
| Decimal literals | 14 | D11 (mantissa wraps), **Q-09** | L-A rejects > 5 significant digits; **Q-09** | as Essential | `3.14159` cannot be written (L-A); D10 display truncation |
| Integer arithmetic (grid + boundaries) | 61 | **D11** wraps | ✓ promotion exact incl. `-32767-1`, `181*182`, `32767*32767` | as Essential | `-32768/-1`, `ABS(-32768)`, `DIV(-32768,-1)`, `INT(90000.5)` still wrong (**D11-EXT**); ≥ 2³² saturates, fractions ≥ 32768 dropped (**D11-DISP**) |
| Float arithmetic | 30 | **Q-02** (three live temps), D10 | same | same | `0.1+0.2` = 0.2999 (D10) |
| Relational / logical | 41 | **Q-03** (float operand resets the machine) | same | same | no short-circuit (L-SC), `NOT` precedence ✓, non-associative `<` ✓ |
| Built-in numeric functions | 60 | **Q-10**, **Q-13**, **Q-22**, D10 | same; **Q-23** `STICK` | same | `MOD` sign = dividend ✓, `DIV` truncates ✓, `INT` truncates (R10.8 L6, decision), `RND` range/coverage/repeatability ✓ |
| Strings | 75 | **Q-01**, **Q-02**, **Q-17**, **Q-27**, **Q-28** | same | same | 31-char cap ✓ (longer literal cut silently, L3), clamping of `LEFT$/RIGHT$/MID$` ✓, `CHR$(256)` error ✓ |
| `PRINT`, screen, colour, graphics | 30 | **Q-14**, **Q-26** | same | multi-item `PRINT` ✓ (`;` `,` zones, trailing separator, bare `PRINT`, inside blocks) | `AT` clamps ✓, attributes ✓, `OVER` XOR ✓, coordinates wrap modulo 256 (DEC-PLOT) |
| `IF` | 18 | **Q-06** | same | same | block/nested/`ELSE IF` ✓; single-line `IF` rejected (decision) ✓; `ELSEIF` missing (L-ELIF) |
| `FOR` / `NEXT` / `EXIT` / `GOTO` | 32 | **Q-07**, **Q-08**, **Q-19**, **Q-20**, D11 (limit 32767 never ends) | Q-07/08/19/20 | same | `EXIT FOR` ✓; 1 500 abandoned loops do not corrupt memory ✓ |
| `PROC`/`CALL`/`DEF FN` | 31 | N-1, **Q-11**, **Q-24** | N-1 fixed ✓; Q-11, Q-24 | same | parameter restore ✓, recursion 150 deep ✓, runaway → STACK OVERFLOW ✓ |
| Arrays | 54 | **Q-04**, **Q-18**, N-4, DD-1 | same | same | 0-based ✓, bounds errors ✓ (but see Q-18), `DIMN` ✓, string widths ✓ |
| `INPUT` | 10 | **Q-15**, **Q-16** | same | prompt ✓ | numeric/string/negative/empty ✓ |
| Hardware statements (emulator-visible part) | 15 | `OUT`/`IN` absent (N/A) | AY register round trip through `OUT 245/246` + `IN(246)` ✓, keyboard port ✓, `STICK` idle ✓, `OUT` reserves the word ✓ | same | **HW**: audio, `STICK` directions, non-`$FE` ports |
| `CLEAR`, program shape, capacity | 12 | **Q-21** | same | same | 150-line programs, 60 variables, 40-term lines ✓ |
| Compile-error line | 7 | Phase 2D behaviour ✓ | ✓ | `FOR` reports its own line (N-3) ✓ | |
| Packages | 16 | **Q-29** (SPRITE `MOVE`) | same | same | unloaded package → error 2 ✓; CIRCLE/FILL ✓; MODE/ULAPLUS/PALETTE ✓ (visible output: HW) |
| Unsupported keywords | 15 | all rejected ✓ | ✓ | ✓ | |
| Memory-safety probes (RAM inspected) | 17 | **Q-03**, **Q-04**, **Q-18**, **Q-28** | same | same | |

### 3.3 The high-priority investigations of the brief (A4)

| # | Question | Answer [M] |
|---|---|---|
| 1 | Integer overflow, signed boundaries | Baseline wraps (D11). Essential/Enhanced promote `+ - *` exactly at every boundary tested (incl. `32767+1`, `-32767-2`, `-256*129`, `32767*32767`, chained `32767+1-1` = 32767). New edge: `-32768` as a literal (**Q-05**). |
| 2 | `ABS(-32768)` | `-32768` in all three (D11-EXT, cost study §B.4) |
| 3 | `-32768 / -1` | `-32768` in all three (D11-EXT): `OP_DIV`'s exactness test `q*b = a` holds for the wrapped quotient |
| 4 | `INT`, `DIV`, `MOD` extremes | `DIV(-32768,-1)` = −32768; `MOD(-32768,3)` = −2 ✓; `INT(30000*3+0.5)` = 32767 (saturates); `INT` truncates toward zero (documented decision); `MOD/DIV` by zero = 0 (**Q-13**); float arguments truncated (**Q-10**: `MOD(7.5,2)` = 1) |
| 5 | Decimal literals | mantissa > 32767 → error 64 (L-A; baseline wraps); 5+ fractional digits → wrong value (**Q-09**: `0.00001*100000` = −3.2183); 4 decimals exact |
| 6 | Large-float display, saturation | ≥ 32768 prints integer digits + `.0000` (fraction dropped); ≥ 2³² saturates (`32767³` → `4294574091.0000`) (D11-DISP) |
| 7 | Float formatting truncation (D10) | reproduced everywhere a rounding matters: `0.1+0.2` 0.2999, `2/3` 0.6666, `PI()` 3.1415, `SIN(30)` 0.4999, `SQR(1000)` 31.6227 … (auto-classified D10) |
| 8 | `FOR` termination / `STEP` | Essential/Enhanced terminate at 32767 and at −32768 ✓ (baseline: endless, D11); **Q-07** zero-trip; **Q-08** float bounds; **Q-20** outer `NEXT` after `GOTO` out of an inner loop; `STEP 0` endless (documented) |
| 9 | Nested FN/PROC name preservation | `CALL p(FN f(4))`, `CALL show(FN sq(3)+FN sq(4))`, `FN inc(FN inc(FN inc(0)))` ✓ in Ess/Enh (N-1 fixed); baseline N-1; **Q-11** for *definitions* nested in a PROC |
| 10 | Bare identifiers, labels | bare words rejected in Ess/Enh (baseline N-2); label with a statement ✓; label vs variable namespaces separate ✓; **duplicate label silently accepted (Q-12)**; `CALL` of a plain label accepted (**Q-24**) |
| 11 | Array/scalar namespace | an array name used as a value needs `(` (N-4, showcase.txt); `a = 5` next to `DIM a(3)` is accepted as a scalar ✓ |
| 12 | `PRINT` bytecode and control flow | multi-item `PRINT` inside `IF/ELSE` blocks, trailing separators, comma zones wrapping to the next line ✓ (Enhanced); the test-only decompiler does not reconstruct it (T-4) |
| 13 | Wrong argument counts | every built-in rejects too few/too many arguments and wrong types at compile time ✓; `MID$` with 2 arguments rejected (decision); package statements check counts (error 28) ✓ |
| 14 | Runtime vs compile-time reporting | compile errors move the cursor to the failing line (D4 ✓; Enhanced: `FOR` line); runtime errors show a generic message (`RUNTIME ERROR` for most codes — U4/U5) |
| 15 | Package registration, unloaded functions | an unloaded package statement is compile error 2; `LPRINT` without PRINTER is error 32 (shared with “expected identifier after DIM”) |

### 3.4 Hardware-only items (HARDWARE REQUIRED)

Audio (`BEEP`, `SOUND`), `STICK` directions, `OUT/IN` on non-`$FE` ports, `BORDER` colour, printer output, hi-res / ULAplus display and their restoration
on return to the editor, the BREAK keycap, visible flicker, analogue tape. The corpus tests only what the emulator can observe (no error, register and
port state where readable).

---------------------------------------------------------------------------------------------------------------------------

## 4. The overnight prototypes, retested (A3)

| Prototype | What was retested here | Result |
|---|---|---|
| BREAK / PAUSE (D5, D5b) | `PAUSE n`, `PAUSE 0` + key in the corpus; the cost study's real-matrix tool `study_break_matrix.py` re-run on Essential and Enhanced (§4.1) | see §4.1 |
| Edit preservation (D9a/b) | `study_edit_preserve.py` re-run (§4.1) | see §4.1 |
| Display restoration (U6) | `study_u6.py` re-run; colour state across RUN observable in the corpus (`print.*`) | see §4.1; ULAplus: HW |
| D11 error / promotion alternatives | promotion in both combined builds: 61 arithmetic cases + boundary grid; error variant (`study/d11-error`) not re-run (alternative, not in either build) | promotion exact; edges Q-05, D11-EXT, D11-DISP |
| Integer literal policies | 21 literal cases | L-A as designed; Q-05, Q-09 at its edges |
| Big-float display | 6 cases | D11-DISP as documented; IX contract note (audit §3.7) |
| Nested FN/PROC calls | 6 cases | N-1 fixed in Ess/Enh ✓; Q-11 is a different (definition) defect |
| Bare-word errors | 3 cases + 15 unsupported-keyword cases | ✓ |
| `IN`, `OUT`, `STICK` (core) | 8 cases | ✓ emulator part; Q-23; HW |
| Core vs EXROM hardware functions / ABI 2.1 function packages | source review of `study/lang-hw-exrom`, `study/extfn` (audit) | alternatives; not in either build; not re-run |
| Multi-item `PRINT`, prompted `INPUT` | 10 cases (Enhanced) | ✓ |
| `FOR` error line (N-3) | `err.eof_for` | ✓ Enhanced reports the `FOR` line; Essential/baseline the append line |
| FILL exactness / overflow (D7) | `pkg.shapes.fill`, `v2_fill_check.py` 10/10 on the fix and shrink branches | ✓ |
| I1 / I1b / I2 redraw | `study_flicker.py --diff` (§4.1) | see §4.1 |
| Abortable LIST (ED5) | — | not run (needs a long program + BREAK at a page end); behaviour verified only by source review |
| Measured shrinks (`V2_POS_IS_APPEND`, `COMPILE_2ARG_STMT`) | covered by every editor/`PLOT`/`BEEP`/`SOUND`/`POKE`/`OUT` case and the gate | ✓ |

### 4.1 Study-tool battery

The cost study's own prototype tools (`tools/study_*.py` of each combined build) were re-run on frozen copies of the Essential and Enhanced exports by
`tools/qual/run_study_battery.sh` (logs: `qual-runs/a3-essential`, `qual-runs/a3-enhanced`) **[M]**:

| Tool (prototype) | Essential | Enhanced |
|---|---|---|
| `study_break_matrix` (D5/D5b BREAK through the real keyboard matrix) | 6 PASS | 6 PASS |
| `study_edit_preserve` (D9a/D9b) | 9 PASS | 9 PASS |
| `study_u6` (display/attribute reset) | 4 PASS | 4 PASS |
| `study_bare_ident` (N-2) | 13 PASS | 13 PASS |
| `study_callfn` (N-1 nested FN in CALL) | 7 PASS | 7 PASS |
| `study_d11_literals` (L-A) | 13 PASS | 13 PASS |
| `study_d11_print` (promotion + big-float display) | 15 PASS | 15 PASS |
| `study_lang_hw` (`OUT`/`IN`/`STICK`) | 6 PASS | 6 PASS |
| `study_eof_for` (N-3) | — (not in Essential) | 5 PASS |
| `study_lang_print` (multi-item `PRINT`, prompted `INPUT`) | — (not in Essential) | 13 PASS |
| `study_fill_break` (BREAK interrupts FILL) | running before BREAK, returned after BREAK ✓ | ✓ |
| `study_flicker --diff` (I1/I1b/I2: selective redraw == full redraw) | 12 scenarios, 0 mismatches | 12 scenarios, 0 mismatches |
| `study_vm_oracle` mul / add / sub / mulop (real VM, exact reference; 8 476 pairs each) | 0 / 0 / 0 / 0 mismatches | 0 / 0 / 0 / 0 mismatches |

Two harness notes, both mine or the tool's, neither the ROM's:

* The first battery pass ran `study_vm_oracle` add/sub/mulop without `ORACLE_PROMOTE=1`. In that mode the tool expects error 67 on overflow, so it reported exactly
  the overflow pairs (855 / 845 / 6 277) as mismatches. Every one of them had promoted to the exact value. The runner now sets the variable for promotion builds.
* The tool's own mismatch report line crashes (`TypeError`: a 9-field tuple formatted with 7 placeholders), so a real mismatch would have been reported only as a
  count. This is a defect in the cost study's tool, recorded here; it is not fixed in the prototype branches, which this study does not modify.

Not re-run: the D11 *error* variant and the core-vs-EXROM / ABI 2.1 hardware-function alternatives. These are alternatives that neither combined build contains.
Abortable LIST has no tool.

---------------------------------------------------------------------------------------------------------------------------

## 5. Test infrastructure (A5)

1. **`chunk_refill_boundary` migrated to the two-bank harness** (`study/qualification-b`, commit `de5c5f5`). Programs, steps and assertions unchanged; the harness
   gained a `TEST_V2_WITH_KERNEL_MEMORY` switch to link the real `kernel/memory/memory.asm` (the stored-program path needs `MEM_LINE_FIRST/NEXT`); the test re-pages
   EXROM after `MEM_COLD_INIT` (which clears `BANK_EXROM_DEPTH`); `DECOMP_END_ADDR` moved from a ROM `DW` to RAM `$9B08` (my first choice, `$9900`, overlapped the
   test's own snapshot buffer — caught by the test failing). **Enhanced: 38/38** (was 37/37 with the test skipped). Two mutants (wrong expected value; inverted
   error check) both fail → the migrated test still detects failures.
2. **New finding, fixed (T-1):** the CALC variant of `rom/test_v2_harness_exrom.asm` (`-DTEST_V2_NEEDS_DECOMPILE -DTEST_V2_NEEDS_CALC`) is **1653 B (baseline) /
   1670 B (Essential) over 8 KB**. The runner assembled it with plain `sjasmplus`, which only warns (“Negative BLOCK moves PC backwards”), so the decompiler's tail past
   `$E000` was silently missing from the image used by `r10_numeric` and `run_tables`. None of those tests calls the decompiler, so the CALC variant now links the
   calculator only and both harness EXROMs are built with `sjasmplus_strict.sh` (commit `c655564`): 38/38, no warnings.
3. **New finding (T-3):** 15 component-test sources are never run by `tools/run_v2_standalone_tests.sh` and are not documented as retired: `print`, `compiler_r2…r7`,
   `call_fn`, `decompiler_phase2`, `editor_integration`, `ext_concurrent`, `graphics_module_ram`, `graphics_pixel`, `sprite_module`, `sqr`. The R10.8 matrix cites some
   of them (`[T:s:print]`, `[T:s:graphics_pixel]`) as coverage. Recommendation: run or retire each (not done).
4. **PRINT opcodes and bytecode-asserting tests (T-4):** the test-only decompiler skips `OP_NL`/`OP_PRINT_COMMA` (so `PRINT a; b` decompiles as two `PRINT` statements —
   enough for the byte-exact `block_if` check, not a faithful reconstruction) and does not know `OP_OUT` (decompiling any program with `OUT` gives decompiler error 3,
   cleanly). No component test asserts multi-item `PRINT` or `OUT` bytecode; `test_v2_print.asm`, the one that would, is among the never-run tests.
5. The `vm_milestone01` component test assembles with two “label has different value in pass 3” warnings (pre-existing, harmless).
6. Fix-branch test updates follow bytecode changes only: the decompiled-text expectations of `for_step`, `group6_math`, `sqr_decomp` (negative literals are folded by
   the Q-05 fix: `(0-3)` → `-3`; `FOR_INIT` gained a 2-byte operand: labels +2 per loop) and the hand-assembled bytecode of `vm_milestone01`; no assertion was weakened.
   The production checks `253-vars` and `free-1` change *capacity* by design under the Q-02 fix (scalar cap 251, FREE −74 B) — not edited, reported as failing (§6.2).

---------------------------------------------------------------------------------------------------------------------------

## 6. Fixes measured (prototype branch `study/qualification-costs`)

### 6.1 Measured costs

| Commit | Fixes | HOME free | EXROM free | Package |
|---|---|---:|---:|---|
| `0dedab3` | (V2 Essential) | 353 | 488 | |
| `ead8885` | Q-01, Q-03, Q-18 | 342 | 488 | |
| `e3356ca` | Q-04 | 334 | 482 | |
| `98b7b5b` | Q-06 (−1), Q-13 (−2), Q-14 (−6), Q-09 (−5), Q-17 stop (0), Q-12 (−4), Q-11 (−16), Q-05 (−18) | 282 | 482 | |
| `602549b` | Q-02 (**+40**, RAM +74) | 322 | 482 | |
| `3eb57e0`/`f0d62ca` | Q-07, Q-08, Q-19, Q-20 (FOR redesign) | 220 | 482 | |
| `b478b31` | Q-27, Q-28 | 208 | 482 | |
| `00cb2a5` | Q-29 | 208 | 482 | SPRITE 832 → 834 |
| `b1463c7` | Q-30 (0), Q-31 (−12) | **196** | **482** | |
| `b716d4e` (`study/qualification-final`) | all of the above + RST shrink | **741** | **482** | |
| `c461d7c` (`study/qualification-enh-final~1`) | the same nine fix commits on **Enhanced** | 23 | 233 | SPRITE 834 |
| `162dd59` (`study/qualification-enh-final`) | + RST shrink, on **Enhanced** | **578** | **233** | |

### 6.2 Verification of the fixed build

Both fixed builds were exported and run exactly like the three configurations **[M]**. They are `b1463c7` (fixes) and `b716d4e` (fixes + RST).

* **Corpus** (619 cases, Essential expectations; the markers of the 22 fixed ids were dropped, so their cases must PASS): **551 PASS, 61 XFAIL, 5 FAIL, 0 XPASS, 2 N/A**
  on both builds. Compared case by case, the two runs have 0 status differences and 0 differences in observed output. All cases of Q-01 … Q-07, Q-09, Q-11 … Q-14,
  Q-18 … Q-20 and Q-27 … Q-31 PASS. The 61 XFAILs are defects still open (D10, D11-EXT, D11-DISP, L-A, L-STR and the other L-items, Q-10, Q-15, Q-16,
  Q-21 … Q-26, N-4, DD-1, DEC-PLOT). The 5 FAILs are reported as failures, with no expectation changed:
  * `for.float_step`, `for.float_limit`, `for.float_start`, `for.float_var_limit`: Q-08 is **mitigated, not fixed**. A float `FOR` bound is now runtime error 11
    instead of a wrong loop. R10.8 documents “float STEP accepted”, so this needs the owner decision integer-only `FOR` vs float loops.
  * `str.val_big`: Q-17 is **partly fixed**: `VAL` stops at a non-digit, but `VAL("99999")` still wraps to −31073.
* **Project gate battery** (`tools/qual/run_gate_suites.sh` on frozen copies; `qual-runs/gate-costs3`, `qual-runs/gate-final`), identical on both builds:
  `v2_prod_regress` **115 PASS**, `v2_prod_arrays` **98 PASS**, `v2_known_defects` **15 PASS**, `v2_fill_check` **10/10**, `v2_production_checks` **17/19**.
  The two failing production checks are `253-vars` (a 253rd scalar is now a compile error: the cap is 251) and `free-1` (`FREE` = 893, outside the
  check's 900–1100 window). Both are capacity constants that the Q-02 fix changes by design (+74 B RAM for 8 temp slots). The checks were not edited.
* **`make check`** rc 0 on both (assembly, docs, package-ABI, storage-contract, basic-source, calculator-dispatcher and SPRITE checks).
* **Standalone component tests** (`tools/run_v2_standalone_tests.sh`, in the branch worktrees): **38/38** on `b1463c7` and on `b716d4e` (the two pass-3 label
  warnings of `vm_milestone01` are pre-existing). Enhanced: see §6.3.
* An earlier gate run on the intermediate `b478b31` was stopped after 38 gate cases (0 FAIL) once `b1463c7` superseded it (`qual-runs/gate-costs2.SUPERSEDED`).

### 6.3 The same fixes on Enhanced (`study/qualification-enh-final`)

The nine fix commits cherry-picked onto `study/qualification-b` (Enhanced + the test-infrastructure commits) without a conflict, and the RST rule was
re-applied with `tools/qual/apply_rst_rule.py`. Measured **[M]**: fixes **HOME 23 / EXROM 233** (`c461d7c`), fixes + RST **HOME 578 / EXROM 233** (`162dd59`).

* **Corpus** (Enhanced expectations, the same 22 ids marked fixed): **551 PASS, 61 XFAIL, 5 FAIL, 0 XPASS, 2 N/A** on both builds, with the same 5 FAILs as on
  Essential. Against unfixed Enhanced, every status change is a case of a fixed defect; the 11 Enhanced-only cases (multi-item `PRINT`, prompted `INPUT`, the
  `FOR` error line) PASS. Against Essential-final there are 0 status differences, and output differs only in those 11 cases.
* **Gate** (`qual-runs/gate-enh-final`): `v2_prod_regress` **113 PASS**, `v2_prod_arrays` **98 PASS**, `v2_known_defects` **15 PASS**, FILL **10/10**,
  production checks **17/19** (the same two capacity checks as on Essential). Enhanced's gate has 113 cases, not 115, by the overnight study's design: `8379ab5` dropped
  `D3-print-comma-list` / `D3-print-semicolon-list`, which assert that a multi-item `PRINT` is *rejected* — Enhanced implements it.
* **`make check`** rc 0; **standalone component tests 38/38**.
* **Prototype tools** (`qual-runs/a3-enh-final`): every tool of §4.1 again passes in full. That covers break matrix 6, edit preservation 9, U6 4, bare words 13,
  `CALL p(FN …)` 7, literals 13, D11 print 15, `OUT/IN/STICK` 6, `FOR` line 5 and multi-item `PRINT` 13. FILL BREAK ✓; flicker diff 12 scenarios, 0 mismatches;
  the VM oracle has 0 mismatches in 4 × 8 476 pairs.

---------------------------------------------------------------------------------------------------------------------------

## 7. Missing tests and untested features

Features with no automated case in this corpus (listed `UNTESTED`/`GATE-ONLY` in the coverage CSV): `SAVE/LOAD/VERIFY` (covered by the project's gate with a
synthesised EAR stream, not here), `LIST` paging and abort, `NEW`, immediate `:` statements, the editor keys (covered by the gate and the study tools), the
GRAPHICS package's visible output, `LLIST`, `INKEY$` with a key held, `RND` distribution beyond coverage of 0..5, `PAUSE` timing accuracy, `ATTR`/`POINT` in
hi-res mode, string arrays in the Array Store across `RUN` (98-case gate), and every HW item of §3.4.

## 8. Recommended corrections

In order: the six critical defects with Q-27 (Q-01, Q-02, Q-03, Q-04, Q-18, Q-27/Q-28 — measured fixes, HOME +9 net together); then the high ones,
Q-06, Q-30, Q-29, Q-07/Q-08/Q-19/Q-20 (with the integer-only-`FOR` decision), Q-10; then the medium items; then decisions (INT rounding, DEC-PLOT, `MID$` start 0, `POKE` value range, literal rule L-C).
Costs, dependencies and the overall budget: `V2_REMAINING_COMPLETION_BUDGET.md`. Root causes and code review: `V2_INDEPENDENT_Z80_AUDIT.md`.
