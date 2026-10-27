# Leap-C back-port: handoff after R1 (next: `SH_VIEW`)

Written 2026-10-26 at the end of phase 3; updated at the end of phase 4, after 5.1 and after R1. The
plan is `docs/V2_LEAPC_BACKPORT_PLAN.md`; this file is only where things stand and how to pick up.

## State

- Branch `backport/leapc` (off `v2-development`), not pushed. Phases 0-4, the redraw item, 5.1
  (decimal literals, owner decision F8) and R1 (calculator rounding, F10/F11) committed.
- Free ROM: HOME 441 B, EXROM 905 B (`make budget`). Emergency reserve HOME 64 / EXROM 32
  (`make check` fails below it). Spending is weighted by benefit per byte, not floored.
- No stock-ROM-derived code left in the images: `tools/check_provenance.py` (in `make check`) has an
  empty allow-list. Keep it that way; anything taken from Leap-C is MIT and goes in `NOTICE.md`.
- Last full `make test` (R1, 2026-10-26, 1,227 s, fast emulation): smoke 9/9, standalone 40/40,
  production and fill checks, prod-regress 116, prod-arrays 101, known-defects 15, saveall 13, micsave
  3, maint-qual all PASS; the corpus then had 6 float-`FOR` FAILs, settled by F11: `make qual` 663 PASS
  + 2 XFAIL + 2 N/A, lifecycle 23; `make doc-examples` 326/326 (the new FOR example `kw.for.6` included).
- R1 done: `rom/exrom_calc.asm`'s arithmetic is Leap-C's float core (rounds to nearest, bit-exact with
  Leap-C's `tools/fpmodel.py`), EXROM 186 → 905 B free, speed at or better than before; `Q-34` fixed.
  Float `FOR` follows the BASIC standards (F11: step accumulated, exact end test), so
  `FOR i = 0 TO 1 STEP 0.1` runs 10 times; corpus oracle and manual say so. Everything measured is in
  the plan, "Review item R1", "Outcome". `proto/r1-calc-round` is merged (same commits); delete it at will.
- Next: `SH_VIEW` (below). Then 5.2.

## Working rules (owner)

- Standard test runs (`make test`, `make qual`, the prod suites) go to a cheaper subagent
  (haiku/sonnet) that reports PASS/FAIL counts and failing text; the main session judges them.
- Run long suites on an rsync copy in the scratchpad, never `make` in the real tree while a suite runs
  there. `make test` is ~32-40 min (fast emulation); the prod suites use ports 10241-10246.
- Never run `make test-legacy` / `test-all` (Fuse) unprompted. Fuse was approved only for probe 0.8.
- Commit only on `backport/leapc`; don't push. A prototype may live on its own branch off it.
- Each item: measure bytes with `make budget`, record them in the plan's ledger and item outcome.

## Tools (use them)

| Tool | What it checks |
| --- | --- |
| `tools/qual/qcanary.py --banking` | paging invariants over the corpus |
| `tools/qual/qpoweron.py` | boot from non-zero RAM patterns |
| `tools/qual/fuse_frames_probe.py` | frames lost by `di` windows (Fuse; approved probe only) |
| `tools/qual/qrnd.py`, `qmuldiv.py` | RND sequence/period, 16-bit mul/div differential |
| `tools/qtapetol.py` | LOAD under 23 tape distortions (old receiver 16, new 22) |
| `tools/qual/qmicsave.py` | real SAVE captured at MIC, decoded, played back (in the prod suites) |
| `tools/check_repro.sh` (`make repro`) | the build is reproducible |
| `tools/qual/qdecimals.py` | all 131,072 short decimals: the lexer's value against the old run-time sequence |
| `tools/qual/qnumparse.py` | `NUM_PARSE_CALC` on random texts; `--ref` another build's run |
| `tools/qual/qliterals.py` | `vN = <literal>` compiled and run, tags and bytes; `--ref` |
| `tools/qual/qcalcround.py` | add/sub/mul/div rounding against exact results; `--leapc DIR` scores Leap-C's model and compares the ROM with it byte for byte |
| `tools/qual/qcalctime.py` | T per calculator operation by operand class; `--fptoint FILE [--cmp FILE]` differential of `CALC_FP_TO_INT` |
| `tools/qual/qnumcheck.py` | `qliterals` / `qnumparse` output against `NUM_PARSE_CALC`'s sequence replayed through Leap-C's model |
| `tools/qual/qbench.py` | T-states per program (now also `float_add_lit`, `compile_dec`, `compile_int_if`) |
| `tools/run_v2_standalone_tests.sh --build-only` | in `make check`: assembles all 40 standalone test images |

Probe pattern (all of the `q*` tools above): a loop assembled at `$F400` (the package window), a
table at `$8300` below the `$B6xx` cells, the booted snapshot restored per batch (`qharness.Machine`).

## Next: `SH_VIEW` (keep the cursor's line whole on screen, fixes ED4/R9)

**Goal.** The plan's weighed Class B item (phase 4, "Weighed items"): the active line always whole on
rows 0-22, so its cursor is always visible. Measure, qualify, commit on `backport/leapc` (or prototype
on a branch first if the size or the redraw interactions surprise).

**The defect.** `docs/R10_8_EDITOR_USABILITY_AUDIT.md` ED4 (= R9): rows 23 and below are not drawn and
`V2_RD_CURSOR` / the end of `V2_REDRAW` skip a cursor at row ≥ 23 (`cp 23 / ret nc`). Two ways in:
(a) a long active line starting low (a line of 97+ characters, 4 rows, starting at row 20; lines are
at most 127 characters, `EDIT_LINE_BUF_LEN` 128); (b) wrapped lines above it: the view always shows 20
lines above the cursor's line, so 20 two-row lines push it past row 22 entirely (`V2_ACTIVE_ROW` then
keeps its default 22). Not in the manual, not in `tools/v2_known_defects.py`.

**V2 today** (`rom/exrom_v2_shell.asm`):

- `V2_REDRAW` (~l.1878), full path: `VIEW_TOP_INDEX = max(0, CUR_EDIT_INDEX - 20)` (the `.scroll` /
  `.top` / `.view_ready` block, ~l.1912-1927): line count only, heights ignored.
- Height-change path (phase-4 redraw item, top of `V2_REDRAW`): "same index, so the same view": redraws
  from the active line down; an active row of 22 takes the full redraw.
- `V2_REDRAW_ACTIVE` (~l.2067): same height: the view cannot change. Unaffected.
- `V2_REDRAW_NAV` (~l.2084), UP/DOWN to a neighbour: assumes "both indices ≤ 20, so the view top
  stays 0" and checks only that the new row is < 23, not that the new line fits.

**Leap-C** (`~/2068-Leap-C`, MIT): `SH_VIEW` in `src/shell/shell.asm` (~l.1168, 94 B,
`docs/milestones/M5.md` §2 and its size table): the active line's height (`EDITOR_WRAP_CALC` on
`EDIT_LINE_BUF`), then each of up to 20 lines above it (copy, `EDITOR_WRAP_CALC`, heights stored in
`SH_HEIGHTS`, 20 B of RAM, `include/leapc_cells.inc`), then lines dropped from the top while the
total exceeds 23 rows. Called
by the full redraw (~l.892) and the height-change path (~l.984: the rows above are left alone only
when the view stays).

**The change, as a sketch.**

1. `V2_VIEW` (port of `SH_VIEW`) replaces the `max(0, idx - 20)` block. Measure a settled line as it
   is drawn: `V2_COPY_RECORD` → `DETOK_BUF`, then `EDITOR_WRAP_CALC`. The append line (`V2_POS_IS_APPEND`)
   is the active line at index = line count.
2. Height-change path: compute the view; if `VIEW_TOP_INDEX` would change, take the full redraw.
   Revisit the `cp 22 / jr nc,.full` default (with `V2_VIEW` the active line is always reached).
3. `V2_REDRAW_NAV`: replace "indices ≤ 20" with "the view for the new index equals `VIEW_TOP_INDEX`"
   and require new row + new height ≤ 23. Measure the cost per UP/DOWN: up to 20 records copied and
   measured (the fast path exists to avoid a ~0.9 MT full redraw).
4. RAM for the 20 heights: `CALC_SPARE_18` (R1 left 18 B free in the calculator block, `$81FD`) is
   2 B short: 18 lines above the cursor, or a smaller encoding, would fit it. Otherwise a dead span
   (`docs/RAM_EFFICIENCY_RESULTS.md`, e.g. `$F328-$F3AE`), which means updating
   `tools/check_ram_layout.py`'s census and `tools/qual/qcanary.py`'s dead-span list; or no table at all
   (measure again while trimming: slower, full redraws only).

**Size [E].** EXROM +70 to +110 B (`SH_VIEW` 94 B in Leap-C, minus helpers V2 already has, plus the
two redraw paths). With EXROM 905 B free (after R1) → about 795-835 B: room is not the constraint, so
prefer the per-key speed (a heights table, the fast UP/DOWN path kept) over the last bytes.

**Qualification.**

- ED4 cases (a) and (b) above, plus a line growing past row 22 while typing and UP/DOWN across a tall
  line: the cursor cell (inverted attribute) on rows 0-22 after every key, the active line whole,
  as many lines above it as fit (≤ 20). Add them to the prod regression gate.
- Differential against the current build where no line wraps far enough to matter: the screen
  identical after every key (method of the phase-4 redraw item: typed scenarios, screen compared per
  key; its scratch script is gone, rebuild it on `qharness`, whose `call_routine` delivers keys).
- Per-key cost for typing, height changes and UP/DOWN near the bottom and in long programs (`T`
  states, as the phase-4 outcomes report them).
- `make check` (now also assembles the standalone images), `make doc-examples` (screenshots: any
  changed cell must be explained), `make test` via a subagent on an rsync copy.

**After `SH_VIEW`.** 5.2 (BREAK poll at back-edges, HOME).

## Pitfalls met in 5.1

- A routine shared by the VM core and the compiler must live in the VM core: `test_v2_vm_milestone01`
  includes the VM core without the compiler. `make check` now catches this (standalone images
  assembled); the 14 never-run sources of defect T-3 are not assembled anywhere.
- `NUM_PARSE_CALC` is slow when the calculator does the digits (~30 kT a digit); keep the 16-bit path.
- `pkill -f <pattern>` also matches the shell running it when the pattern is in its command line:
  kill by PID.

## Pitfalls met in R1

- `tools/z80sim` runs `rom/exrom_calc.asm` in `make check` (`test_calc_dispatcher.py`) and knew no EQU,
  no `rl`/`rr (hl)`, no `set`/`res`, no `lddr`: added. It still has no `EXX` or `EX (SP),HL`, so the
  calculator avoids them; its cells must be registered in the test (`CALC_FX/FY/FQ`).
- `rom/test_calc_smoke_division.asm` hard-coded the truncated 1/3 (`…AA`): now `…AB`. Other expected
  values that encode the old truncation would look like this: a smoke ROM or a test printing bytes.
- The faithful port was slower than V2 where Leap-C loops bit by bit (divide 1.9×, float add 1.8×); the
  three "R1, speed" loops fix that with the same bits (`qcalcround --leapc` must stay 16,000/16,000).

## Open points from phase 3

- `qtapetol` "speed 1.25" fails with the new receiver at `TR_ONE` 34 (ZEsarUX sampling on the bit
  threshold); 35 trades it for two other cases. Kept 34; revisit only with real-tape evidence.
- The calculator rewrite (3.2) was written from the interface with the old derived code visible, not
  by a separated clean-room author; `NOTICE.md` says so. Owner decision 2026-10-26: that counts as
  clean-room enough.
- Plan item 0.10: owner decision 2026-10-26, fast emulation (`TS2068_DEBUG_ZESARUX_FAST=1`) is the
  default (in ts2068-debug; `=0` for real speed). Done: `make test` 1,940 s, all PASS.
