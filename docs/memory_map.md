# 2068 Leap — Memory Map

Status: DRAFT — living document, updated alongside code.

## Physical address space (48K stock machine, no add-on RAM assumed as baseline)

| Range         | Size  | Use                                                          |
|---------------|-------|---------------------------------------------------------------|
| $0000-$3FFF   | 16K   | ROM (this project) — ROM0, always paged in on TS2068 unless HOME/EX-ROM banking used |
| $4000-$57FF   | 6K    | Screen display file (bitmap), standard Spectrum-compatible layout |
| $5800-$5AFF   | 768B  | Screen attributes |
| $5B00-$7FFF   | ~10.3K | Reserved for the video hardware's own use (see below) — nothing this project owns lives here |
| $8000-$BFFF   | 16K | System variables (`include/sysvars.inc`, starting at $8000) followed by the dynamic BASIC program/array/scalar pool (`PROG_AREA_START`=$B8C9 through $BFFF) |
| $FF00-$FFFF   | 256B  | BASIC/machine stack (grows down from `$FF00`) |

**Why `$5B00`-`$7FFF` is off-limits, not just "reserved for later":** the
TS2068 has two *physically separate* RAM chip pools, not one pool with
video sharing part of it — a dedicated 16K "Video Display RAM" at
`$4000`-`$7FFF` (two 4416 chips, wired directly to the SCLD's video
address generation logic) and a completely separate 32K general RAM at
`$8000`-`$FFFF` (four more 4416 chips), per the TS2068 Technical
Reference Manual. In Standard video mode only `$4000`-$5AFF` of that
16K pool is used; the rest sits idle. But the "High Resolution
Graphics" and "64-Column"/Dual-Screen video modes use the *entire*
16K pool — the second display file and its attribute bytes live at
`$6000`-`$77FF`, fixed by the hardware, not relocatable by software.

This project's system variables originally started at `$5D00` —
chosen, evidently, to mirror where the *stock* Spectrum/TS2068 ROM
puts its own system variables (`$5C00`), the same inherited-convention
pattern the old UDG-area note above used to call out explicitly
("mirrors 48K Spectrum convention"). That put this project's entire
custom RAM region inside the video hardware's own dedicated chip pool
— harmless while only Standard mode existed, but a real conflict once
`CIRCLE`/`BLOCK`/`CPLOT` work led to designing `MODE`/`PALETTE` and
that fact got checked against the real hardware manual instead of
assumed. Migrated the whole region to `$8000`+ instead of trying to
carve out just enough space to avoid the second display file — a
permanent fix (works for every current and future video mode, no
runtime relocation, no "not enough memory" failure tied to switching
modes) rather than a narrow patch, and explicitly *not* copying the
stock ROM's own answer to this same problem (`CHNG_VID` dynamically
relocated the machine stack and OS RAM routines out of the way only
when a program actually needed the second display file, and gave an
Out-of-Memory error if the shuffle didn't fit) — a fragility this
project doesn't need to inherit given real, physically separate RAM
to just use instead.

## TS2068-specific considerations (to be filled in as hardware work proceeds)

- Home Bank / Exrom / Dock paging: this project's own ROM0 (Home Bank) is **16K**,
  occupying the full $0000-$3FFF shown in the table above — confirmed empirically by
  Fuse rejecting an 8K `rom0.bin` for `--rom-ts2068-0`, correcting this doc's earlier
  (wrong) 8K assumption. A second banked ROM1 is reserved for extended kernel routines
  (graphics/sound extensions) so the stock BASIC + editor experience fits in ROM0 alone
  on a machine with nothing in the Dock. ROM1's exact size is not yet confirmed the
  same way ROM0's was — treat 8K as a placeholder until tested against Fuse or real
  hardware, not a confirmed fact.

  **EXROM paging design (2026-08-18), verified against the real Timex Sinclair 2068
  ROM Disassembly (David Anderson, 2023) — see `EXROM.txt`'s `OPDFIL`/`CLDFIL`/`INT`/
  `EXTINIT` routines, not just the TRM's port description:**
  - Port `$F4` (Horizontal Select Register) selects, per 8K chunk (A13-A15 decode —
    8 chunks total, chunk N = `$0000 + N*$2000`), whether that chunk comes from Home
    or from an alternate bank; port `$FF` bit 7 picks which alternate bank `$F4`
    refers to (1=EXROM, 0=Dock — mutually exclusive).
  - **Chunk 6 ($C000-$DFFF) is the reserved EXROM paging target.** Chosen because:
    general RAM (not video RAM — sidesteps an still-unconfirmed question about
    whether video generation reads display RAM independently of `$F4`, since chunk 6
    never touches that question at all), architecturally distant from both live
    sysvar/`FOR_STACK`/`PROG_AREA_START` state (chunk 4, `$8000-$9FFF`) and the
    machine stack (chunk 7, `$E000-$FFFF` — **never page this chunk**: if `SP` is
    paged out, the next `push`/`call`/interrupt write goes nowhere). Independently
    corroborated by the stock ROM's own `EXTINIT` routine, which marks chunks 3, 4,
    and 6 as the ones safe to hand to expansion banks when nothing more specific
    claims them (`LD C,$58` — bits 3/4/6) — Timex's own engineers picked chunk 6 as
    expendable too, for unrelated reasons (memory-expansion units), independent
    confirmation rather than something this project derived on its own.
  - Chunks 0-1 (Home ROM itself, incl. every RST vector — `$0038`/`RST_38` is this
    project's real interrupt handler, `KBD_ISR_TICK`) are never paged — EXROM
    doesn't replace Home's own code footprint, it occupies a chunk that's normally
    RAM in the Home map.
  - **Interrupt safety**: the stock ROM's own `INT` handler treats an interrupt
    firing during a bank-switch-sensitive window as a real hazard, not something
    safe by construction — it explicitly `DI`s on entry, snapshots every bank's
    status (`SAVE_STATUS`), forces a known-safe configuration for its own keyboard
    work, then restores the caller's exact paging (`RESTORE_STATUS`) before `EI`.
    This project doesn't need that general machinery — `KBD_ISR_TICK`'s own sysvars
    all live in chunk 4, never chunk 6, so simply never paging chunk 0/1 already
    keeps the ISR fully reachable and correct regardless of what's in chunk 6 at any
    given moment. What this project's own EXROM trampoline DOES need to copy from
    the stock pattern: **run the paging window itself with interrupts off** — `DI`
    before writing `$F4`/`$FF`, `EI` only after Home paging is fully restored —
    mirroring `OPDFIL`'s own discipline around its bank-sensitive stack/UDG moves,
    not assumed safe without it.
  - **Completed:** `PROG_AREA_MAX` is `$C000`, formally reserving chunk 6.
    Program editing grows only up to the live `VARS_START` boundary, which itself
    cannot exceed that ceiling. `BASIC_DO_LOAD` passes the same live maximum length
    to `STORAGE_LOAD`; the header length is rejected before the data block starts if
    it would cross the boundary. An oversized or corrupt header therefore cannot
    overwrite EXROM's Home-side window or the machine stack.
- AY-3-8912 sound chip: accessed via its standard TS2068 port pair; kernel-owned driver
  in `kernel/sound` (not yet written) exposes register-write and note-table APIs to
  `sound/` and `basic/` — BASIC never writes AY ports directly.
- Extended screen modes (High Resolution Graphics / Dual Screen): port `$FF`
  values and hardware behavior confirmed against the manual (see `docs/programmers_
  reference.md`'s Tier 3 writeup). `MODE 0`/`1` are implemented; `PLOT`/`LINE`/`BLOCK`/
  `CIRCLE`/`CPLOT` all draw correctly in both. Dual Screen mode itself is not
  implemented at all. (64-Column mode and its SCLD palette selector existed briefly and were
  removed 2026-08-20 — real overhead versus value; see `docs/programmers_
  reference.md` and `docs/basic_language_reference.md` for the writeup.) The
  later ULAplus `ULAPLUS`/`PALETTE index,value` interface is independent and
  consumes no RAM palette table.

## System variables block (kernel-owned)

Lives entirely in the general 32K RAM pool now (`$8000` onward — see the migration
note above), owned by `kernel/memory`/`kernel/editor`/`basic/`. Every system variable
gets: symbolic name (in `include/sysvars.inc`), fixed address, size, and one-line
purpose, cross-referenced from the Programmer's Reference.

## Open questions / TODO
- Re-evaluate stack budget before adding editor search or deeper structured
  control-flow features; the current editor, BASIC, fill, and GOSUB stacks
  are allocated and tested.
- Reclaim or relocate additional cold code before expanding the language;
  the V2 candidate has 227 Home-ROM bytes and 100 EXROM bytes free.
  `make budget` is authoritative as these figures change.
- **Label table**: the current top-level implementation is working and
  checked on every commit and before `RUN`. Revisit its fixed capacity when
  procedures introduce nested scopes.
- [stated] intends to eventually audit past decisions across the whole project
  for other places convention from the original 2068 ROM/memory map got
  inherited without being separately reasoned about (the sysvar-start-address
  history above is one confirmed example) — separate from, and doesn't block,
  any work already done or in progress.
