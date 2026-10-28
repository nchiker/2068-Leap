# 2068-Leap V2 -- emulator setup

How to run the 2068-Leap V2 ROMs in an emulator. **ZEsarUX is the only qualification emulator**: the release `v2.1.0-emu.1` is accepted on ZEsarUX results (more than a thousand automated cases; see [V2_1_RELEASE_STATUS.md](V2_1_RELEASE_STATUS.md)). EightyOne and Fuse are **courtesy** alternatives for people who prefer them: the configurations below are known to start the ROM, but nothing is qualified on them. The browser emulator TSRun is a quick way to try V2 without installing anything. Nothing has been tried on a physical TS2068 ([V2_HARDWARE_CHECKLIST.md](V2_HARDWARE_CHECKLIST.md)).

## The files

From the release archive [`2068-Leap-V2-v2.1.0-emu.1.zip`](https://github.com/nchiker/2068-Leap/releases/tag/v2.1.0-emu.1) (check it first: `sha256sum -c 2068-Leap-V2-v2.1.0-emu.1.zip.sha256`, then `sha256sum -c SHA256SUMS` inside it):

| File in the release | Size | What it is | Used by |
|---|---:|---|---|
| `roms/leap_v2_home.bin` | 16,384 | HOME ROM (the TS2068 system ROM socket) | Fuse (ROM 0), EightyOne (ROM file), TSRun (ROM0) |
| `roms/leap_v2_exrom.bin` | 8,192 | EXROM (the extension ROM; V2 runs it from chunk 6, `$C000-$DFFF`) | Fuse (ROM 1), TSRun (ROM1) |
| `roms/leap_v2_zesarux.bin` | 24,576 | HOME followed by EXROM in one file | ZEsarUX `--romfile` only |
| `roms/leap_v2_exrom.dck` | 8,201 | the EXROM wrapped as a Timex ROM cartridge (9-byte header + EXROM) | EightyOne 1.41; also accepted by TSRun's **Load Cart** |
| `packages/v2_*.tzx` | varies | the six packages as tapes: `mode`, `sprite`, `printer`, `shapes`, `graphics`, `cbeep` | every emulator's tape input |

The qualified ROM hashes (SHA-256) of `v2.1.0-emu.1` are:

| ROM | SHA-256 |
|---|---|
| `leap_v2_home.bin` | `8c3d6c8108b653114ce4fffcd9695ac9883a8068664bffd21524b7ac1d167df0` |
| `leap_v2_exrom.bin` | `e46e2065ee863f0569c3e47cdc975af0081b4e7227b690977eed4fb7d7020f9d` |

(`v2.0.2-emu.1`: HOME `1fe5798f79f31e760780a7c3d1d24657a9aadf12edfa5aef5f82c94040a4f5cc`, EXROM `e6b507a49cef4d6cdd62ae09f8664f20ee84c7931a42bf67e1cf0862322641a0`; `v2.0.1-emu.1`: HOME `3f13ec2cc4ef02c1b9694ccd3d40c02658ff4ddef100e16f50230d3002306f1c`, EXROM `24b1ebb0b1377aad8e2e6caee443a9c5611cfad2f0eab495311e07df43b22b7e`.) The `v2.0.1-emu.1` archive predates the cartridge file: build it from the EXROM with `tools/make_eightyone_dck.sh roms/leap_v2_exrom.bin roms/leap_v2_exrom.dck` (or by hand: `printf '\376\000\000\000\000\000\000\002\000' > leap_v2_exrom.dck && cat leap_v2_exrom.bin >> leap_v2_exrom.dck`); `v2.0.2-emu.1` and later archives include it. The six package tapes of `v2.1.0-emu.1` are byte-identical to those of `v2.0.2-emu.1`.

**Built from source** (`make build`, see the [README](../README.md#building-from-source)) the same images are `build/test_basic.bin` (HOME), `build/exrom.bin` (EXROM), `build/ts2068rom_zesarux.bin` (combined) and `build/exrom.dck` (cartridge); `make v2-packages` writes the tapes to `build/extensions/v2_*.tzx`. A build of the `v2-development` branch is a development build, not the qualified release (its ROMs can differ from the qualified images).

The files are not interchangeable: do not give ZEsarUX the HOME ROM alone, and do not rename the raw EXROM to `.dck`.

## ZEsarUX (qualified)

**Version:** ZEsarUX 13.0 **with the EXROM-mirroring patch**. Real TS2068 hardware does not decode the EXROM chip's upper address lines, so the 8K EXROM appears in all eight 8K chunks; stock ZEsarUX 13.0 mirrors it only into chunks 0 and 1. V2's editor, compiler services and tape routines run from chunk 6, so a stock ZEsarUX 13.0 shows a **blank screen** at power-on. Build ZEsarUX with [`patches/0001-zesarux-mirror-ts2068-exrom.patch`](../patches/0001-zesarux-mirror-ts2068-exrom.patch) (nine lines in `src/machines/timex.c`; it applies to the upstream tag `ZEsarUX-13.0`):

```sh
git clone https://github.com/chernandezba/zesarux.git
cd zesarux && git checkout ZEsarUX-13.0
git am /path/to/2068-Leap/patches/0001-zesarux-mirror-ts2068-exrom.patch
cd src && ./configure && make -j"$(nproc)"
```

**Start** (from the ZEsarUX directory; use an absolute path to the ROM):

```sh
./zesarux --noconfigfile --machine TS2068 --romfile /absolute/path/roms/leap_v2_zesarux.bin
```

Add `--enableulaplus` for the ULAplus examples of the MODE package (`ULAPLUS`, `PALETTE`). The machine starts in the V2 editor after the startup chime; during the chime the status row shows the ROM's version, `2068 LEAP V2.1`, until the first key, which brings the status line `LINE 1/0` back.

**Packages:** insert the package's `.tzx` with ZEsarUX's tape controls, type `LOAD "SHAPES" EXT` (or `MODE`, `SPRITE`, `PRINTER`, `GRAPHICS`, `CBEEP`) on the editor's empty last line, and play the tape; the status line shows `LOADED`. The tapes are Direct Recording images of V2's own tape format, so the emulator must play them as a signal into the EAR input (a stock-ROM loading trap does not apply). One package is resident at a time; loading another replaces it.

**Automated use:** the qualification suites drive this same binary headless through its remote-control port with [ts2068-debug](https://github.com/nchiker/2068-Debug) (`./zesarux --noconfigfile --machine TS2068 --enable-remoteprotocol --remoteprotocol-port 10000 --vo null --ao null --romfile ...`); see [TESTING.md](TESTING.md). The shared three-emulator reference is `skills/ts2068-debug/references/emulators.md` in [z80-skills](https://github.com/nchiker/z80-skills).

## EightyOne 1.41 (courtesy)

EightyOne (Windows; Linux through Wine) uses the HOME ROM plus the EXROM as a **Timex ROM cartridge** (`.dck`). Version 1.41 rejects a raw EXROM in the cartridge field.

1. Open the hardware configuration, select the **Timex** tab and the **TS2068** machine.
2. **Advanced Settings** → **ROM File** = `leap_v2_home.bin`; leave **Protect ROM from Writes** on.
3. **Interfaces** → **ROM Cartridge** = **Timex**, file = `leap_v2_exrom.dck`.
4. Apply, then hard reset.

The ROM clears the RAM it owns at power-on (since `v2.1.0-emu.1` including the user-defined-character table, which earlier ROMs left as they found it), so zero-filled and randomised power-on RAM both work; randomised RAM is the stronger test. The cartridge header's chunk byte places the EXROM in chunk 6, where V2 runs it. Packages load through EightyOne's tape interface as above. These are the steps confirmed by an EightyOne 1.41 user ([eightyone_setup.md](eightyone_setup.md), where the build names `test_basic.bin`/`exrom.dck` are the same images); they were not repeated for this page. EightyOne results are informative only.

## Fuse (courtesy)

Fuse takes the two ROMs separately: the HOME ROM as ROM 0 and the EXROM as ROM 1.

```sh
fuse --machine ts2068 --rom-ts2068-0 /absolute/path/roms/leap_v2_home.bin --rom-ts2068-1 /absolute/path/roms/leap_v2_exrom.bin
```

(The settings are `rom_ts2068_0` / `rom_ts2068_1`; set them in **Options → Select ROMs → Timex TS2068** to keep them.) **Packages:** open the `.tzx` in Fuse's tape browser, type `LOAD "SHAPES" EXT`, then press **Play**: Fuse does not start the tape by itself for V2's loader. **ULAplus:** upstream Fuse 1.9.1 has no ULAplus on Timex machines; use ZEsarUX, or a Fuse built with [`patches/0001-Add-ULAplus-support-for-Timex-machines.patch`](../patches/0001-Add-ULAplus-support-for-Timex-machines.patch) (GPL, like Fuse; see [patches/README.md](../patches/README.md)). The option names were checked against Fuse 1.9.1. Fuse results are informative only.

## In the browser: TSRun

[**nchiker.github.io/TSRun/?rom=leap**](https://nchiker.github.io/TSRun/?rom=leap) runs the `v2.1.0-emu.1` HOME and EXROM (byte-identical to the release's hashes, given above; since 2026-10-28, TSRun `016787f`) in [TSRun](https://github.com/josef-jelinek/TSRun), a browser TS2068 emulator, from our fork [nchiker/TSRun](https://github.com/nchiker/TSRun). Checked on 2026-10-28, headless on TSRun's own machine: eight programs (every character, floats and `SIN`/`COS`/`TAN`, loops, strings, arrays and `PROC`, scrolling, an error) give screens byte-identical to ZEsarUX's, and the `SHAPES` package tape loads with `LOAD "SHAPES" EXT` once the tape is played. Checked earlier with `v2.0.1-emu.1` (2026-10-12): power-on to the editor, typing and running a program, the AY sound (the startup chime and `BEEP`), and the cartridge path (`leap_v2_home.bin` as ROM0 plus `leap_v2_exrom.dck` through **Load Cart**). Click the page or press a key once to let the browser play sound.

**Package tapes** load in TSRun since its commit `4db1f1e` (2026-10-27): TSRun used to stop the tape about 0.1 s after starting it because its loader detection did not recognise V2's loader running from an EXROM chunk other than 0 ([TSRun issue #3](https://github.com/josef-jelinek/TSRun/issues/3)); it now keeps such a tape playing. Checked headless with `v2.1.0-emu.1` and `SHAPES` (above).

## Reporting a problem

Give the emulator and its exact version, the host system, the ROM files and their SHA-256 hashes, and the shortest program or key sequence that shows the problem; say whether the same files behave the same in ZEsarUX.
