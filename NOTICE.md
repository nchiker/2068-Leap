# Licensing notice

The MIT License in `LICENSE` covers 2068-Leap source and documentation unless
a file or directory states otherwise, with the exceptions recorded below.

The optional emulator patch in `patches/` modifies the Fuse emulator and is
distributed under the GNU General Public License version 2 or, at your
option, any later version. See `patches/README.md` and `patches/COPYING`.

Timex, Sinclair, Fuse, ZEsarUX, and ULAplus are names associated with their
respective owners and projects. 2068-Leap is an independent community project
and is not affiliated with or endorsed by them.

## Code formerly derived from the stock ROM

The TS2068's ROM is Timex's adaptation of the ZX Spectrum ROM, whose code is
copyright Amstrad plc (formerly Sinclair Research Ltd). No part of the current
2068-Leap ROM images is derived from it. Three parts were, until release
`v2.1.0-emu.1` replaced them (`docs/V2_LEAPC_BACKPORT_PLAN.md`, phase 3):

- The tape block I/O (`STORAGE_SEND_BLOCK` / `STORAGE_RECEIVE_BLOCK`, a port
  of SA-BYTES and LD-BYTES): replaced by clean-room code from 2068-Leap-C,
  `kernel/storage/tapeblock.asm`.
- The block-graphics glyph builder in `kernel/graphics/graphics.asm` (two
  12-byte sequences equal to the stock ROM's PO-GR-2): replaced by
  2068-Leap-C's.
- The calculator's literal dispatcher and EXCHANGE in `rom/exrom_calc.asm`,
  whose header recorded them as ported from the Spectrum ROM's CALCULATE and
  EXCHANGE: rewritten in this project to a different design (a table of
  literal, operand count and handler). This rewrite was written from the
  calculator's interface, not by a separated clean-room team: the literal
  values ($01 exchange ... $38 end-calc) and the 5-byte number format are
  kept so literal streams mean what they do to the stock calculator.

`tools/check_provenance.py` (part of `make check` when the stock ROMs are
present) compares the production images with the stock 48K and TS2068 ROMs
and fails on any common run of 12 bytes or more; its allow-list is empty.
The releases `v2.0.0-emu.1` to `v2.0.2-emu.1` and the git history still
contain the derived versions; `v2.1.0-emu.1` is the first release without
them.

## Code from 2068-Leap-C (MIT)

2068-Leap-C (https://github.com/nchiker/2068-Leap-C, MIT License, copyright
(c) 2026 Charlie Day) is built on this project's platform; code it wrote has
been brought back here: the tape block I/O (`kernel/storage/tapeblock.asm`),
the block-graphics glyph builder, the calculator's arithmetic (add,
subtract, multiply and divide in `rom/exrom_calc.asm`: Leap-C's float core,
`src/runtime/fpcore.asm`, adapted to the `RST $28` calculator), the xorshift used by
`RND`, the register-only `MATH_UMUL16` / `MATH_UDIV16`, the row clear in
`GFX_CLEAR_ROW_TEXT`, the `1` and `l` glyphs, the editor's view rule (`V2_VIEW` in
`rom/exrom_v2_shell.asm`, from Leap-C's `SH_VIEW`), `tools/fuse/fuseshim.c`
(loaded into Fuse at test time; it contains no Fuse source), and tools adapted
from Leap-C's (`tools/check_provenance.py`, `tools/check_repro.sh`,
`tools/qual/qpoweron.py`, the banking checks of `tools/qual/qcanary.py`, the tape
tolerance test `tools/qtapetol.py` and the MIC capture of `tools/qual/qmicsave.py`).
All of this is in release `v2.1.0-emu.1`.

Designs and findings taken from Leap-C without its code (written for V2's own
structures): the package export table and signature byte of ABI 2.1
(`EXT2_EXPORTS`, from Leap-C's `spec.md` section 7.2), the paging-depth reset
on the error unwind (item 2.3), the removal of `di` from the EXROM paging
routines (D14), the production-only removal of the editor's unused fallbacks
(D15-D17), the power-on RAM and Fuse frame-count probes (`tools/qual/qpoweron.py`
is adapted from Leap-C's; `tools/qual/fuse_frames_probe.py` uses
`tools/fuse/fuseshim.c`), and the tape signal limits checked by
`tools/check_storage_contract.py` (Leap-C's `docs/TAPE_SIGNAL_SPEC.md`).
`tools/qual/qcalcround.py`, `qnumcheck.py` and `qsinfit.py` read Leap-C's
float model (`tools/fpmodel.py`) from a checkout given on the command line;
it is not copied here. The `SIN`/`COS`/`TAN` series, the `PRINT` and scroll
routines, the package float service and the nine glyphs for `` [ \ ] ^ ` { | } ~ ``
(Q-26) were written for this project.
