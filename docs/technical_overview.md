# 2068 Leap — Technical Overview

## Purpose

2068 Leap asks what the Timex Sinclair 2068 ROM might have looked like if
its software had been redesigned around the machine rather than remaining a
close relative of the 48K Spectrum ROM. The result is a working 16K Home ROM
plus an 8K banked EXROM, still instant-on and usable on a stock 48K TS2068,
with a full-screen editor, structured BASIC, machine-specific graphics,
sound, sprites, and compatible tape framing.

The ROM is a clean Z80 implementation organized into documented kernel
services, a BASIC layer, and banked feature modules rather than a patch set
against the original monolithic ROM.

## Improvements users can see

### Full-screen program editing

Programs are edited in place without line numbers. Statements are addressed
internally by program position and branches use case-insensitive labels. The
editor provides insertion and deletion, word wrapping, automatic scrolling,
cursor navigation, whole-line insertion/deletion, keyword normalization and
bold highlighting, a status bar, and direct movement among errors.

Rendering uses row-shadow state so unchanged settled lines are not redrawn.
Horizontal cursor movement has a smaller fast path that restores and redraws
only the old and new cursor cells. This reduces flicker and avoids traversing
the complete visible program for a cursor-only change.

### Errors integrated into editing

Both append and replacement commits rebuild labels and run the static program
checker. Invalid lines are marked in red immediately, with their specific
message shown when selected. `RUN` repeats the whole-program check before any
statement executes. Value-dependent failures use one centralized runtime
error path that preserves the most specific error and failing statement.

### Structured BASIC and data

The language includes labels and `GOTO`, block and single-line `IF`,
`ELSEIF`/`ELSE`, `FOR`/`NEXT`, `GOSUB`/`CALL`/`RETURN`, and colon-separated
statements. Expressions support normal precedence, comparisons, Boolean
operators, integer arithmetic, variables, arrays, strings, and math and
conversion functions.

Scalar variables and arrays share a dynamic RAM pool with program text rather
than reserving large fixed tables. Numeric arrays are zero-based and report
their size through `DIMN()`. String scalars are allocated on demand from the
same two-ended dynamic pool and hold up to 31 characters. Strings support
concatenation, comparisons, case conversion, slicing, `CHR$`, `STR$`, `LEN`,
`CODE`, and `VAL`.

### Graphics designed for the TS2068

The bitmap API provides `PLOT`, `POINT`, absolute-coordinate `LINE`, filled
clipped `CIRCLE` and bounded-stack flood `FILL`; `BLOCK` and coarse `CPLOT` are
the reference RAM-loaded BASIC extension.
Text and graphics share `INK`, `PAPER`, `BRIGHT`, `FLASH`, `INVERSE`, and
`OVER`; `OVER 1` XOR-plots both pixels and text.

`MODE 1` exposes the TS2068 manual's High Resolution Graphics mode: the normal
256×192 bitmap with colour attributes at 8×1 scanline resolution rather than
8×8 cells. Modern sources often call this Extended Color. It is distinct from
the separate 512×192 two-colour 64-column mode, which was implemented
experimentally and removed when its ROM cost outweighed its practical value.

ULAplus is an independent extension. `PALETTE` writes its 64 GGGRRRBB
registers and `ULAPLUS` controls activation. It is program-scoped; one shared
editor-return boundary disables it after completion, `STOP`, `END`, BREAK, or
an error while retaining programmed palette values for reuse.

### Sprites, sound, and storage

Eight fixed sprite slots can capture up to 32×32 pixels, show while preserving
the background, move, hide, and test rectangular collision with `HIT()`.
Sprite implementation is banked because it is large and cold during editing.

`BEEP` drives the internal speaker and `SOUND` exposes AY-3-8912 registers.
A higher-level music sequencer remains a future opportunity; there is no
`PLAY` statement in the current ROM.

`SAVE` and `LOAD` use the stock TS2068/Sinclair 17-byte header plus data-block
framing and stock-derived pulse transport. The payload is this BASIC's native
line-number-free representation. Named and empty-name loads are supported,
received data is validated before replacing the active program, and progress
is displayed in the editor status bar.

## Architecture

The always-visible Home ROM occupies `$0000-$3FFF`. The 8K EXROM is paged
into chunk 6 at `$C000-$DFFF`; chunk 7 stays untouched because it contains the
machine stack. Calls into EXROM use fixed entry stubs, while callbacks to Home
use a generated fixed-address jump table. Shared wrappers centralize paging
and protect against accidental nested EXROM entry.

The source enforces a layering rule: BASIC calls documented kernel APIs, and
hardware access belongs in kernel modules. Modules cover memory, keyboard I/O,
graphics, math, sound, storage, interrupts, and banking. The production editor
has one canonical EXROM source; standalone Home-ROM tests assemble that exact
body through a compatibility adapter.

System variables and BASIC program storage live above `$8000` in general RAM.
An earlier Spectrum-like `$5D00` placement was removed after auditing the
TS2068 topology: `$4000-$7FFF` is dedicated video RAM required by the extended
display modes. The relocation avoids runtime memory shuffling when entering
High Resolution Graphics.

## Verification

- Static assembly checks catch duplicate globals, broken local-label scope,
  and a stack-ordering error pattern that previously caused real bugs.
- Documentation checks derive counts from source tables and fixtures.
- Standalone smoke ROMs exercise memory, math, and canonical editor operations.
- A production editor harness injects keys through the real interrupt latch
  and crosses the real Home↔EXROM trampoline.
- The integrated Fuse suite contains 69 fixtures covering control flow,
  expressions, memory, arrays, strings, graphics, sound, sprites, I/O,
  ULAplus, errors, and machine-code entry.
- `make budget` reports exact Home ROM, EXROM, and RAM margins; assembler
  assertions enforce both physical ROM limits.

Storage received additional adversarial work because a failed load must never
damage the current program. Data is staged and validated before program state
is committed, and tape fixtures check framing independently of live timing.

## Deliberate boundaries

This is not a compatibility clone of stock Sinclair BASIC. It intentionally
has no line-numbered program model, does not tokenize keywords during keyboard
entry, and stores a native program payload. The 512×192 64-column and dual-
screen modes are not exposed. Procedures, functions, `REPEAT`, `SELECT`,
and exception handling remain future work rather than partial
or undocumented implementations.

Physical ROM capacity is the governing constraint. Features used only while a
program runs are strong EXROM candidates; hot editor and interpreter paths
stay in Home ROM where possible. Every expansion is evaluated for user value
and bank-boundary cost, not merely whether Z80 code can be written for it.
