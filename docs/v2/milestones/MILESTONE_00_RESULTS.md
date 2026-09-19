# Milestone 00 — Test Infrastructure: Fuse → ts2068-debug Migration

Not one of the Phase 0 language/consolidation milestones in
`IMPLEMENTATION_PLAN.md` — this was ad hoc infrastructure work requested
directly by the user mid-Phase-0 ("change anything that is using a fuse
session to just the ts2068-debug"). Recorded here anyway, per the project's
own milestone-result convention, since it's a real, non-trivial change to
the test suite's execution mechanism that every later Phase 0 gate depends
on for its own regression-test step.

## OBJECTIVE

Replace every Fuse/X11-window-based test-execution path in `make test`'s
critical path with ts2068-debug (ZRCP/ZEsarUX), matching the pattern
already established for the smoke-test runner (`026a0b1`).

## IMPLEMENTATION

- **`tools/debug_suite_run.py`** (new): injects one `tests/<name>.txt`
  fixture into the ordinary interactive ROM (`build/test_basic.bin` +
  `exrom.bin` — not a special-purpose harness) via ts2068-debug, and reads
  the border-color verdict directly as a numeric ULA code (0-7) via
  `timex`, instead of a Fuse debugger-script injection + X11 screenshot +
  RGB-pixel decode.
- **`tools/run_suite_test.sh`** (rewritten): thin wrapper around the new
  script for interactive single-fixture debugging use.
- **`tools/run_all_tests.sh`** (rewritten): drives every `tests/*.txt`
  fixture through the new script; verdict logic now compares numeric
  border codes instead of RGB pixel tuples.

## A real technical finding, not just a mechanical port

The old approach (`tools/fuse_suite_inject.py`) worked by setting a
Fuse-debugger breakpoint on a ONE-SHOT label (`INJECT_POINT`, executed
exactly once during a short, linear boot sequence, immediately before
`call BASIC_RUN`) and poking the encoded test program directly into
`PROG_AREA_START`/`PROG_END` at that pause.

That technique does **not** port cleanly to ts2068-debug: empirically,
confirmed reproducible across many independent sessions (not a timing
fluke), ts2068-debug/ZEsarUX's breakpoint-arming has enough real latency
that a one-shot target executed only once during a short linear sequence
reliably fires *past* it before the breakpoint is armed — both
`run --until INJECT_POINT` and an explicit `break` + `run` landed at the
post-call hang loop every time, never at the call itself.

A **converging** target that the CPU loops back into indefinitely (like
the interactive `BASIC_COMMAND_LOOP` idle loop) does not have this problem
— missing the first pass doesn't matter, since execution returns to it
repeatedly. This is exactly the pattern ts2068-debug's own documentation
already recommends (`run --until BASIC_COMMAND_LOOP`, `resume`, `type`,
per its SKILL.md).

The final design instead drives the machine like an operator: boot to the
real command loop, `resume` (exit cpu-step), `type` the fixture's program
text plus `RUN`, wait, `pause`, read `timex`. This is **more**
representative of real usage than the old poke-based shortcut (it
exercises the actual editor + checker + RUN path end-to-end, not a
bypass), at the cost of needing real wall-clock time per fixture instead
of an instant memory poke.

For the ~14 fixtures needing a loadable RAM extension pre-registered
(`RAM_EXTENSION_BIN`), a second technique was needed: the module's own
object code at offset 0 is itself a self-installer (matching the old
harness's `call EXTENSION_MODULE_BASE` convention). Since there's no
direct "call" verb in ts2068-debug's CLI, this is emulated by hand — push
the current PC as a return address, adjust SP, set PC to the module base,
run a small bounded instruction count, then re-synchronize with
`run --until BASIC_COMMAND_LOOP` again (not an exact-PC equality check,
which false-failed despite the operation working correctly — the idle
loop cycles through several legitimately-equivalent PC positions).
Confirmed live: `gfx6` (CPLOT) → border 4 (pass).

## FILES CHANGED

- `tools/debug_suite_run.py` (new)
- `tools/run_suite_test.sh` (rewritten)
- `tools/run_all_tests.sh` (rewritten)
- `tools/fuse_suite_inject.py` (superseded, left in place — no longer
  called by the test-suite critical path; still referenced by
  documentation/history, not deleted in this milestone)

## CONSOLIDATION ACHIEVED

None claimed — this is a test-infrastructure port, not a product-code
consolidation; out of scope for `docs/v2/CONSOLIDATION_AUDIT.md`.

## COMPATIBILITY CHANGES

None to shipped product behavior — this only changes how the *test suite*
exercises the ROM, not the ROM itself.

## ROM RESULT / RAM RESULT

Not applicable — no 2068-Leap ROM/ASM source was modified.

## REGRESSION RESULT

See the live run recorded in `docs/v2/RESOURCE_LEDGER.md` once
`tools/run_all_tests.sh` completes against the full fixture set (in
progress at time of writing).

## Update (same session, later): reverted to direct memory injection, not typing

The section above describes the first working version, which simulated a
real user typing each fixture through the interactive editor — built
that way only because the ORIGINAL injection technique (poke the encoded
program directly into the harness's `PROG_AREA_START`/`PROG_END` at its
one-shot `INJECT_POINT` breakpoint, exactly as `tools/fuse_suite_inject.py`
always did) seemed to be blocked by a ts2068-debug breakpoint-timing race.

That race was root-caused and **fixed at the source, in ts2068-debug
itself** (two commits, `~/ts2068-debug`): `reset_to_known_state()`
(pause first, then a plain/soft reset — `hard-reset-cpu` turned out to
be a no-op for PC/SP/AF, confirmed against the raw ZRCP socket), and a
settle delay inside `resume()` (typing immediately after resume dropped
the first 1-2 characters of the first line — confirmed via screenshot
diff, `BORDER 4` landed on screen as `RDER 4`). With the underlying race
fixed, the original poke-based design is simply correct again — and it
is both simpler and dramatically faster than typing: no keyboard-scan
timing, no per-line whole-program-checker cost, no interactive editor
state to manage between fixtures.

`tools/debug_suite_run.py` and `tools/run_all_tests.sh` were reverted to
the poke-based design (matching the original Fuse-era approach almost
exactly, just via ts2068-debug instead of Fuse). A new
`tools/run_all_tests_fast.py` groups fixtures by which of the four
harness ROM variants they need (`test_suite_inject.bin` /
`test_extension_inject.bin` / `test_extension_clear_inject.bin` /
`test_run_state_inject.bin`) and only restarts ZEsarUX when the variant
changes — 4 restarts for 95 fixtures instead of 95, using
`ts2068-debug`'s Python API directly (no CLI subprocess spawn per
sub-command either).

**This also fully resolved `run_state`** (previously excluded as a known
gap under the typing-based approach) — the dedicated
`test_run_state_inject.bin` harness's own baked-in double-`BASIC_RUN`
call works correctly via direct injection, with no special-casing needed
in this script at all. And `cf1` (previously an unexplained failure)
also turned out to be the same `resume()`-drops-characters bug, now
fixed — it passes cleanly with no other change.

**Result after the harness/breakpoint fixes above**: 87/95 PASS, 8 FAIL,
in 665s (7.0s/fixture average, 4 ZEsarUX restarts total).

## Update (same session, later still): all 8 remaining failures root-caused and fixed

Two independent, real bugs, both found by tracing `CHECK_ERROR_COUNT` and
final PC/border state directly rather than guessing from border color
alone:

**Bug 1 — an un-cleared, persistent breakpoint** (`extension_unloaded`,
`frame_unloaded`, plus a cascading effect on some `*_new_clear`
fixtures): a hand-rolled `break` + `run` + poke + `run` sequence never
cleared the breakpoint after reaching `INJECT_POINT`. Breakpoints are
persistent by design (they fire every time PC reaches that address, not
once) — for fixtures whose execution legitimately revisits that same
address during `BASIC_RUN`, the still-armed breakpoint re-fired on the
second `run()` and executed nothing further. This is standard, correct
ZRCP breakpoint semantics, not a tool bug — the actual gap was that
`ts2068-debug`'s CLI could set a breakpoint but never clear one (`break`
existed, `clear-break` didn't). Fixed by adding `clear-break` to
`ts2068-debug` and calling it in both `tools/debug_suite_run.py` and
`tools/run_all_tests_fast.py` right after reaching `INJECT_POINT`,
matching what `run_until()`'s own internal implementation already does.

**Bug 2 — `BORDER` is a persistent hardware I/O latch, not a CPU
register** (the remaining `*_unloaded`/`*_new_clear` fixtures, plus the
originally-mysterious "true idle default is 4 not 0" finding, which
turned out to be a case of this same bug): `reset_to_known_state()`
correctly resets PC/SP/AF/etc, but the ULA's border port (254) is
untouched by a CPU reset — confirmed live and reproduced with just two
fixtures: `err1` deliberately halts with `BORDER 5` still showing (its
own intended behavior, a runtime error before reaching its later
`BORDER 2`), and the *next* fixture in the same session inherits that
stale border value if its own program is correctly rejected by the
checker and therefore never touches `BORDER` at all — which is exactly
the case for every "checker correctly rejected this unregistered
extension keyword" fixture. This harness's real, hardware-level idle
default is **7 (white)**, confirmed via `CHECK_ERROR_COUNT` reading
nonzero (proving genuine checker rejection, not a coincidental idle
color) across all thirteen `*_unloaded`/`*_new_clear` fixtures once this
was fixed. Fixed by deterministically resetting the border latch
(`LD A,7 : OUT (254),A : RET`, injected via the same register/stack
manipulation technique as extension self-registration, single-stepped
precisely rather than bounded-run — a bounded run of any size, even 10
instructions, let execution continue past the `RET` into real
subsequent boot code before the check could run) at the start of every
fixture in `tools/run_all_tests_fast.py`, and defensively in
`tools/debug_suite_run.py` too.

**Final result: 95/95 PASS**, 703s total (7.4s/fixture, 4 ZEsarUX
restarts for the whole suite) via `tools/run_all_tests_fast.py`. See
`RESOURCE_LEDGER.md` for the final ledger entry.

## PROBLEMS DISCOVERED (original typing-based attempt, superseded above)

- `tests/run_state.txt`'s double-`RUN` semantics (deliberately abandoning
  and testing `FOR_STACK`/`GOSUB_STACK` reset across two consecutive
  `BASIC_RUN` calls) did not reproduce correctly through the ordinary
  interactive command loop in the time available — produced an
  unexplained border value instead of the expected pass. **Explicitly
  excluded from this milestone's completion, not silently reported as
  passing or papered over.** Root-causing this is real follow-up work: is
  it a timing issue (needs more than the fixed 2-second settle window), a
  label-parsing issue specific to typed (vs. poked) label lines, or
  something else. Flagged in `tools/run_all_tests.sh`'s own `SKIP` list
  with a comment pointing back here.
- `tools/run_stack_audit.sh`, `tools/run_demo.sh`,
  `tools/run_demo_cursor_test.sh`, `tools/fuse_demo_inject.py`,
  `tools/fuse_editor_inject.py`, `tools/type_basic.py`, and
  `tools/tape_gen.py`'s real-Fuse-tape-emulation comment still reference
  or use Fuse. **None of these are in `make test`'s critical path** (they
  are standalone developer/demo tooling) — not converted in this
  milestone given time constraints. Disclosed here rather than left
  silently unconverted without a record.

## FOLLOW-UP WORK

1. ~~Root-cause and fix `run_state`'s verdict~~ — done, resolved by the
   direct-injection revert (see update above); `SKIP` list removed from
   `run_all_tests.sh`.
2. ~~Root-cause the 8 remaining failures~~ — done, see update above.
3. Port the remaining standalone Fuse-using developer tools
   (`tools/run_stack_audit.sh`, `tools/run_demo.sh`,
   `tools/run_demo_cursor_test.sh`, `tools/fuse_demo_inject.py`,
   `tools/fuse_editor_inject.py`, `tools/type_basic.py`,
   `tools/tape_gen.py`'s real-Fuse-tape-emulation use), time permitting —
   none block `make test` or any Phase 0 milestone.
4. `tools/fuse_suite_inject.py` is now dead code on the critical path;
   consider deleting it once the migration is confirmed stable, rather
   than leaving an unused Fuse-based implementation beside its
   replacement indefinitely.
5. The border-reset and breakpoint-clear fixes were applied to both
   `tools/debug_suite_run.py` and `tools/run_all_tests_fast.py`
   independently (duplicated logic) rather than factored into one shared
   helper module — acceptable for now given the two scripts' different
   execution models (one-CLI-process-per-fixture vs. one persistent
   Python session), but worth revisiting if they diverge further.

## PASS/FAIL

**95/95 PASS** via `tools/run_all_tests_fast.py` (703s, 7.4s/fixture, 4
ZEsarUX restarts). `tools/run_all_tests.sh` (the slower, one-ZEsarUX-
process-per-fixture `make test` entry point, using the identical
underlying fix set) verified separately — see `RESOURCE_LEDGER.md`.
