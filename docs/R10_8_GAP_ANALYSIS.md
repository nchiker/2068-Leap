# R10.8 — Gap Analysis: Correctness, Integration, and Workflow Audit

Read-only audit of the 2068-Leap V2 production implementation at commit `6151b64`
(`main`, clean tree at start). Companion documents: [`R10_8_FEATURE_MATRIX.md`](R10_8_FEATURE_MATRIX.md),
[`R10_8_EDITOR_USABILITY_AUDIT.md`](R10_8_EDITOR_USABILITY_AUDIT.md),
[`R10_8_PRE_R11_PLAN.md`](R10_8_PRE_R11_PLAN.md). Nothing in the production tree was changed;
nothing was committed.

## 0. How to read this document

Every statement carries one evidence class. Findings are never promoted across classes
silently.

| Tag | Meaning |
|---|---|
| **[M]** | **Measured** in this audit, headless, on the real production ROM (`build/ts2068rom_zesarux.bin`) under ZEsarUX via `ts2068-debug`, or from `make budget`. Reproduction recipes are in Appendix A. |
| **[S]** | **Source-level conclusion**: read directly from the cited file/symbol; not executed. |
| **[D]** | **Documented** in an existing project document (cited); not re-verified here. |
| **[E]** | **Estimate** (ROM/RAM/effort) — not assembled. Always labelled. |
| **[H]** | **Hypothesis**, unverified. |

Finding classes, as requested: *Proven defect*, *Credible architectural/integration risk*,
*Untested behaviour*, *Documented design limitation*, *Optional enhancement*.

**Environment caveat that applies to everything below.** All measurements are emulator
(ZEsarUX) results. No physical TS2068 was available. T-state counts are raw CPU cycles;
display-memory contention is **not** modelled by the counter, so real hardware is expected
to be equal or slower **[H]**. Nothing here claims physical-hardware validation. The word
"hardware" in older project documents (e.g. "real-hardware-validated" in commit messages,
"physical cassette round-trip proven in real Fuse" in `9fc3890`) refers to emulator runs;
Fuse and ZEsarUX are emulators. See §7.

## 1. Baseline re-verification (independent of R10.7 claims)

| Item | R10.7 claim | Re-measured this audit |
|---|---|---|
| HOME ROM free | 546 B | **546 B** (`make budget`: used 15,838 / 16,384) **[M]** |
| EXROM free | 1,385 B | **1,385 B** (used 6,807 / 8,192) **[M]** |
| `make check` | clean | rc 0 **[M]** |
| `make -n test \| grep -ci fuse` | 0 | 0 **[M]** |
| Headless `make test` | smoke 9/9, V2 standalone 38/38, production 19/19, FILL 10/10 | all four reproduced, rc 0 **[M]** |
| Source/array pool | 8,397 B | `PROG_AREA_START=$825A` … `V2_SOURCE_END=$A327` = 8,397 B **[M]** (symbols) |
| Bytecode capacity | 4,011 B | `V2_CODE_BASE=$A455` … `V2_CODE_LIMIT=$B400` = 4,011 B **[M]** |
| Segment 2 | 2,048 B | `$E000–$E7FF` (`ARR2_BASE/ARR2_LIMIT`) **[M]** |
| Legacy Fuse tests | not rerun | **not run** (instruction) |

**What the green suite does and does not cover (important for every finding below).**
`tools/run_v2_standalone_tests.sh` states of itself that its 38 tests "do NOT boot the real
production EXROM build". The 19 production checks (`tools/v2_production_checks.py`) write a
program straight into the line store and call `V2_RUN_STORED`: they bypass the editor, the
keyboard, the command dispatcher, the tape transport, package loading and the display modes.
So the following have **no automated test on the production ROM**: editor key handling
(`EDITOR_LOOP`, `V2_NAV`, `V2_REDRAW`), `SAVE/LOAD/VERIFY` transport, `LOAD … EXT`, array
`LOAD`, `STORAGE_RECEIVE_BLOCK` failure paths (the standalone tests substitute a fake
transport, `STORAGE_TEST_FAKE_*`), BREAK, display-mode return, and the SPRITE/MODE/GRAPHICS
packages (the SPRITE package has no `make test` entry at all: `rom/test_v2_sprite_module.asm`
exists but is absent from `migrated_names`; `rom/test_v2_ext_concurrent.asm` is documented as
excluded and "presumed still correct, not re-verified since" `4ece512`). **[S]**

## 2. Findings register

Severity: **H** high (data loss / silent wrong behaviour / unusable), **M** medium, **L** low.

### 2.1 Proven defects (reproduced in this audit)

| ID | Sev | Finding | Evidence |
|---|---|---|---|
| **D1** | H | **Tape receive failure exits are reported as success.** `STORAGE_RECEIVE_BLOCK` returns *carry clear* on success (final checksum test) but every failure exit ported verbatim from the stock ROM — edge timeout/SPACE abort in `.bits8` (`ret nc`), type-flag mismatch in `.flag` (`ret nz` after `xor`), verify mismatch in `.verify` (`ret nz` after `xor`) — also returns *carry clear*. `STORAGE_LOAD` treats carry clear as success (`.data_recv: call …; jr c,.data_failed`). Only checksum mismatch and entry-retry exhaustion set carry. | **[S]** `kernel/storage/storage.asm` 389–541, 745–747, 889–890. **[M]** (`t9`): injecting a mid-block dropout (20 of 30 bytes outstanding, no tape edges) into the real routine returned carry clear; real `STORAGE_LOAD.data_ok` ran, returned `A=0, DE=30` (the header's declared length), `STORAGE_OP_STATE=4` (LOADED). `V2_LOAD.program_loaded` then sets `PROG_END = PROG_AREA_START + 30`: a program that is 2/3 stale RAM is presented as loaded. SPACE-to-abort during LOAD takes the same exit. |
| **D2** | H | **A failed `VERIFY` erases the in-memory program.** `STORAGE_LOAD.data_failed` reports `STORAGE_LOAD_DATA_TOUCHED ($FF)` whenever the remaining byte count differs from the original — true after a full-length checksum failure even in verify mode, where nothing was written. `V2_LOAD.failed → .program_failed: inc a; … call MEM_INIT_V2` then performs NEW. Separately, because of D1, a verify *content mismatch* is never detected (reports VERIFIED). | **[S]** `rom/exrom_v2_shell.asm` 1204–1230. **[M]** (`t13`): the real handler with `A=$FF`, carry set, `STORAGE_VERIFY_MODE=1`: `PROG_END` `$8272 → $825A` (24-byte program → 0). |
| **D3** | H | **Silent compile truncation.** `COMPILE_STATEMENT_LIST` ends compilation "cleanly" on any token it does not recognise at statement start (`jp .done`, "no error-recovery exists yet"); `.after_stmt` returns when the token after a statement is not `:`; `COMPILE_PROGRAM` never checks that the token stream ended at EOF. Everything after the first unrecognised token is dropped, compile error 0, the program "runs". | **[S]** `rom/exrom_v2_compiler.asm` 4117, 4289–4296, 4320–4331. **[M]** (`t1,t2,t19`), each with a sentinel statement afterwards that never executed: stray `ENDIF`/`ELSE`/`THEN`/`)`/`TO`/`ENDP`; a Spectrum-style leading line number (`10 x = 5` → the **whole program** is dropped); a missing colon (`x = 1 y = 2`); trailing `)`; infix `MOD`/`DIV` (`7 MOD 2` — they are functions `MOD(a,b)`); multi-item `PRINT x; x` / `PRINT x, x`; chained compare `1 < 2 < 3`; `a$(2 TO 3)` slice; `'` comment; embedded `""`. Also accepted silently: unclosed `(`; `FOR` without `NEXT`. |
| **D4** | H | **Compile-error line localisation is wrong.** After a compile error `V2_JUMP_TO_ERROR_LINE` moves the cursor to `CHUNK_CUR_REC_PTR`, "the record most recently appended" to the rolling source window — which runs ahead of the failing token by the lexer's 128-byte look-ahead margin. Introduced by the R10.7 source-staging change; the code comment concedes "close to, not always exactly at". | **[S]** `rom/exrom_v2_shell.asm` 498–562; `include/v2_layout.inc` (`CHUNK_MARGIN`). **[M]** (`t23`), 20-line programs with one `x = )` error: 5-character lines → cursor always on the **last** line (index 19) for an error at index 0, 2, 5, 10 or 19; 25-character lines → error at 2 → lands 7, error at 10 → lands 15; 65-character lines → +2. |
| **D5** | H | **A running program cannot be interrupted.** The VM loop (`VM_RUN`, `rom/exrom_v2_vm_core.asm` 795) never polls the keyboard; `IO_CHECK_BREAK` was deleted as dead code in R10.7 (`kernel/io/io.asm` 650–). Any accidental infinite loop (`top: GOTO top`) requires reset, and `V2_COLD_START` calls `MEM_INIT` so the unsaved program is lost. **D5b:** the BREAK combo itself (CAPS SHIFT+SPACE → `KEY_BREAK = $10`) is not filtered by `EDITOR_LOOP`; it is inserted into the edit line as a control character. | **[S]** grep of `rom/exrom_v2_vm_core.asm` (no `KBD_*`/`BREAK`/`IO_*KEY` poll in dispatch or any back-branch). **[M]** (`t12`): with `KBD_LASTK=$10`, `EDITOR_INSERT_CHAR` is entered with `A=$10`. The infinite-loop hang is **source-level only** (not exercised, to avoid wedging the session). |
| **D6** | H | **`LOAD "f" ARRAY a` cannot deliver data to any program.** The array is allocated at the command prompt; the next `RUN` calls `VM_INIT`, which resets `ARRAYS_END` and `VM_CARVE_TABLES`, which zeroes the whole carved block including the array pointer table. `:` immediate statements recompile (`SYM_RESET`) and re-`VM_INIT` the same way. The documented "write-once" precondition ("array not yet DIM'd this run") makes the situation worse: a program that executes its own `DIM` is rejected (`ARRAY ALREADY SET`), a program that does not has nothing to receive the data. `SAVE … ARRAY` works. | **[S]** `rom/exrom_v2_vm_core.asm` 658–770; `rom/exrom_v2_shell.asm` 1253–1366. **[M]** (`t3`): the real `ARENA_ALLOC_NUMERIC` (exactly what `V2_LOAD_ARRAY` calls) placed a 5-element array (element 2 = 33); an immediately following `V2_RUN_STORED` of the same program gave pointer 0 and runtime error 10. The standalone `array_save_load` test never crosses a `RUN`. |
| **D7** | M | **FILL silently produces incomplete results on dense/noisy regions.** `SHAPES_GFX_FILL_PUSH` drops a seed without any indication once its 1,024-byte stack (512 seeds) is full; seeds are pushed before being painted so duplicates accumulate. The R10.7 claim "exact" holds only for the ten existing fixtures (≤ 384 B). | **[S]** `rom/ext_v2_shapes_module.asm` 272–285, 384–405, 409–505. **[M]** (`fill_adv.py`, independent flood-fill comparison, same harness as `tools/v2_fill_check.py`): ladder 1-px teeth 35,708 px wrong; ladder 2-px 34,928; 10 % random noise 12,899; 25 % noise 16,601; staggered dots 40,768 — **all with stack at 1,024 B**; 40 % noise passes (210 B). No memory is overwritten (the guard works); the fill is simply wrong with no error. |
| **D8** | M | **`CLEAR` (R10.25) is half-implemented and has surprising side effects.** `OP_CLEAR → MEM_CLEAR_V2` resets the array arena and clears package registrations, but leaves the live array pointer table and all scalar/string variables untouched. Arrays remain readable after `CLEAR` while their storage is available for reuse; any package statement after `CLEAR` fails at run time. | **[S]** `rom/exrom_v2_shell.asm` 746–784 (the comment at 740 only justifies *not* zeroing pointers for the edit case). **[M]** (`t22`): `DIM a(5): a(1)=7: s=5: CLEAR: DIM b(5)` → `a(1)` still reads 7 and `s` is still 5; with SHAPES loaded, `CLEAR : CIRCLE 100,90,10` → runtime error 9. |
| **D9** | M | **Edits are silently discarded.** (a) Moving Up/Down (or Delete-line paths) reloads `EDIT_LINE_BUF` from the stored record without committing the typed text. (b) When `ENTER` hits `PROGRAM FULL`, control returns to `.loop`, which re-runs `EDITOR_INIT` and reloads the stored line: the line the user just typed is gone. | **[S]** `rom/exrom_v2_shell.asm` 179–182, 400–478. **[M]** (`t7`): `b = 2` edited to `b = 99999` (uncommitted), `V2_NAV` with `EDIR_UP` → buffer replaced by `a = 1`, stored program unchanged. |
| **D10** | M | **Float formatting truncates instead of rounding.** Fixed 4-decimal output cuts digits: `SIN(30)` → `0.4999`, `COS(60)` → `0.4999`, `0.1 + 0.2` → `0.2999`, `1 / 3 * 3` → `0.9999`, `PI()` → `3.1415`. | **[M]** (screenshot `n1`, rendered by the real ROM). Cause location **[H]**: `BASIC_FLOAT_TO_STRING_EXROM` (`rom/exrom_format.asm`); not traced. |
| **D11** | M | **Silent 16-bit integer wrap.** `30000 * 3` → `24464`; `32767 + 1` → `-32768`; `-32768 - 1` → `32767`; the literal `100000` prints `-31072`. V1 raised `NUMERIC OVERFLOW` for `*` (`docs/CURRENT_LIMITATIONS.md` §5, commit `52467de`); the V2 VM comment at `OP_MUL` records auto-promotion as "deferred". | **[M]** (`t14/n2` screenshots); **[S]** `rom/exrom_v2_vm_core.asm` 2113–2175. Classified as defect (silent wrong result, regression against V1) *and* documented limitation (the deferral is recorded); policy decision needed (§4). |

### 2.2 Credible architectural / integration risks

| ID | Sev | Risk | Evidence |
|---|---|---|---|
| **R1** | H | **The package ABI is "same ROM build", and nothing checks it.** Packages are assembled against `build/v2_crossbank.inc`, which hard-codes ~40 absolute HOME addresses (`EXT2_REGISTER $0FBA`, `VM_CLAMP_Y191 $1D26`, `VM_COMPUTE_PRINT_ATTR $1CF9`, `GFX_*`, `MEM_LINE_*`, `VM_NUM_TO_TEXT`, …) and assembler-computed sysvar addresses (`GFX_FILL_*`, `GFX_CIRCLE_*`, `CURRENT_*`, `EXT_CALL_ARG*`). The only compatibility check is `autostart == V2_PACKAGE_ABI_VERSION (1)`. Any HOME change in R10.9/R10.10 moves these addresses; a previously saved package tape still passes the check and then calls into the wrong code. | **[S]** `build/v2_crossbank.inc`, `tools/write_v2_crossbank.py`, `rom/exrom_v2_shell.asm` 1171–1186, `include/v2_ktab.inc`. The HOME→EXROM direction already has a proper versioned table (`V2_KTAB_*`, 27 entries at `$0040`, magic `$1A`); the package direction does not. Packages touched per module: shapes 10 symbols, sprite 11, printer 13, graphics 8, mode 6 (grep). Not exercised destructively. |
| **R2** | M | **Hidden chunk-6 RAM ownership is implicit.** `$C000–$DFFF` is EXROM while the shell runs and RAM while a package statement runs (`OP_CALL_EXT` pages EXROM out, `rom/exrom_v2_vm_core.asm` 3529–3543). Today only FILL uses it (visited bitmap `$C000–$D7FF`, seed stack `$D800–$DBFF`; `$DC00–$DFFF` unused). Rules that must be written down before freeze are in §6.3. | **[S]** `include/v2_layout.inc` ASSERTs; `include/sysvars.inc` 1524–1556. |
| **R3** | M | **Program tape format is unversioned and un-validated.** SAVE writes the program as header type 0 ("Program", the stock BASIC type) with an uninitialised-by-V2 autostart field; LOAD accepts any type-0 block whose declared length fits (`V2_SOURCE_END−PROG_AREA_START`) and never validates the record chain. A stock Spectrum/TS2068 BASIC tape (or a future V3 format) is accepted and imported as garbage source. `MEM_LINE_NEXT` is bounded by `PROG_END`, so it does not hang; it just yields junk lines. | **[S]** `kernel/storage/storage.asm` 592–655, 831–841; `rom/exrom_v2_shell.asm` 1192–1203. |
| **R4** | M | **The production-ROM test gap (§1).** Editor, keyboard, storage transport, command dispatch, packages and display-mode behaviour are not exercised on the production image. D1, D2, D4, D5, D6, D9 all lived in untested territory. | **[S]** test inventory; **[M]** the defects themselves. |
| **R5** | M | **Legacy V1 regression risk is unquantified.** See §6.7. | |
| **R6** | M | **Timing numbers are uncontended emulator T-states.** Physical redraw latency, key-drop rate and tape timing are unverified. | §7. |
| **R7** | L | **Compile cost grows super-linearly with symbol count.** `SYM_FIND` scans the whole tagged table linearly for every identifier reference. Typical code compiles at ~2.2 k T/source byte (94 B → 0.23 M T; 1,880 B → 4.2 M T ≈ 1.2 s); a 4.4 KB / 50-variable program took 20.5 M T ≈ **5.8 s** (4.7 k T/byte). A full 8 KB program with many variables may take well over 10 s with no progress indication and (D5) no abort. | **[M]** (`t10`); 150/250-variable runs were not completed (test program overran the pool). |
| **R8** | L | **Ambiguous memory messages.** Compile codes {5,6,45,55,62} and run code 64 all display `OUT OF MEMORY` although they mean different resources (bytecode vs symbol arena vs array arena vs control stack). | **[S]** `rom/exrom_v2_shell.asm` 619–652. |
| **R9** | L | **Cursor can disappear on long wrapped lines near the bottom of the screen** (active line starts at row 20 once the view scrolls; rows ≥ 23 are not drawn and the cursor is suppressed). | **[S]** `rom/exrom_v2_shell.asm` 1800–1808. Needs a ≥ 97-character line to trigger; not exercised. |

### 2.3 Documented design limitations (not defects)

| ID | Limitation | Source |
|---|---|---|
| L1 | `IF cond THEN <stmt>` on one line is **not** a statement: after `THEN` (other than `GOTO label`) the parser always enters a block IF requiring `ENDIF` (`IF x=1 THEN y=2` alone → compile error 9). `ELSEIF` is not a keyword; `ELSE IF … ENDIF ENDIF` works. | `rom/exrom_v2_compiler.asm` 3573–3640 **[S]**, `t18/t11` **[M]** |
| L2 | `PROC name(p):` and `DEF FN` take exactly one parameter; `PROC` has no return value; `PRINT`/`LPRINT` take one argument; `INPUT` takes one variable and no prompt (compile error 43 for `INPUT "N"; n`). | compiler **[S]**, `t18` **[M]** |
| L3 | Strings are fixed 31-character records (4-byte header folded into 32 B slots); identifiers 31 significant characters (error 61 beyond). | `include/v2_layout.inc` **[D]** |
| L4 | 255 symbols per kind (§6.4); bytecode capacity 4,011 B; source/array pool 8,397 B shared with the run tables; segment 2 holds whole arrays only (2,048 B). | R10.7 progress doc **[D]**, symbols **[M]** |
| L5 | FOR variables are not recursion-local (frame saves only the enclosing loop's limit/step). | R10.7 progress doc **[D]** |
| L6 | `INT()` truncates toward zero (`INT(-3.5)` → `-3`; stock BASIC floors to `-4`). `MOD(-7,3)` → `-1`, `DIV(-7,2)` → `-3`. | `n1` screenshot **[M]** |
| L7 | One package resident at a time (single 1 KB window at `$F400`; `LOAD … EXT` clears the registry first). The shapes+sprite combination cannot be used in one program. | R9 ledger, README **[D]**; `OP_CALL_EXT` **[S]** |
| L8 | Variables are discarded and re-zeroed on every `RUN` and every immediate (`:`) statement; there is no way to inspect variables after a stop or error. `STOP` is `END`. | `VM_INIT/VM_CARVE_TABLES`, `V2_RUN_IMMEDIATE` **[S]** |
| L9 | Absent by design/decision: `GOSUB/RETURN` (replaced by `PROC/CALL`), `DATA/READ/RESTORE`, `MERGE`, `STICK()` (removed R10.7 as dead code), `INSTR`, `DRAW`, `IN`/`OUT` statements, `VAL$`, `SCREEN$`, `ASN/ACS/ATN/EXP/LN`, multi-dimensional arrays (`DIM a(3,3)` → error 37), run-time `DIM a(n)` (error 34). | `docs/R10_STOCK_TS2068_CAPABILITY_MATRIX.md` (partly stale — see matrix), `t11` **[M]** |
| L10 | The decompiler is **test-only** (not in the production image); its 31-character fragment limit (error 4) affects no user workflow. | `rom/v2_home.asm`/`v2_exrom.asm` include lists **[S]**; R10.7 progress doc **[D]** |

### 2.4 Untested behaviour (no automated or manual evidence)

SPRITE/GRAPHICS/PRINTER packages on the production ROM *via tape*; `LOAD … EXT` and
`SAVE … EXT` end to end; the entire editor key path; auto-repeat/typeahead; display-mode
persistence for `MODE 1` beyond the single screenshot in §5; `ULAPLUS`/`PALETTE`; AY sound
(`SOUND`/`BEEP` compile and run without error — `t18` **[M]** — but output was not heard);
printer output; `INPUT` runtime behaviour; `AT`, `TAB`, `CLEAR` (no test references
`TOK_KW_AT`, `TOK_KW_TAB` or `OP_CLEAR` in `rom/test_v2_*.asm` or the production checks);
the 7-package matrix of `NEW`/`CLEAR`/`LOAD` against registry state.

### 2.5 Optional enhancements (collected; costed in the plan)

Free-memory readout in the status line; error code/name in messages; `SYMBOL SHIFT+SPACE` run
key; word-wise cursor movement; block copy/move; search; undo of last line; startup chime
(already present); `LIST` page-scroll; printing `LINE n/m` plus error counts as in V1.

## 3. End-to-end workflow traces

Each trace lists where individually working parts combine badly.

### 3.1 Enter → edit → RUN → fix an error → RUN again

1. Typing is accepted at ≈ 0.3–0.6 s per character on a populated screen (§5) with a single-slot
   key latch (`KBD_LASTK`/`KBD_KEYHIT`): keys arriving during a redraw overwrite each other.
   **[S]+[M]**.
2. `RUN` is only recognised when the cursor is on the empty end-of-program sentinel
   (`V2_COMMAND_LOOP` 140–146: `CUR_EDIT_POS == $FFxx` → `V2_DISPATCH`; otherwise the typed text is
   stored as a program line). **Typing `RUN` anywhere else overwrites that line with the text
   `RUN`.** **[S]**
3. Compile error → message `SYNTAX ERROR` (every code 2–59 shows this text; no code, no
   position) and the cursor jumps to a line that is usually wrong (D4). **[M]**
4. After correcting the line the user must navigate to the last line one keystroke at a time,
   at the redraw rate, before `RUN` is recognised again: for a 200-line program ≈ 120 s
   (200 × 0.6 s). **[M]**+arithmetic
5. A silent truncation (D3) produces no error at all: the program runs without the dropped
   lines.

### 3.2 LOAD from cassette → modify → SAVE → reload

`LOAD "name"` (typed on the sentinel line) is the only entry; a failed header search gives a
clean `LOAD FAILED` with the old program intact, but any failure after the first data byte,
**including SPACE-abort and tape dropout, is reported as `LOADED` (D1)**; a genuine checksum
failure erases the program (by design: "touched") while VERIFY failure also erases it (D2).
`SAVE` stores `PROG_AREA_START..PROG_END`; programs are position-independent text, so they
survive the R10.7 pool move **[S]**. The saved header type is the stock "Program" type (R3).
Neither SAVE nor LOAD give progress feedback in production: `STORAGE_PROGRESS_HOOK` is never
set (`docs/R9_HANDOFF.md`, "Correction"), so a long LOAD shows only border flicker.

### 3.3 Large arrays, many variables, nested loops, recursion

Works and is production-tested: 150-deep parameter recursion, 3-level nested FOR, 253 numeric
variables, `DIM a(3300)`, segment-2 placement, `OUT OF MEMORY`/`STACK OVERFLOW` as clean
errors (`make test` production checks 19/19 **[M]**). Combinations that are fragile:
(i) `RUN` refuses ("OUT OF MEMORY") when source plus run tables leave < ~110 B of pool even
though the editor accepted the last line — the user finds out only at RUN **[D+S]**; (ii) the
message does not say which resource ran out (R8); (iii) arrays are lost on every edit
(`V2_CLEAR_ARRAYS` after each stored line) so an array computed by one run cannot be saved
after touching the source **[S]**; (iv) D6.

### 3.4 Graphics, sprites, sound, packages

Measured on the production ROM with the package image injected at `$F400` and registered
through the real entry (not via tape): SHAPES — `CIRCLE 128,96,40` + `FILL 128,96` gave a filled
disc (centre pixel byte `$FF`) **[M]**; SPRITE — `GRAB 0,0,0,1,1 / SHOW / MOVE / HIDE` ran with no
error, `SHOW` without `GRAB` → runtime error 17, slot 9 → error 15 (the shell prints the same
`RUNTIME ERROR` for all package errors) **[M]**; MODE — `MODE 1` ran, and **the editor then
comes back garbled** (§5, screenshot `mode1_editor`: overlapping glyph rows, no attribute bar)
because nothing resets the video mode on return **[M]**. A program using SPRITE and CIRCLE/FILL
cannot exist (L7). Colour/attribute state (`INK/PAPER/FLASH/OVER/INVERSE/BRIGHT`) also leaks
from one RUN into the next (§5, `t7`) — consistent with stock BASIC's permanent attributes but
surprising for a "RUN starts clean" expectation **[M]**.

### 3.5 Recovery paths

| Situation | Behaviour | Class |
|---|---|---|
| Syntax error | message, wrong line (D4) | defect |
| Runtime error | `RUNTIME ERROR` / `STACK OVERFLOW` / `OUT OF MEMORY`, key to dismiss, **no line, no code** | usability |
| Memory exhaustion (source) | `PROGRAM FULL`, typed line lost (D9b) | defect |
| Memory exhaustion (run) | `OUT OF MEMORY` clean; source intact | OK **[M]** |
| Interrupted operation | no BREAK in RUN (D5); SPACE aborts tape but is mis-reported (D1) | defect |
| Failed LOAD | clean when header search fails; otherwise D1/D2 | defect |

## 4. Architecture and correctness audit

### 4.1 Compiler / VM / editor agreement

The editor stores plain text; `RUN` re-compiles from the line store every time via the rolling
chunk window, so the editor, compiler and VM share no state except line records and error
position. The agreement defects are in the *error back-channel* (D4) and in *recovery of state*
(D6, D8). The compiler↔VM contract (opcode numbering, operand widths) is exercised by 38
standalone + 19 production tests; the three built-in tables (compiler/VM/decompiler) are
statically checked by `tools/check_builtin_tables.py` (not reopened).

### 4.2 Dynamic tables and the unified control stack

`VM_CARVE_TABLES` sizes five tables from compile counts and zeroes the block; `VM_CS_ALLOC`
bounds the stack against `ARRAYS_END`. Production tests cover 150-deep recursion, stack-into-
arrays and arrays-into-stack error paths, and `DIM` under recursion **[M]**. Remaining risk is
semantic (D6, D8), not allocation safety. The machine (Z80) stack is separate and bounded by
`COMPILE_STACK_CHECK` only for the compiler **[D]**; runtime Z80-stack use is bounded by the
VM design (iterative dispatch) **[S]**.

### 4.3 Array allocation, lifetime, segment 2

Lifetime rules as implemented **[S]**: arrays live from their `OP_DIM` to the next `RUN`/edit/`NEW`/
`CLEAR`; `VM_INIT` empties segment 2 (`ARR2_END = $E000`); every stored line, `LOAD`, `NEW` calls
`V2_CLEAR_ARRAYS`. Allocation prefers the main pool and falls back to segment 2 via the
`ARRAYS_END/ARR2_END` swap (`VM_ARENA_FIT/VM_ARENA_DONE`). Production tests (`seg2-*`, 7 cases)
cover placement, reset, exhaustion, `FREE(1)`.

### 4.4 Symbol limits (follow-up D)

| Documented limit | Mechanism | Verified |
|---|---|---|
| 253 numeric scalars | `SYM_CAPS`: `255 − FLOATTAB_TEMP_COUNT (2) = 253`; creating the 254th → compile error 1 (`TOO MANY VARIABLES`). The two float temp slots sit at indices N, N+1, so the largest slot index in use is 254 (one-byte operand, 255 unused). | production `253-vars`/`254-vars` **[M]** |
| 253 string scalars | `255 − STRTAB_TEMP_COUNT (2) = 253`, same scheme; each costs 32 B, so memory (not the operand) binds first: 253 × 32 = 8,096 B ≈ the entire pool. | cap **[S]**; 61 strings + 202 numerics ran **[D]** |
| 255 numeric arrays / 255 string arrays | no temps: cap 255, error 39 when about to create index 255 (indices 0–254). | **[S]** |
| labels, PROCs, DEF FNs, forward refs, EXIT FOR | uncapped; records in the symbol arena | label test **[M]** |

So the documentation is internally consistent: 253/253/255/255 follow from a one-byte operand
(256 values) minus the reserved temp slots; index 255 is never assigned. (A FOR loop variable
counts as a numeric symbol.)

### 4.5 Extension ABI and package lifecycle (follow-up C)

**Lifecycle (source-level, plus the measurements in §3.4):**

| Event | Registry (`EXT2_TABLE`, 12 slots) | Window `$F400` / `V2_PACKAGE_LEN` | Source: |
|---|---|---|---|
| Cold boot | cleared (`EXT2_CLEAR_ALL`) | empty | `V2_COLD_START` |
| `LOAD "x" EXT` | cleared, then package entry registers names | replaced | `V2_LOAD` 1149–1186 |
| failed/invalid package load | cleared | length 0 | `V2_LOAD` 1186–1213 |
| program `LOAD` | **kept** (package survives; good) | kept | `.program_loaded` |
| `NEW` | cleared | length 0 | `MEM_INIT_V2` |
| `CLEAR` statement | cleared (surprising, D8) | length 0 | `MEM_CLEAR_V2` |
| edit / RUN | kept | kept | — |

Each registry record carries a generation byte; `OP_CALL_EXT` compares it against the compiled
operand and raises `VM_ERR_EXTENSION_NOT_FOUND` on mismatch **[S]** (observed as runtime error 9 after
`CLEAR` **[M]**). That mechanism is sound; it is the *package binary → ROM* binding that is not (R1).

**Secondary-segment arrays across extension calls and bank switches — measured (`t25`).** With a
2,003-byte array in segment 2 ending at `$E7D3` (`b(999)=4242, b(0)=17`), (a) a program running
`CIRCLE` + two `FILL`s (EXROM paged out, chunk 6 used as scratch) and (b) a program running
`GRAB/SHOW/MOVE/HIDE` both left the descriptor `01 E8 03`, `b(999)=4242`, `b(0)=17`
and `ARR2_END=$E7D3` intact, and both read back the expected sum 4259 **[M]**. This follows from
the layout: segment 2 is `$E000–$E7FF`, in the always-visible chunk 7; chunk 6 (`$C000–$DFFF`) is
the only banked chunk; sprites start at `$E800` (`ASSERT ARR2_LIMIT <= SPRITE_SLOT_IMG_BUF`).

### 4.6 Hidden chunk-6 RAM ownership rules (to be recorded)

1. `$C000–$DFFF` is EXROM whenever the shell, compiler, VM, or any non-package service is
   running (`BANK_EXROM_DEPTH ≥ 1`), and RAM only inside an `OP_CALL_EXT` call (and standalone
   test harnesses).
2. Therefore **nothing persistent may live in `$C000–$DFFF`**; contents are undefined between
   statements. Current user: FILL (`$C000–$D7FF` visited bitmap, `$D800–$DBFF` stack). `$DC00–$DFFF`
   (1,024 B) is unused.
3. A package must not call any routine that pages EXROM in (BANK depth is a nesting counter,
   not a mode flag; a nested `BANK_PAGE_EXROM_IN` inside a package call would hide the scratch it
   is working in).
4. Interrupts stay enabled while chunk 6 is RAM; the ISR (`KBD_ISR_TICK`) touches only chunk-4
   sysvars and the machine stack (chunk 7), so this is safe today **[S]**; any future ISR work that
   touches chunk 6 must re-derive this (the `kernel/bank/bank.asm` header already says so).
5. Anything that wants *persistent* hidden storage would have to be a new, explicit allocation
   with its own page-in/out discipline; this is exactly what R10.7's P5.3 rejected for sprites.

### 4.7 ABI assumptions to make explicit before R11 (follow-up C, continued)

* **A1 Package binding (R1).** Either (a) a fixed package-service jump table in the free KTAB
  padding (`$0091–$00FF`, 111 B = 37 more 3-byte entries; zero HOME code cost) plus packages
  referencing only table slots and a fixed sysvar block, or (b) a ROM build signature in the
  package header that LOAD checks. (a) removes the problem; (b) merely detects it.
* **A2 Package sysvar contract.** Packages use `EXT_CALL_ARG0..4`, `VM_ERROR_CODE`, `VM_HALTED`,
  `CURRENT_*`, `GFX_FILL_*`, `GFX_CIRCLE_*`, `SPRITE_*`. Each must be declared part of the ABI or
  copied into a packed `PKG_ABI` block; today they move whenever `include/sysvars.inc` changes
  (the R10.7 compaction moved all of them).
* **A3 Error reporting.** Packages report errors by writing `VM_ERROR_CODE/VM_HALTED` directly
  (`MODE_RAISE`); `OP_CALL_EXT` ignores the return status. That is a de-facto ABI (and
  package error codes 12–17 overlap VM codes): define it or switch to a return code.
* **A4 Register/clobber contract** for `EXEC` entries (what a package may destroy) is undocumented
  in code; `VM_CALL_INDIRECT` assumes nothing is preserved.
* **A5 Argument model:** five 16-bit slots (four contiguous + `EXT_CALL_ARG4`), per-position
  numeric/string flag; no variable-length or result-returning calls (no extension *functions*).
* **A6 Chunk-6 rules** (§4.6) and the one-package window size (1 KB at `$F400`; the shapes package
  uses 795 B, 229 B spare).
* **A7 File formats that freeze with R11:** program tape (type 0, text records — R3),
  extension tape (`STORAGE_EXTENSION_TYPE`, ABI in the autostart field), array tape
  (`STORAGE_ARRAY_TYPE = 8`, descriptor-verbatim; D6 shows the *semantics* are not settled).

### 4.8 State retained or cleared between runs

| State | Cleared by RUN? | Evidence |
|---|---|---|
| Scalars, strings, arrays, array pointers, control stack | yes (carved and zeroed) | `VM_INIT/VM_CARVE_TABLES` **[S]** |
| Segment 2 | yes | `VM_INIT` **[S]** |
| Compile symbol table | yes (reset each compile), kept after the run for `SAVE … ARRAY` | `COMPILER_INIT/SYM_RESET` **[S]** |
| `CURRENT_INK/PAPER/FLASH/OVER/INVERSE/BRIGHT` | **no** | `t7`: all six still set after a second run **[M]** |
| `BORDER`, video mode (`MODE`), `PORT_FF_SHADOW` | **no** (reset only in `V2_COMMAND_LOOP`'s one-time head) | `t20`, `V2_COMMAND_LOOP` **[S/M]** |
| `VM_OUTPUT_ROW/COL` (print cursor) | yes | `VM_INIT` **[S]** |
| Extension registry/window | no | §4.5 |
| Sprite slots/buffers | no | `$E800–$F0FF` persistent **[D]** |
| RNG seed | no (`RANDOMISE`) | **[H]** |

### 4.9 Remaining fixed limits and consequences

Line length 127 B (`EDIT_LINE_BUF_LEN 128`); 8 wrap rows (`WRAP_MAX_ROWS`) so ≤ 8×32 shown;
keyword-bold spans per line `KW_SPAN_MAX = 8` (cosmetic); status buffer 20 B; 12 extension slots;
8 sprite slots; PRINT buffer; FILL stack 512 seeds (D7); bytecode 4,011 B; pool 8,397 B; segment 2
2,048 B; compile/run zone 302 B; machine-stack headroom `$F800–$FEFF` 1,792 B.

## 5. Editor-related measurements (details in the editor audit)

| Quantity | Value | Class |
|---|---|---|
| `V2_REDRAW`, 10 populated lines | 1,015,817 T (288 ms @ 3.528 MHz) | **[M]** |
| `V2_REDRAW`, ≥ 30 lines (screen full) | 1.92–2.11 M T (545–599 ms), nearly independent of program length (viewport is 23 rows) | **[M]** |
| per settled line: keyword scan / draw / wrap | 25,550 / 39,696 / 4,319 T | **[M]** |
| `GFX_CLS` / `V2_DRAW_STATUS` | 193,853 / 48,194 T | **[M]** |
| `V2_COUNT_LINES` | 2.4 k T @ 10 lines … 93 k T @ 400 lines (13.5 ms @ 200) | **[M]** |
| `V2_SET_EDIT_FROM_INDEX` (walks the line chain) | 3.6 k T @ index 5 … 123 k T @ index 399 (35 ms) | **[M]** |
| Key path | ISR scan 60 Hz, debounce 2 ticks, one latched key (`KBD_LASTK`+`KBD_KEYHIT`), repeat 35 ticks then every 5 | **[S]** `kernel/interrupt/interrupt.asm`; real-hardware feedback quoted in its header |

## 6. Required R10.7 follow-up investigations — answers

### 6.A Array SAVE/LOAD (secondary segment, pool exhaustion)

* **SAVE from segment 2 works.** `V2_SAVE_ARRAY` serialises "from the descriptor wherever it
  lives". Measured: `DIM a(3600) : DIM b(900)`, `SAVE "X" ARRAY b` → `STORAGE_SAVE` entered with
  `IX=$E000`, `DE=1803` (= 3 + 900×2), `B=1`; descriptor bytes `01 84 03`; element 5 = 123 **[M]**
  (`t4`; the tape transmission itself was not run).
* **LOAD always receives into the main pool** and caps the accepted length at
  `VARS_START − ARRAYS_END − 1` so the allocator can never relocate the received block to segment 2
  (`V2_LOAD_ARRAY` 1317–1331). If the saved array does not fit, `STORAGE_LOAD`'s header length check
  (`.name_ok`, 831–841) fails *before any byte is written* → clean `LOAD FAILED` with no state change
  **[S]**. A 2,048-byte segment-2 array reloads fine when the main pool has room.
  → *Intentional limitation*, but the message is non-specific.
* **Genuine defect:** the loaded array cannot be used (D6). Also affected by D1 (a truncated array
  transfer is accepted; the received header is trusted for the count).
* Assessment: SAVE is sound; LOAD is a **non-functional feature end to end**. Decision needed before the
  tape format is frozen (plan item M-5).

### 6.B FILL stack safety

* **No provable upper bound.** Each painted span pushes one seed per fillable run in each adjacent
  row, and seeds are not marked visited when pushed, so the same run can be pushed repeatedly by
  different spans. Pending seeds are bounded only by the number of runs on the screen
  (≤ ~24 k), not by 512. The 1,024-byte reservation is ≥ 2.6× the worst *fixture*, not the worst case.
* **The guard is effective against corruption but not against wrong output.** `SHAPES_GFX_FILL_PUSH`
  refuses to write past `GFX_FILL_STACK_END` (no overwrite of `$DC00+`, nothing else in RAM is at
  risk); `POP` refuses below the base. The consequence of a full stack is a silently incomplete fill (D7).
* **Adversarial results (§2.1 D7):** five of six new patterns fail; all saturate the stack.
* **Smallest credible correction (not implemented):** set an overflow flag in `PUSH` when a seed is
  dropped; when the stack empties with the flag set, rescan the visited bitmap for any painted pixel
  with an unpainted fillable neighbour, push it, clear the flag, repeat until a pass paints nothing.
  Terminates (each pass paints ≥ 1 pixel), needs no extra RAM, is **package-only** (0 B HOME/EXROM) and
  is **[E] +60–100 B** in a package with 229 B of spare room (795/1,024 B). Enlarging the stack into
  `$DC00–$DFFF` (+1 KB) only moves the threshold. Validation: add the six adversarial scenarios
  to `tools/v2_fill_check.py` with the same independent flood-fill oracle.

### 6.C Extension and banking interactions

Answered in §4.5–§4.7. Summary: segment-2 data is intact across extension calls and chunk-6
paging **[M]**; ownership rules recorded; the unresolved ABI items are A1–A7.

### 6.D Symbol limits

Answered in §4.4.

### 6.E Decompiler limitations

* **31-character fragment limit** (`DECOMP_FRAG_TEXT_MAX = 31`, `rom/exrom_v2_decompiler.asm`): clean
  DECOMP error 4. The decompiler is **not in the production image** (verified in the production
  roots `rom/v2_home.asm`, `rom/v2_exrom.asm`, which include neither `exrom_v2_decompiler.asm`
  nor its tables) **[S]**; `LIST` shows stored text; `LLIST` is source-based. **No user workflow is affected.**
* **Fix before R11?** No. It only matters if R11 chooses "LIST from bytecode". Minimal correction cost
  **[E]**: widen the 8 fragment slots from 32 to 64 B (`$BB00` region 256 B → 512 B, relocating
  `DECOMP_OUT_BUF` `$BC00`), ~15 B of code in the *test harness* EXROM which is itself size-limited
  ("the calculator and decompiler do not fit together in the harness EXROM"). DEFER.
* **Recorded as required:** float-function round trips (`SQR PI RAD DEG SIN COS TAN`) establish
  **bytecode equivalence only**; their runtime behaviour is covered by `r10_numeric` and the
  production checks, separately. `FREE()` equivalence needs equal-length names.
* New in this audit: float *display* is not covered by any equivalence test and has the
  truncation defect D10.

### 6.F Physical hardware qualification (follow-up F)

Not verifiable headless and with **no physical evidence in the repository**:

| Area | What must be checked on a real TS2068 |
|---|---|
| Cassette | SAVE→LOAD round trip with the production ROM; LOAD with dropouts, SPACE abort (D1); VERIFY; array and extension tapes; leader/sync thresholds (`STORAGE_LEADER_GAP $A0` was calibrated against emulator signal, not analogue tape); behaviour with real recorders at several levels |
| Keyboard | debounce 2 ticks and auto-repeat feel; single-slot key loss during the 0.3–0.6 s redraw (U1 in the editor audit); CAPS SHIFT duplicate keycap behaviour; chord ergonomics of any new key set; BREAK keycap (hardware notes: matrix position unconfirmed) |
| Display/editor | flicker on full-screen `CLS`+redraw each keystroke (not measurable in emulator); attribute bar; hi-res mode return (§5); contention-inflated redraw time |
| Memory/banking | `OUT $F4/$FF` EXROM/Home paging of chunk 6 on real hardware with a Timex dock/EXROM present; interrupt safety while chunk 6 is RAM (FILL); stack headroom |
| Graphics/ULAplus | `MODE 1`, `ULAPLUS`, `PALETTE` on a machine/board that supports them; FILL/CIRCLE speed |
| Sound | AY-3-8912 register writes (`SOUND`), boot chime audibility, `BEEP` |
| Joystick | not implemented (L9) |
| Printer | `LPRINT`/`LLIST` on a real printer interface |
| Packages | package tape load timing at the 1 KB window |

### 6.G Legacy V1 validation (follow-up G)

* **What changed.** R10.7 wrapped 113 dead V1 sysvar `DEFS` in `IFNDEF V2_COMPACT_SYSVARS`
  (legacy builds do not define it, so the legacy layout is textually unchanged), moved
  `STICK_READ/IO_ANY_KEY_DOWN/IO_CHECK_BREAK/MEM_LABEL_*` into `basic/legacy_kernel_compat.asm`,
  and edited shared kernel modules (`graphics.asm` FILL stack conditional, `GFX_SET_ATTR`/
  `GFX_CLEAR_ROW_TEXT` KTAB exposure, memory/line-store helpers, bank helpers).
* **Evidence available:** `make check` assembles the legacy chain (incl. `-DEDITOR_TEST_EXROM
  rom/exrom_build.asm`, `rom/test_editor_auto.asm`); smoke ROMs 9/9; z80sim source-level
  tests pass. **Evidence missing:** every V1 behavioural test (`make test-legacy`: Fuse
  editor-auto and storage-named-load families) was last run before sysvar compaction.
* **Risk assessment [H]:** low–medium. The legacy layout is assembler-computed from unchanged text,
  so layout regressions are unlikely; the realistic risk is behaviour of *shared* kernel code that
  V2 modified. V1 is not the production target.
* **Recommended strategy:** (1) **Decide whether V1 remains a supported product.** If not, record it
  as "assembles only", stop gating on it, and note this in `TESTING.md`. (2) If yes: run
  `make test-legacy` **once** under the user's explicit authorisation after R10.10 closes (not now),
  and (3) optionally port two or three V1 fixtures (`tests/*.txt` editor/storage cases) to the
  headless `ts2068-debug` `type` driver to remove the Fuse/X11 dependency. Cost **[E]**: (3) is
  roughly a day of tooling; ROM cost zero.

## 7. Items that look like defects but are not (to avoid re-opening)

* A package/array silently surviving a RUN is **not** expected; D6 is a feature gap, not a corruption.
* `VM_CARVE_TABLES` zeroing arrays is correct for ordinary programs.
* Segment-2 allocation swap (`VM_ARENA_FIT/VM_ARENA_DONE`) held in every test; no defect found.
* The compile symbol table living at `PROG_END` and surviving a RUN is intentional (`SAVE … ARRAY`).
* The unified control stack/`VM_CS_UNWIND` behaved correctly in all production checks.
* The decompiler built-in tables were **not** reopened (instruction).

## Appendix A — Reproduction recipes

All probes use `tools/v2_headless.py`-style helpers (copied to a scratch directory so the repo
is untouched) with an **isolated session**: `TS2068_DEBUG_STATE_DIR=/tmp/ts2068-r108` and
`ts2068-debug start --port 10077`, so they cannot collide with `make test`. Programs are written
directly into the line store (`PROG_AREA_START`, `PROG_END`, `ARRAYS_END`), then
`PC=V2_RUN_STORED` with `SP=$FF00` and a return address of `V2_COMMAND_LOOP.loop`, run to
`IO_READ_KEY`. Screenshots need ~3 M extra instructions after the stop before `screenshot`, because
ZEsarUX renders from the last completed frame.

| Probe | Recipe (condensed) |
|---|---|
| D1 | `start()`; header length at `STORAGE_HEADER_BUF+11 = 30`; stack (low→high) = `[STORAGE_RECEIVE_BLOCK.exit][addr after the call in STORAGE_LOAD.data_recv][30][dest][$FE00]`; `IX=dest+10, DE=20, BC=$B0xx, HL=1, AF=$FF00`; `PC=STORAGE_RECEIVE_BLOCK.bits8`; run to `$FE00` (`jr $`); read A/F/DE/`STORAGE_OP_STATE`. Result: `A=0 F=carry-clear DE=$1E state=4`. |
| D2 | program in store; `STORAGE_VERIFY_MODE=1`, `V2_REQUEST_TYPE=0`; `AF=$FF01`; `PC=V2_LOAD.failed`; read `PROG_END`. |
| D3 | `["x = 1","ENDIF","y = 2"]` etc.; read `x`,`y` via `RT_SYMTAB_PTR`; with a final `zz = 99` sentinel to detect truncation. |
| D4 | 20 lines `x = 1` with `x = )` at index *k*; read `CUR_EDIT_INDEX` at the `IO_READ_KEY` stop. |
| D6 | run `["GOTO s","DIM a(5)","s:","y = a(2)"]`; write `[1][5,0][5 words]` at `ARRAYS_END`, `VM_CSP=VARS_START`; call `ARENA_ALLOC_NUMERIC` with `A=0, DE=5`; read element; run `V2_RUN_STORED` again. |
| D7 | `tools/v2_fill_check.py` with additional scenarios (ladder, random-noise 10/25/40 %, staggered dots) and the same independent flood fill. |
| D8 | `["DIM a(5)","a(1) = 7","s = 5","CLEAR","DIM b(5)","b(1) = 9","x = a(1)","y = s"]`. |
| D9 | `V2_NAV` with `A=EDIR_UP (0)` after overwriting `EDIT_LINE_BUF`. |
| Timing | ZRCP `reset-tstates-partial` / `get-tstates-partial` around `PC=V2_REDRAW` etc. (return address `$FE00` = `jr $`). |
| Seg-2 vs. packages | install `build/v2_package_<name>.bin` at `$F400`, `PC=$F400`, run to the trap, then `V2_RUN_STORED`. |
