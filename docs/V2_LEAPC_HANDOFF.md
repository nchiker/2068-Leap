# Leap-C back-port: handoff after 5.2-5.4

Written 2026-10-26 at the end of phase 3; updated at the end of phase 4, after 5.1, R1, `SH_VIEW`, ED3/ED7
and (2026-10-27) 5.2-5.4. The plan is `docs/V2_LEAPC_BACKPORT_PLAN.md`; this file is only where
things stand and how to pick up.

## State

- Branch `backport/leapc` (off `v2-development`), not pushed. Phases 0-4, the redraw item, 5.1
  (decimal literals, owner decision F8), R1 (calculator rounding, F10/F11), `SH_VIEW` (ED4), the editor fixes ED3/ED7
  and 5.2-5.4 (VM speed, F14) committed.
- Free ROM: HOME 246 B, EXROM 621 B (`make budget`). Emergency reserve HOME 64 / EXROM 32
  (`make check` fails below it). Spending is weighted by benefit per byte, not floored.
- No stock-ROM-derived code left in the images: `tools/check_provenance.py` (in `make check`) has an
  empty allow-list. Keep it that way; anything taken from Leap-C is MIT and goes in `NOTICE.md`.
- Last full `make test` (5.4, 2026-10-27, 1,730 s, fast emulation): smoke 9/9, standalone 40/40,
  production and fill checks, prod-regress 127, prod-arrays 101, known-defects 15, saveall 13, micsave 3,
  maint-qual all PASS; `make qual` 663 PASS + 2 XFAIL + 2 N/A, lifecycle 23; `make doc-examples` 327/327.
  `qvmedge` (118) joined `make qual` afterwards, run on its own: 118/118.
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
- **5.2-5.4 integrated** (F14, 2026-10-27): `backport/leapc` fast-forwarded to the prototype
  (`fa8e5b9` 5.2, `cae1722` 5.3, `51d4f82` 5.4, `201b960` docs); `proto/5.2-5.4-vm-speed` can be deleted.
  HOME 441 → 246 B free, EXROM 778 → 621. Everything measured is in the plan, "Outcome, 5.2-5.4". Their
  edge cases are in `make qual` as `tools/qual/qvmedge.py` (118 cases, written from the manual's rules).
- Before the v2.1 release: the manual's speed figures are stale (plan, "Outcome, 5.2-5.4": re-run
  `tools/qual/manual_measure.py`).
- Next: 5.5 (top of stack in registers: prototype first; the cheaper `VM_PUSH` noted in the
  5.2-5.4 outcome is a first step), then phase 6 (ABI 2.1) for v2.1.

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
| `tools/qual/qbench.py` | T-states per program (also `float_add_lit`, `compile_dec`, `compile_int_if`; 5.2-5.4: `int_inc`, `goto_loop`, `if_branch`, `proc_calls`, `sieve`) |
| `tools/qual/qbreak.py` | BREAK through the real keyboard matrix in 19 loop forms and waits; error 66, the loop left, key-to-message T |
| `tools/qual/qvmedge.py` | in `make qual`: 118 edge cases of the integer FOR path and the combined instructions, expectations from the manual's rules |
| `tools/run_v2_standalone_tests.sh --build-only` | in `make check`: assembles all 40 standalone test images |
| `tools/qual/qeditview.py` | editor per key: view rule, cursor, T-states; `--oracle` (full-redraw screen), `--ref DIR`, `--measure N` |

Probe pattern (all of the `q*` tools above): a loop assembled at `$F400` (the package window), a
table at `$8300` below the `$B6xx` cells, the booted snapshot restored per batch (`qharness.Machine`).

## Pitfalls met in 5.2-5.4

- **The compiler is HOME code** (`rom/v2_home.asm` includes `rom/exrom_v2_compiler.asm`; the file name
  misleads). Anything added to the compiler costs HOME. 5.4's peepholes live in the EXROM
  (`rom/exrom_v2_fuse.asm`) behind production-only slots `V2_EXROM_FUSE_*_ADDR`; the HOME compiler may
  call EXROM slots directly because every compile runs under the shell with the EXROM in. EXROM code
  sees HOME RAM cells only through the whitelist in `tools/write_v2_crossbank.py`. A slot's
  `V2_VERIFY_KTAB` destroys AF on entry. Changing the slot list: bump `V2_KTAB_MAGIC`.
- **The BREAK poll is at `VM_RUN.loop`, the dispatch at `VM_RUN.next`** (5.2). A handler that jumps, calls,
  or waits must end `jp VM_RUN.loop`; others `jp (iy)`. `qcanary --banking` arms its depth invariant at
  `.next` now. `tools/qual/qbreak.py` is the BREAK matrix (run it on any change to the dispatch).
- **Peepholes are production-only** (`IFDEF V2_PRODUCTION`): the test-only decompiler rebuilds IF
  structures from `JMPZ`/`JMP`. The standalone images compile as before.
- A register clobbered before a fallback: 5.3's first version used `ld bc,5` with C still the loop
  variable for the general path (`qbench`'s `for_float_step` ended with error 7). Check every early exit
  of a fast path for the registers the slow path expects.
- Opcode operand lengths for a bytecode disassembler are in the review script's table (scratch work, not
  in the repo): 1 byte for 3/4/18/39/50/51/56/57, 2 for 2/6/12/15/47/52/53/72/73 and 75/76, 3 for
  13/14/34/48/49/63-66 and 74, 5 for 70, 1+len for 17.
- A differential compares only what compiles: a test label that is a keyword (`out`, `over`) stops the
  program with compile error 12 on both builds, and the comparison passes having run nothing. Check
  that a differential's programs compile (`ce` 0) before trusting "identical".

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
