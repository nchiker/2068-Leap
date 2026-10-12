# 2068-Leap

### ▶ [Try it now, live in your browser — no install](https://nchiker.github.io/TSRun/?rom=leap)

> **2068-Leap V2 Enhanced -- Emulator-Qualified Release** (tag `v2.0.0-emu.1`, branch `v2-development`) is
> the current system. **Start with the [V2 User Manual](docs/v2/manual/01_introduction.md)** -- a
> beginner's guide, an alphabetical keyword reference and concepts reference, the five packages,
> practical examples and appendices, every example of which is run on the release ROM by
> `make doc-examples` -- and the compact [language reference](docs/v2/V2_LANGUAGE_REFERENCE.md). The
> release status is in [`docs/v2/V2_RC_STATUS.md`](docs/v2/V2_RC_STATUS.md). Physical TS2068 hardware: **not
> tested**.

### 📖 [V2 User Manual](docs/v2/manual/01_introduction.md) · [Language reference](docs/v2/V2_LANGUAGE_REFERENCE.md) · [Word edition](docs/v2/2068_Leap_V2_Users_Manual.docx)

> The Release 1 Beta ("V1") manual, [`docs/user_manual.md`](docs/user_manual.md), is kept as history. V1
> programs have line numbers and V1 tapes are refused; most of that manual does **not** apply to V2.

2068-Leap is an alternate-history ROM for the Timex Sinclair 2068: a
structured BASIC, a real full-screen editor, AY sound, and TS2068-specific
graphics, built as documented kernel modules instead of the tangled
monolith of the original ROM — while still fitting a stock 48K machine and
staying instant-on.

**Current production builds use the Architecture B V2 BASIC environment.**
Programs have **no line numbers**: they are lists of editable lines, with labels, `IF` blocks, `FOR` loops
and procedures. `RUN` compiles the whole program to bytecode and executes it in the V2 VM, so a mistake
anywhere is reported before anything runs. The Release 1 Beta manual and change log remain historical
references. See the [V2 status document](docs/v2/V2_RC_STATUS.md) for what the release is, how it was
qualified and what is still open.

See the sibling project [2068-Leap-Forth](https://github.com/nchiker/2068-Leap-Forth)
for a from-scratch Forth built on the same hardware kernel.

The project is open source under the [MIT License](LICENSE). It is an
independent community project and is not affiliated with Timex, Sinclair,
Fuse, ZEsarUX, or the ULAplus project.

## What makes 2068-Leap different

This isn't a compatibility clone of stock Sinclair BASIC — it's a from-scratch
redesign of what the TS2068's own ROM could have been, still instant-on and
usable on a stock 48K machine.

Highlights:

- **An in-place full-screen line editor** with unnumbered source lines,
  insert/replace/delete, navigation, bold keywords, and LIST.
- **Whole-program compilation on RUN** — the editor keeps plain-text source;
  the V2 compiler emits bytecode for the V2 VM.
- **Structured control flow and runtime errors**, including `IF`, `FOR`,
  labels, procedures, and clean recovery to the editor.
- **Integer and floating-point expressions**, strings, arrays, and the
  TS2068 calculator services.
- **TS2068 graphics and sound**: `PLOT`, `LINE`, `BEEP`, `SOUND`, plus the loadable
  sprite, MODE/ULAPLUS/PALETTE, CIRCLE/FILL and graphics packages.
- **Editable plain-text BASIC programs** in the generic line store. `RUN`
  compiles the complete program to V2 bytecode and executes it; tape SAVE/LOAD
  persists source (and, with `SAVE ... ALL`, the variables and arrays) and regenerates
  bytecode on the next RUN. A program's variables survive its stopping, so typed
  statements can inspect and change them (`: PRINT total`).
- **Five loadable V2 packages**: MODE/ULAplus/PALETTE, sprites (`GRAB`, `SHOW`,
  `HIDE`, `MOVE`), printer (`LPRINT` and source-based `LLIST`), CIRCLE/FILL, and the
  graphics package (`CPLOT`, `BLOCK`, `FRAME`, `INVERT`). One package occupies the 1KB
  package window at a time.
- **EXROM banking** — a second 8K ROM bank for sprites and the calculator
  engine and interactive shell, while the V2 compiler and VM run from the
  always-visible 16K Home ROM.

See [`docs/technical_overview.md`](docs/technical_overview.md) for the full
architectural writeup, or jump straight to "Try it" below for a hands-on
tour.

## Try it

For a local emulator, grab a built ROM from the latest release (see
"Download" below), or build it yourself (see "Building from source"). You
are in the editor when the machine starts. There are no line numbers: type each
line, pressing ENTER after it, then type `RUN` on the empty line that follows:

```
x = 5
PRINT x * 2
RUN
```

Press any key to return to the editor. A program that uses a loop and a label:

```
n = 0
again:
n = n + 1
PRINT n
IF n < 3 THEN GOTO again
RUN
```

To try `CIRCLE` and `FILL`, load the SHAPES package first (type `LOAD "SHAPES" EXT` and start the tape), then
enter:

```
CIRCLE 128, 96, 40
FILL 128, 96
RUN
```

The [V2 User Manual](docs/v2/manual/01_introduction.md) starts from the beginning (Part 2, the beginner's
guide) and has a reference entry with examples for every keyword. The older V1 demo programs and
examples in `demos/` and `examples/` use V1 syntax and are retained as historical examples; they are not
compatible with the V2 production language.

## Running it locally

### Fuse

```sh
fuse --machine ts2068 --rom-ts2068-0 test_basic.bin --rom-ts2068-1 exrom.bin
```

Works out of the box with any stock Fuse build. Upstream Fuse 1.9.1 doesn't
expose ULAplus on the TS2068 — use ZEsarUX instead for the palette examples,
or apply this project's own
[Fuse ULAplus patch](patches/0001-Add-ULAplus-support-for-Timex-machines.patch).

### ZEsarUX

```sh
zesarux --noconfigfile --machine TS2068 --romfile ts2068rom_zesarux.bin --enableulaplus
```

**A stock, unpatched ZEsarUX 13.0 download cannot run this ROM at all** — it
shows a blank screen, since ZEsarUX only mirrors the TS2068 EXROM into
chunks 0-1 and this project's production editor lives in chunk 6. A required
patch is included at
[`patches/0001-zesarux-mirror-ts2068-exrom.patch`](patches/0001-zesarux-mirror-ts2068-exrom.patch) —
see [`docs/emulator_setup.md`](docs/emulator_setup.md#zesarux) for the exact
build steps and confirming A/B screenshots.

### EightyOne (Windows, or Linux via Wine)

Select the TS2068 machine, use `test_basic.bin` as the ROM file, and use
`exrom.dck` as a **Timex ROM Cartridge** (not the raw `exrom.bin`). See
[`docs/eightyone_setup.md`](docs/eightyone_setup.md) for the exact
configuration steps.

Full per-emulator setup, including how to load the V2 packages, is in
[`docs/emulator_setup.md`](docs/emulator_setup.md).

## Status

**2068-Leap V2 Enhanced is the current system: an emulator-qualified release** (tag `v2.0.0-emu.1`). The
production ROM boots the V2 editor, whole-program compiler, and VM; five V2 packages are built
separately (the six optional V1 packages are not part of V2). It passed the documented emulator
qualification (a 667-case language corpus, the full `make test` gate, the editor, tape and package
suites -- 1010 cases in all); the accepted limitations are in
[`docs/v2/V2_DEFECT_REGISTER.md`](docs/v2/V2_DEFECT_REGISTER.md). **It has not been tried on a physical
TS2068**: hardware qualification is deferred ([`docs/v2/V2_HARDWARE_CHECKLIST.md`](docs/v2/V2_HARDWARE_CHECKLIST.md)).
Start with [`docs/v2/V2_RC_STATUS.md`](docs/v2/V2_RC_STATUS.md). The V2 user manual's examples are a separate
test suite (`make doc-examples`) and do not change the release baseline. The V1 notes
([`docs/whats_new_release_1_beta.md`](docs/whats_new_release_1_beta.md),
[`docs/development_log.md`](docs/development_log.md)) are the history of earlier work.

The 102 legacy V1 source fixtures remain under `tests/` for static checking
and historical reference; they are not the production V2 runtime test suite.

This is an emulator-qualified release, not yet tried on physical hardware: keep backups of programs saved
on tape, and see the hardware notes in the manual's Appendix G.

## Download

[![Source checks](https://github.com/nchiker/2068-Leap/actions/workflows/check.yml/badge.svg)](https://github.com/nchiker/2068-Leap/actions/workflows/check.yml)

You don't need the assembler to try it. Every push to `main` rebuilds
everything below and packages it with the docs:

- **Latest build** (rebuilt on every push):
  [2068-Leap-latest.zip](https://github.com/nchiker/2068-Leap/releases/download/latest/2068-Leap-latest.zip)
- **Numbered releases**: the [releases page](https://github.com/nchiker/2068-Leap/releases).
- Every push and pull request also gets a build artifact on the
  [Actions](https://github.com/nchiker/2068-Leap/actions) tab, if you want an
  image from a specific commit without waiting for a release.

The zip contains, per [`docs/emulator_setup.md`](docs/emulator_setup.md):

- `roms/test_basic.bin` — 16K Home ROM, the product.
- `roms/exrom.bin` — 8K EXROM (chunk 6), for Fuse.
- `roms/exrom.dck` — the EXROM wrapped as a Timex ROM Cartridge, for
  EightyOne 1.41.
- `roms/ts2068rom_zesarux.bin` — Home ROM + EXROM concatenated, for ZEsarUX.
- `extensions/*.tzx` — the V2 package tapes (MODE, SPRITE, PRINTER, SHAPES; `make rc-assets` collects all
  five, with GRAPHICS, in `build/release-v2-rc/`).
- `docs/`, `patches/`, `SHA256SUMS.txt` — manuals (Markdown + DOCX), the two
  emulator patches above, and a checksum manifest.

`make release-assets` produces the same zip locally.

## Building from source

Requires GNU Make, Python 3, and
[SjASMPlus 1.23.1](https://github.com/z00m128/sjasmplus/releases/tag/v1.23.1)
or a compatible newer release.

```sh
make check    # build + static checks + smoke ROMs
make budget   # report exact Home ROM / EXROM / integrated V2 RAM regions
make test     # full regression gate, including 14 V2 ZEsarUX fixtures
make doc-examples   # every example of the V2 manual, run on the release image
```

The production images are written to `build/test_basic.bin` (Home ROM),
`build/exrom.bin` (EXROM slot 6), `build/exrom.dck` (EightyOne cartridge),
and `build/ts2068rom_zesarux.bin` (combined image for ZEsarUX). Generated
ROMs are deliberately not committed to the repository — see "Download" above
for prebuilt images, or build your own with the commands above.

`make test` additionally requires Fuse, `python3-xlib`, and Pillow, plus an
X11 display.

## Layout

```
rom/        top-level ROM image assembly (ORG, module includes, entry vectors)
kernel/     hardware-facing modules, reusable by other assembly software
  editor/   standalone reference/test copy; production editor is in EXROM
  io/       keyboard and joystick primitives
  memory/   line storage, program iterator, labels, and allocator
  interrupt/interrupt handling
  basic/      retained V1 language-core source; not linked into production
graphics/   TS2068 graphics modes, built on kernel/io primitives
sound/      AY-3-8912 driver and music/sound-effect layer
include/    shared symbolic constants and the kernel API contract
docs/       user manual, technical overview, programmer's reference, and
            per-emulator setup guides — see below
examples/   sample BASIC/assembly programs
```

## Documentation

**V2 (current):**

- [`docs/v2/manual/01_introduction.md`](docs/v2/manual/01_introduction.md) — the **V2 user manual**: introduction,
  [beginner's guide](docs/v2/manual/02_beginners_guide.md), [keywords A-Z](docs/v2/manual/03_keywords.md),
  [concepts A-Z](docs/v2/manual/04_concepts.md), [packages](docs/v2/manual/05_packages.md),
  [practical examples](docs/v2/manual/06_examples.md) and [appendices](docs/v2/manual/07_appendices.md)
  ([Word edition](docs/v2/2068_Leap_V2_Users_Manual.docx), rebuild with `make manual-v2`). Every example is a test.
- [`docs/v2/V2_LANGUAGE_REFERENCE.md`](docs/v2/V2_LANGUAGE_REFERENCE.md) — the compact language reference.
- [`docs/v2/V2_RC_STATUS.md`](docs/v2/V2_RC_STATUS.md) — release status; [`docs/v2/V2_DEFECT_REGISTER.md`](docs/v2/V2_DEFECT_REGISTER.md),
  [`docs/v2/V2_FEATURE_MATRIX.md`](docs/v2/V2_FEATURE_MATRIX.md), [`docs/v2/V2_SESSION_VARIABLES.md`](docs/v2/V2_SESSION_VARIABLES.md),
  [`docs/v2/V2_SAVE_ALL_FORMAT.md`](docs/v2/V2_SAVE_ALL_FORMAT.md), [`docs/v2/PACKAGE_ABI.md`](docs/v2/PACKAGE_ABI.md) (for package
  authors).
- [`docs/v2/V2_DOCUMENTATION_FINDINGS.md`](docs/v2/V2_DOCUMENTATION_FINDINGS.md) — what the documentation work found.

**V1 (historical, Release 1 Beta; line-numbered BASIC):**

- [`docs/user_manual.md`](docs/user_manual.md) — the V1 manual ([DOCX edition](docs/2068_Leap_Users_Manual.docx),
  rebuild with `make manual`).
- [`docs/technical_overview.md`](docs/technical_overview.md) — the shareable
  architectural and feature overview.
- [`docs/emulator_setup.md`](docs/emulator_setup.md) — maps release assets to
  tested Fuse, ZEsarUX, and EightyOne 1.41 configurations.
- [`docs/whats_new_release_1_beta.md`](docs/whats_new_release_1_beta.md) —
  user-visible changes since Public Preview 1.
- [`docs/loadable_basic_extensions.md`](docs/loadable_basic_extensions.md) —
  the implementation contract for RAM BASIC statement modules.
- [`docs/programmers_reference.md`](docs/programmers_reference.md) — the full
  design rationale, ROM API, and bug-by-bug history.
- [`docs/development_log.md`](docs/development_log.md) — the module-by-module
  build order and per-module test procedures used while building this ROM.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Changes should preserve both ROM
budgets and pass `make check`; BASIC changes should include a fixture in
`tests/`.
