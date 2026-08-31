# EXROM subsystem and BASIC exposure audit

Status: complete pass, reconciled for the private preview on 2026-08-27.

## Capacity and governing constraint

The current V2 candidate uses `$3F47/$4000` in Home ROM (185 bytes free)
and ends at `$DFD3` in EXROM (45 bytes free). The shared
program/array/scalar RAM pool is 15,310 bytes. These figures come from
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
| INPUT | Was an unchecked Home-resident numeric-only loop | Moved to EXROM; now accepts numeric or 31-character string scalars and bounds numeric input |

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
