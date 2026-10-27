# Leap-C back-port: handoff for item VER, the rest of phase 5 and phase 6

Written 2026-10-26 at the end of phase 3, updated through phases 4 and 5; this version 2026-10-27, after
5.9/5.10. The plan is `docs/V2_LEAPC_BACKPORT_PLAN.md` (the ledger, every item's outcome, the owner
decisions F1-F26); this file is only where things stand, what comes next and how to pick it up.

## Where things stand

- **Branch `backport/leapc`** (off `v2-development`). On it: phases 0-4, the redraw item, 5.1 (decimal
  literals), R1 (calculator rounding), `SH_VIEW` (ED4), ED3/ED7, 5.2-5.5 (VM speed), 5.6-5.8 (calculator
  multiply/divide in registers, `SQR` halving, the row clear) and 5.9/5.10 (`SIN`/`COS`/`TAN` in the
  EXROM, the polynomial, Q-35; owner F26: integrated by fast-forward). GitHub has it up to `0227797`
  (F21); 5.9/5.10 and later are local until the owner says to push.
- **Free ROM: HOME 746 B, EXROM 171 B** (`make budget`). Emergency reserve HOME 64 / EXROM 32 (`make check`
  fails below it). Spending is weighted by benefit per byte (F1).
- **Owner rules for what is left** (2026-10-27): a change must give a *significant speed increase* or
  *use less HOME or EXROM* (F17); the phase 5 follow-ups must *leave room for phase 6* (F19); item VER
  is the owner's own request (F22).
- **What phase 5 gave** [M] (`qbench`, `qprofile --statements`, against the build before 5.2): counter
  and GOTO loops 2.4-2.55×, the sieve 1.53×, IF-heavy loops 1.56×, empty FOR 1.31×; `SQR` 3.0×,
  `SIN`/`COS` 3.0× (2.0× by 5.6, 1.48× more by 5.10), `TAN` 2.7×, a float divide −40% and multiply −37%
  a statement, a scrolling `PRINT` −10.6%. Every result and screen identical to before, except
  `SIN`/`COS`/`TAN` (5.10: within ~2 ulp of exact, were up to 16,713 ulp off; F23) and the Q-35 fix.
- Last full `make test` (5.10, 2026-10-27, 1,794 s, fast emulation): all PASS (smoke 9/9, standalone
  40/40, prod-regress 127, prod-arrays 101, known-defects 15, saveall 13, micsave, qual 666 PASS + 2 XFAIL
  + 2 N/A of 670, lifecycle 23, `qvmedge` 120, maint-qual all); `make doc-examples` 327 (the spiral's image
  rewritten for 5.10). Emulators only (F12): nothing has run on a physical TS2068.
- No stock-ROM-derived code in the images (`tools/check_provenance.py`, empty allow-list); anything
  taken from Leap-C is MIT and goes in `NOTICE.md`.

## What comes next, in this order

The space arithmetic is the plan's "Room for phase 6": phase 6 is allowed **HOME ~260 B, EXROM ~100 B**
[E] until 6.1 is sized. Now HOME has 422 B above the reserve and that allowance; the EXROM 39 B. Check
every item against *free - reserve - phase 6's allowance >= its cost* in the ROM it uses.

1. **Item VER** (owner F22): the ROM's version on the screen at power-on, while the startup chime plays.
   The plan's "Item VER" has the item; how to pick it up is below.
2. **Size 6.1** (package functions with Leap-C's export table and signature bytes) as a prototype, to
   replace phase 6's allowance with a measured figure before spending more.
3. **Then, where the room is** (HOME has it; the EXROM has 39 B above phase 6's line):
   - 5.13, `PRINT` of a string (~3× a character: the addresses worked out once, an unrolled glyph copy);
     the print path runs only with the EXROM in, so either ROM works: HOME now. Check: `qscrdiff`.
   - 5.11, the scroll copy (each screen third's rows in one block per scanline, unrolled; ~218 → ~180 kT,
     contention-bound). HOME (`kernel/graphics`); the editor shares `GFX_COPY_ROW_BITMAP`, so also
     `qeditview`. Check: `qscrdiff`, `qrtime`.
   - 5.12, `LOAD v; PUSH k; CMP_JMPZ` as one instruction (~1,000 T an `IF i < k`): the handler in HOME
     (the room is there), the compiler side next to 5.4's in `rom/exrom_v2_fuse.asm` (EXROM, ~70 B [E]:
     more than the EXROM's 39 B above phase 6's line, so measure, or put it in HOME). Bytecode changes:
     `qbytecode` review and baseline reset; `qvmedge` cases.
4. **Phase 6 (ABI 2.1)**, items 6.1-6.6, for v2.1. The manual's speed figures were updated after 5.8
   (`tools/qual/manual_measure.py`, owner F21; it has no `SIN`/`COS`/`TAN` entry); re-run it after any
   later speed change and update `04_concepts.md` "Speed" and `FOR`'s note (the Word edition is rebuilt
   at release).

## Item VER: how to pick it up

**Goal (owner F22).** At power-on the screen shows the ROM's version, e.g. `2068 LEAP V2.1`, *while the
startup chime plays*: on the screen before its first note and still there after its last. Proposed in
the plan (not decided): it then stays until the first key, which reaches the editor as usual. If keeping
it past the editor's first redraw costs much or disturbs the tests, ask the owner before settling for
"during the chime only". Only at power-on, like the chime (not on `NEW` or a return to the editor).

**The boot path today.** `V2_COMMAND_LOOP` (`rom/exrom_v2_shell.asm`, EXROM), its one-time head:
`KTAB_GFX_CLS`, `V2_RESET_DISPLAY`, `V2_RESET_EDIT`, `STARTUP_CHIME`; then `.loop` (re-entered on `NEW`
and every return to the editor): `V2_RESET_DISPLAY` (colours, border, mode 0; no clear), `EDITOR_INIT`,
the hooks, `V2_LOAD_EDIT`, `EDITOR_ENTER` → `EDITOR_REDRAW_SCREEN` (→ `V2_REDRAW`, which ends in
`V2_DRAW_STATUS`: row 23 cleared and `LINE n/m` printed, with the status-bar attribute) → `EDITOR_LOOP`
(`KTAB_IO_READ_KEY`). The screen is blank during the chime today.
- Printing the text between `V2_RESET_EDIT` and `STARTUP_CHIME` puts it up for the whole chime. Row 23 is
  natural (the status row), but `V2_DRAW_STATUS` overwrites it at the editor's first redraw, right after
  the chime. Keeping it to the first key needs e.g. a one-shot flag that `V2_DRAW_STATUS` honours (print
  the version instead of `LINE n/m`) and that the first key clears; check `V2_REDRAW`'s selective paths
  (`V2_REDRAW_SCOPE`, `V2_REDRAW_NAV`) also redraw the status when the flag clears.
- `V2_SHOW_MESSAGE` (the status-line messages) is *not* usable as it is: it ends in `jp KTAB_IO_READ_KEY`
  (it waits for, and takes, a key) and calls `SA_UNBUILD` when `SA_BUILT` is set.
- The chime: the default (MAINT) build plays chime C (`V2_MAINT_CHIME_C`): attack 27 frames, hold 19,
  release 9, 55 frames (~0.9 s at 60 Hz; BREAK ends it with `V2_MAINT_SHARED_WAIT`); the release
  definitions (`make build EXTRA_DEFS=`) play the original table chime; `V2_MAINT_CHIME_B` is a third
  variant. The text must be up for each of them: print before the call, not inside a variant.

**The version.** One constant in a new include (e.g. `include/v2_version.inc`: the text), edited at each
release, the next being v2.1 (F4). Not `git describe`: every commit would build a different ROM (`make
repro`; comparing a build with the released images' hashes). The released v2.0.x images are fixed.

**Where the bytes go.** HOME has the room (746 free): the text and a small print routine in HOME,
exported to the EXROM through `tools/write_v2_crossbank.py` (`NAMES`; a global name, not a local
`.label`), called from the boot head (3 B of EXROM). `KTAB_GFX_PRINT_STRING` (HL text, B row, C column)
and `V2_STATUS_SET_BAR_ATTR` are what the status line uses. Estimate ~25 B HOME. Record `make budget`'s
figures in the ledger.

**Checks.**
- A probe (like the 5.9 slot probe, `qharness.Machine`): boot from reset with breakpoints at
  `STARTUP_CHIME`'s entry and at its return (its caller's next instruction), read the screen
  (`m.read(0x4000, 6912)`, or the harness's text reader) at both: the version text present. Then a key
  (`KBD_LASTK`/`KBD_KEYHIT`, as `call_routine` does): it reaches the editor (typed character on screen),
  and the status row shows `LINE n/m` again.
- The chime itself unchanged: `make qual-maint` / maint-qual's `ay_beep` and `cbeep` (AY register writes,
  frame waits).
- **The test harness's boot snapshot** (`qharness.Machine.start`) is taken at the first `IO_READ_KEY`,
  i.e. with the text still up if it stays to the first key. Every tool restoring that snapshot then starts
  from that screen: `qeditview` (its oracle redraws with `V2_REDRAW`), `qscrdiff`, the editor and
  production suites, `doc-examples` screenshots (`manual_run.py`). Run them; a difference confined to row
  23 before the first key is expected, anything else is not. If many tools need re-baselining, prefer
  clearing the flag where the harness's first action would anyway, and say so to the owner.
- `make check`, `make build EXTRA_DEFS=` (the release definitions assemble), `make repro`, `make test`
  (subagent, on a copy), `make doc-examples`.
- The manual: where the version is shown (`01_introduction.md`, `07_appendices.md`); a `doc-examples`
  case is not needed (it is not a BASIC example).

## Pitfalls met in 5.9/5.10

- **The two-bank standalone harness** (`rom/test_v2_harness_*`) assembles the VM core into its HOME with
  the calculator in its EXROM; only `CALC_INT_TO_FP`, `CALC_FP_TO_INT`, `CALC_PUSH_PI`,
  `CALC_PUSH_FP_RAW` and `CALC_SP_TO_NEXT_FREE_PTR` are reachable from HOME there
  (`rom/test_v2_harness_addrs.inc`). Code the VM core includes must use only those (5.9's first
  `SIN_PEEK` used `CALC_SP_TO_TOP_PTR`: `make check` failed on the standalone build).
- **Cross-bank exports** (`tools/write_v2_crossbank.py`): its pattern takes global names only; export a
  local label through a global `EQU` alias (`FP_TRUNC_ZERO`, `VM_ERR_RANGE`). A name that exists only
  under a build define (`VM_ERR_RANGE` was MAINT-only) breaks the release build: check `make build
  EXTRA_DEFS=` after adding one.
- **`qfndiff`'s "0 differ"** counts a program that stops on both builds as equal: read the "(N in programs
  that stopped)" figure (24 `TAN` arguments in 5.9, the Q-35 cases).
- **Simulate the calculator first**: Leap-C's `tools/fpmodel.py` is bit-exact with this calculator
  (FUNPK's small-integer form = `fri` of its 16-bit pattern); `tools/qual/qsinfit.py --leapc DIR` shows
  the pattern. 5.10's form was chosen that way before any Z80 was written.
- **`doc-examples` screenshots**: a last-bit change can move a plotted point (`INT` of a whole number:
  `COS(120)` was 1 ulp short of −0.5). Rewrite an image (`manual_run.py --write-shots --filter id`) only
  after checking the moved pixels against exact maths.
- The calculator stack has 8 slots; `CALC_PUSH_FP_RAW` leaves HL 5 bytes on (walk a constant table with
  it); `rst $28`'s B is the literal parameter (0 for the arithmetic).

Not to be done (owner or below the bar): the top of the operand stack in registers (5.5 step 2, F15), a
page-aligned opcode table, `LOAD_VAR` pushing for itself. The SCLD offers nothing for output speed
(no hardware scroll, blitter or text mode); page flipping with the second display file would be a
language feature.

## Before pushing (owner, 2026-10-27)

`backport/leapc` vendors the simulator at z80sim commit `13c9bce`, which is on GitHub (pushed
2026-10-27, owner). The rule for later simulator changes: push `~/z80sim` (`git -C ~/z80sim push origin
main`) before, or in the same sitting as, the 2068-Leap branch that vendors them. `tools/hooks/pre-push`
(installed in this clone: `git config core.hooksPath tools/hooks`; once per clone elsewhere, see
CONTRIBUTING.md) refuses a 2068-Leap push whose `tools/z80sim/UPSTREAM.md` names a z80sim commit not yet
on GitHub, and prints that command.

## Working rules (owner)

- Standard test runs (`make test`, `make qual`, the prod suites) go to a cheaper subagent
  (haiku/sonnet) that reports PASS/FAIL counts and failing text; the main session judges them.
- Run long suites on an rsync copy in the scratchpad, never `make` in the real tree while a suite runs
  there. `make test` is ~32-40 min (fast emulation); the prod suites use ports 10241-10246.
- Never run `make test-legacy` / `test-all` (Fuse) unprompted. Fuse was approved only for probe 0.8.
- Commit only on `backport/leapc`; don't push. A prototype may live on its own branch off it, and is
  integrated (fast-forward) only on the owner's word. `~/z80sim` changes: commit there (owner-approved
  for the simulator), never push without asking.
- Each item: measure bytes with `make budget`, record them in the plan's ledger and item outcome.

## Tools (use them)

| Tool | What it checks |
| --- | --- |
| `tools/qual/qcanary.py --banking` | paging invariants over the corpus (5.9: also an EXROM entry slot entered with the EXROM paged out) |
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
| `tools/qual/qprofile.py` | where the run time goes: per-instruction profile of 11 workloads (a breakpoint at every dispatch); `--statements`: T one statement adds to a loop |
| `tools/qual/qfndiff.py` | a numeric built-in on two builds, `v = F(arg)` for ~1,900 arguments, every result's 5 bytes compared (5.7, 5.9, 5.10) |
| `tools/qual/qfndiff.py --exact` | the same, each build's results scored in ulp against exact values (`SIN`, `COS`, `TAN`, `SQR`) |
| `tools/qual/qsinfit.py [--leapc DIR]` | `SIN_COEFFS` re-derived (Remez); with Leap-C's model, `SIN`/`COS`/`TAN` simulated step by step and scored |
| `tools/qual/qscrdiff.py` | 15 printing programs that scroll, on two builds: the whole screen compared (5.8, 5.11, 5.13) |
| `tools/qual/qrtime.py` | T-states of one ROM routine with given registers and pokes (`GFX_CLEAR_ROW BC=0x1700`) |
| `tools/qual/qvmedge.py` | in `make qual`: 120 edge cases of the integer FOR path, the combined instructions and the operand stack's limit (5.3-5.5), expectations from the manual's rules |
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

## Pitfalls met in 5.6-5.8

- `make check` runs the calculator (and sprite drivers) in the Python simulator `tools/z80sim`: an
  instruction the ROM starts using must exist there (5.6 needed `EXX`, `ADC HL,rr`, `CCF`). Change it in
  `~/z80sim` first, with a test, commit there, then copy the files back and record the commit in
  `tools/z80sim/UPSTREAM.md` (R1 had edited the vendored copy in place; that is now reconciled).
- The alternate register set (BC', DE', HL') is free in V2 (only the tape code uses AF'); a routine that
  uses it must not call anything that might start using it.
- BASIC test programs: a string literal is at most 31 characters (compile error 70); `out` and `over` are
  keywords, not labels.

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
  no `rl`/`rr (hl)`, no `set`/`res`, no `lddr`: added (5.6 added `EXX`, `ADC HL,rr`, `CCF`, upstream
  first). It still has no `EX (SP),HL`; its cells must be registered in the test (`CALC_FX/FY/FQ`).
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
