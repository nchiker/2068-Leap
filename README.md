# 2068-Leap

### ▶ [Try it now, live in your browser — no install](https://nchiker.github.io/TSRun/?rom=leap)

### 📖 [User Manual](docs/user_manual.md) ([Word/DOCX version](docs/2068_Leap_Users_Manual.docx))

2068-Leap is an alternate-history ROM for the Timex Sinclair 2068: a
structured BASIC, a real full-screen editor, AY sound, and TS2068-specific
graphics, built as documented kernel modules instead of the tangled
monolith of the original ROM — while still fitting a stock 48K machine and
staying instant-on.

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

- **No line numbers.** Programs are edited in place; `GOTO`/`GOSUB` targets
  are case-insensitive labels instead.
- **A real full-screen editor** — insert/delete lines, UP/DOWN navigation,
  automatic scrolling, live keyword bolding, and a status bar, not a
  line-by-line REPL.
- **A whole-program static check pass before every `RUN`** — broken lines are
  red-highlighted immediately, with `SYMBOL SHIFT+A`/`SYMBOL SHIFT+S` to jump
  directly between them, and a program with errors never half-runs.
- **Structured control flow**: block and single-line `IF`/`ELSEIF`/`ELSE`,
  `FOR`/`NEXT`, `GOSUB`/`CALL`/`RETURN`, and colon-separated statements on one
  line.
- **Real runtime error handling** — a message plus the failing statement's
  text, then a clean stop, instead of silent failure or a hang.
- **A real floating-point calculator engine** (`RST $28`, EXROM-resident,
  reworked from the original Spectrum ROM's) behind `SQR`/`SIN`/`COS` and
  friends, alongside a fast all-integer arithmetic core for everyday
  expressions.
- **Graphics built for the TS2068**: `PLOT`/`LINE`/`CIRCLE`/`FILL`, an
  eight-slot sprite system with collision detection, `MODE 1` (Extended
  Color), and full `ULAPLUS`/`PALETTE` support.
- **AY-3-8912 sound** — `BEEP` and register-level `SOUND`.
- **TS2068-framed tape `SAVE`/`LOAD`**, plus six loadable BASIC extensions
  (`CPLOT`, `BLOCK`, `FRAME`, `INVERT`, `AYREG`, `OUT`) that load from tape on
  demand rather than costing ROM space in every build.
- **EXROM banking** — a second 8K ROM bank for sprites and the calculator
  engine, keeping the hot editor/interpreter path in the always-visible 16K
  Home ROM.

See [`docs/technical_overview.md`](docs/technical_overview.md) for the full
architectural writeup, or jump straight to "Try it" below for a hands-on
tour.

## Try it

**Fastest path: [nchiker.github.io/TSRun/?rom=leap](https://nchiker.github.io/TSRun/?rom=leap)**
— runs the full product directly in your browser via
[TSRun](https://github.com/josef-jelinek/TSRun), no download, build, or
emulator install needed.

For a local emulator instead, grab a built ROM from the latest release (see
"Download" below), or build it yourself (see "Building from source"). Try,
across separate ENTER presses:

```
x = 5
PRINT x
RUN
```

Typing a recognized keyword in lowercase flips it to bold uppercase as you
type it. Try labels and `GOTO`:

```
x = 1
loop:
PRINT x
x = x + 1
IF x > 5 THEN
END
END IF
GOTO loop
RUN
```

Try graphics and sprites:

```
CIRCLE 100,100,30
INK 2
FILL 100,100
```

See [`docs/user_manual.md`](docs/user_manual.md) for a complete,
example-driven tour of the language, and
[`demos/showcase.txt`](demos/showcase.txt) for a longer program exercising
`DEF FN`, structured flow, graphics, ULAplus, arrays, sprites, AY sound, and
strings — run it interactively with `tools/run_demo.sh showcase`.

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

Full per-emulator setup, including how to load the six tape-based BASIC
extensions, is in [`docs/emulator_setup.md`](docs/emulator_setup.md).

## Status

**Release 1 Beta candidate.** The integrated ROM provides a full-screen
editor, structured BASIC, graphics, sound, EXROM banking, and TS2068-framed
SAVE/LOAD. `make test` runs the 92-fixture integrated language suite under
Fuse on every build. See
[`docs/whats_new_release_1_beta.md`](docs/whats_new_release_1_beta.md) for
what's changed since Public Preview 1, or
[`docs/development_log.md`](docs/development_log.md) for the full,
module-by-module build history and every bug found and fixed along the way.

This is beta software — keep backups of programs saved with beta builds,
since the native program payload may still evolve before the final
Release 1 build.

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
- `extensions/*.tzx` — the six loadable BASIC extensions
  (`CPLOT`/`BLOCK`/`FRAME`/`INVERT`/`AYREG`/`OUT`).
- `docs/`, `patches/`, `SHA256SUMS.txt` — manuals (Markdown + DOCX), the two
  emulator patches above, and a checksum manifest.

`make release-assets` produces the same zip locally.

## Building from source

Requires GNU Make, Python 3, and
[SjASMPlus 1.23.1](https://github.com/z00m128/sjasmplus/releases/tag/v1.23.1)
or a compatible newer release.

```sh
make check    # build + static checks + smoke ROMs
make budget   # report exact Home ROM / EXROM / RAM margins
make test     # full 92-fixture Fuse regression suite (needs Fuse + X11)
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
basic/      the BASIC interpreter — calls kernel/ APIs only, never hardware
graphics/   TS2068 graphics modes, built on kernel/io primitives
sound/      AY-3-8912 driver and music/sound-effect layer
include/    shared symbolic constants and the kernel API contract
docs/       user manual, technical overview, programmer's reference, and
            per-emulator setup guides — see below
examples/   sample BASIC/assembly programs
```

## Documentation

- [`docs/user_manual.md`](docs/user_manual.md) — the maintained,
  example-driven user manual ([DOCX edition](docs/2068_Leap_Users_Manual.docx),
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
