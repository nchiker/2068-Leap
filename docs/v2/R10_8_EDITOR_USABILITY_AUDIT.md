# R10.8 — Editor Usability Audit (original TS2068 keyboard and display)

Read-only audit of the V2 full-screen editor/shell at commit `6151b64`. Finding IDs `D1…D11`,
`R1…R9` refer to [`R10_8_GAP_ANALYSIS.md`](R10_8_GAP_ANALYSIS.md); `U*`/`O*` are defined here.
Evidence tags as in the gap analysis: **[M]** measured headless on the production ROM,
**[S]** source-level, **[E]** estimate, **[H]** hypothesis. All timings are emulator T-states at the
TS2068 CPU clock (3.528 MHz), uncontended; **nothing here is physical-hardware evidence**.

Scope: `rom/exrom_editor.asm` (key loop, wrap tables), `rom/exrom_v2_shell.asm` (command loop,
dispatch, redraw, status, messages, LIST, SAVE/LOAD UI), `kernel/io/io.asm` + `kernel/interrupt/
interrupt.asm` (keyboard), `include/keys.inc`.

## 1. How the editor works (as built)

* The program is a line store of records `[len:2][text][CR]` (`MEM_LINE_*`). There are no line numbers.
  One record = one editor line, ≤ 127 characters (`EDIT_LINE_BUF_LEN 128`), displayed word-wrapped
  over up to 8 rows of 32 columns (`EDITOR_WRAP_CALC`).
* The user edits **one buffer** (`EDIT_LINE_BUF`) that is a copy of the current record, or the empty
  "new line" sentinel past the last record (`CUR_EDIT_POS = $FFxx`).
* `EDITOR_LOOP` (EXROM, `rom/exrom_editor.asm` 107–140) reads one key at a time from the ISR latch.
  Keys: printable → `EDITOR_INSERT_CHAR` then **full redraw**; `ENTER` → return the line to the shell;
  LEFT/RIGHT → cursor-only fast path; UP/DOWN/DELETE-LINE/INSERT-LINE → shell hook `V2_NAV` then full
  redraw; `DELETE` → backspace (or delete line if the buffer is empty).
* `V2_COMMAND_LOOP` (`rom/exrom_v2_shell.asm` 123–182): after `ENTER`, if the cursor was on the sentinel,
  the text is offered to `V2_DISPATCH` (`RUN`, `LIST`, `NEW`, `SAVE`, `LOAD`, `VERIFY`, or a `:`-prefixed
  immediate statement); anything else (and **every line typed anywhere but the sentinel**) is stored
  with `MEM_LINE_STORE`, the cursor advances to the next record.
* `V2_REDRAW` (1718–1808) = `GFX_CLS`, count lines, choose the viewport, draw every visible record
  (keyword-scan → bold spans → per-character plot), draw the active line plain, draw the row-23 status
  bar, invert the cursor cell's attribute (hardware FLASH).

**What works well [S/M].** Word-boundary wrap with correct cursor mapping; LEFT/RIGHT are cheap
(attribute-only); keyword emphasis on settled lines; CAPS SHIFT+ENTER inserts a blank line, CAPS
SHIFT+1 deletes a line; the status bar shows `LINE n/m` on a distinguishable black/white row with the
RGB swatch; the cursor is a hardware-FLASH block (no interrupt code); long lines wrap and edit
correctly; messages are confined to row 23 so the program stays visible (a lesson from V1 that was
re-applied).

## 2. Confirmed defects (editor-visible)

| ID | Sev | Defect | Evidence |
|---|---|---|---|
| **D4** | H | After a compile error the cursor lands on the wrong line — always the *last* line for short lines. | `t23` **[M]** (gap analysis §2.1) |
| **D5b** | M | The BREAK key (CAPS SHIFT+SPACE, code `$10`) is inserted into the edit line as a control character (it reaches `EDITOR_INSERT_CHAR`). `EDITOR_LOOP` only skips code `0`. Any other unhandled code below `$20` would behave the same. | `t12` **[M]**; `rom/exrom_editor.asm` 133–139 **[S]** |
| **ED1 = D9a** | M | Pressing UP/DOWN with an uncommitted edit discards the edit (buffer is reloaded from the record). There is no "modified" indicator. | `t7` **[M]**; `V2_NAV` 400–478 **[S]** |
| **ED2 = D9b** | M | `PROGRAM FULL` (`ENTER` when the line store is full) returns to `.loop` → `EDITOR_INIT` + `V2_LOAD_EDIT`: the typed line is lost. | `rom/exrom_v2_shell.asm` 179–182 **[S]** |
| **ED3** | M | **Typing a command anywhere except the end-of-program line stores it as program text.** `RUN` typed on line 12 replaces line 12 with the text `RUN`; `CLS`, `CLEAR`, `HELP`, `DELETE` typed anywhere (including the sentinel) are also stored as lines (`V2_DISPATCH` knows only RUN/LIST/NEW/SAVE/LOAD/VERIFY and `:`). The two lines then fail to compile (and, by D3, may silently stop the program). | `V2_COMMAND_LOOP` 140–146, `V2_DISPATCH` 654–737 **[S]** |
| **ED4 = R9** | L | Active line wrapping below row 22 loses its cursor (rows ≥ 23 are not drawn; `cp 23 / ret nc` suppresses the cursor). Needs a ≥ 97-character line (3 wrapped rows start at row 20). | `V2_REDRAW` 1800–1808 **[S]** |
| **ED5** | L | `V2_LIST` cannot be aborted: every page end calls `KTAB_IO_READ_KEY` and continues. | `V2_LIST` 1368–1399 **[S]** |
| **ED6** | L | The edited row is never keyword-emphasised, and at most `KW_SPAN_MAX = 8` keywords per line are emphasised. Cosmetic; deliberate (matches V1). | **[S]** |

(D5 — no way to interrupt a running program — is the single most serious editor-adjacent defect; see the
gap analysis.)

## 3. Usability shortcomings (measured or source-evident; not bugs)

| ID | Sev | Shortcoming | Evidence |
|---|---|---|---|
| **U1** | **H** | **Typing latency is 0.3–0.6 s per keystroke.** Every non-cursor key triggers `V2_REDRAW`, which clears the whole screen and redraws every visible line: 1.02 M T (288 ms) with 10 lines on screen, **1.9–2.1 M T (545–600 ms)** once the screen is full, independent of program length. A single-slot key latch (`KBD_LASTK`/`KBD_KEYHIT`, ISR-fed, debounce 2 ticks) means a key typed during a redraw is overwritten by the next; at normal typing speed (≥ 3 chars/s) characters will be dropped. The header of `kernel/interrupt/interrupt.asm` already records real-hardware reports of "general lag and quick taps … not registering". Auto-repeat (35 ticks, then every 5) cannot keep up: a held key repeats at the redraw rate. | `t5/t6` **[M]**; interrupt/io sources **[S]**; drop rate **[H]** |
| **U2** | **H** | **There is no fast navigation.** The only vertical movement is UP/DOWN, one line per keystroke, each costing a full redraw plus a chain walk (`V2_COUNT_LINES` 13.5 ms and `V2_SET_EDIT_FROM_INDEX` up to 35 ms at 200–400 lines). Top→bottom of a 200-line program ≈ 200 × 0.6 s ≈ **2 minutes** of key presses. There are no page, top/bottom, or line-start/line-end keys, though `EDITOR_MOVE_CURSOR` already implements HOME/END and `EDIR_TOP/BOTTOM` constants exist. | **[M]+[S]** |
| **U3** | **H** | **Commands can only be given at the very end of the program** (ED3). After an error the cursor is on the offending (or, D4, nearby) line; to `RUN` again the user must first navigate to the last line — which is U2. This turns the edit→run→fix loop into the dominant cost of using the system. | **[S]** |
| **U4** | M | The status line shows only `LINE n/m`; messages (`SYNTAX ERROR`, `RUNTIME ERROR`) carry no code, no position, no free-memory figure, and are dismissed by any key. Every compile code 2–59 prints `SYNTAX ERROR`. | `V2_COMPILE_MSG/V2_RUNTIME_MSG` 619–652, `V2_SHOW_MESSAGE` 1945–1960 **[S]** |
| **U5** | M | Runtime errors have no source position (documented as unresolved since R10). The only information is a generic class. | R10 doc **[D]**, `V2_RUNTIME_MSG` **[S]** |
| **U6** | M | **Display state leaks from a run into the editor.** `MODE 1` leaves the editor drawing into hi-res (overlapping rows, no attribute bar — screenshot `mode1_editor`); colours/FLASH/OVER/INVERSE persist into the next RUN (the editor itself keeps its own fixed attributes `$38`). `V2_COMMAND_LOOP` resets all of this only once, at boot. | `t7`, `t20` **[M]** |
| **U7** | M | Viewport policy: once the cursor is past row 20 the view top is `index − 20`, so *every* UP/DOWN scrolls the whole window and forces a full redraw even when the cursor could simply move within the visible window. | `V2_REDRAW` 1726–1741 **[S]** |
| **U8** | M | `NEW` erases instantly, `LOAD` replaces the program without a prompt, `VERIFY` failure erases it (D2). No undo. | **[S]** |
| **U9** | L | A typed line that makes the pool exceed what RUN can carve is accepted by the editor (`PROGRAM FULL` only when the store itself overflows) and refused only at RUN as `OUT OF MEMORY` (< ~110 B pool free). No free-memory display (`FREE()` exists but only inside programs). | `V2_RUN_STORED`, `VM_CARVE_TABLES` **[S]**, R10.7 doc **[D]** |
| **U10** | L | No search, no block copy/move/mark (`EDITOR_BLOCK_DELETE` is a stub whose selection mechanism "still doesn't exist"), no undo, no word movement. | `rom/exrom_editor.asm` 565–594 **[S]** |
| **U11** | L–M | A full `GFX_CLS` + redraw on every keystroke will flicker visibly on a CRT/LCD; the emulator cannot show this. | **[H]** (physical test) |
| **U12** | L | The V1 multi-error list/`NEXT_ERROR`/`PREV_ERROR` keys (SYMBOL SHIFT+A/S) are still decoded by `IO_DECODE_KEY` and dispatched to a hook that ignores them — dead keys. | `V2_NAV` 400–409, `io.asm` 421–437 **[S]** |

## 4. TS2068 keyboard facts used for the proposal

The TS2068 matrix is the standard Spectrum-family 8×5 matrix (`docs/hardware_notes.md`); there are no
dedicated Home/End/PgUp/PgDn/function keys. This ROM's decode (`IO_DECODE_KEY`, tables
`KEY_ASCII_TABLE*`) currently assigns:

| Combo | Meaning today |
|---|---|
| CAPS+5 / 6 / 7 / 8 | LEFT / DOWN / UP / RIGHT |
| CAPS+0 | DELETE (backspace; delete-line when buffer empty) |
| CAPS+1 | delete whole line (`KEY_DELETE_LINE`) |
| CAPS+ENTER | insert blank line (`KEY_INSERT_LINE`) |
| CAPS+SPACE | BREAK (`KEY_BREAK $10`; no consumer, D5/D5b) |
| CAPS+letter | upper-case letter; **CAPS+2, 3, 4, 9: unmapped (decode 0, ignored)** |
| SYMBOL+digit/punctuation | the punctuation table in `docs/hardware_notes.md` |
| SYMBOL+A / S | `KEY_NEXT_ERROR` / `KEY_PREV_ERROR` (dead in V2, U12) |
| SYMBOL+ D F G Q W E I U Y H X, SPACE | **unmapped** (stock Spectrum gives keyword tokens or `<=`,`<>`,`>=` on Q/W/E; this ROM does not implement tokens) |

Because the ISR reports one tracked key at a time and resolves the shift state at acceptance time,
two-shift chords (CAPS+SYMBOL, "extended mode") are **not** decoded today (CAPS wins). The TS2068 has
a duplicate CAPS SHIFT keycap on the right (`hardware_notes.md` line 16) — the BREAK keycap's matrix
position is still unconfirmed there.

### 4.1 Proposed practical key set (no assumed dedicated keys)

All proposed combos are **currently unmapped or dead**, so none conflicts with a live command,
a typed character or the existing editor keys. The letter chords use the left-hand block
Q W / A S with the right hand on SYMBOL SHIFT, mirroring the physical up/down layout (Q above A,
W above S):

| Function | Combo | Replaces/uses | Rationale |
|---|---|---|---|
| Page up | **SYMBOL+Q** | unmapped (stock `<=`) | Q is above A |
| Page down | **SYMBOL+A** | dead `KEY_NEXT_ERROR` | |
| Top of program | **SYMBOL+W** | unmapped (stock `<>`) | W above S |
| Bottom of program (the command/new-line row) | **SYMBOL+S** | dead `KEY_PREV_ERROR` | |
| Start of line | **CAPS+4** | unmapped (stock INV VIDEO) | left of the 5-6-7-8 cursor cluster |
| End of line | **CAPS+9** | unmapped (stock GRAPHICS) | right of the cluster |
| Run program from anywhere | **SYMBOL+SPACE** | unmapped | thumb on SPACE, easy; avoids ED3 |
| (optional) word left / right | **CAPS+2 / CAPS+3** | unmapped | |
| (optional) list free memory / toggle | **SYMBOL+E** | unmapped | |

Alternative if letter chords test badly on hardware: use **both shifts held** (the stock "extended mode"
chord, needs the ISR to report both modifiers) with 5/6/7/8 for page/top/bottom. Costlier (new ISR
state) and physically awkward on this keyboard; not recommended first.
The new combos must be added to `include/keys.inc` and `IO_DECODE_KEY` (HOME ROM, `kernel/io/io.asm`).
`KEY_BREAK` ($10) must additionally be filtered by `EDITOR_LOOP` (D5b).

**This proposal requires a physical typing trial before it is frozen** (ergonomics cannot be
established headless).

## 5. Improvements, with cost estimates

ROM/RAM numbers are **[E]** estimates (nothing assembled). "Diff." is implementation difficulty.
HOME headroom is 546 B; EXROM 1,385 B.

| ID | Improvement | Fixes | Diff. | HOME | EXROM | RAM | Testing |
|---|---|---|---|---:|---:|---:|---|
| **I1** | **Selective redraw, fast path A** — typing/backspace/delete inside the active line when the wrap-row count and line count are unchanged: clear and redraw only the active line's rows (`GFX_CLEAR_ROW_TEXT` + `V2_DRAW_TEXT`), restore/set the cursor attribute (as the LEFT/RIGHT path already does), skip status. Predicted ≈ 45–60 k T per row (≈ 13–17 ms) vs 550 ms. | U1 (largest part), U11 | M | 0 | +60–90 | +1–2 (prev wrap count, dirty flag) | T-state budget assert on the production ROM; **differential screen-hash test** (selective vs full redraw after each key of a scripted edit session must give identical screens); physical flicker/feel trial |
| **I2** | **Fast path B + sticky viewport** — UP/DOWN inside the visible window: redraw only the two affected lines (old active as settled/bold, new active plain) and patch the line number in the status; scroll only when the cursor leaves the window, then re-centre (amortised). | U1, U7 | M | 0 | +80–120 | +2 | same differential test; scripted navigation sessions |
| **I3** | Navigation keys of §4.1 (page up/down, top, bottom, line start/end) handled in `V2_NAV`/`EDITOR_LOOP`; page jumps use the slow path once. | U2 | S–M | +40–70 (decode) | +60–110 | 0 | scripted key injection through `KBD_LASTK/KBD_KEYHIT` (as `t12`) for each new code; boundary tests (top/bottom/empty program/sentinel) |
| **I4** | **Run from anywhere** (`SYMBOL+SPACE`): commit the buffer, compile/run the stored program without touching stored lines; after return/error the cursor stays put (or at the error line). Also stop storing recognised command words typed on non-sentinel lines (reject with a message) — fixes ED3. | U3, ED3 | S | 0 | +25–45 | 0 | production check: run from line 1 of a 20-line program; command typed on a stored line is rejected |
| **I5** | **Commit-on-navigate**: if `EDIT_LINE_BUF` differs from the record, store it before moving; on `PROGRAM FULL` keep the buffer and the cursor. | D9/ED1/ED2 | S | 0 | +15–30 | 0 | `t7`-style test inverted; fill-pool test |
| **I6** | Ignore codes `< $20` that have no handler in `EDITOR_LOOP` (BREAK etc.). | D5b | S | 0 | +4–6 | 0 | `t12` inverted |
| **I7** | **Correct error line** via a line counter maintained by the lexer (increment on each record separator consumed); `V2_JUMP_TO_ERROR_LINE` becomes `CUR_EDIT_INDEX = counter`. The old chain walk (~45 B) is deleted. | D4 | S–M | +10–15 | −30…−40 (net; old walk is 45 B measured) | +2 | `t23` generalised: error at index k ∈ {0, mid, last} for 5/25/65-character lines must land exactly (± the look-ahead token) |
| **I8** | Reset display/attribute state at the start of RUN **and** on return to the editor (video mode 0, `CURRENT_*` defaults, optionally border), reusing the init block at the top of `V2_COMMAND_LOOP`. | U6 | S | 0 | +15–25 | 0 | `MODE 1` program then editor screenshot/`PORT_FF_SHADOW`; second-run attribute test |
| **I9** | Status/messages: append the error code/name (`SYNTAX ERROR 9`, `DIV BY ZERO`, `BAD ARRAY INDEX`, …); show `FREE nnnn` at the right of the status bar (reuses `BASIC_NUM_TO_STRING_EXROM`). | U4, U9 | S | 0 | +80–150 (strings dominate) | 0 | message selection table test; screenshot compare |
| **I10** | Make `LIST` abortable (BREAK) and add the pages-remaining hint; or retire `LIST` (the editor already shows the program). | ED5 | S | 0 | +6–10 / −60 | 0 | — |
| **I11** | Runtime error line (statement-count or IP→line table). | U5 | M–L | +30–60 | +40–80 | ~2 B/line of pool [H] | needs design; DEFER candidate |
| **I12** | NEW/LOAD confirmation or a one-level "undo NEW" (keep the pool untouched until the next store). | U8 | M | 0 | +30–60 | 0 | — |

Total for the recommended editor set (I1–I8): **HOME ≈ 50–85 B, EXROM ≈ 250–420 B [E]**, RAM ≈ 5–8 B,
which fits the free space with ≥ 450 B HOME and ≥ 900 B EXROM to spare before other pre-R11 items.

### 5.1 Why selective redraw is not "a major rewrite"

`V2_REDRAW` already separates (a) viewport choice, (b) per-record draw (`V2_DRAW_TEXT`) and (c) status;
`EDITOR_LOOP` already has a cursor-only fast path (`.do_move`). I1/I2 add a *dirty-scope* argument
(`NONE/ACTIVE_LINE/TWO_LINES/FULL`) set by the caller and honoured at the top of `V2_REDRAW`; the
full path remains the reference behaviour, which makes a differential test (§5 I1) a complete
regression oracle. No change to line-store, compiler or VM.

### 5.2 What would still be slow after I1–I8

Page jumps and any scroll still take the full path (~0.55 s). Per-line draw cost (75 k T: 25 k keyword
scan, 40 k plotting, 4 k wrap) could be halved by caching keyword spans per record or a faster
`GFX_PUTCHAR`, but that is a further, optional gain.

## 6. Workflow audit of editor commands

| Workflow | Today | Problems |
|---|---|---|
| Enter a program | type lines; `ENTER` stores and advances | 0.3–0.6 s/char (U1); no completion help |
| Edit an earlier line | UP/DOWN to it, edit, `ENTER` | slow (U2); edit lost if you move away first (D9a) |
| Insert a line mid-program | CAPS+ENTER then type | works |
| Delete a line | CAPS+1 | works (no undo) |
| Run | go to the last line, type `RUN`, `ENTER` | U3; typing it elsewhere corrupts that line (ED3) |
| After a compile error | message, any key; cursor jumps (D4) | wrong line; then U3 |
| After a runtime error | message, any key | no position (U5) |
| List | `LIST` at the end | paged, cannot abort (ED5) |
| New | `NEW` at the end | no confirmation (U8) |
| Save | `SAVE "name"` (name ≤ 10 chars, quoted; `EXT`/`ARRAY` qualifiers) | `SAVED` is printed unconditionally (`STORAGE_SAVE` has no failure return and does not detect a SPACE abort); no progress hook, so a long SAVE shows only border flicker |
| Load/verify | `LOAD "name"` / `LOAD ""` / `VERIFY "name"` | D1, D2 |
| Clear | `CLEAR` exists only as a program statement (typed at the prompt it becomes a stored line, ED3) | D8 |
| Near full | `PROGRAM FULL` (typed line lost, D9b); RUN refuses at < ~110 B pool free | U9 |

## 7. Physical-test checklist for the editor

1. Typing 20 characters at normal speed into a full screen: count dropped keys (expected losses from U1).
2. Held-key repeat on UP/DOWN/RIGHT: repeat rate vs redraw time.
3. Full-screen `CLS` flicker per keystroke on the target display (U11).
4. The proposed chords (§4.1): comfort with SYMBOL SHIFT held by one hand and Q/A/W/S by the other;
   `CAPS+4/9` reachability; accidental activation near `CAPS+5…8`.
5. BREAK keycap behaviour (if a separate matrix position exists) — D5/D5b.
6. Display after `MODE 1` (U6) on hardware that supports hi-res.
