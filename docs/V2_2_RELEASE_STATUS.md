# 2068-Leap V2 Enhanced v2.2 (designation pending, owner gate G3) -- Storage Release: status

**Start here** for this release. The earlier releases are unchanged: `v2.1.1-emu.1` (graphics and joystick maintenance release, `V2_1_1_RELEASE_STATUS.md`), `v2.1.0-emu.1` (speed and package functions release, `V2_1_RELEASE_STATUS.md`), `v2.0.2-emu.1` (compiler maintenance release, `V2_COMPILER_MAINT_RELEASE_STATUS.md`), `v2.0.1-emu.1` (sound maintenance release, `V2_MAINT_RELEASE_STATUS.md`) and `v2.0.0-emu.1` (`V2_RC_STATUS.md`).

| | |
|---|---|
| Designation | **TODO(owner): release designation and tag name (owner gate G3; the designation goes into `tools/make_rc_assets.py`)** |
| Status | **emulator-qualified, not hardware-qualified**: the ROMs passed the emulator qualification below (ZEsarUX); **physical TS2068 compatibility has not been verified**. TODO(owner): confirm the wording once G3 is decided |
| Approved | TODO(owner): approval date and what was waived (`make test-legacy` (V1, Fuse) and the hardware checklist were waived for `v2.1.0-emu.1` and `v2.1.1-emu.1`) |
| Release source | TODO(owner): annotated tag and merge commit. The work is on branch `release/v2.2-storage`; the ROM qualified below is commit `46a974a` |
| Previous release | `v2.1.1-emu.1` (`4891681`), unchanged and reproducible from its tag |
| Hardware | **NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE**: `V2_HARDWARE_CHECKLIST.md` (rows 2.11 to 2.13 and 3.12 to 3.16 are this release's); nothing was run |

TODO(owner): the boot screen's version text (`include/v2_version.inc`, owner gate G3).

## 1. What changed from v2.1.1-emu.1

The origin is a GitHub experience report on `v2.1.1-emu.1`: a card-file program ported to Leap BASIC met the data ceiling (about 1.9 KB of file) and read an oversize array tape as a damaged one. The plan, with every item's design, bytes, tests and decisions, is `V2_2_STORAGE_RELEASE_PLAN.md` (its section 6 is the ledger). Item letters are the plan's. The tape format is `V2_SAVE_ALL_FORMAT.md`.

**A. Array Store: replacement and `ARRAY STORE FULL` (commit `20e4365`)**

* `LOAD "n" ARRAY a` replaces an array of the same name in the Array Store without room for both copies. The new array has to fit on its own: the room is computed before anything changes, the tape is received into the free part of the main pool, validated, and only then does the old entry go and the new one take its place. Replacing an array with one of the same size in a full store works.
* An array tape that does not fit reports **`ARRAY STORE FULL`**. It was `LOAD FAILED`, the message of a damaged tape or no tape (defect register, `M-10`). A damaged tape is still `LOAD FAILED`; a malformed array tape is still `BAD ARRAY TAPE`. On every failure the store is as it was.
* `STORAGE_LOAD` has a new return code, `STORAGE_LOAD_TOO_LONG` (`$FD`, nothing written), for a header longer than the room the caller gave. `LOAD` and `VERIFY` of a program treat it as the clean failure they already know (`LOAD FAILED`, `VERIFY FAILED`).
* The loader passes the smaller of the store room and the pool room (from the staged descriptor to `V2_CODE_LIMIT`, at least about 3.9 KB for any program the shell accepts) to `STORAGE_LOAD`; an array longer than that is `ARRAY STORE FULL` (added with item C, whose segment is larger than the pool room for a program over about 6.6 KB).

**B. `SAVE ... ALL` in two blocks (commit `ebb7d85`; the partition rule, RC-O2, is closed)**

* `SAVE "n" ALL` is a header, **block 1** (program + session, no segment 2) and **block 2** (segment 2, sent straight from its own address, no copy), with a silent gap of about **4.5 s** between the blocks. LOAD needs the time: after block 1 it computes the block CRC and the identity CRC (about 3 to 4 s together) before it listens for block 2, whose pilot lasts about 1.8 s; the receiver waits up to 8.6 s for it.
* The rule that refused a save is gone: it was bytecode + segment 2 + 53 bytes against the bytecode area plus free memory. It is now bytecode + 55 bytes (the tail of block 1 is 55 bytes: the 49 session cells, the segment-2 CRC, the identity CRC, the block CRC).
* SPACE during the gap or during block 2: `ABORTED`. `VERIFY` of an ALL tape compares block 2 with segment 2; a missing, damaged or different block 2 is `VERIFY FAILED`.
* Failure semantics of `LOAD`: a failure before block 2 is read (another ROM's tape, a failed check of block 1) keeps the Array Store, as before. A failure of block 2 (no pilot within 8.6 s, SPACE, a dropout, the transport checksum, the segment-2 CRC) happens after segment 2 was written, so it **empties the Array Store**; the report is `NO VARIABLES` with the program kept.
* The gap is a hardware figure, tuned only in emulation (limitations).
* A tool consequence: anything that replays a captured ALL save must insert the gap before block 2. `make doc-examples` first failed 4 of 327 for this reason; `tools/qual/manual_tapes.py` now inserts it.

**C. Array segment 2 at `$5B00`-`$77FF` (commit `65f9947`; owner gate G1)**

* Segment 2 (arrays that do not fit the main pool, and the Array Store) is **`$5B00`-`$77FF`, 7,424 bytes** (3.6 times the 2,048 bytes it had at `$E000`). `FREE(1)` is 7424 on an empty machine. `$E000`-`$E7FF` is idle and reserved; `$7800`-`$7FFF` stays free for user machine code.
* **`MODE 1` and arrays share `$6000`-`$77FF`** (the mode's colour attribute file). Entering `MODE 1` while arrays or the Array Store occupy memory above `$6000` is refused with error 64 (`OUT OF MEMORY`) before anything changes; it is allowed otherwise. The check is in the ROM (15 bytes of HOME), so old `MODE` package tapes are held to it too. While `MODE 1` is on, the segment's top is `$6000` (`ARR2_TOP`, used by `VM_ARENA_FIT` and `FREE(1)`).
* Two places that would have broken `LOAD ... ALL` with the new range were found in testing and fixed: the order of the address chain (segment 2 now lies below the program pool) and `SA_RESTORE`'s array-pointer check (segment 2 is tested before the arena).
* `ARR_VALIDATE`'s element-count guard is `< 4096` (an ASSERT ties it to the store size).

**D. `SAVE` / `LOAD` / `VERIFY ... CODE` (commit `46a974a`; owner gate G2)**

* `SAVE "n" CODE start,length`, `LOAD "n" CODE [start[,length]]` and `VERIFY "n" CODE [start[,length]]` save and load raw memory. *start* and *length* are decimal whole numbers (0 to 65535, no expressions); *start* + *length* may not pass 65536. `LOAD` goes to the address on the tape unless a *start* is given; a given *length* is a maximum (a longer tape is `LOAD FAILED`, nothing stored). `LOAD ... CODE` ends the variable session; `VERIFY ... CODE` does not. Details: manual, `SAVE`, `LOAD` and the concept *Tapes*; `V2_LANGUAGE_REFERENCE.md` section 7.
* The header is of type 3 (Leap's format word; the start address is in the PROGLEN field), so a CODE tape is not offered to `LOAD "n"` as a program.
* **G2 (owner): the AY sound code moves into HOME** (BEEP's play loop, with the period already there, and `SOUND`); their two EXROM entry slots are gone and `V2_KTAB_MAGIC` is `$20` (was `$1E`). The default `make build` now defines `V2_MAINT_AYB_PLAY_HOME` as well, and `V2_MAINT_AY_HOME` marks that build (`include/v2_ktab.inc`). The number reader stays in the shell. This is what pays for item D: before it, C and D together did not fit above the EXROM reserve (item D alone was 137 bytes of EXROM).

**Tape format (owner gate G3, option 2)**

* The format minor **stays 1**. A v2.2 `SAVE ... ALL` tape carries the same version word as a v2.1.x one; the identity CRC separates the ROM builds. A v2.2 ALL tape on a v2.1.x ROM loads the program and says `NO VARIABLES`, and a v2.1.x ALL tape on v2.2 does the same. Plain program tapes are unchanged: v2.2 program tapes load on v2.1.x. (The v2.1.x side follows from the order of its checks and has not been run on a v2.1.x ROM.)

**ROM space** (`make budget`; the ledger has each step):

| Step | HOME free | EXROM free |
|---|---:|---:|
| `v2.1.1-emu.1` (start) | 403 | 111 |
| item A | 403 | 89 |
| item B | 325 | 32 |
| shrink pass over A and B | 325 | 120 |
| shrink pass 2 (older save code, small HOME edits) | 347 | 141 |
| item C | 326 | 128 |
| item D with the G2 moves (**end**) | **270** | **34** |

EXROM is 2 bytes above its 32-byte emergency reserve; HOME is 206 above its 64. The ledger records no change to the program pool (source area 9,211 bytes at the baseline).

**Documentation:** the manual (memory map, Arrays, Array Store, Memory, Tapes, `LOAD`, `SAVE`, `VERIFY`, `MODE`, `FREE(1)`, error 64, the USR rules and the examples that used `23296`, now `30720`), `V2_LANGUAGE_REFERENCE.md`, `V2_SAVE_ALL_FORMAT.md`, `PACKAGE_ABI.md` (packages keep out of `$5B00`-`$77FF` and `$E000`-`$E7FF`), `TESTING.md`, `V2_HARDWARE_CHECKLIST.md`, `V2_DEFECT_REGISTER.md` (RC-O2 closed, `M-10`).

**Tools** (no effect on the images)

* New: `tools/v2_prod_code.py` (10 CODE cases, run by `tools/run_v2_prod_tests.sh`); `qmicsave` CODE, `all-seg2` and `array-seg2` captures; `qtapetol` `all-seg2` and CODE cases; `v2_saveall_checks.py` 13 -> 24 cases (B and C); new `v2_prod_arrays.py` cases for replacement, `ARRAY STORE FULL`, the MODE 1 interlock and the 7 KB segment.

## 2. Images (`make rc-assets` -> `build/release-v2-rc/`)

TODO(owner): built by `make rc-assets` after G3 (designation in `tools/make_rc_assets.py`, version text in `include/v2_version.inc`). The table is filled from `build/release-v2-rc/SHA256SUMS` and `BUILD_INFO.txt`:

| File | SHA-256 |
|---|---|
| `roms/leap_v2_home.bin` (16384) | TODO(owner) |
| `roms/leap_v2_exrom.bin` (8192) | TODO(owner) |
| `roms/leap_v2_zesarux.bin` (24576, ZEsarUX only) | TODO(owner) |
| `roms/leap_v2_exrom.dck` (8201, EightyOne) | TODO(owner) |
| packages (six), images and `.tzx` tapes | TODO(owner): compare with `v2.1.1-emu.1`'s (the packages are expected to be byte-identical; nothing in the ledger changes them) |

Bundle: TODO(owner).

Identity CRC-16 (what `SAVE ... ALL` stamps with no package loaded): TODO(owner) (`v2.1.1-emu.1`: `$2A70`). As for every ROM change, an ALL tape restores its variables only on the ROM pair that wrote it (RC-O3); program, array and package tapes are unaffected.

ROM free space: **HOME 270 bytes, EXROM 34 bytes** (`v2.1.1-emu.1`: 403 / 111), measured at `46a974a`.

## 3. Qualification (all on the emulator)

The runs below are on the ROM at commit `46a974a` (the last full `make test` run, exit 0):

| Suite | Result |
|---|---|
| `make check` | TODO(owner): not in the run recorded for this table |
| `make test`: smoke ROMs / V2 standalone | 9/9, 40/40 |
| production regression gate / Array Store gate (`prod-arrays`) / CODE suite (`prod-code`, new) / known-defect suite | 127 / 111 / 10 / 15 PASS |
| SAVE ALL (`saveall`) | 24 PASS |
| micsave (`qmicsave`) | 11 checks, 0 failures |
| `make qual` corpus | 670 PASS, 1 XFAIL (Q-24), 2 N/A |
| session lifecycle | 23/23 |
| `qvmedge` | 221/221 |
| `make qual-maint`: AY BEEP / cbeep / frame interrupt unavailable / cbeep tape LOAD | 59, 27, 14, 3 |
| `make doc-examples` (the manual) | 329/329 |
| `qtapetol` (43 cases) | 41 of 43 loaded: `speed 1.25` and `all-seg2 speed 1.20` refused. Both are the documented phase artifact of the receiver at speeds above about +20 % (the note on 1.25 in `V2_1_1_RELEASE_STATUS.md`): the same ROM family, and both also refuse on the release-branch build without item D |
| `make repro`, release definitions (`make build EXTRA_DEFS=`), `qcanary --banking`, `qpoweron`, `qpkgfn`, `qpkgtape`, `qglyphs` | TODO(owner): not in the run recorded for this table |
| `make test-legacy` (V1, Fuse) | TODO(owner): not run (waiver?) |
| hardware | not tested (above) |

Speed of an array loop (`tools/qual/qbench.py`, T-states around the real `V2_RUN_STORED`): in segment 2 11,889,982 at `$E000` against 11,905,559 at `$5B00` (+0.13 %); the same loop on a main-pool array 11,846,554 in both builds. The manual states no speed claim for segment 2.

## 4. Known limitations (documented)

* Not hardware-qualified (above). The emulator runs 50 Hz frames and a 0.5 % fast AY clock; a TS2068 runs 60 Hz (not measured); every figure in T-states is the emulator's count.
* **The 4.5 s gap, the CODE tapes, the tape I/O into `$5B00` and above, and the array speed in segment 2 are emulation-only.** The gap is a hardware figure (`V2_HARDWARE_CHECKLIST.md`, row 3.14). The emulator's array speed in segment 2 against the main pool differs by +0.13 %; it may not model the video-RAM contention of `$4000`-`$7FFF` that 2068-Leap-C measured at 15 to 23 % on hardware, so the real figure is unknown (row 2.11).
* **Memory.** The manual's old user area `$5B00`-`$5FFF` is withdrawn: user machine code and data go in `$7800`-`$7FFF`. Packages must keep out of `$5B00`-`$77FF` (and `$E000`-`$E7FF`); no shipped package uses them, a third-party package that does corrupts arrays (`PACKAGE_ABI.md`).
* **`MODE 1` and arrays:** `MODE 1` is refused (error 64) while arrays occupy memory above `$6000`, and arrays above `$6000` do not fit while `MODE 1` is on.
* **Array pool-room rule for `LOAD ... ARRAY`:** the tape is received into the main pool above the program, so the largest array a load can take is limited by the program's size: a 7 KB array loads only while the program text is under about 6.6 KB; otherwise `ARRAY STORE FULL`.
* **CODE tapes are Leap's own, not stock-compatible** (header type 3 with Leap's format word). A stock `CODE` tape is refused with `BAD TAPE VERSION`, with one rare exception: a stock tape saved from address 33024 or 33025 can pass the version check, so never `LOAD` a stock `CODE` tape without a start address.
* **`LOAD ... CODE` has no range checks** (as in stock BASIC): loading over `$C000`-`$DFFF`, `$B600`-`$BFFF`, the machine stack, the program area or the array segment crashes or corrupts the machine. Safe: `$7800`-`$7FFF` and the screen.
* A program tape longer than the room is still `LOAD FAILED` (a `PROGRAM FULL` mapping was left out for lack of bytes). `SAVE ... ALL` takes about 4.5 s longer on the tape, and about 0.7 s more on the CRC for a full segment 2.
* A failed block 2 of an ALL tape empties the Array Store (B).
* Not in this release: one-line `IF c THEN stmt` (deferred; an optional item, not built), tokenised program text, a larger bytecode area, the chunk-6 array segment (V3 gate items), and `LOAD ... ARRAY` as a program statement (it is a shell command).
* Open: Q-24 (`CALL` of a plain label), RC-O1, RC-O3, RC-O4 (float literal range message, ALL tapes only on the same ROM pair, 16-bit array elements), RC-O6, T-3, T-4 (`V2_DEFECT_REGISTER.md`). RC-O2 is closed by item B.
* **The cartridge identity and the ALL tapes change, as for every ROM change:** a `SAVE ... ALL` tape written by `v2.1.1-emu.1` or earlier does not restore its variables on this ROM (it loads the program), and the reverse (RC-O3).
* The keyboard has no keys for `` [ \ ] ^ ` { | } ~ ``: they are reached with `CHR$`, or in strings (for example from tape).
* A string literal longer than 31 characters is compile error 70 (unchanged; noted for porters in the manual's *Strings* and in `V2_LANGUAGE_REFERENCE.md`).
* Unchanged from `v2.1.1-emu.1`: the package limitations listed in its section 4 (`SAVE ... EXT` stamps the running ROM's ABI word; a package statement named `RUN`, `LIST` or `NEW`; the float form; the editor redraw from a trimmed view; the test-only decompiler).
