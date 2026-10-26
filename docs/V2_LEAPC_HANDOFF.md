# Leap-C back-port: handoff after phase 4

Written 2026-10-26 at the end of phase 3; updated at the end of phase 4. The plan is `docs/V2_LEAPC_BACKPORT_PLAN.md`; this file is
only where things stand and how to pick up.

## State

- Branch `backport/leapc` (off `v2-development`), not pushed. Phases 0-4 committed.
- Free ROM: HOME 354 B, EXROM 208 B (`make budget`). Emergency reserve HOME 64 / EXROM 32
  (`make check` fails below it). Spending is weighted by benefit per byte, not floored.
- No stock-ROM-derived code left in the images: `tools/check_provenance.py` (in `make check`) has an
  empty allow-list. Keep it that way; anything taken from Leap-C is MIT and goes in `NOTICE.md`.
- Last full `make test` result: see the phase-4 commit message.

## Working rules (owner)

- Standard test runs (`make test`, `make qual`, the prod suites) go to a cheaper subagent
  (haiku/sonnet) that reports PASS/FAIL counts and failing text; the main session judges them.
- Run long suites on an rsync copy in the scratchpad, never `make` in the real tree while a suite runs
  there. `make test` is ~32 min (fast emulation); the prod suites use ports 10241-10246.
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

## Next: the Class B editor items, then phase 5

Phase 4 is done (outcome in the plan). Open decision for the owner: the two weighed editor items
(redraw from the cursor's line down, ~25-35 B EXROM; `SH_VIEW`, ~94 B EXROM, fixes ED4/R9) against
phase 5, whose VM work also spends EXROM. Suggested: the redraw item now, `SH_VIEW` after 5.1 is sized.

Phase 4 tools worth reusing: a differential probe pattern (old build in a `git worktree`, a small
sjasmplus harness at `$F400`, `reset/get-tstates-partial`, compare RAM) and a PNG cell-diff that
classifies changed 8x8 cells of manual screenshots. Both were scratch scripts; rebuild from the plan's
4.1-4.3 outcome notes if needed.

## Open points from phase 3

- `qtapetol` "speed 1.25" fails with the new receiver at `TR_ONE` 34 (ZEsarUX sampling on the bit
  threshold); 35 trades it for two other cases. Kept 34; revisit only with real-tape evidence.
- The calculator rewrite (3.2) was written from the interface with the old derived code visible, not
  by a separated clean-room author; `NOTICE.md` says so. Owner decision 2026-10-26: that counts as
  clean-room enough.
- Plan item 0.10: owner decision 2026-10-26, fast emulation (`TS2068_DEBUG_ZESARUX_FAST=1`) is the
  default (in ts2068-debug; `=0` for real speed). Done: `make test` 1,940 s, all PASS.
