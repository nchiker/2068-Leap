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

## Flood-fill rewrite: attempted, algorithm verified, reverted on ROM cost

**Update (2026-09-13, later in the same session):** attempted, fully
implemented, Python-verified correct — then deliberately reverted, because
it turned out to be a bad trade for THIS project's actual bottleneck.

This project already has flood fill (`kernel/graphics/graphics.asm`'s
`GFX_FILL`, BASIC's `FILL` statement) — unlike the graphics words above,
this isn't a missing capability, it's a RAM-cost question in working code.

**Original cost, confirmed from `include/sysvars.inc`:**

- `GFX_FILL_STACK`: 4096 bytes (2048 x/y pixel entries) — per-pixel design.
- `GFX_FILL_VISITED`: 6144 bytes (1-bit-per-screen-pixel dedup bitmap).
- Total: 10,240 bytes, out of a 15,322-byte RAM pool (`make budget`) — 67%.

### What was done

Ported 2068-Leap-Forth's own already-shipped span-based `GFX_FILL` design
(scan each row for contiguous same-target runs, push one seed per run
instead of per pixel, GFX_FILL_SCAN_ROW finds new runs on the row
above/below bounded to exactly the span's own width) to this project's own
`kernel/graphics/graphics.asm`, replacing `GFX_FILL_TRY_NEIGHBOR` with new
`GFX_FILL_VISITED_CHECK`/`GFX_FILL_SCAN_ROW` routines and rewriting
`GFX_FILL` itself.

**Independently Python-verified before writing the change up here** (not
just trusting 2068-Leap-Forth's own numbers): built a reference
breadth-first flood fill and compared it pixel-for-pixel against a direct
Python port of the exact span algorithm, over TS2068's real 256x192
screen, across: a solid box (both a background fill around it and a
same-value RECOLOR of the box itself — the specific trap this project's
own `GFX_FILL` header already documents once, where target==new_val means
the pixel's own state can't distinguish "already handled" from "still
needs handling"), a blank enclosed square, a full-screen fill in both
directions, a hollow ring, an irregular blob, a solid disc recolored, and
two adversarial synthetic shapes. All matched the reference exactly.

The two adversarial shapes are worth recording precisely, since they
extend 2068-Leap-Forth's own testing: a fine single-pixel-wide "comb"
bridged top and bottom peaked at 252 stack entries; a **more aggressive
multi-bridge comb** (a bridge row every 3 rows, not just top/bottom, to
test whether cascading fragmentation compounds) peaked at **15,876
entries** — nearly 3x 2068-Leap-Forth's own reported worst case (5986) for
their single-bridge comb. This is far beyond anything a real
PLOT/LINE/CIRCLE/RECT-bounded paint-bucket region would produce, and the
algorithm's own documented graceful-truncation behavior (already accepted
for the old per-pixel version too) handles it without crashing — but it's
a genuine data point that adversarial inputs can exceed even a generously
sized stack, not just a small one. 512 entries (1024 bytes) — matching
2068-Leap-Forth's own shipped size — comfortably covers every realistic
shape tested (peak 7 entries) and a genuinely adversarial single-bridge
comb (252).

### Why it was reverted: a bad trade for this project's actual bottleneck

The rewrite's Home ROM cost was measured precisely from the assembled
listing (`build/test_basic.lst`, before/after): the old
`GFX_FILL_TRY_NEIGHBOR` + `GFX_FILL` was 180 bytes; the new
`GFX_FILL_VISITED_CHECK` + `GFX_FILL_SCAN_ROW` + `GFX_FILL` was 392 bytes
— **+212 bytes of Home ROM** to save 3072 bytes of RAM pool.

Home ROM had only 18 bytes free at the time (this session's own editor
shrink pass, `76e80ee`, had just gotten EXROM to 32 free — Home ROM was
untouched and still tight). The rewrite overflowed Home ROM by 194 bytes
and wouldn't assemble
(`sjasmplus_strict: refusing truncated/overflowed image`). Meanwhile the
RAM pool already had 5082 bytes free *with the old, larger fill stack* —
RAM was not the binding constraint for this project the way
`NOTES_FROM_DESCENDANTS.md` item 3's general "RAM is tight for a TS2068
project" framing assumed. Trading 212 bytes of the genuinely scarce
resource (ROM, 18 bytes free) for 3072 bytes of the genuinely abundant one
(RAM, 5082 bytes free) is a bad trade specifically here, even though the
same rewrite was clearly worth it for 2068-Leap-Forth's own, differently-
constrained ROM/RAM balance.

Reverted cleanly (`kernel/graphics/graphics.asm` and `include/sysvars.inc`
back to their prior committed state); `GFX_FILL` is unchanged from before
this session.

## If either is picked up later

- Graphics words: resolve the bank-selection question first (see
  `docs/dock_cartridge.md`'s related DECR/HSR mutual-exclusivity
  discussion — any second-bank mechanism here will run into the same
  DOCK-vs-EXROM global-switch hardware constraint if it tries to reuse the
  DOCK slot for extra ROM capacity).
- Flood fill: the algorithm is proven correct (this session's own Python
  verification above) and ready to re-apply verbatim once Home ROM has at
  least ~212 bytes of free headroom to absorb it — a ROM-shrink pass
  elsewhere in `kernel/graphics/graphics.asm` or another Home ROM module
  would unlock it directly, no further algorithm work needed. Once it
  fits, still confirm under live ZEsarUX/Fuse across multiple shapes
  (solid region, enclosed blank region, full-screen fill, a recolor) the
  same way this session verified the editor shrink pass — a register/
  memory read plus a real rendered screenshot, not just a clean assemble
  — before calling it shipped.
