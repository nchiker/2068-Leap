# 2068-Leap V2 -- User Manual and Language Reference

**For the Timex Sinclair 2068 with the 2068-Leap V2 Enhanced ROMs.**

*Development edition* (branch `v2-development`). It describes the current emulator-qualified release, **v2.0.1-emu.1**, together with the larger memory pool of the later development ROM: on the release ROM the pool is 8397 bytes and `FREE()` on an empty machine is 8153, where this edition gives the development figures of 9211 and 8967 (see the concept [Memory](04_concepts.md#memory)). Everything else applies to both. The manual exactly as published with the release is inside `2068-Leap-V2-v2.0.1-emu.1.zip` (`docs/manual/`).

---

## Contents

| Part | What it is for |
|---|---|
| [Part 1, Introduction](01_introduction.md) | what 2068-Leap V2 is, how to start it, how this manual works |
| [Part 2, Beginner's guide](02_beginners_guide.md) | a step-by-step course: the editor, your first program, numbers, words, decisions, loops, procedures, arrays, the screen, sound, tapes |
| [Part 3, Keywords](03_keywords.md) | every statement, function, operator and command, A to Z, with examples |
| [Part 4, Concepts](04_concepts.md) | the ideas behind the language, A to Z: numbers, strings, arrays, sessions, tapes, errors, memory ... |
| [Part 5, Packages](05_packages.md) | the six loadable packages: mode, sprite, printer, shapes, graphics, cbeep |
| [Part 6, Practical examples](06_examples.md) | complete programs to type in and change |
| [Appendices](07_appendices.md) | messages, error codes, character set, limits, memory map, package card, hardware notes, keyword index |

The manual follows the plan of the *Sinclair QL User Guide*: a gentle beginner's guide, then a keyword reference and a concepts reference each in alphabetical order, with the tables at the back.

## What 2068-Leap V2 is

The Timex Sinclair 2068 normally starts in the BASIC of its ROM. **2068-Leap** replaces that ROM with a new one: a full-screen program editor, a modern structured BASIC without line numbers, a compiler that checks the whole program before it runs it, floating-point arithmetic, strings and arrays, sound, graphics and tape storage, all within the machine's original 16 KB ROM and the 8 KB extension ROM (EXROM) of the Timex hardware.

**V2** is the current version. It is a new design, not a small change to the first release ("V1 Release 1 Beta"): the earlier system read the program text again, statement by statement, every time it ran it, and its arithmetic was almost entirely whole-number. V2 compiles the program when you `RUN` it, has real numbers, long names, string and numeric arrays, procedures that call themselves, and keeps your variables when a program stops so that you can look at them. V1's manual (`docs/v1/user_manual.md`) remains in the repository as history; **do not use it to learn V2**.

Its main features:

* a full-screen **editor** with bold keywords and a status line;
* programs **without line numbers**: labels, `IF` blocks, `FOR` loops, procedures (`PROC`/`CALL`), one-line functions (`DEF FN`);
* whole numbers and 5-byte **floating-point** numbers, converted automatically, with maths functions in degrees;
* 21 **user-defined characters** that you design yourself (defined with `POKE`, printed with `CHR$(144)` to `CHR$(164)`);
* **strings** up to 31 characters and the full set of string functions;
* **arrays** of numbers and of strings, which can be saved to tape on their own and kept across runs (the *Array Store*);
* **sessions**: the variables of a program that stopped stay available to typed statements;
* tape **SAVE**, **LOAD** and **VERIFY** for programs, arrays, and whole programs with their variables;
* sound from the AY sound chip (`BEEP` in seconds and semitones, `SOUND` for the chip's registers), and from the loudspeaker with the optional `CBEEP` package;
* graphics: `PLOT`, `LINE`, colours; and, from loadable **packages**, circles, filled areas, rectangles, sprites, the printer and the TS2068's special video modes.

## The status of this release

2068-Leap V2 Enhanced has been through a complete qualification **in the ZEsarUX emulator**: more than a thousand automated tests of the language, the editor, the tape routines and the packages. The release is called *emulator-qualified*: **it has not been tried on a physical TS2068**, a real cassette recorder, a ZX Printer or a joystick (see [Appendix G](07_appendices.md#appendix-g-hardware-notes)). Everything in this manual that depends on hardware says so.

Every example in this manual has been run on the release, by an automated test, and produced exactly the output shown (see [Appendix I](07_appendices.md#appendix-i-how-this-manual-was-checked)).

## Starting it

**On an emulator.** Use the files of the release (`roms/leap_v2_home.bin` and `roms/leap_v2_exrom.bin`, or the combined `roms/leap_v2_zesarux.bin`) as the TS2068's ROM and EXROM. The [emulator setup guide](../EMULATOR_SETUP.md) describes ZEsarUX (the emulator the release is qualified on), EightyOne and Fuse. (A stock ZEsarUX 13.0 does not map the EXROM the way the real hardware does and shows a blank screen; use the patched one described there.) Switch on and the editor appears.

**On a TS2068.** Fit the two ROM images in place of the ROM and the extension ROM. Nothing about real hardware has been tested.

The package tapes are `.tzx` files for an emulator's tape interface: `v2_mode.tzx`, `v2_sprite.tzx`, `v2_printer.tzx`, `v2_shapes.tzx`, `v2_graphics.tzx`, `v2_cbeep.tzx`. A package is loaded by typing `LOAD "NAME" EXT` (for example `LOAD "SHAPES" EXT`) and starting the tape; Fuse does not start the tape automatically.

## How to read this manual

* **Type the examples.** They are small. Change numbers and words and see what happens.
* In the text, `COMMANDS AND PROGRAM TEXT` are in a typewriter face. The language is not case-sensitive: `print` and `PRINT` are the same, and the editor will show keywords in bold either way.
* A box of program text is a **program**: type each line on its own line. A line in a box beginning with a colon, such as `: PRINT x`, is typed on the editor's last line after the program has run.
* A box labelled with output shows **exactly** what appeared on the screen. A picture shows what the screen looked like. In a listing of a whole screen, a line of three dots (`...`) stands for any number of blank rows (the empty part of the screen above the status line).
* A *typed* example (keys, then the screen) shows the lines as they were typed, one after another, each ended with ENTER, and then the screen as it looked.
* Words in *italics* in a syntax line are things you supply.
* The language reference parts are in alphabetical order. Where something has two names (a keyword and the concept it belongs to) each points to the other.

## What changed from V1, in one paragraph

If you used V1: there are still no line numbers, but now `RUN` compiles the whole program first. Names are long (31 characters), numbers can have fractions, `INT` truncates toward zero, `AND`/`OR` skip what they do not need, `IF` is always a block closed by `ENDIF`, subroutines are `PROC`/`CALL`, `GOSUB` is gone, arrays hold strings too, and `LPRINT`, the sprites, `CIRCLE`/`FILL`, `MODE` and others are on tape as packages. The full list is the table in the concept [Differences from Sinclair BASIC](04_concepts.md#differences-from-sinclair-basic) and `docs/V2_FEATURE_MATRIX.md`.
