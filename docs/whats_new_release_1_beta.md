# What's New in 2068-Leap Release 1 Beta

Release 1 Beta builds on Public Preview 1 without changing the project's core
idea: an instant-on, line-number-free BASIC environment designed for the Timex
Sinclair 2068. The beta concentrates on room for real programs, expansion,
language depth, storage workflow, and reliability.

## At a glance

| Area | Public Preview 1 | Release 1 Beta |
|---|---:|---:|
| Dynamic BASIC memory | 1,857 bytes | 15,322 bytes |
| Integrated BASIC fixtures | 68 | 92 |
| Standalone ROM build checks | 9 | 15 |
| Loadable statement modules | None | 6 supplied modules |
| Home ROM free | 2 bytes | 1 byte |
| EXROM free | 99 bytes | 2 bytes |

## 1. More usable BASIC memory

The much larger BASIC pool is not extra physical RAM. It comes from auditing
fixed reservations, moving temporary work areas to safe shared storage,
relocating persistent state, and reclaiming memory that programs could not use
in the preview. The result is over eight times as much room for program text,
arrays, and strings while retaining the same stock 48K machine target.

## 2. Loadable BASIC extensions

The beta introduces a documented extension ABI and a fixed 512-byte module
window. One optional statement can be installed at a time with:

```basic
LOAD "FRAME" EXT
```

The keyword then participates in normal editing, checking, and execution.
`SAVE "name" EXT` records the installed module. `NEW` and ordinary program
loading unregister it safely.

Six modules ship with Release 1 Beta:

- **CPLOT** — coarse block plotting.
- **BLOCK** — filled rectangles.
- **FRAME** — rectangle outlines.
- **INVERT** — reversible rectangular pixel inversion.
- **AYREG** — native AY register output.
- **OUT** — full 16-bit Z80 port output.

This is more than a collection of commands: it is the mechanism that lets the
BASIC system continue to grow even though both ROM banks are essentially full.

Extension tapes use a separate validated type, fixed size, checksum, and
ABI-version field. An explicit name is required, so a wildcard program load
cannot install an unexpected module.

## 3. User-defined numeric functions

Classic `DEF FN` lets a program name and reuse a calculation:

```basic
DEF FN S(X)=X*X
PRINT FN S(12)
```

The beta supports one active single-letter, single-argument numeric function.
Definitions take effect when execution reaches them and can be replaced later
in the same program. This is a language feature, independent of the optional
extension system.

## 4. Prompted input

`INPUT` now accepts literal prompts for both numeric and string variables:

```basic
INPUT "Name: ";N$
INPUT "Age: ";A
```

The prompt is a quoted literal followed by a semicolon. Numeric input accepts a
leading minus sign; string input is capped at 31 characters.

## 5. Expanded expressions, strings, and arrays

Release 1 Beta adds `INSTR(haystack$,needle$)` and strengthens nested string
function evaluation. Numeric and string arrays use the expanded dynamic pool,
making larger data sets practical. A dedicated string-function work area
prevents editing and static checking from corrupting uncommitted text.

## 6. Numeric calculator behavior

The calculator now rejects stack underflow/overflow, division by zero, numeric
overflow, and invalid conversion boundaries cleanly. Calculator-backed
functions include direct fractional display for SQR, SIN, PI, RAD, and DEG.

## 7. Program storage and autorun

Program tapes can request autorun from a one-based statement position:

```basic
SAVE "DEMO" LINE 1
```

On loading, a valid saved index begins execution there. An invalid index leaves
the program loaded for inspection instead of jumping into an unsafe position.

## 8. Graphics and ULAplus

The base graphics system remains available while the beta adds loadable BLOCK,
FRAME, INVERT, and CPLOT commands. ULAplus palette handling is better isolated
from the editor: programs can prepare 64 custom colors, use them in normal or
High Resolution Graphics mode, and always return to the standard palette when
the program exits.

## 9. Sprites and collision handling

Sprite state handling is stricter and safer. Invalid operations fail before
changing the display, overlapping sprites observe reverse display order, and
global screen changes invalidate stale save-under state while preserving
captured images for reuse. `HIT()` reports overlap between shown slots.

## 10. Sound and hardware access

The base ROM continues to provide beeper and AY sound. The loadable AYREG
command adds native AY register output, while OUT provides full 16-bit Z80 port
output for expert hardware control. Both are optional modules and therefore do
not consume permanent ROM space.

## 11. Editor and execution reliability

The beta fixes two visible post-load editor problems: the append position now
uses the loaded program's real statement count, and the settled word-wrap cache
is rebuilt after auto-scroll. Loaded programs open at the correct bottom
position without a phantom cursor.

`RUN` now clears abandoned FOR and GOSUB state before every execution. The
editor regression harness also covers blank-line insertion and verifies the
physical display result.

## 12. Emulator-ready distribution

Release 1 Beta includes distinct images for each tested setup:

- separate Home ROM and EXROM files for Fuse;
- a combined Home+EXROM image for ZEsarUX;
- a Home ROM and DCK-wrapped Timex cartridge for EightyOne 1.41; and
- six Direct Recording TZX extension tapes.

See `emulator_setup.md` for exact configuration and tape-loading instructions.
All distributed binary and tape assets have SHA-256 checksums.

## 13. Compatibility note

2068-Leap programs remain line-number-free native programs stored inside
standard TS2068 tape framing. They are not byte-compatible with stock tokenized
Sinclair BASIC. Keep backup copies of beta programs because the native payload
may still evolve before the final Release 1 build.
