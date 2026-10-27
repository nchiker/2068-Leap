# Leap-C back-port: handoff after `SH_VIEW`, ED3 and ED7 (next: 5.2-5.4)

Written 2026-10-26 at the end of phase 3; updated at the end of phase 4, after 5.1, R1, `SH_VIEW` and ED3/ED7. The
plan is `docs/V2_LEAPC_BACKPORT_PLAN.md`; this file is only where things stand and how to pick up.

## State

- Branch `backport/leapc` (off `v2-development`), not pushed. Phases 0-4, the redraw item, 5.1
  (decimal literals, owner decision F8), R1 (calculator rounding, F10/F11), `SH_VIEW` (ED4) and the editor fixes ED3/ED7
  committed.
- Free ROM: HOME 441 B, EXROM 778 B (`make budget`). Emergency reserve HOME 64 / EXROM 32
  (`make check` fails below it). Spending is weighted by benefit per byte, not floored.
- No stock-ROM-derived code left in the images: `tools/check_provenance.py` (in `make check`) has an
  empty allow-list. Keep it that way; anything taken from Leap-C is MIT and goes in `NOTICE.md`.
- Last full `make test` (ED3/ED7, 2026-10-26, 1,781 s, fast emulation): smoke 9/9, standalone 40/40,
  production and fill checks, prod-regress 127, prod-arrays 101, known-defects 15, saveall 13, micsave 3,
  maint-qual all PASS; `make qual` 663 PASS + 2 XFAIL + 2 N/A, lifecycle 23; `make doc-examples` 327/327.
- R1 done: `rom/exrom_calc.asm`'s arithmetic is Leap-C's float core (rounds to nearest, bit-exact with
  Leap-C's `tools/fpmodel.py`), EXROM 186 → 905 B free, speed at or better than before; `Q-34` fixed.
  Float `FOR` follows the BASIC standards (F11: step accumulated, exact end test), so
  `FOR i = 0 TO 1 STEP 0.1` runs 10 times; corpus oracle and manual say so. Everything measured is in
  the plan, "Review item R1", "Outcome". `proto/r1-calc-round` was merged and deleted. `STEP 0` keeps V2's rule (F11).
- `SH_VIEW` done: `V2_VIEW` keeps the cursor's line whole on rows 0-22 (ED4 fixed), EXROM +104 B, no RAM
  (no heights table: short lines measured from their length, long ones wrapped in place). Plan, phase 4,
  "Outcome, `SH_VIEW`". New `tools/qual/qeditview.py`; 4 `ED4-*` cases in the prod gate.
- ED3 and ED7 fixed (owner request): a command typed over any line runs and the line keeps its text; the
  edit buffer has an empty row after a full 32-character last row, where the cursor shows (EXROM +23 B).
  Plan, "Outcome, ED3 and ED7"; 7 `ED3-*`/`ED7-*` gate cases (prod-regress now 127); manual `con.edit.5`.
- Owner, 2026-10-26: no physical TS2068 run is possible for now, emulators only (F12); 5.2, 5.3 and 5.4 are
  done as one group (F13).
- Next: 5.2-5.4 (below).

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
| `tools/qual/qeditview.py` | editor per key: view rule, cursor, T-states; `--oracle` (full-redraw screen), `--ref DIR`, `--measure N` |

Probe pattern (all of the `q*` tools above): a loop assembled at `$F400` (the package window), a
table at `$8300` below the `$B6xx` cells, the booted snapshot restored per batch (`qharness.Machine`).

## Next: 5.2, 5.3 and 5.4 together (owner decision F13)

The three are coupled: 5.2 moves the BREAK test to back-edges, 5.3's integer `NEXT` fast path is a
back-edge, and a 5.4 combined opcode that jumps backwards is one too. Conditions (agreed with the owner):

1. **The poll rule first.** Today `VM_RUN.loop` (`rom/exrom_v2_vm_core.asm`, assembled into HOME, `$110C`)
   tests `VM_HALTED` before every opcode (`ld a,(VM_HALTED) / or a / ret nz`, 22 T per op [M]). The ISR sets
   it for BREAK (`kernel/interrupt/interrupt.asm`, D5: error 66); `OP_HALT` sets it and returns into the loop
   (it then has to leave `VM_RUN` itself); the error-halts unwind through `VM_RUN_SP`. Rule: every backward
   jump, `NEXT`, call (`PROC`, `FN`), package call (`OP_CALL_EXT`) and the existing waits (PAUSE, INPUT)
   test it; every new jumping opcode of 5.3/5.4 must too. Prove it with one BREAK case per loop form (GOTO
   loop, integer and float FOR, the 5.3 fast path, PROC recursion, each 5.4 opcode that jumps), next to
   `D5-break-running-loop` (known-defect suite) and `make qual-maint`'s BREAK cases.
2. **One prototype branch off `backport/leapc`, one commit per item**, `qbench` after each, so each item's
   bytes and speed go in the ledger separately; `qbytecode` baselines are reset once, for the group (5.4
   changes the compiler's output: review every changed program, as 5.1 did).
3. **HOME room.** The handlers are HOME: 441 B free, 377 B above the reserve. Size 5.3 and 5.4 before
   writing them (the compiler side of 5.4 is EXROM, 778 B free); item 5.0 (shrink pass) first if they do not
   fit.

Emulators only (F12): ZEsarUX for everything; Fuse only if the owner approves a run (timing-sensitive cases).
Then stop for the owner with the measured sizes and speed-ups before integrating.

**After 5.2-5.4.** 5.5 (top of stack in registers: prototype first), then phase 6 (ABI 2.1) for v2.1.

## Pitfalls met in `SH_VIEW`, ED3 and ED7

- A scenario typed in front of an existing line adds that line's length: `scrolled-typing` meant to stay
  at 3 rows reached 4 (an ED4 case) until the typed text was shortened. DOWN in a wrapped line moves
  between its rows first: count those keys when a scenario must reach a given line.
- `qeditview` enters the editor through `V2_COMMAND_LOOP.loop` with `CUR_EDIT_INDEX`/`CUR_EDIT_POS` poked;
  its oracle calls `V2_REDRAW` from a snapshot at the `IO_READ_KEY` breakpoint (EXROM is paged in there).
- The cursor after a last row of exactly 32 characters was at column 32 and invisible: fixed as ED7 (the
  edit row). A line that gains the edit row as it becomes active moves the lines below it: the UP/DOWN fast
  path must refuse it (the oracle found this in the prototype). `qeditview --edit-row-ref` compares against
  a build without the edit row.
- `ED3`: `P.type_text` ends with ENTER; to type over a line the gate cases go UP, RIGHT to its end and
  DELETE its characters first (`_over_line`).

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
