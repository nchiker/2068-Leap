# V2 release candidate -- physical hardware checklist

Everything about the release candidate has been verified in ZEsarUX only. **Every item below is
HARDWARE PENDING** until it has been done on a real Timex Sinclair 2068 and the result recorded
here (date, machine, ROM build CRCs, observer). The emulator is not the hardware: tape signal
timing, keyboard matrix electrics, ULA contention, AY behaviour and EPROM paging can all differ.

## 0. The images

| File | Size | Where it goes |
|---|---|---|
| `build/release-v2-rc/roms/leap_v2_home.bin` | 16384 | the HOME ROM (the TS2068's 16K system ROM socket, `$0000-$3FFF`) |
| `build/release-v2-rc/roms/leap_v2_exrom.bin` | 8192 | the EXROM (the 8K extension ROM, paged into chunk 6, `$C000-$DFFF`) |
| `build/release-v2-rc/roms/leap_v2_zesarux.bin` | 24576 | HOME + EXROM concatenated, for ZEsarUX `--romfile` only |

With every result, record the SHA-256 of both images (`build/release-v2-rc/SHA256SUMS`) and the
identity CRC-16 (`build/release-v2-rc/BUILD_INFO.txt`); `make rc-assets` makes both. For this
release candidate: HOME `dddd4cbb...e40dca`, EXROM `c1804641...fb291b527`, identity CRC `$5E95`
(the value a `SAVE ... ALL` with no package loaded stamps; full hashes in `V2_RC_STATUS.md`).
A DOCK-cartridge build does not exist (`docs/dock_cartridge.md`): the images replace the internal
ROMs (EPROMs or a ROM-replacement board).

## 1. Boot and editor

| # | Step | Expected | Result |
|---|---|---|---|
| 1.1 | Power on | editor, status bar `LINE 1/1` on row 23, flashing cursor | HARDWARE PENDING |
| 1.2 | Type a 100-character line quickly | every character appears, wrapped; no dropped keys (V1 hardware reports dropped quick taps) | HARDWARE PENDING |
| 1.3 | CAPS SHIFT + 5/6/7/8, 0, 1, ENTER | cursor, delete, delete line, insert line work | HARDWARE PENDING |
| 1.4 | SYMBOL SHIFT punctuation (`"`, `;`, `:`, `<`, `>`, `$`, `(`, `)`) | inserted as typed | HARDWARE PENDING |
| 1.5 | Hold a key | auto-repeat after ~0.7 s | HARDWARE PENDING |

## 2. Running programs

| # | Step | Expected | Result |
|---|---|---|---|
| 2.1 | `PRINT "HELLO"`, `RUN` | HELLO, any key returns | HARDWARE PENDING |
| 2.2 | `top:` / `GOTO top`, `RUN`, then CAPS SHIFT + SPACE | `BREAK`, back to the editor | HARDWARE PENDING |
| 2.3 | `PAUSE 5000`, `RUN`, BREAK | `BREAK` within a second | HARDWARE PENDING |
| 2.4 | the examples of `V2_USER_MANUAL.md` sections 3-8 | as documented (they pass in the emulator) | HARDWARE PENDING |
| 2.5 | `x = 5` `RUN`, then `: PRINT x`, `: x = 7`, `: PRINT x` | 5, then 7 | HARDWARE PENDING |
| 2.6 | float loop `FOR i = 0 TO 1 STEP 0.1` printing `i` | 11 values 0 .. 1.0000 | HARDWARE PENDING |
| 2.7 | `BEEP 1,12`; `SOUND 8,15 : SOUND 0,100 : SOUND 7,62` | beeper tone; AY tone | HARDWARE PENDING |
| 2.8 | `PRINT STICK(1)` with a joystick moved | changing values | HARDWARE PENDING |
| 2.9 | `PLOT`, `LINE`, `INK`/`PAPER`/`FLASH`/`BRIGHT` | as in the emulator | HARDWARE PENDING |
| 2.10 | `DIM a(3600)` `DIM b(900)` `b(899) = 9` `PRINT b(899)` | 9 (segment 2 RAM at `$E000`) | HARDWARE PENDING |

## 3. Tape (stock speed, a real cassette recorder)

| # | Step | Expected | Result |
|---|---|---|---|
| 3.1 | `SAVE "T"` a 20-line program; `NEW`; `LOAD "T"` | `SAVED`, `LOADED`, same program | HARDWARE PENDING |
| 3.2 | `VERIFY "T"` | `VERIFIED` | HARDWARE PENDING |
| 3.3 | after a `RUN` with variables: `SAVE "S" ALL` | a ~2.4 s pause (identity CRC) before the tones; `SAVED`; the program and variables still work after | HARDWARE PENDING |
| 3.4 | power off / on, `LOAD "S"` | `LOADED`; `: PRINT` shows the saved values; `: GOTO label` continues | HARDWARE PENDING |
| 3.5 | `VERIFY "S"` right after 3.3 | `VERIFIED` | HARDWARE PENDING |
| 3.6 | `SAVE "S" ALL` of a program with a big array (the round trip `sa-store`) | a long block; loads back | HARDWARE PENDING |
| 3.7 | a deliberately damaged recording of 3.3 (dropout) | `LOAD FAILED` (empty program), no crash | HARDWARE PENDING |
| 3.8 | SPACE during a SAVE ALL, then `: PRINT x` | `ABORTED`, variables intact | HARDWARE PENDING |
| 3.9 | `SAVE "A" ARRAY a` / `LOAD "A" ARRAY a` | array round trip; `DIM a(...)` adopts it | HARDWARE PENDING |
| 3.10 | `LOAD "shapes" EXT` from a package tape; `CIRCLE 128,96,40`; `FILL 128,96` | circle drawn, filled | HARDWARE PENDING |
| 3.11 | a V1 / stock BASIC tape | `BAD TAPE VERSION`, program intact | HARDWARE PENDING |

## 4. Machine-specific risks to look for

* EXROM paging (chunk 6) with the real MMU; FILL's use of the RAM under the EXROM while a package
  runs.
* The keyboard ISR's debounce on real switch bounce; BREAK reliability.
* Tape level / timing margins of `STORAGE_LOAD` at stock speed; a long `SAVE ... ALL` block.
* AY register access through ports `$F5/$F6`.
* Real-time speed: the emulator figures (`docs/v2/PERFORMANCE_BASELINE.md`) are uncontended
  T-states.

Record failures with the steps, the screen, and (if possible) a ZEsarUX reproduction attempt; open
them in `V2_DEFECT_REGISTER.md`.
