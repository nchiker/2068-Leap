# BEEP, SOUND and MODE: compatibility review (V2 Enhanced, emulator-qualified release)

Written for the owner during the documentation work (branch `docs/v2-user-manual`). **The accepted release ROM was not changed.** The only code written is a throwaway prototype on the study branch `study/beep-compat` (worktree `~/2068-Leap-study/beep-compat`, commit `ccb78a4`, based on the tag `v2.0.0-emu.1`), built only with explicit `-DV2_STUDY_*` switches. Evidence: source code, the real TS2068 ROM running in ZEsarUX (`~/Applications/ZEsarUX-13.0/ts2068.rom`, identical in its 16 KB HOME part to Fuse's `tc2068-0.rom` and EightyOne's `ts2068.rom`), and the release image in the same emulator.

## Decisions needed from the owner

1. **BEEP**: adopt the Sinclair-compatible `BEEP seconds,semitones`? Measured cost: HOME **+5 bytes** (54 -> 49 free) and EXROM **+154 bytes** (25 -> -129): it only fits if the **startup chime (135 bytes of EXROM) is removed** (EXROM then 9 bytes free), or replaced by something very small and 20 more bytes are found. Choose: (A) compat BEEP and no chime; (B) compat BEEP and a minimal chime plus about 20 bytes of other savings; (C) keep the raw BEEP and document the difference (done in the manual, with a BASIC procedure that gives Sinclair's `BEEP`).
2. **SOUND**: accept register 0 like the stock ROM? Cost: **-3 bytes** (a saving). Recommended whatever is decided for BEEP.
3. **MODE**: nothing to change in the ROM; the naming in the ROM source ("High Resolution Graphics") is wrong. Offer the 512 x 192 mode (port value 6)? Not requested; no cost estimate beyond "new code".

## 1. BEEP

### 1.1 What the stock ROM does (measured)

The stock `BEEP duration,pitch` (ROM `$0436`) takes seconds and semitones above middle C. I drove the real routine in the emulator: the two numbers were put on the calculator stack, the routine was run, and the arguments it passes to its `BEEPER` (`$03F3`: HL = period, DE = cycles) were read. Results (`tools/study/beep_stock_oracle.json` on the study branch):

| BEEP seconds,semitones | HL | DE | frequency 3.5 MHz / (8 HL + 241) |
|---|---|---|---|
| 1,0 | 1642 | 261 | 261.64 Hz |
| 1,12 | 806 | 522 | 523.25 |
| 1,-12 | 3314 | 130 | 130.83 |
| 1,9 | 964 | 439 | 440.09 |
| 0.5,0 | 1642 | 130 | |
| 2,0 | 1642 | 522 | |
| 1,24 | 388 | 1046 | 1046.34 |
| 1,-24 | 6659 | 64 | 65.40 |
| 1,60 | 22 | 8371 | 8393 |
| 1,-60 | 53481 | 7 | 8.18 |
| 0.1,0 | 1642 | 25 | |
| 1,0.5 | 1595 | 268 | 269.21 (fractional semitones are supported) |
| 3,7 | 1086 | 1175 | 391.98 |

So: **cycles = int(f x seconds)**, **HL = int(437500 / f - 30.125)** (437500 = 3.5 MHz / 8; 30.125 = 241 / 8), with f = 261.63 x 2^(semitones/12), semitones from -60 to 69 (`BEEP 1,-61` goes to the error handler at `$11F2`). The ROM's beeper loop runs `8 HL + 241` T-states per cycle: measured 3 497 463 T-states for (1642, 261), i.e. a nominal second at 3.5 MHz. The routine disables interrupts while it sounds. On a TS2068 (3.528 MHz) this makes every stock note about 0.8% sharp.

### 1.2 V2 and its history

V2's `BEEP` is `OP_BEEP` in `rom/exrom_v2_vm_core.asm` (HOME): it pops the two numbers (floats truncated) and calls `SOUND_BEEP` in `kernel/sound/sound.asm`, which toggles port `$FE` bit 4 (the loudspeaker; **not** the AY chip) for *duration* cycles with a `pitch`-step delay per half-cycle. The kernel's header states the choice: it is "**deliberately NOT a port of the real ROM's BEEPER**", exposes "the period/cycle-count directly as BASIC-level parameters -- narrower than the real command, honestly scoped rather than presented as authentic", because the test environment had no audio and note-table maths needed the calculator. V1's manual documents the raw counts. V2 inherited this unchanged (R7 Phase 2 transcribed it); no V2 document records a decision to keep it. `V2_FEATURE_MATRIX.md` and the language specification do not mention it. Measured on the release: one cycle takes exactly `222 + 52 x pitch` T-states (5 421 600 T-states for `BEEP 1000,100`).

### 1.3 Leap-Forth

`~/2068-forth/core/beep.asm` implements Sinclair semantics: `BEEP ( n-semitones fduration -- )` with **integer** semitones (fractions deliberately not supported) and a float duration in seconds. It reproduces the real ROM's musical maths (a 12-entry ratio table, the octave applied by adding to the float exponent, cycles = f x duration) but **recalibrates** the final step to the kernel loop, from instruction timings: `pitch = (3 528 000 / f - 222) / 52`, minimum 1, using the TS2068's real clock. It uses the same `SOUND_BEEP` kernel routine as V2 (the kernel is shared), so the hardware path is the beeper port, not the AY. Its code (`SEMITONE_TABLE`..`W_BEEP`, ROM `$1AA2-$1C4F`) is about **430 bytes** and is written on Forth's own float words (`FPUSH`, `W_FSTAR`, `W_FSLASH`), which have a different number format from V2's 5-byte Sinclair calculator: **the code cannot be reused; the algorithm and the constants can.** Forth's maths was not taken on trust: its formulas were reproduced in V2 and checked against the stock-ROM table above (section 1.5). Its own header states that none of it has been heard on a speaker.

### 1.4 Prototype and measured cost

`BEEP_COMPAT` (EXROM, `rom/exrom_sound.asm`) plus a small HOME stub, written against V2's reduced calculator (add, subtract, multiply, divide, exchange, duplicate, delete, end; `CALC_INT_TO_FP`, `CALC_FP_TO_INT`, `CALC_PUSH_FP_RAW`):

* semitones are truncated to whole numbers and range-checked (-60..69, else run-time error 15, as the stock ROM errors);
* f is built from 261.6256 by n multiplications by 2^(1/12) (a 5-byte constant) and the octave is added to the float's exponent (no 12-entry table);
* the stack keeps `[K f]` with K = 3 528 000 / 52, so `K / f - 222/52` is the pitch (`BEEP_4` = 222/52) and `f x seconds` the cycle count (truncated); pitch is at least 1; a negative duration plays nothing;
* it ends by jumping to the unchanged `SOUND_BEEP`.

**Measured** (assembled; `make budget`-style report on the study build):

| | HOME | EXROM |
|---|---|---|
| old `OP_BEEP` | 10 | -- |
| new `OP_BEEP` stub (pop pitch, pop duration into `VM_FLOAT_B`, call the slot) | 15 (**+5**) | -- |
| `BEEP_COMPAT` | -- | 148 (including 15 bytes of constants) |
| the EXROM entry slot (`call V2_VERIFY_KTAB` + `jp`) | -- | 6 |
| **net** | **+5** (54 -> 49 free) | **+154** (25 -> -129) |
| remove the startup chime (`STARTUP_CHIME`, `CHIME_TABLE`, `CHIME_DELAY`, `$D299-$D31F`) | -- | -135 |
| **with the chime gone** | **49 free** | **9 free** (12 with the SOUND change) |

**RAM**: none. The duration is parked in the existing `VM_FLOAT_B_TAG/VAL` cells, the calculator stack is the existing one, no sysvar is added.

Why EXROM and not HOME: HOME has 54 bytes free, the routine is 148; EXROM has the calculator, and the VM already reaches EXROM services through fixed slots. (The VM, compiler and kernel are in HOME; the shell, editor and calculator are in EXROM.) Cheaper shapes were examined and are not smaller: an integer-only formulation needs two 12-entry 16-bit tables (48 bytes) plus 24-bit shifts and ends at about the same total.

Estimated savings that are not assumed: the three constants could be merged by changing the algorithm (a few bytes), the range check could be dropped (13 bytes, but then an out-of-range pitch plays nonsense instead of erroring), fractional semitones would **add** about 25 bytes.

**What would have to give.** The only block of EXROM that big which is not language is the boot chime. A replacement chime of three beeper notes (a three-entry table and a loop, about 26 bytes) saves about 109 of the 135, leaving the build 17 bytes short (EXROM 9 - 26); the extra 17 would come from the SOUND change (-3), the unreachable `EDITOR_BLOCK_DELETE` (3, `RC-O7`) and about 11 more found elsewhere (not measured). Moving the sprite capture/draw services into the sprite package (the budget document's option) gives 60 to 120 bytes of HOME but is a package ABI major change.

### 1.5 Accuracy of the prototype against the stock ROM

(`python3 tools/study/beep_check.py`; frequencies compare the stock ROM at its nominal 3.5 MHz with the prototype at the TS2068's 3.528 MHz.)

| BEEP seconds,semitones | stock Hz | V2 Hz | difference | cycles stock / V2 |
|---|---|---|---|---|
| 1,0 | 261.64 | 261.68 | +0.01% | 261 / 261 |
| 1,12 | 523.25 | 524.84 | +0.31% | 522 / 523 |
| 1,-12 | 130.83 | 130.91 | +0.06% | 130 / 130 |
| 1,9 | 440.09 | 442.66 | +0.58% | 439 / 439 |
| 1,24 | 1046.34 | 1055.66 | +0.89% | 1046 / 1046 |
| 1,-24 | 65.40 | 65.41 | +0.01% | 64 / 65 |
| 1,60 | 8393.29 | 9333.33 | **+11.2%** | 8371 / 8372 |
| 1,-60 | 8.18 | 8.18 | 0.00% | 7 / 8 |
| 1,0.5 | 269.21 | 261.68 | **-2.8%** (fraction cut off) | 268 / 261 |
| 3,7 | 391.98 | 393.84 | +0.47% | 1175 / 1175 |

* **Durations** match to within one cycle. The real durations differ by the clock ratio: stock BEEP of 1 second lasts 0.992 s on a 3.528 MHz machine, the prototype 0.9975 s (it is calibrated to the real clock; the emulator runs a 3.5 MHz clock).
* **Pitch** is within 1% up to about three octaves above middle C and then degrades, because the kernel loop moves in **52 T-state steps** (the stock beeper in steps of 8): at +60 the nearest step is 11% sharp. Notes above about +36 are coarse. Fixing this would mean a finer loop in `SOUND_BEEP` (HOME, shared with other projects): not part of this proposal.
* **Fractional semitones** are not supported (truncated toward zero); the stock ROM interpolates. Adding it costs about 25 bytes.
* Because V2 uses the real clock the **pitch is on target on a TS2068**, where the stock ROM is 0.8% (14 cents) sharp. This is a (small, deliberate) difference from stock.

### 1.6 Effects on interrupts, timing and other commands

* Interrupt handling is **unchanged**: `SOUND_BEEP` still does `DI` for the duration and `EI` at the end, exactly like the stock `BEEPER`. A long BEEP (up to the stock 10-second limit) therefore stops the frame counter and BREAK for its whole length; today's raw `BEEP` already does this (the manual says so).
* `SOUND` (AY), `PAUSE`, `OUT`, the startup of tapes and the printer are untouched. (The chime uses `SOUND_EXROM`; removing it affects nothing else.)
* **Compatibility break for programs**: any existing `BEEP n,m` changes meaning. The owner's compatibility policy permits this for real savings; here it is a correctness change. The corpus has one BEEP case (`hw.beep`: `BEEP 1,0`, which still passes, now sounding for a second); the V1 fixture `tests/snd1.txt` is not part of V2. The documentation examples (`kw.beep.1`, `con.sound.1`, `guide.sound.1`) would be rewritten.
* The prototype build passes the 15 `hw.*` corpus cases (BEEP, SOUND, PEEK/POKE/IN/OUT/STICK ...).

### 1.7 Required tests if it is adopted

1. A stock-ROM **oracle** test: the table of section 1.1 (checked in as data) compared with the arguments captured at `SOUND_BEEP` (tolerances: cycles +-1, frequency +-1% up to +36 semitones, documented wider above).
2. **Duration**: T-states of `BEEP s,p` within 1% of `s` x CPU clock, for several notes and lengths.
3. **Range**: `BEEP 1,70` and `BEEP 1,-61` give run-time error 15; `BEEP 0,p` and a negative duration play nothing and do not hang; float expressions as arguments (`BEEP 1/2, 12/1`) work.
4. **Interrupts**: frame counter stalls during and resumes after; BREAK is not lost after the sound.
5. **No side effects**: calculator stack and `FREE()` unchanged by a `BEEP`; `SOUND`, `PAUSE` still pass; the 667-case corpus and the lifecycle suite.
6. If the chime is replaced: a boot test that the editor comes up and (emulator) three beeper transitions occur.
7. Update the manual's `BEEP` entry and its tests.

### 1.8 Recommendation

Adopt the Sinclair semantics as in the prototype (section 1.4) **if the owner accepts losing the startup chime** (option A): it is a localized change, no RAM, the HOME reserve stays above 49 bytes, the EXROM reserve drops from 25 to 9 (12 with the SOUND fix), and it makes `BEEP` do what the TS2068 manual says. If the chime must stay, option B needs about 17 further bytes that have not been identified and measured. Until a decision, the manual documents the raw behaviour and ships a BASIC procedure (`sbeep`, tested against the same oracle) that gives the Sinclair behaviour on the release as it is.

## 2. SOUND

**The stock ROM** (HOME `$2127`, "SOUND Command Routine"): after evaluating the two arguments it does `CP $11 / JP NC,REPORT-C` (error if the register is 17 or more), then `DEC A / INC A / JP M,REPORT-C`, then `OUT ($F5),A` with the register number **unchanged**, then `OUT ($F6),A` with the data. I ran the validation code of the real ROM in the emulator (set `A` to the register at `$2137`, run to the `OUT` at `$2141` or the error at `$1BED`):

| register | stock ROM |
|---|---|
| 0 | accepted |
| 1, 15, 16 | accepted |
| 17, 20, 255 | rejected (`REPORT-C`) |

so the stock command accepts **0 to 16** and writes the register number straight to the chip. (The `DEC A / INC A / JP M` pair tests nothing for zero: `INC A` restores the value, so only values of 128 and above, already excluded, could set the sign flag.)

**V2** (`SOUND_EXROM`, `rom/exrom_sound.asm`, machine code `78 B7 28 0B FE 11 30 07 D3 F5 79 D3 F6 B7 C9 37 C9`): `ld a,b / or a / jr z,bad / cp 17 / jr nc,bad / out ($F5),a / ld a,c / out ($F6),a`. It also writes the register unchanged, but **rejects 0** (`or a / jr z`): accepted range **1 to 16**. Verified on the release: `SOUND 0,5` is a run-time error; `SOUND 16,5` is accepted (and writes a register that does not exist, as in the stock ROM); `SOUND 17,5` is rejected.

**Discrepancy**: only register 0 -- channel A's fine pitch -- is unreachable in V2. (The V1 source, the V1 manual and Leap-Forth all describe the stock range as "1-16"; the real ROM does not reject 0. The comment at the V2 chime says register 0 "can never be reached" and writes it with raw `OUT`s: that workaround is the visible symptom.) The user-visible effect: channel A cannot be tuned in fine steps with `SOUND`.

**Fix (not applied)**: delete `or a / jr z,.bad_register` (3 bytes of EXROM saved); with it the chime's special case for register 0 (8 bytes) could become one table entry. Prototype: `-DV2_STUDY_SOUND0` on the study branch: `SOUND 0,5` accepted, 16 accepted, 17 still `ve=8`. No effect on anything else. In the manual: the keyword `SOUND` states the discrepancy and the `OUT 245,0 : OUT 246,value` workaround.

## 3. MODE

**Published TS2068 documentation** (port `$FF`, "SCLD display enhancement control": [Timex I/O ports](https://loadzx.com/timexcomputerworld/timex-io-ports/) and the [port map](https://k1.spdns.de/Vintage/Sinclair/82/Timex%20Sinclair%202068/Tech%20Specs%20and%20Repair/port%20map.txt); the technical manual PDF was listed by the search but its bit tables were not retrieved): bits 2..0 select the video mode:

| bits 2..0 | value | mode |
|---|---|---|
| 000 | 0 | ordinary: pixels at 16384, 8 x 8 attributes at 22528 |
| 001 | 1 | second display file: pixels at 24576, attributes at 30720 |
| 010 | **2** | **extended colour ("multicolor") mode**: pixels at 16384, **8 x 1 attributes at 24576** |
| 110 | **6** | **extended resolution**: 512 x 192, two colours (even columns from 16384, odd from 24576; ink and paper from bits 5..3) |

Bit 6 inhibits the 17 ms interrupt, bit 7 selects the EXROM or the cartridge bank (the sources disagree on which value is which; V2 relies on its own use).

**V2** (`GFX_SET_MODE`, `kernel/graphics/graphics.asm`): `MODE 1` keeps the other bits of the port copy `PORT_FF_SHADOW`, sets bits 0..2 to **2** and fills the 6144 bytes at `$6000` with the default attribute; `MODE 0` clears them. Measured on the release (package loaded through the tape loader): after `MODE 1` the port copy is `$82`; after `INK 2 : PAPER 6 : PLOT 100,100` exactly **one** byte at `$6000 + 100 x 32 + 12` holds the new attribute while the ordinary attribute area `$5800` is untouched. So V2's mode 1 **is the extended-colour mode (value 2)**; every drawing statement colours an 8 x 1 strip. It is **not** the 512-pixel mode. The source (`graphics.asm`, `hardware.inc`) and a V1-era comment call it "High Resolution Graphics"; that name is wrong for the hardware. The earlier 64-column mode (value 6) was removed from the ROM on 2026-08-20; `MODE` accepts only 0 and 1 and the ROM's printing and drawing do not support value 6.

**Manual corrected**: `MODE`'s keyword entry and the mode-package chapter now describe the extended-colour mode, with a picture (eight differently coloured lines in one row of character cells, rendered from the `$6000` attribute area), state that the 512 x 192 mode is not offered, and note that the ROM's source uses the other name. `V2_LANGUAGE_REFERENCE.md` and the findings file say the same. Not checked on hardware.

## 4. Documentation changes made for this review

* `docs/v2/manual/03_keywords.md`: `BEEP` (seconds/semitones difference, the compat procedure `sbeep` with oracle-checked examples, 222 not 220), `SOUND` (the register-0 discrepancy and the `OUT` workaround, register table gains register 0), `MODE`.
* `docs/v2/manual/05_packages.md`: the `MODE` section rewritten, new example `pkg.mode.5` with a picture.
* `docs/v2/manual/04_concepts.md`: *Sound* and *Speed* updated.
* `docs/v2/V2_LANGUAGE_REFERENCE.md`, `V2_DOCUMENTATION_FINDINGS.md` (A7, A8, A22, B1, B3 resolved), this file; the DOCX regenerated.
* `tools/qual/manual_run.py` renders pictures in the extended-colour mode from the `$6000` attribute area.

## 5. Test results

* Manual-example suite (`tools/qual/manual_run.py`): **317 of 317 examples pass** on the release image.
* `tools/check_manual.py` (keyword coverage against the ROM tables, links, figures): passes.
* `make check`: passes, and the rebuilt ROMs have the accepted SHA-256 sums (HOME `dddd4cbb...e40dca`, EXROM `c1804641...291b527`).
* `make qual` (the release baseline, run again after all documentation changes): **663 PASS, 2 XFAIL (Q-24, Q-26), 2 N/A; session lifecycle 23 of 23.** No ROM, kernel, include or baseline file differs from `v2-development`.
* Prototype only (study branch): oracle comparison of section 1.5; the 15 `hw.*` corpus cases (BEEP, SOUND, PEEK/POKE/IN/OUT/STICK ...) pass; `SOUND 0,5` accepted with the register-0 change.

## 6. Open items

* The stock ROM's behaviour for `BEEP` with durations above 10 s or fractional pitches at the edges was not fully characterised (the emulator session used for those probes went into the error handler); the section 1.1 table covers the accepted range.
* Nothing was listened to or tried on hardware (Appendix G of the manual).
