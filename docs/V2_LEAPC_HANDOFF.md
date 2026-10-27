# Leap-C back-port: handoff for the rest of phase 5 (5.12, 5.13, 5.11) and phase 6

Written 2026-10-26 at the end of phase 3, updated through phases 4 and 5; this version 2026-10-27, after
6.1 (package functions). The plan is `docs/V2_LEAPC_BACKPORT_PLAN.md` (the ledger, every item's outcome,
the owner decisions F1-F28); this file is only where things stand, what comes next and how to pick it up.

## Where things stand

- **Branch `backport/leapc`** (off `v2-development`), at `e9423ab`. On it: phases 0-4, the redraw item,
  5.1 (decimal literals), R1 (calculator rounding), `SH_VIEW` (ED4), ED3/ED7, 5.2-5.5 (VM speed),
  5.6-5.8 (calculator multiply/divide in registers, `SQR` halving, the row clear), 5.9/5.10
  (`SIN`/`COS`/`TAN` in the EXROM, the polynomial, Q-35; F26), item VER (the ROM's version at power-on;
  F27) and **6.1** (package functions, package ABI 2.1; F28, integrated whole by fast-forward). GitHub
  has it up to `0227797` (F21); everything after is local (12 commits) until the owner says to push.
- **Free ROM: HOME 590 B, EXROM 163 B** (`make budget`). Emergency reserve HOME 64 / EXROM 32 (`make check`
  fails below it). Spending is weighted by benefit per byte (F1).
- **Phase 6's room, re-sized by 6.1** (plan, "Re-sized after 6.1"): 6.1 took HOME 100 / EXROM 0 [M];
  6.2-6.4 keep HOME ~60 / EXROM ~30 [E]. **Above the reserve and that: HOME 466 B, EXROM 101 B.** Check
  every item against *free − reserve − 6.2-6.4's allowance ≥ its cost* in the ROM it uses.
- **Owner rules for what is left** (2026-10-27): a change must give a *significant speed increase* or
  *use less HOME or EXROM* (F17); the phase 5 follow-ups must *leave room for phase 6* (F19).
- **What phase 5 gave** [M] (`qbench`, `qprofile --statements`, against the build before 5.2): counter
  and GOTO loops 2.4-2.55×, the sieve 1.53×, IF-heavy loops 1.56×, empty FOR 1.31×; `SQR` 3.0×,
  `SIN`/`COS` 3.0×, `TAN` 2.7×, a float divide −40% and multiply −37% a statement, a scrolling `PRINT`
  −10.6%. Every result and screen identical to before, except `SIN`/`COS`/`TAN` (5.10; F23) and Q-35.
- **6.1 in brief** (plan, "Item 6.1 outcome"): a package can export numeric functions `NAME(a, b)` and
  string functions `NAME$(a)`; the signature byte's bits 7-6 are the kind (`include/v2_ext_kinds.inc`);
  `EXT2_LOOKUP` binds a name only where its kind fits; calls compile through the built-ins' parser
  (`COMPILE_FACTOR.fn_call`); `OP_CALL_EXT` pushes `EXT_CALL_RESULT`; `EXT2_EXPORTS` (service 16)
  registers an export table. Test package `rom/v2_package_fntest.asm`, probe `tools/qual/qpkgfn.py`.
- Last full `make test` (6.1, 2026-10-27, fast emulation): all PASS once `abi-pkg-reject-newer-minor` was
  moved off `$8201` (now the ROM's own word): smoke 9/9, standalone 40/40, production checks 21, fill 10,
  prod-regress 127, prod-arrays 101, known-defects 15, saveall 13, micsave, qual 666 PASS + 2 XFAIL
  (Q-24, Q-26) + 2 N/A of 670, lifecycle 23, `qvmedge` 120, maint-qual all. `make doc-examples` was not
  run for 6.1 (no ROM text or shipped package changed; run it with the next item). Emulators only (F12).
- No stock-ROM-derived code in the images (`tools/check_provenance.py`, empty allow-list); anything
  taken from Leap-C is MIT and goes in `NOTICE.md`.

## What comes next, in this order

All three phase 5 items fit the room together (HOME ≤ ~225 of 466, EXROM ≤ ~70 of 101). Ranked by
benefit per byte (plan, "The remaining phase 5 items, in order"); each one as before: a prototype branch
off `backport/leapc`, measured (`make budget`, the ledger row and the item's outcome), `make test`
through a cheaper subagent, then **stop for the owner's decision** before integrating.

1. **5.12, `LOAD v; PUSH k; CMP_JMPZ` as one instruction** (~1,000 T an `IF i < k`; `goto_loop` −45%,
   `if_branch` −20% [E]). The handler in HOME (`rom/exrom_v2_vm_core.asm`, beside 5.4's `CMP_JMPZ`); the
   peephole next to 5.4's in `rom/exrom_v2_fuse.asm` (EXROM, ~70 B [E], production-only behind a
   `V2_EXROM_FUSE_*_ADDR` slot: bump `V2_KTAB_MAGIC` if the slot list changes); if it measures well over
   ~70, move it to HOME. A bytecode change: a new opcode (77; `VM_RUN.next`'s `cp 77` and the table),
   the `qbytecode` review and baseline reset, new `qvmedge` cases (mask, both branch directions, the
   operand at the stack's limit, a FLOAT variable falling back), `qbreak` (it jumps: `jp VM_RUN.loop`),
   `qbench` before/after, `qprofile --statements`. The test-only decompiler rebuilds IFs from plain
   `JMPZ`, so the peephole stays production-only (as 5.4's).
2. **5.13, `PRINT` of a string** (~3× a character: the screen and attribute addresses worked out once and
   stepped along the row, the 8 glyph bytes copied unrolled; ~60-120 B, HOME). Keep `INVERSE`, `OVER`,
   the attribute, the wrap at column 32 and the scroll at the bottom exactly as they are. Checks:
   `qscrdiff` (15 programs, whole screens), `qeditview` if anything shared with the editor changes,
   `qbench`/`qprofile --statements` for the T a character.
3. **5.11, the scroll copy** (each screen third's rows in one block per scanline, unrolled; ~218 →
   ~180 kT a scrolled line, contention-bound; ~30-60 B HOME, `kernel/graphics`). The editor shares
   `GFX_COPY_ROW_BITMAP`: `qeditview --oracle --ref`. Checks: `qscrdiff`, `qrtime`.
4. **Then** phase 6's rest for v2.1 (6.2 float service slot, 6.3 error service and a package error
   range, 6.4 reserved slots trap, 6.5 measured package stack, 6.6 package names vs keywords), the open
   item from 6.1 (stamp each package tape with the ABI minor it needs: `tools/make_extension_tzx.py`
   stamps the ROM's word, so the shipped packages are now `$8201` and a v2.0.x ROM refuses them), and the
   manual's speed figures after the last speed change (`tools/qual/manual_measure.py`; `04_concepts.md`
   "Speed" and `FOR`'s note).

## Suggested model and effort

- **Model: Opus 5.5** (fast mode is fine) for the item work: 5.12 changes the bytecode, the compiler's
  peephole and the VM's dispatch together, and 5.13/5.11 are T-state-counted Z80 with screen-layout
  edge cases; all three need the differential tools read critically (the "0 differ" and "ce 0"
  pitfalls below). **Effort: high**: the work is measurement-driven with good tools, not open design;
  xhigh is not needed. If an item turns into a design question (5.12's peephole not fitting either ROM),
  stop and ask rather than raising the effort.
- **Test runs: Sonnet 5.5** subagents (owner rule): `make test`, `make qual`, the prod suites, on an
  rsync copy in the scratchpad; Haiku is enough for a single suite with a fixed command.

## Pitfalls met in 6.1

- **The registry is stubbed in most standalone test images** (`rom/test_v2_*.asm` define `EXT_CALL_ARG0`,
  `EXT2_LOOKUP` and so on as stubs, as `equ`s or as bare labels): a new name the VM core or compiler uses
  (6.1: `EXT_CALL_RESULT`, `EXT_KIND_*`) must be added to every stub set, or `make check`'s standalone
  build fails. `include/v2_ext_kinds.inc` is included by the compiler and VM core for this reason.
- **A test pinned to "the next version"** breaks when the version moves (`abi-pkg-reject-newer-minor` used
  `$8201`; RC-10 was the same for programs): write "the ROM's word + 1".
- **V2's one-line `IF … THEN` takes only `GOTO`**; any other statement needs the block form `IF … THEN` /
  `ENDIF` (a test program with `IF x THEN s = 1` is compile error 9 on every build).
- **The compiler's `CEXT_*` cells are gone**: `COMPILE_EXT_CALL` keeps the slot (D), count (B) and
  signature (E) in registers, because a package function in an argument re-enters the call compile.
  Shared state in fixed cells across a recursive compile is the M-4 and N-1 pattern; check for it in any
  peephole that compiles a sub-expression.
- `EXT2_LOOKUP` now takes the kind in C (`EXT_KIND_STMT` for a statement): a new caller that forgets C
  matches whatever kind C happens to hold.

## Pitfalls met in item VER

- The version text is `include/v2_version.inc`: **edit it at each release** (now `2068 LEAP V2.1`), and
  the manual's two places that show it (`02_beginners_guide.md` Chapter 1 with `boot_screen.png`,
  `07_appendices.md` Appendix A); `doc-examples`' `guide.boot` fails until they agree.
- Every tool's boot snapshot (`qharness.Machine.start`, `v2_prod.boot`, `manual_run`) now has the version
  on row 23 and `V2_VER_FLAG` = 1: the first redraw after it (any typed key, `EDITOR_ENTER` from
  `V2_COMMAND_LOOP.loop`) is a full one and puts `LINE n/m` back. A new tool that reads row 23 straight
  from the snapshot sees the version.
- `tools/qual/qverboot.py` checks it; `tools/maint/chime_trace.py A B` compares the chime's AY writes.
- ZEsarUX gives a burst of static as the chime starts (its audio starting up); Fuse plays it clean.

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
| `tools/qual/qpkgfn.py` | package functions (6.1): 38 cases with `rom/v2_package_fntest.asm`, and one statement of each shipped package |
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
