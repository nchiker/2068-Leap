# 2068 Leap

2068 Leap is an alternate-history ROM for the Timex Sinclair 2068: structured BASIC, a
real full-screen editor, AY sound, and TS2068-specific graphics, built as
documented kernel modules instead of the tangled monolith of the original
ROM — while still fitting a stock 48K machine and staying instant-on.

The project is open source under the [MIT License](LICENSE). It is an
independent community project and is not affiliated with Timex, Sinclair,
Fuse, ZEsarUX, or the ULAplus project.

## Status

Working integrated ROM: full-screen editor, structured BASIC, graphics,
sound, EXROM banking, and TS2068-framed SAVE/LOAD are assembled and tested
under Fuse. The automated language regression suite currently contains
67 passing fixtures. Use `make budget`, `make check`, and `make test` for
the current reproducible build and validation entry points. `make check`
also assembles nine standalone boot/kernel smoke ROMs; `make smoke-build`
runs that build-only compatibility check directly. `make test` executes
the deterministic memory and math smoke ROMs in Fuse before running the
67-fixture integrated language suite; the other smoke ROMs remain visual,
keyboard, or tape-interactive checks.

## Quick start

The source build requires GNU Make, Python 3, and
[SjASMPlus 1.23.1](https://github.com/z00m128/sjasmplus/releases/tag/v1.23.1)
or a compatible newer release. Install SjASMPlus from its official release
or follow its source-build instructions, then run:

```sh
make check
make budget
```

The production images are written to `build/test_basic.bin` (Home ROM),
`build/exrom.bin` (EXROM slot 6), and `build/ts2068rom_zesarux.bin` (combined
image for ZEsarUX). Generated ROMs are deliberately not committed;
ready-to-run binaries should be attached to tagged GitHub releases.

For full emulator-driven testing, install Fuse plus `python3-xlib` and
Pillow, provide an X11 display, and run `make test`. Upstream Fuse 1.9.1 does
not expose ULAplus on the TS2068; the complete ROM can instead be run in
ZEsarUX 13 with ULAplus enabled. An optional patch for Fuse based on
`fuse-1.9.1-21-gdd48d9fc` is included at
[`patches/0001-Add-ULAplus-support-for-Timex-machines.patch`](patches/0001-Add-ULAplus-support-for-Timex-machines.patch).
Apply it from a compatible Fuse source tree with `git am <patch-file>`, then
build and install Fuse normally.

This is pre-1.0 software. Keep backups of programs saved with development
builds because the native program payload may still evolve.

## Layout

```
rom/        top-level ROM image assembly (ORG, module includes, entry vectors)
kernel/     hardware-facing modules, reusable by other assembly software
  editor/   standalone reference/test copy; production editor is in EXROM
  io/       keyboard and joystick primitives
  memory/   line storage, program iterator, labels, and allocator
  interrupt/interrupt handling
basic/      the BASIC interpreter — calls kernel/ APIs only, never hardware
graphics/   TS2068 graphics modes, built on kernel/io primitives
sound/      AY-3-8912 driver and music/sound-effect layer
include/    shared symbolic constants and the kernel API contract
docs/       Programmer's Reference, BASIC Language Reference (labels/control
            flow design started), Memory Map, ROM API, Hardware Notes
            (started — keyboard layout confirmed)
examples/   sample BASIC/assembly programs once there's something to run
```

## Manuals and showcase

- `docs/user_manual.md` is the maintained, example-driven user manual.
- `docs/2068_Leap_Users_Manual.docx` is its styled Word edition;
  rebuild it with `make manual`.
- `docs/technical_overview.md` is the shareable architectural and feature
  overview for people interested in how the redesigned ROM differs.
- `demos/showcase.txt` demonstrates structured flow, High Resolution Graphics,
  ULAplus, arrays, sprites and collision, AY sound, strings, and text XOR. Run
  it interactively with `tools/run_demo.sh showcase`; its timed completion is
  checked by `tools/validate_showcase.sh`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Changes should preserve both ROM
budgets and pass `make check`; BASIC changes should include a fixture in
`tests/`.

## Recommended build order

0. **Milestone 0 — boot stub** (`rom/main.asm`, done): RST vector table,
   stack init, border-cycle smoke test. No dependency on any other module —
   proves the boot chain works before anything is built on top of it. See
   "Testing Milestone 0" below.
1. `kernel/memory` (all routines implemented and hand-traced — see
   `docs/programmers_reference.md` for exactly what's confirmed on real
   hardware vs. hand-traced-only; `MEM_LINE_STORE`/`MEM_LINE_DELETE_RANGE`
   are the two most worth testing next)
   — line storage + program iterator **+ label table**
   (name -> program-position; replaces line-number addressing — see
   `docs/basic_language_reference.md`). Everything else in the editor
   depends on this.
2. `kernel/io` (implemented — see `docs/programmers_reference.md`; scan
   primitives and CAPS SHIFT+digit cursor/delete combos both confirmed
   and implemented — see `docs/hardware_notes.md`; SHIFT+letter symbol
   combos and the BREAK key are still open)
3. `kernel/editor` (single-line editing implemented and hand-traced —
   INSERT/DELETE/MOVE_CURSOR/REDRAW_SCREEN all working; new
   `EDITOR_REDRAW_HOOK` and `EDITOR_NAV_HOOK` let a caller like
   `basic/` fully replace default rendering and UP/DOWN handling — see
   `docs/programmers_reference.md`)
4. `kernel/graphics` (text-mode subset implemented — see
   `docs/programmers_reference.md`; screen addressing verified
   numerically, font glyph shapes need visual confirmation, see
   "Testing kernel/graphics" below; new `GFX_PUTCHAR_BOLD` for
   synthesized bold text) — enough for `EDITOR_REDRAW_SCREEN`
5. `kernel/math` (16-bit signed multiply/divide — Z80 has no hardware
   instructions for either; both algorithms verified via Python
   simulation against tens of thousands of cases before any Z80 code
   was written, see `docs/programmers_reference.md`; own test harness,
   "Testing kernel/math" below) — built to support `basic/`'s
   expression evaluator, kept generic and reusable rather than
   BASIC-specific
6. `basic/` (growing — tokenizer, REPL-style command loop with RUN as
   a real immediate command, variables, PRINT of strings/expressions,
   INPUT, **arithmetic expressions**: `+ - * /`, unary minus,
   parentheses, normal precedence — wired into both assignment
   (`x = y + 1`, not just a literal) and PRINT (`PRINT x+1`),
   **labels and GOTO**: a label is a statement that's entirely a bare
   name followed by `:`, case-insensitive like keywords, the whole
   label table rebuilt fresh at the start of every RUN rather than
   maintained incrementally through edits (see
   `docs/programmers_reference.md`), **runtime error reporting**:
   `BASIC_REPORT_ERROR` shows a message plus the failing statement's
   text, then halts, instead of the old silent no-op — covers
   unrecognized statements, malformed expressions, GOTO failures, and
   division by zero, **a whole-program static check pass** before every
   RUN: walks every statement first, shows "N ERRORS FOUND" plus the
   earliest problem if anything's wrong, and never runs a broken
   program at all (not exhaustive — something like `PRINT x/y` can't
   be statically flagged as division-by-zero unless `y`'s a literal
   `0`; the single-error runtime check still covers that case), **real
   multi-statement editing**: navigate with UP/DOWN, delete an existing
   line with DELETE when it's already empty, or in one keystroke with
   CAPS SHIFT+1, insert a blank line before
   the current one with CAPS SHIFT+ENTER, status line showing which
   line you're on, automatic scrolling, **and a `HELP` command**: `HELP`
   alone lists topics, `HELP <name>` shows one, full-screen, dismissed
   by any key — a small static topic table, easy to extend with more
   topics later — see `docs/programmers_reference.md` for exact scope
   and "Testing basic/" below) — interpreter loop, calling
   kernel/editor for line entry. **`IF`/`ELSEIF`/`ELSE`/`END IF`**
   (block form, plus a single-line `IF <cond> THEN <stmt>` short form),
   with `= <> < > <= >=` and non-short-circuiting `AND`/`OR`/`NOT` — see
   `docs/basic_language_reference.md` for the full grammar and known
   limitations. **`CLS`, `REM`, `BORDER <n>`, and a second immediate
   command `NEW`** (clears the program and all variables, same
   prefix-plus-trailing-check shape as `RUN`) — the first batch pulled
   from the language reference's remaining gap list, all four wired
   into live keyword bolding the same as every other keyword.
   **`INK <n>`, `PAPER <n>`, `FLASH <n>`, `INVERSE <n>`** (0-7 for
   INK/PAPER, 0/1 for FLASH/INVERSE) now actually change what `PRINT`
   draws, not just stored state — see `docs/programmers_reference.md`
   for how the attribute byte is computed and applied. **User-confirmed
   working**: a real bug (an attribute value silently failing to write
   because it lived in a ROM-resident byte instead of RAM) was found
   via a memory dump and fixed — colours now genuinely apply. **`OVER
   <n>`** is stored and validated the same way but doesn't affect
   drawing yet (documented gap — needs a new XOR-plotting
   `kernel/graphics` routine). `NEW`/cold boot now reset text-attribute
   state the same way they already reset `BORDER`. **`AT <row>,<col>` /
   `TAB <col>`** now position the next `PRINT` — row clamps to 0-23,
   column masks to 0-31 — but only for the one `PRINT` that immediately
   follows; the next line resets back to column 0 automatically. Shares
   the now-fixed `PRINT` output path but not yet specifically retested.
   **`LIST`, `EDIT <label>`, `DELETE <start>,<end>`** — three new
   immediate commands (typed and committed like `RUN`/`NEW`, not
   program statements). `LIST` jumps the editor view to the top of the
   program; `EDIT <label>` jumps straight to that label's line
   (rebuilding the label table first, so it works even before the
   program's ever been run); `DELETE <start>,<end>` removes a range of
   statements by 1-based line number, matching how a listing reads top
   to bottom (the first line is `1`) — there are still no line numbers
   stored anywhere, this is purely how the range is typed.
   Any malformed `DELETE`/`EDIT` input, or a typed `0`, leaves the
   program unchanged.
   **User-confirmed both `EDIT`/`DELETE` didn't work at all — four
   real bugs found and fixed across the two, each a different kind**
   (full writeup in `docs/programmers_reference.md`). `EDIT` had two:
   it silently looked up the wrong label name (a shared scratch
   buffer getting overwritten underneath it), then still failed after
   that fix because a length value didn't survive a call that
   destroys registers. `DELETE` had two more: first a genuine build
   failure (`JR Target out of range` — `jr` → `jp` fixed it), then
   once it could compile, its "nothing else should follow" check
   compared against the wrong terminator byte (copied from a routine
   that reads different, already-tokenized text) — fixed, and a
   memory dump confirmed the underlying delete itself was always
   correct, but the SCREEN kept showing stale content afterward
   (`DELETE` never told the redraw system a structural change had
   happened, unlike `NEW`/`RUN`/`HELP`, which all do) — fixed with
   one missing `BASIC_RESET_ROW_SHADOW` call. **User-confirmed
   `EDIT <label>` now works correctly, and `DELETE`'s redraw fix also
   worked** — the next report ("still deletes the wrong line") turned
   out to be the screen correctly showing a 0-based deletion, not a
   redraw problem at all. That surfaced a fifth issue, a design one
   rather than a bug: `DELETE` counted from 0, matching this project's
   internal indexing exactly as designed, but not how anyone reading a
   listing top to bottom expects — **changed to 1-based** (the first
   line is `1`), narrowly, only in how `DELETE`'s own typed numbers are
   interpreted; everything else in the project still addresses
   statements 0-based internally, unchanged. **User-confirmed working.**
   A rejected `DELETE` now shows **"INVALID RANGE"** in the status bar
   for one redraw (user-requested — silently falling through to
   `SYNTAX ERROR` on the next `RUN` wasn't enough feedback), rather
   than persisting the way the existing error-count message does,
   since there's nothing ongoing left to warn about once the bad text
   is already gone.
   **User found a real bug affecting all six immediate commands**
   (`RUN`/`NEW`/`HELP`/`LIST`/`EDIT`/`DELETE`): navigating to an
   *existing* line and editing its text to read something like
   `DELETE 3,3` would EXECUTE it as a command instead of committing
   the edit — the original stored text was never replaced at all
   (found via memory dump). Fixed with one guard, ahead of the whole
   dispatch chain: immediate commands are now only ever recognized
   when composing a genuinely new line (the sentinel/append position),
   never while editing an existing statement — which now always just
   replaces its text, full stop, no matter what the edited text
   happens to read. **User confirmed this is the intended behavior**
   going forward, rather than reopening the ambiguity by letting an
   edited-back-to-valid rejected command re-execute.
   **A rejected command's text now auto-removes itself once the
   cursor moves on** (user-requested follow-up to "INVALID RANGE"
   above) — the text stays visible long enough to read the error, then
   `UP`/`DOWN`/any navigation silently deletes it before moving,
   rather than it becoming a permanent stored line. Typing further new
   lines or pressing `RUN` without navigating first doesn't trigger
   this yet — the line stays pending until an actual navigation
   happens (a stated scope limit, not a bug).
   **`MERGE` was not built** — `LOAD` now exists (see the SAVE/LOAD
   work merged in from a separate conversation, `docs/
   programmers_reference.md`'s kernel/storage section), but it
   replaces the current program outright rather than merging into it;
   `MERGE` itself remains a genuinely separate, unbuilt command.

   **Statement separator (`:`), the last item from this session's
   original list.** `x=1: y=2: PRINT x+y` runs all three on one line.
   Rather than teach every individual statement handler to track where
   it stopped parsing, a line is pre-split into colon-separated
   segments, each fed to the existing, completely unmodified statement
   dispatch as if it were its own standalone statement — no changes
   needed to any individual `PRINT`/`INPUT`/`GOTO`/etc. handler. A `:`
   inside a quoted string or after `REM` is just text, never a real
   separator. Empty statements (`PRINT 1::PRINT 2`, `PRINT 1:`) are
   silently allowed, matching classic BASIC. Also now works inside
   single-line `IF`'s `THEN` branch: `IF x THEN a=1: b=2` runs both.
   **Labels cannot share a line with other statements** — `loop:` must
   still be the entire line by itself, a deliberate scope decision
   that keeps this feature's risk to `GOTO`/labels at zero (verified
   by construction: the label-recognition code path is completely
   untouched by this feature, not just tested). Live keyword bolding
   also only checks the very start of a line — `GOTO` after a colon
   won't render bold, though it executes correctly; purely cosmetic.

   **This delivery is a merge of two separate, parallel conversations**
   — one building this statement-separator feature, the other
   rebuilding SAVE/LOAD from scratch (see `docs/programmers_
   reference.md`'s kernel/storage section for that work's own history).
   Both branched from the same starting point and independently added
   new sysvars in the same free address range; reconciled with a full
   from-scratch overlap check (every sysvar in the merged file, not
   just the ones either side touched) rather than a mechanical file
   diff — see `include/sysvars.inc`'s own `PROG_AREA_START` comment for
   the exact reconciliation. This statement-separator code itself is
   untested against a real build (verified via Python simulation and
   static analysis only, same as always before first real use); the
   SAVE/LOAD side has its own, separately-confirmed test history.

   **The navigation/delete/insert work was the largest, most
   interdependent set of changes made to this project so far** —
   genuinely higher risk of a bug surfacing in testing than the
   smaller, individually-verified pieces around it. Expression
   evaluation, labels/GOTO, and single-error runtime reporting are all
   confirmed working now, including three real bugs found and fixed
   along the way: `RUN`'s output row had no bounds check (corrupting
   the screen past row 23), the error display itself read a message
   pointer AFTER a call that clobbers it (garbage instead of the
   intended message), and `GOTO` permanently rewrote its own label
   reference in the STORED PROGRAM the first time it ran. Building
   labels/GOTO also surfaced a real, pre-existing bug unrelated to any
   of that: `BASIC_MATCH_KEYWORD` had no boundary check at all, so a
   label named `goto` would have been mistaken for the `GOTO` keyword —
   fixed with `BASIC_MATCH_KEYWORD_BOUNDARY`, applied to all five
   recognized keywords, not just the new one. The static check pass is
   the newest piece and hasn't been run at all yet — it reuses the
   exact same validation logic the confirmed-working single-error path
   already uses, and both outcomes were hand-traced against the final
   code, but that's not a substitute for testing on hardware.

   **Error display now shows in the status bar, with red-highlighted
   error lines on top of it — both confirmed working.** `"N ERRORS
   FOUND"` shows in the status bar rather than taking over the whole
   screen — this replaced an earlier full-screen version after direct
   feedback, specifically so the whole program stays visible while
   browsing it. Every failing line renders with red ink (`GFX_SET_ATTR`,
   new — sets a cell's color outright, unlike the existing swap-based
   routines), not just the first one found; this needed genuinely more
   sysvar room than was available, so `PROG_AREA_START` itself moved
   later (verified safe first — every reference to it in the codebase
   uses the symbolic constant, never a hardcoded address). Confirming
   this on real hardware surfaced a real bug — the red-coloring loop
   never saved `HL` (the statement position) across 32 calls to
   `GFX_SET_ATTR`, which destroys it, so the render died after the
   first flagged line and coloring became inconsistent across redraws.
   This project's own recurring register-survival mistake, made again
   in code written after that exact lesson was already documented —
   fixed with one save/restore, then confirmed correct with a clean,
   controlled test sequence.

   **`SYMBOL SHIFT+A`/`SYMBOL SHIFT+S` error navigation is confirmed
   working**, after a genuinely difficult debugging arc. The first
   several rounds of testing were chasing a bug that turned out not to
   exist at all — a stray global label had silently broken
   `sjasmplus`'s local-label scoping, so the feature had never actually
   assembled into any binary being tested; every symptom investigated
   up to that point was against stale, unrelated code. Once fixed and
   genuinely running, a second real bug surfaced: `MEM_LINE_NEXT`
   destroys `DE` per its own documented contract (this project's own
   previously-documented register-survival lesson), but a loop restored
   its index counter from the stack *before* calling it rather than
   after, silently corrupting the count. Found via a diagnostic build
   that printed the actual runtime values on screen — several rounds of
   hand-tracing had missed it by repeating the same unstated assumption
   each time. **The status bar now also shows the specific message for
   whichever flagged line the cursor is on** (`LABEL NOT FOUND`,
   `SYNTAX ERROR`, etc.), not just the overall count — recomputed
   on-demand for just that one statement rather than stored alongside
   every entry in the error list, since the validation routine is
   already fully side-effect-free. Still planned, not yet built: running
   this same check automatically on every commit (`ENTER`), not just
   at `RUN`.

   **Screen-flicker fix — built, one confirmed round of real bugs
   already found and fixed from the user's own testing.** The user
   proposed a separate "display subsystem" module first; discussed
   honestly rather than built outright — most of its stated benefits
   (centralized rendering, no duplicated screen code) were already true
   via `kernel/graphics`, and the one genuinely new piece (reduced
   flicker) didn't actually need a new module, just real diffing logic.
   `BASIC_REDRAW_PROGRAM` no longer starts with an unconditional
   `GFX_CLS` + full re-render on every keystroke — a new shadow state
   tracks what was shown at each row last time (statement position +
   error-flag), so a settled row that hasn't changed is skipped
   entirely, while a changed row is cleared individually
   (`GFX_CLEAR_ROW`, new) rather than the whole screen. The actively-
   edited line always redraws (its content changes every keystroke,
   nothing to diff), and a cleanup pass handles rows left over from a
   longer previous redraw (e.g. after deleting a statement). Needed
   `PROG_AREA_START` to move again to fit the new state (`$6030` →
   `$6090`), re-verified safe the same way as every previous move.

   The very first real test — a screenshot of a black screen with just
   one gray bar at the top on cold boot — surfaced two real bugs at
   once, both the same underlying mistake in two places: removing the
   per-redraw `GFX_CLS` meant nothing established the normal background
   for rows the render loop never actually touches (almost the entire
   screen, at cold boot with an empty program), and separately,
   `BASIC_RUN`'s own unconditional `GFX_CLS` for program output never
   told the shadow state that had happened, so returning to the editor
   afterward skipped redrawing rows that clear had just wiped blank.
   Both fixed with `BASIC_RESET_ROW_SHADOW`, called once at cold boot
   and once right after `BASIC_RUN`'s own clear.
7. Current expansion candidates: a user-facing program search command,
   procedures/functions, and the remaining structured-control forms.
   `IF`, `GOSUB`, `FOR`, graphics, sound, sprites, strings, arrays, and
   commit-time whole-program checking are implemented; use the manuals'
   current feature matrix rather than this historical build order as a
   live todo list.

**`kernel/bank` (EXROM paging trampoline) and the RST $28 calculator
engine** — previously undocumented here; see `docs/
programmers_reference.md`'s new "kernel/bank + the EXROM calculator
engine" section for the full writeup, this is just the status summary.
`kernel/bank` pages a second 8K ROM image (EXROM, `rom/exrom_build.asm`
→ `exrom.bin`) into chunk 6 — **hardware-confirmed** (`rom/
test_exrom_isolation.asm`, PASS/PASS), the first bank-switching code in
this project. `rom/exrom_calc.asm` is a rework (not a byte-for-byte
port) of the real Spectrum ROM's floating-point calculator, EXROM-
resident. Implemented `CALC_TABLE` ops: exchange/delete/duplicate/
end-calc (built, Python/`z80sim`-verified, smoke tests exist but not
yet run against real hardware) and **add/subtract/multiply/divide**,
all four **hardware/Fuse-confirmed** (`rom/test_calc_smoke_
arithmetic.asm` and `rom/test_calc_smoke_division.asm`, both green).
Division (added 2026-08-21) was the last of the four basic arithmetic
ops — same 32-bit shift-and-subtract shape as `kernel/math`'s
`MATH_UDIV16`, scaled up, with a pre-shift step that avoids needing
`CALC_OP_MUL`'s post-loop renormalization branch. **Wired into
`basic/`**, but only partway: `/` (division) routes through this
engine (`BASIC_EVAL_TERM`'s `.divide_ok`) and truncates back to an int
immediately, same behavior as the `kernel/math` divide it replaced —
`+ - *` still use plain register ops / `MATH_MULTIPLY16` directly, and
every BASIC value is still a 16-bit int end to end (see the next
paragraph for where a REAL fractional result finally surfaces).

**"Function-result float" (2026-08-22)** — the calculator engine's
actual payoff: `SQR` and the new `SIN` (this dialect's first
transcendental function) now compute a true float result and can
`PRINT` it with real decimal digits, while every other keyword —
variables, literals, comparisons, `FOR`/`NEXT`, and every OTHER
function — stays plain-int, so this didn't need to touch BASIC's
numeric model at all. Concretely: `SQR`/`SIN` still return a truncated
int through the normal HL/DE pipeline for composition (`x = SQR(2)+1`
still adds 1 to a truncated `1`), but if the ENTIRE printed expression
is exactly one bare `SQR(...)`/`SIN(...)` call, `PRINT` shows its true
fractional value instead (`PRINT SQR(2)` → `1.4142`). `FUNC_RESULT_
IS_FLOAT`/`FUNC_RESULT_FLOAT`/`FUNC_RESULT_FLOAT_NEGATIVE` (include/
sysvars.inc) are how a function call tells `BASIC_STMT_PRINT` that;
cleared at every `+ - * /` combine step and unary minus so composing
with a float-producing call falls back to its plain truncated int, the
same "integer core" the project's own scale (~1.3KB Home ROM headroom
at the time) needed.

`SIN` takes **degrees**, not radians — a deliberate deviation from
real Sinclair BASIC, since this dialect has no float literal syntax at
all, so an integer number of radians would almost never land near a
recognizable angle. Computed via a 5-term Maclaurin series after
folding the argument down to a `[0,90]` reference angle (`sin(x+180)
=-sin(x)`, `sin(180-x)=sin(x)`) — verified in Python across every
integer degree in `[-720,720]` (worst-case error ~3.5e-6, safely under
what `BASIC_FLOAT_TO_STRING`'s 4 displayed fractional digits can show).
`SQR`'s own float path refines `MATH_SQRT16`'s `floor(sqrt(n))` with 4
Newton-Raphson iterations in float space. Both **hardware/Fuse-
confirmed** (`rom/test_sqr_sin_visual.asm` — calls both routines
directly with known arguments and prints each result so the digits can
be read by eye/screenshot, plus a `PRINT SQR(2)`/`PRINT SIN(30)`/
`PRINT SIN(45)+1` check that goes through the real `BASIC_STMT_PRINT`
statement, not just the two routines directly — the last case
confirming composition really does fall back to a plain int). Two real
bugs were caught by that harness before this shipped: `SIN`'s odd/even
term-sign selection was inverted (an unrelated-looking loop-counter-
vs-iteration-number mixup — see `BASIC_SIN_FLOAT`'s own header), and
`SQR`'s `n<=0` shortcut left `FUNC_RESULT_FLOAT`'s mantissa bytes as
whatever a PREVIOUS call had left there (only the packed float format's
"small-int-form marker" byte was zeroed, not the value bytes that
marker's own meaning still depends on).

Every other existing keyword was reviewed against this same "should
this be float?" question and left alone, on purpose: `ABS`/`SGN`/`INT`
are exact by definition regardless of numeric type; `MOD`/`DIV` are
genuinely integer operations (floor division/remainder); `RND`/`POINT`
already return small exact integers with no fractional meaning. `SQR`
was the one existing keyword whose INTEGER answer was actually wrong
most of the time (`SQR(2)` returning `1`, not an approximation of
`1.4142`) — the concrete case this whole feature exists for.

## Testing Milestone 0


```
sjasmplus rom/main.asm
fuse --machine ts2068 --rom-ts2068-0 rom0.bin --rom-ts2068-1 <any 8K file>
```

Expect the border to cycle through all 8 colours. `--rom-ts2068-1` doesn't
matter yet — nothing in Milestone 0 uses the Exrom bank — any 8K file
(even all zeros) works as a placeholder. If the border doesn't cycle, the
bug is in `rom/main.asm`'s vector table or stack init, not in anything
built later, since this milestone has no other dependencies.

## Testing kernel/memory

```
sjasmplus rom/test_memory.asm
fuse --machine ts2068 --rom-ts2068-0 test_memory.bin --rom-ts2068-1 rom1.bin
```

Expect the border to turn **green** and stay there. **Red** means a test
failed — `rom/test_memory.asm` now covers every public routine in
`kernel/memory`: `MEM_INIT`, `MEM_FILL_ZERO`/`MEM_FILL`, `MEM_LINE_FIRST`,
`MEM_SHIFT_UP`/`MEM_SHIFT_DOWN`, a two-label add/lookup/remove round trip,
multi-statement `MEM_LINE_STORE`/`MEM_LINE_DELETE_RANGE` tests, and now
`TEST_MEM_LINE_STORE_EMPTY` — a regression test for the most significant
bug caught in this project so far (storing into a genuinely empty
program read uninitialized RAM as a fake "old statement length" and
corrupted memory; see `docs/programmers_reference.md`'s kernel/memory
section for the full story). This is a separate binary from Milestone
0's `rom0.bin` on purpose, so a failure here can't be confused with a
Milestone 0 regression.

**Note on this test file's own history**: its first draft had a real bug
— a mutable test buffer was declared as `DS`-reserved space inside the
ROM image rather than a RAM address, so writes to it silently failed and
the affected test passed for the wrong reason (see
`docs/programmers_reference.md`'s "Testing gotcha" note). Fixed by moving
all mutable scratch buffers to RAM addresses; worth remembering for any
future test file in this project.

## Testing kernel/math

```
sjasmplus rom/test_math.asm
fuse --machine ts2068 --rom-ts2068-0 test_math.bin --rom-ts2068-1 rom1.bin
```

Same green/red border signal as every other kernel-module test.
Covers `MATH_MULTIPLY16` and `MATH_DIVIDE16` against positive×positive,
negative×positive, negative×negative, zero, a boundary case
(`32767 * 1`), truncating division toward zero (`-17/5 = -3`, not the
floor-division `-4`), and divide-by-zero (returns `0` rather than the
raw algorithm's nonsense `-1`). A representative set, not
exhaustive — the underlying shift-and-add/shift-and-subtract
algorithms were already verified against tens of thousands of cases
via a Python simulation before any Z80 code was written (see
`docs/programmers_reference.md`'s kernel/math section); this test
exists to confirm the actual assembled code matches that verified
design, not to re-verify the algorithm itself.

## Testing rom/exrom_calc.asm (calculator engine)

The calculator is EXROM-resident, so every calculator test builds
**two** binaries and runs them together:

```
sjasmplus rom/test_calc_smoke_arithmetic.asm
sjasmplus rom/exrom_build.asm
fuse --machine ts2068 --rom-ts2068-0 test_calc_smoke_arithmetic.bin --rom-ts2068-1 exrom.bin
```

Same green/red border signal as every other smoke test. `rom/
test_calc_smoke_arithmetic.asm` covers `100+250=350` (addition),
`100-250=-150` (subtraction), and `181*181=32761` (multiply, a
near-boundary case — `182*182` wouldn't fit in 16 bits). **Confirmed
green.**

`rom/test_calc_smoke_division.asm` (build/run the same way, swapping
the Home binary name) covers `32761/181=181` — the exact inverse of
the multiply test's own case, exercising the "preshift" branch (the
result decodes to byte-identical bytes as encoding `181` directly, not
just a numerically-close value) — and `1/3=0.333...`, a genuinely
repeating fraction exercising the non-preshift branch and the full
32-iteration shift-subtract loop. **Confirmed green** — but only after
a real bug in the test itself, worth recording: the first draft's
expected byte for the `1/3` case was computed via Python's `round()`
on the true value rather than by running the same truncating
simulation the Z80 code implements, so it was off by one in the last
byte. `CALC_OP_DIV` truncates toward zero, same as `kernel/math`'s
`MATH_DIVIDE16` — it doesn't round, and `1/3`'s binary expansion rounds
up at the bit truncation lands on. Caught because the real Fuse run
came back RED on the combined test while the exact-result case (no
rounding ambiguity) passed GREEN in isolation via `rom/
test_calc_div_debug.asm` — a per-byte diagnostic (distinct border color
per compared result byte) built specifically to bisect a border-color-
only failure down to which byte disagreed, since there's no other
output channel available for a Z80 program running under Fuse. Kept
around (not deleted) as a worked example of that technique for the
next time this happens.

`rom/test_calc_smoke_stackops.asm` (exchange/delete),
`rom/test_calc_smoke_dupoverflow.asm` (duplicate + the 8-slot overflow
path), `rom/test_calc_smoke_endcalc.asm` (end-calc round trip), and
`rom/test_calc_smoke_unimpl.asm` (confirms an unimplemented literal
actually hangs on real hardware, not just in the simulator's model of
it) all exist and assemble clean but — per their own file headers —
haven't been run against real hardware/Fuse yet, only against
`tools/z80sim`'s simulation. Worth running before trusting those ops
the same way add/subtract/multiply/divide are now trusted.

## Testing SQR/SIN's "function-result float" wiring

```
sjasmplus rom/test_sqr_sin_visual.asm
sjasmplus rom/exrom_build.asm
fuse --machine ts2068 --rom-ts2068-0 test_sqr_sin_visual.bin --rom-ts2068-1 exrom.bin
```

Not a green/red border test — border turns green once every row has
printed, but the harness doesn't itself judge correctness (a byte-exact
expected-value table would need replicating this algorithm's own
32-bit-mantissa rounding path in Python first, the exact mistake `rom/
test_calc_smoke_division.asm` already caught once — see docs/
programmers_reference.md's own writeup on this feature for the two
real bugs an earlier, wrong byte-exact attempt would have masked
either way). Instead it calls `BASIC_SQR_FLOAT`/`BASIC_SIN_FLOAT`
directly with known arguments (`SQR(2)`, `SQR(9)`, `SQR(0)`, `SQR(-5)`,
`SIN` at `0/30/45/90/180/-30/-90/270`) and prints each result, one per
row, plus three cases through the REAL `BASIC_STMT_PRINT` statement
(`PRINT SQR(2)`, `PRINT SIN(30)`, `PRINT SIN(45)+1`) to confirm the
actual PRINT-time hook, not just the two routines in isolation. Expect:
```
1.4142
3.0000
0.0000
0.4999
0.7071
1.0000
0.0000
-0.4999
-1.0000
-1.0000
0.0000
0.0000
1.4142
0.4999
1
```
(`0.4999` instead of the "nicer" `0.5000` for `SIN(30)`/`SIN(-30)` is
truncation showing a true float result landing infinitesimally under
the round value, not a bug — this project's own established convention
truncates rather than rounds everywhere else too.) The final `1` (not
`1.xxxx`) confirms `PRINT SIN(45)+1` correctly falls back to a plain
truncated int once composed with `+`, rather than showing the bare
call's own fractional value.

## Diagnostic: rom/test_nav_hook_debug.asm

```
sjasmplus rom/test_nav_hook_debug.asm
fuse --machine ts2068 --rom-ts2068-0 test_nav_hook_debug.bin --rom-ts2068-1 rom1.bin
```

Combines border-color dispatch tracing with a live state overlay: uses
`rom/editor_navdebug_copy.asm` (border markers + a loop-alive hex
counter around the `UP`/`DOWN` dispatch) in place of the real
`kernel/editor/editor.asm`, AND shows `CUR_EDIT_POS`/`CUR_EDIT_INDEX`
as hex at the bottom of the screen on top of the real
`BASIC_REDRAW_PROGRAM` rendering. Red → yellow → cyan → green traces
how far the dispatch gets; the bottom two rows show whether navigation
state is actually changing when you press `UP`/`DOWN`, independent of
whether the screen visibly looks different.

## Diagnostic: rom/test_basic_nav_debug.asm

```
sjasmplus rom/test_basic_nav_debug.asm
fuse --machine ts2068 --rom-ts2068-0 test_basic_nav_debug.bin --rom-ts2068-1 rom1.bin
```

Same workflow as `test_basic.asm` (calls the real `BASIC_REDRAW_PROGRAM`,
so you see identical rendering), but overlays navigation state as hex
at the bottom four rows: `P=` (`CUR_EDIT_POS`), `I=` (`CUR_EDIT_INDEX`),
`T=` (`VIEW_TOP_INDEX`), `E=` (`PROG_END`). Built to diagnose reports
of committed lines seeming to vanish and `UP` not showing existing text.

## Diagnostic: rom/test_basic_debug.asm

```
sjasmplus rom/test_basic_debug.asm
fuse --machine ts2068 --rom-ts2068-0 test_basic_debug.bin --rom-ts2068-1 rom1.bin
```

Same REPL workflow as `test_basic.asm`, but shows `VAR_TABLE`'s raw
stored value for variable `X` as 4 hex digits at row 20 after every
`RUN` — independent of whatever `PRINT` did or didn't display at row 0.
Built to answer a specific question: after `x=5` then `RUN`, does row
20 read `0005`? If yes, the bug is in `PRINT`'s display path, not
storage. If no, storage itself is still wrong.

## Diagnostic: rom/test_editor_debug.asm

```
sjasmplus rom/test_editor_debug.asm
fuse --machine ts2068 --rom-ts2068-0 test_editor_debug.bin --rom-ts2068-1 rom1.bin
```

Not a feature test — shows the raw key code, cursor offset, and
content length numerically (rows 2-4, hex) alongside the normally-
rendered line (row 0), updated after every keypress. Built to diagnose
a specific reported display issue where punctuation characters appear
visually offset from where they're typed. Type slowly, one character
at a time, and note the three hex values after each keypress.

## Diagnostic: rom/test_keycode.asm

```
sjasmplus rom/test_keycode.asm
fuse --machine ts2068 --rom-ts2068-0 test_keycode.bin --rom-ts2068-1 rom1.bin
```

Not a feature test — shows the exact hex code `IO_READ_KEY` returns for
each keypress, live on screen. Useful when a key seems to do nothing or
the wrong thing in another test, to see whether detection itself is
working before assuming where the bug is. Reference values are in the
file's own header comment.

## Testing basic/

```
sjasmplus rom/test_basic.asm
fuse --machine ts2068 --rom-ts2068-0 test_basic.bin --rom-ts2068-1 rom1.bin
```

**Interactive, `REPL`-style, now genuinely multi-statement** — type a
line, press ENTER (appended to the growing program — displayed
immediately below, bold where a keyword was recognized), type `RUN` on
its own, press ENTER (executes the WHOLE program so far and pauses on
the output — press any key to continue to the next command). Try,
across separate ENTER presses:
```
x = 5
PRINT x
RUN            (shows "5" — stays on screen until you press a key)
```
That's two statements accumulated and run together — try adding more:
```
PRINT "HELLO"
RUN            (now runs all three statements in order)
```
Typing a recognized keyword in lowercase (`print`, `input`, `run`,
`end`, `stop`) flips it to bold uppercase the moment you finish typing
it (space, `=`, or ENTER right after) — try typing `print x` and watch
it become `PRINT x` in bold as you type the space. This only happens
once a line is committed, not while you're still typing it — the
actively-edited line always shows plain until ENTER. `INPUT` still
works the same way as before, just as one more line in the growing
program:
```
INPUT y
PRINT y
RUN            (prompts for a number, then shows it)
```

**Arithmetic expressions** — assignment and `PRINT` both take full
expressions now, not just a bare literal or variable: `+ - * /`, unary
minus, and parentheses, with normal precedence (`*`/`/` bind tighter
than `+`/`-`). Try:
```
x = 3 + 4 * 2
PRINT x        (shows "11" — confirms * binds tighter than +)
y = (x + 1) * 2
PRINT y          (shows "24")
x = x + 1
PRINT x            (shows "12" — self-referential assignment reads the
                    OLD x before storing the NEW one)
```

**Labels and GOTO** — a label is a statement that's entirely a bare
name followed by `:`, nothing else on that line; both label names and
GOTO references are case-insensitive. Try:
```
x = 1
loop:
PRINT x
x = x + 1
GOTO loop
RUN                 (prints 1, 2, 3, ... forever — no way to stop it
                    short of resetting: this program has no condition
                    to break on. This is deliberately an infinite
                    loop, to confirm GOTO actually jumps backward
                    repeatedly. The screen clears and restarts from
                    the top every 24 lines — RUN's output has no true
                    scrolling, so this is the safe way it handles
                    running past the bottom of the screen, not a bug)
```

**IF/ELSEIF/ELSE/END IF** — structured conditionals, block form and a
single-line short form, `= <> < > <= >=` plus `AND`/`OR`/`NOT`
(remember: no short-circuiting — both sides of `AND`/`OR` always
evaluate). Try the block form, nested:
```
x = 7
IF x > 5 THEN
IF x > 10 THEN
PRINT 100
ELSE
PRINT 1
END IF
ELSE
PRINT 2
END IF
RUN                 (shows "1" — outer branch taken (7>5), inner
                    branch's condition false (7 is not >10), so its
                    ELSE runs instead)
```
Try an ELSEIF chain:
```
x = 2
IF x = 1 THEN
PRINT 111
ELSEIF x = 2 THEN
PRINT 222
ELSE
PRINT 999
END IF
RUN                 (shows "222" — only the matching branch runs)
```
Try the single-line short form (no END IF needed at all):
```
x = 5
IF x = 5 THEN PRINT x
IF x = 9 THEN PRINT 999
RUN                 (shows "5" only — the second line's condition is
                    false, so nothing prints for it, and execution
                    just continues to whatever comes after)
```
Try AND/OR/NOT:
```
x = 5
IF x > 0 AND x < 10 THEN PRINT 1
IF x < 0 OR x > 100 THEN PRINT 2
IF NOT x = 0 THEN PRINT 3
RUN                 (shows "1" then "3" — the OR line's condition is
                    false, so it's skipped)
```
Try the infinite-loop example above again, now with a real way to stop
it:
```
x = 1
loop:
PRINT x
x = x + 1
IF x > 5 THEN
END
END IF
GOTO loop
RUN                 (prints 1, 2, 3, 4, 5, then stops on its own —
                    confirms IF can finally give a GOTO loop a real
                    exit condition)
```
Try the new error: an unterminated block.
```
IF x = 1 THEN
PRINT x
RUN                 (shows "IF WITHOUT END IF" — the static checker
                    doesn't catch this ahead of time, since verifying
                    whole-program IF/END IF balance is outside what
                    it's designed to do; this is caught at RUN time
                    instead, when the resolver's own forward scan
                    runs off the end of the program looking for a
                    match)
```

**Error reporting** — runtime errors now show a message plus the
failing statement's text, then stop, instead of silently doing
nothing. Try each as its own single-statement program:
```
GOTO nowhere    RUN   (shows "LABEL NOT FOUND" + "GOTO nowhere")
x = 5 / 0        RUN   (shows "DIVISION BY ZERO" + "x = 5 / 0")
qqq               RUN   (shows "SYNTAX ERROR" + "qqq" — not a keyword,
                        not an assignment, not a label)
```
A genuine label (`loop:`) should never trigger any of these — it's the
one case that looks similarly "unrecognized" but is actually valid,
and needed its own check (`BASIC_IS_LABEL_DEFINITION`) to keep working
correctly once the fallback started reporting real errors.

**Whole-program check pass** — before any of that even runs, every
statement gets checked first. Try a program with more than one
problem:
```
GOTO nowhere
qqq
RUN                (goes straight back to the editor view — no wait,
                   nothing was run — showing both lines you typed,
                   with the status bar at the bottom reading
                   "2 ERRORS FOUND" instead of the usual "LINE n/m";
                   this is deliberately NOT a full-screen message, so
                   you can browse the whole program while it's shown.
                   BOTH lines should also show in RED ink now — not
                   just the first one found — with any recognized
                   keyword within them staying bold, same as always,
                   just bold-red instead of bold-black)
```
The message stays in the status bar as you navigate UP/DOWN — it only
clears once you commit a change (ENTER), since a fresh edit means the
old check result may no longer apply. The red highlighting clears the
same way — fix one of the two lines and commit it, and only the
remaining broken line should still show red. Not exhaustive —
`PRINT x/y` can't be statically flagged as division by zero unless `y`
happens to be a literal `0`, since a static pass has no way to know
what a variable will hold without actually running the program. The
single-error runtime checks above still catch that case once real
execution reaches it.

**Error navigation** (confirmed working) — with the two errors above
still showing, try:
```
SYMBOL SHIFT+A   (jumps to "GOTO nowhere" — press again: wraps to
                 "qqq"; press again: wraps back to "GOTO nowhere")
SYMBOL SHIFT+S   (same, in reverse — try it from either line)
```
Lands you directly on each flagged line, cycling between just the two
errors regardless of where else in the program you start from or how
many other (valid) lines sit in between.

**Per-line error messages** — the status bar now shows the SPECIFIC
message for whichever flagged line the cursor is on, not just the
overall count: landing on "GOTO nowhere" shows `LABEL NOT FOUND`,
landing on "qqq" shows `SYNTAX ERROR`, and moving off both (e.g. back
to the sentinel) reverts to the generic `2 ERRORS FOUND`.

**Screen-flicker fix** — hard to verify precisely on an emulator
running at full speed, but worth a general check: type several lines,
navigate around with UP/DOWN, and confirm nothing *looks* wrong —
lines shouldn't flash, disappear momentarily, or show stray leftover
characters. A more concrete test: build up a multi-line program, then
delete lines from the middle or end (navigate to an existing line,
clear it, DELETE) and confirm no stray text lingers where a deleted
line used to be — that's exactly the case the leftover-rows cleanup
exists for.

**A real bug found and fixed (2026-08-21, user-reported): a program
consisting of just one `PRINT` statement looked like it wasn't running
at all** — `RUN` appeared to silently return straight to the program
listing with no output shown, while the exact same `PRINT` inside a
`FOR`/`NEXT` loop worked fine. Root cause: `BASIC_WAIT_FOR_KEY` (the
press-any-key pause after `RUN`, itself the fix for an earlier, related
bug — see `docs/programmers_reference.md`'s "Bugs caught before
shipping" section) didn't check that the key it saw down was a *new*
press. A single `PRINT` executes in a fraction of a millisecond — far
faster than a human can release a key — so the very same ENTER
keystroke that had just committed `RUN` was still physically held down
when `BASIC_WAIT_FOR_KEY` started checking, satisfying the wait
instantly and then releasing (clearing the screen) a moment later,
long before there was any real chance to read the output. A `FOR`/
`NEXT` loop simply runs long enough that ENTER is already released by
the time it finishes, which is why that case worked and masked the
bug. Diagnosed with two fully-automated boot-time diagnostics (no
typing needed — `rom/test_print_repro_debug.asm` and `rom/
test_print_repro_interactive.asm`) that proved the checker, `BASIC_RUN`,
and the real commit path were all already correct, narrowing the cause
down to real keyboard timing, which neither of those harnesses
exercised. Fixed by having `BASIC_WAIT_FOR_KEY` flush any already-held
key first. **User-confirmed working.**

**Navigation** — press UP to move into and edit an existing line
(discards any uncommitted typing on the line you're leaving — there's
no undo, so this is deliberate). A status line at the bottom of the
screen (row 23, shown in inverse video) shows `LINE n/m` for whichever
statement you're editing, or `NEW LINE` when you're on the fresh line
at the end — it disappears automatically once you `RUN`, since that's
a completely separate screen. Try:
```
x = 5
PRINT x
RUN            (shows "5")
```
Then press UP twice to land back on `x = 5`, change the `5` to a
different number, press ENTER (commits the change and moves down to
`PRINT x`, same as a normal text editor), then `RUN` again — the new
value should show. The view scrolls automatically once the program
exceeds 23 lines (one row is reserved for the status line).

**Delete a line** — press `DELETE` while an already-empty EXISTING
line is showing (nothing left to backspace character-by-character) to
remove it outright; everything after it shifts up. No-op on the
new-line sentinel. `CAPS SHIFT+1` does the same thing in one
keystroke, without needing to empty the line first.

**Insert a line** — `CAPS SHIFT+ENTER` inserts a blank line BEFORE the one
currently being edited, and moves you onto it to start typing. No-op
on the sentinel.

A blank ENTER (nothing typed) is a no-op. This navigation/delete/
insert work is the largest, most interdependent set of changes made to
this project so far — worth testing thoroughly, since it's more likely
than usual to have a bug somewhere in it.

For the quote character (and other punctuation), hold **Ctrl** (Fuse's
mapping for SYMBOL SHIFT, confirmed via your own testing against a
stock Spectrum ROM) — see `docs/hardware_notes.md`'s SYMBOL SHIFT table
for the full 22-character set (`!@#$%&'()_:.,=+-;"/*<>`), including `<`
and `>` (Ctrl+R / Ctrl+T) for the new IF feature's relational
operators. (This line previously listed only 18 characters, missing `/`
and `*` — corrected alongside this update.)

**CLS, REM, BORDER** — three new statements. Try:
```
BORDER 2
PRINT "HELLO"
RUN            (border turns red, then "HELLO" prints as usual)
```
Then try CLS mid-program:
```
PRINT "ONE"
CLS
PRINT "TWO"
RUN            ("ONE" flashes onto row 0, CLS wipes it immediately,
               then "TWO" prints at row 0 again — not row 1 — since
               CLS also resets where PRINT thinks it's writing)
```
REM is a comment — anything after it is ignored, whatever it says:
```
REM this line does nothing
PRINT 1
RUN            (shows "1" — the REM line above it never runs anything)
```
A malformed BORDER should behave like any other malformed expression:
```
BORDER
RUN            (shows "SYNTAX ERROR" — BORDER with no value at all is
               the same class of failure as a bad PRINT expression)
```

**NEW** — a second immediate command, alongside RUN. Try:
```
x = 5
PRINT x
NEW            (screen clears to an empty program — press UP: nothing
               to navigate to, confirming the program is really gone,
               not just hidden)
x = 5
PRINT x
RUN            (still shows "5" — NEW zeroed variables too, so this
               isn't leftover state from before)
```

**INK, PAPER, FLASH, INVERSE** — set text-attribute state that actually
changes what `PRINT` draws (unlike `BORDER`, which only touches the
screen edge). Try:
```
INK 2
PAPER 5
PRINT "HELLO"
RUN            (HELLO prints with red ink on cyan paper, not the
               default black-on-white)
```
`INVERSE` swaps ink/paper at print time without changing the
underlying `INK`/`PAPER` values:
```
INK 2
PAPER 5
INVERSE 1
PRINT "A"
INVERSE 0
PRINT "B"
RUN            (A prints cyan-on-red — swapped; B prints back to
               red-on-cyan, since INVERSE 0 didn't touch INK/PAPER)
```
`FLASH 1` sets the hardware flash bit on subsequently printed text
(visible on real hardware/Fuse, not distinguishable from a static
screenshot). `OVER 1` XOR-plots subsequent text, so printing the same
glyph twice at the same position restores the original bitmap. `NEW`
resets all five back to defaults (INK 0, PAPER 7,
FLASH/INVERSE/OVER 0):
```
INK 2
NEW
PRINT "HELLO"
RUN            (back to default black-on-white, not leftover red ink)
```

**AT, TAB** — position the next `PRINT`. Try:
```
AT 10,5
PRINT "HELLO"
RUN            (HELLO appears at row 10, column 5 — not the top-left)
```
Positioning only lasts for the one `PRINT` that follows it:
```
AT 10,5
PRINT "A"
PRINT "B"
RUN            (A appears at row 10 col 5; B appears at row 11 col 0
               — the next line resets to the left margin on its own)
```
`TAB` moves the column only, same line:
```
PRINT "X"
AT 5,0
PRINT "Y"
TAB 10
PRINT "Z"
RUN            (Y appears at row 5 col 0; Z appears at row 6 col 10 —
               TAB alone doesn't change the row, but PRINT still
               advances to a new row afterward the same as always)
```
An out-of-range row silently clamps rather than erroring:
```
AT 30,5
PRINT "HELLO"
RUN            (HELLO still appears — at row 23, the last valid row,
               not a SYNTAX ERROR)
```
A malformed AT (missing the comma) behaves like any other malformed
statement:
```
AT 5
RUN            (shows "SYNTAX ERROR")
```

**LIST, EDIT, DELETE** — immediate commands, typed alone and pressed
ENTER, same as `RUN`/`NEW`. Try building a short program, then:
```
LIST           (jumps the view back to the top of the program — handy
               after scrolling or typing your way to the bottom)
```
```
loop:
PRINT "HI"
GOTO loop
EDIT loop      (jumps straight to the "loop:" line, wherever it is —
               no need to scroll/navigate to find it by hand)
```
Delete a range by 1-based line number (the first line typed is line
1, matching how you'd read the listing top to bottom):
```
PRINT "A"
PRINT "B"
PRINT "C"
PRINT "D"
DELETE 2,3     (removes lines B and C — LIST afterward shows just A
               and D)
```
A single line can be deleted the same way with matching numbers
(`DELETE 1,1` deletes just the first line), though CAPS SHIFT+1
remains the faster one-keystroke way to delete whatever line you're
currently on. A typed `0`, or a malformed/out-of-range DELETE, leaves
the program untouched and gets typed in as a (syntactically invalid)
line instead — and now also shows **"INVALID RANGE"** in the status
bar for a moment, right after pressing ENTER:
```
DELETE 0,2     (there's no "line 0" — program unchanged; this text
               itself gets stored as a line, showing SYNTAX ERROR on
               RUN, but status bar briefly shows INVALID RANGE first)
DELETE 5,2     (start > end — same outcome, unchanged + stored as text)
```
Editing an *existing* line to read a command no longer executes it —
it's always just text:
```
PRINT "A"
PRINT "B"
UP             (navigate to the "PRINT "B"" line)
               (edit it in place to read: DELETE 1,1)
RUN            (shows SYNTAX ERROR — DELETE 1,1 was stored as an
               ordinary line, not executed; A and B are both still
               present in the listing above)
```
A freshly-typed rejected command auto-removes itself once you
navigate away, so it never becomes a permanent line at all:
```
PRINT "A"
PRINT "B"
DELETE 5,2     (start > end — INVALID RANGE shows, text stays visible
               on screen for now)
UP             (navigate away — the DELETE 5,2 line silently
               disappears; LIST afterward shows only A and B, never
               DELETE 5,2)
```

**Statement separator (`:`)** — multiple statements on one line:
```
x=1: y=2: PRINT x+y
RUN            (prints 3 — all three statements ran, in order)
```
A `:` inside a string or after REM is just text:
```
PRINT "a:b": PRINT "c"
RUN            (prints "a:b" then "c" on separate lines — the colon
               inside the quotes didn't split anything)
REM this: is one comment: PRINT "never runs"
RUN            (nothing prints — the whole line is one comment,
               colons included)
```
Works inside single-line IF's THEN branch too:
```
IF 1 THEN PRINT "yes": PRINT "both ran"
RUN            (prints both lines — before this feature, only the
               first would have run)
```
A label still can't share a line with anything else:
```
loop: PRINT "hi"
RUN            (shows SYNTAX ERROR on that line — "loop:" combined
               with more text on the same line isn't a valid label)
```

**PEEK / POKE / FREE / USR / PAUSE** (2026-08-22) — raw memory access,
free-space query, machine-code call, and frame-based delay:
```
a = 50000: POKE a,42: PRINT PEEK(a)
RUN            (prints 42 — POKE then PEEK round-trips through the
               same address)
PRINT FREE()
RUN            (prints a plausible free-byte count — grows/shrinks as
               the program itself grows/shrinks, not at runtime from
               variables, which don't affect program-area size)
PAUSE 25: PRINT "half a second later"
RUN            (pauses ~0.5s at 50Hz before printing — PAUSE 0 instead
               waits indefinitely for any keypress)
```
`USR` needs real machine code POKEd in first to be meaningful — see
`docs/programmers_reference.md`'s basic/ section ("PEEK/POKE/FREE/USR/
PAUSE") for a full worked example, plus the real infinite-reboot bug
this project's own bisected preload-harness testing caught in `USR`'s
first draft (an unguarded `USR(addr)` jumping to address 0 during the
whole-program *checker* — not real execution — when `addr`'s variable
hadn't been assigned yet) and the `BASIC_CHECK_ONLY` guard that fixed
it.

**RANDOMISE / PI / RAD / DEG** (2026-08-22) — explicit RNG reseeding
plus three more "function-result float" built-ins alongside `SQR`/`SIN`:
```
RANDOMISE 5: PRINT RND(1000)
RUN            (prints some value 0-999)
RANDOMISE 5: PRINT RND(1000)
RUN            (prints the SAME value as the first run — same seed,
               same first draw; RANDOMISE 0 instead reseeds from real
               hardware entropy, like a cold boot)
PRINT PI()
RUN            (prints 3.1415)
PRINT RAD(90)
RUN            (prints 1.5707 — 90 degrees in radians)
PRINT DEG(1)
RUN            (prints 57.2957 — 1 radian in degrees)
```
Building these caught a real, previously-latent bug in `kernel/bank`'s
EXROM paging (already affecting the shipped `SIN`, just never
triggered before — its own prior testing bypassed the checker
entirely) — see `docs/programmers_reference.md`'s basic/ section ("PI/
RAD/DEG and a real EXROM-paging reentrancy bug") for the full
incident, including a controlled A/B test that confirmed the fix was
actually load-bearing, not just theoretical. Also fixed along the way:
`tools/preload_gen.py`'s harness template was missing the `RST_28`
calculator-engine vector entirely — see that tool's own comment and
"Testing guidelines" below.

### Testing guidelines: bisecting a hang in a headless preload harness

When a `BASIC_RUN`-calling preload harness (see the fuse-screenshot-
capture technique above) hangs and you're not sure why:

- **Test one new keyword at a time first**, not the combined program —
  isolating which specific statement/function is responsible is much
  cheaper than debugging a multi-feature program at once. This is
  exactly how the RST_28/EXROM-paging bugs above were found: PAUSE,
  POKE/PEEK, and FREE each passed cleanly in isolation, which pointed
  straight at USR/SIN/PI as the actual culprits.
- **Add `PRINT "checkpoint"` statements between suspect operations**,
  not just a border-color check — a border color alone only tells you
  pass/fail, while text printed (or not printed) on screen tells you
  exactly how far execution actually got before it derailed. This
  matters specifically because `BASIC_RUN` runs the whole-program
  *checker* before executing anything — a hang during the check phase
  means NONE of the program's statements have run yet, including ones
  that appear earlier in program order than the one actually at fault
  (a checkpoint print at the very top of the program not appearing at
  all is itself a strong clue that the bug is in the check pass, not
  real execution, of some statement further down).
- **Read the screenshot's text directly** for the actual computed
  values, not just border color, whenever the feature under test
  produces output — this project's own vision-capable review of a
  screenshot confirmed `PI()`/`RAD(90)`/`DEG(1)` against independently
  hand-computed expected values (`3.1415`/`1.5707`/`57.2957`), a
  stronger check than a pass/fail border alone.
- **A hang can be in the test harness, not the product** — `tools/
  preload_gen.py`'s own template was missing the `RST_28` vector,
  which looked identical (from a screenshot) to a real infinite loop
  in `SIN`. Before concluding a suspected fix is necessary, confirm it
  with a controlled test: temporarily revert just that fix (keeping
  everything else), rebuild, and re-run the same failing case — if it
  still passes, the fix wasn't the (or the only) cause; if it fails
  again, that's real confirmation, not just a plausible theory.

**ROM-size audit: BASIC_FORMAT_STORAGE_STATUS moved to EXROM**
(2026-08-22) — reclaimed 303 bytes of Home ROM (813 -> 1116 free) by
moving the SAVE/LOAD status-bar text builder into `rom/exrom_
storage.asm`, a cold-path candidate found via a systematic size audit
(measure real routine sizes from the assembler's own listing, don't
guess). See `docs/programmers_reference.md`'s basic/ section ("ROM-
size audit") for the full candidate list, including several
deliberately NOT moved (SIN/SQR/RND — real risk, they use the `RST
$28` literal-op-stream convention; PLOT/LINE/CIRCLE graphics
primitives — bad fit, they run during a user's own program, not just
a rare cold path; the keyboard ISR — chunk 6 was deliberately chosen
to stay distant from interrupt state). Confirmed with a real emulator
`SAVE` end-to-end, since **SAVE/LOAD are immediate-only commands**
(typed directly, not part of `BASIC_EXEC_STATEMENT_CONTENT`'s
dispatch) — they can't be preloaded into program text and RUN like
every other keyword tested in this README; a throwaway harness has to
call `BASIC_DO_SAVE`/`BASIC_DO_LOAD` directly instead, with `HL`
pointing at a hand-built `"filename"` buffer and `STORAGE_PROGRESS_
HOOK` set by hand (normally `BASIC_COMMAND_LOOP`'s own job, which a
`BASIC_RUN`-only harness never calls).

**GOSUB / RETURN / CALL** (2026-08-22) — simplified "stored
procedures": a procedure is just a label you `CALL` instead of
`GOSUB`, no parameters or local variables:
```
A = 0: GOSUB addone: PRINT A
RUN            (prints 1)
GOSUB addone: CALL addone: PRINT A
RUN            (prints 3 — CALL is a second spelling of GOSUB)
RETURN
RUN            (shows "RETURN WITHOUT GOSUB")
addone:
A = A + 1
RETURN
```
**Important — labels and identifiers cannot contain digits or
underscores, letters only** (`A`-`Z`) — this is a genuine, pre-
existing language constraint (`BASIC_PARSE_IDENTIFIER` silently stops
at the first non-letter), not something new to GOSUB. `sub1:` is
parsed as the label `SUB` with a stray `1` left over, which fails
grammar checking in a way that looks like a whole-program check
failure — this cost real debugging time this session before being
traced to the label name itself, not a GOSUB bug. See `docs/
programmers_reference.md`'s basic/ section ("Bare GOSUB / RETURN /
CALL") for the full incident, including a misleading diagnostic
technique to avoid repeating (calling the single-statement checker
directly, in a loop, produces false failures even for known-good
keywords like `GOTO` — always prefer the real `BASIC_RUN` check path
when bisecting) and a real edge case guarded against (`RETURN` when
`GOSUB` was the program's own last statement).

**INKEY$()** (2026-08-22) — non-blocking keypress read, scoped as a
plain integer (this dialect has no strings yet):
```
A = INKEY$()
PRINT A
RUN            (prints 0 — nothing pressed; compare against the
               numeric ASCII code, e.g. IF INKEY$()=81 THEN ... for
               'Q', since there's no IF INKEY$()="Q" without string
               literals in expressions, which don't exist yet)
```

**BEEP / SOUND** (2026-08-22) — both confirmed from the real ROM
disassembly's `BEEPER`/`SOUND` routines. `BEEP <duration>,<pitch>` is
deliberately NOT the real musical-note grammar (no audio output exists
in this environment to verify a note-to-Hz conversion against) — both
parameters are raw integers, `kernel/sound`'s `SOUND_BEEP`. `SOUND
<register>,<data>` IS the authentic command (register 1-16 -> port
`$F5`, data -> port `$F6`), EXROM-resident (`rom/exrom_sound.asm`) to
save Home ROM budget:
```
BORDER 2: BEEP 300,800: BORDER 4
RUN            (green border — runs to completion; can't confirm the
               actual pitch/tone by ear in this environment, only that
               the port-toggle loop completes without hanging)

SOUND 8,15: SOUND 0,120
RUN            (halts with "INVALID SOUND REGISTER" — register 0 is
               out of range; the valid SOUND 8,15 before it already
               ran)
```
See `docs/programmers_reference.md`'s `kernel/sound` section and the
basic/ "BEEP / SOUND" section for the full writeup, including a real
cross-EXROM-boundary bug (an EXROM-resident error-message pointer that
would have been read back after EXROM was already paged out) caught
and fixed before it ever shipped.

**String scalars** (2026-08-22) — `A$`-`Z$`, fixed 31-char slots,
assignment/`PRINT`/`=`/`<>` comparison. Real cost: ~364 bytes Home ROM
(573 -> 209 bytes free) — concatenation and arrays are still in scope
but didn't land in this pass; see the status report to the user for
the real numbers this was gated on.
```
A$ = "HI": B$ = "YO"
IF A$ = B$ THEN GOTO bad
IF A$ <> B$ THEN GOTO good
BORDER 1: STOP
bad: BORDER 3: STOP
good: PRINT A$: BORDER 4: STOP
RUN            (prints "HI", green border)
```
Two real bugs caught before either reached the emulator: `BASIC_EVAL_
STR_PRIMARY` not skipping a leading space before the right-hand operand
(`IF A$ = "HI" THEN` failed the checker outright until fixed), and
`BASIC_STR_ADDR` documented as `Destroys: AF, HL` when it actually also
clobbers `DE` — a caller relying on the wrong contract wrote a copied
variable's content straight into `STR_TABLE` itself instead of the
intended scratch buffer, silently blanking `A$` after any comparison
touched it. Caught by bisecting a real symptom (`rom/test_str7.asm`),
not by re-reading the routine in isolation — see `docs/programmers_
reference.md`'s "String scalars" section for the full incident.

**String concatenation** (2026-08-22) — `A$ + B$`, and longer `+`-
chains, anywhere a string expression is expected. Real cost: ~50 bytes
Home ROM (209 -> 159 bytes free), confirming the ~40-60 byte estimate
made once string scalars' own real cost was known:
```
BORDER 2: A$ = "HI": B$ = A$ + "!"
IF B$ = "HI!" THEN BORDER 4
RUN            (green border)
```
Checker wiring cost zero extra bytes — `rom/exrom_checker.asm`'s
`BASIC_CHECK_STR_ASSIGNMENT` already called into Home via a KTAB slot
for single-primary validation; retargeting that same slot at the new
`BASIC_EVAL_STR_EXPR` (renamed `KTAB_BASIC_EVAL_STR_EXPR`) gives
`+`-chain validation for free, no `KTAB_COUNT`/`KTAB_MAGIC` bump. `rom/
test_concat.asm`/`test_concat2.asm` confirm both a true and a
deliberately-mismatched false case; `rom/test_regr4.asm` confirms plain
numeric `IF` comparisons are unaffected. Only 159 Home ROM bytes remain
— whether either array type (`DIM name(n)`/`DIM name$(n)`) fits at all
is a real open question now, not an estimate.

**SPRITE moved to EXROM** (2026-08-22) — a size audit across `basic/
basic.asm` (real byte sizes computed from the assembler's own listing,
not guessed) found `SPRITE GRAB`/`SHOW`/`HIDE` and their shared helpers
as the best remaining shrink candidate: 587 bytes, genuinely cold
(only exercised if a program actually uses `SPRITE`), and already
almost entirely self-contained — every shared Home primitive it needed
was already in the `KTAB_LIST` jump table for other reasons; only
`GFX_SPRITE_CAPTURE`/`GFX_SPRITE_DRAW` needed new entries. Moved
verbatim into new `rom/exrom_sprite.asm`, behind a thin `BASIC_
SPRITE_EXROM` wrapper, same pattern as SAVE/LOAD/HELP/CALC/SOUND
before it. **Real result: +688 bytes Home ROM free (159 -> 847
bytes)**, at a cost of ~720 EXROM bytes (2408 -> 1691 free, still
ample) — by far the largest single shrink this project has done.
`rom/test_sprite2.asm` confirms `SPRITE GRAB`/`SHOW`/`HIDE` all still
work correctly after the move (green border), not just that it
assembles. See `docs/programmers_reference.md`'s "ROM-size audit:
SPRITE moved to EXROM" section for the full writeup.

**Numeric arrays** (2026-08-22) — `DIM name(n)`, 0-based, dynamic
region (grows after program text, reset each `RUN`), `name(i)` as both
a read and an assignment target:
```
DIM A(5): A(0) = 10: A(3) = 20
PRINT A(0) + A(3)
RUN            (prints 30)
```
Real bug found and fixed: the first draft stashed the array's own
letter in `CUR_VAR_LETTER` — shared scratch `BASIC_TRY_ASSIGNMENT`/
`BASIC_STMT_DIM` also use — which a nested array read while parsing
another statement's own RHS/index/size expression silently clobbers.
Concretely, `B = A(0)` stored into **A's own slot**, not B's: assigning
B stashes `'B'`, then evaluating the RHS `A(0)` overwrites the same
byte with `'A'` before the outer assignment reads it back. Third time
this project has hit this "shared mutable scratch clobbered by a
nested call" bug class (after `FUNC_CALL_ID`/`ARGC` and `DETOK_BUF`),
this time self-inflicted. Fixed by pushing the letter onto the real
stack instead in all three places that need it to survive a recursive
call — confirmed against a genuinely nested case too (`A(B(0)) = 99`).
Cost: ~551 bytes Home ROM (847 -> 290 bytes free), ~114 bytes EXROM
(1691 -> 1577 free). String arrays were added later as fixed 31-character
elements (`DIM A$(n)`) — see
`docs/programmers_reference.md`'s "Numeric arrays" section for the
full writeup, including all three runtime errors (`SUBSCRIPT OUT OF
RANGE`/`ARRAY NOT DIMENSIONED`/`ARRAY ALREADY DIMENSIONED`) verified
in the emulator.

**STICK()** (2026-08-22) — real Sinclair BASIC joystick read,
confirmed from the disassembly's own `STICK`/`READ-STICK` routines:
reads AY-3-8912 register 14 (the same ports `SOUND` already writes
to, this project's first *read* from the chip). `device` is 1 or 2;
device 1 returns a 4-bit direction value, device 2 only a single bit
(confirmed hardware asymmetry). Not verifiable against real joystick
movement in this sandbox — only the plumbing is confirmed (grammar,
port read completes, range-check error fires). Real false-positive bug
found and fixed before shipping: an early draft validated `device`
unconditionally, so a **variable** argument (`N = 1: PRINT STICK(N)`)
was rejected outright by the whole-program checker, which reads
whatever stale value `N`'s `VAR_TABLE` slot already holds (check-time
assignment is deliberately non-mutating) rather than the value the
program actually assigns at runtime. Fixed with the same `BASIC_CHECK_
ONLY` guard `USR`/array-reads already use. See `docs/programmers_
reference.md`'s "STICK()" section for the full writeup.

**String functions** (2026-08-22) — 8 string-returning functions
(`CHR$`/`STR$`/`UPPER$`/`LOWER$`/`LEFT$`/`RIGHT$`, plus `INKEY$`
upgraded from a plain integer to a real string) and 3 number-returning,
string-argument functions (`LEN`/`CODE`/`VAL`); nesting works
(`UPPER$(LEFT$(A$,3))`), as does `PRINT`/`IF`-comparison of a function
call directly. All transform logic lives in EXROM (`rom/exrom_
strfuncs.asm`), Home only parses arguments. `FILL$`/`INSTR` were both
dropped mid-implementation to fit Home ROM's own budget (`INSTR`'s own
two-buffer argument parsing was the bulk of the overage). Four real
bugs found and fixed, all only by live emulator testing (static review
and hand-tracing missed every one):
1. A nested-string-function-call clobbering bug — the first draft
   stashed the caller's destination/budget/pool-buffer address in
   shared sysvars, which a call like `UPPER$(LEFT$(A$,3))` recurses
   back through and overwrites before the outer call reads them back.
   Fixed by moving all of it onto the real Z80 stack (same "shared
   mutable scratch clobbered by a nested call" bug class as `FUNC_
   CALL_ID`/`ARGC`, `DETOK_BUF`, and `CUR_VAR_LETTER` before it).
2. The routine factored out to share duplicated argument-parsing code
   across all 4 shapes called `STR_FUNC_POOL_ACQUIRE` (which clobbers
   `HL` with the acquired buffer's address) and then evaluated the
   argument *without reloading `HL`* with the actual source text
   first — fed the buffer's own address to the parser as if it were
   the text to parse. `PRINT UPPER$("hello")` was the first thing to
   actually exercise this path.
3. Once (2) was fixed, the same call still failed the whole-program
   check: `BASIC_EVAL_STR_EXPR` only ever advances the `HL` *register*
   on return, never `EXPR_PARSE_PTR` itself — the very next instruction
   in the shared helper (`pop hl`, retrieving the buffer address)
   silently discarded that advanced position before it was ever saved.
   Every caller's own subsequent `")"`/`","` grammar check then read
   the *stale* pre-argument position.
4. `rom/exrom_checker.asm`'s own `PRINT`-statement grammar check never
   learned about string-function-call syntax when this landed — only a
   quoted literal or bare string variable — so `PRINT UPPER$(A$)`
   failed the whole-program check with `SYNTAX ERROR` despite running
   fine. Fixed by adding the same probe real execution's own `PRINT`
   already had. (`IF`'s own string comparison needed no separate fix —
   it already reaches the real `BASIC_EVAL_COMPARISON` transitively.)

Debugging method: per-branch border-color instrumentation
(`out (PORT_ULA),a`, distinct colors, infinite loop right after) across
several single-statement isolated test programs, bisecting from "the
checker rejects the whole program" down to the exact instruction. One
false alarm along the way, worth remembering: a content-mismatch
diagnostic fired even after the real bugs were fixed, because the
checker evaluates `IF` conditions for real while the left-hand variable
genuinely isn't assigned yet during checking (`BASIC_CHECK_STR_
ASSIGNMENT` deliberately discards its own result) — gating the
diagnostic on `BASIC_CHECK_ONLY` confirmed it was a check-pass
artifact, not a bug. See `docs/programmers_reference.md`'s "String
functions — Phase 3, part 5" section for the full writeup.

**`kernel/editor` moved to EXROM whole** (2026-08-22) — a ROM-shrink
migration forced by the string-functions feature alone still leaving
Home ROM hundreds of bytes over its 16K cap. Surveyed real byte counts
before picking a candidate (not guessed): `kernel/editor` (711 bytes)
was large enough alone to close the gap and, once traced through, had
no hot-loop repaging risk — unlike the graphics statement handlers,
which were both too small combined and would have needed ~10 new
`KTAB` entries for shared Home helpers they don't currently route
through EXROM. Seven entry points `basic/` calls got fixed EXROM stubs
and thin `BASIC_EDITOR_*_EXROM` wrappers; six new `KTAB` entries cover
the editor's own calls back into Home (keyboard read, cursor redraw,
four `kernel/memory` primitives). `EDITOR_ENTER` pages EXROM in once
and keeps it paged in for the *whole* interactive editing session
(every keystroke, until the user commits) rather than per-keystroke —
safe because `EDITOR_NAV_HOOK`/`EDITOR_REDRAW_HOOK` jump straight into
always-mapped Home regardless of chunk 6's paging state, and `BANK_
EXROM_DEPTH`'s existing nesting-safety makes any hook-triggered
EXROM-into-EXROM call a cheap counter bump rather than a real port
write. `kernel/editor/editor.asm` itself is unchanged and still builds
standalone (`rom/test_editor.asm`) — `rom/exrom_editor.asm` is a
hand-adapted copy, not generated, so a future logic change needs both
touched. Verified interactively in the real emulator: synthetic X11
keystrokes (`python-xlib`'s XTest extension) typed `print`, watched it
appear character-by-character with correct cursor redraw, and pressing
ENTER correctly committed it as a program line — all now running from
EXROM, no hang/crash/corruption across sustained use. Final measured
budget after both this migration and the string-functions feature:
**Home 245 bytes free / EXROM 398 bytes free**. See `docs/programmers_
reference.md`'s "kernel/editor moved to EXROM" section for the full
writeup.

**HELP topic expansion, built then reverted the same day** (2026-08-23)
— two new topics (`HELP STRING`, `HELP MATH`) plus a `HELP TOPICS`
list screen were added to `rom/exrom_help.asm` alongside the existing
`EDITOR` topic, then removed again a short time later at the user's
own request: HELP is back to always showing the single `EDITOR` screen
regardless of what follows the word HELP, simpler even than the
original one-topic version (no table, no keyword match, no list
fallback). EXROM ended up with more free space after the revert (449
bytes) than either version that came before it, since real dispatch
logic was removed, not just topic text. See `docs/
programmers_reference.md`'s "HELP topic expansion, built then
reverted the same day" section for the full writeup.

**Multi-keyword bold highlighting** (2026-08-23) — `KEYWORD_HILITE_
TABLE`-driven bolding used to only ever bold a line's very first word;
`INK 7:PAPER 5` only bolded `INK`. Extended at the user's own request
("both ink and paper should be bolded... in an if then statement both
if and then should be bolded") to bold every colon-separated segment's
own leading keyword. **`THEN` in `IF x THEN y` still does NOT bold** —
confirmed directly by the user after shipping, correcting this doc's
own first-draft claim that it did. `IF x THEN y` is one colon-segment
with no `:` in it, and the scan only tries one match per segment, at
its own start — `THEN`, a second word inside that same segment, is
never attempted. Catching it would need a further, narrow, IF-THEN-
specific extension, not yet built (EXROM margin too tight — ~19 bytes
free — by the time this was confirmed). Found and fixed two real bugs
along the way: a Home ROM budget problem (the first Home-resident
draft left only 40 bytes free, not enough for the preload test
harness, confirmed by a real build overflow — needed two EXROM
migration passes, `rom/exrom_highlight.asm`, before the WHOLE `tests/`
suite, not just the boundary cases, came back green), and a genuinely
severe redraw bug right after the second pass where NO keyword bolded
at all any more, including plain single-word cases that had worked
before — root cause was a wrong belief that `LD IX,(nn)` isn't a real
Z80 instruction, leading to an HL-relay workaround that clobbered the
live text-scan pointer instead. See `docs/programmers_reference.md`'s
"Multi-keyword bold highlighting" section for the full writeup on all
of this.

**Sprite improvements: more slots, MOVE, HIT()** (2026-08-23) —
`SPRITE_SLOT_MAX` doubled 4 -> 8 (essentially free in ROM, real cost is
RAM: program-area space shrank from 2199 to 1023 bytes for it);
`SPRITE MOVE <slot>,<row>,<col>` repositions an already-shown sprite in
one statement instead of `HIDE` then `SHOW`; `HIT(slot1,slot2)` is a
new rectangle-overlap collision function. `MOVE`'s first draft (mostly
duplicated code) left EXROM at 12 bytes free, not enough room for
`HIT()` afterward — refactored `SHOW`/`HIDE`/`MOVE` to share four small
helpers first, which recovered enough margin (184 bytes) to fit `HIT()`
too. Final measured cost: Home 179 -> 147 bytes free, EXROM 184 -> 19
bytes free — thin. `HIT()` takes its two slot numbers in `HL`/`DE`, not
`A`, by design — avoiding the exact EXROM-entry-stub bug class just
fixed twice above rather than needing a third fix for it.

Verified via real execution (`tools/preload_gen.py --autorun`, not
interactive typing — see the editor-typing bug/fix sections above for
why that approach was abandoned): slot 7 `GRAB`/`SHOW`/`HIDE` all run
clean; `HIT()` correctly returns both `0` (slot never shown) and `1`
(two slots overlapping) against real computed values, not just "no
error"; `MOVE` runs clean and leaves no visual artifact behind. Budget
was too tight to fit `MOVE` and `HIT()` together in one combined test,
so "does `MOVE` actually change what `HIT()` reports" is inferred from
the code (both touch the same `SPRITE_SLOT_ROW`/`COL` sysvars) rather
than directly proven — see `docs/programmers_reference.md`'s "Sprite
improvements" section for the full writeup and that one specific gap.

**Real bug fixed: only the first character of the line being typed
ever appeared on screen** (2026-08-23, user-reported). The full typed
text was always stored and dispatched correctly (ENTER on `HELP`
still opened the HELP screen) — only the glyphs after the first
failed to render, which is what made this look like a keystroke-
delivery problem at first rather than a display one. Root cause: every
EXROM entry stub's magic-check preamble clobbers `A` before the real
routine runs, and `BASIC_EDITOR_WRAP_TABLE_ADDR_EXROM` was the first
place in the project found routing a call through that trampoline
while needing `A` (a wrap-table row index) as a real argument, not
just `HL`. Fixed by inlining the tiny `HL = table + index` computation
at its two call sites instead of routing through EXROM at all. Found
via border-color instrumentation in the real emulator, same method as
the earlier `STR$` bug; re-verified live afterward (multi-character
typing, word-wrap, UP/DOWN nav, backspace, delete-line, insert-line,
keyword highlighting) and confirmed the full `tests/` regression suite
(38 files) still passes green with no change. See `docs/programmers_
reference.md`'s "Real bug: only the first character..." section for
the full writeup, including why the `kernel/editor` migration's own
original verification above missed it.

**Second instance of the same bug, found separately (2026-08-23,
user-reported): the flashing cursor on a word-wrapped line stuck at a
fixed column instead of tracking the real typing position** — "always
appears to be the same place position column 13." Same root cause,
different routine: `EDITOR_WRAP_OFFSET_TO_ROWCOL`'s own entry stub
also needed `A` (the cursor's buffer offset) as a real argument across
the same broken trampoline. Audited every other EXROM entry stub's
documented input contract afterward to confirm no third instance was
still lurking — none found. Fixed by having `EDITOR_WRAP_OFFSET_TO_
ROWCOL` read `EDIT_BUF_OFFSET` directly from memory instead of
trusting `A` — every real caller already loaded `A` from that exact
sysvar right before calling in anyway, so this changes nothing about
which value is used, only where it's read from. Verified live (a
word-wrapped line's cursor now correctly tracks onto the second row)
and against the full `tests/` suite again. See `docs/programmers_
reference.md`'s "Real bug: cursor position on wrapped lines..."
section for the full writeup.

## Testing kernel/editor

```
sjasmplus rom/test_editor.asm
fuse --machine ts2068 --rom-ts2068-0 test_editor.bin --rom-ts2068-1 rom1.bin
```

**Interactive** — type on your real keyboard and watch it appear live,
with a blinking inverse-video block showing the cursor position (the
ULA's hardware FLASH bit does the blinking — no timer code, see
`docs/programmers_reference.md`'s kernel/editor section). Letters type as **lowercase by default**; hold CAPS SHIFT for
uppercase (see `docs/programmers_reference.md`'s kernel/io section — a
deliberate design choice, not a hardware fact, and a change from
earlier testing when unshifted letters were uppercase). Try letters/
digits in both cases, CAPS SHIFT+5/6/7/8 to move the cursor left/right
(see `docs/hardware_notes.md`), CAPS SHIFT+0 to delete forward, and
confirm the line — and the cursor block's position — matches what
you'd expect after each edit. Tip: Fuse conveniently maps your PC's
actual arrow keys and Backspace key directly to these combos — you
don't need to manually hold Shift and press a number. ENTER exits
(border turns yellow) — this does NOT save anything to program storage
yet, see `EDITOR_EXIT`'s own comment in `kernel/editor/editor.asm` for
why that's deliberately deferred rather than done incorrectly.

**NOTE**: this file (`rom/test_editor.asm`) still exercises kernel/
editor's own standalone Home-only reference copy, not the real shipped
`rom/exrom_editor.asm` — same caveat as ever, it can't catch a Home<->
EXROM boundary bug. For that, see the automated harness just below.

## Automated (non-interactive) editor/typing regression test

**Automated and runnable (2026-08-27)**: the harness now fits exactly
within its 16K test image, its key queue is injected into RAM, and the
runner derives every address from the assembler symbol file. It is part
of `make test` and can also be run directly:

```
tools/run_editor_auto_test.sh
```

**Non-interactive, no keyboard/X11 involved** — added 2026-08-23 after
two real bugs this session ("only the first character of a typed line
ever rendered", "cursor stuck at a fixed column on a wrapped line")
both turned out to live specifically in the Home<->EXROM boundary code
kernel/editor's word-wrap machinery crosses on every keystroke, a code
path neither `rom/test_editor.asm` (real-keyboard interactive, never
actually run against real hardware per its own header) nor kernel/
editor's standalone copy (same-file `call`, bypasses the boundary
entirely) could ever exercise, and after being told directly not to
keep using synthetic X11 keystrokes for testing.

Technique: `kernel/io`'s `IO_READ_KEY` is a thin consumer of two ISR-
latched sysvars, `KBD_LASTK`/`KBD_KEYHIT`, normally written only by
`kernel/interrupt`'s `KBD_ISR_TICK` from the real `RST_38` timer tick.
`rom/test_editor_auto.asm` replaces `RST_38`'s target with its own tiny
injector that writes those same two sysvars from a fixed queue instead
of a real matrix scan — becoming the session's sole writer, same
single-writer invariant the real ISR relies on, just substituted whole
rather than raced against. `EDITOR_ENTER`/`EDITOR_LOOP`
(`rom/exrom_editor.asm`) and everything they call — including the real
`BASIC_COMMAND_LOOP` (`basic/basic.asm`), reused whole for its own
non-trivial cold-boot init rather than hand-rolled — run 100%
unmodified, through the real KTAB boundary and the real, shipped
`exrom.bin`, exactly as a human typing would drive them.

The first test case types 33 'A' characters (one more than one screen
row's 32-column width, no space anywhere for word-wrap to break on,
forcing `EDITOR_WRAP_CALC`'s hard-break path) and checks (1) the typed
buffer holds exactly what was typed, and (2) re-running the same
production wrap/cursor call path `BASIC_REDRAW_PROGRAM`'s own cursor-
drawing code uses returns the hand-computed correct row/column — a
direct regression check on `EDITOR_WRAP_OFFSET_TO_ROWCOL`, the exact
routine the "cursor stuck at column 13" bug lived in. Verdict via
border color (green/red), same convention as `tests/`. The key queue
deliberately never includes ENTER — committing the line would let
`BASIC_COMMAND_LOOP` race ahead to its next loop iteration (re-zeroing
the edit buffer) before verification, which runs from inside the
injector itself once the queue drains, ever got a chance to read it;
parking mid-edit sidesteps that race entirely, and the emulator session
just stays parked afterward (not a hang — the deliberate end state,
same as this project's other interactive test binaries).

Verified both directions before trusting it: the real (correct) check
values show green, and a deliberately-wrong expected value (temporary,
reverted immediately) shows red — confirms the harness actually
discriminates pass/fail rather than always reporting green.

Only one test case exists so far (typing + word-wrap + cursor
placement) — extending this to cover INSERT/DELETE/BACKSPACE/cursor
navigation/multi-line EDIT-into-existing-statement scenarios is future
work; the technique (custom `RST_38` injector + parking mid-edit to
avoid the commit race + reusing real production hooks) generalizes
directly, just needs more queued key sequences and hand-computed
expected states per case. Costs zero real product budget — this file's
own INCLUDEs and Home ROM 16K target only apply to the disposable test
binary itself, never to `test_basic.bin`.

## Testing kernel/graphics

```
sjasmplus rom/test_graphics.asm
fuse --machine ts2068 --rom-ts2068-0 test_graphics.bin --rom-ts2068-1 rom1.bin
```

**Visual**, like the kernel/io test is interactive — there's no formula
to check glyph shapes against, only your eyes. Prints the entire font
(space, 0-9, A-Z, a-z, punctuation) across six rows, then all 16
block-graphics characters (128-143) and three POKE'd UDG test patterns
(diamond/checkerboard/diagonal-stripe, codes 144-146) on rows 6-7,
then sets the border cyan as a "finished rendering" signal, not a
verdict. Check: do the letters and digits actually look like what
they're supposed to? Garbled or overlapping text would point at the
screen-addressing math; a specific wrong-looking letter shape points at
that one glyph in `FONT_TABLE`. For row 6, code 128 should render
blank and code 143 fully solid, with the sequence between visibly
filling in one quadrant at a time; for row 7, each UDG shape should
match its source bytes exactly (see `rom/test_graphics.asm`'s own
`UDG_DIAMOND`/`UDG_CHECKER`/`UDG_STRIPE` data) — see
`docs/programmers_reference.md`'s "Block graphics + UDGs (2026-08-22)"
section for the full algorithm/provenance writeup.

This test file previously never actually assembled (its own header
said so) — it's missing a `kernel/math` `INCLUDE` that `GFX_LINE`/
`GFX_CIRCLE` call into (`MATH_NEGATE16`/`MATH_COMPARE16`), only
surfaced when block-graphics/UDG work finally tried to build it. Fixed
alongside adding the new rows.

## Testing kernel/io

```
sjasmplus rom/test_io.asm
fuse --machine ts2068 --rom-ts2068-0 test_io.bin --rom-ts2068-1 rom1.bin
```

**Interactive**, unlike the other tests here — click into the Fuse
window so it has keyboard focus, then press a real key. Expect the
border to turn green while held, black when released. This only
confirms the scanning primitives, not `IO_READ_KEY`'s ASCII translation
table (see `docs/programmers_reference.md`'s kernel/io section for why).

## Testing kernel/storage (SAVE/LOAD)

Current design: `kernel/storage/storage.asm` is a direct,
instruction-by-instruction-verified port of the real TS2068 ROM's own
SA-BYTES/LD-BYTES cassette routines — see that file's own top header
for the full protocol writeup, every deliberate deviation from the real
ROM, and the current known-status note (summarized below). This
replaced an earlier from-scratch protocol (archived at `kernel/storage/
archive/storage.asm`; see `docs/programmers_reference.md`'s own
archived write-up of it and its now-unused Fuse-injection test tooling
under `tools/archive/` — that tooling was built for the old protocol's
register/timing contract and has not been adapted for this one).

Build:

```
sjasmplus rom/test_basic.asm
sjasmplus rom/exrom_build.asm
fuse --machine ts2068 --rom-ts2068-0 test_basic.bin --rom-ts2068-1 exrom.bin
```

Type `SAVE "name"` then `LOAD "name"` (or `LOAD ""` for the wildcard
form) interactively. The confirmed `tests/fixtures/storage_verify.tzx`
is decoded and validated by `tools/check_tape_fixture.py` during `make
check`, but live receiver timing still requires a real tape round-trip in
Fuse with the tape actually playing (Fuse only auto-starts playback via
its ROM-trap mechanism, which doesn't apply to this non-standard loader,
so press Play in Fuse's tape browser yourself).

**Status**: SAVE and LOAD are confirmed working in real Fuse round-trips
with both `LOAD ""` and `LOAD "verify"`. SAVE produced a valid Direct
Recording TZX and LOAD restored its three-statement listing. The receiver
depends on stock LD-EDGE-2 control flow (a second LD-EDGE-1 measurement),
and named LOAD also retains its padded filename and preserves that
pointer through command setup. `tools/check_storage_contract.py` guards
these structural invariants.

The tape container now uses the stock TS2068/Sinclair 17-byte BASIC
header followed by one data block. The data block intentionally remains
this ROM's native program representation, so this is transport/tooling
compatibility rather than stock Sinclair BASIC compatibility. See
`docs/tape_compatibility.md` for the byte layout and state contract.

## Coding standard (see docs/programmers_reference.md for the long version)

Z80 / sjasmplus, symbolic constants only (`include/`), one module = one
concern, every public routine documented in its header comment and in the
Programmer's Reference, correctness before optimization.

**Before considering any non-trivial change to a large `.asm` file
finished**, run:
```
python3 tools/check_asm.py basic/basic.asm
```
(or list other files as arguments — no arguments defaults to
`basic/basic.asm`, the largest and most actively edited file). Catches,
from source alone with no assembler needed: duplicate global labels,
local-label scope errors (a stray bare label silently ending
sjasmplus's scoping for everything after it — this project's single
most expensive bug once), and a stack-ordering fingerprint (a routine
popping something before pushing anything of its own, the exact shape
of a real bug that survived extensive hand-tracing and passed a full
byte-for-byte listing-file audit before it was finally caught by
single-stepping the real build in an emulator debugger — see
`docs/programmers_reference.md`'s "IF/ELSEIF/ELSE/END IF" section for
the full story). None of this replaces actually assembling and testing
— sjasmplus and real hardware/emulator behavior are still ground
truth — but every check here is free, fast, and catches something this
project has genuinely shipped before.

**After adding a font glyph, punctuation mapping, or HELP topic**, run:
```
python3 tools/check_docs.py
```
Cross-checks counts/names quoted in the docs (glyph count, punctuation
count, HELP topic coverage) against the actual source tables — this
project has had exactly this kind of doc staleness slip through twice
before.
