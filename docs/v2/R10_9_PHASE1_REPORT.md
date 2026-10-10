# R10.9 Phase 1 — Regression infrastructure and package-ABI foundation

**Status:** implemented in the working tree on top of `f0cd550` (R10.7 code `6151b64` + the R10.8 audit
documents); **nothing is committed**. Phase 2, R10.10 and R11 have not been started. Evidence tags:
**[M]** measured in this work on the production ROM or by `make`; **[S]** source reading; **[E]**
estimate.

Companion documents: [`PACKAGE_ABI.md`](PACKAGE_ABI.md) (the ABI contract),
[`R10_9_WORK_SEQUENCE.md`](R10_9_WORK_SEQUENCE.md) (updated sequence), [`TESTING.md`](TESTING.md).

## 1. Summary

* **Task A.** Two new production-ROM suites (≈ 100 cases) plus a tape synthesiser. They drive the
  *real* HOME+EXROM image: the editor through the ISR key latch, the command dispatcher, compiler,
  VM, the real tape receiver fed a synthesised EAR stream, and the real package entry. All ten
  R10.8 defects in scope (D1–D9, D11) and U6 are reproduced as strict expected failures on the
  **unmodified** ROM (53 XFAIL, 0 unexpected results). The gate suite has no known failures.
* **Task B.** Complete inventory of the package-visible interface. It confirmed the plan's 16
  services exactly, but found four things the plan had not: a banking defect that made
  `LPRINT <number>` execute stray RAM (**ABI-F1**), HOME code writing package-owned sprite state
  (**ABI-F2**), un-asserted literal addresses in the SPRITE package (**ABI-F3**), and the need to
  pin sprite/FILL memory-map constants.
* **Task C.** Package ABI 2.0 implemented: a 16-slot service table in the unused KTAB padding,
  34 pinned RAM cells and 11 constants asserted by the HOME build, versioned tape headers for
  programs, packages and arrays checked **before any byte is stored**, a clean `BAD TAPE VERSION`
  failure, and an automated drift checker in `make check`. **HOME cost 0 bytes; EXROM cost 45
  bytes; RAM cost 0; package sizes unchanged.** No blocker was met; nothing had to be forced.
* Both open owner decisions are resolved (§9, §10a).

## 2. Task A — production-ROM regression coverage

### 2.1 What was built

| File | Role |
|---|---|
| `tools/tape_synth.py` | builds EAR-line streams with the project's own block framing and pulse widths (`make_extension_tzx.py`), with fault injection: dropout, truncation, wrong flag byte, bad checksum, arbitrary header words; writes ZEsarUX "real tape" RWA files |
| `tools/v2_prod.py` | harness: boot, key injection, tape insertion, call/run helpers, message capture (`V2_SHOW_MESSAGE` break), SPACE-abort injection, state readers, strict xfail runner |
| `tools/v2_prod_regress.py` | **gate suite** — every case must PASS |
| `tools/v2_known_defects.py` | **known-defect suite** — correct-behaviour assertions; `xfail=` marks the documented defects |
| `tools/run_v2_prod_tests.sh` | runs both concurrently on separate ZEsarUX ports; part of `make test`, also `make test-prod` |
| `tools/v2_abi.py`, `tools/check_package_abi.py` | ABI reader and static drift checker (Task C) |
| `tools/v2_fill_check.py` | made importable (`main()` guard); its own 10-scenario gate is unchanged |
| `tools/v2_headless.py` | one backward-compatible addition: `TS2068_V2_PORT` lets two sessions run side by side |

### 2.2 What is real and what is substituted

**Real, unmodified production code:** ISR key latch → `IO_READ_KEY` → editor → `V2_COMMAND_LOOP` →
`V2_DISPATCH`; compiler; VM; `STORAGE_LOAD`/`STORAGE_RECEIVE_BLOCK` reading the EAR line through
port `$FE`; `V2_SAVE`/`STORAGE_SAVE` up to the transport call; `V2_LOAD`/`V2_VERIFY`; package
install call; `OP_CALL_EXT` with EXROM paged out; the HOME service routines.

**Substituted (all listed in `TESTING.md`):** the EAR signal is a synthesised pulse train, sampled
at ZEsarUX's 15,600 Hz RWA rate (edges quantised by up to ±226 T) rather than analogue cassette audio;
SAVE's *output pulses* are not generated — `STORAGE_SEND_BLOCK` is intercepted at its call site and
its arguments recorded; the SPACE press is injected as one forced `in a,($FE)` result; keys are poked
into the latch instead of scanned from the matrix; packages are mostly installed by copying the image
to `$F400` and calling the real entry (the tape path has its own `abi-pkg-*` cases); some cases call
`V2_RUN_STORED`/`V2_DISPATCH` directly instead of typing the command. **These are not the standalone
component harnesses** (`rom/test_v2_*.asm`, which substitute fake storage/EXROM services and are
unchanged): no HOME or EXROM code is replaced in the new suites.

### 2.3 Defects reproduced (baseline = unmodified ROM, `f0cd550`) [M]

Run on a clean `git worktree` of `f0cd550` with only the new test files copied in:
**`known-defects: 11 PASS, 53 XFAIL, 0 FAIL, 0 XPASS`.**

| R10.8 | Case id(s) | Correct behaviour asserted | Observed at baseline |
|---|---|---|---|
| D1 | `D1-dropout`, `D1-truncated`, `D1-space-abort`, `D1-flag-mismatch` | `LOAD FAILED` | **`LOADED`**, `STORAGE_OP_STATE=4` for all four (control `D1-checksum` correctly `LOAD_FAILED`) |
| D2 | `D2-verify-mismatch`, `D2-verify-checksum` | `VERIFY FAILED`, program intact | mismatch reported **`VERIFIED`**; bad checksum → `VERIFY FAILED` but **program erased** (`PROG_END` → `$825A`). Control `D2-verify-identical` passes |
| D3 | 18 `D3-*` families (stray `ENDIF/ELSE/THEN/)/TO/ENDP`, leading line number, missing colon, trailing `)`, infix `MOD`, `PRINT x; x`, `PRINT x, x`, chained compare, string slice, `'` comment, embedded `""`, unclosed `(`, `FOR` without `NEXT`) | compile error ≠ 0 | **compile error 0**, program silently truncated, for all 18. Controls: incomplete expression → 3, unknown word → 2, valid `x = 1 : y = 2` compiles |
| D4 | `D4-len{5,29,69}-line{0,2,5,10,19}` | cursor on the failing line | wrong for every line but the last (e.g. 5-char lines: always line 19; 29-char: +5; 69-char: +2). The `line19` cases pass only because nothing follows |
| D5b | `D5b-break-key-editor` | edit buffer unchanged | buffer = `$10` (control char inserted) |
| D5 | `D5-break-running-loop` | `top: GOTO top` returns to the editor after BREAK | loop keeps running (8 M instructions), source intact |
| D6 | `D6-array-load-survives-run` | loaded array readable by the next RUN | `LOADED`, then RUN: runtime error 10, `y = 0`. A defect to be repaired (arrays are an intentional feature), not a feature to be removed |
| D7 | `D7-fill-{noise-10pct, noise-25pct, staggered-dots, ladder-1px-teeth, ladder-2px}` | exact flood fill | 7,166 / 12,288 / 35,712 / 21,202 / 2,520 wrong pixels, fill stack at 1,024 B (control `noise-40pct` exact) |
| D8 | `D8-clear-resets-scalars`, `D8-clear-keeps-package` | scalars zeroed; package survives `CLEAR` | `s` still 5; `CLEAR : CIRCLE …` → runtime error 9 |
| D9 | `D9-edit-survives-navigation`, `D9-program-full-keeps-text` | typed text kept | UP,DOWN restores `b = 2` (edit lost); `PROGRAM FULL` then any key → empty buffer. Control `D9-nav-plain` passes |
| D11 | `D11-mul/add/sub/literal` | error, or promoted to float | `30000*3 → 24464`, `32767+1 → 32768 (-32768)`, `-32768-1 → 32767`, `100000 → 34464`, compile and run errors 0. Control `D11-ok-in-range` exact |
| U6 | `U6-mode1-return` | video-mode bits 0 in the editor | bits = 2 (hi-res left on) |

D4's xfail set (every `line < 19`) was fixed *from* the baseline observation; the assertion itself
("cursor on the line containing the error") was written first and is never relaxed. D10 (float
display truncation) and the multi-item `PRINT`/`INPUT` gaps are not in the requested list and have
no case yet.

### 2.4 The gate suite [M]

`prod-regress: 35 PASS, 0 XFAIL, 0 FAIL` on the Phase 1 ROM (§7). It covers: typing and storing
lines through the real key path; `run` typed at the prompt; CAPS SHIFT+1 delete-line; tape LOAD OK /
bad checksum / VERIFY identical; SAVE header contents; SHAPES (CIRCLE+FILL pixel checks), SPRITE
(GRAB/SHOW/MOVE/HIDE and error 15/17), MODE (errors 12/13/14, `MODE 1`→`MODE 0` return), GRAPHICS
(BLOCK/FRAME/CPLOT/INVERT pixels), PRINTER (install, `LPRINT` of a number and a string, `LLIST`),
`NEW` clearing the registry; and the `abi-*` group (§4.3).

On the unmodified ROM the same file gives, as expected, FAIL for `pkg-printer-lprint-number` (ABI-F1) and for the
`abi-*` cases (the ROM has no table to find) — §7.

### 2.5 Not testable without physical hardware

Analogue cassette path (levels, dropouts, wow/flutter, leader/sync thresholds — calibrated against emulator signal);
real-recorder SAVE→LOAD→VERIFY; keyboard feel, debounce, key loss at typing speed, auto-repeat, BREAK keycap matrix
position (`docs/hardware_notes.md`: unconfirmed); display contention and flicker; `MODE 1` and ULAplus on real hardware;
AY audio; printer output; EXROM/Dock paging on a real machine and interrupt safety while chunk 6 is RAM. None of
the Phase 1 results claims hardware qualification (decision 8).

## 3. Task B — package interface inventory

Method: a script assembled each package, tokenised the source (including `printer_raster.asm`),
removed package-local labels and mnemonics, and intersected the rest with the HOME/EXROM symbol
tables [M]; then each HOME target's call/jump closure was walked in the listing for EXROM
edges, the pins' owners were traced in HOME source, and the register contracts were read from the
routines' headers.

### 3.1 HOME entry points used (16 — exactly the plan's list)

`EXT2_REGISTER`, `GFX_SET_MODE`, `GFX_CHAR_TO_FONT_OFFSET`, `GFX_SPRITE_CAPTURE`, `GFX_SPRITE_DRAW`,
`GFX_PLOT_CLIPPED`, `GFX_READ_PIXEL`, `GFX_WRITE_PIXEL`, `MEM_LINE_FIRST`, `MEM_LINE_NEXT`,
`MATH_MULTIPLY16`, `MATH_NEGATE16`, `VM_CLAMP_Y191`, `VM_COMPUTE_PRINT_ATTR`, `VM_NUM_TO_TEXT`,
`VM_STR_ADDR`. Per-package use is in `PACKAGE_ABI.md` §10. No package calls any other HOME or EXROM
routine; none reads or writes any other sysvar.

### 3.2 Findings beyond the plan

| ID | Finding | Resolution |
|---|---|---|
| **ABI-F1** | `VM_NUM_TO_TEXT` ends in `jp BASIC_NUM_TO_STRING_EXROM` (`$C09C`). `OP_CALL_EXT` pages EXROM **out** before a package runs, so the PRINTER package's `LPRINT <number>` jumps into RAM. [M] baseline: `LPRINT 123` falls through a NOP slide to `$E000+` and reaches the `V2_SHOW_MESSAGE` breakpoint with `HL=$F4E5`; `pkg-printer-lprint-number` FAILs at baseline. (`LPRINT a$` and `LLIST` are fine.) The plan's "16 routines, 48 bytes of jumps" would have *frozen this bug into the ABI* | slot 14 is an EXROM-safe wrapper (14 bytes in the padding); the checker pins its exact bytes and forbids exposing the raw routine. Test PASSes now |
| **ABI-F2** | HOME *writes* package-owned state: `MEM_INIT` zeroes `SPRITE_SLOT_DEFINED/SHOWN` and `SPRITE_DISPLAY_DEPTH`; `GFX_SPRITE_INVALIDATE` (from `GFX_CLS`, scrolling, `GFX_SET_MODE`) zeroes `SHOWN`/`DEPTH` | documented; `SPRITE_DISPLAY_DEPTH` pinned (not in the plan's list) |
| **ABI-F3** | SPRITE addresses `$BFB0–$BFBA` with literals; only a prose ledger (R8.9) reserved it | now `PKG_SCRATCH_BASE/END` in the ABI file; checker scans HOME and EXROM listings for any reference and lints package sources for literal addresses |
| **ABI-F4** | package error codes 12–20 share the VM's namespace; `OP_CALL_EXT` ignores a status return (R10.8 A3) | documented, **not** redesigned |
| **ABI-F5** | the FILL scratch (`$C000–$DBFF`) and sprite buffers (`$E800–$F0FF`) are memory-map contracts, not sysvars | pinned as constants and allowed ranges in the checker |

### 3.3 Is the KTAB padding really available? [M]

`$0092–$00FF` = 110 bytes (the plan said 111 from `$0091`; `$0091` holds the KTAB magic `$1A`). In the
unmodified image all 110 bytes were `$FF` (`DS $0100 - $, $FF`); it is ROM, so nothing can write it, and
`V2_VERIFY_KTAB` reads only `$0091`. Pre-existing hazard noted, not touched: the NMI vector `$0066`
lands inside the KTAB entries (a stray NMI would execute `jp` bytes mid-instruction).

### 3.4 Alternatives considered

| Option | Verdict |
|---|---|
| ROM-signature check only (detect, don't fix) | rejected: every HOME edit would still invalidate every package |
| Jump table alone (the plan's M-6a) | insufficient: leaves RAM, formats, banking — and would have frozen ABI-F1 |
| V1-style RAM veneer table copied at init | rejected: costs RAM and init code; the padding is free |
| Relocate package scratch out of the sysvar block into the package images | cleaner long-term, rejected for Phase 1: touches working package code ("preserve existing functionality") for no ABI benefit once pins are asserted. Recommended for *new* packages |
| Pin in place + assert (chosen) | zero RAM/ROM, proves the layout, fails loudly on drift |

## 4. Task C — what was implemented

### 4.1 Design (full contract in `PACKAGE_ABI.md`)

1. **Single source of truth** `include/v2_package_abi.inc` (version words, service list, pins, constants),
   expanded in two modes by macros: in `rom/v2_home.asm` it *emits the table and asserts the pins*;
   in a package build it *defines the names*. Packages no longer include `sysvars.inc` or
   `build/v2_crossbank.inc`, so an unlisted HOME internal is an assembler error.
2. **Service table** at `$0092`: magic `$5A`, major 2, minor 0, count 16, then 16 `jp` slots
   (`$0096–$00C5`); 14 more slots free before the slot-code area `$00F0–$00FD`.
3. **Pins**: 34 cells + 11 constants asserted in the HOME build (a moved sysvar fails the build).
4. **Versions**: header *autostart* word `= $8000 | major<<8 | minor`. Program/array tapes `$8100`
   (format 1.0), packages `$8200` (ABI 2.0). Rule: tag and major equal, tape minor ≤ ROM minor.
   `STORAGE_LOAD` checks after the name matches and **before** the length check or any received
   byte; failure returns `A=$FE` (clean), message **`BAD TAPE VERSION`**, program/window untouched.
5. **Guard rails**: HOME build asserts; `tools/check_package_abi.py` in `make check` (table bytes,
   pins, overlaps, EXROM edges, wrapper bytes, package assembly against the ABI file alone, every
   package call/jump/memory reference, literal addresses); production tests.

### 4.2 Files changed

`include/v2_package_abi.inc` (new); `rom/v2_home.asm` (table, wrapper, asserts); `rom/v2_exrom.asm`
(`STORAGE_VERSIONED`, ABI include); `kernel/storage/storage.asm` (version stamp/check, guarded by
`STORAGE_VERSIONED` — legacy and component builds assemble as before); `rom/exrom_v2_shell.asm`
(removed the old `autostart == 1` test, added the `BAD TAPE VERSION` path and message);
`rom/v2_package_{mode,sprite,printer,graphics}.asm`, `rom/ext_v2_shapes_module.asm` (include the ABI file
only); `tools/make_extension_tzx.py` (`--v2` stamps the ABI word; default unchanged for the legacy
extension targets); `Makefile` (`--v2`, `check_package_abi.py`, `test-prod`, `test` prerequisites).

### 4.3 ABI tests (gate, `abi-*`) [M]

Shipped table bytes; slot 14 with EXROM out; a current-ABI package tape → real LOAD EXT → install →
run (SHAPES, pixel check); rejection with **no side effects** (registry empty, length 0, window
marker untouched) of package header words `0001` (the old ABI), `0000`, `8300`, `8201`, `0200`, `8100`;
program LOAD rejection (program untouched, `STORAGE_OP_STATE=6`) of `8000`, `0000`, `8200`, `8101`,
`0100`, and VERIFY of `0000`; SAVE stamps `8100`/`8200`; a program and a package SAVEd by the ROM
(blocks captured at the transport) LOAD back on a fresh boot and the package still runs.

## 5. Costs and headroom [M]

| | Baseline `f0cd550` | Phase 1 | Δ |
|---|---:|---:|---:|
| HOME used / free | 15,838 / **546** | 15,838 / **546** | **0** (table + wrapper = 66 B inside the existing `$FF` padding) |
| EXROM used / free | 6,807 / **1,385** | 6,852 / **1,340** | **+45** |
| Fixed RAM | — | — | **0** |
| Package sizes (mode/sprite/printer/shapes/graphics) | 165/832/345/795/467 | identical | 0 |
| KTAB padding left | 110 B | 44 B (42 B = 14 slots + 2) | −66 B |

EXROM +45 = version-word helper 13 + check 16 + bad-version tail 4 + shell tail 18 + message 17 −
SAVE simplification 11 − removed old test 12.

## 6. Compatibility

| Item | Result |
|---|---|
| **Existing packages (functionality)** | all five unchanged in size and behaviour: gate cases `pkg-*` PASS; SHAPES also runs after a real tape LOAD |
| **Previously built package tapes** (header word 1, raw HOME addresses) | **refused** with `BAD TAPE VERSION` — they would call wrong addresses; rebuild with `make v2-packages`. Intentional one-time break (R10.8 M-6) |
| **Program tapes saved by R10.8 and earlier** | **refused** (header word is whatever the buffer held, typically `$0000`); program untouched. **Owner decision (§9)** |
| **Stock BASIC tapes** | refused (autostart is a line number or `$8000`, major 0). Previously accepted as garbage source (R3) |
| **Program tapes saved by this ROM** | `$8100`, round-trip tested |
| **V1/legacy chain, standalone component tests** | unchanged: all version code is under `STORAGE_VERSIONED`; `make check` assembles them |
| **Array tapes** | untouched; stamped/checked `$8100`; type 8 identifier and version word preserved. Array persistence is an intentional feature; its semantics are the subject of a separate architecture audit |

## 7. Test results (final run, working tree)

Final `make check` + `make test` on the working tree: **rc 0** (`make test` wall time 22.9 min, of which the
production suites ≈ 9 min — they run concurrently).

| Check | Result |
|---|---|
| `make check` (includes the new `check_package_abi.py`; legacy V1 chain and test builds still assemble) | rc 0 |
| `make budget` | HOME **546** free (unchanged), EXROM **1,340** free (−45) |
| Headless smoke | **9/9** (baseline 9/9) |
| V2 standalone (component, fake services) | **38/38** (baseline 38/38) |
| Production-ROM checks (`v2_production_checks.py`) | **19/19** (baseline 19/19) |
| FILL (`v2_fill_check.py`, unchanged gate) | **10/10** (baseline 10/10) |
| **New** production gate (`v2_prod_regress.py`) | **35 PASS**, 0 FAIL |
| **New** known-defect suite (`v2_known_defects.py`) | **11 PASS** (positive controls), **53 XFAIL** (known defects reproduced), 0 FAIL, 0 XPASS |
| `make -n test \| grep -ci fuse` | 0 — no Fuse/X11; `make test-legacy` was **not** run |

Baseline comparison (unmodified `f0cd550` in a separate worktree, new test files copied in) [M]:

| Suite | Baseline | Phase 1 |
|---|---|---|
| known-defects | 11 PASS, 53 XFAIL, 0 FAIL, 0 XPASS | identical |
| gate | **16 PASS, 19 FAIL** — the 19 are exactly the new behaviours: `pkg-printer-lprint-number` (ABI-F1), `save-header` (no version word), and the 17 `abi-*` cases | 35 PASS |

So the 53 expected failures are unchanged by Phase 1 (it fixes none of them, by design), and every
Phase 1 behaviour change is demonstrated failing before and passing after.


## 8. Remaining risks and limitations

1. **Edge quantisation.** RWA sampling jitters every edge by up to ±226 T; the receiver tolerates it
   (positive controls pass), but a marginal-timing defect would not show. Analogue behaviour needs the
   physical round trip (§10).
2. **SAVE output pulses** are not generated or checked; only the arguments handed to the transport.
3. **Cost of the suites**: 99 cases, each booting the emulator 1–3 times; the two suites take about 9 minutes
   wall (concurrently; ≈ 15 minutes serial) of `make test`'s 23. `make test-prod` runs just these.
4. **Emulator start-up** occasionally stalls once (seen once in ≈ 250 boots); `boot()` retries up to three times.
5. **Header word is the builder's claim.** Nothing proves a package was *built against* the ABI it
   declares except `make v2-packages` + the checker; a hand-edited tape can lie.
6. **Record chain not validated** after receive (R10.8 R3 remainder): a tape with the right version but a
   corrupt body loads as junk lines. Not a Phase 1 item.
7. **`CLEAR` still unregisters packages** (D8; `PACKAGE_ABI.md` §2 says so) — fixed in step 2.6.
8. D10 (float rounding) and multi-item `PRINT`/`INPUT` have no cases.
9. The float path of `VM_NUM_TO_TEXT` is deliberately outside ABI 2.0 (unexercised through the wrapper).

## 9. Owner decisions (resolved after review)

1. Strict rejection of pre-R10.9 V2 program tapes is **kept**; no unversioned-legacy acceptance.
2. The known-defect suite **stays inside `make test`**, with strict XPASS detection.

## 10. Hardware-only validation still required

Real-recorder SAVE→LOAD→VERIFY of a small and a ≈ 6 KB program **and of a package tape and a program tape
carrying the new header words**; deliberate dropout; SPACE abort; wrong-name tape; BREAK keycap and a BREAK
of a running loop; typing latency/flicker; hi-res (`MODE 1`) and ULAplus on supporting hardware; AY, printer.

## 10a. Owner corrections applied after review

* Decisions: strict refusal of pre-R10.9 program tapes is kept; the known-defect suite stays in `make test`
  (strict XPASS detection kept).
* The earlier proposal to **retire `SAVE/LOAD … ARRAY` is withdrawn**. Array persistence is intentional (the V2
  replacement for `DATA/READ/RESTORE`; goals: program alone, program with its current variables/data, array data
  independently — their actual status is **not** assumed). Work-sequence step 2.5 is now a read-only architecture
  audit followed by an architecture-first repair. The −430…−470 B EXROM saving is removed from all projections;
  `R10_9_WORK_SEQUENCE.md` §2a separates measured headroom (HOME 546, EXROM 1,340) from estimates.
* Test correction found during closure: after the ABI work `D6-array-load-survives-run` still reported XFAIL, but for the
  wrong reason (its synthesised array tape lacked the new version word and was refused, so the load itself failed).
  The tape now carries `$8100`; the case again reproduces the real defect (`LOADED`, then RUN: runtime error 10).
  Re-run alone after the fix; the full `make test` pass recorded in §7 predates this one-line test fix.
* `IN(port)` / `OUT port,value` with full 16-bit port addresses are recorded as high-priority R10.10 language
  requirements (`R10_9_WORK_SEQUENCE.md` §2b).

## 11. Recommended next sequence

See [`R10_9_WORK_SEQUENCE.md`](R10_9_WORK_SEQUENCE.md): 2.1 strict compile + exact error line → 2.2 BREAK and
edit preservation → 2.3 tape failure semantics (one physical round trip) → 2.4 FILL → 2.5 array-persistence audit, then repair →
2.6 `CLEAR` → 2.7 overflow-promotion *study* → 2.8 PRINT/INPUT assessment → close. Each step flips its
`xfail=` markers in the same change.

## 12. Working-tree status

`git status --short` at the end of Phase 1 (branch `main` at `f0cd550`; **nothing staged, nothing committed**; no
unrelated change touched; the temporary baseline worktree used for the "before" runs has been removed):

```
 M Makefile
 M docs/v2/TESTING.md
 M kernel/storage/storage.asm
 M rom/exrom_v2_shell.asm
 M rom/ext_v2_shapes_module.asm
 M rom/v2_exrom.asm
 M rom/v2_home.asm
 M rom/v2_package_graphics.asm
 M rom/v2_package_mode.asm
 M rom/v2_package_printer.asm
 M rom/v2_package_sprite.asm
 M tools/make_extension_tzx.py
 M tools/v2_fill_check.py
 M tools/v2_headless.py
?? docs/v2/PACKAGE_ABI.md
?? docs/v2/R10_9_PHASE1_REPORT.md
?? docs/v2/R10_9_WORK_SEQUENCE.md
?? include/v2_package_abi.inc
?? tools/check_package_abi.py
?? tools/run_v2_prod_tests.sh
?? tools/tape_synth.py
?? tools/v2_abi.py
?? tools/v2_known_defects.py
?? tools/v2_prod.py
?? tools/v2_prod_regress.py
```

Modified files are the ABI/test plumbing described in §4.2 and `docs/v2/TESTING.md`; the untracked files are
new. `build/` and the root `*.bin` outputs are untracked build products (git-ignored).
