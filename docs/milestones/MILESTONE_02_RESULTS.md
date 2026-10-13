# Milestone 02 Results — P0.4: `CIRCLE`+`FILL` combined loadable graphics extension

2026-09-20. Real, measured results only — see `docs/RESOURCE_LEDGER.md`
and `docs/COMPATIBILITY_BREAKS.md` (Break 3) for the summary entries
this document backs.

## Why combined, not `FILL` alone

The original plan for this milestone was "relocate `GFX_FILL` per P0.2's
own ranking." Before implementation began, research into both sister
projects' own graphics-extension designs (`structured-basic-poc`'s
`GRAPHICS_EXTENSION_ABI.md`, `2068-Forth`'s fixed 8-slot graphics
service table) found both independently converged on the same lesson:
don't ship a lone-primitive graphics extension — bundle related
primitives into one loadable module so the per-extension fixed overhead
(registration, dispatch, entry stub) is paid once, not once per
primitive. `CIRCLE` (~368B) and `FILL` (~275B) were both LOW risk with
clean paging closure per P0.2's own findings, so this milestone converts
both together as `rom/extensions/shapes.asm`, not `FILL` alone.

## A genuinely different resource picture than P0.3 (`HIT()`)

`HIT()`'s own body (Break 2, P0.3) was EXROM-resident, so removing it
did nothing for Home's budget — the new function-slot ABI's fixed Home
dispatch cost had to be paid by moving the dispatch itself into EXROM,
a substantial extra effort. `GFX_CIRCLE`/`GFX_FILL`, by contrast, were
**Home-resident** (`kernel/graphics/graphics.asm`, ~586 lines including
private helpers). Removing them freed Home space directly and
substantially — enough that the new second-statement-slot + grammar-3
dispatch mechanism (which, considered alone, costs a comparable amount
of Home ROM to P0.3's own function-slot addition) was easily absorbed,
with a large net gain left over. This milestone's own build succeeded
on the **first attempt**, with no iterative budget-fighting at all —
worth noting as the contrast case to P0.3's own extended "design
reversal" history.

## New ABI surface added

- `include/sysvars.inc`: a second statement-registration slot
  (`EXTENSION_SLOT_COUNT`/`EXTENSION_NAME_PTR1`/`EXEC_PTR1`/`GRAMMAR1`,
  `$F3CD-$F3D2`) and a new grammar value, 3 (`expr,expr,expr` — CIRCLE's
  own x,y,r shape; the third value's low byte reuses the pre-existing
  `EXTENSION_ARG0` scratch byte). The module window was enlarged from
  512 to 1,024 bytes (`$F400-$F7FF`), keeping the cheap `AND $FC`
  page-aligned validation trick (just a wider mask than the original
  `AND $FE`) rather than paying for a full 16-bit range check —
  applying the exact lesson P0.3's own real-build history already
  established, proactively this time instead of re-discovering it.
- `kernel/memory/memory.asm`: `MEM_INIT` now also clears
  `EXTENSION_SLOT_COUNT` on NEW/cold boot, alongside the pre-existing
  `EXTENSION_MAGIC` clear — a real bug caught before any build (see
  below).
- `basic/basic.asm`: `BASIC_EXTENSION_REGISTER` auto-assigns statement
  registrations to slot 0 then slot 1 (grammar 2, the function slot,
  unaffected). `BASIC_TRY_EXTENSION` gained grammar-3 parsing inline,
  plus a new `BASIC_TRY_EXTENSION_SLOT` helper for slot 1 with the same
  grammar 0/1/3 handling, IX-relative instead of slot 0's own
  (deliberately unchanged, pre-existing) fixed addresses.
- `rom/exrom_checker.asm`: `.try_assignments` mirrors the same slot-1 +
  grammar-3 dispatch; grammar 3 reuses the **existing** `.check_circle`
  checker routine (already exactly the right 3-expr shape from CIRCLE's
  own pre-conversion dispatch) rather than duplicating it.
- `rom/extensions/shapes.asm` (+ test-build variants, + a
  `shapes-extension` Makefile target): the combined module itself, 762
  bytes, a faithful, unchanged-logic port of `GFX_CIRCLE`/`GFX_FILL` and
  every one of their private helpers (`GFX_CIRCLE_PLOT_OFFSET/POLES/
  GENERAL`, `GFX_FILL_PUSH/POP/TRY_NEIGHBOR/VISITED_CHECK_SET`), renamed
  with a `SHAPES_` prefix. Calls `GFX_PLOT_CLIPPED`/`MATH_NEGATE16`/
  `GFX_READ_PIXEL`/`GFX_WRITE_PIXEL`/`BASIC_CLAMP_Y191` directly (no new
  `EXT_SERVICE_*` veneer added) — reuses the existing `EXT_SERVICE_
  PRINT_ATTR`/`READ_OVER` veneers `CPLOT` already established for
  everything else.
- `tests/circle_unloaded.txt`, `circle_new_clear.txt`,
  `fill_unloaded.txt`, `fill_new_clear.txt`: four new negative
  regression fixtures, matching every existing `*_unloaded`/
  `*_new_clear` convention exactly (see the real fixture-authoring bug
  P0.3 caught and fixed — this milestone got the polarity right the
  first time by reusing that exact lesson). `tests/gfx4.txt`/`gfx5.txt`
  — the EXISTING, unmodified `CIRCLE`/`FILL` correctness fixtures — now
  need `RAM_EXTENSION_BIN=shapes_test.bin` wired into both test runners,
  the same way `gfx6.txt` already needed it for `CPLOT`.

## A real, load-bearing correctness finding (caught before any code was written, not after a bug)

`GFX_FILL_VISITED` ($C000-$D7FF, 6,144 bytes) and `GFX_FILL_STACK`
($D800+, 4,096 bytes) both live **inside** the EXROM/Dock banking window
(chunk 6, $C000-$DFFF). This is safe today only because `GFX_FILL`'s own
code has always executed with EXROM/Dock *not* paged in (plain Home-
mapped RAM at those addresses) — true for every ordinary statement
dispatch. Had this milestone routed the new statement dispatch through
EXROM the way P0.3's `BASIC_TRY_EXTENSION_FUNCTION_EXROM_BODY` did (the
obvious next move, applying the just-established precedent), paging
EXROM in around the dispatch call would leave it paged in for the
*entire* duration of the subsequent call into the RAM module's own exec
routine — meaning `SHAPES_FILL_EXEC`'s own reads/writes to
`GFX_FILL_VISITED`/`GFX_FILL_STACK` would silently hit the paged-in
EXROM/Dock content instead of RAM, corrupting the flood-fill mid-
algorithm. Caught by reasoning through the memory map before writing any
dispatch code, not by a failing test — this milestone's own statement
dispatch stays Home-resident specifically because of this, and didn't
need EXROM migration anyway once the algorithm-body removal's own Home
savings were measured.

## A real bug caught before any build: `EXTENSION_SLOT_COUNT` never cleared

`MEM_INIT` (NEW/cold boot) already clears `EXTENSION_MAGIC` to
unregister a stale module, but did not clear the newly-added
`EXTENSION_SLOT_COUNT`. Without fixing this, loading a **second**
module after a `NEW` would read a stale nonzero count left over from a
**previous** module's own registration, misassigning its first
statement to slot 1 (or refusing both slots as "full") instead of
starting clean at slot 0. Fixed by clearing `EXTENSION_SLOT_COUNT`
alongside `EXTENSION_MAGIC` in the same `MEM_INIT` block. Caught by
reasoning about the registration sequence before any build — the
existing `hit_new_clear.txt`/`circle_new_clear.txt`/`fill_new_clear.txt`
fixtures wouldn't have caught this specific bug on their own (they only
exercise ONE module's registration after NEW, not a second module's
registration after a first one's own residency), so this is a real,
disclosed gap in this milestone's own regression coverage, not
something the tests happened to prove safe.

## Real, measured results

- **`make check`**: clean, 0 errors, 0 warnings (also required the same
  kind of unrelated real fix P0.3 found: `README.md`'s fixture count
  was stale at 98; updated to 102).
- **`make test` (full regression suite, `tools/run_all_tests_fast.py`,
  real ZEsarUX/ZRCP execution via `ts2068-debug`)**: **102/102 PASS, 0
  FAIL** (98 pre-existing + 4 new `circle`/`fill` unloaded/new_clear
  fixtures), 755.0s total, 4 ZEsarUX restarts. The build succeeded
  clean on the first attempt — no budget-driven design reversals this
  time (contrast with P0.3's own extended history).
- **`make budget`**: HOME 15,830/16,384 used, **554 bytes free** (was
  2). EXROM 8,083/8,192 used, **109 bytes free** (was 116). Net: Home
  gained 552 bytes, EXROM lost 7.
- **Live verification, real ts2068-debug/ZEsarUX**: `tests/gfx4.txt`
  (unmodified since before this conversion) draws a real `CIRCLE
  50,50,10` and confirms `POINT(60,50)=1` (on the outline) and
  `POINT(50,50)=0` (the empty center) — the exact same Bresenham-
  algorithm correctness this fixture has always checked, now running
  through the loadable module instead of resident code, still passing
  byte-for-byte. `tests/gfx5.txt` (also unmodified) draws two triangles
  with `LINE`, flood-fills each with `FILL` in a different `INK` color,
  and confirms both `POINT()` results AND the covering attribute cell's
  `ATTR()` value — confirming the ported flood-fill's own dedup/paint
  logic is unchanged. The four new unloaded/new_clear fixtures confirm
  the whole-program checker correctly rejects both keywords when the
  module isn't loaded.

## What was NOT done (explicit, disclosed)

- The extension-function dispatch's real per-statement frame cost was
  not isolated via `~/2068-rom-benchmarks` (same gap P0.3 left open).
- A second-module-after-a-first-module registration sequence (which
  would have caught the `EXTENSION_SLOT_COUNT` bug from a different
  angle, and might catch a similar gap in the function slot's own
  `EXTENSION_FUNC_ACTIVE` handling under a different loading sequence)
  was not added as its own dedicated regression fixture — real,
  disclosed follow-up.
- No further Home-resident graphics primitives (e.g. `PLOT`/`LINE`
  themselves, or a future `GFX_FILL`-adjacent primitive) were assessed
  for this same conversion — out of scope for this pass.
