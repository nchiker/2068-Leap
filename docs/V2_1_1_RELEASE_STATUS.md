# 2068-Leap V2 Enhanced v2.1.1-emu.1 — Graphics and Joystick Maintenance Release: status

**Start here** for this release. The earlier releases are unchanged: `v2.1.0-emu.1` (speed and package functions release, `V2_1_RELEASE_STATUS.md`), `v2.0.2-emu.1` (compiler maintenance release, `V2_COMPILER_MAINT_RELEASE_STATUS.md`), `v2.0.1-emu.1` (sound maintenance release, `V2_MAINT_RELEASE_STATUS.md`) and `v2.0.0-emu.1` (`V2_RC_STATUS.md`).

| | |
|---|---|
| Designation | **2068-Leap V2 Enhanced v2.1.1-emu.1 — Graphics and Joystick Maintenance Release** |
| Status | **emulator-qualified, not hardware-qualified**: the ROMs passed the emulator qualification below (ZEsarUX) and the release is reproducible; **physical TS2068 compatibility has not been verified** |
| Approved | by the owner, 2026-11-01 (all the fixes, the `LINE` port and the interrupt change in this release; `make test-legacy` (V1, Fuse) and the hardware checklist waived, as for `v2.1.0-emu.1`, see section 3) |
| Release source | annotated tag **`v2.1.1-emu.1`** on `v2-development` (the merge of `maint/v2.1.1` that adds this file) |
| Previous release | `v2.1.0-emu.1` (`c005159`), unchanged and reproducible from its tag (a tree built from that tag reproduced its published HOME and EXROM images byte for byte on 2026-11-01) |
| Hardware | **NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE**: `V2_HARDWARE_CHECKLIST.md` (its section 8); waived, not a release blocker |

The boot screen shows `2068 LEAP V2.1.1` (`include/v2_version.inc`).

## 1. What changed from v2.1.0-emu.1

The origin is the Leap IDE's report of 2026-11-01 on `v2.1.0-emu.1` (four findings: `STICK`, the speed of `LINE`, the colours in `MODE 1`, the glyphs `p`, `q` and `g`) and its answer in the IDE repository, `docs/requests/LEAP_V2_ANSWERS.md`. The code of the `LINE` routine and of the interrupt change comes from 2068-Leap-C (deltas D25, commit `b024dbc`, and D27, commit `22a220b`), both ports of 2068-Forth v2.0's code (`NOTICE.md`). The defects are M-5 to M-9 in `V2_DEFECT_REGISTER.md`. Nothing else changed: the packages, the language and the memory layout are those of `v2.1.0-emu.1`.

**`STICK` (M-5, M-6)**

* **`STICK` makes the sound chip's port A an input before each read (M-5).** The start-up chime leaves the mixer (register 7) at `$F8`, which makes port A an output, so a real joystick might not have been seen. `STICK` now clears register 7 bit 6.
* **`STICK(n)` selects joystick `n` (M-6).** The port's high address byte is `A8` for joystick 1 and `A9` for joystick 2, as in the stock ROM. `v2.1.0-emu.1` left it unset, which selects no joystick.
* **The result is 0 to 31 for both sticks:** the directions are bits 0 to 3, and 16 is added while fire is pressed. In `v2.1.0-emu.1` `STICK(1)` gave the directions and `STICK(2)` gave the fire bit (0 or 1).
* Tested: corpus case `hw.stick_input` (fails on `v2.1.0-emu.1`, where register 7 reads 248; passes, 184); `tools/qual/tsrun_stick.mjs` on TSRun's core, which models both connectors and the port direction: 9 of 9 (`v2.1.0-emu.1`: 3 of 9). **Not tried with a real joystick.**

**Colour in `MODE 1` (M-7, issue nchiker/2068-Leap#5)**

* A pixel's 8 x 1 colour byte is written at its bitmap byte + `$2000` (the TS2068 lays the colour bytes out like the bitmap; Fuse's `display.c` reads them there). `v2.1.0-emu.1` wrote `$6000 + y * 32 + col`, which is the wrong pixel row for 168 of the 192 rows.
* It applies to `PLOT`, `LINE`, `CIRCLE`, `FILL`, `CPLOT`, `BLOCK`, `FRAME` and `INVERT`, which all go through one ROM routine. The package images are unchanged.
* The manual's screenshot tool (`tools/qual/manual_run.py`) had read the colours with the same wrong layout, which hid the defect in the `mode1_strips` picture. It is fixed and the picture retaken.
* Test: corpus case `pkg.mode.colour_rows`.

**`LINE` (M-9, and speed)**

* **`LINE` draws with Leap-C's delta D25:** 2068-Forth v2.0's major-axis Bresenham loop, with the screen address and mask stepped per pixel and the attribute written once per cell. It draws the same pixels and mode 0 colours as `v2.1.0-emu.1` for every line with both ends on the screen: `tools/qual/qlines.py` compared 2,952 lines in mode 0 and mode 1, `OVER 0` and `OVER 1`, byte for byte with the `v2.1.0-emu.1` ROM and with a model, and 776 more in the final run.
* **Speed** (ZEsarUX frames):

| Measured | v2.1.0-emu.1 | v2.1.1-emu.1 | |
|---|---:|---:|---:|
| 864 x `LINE 10, 10 TO 100, 60` | 1,707 | 384 | 4.4 times faster |
| 100 x a 256-pixel row | 529 | 93 | 5.7 times faster |
| 1,000 x `PLOT 50` | 50 | 48 | |

* **`LINE` moves an end off the screen to the nearest edge (M-9),** as the manual always said and as `PLOT` does. `v2.1.0-emu.1` took *x* by its low byte: `LINE -10, 50 TO 100, 50` started at *x* 246. Test: corpus case `gfx.line_offscreen`.

**Glyphs (M-8, issue nchiker/2068-Leap#6)**

* The lowercase `g`, `p` and `q` have their bowl on the x-height (pixel rows 2 to 5) and the descender in rows 6 and 7; `p` had looked like a capital `P`. `tools/qual/qglyphs.py` pins the three glyphs. The manual's screenshots `charset` and `boot_screen` are retaken.

**Frame interrupt (Leap-C D27)**

* An idle frame (no key tracked) is ended after one read of every keyboard row at once (`IO_KEY_SCAN_ALL`); the 8-row scan rotates the row select. The cost of the frame interrupt (`qrtime`, `KBD_ISR_TICK`): idle 1,993 -> 190 T-states (about 3 % of every frame back), a tracked key released 2,191 -> 1,402. Debounce, repeat and BREAK are unchanged (the BREAK tests pass).

**Version text:** `2068 LEAP V2.1.1`.

**Tools** (no effect on the images)

* New: `tools/qual/qlines.py` (the `LINE` comparison above) and `tools/qual/tsrun_stick.mjs` (`STICK` on TSRun's core); corpus cases `hw.stick_input`, `pkg.mode.colour_rows` and `gfx.line_offscreen`; `qglyphs` pins `g`, `p` and `q`.
* `LOW_CHAR_TABLE` pads to a page only where it would cross one: 0 bytes in the production images; it matters in the smoke ROMs.

**ROM space.** HOME 313 -> 403 bytes free, EXROM 111 -> 111 (section 2). The program pool is unchanged (source area 9,211 bytes).

## 2. Images (`make rc-assets` -> `build/release-v2-rc/`, 2026-11-01)

| File | SHA-256 |
|---|---|
| `roms/leap_v2_home.bin` (16384) | `c79ce1cfe1d757036fb7c53974d53dd56117ec2d231c7b4c5f2e65c510dc295a` |
| `roms/leap_v2_exrom.bin` (8192) | `ba7f0869d3ea8641cbcdc25f62b131a1cc1e8614fd083a873d77313a00d5a1b5` |
| `roms/leap_v2_zesarux.bin` (24576, ZEsarUX only) | `5715340055dd67a2ef0054e015e96588dffa4dc4982da35e44245eae856f1656` |
| `roms/leap_v2_exrom.dck` (8201, EightyOne) | `8d07f7e56b288270f6c6b7771bb547622e19fa5b292c1cfa34396fb90fa46279` |
| packages (six), images and `.tzx` tapes | byte-identical to `v2.0.2-emu.1` and `v2.1.0-emu.1` (e.g. cbeep `5b863713df1dcfcb...`); full list in the bundle's `SHA256SUMS` |

The EXROM image changes only because the HOME addresses it calls moved.

Bundle: `2068-Leap-V2-v2.1.1-emu.1.zip`.

Identity CRC-16 (what `SAVE ... ALL` stamps with no package loaded): **`$2A70`** (`v2.1.0-emu.1`: `$0AEF`). As for every ROM change, an ALL tape restores its variables only on the ROM pair that wrote it (RC-O3); program, array and package tapes are unaffected.

ROM free space: **HOME 403 bytes, EXROM 111 bytes** (`v2.1.0-emu.1`: 313 / 111). Program pool unchanged: source area 9,211 bytes.

## 3. Qualification (2026-11-01, all on the emulator)

The runs below are on the commit that builds this release's ROM images `efe734c` (this table was filled in the next commit, which changes only this record):

| Suite | Result |
|---|---|
| `make check` | pass |
| `make test`: smoke ROMs / V2 standalone | 9/9, 40/40 |
| production checks, FILL check | 0 failures |
| production regression gate / Array Store gate / known-defect suite / SAVE ALL | 127/127, 101/101, 15/15, 13/13 |
| micsave (`qmicsave`) | 0 failures |
| `make qual` corpus | 670 PASS, 1 XFAIL, 2 N/A |
| session lifecycle | 23/23 |
| `qvmedge` | 221/221 |
| `make qual-maint`: AY BEEP / cbeep / frame interrupt unavailable / cbeep tape LOAD | 59/59, 27/27, 14/14, 3/3 |
| `make doc-examples` (the manual) | 327/327 |
| `make repro` (two fresh trees, identical images) | identical: 18 files |
| release definitions (`make build EXTRA_DEFS=`) | assemble; HOME 441 / EXROM 110 free |
| `qcanary --banking` | 673 cases: 0 canary hits, 0 errors, 0 banking violations; lowest stack byte `$FDE8` |
| `qtapetol` (23 tape distortions) | 22 of 23 loaded: `speed 1.25` refused. Not a regression: a sweep of the tape's start against the frame (leads -600k to +1.2M T) and of speeds 1.20-1.30 shows both this ROM and `v2.1.0-emu.1` loading or refusing 1.22-1.30 by phase alone (each refuses at some leads and loads at others; both refuse 1.22, 1.26, 1.30); the receiver runs with interrupts off. Item 3.1 of v2.1.0 also recorded 22 of 23 |
| `qpoweron` (zero, ones, alternate, address and three random RAM patterns) | 0 failures |
| `qpkgfn` (package functions, floats, errors, slot traps, ABI 2.0 packages) | 67/67 |
| `qpkgtape` (package tapes through the real receiver) | 8/8 on this ROM and on `v2.1.0-emu.1` |
| `qglyphs` (every character code; `g`, `p`, `q` pinned) | 0 problems |
| `qlines` (`LINE` against the `v2.1.0-emu.1` ROM and a model; new) | PASS: new ROM = model in every program; old ROM = old model; new = old wherever no end is off the screen |
| `tsrun_stick` (`STICK` on TSRun's core; new) | 9/9 (`v2.1.0-emu.1`: 3/9) |
| `make test-legacy` (V1, Fuse) | not run (owner waiver) |
| hardware | not tested (above) |

## 4. Known limitations (documented)

* Not hardware-qualified (above). The emulator runs 50 Hz frames and a 0.5 % fast AY clock; a TS2068 runs 60 Hz (not measured); every figure in T-states is the emulator's count.
* **The joystick selection (`A8` for joystick 1, `A9` for joystick 2) and the fire bit are verified only on TSRun's model of the connectors, not on hardware** (`V2_HARDWARE_CHECKLIST.md`, section 8).
* Unchanged from `v2.0.2-emu.1`: `PAUSE`/`BEEP` with the frame interrupt off (M-3); `CBEEP` interrupts off while sounding, border argument, one package at a time.
* Open: Q-24 (`CALL` of a plain label), RC-O1 to RC-O4 (float literal range message, `SAVE ... ALL` room, ALL tapes only on the same ROM pair, 16-bit array elements), RC-O6 (the bare `FOR`/`NEXT` pass against the pre-qualification build's 817 T, `7ae0599`; figures in `V2_1_RELEASE_STATUS.md`), T-3, T-4 (`V2_DEFECT_REGISTER.md`).
* **The cartridge identity and the ALL tapes change, as for every ROM change:** the identity CRC is `$2A70` (`v2.1.0-emu.1`: `$0AEF`), so a `SAVE ... ALL` tape written by an earlier release is not restored on this one, and the reverse (RC-O3).
* The keyboard has no keys for `` [ \ ] ^ ` { | } ~ ``: they are reached with `CHR$`, or in strings (for example from tape).
* `SAVE ... EXT` stamps the running ROM's own ABI word: a package saved from a 2.1 ROM says `$8201` and a 2.0 ROM refuses it. The shipped tapes come from `make v2-packages`, not from `SAVE`.
* A package statement named `RUN`, `LIST` or `NEW` cannot be typed alone as a line (the shell's command wins); it works with arguments or beside other text. A keyword or a built-in function of the same name always wins over a package name.
* Package float form: not for string arguments; slot 14 (print) has no float tag; `LPRINT` of a float and `SQR`/`SIN`-class operations in `FP_OP` are not provided. The reserved-slot trap and the error service raise errors only while a program runs (an execute routine), not at install time.
* UP from a trimmed editor view (the cursor's line pushed the top lines off) is a full redraw (770 kT a key in the plan's `shrink-trimmed` scenario).
* The test-only decompiler does not decode opcode 70 (float literal) or package functions (the production images are not affected).
