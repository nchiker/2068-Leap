# 2068-Leap V2 Enhanced v2.1.0-emu.1 — Speed and Package Functions Release: status

**Start here** for this release. The earlier releases are unchanged: `v2.0.2-emu.1` (compiler maintenance release, `V2_COMPILER_MAINT_RELEASE_STATUS.md`), `v2.0.1-emu.1` (sound maintenance release, `V2_MAINT_RELEASE_STATUS.md`) and `v2.0.0-emu.1` (`V2_RC_STATUS.md`).

| | |
|---|---|
| Designation | **2068-Leap V2 Enhanced v2.1.0-emu.1 — Speed and Package Functions Release** |
| Status | **emulator-qualified, not hardware-qualified**: the ROMs passed the emulator qualification below (ZEsarUX) and the release is reproducible; **physical TS2068 compatibility has not been verified** |
| Approved | by the owner, 2026-10-27 (designation and name as proposed; `make test-legacy` (V1, Fuse) and the hardware checklist waived, decision F37 in `V2_LEAPC_BACKPORT_PLAN.md`, see section 3) |
| Release source | annotated tag **`v2.1.0-emu.1`** on `v2-development` (the merge of `backport/leapc` that adds this file); `docs/v2-user-manual` points at the same commit |
| Previous release | `v2.0.2-emu.1` (`77f1baa`), unchanged and reproducible from its tag (a v2.0.2 tree was rebuilt from its tag on 2026-10-27 and its packages loaded) |
| Hardware | **NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE**: `V2_HARDWARE_CHECKLIST.md` (its section for this release); waived, not a release blocker |

The boot screen shows `2068 LEAP V2.1` (`include/v2_version.inc`).

## 1. What changed from v2.0.2-emu.1

The source of the changes is the back-port of 2068-Leap-C's improvements, `V2_LEAPC_BACKPORT_PLAN.md` (phases 0-6; its ledger and each item's outcome section; decisions F1-F38). The planned `v2.0.3` (phase 2) and `v2.0.4` (phase 3) were never released separately: this release carries everything since `v2.0.2-emu.1`. Item numbers are the plan's.

**Speed** (the manual's table, `tools/qual/manual_measure.py`: T-states a statement adds to a loop; `v2.0.2-emu.1` -> `v2.1.0-emu.1`):

| Statement | v2.0.2-emu.1 | v2.1.0-emu.1 |
|---|---:|---:|
| empty `FOR`/`NEXT` pass | 1,107 | 827 |
| `a = i` | 1,240 | 1,040 |
| `a = i * 2 + 1` | 4,600 | 3,700 |
| `a = a * 1.0001` | 55,200 | 11,500 |
| `t(3) = i : x = t(3)` | 4,500 | 3,700 |
| `a$ = LEFT$(a$ + "x", 20)` | 9,300 | 8,400 |
| `PLOT 100, 100` | 2,800 | 2,500 |
| `CALL p(1)` | 3,800 | 3,500 |
| `AT 5, 0 : PRINT 7;` | 5,800 | 5,000 |
| `PRINT 7` when the screen scrolls | 250,000 (14 lines a second) | 146,000 (24 lines a second) |

* **Loops and tests.** An integer `FOR`/`NEXT` works in registers (5.3); `NEXT` adds a constant step without calling the general routines. A variable compared with a constant in an `IF` is one instruction (5.12: `IF i < 1000` 2.4 to 2.6 times faster); a comparison and its jump are one instruction (5.4), as are `v = v + k` and `v = v + w` (5.4). BREAK is polled at jumps, calls and waits instead of after every operation (5.2); BREAK still stops every loop in under one iteration (`qbreak`, 19 cases). The operand stack's push and pop are cheaper (5.5).
* **Decimal literals** are turned into 5-byte constants once, when the line is compiled, instead of being divided at every execution (5.1): `x = x + 0.5` 31,463 -> 9,285 T at that item. `VAL` and `INPUT` share the parser (`VAL("3.1416")` 263.7 -> 32.1 kT). The cost moves to compile time (about 30 kT a decimal literal).
* **Floating point.** The calculator's multiply and divide run in registers (5.6; float multiply 16,794 -> 6,664 T, divide 22,324 -> 9,464); `SQR` about 3 times faster (5.6, 5.7); `SIN`, `COS`, `TAN` about 2 times faster (5.6), then a further 1.5 times with the new series (5.10).
* **Output.** `PRINT` of a string draws a row's characters with the screen address stepped (5.13: 1,293 -> 562 T a character), the glyph lookup is a table (5.14, 510 T a character), the output scroll copies each scanline in unrolled blocks (5.11: 218,252 -> 142,599 T) and the bottom row's clear sets its attributes directly (5.8). The editor's row clear is 24,786 -> 6,498 T, typing a key from the boot screen 38.1 -> 19.1 kT (4.1); the redraw after a line changes height starts at the active line (redraw item, 7 scenarios, 1,941 keys identical).
* **Smaller:** `RND` is Leap-C's xorshift (1.2; Leap-C measured 143 T against about 3,800 T for the old step); the 16-bit multiply and divide routines are Leap-C's register-only versions (1.5; 60000/7 3,584 -> 1,479 T, measured in Leap-C).

**Calculator (accuracy)**

* **Arithmetic rounds to nearest (Q-34, R1).** The calculator truncated: `INT(3.1*10)` was 30, `INT(1/3*3)` 0, `1/10*10 = 1` false. Leap-C's float core (40-bit working mantissa with a guard byte, rounding to nearest) replaces the add, subtract, multiply and divide; add, subtract, multiply, divide and `m / 10^k` are correctly rounded in 99.9 to 100 % of 4,000 test pairs (were 41 to 72 %), every result equal to Leap-C's bit-exact model. Decimal literals change in the last bit (`0.1` is `7D4CCCCCCD`, was `...CC`).
* **Float `FOR` follows the BASIC standards (F11).** The step is accumulated and the end test is exact (ECMA-55 s13.4, ANSI X3.113 s8.3.4); with rounded arithmetic `FOR i = 0 TO 1 STEP 0.1` runs 10 times (it ran 11 only because the truncated sums stayed below the limit). The manual's `FOR` states the rule (`kw.for.6`). `STEP 0` is unchanged.
* **`SIN`, `COS`, `TAN` use a new series (5.10).** The old five-term series stopped at x^9/9! (`SIN(90)` was 1.0000036; error up to 16,713 ulp near 90 degrees); the new one multiplies once by pi/180 and evaluates a minimax polynomial: every tested result within about 2 ulp (`SIN` 1.81, `COS` 1.92, `TAN` 1.90 ulp). Results at `PRINT`'s four decimals are as before except where the old series was off (`TAN(89.99)` 5729.6036 -> 5729.5834); `COS(120)` is exactly -0.5. The three functions moved to the EXROM (5.9).
* **`COS(n)` for n = 32678 to 32767, and `COS`/`TAN` of a float above 32677, are right (Q-35, fixed in 5.10).** `COS(32687)` gave 0.0175 instead of 0.2924, and `COS`/`TAN` of a float above 32677 stopped with error 15.

**Bug fixes**

* **SPACE during `SAVE` ends it (2.1).** The data block was sent after an aborted header and the shell showed `SAVED`; `SAVE` and `SAVE ... ARRAY` now show `ABORTED`.
* **`CHR$ 144-164` show zeros at power-on (2.2):** the UDG table was not cleared at cold start, so power-on RAM showed through.
* **An error leaves the paging state right (2.3):** the error unwind resets the paging depth and pages the EXROM in before returning to the shell (latent: every path was balanced, nothing enforced it).
* **No lost frame interrupts in float code (1.4):** the paging routines no longer disable interrupts (Fuse lost 47 of 11,232 frames in a float loop; one without).
* **`RND` sequences are no longer correlated (1.2):** the one-bit shift register (`RANDOMISE 7`: `RND(6)` gave 3, 1, 0) is replaced by a 16-bit xorshift, period 65,535. Seeded sequences change: the manual's `RANDOMISE`, `RND` and guess-the-number examples are updated.
* Editor defects ED3, ED4 and ED7 (next section).

**Display and editor**

* **The cursor's line is always whole on screen (ED4, `SH_VIEW`):** a long or wrapped line near the bottom no longer loses its cursor.
* **A command runs on any line (ED3):** `RUN` typed over line 12 no longer replaces the line; the line keeps its text. `run = 4` and `listing = 2` are still stored.
* **The cursor after a last row of exactly 32 characters is on the screen (ED7);** LEFT/RIGHT no longer whiten the status bar's first cell.
* **Power-on version text (VER):** `2068 LEAP V2.1` on the status row from before the start-up chime until the first key. The text is `include/v2_version.inc`.
* **Distinct `1` and `l` glyphs (4.3, Leap-C D13)** (ten manual screenshots refreshed).

**Language**

* **`SYNTAX ERROR n` and `RUNTIME ERROR n` show the error code (4.4, 6.3).** A compile error shows its code (the manual's Appendix B maps it); a runtime error without a message of its own shows its number (`RUNTIME ERROR 13`).

**Characters (Q-26)**

* **All printable ASCII has a glyph (codes 32 to 126):** `` [ \ ] ^ ` { | } ~ `` printed as blanks; they have original 8x8 glyphs now (`8a52ab9`, HOME 64 bytes). The keyboard has no keys for them: they are reached with `CHR$` or in strings (limitations).

**Packages (ABI 2.1; minor version: ABI 2.0 packages load and run unchanged)**

* **Package functions (6.1):** a package can export numeric and string functions, type-checked at compile time (`NAME(a, b)` in expressions; the exact count, string or number per argument, as built-in functions are), by a signature byte and an export table (`EXT2_EXPORTS`, service 16). A built-in of the same name wins.
* **The float form and `FP_OP` (6.2):** signature bit 5; float arguments are passed in calculator slots and a function can return a float. `FP_OP` (service 17) gives a package add, subtract, multiply and divide with BASIC's own errors (67 on overflow or division by zero), integer conversion and truncation.
* **The error service and the registered error range (6.3):** runtime codes 12-31 belong to packages (the shipped packages' 12-21 are unchanged); a package may also raise 5, 15 and 67; service 18 (`VM_RAISE_ERROR`) raises one at once. Closes the overlap with the VM's codes (R10.8 A3). `tools/check_package_abi.py` checks the shipped packages' codes.
* **The reserved-slot trap (6.4):** the 11 unused service slots stop with runtime error 9 instead of executing `$FF` bytes.
* **The measured stack allowance (6.5):** a package's deepest call measured 32 bytes (50 with an interrupt); the allowance is 128 bytes (was an unmeasured 512).
* **Name warnings (6.6):** what happens when a package name equals a keyword, a built-in or a shell command is documented (`PACKAGE_ABI.md`); `tools/make_extension_tzx.py` warns.
* **Tapes carry the minor they need.** A package tape is stamped `$8200` unless the package uses 2.1, so the shipped packages still load on v2.0.x ROMs (checked: the six shipped packages load and run on a ROM built from the `v2.0.2-emu.1` tag; the 2.1 test packages are refused there with `BAD TAPE VERSION`). **The six package images and their `.tzx` tapes are byte-identical to `v2.0.2-emu.1`'s.**

**Licensing**

* **No code derived from the stock ROM remains in the images (phase 3).** The tape block I/O (a port of SA-BYTES/LD-BYTES) is replaced by Leap-C's clean-room `tapeblock.asm` (tolerance test `qtapetol`: 22 of 23 distortions accepted at item 3.1, 23 of 23 in the release's qualification, the old receiver 16; `qmicsave` captures `SAVE` at the MIC line and decodes it byte-exact); the block-graphics glyph builder by Leap-C's (D21); the calculator's literal dispatcher and `EXCHANGE` by a new table-driven design. `tools/check_provenance.py` (in `make check`) finds no run of 12 bytes shared with the stock ROMs; its allow-list is empty. `NOTICE.md` lists the code from Leap-C under the MIT licence. Earlier releases still contain the derived versions.

**Tools** (no effect on the images)

* `make check` fails below the 64-byte (HOME) / 32-byte (EXROM) emergency reserve (`report_budget.py --check`) and runs the provenance scan; `make repro` builds two fresh trees to identical images; the headless suites run on fast emulation by default (`make test` 1,940 s against about 3,200 s at real speed).
* New probes: `qpoweron` (boot from power-on RAM patterns), `qcanary --banking` (paging invariants), `fuse_frames_probe.py` (Fuse, on request), `qtapetol`, `qmicsave`, `qbench`, `qprofile`, `qrtime`, `qcalctime`, `qcalcround`, `qfndiff`, `qscrdiff`, `qeditview`, `qverboot`, `qbreak`, `qvmedge` (221 cases), `qpkgfn`, `qpkgtape`, `qpkgstack`, `qglyphs`; `qbytecode` reviewed at each compiler change (the bytecode changed intentionally at 5.1, 5.4 and 5.12, every difference explained).
* `tools/make_rc_assets.py`: per-release designation and record for this release.

**ROM space.** HOME 275 -> 313 bytes free, EXROM 26 -> 111 (section 2): phases 1 and 3 and the float core freed room, and the speed and package work spent most of it (the plan's ledger shows each item's bytes). The program pool is unchanged (source area 9,211 bytes).

## 2. Images (`make rc-assets` -> `build/release-v2-rc/`, 2026-10-27, `b0abcdf`)

| File | SHA-256 |
|---|---|
| `roms/leap_v2_home.bin` (16384) | `8c3d6c8108b653114ce4fffcd9695ac9883a8068664bffd21524b7ac1d167df0` |
| `roms/leap_v2_exrom.bin` (8192) | `e46e2065ee863f0569c3e47cdc975af0081b4e7227b690977eed4fb7d7020f9d` |
| `roms/leap_v2_zesarux.bin` (24576, ZEsarUX only) | `5a42872e6b6ec9a510f2cde3255617211d33eab7cb68b936c45d01d6db41bf95` |
| `roms/leap_v2_exrom.dck` (8201, EightyOne) | `fd028e05cbfabb915114e0ca6930fb16fda11fbda746d828b5b77f779409eb73` |
| packages (six), images and `.tzx` tapes | byte-identical to `v2.0.2-emu.1` (e.g. cbeep `5b863713df1dcfcb...`); full list in the bundle's `SHA256SUMS` |

Bundle: `2068-Leap-V2-v2.1.0-emu.1.zip`.

Identity CRC-16 (what `SAVE ... ALL` stamps with no package loaded): **`$0AEF`** (`v2.0.2-emu.1`: `$F9E9`). As for every ROM change, an ALL tape restores its variables only on the ROM pair that wrote it (RC-O3); program, array and package tapes are unaffected.

ROM free space: **HOME 313 bytes, EXROM 111 bytes** (`v2.0.2-emu.1`: 275 / 26). Program pool unchanged: source area 9,211 bytes.

## 3. Qualification (2026-10-27, all on the emulator)

`make test` ran on `8a52ab9` and the other runs on `b0abcdf`; both build this release's ROM images byte for byte (the later commits change documents and tools only):

| Suite | Result |
|---|---|
| `make check` | pass |
| `make test`: smoke ROMs / V2 standalone | 9/9, 40/40 |
| production checks, FILL check | 0 failures |
| production regression gate / Array Store gate / known-defect suite / SAVE ALL | 127 / 101 / 15 / 13 PASS |
| micsave (`qmicsave`) | 3 |
| `make qual` corpus | 667 PASS, 1 XFAIL (Q-24), 2 N/A, 0 FAIL |
| session lifecycle | 23/23 |
| `qvmedge` | 221/221 |
| `make qual-maint`: AY BEEP / cbeep / frame interrupt unavailable / cbeep tape LOAD | 59/59, 27/27, 14/14, 3/3 |
| `make doc-examples` (the manual) | 327/327 |
| `make repro` (two fresh trees, identical images) | identical: the 4 ROM images, 8 package images, 6 tapes (18 files) |
| release definitions (`make build EXTRA_DEFS=`) | assemble; HOME 348 / EXROM 110 free |
| `qcanary --banking` | 670 cases: 0 canary hits, 0 errors, 0 banking violations; lowest stack byte `$FDE8` (280 below `$FF00`) |
| `qtapetol` (23 tape distortions) | 23 of 23 loaded |
| `qpoweron` (zero, ones, alternate, address and three random RAM patterns) | 0 failures |
| `qpkgfn` (package functions, floats, errors, slot traps, ABI 2.0 packages) | 67/67 |
| `qpkgtape` (package tapes through the real receiver) | 8/8 on this ROM; with a ROM built from the `v2.0.2-emu.1` tag 16/16 (the six shipped packages load and run there, the two 2.1 test packages are refused) |
| `qglyphs` (every character code) | 256 codes, the 95 printable ones with their glyph; 0 problems |
| `make test-legacy` (V1, Fuse) | not run (owner decision F37) |
| hardware | not tested (above) |

## 4. Known limitations (documented)

* Not hardware-qualified (above). The emulator runs 50 Hz frames and a 0.5 % fast AY clock; a TS2068 runs 60 Hz (not measured); every figure in T-states is the emulator's count.
* Unchanged from `v2.0.2-emu.1`: `PAUSE`/`BEEP` with the frame interrupt off (M-3); `CBEEP` interrupts off while sounding, border argument, one package at a time.
* Open: Q-24 (`CALL` of a plain label), RC-O1 to RC-O4 (float literal range message, `SAVE ... ALL` room, ALL tapes only on the same ROM pair, 16-bit array elements), RC-O6 (the bare `FOR`/`NEXT` pass is now 827 to 911 T against the pre-qualification build's 817, `7ae0599`), T-3, T-4 (`V2_DEFECT_REGISTER.md`). Q-26 is fixed in this release; RC-O5 and RC-O7 are resolved.
* The keyboard has no keys for `` [ \ ] ^ ` { | } ~ ``: they are reached with `CHR$`, or in strings (for example from tape).
* `SAVE ... EXT` stamps the running ROM's own ABI word: a package saved from a 2.1 ROM says `$8201` and a 2.0 ROM refuses it. The shipped tapes come from `make v2-packages`, not from `SAVE`.
* A package statement named `RUN`, `LIST` or `NEW` cannot be typed alone as a line (the shell's command wins); it works with arguments or beside other text. A keyword or a built-in function of the same name always wins over a package name.
* Package float form: not for string arguments; slot 14 (print) has no float tag; `LPRINT` of a float and `SQR`/`SIN`-class operations in `FP_OP` are not provided. The reserved-slot trap and the error service raise errors only while a program runs (an execute routine), not at install time.
* UP from a trimmed editor view (the cursor's line pushed the top lines off) is a full redraw (770 kT a key in the plan's `shrink-trimmed` scenario).
* The test-only decompiler does not decode opcode 70 (float literal) or package functions (the production images are not affected).
