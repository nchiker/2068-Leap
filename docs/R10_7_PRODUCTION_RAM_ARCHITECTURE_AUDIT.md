# R10.7 Production RAM Architecture Audit, Workspace Manager Feasibility, and Fixed-Limit Analysis

**Status: read-only audit and proposal. Nothing in this document is implemented
or approved.** No RAM map, capacity, `FREE()`, FILL, or limit was changed. The only
code changes made in the session that produced this document are the render-time
keyword work recorded in `R10_7_KEYWORD_CANONICALIZATION_AUDIT.md`.

> **Update (feasibility phase, see `R10_7_WORKSPACE_MANAGER_FEASIBILITY.md`):**
> four statements below were corrected by later measurement.
> 1. §5.5 dead system variables: **520 B**, not 592 B (the first scan missed
>    `rom/ext_sprite_module.asm`; sprite slot metadata is live).
> 2. §5.6 array/source overwrite hazard: **CONFIRMED** in the production ROM (descriptor
>    at `$848C` overwritten by source text after one added line).
> 3. §7.4 consolidation: **MEASURED** spike, symbol routines 599 B → 305 B (−294 B before
>    adapters); supersedes the −150…−230 B estimate.
> 4. §5.1 sprite buffers can live in **hidden chunk 6** RAM (package calls run with EXROM
>    out; one package resident at a time), 0 B ROM; the on-demand-claim idea in §7 is
>    not needed for sprites.

Evidence grades used throughout:

* **MEASURED** — read from the assembled build (`build/*.sym`, `build/*.lst`,
  `tools/report_budget.py`) or observed in the production ROM under
  `ts2068-debug`.
* **TRACED** — established by reading production source, with file/label cited.
* **ESTIMATE** — my arithmetic or Z80 byte counting; not assembled.
* **UNVERIFIED** — plausible, not proven; named so it can be checked before a decision.

Baseline at the time of writing (MEASURED, `make build`): HOME 173 B free,
EXROM 1,566 B free (after the keyword change), source 4,094 B, bytecode 4,011 B,
chunk buffer 264 B, recovered unallocated range `$956B–$A454` = 3,818 B.

---

## 1. Headline findings

1. **The large FILL/sprite/package/stack reservations are mostly not what limits
   BASIC.** BASIC's data pool is only reachable in the contiguous chunk 4/5 span
   `$8000–$BFFF`; chunk 6 (`$C000–$DFFF`) is the EXROM window, and chunk 7
   (`$E000–$FFFF`) is separate real RAM. Recovering FILL, sprite, package, or
   stack bytes gives BASIC **nothing** unless the array arena is allowed to use a
   second, non-contiguous segment. (§3)
2. **FILL's 10,240 B is really 2,048 B of real RAM plus 8,192 B of "hidden" RAM.**
   `$C000–$DFFF` is ordinary RAM only while EXROM is paged out, which the VM does
   around every package call (`OP_CALL_EXT`). That 8 KB costs BASIC nothing. Only
   `$E000–$E7FF` (2,048 B, the tail of FILL's stack) is real-RAM competition. (§4)
3. **The earlier "~1,024 B FILL" design did not shrink the bitmap.** It was
   2068-Forth's span-based fill: stack 4,096 B → 1,024 B, but the 6,144 B visited
   bitmap stayed. It was prototyped here (`f5f8c69`) and reverted for **+212 B of
   HOME ROM**. FILL has since moved into a loadable package, so that ROM cost no
   longer lands in HOME. (§4.3)
4. **The biggest immediately-usable RAM is already identified:** 3,818 B in
   `$956B–$A454`, plus ≈590 B of dead V1 system variables in `$8000–$8456`, plus the
   fact that source, bytecode and arrays are three separate fixed-size boxes. (§3, §6)
5. **Most "arbitrary limits" are cheap to raise without any allocator**, because they
   are constants over small tables that sit in a dense, hand-packed region. The
   cheapest mechanism is a documented compile/run overlay zone, not a manager.
   Consolidating the current two/three-tier symbol tables is **ROM-positive**
   (≈ −50 to −60 B, ESTIMATE). (§7)
6. **Recommendation (§7.8): no general workspace manager now.** Take static
   lifetime zones (option B) plus a two-segment array arena; revisit a 4-operation
   workspace manager only if a second *runtime-sized* client of transient RAM
   appears. A manager does not reduce ROM; the ROM wins come from de-duplicating
   near-identical routines.

---

## 2. Production RAM map, `$4000–$FFFF`

Sizes in bytes. "Pre" = lifetime. Addresses MEASURED from `build/test_basic.sym` and
`build/exrom.sym` unless marked.

| Range | Size | Owner | Production usage | Lifetime / survives? | Class |
|---|---:|---|---|---|---|
| `$4000–$57FF` bitmap, `$5800–$5AFF` attrs | 6,912 | video | screen | permanent | hardware |
| `$5B00–$7FFF` | 10,496 | second display file (hi-res/dual modes) | unused in standard mode | hardware-owned | **not available** (memory_map.md; hardware fact) |
| `$8000–$8456` | 1,111 | `include/sysvars.inc` | live system state (editor, VM-adjacent, graphics, keyboard, calc) | permanent | permanent, **≈592 B unreferenced** (§5.5) |
| `$8457–$9454` | 4,094 | K-TAB line store `PROG_AREA_START`…`VARS_START`, shared with array arena above `PROG_END` | source text; arrays bump-allocated from `ARRAYS_END` up to `VARS_START` | permanent (source); arrays reset at RUN/CLEAR/NEW | permanent |
| `$9455–$9544` | 240 | `SYMTAB_OVERFLOW_BASE` (48 B) + `STRTAB_OVERFLOW_BASE` (192 B) | scalar slots 16–31, string slots 4–9 | **runtime only**; overlays chunk buffer | overlayable |
| `$9455–$956A` | 278 | `CHUNK_BUF`(264)+3 state words(6)+`STMT_IDENT_NAME_BUF`(8) | compiler input window | **compile only** | overlayable |
| `$956B–$A454` | 3,818 | none | **unreferenced** | n/a | **unused** |
| `$A455–$B3FF` | 4,011 | bytecode `VM_CODE_BASE` | emitted at every RUN, executed | RUN | permanent while running |
| `$B400–$BFFF` | 3,072 | "Fixed V2" dense table bank | FLOATTAB 160 B, ARR/STRARR ptr tables, STRTAB 192 B, FOR/call/param stacks, SYMTAB, all compiler tables, scratch, EXT2 registry | mixed: compile-only vs runtime-only vs both | **hand-packed gaps**, see §5.3 |
| `$C000–$DFFF` | 8,192 | EXROM code when paged in; **plain RAM when paged out** | production EXROM image; FILL bitmap/stack while a package runs | EXROM mapped except during package calls | **hidden RAM**, see §4 |
| `$E000–$E7FF` | 2,048 | FILL stack tail (`GFX_FILL_STACK`+2,048) | only during FILL | transient | transient, real RAM |
| `$E800–$F0FF` | 2,304 | sprite image (1,152) + background (1,152) buffers, 8 slots × 144 B × 2 | persistent once GRAB/SHOW used | persistent | persistent, only if SPRITE used |
| `$F100–$F227` | 296 | `LABEL_TABLE_TOP`/`UDG_TABLE` region | referenced by legacy kernel/compat and graphics UDG code | — | **unverified in V2** (§5.5) |
| `$F228–$F327` | 256 | `EDIT_LINE_BUF`/`STORAGE_LOAD_NAME_BUF` (128) + `DETOK_BUF` (128) | editor, LIST, LOAD name | permanent | permanent |
| `$F328–$F3A7` | 128 | `STR_FUNC_POOL` | referenced only by legacy `exrom_strfuncs`/`basic.asm` | — | **no production reference found**, §5.5 |
| `$F3A8–$F3D3` | 44 | `DEF_FN_*`, `EXTENSION_*` V1 state, ABI service veneers | `DEF_FN_*` and most `EXTENSION_*` unreferenced; `EXT_SERVICE_*` veneer table live | — | mostly dead, veneers live |
| `$F400–$F7FF` | 1,024 | package module window `EXTENSION_MODULE_BASE` | one loadable EXT2 package at a time | until next package load/CLEAR | permanent window |
| `$F800–$FEFF` | 1,792 | machine-stack headroom | peak measured far below (§5.4) | permanent | reserve |
| `$FF00–$FFFF` | 256 | machine stack top | stack | permanent | permanent |

Notes.

* `$C000–$DFFF` is mapped as RAM exactly when `BANK_EXROM_DEPTH == 0`. TRACED:
  `OP_CALL_EXT` (`rom/exrom_v2_vm_core.asm`, near `.args_done`) calls
  `BANK_PAGE_EXROM_OUT` before `VM_CALL_INDIRECT` and `BANK_PAGE_EXROM_IN` after.
  RAM contents in that window **persist** while EXROM is mapped; they are simply
  invisible to EXROM code.
* `$9455–$A454` is the old "staging" window. It is no longer a full flattened copy
  of source (R10.7 chunk-buffer change). TRACED in `include/v2_layout.inc`.
* `$B400–$BFFF` is dense; `$B4B0`, `$B4D0`, `$B500`, `$B5C0`, `$B600`, `$B700`,
  `$B800`, `$B900`, `$B960`, `$B9B8`, `$BA00`, `$BA60`, `$BCC0`, `$BD70`,
  `$BE70`, `$BED8`, `$BF00` are the table bases (MEASURED from the symbol file).

---

## 3. Why does BASIC have so little usable RAM? (central question)

Contiguous BASIC-accessible RAM is `$8000–$BFFF` = **16,384 B**. It is spent as:

| Consumer | Bytes | Share |
|---|---:|---:|
| System variables (≈592 B dead) | 1,111 | 6.8% |
| Source + array pool (what `FREE()` reports) | 4,094 | 25.0% |
| Staging window: 278 live-at-compile, 240 live-at-run, **3,818 unused** | 4,096 | 25.0% |
| Bytecode | 4,011 | 24.5% |
| Fixed V2 tables, VM/compiler scratch | 3,072 | 18.8% |

So ordinary programs see 4,094 B for source **and** arrays because three
structures that are never simultaneously large each got a fixed box, and the
staging box outgrew its job when the full-copy flatten was replaced by the
264-byte chunk window. The 24% of contiguous RAM that is idle (3,818 B) plus dead
system variables (≈590 B) is a bigger lever than FILL, sprites or packages, which
live in chunks 6/7 where BASIC's pool cannot reach.

What chunk 6/7 can still offer, **only** if the array arena becomes
multi-segment (§7): the 2,048 B FILL tail, ~1,000 B of stack headroom, and the
sprite buffers when SPRITE is unused.

---

## 4. FILL audit

### 4.1 Current production implementation (TRACED)

`rom/ext_v2_shapes_module.asm` (loadable package, 762-byte class). Iterative
4-connected flood fill, "mark on push":

* `GFX_FILL_VISITED` `$C000`, 6,144 B = 256×192 bits, one bit per pixel, cleared
  with `LDIR` at the start of each FILL.
* `GFX_FILL_STACK` `$D800`, 4,096 B = 2,048 `(x,y)` entries; `PUSH` fails silently
  at full, so a too-large region simply stops expanding ("graceful truncation",
  no corruption).
* Pixels are read/written with `GFX_READ_PIXEL`/`GFX_WRITE_PIXEL` (HOME), OR-only
  writes.

### 4.2 Why a separate 6,144 B bitmap (TRACED from the sysvars/graphics history)

Two shipped bugs: an XOR/erase-mode bug and a **cell-granularity dedup bug** (dedup
at 8×8 attribute-cell level lost pixels). The fix was a per-pixel visited set,
independent of the bitmap and of the attribute cell. It also covers the "recolor
same value" trap (target == new value, so pixel state cannot distinguish handled
from unhandled). So the bitmap is *necessary for this semantics*, not accidental.
Whether those semantics are the right product semantics is a decision, not a
finding (§8, question 2).

### 4.3 Historical designs (MEASURED/TRACED from git and docs)

| Design | Stack | Visited | ROM | Where |
|---|---:|---:|---|---|
| Original V1/Leap per-pixel | 4,096 B | 6,144 B | in HOME | `90c5881`, now `ext_v2_shapes_module.asm` |
| Span-based (2068-Forth port) | **1,024 B** (512 spans) | 6,144 B (kept) | **+212 B HOME** (180→392) | `f5f8c69`, reverted |

So "~1,024 B FILL workspace" in earlier work was the *stack*. The bitmap was never
reduced. The span design peaks at 7 entries for realistic shapes, 252 for a
single-bridge comb, and 15,876 for an adversarial multi-bridge comb (graceful
truncation still holds). The per-pixel design's own header reports a peak of ~2,069
entries for a filled radius-50 circle versus 2,048 capacity — that figure is quoted
from the header, **not re-measured here**, but if accurate, today's FILL can
truncate on a large circle fill.

The revert reason (HOME had 18 B free) no longer applies: FILL left HOME in
`61bb8bb`, and HOME is not where its code lives now. A span rewrite would grow the
package (≈762 + 212 ≈ 974 B, ESTIMATE) within the 1,024 B window, with **0 HOME/EXROM
cost** — but it must fit the package window with little margin.

### 4.4 Options

| Option | Workspace | Real RAM freed | ROM | Risk | Capability |
|---|---|---:|---|---|---|
| Keep | 6,144 + 4,096 | 0 | 0 | none | as today (truncates on very large fills) |
| Span stack (1,024 B), keep bitmap | 6,144 + 1,024 | **2,048** (`$E000–$E7FF`) — the whole FILL footprint then fits inside hidden `$C000–$DFFF` | package +≈212 B (ESTIMATE from `f5f8c69`), no HOME/EXROM | medium: reproduce Python-verified algorithm, re-run shape suite and recolor trap | same or better (fewer truncations) |
| Shrink stack to fit hidden RAM, keep per-pixel (2,048 B stack) | 6,144 + 2,048 = 8,192 exactly | 2,048 | **0** (change `GFX_FILL_STACK_END` constant) | low; raises truncation risk for large fills (header's ~2,069 peak) | slightly worse on large circles |
| Color-as-visited (no bitmap) | stack only | up to 6,144 hidden (not real RAM) | package change | **high**: fails on recolor-same-value and cell-granularity cases that caused the two shipped bugs; needs a product decision on FILL semantics | would change behaviour |
| Bounded scanline fill with a fixed stack | ≈ stack only if visited is per-row | hidden RAM only | package +, algorithm rewrite | high | changes semantics |

Key point: bitmap size only matters if something else needs that hidden 8 KB.
Nothing else is placed there today, so shrinking the bitmap recovers **no usable
RAM** by itself. Of the whole 10,240 B, **only 2,048 B** is real-RAM competition,
and it is recoverable at **zero ROM** by shrinking the stack to 2,048 B, or at
≈+212 B *package* ROM with a span stack and no capability loss.

---

## 5. Other reservations

### 5.1 Sprite buffers (`$E800–$F0FF`, 2,304 B) — TRACED
8 slots × 144 B image + 8 × 144 B background (`SPRITE_SLOT_MAX=8`,
`SPRITE_SLOT_BYTES=144`). Allocated whether or not SPRITE is ever used. Lifetime:
persistent once GRAB/SHOW executes. Chunk 7, always mapped, so usable by EXROM,
HOME and packages. Overlay candidate with a second array segment (only when no
sprite is defined), at the price of a "GRAB while arrays occupy this segment"
failure mode; or on-demand allocation (a `WS_ALLOC` use case).

### 5.2 EXT2 package space — TRACED
Registry `EXT2_TABLE` `$BF00`, 12 × 14 B = 168 B (+12 B argtypes at `$BFA8`).
Code window `$F400–$F7FF` (1,024 B), **single window**: loading a second package
replaces the first's code; the per-slot generation counter turns stale calls into
`EXTENSION_NOT_FOUND`. So "12 slots" is 12 names, not 12 simultaneously resident
packages. SYMBOLS: `EXT2_MAX=12`, `EXT2_REC_LEN=14` (`kernel/extensions/ext_registry.asm`).

### 5.3 Compiler-only and VM-only memory (`$B400–$BFFF` and window) — TRACED
Compile-only: `CSYMTAB` 32×9 across three tiers (`$B800`+144 B base-16, 108 B at
`$B890`, 36 B at `$BA84`), `STRSYMTAB`, `LABELTAB` 8×11, `FIXUPTAB` 8×11,
`CFOR_STACK`/`EXITFOR_PATCH_TABLE` in the gap after FIXUPTAB, `ARRSYMTAB`,
`STRARRSYMTAB`, chunk buffer. Run-only: `SYMTAB` (48 B at `$B700` + 48 B overflow),
`FLOATTAB` 32×5, `STRTAB` (4 slots + overflow), `ARR_PTR_TABLE`, VM FOR/call/param
stacks, operand stack. **All compile-only and run-only tables are lifetime-disjoint
by construction** (`COMPILE_PROGRAM` always finishes before `VM_RUN`, and nothing
interleaves) — the same invariant already used for the overflow tiers.

### 5.4 Machine stack (`$F800–$FEFF` + `$FF00` top) — MEASURED
Canary fill of `$F800–$FEDF`, production ROM, then typed `x = ((((((((((((1+2)*3)+4)*5)+6)*7)+8)*9)+1)*2)+3)*4)`,
`print x`, `run` (result `-29156`, 16-bit wrap, compile and run completed):
**peak depth 174 B** below `$FF00` for a 12-level parenthesis nest, ≈12–14 B per
nesting level. Idle SP ≈ `$FEFA`.

Extrapolation (ESTIMATE): a 127-character line can nest ~60+ parentheses, i.e.
≈ 0.8–1.5 KB; there is no explicit nesting cap that I found. So ~1,792 B headroom is
**not** wasteful for the worst-case expression, but typical programs use a few
hundred bytes. Reclaiming stack headroom safely needs either a parser nesting
limit (a compile error, ≈10–15 B ROM, ESTIMATE) or leaving ≥1.5 KB. This is the
one place where an unbounded recursive structure is the real driver.

### 5.5 Dead/unverified system variables — heuristic scan (MEASURED, with caveats)
Method: every RAM symbol ≥`$8000` counted for references in the production HOME and
EXROM listings and in the production package sources, excluding `EQU`/`DEFS`
definition lines. Result: **≈ 520 B of `$8000–$8456` have no production-ROM or package reference** (first-pass figure was 592 B; see the update note at the top):

| Range | Bytes | Symbols (V1 leftovers) |
|---|---:|---|
| `$8004–$8013` | 16 | lookup/remove scratch |
| `$812C–$81CE` | 163 | goto/check/error list/row shadow/if scan |
| `$8245–$8270` | 44 | hilite/scroll row caches |
| `$827F–$82C5` | 71 | **V1 `FOR_STACK`**, FOR temps |
| `$82EE–$830D` | 32 | sprite slot W/H/row/col |
| `$8391–$83A1` | 17 | `GOSUB_STACK` |
| `$83AA–$83E9` | 64 | `STR_EXPR_SCRATCH`, `STR_CMP_RIGHT` |
| `$83F4–$841D` | 42 | pool scan / array assign scratch |
| `$841F–$8456` | 56 | string-func, hilite, `PRINT_ROW_BUF` |

Caveats: this scan can miss references made through register-indirect aliasing or
`sym+N` into another label's space; the sprite slot arrays in particular need a
manual check. The scattered dead cells are **interleaved with live ones**; recovering
them means deleting the `DEFS` and letting `PROG_AREA_START` slide down (the project
has done this repeatedly; see the move history in `sysvars.inc`). The same applies
to ≈128 B `STR_FUNC_POOL`, ≈296 B label/UDG region, and the `DEF_FN_*`/`EXTENSION_*`
cells at `$F3A8+` — **no production reference found, not verified dead** (UDG code in
`graphics.asm` may still use `UDG_TABLE`). Treat as ESTIMATE ≈ 590 B (sysvars) and
up to ≈ 420 B more in chunk 7, pending a manual check.

### 5.6 Latent hazard — **CONFIRMED (was UNVERIFIED)**
`MEM_LINE_STORE` bounds source growth against `VARS_START`, not `ARRAYS_END`, and
arrays are allocated directly above `PROG_END`. Editing source while DIM'd arrays
exist (after a RUN) may overwrite array descriptors that `ARR_PTR_TABLE` still
points at, and `SAVE … ARRAY` would then read garbage. Reproduced in the feasibility phase (feasibility doc §8). It
matters because any scheme that places arrays or bytecode above the source depends
on the answer.

---

## 6. Capacity models

All figures are ESTIMATES unless noted. "Pool" = the region `FREE()` measures today
(source + arrays). No physical RAM is counted twice; the compile-phase and run-phase
columns are alternates for the same bytes.

### 6.0 The zone idea (used by models 2 and 3)
Reserve one **transient zone Z** at the top of the staging window. During compile it
holds the chunk buffer plus compile-only tables; during run it holds run-only
tables and stacks. Because the phases are disjoint, `size(Z) = max(compile, run)`,
not the sum. Everything else in the staging window joins the pool.

### 6.1 Conservative — no new capability, just stop wasting RAM
* Z = 278 B (chunk window; 240 B overflow tiers relocate into it, they fit).
* Pool = `$8457` → `$A33F`: **7,912 B (+3,818, +93%)**; `VARS_START` and the two
  overflow base constants change, ROM ≈ 0.
* Bytecode 4,011, FOR 4, call 12, scalars 32/8, labels 8: unchanged.
* Dead sysvars (≈590 B) optionally added at pool *bottom* by sliding
  `PROG_AREA_START`: pool ≈ 8,500 B.
* FILL, sprites, packages, stack: unchanged. FREE(): `VARS_START − ARRAYS_END`, empty
  program ≈ 7,912 B (≈8,500 with dead sysvars).

### 6.2 Balanced
Conservative **plus**:
* Z = 1,024 B: holds chunk 278 + compile tables (labels/fixups 16 each = 352 B;
  FOR/EXITFOR 8 levels = 96 B, ESTIMATE) at compile, and a flat 64-scalar
  `SYMTAB`/`FLOATTAB`, 16-string `STRTAB`, 16-deep FOR, 24-deep call/param stacks at
  run — sizes must be re-checked against 1,024.
* Pool = 4,096 − 1,024 + 4,094 = **7,166 B**.
* Second array segment `$E000–$E7FF` (2,048 B) after FILL stack shrink: dynamic data
  capacity ≈ **9,200 B** for arrays specifically (not for source).
* Limits: FOR 8–15, PROC 12→24, scalars 32→64, labels/fixups 8→16.
* Bytecode 4,011 (unchanged). FILL: stack 2,048 B (0 ROM) or span stack (package +212).
* FREE(): pool bytes only; arrays-in-segment-2 reported as an additional term
  (see §6.4).

### 6.3 Aggressive
Balanced **plus**, all requiring the §5.6 hazard to be resolved first:
* Unified source → bytecode → arrays bump pool: the staged window, bytecode box and
  array arena become one region `$8457`–`$B3FF` = 12,201 B minus Z; bytecode base
  chosen at RUN as `PROG_END` (offsets in bytecode are relative, **UNVERIFIED** —
  `FOR_LOOP_TOP_OFFSET`/`BRANCH_PATCH_TMP` suggest offset-based branches, but
  `VM_IP`-absolute operands may exist), arrays start above the emitted bytecode.
* Source + bytecode + arrays ≲ 12,201 − Z(1,024) ≈ **11,177 B shared**: a
  4 KB program with 3 KB bytecode leaves ≈ 4 KB for data, versus ≈ 0 today.
* Sprite buffers (2,304 B) become an on-demand `GRAB`-time allocation;
  stack headroom trimmed to 512 B behind a parser nesting cap (+≈1,280 B to a
  segment-2 arena).
* Cost: bytecode base becomes a variable (every `ld hl,VM_CODE_BASE` immediate
  becomes `ld hl,(addr)` — same size, +6 T-states per site), a parser nesting limit,
  a 2-segment arena (≈20–30 B), and a broad regression pass.
* Dynamic data capacity ≈ **12 KB − source − bytecode**, best case ≈ 9 KB for a
  small program; the "limits" (source 4,094 / bytecode 4,011) stop being separate
  caps.

### 6.4 What `FREE()` should mean
Today (`MEM_FREE_BYTES`): `VARS_START − ARRAYS_END`, i.e. room for more source and
arrays *combined*. It is the right number as long as source and arrays share one
pool. It changes meaning per model:

| Model | `FREE()` should report |
|---|---|
| Conservative | unchanged formula; larger result |
| Balanced | free pool bytes **plus** free bytes in array segment 2 (so a program can compare against the DIM it plans) — or keep `FREE()` = pool and add `FREE(1)` for arrays |
| Aggressive | `limit − max(ARRAYS_END, code_end)`; **only valid after a RUN**, and before RUN should say "room for source + estimated bytecode", which is an estimate. Needs an explicit, documented definition |

---

## 7. Workspace Manager vs. Dynamic BASIC Runtime Memory

### 7.1 Existing limits — verified against current production code

| # | Limit | Value | Cause | Class | Dynamic w/o bytecode change? | ROM to raise | Recommended treatment |
|---|---|---:|---|---|---|---|---|
| 1 | FOR/NEXT nesting | 4 | `FOR_NEST_MAX` (compiler) and `VM_FOR_NEST_MAX`; compile tables `CFOR_STACK` 16 B + `EXITFOR_PATCH_TABLE` 32 B in the 72 B gap `$B9B8–$B9FF`; runtime frames 4 B each at `$B5C1` with 63 B free there (→ ≤15 levels, **no relocation**) | 2 fixed table | not needed | **0 B** (EQU edits) once compile tables move to a zone | Raise fixed to 8 or 15; **no dynamic stack** |
| 2 | PROC/CALL nesting | 12 | `VM_CALL_STACK` 24 B `$B688–$B69F` and `VM_PARAM_SAVE` 12×8 = 96 B `$B732–$B791`; bounds checks compare SP to a symbol | 2 | not needed | 0 B | Move both to the run zone; 24–32 deep ≈ +320 B zone |
| 3 | DEF FN depth | 12 (shared with #2) and **one parameter only** | same param-save stack; one-parameter grammar in `COMPILE_DEF_FN` | 2 + 4 | n/a | 0 B for depth; ≈ ≥25 B+ for multi-param (ESTIMATE) | Depth shares #2. Multi-param is a language feature |
| 4 | DEF FN / PROC / label count | **8 combined** | `LABELTAB_MAX_ENTRIES=8`; `COMPILE_DEF_FN` and PROC/GOTO labels all use `LABEL_DEFINE`. 8 is the practical ceiling for program structure | 2 | not needed | 0 B | **Highest-value limit to raise**: 16 × 11 B = 176 B compile-zone |
| 5 | Forward fixups outstanding | 8 | `FIXUPTAB_MAX_ENTRIES=8` | 2 | not needed | 0 B | 16, same zone |
| 6 | EXIT FOR per loop | 4 | `EXITFOR_MAX` | 2 | not needed | 0 B | 4 is fine |
| 7 | Numeric scalars | 32 | `CSYMTAB_MAX_ENTRIES=32`, tiered 16 base + overflow in `$9455` and 3 compile tiers; 1-byte index in bytecode (→ ≤255) | 2 + 3 | not needed | **−≈50 to −60 B** if tiers are merged into one contiguous zone table (ESTIMATE: `VM_SYM_ADDR` 32 B, `VM_STR_ADDR` 38 B, `CSYM_ENTRY_ADDR` 43 B shrink) | Make it one flat zone table; 48–64; keep compile-time index → O(1) runtime |
| 8 | String scalars | 8 named + 2 temps | `STRTAB_MAX_VARS=8`, 32 B each, tiered | 2 + 3 | not needed | merged with #7 | 16, 31-char strings unchanged; temps 2 is a language question |
| 9 | Numeric arrays | 16 | `ARRSYMTAB_MAX_ENTRIES`, `ARRAY_MAX_COUNT`, `ARR_PTR_TABLE` 32 B `$B4B0` | 2 + 3 | pointer table could grow | 0 | 16 reasonable; 24 if table moves |
| 10 | String arrays | 8 | `STRARRSYMTAB_MAX_ENTRIES`, `STRARR_PTR_TABLE` 16 B | 2 | same | 0 | keep |
| 11 | Array dimensionality | 1-D only | descriptor has `dim_count` byte but all code is 1-D | 4 | no | feature | out of scope |
| 12 | Array data capacity | pool − source | bump arena `ARRAYS_END` vs `VARS_START` (already a bump allocator) | 1 | already dynamic | segment-2 ≈ 20–30 B | second segment |
| 13 | EXT2 registry slots | 12 | `EXT2_MAX` immediate in `cp`/`ld bc` (fixed table `$BF00`); **plus one resident package** | 2 + 6 | no | ≈0 for slots; window growth is RAM | 12 is plenty given one package window |
| 14 | Package size | 1,024 B | `$F400–$F7FF` window | 1 | no | n/a | grow only if a package needs it (FILL span ≈974 B) |
| 15 | Source capacity | 4,094 | `PROG_AREA_START`…`VARS_START` | 1 | yes (§6) | ≈0 | §6 models |
| 16 | Bytecode capacity | 4,011 | `VM_CODE_BASE`…`V2_CODE_LIMIT` | 1 | yes if base is variable | ≈+20–40 B (ESTIMATE) | optional, aggressive only |
| 17 | Line length | 127 | `EDIT_LINE_BUF` 128 B, chunk bound proof | 5/6 | no | n/a | fixed by design |
| 18 | Identifier significance | 8 chars | `CLAMP_LEN8`, 8-byte name fields | 3 + 2 | no | n/a | keep |
| 19 | Operand stack | 41 values | `$B604–$B67F` = 124 B / 3 B | 2 | not needed | 0 | adequate (expressions bounded) |
| 20 | Parser nesting | **unbounded**, limited by machine stack (~12–14 B/level, MEASURED) | recursive descent | 5 | n/a | ≈10–15 B for a cap (ESTIMATE) | add a cap if stack headroom is trimmed |
| 21 | FLOATTAB | 32 | 1 : 1 with scalar slots, 5 B each | 2 + 3 | no | 0 | follows #7 |
| 22 | Keyword spans per line | 8 | `KW_SPAN_MAX` (rendering only) | 2 | no | 0 | raise to 12 if RAM allows; display only |
| 23 | Hardware stack | 1,792 + 256 | physical | 6 | no | — | §5.4 |

Classification key: 1 fixed RAM reservation · 2 fixed table/stack size · 3 bytecode
operand/symbol encoding · 4 compiler/parser implementation · 5 runtime algorithm ·
6 hardware.

### 7.2 Findings that follow from the table
* Every limit in the list is in classes 1–2. **None requires an allocator to raise.**
  What blocks them today is a *layout* problem: the tables live in hand-packed gaps
  (`$B4xx–$BFxx`), so each increase collides with a neighbour. That is what caused the
  earlier reverted attempt (`VM_ARR_VALUE_TMP`/`VM_INPUT_COUNT` collision) and why
  the shipped 32/8/12 increases use *tiers*.
* **Tiering is itself a ROM cost.** `VM_SYM_ADDR`, `VM_STR_ADDR`, `CSYM_ENTRY_ADDR`,
  `STRSYM_ENTRY_ADDR` exist largely to pick a tier. A flat table in a zone removes the
  branches.
* Runtime access is `index → address` with immediate bases. A dynamic scheme turns
  each immediate base into a `ld hl,(var)` — **the same instruction size** (3 B) but
  +6 T-states per access, on the hottest path of the VM. This is the real cost of
  "dynamic": speed, not ROM.

### 7.3 Can FOR/NEXT, PROC/CALL, DEF FN share a dynamic runtime stack?
Mechanically yes — they are all push/pop frames with SP-vs-limit checks — but it
is not a good trade:
* FOR frames are 4 B, call frames 2 B, param frames 8 B. A single frame-typed stack
  needs a tag or three stack pointers; the three existing pointers are 3 × 2 B RAM.
* FOR has **no runtime bounds check by design** (the compiler is the sole
  enforcer). A shared dynamic stack would force a runtime check onto every FOR, a
  performance regression for the loop the compiled-BASIC advantage depends on.
* The existing PROC call and param stacks are already depth-synchronised 1 : 1.
* A fixed stack at depth 16/32 costs 64–256 B of zone RAM and **0 B ROM**; a
  dynamic one costs ≈30–50 B ROM (ESTIMATE) plus complexity.

Verdict: **raise the fixed depths; do not make execution stacks dynamic.**

### 7.4 Duplicate allocation/bounds code — audit and measurement

Routine sizes are MEASURED (next-label distance in `build/test_basic.sym`).
Savings are ESTIMATES (Z80 byte counting, not assembled).

| Family | Routines (bytes, MEASURED) | Reusable sequence | Removable | Adapter / call overhead | Net HOME | Runtime |
|---|---|---|---:|---|---:|---|
| Scalar symbol find-or-create | `CSYM_FIND_OR_CREATE` 97 + `STRSYM_FIND_OR_CREATE` 98 — **byte-identical bodies except four symbol operands** (verified by reading both) | whole scan/create/limit-check | ≈ 70–85 | a 3–4-word descriptor (count addr, max, entry-fn) loaded per caller, ≈ 8–10 B × 2 callers | **≈ −55 to −70** | compile-only, negligible |
| Array symbol scan/find/lookup | `ARRSYM_SCAN` 63 + `STRARRSYM_SCAN` 63, `…FIND_OR_CREATE` 61 + 66, `…LOOKUP` 23 + 28 | same pattern, different record length | ≈ 90–110 | descriptor | **≈ −70 to −95** | compile-only |
| Tier address routines | `CSYM_ENTRY_ADDR` 43, `STRSYM_ENTRY_ADDR` 26, `VM_SYM_ADDR` 32, `VM_STR_ADDR` 38 | flat table makes them `base + idx*rec` | ≈ 55–70 | none | **≈ −40 to −60** (this is "remove tiers") | runtime slightly faster |
| Arena allocators | `ARENA_ALLOC_NUMERIC` 77, `ARENA_ALLOC_STRING` 95 — both: size, add `ARRAYS_END`, compare `VARS_START`, write header, update ptr table, bump | bounds check + header write | ≈ 20–30 | one shared tail | **≈ −15 to −25** | none |
| Bounded stacks | `VM_PUSH` 48, `VM_POP` 26, `VM_CALL_PUSH` 37, `VM_CALL_POP` 24, param bind/unbind 35+33, FOR frame address 10 | SP-vs-limit compare | small: they differ in width and error code | not worth a helper | **≤ 10** | hot path: a helper adds `call`/`ret` (+27 T-states) — rejected |
| Init/zero | `VM_INIT` 95, `COMPILER_INIT` 26, `MEM_INIT` 41, `MEM_FILL_ZERO` 1 | zero-ranges | ≈ 20–30 if one table of (base,len) pairs drives it | table | **≈ −10 to −25** | once per RUN |
| Line-store | `MEM_LINE_STORE` 158, `INSERT` 57, `DELETE_RANGE` 87, `MEM_FITS_CHECK` 11 | shifting + bounds | already shared helpers (`MEM_SHIFT_UP/DOWN`) | — | 0 | — |
| FILL push/pop (package) | package-local | — | n/a (package ROM) | — | 0 HOME/EXROM | — |
| EXT2 registry | `EXT2_REGISTER` 142, `LOOKUP` 72, `SLOT_ADDR` 18 | — | already one registry | — | 0 | — |

**Sum of genuine de-duplication: ≈ −150 to −230 B HOME (ESTIMATE).** It comes from
table-driven symbol routines and removing tiers, **not** from a memory manager. None
of these needs a workspace manager.

*Workspace allocation vs subsystem operations that must remain:* line-store
shifting, array element addressing, FOR/PARAM frame push/pop, and the EXT2 generation
check are subsystem-specific and stay as they are. What a manager could replace is only
"set a base, advance a pointer, compare against a limit, release", which in this
codebase appears in `ARENA_ALLOC_*` (already shared by DIM), `MEM_LINE_STORE`'s fit
check, FILL's own push (package), and compile/run table initialisation.

### 7.5 What a 4-operation workspace manager would cost

Preliminary sketch (ESTIMATE, Z80 byte counting; not assembled; the 60–100 B target
is a design target, not a measurement):

| Part | Bytes (ESTIMATE) |
|---|---:|
| `WS_INIT` (set top/limit) | 8–10 |
| `WS_MARK` (return current top) | 4–6 |
| `WS_ALLOC` (HL = size → HL = base, carry on failure, bump) | 18–24 |
| `WS_RELEASE` (restore a mark) | 4–6 |
| **Manager core** | **≈ 35–45** |
| Permanent RAM | 4–6 (top, limit, optional low mark) |
| Per client adapter: carve + store base(s) | ≈ 8–15 per client per table |
| Table bases become `ld hl,(var)` (same size as `ld hl,imm`) | 0 B ROM, +6 T-states per access |

The core is **cheaper than the 60–100 B target**. The cost is in the adapters and in
RAM: a manager that carves compile/run tables dynamically needs a **base pointer in
RAM per table** (≈ 12–14 tables × 2 B ≈ 25–30 B) plus per-table carve code (≈ 8 B × 14
≈ 110 B, ESTIMATE). Net for "manager + carve all zone tables" ≈ **+120 to +170 B ROM
and +25 B RAM**, versus ≈ 0 B ROM for fixed zone addresses. It would be ROM-positive
only if it replaced `ARENA_ALLOC_*`'s duplication (≈ −20 B) and the tier logic —
but the tier logic disappears under a *static* zone as well, with no manager.

**Answer to "could a manager be ROM-neutral or ROM-positive?":** the manager *core*
is ≈ 40 B, so a manager restricted to a few runtime-sized clients can be near
neutral. A manager that owns every compile/run table is **net ROM-negative** against
static zone constants. The ROM savings available in this codebase come from
de-duplication (§7.4), which can be taken with or without a manager.

### 7.6 Three architectures compared

| | **A. Workspace manager only** | **B. Manager + execution stacks in a dynamic arena** | **C. Hybrid runtime memory manager** |
|---|---|---|---|
| What it does | share transient RAM (FILL, sprites, compile/run tables, package scratch) by mark/alloc/release | A plus FOR/call/param frames grown on demand | B plus scalars/strings/arrays addressed through computed bases |
| HOME ROM | ≈ +40 core; +90–140 adapters if it owns compile/run tables (ESTIMATE) | A + ≈ 30–50 | B + ≈ 60–120 and every variable access slower |
| EXROM ROM | ≈ 0–20 | ≈ + 10–20 | ≈ +30–60 |
| Permanent RAM | 4–6 + per-table base pointers ≈ 25–30 | + 6 (three SPs) | + per-array/var base pointers |
| Recoverable RAM | same zone gains as static B (§6); on-demand sprite/FILL use adds ≈ 2–3 KB in the best case | same | same + finer packing |
| Limits removed | none by itself (limits are table-layout problems) | FOR/call/param depth become capacity-bounded (but they were cheap to raise) | scalars/strings/array counts become capacity-bounded |
| Runtime perf | table accesses `ld hl,(var)` (+6 T-states) | FOR gains a bounds check (hot path) | every var access indirect |
| Fragmentation / failure | mark/release is LIFO: no fragmentation, failure = `WS_ALLOC` carry | LIFO per stack; OOM at push | arrays free-list or bump + compaction → real fragmentation risk |
| Complexity | low | medium | high |
| Compiler/VM/EXT2 compat | changes table addressing at every site; package ABI unchanged | VM ops touch frames | bytecode index → address path changes; EXT2 unaffected |
| Production risk | medium (touches the dense tables that caused the earlier regression) | medium-high (FOR/PROC correctness, the `VAL("123")`-class collision history) | high |

For comparison, the same table for the five options requested in the original prompt:

| Option | HOME / EXROM ROM | Permanent RAM | RAM realistically recovered | Fragmentation | Runtime | Complexity | Pointer/API impact | Compaction? | EXT2 | `FREE()` | Migration risk |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **A** fixed, targeted recovery | ≈ 0 / 0 (−150 to −230 HOME if dedup is also taken) | 0 | pool +3,818 (+≈590 dead sysvars) | none | none | low | none | no | none | same formula, bigger | low |
| **B** static overlays / lifetime zones | ≈ 0 / 0 (tier removal −40 to −60) | 0 | A + zone gains (§6.2); FILL tail 2,048 | none | none | low–medium | table bases move (equ-based, ASSERTed) | no | none | same | low–medium |
| **C** region/workspace manager | +40 core, +90–140 adapters / ≈ 0–20 | ≈ 25–30 | ≈ B, plus on-demand sprite/FILL | none (LIFO) | +6 T-states per table access | medium | every table access goes through a base variable | no | none | defined by manager | medium |
| **D** simple dynamic allocator (bump or free list) | +50–120 / +0–20 | few bytes | arrays already do this; extending to scalars/strings only costs speed | free-list: yes; bump: none until `CLEAR` | slower var access | medium–high | variable access and `SAVE … ARRAY` pointer table | free-list needs it | none | free-list needs a walk | high |
| **E** hybrid: fixed critical + static zones + 2-segment array arena (+ optional unified pool) | ≈ +20–30 (segment-2 logic) minus tier/dedup savings | few bytes | B + 2,048 (FILL tail) + stack/sprite segments; unified pool: §6.3 | none (bump) | none | medium | array arena only (descriptors already absolute) | no | none | extra term or `FREE(1)` | medium |

### 7.7 Does the extra capability justify the ROM?
* A (manager only): the core is cheap but delivers **no new BASIC capability**
  (limits are layout problems, §7.2). Justified only if a second runtime-sized
  transient client appears.
* B (+ dynamic stacks): spends ROM and loop speed to solve problems a 64–256 B zone
  already solves. Not justified.
* C (variables/arrays through dynamic bases): the existing array arena already is the
  one place dynamic allocation pays off. Extending dynamism to scalars forfeits O(1)
  immediate-base access for no capacity the flat zone does not already give.

### 7.8 Recommendation

**No general workspace manager now. Adopt static lifetime zones (option B) with a
two-segment array arena (option E-lite), and take the de-duplication that makes it
ROM-positive.**

In order of value per risk:
1. Allocate the 3,818 B recovered range to the pool and relocate the 278 B chunk buffer
   and 240 B overflow tiers to the top of the window (zone Z). ≈ 0 ROM.
2. Merge the scalar/string tiers into flat zone tables (−40 to −60 B HOME, then
   scalars/strings/labels/fixups/FOR/PROC become EQU edits). Unify the near-identical
   symbol routines (−125 to −165 B HOME). Together **≈ −165 to −225 B HOME**, which
   would take HOME free from 173 B to ≈ 340–400 B (ESTIMATE; to be assembled before
   committing to any number).
3. Raise fixed limits to 16 labels/16 fixups, 8–15 FOR levels, 24–32 PROC depth,
   48–64 scalars, 16 string slots — all zone constants, 0 ROM, **no dynamic stacks**.
4. FILL: shrink stack to 2,048 B (0 ROM) now, or span stack (package +≈212 B) later;
   frees `$E000–$E7FF` for a second array segment (≈ +20–30 B ROM).
5. Revisit a 4-op workspace manager **only** if sprites or packages need runtime-sized
   transient RAM. At that point its ≈ 40 B core is cheap; the earlier steps do not
   preclude it.

Do not build a general manager "for elegance": no limit in §7.1 requires one, and the
variable-access speed cost is real.

---

## 8. Architecture decision checkpoint (for review — nothing implemented)

1. **Which reservations to eliminate or reduce?** Proposed: the 3,818 B staging idle
   range and ≈590 B dead sysvars (confirm the scan by hand first); FILL stack tail
   `$E000–$E7FF`. Keep sprite buffers, package window and stack headroom until the
   parser nesting limit exists.
2. **FILL: smaller workspace or different algorithm?** Proposed: shrink stack to
   2,048 B now (0 ROM, slightly more truncation on very large circle fills), consider
   the span stack later (package +≈212 B). Do not drop the bitmap without a decision
   on FILL semantics (recolor, cell granularity).
3. **Fixed overlays or lightweight manager?** Proposed: fixed zones. Revisit a manager
   only with a second runtime-sized client.
4. **How to divide reclaimed RAM among source, bytecode, dynamic data?** Needs your
   call. Static split options: all to pool (+3,818; arrays/source share), or part to
   bytecode by lowering `VM_CODE_BASE`, or the aggressive single-pool. The aggressive
   model needs the §5.6 hazard checked first.
5. **What should `FREE()` report?** §6.4. Recommend keeping `VARS_START − ARRAYS_END`
   for the pool and adding an explicit argument or second function for segment-2
   free bytes, rather than redefining it.

---

## 9. Remaining R10.7 roadmap (unchanged, not part of this task)

* **Editor redraw/flicker:** V2 flashes on redraw; V1 had selective-redraw logic and a
  dedicated smoke test. Locate both, determine whether V2 bypassed/lost the V1
  behaviour, restore/reuse, add regression coverage. Not started.
* **Error-jump command-entry bug:** after `V2_JUMP_TO_ERROR_LINE` the cursor can land
  at the start of an existing source line; typing `RUN`/`NEW` can alter that line
  instead of dispatching. Tracked, not fixed.
* **FOR stack depth:** current production depth is **4** (`FOR_NEST_MAX`,
  `VM_FOR_NEST_MAX`). The earlier "8" cited in `R10_7_CAPABILITY_RESTORATION.md` is the
  legacy V1 `FOR_STACK_MAX=8`, which V2 does not use (also noted in the capacity
  audit §6). The V2 limit of 4 is therefore not a regression of an intended 8;
  confirm intent before release qualification. Not changed here.
* Resolve remaining editor UX issues before R11 qualification.

## 10. Open items and caveats

* Dead-sysvar list is heuristic (§5.5); a manual pass is needed before deleting.
* §5.6 source/array overwrite hazard is unreproduced.
* The 15,876-entry, 252-entry, and ~2,069-entry FILL stack figures are quoted from
  the project's own history, not re-measured.
* All ROM deltas in §7.4–§7.7 marked ESTIMATE have not been assembled; the only
  assembled ROM measurement in this document is the keyword change
  (EXROM 1,409 → 1,566 B).
* Typed-key injection in the emulator drops characters intermittently; programs used
  for measurements were verified by memory dump.
