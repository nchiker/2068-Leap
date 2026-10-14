# V2 Enhanced release -- physical hardware checklist

**Status: NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE.** The 2068-Leap V2 Enhanced release is an
**emulator-qualified** release (accepted by the owner on 2026-10-11): everything has been verified
in ZEsarUX only, and no physical Timex Sinclair 2068 was available. Hardware qualification is
deferred, not a release blocker. The items below are neither passes nor failures; they are the
tests to run when a machine is available. Record each result here (date, machine, ROM SHA-256s and
identity CRC, observer). The emulator is not the hardware: tape signal timing, keyboard matrix
electrics, ULA contention, AY behaviour and EPROM paging can all differ.

## 0. The images

| File | Size | Where it goes |
|---|---|---|
| `build/release-v2-rc/roms/leap_v2_home.bin` | 16384 | the HOME ROM (the TS2068's 16K system ROM socket, `$0000-$3FFF`) |
| `build/release-v2-rc/roms/leap_v2_exrom.bin` | 8192 | the EXROM (the 8K extension ROM, paged into chunk 6, `$C000-$DFFF`) |
| `build/release-v2-rc/roms/leap_v2_zesarux.bin` | 24576 | HOME + EXROM concatenated, for ZEsarUX `--romfile` only |

With every result, record the SHA-256 of both images (`build/release-v2-rc/SHA256SUMS`) and the
identity CRC-16 (`build/release-v2-rc/BUILD_INFO.txt`); `make rc-assets` makes both. For this
release: HOME `dddd4cbb...e40dca`, EXROM `c1804641...fb291b527`, identity CRC `$5E95`
(the value a `SAVE ... ALL` with no package loaded stamps; full hashes in `V2_RC_STATUS.md`).
A DOCK-cartridge build does not exist (`docs/v1/dock_cartridge.md`): the images replace the internal
ROMs (EPROMs or a ROM-replacement board).

## 1. Boot and editor

| # | Step | Expected | Result |
|---|---|---|---|
| 1.1 | Power on | editor, status bar `LINE 1/1` on row 23, flashing cursor | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 1.2 | Type a 100-character line quickly | every character appears, wrapped; no dropped keys (V1 hardware reports dropped quick taps) | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 1.3 | CAPS SHIFT + 5/6/7/8, 0, 1, ENTER | cursor, delete, delete line, insert line work | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 1.4 | SYMBOL SHIFT punctuation (`"`, `;`, `:`, `<`, `>`, `$`, `(`, `)`) | inserted as typed | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 1.5 | Hold a key | auto-repeat after ~0.7 s | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |

## 2. Running programs

| # | Step | Expected | Result |
|---|---|---|---|
| 2.1 | `PRINT "HELLO"`, `RUN` | HELLO, any key returns | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 2.2 | `top:` / `GOTO top`, `RUN`, then CAPS SHIFT + SPACE | `BREAK`, back to the editor | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 2.3 | `PAUSE 5000`, `RUN`, BREAK | `BREAK` within a second | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 2.4 | the examples of `V2_USER_MANUAL.md` sections 3-8 | as documented (they pass in the emulator) | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 2.5 | `x = 5` `RUN`, then `: PRINT x`, `: x = 7`, `: PRINT x` | 5, then 7 | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 2.6 | float loop `FOR i = 0 TO 1 STEP 0.1` printing `i` | 11 values 0 .. 1.0000 | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 2.7 | `BEEP 1,12`; `SOUND 8,15 : SOUND 0,100 : SOUND 7,62` | beeper tone; AY tone | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 2.8 | `PRINT STICK(1)` with a joystick moved | changing values | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 2.9 | `PLOT`, `LINE`, `INK`/`PAPER`/`FLASH`/`BRIGHT` | as in the emulator | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 2.10 | `DIM a(3600)` `DIM b(900)` `b(899) = 9` `PRINT b(899)` | 9 (segment 2 RAM at `$E000`) | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |

## 3. Tape (stock speed, a real cassette recorder)

| # | Step | Expected | Result |
|---|---|---|---|
| 3.1 | `SAVE "T"` a 20-line program; `NEW`; `LOAD "T"` | `SAVED`, `LOADED`, same program | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 3.2 | `VERIFY "T"` | `VERIFIED` | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 3.3 | after a `RUN` with variables: `SAVE "S" ALL` | a ~2.4 s pause (identity CRC) before the tones; `SAVED`; the program and variables still work after | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 3.4 | power off / on, `LOAD "S"` | `LOADED`; `: PRINT` shows the saved values; `: GOTO label` continues | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 3.5 | `VERIFY "S"` right after 3.3 | `VERIFIED` | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 3.6 | `SAVE "S" ALL` of a program with a big array (the round trip `sa-store`) | a long block; loads back | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 3.7 | a deliberately damaged recording of 3.3 (dropout) | `LOAD FAILED` (empty program), no crash | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 3.8 | SPACE during a SAVE ALL, then `: PRINT x` | `ABORTED`, variables intact | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 3.9 | `SAVE "A" ARRAY a` / `LOAD "A" ARRAY a` | array round trip; `DIM a(...)` adopts it | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 3.10 | `LOAD "shapes" EXT` from a package tape; `CIRCLE 128,96,40`; `FILL 128,96` | circle drawn, filled | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 3.11 | a V1 / stock BASIC tape | `BAD TAPE VERSION`, program intact | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |

## 5. Maintenance release v2.0.1-emu.1: sound

For the `v2.0.1-emu.1` images (HOME `3f13ec2c...`, EXROM `24b1ebb0...`, identity CRC `$2CFF`; `V2_MAINT_RELEASE_STATUS.md`). Item 2.7 above describes the release's raw `BEEP`; on the candidate, `BEEP` is the AY note below.

| # | Step | Expected | Result |
|---|---|---|---|
| 5.1 | Power on, listen | the startup chime: C, E, G entering one after another and held, then fading (identical to the release's; `docs/maint_audio/chime_release.wav` / `chime_chimeC_L1.wav` are the emulator's 50 Hz renderings, a TS2068 plays them in five sixths of the time) | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 5.2 | `BEEP 1,0`, `BEEP 1,9`, `BEEP 1,12` with a tuner or a reference | middle C 261.6 Hz, A 440 Hz, C 523 Hz within a few cents; each **1.0 s** (60 frames at 60 Hz) | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 5.3 | `PAUSE 600` timed | 10 s (confirms 60 frames a second) | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 5.4 | `BEEP 10,0`, BREAK after 2 s | the note stops at once, `BREAK` | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 5.5 | `BEEP 0.5,-39`, `BEEP 0.5,48`, `BEEP 0.5,69` | lowest A (27.5 Hz), audible high notes; no clicks between consecutive notes of a scale (`FOR n = 0 TO 12 : BEEP 0.1,n : NEXT n`) | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 5.6 | `SOUND 7,62 : SOUND 0,200 : SOUND 1,1 : SOUND 8,10` | channel A tone, about 242 Hz (register 0 now accepted) | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 5.7 | `SOUND 2,100 : SOUND 3,1 : SOUND 9,12 : SOUND 7,56`, then `BEEP 1,12` | channel B keeps sounding under and after the BEEP | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 5.8 | `LOAD "CBEEP" EXT` from the package tape; `BORDER 2 : CBEEP 1000,0,2 : CBEEP 1000,12,2` | loudspeaker middle C then C an octave up, 1 s each; border stays red | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 5.9 | `CBEEP 5000,0,7`, BREAK during it | the note plays to the end, then `BREAK` (interrupts are off while it sounds) | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 5.10 | relative loudness of `BEEP` (AY, level 15) and `CBEEP` (loudspeaker) through the TV / monitor audio | both audible and comfortable; note the levels | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 5.11 | `PRINT STICK(1)` after the chime and after a `BEEP` | joystick still read (the mixer's I/O-port bits are kept) | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |

## 6. Compiler maintenance release v2.0.2-emu.1

For the `v2.0.2-emu.1` images (HOME `1fe5798f...`, EXROM `e6b507a4...`, identity CRC `$F9E9`; `V2_COMPILER_MAINT_RELEASE_STATUS.md`). The changes are in the compiler and the RAM layout, with nothing timing- or hardware-specific: sections 1-5 apply as they stand; record results against these images. Two quick checks of this release's own changes:

| # | Step | Expected | Result |
|---|---|---|---|
| 6.1 | `NEW`, the one-line program `PRINT FREE()`, `RUN` | 8967 (pool 9211 bytes) | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |
| 6.2 | the program `DIM n$(3)`, `DIM p(3)`, `n$(2) = "abc"`, `p(0) = 2`, `PRINT n$(p(0))`, `n$(p(0)) = "xy"`, `PRINT LEN(n$(2))` (one statement per line), `RUN` | `abc`, then `2` (M-4; checked in ZEsarUX) | NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE |

## 4. Machine-specific risks to look for

* EXROM paging (chunk 6) with the real MMU; FILL's use of the RAM under the EXROM while a package
  runs.
* The keyboard ISR's debounce on real switch bounce; BREAK reliability.
* Tape level / timing margins of `STORAGE_LOAD` at stock speed; a long `SAVE ... ALL` block.
* AY register access through ports `$F5/$F6`.
* Real-time speed: the emulator figures (`docs/PERFORMANCE_BASELINE.md`) are uncontended
  T-states.

Record failures with the steps, the screen, and (if possible) a ZEsarUX reproduction attempt; open
them in `V2_DEFECT_REGISTER.md`.
