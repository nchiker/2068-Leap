# V2 maintenance study: BEEP ROM recovery and the ClassicBEEP package

Branch `study/classicbeep` (worktree `~/2068-Leap-study/classicbeep`), based on the AY BEEP study `study/ay-beep` (`c48a85c`, itself on the release tag `v2.0.0-emu.1`). Local only: nothing merged, pushed or tagged. `v2-development`, `docs/v2-user-manual`, the tag, the release images and the qualification baseline are untouched; `make build EXTRA_DEFS=` still produces the accepted images (HOME `dddd4cbb...`, EXROM `c1804641...`, checked). The owner's brief for this study was received cut off in its section 6; sections 1-6 were carried out and the rest follows the previous study's conventions (isolated branch, local commits, a written report).

Inputs: `V2_AY_BEEP_STUDY.md` (this branch), `V2_BEEP_SOUND_MODE_COMPATIBILITY.md` and `V2_MAINTENANCE_BACKLOG.md` (on `docs/v2-user-manual`), `PACKAGE_ABI.md`, `include/v2_package_abi.inc`, `kernel/extensions/ext_registry.asm`, the release and candidate listings.

**Results.**

1. **The original software beeper is already gone from the AY candidate.** `SOUND_BEEP` (55 bytes, HOME) had one caller, the old `OP_BEEP` (10 bytes); the AY study removed both. Its 65 bytes are already counted in the candidate's HOME 13 / EXROM 20 free. Nothing else of it remains to remove.
2. **One consolidation is worth taking: a shared frame wait.** `PAUSE`, `BEEP` and the chime now use one 12-byte wait in HOME. It gains HOME **+6** and EXROM **+6** bytes (candidate 13/20 -> **19/26**). BREAK now ends a long `BEEP`, which was costed at +6 bytes in the AY study. It also fixes a `PAUSE` defect found here: a pause that crossed the 16-bit frame counter's wrap ended at once. The chime is unchanged: the same register writes in the same frames.
3. **ClassicBEEP works as a package, under ABI 2.0 as released, with two limits.** The name can be at most 8 characters, so it is **`CBEEP`**. Arguments are 16-bit integers, so the duration is given in **milliseconds**.
   - **Default build (ABI 2.0, no ROM change):** `CBEEP ms,semitones,border`, **260 bytes**. Sinclair semitones (-60..69) are converted in integers, and the sound comes from V2's original `SOUND_BEEP`, assembled into the package unchanged.
   - **Border argument:** a package cannot read V2's border colour today, and every write to port `$FE` also sets the border.
   - **Two-argument alternative:** `CBEEP ms,semitones` needs one read-only pin added to the ABI (a minor version, 2.1). It costs **0 ROM bytes** and was built and tested in a copy, not adopted.
   - The old raw design (`CBEEP cycles,pitch,border`) is 107 bytes.

## 1. Baseline (measured on this branch's builds)

| Build | HOME free | EXROM free | HOME / EXROM SHA-256 (first 16) |
|---|---|---|---|
| release (`EXTRA_DEFS=`) | 54 | 25 | `dddd4cbba2e74e4d` / `c180464120cb94af` |
| AY candidate, chime C (`study/ay-beep` default) | 13 | 20 | `f2e3a3cc86bc93b9` / `3ebba2c802e723fc` |
| **this branch's default: AY candidate + shared wait** | **19** | **26** | `3f13ec2cc4ef02c1` / `24b1ebb0b1377aad` |
| chime B (arpeggio) + shared wait, for reference | 47 | 38 | |

Chime option C stays the baseline (the original chord, same writes and frames as the release, plus one inaudible R6 write); the chime was not touched to recover space.

## 2. The original V2 software beeper

**What and where.** `SOUND_BEEP` (`kernel/sound/sound.asm`) toggles port `$FE` bit 4 (the loudspeaker), one cycle = `222 + 52 x pitch` T-states, `DI` while it sounds. In the release it is HOME `$0E61-$0E97`, **55 bytes**, with a private subroutine `.half_cycle`. It keeps the border and MIC bits through the shadow cell `PORT_FE_SHADOW` (`$8109`), which it shares with `BORDER` and the tape routines.

**Call graph (release, from the listings and a byte search of both images):**

```
compiler: BEEP a,b -> opcode 29 (EMIT_OP_BEEP)
VM table entry 29 -> OP_BEEP ($1F02, 10 bytes) -- call SOUND_BEEP ($1F07)  <- the only call
                                                  SOUND_BEEP ($0E61, 55 bytes) -> port $FE
```

* `CD 61 0E` occurs once in HOME (`$1F07`); no `jp`, no table entry, no reference in EXROM.
* Port `$FE` writers in the release: `GFX_SET_BORDER` (HOME), `SOUND_BEEP` (two `out`s), and `STORAGE_SEND_BLOCK` / `STORAGE_RECEIVE_BLOCK` (EXROM, tape). There is no keyboard click and no diagnostic or startup use of the beeper; the startup chime is AY.
* Not exposed by the package ABI (none of the 16 service slots), not an EXROM slot, no tables or variables of its own. `PORT_FE_SHADOW` is shared and stays.
* The legacy V1 chain (`basic/basic.asm`) and 36 test ROMs still include or stub `SOUND_BEEP`; they are not production images and keep the kernel file.

**In the AY candidate:** `rom/v2_home.asm` assembles `kernel/sound/sound.asm` only `IFNDEF V2_MAINT_AY_BEEP`, and `OP_BEEP` is the AY version. The candidate's listings have no `SOUND_BEEP`; the only port `$FE` writers left are `GFX_SET_BORDER` and the tape routines (checked the same way). The recovery (55 + 10 = 65 bytes) is already part of the AY study's "BEEP net +100" and of the 13/20 baseline: **no further bytes can be recovered from the software beeper.** Tape, keyboard, startup, interrupts and the package ABI do not depend on it (section 7: the tape, editor, BREAK, package and lifecycle suites pass).

## 3. ROM recovery

| Change | HOME | EXROM | Status |
|---|---|---|---|
| remove `SOUND_BEEP` + old `OP_BEEP` | -65 | 0 | already in the AY candidate |
| shared frame wait (section 4) | **-6** | **-6** | adopted (branch default) |
| **net from the AY candidate** | **13 -> 19 free** | **20 -> 26 free** | |

RAM: no change (no new cell). Layout: the EXROM entry slots and the ABI service-slot positions do not move. HOME code after `OP_PAUSE` moves down 18 bytes; the service slots' `jp` targets follow, as on every HOME change. `INT_GET_FRAMES` (4 bytes in the RST-slot padding at `$000B`) is no longer used and is removed, so that padding gap is free again. Its use in the kernel is kept for the test ROMs.

## 4. AY BEEP consolidation review

**Adopted: one frame wait for PAUSE, BEEP and the chime** (`V2_MAINT_SHARED_WAIT`, `rom/v2_ay_beep.asm`, `OP_PAUSE`):

```
AY_WAIT_FRAMES:          ; DE frames; BREAK ends it early (A <> 0)
    ld   a, (VM_HALTED)
    or   a
    ret  nz
    halt
    dec  de
    ld   a, d
    or   e
    jr   nz, AY_WAIT_FRAMES
    ret                  ; 12 bytes, HOME
```

| | Before | After |
|---|---|---|
| `OP_PAUSE` (n > 0 path) | 29 bytes: target = `FRAMES` + n, poll `INT_GET_FRAMES`, BREAK check | 11 bytes: `ex de,hl` / `call AY_WAIT_FRAMES` / `jp (iy)` |
| `AY_WAIT_FRAMES` | 7 bytes, EXROM | 12 bytes, HOME (now with the BREAK check) |
| `AY_BEEP_PLAY` | ends with `out (c),a` (A = 0 from the wait) | `xor a` first (+1): the wait may return A <> 0 |
| **net** | | **HOME -6, EXROM -6** |

Behaviour:

* **BREAK now ends a `BEEP`** with error 66 and channel A silenced. Before, the note played out and the program stopped afterwards. The AY study had costed this at +6 bytes; it now comes with a saving. The chime runs before any program, and the cold start zeroes `$8000-$BFFF` first, so the BREAK flag is clear at that point. The chime trace from a cold start is identical to the AY candidate's.
* **`PAUSE n` wrap defect fixed.** Old `PAUSE` waited until `FRAMES >= FRAMES0 + n` in 16 bits. Whenever `FRAMES0 + n` passed 65535 the target wrapped and the pause ended at once. Measured on the AY candidate (same code as the release): `PAUSE 20` with `FRAMES = 65530` returned after **0** frames. With the shared wait it is **20** frames, as from `FRAMES = 1000`. The chance of hitting this is n / 65536 per `PAUSE`, for example about 5% for a one-minute `PAUSE 3000`. It is not in the defect register or the manual; record it as a release defect fixed by this change.
* `PAUSE` now waits with `HALT` instead of polling `FRAMES`. Timing is the same (n display interrupts; the first may be partial, as before). BREAK during `PAUSE` still stops the program (real keyboard matrix, error 66). `PAUSE 0` (wait for a key) is unchanged. With the frame interrupt switched off, `PAUSE` hangs, as it already did and as `BEEP` does.

**Examined and not taken (measured or counted from the instruction sizes):**

| Idea | Result |
|---|---|
| `AY_BEEP_PLAY` writing R0, R1, R8 through `SOUND_EXROM` | `ld b,n` / `ld c,r` / `call` = 6 bytes per write instead of 5; and the R7 read-modify-write cannot use it: **+3**, rejected |
| `jr` instead of `jp` to the range error in `OP_BEEP` / `AY_BEEP_PERIOD` | `VM_ERR_RANGE` (`$231C`) is 1.3 KB / 1.2 KB away: not reachable |
| one range check for duration and pitch | different ranges, different code paths (calculator result vs integer): no shared form |
| calculator use in `OP_BEEP` | already the shared slots (`VM_FLOAT_PUSH_FIRST`, `CALC_INT_TO_FP`, `VM_CALC_MUL_STUB`, `CALC_FP_TO_INT`); no duplicate |
| VM argument handling | `rst $18` / `rst $10`, the shared pop routines; nothing to merge |
| chime C | already shares `SOUND_EXROM` and the wait; its loops cannot use `AY_BEEP_PLAY` without becoming the arpeggio (option B) |
| moving `AY_BEEP_PLAY` to HOME to drop the 9-byte EXROM slot | needs 41 HOME bytes: does not fit with chime C |

All established AY BEEP behaviours are unchanged, with one exception: BREAK now ends a note early. The others are syntax, fractional durations, range -60..69, fraction cut-off, A0 clamp, channel A policy, interrupts on, and SOUND register 0. The focused suite passes on the new default (section 7).

## 5. Can the extension mechanism carry ClassicBEEP?

**Yes, as a statement package with no HOME change. Three ABI facts shape it:**

1. **Names are at most 8 characters.** `EXT2_REGISTER` stores 8 (`EXT2_REC_LEN` = 14, `[gen][len][name:8][exec:2]`), and `EXT2_LOOKUP` matches only a token of exactly the stored length. So `CLASSICBEEP` (11) can never be found: registered, it becomes "CLASSICB" and the typed word does not match. Changing that is a HOME registry/ABI change, so the package is named **`CBEEP`** (`CLASBEEP`, `BEEPER` or `SPKBEEP` would also fit; it is one string in the source). `CBEEP` is matched case-insensitively and does not clash with the keyword `BEEP` (tested).
2. **Arguments are 16-bit integers.** `OP_CALL_EXT` pops each argument with `VM_POP_ADDR`, truncating a float. A package cannot call the calculator, because EXROM is paged out while it runs. Fractions of a second therefore cannot reach it, so the duration is in **milliseconds** (0..32767): Sinclair's `BEEP 0.5,0` is `CBEEP 500,0,...`. Semitones are whole numbers anyway (the AY `BEEP` cuts fractions too).
3. **The border colour is not visible to a package.** Every `OUT ($FE)` sets the border (bits 0-2) along with the speaker bit. V2 keeps the current value in `PORT_FE_SHADOW` (`$8109`), which is **not** a pinned ABI cell, and `tools/check_package_abi.py` rejects a package that reads it. Port `$FE` cannot be read back. Two ways out:
   * **ABI 2.0 as released (built as the default):** the program passes the border colour as a third argument, `CBEEP ms,semitones,border`. It is clumsy but always right and stateless. Assuming white (what the editor resets to) would recolour the border after any `BORDER` in the program.
   * **ABI 2.1 (measured, not adopted):** append `PKG_PIN PORT_FE_SHADOW, $8109, 1` (read-only for packages) and bump the minor version. Then `CBEEP ms,semitones` needs nothing else. ROM cost: **0 bytes**. HOME differs in 1 byte (the minor at `$0094`) and EXROM in 1 byte (the version `STORAGE_LOAD` compares). Older package tapes (`$8200`) still load; a 2.1 package tape is refused cleanly by a 2.0 ROM (tested: `BAD_VERSION`, nothing installed). This **is** an ABI expansion, which the brief excludes for ClassicBEEP alone, so it is an owner decision. `tools/maint/abi21_pin_variant.sh` builds it in a copy of the tree.

**One package at a time.** The window `$F400-$F7FF` holds one package. Loading `CBEEP` replaces SHAPES, SPRITE, GRAPHICS and the others, and vice versa (tested: after `LOAD "SHAPES" EXT`, `CBEEP` is a compile error). A program cannot use `CBEEP` together with `CIRCLE` or sprites. This is the largest usability cost of the package route, and it is the same for every package.

## 6. The prototype: `rom/v2_package_cbeep.asm`

Normal package format: `ORG EXTENSION_MODULE_BASE`, `jp` install, `EXT2_REGISTER` (service 0) only, private state in the image. It is assembled against `hardware.inc` + `v2_package_abi.inc` alone. It was added to `make v2-packages` (`build/extensions/v2_cbeep.tzx`, stamped `$8200`) and to the package list of `tools/check_package_abi.py`, which passes: no HOME reference except slot 0 and the pinned `EXT_CALL_ARG0-2`, `VM_ERROR_CODE`, `VM_HALTED`.

**The beeper is reused as source, not by address.** `kernel/sound/sound.asm` is `INCLUDE`d inside `MODULE cb`. Its `PORT_FE_SHADOW` then resolves to the package's own one-byte cell `cb.PORT_FE_SHADOW`, which is loaded from the border argument (or, in the 2.1 build, copied from V2's cell). The proven loop is unchanged byte for byte, and HOME's shadow is never written (tested).

**Design B (default), Sinclair semitones, integer maths:**

* range: ms 0..32767, semitones -60..69, else **error 15** (as the ROM's `BEEP`; `VM_ERROR_CODE` + `VM_HALTED`, the ABI's error path);
* `pitch = ((Q[n] >> octave) - 15) >> 2`, `Q[n] = 4 x 3 528 000 / (52 f)` for the lowest octave (12 words);
* `cycles = ms x F[n] >> (22 - octave)`, `F[n] = f x 65536 x 64 / 1000` (12 words), with a package-private 16x16->32 multiply. Like the stock ROM it counts cycles of the ideal frequency (`cycles = int(f x seconds)`). More than 65 535 cycles (e.g. over 4.65 s at +69) is error 15.
* calibrated for the real TS2068 clock (3.528 MHz); `CBEEP 1000,0` gives 261 cycles, as the stock ROM's `BEEP 1,0`. A bit-exact Python model is `tools/maint/cbeep_model.py`.

Accuracy on a real TS2068, rounding to the loop's 52 T-state steps (model; the loop is the release's):

| Semitones | -60..-1 | 0..23 | 24..35 | 36..47 | 48..59 | 60..69 |
|---|---|---|---|---|---|---|
| CBEEP worst error | 3 cents | 12 | 18 | 31 | 71 | 155 |
| AY `BEEP` (main ROM) | A0 below -39 | 6 | 12 | 25 | up to 77 | |
| stock ROM | +14 everywhere (clock) | | | | | |

**Sizes (assembled):**

| Variant | Statement | Bytes |
|---|---|---|
| **B, ABI 2.0 (default)** | `CBEEP ms,semitones,border` | **260**: entry 3, install 12, name 6, execute 124, error 11, tables 48, `SOUND_BEEP` 55, cell 1 |
| B, ABI 2.1 pin | `CBEEP ms,semitones` | 258 |
| A, raw, ABI 2.0 | `CBEEP cycles,pitch,border` | 107 (96 without the unused error block) |
| A, raw, ABI 2.1 pin | `CBEEP cycles,pitch` | 105 |

RAM: none outside the package window, which is reserved anyway (1 KB, one package at a time). There are no sysvars and no scratch cells; it uses about 10 bytes of stack and one of the 12 registry slots. ROM: **0 bytes** in every variant (the 2.1 variant changes two version bytes).

**A vs B.** A is 153 bytes smaller and is exactly the release's `BEEP` (tested: `CBEEP 100,100,7` takes 542 614 T, the release's `BEEP 100,100` 542 200). But it keeps the raw counts the owner wanted to leave behind, and needs a formula or table to play a note. B costs 153 bytes of a 1 KB window that is otherwise empty while it is loaded. It gives the Sinclair note numbers with the same pitch accuracy as the AY `BEEP` up to three octaves above middle C, and durations that read directly (`BEEP 0.25,7` -> `CBEEP 250,7,...`). **B is recommended**: the RAM difference costs nothing in practice, because the window holds one package whatever its size.

Kept from the old routine, as documented behaviour: interrupts are off while a `CBEEP` sounds. The frame counter stops and BREAK is not seen until the note ends, like the stock `BEEP` and the release's raw `BEEP`. A long note (up to 32 s) therefore blocks BREAK; programs that need BREAK should use the AY `BEEP`.

## 7. Tests

| Suite | Build | Result |
|---|---|---|
| `tools/maint/ay_beep_tests.py` (AY BEEP, SOUND, BREAK, PAUSE; 4 new cases) | branch default | **59/59**, all 130 semitones register-exact; BREAK during `BEEP 5,0` stops it after 55 frames (error 66, R8 = 0); BREAK during `PAUSE 300`; `PAUSE 20` from `FRAMES` 65530 and 1000 = 20 frames |
| same | AY candidate without the shared wait | 59/59 (quick), with the old behaviour asserted: the note plays out (300 frames) before BREAK; `PAUSE 20` across the wrap returns after 0 frames |
| `tools/maint/chime_trace.py` | default vs AY candidate vs release | identical to the AY candidate; release differs only by the known R6 write |
| `tools/maint/cbeep_tests.py` | default, package B (ABI 2.0) | **28/28**: install; pitch and cycles = model for all 130 semitones; T-states of five notes = `cycles x (222 + 52 pitch)` within 0.1 %; border kept (`BORDER 2`), HOME shadow and AY registers untouched; errors (`70`, `-61`, `-1` ms, `32767,69`, one past the longest +69 note, ±32767); 0 ms; fractions cut; lower-case name; argument-count / string compile errors; not loaded -> compile error; `CBEEP`, AY `BEEP`, `CBEEP` in one program; no side effects on variables, strings, `FREE()`; design A = the release's raw BEEP; **loudspeaker audio**: six notes, each within 0.3 % of `3.5 MHz / (222 + 52 pitch)` (`docs/v2/maint_audio/cbeep_scale.wav`) |
| same, `--pin` | ABI 2.1 copy, package B pinned | 26/26 (quick sweep), border taken from V2 |
| `tools/maint/cbeep_tape_test.py` (gate runner, real tape receiver) | default | **3/3**: `LOAD "CBEEP" EXT` -> LOADED, registry `[CBEEP]`, program runs; SHAPES loaded over it replaces it; a tape with a newer minor word is refused, nothing installed |
| `tools/check_package_abi.py` | default; ABI 2.1 copy | passes (6 packages); passes as ABI 2.1 (35 pins) |
| `make check` | default | passes |
| `make test` (all headless suites, 2026-10-12) | default | **passes**: smoke ROMs 9/9; V2 standalone 40/40; production checks and FILL check 0 failures; production regression gate **114 PASS**; Array Store gate **100 PASS**; known-defect suite **15 PASS**; SAVE ALL **13 PASS**; `make qual` corpus **663 PASS, 2 XFAIL, 2 N/A, 0 FAIL** (the release's tally; `hw.pause`, `tag.pause_frames`, `hw.beep` included); session lifecycle **23/23**. The packages (now six) are built and stamped by `make v2-packages` in the same run |

Not run: `make test-legacy` (V1 chain under Fuse; this change only removes a production-only filler entry and adds `IFDEF`ed code). Nothing was heard on hardware.

## 8. Final budgets

| Configuration | HOME free | EXROM free | Package |
|---|---|---|---|
| release | 54 | 25 | -- |
| AY candidate (chime C) | 13 | 20 | -- |
| **+ shared wait (recommended main ROM)** | **19** | **26** | -- |
| + shared wait, chime B instead | 47 | 38 | -- |
| + ABI 2.1 pin | 19 | 26 | CBEEP 258 bytes, 2 arguments |
| ClassicBEEP package (ABI 2.0) | (no ROM cost) | | 260 bytes, 3 arguments |

## 9. Recommendation and owner decisions

For the maintenance release: **the AY candidate plus the shared frame wait** (this branch's default). It is HOME 19 / EXROM 26 free, BREAK works in `BEEP`, and a `PAUSE` defect is fixed. Ship ClassicBEEP as an **optional package, design B**, outside the ROM.

Decisions (**taken by the owner on 2026-10-12: see section 10**):

1. **ClassicBEEP's border:** keep ABI 2.0 and the third argument, `CBEEP ms,semitones,border` (as built), **or** pin `PORT_FE_SHADOW` as ABI 2.1 (0 ROM bytes, one minor bump, every package tape re-stamped `$8201` by `make v2-packages`) for `CBEEP ms,semitones`. The pin is the better user interface; it is the one ABI change in this study and was not made on the branch.
2. **The name:** `CBEEP` (built), or another name of at most 8 characters. `CLASSICBEEP` itself would need the registry's name field widened (a HOME and ABI major change), which is not recommended.
3. **Milliseconds** for the duration (built). The alternative is hundredths of a second. Seconds would lose every fraction, because package arguments are integers.
4. Carried over from the AY study: chime C or B, low notes A0 or error, `SOUND 256,x`.

Before release: record the `PAUSE` wrap defect as fixed. Update the manual's `BEEP` (BREAK now ends a note), `PAUSE` and package chapters, plus a `CBEEP` section if it ships. Add `ay_beep_tests.py`, `cbeep_tests.py` and `cbeep_tape_test.py` to the maintenance qualification. Listen on hardware: the speaker through the TV, and its level next to the AY's.

## 10. Owner decisions and pre-integration verification (2026-10-12)

**Decisions (owner, 2026-10-12):** CBEEP keeps three arguments, `CBEEP milliseconds,semitones,border`; the name stays `CBEEP` (the 8-character package-name limit is not widened); the duration stays in milliseconds; startup chime option C; the shared frame wait and the `PAUSE` rollover fix stay; **no package ABI 2.1** (the pinned-border variant stays a measured alternative only); ClassicBEEP stays an optional RAM-loaded package and the one-package-at-a-time window is not redesigned. Nothing in the ROM changed after these decisions; the package source was split into `rom/ext_cbeep_module.asm` + `rom/v2_package_cbeep.asm` (the shipped packages' layout, which the manual checker reads) with byte-identical output.

### 10.1 The HALT-based wait without the frame interrupt

The wait counts frames with `HALT`, so it ends only on an interrupt. Two ways a program can take the interrupt away were tested on the candidate and on the release (`tools/maint/di_wait_tests.py`): a `USR` routine that ends `DI : RET` (the manual tells machine code to leave interrupts on), and `OUT 255,192` (port `$FF` bit 6 inhibits the frame interrupt at the SCLD; bit 7 keeps the EXROM selected -- `OUT 255,64` would also deselect the EXROM, which breaks the next EXROM call by itself).

**A safe test is possible.** The harness runs the emulated CPU for a fixed instruction budget (ZRCP `run N`, here 40 million instructions, over 2 000 frames' worth) and then inspects it, so a statement that never ends is reported with its PC and the next case restarts from the booted snapshot. The emulator and the test runner never hang. After each hang the test also presses BREAK in the emulated keyboard matrix and runs on.

| Statement | Interrupts left off by machine code (`USR` `DI`) | Frame interrupt inhibited (`OUT 255,192`) |
|---|---|---|
| `PAUSE 10` | never ends (`HALT` in `AY_WAIT_FRAMES`); **release: never ends either** (polling a `FRAMES` that does not move) | never ends; release: the same |
| `PAUSE 0` | never ends (key wait); release: the same | never ends; release: the same |
| `BEEP 0.1,0` (AY) | **completes**: `OP_BEEP` calls the calculator and its EXROM slot, and `BANK_PAGE_EXROM_IN/OUT` end with `EI` | **never ends**, stopped at the `HALT` in `AY_WAIT_FRAMES`; channel A keeps sounding until reset (from the code: `AY_BEEP_PLAY` sets R8 = 15 before the wait and 0 after it; the register probe cannot run on a halted CPU in ZEsarUX); the release's raw `BEEP` (a timed busy loop) completed |
| `CBEEP 10,0,7` | completes (busy loop; ends with `EI`, so interrupts are on afterwards) | completes |
| any hang, then BREAK | not seen: the keyboard is scanned by the frame interrupt | not seen |
| control: `DI` then `EI` (`USR`), `PAUSE`, `BEEP` | complete | |

So the shared wait changes nothing for `PAUSE` (both versions need the frame interrupt), and makes the AY `BEEP` hang where the release's busy-loop `BEEP` did not -- only when a program has inhibited the frame interrupt at port `$FF` itself, which the manual already warns against ("changing a port the system keeps a copy of ... can confuse the system"); on a TS2068 only the reset button recovers. A guard was not added: the inhibit bit cannot be seen in `PORT_FF_SHADOW` (an `OUT` does not update it), and a time-out would need a second clock. Documented in the manual (`BEEP`, `PAUSE`) and as M-3 in the defect register patch.

### 10.2 `make test-legacy`

Run (Fuse under X11, display `:1`): **8 of 13 cases pass** (`editor_auto` wrap and insert; `storage` named load, extension load, bad length, bad version, wildcard, save-missing). The other **5 cannot be built**: `extension_roundtrip` and the four `autorun_*` cases assemble the V1 test EXROM `rom/exrom_build.asm` with `STORAGE_TEST_FAKE_SEND`, which no longer fits (42 and 17 bytes over; `sjasmplus_strict.sh` refuses the truncated image), so `make` stops at the first. The **release tag fails identically** (same command in a copy of `v2.0.0-emu.1`: the same 42 / 17 bytes); the production images do not use this build, and this branch changes none of its sources (`exrom_build.asm`, `kernel/storage/`, `basic/` are untouched; `rom/exrom_sound.asm` only gained `IFDEF`ed lines). The release documents never ran `make test-legacy` (`R10_9_PHASE2C_REPORT.md`, `R10_7_LIMITS_REMOVAL_PROGRESS.md`). Recorded as test debt T-4; not fixed here.

### 10.3 Documentation

On this branch (files the documentation branch does not change): `PACKAGE_ABI.md` (CBEEP inventory, port `$FE`, the exact-length name rule), `V2_HARDWARE_CHECKLIST.md` (section 5, the hardware-only sound tests), this report, `maint_audio/README.md`.

For the documentation branch (which this branch must not modify): **`docs/v2/maint/docs-v2-user-manual.patch`**, against `docs/v2-user-manual` (`6b1e593`), 11 files:

* `manual/03_keywords.md`: `BEEP` rewritten (seconds/semitones on the AY, fractions, ranges, error 15, channel A policy, BREAK, the frame-interrupt caveat, accuracy, Sinclair comparison; the `sbeep` procedure removed); new entry **`CBEEP  [package: cbeep]`** (interrupts off while it sounds, BREAK not seen until the note ends, may change the border colour, replaces any loaded package, errors, accuracy); `PAUSE` (frame-interrupt requirement, the **rollover defect and its fix**, the measured 6 985 733 T-states for `PAUSE 100`); `SOUND` (registers 0 to 16, error 8, the low-8-bit rule for `SOUND 256`, channel A shared with `BEEP`, the release's register-0 restriction as history);
* `manual/05_packages.md`: six packages; new section **The cbeep package** (the same four warnings); its error code;
* `manual/01_introduction.md`, `02_beginners_guide.md` (chapter 13, the package table), `04_concepts.md` (BREAK, the Sinclair comparison table, *Sound*, *Speed*), `07_appendices.md` (run-time errors 8 and 15 with new tested lines, limits, package card, hardware notes, keyword index, how the manual was checked);
* `V2_LANGUAGE_REFERENCE.md`, `V2_USER_MANUAL.md`, `V2_DEFECT_REGISTER.md` (a "Maintenance candidate" section: **M-PAUSE** the rollover defect, fixed; M-1, M-2; M-3 the frame-interrupt limit; T-4 the legacy build), `V2_BEEP_SOUND_MODE_COMPATIBILITY.md` and `V2_MAINTENANCE_BACKLOG.md` (status lines).

**Verified as an integration trial**, without touching either branch: a detached worktree at `docs/v2-user-manual` (`6b1e593`), `git merge --no-commit study/classicbeep` -- **no conflicts** (only `Makefile` auto-merged) -- then the patch applied (`git apply --check` also passes on an untouched export of the documentation branch). In that merged tree: `tools/check_manual.py` passes (325 examples parsed, every keyword including `CBEEP` has an entry, links resolve) and **`make doc-examples`: 325 of 325 PASS** on the candidate ROM built there. That includes the rewritten `BEEP`, `SOUND`, `PAUSE` examples, `kw.cbeep.1` and `pkg.cbeep.1` (the cbeep package played into the real tape loader and `LOAD "CBEEP" EXT` typed before the program runs) and the new error lines `ve 15 | BEEP 1, 70`, `ve 15 | BEEP -1, 0`, `ve 8 | SOUND 17, 1`, `ve 15 pkg=cbeep | CBEEP 100, 70, 7`, `ve 15 pkg=cbeep | CBEEP 32767, 69, 7`. The trial worktree was removed afterwards; nothing was committed in it. Not regenerated: the Word edition (`make manual-v2`), which belongs to the documentation branch's own release step.

### 10.4 Budget

`make budget` on the default build: **HOME 19, EXROM 26 bytes free**. Checked independently on the images: `build/test_basic.bin` ends in exactly 19 `$FF` bytes after its last instruction (`ret` at `$3FEC`), `build/exrom.bin` in exactly 26 after its last message string (`$DFE5`). Not counted in those figures: the 5-byte low-ROM gap `$000B-$000F` that `INT_GET_FRAMES` occupied in the release is free again. Images: HOME `3f13ec2cc4ef02c1...`, EXROM `24b1ebb0b1377aad...` (unchanged since the shared wait was made the default).

### 10.5 Regression after these changes

On the committed tree (default build, images HOME `3f13ec2c...` / EXROM `24b1ebb0...`, unchanged since section 7):

* `make check`: passes (includes `check_package_abi.py` with the split CBEEP package and `check_docs.py`).
* `make test` (2026-10-12, second full run): smoke ROMs 9/9; V2 standalone 40/40; production checks and FILL check 0 failures; production gate **114 PASS**; Array Store gate **100 PASS**; known-defect suite **15 PASS**; SAVE ALL **13 PASS**; `make qual` corpus **663 PASS, 2 XFAIL, 2 N/A, 0 FAIL** (the release's tally, the historical baseline unchanged); session lifecycle **23/23**.
* Focused: `cbeep_tests.py` 27/27 (all 130 semitones; audio recorded earlier, 28/28 with `--audio`); `cbeep_tape_test.py` 3/3 (real tape receiver); `di_wait_tests.py` 14/14 on the candidate and 11/11 on the release; `ay_beep_tests.py` 59/59 and the chime trace (section 7; ROM unchanged since).
* `make doc-examples` 325/325 in the integration trial (section 10.3).
* `make test-legacy`: 8 of 13; 5 cannot be built, identically on the release tag (section 10.2).

### 10.6 Readiness

**Ready for maintenance-release integration**, as far as emulator testing can establish it: the owner's decisions are in place, the ROM fits with HOME 19 / EXROM 26 bytes free, every suite that ran on the release passes with the same tallies, the branch merges into the documentation branch without conflicts and the documentation patch passes the manual's own example suite on the merged tree. Integration steps (owner's approval needed for each): merge `study/classicbeep` (it contains `study/ay-beep`) into the maintenance line; apply `docs/v2/maint/docs-v2-user-manual.patch` on the documentation side and regenerate the Word edition; turn the `V2_MAINT_*` switches into plain source once the build-variant tooling is no longer wanted (the release images stay reproducible with `EXTRA_DEFS=` until then); add `ay_beep_tests.py`, `cbeep_tests.py`, `cbeep_tape_test.py` and `di_wait_tests.py` to the maintenance qualification. Open, not blocking: T-4 (the legacy V1 storage fixture no longer builds; pre-existing).

**Hardware-only tests** (cannot be done in the emulator; `V2_HARDWARE_CHECKLIST.md` section 5): the startup chime by ear (identical writes, never heard on a TS2068); `BEEP` pitch with a tuner and its length at the real 60 Hz frame rate (ZEsarUX runs 50 Hz and a 0.5 % fast AY clock); BREAK ending a long `BEEP` on a real keyboard; consecutive notes without clicks; `SOUND` register 0 and channel B surviving a `BEEP`; the cbeep package loaded from a real cassette, its pitch, the border staying put, BREAK waiting for the note; the loudness of the AY at level 15 against the loudspeaker through the TV; `STICK` after the chime and a `BEEP` (the mixer's I/O bits); and the frame rate itself (`PAUSE 600` = 10 s).

