# Fuse TS2068 ULAplus patch

`0001-Add-ULAplus-support-for-Timex-machines.patch` adds ULAplus rendering
and peripheral support for Timex machines to Fuse. It was produced against
the upstream Fuse revision described by `fuse-1.9.1-21-gdd48d9fc`.

From a compatible Fuse source checkout:

```sh
git am /path/to/0001-Add-ULAplus-support-for-Timex-machines.patch
```

Then build and install Fuse using its normal instructions.

This patch modifies the GPL-licensed Fuse emulator and is distributed under
the same GNU General Public License, version 2 or (at your option) any later
version. See `COPYING`. The repository's MIT license applies to 2068-Leap,
not to this Fuse patch or the upstream Fuse project.

# ZEsarUX EXROM-mirroring patch

`0001-zesarux-mirror-ts2068-exrom.patch` is **required** to run this project
under ZEsarUX at all — see
[`../docs/emulator_setup.md`](../docs/emulator_setup.md#zesarux) for why.
Real TS2068/TC2068 hardware doesn't decode the EXROM chip's upper address
lines, so the physical 8K EXROM repeats itself across all eight 8K memory
chunks (0-7). Stock ZEsarUX 13.0 only mirrors chunk 0 into chunk 1, not the
other six. This project's production editor lives entirely in EXROM chunk 6
(`$C000-$DFFF`, per `docs/memory_map.md`), so a stock, unpatched ZEsarUX
build shows a blank screen on boot — the CPU runs off into whatever
unmirrored garbage bytes happen to sit in that chunk. Nine lines changed in
`src/machines/timex.c`, applies cleanly to upstream tag `ZEsarUX-13.0`:

```sh
git clone https://github.com/chernandezba/zesarux.git
cd zesarux && git checkout ZEsarUX-13.0
git am /path/to/0001-zesarux-mirror-ts2068-exrom.patch
cd src && ./configure && make -j"$(nproc)"
```

Confirmed by direct A/B test against this project's own
`build/ts2068rom_zesarux.bin` — same ROM file, same `--romfile` invocation,
only the ZEsarUX binary differs. Screenshots: `docs/images/
zesarux_patched_boot.png` (boots correctly) vs. `docs/images/
zesarux_stock_boot.png` (blank screen). This patch modifies the GPL-licensed
ZEsarUX emulator; see ZEsarUX's own licensing terms. The repository's MIT
license applies to 2068-Leap, not to this patch or the upstream ZEsarUX
project.

The `EightyOne/` directory contains the original user-supplied setup note and
screenshots for EightyOne v1.41. Its instructions are incorporated into the
maintained [`docs/eightyone_setup.md`](../docs/eightyone_setup.md), and the
normal build now generates the required `build/exrom.dck` cartridge image.
