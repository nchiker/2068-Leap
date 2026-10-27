# Leap-C back-port: handoff after the R1 prototype

Written 2026-10-26 at the end of phase 3; updated at the end of phase 4, after 5.1 and after the R1
prototype. The plan is
`docs/V2_LEAPC_BACKPORT_PLAN.md`; this file is only where things stand and how to pick up.

## State

- Branch `backport/leapc` (off `v2-development`), not pushed. Phases 0-4, the redraw item and 5.1
  (decimal literals, `1bb5e65`, owner decision F8) committed.
- Free ROM: HOME 441 B, EXROM 905 B (`make budget`). Emergency reserve HOME 64 / EXROM 32
  (`make check` fails below it). Spending is weighted by benefit per byte, not floored.
- No stock-ROM-derived code left in the images: `tools/check_provenance.py` (in `make check`) has an
  empty allow-list. Keep it that way; anything taken from Leap-C is MIT and goes in `NOTICE.md`.
- Last full `make test`: all PASS on 5.1 (2,444 s, loaded host; counts in the plan's 5.1 outcome).
- R1 integrated (owner decision F10; `backport/leapc` fast-forwarded to the prototype): Leap-C's float
  core behind the calculator, EXROM 186 → 905 B free, every result bit-exact with Leap-C's model, speed
  at or better than before. `make test` all PASS except 6 corpus float-`FOR` counts now one short
  (`FOR i = 0 TO 1 STEP 0.1` runs 10 times): the old truncation's downward bias had hidden this.
  Measurements in the plan, "Review item R1", "Prototype outcome".
- Next: the owner's `FOR` decision (F11; the plan's R1 outcome: the BASIC standards' rule is what V2
  does, recommended; `make qual` has these 6 FAILs until then). Then `SH_VIEW`.

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

## R1, the calculator rounds (Leap-C's float arithmetic behind V2's interface): prototyped

Done on `proto/r1-calc-round` as described below; the outcome is in the plan. Kept here for reference.

**Goal of this step.** A prototype on a branch off `backport/leapc` (e.g. `proto/r1-calc-round`):
V2's arithmetic replaced by Leap-C's 40-bit core, with its measured size, speed and rounding; the
owner then decides whether to integrate (owner decision F9). Measurements, root causes and Leap-C's
side are in the plan, section "Review item R1"; defect `Q-34`.

**Why first.** A correctness fix (`INT(3.1*10)` = 30 today), and if it lands near Leap-C's size it frees
EXROM for `SH_VIEW` and the later items (V2's arithmetic 1,331 B, Leap-C's 522 B).

**V2 today** (`rom/exrom_calc.asm`, EXROM): `CALC_UNPACK` (~l.333, also reads the small-integer
form), `CALC_PACK` (~l.469, no rounding), `CALC_FP_TO_INT` (~l.580: the only other reader of the
unpacked layout), `CALC_ADDSUB_ENGINE` (~l.794), `CALC_OP_ADD`/`SUB` (~l.1034), `CALC_OP_MUL`
(~l.1093), `CALC_OP_DIV` (~l.1309), helpers `CALC_ADD8`..`CALC_SUB4` (~l.1497), `CALC_TABLE` (~l.1612,
8 literals). Nothing outside this file touches the internals. Cells (`include/sysvars.inc`
~l.2234-2320): `CALC_OP1/OP2_PTR`, `CALC_UNP_A/B` (6 B each), `CALC_SHIFT_COUNT`, `CALC_MUL_ACC`,
`CALC_MUL_CAND` (8 B each), `CALC_DIV_REM`, `CALC_DIV_QUOT` (4 B each): 37 B.

**Leap-C** (`~/2068-Leap-C/src/runtime/fpcore.asm`, MIT): `FUNPK`, `FPACK` (rounds half away from
zero on the guard byte), `FNORM`, `FADD`, `FSWAP`, `FMUL`, `FDIV`, `FDONE`, `FSIGN`, helpers `FSHL`,
`FSHR`, `FADDN`, `FSUBN`, `FZERO`; unpacked layout `[sign][exponent][m0..m3][guard]` (7 B). Its
`XF_BIN` dispatcher and `XF_*` entry points are not needed (V2 keeps its `RST $28` literal stream).
`tools/fpmodel.py` is a bit-exact model of every operation.

**Adapting it.**

- Working cells: FX, FY (7 B each) and FQ (5 B) in V2's 37 B calculator cells, not at `CALC_STACK`
  as in Leap-C (V2's operand slots live there). The cells left over may be freed (RAM census).
- Inputs: V2 operands may be in the small-integer form (`CALC_INT_TO_FP`'s output; byte 0 = 0 is
  not zero there): `FUNPK` must read it, as `CALC_UNPACK` does. Outputs: the general form; zero as
  five zero bytes (the bytes V2 already uses for zero).
- Errors: V2's codes and paths (`CALC_ABORT_NUMERIC_OVERFLOW`, `CALC_ERR_DIVISION_BY_ZERO`,
  `CALC_ABORT_STREAM`), not Leap-C's `F_ERR`. Underflow gives 0 in both.
- `CALC_FP_TO_INT`: port to the new layout, its results unchanged (differential over many values).
- Keep `CALC_TABLE`'s literals and operand counts (`tools/z80sim/test_calc_dispatcher.py`).

**Measurements.**

- Size: `make budget` (EXROM; HOME should not change). Estimate [E] EXROM +500 to +700 B free.
- Rounding: `tools/qual/qcalcround.py --leapc ~/2068-Leap-C`: 100% correctly rounded, or each
  exception explained; the results equal Leap-C's model bit for bit.
- Speed: T per operation before/after (time the four stubs, as `qcalcround.py` calls them) and
  `qbench` (`float_loop`, `float_add_lit`, `for_float_step`, `builtins`): Leap-C loops where V2
  unrolls, so a slowdown is possible; report it and weigh it against the bytes.
- Values change in the last bit by design: `qdecimals.py` stays self-consistent (same build on both
  sides); for `qliterals.py` / `qnumparse.py` against the old build, check the new values against
  the model instead of expecting identity. The visible cases (`INT(3.1*10)` etc., plan R1) become right.
- `make check`, `make doc-examples` (examples that print decimals may change: explain each),
  corpus expectations (`tools/qual/corpus.py` may have float cases that flip), `make test` via a
  subagent on an rsync copy. `NOTICE.md`: the Leap-C origin of the arithmetic.

## After R1: `SH_VIEW` (keep the cursor's line whole on screen, fixes ED4/R9)

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

**Leap-C** (`~/2068-Leap-C`, MIT): `SH_VIEW` in `src/shell/shell.asm` (~l.1163, 94 B,
`docs/milestones/M5.md` §2 and its size table): the active line's height (`EDITOR_WRAP_CALC` on
`EDIT_LINE_BUF`), then each of up to 20 lines above it (copy, `EDITOR_WRAP_CALC`, heights stored in
`SH_HEIGHTS`, 20 B of RAM), then lines dropped from the top while the total exceeds 23 rows. Called
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
4. RAM for the 20 heights: a dead span (`docs/RAM_EFFICIENCY_RESULTS.md`, e.g. `$F328-$F3AE`) means
   updating `tools/check_ram_layout.py`'s census and `tools/qual/qcanary.py`'s dead-span list; or no
   table at all (measure again while trimming: slower, full redraws only).

**Size [E].** EXROM +70 to +110 B (`SH_VIEW` 94 B in Leap-C, minus helpers V2 already has, plus the
two redraw paths). With EXROM 186 B free (before R1) → about 80-115 B, above the 32 B reserve; R1, if
integrated, adds its savings first.

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
