# Leap-C back-port: handoff after the 5.1 prototype

Written 2026-10-26 at the end of phase 3; updated at the end of phase 4 and after the 5.1 prototype. The plan is `docs/V2_LEAPC_BACKPORT_PLAN.md`; this file is
only where things stand and how to pick up.

## State

- Branch `backport/leapc` (off `v2-development`), not pushed. Phases 0-4 and the redraw item committed (redraw: commit after 07a18da).
- 5.1 prototype on branch `proto/5.1-float5` (off `backport/leapc`), committed, not merged: HOME 441 B
  free there. Waiting for the owner's decision (outcome and the decision in the plan, phase 5).
- Free ROM on `backport/leapc`: HOME 354 B, EXROM 186 B (`make budget`). Emergency reserve HOME 64 / EXROM 32
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

## Next: the owner's 5.1 decision, then `SH_VIEW`

The 5.1 prototype is measured (plan, phase 5 outcome): HOME −87 B, `x = x + 0.5` 3.4× faster, every
decimal literal bit-identical to the old run-time value, ~30 kT more compile time per decimal
literal. If the owner integrates it: fast-forward or cherry-pick `proto/5.1-float5` onto
`backport/leapc` and move its ledger row out of "prototype". `SH_VIEW` (~94 B EXROM, fixes ED4/R9) is
the next weighed item; 5.1 does not change EXROM (186 B free). Then 5.2 (BREAK poll at back-edges).

Pitfalls met in 5.1:

- `make check` does not assemble the standalone test images; `make test` does. A routine shared by
  the VM core and the compiler must live in the VM core: `test_v2_vm_milestone01` includes the VM core
  without the compiler. Assemble every `rom/test_v2_*.asm` against the baseline (42 assemble; the 14
  never-run sources of defect T-3 fail on both) before a long run.
- `NUM_PARSE_CALC` is slow when the calculator does the digits (~30 kT a digit); keep the 16-bit path.
- Tools added for 5.1 (all `--tree`/`--port`, harness at `$F400` as `qmuldiv.py`):
  `tools/qual/qdecimals.py` (all 131,072 short decimals through the real lexer against the old
  run-time sequence, self-checking), `qnumparse.py` (`NUM_PARSE_CALC` on random texts, `--ref` another
  build's run: values must match, forms may differ), `qliterals.py` (`vN = <literal>` compiled and run,
  tags and bytes, `--ref`). `qbench.py` gained `float_add_lit`, `loop_200`, `compile_dec`,
  `compile_int_if` (`IF 0 THEN` ... `ENDIF`: literals compiled, never run).

## Open points from phase 3

- `qtapetol` "speed 1.25" fails with the new receiver at `TR_ONE` 34 (ZEsarUX sampling on the bit
  threshold); 35 trades it for two other cases. Kept 34; revisit only with real-tape evidence.
- The calculator rewrite (3.2) was written from the interface with the old derived code visible, not
  by a separated clean-room author; `NOTICE.md` says so. Owner decision 2026-10-26: that counts as
  clean-room enough.
- Plan item 0.10: owner decision 2026-10-26, fast emulation (`TS2068_DEBUG_ZESARUX_FAST=1`) is the
  default (in ts2068-debug; `=0` for real speed). Done: `make test` 1,940 s, all PASS.
