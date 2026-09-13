# Graphics extension opportunities — open work, not yet started

Status: **investigated, not implemented.** No code changes from this file.
See `NOTES_FROM_DESCENDANTS.md` item 3 for how this was first raised, from
sibling project `2068-Leap-Forth`'s own graphics work (a second, physically
real 8K EXROM bank adding `RECT`/`POLYGON`/sprite words, plus a flood-fill
rewrite).

## New graphics words (RECT, POLYGON, sprites): blocked on ROM/bank budget

2068-Leap-Forth added these as a **second, separate 8K EXROM bank** — its
own base dictionary EXROM and this graphics bank are two different images,
selected one at a time.

This project has no equivalent bank-selection mechanism. `kernel/bank/
bank.asm`'s `BANK_PAGE_EXROM_IN` pages in exactly one fixed 8K EXROM image
(chunk 6, `%01000000`) — there's no second bank to select between. The
current single EXROM bank has 28 bytes free (`make budget`, as of this
session's own editor shrink pass — see the `76e80ee` commit; it was 13
before that). Real hardware has no free EXROM capacity beyond one 8K (or a
verified 16K) chip per the vendored `ts2068-cartridge-development` skill's
own `memory-banking-faq.md`: *"smart cartridges larger than 64K need their
own paging register/protocol; native HSR alone addresses only the eight
fixed DOCK chunks."*

Adding `RECT`/`POLYGON`/sprite words here would need either:

- a real ROM-shrink pass across the existing EXROM content deep enough to
  free several hundred bytes to a few KB (the new words' likely cost, going
  by 2068-Leap-Forth's own bank size), or
- a genuine second bank-select mechanism, which this project's own
  hardware model doesn't have today and would itself be a real design
  project (related to, but distinct from, the DOCK/EXROM banking hazard
  documented in `docs/dock_cartridge.md`).

Neither was attempted here. The numeric pitfalls 2068-Leap-Forth found
while building these words remain useful reference if this is picked up
later — see that project's `core/rectfill.asm`, `core/polygon.asm`,
`core/sprite.asm`:

- A naive per-scanline polygon-edge formula (`x0+(y-y0)*(x1-x0)/(y1-y0)`)
  overflows a signed 16-bit multiply at realistic TS2068 coordinate ranges
  (product can reach ~48700). Bresenham y-major incremental stepping
  avoids the multiply/divide entirely.
- The Bresenham error accumulator needs 2 bytes per edge, not 1 — the real
  worst case for this screen size (dy up to 191, dx up to 255) can reach
  446 before normalization.

## Flood-fill rewrite: real opportunity, deliberately not attempted here

This project already has flood fill (`kernel/graphics/graphics.asm`'s
`GFX_FILL`, BASIC's `FILL` statement) — unlike the graphics words above,
this isn't a missing capability, it's a RAM-cost opportunity in working
code.

**Current cost, confirmed from `include/sysvars.inc`:**

- `GFX_FILL_STACK`: 4096 bytes (2048 x/y pixel entries) — per-pixel design.
- `GFX_FILL_VISITED`: 6144 bytes (1-bit-per-screen-pixel dedup bitmap).
- Total: 10,240 bytes, out of a 15,322-byte RAM pool (`make budget`) — 67%.

2068-Leap-Forth's own `GFX_FILL` (`kernel/graphics/graphics.asm` there)
already made exactly this rewrite: its own `GFX_FILL_STACK` is 1024 bytes
(512 x/y entries — spans, not individual pixels), while its own
`GFX_FILL_VISITED` stays 6144 bytes (screen-sized dedup is needed
regardless of stack representation, to distinguish "still background" from
"already filled to the new color this same fill" — see that project's own
comment on why). Porting that same span-based stack technique here would
save roughly 3072 bytes of RAM pool (4096 -> ~1024), the same proportional
win, without needing any extra ROM budget (a pure RAM/algorithm change, not
new dictionary surface).

**Why this wasn't attempted directly in this session, despite being
well-scoped:** this project's own `GFX_FILL` header documents a real
history — two previous subtle correctness bugs (an XOR/erase mode bug and
a cell-granularity dedup bug), both found via real hardware testing on
2026-08-20, both requiring the current design (OR-only writes, a separate
per-pixel `GFX_FILL_VISITED` bitmap independent of both the bitmap write
and the attribute cell) to fix correctly. The header also states the
current 2048-entry stack size was deliberately re-verified in Python
against real worst-case shapes (a solid 51x51 box, a blank 51x51 enclosed
region, a full 256x192 screen fill) before shipping. A span-based rewrite
is a materially different algorithm — scan each row for contiguous
same-target spans, push one stack entry per span instead of per pixel, and
seed new spans by scanning the rows above/below each span's own horizontal
extent — with its own edge cases (span-boundary determination, avoiding
double-visiting a span from both a left and right neighbor check). Given
the working code's own documented bug history, this needs the same rigor
that code already went through (Python-verified worst-case shapes before
shipping, then live emulator confirmation across multiple shapes, not just
a clean assemble) to be trustworthy — real, bounded work, but risky to rush.

## If either is picked up later

- Graphics words: resolve the bank-selection question first (see
  `docs/dock_cartridge.md`'s related DECR/HSR mutual-exclusivity
  discussion — any second-bank mechanism here will run into the same
  DOCK-vs-EXROM global-switch hardware constraint if it tries to reuse the
  DOCK slot for extra ROM capacity).
- Flood fill: Python-verify the span algorithm against the same worst-case
  shapes `GFX_FILL`'s own header already lists before writing any Z80,
  then confirm under live ZEsarUX/Fuse across multiple shapes (solid
  region, enclosed blank region, full-screen fill) the same way this
  session verified the editor shrink pass's own behavioral-equivalence
  claim — a register/memory read plus a real rendered screenshot, not
  just a clean assemble.
