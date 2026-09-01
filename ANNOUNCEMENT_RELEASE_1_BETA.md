# 2068-Leap Release 1 Beta

2068-Leap Release 1 Beta is ready for public testing. It is a from-scratch,
open-source ROM environment for the Timex Sinclair 2068 that asks what the
machine might have looked like with a structured BASIC, a persistent
full-screen editor, and software designed around its distinctive hardware.

## Highlights

- A full-screen, word-wrapping program editor with insertion, deletion,
  scrolling, keyword highlighting, per-line error highlighting, and direct
  next/previous-error navigation.
- Line-number-free BASIC using labels, block and single-line `IF`, `FOR` /
  `NEXT`, `EXIT FOR`, `GOTO`, `GOSUB`, `RETurn`, `CALL`, and colon-chained
  statements.
- Numeric variables and arrays, bounded strings, string arrays, classic
  `DEF FN`, and a broad set of numeric, string, screen, joystick, and memory
  functions.
- Pixel graphics, lines, circles, flood fill, High Resolution Graphics color,
  ULAplus palettes, and an eight-slot save-under sprite system with collision
  detection.
- Beeper and AY-3-8912 sound, prompted numeric/string input, and TS2068-framed
  tape `SAVE`/`LOAD`, including `SAVE ... LINE` autorun.
- A loadable BASIC-extension system that adds optional statements without
  consuming the final bytes of either ROM bank. Release 1 Beta includes CPLOT,
  BLOCK, FRAME, INVERT, AYREG, and OUT modules.
- Builds for paired Home ROM/EXROM use, a combined ZEsarUX image, and an
  EightyOne DCK image.

## Loadable commands

Only one extension is installed at a time. Use `LOAD "name" EXT` to install a
module and `SAVE "name" EXT` to record the currently installed module. `NEW`
and ordinary program loading unregister it safely.

- `CPLOT cx,cy` draws coarse block graphics.
- `BLOCK x0,y0 TO x1,y1` draws a filled rectangle.
- `FRAME x0,y0 TO x1,y1` draws a rectangle outline.
- `INVERT x0,y0 TO x1,y1` XOR-inverts a rectangular area.
- `AYREG register,data` writes native AY registers.
- `OUT port,data` performs a full-address Z80 port write for expert hardware
  control.

## Beta validation

The release gate covers 92 integrated BASIC fixtures, standalone ROM smoke
builds and runtime checks, the production editor, storage and extension tape
paths, calculator behavior, sprite graphics/state, documentation consistency,
RAM aliases, and ROM-size limits. The production images currently leave one
byte free in Home ROM and two bytes free in EXROM, with 15,322 bytes available
to the dynamic BASIC program pool.

## Important beta notes

- Keep backups of programs and recordings made with beta builds; the native
  program format may still change before the final Release 1 build.
- Programs are native to 2068-Leap's line-number-free representation and are
  not byte-compatible with stock tokenized Sinclair BASIC programs.
- Physical cassette behavior varies with recorder, medium, cable, and signal
  level. Emulator tests validate the framing and ROM logic but cannot qualify
  every analog setup.
- OUT and AYREG are deliberately low-level. OUT can change display, sound,
  tape, add-on, or memory-paging hardware depending on the port selected.
- Cartridge support and a public cartridge ABI are outside this beta's scope.

## Download and documentation

Attach the paired Home ROM and EXROM images, the combined ZEsarUX image, the
EightyOne DCK image, the six extension recordings, release notes, and the Word
and Markdown user documentation, including the separate What's New guide, to
the GitHub beta release. The repository
README contains build instructions; the User's Manual contains the complete
implemented statement/function reference and a dedicated extension chapter.

Feedback is especially welcome for real TS2068 hardware, cassette loading,
editor ergonomics, program compatibility between beta builds, and examples
that exercise the graphics, sound, sprite, and extension systems together.
