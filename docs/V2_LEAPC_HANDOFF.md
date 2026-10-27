# Leap-C back-port: handoff for the v2.1 preparation (phase 6's rest and the release)

Written 2026-10-26 at the end of phase 3 and updated through phases 4-6.1; this version 2026-10-27, after
the last phase 5 items (5.12, 5.13, 5.11 and 5.14). The plan is `docs/V2_LEAPC_BACKPORT_PLAN.md` (the
ledger, every item's outcome, the owner decisions F1-F32); this file is only where things stand, what is
left before v2.1 and how to pick it up.

## Where things stand

- **Branch `backport/leapc`** (off `v2-development`), at the commit that adds this handoff, **pushed to GitHub** (owner,
  2026-10-27). On it: phases 0-4, the redraw item, 5.1-5.14 (phase 5 is finished), R1, `SH_VIEW`
  (ED4), ED3/ED7, item VER and 6.1 (package functions, package ABI 2.1). Not merged into
  `v2-development`, not tagged: no release has been cut since `v2.0.2-emu.1` (`77f1baa`); the plan's
  v2.0.3 (phase 2) and v2.0.4 (phase 3) were never released separately, so v2.1 carries everything.
- **Free ROM: HOME 500 B, EXROM 113 B** (`make budget`). Emergency reserve HOME 64 / EXROM 32 (`make check`
  fails below it). Phase 6's remaining allowance (6.2-6.4) HOME ~60 / EXROM ~30 [E]; **above the reserve
  and that: HOME 376 B, EXROM 51 B.** Spending is weighted by benefit per byte (F1); the owner rule for
  speed items is a *significant* gain or *less* ROM (F17).
- **The last phase 5 items** [M] (plan, "Outcome, 5.12" to "Outcome, 5.14"):
  - **5.12** `IF v <op> k` as one instruction (`CMP_VAR_JMPZ`, opcode 77): an `IF i < k` 1,689 → 703 T;
    `goto_loop` −41%, `if_branch` −19%. HOME −48, EXROM −50. A bytecode change (1,086 fusions in the
    corpus, 1,665 bytes of bytecode fewer).
  - **5.13** `PRINT` of a string: the addresses stepped along the row, the glyph copied unrolled; a
    character 1,293 → 562 T. HOME −88.
  - **5.11** the output scroll: one `LDI` stream per scanline through the three thirds; a scrolled
    line 223,669 → 146,036 T (−35%). HOME +8.
  - **5.14** the glyph lookup (owner request): a direct table for `' '`..`'@'`, letters by arithmetic;
    letters 200 → 138 T, `.` 439 → 135; `PRINT` 510 T a character; the editor −2.4% a key. HOME +38.
- **Every result and screen identical** to the build before each item (`qbytecode` review, `qvmedge`
  221, `qscrdiff` 22 programs, `qeditview --oracle --ref`, the 256-code glyph differential); the only
  intended result changes in all of phase 5 are 5.10's `SIN`/`COS`/`TAN` (F23) and Q-35.
- **Last full `make test`** (5.14, 2026-10-27, fast emulation): all PASS (2,275 s): smoke 9/9,
  standalone 40/40, production and fill checks, prod-regress 127, prod-arrays 101, known-defects 15,
  saveall 13, micsave 3, qual 666 PASS + 2 XFAIL (Q-24, Q-26) + 2 N/A of 670, lifecycle 23, `qvmedge` 221,
  maint-qual all; `make doc-examples` 327/327. Emulators only (F12).
- No stock-ROM-derived code in the images (`tools/check_provenance.py`, empty allow-list); anything
  taken from Leap-C is MIT and goes in `NOTICE.md`.

## What is left before v2.1, in this order

1. **Phase 6's rest** (plan, "Phase 6"; sizes [E], replace each with `make budget`'s figure):
   - **6.2** a float service slot through an EXROM page-in wrapper (as slot 14 does); a float function
     kind if wanted (~15 B HOME). 
   - **6.3** an error service and a registered package error range (closes R10.8 A3: package codes 12-21
     overlap the VM's); maybe a package error message (EXROM ~0-30).
   - **6.4** the reserved service slots trap with a defined error instead of `$FF` bytes.
   - **6.5** a measured package stack budget (Leap-C measured 30-42 B a service with an interrupt) instead
     of the unmeasured 512 B allowance; no ROM.
   - **6.6** a package name equal to a keyword: document it, and the host tool warns (Leap-C's
     `lib2tape.py`); no ROM.
   - Each as before: a prototype branch off `backport/leapc`, `make budget`, the ledger row and outcome,
     `make test` through a cheaper subagent, the owner's decision. 6.2-6.4 change the package ABI's
     surface: `docs/PACKAGE_ABI.md`, `include/v2_package_abi.inc`, `tools/check_package_abi.py` (in
     `make check`), and `tools/qual/qpkgfn.py`-style probes.
2. **The open item from 6.1:** each package tape is stamped with the ROM's ABI word
   (`tools/make_extension_tzx.py`), so the shipped packages say `$8201` and a v2.0.x ROM refuses them
   although only the function packages need 2.1. Stamp the minor a package needs (2.0 unless it exports
   functions) and check that a v2.0.2 ROM loads the statement-only packages again.
3. **The manual's figures** after the last speed change: `tools/qual/manual_measure.py` (the T-state
   table of `docs/manual/04_concepts.md` "Speed" and `FOR`'s note; last measured at `0227797`, before
   5.12-5.14), and the bytecode-size table there if an example's bytecode changed (`make doc-examples`
   327/327 today: `mem.compile.1` has no `IF`).
4. **Owner decisions for the release** (ask; none is taken yet):
   - the designation (the boot text is already `2068 LEAP V2.1`, `include/v2_version.inc`; earlier
     releases were `v2.0.N-emu.1` with an "emulator-qualified" status) and the release name;
   - merging `backport/leapc` into `v2-development` (the earlier releases were tags on `v2-development`)
     and the annotated tag; the GitHub release and its bundle;
   - Q-26 (the nine missing glyphs `[` `\` `]` `^` `` ` `` `{` `|` `}` `~`, ~72-90 B HOME, deferred for want of room on
     2026-10-11) is now affordable (376 B above the allowance); the two optional phase 5 follow-ups (the
     two-variable `IF k <= s`, ~20 B HOME / ~15 EXROM, the sieve's inner loop); and whether
     `make test-legacy` (V1, Fuse) and the hardware checklist are waived again (no hardware, F12).
5. **The release record and documents**, following `v2.0.2-emu.1` (`77f1baa`; its record is
   `docs/V2_COMPILER_MAINT_RELEASE_STATUS.md`): a new `docs/V2_..._RELEASE_STATUS.md` (what changed since
   `v2.0.2-emu.1`: phases 1-6 of the plan in user terms; the image hashes from `make rc-assets`
   → `build/release-v2-rc/`; the identity CRC that `SAVE ... ALL` stamps, which changes with every ROM
   change (RC-O3: an ALL tape restores its variables only on the ROM pair that wrote it); free space;
   the qualification table; the limitations); `tools/make_rc_assets.py`'s per-release designation;
   `README.md`, `docs/README.md`, `docs/AUTHORITATIVE_SOURCE.md`, `docs/EMULATOR_SETUP.md`,
   `docs/V2_HARDWARE_CHECKLIST.md` (a section for the release), `docs/V2_LANGUAGE_REFERENCE.md`, the
   earlier records' "later release" notes, CI's text (`.github/workflows/check.yml`); the defect register
   (Q-35 and the phase 2 fixes as released); `NOTICE.md` (Leap-C's MIT parts); the manual's edition text
   (and `02_beginners_guide.md` Chapter 1 / `07_appendices.md` Appendix A with `boot_screen.png` if the
   version text changes: `doc-examples`' `guide.boot`), then the Word editions (`make manual-v2`).
6. **Qualification for the record:** `make test`, `make doc-examples`, `make repro` (two fresh trees,
   identical images), `make build EXTRA_DEFS=` (the release definitions), `qcanary --banking`,
   `qtapetol`, `qpoweron`; the owner's decision on `make test-legacy` and hardware.

## Suggested model and effort

- **Phase 6's rest: Opus 5.5, high effort** (fast mode is fine): ABI surface and Z80, measured as before.
  If 6.3's error range turns into a design question (which codes, what a package may raise), stop and ask.
- **The release documents: Opus 5.5, medium effort**: mostly careful editing against the `v2.0.2-emu.1`
  pattern; the risk is a stale figure or hash, so take every number from a fresh `make rc-assets` /
  `make budget` / test log, never from this file.
- **Test runs: Sonnet 5.5** subagents (owner rule) on an rsync copy in the scratchpad; Haiku for a single
  suite with a fixed command. Only one `make test` at a time: the prod suites use fixed ports 10241-10246.

## Pitfalls met in 5.12-5.14

- **A peephole must know where its pattern starts.** The bytes before an operator can look like
  `LOAD v; PUSH k` without being the condition (`IF c + d < 8` when d's index is 3; `IF d < 5 + c`):
  5.12 passes the condition's start from `COMPILE_IF` (pushed across `COMPILE_EXPR`; a compile error
  returns, so the pop balances) and fuses only an exact match.
- **A negative literal is a folded `PUSH_I16`** (`-1` is `PUSH_I16 $FFFF`), not `0 - k`; `PUSH_I8` holds
  0-127 only.
- **A FLOAT-tagged whole number prints with four decimals** (`3.0000`); `qvmedge` expectations that print a
  FLOAT must follow that (its `num()` models INTs).
- **A string holds at most 31 characters**, so a "32-character" test string is truncated: fill a row with
  two items (`PRINT "-"; a$`).
- **The alternate set is in use** in `GFX_PRINT_STRING_ATTR` (5.13: the attribute pointer, the
  attribute, the count, the row) as well as the calculator's `FMUL`/`FDIV` (5.6); the tape code uses
  AF'. Nothing they call uses it; keep it that way.
- **`GFX_COPY_ROW_BITMAP` and `GFX_SCROLL_TEXT_UP` are not in the V2 images** any more (5.11; the V2
  editor redraws, and the old caller is V1's `basic/editor_integration.asm`). The previous handoff's
  "the editor shares `GFX_COPY_ROW_BITMAP`" was wrong for V2.
- **`GFX_CHAR_TO_FONT_OFFSET` is package service slot 2**: its contract (A in; HL and NC, or CF; D kept)
  is ABI. 5.14 kept it and checked all 256 codes; `PUNCT_CHAR_COUNT` (23) is read by `check_docs.py`.
- **`pkill -f` and `pgrep -f` match the shell whose command line holds the pattern** (again: a wait loop
  `until ! pgrep -f qeditview.py` waits on itself). Wait on a file's last line instead.
- `qprofile --statements` now has 28 rows (IF and string `PRINT` rows added); `qscrdiff` 22 programs.

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
- Commit only on `backport/leapc`; push only on the owner's word (last push 2026-10-27, after 5.14). A prototype may live on its own branch off it, and is
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
| `tools/qual/qprofile.py` | where the run time goes: per-instruction profile of 11 workloads (a breakpoint at every dispatch); `--statements`: T one statement adds to a loop (IF and string `PRINT` rows since 5.12/5.13) |
| `tools/qual/qfndiff.py` | a numeric built-in on two builds, `v = F(arg)` for ~1,900 arguments, every result's 5 bytes compared (5.7, 5.9, 5.10) |
| `tools/qual/qfndiff.py --exact` | the same, each build's results scored in ulp against exact values (`SIN`, `COS`, `TAN`, `SQR`) |
| `tools/qual/qsinfit.py [--leapc DIR]` | `SIN_COEFFS` re-derived (Remez); with Leap-C's model, `SIN`/`COS`/`TAN` simulated step by step and scored |
| `tools/qual/qscrdiff.py` | 22 printing programs, on two builds: the whole screen compared (5.8, 5.11, 5.13: every character code, OVER/INVERSE over text, rows of 32, off-screen POKEs) |
| `tools/qual/qrtime.py` | T-states of one ROM routine with given registers and pokes (`GFX_CLEAR_ROW BC=0x1700`) |
| `tools/qual/qvmedge.py` | in `make qual`: 221 edge cases of the integer FOR path, the combined instructions (5.4, 5.12's `IF v <op> k`) and the operand stack's limit, expectations from the manual's rules |
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
