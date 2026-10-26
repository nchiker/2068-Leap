# Leap-C back-port: handoff for phase 4

Written 2026-10-26 at the end of phase 3. The plan is `docs/V2_LEAPC_BACKPORT_PLAN.md`; this file is
only where things stand and how to pick up.

## State

- Branch `backport/leapc` (off `v2-development`), not pushed. Phases 0-3 committed.
- Free ROM: HOME 358 B, EXROM 199 B (`make budget`). Emergency reserve HOME 64 / EXROM 32
  (`make check` fails below it). Spending is weighted by benefit per byte, not floored.
- No stock-ROM-derived code left in the images: `tools/check_provenance.py` (in `make check`) has an
  empty allow-list. Keep it that way; anything taken from Leap-C is MIT and goes in `NOTICE.md`.
- Last full `make test` result: see the phase-3 commit message.

## Working rules (owner)

- Standard test runs (`make test`, `make qual`, the prod suites) go to a cheaper subagent
  (haiku/sonnet) that reports PASS/FAIL counts and failing text; the main session judges them.
- Run long suites on an rsync copy in the scratchpad, never `make` in the real tree while a suite runs
  there. `make test` is ~50 min; the prod suites use ports 10241-10246.
- Never run `make test-legacy` / `test-all` (Fuse) unprompted. Fuse was approved only for probe 0.8.
- Commit only on `backport/leapc`; don't push.
- Each item: measure bytes with `make budget`, record them in the plan's ledger and item outcome.

## Tools added in phases 0-3 (use them)

| Tool | What it checks |
| --- | --- |
| `tools/qual/qcanary.py --banking` | paging invariants over the corpus |
| `tools/qual/qpoweron.py` | boot from non-zero RAM patterns |
| `tools/qual/fuse_frames_probe.py` | frames lost by `di` windows (Fuse; approved probe only) |
| `tools/qual/qrnd.py`, `qmuldiv.py` | RND sequence/period, 16-bit mul/div differential |
| `tools/qtapetol.py` | LOAD under 23 tape distortions (old receiver 16, new 22) |
| `tools/qual/qmicsave.py` | real SAVE captured at MIC, decoded, played back (in the prod suites) |
| `tools/check_repro.sh` (`make repro`) | the build is reproducible |

## Phase 4: where to start

| Item | V2 site | Leap-C source |
| --- | --- | --- |
| 4.1 faster `GFX_CLEAR_ROW_TEXT` (keep the routine: V2 calls it) | `kernel/graphics/graphics.asm:1211` | `~/2068-Leap-C/platform/deltas/`, `platform/kernel/graphics/graphics.asm` |
| 4.2 punctuation table in order of use | `kernel/graphics/graphics.asm` (FONT_TABLE header ~l.27, scan ~l.372) | order from V2's corpus (`tools/qual` cases) |
| 4.3 distinct `1` / `l` glyphs (font data only) | FONT_TABLE | Leap-C delta D13, `docs/milestones/M9.md` §3.1 |
| 4.4 error number in compile messages | `rom/exrom_v2_shell.asm` (`V2_MSG_SYNTAX` sites l.854, 957, 1494) | — |

Checks for phase 4: glyph changes break screen oracles (refresh them; `docs/manual/images` too, as
phase 1 did for RND), and the manual examples (`make doc-examples`). 4.1 should be measured in kT per
row and per key typed (Leap-C: 23 → 6 kT per row; 47 vs 72 kT per key). Then weigh the Class B editor
items (redraw from the cursor line, `SH_VIEW`) against phase 5 by benefit per byte.

## Open points from phase 3

- `qtapetol` "speed 1.25" fails with the new receiver at `TR_ONE` 34 (ZEsarUX sampling on the bit
  threshold); 35 trades it for two other cases. Kept 34; revisit only with real-tape evidence.
- The calculator rewrite (3.2) was written from the interface with the old derived code visible, not
  by a separated clean-room author; `NOTICE.md` says so. Owner decision 2026-10-26: that counts as
  clean-room enough.
- Plan item 0.10: owner decision 2026-10-26, fast emulation (`TS2068_DEBUG_ZESARUX_FAST=1`) is the
  default for the suites (set by the Makefile, after the phase-3 commit, validated by a `make test`).
