# R10.7 Memory Architecture Feasibility — Static Zones vs. Workspace Manager vs. Hybrid

**Status: feasibility study with isolated, non-production spikes. Nothing here is
implemented in production and nothing is approved.** The production RAM map,
capacities, `FREE()`, FILL, and all limits are unchanged. The keyword-rendering work
(EXROM +157 B recovered) is preserved. This document builds on
`R10_7_PRODUCTION_RAM_ARCHITECTURE_AUDIT.md`, which it corrects in four places (§12).

> **REVISION 2 — read §15 first.** After the product goal "not substantially more
> restrictive than stock TS2068 BASIC when RAM is available" was stated, §6's
> "raise the fixed limits" recommendation was **withdrawn** and replaced by §15:
> *compile-sized run tables, a single tagged compile symbol table with in-code
> forward chains, and one memory-limited control stack*. It removes the limits
> instead of doubling them, at a **similar or better ROM cost**, with **no general
> memory manager** and **no bytecode-format change**. §§1–5, 8–11 stand; §6 and §14
> are superseded where they conflict; §10's capacity table is recomputed in §15.9.

Evidence grades:

* **MEASURED** — assembled bytes (`sjasmplus` output, `build/*.sym`), or observed in
  the production ROM under `ts2068-debug`.
* **TRACED** — read from production source (file/label cited).
* **ESTIMATE** — arithmetic or Z80 byte counting that was not assembled.
* **UNVERIFIED** — plausible, not proven.

Artifacts added by this study (all non-production, none referenced by any Makefile
target or production image):

| File | Purpose |
|---|---|
| `tools/spikes/ws_manager_spike.asm` | Workspace Manager spike + 12 behavioural tests |
| `tools/spikes/sym_consolidation_spike.asm` | table-driven symbol-routine spike + 9 tests |
| `tools/spikes/run_ws_spike.sh`, `tools/spikes/run_spike.sh` | headless runners (border 4 = PASS) |

---

## 1. Verdict

**Recommended: Architecture A (static lifetime zones and overlays), with three
additions that need no allocator at all:**

1. a **descriptor-driven symbol-table routine set** (MEASURED spike: **−294 B** before
   adapters, ≈ **−255 to −265 B** HOME net), which is what actually makes the ROM
   budget better;
2. a **hazard fix** so editing source clears arrays (§8, ≈ 19–25 B EXROM, ESTIMATE);
3. **move the sprite buffers into hidden chunk 6 RAM** (§3). Package calls run with
   EXROM paged out, only one package is ever resident (`V2_LOAD` calls
   `EXT2_CLEAR_ALL` before every package load, TRACED), and SPRITE and SHAPES/FILL are
   therefore never resident together. The 2,304 B sprite reservation becomes a pure
   `EQU` change (0 B ROM) and returns that chunk-7 RAM to BASIC **whether or not
   sprites are used**.

The four-operation manager is cheap (37 B MEASURED) but, **on its own, it delivers no
BASIC capability**: the pool already *is* a two-ended arena
(`PROG_END`…`ARRAYS_END`…`VARS_START`), arrays already use a bump allocator, and the
one optional client that wanted an on-demand claim (sprites) is better served by a
static overlay in hidden RAM. What was actually missing is clearing arrays on edit.
A hybrid manager that also owns persistent BASIC data (architecture C) is **not
recommended**: it costs ROM and variable-access speed to solve problems a flat zone
table solves for free. A manager becomes worth its ≈ 64 B (core + high-end claim) only
if a *second runtime-sized persistent client* appears that cannot be given a static
overlay.

Headline numbers (grades in the sections that follow):

| Item | Result | Grade |
|---|---|---|
| Workspace Manager core (`WS_INIT/MARK/ALLOC/RELEASE`) | **37 B** ROM, **4 B** RAM | MEASURED |
| + persistent high-end claim `WS_ALLOC_HI` | **+27 B** | MEASURED |
| + ownership-checked release | **+15 B** | MEASURED |
| Symbol routines: production 599 B → spike 305 B (generic 145 + wrappers 136 + descriptors 24) | **−294 B**, ≈ −250 B net of adapters | MEASURED spike vs. MEASURED production; adapters ESTIMATE |
| Flat `VM_SYM_ADDR`+`VM_STR_ADDR` vs tiered | 25 B vs 70 B → **−45 B** | MEASURED sizes (instruction bytes) |
| Total HOME ROM recoverable from consolidation | **≈ −300 B** (HOME free 173 → ≈ 470) | MEASURED parts + ESTIMATE adapters |
| Source-edit/array corruption | **CONFIRMED** in production ROM | MEASURED |
| Sprite buffers in hidden RAM | feasible, 0 HOME/EXROM ROM, +2,304 B of chunk 7 | TRACED + hardware-confirmed paging test; relocation itself NOT run |
| Idle `$956B–$A454` region | **0 writes** across compile, 2× RUN (arrays, PROC recursion, strings) | MEASURED |
| Bytecode / source ratio | **≈ 0.5** (3 programs) → 4,011 B bytecode serves ≈ 8 KB source | MEASURED |

---

## 2. Complete RAM reservation inventory and what is genuinely reclaimable

Physical banking facts that govern every row (TRACED + MEASURED):

* Chunk 4/5 `$8000–$BFFF` and chunk 7 `$E000–$FFFF` are **always mapped** RAM.
* Chunk 6 `$C000–$DFFF` is **EXROM** while `BANK_EXROM_DEPTH > 0`, plain RAM otherwise.
  The VM and compiler run from EXROM or HOME; `OP_CALL_EXT` pages EXROM **out** around
  every package call. RAM written to chunk 6 persists while EXROM is mapped but is
  invisible to EXROM code. Therefore chunk 6 is usable **only by HOME-side code and
  packages**, never by the VM, the compiler, or BASIC data.
* The video RAM `$4000–$7FFF` second display file is hardware-owned.

Sizes and addresses are MEASURED from `build/*.sym` unless marked.

| # | Reservation | Size | Location | Lifetime | Ownership | Class | Reclaimable? |
|---|---|---:|---|---|---|---|---|
| 1 | System variables, live | ≈ 591 | `$8000–$8456` (interleaved) | permanent | kernel/editor/VM glue | permanent | no |
| 2 | System variables, **no production reference** | **520** | 25 runs in `$8000–$8456`; largest `$812C` 163, `$827F` 71 (V1 `FOR_STACK`), `$83AA` 64, `$8245` 44, `$83F4` 42 | — | V1 leftovers | **obsolete** | **yes, 520 B** (delete `DEFS`, `PROG_AREA_START` slides down) |
| 3 | Source/array pool | 4,094 | `$8457–$9454` | source permanent; arrays until RUN/CLEAR/NEW (see §8) | line store + `ARENA_ALLOC_*` | permanent | no (it *is* BASIC) |
| 4 | Scalar/string overflow tiers | 240 | `$9455–$9544` | **run only** | VM | overlayable | overlays #5 |
| 5 | Chunk buffer + state + ident buf | 278 | `$9455–$956A` | **compile only** | compiler | overlayable | overlays #4 |
| 6 | **Idle staging region** | **3,818** | `$956B–$A454` | none | none | **unused** | **yes, 3,818 B (verified, §9)** |
| 7 | Bytecode | 4,011 | `$A455–$B3FF` | RUN | VM | permanent while running | not reduced; reordering optional |
| 8 | Dense V2 table bank | 3,072 | `$B400–$BFFF` | mixed | compiler/VM/EXT2 registry | mixed | partially (§6) |
| 9 | EXROM code / FILL bitmap+stack | 8,192 | `$C000–$DFFF` | EXROM mapped; RAM only during package calls | HOME-side only | **hidden RAM** | **not usable by BASIC**; usable as package scratch |
| 10 | FILL stack tail | 2,048 | `$E000–$E7FF` | transient | FILL | transient, real RAM | **yes, 2,048 B** (stack fits hidden RAM at 2,048 B, 0 ROM) |
| 11 | Sprite image + background buffers | 2,304 | `$E800–$F0FF` | persistent once GRAB; never freed | SPRITE package only | **optional persistent** | **yes, 2,304 B: move to hidden chunk 6 (§3), 0 ROM** |
| 12 | Sprite slot metadata | 57 | `$82DE–$8316` (DEFINED/SHOWN/W/H/ROW/COL/DEPTH/STACK) | persistent | SPRITE package | optional | small; referenced by the package (my first scan wrongly marked 32 B of it dead — corrected) |
| 13 | `LABEL_TABLE_TOP` | 128 | `$F100–$F17F` | — | V1 label table | **obsolete** (no production reference) | yes, 128 B |
| 14 | `UDG_TABLE` | 72 | `$F180–$F227` | persistent | graphics kernel | referenced in production | keep |
| 15 | Edit/LOAD-name buffer + detokenizer buffer | 256 | `$F228–$F327` | permanent | editor, LIST, LOAD | permanent | no |
| 16 | `STR_FUNC_POOL` … `DEF_FN_*` | 135 | `$F328–$F3AE` | — | V1 | **obsolete** (no production reference) | yes, 135 B |
| 17 | `EXTENSION_*` V1 leftovers | ≈ 60 | `$F3B1–$F3FF` (3 runs) | — | V1 | obsolete (the `EXT_SERVICE_*` veneer entries `$F3BA–$F3C3` have no reference either; verify before touching, they are ABI) | ≈ 60 B (+10 B ABI-uncertain) |
| 18 | Package window | 1,024 | `$F400–$F7FF` | until next package load/CLEAR | EXT2 | permanent | no (package sizes: shapes 762, sprite 832, graphics 467, printer 345, mode 165) |
| 19 | Machine-stack headroom | 1,792 | `$F800–$FEFF` | permanent | hardware stack | reserve | partly (§6.4) |
| 20 | Machine stack | 256 | `$FF00–$FFFF` | permanent | — | permanent | no |
| 21 | EXT2 registry | 180 | `$BF00–$BFB3` | permanent | EXT2 | permanent | no |
| 22 | SAVE/LOAD buffers | 17 | `STORAGE_HEADER_BUF` `$81E2` (load name shares `EDIT_LINE_BUF`) | transient | storage | permanent but tiny | no |
| 23 | Printer, sound | 0 | no dedicated RAM buffers found (`rom/printer_raster.asm`, `exrom_sound.asm`, `ext_printer_module.asm` define none; printer code lives in a 345 B package) | — | — | — | nothing to reclaim |

**Genuinely reclaimable bytes, no double counting**

| Source | Bytes | Where it can be used | Needs |
|---|---:|---|---|
| Idle staging region (#6) | 3,818 | BASIC pool (source/arrays), `$8457`-contiguous | move chunk/overflow to the top 278 B; constants only |
| Dead system variables (#2) | 520 | pool bottom | delete `DEFS`; `make check` legacy guard builds must be updated |
| Obsolete chunk-7 cells (#13, #16, #17) | ≈ 323 (+10) | chunk 7, usable only by a seg-2 arena if contiguous with it | verify each; not contiguous with `$E000` |
| FILL stack tail (#10) | 2,048 | chunk 7 second array segment | shrink `GFX_FILL_STACK_END` (0 ROM), or span stack (+≈212 B package) |
| Sprite buffers (#11) | 2,304 | same chunk-7 segment (always, not only when unused) | `SPRITE_SLOT_IMG_BUF/BG_BUF` `EQU`s to `$C000/$C480`; reset `DEFINED/SHOWN` in the package install (package +≈15 B, window has 192 B spare) |
| Stack headroom (#19) | ≈ 1,000 | segment tail | only with a parser nesting cap (§6.4) |
| Hidden chunk 6 | (8,192) | **package scratch only** | not usable by BASIC; do **not** count |

Counted once: 3,818 + 520 + 2,048 + 2,304 = **8,690 B** of chunk 4/5/7 RAM can be
returned to BASIC data use (pool 4,338 B, segment 2 4,352 B); ≈ 323 + ≈ 1,000 more with
extra work. The 8 KB of hidden chunk 6 is excluded by construction: it is *reused*
(FILL transient, sprite persistent, never together), not added.

---

## 3. Sprites and optional packages

TRACED: the SPRITE package (`rom/ext_sprite_module.asm`, 832 B, loaded into `$F400`)
is the only user of `SPRITE_SLOT_IMG_BUF` (`$E800`, 1,152 B) and `SPRITE_SLOT_BG_BUF`
(`$EC80`, 1,152 B) — 8 slots × 144 B × 2. Nothing in HOME or EXROM touches them. They
are reserved from boot whether or not the package is loaded, and neither CLEAR nor NEW
releases them (there is nothing to release; they are static).

Options:

| Option | Returns to BASIC | ROM | Comment |
|---|---:|---|---|
| Keep | 0 | 0 | today |
| Fewer slots (8→4), static | 1,152 | 0 | a language limit; changes `SPRITE_SLOT_MAX` and the three `ASSERT`s |
| **Move buffers into hidden chunk 6** | **2,304, always** | **0 HOME/EXROM**, package +≈15 B | see below |
| On-demand claim (`WS_ALLOC_HI`) | 2,304 only while SPRITE is unused | +27 | needs a failure path on `GRAB`; strictly worse than the static overlay |

Why hidden RAM is legitimate for the sprite buffers (TRACED unless marked):

* Every package call runs with EXROM **paged out** (`OP_CALL_EXT`: `BANK_PAGE_EXROM_OUT`
  → call → `BANK_PAGE_EXROM_IN`), so the SPRITE package and the HOME routines it calls
  (`GFX_SPRITE_CAPTURE/DRAW`, `MATH_MULTIPLY16`) see `$C000–$DFFF` as RAM.
* No HOME or EXROM code touches the sprite buffers (the only references are
  `rom/ext_sprite_module.asm`, `rom/exrom_sprite.asm` — not in the production build — and
  `include/sysvars.inc`).
* RAM contents in chunk 6 survive paging EXROM in and out: `rom/test_exrom_isolation.asm`
  (hardware-confirmed, PASS/PASS) checks exactly that.
* **Only one package is resident at a time**: `V2_LOAD` calls `KTAB_EXT2_CLEAR_ALL`
  before receiving any package into `$F400`, and every package is assembled at
  `EXTENSION_MODULE_BASE`. So SHAPES/FILL (which uses all of `$C000–$E7FF`) and SPRITE
  are never resident together, and FILL can only overwrite sprite data while SPRITE is
  not loaded.
* Residual risks, to handle in the same change: (a) after SPRITE → SHAPES → SPRITE the
  sprite buffers hold FILL data, so the package install must reset
  `SPRITE_SLOT_DEFINED/SHOWN` (install runs with EXROM mapped and only touches
  sysvars); (b) `SPR_COMPUTE_ADDRS` derives addresses from the two `EQU`s, so no code
  change is needed there; (c) any future package that also wants persistent chunk-6
  data cannot coexist with SPRITE by the same single-window rule.
* Not measured: I did not run the sprite package against relocated buffers. The
  relocation is an `EQU` change plus the install reset; it should be validated with
  the existing `tools/z80sim/test_sprite_*` tests and a live GRAB/SHOW/HIDE pass.

Package-memory generalisation: a package that needs more than its 1,024 B window can
be given **scratch in hidden chunk 6** for free (HOME-side code only), exactly as FILL
does today. That is a *capability*, and it deserves a documented ABI contract
(contents undefined between calls) before R11.

---

## 4. ROM consolidation

### 4.1 Measured clones

Production routine sizes are MEASURED (next-label distance in `build/test_basic.sym`):

| Family | Bytes |
|---|---:|
| `CSYM_FIND_OR_CREATE` / `CSYM_ENTRY_ADDR` | 97 / 43 |
| `STRSYM_FIND_OR_CREATE` / `STRSYM_ENTRY_ADDR` | 98 / 26 |
| `ARRSYM_ENTRY_ADDR`/`SCAN`/`FIND_OR_CREATE`/`LOOKUP` | 17 / 63 / 61 / 23 |
| `STRARRSYM_ENTRY_ADDR`/`SCAN`/`FIND_OR_CREATE`/`LOOKUP` | 14 / 63 / 66 / 28 |
| **Total** | **599** |

Reading the sources confirms the bodies are clones: `CSYM_FIND_OR_CREATE` and
`STRSYM_FIND_OR_CREATE` differ in four symbol operands only; `ARRSYM_SCAN` and
`STRARRSYM_SCAN` are byte-identical apart from names.

### 4.2 Spike: one descriptor-driven set (MEASURED)

`tools/spikes/sym_consolidation_spike.asm` implements `SYM_SCAN`, `SYM_CREATE`,
`SYM_ENTRY` and `SYM_FIND_OR_CREATE` once, driven by a 6-byte descriptor
(`count_ptr, base, reclen, max`), plus thin wrappers that keep every production call
contract (so no call site changes), including the array size/width tails and the
errors 38/39 and "table full" behaviour. The scan advances a running pointer instead
of recomputing the entry address with a multiply, so it is also **faster** than the
production scan (UNMEASURED speed; it is compile-time only).

| Part | Bytes | Grade |
|---|---:|---|
| Generic core (SCAN + CREATE + ENTRY + FOC) | 145 | MEASURED |
| Wrappers for 4 tables (incl. array/string-array tails) | 136 | MEASURED |
| Descriptors (4 × 6) | 24 | MEASURED |
| **Spike total** | **305** | MEASURED |
| Production equivalent | 599 | MEASURED |
| **Saving before adapters** | **294** | MEASURED |
| Adapters: direct callers of `*_SCAN` (2 sites each) and `*_ENTRY_ADDR` (a few) | ≈ 30–40 | ESTIMATE |
| **Net HOME** | **≈ −255 to −265** | MEASURED + ESTIMATE |

Functional check: 9 tests pass (sequential indices; case-insensitive find; same-length
distinct names; stored name layout; table-full error code 1 with no growth; string
table independence; array create/duplicate(38)/lookup of size; string array
size+width; array-full error 39; no overrun into the neighbouring table). A bug
found and fixed in the spike by its own test: the string-array wrapper lost the new
index in `A`; the production contract requires it, so the wrapper now preserves it
(+2 B, included above).

**Constraint (important):** the spike assumes **flat** tables. Production tables are
tiered today (`CSYM` 3 tiers, `STRSYM` 2, `SYMTAB`/`STRTAB` 2). Consolidation therefore
depends on relocating the tables into one contiguous zone — it is the same change that
raises the limits.

### 4.3 Tier routines (MEASURED sizes)

| Routine | Today | Flat form | Saving |
|---|---:|---:|---:|
| `VM_SYM_ADDR` | 32 | 12 | −20 |
| `VM_STR_ADDR` | 38 | 13 | −25 |
| `CSYM_ENTRY_ADDR` / `STRSYM_ENTRY_ADDR` | 43 / 26 | (subsumed by §4.2) | counted in §4.2 |

### 4.4 Other duplicated logic (not measured by spike)

| Family | Today (MEASURED sizes) | Estimated saving | Why not more |
|---|---|---:|---|
| `LABEL_DEFINE` 62 / `LABEL_LOOKUP` 75 / fixups | same name-field scan pattern, different record | ≈ 30–40 (ESTIMATE) | records are 11 B with an offset, fixup record has the patch address first; reuse `SYM_SCAN` for the name scan only |
| `ARENA_ALLOC_NUMERIC` 77 / `_STRING` 95 | shared bounds + bump + pointer-table write | ≈ 20–30 (ESTIMATE) | different headers; one shared tail |
| `VM_INIT` 95 / `COMPILER_INIT` 26 / `MEM_INIT` 41 | range-zeroing | ≈ 10–25 (ESTIMATE) | a (base,len) table drives it |
| `VM_PUSH`/`POP`/`CALL_PUSH`/`POP`/`PARAM_BIND`/`UNBIND` | bounded stacks | ≤ 10 | different widths/errors; a helper adds `call`/`ret` (+27 T-states) on the hottest path — **rejected** |

### 4.5 Would a Workspace Manager replace this logic?

No, and measuring it shows why. The manager replaces **"base, bump pointer, compare to
limit, release"**. In this code base that appears in exactly two places:
`ARENA_ALLOC_*` (already the arena) and FILL's package-local push. Everything else in
the table above is *symbol-table* logic (scan, find, create, bounds-by-count), which a
memory manager does not touch.

| Replacement | Existing ROM removed | New ROM | Call-site overhead | Net |
|---|---:|---:|---|---:|
| Manager replaces `ARENA_ALLOC_*` tails | ≈ 25–35 (ESTIMATE) | 37 core | +6 B `call`/`ret` per site ×2 | ≈ **+15 to +25** HOME |
| Manager owns compile/run zone carving (descriptor bases filled by `WS_ALLOC`) | 0 | 37 + ≈ 8 B × 8 tables = ≈ 100 | RAM descriptors | **≈ +100 to +110** HOME, +≈ 30 B RAM |
| Descriptor symbol routines (no manager) | 299 | 0 | adapters ≈ 35 | **≈ −260** |

**Conclusion:** the manager is not ROM-positive. It is roughly ROM-neutral only if it is
confined to the arena (≈ +20 B, for a capability nothing currently needs). **The ROM win in
this study comes entirely from de-duplicating symbol routines and removing tiers**, and
is available with or without a manager. A *centralised* manager costs more ROM than
shared helpers and targeted optimisations; the helpers win.

---

## 5. Workspace Manager proof of concept (MEASURED)

`tools/spikes/ws_manager_spike.asm`, assembled with `sjasmplus`, run headless under
`ts2068-debug`:

```
WS_INIT      8 B    ld (WS_TOP),hl : ld (WS_LIMIT),de : ret
WS_MARK      4 B    ld hl,(WS_TOP) : ret
WS_ALLOC    21 B    BC=size -> HL=base, carry set on failure, top unchanged
WS_RELEASE   4 B    ld (WS_TOP),hl : ret
core        37 B    RAM: WS_TOP, WS_LIMIT = 4 B
WS_ALLOC_HI 27 B    persistent claim from the high end (shrinks WS_LIMIT)
WS_RELEASE_CHK 15 B stale-mark rejection (mark above top)
```

The earlier **60–100 B target is met comfortably** (core 37 B; core + high-end 64 B;
core + high-end + checked release 79 B), with 4 B of RAM.

Behavioural tests (12, all pass; run via `tools/spikes/run_ws_spike.sh`, border 4):

| # | Test |
|---|---|
| 1 | sequential allocation bases |
| 2 | mark/alloc/release restores top exactly |
| 3 | nested (LIFO) marks |
| 4 | exact fit permitted, +1 byte fails, top unchanged |
| 5 | 16-bit wrap (`size = $FFFF`) rejected, top unchanged |
| 6 | zero-size allocation |
| 7 | a failed allocation leaves a usable arena |
| 8 | high-end claim shrinks the limit and the low end sees it |
| 9 | high claim colliding with the temp region fails, limit unchanged |
| 10 | temp release does **not** free persistent memory |
| 11 | checked release rejects a stale mark, accepts a valid one |
| 12 | phase reuse: a compile-zone table's base is reused by a run-zone table |

A deliberate negative control (removing the overflow `ret c` from `WS_ALLOC`) makes the
suite fail at test 4, so the tests do bite.

**Ownership model.** Strictly LIFO. `WS_RELEASE` restores a mark; marks are opaque
2-byte values. There is no per-block ownership: a client that releases an enclosing
mark frees everything after it. That is the point (no fragmentation, no free list) and
the limitation (a block cannot outlive a mark that precedes it, which is exactly why
persistent claims need the **other end**). `WS_RELEASE_CHK` catches a stale mark but not
a *wrong-but-valid* mark; there is no owner tag by design.

**Integration evaluation**

| Client | Fits the manager? | Notes |
|---|---|---|
| Compiler workspaces | yes, temporary | compile-zone tables at `COMPILER_INIT`; but the tables already have fixed constant bases that cost 0 B and nothing varies per program |
| Graphics/FILL | yes, temporary | FILL needs only its hidden-RAM scratch, owned by no one else today; a claim buys nothing unless chunk 6 gains a second client |
| Sprites | persistent, but a static overlay is better | `WS_ALLOC_HI` would work (+27 B) but the buffers can live in hidden chunk 6 for 0 B (§3) |
| EXT2 packages | partly | code window is fixed; a package *data* claim from the high end is the new capability |
| Arrays | already an arena | `ARENA_ALLOC_*` is a bump allocator bounded by `VARS_START`; the manager would be a second copy |
| Source (line store) | **no** | insert/delete shifts a block; it is a compacting buffer, not an arena |

**Temporary vs persistent:** temporary = compile/run tables, FILL scratch, package
scratch (all LIFO, released at phase end). Persistent = sprite buffers and any package
data (high end of a manager arena, or — for sprites — a static hidden-RAM overlay). BASIC arrays are
"temporary" with a lifetime of RUN/CLEAR/NEW (and see §8 for the correctness gap in
that lifetime).

---

## 6. Fixed BASIC limits — verification and treatment

> **Superseded by §15 for the recommendation.** The verification (values, causes) stays valid; the "raise fixed" column is replaced by memory-limited mechanisms in §15.

All values re-verified against current production code (full table with causes in the
RAM audit §7.1). Treatment:

| Limit | Value | Preferred treatment | Why |
|---|---:|---|---|
| **Label / PROC / DEF FN entries (shared)** | **8** | **raise fixed to 16 (11 B × 16 = 176 B compile-zone)** | one table `LABELTAB` serves GOTO labels, every PROC and every DEF FN (TRACED: `COMPILE_DEF_FN` and PROC both call `LABEL_DEFINE`). Programs with 3 PROCs, 3 FNs and 2 labels are already full. Cheapest and most valuable increase |
| Forward fixups outstanding | 8 | raise fixed to 16 (+88 B compile zone) | same pattern |
| FOR/NEXT nesting | 4 | raise fixed to 8 (runtime frames 4 B each have 63 B free → ≤ 15, no relocation; compile side needs `CFOR`+`EXITFOR` 12 B/level → move to the zone) | 0 B ROM; **no dynamic stack** |
| PROC/CALL, DEF FN depth | 12 | raise fixed to 16–24 (call 2 B + param 8 B per level) | 0 B ROM once the stacks leave the `$B6xx/$B7xx` gap |
| Numeric scalars | 32 | **flat 48 or 64** in the zone | removes the tier routines (−45 B) and the overflow ranges |
| String scalars | 8 + 2 temps | flat 12–16 | 32 B each; 16 × 32 = 512 B in the zone |
| Numeric arrays / string arrays | 16 / 8 | 16 / 8 is adequate; 24/12 if the pointer tables move | pointer tables are 2 B each |
| EXT2 registry slots | 12 | keep | 12 names, **one resident package at a time**, so slot count is not the limit |
| Source / bytecode | 4,094 / 4,011 | see §10 | bytecode ≈ 0.5 × source, so source is the binding limit |
| Parser nesting | unbounded | add a cap (≈ 10–15 B ESTIMATE) if headroom is trimmed | machine stack ≈ 12–14 B/level MEASURED |

Dynamic allocation is preferable for **none** of these: each is a bounded table indexed
by a compile-time number; dynamic bases would turn immediate bases into
`ld hl,(var)` (same size, +6 T-states per access, on the VM's hottest path) and FOR
would gain a runtime check it deliberately lacks today.

### 6.4 Stack headroom (MEASURED + ESTIMATE)
12 nested parentheses used 174 B of machine stack (≈ 12–14 B per level). A 127-character
line can nest ~60 levels ≈ 0.8–1.5 KB; there is no cap that I found, so shrinking the
1,792 B headroom without a cap is unsafe.

---

## 7. Memory safety summary

| Property | Today | A (recommended) | B | C |
|---|---|---|---|---|
| Source edit can corrupt live arrays | **yes (§8)** | no (§8-A) | no | no |
| Overlays are provably phase-disjoint | by convention | by convention **plus `ASSERT`s** on zone ends, compile-zone ≤ Z, run-zone ≤ Z | same | by construction, at runtime |
| Allocation failure is clean | `VM_ERR_ARRAY_SPACE`, compile error 55/1 | same | carry from `WS_ALLOC` | at compile end |
| Stale/foreign mark detectable | n/a | n/a | `WS_RELEASE_CHK` (+15 B) catches a mark above top only | same |
| Hidden-RAM overlay safe | FILL only | FILL **or** SPRITE, never both (one resident package) | same | same |
| Stack headroom safe to trim | no (no nesting cap) | only with a parser nesting cap | same | same |
| New address-shift risk | — | **table relocation is the risk the earlier reverted capacity attempt hit** (`VM_ARR_VALUE_TMP`/`VM_INPUT_COUNT`): mitigate with `ASSERT`s and the `scalar_capacity32`/`recursion_depth12`/`dynamic_arrays` tests | same | larger |

---

## 8. Source-editing / array corruption — **CONFIRMED**

TRACED: `MEM_LINE_STORE` bounds source growth against `VARS_START` and does not look at
`ARRAYS_END`; `VM_INIT` places arrays at `PROG_END`; nothing clears the arena when a
line is stored.

MEASURED, production ROM (`ts2068-debug`, headless; program `dim a(5)`,
`a(1)=4660`, `a(2)=22136`, `print a(1)`, then `run`, then new lines typed at the
prompt), reading `PROG_END` / `ARRAYS_END` / `ARR_PTR_TABLE[0]` and the descriptor:

| State | `PROG_END` | `ARRAYS_END` | `ARR_PTR[0]` | descriptor + data at `ARR_PTR[0]` |
|---|---|---|---|---|
| after RUN | `$848C` | `$8499` | `$848C` | `01 05 00 | 00 00 34 12 78 56` (valid: dim=1, count=5, a(1)=$1234, a(2)=$5678) |
| after + `x = 1` | `$8493` | `$8499` | `$848C` | `05 00 20 3D 20 31 0D | 78 56` — **descriptor replaced by source bytes** (`" = 1\r"`) |
| after + `y = 2` | `$849B` | `$8499` | `$848C` | `05 00 20 3D 20 31 0D 06 00 79 20 3D` — more source text over it |
| after another RUN | `$84AF` | `$84BC` | `$84AF` | valid again (VM_INIT resets the arena) |

So source text silently overwrites live array descriptors and data, `ARRAYS_END` is left
stale **above** `PROG_END`, and `ARR_PTR_TABLE` keeps pointing at the corrupted bytes.
Consequences (TRACED, not all executed): `SAVE … ARRAY` after an edit reads garbage;
an immediate-mode statement that touches the array reads garbage; `FREE()`
(`VARS_START − ARRAYS_END`) reports the stale arena size. A re-`RUN` is clean because
`VM_INIT` rebuilds the arena. No crash was observed; the failure is silent wrong data.

**Fix options** (not implemented):

| Option | Effect | Cost (ESTIMATE) |
|---|---|---|
| A. On every successful line store: `ARRAYS_END = PROG_END` and zero `ARR_PTR_TABLE`/`STRARR_PTR_TABLE` (48 B at `$B4B0`) | editing discards arrays, as classic BASIC does; "array not DIM'd" instead of garbage | ≈ 19–25 B EXROM (in `V2_COMMAND_LOOP.store`); `ARR_PTR_TABLE` is already exported by the crossbank include |
| B. Place arrays away from the source (high end of the pool, growing down) | arrays survive edits | needs the arena reversed or a second segment; larger change |
| C. Refuse the edit while arrays are live | surprising UX | ≈ 10 B |

Recommendation: **A**. It is correct for every architecture in §10 and is a
prerequisite for any scheme that places arrays or bytecode above the source.
Note: `CLEAR` also calls `EXT2_CLEAR_ALL` (unloads packages), which `A` must not do.

---

## 9. Idle 3,818-byte staging region — verified

Production ROM, `ts2068-debug`, headless. `$956B–$A454` was painted with `$A5`, then the
program (`dim a(21)`, `dim s$(3,10)`, recursive `proc f(n)` called with `f(8)`, a
21-iteration `for` filling an array, string concatenation, `print x`) was compiled
and run **directly through `V2_RUN_STORED`** (typed-key input was too lossy to be a
reliable harness, see §13).

| Check | Result |
|---|---|
| Compile error / VM error | `00` / `00` |
| `print x` (`a(7)+a(20)`) | `81` (correct) |
| Canary bytes changed after RUN | **0 of 3,818** |
| Canary bytes changed after a second RUN | **0 of 3,818** |

Static corroboration (TRACED): `CHUNK_BUF` (264 B) + three state words + the 8-byte ident
buffer end at `$956A`; `V2_CODE_BASE` is `$A455`; the run-only overflow tiers occupy
`$9455–$9544`; no production reference to any address in `$956B–$A454` exists.

Scope of the proof: RUN (arrays, strings, PROC recursion, FOR). **Not exercised:**
`SAVE`/`LOAD`/`LOAD … EXT`/`LIST` canary runs (LIST was checked earlier only for
the rendering change). I recommend a one-off canary pass over the storage paths before
allocation, because `V2_LOAD_ARRAY`/package load write through `ARRAYS_END` and
`V2_RECEIVE_DEST` (TRACED).

Bytecode/source ratio (MEASURED, `EMIT_PTR − VM_CODE_BASE` vs. stored bytes): 0.53,
0.50, 0.51 on three programs → **4,011 B of bytecode serves ≈ 8 KB of source**. The
present 4,094 B source limit, not the bytecode limit, is what a typical program hits.

---

## 10. Realistic capacities under A, B and C (ESTIMATES unless marked)

Definitions used. "Pool" = `$8457`-contiguous source + array space (what `FREE()`
reports today). "Segment 2" = chunk 7 `$E000–$F0FF`, usable **only for arrays** (it is
not contiguous with the pool, and the VM/EXROM can address it). Sizes are bytes; no
RAM is counted twice.

| | Today | **A. Static zones** | **B. A + minimal manager** | **C. Hybrid manager** |
|---|---:|---:|---:|---:|
| ROM, HOME (net vs. today) | 0 | **≈ −300** | ≈ −300 + 37 core (− ≈ 30 arena dedup) ≈ **−290 to −265**, **no extra capacity** | ≈ B + ≈ 110 adapters ≈ **−180 to −155** |
| ROM, EXROM | 0 | +19 to +25 (hazard fix) | +19 to +25 | +19 to +25 |
| Permanent RAM added | 0 | 0 | 4 | ≈ 30 (descriptor bases) |
| Pool: limits unchanged | 4,094 | **8,432** (3,818 + 520 reclaimed) | 8,432 | 8,432 |
| Pool: with raised limits (§6: 16 labels, 8 FOR, 24 call, 64 scalars, 16 strings) | n/a | ≈ **7,000** (zone ≈ 1.7 KB) | ≈ 7,000 | ≈ 7,000–8,400 (sized per program) |
| Segment-2 arrays (`$E000–$F0FF`) | 0 | **4,352** (FILL tail 2,048 + sprite 2,304, once sprites move to hidden RAM) | 4,352 | 4,352 |
| Sprite buffers | 2,304 reserved in chunk 7 | **moved to hidden RAM (0 B ROM)** | same | same |
| Source capacity | 4,094 | up to ≈ 8,400 in the pool (bytecode 4,011 still serves ≈ 8 KB) | same | same |
| Bytecode capacity | 4,011 | 4,011 (unchanged) | 4,011 | 4,011 |
| Dynamic array capacity with a full-size source | ≈ 0 | pool remainder + 2,048 | pool remainder + 2,048…4,352 | same as B |
| Limits removed | 0 | label/fixup/FOR/call/scalar/string raised, **no allocator** | same | same |
| Runtime speed | baseline | **faster** (flat tables) | same | **slower** (indirect bases on every variable access) |
| Failure mode | compile/runtime errors | same | allocation failure = carry from `WS_ALLOC` at the client | allocation failure at compile end |
| Memory safety | **hazard §8 open** | fixed by §8-A | fixed; stale marks caught by `WS_RELEASE_CHK` | fixed; more moving parts |
| Complexity / production risk | — | low–medium (table moves, ASSERTs) | medium | **high** (touches the VM's hot path; the previous capacity attempt was reverted for a collision) |

Arithmetic behind the pool rows: 4,094 + 3,818 + 520 = 8,432 for unchanged limits.
Raising limits as in §6 needs a compile zone of ≈ 1.7 KB (chunk 278 + 64×9 + 16×9 +
16×11 + 16×11 + 8-level FOR 96 + arrays 176 + 96), so the pool gain falls to
4,096 − 1,718 + 520 ≈ 2,900 → pool ≈ 7,000. Part of the old compile region of the dense
bank (≈ 1 KB, ESTIMATE) is freed by the move and can host the raised run-phase tables,
which is why the run side does not subtract again.

### What `FREE()` should report

| Architecture | `FREE()` |
|---|---|
| A | keep `VARS_START − ARRAYS_END` for the pool. Add `FREE(1)` (or a second function) for segment-2 arrays so a program can size a `DIM`. Do not redefine the existing number |
| B | same as A (there is no dynamic claim for `FREE` to reflect) |
| C | would need a definition per allocation class; not recommended |

---

## 11. Future architecture, and what should precede the R11 ABI/API freeze

Observed: the sibling projects carry **their own forks** of the kernel files (for
example `2068-forth/kernel/memory/memory.asm` and `kernel/graphics/graphics.asm`
exist as separate copies), so any "shared memory service" would be shared **source**,
not a shared resident kernel, and nothing here assumes otherwise.

The spike is dependency-free (two RAM words, no other symbols), 37 B core, 64 B with a
high-end claim. It is the kind of component a Pascal, Forth or C runtime could copy,
but I would not make that a goal: the benefit is a documented *contract*
(LIFO temp + high-end persistent), not shared code.

Decisions that should precede the R11 freeze:

1. **Zone constants as ABI.** Which addresses (`VARS_START` semantics, array segment 2,
   package scratch, stack floor) are promised to packages and which are internal.
2. **Hidden-RAM contract.** Chunk 6 as package scratch: contents undefined between
   calls; EXROM-in invalidates visibility.
3. **Package data claims.** A package header field "persistent bytes needed" and a
   documented failure return, if a manager-based claim is ever adopted.
4. **`FREE()` / `FREE(1)` semantics** (§10).
5. **Allocation-failure error code(s)** for `GRAB`/package load.
6. **Edit-clears-arrays** (§8) as a language rule.
7. **Limits as documented constants**, not accidents of layout (labels 16, FOR 8, call
   depth, scalars, strings).
8. **Parser nesting limit**, if stack headroom is ever reclaimed.
9. **Single-package-window rule** (one resident package at a time) stated explicitly,
   or the window enlarged.
10. **Symbol-table descriptor shape** if the generic routines become an internal API.

---

## 12. Corrections to `R10_7_PRODUCTION_RAM_ARCHITECTURE_AUDIT.md`

1. **Dead system variables: 592 B → 520 B.** The first scan ignored `rom/ext_sprite_module.asm`
   (it is not named `ext_v2_*`), so 32 B of live sprite-slot metadata was flagged dead.
   Re-run against every production package source: 520 B dead in `$8000–$8456`, plus
   ≈ 323 B in chunk 7 (§2 rows 13, 16, 17).
2. **Array/source overwrite hazard: UNVERIFIED → CONFIRMED** (§8).
3. **Consolidation estimate**: the audit's `−150 to −230 B` HOME is superseded by the
   MEASURED spike (§4): ≈ −300 B including the tier routines.
4. **Sprite metadata** is 57 B of live state in the sysvars block, not dead.

---

## 13. Method notes and limits of the evidence

* `ts2068-debug` keystroke injection drops characters intermittently (repeatedly
  observed). Every measurement above that needed a program used direct memory writes
  into the line store and a direct `V2_RUN_STORED` call, or was verified by memory dump.
  Only the hazard test (§8) relied on typed lines, and its outcome was read from
  memory, not from the screen.
* The spikes are **not** the production algorithms: the symbol spike uses flat tables
  and wrapper-keeps-contract; adapters for the remaining direct callers are estimates.
  Spike sizes are exact; the net production figure is not until it is built in the tree.
* The capacity table (§10) is arithmetic over measured sizes, not a build.
* ROM figures for LABEL/FIXUP, arena dedup, init-table and parser-cap work are
  ESTIMATES.
* Not tested: `SAVE`/`LOAD`/`LOAD EXT` canary passes (§9), `SAVE … ARRAY` after the
  hazard (§8), any speed measurement.

---

## 14. Recommended architecture and implementation priorities

> **Superseded by §15.8 (phased plan).** Items 1, 2, 4 and 5 below survive unchanged as phases P0/P1; items 3 and 6 are replaced.

**One recommendation: Architecture A (static lifetime zones) + descriptor-driven symbol
routines + edit-clears-arrays + a high-end claim for sprites/packages. No general or
hybrid manager.**

Order of work, once approved (smallest risk and largest payoff first):

1. **Fix the array hazard** (§8-A). ≈ 19–25 B EXROM. Independent of everything else.
2. **Allocate the idle region and the dead sysvars**: pool +3,818, then +520. Move
   chunk buffer/overflow tiers to the top 278 B; update the assertions and the
   `V2_SOURCE_END`-derived constants (`MEM_INIT_V2`, `MEM_CLEAR_V2`, `V2_LOAD`'s
   program-size limit, `rom/v2_home.asm`'s init). ≈ 0 ROM. Canary-test the storage
   paths first (§9).
3. **Flatten the tables into one zone, introduce the descriptor routines** (§4). HOME
   ≈ −300 B; raise labels/fixups to 16, FOR to 8, call depth, scalars and strings in
   the same pass because they become constants.
4. **Move the sprite buffers into hidden chunk 6** (`EQU` change + install reset,
   0 HOME/EXROM) and **shrink FILL's stack to 2,048 B** (0 ROM). That makes
   `$E000–$F0FF` (4,352 B) free of any other owner.
5. **Segment 2** in the array arena (≈ +20–30 B): arrays spill from the pool into
   `$E000–$F0FF`; `FREE(1)`.
6. Parser nesting cap and stack-headroom trimming (optional).
7. FILL span stack (package +≈212 B) only if truncation on large fills matters.

Not recommended: dynamic FOR/PROC/DEF FN stacks (adds a hot-path check for no
capacity gain), variable tables with computed bases, a free-list or compacting
allocator, and a manager that owns every table (§4.5: +100 B ROM, +30 B RAM for no
capability the zone does not give).

### Decisions requested

1. Approve architecture A + the three additions above?
2. Raised limits: labels/fixups 16, FOR 8 (or higher), call depth 16–24, scalars 48 or
   64, strings 12–16 — and are you willing to give up ≈ 1.4 KB of pool for them?
3. Sprite buffers into hidden chunk 6 (0 ROM; relies on the one-resident-package rule), or keep them where they are, or fewer fixed slots?
4. Edit clears arrays (language rule) or arrays survive edits (needs a bigger change)?
5. `FREE()` stays as is plus `FREE(1)` for segment 2?
6. Should source be allowed to exceed 4,094 B (≈ 8 KB), given bytecode ≈ 0.5 × source?

---

## 15. Removing the artificial limits (stock-BASIC-like flexibility)

**Question asked:** with the product goal that Leap V2 should not be substantially
more restrictive than stock TS2068 BASIC when RAM is available, while keeping compiled
bytecode, fast variable access, a small ROM, and predictable behaviour, what is the
simplest architecture — without assuming a general memory manager?

### 15.1 Recommendation in one paragraph

**Make every table *as large as the program needs, decided at compile time*, and make
every stack *as deep as memory allows*, using only bump pointers — never a heap.**
Concretely: (1) one tagged, variable-length, append-only **compile symbol table**
replaces the six fixed compile tables, with forward references threaded through the
emitted code so no fixup or EXIT-FOR table exists; (2) at `VM_INIT` the VM **carves
exact-size run tables** (scalars, floats, strings, array pointers) from the top of the
existing pool, keeping direct indexed access through a base pointer in RAM; (3) **one
memory-limited control stack** grows down from below those tables and meets the
existing array arena, replacing the separate FOR, CALL and parameter stacks and their
fixed depths; (4) identifier significance is raised from 8. No bytecode change, no
allocator, no relocation, no compaction.

### 15.2 What the code actually does today (verified)

| Fact | Evidence | Grade |
|---|---|---|
| Bytecode operands for variables, strings, arrays and FOR variables are **one byte** | `OP_LOAD_VAR`, `OP_FOR_INIT`, `OP_FOR_NEXT` read `(hl)` once | TRACED |
| Runtime variable access is `index → VM_SYM_ADDR → base + index×3` with a **tier compare** (`cp 16 / jr nc`) | `VM_SYM_ADDR` 32 B | TRACED |
| Compile-time FOR nesting is capped at 4 (`FOR_NEST_MAX`), enforced at compile time; the VM FOR stack has **no runtime bounds check** by design | `exrom_v2_compiler.asm`, `exrom_v2_vm_core.asm` | TRACED |
| …but the VM FOR stack's depth is **dynamic**: `OP_FOR_INIT` pushes the *enclosing* loop's limit/step, so recursion that re-enters a loop pushes one frame per level. 15 frames fit the free gap `$B5C1–$B5FF`; frame 16 overwrites `VM_IP`/`VM_SP` | code read + test below | TRACED + MEASURED |
| Labels, PROCs and DEF FNs share `LABELTAB` (8 × 11 B); forward references use a separate `FIXUPTAB` (8 × 11 B) | `COMPILE_DEF_FN`, `LABEL_DEFINE`, `FIXUP_RECORD` | TRACED |
| `EXIT FOR` patch addresses use a table of 4 per nesting level | `EXITFOR_PATCH_TABLE` | TRACED |
| IF/ELSE/ENDIF nesting and parenthesis nesting already use the **Z80 stack** (recursive descent) — i.e. memory-limited growth is already the compiler's precedent — but there is no stack guard | `COMPILE_IF_BLOCK` header comment; §6.4 | TRACED |
| Identifiers are significant to **8 characters** (`CLAMP_LEN8`) | production run below | TRACED + MEASURED |
| String variables are fixed 32-byte records (31 characters); string arrays have a per-array width | `STR_REC_LEN` | TRACED |
| Immediate-mode (`:`) statements are an isolated mini-program: `KTAB_COMPILER_INIT` resets the compile tables and `VM_INIT` zeroes the run tables | `V2_RUN_IMMEDIATE` | TRACED |
| `SAVE/LOAD … ARRAY` read the compile-time array names **after** a RUN, so the array names must survive compile | `ARRSYM_LOOKUP` header | TRACED |
| `VM_FOR_LIMIT/STEP` hold the *current* loop in two RAM cells, so `OP_FOR_NEXT` does no stack access per iteration | `OP_FOR_NEXT` | TRACED |

**Two new defects found while investigating (MEASURED, production ROM, programs loaded
straight into the line store and run through `V2_RUN_STORED`):**

1. **Silent FOR-stack overflow under recursion.** `proc f(n)` containing two nested
   `for` loops with a recursive `call` in the innermost body, called with `f(10)`
   (20 live frames, limit 15): compile error `00`, VM error `00`, the VM halts early,
   `VM_FOR_STACK_DEPTH = $10` at the end, `VM_IP = $A401` (below the code base) and the
   statement after the call never runs (`x` stays 0). The same program with one loop per
   level (10 frames) runs correctly (`x = 77`). No error is raised.
2. **Identifier collision.** `variable1 = 5`, `variable2 = 9`,
   `total = variable1 + variable2` creates **two** symbols (`variable`, `total`);
   `total` is 18 instead of 14. Stock TS2068 BASIC distinguishes them.

(1) is a correctness bug that exists regardless of the architecture; its minimal fix is a
depth check in `OP_FOR_INIT` (≈ 8 B) and belongs in phase P0.

### 15.3 Which limits are hardware, which are implementation

| Limit | Origin | Notes |
|---|---|---|
| 48 KB RAM; chunk-6 EXROM window; `$5B00–$7FFF` second display file | **hardware** | the only real ceilings; the VM and compiler cannot use hidden chunk-6 RAM |
| Z80 16-bit addresses | hardware | pointers are 2 bytes |
| One-byte symbol/loop operand (≤ 256 per kind) | **implementation, deliberate** (speed + bytecode size) | not a practical ceiling: 255 scalars × 8 B = 2 KB |
| 4 FOR levels, 8 labels/PROC/FN, 8 fixups, 4 EXIT FOR/level | implementation (fixed tables) | removable |
| 32 numeric / 8 string scalars, 16/8 arrays | implementation (fixed tables, tiered) | removable |
| PROC/CALL and DEF FN depth 12 | implementation (fixed stacks) | removable |
| 8-character identifier significance | implementation (`CLAMP_LEN8`, 8-byte name fields) | removable; also a **semantic** departure from stock |
| 31-character string variables | implementation/design (fixed 32 B records; no string heap) | **not** removable without a string heap; see 15.7 |
| 1-D arrays only | implementation (feature) | out of scope |
| One resident package, 12 registry names | design (single `$F400` window) | keep |
| Line length 127 | design (chunk proof) | keep |
| PROC/DEF FN take one parameter | language | out of scope |
| 16-bit integers + calculator floats | language | out of scope |

### 15.4 Alternatives evaluated

Eight criteria per the request. "ROM" is HOME ROM, net of what is removed.

| # | Alternative | ROM (HOME) | RAM efficiency / capacity | Speed | Compiler/VM changes | Pool arena | Bytecode / index | EXT2 / language | Complexity / risk |
|---|---|---|---|---|---|---|---|---|---|
| **A** | Double the fixed limits (previous plan) | ≈ −300 (tier removal + dedup) | reserves unused capacity; hard ceilings remain | neutral | constants, table moves | none | none | none | low–medium |
| **B** | **Compile-sized tables + tagged symbol table + memory-limited control stack (recommended)** | **≈ −300 ± 80** | exact-size tables; ceiling = memory or 255/kind | variable access −4 T (faster), loops unchanged, FOR/CALL +20–40 T per *event* | new symbol layer, VM_INIT carve, control stack | extends it: stack meets `ARRAYS_END` | **none** | none | medium |
| **C** | Stock-style FOR record kept *in the loop variable* (no FOR stack) | ≈ −250 more | no FOR depth limit at all | **slower**: `NEXT` must fetch limit/step from a per-slot record (+~60 T/iteration, ≈ +8 % loop time) | FOR_INIT/NEXT/POP rewritten; bytecode gains a state operand | none | **+1 byte** per FOR/NEXT | none | medium; loses the fast cells |
| **D** | Lower `FOR` to generic ops with hidden scalars (limit/step as symbols) | ≈ −250 | trivial | **much slower** (≈ 8 generic dispatches per iteration instead of one fused op) | compiler only | none | none | none | low, but violates the performance requirement |
| **E** | Three separate memory-limited stacks (no unification) | ≈ −300 ± 90 | needs three growth ends: impossible in a two-ended pool without per-stack reservations | neutral | VM | conflicts | none | none | medium; reintroduces fixed reservations |
| **F** | General heap/handle-based variables | ≈ +300–500 | best packing | slow (indirection on every access), fragmentation | everything | replaces it | wider operands | pointer-relocation hazards | **high**; out of scope as instructed |

**Why B and not C/D for loops:** the fused `OP_FOR_NEXT` plus two RAM cells for the
current loop is the project's performance advantage; C and D give that up to remove a
ceiling that B removes for free.

### 15.5 The recommended design in detail

**(1) Tagged compile symbol table** — measured by `tools/spikes/tagged_symtab_spike.asm`.

```
record = [rec_len][kind][namelen][index][name][extra]   table ends with a 0 byte
kinds  = numeric, string, numeric array, string array, label/PROC/FN
index  = per-kind running count == the 1-byte operand the VM already uses
label extra = [offset-or-chain-head:2][defined:1]
```

* One `SYM_FIND` / `SYM_ADD` pair replaces six table implementations.
* Table lives in the compile zone and grows toward a **compile stack** that grows down
  from the zone top (so the compile structures are also memory-limited, two-ended).
  The zone is the `$9455` region reclaimed in §9; it persists until the next compile or
  edit (needed by `SAVE/LOAD … ARRAY`).
* **Forward references need no table.** An unresolved operand slot stores the
  previous slot's address; the label record keeps the chain head; `LABEL_DEFINE` walks
  the chain once and patches it. `EXIT FOR` uses the same chain (head kept in the
  compile-time FOR frame). `FIXUPTAB`, `EXITFOR_PATCH_TABLE`, `FIXUP_RECORD`,
  `RESOLVE_ALL_FIXUPS` and `FIXUP_ENTRY_ADDR` disappear. An "undefined label" check is a
  single scan (`LABEL_CHECK_ALL`, 25 B).
* Eliminates: scalar/string/array symbol caps, label/PROC/DEF FN cap (8), fixup cap
  (8), EXIT FOR cap (4).
* Spike result (MEASURED): core 183 B + wrappers 301 B = **484 B**, **8 tests pass**
  (per-kind indices, case-insensitive find, arrays with size/width, forward chain of 3
  references patched, backward reference, duplicate definition, undefined-label
  detection, table-full error with no corruption, 200 symbols with correct indices). A
  deliberate mutation of the chain patch fails test 4.
* Replaces 860 B of production code (599 B symbol families + 261 B label/fixup code).
  Saving **376 B** before adapting the label/GOTO/CALL call sites (≈ +40–60 B,
  ESTIMATE) → **≈ −320 B net**.

**(2) Run tables sized by the compiler's counts.**
After a successful compile the compiler knows N numeric, M string, A array and SA
string-array symbols. `VM_INIT` carves, from the pool top (`VARS_START` moves down —
that is exactly what `VARS_START` was designed for):

| Table | Size | Base |
|---|---|---|
| `SYMTAB` | 3 N | `SYMTAB_PTR` (RAM word) |
| `FLOATTAB` | 5 N | `FLOATTAB_PTR` |
| `STRTAB` (+2 temps) | 32 (M+2) | `STRTAB_PTR` |
| `ARR_PTR_TABLE`, `STRARR_PTR_TABLE` | 2 A, 2 SA | `ARRPTR_PTR`, `STRARRPTR_PTR` |

Variable access stays indexed: `VM_SYM_ADDR` becomes
`ld l,a / ld h,0 / ld d,h / ld e,l / add hl,hl / add hl,de / ld de,(SYMTAB_PTR) / add hl,de / ret`
= **12 B** (today 32 B, because of the tier branch). Timing (Z80 timing tables, not
emulated): `ld de,(nn)` costs 20 T versus 10 T for `ld de,nn`, but the removed
`cp 16 / jr nc` costs 14 T, so a base-tier access is **4 T faster** than today and a
former overflow-tier access (16–31) is ≈ 50 T faster. No unused capacity is reserved:
a program with 25 numeric and 6 string variables uses ≈ 470 B of run tables, against
≈ 760 B permanently reserved today (SYMTAB+overflow 96, FLOATTAB 160, STRTAB+overflow 320,
pointer tables 48, three stacks 136).

**(3) One memory-limited control stack.**
`VM_CSP` starts at `VARS_START` (below the tables) and grows **down**; the array arena
grows up from `ARRAYS_END`; both check against each other (`ARENA_ALLOC_*` compares to
`VM_CSP` instead of `VARS_START` — a one-operand change). Frames carry a one-byte type:

| Frame | Size | Pushed / popped by |
|---|---:|---|
| FOR | 1 + 4 | `OP_FOR_INIT` / `OP_FOR_POP` (enclosing loop's limit/step, as today) |
| CALL | 1 + 2 | `OP_CALL` / `OP_RET` |
| PARAM | 1 + 8 | `OP_PARAM_BIND` / `OP_PARAM_UNBIND` (as today) |

* `OP_FOR_NEXT` is **unchanged** (reads `VM_FOR_LIMIT/STEP`), so loop iteration speed is
  identical.
* One `CS_ALLOC` helper (≈ 28 B ESTIMATE) does `new = CSP − size; if new < ARRAYS_END →
  error`. Overflow becomes a clean "out of memory" error (reuse VM error 6 or add one)
  instead of the silent corruption in §15.2.
* **Leak behaviour.** Today a `GOTO` out of a `FOR` leaks a frame on a *separate* FOR
  stack. On a unified stack a leaked FOR frame would sit under later frames and could be
  mistaken for a CALL/PARAM frame. Mitigation: `OP_RET` unwinds frames down to the
  nearest CALL frame, and frames are type-checked on pop (≈ +25 B). This also heals
  leaks at procedure exit, which is better than today. **This is the one design choice I
  would like you to decide (§15.10, D2): unified typed stack (recommended) or three
  stacks with large fixed reservations.**
* Eliminates: FOR depth 4 (compile) / 15 (runtime, unchecked), CALL depth 12, PARAM/DEF FN
  depth 12.
* Compile-time FOR nesting uses the compile stack from (1), so `FOR_NEST_MAX` goes too.
* Parenthesis/IF nesting: add one **machine-stack guard** at the recursive entry points
  (≈ 12 B) so deep nesting becomes a compile error instead of corrupting the package
  window.

**(4) Identifier significance.** With variable-length records the name field no
longer needs 8 bytes; raise the clamp to 16 (or 31) and enlarge `STMT_IDENT_NAME_BUF`
from 8 to match (+8…+23 B RAM, ≈ 0 ROM). This fixes the `variable1`/`variable2`
collision. Decision D4.

### 15.6 Costs

All HOME-ROM figures are net of removed code. MEASURED = assembled spike vs. measured
production sizes; ESTIMATE = my Z80 byte counting.

| Part | HOME ROM | Grade |
|---|---:|---|
| Tagged symbol table + label chains + EXIT chains (spike 484 B vs 860 B removed, plus call-site adapters +40…60) | **≈ −320** | MEASURED + ESTIMATE |
| Flat `VM_SYM_ADDR`/`VM_STR_ADDR` with pointer bases (25 B vs 70 B); other accessors gain `(nn)` loads | **≈ −30** | MEASURED sizes; accessor count ESTIMATE |
| `VM_INIT` carve of 5 tables (ESTIMATE ≈ +60) minus removed fixed-range fills (≈ −40) | ≈ +20 | ESTIMATE |
| Unified control stack: `CS_ALLOC` 28, RET unwind 25, type checks, minus `VM_FOR_STACK_FRAME_ADDR` 10, `VM_CALL_PUSH/POP` 61, bound-check code | **≈ ±30** | ESTIMATE |
| Machine-stack guard | +12 | ESTIMATE |
| FOR_INIT depth guard (P0) | +8 | ESTIMATE |
| **Total** | **≈ −320 ± 90** (HOME free 173 → ≈ 490) | mixed |
| EXROM | +19…25 (edit clears arrays) + small | ESTIMATE |

| RAM | |
|---|---|
| Permanent | `SYMTAB_PTR`, `FLOATTAB_PTR`, `STRTAB_PTR`, two array-pointer bases, `VM_CSP`, counts ≈ 16 B |
| Removed fixed reservations | SYMTAB+overflow (96), FLOATTAB (160), STRTAB+overflow (320), pointer tables (48), FOR/CALL/PARAM stacks (136) ≈ **760 B** become exact-size and pool-resident; the vacated `$B4xx–$B7xx` and `$B8xx–$BDxx` gaps become free dense-bank space |
| Compile zone | symbol table ≈ 12 B per symbol (4 header + average 5-char name + extras), so ≈ 300 symbols per 3.5 KB, against 32/8/16/8/8/8 today |
| Capacity ceilings left | 255 per kind (one-byte operand); string length 31; memory |

### 15.7 Limits that remain, and why

| Remaining limit | Why it stays | Could it go later? |
|---|---|---|
| 255 symbols per kind | one-byte operands keep bytecode small and fast | yes at +1 byte/operand and a speed cost; not worth it |
| **31-character strings** | a fixed record is what keeps string variables O(1) and allocation-free; stock BASIC's dynamic strings need a **string heap and garbage collection** | only with a heap — explicitly out of scope; this is the largest remaining departure from stock |
| 1-D arrays | feature, not memory | separate work (`dim_count` byte is reserved) |
| 16-bit integers / float handling | language | out of scope |
| One parameter for PROC/DEF FN | language | out of scope |
| Line length 127, chunk window | design (proved in the chunk-buffer work) | no |
| One resident package, 12 names | design | no |
| Operand stack 41 values | bounded by the 127-char line; has an overflow check | could join the control region later |
| Bytecode box 4,011 B (≈ 8 KB of source) | fixed box; memory elsewhere is dynamic | yes later: base as a variable (+10 T per branch/call), not recommended |
| Loop variables and loop state are **not recursion-local** | no stack frames for locals; unchanged from today | would need locals; out of scope |

### 15.8 Phased migration plan

Each phase is independently shippable, keeps the regression suite green, and leaves the
earlier phases' gains in place. Nothing below has been implemented.

| Phase | Content | HOME ROM | Limits removed | Key risk and mitigation |
|---|---|---:|---|---|
| **P0 — correctness fixes** | (a) edit clears arrays (§8-A); (b) `OP_FOR_INIT` depth guard so recursion cannot corrupt `VM_IP` (§15.2-1); (c) machine-stack nesting guard | +8, +12 (HOME), +19…25 (EXROM) | none; **removes silent corruption** | low; add a regression test per fix |
| **P1 — pool reclaim** | allocate the idle 3,818 B + 520 B dead sysvars; sprite buffers to hidden RAM; FILL stack 2,048 B; `VARS_START` becomes a real variable (§14 items 2, 4) | ≈ 0 | source capacity (4,094 → ≈ 8,400) | constants coupled to `V2_SOURCE_END` (`MEM_INIT_V2`, `V2_LOAD`, `v2_home.asm`); canary-test storage paths |
| **P2 — compile side** | tagged symbol table, label chains, EXIT chains, compile stack; compile-side FOR nesting | **≈ −320** | labels/PROC/FN 8, fixups 8, EXIT FOR 4, FOR nesting at compile time, symbol caps at compile time | compiler core; spike-proven; existing tests `proc_recursion`, `deffn`, `for_nested`, `block_if`, `arrays`; run tables still fixed here, so a clean "too many variables" error remains until P3 |
| **P3 — run tables** | `VM_INIT` carve, `SYMTAB_PTR` etc., flat accessors, array pointer tables sized by count | ≈ −10 | scalar/string/array caps at run time; frees ≈ 760 B of fixed reservations | the previous capacity attempt was reverted for a table collision; moving to pointer-based tables removes the fixed-address coupling that caused it; `scalar_capacity32`, `dynamic_arrays`, `string_arrays`, `array_save_load` |
| **P4 — control stack** | unified typed stack, `VM_CSP`, `CS_ALLOC`, RET unwind; arena checks `VM_CSP` | ≈ ±30 | FOR/CALL/PARAM depths | recursion and leak semantics; `recursion_depth12`, `proc_recursion`, `deffn`, `for_nested` plus new tests: 2-loop recursion depth 20, GOTO-out-of-FOR leak, stack-meets-array collision both ways |
| **P5 — optional** | identifier significance 16/31; `FREE(1)`; segment-2 arrays; string-width policy | ≈ 0 | identifier collisions | `CLAMP_LEN8` call sites (3), `STMT_IDENT_NAME_BUF` |

P0 and P1 do not depend on the rest and should land first whatever else is decided.

### 15.9 Capacities, recomputed for this design (ESTIMATES)

| | Today | After P1 | After P1–P4 |
|---|---:|---:|---:|
| Source + arrays pool | 4,094 | ≈ 8,432 | ≈ 8,432 less run tables and control stack (typical program ≈ 0.5–1 KB) |
| Numeric / string scalars | 32 / 8 | 32 / 8 | **255 / 255** (memory permitting; 8 B and 32 B each) |
| Arrays (numeric / string) | 16 / 8 | 16 / 8 | **255 / 255** |
| Labels + PROC + DEF FN | 8 | 8 | **memory-limited** (bytecode uses 16-bit offsets, so no operand ceiling; the per-kind count byte wraps at 256 and should be widened or ignored for labels) |
| FOR nesting | 4 (compile) / 15 (runtime, unchecked) | same | **memory-limited, checked** |
| PROC/CALL, DEF FN depth | 12 | 12 | **memory-limited, checked** |
| Identifier significance | 8 | 8 | 16 or 31 (P5) |
| Bytecode capacity | 4,011 | 4,011 | 4,011 (≈ 8 KB source) |
| FREE() | `VARS_START − ARRAYS_END` | same | `VM_CSP − ARRAYS_END` while running |

### 15.10 Decisions requiring your approval

| # | Decision | My recommendation |
|---|---|---|
| D1 | Adopt "bump arenas only, no general manager" as the memory model | **Yes** |
| D2 | Control stack: **one typed, memory-limited stack with RET unwind** (recommended) vs. three stacks with large fixed reservations | **Unified** — the only way to give FOR, CALL and PARAM memory-limited growth in a two-ended pool |
| D3 | Accept 255 symbols per kind (one-byte operands) as the deliberate ceiling | **Yes** |
| D4 | Identifier significance 8 → 16 (or 31) | **Yes, 16**; fixes silent `variable1`/`variable2` collisions |
| D5 | Keep strings at 31 characters (no string heap) | **Yes for now**; it is the largest remaining departure from stock and needs its own decision |
| D6 | Loop variables/state not recursion-local (as today) | **Yes**; document it |
| D7 | Land P0 (three correctness fixes) immediately, independent of D1–D6 | **Yes** |
| D8 | Keep the 4,011 B bytecode box and fixed `VM_CODE_BASE` | **Yes** (a variable base costs 10 T on every branch/call) |
| D9 | Error code for memory exhaustion in the control stack / compile zone (reuse 6/1, or add) | add distinct codes |
| D10 | Phase order P0 → P1 → P2 → P3 → P4 | **Yes** |

### 15.11 What was and wasn't measured

* MEASURED: tagged-table spike size and tests; production routine sizes; the FOR-under-recursion
  defect; the identifier collision; array/source overwrite; canary on the idle region.
* Computed from Z80 timing tables, not emulated: all T-state figures (variable access
  −4 T; scan ≈ 130 T per record versus ≈ 250 T per entry in the production scan;
  FOR_INIT/CALL +20…40 T).
* ESTIMATE: every HOME total in §15.6 except the spike-based parts; the control-stack
  net (±30 B) is the least certain figure, because the unified stack was **not**
  spiked. If you approve the direction, a P4 spike (push/pop/unwind/overflow, FOR and
  PROC/PARAM frames) should precede implementation, as the symbol table's spike did.
* Not tested: immediate-mode statements against a program's variables (they are an
  isolated mini-program today), `SAVE/LOAD … ARRAY` with the tagged table, compile-time
  scaling beyond 200 symbols on hardware.
