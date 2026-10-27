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

| After                        | HOME    | EXROM   | Basis                                                                                                         |
| ---------------------------- | -------:| -------:| ------------------------------------------------------------------------------------------------------------- |
| today                        | 275     | 26      | [M]                                                                                                           |
| phase 1 (space)              | **373** | **138** | [M]: 1.1 EXROM −112; 1.2 HOME −36; 1.3 HOME −12; 1.4 HOME −2; 1.5 HOME −48                                    |
| phase 2 (bug fixes)          | **358** | **123** | [M]: phase total HOME −15, EXROM −15 (items 2.1-2.3; v2.0.3)                                                  |
| phase 3 (licensing)          | **358** | **199** | [M]: 3.1 tape block I/O EXROM +19; 3.2 calculator dispatcher EXROM +57                                        |
| phase 4 (display quick wins) | **354** | **208** | [M]: 4.1 HOME +4; 4.2, 4.3 0; 4.4 EXROM +16, status-bar attribute fill EXROM −25                              |
| redraw from the cursor line  | **354** | **186** | [M]: EXROM +22                                                                                                |
| 5.1 decimal literals         | **441** | **186** | [M]: HOME −139 value/divisor path removed, +41 16-bit digits in `NUM_PARSE_CALC`, +11 `5.` stays an INT       |
| R1 calculator rounding       | **441** | **905** | [M]: EXROM +739 Leap-C's float core, −20 three faster loops                                                   |
| `SH_VIEW` (ED4)              | **441** | **801** | [M]: EXROM −104: `V2_VIEW` 57, `V2_MEASURE` 29, `V2_VIEW_BOUND` 16, `V2_REDRAW_NAV` +7, `V2_REDRAW` −5; RAM 0 |
| ED3, ED7 (editor fixes)     | **441** | **778** | [M]: EXROM −23: `V2_WRAP` +47, 7 edit-buffer wrap calls −21, `V2_REDRAW_NAV` +2, ED3 −5 |
| 5.2 BREAK poll               | **454** | **778** | [M]: HOME +13 free: JMPZ's own jump code gone (a taken JMPZ falls into OP_JMP), polling exits 1 B each   |
| 5.3 FOR fast path            | **367** | **778** | [M]: HOME −87 free: the integer path in `OP_FOR_NEXT` 80 B, the loop variable's reload on its fallback 7 B   |
| 5.4 combined ops             | **246** | **621** | [M]: HOME −121 free (VM 117: `CMP_JMPZ` 23, `ADD_VAR_*` 91, `VM_FLOAT_BINARY` 3; compiler 4); EXROM −157 (peepholes) |
| 5.5 cheaper push/pop        | **273** | **621** | [M]: HOME +27 free: `VM_PUSH` 45 → 22 B, `VM_POP` 26 → 22 B; RAM `$B685-$B687` free (F15: step 1 only) |
| 5.6 calc mul/div             | **273** | **573** | [M]: EXROM −48 free: `FMUL`/`FDIV` in registers (the alternate set)                                    |
| 5.7 `SQR` halving            | **278** | **573** | [M]: HOME +5 free: the exponent decremented instead of pushing 2 and dividing                           |
| 5.8 row clear                | **286** | **573** | [M]: HOME +8 free: `GFX_CLEAR_ROW` fills the attributes and falls into `GFX_CLEAR_ROW_TEXT`            |
| 5.9 `SIN`/`COS`/`TAN` to the EXROM | **746** | **142** | [M]: HOME +460 free (`SIN` 340, `TAN` 58, `COS` 27, `SIN_PEEK_POP` 27, the divisor table 8); EXROM −431 (the code 413 after bit-identical compaction, 3 slots 18); `SQR`/`PI`/`RAD`/`DEG` stay (no room) |
| phase 5 (speed)              | ≥ 64    | ≥ 32    | Class B: each item sized and weighed before it is started; 5.0 first if the room is not there                 |

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
for short programs only). `SH_VIEW` waited for 5.1 and R1; its outcome follows.

Outcome, `SH_VIEW` (2026-10-26, [M]): EXROM 905 → **801 B** free (+104), HOME unchanged, **no RAM**. Fixes
ED4/R9: the cursor's line is always whole on rows 0-22, so its cursor is always on the screen.

- **What.** `V2_VIEW` (Leap-C's `SH_VIEW`, MIT) sets `VIEW_TOP_INDEX` in the full redraw: `max(0, index − 20)`
  (`V2_VIEW_BOUND`) as before, then lines dropped from the top while they and the cursor's line need more
  than rows 0-22. It returns the top record, so the full redraw's `V2_FIND_INDEX` is gone. **No table of
  heights** (so `CALC_SPARE_18` and the dead spans stay free, the RAM census unchanged): `V2_MEASURE` takes a
  record of 32 characters or fewer as one row from its length (~130 T) and wraps a longer one in place
  (`EDITOR_WRAP_CALC_LEN`, a second entry of `EDITOR_WRAP_CALC` after its length scan: no copy); a line dropped
  from the top is measured again, which costs only in a trimmed view.

- **Height change** (typing or DELETE changes the active line's rows): taller and still ending above row 23,
  or shorter in a view that is not trimmed (`VIEW_TOP_INDEX` = `max(0, index − 20)`), keeps the view
  (proved, no walk); the rows from the line down are redrawn as before, now from `CUR_EDIT_POS` instead of a
  `V2_FIND_INDEX` walk. Otherwise the full redraw decides. The `cp 22` test is gone (the line is always
  reached; the default 22 stays as a guard).

- **UP/DOWN** (`V2_REDRAW_NAV`): DOWN keeps the two-line path whenever the new line is at most 20 below the
  view's top and ends above row 23 (exactly when `V2_VIEW` gives the same top, for any top: no walk); UP keeps
  it from a view at line 0 (as Leap-C). UP from a trimmed view takes the full redraw: deciding it would need
  the height of the line above the view (a `V2_FIND_INDEX` walk per UP); not done.

- **Qualification.** New `tools/qual/qeditview.py`: 15 typed scenarios, 1,653 keys; after every key the view
  rule (modelled), the active line whole and showing the buffer, the cursor cell the only inverted attribute
  on rows 0-22; `--oracle`: the screen equals a full redraw's after every key (every selective path);
  `--ref`: the old build. New build: all PASS, oracle included. Old build: the 7 ED4 scenarios fail (1,920
  problems: e.g. 20 two-row lines above, view top 0 where the rule gives 10), the 8 others pass. Differential:
  in the 8 ED4-free scenarios (630 keys: short programs, a scrolled view, wrapped lines that fit, near the
  bottom, delete/insert line, a 200-line program) the screen is identical to the old build's after every
  key. `--measure 3000`: `V2_MEASURE` = `EDITOR_WRAP_CALC` on the copy = the model for 3,000 random texts
  (rows 1-7; 7 is the most a 127-character line can take, so the 8-row cap never applies). Prod gate: 4 new
  cases `ED4-*` (a 4-row line from row 20, 20 two-row lines above, a line on rows 20-22 growing a 4th row and
  back, DOWN onto a 4-row line on row 20): PASS; the old build fails all 4.

- **Per key** (T, mean, old → new; the ED4-free figures on identical screens):

  | scenario                        | typing          | height change   | UP/DOWN, two-line path | UP/DOWN, full redraw |
  | ------------------------------- | --------------- | --------------- | ---------------------- | -------------------- |
  | 10 lines, append line           | 53.9k → 53.1k   | 189.2k → 185.0k | 218.0k → 218.3k        |                      |
  | 25 lines, through all           |                 |                 | 102.1k → 101.2k        | 910.1k → 917.6k      |
  | 30 lines, line 25 (scrolled)    | 101.4k → 100.6k | 152.7k → 144.1k |                        | 1,007.6k → 1,016.6k  |
  | 22 lines, line 21 (near bottom) | 84.7k → 83.9k   | 134.1k → 128.0k |                        | 868.8k → 878.6k      |
  | 200 lines, line 150             | 76.0k → 75.2k   | 190.6k → 147.0k |                        | 1,163.5k → 1,165.5k  |
  | 8 two-row lines that fit        | 115.5k → 114.8k | 971.1k → 969.7k | 180.4k → 180.0k        |                      |

  ENTER (a full redraw) +0.2% to +1.5%. Where ED4 applied the costs are not comparable (the old build drew
  less, wrongly): typing in a line now drawn whole costs its rows (a 3-4-row line in a 120-line program with
  wrapped lines 103k → 235k), a line growing past row 22 scrolls (a full redraw, ~1.0 MT, was ~0.21 MT), UP
  in a trimmed view is a full redraw (5 keys of `shrink-trimmed`: 176k → 770k mean), full redraws with
  wrapped lines above +5.5% (1.20 → 1.27 MT: the in-place wraps; a copy into `DETOK_BUF` was +12%).

- **Tests.** `make test` all PASS (1,631 s: `make check` with the reserve check, smoke 9/9, standalone 40/40,
  production and fill checks, prod-regress 120 (the 4 `ED4-*` included), prod-arrays 101, known-defects 15,
  saveall 13, micsave 3, qual 663 PASS + 2 XFAIL + 2 N/A, lifecycle 23, maint-qual all); `make doc-examples`
  326/326, no screenshot changed.
- **Found:** a cursor after a last row of exactly 32 characters is at column 32, off the screen (both
  builds). Fixed next as ED7.

Outcome, ED3 and ED7 (2026-10-26, [M]; owner request after `SH_VIEW`): EXROM 801 → **778 B** free (+23), HOME
unchanged, no RAM.

- **ED3** (editor audit, MEDIUM): only the empty last line offered its text to `V2_DISPATCH`, so a command
  typed over a program line was stored as that line (`RUN` over line 12 replaced it). `V2_COMMAND_LOOP` now
  dispatches every non-empty line first (−5 B): a command runs on any line, the record is untouched, and
  `.loop` reloads its text; anything else is stored as before. No command word is a program keyword, so no
  program line can be taken for one; `run = 4`, `listing = 2` are still stored (`V2_MATCH_EXACT` /
  `V2_MATCH_PREFIX` need the word alone or followed by a space). Unchanged: `save = 3` and the like were
  already commands with a bad name on the last line (`SYNTAX ERROR`), now on every line; UP/DOWN with an
  uncommitted command in the buffer still stores it (D9a's rule: an edit is kept). Manual: `04_concepts.md`
  (commands on any line, new example `con.edit.5`, which fails on the old build: line 1 became `RUN`).
- **ED7** (new, LOW, found by `qeditview`): with a last row of exactly 32 characters, the cursor after it was at
  column 32: no cell (`GFX_INVERT_ATTR` refuses it), and LEFT/RIGHT from there "restored" (row + 1, 0)
  (`.clear_cursor_attr` has no bound), whitening the status bar's first cell when the line ended on row 22.
  Now `V2_WRAP_EDIT` / `V2_WRAP` (`EDITOR_WRAP_CALC` plus, for the edit buffer only, an empty row after a full
  last row) serve all 7 edit-buffer wraps and `V2_DRAW_TEXT`: the cursor at the end shows at (row + 1, 0);
  the view, the redraw paths and UP/DOWN inside the line count the row; a settled line is drawn without it.
  A line that gains the row as it becomes active moves the lines below it, so `V2_REDRAW_NAV` takes the full
  redraw then (`V2_WRAP` returns Z; found by the oracle in the prototype). 7 rows is the most a 127-character
  line takes, so the 8-entry wrap table has room.
- **Qualification.** `qeditview` (18 scenarios, 3 new for the edit row: 32 and 64 characters, a word-wrapped
  last row of 32, a line on row 21 whose edit row makes the view scroll): all PASS with the oracle; against
  the `SH_VIEW` build (`--edit-row-ref`) every screen identical except the states with the edit row and two
  explained ones (the old status-cell symptom), compared until the two builds' cursor states part (UP/DOWN
  inside a line with the edit row). Prod gate: 7 new cases, `ED3-*` (RUN, LIST, `:` and NEW over a line;
  `run = 4` / `listing = 2` still stored) and `ED7-*` (the cursor at (row + 1, 0) after 32 characters, LEFT,
  RIGHT, the 33rd; the edit row scrolling the view on row 21): PASS.
- **Per key** (T, mean, `SH_VIEW` → now): typing −2% to +0% (10 lines 56.4k → 54.0k); full redraws +0.1% to
  +0.5%; the height change moves from the 33rd character to the 32nd (the same total over a typed line);
  UP/DOWN inside a line with the edit row +7% (one more row cleared); UP/DOWN onto such a line is a full
  redraw (162k → 512k in `edit-row`).
- **Tests.** `make test` all PASS (1,781 s: `make check` with the reserve check, smoke 9/9, standalone 40/40,
  production and fill checks, prod-regress 127 (the 11 `ED3-*`/`ED4-*`/`ED7-*` included), prod-arrays 101,
  known-defects 15, saveall 13, micsave 3, qual 663 PASS + 2 XFAIL + 2 N/A, lifecycle 23, maint-qual all);
  `make doc-examples` 327/327 (`con.edit.5` new), no screenshot changed.

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
| 5.5 | Top of the operand stack in registers; cheaper push/pop                                                           | Owner F15: the cheaper push/pop only (step 1); the top of the stack in registers (step 2) is not done. See "Outcome, 5.5"                      |

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

Outcome, 5.2-5.4 (2026-10-27, owner decision F13: one group; prototyped on `proto/5.2-5.4-vm-speed`, one
commit per item: `fa8e5b9` 5.2, `cae1722` 5.3, `51d4f82` 5.4; integrated into `backport/leapc` by
fast-forward on 2026-10-27, owner decision F14; all [M]):

- **5.2 BREAK poll rule.** `VM_RUN` tests `VM_HALTED` at `.loop` only; ordinary handlers end `jp (iy)` at
  `.next` (no test). Polled: every taken jump (`OP_JMP`, which a taken `JMPZ` now falls into, so `JMP`,
  `JMPZ`, `JMP_ELSE`, `JMP_DEFFN`, `AND_SC`/`OR_SC` and FOR's skip), `FOR_NEXT`'s back branch, every `CALL`
  (PROC, FN), the re-entry after a package (`OP_CALL_EXT` → `VM_RUN`) and the exits of PAUSE, BEEP and
  INPUT. Every cycle passes one of them: a loop needs a backward transfer, and RET (the only other one)
  returns from a CALL in the same cycle. `OP_HALT` already left `VM_RUN` by its own `ret`; the error-halts
  unwind through `VM_RUN_SP`; DIM's EXROM service ends at `VM_RUN_LOOP` (the poll) when it sees a halt.
  HOME 441 → 454 B free (+13). Speed: 22 T saved per op, 22 T added per taken jump: integer programs −1%
  to −3%, `for_empty` +0.2% (its back branch, `jp nn` instead of `jp (iy)`).
- **BREAK qualification** (new `tools/qual/qbreak.py`, 19 cases): CAPS SHIFT + SPACE pressed in the
  emulated keyboard matrix (the real ISR path, as the maint suite does) while the program is inside its
  loop or wait: `GOTO` to itself, `IF … THEN GOTO` (constant and variable limit), an IF block with `GOTO`
  back, integer FOR (empty, with a body, counting down, `STEP 0`), float FOR (float step, float limit,
  float start), FOR whose frame is not the innermost (`GOTO` out of an inner loop), nested FOR, PROC tree
  recursion (`CALL t(18)`, no back-edge at all), `DEF FN` in a `GOTO` loop, `PAUSE 0`, `PAUSE 3000`,
  `BEEP 20,0`, `INPUT` (BREAK, then ENTER). PASS = error 66, the line after the loop never ran, the key
  came while the program ran. Base, 5.2, 5.3 and 5.4: 19/19 each. The time from the ISR's write of
  `VM_HALTED` (a ZEsarUX write watchpoint) to the BREAK message, shell unwind included: base 363-5,839 T,
  5.2 369-6,168 T, 5.4 369-13,448 T (`for-float-var`: one float iteration); at most one loop iteration,
  under 4 ms. The existing BREAK cases (`D5-break-running-loop`, `make qual-maint`'s BEEP/PAUSE) are in
  `make test` (below).
- **5.3 FOR_NEXT integer fast path.** When the loop variable is an INT, its frame is the innermost one
  (`VM_CSP`) and the limit and step are INTs (small-integer form), NEXT adds, stores and compares in
  registers: no `VM_FIND_FOR` walk, no `VM_FOR_LOAD_VA`, no `MATH_COMPARE16` call. Anything else, or a
  sum that overflows (the FLOAT promotion), takes the general path from the start (nothing written yet;
  the loop variable is reloaded from the operand). An empty control stack cannot pass for a frame
  (comment at the code: it would need a FLOAT symbol 0 that is the loop variable). HOME 454 → 367 B (−87).
  Empty loop 1,190 → 911 T per iteration (`for_empty` −23.6%); `for_float_step` +1.0% (the refused tests,
  ~130 T on a 13 kT float iteration). Differential against 5.2, 22 FOR programs (overflow at ±32768 both
  ways, `STEP` 3/−3/2/±32767/−32768, the variable changed in the body to an INT and to a FLOAT, `GOTO` out
  of an inner loop, a float limit and start, NEXT without its FOR with symbol 0 INT, FLOAT and another
  FLOAT, NEXT inside a PROC, re-entered FOR, `EXIT FOR`, `STEP 0` past the limit): screens and error codes
  identical. Bug found by `qbench` in the first version: a refused FLOAT step lost the loop variable
  (error 7 in `for_float_step`); fixed before the commit.
- **5.4 combined opcodes** (sized from the corpus: weighted by loop nesting, `CMP; JMPZ` is 3.4% of the
  instructions, `v = v ± k` 2.0%, `LOAD; PUSH; CMP` 3.5%). `CMP_JMPZ` (74, operand `[mask][target]`): a
  relational operator and IF's `JMPZ` in one dispatch, no 0/1 pushed and popped; mask bit 0/1/2 = true
  when a < b / a = b / a > b; for `IF … THEN GOTO` the mask is inverted and the target is the label (no
  `JMP`). A taken jump polls BREAK. `ADD_VAR_I8` (75, `[v][k]`): `v = v + k` and `v = v - k` (as
  `v + (-k)`: the calculator's FSUB is FADD with the sign flipped, so the FLOAT result is the same);
  `ADD_VAR_VAR` (76, `[v][w]`): `v = v + w`. INT + INT without overflow in place; otherwise the general
  sum (`VM_FLOAT_BINARY`, now a subroutine of `VM_FLOAT_BINARY_COMMON`) stored as `STORE_VAR` stores it.
  - **Size.** HOME 367 → 246 B (−121: VM 117, compiler 4); EXROM 778 → 621 (−157). The handoff assumed
    the compiler side would be EXROM; `rom/exrom_v2_compiler.asm` is assembled into HOME (`v2_home.asm`),
    and the first build put 139 B there (HOME 111 B free). The three peepholes moved to the EXROM
    (`rom/exrom_v2_fuse.asm`) behind three production-only entry slots (`V2_EXROM_FUSE_*_ADDR`), which the
    HOME compiler calls directly, as it and the VM already call the calculator's slots: every compile
    runs under the shell with the EXROM paged in (`qcanary --banking`: 667 cases, 0 violations; the
    machine-stack low-water mark unchanged, `$FDE8`). HOME keeps the call sites and `COMPILE_RELATIONAL`'s
    six tails merged into one that records `CMP_END` ($BA39, free since 5.1; zeroed at every compile).
    KTAB magic `$1B` → `$1C` (`$1A` → `$1D` without AY BEEP). Production only: the test-only decompiler
    rebuilds IF structures from `JMPZ`/`JMP`, so the standalone images compile as before.
  - **Bytecode review** (the `qbytecode` reset for the group; 667 corpus programs, base vs 5.4, aligned
    instruction by instruction, every difference accepted only as one of the three rewrites and every
    jump operand checked against its relocated target): 519 identical, 101 the same compile error, 47
    changed, all explained: 156 `v = v + k`, 4 `v = v + w`, 20 `CMP` + `JMPZ`, 9 `IF … THEN GOTO`; 667
    bytes of bytecode fewer in all (4 per fused assignment, 3 per `IF … THEN GOTO`).
  - **Differential against 5.3**, 95 programs (each relational operator × INT, FLOAT, mixed, negative,
    equal and ±32767/−32768 operands, in IF/ELSE, IF with a constant, `IF … THEN GOTO` taken and not;
    `v = v ± k` across 32767/−32768, FLOAT `v`, `v + w` with FLOAT and overflowing `w`, and near misses
    left unfused: `v - w`, `1 + v`, `v + 1000`, `v + 1 + 1`, AND/OR/NOT, string compares, a compare's
    value stored): screens and error codes identical. *Correction (2026-10-27):* its 36 `IF … THEN
    GOTO` programs used a label `out`, which is the keyword `OUT`, so they stopped with compile error 12
    on both builds and compared nothing; `qvmedge` below runs them with a valid label. Bit-exact: 900 FLOAT results of a fused `x = x - k`,
    `x = x + k`, `x = x + w` against the unfused `z = y - k` (… ) in the same program, random values: all
    identical.
  - Compiles +0.1% to +0.4% (`compile_only`, `compile_int_if`): two peephole checks and a slot call per
    assignment and IF.
- **`qbench` (T, compile and run; new integer programs `int_inc`, `goto_loop`, `if_branch`, `proc_calls`
  and the `sieve` of `~/2068-rom-benchmarks`, because `int_loop` and `builtins` overflow into FLOAT):**

  | program          |       base |   5.2 |    5.3 |    5.4 | group           |
  | ---------------- | ----------:| -----:| ------:| ------:| --------------- |
  | `int_inc`        |  7,984,071 | −2.2% |  −7.2% | −56.8% | −60.8% (2.55×)  |
  | `goto_loop`      | 11,438,235 | −3.1% |   0.0% | −51.2% | −52.8% (2.12×)  |
  | `sieve`          | 13,067,779 | −2.5% |  −2.2% | −22.5% | −26.0% (1.35×)  |
  | `if_branch`      | 16,043,763 | −2.6% |  −3.6% | −21.0% | −25.9% (1.35×)  |
  | `for_empty`      |  3,572,095 | +0.2% | −23.6% |   0.0% | −23.4% (1.31×)  |
  | `for_nested`     |  3,944,003 | −0.1% | −21.8% |   0.0% | −21.9% (1.28×)  |
  | `proc_calls`     |  5,877,700 | −1.5% |  −2.4% | −15.1% | −18.4% (1.23×)  |
  | `loop_200`       |    507,260 |  0.0% | −11.2% |   0.0% | −11.1%          |
  | `strings`        |  2,372,574 | −1.1% |  −2.4% |   0.0% | −3.5%           |
  | `float_add_lit`  |  2,386,714 | −0.8% |  −2.3% | +0.1%  | −3.0%           |
  | `builtins`       | 11,939,220 | −1.3% |  −1.2% | +0.1%  | −2.4%           |
  | `int_loop`       | 38,814,914 | −0.9% |  −1.5% | +0.1%  | −2.3%           |
  | `float_loop`     |  5,911,158 | −0.4% |  −1.0% | +0.1%  | −1.3%           |
  | `float_div`      |  7,456,157 | −0.4% |  −0.8% |   0.0% | −1.1%           |
  | `for_float_step` | 40,199,631 |  0.0% |  +1.0% |   0.0% | +1.0%           |
  | `compile_only`   |  3,686,212 | −0.3% |   0.0% | +0.4%  | +0.1%           |
  | `compile_int_if` |  3,346,791 |  0.0% |   0.0% | +0.4%  | +0.4%           |
  | `compile_dec`    |  9,233,848 |  0.0% |   0.0% | +0.1%  | +0.1%           |

- **Group size.** HOME 441 → **246 B** free (−195; 182 above the reserve), EXROM 778 → **621 B** (−157).
  Per item, HOME: 5.2 +13, 5.3 −87, 5.4 −121.
- **Tests.** `make check` and the release variant (`make build EXTRA_DEFS=`, HOME 281 / EXROM 620 free)
  assemble. `make test` all PASS on 5.3 (1,883 s) and on 5.4 (1,730 s): budget reserve check, smoke 9/9,
  standalone 40/40, production and fill checks, prod-regress 127, prod-arrays 101, known-defects 15
  (`D5-break-running-loop` included), saveall 13, micsave 3, qual 663 PASS + 2 XFAIL + 2 N/A, lifecycle
  23, maint-qual all (BREAK during BEEP and PAUSE included). `make doc-examples` on 5.4: 326/327 until the
  manual followed the change, then 327/327: `mem.compile.1` documents the program's bytecode, and
  `total = total + i` is now one `ADD_VAR_VAR` (31 → 27 bytes; `04_concepts.md`'s table and typical
  figures updated, the Word manual is rebuilt at release). `qcanary --banking` (667 cases): 0 canary
  hits, 0 banking violations, stack low-water mark `$FDE8` on both builds; its depth invariant is armed at
  `VM_RUN.next` now (every op), `.loop` on older builds.
- **Not done (candidates, sized [E]).** (i) A compare of a variable with a small constant fused with the
  branch (`LOAD v; PUSH_I8 k; CMP_JMPZ`, 3.5% of the corpus' weighted instructions): ~45 B HOME, ~0.9 kT
  per IF. (ii) A cheaper `VM_PUSH` (the operand stack is all in page `$B6`, so the bounds test and the
  pointer need only the low byte: ~254 → ~134 T per push): a step of 5.5. (iii) A page-aligned opcode
  table (~30 T per op, the alignment's padding to be found in HOME).
- **Standing coverage (after F14).** New `tools/qual/qvmedge.py`, in `make qual` (so `make test`), 118
  cases, ~7 s: the FOR edge programs of the 5.3 differential (the range ends, steps of ±32767/−32768, the
  variable changed or made FLOAT in the body, NEXT with no loop open: error 7, GOTO out of an inner loop,
  `EXIT FOR`, `STEP 0`) and the 5.4 programs (the 72 comparison cases, now with a valid label, overflow
  across 32767/−32768, FLOAT operands, near misses, the sieve). Expectations written from the manual's
  rules, not from the ROM's output: 118/118 on the integrated build and on the build before 5.2. Compiled
  on both, the combined forms appear where intended (all 72 comparison programs, every `v = v + k` and
  `v = v + w` case) and not in the near misses. Found on the way: a negative constant compiles as
  `0 - magnitude` (unary minus), so `COMPILE_FUSE_ADD`'s guard against `v - (-128)` cannot be reached
  from source (3 B of EXROM, kept as a guard).
- **Manual speed figures.** `04_concepts.md` "Speed" and `FOR`'s note (1,107 T per empty pass, the
  per-statement table) are the release's measurements and predate 5.1, R1 and 5.2-5.4. On `201b960`
  (`manual_measure.py`, 2026-10-27): an empty pass 827 T (was 1,107); `a = a * 1.0001` adds ~20,900 T
  (was 55,200), so the text's "whole numbers about twelve times faster than floating point" is about 4.6
  times now. Re-run the tool and update the table and the text before the v2.1 release. *Done*
  (owner, 2026-10-27, on the 5.6-5.8 build): an empty pass 827 T; `a = a * 1.0001` adds 11,500 (5.6),
  so "about three times"; a scrolling `PRINT` 224,000 (5.8), 16 lines a second; the `FOR` note 830 T.
- **Owner decision F14 (2026-10-27):** integrate all three; fast-forwarded `backport/leapc` to `201b960`.

Outcome, 5.5 (2026-10-27; prototyped on `proto/5.5-vm-push` off `backport/leapc` `3d337c1`, commits `4303cf8`
and `6af3278`; integrated into `backport/leapc` by fast-forward, owner decision F16; all [M] unless marked):

- **Scope (owner decision F15, 2026-10-27).** Step 1 only: a cheaper `VM_PUSH`/`VM_POP` on the same stack
  layout. Step 2, the top of the stack kept in registers, is not done: sized [E] at +100 to +250 B HOME,
  since the gain needs ~15 hot handlers rewritten (5-15 B each) and the cached value written back wherever
  the stack is read in memory (`VM_TEMP_PICK`, the calculator bridge, package calls, USR, errors).
- **Change.** The stack (`$B604-$B67F`), its pointer `VM_SP` (`$B602`) and its floor share page `$B6` (an
  `ASSERT` keeps it so), so both routines move only the pointer's low byte. `VM_PUSH` keeps the tag with
  `push af`/`pop af` instead of two RAM scratch bytes: 45 → 22 B, 234 → 116 T (counted). `VM_POP`: 26 → 22
  B, 140 → 105 T (counted). Outputs as before (HL, A, DE; `VM_POP` returns CF set, ZF clear), except that
  `VM_PUSH` returns the caller's flags (was NC): no caller tests them (every call site, and the callers of
  the 20 routines that end in a jump to `VM_PUSH`: the built-in functions return to `jp (iy)`). An overflow
  leaves one word on the Z80 stack, discarded by `VM_ERR_COMMON`'s unwind from `VM_RUN_SP`. RAM
  `$B685-$B687` is free.
- **Size.** HOME 246 → **273 B** free (+27); EXROM 621 unchanged.
- **Bytecode.** No change: `qbytecode` 667/667 identical, no baseline reset.
- **Speed (`qbench`, T, compile and run; 5.4 → 5.5, and against the build before 5.2):**

  | program          |        5.4 |        5.5 |  5.5   | since 5.2's base |
  | ---------------- | ----------:| ----------:| ------:| ---------------- |
  | `if_branch`      | 11,888,684 | 10,310,976 | −13.3% | −35.7% (1.56×)   |
  | `goto_loop`      |  5,402,826 |  4,772,304 | −11.7% | −58.3% (2.40×)   |
  | `sieve`          |  9,664,538 |  8,559,811 | −11.4% | −34.5% (1.53×)   |
  | `builtins`       | 11,649,512 | 10,625,826 |  −8.8% | −11.0% (1.12×)   |
  | `strings`        |  2,289,749 |  2,132,055 |  −6.9% | −10.1% (1.11×)   |
  | `int_loop`       | 37,931,551 | 35,725,668 |  −5.8% | −8.0% (1.09×)    |
  | `float_add_lit`  |  2,314,983 |  2,218,489 |  −4.2% | −7.0% (1.08×)    |
  | `float_loop`     |  5,832,760 |  5,675,066 |  −2.7% | −4.0% (1.04×)    |
  | `proc_calls`     |  4,795,355 |  4,676,676 |  −2.5% | −20.4% (1.26×)   |
  | `float_div`      |  7,375,626 |  7,217,932 |  −2.1% | −3.2% (1.03×)    |
  | `compile_only`   |  3,690,619 |  3,624,318 |  −1.8% | −1.7% (1.02×)    |
  | `for_float_step` | 40,594,024 | 40,122,166 |  −1.2% | −0.2%            |
  | `for_nested`     |  3,081,711 |  3,051,671 |  −1.0% | −22.6% (1.29×)   |
  | `for_empty`, `int_inc`, `loop_200`, `compile_int_if`, `compile_dec` | | | 0.0% to −0.1% | (paths without a push) |

- **Checks.** `qvmedge` 120/120 on 5.5 and on 5.4, with two new cases at the stack's limit: 40 nested
  operands run, 41 stop with STACK OVERFLOW (run-time 2), the same boundary on both builds (the stack holds
  41 entries; the manual says "about 40"). `qbreak` 19/19. `qcanary --banking` (667): 0 hits, 0 banking
  violations, Z80 stack low-water mark `$FDE8` as before. `make check` assembles.
- **Tests.** `make test` all PASS (1,742 s, on a copy): smoke 9/9, standalone 40/40, production and fill
  checks, prod-regress 127, prod-arrays 101, known-defects 15, saveall 13, micsave 3, qual 663 PASS + 2
  XFAIL + 2 N/A, lifecycle 23, `qvmedge` 120, maint-qual all (ay_beep 59, cbeep 27, di_wait 14,
  cbeep_tape 3). `make doc-examples` 327/327.
- **Owner decision F16 (2026-10-27):** integrated; fast-forwarded `backport/leapc` to `6af3278`.

### Phase 5 follow-ups (profiled after 5.5, 2026-10-27)

Owner rule (2026-10-27): a change must give a **significant speed increase** or **use less HOME or EXROM
space**. Profile of the integrated 5.5 build (`tools/qual/qprofile.py`, new: a breakpoint at every
dispatch, 11 workloads: the `qbench` programs and `~/2068-rom-benchmarks`' pixel, string and SQR programs
in V2's dialect; `--statements` for what one statement adds to a loop) [M]:

- Integer loops: dispatch is 19-27% of the run, `LOAD_VAR` the most frequent instruction (468 T).
- Float and functions: `SQR` ~258,000 T a call (74 ms), `SIN`/`COS` ~251,000, `TAN` ~553,000;
  `x = i * 0.5` adds 18,300 T, `x = i / 7` 26,500, `x = 2.5 + i` 9,200 (the calculator's multiply and
  divide loops go through RAM a bit at a time: ~330 T a multiplier bit, ~500 T a quotient bit).
- Output: a `PRINT` that scrolls adds ~250,000 T (70 ms); `GFX_SCROLL_OUTPUT_UP` is 243,944 T, of which
  the new bottom row's clear (`GFX_CLEAR_ROW`, 32 `GFX_PUTCHAR` calls) is 33,205 and each row's bitmap
  copy 6,463.
- The float built-ins (`SQR`, `PI`, `RAD`, `DEG`, `SIN`, `COS`, `TAN`, `SIN_PEEK_POP`, the divisor table)
  are 611 B of HOME; they only run while the EXROM is paged in (program runs and immediate statements,
  under the shell, as the calculator they call).

| #    | Item                                                                                          | Speed [E]                                                              | HOME [E]   | EXROM [E]      | Results            |
| ---- | --------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- | ---------- | -------------- | ------------------ |
| 5.6  | Calculator `FMUL`/`FDIV` loops in registers (the alternate set: only the tape code uses AF')  | multiply, divide ~2.5×; `float_loop` −35 to −45%; `SIN`/`COS` ~2.3×     | 0          | +30 to +80     | identical bits     |
| 5.7  | `SQR` halves its estimate by the exponent, not a float divide by 2 (exact either way)         | `SQR` −43%; ~3.6× with 5.6                                             | ~0         | 0              | identical          |
| 5.8  | Scroll: the new bottom row cleared by `GFX_CLEAR_ROW_TEXT` and a 32-byte attribute fill        | −26,000 T a scrolled line (−11%)                                       | a few B    | 0              | identical (check INVERSE/OVER) |
| 5.9  | Float built-ins moved to the EXROM behind slots                                               | ~0 (a slot call against ~250 kT)                                       | up to −611 | +450 to +650   | identical          |
| 5.10 | `SIN`/`COS`/`TAN`: one multiply by π/180 and a polynomial with stored coefficients (with 5.9)   | `SIN` 251k → ~140k T, ~55k with 5.6                                    | —          | smaller code   | last bits change: allowed (F20) |
| 5.11 | Scroll: each screen third's rows copied per scanline in one block, unrolled copy loop          | scroll ~244k → ~175k T with 5.8                                        | +30 to +60 | 0              | identical          |
| 5.12 | `LOAD v; PUSH k; CMP_JMPZ` as one instruction (handler in the EXROM if that holds up)         | ~1,000 T an `IF i < k`: `goto_loop` −45%, `if_branch` −20%, sieve 0     | ~4 (or 45) | ~70            | identical          |
| 5.13 | `PRINT` of a string: the screen and attribute addresses worked out once and stepped along the row, the 8 glyph bytes copied unrolled (today each character redoes its range checks and both addresses: `GFX_PUTCHAR` 830 T, `GFX_SET_ATTR` 217, the loop ~220) | 1,266 → ~400-450 T a character (~3×) | ~0 | +60 to +120 | identical screen |

The TS2068's SCLD (port `$FF`) offers nothing to speed output up (checked 2026-10-27): no hardware
scroll or display-start register, no blitter, no text mode. V2 already uses its display modes (normal,
`MODE 1`'s 8 x 1 attributes in the second display file, the 512-pixel mode). The second display file
could give page flipping in normal mode (`$6000-$77FF` is free there): flicker-free drawing, a language
feature, not faster output. The frame interrupt is 2,028 T a frame (2.9%) [M]: nothing to gain there.

**Room for phase 6** (owner, 2026-10-27: the follow-ups must leave room for phase 6). Allowance until 6.1
is sized [E]: 6.1 package functions ~150-200 B HOME (the study's simpler mechanism measured 95, `study/extfn`;
the export table and type-checked binding add to it; the compiler is HOME code), 6.2-6.4 ~30-60 B HOME,
EXROM 0-100 (compile-time parts behind EXROM slots); 6.5, 6.6 no ROM. Reserved: **HOME 260, EXROM 100**.
With 5.6-5.8: HOME 286 free (222 above the 64 B reserve: already ~40 B short of the allowance), EXROM
573 (541 above the reserve). So, for each remaining item, *free − reserve − phase 6's allowance ≥ its
cost* in the ROM it uses:

- 5.9 (with 5.10) comes first: it is the only item that frees HOME (up to 611 B), which phase 6 needs.
  It moves that code into the EXROM (+450 to +650 B; less once 5.10 shortens `SIN`/`COS`/`TAN`), which
  with phase 6's 100 B would leave ~0-90 B of EXROM above its reserve: the EXROM side is measured before
  5.9 is committed, and only as much moves as fits (`SIN`/`COS`/`TAN`, 452 B, first).
- 5.11, 5.12 and 5.13 then go where the room is: after 5.9 HOME has the room and the EXROM may not, so
  5.13 and 5.12's handler may live in HOME instead of the EXROM (5.13's print path runs only while the
  EXROM is paged in, so either works).
- Without 5.9, only items that cost no HOME fit (5.13 and 5.12 in the EXROM), and phase 6 would need
  the 5.0 shrink pass for its last ~40 B of HOME.

Below the bar, not to be done: a page-aligned opcode table (30 of the 151 T dispatch: ≤ 5% on tight
integer loops, ~1% elsewhere, HOME padding); `LOAD_VAR` pushing for itself (~2%); the string and
procedure-call instructions (1-2 kT each, small gains). Owner decision F17 (2026-10-27): these items go
in the plan; 5.6, 5.7 and 5.8 first. F19 (2026-10-27): 5.13 added; the follow-ups keep phase 6's room
(above).

Outcome, 5.6-5.8 (2026-10-27; prototyped on `proto/5.6-5.8-calc-sqr-scroll` off `backport/leapc` `d55bede`,
one commit per item: `460e05c` the simulator, `5774d61` 5.6, `54cd877` 5.7, `22b4999` 5.8, `bbd7189` the
pre-push hook; integrated into `backport/leapc` by fast-forward, owner decision F18; all [M]):

- **5.6, the calculator's multiply and divide in registers.** `FMUL` builds the 40-bit product in
  HL:HL':E' with the multiplicand in BC:BC' (my's bits from A, as before); `FDIV` keeps the remainder in
  HL:HL' and the divisor in BC:BC', the quotient a byte at a time in A behind a marker bit. Nothing else
  in V2 uses BC', DE' or HL' (the tape code uses AF' only; the interrupt handler none). Same bits:
  `qcalcround --leapc`, 20,000 random pairs per operation, every result equal to Leap-C's model, and the
  raw results equal to 5.5's; `qfndiff` (new) `SIN` over 1,850 arguments and `TAN` over 1,760, 5.5
  against 5.8: every result's 5 bytes equal. `qcalctime` (T, float operands): multiply 16,794 → 6,664, divide 22,324 →
  9,464 (int operands 14,806 → 7,108 and 23,060 → 10,267; add and subtract unchanged). EXROM 621 → 573 B
  free (−48). *The simulator:* `make check` runs the calculator in `tools/z80sim`, which had no `EXX`,
  `ADC HL,rr` or `CCF`; owner choice (2026-10-27): added in `~/z80sim` with tests and committed there
  (`13c9bce`, local, not pushed), together with R1's additions, which had been made in the vendored copy
  only (`EQU` constants, shifts on `(HL)`, `SET`/`RES`, `LDDR`); the vendored copy matches it again.
- **5.7, `SQR` halves by the exponent.** Each Newton step's `(x + n/x) / 2` decrements the exponent
  byte instead of pushing 2 and dividing (exact either way). 1,900 arguments (integers, decimals, 10^6 and
  10^-6 scales): every result's 5 bytes equal 5.6's. HOME 273 → 278 B free (+5).
- **5.8, the row clear.** `GFX_CLEAR_ROW` writes `ATTR_DEFAULT` to the row's 32 attributes and falls into
  `GFX_CLEAR_ROW_TEXT` (an `ASSERT` keeps them adjacent) instead of 32 `GFX_PUTCHAR` spaces and
  `GFX_SET_ATTR` calls: the same bytes (the space glyph is 8 zero bytes), rows of 24 or more still
  ignored. 33,205 → 7,527 T; `GFX_SCROLL_OUTPUT_UP` 243,944 → 218,252 T. 13 scrolling `PRINT` programs
  (colours, `BRIGHT`/`FLASH`, `INVERSE`, `OVER`, wrapping lines, `AT 23`, `PLOT`, `CLS`): the whole
  screen equal to 5.7's. HOME 278 → 286 B free (+8).
- **Group size.** HOME 273 → **286 B** free (+13); EXROM 621 → **573 B** (−48).
- **Speed per statement** (`qprofile --statements`, T a statement adds to a loop, 5.5 → 5.8):

  | statement            |     5.5 |     5.8 | change          |
  | -------------------- | -------:| -------:| --------------- |
  | `x = SQR(i)`         | 264,312 |  88,383 | 3.0× (est. 3.6×) |
  | `x = SQR(2.5)`       | 253,005 |  82,202 | 3.1×            |
  | `x = SIN(i)`, `COS`  | 251,297 | 126,852 | 2.0× (est. 2.3×) |
  | `x = TAN(i)`         | 553,234 | 291,443 | 1.9×            |
  | `x = i / 7`          |  26,470 |  15,790 | −40%            |
  | `x = i * 0.5`        |  18,340 |  11,469 | −37%            |
  | `PRINT 7` (scrolls)  | 250,321 | 223,813 | −10.6% (est. −11%) |
  | `x = 2.5 + i`, `RND`, `DIV`, `MOD`, `STR$`, `VAL`, `AT`/`PRINT` | | | unchanged |

  `qbench` (5.5 → 5.8): `float_div` −29.7%, `compile_dec` −25.6% (a decimal literal's divide at compile
  time), `float_loop` −25.3%, `float_add_lit` −0.3%; the integer, string and built-in programs unchanged.
- **Checks.** New tools for these and the later items: `tools/qual/qfndiff.py` (a built-in's results on
  two builds, byte for byte), `qscrdiff.py` (whole screens after scrolling programs), `qrtime.py` (one
  routine's T). `qbytecode` 667/667 identical (no compiler change). `qvmedge` 120/120, `qbreak` 19/19,
  `qcanary --banking` (667): 0 hits, 0 banking violations, Z80 stack low-water mark `$FDE8` as before.
  `make check` (with the simulator's calculator checks).
- **Tests.** `make test` all PASS (1,824 s, on a copy): smoke 9/9, standalone 40/40, production and fill
  checks, prod-regress 127, prod-arrays 101, known-defects 15, saveall 13, micsave 3, qual 663 PASS + 2
  XFAIL + 2 N/A, lifecycle 23, `qvmedge` 120, maint-qual all (ay_beep 59, cbeep 27, di_wait 14,
  cbeep_tape 3). `make doc-examples` 327/327.
- **Owner decision F18 (2026-10-27):** integrate once the tests pass; done (fast-forward).

Outcome, 5.9 (2026-10-27; prototyped on `proto/5.9-5.10-float-fn-exrom` off `backport/leapc` `0227797`,
one commit per item; all [M]):

- **What moved.** `SIN`, `COS`, `TAN`, `SIN_PEEK_POP` and the divisor table (460 B) went from the VM core
  (HOME) to a new `rom/exrom_v2_float_fn.asm`, which the production EXROM assembles behind three slots
  `V2_EXROM_FN_SIN/COS/TAN_ADDR` (after 5.4's; `V2_KTAB_MAGIC` $1E, $1F without the MAINT build), the
  targets of `BUILTIN_FN_JUMP_TABLE`; the standalone images (one flat bank, or the two-bank harness)
  include it from the VM core as before. The HOME routines and cells it uses are exported through
  `tools/write_v2_crossbank.py` (19 names; `VM_ERR_RANGE` now in every build, `FP_TRUNC_ZERO` an alias of
  `FP_TRUNC.zero`). `SQR`, `PI`, `RAD` and `DEG` (146 B, and 24 B of slots) stay in HOME: with them the
  EXROM would fall below phase 6's room.
- **Fitting it.** Moved as they were, the three cost the EXROM 479 B (94 free, 38 short of the 132 that
  keep phase 6's 100 B above the reserve). Four bit-identical changes made the room: `SIN_PEEK_POP` takes
  the slot address from the calculator's `CALC_SP_TO_NEXT_FREE_PTR` and gains a no-pop entry `SIN_PEEK`;
  x² is `duplicate, duplicate, multiply` on the stack instead of a store and two pushes; the term loop
  peeks the new power instead of pop-and-push; the final `0 - acc` (three pushes and a subtract) is the
  sign bit flipped, which is what the subtraction gives for a non-zero general-form number (FADD copies
  the other operand when one is 0; acc is never 0 where the sign is applied). EXROM 142 free.
- **Results.** `qfndiff` against `0227797`: `SIN` 1,850 arguments, `COS` 1,850, `TAN` 1,847: 0 results
  differ (the 24 `TAN` arguments of one program stop with error 15 on both builds: see 5.10).
- **Where they run.** `qcanary --banking` (667 cases) has a fourth invariant: an EXROM entry slot
  (`V2_EXROM_CALCULATE_ADDR` to `V2_EXROM_ARRSVC_ADDR`) entered with the EXROM paged out (checked to fire
  with a `call` to the `SIN` slot at depth 0, and not at depth 1). 0 hits, 0 banking violations, Z80
  stack low-water mark `$FDE8` as before; the corpus calls `SIN` in 7 cases, `COS` 3, `TAN` 2. A probe
  stopping at each slot: a program enters `SIN` 5 times, `COS` 4, `TAN` 2, an immediate `PRINT` each once,
  all at depth 1. The compiler never calls them: it finds a function by name in its own table
  (`BUILTIN_FN_FIND`) and emits `CALL_FN` and the index; it folds literals only.
- **Speed** (`qprofile --statements`, T a statement adds, `0227797` → 5.9): `SIN(i)` 126,852 → 125,590
  (−1.0%: the EXROM calls the calculator directly, not through its slots), `COS(i)` 126,756 → 125,562,
  `TAN(i)` 291,443 → 288,746, `SIN(2.5)` 138,789 → 137,531, `COS(2.5)` 143,590 → 142,274.
- **Accuracy** (new `qfndiff --exact`: each result against the exact value at the argument the ROM holds,
  in units of the last place; the same for `0227797` and 5.9): `SIN` 25.1% correctly rounded, the largest
  error 16,713 ulp (`630.774`), mean 1,118; `COS` 17.7%, 16,821 ulp but for `COS(32687)`, mean 1.3 M;
  `TAN` 0.8%, 15,541 ulp, mean 2,519. The five-term series stops at x⁹/9!, whose remainder is ~3.6e-6
  at 90°: `SIN(90)` is 1.0000036.
- **Defect found** (Q-35, fixed in 5.10): `COS` adds 90 before reducing mod 360, in 16 bits: `COS(n)` for
  n = 32678 to 32767 wraps (`COS(32687)` gives sin 1° = 0.01745, not cos 287° = 0.2924), and `COS(x)`,
  `TAN(x)` of a FLOAT above 32677 stop with error 15 although `SIN` takes up to 32767.
- **Checks.** `make check`, and the images with the release definitions (`make build EXTRA_DEFS=`: HOME
  781, EXROM 141 free) assemble.

## Phase 6: package ABI 2.1 (minor version: old packages keep working)

| #   | Item                                                                                                                                                                                                    | Notes                                                  |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| 6.1 | **Package functions** (not only statements): finish `study/extfn`, using Leap-C's export-table + signature-byte model (name, address, argument/result types; compiler-side binding, type-checked calls) | Leap-C `spec.md` §7.2                                  |
| 6.2 | **Float service slot** through an EXROM page-in wrapper (as slot 14 already does)                                                                                                                       | Float is explicitly outside ABI 2.0 today              |
| 6.3 | **Error service + a registered package error range**                                                                                                                                                    | Closes R10.8 A3 (package codes 12-21 overlap the VM's) |
| 6.4 | Reserved slots trap with a defined error instead of blank `$FF` bytes                                                                                                                                   | Small; tidier than relying on the version check        |
| 6.5 | **Measured package stack budget** (Leap-C measured per service incl. an interrupt: 30-42 B) instead of the unmeasured 512 B allowance                                                                   | Lets phase 7 reclaim part of `$F800-$F9FF`             |
| 6.6 | Document what happens when a package name equals a keyword; host tool warns (Leap-C `lib2tape.py`)                                                                                                      |                                                        |

Size allowance [E] (held free by the phase 5 follow-ups, "Room for phase 6"): HOME ~260 B, EXROM ~100 B
in all, mostly 6.1 (the study's simpler function packages measured HOME 95 B, `study/extfn` `7c349f2`).
Sizing 6.1 first replaces it with a measured figure.

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
  F11 as decided. `STEP 0` with the start already past the limit stays as it is (owner, F11: V2 makes no
  pass; the standards' test would never end the loop). After F11: `make qual` 663 PASS + 2 XFAIL + 2 N/A (as before
  R1), lifecycle 23, `make doc-examples` 326/326.

## Not recommended

- D4 (Leap-C's BREAK model), D7 (C key map; V2 earmarks SS+A/S for page-down/bottom), D9/D11/D12 (Leap-C's
  HOME/EXROM moves), D17-D19 dead-code removals (V2's callers still use those entries), deleting
  `GFX_CLEAR_ROW_TEXT`, `check_platform.py`.
- After 5.5 (profile, "Phase 5 follow-ups"): the page-aligned opcode table, `LOAD_VAR` pushing for
  itself, and step 2 of 5.5 (the top of the stack in registers; owner F15).
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
| F11 | Float `FOR` counts after R1              | (a): follow the standard; `STEP 0` stays as it is (2026-10-26)      |
| F12 | Physical TS2068 run                      | Not possible at this time: emulators only (2026-10-26)              |
| F13 | Phase 5 grouping                         | 5.2, 5.3 and 5.4 together, one commit per item (2026-10-26)         |
| F14 | 5.2-5.4 prototype                        | Integrated, fast-forward to `201b960` (2026-10-27)                  |
| F15 | 5.5 scope                                | Step 1 only (cheaper push/pop); no top of stack in registers (2026-10-27) |
| F16 | 5.5 prototype                            | Integrated, fast-forward to `6af3278` (2026-10-27)                  |
| F17 | Phase 5 follow-ups                       | Added (5.6-5.12); 5.6, 5.7, 5.8 first (2026-10-27)                  |
| F18 | 5.6-5.8 prototype                        | Integrated (fast-forward, 2026-10-27); simulator: z80sim `13c9bce`, pushed to GitHub (owner, 2026-10-27) |
| F19 | 5.13; room for phase 6                   | 5.13 added; follow-ups keep HOME ~260 / EXROM ~100 B free for phase 6 [E] (2026-10-27) |
| F20 | 5.10's results                           | `SIN`/`COS`/`TAN` may change in the last bit (2026-10-27)           |
| F21 | Manual speed figures; pushing            | Updated now (5.6-5.8 build); `backport/leapc` may be pushed (2026-10-27) |

## Also worth doing

- **Physical TS2068 run** before v2.1 (owner, F12: not possible at this time; emulators only): neither V2 nor Leap-C has run on real hardware; items 1.4, 2.2,
  3.1 and 4.x all have hardware-sensitive parts (60 Hz frames, power-on RAM, tape tolerance, contention).
- **Fuse alongside ZEsarUX for timing-sensitive cases**: ZEsarUX runs the TS2068 at the 48K's 50 Hz
  frame; the real machine is 60 Hz [L: M9]. Everything counted in frames is 20% faster on hardware.
- **Keep this plan's ledger (§0) current** with each merged item's measured bytes, as Leap-C's
  improvements report did.
