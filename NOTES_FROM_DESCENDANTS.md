# Notes from 2068-Leap-Forth and structured-basic-poc

`2068-Leap-Forth` started by copying this project's own hardware-facing
`kernel/` modules read-only, and `structured-basic-poc` treats this project
as reference material. Both have since diverged and found real things worth
feeding back — one confirmed bug severe enough to test directly rather than
just flag, plus several new capabilities and techniques. This is a menu to
pull from, not a diff to apply — nothing here modifies this project's own
sources.

Each item says whether it's a **confirmed bug** (tested directly against
this project's own build), a **likely gap** (same root cause as a confirmed
bug elsewhere, not independently re-tested here), or a **new capability**
(doesn't exist here yet).

## 1. ZEsarUX hides your entire EXROM under stock, unpatched ZEsarUX — confirmed bug, high severity

Tested directly against this project's own `build/ts2068rom_zesarux.bin`,
not inferred: booted it under both a stock ZEsarUX 13.0 (built from source,
unmodified) and the same build with one patch applied. Same ROM file, same
`--romfile` invocation, only the ZEsarUX binary differs.

**Patched ZEsarUX** — boots correctly, editor status bar visible:

![Patched: boots correctly](docs/images/zesarux_patched_boot.png)

**Stock, unpatched ZEsarUX** — completely blank screen:

![Stock: blank screen](docs/images/zesarux_stock_boot.png)

Checked *why*, not just *that*: a register read on the stock instance showed
`PC=$D241` — inside chunk 6 (`$C000-$DFFF`), exactly where `docs/
memory_map.md` documents this project's EXROM paging to. The CPU isn't
hung elsewhere; it's actively executing whatever garbage bytes stock
ZEsarUX actually has sitting in chunk 6, because stock ZEsarUX only mirrors
the physical EXROM image into chunk 0→1, not the other six chunks the real
hardware's own undecoded address lines mirror it into.

**Why this bites this project specifically, and why it may not have been
noticed yet:** the `kernel/editor` → EXROM migration (2026-08-22, per this
project's own README) moved the *entire* production editor into chunk 6 to
free Home ROM space. Before that move, chunk-6 content might have been
supplementary rather than load-bearing for the basic act of booting to a
usable screen; after it, the whole interactive experience depends on chunk
6 being visible. If ZEsarUX testing here has mostly used Fuse (which models
the real hardware's mirroring correctly) or a ZEsarUX build that happened
to already have some form of this fix, this might be a real, currently-live
gap for anyone else building from a plain upstream ZEsarUX clone.

**The fix**: `patches/0001-zesarux-mirror-ts2068-exrom.patch` (added to this
project's own `patches/` alongside the existing Fuse ULAplus patch — same
directory, different upstream project, unrelated to each other). Nine lines
changed in `src/machines/timex.c`, applies cleanly to upstream tag
`ZEsarUX-13.0`:

```sh
git clone https://github.com/chernandezba/zesarux.git
cd zesarux && git checkout ZEsarUX-13.0
git am /path/to/0001-zesarux-mirror-ts2068-exrom.patch
cd src && ./configure && make -j"$(nproc)"
```

Confirmed via direct A/B test as above — not by re-deriving the C change
and assuming it's correct.

## 2. PORT_FF_SHADOW likely never gets a real hardware baseline at cold start — likely gap, same root cause as a confirmed bug downstream

**Not independently re-tested against this project's own ROM** — flagging
based on source inspection plus a confirmed identical bug in the shared
downstream code this came from, so treat this one as "probably," not
"confirmed" the way item 1 is.

2068-Leap-Forth had a real, just-fixed bug: `COLD_START` zeroed
`PORT_FF_SHADOW`'s RAM byte (via a bulk RAM clear) but never `OUT` a known
value to the *actual* hardware port `$FF`. Invisible under emulation (the
port and RAM both happen to start at 0 in every emulator tried); not
guaranteed on real hardware, where the port has its own arbitrary power-on
state independent of RAM contents. `structured-basic-poc` was checked too
and already does this correctly (explicit `out (PORT_SCLD),a` right after
zeroing the shadow).

This project's own `rom/test_basic.asm` `COLD_START` was checked directly:
it calls `MEM_COLD_INIT` (comment: "clear the complete `$8000-$BFFF` owned
RAM region before any sysvar, hook, bank depth, or **port shadow** can be
read" — explicitly aware of the shadow) and `MEM_INIT`, but no `out
($FF),a` or equivalent was found anywhere in `COLD_START` or in `kernel/
memory`'s own init routines. `include/sysvars.inc`'s own `PORT_FF_SHADOW`
here is the same variable, same comment style, same module lineage
2068-Leap-Forth inherited wholesale — this is very plausibly the *original*
copy of the exact bug just fixed downstream, not a coincidentally similar
one. Worth a direct check (grep for the shadow variable's own address,
confirm nothing ever `OUT`s a baseline to the real port before the first
`GFX_SET_MODE`-style read-modify-write) before deciding whether to fix it
here too.

## 3. New graphics words + a flood-fill rewrite: new capability

No `RECT`, `POLYGON`, or sprite equivalents found in this project's own
BASIC statement set. 2068-Leap-Forth just built exactly these (Rectangle
Fill, Polygon draw/fill via the even-odd rule, four-slot 16×16 sprites) as
a second, physically real 8K EXROM bank, plus rewrote its own flood-fill
routine from a per-pixel design (3328 bytes of stack) to a per-span one
(1024 bytes) — a technique that would matter here too if this project's own
graphics statements ever need a flood-fill and RAM is tight, which for a
TS2068 project it generally is.

The specific numeric pitfalls found, worth knowing in advance rather than
rediscovering the hard way, if BASIC-level `RECT`/`POLYGON`-style graphics
statements are ever added here:

- A naive per-scanline polygon-edge formula
  (`x0+(y-y0)*(x1-x0)/(y1-y0)`) overflows a signed 16-bit multiply at
  realistic TS2068 coordinate ranges (product can reach ~48700). Bresenham
  y-major incremental stepping avoids the multiply/divide entirely.
- The Bresenham error accumulator for that algorithm needs 2 bytes per
  edge, not 1 — the real worst case for this screen size (dy up to 191, dx
  up to 255) can reach 446 before normalization.
- A flood fill that can't distinguish "still background" from "already
  filled to the *new* color during this same fill" either stops
  immediately or loops forever when recoloring an already-solid region.
  Needs an independent visited-bitmap, not just a color comparison.

Source to read for the full algorithms and the real Z80-level bugs found
building them (not just the Python-verified design): 2068-Leap-Forth's
`core/rectfill.asm`, `core/polygon.asm`, `core/sprite.asm`,
`kernel/graphics/graphics.asm`'s `GFX_FILL`.

## 4. Downloadable build/release pipeline: new capability

This project's own `.github/workflows/check.yml` is a build-and-check gate
only (assembles, runs `make check`/`make budget`) — no packaged, downloadable
release artifact. 2068-Leap-Forth just landed a pipeline worth copying the
shape of: SjASMPlus built from source and cached, the existing check gate
kept as a prerequisite, then a `make dist` step packaging ROM images, symbol
listings, and docs (Markdown + PDF via pandoc/WeasyPrint + DOCX) into a
versioned zip with a SHA-256 alongside it — published as a workflow artifact
on every run, a rolling "latest" pre-release on every push to the default
branch, and a numbered release with generated notes on every version tag.

Source to adapt: `2068-forth/.github/workflows/build.yml`, `2068-forth/
tools/package_dist.sh`, `2068-forth/tools/build_docs.sh`.

## 5. DOCK/LROS cartridge build: recommended for this project too

David Anderson (who contributed 2068-Leap-Forth's own DOCK cartridge build)
made the case this is worth having on every TS2068 project: the only way to
run on real hardware, or a peripheral like TS-Pico, without reflashing the
machine's own ROM socket. This project already has its Home ROM at
`$0000-$3FFF` with a plain `RST_00: di : jp COLD_START` stub — the same
shape 2068-Leap-Forth's own cartridge build starts from. The technique:
replace that reset stub with a 5-byte in-ROM LROS header (type 1, entry
address, chunk-spec byte, per TS2068 Technical Manual §5.1.1), add a small
entry stub in the low, normally-unused gap after the NMI vector that does
`DI` (the stock ROM hands off with interrupts already enabled) then falls
into the normal cold start, and wrap the result in the usual 9-byte
Fuse/ZEsarUX `.dck` container. Confirmed booting cleanly under both Fuse
(`--dock`) and stock, unpatched ZEsarUX with the genuine factory ROM, and
(a real person typing, not scripted input) confirmed handling live
interactive keyboard input correctly too.

This project's own EXROM lives at chunk 6, not chunks 0-1, so there's no
collision the way there would be for `structured-basic-poc` (whose EXROM
sits at chunk 1, the same chunk a 16K DOCK cartridge needs) — a cartridge
build here should be a comparatively direct port of the same
`IFDEF CARTRIDGE` technique.

Source to copy from: `2068-forth/rom/forth_boot.asm`'s `IFDEF CARTRIDGE`
blocks, `2068-forth/tools/make_dck.py`.

## 6. A much smaller full-screen editor architecture exists — worth knowing, not a drop-in swap

`structured-basic-poc`'s own `EDITOR_DESIGN.md` describes a full-screen
editor built explicitly as a reaction to "the full integration cost of the
Spectrum 128 or TS2068ROM editors" — its own words, naming this project
directly. Original budget: 1,800 EXROM bytes (achieved at 1,739; later
revised to 2,100 once named SAVE/LOAD was added), versus this project's own
`exrom_editor.asm` at roughly 918 lines of source (not directly comparable
to a byte count, but a different order of scale).

The size difference partly comes from a genuinely different data model —
`structured-basic-poc` has no line numbers at all, storing NUL-separated
statement records instead, which this project's own numbered-BASIC-program
model can't simply adopt wholesale. What *is* portable, independent of the
data model: an inverse-attribute cursor with only horizontal-movement
redraws instead of a full-screen repaint on every keystroke; deliberately
**not** allocating a large screen-line mirror ("do not allocate a 735-byte
screen-line mirror like the Spectrum 128 editor" is stated as a direct
design rule); and hard, pre-declared byte budgets checked *before* writing
code, with an explicit rule to stop for a consolidation pass rather than
silently blow past the budget. If this project's own editor ever needs
another shrink pass (it's already been through at least one — the
whole-module-to-EXROM move), these are concrete techniques already proven
to work on the same hardware, not theoretical ones.

## 7. Two new testing skills: worth having available

Both written this session, both portable to any TS2068 ROM project. If
working in this project via Claude Code, worth pointing a session at
directly (`2068-forth/.claude/skills/`, copy the whole directory):

- **`zesarux-zrcp`** — launching ZEsarUX headless and driving it entirely
  over its remote protocol (this is how item 1 above was actually tested,
  not just asserted): border-color pass/fail, screenshots, memory reads,
  simulated keyboard input, breakpoints, plus the specific gotchas that
  cost real time — `send-keys-ascii` silently drops batches of ~6+ key
  codes, breakpoints don't reliably fire inside a paged-in EXROM bank (see
  item 8), and **`pkill -f <pattern>` is unsafe for cleaning up a ZEsarUX
  process from inside an AI coding session** specifically, because the
  pattern text is usually present in the invoking shell's own command line
  too, and `pkill -f` only excludes its own PID, not its parent's.
  Confirmed directly: `pkill -9 -f zesarux` followed by a plain `echo` in
  the same shell call killed the shell before the `echo` ran. Use `ps aux |
  grep -i zesarux | grep -v grep | awk '{print $2}' | xargs -r kill -9`
  instead.
- **`tsrun-headless`** — running [TSRun](https://github.com/josef-jelinek/TSRun)'s
  real, open-source Z80 core headlessly under Node, for a second
  independent emulator cross-check without needing a browser.

## 8. In-ROM debug-log technique: methodology, always applicable

A hardware breakpoint set at an address inside a paged-in EXROM bank was
confirmed *not* to fire reliably under ZEsarUX's ZRCP debugger while
building 2068-Leap-Forth's own graphics extension — likely relevant here
too, given this project's editor and BASIC extensions now live in EXROM
chunk 6 as well. The reliable fallback that root-caused a real Bresenham
sign-comparison bug there: pick a few bytes of genuinely idle RAM, write
whatever needs inspecting at the point of interest, read it back with
`read-memory` after the run completes. Give each checkpoint its own byte —
reusing one scratch address across stages erases evidence of earlier-stage
state before it can be read back.
