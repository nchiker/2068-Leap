# Leap-C back-port: handoff for the rest of phase 5 and for phase 6

Written 2026-10-26 at the end of phase 3, updated through phases 4 and 5; this version 2026-10-27, at the
end of 5.6-5.8. The plan is `docs/V2_LEAPC_BACKPORT_PLAN.md` (the ledger, every item's outcome, the owner
decisions F1-F19); this file is only where things stand, what comes next and how to pick it up.

## Where things stand

- **Branch `backport/leapc`** (off `v2-development`), not pushed. On it: phases 0-4, the redraw item,
  5.1 (decimal literals), R1 (calculator rounding), `SH_VIEW` (ED4), ED3/ED7, 5.2-5.5 (VM speed) and
  5.6-5.8 (calculator multiply/divide in registers, `SQR` halving, the row clear; owner F18: integrated
  once `make test` passed). Merged prototype branches that can be deleted: `proto/5.2-5.4-vm-speed`,
  `proto/5.5-vm-push`, `proto/5.6-5.8-calc-sqr-scroll`.
- **Free ROM: HOME 286 B, EXROM 573 B** (`make budget`). Emergency reserve HOME 64 / EXROM 32 (`make check`
  fails below it). Spending is weighted by benefit per byte (F1).
- **Owner rules for what is left** (2026-10-27): a change must give a *significant speed increase* or
  *use less HOME or EXROM* (F17); and the phase 5 follow-ups must *leave room for phase 6* (F19).
- **What phase 5 gave** [M] (`qbench`, `qprofile --statements`, against the build before 5.2): counter
  and GOTO loops 2.4-2.55×, the sieve 1.53×, IF-heavy loops 1.56×, empty FOR 1.31×; `SQR` 3.0×,
  `SIN`/`COS` 2.0×, a float divide −40% and multiply −37% a statement, a scrolling `PRINT` −10.6%;
  every result and every screen identical to before (the bytecode changed only in 5.4's intended
  rewrites).
- Last full `make test` (5.6-5.8, 2026-10-27, 1,824 s, fast emulation): all PASS (smoke 9/9, standalone
  40/40, prod-regress 127, prod-arrays 101, known-defects 15, saveall 13, micsave 3, qual 663 PASS + 2
  XFAIL + 2 N/A, lifecycle 23, `qvmedge` 120, maint-qual all); `make doc-examples` 327/327. Emulators only
  (F12): nothing has run on a physical TS2068.
- No stock-ROM-derived code in the images (`tools/check_provenance.py`, empty allow-list); anything
  taken from Leap-C is MIT and goes in `NOTICE.md`.

## What comes next, in this order

The space arithmetic is the plan's "Room for phase 6": phase 6 is allowed **HOME ~260 B, EXROM ~100 B**
[E] until 6.1 is sized; with 286 B free HOME is ~40 B short of that already. Check every item against
*free - reserve - phase 6's allowance >= its cost* in the ROM it uses.

1. **5.9 with 5.10: the float built-ins to the EXROM** (the only item that frees HOME, up to 611 B:
   `SQR`, `PI`, `RAD`, `DEG`, `SIN`, `COS`, `TAN`, `SIN_PEEK_POP`, the divisor table). They only run
   while the EXROM is paged in (program runs and immediate statements, under the shell); confirm with
   `qcanary --banking`, and that the compiler never calls them (no constant folding of functions). The
   built-in jump table (`BUILTIN_FN_JUMP_TABLE`, HOME) then points at fixed EXROM slots (the
   `V2_EXROM_SLOT` pattern of 5.4's peepholes; bump `V2_KTAB_MAGIC`). Moving as they are is bit-identical
   (`qfndiff` for each function must show 0 differences). The EXROM side is +450 to +650 B, more than
   fits with phase 6's 100 B: measure, move `SIN`/`COS`/`TAN` (452 B) first, the rest if it fits.
   **5.10** (one multiply by pi/180, a polynomial with stored coefficients instead of a divide per term)
   shortens that code and makes `SIN` ~2.3× faster again, but **changes the last bits: owner decision
   first**; measure its accuracy against exact values (as `qcalcround` does) and list what changes with
   `qfndiff`.
2. **Size 6.1** (package functions with Leap-C's export table and signature bytes) as a prototype, to
   replace phase 6's allowance with a measured figure before spending more.
3. **Then, where the room is** (after 5.9 HOME has it, the EXROM may not):
   - 5.13, `PRINT` of a string (~3× a character: the addresses worked out once, an unrolled glyph copy);
     the print path runs only with the EXROM in, so either ROM works. Check: `qscrdiff` (same screen).
   - 5.11, the scroll copy (each screen third's rows in one block per scanline, unrolled; ~218 → ~180 kT,
     contention-bound). HOME (`kernel/graphics`); the editor shares `GFX_COPY_ROW_BITMAP`, so also
     `qeditview`. Check: `qscrdiff`, `qrtime`.
   - 5.12, `LOAD v; PUSH k; CMP_JMPZ` as one instruction (~1,000 T an `IF i < k`): the handler in the
     EXROM only if the dispatch can reach it there (the EXROM is in at every dispatch: `qcanary`'s
     invariant), the compiler side next to 5.4's in `rom/exrom_v2_fuse.asm`. Bytecode changes:
     `qbytecode` review and baseline reset; `qvmedge` cases.
4. **Phase 6 (ABI 2.1)**, items 6.1-6.6, for v2.1. Before the v2.1 release: re-run
   `tools/qual/manual_measure.py` and update the manual's speed figures (`04_concepts.md` "Speed",
   `FOR`'s note), which predate all of phase 5.

Not to be done (owner or below the bar): the top of the operand stack in registers (5.5 step 2, F15), a
page-aligned opcode table, `LOAD_VAR` pushing for itself. The SCLD offers nothing for output speed
(no hardware scroll, blitter or text mode); page flipping with the second display file would be a
language feature.

## Before pushing (owner, 2026-10-27)

`backport/leapc` now vendors the simulator at `~/z80sim` commit `13c9bce`, which exists **only in the
local clone** (`~/z80sim` is one commit ahead of `origin/main` on GitHub). Nothing pushes it
automatically. To publish both:

1. `git -C ~/z80sim push origin main` (first, or in the same sitting);
2. then push 2068-Leap's branch.

`tools/hooks/pre-push` (installed in this clone: `git config core.hooksPath tools/hooks`) refuses step 2
until step 1 is done, naming the missing commit and the command. In another clone, set `core.hooksPath`
once (CONTRIBUTING.md). Branches that still vendor the older, already-published simulator
(`v2-development`) push as before.

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
| `tools/qual/qprofile.py` | where the run time goes: per-instruction profile of 11 workloads (a breakpoint at every dispatch); `--statements`: T one statement adds to a loop |
| `tools/qual/qfndiff.py` | a numeric built-in on two builds, `v = F(arg)` for ~1,900 arguments, every result's 5 bytes compared (5.7, 5.9, 5.10) |
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
