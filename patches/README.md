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
version. See `COPYING`. The repository's MIT license applies to 2068 Leap,
not to this Fuse patch or the upstream Fuse project.

The `EightyOne/` directory contains the original user-supplied setup note and
screenshots for EightyOne v1.41. Its instructions are incorporated into the
maintained [`docs/eightyone_setup.md`](../docs/eightyone_setup.md), and the
normal build now generates the required `build/exrom.dck` cartridge image.
