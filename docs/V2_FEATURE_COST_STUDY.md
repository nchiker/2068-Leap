# 2068-Leap V2 — Feature and defect cost study (overnight, measured)

**Status:** study complete; nothing here is integrated. Every prototype lives on an isolated `study/*` branch and worktree
(`~/2068-Leap-study/<name>`), based on the Phase 2D commit `7ae0599`. `v2-development` was not touched (HEAD `7ae0599`, clean),
nothing was pushed, no tag/release/config was changed. This report is committed only on `study/report`.

**Evidence classes** (as requested): **MEASURED AND TESTED** (assembled into the real production ROM or package, run against the
real ROM in ZEsarUX through ts2068-debug, with the tests named), **MEASURED BUT NOT FULLY VERIFIED** (assembled, size is real,
behaviour only partly exercised), **ESTIMATED ONLY** (not assembled — never silently promoted to a measurement), **BLOCKED**.
Byte costs are *signed against Phase 2D*: "HOME −21" means 21 bytes of HOME free space consumed, "EXROM +17" means 17 bytes freed.
All emulator evidence is emulator evidence; **nothing is hardware-qualified.**

---------------------------------------------------------------------------------------------------------------------------

## 0. Summary

* **Two complete configurations were assembled and tested** (not just costed). **V2 Essential** — BREAK, edit preservation, display restore, integer-overflow promotion to float (with the display fix it needs),
  exact FILL, the nested-call and bare-word fixes, `OUT`/`IN()`/`STICK()`, typing-flicker reduction — leaves **HOME 353 B / EXROM 488 B free** (Phase 2D: 565 / 802). **V2 Enhanced** (Essential plus multi-item `PRINT`,
  prompted `INPUT`, exact `FOR` error line, two-line `UP`/`DOWN` redraw, abortable `LIST`) leaves **HOME 180 B / EXROM 239 B**. Costs were *exactly additive* between the isolated measurements and the merged builds, so the matrix in §B can be used
  for arithmetic. Essential passed `make check` and the whole headless suite (115-case gate, 98-case Array Store gate, known-defect suite with 12 former defects now passing, 19 production checks, 10 FILL fixtures, 38 component tests); Enhanced
  passed `make check` and everything except one component test that no longer fits its legacy flat image (§E.3).
* **The previously identified flicker fix was found, and it works.** The V1 row-shadow design and the R10.8 audit's *I1/I2* "dirty-scope" selective redraw (`R10_8_EDITOR_USABILITY_AUDIT.md` §5) were never ported to the V2 editor:
  `V2_REDRAW` still did `GFX_CLS` (194 k T-states) plus every visible line on every key. Reusing only existing display routines, typing fell from **≈ 591 k to ≈ 70 k T-states per key (−88 %)** and the screen clear per key went from 1 to 0;
  `UP`/`DOWN` fell from ≈ 583 k to ≈ 167 k (−71 %). A differential oracle (screen after the selective path == screen after a forced full redraw, 6 912 bytes, after every key of 12 scripted sessions, run on four builds) found **0 mismatches** — and demonstrably *can* fail
  (it caught a real D9 × I2 interaction bug on an unfixed merge). Cost: **EXROM −123 B** (typing) / **−361 B** (typing + navigation); a finer cell-level typing step (no row is ever cleared) costs −341 B. Whether the remaining row-blank (≈ 7 ms) is visible needs a real TS2068 (§D.2.7).
* **Defects found that were not on the work-sequence list** (all measured, §B.6): (1) a **bare word on a line** (`PRNT`, `CLEARR`, `CONT`, `COPY`, `RESTORE`) is silently accepted and does nothing — fixed for 8 B; (2) `CALL p(FN f(x))` calls the *wrong label* (the nested `FN` overwrites the shared name buffer) — fixed for 4 B;
  (3) decimal literals wrap at 16 bits (`PRINT 12345.678` → `24.9099`) and **every float ≥ 32 768 prints as `32767.////`**; (4) `FOR i = … TO 32767` never ends; (5) the Phase 2D diagnosis of `showcase.txt` is wrong — `MOD(N,15)` works, the demo has an array `N` *and* a parameter `N`.
* **Owner decisions the study does not make for you** (§G): (1) **D11** — overflow as a runtime error (HOME −101, EXROM −23) or promotion to float (HOME −99, EXROM −111) and which *literal rule* (the test corpus uses `POKE 65000`-style address literals); (2) hardware functions as core built-ins or as ABI 2.1 *function packages* (the existing registry is statement-only);
  (3) which parts of `PRINT`/`INPUT` are worth their bytes (150 B for all of it); (4) whether to accept an exact-but-minutes-slow worst-case `FILL`; (5) the reserve policy (Enhanced is below *both* historical targets).
* **Not done / not claimed:** nothing is hardware-qualified; `STICK` directions, BREAK keycap position, visible flicker, ULAplus/hi-res return and non-`$FE` port behaviour all need the real machine (§H.1). The Fuse/legacy suite was not run. Items marked ESTIMATED ONLY were not assembled.

---------------------------------------------------------------------------------------------------------------------------

## A. Baseline

| Item | Value | Evidence |
|---|---|---|
| Repository / branch | `2068-Leap`, `v2-development`, HEAD **`7ae0599`** (Phase 2D docs; Phase 2D commits `056795b`, `de09707`, `7ae0599`), working tree clean at start **and at the end of this study** | `git status`, `git rev-parse` |
| HOME ROM | 15 819 / 16 384 used — **565 B free** | `make budget` in a fresh worktree (`study/baseline`) **[M]** |
| EXROM | 7 390 / 8 192 used — **802 B free** | same **[M]** |
| Physical limits | HOME 16 384 B, EXROM 8 192 B. The 350 B (HOME) / 800 B (EXROM) figures are **historical engineering reserve targets, not physical limits**; this study reports against both | project docs |
| Package window | `$F400–$F7FF`, **1 024 B**, one package resident at a time; image sizes: MODE 165, PRINTER 345, GRAPHICS 467, SHAPES 795, SPRITE 832 (SPRITE leaves 192 B, SHAPES 229 B, before the D7 change) | `build/v2_package_*.bin` **[M]** |
| Spare RAM for new cells | `$BEC0–$BED7` = 24 B in the V2 sysvar gap (Phase 2C freed `$BEC0–$BECA`). The flicker prototype uses `$BEC0–$BEC5` (6 B); no other prototype needs fixed RAM | `exrom_v2_shell.asm` map **[S]** |
| Test baseline | `make test` all green at Phase 2D (smoke 9/9, standalone 38/38, production checks 19/19, FILL 10/10, gate 115 PASS, Array Store 98 PASS, known-defect suite **3 PASS + 14 XFAIL**, 0 XPASS). Re-verified here: `make budget` 565/802 and the known-defect suite **3 PASS, 14 XFAIL, 0 FAIL** on the clean `study/baseline` worktree | Phase 2D report §8; this study **[M]** |
| Not run | `make test-legacy` / any Fuse suite (as instructed) | — |

The strict XFAIL accounting was preserved: every prototype that flips a known-defect case reports it as **XPASS** (the suite then fails
by design until the marker is removed); the combined branches drop the markers and keep the cases as gate tests (§E).

---------------------------------------------------------------------------------------------------------------------------

## B. Feature decision matrix

Cost columns are bytes **consumed** (positive) in the real build; a negative number is a saving. "Placement" is the recommendation.
"Risk" is implementation/integration risk, not user-visible risk. IDs for defects follow the R10.8/R10.9 documents; new findings are `N-*`.

### B.1 Release-critical correctness and data preservation

| ID | Candidate | Ess. / Opt. | Place | HOME | EXROM | Pkg | RAM | Confidence | Tests (what actually ran) | Depends on | Risk | Benefit |
|---|---|---|---|---:|---:|---:|---:|---|---|---|---|---|
| **D5 + D5b** | BREAK stops a running program; the editor ignores control codes `< $20` | **Ess.** | HOME (ISR) + EXROM | **21** | **13** | – | 0 | **MEASURED AND TESTED** | 6 cases × 2 runs through the **real keyboard matrix** (CAPS SHIFT + SPACE, ZEsarUX `send-keys-event` → ISR scan → debounce → decode): `GOTO` loop, long `FOR`, `PAUSE 5000`, `PRINT` loop, inert in the editor, re-run after BREAK. `D5b` known-defect case XPASS. The existing `D5` case pokes the key latch directly and so cannot see an ISR-side fix: rewrite it (done in the combined branches) | none | low: one ISR branch; BREAK keycap matrix position unverified on hardware | Stops runaway programs; removes a stray `$10` from every edit line |
| **D9b** | `PROGRAM FULL` keeps the typed line | **Ess.** | EXROM | **0** | **0** | – | 0 | **MEASURED AND TESTED** | known-defect `D9-program-full-keeps-text` XPASS; `study_edit_preserve` | none | very low (a label: re-enter the editor without `EDITOR_INIT`/`V2_LOAD_EDIT`) | No more lost line when the store is full |
| **D9a** | Commit-on-navigate: an edit survives `UP`/`DOWN`/insert-line; `PROGRAM FULL` while navigating keeps buffer and cursor | **Ess.** | EXROM | 0 | **83** | – | 0 | **MEASURED AND TESTED** | `D9-edit-survives-navigation` XPASS, `D9-nav-plain` PASS, `study_edit_preserve.py` 9/9 (append-line, unchanged nav writes nothing, arrays kept, insert, PROGRAM FULL on nav) | D9b (shares `V2_STORE_EDIT`) | low–medium: new commit path in `V2_NAV` | Edits are never discarded by moving. A cheaper variant (always store when non-empty, no compare) is 55 B but discards the DIM'd arrays and rewrites the store on every move: **rejected** |
| **U6** | Display/attribute/border/mode restored on return to the editor | **Ess.** | EXROM | 0 | **4** | – | 0 | **MEASURED AND TESTED** | `U6-mode1-return` XPASS; `study_u6.py` 4/4 (colour state, MODE 1 return incl. status bar `$07`, border, second run clean) | – | very low | Editor is usable after `MODE 1`/`BORDER`/colour statements; second `RUN` no longer inherits colours |
| **D7** | `FILL` exact when the seed stack overflows | **Ess.** (correctness) / low urgency | **package** | 0 | 0 | **+212** (795 → 1 007 of 1 024; +202 for the exactness itself, +10 for BREAK polling) | 8 (in image) | **MEASURED AND TESTED** (with a time caveat) | `v2_fill_check.py` 10/10 unchanged; known-defect D7: noise-10 %, noise-25 %, ladder-2px XPASS, noise-40 % PASS; staggered-dots and ladder-1px-teeth **exact (0 differing pixels) but 787 s / 453 s emulated** — they exceed the harness's 400 M-instruction cap | none | medium: pathological images are minutes-slow; only 17 B of the window left | No silent partial fills. Ordinary art is unaffected (same code path, same timing, until a seed is dropped) |
| **D11** (variant **P**) | Integer overflow promotes to the existing float path; large literals handled | **Ess.** | HOME + EXROM | **99** | **111** | – | 0 | **MEASURED AND TESTED** | exact oracle: 105 476 pairs each for `+`, `−`, `*` through the real `VM_RUN` bytecode path, **0 mismatches**; `VM_MUL_CHECKED` alone 105 476 pairs, 0 mismatches; `study_d11_print.py` 15/15; `study_d11_literals.py` (address literals still work); `D11-*` XPASS | float display ≥ 32 768 (the 111 EXROM bytes) | medium: touches the VM hot ops; literal rule changes accepted programs | `30000*3` = `90000.0000`, `32767+1` = `32768.0000`, `FOR i=32765 TO 32767` terminates (it looped forever) |
| **D11** (variant **E**) | Overflow raises runtime error 67 `NUMERIC OVERFLOW`; literal > 32 767 is error 64 | alt. | HOME + EXROM | **101** | **23** | – | 0 | **MEASURED AND TESTED** | same oracle: 105 476 pairs × (`+`, `−`, `*`, `*` direct) = **0 mismatches**; `D11-*` XPASS | – | low–medium; **breaks `POKE 65000` style literals** (corpus: `tests/math5`, `usr1`, `hit`) unless the literal rule of variant P is used | Clean error instead of a wrong number |
| **N-1** | Call `p(FN f(x))` calls the right procedure | **Ess.** | HOME | **4** | 0 | – | 0 | **MEASURED AND TESTED** | `study_callfn.py` 7/7 (5 of them fail on the baseline) | – | very low | Silent wrong-call removed |
| **N-2** | A bare word on a line is an error (not a label) | **Ess.** | HOME | **8** | 0 | – | 0 | **MEASURED AND TESTED** | `study_bare_ident.py` 13/13 (7 bare-word cases error 64; labels, `GOTO`, `PROC`, `x = 1:` unchanged) | Phase 2D's `LEX_NEWLINE_PENDING` | low: a program that relied on "bare word = no-op" now fails (that is the point) | Mistyped/unsupported command words (`PRNT`, `CLEARR`, `CONT`, `COPY`, `RESTORE`) are no longer silently ignored |

Details and caveats behind the D11 numbers are in §B.4.

### B.2 Hardware access and language gaps named in the brief

| ID | Candidate | Ess. / Opt. | Place | HOME | EXROM | Pkg | RAM | Confidence | Tests | Depends on | Risk | Benefit |
|---|---|---|---|---:|---:|---:|---:|---|---|---|---|---|
| **L-OUT** | `OUT port,value` (full 16-bit port in `BC`) | **Ess.** | HOME (core) | **56** (13 after the shared-helper shrink) | 0 | – | 0 | **MEASURED AND TESTED** (emulator) | `study_lang_hw.py`: AY register write/read round trip via ports `$F5`/`$F6` | – | low | Hardware access (AY, Timex ports, ULAplus, joystick, Dock) |
| **L-IN** | `IN(port)` function (full 16-bit port) | **Ess.** | HOME (core) | **22** | 0 | – | 0 | **MEASURED AND TESTED** (emulator) | with key `1` held: `IN(63486)=$BE`, `IN(65278)=$BF`, `IN(65022)=$BF`, while `IN(254)=$BE`: the **high byte selects the half-row** (proves the 16-bit address reaches the bus) | – | low | as above |
| **L-STICK** | `STICK(1|2)` — Timex joystick via AY register 14 (the removed V1 `STICK_READ` algorithm) | **Ess.** (per brief) | HOME (core) | **45** | 0 | – | 0 | **MEASURED BUT NOT FULLY VERIFIED** | idle returns 0 for both sticks; direction bits **not exercised** (no joystick event path in ts2068-debug) | – | low; name `STICK` becomes a function name | Joystick games |
| shrink | `COMPILE_2ARG_STMT` shared by `BEEP`/`SOUND`/`POKE`/`PLOT`/`OUT` | Ess. (free) | HOME | **−43** (saves) | 0 | – | 0 | **MEASURED AND TESTED** | same suites; error codes/order unchanged | – | very low | Pays for the whole `OUT` statement and most of `IN`/`STICK` (net HOME for all three: **80**, not 123) |
| **L-HW/EXROM** | `IN()`/`STICK()` handlers placed in **EXROM** behind two fixed 3-byte `jp` slots (`study/lang-hw-exrom`; HOME keeps the table rows and jump words) | alt. | HOME + EXROM | OUT+IN+STICK: **32** (vs 80 in core) | **54** | – | 0 | **MEASURED BUT NOT FULLY VERIFIED** (production build + `study_lang_hw.py` 6/6; component tests not run) | – | low | Total 86 B vs 80 B: it only trades 48 HOME bytes for 54 EXROM bytes — a lever to protect the 350 B HOME reserve, not a saving |
| **ABI 2.1** | *Function* packages: the existing registry is **statement-only**, so `STICK`/`IN` cannot be exposed through it without compiler + VM changes (registration `C` bit 7 = function; `EXT_CALL_RESULT` pinned; operand bit 7 pushes the result) | opt. | HOME mechanism + package | **95** | 0 | **110** for `OUT`+`IN()`+`STICK()` | 0 | **MEASURED AND TESTED** | `study_extfn.py` 8/9 (the one "FAIL" is the expected error *code* differing); `check_package_abi.py` passes as ABI **2.1**, 35 pins | ABI minor bump (old tapes still load; new function packages refused by old ROMs) | medium: new compiler path; **one package resident at a time**, so hardware access would evict SPRITE/SHAPES/MODE/GRAPHICS/PRINTER | Pays only if ≥ 3 further function candidates would otherwise be core. For the three here, **core is cheaper (80 B vs 95 B + a tape load)** |
| **L-PRINT** | Multi-item `PRINT` with `;` and `,` (16-column zones), bare `PRINT`, trailing separator, + `INPUT "p"; v` | opt. (high value) | HOME | **150** (unoptimised) | 0 | – | 0 | **MEASURED AND TESTED** (screen read back through the ROM font) | `study_lang_print.py` 13/13 incl. INPUT prompt+echo+value; **component tests that assert bytecode were not run for this branch** | strict compile (Phase 2D already makes today's `PRINT a; b` an error) | medium: OP_PRINT_* no longer end the line, new `OP_NL`/`OP_PRINT_COMMA`; decompiler (test-only) needs them | The biggest single practical language gap. Parts: INPUT prompt 29, `,` zones 41, bare `PRINT` 20, `;` list core ≈ 60; a shared `TOK_ENDS_STMT` helper saves another 6 |
| **N-3** | End-of-source `FOR` error reports the `FOR`'s own line | opt. | HOME | **23** | 0 | – | +2 B per open `FOR` (compile stack) | **MEASURED AND TESTED** | `study_eof_for.py` 5/5 (simple, later, nested, outer closed, continuation lines) | Phase 2D line counter | low | Cursor lands on the offending `FOR`. `PROC` / block `IF` / forward-label: **ESTIMATED ONLY**, +30–60 B each |
| **ED5** | `LIST` stops on BREAK at a page end | opt. | EXROM | 0 | **3** | – | 0 | **MEASURED** (assembled; behaviour read from source) | not run | – | none | `LIST` of a long program can be left |

### B.3 Editor display (flicker) — detail in §D

| ID | Candidate | Ess. / Opt. | Place | HOME | EXROM | RAM | Confidence | Evidence | Risk | Benefit |
|---|---|---|---|---:|---:|---:|---|---|---|---|
| **I1** | Selective redraw of the active line while typing/backspacing (audit I1) | **Ess.** (high-value usability) | EXROM | 0 | **123** (154 in the refactored form shared with I2) | 2 | **MEASURED AND TESTED** (emulator) | typing 591 k → 70 k T/key (−88 %), 17→0 `GFX_CLS`, differential oracle 0 mismatches (12 scenarios) | low–medium | The characteristic "whole screen blinks on every key" goes away; ~8× lower latency |
| **I1b** | Cell-level typing redraw: only the changed cells are overwritten in place, trailing cells blanked, no row ever cleared (`study/flicker-i1b`) | opt. (only if hardware shows the row-blank flicker of I1) | EXROM | 0 | **341** total (I1 123 + 218) | 11 scratch bytes | **MEASURED AND TESTED** (emulator) | type-10lines 69 562 → 39 918 T/key (worst case: typing at the line start), no `GFX_CLEAR_ROW_TEXT`/`V2_DRAW_TEXT` on the typing path, differential oracle 0 mismatches (3 scenarios) | medium | Removes the last blank interval (a cleared row is blank ≈ 7 ms) |
| **I2** | Cursor-only and two-line redraw for `UP`/`DOWN` within the first 21 lines (audit I2) | opt. | EXROM | 0 | **+238** on top of I1 (I1+I2 = 361) | 6 | **MEASURED AND TESTED** (emulator) | 583 k → 167 k T/key (−71 %), 0 `GFX_CLS` in the window, differential oracle 0 mismatches over 12 scenarios | medium: more geometry rules; falls back to the full redraw outside its proof conditions | Fast navigation in programs ≤ 21 lines; deeper programs still scroll the whole window each key |

### B.4 The D11 study in detail

*What was found before choosing a design* (all **[M]** on the baseline): (1) a decimal literal's digits are accumulated in 16 bits, so `9999.5`
prints `-3107.6999` and `12345.678` prints `24.9099`; (2) `BASIC_FLOAT_TO_STRING_EXROM` uses a 16-bit integer part, so any float ≥ 32 768 prints
`32767.////`: **promotion to float is unusable without fixing the display**; (3) `FOR i = … TO 32767` never ends (the counter wraps); (4) the test corpus
uses literals above 32 767 as 16-bit *addresses* (`POKE 65000`, `USR(61440)`), so "reject all literals > 32 767" breaks hardware access.

| Component | HOME | EXROM | Note |
|---|---:|---:|---|
| `ADD` / `SUB` overflow detect (`ADC`/`SBC` + `jp pe`) | 5 / 3 | 0 | operands already sit in `VM_FLOAT_A/B_VAL`, so promotion is a jump to the existing `.float_path` |
| `VM_MUL_CHECKED` (signed shift-add with carry / lost-bit detection, built on `MATH_SIGN_PREP`/`MATH_APPLY_SIGN`) | **63** | 0 | the dominant cost; exact for all 32-bit products by construction, checked against Python over 105 476 boundary + random pairs |
| `FOR…NEXT` counter overflow ends the loop | 5 | 0 | |
| Literal rule **L-A** (accept ≤ 65 535 as 16-bit address patterns, error 64 above; decimal mantissa ≤ 32 767) | 23 | 0 | shared range-checked digit routine; `POKE 65000`/`USR(61440)` tests pass. `PRINT 65535` still shows `-1` (documented) |
| Literal rule **L-B** (everything > 32 767 is an error) | 21 | 0 | breaks address literals — not recommended |
| Literal rule **L-C** (promote 32 768–65 535 to float + address coercion for `POKE`/`PEEK`/`USR`/`IN`/`OUT`) | **ESTIMATED ONLY** 40–60 | – | cleanest semantics, not built |
| Big-float display (`FLOAT_BIG_TO_STRING`: 32-bit mantissa shift, 10-digit decimal, `.0000`) | 0 | **111** | exact integers to 2³² (`32767*32767` = `1073676289.0000`); the fraction of floats ≥ 32 768 is not shown; ≥ 2³² saturates the shift |
| Runtime error 67 + message (variant E only) | 4 | 23 | |
| Legacy `make check` EXROM fixture guard | 0 | 0 | the legacy fixture (`rom/exrom_build.asm -DEDITOR_TEST_EXROM`) has only **96 B** below its `$DFC0` guard; the display routine is therefore excluded from it with `IFNDEF EDITOR_TEST_EXROM` (found by `make check` failing — an integration fact the owner should know) |

Not covered by either variant (still wrap): `ABS(-32768)`, `-32768 / -1`, the `INT`/`DIV`/`MOD` builtins at the extremes — **ESTIMATED ONLY** 10–25 B for the three.

### B.5 Everything else evaluated (not prototyped unless a cost is shown)

| ID | Item | Class | Place | HOME | EXROM | Confidence | Note |
|---|---|---|---|---:|---:|---|---|
| N-4 | `demos/showcase.txt`: `MOD(N,15)` | **demo compatibility** (name collision), not a missing function | demo edit | 0 | 0 | MEASURED diagnosis | `MOD(a,b)` works (`MOD(20,15)`=5, also inside `DEF FN`). The demo has `DIM N(…)` *and* `DEF FN T(N)=MOD(N,15)`: a DIM'd array name used as a value requires `(` (error 40). Rename the parameter, or (compiler) fall back to the scalar when no `(` follows: ESTIMATED ONLY +20 B HOME |
| ED3 | Typing a command word on a stored line stores it as text | editor correctness | EXROM | – | 25–45 | ESTIMATED ONLY (R10.8 I4) | with N-2 the bare-word case is now an error at `RUN` |
| U7 | Viewport re-centres on every `UP`/`DOWN` past line 20 | usability | EXROM | – | n/a | ESTIMATED ONLY | needed for I2 to help long programs |
| I3 | Page / top / bottom / line-start / line-end keys | usability | HOME + EXROM | 40–70 | 60–110 | ESTIMATED ONLY (R10.8) | needs the physical key-ergonomics trial first |
| I9 | Error codes in messages, `FREE nnnn` in the status bar | usability | EXROM | – | 80–150 | ESTIMATED ONLY | |
| U5/I11 | Runtime error line | usability | HOME + EXROM | 30–60 | 40–80 | ESTIMATED ONLY | needs design |
| U8/I12 | `NEW`/`LOAD` confirmation or undo | usability | EXROM | – | 30–60 | ESTIMATED ONLY | |
| L-STR | String ordering `<>`, `>`, `<=`, `>=` (spec "MUST HAVE") | language | HOME | 30–40 | – | ESTIMATED ONLY | probe: error 3 today |
| L-IF | Single-line `IF c THEN stmt` | language | HOME | 40–60 | – | ESTIMATED ONLY | probe: error 9 today (needs a block `IF`/`ENDIF`) |
| L-ELIF | `ELSEIF` | language | HOME | 10–20 | – | ESTIMATED ONLY | `ELSE IF … ENDIF ENDIF` works; probe: error 2 |
| L-NEXT | Bare `NEXT` | language | HOME | ~10 | – | ESTIMATED ONLY | docs say optional; probe: error 10 |
| L-OUTR | `OUT` value range check (> 255 is an error, as the V1 package) | language | HOME | 10–14 | – | ESTIMATED ONLY | core `OUT` truncates like `POKE` |
| L-DATA | `DATA`/`READ`/`RESTORE` | language | – | – | – | decided against (arrays replace it) | probe: `DATA` error 2 |
| L-FN | `INSTR`, `ATN/ASN/ACS/EXP/LN`, `SCREEN$`, `^`, hex/`1E3` literals | language | package or later | – | – | ESTIMATED ONLY | the calculator wires only 8 literal opcodes; each is real work |
| ABI-F4 | Package error codes overlap the VM's range | ABI | – | – | – | known (A3) | document only |

---------------------------------------------------------------------------------------------------------------------------

### B.6 Known issues from Phase 2D and other documented defects not in the R10.9 work sequence

| Issue | Classification | Status in this study |
|---|---|---|
| `CALL p(FN f(x))` "passes zero" (Phase 2D §5) | **correctness defect** (compiler) | root cause: the nested `FN` re-stashes the shared identifier buffer, so the `CALL` is emitted for label `f`, not `p`. **Fixed, 4 B HOME** (`study/bugfix-callfn`) |
| End-of-source errors land on the empty append line (Phase 2D §5) | optional **usability** improvement | `FOR` measured (23 B HOME, +2 B RAM per open `FOR`); `PROC`/block `IF`/forward label ESTIMATED 30–60 B each |
| `demos/showcase.txt` fails on `MOD(N,15)` (Phase 2D §5) | **demo compatibility** (name resolution), *not* a missing function | diagnosed (§B.5 N-4); rename the demo parameter, or a ~20 B compiler fallback (ESTIMATED) |
| **N-2** a bare word is silently accepted | **correctness defect** (the D3 family; not closed by Phase 2D) | new finding, fixed, 8 B HOME |
| float literal mantissa wraps at 16 bits (`9999.5` → `-3107.6999`, `12345.678` → `24.9099`) | **correctness defect** (part of D11 "large literals") | new finding; the L-A literal rule turns it into error 64 (23 B shared with the integer literal rule) |
| floats ≥ 32 768 print as `32767.////` | **correctness defect** (display), prerequisite of float promotion | new finding; fixed in the D11 promotion variant (EXROM 111 B) |
| `FOR i = a TO 32767` never ends (counter wraps) | **correctness defect** (part of D11) | new finding; fixed (5 B) |
| a name that is a built-in/keyword cannot be a variable (`IN`, `STICK`, `OUT`) once added | **compatibility cost of the new features** | documented; one standalone test used a label `OUT` |
| ED3 command word typed on a stored line is stored as program text | editor correctness | ESTIMATED 25–45 B (R10.8 I4); N-2 now rejects the bare-word case at `RUN` |
| ED4 cursor lost when the active line wraps below row 22 | editor usability | not studied |
| ED5 `LIST` cannot be aborted | usability | **fixed, 3 B EXROM** (`study/list-abort`) |
| U4/U5 messages lack codes; no runtime error line | usability | ESTIMATED (§B.5) |
| U7 viewport re-centres on every move past line 20 | usability; limits I2 | ESTIMATED |
| U8 `NEW`/`LOAD` without confirmation | usability | ESTIMATED |
| U9 no free-memory display | usability | ESTIMATED (I9) |
| U10 no search / block ops / undo; U12 dead `SYMBOL+A/S` keys | editor features | not studied |
| D10 float display truncates (`0.1+0.2` → `0.2999`) | numeric display | not studied (visible again in `3276.7` → `3276.6999`) |
| T-1 `LOAD` does not validate the record chain; ABI-F4/A3 package error codes overlap the VM's | robustness / ABI | not studied |
| DD-1…DD-11 (documentation vs behaviour) | documentation | also: `docs/v1/technical_overview.md` still describes the V1 row-shadow renderer as current; `docs/v1/basic_language_reference.md` is the V1 dialect; the "NEXT var is optional" statement is false for V2 (error 10) |
| `tests/out_bad_value.txt` (V1) expects `OUT 254,256` to be an error | V1 package semantics | core `OUT` truncates like `POKE`; range check ≈ +10…14 B (ESTIMATED) |

---------------------------------------------------------------------------------------------------------------------------

## C. Missing-keyword inventory (probed on the baseline, not read from documents)

A 85-snippet compile probe was run on the Phase 2D ROM (`COMPILE_ERROR_CODE` for each; programs with a result were then run where output
mattered). `0` = accepted. This replaces the stale statements in `docs/v1/basic_language_reference.md`, which still describes the V1 dialect.

**Present and working:** `IF … THEN GOTO`, block `IF`/`ELSE`/`ENDIF`, `FOR…TO…STEP`/`NEXT v`/`EXIT FOR`, `GOTO label`, `PROC name(p)…ENDP`/`CALL name(arg)`,
`DEF FN`/`FN`, `DIM a(n)` (constant `n`, 1-D, plus `DIM a$(n[,w])`), `INPUT v`, `PRINT x` (single item), `AT`/`TAB`/`CLS`/`BORDER`/`INK`/`PAPER`/`FLASH`/`BRIGHT`/`OVER`/`INVERSE`,
`PLOT`/`LINE`, `BEEP`/`SOUND`, `PAUSE`/`POKE`/`PEEK`/`USR`, `CLEAR`, `STOP`/`END`, `RANDOMISE`, `REM`, `AND`/`OR`/`NOT`, `LPRINT`/`CIRCLE`/`FILL`/`MODE`/… (packages),
functions `ABS SGN MOD DIV RND POINT ATTR INT PEEK USR LEN CODE VAL CHR$ STR$ UPPER$ LOWER$ LEFT$ RIGHT$ MID$ INKEY$() SQR PI() RAD DEG SIN COS TAN FREE() FREE(n) DIMN()`.

| Gap | Probe result | Status | Cost / placement (this study) |
|---|---|---|---|
| **`IN(port)`** | error 64 | **missing** | core **22 B** (or package, §B.2) |
| **`OUT port,value`** | error 2 (package absent) / n.a. | **missing** | core **56 B**, 13 B after the shared-helper shrink |
| **`STICK(n)`** | error 64 | **missing** (removed R10.7) | core **45 B** |
| **Multi-item `PRINT` (`;` `,`)** | error 64 (strict compile) | **missing** (was silent truncation before Phase 2D) | **150 B** → see §B.2 |
| **Prompted `INPUT "p"; v`** | error 43 | **missing** | part of the above (29 B) |
| bare `PRINT` (blank line) | error 3 | missing | 20 B |
| `PRINT AT r,c; …` / `PRINT TAB n` | error 3 | missing as PRINT items (standalone `AT`/`TAB` statements exist) | not studied |
| single-line `IF c THEN stmt` | error 9 | missing | ESTIMATED 40–60 |
| `ELSEIF` | error 2 | missing (V1 had it) | ESTIMATED 10–20 |
| bare `NEXT` | error 10 | partial (docs: optional) | ESTIMATED ~10 |
| string `<>`, `>`, `<=`, `>=` | error 3 | partial (`=`, `<` only; spec says MUST HAVE) | ESTIMATED 30–40 |
| `a MOD b` / `a DIV b` infix | error 64 | functions only (`MOD(a,b)`) | not recommended |
| `a$(2 TO 3)` slicing | error 64 | missing (`MID$` covers it) | – |
| `INSTR`, `SCREEN$`, `ATN ASN ACS EXP LN` | error 64 | missing | package-class; each needs real code |
| `^`, `$FF`, `1E3` | 64 / 3 / 64 | missing | – |
| `LET`, `GOSUB`/`RETURN`, `DATA`/`READ`, `REPEAT`/`SELECT`/`WHEN`, `DRAW`, `MERGE`, `RANDOMIZE` | error 2 | intentionally unsupported / replaced (`PROC`/`CALL`, arrays) | no action |
| `RESTORE`, `CONT`, `COPY`, any bare word | **0 (silently accepted)** | **DEFECT N-2** | HOME **8 B** to fix |
| `DIM a(3,3)` / `DIM a(n)` | 37 / 34 | multi-dim and run-time size unsupported (decided) | – |
| `PROC p(a,b)`, `PROC p()` | 20 / 19 | exactly one parameter (decided) | – |
| `INKEY$` without `()` | 29 | by design (0-argument functions need `()`) | – |

Existing functions that could be completed cheaply by reusing services: `IN`/`OUT`/`STICK` (VM `in`/`out`, the removed `STICK_READ`), the V1 `rom/extensions/{cplot,ayreg,out,block,frame,invert}.asm`
packages (R10.25 class C: logic done, only the install stub and 3–4 service calls need porting; `OUT` there is superseded by the core statement if §B.2 is adopted).

---------------------------------------------------------------------------------------------------------------------------

## D. Editor assessment

### D.1 What is release-critical and what is optional

| Class | Items | Status in this study |
|---|---|---|
| **Release-critical (data loss / unusable editor)** | D9a/D9b edit preservation, D5b stray `$10` in the edit line, U6 display/attribute restoration, D4 error-line navigation (kept: Phase 2D) | all prototyped, all MEASURED AND TESTED; Phase 2D's D4 behaviour is unchanged in every build except the deliberate N-3 change in Enhanced (the line counter and `V2_JUMP_TO_ERROR_LINE` were not touched; the 15-case D4 matrix passes in Essential) |
| **Release-critical (runtime)** | D5 BREAK of a running program | MEASURED AND TESTED through the real keyboard matrix |
| **Essential usability** | typing-flicker / latency (I1) | MEASURED AND TESTED (emulator); physical flicker qualification outstanding |
| **Optional enhancements** | two-line `UP`/`DOWN` redraw (I2), abortable `LIST` (ED5), exact end-of-source `FOR` line (N-3), page/top/bottom/line-start/end keys (I3), run-from-anywhere (I4/ED3), status/error text (I9), `NEW`/`LOAD` confirmation (I12), runtime error line (I11), viewport policy (U7) | I2, ED5, N-3 measured; the rest **ESTIMATED ONLY** from the R10.8 audit, §B.5 |

Shared code: the commit-on-navigate path and the `ENTER` path now share one store routine (`V2_STORE_EDIT`); the redraw paths share
`V2_RD_CLEAR_ROWS` / `V2_RD_DRAW_ACTIVE` / `V2_RD_CURSOR`; nine copies of the "is the cursor on the append line" prologue collapse into
`V2_POS_IS_APPEND` (17–20 B back). The fixes and the redraw work touch the same two routines (`V2_NAV`, `V2_REDRAW`) and were developed to compose (§E).

### D.2 Editor flicker investigation

**D.2.1 Where the earlier solution is documented (searched, found).** Searched: all of `docs/`, `rom/`, `basic/`, `kernel/`, `include/`, and git history (`git log --all -i --grep flicker|redraw`).

| Source | What it records |
|---|---|
| `docs/v1/development_log.md` §"Screen-flicker fix" and `docs/v1/programmers_reference.md` §"Screen-flicker fix" | The **V1** editor's cause and cure: `BASIC_REDRAW_PROGRAM` did an unconditional `GFX_CLS` + full re-render on every key; the fix was a **row shadow** (`ROW_SHADOW_POS`/`ROW_SHADOW_FLAGS`/`LAST_RENDERED_ROWS`, ≈ 73–75 B of sysvars, `BASIC_ROW_SHADOW_MATCHES`/`BASIC_UPDATE_ROW_SHADOW`/`BASIC_RESET_ROW_SHADOW`) so a settled row whose content is unchanged is skipped. A "display subsystem" was discussed and explicitly set aside for this reason |
| `docs/v1/technical_overview.md` | States that "rendering uses row-shadow state so unchanged settled lines are not redrawn" — **true of V1, not of the V2 production editor** (documentation discrepancy to correct) |
| `docs/R10_7_PRODUCTION_RAM_ARCHITECTURE_AUDIT.md` §9 | **"Editor redraw/flicker: V2 flashes on redraw; V1 had selective-redraw logic and a dedicated smoke test. Locate both, determine whether V2 bypassed/lost the V1 behaviour, restore/reuse, add regression coverage. Not started."** |
| `docs/R9_CUTOVER_LEDGER.md`, `R8_9_PRODUCTION_INTEGRATION_DESIGN.md` | R9 ledger: *"`basic/editor_integration.asm` is not used: its row-shadow renderer is tied to the old editor, while production reuses `rom/exrom_editor.asm` and the V2 source renderer"*. The R8.9 design had assumed the row-shadow tracking would stay "generic and untouched"; it did not survive the cutover |
| **`docs/R10_8_EDITOR_USABILITY_AUDIT.md` §3 U1/U11, §5 I1/I2, §5.1** | The **V2-shaped** form of the same idea and the one that was implemented here: *dirty-scope* selective redraw — "`V2_REDRAW` already separates viewport choice, per-record draw and status … I1/I2 add a dirty-scope argument … the full path remains the reference behaviour, which makes a differential test a complete regression oracle." Estimates: I1 HOME 0 / EXROM +60–90 / RAM 1–2; I2 EXROM +80–120 / RAM 2 |

The V1 shadow itself was **not** reused: its ≈ 75 B of RAM do not exist in V2 (`IFNDEF V2_COMPACT_SYSVARS` removed them), and the audit's dirty-scope form needs
2–6 B. The existing code that *was* reused: `V2_DRAW_TEXT` (per-line draw with keyword emphasis), `GFX_CLEAR_ROW_TEXT` (bitmap-only clear, itself an earlier
anti-flicker fix), `GFX_INVERT_ATTR`, `EDITOR_WRAP_CALC`/`EDITOR_WRAP_OFFSET_TO_ROWCOL`, `V2_DRAW_STATUS`, `V2_KW_DETECT_SPANS`. **No display code was duplicated and none was added.**

**D.2.2 Routines involved today.** Every key except `LEFT`/`RIGHT` ends in `EDITOR_REDRAW_SCREEN` → hook `V2_REDRAW`: `GFX_CLS` (6 912 bytes, **194 038 T**
measured) → `V2_COUNT_LINES` → per visible record `V2_COPY_RECORD`, `V2_KW_DETECT_SPANS`, `V2_DRAW_TEXT` (a `GFX_PUTCHAR`/`GFX_PUTCHAR_BOLD` per character, **≈ 0.7–0.83 k T** each, measured) →
`V2_DRAW_STATUS` → cursor attribute. `LEFT`/`RIGHT` already have a cursor-only path in `EDITOR_LOOP` (≈ 2 k T).

**D.2.3 What causes unnecessary full-screen updates.** Typing and backspace change *one line*; `UP`/`DOWN` within the window change *two lines and the status*;
neither needs a clear. They triggered `GFX_CLS` plus every visible line: a 10-line program costs ≈ 590 k T (≈ 10 frames at 60 Hz, ≈ 170 ms) per key, a full screen ≈ 930 k–1.05 M T (≈ 16–18 frames).
Wrapped-line cursor moves (`UP`/`DOWN` between rows of one record) did the same.

**D.2.4 Prototype (reuse only).** `study/flicker-i1` (typing / backspace) and `study/flicker-i2` (adds `UP`/`DOWN`).
`EDITOR_LOOP` sets a 1-byte scope (`1` = active line changed, `2` = `UP`/`DOWN`) before it calls the redraw hook; `V2_REDRAW` consults it and the cache
(`V2_ACTIVE_ROW`, wrap-row count, record index), **verifies the geometry itself**, and returns "carry = need the full redraw" whenever it cannot prove that nothing else moves:
a changed row count, an index outside the first 21 lines (the view top would change), a line whose record text no longer has the cached height, a message that overwrote row 23, a
commit-on-navigate store that may have added a line (these last two clear the scope; found by reasoning about the D9 × I2 interaction and covered by the `append-up` scenario),
the first redraw of every editor session, insert/delete line. The full redraw is unchanged and remains the reference.

**D.2.5 Measurements** (T-states from key delivery to the next key wait, ZRCP `get-tstates-partial`; uncontended emulator; counts are real breakpoint hits;
"diff" = number of keys after which the 6 912-byte screen differed from a forced full redraw of the same state):

| scenario | keys | baseline T/key (`GFX_CLS`/key) | I1 T/key | I1+I2 T/key | `GFX_CLS` I1 / I1+I2 | diff mismatches |
|---|---:|---:|---:|---:|---:|---:|
| type-10lines (10-line program, 13 chars + 4 backspaces) | 17 | **591 281** (17) | **69 562** | 71 751 | 0 / 0 | 0 |
| type-20lines (full screen) | 17 | **934 429** (17) | 141 774 | 145 523 | 1 / 1 (a wrap-count change → one full redraw, max 942 k) | 0 |
| type-wrapchg (3-row line) | 19 | 392 695 (19) | 203 312 | 214 271 | 0 / 0 | 0 |
| LEFT/RIGHT (existing cursor path) | 12 | 2 114 (0) | 1 945 | 1 945 | 0 / 0 | 0 |
| updown-10lines | 6 | **583 430** (6) | 584 829 (6) | **167 327** | 6 / 0 | 0 |
| updown-20lines | 6 | **932 197** (6) | 933 541 (6) | **186 431** | 6 / 0 | 0 |
| updown-ends (top/bottom, append line) | 16 | 471 686 (16) | 472 857 | 140 266 | 16 / 0 | 0 |
| updown-wrapped (3-row lines, `RIGHT`s between) | 17 | 587 723 (15) | 586 855 | 230 025 | 15 / 0 | 0 |
| updown-typed (edit, move away, back) | 7 | 507 225 (7) | 306 607 | 110 823 | 4 / 0 | 0 |
| updown-deep (lines 18–27, view scrolls) | 9 | 1 050 262 (9) | 1 050 301 | 564 690 | 9 / 4 | 0 |
| mixed-session | 13 | 486 958 (11) | 291 296 | 109 895 | 6 / 0 | 0 |

(The combined-enhanced build repeats the differential run including the `append-up` scenario after the D9 × I2 fixes; see §E.)

Answers to the questions in the brief:

* **Eliminates unnecessary full-screen redraws?** Yes for typing, backspace and in-window `UP`/`DOWN` (0 `GFX_CLS`); no for scrolling, row-count changes, insert/delete line and the first redraw of a session.
* **Reduces flicker during cursor movement?** `LEFT`/`RIGHT` were already cursor-only. `UP`/`DOWN` now repaint two lines instead of the screen (−71 % time, 0 clears); a full-screen blank per key is gone.
* **During insertion and deletion?** Yes: the only cells touched per key are the active line's rows (each is cleared bitmap-only and redrawn, so a row is blank for ≈ 0.4 frame).
  Measured unit costs: `GFX_CLEAR_ROW_TEXT` = **24 834 T per row** (so a cleared row is blank for ≈ 7 ms, i.e. ≈ 40 % of a 60 Hz frame), `GFX_PUTCHAR` ≈ 0.7–0.83 k T.
  A finer step, **I1b** (`study/flicker-i1b`: redraw only from the first changed character and *overwrite* cells in place, blank only the cells a shrunk row no longer uses, never clear a row) was built:
  type-10lines **69 562 → 39 918 T/key**, type-wrapchg 203 312 → 108 829, **no `GFX_CLEAR_ROW_TEXT` / `V2_DRAW_TEXT` call on the typing path** (no blank interval at all),
  differential oracle 0 mismatches (3 scenarios), at a further **EXROM −218 B** (I1b total −341 B vs I1 −123 B). Typing at the *start* of a line is the worst case for it (the whole tail moves); typing at the end redraws one cell.
* **Improves responsiveness?** Yes: ≈ 590 k → 70 k T per typed key (170 ms → 20 ms at 3.528 MHz, uncontended). With the single-slot key latch this removes the key-drop mechanism described in the audit (U1).
* **MODE 1 / ULAplus / other modes?** The editor always runs in mode 0 with attribute `$38`; U6's `V2_RESET_DISPLAY` now guarantees that on every return. The selective paths write attribute RAM directly (`ATTR_ADDR`, as the existing `LEFT`/`RIGHT` path does) and assume `$38`, so they are only valid in mode 0 — which U6 makes an invariant instead of an assumption. Hi-res/ULAplus **return** behaviour needs hardware.

**Cost:** I1 **EXROM −123 B** (−154 B in the refactored form shared with I2), HOME 0, RAM 2 B; I2 **EXROM −238 B more** (I1+I2 −361 B), RAM 6 B in total. Interaction with D9: +8 B (scope reset in `V2_SHOW_MESSAGE` and after a commit store).

**D.2.6 Unrelated to U6.** U6 (attribute / video-mode restoration after returning from a program) is a *state* defect repaired for 4 B; flicker is a *redraw-volume* defect. They are independent and both are in V2 Essential.

**D.2.7 Hardware qualification still required.** The emulator cannot show flicker. To be checked on a real TS2068 (and recorded in the hardware checklist): (1) visible blanking on typing with the I1 build vs the baseline; (2) row-blank interval during the clear/redraw of the active line (a possible further step is draw-then-pad instead of clear-then-draw); (3) key-drop rate at normal typing speed; (4) held-key repeat on `UP`/`DOWN` (I2); (5) contention-adjusted timings (real redraw time is longer than the figures above); (6) the interaction with `MODE 1` / ULAplus return.

**D.2.8 Recommendation.** Include **I1** in V2 Essential (it is the "flicker per keystroke" cure; 123 B EXROM, no HOME). Include **I2** in Enhanced if EXROM allows (238 B for navigation latency, only helps programs ≤ 21 lines until the viewport policy U7 is also changed). Do not start a display-subsystem rewrite.

---------------------------------------------------------------------------------------------------------------------------

## E. Proposed configurations

Both were **assembled** by merging the isolated branches (no merge into `v2-development`): `study/combined-essential` (worktree `~/2068-Leap-study/combined-essential`) and
`study/combined-enhanced` (worktree `~/2068-Leap-study/combined-enhanced`, built on the Essential branch).

### E.1 Contents

| Item | V2 Essential | V2 Enhanced |
|---|:---:|:---:|
| D5 + D5b BREAK (`study/break`) | ✔ | ✔ |
| D9a + D9b edit preservation (`study/edit-preserve`) | ✔ | ✔ |
| U6 display restore (`study/u6-display`) | ✔ | ✔ |
| D11 overflow → float promotion, literal rule L-A, big-float display (`study/d11-promote-lit`) | ✔ | ✔ |
| D7 FILL exact + BREAK-aware (`study/fill-d7`, package) | ✔ | ✔ |
| N-1 `CALL p(FN f(x))` (`study/bugfix-callfn`) | ✔ | ✔ |
| N-2 bare word is an error (`study/bare-ident`) | ✔ | ✔ |
| `OUT` / `IN()` / `STICK()` in the core ROM + `COMPILE_2ARG_STMT` shrink (`study/lang-hw`) | ✔ | ✔ |
| I1 typing redraw (`study/flicker-i1`) | ✔ | (replaced by I1+I2) |
| `V2_POS_IS_APPEND` shrink | ✔ | ✔ |
| Multi-item `PRINT`, bare `PRINT`, prompted `INPUT` (`study/lang-print`) | – | ✔ |
| N-3 exact `FOR` line (`study/eof-for-line`) | – | ✔ |
| I2 `UP`/`DOWN` redraw (`study/flicker-i2`, incl. I1) | – | ✔ |
| ED5 abortable `LIST` (`study/list-abort`) | – | ✔ |

Not in either: ABI 2.1 function packages (`study/extfn`), the EXROM-resident `IN`/`STICK` variant (`study/lang-hw-exrom`), I1b (`study/flicker-i1b`), the D11 error variant (`study/d11-error`): alternatives, §B.

### E.2 Budgets

| Configuration | HOME free | EXROM free | SHAPES package | How obtained |
|---|---:|---:|---:|---|
| Phase 2D baseline | 565 | 802 | 795 / 1 024 | `make budget` **[M]** |
| **V2 Essential** | **353** | **488** | 1 007 / 1 024 | **ASSEMBLED** (`study/combined-essential`, `make budget`) |
| **V2 Enhanced** | **180** | **239** | 1 007 / 1 024 | **ASSEMBLED** (`study/combined-enhanced`, `make budget`) |
| historical reserve targets | ≥ 350 | ≥ 800 | – | policy, not physical |
| physical capacity | 16 384 | 8 192 | 1 024 | hardware |

Essential uses 212 B of HOME and 314 B of EXROM relative to Phase 2D; Enhanced 385 B and 563 B. Both are physically feasible (Essential / Enhanced: HOME 2.2 % / 1.1 % free; EXROM 6.0 % / 2.9 % free). Against the *historical* targets: Essential
meets HOME (353 ≥ 350) and is 312 B under the EXROM target; Enhanced is 170 B under HOME and 561 B under EXROM — in line with your instruction not to reject a feature for that.

**Arithmetic projections (not assembled — built from the additive §B costs, which the two assembled builds reproduced exactly; treat as ±0 for a pure swap):**

| Variation | HOME free | EXROM free | Note |
|---|---:|---:|---|
| Essential, D11 *error* variant instead of promotion | 351 | 576 | HOME −2, EXROM +88 |
| Essential, `IN`/`STICK` handlers in EXROM (`lang-hw-exrom`) | 401 | 434 | trades 48 HOME for 54 EXROM |
| Essential without `STICK` | 398 | 488 | −45 B HOME |
| Essential with I1b instead of I1 | 353 | 270 | +218 B EXROM for a blank-free typing redraw |
| Essential + ABI 2.1 function packages instead of core `IN`/`STICK` (keeping core `OUT`) | ≈ 353 + 22 + 45 − 95 = 325 | 488 | worse than core; the 110 B package is extra |
| Enhanced without I2 (typing redraw only) | 180 | 485 | I2 and its 8 B interaction fix are 246 B of EXROM |
| Enhanced with `PRINT` trimmed to the `;` list + trailing separator (no `,` zones, no bare `PRINT`) | ≈ 241 | 239 | −61 B |
| Enhanced + R10.10 editor estimate (HOME +75…+140, EXROM +385…+655, `R10_8_PRE_R11_PLAN.md`) | ≈ 40…105 | **negative** | does not fit next to Enhanced; R10.10 would have to replace parts of it (I1/I2/D9 are already inside that estimate) |


### E.3 Qualification actually performed

All headless (ZEsarUX through ts2068-debug); `make -n test | grep -ci fuse` = 0; **no Fuse/X11, `make test-legacy` not run**. Everything below is emulator evidence.

| Suite | Phase 2D | **Essential** | **Enhanced** |
|---|---|---|---|
| `make check` (assemble, lint, ABI, builtin tables, docs, storage contract, legacy fixtures) | rc 0 | **rc 0** (ABI 2.0, 16 slots, 34 pins) | **rc 0** |
| Headless smoke ROMs | 9/9 | 9/9 | 9/9 |
| V2 standalone component tests | 38/38 | **38/38** (one pass before the last two merges, which changed only the FILL package and test tools; plus the single final `make test` below) | **37/37** — `chunk_refill_boundary` no longer fits its flat 16 K image (41 B over, §E.4 #8) |
| `v2_production_checks.py` | 19/19 | **19/19** (after renaming the label `out`, §E.4 #2) | **19/19** |
| `v2_fill_check.py` | 10/10 | **10/10** | **10/10** |
| Production gate `v2_prod_regress.py` | 115 PASS | **115 PASS**, 0 XFAIL/FAIL/XPASS (incl. all 15 D4 error-line cases and all 18 D3 families) | **113 PASS** (the two `PRINT x; x` D3 cases removed — now valid; `D4-eof-for` ×2 expect the `FOR` line) |
| Array Store gate | 98 PASS | **98 PASS** | **98 PASS** |
| Known-defect suite | 3 PASS + **14 XFAIL** | **15 PASS, 0 XFAIL**: D5b, D5 (re-written for the real keyboard matrix), D9 ×2, D11 ×4, U6, D7 ×3 are now gate cases; 3 controls; the two pathological D7 scenarios are exact but exceed the harness's cap (§B.1) and were left out, not hidden | **15 PASS, 0 XFAIL** |
| Study suites (focused) | – | break 6/6, edit-preserve 9/9, u6 4/4, callfn 7/7, d11 prints 15/15, literals 13/13, lang_hw 6/6, oracle `+ − * *` 4 × 9 476 pairs 0 mismatches, flicker differential 12 scenarios 0 mismatches | the same plus `eof-for` 5/5, `lang-print` 13/13; flicker differential 12 scenarios (incl. `append-up`) 0 mismatches |
| One uninterrupted `make test` on the final tree | – | **exit status 0**, 2 395 s: smoke 9/9, standalone 38/38, production checks 19/19, FILL 10/10, gate 115, Array Store 98, known-defect suite 15 PASS / 0 XFAIL (`docs/V2_FEATURE_COST_STUDY_LOGS/final_make_test_essential.log`; commit `0dedab3`) | not applicable as-is (needs the `chunk_refill_boundary` migration) |

Honest limits of this evidence: the production tests drive the key latch directly for most editor paths (as in Phases 1–2D) — the one exception here is BREAK, which was run through the emulated keyboard *matrix*;
the tape path is a synthesised EAR stream; STICK directions, hi-res/ULAplus return, visible flicker and real-clock FILL time are untested; the study suites and the oracle live on the branches, not in the gate.


### E.4 Integration facts found only by combining (each is a reason not to trust the isolated numbers alone)

1. **Costs were additive** — the HOME and EXROM deltas of both assembled configurations equal the sums of the isolated measurements (checked to the byte), so the §B matrix can be used for arithmetic.
2. **A core `OUT` keyword reserves the word.** Two existing tests used a *label* named `out` (`rom/test_v2_control_stack.asm`, `tools/v2_production_checks.py` case `goto-out-of-for`) and failed; both were renamed `fin` in the combined branches. Likewise `IN` and `STICK` stop being usable as variable names. A package-based `OUT` would only reserve the word while loaded.
3. **`make check`'s legacy EXROM fixture (`rom/exrom_build.asm -DEDITOR_TEST_EXROM`) has 96 B of room below its `$DFC0` guard**; the 111 B big-float display routine had to be excluded from it (`IFNDEF EDITOR_TEST_EXROM`). The component-test EXROMs also have no `exrom_calc`, so the display routine may use only sysvars and the carry returned by `CALC_FP_TO_INT`.
4. **Opcode and token numbers collide between independently developed branches** (`OUT` = opcode 67 vs `OP_NL`; `TOK_KW_OUT` vs `TOK_SEMI`); resolved by renumbering in the Enhanced merge (OUT 67, NL 68, COMMA 69; tokens 65/66).
5. **D9 × I2:** an append-line commit followed by `UP` left the status count stale (the differential oracle caught it: 1 mismatch on the unfixed merge); fixed by clearing the redraw scope in `V2_SHOW_MESSAGE` and after a commit store (+8 B).
6. The existing **`D5` known-defect case pokes the key latch** and therefore cannot observe an ISR-side BREAK; the combined branch replaces it with a real-matrix press. Two pathological **D7 scenarios** (staggered dots, 1-px ladder) are exact but need ≈ 800 M instructions (> the 400 M-instruction harness cap) and were left out of the combined gate (not silently: listed in §B.1).
7. **PRINT's bytecode semantics change** (`OP_PRINT_NUM/STR` no longer end the line): the test-only decompiler does not know `OP_NL`/`OP_PRINT_COMMA`; bytecode-asserting component tests were not re-run on the lang-print branch alone, but the full `make test` of the Enhanced build covers them (§E.3).

8. **Test-infrastructure capacity:** the legacy flat-16 K component test `rom/test_v2_chunk_refill_boundary.asm` no longer assembles in Enhanced (it embeds vm_core + compiler and is **41 B over** its image; Essential still fits). It needs the same migration to the two-bank harness that 33 other tests already received; it was excluded from the Enhanced standalone run with a runner copy (`tools/run_v2_standalone_tests_skip_crb.sh`), giving 37/37 instead of 38/38.
9. **The test-only decompiler** must skip `OP_NL`/`OP_PRINT_COMMA` for the byte-exact `block_if` decompile check (`block_if` failed until it did); the production image does not contain the decompiler.
10. **Gate expectations that Enhanced deliberately changes:** two D3 cases (`PRINT x; x`, `PRINT x, x` were asserted to be errors) and two D4 cases (`D4-eof-for`, `D4-eof-trailing-colon`: cursor now on the `FOR`, line 0) were edited in `study/combined-enhanced`; in Essential nothing in the 115-case gate needed to change.

### E.5 Compatibility effects to add to `COMPATIBILITY_BREAKS.md` if adopted

* Programs that relied on a bare word being ignored now get error 64 (N-2).
* Literals ≥ 65 536 and decimal literals with a mantissa > 32 767 are compile errors (they used to wrap).
* `OUT`, `IN`, `STICK` become reserved words (core variant).
* `PRINT a; b` / `PRINT a, b` are accepted (Enhanced) — they were an error since Phase 2D and a silent truncation before.
* Results of `+`, `−`, `*` that leave the 16-bit range are now floats (printed as `90000.0000`), not wrapped integers.
* The editor now ignores control codes below `$20` and keeps uncommitted edits across `UP`/`DOWN`/insert-line.

---------------------------------------------------------------------------------------------------------------------------

## F. Prototype inventory

All branches are local (`git branch --list 'study/*'`), each with a worktree at `~/2068-Leap-study/<name>`; none was pushed. Helper scripts used by these runs are in `tools/study/` on `study/report` (and in the individual `tools/` directories); the running log of the study is `docs/V2_FEATURE_COST_STUDY_NOTES.md`. Every measurement was made on the real production image/package (`make build`, `make v2-packages`) — `make budget` for sizes.

| Branch / worktree | Commit | Purpose | Build | Test command | Measured | Known limitations |
|---|---|---|---|---|---|---|
| `study/baseline` | `a4524e1` | Phase 2D reference (+ tool copies only) | `make budget` | `python3 tools/v2_known_defects.py` | 565 / 802 free; 3 PASS + 14 XFAIL | none |
| `study/break` | `8ee4f1a` | D5/D5b BREAK | `make build` | `python3 tools/study_break_matrix.py`; `python3 tools/v2_known_defects.py D5` | HOME −21, EXROM −13; 6/6 real-matrix cases ×2; D5b XPASS | INPUT key wait and package loops (FILL aside) are not polled; BREAK keycap unverified; the old latch-poking D5 case stays XFAIL |
| `study/edit-preserve` | `2c6bca6` | D9a/D9b | `make build` | `python3 tools/study_edit_preserve.py`; `v2_known_defects.py D9` | EXROM −83 (D9b alone −0); 9/9; both D9 cases XPASS | compare-based commit; the no-compare variant (−55) rejected |
| `study/u6-display` | `2358ac5` | U6 | `make build v2-packages` | `python3 tools/study_u6.py`; `v2_known_defects.py U6` | EXROM −4; 4/4; U6 XPASS | ULAplus palette state not reset/verified |
| `study/fill-d7` | `1a9736a` | D7 FILL (package) | `make v2-packages` | `python3 tools/v2_fill_check.py`; `python3 tools/study_fill_time.py <scenario>`; `python3 tools/study_fill_break.py` | package 795 → 1007 B; fixtures 10/10; 4 adversarial scenarios exact, 2 exact but 453–787 s emulated | 17 B left in the window; pathological images are minutes-slow |
| `study/d11-error` | `84ac49b` | D11 error variant | `make build` | `python3 tools/study_vm_oracle.py mul|mulop|add|sub 100000`; `v2_known_defects.py D11` | HOME −101, EXROM −23; 4 × 105 476 oracle pairs, 0 mismatches | breaks address literals > 32 767 (literal rule L-B) |
| `study/d11-promote` | `5c2c075` | D11 promotion (arithmetic + display) | `make build` | oracle with `ORACLE_PROMOTE=1`; `python3 tools/study_d11_print.py` | arith HOME −76; display EXROM −106; 3 × 105 476 pairs, 0 mismatches; 15/15 prints | literals still the error variant's |
| `study/d11-promote-lit` | `85a0f25` | D11 promotion + literal rule L-A (final) | `make build` | `ORACLE_PROMOTE=1 python3 tools/study_vm_oracle.py add|sub|mulop`; `study_d11_print.py`; `study_d11_literals.py` | HOME −99, EXROM −111 | fraction of floats ≥ 32 768 not shown; ≥ 2³² saturates; `ABS(-32768)`, `-32768/-1` still wrap |
| `study/bugfix-callfn` | `c57f604` | N-1 CALL p(FN f(x)) | `make build` | `python3 tools/study_callfn.py` | HOME −4; 7/7 (5 fail on baseline) | – |
| `study/bare-ident` | `712afec` | N-2 bare word | `make build` | `python3 tools/study_bare_ident.py` | HOME −8; 13/13 | – |
| `study/lang-hw` | `9f0bb59` | core OUT / IN() / STICK() + COMPILE_2ARG_STMT | `make build` | `python3 tools/study_lang_hw.py`; `python3 tools/check_builtin_tables.py` | HOME −123 (−80 with the shrink); 6/6 | STICK directions unverified; OUT truncates (no range check); reserves `OUT`/`IN`/`STICK` |
| `study/lang-hw-exrom` | `b8c093e` | IN/STICK handlers in EXROM | `make build` | `python3 tools/study_lang_hw.py` | HOME −32, EXROM −54 for all three | component tests not run |
| `study/extfn` | `7c349f2` | ABI 2.1 function packages + HW package | `make build v2-packages` | `python3 tools/study_extfn.py`; `python3 tools/check_package_abi.py` | HOME −95; package 110 B; 8/9 (1 expected code difference) | one package resident at a time; statement-typed names used as functions are not rejected |
| `study/lang-print` | `bc5ad09` | multi-item PRINT, bare PRINT, INPUT prompt | `make build` | `python3 tools/study_lang_print.py` | HOME −150; 13/13 (screen read back) | bytecode-asserting component tests not run on this branch alone; decompiler lacks the new opcodes |
| `study/eof-for-line` | `63ace54` | N-3 FOR opening line | `make build` | `python3 tools/study_eof_for.py` | HOME −23; 5/5 | PROC / IF / label not done |
| `study/list-abort` | `63df1d0` | ED5 | `make build` | – | EXROM −3 | behaviour not run |
| `study/shrink-pos` | `907ac1b` | V2_POS_IS_APPEND | `make build` | `make check`-level (assembled; behaviour unchanged by construction) | EXROM +17 back | – |
| `study/flicker-i1` | `4fce1bf` | I1 typing redraw | `make build` | `python3 tools/study_flicker.py --diff` | EXROM −123; 591 k → 70 k T/key; 0 mismatches | row blank ≈ 7 ms remains |
| `study/flicker-i1b` | `75fa9c3` | I1b cell-level typing redraw | `make build` | `python3 tools/study_flicker.py --diff type-10lines type-wrapchg mixed-session` | EXROM −341; → 40 k T/key; 0 mismatches | +218 B for the last blank interval |
| `study/flicker-i2` | `cdff627` | I2 UP/DOWN redraw (on I1) | `make build` | `python3 tools/study_flicker.py --diff` | EXROM −361 (I1+I2); 583 k → 167 k T/key; 0 mismatches (12 scenarios) | D9 interaction fixed only in the combined branch |
| `study/combined-essential` | `0dedab3` | V2 Essential (merge) | `make build v2-packages` | `make check`; `make test`; `tools/study/study_run_all.sh <worktree> <port> <out>` | HOME 353 / EXROM 488 free | see §E.3 |
| `study/combined-enhanced` | `8379ab5` | V2 Enhanced (merge) | `make build v2-packages` | `make check`; `make test`; `study_run_all.sh … enhanced` | HOME 180 / EXROM 239 free | see §E.3 |
| `study/report` | (tip of the branch) | this report + study notes + helper scripts | – | `python3 tools/check_docs.py` | – | – |

Notes: `study/baseline` carries one extra commit that only adds copies of the study tools to `tools/` (no ROM source differs from `7ae0599`). `study/report` is based on it. The `combined-*` branches contain merge commits of the isolated branches plus the integration edits listed in §E.4.

---------------------------------------------------------------------------------------------------------------------------

## G. Recommended decisions (value relative to memory cost)

Ranked by *value per byte*, using the measured costs of §B. "Free" means the item costs nothing or gives bytes back.

| Rank | Item | HOME / EXROM / pkg | Why |
|---:|---|---|---|
| 1 | **D9b** (keep the typed line on `PROGRAM FULL`) | 0 / 0 | Data loss, free |
| 2 | **`V2_POS_IS_APPEND`** (shrink) | 0 / **+17…+20 back** | Pure saving, no behaviour change |
| 3 | **`COMPILE_2ARG_STMT`** (shrink) | **+43 back** / 0 | Pure saving; makes `OUT` nearly free |
| 4 | **U6** display/attribute restore | 0 / 4 | Editor unusable after `MODE 1`/`BORDER` otherwise |
| 5 | **N-1** `CALL p(FN f(x))` | 4 / 0 | Silent wrong call; the shared helper makes it nearly free |
| 6 | **N-2** bare word is an error | 8 / 0 | Silent no-op of mistyped / unsupported commands |
| 7 | **D5 + D5b** BREAK | 21 / 13 | Runaway programs cannot be stopped today |
| 8 | **`OUT` + `IN()`** (full 16-bit port) | 35 net after the shrink / 0 | Brief's highest-priority hardware access; cheaper in core than anywhere else |
| 9 | **D9a** commit-on-navigate | 0 / 83 | Edits are never discarded by moving |
| 10 | **I1** typing redraw | 0 / 123 | −88 % typing latency, no per-key screen clear |
| 11 | **D11** overflow | 99 / 111 (promotion) or 101 / 23 (error) | Silent wrong arithmetic is the most serious *semantic* defect left; see decision (1) below |
| 12 | **D7** FILL exact | pkg +212 | No ROM cost; the price is minutes-long worst-case images |
| 13 | **`STICK()`** | 45 / 0 | Cheap; unverified directions |
| 14 | **N-3** `FOR` opening line | 23 / 0 | Small, polish |
| 15 | **ED5** abortable `LIST` | 0 / 3 | Tiny |
| 16 | **Multi-item `PRINT` + prompted `INPUT`** | 150 / 0 (≈ 120 with `TOK_ENDS_STMT` and without the optional parts) | The largest practical language gap; the cost is why it belongs in Enhanced, not Essential |
| 17 | **I2** `UP`/`DOWN` redraw | 0 / 238 | Only helps programs ≤ 21 lines until viewport policy U7 changes |

**Definitely include (Essential):** items 1–10, 11 (after decision 1), 12, and 13. **Inexpensive enough to include:** 14, 15. **Better as packages:** D7 (already); *hardware access* only if the owner
wants ABI 2.1 function packages for other reasons (§B.2: 95 B mechanism + 110 B package vs 80 B in core; one resident package at a time). **Defer:** runtime error line (U5/I11), page/top/bottom keys (I3 — needs the physical
ergonomics trial), run-from-anywhere (I4), status codes (I9), `NEW`/`LOAD` confirmation (I12), string ordering operators, single-line `IF`, `ELSEIF`, `INSTR`/`ATN`/`EXP`/`LN`, multi-dimensional arrays, `DATA`/`READ`.

**Genuine unresolved choices (the study does not make them for you):**

1. **D11 — error or promotion, and the literal rule.** Promotion is the stated preference and is now demonstrated exact (oracle) *and* printable; it costs about the same as the error variant in HOME and 88 B more in EXROM
   (the display routine). The literal rule is the real design choice: **L-A** (≤ 65 535 stay 16-bit address patterns; `PRINT 65535` shows `-1`) keeps `POKE 65000` working; **L-C** (promote and coerce addresses) is cleaner but unbuilt (+40…60 B est.).
2. **Hardware functions — core builtins or ABI 2.1 function packages.** Core is cheaper for `IN`/`OUT`/`STICK`; a function-package mechanism is only worth its 95 B + the "one package at a time" limit if several further functions would use it.
   Also: a core `OUT` **reserves the word** — an existing standalone test used a label named `OUT` (renamed `FIN` in the combined branches), and `IN`/`STICK` become unusable as variable names.
3. **`OUT` value range:** truncation to a byte (as `POKE`) or an error for > 255 (V1's `tests/out_bad_value.txt` expects an error; ≈ +10…14 B, ESTIMATED).
4. **`PRINT` grammar scope:** which of bare `PRINT`, `,` zones, prompted `INPUT` are worth their bytes (29 / 41 / 20 B); the bytecode semantics of `OP_PRINT_*` change (they no longer end the line).
5. **FILL:** accept an exact-but-slow worst case, or spend design effort on a faster exact algorithm (not studied).
6. **Reserve policy:** Essential leaves HOME 353 / EXROM 488; Enhanced HOME 180 / EXROM 239 — both are physically fine; Essential meets the HOME target and misses the EXROM one, Enhanced is below *both* historical targets (350 / 800). R10.10's editor budget (HOME +75…+140, EXROM +385…+655) no longer fits next to Enhanced.

---------------------------------------------------------------------------------------------------------------------------

## H. Next implementation sequence (after you choose the feature set)

1. **No-regret group first, one commit each, `make check` + focused tests after each:** `V2_POS_IS_APPEND`, `COMPILE_2ARG_STMT`, N-2 bare word, N-1 `CALL p(FN f(x))`, U6, D9b. (All independent; ≈ 0 net bytes.) Convert the `D*` known-defect cases to gate cases in the same commit and drop their markers (strict XPASS accounting).
2. **BREAK + D9a** together (both touch `V2_NAV`/`EDITOR_LOOP`); rewrite the `D5` case to use the real keyboard matrix (`tools/study_break_matrix.py` is the model); add the 9 `study_edit_preserve` cases to the gate.
3. **D11** after decision (1): take `d11-promote-lit` (or `d11-error`), keep `tools/study_vm_oracle.py` (exact reference, real Z80 driver) as a gate tool, add `study_d11_print.py` / `study_d11_literals.py`; keep the `IFNDEF EDITOR_TEST_EXROM` guard around the big-float display (the legacy `make check` fixture has 96 B of room); update `docs/COMPATIBILITY_BREAKS.md`.
4. **I1** (typing redraw) with `tools/study_flicker.py --diff` as a gate (it is the differential screen oracle); then **I2** only if EXROM allows and viewport policy U7 is on the list.
5. **`OUT` / `IN()` / `STICK()`** (core). Hardware checks in §H.1. Update the language reference and `docs/PACKAGE_ABI.md` (only if function packages are chosen).
6. **D7 FILL package** (no ROM cost); decide the time limit for the harness (the two pathological scenarios need ≈ 800 M instructions).
7. **Enhanced items** in value order: `PRINT`/`INPUT` grammar, N-3, ED5.
8. After each step `make check`; after steps 2, 3, 4 and at the end a full `make test`. **Hardware** (cannot be done headless): see §H.1.

### H.1 Hardware validation list (nothing here was possible in the emulator)

| Feature | What to check on a real TS2068 |
|---|---|
| `IN` / `OUT` | a **non-`$FE`-mirrored** port: AY registers (`OUT 245,r` / `OUT 246,v` / `IN(246)`), Timex screen-mode port `$FF`, ULAplus `$BF3B`/`$FF3B`, Dock bank `$F4`; **keyboard half-rows through `IN(port)`** with the high byte selecting the row (`IN(65278)`, `IN(63486)`, …), which the emulator confirms but a real ULA/Dock decode should be seen to match |
| `STICK` | all four directions + fire on joystick 1 and 2, idle value, bounce; the V1 asymmetry (stick 2 = one bit) |
| BREAK | the physical BREAK key matrix position (CAPS SHIFT+SPACE is what the ISR decodes); BREAK during a long `PAUSE`, a `GOTO` loop, a long `FILL` |
| Flicker (I1/I2) | visible blanking with the baseline vs the prototype on a CRT and an LCD; key-drop rate at normal typing speed; held-key repeat on `UP`/`DOWN`; contention-adjusted redraw time |
| U6 | return to the editor after `MODE 1`, `ULAPLUS`, `PALETTE`, `BORDER`, colour statements on hardware that supports hi-res/ULAplus (the emulator in use has no ULAplus) |
| FILL | worst-case time of the exact fill on the real clock (≈ 8–13 min for the two pathological patterns) |
| Tape | unchanged by this study; the Phase 2A–2C owed items remain |

