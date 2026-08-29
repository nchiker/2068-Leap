# 2068 Leap private preview

This preview is the first complete, test-gated snapshot of 2068 Leap. It is
intended for invited testing while the GitHub repository remains private.

## Highlights

- Structured, line-number-free BASIC with a full-screen editor.
- Numeric scalars and arrays, fixed-length strings and string arrays.
- Timex high-resolution graphics, normal Spectrum graphics, sprites, AY sound,
  and ULAplus palette control with editor-safe mode restoration.
- Stock TS2068/Sinclair tape framing for `SAVE` and `LOAD`, including progress
  reporting and staged validation before replacing the current program.
- Screen queries through `POINT()` and `ATTR()`.
- User manual in Markdown and styled Word formats, plus language, technical,
  memory-map, and programmer references.

## Validation baseline

- 68 integrated BASIC fixtures.
- Nine standalone smoke ROMs assemble successfully.
- Automated wrapped-line editor regression passes.
- Showcase validation reaches its green completion border.
- Home ROM: 13 bytes free; EXROM: 99 bytes free; dynamic RAM pool: 1857 bytes.

## Startup compatibility fix

- Cold start now clears the ROM-owned `$8000-$BFFF` RAM region before any
  subsystem initialization. This prevents randomized power-on RAM from being
  mistaken for valid bank, port-shadow, editor, calculator, or hook state.
- A memory smoke regression pre-fills that complete region with `$A5`, invokes
  cold initialization, and verifies that every byte was cleared.

## Preview boundaries

This is a redesigned BASIC rather than a byte-compatible replacement for
stock Sinclair BASIC programs. Native program payloads use standard tape
framing but are not stock tokenized BASIC. The repository remains private
while preview feedback and hardware testing continue.
