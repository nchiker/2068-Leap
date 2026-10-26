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

| After                        | HOME    | EXROM   | Basis                                                                                         |
| ---------------------------- | -------:| -------:| --------------------------------------------------------------------------------------------- |
| today                        | 275     | 26      | [M]                                                                                           |
| phase 1 (space)              | **373** | **138** | [M]: 1.1 EXROM −112; 1.2 HOME −36; 1.3 HOME −12; 1.4 HOME −2; 1.5 HOME −48                    |
| phase 2 (bug fixes)          | **358** | **123** | [M]: phase total HOME −15, EXROM −15 (items 2.1-2.3; v2.0.3)                                  |
| phase 3 (licensing)          | **358** | **199** | [M]: 3.1 tape block I/O EXROM +19; 3.2 calculator dispatcher EXROM +57                        |
| phase 4 (display quick wins) | **354** | **208** | [M]: 4.1 HOME +4; 4.2, 4.3 0; 4.4 EXROM +16, status-bar attribute fill EXROM −25              |
| redraw from the cursor line  | **354** | **186** | [M]: EXROM +22                                                                                |
| phase 5 (speed)              | ≥ 64    | ≥ 32    | Class B: each item sized and weighed before it is started; 5.0 first if the room is not there |

Every [E] is replaced by `make budget`'s figure as each item lands.

## Phase 0: tooling and guard rails (no ROM change)

Goal: every later phase runs faster and is checked automatically. Do these first because each later
phase's qualification run pays for them.

| #    | Item                                                                                                                                                        | Source                                        | Effort | Notes                                                                                                                                                                         |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0.1  | **ZRCP latency fix**: `TCP_NODELAY` + re-armed `TCP_QUICKACK` in `ts2068-debug`'s `ZRCPClient.connect`                                                      | Leap-C `tools/lcharness.py:39-82`             | S      | Leap-C: 41 ms → 0.04 ms per reply; full suite 3,333 s → 305 s with the pool [L]. A change to ts2068-debug, so every project gains. Re-measure V2's 47-min `make test` after   |
| 0.2  | **One persistent ZRCP client** in `tools/v2_headless.py` instead of a CLI process per command                                                               | qharness already does this                    | M      | **Done as opt-in (`V2_HEADLESS_INPROC=1`)**: no wall-clock gain on the prod suites (1,826 s in-process vs 1,630 s, loaded host); their time is the tape cases' emulated waits, and one case stalled 477 s in-process [M]. Those long tape cases are the target for 0.10 |
| 0.3  | **`make test-fast`** (corpus + production gate, a few minutes)                                                                                              | Leap-C `run_tests.py --fast`                  | S      | Then, later, one worker pool across stages                                                                                                                                    |
| 0.4  | **Emergency reserve enforced by `make check`** (`report_budget.py --check`, reserves from §0)                                                               | Leap-C `budget.toml`, `budget.py --check`     | S-M    | Per-component budgets optional; the two reserves are the point                                                                                                                |
| 0.5  | **Provenance scan** (`tools/provenance.py`: runs of ≥12 B shared with the stock ROMs) in `make check`, skipped when stock ROMs are absent                   | Leap-C `tools/provenance.py`                  | S      | Known hits today (the review's scan): two PO-GR-2 runs in `GFX_CHAR_TO_FONT_OFFSET`, five SA/LD-BYTES runs in storage. Start with these as an allow-list that phase 3 empties |
| 0.6  | **Power-on RAM boot test**: fill `$4000-$FFFF` with patterns after reset, boot, compare idle RAM and run the corpus                                         | Leap-C `tools/poweron.py` (found its UDG bug) | S-M    | Proves item 2.2 and finds any other uninitialised cell                                                                                                                        |
| 0.7  | **Banking invariants in the canary**: depth == 1 while the VM runs, 0 inside `OP_CALL_EXT`; no write to `$C000-$DFFF` with EXROM in; stack never in chunk 6 | Leap-C `tools/memguard.py`                    | M      | Guards items 2.3 and phase 7                                                                                                                                                  |
| 0.8  | **Fuse frame-count probe** for item 1.4 (Fuse frame count vs `FRAMES` over a float loop)                                                                    | Leap-C M9 §5.4                                | S      | **Owner approval needed**: Fuse runs only on request. ZEsarUX cannot show the defect                                                                                          |
| 0.9  | Reproducible-build check (two clean builds, identical hashes)                                                                                               | Leap-C `tools/check_repro.sh`                 | S      |                                                                                                                                                                               |
| 0.10 | Fast emulation (`--emulatorspeed 1000 --frameskip 49`), **default** in ts2068-debug (`TS2068_DEBUG_ZESARUX_FAST=0` for real speed) | Leap-C `lcharness.py:32-36`                   | S      | **Done (F7)**: `make test` 1,940 s vs ~3,200 s at real speed, all PASS incl. D5 and the tape cases [M] |

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
for short programs only). `SH_VIEW` waits for 5.1's size.

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

## Not recommended

- D4 (Leap-C's BREAK model), D7 (C key map; V2 earmarks SS+A/S for page-down/bottom), D9/D11/D12 (Leap-C's
  HOME/EXROM moves), D17-D19 dead-code removals (V2's callers still use those entries), deleting
  `GFX_CLEAR_ROW_TEXT`, `check_platform.py`.
- Already in V2: doc examples as tests, the RAM-layout guard, the canary, CI with pinned sjasmplus,
  release packaging.

## Owner decisions

All decided by the owner on 2026-10-25.

| Id  | Decision                                 | Outcome                                                   |
| --- | ---------------------------------------- | --------------------------------------------------------- |
| F1  | ROM spending                             | Weighted policy with a 64 B / 32 B emergency reserve (§0) |
| F2  | Fuse run for the frame-loss probe (0.8)  | Approved                                                  |
| F3  | Keep `EDIR_HOME/END` in production (1.1) | Only if the R10.8 navigation keys are planned             |
| F4  | Release grouping                         | v2.0.3 = phases 1-2; v2.0.4 = phase 3; v2.1 = phases 4-6  |
| F5  | Start phase 7 (V3)                       | Decide after v2.1, with 7.6's spike numbers               |
| F6  | Calculator rewrite (3.2)                 | Counts as clean-room (2026-10-26)                         |
| F7  | Fast emulation (0.10)                    | Default for the suites (2026-10-26)                       |

## Also worth doing

- **Physical TS2068 run** before v2.1: neither V2 nor Leap-C has run on real hardware; items 1.4, 2.2,
  3.1 and 4.x all have hardware-sensitive parts (60 Hz frames, power-on RAM, tape tolerance, contention).
- **Fuse alongside ZEsarUX for timing-sensitive cases**: ZEsarUX runs the TS2068 at the 48K's 50 Hz
  frame; the real machine is 60 Hz [L: M9]. Everything counted in frames is 20% faster on hardware.
- **Keep this plan's ledger (§0) current** with each merged item's measured bytes, as Leap-C's
  improvements report did.
