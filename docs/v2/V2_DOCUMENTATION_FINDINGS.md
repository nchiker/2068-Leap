# V2 documentation session: findings

Written while producing the V2 user manual and language reference (branch `docs/v2-user-manual`, based on `v2-development` at `170550e`). The ROM was **not** changed and no release artifact was touched: every statement below was measured on the accepted release (tag `v2.0.0-emu.1`; HOME `dddd4cbb...e40dca`, EXROM `c1804641...291b527`, checked against the build used) in the headless ZEsarUX of `~/Applications/ZEsarUX-13.0`.

Two lists: **A**, statements in the earlier V2 documents that were wrong or missing and are now corrected; **B**, observations about the *implementation* that the owner may want to look at. Section B is kept here, separately from `V2_DEFECT_REGISTER.md`, as the task required; each item says how it was seen. None of them changes the accepted-limitations list.

## A. Corrections to the earlier documents

| # | Earlier statement (document) | Fact on the release | How established |
|---|---|---|---|
| A1 | `USR` returns its result in **BC** (`V2_LANGUAGE_REFERENCE.md` s6, handoff item 12) | the result is taken from **HL** on return (the V1 manual was right); `LD BC,1234 : RET` returns the address, `LD HL,777 : RET` returns 777; IY is saved and restored by the ROM, every other register may be destroyed | `kw.usr.1`, `kw.usr.2`; `BUILTIN_FN_USR` reads `bit 7,h` after the call |
| A2 | `DIMN(a$)` gives a string array's size (manual s7, reference s6) | `DIMN` accepts **numeric arrays only**; `DIMN` of a string array is compile error 47 | `kw.dimn.1`, the case `arr.dimn_str` in the corpus is `OkOrErr` and so did not show it |
| A3 | `LPRINT` is a core statement (manual s8, reference s5) | belongs to the printer package; without it compile error 32; `LLIST` and `LPRINT`'s string form are in the same package | `kw.lprint.2`, corpus `pkg.printer.unloaded` |
| A4 | `INPUT var` only | `INPUT "prompt"; var` and `INPUT "prompt", var` work (the prompt is printed with nothing between it and the answer); `INPUT a(i)` is compile error 64 | `kw.input.*` |
| A5 | `PLOT`/`LINE`/`POINT`: "256x192 pixels" | y counts **from the top** (`PLOT 0,0` is the top left), unlike Sinclair BASIC; out-of-range values are moved to the edge | screenshots `plot_wave`, `point_readback` |
| A6 | `AT`/`TAB`: "out-of-range values are clamped" | the row above 23 is clamped to 23; the **column is taken modulo 32** (`AT 0,40` is column 8; `TAB 40` the same); the text area is rows 0-22 and row 23 is the status line (printing there scrolls) | `kw.at.1`, `kw.tab.1`, `OP_AT`/`OP_TAB` |
| A7 | `BEEP duration,pitch`: "sound" | raw counts: *duration* is the number of cycles, *pitch* the busy-wait per half-cycle; one cycle takes about `52 x pitch + 220` T-states (measured 5 421 600 T-states for `BEEP 1000,100`); interrupts are off while it sounds, so BREAK is not seen until it ends | `meas`, `kw.beep.1`; `SOUND_BEEP` |
| A8 | `SOUND`: "AY registers 0..15" | the register number is sent to the AY chip **unchanged** and must be **1 to 16**; register 0 cannot be written | machine code of `SOUND_EXROM` read from the image (`ld a,b / ... out ($F5),a / ld a,c / out ($F6),a`) |
| A9 | `PAUSE n`: "n frames" | one frame is one display interrupt: 69 700 T-states per count in the emulator (50 per second); a real TS2068 interrupts at 60 per second | measured `PAUSE 50/100/200` |
| A10 | colour statements | `INK`/`PAPER`: low 3 bits; `BRIGHT`/`FLASH`/`OVER`/`INVERSE`: only the **low bit** (`BRIGHT 2` is off); `BORDER`: low 3 bits; a fraction is cut off | `OP_INK` ... source and `kw.*` attribute readbacks |
| A11 | "arrays up to 16383 elements" (manual s13) | 16383 is only the compile-time cap on `DIM`; memory allows **4063** numeric elements, 508 string elements of 15 characters or 254 of 31, on an empty program; one array must fit wholly in the main pool or in segment 2 | bisection with `manual` programs |
| A12 | compile errors "2, 3, 9..48" | the full table with a program for each code is Appendix B of the manual | `app.cerr.*` |
| A13 | five messages missing (handoff item 5) | `ARRAY NOT DIMD`, `ARRAY STORE FULL`, `BAD ARRAY TAPE`, `NO PACKAGE`, `PROGRAM FULL` are documented, with how each arises (the first four reproduced by tape examples; `PROGRAM FULL` by source and the release qualification only) | `con.store.*` and tape examples |
| A14 | the user sees an error number | the screen shows **only the message** (`RUNTIME ERROR`, `SYNTAX ERROR`, ...), never the code; the code tables are for the test suites and the source | `V2_SHOW_MESSAGE` |
| A15 | names | identifiers are letters and digits only (no underscore); names of **built-in functions** (`abs`, `code`, `len` ...) cannot be used as variable names, nor can keywords; in a name a keyword may only *begin* it | probes `lex.ident.*`, example `prog.caesar.1` (a variable named `code` is compile error 29) |
| A16 | `RANDOMISE [n]` | the number is **required** (`RANDOMISE` alone is compile error 3) | probe |
| A17 | handoff 7 (float `FOR`) | stated in the manual: the step is added each time, so the iteration count of a fractional loop is as exact as the arithmetic; first value prints without decimals if the start is a whole number | `kw.for.5` |
| A18 | handoff 8 (Q-24) | stated under `CALL` and in the concept *Procedures* | register |
| A19 | handoff 9 (2.4 s identity check) | stated under `SAVE` and in *Tapes* | `V2_SAVE_ALL_FORMAT.md` |
| A20 | handoff 13 (speed) | the concept *Speed*, with `tools/qual/manual_measure.py` | measurements |
| A21 | the memory a program may `POKE` / put machine code in | `$5B00-$5FFF` and `$7800-$7FFF` are not used by the V2 system (checked against the release symbol tables); `$F100-$F3D2` holds the label table, UDGs, the editor line buffer and the string/function workspace, and must not be used | `build/*.sym` |
| A22 | `MODE 1` is "high resolution" | the ROM's `GFX_SET_MODE` writes the value **2** to port `$FF` and uses the second display file (`$6000`, 6144 attribute bytes) as 8 x 1 colour attributes; the ROM and its comments call this "High Resolution Graphics". See B3 | `kernel/graphics/graphics.asm`, `include/hardware.inc` |
| A23 | (omission) user-defined characters are not mentioned in any V2 document, and the first draft of the manual said codes 144 to 255 draw nothing | **21 UDGs exist**, codes 144..164, bitmaps in `UDG_TABLE` ($F180, 168 bytes), defined with `POKE` exactly as on the Spectrum (this was the design: `sysvars.inc`, `programmers_reference.md` "Block graphics + UDGs"); `PRINT CHR$(144)` draws them; they survive `RUN`/`CLEAR`/`CLS`/`NEW`/`MODE`/`LOAD`; the V1 plan for a `UDG character,address` statement (`loadable_basic_extensions.md` s6) was never built; the table is not initialised at start-up | `tools/qual` examples `udg.*`; `GFX_CHAR_TO_FONT_OFFSET` |
| A24 | memory: "a program line costs its length + 3" (first draft of the concept *Memory*) described the **source text** only and mixed it with the cost of variables | the program is kept as text (length + 3 per line, in the pool) and compiled at every `RUN` into bytecode in a separate 4011-byte area that `FREE()` does not count; names cost 12/36/7 + length once per name; arrays 2 / 16 per element + ~11-13 + length; each active `PROC` call or `FOR` loop 12 bytes; packages do not touch `FREE()`; the 749-line limit of `PRINT n` is the **pool** (750 lines: `OUT OF MEMORY` at run time), the code area allows 1000 lines of `x = 1` | `mem.*` examples (`code=`/`source=` checks), `V2_BUILD_SOURCE`, `VM_CARVE_PTRS`, `BUILTIN_FN_FREE`, bisection |

## B. Observations on the implementation (not changed)

| # | Observation | Status / suggestion |
|---|---|---|
| B1 | **`SOUND` register numbering.** Register 0 (the fine pitch of channel A) cannot be written, and 16 does not exist in the chip. The code range-checks 1..16 and writes the number unchanged. If the original TS2068 BASIC maps BASIC register *r* to AY register *r*-1 (which the range 1..16 suggests), then every `SOUND` call is one register off; the V1 manual's own example (`SOUND 7,60 / 16,100 / 1,1 / 8,10 / 2,200 / 3,2 / 9,6`) matches the *direct* mapping. Cannot be resolved without the original ROM or hardware | needs the owner's decision (check against a real TS2068 or the Timex ROM disassembly) |
| B2 | `DIMN` has no string-array form (A2) | a capability gap, not in the defect register; no ROM room reserved |
| B3 | `MODE 1` is documented here as the second video mode of the SCLD (port value 2), described by the ROM as "High Resolution Graphics". As far as the SCLD's documented bit assignments are recalled here (unchecked), port value 2 is the **extended colour** (8 x 1 attribute) mode and the 512-pixel hi-res mode is a different value (6); please confirm against the TS2068 technical manual. The name may mislead; what the statement does was not looked at on a screen (the test renderer reads the normal display) | naming/behaviour to confirm on hardware |
| B4 | **Package arguments use only the low byte.** `SHOW 0,256,0` is accepted as row 0; `GRAB`/`SHOW`/`MOVE` and the `shapes`/`graphics` statements read `L` of the 16-bit argument. `PLOT`/`LINE` clamp the full 16-bit value instead. Consistent within a package, inconsistent with the core statements | cosmetic; documented |
| B5 | `LPRINT n` passes the value through the package ABI as a 16-bit integer (`PRT_LPRINT_NUM_EXEC` converts it with `TAG_INT`): a fraction is cut off and values beyond the 16-bit range will not print correctly. Read from the source; not run-verified (the emulator has no printer) | documented as "whole numbers; use `STR$` for others" |
| B6 | The printer's raster routine waits for paper; with no printer attached a program using `LPRINT` waits. Not exercised here (no printer in the emulator, see the package source comment) | documented |
| B7 | Wrapping in `PRINT`: when text reaches column 32 it breaks at the preceding space and the space starts the next row (`...will be` / ` 13`) | cosmetic; seen in `guide.input.1` while writing the example |
| B8 | `ARRAY STORE FULL` is shown only when the store has no room for the *header* of another entry; a load whose data merely does not fit says `LOAD FAILED` (found while reproducing the message: `DIM big(1018)` stored, then a one-element array) | documented in *Array Store*; fine |
| B9 | Capacity messages vary by what fills first: nesting of 300 `IF`s is `NESTING TOO DEEP` but 141 nested `FOR` loops already stop at run time with `STACK OVERFLOW` (the control stack), and a program of 750 `PRINT n` lines does not compile (`OUT OF MEMORY`) | documented in Appendix D |
| B10 | **`INPUT` has no line editing**: DELETE and the cursor keys are ignored (`OP_INPUT_STR` accepts only codes `$20`-`$7E` and ENTER); a mistyped character cannot be corrected. Found when an example assumed DELETE worked | documented in `INPUT`; a usability limitation, owner's call |

| B11 | **UDG ergonomics (possible future maintenance item, not a requirement)**: defining a character needs eight `POKE`s and a hard-coded address (61824); there is no `USR "a"`, no keyboard entry, and the table is not zeroed at start-up (on real hardware, undefined UDGs may show garbage). Cheapest improvements, in order: (1) zero the 168-byte table in the cold-start routine (a handful of bytes in HOME, if any room; `MEM_COLD_INIT` only clears `$8000..$C000` today); (2) a statement `UDG code, address` copying 8 bytes from memory, which the V1 extension plan sized at 23 Home bytes plus ABI, or as a package statement (the package window has room: graphics is 467 of 1024 bytes) -- the package ABI allows 5 arguments, so `UDG c, address` fits but a row-per-argument form does not; (3) nothing in the sprite package helps directly, but `GRAB` can capture any drawn 1-cell picture. No change was made | owner's call |

## C. What the documentation suite does not cover

* `PROGRAM FULL` (needs a nearly full program memory; covered by the release qualification).
* Anything that depends on physical hardware (Appendix G of the manual).
* The look of `MODE 1` and of the ULAplus palette.
* The printed paper of `LPRINT`/`LLIST`.

## D. Reproducing

```
make build v2-packages      # the accepted images (check the SHA-256 sums against the tag)
make doc-examples           # every example of the manual, on the release image
python3 tools/qual/manual_measure.py     # the timing figures of the concept "Speed"
```
