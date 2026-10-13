# Milestone 01 Results — P0.3: `HIT()` sprite-function-to-loadable-extension conversion

2026-09-19. Real, measured results only — see `docs/RESOURCE_LEDGER.md`
and `docs/COMPATIBILITY_BREAKS.md` (Break 2) for the summary entries
this document backs.

## What actually shipped (narrower than originally planned)

The candidate this milestone started from (`COMPATIBILITY_BREAKS.md`'s
original Break 2) assumed converting `SHOW`/`MOVE`/`HIDE`/`HIT()`
together, estimating ~750-900 net EXROM bytes. Implementation found this
assumption wrong before any code was tested: `rom/exrom_sprite.asm`'s own
header shows there is exactly **one** resident statement keyword,
`SPRITE`, with `GRAB`/`SHOW`/`HIDE`/`MOVE` as sub-verbs its own callback
parses internally — not three separate top-level BASIC keywords. That
statement's free-form sub-verb grammar (variable argument count and
shape per sub-verb) does not fit either canned statement shape the
loadable-extension ABI already offered (grammar 0: `expr,expr`; grammar
1: LINE-shaped 4-expr, `x0,y0 TO x1,y1`).

**Only `HIT(slot1,slot2)` was converted** — a clean fit, since it is a
single 2-argument function with no sub-verb grammar, and its own body
(rectangle-overlap arithmetic) turned out to have no EXROM dependency at
all: every `SPRITE_SLOT_*` array it reads, and `SPRITE_SLOT_MAX`, are
plain RAM sysvars/constants, not EXROM-resident code. `SPRITE GRAB/SHOW/
HIDE/MOVE` is **unchanged**, still resident in `rom/exrom_sprite.asm`,
still requires no load step. Converting it is real, disclosed follow-up
work (see COMPATIBILITY_BREAKS.md's "Break 2 follow-up" section) —
it needs a new free-form ("callback owns its own parse and its own
checker-side validation") grammar shape added to the ABI first.

## New ABI surface added

- `include/sysvars.inc`: a new function-registration slot —
  `EXTENSION_FUNC_ACTIVE`/`EXTENSION_FUNC_NAME_PTR`/`EXTENSION_FUNC_EXEC_PTR`
  (`$F3C8-$F3CC`), separate from the pre-existing single statement slot
  (`EXTENSION_NAME_PTR`/`EXEC_PTR`/`GRAMMAR`). Fixed at 2 numeric
  arguments — `HIT()` is this ABI's only function client so far; a
  general arity field was implemented, then reverted (see "Design
  reversals" below).
- `basic/basic.asm`: `BASIC_EXTENSION_REGISTER` gained a `C=2` ("register
  a function, not a statement") path. `BASIC_EVAL_PRIMARY` gained a new
  fallback — tried after the built-in function table fails, before the
  single-letter-variable path — that dispatches into the function slot.
- `rom/exrom_sprite.asm`: the real dispatch body,
  `BASIC_TRY_EXTENSION_FUNCTION_EXROM_BODY`, reached via
  `EXROM_ENTRY_EXTENSION_FUNCTION` (`rom/exrom_checker.asm`, $C096 — the
  exact address the removed sprite-HIT EXROM stub used to occupy).
- `rom/extensions/sprite.asm` (+ `sprite_test.asm`/`sprite_clear_test.asm`
  test-build variants, + a `sprite-extension` Makefile target): the
  loadable module itself, a faithful port of the former
  `BASIC_SPRITE_HIT`'s exact rectangle-overlap logic (247 bytes, well
  under the 512-byte module window).
- `tests/hit.txt`, `tests/hit_unloaded.txt`, `tests/hit_new_clear.txt`:
  new regression fixtures — a positive collision/no-collision check, a
  checker-rejects-unregistered-function check, and a checker-rejects-
  after-NEW check (mirroring the existing `ayreg_new_clear.txt` etc.
  convention exactly — these are negative tests, not positive ones; see
  "A real fixture-authoring bug, caught and fixed" below).

## Design reversals caught before (or by) a real build — the real story of this milestone

Several design decisions were tried, then reverted, each time because a
real build or a real fixture run disproved an assumption. Recorded here
because the reasoning, not just the final shape, is what a future
session needs before touching this ABI again.

1. **Three statement slots, not just a function slot.** The first draft
   assumed `SHOW`/`MOVE`/`HIDE` were three separate keywords needing
   three statement-registration slots (`EXTENSION_SLOT_COUNT`,
   `NAME_PTR1/2`, `EXEC_PTR1/2`, `GRAMMAR1/2`). A real build showed this
   alone pushed Home ROM 255 bytes over budget (against a 5-byte-free
   starting margin) — and re-reading `rom/exrom_sprite.asm`'s own header
   showed the premise was wrong anyway (one keyword, four sub-verbs).
   Reverted to the original single statement slot, unchanged.
2. **A general N-arity function field.** `HIT(slot1,slot2)` is
   2-argument, not 1 — caught by re-reading the OLD resident `.call_hit`
   dispatch this module replaces, before any build. A general
   `EXTENSION_FUNC_ARITY` byte (1 or 2) was implemented to future-proof
   the ABI, then reverted once a real build showed every byte mattered
   and `HIT()` remains the only client — fixed at 2 arguments instead.
   (Independently, `structured-basic-poc`'s own `NATIVE_ABI.md` SBN v2
   package format confirms "name+arity+entry" as a minimal *sufficient*
   shape for a function extension in general — but this project's own
   Home-budget reality, not that shape, is what decided this specific
   implementation.)
3. **A full 16-bit range check for `BASIC_EXTENSION_VALIDATE_ADDR`.**
   Added when the module window was (mistakenly) enlarged from 512 to
   1,536 bytes for the abandoned 3-statement-slot design. Reverted along
   with the window enlargement once the real module (`HIT()` alone, 247
   bytes) turned out to need nowhere near 512 bytes, let alone 1,536 —
   restoring the original, cheaper "`AND $FE`, compare one high byte"
   trick that only works for an exactly-512-byte, page-aligned window.
4. **A `BASIC_CHECK_ONLY` guard for the new function dispatch.** Added
   defensively, then removed: every existing statement-slot extension
   callback already runs unconditionally during a whole-program check
   pass (confirmed by inspection — `BASIC_TRY_EXTENSION`'s own
   `grammar_zero` path calls `BASIC_CALL_USR` with no guard at all, even
   though `CPLOT`'s own exec body mutates the screen), and the pre-move
   resident `.call_hit`'s own original header gives the same reasoning
   for `HIT()` specifically (read-only body, safe to call unconditionally).
   Matched that existing precedent instead of adding new, unneeded
   caution.
5. **The single biggest fix: moving the new dispatch body to EXROM.**
   Every above reversal narrowed the design, but Home was *still* over
   budget (66 bytes, then whittled down to 1 byte through several rounds
   of register-reuse micro-optimization in `BASIC_EXTENSION_REGISTER`
   and the dispatch routine itself). The real fix wasn't more code
   golf: it was recognizing that this ROM already has an established,
   working pattern for exactly this situation — move new HOME-resident
   code whose bulk isn't strictly Home-only-dependent out to EXROM via a
   fixed entry stub + `BASIC_CALL_EXROM_INLINE`, the same shape
   `BASIC_SPRITE_EXROM`/`BASIC_SAVE_EXROM`/etc. already use for *old*
   resident code. Applying it to *brand-new* code for the first time
   dropped Home's net cost for this whole ABI addition from "didn't fit
   at all" to **3 bytes**, while the EXROM side absorbed the real body
   comfortably (EXROM had 89 bytes recovered from removing the old
   resident `HIT()` implementation in the same pass, so the net EXROM
   change is a large net *gain*, not a cost).

## A real fixture-authoring bug, caught and fixed

`tests/hit_new_clear.txt`'s first draft copied `hit.txt`'s positive
collision-check content — wrong. The `_clear` test harness variant
(`rom/test_extension_clear_inject.asm`) installs the module, then calls
`MEM_INIT` (NEW) *before* running the injected program specifically to
prove NEW correctly unregisters it (see every existing `*_new_clear.txt`
fixture — `ayreg_new_clear.txt` is a bare `AYREG 0,0`, expected to be
*rejected*, not to succeed). The first version of this fixture expected
success and failed the real regression run (`border=7` instead of the
expected `4`) — a genuine, disclosed bug this milestone found in its own
test authoring, not in the ROM. Fixed by rewriting it as a bare
`PRINT HIT(0,1)` negative test and adding it to both runners'
`EXPECTED_BLACK` lists, matching the established convention exactly.

## Real, measured results

- **`make check`**: clean, 0 errors, 0 warnings (also required a real,
  disclosed unrelated fix: `README.md`'s fixture count was stale at 95;
  updated to 98, and its "needs Fuse + X11" note updated to reflect the
  `ts2068-debug`/ZEsarUX migration from Milestone 00).
- **`make test` (full regression suite, `tools/run_all_tests_fast.py`,
  real ZEsarUX/ZRCP execution via `ts2068-debug`)**: **98/98 PASS, 0
  FAIL** (95 pre-existing + 3 new `hit`/`hit_unloaded`/`hit_new_clear`
  fixtures), 725.8s total, 4 ZEsarUX restarts.
- **`make budget`**: HOME 16,382/16,384 used, **2 bytes free** (was 5).
  EXROM 8,076/8,192 used, **116 bytes free** (was 27). Net: Home lost 3
  bytes, EXROM gained 89.
- **Live verification, real ts2068-debug/ZEsarUX** (not just the
  automated harness — same technique, read directly): `tests/hit.txt`
  pokes two overlapping sprite-slot rectangles directly into
  `SPRITE_SLOT_*` RAM, confirms `HIT(0,1)=1` (true collision) AND
  `HIT(0,2)=0` (slot 2 never shown, no collision) in the same run —
  border 4 (green) confirms both checks passed, not just one accidental
  match. `tests/hit_unloaded.txt` and `tests/hit_new_clear.txt` confirm
  the whole-program checker correctly rejects `HIT(...)` when no module
  is registered (border 7, the established "unloaded rejection"
  convention). The existing `spr1.txt`-`spr4.txt` fixtures (unchanged
  `SPRITE GRAB/SHOW/HIDE/MOVE` usage) continue to pass unmodified,
  confirming the untouched statement path still works.

## Performance note (why this dispatch's cost is inherent, not a missed optimization)

2068-Leap has no compile step — it re-parses and re-dispatches from
program source on every execution (`docs/CURRENT_LIMITATIONS.md`),
unlike `structured-basic-poc`'s bytecode-VM design, where a function
extension's dispatch cost is paid once at compile time and never again.
The new extension-function check added to `BASIC_EVAL_PRIMARY` is
therefore paid on **every** evaluation of **any** expression that
reaches that fallback (not just ones containing `HIT(...)`) — there is
no "compile it away" alternative available in this architecture, so this
is the real, permanent cost of the feature, not a missed optimization.
It was not separately isolated against `~/2068-rom-benchmarks`'s
existing addition/variable-access benchmarks this session (real,
disclosed follow-up, not done here) — the dispatch itself is one `call`+
conditional `ret` into an EXROM-resident magic/active check that fails
fast (two byte reads) whenever no function is registered, so the
expected cost for programs not using `HIT()` at all is small, but this
is inference, not a measurement.

## What was NOT done (explicit, disclosed)

- `SPRITE GRAB/SHOW/HIDE/MOVE` itself was not converted — see
  "What actually shipped" above and `COMPATIBILITY_BREAKS.md`'s
  "Break 2 follow-up" section for the free-form-grammar prerequisite.
- The extension-function dispatch's real per-expression frame cost was
  not isolated via `~/2068-rom-benchmarks`.
- Home ROM's margin is now critically thin (2 bytes) — any future
  Home-resident addition needs either a dedicated Home-shrink pass first,
  or must itself follow this milestone's own EXROM-migration precedent
  from the start.
