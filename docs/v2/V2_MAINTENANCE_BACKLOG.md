# V2 maintenance backlog (proposed; nothing here is started)

Recorded by the owner at the close of the documentation session (2026-10-11). The accepted release (`v2.0.0-emu.1`) stays as it is until a maintenance release is opened; these are the items the owner asked to be done in it. Evidence and measurements: [`V2_BEEP_SOUND_MODE_COMPATIBILITY.md`](V2_BEEP_SOUND_MODE_COMPATIBILITY.md); the study prototype is on the isolated branch `study/beep-compat` (commit `ccb78a4`).

## M-1. Sinclair-style `BEEP seconds,semitones`, keeping a startup chime

* **Owner's preference:** Sinclair-style `BEEP` (integer semitones, as Leap-Forth; the prototype is accurate enough for normal musical use) **while preserving a startup chime, possibly a smaller one**. Do not simply drop the chime.
* **Open problem -- about 17 bytes of EXROM.** The prototype (HOME +5, EXROM +154) fits only without the 135-byte chime. With a small replacement chime (about 26 bytes: three beeper notes through the existing `SOUND_BEEP`, a three-entry table and a loop) the build is about **17 bytes short** (EXROM 9 free - 26). Candidate sources, none yet applied or fully measured: the `SOUND` register-0 change (-3, item M-2; also removes the chime's register-0 special case), the unreachable `EDITOR_BLOCK_DELETE` (3 bytes, `RC-O7`), a further shrink of `BEEP_COMPAT` itself (merging constants; dropping the range check saves 13 but loses the error), and about 11 more to be found elsewhere in EXROM; the larger lever is moving the sprite capture/draw services into the sprite package (60-120 HOME bytes, a package ABI major change).
* Also in scope: a boot test for the replacement chime; the oracle, duration, range, interrupt and no-side-effect tests listed in the report (s1.7); update the manual's `BEEP` entry (the BASIC `sbeep` procedure becomes unnecessary) and its examples.
* Not in scope unless asked: fractional semitones (about +25 bytes), a finer loop in `SOUND_BEEP` for very high notes (HOME, shared with other projects).

## M-2. `SOUND` accepts register 0

Owner favours the fix (stock TS2068 BASIC accepts 0 to 16). Delete `or a / jr z,.bad_register` in `SOUND_EXROM` (**-3 bytes**); the startup chime's raw `OUT` for register 0 can then become a table entry. Add tests: `SOUND 0,x` accepted (port write seen), 16 accepted, 17 rejected. Update the manual's `SOUND` entry.

## M-3. `MODE` source terminology

Owner favours correcting it: the ROM source (`kernel/graphics/graphics.asm`, `include/hardware.inc`, comments and symbol names) calls `MODE 1` "High Resolution Graphics", but port `$FF` value 2 is the TS2068's **extended-colour (multicolor) mode** (8 x 1 attributes at `$6000`); the 512 x 192 mode is value 6 and is not offered. Comment/name changes only (no code bytes), then rebuild and check the images are byte-identical if only comments change.

## Handoff: state at the end of the documentation session

* Branch `docs/v2-user-manual` (based on `v2-development` 170550e), not merged, not pushed: the V2 manual (`docs/v2/manual/`), the corrected language reference, README, findings, the BEEP/SOUND/MODE report, this backlog, the Word edition, and the documentation-example suite (`make doc-examples`: 317 examples, separate from the 1010-case baseline).
* Reproduce: `make build v2-packages`, `make doc-examples`, `make check`, `make qual`; timing figures: `python3 tools/qual/manual_measure.py`.
* Open owner-level questions are in `V2_DOCUMENTATION_FINDINGS.md` section B (not edited into `V2_DEFECT_REGISTER.md`); the manual documents the release as it is, with the discrepancies stated.
