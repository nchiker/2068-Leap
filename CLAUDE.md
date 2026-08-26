# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

An alternate-history ROM for the Timex Sinclair 2068: structured BASIC (no
line numbers — labels + GOTO instead), a full-screen editor, AY sound, and
TS2068-specific graphics, built as documented Z80 assembly kernel modules
instead of the tangled monolith of the original ROM, while still fitting a
stock 48K machine (16K Home ROM + 8K EXROM) and staying instant-on.

`sjasmplus` and `fuse` are both installed in this environment (`which
sjasmplus fuse`) — build and run everything for real rather than reviewing
by eye. (Older docs/commit messages in this repo say sjasmplus wasn't
available when this scaffold was authored; that's no longer true here.)

## Build & test commands

Every build is `sjasmplus <file>.asm` producing a `.bin`, run via
`fuse --machine ts2068 --rom-ts2068-0 <home>.bin --rom-ts2068-1 <exrom>.bin`.
Most test binaries signal pass/fail via **border color** (green = pass, red
= failure) since there's no serial/stdout on this hardware target. Full
per-module instructions (exact expected behavior, sample BASIC programs to
type, etc.) are in `README.md`'s "Testing ..." sections — read the relevant
one there before testing a module, this file only lists the invocations.

```sh
# Home ROM (16K, $0000-$3FFF) + EXROM (8K, $C000-$DFFF paged into chunk 6)
sjasmplus rom/test_basic.asm      # main interactive BASIC REPL test target
sjasmplus rom/exrom_build.asm     # builds exrom.bin — REQUIRED alongside any
                                   # Home build since basic.asm calls into it
                                   # (checker, SAVE/LOAD, HELP, calculator)
fuse --machine ts2068 --rom-ts2068-0 test_basic.bin --rom-ts2068-1 exrom.bin

# Individual kernel-module tests (green/red border pass signal)
sjasmplus rom/test_memory.asm     # kernel/memory
sjasmplus rom/test_math.asm       # kernel/math
sjasmplus rom/test_io.asm         # kernel/io (interactive)
sjasmplus rom/test_editor.asm     # kernel/editor (interactive)
sjasmplus rom/test_graphics.asm   # kernel/graphics (visual — check glyphs by eye)
sjasmplus rom/test_exrom_isolation.asm  # EXROM paging (kernel/bank)
sjasmplus rom/main.asm            # Milestone 0 boot stub (border-cycle smoke test)
```

Static checks — no assembler needed, run these before considering any
non-trivial `.asm` change finished:

```sh
python3 tools/check_asm.py [file ...]   # defaults to basic/basic.asm
python3 tools/check_docs.py             # run after adding a font glyph,
                                         # punctuation mapping, or HELP topic
```

`check_asm.py` catches three bug classes this project has actually shipped:
duplicate global labels, a stray bare (non-dotted) label silently ending
sjasmplus's local-label scoping for everything after it in the file (this
project's single most expensive debugging arc — an entire test round chased
a bug in code that had never actually assembled), and a stack-ordering
fingerprint (a routine `pop`ping before it's pushed anything of its own).
`check_docs.py` cross-checks counts quoted in docs (font glyph count,
punctuation count, HELP topic coverage) against the real source tables.

`tools/z80sim/sim.py` is a source-level Z80 simulator (parses this
project's own `.asm` directly, no assembly step) for replaying a specific,
already-narrowed-down routine against concrete seeded state — built after
hand-tracing and "reasoned" Python translations repeatedly missed a real
register-clobber bug that faithfully replaying the actual instructions
caught immediately. Not a general emulator; supports a working instruction
subset only (see `tools/z80sim/README.md` for exact limitations). Reach for
it only after static analysis and hand-tracing are exhausted on a
reproducible bug.

`tools/preload_gen.py <program.txt> <output.asm> [PROGNAME] [--autorun]`
encodes a plain-text BASIC listing straight into this ROM's program-area
storage format and emits a ready-to-assemble test harness that boots
straight into it — skips typing the program by hand in Fuse for repeatable
manual tests. `--autorun` runs it immediately instead of dropping into the
editor (yellow border = whole-program check failed; otherwise whatever
border the program's own `BORDER` statement last set is the verdict).

`tools/run_suite_test.sh <name>` is the one-command wrapper for the
`tests/<name>.txt` regression suite: builds (once — cached) `rom/
test_suite_inject.bin`, generates a Fuse `--debugger-command` injection
script via `tools/fuse_suite_inject.py`, launches Fuse headless,
screenshots to `/tmp/suite_<name>.png`, retries once if Fuse's CPU time
looks stuck. `tests/` covers arrays (`arr*`), control flow (`cf*`),
errors (`err*`), I/O/PEEK-POKE (`io*`), math (`math*`), strings (`str*`),
memory/`FREE()`/`DIM` accounting (`mem*`), graphics primitives via
`POINT()` readback (`gfx*`), sprites via `SPRITE_SLOT_*` sysvar readback
(`spr*`), sound (`snd*`), `USR` (`usr1`), and misc language features
(`misc*`) — see each fixture's own `.txt` for what it checks.
`tools/run_all_tests.sh` runs every `tests/*.txt` fixture and prints a
PASS/FAIL summary — knows that `err1`/`mem2`/`snd3` are deliberate
negative tests whose correct pass signal is a cyan border (error
correctly raised and halted before reaching their own final green
`BORDER`), not a failure; see that script's own header before adding
another fixture to its `EXPECTED_CYAN` list.

**Superseded (2026-08-23): the old `tools/preload_gen.py --autorun`
approach baked each test's encoded program straight into the same 16K
ROM image as `basic.asm`, so `basic.asm` growth ate directly into every
fixture's own budget** (the "razor-thin margin" this note used to warn
about) — replaced with `rom/test_suite_inject.asm`, a reusable harness
nothing test-specific is ever baked into, plus Fuse-debugger injection
(same technique `tools/fuse_load_inject.py` already proved for SAVE/
LOAD) to poke each test's bytes into RAM at a stable breakpoint instead.
ROM budget is now permanently decoupled from test-program size — see
`docs/programmers_reference.md`'s "Scalar variables in the dynamic
pool" section for the full writeup (written for the migration that
prompted this, but the testing-infrastructure fix applies regardless of
future `basic.asm` growth). `tools/fuse_load_inject.py`'s OWN purpose-
built harnesses (`rom/test_storage_save_toolarge.asm`, the SAVE/LOAD
roundtrip test) still have the old problem and haven't been migrated
yet — they test the real SAVE/LOAD call path specifically, so `test_
suite_inject.asm`'s "skip straight to `BASIC_RUN`" approach doesn't
directly apply; would need its own analogous redesign.

**SAVE/LOAD status: real-ROM-derived transport, confirmed working in a
Fuse round-trip.** `kernel/storage/storage.asm` (the earlier
from-scratch tape protocol) was archived at `kernel/storage/archive/
storage.asm` (see that archive's own README.md for why) and replaced
with a direct, instruction-by-instruction-verified port of the real
TS2068 ROM's own SA-BYTES/LD-BYTES cassette routines (`Resource Docs/
Timex Sinclair 2068 ROM Disassembly.pdf`, repo root; real stock ROM
binary at `~/fuse-build/roms/tc2068-1.rom`) — see `kernel/storage/
storage.asm`'s own top header for the full protocol writeup, every
deliberate deviation from the real ROM, and the current known-status
note. SAVE has been directly verified: a real user-captured TZX
recording of its output was parsed and measured against the real ROM's
own timing constants and found to be a clean, correctly-timed signal.
LOAD now displays the matched filename and restores the saved program.
The decisive fix was restoring the stock LD-EDGE-2 fall-through into a
second LD-EDGE-1 measurement. `tools/fuse_load_inject.py`/`tools/
run_storage_roundtrip_test.sh`/`tests/storage_roundtrip1.txt` (the
OLD design's debugger-injection SAVE/LOAD test tooling, built for the
archived from-scratch protocol) remain archived in their own
directories' `archive/` folders and have not been adapted for the new
protocol.

## Architecture

### Layering and the kernel API contract

```
rom/        top-level assembly (ORG, INCLUDEs, RST vector table, entry points)
basic/      BASIC interpreter — calls kernel/ APIs ONLY, never touches hardware directly
kernel/     hardware-facing modules, reusable by any assembly software
  memory/   line storage, program iterator, label table (no line numbers — see below)
  editor/   full-screen editor (INSERT/DELETE/MOVE_CURSOR/REDRAW, nav/redraw hooks)
  io/       keyboard scanning + ASCII translation
  graphics/ text-mode + bitmap graphics (PLOT/LINE/BLOCK/CIRCLE/FILL/CPLOT, MODE)
  math/     16-bit signed multiply/divide (Z80 has neither in hardware)
  storage/  SAVE/LOAD -- stock-derived pulse routines and TS2068 framing,
            confirmed in a real Fuse round-trip
  bank/     EXROM paging trampoline (see EXROM section below)
  interrupt/interrupt handling
graphics/, sound/   top-level dirs, not yet started (empty)
include/    symbolic constants + kernel_api.inc, the kernel API contract
docs/       Programmer's Reference, BASIC Language Reference, Memory Map, Hardware Notes
tools/      static checkers, z80sim, preload generator
```

`include/kernel_api.inc` is the literal contract: **everything outside
`kernel/` calls only the `EXTERN`s declared there; nothing outside `kernel/`
touches hardware ports or system-variable addresses directly.** When adding
a new kernel routine callable from `basic/` or elsewhere, declare it there
first — `docs/rom_api.md`/`docs/programmers_reference.md` is the prose
mirror of the same contract and must stay in sync (checked by
`check_docs.py` for the specific tables it covers, otherwise by hand).

### No line numbers

The BASIC dialect has no classic line numbers. Programs are a flat sequence
of statements in `kernel/memory`'s program area; jumps use **labels**
(`name:` on its own line) resolved through a label table
(`MEM_LABEL_LOOKUP`/`_ADD`/`_REMOVE`), rebuilt fresh at the start of every
`RUN` rather than maintained incrementally through edits. `LIST`/`EDIT
<label>`/`DELETE <start>,<end>` address statements by their 1-based
position in the current listing (matching how a user reads top to bottom)
purely for command syntax — internal storage/iteration is still 0-based
throughout. A label can never share a line with another statement
(deliberate — keeps the colon statement-separator feature's risk to
labels/GOTO at zero).

### Home ROM / EXROM split (bank-switched memory)

The Home ROM is hard-capped at 16K (`$0000-$3FFF`, always paged in). When
that filled up, a second 8K image (EXROM, `exrom.bin`) was added, paged
into chunk 6 (`$C000-$DFFF`) via `kernel/bank/bank.asm`
(`BANK_PAGE_EXROM_IN`/`_OUT`, port `$F4`/`$FF` — hardware-confirmed on real
TS2068 hardware). `rom/exrom_build.asm` is the actual build driver
(`sjasmplus rom/exrom_build.asm` → `exrom.bin`); it `INCLUDE`s, in
address-sensitive order, `rom/exrom_checker.asm` (whole-program/statement
validator — must come first, declares all the fixed entry stubs),
`rom/exrom_storage.asm` (SAVE/LOAD), `rom/exrom_help.asm` (`HELP`), and
`rom/exrom_calc.asm` (the RST $28 calculator engine).

Since EXROM is a separate `sjasmplus` compilation unit with no linker, it
cannot call Home routines (`MEM_LINE_FIRST`, `BASIC_EVAL_EXPR`, etc.)
directly by label — those addresses shift on every Home-side edit. Calls
from EXROM back into Home go through the fixed-address jump table in
`include/exrom_jumptable.inc` (`KTAB_*`, generated by the `KTAB_LIST` macro
from one shared list, expanding to real `jp` trampolines on the Home side
and to `EQU` offsets everywhere else) — never add a direct `call`/`jp` from
EXROM code into a Home label. Chunk 6 was chosen because it's general RAM,
architecturally distant from live sysvar/stack state, and independently
confirmed expendable by the stock TS2068 ROM's own `EXTINIT` routine (see
`docs/memory_map.md` for the full hardware audit). Chunk 7 ($E000-$FFFF,
the machine stack) must never be paged.

### Memory map

RAM system variables + BASIC program area live at `$8000`+
(`include/sysvars.inc`), not the `$5D00`/`$5C00`-ish region a stock
Spectrum-family ROM would use — that region was deliberately migrated
after realizing it collided with the TS2068's own dedicated video RAM pool
(`$4000-$7FFF`, used in full by High Resolution Graphics / Dual Screen
modes, not just Standard mode). See `docs/memory_map.md` for the full
physical-RAM-pool reasoning; don't reintroduce sysvars below `$8000`.

### Recurring correctness lessons worth carrying forward

These are documented (with the specific bug each guards against) in
`docs/programmers_reference.md` and enforced partly by `tools/check_asm.py`
— worth internalizing since each has already caused a real, hard-to-find
bug in this codebase:

- **Register survival across calls**: know and respect what a routine's own
  header says it destroys (e.g. `MEM_LINE_NEXT` destroys `DE`); restoring a
  loop counter from the stack *before* rather than *after* calling such a
  routine silently corrupts state. Save/restore explicitly when a call's
  destroys-list conflicts with a value you still need.
- **Local label scoping**: a stray bare (non-dotted) global label anywhere
  in a file silently ends sjasmplus's local-label scope for everything
  after it — `check_asm.py` catches this; don't bypass it.
- **RST $28 is a `jp`, not `call`**: `RST_28` in `rom/main.asm` must remain
  a bare `jp CALC_ENTRY_TRAMPOLINE` — the calculator's literal-op-stream
  convention depends on the exact return address RST itself pushed.
- Every new sysvar goes through `include/sysvars.inc`, referenced only by
  its symbolic constant, never a hardcoded address (this let
  `PROG_AREA_START` move twice without touching call sites).

## Status / where to look next

`README.md` carries a detailed, chronological build log (what's
implemented, what's still a gap, exact bugs found and fixed, and full
interactive test scripts to type into Fuse for each feature) — check it
before assuming a feature is missing or before re-diagnosing a bug that may
already be documented there. `docs/programmers_reference.md` is the
authoritative per-module reference (routine-by-routine status tables);
`docs/basic_language_reference.md` covers the BASIC grammar; `docs/
hardware_notes.md` covers confirmed keyboard/hardware behavior.
