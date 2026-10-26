# Licensing notice

The MIT License in `LICENSE` covers 2068-Leap source and documentation unless
a file or directory states otherwise, with the exceptions recorded below.

The optional emulator patch in `patches/` modifies the Fuse emulator and is
distributed under the GNU General Public License version 2 or, at your
option, any later version. See `patches/README.md` and `patches/COPYING`.

Timex, Sinclair, Fuse, ZEsarUX, and ULAplus are names associated with their
respective owners and projects. 2068-Leap is an independent community project
and is not affiliated with or endorsed by them.

## Code derived from the stock ROM

The TS2068's ROM is Timex's adaptation of the ZX Spectrum ROM, whose code is
copyright Amstrad plc (formerly Sinclair Research Ltd). Two parts of 2068-Leap
are derived from it and are not offered under the MIT License; the ROM images
that contain them are redistributed under Amstrad's permission to redistribute
its Spectrum ROM code free of charge:

- `STORAGE_SEND_BLOCK` and `STORAGE_RECEIVE_BLOCK` in
  `kernel/storage/storage.asm` (the tape block I/O, in the EXROM image): a port
  of the stock ROM's SA-BYTES and LD-BYTES, as that file's header states.
- Parts of the calculator engine in `rom/exrom_calc.asm` (EXROM image): its
  header records that it began as a port of the Spectrum ROM's CALCULATE and
  that the literal-decode dispatcher and EXCHANGE were ported directly. No run
  of 12 or more bytes in it equals the stock ROMs.

Both are scheduled for replacement by clean-room code
(`docs/V2_LEAPC_BACKPORT_PLAN.md`, phase 3); this section will then be removed.
`tools/check_provenance.py` (part of `make check` when the stock ROMs are
present) compares the production images with the stock 48K and TS2068 ROMs and
fails on any common run of 12 bytes or more not recorded here.

The block-graphics glyph builder in `kernel/graphics/graphics.asm`, which
contained two 12-byte sequences equal to the stock ROM's PO-GR-2, was replaced
in this branch by clean-room code from 2068-Leap-C (MIT). Earlier releases and
the git history still contain the derived version.

## Code from 2068-Leap-C (MIT)

2068-Leap-C (https://github.com/nchiker/2068-Leap-C, MIT License, copyright
(c) 2026 Charlie Day) is built on this project's platform; code it wrote has
been brought back here: the block-graphics glyph builder, the xorshift used by
`RND`, the register-only `MATH_UMUL16` / `MATH_UDIV16`, `tools/fuse/fuseshim.c`
(loaded into Fuse at test time; it contains no Fuse source), and tools adapted
from Leap-C's (`tools/check_provenance.py`, `tools/check_repro.sh`,
`tools/qual/qpoweron.py`, the banking checks of `tools/qual/qcanary.py`).
