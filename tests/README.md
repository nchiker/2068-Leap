# tests/ — regression test suite

Plain-text BASIC listings (`tools/preload_gen.py`'s own input format:
one statement per line, blank lines and `;;`-prefixed lines skipped).
Each one gets built into a standalone, self-checking preload-harness
ROM via:

```sh
python3 tools/preload_gen.py tests/<name>.txt rom/test_suite_<name>.asm SUITE_<NAME> --autorun
sjasmplus rom/test_suite_<name>.asm
```

or, for the whole build+run+screenshot cycle in one step:

```sh
tools/run_suite_test.sh <name>
```

## Convention every test file follows

```
BORDER 4
IF <expression that should be true> <> <expected> THEN BORDER 2
... more checks, each its own line ...
```

Green (4) = every check passed. Red (2) = at least one failed —
`BORDER 4` sets the optimistic default first, and each check only ever
overrides it to red, never back to green, so once anything fails the
verdict stays red regardless of what runs after. Border color is this
project's own established pass/fail signal throughout (no serial/
stdout on real hardware).

**Superseded (2026-08-22): the original `F = 0` / `F = F + 1` / `IF
F = 0 THEN BORDER 4` / `IF F > 0 THEN BORDER 2` counter convention.**
Replaced during a since-reverted DATA/READ/RESTORE prototype whose own
EXROM migration temporarily shrank Home ROM's free margin enough to
break nearly the whole suite at once — the counter pattern's own fixed
overhead (`F = 0` plus two border-verdict lines, ~55 bytes regardless
of check count) was costing more than the actual checks in a single-
or-two-check file. DATA/READ/RESTORE itself didn't survive that same
session (see "Real bug/change log" below), but this convention change
is kept regardless — it's a strict improvement independent of that
budget pressure: just one setup line, and each check is a single self-
contained statement, with no per-file overhead to speak of. Confirmed
correct in both directions with a live emulator test before converting
the rest of the suite (a passing 2-check program stayed green; a
deliberately-wrong check correctly turned it red and it stayed red).
Splitting several files into smaller ones (`math7`-`math10`, `str8`-
`str11`, `arr4`) happened alongside this and was likewise kept even
after the budget pressure that originally forced it went away — more,
smaller category files, consistent with the project's own established
precedent noted below.

**Never use `BORDER 6` (yellow) as a test's own verdict color.**
`--autorun`'s own harness reserves yellow for ITS signal ("the whole-
program static check failed — the test never even ran"), completely
independent of the test program's own pass/fail logic. Colliding with
it is a real trap: a self-inflicted bug in this suite's own early
`math4` test used yellow for a legitimate "value fell in this range"
verdict, and every follow-up debugging session misread that as a
checker failure — burning real time chasing two bugs (a supposed
`RAD`/`DEG` precision bug, a supposed `AND`-with-float-derived-
variable checker bug) that never existed. Stick to red/green/blue/
magenta/cyan/white for a test's own verdicts.

## Why small files, not one big suite

Each preload harness bakes its BASIC program directly into the same
16K Home ROM image as the ROM's own code — sharing the same tight free
margin (currently ~208 bytes), not the much larger RAM program area a
typed-in program would use. A handful of `IF`/`THEN` checks per file
is what actually fits; this is why the suite is organized as many
small, category-scoped files (`math1.txt`, `math2.txt`, ...) rather
than one comprehensive program, matching this project's own existing
`rom/test_arr1..8.asm`/`test_str1..7.asm` precedent.

## Files

- `math1.txt`–`math10.txt` — `ABS`/`SGN`/`MOD`/`DIV`/`SQR`/`INT`/`PI`/
  `RAD`/`DEG`/`PEEK`/`POKE`/`FREE`/`STICK`
- `str1.txt`–`str11.txt` — `UPPER$`/`LOWER$`/`LEFT$`/`RIGHT$`/`CHR$`/
  `STR$`/`VAL`/`LEN`/`CODE`/`INKEY$`
- `cf1.txt`–`cf7.txt` — control flow: `IF`/`ELSE`/`END IF`,
  `IF`/`ELSEIF`/`ELSE`/`END IF`, `FOR`/`NEXT`, `EXIT FOR`,
  `GOTO`/labels, `GOSUB`/`RETURN`, `CALL`/`RETURN`
- `run_state.txt` — dedicated two-RUN harness proving that abandoned FOR and
  GOSUB frames cannot leak into the next execution
- `arr1.txt`–`arr6.txt` — `DIM`, numeric and fixed-length string array
  read/write, arithmetic over
  array elements, array-indexed-by-array (`A(B(0)) = 99`), `DIMN`
- `io1.txt`–`io4.txt` — `INK`/`PAPER`/`AT` and `BRIGHT`/`FLASH`
  (verified against the real screen-attribute byte via `PEEK`, not
  just smoke-tested), `RANDOMISE`/`RND` determinism, `PAUSE`/`CLS`
- `gfx1.txt`–`gfx10.txt` — pixel/block/line/circle/fill graphics,
  `POINT`, and direct attribute reads through `ATTR(row,col)`
- `frame.txt` / `frame_over.txt` — loadable FRAME geometry, reversed corners,
  interior exclusion, and OVER-twice bitmap restoration; unloaded and NEW-
  clearing variants verify lifecycle behavior
- `err1.txt` — a runtime error (`SUBSCRIPT OUT OF RANGE`) correctly
  halting execution and reaching the status-line error display,
  verified via a marker border color (see "Verdict convention for
  runtime-error tests" below), since the program never reaches its
  own final `BORDER` statement once the error fires.

Numbering isn't sequential-by-check-count within a category — several
of the higher numbers (`math7`-`math10`, `str8`-`str11`, `arr4`) exist
because a single-or-two-check file was split off from a lower-numbered
one to fit Home ROM's budget (see the convention note above), not
because they were added later in a planned order.

## Verdict convention for runtime-error tests

A test that deliberately triggers a runtime error can't use the usual
`IF F=0 THEN BORDER 4` tail — the statement that would set it never
runs once the error halts the program. Instead: set `BORDER 5` (cyan)
immediately before the failing statement, and put a DIFFERENT color
(anything other than 5, 4, 2, or 6 — those are already spoken for)
after it. If the ROM is working correctly, execution stops at the
error and the border stays cyan; if a future bug caused execution to
continue past a runtime error instead of halting, the border would
change to whatever comes after, which is exactly what this convention
is watching for. `err1.txt` is the first test using this pattern.

`mem2.txt` is the exception: the whole-program validation rejects its
deliberately impossible `DIM A(FREE())` before execution begins, so no
fixture-set border is reached. The automated runner therefore recognizes the
cold red border as that fixture's expected pre-run rejection. It is listed
explicitly rather than treating red as success for any other test.

## Gaps not covered by this suite

- **`DATA`/`RESTORE`/`READ`** — design-documented
  (`docs/basic_language_reference.md`) but deliberately not
  implemented: scoped out in full, then set aside 2026-08-22 once
  weighed against this dialect's own integer-only numeric arrays,
  which already cover the same ground with none of `READ`'s one-shot
  position-tracking constraints — see that doc's own "Status" note.
  Nothing to test.
- **`INPUT`** — blocks on real keyboard input, incompatible with the
  `--autorun` headless harness.
- **`SOUND`/`BEEP`/`SPRITE`/graphics (`PLOT`/`LINE`/`BLOCK`/`CIRCLE`/
  `CPLOT`/`MODE`/`FILL`)** — not yet covered by this suite. Audio
  can only be smoke-tested (no way to verify a sound was actually
  produced); graphics could use `POINT()` readback the same way `io1`/
  `io3` used `PEEK` on attribute RAM, but hasn't been built yet.

## Real bug/change log

- **Multi-keyword bold highlighting's own Home ROM budget regression,
  caught by this suite (2026-08-23).** Extending keyword bolding to
  cover every colon-separated segment (not just a line's first word)
  first shipped Home-resident at ~159 bytes, leaving only 40 bytes
  free — enough for `rom/test_basic.asm` alone, but not for this
  suite's own preload-harness overhead. A first EXROM migration pass
  raised that to 112 bytes free, which looked like plenty from the
  free-byte count alone — but re-running the FULL suite (not just
  spot-checking a couple of files) still turned up 6 real failures
  (`cf2`, `cf4`, `cf6`, `cf7`, `io3`, `arr5` — each a genuine build
  overflow, 33-42 bytes, not a flaky run) that a smaller check would
  have missed entirely. A second migration pass (moving the keyword-
  table walk itself to EXROM, via a runtime address handoff instead of
  a compile-time label) fixed all six. Worth remembering: after any
  Home-side budget change, re-run the WHOLE suite before calling it
  fixed, not just the file(s) that happened to catch attention first —
  see docs/programmers_reference.md's "Multi-keyword bold highlighting"
  section for the full writeup.
- **`DIMN`/multi-dimensional arrays built; 2D archived, `DIMN` kept
  (2026-08-22).** Full 2D array support (`DIM name(rows,cols)`, 2D
  read/write, `DIMN(name,dim)`) was built and verified correct in the
  emulator, then archived once its real Home/EXROM cost was actually
  measured (Home over by ~26 bytes even after real optimization
  effort, EXROM by ~69 with the whole feature moved there instead) —
  weighed against what a 1D array already covers in an integer-only
  dialect, judged not worth that cost. See `docs/programmers_reference
  .md`'s "Multi-dimensional arrays (archived)" section for the full
  design. `DIMN` alone survived, simplified to `DIMN(name)` (single
  argument — no "which dimension" left to ask about). `arr5.txt` is
  the first test covering it. A real bug was caught along the way: the
  `arr6.txt` additionally covers `DIM A$(n)`, string expression
  assignment/read, and `DIMN(A$)`. The first `DIMN` draft had no
  `BASIC_CHECK_ONLY` guard at all, so it
  called the real array lookup during the static whole-program check
  too — a program using `DIMN` correctly still failed its own check
  with a spurious `ARRAY NOT DIMENSIONED` (screenshot-confirmed
  yellow, not the real green verdict), fixed by adding the same guard
  `.do_array_read` already has.
- **DATA/READ/RESTORE prototyped, then reverted (2026-08-22).** Built
  in full — three new keywords, a persistent DATA-position pointer
  (`DATA_STMT_PTR`/`DATA_READ_PTR`), and a full EXROM migration
  (`rom/exrom_data.asm`, two new KTAB entries) once a first Home-
  resident draft landed 66 bytes over budget. Reverted whole, not
  because it didn't fit — it did, cleanly, at ~89 bytes of unavoidable
  Home-side dispatch/wrapper cost — but because the user judged it
  didn't clear the bar over what numeric arrays already do in an
  integer-only dialect (see `docs/basic_language_reference.md`'s own
  "Status" note on that decision). Every sysvar, KTAB entry, dispatch
  entry, and file this attempt touched was manually reverted (no git
  in this repo) and confirmed byte-for-byte back to the pre-attempt
  Home ROM size (22944 assembled lines, 208 bytes free) before
  anything else continued. The `BORDER 4`-default test convention and
  the file splits this attempt's own budget pressure motivated were
  kept anyway — see the convention note above for why.
- **Runtime error display unified with the status bar (2026-08-22).**
  `BASIC_REPORT_ERROR` used to `GFX_CLS` the whole screen for a
  runtime error; it now writes to row 23 via the same
  `BASIC_PRINT_STATUS_TEXT` rendering check-time errors already use,
  leaving whatever the program had already printed on screen intact.
  Cost ~19 bytes net in Home ROM, which pushed `str4.txt` and `cf6.txt`
  (both already near the per-file budget) over the edge — split into
  `str4`/`str7` and `cf6`/`cf7`. See `docs/programmers_reference.md`'s
  "Unified runtime error display" section for the full writeup,
  including a real latent-overflow bug fixed in `BASIC_APPEND_STR`
  along the way (no length cap before this — never triggered by any
  existing caller, but a detokenized statement text could have walked
  past `STATUS_BUF` into adjacent sysvars) and a separate, NOT-yet-
  fixed finding flagged for discussion there: the static checker can
  produce a false-positive `DIVISION BY ZERO` for code that runs fine,
  because it evaluates expressions for real against `VAR_TABLE` state
  from before the check pass's own (never-committed) assignments.

## Real bug found by this suite: `STR$(n)` always returned ""

`str4.txt` caught a real bug (2026-08-22): `STR$(123)` returned an
empty string. Root cause: `.f_str` in `rom/exrom_strfuncs.asm` called
`KTAB_BASIC_NUM_TO_STRING` — whose own contract is `Destroys: AF, BC,
DE, HL` — before consuming `C`, the caller's copy-budget register. The
bare KTAB trampoline does no save/restore of its own, so `C` landed on
whatever garbage `BASIC_NUM_TO_STRING` left behind; when that happened
to be 0, the copy loop's own `cp c` budget check fired on its very
first iteration, producing 0 bytes copied. Fixed by stashing `C`
across the call (`ld a,c` / `push af` ... `pop af` / `ld c,a`) — the
same "push what a destructive call's own contract doesn't preserve"
discipline this project has hit repeatedly elsewhere (`STR_FUNC_CALL_ID`,
`FUNC_CALL_ID`/`ARGC`, `CUR_VAR_LETTER`, `DETOK_BUF`).
