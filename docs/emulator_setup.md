# Emulator setup for 2068-Leap Release 1 Beta

The beta release supports three tested emulator configurations. Use the files
listed for your emulator; similarly named files are not interchangeable.

## Release files

| File | Size | Used by |
|---|---:|---|
| `test_basic.bin` | 16,384 bytes | Home ROM for Fuse and EightyOne |
| `exrom.bin` | 8,192 bytes | EXROM slot 6 for Fuse |
| `exrom.dck` | 8,201 bytes | Timex ROM cartridge for EightyOne 1.41 |
| `ts2068rom_zesarux.bin` | 24,576 bytes | Combined Home ROM + EXROM image for ZEsarUX |
| `cplot.tzx`, `block.tzx`, `frame.tzx`, `invert.tzx`, `ayreg.tzx`, `out.tzx` | varies | Loadable BASIC extensions through the emulator's tape interface |

Verify downloads with `SHA256SUMS.txt` before diagnosing an emulator problem.
Do not rename `exrom.bin` to `.dck`: the EightyOne file contains a required
nine-byte cartridge header.

## Fuse

Fuse uses the separate Home and EXROM images:

```sh
fuse --machine ts2068 \
  --rom-ts2068-0 roms/test_basic.bin \
  --rom-ts2068-1 roms/exrom.bin
```

The 16K image is ROM 0. The 8K image is the TS2068 EXROM mapped into slot 6;
it is not a Dock cartridge. Upstream Fuse 1.9.1 does not expose ULAplus for the
TS2068, so the base ROM works but ULAplus demonstrations require the optional
project patch at
`patches/0001-Add-ULAplus-support-for-Timex-machines.patch` or ZEsarUX. The
patch targets the compatible Fuse source revision stated in the main README;
ordinary Fuse users can simply leave ULAplus disabled.

To load a BASIC extension, open one of the `.tzx` files in Fuse's tape browser,
enter `LOAD "CPLOT" EXT` (substitute its recorded name), press Play in the tape
browser, and wait for the completion status. Fuse does not automatically start
this custom loader's tape playback.

## ZEsarUX

**A stock, unpatched ZEsarUX 13.0 download cannot run this ROM correctly —
it shows a blank screen on boot.** This project's production editor lives
entirely in EXROM chunk 6 (`$C000-$DFFF`), and every interactive session
pages it in immediately (`EDITOR_INIT` runs on the very first
`BASIC_COMMAND_LOOP` iteration). Real TS2068/TC2068 hardware mirrors the
physical EXROM chip across all eight 8K memory chunks, since the chip's
upper address lines aren't decoded; stock ZEsarUX 13.0 only mirrors chunk 0
into chunk 1, so chunk 6 contains unmirrored garbage under stock ZEsarUX and
the CPU runs off into it the moment the editor tries to start. Confirmed by
direct A/B test against this project's own `build/ts2068rom_zesarux.bin` —
same ROM file, same invocation below, only the ZEsarUX binary differs;
screenshots at `docs/images/zesarux_patched_boot.png` and `docs/images/
zesarux_stock_boot.png`.

Build ZEsarUX with
[`../patches/0001-zesarux-mirror-ts2068-exrom.patch`](../patches/0001-zesarux-mirror-ts2068-exrom.patch)
applied — see [`../patches/README.md`](../patches/README.md) for the exact
build steps. This is a different patch, targeting a different upstream
project, from the Fuse ULAplus patch described above; they are unrelated to
each other.

ZEsarUX uses the single combined image:

```sh
zesarux --noconfigfile --machine TS2068 \
  --romfile roms/ts2068rom_zesarux.bin \
  --enableulaplus
```

The combined file is exactly the 16K Home ROM followed by the 8K EXROM. Do not
select `test_basic.bin` alone when using `--romfile`; BASIC relies on EXROM
services. `--enableulaplus` is recommended for the palette examples, although
ordinary editor, BASIC, graphics, sprite, and sound operation does not require
ULAplus.

Load extension `.tzx` files through ZEsarUX's tape controls, then enter the
matching `LOAD "name" EXT` command in 2068-Leap.

## EightyOne 1.41

EightyOne uses the Home ROM plus a DCK-wrapped Timex cartridge:

1. Open hardware configuration and select the **Timex** tab and **TS2068**.
2. Under **Advanced Settings**, choose `roms/test_basic.bin` as **ROM File**.
3. Leave **Protect ROM from Writes** enabled.
4. Under **Interfaces**, set **ROM Cartridge** to **Timex** and choose
   `roms/exrom.dck`.
5. Apply the configuration and perform a hard reset.

Do not choose raw `exrom.bin` in EightyOne's cartridge field. Version 1.41
validates the Timex cartridge container, and `exrom.dck` is the release asset
built for that interface.

The ROM clears all RAM it owns during cold start, so it should boot with either
zero-filled or randomized power-on RAM. Randomized RAM is the stronger
compatibility setting.

## Loadable-extension behavior

Only one extension can be installed at a time. The recorded names are CPLOT,
BLOCK, FRAME, INVERT, AYREG, and OUT. Use:

```basic
LOAD "FRAME" EXT
```

`NEW` and an ordinary program `LOAD` unregister the module. Therefore, load a
saved BASIC program first and its required extension second. The `.tzx` files
are Direct Recording images because the custom program/extension transport
uses live TS2068 pulse framing rather than a stock-ROM tape trap.

## Reporting emulator problems

Include the emulator and exact version, host operating system, selected ROM
files, their SHA-256 hashes, and the smallest program or sequence that
reproduces the issue. A screenshot and the emulator configuration are helpful.
State whether the same files boot in another emulator if you can test one.
