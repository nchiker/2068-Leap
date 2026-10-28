# 2068-Leap V2 Enhanced v2.0.2-emu.1 — Compiler Maintenance Release: status

> **Later release:** `v2.1.0-emu.1`, the speed and package functions release (emulator-qualified, not hardware-qualified): `V2_1_RELEASE_STATUS.md`, the current release. This document remains the record of `v2.0.2-emu.1`, which is unchanged.

**Start here** for this release. The earlier releases are unchanged: `v2.0.1-emu.1` (sound maintenance release, `V2_MAINT_RELEASE_STATUS.md`) and `v2.0.0-emu.1` (`V2_RC_STATUS.md`).

| | |
|---|---|
| Designation | **2068-Leap V2 Enhanced v2.0.2-emu.1 — Compiler Maintenance Release** |
| Status | **emulator-qualified, not hardware-qualified**: the ROMs passed the emulator qualification below (ZEsarUX) and the release is reproducible; **physical TS2068 compatibility has not been verified** |
| Approved | by the owner, 2026-10-13 (release requested under this name; the manual-example run, the V1 legacy suite and hardware tests waived for this release, see section 3) |
| Release source | annotated tag **`v2.0.2-emu.1`** on `v2-development` (the commit that adds this file); `docs/v2-user-manual` points at the same commit |
| Previous release | `v2.0.1-emu.1` (`d19b9ea`), unchanged and reproducible from its tag (HOME `3f13ec2c...`, rebuilt and checked 2026-10-13) |
| Hardware | **NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE**: `V2_HARDWARE_CHECKLIST.md` (section 6 for this release); deferred, not a release blocker |

## 1. What changed from v2.0.1-emu.1

* **Array accesses nested in an array of the other kind are compiled correctly (M-4).** `PRINT names$(pick(0))` read the numeric array table (a wrong value, no error), `pick(1) = LEN(w$(0))` stored with the string-array opcode, and `names$(pick(0)) = "x"` or `pick(LEN(w$(0))) = 1` were rejected as `SYNTAX`. Present since `v2.0.0-emu.1`; plain subscripts and same-kind nesting were always correct. New gate case `arr-nested-kind`.
* **More memory for programs:** the program/variable pool grows from 8397 to 9211 bytes (`FREE()` on an empty machine 8153 -> 8967): the compile-only working area moved into unused fixed RAM (`RAM_EFFICIENCY_RESULTS.md`). Bytecode, package ABI 2.0 and tape formats unchanged.
* **HOME ROM reserve 19 -> 275 bytes**, with no other change to what the compiler produces: the compiler keeps its scratch values in registers instead of RAM cells wherever the calls in between preserve them (12 + 224 bytes; 20 RAM cells, 23 bytes, retired), the M-4 fix itself (14 bytes) and a dead decompiler store left out of the production build (6 bytes). Proven by a differential compile of about 2,700 programs and changed-code coverage (section 3).
* **Release bundle:** the V2 set in one archive, `2068-Leap-V2-v2.0.2-emu.1.zip` (ROMs, EightyOne cartridge `roms/leap_v2_exrom.dck`, six packages binary and `.tzx`, the manual in Markdown, Word and Word 97, the emulator guide and patches, the V2 documents, `SHA256SUMS`, `BUILD_INFO.txt`).
* Documentation: the V2 front page, the manual in three formats (now describing exactly this release), the emulator guide, the documentation layout (`docs/`, V1 in `docs/v1/`), the testing guide; tools for proving a compiler change output-neutral (`tools/qual/qdiff.py`, `qcov_changed.py`, `scan_scratch_cells.py`).

## 2. Images (`make rc-assets` -> `build/release-v2-rc/`)

| File | SHA-256 |
|---|---|
| `roms/leap_v2_home.bin` (16384) | `1fe5798f79f31e760780a7c3d1d24657a9aadf12edfa5aef5f82c94040a4f5cc` |
| `roms/leap_v2_exrom.bin` (8192) | `e6b507a49cef4d6cdd62ae09f8664f20ee84c7931a42bf67e1cf0862322641a0` |
| `roms/leap_v2_zesarux.bin` (24576, ZEsarUX only) | `c0ae3c6108668db9fc58ccd8d0ef634d7d5e600d5d0f60a1d27a8c6d1a2a4b2c` |
| `roms/leap_v2_exrom.dck` (8201, EightyOne) | `527b7960725165b3cbd97017b803a4f7fd1b08ff0ca7caeb716ad4518b412b4b` |
| packages (six) | byte-identical to `v2.0.1-emu.1` (e.g. cbeep `5b863713df1dcfcb...`); full list in the bundle's `SHA256SUMS` |

Identity CRC-16 (what `SAVE ... ALL` stamps with no package loaded): **`$F9E9`** (`v2.0.1-emu.1`: `$2CFF`). As for every ROM change, an ALL tape restores its variables only on the ROM pair that wrote it (RC-O3); program, array and package tapes are unaffected.

ROM free space: **HOME 275 bytes, EXROM 26 bytes** (`v2.0.1-emu.1`: 19 / 26).

## 3. Qualification (2026-10-13, all on the emulator)

All on images byte-identical to this release's (`1d65947`; this commit changes documents and tools only):

| Suite | Result |
|---|---|
| `make check` (incl. package ABI, 6 packages; docs; manual structure, 325 examples parsed) | pass |
| `make test`: smoke ROMs / V2 standalone | 9/9, 40/40 |
| production checks, FILL check | 0 failures |
| production regression gate / Array Store gate (incl. new `arr-nested-kind`) / known-defect suite / SAVE ALL | 114 / 101 / 15 / 13 PASS |
| `make qual` corpus | 663 PASS, 2 XFAIL (Q-24, Q-26), 2 N/A, 0 FAIL -- unchanged |
| session lifecycle | 23/23 |
| `make qual-maint`: AY BEEP / cbeep / frame interrupt unavailable / cbeep tape LOAD | 59/59, 27/27, 14/14, 3/3 |
| `make doc-examples` (the manual) | not rerun (owner decision, 2026-10-13: no documented behaviour changed); 325/325 on `v2.0.1-emu.1` |
| `make test-legacy` (V1, Fuse) | not run (owner decision); 8 of 13 on `v2.0.1-emu.1` (T-4) |
| hardware | not tested (above) |

Compiler-output proof for the register port (`7a79d68` -> `1d65947`, `docs/TESTING.md`, "Proving a compiler change leaves its output unchanged"): `qbytecode.py` 667/667 identical; `qdiff.py` 2,701 programs (the corpus, generated, mutated error-path and long chunk-boundary programs) identical in all RAM, stop point and SP, apart from the two benign cells (`FRAMES`, `EXT2_LOOKUP_NAME`); `qcov_changed.py` 82/82 changed instructions executed, 11/11 nearby branches both ways. The M-4 fix: `qbytecode.py` `cbb7eb4` -> `7a79d68` 667/667 identical (no corpus program nests arrays of different kinds).

## 4. Known limitations (documented)

* Not hardware-qualified (above).
* Unchanged from `v2.0.1-emu.1`: `PAUSE`/`BEEP` with the frame interrupt off (M-3); `CBEEP` interrupts off while sounding, border argument, one package at a time; the emulator's 50 Hz frames and 0.5 % fast AY clock (a TS2068 runs 60 Hz, not measured).
* Open, unchanged: Q-24, Q-26, RC-O1 to RC-O7, T-3, T-4 (`V2_DEFECT_REGISTER.md`).
