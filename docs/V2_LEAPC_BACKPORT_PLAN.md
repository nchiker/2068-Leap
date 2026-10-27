# V2 back-port plan: improvements from 2068-Leap-C

**2026-10-25. Draft for the owner; nothing here is implemented.** Source: a review of `~/2068-Leap-C`
(its `platform/UPSTREAM.md` deltas D1-D21, milestone reports M1-M11, tools) against V2 HEAD `77f1baa`.

Tags: **[M]** measured (V2 build or test), **[L]** measured in Leap-C, **[E]** estimate.

## 0. Starting point and the space floors

Clean build of `77f1baa` [M]: **HOME 275 B free, EXROM 26 B free.**

### ROM spending policy (owner decision F1, 2026-10-25): weighted, not a fixed floor

Free ROM is not a goal in itself (the stock TS2068 ROM shipped with none). Bytes are spent where they buy
the most, and only a small emergency reserve is held back.

| ROM   | Emergency reserve | Use                                                                                                           |
| ----- | -----------------:| ------------------------------------------------------------------------------------------------------------- |
| HOME  | **64 B**          | Bug fixes only (Class A below), so a defect found after a release never needs a shrink before it can be fixed |
| EXROM | **32 B**          | The same                                                                                                      |

Everything above the reserve is spent by weight:

| Class | What                                                                                                                                      | Rule                                                                                                                                |
| ----- | ----------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| **A** | Correctness bugs, licensing                                                                                                               | Always done. If the bytes are not there, the shrink or removal that frees them comes first                                          |
| **B** | Significant improvements: a common path ≥ 1.5× faster, more program capacity, a new capability users asked for, a known open defect fixed | Done when the benefit is large for the bytes; ranked by benefit per byte. A big win is taken even if it uses most of the free space |
| **C** | Minor or cosmetic                                                                                                                         | Only when cheap (about 10 B or less) or free                                                                                        |

Further rules:

1. **Removals and smaller replacements come first**: they are free value and make room for A and B.
2. Each item records its measured bytes and its benefit in the ledger below, so the weighting is visible.
3. `make check` fails below the emergency reserve (phase 0, item 0.4).

### Running ledger (free bytes after each phase)

| After                        | HOME    | EXROM   | Basis                                                                                                   |
| ---------------------------- | -------:| -------:| ------------------------------------------------------------------------------------------------------- |
| today                        | 275     | 26      | [M]                                                                                                     |
| phase 1 (space)              | **373** | **138** | [M]: 1.1 EXROM −112; 1.2 HOME −36; 1.3 HOME −12; 1.4 HOME −2; 1.5 HOME −48                              |
| phase 2 (bug fixes)          | **358** | **123** | [M]: phase total HOME −15, EXROM −15 (items 2.1-2.3; v2.0.3)                                            |
| phase 3 (licensing)          | **358** | **199** | [M]: 3.1 tape block I/O EXROM +19; 3.2 calculator dispatcher EXROM +57                                  |
| phase 4 (display quick wins) | **354** | **208** | [M]: 4.1 HOME +4; 4.2, 4.3 0; 4.4 EXROM +16, status-bar attribute fill EXROM −25                        |
| redraw from the cursor line  | **354** | **186** | [M]: EXROM +22                                                                                          |
| 5.1 decimal literals         | **441** | **186** | [M]: HOME −139 value/divisor path removed, +41 16-bit digits in `NUM_PARSE_CALC`, +11 `5.` stays an INT |
| R1 calculator rounding       | **441** | **905** | [M]: EXROM +739 Leap-C's float core, −20 three faster loops                                             |
| phase 5 (speed)              | ≥ 64    | ≥ 32    | Class B: each item sized and weighed before it is started; 5.0 first if the room is not there           |

Every [E] is replaced by `make budget`'s figure as each item lands.

## Phase 0: tooling and guard rails (no ROM change)

Goal: every later phase runs faster and is checked automatically. Do these first because each later
phase's qualification run pays for them.

| #    | Item                                                                                                                                                        | Source                                        | Effort | Notes                                                                                                                                                                                                                                                                   |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0.1  | **ZRCP latency fix**: `TCP_NODELAY` + re-armed `TCP_QUICKACK` in `ts2068-debug`'s `ZRCPClient.connect`                                                      | Leap-C `tools/lcharness.py:39-82`             | S      | Leap-C: 41 ms → 0.04 ms per reply; full suite 3,333 s → 305 s with the pool [L]. A change to ts2068-debug, so every project gains. Re-measure V2's 47-min `make test` after                                                                                             |
| 0.2  | **One persistent ZRCP client** in `tools/v2_headless.py` instead of a CLI process per command                                                               | qharness already does this                    | M      | **Done as opt-in (`V2_HEADLESS_INPROC=1`)**: no wall-clock gain on the prod suites (1,826 s in-process vs 1,630 s, loaded host); their time is the tape cases' emulated waits, and one case stalled 477 s in-process [M]. Those long tape cases are the target for 0.10 |
| 0.3  | **`make test-fast`** (corpus + production gate, a few minutes)                                                                                              | Leap-C `run_tests.py --fast`                  | S      | Then, later, one worker pool across stages                                                                                                                                                                                                                              |
| 0.4  | **Emergency reserve enforced by `make check`** (`report_budget.py --check`, reserves from §0)                                                               | Leap-C `budget.toml`, `budget.py --check`     | S-M    | Per-component budgets optional; the two reserves are the point                                                                                                                                                                                                          |
| 0.5  | **Provenance scan** (`tools/provenance.py`: runs of ≥12 B shared with the stock ROMs) in `make check`, skipped when stock ROMs are absent                   | Leap-C `tools/provenance.py`                  | S      | Known hits today (the review's scan): two PO-GR-2 runs in `GFX_CHAR_TO_FONT_OFFSET`, five SA/LD-BYTES runs in storage. Start with these as an allow-list that phase 3 empties                                                                                           |
| 0.6  | **Power-on RAM boot test**: fill `$4000-$FFFF` with patterns after reset, boot, compare idle RAM and run the corpus                                         | Leap-C `tools/poweron.py` (found its UDG bug) | S-M    | Proves item 2.2 and finds any other uninitialised cell                                                                                                                                                                                                                  |
| 0.7  | **Banking invariants in the canary**: depth == 1 while the VM runs, 0 inside `OP_CALL_EXT`; no write to `$C000-$DFFF` with EXROM in; stack never in chunk 6 | Leap-C `tools/memguard.py`                    | M      | Guards items 2.3 and phase 7                                                                                                                                                                                                                                            |
| 0.8  | **Fuse frame-count probe** for item 1.4 (Fuse frame count vs `FRAMES` over a float loop)                                                                    | Leap-C M9 §5.4                                | S      | **Owner approval needed**: Fuse runs only on request. ZEsarUX cannot show the defect                                                                                                                                                                                    |
| 0.9  | Reproducible-build check (two clean builds, identical hashes)                                                                                               | Leap-C `tools/check_repro.sh`                 | S      |                                                                                                                                                                                                                                                                         |
| 0.10 | Fast emulation (`--emulatorspeed 1000 --frameskip 49`), **default** in ts2068-debug (`TS2068_DEBUG_ZESARUX_FAST=0` for real speed)                          | Leap-C `lcharness.py:32-36`                   | S      | **Done (F7)**: `make test` 1,940 s vs ~3,200 s at real speed, all PASS incl. D5 and the tape cases [M]                                                                                                                                                                  |

## Phase 1: free space first

Goal: EXROM above its floor before anything spends it; HOME gains a margin. Pure removals or
smaller replacements, no behaviour change.

| #   | Item                                                                                                                                                                          | HOME           | EXROM        | Notes                                                                                                                                                                                                                                              |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------:| ------------:| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1.1 | **Editor fallbacks removed under `IFDEF V2_PRODUCTION`** (Leap-C D15-D17: unset-hook UP/DOWN and redraw fallbacks, NEXT/PREV ERROR and HOME/END cases, `EDITOR_BLOCK_DELETE`) | 0              | **−112 [M]** | Production build assembles with the deletions [M]; not yet run. Keep them for the V1 fixtures, `exrom_checker.asm` and `rom/test_editor*` (which test `EDIR_HOME/END`). If the R10.8 navigation keys are planned, keep HOME/END (a few bytes back) |
| 1.2 | **xorshift RND** replacing `MATH_RND16`'s one-bit LFSR step (consecutive values are correlated today)                                                                         | ~−51 [L]       | 0            | Also a quality fix and ~25× faster (143 T vs ~3,800 T) [L]. Keep the R-register seeding and MOD scaling                                                                                                                                            |
| 1.3 | **Clean-room block-graphics glyph builder** (Leap-C D21)                                                                                                                      | −12 [L]        | 0            | Same contract; removes the PO-GR-2 copies (licensing, phase 3)                                                                                                                                                                                     |
| 1.4 | **Remove `di` from `BANK_PAGE_EXROM_IN/OUT`** (Leap-C D14)                                                                                                                    | −2             | 0            | Is a bug fix (lost frame interrupts in float code; Leap-C lost 1% of frames [L]). Here because it is a removal. The ISR touches no paging state (checked). Confirm with 0.8                                                                        |
| 1.5 | **Register-only `MATH_UMUL16` / `MATH_UDIV16`** (Leap-C `RT_UMUL/RT_UDIV`, incl. the dead-branch removal)                                                                     | ± (size first) | 0            | 60000/7: 3,584 → 1,479 T [L]. Same register contracts; keep ABI slot 10 at `$00B4`. Optional: `OP_DIV` tests the remainder instead of multiplying back (~1.5 kT per exact division)                                                                |

Qualification for this phase: `make check`, `make test`, `qbytecode` (bytecode must be byte-identical:
none of these touch the compiler), `qbench` for 1.2 and 1.5, `qcov_changed` on changed routines.

## Phase 2: bug fixes found by the Leap-C work → release v2.0.3

| #   | Item                                                                                                                                                                                   | HOME    | EXROM      | Notes                                                                                                                                                                  |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------:| ----------:| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2.1 | **SPACE during SAVE is ignored**: `STORAGE_SAVE` sends the data block after an aborted header (`storage.asm:700-721`); the shell always shows `SAVED` (`exrom_v2_shell.asm:1213-1216`) | 0       | +10-15 [E] | `jr nc` after each send, `V2_MSG_ABORTED` already exists. Test: Leap-C's `save-break` case (`tools/tapetest.py:452`). Hardware checklist 3.8 already expects `ABORTED` |
| 2.2 | **`UDG_TABLE` not cleared at cold start** (`$F180` lies outside `MEM_COLD_INIT`'s `$8000-$BFFF`)                                                                                       | +10 [E] | 0          | `CHR$ 144-164` show power-on garbage on real hardware. Fix `EMULATOR_SETUP.md:62` too. Test: 0.6                                                                       |
| 2.3 | **Paging depth reset on the error unwind** (`VM_ERR_COMMON`, `vm_core:5586`)                                                                                                           | +5 [E]  | 0          | Latent: every path is balanced today, nothing enforces it. Required before phase 7                                                                                     |
| 2.4 | **`NOTICE.md` correction**: state that the tape block I/O and block-graphics glyph code are stock-ROM derived until phase 3 replaces them                                              | 0       | 0          | Today it claims MIT for code whose own header says it is "a direct, verified port" of SA-BYTES/LD-BYTES. Leap-C M11-beta drafted a V2 wording                          |

Release v2.0.3 = phases 1 + 2: a maintenance release (no bytecode, ABI or tape-format change).

## Phase 3: licensing clean-up → release v2.0.4

| #   | Item                                                                                                                              | HOME | EXROM                                                          | Notes                                                                                                                                                                                                                                                                                                                                       |
| --- | --------------------------------------------------------------------------------------------------------------------------------- | ----:| --------------------------------------------------------------:| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 3.1 | **Clean-room tape block I/O** (Leap-C `src/runtime/tapeblock.asm`) into V2's EXROM, aliased to `STORAGE_SEND_BLOCK/RECEIVE_BLOCK` | 0    | −15 [L], a few more without the `STORAGE_NZ_SENTINEL` compares | Same register contract. Tolerance test: V2's receiver accepts 54/71 cases, the new one 67/71 and every case V2 accepts [L]. Rewrite `tools/check_storage_contract.py` (it asserts stock internals); port `tools/tapetol.py` and the MIC-capture decode; re-run the EAR-stream and cross-version cases. Keep the `STORAGE_TEST_FAKE_*` hooks |
| 3.2 | **Calculator: clean-room rewrite of the parts its header says were ported** (literal-decode dispatcher, EXCHANGE)                 | 0    | ± (size first)                                                 | No ≥12 B match found, but the header says "ported directly". Keep the 5-byte format and semantics                                                                                                                                                                                                                                           |
| 3.3 | `NOTICE.md` final: all MIT; provenance scan (0.5) has an empty allow-list                                                         |      |                                                                |                                                                                                                                                                                                                                                                                                                                             |
| 3.4 | Remove the stale `tools/tape_gen.py` (describes the archived protocol, unreferenced)                                              |      |                                                                |                                                                                                                                                                                                                                                                                                                                             |

Outcome (2026-10-26, all [M]):

- **3.1** EXROM 123 → 142 B. `tools/qtapetol.py` (23 distortions, ZEsarUX's 15.6 kHz sampled EAR): the old
  receiver accepts 16, the new 22. The new one gains speed 0.75, jitter 30%, pilots of 400/1000/2000 and
  dropouts of 50/200 ms. It loses speed 1.25: a 0 bit stretched 25% plus one sample of jitter lands on
  `TR_ONE` (34). `TR_ONE` 35 wins that case back but loses speed 0.75 and jitter 30% (21/23), so Leap-C's
  34 stays; on Fuse (no sampling) Leap-C measured the new receiver accepting every case the old one did.
  New `tools/qual/qmicsave.py` (in `tools/run_v2_prod_tests.sh`) runs SAVE through the real sender with
  the MIC line captured: blocks byte-exact with valid checksums, pilots 8063/3222 decoded, every pulse
  within +16 T of the stock widths, and the captured signal LOADs back.
- **3.2** EXROM 142 → 199 B. A new dispatcher: `CALC_TABLE` holds (literal, operand count, handler); the
  multi-purpose literal decode and `CALC_LITERAL_PARAM` (never read) are gone; every unknown literal is
  `CALC_ERR_UNIMPLEMENTED` (`CALC_ERR_INVALID_LITERAL` retired). EXCHANGE rewritten. Literal values and
  the 5-byte format unchanged. `tools/z80sim/test_calc_dispatcher.py` updated to the table layout.
- **3.3** `NOTICE.md`: no stock-derived code in the images; the provenance allow-list is empty.
- **3.4** `tools/tape_gen.py` removed.

## Phase 4: display and editor quick wins

| #   | Item                                                                                                                                   | HOME      | EXROM    | Notes                                                                                     |
| --- | -------------------------------------------------------------------------------------------------------------------------------------- | ---------:| --------:| ----------------------------------------------------------------------------------------- |
| 4.1 | **Faster `GFX_CLEAR_ROW_TEXT`**: rewrite its body with Leap-C's 8-scanline `ldir` (do **not** delete it as Leap-C D8 did: V2 calls it) | +6-10 [E] | 0        | ~23 kT → ~6 kT per row [L]; Leap-C typing 47 kT/key vs V2's 72 kT [L]                     |
| 4.2 | **Punctuation table in order of use** (derive the order from V2's corpus)                                                              | 0         | 0        | Scanned linearly per character drawn; font indices and package slot 2's results unchanged |
| 4.3 | **Distinct `1` and `l` glyphs** (Leap-C D13, font data only)                                                                           | 0         | 0        | `LET l=1` is ambiguous today. Refresh any screen oracles                                  |
| 4.4 | Error code number in compile messages (`SYNTAX ERROR 23`)                                                                              | 0         | ~+10 [E] | Cheap step towards audit U4                                                               |

Outcome (2026-10-26, all [M]):

- **4.1** HOME 358 → 354 B (+4, a `djnz` fill rather than Leap-C's 8×`ldir`, which is +8 B for ~0.6 kT
  less). 24,786 → 6,498 T per row; typing `10 print a` from the boot screen 38.1 → 19.1 kT per key
  (one status-row clear per key). Differential: every row 0-23 cleared over a random-filled screen gives
  the old build's screen byte for byte (bitmap and attributes).
- **4.2** 0 B. Order from the corpus (1,860 lines) plus the manual's BASIC examples (1,440 lines): `" = ( ) ,
  + . $ # - * : ; > / < ! ? ' _ @ % &`. Mean scan length per punctuation character 10.4 → 4.9 entries
    (~240 T saved each). All codes 32-196 render byte-identically to the old build.
- **4.3** 0 B. Leap-C D13's glyphs. Ten manual screenshots refreshed; every changed cell is a `1` or `l`
  (checked cell by cell). `NOTICE.md` lists the row clear and the glyphs.
- **4.4** `SYNTAX ERROR n` (the compile code; the manual's Appendix B maps it). EXROM +16 B: built in
  `V2_STATUS_BUF` through a `V2_STATUS_NUM` helper that `V2_DRAW_STATUS` now shares; the message string
  carries the separating space, so the two non-compile `SYNTAX ERROR` sites look unchanged. Paid for by
  `V2_STATUS_SET_BAR_ATTR` writing row 23's attributes directly instead of 32 `GFX_SET_ATTR` calls
  (−25 B; `syntax_error.png` differs only in the new digit). Manual, language reference and
  `manual_tapes.py` / `manual_examples.py` (messages composed in RAM, digits in `[...]`) updated.
- `make doc-examples` 325/325; `make test` all PASS (1,753 s); `qbytecode` 667/667 programs identical.

**Weighed items (Class B, larger EXROM cost):** redraw from the cursor's line down when its height
changes (~25-35 B EXROM [E]; replaces a full redraw of up to 949 kT); keep the cursor's line whole on
screen (`SH_VIEW`, fixes open defect ED4/R9, ~94 B EXROM [L]). Both fit in the room phase 1 frees and
are ranked against phase 5 and 6 by benefit per byte. Cursor at the error's column: Class C for V2's
short lines (needs a compiler-side column count and full qualification): deferred.

Outcome, redraw from the cursor's line (2026-10-26, [M]): EXROM 208 → 186 B (+22). When typing or
DELETE changes the active line's height, `V2_REDRAW` clears from the line's first row down and re-enters
its main loop at the active record (`V2_FIND_INDEX`), instead of CLS and every line from the view top.
An active line cached at row 22 still takes the full redraw: 22 is also the default for a line the full
redraw never reached (ED4). Differential against the phase-4 build: 7 scenarios, 1,941 keys typed (first,
middle and append lines, near the bottom, a scrolled view, wrapped lines above, navigation mixed in), the
screen identical after every key. Per height-changing key: a line on row 20 under 20 lines 796k → 115k T;
a scrolled view 834k → 140k T; long lines above 435k → 212k T; a line near the top gains little (the rows
below are cleared either way). Not done: clearing only down to the last drawn row (~11 B and a RAM cell,
for short programs only). `SH_VIEW` waits for 5.1's size (5.1 merged: EXROM unchanged, `SH_VIEW` is next).

## Phase 5: speed inside the bytecode model → release v2.1

Measured [M] where time goes: dispatch is 21-26% of an integer op (163 T of 640-780 T); the
memory-based tagged operand stack is ~45% [E] (push ~234 T, pop ~150 T, variable load ~595 T).
`x=x+0.5` costs **31,542 T** per iteration because the literal is divided at run time.

| #   | Item                                                                                                              | Notes                                                                                                                                            |
| --- | ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| 5.0 | **HOME/EXROM shrink pass** (z80-skills shrink scripts), if 5.1-5.3 need more room than the floors allow           | Same qualification as the compiler shrink (`qbytecode`, full-RAM diff, `qcov_changed`)                                                           |
| 5.1 | **Float literals compiled to 5-byte constants** (`PUSH_FLOAT5`), parsed at compile time (Leap-C `XF_ATOF` method) | Largest single gain [E]; also lifts the 32767-mantissa / 4-decimal literal limits. Bytecode changes: requalify, reset `qbytecode` baselines once |
| 5.2 | BREAK poll only at back-edges, calls and after package calls (not every op)                                       | 22 T per op [M]                                                                                                                                  |
| 5.3 | Integer fast path in `FOR_NEXT` (int variable, constant STEP)                                                     | Empty loop 1,122 T/iteration today [M]                                                                                                           |
| 5.4 | Combined opcodes for common patterns (e.g. add a small constant to a variable)                                    | Fewer dispatches and stack round trips                                                                                                           |
| 5.5 | Top of the operand stack in registers; cheaper push/pop                                                           | Largest structural change in this phase; prototype first                                                                                         |

Each item: `qbench` before/after, `qbytecode` reviewed (intended changes only), size from `make budget`
against the floors. Combined estimate for 5.2-5.5: 1.5-2.5× on integer code [E]; 5.1 and 5.3 add more on
float literals and loops.

Outcome, 5.1 (2026-10-26, prototyped on `proto/5.1-float5`, merged into `backport/leapc` as `1bb5e65`; all [M]):

- **Change.** In `LEX_SCAN_NUMBER`, a `.` followed by a digit sends the literal to `LEX_NUMBER_TOO_BIG`
  (`NUM_PARSE_CALC` at compile time, `PUSH_FLOAT5`, opcode 70). Removed: the fraction loop and divisor,
  `TOK_FLOAT_NUMBER`, `COMPILE_FLOAT_LITERAL`, `OP_PUSH_FLOAT_LIT`; opcode 22's slot is
  `VM_ERR_ILLEGAL_OPCODE` (as 44/45); RAM `$BA39-$BA3A` is free. A `.` without a digit after it still ends
  an INT literal (`5.` = 5, as before; +11 B).
- **`NUM_PARSE_CALC` fast path (+41 B).** Without it the calculator accumulated every digit (4 calls a
  digit): `3.1416` cost 262 kT to compile (old: 3 kT, plus 22 kT at every execution) and 240 decimals +32
  MT. Now digits accumulate in DE while x < 3276 (`LEX_ACCUM_DIGIT`, moved into the VM core), then in the
  calculator (D = $FF marks it), and 10^k is built in 16 bits up to 10^4: a short decimal is int→fp(m) /
  int→fp(10^k), the old run-time sequence, once.
- **Size.** HOME 354 → 441 B free (−87 B). EXROM 186 (unchanged).
- **Rounding: bit-identical.** Exhaustive (`tools/qual/qdecimals.py`): all 131,072 inputs of the old path
  (mantissa 0-32767 × 1-4 decimals) through the real `LEX_SCAN_NUMBER` and through the old calculator
  sequence: all 131,072 identical (one `TOK_FLOAT5` each, every character used). End to end
  (`qliterals.py`): 1,542 literals (42 edge forms such as `2.0`, `0.0001`, `32767.5`, `3276.7`, `1.`,
  `65535.5`, `4294967296`, plus 1,500 random) compiled and run on both builds: tag and 5 bytes identical
  for all. Parser differential (`qnumparse.py`), 20,000 random texts (signs, spaces, 0-12 decimals, a
  second `.`, trailing text, both length modes) against the calculator-only parser: identical, except
  2,288 results without fraction digits below 32,760, now in the calculator's small-integer form (same
  value); VAL and INPUT turn those into INTs (`NUM_PUSH_CALC`), and a literal never gets one. Unchanged:
  the calculator's divide truncates (3.1 = mantissa `$46666666`, not `…67`).
- **Speed (`qbench`, T).** `x = x + 0.5`: 31,463 → 9,285 per iteration (3.4×); `float_loop` 16.60 M → 7.71
  M (−53.5%); integer programs −0.0 to −0.9%; `for_float_step` −0.01%. Compile: each decimal literal is
  parsed once and costs ~30 kT (`0.5` +31.7 kT, `3.1416` +37.8 kT over an integer literal): 240
  never-executed decimals 3.66 → 9.49 MT. Break-even is ~1.3 executions; a literal that never runs costs
  ~8 ms more. VAL (INPUT shares the parser): `"123"` 79.8 → 8.0 kT, `"0.5"` 68.9 → 28.0 kT, `"3.1416"`
  263.7 → 32.1 kT, `"3.14159265"` 489 → 258 kT.
- **Bytecode.** 667 corpus programs compiled on both builds: 574 identical; 93 differ, each by exactly +1
  byte per short decimal (opcode 22 + 4 bytes → 70 + 5); compile errors identical in all 667.
- **Tests.** `make check`, `make repro` OK; `make doc-examples` 325/325; `make test` all PASS (2,444 s,
  loaded host: standalone 40/40, prod-regress 116, prod-arrays 101, known-defects 15, saveall 13, qual 663
  PASS + 2 XFAIL + 2 N/A, lifecycle 23, maint-qual all). Every `rom/test_v2_*.asm` assembles exactly as on
  the baseline (42; the 14 never-run sources of T-3 fail on both).
- **Not changed.** The test-only decompiler still decodes opcode 22, not 70 (the decimal programs it is
  given are in the never-run sources).
- **Owner decision (F8, 2026-10-26):** integrated; the `5.` rule kept (without it `5.` would be a float:
  `PRINT 5.` shows `5.0000`, `b(2.)` is run-time error 11).

## Phase 6: package ABI 2.1 (minor version: old packages keep working)

| #   | Item                                                                                                                                                                                                    | Notes                                                  |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| 6.1 | **Package functions** (not only statements): finish `study/extfn`, using Leap-C's export-table + signature-byte model (name, address, argument/result types; compiler-side binding, type-checked calls) | Leap-C `spec.md` §7.2                                  |
| 6.2 | **Float service slot** through an EXROM page-in wrapper (as slot 14 already does)                                                                                                                       | Float is explicitly outside ABI 2.0 today              |
| 6.3 | **Error service + a registered package error range**                                                                                                                                                    | Closes R10.8 A3 (package codes 12-21 overlap the VM's) |
| 6.4 | Reserved slots trap with a defined error instead of blank `$FF` bytes                                                                                                                                   | Small; tidier than relying on the version check        |
| 6.5 | **Measured package stack budget** (Leap-C measured per service incl. an interrupt: 30-42 B) instead of the unmeasured 512 B allowance                                                                   | Lets phase 7 reclaim part of `$F800-$F9FF`             |
| 6.6 | Document what happens when a package name equals a keyword; host tool warns (Leap-C `lib2tape.py`)                                                                                                      |                                                        |

## Phase 7: decision gate for a V3 (major: ABI 3.0, new RAM map)

Only after phases 1-6, and only with the owner's go-ahead. Everything here breaks the package ABI.

| #   | Item                                                                                                                 | Gain                                             | Notes                                                                                                                                                |
| --- | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| 7.1 | **System variables to `$5B00`** (Leap-C D1: assembly-time relocation)                                                | Main pool from `$7800`: **~+2,650 B (+29%)** [E] | 34 pinned cells move → ABI 3.0, all packages rebuilt. Program tapes unaffected. `$5B00-$7FFF` is contended: Leap-C saw float/compile 2-3% slower [L] |
| 7.2 | Pack live fixed cells into one block; reclaim the ~1,670 B of dead cells                                             | part of 1,670 B                                  | Not all of sysvars + cells fit in `$5B00-$5FFF`: choose which moves                                                                                  |
| 7.3 | **Array segment in chunk 6** (`$C000-$DFFF`, 8 KB), paged out per element access                                     | +8 KB array/Array Store space                    | Needs 1.4 and 2.3 first; tape cannot load into chunk 6 while the block I/O lives in EXROM (Leap-C moved it to HOME, 331 B: weigh against HOME floor) |
| 7.4 | Array segment in the second display file (`$6000-$77FF`) when MODE 1 is off; `MODE 1` refuses while in use           | +6 KB                                            | Contended (+15-23% access time [L])                                                                                                                  |
| 7.5 | ABI 3.0 bundle: register arguments (HL/DE/BC) instead of `EXT_CALL_ARGn`; drop the historical sysvar package scratch |                                                  | Only alongside 7.1                                                                                                                                   |
| 7.6 | **Native-code spike** (not a commitment): native BASIC loops with tag checks vs the phase-5 VM                       | Decides whether a native back end is worth it    | Native code is 2-5× larger than bytecode [E]; only viable with 7.1-7.4's RAM. Leap-C's templates and fixup chains would be the starting point        |

## Review item R1: the calculator does not round (found in 5.1, 2026-10-26)

Defect `Q-34` (`tools/qual/defects.py`), HIGH: wrong results in ordinary programs. Not caused by 5.1
(the old build is identical) and not a stock-ROM trait. Owner decision F9 (2026-10-26): the next item,
before `SH_VIEW` (a correctness fix that may also free EXROM for the remaining items); prototype on a
branch first, integrate after the owner sees size, speed and rounding.

**What [M].** `tools/qual/qcalcround.py` runs the ROM's four operations on 4,000 operand pairs and
scores each 5-byte result against the exact result rounded to nearest:

| Operation | V2 correctly rounded | V2 worst error | V2 errors lean       | Leap-C (its model) |
| --------- | --------------------:| --------------:| -------------------- | ------------------ |
| add       | 72%                  | 2.00 ulp       | both ways            | 100%, ≤ 0.5 ulp    |
| subtract  | 72%                  | 2.00 ulp       | both ways            | 99.9%, ≤ 0.5 ulp   |
| multiply  | 64%                  | 1.00 ulp       | toward zero (always) | 100%, ≤ 0.5 ulp    |
| divide    | 41%                  | 1.95 ulp       | toward zero (always) | 100%, ≤ 0.5 ulp    |
| m / 10^k  | 51%                  | 1.00 ulp       | toward zero (always) | 100%, ≤ 0.5 ulp    |

Visible in BASIC [M]: `INT(3.1*10)` = 30, `INT(0.3*10)` = 2, `INT(0.7*10)` = 6, `INT(2.2*10)` = 21,
`INT(8.2*10)` = 81, `INT(1.15*100)` = 114, `INT(4.35*100)` = 434, `INT(19.99*100)` = 1998,
`INT(1/3*3)` = 0, `1/10*10=1` false. With correct rounding (Leap-C's model) all ten give the expected
value (31, 3, 7, 22, 82, 115, 435, 1999, 1, true). Summing 0.001 a thousand times stays below 1 with
either: that one is binary floating point, not this defect. PRINT's four decimals hide the error
otherwise.

**Why.** `CALC_OP_DIV` keeps 32 quotient bits (no guard bit) and drops the dividend's lowest bit
when it pre-shifts; `CALC_OP_MUL` truncates the 64-bit product; `CALC_ADDSUB_ENGINE` shifts the
smaller operand right without guard bits; `CALC_PACK` never rounds.

**Leap-C [L].** Not affected: its float core (`src/runtime/fpcore.asm`, MIT) unpacks to a 40-bit
mantissa (32 bits and a guard byte), divides to 40 bits, keeps the dividend's 33rd bit, and `FPACK`
rounds to nearest (ties away from zero). Its float suite checks the ROM against the bit-exact model
`tools/fpmodel.py` (5,451 checks in its `make test`).

**Options.**

1. **Port Leap-C's arithmetic behind V2's calculator interface** (keep the 5-byte format, the
   `RST $28` literal stream and its operand slots, small-integer-form inputs, the error paths).
   Leap-C's unpack/pack/normalise/add/multiply/divide is 522 B; V2's equivalent is 1,331 B
   (`CALC_UNPACK` 125, `CALC_PACK` 44, `CALC_ADDSUB_ENGINE` 399, add/sub 90, multiply 260, divide 347,
   helpers 66). Estimate [E]: EXROM **+500 to +700 B free** after the glue, and correct rounding.
   Scope [M]: the internals (`CALC_UNP_A/B`, `CALC_UNPACK`/`CALC_PACK`, the division and
   multiplication cells, `CALC_OP1/OP2_PTR`) are used only in `rom/exrom_calc.asm`; besides the four
   operations only `CALC_FP_TO_INT` reads the unpacked layout; `CALC_TABLE` has 8 literals (exchange,
   delete, subtract, multiply, divide, add, duplicate, end-calc). To check: speed (Leap-C loops where
   V2 unrolls: measure T per operation and `qbench`'s float programs); `NOTICE.md` (MIT).
2. Guard bits and rounding in V2's own routines: EXROM −60 to −90 B [E], no size win.

**Qualification.** `qcalcround.py` (100% correctly rounded, or every exception explained),
Leap-C's `fpmodel.py` as a bit-exact reference (`--leapc`), `qdecimals.py` / `qliterals.py` /
`qnumparse.py` (literal values change by design: decide the expected values from the model, not
from the old build), `make doc-examples` (examples printing decimals may change in the last digit),
`make test`.

**Interaction with `SH_VIEW`.** Both are EXROM. Option 1 would free far more than `SH_VIEW` uses
(~94 B); option 2 and `SH_VIEW` together would leave about 186 − 94 − 75 ≈ 17 B, below the 32 B
reserve.

**Outcome (2026-10-26; prototyped on `proto/r1-calc-round`, integrated into `backport/leapc` by
fast-forward, owner decision F10).** Option 1, measured:

- **What.** `CALC_OP_ADD/SUB/MUL/DIV` are Leap-C's `FUNPK`/`FPACK`/`FNORM`/`FADD`/`FMUL`/`FDIV`/`FDONE`
  and helpers behind V2's dispatcher: the operands from `CALC_OP1_PTR`/`CALC_OP2_PTR`, either in the
  small-integer form (`FUNPK` normalises its 16 bits in registers), the result packed to the first slot
  (zero as five zero bytes), V2's error paths (`CALC_ABORT_NUMERIC_OVERFLOW`, division by zero through
  `CALC_ABORT_STREAM`; a nested abort is safe: every `RST $28` site is a `VM_CALC_*_STUB`, whose
  `VM_CALC_CHECK` unwinds through `VM_ERR_COMMON`). `CALC_FP_TO_INT` reads the new layout. Cells: the
  37 B block is now `CALC_FX` 7, `CALC_FY` 7, `CALC_FQ` 5 and `CALC_SPARE_18` (nothing after it moved).
  Three loops are faster than Leap-C's with the same bits: `FADD` aligns in registers (Leap-C: a 5-byte
  memory shift per bit), `FMUL` takes the multiplier's bits from A, `FDIV` compares before it subtracts
  and builds the quotient a byte at a time (marker bit) instead of shifting all of Q per bit.

- **Size.** EXROM 186 → **905 B free (+719)**; `exrom_calc.asm` 1,872 → 1,153 B. HOME unchanged (image
  identical). The faithful port alone gave 925; the three speed changes cost 20 B net (`FADD` −17,
  `FMUL` −5, `FDIV` +2).

- **Rounding.** `qcalcround.py --leapc` (4,000 pairs × 4 operations): every result equals Leap-C's model
  byte for byte (16,000/16,000). Correctly rounded: add 100.0%, sub 99.9%, mul 100%, div 100%, m/10^k
  100% (before: 72 / 72 / 64 / 41 / 51%, worst 2 ulp). The 6 exceptions (add 2, sub 4) are all
  effective subtractions with exponents 15-27 apart, off by 0.5002-0.5034 ulp: `FADD` drops the
  smaller operand's bits below the guard byte (no sticky bit), so a borrow they would cause is lost;
  the error is at most 0.5 + 2^-8 ulp, by design in Leap-C's core and model. The ten visible cases
  (`INT(3.1*10)` … `1/10*10=1`) all give the expected value; summing 0.001 a thousand times still stays
  below 1 (binary floating point).

- **`CALC_FP_TO_INT` unchanged** (`qcalctime.py --fptoint`): 22,420 values (random general forms,
  exponents 0-2, 120-149, 200, 255 with edge mantissas, both signs, small-integer forms): HL, carry,
  `CALC_TRUNC_FLAG`, `CALC_ERROR_CODE`, `CALC_SP` identical to the old build for all.

- **Speed per operation** (`qcalctime.py`, T, mean of 1,000 pairs, stub + `RST $28` + dispatcher):

  | operands  | add           | sub           | mul             | div             |
  | --------- | ------------- | ------------- | --------------- | --------------- |
  | float     | 3,999 → 4,397 | 3,825 → 4,224 | 28,612 → 16,794 | 20,589 → 22,324 |
  | int       | 7,000 → 4,801 | 6,823 → 4,624 | 26,777 → 14,806 | 23,748 → 23,060 |
  | float,int | 5,280 → 4,154 | 5,197 → 4,211 | 24,651 → 14,178 | 22,641 → 22,859 |

  The faithful port was slower where Leap-C loops bit by bit: div 38.7-39.6 kT, float add 7.3 kT
  (`qbench`: `float_div` +40%, `compile_dec` +54%, `int_loop` +16%); the three speed changes remove that.

- **`qbench`** (T, old → new): `float_loop` 7.71 → 5.91 M (−23.3%), `int_loop` 42.57 → 38.81 M (−8.8%),
  `builtins` −6.3%, `for_float_step` −5.0%, `compile_dec` −2.7%, `float_div` (new: `x = x + i / 7`)
  −0.9%, `float_add_lit` +0.95%; integer-only programs 0.

- **Literals.** `qliterals.py`: 675 of 1,542 literals change in the last bit (`0.1` = `7D4CCCCCCD`, was
  `…CC`), tags unchanged; `qnumparse.py`: 2,787 of 5,000 texts change value, fraction digits,
  characters used and errors unchanged. New `qnumcheck.py` replays `NUM_PARSE_CALC`'s sequence through
  the model: every literal and parser value is the model's (the old build fails exactly the changed
  ones). `qdecimals.py` (exhaustive, all 131,072 short decimals): each literal equals the run-time
  sequence on the same build (PASS), and against the model all 131,072 lexer values are its m / 10^k
  and every one is the nearest 5-byte float (before R1: 51% of `qcalcround`'s 1,000 m / 10^k pairs).

- **Tests.** `make check`, `make repro` OK; smoke ROMs 9/9 (`test_calc_smoke_division` expected the
  truncated 1/3, `…AA`: now `…AB`); standalone 40/40; production checks, fill check, prod-regress 116,
  prod-arrays 101, known-defects 15, saveall 13, micsave 3: all PASS; lifecycle 23, maint-qual all PASS;
  `make doc-examples` 325/325, every output identical to the old build's. **Corpus: 657 PASS + 6 FAIL

  + 2 XFAIL + 2 N/A** (before: 663 PASS): the 6 are float `FOR` counts one short, `ffor.count.0_1_0.1`
    10 (expected 11), `0_2_0.2` 10, `1_0_-0.1` 10, `2_0_-0.2` 10, `-1_1_0.1` 20 (21), `long` (`0 TO 10
    STEP 0.01`) 1,000 (1,001). Why: a float loop adds the step and stops when v − limit is past 0. The
    rounded `0.1` (`7D4CCCCCCD`) is 5.8e-12 above 0.1, and ten rounded additions give `8100000001`, one
    ulp above 1; the truncated `0.1` (`…CC`) was below and every truncated sum stayed below, so before R1
    these inclusive loops always reached their limit (a side effect of `Q-34`'s downward bias). The model
    agrees (0.01 × 1,000 additions: 10 + 1.7e-7). The other 4 `ffor.count.*` cases and all other float
    loops still pass. The manual already says not to rely on the count (keywords, FOR: "the 25 loops of
    the qualification test were all exact, but do not rely on it"). **Owner decision needed** (below).

- **The `FOR` decision.** The BASIC standards define this case. Minimal BASIC (ECMA-55 1978 = ANSI
  X3.60-1978 = ISO 6373:1984, §13.4) and Full BASIC (ANSI X3.113-1987 = ISO/IEC 10279:1991, §8.3.4)
  define FOR/NEXT by an equivalent program: limit and step evaluated once, `LET v = v + own2` (the step
  accumulated), and the loop ends when `(v - own1) * SGN(own2) > 0`, an exact test. ECMA-55 §13.6:
  "Where arithmetic is approximate (as with decimal fractions in a binary machine), the loop will be
  executed within the limits of machine arithmetic. No presumptions about approximate achievement of
  the end test are made", and with truncating arithmetic `FOR X = 0 TO 1 STEP 0.1` "will work as the
  user expects" but `FOR X = 1 TO 0 STEP -0.1` "will probably not". Full BASIC's way to exact decimal
  steps is `OPTION ARITHMETIC DECIMAL` (decimal floating point, ≥ 10 digits), not a fuzzy test. V2's
  float loop is this rule, so after R1 it conforms with correctly rounded arithmetic. Options:
  (a) **accept (the standard's rule; recommended)**: the 6 corpus expectations become the counts the
  rule gives, and the manual's FOR note says why; 0 B. (b) A tolerance in `VM_FOR_PAST` (a fraction of
  the step): changes the standard's end test, and a fixed fraction fails again for longer loops (model:
  2^-16 of the step misses `0 TO 10 STEP 0.01`) and can include a limit just below a multiple; values
  still drift. HOME about −20 to −30 B [E]. (c+ε) v = start + k × step from a hidden count, with an end
  test allowing a few ulps: the decimal-intent count in 300/300 random decimal loops (A: 165, B 2^-12:
  300, C without ε: 242) and no drift (worst value error 9.5e-6 against A's 3.4e-4, which changes
  PRINT's 4th decimal in 17 of 300 loops); departs from the standard's `LET v = v + own2`, costs a
  multiply per float NEXT and a larger FOR frame, HOME about −60 to −100 B [E].

- **Integrated** (F10): `backport/leapc` fast-forwarded; the ledger row; `Q-34` fixed (`defects.py`,
  `RC_FIXED`, `docs/V2_DEFECT_REGISTER.md`). `CALC_SPARE_18` stays free (2 B short of `SH_VIEW`'s 20
  heights).

- **`FOR` (F11: follow the standard).** No ROM change: V2's float loop already is the standards' loop.
  The corpus oracle (`_cnt` in `tools/qual/corpus.py`) now applies it, each sum rounded to the nearest
  5-byte float, instead of the exact decimal count: 10, 10, 4, 10, 41, 20, 10, 10, 51 and 1,000, the
  counts the ROM gives. The manual's FOR passage (03_keywords.md) states the rule and shows
  `FOR i = 0 TO 1 STEP 0.1` running 10 times (example `kw.for.6`); `docs/V2_DEFECT_REGISTER.md` lists
  F11 as decided. `STEP 0` with the start already past the limit is left as it is (V2: no pass; the
  standards' test never ends the loop). After F11: `make qual` 663 PASS + 2 XFAIL + 2 N/A (as before
  R1), lifecycle 23, `make doc-examples` 326/326.

## Not recommended

- D4 (Leap-C's BREAK model), D7 (C key map; V2 earmarks SS+A/S for page-down/bottom), D9/D11/D12 (Leap-C's
  HOME/EXROM moves), D17-D19 dead-code removals (V2's callers still use those entries), deleting
  `GFX_CLEAR_ROW_TEXT`, `check_platform.py`.
- Already in V2: doc examples as tests, the RAM-layout guard, the canary, CI with pinned sjasmplus,
  release packaging.

## Owner decisions

All decided by the owner on 2026-10-25.

| Id  | Decision                                 | Outcome                                                             |
| --- | ---------------------------------------- | ------------------------------------------------------------------- |
| F1  | ROM spending                             | Weighted policy with a 64 B / 32 B emergency reserve (§0)           |
| F2  | Fuse run for the frame-loss probe (0.8)  | Approved                                                            |
| F3  | Keep `EDIR_HOME/END` in production (1.1) | Only if the R10.8 navigation keys are planned                       |
| F4  | Release grouping                         | v2.0.3 = phases 1-2; v2.0.4 = phase 3; v2.1 = phases 4-6            |
| F5  | Start phase 7 (V3)                       | Decide after v2.1, with 7.6's spike numbers                         |
| F6  | Calculator rewrite (3.2)                 | Counts as clean-room (2026-10-26)                                   |
| F7  | Fast emulation (0.10)                    | Default for the suites (2026-10-26)                                 |
| F8  | 5.1 decimal literals                     | Integrated, `5.` stays an INT (2026-10-26)                          |
| F9  | Calculator rounding (`Q-34`)             | R1 is the next item, before `SH_VIEW`: prototype first (2026-10-26) |
| F10 | R1 prototype                             | Integrated (2026-10-26)                                             |
| F11 | Float `FOR` counts after R1              | (a): follow the standard (2026-10-26)                               |

## Also worth doing

- **Physical TS2068 run** before v2.1: neither V2 nor Leap-C has run on real hardware; items 1.4, 2.2,
  3.1 and 4.x all have hardware-sensitive parts (60 Hz frames, power-on RAM, tape tolerance, contention).
- **Fuse alongside ZEsarUX for timing-sensitive cases**: ZEsarUX runs the TS2068 at the 48K's 50 Hz
  frame; the real machine is 60 Hz [L: M9]. Everything counted in frames is 20% faster on hardware.
- **Keep this plan's ledger (§0) current** with each merged item's measured bytes, as Leap-C's
  improvements report did.
