# EXROM subsystem and BASIC exposure audit

Status: complete pass, reconciled for the private preview on 2026-08-27.

## Capacity and governing constraint

The current V2 candidate uses `$3FFF/$4000` in Home ROM (1 byte free)
and ends at `$DFFE` in EXROM (2 bytes free). The shared
program/array/scalar RAM pool is 15,322 bytes. These figures come from
`make budget`; historical measurements elsewhere in the engineering journal
are intentionally retained as snapshots of their respective changes.
Another language feature therefore needs a relocation, a compact shared
implementation, or removal of lower-value code.

Editor FIND is deliberately removed. Its stub was never wired to the editor,
and spending ROM and a key binding on it ranks below input and array support.

## Subsystem findings

| Subsystem | Current assessment | Recommended action |
|---|---|---|
| Entry stubs and paging | Fixed checked entries, generated Home callbacks, nesting-safe paging, shared wrappers | Keep. Reclaim the unused `$C072` stub only when six EXROM bytes are decisive; do not renumber entries |
| Static checker | High value, but duplicates portions of execution grammar | Keep in EXROM. Update checker and executor together; share small target/subscript parsers where practical |
| Tape storage/status | Stock framing, staging, validation, and progress are mature | Freeze except for bugs; this is high-risk code with little expansion payoff |
| Calculator | Large specialized service enabling `/`, `SQR`, `SIN`, `PI`, and conversions | Keep. Add calculator operations only for a specific BASIC feature |
| Sound | `SOUND` is already the minimal useful AY primitive | Keep. A high-level `PLAY` statement does not currently exist; consider a compact sequencer after arrays |
| ULAplus | Small, well-scoped, disabled at the shared editor-return boundary | Keep unchanged and showcase it better |
| Sprites | Distinctive and capable, but among the largest EXROM modules | Keep behavior; size-audit repeated validation, error tails, and coordinate parsing |
| String functions | Useful and dispatched through one bank entry | Keep. `INSTR` is now implemented and is more broadly useful than editor FIND |
| Editor | Canonical implementation and redraw hooks are structurally sound | Keep navigation/redraw design. FIND stub removed; defer editor-only expansion |
| Arrays | Numeric and fixed-length string 1D arrays are implemented; `DIM`/`DIMN` are banked; the prior 2D version exceeded ROM | Keep 1D stable; revisit 2D only after a larger ROM-space win |
| Highlighting | Appropriate in EXROM after settled-line caching | Keep; it no longer runs for every cursor-cell move |
| INPUT | EXROM-resident bounded numeric/string input | Literal prompted form (`INPUT "text";A` / `A$`) is implemented; retain the bounds |

## Sprites — size audit follow-up (2026-09-13)

Acted on the "size-audit repeated validation" recommendation above, prompted
by a user question comparing this project's `rom/exrom_sprite.asm` (1081
bytes) against sibling project 2068-Leap-Forth's own smaller sprite feature
(364 bytes EXROM-side). Not a fair swap — that version has 3 ops/4 slots/
fixed 16x16 vs this project's 4 ops including `MOVE`/8 slots/variable size
to 32x32/6 error messages/collision detection (`BASIC_SPRITE_HIT`) — so a
`shrink-z80` pass on this project's own file was the right comparison
instead.

**Applied:** `BASIC_SPRITE_CHECK_ROW`/`BASIC_SPRITE_CHECK_COL` were
byte-identical except one immediate; factored into a shared
`BASIC_SPRITE_CHECK_ROWCOL_CORE`. 22 -> 18 bytes. Verified via `make test`
(all `spr1`-`spr4` fixtures) and `tools/z80sim/test_sprite_basic_driver.py`,
which directly exercises the exact boundary values this touches (row
23/24, col 31/32).

**Follow-up, not yet attempted:** `BASIC_SPRITE_HIT`'s four overlap-check
blocks (row-vs-row+h and col-vs-col+w, each done twice with the two slots'
roles swapped — `~29 bytes` per block, `~162` bytes total, confirmed via
`build/exrom.lst` `$D79F-$D841`) are shaped for a data-driven loop over a
4-entry parameter table, plausibly another 60-80 bytes. Deliberately not
attempted yet: unlike `SHOW`/`MOVE` (which have a documented HL-clobber
bug already found and fixed), `BASIC_SPRITE_HIT` has no known-bug history,
and it's collision-detection logic a game loop calls every frame — a
subtly wrong parameterization would fail silently (wrong hit/no-hit
results), not crash. Whoever picks this up should verify against several
concrete sprite configurations (overlapping, adjacent-but-not-overlapping,
and edge-touching rectangles in both axes) under live emulation, not just
a clean assemble.

## Existing primitives worth exposing in BASIC

Highest-value candidates:

1. Prompted `INPUT "text"; A` / `A$`, building on the existing EXROM input engine.
2. `ATTR(row,col)` over the existing attribute-address machinery, useful for
   games and characteristic of Spectrum/Timex graphics.
3. A relative draw command built over the existing line primitive.
4. A compact AY note/sequencer helper; `SOUND` is complete but verbose.
5. Sprite width, height, or visibility queries over existing slot metadata.

Lower priority: destructive screen scrolling, raw mode-register access
(already reachable through `POKE`/`USR`), and the retired 512x192/64-column
code, which has substantial raster and text-system costs.

## Array expansion recommendation

Use one record evolution rather than a string-array bolt-on:

- preserve kind 0 numeric 1D records;
- add a string-array kind with fixed 32-byte length-prefixed elements,
  matching scalar strings;
- reserve a dimension-count/header form capable of describing 1D or 2D;
- centralize subscript parsing and element-address calculation;
- measure whether hot reads/writes stay Home-side while cold `DIM` allocation
  and metadata move to EXROM.

String arrays have now shipped using kind 3 records and fixed 32-byte
length-prefixed elements. Restore 2D only if the shared work
makes its marginal cost fit. The earlier verified 2D prototype exceeded Home
by about 26 bytes (or EXROM by about 69 bytes with `DIM` banked) in its old
layout, so affordability must be measured again rather than assumed.

## Demo direction

The former checklist demo is replaced by one presentation: an AY drone plays
while a ULAplus-colored Sierpinski triangle is generated using the chaos game,
then a sprite flies over the completed image while its pitch changes. It
combines graphics, arrays, random numbers, integer math, ULAplus, AY sound,
and sprites in one coherent program.
